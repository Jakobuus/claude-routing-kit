#!/bin/bash
# Hash the text strictly between the marker lines: lines after the start line
# up to and excluding the end line, joined with "\n", with a trailing "\n".
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
export HOME="$(mktmp)"
export CODEX_HOME="$(mktmp)"
export ROUTING_KIT_HOME="$(mktmp)"
. plugins/routing-kit/bin/kit-common
claude_home=$(mktmp)
gemini_home=$(mktmp)
repos=$(mktmp)
export DOCTOR_MARKER="$HOME/probed"
export DOCTOR_COST_FIXTURES="$PWD/tests/fixtures/doctor/cost"
doctor="$PWD/plugins/routing-kit/bin/kit-doctor"
args=(--home-claude "$claude_home" --home-codex "$CODEX_HOME" --home-gemini "$gemini_home" --repos-root "$repos")
run() { "$doctor" "${args[@]}" "$@"; }
clean() {
  rm -rf "$claude_home"/* "$CODEX_HOME"/* "$gemini_home"/* "$repos"/* "$ROUTING_KIT_HOME"/*
  mkdir -p "$repos/repo" "$claude_home/skills"
  kit_python3 - "$claude_home" "$ROUTING_KIT_HOME" <<'PY'
import sys,pathlib,json,hashlib
home,kit=map(pathlib.Path,sys.argv[1:])
rules=home/'CLAUDE.md'
rules.write_text('Outside\n<!-- routing-kit:rules:start -->\nManaged\n<!-- routing-kit:rules:end -->\n')
target=kit/'skill'
target.mkdir()
link=home/'skills/example'
link.symlink_to(target)
(kit/'sync-state.json').write_text(json.dumps({'files':{str(rules):hashlib.sha256(b'Managed\n').hexdigest()},'links':{str(link):{'target':str(target),'skill':'example','agent':'claude'}}}))
PY
}
# 1: edited block, exact text, JSON identity, successful exit.
clean
sed 's/Managed/Changed/' "$claude_home/CLAUDE.md" > "$HOME/edited"
cp "$HOME/edited" "$claude_home/CLAUDE.md"
assert_eq "edited by hand: $claude_home/CLAUDE.md" "$(run)" "edited block"
assert_exit 0 "findings exit zero" -- run
out=$(run --json)
parsed=$(printf '%s' "$out" | kit_python3 -c 'import json,sys; a=json.load(sys.stdin); assert len(a)==1; print(a[0]["check"]+"|"+a[0]["message"])')
assert_eq "edited_by_hand|edited by hand: $claude_home/CLAUDE.md" "$parsed" "JSON finding"
# 2: missing and misdirected symlinks.
clean
rm "$claude_home/skills/example"
assert_eq "skill missing: example in claude" "$(run)" "missing link"
ln -s "$HOME" "$claude_home/skills/example"
assert_eq "skill missing: example in claude" "$(run)" "wrong target"
# 3: default and explicit Codex budget, Antigravity byte limit.
clean
kit_python3 - "$CODEX_HOME" "$repos" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[1],'AGENTS.md').write_bytes(b'x'*20000)
pathlib.Path(sys.argv[2],'repo/AGENTS.md').write_bytes(b'y'*13000)
PY
assert_eq "Codex would cut rules in $repos/repo" "$(run)" "default budget"
echo 'project_doc_max_bytes = 65536' > "$CODEX_HOME/config.toml"
assert_eq "" "$(run)" "configured budget"
kit_python3 - "$gemini_home/AGENTS.md" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[1]).write_bytes(b'x'*24001)
PY
assert_eq "Antigravity would cut $gemini_home/AGENTS.md" "$(run)" "Antigravity budget"
# 3b: Codex override file, and Antigravity on every repo rules file.
clean
kit_python3 - "$CODEX_HOME" "$repos" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[1],'AGENTS.md').write_bytes(b'x'*100)
pathlib.Path(sys.argv[1],'AGENTS.override.md').write_bytes(b'x'*20000)
pathlib.Path(sys.argv[2],'repo/AGENTS.md').write_bytes(b'y'*13000)
PY
assert_eq "Codex would cut rules in $repos/repo" "$(run)" "override file wins"
: > "$CODEX_HOME/AGENTS.override.md"
assert_eq "" "$(run)" "empty override falls back to AGENTS.md"
kit_python3 - "$repos" <<'PY'
import pathlib,sys
pathlib.Path(sys.argv[1],'repo/AGENTS.md').write_bytes(b'y'*24001)
PY
echo 'project_doc_max_bytes = 65536' > "$CODEX_HOME/config.toml"
assert_eq "Antigravity would cut $repos/repo/AGENTS.md" "$(run)" "Antigravity repo file"
# 3c: one empty or invalid file never hides the other findings.
clean
mkdir -p "$gemini_home/config"
: > "$gemini_home/config/mcp_config.json"
echo '{not json' > "$claude_home/settings.json"
rm "$claude_home/skills/example"
assert_eq "skill missing: example in claude" "$(run)" "bad config files still report"
assert_exit 0 "bad config files exit zero" -- run
# 4: eager tools in each agent.
clean
echo '{"env":{"ENABLE_TOOL_SEARCH":"false"}}' > "$claude_home/settings.json"
assert_eq "tools load up front in claude" "$(run)" "Claude eager tools"
rm "$claude_home/settings.json"
mkdir -p "$gemini_home/config"
echo '{"mcpServers":{"example":{"eager":true}}}' > "$gemini_home/config/mcp_config.json"
assert_eq "tools load up front in gemini" "$(run)" "Gemini eager tools"
# 5: incremental hook errors, including fast-run acknowledgement.
clean
printf 'first\nsecond\n' > "$ROUTING_KIT_HOME/hook-errors.log"
assert_eq "routing kit: hooks had 2 errors" "$(run --fast)" "new hook errors"
assert_eq "" "$(run)" "errors acknowledged"
# 5b: media jobs from the last 7 days only (3 seen, one without a route), never in the fast run.
clean
assert_eq "" "$(run)" "no media log, no line"
kit_python3 - "$ROUTING_KIT_HOME/route-log.jsonl" <<'PY'
import datetime,json,sys
now=datetime.datetime.now(datetime.timezone.utc)
f=lambda d:(now-datetime.timedelta(days=d)).strftime('%Y-%m-%dT%H:%M:%SZ')
rows=[{'time':f(1),'agent':'claude','job':'images'},{'time':f(2),'agent':'agy','job':'ocr'},
      {'time':f(3),'agent':'codex','job':'music','routed':False},{'time':f(9),'agent':'claude','job':'images'}]
open(sys.argv[1],'w').write('\n'.join(json.dumps(r) for r in rows)+'\nnot json\n')
PY
assert_eq "media jobs: 3 seen, 2 routed" "$(run)" "media jobs weekly line"
assert_eq "" "$(run --fast)" "media line stays out of the fast run"
# 6: deterministic cost probes and a PATH with no real agent binaries.
clean
stubbin=$(mktmp)
for tool in /usr/bin/* /bin/*; do
  name=${tool##*/}
  case "$name" in claude|codex|agy) continue ;; esac
  [ -f "$tool" ] && [ -x "$tool" ] && ln -sf "$tool" "$stubbin/$name"
done
for name in claude codex agy; do
  cp tests/fixtures/doctor/cost/probe "$stubbin/$name"
  chmod +x "$stubbin/$name"
done
saved_path=$PATH
export PATH="$stubbin"
expected=$(kit_python3 - "$DOCTOR_COST_FIXTURES" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
c=[e for e in json.loads((p/'claude.json').read_text()) if e.get('type')=='result'][0]['usage']
c={k:c[k] for k in ('input_tokens','cache_creation_input_tokens','cache_read_input_tokens')}
d=[e for e in map(json.loads,[l for l in (p/'codex.jsonl').read_text().splitlines() if l.startswith('{')]) if e.get('type')=='turn.completed'][0]['usage']
g=json.loads((p/'agy.json').read_text())['usage']
print('claude: %s tokens at start'%sum(c.values()))
print('codex: %s tokens at start'%d['input_tokens'])
print('gemini: %s tokens at start'%g['input_tokens'])
PY
)
assert_eq "$expected" "$(run --cost "$repos/repo")" "cost totals"
rm "$stubbin/codex"
assert_contains "$(run --cost "$repos/repo")" "codex: not installed" "absent Codex"
rm -f "$DOCTOR_MARKER"
run --fast --cost "$repos/repo" >/dev/null
assert_eq absent "$([ -e "$DOCTOR_MARKER" ] && echo present || echo absent)" "fast never probes"
export PATH="$saved_path"
# 7: quiet clean fast run, then exactly one summary line for two findings.
clean
assert_eq "" "$(run --fast)" "clean fast output"
assert_exit 0 "clean fast exit" -- run --fast
rm "$claude_home/skills/example"
echo '{"env":{"ENABLE_TOOL_SEARCH":"false"}}' > "$claude_home/settings.json"
out=$(run --fast)
case "$out" in
  "routing kit: skill missing: example in claude (+1 more; run kit-doctor)"|"routing kit: tools load up front in claude (+1 more; run kit-doctor)") pass ;;
  *) fail "two findings fast summary (got [$out])" ;;
esac
# 8: median wall time includes process startup; unsuccessful runs cannot pass.
clean
assert_exit 0 "clean fast median under 200ms" -- kit_python3 - "$doctor" "${args[@]}" <<'PY'
import subprocess,sys,time,statistics
times=[]
for _ in range(3):
    start=time.monotonic()
    result=subprocess.run([sys.argv[1],*sys.argv[2:],'--fast'],capture_output=True)
    times.append(time.monotonic()-start)
    assert result.returncode==0 and result.stdout==b'', result
assert statistics.median(times)<.200, times
PY
clean
for target in "$claude_home/settings.json" "$CODEX_HOME/hooks.json" "$gemini_home/config/hooks.json"; do
  mkdir -p "$(dirname "$target")"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"command":"/kit/hooks/kit-hook","timeout":11}]}]}}' > "$target"
done
out=$(run)
assert_contains "$out" "run kit-sync hooks" "stale hook timeout has fix"
assert_eq 3 "$(printf '%s\n' "$out" | /usr/bin/grep -c 'hook timeout too low')" "all three homes checked"
out=$(run --fast)
assert_eq "" "$out" "fast skips timeout checks"
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
