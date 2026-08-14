#!/usr/bin/env bash
# fm-nm-custody.sh - recognize a branch stranded by a dead no-mistakes run, and
# step around it without destroying anything.
#
# THE SHAPE. A pipeline run that dies mid-flight (an agent killed by a usage
# limit is the ordinary cause) leaves a terminal run still holding custody of its
# branch. The supported return, `no-mistakes axi sync --recover`, is guarded on
# the gate branch still sitting exactly where that run left it. Once anything has
# moved the gate branch off that recorded head, the guard's precondition can
# never be met again and every supported exit refuses:
#
#   axi run                     -> recover custody before any local follow-up commit
#   axi sync --recover          -> safety: blocked_recover_gate_diverged
#   axi sync --recover --keep-local -> refuses identically
#   axi abort --run <id>        -> no-op, the run is already terminal
#
# Each refusal states that no files or refs were changed, so nothing is damaged:
# the bookkeeping is simply unreachable. Observed three times in two days across
# two repositories (backlog item nm-custody-deadlock keeps the reproductions);
# docs/verification/nm-custody-deadlock.md records the v1.46.0 evidence behind
# every field this script parses.
#
# THE WAY OUT. The custody claim is keyed to the BRANCH NAME, not to the commits.
# A new branch at the identical head carries no claim, so validation starts
# normally there. That is the whole sidestep, and its safety is exactly its
# smallness: no commit is dropped, no history is rewritten, no ref is deleted or
# forced, and the stranded ref is left exactly where it stands.
#
# DETECTION is read-only and needs both halves, because the two states are
# indistinguishable from `axi sync --check` alone - a recoverable branch and a
# stranded one print the identical `blocked_pipeline_owned_recoverable` /
# `next_action.code: recover_custody` answer:
#
#   1. `no-mistakes axi sync --check` reports a TERMINAL run (failed/cancelled)
#      holding custody, and names the preserved head in
#      `branch_sync.pipeline.current_head`.
#   2. The gate branch is NOT at that preserved head. The gate is addressed
#      through the repo's own `no-mistakes` git remote that `no-mistakes init`
#      writes, so this reads the real precondition rather than guessing at
#      NM_HOME's internal layout, and `git ls-remote` never mutates either side.
#
# Both halves true is `stranded`. Half 1 true with the heads equal is
# `recoverable`: ordinary, the supported recovery works, and this script does
# NOTHING to it - choosing between `--recover` and `--recover --keep-local` is a
# content decision that belongs to the worker, not to a detector. Anything
# unreadable classifies `unknown` and also does nothing. Every uncertain answer
# falls toward inaction.
#
# NEVER SILENTLY. A stranded branch means a run died, which a supervisor needs to
# know even when the recovery is clean; an automatic fix that hid its own trigger
# would turn a visible problem into an invisible one. `recover` therefore always
# prints the full account, and `--status <file>` appends the one-line summary to
# a task status file so the report does not depend on the worker remembering.
#
# THE RESIDUAL, stated rather than hidden. Each sidestep spends a `-vN` name, so
# the branch namespace accumulates second attempts. The stranded local and gate
# refs, and the preserved pipeline commits anchored to the dead run, are left in
# place deliberately: deleting them is discard-flavoured, and the whole reason
# this state exists is that we do not know what the pipeline still believes about
# them. They are the captain's to remove, after the replacement branch has landed
# and the dead run's bookkeeping no longer matters. This script never deletes.
#
# Usage:
#   fm-nm-custody.sh check   [--dir <worktree>]
#   fm-nm-custody.sh recover [--dir <worktree>] [--status <file>]
#
#   check    Read-only. Classify and print; changes nothing, ever. Safe to run
#            against any worktree, including another task's.
#   recover  Apply the sidestep, but only to a freshly classified `stranded`
#            branch. Run it in the worktree that owns the branch.
#
# `check` exits 0 on any successful read (the state is on stdout) and 2 on usage.
# `recover` exits 0 when the branch is usable again and this script changed
# something, 3 when there was nothing to do, 4 when the branch is stranded but
# could not be stepped around safely, and 2 on usage.
#
# Firstmate itself may run `check` for diagnosis - it writes nothing. `recover`
# creates a branch in a project worktree, so it belongs to the worker that owns
# that worktree (AGENTS.md hard rule 1).
set -u

STATE_UNKNOWN=unknown
STATE_NO_CLAIM=no-claim
STATE_ACTIVE=active
STATE_RECOVERABLE=recoverable
STATE_STRANDED=stranded

EXIT_USAGE=2
EXIT_NOTHING=3
EXIT_BLOCKED=4

# How far the `-vN` search walks before giving up rather than spinning.
MAX_ATTEMPT=${FM_NM_CUSTODY_MAX_ATTEMPT:-20}
case "$MAX_ATTEMPT" in ''|*[!0-9]*) MAX_ATTEMPT=20 ;; esac
# Every no-mistakes and ls-remote call is bounded: this runs inside a worker's
# turn and must never hang it.
NM_TIMEOUT=${FM_NM_CUSTODY_TIMEOUT:-60}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=60 ;; esac

usage() {
  cat >&2 <<'EOF'
usage: fm-nm-custody.sh check   [--dir <worktree>]
       fm-nm-custody.sh recover [--dir <worktree>] [--status <file>]

  check    read-only: classify this branch's no-mistakes custody state
  recover  step around a stranded branch by branching at the identical head

  --dir <worktree>  worktree to inspect (default: current directory)
  --status <file>   append the one-line report to this task status file
EOF
  exit "$EXIT_USAGE"
}

VERB=${1:-}
[ -n "$VERB" ] || usage
shift
case "$VERB" in check|recover) : ;; *) usage ;; esac

DIR=.
STATUS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    DIR=${2:-}; [ -n "$DIR" ] || usage; shift 2 ;;
    --status) STATUS_FILE=${2:-}; [ -n "$STATUS_FILE" ] || usage; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit "$EXIT_USAGE"; }
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "error: not a git worktree: $DIR" >&2; exit "$EXIT_USAGE"; }

# --- bounded external calls -------------------------------------------------

# Pick the available bounding mechanism once. Mirrors bin/fm-crew-state.sh's
# probe so both readers behave the same on a host without GNU coreutils.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
fi

# run_bounded <args...>: run in $DIR, stdout only, never fail the script.
# stderr is dropped deliberately: no-mistakes prints an update-available banner
# and its refusal prose there, while every field this script reads is structured
# TOON on stdout.
run_bounded() {
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$DIR" && timeout "$NM_TIMEOUT" "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$DIR" && gtimeout "$NM_TIMEOUT" "$@" ) 2>/dev/null || true ;;
    *)        ( cd "$DIR" && "$@" ) 2>/dev/null || true ;;
  esac
}

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# --- axi sync --check parsing -----------------------------------------------

SYNC_OUT=""
# toon_field <key> [after-key]: first scalar value of a TOON `key: value` line.
# With <after-key>, the search starts only after that key's own line, which is
# how the nested `pipeline:` / `next_action:` scalars are read without a real
# TOON parser: `head` appears under both `local:` and `pipeline:`, and
# `next_action.command` must not be mistaken for a top-level field.
toon_field() {
  local key=$1 after=${2:-} body=$SYNC_OUT
  if [ -n "$after" ]; then
    body=$(printf '%s\n' "$SYNC_OUT" | sed -n "/^[[:space:]]*$after:[[:space:]]*$/,\$p")
  fi
  strip_quotes "$(printf '%s\n' "$body" | sed -n "s/^[[:space:]]*$key:[[:space:]]*\(.*\)/\1/p" | head -1)"
}

# A run whose status is one of these has stopped for good; only a stopped run can
# strand a branch, because a live one is still entitled to its custody.
run_status_is_terminal() {  # <status>
  case "${1:-}" in
    failed|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

# The two independent ways `axi sync --check` reports "a terminal run still holds
# this branch". Either is accepted: the discriminator between recoverable and
# stranded is the gate head below, and the confirming probe in `recover` is the
# final gate before anything is created.
custody_is_held() {  # <safety> <next-action-code>
  [ "${1:-}" = blocked_pipeline_owned_recoverable ] && return 0
  [ "${2:-}" = recover_custody ] && return 0
  return 1
}

# gate_head <branch>: the gate repo's head for <branch>, read through the repo's
# own `no-mistakes` remote. Empty when there is no such remote, the read fails,
# or the gate does not carry the branch.
gate_head() {  # <branch>
  local branch=$1 out
  git -C "$DIR" config --get remote.no-mistakes.url >/dev/null 2>&1 || return 0
  out=$(run_bounded git ls-remote no-mistakes "refs/heads/$branch")
  [ -n "$out" ] || return 0
  printf '%s' "$(trim "${out%%$'\t'*}")"
}

# Classification results, populated by classify().
CLASS=$STATE_UNKNOWN
CLASS_WHY=""
BRANCH=""
LOCAL_HEAD=""
LOCAL_CLEAN=""
RUN_ID=""
RUN_STATUS=""
PRESERVED_HEAD=""
GATE_HEAD=""

classify() {
  local safety next_code
  CLASS=$STATE_UNKNOWN

  if ! command -v no-mistakes >/dev/null 2>&1; then
    CLASS_WHY="no-mistakes is not installed on PATH"
    return
  fi

  SYNC_OUT=$(run_bounded no-mistakes axi sync --check)
  if ! printf '%s\n' "$SYNC_OUT" | grep -q '^branch_sync:'; then
    CLASS_WHY="no branch_sync report from \`no-mistakes axi sync --check\` (not initialized here, or the call did not return)"
    return
  fi

  BRANCH=$(toon_field branch local)
  LOCAL_HEAD=$(toon_field head local)
  LOCAL_CLEAN=$(toon_field clean local)
  RUN_ID=$(toon_field run pipeline)
  RUN_STATUS=$(toon_field status pipeline)
  PRESERVED_HEAD=$(toon_field current_head pipeline)
  safety=$(toon_field safety)
  next_code=$(toon_field code next_action)

  if [ -z "$BRANCH" ]; then
    CLASS_WHY="the report names no branch (detached HEAD, or no pipeline binding for this checkout)"
    return
  fi

  if ! custody_is_held "$safety" "$next_code"; then
    CLASS=$STATE_NO_CLAIM
    CLASS_WHY="no terminal run holds this branch (safety: ${safety:-none})"
    return
  fi

  if [ -z "$RUN_STATUS" ]; then
    CLASS_WHY="a run holds this branch but the report gives it no status"
    return
  fi
  if ! run_status_is_terminal "$RUN_STATUS"; then
    CLASS=$STATE_ACTIVE
    CLASS_WHY="run $RUN_ID is still $RUN_STATUS - a live run is entitled to its branch"
    return
  fi
  if [ -z "$PRESERVED_HEAD" ]; then
    CLASS_WHY="run $RUN_ID holds this branch but the report records no preserved head"
    return
  fi

  GATE_HEAD=$(gate_head "$BRANCH")
  if [ -z "$GATE_HEAD" ]; then
    CLASS_WHY="could not read the gate's head for $BRANCH through the \`no-mistakes\` remote"
    return
  fi

  if [ "$GATE_HEAD" = "$PRESERVED_HEAD" ]; then
    CLASS=$STATE_RECOVERABLE
    CLASS_WHY="the gate is still at the head run $RUN_ID recorded, so \`no-mistakes axi sync --recover\` can return custody normally"
    return
  fi

  CLASS=$STATE_STRANDED
  CLASS_WHY="run $RUN_ID ($RUN_STATUS) holds $BRANCH at preserved head $PRESERVED_HEAD, but the gate branch is at $GATE_HEAD - the guarded recovery's precondition can never be met again"
}

short() {  # <sha>
  local s=${1:-}
  [ -n "$s" ] || { printf '(none)'; return; }
  printf '%s' "${s:0:8}"
}

print_finding() {
  printf 'custody: %s\n' "$CLASS"
  [ -n "$BRANCH" ] && printf '  branch:         %s\n' "$BRANCH"
  [ -n "$RUN_ID" ] && printf '  run:            %s (%s)\n' "$RUN_ID" "${RUN_STATUS:-unknown}"
  [ -n "$PRESERVED_HEAD" ] && printf '  preserved head: %s\n' "$PRESERVED_HEAD"
  [ -n "$GATE_HEAD" ] && printf '  gate head:      %s\n' "$GATE_HEAD"
  [ -n "$LOCAL_HEAD" ] && printf '  local head:     %s\n' "$LOCAL_HEAD"
  printf '  %s\n' "$CLASS_WHY"
}

# --- check ------------------------------------------------------------------

if [ "$VERB" = check ]; then
  classify
  print_finding
  case "$CLASS" in
    "$STATE_STRANDED")
      printf '\nStep around it with: %s recover\n' "$(basename "$0")" ;;
    "$STATE_RECOVERABLE")
      printf '\nUse the supported recovery: no-mistakes axi sync --recover\n' ;;
  esac
  exit 0
fi

# --- recover ----------------------------------------------------------------

# report_line <text>: print the one-line summary and, when --status was given,
# append it to that task status file so the recovery cannot happen unseen.
report_line() {  # <verb> <text>
  local line="$1: $2"
  printf '%s\n' "$line"
  [ -n "$STATUS_FILE" ] || return 0
  printf '%s\n' "$line" >> "$STATUS_FILE" \
    || echo "warning: could not append the report to $STATUS_FILE" >&2
}

classify
print_finding
printf '\n'

case "$CLASS" in
  "$STATE_STRANDED") : ;;
  "$STATE_RECOVERABLE")
    echo "Nothing to step around: this is the ordinary recoverable state."
    echo "Return custody with no-mistakes axi sync --recover (add --keep-local to keep the current local head)."
    exit "$EXIT_NOTHING" ;;
  "$STATE_ACTIVE"|"$STATE_NO_CLAIM")
    echo "Nothing to do - this branch is not stranded."
    exit "$EXIT_NOTHING" ;;
  *)
    echo "Not acting on an unreadable state."
    exit "$EXIT_NOTHING" ;;
esac

# Preconditions. The sidestep is `git checkout -b` and nothing else, so it must
# start from exactly the state that was classified.
CURRENT_BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo "error: $DIR is on '${CURRENT_BRANCH:-a detached HEAD}', not the stranded branch '$BRANCH'; run this in the worktree that owns it" >&2
  exit "$EXIT_BLOCKED"
fi
CURRENT_HEAD=$(git -C "$DIR" rev-parse HEAD 2>/dev/null || true)
if [ -z "$CURRENT_HEAD" ] || { [ -n "$LOCAL_HEAD" ] && [ "$CURRENT_HEAD" != "$LOCAL_HEAD" ]; }; then
  echo "error: the local head moved between the check and now ($LOCAL_HEAD -> $CURRENT_HEAD); re-run the check" >&2
  exit "$EXIT_BLOCKED"
fi
if [ "$LOCAL_CLEAN" != true ]; then
  echo "error: the worktree has uncommitted changes; commit them first - the pipeline needs a clean branch, and nothing here is going to touch your working tree" >&2
  exit "$EXIT_BLOCKED"
fi

# Name the replacement. A branch that is already a second attempt increments its
# own suffix instead of growing another one, so the namespace stays readable.
BASE_NAME=$BRANCH
case "$BASE_NAME" in
  *-v[0-9]|*-v[0-9][0-9]) BASE_NAME=${BASE_NAME%-v*} ;;
esac
NEW_BRANCH=""
attempt=2
while [ "$attempt" -le "$MAX_ATTEMPT" ]; do
  candidate="$BASE_NAME-v$attempt"
  if ! git -C "$DIR" show-ref --verify --quiet "refs/heads/$candidate" \
    && [ -z "$(gate_head "$candidate")" ]; then
    NEW_BRANCH=$candidate
    break
  fi
  attempt=$((attempt + 1))
done
if [ -z "$NEW_BRANCH" ]; then
  echo "error: no free name from $BASE_NAME-v2 through $BASE_NAME-v$MAX_ATTEMPT; this branch has been stepped around too many times to keep going automatically" >&2
  exit "$EXIT_BLOCKED"
fi

# Confirming probe. `--keep-local` is the non-destructive form of the supported
# recovery: it keeps the current local head, so if this classification were wrong
# and custody were genuinely returnable, the branch is simply repaired through
# no-mistakes' own path at the same head, with nothing dropped. On a truly
# stranded branch it refuses with blocked_recover_gate_diverged and, as the
# refusal itself states, changes no files and no refs. Nothing is created until
# this refusal is seen.
PROBE_OUT=$(run_bounded no-mistakes axi sync --recover --keep-local)
PROBE_SAFETY=""
if printf '%s\n' "$PROBE_OUT" | grep -q '^branch_sync:'; then
  SYNC_OUT=$PROBE_OUT
  PROBE_SAFETY=$(toon_field safety)
  SYNC_OUT=""
fi
case "$PROBE_SAFETY" in
  '')
    echo "error: the confirming \`no-mistakes axi sync --recover --keep-local\` gave no readable answer; nothing was created" >&2
    exit "$EXIT_BLOCKED" ;;
  blocked_recover_gate_diverged) : ;;
  blocked_*)
    echo "error: the confirming \`no-mistakes axi sync --recover --keep-local\` refused with safety: $PROBE_SAFETY - custody was not returned and $BRANCH is still held; nothing was created" >&2
    exit "$EXIT_BLOCKED" ;;
  *)
    report_line working \
      "no-mistakes custody on $BRANCH returned through the supported recovery after all (safety: $PROBE_SAFETY) - the local head $(short "$CURRENT_HEAD") is unchanged and no branch was created; a pipeline run still died mid-flight, which is why this ran"
    echo
    echo "This did NOT need the sidestep: custody came back through no-mistakes' own guarded path,"
    echo "keeping the local head, dropping no commit and rewriting no history."
    echo "Validate on $BRANCH as usual."
    exit 0 ;;
esac

# Apply the sidestep: a plain branch at the identical head. No -B, no force, no
# reset, no delete - the stranded ref is not touched at all.
if ! git -C "$DIR" checkout -q -b "$NEW_BRANCH"; then
  echo "error: could not create $NEW_BRANCH; nothing was changed" >&2
  exit "$EXIT_BLOCKED"
fi

report_line working \
  "no-mistakes left $BRANCH stranded when run $RUN_ID died mid-flight ($RUN_STATUS); its guarded custody return can no longer succeed, so validation continues on $NEW_BRANCH at the identical head $(short "$CURRENT_HEAD") - no commit dropped, no history rewritten, $BRANCH left in place untouched"

cat <<EOF

What happened
  Run $RUN_ID died $RUN_STATUS while it held $BRANCH.
  It recorded preserved head $PRESERVED_HEAD, but the gate branch is at $GATE_HEAD,
  so \`no-mistakes axi sync --recover\` is guarded on a precondition that can never be met again.
  A run dying mid-flight is the ordinary cause - usually an agent killed by a usage limit.

What was done
  Created $NEW_BRANCH at $CURRENT_HEAD - the identical head, byte for byte the same commit.
  The custody claim is keyed to the branch NAME, so the new branch carries none and validation
  starts normally. Nothing was forced, discarded, deleted, reset or rewritten.

What was left behind, on purpose
  refs/heads/$BRANCH, locally and in the no-mistakes gate, both untouched.
  The preserved pipeline commits stay anchored to run $RUN_ID inside the gate; any fixes it had
  applied are NOT on $NEW_BRANCH and will be re-derived by the new run.
  These are deliberately not cleaned up: we do not know what the pipeline still believes about
  them, and deleting them is a discard. They are the captain's to remove once $NEW_BRANCH has
  landed. This script never deletes anything.
  Each sidestep also spends a -vN name, so the branch namespace accumulates second attempts.

Next
  Validate on $NEW_BRANCH. Open its PR from this branch, not from $BRANCH.
EOF
exit 0
