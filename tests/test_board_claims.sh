#!/bin/bash
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BOARD="$ROOT/plugins/routing-kit/bin/kit-board"
export HOME=$(mktmp)
for case_name in expiry renewal repo archive load strike renewal_strike cursor_format archive_retry; do
  export ROUTING_KIT_HOME=$(mktmp)
  if python3 - "$BOARD" "$case_name" <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys

board, case = sys.argv[1:]
home = Path(os.environ['ROUTING_KIT_HOME'])
repo = str(home)
other = str(home / 'other')
old = '2026-01-01T00:00:00Z'
now = '2026-02-01T00:00:00Z'

def run(*args, at=now, name='A'):
    env = dict(os.environ, KIT_BOARD_NOW=at, KIT_BOARD_NAME=name, KIT_BOARD_FAMILY='codex')
    p = subprocess.run([board, *args], cwd=home, env=env, capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, f'{args}: exit {p.returncode}: {p.stderr.strip()}'
    return p.stdout.strip()

def post(text, kind='note', at=now, name='A', path=repo):
    return run('post', '--repo', path, '--kind', kind, text, at=at, name=name)

def claims(at=now, path=repo):
    return run('claims', '--repo', path, at=at)

def rows():
    return [json.loads(s) for s in (home / 'board/board.jsonl').read_bytes().splitlines()]

def expiry():
    post('boundary claim', 'claim', old)
    assert 'boundary claim' in claims('2026-01-01T05:59:59Z')
    assert 'boundary claim' not in claims('2026-01-01T06:00:00Z')
    assert 'boundary claim' not in claims('2026-01-01T06:00:01Z')

def renewal():
    post('renew me', 'claim', old)
    post('renew me', 'claim', '2026-01-01T05:00:00Z')
    out = claims('2026-01-01T06:00:00Z')
    assert out.count('renew me') == 1, out
    assert 'renew me' in claims('2026-01-01T10:59:59Z')
    assert 'renew me' not in claims('2026-01-01T11:00:00Z')

def repo_case():
    post('open here', 'claim')
    post('open elsewhere', 'claim', path=other)
    post('ordinary note')
    post('expired here', 'claim', old)
    struck = post('closed here', 'claim')
    run('strike', struck)
    out = claims()
    assert 'open here' in out
    for text in ('open elsewhere', 'ordinary note', 'expired here', 'closed here'):
        assert text not in out, out
    assert 'open elsewhere' in claims(path=other)

def archive():
    expired = post('old expired', 'claim', old)
    struck = post('old struck', at=old)
    run('strike', struck, at=old)
    keep = post('live claim', 'claim')
    # Expired but younger than fourteen days must remain in the live log.
    young = post('young expired', 'claim', '2026-01-31T00:00:00Z')
    path = home / 'board/board.jsonl'
    before = path.read_bytes().splitlines(keepends=True)
    run('tidy')
    live = path.read_bytes().splitlines(keepends=True)
    archived = (home / 'board/archive/2026-01.jsonl').read_bytes().splitlines(keepends=True)
    assert len(live) < len(before)
    assert sorted(live + archived) == sorted(before), 'lost, duplicated, or rewritten bytes'
    assert {expired, struck} <= {json.loads(s)['id'] for s in archived}
    assert {keep, young} <= {json.loads(s)['id'] for s in live}
    run('tidy')
    assert path.read_bytes().splitlines(keepends=True) == live
    assert (home / 'board/archive/2026-01.jsonl').read_bytes().splitlines(keepends=True) == archived

def load():
    # Gate before creating concurrent workers: missing commands fail cleanly.
    run('tidy')
    post('expired load fixture', 'claim', old)
    anchor = post('cursor anchor')
    for i in range(5):
        assert anchor in run('read', '--as', f'reader-{i}', '--repo', repo)
    def poster(i):
        for j in range(10):
            post(f'load-{i}-{j}', name=f'poster-{i}')
    def reader(i):
        for _ in range(10):
            run('read', '--as', f'reader-{i}', '--repo', repo)
    def tidy():
        for _ in range(10):
            run('tidy')
    # All workers are joined inside this foreground process.
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(poster, i) for i in range(10)]
        futures += [pool.submit(reader, i) for i in range(5)]
        futures.append(pool.submit(tidy))
        for future in futures:
            future.result()
    live = rows()
    archived = [json.loads(s) for p in (home / 'board/archive').glob('*.jsonl') for s in p.read_bytes().splitlines()]
    combined = live + archived
    assert len(combined) == 102
    assert len({r['id'] for r in combined}) == 102
    assert {r['text'] for r in combined if r['text'].startswith('load-')} == {f'load-{i}-{j}' for i in range(10) for j in range(10)}
    ids = {r['id'] for r in live}
    for i in range(5):
        cursor = json.loads((home / f'board/cursors/reader-{i}.json').read_text())
        assert isinstance(cursor, dict) and set(cursor) == {'id', 'time'}
        assert cursor['id'] in ids
        run('read', '--as', f'reader-{i}', '--repo', repo)
        assert run('read', '--as', f'reader-{i}', '--repo', repo) == ''
    tail = post('after tidy')
    for i in range(5):
        assert tail in run('read', '--as', f'reader-{i}', '--repo', repo)

def renewal_strike():
    first = post('renew then close', 'claim')
    post('renew then close', 'claim')
    run('strike', first)
    assert 'renew then close' not in claims()
    post('renew then close', 'claim')
    assert 'renew then close' in claims()

def cursor_format():
    target = post('cursor fixture')
    run('read', '--as', 'format-reader', '--repo', repo)
    cursor = json.loads((home / 'board/cursors/format-reader.json').read_text())
    assert cursor == {'id': target, 'time': now}, cursor

def archive_retry():
    post('January claim', 'claim', old)
    post('February claim', 'claim', now)
    path = home / 'board/board.jsonl'
    before = path.read_bytes().splitlines(keepends=True)
    archive = home / 'board/archive'
    archive.mkdir()
    obstacle = archive / '2026-02.jsonl'
    obstacle.mkdir()
    env = dict(os.environ, KIT_BOARD_NOW='2026-03-01T00:00:00Z')
    result = subprocess.run([board, 'tidy'], env=env, capture_output=True, timeout=30)
    assert result.returncode != 0
    assert path.read_bytes().splitlines(keepends=True) == before
    assert (archive / '2026-01.jsonl').read_bytes().splitlines(keepends=True) == before[:1]
    obstacle.rmdir()
    run('tidy', at='2026-03-01T00:00:00Z')
    combined = path.read_bytes().splitlines(keepends=True)
    combined += [line for p in archive.glob('*.jsonl') for line in p.read_bytes().splitlines(keepends=True)]
    assert sorted(combined) == sorted(before)

def strike():
    target = post('hidden forever', at=old)
    run('strike', target, at=old)
    survivor = post('survives')
    run('tidy')
    for name in ('fresh-one', 'fresh-two'):
        out = run('read', '--as', name, '--repo', repo, '--peek')
        assert survivor in out
        assert target not in out and 'hidden forever' not in out

try:
    {'renewal_strike': renewal_strike, 'cursor_format': cursor_format, 'archive_retry': archive_retry, 'expiry': expiry, 'renewal': renewal, 'repo': repo_case, 'archive': archive, 'load': load, 'strike': strike}[case]()
except Exception as error:
    print(f'{case}: {error}', file=sys.stderr)
    sys.exit(1)
PY
  then pass; else fail "$case_name"; fi
done
echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
