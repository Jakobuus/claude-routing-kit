#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RT="$(dirname "$0")/../plugins/routing-kit/bin/kit-routing-table"
p=$(mktmp)
mk() { printf '{"version":1,"claude_plan":"%s","codex":"%s","jules":%s,"kimi":%s,"glm":%s,"paseo":false}' "$@" > "$p/profile.json"; }

mk pro none false false false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "| Review | fresh Claude opus subagent" "claude-only review"
assert_contains "$t" "| Features, bug fixes, tests | Claude sonnet" "claude-only build"
case "$t" in *codex*|*gpt-6*|*Jules*|*kimi*|*glm*) fail "claude-only must not mention other lanes";; esac

mk max5 plus false false false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "Codex gpt-6-sol · Claude sonnet" "codex build choice"
assert_contains "$t" "Claude work → Codex gpt-6-astra; Codex work → Claude opus" "cross-company review"
assert_contains "$t" "Codex gpt-6-luna · Claude haiku" "lookups"

mk pro plus true true false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "kit-jules-build" "jules row"
# Kimi/GLM are macOS-only (the Seatbelt jail): the row only appears on a
# real Mac, even for a profile that says kimi true. This file must pass on
# real macOS AND real Ubuntu, so the expectation follows the real host.
if [ "$(uname)" = Darwin ]; then
  assert_contains "$t" "locked-build --provider kimi" "kimi row on a real Mac"
else
  case "$t" in
    *"provider kimi"*) fail "kimi row appeared on this real, non-macOS host" ;;
    *) pass ;;
  esac
fi
case "$t" in *"provider glm"*) fail "glm not chosen";; esac

echo '{"version":1,"claude_plan":"bogus"}' > "$p/profile.json"
assert_exit 2 "invalid profile refused" -- "$RT" --profile "$p/profile.json"

# booleans must be JSON true/false, not strings; a string "true" must not
# silently enable a lane
p2=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":"true","kimi":false,"glm":false,"paseo":false}' > "$p2/profile.json"
assert_exit 2 "string jules:\"true\" refused" -- "$RT" --profile "$p2/profile.json"

# codex:false must not pass through default substitution as if it were "none"
p3=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":false,"jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p3/profile.json"
assert_exit 2 "codex:false refused" -- "$RT" --profile "$p3/profile.json"

# unreadable models file must fail loudly, not produce empty model names
p4=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p4/profile.json"
assert_exit 2 "unreadable models file refused" -- "$RT" --profile "$p4/profile.json" --models "$p4/nonexistent-models.json"

# incomplete models file (missing required fields) must also fail
incomplete="$p4/models-incomplete.json"
echo '{"claude":{"strong":"opus","build":"sonnet","lookup":"haiku"}}' > "$incomplete"
assert_exit 2 "incomplete models file refused" -- "$RT" --profile "$p4/profile.json" --models "$incomplete"

# a missing option value is bad input (exit 2), not a nounset crash
assert_exit 2 "bare --profile refused" -- "$RT" --profile
assert_exit 2 "bare --models refused" -- "$RT" --models

# Every plan and lane combination renders only enabled lanes.
for plan in pro max5 max20 team api; do
  for codex in none plus pro business api; do
    for jules in false true; do for kimi in false true; do for glm in false true; do
      mk "$plan" "$codex" "$jules" "$kimi" "$glm"
      t=$("$RT" --profile "$p/profile.json")
      case "$t" in *"| Review |"*) pass;; *) fail "missing review row: $plan/$codex/$jules/$kimi/$glm";; esac
      if [ "$codex" = none ]; then case "$t" in *Codex*) fail "Codex leaked";; *) pass;; esac; fi
      if [ "$jules" = false ]; then case "$t" in *Jules*) fail "Jules leaked";; *) pass;; esac; fi
      if [ "$kimi" = false ]; then case "$t" in *"provider kimi"*) fail "Kimi leaked";; *) pass;; esac; fi
      if [ "$glm" = false ]; then case "$t" in *"provider glm"*) fail "GLM leaked";; *) pass;; esac; fi
    done; done; done
  done
done

# Model identifiers belong to models.json and tests only (README.md shows a dated example table).
ids=$(/usr/bin/jq -r '[.claude, .codex, .kimi, .glm] | map(.strong?, .build?, .lookup?) | .[] | select(type == "string")' "$(dirname "$RT")/../rules/models.json" | sort -u)
for id in $ids; do
  if git -C "$REPO_ROOT" grep -l -F -w -- "$id" -- . ':!tests' ':!plugins/routing-kit/rules/models.json' ':!README.md' | grep -q .; then
    fail "model id outside models.json: $id"
  else pass; fi
done

# Kimi/GLM are macOS-only (the Seatbelt jail): on a faked Linux uname the
# row must never appear, even for a profile that says kimi/glm true (a
# hand-edited profile.json, since kit-profile itself refuses to set either
# true off-Mac).
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
mk pro plus true true true
t=$(env PATH="$fakebin:$PATH" "$RT" --profile "$p/profile.json")
case "$t" in
  *"provider kimi"*) fail "kimi row leaked on a faked Linux uname" ;;
  *) pass ;;
esac
case "$t" in
  *"provider glm"*) fail "glm row leaked on a faked Linux uname" ;;
  *) pass ;;
esac
assert_contains "$t" "kit-jules-build" "jules row still appears on a faked Linux uname"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
