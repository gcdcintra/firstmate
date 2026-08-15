#!/usr/bin/env bash
# fm-gh-repo-guard.sh - refuse any GitHub pull-request or issue query in bin/
# that does not name its repository.
#
# bin/fm-gh-lib.sh can only defend the callers that use it. This guard is what
# makes using it structural rather than remembered: a rule every future caller
# has to recall is a rule that eventually gets dropped, and the failure it
# produces here is silent, because an answer about the wrong repository looks
# exactly like an answer about the right one.
#
# A `gh` or `gh-axi` pr/issue invocation in bin/ is accepted when it either
#   - goes through fm_gh_query, or
#   - names the repository with --repo/-R on the same line,
# and is refused otherwise. Comment lines are ignored. The allowlist below
# carries the only exemptions, each with the reason it is safe.
#
# A scan that matched no scripts proves nothing, so it exits 2 rather than
# reporting success: a --root pointed one level off must fail like the argument
# error it is, not read as a clean bin/.
#
# Usage:
#   bin/fm-gh-repo-guard.sh              guard this repository's bin/
#   bin/fm-gh-repo-guard.sh --root <dir> guard another checkout's bin/
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { printf 'fm-gh-repo-guard: --root requires a path\n' >&2; exit 2; }
      ROOT=$(cd "$2" && pwd) || exit 2
      shift 2
      ;;
    --help|-h)
      sed -n '2,23{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) printf 'fm-gh-repo-guard: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Exempt paths, relative to the repository root, and why each one is safe.
#
# bin/fm-gh-lib.sh          is the resolver itself; it names the tools in order
#                           to run them, and its refusal is the guarded behavior.
# bin/fm-pr-check.sh        queries only a canonical PR URL that fm-pr-lib.sh has
# bin/fm-pr-poll.sh         already validated, and a URL names its own repository.
#                           Both also carry live merge-poll identity bindings, so
#                           they are deliberately left byte-stable.
is_allowlisted() {
  case "$1" in
    bin/fm-gh-lib.sh|bin/fm-pr-check.sh|bin/fm-pr-poll.sh) return 0 ;;
  esac
  return 1
}

findings=0
scanned=0
for path in "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh; do
  [ -f "$path" ] || continue
  rel=${path#"$ROOT"/}
  is_allowlisted "$rel" && continue
  scanned=$((scanned + 1))
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    # Skip comments: prose about these tools is not an invocation.
    case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
    # An invocation of gh or gh-axi with a pr/issue subcommand.
    case "$line" in
      *gh\ pr\ *|*gh\ issue\ *|*gh-axi\ pr\ *|*gh-axi\ issue\ *) ;;
      *) continue ;;
    esac
    # Accepted when the repository is named, or the resolver owns the call.
    case "$line" in
      *fm_gh_query*|*--repo*|*\ -R\ *) continue ;;
    esac
    printf '%s:%s: GitHub query without an explicit repository: %s\n' \
      "$rel" "$line_number" "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" >&2
    findings=$((findings + 1))
  done < "$path"
done

if [ "$scanned" -eq 0 ]; then
  printf 'fm-gh-repo-guard: no scripts to scan under %s/bin - nothing was checked, so nothing is proven.\n' \
    "$ROOT" >&2
  printf 'Point --root at the root of a checkout whose bin/ holds the scripts to guard.\n' >&2
  exit 2
fi
if [ "$findings" -gt 0 ]; then
  printf 'fm-gh-repo-guard: %s unpinned GitHub query/queries found.\n' "$findings" >&2
  printf 'Route them through fm_gh_query (bin/fm-gh-lib.sh) or pass --repo explicitly.\n' >&2
  exit 1
fi
printf 'fm-gh-repo-guard: ok scripts=%s\n' "$scanned"
