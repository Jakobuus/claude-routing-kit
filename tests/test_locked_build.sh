#!/bin/bash
# tests/test_locked_build.sh -- bin/locked-build against a fake Claude, a
# fake keychain, and a fake upstream. Exercises every exit path without
# ever needing a real provider key or a real Claude binary.
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LOCKED_BUILD="$REPO_ROOT/plugins/routing-kit/bin/locked-build"

case "$(uname)" in
  Darwin) ;;
  *)
    echo "test_locked_build.sh: macOS only, skipping" >&2
    echo "PASS 0 / FAIL 0"
    exit 0
    ;;
esac

# The provider key must never be a literal in this source file (same
# discipline as tests/test_gate.sh): built at runtime from pid + timestamp.
TEST_KEY="test-key-$$-$(date +%s)-$RANDOM"

# --- shared fixtures ----------------------------------------------------

mk_src_repo() {
  d=$(mktmp)
  git -C "$d" init -q
  git -C "$d" config user.email you@example.com
  git -C "$d" config user.name "Test User"
  echo hello > "$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" commit -q -m init
  echo "$d"
}

# a fake, native-shaped Claude binary: readlink -f resolves under
# .../.local/share/claude/versions/<ver>/<bin>, exactly like the real one.
mk_native_claude() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir" "$root/.local/bin"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
env > .fake-claude-env-dump
echo "hello from fake claude" > hello-from-fake-claude.txt
printf '{"usage":{"input_tokens":11,"output_tokens":22}}\n'
EOF
  chmod +x "$bin"
  link="$root/.local/bin/claude"
  ln -s "$bin" "$link"
  echo "$link"
}

# item 7: a native claude that exits immediately but leaves a background
# child alive in its own process group -- must be killed within the
# script's grace period, before it ever gets to write late.txt. The child
# records its OWN pid (captured via $! right after backgrounding, into
# child.pid in cwd -- wt, an allowed writable path) and sleeps 60s, not 5s:
# a short sleep could complete on its own during the run's other overhead
# (canaries, gate start/stop) well before any check ran after locked-build
# returned, which made the old test structurally unable to fail even with
# the kill logic removed. 60s is long enough that only an actual kill (not
# the passage of time) can explain the child being dead afterward, and the
# check below asserts on that recorded pid directly with `kill -0`, not on
# a `pgrep -f` pattern tied to the sleep's duration.
mk_native_claude_leftover_child() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir" "$root/.local/bin"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
sh -c 'sleep 60; echo late > late.txt' &
echo "$!" > child.pid
disown
printf '{"usage":{"input_tokens":1,"output_tokens":1}}\n'
EOF
  chmod +x "$bin"
  link="$root/.local/bin/claude"
  ln -s "$bin" "$link"
  echo "$link"
}

# item 11: a native claude that exits non-zero.
mk_native_claude_nonzero() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir" "$root/.local/bin"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
printf '{"usage":{"input_tokens":1,"output_tokens":1}}\n'
exit 1
EOF
  chmod +x "$bin"
  link="$root/.local/bin/claude"
  ln -s "$bin" "$link"
  echo "$link"
}

# item 11: a native claude that never returns on its own -- only a timeout
# kill ends it.
mk_native_claude_hangs() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir" "$root/.local/bin"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
sleep 300
EOF
  chmod +x "$bin"
  link="$root/.local/bin/claude"
  ln -s "$bin" "$link"
  echo "$link"
}

# item 9: a native claude whose JSON output has no "usage" object at all.
mk_native_claude_no_usage() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir" "$root/.local/bin"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
printf '{}\n'
EOF
  chmod +x "$bin"
  link="$root/.local/bin/claude"
  ln -s "$bin" "$link"
  echo "$link"
}

# item 14: a native claude whose usage carries cache tokens that must be
# summed into the ledger's "in" column.
mk_native_claude_cache_tokens() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir" "$root/.local/bin"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
printf '{"usage":{"input_tokens":5,"output_tokens":9,"cache_read_input_tokens":30,"cache_creation_input_tokens":7}}\n'
EOF
  chmod +x "$bin"
  link="$root/.local/bin/claude"
  ln -s "$bin" "$link"
  echo "$link"
}

# item 5 (job-side fd test): a native claude that tries to read fd 8 and fd
# 10 directly -- fds this test opens on marker files BEFORE invoking
# locked-build, so they're inherited by the top-level `bash locked-build`
# process exactly the way a real caller's already-open fds would be. Reads
# with `cat <&8` / `cat <&10` (a dup of the fd itself), not `cat
# /dev/fd/N` -- the latter goes through Seatbelt's path-based file rules,
# which deny /dev/fd access regardless of whether the fd was ever closed,
# so it would pass even with kit_close_extra_fds removed. Writes what it
# saw (or the error) to fd-probe.txt in wt so the test can check it from
# outside. locked-build's own kit_close_extra_fds runs in the subshell
# right before it execs sandbox-exec, so by the time this fake claude
# actually runs, fds 8/10 must already be closed -- this is the job-side
# counterpart to tests/test_canaries.sh's canary-side fd 8/10 check (item 4
# there tests canaries_run's own jail; this tests the real job launch).
mk_native_claude_fd_probe() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir" "$root/.local/bin"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
{ cat <&8; echo "---"; cat <&10; } > fd-probe.txt 2>&1
printf '{"usage":{"input_tokens":1,"output_tokens":1}}\n'
EOF
  chmod +x "$bin"
  link="$root/.local/bin/claude"
  ln -s "$bin" "$link"
  echo "$link"
}

mk_non_native_claude() {
  d=$(mktmp)
  bin="$d/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
: > .fake-claude-called-marker
echo "should never run" > hello.txt
printf '{"usage":{"input_tokens":1,"output_tokens":1}}\n'
EOF
  chmod +x "$bin"
  echo "$bin"
}

mk_fake_keychain_hit() {
  d=$(mktmp)
  script="$d/security"
  cat > "$script" <<EOF
#!/bin/bash
# args: -s SERVICE -w
if [ "\$1" = "-s" ] && [ "\$2" = "routing-kit-\$PROVIDER_FOR_FAKE_KEYCHAIN" ] && [ "\$3" = "-w" ]; then
  echo "$TEST_KEY"
  exit 0
fi
exit 44
EOF
  chmod +x "$script"
  echo "$script"
}

mk_fake_keychain_miss() {
  d=$(mktmp)
  script="$d/security"
  cat > "$script" <<'EOF'
#!/bin/bash
exit 44
EOF
  chmod +x "$script"
  echo "$script"
}

write_profile() {
  home_dir="$1"; kimi_on="$2"
  mkdir -p "$home_dir"
  printf '{"version":1,"claude_plan":"api","codex":"none","jules":false,"kimi":%s,"glm":false,"paseo":false}\n' \
    "$kimi_on" > "$home_dir/profile.json"
}

# a throwaway upstream URL: nothing needs to actually answer it, since the
# fake Claude never calls the gate -- only its scheme must be valid and
# GATE_TEST_UPSTREAM_INSECURE=1 must be set for gate.py to accept http://.
FAKE_UPSTREAM="http://127.0.0.1:1"

run_locked_build() {
  # run_locked_build KIT_HOME CLAUDE_LINK KEYCHAIN_SCRIPT REPO NAME BRIEF [EXTRA_ENV...]
  kit_home="$1"; claude_link="$2"; keychain="$3"; repo="$4"; name="$5"; brief="$6"
  shift 6
  env ROUTING_KIT_HOME="$kit_home" \
      KIT_CLAUDE_BIN="$claude_link" \
      KIT_KEYCHAIN_CMD="$keychain" \
      PROVIDER_FOR_FAKE_KEYCHAIN="kimi" \
      KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" \
      GATE_TEST_UPSTREAM_INSECURE=1 \
      "$@" \
      bash "$LOCKED_BUILD" --provider kimi --repo "$repo" --name "$name" --brief "$brief"
}

brief_dir=$(mktmp)
BRIEF="$brief_dir/brief.md"
printf 'create hello.txt containing hi\n' > "$BRIEF"

claude_link=$(mk_native_claude)
keychain_hit=$(mk_fake_keychain_hit)
keychain_miss=$(mk_fake_keychain_miss)

# --- 1. provider off -> 2 ----------------------------------------------------
kit_home=$(mktmp)
write_profile "$kit_home" false
repo=$(mk_src_repo)
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run1 "$BRIEF" 2>&1)
code=$?
assert_eq 2 "$code" "provider off exits 2"
assert_contains "$out" "kimi" "provider-off message names the provider"

# --- 2. non-native claude -> 3 -----------------------------------------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
non_native=$(mk_non_native_claude)
out=$(run_locked_build "$kit_home" "$non_native" "$keychain_hit" "$repo" run2 "$BRIEF" 2>&1)
code=$?
assert_eq 3 "$code" "non-native claude exits 3"
assert_contains "$out" "native" "non-native message names the native install requirement"

# --- 3. no key -> 3, message names security add-generic-password ------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_miss" "$repo" run3 "$BRIEF" 2>&1)
code=$?
assert_eq 3 "$code" "missing key exits 3"
assert_contains "$out" "security add-generic-password" "missing-key message tells the user how to add it"
run_dir=$(find "$kit_home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -z "$run_dir" ] && pass || fail "missing key leaves an exported run dir behind"

# --- 4. dirty repo -> 2 -------------------------------------------------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
echo dirty >> "$repo/a.txt"
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run4 "$BRIEF" 2>&1)
code=$?
assert_eq 2 "$code" "dirty repo exits 2"

# --- 5. .env in wt -> 5, fake claude never called ----------------------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
printf 'SECRET=plain-value\n' > "$repo/.env"
git -C "$repo" add .env
git -C "$repo" commit -q -m "add env"
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run5 "$BRIEF" 2>&1)
code=$?
assert_eq 5 "$code" ".env in wt exits 5"
assert_contains "$out" "provider never contacted" "secret-scan refusal says the provider was never contacted"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run5*' 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "could not find the run5 run dir"
elif [ -f "$run_dir/wt/.fake-claude-called-marker" ]; then
  fail "fake claude was called despite the .env refusal"
else
  pass
fi

# --- 6. key in brief -> 5 -----------------------------------------------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
briefkey_dir=$(mktmp)
brief_with_key="$briefkey_dir/brief.md"
k="sk-""ant-api03-$(printf 'A%.0s' {1..24})"
printf 'notes\n\nkey: %s\n' "$k" > "$brief_with_key"
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run6 "$brief_with_key" 2>&1)
code=$?
assert_eq 5 "$code" "key in brief exits 5"
case "$out" in
  *"$k"*) fail "the key from the brief leaked into locked-build's output" ;;
  *) pass ;;
esac

# Locked providers retain the full privacy scan, including contact details.
private_brief_dir=$(mktmp); private_brief="$private_brief_dir/brief.md"
printf 'contact someone''@example.org in /Us''ers/example/project\n' > "$private_brief"
kit_home=$(mktmp); write_profile "$kit_home" true; repo=$(mk_src_repo)
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run-private "$private_brief" 2>&1)
assert_eq 5 "$?" "Kimi full scan refuses email and home path"

# --- Step 6 (known-bad record): a committed sk-ant- key in the repo itself,
# built at runtime so it's not a literal anywhere -> 5, no gate log ----------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
k2="sk-""ant-api03-$(printf 'B%.0s' {1..24})"
printf 'const key = "%s";\n' "$k2" > "$repo/config.js"
git -C "$repo" add config.js
git -C "$repo" commit -q -m "add config with key"
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" runbad "$BRIEF" 2>&1)
code=$?
assert_eq 5 "$code" "a committed key in the repo exits 5 (known-bad record)"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*runbad*' 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "could not find the runbad run dir"
elif [ -f "$run_dir/gate-stderr.log" ]; then
  fail "a gate log exists even though the secret scan should have refused before the gate ever started"
else
  pass
fi

# --- 7. a canary forced to "succeed" (a simulated leak) -> 5, gate never started
# A committed key must be refused by the scan even when Keychain has no key.
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
k3="sk-""ant-api03-$(printf 'C%.0s' {1..40})"
printf 'const key = "%s";\n' "$k3" > "$repo/config.js"
git -C "$repo" add config.js
git -C "$repo" commit -q -m "add test key"
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_miss" "$repo" run-no-key-scan "$BRIEF" 2>&1)
code=$?
assert_eq 5 "$code" "committed secret without Keychain key exits 5"
assert_contains "$out" "secret scan" "committed secret refusal names the scan"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run-no-key-scan*' 2>/dev/null | head -1)
if [ -n "$run_dir" ] && [ ! -e "$run_dir/gate-stderr.log" ] && [ ! -e "$run_dir/gate-port" ]; then
  pass
else
  fail "gate started despite secret scan refusal without a Keychain key"
fi

# --- 7. a canary forced to "succeed" (a simulated leak) -> 5, gate never started
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
out=$(KIT_CANARY_FORCE_SUCCEED="read real-home marker" \
      run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run7 "$BRIEF" 2>&1)
code=$?
assert_eq 5 "$code" "a caught canary leak exits 5"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run7*' 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "could not find the run7 run dir"
else
  if [ -f "$run_dir/gate-port" ]; then
    fail "the gate started even though a canary reported a leak"
  else
    pass
  fi
  if [ -f "$run_dir/wt/.fake-claude-called-marker" ]; then
    fail "fake claude was called despite the canary refusal"
  else
    pass
  fi
  if pgrep -f "gate.py.*$run_dir" >/dev/null 2>&1; then
    fail "a gate process is still running for the run7 refusal"
  else
    pass
  fi
fi

# --- 8/9. happy path -----------------------------------------------------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
out=$(run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run8 "$BRIEF" 2>&1)
code=$?
assert_eq 0 "$code" "happy path exits 0"
assert_contains "$out" "hello-from-fake-claude.txt" "the diff shows fake claude's new file"
assert_contains "$out" "run dir:" "the run dir is printed"

run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run8*' 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "could not find the run8 run dir"
else
  env_dump="$run_dir/wt/.fake-claude-env-dump"
  if [ -f "$env_dump" ]; then
    envtext=$(cat "$env_dump")
    assert_contains "$envtext" "ANTHROPIC_BASE_URL=http://127.0.0.1:" "fake claude saw a loopback ANTHROPIC_BASE_URL"
    assert_contains "$envtext" "ANTHROPIC_AUTH_TOKEN=routing-kit-placeholder" "fake claude saw the placeholder token, not the real key"
    assert_contains "$envtext" "HOME=$run_dir/home" "fake claude's HOME is under the run dir"
    assert_contains "$envtext" "TMPDIR=$run_dir/tmp" "fake claude's TMPDIR is under the run dir"
    assert_contains "$envtext" "ANTHROPIC_MODEL=" "fake claude saw ANTHROPIC_MODEL"
    assert_contains "$envtext" "ANTHROPIC_DEFAULT_HAIKU_MODEL=" "fake claude saw ANTHROPIC_DEFAULT_HAIKU_MODEL (item 19)"
    assert_contains "$envtext" "CLAUDE_CONFIG_DIR=$run_dir/cfg" "fake claude's CLAUDE_CONFIG_DIR is under the run dir"
    assert_contains "$envtext" "CLAUDE_CODE_TMPDIR=$run_dir/tmp" "fake claude's CLAUDE_CODE_TMPDIR is under the run dir (item 2)"
    assert_contains "$envtext" "PATH=/usr/bin:/bin" "fake claude saw the minimal PATH"
    assert_contains "$envtext" "DISABLE_TELEMETRY=1" "fake claude saw DISABLE_TELEMETRY"
    assert_contains "$envtext" "DISABLE_ERROR_REPORTING=1" "fake claude saw DISABLE_ERROR_REPORTING"
    assert_contains "$envtext" "DISABLE_AUTOUPDATER=1" "fake claude saw DISABLE_AUTOUPDATER"
    case "$envtext" in
      *"$TEST_KEY"*) fail "the real key appears in fake claude's env dump" ;;
      *) pass ;;
    esac
    # The env is exactly the plan's list (plus item 19's var) plus what
    # `env -i .../env ...` and the shell itself always add on top (PWD,
    # SHLVL, _) -- nothing else. A dropped env -i, or a stray extra
    # variable (e.g. a leaked host var), would add a key outside this set.
    allowed_keys="HOME TMPDIR CLAUDE_CONFIG_DIR CLAUDE_CODE_TMPDIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL PATH DISABLE_TELEMETRY DISABLE_ERROR_REPORTING DISABLE_AUTOUPDATER PWD SHLVL _"
    extra_keys=""
    while IFS='=' read -r k _v; do
      [ -n "$k" ] || continue
      case " $allowed_keys " in
        *" $k "*) : ;;
        *) extra_keys="$extra_keys $k" ;;
      esac
    done <<EOF_ENV
$envtext
EOF_ENV
    assert_eq "" "$extra_keys" "the jail env has no keys outside the plan's list"
  else
    fail "fake claude's env dump was not written"
  fi

  ledger="$kit_home/ledger.tsv"
  if [ -f "$ledger" ]; then
    ledger_line=$(grep -F "run8" "$ledger")
    line_count=$(printf '%s\n' "$ledger_line" | grep -c .)
    assert_eq 1 "$line_count" "exactly one ledger line for run8"
    # The fake claude prints usage 11/22 -- the ledger's in/out columns
    # (fields 5 and 6 of the tab-separated line) must actually carry those
    # numbers, not just "some line mentioning run8" (a parser that always
    # wrote "-" would still pass a line-count-only check).
    ledger_in=$(printf '%s\n' "$ledger_line" | cut -f5)
    ledger_out=$(printf '%s\n' "$ledger_line" | cut -f6)
    assert_eq 11 "$ledger_in" "ledger input-token column shows fake claude's 11"
    assert_eq 22 "$ledger_out" "ledger output-token column shows fake claude's 22"
    ledger_provider=$(printf '%s\n' "$ledger_line" | cut -f8)
    ledger_cost=$(printf '%s\n' "$ledger_line" | cut -f9)
    assert_eq kimi "$ledger_provider" "ledger attributes the run to Kimi"
    assert_eq 0.000098 "$ledger_cost" "cost uses models.json prices (11 in x 0.95 + 22 out x 4.00 per M), fixed decimals"
  else
    fail "no ledger.tsv was written"
  fi

  # --- item 23: the gate process is dead after this (successful) exit --------
  if pgrep -f "gate.py.*$run_dir" >/dev/null 2>&1; then
    fail "a gate process is still running after the happy path exited"
  else
    pass
  fi
fi

# --- item 8: no bash job-control notice ("Terminated: 15 ...") on stderr,
# from killing the timer/claude process groups after this normal exit -----
case "$out" in
  *"Terminated:"*) fail "a bash job-control notice ('Terminated: ...') leaked onto stderr" ;;
  *) pass ;;
esac

# --- the real key never appears anywhere observable --------------------------
case "$out" in
  *"$TEST_KEY"*) fail "the real key appears in locked-build's stdout/stderr" ;;
  *) pass ;;
esac
if [ -n "$run_dir" ] && grep -r -F -- "$TEST_KEY" "$run_dir" >/dev/null 2>&1; then
  fail "the real key appears somewhere under the run dir"
else
  pass
fi
if [ -f "$kit_home/ledger.tsv" ] && grep -F -- "$TEST_KEY" "$kit_home/ledger.tsv" >/dev/null 2>&1; then
  fail "the real key appears in the ledger"
else
  pass
fi

# --- item 22: path validation (a seatbelt profile can't embed these safely) --
SEATBELT_SH="$REPO_ROOT/plugins/routing-kit/lib/seatbelt.sh"
mk_seatbelt_fixture() {
  d=$(mktmp)
  mkdir -p "$d/wt" "$d/home" "$d/cfg" "$d/tmp"
  printf '#!/bin/bash\ntrue\n' > "$d/claude"
  chmod +x "$d/claude"
  echo "$d"
}
d=$(mk_seatbelt_fixture)
assert_exit 2 'a double quote in a path exits 2' -- \
  bash -c ". \"$SEATBELT_SH\"; seatbelt_generate \"$d/out.sb\" '$d/wt\"evil' \"$d/home\" \"$d/cfg\" \"$d/tmp\" \"$d/claude\" 18888"
d=$(mk_seatbelt_fixture)
assert_exit 2 'a backslash in a path exits 2' -- \
  bash -c ". \"$SEATBELT_SH\"; seatbelt_generate \"$d/out.sb\" '$d/wt\\\\evil' \"$d/home\" \"$d/cfg\" \"$d/tmp\" \"$d/claude\" 18888"
d=$(mk_seatbelt_fixture)
nl_path="$d/wt
evil"
assert_exit 2 'a newline in a path exits 2' -- \
  bash -c ". \"$SEATBELT_SH\"; seatbelt_generate \"$d/out.sb\" \"\$1\" \"$d/home\" \"$d/cfg\" \"$d/tmp\" \"$d/claude\" 18888" -- "$nl_path"

# --- item 7: a background child claude leaves behind must be killed before
# the diff, and must never get to write late.txt -----------------------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
leftover_claude=$(mk_native_claude_leftover_child)
out=$(run_locked_build "$kit_home" "$leftover_claude" "$keychain_hit" "$repo" run-item7 "$BRIEF" 2>&1)
code=$?
assert_eq 0 "$code" "item 7: fake claude with a leftover background child still exits 0 itself"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run-item7*' 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "item 7: could not find the run dir"
else
  case "$out" in
    *late.txt*) fail "item 7: late.txt appears in the diff -- the background child was not killed in time" ;;
    *) pass ;;
  esac
  if [ -e "$run_dir/wt/late.txt" ]; then
    fail "item 7: late.txt was created after locked-build exited -- the background child survived"
  else
    pass
  fi
  # The child records its own pid (captured via $! right after
  # backgrounding) into child.pid in wt. locked-build's group kill runs
  # BEFORE it returns, so the recorded pid must already be dead by now --
  # no sleep/grace period needed here, unlike the old pgrep-on-a-sleep-
  # duration check this replaces (see the fixture's own comment: a 60s
  # sleep can't have completed on its own, so a dead pid here can only mean
  # the kill actually happened).
  child_pid_file="$run_dir/wt/child.pid"
  if [ -f "$child_pid_file" ]; then
    child_pid=$(cat "$child_pid_file")
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
      fail "item 7: the leftover child (pid $child_pid) is still alive after locked-build exited"
    else
      pass
    fi
  else
    fail "item 7: child.pid was never written by the fake claude"
  fi
fi

# --- item 11: Claude exits non-zero -> locked-build exits 4 -----------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
nonzero_claude=$(mk_native_claude_nonzero)
out=$(run_locked_build "$kit_home" "$nonzero_claude" "$keychain_hit" "$repo" run-item11a "$BRIEF" 2>&1)
code=$?
assert_eq 4 "$code" "item 11: a non-zero Claude exit becomes locked-build exit 4"

# --- item 11: a Claude that never returns -> the timeout kills it, exit 4 ---
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
hang_claude=$(mk_native_claude_hangs)
out=$(timeout 30 env ROUTING_KIT_HOME="$kit_home" \
      KIT_CLAUDE_BIN="$hang_claude" \
      KIT_KEYCHAIN_CMD="$keychain_hit" \
      PROVIDER_FOR_FAKE_KEYCHAIN="kimi" \
      KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" \
      GATE_TEST_UPSTREAM_INSECURE=1 \
      bash "$LOCKED_BUILD" --provider kimi --repo "$repo" --name run-item11b --brief "$BRIEF" --timeout 2 2>&1)
code=$?
assert_eq 4 "$code" "item 11: a Claude that never returns is timed out and exits 4, without hanging the caller"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run-item11b*' 2>/dev/null | head -1)
if [ -n "$run_dir" ] && pgrep -f "gate.py.*$run_dir" >/dev/null 2>&1; then
  fail "item 17: the gate is still running after the timeout (exit 4) path"
else
  pass
fi
# item 7 (continued): a bash job-control notice ("Terminated: 15 ...") must
# not leak onto stderr on the TIMEOUT path either -- the happy-path check
# elsewhere in this file only ever exercised a normal exit, which never
# triggers this notice; the timer's own SIGTERM to a still-running claude
# job is what makes bash print it, from the `wait "$claude_pid"` line.
case "$out" in
  *"Terminated:"*) fail "item 7: a bash job-control notice ('Terminated: ...') leaked onto stderr on the timeout path" ;;
  *) pass ;;
esac

# --- item 10: the last flag with no value exits 2 without hanging -----------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
out=$(timeout 10 env ROUTING_KIT_HOME="$kit_home" \
      KIT_CLAUDE_BIN="$claude_link" \
      KIT_KEYCHAIN_CMD="$keychain_hit" \
      PROVIDER_FOR_FAKE_KEYCHAIN="kimi" \
      bash "$LOCKED_BUILD" --provider kimi --repo "$repo" --name run-item10 --brief 2>&1)
code=$?
assert_eq 2 "$code" "item 10: a trailing flag with no value exits 2, not a hang"

# --- item 12: --timeout 0 / --timeout abc both exit 2 ------------------------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
out=$(env ROUTING_KIT_HOME="$kit_home" KIT_CLAUDE_BIN="$claude_link" KIT_KEYCHAIN_CMD="$keychain_hit" \
      PROVIDER_FOR_FAKE_KEYCHAIN="kimi" KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" GATE_TEST_UPSTREAM_INSECURE=1 \
      bash "$LOCKED_BUILD" --provider kimi --repo "$repo" --name run-item12a --brief "$BRIEF" --timeout 0 2>&1)
code=$?
assert_eq 2 "$code" "item 12: --timeout 0 exits 2"
out=$(env ROUTING_KIT_HOME="$kit_home" KIT_CLAUDE_BIN="$claude_link" KIT_KEYCHAIN_CMD="$keychain_hit" \
      PROVIDER_FOR_FAKE_KEYCHAIN="kimi" KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" GATE_TEST_UPSTREAM_INSECURE=1 \
      bash "$LOCKED_BUILD" --provider kimi --repo "$repo" --name run-item12b --brief "$BRIEF" --timeout abc 2>&1)
code=$?
assert_eq 2 "$code" "item 12: --timeout abc exits 2"

# --- item 13: a relative --repo works, not refused as a lockdown failure ----
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
repo_parent=$(dirname "$repo")
repo_base=$(basename "$repo")
out=$(
  cd "$repo_parent" && \
  env ROUTING_KIT_HOME="$kit_home" KIT_CLAUDE_BIN="$claude_link" KIT_KEYCHAIN_CMD="$keychain_hit" \
      PROVIDER_FOR_FAKE_KEYCHAIN="kimi" KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" GATE_TEST_UPSTREAM_INSECURE=1 \
      bash "$LOCKED_BUILD" --provider kimi --repo "$repo_base" --name run-item13 --brief "$BRIEF" 2>&1
)
code=$?
assert_eq 0 "$code" "item 13: a relative --repo (resolved against the caller's cwd) still works"

# --- item 14: cache tokens are summed into the ledger's "in" column ---------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
cache_claude=$(mk_native_claude_cache_tokens)
out=$(run_locked_build "$kit_home" "$cache_claude" "$keychain_hit" "$repo" run-item14 "$BRIEF" 2>&1)
code=$?
assert_eq 0 "$code" "item 14: cache-token happy path exits 0"
ledger="$kit_home/ledger.tsv"
if [ -f "$ledger" ]; then
  ledger_line=$(grep -F "run-item14" "$ledger")
  ledger_in=$(printf '%s\n' "$ledger_line" | cut -f5)
  # fake claude: input_tokens=5, cache_read_input_tokens=30,
  # cache_creation_input_tokens=7 -> 5+30+7=42
  assert_eq 42 "$ledger_in" "item 14: the ledger's 'in' column sums input + both cache token fields (42)"
else
  fail "item 14: no ledger.tsv was written"
fi

# --- item 9: no "usage" object at all -> ledger writes "-", not "0" --------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
no_usage_claude=$(mk_native_claude_no_usage)
out=$(run_locked_build "$kit_home" "$no_usage_claude" "$keychain_hit" "$repo" run-item9 "$BRIEF" 2>&1)
code=$?
assert_eq 0 "$code" "item 9: no-usage happy path exits 0"
ledger="$kit_home/ledger.tsv"
if [ -f "$ledger" ]; then
  ledger_line=$(grep -F "run-item9" "$ledger")
  ledger_in=$(printf '%s\n' "$ledger_line" | cut -f5)
  ledger_out=$(printf '%s\n' "$ledger_line" | cut -f6)
  assert_eq "-" "$ledger_in" "item 9: ledger 'in' column is '-' when Claude's output has no usage object"
  assert_eq "-" "$ledger_out" "item 9: ledger 'out' column is '-' when Claude's output has no usage object"
else
  fail "item 9: no ledger.tsv was written"
fi

# --- item 15: no USER in the environment -> the canaries still run ----------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
out=$(env -u USER ROUTING_KIT_HOME="$kit_home" \
      KIT_CLAUDE_BIN="$claude_link" \
      KIT_KEYCHAIN_CMD="$keychain_hit" \
      PROVIDER_FOR_FAKE_KEYCHAIN="kimi" \
      KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" \
      GATE_TEST_UPSTREAM_INSECURE=1 \
      bash "$LOCKED_BUILD" --provider kimi --repo "$repo" --name run-item15 --brief "$BRIEF" 2>&1)
code=$?
assert_eq 0 "$code" "item 15: locked-build still succeeds with no USER in the environment"
assert_contains "$out" "CANARY SUMMARY" "item 15: the canaries still ran with no USER in the environment"

# --- item 16/17: a canary forced to "succeed" ONLY on the SECOND
# (final-profile) canaries_run call -> 5, Claude never called, and (unlike
# the old run7 check, which could never fail because the gate hadn't even
# started yet) the gate really is up by this point and must be killed ------
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
out=$(KIT_CANARY_FORCE_SUCCEED="read real-home marker" \
      KIT_CANARY_FORCE_SUCCEED_CALL=2 \
      run_locked_build "$kit_home" "$claude_link" "$keychain_hit" "$repo" run-item16 "$BRIEF" 2>&1)
code=$?
assert_eq 5 "$code" "item 16: a leak caught only on the final-profile canary run exits 5"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run-item16*' 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "item 16: could not find the run dir"
else
  if [ -f "$run_dir/wt/.fake-claude-called-marker" ]; then
    fail "item 16: fake claude was called despite the final-profile canary refusal"
  else
    pass
  fi
  # The gate DOES start before the final canaries run (Step 8 happens
  # before Step 8.5's final canary check) -- this is the meaningful version
  # of the old run7 check, which could never fail because its canary was
  # forced to leak before the gate ever started.
  if [ -f "$run_dir/gate-port" ]; then
    pass
  else
    fail "item 16: expected the gate to have started before the final-profile canary ran"
  fi
  if pgrep -f "gate.py.*$run_dir" >/dev/null 2>&1; then
    fail "item 17: the gate is still running after the final-profile canary refusal (exit 5)"
  else
    pass
  fi
fi

# --- item 5: job-side fd test -- fds 8 and 10, open on marker files in
# THIS shell before locked-build ever starts, must not be readable by the
# real fake-claude job (mirrors test_canaries.sh's KIT_CANARY_TEST_FDS
# check, but against the actual job launch path, not the canary jail) -----
kit_home=$(mktmp)
write_profile "$kit_home" true
repo=$(mk_src_repo)
fd_probe_claude=$(mk_native_claude_fd_probe)
fd_marker_dir=$(mktmp)
printf 'fd8-secret-marker\n' > "$fd_marker_dir/fd8"
printf 'fd10-secret-marker\n' > "$fd_marker_dir/fd10"
exec 8< "$fd_marker_dir/fd8"
exec 10< "$fd_marker_dir/fd10"
out=$(run_locked_build "$kit_home" "$fd_probe_claude" "$keychain_hit" "$repo" run-item5fd "$BRIEF" 2>&1)
code=$?
exec 8<&-
exec 10<&-
assert_eq 0 "$code" "item 5: fd-probe happy path exits 0"
run_dir=$(find "$kit_home/runs" -maxdepth 1 -name '*run-item5fd*' 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "item 5: could not find the run dir"
else
  probe_file="$run_dir/wt/fd-probe.txt"
  if [ -f "$probe_file" ]; then
    probe_out=$(cat "$probe_file")
    case "$probe_out" in
      *"fd8-secret-marker"*) fail "item 5: the real job read the inherited fd 8 marker: $probe_out" ;;
      *"Bad file descriptor"*) pass ;;
      *) fail "item 5: fd 8 was not reported closed (expected 'Bad file descriptor'): $probe_out" ;;
    esac
    case "$probe_out" in
      *"fd10-secret-marker"*) fail "item 5: the real job read the inherited fd 10 marker: $probe_out" ;;
      *) pass ;;
    esac
    # both reads must independently report a closed fd -- a single "Bad
    # file descriptor" in the combined output could come from just one of
    # the two `cat` calls (bash 3.2's `cat <&N` failure message is
    # identical for both fds), so count occurrences rather than doing a
    # single substring check.
    bad_fd_count=$(printf '%s\n' "$probe_out" | grep -c "Bad file descriptor")
    if [ "$bad_fd_count" -ge 2 ]; then
      pass
    else
      fail "item 5: expected 'Bad file descriptor' twice (once per fd), got $bad_fd_count: $probe_out"
    fi
  else
    fail "item 5: fd-probe.txt was never written by the fake claude"
  fi
fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
