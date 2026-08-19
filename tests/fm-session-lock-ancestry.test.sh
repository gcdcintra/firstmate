#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Three layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The fork-descent
# cases build a Claude Code configuration root of their own and drive the real
# evidence path against real live processes, because the process start time that
# makes the registry pid-reuse proof cannot be faked through ps. The end-to-end
# cases run the REAL Stop auto-arm inside real process trees whose shapes differ
# only in how the per-session process is named and what its parent is. Those
# trees are orphaned before the hook fires, so the ancestry walk terminates
# inside the fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- fork-descent layer: the real evidence path against live processes -------
#
# A private Claude Code configuration root stands in for the real one, so these
# cases read the same registry and transcript layout the harness writes without
# depending on this machine's own sessions.

CLAUDE_CONFIG_DIR=$(fm_test_claude_config "$TMP_ROOT/claude-config")
export CLAUDE_CONFIG_DIR

# The record shapes themselves live in tests/lib.sh, which owns the one encoding
# of that external contract; the wrappers below only bind them to this suite's
# private configuration root and temp tree.

# Publish a live process in OWNER_PID to stand in for a session owner. The
# descent evidence never consults the process table, so any real pid carries the
# start time this needs. Its output is detached from this shell so no command
# substitution around a caller can wait on it.
OWNER_PID=
spawn_owner_process() {
  sleep 60 >/dev/null 2>&1 &
  OWNER_PID=$!
  fm_test_cleanup_register_pid "$OWNER_PID"
}

# True when this host can supply the process start time the registry check
# requires. Everywhere else the evidence is unavailable by design and every
# claim below must be refused instead.
proc_start_available() {
  fm_test_claude_fork_evidence_available
}

register_session() {  # <pid> <session-id> [<proc-start>]
  fm_test_claude_register_session "$CLAUDE_CONFIG_DIR" "$@"
}

write_transcript() {  # <session-id> <uuid>...
  fm_test_claude_write_transcript "$CLAUDE_CONFIG_DIR" "$@"
}

msg_uuid() {  # <n>
  fm_test_claude_msg_uuid "$1"
}

make_job_dir() {  # <name> <own-session-id> <resumed-session-id>
  fm_test_claude_job_dir "$TMP_ROOT/jobs/$1" "$2" "$3"
}

# Publish one backgrounded run: BG_HOST_PID is what a lock would record for it,
# and BG_SESSION_PID is the only pid in it the registry ever records.
BG_HOST_PID=
BG_SESSION_PID=
spawn_backgrounded_session_run() {  # <name>
  fm_test_spawn_bg_session_run "$NAMED_CLAUDE" "$TMP_ROOT/bg-run-$1"
  BG_HOST_PID=$FM_TEST_BG_HOST_PID
  BG_SESSION_PID=$FM_TEST_BG_SESSION_PID
}

# Evaluate one library expression against the REAL process table.
lib_run() {  # <expression>
  local expr=$1
  bash -c ". \"\$0\"; $expr" "$LIB"
}

test_quiescent_fork_source_is_provable() {
  local owner
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000001
  write_transcript 00000000-0000-4000-9000-000000000001 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000002 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"

  if proc_start_available; then
    CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000002 lib_run "fm_claude_fork_descendant_of_pid $owner" \
      || fail "a forked session could not prove descent from its own quiescent source"
    pass "fork descent: a forked session proves descent from its still-live, quiescent source"
  else
    if CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000002 lib_run "fm_claude_fork_descendant_of_pid $owner"; then
      fail "descent was claimed on a host that cannot supply the process start time"
    fi
    pass "fork descent: no process start time available, so the claim is refused"
  fi
}

test_fork_source_that_resumed_work_is_refused() {
  local owner
  proc_start_available || { pass "fork descent: resumed-source case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000003
  # The source took another turn after the fork: its own new uuid is one this
  # session does not have, which is exactly the 2026-08-02 two-helms shape.
  write_transcript 00000000-0000-4000-9000-000000000003 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 9)"
  write_transcript 00000000-0000-4000-9000-000000000004 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000004 lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a fork source that resumed work was still treated as a yieldable source"
  fi
  pass "fork descent: a source that took a turn after the fork is refused"
}

test_sibling_fork_is_not_an_ancestor() {
  local owner
  proc_start_available || { pass "fork descent: sibling-fork case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000005
  # Two forks of one source: each carries the shared history plus its own turns,
  # so neither extends the other and neither may take the home from the other.
  write_transcript 00000000-0000-4000-9000-000000000005 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 20)"
  write_transcript 00000000-0000-4000-9000-000000000006 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 30)" "$(msg_uuid 31)"
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000006 lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "one fork claimed descent from its sibling fork"
  fi
  pass "fork descent: a sibling fork is never an ancestor"
}

test_identical_transcript_is_not_an_ancestor() {
  local owner
  proc_start_available || { pass "fork descent: identical-transcript case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000007
  write_transcript 00000000-0000-4000-9000-000000000007 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000008 "$(msg_uuid 1)" "$(msg_uuid 2)"
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000008 lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a session that merely matches the owner's transcript claimed to extend it"
  fi
  pass "fork descent: matching the source's transcript is not extending it"
}

test_task_seeded_background_job_never_claims_by_fork_evidence() {
  local owner job
  proc_start_available || { pass "fork descent: task-seeded-job case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000009
  write_transcript 00000000-0000-4000-9000-000000000009 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000010 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  # A worker `claude --bg` seeded with its own task records itself as the session
  # it continues, so it must be refused even where the transcript proof is
  # satisfied - which a real one never is, since it forks no one.
  job=$(make_job_dir seeded 00000000-0000-4000-9000-000000000010 00000000-0000-4000-9000-000000000010)
  if CLAUDE_JOB_DIR="$job" CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000010 \
    lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a task-seeded background job claimed the home on fork evidence"
  fi
  pass "fork descent: a task-seeded background job is excluded even with a satisfied transcript proof"
}

# The 2026-08-14 defect: Claude Code gives a session the operator moved into the
# background the same CLAUDE_JOB_DIR it gives a task-seeded worker, so treating
# that variable as the worker test left a backgrounded primary permanently unable
# to re-claim its own home - the guard then blocked every turn end reporting a
# competing session, and supervision never re-armed.
test_backgrounded_session_claims_its_own_quiescent_source() {
  local owner job
  proc_start_available || { pass "fork descent: backgrounded-session case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000015
  write_transcript 00000000-0000-4000-9000-000000000015 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000016 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  job=$(make_job_dir backgrounded 00000000-0000-4000-9000-000000000016 00000000-0000-4000-9000-000000000015)
  CLAUDE_JOB_DIR="$job" CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000016 \
    lib_run "fm_claude_fork_descendant_of_pid $owner" \
    || fail "a backgrounded session could not prove descent from its own quiescent source"
  pass "fork descent: a backgrounded session proves descent from its own quiescent source"
}

test_backgrounded_session_with_an_unreadable_job_record_is_refused() {
  local owner job
  proc_start_available || { pass "fork descent: unreadable-job-record case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000017
  write_transcript 00000000-0000-4000-9000-000000000017 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000018 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  # A job whose record cannot be read says nothing about what it continues, so
  # the claim fails closed rather than assuming the permissive reading.
  mkdir -p "$TMP_ROOT/jobs/recordless"
  if CLAUDE_JOB_DIR="$TMP_ROOT/jobs/recordless" \
    CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000018 \
    lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a job with no readable record claimed descent"
  fi
  job=$(make_job_dir malformed 00000000-0000-4000-9000-000000000018 'not a session id')
  if CLAUDE_JOB_DIR="$job" CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000018 \
    lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a job record naming a malformed continued session claimed descent"
  fi
  pass "fork descent: a background job whose record does not prove a continued session is refused"
}

test_backgrounded_session_whose_source_resumed_work_is_refused() {
  local owner job
  proc_start_available || { pass "fork descent: backgrounded resumed-source case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000019
  # The continued session is genuinely this job's source, but it took its own
  # turn after the fork: two live sessions in use, which must still be refused.
  write_transcript 00000000-0000-4000-9000-000000000019 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 40)"
  write_transcript 00000000-0000-4000-9000-000000000020 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  job=$(make_job_dir backgrounded-active 00000000-0000-4000-9000-000000000020 00000000-0000-4000-9000-000000000019)
  if CLAUDE_JOB_DIR="$job" CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000020 \
    lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a backgrounded session took the home from a source that had resumed work"
  fi
  pass "fork descent: a backgrounded session whose source resumed work is still refused"
}

# The residual half of the same defect: this fleet's own primary is a fork of a
# source that was ITSELF backgrounded, so the lock records that source's host
# process and the registry keys only its session pid. Resolving the recorded
# owner only through its own record left that fork unable to reclaim its home -
# the identical inert-auto-arm, blocked-every-turn symptom, one hop later.
test_fork_of_a_backgrounded_source_resolves_the_run_the_lock_records() {
  local job
  proc_start_available || { pass "fork descent: backgrounded-source case needs /proc, refused everywhere else"; return; }
  spawn_backgrounded_session_run source
  register_session "$BG_SESSION_PID" 00000000-0000-4000-9000-000000000021
  [ ! -e "$CLAUDE_CONFIG_DIR/sessions/$BG_HOST_PID.json" ] \
    || fail "the fixture registered the host pid, which is exactly what the harness never does"
  write_transcript 00000000-0000-4000-9000-000000000021 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000022 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  job=$(make_job_dir fork-of-backgrounded 00000000-0000-4000-9000-000000000022 00000000-0000-4000-9000-000000000021)
  CLAUDE_JOB_DIR="$job" CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000022 \
    lib_run "fm_claude_fork_descendant_of_pid $BG_HOST_PID" \
    || fail "a fork of a backgrounded source could not resolve the run its lock records"
  pass "fork descent: a lock naming the host of a backgrounded run resolves to the session that run hosts"
}

test_live_session_outside_the_recorded_run_is_never_borrowed() {
  local owner
  proc_start_available || { pass "fork descent: outside-the-run case needs /proc, refused everywhere else"; return; }
  # A live, registered, harness-named session exists - just not inside the run
  # the lock records. Borrowing it would hand an unrelated session's identity to
  # the recorded owner, which is the whole boundary the run walk must keep.
  spawn_backgrounded_session_run outsider
  register_session "$BG_SESSION_PID" 00000000-0000-4000-9000-000000000023
  write_transcript 00000000-0000-4000-9000-000000000023 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000024 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  spawn_owner_process; owner=$OWNER_PID
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000024 \
    lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "an unrelated live session record was borrowed to resolve a recorded owner"
  fi
  pass "fork descent: a live session outside the run the lock records is never borrowed to resolve it"
}

# The same boundary where the recorded owner IS a live verified Claude process, so
# nothing about its kind can discard it early and the run walk itself is the only
# thing standing between two independent live runs on one machine - the case that
# actually decides whether a second session's identity can be handed to this
# home's recorded owner.
test_claude_owner_outside_the_registered_run_is_never_borrowed() {
  local registered_session outsider_host
  proc_start_available || { pass "fork descent: outside-the-run Claude-owner case needs /proc, refused everywhere else"; return; }
  spawn_backgrounded_session_run borrow-source
  registered_session=$BG_SESSION_PID
  register_session "$registered_session" 00000000-0000-4000-9000-000000000031
  write_transcript 00000000-0000-4000-9000-000000000031 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000032 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  # A second, independent backgrounded run. Its host is a live Claude harness the
  # registry vouches for nowhere, and the only live record on the machine belongs
  # to the OTHER run, so resolving it can only happen by borrowing across runs.
  spawn_backgrounded_session_run borrow-target
  outsider_host=$BG_HOST_PID
  [ "$outsider_host" != "$registered_session" ] \
    || fail "the fixture reused one run for both sides, so nothing about the run walk is being tested"
  [ ! -e "$CLAUDE_CONFIG_DIR/sessions/$outsider_host.json" ] \
    || fail "the fixture registered the recorded owner, which is exactly what this case must not stage"
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000032 \
    lib_run "fm_claude_fork_descendant_of_pid $outsider_host"; then
    fail "a session record from another live Claude run was borrowed to resolve the recorded owner"
  fi
  pass "fork descent: a live Claude owner outside the registered run is never resolved by borrowing across runs"
}

test_inherited_ancestor_job_record_never_claims() {
  local owner job
  proc_start_available || { pass "fork descent: inherited-job-record case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000025
  write_transcript 00000000-0000-4000-9000-000000000025 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000026 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  # CLAUDE_JOB_DIR is exported to every descendant process, so a nested session
  # started inside a backgrounded one reads its ANCESTOR's record. That record
  # proves a continuation, but of a different session than the one claiming.
  job=$(make_job_dir inherited-ancestor 00000000-0000-4000-9000-000000000027 00000000-0000-4000-9000-000000000025)
  if CLAUDE_JOB_DIR="$job" CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000026 \
    lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a nested session claimed the home on a job record belonging to its ancestor"
  fi
  pass "fork descent: a job record inherited from an ancestor never proves THIS claimant continued anyone"
}

test_job_record_continuing_a_different_session_is_refused() {
  local owner job
  proc_start_available || { pass "fork descent: other-source-job case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000028
  write_transcript 00000000-0000-4000-9000-000000000028 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000029 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  # This claimant's own job record, naming a third session as the one it
  # continues: it vouches for nothing about the session the lock actually holds.
  job=$(make_job_dir other-source 00000000-0000-4000-9000-000000000029 00000000-0000-4000-9000-000000000099)
  if CLAUDE_JOB_DIR="$job" CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000029 \
    lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a job record continuing some other session claimed descent from the recorded owner"
  fi
  pass "fork descent: a job record that continues a session other than the recorded owner is refused"
}

test_recycled_pid_record_is_rejected() {
  local owner
  proc_start_available || { pass "fork descent: recycled-pid case needs /proc, refused everywhere else"; return; }
  spawn_owner_process; owner=$OWNER_PID
  # A record left by a dead session whose pid was handed to something else.
  register_session "$owner" 00000000-0000-4000-9000-000000000011 1
  write_transcript 00000000-0000-4000-9000-000000000011 "$(msg_uuid 1)" "$(msg_uuid 2)"
  write_transcript 00000000-0000-4000-9000-000000000012 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000012 lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a session record whose process start time does not match the live pid was trusted"
  fi
  pass "fork descent: a recorded owner whose process start time no longer matches is rejected"
}

test_live_owner_without_a_session_record_is_refused() {
  local owner
  spawn_owner_process; owner=$OWNER_PID
  write_transcript 00000000-0000-4000-9000-000000000013 "$(msg_uuid 1)" "$(msg_uuid 2)" "$(msg_uuid 3)"
  # Every harness other than Claude Code, and any Claude session the registry
  # does not vouch for, lands here and keeps the unchanged refusal.
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID=00000000-0000-4000-9000-000000000013 lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "an owner with no session record was treated as a fork source"
  fi
  pass "fork descent: a live owner the harness does not vouch for is refused"
}

test_missing_own_session_identity_is_refused() {
  local owner
  spawn_owner_process; owner=$OWNER_PID
  register_session "$owner" 00000000-0000-4000-9000-000000000014
  write_transcript 00000000-0000-4000-9000-000000000014 "$(msg_uuid 1)" "$(msg_uuid 2)"
  if CLAUDE_JOB_DIR='' CLAUDE_CODE_SESSION_ID='' lib_run "fm_claude_fork_descendant_of_pid $owner"; then
    fail "a claimant that cannot identify its own session still claimed descent"
  fi
  pass "fork descent: a claimant with no session identity of its own is refused"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_quiescent_fork_source_is_provable
test_fork_source_that_resumed_work_is_refused
test_sibling_fork_is_not_an_ancestor
test_identical_transcript_is_not_an_ancestor
test_task_seeded_background_job_never_claims_by_fork_evidence
test_backgrounded_session_claims_its_own_quiescent_source
test_backgrounded_session_with_an_unreadable_job_record_is_refused
test_backgrounded_session_whose_source_resumed_work_is_refused
test_fork_of_a_backgrounded_source_resolves_the_run_the_lock_records
test_live_session_outside_the_recorded_run_is_never_borrowed
test_claude_owner_outside_the_registered_run_is_never_borrowed
test_inherited_ancestor_job_record_never_claims
test_job_record_continuing_a_different_session_is_refused
test_recycled_pid_record_is_rejected
test_live_owner_without_a_session_record_is_refused
test_missing_own_session_identity_is_refused
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
