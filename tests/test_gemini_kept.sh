#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktmp)
export ROUTING_KIT_HOME="$T/home"
mkdir -p "$T/bin" "$T/repo"
git -C "$T/repo" init -q
git -C "$T/repo" -c user.name=Test -c user.email=you@example.com commit -qm init --allow-empty
printf 'build\n' > "$T/brief"
cat > "$T/bin/agy" <<'STUB'
#!/bin/bash
echo work > changed
case "$KIT_AGY_MODE" in
 repointed) rm -rf .git; printf "gitdir: /nonexistent\n" > .git; mkfifo pipe ;;
 fsmonitor) git config core.fsmonitor /nonexistent; mkfifo pipe ;;
 fifo) mkfifo pipe ;;
 hardlink) ln changed second ;;
 nested) mkdir -p sub/.git ;;
 gitfile) mkdir sub; printf 'gitdir: /nonexistent\n' > sub/.git ;;
esac
echo '{"response":"done"}'
STUB
chmod +x "$T/bin/agy"
for mode in fifo hardlink nested gitfile repointed fsmonitor; do
 out=$(KIT_AGY_MODE="$mode" KIT_AGY_BIN="$T/bin/agy" "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name "$mode" --brief "$T/brief" --model stub 2>&1)
 assert_eq 4 "$?" "$mode refused"
 run=$(find "$T/home/runs" -name manifest.json | while read -r f; do [ "$(jq -r .name "$f")" != "$mode" ] || dirname "$f"; done)
 assert_eq true "$([ -f "$run/wt/changed" ] && echo true)" "$mode copy retained"
 assert_eq kept "$(jq -r .cleanup "$run/manifest.json")" "$mode kept manifest"
 assert_contains "$(tail -1 <<< "$out")" "$run/wt" "$mode final copy path"
 assert_contains "$(cat "$run/result.md")" "$run/wt" "$mode result copy path"
 assert_contains "$(jq -r .cleanup_reason "$run/manifest.json")" 'refusing' "$mode reason"
 touch -t 202001010000 "$run"
done
assert_eq "" "$(git -C "$T/repo" branch --list 'kit-gemini/*' 'kit/*')" "refused runs leave no branch in the source repo"
. "$ROOT/plugins/routing-kit/bin/kit-common"
. "$ROOT/plugins/routing-kit/lib/export.sh"
run_sweep_stale
for mode in fifo hardlink nested gitfile repointed fsmonitor; do
 assert_eq 1 "$(find "$T/home/runs" -path "*-$mode-*/wt/changed" | wc -l | tr -d ' ')" "$mode survives stale cleanup"
done
# The wrapper is killed outright after agy wrote work: no exit trap runs and no manifest is
# written. The stale cleanup has nothing to go by, and still must not delete that copy: it moves it
# to <kit home>/retained.
cat > "$T/bin/agy-kill" <<'STUB'
#!/bin/bash
echo unsaved-work > changed
# agy's parent is the wrapper script itself.
kill -KILL "$PPID"
STUB
chmod +x "$T/bin/agy-kill"
( KIT_AGY_TIMEOUT_GRACE=0 KIT_AGY_BIN="$T/bin/agy-kill" exec "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name killed --brief "$T/brief" --model stub --timeout 3 >/dev/null 2>&1 ) &
wrapper=$!
wait "$wrapper" 2>/dev/null
run=$(find "$T/home/runs" -mindepth 1 -maxdepth 1 -type d -name '*-killed-*' | head -1)
assert_eq true "$([ -f "$run/wt/changed" ] && [ ! -f "$run/manifest.json" ] && echo true)" "killed wrapper leaves its copy and no manifest"
touch -t 202001010000 "$run"
run_sweep_stale
assert_eq "" "$(find "$run" -maxdepth 1 -name wt)" "stale cleanup clears the run dir of the killed build"
assert_eq unsaved-work "$(cat "$T/home/retained/$(basename "$run")/changed" 2>/dev/null)" "stale cleanup retains the killed build's copy"
assert_contains "$(cat "$T/home/retained/$(basename "$run").why" 2>/dev/null)" "from=$run/wt" "retained copy says where it came from"
# A finished Gemini build whose work is all in build.patch has its copy deleted.
out=$(KIT_AGY_MODE=plain KIT_AGY_BIN="$T/bin/agy" "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name finished --brief "$T/brief" --model stub 2>&1)
assert_eq 0 "$?" "plain build succeeds"
run=$(find "$T/home/runs" -mindepth 1 -maxdepth 1 -type d -name '*-finished-*' | head -1)
assert_eq "" "$(ls -A "$T/home/retained/$(basename "$run")" 2>/dev/null)" "finished Gemini build's copy is not retained"
assert_contains "$(cat "$run/build.patch")" "+work" "finished Gemini build's work is in build.patch"
assert_eq "" "$(find "$run" -maxdepth 1 -name wt)" "finished Gemini build's run dir has no copy left"
# Review finding 1 (Gemini): agy writes work git ignores and forges the run dir's marks.
cat > "$T/bin/agy-forge" <<'STUB'
#!/bin/bash
printf 'artifact.json\n' > .gitignore
echo unique-work > artifact.json
: > ../agent-not-started
rm -f ../agent-started
echo '{"response":"done"}'
STUB
chmod +x "$T/bin/agy-forge"
KIT_AGY_BIN="$T/bin/agy-forge" "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name forged --brief "$T/brief" --model stub >/dev/null 2>&1
assert_eq 0 "$?" "forged marks: build succeeds"
run=$(find "$T/home/runs" -mindepth 1 -maxdepth 1 -type d -name '*-forged-*' | head -1)
assert_eq unique-work "$(cat "$T/home/retained/$(basename "$run")/artifact.json" 2>/dev/null)" "forged marks do not get a Gemini build's copy deleted"
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
