#!/bin/bash
# A Codex build that stops early is told to continue (kit-codex-build, KIT_CODEX_CONTINUES).
# 1: the rule (lib/codex_continue.py); 2: direct mode with a fake codex; 3: Paseo mode with a fake paseo.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/plugins/routing-kit/bin/kit-codex-build"
RULE="$ROOT/plugins/routing-kit/lib/codex_continue.py"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=you@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=you@example.com

# ---- 1. the rule ------------------------------------------------------------------------------
W=$(mktmp)
printf 'Do two steps.\n' > "$W/plain.md"
printf 'Do two steps. End with "items done: N of M".\n' > "$W/count.md"
rule() { # BRIEF FINAL_TEXT -> exit code of `check`
  printf '%s' "$2" > "$W/final.txt"
  python3 "$RULE" check "$W/$1" "$W/final.txt" >/dev/null
}
rule_case() { # EXPECT(unfinished|finished) BRIEF FINAL LABEL
  if rule "$2" "$3"; then got=unfinished; else got=finished; fi
  assert_eq "$1" "$got" "rule: $4"
}
rule_case unfinished plain.md 'Partial. items done: 1 of 2' 'count N < M'
rule_case unfinished plain.md 'findings fixed: 3 of 9' 'findings fixed N < M'
rule_case unfinished plain.md 'features done: 0 of 4' 'features done N < M'
rule_case finished   plain.md 'All good. items done: 2 of 2' 'count N = M'
rule_case unfinished count.md 'Everything is finished.' 'brief asks for a count, message has none'
rule_case unfinished count.md '' 'brief asks for a count, message empty'
rule_case finished   plain.md 'Everything is finished.' 'no count asked, none given'
rule_case unfinished plain.md $'Wrote a.txt.\n\nI'"'"'ll add the guard next.' "plan phrase I'll"
rule_case unfinished plain.md 'Wrote a.txt. I will add b.txt.' 'plan phrase I will'
rule_case unfinished plain.md 'Next I wire the tests.' 'plan phrase Next I'
rule_case unfinished plain.md 'Let me check the other file.' 'plan phrase Let me'
rule_case finished   plain.md 'Done. Let me know if you want changes.' '"Let me know" is not a plan'
rule_case unfinished plain.md 'Incomplete: the parser is missing.' 'says incomplete'
rule_case unfinished plain.md 'The work is not finished.' 'says not finished'
rule_case unfinished plain.md "I didn't do the docs." "says didn't do"
rule_case finished   plain.md $'I\'ll note the plan was earlier.\n\nAll steps are done and checked.' 'a plan phrase before the last paragraph does not count'
rule_case unfinished count.md 'items done: 1 of 3 then items done: 3 of 3 and items done: 2 of 3' 'the last count line wins'
rule_case finished   count.md 'items done: 1 of 3 then items done: 3 of 3' 'the last count line wins (done)'
if python3 "$RULE" check "$W/count.md" "$W/does-not-exist" >/dev/null; then pass; else fail 'rule: a missing final message counts as empty (count asked: unfinished)'; fi
assert_contains "$(python3 "$RULE" message)" 'Nobody will answer you' 'rule: continue message'
assert_contains "$(python3 "$RULE" message)" 'N of N' 'rule: continue message asks for N of N'

closing=$'\n\nWhat I did: implemented\nWhat I didn\'t do: none\nWhat I couldn\'t check: none'
rule_case finished count.md "items done: 2 of 2$closing" 'closing labels'
rule_case finished count.md $'items done: 2 of 2\n\n**What I did**\n- implemented\n**What I didn\'t do**\n- none\n**What I couldn\'t check**\n- none' 'bold closing headings'
rule_case finished plain.md 'Regression test rejects incomplete input' 'subject incomplete'
plan_closing=$'\n\nWhat I did: implemented\nWhat I did not do: none\nWhat I could not check: none'
rule_case unfinished plain.md "I'll add s2.txt next.$plan_closing" 'plan above closing'
rule_case unfinished plain.md "The work is incomplete: item 3 is left.$closing" 'unfinished above closing'
rule_case unfinished count.md "items done: 1 of 2$closing" 'partial above closing'
rule_case unfinished plain.md $'What I did so far: s1.txt\n\nI\'ll add s2.txt next.' 'progress heading then plan'
rule_case unfinished plain.md $'- Groups A-D done.\n- Final captures are incomplete; E-H were not run.' 'captures are incomplete'
rule_case finished plain.md 'Returns 2 on a brief that rejects incomplete input.' 'describes incomplete input'
rule_case unfinished plain.md $'What I did: groups A-D\nWhat I didn\'t do: none\nWhat I couldn\'t check: final captures are incomplete' 'status inside closing lists'
rule_case unfinished plain.md 'Not finished: s2.txt still needs implementing.' 'not finished label'
rule_case unfinished plain.md $'- **Unfinished**: s2.txt' 'unfinished bold label'
rule_case unfinished plain.md $'What I did so far: created s1.txt.\n\nI didn\'t do s2.txt.' 'progress heading then skipped work'

# ---- 2. direct mode ---------------------------------------------------------------------------
mk_src_repo() {
  d=$(mktmp)
  git -C "$d" init -q
  echo hello > "$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" commit -q -m init
  echo "$d"
}
printf 'Step 1: create s1.txt. Step 2: create s2.txt. End with "items done: N of M".\n' > "$W/brief.md"
DB=$(mktmp)
STATE=$(mktmp)
# Fake codex: first call makes s1.txt and ends "items done: 1 of 2"; each resume makes s2.txt.
# FAKE_MODE: finish (one resume completes), never (never completes), done (complete at once), fail (exit 7).
cat > "$DB/codex" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_STATE/argv"
out="" dir="" prev="" resume=no
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  [ "$prev" = -C ] && dir=$a
  [ "$a" = resume ] && resume=yes
  prev=$a
done
[ -n "$dir" ] || dir=$PWD
echo "session id: 00000000-0000-4000-8000-000000000001"
if [ "$resume" = no ]; then
  cat >/dev/null
  [ "$FAKE_MODE" != fail ] || exit 7
  echo s1 > "$dir/s1.txt"
  if [ "$FAKE_MODE" = done ]; then echo s2 > "$dir/s2.txt"; echo 'items done: 2 of 2' > "$out"; else echo "I'll do step 2 next. items done: 1 of 2" > "$out"; fi
else
  n=$(cat "$STUB_STATE/resumes" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STUB_STATE/resumes"
  pwd > "$STUB_STATE/resume-cwd"
  if [ "$FAKE_MODE" = finish ]; then echo s2 > "$dir/s2.txt"; echo 'items done: 2 of 2' > "$out"; else echo "I'll do step 2 next. items done: 1 of 2" > "$out"; fi
fi
exit 0
STUB
chmod +x "$DB/codex"
direct() { # MODE [ENV...]: runs a build; sets dout dcode drun
  mode=$1; shift
  rm -f "$STATE/argv" "$STATE/resumes" "$STATE/resume-cwd"
  dhome=$(mktmp)
  dout=$(env PATH="$DB:/usr/bin:/bin" STUB_STATE="$STATE" FAKE_MODE="$mode" ROUTING_KIT_HOME="$dhome" "$@" \
    "$BIN" --no-paseo --repo "$(mk_src_repo)" --name cont --brief "$W/brief.md" 2>&1)
  dcode=$?
  drun=$(printf '%s\n' "$dout" | sed -n 's/^kit-codex-build: run dir: //p' | head -1)
}
resumes() { cat "$STATE/resumes" 2>/dev/null || echo 0; }

direct finish
assert_eq 0 "$dcode" 'direct: stops once, finishes after one continue: exit 0'
assert_eq 1 "$(resumes)" 'direct: exactly one continue'
assert_contains "$dout" '+++ b/s2.txt' 'direct: the patch has the second step'
assert_contains "$(grep -F 'resume' "$STATE/argv")" '00000000-0000-4000-8000-000000000001' 'direct: resumes the first run session'
assert_contains "$(grep -F 'resume' "$STATE/argv")" 'Nobody will answer you' 'direct: sends the continue message'
assert_contains "$(grep -F 'resume' "$STATE/argv")" 'dangerously-bypass-approvals-and-sandbox' 'direct: the resume has no sandbox either'
case "$(cat "$STATE/resume-cwd")" in */wt) pass ;; *) fail "direct: resume runs in the build copy ($(cat "$STATE/resume-cwd"))" ;; esac

direct never
assert_eq 0 "$dcode" 'direct: never finishing ends as today (exit 0)'
assert_eq 3 "$(resumes)" 'direct: default is exactly 3 continues'
assert_contains "$(cat "$drun/codex-output.txt")" 'stopped early after 3 continues' 'direct: says it stopped early after 3 continues'

direct never KIT_CODEX_CONTINUES=2
assert_eq 2 "$(resumes)" 'direct: KIT_CODEX_CONTINUES=2 gives exactly 2'
assert_contains "$(cat "$drun/codex-output.txt")" 'stopped early after 2 continues' 'direct: reason names 2'

direct never KIT_CODEX_CONTINUES=0
assert_eq 0 "$dcode" 'direct: off: exit 0'
assert_eq 0 "$(resumes)" 'direct: KIT_CODEX_CONTINUES=0 never continues'

direct done
assert_eq 0 "$dcode" 'direct: finished agent: exit 0'
assert_eq 0 "$(resumes)" 'direct: a finished agent is not continued'

direct fail
assert_eq 4 "$dcode" 'direct: a failed codex ends as today (exit 4)'
assert_eq 0 "$(resumes)" 'direct: a failed codex is never continued'

direct never KIT_CODEX_CONTINUES=abc
assert_eq 2 "$dcode" 'direct: a bad KIT_CODEX_CONTINUES is refused (exit 2)'

# ---- 3. Paseo mode ----------------------------------------------------------------------------
P=$(TMPDIR="$HOME" mktmp)
mkdir -p "$P/bin" "$P/state"
export STUB_STATE_P="$P/state"
cat > "$P/bin/paseo" <<'STUB'
#!/bin/bash
S=$STUB_STATE_P
printf '%s\n' "$*" >> "$S/args"
cmd=$1; shift
cnt() { cat "$S/sends" 2>/dev/null || echo 0; }
case "$cmd" in
 run)
  cwd= prev=
  for a in "$@"; do [ "$prev" = --cwd ] && cwd=$a; prev=$a; done
  echo "$cwd" > "$S/last"
  echo s1 > "$cwd/s1.txt"
  echo agent-cont-1;;
 send)
  [ "${STUB_SEND_FAIL:-}" != yes ] || exit 1
  n=$(cnt); echo $((n + 1)) > "$S/sends"
  # The message arrives as a file.
  prev=
  for a in "$@"; do [ "$prev" = --prompt-file ] && cp "$a" "$S/last-message"; prev=$a; done
  [ "$STUB_MODE" != finish ] || echo s2 > "$(cat "$S/last")/s2.txt";;
 wait)
  printf '{"status":"%s"}\n' "${STUB_STATUS:-idle}";;
 logs)
  [ "${STUB_BUDGET:-}" != yes ] || sleep 2
  echo '---'
  case "$STUB_MODE" in
   done) echo 'items done: 2 of 2';;
   finish) if [ "$(cnt)" -ge 1 ]; then echo 'items done: 2 of 2'; else echo "I'll do step 2 next. items done: 1 of 2"; fi;;
   *) echo "I'll do step 2 next. items done: 1 of 2";;
  esac;;
 inspect)
  archived=false; [ ! -f "$S/archived" ] || archived=true
  jq -n --arg cwd "$(cat "$S/last")" --argjson archived "$archived" \
   '{Id:"agent-cont-1",Cwd:$cwd,Status:(if $archived then "closed" else "idle" end),Archived:$archived,PendingPermissions:[]}';;
 stop) exit 0;;
 archive) : > "$S/archived";;
 ls) echo '[]';;
 workspace)
  case "$1" in
   ls) if [ -f "$S/ws-archived" ]; then echo '[]'; else jq -n --arg cwd "$(cat "$S/last")" '[{workspaceId:"workspace-cont-1",cwd:$cwd}]'; fi;;
   archive) : > "$S/ws-archived"; : > "$S/archived";;
  esac;;
 *) exit 91;;
esac
STUB
chmod +x "$P/bin/paseo"
printf '#!/bin/bash\nexit 93\n' > "$P/bin/codex"; chmod +x "$P/bin/codex"
PR=$P/repo; mkdir -p "$PR"; git -C "$PR" init -q; echo hello > "$PR/a.txt"; git -C "$PR" add a.txt; git -C "$PR" commit -q -m init
paseo_run() { # MODE [ENV...]: sets pout pcode prun
  mode=$1; shift
  rm -f "$P/state/"*
  phome=$(TMPDIR="$HOME" mktmp)
  pout=$(env PATH="$P/bin:/usr/bin:/bin" STUB_STATE_P="$P/state" STUB_MODE="$mode" ROUTING_KIT_HOME="$phome" "$@" \
    "$BIN" --paseo --timeout "${PASEO_TEST_TIMEOUT:-1800}" --repo "$PR" --name cont --brief "$W/brief.md" 2>&1)
  pcode=$?
  prun=$(dirname "$(find "$phome/runs" -name manifest.json -print | head -1)")
}
sends() { cat "$P/state/sends" 2>/dev/null || echo 0; }

paseo_run finish
assert_eq 0 "$pcode" 'paseo: stops once, finishes after one continue: exit 0'
assert_eq 1 "$(sends)" 'paseo: exactly one continue'
assert_contains "$(cat "$prun/build.patch")" '+++ b/s2.txt' 'paseo: the patch has the second step'
assert_eq 1 "$(jq -r '.continues' "$prun/manifest.json")" 'paseo: manifest says continues 1'
assert_contains "$(cat "$prun/result.md")" 'continued 1 time' 'paseo: result.md records the continue'
assert_contains "$(cat "$P/state/last-message")" 'Nobody will answer you' 'paseo: the continue message was sent'
assert_contains "$(grep '^send ' "$P/state/args")" 'agent-cont-1' 'paseo: sent to the build agent'

paseo_run never
assert_eq 0 "$pcode" 'paseo: never finishing ends as today (exit 0)'
assert_eq 3 "$(sends)" 'paseo: default is exactly 3 continues'
assert_eq 3 "$(jq -r '.continues' "$prun/manifest.json")" 'paseo: manifest says continues 3'
assert_contains "$(cat "$prun/result.md")" 'stopped early after 3 continues' 'paseo: result.md says stopped early after 3 continues'

paseo_run never KIT_CODEX_CONTINUES=1
assert_eq 1 "$(sends)" 'paseo: KIT_CODEX_CONTINUES=1 gives exactly 1'

paseo_run never KIT_CODEX_CONTINUES=0
assert_eq 0 "$(sends)" 'paseo: KIT_CODEX_CONTINUES=0 never continues'
assert_eq 0 "$(jq -r '.continues' "$prun/manifest.json")" 'paseo: off: manifest says continues 0'

paseo_run done
assert_eq 0 "$pcode" 'paseo: finished agent: exit 0'
assert_eq 0 "$(sends)" 'paseo: a finished agent is not continued'
assert_eq 0 "$(jq -r '.continues' "$prun/manifest.json")" 'paseo: finished: manifest says continues 0'

paseo_run never STUB_STATUS=timeout
assert_eq 124 "$pcode" 'paseo: timeout keeps exit 124'
assert_eq 0 "$(sends)" 'paseo: a timeout is never continued'

paseo_run never STUB_STATUS=permission
assert_eq 6 "$pcode" 'paseo: permission wait keeps exit 6'
assert_eq 0 "$(sends)" 'paseo: a permission wait is never continued'

paseo_run never STUB_STATUS=error
assert_eq 4 "$pcode" 'paseo: an error keeps exit 4'
assert_eq 0 "$(sends)" 'paseo: an error is never continued'

paseo_run never STUB_SEND_FAIL=yes
assert_eq 4 "$pcode" 'paseo: failed continue send exits 4'
assert_contains "$(cat "$prun/build.patch")" '+++ b/s1.txt' 'failed send keeps patch'
assert_contains "$(cat "$prun/result.md")" 'could not send' 'paseo: a failed send is said in result.md'

PASEO_TEST_TIMEOUT=1 paseo_run never STUB_BUDGET=yes
assert_eq 124 "$pcode" 'paseo: exhausted continue budget exits 124'
assert_contains "$(cat "$prun/result.md")" 'time budget is used up' 'budget note'

printf 'test_codex_continue: PASS=%s FAIL=%s\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
