#!/bin/bash
# tests/test_finish.sh — plugins/routing-kit/hooks/checks/finish.py (task 3.2c).
#
# Prompt events port the owner's ~/.claude/hooks/prep-for-exit-trigger.sh EXACTLY:
# same patterns, same two guards (length > 300, quoted spans stripped), same
# injected text (tests/fixtures/checks/finish/prep-for-exit-text.txt, taken
# byte for byte from that script's additionalContext). Acts only when
# first_in_turn is true.
#
# Stop events run the continuation judge (profile key continuation_judge) only
# when DOUBLE_SHOT_LATTE=1. The judge's own output format is the existing
# script's: {"decision":"block"|"approve","reason":...}. Its loop guard
# (~/.claude/hooks/double-shot-latte/claude-judge-continuation): when
# stop_hook_active is true, after 3 continuations for a session inside 5
# minutes the 4th is forced to stop and the counter is cleared; every
# continuation increments the counter; an "approve" clears it.
#
# Not covered here: the 5-minute window expiring (needs a clock).
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/plugins/routing-kit/bin/kit-common"
export PYTHONDONTWRITEBYTECODE=1
unset DOUBLE_SHOT_LATTE
CHECK="$ROOT/plugins/routing-kit/hooks/checks/finish.py"
FIX="$ROOT/tests/fixtures/checks/finish"
EXPECTED_TEXT=$(cat "$FIX/prep-for-exit-text.txt")
HOME_DIR=$(mktmp)          # temp ROUTING_KIT_HOME with no profile
printf '%s\n' '{"owner_name":"Sam"}' > "$HOME_DIR/profile.json"
SID_BASE="finish-test-$$-$RANDOM"
CASES=0

# ev AGENT EVENT PROMPT FIRST ACTIVE SESSION -> common event JSON
ev() {
  kit_jq -n -c --arg agent "$1" --arg event "$2" --arg prompt "$3" \
    --argjson first "$4" --argjson active "$5" --arg sid "$6" \
    '{agent:$agent,event:$event,session_id:$sid,cwd:"/REPO",prompt:$prompt,
      first_in_turn:$first,stop_hook_active:$active,
      tool:{kind:"other",name:"",command:"",paths:[],params:{}}}'
}

# run H DSL EVENT -> OUT (stdout), CODE (exit). DSL empty = variable unset.
run() {
  if [ -n "$2" ]; then
    OUT=$(printf '%s' "$3" | ROUTING_KIT_HOME="$1" DOUBLE_SHOT_LATTE="$2" kit_python3 "$CHECK" 2>/dev/null)
  else
    OUT=$(printf '%s' "$3" | ROUTING_KIT_HOME="$1" kit_python3 "$CHECK" 2>/dev/null)
  fi
  CODE=$?
}

expect_nothing() {   # MSG   (uses OUT/CODE from the last run)
  CASES=$((CASES + 1))
  if [ "$CODE" != "0" ]; then fail "$1 (check exited $CODE)"; return; fi
  assert_eq "" "$(printf '%s' "$OUT" | tr -d '[:space:]')" "$1 (expected no output)"
}

expect_prep() {      # MSG
  CASES=$((CASES + 1))
  if [ "$CODE" != "0" ]; then fail "$1 (check exited $CODE)"; return; fi
  assert_eq "context" "$(printf '%s' "$OUT" | kit_jq -r '.action' 2>/dev/null)" "$1 (action)"
  assert_eq "$EXPECTED_TEXT" "$(printf '%s' "$OUT" | kit_jq -r '.text' 2>/dev/null)" "$1 (text)"
}

no_judge_run() {      # MSG  (the last run exited 0 AND left no judge call marker)
  CASES=$((CASES + 1))
  if [ "$CODE" != "0" ]; then fail "$1 (check exited $CODE)"; return; fi
  [ ! -e "$JD/calls" ] || fail "$1"
}

prompt_fires() {     # PROMPT MSG
  run "$HOME_DIR" "" "$(ev claude UserPromptSubmit "$1" true false "$SID_BASE")"
  expect_prep "fires: $2"
}
prompt_silent() {    # PROMPT MSG
  run "$HOME_DIR" "" "$(ev claude UserPromptSubmit "$1" true false "$SID_BASE")"
  expect_nothing "silent: $2"
}

# The check itself exists and is a file the runner can feed.
CASES=$((CASES + 1))
[ -f "$CHECK" ] || fail "finish.py exists at plugins/routing-kit/hooks/checks/finish.py"

# ---------------------------------------------------------------- prompt: patterns
# pattern 1: prep(are)? (for )?exit
prompt_fires "prep for exit" "p1 prep for exit"
prompt_fires "prepare exit" "p1 prepare exit"
prompt_fires "PREP FOR EXIT" "p1 case-insensitive"
prompt_silent "prep for lunch" "p1 near miss"
# pattern 2: prep.{0,12}end.{0,6}session
prompt_fires "prep to end the session" "p2 prep to end the session"
prompt_fires "prep 1234567890 end session" "p2 gap of exactly 12 before end"
prompt_silent "prep 12345678901 end session" "p2 gap of 13 before end"
prompt_fires "prep end 1234 session" "p2 gap of exactly 6 before session"
prompt_silent "prep end 123456 session" "p2 gap of 8 before session"
# pattern 3: safe to (exit|leave)
prompt_fires "is it safe to exit?" "p3 safe to exit"
prompt_fires "safe to leave now" "p3 safe to leave"
prompt_silent "safe to enter" "p3 near miss"
# pattern 4: close (up )?(this |the )?session
prompt_fires "close this session" "p4 close this session"
prompt_fires "close up the session" "p4 close up the session"
prompt_fires "close session" "p4 close session"
prompt_silent "close the window" "p4 near miss"
# pattern 5: wrap up (this |the )?session
prompt_fires "wrap up this session" "p5 wrap up this session"
prompt_fires "wrap up session" "p5 wrap up session"
prompt_silent "wrap up this meeting" "p5 near miss"
# pattern 6: done for today
prompt_fires "ok, done for today" "p6 done for today"
prompt_silent "done for now" "p6 near miss"
# pattern 7: all pushed.*(committed|memory)
prompt_fires "all pushed and committed?" "p7 all pushed ... committed"
prompt_fires "all pushed, memory saved?" "p7 all pushed ... memory"
prompt_silent "all pushed" "p7 all pushed alone"
prompt_silent "all pushed
committed" "p7 '.' does not cross a newline"
# unrelated text and empty prompt
prompt_silent "please refactor the parser" "unrelated prompt"
prompt_silent "" "empty prompt"
prompt_fires "first line
prep for exit" "trigger on a later line of a multi-line prompt"

# ---------------------------------------------------------------- prompt: guard 1 (length)
pad() { printf 'x%.0s' $(seq 1 "$1"); }   # N times x
p300="prep for exit $(pad 286)"   # 14 + 286 = 300 characters
p301="prep for exit $(pad 287)"   # 301 characters
assert_eq 300 "${#p300}" "fixture p300 is 300 characters"
assert_eq 301 "${#p301}" "fixture p301 is 301 characters"
prompt_fires "$p300" "guard 1: exactly 300 characters still fires"
prompt_silent "$p301" "guard 1: 301 characters is too long"

# ---------------------------------------------------------------- prompt: guard 2 (quotes)
prompt_silent 'when i say "prep for exit" you run the protocol' "guard 2: double-quoted mention"
prompt_silent "when i say 'prep for exit' you run the protocol" "guard 2: single-quoted mention"
prompt_fires 'he said "hello" so prep for exit' "guard 2: quotes elsewhere do not hide a real command"
prompt_fires 'prep for exit "' "guard 2: a lone unmatched quote strips nothing"
# exact port: apostrophes count as quote marks, the span between two is stripped
prompt_silent "i can't wait, done for today, it's late" "guard 2: span between apostrophes is stripped"
prompt_fires "don't forget, it's done for today" "guard 2: phrase after the last apostrophe survives"

# ---------------------------------------------------------------- prompt: first_in_turn and agents
for agent in claude codex agy; do
  run "$HOME_DIR" "" "$(ev $agent UserPromptSubmit "prep for exit" true false "$SID_BASE")"
  expect_prep "$agent first_in_turn=true fires"
  run "$HOME_DIR" "" "$(ev $agent UserPromptSubmit "prep for exit" false false "$SID_BASE")"
  expect_nothing "$agent first_in_turn=false (later invocation, same prompt) is silent"
done
run "$HOME_DIR" "" "$(ev claude PreToolUse "prep for exit" true false "$SID_BASE")"
expect_nothing "a non-prompt event with a trigger prompt is silent"
run "$HOME_DIR" "" "$(ev claude SessionStart "prep for exit" true false "$SID_BASE")"
expect_nothing "SessionStart with a trigger prompt is silent"
# a prompt event never runs the judge, even with the gate open and a judge set
JD=$(mktmp)
cat > "$JD/judge-block" <<EOF
#!/bin/bash
echo called >> "$JD/calls"
echo '{"decision":"block","reason":"Claude evaluator determined continuation is appropriate: STUBREASON42 run the tests"}'
EOF
chmod +x "$JD/judge-block"
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-block" > "$JD/profile.json"
run "$JD" 1 "$(ev claude UserPromptSubmit "just a normal prompt" true false "$SID_BASE")"
expect_nothing "a normal prompt event does not run the judge"
no_judge_run "judge script was run for a prompt event"

# ---------------------------------------------------------------- stop: the gate
rm -f "$JD/calls"
run "$JD" "" "$(ev claude Stop "" false false "$SID_BASE-gate-unset")"
expect_nothing "stop: DOUBLE_SHOT_LATTE unset -> nothing"
no_judge_run "stop: judge must not run when DOUBLE_SHOT_LATTE is unset"
run "$JD" 0 "$(ev claude Stop "" false false "$SID_BASE-gate-0")"
expect_nothing "stop: DOUBLE_SHOT_LATTE=0 -> nothing"
run "$JD" true "$(ev claude Stop "" false false "$SID_BASE-gate-true")"
expect_nothing "stop: DOUBLE_SHOT_LATTE=true (not exactly 1) -> nothing"
no_judge_run "stop: judge must not run unless DOUBLE_SHOT_LATTE is exactly 1"

# ---------------------------------------------------------------- stop: verdicts
expect_continue() {   # MSG   (uses OUT/CODE; reason must carry the judge's text)
  CASES=$((CASES + 1))
  if [ "$CODE" != "0" ]; then fail "$1 (check exited $CODE)"; return; fi
  assert_eq "continue" "$(printf '%s' "$OUT" | kit_jq -r '.action' 2>/dev/null)" "$1 (action)"
  assert_contains "$(printf '%s' "$OUT" | kit_jq -r '.reason' 2>/dev/null)" "STUBREASON42" "$1 (reason carries the judge's reason)"
}

for agent in claude codex agy; do
  run "$JD" 1 "$(ev $agent Stop "" false false "$SID_BASE-v-$agent")"
  expect_continue "stop: $agent, judge says block -> continue"
done
# the judge receives the common event on stdin
cat > "$JD/judge-spy" <<EOF
#!/bin/bash
cat > "$JD/stdin-seen"
echo '{"decision":"block","reason":"STUBREASON42"}'
EOF
chmod +x "$JD/judge-spy"
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-spy" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "" false false "$SID_BASE-spy")"
expect_continue "stop: spy judge, block -> continue"
CASES=$((CASES + 1))
assert_eq "$SID_BASE-spy" "$(kit_jq -r '.session_id' "$JD/stdin-seen" 2>/dev/null)" "stop: judge got the event JSON (session_id) on stdin"

cat > "$JD/judge-approve" <<EOF
#!/bin/bash
echo '{"decision":"approve","reason":"Claude evaluator determined stopping is appropriate: all done"}'
EOF
chmod +x "$JD/judge-approve"
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-approve" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "" false false "$SID_BASE-approve")"
expect_nothing "stop: judge says approve -> nothing"

cat > "$JD/judge-done" <<EOF
#!/bin/bash
echo done
EOF
chmod +x "$JD/judge-done"
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-done" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "" false false "$SID_BASE-done")"
expect_nothing "stop: judge prints plain 'done' -> nothing"

cat > "$JD/judge-broken" <<EOF
#!/bin/bash
echo "boom" >&2
exit 1
EOF
chmod +x "$JD/judge-broken"
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-broken" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "" false false "$SID_BASE-broken")"
expect_nothing "stop: judge fails (exit 1, no output) -> nothing (fail open)"

printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/does-not-exist" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "" false false "$SID_BASE-missing")"
expect_nothing "stop: judge path points at nothing -> nothing"

# no profile key / no profile file
N1=$(mktmp)
printf '{"claude_plan":"pro"}\n' > "$N1/profile.json"
run "$N1" 1 "$(ev claude Stop "" false false "$SID_BASE-nokey")"
expect_nothing "stop: profile without continuation_judge -> nothing"
run "$HOME_DIR" 1 "$(ev claude Stop "" false false "$SID_BASE-noprofile")"
expect_nothing "stop: no profile file at all -> nothing"
N2=$(mktmp)
printf '{"claude_plan":"pro","continuation_judge":""}\n' > "$N2/profile.json"
run "$N2" 1 "$(ev claude Stop "" false false "$SID_BASE-emptykey")"
expect_nothing "stop: empty continuation_judge -> nothing"

# a stop event never fires the prep-for-exit trigger
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-approve" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "prep for exit" true false "$SID_BASE-stopprompt")"
expect_nothing "stop: trigger phrase in prompt on a stop event -> nothing"

# ---------------------------------------------------------------- stop: loop guard
# Judge always says block. Loop guard from the existing judge: with
# stop_hook_active true, 3 continuations then the 4th is forced to stop
# (and the counter is cleared, so the 5th continues again).
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-block" > "$JD/profile.json"
G="$SID_BASE-guard"
run "$JD" 1 "$(ev claude Stop "" false true "$G")"; expect_continue "loop guard: active #1 continues"
run "$JD" 1 "$(ev claude Stop "" false true "$G")"; expect_continue "loop guard: active #2 continues"
run "$JD" 1 "$(ev claude Stop "" false true "$G")"; expect_continue "loop guard: active #3 continues"
run "$JD" 1 "$(ev claude Stop "" false true "$G")"; expect_nothing "loop guard: active #4 forced to stop"
run "$JD" 1 "$(ev claude Stop "" false true "$G")"; expect_continue "loop guard: counter cleared after forced stop, #5 continues"
# a different session is counted separately
run "$JD" 1 "$(ev claude Stop "" false true "$G-other")"; expect_continue "loop guard: other session starts at zero"

# stop_hook_active false is never stopped by the guard
G2="$SID_BASE-inactive"
for n in 1 2 3; do
  run "$JD" 1 "$(ev claude Stop "" false false "$G2")"; expect_continue "loop guard: inactive stop #$n continues"
done
# ...but every continuation counted: the next ACTIVE stop in the window is forced
run "$JD" 1 "$(ev claude Stop "" false true "$G2")"; expect_nothing "loop guard: 3 inactive continues count, then active is forced to stop"

# an approve clears the counter
G3="$SID_BASE-reset"
run "$JD" 1 "$(ev claude Stop "" false true "$G3")"; expect_continue "reset: active #1 continues"
run "$JD" 1 "$(ev claude Stop "" false true "$G3")"; expect_continue "reset: active #2 continues"
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-approve" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "" false true "$G3")"; expect_nothing "reset: judge approves -> nothing"
printf '{"claude_plan":"pro","continuation_judge":"%s"}\n' "$JD/judge-block" > "$JD/profile.json"
run "$JD" 1 "$(ev claude Stop "" false true "$G3")"; expect_continue "reset: after approve, active #1 continues"
run "$JD" 1 "$(ev claude Stop "" false true "$G3")"; expect_continue "reset: after approve, active #2 continues"
run "$JD" 1 "$(ev claude Stop "" false true "$G3")"; expect_continue "reset: after approve, active #3 continues (counter was cleared)"
run "$JD" 1 "$(ev claude Stop "" false true "$G3")"; expect_nothing "reset: after approve, active #4 forced to stop"

# Regression: adapt native agy prompts before exercising the check.
for first in 0 1; do
  payload=$(kit_jq -nc --argjson n "$first" '{hookEventName:"PreInvocation",invocationNum:$n,lastUserInput:"prep for exit"}' | kit_python3 "$ROOT/plugins/routing-kit/lib/hook_adapt.py" in agy)
  run "$HOME_DIR" "" "$payload"
  if [ "$first" = 0 ]; then expect_prep "agy native first invocation"; else expect_nothing "agy native later invocation"; fi
done
prompt_fires "$p300

" "300 characters with trailing newlines"
# Match the real judge's transcript gate and decision/reason protocol.
cat > "$JD/judge-transcript" <<'STUB'
#!/usr/bin/env python3
import json, sys
from pathlib import Path
e = json.load(sys.stdin)
p = e.get('transcript_path', '')
if not p or not Path(p).is_file():
    print(json.dumps({'decision':'approve','reason':'No transcript available for evaluation'}))
else:
    print(json.dumps({'decision':'block','reason':'STUBREASON42'}))
STUB
chmod +x "$JD/judge-transcript"
printf '{"continuation_judge":"%s"}\n' "$JD/judge-transcript" > "$JD/profile.json"
printf '{}\n' > "$JD/transcript"
for agent in claude agy; do
  payload=$(kit_jq -nc --arg p "$JD/transcript" '{hook_event_name:"Stop",hookEventName:"Stop",transcript_path:$p,transcriptPath:$p}' | kit_python3 "$ROOT/plugins/routing-kit/lib/hook_adapt.py" in "$agent")
  run "$JD" 1 "$payload"
  expect_continue "$agent native transcript reaches judge"
done

ownerhome=$(mktmp)
payload=$(ev claude UserPromptSubmit 'prep for exit' true false owner-test)
run "$ownerhome" '' "$payload"
assert_contains "$OUT" 'the owner asked' 'default owner wording'
printf '%s\n' '{"owner_name":"Alex"}' > "$ownerhome/profile.json"
run "$ownerhome" '' "$payload"
assert_contains "$OUT" 'Alex asked' 'configured owner wording'

echo "cases: $CASES"
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
