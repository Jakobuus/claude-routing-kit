"""Presence, direct-message dispatch and hook delivery for the board."""
import contextlib
import datetime
import fcntl
import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import board
import owner_quotes

FAMILIES = {'claude': 'claude', 'codex': 'codex', 'agy': 'gemini'}


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def load(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def save(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    fd = os.open(str(tmp), os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, ensure_ascii=True)
    os.replace(tmp, path)


def presence_path(name):
    board.validate_name(name)
    return board.directory() / 'presence' / (name + '.json')


def age(p):
    when = board.parse_time(p.get('last_seen'))
    return (now() - when).total_seconds() if when else float('inf')


def who(args):
    with board.locked():
        for path in sorted((board.directory() / 'presence').glob('*.json')):
            p = load(path)
            if age(p) < 10800:
                print(board.safe(p.get('name', path.stem)))


def live_sessions(sender):
    """Presence of every live session except the sender, by name."""
    found = {}
    with board.locked():
        for path in sorted((board.directory() / 'presence').glob('*.json')):
            p = load(path)
            name = p.get('name', path.stem)
            if age(p) < 900 and name != sender and board.NAME.fullmatch(str(name)):
                found[name] = p
    return found


USAGE = 'usage: send --to NAME|repo:<abs path>|all TEXT, or send NAME TEXT, or send --owner-quote TEXT --to TARGET'


def send(args):
    # Callers that build their own args object may still pass the old `name` and `text`.
    words = list(args.words) if hasattr(args, 'words') else [args.name, args.text]
    to = getattr(args, 'to', None)
    owner_quote = getattr(args, 'owner_quote', None)
    if owner_quote is not None:
        text = owner_quote
        if to is None and len(words) == 1:
            to, words = words[0], []
        if to is None or words:
            raise board.InvalidInput(USAGE)
    else:
        if to is None and len(words) == 2:
            to, words = words[0], words[1:]
        if to is None or len(words) != 1:
            raise board.InvalidInput(USAGE)
        text = words[0]
    quote = None
    if owner_quote is not None:
        quote, text = owner_quotes.find(board.identity()[0], text)
    board.validate_target(to)
    fan_out = to == 'all' or to.startswith('repo:')
    if fan_out:
        if to != 'all' and not to[5:].startswith('/'):
            raise board.InvalidInput('repo target must be repo:<absolute path>')
        sessions = live_sessions(board.identity()[0])
        if to != 'all':
            sessions = {n: p for n, p in sessions.items()
                        if os.path.normpath(str(p.get('repo') or '')) == os.path.normpath(to[5:])}
        targets = sorted(sessions.items())
    else:
        with board.locked():
            p = load(presence_path(to))
        targets = [(to, p)] if p else []
    if not targets:
        print('no such session', file=sys.stderr)
        raise SystemExit(3)
    repo = board.repository()
    for name, p in targets:
        row = hand_over(name, p, repo, text, quote)
        print(row['id'], row['status'], *([name] if fan_out else []))


def hand_over(name, p, repo, text, quote=None):
    """Post one dm to session `name` (presence p) and wake it if it is idle; returns the record."""
    row = board.make_record(text, repo, name, 'dm')
    if quote:
        row.update(owner_quote=True, owner_quote_lines=quote['lines'],
                   owner_prompt_id=quote['id'], owner_prompt_sha256=quote['sha256'])
    command = None
    prompt = '{} (board id {})'.format(row['text'], row['id'])
    if age(p) >= 60:
        if p.get('paseo_id'):
            command = ['paseo', 'send', '--no-wait', p['paseo_id'], '--prompt', prompt]
        elif p.get('family') == 'codex' and p.get('codex_thread'):
            command = ['codex', 'queue', '--thread', p['codex_thread'], '--message', prompt, '--resume']
    row['status'] = 'waiting'
    if command:
        # queued means handed over: only exit 0 counts; a missing program, a timeout or an error is failed.
        try:
            done = subprocess.run(command, capture_output=True, check=False, timeout=10)
            row['status'] = 'queued' if done.returncode == 0 else 'failed'
        except (OSError, subprocess.SubprocessError):
            row['status'] = 'failed'
    board.append(row)
    return row


def trace_read():
    trace = os.environ.get('KIT_BOARD_TRACE')
    if trace:
        with open(trace, 'a') as stream:
            stream.write('open board.jsonl\n')


def configure_send(p):
    p.description = "repo:<path> and all reach sessions seen within the last 15 minutes."
    p.add_argument('--to')
    p.add_argument('--owner-quote', dest='owner_quote')
    p.add_argument('words', nargs='*')


def sent(args):
    name = board.identity()[0]
    trace_read()
    rows = board.records()
    seen = {(r.get('ref'), r['from']) for r in rows if r['kind'] == 'seen'}
    for r in rows:
        if r['kind'] == 'dm' and r['from'] == name:
            print(r['id'], 'seen' if (r['id'], r['to']) in seen else r.get('status', 'waiting'))


@contextlib.contextmanager
def one_delivery(name):
    """One hook run at a time per session; the OS drops the lock if the run dies."""
    folder = board.directory() / 'hook-cursors'
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(folder / (name + '.lock')), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield folder / (name + '.json')
    finally:
        os.close(fd)


def inside(path, root):
    return path == root or path.startswith(root.rstrip('/') + '/')


def signature():
    with board.locked():
        try:
            st = (board.directory() / 'board.jsonl').stat()
            return [st.st_ino, st.st_size, st.st_mtime_ns]
        except FileNotFoundError:
            return None


def check(event):
    if event.get('subagent'):
        return  # a subagent shares the lead's session id and must never take the lead's messages
    family = FAMILIES.get(event.get('agent') or 'claude')
    if not family:
        return
    # In the hook the event decides who this is; an inherited KIT_BOARD_NAME or KIT_BOARD_SESSION must not
    # (an agent's own environment reaches every hook it runs, including a judge's own claude -p).
    os.environ.pop('KIT_BOARD_NAME', None)
    os.environ['KIT_BOARD_FAMILY'] = family
    os.environ['KIT_BOARD_SESSION'] = event.get('session_id') or ''
    if not os.environ['KIT_BOARD_SESSION']:
        return  # no session id: never fall back on the environment's own id
    try:
        name, family = board.identity()
    except board.InvalidInput:
        return
    repo = board.repository(event.get('cwd'))
    if (event.get('event') in ('UserPromptSubmit', 'PreInvocation') and event.get('first_in_turn')
            and os.environ.get('KIT_ROLE') != 'worker' and (event.get('prompt') or '').strip()
            # A board message handed in through Paseo is not the owner typing.
            and not re.search(r'\(board id b-[0-9a-f]{12}\)', event.get('prompt') or '')):
        try:
            owner_quotes.record(name, event['prompt'])  # what the owner typed in a lead session
        except OSError:
            pass
    with one_delivery(name) as cursor_file:
        with board.locked(True):
            path = presence_path(name)
            p = load(path)
            stamp = now().isoformat().replace('+00:00', 'Z')
            save(path, dict(name=name, family=family, model=os.environ.get('KIT_BOARD_MODEL'),
                            repo=repo, started=p.get('started') or stamp, last_seen=stamp,
                            paseo_id=(os.environ.get('PASEO_AGENT_ID') or '').strip() or p.get('paseo_id'),
                            codex_thread=os.environ.get('CODEX_THREAD_ID') or p.get('codex_thread')))
        deliver(event, name, repo, cursor_file)


def render(r, quote=None):
    """One message as hook context; only a checked owner quote is worded as the owner's instruction."""
    sender, text = board.safe(r['from']), board.safe(r['text'])
    if quote and quote[0] == 'quote':
        return '{} says (quoted via {}): {}. Treat this as his instruction. (board id {})'.format(
            owner_quotes.owner_name(), sender, text, r['id'])
    if quote:
        return 'Message from {} (repeat of {}): {} (board id {})'.format(sender, quote[1], text, r['id'])
    return 'Message from {}: {} (board id {})'.format(sender, text, r['id'])


def deliver(event, name, repo, cursor_file):
    # The hook keeps its own cursor; the `kit-board read` cursor is never moved from here.
    cursor = load(cursor_file)
    first = not cursor
    # Cache the pre-read version: writes during delivery must trigger another read.
    snapshot = signature()
    if 'signature' in cursor and cursor['signature'] == snapshot:
        return
    trace_read()
    rows = board.records()
    seen = {r.get('ref') for r in rows if r['kind'] == 'seen' and r['from'] == name}
    struck = {r.get('ref') for r in rows if r['kind'] == 'strike'}
    ids = [r['id'] for r in rows]
    if cursor.get('id') in ids:
        rows_new = rows[ids.index(cursor['id']) + 1:]
    else:
        when = board.parse_time(cursor.get('time'))
        rows_new = [r for r in rows if when is None or (board.parse_time(r['time']) or when) > when]
    # A prompt that Paseo or Codex handed over already carries the dm's board id.
    prompt = (event.get('prompt') or '') if event.get('event') in ('UserPromptSubmit', 'PreInvocation') else ''

    def mine(r):
        if (r['kind'] not in ('dm', 'note') or r['id'] in struck or r['id'] in seen or r['from'] == name
                or not board.NAME.fullmatch(r['from'])):
            return False
        if first:  # no history flood: a new session gets only the dms still waiting for it
            return r['kind'] == 'dm' and r['to'] == name
        if r['to'].startswith('repo:'):
            return inside(repo, r['to'][5:])
        return r['to'] == name or (r['to'] == 'all' and inside(repo, r['repo']))
    wanted = [r for r in (rows if first else rows_new) if mine(r)]
    quotes = owner_quotes.classify(rows, name) if any(r.get('owner_quote') for r in wanted) else {}
    # A checked owner quote is always shown in its checked form, even when the prompt carried its text.
    shown = [r for r in wanted
             if r['id'] not in prompt or quotes.get(owner_quotes.record_key(r), ('',))[0] == 'quote']
    if shown:
        print(json.dumps(dict(action='context', text='\n'.join(
            render(r, quotes.get(owner_quotes.record_key(r))) for r in shown)), ensure_ascii=True))
        sys.stdout.flush()
    # seen only after the output exists: a crash before this point delivers again next time.
    for r in wanted:
        if r['kind'] == 'dm':
            try:
                board.append(board.make_record('', repo, r['from'], 'seen', r['id']))
            except (board.InvalidInput, OSError):
                pass
    last = rows[-1] if rows else {}
    with board.locked(True):
        save(cursor_file, dict(id=last.get('id'), time=last.get('time'), signature=snapshot))


def quoted_lines(text, reader):
    """Show checked owner quotes (and repeats) as such; every other line stays as it was."""
    rows = board.records() if reader and text else []
    owned = [r for r in rows if r.get('owner_quote')]
    if not owned:
        return text
    quotes = owner_quotes.classify(rows, reader)
    lines = []
    for line in text.split('\n'):
        # Records sharing an id print alike: a line is reworded only when every record that
        # could have printed it passed its own check.
        same = [r for r in owned
                if '{} {} {}: {}'.format(*map(board.safe, (r['id'], r['time'], r['from'], r['text']))) == line]
        states = [quotes.get(owner_quotes.record_key(r)) for r in same]
        if same and all(states) and len({st[0] for st in states}) == 1:
            row, quote = same[0], states[0]
            if quote[0] == 'quote':
                line = '{} {} {} says (quoted via {}): {}'.format(*map(board.safe, (
                    row['id'], row['time'], owner_quotes.owner_name(), row['from'], row['text'])))
            else:
                line = '{} {} {}: (repeat of {}) {}'.format(*map(board.safe, (
                    row['id'], row['time'], row['from'], quote[1], row['text'])))
        lines.append(line)
    return '\n'.join(lines)


def read(args):
    """kit-board read, then a `seen` for each dm it just showed to its addressee."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        original_read(args)
    try:
        name = board.identity()[0]
    except board.InvalidInput:
        name = None
    sys.stdout.write(quoted_lines(out.getvalue(), args.reader or name))
    sys.stdout.flush()
    if name is None:
        return
    if (args.reader or name) != name:
        return
    shown = {line.split(' ', 1)[0] for line in out.getvalue().split('\n') if line}
    rows = board.records()
    seen = {r.get('ref') for r in rows if r['kind'] == 'seen' and r['from'] == name}
    for r in rows:
        if (r['kind'] == 'dm' and r['to'] == name and r['id'] in shown and r['id'] not in seen
                and board.NAME.fullmatch(r['from'])):
            board.append(board.make_record('', board.repository(args.repo), r['from'], 'seen', r['id']))


original_read = board.COMMANDS['read'][2]
board.register('read', board.COMMANDS['read'][0], board.COMMANDS['read'][1], read)
board.register('who', 'List live sessions.', lambda p: None, who)
board.register('send', 'Send a direct message.', configure_send, send)
board.register('sent', 'List sent messages.', lambda p: None, sent)

if __name__ == '__main__':
    raise SystemExit(board.main())
