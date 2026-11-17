"""codex_trust: the hash matches what codex 0.166.0 itself reports, and config.toml edits touch only the kit's own tables.
Run: python3 tests/test_codex_trust.py"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT/'plugins/routing-kit/lib'))
import codex_trust as ct  # noqa: E402

failed = 0
def check(name, cond):
    global failed
    print(('ok ' if cond else 'FAIL ')+name)
    failed += not cond

# 1. Known answers: every hash codex reported for the vector hooks file.
vec = json.loads((ROOT/'tests/fixtures/sync-hooks/codex-trust-vectors.json').read_text())
path = '/h/hooks.json'
data = vec['hooks_json']
allcmds = {h['command'] for gs in data['hooks'].values() for g in gs for h in g['hooks']}
got = ct.entries_for(path, data, allcmds)
check('hash equals codex hooks/list for all %d vector hooks' % len(vec['codex_hashes']),
      {k[len(path)+1:]: v for k, v in got.items()} == vec['codex_hashes'])
# Only owned commands count; handlers codex would reject are not trusted.
check('only owned commands get a hash', set(ct.entries_for(path, data, {'first'})) == {path+':pre_tool_use:0:0'})
check('fractional or negative timeout is refused', ct.hook_hash('Stop', None, {'type': 'command', 'command': 'x', 'timeout': 1.5}) is None
      and ct.hook_hash('Stop', None, {'type': 'command', 'command': 'x', 'timeout': -1}) is None
      and ct.hook_hash('Stop', None, {'type': 'command', 'command': '  '}) is None
      and ct.hook_hash('Stop', None, {'type': 'prompt'}) is None)

# 2. config.toml edits: one block at the very end, removed only when it is still the very end.
D1, D2 = 'sha256:' + '1'*64, 'sha256:' + '2'*64
K1, K2 = '/h/hooks.json:stop:0:0', '/h/hooks.json:pre_tool_use:0:0'
base = '# keep\nmodel = "x"\n\n[hooks.state."foreign:stop:0:0"]\ntrusted_hash = "sha256:f"\n'
W = {K1: D1, K2: D2}
new, rec, notes = ct.sync_text(base, W, None)
check('appends one block after the foreign text, foreign bytes unchanged',
      new == base + ct.block([(K1, D1), (K2, D2)]) and new.count(ct.START) == 1 and new.endswith(ct.END) and not notes and rec['sep'] is False)
check('sync is idempotent (byte-equal)', ct.sync_text(new, W, rec) == (new, rec, []))
check('remove restores the original bytes', ct.remove_text(new, rec) == (base, []))
changed, rec2, _ = ct.sync_text(new, {K1: D2, K2: D2}, rec)
check('a changed hash rewrites the block only', changed.startswith(base) and changed.count(D1) == 0 and changed.count(ct.START) == 1)
check('a hook that is gone drops out of the block', ct.sync_text(new, {K1: D1}, rec)[0] == base + ct.block([(K1, D1)]))
# Review finding 1: the block text inside foreign content is never touched; only the very end counts.
inside = 'developer_instructions = """\n%s"""\n' % ct.block([(K1, D1)])
text, r, _ = ct.sync_text(inside, {K1: D1}, None)
check('block-looking text inside a foreign multiline string is left alone', text.startswith(inside))
fake = {'items': [[K1, D1]], 'sep': False}
check('removal never searches inside the file', ct.remove_text(inside + 'x = 1\n', fake) == (inside + 'x = 1\n', [ct.BY_HAND]))
extra = new + 'enabled = false\n'
check('anything after the block: nothing removed, owner told once',
      ct.remove_text(extra, rec) == (extra, [ct.BY_HAND]) and ct.sync_text(extra, W, rec) == (extra, rec, [ct.BY_HAND]))
check('a stray block with no record is not touched or doubled', ct.sync_text(new, W, None) == (new, None, [ct.BY_HAND]))
foreign_same_key = base + '\n[hooks.state.%s]\nenabled = false\n' % json.dumps(K1)
out, r, notes = ct.sync_text(foreign_same_key, {K1: D1}, None)
check('a foreign table with the same key is left alone and nothing is added', out == foreign_same_key and r is None and len(notes) == 1)
out, r, notes = ct.sync_text(foreign_same_key, W, None)
check('other hooks still get their table when one key is foreign', out == foreign_same_key + ct.block([(K2, D2)]) and len(notes) == 1)
# Review finding 5: undo removes exactly what was appended.
for original in ('', ' \t\n\n', 'a = 1', 'a = 1\n', '\n'):
    n, r, _ = ct.sync_text(original, W, None)
    back, _ = ct.remove_text(n, r)
    check('round trip gives the original bytes back: %r' % original, back == original)
n, r, _ = ct.sync_text('', W, None)
check('a file the kit created is deleted only if it was created and is now empty', ct.remove_text(n, r, created=True) == (None, []) and ct.remove_text(n, r, created=False) == ('', []))
n, r, _ = ct.sync_text(' \t\n\n', W, None)
check('whitespace-only original is never deleted', ct.remove_text(n, r, created=False)[0] == ' \t\n\n')
check('an unterminated config gets exactly one separating newline, removed again',
      ct.sync_text('a = 1', W, None)[0].startswith('a = 1\n# routing-kit hook trust: start') and ct.sync_text('a = 1', W, None)[1]['sep'] is True)
bad = 'a = [\n'
if ct.tomllib is not None:
    check('invalid TOML is left alone', ct.sync_text(bad, W, None) == (bad, None, ['config.toml is not valid TOML, left alone; Codex trust not written']))
check('quote and backslash in a path stay valid TOML', ct.tomllib is None or ct.tomllib.loads(ct.sync_text('', {'/a"b\\c/hooks.json:stop:0:0': D1}, None)[0])['hooks']['state']['/a"b\\c/hooks.json:stop:0:0']['trusted_hash'] == D1)
# Owner removed our block by hand (after an owner comment made it non-suffix): the next sync writes a fresh block.
t1, r1, _ = ct.sync_text('a = 1\n', W, None)
by_hand = 'a = 1\n# my note\n'
t2, r2, n2 = ct.sync_text(by_hand, W, r1)
check('block removed by hand: a fresh block is written', t2.startswith(by_hand) and ct.START in t2 and r2 is not None)
# Only the start line removed: our tables are still there, so nothing is written and the by-hand line shows.
partial = t1.replace(ct.START + '\n', '', 1) if (ct.START + '\n') in t1 else t1.replace(ct.START, '', 1)
t3, r3, n3 = ct.sync_text(partial, W, r1)
check('start line removed but tables left: no second block', t3 == partial and n3 == [ct.BY_HAND])
# Marker kept without its newline, or a table header re-quoted: still ours, no second block.
k1 = list(W)[0]
t4, r4, n4 = ct.sync_text('a = 1\n' + ct.START.rstrip('\n'), W, r1)
check('marker without newline: no second block', n4 == [ct.BY_HAND])
t5, r5, n5 = ct.sync_text("a = 1\n[hooks.state.'" + k1 + "']\ntrusted_hash = 'x'\n", W, r1)
check('re-quoted header of ours: no second block', n5 == [ct.BY_HAND])
print('FAIL %d' % failed if failed else 'codex trust: all ok')
sys.exit(1 if failed else 0)
