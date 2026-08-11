#!/usr/bin/env bash
# Tests for worktree ownership: proving a task's recorded worktree still belongs
# to that task before anything acts destructively on it.
# Contract owner: bin/fm-worktree-owner-lib.sh. Consumers: bin/fm-spawn.sh writes
# the record at spawn; bin/fm-teardown.sh refuses without it; bin/fm-worktree-owner.sh
# inspects and restores it.
#
# THE OBSERVED SHAPE. A parked task's agent exits, its shell is left sitting in a
# pooled treehouse worktree, and its pane later disappears. A pooled worktree is
# NOT reserved by the shell inside it, so the pool correctly leases that slot to a
# freshly spawned task while the parked task's meta still records the same path.
# Tearing the parked task down then terminates the newer task's running agent and
# returns ITS worktree. Nothing recovers that; only refusing does.
#
# Matrix:
#   (a) task A's meta naming the worktree task B now holds -> REFUSE, change nothing
#   (b) --force on that same mismatch                      -> REFUSE (forcing discards
#                                                             OUR work, never a sibling's)
#   (c) worktree that is genuinely the task's own          -> ALLOW (ordinary cleanup
#                                                             must not regress)
#   (d) meta with no ownership record (pre-change task)    -> ALLOW (legacy tolerance)
#   (e) ownership record missing entirely                  -> REFUSE (cannot prove ours)
#   (f) --disown-worktree on a reassigned worktree         -> ALLOW, touching nothing
#                                                             under that path
#   (g) --disown-worktree while the worktree IS still ours -> REFUSE (never a way past
#                                                             the landed-work checks)
#   (h) fm-worktree-owner.sh claim on a missing record     -> restores it
#   (i) fm-worktree-owner.sh claim on a sibling's record   -> REFUSE (never steals)
#   (j) fm-spawn.sh                                        -> writes both halves of the
#                                                             proof, agreeing
#   (k) uncommitted-work protection with a record present  -> still REFUSES
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
OWNER="$ROOT/bin/fm-worktree-owner.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-owner)
MARKER=.fm-worktree-owner

# Build a sandbox with a project and TWO pooled worktrees, standing in for two
# pool slots. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  # `treehouse return` records the call so a refusing teardown can be proven to
  # have returned nothing at all.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TREEHOUSE_CALL_LOG:?}"
exit 0
SH
  fm_fake_exit0 "$fakebin" tmux gh gh-axi
  chmod +x "$fakebin/treehouse"

  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" worktree add -q -b fm/task-a "$case_dir/wt-a"
  git -C "$case_dir/project" worktree add -q -b fm/task-b "$case_dir/wt-b"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Write an ownership record naming <task> with <token> into <worktree>, the way
# a spawn into that worktree leaves it.
claim_for() {  # <worktree> <token> <task>
  printf 'token=%s\ntask=%s\nhome=/fake/home\n' "$2" "$3" > "$1/$MARKER"
  chmod 0600 "$1/$MARKER"
}

write_meta() {  # <case_dir> <task> <worktree> [token]
  local case_dir=$1 id=$2 wt=$3 token=${4:-}
  local -a lines=(
    "window=firstmate:fm-$id"
    "endpoint_task_id=$id"
    "worktree=$wt"
    "project=$case_dir/project"
    "kind=ship"
    "mode=local-only"
  )
  [ -z "$token" ] || lines+=("worktree_owner=$token")
  fm_write_meta "$case_dir/state/$id.meta" "${lines[@]}"
}

run_teardown() {  # <case_dir> <task> [args...]
  local case_dir=$1 id=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  TREEHOUSE_CALL_LOG="$case_dir/treehouse-calls" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

run_owner() {  # <case_dir> <action> <task>
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$OWNER" "$@"
}

treehouse_was_called() {  # <case_dir>
  [ -s "$1/treehouse-calls" ]
}

TOKEN_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TOKEN_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# (a) The exact observed shape: task A's meta names the worktree task B now holds.
test_reassigned_worktree_refuses_and_changes_nothing() {
  local case_dir rc
  case_dir=$(make_case reassigned)
  # The pool handed wt-a to task-b, whose spawn claimed it.
  claim_for "$case_dir/wt-a" "$TOKEN_B" task-b
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  git -C "$case_dir/wt-a" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "task-b work"

  set +e
  run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "reassigned: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "reassigned: no REFUSED line"
  grep -q "held by task task-b" "$case_dir/stderr" \
    || fail "reassigned: refusal did not name the task that holds the worktree: $(cat "$case_dir/stderr")"
  grep -q "$TOKEN_A" "$case_dir/stderr" \
    || fail "reassigned: refusal did not name the expected token"
  # Changed nothing: the sibling's record, branch, and worktree all intact, and
  # the worktree was never returned to the pool.
  ! treehouse_was_called "$case_dir" || fail "reassigned: teardown returned the sibling's worktree"
  grep -q "task=task-b" "$case_dir/wt-a/$MARKER" || fail "reassigned: sibling ownership record was disturbed"
  git -C "$case_dir/project" rev-parse --verify -q fm/task-a >/dev/null \
    || fail "reassigned: teardown deleted a branch despite refusing"
  assert_present "$case_dir/state/task-a.meta" "reassigned: durable task record was removed despite refusing"
  pass "a teardown whose worktree is now held by another task refuses and changes nothing"
}

# (b) --force authorizes discarding OUR work, never destroying a sibling's.
test_force_does_not_override_a_reassigned_worktree() {
  local case_dir rc
  case_dir=$(make_case reassigned-force)
  claim_for "$case_dir/wt-a" "$TOKEN_B" task-b
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  set +e
  run_teardown "$case_dir" task-a --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "reassigned-force: --force should still refuse"
  grep -q "held by task task-b" "$case_dir/stderr" || fail "reassigned-force: no ownership refusal"
  ! treehouse_was_called "$case_dir" || fail "reassigned-force: --force returned the sibling's worktree"
  pass "--force does not override a reassigned worktree"
}

# (c) The ordinary case must not regress: an owned worktree is torn down as before.
test_owned_worktree_is_torn_down_normally() {
  local case_dir rc
  case_dir=$(make_case owned)
  claim_for "$case_dir/wt-a" "$TOKEN_A" task-a
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  set +e
  run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "owned: teardown should succeed on its own worktree"
  ! grep -q REFUSED "$case_dir/stderr" || fail "owned: teardown refused its own worktree: $(cat "$case_dir/stderr")"
  treehouse_was_called "$case_dir" || fail "owned: worktree was never returned to the pool"
  assert_absent "$case_dir/state/task-a.meta" "owned: durable task record was not cleaned up"
  pass "a teardown whose worktree is genuinely its own still succeeds"
}

# (d) Tasks spawned before ownership records existed carry none, and are unaffected.
test_task_without_ownership_record_is_unchecked() {
  local case_dir rc
  case_dir=$(make_case legacy)
  write_meta "$case_dir" task-a "$case_dir/wt-a"

  set +e
  run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "legacy: teardown of a pre-ownership task should succeed"
  ! grep -q REFUSED "$case_dir/stderr" || fail "legacy: teardown refused a pre-ownership task: $(cat "$case_dir/stderr")"
  treehouse_was_called "$case_dir" || fail "legacy: worktree was never returned"
  pass "a task with no ownership record is torn down unchecked, as before"
}

# (e) A record that is simply gone proves nothing, and proceeding could act inside
# another task's work, so it refuses rather than assuming the worktree is ours.
test_missing_ownership_record_refuses() {
  local case_dir rc
  case_dir=$(make_case missing-record)
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  set +e
  run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-record: teardown should refuse"
  grep -q "cannot prove" "$case_dir/stderr" || fail "missing-record: refusal did not say ownership was unprovable"
  grep -q "absent" "$case_dir/stderr" || fail "missing-record: refusal did not name what it found"
  grep -q "claim task-a" "$case_dir/stderr" || fail "missing-record: refusal did not offer the restore path"
  grep -q -- "--disown-worktree" "$case_dir/stderr" || fail "missing-record: refusal did not offer the cleanup path"
  ! treehouse_was_called "$case_dir" || fail "missing-record: teardown returned an unproven worktree"
  pass "a worktree with no ownership record refuses and names both resolutions"
}

# (f) The stated, non-forcing cleanup for a task whose worktree was reclaimed.
test_disown_cleans_up_without_touching_the_worktree() {
  local case_dir rc
  case_dir=$(make_case disown)
  claim_for "$case_dir/wt-a" "$TOKEN_B" task-b
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  # Task A's commits live on its branch in the shared repository, not in the
  # worktree the pool took back.
  git -C "$case_dir/project" branch fm/task-a-work

  set +e
  run_teardown "$case_dir" task-a --disown-worktree > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "disown: cleanup should succeed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-a.meta" "disown: task record was not cleaned up"
  # Touched nothing under the reclaimed path.
  ! treehouse_was_called "$case_dir" || fail "disown: returned a worktree it does not own"
  grep -q "task=task-b" "$case_dir/wt-a/$MARKER" || fail "disown: disturbed the holder's ownership record"
  assert_present "$case_dir/wt-a" "disown: removed a worktree it does not own"
  git -C "$case_dir/project" rev-parse --verify -q fm/task-a-work >/dev/null \
    || fail "disown: deleted a branch holding the task's work"
  git -C "$case_dir/project" rev-parse --verify -q fm/task-a >/dev/null \
    || fail "disown: deleted the worktree's branch"
  assert_contains "$(cat "$case_dir/stdout")" "leaving worktree" "disown: did not report leaving the worktree alone"
  pass "a task whose worktree was reclaimed is cleaned up without touching that worktree"
}

# (g) Disowning must never become a way around the landed-work checks.
test_disown_refuses_while_the_worktree_is_still_ours() {
  local case_dir rc
  case_dir=$(make_case disown-still-ours)
  claim_for "$case_dir/wt-a" "$TOKEN_A" task-a
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  set +e
  run_teardown "$case_dir" task-a --disown-worktree > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "disown-still-ours: should refuse"
  grep -q "still task task-a's own" "$case_dir/stderr" \
    || fail "disown-still-ours: refusal did not say the worktree is still ours: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-a.meta" "disown-still-ours: cleaned up despite refusing"
  pass "--disown-worktree refuses while the worktree is still the task's own"
}

# (k) The unlanded-work protections are untouched: this adds a check, removes none.
test_uncommitted_work_still_refuses_with_a_valid_record() {
  local case_dir rc
  case_dir=$(make_case dirty-owned)
  claim_for "$case_dir/wt-a" "$TOKEN_A" task-a
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  printf 'work in progress\n' > "$case_dir/wt-a/scratch.txt"

  set +e
  run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-owned: teardown should still refuse uncommitted work"
  grep -q "uncommitted changes" "$case_dir/stderr" \
    || fail "dirty-owned: the uncommitted-work refusal was lost: $(cat "$case_dir/stderr")"
  ! treehouse_was_called "$case_dir" || fail "dirty-owned: returned a worktree with uncommitted work"
  pass "an owned worktree with uncommitted work still refuses (unlanded-work protection intact)"
}

# The ownership record itself is firstmate's own artifact and must never be the
# thing that makes a worktree look dirty.
test_ownership_record_alone_is_not_uncommitted_work() {
  local case_dir rc
  case_dir=$(make_case record-not-dirty)
  claim_for "$case_dir/wt-a" "$TOKEN_A" task-a
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  set +e
  run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "record-not-dirty: the record alone must not block teardown: $(cat "$case_dir/stderr")"
  pass "the ownership record alone never reads as uncommitted work"
}

# (h) Restoring a lost record, for the case the refusal cannot resolve on its own.
test_claim_restores_a_missing_record() {
  local case_dir out
  case_dir=$(make_case claim-restore)
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  out=$(run_owner "$case_dir" claim task-a) || fail "claim: restoring a missing record failed"
  assert_contains "$out" "restored ownership record" "claim: did not report restoring the record"
  grep -q "token=$TOKEN_A" "$case_dir/wt-a/$MARKER" || fail "claim: token was not restored"
  grep -q "task=task-a" "$case_dir/wt-a/$MARKER" || fail "claim: task was not restored"

  # And the teardown it was blocking now proceeds.
  run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "claim: teardown still refused after the record was restored: $(cat "$case_dir/stderr")"
  pass "a lost ownership record can be restored, unblocking ordinary cleanup"
}

# (i) Restoring must only ever FILL a missing record, never take a live one.
test_claim_refuses_to_take_another_tasks_worktree() {
  local case_dir rc
  case_dir=$(make_case claim-steal)
  claim_for "$case_dir/wt-a" "$TOKEN_B" task-b
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  set +e
  run_owner "$case_dir" claim task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "claim-steal: claiming a held worktree should refuse"
  grep -q "held by task task-b" "$case_dir/stderr" || fail "claim-steal: refusal did not name the holder"
  grep -q "token=$TOKEN_B" "$case_dir/wt-a/$MARKER" || fail "claim-steal: overwrote the holder's record"
  pass "restoring a record never takes a worktree another task holds"
}

test_show_reports_both_halves_of_the_proof() {
  local case_dir out
  case_dir=$(make_case show)
  claim_for "$case_dir/wt-a" "$TOKEN_B" task-b
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  out=$(run_owner "$case_dir" show task-a) || fail "show: failed"
  assert_contains "$out" "expected_token=$TOKEN_A" "show: did not report the expected token"
  assert_contains "$out" "recorded_token=$TOKEN_B" "show: did not report the recorded token"
  assert_contains "$out" "verdict=other" "show: did not report the verdict"
  pass "the ownership record can be inspected against what the task expects"
}

# (j) The spawn half of the proof: a real fm-spawn records both halves, agreeing.
test_spawn_records_ownership_of_the_worktree_it_took() {
  local case_dir home proj wt fakebin id out rc
  id=owner-spawn-z1
  case_dir="$TMP_ROOT/spawn-records"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-owner-spawn"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn-records: spawn failed: $out"

  assert_grep "worktree_owner=" "$home/state/$id.meta" \
    "spawn-records: spawn did not record the ownership token in the task's metadata"
  assert_present "$wt/$MARKER" "spawn-records: spawn did not write the ownership record into the worktree"
  # Both halves must agree, and name this task.
  local meta_token marker_token
  meta_token=$(sed -n 's/^worktree_owner=//p' "$home/state/$id.meta" | head -1)
  marker_token=$(sed -n 's/^token=//p' "$wt/$MARKER" | head -1)
  [ -n "$meta_token" ] || fail "spawn-records: recorded an empty ownership token"
  [ "$meta_token" = "$marker_token" ] \
    || fail "spawn-records: metadata token '$meta_token' disagrees with the worktree record '$marker_token'"
  grep -q "task=$id" "$wt/$MARKER" || fail "spawn-records: the worktree record does not name the task"
  # It must stay out of git's view so it can never reach a commit.
  [ -z "$(git -C "$wt" status --porcelain -- "$MARKER")" ] \
    || fail "spawn-records: the ownership record is visible to git and could be committed"
  pass "spawn records ownership of the worktree it took, in metadata and in the worktree, out of git's view"
}

test_reassigned_worktree_refuses_and_changes_nothing
test_force_does_not_override_a_reassigned_worktree
test_owned_worktree_is_torn_down_normally
test_task_without_ownership_record_is_unchecked
test_missing_ownership_record_refuses
test_disown_cleans_up_without_touching_the_worktree
test_disown_refuses_while_the_worktree_is_still_ours
test_uncommitted_work_still_refuses_with_a_valid_record
test_ownership_record_alone_is_not_uncommitted_work
test_claim_restores_a_missing_record
test_claim_refuses_to_take_another_tasks_worktree
test_show_reports_both_halves_of_the_proof
test_spawn_records_ownership_of_the_worktree_it_took

echo "# all fm-worktree-owner tests passed"
