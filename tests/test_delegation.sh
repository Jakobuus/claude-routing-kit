#!/bin/bash
# Tests for plugins/routing-kit/hooks/checks/delegation.py (task 3.2b).
# Agent cases are ported from ~/.claude/hooks/test-require-subagent-model.sh;
# shell cases run once per agent (claude Bash, codex Bash, agy run_command).
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/plugins/routing-kit/bin/kit-common"
CHECK="$ROOT/plugins/routing-kit/hooks/checks/delegation.py"

KHOME=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$KHOME/profile.json"

# run_check JSON -> sets OUT (stdout) and CODE (exit status). Runs exactly as the kit does.
run_check() {
  OUT=$(printf '%s' "$1" | env ROUTING_KIT_HOME="$KHOME" bash -c \
    '. "$1/plugins/routing-kit/bin/kit-common"; kit_python3 "$2"' _ "$ROOT" "$CHECK" 2>/dev/null)
  CODE=$?
}

# ev_shell AGENT TOOLNAME COMMAND -> common event JSON for a shell tool call
ev_shell() {
  local key=command
  [ "$1" = agy ] && key=CommandLine
  kit_jq -n -c --arg a "$1" --arg n "$2" --arg c "$3" --arg k "$key" \
    '{agent:$a,event:"PreToolUse",session_id:"s1",cwd:"/tmp",prompt:"",first_in_turn:false,stop_hook_active:false,
      tool:{kind:"shell",name:$n,command:$c,paths:[],params:({($k):$c})}}'
}

# ev_agent AGENT TOOLNAME PARAMS_JSON -> common event JSON for a subagent tool call
ev_agent() {
  kit_jq -n -c --arg a "$1" --arg n "$2" --argjson p "$3" \
    '{agent:$a,event:"PreToolUse",session_id:"s1",cwd:"/tmp",prompt:"",first_in_turn:false,stop_hook_active:false,
      tool:{kind:"agent",name:$n,command:"",paths:[],params:$p}}'
}

# expect_allow LABEL JSON: exit 0 and no decision (or an explicit allow)
expect_allow() {
  run_check "$2"
  if [ "$CODE" != 0 ]; then fail "$1: expected allow, check exited $CODE"; return; fi
  if [ -z "$OUT" ]; then pass; return; fi
  if [ "$(printf '%s' "$OUT" | kit_jq -r '.action' 2>/dev/null)" = allow ]; then pass; return; fi
  fail "$1: expected allow, got [$OUT]"
}

# expect_deny LABEL JSON NEEDLE: exit 0, action deny, reason contains NEEDLE (case-insensitive)
expect_deny() {
  run_check "$2"
  if [ "$CODE" != 0 ]; then fail "$1: expected deny, check exited $CODE"; return; fi
  local action reason
  action=$(printf '%s' "$OUT" | kit_jq -r '.action' 2>/dev/null)
  if [ "$action" != deny ]; then fail "$1: expected deny, got [$OUT]"; return; fi
  reason=$(printf '%s' "$OUT" | kit_jq -r '.reason // ""' | tr '[:upper:]' '[:lower:]')
  case "$reason" in
    *"$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"*) pass ;;
    *) fail "$1: deny reason does not name [$3] (reason: $reason)" ;;
  esac
}

# The check must exist (python file run via kit_python3).
if [ -f "$CHECK" ]; then pass; else fail "delegation.py exists at plugins/routing-kit/hooks/checks/"; fi

# ---- Agent kind (Claude Agent): ported from test-require-subagent-model.sh ----
ag() { ev_agent claude Agent "$1"; }
expect_deny  "gp no model"       "$(ag '{"subagent_type":"general-purpose","effort":"medium","prompt":"x"}')" "model"
expect_deny  "no type no model"  "$(ag '{"effort":"medium","prompt":"x"}')" "model"
expect_deny  "claude no model"   "$(ag '{"subagent_type":"claude","effort":"medium","prompt":"x"}')" "model"
expect_deny  "Plan no model"     "$(ag '{"subagent_type":"Plan","effort":"medium","prompt":"x"}')" "model"
expect_allow "gp explicit opus"  "$(ag '{"subagent_type":"general-purpose","model":"opus","effort":"medium","prompt":"x"}')"
expect_allow "gp explicit haiku" "$(ag '{"subagent_type":"general-purpose","model":"haiku","effort":"medium","prompt":"x"}')"
expect_allow "fork"              "$(ag '{"subagent_type":"fork","prompt":"x"}')"
expect_allow "Explore"           "$(ag '{"subagent_type":"Explore","effort":"medium","prompt":"x"}')"
expect_allow "custom pinned def" "$(ag '{"subagent_type":"fresh-reviewer","effort":"medium","prompt":"x"}')"
expect_allow "plugin agent"      "$(ag '{"subagent_type":"episodic-memory:search-conversations","effort":"medium","prompt":"x"}')"
expect_deny  "gp model but no effort" "$(ag '{"subagent_type":"general-purpose","model":"sonnet","prompt":"x"}')" "effort"
expect_deny  "custom def no effort"   "$(ag '{"subagent_type":"fresh-reviewer","prompt":"x"}')" "effort"
expect_deny  "empty effort"           "$(ag '{"subagent_type":"general-purpose","model":"sonnet","effort":"","prompt":"x"}')" "effort"
expect_allow "gp model and effort"    "$(ag '{"subagent_type":"general-purpose","model":"sonnet","effort":"high","prompt":"x"}')"
expect_allow "explicit fable agent is allowed" "$(ag '{"subagent_type":"general-purpose","model":"fable","effort":"high","prompt":"x"}')"
expect_allow "not Agent tool (Bash ls)" "$(ev_shell claude Bash 'ls')"
expect_allow "other tool kind (Write)" "$(kit_jq -n -c '{agent:"claude",event:"PreToolUse",session_id:"s1",cwd:"/tmp",prompt:"",first_in_turn:false,stop_hook_active:false,tool:{kind:"write",name:"Write",command:"",paths:["/tmp/x"],params:{file_path:"/tmp/x"}}}')"
expect_allow "malformed json" 'not json at all'
# the effort message keeps the original wording
run_check "$(ag '{"subagent_type":"general-purpose","model":"sonnet","prompt":"x"}')"
assert_contains "$OUT" 'has no `effort`' "effort message wording ported"

# ---- Antigravity subagent tiers flash|pro are allowed (no effort/model rules apply) ----
expect_allow "agy subagent tier flash (model)" "$(ev_agent agy invoke_subagent '{"model":"flash","prompt":"x"}')"
expect_allow "agy subagent tier pro (model)"   "$(ev_agent agy invoke_subagent '{"model":"pro","prompt":"x"}')"
expect_allow "agy subagent tier flash (type)"  "$(ev_agent agy invoke_subagent '{"subagent_type":"flash","prompt":"x"}')"
expect_allow "agy subagent tier pro (type)"    "$(ev_agent agy invoke_subagent '{"subagent_type":"pro","prompt":"x"}')"

# ---- Shell kind, once per agent ----
for pair in claude:Bash codex:Bash agy:run_command; do
  A=${pair%%:*}; T=${pair#*:}
  shc() { ev_shell "$A" "$T" "$1"; }
  expect_deny "paseo missing model" "$(shc 'paseo run x')" "--model"
  expect_deny "paseo fable" "$(shc 'paseo run --model fable --thinking high x')" "fable"
  expect_deny "paseo missing thinking" "$(shc 'paseo run --model sonnet x')" "--thinking"
  expect_allow "paseo explicit" "$(shc 'paseo run --model=sonnet --thinking=high x')"
  expect_allow "paseo help" "$(shc 'paseo run --help')"
  expect_allow "paseo lookup" "$(shc 'which paseo run')"
  expect_deny "claude missing effort" "$(shc 'claude -p --model sonnet x')" "--effort"
  expect_deny "agy missing effort" "$(shc 'agy -p --model gemini x')" "--effort"
  expect_deny "codex missing effort" "$(shc 'codex exec -m sol x')" "model_reasoning_effort"
  expect_allow "codex config equals" "$(shc 'codex exec -m sol --config=model_reasoning_effort=high x')"
  expect_allow "agy effort equals" "$(shc 'agy -p --model gemini --effort=high x')"
  expect_deny  "$A: claude -p without --model" "$(shc 'claude -p "x"')" "--model"
  expect_deny  "$A: claude --print without --model" "$(shc 'claude --print "x"')" "--model"
  expect_deny  "$A: claude -p names Fable" "$(shc 'claude -p --model claude-fable-5-2 "x"')" "fable"
  expect_deny  "$A: claude -p --model=fable form" "$(shc 'claude -p --model=claude-fable-5-2 "x"')" "fable"
  expect_allow "$A: env A=1 claude --print --model sonnet" "$(shc 'env A=1 claude --print --effort high --model claude-sonnet-5-5 x')"
  expect_allow "$A: claude -p --model sonnet" "$(shc 'claude -p --effort high --model claude-sonnet-5-5 "x"')"
  expect_deny  "$A: cd && timeout 60 claude -p" "$(shc 'cd /x && timeout 60 claude -p x')" "--model"
  expect_allow "$A: cd && timeout 60 claude -p --model" "$(shc 'cd /x && timeout 60 claude -p --effort high --model claude-sonnet-5-5 x')"
  expect_allow "$A: claude without -p (interactive)" "$(shc 'claude --version')"
  expect_deny  "$A: codex exec without model" "$(shc 'codex exec "x"')" "--model"
  expect_allow "$A: codex exec -m" "$(shc 'codex exec -c model_reasoning_effort=high -m gpt-6.1-sol x')"
  expect_allow "$A: codex exec --model" "$(shc 'codex exec -c model_reasoning_effort=high --model gpt-6.1-sol x')"
  expect_deny  "$A: agy -p without --model" "$(shc 'agy -p "x"')" "--model"
  expect_allow "$A: agy --model -p" "$(shc 'agy --effort high --model gemini-4-argon-high -p x')"
  for b in codex-build agy-build kit-codex-build kit-gemini-build; do
    expect_deny  "$A: $b without --model" "$(shc "$b --repo /r --name n --brief /b.md")" "--model"
    effort=""
    case "$b" in agy-build) effort="--effort high";; esac
    expect_allow "$A: $b with --model" "$(shc "$b --repo /r --name n --brief /b.md --model gpt-6.1-sol $effort")"
  done
  expect_allow "$A: ls" "$(shc 'ls')"
  expect_allow "$A: text merely mentions claude -p" "$(shc 'echo "claude -p x"')"

  # 3.2d finding 1: judge each simple command on its own (|, ||, &&, ;, newline)
  expect_allow "$A: claude --help | grep -- -p (grep's -p is not claude's)" "$(shc 'claude --help | grep -- -p')"
  expect_allow "$A: git commit message mentions codex exec" "$(shc 'git commit -m "codex exec foo"')"
  expect_allow "$A: quoted && does not split" "$(shc 'echo "a && claude -p x"')"
  expect_allow "$A: quoted ; does not split" "$(shc "grep 'a;claude -p' f")"
  expect_allow "$A: comment mentions claude -p" "$(shc 'ls # claude -p x')"
  expect_deny  "$A: echo && claude -p" "$(shc 'echo ready && claude -p x')" "--model"
  expect_deny  "$A: claude -p ; after echo" "$(shc 'echo ready; claude -p x')" "--model"
  expect_deny  "$A: pipe into claude -p" "$(shc 'cat f | claude -p')" "--model"
  expect_deny  "$A: newline separates commands" "$(shc $'echo hi\nclaude -p x')" "--model"
  expect_deny  "$A: claude -p && echo --model sonnet (model belongs to echo)" "$(shc 'claude -p x && echo --model sonnet')" "--model"
  expect_allow "$A: heredoc body mentioning --model fable" "$(shc $'cat <<\'EOF\' | claude -p --effort high --model claude-sonnet-5-5\nuse --model fable here\nEOF')"
  expect_allow "$A: unparsable command is allowed" "$(shc 'claude -p "x')"

  # 3.2d finding 2: common prefixes
  expect_deny  "$A: A=1 claude -p" "$(shc 'A=1 claude -p x')" "--model"
  expect_deny  "$A: bash -c 'claude -p'" "$(shc "bash -c 'claude -p x'")" "--model"
  expect_deny  "$A: sh -lc 'claude -p'" "$(shc "sh -lc 'cd /x && claude -p x'")" "--model"
  expect_deny  "$A: bash -euo pipefail -c 'claude -p'" "$(shc "bash -euo pipefail -c 'claude -p x'")" "--model"
  expect_allow "$A: bash script.sh -c is a script argument" "$(shc 'bash script.sh -c claude')"
  expect_deny  "$A: nohup claude -p" "$(shc 'nohup claude -p x')" "--model"
  expect_deny  "$A: sudo claude -p" "$(shc 'sudo claude -p x')" "--model"
  expect_deny  "$A: sudo -u user claude -p" "$(shc 'sudo -u bob claude -p x')" "--model"
  expect_deny  "$A: xargs claude -p" "$(shc 'xargs claude -p < prompts.txt')" "--model"
  expect_deny  "$A: /usr/bin/env A=1 claude -p" "$(shc '/usr/bin/env A=1 claude -p x')" "--model"
  expect_deny  "$A: absolute path claude -p" "$(shc '/usr/local/bin/claude -p x')" "--model"
  expect_deny  "$A: caffeinate codex-build" "$(shc 'caffeinate -i codex-build --repo /r --name n --brief /b.md')" "--model"
  expect_allow "$A: A=1 claude -p --model" "$(shc 'A=1 claude -p --effort high --model claude-sonnet-5-5 x')"
  expect_allow "$A: bash -c with --model" "$(shc "bash -c 'claude -p --effort high --model claude-sonnet-5-5 x'")"
  expect_allow "$A: nohup claude -p --model" "$(shc 'nohup claude -p --effort high --model claude-sonnet-5-5 x')"
  expect_allow "$A: xargs claude -p --model" "$(shc 'xargs claude -p --effort high --model claude-sonnet-5-5 < prompts.txt')"
  expect_deny  "$A: bash -c names Fable" "$(shc "bash -c 'claude -p --model claude-fable-5-2 x'")" "fable"

  # 3.2d finding 3: help and version requests start no worker
  expect_allow "$A: codex exec --help" "$(shc 'codex exec --help')"
  expect_allow "$A: claude -p --help" "$(shc 'claude -p --help')"
  expect_allow "$A: codex-build --help" "$(shc 'codex-build --help')"
  expect_allow "$A: agy -p -h" "$(shc 'agy -p -h')"
  expect_allow "$A: claude --print --version" "$(shc 'claude --print --version')"

  # 3.2d finding 4: after -- the words are prompt text
  expect_deny  "$A: claude -p -- --model=sonnet" "$(shc "claude -p -- '--model=sonnet'")" "--model"
  expect_deny  "$A: claude -p -- --model sonnet" "$(shc 'claude -p -- --model claude-sonnet-5-5')" "--model"
  expect_deny  "$A: codex exec -- -m model" "$(shc 'codex exec -- -m gpt-6.1-sol x')" "--model"
  expect_allow "$A: claude -p --model sonnet -- prompt" "$(shc 'claude -p --effort high --model claude-sonnet-5-5 -- x')"
  expect_allow "$A: --help after -- is prompt text but model given" "$(shc 'claude -p --effort high --model claude-sonnet-5-5 -- --help')"
  expect_deny  "$A: --help after -- does not count as help" "$(shc 'claude -p -- --help')" "--model"

  # 3.2g finding 1: lookups and syntax checks start no worker
  expect_allow "$A: command -v kit-codex-build" "$(shc 'command -v kit-codex-build')"
  expect_allow "$A: command -V kit-gemini-build" "$(shc 'command -V kit-gemini-build')"
  expect_allow "$A: type claude" "$(shc 'type claude -p')"
  expect_allow "$A: which codex" "$(shc 'which codex exec')"
  expect_allow "$A: bash -n -c" "$(shc 'bash -n -c "claude -p x"')"
  expect_allow "$A: bash -nc" "$(shc "bash -nc 'claude -p x'")"
  expect_deny  "$A: command claude -p still runs" "$(shc 'command claude -p x')" "--model"

  # 3.2g finding 2: substitutions and arrays stay one word
  expect_allow "$A: claude -p \$(printf hello) --model sonnet" "$(shc 'claude -p $(printf hello) --effort high --model claude-sonnet-5-5')"
  expect_allow "$A: claude -p with backticks and --model" "$(shc 'claude -p `printf hello` --effort high --model claude-sonnet-5-5')"
  expect_allow "$A: quoted substitution with inner quotes" "$(shc 'claude -p "$(echo "a b")" --effort high --model claude-sonnet-5-5')"
  expect_allow "$A: array assignment is not a command" "$(shc 'args=(claude -p x)')"
  expect_deny  "$A: claude -p \$(printf hello) no model" "$(shc 'claude -p $(printf hello) x')" "--model"
  expect_deny  "$A: claude inside substitution is still judged" "$(shc 'out=$(claude -p x)')" "--model"
  expect_deny  "$A: bare subshell still judged" "$(shc '(cd /x && claude -p x)')" "--model"

  # 3.2g finding 3: a help token that is an option value is not a help request
  expect_deny  "$A: --name --help is a value" "$(shc 'kit-codex-build --repo /r --name --help --brief /b.md')" "--model"
  expect_deny  "$A: --brief -h is a value" "$(shc 'codex-build --repo /r --name n --brief -h')" "--model"
  expect_allow "$A: --name --help with model" "$(shc 'kit-codex-build --repo /r --name --help --brief /b.md --model gpt-6.1-sol')"
done

# 3.2d finding 5: a deeply nested event must not crash the check (exit 0, no decision)
DEEP=$(kit_python3 -c 'print("{\"event\":\"PreToolUse\",\"tool\":" + "["*2000 + "]"*2000 + "}")')
expect_allow "deeply nested JSON fails open" "$DEEP"

# The owner's documented agy and agy-build commands carry effort in the model name.
expect_allow "agy effort in model name" "$(ev_shell claude Bash 'agy --dangerously-skip-permissions --model gemini-4-argon-high --output-format json -p "x"')"
expect_allow "agy-build effort in model name" "$(ev_shell claude Bash 'agy-build --repo /r --name n --brief /b.md --model gemini-4-hydrogen-medium')"
expect_deny "agy without effort anywhere" "$(ev_shell claude Bash 'agy --model gemini-4-argon -p x')" effort
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
