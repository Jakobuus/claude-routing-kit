"""Claim leases and locked, byte-preserving board archival."""
import datetime
import json
import os
import tempfile

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import board


now = board.now


def latest_claims(rows):
    latest, key_of = {}, {}
    for row in rows:
        if row['kind'] == 'claim':
            key = (row['from'], row['repo'], row['to'], row['text'])
            latest[key] = row
            key_of[row['id']] = key
        elif row['kind'] == 'strike' and row.get('ref') in key_of:
            latest.pop(key_of[row['ref']], None)
    return latest.values()


def expired(row, clock):
    stamp = board.parse_time(row['time'])
    return stamp is not None and clock - stamp >= datetime.timedelta(hours=6)


def claims(args):
    clock = now()
    rows = board.records()
    struck = {r.get('ref') for r in rows if r['kind'] == 'strike'}
    repo = board.repository(args.repo)
    for row in latest_claims(rows):
        if row['repo'] == repo and row['id'] not in struck and not expired(row, clock):
            print('{} {} {}: {}'.format(*map(board.safe, (row['id'], row['time'], row['from'], row['text']))))


def tidy(args):
    clock = now()
    with board.locked(True):
        directory = board.directory()
        path = directory / 'board.jsonl'
        if not path.exists():
            return
        lines = path.read_bytes().splitlines(keepends=True)
        parsed = []
        for line in lines:
            try:
                row = json.loads(line)
                if not isinstance(row, dict) or not all(isinstance(row.get(k), str) for k in board.REQUIRED):
                    row = None
            except (ValueError, UnicodeError):
                row = None
            parsed.append(row)
        rows = [r for r in parsed if r is not None]
        struck = {r.get('ref') for r in rows if r['kind'] == 'strike'}
        pinned = set()
        for cursor in (directory / 'cursors').glob('*.json'):
            try:
                value = json.loads(cursor.read_text())
                pinned.add(value.get('id') if isinstance(value, dict) else value)
            except (ValueError, OSError, TypeError):
                continue
        moving = set()
        for row in rows:
            stamp = board.parse_time(row['time'])
            if (stamp is not None and clock - stamp > datetime.timedelta(days=14)
                    and row['id'] not in pinned
                    and (row['id'] in struck or (row['kind'] == 'claim' and expired(row, clock)))):
                moving.add(row['id'])
        # Keep strike markers while their target remains in the live log.
        live_ids = {r['id'] for r in rows} - moving
        for row in rows:
            stamp = board.parse_time(row['time'])
            if (row['kind'] == 'strike' and row.get('ref') not in live_ids
                    and row['id'] not in pinned and stamp is not None
                    and clock - stamp > datetime.timedelta(days=14)):
                moving.add(row['id'])
        if not moving:
            return
        archives = {}
        live = []
        for line, row in zip(lines, parsed):
            if row is not None and row['id'] in moving:
                month = board.parse_time(row['time']).strftime('%Y-%m')
                archives.setdefault(month, []).append(line)
            else:
                live.append(line)
        archive = directory / 'archive'
        archive.mkdir(mode=0o700, exist_ok=True)
        for month, data in archives.items():
            target = archive / (month + '.jsonl')
            existing = set()
            if target.is_file():
                for line in target.read_bytes().splitlines():
                    try:
                        existing.add(json.loads(line)['id'])
                    except (ValueError, KeyError, TypeError):
                        continue
            data = [line for line in data if json.loads(line)['id'] not in existing]
            fd = os.open(str(target), os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
            try:
                payload = b''.join(data)
                if os.write(fd, payload) != len(payload):
                    raise OSError('incomplete archive write')
            finally:
                os.close(fd)
        fd, temporary = tempfile.mkstemp(dir=directory, prefix='.tidy-')
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(b''.join(live))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def configure_claims(parser):
    parser.add_argument('--repo')


board.register('claims', 'List open claims.', configure_claims, claims)
board.register('tidy', 'Archive old struck and expired records.', lambda parser: None, tidy)

if __name__ == '__main__':
    raise SystemExit(board.main())
