"""Synthetic assertions through the installed hook dispatcher; never run fixture commands."""
from concurrent.futures import ThreadPoolExecutor
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    fixtures = root.parents[1] / 'tests/fixtures/hooks'
    passed = failed = 0
    with tempfile.TemporaryDirectory(prefix='kit-selftest-hooks-') as directory:
        scratch = Path(directory)
        judge = scratch / 'judge'
        judge.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"decision":"block","reason":"keep going"}\'\n')
        judge.chmod(0o700)
        (scratch / 'profile.json').write_text(json.dumps(dict(
            version=1, blocks=True, owner_checkouts=[str(scratch / 'owner')],
            protected_paths=[], continuation_judge=str(judge))))
        env = dict(os.environ, ROUTING_KIT_HOME=directory, PYTHONDONTWRITEBYTECODE='1')

        def load(agent, name):
            return json.loads((fixtures / agent / (name + '.json')).read_text())

        # The exit-prep trigger fires only when a prep-for-exit skill is installed (the kit ships none):
        # one home with the skill in every agent's folder, one without any.
        skill_home, bare_home = scratch / 'home-skill', scratch / 'home-bare'
        for sub in ('.claude', '.agents', '.gemini', '.codex'):
            (skill_home / sub / 'skills' / 'prep-for-exit').mkdir(parents=True, exist_ok=True)
            (skill_home / sub / 'skills' / 'prep-for-exit' / 'SKILL.md').write_text('---\nname: prep-for-exit\n---\n')
        bare_home.mkdir(exist_ok=True)

        def homed(home):
            e = {k: v for k, v in env.items() if k not in ('CLAUDE_CONFIG_DIR',)}
            return dict(e, HOME=str(home), CODEX_HOME=str(home / '.codex'))

        def run(agent, payload, latte='0', run_env=None):
            event = payload.get('hookEventName', payload.get('hook_event_name'))
            result = subprocess.run([str(root / 'hooks/kit-hook'), agent, event],
                                    input=json.dumps(payload), text=True, capture_output=True,
                                    env=dict(run_env or env, DOUBLE_SHOT_LATTE=latte), cwd=directory, timeout=10)
            if result.returncode:
                raise ValueError('hook failed')
            return json.loads(result.stdout) if result.stdout.strip() else {}

        def check(agent, name, probe):
            nonlocal passed, failed
            try:
                good = probe()
            except (OSError, ValueError, subprocess.TimeoutExpired):
                good = False
            passed += bool(good)
            failed += not good
            print(('ok' if good else 'FAIL') + ' ' + agent + ' ' + name)

        def test_agent(agent):
            agy = agent == 'agy'
            shell = load(agent, 'PreToolUse-' + ('run_command' if agy else 'Bash'))
            for name, command, deny in (
                ('rm_rf_home', 'rm -rf ~', True),
                ('force_push', 'git push --force origin main', True),
                ('claude_no_model', 'claude -p "x"', True),
                ('claude_bad_model', 'claude -p --model claude-fable-5-2', True),
                ('ls', 'ls', False), ('codex_exec', 'codex exec -m gpt-6.1-sol -c model_reasoning_effort=high "x"', False)):
                payload = copy.deepcopy(shell)
                params = payload['toolCall']['args'] if agy else payload['tool_input']
                params['CommandLine' if agy else 'command'] = command
                def probe():
                    out = run(agent, payload)
                    return (out.get('decision') == 'deny' or out.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny') == deny
                check(agent, name, probe)
            for name, path, deny in (('owner_checkout', scratch / 'owner/file', True),
                                     ('normal_write', scratch / 'normal/file', False)):
                payload = load(agent, 'PreToolUse-' + ('write_file' if agy else 'apply_patch-add' if agent == 'codex' else 'Write'))
                params = payload['toolCall']['args'] if agy else payload['tool_input']
                if agent == 'codex':
                    params['command'] = params['command'].replace('notes.txt', str(path))
                else:
                    params['Path' if agy else 'file_path'] = str(path)
                check(agent, name, probe)
            payload = load(agent, 'PreInvocation-n' if agy else 'UserPromptSubmit-n')
            payload['lastUserInput' if agy else 'prompt'] = 'prep for exit'
            check(agent, 'prep_for_exit', lambda: 'SESSION-END TRIGGER' in json.dumps(run(agent, payload, run_env=homed(skill_home))))
            check(agent, 'prep_for_exit_needs_skill', lambda: 'SESSION-END TRIGGER' not in json.dumps(run(agent, payload, run_env=homed(bare_home))))
            if agy:
                payload = load(agent, 'PreInvocation-later')
                payload['lastUserInput'] = 'prep for exit'
                check(agent, 'prep_for_exit_once_per_turn', lambda: 'SESSION-END TRIGGER' not in json.dumps(run(agent, payload, run_env=homed(skill_home))))
            # Every handler sync_hooks generates must run here once: the kit-hook events not covered above, and the
            # standalone session-start command (exit 0, something on stdout).
            for event, fixture in (('SessionStart', 'SessionStart-n'), ('PostToolUse', 'PostToolUse-' + ('run_command' if agy else 'Bash'))):
                payload = load(agent, fixture)
                check(agent, 'kit_hook_' + event, lambda: isinstance(run(agent, payload), dict))
            start = [str(root / 'hooks' / ('session-start-agy' if agy else 'session-start'))] + ([] if agy else [agent])

            def session_start():
                result = subprocess.run(start, input=json.dumps(load(agent, 'SessionStart-n')), text=True, capture_output=True,
                                        env=env, cwd=directory, timeout=20)
                return result.returncode == 0 and bool(result.stdout.strip())
            check(agent, 'session_start_command', session_start)
            payload = load(agent, 'Stop-n')
            for name, latte in (('stop_without_latte', '0'), ('stop_with_latte', '1')):
                check(agent, name, lambda: (run(agent, payload, latte).get('decision') == ('continue' if agy else 'block')) == (latte == '1'))
        with ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(test_agent, ('claude', 'codex', 'agy')))
    print(f'hooks selftest: {passed} ok, {failed} failed')
    return int(bool(failed))


if __name__ == '__main__':
    raise SystemExit(main())
