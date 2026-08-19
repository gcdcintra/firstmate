#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, the bounded child-process stop contract
# (fm_wake_terminate), fakebin/PATH-shim helpers, deterministic git identity and
# fixture builders, state/<id>.meta writers, and the common string/exit-code/file
# assertions. It deliberately does NOT bundle the behavior-specific fake
# tmux/treehouse/no-mistakes mocks: those encode terminal and lifecycle
# assumptions that differ per suite and belong with the tests that own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not point the
# registry at a fresh empty file, re-arm the EXIT trap, or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fleet-lifecycle entrypoints would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. fm_test_cleanup_register <dir> registers a dir the caller made
# itself. A test file that needs extra teardown (e.g. killing a daemon) should
# define its own EXIT trap and call fm_test_cleanup from inside it so registered
# dirs are still removed.
#
# Two properties below are load-bearing, and both were once absent:
#
#   1. The EXIT trap is installed HERE, at source time, never lazily on first
#      registration. fm_test_tmproot echoes its root, so nearly every caller
#      writes `TMP_ROOT=$(fm_test_tmproot ...)` - which runs the body in a
#      command-substitution subshell, where an installed trap dies with the
#      subshell. Registering lazily left the real shell with no trap at all.
#   2. Registrations go to a FILE rather than to a shell array, for the same
#      reason: a subshell's array append is invisible to its parent, while an
#      append to the registry file is not.
#
# Losing cleanup does not merely leak a directory. bin/fm-test-run.sh runs every
# suite as `bash "$script" 2>&1 | tee "$out"`, so each background child a suite
# leaves behind inherits the write end of that pipe through stderr. A watcher
# whose state dir still exists keeps polling forever, tee never sees EOF, and the
# lane burns its whole timeout-minutes cap without ever reporting the assertion
# that actually failed. fm_test_cleanup therefore reaps this shell's own
# background jobs BEFORE removing directories, by exact pid from `jobs -p`: the
# process table is shared with every other worker on the machine, so it must
# never pattern-match a process name.
#
# `jobs -p` covers only this shell's DIRECT children, which is not every process
# a suite creates: a fixture that starts a host process publishing a grandchild
# leaves that grandchild invisible to the job table, and killing the host merely
# reparents it. Such a pid must be handed to fm_test_cleanup_register_pid the
# moment it is known, so a `fail` anywhere after the spawn still retires it -
# relying on a per-suite stop helper reached only on the happy path is what
# leaked one past every suite exit.
#
# A registered pid is nonetheless weaker evidence than a job pid, and the
# difference decides whether the reap is safe. An unwaited job is held in the
# table by its own zombie, so its pid cannot be reused while this shell can still
# name it; a registered grandchild is nobody's job here, so the moment it dies it
# is reaped by init and its pid is free for the next process on the machine. A
# suite that retires such a run mid-run and keeps going therefore leaves a long
# window in which a bare recorded pid names something unrelated. Registration
# binds the pid to its incarnation for exactly that reason, and cleanup signals it
# only while that binding still holds.

# Deliberately NOT exported. A subshell inherits it, which is the whole point,
# while a separate test process that sources this library gets its own registry
# and so can never delete a parent's roots.
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/fm-test-registry.XXXXXX")
FM_TEST_CLEANUP_PID_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/fm-test-pids.XXXXXX")

# fm_test_cleanup_register <dir>: register <dir> for removal on EXIT. Safe to
# call from a command-substitution subshell.
fm_test_cleanup_register() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$1" >> "$FM_TEST_CLEANUP_REGISTRY"
}

# fm_test_cleanup_register_pid <pid> [<proc-start>]: register a process this suite
# spawned that `jobs -p` cannot see - typically a grandchild published by a
# fixture host - so EXIT reaps it by exact pid. Safe to call from a
# command-substitution subshell. A non-numeric argument is ignored rather than
# signalled: cleanup must never widen a kill to anything the caller did not name.
#
# The pid is recorded together with the kernel start time naming THIS incarnation
# of it, so the reap can never reach a later, unrelated holder of a recycled pid.
# <proc-start> overrides the live reading, for a test staging a pid whose
# incarnation has already changed. Where the host cannot supply a start time at
# all the pid stands for itself, exactly as before.
fm_test_cleanup_register_pid() {
  local pid=${1:-} start=${2:-}
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -n "$start" ] || start=$(fm_test_proc_start "$pid")
  printf '%s %s\n' "$pid" "$start" >> "$FM_TEST_CLEANUP_PID_REGISTRY"
}

# True while pid $1 is still the incarnation that was registered with start time
# $2. An empty $2 is the no-evidence case - a job pid, which needs none, or a host
# with no /proc - and keeps the unconditional reap.
fm_test_pid_is_registered_incarnation() {
  [ -n "${2:-}" ] || return 0
  [ "$2" = "$(fm_test_proc_start "$1")" ]
}

fm_test_cleanup() {
  local d p start records signalled=''
  # Exact-pid reap of this shell's own background jobs and of every explicitly
  # registered descendant, so nothing this suite spawned outlives it holding the
  # runner's stdout pipe open. Each escalation re-checks the binding, because a
  # registered pid that the first signal retired is free for reuse before the
  # second one is sent.
  records=$(jobs -p 2>/dev/null || true)
  if [ -f "$FM_TEST_CLEANUP_PID_REGISTRY" ]; then
    records=$(printf '%s\n%s\n' "$records" "$(cat "$FM_TEST_CLEANUP_PID_REGISTRY" 2>/dev/null || true)")
    rm -f "$FM_TEST_CLEANUP_PID_REGISTRY"
  fi
  records=$(printf '%s\n' "$records" | awk 'NF')
  while IFS=' ' read -r p start; do
    [ -n "$p" ] || continue
    fm_test_pid_is_registered_incarnation "$p" "$start" || continue
    kill "$p" 2>/dev/null || true
    signalled="$signalled$p $start"$'\n'
  done <<< "$records"
  if [ -n "$signalled" ]; then
    sleep 0.2
    while IFS=' ' read -r p start; do
      [ -n "$p" ] || continue
      fm_test_pid_is_registered_incarnation "$p" "$start" || continue
      kill -9 "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
    done <<< "$signalled"
  fi
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
}

trap fm_test_cleanup EXIT

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  fm_test_cleanup_register "$root"
  printf '%s\n' "$root"
}

# --- child-process stop contract --------------------------------------------

# Terminate a child THIS shell owns and reap it, without ever blocking forever.
#
# The escalation below is load-bearing, not defensive tidiness. A watcher whose
# TERM handler never runs survives the single SIGTERM these helpers send, and
# that is not hypothetical: PR 10's job log caught bin/fm-watch.sh emitting
# "trap: line 2: unexpected EOF while looking for matching ')'", so its
# `trap 'exit 1' HUP INT TERM` body failed to parse and the process simply
# carried on. A bare `wait` on such a pid never returns.
#
# The cost of that is a whole CI lane, not one red test. bin/fm-test-run.sh
# streams every suite as `bash "$script" 2>&1 | tee "$out"`, so a suite blocked
# here stops mid-run still holding that pipe, and the job burns its entire
# timeout-minutes cap producing NO verdict at all. PR 10 died exactly there,
# after 28 of fm-watch-triage's 48 assertions, and was cancelled 15 minutes
# later with an orphaned tee still open.
#
# SIGTERM is therefore escalated to SIGKILL after a bounded grace, so `wait`
# only ever runs against a pid that is already dying. SIGKILL cannot be trapped,
# which is what makes the bound hold whatever the child's own handlers do, or
# fail to do. Kills are by exact pid, never by pattern: the process table is
# shared with every other worker on the machine.
#
# The grace must EXCEED the child's poll interval. bin/fm-watch.sh waits in
# `sleep "$POLL"` as a foreground child, and bash defers a trapped signal until
# that child finishes, so a watcher's TERM latency is bounded below by its poll.
# A grace that expired first would SIGKILL a HEALTHY watcher and skip its EXIT
# trap (watcher_cleanup), leaving .watch.lock unreleased inside the very suites
# that assert lock behavior. The default below clears the FM_POLL=5 these suites
# use by a wide margin; a caller running a watcher on a longer poll must pass a
# larger grace explicitly. Raising it costs nothing on a healthy stop: the loop
# exits as soon as the child is gone.
fm_wake_terminate() {
  local pid=$1 grace=${2:-150} i=0
  kill "$pid" 2>/dev/null || true
  while [ "$i" -lt "$grace" ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- Claude Code session fixtures -------------------------------------------
#
# ONE encoding of the three external record shapes Claude Code writes and
# bin/fm-session-lock-lib.sh parses: the live-session registry at
# <config>/sessions/<pid>.json, the session transcript at
# <config>/projects/<project>/<session-id>.jsonl, and the background-job record
# at <job-dir>/state.json. They are an external contract, not firstmate output,
# so a suite carrying its own copy would keep passing on a stale assumption after
# the real shape moved - which is exactly what three independent copies of them
# risked.

# fm_test_claude_config <dir>: create the private configuration root <dir> with
# the subdirectories the writers below populate, and echo it. A private root is
# what keeps a live-owner case from reading the sessions of whichever machine
# happens to run the suite.
fm_test_claude_config() {
  local dir=$1
  mkdir -p "$dir/sessions" "$dir/projects/probe"
  printf '%s\n' "$dir"
}

# fm_test_proc_start <pid>: echo the kernel start time of <pid> exactly as the
# registry records it, read straight from /proc so it never depends on the
# library's own parsing. Empty where /proc does not exist.
fm_test_proc_start() {
  [ -r "/proc/$1/stat" ] || return 0
  awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null
}

# fm_test_claude_fork_evidence_available: true when this host can supply that
# start time at all. It binds a record to one incarnation of a pid, so fork
# recovery is deliberately Linux-only and every other platform must refuse.
fm_test_claude_fork_evidence_available() {
  [ -n "$(fm_test_proc_start $$)" ]
}

# fm_test_claude_register_session <config> <pid> <session-id> [<proc-start>]:
# write the live-session record Claude Code keeps for <pid>. The start time
# defaults to the live one, so the record binds to this incarnation of the pid;
# pass a differing one to stage a recycled pid.
fm_test_claude_register_session() {
  local config=$1 pid=$2 session_id=$3 start=${4:-}
  [ -n "$start" ] || start=$(fm_test_proc_start "$pid")
  printf '{"pid":%s,"sessionId":"%s","cwd":"/probe","procStart":"%s","kind":"interactive"}\n' \
    "$pid" "$session_id" "$start" > "$config/sessions/$pid.json"
}

# fm_test_claude_write_transcript <config> <session-id> <uuid>...: write the
# transcript for <session-id> carrying those message uuids, in the record shape a
# fork copies verbatim.
fm_test_claude_write_transcript() {
  local config=$1 session_id=$2 uuid file
  shift 2
  file="$config/projects/probe/$session_id.jsonl"
  : > "$file"
  for uuid in "$@"; do
    printf '{"parentUuid":null,"type":"user","uuid":"%s","sessionId":"%s"}\n' \
      "$uuid" "$session_id" >> "$file"
  done
}

# fm_test_claude_msg_uuid <n>: a distinct, well-formed v4-shaped message uuid.
fm_test_claude_msg_uuid() {
  printf '00000000-0000-4000-8000-%012d\n' "$1"
}

# fm_test_claude_job_dir <dir> <own-session-id> <resumed-session-id>: write the
# background-job record `claude --bg` leaves at <dir>/state.json and echo <dir>,
# for CLAUDE_JOB_DIR. The same session id in both fields is the shape a job
# seeded with its own task carries.
fm_test_claude_job_dir() {
  local dir=$1
  mkdir -p "$dir"
  printf '{\n  "sessionId": "%s",\n  "resumeSessionId": "%s",\n  "template": "bg",\n  "backend": "daemon"\n}\n' \
    "$2" "$3" > "$dir/state.json"
  printf '%s\n' "$dir"
}

# fm_test_spawn_bg_session_run <harness> <dir>: start a backgrounded Claude
# session as the process table really shows it - a harness-named host process with
# the session process as its own CHILD - using the harness-named interpreter
# <harness> and publishing the session pid under <dir>. Sets
# FM_TEST_BG_HOST_PID, the outermost pid of the contiguous run and so the pid a
# session lock records, and FM_TEST_BG_SESSION_PID, the only pid in that run the
# harness registry ever keys a record on.
#
# Both pids are registered for cleanup as soon as they are known, because the
# session process is this shell's GRANDCHILD: `jobs -p` never sees it, and the
# readiness `fail` below fires with the host already running. Its own loop is
# bounded for the same reason, so even a pid this fixture never got to publish
# retires itself instead of spinning for the life of the machine.
FM_TEST_BG_HOST_PID=
FM_TEST_BG_SESSION_PID=
fm_test_spawn_bg_session_run() {
  local harness=$1 dir=$2 script i=0
  mkdir -p "$dir"
  script="$dir/bg-host.sh"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
# $1 = directory to publish the session pid into, $2 = harness-named interpreter.
"$2" -c 'printf "%s\n" "$$" > "$0/session-pid"; i=0; while [ "$i" -lt 900 ]; do sleep 0.2; i=$((i + 1)); done' "$1" &
wait
SH
  FM_TEST_BG_HOST_PID=
  FM_TEST_BG_SESSION_PID=
  rm -f "$dir/session-pid"
  "$harness" "$script" "$dir" "$harness" >/dev/null 2>&1 &
  FM_TEST_BG_HOST_PID=$!
  fm_test_cleanup_register_pid "$FM_TEST_BG_HOST_PID"
  while [ "$i" -lt 200 ] && [ ! -s "$dir/session-pid" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/session-pid" ] || fail "the backgrounded-run fixture never started its session process"
  FM_TEST_BG_SESSION_PID=$(tr -d '[:space:]' < "$dir/session-pid")
  fm_test_cleanup_register_pid "$FM_TEST_BG_SESSION_PID"
}

# fm_test_stop_bg_session_run: retire the run fm_test_spawn_bg_session_run last
# published. Cleanup reaps it regardless, so this is only for a suite whose next
# assertion needs the recorded owner to be dead.
fm_test_stop_bg_session_run() {
  local pid
  for pid in "$FM_TEST_BG_SESSION_PID" "$FM_TEST_BG_HOST_PID"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  [ -z "$FM_TEST_BG_HOST_PID" ] || wait "$FM_TEST_BG_HOST_PID" 2>/dev/null || true
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
