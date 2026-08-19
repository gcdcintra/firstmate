# Verification: which pipeline run `fm-crew-state.sh` attributes to a task

Audience: maintainer-verification.
Owner of the contract itself: the header of [`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh).
This record holds the empirical facts that contract rests on, so they can be re-checked against a newer CLI.

Verified 2026-08-19 against the installed `no-mistakes` v1.48.0, from two live worktrees of the same repository, one of which owned an active run parked at its review gate.

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

So `run.id` equal to `branch_sync.pipeline.run`, with `branch_sync.local` agreeing on the task's branch and HEAD, is the pipeline's own attribution.

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
This is why the walk answers only for the newest row of the branch and reports an unbindable one as unread.

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
- `test_coarse_unbindable_newest_row_never_falls_back_to_older_row` pins that no older row answers for an unbindable newest one.
- `test_coarse_newest_row_failed_and_bound_still_reports_failed` and `test_run_id_bound_failed_run_still_reports_failed` pin that genuinely failed runs are still reported failed, through both attribution paths.
- `test_run_id_binding_rejects_foreign_branch_sync` pins that a `branch_sync` block describing another checkout binds nothing.
