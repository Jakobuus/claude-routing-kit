#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
HOOK="$PLUGIN_ROOT/hooks/session-start"
cd "$REPO_ROOT"
export HOME=$(mktmp)
export CODEX_HOME="$HOME/.codex"

# A hand-run hook must exit while its terminal input remains open.
if python3 - "$HOOK" <<'PYTTY'
import os, pty, subprocess, sys
master, slave = pty.openpty()
try:
    child = subprocess.Popen([sys.argv[1]], stdin=slave, stdout=subprocess.DEVNULL)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
        sys.exit(1)
finally:
    os.close(master)
    os.close(slave)
PYTTY
then pass; else fail "hand-run hook blocks on terminal stdin"; fi

mkprofile() {
  # mkprofile FILE claude_plan codex jules kimi glm paseo
  printf '{"version":1,"claude_plan":"%s","codex":"%s","jules":%s,"kimi":%s,"glm":%s,"paseo":%s}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$1"
}

# (a) valid profile -> stdout contains "# Rules" and "## Your routing table", exit 0
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "valid profile exits 0"
assert_contains "$out" "# Rules" "valid profile output has # Rules"
assert_contains "$out" "## Your routing table" "valid profile output has routing table heading"
case "$out" in *"## You are a worker"*) fail "default session is a lead";; *) pass;; esac
lead=$(KIT_ROLE=lead ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
assert_eq "$out" "$lead" "explicit lead matches default"
worker=$(KIT_ROLE=worker "$HOOK")
expected=$(cat <<'WORKER'
## You are a worker
- Stay inside the task in your brief. Don't refactor code you weren't asked to touch.
- Run the project's tests (or the check named in the brief) before you finish.
- Don't commit, push, or change git config.
- End with three short lists: what you did, what you didn't do, what you couldn't check.
WORKER
)
assert_eq "$expected" "$worker" "worker prints only its section"
for lane in Codex Jules Kimi GLM; do
  lower=$(printf '%s' "$lane" | tr '[:upper:]' '[:lower:]')
  case "$out" in *"$lane"*|*"$lower"*) fail "disabled $lane appears in rules";; *) pass;; esac
done

# Each lane disappears on its own while the other three remain enabled.
for lane in codex jules kimi glm; do
  d=$(mktmp); mkdir -p "$d/.config/routing-kit"
  codex=plus; jules=true; kimi=true; glm=true
  case "$lane" in
    codex) codex=none;; jules) jules=false;; kimi) kimi=false;; glm) glm=false;;
  esac
  mkprofile "$d/.config/routing-kit/profile.json" pro "$codex" "$jules" "$kimi" "$glm" false
  out=$(ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
  cap=$(printf '%s' "$lane" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  [ "$lane" = glm ] && cap=GLM
  case "$out" in *"$cap"*|*"$lane"*) fail "individually disabled $lane appears in hook output";; *) pass;; esac
done

# Null Gemini and an absent Codex key are disabled in both rules and table.
d=$(mktmp); mkdir -p "$d/.config/routing-kit"
printf '{"version":1,"claude_plan":"pro","gemini":null,"jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$d/.config/routing-kit/profile.json"
out=$(ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
case "$out" in *'Every Gemini build'*|*'Every Codex build'*) fail 'null Gemini or absent Codex rules loaded';; *) pass;; esac

# (b) no profile -> the not-set-up line only, exit 0
d=$(mktmp)
out=$(env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "no profile exits 0"
assert_eq "routing-kit is installed but not set up yet. Give your agent START-HERE.md from https://github.com/Jakobuus/claude-routing-kit and ask it to set up routing-kit." "$out" "no-profile message is exact"

# (c) broken profile JSON -> contains "rules did not load", exit 0
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
echo '{not json' > "$d/.config/routing-kit/profile.json"
out=$(env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "broken profile exits 0"
assert_contains "$out" "rules did not load" "broken profile reports rules did not load"

# (d) output length <= 9400 for the largest profile (all lanes on). Claude Code
# truncates hook output at 10,000 characters; the hook drops sections to stay in budget.
# Assert the output actually contains the routing table (not the short
# repair line, which would trivially satisfy a length check and mask a
# real failure to inject rules), and measure length without stripping the
# trailing newline that command substitution would otherwise eat.
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" max20 api true true true true
outfile="$d/hook.out"
env ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK" > "$outfile"
code=$?
assert_eq 0 "$code" "largest profile exits 0"
out=$(cat "$outfile")
assert_contains "$out" "## Your routing table" "largest profile output actually has the routing table, not the repair line"
len=$(wc -c < "$outfile" | tr -d ' ')
if [ "$len" -le 9400 ]; then
  pass
else
  fail "largest-profile output is $len chars, over the 9400 budget"
fi

# (e) runs with env -i PATH=/usr/bin:/bin HOME=$tmp (the bare PATH Paseo can give)
d=$(mktmp)
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env -i PATH=/usr/bin:/bin HOME="$d" ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "bare PATH run exits 0"
assert_contains "$out" "## Your routing table" "bare PATH run still produces the table"

# (f) Linux (and WSL2, which reports uname as Linux) is a supported system:
# a fake `uname` that prints Linux must still produce the normal routing
# table, not the old macOS-only refusal.
d=$(mktmp)
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "faked-Linux hook exits 0"
assert_contains "$out" "## Your routing table" "faked-Linux hook still produces the table"

# (g) native Windows (no WSL): a session must never be blocked either, but
# it's not a supported system -- fake a MINGW64_NT-shaped uname (what
# git-bash reports) and check the hook prints exactly the one-line
# unsupported-system message and exits 0 (not exit 2).
d=$(mktmp)
winbin=$(mktmp)
cat > "$winbin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0"
EOF
chmod +x "$winbin/uname"
mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
out=$(env PATH="$winbin:$PATH" ROUTING_KIT_HOME="$d/.config/routing-kit" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "native-Windows hook exits 0"
assert_eq "routing-kit needs macOS, Linux, or WSL2 on Windows; rules not loaded." "$out" "native-Windows hook prints the exact one-line message"

# --- Task 3: stale-guide line, missing-model lines, Gemini refresh ---------
GUIDE_DATE=$(jq -r .checked "$PLUGIN_ROOT/rules/models.json")
d=$(mktmp); mkdir -p "$d/.config/routing-kit"
mkprofile "$d/.config/routing-kit/profile.json" pro none false false false false
RK="$d/.config/routing-kit"
fresh=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$RK" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
table=$("$PLUGIN_ROOT/bin/kit-routing-table" --profile "$RK/profile.json")
case "$fresh" in *"Routing guide"*) fail "fresh guide: hook prints a guide line";; *) pass;; esac
# A fresh guide adds nothing after the table: the output ends with the table.
case "$fresh" in *"$table") pass;; *) fail "fresh guide: output does not end with the table";; esac
stale=$(env KIT_GUIDE_TODAY=2099-01-01 ROUTING_KIT_HOME="$RK" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
assert_eq 0 "$code" "stale guide: hook exits 0"
assert_contains "$stale" "Routing guide is " "stale guide: line shown"
assert_contains "$stale" "days old. Update it: claude plugin update routing-kit@routing-kit" "stale guide: exact wording"
# Stale output = fresh output + one blank line + the single guide line, nothing else.
extra=${stale#"$fresh"}
nlines=$(printf '%s' "$extra" | grep -c .)
assert_eq 1 "$nlines" "stale guide adds exactly one line"
case "$stale" in "$fresh"*) pass;; *) fail "stale guide output does not start with the fresh output";; esac

# Missing models.json: the existing one-line repair message, exit 0.
pr=$(mktmp); cp -R "$PLUGIN_ROOT/." "$pr/"
rm -f "$pr/rules/models.json"
out=$(env ROUTING_KIT_HOME="$RK" CLAUDE_PLUGIN_ROOT="$pr" "$pr/hooks/session-start")
code=$?
assert_eq 0 "$code" "missing models.json: hook exits 0"
assert_eq "routing-kit: rules did not load (invalid profile). Repair: claude plugin update routing-kit@routing-kit" "$out" "missing models.json: existing repair line"

# Gemini refresh: fake agy that counts calls and sleeps 30 s.
fb=$(mktmp)
cat > "$fb/agy" <<'EOF'
#!/bin/bash
echo "$$" >> "$FAKE_AGY_DIR/pids"
echo call >> "$FAKE_AGY_DIR/count"
sleep 30
EOF
chmod +x "$fb/agy"
d=$(mktmp); mkdir -p "$d/.config/routing-kit"; RK="$d/.config/routing-kit"
printf '{"version":1,"claude_plan":"pro","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$RK/profile.json"
start=$(python3 -c 'import time; print(int(time.time()*1000))')
out=$(env FAKE_AGY_DIR="$fb" PATH="$fb:$PATH" KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$RK" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
code=$?
elapsed=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - start ))
assert_eq 0 "$code" "gemini hook exits 0"
assert_contains "$out" "## Your routing table" "gemini hook still prints the table"
if [ "$elapsed" -lt 2000 ]; then pass; else fail "hook with a 30 s fake agy took ${elapsed} ms"; fi
sleep 1
n=$(grep -c call "$fb/count" 2>/dev/null); n=${n:-0}
assert_eq 1 "$n" "first hook run starts the refresh once"
assert_eq 1 "$(ls "$RK/cache" 2>/dev/null | grep -c 'refresh')" "a stamp file is written in cache"
# No zombie (state Z) left behind by the hook.
zombies=$(ps -axo stat=,command= | grep -E '^Z' | grep -c "session-start")
assert_eq 0 "$zombies" "hook leaves no zombie"
# Second run within 24 h: no new refresh.
env FAKE_AGY_DIR="$fb" PATH="$fb:$PATH" KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$RK" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK" >/dev/null
sleep 1
n=$(grep -c call "$fb/count" 2>/dev/null); n=${n:-0}
assert_eq 1 "$n" "second run inside 24 h does not start the refresh again"
# An old stamp (older than 24 h) lets the refresh run again.
stampf=$(ls "$RK"/cache/*refresh* | head -1)
touch -t 202001010000 "$stampf"
env FAKE_AGY_DIR="$fb" PATH="$fb:$PATH" KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$RK" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK" >/dev/null
sleep 1
n=$(grep -c call "$fb/count" 2>/dev/null); n=${n:-0}
assert_eq 2 "$n" "a stamp older than 24 h allows a new refresh"
# Stop only the fake agy processes this test started.
for pid in $(cat "$fb/pids" 2>/dev/null); do
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
done

# A profile without Gemini never starts a refresh.
d=$(mktmp); mkdir -p "$d/.config/routing-kit"; RK="$d/.config/routing-kit"
mkprofile "$RK/profile.json" pro plus false false false false
fb2=$(mktmp); cp "$fb/agy" "$fb2/agy"
env FAKE_AGY_DIR="$fb2" PATH="$fb2:$PATH" KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$RK" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CODEX_HOME="$d/codex" "$HOOK" >/dev/null
sleep 1
n=$(grep -c call "$fb2/count" 2>/dev/null); n=${n:-0}
assert_eq 0 "$n" "no Gemini in the profile: no refresh"

# --- Task 4: main_agent filters the rules, the table and the wording --------
GUIDE_DATE=$(jq -r .checked "$PLUGIN_ROOT/rules/models.json")
run_hook() { # DIR [extra env...]
  dd="$1"; shift
  env "$@" KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$dd" CODEX_HOME="$dd/no-codex" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK"
}
# Claude main: no filter markers left; new rules present.
d=$(mktmp)
mkprofile "$d/profile.json" max5 plus false false false false
out=$(run_hook "$d")
case "$out" in *"<!--"*) fail "claude main: filter markers left in the output";; *) pass;; esac
assert_contains "$out" "**Hardest builds.**" "claude main: Hardest builds rule"
assert_contains "$out" "**Risky changes get the stronger reviewer.**" "claude main: risky changes rule"
assert_contains "$out" "**Reviewers read the diff.**" "claude main: reviewers read the diff"
assert_contains "$out" "**Effort.** Raise the model, not the effort." "claude main: effort rule"
assert_contains "$out" "**Brief each company's models differently.**" "claude main: brief rule"
assert_contains "$out" "**Untrusted text.**" "claude main: untrusted rule"
assert_contains "$out" "**Background workers never run on the top Claude model**" "claude main: background workers rule"
assert_contains "$out" "every subagent gets \`model\`" "claude main: subagent wording"

# Codex-only user: Codex main, no Claude plan, no Gemini.
d=$(mktmp)
printf '{"version":1,"claude_plan":"none","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
out=$(run_hook "$d"); code=$?
assert_eq 0 "$code" "codex main: hook exits 0"
assert_contains "$out" "## Your routing table" "codex main: table present"
case "$out" in *"<!--"*) fail "codex main: filter markers left in the output";; *) pass;; esac
case "$out" in *subagent*|*Subagent*) fail "codex main: the word subagent appears";; *) pass;; esac
case "$out" in *"claude plugin"*) fail "codex main: claude plugin appears";; *) pass;; esac
case "$out" in *opus*|*sonnet*|*haiku*|*fable*|*gemini-*|*argon-*|*hydrogen-*|*flash*) fail "codex main: a model of a lane the user lacks appears";; *) pass;; esac
case "$out" in *"Hardest builds"*|*"Background workers"*) fail "codex main: Claude-only rules appear";; *) pass;; esac
assert_contains "$out" "**Risky changes get the stronger reviewer.**" "codex main: shared rules present"
assert_contains "$out" "Kit commands live in $PLUGIN_ROOT/bin; call them by full path if they are not on PATH." "codex main: kit commands located by full path"
assert_contains "$out" "gpt-6-astra (the main session)" "codex main: Plans row"
# Stale guide: git pull wording, no claude plugin.
stale=$(env KIT_GUIDE_TODAY=2099-01-01 ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
assert_contains "$stale" "Update it: git -C " "codex main: stale line says git pull"
case "$stale" in *"claude plugin"*) fail "codex main: stale line mentions claude plugin";; *) pass;; esac
# Repair line for a broken kit uses git pull too.
pr=$(mktmp); cp -R "$PLUGIN_ROOT/." "$pr/"; rm -f "$pr/rules/models.json"
out=$(env ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$pr" "$pr/hooks/session-start")
assert_contains "$out" "rules did not load" "codex main: broken kit reports the repair line"
case "$out" in *"claude plugin"*) fail "codex main: repair line mentions claude plugin";; *) pass;; esac

# Gemini main with Claude as helper.
d=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"gemini"}\n' > "$d/profile.json"
out=$(run_hook "$d")
case "$out" in *"<!--"*|*subagent*|*"claude plugin"*) fail "gemini main: marker, subagent or claude plugin in output";; *) pass;; esac
assert_contains "$out" "gemini-4-argon-high (the main session)" "gemini main: Plans row"
assert_contains "$out" "its builds go through \`kit-gemini-build\`" "gemini main: Gemini lane rules present"
# Profile with a main agent but no lane: repair line, exit 0.
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
out=$(run_hook "$d"); code=$?
assert_eq 0 "$code" "main agent without its lane: hook exits 0"
assert_contains "$out" "rules did not load" "main agent without its lane: repair line"

# --- Task 4: the Gemini (Antigravity) adapter -------------------------------
AGY="$PLUGIN_ROOT/hooks/session-start-agy"
[ -x "$AGY" ] && pass || fail "session-start-agy is missing or not executable"
d=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"gemini"}\n' > "$d/profile.json"
pr=$(mktmp); cp -R "$PLUGIN_ROOT/." "$pr/"
# Rules text full of characters JSON must escape.
printf '\n## Odd characters\n\n- A "quoted" word, a back\\slash, a tab\there, unicode é → ✓, and a {"json": [1,2]} lookalike.\n\n  Second line with trailing spaces   \n' >> "$pr/rules/RULES.md"
want=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$pr" "$pr/hooks/session-start")
got=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" "$pr/hooks/session-start-agy"); code=$?
assert_eq 0 "$code" "adapter exits 0"
printf '%s' "$got" | jq -e . >/dev/null 2>&1 && pass || fail "adapter output is not valid JSON"
text=$(printf '%s' "$got" | jq -r '.injectSteps[0].systemMessage.systemMessage')
assert_eq "$want" "$text" "adapter carries the same text as session-start"
assert_contains "$text" 'A "quoted" word, a back\slash' "adapter keeps quotes and backslashes"
assert_eq 1 "$(printf '%s' "$got" | jq '.injectSteps | length')" "adapter emits one inject step"
# The adapter speaks for Gemini even when the profile says Claude.
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$d/profile.json"
got=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" "$AGY")
text=$(printf '%s' "$got" | jq -r '.injectSteps[0].systemMessage.systemMessage')
assert_contains "$text" "gemini-4-argon-high (the main session)" "adapter forces the Gemini wording"
case "$text" in *subagent*) fail "adapter text has Claude subagent wording";; *) pass;; esac
# No profile: still valid JSON, exit 0.
e=$(mktmp)
got=$(env ROUTING_KIT_HOME="$e" "$AGY"); code=$?
assert_eq 0 "$code" "adapter without a profile exits 0"
printf '%s' "$got" | jq -e '.injectSteps[0].systemMessage.systemMessage | contains("not set up")' >/dev/null 2>&1 && pass || fail "adapter without a profile: not-set-up text missing"
# Bare PATH.
got=$(env -i PATH=/usr/bin:/bin HOME="$e" ROUTING_KIT_HOME="$d" "$AGY")
printf '%s' "$got" | /usr/bin/python3 -c 'import json,sys; json.load(sys.stdin)' && pass || fail "adapter with a bare PATH: invalid JSON"

# --- degrade by section instead of failing on size ---------------------------
BUDGET=9400
all_profile() { # FILE MAIN
  printf '{"version":1,"claude_plan":"max20","codex":"api","gemini":"ultra","jules":true,"kimi":true,"glm":true,"paseo":true,"main_agent":"%s"}\n' "$2" > "$1"
}
# A home whose caches are fresh (no background refresh) and whose local model
# lists lack two models, so the table prints two Note lines.
mk_notes_home() { # DIR
  mkdir -p "$1/cache" "$1/codex"
  : > "$1/cache/agy-refresh.stamp"
  printf 'gemini-4-argon-high\ngemini-4-hydrogen-medium\ngemini-4-hydrogen-high\ngemini-3.8-flash-medium\n' > "$1/cache/agy-models.txt"
  printf '%s' '{"models":[{"slug":"gpt-6-sol"},{"slug":"gpt-6.1-terra"},{"slug":"gpt-6-astra"},{"slug":"gpt-6-luna"}]}' > "$1/codex/models_cache.json"
}
for m in claude codex gemini; do
  # Normal case: every lane on, no extra lines: nothing is dropped, within budget.
  d=$(mktmp); all_profile "$d/profile.json" $m; mkdir -p "$d/cache"; : > "$d/cache/agy-refresh.stamp"
  out=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
  len=$(printf '%s' "$out" | wc -c | tr -d ' ')
  if [ "$len" -le "$BUDGET" ]; then pass; else fail "$m main, all lanes, normal case: $len chars, over $BUDGET"; fi
  assert_contains "$out" "## Long jobs" "$m main, all lanes: Long jobs kept in the normal case"
  assert_contains "$out" "## Costly tools" "$m main, all lanes: Costly tools kept in the normal case"
  # Worst case: stale line plus two Note lines.
  d=$(mktmp); all_profile "$d/profile.json" $m; mk_notes_home "$d"
  out=$(env KIT_GUIDE_TODAY=2099-01-01 ROUTING_KIT_HOME="$d" CODEX_HOME="$d/codex" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
  len=$(printf '%s' "$out" | wc -c | tr -d ' ')
  echo "worst case, $m main: $len chars" >&2
  if [ "$len" -le "$BUDGET" ]; then pass; else fail "$m main, worst case: $len chars, over $BUDGET"; fi
  case "$out" in *"rules did not load"*) fail "$m main, worst case: repair message instead of rules";; *) pass;; esac
  assert_contains "$out" "## Your routing table" "$m main, worst case: table kept"
  assert_contains "$out" "Note: gpt-6.1-sol is not offered by your codex CLI; using gpt-6-sol." "$m main, worst case: first Note kept"
  assert_contains "$out" "Note: gemini-4-hydrogen-low is not offered by your gemini CLI and has no usable fallback; leaving it out." "$m main, worst case: second Note kept"
  assert_contains "$out" "Routing guide is " "$m main, worst case: stale line kept"
  assert_contains "$out" "## Advisers" "$m main, worst case: the other rules kept"
done

# Drop order with artificially long rules: Costly tools first, then Long jobs,
# then (only then) the size check as a last resort.
d=$(mktmp); all_profile "$d/profile.json" claude; mkdir -p "$d/cache"; : > "$d/cache/agy-refresh.stamp"
run_pad() { # PAD-CHARS
  pr=$(mktmp); cp -R "$PLUGIN_ROOT/." "$pr/"
  python3 -c '
import sys
n = int(sys.argv[2])
p = sys.argv[1] + "/rules/RULES.md"
s = open(p).read()
filler = ("- Filler line that only exists to make the rules long. " * 40).strip()
pad = ""
while len(pad) < n:
    pad += filler + "\n"
pad = pad[:n].rstrip() + "\n"
s = s.replace("## Working with the user\n", "## Working with the user\n\n" + pad + "\n", 1)
open(p, "w").write(s)
' "$pr" "$1"
  env KIT_GUIDE_TODAY="${PAD_TODAY:-$GUIDE_DATE}" ROUTING_KIT_HOME="$d" CODEX_HOME="${PAD_CODEX:-$d/no-codex}" CLAUDE_PLUGIN_ROOT="$pr" "$pr/hooks/session-start"
}
base=$(run_pad 1); base_len=$(printf '%s' "$base" | wc -c | tr -d ' ')
over=$(( BUDGET - base_len + 60 ))
out=$(run_pad "$over")
case "$out" in *"## Costly tools"*) fail "a little over budget: Costly tools should be dropped";; *) pass;; esac
assert_contains "$out" "## Long jobs" "a little over budget: Long jobs kept"
assert_contains "$out" "## Your routing table" "a little over budget: table kept"
[ $(printf '%s' "$out" | wc -c | tr -d ' ') -le "$BUDGET" ] && pass || fail "a little over budget: still over"
out=$(run_pad $(( over + 700 )))
case "$out" in *"## Costly tools"*|*"## Long jobs"*) fail "well over budget: both sections should be dropped";; *) pass;; esac
[ $(printf '%s' "$out" | wc -c | tr -d ' ') -le "$BUDGET" ] && pass || fail "well over budget: output over"
assert_contains "$out" "## Your routing table" "well over budget: table kept"
case "$out" in *"rules did not load"*) fail "well over budget: repair message";; *) pass;; esac
# Last resort: still too big after both drops.
# Last resort keeps every mandatory part: table, Notes, stale line, bin line.
d=$(mktmp); all_profile "$d/profile.json" codex; mk_notes_home "$d"
PAD_TODAY=2099-01-01 PAD_CODEX="$d/codex"
out=$(run_pad 20000)
unset PAD_TODAY PAD_CODEX
assert_contains "$out" "routing-kit rules are too long to load; reinstall the kit." "far too long: one-line notice"
case "$out" in *"rules did not load"*) fail "far too long: bare repair text printed";; *) pass;; esac
assert_contains "$out" "## Your routing table" "far too long: table kept"
assert_contains "$out" "| Work | Use | Notes |" "far too long: table rows kept"
assert_contains "$out" "Note: gpt-6.1-sol is not offered by your codex CLI" "far too long: first Note kept"
assert_contains "$out" "Note: gemini-4-hydrogen-low is not offered" "far too long: second Note kept"
assert_contains "$out" "Routing guide is " "far too long: stale line kept"
assert_contains "$out" "Kit commands live in " "far too long: bin line kept"
[ $(printf '%s' "$out" | wc -c | tr -d ' ') -le "$BUDGET" ] && pass || fail "far too long: output over"

# --- refresh throttle: atomic lock -------------------------------------------
mk_gem_home() { # sets RK; fresh kit home with a Gemini profile
  d=$(mktmp); mkdir -p "$d/.config/routing-kit"; RK="$d/.config/routing-kit"
  printf '{"version":1,"claude_plan":"pro","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$RK/profile.json"
}
fb=$(mktmp)
cat > "$fb/agy" <<'EOF'
#!/bin/bash
echo "$$" >> "$FAKE_AGY_DIR/pids"
echo call >> "$FAKE_AGY_DIR/count"
sleep 20
EOF
chmod +x "$fb/agy"
stop_fakes() { for pid in $(cat "$1/pids" 2>/dev/null); do pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; done; }
hook_gem() { env FAKE_AGY_DIR="$1" PATH="$1:$PATH" KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$RK" CODEX_HOME="$RK/no-codex" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK"; }
calls() { n=$(grep -c call "$1/count" 2>/dev/null); echo "${n:-0}"; }

# Many sessions starting together: one refresh.
mk_gem_home; fc=$(mktmp); cp "$fb/agy" "$fc/agy"
for i in 1 2 3 4 5 6 7 8; do hook_gem "$fc" >/dev/null 2>&1 & done
wait
sleep 1
assert_eq 1 "$(calls "$fc")" "eight simultaneous session starts launch one refresh"
[ ! -d "$RK/cache/agy-refresh.lock" ] && pass || fail "lock left behind after the hooks finished"
stop_fakes "$fc"

# A fresh lock held by another session: no refresh, no stamp.
mk_gem_home; fc=$(mktmp); cp "$fb/agy" "$fc/agy"
mkdir -p "$RK/cache/agy-refresh.lock"
hook_gem "$fc" >/dev/null 2>&1
sleep 1
assert_eq 0 "$(calls "$fc")" "a fresh lock blocks the refresh"
[ ! -e "$RK/cache/agy-refresh.stamp" ] && pass || fail "stamp written while another session held the lock"
[ -d "$RK/cache/agy-refresh.lock" ] && pass || fail "someone else's fresh lock was removed"

# A stale lock (older than 10 minutes) is taken over.
mk_gem_home; fc=$(mktmp); cp "$fb/agy" "$fc/agy"
mkdir -p "$RK/cache/agy-refresh.lock"; touch -t 202001010000 "$RK/cache/agy-refresh.lock"
hook_gem "$fc" >/dev/null 2>&1
sleep 1
assert_eq 1 "$(calls "$fc")" "a stale lock is taken over and the refresh runs"
[ ! -d "$RK/cache/agy-refresh.lock" ] && pass || fail "taken-over lock not released"
stop_fakes "$fc"

# The stamp is rechecked inside the lock: a stamp written meanwhile means no refresh.
mk_gem_home; fc=$(mktmp); cp "$fb/agy" "$fc/agy"
mkdir -p "$RK/cache"; : > "$RK/cache/agy-refresh.stamp"
hook_gem "$fc" >/dev/null 2>&1
sleep 1
assert_eq 0 "$(calls "$fc")" "a fresh stamp means no refresh"
[ ! -d "$RK/cache/agy-refresh.lock" ] && pass || fail "lock left behind when the stamp was fresh"

# --- agent-neutral not-set-up message -----------------------------------------
NEUTRAL="routing-kit is installed but not set up yet. Give your agent START-HERE.md from https://github.com/Jakobuus/claude-routing-kit and ask it to set up routing-kit."
e=$(mktmp)
out=$(env ROUTING_KIT_HOME="$e/none" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
assert_eq "$NEUTRAL" "$out" "not-set-up line is agent-neutral"
out=$(env KIT_MAIN_AGENT=codex ROUTING_KIT_HOME="$e/none" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
assert_eq "$NEUTRAL" "$out" "not-set-up line is the same under Codex"
case "$out" in *"into Claude"*) fail "not-set-up line still says Claude";; *) pass;; esac
# A repair line before the profile is known carries no single agent's command.
pr=$(mktmp); cp -R "$PLUGIN_ROOT/." "$pr/"; rm -f "$pr/bin/kit-common"
out=$(env ROUTING_KIT_HOME="$e/none" CLAUDE_PLUGIN_ROOT="$pr" "$pr/hooks/session-start")
assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "early repair message is one line"
assert_contains "$out" "rules did not load" "early repair message"
case "$out" in *"claude plugin update"*"git -C"*|*"git"*"claude plugin update"*) pass;; *) fail "early repair line should name both ways to update: $out";; esac

# --- the kit's bin folder is named right before the table (Codex, Gemini) -----
d=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
out=$(run_hook "$d")
line="Kit commands live in $PLUGIN_ROOT/bin; call them by full path if they are not on PATH."
assert_contains "$out" "$line" "codex main: bin line present"
before=$(printf '%s\n' "$out" | grep -n -F -- "$line" | cut -d: -f1)
tbl=$(printf '%s\n' "$out" | grep -n '^| Work | Use | Notes |' | cut -d: -f1)
head=$(printf '%s\n' "$out" | grep -n '^## Your routing table' | cut -d: -f1)
if [ "$before" -gt "$head" ] && [ "$before" -lt "$tbl" ]; then pass; else fail "bin line is not between the table heading and the table ($head/$before/$tbl)"; fi
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"gemini"}\n' > "$d/profile.json"
out=$(run_hook "$d")
assert_contains "$out" "$line" "gemini main: bin line present"
printf '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$d/profile.json"
out=$(run_hook "$d")
case "$out" in *"Kit commands live in"*) fail "claude main: bin line must not be printed";; *) pass;; esac
# Claude output is byte-identical with and without the feature: the table follows the heading directly.
case "$out" in *"## Your routing table

| Work |"*) pass;; *) fail "claude main: table does not follow the heading directly";; esac
# A path with a space is shell-quoted.
sp=$(mktmp)/"kit checkout"; mkdir -p "$sp"; cp -R "$PLUGIN_ROOT" "$sp/"
printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
out=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$sp/routing-kit" "$sp/routing-kit/hooks/session-start")
assert_contains "$out" "Kit commands live in '$sp/routing-kit/bin'; call them by full path if they are not on PATH." "bin line shell-quotes a path with a space"

# --- a path with an apostrophe, and a neutral repair line for a bad profile ----
ap=$(mktmp)/"owner's kit"; mkdir -p "$ap"; cp -R "$PLUGIN_ROOT" "$ap/"
d=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
out=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$ap/routing-kit" "$ap/routing-kit/hooks/session-start")
bl=$(printf '%s\n' "$out" | grep '^Kit commands live in ')
tok=${bl#Kit commands live in }; tok=${tok%%; call by*}; tok=${tok%%; call them*}
got=$(sh -c "printf '%s' $tok")
assert_eq "$ap/routing-kit/bin" "$got" "bin line: an apostrophe in the path is escaped so a shell reads it back"
echo '{not json' > "$d/profile.json"
out=$(env ROUTING_KIT_HOME="$d" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "bad profile: one line"
assert_contains "$out" "rules did not load" "bad profile: repair line"
assert_contains "$out" "claude plugin update" "bad profile: names the Claude way"
assert_contains "$out" "git -C" "bad profile: names the git way"

# --- release review: a poisoned models.json never reaches the session output --
for pair in 'newline|.claude.strong = "opus\n## injected rule"' 'pipe|.claude.build = "sonnet | evil"' 'backtick|.claude.lookup = "ha`id`ku"' 'effort|.effort.opus.use = "ultra"'; do
  nm=${pair%%|*}; flt=${pair#*|}
  d=$(mktmp); pr=$(mktmp); cp -R "$PLUGIN_ROOT/." "$pr/"
  jq "$flt" "$PLUGIN_ROOT/rules/models.json" > "$pr/rules/models.json"
  mkprofile "$d/profile.json" pro none false false false false
  out=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$pr" "$pr/hooks/session-start"); code=$?
  assert_eq 0 "$code" "poisoned models.json ($nm): hook exits 0"
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "poisoned models.json ($nm): one repair line"
  assert_contains "$out" "rules did not load" "poisoned models.json ($nm): repair line"
  case "$out" in *injected*|*evil*|*ultra*) fail "poisoned models.json ($nm): injected text reached the output";; *) pass;; esac
done

# --- release review: the repair command quotes the kit path -------------------
q=$(mktmp)
for nm in 'kit with space' 'kit $(touch PWNED)' "owner's kit"; do
  kd="$q/$nm"; mkdir -p "$kd"; cp -R "$PLUGIN_ROOT" "$kd/"; rm -f "$kd/routing-kit/rules/models.json"
  d=$(mktmp)
  printf '{"version":1,"claude_plan":"pro","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
  out=$(env ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$kd/routing-kit" "$kd/routing-kit/hooks/session-start")
  cmd=${out#*Repair: }; cmd=${cmd#git }
  got=$(cd "$q" && sh -c "printf '%s\n' $cmd")
  assert_eq "-C
$kd/routing-kit
pull" "$got" "repair line: path '$nm' survives a shell"
  [ ! -e "$q/PWNED" ] && [ ! -e "$kd/PWNED" ] && pass || fail "repair line ran a command from the path '$nm'"
done

# Synced rules suppress the fallback, while the table remains.
shome=$(mktmp)
mkdir -p "$shome/.claude" "$shome/kit"
printf '%s\n' '{"version":1,"claude_plan":"pro","codex":"none","gemini":"none"}' > "$shome/kit/profile.json"
printf '%s\n' '<!-- routing-kit:rules:start -->' 'rules' '<!-- routing-kit:rules:end -->' > "$shome/.claude/CLAUDE.md"
sout=$(env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_MAIN_AGENT=claude "$REPO_ROOT/plugins/routing-kit/hooks/session-start")
assert_contains "$sout" '## Your routing table' 'synced session has table'
case "$sout" in *'## Costly tools'*) fail 'synced session repeats rules';; *) pass;; esac

env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_BOARD_NAME=claude "$PLUGIN_ROOT/bin/kit-board" post --repo "$REPO_ROOT" hello >/dev/null
env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_BOARD_NAME=claude "$PLUGIN_ROOT/bin/kit-board" post --repo "$REPO_ROOT" --kind claim work >/dev/null
sout=$(env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_BOARD_NAME=claude KIT_MAIN_AGENT=claude "$HOOK")
assert_contains "$sout" 'Board: 1 open notes, 1 claims for this repo.' 'board summary'

# --- Rules fix wave (G2c): only: blocks follow the reader; build-launch and adviser rules ---
# Codex-led profile with Claude enabled. The Claude plugin's hook passes "claude" and must keep the
# only:claude blocks while main:codex blocks still follow the profile; the bare hook (Codex) keeps only:codex.
d=$(mktmp)
printf '{"version":1,"claude_plan":"max5","codex":"plus","gemini":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
out=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK" claude)
assert_contains "$out" 'every subagent gets `model` and `effort`' "reader claude, profile main codex: subagent rule kept"
assert_contains "$out" 'Use the `ask-advisers` skill.' "reader claude, profile main codex: adviser skill kept"
assert_contains "$out" 'subagent builds it' "reader claude, profile main codex: private-data work goes to a subagent"
assert_contains "$out" "gpt-6-astra (the main session)" "reader claude, profile main codex: main: blocks and table still follow the profile"
case "$out" in *"Hardest builds"*|*"<!--"*) fail "reader claude, main codex: main:claude block or marker leaked";; *) pass;; esac
bare=$(run_hook "$d")
case "$bare" in *subagent*|*"Use the \`ask-advisers\` skill."*) fail "bare hook, main codex: Claude-only wording appears";; *) pass;; esac
# The Antigravity adapter reads for Gemini whatever the profile's main agent says.
printf '{"version":1,"claude_plan":"max5","codex":"plus","gemini":"pro","jules":false,"kimi":false,"glm":false,"paseo":false,"main_agent":"codex"}\n' > "$d/profile.json"
got=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" "$AGY")
text=$(printf '%s' "$got" | jq -r '.injectSteps[0].systemMessage.systemMessage')
case "$text" in *subagent*) fail "adapter, profile main codex: Claude subagent wording";; *) pass;; esac
assert_contains "$text" 'One context: one helper call or none' "adapter, profile main codex: only:gemini block kept"
# The Claude plugin's hooks.json names its reader.
assert_eq 'hooks/session-start claude' "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json" | sed 's|^.*/hooks/|hooks/|')" "hooks.json: the Claude plugin's session start passes claude"

# Build-launch rule matches the real commands: effort goes on claude -p / paseo run / codex exec / agy -p;
# the shipped build wrappers take --model only (or nothing, for Jules) and have no effort option.
d=$(mktmp)
all_profile "$d/profile.json" claude
mkdir -p "$d/cache"; : > "$d/cache/agy-refresh.stamp"
out=$(env KIT_GUIDE_TODAY="$GUIDE_DATE" ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$HOOK")
assert_contains "$out" '`kit-codex-build` takes `--model` only' "build rule: kit-codex-build takes --model only"
assert_contains "$out" '`kit-gemini-build` takes `--model` only' "build rule: kit-gemini-build takes --model only"
assert_contains "$out" '`kit-jules-build` takes no model or effort' "build rule: kit-jules-build takes neither"
case "$out" in *"build-command launch"*) fail "build rule still asks for model and effort on every build command";; *) pass;; esac
for b in kit-codex-build kit-gemini-build kit-jules-build locked-build; do
  if grep -q -e '--effort' "$PLUGIN_ROOT/bin/$b"; then fail "$b has an effort option; the rules say it has none"; else pass; fi
done
for b in kit-codex-build kit-gemini-build; do grep -q -e '--model)' "$PLUGIN_ROOT/bin/$b" && pass || fail "$b has no --model option"; done
grep -q -e '--model' "$PLUGIN_ROOT/bin/kit-jules-build" && fail "kit-jules-build takes --model; the rules say it takes none" || pass
# Adviser condition: the second adviser only when the table's row names one.
assert_contains "$out" "also the row's second adviser, when it names one" "advisers: second adviser only when one exists"

# G2e: another agent's synced file cannot suppress the reader's rules.
sout=$(env HOME="$shome" CODEX_HOME="$shome/codex" ROUTING_KIT_HOME="$shome/kit" "$HOOK" codex)
assert_contains "$sout" '## Costly tools' 'codex ignores synced Claude instructions'
env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_BOARD_FAMILY=claude KIT_BOARD_SESSION=s1 "$PLUGIN_ROOT/bin/kit-board" read >/dev/null
sout=$(printf '{"session_id":"s1"}' | env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" "$HOOK" claude)
assert_contains "$sout" 'Board: 0 open notes, 1 claims' 'read notes no longer counted'
env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_BOARD_NAME=claude "$PLUGIN_ROOT/bin/kit-board" post --repo /another/repo --to "repo:$REPO_ROOT" cross-repo >/dev/null
sout=$(printf '{"session_id":"s1"}' | env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" "$HOOK" claude)
assert_contains "$sout" 'Board: 1 open notes, 1 claims' 'repo-addressed cross-repo note counted'
again=$(printf '{"session_id":"s1"}' | env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" "$HOOK" claude)
assert_eq "$sout" "$again" 'session start never advances cursor'
# B1: the event decides who reads, not an inherited KIT_BOARD_NAME / KIT_BOARD_SESSION.
inh=$(printf '{"session_id":"s1"}' | env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_BOARD_NAME=intruder KIT_BOARD_SESSION=other "$HOOK" claude)
assert_eq "$sout" "$inh" 'session start ignores an inherited KIT_BOARD_NAME and KIT_BOARD_SESSION'
# B1 (F2): Antigravity runs hooks in ~/.gemini/config, not in the repo, and names the session
# conversationId (shape recorded in tests/fixtures/hooks/agy/SessionStart-n.json). The board line comes
# from the payload's cwd and conversationId.
agy_payload=$(jq -c --arg cwd "$REPO_ROOT" '.cwd = $cwd | .conversationId = "conv-b1"' "$REPO_ROOT/tests/fixtures/hooks/agy/SessionStart-n.json")
mkdir -p "$shome/elsewhere"
cp "$shome/kit/profile.json" "$shome/profile.claude-only"
printf '%s\n' '{"version":1,"claude_plan":"pro","codex":"none","gemini":"pro"}' > "$shome/kit/profile.json"
agy_out=$( cd "$shome/elsewhere" && printf '%s' "$agy_payload" | env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" KIT_BOARD_NAME=intruder "$AGY")
agy_text=$(printf '%s' "$agy_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')
assert_contains "$agy_text" 'Board: 2 open notes, 1 claims for this repo.' 'agy session start shows the board line (payload cwd, conversationId)'
# Control: the same run without a cwd in the payload sits in the wrong folder and shows no line.
nocwd=$( cd "$shome/elsewhere" && printf '%s' "$agy_payload" | jq -c 'del(.cwd)' | env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" "$AGY")
case "$(printf '%s' "$nocwd" | jq -r '.injectSteps[0].systemMessage.systemMessage')" in *'Board:'*) fail 'no payload cwd: board line shown for the wrong folder';; *) pass;; esac
# The conversation has its own cursor: after it reads the notes as its inferred self, they are not counted.
env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" env -u KIT_BOARD_NAME ANTIGRAVITY_CONVERSATION_ID=conv-b1 "$PLUGIN_ROOT/bin/kit-board" read >/dev/null
read_out=$( cd "$shome/elsewhere" && printf '%s' "$agy_payload" | env HOME="$shome" ROUTING_KIT_HOME="$shome/kit" "$AGY")
assert_contains "$(printf '%s' "$read_out" | jq -r '.injectSteps[0].systemMessage.systemMessage')" 'Board: 0 open notes, 1 claims' 'agy conversation that read the notes has none open (same name from the CLI and the hook)'
cp "$shome/profile.claude-only" "$shome/kit/profile.json"
# R2 regression
mkdir -p "$HOME/worker-private/private"
printf 'PRIVATE WORKER TEXT' > "$HOME/worker-private/private/worker.md"
private_out=$(KIT_ROLE=worker KIT_HOME="$HOME/worker-private" "$HOOK")
case "$private_out" in *'PRIVATE WORKER TEXT') pass;; *) fail 'worker private text missing';; esac

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
