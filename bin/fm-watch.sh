#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge; it surfaces once on
#                          first sighting, with a reason, while the crew's endpoint is
#                          not confirmed dead, and that first sighting is
#                          bounded by the cadence marker rather than by the pane hash
#                          (an idle harness animates its footer, so the hash alone
#                          would re-arm a first sighting every cycle). Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. A genuinely busy pane
#                          (an exact busy verdict) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (state/<id>.turn-ended, or the spawn record before any
#                          turn completes); past that bound busy_turn_over_age
#                          routes it through the same wedge timer, so it surfaces
#                          with the identical "stale: ..." reason, escalation
#                          count, and demand-deep-inspection marker, for human
#                          inspection only - never an automatic interrupt,
#                          signal, or restart of the worker or its tool process.
#                          Before any wedge escalation fires, the pane goes
#                          through the ORDERED evidence hierarchy owned by
#                          bin/fm-wedge-evidence-lib.sh - the harness's own busy
#                          verdict, then a declared wait, then the attributed
#                          pipeline run's own activity clock, then the worker
#                          process's CPU counter - and every escalation carries
#                          the whole ordered reading, so an alarm that overrode
#                          an authoritative signal names it and can be dismissed
#                          by reading it. That library owns which tier may defer,
#                          the per-tier caps read against ONE shared per-pane
#                          deferral episode, and the residual shapes none of the
#                          tiers can see. Two rules are enforced HERE rather than
#                          there: the CPU tier stays gated on the busy-turn path
#                          (a pane without an exact busy verdict may hold an
#                          agent idle at its prompt, whose animation overlaps a
#                          working reading), and the escalation ladder keeps
#                          counting through every deferral and every declared-wait
#                          recheck, so demand-deep-inspection stays reachable for
#                          a worker whose declared wait is inaccurate or whose
#                          pipeline advances without it.
#                          A declared wait below that threshold surfaces as a
#                          recheck WITHOUT the possible-wedge segment, so away
#                          mode reads it as the pause recheck it is; at the
#                          threshold it switches to the wedge form, because that
#                          segment is the only path a worker wedged behind a
#                          busy-looking pane reaches an away captain.
#                          Past a tier's cap the pane escalates on the ordinary
#                          STALE_ESCALATE_SECS cadence - reaching
#                          demand-deep-inspection like any other wedge - and
#                          the reason says the budget is spent and what the
#                          evidence still reads, until the pane goes genuinely
#                          active again and clear_wedge_tracking resets it.
#   check: <script>: <out> authenticated check output, always actionable
#   check: branch-red: <project>/<branch> ...
#                          a cloned project's DEFAULT branch settled red, with
#                          the suspect commit, the last green commit, and the
#                          failing job's step count and duration inline so a
#                          check that ran and failed is told apart from one that
#                          never started; bin/fm-branch-poll.sh owns the sweep
#   check: branch-watch-incomplete: ...
#                          that sweep could not reach every clone inside its
#                          budget, naming the projects it did not reach; the
#                          next pass resumes there, so this is a stated latency
#                          and never a silent gap
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# shellcheck source=bin/fm-push-transition-lib.sh
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# Worker-CPU progress, the one evidence source that can tell a worker inside a
# long tool-driven turn from a wedged one. Sampled on EVERY poll of an aging
# pane, so the rolling anchor is mature by the time a wedge timer first crosses
# its threshold; only a `progressing` verdict ever suppresses, and only on the
# busy-turn path.
# shellcheck source=bin/fm-cpu-progress-lib.sh
. "$SCRIPT_DIR/fm-cpu-progress-lib.sh"
# A crewmate's currently-open delegation-shaped tool calls: the signature of a
# worker blocked behind a helper of its own, which no other signal here has.
# shellcheck source=bin/fm-delegation-lib.sh
. "$SCRIPT_DIR/fm-delegation-lib.sh"
# The ORDER in which a wedge alarm consults evidence, and what each tier may
# buy. Sourced after the classifier, the CPU measure, and the delegation record
# because it reads all three.
# shellcheck source=bin/fm-wedge-evidence-lib.sh
. "$SCRIPT_DIR/fm-wedge-evidence-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
BRANCH_WATCH_INTERVAL=${FM_BRANCH_WATCH_INTERVAL:-900}  # seconds between default-branch sweeps
# The default-branch sweep must read exactly the home THIS watcher supervises.
# An ambient FM_HOME is not that home whenever a state override displaced it, so
# the three roots the sweep reads are derived from the supervised state
# directory and passed to it explicitly rather than left to its own defaults.
BRANCH_WATCH_HOME=$(dirname "$STATE")
BRANCH_WATCH_PROJECTS=${FM_PROJECTS_OVERRIDE:-$BRANCH_WATCH_HOME/projects}
BRANCH_WATCH_CONFIG=${FM_CONFIG_OVERRIDE:-$BRANCH_WATCH_HOME/config}
# The sweep's cost grows with the fleet, so it must stop starting projects while
# it still has time to exit cleanly and report what it did not reach. A sweep
# that only ever stopped by being killed here could never report anything at all.
# This is only the default the per-check budget implies: an explicit
# FM_BRANCH_WATCH_BUDGET still wins, the same way FM_BRANCH_WATCH_LIMIT does.
BRANCH_WATCH_BUDGET=25
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*) ;;
  *)
    BRANCH_WATCH_BUDGET=$((CHECK_TIMEOUT - 5))
    [ "$BRANCH_WATCH_BUDGET" -ge 5 ] || BRANCH_WATCH_BUDGET=5
    ;;
esac
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # secs without pane output before a provably-working stale escalates as a possible wedge
# Consecutive polls an endpoint must keep reporting the SAME absence verdict
# before endpoint_absence_check wakes on it. Two costs one extra poll and
# absorbs the two races that produce a one-poll false absence: a teardown
# mid-flight, and a spawn whose endpoint is recorded a moment before its agent
# starts. Still an order of magnitude faster than STALE_ESCALATE_SECS.
ENDPOINT_ABSENCE_CONFIRM_POLLS=${FM_ENDPOINT_ABSENCE_CONFIRM_POLLS:-2}
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no completed turn: once its task's
# state/<id>.turn-ended marker (or, before any turn has completed, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through the
# same STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale, so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only - never
# an automatic interrupt, signal, or restart. A completed turn touches
# turn-ended and resets the age. Set generously above any legitimate interval
# between completed turns, including long tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once.
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_busy_verdict: the task's full semantic busy verdict, "<state> <source>",
# from the one contract owner (bin/fm-busy-lib.sh). The SOURCE half matters as
# much as the state: an escalation that overrode an authoritative busy verdict
# has to name which signal it overrode, or a supervisor spends a turn
# rediscovering it. <tail40> is the same bounded capture already read for
# hashing and is consumed only by the Grok-scoped fallback inside the contract.
window_busy_verdict() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40"
  else
    fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40"
  fi
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working. Only an
# exact busy verdict returns 0: idle, unknown, and dead all return 1, so a
# converted adapter whose semantic state is missing, malformed, stale, or
# unverified is treated as not-provably-working and surfaces rather than being
# absorbed.
window_is_busy() {  # <window> <tail40>
  local verdict
  verdict=$(window_busy_verdict "$1" "$2")
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
#
# The same marker is also added on the FIRST escalation of a worker the evidence
# hierarchy vetoed as blocked inside a delegation tool call
# (FM_WEDGE_DELEGATION_BLOCK_SECS, bin/fm-delegation-lib.sh). That is an
# addition to this count rule, never a substitute: the count is what forces a
# real look when no single reading explains a pane, and it is what caught the
# 2026-08-15 delegation block before any of this existed.
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Bound on how long ANY tier of the evidence hierarchy may keep deferring ONE
# pane's wedge escalation. No tier can tell productive work from a wedge with
# the same signature - a retry loop burns CPU exactly like a working turn, and a
# healthy pipeline advances exactly the same whether or not the worker driving
# it is blocked - so deferral is capped rather than indefinite. Past its cap the
# pane escalates anyway, and the reason says which evidence stopped holding it
# back, which is the supervisor's cue to look for a loop or a blocked worker
# rather than a stopped agent.
#
# The cap is a per-pane BUDGET, not a per-window one, and it is spent once: it
# is measured both from the wedge timer's own start (so for the busy path it
# applies on top of BUSY_TURN_MAX_SECS) and from .wedge-defer-since-<key>, the
# epoch of the pane's first deferral by ANY tier. Escalating resets the wedge
# timer, so a cap read only off that timer would hand a spinning wedge a fresh
# full window after every escalation and surface it once per cap instead of once
# per STALE_ESCALATE_SECS. The deferral epoch survives that reset, so once the
# budget is spent the pane escalates on the normal cadence - and reaches
# FM_WEDGE_DEMAND_INSPECT_COUNT - until it goes genuinely active again.
# bin/fm-wedge-evidence-lib.sh owns the per-tier caps read against that one
# epoch, and why the pipeline tier's is deliberately shorter than the CPU tier's.
#
# One condition bypasses that budget entirely rather than shortening it: a
# worker that has sat inside one delegation-shaped tool call for
# FM_WEDGE_DELEGATION_BLOCK_SECS (default 900) is blocked behind a helper, and
# the pipeline and CPU readings are then measurements of other processes. That
# veto is owned by bin/fm-wedge-evidence-lib.sh and its record by
# bin/fm-delegation-lib.sh; it withholds deferral and names the shape, and it
# never interrupts, signals, or restarts a worker.

# The ONE spelling of a window's marker-key transform, used by every marker
# site in this watcher, so the key contract that fm-supervise-daemon.sh's
# _stale_key must stay in sync with is stated once.
window_key() {  # <window>
  printf '%s' "$1" | tr ':/.' '___'
}

# cpu_progress_for_window: "<class> <evidence>" for the worker process behind
# <window>, keyed by the same window key as the other watcher markers.
# bin/fm-cpu-progress-lib.sh owns the measure, the record, and the rule that
# every failure mode returns `unknown` rather than a false `progressing`.
cpu_progress_for_window() {  # <window>
  local w=$1 key
  key=$(window_key "$w")
  fm_cpu_progress_check "$STATE/.cpu-$key" "$(window_backend "$w")" "$w"
}

# A pane's wedge bookkeeping is reset as one set wherever that pane goes
# genuinely active or moves onto the declared-pause cadence, so a pane that
# resumes starts clean on all of it and no marker can outlive a reset because one
# call site listed a stale subset. The set itself is owned by
# bin/fm-classify-lib.sh's fm_wedge_markers_clear, because the away-mode daemon
# resets the same markers and the two must not drift.
# Surfacing a stale pane is NOT such a reset: those sites clear only the timer,
# deliberately keeping the escalation count and the spent deferral budget.
clear_wedge_tracking() {  # <window>
  local win=$1 key
  key=$(window_key "$win")
  fm_wedge_markers_clear "$STATE" "$key"
}

# --- endpoint absence: a killed endpoint is not a quiet worker ---------------
#
# A wedged agent and a killed one look identical to every heuristic this
# watcher had: both render a frozen pane, both hold a stable hash, and both
# read flat on the worker-CPU counter that clears a long productive turn. The
# one signal that separates them is not a heuristic at all - it is asking the
# backend whether the endpoint still holds a running agent, which is cheap and
# unambiguous.
#
# Until this check existed a killed endpoint took one of two wrong paths. If
# its capture failed it dropped silently out of the stale loop's `continue` and
# produced no wake at all; if the capture still returned bytes it aged into a
# wedge alarm worded exactly like a hung worker's, and telling the two apart
# cost a manual inspection every time. Observed 2026-08-15: a desktop-session
# collapse SIGKILLed an entire user cgroup, killing every pane on the machine
# in one instant, and supervision reported it as a run of ordinary wedges
# discovered one at a time over the following two hours.
#
# fm_backend_agent_state (bin/fm-backend.sh) owns the state vocabulary, and
# only its two CONFIDENT non-agent verdicts wake anything here - the same two
# that contract already says are the only ones licensing recovery:
#   missing - the endpoint is authoritatively absent. Covers both a killed pane
#             and a dead backend server: the tmux adapter maps tmux's own "no
#             server running on"/"can't find session" replies to missing rather
#             than to a read failure, so a server that died with its session
#             still reaches this wake instead of a blind spot.
#   dead    - the endpoint is still there but runs a bare shell where an agent
#             belongs: the agent died without reporting.
# alive, ambiguous, unreadable, and unverified never wake, and never divert a
# window from the path it would have taken before. That is what keeps a
# genuinely wedged worker with a live pane escalating exactly as it did, keeps
# an unreadable probe from inventing an absence it cannot see, and keeps a
# backend with no recovery classifier behaving as it does today. This check
# adds a signal; it removes none.
#
# Two absences are already accounted for and are logged rather than woken on:
# one after the worker reported a terminal outcome, and one under a declared
# pause or captain hold, whose own bounded recheck cadence already treats an
# exited agent as still waiting. endpoint_absence_expected owns that pair, and
# naming which of the two applied is its job because the triage log is the only
# place an absorb is ever visible. Neither is claimed: an absence this check
# declines to report stays on the path it would have taken, or absorbing it here
# would silently cancel the very cadence that made it safe to absorb.

# 0 when this window's absence is already accounted for, so reporting it as a
# fault would be wrong rather than merely noisy. Prints WHICH of the two cases
# applied: the absorb is only ever visible in the triage log, and a pause
# absorbed under the wrong cause sends the next person debugging it at the wrong
# question.
endpoint_absence_expected() {  # <window>
  local w=$1 task last
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] || return 1
  last=$(last_status_line "$STATE/$task.status")
  # The worker reported a terminal outcome: firstmate may already be tearing
  # this endpoint down, and its disappearance is the expected next step.
  if status_is_terminal_verb "$last"; then
    printf 'worker already reported a terminal outcome'
    return 0
  fi
  # A declared pause or captain hold already owns the exited-agent case on its
  # own bounded recheck cadence (pause_state_class, PAUSE_RESURFACE_SECS), and
  # deliberately treats a confidently-exited agent as still paused rather than
  # as a wedge. Claiming it here would convert a chosen long wait into a fault
  # report and change behavior this check is meant to leave alone.
  status_is_paused_or_captain_held "$last" || return 1
  printf 'declared pause or captain hold, which rechecks an exited agent on its own cadence'
}

# A trailing clause naming where a husk shell is sitting, when that is itself a
# hazard. A primary checkout is called out by name because work started there
# would not be isolated in a task worktree at all - the one thing the worktree
# contract exists to prevent - and there are two of them: this firstmate home's
# own root, and the task's recorded `project=` checkout, which is where crew
# panes are created (bin/fm-spawn.sh) and therefore the fallback actually
# observed. Any other drift off the recorded worktree is reported more plainly.
# Silent when the backend cannot resolve a cwd, or when the shell is where it
# belongs - checked first, so a task whose worktree IS its project checkout is
# never accused of the drift it does not have.
endpoint_cwd_note() {  # <window>
  local w=$1 task meta cwd worktree project
  cwd=$(fm_backend_current_path "$(window_backend "$w")" "$w" 2>/dev/null) || return 0
  [ -n "$cwd" ] || return 0
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  worktree=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- || true)
  [ -n "$worktree" ] && [ "$cwd" = "$worktree" ] && return 0
  project=$(grep '^project=' "$meta" 2>/dev/null | cut -d= -f2- || true)
  if [ "$cwd" = "$FM_ROOT" ] || { [ -n "$project" ] && [ "$cwd" = "$project" ]; }; then
    printf ', and its shell fell back to the primary checkout %s - anything started there would not be isolated in a task worktree' "$cwd"
    return 0
  fi
  [ -n "$worktree" ] &&
    printf ', and its shell is at %s rather than the task worktree %s' "$cwd" "$worktree"
  return 0
}

# Classify <window>'s endpoint and wake once per absence episode. Returns 0 ONLY
# when this window's absence has been reported, so the caller skips the wedge
# path that cannot describe it. Returns 1 when the endpoint is (or may still be)
# a working agent, and equally when the absence is one of the two already
# accounted for: an absence this check declines to report must leave the window
# on exactly the path it would have taken, because the declared-pause and
# captain-hold recheck cadence that owns that case only runs on that path.
endpoint_absence_check() {  # <window>
  local w=$1 verdict key seen prev count reason detail expected
  verdict=$(fm_backend_agent_state "$(window_backend "$w")" "$w" 2>/dev/null) || verdict=
  key=$(window_key "$w")
  case "$verdict" in
    missing|dead) ;;
    *)
      # Anything not confidently absent - working, ambiguous, unreadable, or a
      # backend with no classifier - ends any absence episode and takes the
      # unchanged path, so a relaunched worker that later goes absent wakes again.
      rm -f "$STATE/.gone-seen-$key" "$STATE/.gone-$key"
      return 1
      ;;
  esac
  seen=$(cat "$STATE/.gone-seen-$key" 2>/dev/null || true)
  prev=${seen%%:*}
  count=${seen#*:}
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$prev" = "$verdict" ]; then count=$((count + 1)); else count=1; fi
  printf '%s:%s' "$verdict" "$count" > "$STATE/.gone-seen-$key"
  [ "$count" -ge "$ENDPOINT_ABSENCE_CONFIRM_POLLS" ] || return 1
  # One wake per episode: an absent endpoint does not come back on its own, and
  # a fleet-wide kill would otherwise re-wake for every dead window every poll.
  [ "$(cat "$STATE/.gone-$key" 2>/dev/null || true)" = "$verdict" ] && return 0
  if expected=$(endpoint_absence_expected "$w"); then
    # Deliberately neither claimed nor marked delivered. Claiming it would skip
    # the pause/captain-hold cadence that is the whole reason this case is
    # absorbed, and marking it delivered would spend the episode's one wake on a
    # wake that never fired - so a status that later moves off the accounted-for
    # verb (`resolved:` is not terminal) could never wake gone. Logged on the
    # poll that confirms the verdict, so the absorb is visible once per episode
    # rather than on every poll for as long as the wait lasts.
    [ "$count" -eq "$ENDPOINT_ABSENCE_CONFIRM_POLLS" ] &&
      triage_log "absorbed gone endpoint ($verdict; $expected): $w"
    return 1
  fi
  case "$verdict" in
    missing)
      reason="gone: $w (the worker's endpoint no longer exists - it was killed, which is NOT a quiet or wedged worker and will never clear on its own; its committed branch and any running validation usually survive, so inspect what landed and relaunch rather than assuming the work is lost)"
      ;;
    *)
      detail=$(endpoint_cwd_note "$w")
      reason="gone: $w (the endpoint is still there but its agent is not - a bare shell where a worker belongs${detail}; the worker died without reporting, so its turn is lost even though anything it committed survives)"
      ;;
  esac
  fm_wake_append gone "$w" "$reason" || exit 1
  printf '%s' "$verdict" > "$STATE/.gone-$key"
  wake "$reason"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or, once
# STALE_ESCALATE_SECS have elapsed, puts the pane through the ordered evidence
# hierarchy in bin/fm-wedge-evidence-lib.sh. Shared by both places a hash can be
# absorbed this way: the plain non-terminal path, and the stale_is_terminal-
# overridden path (a captain-relevant status-log line that an active run/busy
# pane outranked).
#
# This function owns the TIMER, the LADDER, the shared deferral episode, and the
# wake wording; the evidence library owns which evidence is consulted, in what
# order, and what each tier may buy. Splitting it that way is deliberate: the
# ladder must keep counting through every deferral and every long-cadence
# recheck, and keeping that counter here means no tier can reach it.
#
# <cpu-deferral-allowed> is 1 ONLY on the busy-turn call sites, where the pane
# holds an exact busy verdict with no completed turn - the one state in which a
# worker is structurally unable to speak for itself. Everywhere else it is 0:
# those panes hold no exact busy verdict, so the measured process may be an
# agent sitting at its prompt, and an idle prompt animation reads 0.58-3.82 ticks/s
# against a 2.0 floor. Deferring on that would delay a worker that simply
# STOPPED - the shape a stale alarm catches within minutes today. The parameter
# is explicit rather than inferred from <triage-label>, and it defaults to 0, so
# a future call site that forgets it escalates rather than silently deferring.
# <busy-verdict> is the pane's full semantic verdict, carried into every
# escalation so an alarm that overrode an authoritative busy signal names it.
#
# <declared-wait-eligible> is 1 only on the busy-turn call sites. The three
# non-busy sites are reached ONLY after pause_state_class has already reconciled
# this pane's declared wait against authoritative crew state - a crew that
# appended `paused:` and then started a run reports working, and that decision
# resumes wedge tracking on purpose - so letting the evidence hierarchy re-read
# the same raw status line there would hand a superseded declaration the cadence
# back. The busy-turn sites perform no such reconciliation, which is exactly the
# gap that escalated a well-formed declared wait as a possible wedge. It
# defaults to 0 for the same reason <cpu-deferral-allowed> does.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <cpu-deferral-allowed> <busy-verdict> <declared-wait-eligible>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 cpu_deferral=${5:-0} busy_verdict=${6:-}
  local declared_eligible=${7:-0}
  local since age n reason age_phrase key task
  local cpu cpu_class cpu_detail defer_file cache_file defer_since deferred_for now
  local budget_usable budget_note verdict decision tier evidence
  # Sample on EVERY poll of an aging pane, not only when an escalation is due:
  # the rolling anchor has to be mature by the time the timer first crosses the
  # threshold, or the first escalation of every long turn would still fire with
  # no evidence. One small /proc read per poll; the backend pid resolve runs
  # only when the cached pid is absent, dead, or recycled.
  cpu=$(cpu_progress_for_window "$win")
  cpu_class=${cpu%% *}
  cpu_detail=${cpu#* }
  key=$(window_key "$win")
  task=$(window_to_task "$win" "$STATE")
  defer_file="$STATE/.wedge-defer-since-$key"
  cache_file="$STATE/.wedge-pipeline-$key"
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      now=$(date +%s)
      age=$(( now - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        # What the age measures differs by path, so the wording does too. On the
        # busy-turn path the timer starts when the turn passed BUSY_TURN_MAX_SECS
        # and pane output never resets it - a pane whose footer ticks on every
        # poll reaches here - so it counts seconds with no COMPLETED TURN. On the
        # three non-busy paths it starts when a stale hash is absorbed and runs
        # only while that hash is unchanged, so there it counts seconds with no
        # PANE OUTPUT. Claiming the pane went silent when only the turn ran long
        # would point triage at a frozen pane instead of the spin loop the rest
        # of the same sentence asks for.
        if [ "$cpu_deferral" -eq 1 ]; then
          age_phrase="no completed turn for ${age}s"
        else
          age_phrase="no pane output for ${age}s"
        fi
        # The pane's ONE deferral episode, shared by every tier. A corrupt record
        # or a backwards clock step makes the elapsed span unknowable, and an
        # unknowable span must never hand a pane a fresh window, so it denies
        # every tier at once rather than only the one that opened the episode.
        deferred_for=0
        budget_usable=1
        budget_note=
        defer_since=$(cat "$defer_file" 2>/dev/null || true)
        case "$defer_since" in
          '') ;;
          *[!0-9]*)
            budget_usable=0
            budget_note="its deferral record is unreadable" ;;
          *)
            deferred_for=$(( now - defer_since ))
            if [ "$deferred_for" -lt 0 ]; then
              budget_usable=0
              deferred_for=0
              budget_note="the clock stepped backwards since it was recorded"
            fi ;;
        esac
        verdict=$(fm_wedge_evidence "$STATE" "$task" "$busy_verdict" "$cpu_deferral" \
          "$cpu_class" "$cpu_detail" "$deferred_for" "$budget_usable" "$budget_note" \
          "$age" "$cache_file" "$declared_eligible")
        decision=${verdict%%	*}
        verdict=${verdict#*	}
        tier=${verdict%%	*}
        evidence=${verdict#*	}
        if [ "$decision" = defer ]; then
          # One triage line per deferral EPISODE, not per poll: a pane deferring
          # for the whole cap is polled hundreds of times, and logging each one
          # would push unrelated triage history past the log's size cap.
          if [ -z "$defer_since" ]; then
            printf '%s\n' "$now" > "$defer_file"
            case "$tier" in
              cpu)
                triage_log "deferred $label wedge escalation, worker CPU progressing ($age_phrase): $win - $evidence" ;;
              pipeline)
                triage_log "deferred $label wedge escalation, the attributed pipeline run is advancing ($age_phrase): $win - $evidence" ;;
              *)
                triage_log "deferred $label wedge escalation, declared wait on the long recheck cadence ($age_phrase): $win - $evidence" ;;
            esac
          fi
          return 0
        fi
        # The ladder counts every wake this path produces, recheck and escalation
        # alike, and nothing below resets it. That is what keeps
        # FM_WEDGE_DEMAND_INSPECT_COUNT reachable for a worker whose declared
        # wait is inaccurate or whose pipeline advances without it.
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        if [ "$decision" = recheck ] && [ "$n" -lt "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          # A declared wait that reached its long cadence is a recheck, not a
          # wedge, so the reason deliberately omits FM_CLASSIFY_WEDGE_REASON_SEGMENT
          # and the away-mode daemon classifies it as the ordinary pause recheck
          # it is. At the threshold it switches to the wedge form below, because
          # the daemon's force-escalation on that segment is the only path a
          # worker wedged behind a busy-looking pane reaches an away captain.
          reason="stale: $win (declared wait, recheck $n on the ${FM_WEDGE_DECLARED_WAIT_CADENCE}s cadence rather than a wedge escalation - confirm the wait still holds; $evidence)"
        else
          reason="stale: $win (${age_phrase}${FM_CLASSIFY_WEDGE_REASON_SEGMENT}$n; $evidence)"
          if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
            reason="$reason (demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
          elif [ "$tier" = delegation ]; then
            # The count rule is untouched - this is a second, independent way to
            # earn the same marker, and it never delays or replaces that one.
            # The count exists because three identical alarms mean no single
            # reading can be trusted to explain the pane; here one reading
            # already names WHY the run-step and pane state cannot explain it,
            # so waiting for two more identical alarms would only spend the
            # minutes this shape has already proven it can waste.
            reason="$reason (demand-deep-inspection: this worker is blocked inside a delegation tool call - do not re-absorb on the run-step/pane state alone)"
          fi
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff <task>'s latest completed-turn marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task turn-ended marker, the harness-neutral
# signal every verified harness's turn-end hook touches; before any turn has
# completed, ages the task's spawn record instead so a fresh task still gets a
# bound. The caller checks that the pane is busy and routes a crossed bound
# through the existing wedge_timer_check, never anything that touches the
# worker itself.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  clear_wedge_tracking "$win"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=$(window_key "$win")
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=$(window_key "$win")
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key"
  clear_wedge_tracking "$win"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=$(window_key "$win")
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# Surface a stale pane whose status log carries no captain-relevant line. A crew
# with NO declared external wait surfaces immediately on every distinct stale
# hash, unchanged.
#
# A crew whose last status line DECLARES a wait is bounded instead. The
# declaration is a claim, not proof, so the FIRST sighting still surfaces
# promptly - a live agent may really be parked at a gate it called a pause - but
# every later sighting belongs to handle_paused_stale's long cadence. The
# first-sighting identity is the presence of the .paused-resurfaced-<key>
# throttle marker, NOT the pane hash: a pane hash is not a stable identity for an
# idle harness. A crew sitting at its prompt still renders an animated footer
# (Claude rotates its spinner word and ticks an elapsed-seconds counter), so it
# mints a new hash - and, when the hash was the identity, a new "first sighting" -
# on nearly every capture. That is what re-escalated a declared wait once per
# monitoring cycle for as long as the wait lasted: each cycle's restart gap
# guaranteed at least one fresh hash. PAUSE_RESURFACE_SECS stays stated once, in
# handle_paused_stale.
surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last reason
  key=$(window_key "$win")
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    if [ -e "$STATE/.paused-resurfaced-$key" ]; then
      handle_paused_stale "$win" "$task" "$h"
    else
      reason="stale: $win (declared wait, first sighting - the worker's endpoint is not confirmed dead, so the declaration alone is not proof it is idle on purpose; check it once, then later sightings use the long pause recheck cadence)"
      fm_wake_append stale "$win" "$reason" || exit 1
      printf '%s' "$h" > "$STATE/.stale-$key"
      rm -f "$STATE/.stale-since-$key"
      : > "$STATE/.paused-$key"
      date +%s > "$STATE/.paused-rechecked-$key"
      date +%s > "$STATE/.paused-resurfaced-$key"
      wake "$reason"
    fi
  else
    fm_wake_append stale "$win" "stale: $win" || exit 1
    printf '%s' "$h" > "$STATE/.stale-$key"
    rm -f "$STATE/.stale-since-$key"
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
    wake "stale: $win"
  fi
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" "$out"; then
            fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
              || triage_log "merged PR poll retirement remains recoverable for $id"
          else
            triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
          fi
        fi
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # Default-branch watch. Every other poll here follows a task; this one follows
  # the branch those tasks merge ONTO, which nothing looked at once a pull
  # request landed, so a merge that broke it stayed invisible until a human
  # tripped over it. bin/fm-branch-poll.sh owns the sweep; it is read-only
  # against the forge and never touches a project.
  #
  # Placed after the task checks and on its own slower marker for two reasons: a
  # per-project forge query must not be paid at the per-task check rate, and a
  # merge poll - which a firstmate turn is actively waiting on - must never be
  # starved by this. Because wake() ends the process, a cycle that woke on a task
  # check simply leaves .last-branch-watch untouched and sweeps next cycle.
  if [ -d "$BRANCH_WATCH_PROJECTS" ] \
    && [ "$(age_of "$STATE/.last-branch-watch")" -ge "$BRANCH_WATCH_INTERVAL" ]; then
    touch "$STATE/.last-branch-watch"
    FM_HOME="$BRANCH_WATCH_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_PROJECTS_OVERRIDE="$BRANCH_WATCH_PROJECTS" FM_CONFIG_OVERRIDE="$BRANCH_WATCH_CONFIG" \
      FM_BRANCH_WATCH_BUDGET="${FM_BRANCH_WATCH_BUDGET:-$BRANCH_WATCH_BUDGET}" \
      run_check_capture "$SCRIPT_DIR/fm-branch-poll.sh" || exit 1
    out=$FM_CHECK_RESULT
    reason=
    bw_acks=()
    # One queue record per key the sweep emits - a project name for a red branch,
    # ":sweep" for a pass that could not reach the whole fleet. The drain
    # collapses records that share a kind and key and keeps only the newest, so a
    # single shared key would let one project's red silently replace another's -
    # and the sweep's own re-emit safety net could not recover it, because
    # acknowledging the wake already marked both verdicts delivered.
    while IFS=$(printf '\t') read -r bw_key bw_line; do
      [ -n "$bw_key" ] && [ -n "$bw_line" ] || continue
      fm_wake_append check "branch-watch:$bw_key" "check: $bw_line" || exit 1
      bw_acks+=("$bw_key")
      if [ -z "$reason" ]; then reason="check: $bw_line"; else reason="$reason ;; $bw_line"; fi
    done <<EOF
$out
EOF
    if [ "${#bw_acks[@]}" -gt 0 ]; then
      # Only now is every one of these durably queued, so only now may the sweep
      # mark them surfaced - and only THESE. A blanket acknowledgement would also
      # mark a verdict from an earlier sweep delivered when nothing ever carried
      # it, which swallows that red for good: the same expensive failure, reached
      # by acknowledging instead of by colliding keys.
      FM_HOME="$BRANCH_WATCH_HOME" FM_STATE_OVERRIDE="$STATE" \
        FM_PROJECTS_OVERRIDE="$BRANCH_WATCH_PROJECTS" FM_CONFIG_OVERRIDE="$BRANCH_WATCH_CONFIG" \
        run_check "$SCRIPT_DIR/fm-branch-poll.sh" --ack "${bw_acks[@]}"
      wake "$reason"
    fi
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=$(window_key "$w")
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    # A capture that fails is the loudest evidence an endpoint is gone, and used
    # to be the quietest: this `continue` skipped the window with no wake at all,
    # every poll, forever. Ask the backend what happened before dropping it.
    if ! tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null); then
      endpoint_absence_check "$w" || true
      continue
    fi
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(window_key "$w")
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    busy_verdict=$(window_busy_verdict "$w" "$tail40")
    if [ "${busy_verdict%% *}" = busy ]; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # A pane can hold a stable hash because its agent is gone rather than
        # stuck - a killed endpoint whose backend still returns its last frame,
        # or a husk shell left where an agent died. Both would otherwise age
        # into a wedge alarm that describes neither. Asked here, on the narrow
        # already-stale path, so a working fleet pays nothing for it.
        if endpoint_absence_check "$w"; then
          continue
        fi
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" 0 "$busy_verdict"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no declared pause.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" 0 "$busy_verdict"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" 0 "$busy_verdict"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through the same wedge timer instead of erasing it.
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          wedge_timer_check "$w" "$ssf" "busy (no completed turn)" "$ewf" 1 "$busy_verdict" 1
        else
          clear_wedge_tracking "$w"
        fi
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        wedge_timer_check "$w" "$ssf" "busy (no completed turn)" "$ewf" 1 "$busy_verdict" 1
      else
        clear_wedge_tracking "$w"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused)  handle_paused_stale "$w" "$task" "$h" ;;
          working) clear_pause_tracking "$w" ;;
          # An UNCORROBORATED declared wait keeps its bounded-cadence tracking.
          # The wait is still declared - the guard at the top of this loop owns
          # clearing once it is not - so the crew has not resumed and nothing
          # here has been decided. Dropping .paused-resurfaced-<key> at this
          # point is what re-armed a fresh first sighting on every churned hash,
          # and an idle harness churns its hash on nearly every capture.
          *)       : ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
