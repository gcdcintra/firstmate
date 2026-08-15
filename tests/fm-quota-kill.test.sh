#!/usr/bin/env bash
# tests/fm-quota-kill.test.sh - behavior tests for bin/fm-quota-kill-lib.sh, the
# single owner of the vendor usage-limit recognizer.
#
# The recognizer exists because no-mistakes reports a pipeline agent killed by
# the account usage limit with byte-identical text to one that crashed. Half of
# these cases therefore pin the POSITIVE direction (a real kill is recognized,
# with the right window), and half pin the direction that must never regress:
# a genuine agent failure is never excused as an external quota event.
#
# Every fixture below is the real shape observed in ~/.no-mistakes/logs; the run
# ids and exact output that back them are in
# docs/verification/quota-kill-classification.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-quota-kill-lib.sh
. "$ROOT/bin/fm-quota-kill-lib.sh"

# --- fixtures ---------------------------------------------------------------

# The model-window family, as the review step logs it verbatim.
log_model_kill() {
  cat <<'EOF'
reviewing changes...

claude started pid=95327

You've reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model.
claude exited pid=95327 error=claude exited: exit status 1:


error: agent review: claude exited: exit status 1:
EOF
}

# The session (five-hour) window family, which also carries a reset hint.
log_session_kill() {
  cat <<'EOF'
reviewing changes...

claude started pid=2528900

I'll review the branch changes. Let me start by reading the diff and relevant context.You've hit your session limit · resets 2am (UTC)
claude exited pid=2528900 error=claude exited: exit status 1:


error: agent review: claude exited: exit status 1:
EOF
}

# A genuine agent death: no vendor message anywhere, only the exit shape.
log_genuine_kill() {
  cat <<'EOF'
no test command configured, asking agent to run tests...

claude started pid=2706190

I'll start by orienting: reviewing what changed between base and target.
claude exited pid=2706190 error=claude exited: signal: killed:


error: agent run tests: claude exited: signal: killed:
EOF
}

# --- positive direction: a real kill is recognized, with its window ----------

rec=$(log_model_kill | fm_quota_kill_scan --agent-episode) \
  || fail "a real model-window kill must be recognized"
[ "$(fm_quota_kill_window "$rec")" = "model:Fable 5" ] \
  || fail "the model window must name the model the vendor named, got '$(fm_quota_kill_window "$rec")'"
case "$(fm_quota_kill_evidence "$rec")" in
  "You've reached your Fable 5 limit."*) : ;;
  *) fail "the evidence must carry the vendor sentence, got '$(fm_quota_kill_evidence "$rec")'" ;;
esac
pass "a model-window kill is recognized and names the model window the vendor named"

rec=$(log_session_kill | fm_quota_kill_scan --agent-episode) \
  || fail "a real session-window kill must be recognized"
[ "$(fm_quota_kill_window "$rec")" = session ] \
  || fail "the five-hour family must report the session window, got '$(fm_quota_kill_window "$rec")'"
case "$(fm_quota_kill_evidence "$rec")" in
  *"resets 2am"*) : ;;
  *) fail "the session evidence must keep the vendor's reset hint, got '$(fm_quota_kill_evidence "$rec")'" ;;
esac
pass "a session-window kill is recognized and keeps the vendor's reset hint as evidence"

# The harness streams agent prose and the vendor sentence onto ONE line, so the
# recognizer has to match a substring; a whole-line compare would miss every
# kill that interrupted a talking agent.
rec=$(printf 'claude started pid=1\nLet me orient in the worktree first.You'"'"'ve reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model.\nclaude exited pid=1 error=claude exited: exit status 1: \n' \
  | fm_quota_kill_scan --agent-episode) \
  || fail "a vendor sentence glued to streamed agent prose must still be recognized"
[ "$(fm_quota_kill_window "$rec")" = "model:Fable 5" ] \
  || fail "the glued-prose line must still yield the model window, got '$(fm_quota_kill_window "$rec")'"
pass "a vendor sentence glued to streamed agent prose on one line is still recognized"

# A pane capture has no agent-episode structure at all, so the pane consumer
# scans without the flag and must still recognize the same sentence.
rec=$(printf 'esc to interrupt\nYou'"'"'ve hit your session limit · resets 2am (UTC)\nWhat do you want to do?\n' \
  | fm_quota_kill_scan) \
  || fail "pane text with no episode structure must still be recognized"
[ "$(fm_quota_kill_window "$rec")" = session ] || fail "pane scan must report the session window"
pass "pane text with no agent-episode structure is recognized without the episode flag"

# --- the direction that must not regress: a real failure stays a real failure -

if log_genuine_kill | fm_quota_kill_scan --agent-episode; then
  fail "a genuine agent death (signal: killed, no vendor message) must NEVER be reported as a quota kill"
fi
pass "a genuine agent death is not excused as a quota event"

# "reached your ... limit" is ordinary enough prose that a review agent quoting a
# diff can emit it. Without the vendor's own action link it is not a kill.
if printf 'claude started pid=1\nThe check fires once you have reached your configured limit. You'"'"'ve reached your daily limit is the wording.\nassertion failed: want 3 got 2\nclaude exited pid=1 error=claude exited: exit status 1: \n' \
  | fm_quota_kill_scan --agent-episode; then
  fail "agent prose resembling the vendor sentence must not be classified as a quota kill"
fi
pass "agent prose resembling the vendor sentence is not classified as a quota kill"

# A step log can hold several agent episodes. A kill the pipeline already retried
# past is not why the step ended, so only the FINAL episode may classify it.
if printf 'claude started pid=1\nYou'"'"'ve reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model.\nclaude exited pid=1 error=claude exited: exit status 1: \nstarting a fresh review-fixer session\nclaude started pid=2\ntest failure: 3 assertions failed\nclaude exited pid=2 error=claude exited: exit status 1: \n' \
  | fm_quota_kill_scan --agent-episode; then
  fail "a quota kill the pipeline retried past must not excuse the genuine failure that ended the step"
fi
pass "an earlier quota kill the pipeline retried past never excuses the final episode's genuine failure"

# The same text without the flag still reports the kill it contains: the flag is
# what binds a kill to the step's outcome, and the pane consumer must not get it.
rec=$(printf 'claude started pid=1\nYou'"'"'ve reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model.\nclaude exited pid=1 error=claude exited: exit status 1: \nclaude started pid=2\ntest failure\n' \
  | fm_quota_kill_scan) \
  || fail "without the episode flag the recognizer must still report a kill present in the text"
[ "$(fm_quota_kill_window "$rec")" = "model:Fable 5" ] || fail "plain scan must report the recognized window"
pass "the episode flag is what binds a kill to a step outcome; plain scan still reports the text's kill"

# --- evidence bound ---------------------------------------------------------

long=$(printf 'claude started pid=1\nYou'"'"'ve hit your session limit · resets 2am (UTC)%s\n' "$(head -c 4000 < /dev/zero | tr '\0' 'x')")
rec=$(printf '%s\n' "$long" | fm_quota_kill_scan) || fail "a long line must still be recognized"
[ "${#rec}" -le 220 ] || fail "evidence must stay bounded so a wake reason cannot be flooded, got ${#rec} bytes"
pass "evidence is bounded so an enormous pane or log line cannot flood a wake reason"

# --- failed-step extraction from an axi status steps table ------------------

step=$(fm_quota_kill_failed_step <<'EOF'
run:
  id: "01KZW3F28V5XWBZCBTX7963S81"
  branch: fm/sm-cf-nf3-settlement
  status: failed
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,5
    rebase,completed,0,1624
    review,failed,0,4049
    test,pending,0,0
outcome: failed
EOF
)
[ "$step" = review ] || fail "the failed step must be read from the steps table, got '$step'"
pass "the failed step is read from an axi status steps table"

step=$(fm_quota_kill_failed_step <<'EOF'
run:
  id: "01RUN"
  status: running
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,5
    review,running,0,4049
EOF
)
[ -z "$step" ] || fail "a table with no failed row must yield no step, got '$step'"
pass "a steps table with no failed row yields no step, so no log is read"

step=$(fm_quota_kill_failed_step <<'EOF'
run:
  id: "01RUN"
  status: failed
outcome: failed
EOF
)
[ -z "$step" ] || fail "a status with no steps table at all must yield no step, got '$step'"
pass "a status carrying no steps table yields no step rather than guessing one"

echo "# fm-quota-kill.test.sh: all assertions passed"
