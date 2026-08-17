# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
`fm_session_lock_foreign_owner_alive` in `bin/fm-session-lock-lib.sh` is the single owner of that live-foreign-owner test, shared with the Claude turn-end guard's stood-down outcome in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
That test has one evidence-gated exception, owned by the same library and described under [Session fork recovery](#session-fork-recovery) below.
The recoverable-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher emits one last-resort notice for the continuous failure episode; later consecutive Stop cycles exit 2 to guarantee another Stop-owned retry without repeating the notice until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Session fork recovery

A forked Claude session continues the same conversation under a new pid while the pre-fork process stays alive, so the lock keeps naming a live process that is not in the fork's ancestry.
That is a third case: neither the same session nor a competing one.
Refusing it left supervision unable to re-claim its own home, so every turn end needed a manual arm.

The fork is separated from a competing session by evidence only, never by assumption, and never by inspecting or ending either process.
Claude Code's own live-session registry maps the recorded lock pid to the session it is running, bound to that incarnation of the pid by its process start time.
It keys that record on the session pid, while the lock records the outermost pid of the contiguous harness run, so for a source that was itself backgrounded the two differ and the recorded pid is its `claude bg-pty-host`; the recorded pid is then resolved through the one live record whose session pid its own contiguous Claude run hosts, which is how a fork of a backgrounded source resolves and reclaims exactly like an ordinary fork.
A forked transcript is a verbatim copy of its source's, so the source's message uuids reappear in it unchanged and in order.
The claim therefore requires the owner's transcript to be a strict positional prefix of this session's, which proves the owner is this session's fork source and, in the same test, that it has produced nothing since the fork.
When it holds, `bin/fm-lock.sh` takes the lock and leaves the source process running; it re-proves the claim before releasing, so a source that resumes work mid-claim gets the lock straight back.
[`verification/supervision.md`](verification/supervision.md#session-fork-lock-recovery) records the measured evidence.

Everything else keeps the unchanged refusal, so the boundary the fleet depends on does not move:

- A source that took any turn after the fork appends a uuid this session does not have, so it is a live session in use and keeps the home.
- Sibling forks of one source extend each other in neither direction, and an identical transcript is not an extension.
- A session inside a Claude Code background job claims only when that job's own record shows THIS claimant was created to continue THIS recorded owner: the record must name the claimant's own session id, and must name the owner's resolved session as the one it continues.
  A job seeded with its own task names itself in both fields and is refused before any transcript is read, and a session that inherited `CLAUDE_JOB_DIR` from a backgrounded ancestor reads a record about that ancestor rather than itself and is refused for the same reason - the transcript proof is not left as the only thing standing between an inherited record and a claim.
  Claude Code has one background-session feature, `claude --bg`, whose help calls what it starts a background agent, and the same feature serves both a session the operator moved into the background and a worker seeded with a task; the job environment alone therefore cannot tell them apart, and treating its presence as the worker test left a backgrounded primary session permanently unable to re-claim its own home (2026-08-14 incident).
- A live owner the registry vouches for nowhere in its own contiguous run, a record whose process start time no longer matches, two session records inside one run, or a claimant that cannot identify its own session all fail closed.
- The process start time is read from `/proc`, so fork recovery is Linux-only and every other platform refuses.
- Every primary harness other than Claude keeps today's behavior, having no such registry, and the run walk rejects a non-Claude process at its first hop.

Two limits are deliberate.
A fork taken from a point earlier than the source's own tip leaves post-boundary uuids in the source, so it never auto-claims and the manual path remains.
A source that has been idle since the fork loses the lock to its descendant and goes read-only if it is used again; the home still has exactly one owner at all times, and this is the only direction in which the change is more permissive - never the direction where two live sessions both act on one home.
[`verification/supervision.md`](verification/supervision.md#resolving-a-lock-that-records-a-backgrounded-run) records the measured evidence for the backgrounded-run resolution.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after the durable wake queue was drained, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale, live, and fork-source session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
