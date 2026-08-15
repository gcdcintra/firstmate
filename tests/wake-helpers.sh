#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites. The fake tmux surfaces here encode
# watcher/daemon/composer behavior, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm-wake-drain.sh now calls fm-guard.sh to assert watcher liveness on every
# drain. fm-guard.sh's first check warns when the firstmate PRIMARY checkout
# (FM_ROOT) sits on a feature branch; with no override FM_ROOT resolves to the
# test runner's own checkout, which during validation is on a feature branch, so
# each drain would emit a spurious worktree-tangle banner. Point the tangle check
# at a fresh non-git dir to keep it inert across these suites - the same trick the
# direct fm-guard.sh tests use. A per-call FM_ROOT_OVERRIDE still wins where a
# suite sets its own (e.g. the watcher-lock guard-banner cases).
if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-wake-tangle-root)"
  export FM_ROOT_OVERRIDE
fi

# Wedge-alarm notifier recorder (safety seam). The away-mode wedge alarm fires a
# real OS-level desktop notification by default. Point its FM_WEDGE_ALARM_EXEC
# seam at a recorder for every
# daemon/wake suite, so no test - present or future - can post a real macOS,
# herdr, or command: notification: it is impossible to forget, because sourcing this harness
# installs it. The recorder is an on-disk script (a real daemon a test spawns
# inherits the path and records too). It logs "<channel>\t<summary>" to
# $FM_WEDGE_ALARM_LOG, which a test sets to its own file to assert on; unset means
# /dev/null. FM_WEDGE_ALARM_FAIL=<channel> makes the recorder exit non-zero for
# that channel, to exercise graceful degradation. Suites that do not source this
# harness still cannot fire a real notification: the daemon defaults the seam to
# "discard" whenever it is sourced (its library-mode guard).
# Created with mktemp directly rather than fm_test_tmproot, because this file is
# sourced at top level and the recorder path is needed here, not echoed. Register
# it through the shared registry; tests/lib.sh owns the trap.
_fm_wedge_rec_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-wedge-rec.XXXXXX")
fm_test_cleanup_register "$_fm_wedge_rec_dir"
cat > "$_fm_wedge_rec_dir/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
case " ${FM_WEDGE_ALARM_FAIL:-} " in *" ${1:-} "*) exit 1 ;; esac
exit 0
REC
chmod +x "$_fm_wedge_rec_dir/rec"
export FM_WEDGE_ALARM_EXEC="$_fm_wedge_rec_dir/rec"

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
  fi
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
    # Opt-in animated footer (FM_FAKE_TMUX_CHURN_FILE names a counter file). A
    # crew idling at its prompt still renders a live footer - Claude rotates a
    # spinner word and ticks an elapsed-seconds counter - so its pane hash
    # changes with no crew activity at all. Each rendered word repeats
    # FM_FAKE_TMUX_CHURN_REPEAT captures so consecutive polls still match often
    # enough to reach the watcher's >=2 stable-hash stale threshold, which is
    # what a real footer does at a 15s poll. Off unless a test asks for it.
    if [ -n "${FM_FAKE_TMUX_CHURN_FILE:-}" ]; then
      n=$(cat "$FM_FAKE_TMUX_CHURN_FILE" 2>/dev/null || echo 0)
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      printf 'spinner %s - 1 shell still running\n' $(( n / ${FM_FAKE_TMUX_CHURN_REPEAT:-3} ))
      printf '%s\n' $(( n + 1 )) > "$FM_FAKE_TMUX_CHURN_FILE"
    fi
  fi
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in
    *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
  esac
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# Install a hermetic fake fm-crew-state.sh into <fakebin> and echo its path. The
# watcher's absorb-only-when-provably-working triage calls this (via
# FM_CREW_STATE_BIN) to read a crew's current state on no-verb signal and stale
# paths; the fake returns a canned "state: <s> · source: <src> · <detail>"
# verdict line so a test can fix the provably-working decision without a real
# worktree or no-mistakes.
# A per-id override FM_FAKE_CREW_STATE_<sanitized-id> wins; otherwise the shared
# FM_FAKE_CREW_STATE; otherwise an unknown verdict (NOT provably working), the
# safe default so a test that forgets to set one surfaces rather than absorbs.
make_fake_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin/fm-crew-state.sh"
}

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || exit 1
    _print=0
    # Return cursor_y when the format asks for it (pane_input_pending).
    for _a in "$@"; do
      case "$_a" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;; esac
      [ "$_a" = "-p" ] && _print=1
    done
    [ "$_print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    # Honor a single-line band capture (-S N -E M, both non-negative) for the
    # composer reader's non-bordered compatibility fallback; otherwise (e.g. its
    # structural full-pane scan or fm_pane_is_busy's "-S -40" tail) return the whole capture. -e is accepted and
    # ignored: this fake emits plain text, which the dim-stripper passes through.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) _S="${2:-}"; shift 2; continue ;;
        -E) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && {
          printf '%s\n' "$1" >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
          # Reflect sent text into capture so pane_input_pending sees it as
          # pending input (text in the composer).
          [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && printf '%s\n' "$1" >> "$FM_FAKE_TMUX_CAPTURE"
        } ;;
        Enter)
          # Optionally swallow Enter (file-based flag) to test the retry path.
          if [ -n "${FM_FAKE_TMUX_SWALLOW_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_SWALLOW_FILE" ]; then
            rm -f "$FM_FAKE_TMUX_SWALLOW_FILE"
          else
            printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
            # Enter submits: clear the last line (the typed text) from the
            # capture, simulating the composer being cleared on submit.
            if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$FM_FAKE_TMUX_CAPTURE" ]; then
              _tmp=$(mktemp 2>/dev/null) || _tmp="${FM_FAKE_TMUX_CAPTURE}.tmp"
              sed '$d' "$FM_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$FM_FAKE_TMUX_CAPTURE"
              rm -f "$_tmp" 2>/dev/null
            fi
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
write_composer() {
  text=$1
  width=$((${#text} + 4))
  border=
  i=0
  while [ "$i" -lt "$width" ]; do
    border="${border}─"
    i=$((i + 1))
  done
  printf '╭%s╮\n│ > %s │\n╰%s╯\n' "$border" "$text" "$border" > "$COMPOSER"
}
case "${1:-}" in
  display-message)
    print=0
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    for a in "$@"; do [ "$a" = "-p" ] && print=1; done
    [ "$print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        write_composer ""
      fi
    elif [ "$lit" = 1 ]; then
      [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      write_composer "$text"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# Terminate a child THIS shell owns and reap it, without ever blocking forever.
#
# The escalation below is load-bearing, not defensive tidiness. A watcher whose
# TERM handler never runs survives the single SIGTERM these helpers send, and
# that is not hypothetical: PR 10's job log caught bin/fm-watch.sh emitting
# "trap: line 2: unexpected EOF while looking for matching ')'", so its
# `trap 'exit 1' HUP INT TERM` body failed to parse and the process simply
# carried on. A bare `wait` on such a pid never returns.
#
# The cost of that is a whole CI lane, not one red test. bin/fm-test-run.sh
# streams every suite as `bash "$script" 2>&1 | tee "$out"`, so a suite blocked
# here stops mid-run still holding that pipe, and the job burns its entire
# timeout-minutes cap producing NO verdict at all. PR 10 died exactly there,
# after 28 of fm-watch-triage's 48 assertions, and was cancelled 15 minutes
# later with an orphaned tee still open.
#
# SIGTERM is therefore escalated to SIGKILL after a bounded grace, so `wait`
# only ever runs against a pid that is already dying. SIGKILL cannot be trapped,
# which is what makes the bound hold whatever the child's own handlers do, or
# fail to do. Kills are by exact pid, never by pattern: the process table is
# shared with every other worker on the machine.
#
# The grace must EXCEED the child's poll interval. bin/fm-watch.sh waits in
# `sleep "$POLL"` as a foreground child, and bash defers a trapped signal until
# that child finishes, so a watcher's TERM latency is bounded below by its poll.
# A grace that expired first would SIGKILL a HEALTHY watcher and skip its EXIT
# trap (watcher_cleanup), leaving .watch.lock unreleased inside the very suites
# that assert lock behavior. The default below clears the FM_POLL=5 these suites
# use by a wide margin; a caller running a watcher on a longer poll must pass a
# larger grace explicitly. Raising it costs nothing on a healthy stop: the loop
# exits as soon as the child is gone.
fm_wake_terminate() {
  local pid=$1 grace=${2:-150} i=0
  kill "$pid" 2>/dev/null || true
  while [ "$i" -lt "$grace" ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  fm_wake_terminate "$pid"
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
