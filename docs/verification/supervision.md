# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.
The installed pi-signed 0.82.0 wrapper repeated the Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
Firstmate-written project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while global `~/.codex/hooks.json` `SessionStart` hooks fired in the same runs.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Worker CPU progress

[`bin/fm-cpu-progress-lib.sh`](../../bin/fm-cpu-progress-lib.sh) reads utime+stime+cutime+cstime from `/proc/<pid>/stat`, and the watcher consults it before every wedge escalation.
These measurements set its shipped floor of `FM_CPU_PROGRESS_MIN_TICKS_PER_MIN=120`, i.e. 2.0 ticks/s.
Fields are USER_HZ units, fixed at 100 on Linux (`getconf CLK_TCK` reported `100` on the sampled host).

Sampled 2026-08-12 on Linux 6.8.0-137 over a 45-second window, across every live Claude Code worker on one host also running builds and a UI suite, with each worker's declared turn state read from its own `state/<id>.busy-state` record:

```sh
read_ticks() { awk '{n=index($0,")"); r=substr($0,n+2); split(r,f," "); print f[12]+f[13]+f[14]+f[15]}' "/proc/$1/stat"; }
# sample, sleep 45, re-sample, print the delta per worker
```

| Declared turn state | Observed ticks/s over 45s |
| --- | --- |
| busy (inside a turn) | 4.04, 4.67, 13.16 |
| idle (waiting at its prompt) | 0.58, 0.91, 2.24, 3.33, 3.82 |

Two facts follow, and both are load-bearing.

An idle agent is NOT quiet: a Claude Code worker sitting at its prompt animates its footer and burns 0.58-3.82 ticks/s, overlapping the busy range.
CPU progress is therefore not a general "is this worker working" signal, and the watcher consults it only where an idle-at-prompt worker cannot appear - the wedge timer, which a pane reaches only after already being classified provably working or busy-past-its-turn-bound.
A finished worker that went quiet without a status line is surfaced immediately by the separate non-terminal stale path, which this change does not touch.

The floor separates working from WEDGED, not working from idle.
The wedge cases sit an order of magnitude below every reading above: the 2026-08-10 stuck-TCP-send-queue wedge logged 10 ticks over 45s (0.22 ticks/s) with 539136 bytes pinned in `Send-Q`, and a hung process logs 0.
At 2.0 ticks/s the floor sits ~9x above that wedge and ~1.5x below the slowest productive turn observed (3.1 ticks/s in an earlier 40s sample on the same host).
A long tool-driven turn is the case being rescued, and the two independently sampled reproductions of it - one worker 100+ minutes into a single verification turn, one 5 hours into a single implementation turn - read 5.7 and 5.6 ticks/s.

End-to-end on 2026-08-12, with a real `bin/fm-watch.sh` in a throwaway `FM_HOME`, pointed at live Herdr panes and resolving each worker pid through the real `herdr pane process-info` path.
Both panes were set up identically - a busy record, a spawn record aged past `FM_BUSY_TURN_MAX_SECS`, and a wedge timer backdated 500s past `FM_STALE_ESCALATE_SECS` - so the CPU reading was the only difference between them.

A worker several hours inside ONE agent turn was deferred, not escalated, and its wake queue stayed empty:

```
absorbed busy (no completed turn) timer reset: default:w7:p15
deferred busy (no completed turn) wedge escalation, worker CPU progressing (500s without pane output):
  default:w7:p15 - process 106286 used 326 CPU ticks in 46s (floor 92)
```

A pane whose agent had exited, leaving a bash prompt as its foreground process - a real near-flat counter of the same shape a hung or socket-blocked agent presents - still escalated, carrying its reading:

```
measured: class=flat delta=0 window=46
stale: default:w7:pR (no pane output for 501s, possible wedge, escalation 1;
  process 1398 used 0 CPU ticks in 46s (floor 92))
```

Deterministic entry points:

```sh
tests/fm-cpu-progress.test.sh
tests/fm-watch-triage.test.sh
```

`tests/fm-cpu-progress.test.sh` drives real processes rather than canned `/proc` fixtures, since the guarantee is about the counter the kernel maintains.
A live worker is not a usable stand-in for a wedged one: a quiet agent can resume mid-sample and then correctly reads as progressing, which is why the flat-counter cases use processes the test controls or a pane whose agent has actually exited.

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs a real watcher and attached arm to verify that a delivered reason survives queue draining, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

The bounded stood-down fail-open, which keeps the `--claude` guard from blocking indefinitely while another live session owns this home's fleet lock, was verified on 2026-08-10 with the isolated behavior suites for both cooperating hooks.

```sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-turnend-guard.test.sh tests/fm-claude-stop-autoarm.test.sh
```

Observed output:

```text
fm-doc-audience-check: ok surfaces=61 local_links=176
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=152927
```

The pull guard's false `WATCHER DOWN` alarm through the normal between-cycle gap, and its silence after the fix, were observed live on 2026-08-10 against the running primary home under real fleet load, read-only, with the home's own watcher never stopped or disturbed.
The gap was sampled until `state/.watch.lock` was absent while `state/.last-watcher-beat` was still inside the grace window, then both guards were run back to back over that same live state.

```sh
FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
FM_ROOT_OVERRIDE=<live home> FM_GUARD_READ_ONLY=1 <changed checkout>/bin/fm-guard.sh
```

Observed output:

```text
sampled gap: state/.watch.lock absent, state/.last-watcher-beat 24s old, grace 300s, 6 in-flight tasks

before the change:
● WATCHER DOWN - SUPERVISION IS OFF
● 6 task(s) in flight, but no watcher has a fresh beacon (last beat: 24s ago, grace 300s).
WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership.

after the change:
WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership.
```

Both directions were exercised end to end on 2026-08-10 in a throwaway `FM_HOME` against a genuinely armed `bin/fm-watch.sh` watcher, stopped only by its exact pid, across five scenarios covering silence and alarm.
`FM_GUARD_GRACE` was forced to 1 second in scenarios 3 and 5 to age the beacon deterministically instead of waiting out a real stall.
A scenario recorded as silent means the guard printed nothing at all.

```sh
FM_HOME=<throwaway home> bin/fm-watch.sh &
FM_ROOT_OVERRIDE=<throwaway root> FM_HOME=<throwaway home> FM_GUARD_GRACE=<300|1> bin/fm-guard.sh
```

Observed output:

```text
1. no watcher ever armed, beacon absent, grace 300:
● WATCHER DOWN - SUPERVISION IS OFF
● 1 task(s) in flight, but no live watcher is supervising them (last beat: never, grace 300s).
● Failing condition: no watcher process holds this home's watcher lock (state/.watch.lock is absent).

2. live armed watcher pid 2315281 holding the lock, beacon fresh, grace 300: silent

3. same live watcher pid 2315281 still holding the lock, grace 1:
● WATCHER DOWN - SUPERVISION IS OFF
● 1 task(s) in flight, but no live watcher is supervising them (last beat: 3s ago, grace 1s).
● Failing condition: the watcher holding this home's lock (pid 2315281) is running but has stopped beating.

4. that watcher stopped by exact pid so its own exit released the lock, beacon still fresh, grace 300: silent

5. same stopped watcher, beacon now past grace, grace 1:
● WATCHER DOWN - SUPERVISION IS OFF
● 1 task(s) in flight, but no live watcher is supervising them (last beat: 17s ago, grace 1s).
● Failing condition: no watcher process holds this home's watcher lock (state/.watch.lock is absent).
```

Proven live against a real watcher process: the between-cycle gap staying silent (observed both on the primary home under real fleet load and in the throwaway home after a real watcher exit), a verified live holder with a fresh beacon staying silent, a live lock holder that has stopped beating alarming and naming that holder, and an absent lock past grace alarming and naming the absent lock.
Resting on `tests/fm-guard-stale-banner.test.sh` alone: a lock naming a dead pid alarming and naming that pid, which a real watcher cannot leave behind because its exit releases the lock, so it is only reachable through a recorded lock fixture.
Exercised by no scenario and no test in this change: the `lock-owner-missing`, `lock-pid-unreadable`, `lock-foreign-home`, `lock-foreign-watcher`, `lock-identity-missing`, `lock-identity-unreadable`, `lock-identity-mismatch` and `beacon-missing` description branches of `fm_watcher_unhealthy_description`; the underlying predicate rejections for those conditions remain covered by the existing turn-end guard suite, but their rendered banner wording is not.

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-07-27 against the tracked extension with a faithful in-process factory rebind (module cache retained, real arm children):

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, and `/fork`, plus same-instance shutdown-plus-start, the replacement generation armed again without a Pi restart and without the `watcher: not armed - Pi session is shutting down` refusal.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Session fork lock recovery

A harness session fork runs the continuation under a new pid while the pre-fork process stays alive, so the home's session lock keeps naming a live process that is not in the new session's ancestry.
The evidence below is what lets `bin/fm-session-lock-lib.sh` separate that source from a genuinely competing session without inspecting or touching either process.
Measured on 2026-08-11 with Claude Code 2.1.227 on Linux, entirely in a throwaway project directory and two throwaway terminal sessions.

The `SessionStart` hook payload identifies the fork but nothing above it.
`claude --resume <id> --fork-session` with a `SessionStart` hook that echoes its stdin produced:

```text
{"session_id":"d69f5a17-ee02-46de-8775-39fc0d5f5406","transcript_path":"/home/ubuntu/.claude/projects/-tmp-fm-fork-stale-lock-probe/d69f5a17-ee02-46de-8775-39fc0d5f5406.jsonl","cwd":"/tmp/fm-fork-stale-lock/probe","hook_event_name":"SessionStart","source":"fork"}
```

The payload carries the new session id only: no source session id, no source pid, and no other statement of the relationship.
`CLAUDE_CODE_RESUME_SOURCE_ALIVE` was empty in the same hook environment, because Claude Code sets it only when it spawns a session from a live source itself.
The forked transcript is rewritten to the new session id throughout, so the source id does not appear there either.

Two harness-maintained facts do carry the relationship.

Claude Code keeps a live-session registry at `<config>/sessions/<pid>.json`:

```text
{"pid":39387,"sessionId":"b215a5c6-46d4-4f83-b982-704b97ef871b","cwd":"/tmp/fm-fork-stale-lock/probe","startedAt":1786464523520,"procStart":"4391894","version":"2.1.227","peerProtocol":1,"kind":"interactive","entrypoint":"cli","tmux":"fm-fork-repro:@0.%0","messagingSocketPath":"/run/user/1000/cc-socks/39387.sock","name":"probe-9b","nameSource":"derived","status":"idle","updatedAt":1786464544549,"statusUpdatedAt":1786464544549}
```

`procStart` equals field 22 of `/proc/<pid>/stat` (`awk '{ print $22 }' /proc/39387/stat` printed `4391894`), which binds the record to that incarnation of the pid.
Every record enumerated on the host mapped to a live process, and both throwaway records were gone once their sessions exited, so a stale record does not survive to vouch for a dead session.
Reading it needs no privilege beyond the user's own configuration directory, and the record for the forked session was already present when its own `SessionStart` hook ran.

A fork's transcript is a verbatim copy of its source's, so the copied records keep their original message uuids.
With a live interactive session forked from a second terminal, the source pid stayed alive and foreground on its tty while the continuation ran under a new pid, reproducing the reported shape:

```text
39387 Ssl+ pts/16   claude      (source, still the foreground window)
104131 -            claude      (forked continuation, new pid)
```

Comparing the two transcripts after the fork took one turn:

```text
parent uuids: 11  fork uuids: 15
parent set subset of fork set: True
strict superset: True
parent uuids are a positional PREFIX of fork uuids: True
```

The source transcript stayed byte-identical across the fork and the fork's turn while its window sat idle, so the prefix relation is reachable in practice rather than only in principle.
After the source took one more turn of its own, the same comparison printed:

```text
parent uuids: 15  fork uuids: 15
still a prefix (must be False): False
still a subset  (must be False): False
```

That is the guarantee the design rests on: the same test that proves the owner is this session's fork source also proves it has done nothing since, and any turn the source takes breaks it in both directions.

`procStart` has no portable equivalent, so fork recovery is Linux-only by construction and every other platform keeps the unchanged live-owner refusal.
Non-Claude primaries have no such registry and are unaffected for the same reason.

The recovery itself was measured the same day against two real interactive sessions in a throwaway home, using the tracked `.claude/settings.json` Stop registration and an arm fixture in place of a real watcher.
The source session acquired the lock through `bin/fm-lock.sh`, was forked from a second terminal, and was then left untouched while the fork completed one turn.

Observed at the fork's own turn end, with no arm command issued by either model:

```text
=== lock now ===            1457529   (the forked session)
=== fork pane pid ===       1457529
=== source still alive? === 1409153 pts/16   Ssl+ claude
=== epoch ===               epoch=4 owner_pid=1483946 outcome=rewake
```

The lock moved to the forked continuation on its own turn end, supervision armed without a manual step, and the source process stayed alive and foreground on its tty throughout.

The same lab then proved the boundary in the other direction.
With the lock restored to the source and the source given one further turn of its own, the evidence path refused and the acquirer left the lock alone:

```text
=== AFTER the source took a turn: predicate must refuse ===
REFUSED (correct)
lock: held by live harness pid 1409153
error: another live firstmate session holds the lock (pid 1409153); operate read-only until resolved
acquire rc=1
lock after refused acquire: 1409153
```

Deterministic entry points:

```sh
tests/fm-session-lock-ancestry.test.sh
tests/fm-claude-stop-autoarm.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
