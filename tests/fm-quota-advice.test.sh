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
             [ "${FM_FAKE_QUOTA_SLEEP:-0}" = 0 ] || sleep "${FM_FAKE_QUOTA_SLEEP}"
             printf '%s\n' "${FM_FAKE_QUOTA_JSON:-}" ;;
esac
exit 0
SH
  chmod +x "$fb/quota-axi"
  printf '%s\n' "$fb"
}

# A PATH carrying the tools the script needs but NOT `timeout` or `gtimeout`,
# which is the stock macOS layout. Pass "no-perl" to drop the last bounding
# mechanism too, leaving a host that cannot bound a call at all.
make_no_timeout_toolbin() {  # <dir> <tag> [no-perl] -> echoes toolbin path
  local dir=$1 tag=$2 drop=${3:-} tb tool real
  tb="$dir/notimeoutbin-$tag"
  mkdir -p "$tb"
  for tool in bash sh env jq sed head cut grep dirname pwd cat sleep; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for the no-timeout path: $tool"
    ln -sf "$real" "$tb/$tool"
  done
  if [ "$drop" != no-perl ]; then
    real=$(command -v perl || true)
    [ -n "$real" ] || fail "missing perl for the no-timeout path"
    ln -sf "$real" "$tb/perl"
  fi
  printf '%s\n' "$tb"
}

FB=$(make_fake_quota_axi "$TMP")
export FM_FAKE_QUOTA_VERSION="quota-axi 0.1.16"
export FM_FAKE_QUOTA_FAIL=0
export FM_FAKE_QUOTA_JSON=
export FM_FAKE_QUOTA_SLEEP=0

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

# Valid JSON carrying no windows is the degraded read that looks least like one:
# an unauthenticated account or a failed provider probe parses cleanly, so the
# renderer would walk it to completion and headline a healthy account with no
# window lines under it to contradict the claim.
for shapeless in '{}' '{"providers":[]}' '{"error":"not authenticated"}'; do
  FM_FAKE_QUOTA_JSON="$shapeless"
  out=$(run_advice); rc=$?
  [ "$rc" = 0 ] || fail "shapeless quota output must still exit 0 (advisory, never a refusal), got $rc for $shapeless"
  assert_contains "$out" "quota-advice: unavailable" \
    "valid JSON with no provider/window shape must report unavailable, got: $out"
  assert_not_contains "$out" "no window is exhausted" \
    "an account whose windows could not be read must NEVER be reported as a healthy one ($shapeless)"
done
pass "valid JSON carrying no provider/window shape reports unavailable, never a healthy account"

FM_FAKE_QUOTA_VERSION="quota-axi 0.1.2"
FM_FAKE_QUOTA_JSON=$(healthy_json)
out=$(run_advice); rc=$?
[ "$rc" = 0 ] || fail "an under-floor quota-axi must still exit 0, got $rc"
assert_contains "$out" "quota-advice: unavailable" "an under-floor quota-axi must report unavailable"
pass "a quota-axi below the shared compatibility floor reports unavailable rather than parsing it anyway"

# --- the read is bounded even where `timeout` does not exist ------------------
#
# `--json` is the provider network read, and it runs immediately before a
# validation dispatch. A caller that looks only for `timeout` falls through to an
# unbounded call on a stock macOS, so the one report whose promise is a fast,
# always-answering read would hang instead - the worst failure available to it,
# because it never returns rather than returning something wrong.
#
# A regression must fail this suite red rather than hang it, on every platform -
# including the one with no `timeout`, which is the whole point of these cases and
# so cannot be a host requirement for running them. The fake's sleep is finite, so
# the elapsed assertion alone is sufficient: an unbounded read returns a healthy
# account 30 seconds late and fails on both the clock and the headline. An outer
# bound is used when the host has one, purely to fail faster. It is resolved from
# the full PATH BEFORE the restricted one is imposed, and only the child is
# restricted.

TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
run_outer_bound() {
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" 20 "$@"; else "$@"; fi
}

FM_FAKE_QUOTA_VERSION="quota-axi 0.1.16"
FM_FAKE_QUOTA_JSON=$(healthy_json)
FM_FAKE_QUOTA_SLEEP=30
TB=$(make_no_timeout_toolbin "$TMP" perl)
start=$SECONDS
out=$(run_outer_bound env PATH="$FB:$TB" FM_QUOTA_ADVICE_TIMEOUT=1 "$ADVICE" 2>/dev/null); rc=$?
elapsed=$((SECONDS - start))
[ "$rc" != 124 ] \
  || fail "the advisory hung: with no \`timeout\` on PATH the --json read ran unbounded (${elapsed}s)"
[ "$rc" = 0 ] || fail "a bounded-out read must still exit 0 (advisory, never a refusal), got $rc"
[ "$elapsed" -lt 15 ] || fail "the --json read was not bounded promptly, took ${elapsed}s"
assert_contains "$out" "quota-advice: unavailable" \
  "a read that hit its bound must report unavailable, got: $out"
assert_not_contains "$out" "no window is exhausted" \
  "a read that never returned must never be reported as a healthy account"
pass "the --json read is bounded on a host with no \`timeout\`, reporting unavailable rather than hanging"

# --- a host that cannot bound at all reports, and still never blocks -----------

TB=$(make_no_timeout_toolbin "$TMP" noperl no-perl)
start=$SECONDS
out=$(run_outer_bound env PATH="$FB:$TB" FM_QUOTA_ADVICE_TIMEOUT=1 "$ADVICE" 2>/dev/null); rc=$?
elapsed=$((SECONDS - start))
[ "$rc" != 124 ] \
  || fail "with no bounding mechanism at all the advisory must report, never run quota-axi loose (${elapsed}s)"
[ "$rc" = 0 ] || fail "an unboundable host must still exit 0 (advisory, never a refusal), got $rc"
[ "$elapsed" -lt 15 ] || fail "the unboundable host read quota-axi anyway, took ${elapsed}s"
assert_contains "$out" "quota-advice: unavailable" "an unboundable host must report unavailable"
assert_contains "$out" "to bound the read" "the report must name the missing bound as the reason"
assert_not_contains "$out" "no window is exhausted" \
  "a host that never read the account must never report it healthy"
pass "a host with no timeout, gtimeout or perl reports unavailable instead of reading quota-axi unbounded"

FM_FAKE_QUOTA_SLEEP=0

echo "# fm-quota-advice.test.sh: all assertions passed"
