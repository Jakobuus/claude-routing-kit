#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktmp)
export ROUTING_KIT_HOME="$T/home"
mkdir -p "$T/bin" "$T/repo/sub"
git -C "$T/repo" init -q
git -C "$T/repo" -c user.name=Test -c user.email=you@example.com commit -qm init --allow-empty
printf 'add a file\n' > "$T/brief"
cat > "$T/bin/agy" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$KIT_AGY_ARGS"
echo hi > hello.txt
case "$KIT_AGY_MODE" in
 error) echo '{"status":"ERROR","response":"quota exhausted for model"}' ;;
 invalid) echo 'unreadable output' ;;
 crash) exit 1 ;;
 prose) echo '{"status":"SUCCESS","response":"Fixed the permission denied bug","denied_actions":[]}' ;;
 empty) echo '{"response":"  "}' ;;
 multi) printf '{"response":"first"}\n{"message":"last","denied_actions":[] }\n'; echo 'Denied command: example' >&2 ;;
 denied) echo '{"final_message":"done","denied_actions":[1,2]}' ;;
esac
STUB
chmod +x "$T/bin/agy"
for mode in empty multi denied; do
 out=$(env PATH="$T/bin:$PATH" KIT_AGY_ARGS="$T/args" KIT_AGY_MODE="$mode" "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo/sub" --name "$mode" --brief "$T/brief" --model stub --effort medium 2>&1)
 code=$?
 run=$(find "$T/home/runs" -type d -name "*-$mode-*" | head -1)
 if [ "$mode" = empty ]; then
 assert_eq 4 "$code" 'empty fails'
 assert_eq 'empty answer' "$(jq -r .reason "$run/manifest.json")" 'empty reason'
 else
 assert_eq 0 "$code" 'answer succeeds'
 fi
 git -C "$T/repo" apply --cached --check "$run/build.patch"
 assert_eq 0 "$?" 'patch applies to base index'
 branch=$(jq -r .branch "$run/manifest.json")
 assert_eq "kit-gemini/$(basename "$run")" "$branch" 'run branch name'
 git -C "$T/repo" show-ref --verify "refs/heads/$branch" >/dev/null
 assert_eq 0 "$?" 'run branch exists'
 assert_eq "$(jq -r .base "$run/manifest.json")" "$(git -C "$T/repo" rev-parse "$branch^" 2>/dev/null)" 'the branch is one commit on BASE'
 assert_eq "$(cat "$run/build.patch")" "$(git -C "$T/repo" diff --binary "$(jq -r .base "$run/manifest.json")" "$branch")" 'the branch holds the build: its diff from BASE is build.patch'
 assert_contains "$(git -C "$T/repo" show "$branch:hello.txt" 2>/dev/null)" hi 'the build file is in the branch'
 assert_eq "" "$(git -C "$T/repo" status --porcelain)" 'the working tree and index are untouched'
 assert_eq medium "$(jq -r .effort "$run/manifest.json")" 'effort recorded'
 assert_eq medium "$(awk '/^--effort$/{getline; print}' "$T/args")" 'effort value passed'
 assert_eq true "$(jq '.base!="" and .worktree!="" and has("branch") and .agy_exit==0 and .patch!=""' "$run/manifest.json")" 'manifest fields'
 assert_contains "$(printf '%s\n' "$out" | tail -1)" "patch=$run/build.patch" 'last line patch'
 case "$mode" in
 multi) assert_eq last "$(cat "$run/result.md")" 'last object answer'; assert_eq 1 "$(jq .denied_command_count "$run/manifest.json")" 'text fallback';;
 denied) assert_eq 2 "$(jq .denied_command_count "$run/manifest.json")" 'structured denials';;
 esac
done
# An existing branch named "kit" does not break the build (the old name kit/gemini-<run> could not exist beside it).
git -C "$T/repo" branch kit
out=$(env PATH="$T/bin:$PATH" KIT_AGY_ARGS="$T/args" KIT_AGY_MODE=denied "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name withkit --brief "$T/brief" --model stub 2>&1)
assert_eq 0 "$?" 'a branch named kit does not break the build'
run=$(find "$T/home/runs" -type d -name "*-withkit-*" | head -1)
git -C "$T/repo" show-ref --verify "refs/heads/kit-gemini/$(basename "$run")" >/dev/null
assert_eq 0 "$?" 'the build branch is made beside the branch kit'
assert_contains "$out" "kit-gemini-build: branch: kit-gemini/$(basename "$run")" 'the branch is reported'
for mode in error invalid crash prose; do
 out=$(env PATH="$T/bin:$PATH" KIT_AGY_ARGS="$T/args" KIT_AGY_MODE="$mode" "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name "$mode" --brief "$T/brief" --model stub 2>&1)
 code=$?
 run=$(find "$T/home/runs" -type d -name "*-$mode-*" | head -1)
 assert_eq false "$(grep -qx -- '--effort' "$T/args" && echo true || echo false)" 'effort omitted'
 case "$mode" in
 error) assert_eq 4 "$code" 'status fails'; assert_eq 'status ERROR' "$(jq -r .reason "$run/manifest.json")" 'status reason'; assert_contains "$(cat "$run/result.md")" 'quota exhausted' 'error answer retained';;
 invalid) assert_eq 4 "$code" 'invalid fails'; assert_eq 'invalid output' "$(jq -r .reason "$run/manifest.json")" 'invalid reason';;
 crash) assert_eq 4 "$code" 'crash fails'; assert_eq 'agy failed (exit 1)' "$(jq -r .reason "$run/manifest.json")" 'crash reason'; assert_contains "$(cat "$run/result.md")" 'agy failed' 'crash result';;
 prose) assert_eq 0 "$code" 'prose succeeds'; assert_eq 0 "$(jq .denied_command_count "$run/manifest.json")" 'prose is not denial';;
 esac
done
cat > "$T/bin/agy" <<'STUB'
#!/bin/bash
sleep 30
STUB
cat > "$T/bin/agy-grace" <<'STUB'
#!/bin/bash
sleep 2
echo '{"response":"done"}'
STUB
chmod +x "$T/bin/agy-grace"
env KIT_AGY_BIN="$T/bin/agy-grace" KIT_AGY_TIMEOUT_GRACE=3 "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name grace --brief "$T/brief" --model stub --timeout 1 > "$T/grace.out" 2>&1
assert_eq 0 "$?" 'grace permits late success'
run=$(find "$T/home/runs" -type d -name '*-grace-*' | head -1)
assert_contains "$(cat "$run/result.md")" 'inside the grace' 'late success note'
assert_eq true "$(jq '.agy_elapsed_seconds > 1' "$run/manifest.json")" 'elapsed recorded'
for value in 08 09 1000000; do
 env KIT_AGY_TIMEOUT_GRACE="$value" "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name invalid-grace --brief "$T/brief" --model stub > "$T/invalid.out" 2>&1
 assert_eq 2 "$?" 'invalid grace rejected'
done
start=$SECONDS
env PATH="$T/bin:$PATH" KIT_AGY_TIMEOUT_GRACE=0 "$ROOT/plugins/routing-kit/bin/kit-gemini-build" --repo "$T/repo" --name fix/timeout --brief "$T/brief" --model stub --timeout 1 > "$T/timeout.out" 2>&1
assert_eq 4 "$?" 'timeout failure'
run=$(find "$T/home/runs" -name watchdog-fired -exec dirname {} \; | head -1)
assert_contains "$(cat "$run/result.md")" 'Timeout:' 'timeout note'
assert_eq true "$([ $((SECONDS-start)) -lt 10 ] && echo true)" 'timeout bounded'
# Exercise the real export check with a deliberately corrupt diff producer.
python3 - "$ROOT/plugins/routing-kit/lib/export.sh" "$T/export-corrupt.sh" <<'CORRUPT'
import sys
s = open(sys.argv[1]).read()
s = s.replace('. "$EXPORT_LIB_DIR/../bin/kit-common"', '. "' + str(__import__('pathlib').Path(sys.argv[1]).parent.parent / 'bin/kit-common') + '"')
needle = '--no-textconv --ignore-submodules=all "$base" > "$patch" 2>/dev/null || exit 4'
assert needle in s
s = s.replace(needle, needle + '\n    printf "corrupt patch\\n" > "$patch"')
open(sys.argv[2], 'w').write(s)
CORRUPT
(
 . "$ROOT/plugins/routing-kit/bin/kit-common"
 kit_require_python3
 . "$T/export-corrupt.sh"
 run=$(run_export "$T/repo" corrupt)
 echo hi > "$run/wt/hello.txt"
 run_build_patch_fresh "$run/wt" "$T/repo" "$(git -C "$T/repo" rev-parse HEAD)" 2> "$T/corrupt.err"
 code=$?
 assert_eq 4 "$code" 'corrupt patch rejected'
 assert_eq false "$([ -e "$run/build.patch" ] && echo true || echo false)" 'corrupt patch removed'
 [ "$FAIL_COUNT" -eq 0 ]
)
assert_eq 0 "$?" 'patch self-check regression'
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
