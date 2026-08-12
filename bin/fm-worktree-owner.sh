#!/usr/bin/env bash
# Inspect or restore a task's worktree-ownership record. bin/fm-worktree-owner-lib.sh
# owns the contract this reads and writes; read its header first.
#
# bin/fm-spawn.sh writes the record at spawn and bin/fm-teardown.sh checks it before
# touching a worktree. This script exists for the one case that check cannot resolve
# on its own: the record is gone (a crewmate's `git clean -fdx` removes it) while the
# worktree IS still the task's, so teardown refuses with "ownership cannot be proven"
# and the operator has confirmed by hand that no other task holds the path.
#
# Usage:
#   fm-worktree-owner.sh show <task-id>    Print the recorded and expected identity
#   fm-worktree-owner.sh claim <task-id>   Restore this task's missing record
#
# `claim` only ever FILLS a missing record. It refuses when the worktree already
# carries another task's record, so it can never be used to take a live sibling's
# worktree - that direction stays a refusal, and the cleanup path for a task whose
# worktree was genuinely reclaimed is `fm-teardown.sh <id> --disown-worktree`.
# It also refuses when the task's metadata has no worktree_owner= to restore,
# because there is no recorded identity to prove and nothing to reinstate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# fm_meta_get lives in fm-backend.sh; fm_task_id_path_safe in fm-pr-lib.sh.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-worktree-owner-lib.sh
. "$SCRIPT_DIR/fm-worktree-owner-lib.sh"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
ACTION=$1
ID=$2
fm_task_id_path_safe "$ID" || { echo "error: invalid task id" >&2; exit 2; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(fm_meta_get "$META" worktree)
EXPECTED=$(fm_meta_get "$META" worktree_owner)
[ -n "$WT" ] || { echo "error: task $ID records no worktree" >&2; exit 1; }

case "$ACTION" in
  show)
    fm_worktree_owner_verdict "$WT" "$EXPECTED"
    printf 'task=%s\n' "$ID"
    printf 'worktree=%s\n' "$WT"
    printf 'expected_token=%s\n' "${EXPECTED:-<none recorded>}"
    printf 'recorded_token=%s\n' "${FM_WORKTREE_OWNER_TOKEN:-<none>}"
    printf 'recorded_task=%s\n' "${FM_WORKTREE_OWNER_TASK:-<none>}"
    printf 'recorded_home=%s\n' "${FM_WORKTREE_OWNER_HOME:-<none>}"
    if [ -z "$EXPECTED" ]; then
      printf 'verdict=unchecked (task predates worktree ownership records)\n'
    else
      printf 'verdict=%s\n' "$FM_WORKTREE_OWNER_VERDICT"
    fi
    ;;
  claim)
    if [ -z "$EXPECTED" ]; then
      echo "REFUSED: task $ID has no worktree_owner= to restore." >&2
      echo "It predates worktree ownership records, so there is no recorded identity to reinstate and teardown already treats it as unchecked." >&2
      exit 1
    fi
    [ -d "$WT" ] || { echo "REFUSED: worktree $WT for task $ID does not exist." >&2; exit 1; }
    fm_worktree_owner_verdict "$WT" "$EXPECTED"
    case "$FM_WORKTREE_OWNER_VERDICT" in
      ours)
        echo "task $ID already owns $WT; nothing to restore"
        exit 0
        ;;
      other)
        echo "REFUSED: worktree $WT is recorded as held by task ${FM_WORKTREE_OWNER_TASK:-<unnamed>} (token $FM_WORKTREE_OWNER_TOKEN), not task $ID (token $EXPECTED)." >&2
        echo "Restoring here would take a live sibling's worktree. If task $ID's worktree was genuinely reclaimed, clean it up with bin/fm-teardown.sh $ID --disown-worktree." >&2
        exit 1
        ;;
      unreadable)
        echo "REFUSED: worktree $WT carries an unreadable ownership record; inspect $WT/$FM_WORKTREE_OWNER_MARKER by hand before restoring." >&2
        exit 1
        ;;
    esac
    fm_worktree_owner_write "$WT" "$EXPECTED" "$ID" "$FM_HOME" \
      || { echo "error: could not write the ownership record for $ID at $WT" >&2; exit 1; }
    echo "restored ownership record for $ID at $WT (token $EXPECTED)"
    echo "Only do this after confirming by hand that no other task holds that path."
    ;;
  *)
    usage
    ;;
esac
