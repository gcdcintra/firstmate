#!/usr/bin/env bash
# Behavior tests for the default-branch watch (bin/fm-branch-poll.sh and its
# cursor library), driven through the real executables with a fake `gh`.
#
# The regression this suite exists to hold is not "does it notice red". It is
# that the wake distinguishes a check that RAN and failed from one that NEVER
# STARTED. On 2026-08-15 this fleet read a red badge, concluded a code
# regression, and was wrong: the jobs had died in about two seconds having
# executed zero steps. A wake that reports only the conclusion reproduces that
# misdiagnosis, so the never-started shape is pinned explicitly and by evidence
# (step count and duration inline), not just by a classification word.
#
# Pinned here:
#   - a green-to-red transition wakes, naming the project, the suspect commit,
#     and the last green commit;
#   - a run that never started is reported as such with steps=0 and its
#     seconds-long duration inline;
#   - a branch whose newest commit is still running wakes nothing, and the
#     settled verdict behind it is what gets recorded;
#   - a project observed red on its very first sweep wakes once, worded as a
#     first observation rather than a transition;
#   - the same red commit does not wake twice once acknowledged, but a red
#     verdict that was never acknowledged is re-emitted (the watcher-crash gap);
#   - a red commit that cannot have its run detail read still wakes, with the
#     evidence gap stated rather than the wake dropped;
#   - two red projects reach the durable queue under two keys and both survive a
#     drain, which collapses records sharing a kind and key;
#   - an acknowledgement marks only the records it names, so a verdict written
#     in the same pass but never queued is re-emitted rather than swallowed;
#   - the last green commit is never the suspect commit itself;
#   - a pass too slow to reach the whole fleet resumes at the next project,
#     reaches every project within a bounded number of passes, names what it did
#     not reach, and does not repeat that notice on every sweep;
#   - a corrupt or unknown resume position restarts at the beginning rather than
#     skipping projects;
#   - coverage degrading past the figure already reported surfaces again, while
#     the same level, a recovery, and an oscillation back up stay quiet, and a
#     pass that reached nothing counts as worse than any finite figure;
#   - a pass killed before it could report leaves the gap it actually had rather
#     than the previous pass's cleaner one;
#   - a complete pass does not discard the coverage already reported, so a fleet
#     alternating complete and truncated does not re-notify every other sweep;
#   - a red whose verdict cannot be recorded is still reported, says so inline,
#     and never claims a first observation it already made;
#   - green records silently and clears the pre-launch advisory;
#   - config/branch-watch "off", a clone with no origin, and a non-GitHub origin
#     are all silent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-branch-watch-lib.sh
# Sourced here rather than mid-file so the cases below can read back a recorded
# verdict through the same reader the pre-launch advisory uses.
. "$ROOT/bin/fm-branch-watch-lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-branch-watch-tests)

GREEN_SHA=1111111111111111111111111111111111111111
RED_SHA=2222222222222222222222222222222222222222
NEWER_SHA=3333333333333333333333333333333333333333

# --- fixtures ---------------------------------------------------------------

# A fresh isolated FM_HOME per case. mktemp rather than a counter because every
# caller writes `H=$(new_home)`, and a counter incremented in that command
# substitution's subshell never reaches this shell - every home would be the
# same one, and each case would inherit the previous case's recorded verdict.
new_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/home-XXXXXX")
  mkdir -p "$h/projects" "$h/state" "$h/config"
  printf '%s\n' "$h"
}

# add_project <home> <name> [origin-url]: a git clone-shaped directory with an
# origin remote and a cached origin/HEAD, which is all the poll reads from disk.
add_project() {
  local home=$1 name=$2 origin=${3:-https://github.com/acme/$2.git}
  local dir="$home/projects/$name"
  fm_git_init_commit "$dir"
  [ "$origin" = none ] || git -C "$dir" remote add origin "$origin"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '%s\n' "$dir"
}

# fake_gh <home> <runs-file> <jobs-file> [list-delay]: a `gh` that answers
# `run list` from <runs-file> and `run view` from <jobs-file>, both already in
# the tab-separated shape the real `gh ... -q '... | @tsv'` produces. Either file
# may be the literal word "fail", which makes that subcommand exit non-zero the
# way an expired log or an unreachable forge does. <list-delay> makes each
# `run list` take that many seconds, which is how the cases below drive a sweep
# past its own budget the way a real fleet's forge round-trips do.
FAKE_SUBJECT='Merge pull request #36 from acme/nf-9'
fake_gh() {
  local home=$1 runs=$2 jobs=$3 delay=${4:-0} slow=${5:-} fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$1" in
  api)
    case "\$2" in
      */git/commits/*) printf '%s\n' "$FAKE_SUBJECT" ;;
      *) printf 'main\n' ;;
    esac
    exit 0
    ;;
  run)
    case "\$2" in
      list)
        [ "$runs" != fail ] || exit 1
        case "\$*" in
          *"$slow"*) [ "$delay" = 0 ] || sleep "$delay" ;;
        esac
        cat "$runs"
        exit 0
        ;;
      view)
        [ "$jobs" != fail ] || exit 1
        cat "$jobs"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

# runs_file <path> <record>...: each record is "sha|status|conclusion|id|url|workflow".
# The separator is "|" rather than whitespace so an empty conclusion - which is
# exactly what an unfinished run reports - stays an empty field.
runs_file() {
  local path=$1 record sha status concl id url wf
  shift
  : > "$path"
  for record in "$@"; do
    IFS='|' read -r sha status concl id url wf <<< "$record"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sha" "$status" "$concl" "$id" "$url" "$wf" >> "$path"
  done
}

# jobs_file <path> <record>...: each record is "conclusion|name|steps|duration".
jobs_file() {
  local path=$1 record concl name steps dur
  shift
  : > "$path"
  for record in "$@"; do
    IFS='|' read -r concl name steps dur <<< "$record"
    printf '%s\t%s\t%s\t%s\n' "$concl" "$name" "$steps" "$dur" >> "$path"
  done
}

# seed_record <home> <project> <repo> <branch> <verdict> <sha> <run> <last-green> <surfaced>
seed_record() {
  mkdir -p "$1/state/branch-watch"
  printf 'fm-branch-watch-v1\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n1\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" > "$1/state/branch-watch/$2"
}

# poll <home> <fakebin> [args...]: run the real poll against this home.
poll() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-branch-poll.sh" "$@"
}

# surfaced_of <home> <project>: the recorded verdict's surfaced flag, read back
# through the same reader the watcher and the pre-launch advisory use.
surfaced_of() {
  fm_bw_read "$1/state" "$2" || { printf 'unreadable\n'; return 0; }
  printf '%s\n' "$FM_BW_SURFACED"
}

# one_pass_bin <home> <runs-file> <jobs-file>: a fake gh slow enough that a pass
# with a one-second budget always attempts exactly one project - the first is
# attempted unconditionally, and the second is never started because the sleep
# has already spent the whole budget.
one_pass_bin() {
  fake_gh "$1" "$2" "$3" 1.1
}
ONE_PASS_BUDGET=1

# stall_at_bin <home> <runs-file> <jobs-file> <project>: a fake gh where only
# <project> is slow, and slow by more than the whole budget. Every project before
# it in the pass order costs nothing, so the pass reaches exactly up to and
# including <project> and stops - which is how these cases choose a coverage
# level outright instead of racing the clock for one. The budget is 2s against a
# 2.2s stall so neither side of the deadline check can land ambiguously: the
# fast prefix is always under it, and one stall is always past it.
stall_at_bin() {
  fake_gh "$1" "$2" "$3" 2.2 "$4"
}
STALL_BUDGET=2

# sweep_field <home> <line>: one line of the sweep cursor, which is this
# feature's own persisted record format (bin/fm-branch-watch-lib.sh documents the
# seven lines); line 3 is the coverage gap and line 6 the delivered watermark.
sweep_field() {
  sed -n "${2}p" "$1/state/branch-watch/.sweep" 2>/dev/null || true
}

# --- green to red names the project and the suspect merge -------------------

H=$(new_home)
add_project "$H" storage-manager >/dev/null
runs_file "$TMP_ROOT/runs-1" \
  "$RED_SHA|completed|failure|900|https://forge/runs/900|CI" \
  "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
jobs_file "$TMP_ROOT/jobs-1" "failure|build|14|401" "success|docs|6|20"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")

# Seed a prior green verdict so this sweep is a transition, not a first sighting.
seed_record "$H" storage-manager acme/storage-manager main green "$GREEN_SHA" - - yes

OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "branch-red:" "green to red must wake"
assert_contains "$OUT" "storage-manager/main went red" "the wake must name the project and the transition"
assert_contains "$OUT" "suspect=${RED_SHA:0:7}" "the wake must name the suspect merge"
assert_contains "$OUT" "last_green=${GREEN_SHA:0:7}" "the wake must name the last green commit"
pass "a default branch going green to red wakes, naming the project and the suspect merge"

# --- the wake tells a failure apart from a refusal, with evidence inline -----

assert_contains "$OUT" "checks ran and failed" "a run with executed steps is a real failure"
assert_contains "$OUT" 'job="build" steps=14 duration=401s' "the failing job's evidence must be inline"
pass "a check that ran and failed is reported as such with its step count and duration"

H=$(new_home)
add_project "$H" storage-manager >/dev/null
runs_file "$TMP_ROOT/runs-2" \
  "$RED_SHA|completed|failure|901|https://forge/runs/901|CI" \
  "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
# The 2026-08-15 shape: the job existed, concluded failure, and executed nothing.
jobs_file "$TMP_ROOT/jobs-2" "failure|build|0|2"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-2" "$TMP_ROOT/jobs-2")
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "checks NEVER STARTED" "zero executed steps is a refusal, not a regression"
assert_contains "$OUT" 'job="build" steps=0 duration=2s' "the never-started evidence must be inline"
assert_not_contains "$OUT" "checks ran and failed" "a refusal must never be reported as a failure"
pass "a check that never started is distinguished from one that ran and failed, with evidence inline"

# A run the forge itself refused to start reports startup_failure, which is the
# never-started claim stated by the forge rather than inferred from step counts.
H=$(new_home)
add_project "$H" storage-manager >/dev/null
runs_file "$TMP_ROOT/runs-startup" \
  "$RED_SHA|completed|startup_failure|906|https://forge/runs/906|CI" \
  "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
jobs_file "$TMP_ROOT/jobs-startup" "failure|build|7|9"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-startup" "$TMP_ROOT/jobs-startup")
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "checks NEVER STARTED" \
  "a startup_failure conclusion is a refusal even when the run reports steps"
assert_contains "$OUT" "conclusion=startup_failure" "the forge's own conclusion must be inline"
pass "a startup_failure conclusion is classified as never started regardless of step count"

# A run that produced no job rows at all is the same refusal shape and must not
# be dropped for lack of a job to describe.
H=$(new_home)
add_project "$H" storage-manager >/dev/null
: > "$TMP_ROOT/jobs-empty"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-2" "$TMP_ROOT/jobs-empty")
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "checks NEVER STARTED" "a run with no jobs at all never started"
assert_contains "$OUT" "jobs=0" "the absent job count must be stated"
pass "a red run with no jobs at all is reported as never started"

# --- a branch that is merely still running wakes nothing --------------------

H=$(new_home)
add_project "$H" storage-manager >/dev/null
runs_file "$TMP_ROOT/runs-3" \
  "$NEWER_SHA|in_progress||902|https://forge/runs/902|CI" \
  "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
jobs_file "$TMP_ROOT/jobs-3" "success|build|14|401"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-3" "$TMP_ROOT/jobs-3")
OUT=$(poll "$H" "$BIN")
[ -z "$OUT" ] || fail "a still-running branch must wake nothing, got: $OUT"
assert_grep "$GREEN_SHA" "$H/state/branch-watch/storage-manager" \
  "the settled commit behind the running one is what gets recorded"
assert_grep "green" "$H/state/branch-watch/storage-manager" "the settled verdict is green"
pass "a default branch whose newest commit is still running wakes nothing"

# A commit that is PARTLY complete is still settling: one finished failing run
# beside an unfinished sibling must not be called a settled verdict yet.
H=$(new_home)
add_project "$H" storage-manager >/dev/null
runs_file "$TMP_ROOT/runs-4" \
  "$NEWER_SHA|completed|failure|903|https://forge/runs/903|CI" \
  "$NEWER_SHA|in_progress||904|https://forge/runs/904|Docs" \
  "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-4" "$TMP_ROOT/jobs-3")
OUT=$(poll "$H" "$BIN")
[ -z "$OUT" ] || fail "a commit still running one of its workflows must wake nothing, got: $OUT"
pass "a commit with an unfinished run is treated as still settling, not as a verdict"

# --- first observation, repeat suppression, and the unacknowledged gap ------

H=$(new_home)
add_project "$H" storage-manager >/dev/null
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "was already red when the watch started" \
  "a branch already red on the first sweep must still wake, worded as a first observation"
assert_contains "$OUT" "suspect=${RED_SHA:0:7}" "the first observation still names the suspect commit"
pass "a branch already red at the first sweep wakes once as a first observation"

# Not yet acknowledged: the watcher may have died between the sweep and the
# durable queue, so the same red must be re-emitted rather than swallowed.
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "suspect=${RED_SHA:0:7}" \
  "an unacknowledged red verdict must be re-emitted, not swallowed"
assert_contains "$OUT" "repeating a report that was never delivered" \
  "a re-emitted verdict must say so rather than claim a new suspect commit"
assert_not_contains "$OUT" "at a new commit" \
  "the same red commit must never be described as a new one"
pass "a red verdict whose wake was never acknowledged is re-emitted, and says it is a repeat"

poll "$H" "$BIN" --ack storage-manager
OUT=$(poll "$H" "$BIN")
[ -z "$OUT" ] || fail "the same red commit must not wake twice once acknowledged, got: $OUT"
pass "an acknowledged red commit does not wake again"

# A NEW red commit is a new suspect and wakes again.
runs_file "$TMP_ROOT/runs-5" \
  "$NEWER_SHA|completed|failure|905|https://forge/runs/905|CI" \
  "$RED_SHA|completed|failure|900|https://forge/runs/900|CI"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-5" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "is red at a new commit" "a new red commit is a new suspect"
assert_contains "$OUT" "suspect=${NEWER_SHA:0:7}" "the new suspect commit must be named"
pass "a red verdict at a new commit wakes again with the new suspect"

# --- an unreadable run still wakes -----------------------------------------

H=$(new_home)
add_project "$H" storage-manager >/dev/null
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" fail)
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "suspect=${RED_SHA:0:7}" \
  "a red branch whose run detail cannot be read must still wake"
assert_contains "$OUT" "evidence=unavailable" "the missing evidence must be stated, not implied"
pass "a red branch whose run detail is unreadable still wakes, with the evidence gap named"

# --- green records silently and clears the advisory -------------------------

H=$(new_home)
add_project "$H" storage-manager >/dev/null
runs_file "$TMP_ROOT/runs-6" "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-6" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
[ -z "$OUT" ] || fail "a green branch must wake nothing, got: $OUT"
OUT=$(poll "$H" "$BIN" --status)
assert_contains "$OUT" "storage-manager (main): green" "--status must report the recorded verdict"
pass "a green default branch records its verdict and wakes nothing"

# --- silence where the watch does not apply ---------------------------------

H=$(new_home)
add_project "$H" storage-manager >/dev/null
printf 'off\n' > "$H/config/branch-watch"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
[ -z "$OUT" ] || fail "config/branch-watch off must silence the sweep, got: $OUT"
assert_absent "$H/state/branch-watch" "a disabled sweep must record nothing"
pass "config/branch-watch off silences the default-branch sweep entirely"

H=$(new_home)
add_project "$H" no-remote none >/dev/null
add_project "$H" gitlab-hosted "https://gitlab.example.com/group/proj.git" >/dev/null
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
[ -z "$OUT" ] || fail "a clone with no GitHub origin must be skipped, got: $OUT"
assert_absent "$H/state/branch-watch/no-remote" "a clone with no origin records nothing"
assert_absent "$H/state/branch-watch/gitlab-hosted" "a non-GitHub origin records nothing"
pass "clones with no origin and with a non-GitHub origin are skipped silently"

# --- two red projects stay two reports, never one that hides the other ------

H=$(new_home)
add_project "$H" storage-manager >/dev/null
add_project "$H" nf-service >/dev/null
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] \
  || fail "two red projects must produce two records, got: $OUT"
assert_contains "$OUT" "$(printf 'nf-service\tbranch-red: nf-service/main')" \
  "each record must carry the project name that keys its durable wake"
assert_contains "$OUT" "$(printf 'storage-manager\tbranch-red: storage-manager/main')" \
  "each record must carry the project name that keys its durable wake"
pass "two red projects produce two separately keyed records"

# --- an acknowledgement covers what was delivered, and nothing else ----------
#
# Both verdicts are written unsurfaced in one pass, but only one project's wake
# reaches the durable queue - the watcher can die, or the append can fail,
# between the two. Acknowledging the whole fleet would mark the undelivered one
# delivered too, and since the same red commit at the same sha never wakes twice
# once surfaced, that red would be swallowed for good.

H=$(new_home)
add_project "$H" storage-manager >/dev/null
add_project "$H" nf-service >/dev/null
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "branch-red: nf-service/main" "both projects must report red in the first pass"
assert_contains "$OUT" "branch-red: storage-manager/main" "both projects must report red in the first pass"
poll "$H" "$BIN" --ack storage-manager
[ "$(surfaced_of "$H" storage-manager)" = yes ] \
  || fail "the acknowledged project's verdict must be marked surfaced"
[ "$(surfaced_of "$H" nf-service)" = no ] \
  || fail "a verdict whose wake was never queued must stay unsurfaced"
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "branch-red: nf-service/main" \
  "a red whose wake was never queued must be re-emitted on the next pass"
assert_not_contains "$OUT" "branch-red: storage-manager/main" \
  "an acknowledged red must not be re-emitted"
pass "an acknowledgement marks only the projects it names, and the rest are re-emitted"

# --- the last green commit is never the suspect itself ----------------------
#
# A commit recorded green can go red without any new commit: a rerun, a
# workflow_dispatch, or a nightly schedule all run against the same HEAD. The
# green record behind it is then that same commit, and reporting it as the last
# green would make the wake contradict itself about the one thing it must state
# exactly.

H=$(new_home)
add_project "$H" storage-manager >/dev/null
seed_record "$H" storage-manager acme/storage-manager main green "$RED_SHA" - - yes
runs_file "$TMP_ROOT/runs-rerun" "$RED_SHA|completed|failure|907|https://forge/runs/907|CI"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-rerun" "$TMP_ROOT/jobs-1")
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "suspect=${RED_SHA:0:7}" "the suspect commit must still be named"
assert_contains "$OUT" "last_green=none" \
  "with nothing green behind the suspect, the last green commit must read none"
assert_not_contains "$OUT" "last_green=${RED_SHA:0:7}" \
  "the suspect commit must never be reported as its own last green commit"
pass "a commit that went red on a rerun never names itself as its own last green commit"

# --- a pass too slow for the whole fleet rotates instead of losing a tail ----
#
# One `gh run list` here takes longer than the whole budget, so each pass
# attempts exactly one project: the first is always attempted, and the next is
# never started. Which one that is has to move every pass, or the far end of the
# fleet is never watched at all and the sweep's silence still reads as green.

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
runs_file "$TMP_ROOT/runs-green" "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
BIN=$(one_pass_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1")
FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN" >/dev/null
assert_present "$H/state/branch-watch/alpha" "the first pass must reach the first project"
assert_absent "$H/state/branch-watch/bravo" "a pass out of budget must not reach the rest"
FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN" >/dev/null
assert_present "$H/state/branch-watch/bravo" "the next pass must resume at the project after the last one attempted"
assert_absent "$H/state/branch-watch/charlie" "rotation must advance by a pass, not restart"
FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN" >/dev/null
assert_present "$H/state/branch-watch/charlie" \
  "every project must be reached within a bounded number of passes"
pass "a pass that cannot reach the whole fleet resumes at the next project and covers all of them"

# --- a truncated pass says what it did not reach ----------------------------

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
BIN=$(one_pass_bin "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
OUT=$(FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "branch-red: alpha/main" "the project the pass did reach must still report red"
INCOMPLETE=$(printf '%s\n' "$OUT" | grep 'branch-watch-incomplete' || true)
[ -n "$INCOMPLETE" ] || fail "a truncated pass must say so, got: $OUT"
assert_contains "$INCOMPLETE" "not reached this pass: bravo charlie" \
  "a truncated pass must name every project it did not reach"
assert_contains "$INCOMPLETE" "reached 1 of 3 projects" "the truncated pass must state its own coverage"
pass "a truncated pass names the projects it did not reach, alongside the red it did find"

OUT=$(poll "$H" "$BIN" --status)
assert_contains "$OUT" "sweep: the last pass did not reach bravo charlie" \
  "--status must report the coverage gap on demand"
pass "the coverage gap of the last pass is readable through --status"

# --- the truncation notice repeats on news, not on every sweep --------------
#
# Rotation changes which projects are missed on every single pass by
# construction, so a notice keyed on that set would wake once per sweep forever.
# The news is the fleet changing, or its coverage getting worse than any figure
# already delivered; a fleet that is simply large stays quiet.

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
BIN=$(one_pass_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1")
OUT=$(FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "branch-watch-incomplete" "a newly truncating fleet must surface once"
assert_contains "$OUT" "$(printf ':sweep\tbranch-watch-incomplete')" \
  "the notice must carry its own queue key, which no project name can collide with"
OUT=$(FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "branch-watch-incomplete" \
  "an unacknowledged truncation notice must be re-emitted, not swallowed"
poll "$H" "$BIN" --ack :sweep
OUT=$(FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN")
[ -z "$OUT" ] || fail "an acknowledged truncation must not wake again on the same fleet, got: $OUT"
OUT=$(FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN")
[ -z "$OUT" ] || fail "a persistently truncating fleet must not wake on every sweep, got: $OUT"
add_project "$H" delta >/dev/null
OUT=$(FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "branch-watch-incomplete" \
  "a change to the fleet being missed must surface again"
pass "a truncated pass with nothing red surfaces on news, not on every sweep"

# --- coverage that gets worse speaks up again -------------------------------
#
# A disclosure that was true when it was written is still read as true later. A
# fleet told "covered within 2 passes" that quietly slides to 4 leaves the reader
# trusting a number that no longer holds, so a worse figure than any already
# delivered is news; the same figure again, or a better one, is not.

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
add_project "$H" delta >/dev/null

# Pass 1 stalls on bravo, so it reaches alpha and bravo: 2 of 4, covered in 2.
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" bravo)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "reached 2 of 4 projects" "the stall must decide the coverage level, not the clock"
assert_contains "$OUT" "covering the fleet within 2 passes" "a new fleet states its pass count"
poll "$H" "$BIN" --ack :sweep

# Pass 2 resumes at charlie and stalls there: 1 of 4, so the fleet now needs 4
# passes where 2 was reported. That is the degradation, and it must be said.
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" charlie)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "reached 1 of 4 projects" "the pass must reach only the stalled project"
assert_contains "$OUT" "covering the fleet within 4 passes" \
  "coverage degrading past what was reported must surface with the worse figure"
poll "$H" "$BIN" --ack :sweep
pass "coverage degrading past the figure already reported surfaces again"

# Pass 3 resumes at delta and stalls there: 1 of 4 again. Same figure, already
# delivered, so nothing new to say.
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" delta)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
[ -z "$OUT" ] || fail "the same degraded coverage must not surface twice, got: $OUT"
pass "the same degraded coverage level does not surface again"

# Pass 4 resumes at alpha and stalls on bravo: back to 2 of 4. Recovery is not
# news, and the watermark must not fall back to it.
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" bravo)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
[ -z "$OUT" ] || fail "coverage recovering must not surface, got: $OUT"
[ "$(sweep_field "$H" 6)" = 4 ] || \
  fail "recovery must not lower the worst coverage reported, got $(sweep_field "$H" 6)"
pass "coverage recovering does not surface, and does not lower the watermark"

# Pass 5 resumes at charlie and stalls there: 1 of 4, the worst level again.
# Already delivered once, so an oscillation back up to it stays quiet.
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" charlie)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
[ -z "$OUT" ] || fail "oscillating back to an already reported level must stay quiet, got: $OUT"
pass "oscillation back across a pass-count boundary stays quiet once the worst level was reported"

# A fleet that is not the one the watermark was measured on starts again.
add_project "$H" echo-svc >/dev/null
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" delta)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "branch-watch-incomplete" \
  "a fleet change must reset the watermark and surface again"
pass "a change to the fleet resets the watermark and surfaces again"

# --- a complete pass is a recovery, and recovery is never news --------------
#
# A fleet sitting on the budget boundary crosses it on forge jitter alone, so it
# alternates complete and truncated passes. If a complete pass cleared what had
# already been reported, every truncated pass after one would announce the same
# unchanged coverage again - a wake every other sweep for a fleet whose coverage
# never got worse.

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
add_project "$H" delta >/dev/null

BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" bravo)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "covering the fleet within 2 passes" "the first truncation states its pass count"
poll "$H" "$BIN" --ack :sweep
[ "$(sweep_field "$H" 6)" = 2 ] || fail "the delivered pass count must be recorded, got $(sweep_field "$H" 6)"

# A pass that fits in its budget reaches everything.
FAST=$(fake_gh "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1")
OUT=$(FM_BRANCH_WATCH_BUDGET=999 poll "$H" "$FAST")
[ -z "$OUT" ] || fail "a complete pass must wake nothing, got: $OUT"
assert_contains "$(poll "$H" "$FAST" --status)" "sweep: the last pass reached every project" \
  "a complete pass must report complete coverage"
[ "$(sweep_field "$H" 6)" = 2 ] \
  || fail "a complete pass must not discard the coverage already reported, got $(sweep_field "$H" 6)"

# Back to the same truncated coverage. Nothing about it is new. The complete pass
# above resumed the ring at charlie, so the stall goes on delta to land second in
# THIS pass - a stall on the ring's last project would let the pass finish and
# make the silence below prove nothing.
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" delta)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
[ -z "$OUT" ] || fail "coverage already reported must stay quiet after a complete pass, got: $OUT"
assert_contains "$(poll "$H" "$BIN" --status)" "sweep: the last pass did not reach" \
  "the quiet pass must have been truncated, or its silence proves nothing"
pass "a complete pass does not discard what was already reported, so recovery never re-notifies"

# A fleet change must still reset, rather than inheriting the old fleet's figure.
add_project "$H" echo-svc >/dev/null
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" alpha)
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
assert_contains "$OUT" "branch-watch-incomplete" \
  "a fleet change after a complete pass must still surface rather than inherit a figure measured elsewhere"
pass "a fleet change after a complete pass still resets the watermark"

# --- a red that cannot be recorded is still reported ------------------------
#
# The state directory goes unwritable when the disk is full or permissions have
# gone wrong - the same conditions under which a default branch is most likely to
# be broken. Going quiet then would correlate this watch's own failure with the
# thing it watches for.

H=$(new_home)
add_project "$H" storage-manager >/dev/null
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
mkdir -p "$H/state/elsewhere"
ln -s "$H/state/elsewhere" "$H/state/branch-watch"
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "branch-red: storage-manager/main" \
  "a red whose verdict cannot be recorded must still be reported"
assert_contains "$OUT" "could not be recorded" \
  "the report must say inline that the verdict was not recorded"
assert_contains "$OUT" "repeats until it can be" \
  "the report must say that it will repeat, so the repeat explains itself"
assert_contains "$OUT" 'job="build" steps=14 duration=401s' \
  "the evidence that separates a failure from a refusal must survive the unrecorded path"
assert_not_contains "$OUT" "was already red when the watch started" \
  "an unrecordable verdict must not claim a first observation"
OUT=$(poll "$H" "$BIN")
assert_contains "$OUT" "could not be recorded" \
  "a later sweep must keep reporting the red while the record cannot be written"
assert_not_contains "$OUT" "was already red when the watch started" \
  "a later sweep must not claim a first observation it already made"
pass "a red verdict that cannot be recorded is still reported, and says so rather than claiming a first sighting"

# --- a pass that reached nothing is the worst coverage there is -------------
#
# The sweep always attempts its first project, so this state is reachable
# through the record rather than through a pass: a cursor whose unreached list is
# the whole fleet describes a pass that got nowhere. It must be read as worse
# than any finite figure, never as one pass and never as complete.

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
add_project "$H" delta >/dev/null
mkdir -p "$H/state/branch-watch"
printf 'fm-branch-sweep-v2\ndelta\n%s\n%s\nno\n-\n1\n' \
  "alpha bravo charlie delta" "alpha bravo charlie delta" > "$H/state/branch-watch/.sweep"
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" alpha)
poll "$H" "$BIN" --ack :sweep
[ "$(sweep_field "$H" 6)" = 5 ] \
  || fail "a pass that reached no project must record worse than any finite figure, got $(sweep_field "$H" 6)"
OUT=$(FM_BRANCH_WATCH_BUDGET=$STALL_BUDGET poll "$H" "$BIN")
[ -z "$OUT" ] || fail "a level better than reaching nothing must not surface, got: $OUT"
pass "a pass that reached no project counts as worse than any coverage the fleet can have"

# --- a pass that is killed leaves an honest gap behind it -------------------
#
# The trailing report is what names the gap, and a killed pass never gets to
# print one. Whatever the cursor says mid-pass is therefore what --status will
# claim, so it must describe THIS pass rather than carrying the last one's
# cleaner answer forward.

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
runs_file "$TMP_ROOT/runs-green" "$GREEN_SHA|completed|success|899|https://forge/runs/899|CI"
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1")
FM_BRANCH_WATCH_BUDGET=999 poll "$H" "$BIN" >/dev/null
OUT=$(poll "$H" "$BIN" --status)
assert_contains "$OUT" "sweep: the last pass reached every project" \
  "a complete pass must report complete coverage"

# Now kill a pass mid-flight, the way the watcher's per-check timeout does: the
# sweep runs as its own process group leader and the whole group is killed, so
# the forge call it is blocked in dies with it rather than outliving this case
# and overwriting the cursor it was supposed to leave behind. The executable is
# backgrounded directly rather than through the poll helper, because
# backgrounding a shell function yields the wrapper subshell's pid and killing
# that would leave the real sweep running.
BIN=$(stall_at_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1" bravo)
set -m
PATH="$BIN:$PATH" FM_HOME="$H" FM_BRANCH_WATCH_BUDGET=999 \
  "$ROOT/bin/fm-branch-poll.sh" >/dev/null 2>&1 &
POLL_PID=$!
set +m
sleep 1
POLL_PGID=$(ps -o pgid= -p "$POLL_PID" 2>/dev/null | tr -d '[:space:]')
if [ -n "$POLL_PGID" ] && [ "$POLL_PGID" = "$POLL_PID" ]; then
  kill -KILL -- "-$POLL_PGID" 2>/dev/null || true
else
  kill -KILL "$POLL_PID" 2>/dev/null || true
fi
wait "$POLL_PID" 2>/dev/null || true
is_live_non_zombie "$POLL_PID" && fail "the killed sweep must not outlive the case"
OUT=$(poll "$H" "$BIN" --status)
assert_not_contains "$OUT" "reached every project" \
  "a pass killed before its report must never be read as having reached every project"
assert_contains "$OUT" "sweep: the last pass did not reach" \
  "a killed pass must leave the projects it had not attempted behind it"
assert_contains "$OUT" "bravo" "the project it died on must be named as not reached"
assert_contains "$OUT" "charlie" "the projects behind it must be named as not reached"
pass "a pass killed before it could report leaves an honest coverage gap, not a clean one"

# --- an unusable resume position restarts, and never skips -------------------

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
mkdir -p "$H/state/branch-watch"
printf 'fm-branch-sweep-v0\nbravo\n-\n-\nyes\n1\n' > "$H/state/branch-watch/.sweep"
BIN=$(one_pass_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1")
FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN" >/dev/null
assert_present "$H/state/branch-watch/alpha" \
  "a resume position that cannot be validated must restart at the beginning"
assert_absent "$H/state/branch-watch/charlie" "a corrupt resume position must never skip projects"
pass "a corrupt resume position restarts the ring rather than skipping projects"

H=$(new_home)
add_project "$H" alpha >/dev/null
add_project "$H" bravo >/dev/null
add_project "$H" charlie >/dev/null
mkdir -p "$H/state/branch-watch"
printf 'fm-branch-sweep-v2\nzulu\n-\n-\nyes\n-\n1\n' > "$H/state/branch-watch/.sweep"
BIN=$(one_pass_bin "$H" "$TMP_ROOT/runs-green" "$TMP_ROOT/jobs-1")
FM_BRANCH_WATCH_BUDGET=$ONE_PASS_BUDGET poll "$H" "$BIN" >/dev/null
assert_present "$H/state/branch-watch/alpha" \
  "a resume position naming no current project must restart at the beginning"
pass "a resume position naming a project that no longer exists restarts at the beginning"

# --- the watcher actually turns a red branch into a durable wake ------------
#
# The sweep printing a line is only half the contract: the supervisor has to
# queue it durably and acknowledge it, or the red is lost the moment the watcher
# exits. This drives the real fm-watch.sh rather than asserting on the poll.

H=$(new_home)
add_project "$H" storage-manager >/dev/null
add_project "$H" nf-service >/dev/null
BIN=$(fake_gh "$H" "$TMP_ROOT/runs-1" "$TMP_ROOT/jobs-1")
OUT_FILE="$H/watch.out"
PATH="$BIN:$PATH" FM_ROOT_OVERRIDE="$H" FM_STATE_OVERRIDE="$H/state" \
  FM_PROJECTS_OVERRIDE="$H/projects" FM_CONFIG_OVERRIDE="$H/config" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_BRANCH_WATCH_INTERVAL=0 \
  bash "$ROOT/bin/fm-watch.sh" > "$OUT_FILE" 2>/dev/null &
WATCH_PID=$!
I=0
while [ "$I" -lt 100 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.1
  I=$((I + 1))
done
fm_wake_terminate "$WATCH_PID" 2>/dev/null || true
OUT=$(cat "$OUT_FILE" 2>/dev/null || true)
assert_contains "$OUT" "check: branch-red:" "the watcher must report a red default branch as a check wake"
assert_contains "$OUT" "suspect=${RED_SHA:0:7}" "the watcher's wake must carry the suspect commit"
assert_grep "branch-watch:storage-manager" "$H/state/.wake-queue" \
  "each red project must reach the durable wake queue under its own key"
assert_grep "branch-watch:nf-service" "$H/state/.wake-queue" \
  "each red project must reach the durable wake queue under its own key"
[ "$(surfaced_of "$H" storage-manager)" = yes ] \
  || fail "the watcher must acknowledge each queued verdict, so it does not repeat"
[ "$(surfaced_of "$H" nf-service)" = yes ] \
  || fail "the watcher must acknowledge every verdict it queued, not just the first"

# The drain keeps only the newest record per (kind, key), so distinct keys are
# what stops one project's red from silently replacing the other's - and the
# acknowledgement above means a dropped record could never be re-emitted.
DRAINED=$(FM_ROOT_OVERRIDE="$H" FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
assert_contains "$DRAINED" "storage-manager/main" "the first project's red must survive the drain"
assert_contains "$DRAINED" "nf-service/main" "the second project's red must survive the drain"
pass "the watcher turns each red default branch into its own durable, acknowledged wake"

# A watcher supervising a home with no clones at all must not run the sweep,
# which is what keeps every other suite's watcher hermetic.
H=$(new_home)
rmdir "$H/projects"
OUT_FILE="$H/watch.out"
FM_ROOT_OVERRIDE="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_BRANCH_WATCH_INTERVAL=0 \
  bash "$ROOT/bin/fm-watch.sh" > "$OUT_FILE" 2>/dev/null &
WATCH_PID=$!
sleep 2
kill -0 "$WATCH_PID" 2>/dev/null || fail "a watcher with no clones must keep supervising, not exit"
fm_wake_terminate "$WATCH_PID" 2>/dev/null || true
assert_absent "$H/state/.last-branch-watch" "a home with no clones must never run the sweep"
pass "a watcher supervising a home with no clones never runs the default-branch sweep"

# --- the cursor refuses a record it cannot trust ----------------------------

H=$(new_home)
mkdir -p "$H/state/branch-watch"
printf 'fm-branch-watch-v0\np\nacme/p\nmain\ngreen\n%s\n-\n-\nyes\n1\n' "$GREEN_SHA" \
  > "$H/state/branch-watch/p"
fm_bw_read "$H/state" p && fail "a record with an unknown version tag must be refused"
printf 'fm-branch-watch-v1\np\nacme/p\nmain\ngreen\nnot-a-sha\n-\n-\nyes\n1\n' \
  > "$H/state/branch-watch/p"
fm_bw_read "$H/state" p && fail "a record with a malformed commit must be refused"
printf 'fm-branch-watch-v1\np\nacme/p\nmain\ngreen\n%s\n-\n-\nyes\n1\nextra\n' "$GREEN_SHA" \
  > "$H/state/branch-watch/p"
fm_bw_read "$H/state" p && fail "a record with a trailing field must be refused"
pass "the default-branch cursor refuses a record it cannot fully validate"

# Writing a verdict must not change the umask of the script that wrote it. The
# record itself stays private, but bin/fm-spawn.sh sources this library and lives
# for a whole launch, so a umask left behind here would silently privatize every
# file it creates afterwards.
H=$(new_home)
UMASK_BEFORE=$(umask)
fm_bw_write "$H/state" p acme/p main red "$RED_SHA" 900 "$GREEN_SHA" no 1 \
  || fail "writing a verdict must succeed"
[ "$(umask)" = "$UMASK_BEFORE" ] || fail "fm_bw_write must restore the caller's umask, got $(umask)"
fm_bw_sweep_write "$H/state" p - - yes - 1 || fail "writing the sweep cursor must succeed"
[ "$(umask)" = "$UMASK_BEFORE" ] || fail "fm_bw_sweep_write must restore the caller's umask, got $(umask)"
[ -n "$(find "$H/state/branch-watch/p" -perm 0600 2>/dev/null)" ] \
  || fail "the verdict record must still be written private to its owner"
pass "writing a record keeps it private without leaving the caller's umask changed"

# --- the pre-launch advisory reads the same cursor --------------------------

H=$(new_home)
mkdir -p "$H/state/branch-watch"
seed_record "$H" storage-manager acme/storage-manager main red "$RED_SHA" 900 "$GREEN_SHA" yes
fm_bw_read "$H/state" storage-manager || fail "the recorded red verdict must read back"
[ "$FM_BW_STATE" = red ] || fail "the recorded verdict must be red"
[ "$(fm_bw_short "$FM_BW_SHA")" = "${RED_SHA:0:7}" ] || fail "the recorded suspect must read back"
[ "$(fm_bw_short "$FM_BW_LAST_GREEN")" = "${GREEN_SHA:0:7}" ] || fail "the last green must read back"
pass "a recorded red verdict is readable by the pre-launch advisory before a worker starts"
