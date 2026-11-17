#!/bin/bash
# State M: contract tests for the forthcoming picker and reset bank.
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
QUOTA="$ROOT/plugins/routing-kit/bin/kit-quota"
TABLE="$ROOT/plugins/routing-kit/bin/kit-routing-table"
MODELS="$ROOT/plugins/routing-kit/rules/models.json"
SANDBOX=$(mktmp)
export HOME="$SANDBOX" ROUTING_KIT_HOME="$SANDBOX/kit" CODEX_HOME="$SANDBOX/codex"
mkdir -p "$ROUTING_KIT_HOME" "$CODEX_HOME/sessions/2026/11/17" "$SANDBOX/bin"
for cli in paseo codex claude agy jules; do
  printf '#!/bin/bash\nexit 4\n' > "$SANDBOX/bin/$cli"
  chmod +x "$SANDBOX/bin/$cli"
done
export PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
printf '{"version":1,"claude_plan":"max20","codex":"pro","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$ROUTING_KIT_HOME/profile.json"
NOW=$(date +%s)
# Match test_quota.sh: feed the same cache/session fixtures used by --json.
# Half a week remaining makes pace twice used percentage, without a clock stub.
quota_fixture() {
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s},"sampled":%s}\n' "$1" "$((NOW+9000))" "$2" "$((NOW+302400))" "$((NOW-$5))" > "$ROUTING_KIT_HOME/claude-limits.json"
  printf '{"rate_limits":{"primary":{"used_percent":%s,"resets_at":%s,"window_minutes":300},"secondary":{"used_percent":%s,"resets_at":%s,"window_minutes":10080}}}\n' "$3" "$((NOW+9000))" "$4" "$((NOW+302400))" > "$CODEX_HOME/sessions/2026/11/17/rollout-test.jsonl"
}
pick() {
  label=$1; want=$2; job=$3
  out=$("$QUOTA" --pick "$job" 2>"$SANDBOX/err"); rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then pass; else fail "$label (exit $rc; expected $want, got $out)"; fi
}
quota_fixture 10 10 10 30 0
pick 'lowest weekly pace wins even below 100%' sonnet 'Features, bug fixes, tests'
quota_fixture 10 40 10 10 0
pick 'lower Codex pace wins' gpt-6.1-sol 'Features, bug fixes, tests'
quota_fixture 81 1 10 30 0
pick 'skip Claude five-hour window over 80%' gpt-6.1-sol 'Features, bug fixes, tests'
quota_fixture 80 1 10 30 0
pick '80% five-hour window remains eligible' sonnet 'Features, bug fixes, tests'
quota_fixture 10 1 81 30 25200
pick 'skip stale Claude reading' gpt-6.1-sol 'Features, bug fixes, tests'
quota_fixture 10 1 10 40 0
pick 'quality list excludes cheap build from UI judgment' opus 'UI building'
out=$("$QUOTA" --pick nonexistent 2>&1); rc=$?
if [ "$rc" = 3 ] && [[ "$out" == *'no such job'* ]]; then pass; else fail 'unknown job exits 3 with no such job'; fi

BANK="$ROUTING_KIT_HOME/resets.json"
seed_bank() {
  printf '{"updated":"2000-01-01","resets":[{"type":"fable","expires":%s},{"type":"weekly","expires":%s},{"type":"fable","expires":%s},{"type":"weekly","expires":%s}]}' "$((NOW+5000))" "$((NOW+1000))" "$((NOW+1000))" "$((NOW-100))" > "$BANK"
}
reset_run() { "$QUOTA" resets "$@" 2>"$SANDBOX/err"; }
seed_bank
out=$(reset_run); rc=$?
assert_eq "0|3 $((NOW+1000)) 1weekly+2fable" "$rc|$out" 'bank read ignores expired entries'
out=$(reset_run list); rc=$?
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] && [[ "$out" == *:* ]]; then pass; else fail 'bank list shows three live entries'; fi
for kind in weekly fable; do
  seed_bank
  reset_run use "$kind" >/dev/null; rc=$?
  if [ "$kind" = weekly ]; then expected="[$((NOW-100))]"; else expected="[$((NOW+5000))]"; fi
  got=$(jq -c --arg t "$kind" '[.resets[]|select(.type==$t)|.expires]' "$BANK")
  if [ "$rc" = 0 ] && [ "$got" = "$expected" ] && [ "$(jq -r .updated "$BANK")" = "$(date -u +%Y-%m-%d)" ]; then pass; else fail "use $kind removes soonest live entry and updates date"; fi
done
printf '{"updated":"x","resets":[]}' > "$BANK"
reset_run use weekly >/dev/null; assert_eq 1 "$?" 'use empty bank fails'
out=$(reset_run); rc=$?; assert_eq '0|0 -' "$rc|$out" 'empty bank summary'
for spec in 'weekly 2027-01-02 1798934340' 'fable 2027-01-03T10:30 1798972200'; do
  set -- $spec
  printf '{"updated":"x","resets":[]}' > "$BANK"
  reset_run add "$1" "$2" >/dev/null; rc=$?
  got=$(jq -r '.resets[0].expires' "$BANK")
  if [ "$rc" = 0 ] && [ "$got" = "$3" ] && [ "$(jq -r '.resets[0].type' "$BANK")" = "$1" ]; then pass; else fail "add $1 $2 stores UTC expiry"; fi
done
reset_run add weekly 2027-01-02 >/dev/null; bank_ready=$?
for spec in 'weekly nonsense' 'other 2027-01-02'; do
  set -- $spec
  before=$(cat "$BANK")
  reset_run add "$1" "$2" >/dev/null; rc=$?
  if [ "$bank_ready" = 0 ] && [ "$rc" = 2 ] && [ "$(cat "$BANK")" = "$before" ]; then pass; else fail "invalid add $spec leaves bank intact"; fi
done
for data in missing '{not json' '{"resets":[{"type":"bogus","expires":5}]}'; do
  if [ "$data" = missing ]; then rm -f "$BANK"; else printf '%s' "$data" > "$BANK"; fi
  out=$(reset_run); rc=$?
  assert_eq '1|' "$rc|$out" "unreadable or invalid bank: $data"
done
# Trial metadata is supplied without changing the shipped models file.
jq --arg ledger "$SANDBOX/trials.tsv" '.trial={runs:5,ledger:$ledger}' "$MODELS" > "$SANDBOX/models.json"
out=$("$TABLE" --models "$SANDBOX/models.json" 2>"$SANDBOX/err"); rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *'gpt-6.1-terra (trial)'* ]]; then pass; else fail 'trial metadata labels Terra (trial)'; fi

quota_fixture 10 1 10 40 0
pick 'review defaults to Claude work reviewer' gpt-6.1-sol Review
pick 'second opinion keeps primary adviser' gpt-6-astra 'Second opinion'
out=$("$QUOTA" --pick 'Hardest builds: long overnight runs, or after a cheaper build failed twice' 2>&1); rc=$?
assert_eq 1 "$rc" 'unknown Fable share excludes Fable'
rm -f "$BANK"
reset_run add weekly 2027-01-02 >/dev/null
assert_eq 0 "$?" 'first add creates missing bank'
# Exercise independent Gemini pool readings without calling any live CLI.
fixture=$(mktmp)
mkdir -p "$fixture/bin" "$fixture/rules"
cp "$MODELS" "$fixture/rules/models.json"
cat > "$fixture/bin/kit-routing-table" <<'EOF'
#!/bin/bash
echo '| Pool | gemini-4-argon-high · gemini-4-hydrogen-medium | |'
EOF
cat > "$fixture/bin/kit-quota" <<'EOF'
#!/bin/bash
echo '{"gemini":{"week":{"percent":5,"pace":5},"argon_week":{"percent":100,"pace":100}}}'
EOF
chmod +x "$fixture/bin/"*
out=$(python3 "$ROOT/plugins/routing-kit/lib/quota_pick.py" "$fixture/bin" Pool)
assert_eq gemini-4-hydrogen-medium "$out" 'exhausted Argon pool cannot borrow Hydrogen quota'
printf 'test_quota_pick: PASS=%s FAIL=%s\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
