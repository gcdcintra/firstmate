#!/usr/bin/env bash
# One sweep of every cloned project's DEFAULT branch, answering the question
# nothing else in firstmate asks: did the branch we merge onto just go red?
#
# The watcher invokes this trusted repository script directly on its own slow
# cadence. Its contract is the same as every other poll: print one line and
# firstmate wakes, print nothing and the fleet keeps sleeping. Every failure
# path is silent, so an unreachable forge is never mistaken for a broken branch.
#
# WHY THE WAKE CARRIES EVIDENCE, NOT A BADGE
# A red default branch has at least two causes that look identical in the
# conclusion field: a check that ran and failed (a real regression), and a check
# that never started at all (a billing lapse, a revoked runner, a workflow that
# would not parse). On 2026-08-15 this fleet read a red badge, diagnosed a code
# regression, and was wrong: the jobs had died in about two seconds having run
# zero steps. Step count and duration separate the two instantly, so the wake
# carries them inline and never reports the conclusion alone.
#
# ASSESSMENT MODEL
# Runs on the default branch are grouped by commit, newest first. A commit whose
# runs have not all completed is still settling and is skipped, so work in
# progress never wakes anything. The newest fully-settled commit is the verdict:
# red if any of its runs concluded failure, timed_out, or startup_failure; green
# if none did and at least one succeeded; otherwise indeterminate and skipped
# too (a commit whose only runs were cancelled or awaiting approval is neither a
# regression nor a pass). Scanning continues past a red verdict to find the
# newest green commit behind it, which is what makes the suspect merge nameable.
#
# WAKE POLICY
# Green records and stays quiet. Red wakes once per red commit: a new red commit
# wakes again, the same red commit does not. A project observed red on its very
# first sweep wakes too, worded as a first observation rather than a transition,
# because arming a watch on an already-broken branch and then saying nothing
# would reproduce the exact silence this exists to end. Recovery to green is
# recorded but does not wake - it clears the pre-launch advisory instead.
#
# NOT COVERED, deliberately. Each of these is a real limit, not an oversight:
#   - projects with no origin remote, and projects whose origin is not GitHub
#     (bin/fm-gh-lib.sh refuses rather than guessing, and this skips them);
#   - forks: the origin remote is the only remote read, so a fork is watched as
#     itself and never answers for its upstream;
#   - branches other than the default one;
#   - GitLab, which the merge poll supports but which has no equivalent run
#     query wired here;
#   - a workflow whose newest run is older than the assessed commit: the verdict
#     describes the commit, so a failure that only ever ran on an older commit
#     is not carried forward.
#
# Usage:
#   fm-branch-poll.sh            one sweep; prints a wake line or nothing
#   fm-branch-poll.sh --ack      mark every pending red verdict as surfaced
#   fm-branch-poll.sh --status   human-readable current verdict per project
#
# Environment: FM_BRANCH_WATCH_LIMIT (runs fetched per project, default 30).
# Disable entirely with a config/branch-watch file containing "off".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-branch-watch-lib.sh
. "$SCRIPT_DIR/fm-branch-watch-lib.sh"
# shellcheck source=bin/fm-gh-lib.sh
. "$SCRIPT_DIR/fm-gh-lib.sh"

RUN_LIMIT=${FM_BRANCH_WATCH_LIMIT:-30}
case "$RUN_LIMIT" in
  ''|*[!0-9]*|0) RUN_LIMIT=30 ;;
esac

MODE=poll
case "${1-}" in
  '') ;;
  --ack) MODE=ack ;;
  --status) MODE=status ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    echo "usage: fm-branch-poll.sh [--ack|--status]" >&2
    exit 2
    ;;
esac

# Every project directory under this home, in a stable order so a sweep cut
# short by the watcher's per-check timeout always loses the same tail rather
# than a random project each time.
list_projects() {
  local dir name
  [ -d "$PROJECTS" ] || return 0
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "${dir%/}")
    fm_bw_project_valid "$name" || continue
    printf '%s\n' "$name"
  done | LC_ALL=C sort
}

# The default branch, without ever writing to the project. The clone's cached
# origin/HEAD symref is free and authoritative when present; a previously
# recorded branch covers a clone that never got one; a single forge lookup is
# the last resort. bin/fm-fleet-sync.sh owns repairing a missing symref, because
# repairing it is a write and firstmate does not write to projects.
resolve_default_branch() {
  local dir=$1 project=$2 repo=$3 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  branch=${ref#origin/}
  if fm_bw_branch_valid "$branch"; then
    printf '%s\n' "$branch"
    return 0
  fi
  if fm_bw_read "$STATE" "$project" && fm_bw_branch_valid "$FM_BW_BRANCH"; then
    printf '%s\n' "$FM_BW_BRANCH"
    return 0
  fi
  branch=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null || true)
  fm_bw_branch_valid "$branch" || return 1
  printf '%s\n' "$branch"
}

# Group the branch's runs by commit and reduce them to one settled verdict.
# Reads TSV on stdin; prints one of:
#   none
#   green<TAB>sha
#   red<TAB>sha<TAB>run_id<TAB>run_url<TAB>workflow<TAB>conclusion<TAB>last_green
assess_runs() {
  awk -F '\t' '
    {
      sha = $1; status = $2; concl = $3; id = $4; url = $5; wf = $6
      if (sha == "") next
      if (!(sha in seen)) { seen[sha] = 1; order[++n] = sha }
      if (status != "completed") pending[sha] = 1
      if (concl == "failure" || concl == "timed_out" || concl == "startup_failure") {
        if (!(sha in bad)) {
          bad[sha] = 1
          badid[sha] = id
          badurl[sha] = (url == "" ? "-" : url)
          badwf[sha] = (wf == "" ? "-" : wf)
          badconcl[sha] = concl
        }
      } else if (concl == "success") {
        good[sha] = 1
      }
    }
    END {
      verdict = ""; assessed = ""; last_green = "-"
      for (i = 1; i <= n; i++) {
        s = order[i]
        if (s in pending) continue
        if (s in bad) st = "red"
        else if (s in good) st = "green"
        else continue
        if (verdict == "") {
          verdict = st; assessed = s
          if (verdict == "green") break
          continue
        }
        if (st == "green") { last_green = s; break }
      }
      if (verdict == "") { print "none"; exit }
      if (verdict == "green") { printf "green\t%s\n", assessed; exit }
      printf "red\t%s\t%s\t%s\t%s\t%s\t%s\n", assessed, badid[assessed], \
        badurl[assessed], badwf[assessed], badconcl[assessed], last_green
    }
  '
}

# Step count and wall duration for the failing jobs of one run. This is the
# whole point of the wake: zero steps in a couple of seconds is a check that
# never started, and no conclusion field can tell you that.
#
# The reported job, step count, and duration all describe the FIRST failing job,
# so the three numbers always belong together. The separate maximum step count
# across every failing job is what the caller classifies on, because "not one
# failing job executed a single step" is the claim that distinguishes a refused
# run from a real failure, and one job's zero would not carry it.
# Prints "<job>\t<steps>\t<duration>\t<jobs>\t<max-steps>" or nothing when the
# run detail cannot be read at all.
job_evidence() {
  local repo=$1 run=$2 raw concl name steps dur
  local jobs=0 max_steps=0 first_name='' first_steps=0 first_dur='?'
  raw=$(gh run view "$run" --repo "$repo" --json jobs -q '
    .jobs[] | [ (.conclusion // "-"), (.name // "-"), (.steps | length | tostring),
      ( if (.startedAt | type) == "string" and (.completedAt | type) == "string"
        then ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))
        else -1 end | tostring ) ] | @tsv' 2>/dev/null) || return 1
  while IFS=$(printf '\t') read -r concl name steps dur; do
    [ -n "$concl" ] || continue
    jobs=$((jobs + 1))
    case "$concl" in failure|timed_out|startup_failure) ;; *) continue ;; esac
    case "$steps" in ''|*[!0-9]*) steps=0 ;; esac
    [ "$steps" -le "$max_steps" ] || max_steps=$steps
    [ -z "$first_name" ] || continue
    first_name=${name:--}
    first_steps=$steps
    case "$dur" in ''|*[!0-9]*) dur='?' ;; esac
    first_dur=$dur
  done <<EOF
$raw
EOF
  # A run can fail with no failing job at all - that IS the never-started shape,
  # and it must be reported rather than dropped for lack of a job row.
  printf '%s\t%s\t%s\t%s\t%s\n' "${first_name:--}" "$first_steps" "$first_dur" "$jobs" "$max_steps"
}

commit_subject() {
  local repo=$1 sha=$2 subject
  subject=$(gh api "repos/$repo/git/commits/$sha" --jq '.message | split("\n")[0]' 2>/dev/null) || return 1
  [ -n "$subject" ] || return 1
  subject=$(printf '%s' "$subject" | LC_ALL=C tr '\t\r\n"' '    ')
  printf '%s\n' "${subject:0:72}"
}

# One project's sweep. Prints its wake clause when the branch newly reads red,
# nothing otherwise. Records the verdict either way.
sweep_project() {
  local project=$1 dir repo branch runs verdict fields
  local sha run url workflow conclusion last_green
  local had_prev=0 prev_state='' prev_sha='' prev_green='' prev_surfaced=''
  local evidence job steps duration jobs max_steps phrase classification subject line

  dir="$PROJECTS/$project"
  repo=$(fm_gh_repo_from_remote "$dir" 2>/dev/null) || return 0
  branch=$(resolve_default_branch "$dir" "$project" "$repo") || return 0

  if fm_bw_read "$STATE" "$project"; then
    had_prev=1
    prev_state=$FM_BW_STATE
    prev_sha=$FM_BW_SHA
    prev_surfaced=$FM_BW_SURFACED
    [ "$FM_BW_STATE" != green ] || prev_green=$FM_BW_SHA
    [ "$FM_BW_LAST_GREEN" = - ] || [ -n "$prev_green" ] || prev_green=$FM_BW_LAST_GREEN
  fi

  runs=$(gh run list --repo "$repo" --branch "$branch" --limit "$RUN_LIMIT" \
    --json headSha,status,conclusion,databaseId,url,workflowName \
    -q '.[] | [ .headSha, .status, (.conclusion // ""), (.databaseId | tostring),
      (.url // ""), (.workflowName // "") ] | @tsv' 2>/dev/null) || return 0
  [ -n "$runs" ] || return 0

  fields=$(printf '%s\n' "$runs" | assess_runs)
  case "$fields" in
    green*) verdict=green ;;
    red*) verdict=red ;;
    *) return 0 ;;
  esac
  IFS=$(printf '\t') read -r _ sha run url workflow conclusion last_green <<EOF
$fields
EOF
  fm_bw_sha_valid "$sha" || return 0
  [ "$verdict" = red ] || { run=-; last_green=-; }
  [ -n "${last_green:-}" ] || last_green=-
  [ "$last_green" != - ] || last_green=${prev_green:--}
  [ "$last_green" = - ] || fm_bw_sha_valid "$last_green" || last_green=-

  if [ "$verdict" = green ]; then
    fm_bw_write "$STATE" "$project" "$repo" "$branch" green "$sha" - - yes "$(date +%s)" || true
    return 0
  fi

  # Red. Silent only when this exact commit's red verdict was already delivered.
  if [ "$had_prev" = 1 ] && [ "$prev_state" = red ] && [ "$prev_sha" = "$sha" ] \
    && [ "$prev_surfaced" = yes ]; then
    return 0
  fi

  if evidence=$(job_evidence "$repo" "$run"); then
    IFS=$(printf '\t') read -r job steps duration jobs max_steps <<EOF
$evidence
EOF
    if [ "$conclusion" = startup_failure ] || [ "$jobs" = 0 ] || [ "$max_steps" = 0 ]; then
      classification='checks NEVER STARTED'
    else
      classification='checks ran and failed'
    fi
    evidence="job=\"$job\" steps=$steps duration=${duration}s jobs=$jobs"
  else
    classification='checks failed, run detail unavailable'
    evidence='evidence=unavailable'
  fi

  if [ "$had_prev" = 0 ]; then
    phrase='was already red when the watch started'
  elif [ "$prev_state" = green ]; then
    phrase='went red'
  elif [ "$prev_sha" = "$sha" ]; then
    # Same red commit, reached here only because its previous wake was never
    # acknowledged. Calling that a new commit would be a plain falsehood about
    # the suspect, which is the one thing this wake exists to get right.
    phrase='is still red, repeating a report that was never delivered'
  else
    phrase='is red at a new commit'
  fi

  line="$project/$branch $phrase - $classification; conclusion=$conclusion $evidence"
  line="$line suspect=$(fm_bw_short "$sha") last_green=$(fm_bw_short "$last_green")"
  line="$line workflow=\"$workflow\" run=$url"
  if subject=$(commit_subject "$repo" "$sha"); then
    line="$line subject=\"$subject\""
  fi

  fm_bw_write "$STATE" "$project" "$repo" "$branch" red "$sha" "$run" "$last_green" no "$(date +%s)" || return 0
  printf '%s\n' "$line"
}

run_ack() {
  local project
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    fm_bw_read "$STATE" "$project" || continue
    [ "$FM_BW_SURFACED" = no ] || continue
    fm_bw_write "$STATE" "$project" "$FM_BW_REPO" "$FM_BW_BRANCH" "$FM_BW_STATE" \
      "$FM_BW_SHA" "$FM_BW_RUN" "$FM_BW_LAST_GREEN" yes "$FM_BW_OBSERVED" || true
  done < <(list_projects)
}

run_status() {
  local project found=0
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    found=1
    if ! fm_bw_read "$STATE" "$project"; then
      printf '%s: no default-branch verdict recorded yet\n' "$project"
      continue
    fi
    printf '%s (%s): %s at %s' "$project" "$FM_BW_BRANCH" "$FM_BW_STATE" "$(fm_bw_short "$FM_BW_SHA")"
    [ "$FM_BW_STATE" = green ] || printf ', last green %s, run %s, surfaced=%s' \
      "$(fm_bw_short "$FM_BW_LAST_GREEN")" "$FM_BW_RUN" "$FM_BW_SURFACED"
    printf '\n'
  done < <(list_projects)
  [ "$found" = 1 ] || printf 'no default-branch verdicts recorded in %s\n' "$(fm_bw_dir "$STATE")"
}

case "$MODE" in
  ack)
    run_ack
    exit 0
    ;;
  status)
    run_status
    exit 0
    ;;
esac

fm_bw_enabled "$CONFIG" || exit 0
[ -d "$PROJECTS" ] || exit 0
command -v gh >/dev/null 2>&1 || exit 0

OUT=
while IFS= read -r PROJECT; do
  [ -n "$PROJECT" ] || continue
  CLAUSE=$(sweep_project "$PROJECT") || continue
  [ -n "$CLAUSE" ] || continue
  if [ -z "$OUT" ]; then
    OUT="branch-red: $CLAUSE"
  else
    OUT="$OUT ;; $CLAUSE"
  fi
done < <(list_projects)

[ -z "$OUT" ] || printf '%s\n' "$OUT"
exit 0
