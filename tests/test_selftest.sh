#!/bin/bash
# tests/test_selftest.sh -- bin/kit-selftest against fakes for every lane
# (codex, jules, kimi via locked-build) plus the real canary suite (real
# sandbox-exec, real generated Seatbelt profile) -- never a real provider,
# never the network.
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
SELFTEST="$PLUGIN_ROOT/bin/kit-selftest"

# This file must pass on real macOS AND real Ubuntu (WSL2 reports uname as
# Linux, so it rides the same path). The portable cases below (profile,
# routing table, kit-quota, codex, jules) run for real on either host;
# only the Seatbelt-jail-specific cases (kimi/glm via locked-build, and the
# real canary suite) are macOS-only and get skipped -- explicitly, per
# case, with a SKIP line -- on a real non-Darwin host, never by exiting
# this whole file early the way it used to.
ON_DARWIN=0
[ "$(uname)" = Darwin ] && ON_DARWIN=1

TEST_KEY="test-key-$$-$(date +%s)-$RANDOM"

write_profile() {
  # write_profile HOME codex jules kimi glm
  home_dir="$1"
  mkdir -p "$home_dir"
  printf '{"version":1,"claude_plan":"api","codex":"%s","jules":%s,"kimi":%s,"glm":false,"paseo":false}\n' \
    "$2" "$3" "$4" > "$home_dir/profile.json"
}

mk_fake_codex_ok() {
  bindir=$(mktmp)
  cat > "$bindir/codex" <<'EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "codex fake 0.0.0"
  exit 0
fi
cat >/dev/null
dir=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then dir="$a"; fi
  prev="$a"
done
[ -n "$dir" ] && echo hi > "$dir/hello.txt"
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

mk_fake_codex_broken() {
  bindir=$(mktmp)
  cat > "$bindir/codex" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

mk_fake_jules_ok() {
  bindir=$(mktmp)
  cat > "$bindir/jules" <<'EOF'
#!/bin/bash
echo "ID  AGE  STATUS"
exit 0
EOF
  chmod +x "$bindir/jules"
  echo "$bindir"
}

mk_fake_jules_broken() {
  bindir=$(mktmp)
  cat > "$bindir/jules" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$bindir/jules"
  echo "$bindir"
}

# a fake, native-shaped Claude binary for the kimi (locked-build) check --
# never actually calls the gate, so a throwaway upstream URL is enough.
mk_native_claude() {
  root=$(mktmp)
  versdir="$root/.local/share/claude/versions/9.9.9"
  mkdir -p "$versdir"
  bin="$versdir/claude"
  cat > "$bin" <<'EOF'
#!/bin/bash
cat >/dev/null
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
if [ "\$1" = "-s" ] && [ "\$2" = "routing-kit-kimi" ] && [ "\$3" = "-w" ]; then
  echo "$TEST_KEY"
  exit 0
fi
exit 44
EOF
  chmod +x "$script"
  echo "$script"
}

FAKE_UPSTREAM="http://127.0.0.1:1"

# --- 1. profile invalid -> FAIL profile, exit 2 -----------------------------
d=$(mktmp)
out=$(env ROUTING_KIT_HOME="$d" "$SELFTEST" 2>&1)
code=$?
assert_contains "$out" "profile: FAIL:" "no profile at all reports a FAIL on the profile line"
assert_eq 2 "$code" "no profile exits 2"

# --- 2. claude-only profile, no lanes on: profile/table/quota run for real
# on either host; canaries run for real on a Mac (real sandbox-exec) and
# print a plain SKIP on a real non-Darwin host instead. All-clear exits 0
# either way (a KNOWN-GAP canary probe must not turn a real Mac run into a
# failure, and a SKIP must not turn a real Linux run into one either). -----
d=$(mktmp)
write_profile "$d" none false false
out=$(env ROUTING_KIT_HOME="$d" "$SELFTEST" 2>&1)
code=$?
assert_eq 0 "$code" "claude-only profile, all real checks passing, exits 0"
assert_contains "$out" "profile: ok" "profile check passes"
assert_contains "$out" "routing table: ok" "routing table check passes"
assert_contains "$out" "kit-quota: ok" "kit-quota check passes"
if [ "$ON_DARWIN" -eq 1 ]; then
  assert_contains "$out" "canaries: ok" "canaries check passes on a real Mac"
  assert_contains "$out" "WARN: KNOWN-GAP" "the accepted command-line-read gap is surfaced as a WARN line on a real Mac"
else
  assert_contains "$out" "canaries: SKIP (macOS only)" "canaries is a plain SKIP on this real, non-macOS host"
fi
case "$out" in
  *"codex:"*) fail "codex line appeared even though codex is off in the profile" ;;
  *) pass ;;
esac
case "$out" in
  *"jules:"*) fail "jules line appeared even though jules is off in the profile" ;;
  *) pass ;;
esac
case "$out" in
  *"FAIL"*) fail "a claude-only, all-clear run must not print any FAIL line" ;;
  *) pass ;;
esac

# --- 3. codex on, fake codex succeeds: codex line is ok ----------------------
d=$(mktmp)
write_profile "$d" plus false false
codexbin=$(mk_fake_codex_ok)
out=$(env ROUTING_KIT_HOME="$d" PATH="$codexbin:$PATH" "$SELFTEST" 2>&1)
code=$?
assert_eq 0 "$code" "codex on with a working fake codex exits 0"
assert_contains "$out" "codex: ok" "codex check passes with a working fake codex"

# --- 4. codex on, no codex on PATH at all: FAIL, exit 3 ----------------------
d=$(mktmp)
write_profile "$d" plus false false
emptybin=$(mktmp)
out=$(env ROUTING_KIT_HOME="$d" PATH="$emptybin:/usr/bin:/bin:/usr/sbin:/sbin" "$SELFTEST" 2>&1)
code=$?
assert_contains "$out" "codex: FAIL:" "codex check fails when codex is not on PATH"
assert_contains "$out" "npm i -g @openai/codex" "the fix line tells the friend how to install codex"
assert_eq 3 "$code" "missing codex on PATH exits 3"

# --- 5. codex on, codex on PATH but --version fails: FAIL, exit 3 -----------
d=$(mktmp)
write_profile "$d" plus false false
brokencodex=$(mk_fake_codex_broken)
out=$(env ROUTING_KIT_HOME="$d" PATH="$brokencodex:$PATH" "$SELFTEST" 2>&1)
code=$?
assert_contains "$out" "codex: FAIL:" "codex check fails when codex --version fails"
assert_eq 3 "$code" "broken codex exits 3"

# --- 6. jules on, fake jules succeeds: jules line is ok ----------------------
d=$(mktmp)
write_profile "$d" none true false
julesbin=$(mk_fake_jules_ok)
out=$(env ROUTING_KIT_HOME="$d" PATH="$julesbin:$PATH" "$SELFTEST" 2>&1)
code=$?
assert_eq 0 "$code" "jules on with a working fake jules exits 0"
assert_contains "$out" "jules: ok" "jules check passes with a working fake jules"

# --- 7. jules on, jules not on PATH: FAIL, exit 3 ----------------------------
d=$(mktmp)
write_profile "$d" none true false
emptybin=$(mktmp)
out=$(env ROUTING_KIT_HOME="$d" PATH="$emptybin:/usr/bin:/bin:/usr/sbin:/sbin" "$SELFTEST" 2>&1)
code=$?
assert_contains "$out" "jules: FAIL:" "jules check fails when jules is not on PATH"
assert_contains "$out" "npm install -g @google/jules" "the fix line tells the friend how to install jules"
assert_eq 3 "$code" "missing jules on PATH exits 3"

# --- 8. jules on, jules present but 'remote list' fails: FAIL, exit 3 -------
d=$(mktmp)
write_profile "$d" none true false
brokenjules=$(mk_fake_jules_broken)
out=$(env ROUTING_KIT_HOME="$d" PATH="$brokenjules:$PATH" "$SELFTEST" 2>&1)
code=$?
assert_contains "$out" "jules: FAIL:" "jules check fails when jules remote list fails"
assert_eq 3 "$code" "broken jules exits 3"

# --- 9-12: kimi/glm and the real canary suite only ever run inside the
# macOS Seatbelt jail -- these cases need a real Mac and only run there.
# The Linux-side behavior (a plain SKIP for each, still exit 0) is covered
# for real in case 13 below, on whichever host actually runs this file. ----
if [ "$ON_DARWIN" -eq 1 ]; then

# --- 9. kimi on, everything faked through locked-build's own hooks: ok ------
d=$(mktmp)
write_profile "$d" none false true
claude_bin=$(mk_native_claude)
keychain=$(mk_fake_keychain_hit)
out=$(env ROUTING_KIT_HOME="$d" KIT_CLAUDE_BIN="$claude_bin" KIT_KEYCHAIN_CMD="$keychain" \
      KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" GATE_TEST_UPSTREAM_INSECURE=1 \
      "$SELFTEST" 2>&1)
code=$?
assert_eq 0 "$code" "kimi on with every dependency faked exits 0"
assert_contains "$out" "kimi: ok" "kimi check passes through a fully faked locked-build"

# --- 10. kimi on, no key in the fake keychain: FAIL, exit 3 -----------------
d=$(mktmp)
write_profile "$d" none false true
claude_bin=$(mk_native_claude)
missbin=$(mktmp)
cat > "$missbin/security" <<'EOF'
#!/bin/bash
exit 44
EOF
chmod +x "$missbin/security"
out=$(env ROUTING_KIT_HOME="$d" KIT_CLAUDE_BIN="$claude_bin" KIT_KEYCHAIN_CMD="$missbin/security" \
      KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" GATE_TEST_UPSTREAM_INSECURE=1 \
      "$SELFTEST" 2>&1)
code=$?
assert_contains "$out" "kimi: FAIL:" "kimi check fails when the keychain has no key"
assert_eq 3 "$code" "missing kimi key exits 3"

# --- 11. every lane on and faked to succeed at once: exit 0 ------------------
d=$(mktmp)
write_profile "$d" plus true true
codexbin=$(mk_fake_codex_ok)
julesbin=$(mk_fake_jules_ok)
claude_bin=$(mk_native_claude)
keychain=$(mk_fake_keychain_hit)
out=$(env ROUTING_KIT_HOME="$d" PATH="$codexbin:$julesbin:$PATH" \
      KIT_CLAUDE_BIN="$claude_bin" KIT_KEYCHAIN_CMD="$keychain" \
      KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" GATE_TEST_UPSTREAM_INSECURE=1 \
      "$SELFTEST" 2>&1)
code=$?
assert_eq 0 "$code" "every lane on and faked to succeed exits 0"
assert_contains "$out" "codex: ok" "all-lanes run: codex ok"
assert_contains "$out" "jules: ok" "all-lanes run: jules ok"
assert_contains "$out" "kimi: ok" "all-lanes run: kimi ok"
assert_contains "$out" "canaries: ok" "all-lanes run: canaries ok"

# --- 12. a fake canary "success" reading ~/.ssh must FAIL the whole run with
# lockdown, exit 5, even when every lane above would otherwise pass --------
d=$(mktmp)
write_profile "$d" plus true true
codexbin=$(mk_fake_codex_ok)
julesbin=$(mk_fake_jules_ok)
claude_bin=$(mk_native_claude)
keychain=$(mk_fake_keychain_hit)
out=$(env ROUTING_KIT_HOME="$d" PATH="$codexbin:$julesbin:$PATH" \
      KIT_CLAUDE_BIN="$claude_bin" KIT_KEYCHAIN_CMD="$keychain" \
      KIT_GATE_UPSTREAM="$FAKE_UPSTREAM" GATE_TEST_UPSTREAM_INSECURE=1 \
      KIT_CANARY_FORCE_SUCCEED="list .ssh" \
      "$SELFTEST" 2>&1)
code=$?
assert_eq 5 "$code" "a simulated ~/.ssh leak makes kit-selftest exit 5"
assert_contains "$out" "canaries: FAIL: the Kimi/GLM sandbox did not hold" "the canary failure gives a plain fix line"

fi # ON_DARWIN (cases 9-12)


# --- 13. what a real Linux/WSL2 friend would see: profile/routing-table/
# quota/codex/jules all still run for real (they're portable now), but
# kimi, glm and the canary suite -- all Seatbelt-jail-only -- print a plain
# SKIP line instead of trying to build a jail that doesn't exist there.
# Even with kimi written true directly into profile.json (bypassing
# kit-profile's own off-Mac refusal), the SKIP still wins over trying to
# run locked-build. Overall exit is 0: no lane actually failed.
#
# On a real non-Darwin host (Ubuntu CI) this runs directly against the
# real uname -- genuine Linux coverage, not a fake. On a real Mac, it
# fakes uname via PATH instead, the same technique the rest of this suite
# already uses for its other "non-macOS" cases, since there's no real
# Linux box to prove it against here. ---------------------------------------
if [ "$ON_DARWIN" -eq 1 ]; then
  fakeuname=$(mktmp)
  cat > "$fakeuname/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
  chmod +x "$fakeuname/uname"
  test13_path="$fakeuname:$PATH"
else
  test13_path="$PATH"
fi
d=$(mktmp)
write_profile "$d" plus true true
codexbin=$(mk_fake_codex_ok)
julesbin=$(mk_fake_jules_ok)
out=$(env ROUTING_KIT_HOME="$d" PATH="$codexbin:$julesbin:$test13_path" "$SELFTEST" 2>&1)
code=$?
assert_eq 0 "$code" "non-macOS (real or faked) kit-selftest exits 0 (codex/jules ok, kimi/canaries just skip)"
assert_contains "$out" "profile: ok" "non-macOS (real or faked) run: profile check still runs for real"
assert_contains "$out" "routing table: ok" "non-macOS (real or faked) run: routing table check still runs for real"
assert_contains "$out" "kit-quota: ok" "non-macOS (real or faked) run: kit-quota check still runs for real"
assert_contains "$out" "codex: ok" "non-macOS (real or faked) run: codex check still runs for real"
assert_contains "$out" "jules: ok" "non-macOS (real or faked) run: jules check still runs for real"
assert_contains "$out" "kimi: SKIP (macOS only)" "non-macOS (real or faked) run: kimi is a plain SKIP, not attempted"
assert_contains "$out" "glm: SKIP (macOS only)" "non-macOS (real or faked) run: glm is a plain SKIP, not attempted"
assert_contains "$out" "canaries: SKIP (macOS only)" "non-macOS (real or faked) run: canaries is a plain SKIP, not attempted"
case "$out" in
  *"FAIL"*) fail "a non-macOS run with only portable lanes on must not print any FAIL line" ;;
  *) pass ;;
esac

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
