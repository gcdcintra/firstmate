#!/usr/bin/env bash
# fm-branch-watch-lib.sh - the durable cursor for "is this project's default
# branch green or red right now?", shared by the poll that produces it
# (bin/fm-branch-poll.sh) and the consumers that read it.
#
# Why a cursor exists at all. Firstmate polls a task's own pull request until it
# is green and then stops: the moment work merges, nothing looks at the default
# branch again, so a merge that breaks it stays invisible until a human trips
# over it or the next feature inherits the breakage and misreads it as its own.
# The cursor is what turns "the branch is red" into "the branch JUST went red,
# and here is the commit that did it".
#
# Record layout, one field per line, exactly ten lines:
#   1  fm-branch-watch-v1     version tag; anything else is refused, not guessed
#   2  project                the clone's directory name under <home>/projects
#   3  owner/repo             resolved from the clone's origin remote only
#   4  branch                 the default branch this state describes
#   5  green|red              the settled verdict for line 6's commit
#   6  sha                    the assessed commit, 40 lowercase hex
#   7  run                    forge run id behind a red verdict, or "-"
#   8  last_green             newest green commit older than line 6, or "-"
#   9  yes|no                 whether line 5's verdict was already surfaced
#  10  observed               unix epoch of the observation
#
# Field 9 is the durability boundary. The poll records a red verdict as
# unsurfaced and only bin/fm-branch-poll.sh --ack <key>... marks it surfaced,
# after the caller has committed that exact record's wake to the durable queue.
# A watcher that dies between the two therefore re-emits the same line on its
# next sweep: one duplicate notification is the cheap failure, a silently
# swallowed red default branch is the expensive one this whole mechanism exists
# to prevent. The acknowledgement names the records it delivered for the same
# reason: a blanket ack would mark a verdict from an earlier sweep delivered
# when nothing ever carried it, which is that same swallowed red by another
# route.
#
# The sweep's own cursor is a second record, state/branch-watch/.sweep, ten
# lines and one per line:
#   1  fm-branch-sweep-v6     version tag; anything else is refused, not guessed
#   2  resume                 last project the previous pass ATTEMPTED, or "-"
#   3  unreached              projects that pass never reached, space-joined, or "-"
#   4  failed                 projects it reached whose forge query would not answer
#   5  fleet                  the project list lines 7 and 8 were measured on
#   6  yes|no                 whether line 5's truncation notice was surfaced
#   7  watermark              the worst pass count DELIVERED for line 5's fleet, or "-"
#   8  delivered              "<project>:<streak>" per failed query already
#                             DELIVERED, streak being its consecutive answered
#                             queries since, or "-"
#   9  failing                projects whose most recent ATTEMPT failed its query
#  10  observed               unix epoch of the observation
# Line 2 is what makes a fleet too large for one pass lose a rotating slice
# instead of the same tail forever, so it is written before each attempt rather
# than after: a pass killed mid-project must not send every later pass back into
# the same stall. Lines 3 and 4 always describe the pass that is running, so a
# pass killed before it could report still leaves an honest gap behind rather
# than the previous pass's cleaner one.
#
# Lines 3 and 4 are both gaps in coverage and neither is the other: line 3 was
# never attempted and rotation reaches it next pass, while line 4 was attempted
# and the forge would not answer, which rotation cannot fix. Both are subtracted
# from the count of projects a pass actually assessed.
#
# Lines 5, 7 and 8 together are the suppression key, and line 6 is the same
# durability boundary as field 9 above. Line 7 holds a count of passes, not a
# timestamp or a flag: coverage that gets WORSE than anything already delivered
# is news and speaks up again, coverage that merely recovers is not.
#
# Line 8 exists because line 7 cannot see the difference line 4 draws. A pass
# count collapses a bounded rotation gap and a permanent query failure into one
# number, so a fleet already reported at some pass count can start failing
# queries without that number moving at all, and the failure would never be
# said out loud. Line 8 is compared as a SET, not as a signature: a failure that
# is not already in it is news, and one that is already in it is not. Unlike the
# rotation gap, which churns every pass by construction, this set is stable
# exactly while the fault lasts, so keying on it cannot wake every sweep.
#
# Membership alone would only ever grow, and a set that never forgets converges
# on forgiving the whole fleet: one transient blip would inoculate a project
# against ever reporting the permanent failure that arrives later, which is the
# case this disclosure exists to catch. So each entry carries how many
# consecutive queries have been ANSWERED for that project since, and an entry
# leaves once that reaches FM_BW_FORGET_AFTER. A failed query resets its own
# entry to zero. A project a pass never attempted is left exactly as it was:
# not looking at something is not evidence that it recovered, and crediting it
# would let a truncated fleet forget failures it never even queried.
#
# The streak is observation, not delivery, so it moves on the ordinary pass
# write. Only membership is delivery state: it grows solely at the
# acknowledgement, never at the write that produces the notice, because that is
# what an undelivered report must not be able to silence. The streak is exempt
# because it only ever REMOVES entries, which makes a failure more visible
# rather than less - the direction that needs no delivery gate. Line 9 is
# observation for the same reason and is never gated on delivery either.
#
# Line 9 answers a different question from line 8 and cannot be derived from it:
# "is this project's query failing RIGHT NOW", which is what a status display
# must not get wrong. Line 8 deliberately lags - it holds an entry for several
# answered queries after recovery so a notice does not flap, and it never holds
# a failure whose notice was not delivered. Both are correct for deciding
# whether to speak; both would be wrong for describing the present. So line 9
# tracks the outcome of each project's most recent ATTEMPT: a failed query puts
# it in, the first answered query takes it out, and a pass that never attempted
# it changes nothing. It keys no notice - waking on it would report every
# recover-and-fail-again flap, which is precisely what line 8's patience exists
# to avoid.
#
# The record is data, never authority: nothing here is interpolated into shell
# source, and every field is revalidated on read rather than trusted from disk.

# shellcheck disable=SC2034  # the FM_BW_* globals below are this library's whole
# output contract: fm_bw_read fills them for the sourcing script to read, so none
# of them is consumed inside this file.
FM_BW_VERSION=fm-branch-watch-v1
FM_BW_PROJECT=
FM_BW_REPO=
FM_BW_BRANCH=
FM_BW_STATE=
FM_BW_SHA=
FM_BW_RUN=
FM_BW_LAST_GREEN=
FM_BW_SURFACED=
FM_BW_OBSERVED=

FM_BW_SWEEP_VERSION=fm-branch-sweep-v6
# How many consecutive answered queries retire a project from the delivered
# failure set, so its next failure is news again rather than pre-forgiven.
FM_BW_FORGET_AFTER=4
# The sweep's own record is addressed by a key that is deliberately outside the
# project-name charset, so the truncation notice can never share a durable wake
# key with a project called anything at all - two records under one key collapse
# on drain, and that collapse is exactly the loss this feature already had to fix.
FM_BW_SWEEP_KEY=:sweep
FM_BW_SWEEP_RESUME=
FM_BW_SWEEP_UNREACHED=
FM_BW_SWEEP_FAILED=
FM_BW_SWEEP_FLEET=
FM_BW_SWEEP_SURFACED=
FM_BW_SWEEP_WATERMARK=
FM_BW_SWEEP_DELIVERED=
FM_BW_SWEEP_FAILING=
FM_BW_SWEEP_OBSERVED=

# A project name addresses a directory under <home>/projects and a file under
# state/branch-watch, so it carries the same path-safety class firstmate applies
# to task ids: no empty name, no leading dot, no separator, no shell metacharacter.
fm_bw_project_valid() {
  local name=${1-}
  local LC_ALL=C
  case "$name" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#name}" -le 128 ]
}

fm_bw_dir() {
  printf '%s/branch-watch\n' "$1"
}

fm_bw_record_path() {
  printf '%s/branch-watch/%s\n' "$1" "$2"
}

fm_bw_sweep_path() {
  printf '%s/branch-watch/.sweep\n' "$1"
}

# A space-joined list of project names, or "-" for none. Parsed by hand rather
# than by word splitting so a list read back from disk can never expand into a
# glob or an empty element that silently passes as valid.
fm_bw_list_valid() {
  local list=${1-} name rest
  [ "$list" != - ] || return 0
  [ -n "$list" ] || return 1
  rest=$list
  while [ -n "$rest" ]; do
    name=${rest%% *}
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) rest= ;;
    esac
    fm_bw_project_valid "$name" || return 1
  done
}

# Every name in <a> also appears in <b>. An empty set is a subset of anything,
# and "-" holds nothing, so a non-empty set is never a subset of it.
fm_bw_list_subset() {
  local a=${1-} b=${2-} name rest
  [ "$a" != - ] && [ -n "$a" ] || return 0
  rest=$a
  while [ -n "$rest" ]; do
    name=${rest%% *}
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) rest= ;;
    esac
    case " $b " in
      *" $name "*) ;;
      *) return 1 ;;
    esac
  done
}

# The delivered set: "-" or space-joined "<project>:<streak>" tokens. The colon
# is outside the project-name charset, so a token can never be read two ways.
fm_bw_delivered_valid() {
  local field=${1-} tok rest name count
  [ "$field" != - ] || return 0
  [ -n "$field" ] || return 1
  rest=$field
  while [ -n "$rest" ]; do
    tok=${rest%% *}
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) rest= ;;
    esac
    name=${tok%%:*}
    count=${tok#*:}
    [ "$name" != "$tok" ] || return 1
    fm_bw_project_valid "$name" || return 1
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#count}" -le 3 ] || return 1
  done
}

# Just the names, which is what the subset comparison is about.
fm_bw_delivered_names() {
  local field=${1-} tok rest out
  out=''
  [ "$field" != - ] && [ -n "$field" ] || { printf '%s\n' -; return 0; }
  rest=$field
  while [ -n "$rest" ]; do
    tok=${rest%% *}
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) rest= ;;
    esac
    out="${out:+$out }${tok%%:*}"
  done
  printf '%s\n' "${out:--}"
}

# fm_bw_delivered_advance <delivered> <fleet> <unreached> <failed>
# One pass's observations. A project this pass asked about and got an answer for
# moves one step toward being forgotten and leaves at FM_BW_FORGET_AFTER; one
# whose query failed goes back to zero; one this pass never attempted is left
# untouched, because not asking is not evidence of recovery.
fm_bw_delivered_advance() {
  local delivered=${1-} fleet=${2-} unreached=${3-} failed=${4-}
  local tok rest name count out
  out=''
  [ "$delivered" != - ] && [ -n "$delivered" ] || { printf '%s\n' -; return 0; }
  rest=$delivered
  while [ -n "$rest" ]; do
    tok=${rest%% *}
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) rest= ;;
    esac
    name=${tok%%:*}
    count=${tok#*:}
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    if fm_bw_list_subset "$name" "$failed"; then
      count=0
    elif fm_bw_list_subset "$name" "$unreached"; then
      :
    elif fm_bw_list_subset "$name" "$fleet"; then
      count=$((count + 1))
      [ "$count" -lt "$FM_BW_FORGET_AFTER" ] || continue
    fi
    out="${out:+$out }$name:$count"
  done
  printf '%s\n' "${out:--}"
}

# fm_bw_delivered_add <delivered> <failed>: a failure joins at a zero streak the
# moment its notice is delivered, and one already there keeps the streak it has.
fm_bw_delivered_add() {
  local delivered=${1-} failed=${2-} rest name out names
  out=''
  [ "$delivered" = - ] || out=$delivered
  names=$(fm_bw_delivered_names "$delivered")
  if [ "$failed" != - ] && [ -n "$failed" ]; then
    rest=$failed
    while [ -n "$rest" ]; do
      name=${rest%% *}
      case "$rest" in
        *' '*) rest=${rest#* } ;;
        *) rest= ;;
      esac
      fm_bw_list_subset "$name" "$names" || out="${out:+$out }$name:0"
    done
  fi
  printf '%s\n' "${out:--}"
}

fm_bw_list_count() {
  local list=${1-} rest n=0
  [ "$list" != - ] && [ -n "$list" ] || { printf '0\n'; return 0; }
  rest=$list
  while [ -n "$rest" ]; do
    n=$((n + 1))
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) rest= ;;
    esac
  done
  printf '%s\n' "$n"
}

# Enabled unless config/branch-watch says "off". A watchdog whose configuration
# is unreadable or misspelled must keep watching rather than go quiet, so only
# the exact opt-out disables it.
fm_bw_enabled() {
  local config=${1-} file value
  file="$config/branch-watch"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS= read -r value < "$file" 2>/dev/null || return 0
  case "$value" in
    off|OFF|Off) return 1 ;;
  esac
  return 0
}

fm_bw_sha_valid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[0-9a-f]{40}$ ]]
}

# A forge run id, or "-" when the verdict is green and no run is under suspicion.
fm_bw_run_valid() {
  local run=${1-}
  case "$run" in
    -) return 0 ;;
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#run}" -le 32 ]
}

fm_bw_short() {
  local sha=${1-}
  case "$sha" in
    -|'') printf 'none\n' ;;
    *) printf '%s\n' "${sha:0:7}" ;;
  esac
}

# A branch name is used only as a `gh` argument and as display text, never as a
# path, but it still must not smuggle whitespace or an option-looking leading
# dash into either.
fm_bw_branch_valid() {
  local branch=${1-}
  local LC_ALL=C
  case "$branch" in
    ''|-*|*[[:space:]]*|*'..'*) return 1 ;;
  esac
  [ "${#branch}" -le 255 ]
}

fm_bw_read() {
  local state=$1 project=$2 file version p repo branch verdict sha run last_green surfaced observed extra
  FM_BW_PROJECT=
  FM_BW_REPO=
  FM_BW_BRANCH=
  FM_BW_STATE=
  FM_BW_SHA=
  FM_BW_RUN=
  FM_BW_LAST_GREEN=
  FM_BW_SURFACED=
  FM_BW_OBSERVED=
  fm_bw_project_valid "$project" || return 1
  file=$(fm_bw_record_path "$state" "$project")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r version <&6 || { exec 6<&-; return 1; }
  IFS= read -r p <&6 || { exec 6<&-; return 1; }
  IFS= read -r repo <&6 || { exec 6<&-; return 1; }
  IFS= read -r branch <&6 || { exec 6<&-; return 1; }
  IFS= read -r verdict <&6 || { exec 6<&-; return 1; }
  IFS= read -r sha <&6 || { exec 6<&-; return 1; }
  IFS= read -r run <&6 || { exec 6<&-; return 1; }
  IFS= read -r last_green <&6 || { exec 6<&-; return 1; }
  IFS= read -r surfaced <&6 || { exec 6<&-; return 1; }
  IFS= read -r observed <&6 || { exec 6<&-; return 1; }
  if IFS= read -r extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$version" = "$FM_BW_VERSION" ] || return 1
  [ "$p" = "$project" ] || return 1
  fm_bw_branch_valid "$branch" || return 1
  case "$verdict" in green|red) ;; *) return 1 ;; esac
  fm_bw_sha_valid "$sha" || return 1
  fm_bw_run_valid "$run" || return 1
  [ "$last_green" = - ] || fm_bw_sha_valid "$last_green" || return 1
  case "$surfaced" in yes|no) ;; *) return 1 ;; esac
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  FM_BW_PROJECT=$project
  FM_BW_REPO=$repo
  FM_BW_BRANCH=$branch
  FM_BW_STATE=$verdict
  FM_BW_SHA=$sha
  FM_BW_RUN=$run
  FM_BW_LAST_GREEN=$last_green
  FM_BW_SURFACED=$surfaced
  FM_BW_OBSERVED=$observed
}

# fm_bw_publish <dir> <file> <content>: atomic replace through a private temp
# file on the same device, so a reader never sees a half-written cursor and a
# crash never leaves a truncated one. <content> is written with exactly one
# trailing newline, which is what command substitution strips from every caller.
#
# The umask is restored before returning. This library is sourced by long-lived
# scripts (bin/fm-spawn.sh), and a 077 left behind would silently privatize
# every file the caller creates for the rest of its run.
fm_bw_publish() {
  local dir=$1 file=$2 content=$3 tmp old_umask rc
  [ ! -L "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ ! -L "$file" ] || return 1
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$dir/.fm-branch-watch.XXXXXX")
  rc=$?
  umask "$old_umask"
  [ "$rc" = 0 ] || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# fm_bw_write <state> <project> <repo> <branch> <verdict> <sha> <run> <last_green> <surfaced> <observed>
fm_bw_write() {
  local state=$1 project=$2 repo=$3 branch=$4 verdict=$5 sha=$6 run=$7 last_green=$8 surfaced=$9 observed=${10}
  local dir file
  # Validate exactly what fm_bw_read demands, so a record this writes can never
  # be one the reader then refuses: a project whose cursor is unreadable reads
  # as never-observed and would re-announce its red on every single sweep.
  fm_bw_project_valid "$project" || return 1
  case "$verdict" in green|red) ;; *) return 1 ;; esac
  case "$surfaced" in yes|no) ;; *) return 1 ;; esac
  fm_bw_branch_valid "$branch" || return 1
  fm_bw_sha_valid "$sha" || return 1
  fm_bw_run_valid "$run" || return 1
  [ "$last_green" = - ] || fm_bw_sha_valid "$last_green" || return 1
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  dir=$(fm_bw_dir "$state")
  file=$(fm_bw_record_path "$state" "$project")
  fm_bw_publish "$dir" "$file" "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    "$FM_BW_VERSION" "$project" "$repo" "$branch" "$verdict" "$sha" \
    "$run" "$last_green" "$surfaced" "$observed")"
}

# A pass count: how many passes this fleet needs at the coverage last seen.
# "-" means none has been delivered yet, which reads as "surface the next one".
fm_bw_watermark_valid() {
  local mark=${1-}
  case "$mark" in
    -) return 0 ;;
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  [ "${#mark}" -le 12 ]
}

# fm_bw_failing_update <failing> <fleet> <unreached> <failed>
# Which projects a status display must not present a stored verdict for. The
# outcome of the most recent ATTEMPT and nothing else: a query that failed puts a
# project in, the first query that answers takes it straight out, and a pass that
# never attempted it leaves it exactly as it was. No delivery gate and no
# patience, because both of those are right for deciding whether to speak and
# wrong for saying what is true now.
fm_bw_failing_update() {
  local failing=${1-} fleet=${2-} unreached=${3-} failed=${4-} name rest out
  out=''
  [ "$failed" = - ] || out=$failed
  if [ "$failing" != - ] && [ -n "$failing" ]; then
    rest=$failing
    while [ -n "$rest" ]; do
      name=${rest%% *}
      case "$rest" in
        *' '*) rest=${rest#* } ;;
        *) rest= ;;
      esac
      fm_bw_list_subset "$name" "$unreached" || continue
      fm_bw_list_subset "$name" "$fleet" || continue
      case " $out " in
        *" $name "*) ;;
        *) out="${out:+$out }$name" ;;
      esac
    done
  fi
  printf '%s\n' "${out:--}"
}

fm_bw_sweep_read() {
  local state=$1 file version resume unreached failed fleet surfaced watermark delivered failing observed extra
  FM_BW_SWEEP_RESUME=
  FM_BW_SWEEP_UNREACHED=
  FM_BW_SWEEP_FAILED=
  FM_BW_SWEEP_FLEET=
  FM_BW_SWEEP_SURFACED=
  FM_BW_SWEEP_WATERMARK=
  FM_BW_SWEEP_DELIVERED=
  FM_BW_SWEEP_FAILING=
  FM_BW_SWEEP_OBSERVED=
  file=$(fm_bw_sweep_path "$state")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r version <&6 || { exec 6<&-; return 1; }
  IFS= read -r resume <&6 || { exec 6<&-; return 1; }
  IFS= read -r unreached <&6 || { exec 6<&-; return 1; }
  IFS= read -r failed <&6 || { exec 6<&-; return 1; }
  IFS= read -r fleet <&6 || { exec 6<&-; return 1; }
  IFS= read -r surfaced <&6 || { exec 6<&-; return 1; }
  IFS= read -r watermark <&6 || { exec 6<&-; return 1; }
  IFS= read -r delivered <&6 || { exec 6<&-; return 1; }
  IFS= read -r failing <&6 || { exec 6<&-; return 1; }
  IFS= read -r observed <&6 || { exec 6<&-; return 1; }
  if IFS= read -r extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$version" = "$FM_BW_SWEEP_VERSION" ] || return 1
  [ "$resume" = - ] || fm_bw_project_valid "$resume" || return 1
  fm_bw_list_valid "$unreached" || return 1
  fm_bw_list_valid "$failed" || return 1
  fm_bw_list_valid "$fleet" || return 1
  case "$surfaced" in yes|no) ;; *) return 1 ;; esac
  fm_bw_watermark_valid "$watermark" || return 1
  fm_bw_delivered_valid "$delivered" || return 1
  fm_bw_list_valid "$failing" || return 1
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  FM_BW_SWEEP_RESUME=$resume
  FM_BW_SWEEP_UNREACHED=$unreached
  FM_BW_SWEEP_FAILED=$failed
  FM_BW_SWEEP_FLEET=$fleet
  FM_BW_SWEEP_SURFACED=$surfaced
  FM_BW_SWEEP_WATERMARK=$watermark
  FM_BW_SWEEP_DELIVERED=$delivered
  FM_BW_SWEEP_FAILING=$failing
  FM_BW_SWEEP_OBSERVED=$observed
}

# fm_bw_sweep_write <state> <resume> <unreached> <failed> <fleet> <surfaced> <watermark> <delivered> <failing> <observed>
fm_bw_sweep_write() {
  local state=$1 resume=$2 unreached=$3 failed=$4 fleet=$5 surfaced=$6 watermark=$7
  local delivered=$8 failing=$9 observed=${10}
  local dir file
  # Validate exactly what fm_bw_sweep_read demands. A cursor this writes but the
  # reader then refuses would restart every pass at the beginning, which quietly
  # reinstates the fixed blind spot the rotation exists to remove.
  [ "$resume" = - ] || fm_bw_project_valid "$resume" || return 1
  fm_bw_list_valid "$unreached" || return 1
  fm_bw_list_valid "$failed" || return 1
  fm_bw_list_valid "$fleet" || return 1
  case "$surfaced" in yes|no) ;; *) return 1 ;; esac
  fm_bw_watermark_valid "$watermark" || return 1
  fm_bw_delivered_valid "$delivered" || return 1
  fm_bw_list_valid "$failing" || return 1
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  dir=$(fm_bw_dir "$state")
  file=$(fm_bw_sweep_path "$state")
  fm_bw_publish "$dir" "$file" "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    "$FM_BW_SWEEP_VERSION" "$resume" "$unreached" "$failed" "$fleet" "$surfaced" \
    "$watermark" "$delivered" "$failing" "$observed")"
}

# How many passes a fleet of <fleet> needs at the coverage a pass achieved, where
# <unreached> was never attempted and <failed> was attempted but the forge would
# not answer. Neither counts as assessed. A pass that assessed none of the fleet -
# which also covers a record whose lists cannot be reconciled - has no finite
# answer and is reported as one worse than the worst finite one, so it always
# counts as degraded rather than dividing by zero or passing for complete.
fm_bw_pass_count() {
  local fleet=${1-} unreached=${2-} failed=${3-} total missed reached
  total=$(fm_bw_list_count "$fleet")
  missed=$(( $(fm_bw_list_count "$unreached") + $(fm_bw_list_count "$failed") ))
  reached=$((total - missed))
  if [ "$total" -le 0 ] || [ "$reached" -le 0 ]; then
    printf '%s\n' "$((total + 1))"
    return 0
  fi
  printf '%s\n' "$(( (total + reached - 1) / reached ))"
}
