# shellcheck shell=bash
# Single owner of the vendor usage-limit recognizer.
# Usage: . bin/fm-quota-kill-lib.sh
#
# A validation pipeline agent killed by the account usage limit fails its step
# with exactly the same opaque error as one that crashed:
#
#   step review failed: agent review: claude exited: exit status 1:
#
# The distinguishing evidence is one level down, in the failed step's own log,
# where the harness passes the vendor's message through verbatim. Two families
# have been observed in the field; docs/verification/quota-kill-classification.md
# holds the real runs, exact commands, and exact output.
#
# The recognizer matches ONLY those vendor sentences. It never classifies from
# the exit shape ("exit status 1", "signal: killed"), because that shape is
# byte-identical for a genuine agent failure - which is the whole reason this
# exists. Anything it does not positively recognize is reported as NOT a quota
# kill, so an unrecognized new vendor wording degrades into today's behavior (a
# plain failure) instead of excusing a real one.

# fm_quota_kill_scan: read text on stdin and recognize a vendor usage-limit
# message. On the LAST recognized sentence, print "<window><TAB><evidence>" and
# return 0; return 1 when nothing matched.
#
#   <window>   "session" for the five-hour window, or "model:<name>" naming the
#              model exactly as the vendor wrote it, so a reader can map it onto
#              quota-axi's own model window.
#   <evidence> the vendor sentence and the rest of its line, capped, because the
#              tail carries the reset hint the caller needs. Agent prose and the
#              vendor sentence can share one line - the harness streams both -
#              so the match is a substring, never a whole-line compare.
#
# With --agent-episode the match must also belong to the FINAL agent episode in
# the text: no "started pid=" line may follow it. A pipeline step log can hold
# several episodes, and only a kill in the last one is the reason the step ended
# the way it did. Text with no episode structure at all (a pane capture) is
# scanned without the flag.
fm_quota_kill_scan() {  # [--agent-episode]
  local episode=0
  [ "${1:-}" = --agent-episode ] && episode=1
  awk -v episode="$episode" '
    /started pid=/ { laststart = NR }
    {
      if (match($0, /You.?.?.?ve hit your session limit/)) {
        win = "session"; ev = substr($0, RSTART); hit = NR
      } else if (match($0, /You.?.?.?ve reached your [^.]+ limit\./) && index($0, "/usage-credits") > 0) {
        # The action link is required as a second anchor: "reached your X limit"
        # alone is ordinary enough prose that a review agent quoting a diff could
        # produce it, and a false quota verdict would excuse a real failure.
        m = substr($0, RSTART, RLENGTH)
        sub(/^You.?.?.?ve reached your /, "", m)
        sub(/ limit\.$/, "", m)
        win = "model:" m; ev = substr($0, RSTART); hit = NR
      }
    }
    END {
      if (!hit) exit 1
      if (episode && hit < laststart) exit 1
      if (length(ev) > 200) ev = substr(ev, 1, 200)
      printf "%s\t%s\n", win, ev
    }
  '
}

# fm_quota_kill_failed_step: print the first step reported `failed` in a
# `no-mistakes axi status` steps table, read on stdin. Empty when the table
# holds no failed row, which is also what a coarse or absent status yields.
fm_quota_kill_failed_step() {
  sed -n 's/^[[:space:]]*\([a-z][a-z_-]*\),[[:space:]]*"\{0,1\}failed"\{0,1\},.*/\1/p' | head -1
}

# Field accessors for one captured "<window><TAB><evidence>" record. The record
# shape is the contract this library owns; each consumer writes its own sentence
# around these two fields, because a run-step detail and a wake reason are read
# in different places and should not be forced into one wording.
fm_quota_kill_window() {  # <record>
  printf '%s' "${1%%$'\t'*}"
}

fm_quota_kill_evidence() {  # <record>
  printf '%s' "${1#*$'\t'}"
}
