#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/plugins/routing-kit/bin/kit-gemini-build"
home=$(mktmp)
repo=$(mktmp)
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=you@example.com commit --allow-empty -qm init
brief=$(mktmp)/brief
echo 'write hello' > "$brief"
fake=$(mktmp)/agy
cat > "$fake" <<'STUB'
#!/bin/bash
echo hi > hello.txt
if [ "$KIT_AGY_CASE" = active ]; then
  for i in 1 2 3 4 5; do echo "$i" >> hello.txt; sleep 1; done
  echo '{"status":"SUCCESS","response":"done"}'
else
  sleep 30 & wait
fi
STUB
chmod +x "$fake"
for value in 0 -1 1.5 abc ''; do
assert_exit 2 "reject idle value $value" -- env ROUTING_KIT_HOME="$home" KIT_AGY_IDLE_SECS="$value" "$BIN" --repo "$repo" --name invalid --brief "$brief"
done
start=$SECONDS
out=$(env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_IDLE_SECS=2 KIT_AGY_CASE=idle "$BIN" --repo "$repo" --name idle --brief "$brief" --timeout 25 2>&1)
code=$?
assert_eq 4 "$code" 'idle exits with saved failure'
manifest=$(find "$home/runs" -name manifest.json | head -1)
assert_eq idle "$(jq -r .reason "$manifest")" 'idle reason'
patch=$(jq -r .patch "$manifest")
assert_contains "$(cat "$patch")" '+hi' 'idle patch saved'
assert_eq true "$([ $((SECONDS-start)) -lt 20 ] && echo true)" 'stopped before timeout'
assert_exit 0 'activity resets idle clock' -- env ROUTING_KIT_HOME="$home" KIT_AGY_BIN="$fake" KIT_AGY_IDLE_SECS=2 KIT_AGY_CASE=active "$BIN" --repo "$repo" --name active --brief "$brief" --timeout 25
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
