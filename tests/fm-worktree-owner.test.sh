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
#   (l) spawn onto a planted marker-named symlink          -> replaces it, never
#                                                             writes through it
#   (m) disown at mode != local-only                       -> the run's clone refresh
#                                                             prunes no branch, so the
#                                                             released branch survives
#   (n) slot reassigned during a return lock-retry wait    -> REFUSE before retrying
#                                                             the return
#   (o) slot reassigned during the safety-check lock wait  -> REFUSE before branch
#                                                             deletion and the return
#   (p) --disown-worktree on an unprovable record whose
#       worktree still holds unlanded work                 -> REFUSE, naming what it
#                                                             found (never orphan it)
#   (q) --disown-worktree on an unprovable record with no
#       unlanded work at stake                             -> ALLOW (that cleanup
#                                                             must stay non-trapping)
#   (r) --force --disown-worktree on (p)                   -> ALLOW, the explicit
#                                                             override, touching nothing
#   (s) slot reassigned during the herdr presentation-lock
#       preflight wait                                     -> REFUSE before branch
#                                                             deletion and the return
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
OWNER="$ROOT/bin/fm-worktree-owner.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-owner)
MARKER=.fm-worktree-owner
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

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

write_meta() {  # <case_dir> <task> <worktree> [token] [mode]
  local case_dir=$1 id=$2 wt=$3 token=${4:-} mode=${5:-local-only}
  local -a lines=(
    "window=firstmate:fm-$id"
    "endpoint_task_id=$id"
    "worktree=$wt"
    "project=$case_dir/project"
    "kind=ship"
    "mode=$mode"
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

# treehouse whose first return fails with the transient index.lock signature
# while the pool hands the slot to another task (rewriting the ownership record
# named by FM_TEST_REASSIGN_MARKER), then would succeed on the retry - exactly
# the release the post-wait recheck must refuse.
add_reassigning_transient_lock_treehouse() {  # <case_dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${TREEHOUSE_CALL_LOG:?}"
if [ "${1:-}" = return ]; then
  if [ ! -e "${TREEHOUSE_FIRST_FAIL_FLAG:?}" ]; then
    : > "$TREEHOUSE_FIRST_FAIL_FLAG"
    printf 'token=%s\ntask=%s\nhome=/fake/home\n' \
      "${FM_TEST_REASSIGN_TOKEN:?}" "${FM_TEST_REASSIGN_TASK:?}" > "${FM_TEST_REASSIGN_MARKER:?}"
    echo "fatal: Unable to create 'index.lock': File exists." >&2
    exit 128
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# git wrapper that fails `status --porcelain` with the index.lock signature while
# the lock file exists, handing the slot to another task at that same blocked
# moment (rewriting the ownership record named by FM_TEST_REASSIGN_MARKER), and
# passes everything else through to the real git.
add_reassigning_git_status_lock_failure() {  # <case_dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    printf 'token=%s\ntask=%s\nhome=/fake/home\n' \
      "${FM_TEST_REASSIGN_TOKEN:?}" "${FM_TEST_REASSIGN_TASK:?}" > "${FM_TEST_REASSIGN_MARKER:?}"
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Give <case-dir>'s task-a a flat Herdr endpoint whose fake socket path is
# case-local, so the derived presentation lock never collides with another test or
# a real fleet session. When FM_TEST_REASSIGN_MARKER is set, the fake hands the
# slot to another task at the moment teardown resolves the presentation session
# lock - inside the preflight that then spins on it, which is after the first
# ownership proof and before anything destructive.
configure_reassigning_herdr_endpoint() {  # <case_dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-a.meta"
  rm -f "$case_dir/state/task-a.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-a.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":true}]}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ -n "\${FM_TEST_REASSIGN_MARKER:-}" ]; then
      printf 'token=%s\ntask=%s\nhome=/fake/home\n' \
        "\${FM_TEST_REASSIGN_TOKEN:?}" "\${FM_TEST_REASSIGN_TASK:?}" > "\$FM_TEST_REASSIGN_MARKER"
    fi
    printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

add_lsof_no_holder() {  # <case_dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

git_index_lock_path() {  # <dir>
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
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

# (p) `absent` and `unreadable` are not proof of a reclaim - they are the absence
# of proof either way, and a crewmate's own `git clean -fdx` reaches them with the
# worktree still this task's and its work still in it. Disowning there would drop
# the records and leave that work in a path no task claims, which the pool then
# passes over for both `get` and prune, so it refuses and names what it found.
test_disown_refuses_unlanded_work_when_ownership_is_unprovable() {
  local case_dir rc
  case_dir=$(make_case disown-unprovable-dirty)
  # No record at all: removed, not replaced by a sibling's.
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  printf 'work in progress\n' > "$case_dir/wt-a/scratch.txt"

  set +e
  run_teardown "$case_dir" task-a --disown-worktree > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "disown-unprovable-dirty: disowning should refuse while unlanded work is in that worktree"
  grep -q "uncommitted changes" "$case_dir/stderr" \
    || fail "disown-unprovable-dirty: the refusal did not name what it found: $(cat "$case_dir/stderr")"
  grep -q "needs a human decision" "$case_dir/stderr" \
    || fail "disown-unprovable-dirty: the refusal did not say this state needs a human decision"
  assert_present "$case_dir/state/task-a.meta" "disown-unprovable-dirty: records were dropped despite refusing"
  assert_present "$case_dir/wt-a/scratch.txt" "disown-unprovable-dirty: the uncommitted work was disturbed"
  ! treehouse_was_called "$case_dir" || fail "disown-unprovable-dirty: touched the pool despite refusing"
  pass "--disown-worktree refuses unlanded work when ownership is merely unprovable"
}

# (q) The other half of that, so criterion 3 does not become its own trap: with
# nothing unlanded at stake, an unprovable record still has the stated
# non-forcing way out.
test_disown_proceeds_when_an_unprovable_worktree_holds_no_unlanded_work() {
  local case_dir rc
  case_dir=$(make_case disown-unprovable-clean)
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"

  set +e
  run_teardown "$case_dir" task-a --disown-worktree > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "disown-unprovable-clean: cleanup should still succeed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-a.meta" "disown-unprovable-clean: task record was not cleaned up"
  ! treehouse_was_called "$case_dir" || fail "disown-unprovable-clean: returned a worktree it cannot prove is its own"
  assert_present "$case_dir/wt-a" "disown-unprovable-clean: removed a worktree it does not own"
  pass "--disown-worktree still resolves an unprovable record when no unlanded work is at stake"
}

# (r) The way past (p) stays the ordinary explicit one - the captain's --force,
# which authorizes giving up THIS task's own work - and it still touches nothing
# under the path.
test_forced_disown_overrides_the_unlanded_work_refusal() {
  local case_dir rc
  case_dir=$(make_case disown-unprovable-forced)
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  printf 'work in progress\n' > "$case_dir/wt-a/scratch.txt"

  set +e
  run_teardown "$case_dir" task-a --force --disown-worktree > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "disown-unprovable-forced: --force should authorize the disown: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-a.meta" "disown-unprovable-forced: task record was not cleaned up"
  ! treehouse_was_called "$case_dir" || fail "disown-unprovable-forced: returned a worktree it cannot prove is its own"
  assert_present "$case_dir/wt-a/scratch.txt" "disown-unprovable-forced: disowning touched the worktree"
  pass "--force --disown-worktree is the explicit override for that refusal and still touches nothing"
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

# (l) The write side refuses what the read side refuses. A marker-named symlink
# planted in a pooled slot survives `treehouse return --force` (the clean skips
# git-excluded files), so the next spawn into that slot must replace it with a
# fresh regular record - never write through it into whatever it points at.
test_spawn_never_writes_through_a_planted_marker_symlink() {
  local case_dir home proj wt fakebin id victim out rc
  id=owner-spawn-z2
  case_dir="$TMP_ROOT/spawn-symlink"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  victim="$case_dir/victim.txt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-owner-spawn-symlink"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf 'sibling data that must survive\n' > "$victim"
  ln -s "$victim" "$wt/$MARKER"
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
  expect_code 0 "$rc" "spawn-symlink: spawn failed: $out"

  [ "$(cat "$victim")" = 'sibling data that must survive' ] \
    || fail "spawn-symlink: spawn wrote through the planted symlink and clobbered its target"
  [ ! -L "$wt/$MARKER" ] || fail "spawn-symlink: the planted symlink is still the ownership record"
  [ -f "$wt/$MARKER" ] || fail "spawn-symlink: spawn did not leave a regular ownership record"
  grep -q "task=$id" "$wt/$MARKER" || fail "spawn-symlink: the fresh record does not name the task"
  pass "spawn replaces a planted marker symlink instead of writing through it"
}

# (m) The disown promise holds where the teardown tail actually refreshes the
# project clone (mode != local-only): that refresh must not prune the branch the
# disown just released, even when its remote branch is already deleted and no
# worktree holds it, which is exactly a disowned task's state. The run itself
# deletes no branch; only a later routine sync may.
test_disown_run_never_prunes_the_released_branch() {
  local case_dir rc default
  case_dir=$(make_case disown-remote-mode)
  fm_git_add_origin "$case_dir/project" "$case_dir/origin.git"
  default=$(git -C "$case_dir/project" symbolic-ref --short HEAD)
  git -C "$case_dir/project" push -q -u origin "$default"
  # Task A's branch was pushed and its remote branch has since been deleted.
  git -C "$case_dir/wt-a" push -q -u origin fm/task-a
  git -C "$case_dir/project" push -q origin --delete fm/task-a
  # The pool then reused the slot: a fresh task checked out its own branch there
  # and claimed the path, so no worktree holds fm/task-a any more.
  git -C "$case_dir/wt-a" checkout -q -b fm/task-b-reuse
  claim_for "$case_dir/wt-a" "$TOKEN_B" task-b
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A" no-mistakes

  set +e
  run_teardown "$case_dir" task-a --disown-worktree > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "disown-remote: cleanup should succeed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-a.meta" "disown-remote: task record was not cleaned up"
  # The teardown tail's clone refresh really ran against this project...
  assert_contains "$(cat "$case_dir/stdout")" "already current" \
    "disown-remote: the teardown tail's clone refresh did not run"
  # ...and still deleted no branch: the disowned task's commits survive the run.
  git -C "$case_dir/project" rev-parse --verify -q fm/task-a >/dev/null \
    || fail "disown-remote: the disown run pruned the branch it promised to leave alone"
  ! treehouse_was_called "$case_dir" || fail "disown-remote: returned a worktree it does not own"
  grep -q "task=task-b" "$case_dir/wt-a/$MARKER" || fail "disown-remote: disturbed the holder's ownership record"
  pass "a disown at mode != local-only refreshes the clone without pruning the released branch"
}

# (n) The pool can reassign a slot during the return's own lock-retry waits,
# after every pre-return check has passed. Each retried return must re-prove
# ownership first; without that, the retry releases the slot out from under its
# new holder.
test_return_lock_retry_reproves_ownership_before_retrying() {
  local case_dir rc
  case_dir=$(make_case retry-wait-reassign)
  claim_for "$case_dir/wt-a" "$TOKEN_A" task-a
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  add_reassigning_transient_lock_treehouse "$case_dir"

  set +e
  TREEHOUSE_FIRST_FAIL_FLAG="$case_dir/first-fail" \
  FM_TEST_REASSIGN_MARKER="$case_dir/wt-a/$MARKER" \
  FM_TEST_REASSIGN_TOKEN="$TOKEN_B" FM_TEST_REASSIGN_TASK=task-b \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
    run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "retry-reassign: teardown should refuse after the slot changed hands during the wait"
  grep -q "held by task task-b" "$case_dir/stderr" \
    || fail "retry-reassign: the post-wait recheck did not name the new holder: $(cat "$case_dir/stderr")"
  grep -q "aborted after a lock wait" "$case_dir/stderr" \
    || fail "retry-reassign: the return was not aborted by the post-wait recheck: $(cat "$case_dir/stderr")"
  [ "$(grep -c '^return' "$case_dir/treehouse-calls")" -eq 1 ] \
    || fail "retry-reassign: the return was retried against a slot another task now holds"
  assert_present "$case_dir/wt-a" "retry-reassign: the reassigned worktree was removed"
  grep -q "task=task-b" "$case_dir/wt-a/$MARKER" || fail "retry-reassign: disturbed the new holder's record"
  assert_present "$case_dir/state/task-a.meta" "retry-reassign: durable task record was removed despite refusing"
  pass "a slot reassigned during a return lock-retry wait is refused, not released"
}

# (o) The safety-check lock wait opens the same window before branch deletion:
# ownership was proved once, inspection was blocked by a git lock, and by the
# time the stale lock is cleared the pool has re-handed the slot. The re-proof
# after that wait must refuse before the branch deletion and the return.
test_safety_lock_wait_reproves_ownership_before_branch_deletion() {
  local case_dir rc lock
  case_dir=$(make_case safety-wait-reassign)
  claim_for "$case_dir/wt-a" "$TOKEN_A" task-a
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  add_reassigning_git_status_lock_failure "$case_dir"
  add_lsof_no_holder "$case_dir"
  lock=$(git_index_lock_path "$case_dir/wt-a")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_TEST_REASSIGN_MARKER="$case_dir/wt-a/$MARKER" \
  FM_TEST_REASSIGN_TOKEN="$TOKEN_B" FM_TEST_REASSIGN_TASK=task-b \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "safety-wait-reassign: teardown should refuse after the slot changed hands during the wait"
  grep -q "removed provably-stale git lock" "$case_dir/stderr" \
    || fail "safety-wait-reassign: the stale lock was never cleared, so the waited path was not exercised: $(cat "$case_dir/stderr")"
  grep -q "held by task task-b" "$case_dir/stderr" \
    || fail "safety-wait-reassign: the post-wait re-proof did not name the new holder: $(cat "$case_dir/stderr")"
  git -C "$case_dir/project" rev-parse --verify -q fm/task-a >/dev/null \
    || fail "safety-wait-reassign: the branch was deleted despite the refused re-proof"
  ! treehouse_was_called "$case_dir" || fail "safety-wait-reassign: returned a worktree another task holds"
  grep -q "task=task-b" "$case_dir/wt-a/$MARKER" || fail "safety-wait-reassign: disturbed the new holder's record"
  assert_present "$case_dir/state/task-a.meta" "safety-wait-reassign: durable task record was removed despite refusing"
  pass "ownership is re-proved after the safety-check lock wait, before branch deletion"
}

# (s) The herdr preflight spins on the presentation session lock for up to five
# seconds, and that spin sits between the first ownership proof and the block that
# deletes the branch, removes the hook files, and returns the worktree. A slot the
# pool reassigns while teardown waits there has to be refused like any other.
test_herdr_preflight_wait_reproves_ownership_before_branch_deletion() {
  local case_dir rc
  case_dir=$(make_case herdr-preflight-reassign)
  claim_for "$case_dir/wt-a" "$TOKEN_A" task-a
  write_meta "$case_dir" task-a "$case_dir/wt-a" "$TOKEN_A"
  configure_reassigning_herdr_endpoint "$case_dir"

  set +e
  FM_FAKE_HERDR_LOG="$case_dir/herdr.log" \
  FM_FAKE_HERDR_CLOSED="$case_dir/herdr-closed" \
  FM_TEST_REASSIGN_MARKER="$case_dir/wt-a/$MARKER" \
  FM_TEST_REASSIGN_TOKEN="$TOKEN_B" \
  FM_TEST_REASSIGN_TASK=task-b \
    run_teardown "$case_dir" task-a > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "herdr-preflight-reassign: teardown should refuse a slot reassigned during the preflight"
  grep -q "held by task task-b" "$case_dir/stderr" \
    || fail "herdr-preflight-reassign: no ownership refusal: $(cat "$case_dir/stderr")"
  # The reassignment is served from inside the preflight, so reaching it at all
  # proves the first proof passed and the refusal came from the re-proof after it.
  grep -q "^session list" "$case_dir/herdr.log" \
    || fail "herdr-preflight-reassign: the preflight never ran, so its wait was never exercised"
  ! treehouse_was_called "$case_dir" || fail "herdr-preflight-reassign: returned a worktree another task holds"
  git -C "$case_dir/project" rev-parse --verify -q fm/task-a >/dev/null \
    || fail "herdr-preflight-reassign: deleted the branch despite refusing"
  grep -q "task=task-b" "$case_dir/wt-a/$MARKER" \
    || fail "herdr-preflight-reassign: disturbed the new holder's ownership record"
  assert_present "$case_dir/state/task-a.meta" \
    "herdr-preflight-reassign: durable task record was removed despite refusing"
  pass "ownership is re-proved after the herdr presentation-lock wait, before branch deletion"
}

# The no-argument help is the header contract: whole sentences from the first
# one on, comment prefixes stripped, like every other bin script's usage.
test_usage_prints_the_header_from_its_first_sentence() {
  local out rc first
  set +e
  out=$("$OWNER" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "usage: bare invocation should exit 2"
  first=$(printf '%s\n' "$out" | head -1)
  case "$first" in
    'Inspect or restore'*) : ;;
    *) fail "usage: help does not open with the header's first sentence: '$first'" ;;
  esac
  assert_not_contains "$out" '# ' "usage: help kept raw comment prefixes"
  assert_contains "$out" 'fm-worktree-owner.sh show <task-id>' "usage: help lost the show synopsis"
  pass "usage help starts at the header's first sentence with prefixes stripped"
}

test_reassigned_worktree_refuses_and_changes_nothing
test_force_does_not_override_a_reassigned_worktree
test_owned_worktree_is_torn_down_normally
test_task_without_ownership_record_is_unchecked
test_missing_ownership_record_refuses
test_disown_cleans_up_without_touching_the_worktree
test_disown_refuses_while_the_worktree_is_still_ours
test_disown_refuses_unlanded_work_when_ownership_is_unprovable
test_disown_proceeds_when_an_unprovable_worktree_holds_no_unlanded_work
test_forced_disown_overrides_the_unlanded_work_refusal
test_disown_run_never_prunes_the_released_branch
test_return_lock_retry_reproves_ownership_before_retrying
test_safety_lock_wait_reproves_ownership_before_branch_deletion
test_herdr_preflight_wait_reproves_ownership_before_branch_deletion
test_uncommitted_work_still_refuses_with_a_valid_record
test_ownership_record_alone_is_not_uncommitted_work
test_claim_restores_a_missing_record
test_claim_refuses_to_take_another_tasks_worktree
test_show_reports_both_halves_of_the_proof
test_spawn_records_ownership_of_the_worktree_it_took
test_spawn_never_writes_through_a_planted_marker_symlink
test_usage_prints_the_header_from_its_first_sentence

echo "# all fm-worktree-owner tests passed"
