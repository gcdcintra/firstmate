#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# A live recorded owner is refused, with one evidence-gated exception: when
# fm-session-lock-lib.sh proves the owner is this session's own fork source and
# that it has produced nothing since the fork, the lock is taken over and the
# source process is left running untouched.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then
    if fm_claude_fork_descendant_of_pid "$old"; then
      echo "lock: held by live harness pid $old, this session's quiescent fork source (reclaimable)"
    else
      echo "lock: held by live harness pid $old"
    fi
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CLAIM_LOCK"
CLAIM_LOCK_HELD=1

TOOK_FROM_FORK_SOURCE=
if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    # A live owner is refused unless it is provably this session's own fork
    # source, still quiescent since the fork. That evidence is owned by
    # fm-session-lock-lib.sh and fails closed into this same refusal.
    if ! fm_claude_fork_descendant_of_pid "$old"; then
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
      exit 1
    fi
    TOOK_FROM_FORK_SOURCE=$old
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
# A fork source can start a turn between the proof and the write, which would
# make it a live competing session after all. Re-prove it while still holding
# the claim lock, and hand the lock straight back if it moved.
if [ -n "$TOOK_FROM_FORK_SOURCE" ] && ! fm_claude_fork_descendant_of_pid "$TOOK_FROM_FORK_SOURCE"; then
  printf '%s\n' "$TOOK_FROM_FORK_SOURCE" > "$LOCK" 2>/dev/null || true
  echo "error: the session this one forked from resumed work and keeps the lock (pid $TOOK_FROM_FORK_SOURCE); operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
if [ -n "$TOOK_FROM_FORK_SOURCE" ]; then
  echo "lock acquired: harness pid $me (taken from quiescent fork source pid $TOOK_FROM_FORK_SOURCE, which was left running)"
else
  echo "lock acquired: harness pid $me"
fi
