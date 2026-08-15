# shellcheck shell=bash
# Shared quota-axi access contract: the compatibility floor, and the one bounding
# ladder every quota-axi call runs under.
# Usage: . bin/fm-quota-axi-lib.sh
#
# 0.1.16 is the floor because it is the first build that reports each provider's
# credential sources independently and exposes Grok `state.authStatus`. Without
# those fields a dispatch candidate cannot be checked against the authentication
# surface it actually uses, which is how one harness's expired CLI token used to
# produce a captain-facing sign-out claim for a candidate that never read it.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# It also owns HOW a quota-axi call is bounded, because `timeout` is absent on a
# stock macOS: a caller that checks for that one command falls through to an
# unbounded network read on exactly the platform the ladder exists for. Keeping
# the ladder here is what stops a caller's idea of "bounded" from disagreeing
# with this file's.

FM_QUOTA_AXI_MIN=0.1.16

# fm_quota_axi_can_bound: true when this host has some way to bound a call. A
# caller that cannot bound quota-axi must report that rather than run it loose.
fm_quota_axi_can_bound() {
  command -v timeout >/dev/null 2>&1 ||
    command -v gtimeout >/dev/null 2>&1 ||
    command -v perl >/dev/null 2>&1
}

# fm_quota_axi_run: run `quota-axi <args>` under a bound and print its stdout.
# An empty <timeout_secs> runs unbounded, which is the bootstrap diagnostic's
# existing behavior. A zero or non-numeric bound, or a host with no bounding
# mechanism at all, returns non-zero WITHOUT running quota-axi.
fm_quota_axi_run() {  # <timeout_secs> <args...>
  local timeout=${1:-}
  [ "$#" -gt 0 ] && shift
  if [ -z "$timeout" ]; then
    quota-axi "$@" 2>/dev/null </dev/null
    return
  fi
  case "$timeout" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  else
    return 1
  fi
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  output=$(fm_quota_axi_run "$timeout" --version) || return 1
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}
