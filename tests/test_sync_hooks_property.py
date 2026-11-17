"""Property test for kit-sync hooks ownership (exact-command rule).

Random hooks files full of foreign handlers, including look-alikes of the kit's names and commands and groups
that mix a foreign and a kit handler, go through random sequences of sync / add-foreign / resync / move-root /
undo. The oracle is independent of the code under test: `foreign()` lists every handler whose command was never
generated, with its group's own fields, in file order. Sync and undo must leave that list exactly as it was, and
after undo no generated command may remain.
Run: python3 tests/test_sync_hooks_property.py  (fixed seed, prints the number of runs)
"""
import copy
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent/'plugins/routing-kit'
sys.path.insert(0, str(ROOT/'lib'))
import sync_hooks as sh  # noqa: E402

sh.max_timeout = lambda root, event: 5 + len(event) % 4
RUNS = 400
AGENTS = ('claude', 'codex', 'agy')
ROOTS = [Path('/opt/kit-a'), Path('/opt/kit b/with space')]
P = Path('hooks-under-test.json')


def lookalikes(agent):
    other = [a for a in AGENTS if a != agent][0]
    return ['/vendor/guard-destructive.sh', 'printf "kit-hook audit"', '/vendor/kit-hook audit',
            str(ROOTS[0]/'hooks/kit-hook')+' '+agent+' Stop extra',
            str(ROOTS[0]/'hooks/kit-hook')+' '+other+' Stop',
            '/elsewhere/hooks/kit-hook '+agent+' Stop',
            'bash -c "'+str(ROOTS[0]/'hooks/kit-hook')+' '+agent+' Stop"']


def generated_ever(agent):
    return {sh.command_for(r, agent, agent == 'claude', e) for r in ROOTS for e in sh.events_of(agent)} | {str(r/'hooks'/('session-start-agy' if agent == 'agy' else 'session-start')) + ('' if agent == 'agy' else ' '+agent) for r in ROOTS}


def foreign(data, agent):
    gen = generated_ever(agent)
    hooks = data.get(sh.key_of(agent)) or {}
    out = {}
    for event, items in hooks.items():
        acc = []
        for item in items:
            if sh.is_group(item):
                meta = {k: v for k, v in item.items() if k != 'hooks'}
                acc += [('g', meta, h) for h in item['hooks'] if sh.command(h) not in gen]
            elif isinstance(item, dict) and sh.command(item) in gen:
                continue
            else:
                acc.append(('f', item))
        if acc:
            out[event] = acc
    return out


def kit_commands(data, agent):
    gen = generated_ever(agent)
    hooks = data.get(sh.key_of(agent)) or {}
    found = []
    for items in hooks.values():
        for item in items:
            for h in (item['hooks'] if sh.is_group(item) else [item]):
                if sh.command(h) in gen:
                    found.append(sh.command(h))
    return found


def random_handler(rng, agent, i):
    r = rng.random()
    if r < 0.45:
        c = rng.choice(lookalikes(agent) + ['foreign-%d' % i, 'echo "kit-hook $X"'])
        h = {'type': 'command', 'command': c}
        if rng.random() < 0.5:
            h['timeout'] = rng.choice([3, 9, 60])
        return h
    if r < 0.6:
        return {'type': 'prompt', 'prompt': 'p%d' % i}
    return {'type': 'command', 'command': 'foreign-%d' % i, 'extra': {'n': [i, None, True]}}


def random_item(rng, agent, i, gen_cmds):
    r = rng.random()
    if agent == 'agy' and r < 0.4:
        return random_handler(rng, agent, i)
    hs = [random_handler(rng, agent, i*10+j) for j in range(rng.randint(1, 3))]
    if gen_cmds and rng.random() < 0.3:  # a hand-merged group: foreign handlers around a kit handler
        hs.insert(rng.randint(0, len(hs)), {'type': 'command', 'command': rng.choice(gen_cmds), 'timeout': 1})
    g = {'hooks': hs}
    if rng.random() < 0.6:
        g['matcher'] = rng.choice(['Read', '*', 'Bash'])
    if rng.random() < 0.2:
        g['note'] = 'keep me %d' % i
    if rng.random() < 0.1:
        return 'junk-%d' % i
    return g


def initial(rng, agent):
    gen_cmds = sorted(sh.command_for(ROOTS[0], agent, agent == 'claude', e) for e in sh.events_of(agent))
    events = sh.events_of(agent) + ['Notification']
    hooks = {}
    for k, e in enumerate(rng.sample(events, rng.randint(0, 4))):
        hooks[e] = [random_item(rng, agent, k*100+j, gen_cmds) for j in range(rng.randint(0, 3))]
    data = {'theme': 'keep', 'list': [1, 2, {'a': None}]}
    if rng.random() < 0.8 or hooks:
        data[sh.key_of(agent)] = hooks
    if agent == 'agy':
        data['other'] = {'Stop': [{'type': 'command', 'command': 'second-foreign'}]}
    return data


def dump(rng, data):
    return (json.dumps(data, indent=rng.choice([None, 2, 4]), ensure_ascii=False)+rng.choice(['', '\n'])).encode()


def add_foreign(rng, data, agent, n, current):
    data = copy.deepcopy(data)
    hooks = data.setdefault(sh.key_of(agent), {})
    gen_cmds = sorted(current)
    event = rng.choice(sh.events_of(agent) + ['Notification'])
    items = hooks.setdefault(event, [])
    how = rng.random()
    if how < 0.25 and any(sh.is_group(i) for i in items):
        g = rng.choice([i for i in items if sh.is_group(i)])
        g['hooks'].insert(rng.randint(0, len(g['hooks'])), random_handler(rng, agent, 9000+n))
    else:
        items.insert(rng.randint(0, len(items)), random_item(rng, agent, 9000+n, gen_cmds if how > 0.9 else []))
    return data


def one_run(seed):
    rng = random.Random(seed)
    agent = rng.choice(AGENTS)
    root_i = 0
    raw = dump(rng, initial(rng, agent))
    recorded = set()
    n = 0
    steps = 0
    def snapshot():
        return foreign(json.loads(raw), agent)
    def sync():
        nonlocal raw, recorded
        root = ROOTS[root_i]
        fresh = sh.hook_entries(root, agent, agent == 'claude')
        now = sh.commands_of(fresh)
        before = snapshot()
        raw = sh.sync_bytes(raw, P, agent, set(now) | recorded, fresh)
        recorded = set(now)
        data = json.loads(raw)
        assert foreign(data, agent) == before, ('sync changed foreign', seed)
        kit = kit_commands(data, agent)
        assert sorted(kit) == sorted(now), ('sync left stale or duplicate kit commands', seed, kit)
        return raw
    def undo():
        nonlocal raw, recorded
        root = ROOTS[root_i]
        owned = {sh.command_for(root, agent, agent == 'claude', e) for e in sh.events_of(agent)} | recorded
        before = snapshot()
        out = sh.undo_bytes(raw, P, agent, owned)
        raw = b'{}' if out is None else out
        recorded = set()
        data = json.loads(raw)
        assert foreign(data, agent) == before, ('undo changed foreign', seed)
        assert not set(kit_commands(data, agent)) & owned, ('undo left kit commands', seed)
    for _ in range(rng.randint(3, 9)):
        op = rng.choice(['sync', 'sync', 'add', 'add', 'resync', 'move', 'undo'])
        steps += 1
        if op == 'sync':
            sync()
        elif op == 'resync':
            first = sync()
            assert sync() == first, ('resync not stable', seed)
        elif op == 'add':
            n += 1
            current = {sh.command_for(ROOTS[root_i], agent, agent == 'claude', e) for e in sh.events_of(agent)} | recorded
            data = add_foreign(rng, json.loads(raw), agent, n, current)
            raw = dump(rng, data)
        elif op == 'move' and recorded:
            root_i = 1 - root_i
        else:
            undo()
    # every sequence ends with a sync (if none ran) and an undo: nothing of ours may stay, nothing foreign may go
    sync()
    undo()
    return steps + 2


def main():
    steps = sum(one_run(1000+i) for i in range(RUNS))
    print('property runs: %d (steps: %d, agents: %s)' % (RUNS, steps, ','.join(AGENTS)))


if __name__ == '__main__':
    main()
