#!/bin/bash
# Recorded inputs are authoritative; derived variants change only named fields.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
. "$ROOT/plugins/routing-kit/bin/kit-common"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$ROOT" <<'PYTEST'
import copy, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
fixtures = root / 'plugins/routing-kit/hooks/fixtures'
passed = failed = 0

def check(label, agent, payload, expected, event=None):
    global passed, failed
    command = ['bash', '-c', '. "$1/plugins/routing-kit/bin/kit-common"; shift; kit_python3 "$@"',
               'hook-test', str(root), str(root / 'plugins/routing-kit/lib/hook_adapt.py'),
               'out' if event else 'in', agent]
    if event:
        command.append(event)
    result = subprocess.run(command, input=payload, text=True, capture_output=True)
    try:
        actual = json.loads(result.stdout) if expected is not None else result.stdout
        ok = result.returncode == 0 and actual == (expected if expected is not None else '')
    except ValueError:
        ok = False
    if ok:
        passed += 1
    else:
        failed += 1
        print('FAIL: ' + label + ' (exit ' + str(result.returncode) + ', stdout ' + repr(result.stdout) + ')')

def load(agent, name):
    path = fixtures / agent / (name + '.json')
    subprocess.run(['python3', '-m', 'json.tool', str(path)], stdout=subprocess.DEVNULL, check=True)
    return json.loads(path.read_text())

# Full common shape, including empty values on non-tool events.
def inbound(agent, name, kind='other', paths=(), first=False, mutate=None, subagent=False):
    data = load(agent, name)
    if mutate:
        mutate(data)
    agy = agent == 'agy'
    params = data.get('toolCall', {}).get('args', {}) if agy else data.get('tool_input', {})
    tool = data.get('toolCall', {}).get('name', '') if agy else data.get('tool_name', '')
    expected = dict(agent=agent, event=data.get('hookEventName' if agy else 'hook_event_name'),
                    session_id=data.get('conversationId' if agy else 'session_id'), cwd='/REPO',
                    prompt=data.get('lastUserInput' if agy else 'prompt', ''), first_in_turn=first,
                    transcript_path=data.get('transcriptPath' if agy else 'transcript_path', ''),
                    stop_hook_active=data.get('continuationActive' if agy else 'stop_hook_active', False),
                    subagent=subagent,
                    tool=dict(kind=kind, name=tool, command=params.get('CommandLine' if agy else 'command', ''),
                              paths=list(paths), params=params))
    check(agent + '/' + name + (' variant' if mutate else ''), agent, json.dumps(data), expected)

for agent in ('claude', 'codex', 'agy'):
    inbound(agent, 'PreToolUse-' + ('run_command' if agent == 'agy' else 'Bash'), 'shell')
    inbound(agent, 'Stop-n')
    inbound(agent, 'PreInvocation-n' if agent == 'agy' else 'UserPromptSubmit-n', first=True)
    inbound(agent, {'claude':'PreToolUse-Agent', 'codex':'PreModelRequest-n', 'agy':'PreToolUse-read_file'}[agent],
            'agent' if agent == 'claude' else 'other')
for name in ('Write', 'Edit'):
    inbound('claude', 'PreToolUse-' + name, 'write', ['/REPO/notes.txt'])
for name, paths in [('add', ['/REPO/notes.txt']), ('update', ['/REPO/notes.txt']), ('move', ['/REPO/notes.txt', '/REPO/notes2.txt'])]:
    inbound('codex', 'PreToolUse-apply_patch-' + name, 'write', paths)
def crlf(data):
    data['tool_input']['command'] = data['tool_input']['command'].replace('\n', '\r\n')
for name, paths in [('add', ['/REPO/notes.txt']), ('move', ['/REPO/notes.txt', '/REPO/notes2.txt'])]:
    inbound('codex', 'PreToolUse-apply_patch-' + name, 'write', paths, mutate=crlf)
def unicode_break(data):
    data['tool_input']['command'] = data['tool_input']['command'].replace('Add File: notes.txt', 'Add File: a\u2028b.txt')
inbound('codex', 'PreToolUse-apply_patch-add', 'write', ['/REPO/a\u2028b.txt'], mutate=unicode_break)
for name in ('write_file', 'edit_file'):
    inbound('agy', 'PreToolUse-' + name, 'write', ['/REPO/notes.txt'])
for name in ('write_to_file', 'replace_file_content', 'multi_replace_file_content'):
    def rename(data, name=name):
        data['toolCall']['name'] = name
        args = data['toolCall']['args']
        args['TargetFile'] = args.pop('Path')
    inbound('agy', 'PreToolUse-write_file', 'write', ['/REPO/notes.txt'], mutate=rename)
inbound('agy', 'PreInvocation-later')
# A subagent's call carries agent_id; the adapter marks it so checks can skip it.
inbound('claude', 'PreToolUse-Bash-subagent', 'shell', subagent=True)
inbound('claude', 'PostToolUse-Bash-subagent', 'shell', subagent=True)
inbound('claude', 'PostToolUse-Bash', 'shell')
inbound('claude', 'UserPromptSubmit-task-notification')
for agent in ('claude', 'codex', 'agy'):
    def active(data, agent=agent):
        data['continuationActive' if agent == 'agy' else 'stop_hook_active'] = True
    inbound(agent, 'Stop-n', mutate=active)
    for action, event in [('deny', 'PreToolUse'), ('continue', 'Stop'), ('allow', 'PreToolUse')]:
        expected = None
        if action == 'deny':
            expected = {'decision':'deny', 'reason':'Policy reason'} if agent == 'agy' else {'hookSpecificOutput':{'hookEventName':event, 'permissionDecision':'deny', 'permissionDecisionReason':'Policy reason'}}
        elif action == 'continue':
            expected = {'decision':'continue' if agent == 'agy' else 'block', 'reason':'Policy reason'}
        elif agent == 'agy':
            expected = {'decision':'allow'}
        check(agent + '/' + action, agent, json.dumps(dict(action=action, reason='Policy reason', text='Context text')), expected, event)
    for event in (('SessionStart', 'PreInvocation') if agent == 'agy' else ('SessionStart', 'UserPromptSubmit', 'PostToolUse')):
        expected = {'injectSteps':[{'systemMessage':{'systemMessage':'Context text'}}]} if agent == 'agy' else {'hookSpecificOutput':{'hookEventName':event, 'additionalContext':'Context text'}}
        check(agent + '/context/' + event, agent, json.dumps(dict(action='context', reason='Policy reason', text='Context text')), expected, event)
    check(agent + '/malformed', agent, '{broken', {'agent':agent, 'event':'unknown'})
print(f'hook_adapt: {passed} passed, {failed} failed')
sys.exit(bool(failed))
PYTEST
code=$?
[ "$code" = 0 ] && pass || fail "hook adapter cases"
exit "$code"
