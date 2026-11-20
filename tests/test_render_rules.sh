#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/plugins/routing-kit/bin/kit-common"
F="$ROOT/tests/fixtures/render"
p=$(mktmp)
export CODEX_HOME="$p/no-codex" ROUTING_KIT_HOME="$p/no-kit"
render() {
  kit_python3 "$ROOT/plugins/routing-kit/lib/render_rules.py" --agent "$1" \
    --kit-rules "$2" --private-rules "$3" --table "$4" --role lead
}
absent() {
  case "$1" in *"$2"*) fail "$3";; *) pass;; esac
}
# 1–3: shared text, single-agent and multi-agent blocks, whole-line markers.
for agent in claude codex gemini; do
  render "$agent" "$F/kit.md" "$F/private.md" "$F/table.md" > "$p/$agent" 
  assert_eq 0 "$?" "$agent renders fixtures"
  out=$(cat "$p/$agent")
  assert_contains "$out" 'Shared opening.' "$agent shared opening"
  assert_contains "$out" 'Shared closing.' "$agent shared closing"
  assert_contains "$out" 'Inline <!-- only:claude --> stays literal.' "$agent inline marker is literal"
  markers=$(sed -n '/^[[:space:]]*<!--[[:space:]]*only:/p; /^[[:space:]]*<!--[[:space:]]*\/only[[:space:]]*-->/p' "$p/$agent")
  assert_eq '' "$markers" "$agent has no marker lines"
  if [ "$agent" = claude ]; then
    assert_contains "$out" 'Claude exclusive.' 'claude gets X'
    absent "$out" 'Codex and Gemini exclusive.' 'claude excludes Y'
  else
    absent "$out" 'Claude exclusive.' "$agent excludes X"
    assert_contains "$out" 'Codex and Gemini exclusive.' "$agent gets Y"
  fi
done
# 4–5: malformed blocks have one diagnostic line and no stdout.
for kind in nested unclosed; do
  assert_exit 2 "$kind rejected" -- render claude "$F/$kind.md" "$F/private.md" "$F/table.md"
  render claude "$F/$kind.md" "$F/private.md" "$F/table.md" > "$p/out" 2> "$p/err"
  assert_eq '' "$(cat "$p/out")" "$kind stdout empty"
  assert_contains "$(cat "$p/err")" "$kind" "$kind diagnostic"
  assert_eq 1 "$(wc -l < "$p/err" | tr -d ' ')" "$kind one stderr line"
done
# 6: build the exact expected layout from the fixture text, preserving EOF bytes.
kit=$(sed '/^[[:space:]]*<!-- only:/d; /^[[:space:]]*<!-- \/only -->/d; /Codex and Gemini exclusive\./d' "$F/kit.md")
private=$(cat "$F/private.md")
table=$(cat "$F/table.md")
expected=$(printf '%s\n\n%s\n\n%s\n' "$kit" "$private" "$table"; printf '@')
actual=$(cat "$p/claude"; printf '@')
assert_eq "$expected" "$actual" 'exact kit/private/table order and newlines'
# 7: empty stdin skips the private part entirely.
render claude "$F/kit.md" - "$F/table.md" < /dev/null > "$p/stdin"
assert_eq 0 "$?" 'empty stdin succeeds'
expected=$(printf '%s\n\n%s\n' "$kit" "$table"; printf '@')
actual=$(cat "$p/stdin"; printf '@')
assert_eq "$expected" "$actual" 'empty stdin exact layout'
# 8: decisions beat the guide, using real rules and a generated real table.
printf '%s\n' '{"version":1,"claude_plan":"pro","codex":"plus","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p/profile.json"
"$ROOT/plugins/routing-kit/bin/kit-routing-table" --profile "$p/profile.json" > "$p/table"
assert_eq 0 "$?" 'real table generated'
for agent in claude codex gemini; do
  render "$agent" "$ROOT/plugins/routing-kit/rules/RULES.md" - "$p/table" < /dev/null > "$p/real"
  assert_eq 0 "$?" "$agent real rules succeeds"
  out=$(cat "$p/real")
  for forbidden in '--sandbox' '-s read-only' sandboxed; do
    absent "$out" "$forbidden" "$agent excludes $forbidden"
  done
done
# Full profiles render a compact, two-column block for every reader.
printf '%s\n' '{"version":1,"claude_plan":"max20","codex":"pro","gemini":"ultra","jules":true}' > "$p/full.json"
for agent in claude codex gemini; do
  "$ROOT/plugins/routing-kit/bin/kit-routing-table" --profile "$p/full.json" --main "$agent" > "$p/full-table"
  out=$(kit_python3 "$ROOT/plugins/routing-kit/lib/render_rules.py" --agent "$agent" --main "$agent" --profile "$p/full.json" --kit-rules "$ROOT/plugins/routing-kit/rules/RULES.md" --private-rules /dev/null --table "$p/full-table" --role lead)
  assert_contains "$out" 'Name the model on every worker' "$agent worker model rule"
  assert_contains "$out" 'delegating' "$agent build skill"
  lines=$(printf '%s\n' "$out" | wc -l)
  chars=$(printf '%s' "$out" | wc -m)
  [ "$lines" -le 45 ] && pass || fail "$agent exceeds 45 lines"
  [ "$chars" -le 3000 ] && pass || fail "$agent exceeds 3000 characters"
  awk -F'|' '/^\|/ {if (NF != 4) exit 1}' "$p/full-table" && pass || fail "$agent table columns"
  for phrase in 'Notes |' '(trial)' 'never max' 'at high, never low' 'medium or high' 'prompts under 100K' 'strong models plan and review, never code' 'never Fable' 'never the top model' 'Read-only lookups' 'Bulk mechanical edits' 'Very long single outputs'; do
    absent "$out" "$phrase" "$agent excludes $phrase"
  done
done
# kit_rules "replace": private rules and the table stand in for all kit rules.
printf '## Talking to the user\nKIT GENERIC LINE\n\n## Sessions and media\nKIT BOARD LINE\n\n## Advisers\nKIT ADVISER LINE\n' > "$p/kit-r.md"
printf 'OWNER LINE\n' > "$p/priv-r.md"; printf 'TABLE\n' > "$p/table-r.md"
printf '{"version":1,"kit_rules":"replace"}' > "$p/prof-replace.json"
out=$(kit_python3 "$ROOT/plugins/routing-kit/lib/render_rules.py" --agent claude --kit-rules "$p/kit-r.md" \
  --private-rules "$p/priv-r.md" --table "$p/table-r.md" --role lead --profile "$p/prof-replace.json")
absent "$out" 'KIT BOARD LINE' 'replace drops all kit rules'
assert_contains "$out" 'OWNER LINE' 'replace keeps the private rules'
absent "$out" 'KIT GENERIC LINE' 'replace drops the kit generic rules'
absent "$out" 'KIT ADVISER LINE' 'replace drops later kit sections'
out=$(kit_python3 "$ROOT/plugins/routing-kit/lib/render_rules.py" --agent claude --kit-rules "$p/kit-r.md" \
  --private-rules "$p/priv-r.md" --table "$p/table-r.md" --role lead)
assert_contains "$out" 'KIT GENERIC LINE' 'without the profile key the kit rules stay'
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
