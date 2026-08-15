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
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
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

# Deliberately NOT exported. A subshell inherits it, which is the whole point,
# while a separate test process that sources this library gets its own registry
# and so can never delete a parent's roots.
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/fm-test-registry.XXXXXX")

# fm_test_cleanup_register <dir>: register <dir> for removal on EXIT. Safe to
# call from a command-substitution subshell.
fm_test_cleanup_register() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$1" >> "$FM_TEST_CLEANUP_REGISTRY"
}

fm_test_cleanup() {
  local d p pids
  # Exact-pid reap of this shell's own background jobs, so nothing this suite
  # spawned outlives it holding the runner's stdout pipe open.
  pids=$(jobs -p 2>/dev/null || true)
  for p in $pids; do
    kill "$p" 2>/dev/null || true
  done
  if [ -n "$pids" ]; then
    sleep 0.2
    for p in $pids; do
      kill -9 "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
    done
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
