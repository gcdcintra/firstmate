#!/usr/bin/env bash
# tests/fm-quota-advice.test.sh - behavior tests for bin/fm-quota-advice.sh.
#
# The report exists to answer, before an expensive validation run, the question
# that keeps being answered wrong: "quota is back" is not one question, because
# an account window, a weekly window and a per-model window bound the work
# independently. The property these cases protect above all is that it stays
# ADVISORY - it always exits 0, so it can never become a check that quietly
# shrinks the fleet behind the captain's standing instruction.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADVICE="$ROOT/bin/fm-quota-advice.sh"
TMP=$(fm_test_tmproot fm-quota-advice)

# A fake quota-axi whose --json body and --version come from the environment, so
# each case drives the real script over a real jq with no live account read.
make_fake_quota_axi() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' "${FM_FAKE_QUOTA_VERSION:-quota-axi 0.1.16}" ;;
  --json)    [ "${FM_FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
             printf '%s\n' "${FM_FAKE_QUOTA_JSON:-}" ;;
esac
exit 0
SH
  chmod +x "$fb/quota-axi"
  printf '%s\n' "$fb"
}

FB=$(make_fake_quota_axi "$TMP")
export FM_FAKE_QUOTA_VERSION="quota-axi 0.1.16"
export FM_FAKE_QUOTA_FAIL=0
export FM_FAKE_QUOTA_JSON=

healthy_json() {
  cat <<'EOF'
{"providers":[{"provider":"claude","windows":[
 {"id":"five_hour","percentRemaining":86,"resetsAt":"2026-08-15T18:00:00Z","pace":{"status":"behind"}},
 {"id":"seven_day","percentRemaining":42,"resetsAt":"2026-08-20T10:00:00Z","pace":{"status":"ahead"}},
 {"id":"model:fable","percentRemaining":43,"resetsAt":"2026-08-20T10:00:00Z","pace":{"status":"ahead"}}],
 "quotaSemantics":{"effectiveAvailability":[
 {"scope":"all_models","effectivePercentRemaining":42,"limitingWindowIds":["seven_day"]}]}}]}
EOF
}

# The documented trap: the session window resets and reads healthy while the
# per-model window the pipeline agent draws on is flat at zero.
model_exhausted_json() {
  cat <<'EOF'
{"providers":[{"provider":"claude","windows":[
 {"id":"five_hour","percentRemaining":99,"resetsAt":"2026-08-15T18:00:00Z"},
 {"id":"seven_day","percentRemaining":12,"resetsAt":"2026-08-20T10:00:00Z"},
 {"id":"model:fable","percentRemaining":0,"resetsAt":"2026-08-20T10:00:00Z"}],
 "quotaSemantics":{"effectiveAvailability":[
 {"scope":"model:fable","effectivePercentRemaining":0,"limitingWindowIds":["model:fable"]}]}}]}
EOF
}

run_advice() {
  PATH="$FB:$PATH" "$ADVICE"
}

# --- every window is reported, not just the session --------------------------

FM_FAKE_QUOTA_JSON=$(healthy_json)
out=$(run_advice); rc=$?
[ "$rc" = 0 ] || fail "the report must always exit 0, got $rc"
assert_contains "$out" "window: claude five_hour 86% remaining" "the session window must be reported"
assert_contains "$out" "window: claude seven_day 42% remaining" "the weekly window must be reported"
assert_contains "$out" "window: claude model:fable 43% remaining" "the per-model window must be reported"
assert_contains "$out" "bound by seven_day" "the limiting window must be named, not left to be inferred"
assert_contains "$out" "no window is exhausted" "a healthy account must say so plainly"
pass "every window is reported with the one that binds named, so 'quota is back' is answered in full"

# --- an exhausted per-model window is the headline, even under a fresh session -

FM_FAKE_QUOTA_JSON=$(model_exhausted_json)
out=$(run_advice); rc=$?
[ "$rc" = 0 ] || fail "an exhausted window must still exit 0 (advisory, never a refusal), got $rc"
assert_contains "$out" "quota-advice: exhausted - claude:model:fable" \
  "an exhausted per-model window must be the headline"
assert_contains "$out" "a validation run drawing on one of those dies immediately" \
  "the consequence must be stated, and scoped to runs that draw on the exhausted window"
assert_contains "$out" "window: claude five_hour 99% remaining" \
  "the healthy-looking session window must still be shown, since that is the misreading being prevented"
pass "an exhausted per-model window is the headline even while the session window reads healthy"

# --- advisory, structurally: it reports and never withholds -------------------

assert_contains "$out" "advisory only" "the report must say plainly that it does not decide dispatch"
assert_contains "$out" "never withholds a spawn" "the report must state that it cannot withhold a spawn"
pass "the report states its own advisory limit, so it is never mistaken for a dispatch gate"

# --- degradation: unreadable quota is reported, never guessed -----------------

FM_FAKE_QUOTA_FAIL=1
out=$(run_advice); rc=$?
[ "$rc" = 0 ] || fail "a failed quota read must still exit 0, got $rc"
assert_contains "$out" "quota-advice: unavailable" "a failed quota read must report unavailable"
assert_not_contains "$out" "no window is exhausted" \
  "an unreadable account must never be reported as a healthy one"
FM_FAKE_QUOTA_FAIL=0
pass "a failed quota read reports unavailable rather than an invented healthy answer"

FM_FAKE_QUOTA_JSON='not json at all'
out=$(run_advice); rc=$?
[ "$rc" = 0 ] || fail "malformed quota output must still exit 0, got $rc"
assert_contains "$out" "quota-advice: unavailable" "malformed output must report unavailable"
pass "malformed quota output reports unavailable rather than a partial answer"

FM_FAKE_QUOTA_VERSION="quota-axi 0.1.2"
FM_FAKE_QUOTA_JSON=$(healthy_json)
out=$(run_advice); rc=$?
[ "$rc" = 0 ] || fail "an under-floor quota-axi must still exit 0, got $rc"
assert_contains "$out" "quota-advice: unavailable" "an under-floor quota-axi must report unavailable"
pass "a quota-axi below the shared compatibility floor reports unavailable rather than parsing it anyway"

echo "# fm-quota-advice.test.sh: all assertions passed"
