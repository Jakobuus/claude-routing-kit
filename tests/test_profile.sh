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

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
