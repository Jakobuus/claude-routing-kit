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
    echo "SKIP: test_canaries.sh needs macOS (Kimi/GLM Seatbelt jail)" >&2
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
# KIT_CANARY_DEBUG_DIR_FILE: canary_dir/keychain_svc are random per call
# (mktemp), not a fixed or pid-derived name a test could guess from outside
# -- see canaries.sh's own comment on canary_dir for why. Capture the real
# values via the test-only hook so "nothing left behind" below checks the
# actual fixture, not a guessed path that would trivially "pass" by no
# longer existing at all.
canary_debug_file=$(mktmp)/canary-dirs.txt
out=$(KIT_CANARY_DEBUG_DIR_FILE="$canary_debug_file" canaries_run "$profile" "$wt" "$src" "$port" full)
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
# Read the real canary_dir/keychain_svc back from the debug file the hook
# above wrote (see canaries.sh: they're mktemp-random per call, not a
# guessable name).
canary_dir=$(sed -n '1p' "$canary_debug_file" 2>/dev/null)
canary_keychain_svc=$(sed -n '2p' "$canary_debug_file" 2>/dev/null)
if [ -z "$canary_dir" ] || [ -z "$canary_keychain_svc" ]; then
  fail "KIT_CANARY_DEBUG_DIR_FILE was not written -- cannot check for leftover fixtures"
else
  if [ -e "$canary_dir/marker" ]; then
    fail "canary marker left behind in the real home"
  else
    pass
  fi
  if [ -e "$canary_dir/sock" ]; then
    fail "canary socket left behind in the real home"
  else
    pass
  fi
  if [ -e "$canary_dir/written" ]; then
    fail "canary write-test file left behind in the real home"
  else
    pass
  fi
  if security find-generic-password -s "$canary_keychain_svc" -w >/dev/null 2>&1; then
    fail "canary Keychain item left behind"
  else
    pass
  fi
  if [ -e "$canary_dir" ]; then
    fail "canary_dir ($canary_dir) itself left behind (not just its contents)"
  else
    pass
  fi
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

# --- regression: two concurrent canaries_run invocations must not race on
# real-$HOME fixtures ---------------------------------------------------------
# Reproduced directly (see canaries.sh's file header): before canary_dir and
# the Keychain item name were namespaced by $$, two canaries_run calls
# running at the same time (two locked-build runs, or locked-build racing a
# friend's kit-selftest -- both normal on one machine) shared a single
# "$HOME/.routing-kit-canary" and Keychain item "routing-kit-canary". One
# call's own cleanup (its RETURN trap deletes the marker/Keychain item when
# ITS canaries_run returns) could delete the OTHER call's still-in-flight
# fixture, which surfaced as a plain "CANARY FAIL" -- indistinguishable from
# a genuine Seatbelt leak, and became locked-build's exit 5 ("lockdown
# failed") even though nothing ever leaked.
#
# This runs two REAL, separately-forked `bash` processes (not two subshells
# of this script: $$ is inherited from the parent across `( ... ) &`, so
# subshells here would share one pid and never exercise the per-pid
# namespacing at all) each running the full canary suite against its own
# wt/profile/port, started together so their setup/teardown windows
# overlap. Before the $$ namespacing fix this reproduced a spurious CANARY
# FAIL essentially every time two full runs genuinely overlapped; run
# several pairs to keep it that way as a real regression guard rather than
# a lucky one-shot.
conc_pairs=4
conc_any_fail=0
conc_i=1
while [ "$conc_i" -le "$conc_pairs" ]; do
  cd=$(mktmp)
  for side in a b; do
    side_dir="$cd/$side"
    mkdir -p "$side_dir/wt" "$side_dir/home" "$side_dir/cfg" "$side_dir/tmp"
    echo hello > "$side_dir/wt/a.txt"
    printf '#!/bin/bash\necho fake\n' > "$side_dir/claude-bin"
    chmod +x "$side_dir/claude-bin"
  done
  src_a="$(mktmp)"
  git -C "$src_a" init -q
  git -C "$src_a" config user.email you@example.com
  git -C "$src_a" config user.name "Test User"
  echo hello > "$src_a/a.txt"
  git -C "$src_a" add a.txt
  git -C "$src_a" commit -q -m init
  src_b="$(mktmp)"
  git -C "$src_b" init -q
  git -C "$src_b" config user.email you@example.com
  git -C "$src_b" config user.name "Test User"
  echo hello > "$src_b/a.txt"
  git -C "$src_b" add a.txt
  git -C "$src_b" commit -q -m init

  conc_runner="$cd/runner.sh"
  cat > "$conc_runner" <<RUNNER_EOF
#!/bin/bash
set -u
side_dir="\$1"; src="\$2"; out_file="\$3"; port="\$4"
. "$LIB_DIR/../bin/kit-common"
. "$LIB_DIR/seatbelt.sh"
. "$LIB_DIR/canaries.sh"
wt="\$(kit_realpath "\$side_dir/wt")"
run_home="\$(kit_realpath "\$side_dir/home")"
run_cfg="\$(kit_realpath "\$side_dir/cfg")"
run_tmp="\$(kit_realpath "\$side_dir/tmp")"
claude_bin="\$(kit_realpath "\$side_dir")/claude-bin"
profile="\$side_dir/profile.sb"
seatbelt_generate "\$profile" "\$wt" "\$run_home" "\$run_cfg" "\$run_tmp" "\$claude_bin" "\$port"
canaries_run "\$profile" "\$wt" "\$src" "\$port" full > "\$out_file" 2>&1
echo \$? >> "\$out_file.code"
RUNNER_EOF
  chmod +x "$conc_runner"

  # Fixed, widely-separated ports per side (not an OS-assigned bind(0) pick
  # per side, unlike production code): each canaries_run call also opens
  # stub listeners on port+1/port+2 for its own network probes, and two
  # independent bind(0)-then-close pickers running this close together can
  # coincide or collide under heavy, tight-loop ephemeral-port churn -- a
  # real but SEPARATE hazard from the one this test targets (see the
  # concurrency comment above). Fixed, far-apart blocks keep this
  # regression test focused on the real-$HOME/Keychain race being tested
  # here, not that unrelated port-reuse timing issue.
  port_a=$((21000 + conc_i * 10))
  port_b=$((26000 + conc_i * 10))

  bash "$conc_runner" "$cd/a" "$src_a" "$cd/a.out" "$port_a" &
  pid_a=$!
  bash "$conc_runner" "$cd/b" "$src_b" "$cd/b.out" "$port_b" &
  pid_b=$!
  wait "$pid_a"
  wait "$pid_b"

  code_a=$(cat "$cd/a.out.code" 2>/dev/null)
  code_b=$(cat "$cd/b.out.code" 2>/dev/null)
  out_a=$(cat "$cd/a.out" 2>/dev/null)
  out_b=$(cat "$cd/b.out" 2>/dev/null)

  if [ "$code_a" != 0 ] || [ "$code_b" != 0 ] \
     || printf '%s' "$out_a" | grep -q '^CANARY FAIL' \
     || printf '%s' "$out_b" | grep -q '^CANARY FAIL'; then
    conc_any_fail=1
    fail "concurrency pair $conc_i: a real-\$HOME fixture race between two concurrent canaries_run calls (code_a=$code_a code_b=$code_b); see $cd/a.out and $cd/b.out"
  fi
  conc_i=$((conc_i + 1))
done
if [ "$conc_any_fail" -eq 0 ]; then
  pass
fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
