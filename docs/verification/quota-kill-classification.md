# Usage-limit kill classification verification

Audience: maintainer verification.

This record supports `bin/fm-quota-kill-lib.sh` and its two consumers, `bin/fm-crew-state.sh` (a failed run's cause) and `bin/fm-push-transition-lib.sh` (a blocked pane's cause).
It records only the facts that must be re-established when the no-mistakes binary or the agent harness changes: where the distinguishing evidence lives, the exact vendor wordings the recognizer matches, and the proof that a genuine agent failure is still reported as a failure.

Verified 2026-08-15 against `no-mistakes version v1.46.0`, `quota-axi` schemaVersion 3, harness `claude`.

## Why the pipeline's own error cannot classify it

no-mistakes reports a pipeline agent killed by the account usage limit with the same text as one that crashed.
This is the fact the whole classifier rests on.

```
$ no-mistakes axi status --run 01KZW3F28V5XWBZCBTX7963S81
run:
  id: "01KZW3F28V5XWBZCBTX7963S81"
  branch: fm/sm-cf-nf3-settlement
  status: failed
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,5
    rebase,completed,0,1624
    review,failed,0,4049
outcome: failed
error: "step review failed: agent review: claude exited: exit status 1: "
```

Nothing in that answer separates an external, recoverable quota kill from a crash.
`axi` v1.46.0 also exposes no way to park and resume a step: its whole surface is `abort`, `logs`, `respond`, `run`, `status`, `sync`, none of which pauses a step, and `run` carries only `--intent`, `--skip` and `--yes`.
So the pipeline cannot be told to treat a quota kill as a wait, and classification has to happen a level down.

## Where the evidence does live

The failed step's own log carries the vendor's message verbatim, and `axi logs` serves it for any run id from any working directory.

```
$ no-mistakes axi logs --run 01KZW3F28V5XWBZCBTX7963S81 --step review --full
step: review
run: "01KZW3F28V5XWBZCBTX7963S81"
lines: 9 total
log[9]{line}:
  reviewing changes...
  ""
  claude started pid=95327
  ""
  You've reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model.
  "claude exited pid=95327 error=claude exited: exit status 1: "
  ""
  ""
  "error: agent review: claude exited: exit status 1: "
```

## The steps table the cause read depends on

`bin/fm-crew-state.sh` reads the failed step from the `axi status` answer it already has, so that answer must carry the steps table.
It does, in both forms this helper can hold: the `--run`-pinned read of a failed run above, and the bare read the helper actually makes.

```
$ no-mistakes axi status
run:
  id: "01M027VVSVNHGHH2HT78MDZPB1"
  branch: fm/fm-longturn-false-wedge-v2
  status: completed
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,8
    rebase,completed,0,1243
    review,completed,0,3601899
    ...
outcome: passed
```

If a later binary trims that table from the bare answer, the cause read stops firing and every failed run reports as a plain failure - the pre-existing behavior, never a wrong one - so this is a re-verification point rather than a safety boundary.

## The two vendor wordings the recognizer matches

Both observed in the field; the recognizer matches these and nothing else.

| Family | Wording | Window reported |
| --- | --- | --- |
| model | `You've reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model.` | `model:Fable 5` |
| session | `You've hit your session limit · resets 2am (UTC)` | `session` |

The model family requires the vendor's `/usage-credits` action link as a second anchor.
`reached your … limit` on its own is ordinary enough prose that a review agent quoting a diff can emit it, and a false quota verdict would excuse a real failure.

The model name is bound by `[A-Za-z0-9]+([.][0-9]+|[ -][A-Za-z0-9]+)*`, which admits a dot only between digits.
That is what a version looks like (`Haiku 4.5`, `Opus 4.1`), and it is not what a sentence end looks like.
A freely dotted name is unsafe even behind the action-link anchor, because this line satisfies both anchors at once:

```
Docs note: You've reached your quota. See the docs. Then run /usage-credits to check your limit.
```

Under a freely dotted name that reports the model as `quota. See the docs. Then run /usage-credits to check your`.
It is ordinary prose a review agent could emit while discussing this very feature, so the bound is load-bearing rather than cosmetic; `tests/fm-quota-kill.test.sh` pins that exact line as a must-not-match.

Classification is never taken from the exit shape.
`exit status 1` and `signal: killed` both occur for quota kills and for genuine deaths, which is exactly why the message is the only admissible evidence.

## Why a log match must also carry the harness's own exit line

The vendor sentence is just text, so an agent that QUOTES it writes the same bytes the vendor does.
This is not hypothetical: committing both wordings verbatim into this repository made the recognizer match its own documentation and its own test file, a live false positive in tracked material.

So in `--agent-episode` (log) mode a match must additionally be followed, on the first non-blank line, by the harness's own exit line matching `exited pid=<digits> error=`.
Only the harness writes that line, so requiring it adjacent separates the vendor speaking from an agent quoting the vendor.
Lines that are empty once surrounding whitespace and double quotes are stripped are skipped, because `axi logs` renders the log as TOON, which blanks to `""` and quotes some lines; both the raw log file and that rendering are real inputs.

**This requirement is scoped to log mode and must stay that way.**
A worker sitting on a live usage-limit dialog has not exited, which is the entire reason a supervisor is woken for it, so its pane carries no exit line by definition.
Adding adjacency to the plain (pane) mode would blind the blocked-worker path completely.

The cost of the requirement is that attribution can degrade to a plain failure, and that direction was chosen deliberately.
A false quota verdict excusing a genuine failure tells a supervisor to wait out an external condition that is never coming.
An unrecognized kill reporting as a plain failure is merely today's behavior and costs nothing that is not already being paid.
The second is recoverable by a human reading the log; the first actively misdirects one.
A later reader should not mistake this for an oversight and widen it back.

Measured over every log under `~/.no-mistakes/logs` carrying a vendor sentence, 30 logs: 27 keep their attribution and 3 do not.
All 3 are earlier-episode rejections that already existed before this change, not new losses.
The adjacency requirement itself costs zero attribution in that corpus: across all 42 vendor-line occurrences in it, the first non-blank line after the vendor line is the harness exit line in 42 of 42.

## Proof against real recorded runs

`fm_quota_kill_scan --agent-episode` run over the real step logs under `~/.no-mistakes/logs`, seven true kills and two controls:

```
MATCH   01KZW462QQ0DRRMFBMPDDP97YR/review.log   -> model:Fable 5
MATCH   01KZW4N9P25Y19SC2VG8QDX2YR/review.log   -> model:Fable 5
MATCH   01KZW3F28V5XWBZCBTX7963S81/review.log   -> model:Fable 5
MATCH   01KZVPA4GJ105Y83V6PCGKQ4NE/document.log -> model:Fable 5
MATCH   01KZVP7QQGGY9D2XEK080YYQ4X/review.log   -> model:Fable 5
MATCH   01KZVPCMHBVDQZ68JNEW173K2H/test.log     -> model:Fable 5
MATCH   01KZ2JBGHE3RQKQNF8C4HV7CDE/review.log   -> session (evidence keeps "resets 2am (UTC)")
NOMATCH 01KZPSM7F565JZA1ERZVKX4TJE/test.log     (genuine death: "claude exited: signal: killed", no vendor message)
NOMATCH 01KZ2FE452BGW3RP2YXA1754AW/ci.log       (three kills the CI step retried past; a later agent episode followed)
```

The last row is the reason for the `--agent-episode` mode.
A step log can hold several agent episodes, and a kill the pipeline already retried past is not why the step ended, so only a match in the final episode - none after the last `started pid=` line - may be attributed to the step's outcome.
A pane capture has no episode structure and is scanned without the flag.

## What this still cannot see

- **A new vendor wording.** The recognizer matches the two sentences above. A reworded limit message is not recognized, which reports as a plain failure - today's behavior - never as an excused one.
- **A verbatim quotation of a COMPLETE log block.** Adjacency narrows the quotation false positive; it does not eliminate it. Text reproducing the vendor sentence *together with* its adjacent harness exit line still matches in log mode, because at that point it is byte-identical to the thing it quotes. The `axi logs` excerpt in this record is exactly such a block, and it does match when scanned on its own. Scanning this whole record happens not to match, but only incidentally - its later prose mentions the `started pid=` marker, which trips the final-episode rule - so that is a coincidence of this file, not a property to rely on.
- **Any vendor sentence at all, in pane mode.** Plain mode carries no adjacency requirement by design, so tracked text quoting either wording still matches it, including this record and `tests/fm-quota-kill.test.sh`. The blocked-pane consumer is enrichment only: a false match renames a wake that was already being raised and never suppresses one, which is why this exposure is accepted rather than closed by narrowing the mode that acceptance criterion 2 depends on.
- **A kill before any output.** An agent killed before writing its first line leaves no message to match.
- **Non-`claude` harnesses.** Only the `claude` wordings are established. `codex`, `opencode`, `pi`, `grok` and `kimi` limit messages have not been observed here.
- **The pane dialog's own wording.** The blocked-pane enrichment matches the same two vendor sentences. If the interactive dialog words its limit differently, the enrichment does not fire and the wake keeps its existing generic reason - it is never suppressed.
- **A stopped supervisor.** The immediate blocked escalation needs a live supervision cycle. When none is running, the guard and auto-arm path owns that, not this.
- **Backends with no native push.** The prompt blocked wake rides the Herdr `pane.agent_status_changed` stream (`docs/herdr-backend.md`). A tmux home keeps the poll loop's wedge timer.

## Quota reporting at validation start

`bin/fm-quota-advice.sh` reports every window from `quota-axi --json` rather than the session window alone, because an account window, a weekly window and a per-model window bound the work independently, and the validation pipeline agent resolves its own model rather than the crewmate's.
Run against a live account on 2026-08-15 it emitted the shape below; following `dispatch-auth.md`, the percentages and reset stamps here are representative rather than the real account's.

```
$ bin/fm-quota-advice.sh
quota-advice: no window is exhausted
effective: claude all_models NN% remaining (bound by seven_day)
effective: claude model:fable NN% remaining (bound by seven_day)
window: claude five_hour NN% remaining, resets <timestamp>, pace behind
window: claude seven_day NN% remaining, resets <timestamp>, pace ahead
window: claude model:fable NN% remaining, resets <timestamp>, pace ahead
note: the validation pipeline agent resolves its own model, so its window is not necessarily the one a crewmate draws on.
note: advisory only - firstmate owns the dispatch decision; this reports quota and never withholds a spawn.
```

The three window ids, the `effective:` scopes, and `boundedBy`/`limitingWindowIds` are the producer fields the renderer depends on; `dispatch-auth.md` owns the full `quota-axi` shape.

It exits 0 on every path, including a missing, under-floor, failing or malformed `quota-axi`.
That is a deliberate structural property, not a convenience: it must never become a check that can withhold a spawn, because wave size is the captain's decision and firstmate owns dispatch under `AGENTS.md` section 7.

## Regression coverage

- `tests/fm-quota-kill.test.sh` - both vendor families, dotted model names, the glued-prose line shape, pane text with no episode structure, a live pane dialog with no exit line anywhere (the direct guard on the blocked-worker path), the evidence bound, and the failed-step read; plus the cases that must not regress: a genuine death, agent prose resembling the vendor sentence, a retried-past kill ahead of a genuine failure, an agent quoting the vendor sentence with no adjacent exit line, and the `Docs note:` line that carries both anchors.
- `tests/fm-crew-state.test.sh` - a failed run killed by the usage limit names that cause with its window; a failed run from a genuine agent death stays a plain failure with no quota clause.
- `tests/fm-supervision-events.test.sh` - a blocked pane showing the limit wakes with it named; an unrecognized dialog and an unreadable pane both keep the pre-existing generic reason.
- `tests/fm-quota-advice.test.sh` - every window reported with the binding one named, an exhausted per-model window headlined under a healthy-looking session window, valid JSON carrying no provider/window shape reported as unavailable rather than as a healthy account, and exit 0 preserved across every degraded read.
