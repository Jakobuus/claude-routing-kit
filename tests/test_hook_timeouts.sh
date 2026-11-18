#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/plugins/routing-kit/bin/kit-common"
export PYTHONDONTWRITEBYTECODE=1
kit_python3 - "$ROOT" <<'PY'
import sys, pathlib, tempfile, os, json, subprocess, re
root=pathlib.Path(sys.argv[1])
sys.path.insert(0,str(root/'plugins/routing-kit/lib'))
import hook_adapt as h
registry=json.loads((root/'plugins/routing-kit/hooks/checks/registry.json').read_text())
with tempfile.TemporaryDirectory() as d:
    os.environ['ROUTING_KIT_HOME']=d
    os.environ['KIT_HOOK_CHECKS']=d
    p=pathlib.Path(d)
    (p/'guard_destructive.py').write_text('import time; time.sleep(2.2); print(\'{"action":"deny","reason":"slow"}\')')
    (p/'registry.json').write_text(json.dumps({'PreToolUse':[registry['PreToolUse'][0]]}))
    env=dict(os.environ,KIT_HOOK_REGISTRY=str(p/'registry.json'))
    command=[sys.executable,str(root/'plugins/routing-kit/lib/hook_adapt.py'),'dispatch','claude','PreToolUse']
    payload=json.dumps({'hook_event_name':'PreToolUse'})
    out=subprocess.run(command,input=payload,text=True,capture_output=True,env=env)
    assert 'slow' in out.stdout, out
    assert 2 < registry['PreToolUse'][1]['timeout_s'] <= 10
    (p/'guard_owner_checkout.py').write_text((p/'guard_destructive.py').read_text())
    (p/'registry.json').write_text(json.dumps({'PreToolUse':[registry['PreToolUse'][1]]}))
    out=subprocess.run(command,input=payload,text=True,capture_output=True,env=env)
    assert 'slow' in out.stdout, out
    (p/'registry.json').write_text(json.dumps({'PreToolUse':[{'path':'finish.py','timeout':2}]}))
    subprocess.run(command,input=payload,text=True,capture_output=True,env=env,check=True)
    log=(p/'hook-errors.log').read_text()
    assert 'expected check and timeout_s' in log,log
    assert re.match(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ ',log),log
    import media_match
    (p/'private').mkdir()
    (p/'private/media.json').write_text('{}')
    media_match.private_jobs(p)
    assert re.match(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ ',(p/'hook-errors.log').read_text().splitlines()[-1])
print('PASS 5 / FAIL 0')
PY
