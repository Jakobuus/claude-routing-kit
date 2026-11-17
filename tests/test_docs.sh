#!/bin/bash
# tests/test_docs.sh: README.md and START-HERE.md only name things that exist.
#   - every kit-... / locked-build command exists in plugins/routing-kit/bin
#   - every model ID names an entry of rules/models.json
#   - each README example table equals kit-routing-table for the profile it states
#   - the Claude plan values START-HERE tells the agent to save are accepted
# (tests/test_routing_table.sh separately keeps model IDs out of everything else.)
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$REPO_ROOT/plugins/routing-kit/bin"
MODELS="$REPO_ROOT/plugins/routing-kit/rules/models.json"
README="$REPO_ROOT/README.md"
START="$REPO_ROOT/START-HERE.md"
p=$(mktmp)
# Hermetic: no local Codex or Gemini lists, no real kit home.
export CODEX_HOME="$p/no-codex"

# --- required wording -------------------------------------------------------
assert_contains "$(cat "$README")" "## If you are an AI agent" "README has the agent block"
assert_contains "$(cat "$README")" "Fetch \`START-HERE.md\`" "README tells the agent to fetch START-HERE.md"
assert_contains "$(cat "$README")" "Set up https://github.com/Jakobuus/claude-routing-kit for me" "README has the line a person pastes"
assert_contains "$(cat "$START")" "Which agent do you mainly work in: Claude Code, Codex, or Gemini (Antigravity)?" "START-HERE asks the main-agent question"
assert_contains "$(cat "$START")" "git clone https://github.com/Jakobuus/claude-routing-kit ~/.config/routing-kit/kit" "START-HERE clones to the kit folder"
assert_contains "$(cat "$START")" "/hooks" "START-HERE tells Codex users to trust the hook"
assert_contains "$(cat "$START")" "not been tested end to end" "START-HERE says Gemini main is untested"
assert_contains "$(cat "$START")" "kit-profile set claude_plan none" "START-HERE covers a user without a Claude plan"
for f in "$START" "$README"; do
  assert_contains "$(cat "$f")" "kit-install-rules --agent codex --uninstall" "$(basename "$f") removes codex"
  assert_contains "$(cat "$f")" "--agent gemini" "$(basename "$f") covers gemini"
done
assert_contains "$(cat "$START")" "git -C ~/.config/routing-kit/kit pull" "START-HERE has the update command"
assert_contains "$(cat "$README")" "git -C ~/.config/routing-kit/kit pull" "README has the update command"

for n in 15 100 300; do
  assert_contains "$(cat "$START")" "kit-profile set jules_daily_limit $n" "START-HERE maps a Jules plan to limit $n"
done

# START-HERE asks about the two guards and saves them as one setting.
assert_contains "$(cat "$START")" "Turn on the guard against destructive commands?" "START-HERE asks about the destructive guard"
assert_contains "$(cat "$START")" "Turn on the guard for owner checkouts?" "START-HERE asks about the owner-checkout guard"
assert_contains "$(cat "$START")" 'blocks: {"destructive": <true|false>, "owner_checkout": <true|false>}' "START-HERE names the blocks setting"
assert_contains "$(cat "$START")" 'kit-profile set blocks' "START-HERE saves the blocks setting"

# --- commands named in the docs exist ---------------------------------------
cmds=$(cat "$README" "$START" \
  | grep -oE '(^|[^-A-Za-z0-9_/.])(kit-[a-z][a-z-]*|locked-build)' \
  | sed -E 's/^[^kl]//; s/-+$//' | sort -u)
[ -n "$cmds" ] && pass || fail "no commands found in the docs (pattern broken?)"
for c in $cmds; do
  if [ -f "$BIN/$c" ] && [ -x "$BIN/$c" ]; then pass; else fail "docs name a command that is not in bin/: $c"; fi
done

# --- model IDs named in the docs are in models.json -------------------------
known=$(/usr/bin/jq -r '([.claude, .codex, .gemini, .kimi, .glm] | map(del(.base_url, .host)) | .[] | .[] | select(type == "string")),
  (.fallbacks | to_entries[] | .key, .value)' "$MODELS" | sort -u)
mentioned=$(cat "$README" "$START" \
  | sed 's/claude-routing-kit//g; s/claude-plugins-official//g' \
  | grep -oE '(^|[^-A-Za-z0-9_.])(gpt|gemini|claude|kimi|glm)-[a-z0-9][a-z0-9.-]*' \
  | sed -E 's/^[^gck]//; s/[.-]+$//' | sort -u)
for id in $mentioned; do
  if printf '%s\n' "$known" | grep -qx -- "$id"; then pass; else fail "docs name a model id that is not in models.json: $id"; fi
done
# The bare aliases the table uses must be real entries too.
for alias in opus sonnet haiku; do
  if grep -qw -- "$alias" "$README"; then
    if printf '%s\n' "$known" | grep -qx -- "$alias"; then pass; else fail "docs name alias $alias, not in models.json"; fi
  fi
done

# --- README example tables equal the real routing table ---------------------
blocks=0
while IFS= read -r line; do
  case "$line" in
    "<!-- example:start "*" -->")
      blocks=$((blocks + 1))
      spec=${line#"<!-- example:start "}; spec=${spec%" -->"}
      kh="$p/kit$blocks"; mkdir -p "$kh"
      get() { for kv in $spec; do case "$kv" in "$1="*) echo "${kv#*=}";; esac; done; }
      main=$(get main_agent); plan=$(get claude_plan)
      export ROUTING_KIT_HOME="$kh"
      ok=1
      for k in codex gemini jules kimi glm; do "$BIN/kit-profile" set "$k" "$(get "$k")" || ok=0; done
      if [ "$plan" = none ]; then
        "$BIN/kit-profile" set main_agent "$main" || ok=0
        "$BIN/kit-profile" set claude_plan none || ok=0
      else
        "$BIN/kit-profile" set claude_plan "$plan" || ok=0
        "$BIN/kit-profile" set main_agent "$main" || ok=0
      fi
      "$BIN/kit-profile" validate || ok=0
      [ "$ok" = 1 ] && pass || fail "example $blocks: the stated profile is not valid ($spec)"
      "$BIN/kit-routing-table" > "$p/expected$blocks.md" 2>/dev/null
      awk -v n="$blocks" '
        /^<!-- example:start / { c++ }
        c == n && /^<!-- example:end -->/ { exit }
        c == n && !/^<!--/ && NF { print }' "$README" > "$p/actual$blocks.md"
      sed -i.bak '/^$/d' "$p/expected$blocks.md" && rm -f "$p/expected$blocks.md.bak"
      if [ -s "$p/expected$blocks.md" ] && diff "$p/expected$blocks.md" "$p/actual$blocks.md" >/dev/null; then
        pass
      else
        fail "README example $blocks differs from kit-routing-table for: $spec"
        diff "$p/expected$blocks.md" "$p/actual$blocks.md" | head -10 >&2
      fi
      ;;
  esac
done < "$README"
[ "$blocks" -ge 2 ] && pass || fail "README should show at least two example tables (found $blocks)"
unset ROUTING_KIT_HOME

# --- Claude plan values START-HERE tells the agent to save are accepted ------
for v in $(grep -oE 'kit-profile set claude_plan [a-z0-9]+' "$START" | awk '{print $4}' | sort -u); do
  kh="$p/plan-$v"; mkdir -p "$kh"
  if [ "$v" = none ]; then
    ROUTING_KIT_HOME="$kh" "$BIN/kit-profile" set codex plus
    ROUTING_KIT_HOME="$kh" "$BIN/kit-profile" set main_agent codex
  fi
  if ROUTING_KIT_HOME="$kh" "$BIN/kit-profile" set claude_plan "$v" >/dev/null 2>&1; then pass
  else fail "START-HERE saves claude_plan $v, which kit-profile refuses"; fi
done

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
