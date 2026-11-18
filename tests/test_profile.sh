#!/bin/bash
. "$(dirname "$0")/lib.sh"
KP="$(dirname "$0")/../plugins/routing-kit/bin/kit-profile"

# get with no file -> exit 3, message contains START-HERE.md
d=$(mktmp)
out=$(ROUTING_KIT_HOME="$d" "$KP" get 2>&1)
code=$?
assert_eq 3 "$code" "get with no profile exits 3"
assert_contains "$out" "START-HERE.md" "no-profile message points at START-HERE.md"

# set codex plus then get -> JSON has "codex":"plus"
d=$(mktmp)
assert_exit 0 "set codex plus succeeds" -- env ROUTING_KIT_HOME="$d" "$KP" set codex plus
out=$(ROUTING_KIT_HOME="$d" "$KP" get)
got_codex=$(echo "$out" | /usr/bin/jq -r '.codex')
assert_eq "plus" "$got_codex" "get reflects set codex plus"

# set codex nonsense -> exit 2 and file unchanged
before=$(cat "$d/profile.json")
assert_exit 2 "set codex nonsense refused" -- env ROUTING_KIT_HOME="$d" "$KP" set codex nonsense
after=$(cat "$d/profile.json")
assert_eq "$before" "$after" "file unchanged after invalid set"

# set on a missing profile creates it with defaults; claude_plan must be
# set before validate passes
d=$(mktmp)
assert_exit 0 "set jules true on missing profile creates it" -- env ROUTING_KIT_HOME="$d" "$KP" set jules true
[ -f "$d/profile.json" ] || fail "profile.json was not created"
assert_exit 2 "validate fails before claude_plan is set" -- env ROUTING_KIT_HOME="$d" "$KP" validate
assert_exit 0 "set claude_plan pro" -- env ROUTING_KIT_HOME="$d" "$KP" set claude_plan pro
assert_exit 0 "validate passes once claude_plan is set" -- env ROUTING_KIT_HOME="$d" "$KP" validate

# the file is never half-written: no *.tmp remains after a set
d=$(mktmp)
env ROUTING_KIT_HOME="$d" "$KP" set claude_plan pro >/dev/null 2>&1
env ROUTING_KIT_HOME="$d" "$KP" set codex plus >/dev/null 2>&1
env ROUTING_KIT_HOME="$d" "$KP" set jules true >/dev/null 2>&1
leftover=$(find "$d" -name '*.tmp*' 2>/dev/null)
if [ -n "$leftover" ]; then
  fail "leftover tmp file(s) after set: $leftover"
else
  pass
fi

# validate must reject codex:false, not silently treat it as "none" via
# default substitution
d=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":false,"jules":false,"kimi":false,"glm":false,"paseo":false}' > "$d/profile.json"
assert_exit 2 "validate refuses codex:false" -- env ROUTING_KIT_HOME="$d" "$KP" validate

# a jq failure while writing must not leave a tmp file behind, and a
# failed set must exit 2
d=$(mktmp)
echo '{not json' > "$d/profile.json"
assert_exit 2 "set against malformed profile JSON refused" -- env ROUTING_KIT_HOME="$d" "$KP" set codex plus
leftover=$(find "$d" -name '*.tmp*' 2>/dev/null)
if [ -n "$leftover" ]; then
  fail "leftover tmp file after failed set: $leftover"
else
  pass
fi

# error diagnostics must name the key and say the value is invalid, never
# print the value itself (it may be a secret pasted by mistake). Built via
# adjacent-quote concatenation so this fixture secret never appears as a
# contiguous token in this source file (privacy-check would flag it).
d=$(mktmp)
secret_value="sk-""example-secret-token"
out=$(env ROUTING_KIT_HOME="$d" "$KP" set kimi "$secret_value" 2>&1)
assert_contains "$out" "kimi" "invalid-value error names the key"
case "$out" in
  *"example-secret-token"*) fail "kit-profile printed the invalid value to stderr" ;;
  *) pass ;;
esac


# jules_daily_limit: optional positive int, default stays 15 via kit-quota
# (see tests/test_quota.sh), not enforced here -- kit-profile only accepts
# or refuses the value.
d=$(mktmp)
assert_exit 0 "set claude_plan pro (jules_daily_limit fixture)" -- env ROUTING_KIT_HOME="$d" "$KP" set claude_plan pro
assert_exit 0 "set jules_daily_limit 20 succeeds" -- env ROUTING_KIT_HOME="$d" "$KP" set jules_daily_limit 20
out=$(ROUTING_KIT_HOME="$d" "$KP" get)
got_limit=$(echo "$out" | /usr/bin/jq -r '.jules_daily_limit')
assert_eq "20" "$got_limit" "get reflects set jules_daily_limit 20 as a number"
assert_exit 0 "validate passes with a valid jules_daily_limit" -- env ROUTING_KIT_HOME="$d" "$KP" validate

assert_exit 2 "set jules_daily_limit 0 refused" -- env ROUTING_KIT_HOME="$d" "$KP" set jules_daily_limit 0
assert_exit 2 "set jules_daily_limit -5 refused" -- env ROUTING_KIT_HOME="$d" "$KP" set jules_daily_limit -5
assert_exit 2 "set jules_daily_limit abc refused" -- env ROUTING_KIT_HOME="$d" "$KP" set jules_daily_limit abc

d=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"jules_daily_limit":0}' > "$d/profile.json"
assert_exit 2 "validate refuses jules_daily_limit:0 written directly to the file" -- env ROUTING_KIT_HOME="$d" "$KP" validate

d=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$d/profile.json"
assert_exit 0 "validate passes when jules_daily_limit is absent (defaults to 15)" -- env ROUTING_KIT_HOME="$d" "$KP" validate

# Kimi and GLM only ever run inside the macOS Seatbelt jail: on a faked
# Linux uname, `set kimi true` / `set glm true` must be refused with the
# same message locked-build itself gives, and the file must stay unchanged.
# Every other key (codex, jules, ...) must still work normally there.
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
d=$(mktmp)
out=$(env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$d" "$KP" set kimi true 2>&1)
code=$?
assert_eq 2 "$code" "set kimi true refused on a faked Linux uname"
assert_contains "$out" "Kimi and GLM need a Mac" "set kimi true on Linux gives the Kimi/GLM-needs-a-Mac message"
if [ -f "$d/profile.json" ]; then
  fail "kimi true on Linux must not create/modify profile.json"
else
  pass
fi

out=$(env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$d" "$KP" set glm true 2>&1)
code=$?
assert_eq 2 "$code" "set glm true refused on a faked Linux uname"
assert_contains "$out" "Kimi and GLM need a Mac" "set glm true on Linux gives the Kimi/GLM-needs-a-Mac message"

assert_exit 0 "set kimi false still works on a faked Linux uname" -- env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$d" "$KP" set kimi false
assert_exit 0 "set codex plus still works on a faked Linux uname" -- env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$d" "$KP" set codex plus

# Native Windows (no WSL) is not a supported system at all: any kit-profile
# call refuses, faked via a MINGW64_NT-shaped uname.
winbin=$(mktmp)
cat > "$winbin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0"
EOF
chmod +x "$winbin/uname"
dw=$(mktmp)
out=$(env PATH="$winbin:$PATH" ROUTING_KIT_HOME="$dw" "$KP" set codex plus 2>&1)
code=$?
assert_eq 2 "$code" "kit-profile refuses on a faked native-Windows uname"
assert_contains "$out" "routing-kit needs macOS, Linux, or WSL2 on Windows" "kit-profile prints the supported-systems message on native Windows"

# --- 0.3: main_agent ---------------------------------------------------------
d=$(mktmp)
env ROUTING_KIT_HOME="$d" "$KP" set claude_plan pro >/dev/null 2>&1
# A main agent whose lane is none is refused, with one clear line, and nothing changes.
before=$(cat "$d/profile.json")
out=$(env ROUTING_KIT_HOME="$d" "$KP" set main_agent gemini 2>&1); code=$?
assert_eq 2 "$code" "set main_agent gemini with gemini none exits non-zero"
assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "main_agent refusal is one line"
assert_contains "$out" "gemini" "main_agent refusal names the agent"
out=$(env ROUTING_KIT_HOME="$d" "$KP" set main_agent codex 2>&1); code=$?
assert_eq 2 "$code" "set main_agent codex with codex none exits non-zero"
assert_eq "$before" "$(cat "$d/profile.json")" "profile unchanged after a refused main_agent"
assert_exit 2 "set main_agent bogus refused" -- env ROUTING_KIT_HOME="$d" "$KP" set main_agent bogus
# claude is always allowed; with a lane it works.
assert_exit 0 "set main_agent claude" -- env ROUTING_KIT_HOME="$d" "$KP" set main_agent claude
env ROUTING_KIT_HOME="$d" "$KP" set codex plus >/dev/null 2>&1
assert_exit 0 "set main_agent codex with a Codex plan" -- env ROUTING_KIT_HOME="$d" "$KP" set main_agent codex
assert_eq codex "$(env ROUTING_KIT_HOME="$d" "$KP" get | /usr/bin/jq -r .main_agent)" "get reflects main_agent codex"
assert_exit 0 "validate passes with main_agent codex" -- env ROUTING_KIT_HOME="$d" "$KP" validate
# The lane under the main agent cannot be switched off from under it.
assert_exit 2 "set codex none refused while codex is the main agent" -- env ROUTING_KIT_HOME="$d" "$KP" set codex none
# claude_plan none is for users whose main agent is not Claude.
assert_exit 0 "claude_plan none allowed with a codex main agent" -- env ROUTING_KIT_HOME="$d" "$KP" set claude_plan none
assert_exit 0 "validate passes with claude_plan none and main codex" -- env ROUTING_KIT_HOME="$d" "$KP" validate
assert_exit 2 "set main_agent claude refused while claude_plan is none" -- env ROUTING_KIT_HOME="$d" "$KP" set main_agent claude
d2=$(mktmp)
assert_exit 2 "claude_plan none refused when the main agent is claude (absent)" -- env ROUTING_KIT_HOME="$d2" "$KP" set claude_plan none
# A hand-edited profile with an invalid main_agent fails validate.
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","main_agent":"nobody"}\n' > "$d2/profile.json"
assert_exit 2 "validate refuses main_agent nobody" -- env ROUTING_KIT_HOME="$d2" "$KP" validate
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","main_agent":"gemini"}\n' > "$d2/profile.json"
assert_exit 2 "validate refuses main_agent gemini with gemini none" -- env ROUTING_KIT_HOME="$d2" "$KP" validate
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none"}\n' > "$d2/profile.json"
assert_exit 0 "validate passes with main_agent absent" -- env ROUTING_KIT_HOME="$d2" "$KP" validate

# --- 0.4: skills (optional list of strings) ----------------------------------
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","skills":["/tmp/skill-a","/tmp/skill-b"]}\n' > "$d2/profile.json"
assert_exit 0 "validate passes with skills as list of strings" -- env ROUTING_KIT_HOME="$d2" "$KP" validate
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","skills":[123]}\n' > "$d2/profile.json"
assert_exit 2 "validate refuses non-string entry in skills" -- env ROUTING_KIT_HOME="$d2" "$KP" validate


d=$(mktmp)
env ROUTING_KIT_HOME="$d" "$KP" set claude_plan pro
for value in true false '{}' '{"destructive":true}' '{"owner_checkout":false}' '{"destructive":false,"owner_checkout":true}'; do
  assert_exit 0 "set blocks $value" -- env ROUTING_KIT_HOME="$d" "$KP" set blocks "$value"
  assert_eq "$value" "$(jq -c .blocks "$d/profile.json")" "blocks stored as JSON"
  assert_exit 0 "validate blocks $value" -- env ROUTING_KIT_HOME="$d" "$KP" validate
done
for value in null '[]' '"true"' '{"destructive":1}' '{"owner_checkout":null}'; do
  before=$(cat "$d/profile.json")
  assert_exit 2 "reject blocks $value" -- env ROUTING_KIT_HOME="$d" "$KP" set blocks "$value"
  assert_eq "$before" "$(cat "$d/profile.json")" "invalid blocks leaves file unchanged"
  jq --argjson v "$value" '.blocks=$v' "$d/profile.json" > "$d/invalid"
  cp "$d/invalid" "$d/profile.json"
  assert_exit 2 "validate rejects blocks $value" -- env ROUTING_KIT_HOME="$d" "$KP" validate
done
assert_exit 0 "owner name is accepted" -- env ROUTING_KIT_HOME="$d2" "$KP" set owner_name Alex
printf '{"version":1,"claude_plan":"pro","owner_name":12}\n' > "$d2/profile.json"
assert_exit 2 "owner name must be a string" -- env ROUTING_KIT_HOME="$d2" "$KP" validate

for key in claude_usage_db claude_resets_file; do
  assert_exit 0 "$key accepts path" -- env ROUTING_KIT_HOME="$d" "$KP" set "$key" "/tmp/usage data"
  assert_exit 2 "$key rejects empty" -- env ROUTING_KIT_HOME="$d" "$KP" set "$key" ""
done
for value in paseo direct; do
  assert_exit 0 "transport $value" -- env ROUTING_KIT_HOME="$d" "$KP" set codex_build_transport "$value"
done
assert_exit 2 "bad transport" -- env ROUTING_KIT_HOME="$d" "$KP" set codex_build_transport ssh
assert_exit 0 "positive daily limit" -- env ROUTING_KIT_HOME="$d" "$KP" set jules_daily_limit 12
for value in 0 -1 1.5 00; do
  assert_exit 2 "bad daily limit $value" -- env ROUTING_KIT_HOME="$d" "$KP" set jules_daily_limit "$value"
done
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
