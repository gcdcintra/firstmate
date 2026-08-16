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
# The sweep's own cursor is a second record, state/branch-watch/.sweep, six
# lines and one per line:
#   1  fm-branch-sweep-v1     version tag; anything else is refused, not guessed
#   2  resume                 last project the previous pass ATTEMPTED, or "-"
#   3  unreached              projects that pass never reached, space-joined, or "-"
#   4  fleet                  the project list whose truncation was last reported
#   5  yes|no                 whether line 4's truncation notice was surfaced
#   6  observed               unix epoch of the observation
# Line 2 is what makes a fleet too large for one pass lose a rotating slice
# instead of the same tail forever, so it is written before each attempt rather
# than after: a pass killed mid-project must not send every later pass back into
# the same stall. Line 4 is the suppression key, and line 5 is the same
# durability boundary as field 9 above.
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

FM_BW_SWEEP_VERSION=fm-branch-sweep-v1
# The sweep's own record is addressed by a key that is deliberately outside the
# project-name charset, so the truncation notice can never share a durable wake
# key with a project called anything at all - two records under one key collapse
# on drain, and that collapse is exactly the loss this feature already had to fix.
FM_BW_SWEEP_KEY=:sweep
FM_BW_SWEEP_RESUME=
FM_BW_SWEEP_UNREACHED=
FM_BW_SWEEP_FLEET=
FM_BW_SWEEP_SURFACED=
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

fm_bw_sweep_read() {
  local state=$1 file version resume unreached fleet surfaced observed extra
  FM_BW_SWEEP_RESUME=
  FM_BW_SWEEP_UNREACHED=
  FM_BW_SWEEP_FLEET=
  FM_BW_SWEEP_SURFACED=
  FM_BW_SWEEP_OBSERVED=
  file=$(fm_bw_sweep_path "$state")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r version <&6 || { exec 6<&-; return 1; }
  IFS= read -r resume <&6 || { exec 6<&-; return 1; }
  IFS= read -r unreached <&6 || { exec 6<&-; return 1; }
  IFS= read -r fleet <&6 || { exec 6<&-; return 1; }
  IFS= read -r surfaced <&6 || { exec 6<&-; return 1; }
  IFS= read -r observed <&6 || { exec 6<&-; return 1; }
  if IFS= read -r extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$version" = "$FM_BW_SWEEP_VERSION" ] || return 1
  [ "$resume" = - ] || fm_bw_project_valid "$resume" || return 1
  fm_bw_list_valid "$unreached" || return 1
  fm_bw_list_valid "$fleet" || return 1
  case "$surfaced" in yes|no) ;; *) return 1 ;; esac
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  FM_BW_SWEEP_RESUME=$resume
  FM_BW_SWEEP_UNREACHED=$unreached
  FM_BW_SWEEP_FLEET=$fleet
  FM_BW_SWEEP_SURFACED=$surfaced
  FM_BW_SWEEP_OBSERVED=$observed
}

# fm_bw_sweep_write <state> <resume> <unreached> <fleet> <surfaced> <observed>
fm_bw_sweep_write() {
  local state=$1 resume=$2 unreached=$3 fleet=$4 surfaced=$5 observed=$6
  local dir file
  # Validate exactly what fm_bw_sweep_read demands. A cursor this writes but the
  # reader then refuses would restart every pass at the beginning, which quietly
  # reinstates the fixed blind spot the rotation exists to remove.
  [ "$resume" = - ] || fm_bw_project_valid "$resume" || return 1
  fm_bw_list_valid "$unreached" || return 1
  fm_bw_list_valid "$fleet" || return 1
  case "$surfaced" in yes|no) ;; *) return 1 ;; esac
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  dir=$(fm_bw_dir "$state")
  file=$(fm_bw_sweep_path "$state")
  fm_bw_publish "$dir" "$file" "$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    "$FM_BW_SWEEP_VERSION" "$resume" "$unreached" "$fleet" "$surfaced" "$observed")"
}
