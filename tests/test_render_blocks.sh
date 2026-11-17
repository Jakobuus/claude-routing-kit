#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/plugins/routing-kit/bin/kit-common"
p=$(mktmp)
printf '%s\n' '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p/profile.json"
: > "$p/empty"
render() {
  kit_python3 "$ROOT/plugins/routing-kit/lib/render_rules.py" --agent "$1" \
    --kit-rules "$p/rules" --private-rules - --table "$p/empty" --role lead "${@:2}" < /dev/null
}
printf '%s\n' '<!-- main:claude -->' 'main text' '<!-- /main:claude -->' > "$p/rules"
# main: follows who leads (--main, else the profile's main_agent, else claude),
# not which program reads the file.
assert_eq 'main text' "$(render claude)" 'main:claude kept by default'
assert_eq 'main text' "$(render codex)" 'main:claude kept in the Codex file too'
assert_eq '' "$(render codex --main codex)" 'main:claude dropped when Codex leads'
sed 's/"version":1,/"version":1,"main_agent":"gemini",/' "$p/profile.json" > "$p/lead.json"
assert_eq '' "$(render claude --profile "$p/lead.json")" 'main:claude dropped when the profile names another lead'
assert_eq 'main text' "$(render claude --profile "$p/lead.json" --main claude)" '--main beats the profile'
printf '%s\n' '<!-- lane:codex -->' 'lane text' '<!-- /lane:codex -->' > "$p/rules"
assert_eq 'lane text' "$(render claude --profile "$p/profile.json")" 'codex plus kept'
sed 's/"plus"/"none"/' "$p/profile.json" > "$p/none.json"
assert_eq '' "$(render claude --profile "$p/none.json")" 'codex none dropped'
assert_eq 'lane text' "$(render claude)" 'no profile keeps lane'
printf '%s\n' '<!-- lane:jules -->' 'jules text' '<!-- /lane:jules -->' > "$p/rules"
assert_eq '' "$(render claude --profile "$p/profile.json")" 'jules false dropped'
cp "$ROOT/plugins/routing-kit/rules/RULES.md" "$p/rules"
for agent in claude codex gemini; do
  "$ROOT/plugins/routing-kit/bin/kit-routing-table" --profile "$p/profile.json" > "$p/empty"
  assert_eq 0 "$?" "$agent real table generated"
  render "$agent" --profile "$p/profile.json" > "$p/$agent"
  assert_eq 0 "$?" "$agent real render"
  assert_eq '' "$(sed -n '/^<!--/p' "$p/$agent")" "$agent markers removed"
done
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
