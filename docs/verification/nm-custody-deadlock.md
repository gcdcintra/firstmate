# Stranded-branch custody verification

Audience: maintainer verification.

This record supports `bin/fm-nm-custody.sh`, which recognizes a branch stranded by a dead no-mistakes run and steps around it.
It records only the facts that must be re-established when the no-mistakes binary changes: the exact fields the script parses, the one signal that distinguishes a stranded branch from an ordinary recoverable one, and the proof that the sidestep restores validation.
Incident chronology and the field reproductions stay in the private backlog item `nm-custody-deadlock`.

Verified 2026-08-12 against `no-mistakes version v1.46.0 (20892e6)`.

## The state the script must recognize

A terminal run keeps a custody claim on its branch.
The supported return is guarded on the gate branch still sitting exactly at the head that run recorded, so once anything moves the gate off that head the guard can never pass again.

Reproduced end to end in a scratch repository with a local bare origin, triggered by a real pipeline-agent kill (`You've reached your Fable 5 limit`), which is the same trigger as every field occurrence.
The rebase step alone is enough to strand a branch: it advances the run's recorded head inside the gate without moving the gate ref.

```
$ no-mistakes axi sync --check
branch_sync:
  local:
    branch: feat/custody
    head: 7184f7f0382cf08dbd2182a02ecb3fc58b3c1972
    clean: true
  pipeline:
    run: "01KZW462QQ0DRRMFBMPDDP97YR"
    status: failed
    phase: pre_push
    submitted_head: 7184f7f0382cf08dbd2182a02ecb3fc58b3c1972
    current_head: 58c7dbd158be754c3cf97bb56c9ffcde4111307c
  safety: blocked_pipeline_owned_recoverable
  next_action:
    code: recover_custody
    command: no-mistakes axi sync --recover
```

```
$ no-mistakes axi sync --recover
  safety: blocked_recover_gate_diverged
  note: "the gate branch is at 7184f7f0382cf08dbd2182a02ecb3fc58b3c1972, not the preserved pipeline head 58c7dbd158be754c3cf97bb56c9ffcde4111307c recorded for this run; no files or refs were changed"
```

`--recover --keep-local` refuses identically, and `axi abort --run <id>` is a no-op because the run is already terminal.

## Why `axi sync --check` alone cannot classify it

This is the fact the whole detector rests on.
A stranded branch and an ordinary recoverable one print the **identical** check answer, so the gate-diverged code is only reachable by attempting a recovery.

| | stranded (scratch repro) | recoverable (live task `fm/fm-meta-worktree-reassigned`) |
| --- | --- | --- |
| `safety` | `blocked_pipeline_owned_recoverable` | `blocked_pipeline_owned_recoverable` |
| `next_action.code` | `recover_custody` | `recover_custody` |
| `pipeline.status` | `failed` | `failed` |
| `pipeline.current_head` | `58c7dbd1…` | `8149215d…` |
| gate head for the branch | `7184f7f0…` | `8149215d…` |
| `axi sync --recover` would | refuse, gate diverged | succeed |

The discriminator is the last row: the gate branch's head against `pipeline.current_head`.
The refusal note states that comparison in exactly those terms, which is why the script reads it rather than inferring it from prose.

## Reading the gate head

`no-mistakes init` registers the gate as a git remote named `no-mistakes` in the repo itself, so the gate head is addressable without assuming anything about `NM_HOME`'s internal layout.

```
$ git remote -v
no-mistakes	/home/ubuntu/.no-mistakes/repos/3fe6a1615eba.git (fetch)
no-mistakes	/home/ubuntu/.no-mistakes/repos/3fe6a1615eba.git (push)

$ git ls-remote no-mistakes refs/heads/feat/custody
7184f7f0382cf08dbd2182a02ecb3fc58b3c1972	refs/heads/feat/custody
```

`git ls-remote` mutates neither side, which keeps the whole classification read-only.

## The sidestep restores validation

The claim is keyed to the branch name, so a new branch at the identical head carries none.

```
$ bin/fm-nm-custody.sh recover --dir <scratch>
custody: stranded
  ...
Created feat/custody-v2 at 7184f7f0382cf08dbd2182a02ecb3fc58b3c1972 - the identical head

$ git for-each-ref --format='%(refname:short) %(objectname:short)' refs/heads
feat/custody 7184f7f          <- stranded ref, left in place
feat/custody-v2 7184f7f       <- identical head
```

A fresh run on the replacement branch is accepted rather than refused for custody:

```
$ no-mistakes axi run --intent "..."
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,5
    rebase,completed,0,76
    review,failed,0,3898
  error: "step review failed: agent review: claude exited: exit status 1: "
```

`intent` and `rebase` completing is the point: the run started.
Review then failed only on the exhausted model quota that caused the strand in the first place, not on custody.

The captain separately validated two hand-made sidesteps to completion on real work, `fm/sm-cf-nf6-caderno-v2` and `fm/fm-fork-stale-lock-v2`, which is the evidence that a run started this way also finishes normally.

## Must-not-fire, checked against live state

Run read-only against the live task worktree for `fm/fm-meta-worktree-reassigned`, whose gate head equalled its preserved head:

```
$ bin/fm-nm-custody.sh check --dir <live worktree>
custody: recoverable
  the gate is still at the head run 01KZVPA4GJ105Y83V6PCGKQ4NE recorded, so `no-mistakes axi sync --recover` can return custody normally
```

`recover` exits without acting on that state, leaving the choice between `--recover` and `--recover --keep-local` to the worker, because that choice is about content rather than about ownership.

## Re-establishing this record

Run `tests/fm-nm-custody.test.sh` after any no-mistakes upgrade.
Its fixtures replay the TOON above; if a version renames `safety`, `next_action.code`, `pipeline.current_head`, or the `no-mistakes` remote, the tests keep passing against stale fixtures while the real binary has moved, so re-capture the two commands in this file's first section before trusting them.
