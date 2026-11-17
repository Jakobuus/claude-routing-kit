#!/bin/bash
# Tests for plugins/routing-kit/hooks/checks/media.py (task 5.4a, tests first).
# Uses the REAL guide (plugins/routing-kit/guide/guide.json, its `media` list) so the keywords are
# proven too. `kit-route` is stubbed: a fake first on PATH prints "ROUTE:<its argument>".
#
# Cases (M = 52):
#   12 media prompts x 2 agents (claude, agy)   = 24
#   12 coding prompts x 2 agents                = 24
#   first_in_turn false -> nothing              =  1
#   prompt over 2,000 chars -> nothing          =  1
#   prompt of exactly 2,000 chars still matches =  1
#   route log (matches logged, non-matches not) =  1
#   plus 5.3d: 19 of Sol's coding prompts (those with an explicit code signal) x 3 agents, 12 media
#   prompts, 1 topic-only, 7 bad private files x 3
#   plus 5.3g (recall first): tests/fixtures/checks/media/eval.tsv, scored by tests/media_eval.py. At least
#   90% of its media prompts must route to the right job; prompts with an explicit code signal (code
#   file names, paths, backticks, language names, function/class/bug/test/API/endpoint/component) must
#   match nothing. Soft coding prompts may match now, because the injected line is conditional. Dropped:
#   Sol's 3 soft prompts (TTS service "from the build", PNG to SVG "in the worker", subtitles "in the HLS
#   pipeline"), the 4 topic-only nouns (3 of them now match), the 5.3e prompts for video controls, canvas
#   element, transcoding pipeline, player and OCR plugin, and the whole 5.3f block of soft nouns and Opus
#   coding prompts. Rewritten: 5.3f nouns now only for explicit signals (loop in 5.3g).
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/plugins/routing-kit/bin/kit-common"
CHECK="$ROOT/plugins/routing-kit/hooks/checks/media.py"
GUIDE="$ROOT/plugins/routing-kit/guide/guide.json"

KHOME=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$KHOME/profile.json"
FAKEBIN=$(mktmp)
printf '#!/bin/bash\necho "ROUTE:${@: -1}"\n' > "$FAKEBIN/kit-route"
chmod +x "$FAKEBIN/kit-route"

# run_check JSON [HOME_DIR] -> sets OUT (stdout) and CODE (exit status). Runs as the kit does.
run_check() {
  OUT=$(printf '%s' "$1" | env ROUTING_KIT_HOME="${2:-$KHOME}" PATH="$FAKEBIN:$PATH" bash -c \
    '. "$1/plugins/routing-kit/bin/kit-common"; kit_python3 "$2"' _ "$ROOT" "$CHECK" 2>/dev/null)
  CODE=$?
}

# ev AGENT PROMPT FIRST_IN_TURN -> common event JSON for a prompt event
ev() {
  kit_jq -n -c --arg a "$1" --arg p "$2" --argjson f "${3:-true}" \
    '{agent:$a,event:"UserPromptSubmit",session_id:"s1",cwd:"/tmp",prompt:$p,first_in_turn:$f,stop_hook_active:false,
      tool:{kind:"other",name:"",command:"",paths:[],params:{}}}'
}

label_of() { kit_jq -r --arg j "$1" '.media[] | select(.job==$j) | .label' "$GUIDE"; }

# expect_job LABEL JOB EVENT_JSON [HOME_DIR]: context naming exactly JOB's label and route
expect_job() {
  run_check "$3" "$4"
  if [ "$CODE" != 0 ]; then fail "$1: check exited $CODE (media.py missing or crashed)"; return; fi
  local action text want
  action=$(printf '%s' "$OUT" | kit_jq -r '.action' 2>/dev/null)
  text=$(printf '%s' "$OUT" | kit_jq -r '.text // ""' 2>/dev/null)
  want="If this is a media job (making, editing, transcribing, translating or reading images, video or audio; not code): $(label_of "$2"). Route: ROUTE:$2. Follow it unless the user named a tool."
  if [ "$action" != context ]; then fail "$1: expected context for job $2, got [$OUT]"; return; fi
  if [ "$text" != "$want" ]; then fail "$1: wrong text (expected [$want], got [$text])"; return; fi
  pass
}

# expect_none LABEL EVENT_JSON [HOME_DIR]: the check ran fine and printed nothing (or allow)
expect_none() {
  run_check "$2" "$3"
  if [ "$CODE" != 0 ]; then fail "$1: expected nothing, but check exited $CODE (media.py missing or crashed)"; return; fi
  if [ -z "$OUT" ]; then pass; return; fi
  if [ "$(printf '%s' "$OUT" | kit_jq -r '.action' 2>/dev/null)" = allow ]; then pass; return; fi
  fail "$1: expected nothing, got [$OUT]"
}

# ---- 12 media prompts, one per main job, each must match exactly its job ----
MEDIA='images|Make a poster image for our summer launch party
image-editing|Retouch my headshot, the lighting is too harsh
logo-svg|Design a vector logo for my bakery
text-to-video|Generate video of a sailboat at sunset, about ten seconds long
voiceover|I need a voiceover for my product demo, calm female voice
transcription|Transcribe this interview recording and mark who is speaking
music|Compose some background music for my cooking channel
ocr|Run OCR on this scanned receipt and give me the total
translation|Translate this email into German
ui-mockups|I need a UI mockup for a meditation app home screen
background-removal|Cut out the person in this photo and give me a transparent background
video-understanding|Watch this video and tell me what happens in it'

# ---- 12 coding prompts that share words with media jobs: a coding verb plus a code noun wins ----
CODING='Fix the image upload bug
Add a logo prop to the Header component
Transcribe the API response into a TypeScript type
Translate this Python function to Go
The video player test is flaky
The OCR endpoint returns a 500, debug the handler
Rename the music player class and update its imports
The remove background endpoint throws a null pointer exception in the handler
Implement the wireframe for the settings page as a React component
Add the Spanish translation keys to the en.json config file
Write a unit test for the subtitles parser
Fix the TTS client class, it throws a timeout error'

for agent in claude agy; do
  while IFS='|' read -r job prompt; do
    [ -n "$job" ] || continue
    expect_job "$agent media $job" "$job" "$(ev "$agent" "$prompt")"
  done <<EOF2
$MEDIA
EOF2
  while IFS= read -r prompt; do
    [ -n "$prompt" ] || continue
    expect_none "$agent coding: $prompt" "$(ev "$agent" "$prompt")"
  done <<EOF3
$CODING
EOF3
done

# ---- acts only when first_in_turn is true ----
expect_none "first_in_turn false" "$(ev claude 'Make a poster image for our summer launch party' false)"

# ---- prompts over 2,000 chars give nothing; exactly 2,000 still matches ----
HEAD_TXT='Make a poster image of a fox. '   # 30 chars
PAD1970=$(head -c 1970 /dev/zero | tr '\0' 'a')
PAD1971=$(head -c 1971 /dev/zero | tr '\0' 'a')
expect_none "prompt of 2001 chars" "$(ev claude "$HEAD_TXT$PAD1971")"
expect_job "prompt of exactly 2000 chars" images "$(ev claude "$HEAD_TXT$PAD1970")"

# ---- route log: one {time,agent,job} line per match, none for non-matches ----
LOGHOME=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$LOGHOME/profile.json"
LOG="$LOGHOME/route-log.jsonl"
run_check "$(ev claude 'Translate this email into German')" "$LOGHOME"
run_check "$(ev agy 'Run OCR on this scanned receipt and give me the total')" "$LOGHOME"
run_check "$(ev claude 'Fix the image upload bug')" "$LOGHOME"
run_check "$(ev codex 'Transcribe this interview recording and mark who is speaking' false)" "$LOGHOME"
LOGOK=1
if [ ! -f "$LOG" ]; then
  LOGOK=0; fail "route log: $LOG was not created"
else
  [ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] || { LOGOK=0; fail "route log: expected exactly 2 lines (2 matches, 2 non-matches), got $(wc -l < "$LOG" | tr -d ' ')"; }
  L1=$(sed -n 1p "$LOG"); L2=$(sed -n 2p "$LOG")
  [ "$(printf '%s' "$L1" | kit_jq -r '.agent + "/" + .job' 2>/dev/null)" = "claude/translation" ] || { LOGOK=0; fail "route log line 1 should be agent claude, job translation (got [$L1])"; }
  [ "$(printf '%s' "$L2" | kit_jq -r '.agent + "/" + .job' 2>/dev/null)" = "agy/ocr" ] || { LOGOK=0; fail "route log line 2 should be agent agy, job ocr (got [$L2])"; }
  for L in "$L1" "$L2"; do
    [ "$(printf '%s' "$L" | kit_jq -r '(.time // "") | tostring | length > 0' 2>/dev/null)" = true ] || { LOGOK=0; fail "route log line has no time (got [$L])"; }
    [ "$(printf '%s' "$L" | kit_jq -r 'keys | join(",")' 2>/dev/null)" = "agent,job,time" ] || { LOGOK=0; fail "route log line keys must be exactly time, agent, job (got [$L])"; }
  done
fi
[ "$LOGOK" = 1 ] && pass

expect_job "shared plural matcher" logo-svg "$(ev claude 'make 3 logos')"

# ---- 5.3d: Sol's review prompts (5.4b) that carry an explicit code signal match nothing in all three agents ----
SOL_CODING='Optimize image decoding in the Rust renderer
Fix image caching in nginx
Investigate why the SVG logo disappears after hydration
Support captions in the HTML5 video player
Implement lazy loading for image elements
Fix the poster attribute in our Vue player
Add translation strings to locales/en.yml
Document OCR CLI flags in the README
Upgrade the music streaming SDK to its latest release
Generate TypeScript types for the image upload response
Change the transparent background CSS to white
Migrate the image optimizer from webpack to Vite
Fix the image upload handler
Write a test for the logo component
Update the OCR endpoint error handling
Refactor the translation module
The music player tests are failing
Why does the logo look blurry? See src/Header.tsx
Make a poster image, see `poster.py`'
for agent in claude codex agy; do
  while IFS= read -r prompt; do
    expect_none "$agent sol coding: $prompt" "$(ev "$agent" "$prompt")"
  done <<EOF4
$SOL_CODING
EOF4
done

# The requested operation beats a topic word in the prompt; ordinary phrasings match.
SOL_MEDIA='text-to-video|Generate a video of a sailboat at sunset
background-removal|Remove the background from this photo
image-editing|Edit this image to make the sky blue
images|Generate an image of a German shepherd
logo-svg|Design a logo for a music app
translation|Translate this interview transcription into German
translation|Translate these subtitles into French
image-to-video|turn this image into a video
image-to-video|Animate this photo into a short clip
video-editing|Edit this video to remove the intro
transcription|Please transcribe this meeting
music|Write a song about autumn'
while IFS='|' read -r job prompt; do
  expect_job "sol media $job: $prompt" "$job" "$(ev claude "$prompt")"
done <<EOF5
$SOL_MEDIA
EOF5
# A topic word that is no media job (a German shepherd is not translation) routes nothing.
for prompt in 'My German shepherd is ill'; do
  expect_none "topic word only: $prompt" "$(ev claude "$prompt")"
done

# ---- 5.3d: a wrong-shaped private/media.json is ignored (one line in hook-errors.log), never crashes ----
BADSHAPES='42
{"media":null}
{"media":[{}]}
{"media":[{"job":"images"}]}
[{"job":"x","match":"logo","options":[]}]
[{"job":"x","match":["logo"],"options":[{}]}]
not json'
while IFS= read -r shape; do
  BADHOME=$(mktmp)
  cp "$KHOME/profile.json" "$BADHOME/profile.json"
  mkdir -p "$BADHOME/private"
  printf '%s' "$shape" > "$BADHOME/private/media.json"
  expect_none "bad private $shape: coding prompt" "$(ev claude 'Explain Rust lifetimes')" "$BADHOME"
  expect_job "bad private $shape: bundled job kept" images "$(ev claude 'Make a poster image for our summer launch party')" "$BADHOME"
  if grep -q 'ignoring private/media.json' "$BADHOME/hook-errors.log" 2>/dev/null; then pass
  else fail "bad private $shape: no line in hook-errors.log"; fi
done <<EOF6
$BADSHAPES
EOF6

# agy prompts arrive on PreInvocation (Opus 4.2c re-review): the check must act there too.
expect_job 'agy PreInvocation routes' images "$(ev agy 'Generate an image of a lighthouse at dawn' | kit_jq -c '.event="PreInvocation"')"

# 5.3e coding regressions from every recorded Sol prompt.
expect_none '5.3e coding' "$(ev claude 'Add a logo button in Svelte.')"
expect_none '5.3e coding' "$(ev claude 'Translate this C# routine into Kotlin.')"
expect_none '5.3e coding' "$(ev claude 'Convert PNG to SVG using ImageMagick.')"
expect_none '5.3e coding' "$(ev claude 'Add a background removal toggle in SwiftUI.')"
expect_none '5.3e coding' "$(ev claude 'Create a speech to text adapter in C++.')"
expect_none '5.3e coding' "$(ev claude 'Fix the text to speech integration in .NET.')"
expect_none '5.3e coding' "$(ev claude 'Write an OCR wrapper in Ruby.')"
expect_none '5.3e coding' "$(ev claude 'Generate an image thumbnailer in Go.')"
expect_none '5.3e coding' "$(ev claude 'Add image compression to the upload handler.')"
expect_none '5.3e coding' "$(ev claude 'Fix the translation endpoint timeout.')"
expect_none '5.3e coding' "$(ev claude 'Write a voiceover queue worker in Python.')"
expect_none '5.3e coding' "$(ev claude 'Update the logo component in React.')"
expect_none '5.3e coding' "$(ev claude 'Convert the OCR response schema to JSON.')"
expect_none '5.3e coding' "$(ev claude 'Generate a picture preview in src/Preview.tsx.')"
expect_none '5.3e coding' "$(ev claude 'Add image lazy loading to the frontend.')"
expect_none '5.3e coding' "$(ev claude 'Write tests for the audio transcription API.')"
expect_none '5.3e coding' "$(ev claude 'Write a Bash converter for PNG to SVG using ImageMagick.')"
expect_none '5.3e coding' "$(ev claude 'Translate this into Kotlin')"
expect_none '5.3e coding' "$(ev claude 'Make an image in R')"
expect_none '5.3e coding' "$(ev claude 'Create a Rust image tool')"
expect_none '5.3e coding' "$(ev claude 'Make an image in Java')"
expect_none '5.3e coding' "$(ev claude 'Make an image in Swift')"
expect_job "5.3e operation" images "$(ev claude 'Create an image for an album about background music.')"
expect_job "5.3e operation" text-to-video "$(ev claude 'Make a video about speech to text.')"
expect_job "5.3e operation" logo-svg "$(ev claude 'Make a logo about background music')"

# 5.3g: recall first. Only explicit code signals stop a match; soft coding prompts may match (one
# ignorable sentence), so the old "soft coding prompt matches nothing" assertions are gone (see header).
for word in component endpoint handler controller migration localStorage Flask Django Rails React Celery deploy; do
  expect_none "5.3g code signal: $word" "$(ev claude "Make an image for the $word")"
done
expect_job "5.3g ordinary nouns no longer block" images "$(ev claude 'Make a poster for the job fair next week')"
expect_job "5.3g ordinary nouns no longer block" layouts "$(ev claude 'Design a business card for my consulting practice')"
expect_job "5.3g ordinary nouns no longer block" transcription "$(ev claude 'Transcribe the attached audio file and identify each speaker.')"

# kit-0.4 fix wave: the watch/describe shortcut needs the verb before the video and no make verb before it.
expect_job "fix wave: make a video to summarize is text-to-video" text-to-video "$(ev claude 'Make a short video to summarize our quarterly results')"
expect_job "fix wave: product video is text-to-video" text-to-video "$(ev claude 'Generate a product video of a luxury watch rotating on a table')"
expect_job "fix wave: video showing what happens is text-to-video" text-to-video "$(ev claude 'Make a video showing what happens when you mix baking soda and vinegar')"
expect_job "fix wave: watch a video file still understands" video-understanding "$(ev claude 'Watch clip.mp4 and describe the animal movements')"
expect_job "fix wave: summarize this video still understands" video-understanding "$(ev claude 'Summarize this video for me')"
# more code signals: PHP, Lua, other languages, and two-part relative paths
expect_none "fix wave: PHP" "$(ev claude 'Fix image loading in PHP')"
expect_none "fix wave: Lua" "$(ev claude 'Fix image loading in Lua')"
expect_none "fix wave: Haskell" "$(ev claude 'Make an image parser in Haskell')"
expect_none "fix wave: src/media" "$(ev claude 'Update the image loader in src/media')"
expect_none "fix wave: src/media full stop" "$(ev claude 'Update the image loader in src/media.')"
expect_none "fix wave: lib/uploads" "$(ev claude 'Resize the images in lib/uploads')"
expect_job "fix wave: and/or is not a path" images "$(ev claude 'Make a poster and/or flyer')"
expect_job "fix wave: images/videos is not a path" images "$(ev claude 'Create images/videos for my brand')"
expect_job "fix wave: 24/7 is not a path" images "$(ev claude 'Make an image for 24/7 support')"

# F3 regressions must each route correctly, independently of aggregate recall.
expect_job "F3 summary video" text-to-video "$(ev claude 'Summarize our quarterly results in a short video')"
expect_job "F3 describe video" text-to-video "$(ev claude 'Describe our new app in a 30 second video')"
expect_job "F3 client pair" text-to-video "$(ev claude 'Make an explainer video for our client/partner onboarding')"
expect_job "F3 docs pair" image-editing "$(ev claude 'Edit this photo for the docs/blog header')"

# ---- 5.3g: the fixed evaluation set (every prompt from the earlier reviews plus our own) ----
EVAL=$(kit_python3 "$ROOT/tests/media_eval.py" "$ROOT" 2>&1)
printf '%s\n' "$EVAL" | grep -E '^(MISS|WRONG)' | sed 's/^/  eval: /'
read -r _ MEDIA_RIGHT MEDIA_TOTAL <<EOF7
$(printf '%s\n' "$EVAL" | grep '^MEDIA ')
EOF7
read -r _ CODE_MATCHED CODE_TOTAL <<EOF8
$(printf '%s\n' "$EVAL" | grep '^CODING ')
EOF8
read -r _ SIGNAL_MATCHED SIGNAL_TOTAL <<EOF9
$(printf '%s\n' "$EVAL" | grep '^EXPLICIT ')
EOF9
echo "eval: media routed right $MEDIA_RIGHT/$MEDIA_TOTAL; coding prompts that match (allowed) $CODE_MATCHED/$CODE_TOTAL; explicit-code-signal prompts that match $SIGNAL_MATCHED/$SIGNAL_TOTAL"
if [ "${MEDIA_TOTAL:-0}" -ge 60 ] && [ "$((MEDIA_RIGHT * 100))" -ge "$((MEDIA_TOTAL * 90))" ]; then pass
else fail "eval recall: $MEDIA_RIGHT of $MEDIA_TOTAL media prompts routed right (need >= 90% of at least 60)"; fi
if [ "${SIGNAL_TOTAL:-0}" -ge 20 ] && [ "${SIGNAL_MATCHED:-1}" = 0 ]; then pass
else fail "eval code signals: $SIGNAL_MATCHED of $SIGNAL_TOTAL prompts with an explicit code signal still matched (need 0 of at least 20)"; fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
