#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RT="$(dirname "$0")/../plugins/routing-kit/bin/kit-routing-table"
p=$(mktmp)
# Hermetic: no local Codex or Gemini lists unless a test makes one.
export CODEX_HOME="$p/no-codex" ROUTING_KIT_HOME="$p/no-kit"
mk() { printf '{"version":1,"claude_plan":"%s","codex":"%s","jules":%s,"kimi":%s,"glm":%s,"paseo":false}' "$@" > "$p/profile.json"; }

mk pro none false false false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "| Review | fresh Claude opus subagent" "claude-only review"
assert_contains "$t" "| Features, bug fixes, tests | Claude sonnet" "claude-only build"
case "$t" in *codex*|*gpt-6*|*Jules*|*kimi*|*glm*) fail "claude-only must not mention other lanes";; esac

mk max5 plus false false false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "Codex gpt-6.1-sol · Claude sonnet" "codex build choice"
assert_contains "$t" "Claude work → Codex gpt-6.1-sol, risky changes → gpt-6-astra; Codex work → Claude opus" "cross-company review"
assert_contains "$t" "Claude haiku · Codex gpt-6-luna" "lookups"

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

# Routing model identifiers belong to models.json. The guide and README show
# examples; doctor cost probes and hook self-tests deliberately name models,
# and delegation.py has a model-name example in a comment. These are not
# routing defaults. Keep the audit on routing code rather than every tracked file.
ids=$(/usr/bin/jq -r '[.claude, .codex, .gemini, .kimi, .glm] | map(del(.base_url, .host)) | .[] | .[] | select(type == "string")' "$(dirname "$RT")/../rules/models.json" | sort -u)
for id in $ids; do
  if git -C "$REPO_ROOT" grep -l -F -w -- "$id" -- . ':!tests' ':!plugins/routing-kit/rules/models.json' ':!plugins/routing-kit/guide' ':!README.md' ':!plugins/routing-kit/lib/doctor.py' ':!plugins/routing-kit/lib/selftest_hooks.py' ':!plugins/routing-kit/hooks/checks/delegation.py' | grep -q .; then
    fail "model id outside models.json: $id"
  else pass; fi
done


# --- 0.3: models.json shape -------------------------------------------------
M="$(dirname "$RT")/../rules/models.json"
assert_eq 2 "$(/usr/bin/jq -r .version "$M")" "models.json version 2"
# The checked date moves with every guide refresh: assert its shape, not a fixed day.
assert_eq 0 "$(/usr/bin/jq -r .checked "$M" | /usr/bin/grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}'; echo $?)" "models.json checked date is an ISO date"
assert_eq claude-fable-5-2 "$(/usr/bin/jq -r .claude.top "$M")" "fable pinned by full id"
assert_eq gpt-6.1-sol "$(/usr/bin/jq -r .codex.review "$M")" "codex review model"
assert_eq gpt-6.1-terra "$(/usr/bin/jq -r .codex.screens "$M")" "codex screens model"
assert_eq gemini-4-argon-high "$(/usr/bin/jq -r .gemini.long_read "$M")" "gemini long_read"
assert_eq gemini-4-hydrogen-low "$(/usr/bin/jq -r .gemini.lookup "$M")" "gemini lookup"
assert_eq gpt-6-sol "$(/usr/bin/jq -r '.fallbacks["gpt-6.1-sol"]' "$M")" "sol fallback"
assert_eq opus "$(/usr/bin/jq -r '.fallbacks["claude-fable-5-2"]' "$M")" "fable fallback"
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
assert_eq 14 "$(nrows "$t")" "full profile: exactly 14 rows"
assert_contains "$t" "gpt-6.1-sol" "full: sol 6.1"
assert_contains "$t" "gpt-6.1-terra" "full: terra"
assert_contains "$t" "claude-fable-5-2" "full: fable by full id"
case "$t" in *[Ff]lash*) fail "full: flash must not appear";; *) pass;; esac
assert_contains "$t" "| Review | Claude work → Codex gpt-6.1-sol, risky changes → gpt-6-astra; Codex or Gemini work → Claude opus |" "full: review row"
assert_contains "$t" "| Hardest builds: long overnight runs, or after a cheaper build failed twice | Claude claude-fable-5-2 | high, never max;" "full: fable row"
assert_contains "$t" "Claude sonnet" "full: sonnet"
assert_contains "$t" "medium or high, never above" "full: sonnet effort text"
assert_contains "$t" "at high, never low" "full: luna effort text"
assert_contains "$t" "| Exploration, big reads | Gemini gemini-4-hydrogen-high | read-only facts with file:line, no decisions; another company checks code claims" "full: exploration row (Hydrogen, no Argon)"
assert_contains "$t" "| Very long single outputs | Gemini gemini-4-argon-high (trial) |" "full: long outputs row"
assert_contains "$t" "| Screenshots, UI checks, prose from supplied material | Codex gpt-6.1-terra (trial) |" "full: terra row"
assert_contains "$t" "| Reading untrusted web pages or email while holding tools that can act | Claude opus | never Fable |" "full: untrusted row"
assert_contains "$t" "Claude haiku · Codex gpt-6-luna · Gemini gemini-4-hydrogen-low" "full: lookups"
assert_contains "$t" "Gemini gemini-4-hydrogen-high" "full: research hydrogen high"
case "$t" in *"Note:"*) fail "full: no Note without local lists";; *) pass;; esac
# row order follows the field-guide table
order=$(printf '%s\n' "$t" | sed -n '3,$p' | cut -d'|' -f2 | cut -c2-8 | tr '\n' ',')
assert_eq "Plans, ,Hardest,Feature,Review ,Second ,Explora,Very lo,Screens,UI buil,Read-on,Bulk me,Web res,Reading,Mechani," "$order" "row order"

mkf pro none none false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 9 "$(nrows "$t")" "claude-only pro: 9 rows"
case "$t" in *claude-fable*) fail "pro must not show the Fable row";; *) pass;; esac
case "$t" in *[Cc]odex*|*gpt-*|*[Gg]emini*|*argon*|*hydrogen*|*Jules*|*terra*) fail "claude-only must not mention other lanes";; *) pass;; esac
for plan in max5 max20 api; do
  mkf $plan none none false false false; t=$("$RT" --profile "$p/profile.json")
  assert_eq 10 "$(nrows "$t")" "claude-only $plan: 10 rows (Fable row added)"
  assert_contains "$t" "claude-fable-5-2" "$plan shows Fable"
done
# Standard Team seats only get Fable on paid usage credits and the profile cannot
# tell premium seats apart: no Fable row for team.
mkf team none none false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 9 "$(nrows "$t")" "claude-only team: 9 rows (no Fable row)"
case "$t" in *claude-fable*|*Hardest*) fail "team must not show the Fable row";; *) pass;; esac
# api is pay per use: no talk of a weekly share.
mkf api none none false false false; t=$("$RT" --profile "$p/profile.json")
hb=$(printf '%s\n' "$t" | grep '^| Hardest')
case "$hb" in *share*|*week*) fail "api Fable row must not mention a weekly share";; *) pass;; esac
assert_contains "$hb" "pay per use" "api Fable row says pay per use"
mkf max5 none none false false false; t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "needs room in Fable's share and the Claude week" "max5 Fable row keeps the weekly-share note"

mkf max5 plus none false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 11 "$(nrows "$t")" "claude+codex: 11 rows"
case "$t" in *[Gg]emini*|*argon*|*hydrogen*|*Jules*) fail "claude+codex must not mention gemini/jules";; *) pass;; esac
assert_contains "$t" "Claude work → Codex gpt-6.1-sol, risky changes → gpt-6-astra; Codex work → Claude opus" "claude+codex review"

mkf max5 none pro false false false; t=$("$RT" --profile "$p/profile.json")
assert_eq 12 "$(nrows "$t")" "claude+gemini: 12 rows"
case "$t" in *[Cc]odex*|*gpt-*|*Jules*|*terra*) fail "claude+gemini must not mention codex/jules";; *) pass;; esac
assert_contains "$t" "Gemini work → Claude opus" "claude+gemini review"

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
assert_contains "$(row_of "$t" "Plans")" "Codex gpt-6-astra" "codex main: Plans row names the Codex strong model"
assert_contains "$(row_of "$t" "Plans")" "main session" "codex main: Plans row says main session"
assert_contains "$(row_of "$t" "Review")" "Codex work → Claude opus" "codex main: Codex work goes to Claude opus"
assert_contains "$(row_of "$t" "Review")" "Gemini work → Codex gpt-6.1-sol" "codex main: Gemini work goes to Codex"
assert_contains "$t" "claude -p --model opus" "codex main: Claude helper is called as claude -p --model"
case "$t" in *Hardest*) fail "codex main: no Hardest builds row (no Claude build script)";; *) pass;; esac
assert_contains "$(row_of "$t" "Features")" "no Claude build script exists yet" "codex main: Features notes say there is no Claude build script"
for rowname in "Exploration" "Very long" "Screenshots" "UI building" "Bulk mechanical" "Web research" "Reading untrusted"; do
  case "$(row_of "$t" "$rowname")" in *Claude*) fail "codex main: Claude must not appear in the $rowname row";; *) pass;; esac
done
assert_contains "$(row_of "$t" "Read-only lookups")" "Claude haiku" "codex main: Claude helper in lookups"
assert_contains "$(row_of "$t" "Second opinion")" "Claude opus" "codex main: second opinion from Claude"
assert_contains "$(row_of "$t" "Features")" "Codex gpt-6.1-sol" "codex main: Codex builds"
assert_contains "$(row_of "$t" "Exploration")" "Gemini gemini-4-hydrogen-high" "codex main: exploration goes to Hydrogen"
assert_contains "$(row_of "$t" "Exploration")" "no decisions" "codex main: exploration summary makes no decisions"
assert_contains "$(row_of "$t" "Features")" "Gemini gemini-4-argon-high" "codex main: Gemini builds"
assert_contains "$t" "kit-jules-build" "codex main: Jules row stays"

# Codex main, Codex only (no Claude plan, no Gemini): no Claude or Gemini anywhere.
printf '{"version":1,"claude_plan":"none","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json"); code=$?
assert_eq 0 "$code" "codex-only profile (claude_plan none): exit 0"
case "$t" in *[Cc]laude*|*opus*|*[Gg]emini*|*argon*|*hydrogen*|*haiku*|*sonnet*|*fable*) fail "codex-only table mentions a lane the user lacks";; *) pass;; esac
assert_contains "$(row_of "$t" "Plans")" "gpt-6-astra" "codex-only: Plans row"
assert_contains "$(row_of "$t" "Review")" "no other lane to cross-check against" "codex-only: review says no other lane"
# Codex main with a Claude plan but no Gemini: no Gemini names.
printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json")
case "$t" in *[Gg]emini*|*argon*|*hydrogen*|*claude-fable*) fail "codex+claude table mentions a lane the user lacks";; *) pass;; esac
assert_contains "$(row_of "$t" "Review")" "Codex work → Claude opus" "codex+claude: review"

# Gemini main.
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"gemini"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json"); code=$?
assert_eq 0 "$code" "gemini main: exit 0"
assert_contains "$(row_of "$t" "Plans")" "Gemini gemini-4-argon-high" "gemini main: Plans row names Argon"
assert_contains "$(row_of "$t" "Review")" "Gemini work → Claude opus" "gemini main: Gemini work goes to Claude when no Codex"
case "$t" in *[Cc]odex*|*gpt-*|*terra*) fail "gemini main without Codex mentions Codex";; *) pass;; esac
assert_contains "$(row_of "$t" "Exploration")" "Gemini gemini-4-hydrogen-high" "gemini main: exploration goes to Hydrogen"
case "$(row_of "$t" "Exploration")" in *[Aa]rgon*) fail "gemini main: exploration never names Argon";; *) pass;; esac
/usr/bin/jq '.gemini.research = .gemini.long_read' "$(dirname "$RT")/../rules/models.json" > "$p/models-same.json"
t3=$("$RT" --profile "$p/profile.json" --models "$p/models-same.json")
assert_contains "$(row_of "$t3" "Exploration")" "Gemini gemini-4-argon-high" "research == long read: exploration row uses that model"
case "$(row_of "$t3" "Exploration")" in *"only when it is not enough"*) fail "research == long read: no fallback clause";; *) pass;; esac
printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"gemini"}' > "$p/profile.json"
t=$("$RT" --profile "$p/profile.json")
assert_contains "$(row_of "$t" "Review")" "Gemini work → Codex gpt-6.1-sol" "gemini main with Codex: Gemini work goes to Codex"
assert_contains "$(row_of "$t" "Review")" "Codex work → Claude opus" "gemini main with Codex: Codex work goes to Claude"
# --main overrides the profile; a main agent without its lane is refused.
t2=$("$RT" --profile "$p/profile.json" --main codex)
assert_contains "$(row_of "$t2" "Plans")" "Codex gpt-6-astra" "--main codex overrides main_agent gemini"
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p/profile.json"
assert_exit 2 "--main codex with no Codex lane refused" -- "$RT" --profile "$p/profile.json" --main codex
assert_exit 2 "--main gemini with no Gemini lane refused" -- "$RT" --profile "$p/profile.json" --main gemini
printf '{"version":1,"claude_plan":"none","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false}' > "$p/profile.json"
assert_exit 2 "claude_plan none with the Claude main agent refused" -- "$RT" --profile "$p/profile.json"

# --- 0.3: missing local models fall back ---------------------------------
mkf max5 plus none false false false
cx=$(mktmp); mkdir -p "$cx"
all_codex='{"models":[{"slug":"gpt-6.1-sol"},{"slug":"gpt-6-sol"},{"slug":"gpt-6.1-terra"},{"slug":"gpt-6-astra"},{"slug":"gpt-6-luna"}]}'
printf '%s' "$all_codex" > "$cx/models_cache.json"
t=$(env CODEX_HOME="$cx" "$RT" --profile "$p/profile.json")
case "$t" in *"Note:"*) fail "complete local list: no Note";; *) pass;; esac
assert_contains "$t" "gpt-6.1-sol" "complete local list keeps sol 6.1"

printf '%s' '{"models":[{"slug":"gpt-6-sol"},{"slug":"gpt-6.1-terra"},{"slug":"gpt-6-astra"},{"slug":"gpt-6-luna"}]}' > "$cx/models_cache.json"
t=$(env CODEX_HOME="$cx" "$RT" --profile "$p/profile.json"); code=$?
assert_eq 0 "$code" "missing sol 6.1 still exits 0"
assert_contains "$t" "| Features, bug fixes, tests | Codex gpt-6-sol · Claude sonnet" "build row falls back to gpt-6-sol"
assert_contains "$t" "Claude work → Codex gpt-6-sol, risky changes → gpt-6-astra" "review row falls back"
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
assert_contains "$t" "| Features, bug fixes, tests | Claude sonnet |" "build row drops the Codex choice"
assert_contains "$t" "| Review | Claude work → Codex gpt-6-astra; Codex work → Claude opus |" "review keeps Codex as the strong reviewer when the everyday one is missing"
assert_contains "$t" "gpt-6-luna" "luna still shown"

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
assert_contains "$t" "Note: gemini-4-hydrogen-low is not offered by your gemini CLI and has no usable fallback; leaving it out. Check for a kit update." "gemini no-fallback Note"
printf 'gemini-4-argon-high\ngemini-4-hydrogen-medium\ngemini-4-hydrogen-high\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
case "$t" in *"Note:"*|*flash*) fail "complete gemini list: no Note, no flash";; *) pass;; esac
# Exploration row under availability: research missing -> no exploration row (never Argon); long read missing -> research;
# both missing -> no exploration row.
printf 'gemini-4-argon-high\ngemini-4-hydrogen-medium\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
case "$t" in *"Exploration, big reads"*) fail "research unavailable: no exploration row (never Argon)";; *) pass;; esac
assert_contains "$t" "Very long single outputs" "research unavailable: the long-output row stays"
printf 'gemini-4-hydrogen-medium\ngemini-4-hydrogen-high\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
assert_contains "$(row_of "$t" "Exploration")" "Gemini gemini-4-hydrogen-high" "long read unavailable: exploration uses research"
case "$(row_of "$t" "Exploration")" in *"only when it is not enough"*) fail "long read unavailable: no fallback clause";; *) pass;; esac
case "$t" in *"Very long single outputs"*) fail "long read unavailable: no long-output row";; *) pass;; esac
printf 'gemini-4-hydrogen-medium\ngemini-4-hydrogen-low\n' > "$gk/cache/agy-models.txt"
t=$(env ROUTING_KIT_HOME="$gk" "$RT" --profile "$p/profile.json")
case "$t" in *"Exploration, big reads"*) fail "both unavailable: no exploration row";; *) pass;; esac

# --- the removed "Reviewer models" row is not referenced any more ---------
if grep -rqi "reviewer models" "$REPO_ROOT/plugins/routing-kit/rules" "$REPO_ROOT/plugins/routing-kit/skills"; then
  fail "rules or skills still point at the removed Reviewer models row"
else
  pass
fi
grep -q "Second opinion" "$REPO_ROOT/plugins/routing-kit/skills/ask-advisers/SKILL.md" && pass || fail "ask-advisers does not point at the Second opinion row"

# --- release review: values from models.json are validated before rendering ---
MJ="$(dirname "$RT")/../rules/models.json"
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
assert_exit 0 "the shipped models.json passes validation" -- "$RT" --profile "$p/profile.json"

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
assert_contains "$t" "kit-jules-build" "jules row still appears on a faked Linux uname"

assert_contains "$t" "Jules (trial)" "shipped Jules trial is labeled"
mkf max20 pro pro true false false
t=$("$RT" --profile "$p/profile.json")
assert_contains "$t" "gpt-6.1-terra (trial)" "shipped Terra trial is labeled"
assert_contains "$t" "gemini-4-argon-high (trial)" "shipped Argon trial is labeled"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
