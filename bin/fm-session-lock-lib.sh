#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# It also owns the fork-descent evidence below, which is what separates a
# forked continuation of the lock owner from a genuinely competing session.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Set FM_HARNESS_PATH_NAME to the exact harness name carried by executable path
# $1 - its own basename or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
#
# It answers through a variable rather than stdout because its one caller runs
# per ancestry hop on the Stop hot path, where a command substitution would cost
# a subprocess for a search that is entirely shell pattern matching.
FM_HARNESS_PATH_NAME=''
fm_harness_path_name() {  # <path>
  local path=$1 name
  FM_HARNESS_PATH_NAME=''
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) FM_HARNESS_PATH_NAME=$name; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#
# Every test here is a shell builtin. This runs once per ancestry hop, and the
# fork-descent resolution below walks a run per candidate registry record on the
# Stop hot path, so a subprocess per test would cost more than the ps calls that
# feed it.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=${comm##*/}
  if [[ $base =~ $FM_HARNESS_RE ]]; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if fm_harness_path_name "$comm" || fm_harness_path_name "$argv0"; then
    name=$FM_HARNESS_PATH_NAME
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if [[ $args =~ $FM_HARNESS_RE ]]; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when pid $1 is ANY harness ancestor of the current process, i.e. this
# process runs inside the same contiguous verified-harness run as that pid.
# ONE owner of that membership relation, so every predicate below decides "the
# same run" the same way and none of them re-reads the lock to ask it.
fm_harness_ancestry_contains_pid() {  # <pid>
  local want=$1 pids pid
  case "$want" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$want" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  fm_harness_ancestry_contains_pid "$lock_pid"
}

# --- fork descent ------------------------------------------------------------
#
# A harness session fork is a third case the live/dead owner test cannot see: a
# forked continuation runs under a NEW pid while the pre-fork process is still
# alive, so the lock keeps naming a live process that is not in the new
# session's ancestry. That reads exactly like a competing session, and refusing
# it is what leaves supervision unable to re-claim its own home.
#
# The functions below decide that third case from EVIDENCE ONLY, and only for
# Claude Code. Two independent facts are required, both produced by the harness
# itself and neither of them forgeable by an unrelated session:
#
#   1. Claude Code keeps a live-session registry at
#      <config>/sessions/<pid>.json, pruned when the pid dies or its recorded
#      process start time stops matching. It maps the lock's bare pid to the
#      session id that pid is actually running.
#   2. A forked session's transcript is a verbatim copy of its source
#      transcript: the copied records keep their original v4 message uuids, in
#      order, and the fork then appends its own. An unrelated session shares no
#      uuid with anyone.
#
# So "the owner's transcript is a strict positional prefix of mine" proves both
# that the owner is this session's fork source AND that it has produced nothing
# since the fork. The second half is what keeps this safe: any turn the source
# takes after the fork appends a uuid this session does not have, the prefix
# stops holding, and the owner is treated as the live competing session it now
# demonstrably is.
#
# docs/watcher-continuity.md owns the operator-facing behavior and its limits;
# docs/verification/supervision.md records the measured evidence.
# Everything here fails closed: any missing, ambiguous, or unreadable input
# leaves the caller with today's live-foreign-owner refusal.

# Claude Code's configuration root, honoring its own CLAUDE_CONFIG_DIR override.
fm_claude_config_dir() {
  local dir=${CLAUDE_CONFIG_DIR:-}
  [ -n "$dir" ] || dir="${HOME:-}/.claude"
  case "$dir" in
    ''|/.claude) return 1 ;;
  esac
  printf '%s\n' "$dir"
}

# Print the kernel start time of pid $1, the value Claude Code stores as
# procStart, or return 1. Linux only: it is read from /proc, and no portable
# equivalent exists, so fork recovery is a Linux-only widening and every other
# platform keeps the unchanged refusal.
fm_claude_proc_start() {  # <pid>
  local pid=$1 line rest
  local -a fields=()
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r line < "/proc/$pid/stat" 2>/dev/null || return 1
  # Strip "<pid> (<comm>) ", whose comm may itself contain spaces and parens.
  # Nothing after it contains a parenthesis, so the last ") " is comm's close.
  rest=${line##*") "}
  [ "$rest" != "$line" ] || return 1
  read -ra fields <<< "$rest" || :
  [ "${#fields[@]}" -ge 20 ] || return 1
  printf '%s\n' "${fields[19]}"
}

# Print flat JSON string-or-number field $2 from single-object record file $1.
# Deliberately narrow: it reads only the flat, machine-written session record,
# and any value that is not a plain token fails closed to no output.
#
# One subprocess per field, deliberately: the callers below run this on the Stop
# hot path, once per candidate registry record, so the first-match selection is
# done with a parameter expansion rather than a second process.
fm_claude_record_field() {  # <file> <key>
  local value
  value=$(sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$1" 2>/dev/null)
  value=${value%%$'\n'*}
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# True when THIS claimant's own Claude Code background job was created to
# CONTINUE the session that holds the lock - the only job shape a fork
# continuation can have. $1 is this claimant's session id and $2 the session id
# the recorded lock owner resolves to.
#
# Claude Code has exactly one background-session feature, `claude --bg`, and its
# own help calls what that starts a background agent. The same feature serves
# both a session the operator moved into the background and a worker seeded with
# its own task, and one code path gives both of them CLAUDE_JOB_DIR. So that
# variable identifies a job, never specifically a worker, and testing it alone
# left a backgrounded primary session permanently unable to re-claim its own home
# (2026-08-14 incident).
#
# The job's own record separates the two by construction: a job that resumed or
# forked an existing session names that session in resumeSessionId, while a
# task-seeded worker names its own id there. Three facts are required, because
# the record alone attributes nothing:
#
#   1. the record continues someone else at all (resumeSessionId != sessionId),
#      which is what refuses a task-seeded worker before any transcript is read;
#   2. the record is THIS claimant's own job, not one inherited through the
#      environment - CLAUDE_JOB_DIR is exported to every descendant process, so a
#      nested session started inside a backgrounded one reads its ANCESTOR's
#      record and would otherwise claim on evidence about a different session;
#   3. the session it continues is the one the lock actually records, so the
#      record cannot vouch for continuity with a session that is not the owner.
#
# A record that is absent, unreadable, malformed, self-naming, or about anyone
# other than this claimant and this lock owner fails closed into today's refusal.
#
# Binding the record to the recorded owner has one accepted consequence, and it is
# the deliberate safe edge of this boundary rather than an oversight to widen into
# chain-walking: a claimant more than ONE background fork removed from the
# recorded owner is refused, because its job record names the session it forked
# from rather than the one the lock holds - background A into B while the home is
# idle, then B into C, and C names B while the lock still names A. That binding is
# exactly what stops an inherited record vouching for a session that is not the
# owner, so this walks no chain: one `bin/fm-lock.sh` acquire from B removes the
# gap, and docs/watcher-continuity.md owns the operator-facing statement of it.
fm_claude_job_continues_another_session() {  # <own-session-id> <owner-session-id>
  local own_session=$1 owner_session=$2 dir=${CLAUDE_JOB_DIR:-} record own resumed
  [ -n "$dir" ] || return 1
  record="$dir/state.json"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  own=$(fm_claude_record_field "$record" sessionId) || return 1
  resumed=$(fm_claude_record_field "$record" resumeSessionId) || return 1
  case "$own$resumed" in
    *[!0-9a-fA-F-]*) return 1 ;;
  esac
  [ "$resumed" != "$own" ] || return 1
  [ "$own" = "$own_session" ] || return 1
  [ "$resumed" = "$owner_session" ]
}

# Print the Claude session id the harness registry vouches for live pid $1, or
# return 1. The record's own pid and process start time must both match the live
# process, so a recycled pid can never inherit a dead session's identity.
fm_claude_session_record_id() {  # <pid>
  local pid=$1 cfg record record_pid record_start live_start session_id
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  cfg=$(fm_claude_config_dir) || return 1
  record="$cfg/sessions/$pid.json"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  record_pid=$(fm_claude_record_field "$record" pid) || return 1
  [ "$record_pid" = "$pid" ] || return 1
  record_start=$(fm_claude_record_field "$record" procStart) || return 1
  live_start=$(fm_claude_proc_start "$pid") || return 1
  [ "$record_start" = "$live_start" ] || return 1
  session_id=$(fm_claude_record_field "$record" sessionId) || return 1
  case "$session_id" in
    ''|*[!0-9a-fA-F-]*) return 1 ;;
  esac
  printf '%s\n' "$session_id"
}

# True when live pid $2 is live pid $1 itself, or an ancestor of it reached
# without ever leaving one contiguous Claude harness run: the same relation
# fm_harness_ancestry_pids models for THIS process, evaluated for another.
#
# Every process on the walk must be a verified Claude harness process, so the
# walk can never cross a gap into an unrelated harness further up the real
# process tree, and no non-Claude harness is reachable through it at all.
fm_harness_run_hosts_pid() {  # <inner-pid> <outer-pid>
  local pid=$1 outer=$2 comm args
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$outer" in
    ''|*[!0-9]*) return 1 ;;
  esac
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    [ "$pid" = "$outer" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  return 1
}

# Print the Claude session id that live pid $1 is running, or return 1.
#
# The registry keys its records on the SESSION pid, while the session lock
# records the outermost pid of the contiguous harness run
# (fm_harness_ancestry_pid). Those are the same pid for an ordinary session, and
# different for one running in the background, whose run is headed by a
# `claude bg-pty-host` process the registry never records - the shape this
# fleet's own primary runs in. So the pid's own record answers when there is one,
# and otherwise the one live record whose session pid that run hosts does.
#
# Nothing is weakened by the second step: the walk stays inside one contiguous
# Claude run, so an unrelated live session is never reachable, and two session
# records inside one run is ambiguity rather than an answer - refused like every
# other unresolvable input here. A recorded owner the registry vouches for
# nowhere in its run keeps the unchanged refusal.
#
# The scan runs on the Stop hot path, exactly in the backgrounded-primary shape
# this fleet normally runs in, so candidates are discarded cheapest-first: a pid
# the registry left a record for but that no longer exists costs no subprocess at
# all, and one that is live but outside the run is rejected by the walk before
# its record is ever read. Only a candidate the run genuinely hosts pays for the
# record proof. Ordering the two conditions this way cannot change the outcome,
# because a candidate must satisfy both to be accepted.
#
# The run walk also requires the RECORDED pid itself to be a live Claude harness
# process, which is a property of that pid alone and so the same answer for every
# candidate. It is therefore tested once, on the first live candidate, rather
# than re-derived per candidate at the top of each walk: a lock recorded by a
# live codex, opencode, grok, kimi or pi primary - a supported configuration -
# would otherwise pay a whole ancestry walk per live record for a walk that
# cannot succeed, four times over on a single Stop. Testing it lazily keeps the
# no-live-candidate case free of subprocesses entirely.
#
# The scan is skipped outright where no record can be proven. Every candidate ends
# at fm_claude_session_record_id, which binds a record to one incarnation of a pid
# through fm_claude_proc_start and so refuses wherever /proc is absent - the same
# Linux-only limit fork recovery has by design. A host without it would otherwise
# walk the whole registry, and pay an ancestry walk per live candidate, to reach a
# refusal a single builtin read establishes up front. Testing the RECORDED pid's
# own entry is what makes that one read enough: the scan cannot succeed unless
# that pid is a live Claude process, which no unreadable /proc entry allows.
fm_claude_session_id_of_pid() {  # <pid>
  local pid=$1 cfg record candidate session_id found='' owner_verified=0
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_claude_session_record_id "$pid" && return 0
  [ -r "/proc/$pid/stat" ] || return 1
  cfg=$(fm_claude_config_dir) || return 1
  for record in "$cfg"/sessions/*.json; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    candidate=${record##*/}
    candidate=${candidate%.json}
    case "$candidate" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$candidate" != "$pid" ] || continue
    kill -0 "$candidate" 2>/dev/null || continue
    if [ "$owner_verified" -eq 0 ]; then
      fm_harness_pid_alive "$pid" || return 1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
      owner_verified=1
    fi
    fm_harness_run_hosts_pid "$candidate" "$pid" || continue
    session_id=$(fm_claude_session_record_id "$candidate") || continue
    [ -z "$found" ] || return 1
    found=$session_id
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Print the one transcript file recorded for Claude session id $1, or return 1.
# Ambiguity across project directories is treated as no answer.
fm_claude_transcript_of_session() {  # <session-id>
  local session_id=$1 cfg candidate found=''
  case "$session_id" in
    ''|*[!0-9a-fA-F-]*) return 1 ;;
  esac
  cfg=$(fm_claude_config_dir) || return 1
  for candidate in "$cfg"/projects/*/"$session_id.jsonl"; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    [ -z "$found" ] || return 1
    found=$candidate
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# True when transcript $2 is a STRICT extension of transcript $1: every message
# uuid in $1 appears at the same position in $2, and $2 carries at least one
# more. An empty ancestor proves nothing and is rejected, so is a $2 that merely
# equals $1 - two sessions with identical transcripts have no ancestor among
# them, and neither does a sibling fork, whose own post-fork uuids break the
# positional match in both directions.
fm_transcript_strictly_extends() {  # <ancestor-file> <descendant-file>
  [ -f "$1" ] && [ -f "$2" ] || return 1
  awk '
    function uuid_of(line,   value) {
      if (!match(line, /"uuid":"[0-9a-fA-F-]+"/)) return ""
      value = substr(line, RSTART + 8, RLENGTH - 9)
      return (length(value) == 36) ? value : ""
    }
    FNR == NR { u = uuid_of($0); if (u != "") ancestor[++a] = u; next }
    {
      u = uuid_of($0)
      if (u == "") next
      d++
      if (d <= a && ancestor[d] != u) { diverged = 1; exit }
    }
    END { exit (!diverged && a > 0 && d > a) ? 0 : 1 }
  ' "$1" "$2"
}

# --- published refusal evidence ----------------------------------------------
#
# The predicate below refuses for materially different reasons, and no command
# available to an operator separates them from the outside: `bin/fm-lock.sh
# status` prints the same live-pid line whether the recorded owner is a second
# session genuinely in use or this session's own displaced predecessor. The
# predicate is the only place that knows which sub-check refused, so it publishes
# that, and callers report it instead of asking the operator to establish what
# nothing they can run will tell them (2026-08-14 incident).
#
# FM_CLAUDE_FORK_EVIDENCE is one of:
#   no-session-identity   this process carries no Claude session id at all, so
#                         no continuity evidence can be produced.
#   owner-unresolved      no live Claude session record vouches for the recorded
#                         pid or for the harness run it heads. This says nothing
#                         about WHICH unvouched-for case it is, so a caller must
#                         report it as inconclusive; the one case it does rule
#                         out, a live owner that is not Claude at all, is
#                         published separately as owner-not-claude below.
#   owner-is-this-session the recorded owner resolves to this session's own id.
#   job-record-unproven   this claimant runs inside a background job whose record
#                         does not show it continues the recorded owner.
#   transcript-missing    a transcript needed for the comparison is unreadable.
#   transcript-diverged   the owner's transcript is not a strict prefix of this
#                         session's: it has taken turns of its own.
#   fork-proven           no refusal; descent was proven.
# FM_CLAUDE_FORK_OWNER_SESSION carries the owner's resolved session id, or is
# empty when the owner was never resolved.
FM_CLAUDE_FORK_EVIDENCE='no-session-identity'
FM_CLAUDE_FORK_OWNER_SESSION=''

# True when THIS process's Claude session provably descends, by fork, from the
# session that live pid $1 is running, and that source session has produced
# nothing since the fork.
#
# A session running inside a Claude Code background job may only claim when that
# job's own record shows this claimant continues this recorded owner, so a
# task-seeded worker, and a nested session reading an ancestor's inherited job
# record, are both refused before any transcript is read.
fm_claude_fork_descendant_of_pid() {  # <pid>
  local owner_pid=$1 own_session owner_session own_transcript owner_transcript
  FM_CLAUDE_FORK_EVIDENCE='no-session-identity'
  FM_CLAUDE_FORK_OWNER_SESSION=''
  own_session=${CLAUDE_CODE_SESSION_ID:-}
  case "$own_session" in
    ''|*[!0-9a-fA-F-]*) return 1 ;;
  esac
  FM_CLAUDE_FORK_EVIDENCE='owner-unresolved'
  owner_session=$(fm_claude_session_id_of_pid "$owner_pid") || return 1
  FM_CLAUDE_FORK_OWNER_SESSION=$owner_session
  FM_CLAUDE_FORK_EVIDENCE='owner-is-this-session'
  [ "$owner_session" != "$own_session" ] || return 1
  if [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    FM_CLAUDE_FORK_EVIDENCE='job-record-unproven'
    fm_claude_job_continues_another_session "$own_session" "$owner_session" || return 1
  fi
  FM_CLAUDE_FORK_EVIDENCE='transcript-missing'
  own_transcript=$(fm_claude_transcript_of_session "$own_session") || return 1
  owner_transcript=$(fm_claude_transcript_of_session "$owner_session") || return 1
  FM_CLAUDE_FORK_EVIDENCE='transcript-diverged'
  fm_transcript_strictly_extends "$owner_transcript" "$own_transcript" || return 1
  FM_CLAUDE_FORK_EVIDENCE='fork-proven'
}

# What the single deciding read in fm_session_lock_foreign_owner_alive() below
# saw, published so a caller's operator-facing message can never name a pid, a
# session, or a reason that decision did not use. The lock is read exactly once
# per call and every one of these comes from that read; a caller that re-read it
# for its banner could name whatever a third writer put there in between.
# FM_SESSION_LOCK_OWNER_PID is "unknown" for an absent or malformed lock, and
# FM_SESSION_LOCK_OWNER_EVIDENCE carries the FM_CLAUDE_FORK_EVIDENCE token above,
# with one token this predicate adds because only it holds the fact:
#
#   owner-not-claude      the recorded owner is a live VERIFIED harness process
#                         that is not Claude Code. The liveness check below
#                         already establishes this, and the fork walk cannot -
#                         it sees only that nothing resolved. Publishing it apart
#                         from owner-unresolved is what stops a caller telling a
#                         Claude session that a codex, opencode, grok, kimi or pi
#                         owner is probably its own displaced predecessor, which
#                         no displaced predecessor of a Claude session can be.
#                         It replaces EVERY token the fork walk can reach without
#                         resolving the owner - no-session-identity as well as
#                         owner-unresolved - because both of those describe only
#                         what the walk failed to learn, while the owner's kind is
#                         a fact already in hand. A claimant that carries no
#                         session id of its own still knows a non-Claude owner is
#                         no fork source of any Claude session.
# shellcheck disable=SC2034 # Read by the stood-down messages in bin/fm-turnend-guard.sh, not this lib.
FM_SESSION_LOCK_OWNER_PID=unknown
# shellcheck disable=SC2034 # Read by the stood-down messages in bin/fm-turnend-guard.sh, not this lib.
FM_SESSION_LOCK_OWNER_SESSION=''
# shellcheck disable=SC2034 # Read by the stood-down messages in bin/fm-turnend-guard.sh, not this lib.
FM_SESSION_LOCK_OWNER_EVIDENCE='owner-unresolved'

# True when state dir $1's session lock is held by a LIVE harness process that
# is not this process's own ancestry AND is not this session's proven fork
# source: the state in which this session cannot show the home is its own, so its
# Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) stays inert rather than
# contesting the recorded owner. Callers must not report that owner as a proven
# second session: an unproven fork source lands here too, and the 2026-08-14
# incident was an evening of turn-end blocks asserting exactly that - report the
# published evidence above instead.
# False for a missing/malformed lock and false for a dead recorded owner - both
# remain this caller's own uncertainty or stale-owner cases to handle, not a
# foreign live owner.
# shellcheck disable=SC2034 # The FM_SESSION_LOCK_OWNER_* globals it publishes are read by bin/fm-turnend-guard.sh, not this lib.
fm_session_lock_foreign_owner_alive() {
  local state=$1 lock_pid owner_is_claude
  FM_SESSION_LOCK_OWNER_PID='unknown'
  FM_SESSION_LOCK_OWNER_SESSION=''
  FM_SESSION_LOCK_OWNER_EVIDENCE='owner-unresolved'
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  FM_SESSION_LOCK_OWNER_PID=$lock_pid
  fm_harness_ancestry_contains_pid "$lock_pid" && return 1
  fm_harness_pid_alive "$lock_pid" || return 1
  owner_is_claude=$FM_HARNESS_IS_CLAUDE
  fm_claude_fork_descendant_of_pid "$lock_pid" && return 1
  FM_SESSION_LOCK_OWNER_SESSION=$FM_CLAUDE_FORK_OWNER_SESSION
  FM_SESSION_LOCK_OWNER_EVIDENCE=$FM_CLAUDE_FORK_EVIDENCE
  if [ "$owner_is_claude" -eq 0 ]; then
    case "$FM_SESSION_LOCK_OWNER_EVIDENCE" in
      owner-unresolved|no-session-identity) FM_SESSION_LOCK_OWNER_EVIDENCE='owner-not-claude' ;;
    esac
  fi
  return 0
}
