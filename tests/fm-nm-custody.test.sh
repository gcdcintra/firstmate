#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-custody.sh.
#
# The shape under test: a no-mistakes run that dies mid-flight leaves a terminal
# run holding its branch, and once the gate branch has moved off the head that
# run recorded, the guarded `axi sync --recover` can never succeed again. The
# script recognizes that state and steps around it by branching at the identical
# head, leaving the stranded ref alone.
#
# The two states are indistinguishable from `axi sync --check` alone - both print
# blocked_pipeline_owned_recoverable / next_action.code: recover_custody - so the
# discriminator is the gate branch head. These tests therefore drive BOTH halves
# for real: a stubbed `no-mistakes` on PATH supplies the TOON reports (fixtures
# copied from real v1.46.0 output, see docs/verification/nm-custody-deadlock.md),
# while the gate is a REAL bare repo registered as the `no-mistakes` git remote,
# so the ls-remote half is exercised rather than mocked.
#
# Coverage: the stranded shape fires; recoverable, active, released, unreadable
# and wrong-branch states are left alone; the report names what it found, did and
# left behind; suffix collisions walk forward; and nothing is ever deleted,
# forced or discarded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CUSTODY="$ROOT/bin/fm-nm-custody.sh"

TMP=$(fm_test_tmproot fm-nm-custody)
fm_git_identity fmtest fmtest@example.invalid

# --- fixtures ---------------------------------------------------------------

# make_repo <name> -> echoes a worktree with a feature branch and a real bare
# gate registered as the `no-mistakes` remote, matching what `no-mistakes init`
# leaves behind. Echoes "<worktree> <gate> <head>".
make_repo() {  # <name> [branch]
  local name=$1 branch=${2:-feat/work}
  local dir="$TMP/$name" gate="$TMP/$name-gate.git" head
  fm_git_init_commit "$dir"
  git -C "$dir" checkout -q -b "$branch"
  printf 'work\n' > "$dir/work.txt"
  git -C "$dir" add work.txt
  git -C "$dir" commit -qm "feat: work"
  head=$(git -C "$dir" rev-parse HEAD)
  git init -q --bare "$gate"
  git -C "$dir" remote add no-mistakes "$gate"
  # The gate carries the branch, as it does after a run's push.
  git -C "$dir" push -q no-mistakes "refs/heads/$branch:refs/heads/$branch"
  printf '%s %s %s\n' "$dir" "$gate" "$head"
}

# The `branch_sync` report `no-mistakes axi sync --check` prints. Field names,
# nesting and ordering are copied from real v1.46.0 output; only the values vary
# per scenario. `head` appearing under both `local:` and `pipeline:`-adjacent
# blocks is deliberate - it is exactly the ambiguity the script's parser must
# resolve by section.
sync_report() {  # <branch> <local-head> <clean> <run> <run-status> <preserved-head> <safety> [next-code]
  local branch=$1 local_head=$2 clean=$3 run=$4 run_status=$5 preserved=$6 safety=$7 next_code=${8:-}
  cat <<EOF
branch_sync:
  state: pipeline_owned
  changed: false
  local:
    branch: $branch
    head: $local_head
    clean: $clean
  pipeline:
    run: "$run"
    status: $run_status
    phase: pre_push
    submitted_head: $local_head
    current_head: $preserved
    pushed_head: ""
    pushed_at: 0
    push_generation: 0
  target:
    kind: ""
    remote: origin
    url: /dev/null
    ref: ""
  remote:
    observed_head: ""
    freshness: pipeline_push
    observed_at: 0
  relation: unknown
  safety: $safety
  pr_state: none
EOF
  if [ -n "$next_code" ]; then
    cat <<EOF
  next_action:
    code: $next_code
    command: no-mistakes axi sync --recover
EOF
  fi
}

# install_nm <dir> <check-report-file> <recover-report-file>: put a `no-mistakes`
# stub on PATH that replays the given reports. The stub distinguishes the
# read-only check from the confirming --recover probe so a test can assert the
# script never acts on the check alone.
install_nm() {  # <fakebin> <check-file> <recover-file>
  local fakebin=$1 check=$2 recover=$3
  cat > "$fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
# Stubbed no-mistakes. Real binaries print an update banner on stderr; do the
# same so the script is exercised against that noise.
echo "A new version of no-mistakes is available" >&2
case "\$*" in
  *"sync --check"*)  [ -f '$check' ] && cat '$check' ;;
  *"sync --recover"*) [ -f '$recover' ] && cat '$recover' ;;
esac
exit 0
EOF
  chmod +x "$fakebin/no-mistakes"
}

# The refusal a genuinely stranded branch gets from the confirming probe.
diverged_report() {  # <branch> <local-head> <preserved> <gate-head>
  sync_report "$1" "$2" true 01KZW462QQ0DRRMFBMPDDP97YR failed "$3" blocked_recover_gate_diverged
}

# stranded_case <name> -> sets DIR/GATE/HEAD/FAKEBIN globals for a stranded
# branch: a terminal run holding custody at a preserved head the gate is not at.
DIR=""; GATE=""; HEAD=""; FAKEBIN=""
stranded_case() {  # <name> [branch]
  local name=$1 branch=${2:-feat/work} preserved
  read -r DIR GATE HEAD < <(make_repo "$name" "$branch")
  # A head the gate is NOT at: the commits the dead run made and never published.
  preserved=$(printf '%s' "$HEAD" | tr '0-9a-f' '1-9a-f0')
  FAKEBIN=$(fm_fakebin "$TMP/$name-bin")
  sync_report "$branch" "$HEAD" true 01KZW462QQ0DRRMFBMPDDP97YR failed \
    "$preserved" blocked_pipeline_owned_recoverable recover_custody > "$TMP/$name.check"
  diverged_report "$branch" "$HEAD" "$preserved" > "$TMP/$name.recover"
  install_nm "$FAKEBIN" "$TMP/$name.check" "$TMP/$name.recover"
}

run_custody() {  # <fakebin> <args...>
  local fakebin=$1
  shift
  PATH="$fakebin:$PATH" "$CUSTODY" "$@" 2>&1
}

# --- the stranded shape is recognized ---------------------------------------

stranded_case strand1
out=$(run_custody "$FAKEBIN" check --dir "$DIR")
assert_contains "$out" "custody: stranded" "check must recognize the stranded shape"
assert_contains "$out" "01KZW462QQ0DRRMFBMPDDP97YR" "check must name the run that stranded it"
assert_contains "$out" "can never be met again" "check must explain why the supported recovery is unreachable"
pass "check recognizes a branch stranded by a dead run"

# check is read-only: it must not create anything even on the stranded shape.
refs=$(git -C "$DIR" for-each-ref --format='%(refname:short)' 'refs/heads/feat/*' | tr '\n' ' ')
[ "$refs" = "feat/work " ] || fail "check created or moved a ref: $refs"
pass "check changes nothing on a stranded branch"

# --- the sidestep -----------------------------------------------------------

stranded_case strand2
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 0 "$code" "recover on a stranded branch"
[ "$(git -C "$DIR" symbolic-ref --short HEAD)" = feat/work-v2 ] \
  || fail "recover must leave the worktree on the replacement branch"
[ "$(git -C "$DIR" rev-parse feat/work-v2)" = "$HEAD" ] \
  || fail "the replacement branch must sit at the IDENTICAL head"
[ "$(git -C "$DIR" rev-parse feat/work)" = "$HEAD" ] \
  || fail "the stranded branch must be left exactly where it was"
[ "$(git -C "$DIR" rev-list --count feat/work)" = "$(git -C "$DIR" rev-list --count feat/work-v2)" ] \
  || fail "the sidestep must drop no commit"
pass "recover branches at the identical head and drops nothing"

# The stranded refs survive on both sides. Nothing is ever deleted.
git -C "$DIR" show-ref --verify --quiet refs/heads/feat/work \
  || fail "the local stranded ref was deleted"
git -C "$GATE" show-ref --verify --quiet refs/heads/feat/work \
  || fail "the gate's stranded ref was deleted"
pass "recover deletes nothing: the stranded ref survives locally and in the gate"

# --- the report -------------------------------------------------------------

assert_contains "$out" "What happened" "the report must say what it found"
assert_contains "$out" "What was done" "the report must say what it did"
assert_contains "$out" "What was left behind" "the report must say which ref it left behind"
assert_contains "$out" "refs/heads/feat/work" "the report must name the exact ref left behind"
assert_contains "$out" "captain's to remove" "the report must say who decides to remove the residue"
assert_contains "$out" "-vN name" "the report must own the namespace cost"
assert_contains "$out" "died mid-flight" "the report must name the trigger, so the fix does not hide it"
pass "recover reports what it found, did, left behind, and who clears the residue"

# --status makes the report durable rather than depending on the worker.
stranded_case strand3
status="$TMP/strand3.status"
: > "$status"
run_custody "$FAKEBIN" recover --dir "$DIR" --status "$status" >/dev/null
assert_grep "working: no-mistakes left feat/work stranded" "$status" \
  "the one-line report must be appended to the status file"
assert_grep "feat/work-v2" "$status" "the status line must name the replacement branch"
[ "$(grep -c . "$status")" = 1 ] || fail "exactly one status line must be appended"
pass "recover appends its one-line report to the task status file"

# --- ordinary states are untouched ------------------------------------------

# Recoverable: a terminal run holds the branch, but the gate is still at the head
# it recorded, so no-mistakes' own guarded recovery works. Must not fire.
read -r DIR GATE HEAD < <(make_repo ordinary)
FAKEBIN=$(fm_fakebin "$TMP/ordinary-bin")
sync_report feat/work "$HEAD" true 01KZVPA4GJ105Y83V6PCGKQ4NE failed \
  "$HEAD" blocked_pipeline_owned_recoverable recover_custody > "$TMP/ordinary.check"
diverged_report feat/work "$HEAD" "$HEAD" > "$TMP/ordinary.recover"
install_nm "$FAKEBIN" "$TMP/ordinary.check" "$TMP/ordinary.recover"

out=$(run_custody "$FAKEBIN" check --dir "$DIR")
assert_contains "$out" "custody: recoverable" "a gate still at the recorded head is recoverable, not stranded"
assert_contains "$out" "axi sync --recover" "check must point at the supported recovery"
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 3 "$code" "recover on a recoverable branch must do nothing"
assert_not_contains "$out" "What was done" "no sidestep report on a recoverable branch"
[ -z "$(git -C "$DIR" for-each-ref --format='%(refname:short)' refs/heads/feat/work-v2)" ] \
  || fail "recover created a branch for an ordinary recoverable state"
pass "an ordinary recoverable branch is left for no-mistakes' own recovery"

# Behind / cleanly owned: no custody claim at all.
read -r DIR GATE HEAD < <(make_repo owned)
FAKEBIN=$(fm_fakebin "$TMP/owned-bin")
sync_report feat/work "$HEAD" true "" "" "" user_owned > "$TMP/owned.check"
install_nm "$FAKEBIN" "$TMP/owned.check" /nonexistent
out=$(run_custody "$FAKEBIN" check --dir "$DIR")
assert_contains "$out" "custody: no-claim" "a cleanly owned branch holds no claim"
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 3 "$code" "recover on a cleanly owned branch must do nothing"
[ "$(git -C "$DIR" symbolic-ref --short HEAD)" = feat/work ] \
  || fail "recover moved a cleanly owned branch"
pass "a cleanly owned branch is untouched"

# A LIVE run owns its branch and must never be stepped around: doing so would
# abandon a run that is still working.
read -r DIR GATE HEAD < <(make_repo live)
FAKEBIN=$(fm_fakebin "$TMP/live-bin")
sync_report feat/work "$HEAD" true 01KZW462QQ0DRRMFBMPDDP97YR running \
  0000000000000000000000000000000000000000 blocked_pipeline_owned_recoverable recover_custody > "$TMP/live.check"
install_nm "$FAKEBIN" "$TMP/live.check" /nonexistent
out=$(run_custody "$FAKEBIN" check --dir "$DIR")
assert_contains "$out" "custody: active" "a run still running is active, not stranded"
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 3 "$code" "recover must never step around a live run"
[ "$(git -C "$DIR" symbolic-ref --short HEAD)" = feat/work ] \
  || fail "recover stepped around a live run"
pass "a live run keeps its branch"

# --- unreadable states fall toward inaction ---------------------------------

read -r DIR GATE HEAD < <(make_repo silent)
FAKEBIN=$(fm_fakebin "$TMP/silent-bin")
install_nm "$FAKEBIN" /nonexistent /nonexistent
out=$(run_custody "$FAKEBIN" check --dir "$DIR")
assert_contains "$out" "custody: unknown" "no readable report means unknown"
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 3 "$code" "recover must not act on an unreadable state"
pass "an unreadable report is never acted on"

# A gate that does not carry the branch cannot prove divergence.
read -r DIR GATE HEAD < <(make_repo nogate)
git -C "$GATE" update-ref -d refs/heads/feat/work
FAKEBIN=$(fm_fakebin "$TMP/nogate-bin")
sync_report feat/work "$HEAD" true 01KZW462QQ0DRRMFBMPDDP97YR failed \
  0000000000000000000000000000000000000000 blocked_pipeline_owned_recoverable recover_custody > "$TMP/nogate.check"
install_nm "$FAKEBIN" "$TMP/nogate.check" /nonexistent
out=$(run_custody "$FAKEBIN" check --dir "$DIR")
assert_contains "$out" "custody: unknown" "an unreadable gate head must not be guessed at"
pass "an unreadable gate head classifies unknown rather than stranded"

# --- safety refusals --------------------------------------------------------

# Uncommitted work: refuse rather than carry it onto a new branch silently.
stranded_case dirty
printf 'scratch\n' > "$DIR/uncommitted.txt"
sed -i 's/    clean: true/    clean: false/' "$TMP/dirty.check"
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 4 "$code" "recover must refuse a dirty worktree"
assert_contains "$out" "uncommitted changes" "the refusal must name the reason"
[ -z "$(git -C "$DIR" for-each-ref --format='%(refname:short)' refs/heads/feat/work-v2)" ] \
  || fail "recover created a branch despite refusing"
pass "a dirty worktree is refused, not worked around"

# The confirming probe is the last gate: without the gate-diverged refusal,
# nothing is created.
stranded_case probe
sync_report feat/work "$HEAD" true 01KZW462QQ0DRRMFBMPDDP97YR failed "$HEAD" sync > "$TMP/probe.recover"
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 0 "$code" "custody returned by the supported probe is a usable outcome"
[ "$(git -C "$DIR" symbolic-ref --short HEAD)" = feat/work ] \
  || fail "no branch may be created when the probe returned custody instead of refusing"
assert_contains "$out" "returned through the supported recovery" \
  "an unexpected recovery must be reported, not silently treated as a sidestep"
pass "custody returned by the confirming probe creates no branch and is reported"

stranded_case probemute
: > "$TMP/probemute.recover"
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 4 "$code" "an unreadable probe must block"
[ "$(git -C "$DIR" symbolic-ref --short HEAD)" = feat/work ] \
  || fail "a branch was created despite an unreadable probe"
pass "an unreadable confirming probe blocks the sidestep"

# Running it from the wrong worktree must not invent a branch there.
stranded_case elsewhere
git -C "$DIR" checkout -q --detach HEAD
out=$(run_custody "$FAKEBIN" recover --dir "$DIR"); code=$?
expect_code 4 "$code" "recover must refuse from a worktree that is not on the stranded branch"
assert_contains "$out" "not the stranded branch" "the refusal must name the mismatch"
pass "recover refuses from a worktree that does not own the branch"

# --- name selection ---------------------------------------------------------

# A taken -v2 walks forward instead of colliding, and the gate counts as taken
# even when the local repo has no such ref.
stranded_case collide
git -C "$DIR" branch feat/work-v2 "$HEAD"
git -C "$GATE" update-ref refs/heads/feat/work-v3 "$HEAD"
run_custody "$FAKEBIN" recover --dir "$DIR" >/dev/null
[ "$(git -C "$DIR" symbolic-ref --short HEAD)" = feat/work-v4 ] \
  || fail "expected feat/work-v4, got $(git -C "$DIR" symbolic-ref --short HEAD)"
[ "$(git -C "$DIR" rev-parse feat/work-v2)" = "$HEAD" ] \
  || fail "an existing -v2 must not be moved"
pass "a taken name walks forward, counting both local and gate refs"

# A branch that is already a second attempt increments its own suffix rather
# than growing another one.
stranded_case again feat/work-v2
run_custody "$FAKEBIN" recover --dir "$DIR" >/dev/null
[ "$(git -C "$DIR" symbolic-ref --short HEAD)" = feat/work-v3 ] \
  || fail "expected feat/work-v3, got $(git -C "$DIR" symbolic-ref --short HEAD)"
pass "an already-stepped-around branch increments its own suffix"

# The walk is bounded rather than spinning forever.
stranded_case bounded
git -C "$DIR" branch feat/work-v2 "$HEAD"
out=$(PATH="$FAKEBIN:$PATH" FM_NM_CUSTODY_MAX_ATTEMPT=2 "$CUSTODY" recover --dir "$DIR" 2>&1); code=$?
expect_code 4 "$code" "an exhausted name search must block rather than spin"
assert_contains "$out" "too many times" "the refusal must explain the exhausted search"
pass "the replacement-name search is bounded"

# --- usage ------------------------------------------------------------------

out=$("$CUSTODY" 2>&1); code=$?
expect_code 2 "$code" "no verb is a usage error"
assert_contains "$out" "usage:" "usage must be printed"
out=$("$CUSTODY" check --dir "$TMP/definitely-not-here" 2>&1); code=$?
expect_code 2 "$code" "a missing directory is a usage error"
out=$("$CUSTODY" nonsense 2>&1); code=$?
expect_code 2 "$code" "an unknown verb is a usage error"
pass "usage errors are reported distinctly"
