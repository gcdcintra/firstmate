#!/usr/bin/env bash
# Behavior tests for bin/fm-gh-lib.sh, the single owner of repository
# resolution for firstmate's GitHub pull-request and issue queries.
#
# The defect being defended against: `gh` picks a base repository from the
# checkout's remotes and prefers `upstream` over `origin` while the clone has no
# `remote.<name>.gh-resolved` setting, and every gh-axi pr/issue subcommand
# inherits that choice. Inside a fork an unpinned `pr view <n>` therefore answers
# about the parent project's pull request of that number, with its own author,
# state, and green checks. Nothing in the answer marks it as foreign, so the only
# safe posture is to never let a query leave without a repository.
#
# Matrix:
#   (a) owner/repo derived from a canonical GitHub PR URL
#   (b) a non-canonical or non-GitHub URL derives nothing
#   (c) owner/repo derived from an https origin remote, .git suffix or not,
#       with or without the userinfo `git clone https://user@github.com/...` records
#   (d) owner/repo derived from an ssh origin remote (both spellings, any port)
#   (e) an origin that is not a GitHub repository - another host, or a path
#       dressed up as one - derives nothing
#   (f) `upstream` is never read, even when origin is absent
#   (f) a resolvable directory injects --repo into the invocation
#   (g) an argument that already pins the repository is passed through untouched
#   (h) an unresolvable repository is REFUSED without running the tool at all
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-gh-lib)

# shellcheck source=bin/fm-gh-lib.sh
. "$ROOT/bin/fm-gh-lib.sh"

# A git repo with the given remotes, as "<name>=<url>" pairs. Echoes its path.
make_repo() {
  local name=$1 dir pair remote url
  shift
  dir="$TMP_ROOT/$name"
  fm_git_init_commit "$dir" >/dev/null 2>&1
  for pair in "$@"; do
    remote=${pair%%=*}
    url=${pair#*=}
    git -C "$dir" remote add "$remote" "$url"
  done
  printf '%s\n' "$dir"
}

# A fakebin whose gh and gh-axi record their full argv, so a test can prove both
# what was passed and that nothing ran at all. Echoes the fakebin path.
make_recording_tools() {
  local name=$1 fakebin
  fakebin="$TMP_ROOT/$name-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TOOL_LOG"
SH
  cp "$fakebin/gh" "$fakebin/gh-axi"
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

test_repo_from_canonical_pr_url() {
  local got
  got=$(fm_gh_repo_from_url "https://github.com/gcdcintra/firstmate/pull/6") \
    || fail "canonical PR URL did not resolve"
  [ "$got" = "gcdcintra/firstmate" ] \
    || fail "canonical PR URL resolved to '$got', expected gcdcintra/firstmate"
  got=$(fm_gh_repo_from_url "https://github.com/some-owner/repo.name-1/pull/12345") \
    || fail "dotted/hyphenated repository name did not resolve"
  [ "$got" = "some-owner/repo.name-1" ] \
    || fail "resolved '$got', expected some-owner/repo.name-1"
  pass "fm-gh-lib: owner/repo is derived from a canonical GitHub PR URL"
}

test_non_canonical_urls_resolve_nothing() {
  local url
  # A GitLab merge request parses in fm-pr-lib.sh but is not a GitHub repository,
  # so it must not be turned into an owner/name pair for the GitHub CLI.
  for url in \
    "https://gitlab.com/group/sub/project/-/merge_requests/4" \
    "https://github.com/gcdcintra/firstmate/pull/abc" \
    "https://github.com/gcdcintra/firstmate" \
    "https://github.example.invalid/gcdcintra/firstmate/pull/6" \
    "" ; do
    if fm_gh_repo_from_url "$url" >/dev/null 2>&1; then
      fail "non-canonical GitHub PR URL was resolved anyway: '$url'"
    fi
  done
  pass "fm-gh-lib: a non-canonical or non-GitHub URL derives no repository"
}

test_repo_from_https_origin_remote() {
  local repo got
  repo=$(make_repo https-origin "origin=https://github.com/gcdcintra/firstmate.git")
  got=$(fm_gh_repo_from_remote "$repo") || fail "https origin did not resolve"
  [ "$got" = "gcdcintra/firstmate" ] \
    || fail "https origin resolved to '$got', expected gcdcintra/firstmate"

  repo=$(make_repo https-origin-nosuffix "origin=https://github.com/gcdcintra/firstmate")
  got=$(fm_gh_repo_from_remote "$repo") || fail "suffixless https origin did not resolve"
  [ "$got" = "gcdcintra/firstmate" ] \
    || fail "suffixless https origin resolved to '$got'"

  # What `git clone https://user@github.com/owner/repo` records. Refusing it
  # would cost a legitimate clone every pull-request and issue answer.
  repo=$(make_repo https-origin-userinfo "origin=https://gcdcintra@github.com/gcdcintra/firstmate.git")
  got=$(fm_gh_repo_from_remote "$repo") || fail "https origin with userinfo did not resolve"
  [ "$got" = "gcdcintra/firstmate" ] \
    || fail "https origin with userinfo resolved to '$got'"
  pass "fm-gh-lib: owner/repo is derived from an https origin remote"
}

test_repo_from_ssh_origin_remote() {
  local repo got
  repo=$(make_repo ssh-origin "origin=git@github.com:gcdcintra/firstmate.git")
  got=$(fm_gh_repo_from_remote "$repo") || fail "scp-style ssh origin did not resolve"
  [ "$got" = "gcdcintra/firstmate" ] \
    || fail "scp-style ssh origin resolved to '$got'"

  repo=$(make_repo ssh-url-origin "origin=ssh://git@github.com/gcdcintra/firstmate.git")
  got=$(fm_gh_repo_from_remote "$repo") || fail "ssh:// origin did not resolve"
  [ "$got" = "gcdcintra/firstmate" ] \
    || fail "ssh:// origin resolved to '$got'"

  # An explicit port is still the same repository on the same host.
  repo=$(make_repo ssh-url-origin-port "origin=ssh://git@github.com:22/gcdcintra/firstmate.git")
  got=$(fm_gh_repo_from_remote "$repo") || fail "ssh:// origin with a port did not resolve"
  [ "$got" = "gcdcintra/firstmate" ] \
    || fail "ssh:// origin with a port resolved to '$got'"
  pass "fm-gh-lib: owner/repo is derived from an ssh origin remote"
}

# Widening the accepted spellings must not widen what counts as GitHub. Each
# origin below either names another host or only looks like it names GitHub;
# resolving any of them would pin queries to a repository that is not ours.
test_origin_urls_that_are_not_github_repositories_are_refused() {
  local url repo got i=0
  for url in \
    "https://gitlab.com/group/project.git" \
    "https://github.com@evil.example/gcdcintra/firstmate.git" \
    "https://user@github.com.evil.example/gcdcintra/firstmate.git" \
    "https://evil.example/x@github.com/gcdcintra/firstmate.git" \
    "ssh://git@github.com:notaport/gcdcintra/firstmate.git" \
    "https://github.com/gcdcintra" \
    "git@gitlab.com:group/project.git" ; do
    i=$((i + 1))
    repo=$(make_repo "refuse-origin-$i" "origin=$url")
    if got=$(fm_gh_repo_from_remote "$repo" 2>/dev/null); then
      fail "origin '$url' resolved to '$got' instead of being refused"
    fi
  done
  pass "fm-gh-lib: an origin that is not a GitHub repository derives nothing"
}

# Preferring `upstream` is the defect. Reading it here even as a fallback would
# reintroduce exactly the wrong answer this library exists to prevent.
test_upstream_remote_is_never_read() {
  local repo
  repo=$(make_repo upstream-only "upstream=https://github.com/kunchenguid/firstmate.git")
  if fm_gh_repo_from_remote "$repo" >/dev/null 2>&1; then
    fail "a repository with only an upstream remote resolved a repository"
  fi

  repo=$(make_repo non-github-origin \
    "origin=https://gitlab.com/group/project.git" \
    "upstream=https://github.com/kunchenguid/firstmate.git")
  if fm_gh_repo_from_remote "$repo" >/dev/null 2>&1; then
    fail "a non-GitHub origin fell back to the upstream remote"
  fi
  pass "fm-gh-lib: the upstream remote is never read, even with no usable origin"
}

test_query_injects_repo_from_origin() {
  local repo fakebin log
  repo=$(make_repo inject-origin "origin=https://github.com/gcdcintra/firstmate.git")
  fakebin=$(make_recording_tools inject)
  log="$TMP_ROOT/inject.log"
  : > "$log"
  FM_TEST_TOOL_LOG="$log" PATH="$fakebin:$PATH" \
    fm_gh_query gh-axi "$repo" pr list --state all --head fm/x --limit 1 \
    || fail "query with a resolvable origin failed"
  assert_grep "--repo gcdcintra/firstmate" "$log" \
    "query did not pin the repository derived from origin"
  assert_grep "pr list --state all --head fm/x --limit 1" "$log" \
    "query did not forward the caller's own arguments"
  pass "fm-gh-lib: a resolvable origin pins the repository on the invocation"
}

test_already_pinned_arguments_pass_through() {
  local repo fakebin log
  # An upstream-preferring layout: passing through unchanged is only safe because
  # the caller's own argument already names the repository.
  repo=$(make_repo pinned-args \
    "origin=https://github.com/gcdcintra/firstmate.git" \
    "upstream=https://github.com/kunchenguid/firstmate.git")
  fakebin=$(make_recording_tools pinned)
  log="$TMP_ROOT/pinned.log"

  : > "$log"
  FM_TEST_TOOL_LOG="$log" PATH="$fakebin:$PATH" \
    fm_gh_query gh "$repo" pr view "https://github.com/gcdcintra/firstmate/pull/9" --json state \
    || fail "URL-pinned query failed"
  assert_grep "pr view https://github.com/gcdcintra/firstmate/pull/9 --json state" "$log" \
    "URL-pinned query was not forwarded verbatim"
  assert_no_grep "--repo" "$log" \
    "URL-pinned query had a redundant --repo injected alongside the URL"

  : > "$log"
  FM_TEST_TOOL_LOG="$log" PATH="$fakebin:$PATH" \
    fm_gh_query gh-axi "$repo" pr view 9 --repo other-owner/other-repo \
    || fail "caller-pinned query failed"
  assert_grep "pr view 9 --repo other-owner/other-repo" "$log" \
    "an explicit caller --repo was not preserved"
  assert_no_grep "gcdcintra/firstmate" "$log" \
    "an explicit caller --repo was overridden by the origin remote"
  pass "fm-gh-lib: arguments that already name a repository pass through untouched"
}

# The whole point: when the repository cannot be established, nothing runs.
# Falling through to the tool would hand back the parent project's answer.
test_unresolvable_repository_is_refused_without_running_the_tool() {
  local repo fakebin log rc out
  repo=$(make_repo refuse-no-origin "upstream=https://github.com/kunchenguid/firstmate.git")
  fakebin=$(make_recording_tools refuse)
  log="$TMP_ROOT/refuse.log"
  : > "$log"
  out=$(FM_TEST_TOOL_LOG="$log" PATH="$fakebin:$PATH" \
    fm_gh_query gh-axi "$repo" pr list --state all 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unresolvable repository must be refused with status 2"
  assert_contains "$out" "refusing" "the refusal did not say it was refusing"
  [ ! -s "$log" ] || fail "the tool was invoked anyway: $(cat "$log")"

  # A directory that is not a git repository at all refuses the same way.
  mkdir -p "$TMP_ROOT/not-a-repo"
  : > "$log"
  out=$(FM_TEST_TOOL_LOG="$log" PATH="$fakebin:$PATH" \
    fm_gh_query gh "$TMP_ROOT/not-a-repo" pr view 6 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a non-repository directory must be refused with status 2"
  [ ! -s "$log" ] || fail "the tool ran for a non-repository directory: $(cat "$log")"

  # A missing directory, and an unsupported tool, are refused before anything runs.
  : > "$log"
  out=$(FM_TEST_TOOL_LOG="$log" PATH="$fakebin:$PATH" \
    fm_gh_query gh "$TMP_ROOT/missing-dir" pr view 6 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a missing directory must be refused with status 2"
  out=$(FM_TEST_TOOL_LOG="$log" PATH="$fakebin:$PATH" \
    fm_gh_query curl "$TMP_ROOT" pr view 6 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unsupported tool must be refused with status 2"
  [ ! -s "$log" ] || fail "something ran during the refusal cases: $(cat "$log")"
  pass "fm-gh-lib: an unresolvable repository is refused before the tool runs"
}

test_repo_from_canonical_pr_url
test_non_canonical_urls_resolve_nothing
test_repo_from_https_origin_remote
test_repo_from_ssh_origin_remote
test_origin_urls_that_are_not_github_repositories_are_refused
test_upstream_remote_is_never_read
test_query_injects_repo_from_origin
test_already_pinned_arguments_pass_through
test_unresolvable_repository_is_refused_without_running_the_tool
