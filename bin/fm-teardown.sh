#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, refresh/prune the project's clone for PR-based ship
# tasks, then print a backlog-refresh reminder for ship and scout teardowns
# (a secondmate teardown prints none, since secondmates are not backlog items).
# REFUSES if the worktree holds work that has not LANDED, because cleanup
# hard-resets/removes the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge after configured approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. Teardown proceeds only once the report exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
# Before destructive cleanup, teardown validates task check artifacts and any
# matching quarantine entries as ordinary single-link files on the state
# device. It refuses and preserves task state when that proof fails; otherwise
# it removes the task's check, trust record, PR sidecar, publication record, and
# quarantine entries with the rest of the volatile state.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# A Herdr presentation journal never authorizes cleanup. Teardown still closes
# only the exact task pane from ordinary endpoint metadata and never calls
# `workspace close`. It retires the non-authoritative journal only when a
# read-only token correlation agrees with that endpoint and pane closure is
# confirmed. Otherwise the journal stays quarantined for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child runtime endpoints, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# A child worktree that is no longer provably the child's own blocks forced
# retirement the same way a task's own reassigned worktree blocks teardown, and
# --force never overrides it. The way forward is to resolve the child inside its
# own home first - FM_HOME=<child-home> bin/fm-teardown.sh <child-id>
# --disown-worktree when the pool reclaimed the path, or FM_HOME=<child-home>
# bin/fm-worktree-owner.sh claim <child-id> when only the record was lost - then
# rerun the retirement; the refusal itself names both.
# WORKTREE OWNERSHIP. A pooled treehouse worktree is not reserved by the shell or
# agent inside it, so a task whose pane disappears can have its slot handed to a
# newer task while its own meta still records that path. Every destructive step
# below - branch deletion, harness hook removal, process termination, the pool
# return - would then land inside the newer task's live work. So before touching
# the worktree at all, teardown requires the ownership record written at spawn to
# match the worktree_owner= recorded in meta; a mismatch REFUSES and changes
# nothing, naming what it found and what it expected. --force does NOT override
# this: forcing authorizes discarding THIS task's work, never destroying another
# task's. Tasks spawned before ownership records existed carry no worktree_owner=
# and are torn down unchecked, exactly as before. bin/fm-worktree-owner-lib.sh
# owns the contract and the exact limits of what it proves.
# Secondmate homes are leased from treehouse (`treehouse get --lease`), so their
# holder is recorded by treehouse itself and their return is guarded with
# `treehouse return --if-lease-holder <id>` instead of a marker. That holder
# precondition is carried by EVERY return attempt for the call, including lock
# retries and the post-stale-lock retry. Only treehouse's explicit "is not
# leased" refusal on the first attempt (a home leased before holders were
# recorded) falls back to an unguarded return; any other guarded failure,
# including an older treehouse that rejects the flag, aborts loudly rather than
# degrading to a return with no holder precondition.
# Usage: fm-teardown.sh <task-id> [--force] [--disown-worktree]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
#   --disown-worktree cleans up a task whose worktree is no longer provably its
#   own, so an unresolvable ownership refusal never becomes its own trap. It does
#   not apply to kind=secondmate, whose leased home treehouse itself records a
#   holder for; that combination is refused at preflight, before the forced child
#   cleanup could destroy anything. It requires that the worktree is NOT provably
#   this task's, and then touches nothing under that path: no process is killed
#   there, no branch is deleted, no worktree is returned to the pool. Only this
#   task's own records and its own recorded endpoint are cleared, so it destroys
#   no work anywhere and is not a way around the landed-work checks. When
#   ownership is merely unprovable (absent or unreadable rather than another
#   task's record), the worktree may still be this task's, so disowning runs that
#   worktree's ordinary uncommitted and unlanded-work checks first and REFUSES
#   while any of that work is there rather than orphaning it in a path no task
#   claims; the refusal names what it found and says the state needs a human
#   decision. That unlanded-work refusal is the one refusal on this path --force
#   does resolve, because the work it puts at risk is this task's own - exactly
#   what forcing authorizes discarding. --force still never resolves the
#   ownership refusal itself, and never makes a disown touch the worktree.
#   The run's own clone refresh skips branch pruning (FM_FLEET_PRUNE=0), so this
#   run cannot delete the branch it just released; a later routine sync can still
#   prune a pushed branch whose remote branch is gone once no worktree holds it,
#   and the disown output says so.
#   The reverse case - the record was lost but the worktree IS still this
#   task's - is restored with bin/fm-worktree-owner.sh claim <task-id>, not with
#   --force.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crew process
# killed mid-git-operation can leave a .git/worktrees/<wt>/index.lock (or, for a
# non-linked worktree, .git/index.lock) that makes `treehouse return --force` fail
# with Unable to create '...index.lock': File exists. That lock is usually transient
# (the dying process finishes or exits within seconds) and must never be force-deleted
# while a live git process might still own it - the fix is patience, not rm.
#
# On that failure signature only, teardown_treehouse_return:
#   1. Retries up to FM_TREEHOUSE_RETURN_LOCK_RETRIES times (default 3), waiting
#      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS (default 1s; falls back to the older
#      FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS name when the new one is unset) between
#      attempts. Retries key off the error text, not whether the lock file still
#      exists after the failed attempt - a lock that self-clears mid-check still
#      deserves a retry of the return. Before every retried return that follows a
#      wait, the caller-supplied revalidation (ownership and safety) re-runs, so
#      a slot reassigned while teardown waited is refused rather than released.
#   2. Other treehouse return failures still abort immediately and loudly (no retry).
#   3. If every retry still hits the lock signature and the lock remains, it is removed
#      and the return tried once more ONLY when the lock is provably stale per
#      bin/fm-lock-lib.sh's fm_lock_is_provably_stale, passing the worktree dir as the
#      companion directory and FM_STALE_WORKTREE_LOCK_AGE_SECS (default 30s) as the age
#      threshold. That shared proof owns the exact lsof-holder, mtime-age, and fail-safe
#      rules.
#   4. If retries exhaust and the lock is not provably stale, teardown fails as loudly
#      as a normal return failure and notes that the lock persisted across the retry
#      window. A missing `lsof`, or a lock that fails any stale check, is treated as
#      NOT provably stale (fail safe): the lock is left untouched.
# The same proof is used when non-force safety inspection cannot run because the lock
# is present; teardown clears only a provably stale lock, then re-proves ownership and
# re-runs the safety checks before any destructive step. Teardown output notes every
# wait, retry, and removal so the operator can see what happened.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gh-lib.sh
. "$SCRIPT_DIR/fm-gh-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-worktree-owner-lib.sh
. "$SCRIPT_DIR/fm-worktree-owner-lib.sh"
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
ID=$1
shift
FORCE=
DISOWN_WORKTREE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=--force ;;
    --disown-worktree) DISOWN_WORKTREE=1 ;;
    *) echo "error: unknown teardown option '$1'" >&2; exit 2 ;;
  esac
  shift
done
# Fail closed before any fleet mutation: a no-mistakes gate agent must never tear
# down a worktree (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
FM_LOCK_LOG_PREFIX=teardown

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
# This is the first cleanup authorization check. It is metadata-only and must
# complete before fm-guard, a backend command, file removal, branch deletion,
# worktree return, registry change, or process termination can run.
fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
# Empty for tasks spawned before ownership records existed; those stay unchecked.
WT_OWNER_EXPECTED=$(fm_meta_get "$META" worktree_owner)
T_ORCA=
[ "$BACKEND" != orca ] || T_ORCA=$T
"$FM_ROOT/bin/fm-guard.sh" || true
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
BUSY_GEN=$(fm_meta_get "$META" busy_gen)
if [ -z "$BUSY_GEN" ]; then
  BUSY_GEN=$(cat "$STATE/$ID.busy-gen" 2>/dev/null || true)
fi
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_PATH_MATCH_VERIFIED=0

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
# Refused at preflight so an invalid flag combination can never destroy anything
# first: for kind=secondmate the forced child cleanup below would otherwise run
# before a later --disown-worktree refusal.
if [ "$DISOWN_WORKTREE" = 1 ] && [ "$KIND" = secondmate ]; then
  echo "REFUSED: --disown-worktree does not apply to secondmate $ID; its home is leased from treehouse, which records the holder itself." >&2
  echo "Retire it with the ordinary secondmate path once its home holds no work under way." >&2
  exit 1
fi
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
PUBLIC_FOLLOWUP_HOME=$FM_HOME
PUBLIC_FOLLOWUP_STATE=$STATE
PUBLIC_FOLLOWUP_WORK_HOME=main
PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=0
PUBLIC_FOLLOWUP_RELAY_ACTIVE=0
public_followup_resolve_primary_home() {
  local parent=$1 child=$2 id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$id" || return 1
  case "$parent" in /*) ;; *) return 1 ;; esac
  parent=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
  child=$(CDPATH='' cd -- "$child" 2>/dev/null && pwd -P) || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fm_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fm_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key "$id" "$child" || return 1
  printf '%s\n' "$parent"
}
if [ -f "$FM_HOME/$SUB_HOME_MARKER" ]; then
  SECOND_MATE_ID=$(sed -n '1p' "$FM_HOME/$SUB_HOME_MARKER")
  # A marked child only enters the primary-binding path when the authoritative
  # parent relay is active. A child that has not opted into the relay must
  # retain the old teardown path, even without a durable parent registry.
  if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
    if fm_pf_relay_active "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME"; then
      PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
    fi
  elif fm_pf_relay_active "$FM_HOME"; then
    PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
  fi
  if [ "$PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE" = 1 ]; then
    PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
    if fm_pf_home_id_valid "secondmate:$SECOND_MATE_ID"; then
      PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$SECOND_MATE_ID"
      if PUBLIC_FOLLOWUP_HOME=$(public_followup_resolve_primary_home \
          "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" "$FM_HOME" "$SECOND_MATE_ID"); then
        PUBLIC_FOLLOWUP_STATE="$PUBLIC_FOLLOWUP_HOME/state"
        PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
        if [ "$FORCE" != "--force" ] \
          && fm_pf_relay_active "$PUBLIC_FOLLOWUP_HOME"; then
          PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
        fi
      else
        PUBLIC_FOLLOWUP_HOME=
        PUBLIC_FOLLOWUP_STATE=
      fi
    fi
  else
    PUBLIC_FOLLOWUP_HOME=
    PUBLIC_FOLLOWUP_STATE=
  fi
elif [ "$KIND" = secondmate ]; then
  PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$ID"
  if [ "$FORCE" != "--force" ] && fm_pf_relay_active "$FM_HOME"; then
    PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
  fi
elif [ "$FORCE" != "--force" ] && fm_pf_relay_active "$FM_HOME"; then
  PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

require_orca_worktree_id() {
  local meta=$1 id
  id=$(meta_value "$meta" orca_worktree_id)
  if [ -z "$id" ]; then
    echo "error: missing orca_worktree_id in $meta; cannot remove Orca worktree" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

require_orca_terminal() {
  local meta=$1 terminal
  terminal=$(meta_value "$meta" terminal)
  if [ -z "$terminal" ]; then
    echo "error: missing terminal in $meta; cannot close Orca terminal" >&2
    return 1
  fi
  printf '%s\n' "$terminal"
}

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  T_ORCA=$(meta_value "$META" terminal)
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

remove_kimi_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.kimi-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="$HOME/.kimi-code/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

retire_busy_state() {
  local state_dir=$1 id=$2 gen=${3:-}
  if [ -n "$gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --gen "$gen"
  elif [ -f "$state_dir/$id.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --current-gen
  fi
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 quarantine state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  quarantine="$state_dir/.pr-check-quarantine"
  if [ "$id" = _noncanonical ] \
    && { [ -e "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -e "$quarantine/_noncanonical.diagnostic.noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.noncanonical" ]; }; then
    echo "REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state." >&2
    return 1
  fi
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    has_artifact=1
  fi
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  if [ ! -d "$state_dir" ] || [ -L "$state_dir" ] \
    || [ ! -d "$quarantine" ] || [ -L "$quarantine" ]; then
    echo "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state." >&2
    return 1
  fi
  if [ "$(fm_pr_file_device "$quarantine")" != "$state_device" ] \
    || [ "$(fm_pr_file_mode "$quarantine")" != 700 ]; then
    echo "REFUSED: PR-check quarantine is not on the task state device; preserving task state." >&2
    return 1
  fi
  for artifact in "$quarantine/$id."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! fm_pr_private_file_valid "$artifact" 600 "$state_device"; then
      echo "REFUSED: unsafe task quarantine entry; preserving task state." >&2
      return 1
    fi
  done
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2 quarantine artifact
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust" || return 1
  if fm_task_id_path_safe "$id"; then
    quarantine="$state_dir/.pr-check-quarantine"
    if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
      for artifact in "$quarantine/$id."*; do
        [ -e "$artifact" ] || [ -L "$artifact" ] || continue
        rm -f -- "$artifact" || return 1
      done
      rmdir "$quarantine" 2>/dev/null || true
    fi
  fi
}

# Resolve the PR number for a worktree branch. Echoes the number on a single
# match and returns 0; returns non-zero on no match or any lookup failure, so
# the caller treats it as "no PR found" (fail-safe).
#
# The repository comes from bin/fm-gh-lib.sh rather than the tool's own remote
# inference, which is what makes this lookup answerable at all: a branch name is
# not unique across repositories, and a fork and its parent both using the
# fm/<task-id> convention can hold the same head branch on unrelated pull
# requests. Asking the wrong repository for "the PR on branch X" is how a
# landed-work check ends up reading another project's merge.
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$(fm_gh_query gh-axi "$WT" pr list --state all --head "$branch" --limit 1 2>/dev/null) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
#
# A recorded pr= URL names its repository on its own, but a branch-derived
# number does not, so both go through bin/fm-gh-lib.sh. A repository that cannot
# be established there refuses the query, which lands on that same content-check
# fallback rather than on a state read from some other repository.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(fm_gh_query gh "$WT" pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

backlog_refresh_reminder() {
  local pr done_cmd report_path
  [ "$KIND" = secondmate ] && return 0
  if fm_tasks_axi_backend_available "$CONFIG"; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        else
          pr=$PR_URL
          if [ -n "$pr" ]; then
            done_cmd="tasks-axi done $ID --pr $pr"
          else
            done_cmd="tasks-axi done $ID --pr PR_URL"
          fi
        fi
        ;;
    esac
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished. Update data/backlog.md - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

inspectable_git_worktree() {
  local target=$1 top
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -d "$top" ] || return 1
  git -C "$top" rev-parse --git-dir >/dev/null 2>&1
}

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crew process.
# New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
# for the per-attempt wait so existing tests and operators keep working.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
# Compatibility alias used by the safety-check wait path and older call sites.
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3
TEARDOWN_PROCEVENT_RESTORE_FAILED=4

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

# True when treehouse refused a return because the lease is held by someone else.
treehouse_return_is_lease_mismatch() {
  printf '%s\n' "$1" | grep -Fq 'lease holder does not match'
}

# True when treehouse refused a return because the worktree carries no lease at all.
treehouse_return_is_unleased() {
  printf '%s\n' "$1" | grep -Fq 'is not leased'
}

# The single refusal wording for a guarded return whose lease now belongs to
# someone else, wherever in the attempt sequence treehouse reports it.
refuse_lease_mismatch() {  # <label> <dir> <lease-holder>
  echo "REFUSED: $1 $2 is no longer leased to $3; returning it would release a worktree another holder is using. Nothing was changed." >&2
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crew process. See the script header.
# <post-wait-check>, when given, runs after EVERY wait this call makes - each
# lock-retry sleep and the provably-stale lock cleanup - and must re-prove
# whatever the caller established before calling (ownership, safety) against the
# CURRENT worktree; a failed recheck aborts the return instead of retrying it.
# <lease-holder>, when given, names the holder this caller expects treehouse to have
# recorded (secondmate homes are taken with `treehouse get --lease --lease-holder
# <id>`). It is checked by treehouse itself, atomically with the return, and the
# precondition rides EVERY attempt this call makes - lock retries and the
# post-stale-lock retry included - so a lease that changes hands during a wait is
# refused rather than released out from under its new holder. The one fallback to
# an unguarded return is treehouse's explicit "is not leased" signature on the
# first attempt: a slot carrying no lease at all predates the holder record, which
# is exactly what happened before this guard existed. Every other guarded failure,
# including an older treehouse that rejects --if-lease-holder, fails this call
# loudly instead of degrading to an unguarded return.
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_wait_check=${4:-} lease_holder=${5:-}
  local out lock attempt=0 max_retries lock_desc
  local -a return_cmd=(treehouse return --force)
  [ -z "$lease_holder" ] || return_cmd=(treehouse return --force --if-lease-holder "$lease_holder")

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && "${return_cmd[@]}" "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi

  if [ -n "$lease_holder" ] && treehouse_return_is_unleased "$out"; then
    echo "teardown: $label $dir carries no treehouse lease to verify; returning it unguarded" >&2
    lease_holder=
    return_cmd=(treehouse return --force)
    if out=$( ( cd "$cd_dir" && "${return_cmd[@]}" "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  if [ -n "$lease_holder" ] && treehouse_return_is_lease_mismatch "$out"; then
    refuse_lease_mismatch "$label" "$dir" "$lease_holder"
    return 1
  fi

  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    if [ -n "$post_wait_check" ]; then
      if ! "$post_wait_check"; then
        echo "teardown: $label return aborted after a lock wait because safety checks failed" >&2
        return 1
      fi
    fi

    if out=$( ( cd "$cd_dir" && "${return_cmd[@]}" "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2
    if [ -n "$lease_holder" ] && treehouse_return_is_lease_mismatch "$out"; then
      refuse_lease_mismatch "$label" "$dir" "$lease_holder"
      return 1
    fi

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_wait_check" ]; then
        if ! "$post_wait_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if out=$( ( cd "$cd_dir" && "${return_cmd[@]}" "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      if [ -n "$lease_holder" ] && treehouse_return_is_lease_mismatch "$out"; then
        refuse_lease_mismatch "$label" "$dir" "$lease_holder"
        return 1
      fi
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    secondmate|scout) return 0 ;;
  esac

  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$|\.fm-worktree-owner$)' | head -1 || true)

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

# True when this task carries an ownership record to check. Secondmate homes are
# leased and proven through treehouse instead; a task with no worktree_owner=
# predates the mechanism; a worktree that no longer exists has nothing to destroy.
worktree_ownership_applies() {
  [ "$KIND" != secondmate ] || return 1
  [ -n "$WT_OWNER_EXPECTED" ] || return 1
  [ -n "$WT" ] && [ -d "$WT" ]
}

# The gate every destructive use of $WT must pass. Refuses unless the worktree
# still carries THIS task's ownership record. Deliberately not skipped by
# --force: forcing authorizes discarding this task's own work, never destroying
# a different task's.
require_worktree_ownership() {
  worktree_ownership_applies || return 0
  fm_worktree_owner_verdict "$WT" "$WT_OWNER_EXPECTED"
  case "$FM_WORKTREE_OWNER_VERDICT" in
    ours) return 0 ;;
    other)
      echo "REFUSED: worktree $WT is held by task ${FM_WORKTREE_OWNER_TASK:-<unnamed>} (ownership record token $FM_WORKTREE_OWNER_TOKEN), not task $ID (expected token $WT_OWNER_EXPECTED)." >&2
      [ -z "$FM_WORKTREE_OWNER_HOME" ] || echo "That record was written by the firstmate home at $FM_WORKTREE_OWNER_HOME." >&2
      echo "The pool reassigned this path after task $ID stopped holding it. Cleaning up here would kill that task's running agent and return ITS worktree, so nothing was changed." >&2
      echo "Task $ID's commits are unaffected: branches live in the shared repository at $PROJ, not in the worktree." >&2
      echo "Clean up task $ID without touching that path: bin/fm-teardown.sh $ID --disown-worktree" >&2
      return 1
      ;;
    *)
      echo "REFUSED: cannot prove worktree $WT still belongs to task $ID; its ownership record is ${FM_WORKTREE_OWNER_VERDICT} (expected token $WT_OWNER_EXPECTED)." >&2
      echo "A returned or reclaimed worktree, or a crewmate's 'git clean -fdx', leaves this state, and proceeding could act inside another task's work, so nothing was changed." >&2
      echo "If you confirm that path is still task $ID's, restore the record with bin/fm-worktree-owner.sh claim $ID and rerun." >&2
      echo "If it was reclaimed, bin/fm-teardown.sh $ID --disown-worktree cleans up without touching that path - it runs this same worktree's uncommitted and unlanded-work checks first and refuses while any of that work is still there." >&2
      return 1
      ;;
  esac
}

# The --disown-worktree precondition. Disowning is allowed exactly when the
# worktree is NOT provably this task's; a worktree that still IS this task's must
# go through ordinary cleanup so its landed-work checks apply, which is what keeps
# this from becoming a way around them. kind=secondmate never reaches this: it is
# refused at preflight, before the forced child cleanup can destroy anything.
#
# `absent` and `unreadable` are not proof of a reclaim - they are the absence of
# proof either way, and a crewmate's own `git clean -fdx` reaches them with the
# worktree still this task's and its work still in it. So those two run the same
# unlanded-work test ordinary teardown runs, against that same worktree, and
# refuse while it finds anything: releasing the record there would leave real work
# in a path no task claims, and the pool skips a dirty slot for both `get` and
# prune, so nothing would ever come back for it. `other` keeps today's behaviour,
# because a worktree provably held by a sibling cannot hold OUR unlanded work and
# inspecting it for ours would be meaningless.
require_disownable_worktree() {
  local safety_rc
  if [ -z "$WT_OWNER_EXPECTED" ]; then
    echo "REFUSED: task $ID has no ownership record to disown; it predates worktree ownership records." >&2
    echo "Ordinary cleanup already applies to it: bin/fm-teardown.sh $ID" >&2
    return 1
  fi
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    fm_worktree_owner_verdict "$WT" "$WT_OWNER_EXPECTED"
    case "$FM_WORKTREE_OWNER_VERDICT" in
      ours)
        echo "REFUSED: worktree $WT is still task $ID's own, so there is nothing to disown." >&2
        echo "Clean it up the ordinary way so its uncommitted and unlanded work is checked first: bin/fm-teardown.sh $ID" >&2
        return 1
        ;;
      other) ;;
      *)
        if validate_worktree_teardown_safety; then
          :
        else
          safety_rc=$?
          if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
            echo "REFUSED: cannot inspect worktree $WT for unlanded work; a git lock is present, and disowning must not touch that path to clear it." >&2
          else
            echo "REFUSED: worktree $WT still holds work that has not landed, and task $ID cannot prove that path is its own." >&2
          fi
          echo "Disowning would drop task $ID's records while that work sits in a worktree no task claims, and the pool passes over a dirty slot, so nothing was changed." >&2
          echo "This state needs a human decision: confirm by hand whose worktree $WT is." >&2
          echo "If it is still task $ID's, land that work (commit and push, or merge it), restore the record with bin/fm-worktree-owner.sh claim $ID, and clean up the ordinary way: bin/fm-teardown.sh $ID" >&2
          echo "If another task has taken that path, its own record belongs there; leave the worktree to it and rerun this once the record says so." >&2
          return 1
        fi
        ;;
    esac
  fi
  return 0
}

# The post-wait recheck for teardown_treehouse_return, also re-run after the
# safety-check stale-lock wait below: after ANY wait, both the ownership proof
# and the landed-work checks are re-run against the CURRENT worktree, so a slot
# reassigned during that wait is caught before anything destructive.
revalidate_worktree_before_return() {
  require_worktree_ownership || return 1
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    secondmate|scout) return 0 ;;
  esac
  validate_worktree_teardown_safety
}

# The child-return counterpart of revalidate_worktree_before_return, which closes
# over the parent task's $WT/$KIND/$FORCE and so cannot speak for a child. Bound
# through these globals, set at the child return call site, because
# teardown_treehouse_return invokes its post-wait recheck with no arguments; it
# re-proves the child's own ownership record and removal boundaries against the
# CURRENT worktree before any waited return retry.
TEARDOWN_CHILD_RECHECK_WT=
TEARDOWN_CHILD_RECHECK_PROJ=
TEARDOWN_CHILD_RECHECK_META=
TEARDOWN_CHILD_RECHECK_ID=
revalidate_child_worktree_before_return() {
  validate_child_worktree_for_removal "$TEARDOWN_CHILD_RECHECK_WT" \
    "$TEARDOWN_CHILD_RECHECK_PROJ" "$TEARDOWN_CHILD_RECHECK_META" \
    "$TEARDOWN_CHILD_RECHECK_ID" >/dev/null
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
  resolved=$(fm_backend_worktree_path orca "$worktree_id") || {
    echo "REFUSED: cannot resolve Orca worktree id $worktree_id to a path; preserving metadata." >&2
    return 1
  }
  inspected_abs=$(canonical_existing_dir "$inspected") || {
    echo "REFUSED: cannot canonicalize inspected worktree ${inspected:-<missing>}; preserving metadata." >&2
    return 1
  }
  resolved_abs=$(canonical_existing_dir "$resolved") || {
    echo "REFUSED: Orca worktree id $worktree_id resolved to uninspectable path ${resolved:-<missing>}; preserving metadata." >&2
    return 1
  }
  if [ "$resolved_abs" != "$inspected_abs" ]; then
    echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved_abs, not inspected worktree $inspected_abs." >&2
    echo "Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata." >&2
    return 1
  fi
}

require_orca_worktree_path_match_if_present() {
  local worktree_id=$1 inspected=$2
  [ -n "$inspected" ] && [ -e "$inspected" ] || return 0
  require_orca_worktree_path_match "$worktree_id" "$inspected"
}

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  if ! secondmate_registry_validate_bindings "$reg" secondmate_registry_path_key; then
    echo "REFUSED: $SECONDMATE_REGISTRY_ERROR" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        secondmate_registry_parse_line "$line" || {
          echo "REFUSED: malformed secondmate registry entry: $line" >&2
          return 2
        }
        id=$SECONDMATE_REGISTRY_ID
        registered_home=$SECONDMATE_REGISTRY_HOME
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

# A secondmate's child worktrees come from the same pool and go stale the same
# way, and forced retirement discards THAT secondmate's work - never a worktree
# the pool has since handed to someone else. When the child's metadata records an
# ownership token, it must still match before the child's path can be removed or
# returned.
require_child_worktree_ownership() {  # <child-worktree> <child-meta> <child-id>
  local target=$1 child_meta=$2 child_id=$3 expected child_home
  [ -n "$target" ] && [ -d "$target" ] || return 0
  [ -n "$child_meta" ] && [ -f "$child_meta" ] || return 0
  expected=$(meta_value "$child_meta" worktree_owner)
  [ -n "$expected" ] || return 0
  fm_worktree_owner_verdict "$target" "$expected"
  if [ "$FM_WORKTREE_OWNER_VERDICT" = ours ]; then
    return 0
  fi
  child_home=$(dirname "$(dirname "$child_meta")")
  echo "REFUSED: child worktree $target is no longer provably held by $child_id (ownership record ${FM_WORKTREE_OWNER_VERDICT}, expected token $expected)." >&2
  if [ "$FM_WORKTREE_OWNER_VERDICT" = other ]; then
    echo "It is recorded as held by task ${FM_WORKTREE_OWNER_TASK:-<unnamed>}; removing it would destroy that task's live work." >&2
  fi
  echo "Retiring this second mate would act outside its own work, so nothing was changed." >&2
  echo "Resolve the child inside its own home first, then rerun this retirement." >&2
  if [ "$FM_WORKTREE_OWNER_VERDICT" != other ]; then
    echo "If that path is still $child_id's own, restore its record: FM_HOME=$child_home bin/fm-worktree-owner.sh claim $child_id" >&2
  fi
  if [ "$FM_WORKTREE_OWNER_VERDICT" = other ]; then
    echo "If the pool reclaimed it, clean the child up without touching it: FM_HOME=$child_home bin/fm-teardown.sh $child_id --disown-worktree" >&2
  else
    echo "If the pool reclaimed it, FM_HOME=$child_home bin/fm-teardown.sh $child_id --disown-worktree cleans the child up without touching that path - it runs that worktree's uncommitted and unlanded-work checks first and refuses while any of that work is still there." >&2
  fi
  return 1
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 child_meta=${3:-} child_id=${4:-} abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  require_child_worktree_ownership "$target" "$child_meta" "${child_id:-the recorded child task}" || return 1
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2 child_meta=${3:-} child_id=${4:-}
  validate_child_worktree_for_removal "$target" "$project" "$child_meta" "$child_id" >/dev/null || return 1
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
    if [ -e "$SECONDMATE_REG" ] || [ -L "$SECONDMATE_REG" ]; then
      if ! secondmate_registry_validate_bindings "$SECONDMATE_REG" secondmate_registry_path_key "$expected_id" "$abs_home_path"; then
        case "$SECONDMATE_REGISTRY_ERROR" in
          overlapping\ secondmate\ home\ assignment:*)
            echo "REFUSED: unsafe $label removal target $home contains registered secondmate home; $SECONDMATE_REGISTRY_ERROR" >&2
            ;;
          *) echo "REFUSED: $SECONDMATE_REGISTRY_ERROR" >&2 ;;
        esac
        return 1
      fi
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=
  if conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path"); then
    :
  else
    conflict_rc=$?
    [ "$conflict_rc" -eq 1 ] || return 1
  fi
  if [ -z "$conflict" ]; then
    if conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path"); then
      :
    else
      conflict_rc=$?
      [ "$conflict_rc" -eq 1 ] || return 1
    fi
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path process_event_backup
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  process_event_backup=$(snapshot_firstmate_home_process_events "$abs_home_path" "$label") || return 1
  if ! cleanup_firstmate_home_process_events "$abs_home_path" "$label"; then
    restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
    return 1
  fi
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" "" "$expected_id" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
      return 1
    }
    [ -z "$process_event_backup" ] || rm -rf -- "$process_event_backup"
    return 0
  fi
  if safe_rm_rf "$abs_home_path" "$label"; then
    [ -z "$process_event_backup" ] || rm -rf -- "$process_event_backup"
    return 0
  fi
  restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
  return 1
}

firstmate_home_has_process_events() {
  local home=$1 path owner claim_root
  for path in "$home/state/procevent"/*.source "$home/state/procevent"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  claim_root=${FM_PROCEVENT_CLAIM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/procevent-claims}
  for path in "$claim_root"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$home" ] && return 0
  done
  return 1
}

snapshot_firstmate_home_process_events() {
  local home=$1 label=$2 backup path
  if ! firstmate_home_has_process_events "$home"; then
    printf '\n'
    return 0
  fi
  backup=$(umask 077; mktemp -d "${home%/*}/.fm-procevent-restore.XXXXXX") || {
    echo "REFUSED: cannot stage recoverable process-event state for $label $home" >&2
    return 1
  }
  for path in "$home/state/procevent"/*.source; do
    [ -e "$path" ] || continue
    if [ ! -f "$path" ] || [ -L "$path" ] || ! cp -p -- "$path" "$backup/"; then
      rm -rf -- "$backup"
      echo "REFUSED: cannot preserve process-event registrations for $label $home" >&2
      return 1
    fi
  done
  printf '%s\n' "$backup"
}

restore_firstmate_home_process_events() {
  local home=$1 label=$2 backup=$3 reg source tmp runner
  [ -n "$backup" ] || return 0
  [ -d "$backup" ] && [ ! -L "$backup" ] || {
    echo "error: process-event restoration failed for $label $home; recovery backup is unavailable at $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  reg="$home/state/procevent"
  (umask 077; mkdir -p "$reg") || {
    echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  [ -d "$reg" ] && [ ! -L "$reg" ] || {
    echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  for source in "$backup"/*.source; do
    [ -e "$source" ] || continue
    [ -f "$source" ] && [ ! -L "$source" ] || {
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    }
    tmp=$(umask 077; mktemp "$reg/.restore.XXXXXX") || {
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    }
    if ! cp -- "$source" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$reg/${source##*/}"; then
      rm -f -- "$tmp"
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    fi
  done
  runner="$home/bin/fm-procevent.sh"
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    runner="$SCRIPT_DIR/fm-procevent.sh"
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" "$runner" reconcile >/dev/null; then
    echo "error: process-event restoration could not rearm $label $home; active waits may remain retired; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  fi
  rm -rf -- "$backup"
}

cleanup_firstmate_home_process_events() {
  local home=$1 label=$2 runner="$1/bin/fm-procevent.sh"
  firstmate_home_has_process_events "$home" || return 0
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    echo "REFUSED: $label $home has process-event state but no sweep-capable bin/fm-procevent.sh; restore the home script and rerun teardown" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$runner" sweep-home; then
    echo "REFUSED: process-event cleanup is incomplete for $label $home; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
  if firstmate_home_has_process_events "$home"; then
    echo "REFUSED: process-event state remains for $label $home after its bounded sweep; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
}

preflight_firstmate_home_process_events() {
  local home=$1 label=$2 runner="$1/bin/fm-procevent.sh"
  firstmate_home_has_process_events "$home" || return 0
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    echo "REFUSED: $label $home has process-event state but no sweep-capable bin/fm-procevent.sh; restore the home script and rerun teardown" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$runner" sweep-home --preflight >/dev/null; then
    echo "REFUSED: process-event cleanup cannot safely proceed for $label $home; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
}

preflight_firstmate_home_process_event_tree() {
  local home=$1 label=$2 sub_state child_meta child_kind child_home child_wt child_id
  sub_state="$home/state"
  if [ -d "$sub_state" ]; then
    for child_meta in "$sub_state"/*.meta; do
      [ -e "$child_meta" ] || continue
      child_kind=$(meta_value "$child_meta" kind)
      [ "$child_kind" = secondmate ] || continue
      child_id=$(basename "$child_meta" .meta)
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      preflight_firstmate_home_process_event_tree "$child_home" "child firstmate home for $child_id" || return 1
    done
  fi
  preflight_firstmate_home_process_events "$home" "$label"
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home child_backend child_orca_worktree_id
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    fm_backend_validate_task_endpoint "$child_meta" "$child_id" || return 1
    validate_pr_poll_cleanup "$sub_state" "$child_id" || return 1
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ "$child_backend" = orca ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        child_proj=$(meta_value "$child_meta" project)
        validate_child_worktree_for_removal "$child_wt" "$child_proj" "$child_meta" "$child_id" >/dev/null || return 1
        require_orca_worktree_path_match "$child_orca_worktree_id" "$child_wt" || return 1
      fi
    elif [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" "$child_meta" "$child_id" >/dev/null || return 1
    fi
  done
}

TEARDOWN_HERDR_LOCK_RECORDS=
teardown_release_herdr_locks() {
  local lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 0
  while IFS=$'\t' read -r lock_session lock_path; do
    [ -n "$lock_path" ] || continue
    fm_lock_release "$lock_path" || true
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  TEARDOWN_HERDR_LOCK_RECORDS=
}

teardown_herdr_session_lock_held() {  # <session>
  local session=$1 lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 1
  while IFS=$'\t' read -r lock_session lock_path; do
    [ "$lock_session" != "$session" ] || return 0
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  return 1
}

teardown_herdr_require_prerequisites() {  # <task-id>
  local task_id=$1 prerequisite
  if ! fm_backend_source herdr; then
    echo "error: herdr teardown prerequisites are unavailable for $task_id; nothing was changed - restore the adapter and rerun teardown" >&2
    return 1
  fi
  for prerequisite in \
    fm_backend_herdr_parse_target \
    fm_backend_herdr_pane_presence_state \
    fm_backend_herdr_workspace_presence_state \
    fm_backend_herdr_endpoint_confirmed_gone \
    fm_backend_herdr_explicit_close_pane_confirmed \
    fm_backend_herdr_presentation_session_lock_path; do
    if ! declare -F "$prerequisite" >/dev/null 2>&1; then
      echo "error: herdr teardown prerequisites are unavailable for $task_id; nothing was changed - restore the adapter and rerun teardown" >&2
      return 1
    fi
  done
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1 \
    || ! declare -F fm_lock_release >/dev/null 2>&1; then
    echo "error: herdr teardown lock machinery is unavailable for $task_id; nothing was changed - restore the lock support and rerun teardown" >&2
    return 1
  fi
}

teardown_herdr_preflight_target() {  # <target> <task-id>
  local target=$1 task_id=$2 session pane presence lock_path verified_lock_path lock_session held_path attempt
  teardown_herdr_require_prerequisites "$task_id" || return 1
  if ! fm_backend_herdr_parse_target "$target"; then
    echo "error: herdr endpoint $target for $task_id could not be parsed exactly; nothing was changed - repair the endpoint metadata and rerun teardown" >&2
    return 1
  fi
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
  case "$presence" in
    dead|present) ;;
    *)
      echo "error: herdr endpoint $target for $task_id has ambiguous structured presence; nothing was changed - restore reliable endpoint inspection and rerun teardown" >&2
      return 1
      ;;
  esac
  if ! lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session"); then
    echo "error: herdr session presentation lock could not be resolved for $task_id; nothing was changed - rerun teardown once the session is reachable and unambiguous" >&2
    return 1
  fi
  if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
    while IFS=$'\t' read -r lock_session held_path; do
      if [ "$lock_session" = "$session" ]; then
        if [ "$held_path" != "$lock_path" ]; then
          echo "error: herdr session presentation lock changed during preflight for $task_id; nothing was changed - rerun teardown once session identity is stable" >&2
          return 1
        fi
        return 0
      fi
    done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  fi
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$lock_path"; then
      if ! verified_lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") \
        || [ "$verified_lock_path" != "$lock_path" ]; then
        fm_lock_release "$lock_path" || true
        echo "error: herdr session presentation lock changed during preflight for $task_id; nothing was changed - rerun teardown once session identity is stable" >&2
        return 1
      fi
      if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
        TEARDOWN_HERDR_LOCK_RECORDS="$TEARDOWN_HERDR_LOCK_RECORDS
$session	$lock_path"
      else
        TEARDOWN_HERDR_LOCK_RECORDS="$session	$lock_path"
      fi
      trap teardown_release_herdr_locks EXIT
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "error: herdr session presentation lock is contended for $task_id; nothing was changed - rerun teardown once the contention clears" >&2
  return 1
}

preflight_firstmate_home_herdr_children() {  # <home>
  local home=$1 sub_state child_meta child_id child_backend child_target child_kind child_home child_wt
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    fm_backend_validate_task_endpoint "$child_meta" "$child_id" || return 1
    child_backend=$FM_BACKEND_VALIDATED_BACKEND
    child_target=$FM_BACKEND_VALIDATED_TARGET
    if [ "$child_backend" = herdr ]; then
      teardown_herdr_preflight_target "$child_target" "$child_id" || return 1
    fi
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ "$child_kind" = secondmate ]; then
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      preflight_firstmate_home_herdr_children "$child_home" || return 1
    fi
  done
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home child_backend child_orca_worktree_id child_return_rc child_busy_gen
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_backend" = orca ]; then
      child_t=$(meta_value "$child_meta" terminal)
    else
      child_t=$(fm_backend_target_of_meta "$child_meta")
    fi
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" "$child_meta" "$child_id" >/dev/null || return 1
      fi
    fi
    if [ -n "$child_t" ]; then
      if [ "$child_backend" = herdr ]; then
        fm_backend_herdr_parse_target "$child_t" || return 1
        if ! teardown_herdr_session_lock_held "$FM_BACKEND_HERDR_SESSION"; then
          echo "error: herdr session presentation lock is not held for child $child_id; retaining that child's durable identity records and stopping forced cleanup" >&2
          return 1
        fi
        fm_backend_herdr_kill_serialized "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" 2>/dev/null || true
        if ! fm_backend_herdr_endpoint_confirmed_gone "$child_t"; then
          echo "error: herdr pane $child_t for child $child_id is not confirmed gone; retaining that child's durable identity records and stopping forced cleanup" >&2
          return 1
        fi
      elif [ "$child_backend" = zellij ]; then
        # Zellij titles are scoped by the owning home tag, so forced secondmate
        # cleanup must verify child tabs as that child home, not the parent.
        ( unset FM_ROOT_OVERRIDE; FM_HOME=$home FM_ROOT=$home fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" ) 2>/dev/null || true
      else
        fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" 2>/dev/null || true
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home" || return $?
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" || return $?
      fi
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" "$child_meta" "$child_id" >/dev/null || return 1
        rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" \
          "$child_wt/.fm-grok-turnend" "$child_wt/.fm-kimi-turnend"
      fi
      fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" || return 1
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" "$child_meta" "$child_id" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" \
        "$child_wt/.opencode/plugins/fm-busy-state.js" \
        "$child_wt/.fm-grok-turnend" "$child_wt/.fm-kimi-turnend"
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        TEARDOWN_CHILD_RECHECK_WT=$child_wt
        TEARDOWN_CHILD_RECHECK_PROJ=$child_proj
        TEARDOWN_CHILD_RECHECK_META=$child_meta
        TEARDOWN_CHILD_RECHECK_ID=$child_id
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" revalidate_child_worktree_before_return; then
          :
        else
          child_return_rc=$?
          if [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ]; then
            return "$child_return_rc"
          fi
          safe_rm_rf_child_worktree "$child_wt" "$child_proj" "$child_meta" "$child_id" || {
            echo "error: child worktree $child_wt for $child_id could not be removed; retaining that child's records and stopping forced cleanup" >&2
            return 1
          }
        fi
      else
        safe_rm_rf_child_worktree "$child_wt" "$child_proj" "$child_meta" "$child_id" || {
          echo "error: child worktree $child_wt for $child_id could not be removed; retaining that child's records and stopping forced cleanup" >&2
          return 1
        }
      fi
      # Clear this child's own holder record now that its slot is released, so a
      # returned pool worktree does not carry a stale one (the return's clean does
      # not remove git-excluded files). Scoped to the child's token, so a task that
      # already claimed the freed slot keeps its record.
      fm_worktree_owner_remove "$child_wt" "$(meta_value "$child_meta" worktree_owner)"
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id"
    remove_kimi_turnend_auth "$sub_state" "$child_id"
    remove_pr_poll_artifacts "$sub_state" "$child_id" || return 1
    child_busy_gen=$(meta_value "$child_meta" busy_gen)
    if [ -z "$child_busy_gen" ]; then
      child_busy_gen=$(cat "$sub_state/$child_id.busy-gen" 2>/dev/null || true)
    fi
    retire_busy_state "$sub_state" "$child_id" "$child_busy_gen" || return 1
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" \
      "$sub_state/$child_id.meta" "$sub_state/$child_id.pi-ext.ts" \
      "$sub_state/$child_id.grok-turnend-token" "$sub_state/$child_id.kimi-turnend-token"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
    if [ "$BACKEND" = herdr ]; then
      teardown_herdr_preflight_target "$T" "$ID" || exit 1
    fi
    preflight_firstmate_home_herdr_children "$HOME_PATH" || exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ "$KIND" = secondmate ]; then
  preflight_firstmate_home_process_event_tree "$HOME_PATH" "secondmate home" || exit 1
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  cleanup_firstmate_home_children "$HOME_PATH" || exit $?
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$ID" >/dev/null; then
    echo "REFUSED: scout task $ID has not passed the unresolved-decision completion gate." >&2
    echo "Inventory its report and any visual review through bin/fm-decision-hold.sh before teardown." >&2
    exit 1
  fi
fi

# A public commitment is not kept until its final reply lands in the ORIGINAL
# thread, and this cleanup removes the task records that make the promise
# reconcilable. Refuse while this home still owes a public reply for exactly this
# work. Both gates live in bin/fm-public-followup-lib.sh, so a home that never
# opted into the myfirstmate relay runs one [ -f ] test and nothing else here.
if [ "$FORCE" != "--force" ] && [ "$PUBLIC_FOLLOWUP_PARENT_UNRESOLVED" = 1 ]; then
  echo "REFUSED: cannot resolve the primary home for marked secondmate $SECOND_MATE_ID; refusing cleanup without its durable parent binding." >&2
  exit 1
fi
if [ "$FORCE" != "--force" ] \
  && [ -n "$PUBLIC_FOLLOWUP_STATE" ] \
  && [ "$PUBLIC_FOLLOWUP_RELAY_ACTIVE" = 1 ] \
  && fm_pf_has_registrations "$PUBLIC_FOLLOWUP_STATE"; then
  if ! PUBLIC_FOLLOWUP_BLOCKING=$(FM_HOME="$PUBLIC_FOLLOWUP_HOME" FM_STATE_OVERRIDE="$PUBLIC_FOLLOWUP_STATE" \
      "$SCRIPT_DIR/fm-public-followup.sh" guard-work "$PUBLIC_FOLLOWUP_WORK_HOME" "$ID" 2>/dev/null); then
    echo "REFUSED: task $ID still owes a public reply through the myfirstmate relay." >&2
    printf '%s\n' "$PUBLIC_FOLLOWUP_BLOCKING" >&2
    echo "Deliver it with bin/fm-public-followup.sh deliver <obligation-id>, waive it with tasks-axi public-followup waive, or use --force after explicit discard approval." >&2
    exit 1
  fi
fi

# Ownership first, before anything inspects or touches the worktree: if the pool
# reassigned this path, the checks below would read - and then destroy - a
# different task's work, and would refuse or proceed for entirely the wrong
# reasons. This runs even under --force.
if [ "$DISOWN_WORKTREE" = 1 ]; then
  require_disownable_worktree || exit 1
else
  require_worktree_ownership || exit 1
fi

if [ "$DISOWN_WORKTREE" != 1 ] && [ "$BACKEND" = orca ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$FORCE" != "--force" ]; then
  if ! inspectable_git_worktree "$WT"; then
    echo "REFUSED: Orca ship task $ID has no inspectable git worktree at ${WT:-<missing>}." >&2
    echo "Cannot verify dirty or unlanded work; restore the worktree path or get explicit OK to discard, then --force." >&2
    exit 1
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$WT" || exit 1
  ORCA_PATH_MATCH_VERIFIED=1
fi

# Disowning destroys nothing under the worktree, so the checks here have no
# subject: they guard a hard reset, a process kill, and a pool return that a
# disown never performs. They are not bypassed either. require_disownable_worktree
# above has already run this same unlanded-work test against that path for the
# ambiguous absent/unreadable states, where the worktree may still be this task's.
# The work itself is left exactly where it is, on its branch in the shared
# repository.
if [ "$DISOWN_WORKTREE" != 1 ] && [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      cleanup_stale_lock_for_safety_check "$WT" || exit 1
      revalidate_worktree_before_return || exit 1
    else
      exit 1
    fi
  fi
fi

# A Herdr close may reposition shared workspace order, so the whole
# destructive sequence below (worktree return, pane close, record removal)
# runs under the named-session presentation lock, acquired BEFORE anything is
# returned or erased: a contended lock refuses here while the isolated copy,
# every durable record, and the endpoint are all still intact for a plain
# rerun. An unresolvable lock path (for example an unreachable server) also
# refuses before any destructive step.
TEARDOWN_HERDR_SESSION=
TEARDOWN_HERDR_PANE=
if [ "$BACKEND" = herdr ]; then
  teardown_herdr_preflight_target "$T" "$ID" || exit 1
  fm_backend_herdr_parse_target "$T" || exit 1
  TEARDOWN_HERDR_SESSION=$FM_BACKEND_HERDR_SESSION
  TEARDOWN_HERDR_PANE=$FM_BACKEND_HERDR_PANE
fi

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ "$DISOWN_WORKTREE" = 1 ]; then
  # Every step in this section acts on $WT, and $WT is not this task's to act on.
  # Deleting the branch here would be the worst of them: it is where the task's
  # commits still live, and it is in the shared repository, reachable from a fresh
  # worktree. Leave all of it alone and say where the work is.
  echo "disown: leaving worktree $WT untouched - no processes terminated, no branch deleted, nothing returned to the pool"
  if [ -n "$PROJ" ]; then
    echo "disown: any commits task $ID made remain on their branch in $PROJ and are reachable from a new worktree"
    # Honest limit on that: with no worktree left holding the branch, routine
    # clone maintenance prunes a branch whose remote branch is already deleted
    # (bin/fm-fleet-sync.sh's prune_gone_branches). This run keeps the promise
    # above itself - its clone refresh in the teardown tail runs with
    # FM_FLEET_PRUNE=0 - but a LATER sync can still prune. A branch that was
    # never pushed has no upstream and is never pruned.
    echo "disown: this run's own clone refresh skips branch pruning, so the branch survives this teardown"
    echo "disown: if that branch was pushed and its remote branch has since been deleted, confirm the work landed - a later routine clone maintenance run prunes such a branch once no worktree holds it"
  fi
  # This task's OWN recorded endpoint is still ours to close, and the shared
  # close below skips orca. Without this an Orca task offered the disown path
  # would keep its terminal running with no record left to find it by.
  if [ "$BACKEND" = orca ] && [ -n "$T_ORCA" ]; then
    fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
  fi
elif [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  if [ "$ORCA_PATH_MATCH_VERIFIED" != 1 ]; then
    require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || exit 1
    ORCA_PATH_MATCH_VERIFIED=1
  fi
  if [ -d "$WT" ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$branch" != "HEAD" ]; then
      if git -C "$WT" checkout --detach -q 2>/dev/null; then
        git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" \
      "$WT/.opencode/plugins/fm-busy-state.js" \
      "$WT/.fm-grok-turnend" "$WT/.fm-kimi-turnend"
    fm_worktree_owner_remove "$WT" "$WT_OWNER_EXPECTED"
  fi
  [ -z "$T_ORCA" ] || fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
  fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID"
elif [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  # The herdr preflight above spins on the presentation session lock, and that is
  # a wait like any other: the pool can reassign this slot while teardown waits.
  # Re-prove ownership (and safety) here, before the branch deletion and hook
  # removal that precede the return's own post-wait rechecks.
  revalidate_worktree_before_return || exit 1
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" \
    "$WT/.fm-grok-turnend" "$WT/.fm-kimi-turnend"
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project. teardown_treehouse_return tolerates transient and stale git locks
  # left by a killed crew process; see the script header for retry and stale-lock proof.
  # The recheck after any wait - each lock-retry sleep and the stale-lock cleanup -
  # re-proves ownership as well as safety, since the pool can reassign a slot while
  # teardown waits.
  teardown_treehouse_return "$WT" "$PROJ" "worktree" revalidate_worktree_before_return || {
    echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
    exit 1
  }
  # Only now that the slot is released: the ownership record has to survive up to
  # the return so the recheck above can still prove the worktree is ours, and it is
  # git-excluded, so the return's clean does not take it. Removing it is scoped to
  # our own token, so a task that has already claimed the freed slot keeps its own.
  fm_worktree_owner_remove "$WT" "$WT_OWNER_EXPECTED"
fi

HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
HERDR_PRESENTATION_SESSION=
HERDR_PRESENTATION_PANE=
if [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  fm_backend_source herdr || true
  HERDR_PRESENTATION_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_PRESENTATION_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_PRESENTATION_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_PRESENTATION_PANE" ] \
     && [ "$T" = "$HERDR_PRESENTATION_SESSION:$HERDR_PRESENTATION_PANE" ] \
     && fm_backend_herdr_projection_endpoint_matches_journal \
       "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
       "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
    HERDR_PRESENTATION_RETIRE_CANDIDATE=1
  fi
fi

if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  # The presentation lock was acquired before the worktree return above; a
  # contended lock already refused this teardown while everything was intact.
  if teardown_herdr_session_lock_held "$HERDR_PRESENTATION_SESSION"; then
    fm_backend_herdr_projection_close_pane_focus_preserving \
      "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE" 2>/dev/null || true
  else
    echo "warning: herdr presentation focus lock unavailable; refusing a concurrent focus-unsafe pane close" >&2
  fi
elif [ "$BACKEND" = herdr ]; then
  if teardown_herdr_session_lock_held "$TEARDOWN_HERDR_SESSION"; then
    fm_backend_herdr_kill_serialized "$TEARDOWN_HERDR_SESSION" "$TEARDOWN_HERDR_PANE" 2>/dev/null || true
  else
    echo "warning: herdr session presentation lock path is unavailable; skipping the pane close rather than closing unlocked" >&2
  fi
elif [ "$BACKEND" != orca ]; then
  fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
fi
if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if [ "$(fm_backend_herdr_pane_agent_state "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE")" = dead ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: exact herdr task-pane close could not be confirmed for $ID; retaining the presentation journal and attempting no workspace cleanup" >&2
  fi
elif [ "$BACKEND" = herdr ] \
     && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  echo "warning: herdr presentation journal for $ID remains quarantined; no workspace cleanup was attempted" >&2
fi
# A refused, skipped, or failed Herdr close must never erase a live task's
# durable endpoint identity: unless the exact pane is confirmed gone, retain
# every record and stop before any removal below so a later rerun can retry
# the locked close. Only a structured not-found proves the pane gone; unknown
# presence, missing or malformed endpoint identity, and missing confirmation
# machinery all refuse.
if [ "$BACKEND" = herdr ]; then
  fm_backend_source herdr || true
  if ! declare -F fm_backend_herdr_endpoint_confirmed_gone >/dev/null 2>&1; then
    echo "error: herdr endpoint confirmation is unavailable for $ID; retaining every durable task record" >&2
    exit 1
  fi
  if ! fm_backend_herdr_endpoint_confirmed_gone "$T"; then
    echo "error: herdr pane $T for $ID is not confirmed gone after its close was refused, skipped, or failed; retaining every durable task record - rerun teardown once the close can run under the session lock" >&2
    exit 1
  fi
fi
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" || exit $?
  remove_secondmate_registry_entry "$ID"
fi
remove_grok_turnend_auth "$STATE" "$ID"
remove_kimi_turnend_auth "$STATE" "$ID"
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
retire_busy_state "$STATE" "$ID" "$BUSY_GEN" || exit 1
"$FM_ROOT/bin/fm-delegation-event.sh" clear "$STATE" "$ID" >/dev/null 2>&1 || true
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta" \
  "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token" \
  "$STATE/$ID.kimi-turnend-token"
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  if [ "$DISOWN_WORKTREE" = 1 ]; then
    FM_FLEET_PRUNE=0 "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
  else
    "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
  fi
fi
echo "teardown $ID complete (window $T, worktree $WT)"
backlog_refresh_reminder
