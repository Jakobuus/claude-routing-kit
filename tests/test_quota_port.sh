#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktmp)
export ROUTING_KIT_HOME="$T" QUOTA_NOW=2000000000
printf '%s\n' '{"claude_plan":"max","codex":"none","gemini":"none","jules":false}' > "$T/profile.json"
printf '%s\n' '{"resets":[{"type":"weekly","expires":2000100000},{"type":"fable","expires":2000200000},{"type":"weekly","expires":1999999999}]}' > "$T/claude-resets.json"
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 2 "$(printf '%s' "$out" | jq -r '.claude.resets.available')" 'default reset file'
assert_eq 1 "$(printf '%s' "$out" | jq -r '.claude.resets.fable')" 'reset types'
# Exercise the native Gemini parser with fresh cached API replies.
export KIT_AGY_BIN="$T/missing-agy"
base=$(date +%s)
printf '%s\n' '{"claude_plan":"none","codex":"none","gemini":"pro","jules":false}' > "$T/profile.json"
reply() {
  python3 - "$T/agy-quota.json" "$1" "$2" <<'PYREPLY'
import datetime, json, sys
reset = datetime.datetime.fromtimestamp(int(sys.argv[3]), datetime.timezone.utc).isoformat()
json.dump({'command': {'data': {'groups': [{'buckets': [{'id':'gemini-5h','remaining_fraction':float(sys.argv[2]),'reset_time':reset}]}]}}}, open(sys.argv[1], 'w'))
PYREPLY
}
reply .2 "$((base+7200))"
export QUOTA_NOW=$(date +%s)
bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json >/dev/null
reply .8 "$((base+7200+120))"   # exactly at the 120 s tolerance, from the same base second (no clock race)
export QUOTA_NOW=$(date +%s)
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 80 "$(printf '%s' "$out" | jq -r .gemini.five_hour.percent)" 'replica lower reading retained at tolerance boundary'
reply .8 "$((base+7200+300))"   # well past the tolerance: a new reset
export QUOTA_NOW=$(date +%s)
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 20 "$(printf '%s' "$out" | jq -r .gemini.five_hour.percent)" 'new reset accepts lower reading'
# Native Codex session cache survives a changing source for sixty seconds.
printf '%s\n' '{"claude_plan":"none","codex":"pro","gemini":"none","jules":false}' > "$T/profile.json"
export CODEX_HOME="$T/codex"
mkdir -p "$CODEX_HOME/sessions/2026/01/01"
printf '{"rate_limits":{"primary":{"used_percent":10,"resets_at":%s,"window_minutes":300}}}\n' "$((QUOTA_NOW+7200))" > "$CODEX_HOME/sessions/2026/01/01/a.jsonl"
export QUOTA_CODEX_RESETS_CMD="$T/no-reader"
bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json >/dev/null
sed -i.bak 's/10/40/' "$CODEX_HOME/sessions/2026/01/01/a.jsonl"
export QUOTA_NOW=$(date +%s)
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 10 "$(printf '%s' "$out" | jq -r .codex.five_hour.percent)" 'native Codex cache'
export QUOTA_NOW=$((QUOTA_NOW+61))
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 40 "$(printf '%s' "$out" | jq -r .codex.five_hour.percent)" 'Codex cache expires'
export QUOTA_NOW=$(date +%s)
mkdir -p "$T/bin"
cat > "$T/bin/jules" <<'STUB'
#!/bin/bash
echo call >> "$ROUTING_KIT_HOME/calls"
printf 'ID  Name  Age  Status\n1  demo  1h ago  Completed\n'
STUB
chmod +x "$T/bin/jules"
export PATH="$T/bin:$PATH"
printf '%s\n' '{"claude_plan":"none","codex":"none","gemini":"none","jules":true}' > "$T/profile.json"
export QUOTA_NOW=$(date +%s)
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 100 "$(printf '%s' "$out" | jq -r .jules.limit)" 'Jules default daily limit'
export QUOTA_NOW=$(date +%s)
bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json >/dev/null
assert_eq 1 "$(wc -l < "$T/calls" | tr -d ' ')" 'Jules reader cached'
# Profile reset paths expand relative to the isolated HOME.
export HOME="$T"
printf '%s\n' '{"claude_plan":"max","codex":"none","gemini":"none","jules":false,"claude_resets_file":"~/r.json"}' > "$T/profile.json"
printf '{"resets":[{"type":"weekly","expires":%s}]}\n' "$((QUOTA_NOW+7200))" > "$T/r.json"
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 1 "$(printf '%s' "$out" | jq -r .claude.resets.available)" 'profile reset path expands HOME'
# Different session roots must not share a fresh native reader cache.
printf '%s\n' '{"claude_plan":"none","codex":"pro","gemini":"none","jules":false}' > "$T/profile.json"
export CODEX_HOME="$T/codex-other"
mkdir -p "$CODEX_HOME/sessions/2026/01/01"
printf '{"rate_limits":{"primary":{"used_percent":77,"resets_at":%s,"window_minutes":300}}}\n' "$((QUOTA_NOW+7200))" > "$CODEX_HOME/sessions/2026/01/01/a.jsonl"
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 77 "$(printf '%s' "$out" | jq -r .codex.five_hour.percent)" 'Codex cache separates session roots'
export CODEX_HOME="$T/codex"
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 40 "$(printf '%s' "$out" | jq -r .codex.five_hour.percent)" 'Codex original root retains reading'
# Speak the app-server protocol, recording each actual launch.
unset QUOTA_CODEX_RESETS_CMD
cat > "$T/server.py" <<'SERVER'
import json, os, sys
with open(os.path.join(os.environ['HOME'], 'server-calls'), 'a') as f:
    f.write(os.getcwd() + '\n')
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 1:
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
    elif msg.get('id') == 2:
        credits = None if os.path.exists(os.path.join(os.environ['HOME'], 'null-reply')) else {'availableCount': 2, 'credits': []}
        print(json.dumps({'id': 2, 'result': {'rateLimitResetCredits': credits}}), flush=True)
SERVER
export CODEX_RESETS_CMD="python3 $T/server.py"
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json)
assert_eq 2 "$(printf '%s' "$out" | jq -r .codex.resets.available)" 'app-server reset credits'
assert_eq "$HOME" "$(cat "$T/server-calls")" 'app-server runs in HOME'
bash "$ROOT/plugins/routing-kit/bin/kit-quota" --json >/dev/null
assert_eq 1 "$(wc -l < "$T/server-calls" | tr -d ' ')" 'app-server credits cached within 600 seconds'
rm "$T/cache/codex-resets.cache"
touch "$T/null-reply"
out=$(bash "$ROOT/plugins/routing-kit/bin/kit-quota")
assert_contains "$out" 'resets ?' 'null app-server credits stay unknown'
printf 'PASS %s / FAIL %s\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" = 0 ]
