#!/usr/bin/env bash
# Behavior tests for the open-delegation record: the signature that lets
# supervision see a crewmate blocked inside a delegation tool call.
#
# The two shapes these cases must keep apart are the whole point, and they are
# indistinguishable to every other signal firstmate has:
#   - a worker blocked behind a helper, which needs to be seen; and
#   - a worker inside a long, healthy, non-delegation tool call, which must be
#     left alone.
# Here that separation is the shape test plus elapsed time. The watcher-level
# half - what the wedge alarm does with each - lives in tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVENT="$ROOT/bin/fm-delegation-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-delegation-event-tests)

# shellcheck source=bin/fm-delegation-lib.sh
. "$ROOT/bin/fm-delegation-lib.sh"

# Claude Code's verified delegation surface, plus the names a future release
# could ship before any fixed list knows them.
DELEGATION_TOOLS='Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage EnterWorktree ExitWorktree CronCreate TaskOutput TaskStop'
FUTURE_DELEGATION_TOOLS='DelegateWork SpawnHelper AgentPool RemoteExec DispatchJob TaskRunner'
ORDINARY_TOOLS='Bash Edit Read Write Skill ToolSearch WebFetch WebSearch NotebookEdit ReportFindings advisor'

fresh_state() {  # <name> -> echoes state dir
  local dir="$TMP_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# age_record: restate one open call as having started <secs> ago, the way a call
# that has genuinely been open that long would read.
age_record() {  # <state> <task> <key> <secs>
  local tool
  tool=$(sed -n 's/.* tool=//p' "$1/$2.delegating/$3")
  printf 'v1 ts=%s tool=%s\n' "$(( $(date +%s) - $4 ))" "$tool" > "$1/$2.delegating/$3"
}

test_delegation_shaped_calls_are_recorded_and_ordinary_ones_are_not() {
  local state tool n
  state=$(fresh_state shape)
  n=0
  for tool in $DELEGATION_TOOLS $FUTURE_DELEGATION_TOOLS; do
    n=$((n + 1))
    printf '{"tool_name":"%s","tool_use_id":"id%s"}' "$tool" "$n" | "$EVENT" open "$state" t
    [ -f "$state/t.delegating/id$n" ] \
      || fail "a delegation-shaped call ($tool) left no open record"
  done
  # The observe-or-stop names the primary guard deliberately allows are recorded
  # here on purpose: a worker parked in one is watching a helper it already
  # started, which is the shape being measured. That difference is why the two
  # consumers keep their own exclusions rather than sharing one list.
  for tool in $ORDINARY_TOOLS; do
    n=$((n + 1))
    printf '{"tool_name":"%s","tool_use_id":"id%s"}' "$tool" "$n" | "$EVENT" open "$state" t
    [ ! -e "$state/t.delegating/id$n" ] \
      || fail "an ordinary tool call ($tool) opened a delegation record"
  done
  printf '{"tool_name":"mcp__srv__spawn_agent","tool_use_id":"mcp1"}' | "$EVENT" open "$state" t
  [ ! -e "$state/t.delegating/mcp1" ] \
    || fail "an MCP tool name was classified as harness delegation"
  pass "delegation-shaped calls are recorded, ordinary and MCP calls are not"
}

# The load-bearing case. A subagent's own tool calls fire the SAME PreToolUse and
# PostToolUse hooks, nested inside the outer delegation call - verified live
# against Claude Code (docs/verification/supervision.md). A close that matched on
# anything looser than the harness's own call id would therefore retire the outer
# record the moment the helper ran its first command, which is exactly the window
# this record exists to measure.
test_a_nested_helper_tool_call_cannot_retire_the_outer_delegation() {
  local state open
  state=$(fresh_state nested)
  printf '{"tool_name":"Agent","tool_use_id":"toolu_outer"}' | "$EVENT" open "$state" t
  age_record "$state" t toolu_outer 1800
  # The helper's own calls, opened and closed inside the outer one.
  printf '{"tool_name":"Bash","tool_use_id":"toolu_inner1"}' | "$EVENT" open "$state" t
  printf '{"tool_name":"Bash","tool_use_id":"toolu_inner1"}' | "$EVENT" close "$state" t
  printf '{"tool_name":"Read","tool_use_id":"toolu_inner2"}' | "$EVENT" open "$state" t
  printf '{"tool_name":"Read","tool_use_id":"toolu_inner2"}' | "$EVENT" close "$state" t
  open=$(fm_delegation_open_age "$state" t) \
    || fail "the outer delegation was retired by a nested helper tool call"
  [ "${open%% *}" -ge 1800 ] \
    || fail "a nested tool call restated the outer delegation as fresh: $open"
  printf '{"tool_name":"Agent","tool_use_id":"toolu_outer"}' | "$EVENT" close "$state" t
  fm_delegation_open_age "$state" t >/dev/null \
    && fail "the outer delegation survived its own matching close"
  [ -d "$state/t.delegating" ] \
    || fail "a close removed the record directory, which a concurrent open needs to survive"
  pass "a nested helper tool call cannot retire or refresh the outer delegation"
}

test_the_oldest_open_call_is_the_one_reported() {
  local state open
  state=$(fresh_state oldest)
  printf '{"tool_name":"Agent","tool_use_id":"first"}' | "$EVENT" open "$state" t
  age_record "$state" t first 4000
  printf '{"tool_name":"Workflow","tool_use_id":"second"}' | "$EVENT" open "$state" t
  age_record "$state" t second 30
  open=$(fm_delegation_open_age "$state" t) || fail "two open calls reported none"
  [ "${open#* }" = Agent ] \
    || fail "a short concurrent call displaced the long one as the reported call: $open"
  [ "${open%% *}" -ge 4000 ] \
    || fail "a short concurrent call restated the long one as fresh: $open"
  # Retiring the long one leaves the short one, still measured on its own clock.
  printf '{"tool_name":"Agent","tool_use_id":"first"}' | "$EVENT" close "$state" t
  open=$(fm_delegation_open_age "$state" t) || fail "the surviving call reported none"
  [ "${open#* }" = Workflow ] || fail "the surviving call was misreported: $open"
  [ "${open%% *}" -lt 100 ] || fail "the surviving call inherited the retired one's age: $open"
  pass "the oldest open call is what is reported, and retiring it does not age the rest"
}

test_a_reopened_call_id_never_restates_its_own_clock() {
  local state open
  state=$(fresh_state reopen)
  printf '{"tool_name":"Agent","tool_use_id":"same"}' | "$EVENT" open "$state" t
  age_record "$state" t same 2500
  printf '{"tool_name":"Agent","tool_use_id":"same"}' | "$EVENT" open "$state" t
  open=$(fm_delegation_open_age "$state" t) || fail "the reopened call reported none"
  [ "${open%% *}" -ge 2500 ] \
    || fail "a repeated PreToolUse for the same call reset the clock it exists to keep: $open"
  pass "a repeated open for the same call id never restates its clock"
}

# Claude issues parallel tool calls in one assistant block, so a sibling's
# PostToolUse can land in the window between a delegation open's mkdir and its
# write. If that close removed the record directory, the open's write would fail
# into its own `|| true` and the delegation would leave NO record for its entire
# lifetime - the exact blindness this record exists to remove, and worse than a
# lost close, which only costs a deferral the pane would have been granted.
# The window is eliminated rather than narrowed: close never removes the
# directory, and clear and teardown own that.
test_a_sibling_close_cannot_strand_a_concurrent_open() {
  local state open
  state=$(fresh_state race)
  # The state a delegation open is in after its mkdir and before its write.
  mkdir -p "$state/t.delegating"
  printf '{"tool_name":"Read","tool_use_id":"sibling"}' | "$EVENT" close "$state" t
  [ -d "$state/t.delegating" ] \
    || fail "a sibling close removed the directory a concurrent open was populating"
  printf '{"tool_name":"Agent","tool_use_id":"outer"}' | "$EVENT" open "$state" t
  [ -f "$state/t.delegating/outer" ] \
    || fail "the delegation open lost its record to a concurrent sibling close"
  open=$(fm_delegation_open_age "$state" t) \
    || fail "a delegation that raced a sibling close reported nothing open"
  [ "${open#* }" = Agent ] \
    || fail "the stranded-open case reported the wrong call: $open"
  pass "a delegation open concurrent with a sibling close still leaves its record"
}

test_clear_retires_every_open_call() {
  local state
  state=$(fresh_state clear)
  printf '{"tool_name":"Agent","tool_use_id":"a"}' | "$EVENT" open "$state" t
  printf '{"tool_name":"Workflow","tool_use_id":"b"}' | "$EVENT" open "$state" t
  age_record "$state" t a 9000
  "$EVENT" clear "$state" t < /dev/null
  fm_delegation_open_age "$state" t >/dev/null \
    && fail "clear left an open call behind, so a stale record could outlive its turn"
  pass "clear retires every open call, bounding a missed close to one turn"
}

# The veto direction is the opposite of every other measure the wedge alarm
# reads: those escalate when unmeasurable, this one must simply not fire. A
# record that cannot be read must therefore answer "nothing open", never "open
# forever".
test_unreadable_records_report_nothing_open() {
  local state open
  state=$(fresh_state unreadable)
  fm_delegation_open_age "$state" t >/dev/null \
    && fail "a task with no directory at all reported an open call"
  mkdir -p "$state/t.delegating"
  fm_delegation_open_age "$state" t >/dev/null \
    && fail "an empty directory reported an open call"
  printf 'garbage\n' > "$state/t.delegating/corrupt"
  printf 'v1 ts= tool=Agent\n' > "$state/t.delegating/emptyts"
  printf 'v1 ts=notanumber tool=Agent\n' > "$state/t.delegating/badts"
  fm_delegation_open_age "$state" t >/dev/null \
    && fail "unreadable records reported an open call"
  # A record stamped in the future means the clock stepped backwards, so this
  # call's span is unknowable. Clamping it would read as a brand-new call and
  # hide a long one; skipping it leaves the tiers exactly as they were.
  printf 'v1 ts=%s tool=Agent\n' "$(( $(date +%s) + 5000 ))" > "$state/t.delegating/future"
  fm_delegation_open_age "$state" t >/dev/null \
    && fail "a record stamped in the future was measured anyway"
  # One good record among the unusable ones is still reported.
  printf 'v1 ts=%s tool=Agent\n' "$(( $(date +%s) - 700 ))" > "$state/t.delegating/good"
  open=$(fm_delegation_open_age "$state" t) \
    || fail "a readable record was lost among unreadable ones"
  [ "${open#* }" = Agent ] && [ "${open%% *}" -ge 700 ] \
    || fail "a readable record was lost among unreadable ones: $open"
  pass "every unreadable record reports nothing open rather than a phantom block"
}

# This runs inside a worker's own tool-call path, where a nonzero exit or stray
# output can block a tool call or be read as hook feedback.
test_every_invocation_is_silent_and_succeeds() {
  local state rc out err bad
  state=$(fresh_state silent)
  out="$TMP_ROOT/ev.out"; err="$TMP_ROOT/ev.err"
  for bad in \
    "open $state" \
    "open $state ../escape --tool Agent --call x" \
    "close $state t --call" \
    "bogus $state t" \
    "open" \
    ""; do
    rc=0
    # shellcheck disable=SC2086 # deliberate word splitting of the argument case
    "$EVENT" $bad > "$out" 2> "$err" < /dev/null || rc=$?
    [ "$rc" -eq 0 ] || fail "invocation [$bad] exited $rc instead of failing silently"
    [ ! -s "$out" ] || fail "invocation [$bad] wrote stdout: $(cat "$out")"
    [ ! -s "$err" ] || fail "invocation [$bad] wrote stderr: $(cat "$err")"
  done
  [ ! -e "$state/../escape.delegating" ] \
    || fail "a task id containing a path traversal wrote outside the state directory"
  rc=0
  printf 'not json at all' | "$EVENT" open "$state" t > "$out" 2> "$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "a malformed payload exited $rc instead of failing silently"
  [ ! -s "$out" ] && [ ! -s "$err" ] || fail "a malformed payload wrote output"
  fm_delegation_open_age "$state" t >/dev/null \
    && fail "a malformed payload opened a record"
  pass "every malformed or hostile invocation is silent, succeeds, and writes nothing"
}

test_delegation_shaped_calls_are_recorded_and_ordinary_ones_are_not
test_a_nested_helper_tool_call_cannot_retire_the_outer_delegation
test_the_oldest_open_call_is_the_one_reported
test_a_reopened_call_id_never_restates_its_own_clock
test_a_sibling_close_cannot_strand_a_concurrent_open
test_clear_retires_every_open_call
test_unreadable_records_report_nothing_open
test_every_invocation_is_silent_and_succeeds

echo "all fm-delegation-event tests passed"
