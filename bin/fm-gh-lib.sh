#!/usr/bin/env bash
# fm-gh-lib.sh - the single owner of repository resolution for every `gh` and
# `gh-axi` pull-request and issue query firstmate makes.
#
# Why this library exists. `gh` chooses a "base repo" from the checkout's
# remotes, and in a fork whose clone carries no `remote.<name>.gh-resolved`
# setting it prefers the `upstream` remote over `origin`. Every `gh` and
# `gh-axi` pr/issue subcommand inherits that choice, so a bare `gh-axi pr view
# 6` run inside a fork answers about the PARENT project's pull request 6 - a
# different change, with its own author, its own state, and its own green
# checks - and nothing in the answer says it came from another repository. A
# wrong answer here reads exactly like a right one, which is why the resolution
# is taken away from the tool rather than left to it.
#
# Resolution order, first match wins:
#   1. a canonical GitHub pull-request or issue URL already among the
#      arguments, which pins the repository by itself, so nothing is injected;
#   2. an explicit --repo/-R the caller already passed;
#   3. the `origin` remote of the given directory, injected as --repo.
# `origin` is the only remote ever read, because preferring `upstream` is the
# behavior this library exists to contain.
#
# When none of those yields a repository the call is REFUSED before any network
# request instead of falling back to the tool's own inference. Callers must
# treat a refusal as "no answer", never as a negative answer: teardown asking
# "is this branch's PR merged?" has to fall through to its content check, not
# conclude the work never landed.
#
# Usage (sourced; see tests/fm-gh-lib.test.sh for the behavior contract):
#   fm_gh_repo_from_url <url>           owner/repo from a canonical PR URL
#   fm_gh_repo_from_remote_url <url>    owner/repo from one remote's URL
#   fm_gh_repo_from_remote <dir>        owner/repo from <dir>'s origin remote
#   fm_gh_query <gh|gh-axi> <dir> <arg>...   run the query with a pinned repo

FM_GH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical URL parsing belongs to fm-pr-lib.sh; source it only when the caller
# has not already, so a caller mid-way through its own parse keeps its state.
if ! declare -F fm_pr_url_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$FM_GH_LIB_DIR/fm-pr-lib.sh"
fi

# Is <candidate> a well-formed GitHub owner/repository pair? Mirrors the owner
# and repository classes fm-pr-lib.sh applies to canonical URLs.
fm_gh_owner_repo_valid() {
  local candidate=${1-}
  local LC_ALL=C
  [[ "$candidate" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})$ ]] || return 1
  [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
  [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ]
}

# owner/repo from a canonical GitHub pull-request URL. The parse itself is
# fm-pr-lib.sh's, run in a subshell so its FM_PR_* globals never leak into a
# caller that is holding its own parse result.
fm_gh_repo_from_url() {
  (
    fm_pr_url_parse "${1-}" || exit 1
    [ "$FM_PR_PROVIDER" = github ] || exit 1
    printf '%s/%s\n' "$FM_PR_OWNER" "$FM_PR_REPO"
  )
}

# Does this single argument pin the repository on its own?
fm_gh_arg_is_repo_url() {
  local LC_ALL=C
  [[ "${1-}" =~ ^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/(pull|issues)/[1-9][0-9]*$ ]]
}

# Do the caller's own arguments already name a repository?
fm_gh_args_pin_repo() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*) return 0 ;;
    esac
    fm_gh_arg_is_repo_url "$arg" && return 0
  done
  return 1
}

# owner/repo from a single remote's URL, GitHub hosts only. Accepts the
# spellings git itself records: https:// and ssh:// with optional userinfo and
# an optional port, the scp-style git@github.com:, and an optional .git suffix -
# `git clone https://user@github.com/owner/repo` records the userinfo form, and
# refusing it would cost a legitimate clone its repository for no gain.
#
# Userinfo is stripped inside the authority only, and the host must then be
# github.com exactly, so a path segment dressed up as a host
# (https://evil.example/x@github.com/owner/repo) refuses like any other host. A
# non-GitHub host, another scheme, or anything that does not parse returns
# non-zero rather than a guess, so a GitLab-hosted project refuses here instead
# of being asked about the wrong forge.
fm_gh_repo_from_remote_url() {
  local url=${1-} rest authority host port owner_repo
  case "$url" in
    https://*|ssh://*)
      rest=${url#*://}
      case "$rest" in
        */*) ;;
        *) return 1 ;;
      esac
      authority=${rest%%/*}
      owner_repo=${rest#*/}
      host=${authority##*@}
      case "$host" in
        *:*)
          port=${host##*:}
          host=${host%:*}
          [[ "$port" =~ ^[0-9]+$ ]] || return 1
          ;;
      esac
      [ "$host" = github.com ] || return 1
      ;;
    git@github.com:*) owner_repo=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  owner_repo=${owner_repo%/}
  owner_repo=${owner_repo%.git}
  fm_gh_owner_repo_valid "$owner_repo" || return 1
  printf '%s\n' "$owner_repo"
}

# owner/repo from <dir>'s `origin` remote. A missing origin, or a URL
# fm_gh_repo_from_remote_url refuses, returns non-zero rather than a guess, so a
# remote-less project refuses here instead of falling back to another remote.
#
# The configured URL is read with `git config` rather than `git remote get-url`
# because get-url applies url.<base>.insteadOf rewriting. What is wanted here is
# the remote's declared identity - which repository this is - not the transport
# a local mirror or proxy rewrite happens to send it over.
fm_gh_repo_from_remote() {
  local dir=${1-} url
  [ -n "$dir" ] || return 1
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || return 1
  fm_gh_repo_from_remote_url "$url"
}

# Run `gh` or `gh-axi` with the repository pinned, from inside <dir> so a
# project worktree resolves its own project rather than whatever directory
# firstmate happens to be standing in. Returns 2 without running anything when
# the repository cannot be established.
fm_gh_query() {
  local tool=${1-} dir=${2-} repo
  case "$tool" in
    gh|gh-axi) ;;
    *)
      printf 'fm-gh-lib: unsupported tool: %s\n' "${tool:-<unset>}" >&2
      return 2
      ;;
  esac
  [ "$#" -ge 3 ] || {
    printf 'fm-gh-lib: refusing %s with no query arguments\n' "$tool" >&2
    return 2
  }
  shift 2
  [ -d "$dir" ] || {
    printf 'fm-gh-lib: refusing "%s %s" - no such directory: %s\n' \
      "$tool" "$1" "${dir:-<unset>}" >&2
    return 2
  }
  if fm_gh_args_pin_repo "$@"; then
    ( cd "$dir" && exec "$tool" "$@" )
    return $?
  fi
  repo=$(fm_gh_repo_from_remote "$dir") || {
    printf 'fm-gh-lib: refusing "%s %s" - no explicit repository and no GitHub origin remote in %s\n' \
      "$tool" "$1" "$dir" >&2
    return 2
  }
  ( cd "$dir" && exec "$tool" "$@" --repo "$repo" )
}
