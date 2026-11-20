#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
export HOME="$(mktmp)" CODEX_HOME="$(mktmp)" ROUTING_KIT_HOME="$(mktmp)"
test_python=$(command -v python3)
test_jq=$(command -v jq)
base=$(mktmp)
export DOCTOR_TEST_BIN="$base/bin"
mkdir -p "$DOCTOR_TEST_BIN"
# Keep system tools, never the user's agent commands.
export PATH="$DOCTOR_TEST_BIN:/usr/bin:/bin"
ln -s "$test_python" "$DOCTOR_TEST_BIN/python3"
ln -s "$test_jq" "$DOCTOR_TEST_BIN/jq"
python3 - "$PWD" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, time
root=pathlib.Path(sys.argv[1]); kit=pathlib.Path(os.environ['ROUTING_KIT_HOME']); home=pathlib.Path(os.environ['HOME']); codex=pathlib.Path(os.environ['CODEX_HOME']); bins=pathlib.Path(os.environ['DOCTOR_TEST_BIN'])
sys.path.insert(0,str(root/'plugins/routing-kit/lib'))
import codex_trust
passed=failed=0

def check(ok, name):
    global passed,failed
    if ok: passed+=1
    else: failed+=1; print('FAIL: '+name)

def write(path,data):
    path.parent.mkdir(parents=True,exist_ok=True); path.write_text(json.dumps(data))
profile={'version':1,'main_agent':'claude','claude_plan':'pro','codex':'plus','gemini':'pro','jules':True,'paseo':True,'codex_build_transport':'paseo'}
script='''#!/bin/bash
name=${0##*/}
[ "${HANG:-}" != "$name" ] || { sleep 30; exit; }
[ "$1" != --version ] || { echo "$name 1.2.3"; exit; }
case "$name:$1" in
claude:auth) [ "${BAD_AUTH:-}" = claude ] && echo '{"loggedIn":false}' || echo '{"loggedIn":true}' ;;
codex:login) [ "${BAD_AUTH:-}" != codex ] || exit 1; echo 'Logged in using ChatGPT' ;;
agy:models) [ "${BAD_AUTH:-}" != gemini ] || exit 1; echo 'gemini-4-argon-high Model' ;;
paseo:status) [ "${BAD_STATUS:-}" != yes ] || exit 1; echo '{"localDaemon":"'"${DAEMON:-running}"'","providers":[{"provider":"claude","available":true},{"provider":"codex","available":true},{"provider":"gemini","available":true}]}' ;;
paseo:plugin) echo 'PLUGIN STATUS ENABLED SOURCE DIRECTORY'; echo "${PILL_NAME:-routing-kit-pill} ${PILL:-running} yes local ${PILL_PATH:-/plugins/paseo-pill}" ;;
esac
'''
for name in ('claude','codex','agy','jules','paseo'):
    p=bins/name; p.write_text(script); p.chmod(0o755)
rules=home/'rules.md'; rules.write_text('<!-- routing-kit:rules:start -->\nManaged\n<!-- routing-kit:rules:end -->\n')
target=home/'skill'; target.mkdir(); link=home/'skills/example'; link.parent.mkdir(); link.symlink_to(target)
hooks={'hooks':{'PreToolUse':[{'hooks':[{'type':'command','command':'/kit/kit-hook','timeout':600}]}]}}
write(codex/'hooks.json',hooks)
from sync_hooks import projection
sync={'files':{str(rules):hashlib.sha256(b'Managed\n').hexdigest()},'links':{str(link):{'target':str(target),'skill':'example','agent':'claude'}},'hooks':{str(codex/'hooks.json'):{'agent':'codex','commands':['/kit/kit-hook'],'entries':projection(hooks,'codex',{'/kit/kit-hook'})}}}
write(kit/'sync-state.json',sync)
trust=codex_trust.entries_for(str(codex/'hooks.json'),hooks,{'/kit/kit-hook'})
(codex/'config.toml').write_text(codex_trust.block(list(trust.items())))
models=json.loads((root/'plugins/routing-kit/rules/models.json').read_text())
def caches():
    write(codex/'models_cache.json',{'models':[{'slug':m} for m in set(models['codex'].values())]})
    p=kit/'cache/agy-models.txt'; p.parent.mkdir(exist_ok=True); p.write_text('\n'.join(set(models['gemini'].values())))
def run(*args, **env):
    e=dict(os.environ); e.update(env)
    command=[str(root/'plugins/routing-kit/bin/kit-doctor'),*args]
    if not (bins/'paseo').exists():
        # Simulate Linux for absence tests: a Mac may have the real desktop app.
        command=[sys.executable, '-c', "import runpy,sys; sys.platform='linux'; path=sys.argv.pop(1); runpy.run_path(path,run_name='__main__')", str(root/'plugins/routing-kit/lib/doctor.py'),*args]
    return subprocess.run(command,capture_output=True,text=True,env=e,timeout=25)
def reset():
    write(kit/'profile.json',profile); caches()
reset()
r=run('--setup'); check(r.returncode==0 and r.stdout.rstrip().endswith('setup: all ok'),'healthy setup exit and summary')
check(all(s.startswith('ok    ') for s in r.stdout.splitlines()[:-1]),'healthy checks all ok')
check('1.2.3' in r.stdout,'versions shown')
for agent,login in [('claude','claude auth login'),('codex','codex login'),('gemini','agy')]:
    r=run('--setup',BAD_AUTH=agent); check(r.returncode==1 and login in r.stdout and sum(s.startswith('fix   ') for s in r.stdout.splitlines())==1,agent+' signed out')
p=dict(profile,gemini='none'); write(kit/'profile.json',p); (bins/'agy').rename(bins/'agy.off')
r=run('--setup'); check('gemini' not in r.stdout and r.returncode==0,'unused Gemini omitted'); (bins/'agy.off').rename(bins/'agy'); reset()
missing=models['codex']['strong']; write(codex/'models_cache.json',{'models':[{'slug':m} for m in set(models['codex'].values()) if m!=missing]})
r=run('--setup'); check(r.returncode==1 and missing in r.stdout,'missing routed model named'); reset()
(codex/'models_cache.json').unlink(); r=run('--setup'); check(r.returncode==0 and 'models codex: list not known yet' in r.stdout,'unknown models ok'); reset()
(bins/'paseo').rename(bins/'paseo.off'); write(kit/'profile.json',dict(profile,paseo=False,codex_build_transport='direct'))
r=run('--setup'); check(r.returncode==0 and 'recommended: Paseo' in r.stdout,'optional Paseo recommendation')
write(kit/'profile.json',profile); r=run('--setup'); check(r.returncode==1 and 'fix   paseo' in r.stdout,'chosen missing Paseo fails')
r=run('--fast'); check(r.stdout.startswith('routing kit: ') and 'Paseo' in r.stdout and len(r.stdout.splitlines())==1,'fast missing Paseo')
(bins/'paseo.off').rename(bins/'paseo'); reset()
for chosen in (False, True):
    write(kit/'profile.json',dict(profile,paseo=chosen,codex_build_transport='direct'))
    for env in ({'BAD_STATUS':'yes'}, {'DAEMON':'stopped'}, {'PILL':'stopped'}):
        r=run('--setup',**env)
        check(r.returncode==int(chosen), 'Paseo problems required only when chosen: '+str((chosen,env)))
reset()
(bins/'paseo').rename(bins/'paseo.off')
app=home/'Paseo.app'; app.mkdir()
for args in (('--setup',), ('--fast',)):
    r=run(*args,ROUTING_KIT_TEST_PASEO_APP=str(app))
    check('paseo command on PATH' in r.stdout, 'app without CLI needs PATH fix '+str(args))
(bins/'paseo.off').rename(bins/'paseo'); reset()
empty=dict(sync,links={}); write(kit/'sync-state.json',empty)
r=run('--setup'); check(r.returncode==1 and 'fix   skills' in r.stdout,'undone skills need sync')
write(kit/'sync-state.json',sync)
r=run('--setup',DAEMON='stopped'); check(r.returncode==1 and 'paseo daemon' in r.stdout,'stopped daemon fails')
r=run('--setup',PILL_NAME='custom',PILL_PATH='/plugins/limits-pill'); check(r.returncode==0,'pill recognized by directory')
r=run('--setup',PILL='stopped'); check(r.returncode==1 and 'paseo plugin install' in r.stdout,'pill install fix')
write(kit/'profile.json',dict(profile,codex_build_transport='direct')); r=run('--setup'); check(r.returncode==0 and 'recommended:' in r.stdout and 'kit-profile set codex_build_transport paseo' in r.stdout,'direct transport recommendation'); reset()
r=run('--setup','--json'); rows=json.loads(r.stdout); text=run('--setup').stdout.splitlines(); check(len(rows)==len(text)-1 and all(set(x)=={'check','status','message'} for x in rows),'JSON entries match text checks')
start=time.monotonic(); r=run('--setup',HANG='claude'); check(r.returncode==1 and 'did not answer in 10 s' in r.stdout and time.monotonic()-start<22,'bounded hanging command')
(kit/'hook-errors.log').write_text('old failure\n')
r=run('--setup'); check(not (kit/'doctor-state.json').exists(),'setup does not acknowledge or write state')
(kit/'hook-errors.log').unlink()
r=run('--fast'); check(r.returncode==0 and not r.stdout,'clean fast silent')
# Every external executable would sleep; the fast path must not run even one.
for name in ('claude','codex','agy','jules','paseo'):
    (bins/name).write_text('#!/bin/bash\nsleep 5\n')
start=time.monotonic(); r=run('--fast'); check(not r.stdout and time.monotonic()-start<1,'fast sleeping fakes under one second')
(kit/'profile.json').unlink(); r=run('--fast'); check('profile' in r.stdout,'fast missing profile')
write(kit/'profile.json',dict(profile,main_agent='bogus')); r=run('--fast'); check('profile' in r.stdout,'fast invalid profile')
reset(); (kit/'profile.json').write_text('{invalid'); r=run('--fast'); check('profile' in r.stdout,'fast malformed JSON profile')
for name in ('claude','codex','agy','jules','paseo'):
    (bins/name).write_text(script)
legacy=dict(profile); legacy.pop('main_agent'); write(kit/'profile.json',legacy)
r=run('--fast'); check(not r.stdout,'fast accepts legacy implicit Claude main')
write(kit/'profile.json',dict(profile,main_agent=None)); r=run('--setup'); check(r.returncode==1 and 'fix   profile' in r.stdout,'explicit main agent required')
reset(); (bins/'codex').unlink(); r=run('--fast'); check('codex' in r.stdout,'fast missing used agent')
(bins/'codex').write_text('#!/bin/bash\nexit 0\n'); (bins/'codex').chmod(0o755)
for name in ('claude','codex','agy','jules','paseo'):
    (bins/name).write_text(script)
rules.write_text('edited'); r=run('--setup'); check('fix   rules' in r.stdout,'rules drift')
rules.write_text('<!-- routing-kit:rules:start -->\nManaged\n<!-- routing-kit:rules:end -->\n'); link.unlink(); r=run('--setup'); check('fix   skills' in r.stdout,'skills drift'); link.symlink_to(target)
write(codex/'hooks.json',{'hooks':{}}); r=run('--setup'); check('fix   hooks' in r.stdout,'hook drift detected'); write(codex/'hooks.json',hooks)
(kit/'sync-state.json').unlink(); r=run('--setup'); check(all('fix   '+name in r.stdout for name in ('rules','skills','hooks')),'missing sync state needs sync'); write(kit/'sync-state.json',sync)
(codex/'config.toml').write_text(''); r=run('--setup'); check('fix   codex hooks trusted' in r.stdout,'untrusted hooks detected')
# Codex hooks installed but Codex not routed: their trust is still checked (a failed selftest removes it).
write(kit/'profile.json',dict(profile,codex='none')); r=run('--setup'); check('fix   codex hooks trusted' in r.stdout,'untrusted hooks checked without Codex routed')
(codex/'config.toml').write_text(codex_trust.block(list(trust.items()))); r=run('--setup'); check('ok    codex hooks trusted' in r.stdout,'trusted hooks ok without Codex routed'); reset()
# No agent available in Paseo: a recommendation, never an ok line that reads like a problem, never exit 1.
(bins/'paseo').write_text(script.replace('"available":true','"available":false')); (bins/'paseo').chmod(0o755)
r=run('--setup'); check(r.returncode==0 and 'recommended: Paseo lists none of your agents' in r.stdout and 'ok    paseo providers' not in r.stdout,'no Paseo providers is a recommendation')
(bins/'paseo').write_text(script)
print('PASS %d / FAIL %d'%(passed,failed))
sys.exit(bool(failed))
PY
