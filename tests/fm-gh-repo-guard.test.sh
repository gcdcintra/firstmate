#!/usr/bin/env bash
# Behavior tests for bin/fm-gh-repo-guard.sh.
#
# bin/fm-gh-lib.sh defends the callers that use it; this guard is what keeps
# using it from being a rule someone has to remember. The failure it prevents is
# silent - an unpinned GitHub query inside a fork returns the parent project's
# pull request, green checks and all - so the guard has to refuse at review time
# rather than leave the mistake to be discovered from a wrong answer later.
#
# Matrix:
#   (a) this repository's own bin/ passes the guard
#   (b) an unpinned gh or gh-axi pr/issue query is refused, with file and line
#   (c) an explicit --repo/-R, or a routed fm_gh_query, is accepted
#   (d) prose about these tools in a comment is not an invocation
#   (e) an unreadable --root argument fails rather than passing vacuously
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-gh-repo-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-repo-guard)

# A fixture checkout holding one bin/ script with the given body. Echoes its root.
make_fixture() {
  local name=$1 body=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin"
  printf '%s\n' "$body" > "$dir/bin/subject.sh"
  printf '%s\n' "$dir"
}

# The guard must hold over the real tree, not just over fixtures: that is the
# assertion that actually keeps bin/ pinned as the repository grows.
test_repository_bin_is_clean() {
  local out rc
  out=$("$GUARD" 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "bin/ has an unpinned GitHub query: $out"
  assert_contains "$out" "fm-gh-repo-guard: ok scripts=" \
    "the guard did not report a scanned-script count"
  case "$out" in
    *"ok scripts=0"*) fail "the guard scanned no scripts, so it proves nothing" ;;
  esac
  pass "fm-gh-repo-guard: this repository's bin/ names a repository on every GitHub query"
}

# The two forms below are verbatim the shapes that shipped before this fix, so a
# revert of either call site fails here.
test_unpinned_queries_are_refused() {
  local fixture out rc
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  fixture=$(make_fixture unpinned '#!/usr/bin/env bash
out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid 2>/dev/null) || return 1
count=$(gh issue list --limit 5)')
  out=$("$GUARD" --root "$fixture" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "an unpinned GitHub query was not refused"
  assert_contains "$out" "bin/subject.sh:2" "the gh-axi pr list finding lost its file:line"
  assert_contains "$out" "bin/subject.sh:3" "the gh pr view finding lost its file:line"
  assert_contains "$out" "bin/subject.sh:4" "the gh issue list finding lost its file:line"
  assert_contains "$out" "3 unpinned" "the guard miscounted its findings"
  pass "fm-gh-repo-guard: unpinned pull-request and issue queries are refused with file and line"
}

test_pinned_and_routed_queries_are_accepted() {
  local fixture out rc
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  fixture=$(make_fixture pinned '#!/usr/bin/env bash
gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --squash
gh pr view "$n" -R "$owner/$repo" --json state
out=$(fm_gh_query gh-axi "$WT" pr list --state all --head "$branch" --limit 1) || return 1
view=$(fm_gh_query gh "$WT" pr view "$target" --json state,headRefOid) || return 1')
  out=$("$GUARD" --root "$fixture" 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a pinned or routed query was refused: $out"
  pass "fm-gh-repo-guard: an explicit --repo/-R, or a routed fm_gh_query, is accepted"
}

# Briefs and headers legitimately describe these commands. Flagging prose would
# make the guard something contributors route around instead of trust.
test_comments_are_not_invocations() {
  local fixture out rc
  fixture=$(make_fixture comments '#!/usr/bin/env bash
# A bare gh-axi pr view 6 answers about the parent project inside a fork.
#   gh pr list --state all
  # gh issue list is likewise only prose here.
:')
  out=$("$GUARD" --root "$fixture" 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "prose in a comment was treated as an invocation: $out"
  pass "fm-gh-repo-guard: comments about these tools are not invocations"
}

test_unreadable_root_fails() {
  local out rc
  out=$("$GUARD" --root "$TMP_ROOT/definitely-missing" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing --root passed vacuously: $out"
  out=$("$GUARD" --root 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "--root without a path must be an argument error"
  pass "fm-gh-repo-guard: an unusable --root fails instead of passing vacuously"
}

test_repository_bin_is_clean
test_unpinned_queries_are_refused
test_pinned_and_routed_queries_are_accepted
test_comments_are_not_invocations
test_unreadable_root_fails
