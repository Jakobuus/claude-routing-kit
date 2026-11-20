"""Add the kit's hooks to each agent's hooks file; undo takes exactly those back out.

One rule: the kit removes only handlers whose command string equals one it generated. OWNED is the
commands generated now plus the commands recorded in sync-state.json at the last write (so a moved kit
root still cleans up). No substring, shell-splitting or filename guessing. Everything else is foreign and is
never removed, reordered or rewritten. Undo is an uninstall: it removes owned handlers and prunes only the
containers that removal emptied; it never restores a file.

Codex runs a hooks file's handlers only after they are trusted in $CODEX_HOME/config.toml. Sync marks the kit's
Codex handlers trusted only after `kit-selftest --hooks` (or $KIT_SELFTEST_CMD) exits 0, with whole
`[hooks.state."..."]` tables it writes (lib/codex_trust.py) as one block at the very end of config.toml between two
comment lines it owns. A failed selftest (any error running it counts) and undo remove that block again, but only
when the file still ends with exactly the recorded block; otherwise nothing is removed and the owner is told to
remove it by hand. Nothing else in config.toml is ever touched.
"""
import argparse
import copy
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))

import codex_trust
import sync_rules as shared

# Antigravity registers these three events as flat command handlers; tool events use matcher groups.
AGY_FLAT = {'SessionStart', 'PreInvocation', 'Stop'}
MATCHERS = {'claude': 'Bash|Agent|Write|Edit|MultiEdit|NotebookEdit',
            'codex': 'Bash|apply_patch|exec_command',
            'agy': 'run_command|write_file|edit_file|write_to_file|replace_file_content|multi_replace_file_content'}


def key_of(agent):
    return 'routing-kit' if agent == 'agy' else 'hooks'


def events_of(agent):
    return ['SessionStart', 'PreToolUse', 'PreInvocation', 'Stop'] if agent == 'agy' else ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop']


def command_for(root, agent, settings, event):
    """The exact command string the kit writes for one event."""
    cmd = '${CLAUDE_PLUGIN_ROOT}/hooks/kit-hook' if agent == 'claude' and not settings else str(root/'hooks/kit-hook')
    return cmd+' '+agent+' '+event


def command(h):
    c = h.get('command') if isinstance(h, dict) else None
    return c if isinstance(c, str) else ''


def is_group(item):
    return isinstance(item, dict) and isinstance(item.get('hooks'), list)


def projection(data, agent, owned):
    """The kit's own entries in a hooks file (handlers whose command is in `owned`), in file order,
    in the shape the kit writes them."""
    hooks = data.get(key_of(agent)) if isinstance(data, dict) else None
    out = {}
    for event, items in (hooks.items() if isinstance(hooks, dict) else []):
        found = []
        for item in items if isinstance(items, list) else []:
            if is_group(item):
                kit = [h for h in item['hooks'] if command(h) in owned]
                if kit:
                    found.append(dict(item, hooks=kit))
            elif isinstance(item, dict) and command(item) in owned:
                found.append(item)
        if found:
            out[event] = found
    return out


def max_timeout(root, event):
    """The dispatcher's longest run in whole seconds, rounded up (agents want integers)."""
    raw = subprocess.check_output([str(root/'hooks/kit-hook'), '--max-timeout', event]).decode().strip()
    try:
        value = Decimal(raw)
    except InvalidOperation:
        raise ValueError('kit-hook --max-timeout %s printed %r' % (event, raw))
    if not value.is_finite() or value <= 0:
        raise ValueError('kit-hook --max-timeout %s printed %r' % (event, raw))
    return int(value.to_integral_value(rounding=ROUND_CEILING))


def hook_entries(root, agent, settings=False):
    """The entries the kit writes: dedicated groups (flat handlers for Antigravity's flat events)."""
    hooks = {}
    for event in events_of(agent):
        handler = {'type': 'command', 'command': command_for(root, agent, settings, event), 'timeout': max_timeout(root, event)}
        if agent == 'agy' and event in AGY_FLAT:
            hooks.setdefault(event, []).append(handler)
            continue
        group = {'hooks': [handler]}
        if event == 'PreToolUse':
            group['matcher'] = MATCHERS[agent]
        hooks.setdefault(event, []).append(group)
    if agent == "claude" and not settings:
        return hooks
    start = str(root / "hooks" / ("session-start-agy" if agent == "agy" else "session-start"))
    if agent != "agy":
        start += " " + agent
    handler = {"type": "command", "command": start, "timeout": 10}
    hooks["SessionStart"].append(handler if agent == "agy" else {"hooks": [handler]})
    return hooks


def commands_of(entries):
    return [command(h) for items in entries.values() for item in items for h in (item['hooks'] if is_group(item) else [item])]


def sweep(items, owned):
    """Take the owned handlers out of one event's list. Everything else stays as it was, in order.
    A group keeps its other handlers and its own fields; a group left with none is dropped.
    Returns (kept items, where the first removal sat or None)."""
    out, slot = [], None
    for item in items:
        if is_group(item):
            kept = [h for h in item['hooks'] if command(h) not in owned]
            if len(kept) == len(item['hooks']):
                out.append(item)
                continue
            if slot is None:
                slot = len(out)
            if kept:
                out.append(dict(item, hooks=kept))
        elif isinstance(item, dict) and 'hooks' not in item and command(item) in owned:
            if slot is None:
                slot = len(out)
        else:
            out.append(item)
    return out, slot


def strip_owned(data, agent, owned):
    """A copy of `data` without owned handlers; only containers that removal emptied are pruned."""
    data = copy.deepcopy(data)
    key = key_of(agent)
    hooks = data.get(key)
    if not isinstance(hooks, dict):
        return data
    touched = False
    for event in list(hooks):
        kept, slot = sweep(hooks[event], owned)
        if slot is None:
            continue
        touched = True
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if touched and not hooks:
        del data[key]
    return data


def canon(data, agent):
    """Data with empty event lists and an empty hooks object ignored (sync may add or drop those, nothing else)."""
    key = key_of(agent)
    hooks = data.get(key)
    if isinstance(hooks, dict):
        data = dict(data)
        data[key] = {e: v for e, v in hooks.items() if v}
        if not data[key]:
            del data[key]
    return data


def place(data, agent, owned, fresh):
    """The data with the kit's entries current: owned handlers out, fresh dedicated entries in, each event's
    entries where the first owned one sat (new events last)."""
    data = copy.deepcopy(data)
    fresh = dict(fresh)
    hooks = data.setdefault(key_of(agent), {})
    for event in list(hooks):
        kept, slot = sweep(hooks[event], owned)
        if event in fresh:
            at = len(kept) if slot is None else slot
            kept[at:at] = fresh.pop(event)
        elif slot is not None and not kept:
            del hooks[event]
            continue
        hooks[event] = kept
    hooks.update(fresh)
    return data


class _Dup(ValueError):
    pass


def _no_dups(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            raise _Dup('duplicate key %r' % k)
        seen.add(k)
    return dict(pairs)


def parse(raw, p, agent):
    """The JSON object in a hooks file. A missing file is {}; an empty, broken or ambiguous one is refused."""
    if raw is None:
        return {}
    try:
        data = json.loads(raw, object_pairs_hook=_no_dups)
    except _Dup:
        raise ValueError('duplicate JSON keys, left alone: ' + str(p))
    except ValueError:
        raise ValueError('not valid JSON, left alone: ' + str(p))
    if not isinstance(data, dict):
        raise ValueError('not a JSON object, left alone: ' + str(p))
    key = key_of(agent)
    if key in data and (not isinstance(data[key], dict) or any(not isinstance(v, list) for v in data[key].values())):
        raise ValueError('unexpected hooks layout, left alone: ' + str(p))
    return data


def dumps(data, like):
    """JSON text in the style of the file it replaces (indent, separators, trailing newline); 2 spaces for a new file."""
    indent, newline, seps = 2, True, None
    if like is not None:
        text = like.decode('utf-8', 'replace')
        newline = text.endswith('\n')
        lines = text.strip().split('\n')
        indent = None
        if len(lines) > 1:
            lead = re.match(r'[ \t]*', lines[1]).group()
            indent = lead if lead else 2
        elif not re.search(r'[:,] ', text):
            seps = (',', ':')
    return (json.dumps(data, indent=indent, separators=seps, ensure_ascii=False)+('\n' if newline else '')).encode()


def sync_bytes(raw, p, agent, owned, fresh):
    """The file after sync. Refuses to write if anything but owned handlers would change."""
    data = parse(raw, p, agent)
    new = place(data, agent, owned, fresh)
    if canon(strip_owned(new, agent, owned), agent) != canon(strip_owned(data, agent, owned), agent):
        raise ValueError("would change entries that are not the kit's, left alone: " + str(p))
    return dumps(new, raw)


def undo_bytes(raw, p, agent, owned):
    """The file after undo: owned handlers out, nothing else touched. None means nothing is left."""
    data = parse(raw, p, agent)
    new = strip_owned(data, agent, owned)
    if new == data:
        return raw
    return dumps(new, raw) if new else None


def run_selftest(root):
    """(passed, last output line). Any error running or parsing the command counts as a failure."""
    try:
        cmd = shlex.split(os.environ['KIT_SELFTEST_CMD']) if os.environ.get('KIT_SELFTEST_CMD') else [str(root/'bin/kit-selftest'), '--hooks']
        if not cmd:
            raise ValueError('empty KIT_SELFTEST_CMD')
        run = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return False, ' '.join(str(exc).splitlines())
    lines = run.stdout.decode('utf-8', 'replace').strip().splitlines()
    return run.returncode == 0, (lines[-1] if lines else 'exit %d' % run.returncode)


def recorded_trust(state):
    """The record of the trust block written at the last sync, or None."""
    rec = state.get('codex_trust')
    ok = (isinstance(rec, dict) and isinstance(rec.get('config'), str) and isinstance(rec.get('items'), list)
          and all(isinstance(i, list) and len(i) == 2 and all(isinstance(x, str) for x in i) for i in rec['items']))
    return rec if ok else None


def config_text(p):
    raw = shared.read(p)
    return '' if raw is None else raw.decode('utf-8')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--undo', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--claude-settings', default=str(Path.home()/'.claude/settings.json'))
    ap.add_argument('--agy-hooks', default=str(Path.home()/'.gemini/config/hooks.json'))
    a = ap.parse_args()
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get('ROUTING_KIT_HOME', str(Path.home()/'.config/routing-kit')))
    shared.sync_lock.acquire(home)
    sp = home/'sync-state.json'
    state = json.loads(shared.read(sp) or b'{}')
    profile = json.loads(shared.read(home/'profile.json') or b'{}')
    settings = profile.get('claude_hooks') == 'settings'
    codex = Path(os.environ.get('CODEX_HOME', str(Path.home()/'.codex')))
    # The Claude plugin's own hooks.json ships static; only settings mode writes Claude entries (it only adds them).
    targets = {'codex': codex/'hooks.json', 'agy': Path(a.agy_hooks)}
    if settings:
        targets['claude'] = Path(a.claude_settings)
    recorded = state.get('hooks', {})
    plan, wanted = {}, {}
    above_home = set(Path.home().parents)  # system folders above the home folder may be symlinks
    def check(p):
        if any(q not in above_home and q.is_symlink() for q in [p, *p.parents]):
            raise ValueError('symlink: '+str(p))
    if 'hooks_undo' in state:
        print('old hook backups (*.routing-kit.bak) are left as they are; delete them by hand if you want')
    state.pop('hooks_undo', None)
    state.pop('hook_trust', None)
    if a.undo:
        paths = {str(p): agent for agent, p in targets.items()}
        paths.update({name: rec['agent'] for name, rec in recorded.items()})
        for name, agent in paths.items():
            p = Path(name)
            owned = set(commands_of(hook_entries(root, agent, agent == 'claude')))
            owned.update(recorded.get(name, {}).get('commands', []))
            raw = shared.read(p)
            if raw is not None:
                plan[p] = undo_bytes(raw, p, agent, owned)
        rec = recorded_trust(state)
        if rec and shared.read(Path(rec['config'])) is not None:
            text = config_text(Path(rec['config']))
            new, notes = codex_trust.remove_text(text, rec, bool(rec.get('created')))
            for note in notes:
                print(note)
            if new != text:
                plan[Path(rec['config'])] = None if new is None else new.encode('utf-8')
        state.pop('hooks', None)
        state.pop('codex_trust', None)
    else:
        records = dict(recorded)
        for agent, p in targets.items():
            fresh = hook_entries(root, agent, agent == 'claude')
            now = commands_of(fresh)
            owned = set(now) | set(recorded.get(str(p), {}).get('commands', []))
            new = sync_bytes(shared.read(p), p, agent, owned, fresh)
            plan[p] = new
            records[str(p)] = {'agent': agent, 'entries': projection(parse(new, p, agent), agent, set(now)), 'commands': now}
            if agent == 'codex':
                wanted = codex_trust.entries_for(str(p), parse(new, p, agent), set(now))
        state['hooks'] = records
    plan[sp] = (json.dumps(state, indent=2)+'\n').encode()
    if a.dry_run:
        if not a.undo:
            print('would run the hooks selftest, then trust %d Codex hooks in %s' % (len(wanted), codex/'config.toml'))
        return
    shared.apply_plan({p: d for p, d in plan.items() if shared.read(p) != d}, check)
    if not a.undo:
        sys.exit(trust(root, state, sp, codex/'config.toml', wanted, check))


def trust(root, state, sp, cfg, wanted, check):
    """After the hooks are written: trust them in Codex only if the hooks selftest passes; else take the kit's
    trust block out. Returns the exit code (1 when the selftest failed or the config could not be updated)."""
    passed, last = run_selftest(root)
    rec = recorded_trust(state)
    notes = []
    try:
        plan = {}
        if rec and rec['config'] != str(cfg):
            # CODEX_HOME moved: take the block out of the old config first.
            old = Path(rec['config'])
            if shared.read(old) is not None:
                old_text = config_text(old)
                gone, notes = codex_trust.remove_text(old_text, rec, bool(rec.get('created')))
                if gone != old_text:
                    plan[old] = None if gone is None else gone.encode('utf-8')
            rec = None
            state.pop('codex_trust', None)
        raw = shared.read(cfg)
        text = '' if raw is None else raw.decode('utf-8')
        created = bool(rec.get('created')) if rec else raw is None
        if passed:
            new, newrec, more = codex_trust.sync_text(text, wanted, rec)
        else:
            new, more = codex_trust.remove_text(text, rec, created)
            newrec = rec if more else None
        notes += more
        if new == '' and created:
            new = None
        if newrec:
            state['codex_trust'] = dict(newrec, config=str(cfg), created=created)
        else:
            state.pop('codex_trust', None)
        plan[sp] = (json.dumps(state, indent=2)+'\n').encode()
        if (new if new is not None else '') != text:
            plan[cfg] = None if new is None else new.encode('utf-8')
        shared.apply_plan({p: d for p, d in plan.items() if shared.read(p) != d}, check)
    except (OSError, ValueError) as exc:
        print('Codex hook trust not updated: '+' '.join(str(exc).splitlines()), file=sys.stderr)
        return 1
    for note in notes:
        print(note)
    if not passed:
        print('hooks selftest failed (%s): Codex trust for the kit hooks removed; Codex skips the kit hooks until it passes' % last, file=sys.stderr)
        return 1
    print('hooks selftest passed (%s): Codex trusts the kit hooks (%d)' % (last, len(newrec['items']) if newrec else 0))
    return 0


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        print(' '.join(str(exc).splitlines()), file=sys.stderr)
        sys.exit(1)
