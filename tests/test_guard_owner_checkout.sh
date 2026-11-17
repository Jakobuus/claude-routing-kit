#!/bin/bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
. "$ROOT/plugins/routing-kit/bin/kit-common"
export ROUTING_KIT_HOME=$(mktmp)
unset CW_ALLOW_OWNER_WRITE
CHECK="$ROOT/plugins/routing-kit/hooks/checks/guard_owner_checkout.py"
owner="$ROUTING_KIT_HOME/owner"
other="$ROUTING_KIT_HOME/other"
mkdir -p "$owner/sub" "$other" "$ROUTING_KIT_HOME/owner-other"
git init -q "$owner"
git init -q "$other"
ln -s "$owner" "$ROUTING_KIT_HOME/link"
profile() {
 kit_jq -n --argjson blocks "$1" --arg owner "$owner" '{blocks:$blocks,owner_checkouts:[$owner],protected_paths:[]}' > "$ROUTING_KIT_HOME/profile.json"
}
profile true
cwd="$other"
target="$owner/file"
second=""
check() {
  local expected="$1" desc="$2" cmd="$3" agent="${4:-claude}" kind="${5:-write}" name="${6:-Write}" output code event
  event=$(kit_jq -n --arg agent "$agent" --arg kind "$kind" --arg name "$name" --arg cmd "$cmd" --arg p "$target" --arg second "$second" --arg cwd "$cwd" '{agent:$agent,event:"PreToolUse",session_id:"guard-test",cwd:$cwd,prompt:"",first_in_turn:false,stop_hook_active:false,tool:{kind:$kind,name:$name,command:$cmd,paths:(if $kind=="write" then ([$p] + (if $second=="" then [] else [$second] end)) else [] end),params:{}}}')
  if [ ! -x "$CHECK" ]; then fail "$desc (missing executable check)"; return; fi
  output=$(printf '%s' "$event" | kit_python3 "$CHECK" 2>"$ROUTING_KIT_HOME/stderr"); code=$?
  if [ "$code" -ne 0 ]; then fail "$desc (exit $code)"; return; fi
  if [ -z "$output" ]; then
    if [ "$expected" = PASS ]; then pass; else fail "$desc (expected deny, got silence)"; fi
  elif printf '%s' "$output" | kit_jq -e --arg action "$(if [ "$expected" = BLOCK ]; then echo deny; else echo allow; fi)" 'type=="object" and .action==$action' >/dev/null 2>&1; then pass
  else fail "$desc (invalid or unexpected decision: $output)"; fi
}
check BLOCK 'foreign repository write' ''
check BLOCK 'edit' '' claude write Edit
check BLOCK 'notebook' '' claude write NotebookEdit
check BLOCK 'multi edit' '' claude write MultiEdit
cwd="$owner/sub"
check PASS 'owner repository subdirectory' ''
cwd="$ROUTING_KIT_HOME"
check BLOCK 'non repository session' ''
cwd="$other"
target="$other/file"
check PASS 'outside owner' ''
target="$ROUTING_KIT_HOME/owner-other/file"
check PASS 'prefix sibling' ''
target="$owner/clients/acme/data/live.json"
check PASS 'store carve out' ''
target="$owner/clients/acme/docs/file"
check BLOCK 'store document' ''
target="$ROUTING_KIT_HOME/link/file"
check BLOCK 'symlink into owner' ''
target="$owner/sub/../file"
check BLOCK 'parent normalization' ''
target="$owner/file"
for value in 1 true yes y; do
 export CW_ALLOW_OWNER_WRITE="$value"
 check BLOCK "boolean override $value" ''
done
unset CW_ALLOW_OWNER_WRITE
check PASS 'other tool' '' claude other Read
for agent in claude codex agy; do
 case "$agent" in claude) shell=Bash; write=Write;; codex) shell=Bash; write=apply_patch;; agy) shell=run_command; write=edit_file;; esac
 check PASS "$agent shell" 'echo ok' "$agent" shell "$shell"
 check BLOCK "$agent write" '' "$agent" write "$write"
done
target="$other/file"
second="$owner/moved"
check BLOCK 'move destination' '' codex write apply_patch
target="$owner/moved"
second="$other/file"
check BLOCK 'move source' '' codex write apply_patch
# One call, one decision: several forbidden targets must print exactly one JSON object.
check_single() {
  local desc="$1" output code event
  event=$(kit_jq -n --arg cwd "$other" --arg a "$owner/one" --arg b "$owner/two" '{agent:"codex",event:"PreToolUse",session_id:"guard-test",cwd:$cwd,prompt:"",first_in_turn:false,stop_hook_active:false,tool:{kind:"write",name:"apply_patch",command:"",paths:[$a,$b],params:{}}}')
  output=$(printf '%s' "$event" | kit_python3 "$CHECK" 2>"$ROUTING_KIT_HOME/stderr"); code=$?
  if [ "$code" -ne 0 ]; then fail "$desc (exit $code)"; return; fi
  if printf '%s' "$output" | kit_jq -s -e 'length==1 and .[0].action=="deny"' >/dev/null 2>&1; then pass
  else fail "$desc (expected exactly one deny, got: $output)"; fi
}
profile true
check_single 'two forbidden targets give one decision'
profile '{"owner_checkout":true}'
check BLOCK 'object switch {"owner_checkout":true}' ''
profile '{"owner_checkout":false}'
check PASS 'object switch {"owner_checkout":false}' ''
profile '{}'
check PASS 'object switch {}' ''
profile '{"destructive":true}'
check PASS 'object switch {"destructive":true}' ''
profile false
check PASS 'blocks false write' ''
check PASS 'blocks false shell' 'echo ok' agy shell run_command
printf 'test_guard_owner_checkout: PASS=%s FAIL=%s\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
