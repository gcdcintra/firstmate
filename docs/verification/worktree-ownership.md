# Worktree ownership verification

Audience: maintainer verification.

This record supports the ownership proof in `bin/fm-worktree-owner-lib.sh` and the refusals in `bin/fm-teardown.sh`.
It records only the treehouse behavior those decisions rest on, so it must be re-established when the treehouse pin changes.
Incident chronology and delivery evidence stay in private reports or PR evidence.

The question behind all of it: before firstmate terminates processes in a recorded worktree and returns it to the pool, can it prove that worktree still belongs to the task whose metadata names it?

## treehouse records a holder only for leased worktrees

Verified 2026-08-11 against treehouse v2.1.1.

`treehouse status --json` reports `lease_id`, `lease_holder`, and `leased_at` per worktree.
Those fields carry a holder only for worktrees taken with `treehouse get --lease`:

```
$ treehouse get --lease --lease-holder taskA
$ treehouse status --json
[{"name":"1","path":".../1/repo","status":"leased","lease_id":"3f581d1f...","lease_holder":"taskA","leased_at":"...","processes":[]}]
```

A worktree from a plain pooled `treehouse get` reports `"lease_holder":""`, so treehouse cannot name its holder.
This is the split the design follows: `bin/fm-home-seed.sh` takes secondmate homes with `treehouse get --lease --lease-holder <id>`, so their ownership is already provable through treehouse, while ordinary crewmate ship and scout worktrees carry no holder at all and need the marker record.

The leased entry above has `"processes":[]` and remains `leased`, confirming a lease survives with no live process.

## A pooled worktree is not reserved by the shell inside it

Verified 2026-08-11 against treehouse v2.1.1.

With no lease, a worktree whose processes are gone returns to `available` with nothing written back to the task that still records it, and the next `treehouse get` hands out that same slot.
This is the reassignment the ownership check exists to detect; nothing in the pool prevents it.

## Reclaim does not clean the worktree; `return --force` does not clean excluded files

Verified 2026-08-11 against treehouse v2.1.1.

A slot released by its processes disappearing is re-handed with its files intact, so a marker written by the previous holder survives into the next holder's slot.
That is why the record is compared by minted token rather than task id, why every firstmate spawn writes its own record unconditionally, and why `absent` refuses instead of assuming the worktree is still ours.

`treehouse return --force` cleans untracked files, but not files listed in the repo's `info/exclude`:

```
$ printf 'token=abc123\n' > "$WT/.fm-worktree-owner"     # with .fm-worktree-owner in info/exclude
$ treehouse return --force "$WT"
🌳 Worktree returned to pool.
$ cat "$WT/.fm-worktree-owner"
token=abc123
```

So teardown removes the record itself, scoped to its own token, after the return succeeds.

## An excluded marker does not make the slot look dirty

Verified 2026-08-11 against treehouse v2.1.1.

treehouse reports `status: dirty` for a worktree with uncommitted changes, skips dirty slots when handing one out, and documents that prune passes over them.
A marker listed in `info/exclude` leaves `git status --porcelain` empty and the slot `available`.

This is deliberate. Reserving a pool slot is treehouse's own job, through leases; a marker that reserved slots as a side effect of looking dirty would flip the pool from self-healing to held-until-returned without that being anyone's decision.
The marker therefore detects reassignment and never prevents it.

## `--if-lease-holder` is an atomic precondition, and refuses an unleased worktree

Verified 2026-08-11 against treehouse v2.1.1.

```
$ treehouse return --if-lease-holder wrongtask "$WT"; echo $?
failed to return worktree: lease precondition failed: lease holder does not match worktree ...
1
$ treehouse return --if-lease-holder taskA "$WT"      # lease still intact after the refusal
🌳 Worktree returned to pool.
$ treehouse return --if-lease-holder taskA "$WT"; echo $?
failed to return worktree: lease precondition failed: worktree ... is not leased
1
```

Both refusals exit 1 and leave the lease untouched, and the two messages are distinguishable.
`bin/fm-teardown.sh` and `bin/fm-home-seed.sh` therefore pass `--if-lease-holder` only where a lease is expected, treat the holder mismatch as a refusal, and fall back to an unguarded return on the "is not leased" signature so a home predating the lease is not stranded.

## The capability floor: v2.0.1 leases but cannot guard the return

Verified 2026-08-15 against the official v2.0.1 and v2.1.1 release archives.

Because the guarded return is a hard requirement rather than a best effort - every other guarded failure aborts instead of degrading to an unguarded return - a treehouse without `--if-lease-holder` cannot retire a leased secondmate home at all.
The dangerous shape is a build that offers the lease but not its precondition, since a lease-only capability probe passes it and the failure only surfaces at retirement, with the home retained and its lease never released.
v2.0.1 is exactly that shape:

```
$ ./treehouse --version
v2.0.1
$ ./treehouse get --help
Flags:
  -h, --help                  help for get
      --lease                 Durably lease a worktree without opening a subshell; print only its path to stdout
      --lease-holder string   Optional label recorded as the lease holder (defaults to $TREEHOUSE_LEASE_HOLDER)
$ ./treehouse return --help
Flags:
      --force   Clean, reset, and return without prompting
  -h, --help    help for return
```

v2.1.1's `return --help` advertises both `--if-lease-holder` and `--if-lease-id`.

So the floor is enforced in two places rather than assumed.
`bin/fm-install-treehouse.sh` pins v2.1.1, with each platform archive's SHA-256 taken from the release's `checksums.txt` and independently recomputed from the downloaded archive, and each verified to hold a single `treehouse` binary at the archive root.
`bin/fm-bootstrap.sh`'s `treehouse_supports_lease` probes `return --help` for `--if-lease-holder` as well as `get --help` for `--lease`, so a local install below the floor is reported as `MISSING: treehouse` at bootstrap instead of at retirement.

## Regression coverage

`tests/fm-worktree-owner.test.sh` covers the behavior these facts support, including the observed shape: one task's metadata naming a worktree another task now holds.
`tests/fm-bootstrap.test.sh` covers the capability floor, driving bootstrap against a treehouse that advertises the lease but not the guarded return.
