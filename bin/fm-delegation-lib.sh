#!/usr/bin/env bash
# fm-delegation-lib.sh - the ONE owner of two related contracts: what makes a
# tool name DELEGATION-SHAPED, and what a crewmate's currently-open delegation
# calls look like on disk.
#
# Why the second contract exists. Observed 2026-08-15: a crewmate delegated
# "respond to the review gate" to a helper and sat blocked on it for over two
# hours while its own pipeline carried on without it and opened the PR. Every
# signal supervision consults read healthy, and each was correct about its own
# subject - the harness's busy verdict described a turn that really was open,
# the pipeline's activity clock described the PIPELINE's separate agent, and the
# worker's CPU counter described a pane process that is correct to be quiet
# while a helper runs. The helper sat between the worker and all of them, so the
# block had no wedge-shaped signature at all. This library gives it one.
#
# THE SIGNAL, and why it lives at the TOOL layer rather than the process table.
# A delegation is a tool call, and a tool call is bracketed by hooks the harness
# already fires. That placement is what makes the signal cover BOTH shapes:
#   - a helper in a separate process, where the worker's own CPU reads flat; and
#   - an in-process subagent, where the delegating turn's CPU keeps CLIMBING and
#     reads exactly like healthy work.
# A process-table detector sees only the first. Claude's subagent is verified to
# be the second - its nested tool calls fire hooks in the delegating session
# (docs/verification/supervision.md) - so a descendant scan would have missed
# the observed incident entirely.
#
# THE RECORD. One directory per task, state/<id>.delegating/, holding one file
# per OPEN delegation-shaped tool call, keyed by the harness's own tool-call id:
#
#   v1 ts=<epoch> tool=<tool-name>
#
# Keying by call id is required, not tidiness. A subagent's own tool calls fire
# the same PreToolUse/PostToolUse hooks nested inside the outer delegation call,
# so a close that matched on anything looser would clear the outer record the
# moment the helper ran its first command - which is precisely the window this
# library exists to measure. The epoch lives INSIDE the file rather than in its
# mtime so no copy, restore, or touch can silently restate the age.
#
# WHAT READS IT. bin/fm-wedge-evidence-lib.sh, as a VETO rather than a tier: an
# open delegation older than FM_WEDGE_DELEGATION_BLOCK_SECS denies the soft
# deferral tiers and names the shape in the escalation. A veto inverts the
# fail-safe direction of every other measure here, so every unmeasurable case -
# no directory, an unreadable record, a missing timestamp, a clock that stepped
# backwards - must yield NO veto and leave behavior exactly as it was.
#
# WHAT IT STILL CANNOT SEE. Stated rather than implied:
#   - A helper launched through Bash, or any other tool whose name is not
#     delegation-shaped. This is the same residual docs/subagent-guard.md
#     records for the primary guard, and it has the same cause: the shape test
#     reads a tool NAME, never the work behind it.
#   - Any harness with no per-task tool-call hooks. Only Claude is wired
#     (bin/fm-spawn.sh); docs/subagent-guard.md's harness table owns the
#     per-harness status and the precedent that an unvalidated hook is worse
#     than a missing one.
#   - A delegation whose closing hook never fires. Turn end clears the whole
#     directory, and so does a firstmate interrupt from bin/fm-send.sh, which
#     Claude answers with no hook at all - so staleness is bounded by one turn
#     even on the interrupt-then-steer path a blocked worker is most likely to
#     be given, and a stale record can only cost a deferral the pane would
#     otherwise have been granted - noise, never blindness.
#
# Sourcing: set -u and set -e safe, and dependency-free on purpose, because a
# PreToolUse hook sources it on every tool call a crewmate makes.

# Lowercase substrings that mark a tool name as delegation-shaped: it creates
# work, an agent, a schedule, or an isolated workspace. This list is the single
# owner of that classification for every consumer.
#
# Consumers apply their OWN exclusions on top, because the same name means
# different things to a guard and to a measurement. bin/fm-subagent-pretool-check.sh
# excludes the observe-or-stop and session-local-todo names, since denying those
# would strand a runaway task or stop a primary tracking its own plan. The
# open-call record excludes none of them: a worker parked in a tool that only
# WATCHES a background helper is the very shape being measured, and a tool that
# returns promptly leaves no aged record, so elapsed time filters the harmless
# names on its own without a list to keep in sync.
FM_DELEGATION_STEMS='agent subagent task workflow cron schedul worktree delegate spawn dispatch handoff remote sendmessage monitor'

# fm_delegation_normalize: the lowercase alphanumeric form both the shape test
# and a consumer's exact-name exclusions compare against.
fm_delegation_normalize() {  # <tool-name>
  LC_ALL=C printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

# fm_delegation_shape_match: 0 and the matched stem when <tool-name> is
# delegation-shaped, 1 otherwise.
#
# An MCP tool is never classified. Its name is chosen by an external server
# where a task or agent noun is common, and it has no bearing on fleet dispatch;
# this exclusion is part of the shape contract itself rather than a consumer's,
# so both consumers inherit it.
fm_delegation_shape_match() {  # <tool-name>
  local tool=$1 normalized stem
  [ -n "$tool" ] || return 1
  case "$tool" in
    mcp__*) return 1 ;;
  esac
  normalized=$(fm_delegation_normalize "$tool")
  [ -n "$normalized" ] || return 1
  for stem in $FM_DELEGATION_STEMS; do
    case "$normalized" in
      *"$stem"*) printf '%s' "$stem"; return 0 ;;
    esac
  done
  return 1
}

# fm_delegation_dir: where <task>'s open delegation records live.
fm_delegation_dir() {  # <state-dir> <task>
  printf '%s/%s.delegating' "$1" "$2"
}

# fm_delegation_call_key: the filename for one tool-call id. Untrusted harness
# text becomes a path component here, so everything outside a conservative
# alphabet is dropped and the result is bounded. An id that survives as nothing
# collapses to a single shared key: pairing is then no better than the
# harness's, which is the status quo, and turn end still clears it.
fm_delegation_call_key() {  # <tool-call-id>
  local key
  key=$(LC_ALL=C printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_-')
  key=${key:0:96}
  [ -n "$key" ] || key=unkeyed
  printf '%s' "$key"
}

# fm_delegation_open_age: 0 and "<age-secs> <tool-name>" for the OLDEST open
# delegation call, 1 when there is none or when the answer cannot be measured.
#
# The oldest is the right one to report: it is the call the worker has been
# waiting on longest, and a short inner call must never restate a long outer
# one as fresh. Every unmeasurable case returns 1, because the only consumer is
# a veto and an unmeasurable veto must never fire.
fm_delegation_open_age() {  # <state-dir> <task>
  local dir file now line rest ts tool age
  local best_ts='' best_tool=''
  [ -n "${2:-}" ] || return 1
  dir=$(fm_delegation_dir "$1" "$2")
  [ -d "$dir" ] || return 1
  now=$(date +%s)
  for file in "$dir"/*; do
    [ -f "$file" ] || continue
    IFS= read -r line < "$file" 2>/dev/null || continue
    ts=; tool=
    case "$line" in
      'v1 ts='*' tool='*)
        rest=${line#v1 ts=}
        ts=${rest%% *}
        tool=${rest#* tool=}
        ;;
    esac
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    # A record stamped in the future means the clock stepped backwards, so this
    # call's span is unknowable. Skip it rather than clamping: a clamped age
    # would read as a brand-new call and quietly hide a long one.
    [ "$ts" -le "$now" ] || continue
    if [ -z "$best_ts" ] || [ "$ts" -lt "$best_ts" ]; then
      best_ts=$ts
      best_tool=$tool
    fi
  done
  [ -n "$best_ts" ] || return 1
  age=$(( now - best_ts ))
  [ -n "$best_tool" ] || best_tool='an unnamed delegation tool'
  printf '%s %s' "$age" "$best_tool"
}
