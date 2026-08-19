#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      Attribution takes two answers, and needs BOTH. WHICH RUN comes from the
#      run id wherever the CLI supplies one: `axi status` emits its `branch_sync:`
#      block only for the run that owns the current checkout's branch, and
#      `branch_sync.pipeline.run` names that run's id. WHOSE CODE the run id
#      cannot answer, because a run keeps owning its branch NAME after its worker
#      has moved on - so the binding also demands that a pipeline head from the
#      same block already CARRIES every commit unique to this worktree's HEAD
#      (nm_commit_carries_worktree_work, patch identity, so the pipeline's own
#      rebase of this crew's work still counts).
#      That code evidence is the ONLY thing that binds. Ownership on its own -
#      however the CLI phrases it - is never enough, and neither is
#      `branch_sync.local.head`, which is the CLI's live read of this same
#      checkout and agrees by construction. Local work the pipeline never
#      received leaves a commit uncarried, and a pipeline head this worktree
#      cannot see leaves no evidence either way; both are UNATTRIBUTED, and
#      rule 4's pane and log sources answer instead. That is what keeps a crew's
#      own blocked/paused report from being masked by a run it abandoned, and it
#      is why no verdict of any kind - terminal or otherwise - can rest on
#      ownership alone.
#      Which binding applies is decided by the block's presence, not by the
#      run-id binding's result: an answer CARRYING a `branch_sync` block is
#      answered entirely by that binding, so a refusal it reached on the
#      pipeline's own heads is never rescued by a looser match; an answer
#      carrying no such block (an older CLI) falls back to the sha binding, where
#      a run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). Local work that advanced past the run head, or
#      diverged from it, invalidates that fallback, as does a pipeline that
#      rebased its own head off this worktree's line of history - which is why
#      the run id has to lead (see nm_run_head_matches_worktree, and the incident
#      it records).
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. A failed run
#      also names its cause when the failed step's log proves the pipeline agent
#      was killed by the account usage limit rather than failing on its own
#      (nm_failed_cause); anything unrecognized stays a plain failure. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail. One line the log may NOT
#      supply: a TERMINAL verdict while the CLI still reports a live run owning
#      this branch (nm_branch_sync_run_is_live). Rule 2 refused to attribute that
#      run, and it keeps refusing - but a `failed:`/`done:` line is then provably
#      an EARLIER run's outcome, and relaying it abandons a gate that is still
#      answerable or invites tearing live work down. That reads unknown, with the
#      reason attribution missed (nm_bind_miss_note). Liveness is the only thing
#      the block is trusted for here; it never becomes attribution.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log. The coarse fallback answers only for this
#      branch's NEWEST run row, never for an older one further down the list: a
#      newest row it cannot bind to this worktree attributes NO run, which is rule
#      4's case and falls through to the pane and status log like any other crew
#      without a run. Refusing to let an older row answer costs the reader nothing
#      else - the two independent sources below are still read.
#
# `--pipeline-activity` is a second, narrower read of the SAME attributed run:
# instead of the crew's state it prints how the PIPELINE's own process is doing,
# which is the one measurement of the process that actually works during a
# validation run (see the emit_pipeline block below). It lives here rather than
# in its own script because it must reuse this file's branch and code-identity
# attribution; re-deriving that elsewhere is how a sibling crew's live run would
# get credited to a wedged pane.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id, or an unknown mode).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-quota-kill-lib.sh
. "$SCRIPT_DIR/fm-quota-kill-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id> [--pipeline-activity]" >&2; exit 2; }
MODE=${2:-}
case "$MODE" in
  ''|--pipeline-activity) : ;;
  *) echo "usage: fm-crew-state.sh <id> [--pipeline-activity]" >&2; exit 2 ;;
esac
pipeline_mode() { [ "$MODE" = --pipeline-activity ]; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# Ceiling on how far the code-identity guard will diff (nm_commit_carries_worktree_work).
FM_CREW_STATE_PATCH_SCAN=${FM_CREW_STATE_PATCH_SCAN:-200}
case "$FM_CREW_STATE_PATCH_SCAN" in ''|*[!0-9]*) FM_CREW_STATE_PATCH_SCAN=200 ;; esac
# Why the attribution below last refused, owned by nm_run_id_binds_worktree and
# rendered by nm_bind_miss_note. Empty means it bound, or was never attempted.
NM_BIND_MISS=''
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# The one line --pipeline-activity prints. Class vocabulary and the rule that
# every unmeasurable case is `unknown` live with the emit block far below.
emit_pipeline() {  # <class> <detail>
  printf '%s %s\n' "$1" "$2"
  exit 0
}

# --- meta resolution --------------------------------------------------------

if [ ! -f "$META" ]; then
  pipeline_mode && emit_pipeline unknown "no durable record for $ID, so no run can be attributed to it"
  emit unknown none "no metadata for $ID"
fi

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  pipeline_mode && emit_pipeline none "the task worktree is gone, so no run is attributed to it"
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

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

# Bounded no-mistakes call in the worktree; stdout only, never fails the script.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    perl)     ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null || true ;;
    *)        true ;;
  esac
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}

# Why a failed run failed, when that can be established. no-mistakes reports
# every dead pipeline agent identically ("agent review: claude exited: exit
# status 1"), so a usage-limit kill - a known, recoverable, external condition
# that leaves the crew's branch content untouched - is indistinguishable at that
# level from a genuine crash. The failed step's own log carries the vendor's
# message verbatim, so one bounded `axi logs` read separates them.
# Prints the clause to append to the failed detail, or nothing at all when the
# run failed for any other reason, when no failed step is reported, or when the
# log is unreadable - an unrecognized cause always reports as a plain failure and
# is never excused as external. Only meaningful for a full `axi status` read: the
# coarse runs-list fallback carries neither a run id nor a step table.
nm_failed_cause() {
  local run_id step log_out record
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || return 0
  step=$(printf '%s\n' "$RUN_OUT" | fm_quota_kill_failed_step)
  [ -n "$step" ] || return 0
  log_out=$(nm_run axi logs --step "$step" --run "$run_id" --full) || true
  [ -n "$log_out" ] || return 0
  record=$(printf '%s\n' "$log_out" | fm_quota_kill_scan --agent-episode) || return 0
  printf 'usage limit killed the pipeline agent at step %s (%s) - %s' \
    "$step" "$(fm_quota_kill_window "$record")" "$(fm_quota_kill_evidence "$record")"
}

# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# matching row's status word (running/completed/cancelled/failed), or empty
# when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # The list is newest-first, so the FIRST row for this branch is the only
      # candidate this walk may ever answer with. Same code-identity rule as axi
      # status: a row whose short-sha does not bind this worktree is not
      # attributable - and the answer is then that this branch has no attributable
      # run at all, NOT a look further down the list. Skipping onward is what
      # produced the 2026-08-19 false `failed`: the branch's live run sat at a
      # gate-repo-only head, so its own newest row did not bind, and the walk
      # continued to an older failed run of the SAME branch still sitting on the
      # worktree sha and reported its terminal outcome as current. Answering empty
      # rather than a status word leaves the pane and status-log sources below to
      # do their job, which refusing the older row never needed to cost.
      if nm_coarse_head_matches_worktree "$sha"; then
        printf '%s' "$st"
      fi
      return 0
    fi
  done <<< "$out"
  return 0
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if <commit> is this worktree's code identity. The single owner of that test.
# Rules:
#   - missing/empty: cannot bind; no match
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of it: match (pipeline fix commits on the same
#     history advanced the run tip)
#   - it is a strict ancestor of worktree HEAD: no match (local work advanced
#     outside the run)
#   - diverged / not resolvable in this worktree: no match (rewritten branch tip,
#     or a commit that only exists inside the local gate repo)
nm_commit_binds_worktree() {  # <commit-ish>
  local cand=${1:-} local_full cand_full
  [ -n "$cand" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  cand_full=$(git -C "$WT" rev-parse --verify "${cand}^{commit}" 2>/dev/null) || return 1
  [ "$cand_full" = "$local_full" ] && return 0
  git -C "$WT" merge-base --is-ancestor "$local_full" "$cand_full" 2>/dev/null
}

# 0 if <commit> IS this worktree's HEAD, resolving an abbreviation the CLI
# printed. Deliberately identity-only, unlike nm_commit_binds_worktree above:
# the run-id binding below uses it to check that the CLI's own view of this
# checkout still matches the one being read, where an ancestor is not the same
# thing as agreement. On its own this proves nothing about WHOSE code a run is
# validating - `branch_sync.local.head` is the CLI's live read of the very
# checkout being read here, taken with `cd "$WT"`, so it agrees by construction.
# It is a freshness check on the answer, never the code-identity guard.
same_commit_as_worktree_head() {  # <commit-ish>
  local cand=${1:-} local_full cand_full
  [ -n "$cand" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  cand_full=$(git -C "$WT" rev-parse --verify "${cand}^{commit}" 2>/dev/null) || return 1
  [ "$cand_full" = "$local_full" ]
}

# 0 if <commit> resolves in this worktree at all. Distinguishes "the pipeline is
# holding a head this checkout cannot see" - true of every in-flight run whose
# own commits live only in the local gate repo - from "the pipeline's head is
# right here and disagrees with mine", which are opposite amounts of evidence.
nm_commit_visible_here() {  # <commit-ish>
  [ -n "${1:-}" ] || return 1
  git -C "$WT" rev-parse --verify "${1}^{commit}" >/dev/null 2>&1
}

# 0 if <commit> already CARRIES every commit that is unique to this worktree's
# HEAD - i.e. the pipeline received all of this crew's work. This is the real
# code-identity guard, and the only one available on the local side.
#
# It compares by PATCH identity (`git cherry`), not by ancestry, because the
# rebase step replays the crew's commits onto a newer base: the resulting head is
# a SIBLING of the worktree HEAD, neither equal to it nor a descendant of it, and
# an ancestry test disowns the very run that is validating this crew (the
# 2026-08-19 incident). Patch identity sees through that replay - verified on the
# incident's own commits, `git cherry 0df68e38 985dd8af` reporting both worktree
# commits as `-`, already present upstream.
#
# It still refuses the case ancestry was there to refuse, which is the whole
# point: a crew that committed a local fix after its run went terminal, or that
# rewrote its branch out from under an abandoned run, leaves at least one commit
# the pipeline never received, `git cherry` prefixes it `+`, and nothing binds.
#
# Cost discipline, because this reader runs per-crew on the watcher's
# single-threaded poll and is called up to twice per read. Two cheap graph walks
# stand in front of the one expensive step:
#   - if the worktree HEAD is reachable from the candidate, every commit of HEAD
#     is literally in it and nothing needs diffing at all. That covers a run that
#     has not rebased yet and a crew already synchronized to the pipeline's head.
#   - otherwise the divergence is measured first. `git cherry` computes a patch-id
#     - a full diff - for every commit on BOTH sides of the merge base, and after
#     a rebase the candidate's side includes however far the default branch had
#     advanced, so that span is what has to stay bounded. Past
#     FM_CREW_STATE_PATCH_SCAN commits the walk is not run at all and the answer
#     is "no evidence", which costs a fall-through to the pane and log sources
#     rather than an unbounded diff on the fleet's supervision poll.
# Post-rebase runs are the shape that reaches the patch-id walk, and by design it
# is the bounded shape rather than the rare one.
nm_commit_carries_worktree_work() {  # <commit-ish>
  local cand=${1:-} cand_full base span unmatched
  nm_commit_visible_here "$cand" || return 1
  NM_BIND_MISS=head-disagrees
  cand_full=$(git -C "$WT" rev-parse --verify "${cand}^{commit}" 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor HEAD "$cand_full" 2>/dev/null && return 0
  base=$(git -C "$WT" merge-base HEAD "$cand_full" 2>/dev/null) || return 1
  [ -n "$base" ] || return 1
  span=$(git -C "$WT" rev-list --count "$base..HEAD" "$base..$cand_full" 2>/dev/null) || return 1
  case "$span" in ''|*[!0-9]*) return 1 ;; esac
  [ "$span" -le "$FM_CREW_STATE_PATCH_SCAN" ] || { NM_BIND_MISS=scan-ceiling; return 1; }
  unmatched=$(git -C "$WT" cherry "$cand_full" HEAD 2>/dev/null) || return 1
  printf '%s\n' "$unmatched" | grep -q '^+' && return 1
  return 0
}

# 0 when the answer carries a `branch_sync:` block at all. That block is the only
# source of the CLI's own attribution, so its presence decides WHICH binding may
# run: with it, the run-id binding is the whole rule; without it, the sha binding
# below is.
nm_has_branch_sync() {
  printf '%s\n' "$RUN_OUT" | grep -qE '^branch_sync:[[:space:]]*$'
}

# Scalar value of a key nested one level under the `branch_sync:` block, e.g.
# `nm_branch_sync_field local branch`. Scoped to that block, so a same-named key
# elsewhere in the run object (`head:` appears in both `run:` and
# `branch_sync.local:`) can never answer for it.
nm_branch_sync_field() {  # <sub-block> <key>
  printf '%s\n' "$RUN_OUT" | awk -v blk="$1" -v key="$2" '
    {
      indent = match($0, /[^[:space:]]/) - 1
      if (indent < 0) next
      if (indent == 0) { inbs = ($0 ~ /^branch_sync:[[:space:]]*$/); insub = 0; next }
      if (!inbs) next
      if (indent == 2) { insub = ($0 ~ ("^  " blk ":[[:space:]]*$")); next }
      if (insub && indent == 4 && $0 ~ ("^    " key ":")) {
        v = $0
        sub(/^[^:]*:[[:space:]]*/, "", v)
        print v
        exit
      }
    }'
}

# 0 when the CLI ITSELF binds the reported run to this checkout AND that run is
# still validating this checkout's code. This is the strongest attribution
# available and is tried first.
#
# WHICH RUN. `axi status` emits its `branch_sync:` block only when the run it
# reports is the one owning the CURRENT checkout's branch: querying any other run
# - a sibling branch's run picked up by the repo-global bare call, or an explicit
# `--run <id>` for another branch - returns the run object with no `branch_sync`
# at all (verified 2026-08-19 against the installed v1.48.0 from five live
# worktrees, four owning a run and one owning none). Inside it, `pipeline.run` names the run id the pipeline considers
# to own that branch. Run id equal to `pipeline.run`, plus `local.branch` equal
# to this crew's branch, is the pipeline's own statement of which run owns this
# branch - no sha ancestry involved.
#
# Why it had to lead: both heads the sha binding can try are commits the pipeline
# REWRITES. The rebase step alone rewrites the submitted head onto a newer base,
# and each fix round adds to it, so `submitted_head` is the head the pipeline is
# validating and not, in general, "the commit this worktree handed it". On
# 2026-08-19 a live run parked at its review gate reported head c3c0cfa7
# (gate-repo only) and submitted_head 0df68e38 - a rebase of the worktree's
# 985dd8af onto a newer main, so neither equal to nor a descendant of it. Both
# head tests missed, attribution fell through to the coarse runs list, and that
# walk credited the branch's OWN older failed run to the live one. The same
# output carried `pipeline.run` matching the reported run id the whole time.
#
# WHOSE CODE is a separate question, and the run id cannot answer it: a run keeps
# owning its branch NAME after its worker has moved on - custody survives a
# terminal run (see docs/verification/nm-custody-deadlock.md) - so run id plus
# branch name alone is the "some run owns this branch" rule this file's header
# calls insufficient. `local.head` cannot answer it either: that field is the
# CLI's live read of this same checkout, so it agrees by construction. The code
# guard is therefore a PIPELINE head that already carries every commit unique to
# this worktree's HEAD, by patch identity so the pipeline's own rebase of this
# crew's work still counts (nm_commit_carries_worktree_work).
#
# Code evidence is the only thing that binds, and there is no ownership-only
# escape hatch. When NEITHER pipeline head is visible in this worktree - the
# ordinary shape of an in-flight run, whose commits live only inside the local
# gate - nothing here can tell a run that is validating this crew's code from one
# whose worker has since rewritten the branch out from under it, so the answer is
# UNATTRIBUTED and the pane and log sources answer instead. That is what keeps an
# abandoned run from masking the crew's own blocked/paused report, and it is why
# no verdict of any kind can rest on the CLI merely naming this branch's owner.
# `local.head` is checked too, but only as a freshness check on the answer: it is
# the CLI's live read of this same checkout, so it can catch a read that raced a
# local commit and can never be the code evidence itself.
nm_run_id_binds_worktree() {
  local run_id bs_run bs_branch
  NM_BIND_MISS=foreign-run
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || return 1
  bs_run=$(strip_quotes "$(nm_branch_sync_field pipeline run)")
  [ -n "$bs_run" ] && [ "$bs_run" = "$run_id" ] || return 1
  bs_branch=$(strip_quotes "$(nm_branch_sync_field local branch)")
  [ -n "$bs_branch" ] && [ "$bs_branch" = "$CREW_BRANCH" ] || return 1
  NM_BIND_MISS=stale-view
  same_commit_as_worktree_head "$(strip_quotes "$(nm_branch_sync_field local head)")" || return 1
  NM_BIND_MISS=no-visible-head
  nm_commit_carries_worktree_work "$(strip_quotes "$(nm_branch_sync_field pipeline submitted_head)")" \
    && { NM_BIND_MISS=''; return 0; }
  nm_commit_carries_worktree_work "$(strip_quotes "$(nm_branch_sync_field pipeline current_head)")" \
    && { NM_BIND_MISS=''; return 0; }
  return 1
}

# The FALLBACK attribution, reached ONLY for an answer that carries no
# `branch_sync` block at all - nm_run_id_binds_worktree above is the whole rule
# for any answer that carries one, and needs no commit guessing.
# Branch match is a precondition (caller). One head is all such an answer has:
# `head`, where the run sits NOW. It binds a run whose commits this worktree can
# still see - no pipeline commit yet, or the crew already synchronized to the
# pipeline-pushed head - and nothing else. A submitted head is not tried here
# because there is none to try: the CLI publishes `submitted_head` only inside
# `branch_sync.pipeline`, so any answer that has one is answered above.
# The test stays exact rather than optimistic, so a crew that rewrote its branch
# under an abandoned still-active run matches no head and correctly falls
# through to the pane/log sources below.
nm_run_head_matches_worktree() {
  nm_commit_binds_worktree "$(strip_quotes "$(nm_field head)")"
}

# 0 when the CLI's own `branch_sync` block says a run is LIVE on this crew's
# branch. This is evidence that a run EXISTS, never attribution of it to this
# code: the block is emitted for whoever owns the branch NAME, which is exactly
# the claim the binding above refuses to act on. The one thing it is trusted for
# is the fallback's terminal verdicts - while a run is live on this branch, a
# `failed:`/`done:` line left in the status log by an earlier run is provably not
# this crew's current state, and reporting it would be the false terminal verdict
# this whole reader exists to prevent. An unrecognized status counts as live,
# which errs toward saying less rather than toward asserting an ending.
nm_branch_sync_run_is_live() {
  local bs_branch bs_status
  nm_has_branch_sync || return 1
  bs_branch=$(strip_quotes "$(nm_branch_sync_field local branch)")
  [ -n "$bs_branch" ] && [ "$bs_branch" = "$CREW_BRANCH" ] || return 1
  bs_status=$(strip_quotes "$(nm_branch_sync_field pipeline status)")
  [ -n "$bs_status" ] || return 1
  case "$bs_status" in completed|failed|cancelled) return 1 ;; esac
  return 0
}

# What the attribution actually observed when it refused, for the details this
# reader prints when it declines to attribute. Empty when nothing was attempted
# or nothing is worth saying. Each miss is a different fact about a crew and is
# read inside a wedge escalation, so a confident wrong cause here is the same
# defect class as a confident wrong state.
nm_bind_miss_note() {
  case "${NM_BIND_MISS:-}" in
    no-visible-head) printf '%s' "the pipeline holds a head this checkout cannot see, so code identity could not be established either way" ;;
    scan-ceiling)    printf '%s' "this branch and the pipeline's head have diverged by more than FM_CREW_STATE_PATCH_SCAN ($FM_CREW_STATE_PATCH_SCAN) commits, so code identity was not checked" ;;
    stale-view)      printf '%s' "the pipeline CLI's own view of this checkout is already out of date" ;;
    head-disagrees)  printf '%s' "the pipeline's head does not carry this checkout's work" ;;
  esac
}

# The one attribution test the reader uses, and the block's presence picks which
# half applies. An answer CARRYING a `branch_sync` block is answered entirely by
# the run-id binding: that block is the CLI's own attribution, so once it has
# refused - including when it refused on a visible pipeline head that does not
# carry this worktree's work - a looser ancestry match on the top-level `head:`
# field must not rescue it. An answer carrying no block (an older CLI) has no
# such attribution to consult, and falls back to the sha binding above.
nm_run_binds_worktree() {
  if nm_has_branch_sync; then
    nm_run_id_binds_worktree
    return
  fi
  nm_run_head_matches_worktree
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". That row carries
# only the run's current head - the runs list exposes no submitted head - so a
# coarse row binds on that one sha alone. Teaching this walk about submitted
# heads is tracked as backlog item fm-crewstate-coarse-walk.
nm_coarse_head_matches_worktree() {  # <short-sha>
  nm_commit_binds_worktree "${1:-}"
}

HAVE_RUN=0
# Set when the CLI reports a LIVE run owning this branch that the binding above
# could not tie to this code. It buys no attribution - only the right to refuse a
# stale terminal line from the status log below.
UNATTRIBUTED_LIVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_binds_worktree; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      #
      # --pipeline-activity never pays for it. A coarse row carries a status
      # word and no activity clock, so that mode can only answer `unknown` from
      # one - the same answer it gives here - and spending a second bounded call
      # plus a git walk per same-branch row to reach it would double the worst
      # case of a read the watcher makes on its single-threaded poll for every
      # aging pane, on exactly the panes that have no attributable run.
      #
      # `unknown` for all three, because this mode stops one source short of
      # proving there is no run - but the three misses are different facts about
      # a pane, and this sentence is read inside a wedge escalation, so a crew
      # that has simply not started a run must not be described as one whose run
      # failed to bind.
      if pipeline_mode; then
        if [ -z "$run_branch" ]; then
          emit_pipeline unknown "the pipeline CLI answered without naming a run, so there is no activity clock to read for this work"
        elif [ "$run_branch" != "$CREW_BRANCH" ]; then
          emit_pipeline unknown "the only run the pipeline CLI reports is for another branch ($run_branch), so no run of this work's own could be measured"
        else
          case "$NM_BIND_MISS" in
            no-visible-head) emit_pipeline unknown "the run the pipeline CLI reports for this branch holds a head this checkout cannot see, so nothing here ties its clock to this work either way" ;;
            scan-ceiling)    emit_pipeline unknown "this branch and the head of the run the pipeline CLI reports for it have diverged too far to check, so whose code that run is validating was never established" ;;
            stale-view)      emit_pipeline unknown "the pipeline CLI's own view of this checkout is already out of date, so the run it reports describes a checkout that has since moved" ;;
            *)               emit_pipeline unknown "the run the pipeline CLI reports for this branch is validating other code - a superseded or rewritten head - so its clock is not this work's" ;;
          esac
        fi
      fi
      nm_branch_sync_run_is_live && UNATTRIBUTED_LIVE_RUN=1
      COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH")
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- pipeline activity mode -------------------------------------------------
#
# The pipeline's OWN activity clock. During a validation run the crew's pane
# process is correct to be near-idle - it is blocked in one `axi run`/`axi
# respond` call while the work happens in the pipeline's separate agent - so
# every measurement taken on that pane is measuring the wrong subject. The
# installed CLI already publishes the right one: for a step whose status is
# running or fixing, `axi status` emits an `active_steps` table carrying
# `step`, `active_for`, `last_activity`, `agent_pid` and the current round, and
# marks a run waiting at a gate with `awaiting_agent: parked <duration>`.
# `last_activity` is prefixed `quiet` once no step log or native-agent
# lifecycle event has arrived for longer than the pipeline's own
# `step_quiet_warning`.
#
# Prints one line, "<class> <detail>":
#   active   an attributed run is advancing right now
#   quiet    an attributed run's own activity clock has gone quiet past that
#            warning window, so it is no longer evidence of progress
#   parked   an attributed run is waiting for THIS worker to answer a gate; a
#            quiet worker is then the fault, never an explanation for one
#   none     no run is attributed to this work, or its run is terminal
#   unknown  nothing could be measured - no CLI, no answer, coarse attribution
#            only, or an unreadable table
# Only `active` is evidence of progress. Every other class, `unknown`
# especially, must earn a caller nothing, so an unreadable pipeline degrades
# toward noise and never toward blindness.
#
# Read the first `active_steps` row by COLUMN NAME from the table header rather
# than by position, so a column added or reordered by a later CLI release
# yields an empty field (hence `unknown`) instead of a confidently wrong one.
nm_active_step_field() {  # <column-name>
  printf '%s\n' "$RUN_OUT" | awk -v want="$1" '
    $0 ~ /^[[:space:]]*active_steps\[[0-9]+\]\{[^}]*\}:[[:space:]]*$/ {
      hdr = $0
      sub(/^[^{]*\{/, "", hdr)
      sub(/\}.*$/, "", hdr)
      ncol = split(hdr, cols, ",")
      idx = 0
      for (i = 1; i <= ncol; i++) {
        c = cols[i]
        gsub(/^[ \t]+|[ \t]+$/, "", c)
        if (c == want) idx = i
      }
      if (idx == 0) exit
      if (getline row <= 0) exit
      nval = split(row, vals, ",")
      if (idx > nval) exit
      v = vals[idx]
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }'
}

if pipeline_mode; then
  if [ "$KIND" != ship ]; then
    emit_pipeline none "a $KIND task never drives a validation run of its own"
  fi
  if ! command -v no-mistakes >/dev/null 2>&1; then
    emit_pipeline unknown "the pipeline CLI is not installed here, so its activity cannot be measured"
  fi
  if [ -z "$CREW_BRANCH" ]; then
    emit_pipeline none "the task worktree is at a detached HEAD, so no run can be attributed to it"
  fi
  # Every other way to reach here without an attributed run already emitted
  # above: an answering CLI whose run this work cannot claim exits at the
  # three-way miss, so no run is left for this block but an absent answer - and
  # nothing unattributed can reach the field parsing below.
  if [ "$HAVE_RUN" != 1 ]; then
    emit_pipeline unknown "the pipeline CLI did not answer within ${NM_TIMEOUT}s"
  fi
  PA_OUTCOME=$(strip_quotes "$(nm_field outcome)")
  [ -n "$PA_OUTCOME" ] && emit_pipeline none "the attributed pipeline run is terminal ($PA_OUTCOME)"
  PA_STATUS=$(strip_quotes "$(nm_field status)")
  PA_AWAITING=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  PA_GATE_STATUS=$(nm_gate_status)
  PA_HAS_GATE=0
  nm_has_gate && PA_HAS_GATE=1
  if [ -n "$PA_AWAITING" ] || [ "$PA_STATUS" = awaiting_approval ] || [ "$PA_STATUS" = fix_review ] \
     || [ -n "$PA_GATE_STATUS" ] || [ "$PA_HAS_GATE" = 1 ]; then
    PA_GATE=$(nm_gate_name)
    [ -n "$PA_GATE" ] || PA_GATE=${PA_STATUS:-a gate}
    emit_pipeline parked "the attributed pipeline run is parked at $PA_GATE waiting for this worker to answer it"
  fi
  case "$PA_STATUS" in
    completed|failed|cancelled) emit_pipeline none "the attributed pipeline run is terminal ($PA_STATUS)" ;;
  esac
  PA_STEP=$(nm_active_step_field step)
  [ -n "$PA_STEP" ] || emit_pipeline unknown "the attributed pipeline run reports no active step, so its activity clock cannot be read"
  PA_FOR=$(nm_active_step_field active_for); [ -n "$PA_FOR" ] || PA_FOR=unknown
  PA_LAST=$(nm_active_step_field last_activity); [ -n "$PA_LAST" ] || PA_LAST=unknown
  case "$PA_LAST" in
    quiet*)
      # The CI step is the one place quiet is expected rather than telling: the
      # monitor is waiting on the forge's checks and writes no step log while it
      # does, which nm_ci_checks_state's marker vocabulary above already shows.
      # Every other step's quiet is a real liveness clue and earns nothing.
      [ "$PA_STEP" = ci ] && emit_pipeline active \
        "the attributed pipeline run is monitoring CI (step $PA_STEP, active $PA_FOR, last activity $PA_LAST) - a CI monitor waits on the forge and writes no step log while it does"
      emit_pipeline quiet \
        "the attributed pipeline run is at step $PA_STEP (active $PA_FOR) but its own activity clock reads $PA_LAST"
      ;;
  esac
  emit_pipeline active \
    "the attributed pipeline run is at step $PA_STEP, active $PA_FOR, last activity $PA_LAST"
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  # A failed run says WHY when the cause can be established from the pipeline's
  # own logs, so a usage-limit kill is not read as a crewmate that broke its
  # work. Deliberately after the state resolution above and only on the full
  # read, so the extra bounded call happens once, on failure, and never on a
  # healthy crew.
  if [ "$RUN_STATE" = failed ] && [ "$RUN_SOURCE" = full ]; then
    FAILED_CAUSE=$(nm_failed_cause)
    if [ -n "$FAILED_CAUSE" ]; then
      RUN_DETAIL="$RUN_DETAIL: $FAILED_CAUSE"
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    *) emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    # A TERMINAL verdict is the one thing this log line may not assert while the
    # CLI says a run is still live on this branch. The reader could not tie that
    # run to this code and does not pretend otherwise - but `failed:`/`done:`
    # here is necessarily an EARLIER run's outcome, and relaying it abandons a
    # gate that is still answerable or invites tearing live work down. Saying
    # `unknown` costs a supervisor one look; the terminal word costs the work.
    case "$LOG_STATE" in
      failed|done)
        if [ "$UNATTRIBUTED_LIVE_RUN" = 1 ]; then
          MISS_NOTE=$(nm_bind_miss_note)
          emit unknown none "a live pipeline run owns this branch but could not be tied to this code${MISS_NOTE:+ ($MISS_NOTE)}, so this crew's earlier \`$LOG_VERB:\` line is not its current state"
        fi
        ;;
    esac
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

MISS_NOTE=$(nm_bind_miss_note)
[ -z "$MISS_NOTE" ] || emit unknown none "no current-state source available: $MISS_NOTE"
emit unknown none "no current-state source available"
