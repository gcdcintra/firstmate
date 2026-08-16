#!/usr/bin/env bash
# One sweep of every cloned project's DEFAULT branch, answering the question
# nothing else in firstmate asks: did the branch we merge onto just go red?
#
# The watcher invokes this trusted repository script directly on its own slow
# cadence. Its contract is the same as every other poll: print one line and
# firstmate wakes, print nothing and the fleet keeps sleeping. Every failure path
# is silent about the VERDICT, so an unreachable forge is never mistaken for a
# broken branch - but it is not silent about COVERAGE: a project whose query
# would not answer is counted as unassessed and named, because "no verdict" and
# "checked and fine" are the two things this must never conflate.
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
# COVERING THE FLEET WITHOUT PRETENDING TO
# A pass costs one `gh run list` per project plus two further calls per red one,
# and it runs inside the watcher's per-check budget, so a large enough fleet
# cannot be swept in one pass. Two things keep that from becoming a blind spot.
#
# The pass SELF-BOUNDS: once FM_BRANCH_WATCH_BUDGET seconds have gone it starts
# no further project. Exiting on its own terms rather than being killed is what
# lets it report and record anything at all - a killed process prints no trailing
# line. And the next pass RESUMES at the project after the last one it attempted,
# wrapping around, so a fleet too large for one pass loses a rotating slice for a
# pass each instead of the same tail every time. The cursor advances BEFORE each
# attempt, so a forge call that hangs until the watcher kills the sweep costs its
# project one rotation rather than parking every later pass on the same stall.
#
# A truncated pass SAYS SO and names every project it did not reach, because a
# partial sweep is indistinguishable from a clean one when silence is the "green"
# signal. Repeat suppression is keyed on the fleet and on how bad its coverage
# has ever been, never on the set that was missed: rotation changes that set on
# every pass by construction, so keying on it would wake once per sweep forever,
# which is what suppression exists to avoid. So a pass speaks up when the fleet
# changed, and again whenever it needs MORE passes to cover the fleet than any
# figure already delivered - coverage sliding from two passes to fourteen turns a
# disclosure the reader still trusts into a false one, and a stale disclosure is
# worse than none. Recovery is not news and stays quiet, which is also what stops
# a fleet hovering on a boundary from reporting every other pass. It speaks up a
# third time when a project starts failing its query that was never reported
# failing, because that gap can grow while the pass count sits still and it is
# the one rotation can never close. Any red report in a truncated pass carries
# the unreached names with it whether or not the notice is suppressed, so a red
# wake can never be read as "and the rest of the fleet is fine", and --status
# prints the current gap on demand.
#
# WHAT THIS FEATURE'S HISTORY IS, because it should shape what gets added next.
# The sweep first dropped a fixed alphabetical tail and said nothing, so it was
# made to rotate. Rotation left a latency, so the latency had to be stated as a
# number. The stated number could go stale without anyone noticing, so the notice
# now fires again when coverage degrades past anything already reported. Every
# layer was correct and every one stopped one step short of the thing it was
# protecting against. Ask it of whatever comes next here: does this leave
# something unbounded, silent, or stale?
#
# THE COVERAGE NUMBER IS LOAD-BEARING. It is what tells an operator how much of
# the fleet was actually looked at, so every path that increments it has to be
# honest. Read any future change that touches that counter with one question:
# can this increment without a successful check?
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
#     is not carried forward;
#   - the whole fleet in a single pass, past roughly 25 clones. One `gh run list`
#     against the real GitHub forge measured 0.93s, 0.95s, 1.01s, 1.13s and 1.21s
#     over five consecutive calls, a median of about 1.0s, and a red project costs
#     two further calls - so about 25 projects fit in one 30s pass. Rotation makes
#     the residual limit LATENCY rather than coverage, proportional to fleet size:
#     about 50 clones are covered in full within two passes, so at the default
#     900s cadence the worst-case notice for the far side of the ring is one extra
#     sweep, roughly 15 minutes, and never "not at all".
#
# OUTPUT SHAPE
# A sweep prints one tab-separated "<key><TAB><wake line>" record per thing worth
# waking on, and nothing at all otherwise. The key is the project name for a red
# branch, and ":sweep" for the one truncation notice - a key deliberately outside
# the project-name charset, because the durable wake queue collapses records
# sharing a kind and key, and one key covering two things would let one silently
# replace the other. That is the loss this whole mechanism exists to prevent. The
# caller keys each queue record on the key it is given, and acknowledges by those
# same keys once it has committed them.
#
# Usage:
#   fm-branch-poll.sh                  one sweep; prints one record per key to wake on
#   fm-branch-poll.sh --ack <key>...   mark exactly these records surfaced
#   fm-branch-poll.sh --status         human-readable current verdict per project
#
# Environment: FM_BRANCH_WATCH_LIMIT (runs fetched per project, default 30),
# FM_BRANCH_WATCH_BUDGET (seconds one pass may spend starting projects, default
# 25, which is the watcher's 30s per-check budget with room to exit cleanly).
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

BUDGET=${FM_BRANCH_WATCH_BUDGET:-25}
case "$BUDGET" in
  ''|*[!0-9]*|0) BUDGET=25 ;;
esac

USAGE='usage: fm-branch-poll.sh [--ack <key>... | --status]'
MODE=poll
case "${1-}" in
  '') ;;
  --ack)
    MODE=ack
    shift
    # An acknowledgement names what the caller committed. A bare --ack used to
    # mean "everything pending", which could mark a verdict delivered that
    # nothing ever carried, so it is now a usage error rather than a silent
    # over-reach.
    [ "$#" -gt 0 ] || { echo "$USAGE" >&2; exit 2; }
    ;;
  --status)
    [ "$#" = 1 ] || { echo "$USAGE" >&2; exit 2; }
    MODE=status
    ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    echo "$USAGE" >&2
    exit 2
    ;;
esac

# Every project directory under this home, in one stable order. The order is the
# ring that rotation walks, not the point every pass starts from: a pass resumes
# after the project it last attempted, so a stable order buys a repeatable ring
# rather than - as it did before rotation existed - a repeatable blind spot.
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

# One project's sweep. Prints its "<project><TAB><wake line>" record when the
# branch newly reads red, nothing otherwise. Records the verdict either way.
#
# Returns 2, and only 2, when the forge would not answer for this project: the
# caller must not count it among the projects the pass assessed. A project whose
# origin is missing or is not GitHub returns 0 instead - those are stated limits,
# outside the watched set by design rather than a check that failed.
sweep_project() {
  local project=$1 dir repo branch runs verdict fields
  local sha run url workflow conclusion last_green
  local had_prev=0 prev_state='' prev_sha='' prev_green='' prev_surfaced=''
  local evidence job steps duration jobs max_steps phrase classification subject detail

  dir="$PROJECTS/$project"
  repo=$(fm_gh_repo_from_remote "$dir" 2>/dev/null) || return 0
  branch=$(resolve_default_branch "$dir" "$project" "$repo") || return 2

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
      (.url // ""), (.workflowName // "") ] | @tsv' 2>/dev/null) || return 2
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
  # The last green commit is the one BEHIND the suspect. A commit recorded green
  # and then failed again on a rerun, a workflow_dispatch, or a nightly schedule
  # would otherwise fall back onto itself and produce "suspect=abc1234
  # last_green=abc1234" - incoherent evidence in the one line that has to be
  # right. "none" is the honest answer when nothing green is behind it.
  [ "$last_green" != "$sha" ] || last_green=-

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

  detail="$classification; conclusion=$conclusion $evidence"
  detail="$detail suspect=$(fm_bw_short "$sha") last_green=$(fm_bw_short "$last_green")"
  detail="$detail workflow=\"$workflow\" run=$url"
  if subject=$(commit_subject "$repo" "$sha"); then
    detail="$detail subject=\"$subject\""
  fi

  # A verdict that cannot be written is still reported. An unwritable state
  # directory is not an independent random fault: it means a full disk, or
  # permissions gone wrong, or a machine already in trouble - exactly the
  # conditions under which a default branch is most likely to be broken and
  # least affordable to miss. Going quiet here would correlate this watch's own
  # failure with the thing it watches for, which is the worst possible moment to
  # say nothing, and two failures arriving together are far worse than either
  # alone. Without a record nothing pins the sha, so the report repeats; it says
  # so inline, because an operator who sees the same red twice with no
  # explanation starts doubting the watcher instead of the branch.
  if ! fm_bw_write "$STATE" "$project" "$repo" "$branch" red "$sha" "$run" \
    "$last_green" no "$(date +%s)"; then
    phrase='is red and its verdict could not be recorded, so this repeats until it can be'
  fi
  printf '%s\t%s\n' "$project" "branch-red: $project/$branch $phrase - $detail"
}

# Mark surfaced exactly the records the caller names, and no others. The caller
# knows which wakes it committed to the durable queue; this script does not, and
# a record written unsurfaced by an earlier pass whose wake never reached the
# queue must stay unsurfaced so the next pass re-emits it. An unknown or already
# surfaced key is skipped rather than treated as an error, because failing to
# acknowledge only costs a duplicate report - the safe direction.
run_ack() {
  local key level mark seen
  for key in "$@"; do
    [ -n "$key" ] || continue
    if [ "$key" = "$FM_BW_SWEEP_KEY" ]; then
      fm_bw_sweep_read "$STATE" || continue
      [ "$FM_BW_SWEEP_SURFACED" = no ] || continue
      # Delivery is also what raises the watermark, so the level just handed over
      # is the one that may silence a later pass. It only ever rises: worse
      # coverage than anything delivered is news, recovery is not.
      level=$(fm_bw_pass_count "$FM_BW_SWEEP_FLEET" "$FM_BW_SWEEP_UNREACHED" \
        "$FM_BW_SWEEP_FAILED")
      mark=$FM_BW_SWEEP_WATERMARK
      if [ "$mark" = - ] || [ "$level" -gt "$mark" ]; then
        mark=$level
      fi
      # The delivered failures only ever grow, for the same reason the watermark
      # only ever rises: a project that failed, recovered, and failed again was
      # already said out loud once, and saying it again on every relapse is the
      # flapping this suppression exists to avoid.
      seen=$(fm_bw_list_union "$FM_BW_SWEEP_DELIVERED" "$FM_BW_SWEEP_FAILED")
      fm_bw_sweep_write "$STATE" "$FM_BW_SWEEP_RESUME" "$FM_BW_SWEEP_UNREACHED" \
        "$FM_BW_SWEEP_FAILED" "$FM_BW_SWEEP_FLEET" yes "$mark" "$seen" \
        "$FM_BW_SWEEP_OBSERVED" || true
      continue
    fi
    fm_bw_read "$STATE" "$key" || continue
    [ "$FM_BW_SURFACED" = no ] || continue
    fm_bw_write "$STATE" "$key" "$FM_BW_REPO" "$FM_BW_BRANCH" "$FM_BW_STATE" \
      "$FM_BW_SHA" "$FM_BW_RUN" "$FM_BW_LAST_GREEN" yes "$FM_BW_OBSERVED" || true
  done
}

run_status() {
  local project found=0 sweep_failed=- have_sweep=0
  if fm_bw_sweep_read "$STATE"; then
    have_sweep=1
    sweep_failed=$FM_BW_SWEEP_FAILED
  fi
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    found=1
    if ! fm_bw_read "$STATE" "$project"; then
      # A clone nobody could query and a clone nobody has swept yet both have no
      # verdict, and telling them apart is the whole point of tracking the one.
      case " $sweep_failed " in
        *" $project "*)
          printf '%s: no verdict - the forge query failed on the last pass that tried it\n' "$project"
          ;;
        *)
          printf '%s: no default-branch verdict recorded yet\n' "$project"
          ;;
      esac
      continue
    fi
    printf '%s (%s): %s at %s' "$project" "$FM_BW_BRANCH" "$FM_BW_STATE" "$(fm_bw_short "$FM_BW_SHA")"
    [ "$FM_BW_STATE" = green ] || printf ', last green %s, run %s, surfaced=%s' \
      "$(fm_bw_short "$FM_BW_LAST_GREEN")" "$FM_BW_RUN" "$FM_BW_SURFACED"
    printf '\n'
  done < <(list_projects)
  [ "$found" = 1 ] || printf 'no default-branch verdicts recorded in %s\n' "$(fm_bw_dir "$STATE")"
  # Coverage is part of the verdict: a reader has to be able to tell "every
  # project reads green" from "every project I got to reads green".
  if [ "$have_sweep" = 0 ]; then
    printf 'sweep: no pass cursor could be read, so the coverage of the last pass is unknown\n'
    return 0
  fi
  if [ "$FM_BW_SWEEP_UNREACHED" = - ] && [ "$FM_BW_SWEEP_FAILED" = - ]; then
    printf 'sweep: the last pass reached every project\n'
    return 0
  fi
  [ "$FM_BW_SWEEP_UNREACHED" = - ] \
    || printf 'sweep: the last pass did not reach %s\n' "$FM_BW_SWEEP_UNREACHED"
  [ "$FM_BW_SWEEP_FAILED" = - ] \
    || printf 'sweep: the last pass could not query %s\n' "$FM_BW_SWEEP_FAILED"
  printf 'sweep: coverage surfaced=%s' "$FM_BW_SWEEP_SURFACED"
  if [ "$FM_BW_SWEEP_WATERMARK" = - ]; then
    printf ', no coverage reported yet\n'
  else
    printf ', worst coverage reported %s passes\n' "$FM_BW_SWEEP_WATERMARK"
  fi
}

case "$MODE" in
  ack)
    run_ack "$@"
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

PROJECT_LIST=()
while IFS= read -r PROJECT; do
  [ -n "$PROJECT" ] || continue
  PROJECT_LIST+=("$PROJECT")
done < <(list_projects)
COUNT=${#PROJECT_LIST[@]}
[ "$COUNT" -gt 0 ] || exit 0
FLEET=$(printf '%s ' "${PROJECT_LIST[@]}")
FLEET=${FLEET% }

PREV_FLEET=-
PREV_SURFACED=yes
PREV_WATERMARK=-
PREV_DELIVERED=-
RESUME=-
if fm_bw_sweep_read "$STATE"; then
  RESUME=$FM_BW_SWEEP_RESUME
  PREV_FLEET=$FM_BW_SWEEP_FLEET
  PREV_SURFACED=$FM_BW_SWEEP_SURFACED
  PREV_WATERMARK=$FM_BW_SWEEP_WATERMARK
  PREV_DELIVERED=$FM_BW_SWEEP_DELIVERED
fi

# Resume after the project the previous pass last attempted. An unreadable,
# malformed, or since-removed position falls back to the start of the ring:
# starting over costs a duplicate look, while guessing forward would skip
# projects, and skipping is the whole failure this rotation removes.
START=0
if [ "$RESUME" != - ]; then
  I=0
  while [ "$I" -lt "$COUNT" ]; do
    if [ "${PROJECT_LIST[$I]}" = "$RESUME" ]; then
      START=$(( (I + 1) % COUNT ))
      break
    fi
    I=$((I + 1))
  done
fi

RING=()
K=0
while [ "$K" -lt "$COUNT" ]; do
  RING+=("${PROJECT_LIST[$(( (START + K) % COUNT ))]}")
  K=$((K + 1))
done
REMAINING=$(printf '%s ' "${RING[@]}")
REMAINING=${REMAINING% }

SWEEP_START=$SECONDS
RED=0
K=0
FAILED=
LAST_ATTEMPTED=$RESUME
while [ "$K" -lt "$COUNT" ]; do
  # The first project of a pass is always attempted. A deadline that could stop
  # a pass before it started anything would leave the cursor where it was and
  # make "every project is reached within a bounded number of passes" false.
  if [ "$K" -gt 0 ] && [ "$((SECONDS - SWEEP_START))" -ge "$BUDGET" ]; then
    break
  fi
  # Advance the cursor BEFORE the attempt, not after it. A forge call that hangs
  # until the watcher's per-check timeout kills this sweep writes nothing on the
  # way out, and a cursor moved only on success would send every later pass back
  # into that same stall - a permanent blind spot behind one slow project.
  #
  # The gap recorded here is what THIS pass has not attempted yet, never what the
  # last pass missed. A killed pass leaves no trailing report, so whatever stands
  # in this field is what --status will claim, and carrying the previous pass's
  # cleaner gap forward would let a pass that died three projects into fifty
  # report that it reached them all.
  fm_bw_sweep_write "$STATE" "${RING[$K]}" "$REMAINING" "${FAILED:--}" "$PREV_FLEET" \
    "$PREV_SURFACED" "$PREV_WATERMARK" "$PREV_DELIVERED" "$(date +%s)" || true
  LAST_ATTEMPTED=${RING[$K]}
  RECORD=$(sweep_project "${RING[$K]}")
  RC=$?
  [ "$RC" = 0 ] || RECORD=
  # A project the forge would not answer for was attempted and not assessed, so
  # it never counts toward what this pass covered. Rotation cannot help it the
  # way it helps an unreached one: a renamed repository or a lapsed token grant
  # fails on every pass, forever.
  [ "$RC" != 2 ] || FAILED="${FAILED:+$FAILED }${RING[$K]}"
  if [ -n "$RECORD" ]; then
    printf '%s\n' "$RECORD"
    RED=1
  fi
  case "$REMAINING" in
    *' '*) REMAINING=${REMAINING#* } ;;
    *) REMAINING= ;;
  esac
  K=$((K + 1))
done

UNREACHED=$REMAINING
[ -n "$UNREACHED" ] || UNREACHED=-
FAILED=${FAILED# }
[ -n "$FAILED" ] || FAILED=-
REACHED=$((K - $(fm_bw_list_count "$FAILED")))

NOW=$(date +%s)
if [ "$UNREACHED" = - ] && [ "$FAILED" = - ]; then
  # A complete pass clears the gap and nothing else. The watermark and the fleet
  # it was measured on carry through untouched, because a complete pass is the
  # fullest recovery there is and recovery is never news: clearing them here
  # would make a fleet sitting on the budget boundary alternate complete and
  # truncated and announce the same unchanged coverage every other sweep. They
  # are carried through rather than restated from this pass, so a fleet that
  # changes still resets and never inherits a figure measured on another one.
  fm_bw_sweep_write "$STATE" "$LAST_ATTEMPTED" - - "$PREV_FLEET" "$PREV_SURFACED" \
    "$PREV_WATERMARK" "$PREV_DELIVERED" "$NOW" || true
  exit 0
fi

PASSES=$(fm_bw_pass_count "$FLEET" "$UNREACHED" "$FAILED")
RING_PASSES=$(( (COUNT + K - 1) / K ))

# Truncated. Report it when a red report is going out in the same pass (so it can
# never be read as covering a fleet it did not look at), when this fleet has not
# been reported yet, when the last notice was never acknowledged and so may never
# have been delivered, when coverage has slipped past the worst already delivered
# for this fleet - a stated latency that quietly doubles is a disclosure the
# reader still trusts and it is no longer true - or when a project is failing its
# query that was never reported failing. That last arm is not the pass count in
# another form: a query failure can leave the count untouched while the fleet
# quietly stops being assessed, and it is the one gap rotation can never close.
NOTIFY=0
if [ "$RED" = 1 ] || [ "$FLEET" != "$PREV_FLEET" ] || [ "$PREV_SURFACED" = no ]; then
  NOTIFY=1
elif [ "$PREV_WATERMARK" = - ] || [ "$PASSES" -gt "$PREV_WATERMARK" ]; then
  NOTIFY=1
elif ! fm_bw_list_subset "$FAILED" "$PREV_DELIVERED"; then
  NOTIFY=1
fi

# Both suppression markers belong to the fleet they were measured on, so a fleet
# that changed starts again with nothing delivered. They are raised by the
# acknowledgement, not here: a report this pass never managed to deliver must not
# silence the one after it.
WATERMARK=$PREV_WATERMARK
DELIVERED=$PREV_DELIVERED
if [ "$FLEET" != "$PREV_FLEET" ]; then
  WATERMARK=-
  DELIVERED=-
fi

LINE="branch-watch-incomplete: this pass reached $REACHED of $COUNT projects inside its ${BUDGET}s budget"
if [ "$UNREACHED" != - ]; then
  # The claim is about the projects this pass did not reach, never about the
  # fleet: the failed-query ones below are not covered by rotation at all. The
  # number is how fast the ring actually advances, which is the attempted rate -
  # the cursor moves past a project whose query failed too. The pass count that
  # drives suppression is a different figure and deliberately not stated here.
  LINE="$LINE - not reached this pass: $UNREACHED; the next pass resumes there, reaching them within $RING_PASSES passes"
fi
if [ "$FAILED" != - ]; then
  LINE="$LINE - forge query failed, so no verdict at all for: $FAILED; rotation does not reach these, they stay unassessed until the query works again"
fi

if [ "$NOTIFY" = 1 ]; then
  # The notice goes out even when the cursor cannot be recorded. The rule that a
  # persistently large fleet must not wake every sweep was about a HEALTHY fleet,
  # where truncation is expected and repeating it is stale news. A state
  # directory that cannot be written is not that: rotation degenerates back to
  # the fixed alphabetical tail it was added to remove, this notice would vanish,
  # and --status goes blank - all three at once, leaving a supervisor reading a
  # red report from a truncated pass with no coverage beside it, which this
  # file's own contract says can never happen. Waking every sweep while that
  # lasts is proportionate, and saying inline that it could not be recorded is
  # what keeps the repeat self-explaining rather than reading as noise.
  if ! fm_bw_sweep_write "$STATE" "$LAST_ATTEMPTED" "$UNREACHED" "$FAILED" "$FLEET" \
    no "$WATERMARK" "$DELIVERED" "$NOW"; then
    LINE="$LINE; this coverage report could not be recorded, so it repeats every sweep until it can be"
  fi
  printf '%s\t%s\n' "$FM_BW_SWEEP_KEY" "$LINE"
elif ! fm_bw_sweep_write "$STATE" "$LAST_ATTEMPTED" "$UNREACHED" "$FAILED" "$FLEET" \
  yes "$WATERMARK" "$DELIVERED" "$NOW"; then
  # Suppression is only trustworthy while the cursor it is decided from can be
  # written. Once it cannot, the resume position freezes and rotation falls back
  # to the fixed tail it was added to remove, while --status keeps describing a
  # pass that is no longer the last one. Staying quiet here for the same reason
  # the sibling arm does not would leave that condition entirely unsaid.
  printf '%s\t%s\n' "$FM_BW_SWEEP_KEY" \
    "$LINE; this coverage report could not be recorded, so it repeats every sweep until it can be"
fi
exit 0
