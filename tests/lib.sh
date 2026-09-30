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
