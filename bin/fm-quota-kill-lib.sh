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
# With --agent-episode the match must clear TWO further requirements, because a
# step log is read to explain why a step ended:
#
#   1. It must belong to the FINAL agent episode: no "started pid=" line may
#      follow it. A step log can hold several episodes, and a kill the pipeline
#      already retried past is not why the step ended the way it did.
#   2. The first non-blank line after it must be the harness's OWN exit line
#      ("exited pid=<digits> error="). The vendor sentence is text, so an agent
#      that QUOTES it - reviewing this very feature, say - writes the same bytes
#      the vendor does. Only the harness writes the exit line, so requiring it
#      adjacent separates the vendor speaking from an agent quoting the vendor.
#      Lines that are empty once surrounding whitespace and double quotes are
#      stripped are skipped, because `no-mistakes axi logs` renders the log as
#      TOON, which blanks to "" and quotes some lines; the raw log file and that
#      rendering are both real inputs.
#
# Requirement 2 is deliberately NOT applied without the flag. A pane capture of a
# worker sitting on a live usage-limit dialog has no exit line by definition -
# the agent has not exited, which is the entire point of waking a supervisor for
# it - so adding adjacency there would blind the blocked-worker path. Pane text
# has no episode structure either, so it is scanned without the flag.
fm_quota_kill_scan() {  # [--agent-episode]
  local episode=0
  [ "${1:-}" = --agent-episode ] && episode=1
  awk -v episode="$episode" '
    function commit() { win = pend_win; ev = pend_ev; hit = pend_hit; pending = 0 }
    /started pid=/ { laststart = NR }
    {
      # Resolve a match still awaiting its adjacent exit line BEFORE looking for
      # a new one, so a second vendor line correctly rejects the first.
      if (pending) {
        probe = $0
        gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", probe)
        if (probe != "") {
          if (match($0, /exited pid=[0-9]+ error=/)) commit(); else pending = 0
        }
      }
      if (match($0, /You.?.?.?ve hit your session limit/)) {
        pend_win = "session"; pend_ev = substr($0, RSTART); pend_hit = NR; pending = 1
      } else if (match($0, /You.?.?.?ve reached your [A-Za-z0-9]+([.][0-9]+|[ -][A-Za-z0-9]+)* limit\./) && index($0, "/usage-credits") > 0) {
        # The action link is required as a second anchor: "reached your X limit"
        # alone is ordinary enough prose that a review agent quoting a diff could
        # produce it, and a false quota verdict would excuse a real failure.
        #
        # The name bound admits a dot only between digits, so a version like
        # "Haiku 4.5" is a name while a sentence end is not. A freely dotted name
        # would let ordinary prose ("...reached your quota. See the docs. Then
        # run /usage-credits to check your limit.") satisfy both anchors at once.
        m = substr($0, RSTART, RLENGTH)
        sub(/^You.?.?.?ve reached your /, "", m)
        sub(/ limit\.$/, "", m)
        pend_win = "model:" m; pend_ev = substr($0, RSTART); pend_hit = NR; pending = 1
      }
      if (pending && !episode) commit()
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
