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

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
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
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
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

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
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
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r line < "/proc/$pid/stat" 2>/dev/null || return 1
  # Strip "<pid> (<comm>) ", whose comm may itself contain spaces and parens.
  # Nothing after it contains a parenthesis, so the last ") " is comm's close.
  rest=${line##*") "}
  [ "$rest" != "$line" ] || return 1
  printf '%s\n' "$rest" | awk 'NF >= 20 { print $20 }'
}

# Print flat JSON string-or-number field $2 from single-object record file $1.
# Deliberately narrow: it reads only the flat, machine-written session record,
# and any value that is not a plain token fails closed to no output.
fm_claude_record_field() {  # <file> <key>
  local value
  value=$(sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$1" 2>/dev/null | head -1)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# Print the Claude session id that live pid $1 is running, proven by the
# harness's own registry, or return 1. The record's own pid and process start
# time must both match the live process, so a recycled pid can never inherit a
# dead session's identity.
fm_claude_session_id_of_pid() {  # <pid>
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

# True when THIS process's Claude session provably descends, by fork, from the
# session that live pid $1 is running, and that source session has produced
# nothing since the fork.
#
# A background agent is excluded outright: Claude Code forks the captain's live
# session to seed one, so it would otherwise satisfy the transcript proof while
# being a genuinely separate worker that must never take the home.
fm_claude_fork_descendant_of_pid() {  # <pid>
  local owner_pid=$1 own_session owner_session own_transcript owner_transcript
  [ -z "${CLAUDE_JOB_DIR:-}" ] || return 1
  own_session=${CLAUDE_CODE_SESSION_ID:-}
  case "$own_session" in
    ''|*[!0-9a-fA-F-]*) return 1 ;;
  esac
  owner_session=$(fm_claude_session_id_of_pid "$owner_pid") || return 1
  [ "$owner_session" != "$own_session" ] || return 1
  own_transcript=$(fm_claude_transcript_of_session "$own_session") || return 1
  owner_transcript=$(fm_claude_transcript_of_session "$owner_session") || return 1
  fm_transcript_strictly_extends "$owner_transcript" "$own_transcript"
}

# True when state dir $1's session lock is held by a LIVE harness process that
# is not this process's own ancestry AND is not this session's proven fork
# source: the state in which recovery genuinely belongs to that other session,
# so this session's own Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh)
# correctly stays inert rather than contesting it. False for a missing/malformed
# lock and false for a dead recorded owner - both remain this caller's own
# uncertainty or stale-owner cases to handle, not a foreign live owner.
fm_session_lock_foreign_owner_alive() {
  local state=$1 lock_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_session_lock_owned_by_self "$state" && return 1
  fm_harness_pid_alive "$lock_pid" || return 1
  ! fm_claude_fork_descendant_of_pid "$lock_pid"
}
