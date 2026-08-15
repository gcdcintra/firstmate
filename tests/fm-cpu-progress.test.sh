#!/usr/bin/env bash
# tests/fm-cpu-progress.test.sh - the worker-CPU-progress contract in
# bin/fm-cpu-progress-lib.sh, the evidence source a worker inside one long
# tool-driven turn cannot produce for itself.
#
# Every case drives REAL processes through the real /proc counter rather than
# canned stat files, because the whole point of the library is that the counter
# it reads is the one the kernel maintains: a fake would prove nothing about the
# hung and socket-blocked cases it must keep escalating.
#
# The safety invariant under test throughout: `progressing` is the ONLY verdict
# that may suppress an escalation, and every failure mode - unresolvable pid,
# vanished process, immature, over-wide, or clock-stepped window, no /proc at
# all - returns `unknown`, which escalates. Watcher-level consequences
# (deferral, the per-pane deferral budget, and the evidence carried in the wake
# reason) live in tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The library needs fm_backend_agent_pid from the backend layer.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-cpu-progress-lib.sh
. "$ROOT/bin/fm-cpu-progress-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cpu-progress-tests)
# fm_test_tmproot registers its cleanup inside the command substitution's own
# subshell, so the directory is already gone by the time it is echoed back; the
# other suites re-create it lazily through their case builders and this one does
# the same rather than changing that shared helper's contract here.
mkdir -p "$TMP_ROOT"

if ! fm_cpu_progress_supported; then
  printf 'ok - skipped: no /proc on this platform, every verdict is unknown by contract\n'
  exit 0
fi

# --- process fixtures -------------------------------------------------------

KIDS=()
reap_kids() {
  local p
  for p in "${KIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  KIDS=()
}
trap 'reap_kids; fm_test_cleanup' EXIT

# Fixture processes set SPAWNED rather than printing their pid: a command
# substitution around a background start would block until the child's inherited
# stdout closed, which for a spin loop is never. They are also self-terminating,
# so a killed or crashed test run can never leave a spin loop burning a core on
# a machine shared with other workers - the EXIT trap is the first line of
# defense, LIFE_SECS is the backstop.
LIFE_SECS=120
SPAWNED=""

spawn_bg() {  # <shell-snippet>
  bash -c "$1" >/dev/null 2>&1 &
  SPAWNED=$!
  KIDS+=("$SPAWNED")
}

# spawn_busy: a process pinned to a real CPU spin - the productive long turn.
spawn_busy() {
  spawn_bg "end=\$((SECONDS + $LIFE_SECS)); while [ \$SECONDS -lt \$end ]; do :; done"
}

# spawn_hung: a process that will never be scheduled again - the hung agent.
spawn_hung() {
  spawn_bg "exec sleep $LIFE_SECS"
}

# spawn_barely_moving: a process whose counter creeps rather than sits at zero -
# the shape of the 2026-08-10 socket wedge, which held 539136 bytes in a TCP
# send queue and still logged 10 ticks over 45s. It must classify flat.
spawn_barely_moving() {
  spawn_bg "end=\$((SECONDS + $LIFE_SECS)); while [ \$SECONDS -lt \$end ]; do sleep 0.5; done"
}

# The library resolves a pid through the backend only when its record has no
# usable cached pid. These tests own that seam directly: FAKE_PID is what the
# resolver returns, and an empty FAKE_PID models a backend with no resolver.
FAKE_PID=""
fm_backend_agent_pid() {  # <backend> <target>
  [ -n "$FAKE_PID" ] || return 1
  printf '%s' "$FAKE_PID"
}

# verdict_class / verdict_detail: split the library's "<class> <evidence>" line.
verdict_class() { printf '%s' "${1%% *}"; }
verdict_detail() { printf '%s' "${1#* }"; }

# ticks_used: the tick count an evidence line reports, for asserting that a
# `flat` verdict is genuinely a below-floor reading rather than a zero-only one.
ticks_used() {
  printf '%s' "$1" | sed -n 's/.*used \([0-9][0-9]*\) CPU ticks.*/\1/p'
}

# settle_window: let a sampling window mature past <secs>.
settle_window() { sleep "$1"; }

new_record() { printf '%s/rec.%s' "$TMP_ROOT" "$1"; }

# --- cases ------------------------------------------------------------------

test_first_sample_is_unknown() {
  local rec v
  rec=$(new_record first-sample); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  v=$(fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "the first sample of a worker returned '$v' instead of unknown"
  [ -s "$rec" ] || fail "the first sample did not write a rolling anchor"
  pass "the first sample has no window yet and returns unknown, which escalates"
}

test_busy_process_is_progressing() {
  local rec v
  rec=$(new_record busy); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  settle_window 4
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = progressing ] \
    || fail "a worker burning real CPU returned '$v' instead of progressing"
  pass "a worker whose CPU counter is moving classifies progressing - the long productive turn"
}

test_hung_process_is_flat() {
  local rec v
  rec=$(new_record hung); rm -f "$rec"
  spawn_hung; FAKE_PID=$SPAWNED
  FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  settle_window 4
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = flat ] \
    || fail "a hung worker returned '$v' instead of flat"
  [ "$(ticks_used "$v")" = 0 ] \
    || fail "a hung worker reported non-zero CPU: $v"
  pass "a hung worker's counter never moves and classifies flat, which escalates"
}

test_barely_moving_process_is_flat_at_the_default_floor() {
  local rec v
  rec=$(new_record barely); rm -f "$rec"
  spawn_barely_moving; FAKE_PID=$SPAWNED
  fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  settle_window "$(( FM_CPU_PROGRESS_WINDOW + 2 ))"
  v=$(fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = flat ] \
    || fail "a barely-moving worker returned '$v' instead of flat at the shipped floor"
  pass "a worker whose counter only creeps stays flat at the shipped floor - the socket-wedge shape"
}

# The floor must be a real floor, not a zero test: a worker doing MEASURABLE
# work that still falls short of the floor classifies flat and escalates. This
# is the case a naive "did the counter change at all" predicate would excuse,
# and the 2026-08-10 socket wedge was exactly that - moving, but not working.
test_measurable_but_below_floor_is_flat() {
  local rec v used
  rec=$(new_record below-floor); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  # Floor of 60000 ticks/min (1000 ticks/s - ten cores' worth at the typical
  # 100 Hz tick rate) over the ~4s matured window is ~4000 ticks; one spinning
  # process cannot reach that here, but it will certainly log some.
  FM_CPU_PROGRESS_WINDOW=3 FM_CPU_PROGRESS_MIN_TICKS_PER_MIN=60000 \
    fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  settle_window 4
  v=$(FM_CPU_PROGRESS_WINDOW=3 FM_CPU_PROGRESS_MIN_TICKS_PER_MIN=60000 \
    fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = flat ] \
    || fail "a worker below the floor returned '$v' instead of flat"
  used=$(ticks_used "$v")
  [ -n "$used" ] && [ "$used" -gt 0 ] \
    || fail "the below-floor case logged no CPU at all, so it did not test the floor: $v"
  pass "measurable CPU that falls short of the floor still classifies flat, so the floor is not a zero test"
}

test_unresolvable_worker_is_unknown() {
  local rec v
  rec=$(new_record unresolvable); rm -f "$rec"
  FAKE_PID=""
  v=$(fm_cpu_progress_check "$rec" zellij test:win)
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "a backend with no pid resolver returned '$v' instead of unknown"
  [ ! -e "$rec" ] || fail "an unresolvable worker left a stale anchor behind"
  pass "a backend that cannot resolve a worker pid returns unknown, which escalates"
}

test_vanished_process_is_unknown() {
  local rec v pid
  rec=$(new_record vanished); rm -f "$rec"
  spawn_busy; pid=$SPAWNED; FAKE_PID=$pid
  FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  FAKE_PID=""
  settle_window 4
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "a vanished worker returned '$v' instead of unknown"
  pass "a worker that vanished mid-sample returns unknown rather than a remembered verdict"
}

test_immature_window_carries_the_previous_verdict() {
  local rec v anchor_before anchor_after
  rec=$(new_record immature); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  settle_window 4
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = progressing ] || fail "setup did not reach a progressing verdict: $v"
  anchor_before=$(cat "$rec")
  # An immediate re-poll is inside the window: the verdict must carry forward
  # and the anchor must NOT be re-cut, or frequent polling would keep resetting
  # the window and no verdict would ever mature.
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  anchor_after=$(cat "$rec")
  [ "$(verdict_class "$v")" = progressing ] \
    || fail "an in-window re-poll dropped the matured verdict: $v"
  [ "$anchor_before" = "$anchor_after" ] \
    || fail "an in-window re-poll re-cut the rolling anchor"
  pass "a re-poll inside the window carries the matured verdict forward without re-cutting the anchor"
}

test_overwide_window_is_unknown() {
  local rec v
  rec=$(new_record overwide); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  settle_window 4
  # A window wider than the maximum says nothing about whether the worker moved
  # RECENTLY - the shape a watcher restart or a long gap leaves behind.
  v=$(FM_CPU_PROGRESS_WINDOW=3 FM_CPU_PROGRESS_WINDOW_MAX=1 \
    fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "an over-wide sampling window returned '$v' instead of unknown"
  pass "a sampling window too wide to describe now returns unknown and re-anchors"
}

# A backwards clock step (NTP correction, VM suspend/resume, laptop sleep)
# leaves the anchor stamped in the FUTURE. Treating that span as merely immature
# would re-serve the recorded `progressing` on every later call for as long as
# the skew lasts - a suppression built on a measurement the clock cannot
# support, and the one failure shape that degrades toward blindness.
test_backwards_clock_step_re_anchors_instead_of_carrying_progressing() {
  local rec v ts line
  rec=$(new_record clock-step); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  settle_window 4
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = progressing ] || fail "setup did not reach a progressing verdict: $v"
  # The clock stepping back an hour is indistinguishable from the anchor being
  # stamped an hour ahead of it.
  ts=$(sed -n 's/.* ts=\([0-9][0-9]*\) .*/\1/p' "$rec")
  [ -n "$ts" ] || fail "the anchor recorded no timestamp to step: $(cat "$rec")"
  line=$(sed "s/ts=$ts/ts=$(( ts + 3600 ))/" "$rec")
  printf '%s\n' "$line" > "$rec"
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "an anchor from after a backwards clock step returned '$v' instead of unknown"
  grep -q 'class=unknown' "$rec" \
    || fail "a backwards clock step did not re-anchor the record: $(cat "$rec")"
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "the re-anchored record still served a remembered verdict: $v"
  pass "an anchor stamped after a backwards clock step re-anchors and returns unknown, never a carried-forward progressing"
}

test_recycled_pid_is_not_trusted() {
  local rec v pid start line
  rec=$(new_record recycled); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win >/dev/null
  pid=$FAKE_PID
  start=$(fm_cpu_progress_starttime "$pid")
  # Same pid, different process: corrupt the recorded start time so the cached
  # pid no longer names the process that was measured.
  line=$(sed "s/start=$start/start=$(( start + 1 ))/" "$rec")
  printf '%s\n' "$line" > "$rec"
  FAKE_PID=""
  settle_window 4
  v=$(FM_CPU_PROGRESS_WINDOW=3 fm_cpu_progress_check "$rec" tmux test:win)
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "a recycled pid was trusted and returned '$v' instead of unknown"
  pass "a cached pid whose process start time no longer matches is re-resolved, never trusted"
}

test_platform_without_proc_is_unknown() {
  local rec v
  rec=$(new_record no-proc); rm -f "$rec"
  spawn_busy; FAKE_PID=$SPAWNED
  fm_cpu_progress_supported() { return 1; }
  v=$(fm_cpu_progress_check "$rec" tmux test:win)
  unset -f fm_cpu_progress_supported
  # shellcheck source=bin/fm-cpu-progress-lib.sh
  . "$ROOT/bin/fm-cpu-progress-lib.sh"
  [ "$(verdict_class "$v")" = unknown ] \
    || fail "a platform with no tick counter returned '$v' instead of unknown"
  pass "a platform with no tick-resolution counter returns unknown, keeping the pre-existing behavior"
}

test_first_sample_is_unknown
test_busy_process_is_progressing
test_hung_process_is_flat
test_barely_moving_process_is_flat_at_the_default_floor
test_measurable_but_below_floor_is_flat
test_unresolvable_worker_is_unknown
test_vanished_process_is_unknown
test_immature_window_carries_the_previous_verdict
test_overwide_window_is_unknown
test_backwards_clock_step_re_anchors_instead_of_carrying_progressing
test_recycled_pid_is_not_trusted
test_platform_without_proc_is_unknown

reap_kids
printf 'ok - fm-cpu-progress: all cases passed\n'
