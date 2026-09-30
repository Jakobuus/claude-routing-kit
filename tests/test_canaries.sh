#!/bin/bash
# tests/test_canaries.sh -- the full canary set (lib/canaries.sh) against the
# real sandbox-exec, a real generated Seatbelt profile, and a source repo
# with a gitignored file.
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB_DIR="$REPO_ROOT/plugins/routing-kit/lib"

. "$LIB_DIR/../bin/kit-common"
. "$LIB_DIR/seatbelt.sh"
. "$LIB_DIR/canaries.sh"

case "$(uname)" in
  Darwin) ;;
  *)
    echo "test_canaries.sh: macOS only, skipping" >&2
    echo "PASS 0 / FAIL 0"
    exit 0
    ;;
esac

d=$(mktmp)

# --- a source repo with a committed file, a gitignored file, and a HEAD ----
src=$(mktmp)
git -C "$src" init -q
git -C "$src" config user.email you@example.com
git -C "$src" config user.name "Test User"
echo hello > "$src/a.txt"
echo 'ignored.local' > "$src/.gitignore"
git -C "$src" add a.txt .gitignore
git -C "$src" commit -q -m init
echo "secret-local-content" > "$src/ignored.local"

# --- a working tree the profile allows (stand-in for run_export's wt) -----
wt="$d/wt"
mkdir -p "$wt"
echo hello > "$wt/a.txt"

run_home="$d/home"; run_cfg="$d/cfg"; run_tmp="$d/tmp"
mkdir -p "$run_home" "$run_cfg" "$run_tmp"

claude_bin="$d/fake-claude-bin"
printf '#!/bin/bash\necho fake\n' > "$claude_bin"
chmod +x "$claude_bin"

# Every path Seatbelt sees must be resolved (pwd -P), same as locked-build.
wt="$(kit_realpath "$wt")"
run_home="$(kit_realpath "$run_home")"
run_cfg="$(kit_realpath "$run_cfg")"
run_tmp="$(kit_realpath "$run_tmp")"
claude_bin="$(kit_realpath "$d")/fake-claude-bin"

port=$(/usr/bin/python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')

profile="$d/profile.sb"
seatbelt_generate "$profile" "$wt" "$run_home" "$run_cfg" "$run_tmp" "$claude_bin" "$port"

if [ ! -s "$profile" ]; then
  fail "seatbelt_generate did not write a profile"
  echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
  exit 1
fi
pass

if ! sandbox-exec -f "$profile" /bin/sh -c 'echo jail-works' >/dev/null 2>&1; then
  fail "sandbox-exec could not even start with the generated profile -- environment problem, not a canary result"
  echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
  exit 1
fi
pass

# --- run the full canary suite ---------------------------------------------
out=$(canaries_run "$profile" "$wt" "$src" "$port" full)
code=$?
echo "$out"

fail_lines=$(printf '%s\n' "$out" | grep -c '^CANARY FAIL')
ok_lines=$(printf '%s\n' "$out" | grep -c '^CANARY OK')

assert_eq 0 "$code" "canaries_run (full) reports overall success"
assert_eq 0 "$fail_lines" "no individual canary reported FAIL"
if [ "$ok_lines" -ge 10 ]; then
  pass
else
  fail "expected at least 10 canary OK lines, saw $ok_lines"
fi

assert_contains "$out" "read source repo's gitignored file" "gitignored-file probe ran in the full suite"
assert_contains "$out" "read source repo's .git/config" ".git/config probe ran"
assert_contains "$out" "read/write inside wt" "must-succeed wt probe ran"
assert_contains "$out" "reach the allowed loopback port" "must-succeed gate-port probe ran"

# --- KNOWN GAP probe: reports, but never counted as a pass or a fail ---------
# ("$fail_lines" and "$code", asserted above against 0, already cover "never
# a FAIL"/"never flips the overall result" for every line in $out, including
# these -- this only checks the probe actually ran and printed the right
# outcome.)
#
# This dev Mac has a working cc/CLT and the gap is NOT closed here, so
# "CANARY NOTE known gap now closed by macOS" is not an acceptable outcome
# on this machine -- accepting it unconditionally would let the probe
# silently report "closed" even when it's actually inconclusive or wrong.
# Only KNOWN-GAP (the true, expected outcome) or an explicit SKIP
# (inconclusive probe, or no working cc) pass here.
case "$out" in
  *"CANARY KNOWN-GAP read another process's command line (accepted risk, see START-HERE)"*) pass ;;
  *"CANARY SKIP known-gap probe inconclusive:"*) pass ;;
  *"CANARY SKIP read another process command line (KNOWN GAP probe): no working cc on this machine"*) pass ;;
  *"CANARY NOTE known gap now closed by macOS"*)
    fail "KNOWN GAP probe reported the gap as closed -- on this Mac it must still be open (expected KNOWN-GAP)"
    ;;
  *) fail "KNOWN GAP argv probe printed none of its expected outcome lines" ;;
esac

# --- no fixtures left behind -------------------------------------------------
real_home="$(kit_realpath "$HOME")"
if [ -e "$real_home/.routing-kit-canary/marker" ]; then
  fail "canary marker left behind in the real home"
else
  pass
fi
if [ -e "$real_home/.routing-kit-canary/sock" ]; then
  fail "canary socket left behind in the real home"
else
  pass
fi
if [ -e "$real_home/.routing-kit-canary/written" ]; then
  fail "canary write-test file left behind in the real home"
else
  pass
fi
if security find-generic-password -s routing-kit-canary -w >/dev/null 2>&1; then
  fail "canary Keychain item left behind"
else
  pass
fi
if [ -e "$real_home/.routing-kit-canary" ]; then
  fail "\$HOME/.routing-kit-canary directory itself left behind (not just its contents)"
else
  pass
fi

# --- quick mode skips the gitignored-file probe -----------------------------
quick_out=$(canaries_run "$profile" "$wt" "$src" "$port" quick)
quick_code=$?
assert_eq 0 "$quick_code" "canaries_run (quick) reports overall success"
case "$quick_out" in
  *"gitignored file"*) fail "quick mode ran the gitignored-file probe" ;;
  *) pass ;;
esac

# --- KIT_CANARY_FORCE_SUCCEED simulates a caught leak -> overall failure ----
forced_out=$(KIT_CANARY_FORCE_SUCCEED="read real-home marker" canaries_run "$profile" "$wt" "$src" "$port" quick)
forced_code=$?
assert_eq 1 "$forced_code" "a forced 'success' (simulated leak) makes canaries_run report failure"
assert_contains "$forced_out" "CANARY FAIL read real-home marker" "the forced probe is reported as a failure, not silently passed"

# --- item 4: an inherited fd above stderr must not be readable from inside
# the jail. Open fd 8 and 10 on marker files in THIS shell (bash 3.2: exec
# N<file), tell canaries_run about them via KIT_CANARY_TEST_FDS, and check
# both probes report OK (i.e. the jail could not read them) ------------------
fd_marker_dir=$(mktmp)
printf 'fd8-marker\n' > "$fd_marker_dir/fd8"
printf 'fd10-marker\n' > "$fd_marker_dir/fd10"
exec 8< "$fd_marker_dir/fd8"
exec 10< "$fd_marker_dir/fd10"
fd_out=$(KIT_CANARY_TEST_FDS="8 10" canaries_run "$profile" "$wt" "$src" "$port" quick)
fd_code=$?
exec 8<&-
exec 10<&-
assert_eq 0 "$fd_code" "canaries_run still reports success with fds 8/10 held open and both denied"
assert_contains "$fd_out" "CANARY OK   read inherited fd 8" "fd 8 is not readable inside the jail"
assert_contains "$fd_out" "CANARY OK   read inherited fd 10" "fd 10 is not readable inside the jail"

# --- item 6/18: every listener/stub PID canaries_run starts must be dead
# once it returns, and ~/.routing-kit-canary must be gone -------------------
pid_file=$(mktmp)/pids.txt
KIT_CANARY_PID_FILE="$pid_file" canaries_run "$profile" "$wt" "$src" "$port" full >/dev/null 2>&1
if [ -s "$pid_file" ]; then
  still_alive=""
  while IFS= read -r rec_pid; do
    [ -n "$rec_pid" ] || continue
    if kill -0 "$rec_pid" 2>/dev/null; then
      still_alive="$still_alive $rec_pid"
    fi
  done < "$pid_file"
  if [ -n "$still_alive" ]; then
    fail "canaries_run left listener PID(s) alive after returning:$still_alive"
  else
    pass
  fi
else
  fail "canaries_run recorded no PIDs to $pid_file despite KIT_CANARY_PID_FILE being set"
fi
if ps -axo command | grep -q '[r]k-wtsock'; then
  fail "a .rk-wtsock listener process is still running after canaries_run returned"
else
  pass
fi

# --- item 18: a plain "could not be found" (no CreateFromAttributes line)
# must NOT be accepted as a valid denial message -- exercises _canary_denied
# directly, without needing the real Keychain, by simulating exactly what a
# denied `security find-generic-password` looks like without the specific
# marker line _canary_denied requires. Uses $_CANARY_KEYCHAIN_DENIAL_PATTERN
# (the same named constant the production Keychain probe in canaries.sh
# itself matches against), not a separate literal copied into this test --
# a change to the production pattern is caught here automatically instead
# of the two silently drifting apart. -----------------------------------
before_fail=$_CANARY_FAIL
_canary_denied "fd18 simulated ambiguous keychain miss" \
  "true" \
  "echo 'SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2; exit 44" \
  "$profile" \
  "$_CANARY_KEYCHAIN_DENIAL_PATTERN"
if [ "$_CANARY_FAIL" -gt "$before_fail" ]; then
  pass
else
  fail "a plain 'could not be found' line (without CreateFromAttributes) was accepted as a valid denial"
fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
