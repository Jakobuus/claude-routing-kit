#!/bin/bash
# Seven route contracts, each counted once.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FIX="$ROOT/tests/fixtures/route"
ROUTE="$ROOT/plugins/routing-kit/bin/kit-route"

# Each invocation has an isolated profile and captures stdout and stderr separately.
route_case() {
  local label profile query expected status private home actual code err lines
  label="$1"; profile="$2"; query="$3"; expected="$4"; status="$5"; private="$6"
  home=$(mktmp)
  cp "$FIX/$profile.json" "$home/profile.json"
  if [ "$private" = yes ]; then
    mkdir -p "$home/private"
    cp "$FIX/private-media.json" "$home/private/media.json"
  fi
  ROUTING_KIT_HOME="$home" "$ROUTE" --guide "$FIX/guide.json" "$query" >"$home/out" 2>"$home/err"
  code=$?
  actual=$(cat "$home/out"); err=$(cat "$home/err")
  lines=$(wc -l < "$home/out" | tr -d ' ')
  if [ "$status" = 3 ]; then
    if [ "$code" = 3 ] && [ -z "$actual" ] && [ "$err" = 'no route; ask the user' ]; then
      pass
    else
      fail "$label (exit $code; stdout [$actual]; stderr [$err])"
    fi
  elif [ "$code" = 0 ] && [ "$actual" = "$expected" ] && [ -z "$err" ] && [ "$lines" -le 4 ]; then
    pass
  else
    fail "$label (exit $code; stdout [$actual]; stderr [$err])"
  fi
}

route_case 'ChatGPT images by exact id' chatgpt images 'Do: GPT Image — agent (Image tool)
Check image details.' 0 no
route_case 'without ChatGPT uses local fallback' basic images 'Do: Local painter — agent (Local tool)
Better, needs a new subscription: GPT Image, about $20/month
Check image details.' 0 no
route_case 'owner connector wording' connector slides 'Do: this is for the user — tell them to do it in Canva (Canva); do not do it yourself.
Review the slides.' 0 no
route_case 'subscription gap' basic music 'Do: nothing in your plans covers this — tell the user the options below; do not make a substitute yourself
Better, needs a new subscription: Music Pro, about $12/month
Check music rights.' 0 no
route_case 'private job replaces guide job' chatgpt images 'Do: Private painter — agent (Private tool)
Private image note.' 0 yes
route_case 'case insensitive free text with punctuation' chatgpt 'Please make an IMAGE, today.' 'Do: GPT Image — agent (Image tool)
Check image details.' 0 no
route_case 'unknown does not match keyword substrings' basic 'afterimages and musicality' '' 3 no

# Review A1-A5 regression cases, using an isolated real guide/profile.
home=$(mktmp)
cp "$FIX/chatgpt.json" "$home/profile.json"
real_route() { ROUTING_KIT_HOME="$home" "$ROUTE" "$1"; }
assert_eq "$(real_route image-to-video)" "$(real_route 'image to video')" 'A1 longest keyword'
assert_eq "$(real_route images)" "$(real_route 'make two images')" 'A2 simple plurals'
printf '[]' > "$home/profile.json"
out=$(real_route images 2>&1); code=$?
if [ "$code" = 2 ] && [ "$out" = 'kit-route: invalid profile; run kit-profile' ]; then pass; else fail 'A3 invalid profile diagnostic'; fi
cp "$FIX/chatgpt.json" "$home/profile.json"
mkdir -p "$home/private"
printf '[{"job":"custom","match":["logo"],"options":[]}]' > "$home/private/media.json"
assert_eq 'Do: nothing in your plans covers this — tell the user the options below; do not make a substitute yourself' "$(real_route 'make a logo')" 'A4 private keyword tie'
fallback=$(mktmp)
mkdir -p "$fallback/.config/routing-kit"
cp "$FIX/chatgpt.json" "$fallback/.config/routing-kit/profile.json"
assert_eq "$(real_route images)" "$(HOME="$fallback" ROUTING_KIT_HOME="" "$ROUTE" images)" 'A5 empty home uses default'

# 5.3d: the operation beats topic words; coding prompts route nothing; a bad private file is ignored.
home=$(mktmp)
cp "$FIX/chatgpt.json" "$home/profile.json"
assert_eq "$(real_route images)" "$(real_route 'Generate an image of a German shepherd')" '5.3d operation over topic: image'
assert_eq "$(real_route logo-svg)" "$(real_route 'Design a logo for a music app')" '5.3d operation over topic: logo'
assert_eq "$(real_route translation)" "$(real_route 'Translate this interview transcription into German')" '5.3d translate over transcription'
assert_eq "$(real_route text-to-video)" "$(real_route 'Generate a video of a sailboat at sunset')" '5.3d make a video'
assert_eq "$(real_route background-removal)" "$(real_route 'Remove the background from this photo')" '5.3d remove the background'
assert_eq "$(real_route image-editing)" "$(real_route 'Edit this image to make the sky blue')" '5.3d edit this image'
assert_eq "$(real_route image-to-video)" "$(real_route 'turn this image into a video')" '5.3d image into a video'
for prompt in 'Fix image caching in nginx' 'Generate TypeScript types for the image upload response' \
    'Change the transparent background CSS to white' 'Make a poster image, see `poster.py`'; do
  out=$(real_route "$prompt" 2>&1); code=$?
  if [ "$code" = 3 ] && [ "$out" = 'no route; ask the user' ]; then pass; else fail "5.3d coding prompt routes nothing: $prompt (exit $code; $out)"; fi
done
mkdir -p "$home/private"
printf '{"media":[{}]}' > "$home/private/media.json"
assert_eq "$(real_route images)" "$(real_route 'Make a poster image for my bakery')" '5.3d bad private file: bundled jobs still route'
out=$(real_route 'Explain Rust lifetimes' 2>&1); code=$?
if [ "$code" = 3 ] && [ "$out" = 'no route; ask the user' ]; then pass; else fail "5.3d bad private file does not crash (exit $code; $out)"; fi
if grep -q 'ignoring private/media.json' "$home/hook-errors.log" 2>/dev/null; then pass; else fail '5.3d bad private file: no line in hook-errors.log'; fi


# 5.3e malformed optional values discard the whole private file, once per invocation.
for field in '"note":[]' '"label":42' '"best_overall":[]' '"options":[{"name":"x","product":"local","who":"agent","how":"x","rank":1,"price_month_usd":"bad"}]'; do
  printf '[{"job":"images","match":["image"],"options":[],%s}]' "$field" > "$home/private/media.json"
  : > "$home/hook-errors.log"
  out=$(real_route 'Make an image')
  assert_eq '1' "$(wc -l < "$home/hook-errors.log" | tr -d ' ')" '5.3e one private error'
  case "$out" in *'GPT Image'*) pass ;; *) fail "5.3e bundled fallback: $out" ;; esac
done
assert_eq "$(real_route video-understanding)" "$(real_route 'Watch clip.mp4 and describe it')" '5.4c watch file'
launch_home=$(mktmp)
cp "$FIX/chatgpt.json" "$launch_home/profile.json"
out=$(ROUTING_KIT_HOME="$launch_home" "$ROUTE" --guide "$FIX/guide.json" --agent claude images)
assert_contains "$out" 'Reach it with: KIT_ROLE=worker codex exec --skip-git-repo-check -m ' '5.4c cross agent launch'
# ---- kit-0.4 media fix wave: runnable reach commands, model follows the option, worker mark, own lane ----
nocodex=$(mktmp)   # an empty CODEX_HOME: the codex model list is unknown, so no fallback applies
reach() {  # reach AGENT PROFILE_FILE QUERY [GUIDE]
  local h; h=$(mktmp); cp "$2" "$h/profile.json"
  CODEX_HOME="$nocodex" ROUTING_KIT_HOME="$h" "$ROUTE" ${4:+--guide "$4"} --agent "$1" "$3"
}
printf '{"claude_plan":"max20","codex":"pro","gemini":"pro","products":[]}' > "$launch_home/all.json"
ALL="$launch_home/all.json"
assert_contains "$(reach claude "$FIX/chatgpt.json" images "$FIX/guide.json")" \
  'Reach it with: KIT_ROLE=worker codex exec --skip-git-repo-check -m gpt-6.1-sol -c model_reasoning_effort=high "<task>" </dev/null' 'fix wave: codex reach command'
assert_contains "$(reach claude "$ALL" video-understanding)" \
  'Reach it with: KIT_ROLE=worker agy --dangerously-skip-permissions --model gemini-4-argon-high -p "<task>" </dev/null' 'fix wave: agy reach command'
assert_contains "$(reach codex "$ALL" logo-svg)" \
  'Reach it with: KIT_ROLE=worker claude -p --model sonnet --effort medium "<task>" </dev/null' 'fix wave: claude reach command uses build, not strong'
assert_contains "$(reach codex "$ALL" 3d-code)" '--model sonnet ' 'fix wave: model follows the option name (Sonnet)'
# every printed command uses only flags the installed tool lists in --help
check_flags() {  # check_flags TOOL COMMAND
  command -v "$1" >/dev/null 2>&1 || { pass; return; }
  local help flag ok=yes
  help=$("$1" --help 2>&1 </dev/null; [ "$1" = codex ] && codex exec --help 2>&1 </dev/null)
  for flag in $(printf '%s' "$2" | grep -oE ' (--[a-z-]+|-[mcp]) ' | tr -d ' '); do
    case "$help" in *"$flag"*) ;; *) ok="no ($flag)" ;; esac
  done
  if [ "$ok" = yes ]; then pass; else fail "fix wave: $1 --help lacks a flag the reach command uses: $ok"; fi
}
check_flags codex "$(reach claude "$FIX/chatgpt.json" images "$FIX/guide.json" | grep '^Reach')"
check_flags agy "$(reach claude "$ALL" video-understanding | grep '^Reach')"
check_flags claude "$(reach codex "$ALL" logo-svg | grep '^Reach')"
# the model list of the lane's CLI: a missing model uses its fallback, no usable model drops the line
mkdir -p "$nocodex/has-fallback" "$nocodex/has-none"
printf '{"models":[{"slug":"gpt-6-sol"}]}' > "$nocodex/has-fallback/models_cache.json"
printf '{"models":[{"slug":"other-model"}]}' > "$nocodex/has-none/models_cache.json"
out=$(CODEX_HOME="$nocodex/has-fallback" ROUTING_KIT_HOME="$launch_home" "$ROUTE" --guide "$FIX/guide.json" --agent claude images)
assert_contains "$out" ' -m gpt-6-sol ' 'fix wave: fallback model used when the CLI lacks the first'
out=$(CODEX_HOME="$nocodex/has-none" ROUTING_KIT_HOME="$launch_home" "$ROUTE" --guide "$FIX/guide.json" --agent claude images)
case "$out" in *'Reach it with'*) fail "fix wave: reach line printed with no usable model [$out]" ;; *) pass ;; esac
# an owner option whose product's lane is the reader: agent wording for that reader, owner wording for others
own=$(mktmp); cp "$FIX/chatgpt.json" "$own/profile.json"; mkdir -p "$own/private"
printf '[{"job":"images","match":["image"],"options":[{"name":"GPT Image","product":"chatgpt","who":"owner","how":"ChatGPT app or Codex","rank":1,"price_month_usd":null}]}]' > "$own/private/media.json"
out=$(ROUTING_KIT_HOME="$own" "$ROUTE" --agent codex images)
assert_contains "$out" 'do not do it yourself' 'owner options always hand off'
case "$out" in *'use your own tools'*|*'Reach it'*) fail "fix wave: Codex told not to do its own job [$out]" ;; *) pass ;; esac
out=$(ROUTING_KIT_HOME="$own" "$ROUTE" --agent claude images)
assert_contains "$out" 'tell them to do it in ChatGPT app or Codex' 'fix wave: other readers still hand an owner option to the user'
# shipped guide: Codex does image jobs itself; Claude gets a reach line to Codex
out=$(reach codex "$ALL" 'Make an image of a fox')
case "$out" in *'Do: GPT Image'*'agent'*) pass ;; *) fail "fix wave: Codex image route [$out]" ;; esac
case "$out" in *'Reach it'*|*'do not do it yourself'*) fail "fix wave: Codex image route should be its own [$out]" ;; *) pass ;; esac
assert_contains "$(reach claude "$ALL" 'Make an image of a fox')" 'Reach it with: KIT_ROLE=worker codex exec' 'fix wave: Claude image route reaches Codex'
assert_contains "$(reach claude "$ALL" 'Edit this photo to remove the person on the left')" 'Reach it with: KIT_ROLE=worker codex exec' 'fix wave: Claude image-editing route reaches Codex'
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
