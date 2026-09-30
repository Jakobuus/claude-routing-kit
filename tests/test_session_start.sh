#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
HOOK="$PLUGIN_ROOT/hooks/session-start"

mkprofile() {
  # mkprofile FILE claude_plan codex jules kimi glm paseo
  printf '{"version":1,"claude_plan":"%s","codex":"%s","jules":%s,"kimi":%s,"glm":%s,"paseo":%s}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$1"
}

# (a) valid profile -> stdout contains "# Rules" and "## Your routing table", exit 0
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "valid profile exits 0"
assert_contains "$out" "# Rules" "valid profile output has # Rules"
assert_contains "$out" "## Your routing table" "valid profile output has routing table heading"
for lane in Codex Jules Kimi GLM; do
  lower=$(printf '%s' "$lane" | tr '[:upper:]' '[:lower:]')
  case "$out" in *"$lane"*|*"$lower"*) fail "disabled $lane appears in rules";; *) pass;; esac
done

# Each lane disappears on its own while the other three remain enabled.
for lane in codex jules kimi glm; do
  d=$(mktmp); mkdir -p "$d/.config/routing-kit"
  codex=plus; jules=true; kimi=true; glm=true
  case "$lane" in
    codex) codex=none;; jules) jules=false;; kimi) kimi=false;; glm) glm=false;;
  esac
  mkprofile "$d/.config/routing-kit/profile.json" pro "$codex" "$jules" "$kimi" "$glm" false
  out=$(ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
  cap=$(printf '%s' "$lane" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  [ "$lane" = glm ] && cap=GLM
  case "$out" in *"$cap"*|*"$lane"*) fail "individually disabled $lane appears in hook output";; *) pass;; esac
done

# (b) no profile -> the not-set-up line only, exit 0
d=$(mktmp)
out=$(env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "no profile exits 0"
assert_eq "routing-kit is installed but not set up yet. Drop START-HERE.md into Claude to finish setup." "$out" "no-profile message is exact"

# (c) broken profile JSON -> contains "rules did not load", exit 0
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
echo '{not json' > "$d/.config/routing-kit/profile.json"
out=$(env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "broken profile exits 0"
assert_contains "$out" "rules did not load" "broken profile reports rules did not load"

# (d) output length <= 9000 for the largest profile (all lanes on).
# Assert the output actually contains the routing table (not the short
# repair line, which would trivially satisfy a length check and mask a
# real failure to inject rules), and measure length without stripping the
# trailing newline that command substitution would otherwise eat.
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" max20 api true true true true
outfile="$d/hook.out"
env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK" > "$outfile"
code=$?
assert_eq 0 "$code" "largest profile exits 0"
out=$(cat "$outfile")
assert_contains "$out" "## Your routing table" "largest profile output actually has the routing table, not the repair line"
len=$(wc -c < "$outfile" | tr -d ' ')
if [ "$len" -le 9000 ]; then
  pass
else
  fail "largest-profile output is $len chars, over the 9000 cap"
fi

# (e) runs with env -i PATH=/usr/bin:/bin HOME=$tmp (the bare PATH Paseo can give)
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env -i PATH=/usr/bin:/bin HOME="$d" ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "bare PATH run exits 0"
assert_contains "$out" "## Your routing table" "bare PATH run still produces the table"

# (f) Linux (and WSL2, which reports uname as Linux) is a supported system:
# a fake `uname` that prints Linux must still produce the normal routing
# table, not the old macOS-only refusal.
d=$(mktmp)
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "faked-Linux hook exits 0"
assert_contains "$out" "## Your routing table" "faked-Linux hook still produces the table"

# (g) native Windows (no WSL): a session must never be blocked either, but
# it's not a supported system -- fake a MINGW64_NT-shaped uname (what
# git-bash reports) and check the hook prints exactly the one-line
# unsupported-system message and exits 0 (not exit 2).
d=$(mktmp)
winbin=$(mktmp)
cat > "$winbin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0"
EOF
chmod +x "$winbin/uname"
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env PATH="$winbin:$PATH" ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "native-Windows hook exits 0"
assert_eq "routing-kit needs macOS, Linux, or WSL2 on Windows; rules not loaded." "$out" "native-Windows hook prints the exact one-line message"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
