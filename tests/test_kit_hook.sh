#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
export ROUTING_KIT_HOME="$(mktmp)"
export KIT_HOOK_CHECKS="$ROUTING_KIT_HOME/checks"
export KIT_HOOK_REGISTRY="$ROUTING_KIT_HOME/registry.json"
mkdir -p "$KIT_HOOK_CHECKS"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
checks = pathlib.Path(os.environ['KIT_HOOK_CHECKS'])
registry = pathlib.Path(os.environ['KIT_HOOK_REGISTRY'])
log = pathlib.Path(os.environ['ROUTING_KIT_HOME']) / 'hook-errors.log'
hook = root / 'plugins/routing-kit/hooks/kit-hook'
def setup(entries):
    registry.write_text(json.dumps(entries))
def run(agent='claude', event='PreToolUse', payload=None, env=None):
    if payload is None:
        name = 'run_command' if agent == 'agy' else 'Bash'
        payload = (root / f'tests/fixtures/hooks/{agent}/PreToolUse-{name}.json').read_text()
    result = subprocess.run([str(hook), agent, event], input=payload, text=True, capture_output=True, env=env)
    assert result.returncode == 0, result
    return json.loads(result.stdout) if result.stdout else None
def check(name, code):
    (checks / (name + '.py')).write_text(code)
check('crash', 'raise RuntimeError("crashed")')
setup({'PreToolUse': [{'check':'crash'}]})
assert run() is None and 'crash' in log.read_text()
check('slow', 'import time; time.sleep(3)')
setup({'PreToolUse': [{'check':'slow', 'timeout_s':1}]})
start = time.monotonic()
assert run() is None
assert time.monotonic() - start < 2.5 and 'slow' in log.read_text()
check('one', 'print(\'{"action":"context","text":"one"}\')')
check('two', 'print(\'{"action":"context","text":"two"}\')')
check('deny', 'print(\'{"action":"deny","reason":"blocked"}\')')
check('last', 'raise RuntimeError("must not run")')
setup({'PreToolUse':[{'check':n} for n in ('one','deny','last')]})
assert run()['hookSpecificOutput']['permissionDecisionReason'] == 'blocked'
assert 'must not run' not in log.read_text()
setup({'UserPromptSubmit':[{'check':n} for n in ('one','two')]})
payload = (root / 'tests/fixtures/hooks/claude/UserPromptSubmit-n.json').read_text()
assert run(event='UserPromptSubmit', payload=payload)['hookSpecificOutput']['additionalContext'] == 'one\n\ntwo'
check('continue', 'print(\'{"action":"continue","reason":"more"}\')')
setup({'Stop':[{'check':n} for n in ('continue','one')]})
payload = (root / 'tests/fixtures/hooks/claude/Stop-n.json').read_text()
assert run(event='Stop', payload=payload) == {'decision':'block','reason':'more'}
setup({})
assert run('agy') == {'decision':'allow'}
before = len(log.read_text().splitlines())
assert run('agy', payload='{broken') == {'decision':'allow'}
assert len(log.read_text().splitlines()) == before + 1
# Invalid bytes on a check's stderr must not discard its deny.
check('badbytes', 'import sys; sys.stderr.buffer.write(b"\\xff\\xfe"); print(\'{"action":"deny","reason":"blocked"}\')')
setup({'PreToolUse': [{'check':'badbytes'}]})
assert run('agy') == {'decision':'deny','reason':'blocked'}
# No python3: fail open, one log line each, and agy PreToolUse still gets its allow.
setup({})
nopy = dict(os.environ, KIT_TEST_NO_PYTHON3='1')
before = len(log.read_text().splitlines())
assert run('agy', env=nopy) == {'decision':'allow'}
assert run('claude', env=nopy) is None
assert len(log.read_text().splitlines()) == before + 2
# A timed-out check's children die with it.
marker = pathlib.Path(os.environ['ROUTING_KIT_HOME']) / 'child-marker'
check('spawner', 'import subprocess, sys, time\n'
      'subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.8); open(%r, \'w\').write(\'x\')"])\n'
      'time.sleep(3)' % str(marker))
setup({'PreToolUse': [{'check':'spawner', 'timeout_s':0.2}]})
assert run() is None
time.sleep(1.5)
assert not marker.exists()
setup({'Stop':[{'check':'slow','timeout_s':60}]})
assert subprocess.check_output([str(hook),'--max-timeout','Stop'], text=True).strip() == '65'
print('kit_hook: 8 passed, 0 failed')
PY
