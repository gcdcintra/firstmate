#!/usr/bin/env bash
# fm-send post-submit settle pause (FM_SEND_SETTLE).
#
# fm-send's success only proves the composer cleared - the Enter landed and the
# text was submitted. The harness then takes a beat to spin up the turn before its
# busy footer appears, so an immediate peek after fm-send returns would see the
# stale idle pane. fm-send therefore pauses FM_SEND_SETTLE seconds (default 1, 0
# disables) after a successful text submit, so the receiving turn has time to
# visibly start. These tests pin that behavior hermetically (stubbed tmux + sleep,
# no real agent):
#   1. A successful text send pauses for the FM_SEND_SETTLE value (default 1).
#   2. FM_SEND_SETTLE=0 produces no pause at all (sleep is never invoked for it).
#   3. The pause is tunable (FM_SEND_SETTLE=7 pauses 7).
#   4. The --key path never pauses (it bypasses the submit/settle path entirely).
#
# The same file also owns the --key path's other duty. Claude fires NO hook for a
# manual interrupt, so every per-turn record its hooks would have closed has to be
# closed by fm-send itself: the busy edge, and the open delegation records that
# tell supervision a worker is blocked behind a helper of its own. Interrupt-then-
# steer is the prescribed recovery for exactly that shape, so a record left behind
# here would keep accusing a helper the captain already killed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-delegation-lib.sh
. "$ROOT/bin/fm-delegation-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-settle)

# A fake tmux that lets fm-send's submit path reach a clean "empty" verdict, plus a
# fake sleep that records every requested duration (one per line) instead of
# sleeping. send-keys always succeeds; display-message yields a numeric cursor_y;
# capture-pane returns an empty bordered composer so fm_tmux_composer_state reads
# "empty" (submit landed) on the first Enter. The sleep log path comes from
# FM_SLEEP_LOG.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <sleep-log> [env-assignments...] -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH. FM_ROOT_OVERRIDE points at a non-repo
# temp dir so fm-guard's tangle check stays silent, and FM_HOME at an empty home so
# no in-flight task is seen; guard noise goes to stderr (discarded). Echoes nothing;
# returns fm-send's exit code.
run_send() {
  local fb=$1 log=$2 home; shift 2
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  : > "$log"
  env "$@" PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" "hello captain" 2>/dev/null
}

test_default_send_pauses_one_second() {
  local dir fb log rc last
  dir="$TMP_ROOT/default"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log"; rc=$?
  expect_code 0 "$rc" "default send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 1 ] || fail "default send: expected a trailing 1s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: a successful text send pauses the default 1s after submit"
}

test_zero_disables_pause() {
  local dir fb log rc
  dir="$TMP_ROOT/zero"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=0; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=0 send should succeed"
  # The disable path must not invoke sleep with 0 at all - the only sleeps left are
  # the submit core's own settle/enter waits, none of which is "0".
  if grep -qx '0' "$log"; then
    fail "FM_SEND_SETTLE=0 still paused (a sleep 0 was recorded)"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  fi
  pass "fm-send: FM_SEND_SETTLE=0 produces no settle pause"
}

test_pause_is_tunable() {
  local dir fb log rc last
  dir="$TMP_ROOT/tunable"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=7; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=7 send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 7 ] || fail "FM_SEND_SETTLE=7: expected a trailing 7s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the settle pause is tunable via FM_SEND_SETTLE"
}

test_key_path_never_pauses() {
  local dir fb log rc home
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "--key send should succeed"
  [ ! -s "$log" ] || fail "--key path paused but must not"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the --key path never pauses (settle scoped to text submit)"
}

# Seed one genuinely open delegation call through the real writer, then prove the
# setup landed: that writer is silent by contract, so a seed that quietly failed
# would make every clear assertion below pass for the wrong reason.
seed_open_delegation() {  # <state-dir> <task> <call-id>
  printf '{"tool_name":"Agent","tool_use_id":"%s"}' "$3" \
    | "$ROOT/bin/fm-delegation-event.sh" open "$1" "$2"
  fm_delegation_open_age "$1" "$2" >/dev/null \
    || fail "setup: seeding an open delegation call for '$2' recorded nothing"
}

test_claude_escape_records_interrupt_idle() {
  local dir fb log rc home gen out
  dir="$TMP_ROOT/claude-interrupt"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/task.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" task)
  printf 'busy_gen=%s\n' "$gen" >> "$home/state/task.meta"
  seed_open_delegation "$home/state" task toolu_blocked
  : > "$log"

  env PATH="$fb:$PATH" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" task --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "Claude Escape send should succeed"
  out=$(fm_busy_classify tmux sess:win claude task "$home/state")
  [ "$out" = "idle fm-interrupt" ] \
    || fail "Claude Escape must classify idle/fm-interrupt, got '$out'"
  fm_delegation_open_age "$home/state" task >/dev/null \
    && fail "Claude Escape left an open delegation call behind, so the wedge alarm would keep naming a helper the captain already killed"
  pass "fm-send: a successful Claude Escape records the interrupt lifecycle edge and retires the open delegation"
}

# The busy-gen precondition is busy-specific: an unarmed task still holds
# delegation records, and Escape is still the only thing that will ever close
# them. So the delegation clear must sit ahead of that gate, and the interrupt
# must still succeed with nothing to record on the busy side.
test_claude_escape_clears_delegation_without_a_busy_generation() {
  local dir fb log rc home
  dir="$TMP_ROOT/claude-interrupt-unarmed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/task.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  seed_open_delegation "$home/state" task toolu_unarmed
  [ ! -e "$home/state/task.busy-gen" ] \
    || fail "setup: this case must run with no armed busy generation"
  : > "$log"

  env PATH="$fb:$PATH" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" task --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "an Escape to an unarmed Claude task must still succeed"
  fm_delegation_open_age "$home/state" task >/dev/null \
    && fail "the delegation clear was gated on the busy-gen precondition, so an unarmed task keeps a stale open call"
  pass "fm-send: Escape clears the open delegation even with no armed busy generation"
}

test_default_send_pauses_one_second
test_zero_disables_pause
test_pause_is_tunable
test_key_path_never_pauses
test_claude_escape_records_interrupt_idle
test_claude_escape_clears_delegation_without_a_busy_generation
