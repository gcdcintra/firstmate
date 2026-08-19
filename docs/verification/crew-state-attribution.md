# Verification: which pipeline run `fm-crew-state.sh` attributes to a task

Audience: maintainer-verification.
Owner of the contract itself: the header of [`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh).
This record holds the empirical facts that contract rests on, so they can be re-checked against a newer CLI.

Verified 2026-08-19 against the installed `no-mistakes` v1.48.0, from five live worktrees of the same repository - four owning a run of their own, one owning none, and two of the four parked at a review gate.

## The guarantee

A live run parked at a gate is never reported `failed`, and no run may answer for a run the reader could not read.

## `axi status` emits `branch_sync:` only for the run that owns the current checkout's branch

This is the fact the run-id binding rests on, and it is not stated in `axi status --help`.
Three directions, all with the same run id:

```
$ cd <worktree on fm/fm-teardown-ownership-remediation, which owned run 01M0C0NMH09NBK495KFFC9TAF8>
$ no-mistakes axi status | grep -c '^branch_sync:'
1
$ cd <worktree on another branch, with no run of its own>
$ no-mistakes axi status | grep -c '^branch_sync:'
0
$ no-mistakes axi status --run 01M0C0NMH09NBK495KFFC9TAF8 | grep -c '^branch_sync:'
0
```

Inside the block, `pipeline.run` names the run id the pipeline treats as owning that branch, and `local` reports the checkout it resolved:

```
$ no-mistakes axi status | grep -E '^  id:|^    run:|^    branch:|^    head:'
  id: "01M0C0NMH09NBK495KFFC9TAF8"
    branch: fm/fm-teardown-ownership-remediation
    head: 985dd8af934a077dad2656e85d2cf849bd8c8ddd
    run: "01M0C0NMH09NBK495KFFC9TAF8"
```

So `run.id` equal to `branch_sync.pipeline.run`, with `branch_sync.local.branch` agreeing on the task's branch, is the pipeline's own statement of WHICH run owns this branch.

## The run id answers which run, never whose code

The run id cannot carry attribution on its own, and neither can `branch_sync.local`.

`local` is the CLI's LIVE read of the checkout it was invoked in - `fm-crew-state.sh` invokes it with `cd "$WT"` - so `local.head` equals that worktree's HEAD by construction and agrees with any run.
A run also keeps its custody claim on the branch NAME after going terminal ([`nm-custody-deadlock.md`](nm-custody-deadlock.md)), so the CLI keeps naming a dead run in `pipeline.run` long after its worker committed a local fix and went back to work.
Run id plus branch name plus `local.head` is therefore exactly the "some run owns this branch" rule the reader's header calls insufficient, and binding on it reintroduces the false `failed`.

The three neighboring fields do not close that gap either, checked against the four live runs above, two of which had a pipeline head that had already moved:

| field | run A | run B | run C | run D |
| --- | --- | --- | --- | --- |
| `local.head` vs `pipeline.current_head` | same | same | differs | differs |
| `changed` | `false` | `false` | `false` | `false` |
| `state` | `pipeline_owned` | `pipeline_owned` | `pipeline_owned` | `pipeline_owned` |
| `relation` | `equal` | `equal` | `unknown` | `unknown` |

`changed` is `false` on every one of them, including the two whose heads disagree, so it is not a local-versus-pipeline comparison at all.
`state` is `pipeline_owned` on all four, which is ownership rather than code identity.
`relation` is `equal` only while the pipeline head still equals the local head and degrades to `unknown` - not to a divergence verdict - the moment the pipeline moves its head without pushing it, which is the ordinary shape of a live run.

What the reader can compute locally is PATCH identity: does a pipeline head already carry every commit unique to this worktree's HEAD?
On the incident's own commits it sees straight through the rebase that defeated ancestry:

```
$ git cherry 0df68e38d59e983b27060130fd49efb068eab352 985dd8af934a077dad2656e85d2cf849bd8c8ddd
- 2b3e7014c46bed557bfeb51e15250e45ac7cad10
- 985dd8af934a077dad2656e85d2cf849bd8c8ddd
```

Every worktree commit is `-`, already present upstream, so the pipeline holds all of this task's work.
A worker that added a commit the pipeline never received gets a `+` line instead, and nothing binds.

## When no pipeline head is visible at all

An in-flight run's own commits live only inside the local gate, so `current_head` - and, after a rebase, `submitted_head` too - can be unresolvable in the worktree.
There is then no local evidence in either direction, and the reader binds NOTHING: the run is unattributed and the pane busy signature and status log answer instead.

That is a deliberate refusal rather than a gap.
The remaining fields in the block are all statements about who owns the branch NAME - `state: pipeline_owned`, `safety: blocked_pipeline_owned`, `next_action.code: continue_active_run` - and branch ownership survives both a worker rewriting the branch under a run it abandoned and a run going terminal ([`nm-custody-deadlock.md`](nm-custody-deadlock.md)).
Binding on any of them would report an abandoned run's step as the crew's state and mark the crew's own `blocked:`/`paused:` line superseded, which is the self-report the pane and log fallback exists to surface.

Sourcing matters here and is worth stating plainly: the live values above were read with `no-mistakes axi status`, while the terminal-custody pairing (`safety: blocked_pipeline_owned_recoverable`, `next_action.code: recover_custody`) is only recorded from `no-mistakes axi sync --check`, a different command.
No `axi status` read of a terminal run holding custody was ever captured - so a reader that leaned on those fields would be resting a false `failed` on an unchecked cross-command assumption.
It does not lean on them at all.

## Bounding the patch-identity walk

`git cherry` computes a patch-id - a full diff - for every commit on both sides of the merge base, and after a rebase the candidate's side includes however far the default branch had advanced.
This reader runs per-crew on the watcher's single-threaded poll, so the walk is fenced twice: an ancestor test answers without diffing at all when the pipeline has not rebased, and otherwise the divergence is counted first with a plain graph walk and the diff is skipped entirely past `FM_CREW_STATE_PATCH_SCAN` commits (default 200).
Exceeding the ceiling is treated as no evidence, which costs a fall-through to the pane and log sources rather than an unbounded diff on the fleet's supervision poll.

## Why the commit-sha binding cannot carry attribution alone

Both heads a sha binding can try are commits the pipeline rewrites, so on a run that has rebased, neither is the worktree HEAD nor a descendant of it:

```
run:
  id: "01M0C0NMH09NBK495KFFC9TAF8"
  status: running
  awaiting_agent: parked 13h29m
  head: c3c0cfa7
  steps[9]{step,status,findings,duration_ms}:
    rebase,completed,0,3751
    review,awaiting_approval,6,869592
branch_sync:
  local:
    head: 985dd8af934a077dad2656e85d2cf849bd8c8ddd
  pipeline:
    submitted_head: 0df68e38d59e983b27060130fd49efb068eab352
```

```
$ git rev-parse --verify c3c0cfa7^{commit}
fatal: Needed a single revision
$ git merge-base --is-ancestor 985dd8af934a077dad2656e85d2cf849bd8c8ddd 0df68e38d59e983b27060130fd49efb068eab352; echo $?
1
```

`head` lives only in the local gate repository, and `submitted_head` is the rebase of the worktree's own commit onto a newer base, so it is a sibling of the worktree HEAD rather than a descendant.
`submitted_head` is therefore the head the pipeline records itself as validating, not "the commit this worktree handed it".

## `no-mistakes runs` has no run id, so the coarse walk can only bind by sha

```
$ no-mistakes runs --help
Flags:
  -h, --help        help for runs
      --limit int   maximum number of runs to display (default 10)
```

Newest-first plain text, `<status> <branch> <short-sha> <date> [<pr-url>]`, with no id and no JSON:

```
  running      fm/fm-nested-project-mode ecf596f0  2026-08-19 00:24
  running      fm/fm-teardown-ownership-remediation c3c0cfa7  2026-08-19 00:22
  failed       fm/fm-teardown-ownership-remediation 0df68e38  2026-08-18 16:53
  failed       fm/fm-teardown-ownership-remediation 985dd8af  2026-08-18 09:36
```

The branch's live run is the second row and its sha is gate-only.
A walk that skips an unbindable row reaches the fourth row, whose sha is exactly the worktree HEAD, and reports a terminal `failed` for a run that is still parked and answerable.
This is why the walk answers only for the newest row of the branch.
An unbindable newest row attributes no run at all, which is the ordinary no-run case: the reader falls through to the pane busy signature and then the status log, so refusing the older row costs it no other evidence.

## End-to-end, on the live parked run

The reader before the fix, and after it, against the same live state and the same task record:

```
$ bin/fm-crew-state.sh fm-teardown-ownership-remediation          # before
state: failed · source: run-step · run failed
$ bin/fm-crew-state.sh fm-teardown-ownership-remediation          # after
state: parked · source: run-step · parked at review: 6 finding(s) (ask-user: authority decision)
$ bin/fm-crew-state.sh fm-teardown-ownership-remediation --pipeline-activity   # after
parked the attributed pipeline run is parked at review waiting for this worker to answer it
```

That agrees with the run's own pinned read, which was the confirming check all along:

```
$ no-mistakes axi status --run 01M0C0NMH09NBK495KFFC9TAF8
  status: running
  awaiting_agent: parked 13h29m
    review,awaiting_approval,6,869592
```

## Regression coverage

`tests/fm-crew-state.test.sh` pins the guarantee hermetically, over throwaway git repositories with a fake CLI:

- `test_live_parked_run_never_reported_failed` reproduces this exact condition - gate-only run head, rebased submitted head, and the branch's own older failed rows below its live row - and fails with `state: failed · source: run-step · run failed` without the fix.
- `test_live_parked_run_pipeline_activity_is_parked` pins the same binding for the pipeline-clock mode.
- `test_coarse_unbindable_newest_row_never_falls_back_to_older_row` and `test_coarse_unbindable_newest_row_still_reads_the_pane` pin that no older row answers for an unbindable newest one, and that refusing it still leaves the status log and the pane busy signature to answer.
- `test_stale_terminal_run_after_local_fix_commit_not_attributed` pins the other false-`failed` shape: a terminal run still named in `pipeline.run` after its worker committed a local fix binds nothing, because the pipeline's submitted head does not carry that commit. It supplies `continue_active_run`, the strongest ownership claim the CLI can make, so only the code evidence can be deciding it.
- `test_active_run_with_no_visible_pipeline_head_binds_nothing`, `test_abandoned_active_run_with_gate_only_heads_not_attributed` and `test_terminal_run_with_no_visible_pipeline_head_binds_nothing` pin the no-code-evidence refusal with BOTH pipeline heads gate-only, for a live run, for a run a worker abandoned after rewriting the branch under it, and for a terminal run.
- `test_branch_sync_refusal_is_not_rescued_by_the_sha_binding` pins that the older sha binding is reached only for an answer carrying no `branch_sync` block.
- `test_run_id_binding_rejects_a_stale_view_of_this_checkout` pins the freshness half: an answer whose `local.head` disagrees with the HEAD really there describes a checkout that has moved, and binds nothing even though every other check would pass.
- `test_coarse_newest_row_failed_and_bound_still_reports_failed` and `test_run_id_bound_failed_run_still_reports_failed` pin that genuinely failed runs are still reported failed, through both attribution paths.
- `test_run_id_binding_rejects_foreign_branch_sync` pins that a `branch_sync` block describing another checkout binds nothing.
