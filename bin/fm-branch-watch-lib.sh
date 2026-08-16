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
# unsurfaced and only bin/fm-branch-poll.sh --ack marks it surfaced, after the
# caller has committed the wake to the durable queue. A watcher that dies
# between the two therefore re-emits the same line on its next sweep: one
# duplicate notification is the cheap failure, a silently swallowed red default
# branch is the expensive one this whole mechanism exists to prevent.
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
  case "$run" in -|[1-9]*) ;; *) return 1 ;; esac
  case "$run" in *[!0-9-]*) return 1 ;; esac
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

# fm_bw_write <state> <project> <repo> <branch> <verdict> <sha> <run> <last_green> <surfaced> <observed>
# Atomic replace through a private temp file on the same device, so a reader
# never sees a half-written cursor and a crash never leaves a truncated one.
fm_bw_write() {
  local state=$1 project=$2 repo=$3 branch=$4 verdict=$5 sha=$6 run=$7 last_green=$8 surfaced=$9 observed=${10}
  local dir file tmp
  fm_bw_project_valid "$project" || return 1
  case "$verdict" in green|red) ;; *) return 1 ;; esac
  case "$surfaced" in yes|no) ;; *) return 1 ;; esac
  fm_bw_sha_valid "$sha" || return 1
  dir=$(fm_bw_dir "$state")
  [ ! -L "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  file=$(fm_bw_record_path "$state" "$project")
  [ ! -L "$file" ] || return 1
  umask 077
  tmp=$(mktemp "$dir/.fm-branch-watch.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      "$FM_BW_VERSION" "$project" "$repo" "$branch" "$verdict" "$sha" \
      "$run" "$last_green" "$surfaced" "$observed" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}
