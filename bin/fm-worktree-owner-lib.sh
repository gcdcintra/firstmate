#!/usr/bin/env bash
# fm-worktree-owner-lib.sh - prove a task's recorded worktree still belongs to
# that task before anything acts destructively on it. No side effects on source.
# set -u / set -e safe.
#
# WHY THIS EXISTS. A pooled treehouse worktree is NOT reserved by the shell or
# agent sitting in it. When a task's pane disappears, the pool sees an unused
# worktree and correctly leases that slot to a freshly spawned task, while the
# first task's state/<id>.meta still records the same path. Everything that
# trusts that stale worktree= then acts inside another task's live work:
# bin/fm-teardown.sh would delete its branch, remove its harness hook files,
# terminate its processes, and return ITS worktree to the pool.
#
# WHAT PROVES OWNERSHIP. treehouse records a holder only for worktrees taken
# with `treehouse get --lease` (`lease_holder` in `treehouse status --json`).
# Firstmate leases secondmate HOMES that way, so their ownership is already
# provable through treehouse itself and callers should use
# `treehouse return --if-lease-holder <id>`. Ordinary crewmate ship/scout
# worktrees come from a plain pooled `treehouse get`, which records no holder at
# all - so this library maintains the missing record: a marker file written into
# the worktree at spawn, carrying a token that is also recorded as
# worktree_owner= in state/<id>.meta. Ownership holds only when both agree.
#
# SCOPE OF THE GUARANTEE. This DETECTS a reassigned worktree; it does not
# reserve one. The marker is added to the repo's info/exclude (like every other
# firstmate worktree artifact), so it never shows up in `git status`, never
# reaches a commit, and deliberately does NOT make the slot look dirty to
# treehouse - reserving pool slots is treehouse's own job, through leases, and
# flipping the pool from self-healing to held-until-returned is a separate
# decision.
#
# The limit that follows from that, stated plainly: a reclaim does not clean the
# worktree, so a released slot keeps the old marker until its next holder writes
# one. Every firstmate spawn does write one, which is what makes the observed
# shape - one task's slot re-leased to a newly spawned task - detectable. A
# holder that writes NO marker (a person's own `treehouse get`, or the window
# between another spawn's `treehouse get` and its write) leaves the stale record
# in place, and the previous task would read it as `ours`. That residual window
# is inherent to detecting rather than reserving; only taking crewmate worktrees
# with `treehouse get --lease` would close it, at the cost of a pool that no
# longer self-heals. `absent` therefore refuses rather than assuming the
# worktree is still ours, since absence is the one state that cannot be trusted
# either way.
#
# The marker is NOT authority over anything else. It never authorizes a
# teardown, never overrides an unlanded-work refusal, and never substitutes for
# endpoint validation; it can only withhold permission to touch a worktree.
#
# Verdicts from fm_worktree_owner_verdict:
#   ours       marker token matches the expected token - safe to proceed
#   other      marker names a different task - REFUSE, a sibling holds this path
#   absent     no marker - ownership cannot be proven, REFUSE
#   unreadable marker exists but is malformed/unreadable - REFUSE
# Only `ours` is permission. Everything else is a refusal, never a downgrade to
# "probably fine".

FM_WORKTREE_OWNER_MARKER=.fm-worktree-owner
# 32 lowercase hex chars minted at spawn; also recorded as worktree_owner= in meta.
FM_WORKTREE_OWNER_TOKEN_RE='^[0-9a-f]{32}$'

fm_worktree_owner_marker_path() {  # <worktree>
  [ -n "${1:-}" ] || return 1
  printf '%s/%s' "$1" "$FM_WORKTREE_OWNER_MARKER"
}

# Mint a fresh ownership token. openssl when available, else a seeded digest,
# matching bin/fm-pending-reply-lib.sh's portable id shape.
fm_worktree_owner_mint() {
  local raw='' hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 16 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    hex=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM$RANDOM" \
      | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=$hex
  fi
  raw=$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-32)
  case "$raw" in
    ????????????????????????????????) printf '%s' "$raw" ;;
    *) return 1 ;;
  esac
}

fm_worktree_owner_token_valid() {  # <token>
  [ -n "${1:-}" ] || return 1
  printf '%s' "$1" | grep -Eq "$FM_WORKTREE_OWNER_TOKEN_RE"
}

# Record ownership of <worktree> for <task-id>. Private (0600) so another user
# cannot forge a holder, and excluded from git so it never reaches a commit.
# Refuses to follow what the read side refuses to read: a marker path that is a
# symlink or any other non-regular file is never written through - a planted one
# survives `treehouse return --force` (the clean skips git-excluded files) and
# would otherwise let the next spawn truncate whatever it points at. It is
# removed and replaced with a fresh regular file, or the write fails.
fm_worktree_owner_write() {  # <worktree> <token> <task-id> <home>
  local wt=$1 token=$2 id=$3 home=${4:-} marker excl old_umask
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  fm_worktree_owner_token_valid "$token" || return 1
  marker=$(fm_worktree_owner_marker_path "$wt") || return 1
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    rm -f -- "$marker" 2>/dev/null || return 1
  fi
  old_umask=$(umask)
  umask 077
  {
    printf 'token=%s\n' "$token"
    printf 'task=%s\n' "$id"
    printf 'home=%s\n' "$home"
  } > "$marker" || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  chmod 0600 "$marker" 2>/dev/null || true
  # Same exclusion path fm-spawn uses for its other worktree artifacts, so the
  # crewmate never sees it in git status and cannot commit it into a PR.
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  if [ -n "$excl" ]; then
    mkdir -p "$(dirname "$excl")" 2>/dev/null || true
    grep -qxF "$FM_WORKTREE_OWNER_MARKER" "$excl" 2>/dev/null \
      || printf '%s\n' "$FM_WORKTREE_OWNER_MARKER" >> "$excl" 2>/dev/null || true
  fi
}

fm_worktree_owner_field() {  # <worktree> <key>
  local wt=$1 key=$2 marker
  marker=$(fm_worktree_owner_marker_path "$wt") || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  sed -n "s/^$key=//p" "$marker" 2>/dev/null | head -1
}

# Classify <worktree> against <expected-token>. Sets, for the caller's message:
#   FM_WORKTREE_OWNER_VERDICT  ours|other|absent|unreadable
#   FM_WORKTREE_OWNER_TASK     task id recorded in the marker (may be empty)
#   FM_WORKTREE_OWNER_TOKEN    token recorded in the marker (may be empty)
#   FM_WORKTREE_OWNER_HOME     firstmate home recorded in the marker (may be empty)
# Always returns 0; the verdict is the result. A caller with no expected token
# has nothing to compare and must not call this.
fm_worktree_owner_verdict() {  # <worktree> <expected-token>
  local wt=$1 expected=$2 marker found
  FM_WORKTREE_OWNER_VERDICT=absent
  FM_WORKTREE_OWNER_TASK=
  FM_WORKTREE_OWNER_TOKEN=
  FM_WORKTREE_OWNER_HOME=
  marker=$(fm_worktree_owner_marker_path "$wt") || { FM_WORKTREE_OWNER_VERDICT=unreadable; return 0; }
  if [ -L "$marker" ]; then
    # A symlink is never a record this library wrote; refuse rather than follow
    # it to whatever it points at.
    FM_WORKTREE_OWNER_VERDICT=unreadable
    return 0
  fi
  [ -e "$marker" ] || return 0
  if [ ! -f "$marker" ] || [ ! -r "$marker" ]; then
    FM_WORKTREE_OWNER_VERDICT=unreadable
    return 0
  fi
  found=$(fm_worktree_owner_field "$wt" token || true)
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_WORKTREE_OWNER_TASK=$(fm_worktree_owner_field "$wt" task || true)
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_WORKTREE_OWNER_HOME=$(fm_worktree_owner_field "$wt" home || true)
  if ! fm_worktree_owner_token_valid "$found"; then
    FM_WORKTREE_OWNER_VERDICT=unreadable
    return 0
  fi
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_WORKTREE_OWNER_TOKEN=$found
  if [ "$found" = "$expected" ]; then
    FM_WORKTREE_OWNER_VERDICT=ours
  else
    FM_WORKTREE_OWNER_VERDICT=other
  fi
  return 0
}

# Drop OUR OWN record, and only ours. `treehouse return --force` does not remove
# an excluded file, so a returned slot would otherwise carry a stale holder until
# the next spawn overwrites it - callers clear it once the worktree is released.
# Scoped by token because that release makes the slot available again: if a newer
# task has already claimed it, this must be a no-op rather than erase the new
# holder's record and re-open the very hole this library closes.
fm_worktree_owner_remove() {  # <worktree> <token>
  local wt=${1:-} token=${2:-} marker
  [ -n "$wt" ] || return 0
  fm_worktree_owner_token_valid "$token" || return 0
  fm_worktree_owner_verdict "$wt" "$token"
  [ "$FM_WORKTREE_OWNER_VERDICT" = ours ] || return 0
  marker=$(fm_worktree_owner_marker_path "$wt") || return 0
  rm -f "$marker" 2>/dev/null || true
}
