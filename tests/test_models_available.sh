#!/bin/bash
. "$(dirname "$0")/lib.sh"
BIN="$(cd "$(dirname "$0")/../plugins/routing-kit/bin" && pwd)/kit-models-available"
p=$(mktmp)
export CODEX_HOME="$p/codex" ROUTING_KIT_HOME="$p/kit"
mkdir -p "$CODEX_HOME" "$ROUTING_KIT_HOME/cache" "$p/bin"
assert_exit 4 'unknown cache' -- "$BIN" codex
printf '%s\n' '{"models":[{"slug":"test-model"}]}' > "$CODEX_HOME/models_cache.json"
assert_eq test-model "$("$BIN" codex)" 'codex slugs'
assert_exit 4 'claude unknown' -- "$BIN" claude
printf 'test-model description\n' > "$ROUTING_KIT_HOME/cache/agy-models.txt"
assert_eq test-model "$("$BIN" gemini)" 'gemini first column'
printf '#!/bin/bash\nexit 1\n' > "$p/bin/agy"
chmod +x "$p/bin/agy"
PATH="$p/bin:$PATH" "$BIN" --refresh gemini >/dev/null
assert_eq 'test-model description' "$(cat "$ROUTING_KIT_HOME/cache/agy-models.txt")" 'failed refresh preserves cache'

# successful refresh rewrites the cache from `agy models`, skipping non-model lines
cat > "$p/bin/agy" <<'SH'
#!/bin/bash
printf 'Fetching available models...\n'
printf 'gemini-4-argon-high\tGemini 4 Argon (High)\n'
printf 'gemini-4-hydrogen-low\tGemini 4 Hydrogen (Low)\n'
SH
PATH="$p/bin:$PATH" "$BIN" --refresh gemini >/dev/null
assert_eq 'gemini-4-argon-high
gemini-4-hydrogen-low' "$("$BIN" gemini)" 'refresh rewrites the cache'
# a refresh that prints no model lines keeps the old file
printf '#!/bin/bash\nprintf "Fetching available models...\\n"\n' > "$p/bin/agy"
PATH="$p/bin:$PATH" "$BIN" --refresh gemini >/dev/null
assert_eq 'gemini-4-argon-high
gemini-4-hydrogen-low' "$("$BIN" gemini)" 'empty refresh keeps the cache'
assert_eq 0 "$(ls "$ROUTING_KIT_HOME/cache" | grep -c 'agy-models\.[A-Za-z0-9]\{6\}')" 'no temp files left behind'
# unknown lists and bad input
rm -f "$ROUTING_KIT_HOME/cache/agy-models.txt"
assert_exit 4 'no gemini cache is unknown' -- "$BIN" gemini
printf '{not json' > "$CODEX_HOME/models_cache.json"
assert_exit 4 'malformed codex cache is unknown' -- "$BIN" codex
printf '{"models":[]}' > "$CODEX_HOME/models_cache.json"
assert_exit 4 'empty codex list is unknown' -- "$BIN" codex
assert_exit 4 'no arguments' -- "$BIN"
assert_exit 4 'unknown lane' -- "$BIN" bogus
assert_exit 4 'refresh is gemini only' -- "$BIN" --refresh codex
# agy models runs from the kit's cache folder, never from the caller's folder
# (an untrusted project folder could carry an agy config of its own).
untrusted=$(mktmp)/project; mkdir -p "$untrusted"
cwdmark="$p/agy-cwd"
cat > "$p/bin/agy" <<'SH'
#!/bin/bash
pwd -P > "$AGY_CWD_MARK"
printf 'cwd-model description\n'
SH
chmod +x "$p/bin/agy"
(cd "$untrusted" && env PATH="$p/bin:$PATH" AGY_CWD_MARK="$cwdmark" "$BIN" --refresh gemini >/dev/null)
want=$(cd "$ROUTING_KIT_HOME/cache" && pwd -P)
assert_eq "$want" "$(cat "$cwdmark" 2>/dev/null)" 'agy models runs from the cache folder'
assert_contains "$(cat "$ROUTING_KIT_HOME/cache/agy-models.txt")" 'cwd-model' 'refresh from the cache folder still fills the cache'

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
