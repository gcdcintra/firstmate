#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm.sh), which fires on the same Stop event:
#   1. a live identity-matched watcher with a fresh beacon allows immediately;
#   2. otherwise wait briefly (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS, default 800ms)
#      for the auto-arm to claim this home (state/.claude-autoarm.lock owner
#      alive) or to record a fresh actionable exit-2 outcome
#      (state/.claude-autoarm-epoch) for this event epoch - either proof allows
#      without consuming a continuation, so one event epoch yields exactly one recovery turn;
#      the first fresh exhausted-failure epoch preserves the bounded progression,
#      while later fresh failed epochs consume it instead of resetting it;
#   3. only when neither materializes is the auto-arm genuinely absent: re-block
#      with the repair banner, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET
#      (default 3) consecutive blocks per session - safely below Claude Code's
#      hard 8-consecutive-block override - then allow one loud attended
#      fail-open only for an already verified failure episode.
#
# Stood-down outcome (the fleet lock records a live owner this session cannot
# match to its own): the Stop-owned auto-arm stays INERT
# (bin/fm-claude-stop-autoarm.sh) and never writes an epoch or an EXHAUSTED
# FAILURE notice for this home - so step 3 above can never become reachable while
# waiting on that failure.
# The recorded owner may be a second session that owns recovery, or this
# session's own displaced predecessor whose continuity could not be proven. No
# command available to the operator separates those readings - bin/fm-lock.sh
# status prints the same live-pid line for both - so the banner and the alarm
# name the recorded pid and REPORT which reading the refusing sub-check actually
# supports (FM_SESSION_LOCK_OWNER_EVIDENCE, published by the shared predicate)
# instead of asserting one or asking the operator to establish it. Neither tells
# the operator to skip inspecting this session's hook registration - a
# misconfigured hook is silent in exactly the same way, and the 2026-08-14
# incident stayed hidden for an evening behind a message that ruled that
# inspection out.
# This guard treats the stood-down case as its own
# first-class outcome: it accounts that case on the SAME bounded
# state/.turnend-claude-blocks budget as step 3, incrementing once per turn
# instead of deduping against an epoch that cannot advance, so the two reasons
# share one budget and can never stack past it. Once that shared budget is
# exhausted the stood-down outcome allows the same one loud attended fail-open,
# sharing state/.claude-autoarm-failure-alarmed with the ordinary progression so
# only one alarm ever fires per unresolved episode regardless of which reason
# triggered it first (2026-08-08 incident).
#
# Away mode (state/.afk) owns supervision itself, so a stood-down turn end there
# blocks with the away-mode reason and accounts NOTHING: the reason override,
# the accounting, and the fail-open are all excluded together. The attended
# fail-open is a single-shot resource, and an unattended away stretch must not
# spend the bounded blocks that belong to the first attended turn after the
# return - away mode's own return catch-up already reports that supervision was
# down while away.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
CLAUDE_MODE=0
SYNC_WAIT_MS=${FM_CLAUDE_AUTOARM_SYNC_WAIT_MS:-800}
EPOCH_FRESH=${FM_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
BLOCK_BUDGET=${FM_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
case "$SYNC_WAIT_MS" in ''|*[!0-9]*) SYNC_WAIT_MS=800 ;; esac
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude]" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$CLAUDE_MODE" -eq 0 ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

BUDGET_FILE="$STATE/.turnend-claude-blocks"
BUDGET_LOCK="$STATE/.turnend-claude-blocks.lock"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
FOREIGN_LOCK_OWNER_ALIVE=0
# What the stood-down outcome actually read, taken from the shared predicate's
# own published values so the banner and the alarm can never name a pid, a
# session, or a reason the decision did not use - this guard never re-reads
# state/.lock for its message. Naming them is what makes the outcome checkable
# instead of an assertion about who owns the home.
FOREIGN_LOCK_OWNER_PID='unknown'
FOREIGN_LOCK_OWNER_SESSION=''
FOREIGN_LOCK_OWNER_EVIDENCE='owner-unresolved'
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')

# Capture the deciding read of fm_session_lock_foreign_owner_alive(). Called
# only where that predicate has just returned true, so these always describe a
# read that actually produced the stood-down outcome.
capture_standdown_owner() {
  FOREIGN_LOCK_OWNER_PID=$FM_SESSION_LOCK_OWNER_PID
  FOREIGN_LOCK_OWNER_SESSION=$FM_SESSION_LOCK_OWNER_SESSION
  FOREIGN_LOCK_OWNER_EVIDENCE=$FM_SESSION_LOCK_OWNER_EVIDENCE
}

# The ONE rendering of what the refusal actually established, shared by the
# stderr banner and the JSON alarm so the two operator-facing texts can never
# disagree. It reports the evidence rather than directing the operator to
# establish the reading themselves: no command available to them separates a
# second live session from this session's own displaced predecessor, because
# bin/fm-lock.sh status prints the same live-pid line for both (2026-08-14
# incident). Apostrophe-free, because the JSON alarm below is a single-quoted
# printf format that cannot carry one.
standdown_evidence() {
  case "$FOREIGN_LOCK_OWNER_EVIDENCE" in
    transcript-diverged)
      printf 'The evidence supports a second live session: that process runs Claude session %s, whose transcript has diverged from the transcript of this session, so it has taken turns of its own.' \
        "$FOREIGN_LOCK_OWNER_SESSION" ;;
    transcript-missing)
      printf 'The evidence is inconclusive: that process runs Claude session %s, but a transcript needed to compare the two could not be read, so continuity was never tested.' \
        "$FOREIGN_LOCK_OWNER_SESSION" ;;
    owner-not-claude)
      printf 'The evidence supports a primary of another kind: that process is a live verified harness that is not Claude Code, so no Claude fork continuity with it is possible at all, and recovering supervision for this home belongs to that primary.' ;;
    owner-unresolved)
      printf 'The evidence is inconclusive: that process is a live Claude harness that no live session record vouches for, neither its own nor one for the harness run it heads, which is equally how the displaced predecessor of this session reads after a fork and how a session the registry has already dropped reads.' ;;
    job-record-unproven)
      printf 'The evidence is inconclusive: this session runs inside a Claude Code background job whose own record does not name Claude session %s as the session it continues, so continuity was never tested.' \
        "$FOREIGN_LOCK_OWNER_SESSION" ;;
    owner-is-this-session)
      printf 'The evidence is contradictory: that process resolves to the session id of this very session while sitting outside the harness ancestry of this process.' ;;
    *)
      printf 'The evidence is inconclusive: this process carries no Claude session id, so no continuity evidence could be produced at all, which is itself worth diagnosing.' ;;
  esac
}
budget_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  fm_lock_try_acquire "$BUDGET_LOCK" || return 0
  rm -f "$BUDGET_FILE" 2>/dev/null || true
  fm_lock_release "$BUDGET_LOCK"
}

fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" = false ]; then
  [ -e "$FAILURE_NOTICE" ] || budget_reset
  exit 0
fi
if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  [ "$CLAUDE_MODE" -eq 1 ] || exit 0
  fm_failure_episode_reset "$STATE" && exit 0
  exit 2
fi

block_stop() {
  local afk x_mode reason rule
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  if [ "$CLAUDE_MODE" -eq 1 ] && [ "$FOREIGN_LOCK_OWNER_ALIVE" -eq 1 ] && [ "$afk" -eq 0 ]; then
    reason="this home's fleet lock records live process $FOREIGN_LOCK_OWNER_PID, which this session could not match to its own, so the Stop-owned auto-arm stayed inert and will never record a failure here. $(standdown_evidence) Inspect the Stop hook registration of this session as well, because a broken hook is silent in exactly this way."
  else
    reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
      || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  fi
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
      printf '●  %s process-event source(s) registered, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_SOURCES" "$FM_SUP_BEACON_DESC"
    else
      printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_BEACON_DESC"
    fi
    printf '●  Failing condition: %s.\n' \
      "$(fm_watcher_unhealthy_description "$FM_WATCHER_UNHEALTHY_REASON" "$FM_WATCHER_UNHEALTHY_DETAIL")"
    if [ "$CLAUDE_MODE" -eq 1 ]; then
      printf '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.\n'
    fi
    printf '●  %s\n' "$reason"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

# The one description of WHAT still needs supervision, shared by every attended
# fail-open message so the two alarms cannot drift apart.
need_desc() {
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    printf '%s task(s) in flight' "$FM_SUP_IN_FLIGHT"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    printf '%s process-event source(s) registered' "$FM_SUP_SOURCES"
  else
    printf 'X-mode relay polling active'
  fi
}

if [ "$CLAUDE_MODE" -eq 0 ]; then
  block_stop
fi

# --- --claude cooperative path -----------------------------------------------
# The Stop-owned auto-arm fires on the same Stop event. Give it a brief bounded
# window to prove it owns recovery for this event epoch before consuming one of
# Claude's bounded continuations.
budget_account_current_epoch() {
  local current_epoch outcome old_session old_count old_epoch tmp initialized
  fm_lock_try_acquire "$BUDGET_LOCK" || return 1
  current_epoch=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  initialized=0
  COUNT=0
  if [ -f "$BUDGET_FILE" ]; then
    old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_epoch=$(sed -n '3s/^epoch=//p' "$BUDGET_FILE" 2>/dev/null || true)
    case "$old_count" in
      ''|*[!0-9]*) old_count=0 ;;
    esac
    if [ "$old_session" = "$SESSION_ID" ]; then
      COUNT=$old_count
      if [ -n "$current_epoch" ] && [ "$old_epoch" = "$current_epoch" ]; then
        :
      else
        COUNT=$((COUNT + 1))
      fi
    fi
  fi
  if [ ! -f "$BUDGET_FILE" ] || [ "${old_session:-}" != "$SESSION_ID" ]; then
    case "$outcome" in
      failed|failed-suppressed)
        if [ -e "$FAILURE_NOTICE" ]; then
          initialized=1
          COUNT=0
        else
          COUNT=1
        fi
        ;;
      *) COUNT=1 ;;
    esac
  fi
  tmp="$BUDGET_FILE.tmp.$$"
  if ! printf 'session=%s\ncount=%s\nepoch=%s\n' "$SESSION_ID" "$COUNT" "$current_epoch" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$BUDGET_LOCK"
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  BUDGET_INITIALIZED_FAILURE=$initialized
  fm_lock_release "$BUDGET_LOCK"
  return 0
}

autoarm_owns_recovery() {
  local pid role outcome age
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0
  pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if fm_pid_alive "$pid" && [ "$role" = autoarm ]; then
    [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
    return 0
  fi
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    rewake)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ]; then
        [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
        return 0
      fi
      ;;
    failed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        [ "$BUDGET_INITIALIZED_FAILURE" -eq 1 ] && return 0
      fi
      ;;
    failed-suppressed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        :
      fi
      ;;
  esac
  return 1
}

terminal_fail_open() {
  local pid role old_session old_count
  [ "$COUNT" -gt "$BLOCK_BUDGET" ] || return 1
  failure_episode_verified || return 1
  [ ! -e "$FAILURE_ALARM" ] || return 1
  if ! fm_lock_try_acquire "$OWNER_LOCK"; then
    pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
    role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
    if fm_pid_alive "$pid" && [ "$role" = autoarm ]; then
      return 2
    fi
    return 1
  fi
  if ! fm_lock_set_role "$OWNER_LOCK" terminal-check; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if ! fm_lock_try_acquire "$BUDGET_LOCK"; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if [ "$role" != terminal-check ] || [ "$old_session" != "$SESSION_ID" ] \
    || [ "$old_count" -le "$BLOCK_BUDGET" ] || ! failure_episode_verified \
    || [ -e "$FAILURE_ALARM" ]; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    if ! fm_failure_episode_reset "$STATE" held; then
      fm_lock_release "$BUDGET_LOCK"
      fm_lock_release "$OWNER_LOCK"
      return 1
    fi
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 2
  fi
  if ! (set -C; : > "$FAILURE_ALARM") 2>/dev/null; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$BUDGET_LOCK"
  fm_lock_release "$OWNER_LOCK"
  return 0
}

failure_episode_verified() {
  local outcome
  [ ! -e "$STATE/.afk" ] || return 1
  [ -e "$FAILURE_NOTICE" ] || return 1
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    failed|failed-suppressed) return 0 ;;
    *) return 1 ;;
  esac
}

# --- stood-down accounting (the lock records an unmatched live owner) --------
# Shares the one BUDGET_FILE record, and its BUDGET_LOCK, with
# budget_account_current_epoch() above: a single persisted counter is what keeps
# the two reasons for re-blocking from independently reaching BLOCK_BUDGET and
# stacking to twice it, and it keeps every writer of that record - including
# fm_failure_episode_reset() - under the same lock.
#
# What it must NOT share is that function's epoch dedup: the auto-arm epoch
# never advances while it stays inert (see the header comment), so every call
# would see the same unchanging epoch and never distinguish "still the same
# turn" from "the auto-arm never ran again". This outcome therefore increments
# once per turn unconditionally, and passes the record's epoch field through
# unchanged so a later transition back to the ordinary progression still reads
# the epoch that progression recorded.
standdown_account() {
  local old_session old_count old_epoch='' tmp
  fm_lock_try_acquire "$BUDGET_LOCK" || return 1
  COUNT=1
  if [ -f "$BUDGET_FILE" ]; then
    old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_epoch=$(sed -n '3s/^epoch=//p' "$BUDGET_FILE" 2>/dev/null || true)
    case "$old_count" in
      ''|*[!0-9]*) old_count=0 ;;
    esac
    [ "$old_session" = "$SESSION_ID" ] && COUNT=$((old_count + 1))
  fi
  tmp="$BUDGET_FILE.tmp.$$"
  if ! printf 'session=%s\ncount=%s\nepoch=%s\n' "$SESSION_ID" "$COUNT" "$old_epoch" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$BUDGET_LOCK"
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$BUDGET_LOCK"
  return 0
}

# Same bounded-then-loud-once contract as terminal_fail_open(), on the shared
# block budget but keyed to the live foreign lock owner instead of the auto-arm
# epoch/failure-notice evidence, and sharing the same FAILURE_ALARM so only one
# attended alarm ever fires per unresolved episode. Returns 0 (alarm fired,
# report genuinely down), 1 (not yet eligible - caller falls through to an
# ordinary block), or 2 (recovered between accounting and this check - episode
# reset, allow the stop).
standdown_terminal_fail_open() {
  [ "$COUNT" -gt "$BLOCK_BUDGET" ] || return 1
  [ ! -e "$STATE/.afk" ] || return 1
  [ ! -e "$FAILURE_ALARM" ] || return 1
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    fm_failure_episode_reset "$STATE" || return 1
    return 2
  fi
  fm_session_lock_foreign_owner_alive "$STATE" || return 1
  capture_standdown_owner
  (set -C; : > "$FAILURE_ALARM") 2>/dev/null
}

i=0
while [ "$i" -lt $((SYNC_WAIT_MS / 100)) ]; do
  if autoarm_owns_recovery; then
    if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
      fm_failure_episode_reset "$STATE" || exit 2
    fi
    exit 0
  fi
  sleep 0.1
  i=$((i + 1))
done
if autoarm_owns_recovery; then
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    fm_failure_episode_reset "$STATE" || exit 2
  fi
  exit 0
fi

# The lock may record a live owner this session cannot match to its own, in which
# case the auto-arm above stayed inert and never wrote the epoch/failure
# evidence the ordinary progression below waits for (see the header comment).
# Handle that stood-down outcome on the shared block budget before assuming a
# genuine auto-arm failure. Away mode owns supervision itself, so it blocks here
# without spending any of that budget (see the header comment).
if fm_session_lock_foreign_owner_alive "$STATE"; then
  FOREIGN_LOCK_OWNER_ALIVE=1
  capture_standdown_owner
  [ ! -e "$STATE/.afk" ] || block_stop
  standdown_account || block_stop
  standdown_terminal_fail_open
  standdown_status=$?
  if [ "$standdown_status" -eq 0 ]; then
    NEED_DESC=$(need_desc)
    printf '{"systemMessage":"FIRSTMATE SUPERVISION IS GENUINELY DOWN: %s, this home fleet lock records live process %s which this session could not match to its own so the Stop-owned auto-arm stayed inert and will never record a failure here, no watcher or automatic continuation exists here, and the block budget is exhausted. %s Keep this session attended, and inspect the Stop hook registration of this session as well, because a broken hook is silent in exactly this way."}\n' \
      "$NEED_DESC" "$FOREIGN_LOCK_OWNER_PID" "$(standdown_evidence)"
    exit 0
  fi
  [ "$standdown_status" -eq 2 ] && exit 0
  block_stop
fi

# The auto-arm genuinely failed to establish: consume the bounded re-block
# budget before considering the verified one-time attended fail-open.
budget_account_current_epoch || block_stop
terminal_fail_open
terminal_status=$?
if [ "$terminal_status" -eq 0 ]; then
  NEED_DESC=$(need_desc)
  printf '{"systemMessage":"FIRSTMATE SUPERVISION IS GENUINELY DOWN: %s, the Stop-owned auto-arm exhausted its bounded retries and one failure notice, no watcher or automatic continuation exists, and the block budget is exhausted. Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision."}\n' "$NEED_DESC"
  exit 0
fi
[ "$terminal_status" -eq 2 ] && exit 0
block_stop
