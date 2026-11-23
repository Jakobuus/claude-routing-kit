#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
CHECK="$PLUGIN_ROOT/bin/kit-guide-check"

d=$(mktmp)
# Never read the caller's real kit folder (its profile or a pending-research marker would change every line).
export ROUTING_KIT_HOME="$d/kit" KIT_HOME="$d/kit"
mkdir -p "$ROUTING_KIT_HOME"
mkmodels() { # FILE CHECKED-VALUE-JSON
  printf '{"version":2,"checked":%s}\n' "$2" > "$1"
}
mkmodels "$d/m.json" '"2026-11-15"'

# 7 days after checked -> silent; 8 days -> the line with 8.
out=$("$CHECK" --models "$d/m.json" --today 2026-11-22); code=$?
assert_eq 0 "$code" "7 days: exit 0"
assert_eq "" "$out" "7 days after checked prints nothing"
out=$("$CHECK" --models "$d/m.json" --today 2026-11-15)
assert_eq "" "$out" "same day prints nothing"
out=$("$CHECK" --models "$d/m.json" --today 2026-11-01)
assert_eq "" "$out" "a checked date in the future prints nothing"
out=$("$CHECK" --models "$d/m.json" --today 2026-11-23); code=$?
assert_eq 0 "$code" "8 days: exit 0"
assert_eq "Routing guide is 8 days old. Update it: claude plugin update routing-kit@routing-kit" "$out" "8 days prints the exact line"
out=$("$CHECK" --models "$d/m.json" --today 2027-01-14)
assert_contains "$out" "Routing guide is 60 days old." "60 days counted across a year boundary"

# Codex and Gemini main agents get the git pull wording.
printf '{"version":1,"claude_plan":"pro","codex":"plus","main_agent":"codex"}\n' > "$d/p.json"
out=$("$CHECK" --models "$d/m.json" --profile "$d/p.json" --today 2026-11-23)
case "$out" in
  "Routing guide is 8 days old. Update it: git -C "*" pull") pass ;;
  *) fail "codex main agent gets the git pull line (got [$out])" ;;
esac
printf '{"version":1,"claude_plan":"pro","codex":"plus","main_agent":"claude"}\n' > "$d/p.json"
out=$("$CHECK" --models "$d/m.json" --profile "$d/p.json" --today 2026-11-23)
assert_contains "$out" "claude plugin update routing-kit@routing-kit" "claude main agent keeps the plugin update line"

# Unreadable dates.
mkmodels "$d/bad.json" '"not-a-date"'
out=$("$CHECK" --models "$d/bad.json" --today 2026-11-23); code=$?
assert_eq 0 "$code" "bad date: exit 0"
assert_eq "Routing guide date unreadable; reinstall the kit." "$out" "bad date message is exact"
mkmodels "$d/bad2.json" '"2026-13-45"'
out=$("$CHECK" --models "$d/bad2.json" --today 2026-11-23)
assert_eq "Routing guide date unreadable; reinstall the kit." "$out" "impossible date message"
printf '{"version":2}\n' > "$d/nokey.json"
out=$("$CHECK" --models "$d/nokey.json" --today 2026-11-23)
assert_eq "Routing guide date unreadable; reinstall the kit." "$out" "missing checked key message"
echo '{broken' > "$d/broken.json"
out=$("$CHECK" --models "$d/broken.json" --today 2026-11-23); code=$?
assert_eq 0 "$code" "broken models file: exit 0"
assert_eq "Routing guide date unreadable; reinstall the kit." "$out" "broken models file message"
out=$("$CHECK" --models "$d/nope.json" --today 2026-11-23); code=$?
assert_eq 0 "$code" "missing models file: exit 0"
assert_eq "Routing guide date unreadable; reinstall the kit." "$out" "missing models file message"
out=$("$CHECK" --models "$d/m.json" --today garbage); code=$?
assert_eq 0 "$code" "garbage --today: exit 0"
assert_eq "Routing guide date unreadable; reinstall the kit." "$out" "garbage --today message"

# KIT_GUIDE_TODAY is the test seam for the hook.
out=$(KIT_GUIDE_TODAY=2026-11-23 "$CHECK" --models "$d/m.json")
assert_contains "$out" "8 days old" "KIT_GUIDE_TODAY sets today"

# Real models.json, today = its own date: silent.
real_checked=$(jq -r .checked "$PLUGIN_ROOT/rules/models.json")
out=$("$CHECK" --today "$real_checked")
assert_eq "" "$out" "shipped models.json is fresh on its own checked date"

# Bare PATH.
out=$(env -i PATH=/usr/bin:/bin "$CHECK" --models "$d/m.json" --today 2026-11-23)
assert_contains "$out" "8 days old" "works with a bare PATH"

# --- release review: paths inside printed commands are shell-quoted -----------
q=$(mktmp)
for nm in 'kit with space' 'kit $(touch PWNED)' "owner's kit"; do
  kd="$q/$nm"; mkdir -p "$kd"; cp -R "$PLUGIN_ROOT" "$kd/"
  printf '{"version":1,"claude_plan":"pro","codex":"plus","main_agent":"codex"}\n' > "$q/p.json"
  out=$(cd "$q" && "$kd/routing-kit/bin/kit-guide-check" --models "$kd/routing-kit/rules/models.json" --profile "$q/p.json" --today 2099-01-01)
  cmd=${out#*Update it: }; cmd=${cmd#git }
  got=$(cd "$q" && sh -c "printf '%s\n' $cmd")
  assert_eq "-C
$kd/routing-kit
pull" "$got" "stale line: path '$nm' survives a shell"
  [ ! -e "$q/PWNED" ] && [ ! -e "$q/$nm/PWNED" ] && pass || fail "stale line ran a command from the path '$nm'"
done

# Pending research appears even while the guide is fresh; malformed markers are silent.
printf '{"date":"2026-11-20","changes":2,"command":"/tmp/Publish research.command"}' > "$ROUTING_KIT_HOME/research-pending.json"
out=$("$CHECK" --models "$d/m.json" --today 2026-11-15)
assert_eq "Model research waits for your click (2 change(s)): /tmp/Publish research.command" "$out" "pending research line"
printf '{broken' > "$ROUTING_KIT_HOME/research-pending.json"
out=$("$CHECK" --models "$d/m.json" --today 2026-11-15)
assert_eq "" "$out" "unreadable pending marker is silent"
rm "$ROUTING_KIT_HOME/research-pending.json"
out=$("$CHECK" --models "$d/m.json" --today 2026-11-15)
assert_eq "" "$out" "absent pending marker is silent"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
