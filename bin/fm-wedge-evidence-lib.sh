#!/usr/bin/env bash
# fm-wedge-evidence-lib.sh - the ONE owner of the ORDER in which firstmate's
# wedge alarm consults evidence, and of exactly what each kind of evidence is
# allowed to buy.
#
# Why this exists: the alarm used to consult a single signal - the CPU counter
# of the worker's own pane process - while three better ones sat unread. On
# 2026-08-15 that produced escalations against workers whose harness
# authoritatively reported busy, whose declared wait named what it was waiting
# on, and whose attributed pipeline run was demonstrably advancing, because the
# one signal it did read was measured on a process that is CORRECT to be idle
# for most of a ship task's life. Retuning that signal cannot fix a wrong
# subject; consulting the evidence that already exists, in order of authority,
# can.
#
# THE ORDER, and what each tier covers. The tiers do not cover the same
# subject, which is the whole reason the order matters:
#
#   1. the harness's own busy verdict            subject: the worker's turn
#      Owned by bin/fm-busy-lib.sh and consulted before this library is ever
#      reached: an exact busy verdict exempts a pane from staleness outright.
#      It is bounded rather than absolute (FM_BUSY_TURN_MAX_SECS) because a hung
#      agent can still hold its hook state, so this library never re-litigates
#      it - it NAMES it in every escalation instead, so an alarm that overrode
#      an authoritative busy verdict says so rather than leaving a supervisor to
#      rediscover it.
#   2. a declared wait (paused:/captain-held:)   subject: the worker's CLAIM
#      Moves the pane to the long recheck cadence instead of the wedge cadence.
#      It is a claim, not a measurement, and on this path it is a claim the
#      harness contradicts - the worker says it is waiting while holding a turn
#      open past its bound - so it buys a longer cadence and never silence.
#      The caller decides whether the declaration is ELIGIBLE at all
#      (<declared-wait-eligible>), because the watcher's own pause_state_class
#      may already have reconciled that same line away against authoritative
#      crew state. Re-reading the raw status line here and reversing that
#      decision would put a superseded declaration back in charge of the
#      cadence, which is the run-step precedence rule in bin/fm-crew-state.sh
#      turned inside out.
#   3. the attributed pipeline run's own clock   subject: the PIPELINE's agent
#      Read through bin/fm-crew-state.sh's --pipeline-activity mode, which
#      reuses that file's branch and code-identity attribution so a sibling
#      crew's live run can never be credited here. `active` defers; `parked`
#      deliberately does NOT, because a parked run is waiting for this worker,
#      which makes a quiet worker the fault rather than an explanation for one.
#   4. the worker process's own CPU counter      subject: the worker process
#      Last resort, unchanged from bin/fm-cpu-progress-lib.sh, and still offered
#      only on the busy-turn path.
#
# THE SAFETY RULES, which are what keep this from becoming a quieter watcher
# that stops looking - a worse defect than the false alarms it removes:
#   - No tier ever clears the escalation ladder. `.wedge-escalations-<key>`
#     keeps counting through every deferral and every long-cadence recheck, so
#     FM_WEDGE_DEMAND_INSPECT_COUNT still arrives and still forces a real look.
#     That rule is the only thing that caught the 2026-08-15 delegation wedge -
#     a worker blocked on a helper process for over two hours while every one of
#     the signals above read healthy - so nothing here may weaken it.
#   - ONE deferral episode per pane, shared by every tier, with a per-tier cap
#     measured against that single epoch. Tiers therefore cannot be chained into
#     a longer silence than the longest single cap, and a spent episode disables
#     every soft tier at once, the declared wait included.
#   - Every unmeasurable case earns nothing. A missing CLI, a timeout, coarse
#     attribution, an unreadable table, or a corrupt episode record all escalate
#     exactly as they did before this library existed.
#
# WHAT THIS STILL CANNOT SEE. Stated rather than implied, because each of these
# is a shape that reads healthy here:
#   - A worker blocked on a helper process while its pipeline advances. Tier 3
#     credits the pipeline, which really is progressing; the worker is invisible
#     behind the helper. It is caught only by the ladder, at
#     FM_WEDGE_PIPELINE_MAX_DEFER_SECS plus FM_WEDGE_DEMAND_INSPECT_COUNT
#     ordinary escalations, which is why that cap is deliberately half the CPU
#     one rather than matched to it.
#   - A wedge that keeps burning CPU. Tier 4 cannot tell a retry loop from work;
#     its cap and its escalation wording own that residual.
#   - A worker whose declared wait is inaccurate. Tier 2 believes the claim for
#     one long window; the ladder ends it.
#   - A harness that never produces an exact busy verdict - Codex and standalone
#     Kimi - reaches tiers 2 and 3 but never tier 4, because tier 4 stays gated
#     on the busy-turn path. That gap belongs to the busy-state contract in
#     bin/fm-busy-lib.sh (backlog fm-wedge-defer-uncovered-harnesses).
#   - A pipeline read at most FM_WEDGE_PIPELINE_SAMPLE_SECS stale, because the
#     read is throttled per pane; a run that stops advancing keeps its credit
#     for at most one sample interval.
#
# Sourcing: set -u and set -e safe. Requires bin/fm-classify-lib.sh (for
# last_status_line, status_is_paused_or_captain_held, FM_CREW_STATE_BIN and
# FM_PAUSE_RESURFACE_SECS_DEFAULT) and bin/fm-wake-lib.sh (for fm_path_age)
# already sourced.

# Per-tier caps, all measured against the pane's ONE shared deferral episode.
#
# The pipeline cap is deliberately half the CPU one. Tier 3 is evidence about
# the pipeline's process, not the worker's, so it says the TASK is progressing
# and cannot say the worker is; tier 4 is measured on the worker itself. A tier
# that covers a different subject than the alarm buys less time, and this is
# the number that decides when the delegation shape reaches deep inspection.
FM_WEDGE_PIPELINE_MAX_DEFER_SECS=${FM_WEDGE_PIPELINE_MAX_DEFER_SECS:-3600}
# A declared wait is a claim the harness contradicts on this path, so it buys
# the same hour and no more.
FM_WEDGE_DECLARED_WAIT_MAX_DEFER_SECS=${FM_WEDGE_DECLARED_WAIT_MAX_DEFER_SECS:-3600}
# The worker-CPU cap keeps its established name and value; bin/fm-watch.sh's
# header and docs/configuration.md own the operator-facing statement of it.
FM_WEDGE_CPU_MAX_DEFER_SECS=${FM_CPU_PROGRESS_MAX_DEFER_SECS:-7200}
# The cadence a declared wait moves the pane onto: the same long recheck window
# an idle declared wait already uses, so a worker gets one answer to the same
# declaration whether or not it happens to be holding a turn open.
FM_WEDGE_DECLARED_WAIT_CADENCE=${FM_PAUSE_RESURFACE_SECS:-${FM_PAUSE_RESURFACE_SECS_DEFAULT:-3600}}
# Shortest interval between two pipeline reads for one pane. The read is a
# bounded CLI call, and an aging pane is polled every FM_POLL seconds, so an
# unthrottled read would run it several times a minute for hours.
FM_WEDGE_PIPELINE_SAMPLE_SECS=${FM_WEDGE_PIPELINE_SAMPLE_SECS:-${FM_STALE_ESCALATE_SECS:-240}}
# Longest declared-wait status line quoted back in an escalation reason.
FM_WEDGE_DECLARED_WAIT_NOTE_MAX=${FM_WEDGE_DECLARED_WAIT_NOTE_MAX:-160}

# fm_wedge_pipeline_activity: the throttled read of tier 3, through
# bin/fm-crew-state.sh's --pipeline-activity mode. Prints that mode's
# "<class> <detail>" line. <cache-file> holds the last answer and its epoch so
# repeated polls of one aging pane reuse it; a reader that fails is cached too,
# so a broken or absent CLI is not re-invoked every poll.
fm_wedge_pipeline_activity() {  # <task> <cache-file>
  local task=$1 cache=$2 bin out cached
  if [ -f "$cache" ] && [ "$(fm_path_age "$cache")" -lt "$FM_WEDGE_PIPELINE_SAMPLE_SECS" ]; then
    IFS= read -r cached < "$cache" 2>/dev/null || cached=
    case "$cached" in
      active\ *|quiet\ *|parked\ *|none\ *|unknown\ *) printf '%s' "$cached"; return 0 ;;
    esac
  fi
  bin=${FM_CREW_STATE_BIN:-}
  if [ -z "$task" ] || [ -z "$bin" ] || [ ! -x "$bin" ]; then
    printf 'unknown no pipeline-activity reader is available for this endpoint'
    return 0
  fi
  out=$("$bin" "$task" --pipeline-activity 2>/dev/null) || out=
  out=${out%%$'\n'*}
  case "$out" in
    active\ *|quiet\ *|parked\ *|none\ *|unknown\ *) : ;;
    *) out='unknown the pipeline-activity read returned nothing usable' ;;
  esac
  printf '%s\n' "$out" > "$cache" 2>/dev/null || true
  printf '%s' "$out"
}

# fm_wedge_declared_wait: tier 2's cheap read. 0 and the (trimmed) declaring
# status line when the worker declared an external wait or a captain hold.
fm_wedge_declared_wait() {  # <state-dir> <task>
  local last
  [ -n "$2" ] || return 1
  last=$(last_status_line "$1/$2.status")
  status_is_paused_or_captain_held "$last" || return 1
  if [ "${#last}" -gt "$FM_WEDGE_DECLARED_WAIT_NOTE_MAX" ]; then
    last="${last:0:$FM_WEDGE_DECLARED_WAIT_NOTE_MAX}..."
  fi
  printf '%s' "$last"
}

# fm_wedge_evidence: the ordered decision. Called by bin/fm-watch.sh's
# wedge_timer_check once a pane's wedge timer has reached the ordinary
# escalation threshold, and never before, so the pipeline read costs nothing on
# a healthy fleet.
#
# Prints three TAB-separated fields, "<decision>\t<tier>\t<evidence>":
#   defer     hold silently; the caller opens or keeps the pane's one deferral
#             episode. <tier> names which evidence held it back.
#   recheck   a declared wait has reached its long cadence: surface it as a
#             recheck rather than a wedge, and count it on the ladder.
#   escalate  nothing credits this pane; escalate as a possible wedge.
# <evidence> is the full ordered sentence, and every decision that reaches a
# wake carries it, so an alarm a supervisor must dismiss can be dismissed by
# reading it rather than by spending a turn re-deriving the same four reads.
#
# <busy-path> is 1 ONLY where the pane holds an exact busy verdict with no
# completed turn - the single state in which a worker cannot speak for itself
# and the only one where tier 4 may defer. It is an explicit argument rather
# than something inferred from the label, and it defaults to 0, so a future
# call site that forgets it escalates rather than silently deferring.
# <deferred-for> is 0 when no episode is open. <budget-usable> is 0 when the
# episode record was unreadable or its clock impossible; a corrupt record must
# never hand a pane a fresh window, so it denies every tier at once.
# <declared-wait-eligible> is 1 only where the caller has NOT already reconciled
# the pane's declared wait against authoritative crew state, and defaults to 0
# for the same reason <busy-path> does: a call site that forgets it escalates.
fm_wedge_evidence() {  # <state-dir> <task> <busy-verdict> <busy-path> <cpu-class> <cpu-detail> <deferred-for> <budget-usable> <budget-note> <age> <pipeline-cache>
  local state=$1 task=$2 busy_verdict=$3 busy_path=${4:-0} cpu_class=$5 cpu_detail=$6
  local deferred_for=$7 budget_usable=$8 budget_note=$9 age=${10} cache=${11}
  local declared_eligible=${12:-0}
  local declared='' has_declared=0 declared_credited=0
  local pipeline pclass pdetail decision tier
  local harness_clause declared_clause cpu_clause spent_note evidence busy_source

  if [ "$declared_eligible" -eq 1 ]; then
    declared=$(fm_wedge_declared_wait "$state" "$task") && has_declared=1 || has_declared=0
  fi

  # Tier 2 first, because it decides the CADENCE and costs one status-file read.
  # Deferring here without touching tier 3 is what keeps a long declared wait
  # from running a bounded CLI call on every poll for its whole duration.
  if [ "$has_declared" -eq 1 ] && [ "$budget_usable" -eq 1 ] \
     && [ "$deferred_for" -lt "$FM_WEDGE_DECLARED_WAIT_MAX_DEFER_SECS" ]; then
    declared_credited=1
    if [ "$age" -lt "$FM_WEDGE_DECLARED_WAIT_CADENCE" ]; then
      printf 'defer\tdeclared-wait\t%s' \
        "the worker declared a wait, so this pane is on the ${FM_WEDGE_DECLARED_WAIT_CADENCE}s recheck cadence rather than the wedge cadence ($declared)"
      return 0
    fi
  fi

  pipeline=$(fm_wedge_pipeline_activity "$task" "$cache")
  pclass=${pipeline%% *}
  pdetail=${pipeline#* }

  if [ "$declared_credited" -eq 1 ]; then
    decision=recheck
    tier='declared-wait'
  elif [ "$budget_usable" -eq 1 ] && [ "$pclass" = active ] \
       && [ "$deferred_for" -lt "$FM_WEDGE_PIPELINE_MAX_DEFER_SECS" ] \
       && [ "$age" -lt "$FM_WEDGE_PIPELINE_MAX_DEFER_SECS" ]; then
    decision=defer
    tier=pipeline
  elif [ "$busy_path" -eq 1 ] && [ "$cpu_class" = progressing ] && [ "$budget_usable" -eq 1 ] \
       && [ "$deferred_for" -lt "$FM_WEDGE_CPU_MAX_DEFER_SECS" ] \
       && [ "$age" -lt "$FM_WEDGE_CPU_MAX_DEFER_SECS" ]; then
    decision=defer
    tier=cpu
  else
    decision=escalate
    tier=none
  fi

  if [ "$decision" = defer ]; then
    case "$tier" in
      pipeline) printf 'defer\tpipeline\t%s' "$pdetail" ;;
      cpu)      printf 'defer\tcpu\t%s' "$cpu_detail" ;;
    esac
    return 0
  fi

  # Compose the ordered evidence sentence for everything that reaches a wake.
  busy_source=${busy_verdict#* }
  [ -n "$busy_source" ] || busy_source=unknown
  if [ "$busy_path" -eq 1 ]; then
    harness_clause="the harness still reports this turn busy ($busy_source), but a busy turn that completes nothing has passed its bound, so that verdict alone no longer clears this pane"
  else
    harness_clause="this pane holds no exact busy verdict (${busy_verdict:-unknown}), so a CPU reading never defers here - the reading alone cannot tell a working agent from one stopped at its prompt"
  fi

  declared_clause=
  if [ "$has_declared" -eq 1 ]; then
    if [ "$declared_credited" -eq 1 ]; then
      declared_clause="the worker declared a wait ($declared)"
    else
      declared_clause="the worker declared a wait ($declared), but this pane's ${FM_WEDGE_DECLARED_WAIT_MAX_DEFER_SECS}s recheck allowance is spent, so the declaration no longer lengthens its cadence"
    fi
  fi

  spent_note=$budget_note
  if [ -z "$spent_note" ] && [ "$deferred_for" -gt 0 ]; then
    # The episode epoch records when suppression OPENED and is never refreshed,
    # so report it as exactly that: a supervisor reading the twentieth
    # post-budget escalation must not be told the pane is still suppressed.
    spent_note="this deferral episode opened ${deferred_for}s ago and its suppression ended at the cap"
  fi

  cpu_clause="$cpu_detail"
  if [ "$busy_path" -eq 0 ]; then
    :
  elif [ "$cpu_class" = progressing ] && { [ "$budget_usable" -eq 0 ] || [ "$deferred_for" -ge "$FM_WEDGE_CPU_MAX_DEFER_SECS" ]; }; then
    cpu_clause="$cpu_clause, but this pane's ${FM_WEDGE_CPU_MAX_DEFER_SECS}s CPU-progress deferral budget is spent - ${spent_note:-its deferral record is unreadable} - so measured progress no longer holds it back and it escalates on the normal cadence from here; look for a retry or spin loop, not a stopped agent"
  elif [ "$cpu_class" = progressing ]; then
    cpu_clause="$cpu_clause, and CPU has kept moving for that whole span - look for a retry or spin loop, not a stopped agent"
  fi

  evidence="$harness_clause; $pdetail"
  [ -n "$declared_clause" ] && evidence="$evidence; $declared_clause"
  evidence="$evidence; $cpu_clause"
  printf '%s\t%s\t%s' "$decision" "$tier" "$evidence"
}
