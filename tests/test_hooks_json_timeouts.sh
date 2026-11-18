#!/bin/bash
# hooks.json gives every event at least the dispatcher's own worst case (kit-hook --max-timeout),
# so the agent never kills a blocking guard first (a killed hook lets the action through).
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
KH="$REPO_ROOT/plugins/routing-kit/hooks/kit-hook"
HJ="$REPO_ROOT/plugins/routing-kit/hooks/hooks.json"
events=$(/usr/bin/jq -r '.hooks | keys[]' "$HJ")
[ -n "$events" ] && pass || fail "hooks.json lists no events"
for ev in $events; do
  need=$("$KH" --max-timeout "$ev" 2>/dev/null)
  need=$(python3 -c 'import math,sys; print(int(math.ceil(float(sys.argv[1]))))' "$need" 2>/dev/null)
  [ -n "$need" ] || { fail "$ev: kit-hook --max-timeout gave nothing"; continue; }
  for have in $(/usr/bin/jq -r --arg e "$ev" '.hooks[$e][].hooks[] | select(.command|test("kit-hook")) | .timeout' "$HJ"); do
    [ "$have" -ge "$need" ] && pass || fail "$ev: hooks.json timeout $have < dispatcher worst case $need"
  done
done
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
