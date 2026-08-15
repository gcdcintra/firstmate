#!/usr/bin/env bash
# fm-quota-advice.sh - read-only quota report for the moment before a validation
# run starts.
#
# Usage: bin/fm-quota-advice.sh
#
# WHY THIS EXISTS, and what it deliberately does not do.
#
# Firstmate already reads quota-axi at dispatch intake, to pick among a matched
# crew-dispatch profile array. Nothing reads it before starting a VALIDATION run,
# which is the expensive operation and the only one whose death can strand a
# branch in the pipeline's custody (docs/verification/nm-custody-deadlock.md).
#
# The fact that keeps being read wrong is that "quota is back" is not one
# question. An account window, a weekly window, and a per-model window each bound
# the work independently, the validation pipeline agent draws on whichever model
# it resolves rather than the crewmate's, and a reset session window can sit
# above a per-model window that is flat at zero - in which case no validation is
# possible at all while every other signal says there is room.
#
# So this prints every window, names the one that binds, and states the single
# derived fact that is not a judgement call: whether any window is exhausted. It
# invents no thresholds, recommends no fleet size, and ALWAYS exits 0. It cannot
# refuse a spawn and must never be turned into something that can: firstmate owns
# the dispatch decision under AGENTS.md section 7, and a script that quietly
# shrank the fleet would be answering a question the captain already answered.
#
# Exiting 0 is only half of that promise; the other half is answering at all.
# Every quota-axi call here is bounded through bin/fm-quota-axi-lib.sh, and a host
# with no way to bound one reports unavailable instead of reading it loose. This
# runs immediately before a validation dispatch, so a stalled provider endpoint
# would otherwise hang the very moment the report exists to keep moving.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

unavailable() {
  printf 'quota-advice: unavailable - %s\n' "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || unavailable "jq is not installed"
# Checked before the version probe, because that probe is itself a bounded call:
# without this the unboundable host would be reported as a missing or under-floor
# quota-axi, which is a false reason for a binary that is present and current.
fm_quota_axi_can_bound \
  || unavailable "no timeout, gtimeout or perl on PATH to bound the read (bin/fm-quota-axi-lib.sh owns the ladder)"
fm_quota_axi_compatible 10 \
  || unavailable "quota-axi is missing or older than $FM_QUOTA_AXI_MIN (bin/fm-quota-axi-lib.sh owns the floor)"

RAW=$(fm_quota_axi_run "${FM_QUOTA_ADVICE_TIMEOUT:-20}" --json) || RAW=
[ -n "$RAW" ] || unavailable "quota-axi returned nothing"
printf '%s' "$RAW" | jq -e . >/dev/null 2>&1 || unavailable "quota-axi output is not valid JSON"

# Valid JSON is not yet an answer. An error object, or a providers array that is
# empty because the account is unauthenticated or a provider probe failed, parses
# fine and would render as "no window is exhausted" - a healthy account is the
# one thing an unreadable one must never be reported as. The renderer below walks
# the shape with `[]?`, which yields nothing rather than failing, so the absence
# has to be caught here instead.
printf '%s' "$RAW" | jq -e '[.providers[]?.windows[]?] | length > 0' >/dev/null 2>&1 \
  || unavailable "quota-axi output carried no provider/window shape (unauthenticated account, or a provider probe failed)"

# One jq pass renders the whole report. Every number and label is quota-axi's
# own; the only thing computed here is which windows read as exhausted, which is
# a plain zero test rather than a policy threshold.
printf '%s' "$RAW" | jq -r '
  def pct: if (.percentRemaining | type) == "number" then .percentRemaining else null end;
  def exhausted: (pct != null and pct <= 0);
  [ .providers[]? as $p
    | $p.windows[]?
    | select(exhausted)
    | "\($p.provider):\(.id)"
  ] as $dead
  | (if ($dead | length) > 0 then
       "quota-advice: exhausted - \($dead | join(", ")); a validation run drawing on one of those dies immediately"
     else
       "quota-advice: no window is exhausted"
     end),
    ( .providers[]?
      | . as $p
      | ( [ $p.quotaSemantics.effectiveAvailability[]?
            | "effective: \($p.provider) \(.scope) \(.effectivePercentRemaining // "?")% remaining"
              + (if ((.limitingWindowIds // []) | length) > 0
                 then " (bound by \((.limitingWindowIds // []) | join(", ")))" else "" end)
          ][]
        ),
        ( [ $p.windows[]?
            | "window: \($p.provider) \(.id) \(.percentRemaining // "?")% remaining"
              + (if .resetsAt then ", resets \(.resetsAt)" else "" end)
              + (if .pace.status then ", pace \(.pace.status)" else "" end)
          ][]
        )
    ),
    "note: the validation pipeline agent resolves its own model, so its window is not necessarily the one a crewmate draws on.",
    "note: advisory only - firstmate owns the dispatch decision; this reports quota and never withholds a spawn."
' 2>/dev/null || unavailable "quota-axi output did not carry the expected provider/window shape"

exit 0
