#!/bin/bash
# tests/lib.sh — tiny bash 3.2 test harness helpers.
# Sourced by each tests/test_*.sh file.

PASS_COUNT=0
FAIL_COUNT=0

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1" >&2
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
  expected="$1"; actual="$2"; msg="$3"
  if [ "$expected" = "$actual" ]; then
    pass
  else
    fail "$msg (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  haystack="$1"; needle="$2"; msg="$3"
  case "$haystack" in
    *"$needle"*) pass ;;
    *) fail "$msg (did not find [$needle])" ;;
  esac
}

# assert_locked_build_ok CODE OUT MSG -- asserts a locked-build invocation
# that was expected to succeed (exit 0) actually did. A happy-path test that
# instead got exit 5 tells you nothing about WHY on its own -- locked-build's
# own canary log is already in OUT (locked-build cats it before kit_die), so
# on failure this dumps every CANARY line from OUT to stderr, which is what
# actually shows up in CI logs. Without this, "expected [0], got [5])" is the
# only trace a flaky canary leaves behind, and there is no way to tell a real
# lockdown leak from a flake (port churn, a slow positive control, ...)
# without reproducing it by hand.
assert_locked_build_ok() {
  code="$1"; out="$2"; msg="$3"
  if [ "$code" = "0" ]; then
    pass
  else
    fail "$msg (expected [0], got [$code])"
    printf '%s\n' "$out" | grep -E '^CANARY|canary check failed|lockdown' >&2
  fi
}

# assert_exit CODE MSG -- CMD...
assert_exit() {
  expected_code="$1"; msg="$2"
  shift 2
  if [ "$1" != "--" ]; then
    fail "$msg (assert_exit missing -- separator)"
    return
  fi
  shift
  "$@" >/tmp/assert_exit_out.$$ 2>&1
  actual_code=$?
  rm -f /tmp/assert_exit_out.$$
  if [ "$actual_code" = "$expected_code" ]; then
    pass
  else
    fail "$msg (expected exit $expected_code, got $actual_code)"
  fi
}

# mktmp — a resolved temp dir, removed on exit.
# `d=$(mktmp)` runs mktmp in a subshell, so any trap set *inside* mktmp
# only fires when that subshell exits (immediately). Track created dirs in
# a list file instead, and register the cleanup trap once here, in the
# caller's own shell.
_MKTMP_LIST=$(mktemp "${TMPDIR:-/tmp}/rk-test-list.XXXXXX")
_mktmp_cleanup() {
  [ -f "$_MKTMP_LIST" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && rm -rf "$d"
  done < "$_MKTMP_LIST"
  rm -f "$_MKTMP_LIST"
}
trap _mktmp_cleanup EXIT

mktmp() {
  # If `mktemp -d` fails, its stdout is empty. A bare `cd ""` silently
  # stays in the caller's cwd and `pwd -P` then reports that cwd as if it
  # were a fresh temp dir — which then gets queued for rm -rf on exit.
  # Fail loudly instead, and never queue anything before we know the dir
  # is real.
  d=$(mktemp -d "${TMPDIR:-/tmp}/rk-test.XXXXXX")
  if [ $? -ne 0 ] || [ -z "$d" ]; then
    echo "mktmp: mktemp -d failed" >&2
    exit 1
  fi
  d=$(cd "$d" && pwd -P)
  if [ $? -ne 0 ] || [ -z "$d" ]; then
    echo "mktmp: could not resolve created temp dir" >&2
    exit 1
  fi
  echo "$d" >> "$_MKTMP_LIST"
  echo "$d"
}

# run_with_timeout SECS CMD... — a portable stand-in for GNU coreutils
# `timeout`, which a stock Mac (this repo's own baseline) does not ship and
# a clean CI runner does not have either. Runs CMD in the background inside
# its own process group, waits for it, and if it hasn't finished within
# SECS, TERMs (then KILLs) the whole group and returns 124 -- the same
# convention GNU timeout uses. On a normal finish, CMD's own exit code is
# returned unchanged.
#
# Own process group (`set -m` inside a subshell, so this never touches the
# test script's own group): killing -pgid on timeout reaches CMD and
# anything it forked, not just CMD's own pid, without reaching back up into
# the caller or any sibling test process.
#
# No `disown` here: a disowned pid can no longer be `wait`-ed for its real
# exit status (bash returns 0 immediately without actually waiting) --
# tried that first, and it silently turned every non-zero/timeout result
# into a false success. Instead, this follows the same discipline
# plugins/routing-kit/bin/locked-build uses: `wait CMD_PID` once, for the
# real exit status, and every subsequent `kill` on an already-reaped pid or
# on the watchdog is immediately followed by its own `wait` with nothing
# else run in between -- bash only prints an asynchronous "Terminated: ..."
# job-control notice for a job it killed and never got around to reaping
# before running some other command.
run_with_timeout() {
  local secs flag_dir flag code
  secs="$1"; shift
  flag_dir=$(mktmp)
  flag="$flag_dir/fired"
  (
    set -m
    "$@" &
    cmd_pid=$!
    (
      sleep "$secs"
      : > "$flag" 2>/dev/null
      kill -TERM -"$cmd_pid" 2>/dev/null || kill "$cmd_pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    timer_pid=$!
    wait "$cmd_pid" 2>/dev/null
    code=$?
    kill -TERM -"$cmd_pid" 2>/dev/null
    wait "$cmd_pid" 2>/dev/null
    kill -KILL -"$cmd_pid" 2>/dev/null
    kill -TERM -"$timer_pid" 2>/dev/null
    kill -KILL -"$timer_pid" 2>/dev/null
    wait "$timer_pid" 2>/dev/null
    exit "$code"
  )
  code=$?
  if [ -e "$flag" ]; then
    return 124
  fi
  return "$code"
}
