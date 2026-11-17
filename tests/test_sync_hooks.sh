#!/bin/bash
# kit-sync hooks: exact-command ownership. Sync only adds the kit's own entries; undo only removes handlers whose
# command equals one the kit generated; nothing else is ever touched and no file is ever restored.
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
P="$ROOT/plugins/routing-kit"
. "$P/bin/kit-common"
F="$ROOT/tests/fixtures/sync-hooks"
setup() {
 s=$(mktmp)
 export HOME="$s/home" CODEX_HOME="$s/codex" ROUTING_KIT_HOME="$s/kit"
 export KIT_HOOK_REGISTRY="$F/registry.json" KIT_SELFTEST_CMD=true
 mkdir -p "$HOME" "$CODEX_HOME" "$ROUTING_KIT_HOME"
 settings="$s/settings.json"; agy="$s/agy.json"; codexf="$CODEX_HOME/hooks.json"
 cp "$F/settings.json" "$settings"; cp "$F/foreign.json" "$codexf"; cp "$F/agy.json" "$agy"
 cp "$F/config.toml" "$CODEX_HOME/config.toml"
 printf '{"version":1,"claude_hooks":"%s"}\n' "$1" > "$ROUTING_KIT_HOME/profile.json"
}
run() {
 out=$("$P/bin/kit-sync" hooks --claude-settings "$settings" --agy-hooks "$agy" "$@" 2>&1); code=$?
 [ "$code" -eq 0 ]
}
target_of() { case "$1" in settings) echo "$settings";; codex) echo "$codexf";; agy) echo "$agy";; esac; }
result() { if [ "$2" -eq 0 ]; then pass; else fail "$1"; fi; }
# jedit FILE PYSTATEMENTS: loads FILE as JSON into d, runs the statements, writes it back (compact).
jedit() {
 kit_python3 - "$1" "$2" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text())
exec(sys.argv[2])
p.write_text(json.dumps(d))
PY
}
# jcmds FILE: every command string in the file, one per line.
jcmds() {
 kit_python3 - "$1" <<'PY'
import json,pathlib,sys
def walk(x):
 if isinstance(x,dict):
  if isinstance(x.get('command'),str): print(x['command'])
  for v in x.values(): walk(v)
 elif isinstance(x,list):
  for v in x: walk(v)
walk(json.loads(pathlib.Path(sys.argv[1]).read_text()))
PY
}
# check AGENT: each event has exactly one kit entry in the right shape, with the right command and timeout; foreign kept.
check() {
 kit_python3 - "$s" "$P" "$1" <<'PY'
import json,pathlib,sys
s,p,agent=sys.argv[1:]; s=pathlib.Path(s)
f={'settings':s/'settings.json','codex':s/'codex/hooks.json','agy':s/'agy.json'}[agent]
d=json.loads(f.read_text()); ag='claude' if agent=='settings' else agent
h=d['routing-kit'] if ag=='agy' else d['hooks']
events=['SessionStart','PreToolUse','PreInvocation','Stop'] if ag=='agy' else ['SessionStart','UserPromptSubmit','PreToolUse','PostToolUse','Stop']
for event in events:
 groups=h[event]; entries=[x for g in groups for x in (g.get('hooks',[g]))]
 expected=p+'/hooks/kit-hook '+ag+' '+event
 found=[x for x in entries if x.get('command')==expected]
 assert len(found)==1,(event,found)
 assert found[0]['command']==expected
 if event=='Stop': assert found[0]['timeout']==65
 if event=='PreToolUse':
  matcher=next(g['matcher'] for g in groups if any('kit-hook' in x.get('command','') for x in g.get('hooks',[])))
  assert set(matcher.split('|'))==set({'claude':'Bash|Agent|Write|Edit|MultiEdit|NotebookEdit','codex':'Bash|apply_patch|exec_command','agy':'run_command|write_file|edit_file|write_to_file|replace_file_content|multi_replace_file_content'}[ag].split('|'))
if ag=='agy': assert d['foreign']=={'Stop':[{'type':'command','command':'foreign-stop','timeout':9}]}
else:
 assert d['theme']=='keep'
 for event,command in [('Stop','foreign-stop'),('PreToolUse','foreign-read')]:
  assert h[event][0]['hooks'][0]['command']==command
PY
}
# 1-3: each target gets the kit's entries once (per-agent shape, native timeout), keeps its foreign content, and
# undo gives the original back byte for byte (even after a repeat sync). The settings fixture's old guard scripts are
# foreign now: sync adds only, never replaces them.
for agent in settings codex agy; do
 mode=plugin; [ "$agent" = settings ] && mode=settings
 setup "$mode"; target=$(target_of "$agent")
 cp "$target" "$s/original"
 (run && check "$agent" && run && run --undo && cmp -s "$target" "$s/original") >/dev/null 2>&1
 result "$agent merge, timeout, repeat and undo" "$?"
done
setup settings
(run && for old in guard-destructive.sh guard-owner-checkout.py require-subagent-model.py prep-for-exit-trigger.sh continuation-judge.py; do jcmds "$settings" | grep -q "/old/$old" || exit 1; done) >/dev/null 2>&1
result 'settings mode only adds: the owner old scripts stay' "$?"
# 4: plugin mode leaves Claude's settings and the shipped plugin hooks.json alone.
setup plugin
cp "$settings" "$s/settings.before"; cp "$P/hooks/hooks.json" "$s/plugin.before"
(run && cmp -s "$settings" "$s/settings.before" && cmp -s "$P/hooks/hooks.json" "$s/plugin.before" && ! grep -q "$settings" "$ROUTING_KIT_HOME/sync-state.json") >/dev/null 2>&1
result 'plugin mode writes no Claude file' "$?"
# 5-7: repeats leave targets, config and state byte-equal.
for agent in settings codex agy; do
 mode=plugin; [ "$agent" = settings ] && mode=settings
 setup "$mode"
 (run && cp "$settings" "$s/a" && cp "$agy" "$s/c" && cp "$codexf" "$s/d" && cp "$CODEX_HOME/config.toml" "$s/e" && cp "$ROUTING_KIT_HOME/sync-state.json" "$s/f" && run && cmp -s "$settings" "$s/a" && cmp -s "$agy" "$s/c" && cmp -s "$codexf" "$s/d" && cmp -s "$CODEX_HOME/config.toml" "$s/e" && cmp -s "$ROUTING_KIT_HOME/sync-state.json" "$s/f") >/dev/null 2>&1
 result "$agent repeat byte-equal" "$?"
done
# 8: Codex trust: written only after the selftest passes (stub), as whole tables appended after the foreign text; the
# selftest runs once per sync and never on undo or --dry-run; undo gives config.toml back byte for byte.
stub() { # stub pass|fail: a selftest stand-in that logs each call
 printf '#!/bin/sh\necho call >> "%s/selftest.log"\n[ -f "%s/selftest.fail" ] && { echo "boom: 1 failed"; exit 1; }\nexit 0\n' "$s" "$s" > "$s/selftest"; chmod +x "$s/selftest"
 export KIT_SELFTEST_CMD="$s/selftest"; : > "$s/selftest.log"; rm -f "$s/selftest.fail"; [ "$1" = fail ] && : > "$s/selftest.fail"
 return 0
}
tables() { grep -c '^\[hooks.state."'"$CODEX_HOME"'/hooks.json:' "$CODEX_HOME/config.toml"; }
setup plugin; stub pass
(run && [ "$(tables)" -eq 6 ] && head -c "$(wc -c < "$F/config.toml")" "$CODEX_HOME/config.toml" | cmp -s - "$F/config.toml" && [ "$(wc -l < "$s/selftest.log")" -eq 1 ] \
 && case "$out" in *'Codex trusts the kit hooks (6)'*) true;; *) false;; esac \
 && run && [ "$(wc -l < "$s/selftest.log")" -eq 2 ] && [ "$(tables)" -eq 6 ] \
 && run --undo && cmp -s "$CODEX_HOME/config.toml" "$F/config.toml" && [ "$(wc -l < "$s/selftest.log")" -eq 2 ] && ! grep -q codex_trust "$ROUTING_KIT_HOME/sync-state.json") >/dev/null 2>&1
result 'Codex trust: tables written after the selftest passes, byte-exact undo, no selftest on undo' "$?"
# 8b: a failing selftest writes nothing and says so (exit 1); the hooks themselves are still written.
setup plugin; stub fail
(! run && [ "$(tables)" -eq 0 ] && cmp -s "$CODEX_HOME/config.toml" "$F/config.toml" && jcmds "$codexf" | grep -q 'kit-hook codex Stop' && case "$out" in *'hooks selftest failed (boom: 1 failed)'*) true;; *) false;; esac) >/dev/null 2>&1
result 'failing selftest: no trust written, hooks kept, exit 1' "$?"
# 8c: trust written, then a later selftest fails: exactly the kit's tables go, config.toml is the original again.
setup plugin; stub pass
(run && [ "$(tables)" -eq 6 ] && stub fail && ! run && cmp -s "$CODEX_HOME/config.toml" "$F/config.toml" && ! grep -q codex_trust "$ROUTING_KIT_HOME/sync-state.json" && stub pass && run && [ "$(tables)" -eq 6 ]) >/dev/null 2>&1
result 'later failing selftest removes the trust tables; a pass writes them again' "$?"
# 8d: --dry-run writes nothing and does not run the selftest.
setup plugin; stub pass
(run --dry-run && cmp -s "$CODEX_HOME/config.toml" "$F/config.toml" && [ ! -s "$s/selftest.log" ] && cmp -s "$codexf" "$F/foreign.json" && case "$out" in *'would run the hooks selftest, then trust 6 Codex hooks'*) true;; *) false;; esac) >/dev/null 2>&1
result 'dry-run: nothing written, selftest not run' "$?"
# 8e: the hash equals the independent known answers (codex 0.166.0 hooks/list) and the stub-free python check agrees
# with the tables the sync wrote; a foreign trust entry for the same hook key is left alone (nothing added, nothing removed).
setup plugin; stub pass
(run && kit_python3 - "$CODEX_HOME" <<'PY'
import hashlib,json,pathlib,re,sys
home=pathlib.Path(sys.argv[1]); d=json.loads((home/'hooks.json').read_text())['hooks']; t={k:{'trusted_hash':h} for k,h in re.findall(r'\[hooks\.state\."(.*?)"\]\ntrusted_hash = "(.*?)"',(home/'config.toml').read_text())}
for event,label in (('SessionStart','session_start'),('UserPromptSubmit','user_prompt_submit'),('PreToolUse','pre_tool_use'),('PostToolUse','post_tool_use'),('Stop','stop')):
 for gi,g in enumerate(d[event]):
  for hi,h in enumerate(g['hooks']):
   if 'kit-hook' not in h['command'] and 'session-start' not in h['command']: continue
   ident={'event_name':label,'hooks':[{'type':'command','command':h['command'],'async':False,'timeout':h['timeout']}]}
   if 'matcher' in g and event in ('SessionStart','PreToolUse','PostToolUse'): ident['matcher']=g['matcher']
   want='sha256:'+hashlib.sha256(json.dumps(ident,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
   assert t[str(home/'hooks.json')+':%s:%d:%d'%(label,gi,hi)]['trusted_hash']==want,(event,gi,hi)
PY
) >/dev/null 2>&1
result 'trust tables carry the hash an independent computation gives' "$?"
setup plugin; stub pass
(run && key=$(kit_python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["codex_trust"]["items"][0][0])' "$ROUTING_KIT_HOME/sync-state.json") && run --undo \
 && printf '\n[hooks.state."%s"]\nenabled = false\n' "$key" >> "$CODEX_HOME/config.toml" && cp "$CODEX_HOME/config.toml" "$s/foreign-entry.toml" \
 && run && [ "$(tables)" -eq 6 ] && [ "$(grep -c 'trusted_hash' "$CODEX_HOME/config.toml")" -eq 6 ] && case "$out" in *'already has its own entry'*) true;; *) false;; esac \
 && run --undo && cmp -s "$CODEX_HOME/config.toml" "$s/foreign-entry.toml") >/dev/null 2>&1
result 'foreign trust entry for a kit hook key: left alone on sync and undo' "$?"
# 8g: any error running the selftest command is a failure: an unparseable or empty command removes the block again.
for bad in "'unclosed" " " "/nonexistent/selftest"; do
 setup plugin; stub pass
 (run && [ "$(tables)" -eq 6 ] && export KIT_SELFTEST_CMD="$bad" && ! run && [ "$(tables)" -eq 0 ] && cmp -s "$CODEX_HOME/config.toml" "$F/config.toml" && ! grep -q codex_trust "$ROUTING_KIT_HOME/sync-state.json") >/dev/null 2>&1
 result "selftest command error ($bad) removes the trust block" "$?"
done
# 8h: the block is the last thing in config.toml. Text added after it is never searched around: nothing is removed
# (sync, failed selftest or undo), the owner gets one line, and a sync does not add a second block.
setup plugin; stub pass
(run && printf 'late = 1\n' >> "$CODEX_HOME/config.toml" && cp "$CODEX_HOME/config.toml" "$s/late.toml" \
 && run && cmp -s "$CODEX_HOME/config.toml" "$s/late.toml" && case "$out" in *'remove it by hand'*) true;; *) false;; esac \
 && stub fail && ! run && cmp -s "$CODEX_HOME/config.toml" "$s/late.toml" && case "$out" in *'remove it by hand'*) true;; *) false;; esac \
 && stub pass && run --undo && cmp -s "$CODEX_HOME/config.toml" "$s/late.toml" && case "$out" in *'remove it by hand'*) true;; *) false;; esac \
 && [ "$(grep -c 'routing-kit hook trust: start' "$CODEX_HOME/config.toml")" -eq 1 ]) >/dev/null 2>&1
result 'text after the block: nothing removed, one by-hand line, no second block' "$?"
# 8i: undo removes exactly the bytes sync appended, whatever config.toml looked like (no final newline, only whitespace).
for original in 'a = 1' ' \t\n\n' ''; do
 setup plugin; stub pass; printf "$original" > "$CODEX_HOME/config.toml"; cp "$CODEX_HOME/config.toml" "$s/orig.toml"
 (run && [ "$(tables)" -eq 6 ] && run --undo && [ -f "$CODEX_HOME/config.toml" ] && cmp -s "$CODEX_HOME/config.toml" "$s/orig.toml") >/dev/null 2>&1
 result "undo gives config.toml back byte for byte (original: $original)" "$?"
done
# 8j: a config.toml the kit created is removed again by undo; the trust block sits between its two owned comment lines.
setup plugin; stub pass; rm -f "$CODEX_HOME/config.toml"
(run && [ "$(sed -n 1p "$CODEX_HOME/config.toml" | cut -c1-31)" = '# routing-kit hook trust: start' ] && [ "$(tail -n 1 "$CODEX_HOME/config.toml")" = '# routing-kit hook trust: end' ] && run --undo && [ ! -e "$CODEX_HOME/config.toml" ]) >/dev/null 2>&1
result 'created config.toml: block between the owned comment lines, undo removes the file' "$?"
kit_python3 "$ROOT/tests/test_codex_trust.py" >/dev/null 2>&1
result 'codex_trust unit tests (known answers from codex 0.166.0, ownership rules)' "$?"
# 9: doctor sees a changed kit command, and no false drift after a foreign addition.
setup settings
(
 run || exit 1
 jedit "$settings" "d['hooks']['Stop'].append({'hooks':[{'type':'command','command':'late-foreign'}]})"
 doctor=$("$P/bin/kit-doctor" 2>&1); case "$doctor" in *'out of date'*) exit 1;; esac
 jedit "$settings" "
for g in d['hooks']['Stop']:
 for h in g['hooks']:
  if 'kit-hook' in h['command']: h['command']+=' changed'"
 doctor=$("$P/bin/kit-doctor" 2>&1)
 case "$doctor" in *'routing kit: hooks out of date for claude'*) exit 0;; *) exit 1;; esac
) >/dev/null 2>&1
result 'doctor: no false drift after a foreign addition; drift on a changed kit hook' "$?"
# 10: the shipped plugin hooks.json is static and equals what the kit generates for Claude.
env -u KIT_HOOK_REGISTRY python3 - "$ROOT" <<'PYTEST'
import sys,json
from pathlib import Path
root=Path(sys.argv[1])/'plugins/routing-kit'
sys.path.insert(0,str(root/'lib'))
import sync_hooks
shipped=json.loads((root/'hooks/hooks.json').read_text())
want=sync_hooks.hook_entries(root,'claude')
assert sync_hooks.projection(shipped,'claude',set(sync_hooks.commands_of(want))) == want
PYTEST
result 'shipped hooks.json equals the generated plugin entries' "$?"
# 11: foreign handlers (look-alikes of kit and owner names) survive sync in every file; kit entries appear once.
FOREIGN_CMDS='/vendor/kit-hook-audit|printf continuation-judge|/vendor/other-tool --x|/vendor/guard-destructive.sh|printf "kit-hook audit"'
for agent in settings codex agy; do
 mode=plugin; [ "$agent" = settings ] && mode=settings
 setup "$mode"; target=$(target_of "$agent")
 kit_python3 - "$target" "$agent" "$FOREIGN_CMDS" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text()); cmds=sys.argv[3].split('|')
if sys.argv[2]=='agy':
 d['routing-kit']={'Stop':[{'type':'command','command':c} for c in cmds],'PreToolUse':[{'matcher':'x','hooks':[{'type':'command','command':cmds[0]}]}]}
else:
 d['hooks']['Stop'].append({'hooks':[{'type':'command','command':c} for c in cmds]})
 d['hooks']['SessionStart']=[{'hooks':[{'type':'command','command':cmds[0]},{'type':'command','command':'echo kept'}]}]
p.write_text(json.dumps(d))
PY
 (run && cmds=$(jcmds "$target") && IFS='|' && for c in $FOREIGN_CMDS; do printf '%s\n' "$cmds" | grep -qxF -- "$c" || exit 1; done && unset IFS && [ "$(printf '%s\n' "$cmds" | grep -c 'kit-hook [a-z]* Stop')" -eq 1 ]) >/dev/null 2>&1
 result "$agent sync keeps foreign handlers (look-alike names)" "$?"
done
# 12: Antigravity SessionStart / PreInvocation / Stop are flat handlers; PreToolUse keeps the matcher group.
setup plugin
(run && kit_python3 - "$agy" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())['routing-kit']
for e in ('SessionStart','PreInvocation','Stop'):
 kit=[x for x in d[e] if 'kit-hook ' in x.get('command','')]
 assert len(kit)==1 and 'hooks' not in kit[0] and kit[0]['type']=='command',(e,d[e])
assert not any('kit-hook ' in x.get('command','') for e in ('SessionStart','PreInvocation','Stop') for x in d[e] if 'hooks' in x)
g=[x for x in d['PreToolUse'] if 'hooks' in x]
assert len(g)==1 and 'matcher' in g[0]
PY
) >/dev/null 2>&1
result 'agy: flat handlers for SessionStart/PreInvocation/Stop, group for PreToolUse' "$?"
# 13: a group-shaped entry with exactly the kit's own command (old agy shape) is replaced by the flat handler; foreign kept.
setup plugin
jedit "$agy" "d['routing-kit']={'Stop':[{'hooks':[{'type':'command','command':'$P/hooks/kit-hook agy Stop','timeout':5}]},{'type':'command','command':'mine'}]}"
(run && kit_python3 - "$agy" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())['routing-kit']
assert [x for x in d['Stop'] if 'hooks' in x]==[],d['Stop']
assert len(d['Stop'])==2 and 'kit-hook ' in d['Stop'][0]['command'] and d['Stop'][1]=={'type':'command','command':'mine'},d['Stop']
PY
) >/dev/null 2>&1
result 'agy: old group-shaped kit entry (exact command) becomes flat, foreign kept' "$?"
# 14: the agy matcher matches the real tool names seen in the recorded payloads, and the documented ones.
setup plugin
(run && kit_python3 - "$agy" <<'PY'
import json,pathlib,re,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())['routing-kit']
m=[g['matcher'] for g in d['PreToolUse'] if 'matcher' in g and 'kit-hook ' in json.dumps(g)][0]
for name in ('run_command','write_file','edit_file','write_to_file','replace_file_content','multi_replace_file_content'):
 assert re.fullmatch(m,name),name
for name in ('read_file','view_file'):
 assert not re.fullmatch(m,name),name
PY
) >/dev/null 2>&1
result 'agy matcher covers write_file and edit_file plus the documented names' "$?"
# 15: sync, a foreign addition, sync again, undo: the addition survives, kit entries are gone.
for agent in settings codex agy; do
 mode=plugin; [ "$agent" = settings ] && mode=settings
 setup "$mode"; target=$(target_of "$agent")
 cp "$target" "$s/original"
 (run \
  && if [ "$agent" = agy ]; then jedit "$target" "d['routing-kit']['Stop'].append({'type':'command','command':'new-foreign-stop'}); d['other']={'Stop':[{'type':'command','command':'second-foreign'}]}"; else jedit "$target" "d['hooks']['Stop'].append({'hooks':[{'type':'command','command':'new-foreign-stop'}]}); d['hooks']['Notification']=[{'hooks':[{'type':'command','command':'new-event'}]}]"; fi \
  && run && run --undo \
  && kit_python3 - "$target" "$s/original" "$agent" <<'PY'
import json,pathlib,sys
now=json.loads(pathlib.Path(sys.argv[1]).read_text()); want=json.loads(pathlib.Path(sys.argv[2]).read_text())
if sys.argv[3]=='agy':
 want.setdefault('routing-kit',{}).setdefault('Stop',[]).append({'type':'command','command':'new-foreign-stop'})
 want['other']={'Stop':[{'type':'command','command':'second-foreign'}]}
else:
 want['hooks']['Stop'].append({'hooks':[{'type':'command','command':'new-foreign-stop'}]})
 want['hooks']['Notification']=[{'hooks':[{'type':'command','command':'new-event'}]}]
assert 'kit-hook ' not in json.dumps(now),now
assert now==want,(now,want)
PY
 ) >/dev/null 2>&1
 result "$agent resync then undo keeps later foreign additions" "$?"
done
# 16: undo after a hand edit of a foreign entry leaves the edit alone; the kit is gone.
setup settings
(run && jedit "$settings" "d['hooks']['PreToolUse'][0]['matcher']='Read|Glob'" && run --undo && kit_python3 - "$settings" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert d['hooks']['PreToolUse'][0]=={'matcher':'Read|Glob','hooks':[{'type':'command','command':'foreign-read'}]},d
assert 'kit-hook ' not in json.dumps(d)
PY
) >/dev/null 2>&1
result 'undo after hand edit: foreign edit kept, kit gone' "$?"
# 17: a file the kit created is removed by undo when nothing foreign is in it.
setup plugin
rm "$codexf" "$agy"
(run && [ -f "$codexf" ] && [ -f "$agy" ] && run --undo && [ ! -f "$codexf" ] && [ ! -f "$agy" ]) >/dev/null 2>&1
result 'undo removes a file the kit created when nothing foreign is in it' "$?"
# 18: a resync leaves foreign entries where they are (a foreign entry after the kit's stays after it).
setup settings
(run && jedit "$settings" "d['hooks']['Stop'].append({'hooks':[{'type':'command','command':'late-foreign'}]})" && run && kit_python3 - "$settings" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())
c=[g['hooks'][0]['command'] for g in d['hooks']['Stop']]
assert c[0]=='foreign-stop' and c[1]=='/old/prep-for-exit-trigger.sh' and 'kit-hook ' in c[2] and c[3]=='late-foreign' and len(c)==4,c
PY
) >/dev/null 2>&1
result 'resync keeps foreign order around the kit entry' "$?"
# 19: a moved kit root. Commands recorded at the last write are the kit's; the same text never recorded is foreign.
setup plugin
(run && jedit "$codexf" "
import re
old='/old/root/hooks/kit-hook'
for g in d['hooks']['Stop']:
 for h in g['hooks']:
  if 'kit-hook ' in h['command']: h['command']=h['command'].replace('$P/hooks/kit-hook', old)
d['hooks']['SessionStart'].append({'hooks':[{'type':'command','command':'/never/recorded/hooks/kit-hook codex Stop'}]})
" && jedit "$ROUTING_KIT_HOME/sync-state.json" "
for rec in d['hooks'].values():
 rec['commands']=[c.replace('$P/hooks/kit-hook','/old/root/hooks/kit-hook') for c in rec['commands']]
" && run && cmds=$(jcmds "$codexf") && ! printf '%s\n' "$cmds" | grep -q '/old/root/' && [ "$(printf '%s\n' "$cmds" | grep -c "$P/hooks/kit-hook codex Stop")" -eq 1 ] && printf '%s\n' "$cmds" | grep -qxF '/never/recorded/hooks/kit-hook codex Stop' && run --undo && ! jcmds "$codexf" | grep -q "$P/hooks/kit-hook") >/dev/null 2>&1
result 'moved kit root: recorded commands cleaned up, unrecorded look-alike kept' "$?"
# 20: state written by the earlier version (backups, trust list) is dropped without touching anything else.
setup plugin
printf '{"hooks_undo":{},"hook_trust":["x"],"files":{"a":1}}\n' > "$ROUTING_KIT_HOME/sync-state.json"
(run && kit_python3 - "$ROUTING_KIT_HOME/sync-state.json" <<'PY'
import json,pathlib,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert 'hooks_undo' not in d and 'hook_trust' not in d and d['files']=={'a':1} and 'hooks' in d
PY
) >/dev/null 2>&1
result 'old backup/trust state dropped, other state kept' "$?"
# 21: fractional timeouts from the dispatcher round up to whole seconds.
setup plugin
printf '{"Stop":[{"name":"x","command":"true","timeout_s":0.2}]}\n' > "$s/frac.json"
(export KIT_HOOK_REGISTRY="$s/frac.json"; run && kit_python3 - "$agy" "$codexf" <<'PY'
import json,pathlib,sys
for f in sys.argv[1:]:
 d=json.loads(pathlib.Path(f).read_text()); d=d.get('routing-kit',d.get('hooks'))
 for g in d['Stop']:
  for h in (g.get('hooks',[g])):
   if 'kit-hook ' in h['command']: assert h['timeout']==6 and isinstance(h['timeout'],int),(f,h)
PY
) >/dev/null 2>&1
result 'fractional timeout rounds up to an integer' "$?"
# 22: an existing empty, garbage or duplicate-key file is refused, with nothing else written (sync and undo).
for agent in settings codex agy; do
 for bad in empty garbage dupkey; do
  mode=plugin; [ "$agent" = settings ] && mode=settings
  setup "$mode"; target=$(target_of "$agent")
  case "$bad" in empty) : > "$target";; garbage) printf '{oops' > "$target";; dupkey) printf '{"hooks":{},"hooks":{},"routing-kit":{}}' > "$target";; esac
  cp "$settings" "$s/a"; cp "$agy" "$s/c"; cp "$codexf" "$s/d"
  (! run && cmp -s "$settings" "$s/a" && cmp -s "$agy" "$s/c" && cmp -s "$codexf" "$s/d" && [ ! -e "$ROUTING_KIT_HOME/sync-state.json" ] && ! run --undo && cmp -s "$settings" "$s/a" && cmp -s "$agy" "$s/c" && cmp -s "$codexf" "$s/d") >/dev/null 2>&1
  result "$agent $bad existing file is refused, nothing written" "$?"
 done
done
# 23: the property test: random sequences of sync / add-foreign / resync / move-root / undo over files full of
# foreign look-alikes; foreign objects stay identical and in order, no generated command survives undo.
prop=$(kit_python3 "$ROOT/tests/test_sync_hooks_property.py" 2>&1); code=$?
[ "$code" -eq 0 ] && case "$prop" in 'property runs: 400'*) true;; *) false;; esac
result "property test: $prop" "$?"
cmd=$(kit_python3 -c 'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); import sync_hooks; print(sync_hooks.command_for(Path(sys.argv[2]), "codex", False, "SessionStart"))' "$P/lib" "$P")
case "$cmd" in *'/hooks/kit-hook codex SessionStart') result 'Codex SessionStart names its reader' 0;; *) result 'Codex SessionStart names its reader' 1;; esac
# R2: every agent's generated entries include the kit's session-start command (and the kit-hook SessionStart one).
kit_python3 - "$P" <<'R2PY' >/dev/null 2>&1
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'lib'))
import sync_hooks as s
for agent in ('claude','codex','agy'):
 root=Path(sys.argv[1]); entries=s.hook_entries(root,agent,True)
 expected=str(root/'hooks'/('session-start-agy' if agent=='agy' else 'session-start'))+('' if agent=='agy' else ' '+agent)
 assert expected in s.commands_of(entries)
 assert s.command_for(root,agent,True,'SessionStart') in s.commands_of(entries)
R2PY
result 'every agent registers the kit session-start command next to kit-hook SessionStart' "$?"
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
