#!/usr/bin/env bash
# fm-cpu-progress-lib.sh - the ONE owner of firstmate's worker-CPU-progress
# contract: does the recorded worker PROCESS show CPU progress right now?
#
# Why this exists: a worker only reaches its status file BETWEEN turns, so a
# worker inside one long tool-driven turn (driving an app, taking screenshots,
# running a suite) can neither append `paused:` nor refresh its pane, and the
# watcher's pane-output wedge predicate therefore escalates it as a possible
# wedge every FM_STALE_ESCALATE_SECS. The process's own CPU counter is the
# signal that separates that worker from a wedged one, and nothing consulted it.
#
# THE SAFETY INVARIANT, and the reason this library is small:
#   `progressing` is the ONLY verdict that may SUPPRESS an escalation.
#   Every other outcome - no pid resolver for the backend, no /proc on this
#   platform, an unreadable or vanished process, a first sample with no anchor
#   yet, a sampling window too wide to trust after a watcher restart, or a
#   window that a backwards clock step (NTP correction, VM suspend/resume,
#   laptop sleep) made impossible - returns `unknown`, and `unknown` escalates
#   exactly as before this library existed. A verdict is never carried forward
#   on a measurement the clock cannot support: that is the one shape of failure
#   that would degrade toward BLINDNESS instead of NOISE.
# This library never escalates anything on its own and never touches a worker;
# it only ever answers "is this process burning CPU", and its caller decides.
#
# What it can and cannot see (bin/fm-watch.sh's header states the operational
# consequence, docs/verification/supervision.md holds the measurements):
#   - A hung agent reads flat (0 ticks) and escalates.
#   - An agent blocked on a stuck TCP send queue reads near-flat - 10 ticks
#     over 45s in the 2026-08-10 case, 0.22/s, an order of magnitude under the
#     floor - and escalates. This library must never start excusing that one.
#   - A wedge that KEEPS BURNING CPU - an internal retry or spin loop - looks
#     exactly like productive work here and is suppressed. That is why the
#     caller bounds total deferral rather than deferring forever.
#   - An agent blocked waiting on ONE long-running child shows flat own-CPU
#     until that child is reaped, so it escalates. Unchanged from before.
#   - An agent IDLE AT ITS PROMPT cannot be told apart from a working one here:
#     a prompt animation measured 0.58-3.82 ticks/s, straddling the floor. This
#     library cannot close that overlap, so the caller does not ask it to - only
#     the busy-turn path may defer, and a pane with no turn in progress
#     escalates on its ordinary cadence whatever this returns.
#   - A turn that OPENS but never closes is the residual of that arrangement: a
#     pane keeps an exact busy verdict until a turn-close event arrives, so a
#     harness whose turn end can go unreported would stay deferrable. Claude
#     covers this with its StopFailure hook; a harness without an equivalent
#     does not, and its unreported turn end is a gap in the busy contract
#     (bin/fm-busy-lib.sh), not something this measure can detect.
#
# Measure: fields 14-17 of /proc/<pid>/stat - utime+stime (the agent's own CPU)
# plus cutime+cstime (CPU of children it has REAPED). The children term is the
# cheap structural "child processes appeared and finished" signal, captured by
# the same single read rather than by a separate process-table scan; a
# tool-driven turn accumulates it continuously. Never `ps -o time`, whose
# one-second resolution reads a mostly-idle agent as perfectly flat (the
# 2026-08-10 measurement artefact that nearly justified an unsupported abort).
# These fields are USER_HZ units, fixed at 100 on Linux; nothing here needs the
# real value, because both sides of the comparison are in the same units.
#
# Sourcing: set -u and set -e safe. Requires bin/fm-backend.sh already sourced
# for fm_backend_agent_pid.

FM_CPU_PROGRESS_LIB_VERSION=v1

# Minimum CPU ticks per MINUTE the worker process must accumulate to count as
# progressing. Default 120 (2.0 ticks/s, i.e. 2% of one core).
#
# Chosen from measured populations (docs/verification/supervision.md):
#   wedged, stuck TCP send queue  0.22 ticks/s   <- must stay above this
#   long productive turns         3.1-17 ticks/s <- must stay below this
# 2.0/s sits ~9x above the wedge case and ~1.5x below the slowest productive
# turn observed. Raising it risks escalating real work; lowering it walks
# toward the socket-wedge case, which is the one this predicate must never
# excuse, so prefer noise over blindness when tuning.
FM_CPU_PROGRESS_MIN_TICKS_PER_MIN=${FM_CPU_PROGRESS_MIN_TICKS_PER_MIN:-120}

# Shortest sampling window trusted for a verdict. Too short is scheduler noise
# on a machine running several agents, builds and a UI suite at once; the
# watcher polls far more often than this, so a verdict is simply carried
# forward until the window matures.
FM_CPU_PROGRESS_WINDOW=${FM_CPU_PROGRESS_WINDOW:-45}

# Widest sampling window trusted for a verdict. A watcher restart or a long gap
# can leave an anchor arbitrarily old, and CPU that accumulated over an hour
# says nothing about whether the process moved in the last minute. Past this,
# the anchor is reset and the verdict is `unknown` - which escalates.
FM_CPU_PROGRESS_WINDOW_MAX=${FM_CPU_PROGRESS_WINDOW_MAX:-300}

# fm_cpu_progress_ticks: total CPU ticks (utime+stime+cutime+cstime) for <pid>.
# Fails when /proc is unavailable or the process is gone. The comm field can
# contain spaces and parentheses, so parse from the LAST ')' rather than by
# whitespace-splitting the whole line.
fm_cpu_progress_ticks() {  # <pid>
  local pid=$1 out
  out=$(awk '{
    n = 0
    for (i = length($0); i > 0; i--) { if (substr($0, i, 1) == ")") { n = i; break } }
    if (n == 0) exit 1
    split(substr($0, n + 2), f, " ")
    if (f[12] == "" || f[15] == "") exit 1
    print f[12] + f[13] + f[14] + f[15]
  }' "/proc/$pid/stat" 2>/dev/null) || return 1
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

# fm_cpu_progress_starttime: field 22 of /proc/<pid>/stat, the process start
# time in ticks since boot. Binds a cached pid to the exact process that was
# measured, so a recycled pid can never be read as the same worker.
fm_cpu_progress_starttime() {  # <pid>
  local pid=$1 out
  out=$(awk '{
    n = 0
    for (i = length($0); i > 0; i--) { if (substr($0, i, 1) == ")") { n = i; break } }
    if (n == 0) exit 1
    split(substr($0, n + 2), f, " ")
    if (f[20] == "") exit 1
    print f[20]
  }' "/proc/$pid/stat" 2>/dev/null) || return 1
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

# fm_cpu_progress_supported: 0 when this platform exposes the tick-resolution
# counter at all. macOS has no /proc, so every verdict there is `unknown` and
# behavior is exactly as it was before this library existed.
fm_cpu_progress_supported() {
  [ -r /proc/self/stat ]
}

# fm_cpu_progress_check: sample <record-file>'s worker and print
#   "<progressing|flat|unknown> <one-line evidence>"
# The record is a rolling anchor this function owns end to end:
#   v1 pid=<n> start=<n> ticks=<n> ts=<epoch> class=<c> delta=<n> window=<n>
# Call it on EVERY poll of a pane that is aging toward escalation: each call is
# one small file read (plus a backend pid resolve only when the cached pid is
# absent, dead, or recycled), and the anchor needs to mature before the first
# escalation is due. A call made before the window matures carries the previous
# verdict forward rather than re-anchoring, so the anchor cannot be reset to
# nothing by frequent polling.
# Always exits 0: the verdict is the output, and there is no failure the caller
# treats differently from `unknown`.
fm_cpu_progress_check() {  # <record-file> <backend> <target>
  local record=$1 backend=$2 target=$3
  local line pid start ticks ts class delta window prev_window now floor
  local cur_start cur_ticks

  if ! fm_cpu_progress_supported; then
    printf 'unknown no tick-resolution CPU counter on this platform'
    return 0
  fi

  pid=; start=; ticks=; ts=; class=unknown; delta=; window=; prev_window=
  line=$(cat "$record" 2>/dev/null || true)
  case "$line" in
    "$FM_CPU_PROGRESS_LIB_VERSION "*)
      # shellcheck disable=SC2086
      set -- $line
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          pid=*)    pid=${1#pid=} ;;
          start=*)  start=${1#start=} ;;
          ticks=*)  ticks=${1#ticks=} ;;
          ts=*)     ts=${1#ts=} ;;
          class=*)  class=${1#class=} ;;
          delta=*)  delta=${1#delta=} ;;
          window=*) prev_window=${1#window=} ;;
        esac
        shift
      done
      ;;
  esac
  case "$pid" in ''|*[!0-9]*) pid= ;; esac
  case "$start" in ''|*[!0-9]*) start= ;; esac
  case "$ticks" in ''|*[!0-9]*) ticks= ;; esac
  case "$ts" in ''|*[!0-9]*) ts= ;; esac

  # Reuse the cached pid only while it still names the SAME process; otherwise
  # ask the backend, and treat an unresolvable worker as unknown.
  if [ -n "$pid" ] && [ -n "$start" ]; then
    cur_start=$(fm_cpu_progress_starttime "$pid") || cur_start=
    [ "$cur_start" = "$start" ] || pid=
  else
    pid=
  fi
  if [ -z "$pid" ]; then
    pid=$(fm_backend_agent_pid "$backend" "$target" 2>/dev/null) || pid=
    case "$pid" in ''|*[!0-9]*) pid= ;; esac
    if [ -z "$pid" ]; then
      rm -f "$record"
      printf 'unknown could not resolve the worker process for %s' "$target"
      return 0
    fi
    start=$(fm_cpu_progress_starttime "$pid") || start=
    if [ -z "$start" ]; then
      rm -f "$record"
      printf 'unknown could not read CPU counters for process %s' "$pid"
      return 0
    fi
    ticks=; ts=
  fi

  cur_ticks=$(fm_cpu_progress_ticks "$pid") || cur_ticks=
  if [ -z "$cur_ticks" ]; then
    rm -f "$record"
    printf 'unknown could not read CPU counters for process %s' "$pid"
    return 0
  fi
  now=$(date +%s)

  # No usable anchor yet: record one and report unknown, which escalates. The
  # anchor matures over the following polls.
  if [ -z "$ticks" ] || [ -z "$ts" ]; then
    printf '%s pid=%s start=%s ticks=%s ts=%s class=unknown delta=0 window=0\n' \
      "$FM_CPU_PROGRESS_LIB_VERSION" "$pid" "$start" "$cur_ticks" "$now" > "$record"
    printf 'unknown first CPU sample of process %s, no window yet' "$pid"
    return 0
  fi

  window=$(( now - ts ))

  # An anchor stamped in the FUTURE means the host clock stepped backwards, so
  # the span between the two samples is unknown. Clamping it to 0 would make it
  # look merely immature and carry the recorded verdict forward on every later
  # call - a stale `progressing` re-served for as long as the skew lasts, which
  # is the blindness this library must never introduce. Re-anchor instead, the
  # same way an over-wide window does, and escalate.
  if [ "$window" -lt 0 ]; then
    printf '%s pid=%s start=%s ticks=%s ts=%s class=unknown delta=0 window=0\n' \
      "$FM_CPU_PROGRESS_LIB_VERSION" "$pid" "$start" "$cur_ticks" "$now" > "$record"
    printf 'unknown CPU sampling window of process %s is impossible (%ss - the clock stepped backwards), re-anchored' \
      "$pid" "$window"
    return 0
  fi

  # Window still maturing: carry the previous verdict, and its own evidence,
  # forward rather than re-anchoring - otherwise frequent polling would keep
  # resetting the anchor and no window would ever mature.
  if [ "$window" -lt "$FM_CPU_PROGRESS_WINDOW" ]; then
    case "$class" in
      progressing|flat)
        case "$delta" in ''|*[!0-9]*) delta=0 ;; esac
        case "$prev_window" in ''|*[!0-9]*) prev_window=0 ;; esac
        floor=$(( prev_window * FM_CPU_PROGRESS_MIN_TICKS_PER_MIN / 60 ))
        printf '%s process %s used %s CPU ticks in %ss (floor %s)' \
          "$class" "$pid" "$delta" "$prev_window" "$floor"
        return 0
        ;;
    esac
    printf 'unknown CPU sampling window of process %s is only %ss, under the %ss minimum' \
      "$pid" "$window" "$FM_CPU_PROGRESS_WINDOW"
    return 0
  fi

  # Window too wide to say anything about NOW (watcher restart, long gap):
  # re-anchor and report unknown, which escalates.
  if [ "$window" -gt "$FM_CPU_PROGRESS_WINDOW_MAX" ]; then
    printf '%s pid=%s start=%s ticks=%s ts=%s class=unknown delta=0 window=0\n' \
      "$FM_CPU_PROGRESS_LIB_VERSION" "$pid" "$start" "$cur_ticks" "$now" > "$record"
    printf 'unknown CPU sampling window of process %s was %ss, over the %ss maximum' \
      "$pid" "$window" "$FM_CPU_PROGRESS_WINDOW_MAX"
    return 0
  fi

  delta=$(( cur_ticks - ticks ))
  [ "$delta" -ge 0 ] || delta=0
  floor=$(( window * FM_CPU_PROGRESS_MIN_TICKS_PER_MIN / 60 ))
  # A zero floor would make every reading, including a dead-flat counter,
  # `progressing` - the exact blindness this library must never introduce. Keep
  # at least one tick required however the knobs are set.
  [ "$floor" -ge 1 ] || floor=1
  if [ "$delta" -ge "$floor" ]; then class=progressing; else class=flat; fi
  printf '%s pid=%s start=%s ticks=%s ts=%s class=%s delta=%s window=%s\n' \
    "$FM_CPU_PROGRESS_LIB_VERSION" "$pid" "$start" "$cur_ticks" "$now" "$class" "$delta" "$window" > "$record"
  printf '%s process %s used %s CPU ticks in %ss (floor %s)' \
    "$class" "$pid" "$delta" "$window" "$floor"
}
