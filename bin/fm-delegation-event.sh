#!/usr/bin/env bash
# fm-delegation-event.sh - the ONLY writer of a task's open-delegation records.
#
# A crewmate's harness calls this from its tool-call hooks so supervision can
# see a worker that is blocked inside a delegation-shaped tool call. The record
# format, the shape test, and the reason this lives at the tool layer are all
# owned by bin/fm-delegation-lib.sh; this script owns only the mutations.
#
# Usage:
#   fm-delegation-event.sh open  <state-dir> <task-id> [--tool <name>] [--call <id>]
#   fm-delegation-event.sh close <state-dir> <task-id> [--call <id>]
#   fm-delegation-event.sh clear <state-dir> <task-id>
#
# open  records one open call, but only when the tool name is delegation-shaped.
# close retires exactly the call whose id it is given.
# clear retires every open call. A turn-end or session-end hook calls it, and so
#       does bin/fm-send.sh on a firstmate interrupt, for which Claude fires no
#       hook of its own: together they bound a record whose closing hook never
#       fired to one turn.
#
# With no --tool or --call, a Claude/Codex-shaped PreToolUse or PostToolUse
# payload is read from stdin (.tool_name and .tool_use_id, or Grok's .toolName
# and .toolUseId). A missing jq, malformed JSON, an unwritable state directory,
# or any other transport failure is silent.
#
# ALWAYS exits 0 and always writes both streams empty. This runs inside a
# worker's own tool-call path, where a nonzero exit or stray output can block a
# tool call or be read as hook feedback. The measurement it feeds is a VETO on
# deferral, so losing an event costs a deferral the pane might have been
# granted - noise - while breaking a worker's turn would cost the task.
set -u

MODE=${1:-}
case "$MODE" in
  open|close|clear) shift ;;
  -h|--help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) exit 0 ;;
esac

STATE=${1:-}
TASK=${2:-}
[ "$#" -lt 2 ] || shift 2
TOOL=""
CALL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool) [ "$#" -gt 1 ] || exit 0; TOOL=$2; shift 2 ;;
    --tool=*) TOOL=${1#--tool=}; shift ;;
    --call) [ "$#" -gt 1 ] || exit 0; CALL=$2; shift 2 ;;
    --call=*) CALL=${1#--call=}; shift ;;
    *) shift ;;
  esac
done

[ -n "$STATE" ] && [ -n "$TASK" ] || exit 0
case "$TASK" in *[/\\]*|.|..) exit 0 ;; esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
# shellcheck source=bin/fm-delegation-lib.sh
. "$SCRIPT_DIR/fm-delegation-lib.sh" 2>/dev/null || exit 0

DIR=$(fm_delegation_dir "$STATE" "$TASK")

if [ "$MODE" = clear ]; then
  rm -rf "$DIR" 2>/dev/null || true
  exit 0
fi

# A close with no directory has no record to retire, so both mutations below are
# already no-ops. Leaving before the payload read keeps that case - the common
# one, since PostToolUse fires for every tool call a crewmate makes - off jq
# entirely, inside the worker's own tool-call latency.
[ "$MODE" != close ] || [ -d "$DIR" ] || exit 0

# Read the payload only when the caller did not already hand over both fields,
# so a hook that passes them on the command line never pays for jq. One jq
# invocation yields both, because this sits in that same latency.
if [ -z "$CALL" ] || { [ "$MODE" = open ] && [ -z "$TOOL" ]; }; then
  if [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
    PAYLOAD=$(cat 2>/dev/null || true)
    if [ -n "$PAYLOAD" ]; then
      # @tsv rather than two lines: it escapes any control character in either
      # field, so no harness value can break the split.
      PARSED=$(printf '%s' "$PAYLOAD" | jq -r '[(.tool_name // .toolName // ""), (.tool_use_id // .toolUseId // "")] | @tsv' 2>/dev/null) || PARSED=""
      if [ -n "$PARSED" ]; then
        [ -n "$TOOL" ] || TOOL=${PARSED%%$'\t'*}
        [ -n "$CALL" ] || CALL=${PARSED#*$'\t'}
      fi
    fi
  fi
fi

KEY=$(fm_delegation_call_key "$CALL")

if [ "$MODE" = close ]; then
  rm -f "$DIR/$KEY" 2>/dev/null || true
  # An empty directory is retired so a torn-down or long-idle task leaves none
  # behind; a still-open sibling call keeps it, and rmdir refuses rather than
  # removing one.
  rmdir "$DIR" 2>/dev/null || true
  exit 0
fi

fm_delegation_shape_match "$TOOL" >/dev/null || exit 0

# Never restate an already-open call as fresh. A harness that re-fires
# PreToolUse for the same call id - a retry, a resumed session - must not reset
# the clock this record exists to keep.
[ ! -e "$DIR/$KEY" ] || exit 0

mkdir -p "$DIR" 2>/dev/null || exit 0
# The tool name reaches a wake payload and an escalation sentence, so flatten it
# to the same conservative alphabet the shape test already normalizes against.
SAFE_TOOL=$(LC_ALL=C printf '%s' "$TOOL" | tr -cd 'A-Za-z0-9_.-')
SAFE_TOOL=${SAFE_TOOL:0:64}
[ -n "$SAFE_TOOL" ] || SAFE_TOOL=unnamed
printf 'v1 ts=%s tool=%s\n' "$(date +%s)" "$SAFE_TOOL" > "$DIR/$KEY" 2>/dev/null || true
exit 0
