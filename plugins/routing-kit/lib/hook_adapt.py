"""Normalize hook payloads and dispatch isolated checks."""
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


def inbound(data, agent):
    agy = agent == 'agy'
    event = data.get('hookEventName' if agy else 'hook_event_name', 'unknown')
    params = data.get('toolCall', {}).get('args', {}) if agy else data.get('tool_input', {})
    name = data.get('toolCall', {}).get('name', '') if agy else data.get('tool_name', '')
    kind, paths = 'other', []
    if name in ('Bash', 'exec_command', 'run_command'):
        kind = 'shell'
    elif name == 'Agent':
        kind = 'agent'
    elif name in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'apply_patch', 'write_file',
                  'edit_file', 'write_to_file', 'replace_file_content', 'multi_replace_file_content'):
        kind = 'write'
        if name == 'apply_patch':
            header = re.compile(r'\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)')
            paths = [m.group(1) for m in map(header.fullmatch, (l[:-1] if l.endswith('\r') else l for l in params.get('command', '').split('\n'))) if m]
        else:
            paths = [params.get('Path', params.get('TargetFile', params.get('file_path', params.get('notebook_path', ''))))]
        paths = [os.path.normpath(os.path.join(data.get('cwd', ''), p)) for p in paths if p]
    prompt = data.get('lastUserInput' if agy else 'prompt', '')
    first = (event == 'PreInvocation' and data.get('invocationNum') == 0) if agy else (
        event == 'UserPromptSubmit' and not prompt.lstrip().startswith('<task-notification>'))
    return dict(agent=agent, event=event, session_id=data.get('conversationId' if agy else 'session_id', ''),
                cwd=data.get('cwd', ''), prompt=prompt, first_in_turn=first,
                transcript_path=data.get('transcriptPath' if agy else 'transcript_path', ''),
                # Claude marks a subagent's tool calls with agent_id (the session_id stays the lead's).
                subagent=not agy and bool(data.get('agent_id')),
                stop_hook_active=data.get('continuationActive' if agy else 'stop_hook_active', False),
                tool=dict(kind=kind, name=name, command=params.get('CommandLine' if agy else 'command', ''),
                          paths=paths, params=params))


def outbound(d, agent, event):
    action, reason = d.get('action', 'allow'), d.get('reason', '')
    if action == 'deny' and event == 'PreToolUse':
        return dict(decision='deny', reason=reason) if agent == 'agy' else {
            'hookSpecificOutput': dict(hookEventName=event, permissionDecision='deny', permissionDecisionReason=reason)}
    if action == 'continue' and event == 'Stop':
        return dict(decision='continue' if agent == 'agy' else 'block', reason=reason)
    if action == 'context':
        if agent == 'agy' and event in ('SessionStart', 'PreInvocation'):
            return {'injectSteps': [{'systemMessage': {'systemMessage': d.get('text', '')}}]}
        if agent != 'agy' and event in ('SessionStart', 'UserPromptSubmit', 'PostToolUse'):
            return {'hookSpecificOutput': dict(hookEventName=event, additionalContext=d.get('text', ''))}
    if agent == 'agy' and event == 'PreToolUse':
        return {'decision': 'allow'}


def log(error):
    try:
        home = Path(os.environ.get('ROUTING_KIT_HOME', str(Path.home() / '.config/routing-kit')))
        home.mkdir(parents=True, exist_ok=True)
        with (home / 'hook-errors.log').open('a') as f:
            f.write(str(error).replace('\n', ' ') + '\n')
    except OSError:
        pass


def timeout(entry):
    value = float(entry.get('timeout_s', 2))
    if not math.isfinite(value) or value <= 0:
        raise ValueError('invalid check timeout')
    return value


def run_check(command, payload, limit):
    """Run a check in its own process group; on timeout kill the whole group."""
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    try:
        out, err = proc.communicate(payload, timeout=limit)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        raise
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    if proc.returncode:
        raise subprocess.CalledProcessError(proc.returncode, command, out, err)
    return out


def dispatch(agent, event):
    base = Path(__file__).resolve().parent.parent / 'hooks/checks'
    registry = json.loads(Path(os.environ.get('KIT_HOOK_REGISTRY', str(base / 'registry.json'))).read_text())
    if agent == '--max-timeout':
        # Checks run one after another, so the agent's own hook timeout must cover their sum.
        print(format(sum(timeout(e) for e in registry.get(event, [])) + 5, 'g'))
        return
    common = inbound(json.load(sys.stdin), agent)
    if common['event'] == 'unknown':
        raise ValueError('unknown hook event')
    contexts, continuation = [], None
    decision = {'action': 'allow'}
    for entry in registry.get(common['event'], []):
        try:
            name = entry['check']
            if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
                raise ValueError('invalid check name')
            script = str(Path(os.environ.get('KIT_HOOK_CHECKS', str(base))) / (name + '.py'))
            command = [sys.executable, '-I', script]
            if not Path(script).exists() and Path(script).with_suffix('.sh').is_file():
                command = ['bash', str(Path(script).with_suffix('.sh'))]
            stdout = run_check(command, json.dumps(common).encode(), timeout(entry)).decode()
            d = json.loads(stdout) if stdout.strip() else {'action': 'allow'}
            if not isinstance(d, dict) or d.get('action') not in ('allow', 'deny', 'context', 'continue'):
                raise ValueError('invalid decision')
            if any(not isinstance(d.get(k, ''), str) for k in ('reason', 'text')):
                raise ValueError('invalid decision text')
            if d['action'] == 'deny':
                decision = d
                break
            if d['action'] == 'context':
                contexts.append(d.get('text', ''))
            if d['action'] == 'continue' and common['event'] == 'Stop':
                continuation = d
        except Exception as error:
            log('check ' + str(entry) + ': ' + str(error))
    else:
        decision = continuation or ({'action': 'context', 'text': '\n\n'.join(contexts)} if contexts else decision)
    emit(outbound(decision, agent, event))


def emit(value):
    if value is not None:
        print(json.dumps(value))


if __name__ == '__main__':
    mode, agent = sys.argv[1:3]
    event = sys.argv[3] if len(sys.argv) > 3 else 'unknown'
    try:
        if mode == 'dispatch':
            dispatch(agent, event)
        elif mode == 'in':
            emit(inbound(json.load(sys.stdin), agent))
        else:
            emit(outbound(json.load(sys.stdin), agent, event))
    except Exception as error:
        if mode == 'dispatch':
            log(error)
            emit(outbound({'action': 'allow'}, agent, event))
        else:
            emit({'agent': agent, 'event': 'unknown'})
