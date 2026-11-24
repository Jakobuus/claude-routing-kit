#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RT="$(dirname "$0")/../plugins/routing-kit/bin/kit-routing-table"
p=$(mktmp)
# Hermetic: no local Codex or Gemini lists unless a test makes one.
export CODEX_HOME="$p/no-codex" ROUTING_KIT_HOME="$p/no-kit"
assert_not_contains() { case "$1" in *"$2"*) fail "$3";; *) pass;; esac; }
mk() { printf '{"version":1,"claude_plan":"%s","codex":"%s","jules":%s,"kimi":%s,"glm":%s,"paseo":false}' "$@" > "$p/profile.json"; }

mk pro none false false false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "| Review | a fresh Claude $(routed_model claude strong) session that did not build it" "claude-only review"
assert_contains "$t" "| Features, fixes, tests | Claude $(routed_model claude build)" "claude-only build"
case "$t" in *codex*|*gpt-6*|*Jules*|*kimi*|*glm*) fail "claude-only must not mention other lanes";; esac

mk max5 plus false false false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "Codex $(routed_model codex build) · Claude $(routed_model claude build)" "codex build choice"
assert_contains "$t" "a strong model from another company than the builder: Codex $(routed_model codex strong) · Claude $(routed_model claude strong)" "cross-company review"
assert_contains "$t" "Codex $(routed_model codex lookup) · Claude $(routed_model claude lookup)" "lookups"

mk pro plus true true false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "Jules" "jules row"
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

# Routing model identifiers belong to models.json. The guide and README show
# examples; doctor cost probes and hook self-tests deliberately name models,
# and delegation.py has a model-name example in a comment. These are not
# routing defaults. Keep the audit on routing code rather than every tracked file.
ids=$(/usr/bin/jq -r '[.claude, .codex, .gemini, .kimi, .glm] | map(del(.base_url, .host)) | .[] | .[] | select(type == "string")' "$(dirname "$RT")/../rules/models.json" | sort -u)
for id in $ids; do
  if git -C "$REPO_ROOT" grep -l -F -w -- "$id" -- . ':!tests' ':!plugins/routing-kit/hooks/fixtures' ':!plugins/routing-kit/rules/models.json' ':!plugins/routing-kit/guide' ':!README.md' ':!plugins/routing-kit/lib/doctor.py' ':!plugins/routing-kit/lib/selftest_hooks.py' ':!plugins/routing-kit/hooks/checks/delegation.py' | grep -q .; then
    fail "model id outside models.json: $id"
  else pass; fi
done


# --- 0.3: models.json shape -------------------------------------------------
M="$(dirname "$RT")/../rules/models.json"
assert_eq 2 "$(/usr/bin/jq -r .version "$M")" "models.json version 2"
# The checked date moves with every guide refresh: assert its shape, not a fixed day.
assert_eq 0 "$(/usr/bin/jq -r .checked "$M" | /usr/bin/grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}'; echo $?)" "models.json checked date is an ISO date"
# Required roles and fallback references are validated as data, independent of today's IDs.
for role in claude.top claude.strong claude.build claude.lookup claude.research codex.research codex.strong codex.review codex.build codex.screens codex.lookup gemini.strong gemini.build gemini.long_read gemini.mid gemini.lookup gemini.research; do
  assert_eq 0 "$(/usr/bin/jq -e --arg r "$role" 'getpath($r | split(".")) | strings | length > 0' "$M" >/dev/null 2>&1; echo $?)" "models.json has $role"
done
assert_eq 0 "$(/usr/bin/jq -e '.fallbacks[.codex.build] and .fallbacks[.claude.top]' "$M" >/dev/null 2>&1; echo $?)" "fallbacks for codex.build and claude.top"
assert_exit 0 "routed model roles validate" -- "$REPO_ROOT/plugins/routing-kit/bin/kit-models-validate" "$M" --guide "$REPO_ROOT/plugins/routing-kit/guide/guide.json"
bad=$(/usr/bin/jq -r '[.claude, .codex, .gemini, .kimi, .glm] | map(del(.base_url, .host)) | .[] | .[] | select(type == "string") | select(test("^[a-z0-9][a-z0-9.-]{2,60}$") | not)' "$M")
assert_eq "" "$bad" "every model id matches the id pattern"
bad=$(/usr/bin/jq -r '.effort | .[] | .[] | select(IN("low","medium","high","xhigh","max") | not)' "$M")
assert_eq "" "$bad" "effort values are valid"

# --- 0.3: the table for sample plan mixes ----------------------------------
mkf() { # plan codex gemini jules kimi glm [main_agent]
  if [ -n "${7:-}" ]; then ma=",\"main_agent\":\"$7\""; else ma=""; fi
  printf '{"version":1,"claude_plan":"%s","codex":"%s","gemini":"%s","jules":%s,"kimi":%s,"glm":%s,"paseo":false%s}' "$1" "$2" "$3" "$4" "$5" "$6" "$ma" > "$p/profile.json"
}
nrows() { n=$(printf '%s\n' "$1" | grep -c '^| '); echo $((n - 1)); }

mkf max5 plus pro true false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 11 "$(nrows "$t")" "full profile: exactly 14 rows"
assert_contains "$t" "$(routed_model codex build)" "full: sol 6.1"
assert_contains "$t" "$(routed_model codex screens)" "full: terra"
assert_contains "$t" "$(routed_model claude top)" "full: fable by full id"
case "$t" in *[Ff]lash*) fail "full: flash must not appear";; *) pass;; esac
assert_contains "$t" "| Review | a strong model from another company than the builder: Codex $(routed_model codex strong) · Claude $(routed_model claude strong) · Gemini $(routed_model gemini long_read) |" "full: review row"
assert_contains "$t" "| Hardest builds (long unattended, or failed twice) | Claude $(routed_model claude top) |" "full: fable row"
assert_contains "$t" "Claude $(routed_model claude build)" "full: sonnet"
assert_not_contains "$t" "medium or high, never above" "full: sonnet effort text"
assert_not_contains "$t" "at high, never low" "full: luna effort text"
assert_contains "$t" "| Exploration, big reads, web research | Gemini $(routed_model gemini research)" "full: exploration row (Hydrogen, no Argon)"
assert_contains "$t" "Gemini $(routed_model gemini long_read)" "full: long outputs row"
assert_contains "$t" "| Screenshots, UI checks | Codex $(routed_model codex screens) |" "full: terra row"
assert_contains "$t" "| Web pages or email while holding tools that can act | Claude $(routed_model claude strong) |" "full: untrusted row"
assert_contains "$t" "Codex $(routed_model codex lookup) · Gemini $(routed_model gemini lookup) · Claude $(routed_model claude lookup)" "full: lookups"
assert_contains "$t" "| Exploration, big reads, web research | Gemini $(routed_model gemini research) · Codex $(routed_model codex research) with web search · Claude $(routed_model claude research) |" "full: exploration uses the research roles, not the build models"
assert_contains "$t" "Gemini $(routed_model gemini research)" "full: research hydrogen high"
case "$t" in *"Note:"*) fail "full: no Note without local lists";; *) pass;; esac
# row order follows the field-guide table
order=$(printf '%s\n' "$t" | sed -n '3,$p' | cut -d'|' -f2 | cut -c2-8 | tr '\n' ',')
assert_eq "Plans, ,Feature,Hardest,Review ,Second ,Explora,Lookups,UI buil,Screens,Web pag,Mechani," "$order" "row order"

mkf pro none none false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 8 "$(nrows "$t")" "claude-only pro: 9 rows"
case "$t" in *claude-fable*) fail "pro must not show the Fable row";; *) pass;; esac
case "$t" in *[Cc]odex*|*gpt-*|*[Gg]emini*|*argon*|*hydrogen*|*Jules*|*terra*) fail "claude-only must not mention other lanes";; *) pass;; esac
for plan in max5 max20 api; do
  mkf $plan none none false false false; t=$("$RT" --profile "$p/profile.json")
  assert_eq 9 "$(nrows "$t")" "claude-only $plan: 10 rows (Fable row added)"
  assert_contains "$t" "$(routed_model claude top)" "$plan shows Fable"
done
# Standard Team seats only get Fable on paid usage credits and the profile cannot
# tell premium seats apart: no Fable row for team.
mkf team none none false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 8 "$(nrows "$t")" "claude-only team: 9 rows (no Fable row)"
case "$t" in *claude-fable*|*Hardest*) fail "team must not show the Fable row";; *) pass;; esac
# api is pay per use: no talk of a weekly share.
mkf api none none false false false; t=$("$RT" --profile "$p/profile.json")
hb=$(printf '%s\n' "$t" | grep '^| Hardest')
case "$hb" in *share*|*week*) fail "api Fable row must not mention a weekly share";; *) pass;; esac
assert_not_contains "$hb" "pay per use" "api Fable row says pay per use"
mkf max5 none none false false false; t=$("$RT" --profile "$p/profile.json")
assert_not_contains "$t" "needs room in Fable's share and the Claude week" "max5 Fable row keeps the weekly-share note"

mkf max5 plus none false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 10 "$(nrows "$t")" "claude+codex: 11 rows"
case "$t" in *[Gg]emini*|*argon*|*hydrogen*|*Jules*) fail "claude+codex must not mention gemini/jules";; *) pass;; esac
assert_contains "$t" "a strong model from another company than the builder: Codex $(routed_model codex strong) · Claude $(routed_model claude strong)" "claude+codex review"

mkf max5 none pro false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 9 "$(nrows "$t")" "claude+gemini: 12 rows"
case "$t" in *[Cc]odex*|*gpt-*|*Jules*|*terra*) fail "claude+gemini must not mention codex/jules";; *) pass;; esac
assert_contains "$t" "Claude $(routed_model claude strong)" "claude+gemini review"

# --- 0.3: --main --------------------------------------------------------
mkf max5 plus pro true false false
full=$("$RT" --profile "$p/profile.json")
assert_eq "$full" "$("$RT" --profile "$p/profile.json" --main claude)" "--main claude is the default"
assert_exit 0 "--main codex accepted" -- "$RT" --profile "$p/profile.json" --main codex
assert_exit 0 "--main gemini accepted" -- "$RT" --profile "$p/profile.json" --main gemini
case "$("$RT" --profile "$p/profile.json" --main codex)" in "$full") fail "--main codex must not print the Claude table";; *) pass;; esac
assert_exit 2 "--main bogus refused" -- "$RT" --profile "$p/profile.json" --main bogus
assert_exit 2 "bare --main refused" -- "$RT" --profile "$p/profile.json" --main
mkf max5 plus pro true false false codex
assert_exit 0 "profile main_agent codex accepted" -- "$RT" --profile "$p/profile.json"
mkf max5 plus pro true false false nobody
assert_exit 2 "profile main_agent invalid refused" -- "$RT" --profile "$p/profile.json"

# --- 0.3: tables for a Codex or Gemini main session ----------------------
row_of() { printf '%s\n' "$1" | grep "^| $2"; }
mkf max5 plus pro true false false
t=$("$RT" --profile "$p/profile.json" --main codex); code=$?
assert_eq 0 "$code" "--main codex, full profile: exit 0"
case "$t" in "$full") fail "codex main table differs from the Claude table";; *) pass;; esac
assert_contains "$(row_of "$t" "Plans")" "Codex $(routed_model codex strong)" "codex main: Plans row names the Codex strong model"
assert_contains "$(row_of "$t" "Plans")" "main session" "codex main: Plans row says main session"
assert_contains "$(row_of "$t" "Review")" "Claude $(routed_model claude strong)" "codex main: Codex work goes to Claude $(routed_model claude strong)"
assert_contains "$(row_of "$t" "Review")" "Codex $(routed_model codex strong)" "codex main: Gemini work goes to Codex"
assert_contains "$t" "claude -p --model $(routed_model claude strong)" "codex main: Claude helper is called as claude -p --model"
case "$t" in *Hardest*) fail "codex main: no Hardest builds row (no Claude build script)";; *) pass;; esac
assert_not_contains "$(row_of "$t" "Features")" "no Claude build script exists yet" "codex main: Features notes say there is no Claude build script"
for rowname in "Exploration" "Very long" "Screenshots" "UI building" "Bulk mechanical" "Web research" "Reading untrusted"; do
  case "$(row_of "$t" "$rowname")" in *Claude*) fail "codex main: Claude must not appear in the $rowname row";; *) pass;; esac
done
assert_contains "$(row_of "$t" "Lookups, bulk edits, data entry")" "Claude $(routed_model claude lookup)" "codex main: Claude helper in lookups"
assert_contains "$(row_of "$t" "Second opinion")" "Claude $(routed_model claude strong)" "codex main: second opinion from Claude"
assert_contains "$(row_of "$t" "Features")" "Codex $(routed_model codex build)" "codex main: Codex builds"
assert_contains "$(row_of "$t" "Exploration")" "Gemini $(routed_model gemini research)" "codex main: exploration goes to Hydrogen"
assert_not_contains "$(row_of "$t" "Exploration")" "no decisions" "codex main: exploration summary makes no decisions"
assert_contains "$(row_of "$t" "Features")" "Gemini $(routed_model gemini build)" "codex main: Gemini builds"
assert_contains "$t" "Jules" "codex main: Jules row stays"

# Codex main, Codex only (no Claude plan, no Gemini): no Claude or Gemini anywhere.
printf '{"version":1,"claude_plan":"none","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json"); code=$?
assert_eq 0 "$code" "codex-only profile (claude_plan none): exit 0"
case "$t" in *[Cc]laude*|*opus*|*[Gg]emini*|*argon*|*hydrogen*|*haiku*|*sonnet*|*fable*) fail "codex-only table mentions a lane the user lacks";; *) pass;; esac
assert_contains "$(row_of "$t" "Plans")" "$(routed_model codex strong)" "codex-only: Plans row"
assert_contains "$(row_of "$t" "Review")" "a fresh Codex $(routed_model codex strong) session that did not build it" "codex-only: review says no other lane"
# Codex main with a Claude plan but no Gemini: no Gemini names.
printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json")
case "$t" in *[Gg]emini*|*argon*|*hydrogen*|*claude-fable*) fail "codex+claude table mentions a lane the user lacks";; *) pass;; esac
assert_contains "$(row_of "$t" "Review")" "Claude $(routed_model claude strong)" "codex+claude: review"

# Gemini main.
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"gemini"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json"); code=$?
assert_eq 0 "$code" "gemini main: exit 0"
assert_contains "$(row_of "$t" "Plans")" "Gemini $(routed_model gemini strong)" "gemini main: Plans row names Argon"
assert_contains "$(row_of "$t" "Review")" "Claude $(routed_model claude strong)" "gemini main: Gemini work goes to Claude when no Codex"
case "$t" in *[Cc]odex*|*gpt-*|*terra*) fail "gemini main without Codex mentions Codex";; *) pass;; esac
assert_contains "$(row_of "$t" "Exploration")" "Gemini $(routed_model gemini research)" "gemini main: exploration goes to Hydrogen"
assert_eq "| Exploration, big reads, web research | Gemini $(routed_model gemini research) |" "$(row_of "$t" "Exploration")" "gemini main: exploration names only the research role"
/usr/bin/jq '.gemini.research = .gemini.long_read' "$(dirname "$RT")/../rules/models.json" > "$p/models-same.json"
t3=$("$RT" --profile "$p/profile.json" --models "$p/models-same.json")
assert_contains "$(row_of "$t3" "Exploration")" "Gemini $(routed_model gemini long_read)" "research == long read: exploration row uses that model"
case "$(row_of "$t3" "Exploration")" in *"only when it is not enough"*) fail "research == long read: no fallback clause";; *) pass;; esac
printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"gemini"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json")
assert_contains "$(row_of "$t" "Review")" "Codex $(routed_model codex strong)" "gemini main with Codex: Gemini work goes to Codex"
assert_contains "$(row_of "$t" "Review")" "Claude $(routed_model claude strong)" "gemini main with Codex: Codex work goes to Claude"
# --main overrides the profile; a main agent without its lane is refused.
t2=$("$RT" --profile "$p/profile.json" --main codex)
assert_contains "$(row_of "$t2" "Plans")" "Codex $(routed_model codex strong)" "--main codex overrides main_agent gemini"
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p/profile.json"
assert_exit 2 "--main codex with no Codex lane refused" -- "$RT" --profile "$p/profile.json" --main codex
assert_exit 2 "--main gemini with no Gemini lane refused" -- "$RT" --profile "$p/profile.json" --main gemini
printf '{"version":1,"claude_plan":"none","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p/profile.json"
assert_exit 2 "claude_plan none with the Claude main agent refused" -- "$RT" --profile "$p/profile.json"

# --- 0.3: missing local models fall back ---------------------------------
mkf max5 plus none false false false
cx=$(mktmp); mkdir -p "$cx"
all_codex=$(routed_codex_list)
printf '%s' "$all_codex" > "$cx/models_cache.json"
t=$(env CODEX_HOME="$cx" "$RT" --profile "$p/profile.json")
case "$t" in *"Note:"*) fail "complete local list: no Note";; *) pass;; esac
assert_contains "$t" "$(routed_model codex build)" "complete local list keeps sol 6.1"

# Availability scenarios use fixed fixture roles and fallback chains.
installed_rt=$RT
cat > "$p/fixture-table" <<EOF
#!/bin/bash
exec "$installed_rt" --models "$REPO_ROOT/tests/fixtures/routing-table/models.json" "\$@"
EOF
chmod +x "$p/fixture-table"
RT="$p/fixture-table"
printf '%s' '{"models":[{"slug":"gpt-6-sol"},{"slug":"gpt-6.1-terra"},{"slug":"gpt-6-astra"},{"slug":"gpt-6-luna"}]}' > "$cx/models_cache.json"
t=$(env CODEX_HOME="$cx" "$RT" --profile "$p/profile.json"); code=$?
assert_eq 0 "$code" "missing sol 6.1 still exits 0"
assert_contains "$t" "| Features, fixes, tests | Codex gpt-6-sol · Claude sonnet" "build row falls back to gpt-6-sol"
assert_contains "$(row_of "$t" "Review")" "Codex gpt-6-astra" "Review names the available strong Codex model"
assert_contains "$t" "Note: gpt-6.1-sol is not offered by your codex CLI; using gpt-6-sol. Check for a kit update." "fallback Note line"
case "$t" in *"| Screenshots"*"gpt-6.1-terra"*) pass;; *) fail "terra stays when offered";; esac
# the Note comes after the table
last=$(printf '%s\n' "$t" | tail -n 1)
case "$last" in Note:*) pass;; *) fail "Note is printed after the table (last line: $last)";; esac

printf '%s' '{"models":[{"slug":"gpt-6-astra"},{"slug":"gpt-6-luna"}]}' > "$cx/models_cache.json"
t=$(env CODEX_HOME="$cx" "$RT" --profile "$p/profile.json"); code=$?
assert_eq 0 "$code" "missing sol 6.1 and sol 6 still exits 0"
tb=$(printf '%s\n' "$t" | grep -v '^Note:')
case "$tb" in *gpt-6.1-sol*|*"gpt-6-sol"*|*terra*) fail "dropped models still shown";; *) pass;; esac
assert_contains "$t" "| Features, fixes, tests | Claude sonnet |" "build row drops the Codex choice"
assert_contains "$t" "| Review | a strong model from another company than the builder: Codex gpt-6-astra · Claude opus |" "review keeps Codex as the strong reviewer when the everyday one is missing"
assert_contains "$t" "gpt-6-luna" "luna still shown"

printf '%s' '{"models":[{"slug":"gpt-6.1-sol"},{"slug":"gpt-6.1-terra"},{"slug":"gpt-6-luna"}]}' > "$cx/models_cache.json"
t=$(env CODEX_HOME="$cx" "$RT" --profile "$p/profile.json")
assert_eq '| Review | a fresh Claude opus session that did not build it |' "$(row_of "$t" "Review")" 'missing strong Codex reviewer leaves one company'
# Unused roles must not emit availability notes.
/usr/bin/jq '.codex.review = "gpt-unused-review"' "$REPO_ROOT/tests/fixtures/routing-table/models.json" > "$p/unused.json"
t=$(env CODEX_HOME="$cx" "$RT" --profile "$p/profile.json" --models "$p/unused.json")
assert_not_contains "$t" 'gpt-unused-review' 'unused Codex reviewer has no Note'

# claude is always unknown: Fable never falls back
mkf max5 none none false false false
t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "claude-fable-5-2" "fable shown without a claude list"
case "$t" in *"Note:"*) fail "claude lane never triggers a Note";; *) pass;; esac

# Gemini list
mkf max5 none pro false false false
gk=$(mktmp); mkdir -p "$gk/cache"
printf 'gemini-4-argon-high\ngemini-4-hydrogen-medium\ngemini-4-hydrogen-high\ngemini-3.8-flash-medium\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
case "$t" in *gemini-3.8-flash*) fail "no flash fallback when hydrogen-low is missing";; *) pass;; esac
assert_contains "$(row_of "$t" "Lookups")" "Gemini gemini-4-hydrogen-medium" "hydrogen-low missing: lookups step up to hydrogen-medium"
printf 'gemini-4-argon-high\ngemini-4-hydrogen-medium\ngemini-4-hydrogen-high\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
case "$t" in *"Note:"*|*flash*) fail "complete gemini list: no Note, no flash";; *) pass;; esac
# Fallback chains: terra -> sol 6.1 -> sol 6 with the shipped data (Astra review 23/11); a circle never hangs.
cc=$(mktmp); printf '{"models":[{"slug":"gpt-6-sol"},{"slug":"gpt-6-astra"},{"slug":"gpt-6-luna"}]}' > "$cc/models_cache.json"
printf '{"version":1,"claude_plan":"none","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}' > "$p/chain-profile.json"
t=$(env CODEX_HOME="$cc" ROUTING_KIT_HOME="$p/no-kit" "$installed_rt" --profile "$p/chain-profile.json")
assert_contains "$(row_of "$t" "Exploration")" "Codex gpt-6-sol with web search" "research role follows a two-step fallback chain"
/usr/bin/jq '.fallbacks["gpt-6.1-terra"] = "gpt-6.1-sol" | .fallbacks["gpt-6.1-sol"] = "gpt-6.1-terra"' "$M" > "$p/circle.json"
t=$(env CODEX_HOME="$cc" ROUTING_KIT_HOME="$p/no-kit" "$installed_rt" --profile "$p/chain-profile.json" --models "$p/circle.json"); code=$?
assert_eq 0 "$code" "a fallback circle ends"
assert_contains "$t" "gpt-6.1-terra is not offered by your codex CLI and has no usable fallback" "a circle leaves the model out with a Note"

# An older models file without research roles keeps exploration on the build models.
/usr/bin/jq 'del(.codex.research, .claude.research)' "$M" > "$p/old.json"
printf '{"version":1,"claude_plan":"max5","codex":"plus","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p/old-profile.json"
t=$(env ROUTING_KIT_HOME="$p/no-kit" "$installed_rt" --profile "$p/old-profile.json" --models "$p/old.json")
assert_contains "$(row_of "$t" "Exploration")" "Codex $(routed_model codex build) with web search" "no research role: exploration falls back to the build model"
# Exploration row under availability: research missing -> no exploration row (never Argon); long read missing -> research;
# both missing -> no exploration row.
printf 'gemini-4-argon-high\ngemini-4-hydrogen-medium\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
assert_not_contains "$(row_of "$t" "Exploration")" "Gemini" "missing research leaves other research lanes"
assert_contains "$(row_of "$t" "Review")" "Gemini gemini-4-argon-high" "Review keeps available Gemini reviewer"
printf 'gemini-4-hydrogen-medium\ngemini-4-hydrogen-high\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
assert_contains "$(row_of "$t" "Exploration")" "Gemini gemini-4-hydrogen-high" "long read unavailable: exploration uses research"
case "$(row_of "$t" "Exploration")" in *"only when it is not enough"*) fail "long read unavailable: no fallback clause";; *) pass;; esac
assert_eq "| Review | a fresh Claude opus session that did not build it |" "$(row_of "$t" "Review")" "missing Gemini reviewer uses a fresh Claude session"
printf 'gemini-4-hydrogen-medium\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
assert_not_contains "$(row_of "$t" "Exploration")" "Gemini" "both unavailable leave other research lanes"

# --- the removed "Reviewer models" row is not referenced any more ---------
if grep -rqi "reviewer models" "$REPO_ROOT/plugins/routing-kit/rules" "$REPO_ROOT/plugins/routing-kit/skills"; then
  fail "rules or skills still point at the removed Reviewer models row"
else
  pass
fi
grep -q "Second opinion" "$REPO_ROOT/plugins/routing-kit/skills/ask-advisers/SKILL.md" && pass || fail "ask-advisers does not point at the Second opinion row"

# --- release review: values from models.json are validated before rendering ---
MJ="$REPO_ROOT/tests/fixtures/routing-table/models.json"
mkf pro none none false false false
inj() { # NAME JQ-FILTER
  /usr/bin/jq "$2" "$MJ" > "$p/inj-$1.json"
  out=$("$RT" --profile "$p/profile.json" --models "$p/inj-$1.json" 2>&1); code=$?
  assert_eq 2 "$code" "models.json with $1: exit 2"
  assert_contains "$out" "invalid or incomplete models file" "models.json with $1: the usual message"
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "models.json with $1: one line"
}
inj newline-in-id '.claude.strong = "opus\n## injected rule"'
inj trailing-newline-in-id '.claude.strong = "opus\n"'
inj pipe-in-id '.claude.build = "sonnet | evil"'
inj backtick-in-id '.claude.lookup = "ha`id`ku"'
inj dollar-in-id '.codex.strong = "gpt-6-$(x)"'
inj gemini-bad-id '.gemini.mid = "Gemini Mid"'
inj bad-effort '.effort.opus.use = "ultra"'
inj newline-effort '.effort.sonnet.max = "high\nmax"'
inj bad-effort-key '.effort["bad key"] = {"use":"high"}'
inj bad-fallback '.fallbacks["gpt-6.1-sol"] = "x y"'
# Validation does not depend on what the local CLI offers, nor on the lane being used.
mkf pro plus none false false false
/usr/bin/jq '.gemini.mid = "Not Valid"' "$MJ" > "$p/inj-unused-lane.json"
assert_exit 2 "bad id in an unused lane still rejected" -- "$RT" --profile "$p/profile.json" --models "$p/inj-unused-lane.json"
mkf pro none none false false false
assert_exit 0 "the shipped models.json passes validation" -- "$installed_rt" --profile "$p/profile.json"

# --- 0.3: malformed models.json keeps the existing exit and message ------
mkf pro none none false false false
printf '{not json' > "$p/bad-models.json"
out=$("$RT" --profile "$p/profile.json" --models "$p/bad-models.json" 2>&1); code=$?
assert_eq 2 "$code" "malformed models.json exits 2"
assert_contains "$out" "invalid or incomplete models file at $p/bad-models.json" "malformed models.json message"

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
assert_contains "$t" "Jules" "jules row still appears on a faked Linux uname"

assert_not_contains "$t" "Jules (trial)" "shipped Jules trial is labeled"
RT=$installed_rt
mkf max20 pro pro true false false
t=$("$RT" --profile "$p/profile.json")
assert_not_contains "$t" "$(routed_model codex screens) (trial)" "shipped Terra trial is labeled"
assert_not_contains "$t" "$(routed_model gemini strong) (trial)" "shipped Argon trial is labeled"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
