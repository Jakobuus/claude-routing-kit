"""Locked JSON-lines message board and extensible command dispatch."""
import argparse
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata
import uuid


class InvalidInput(ValueError):
    """The caller's text, name or target is not acceptable (exit 2)."""


REQUIRED = ('id', 'time', 'from', 'to', 'repo', 'kind', 'text')
NAME = re.compile(r'[A-Za-z0-9._-]{1,64}')


def directory():
    home = Path(os.environ.get('ROUTING_KIT_HOME', str(Path.home() / '.config/routing-kit')))
    for path in (home, home / 'board', home / 'board/cursors'):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.chmod(0o700)
    return home / 'board'


@contextmanager
def locked(exclusive=False):
    fd = os.open(str(directory() / '.lock'), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield
    finally:
        os.close(fd)


def unsafe(text, allow_tab=False):
    """True when text holds a control, line or paragraph separator character."""
    return any(unicodedata.category(c) in ('Cc', 'Zl', 'Zp') and not (allow_tab and c == '\t') for c in text)


def safe(value):
    """Show control and separator characters as escapes, never raw."""
    return ''.join('\\u%04x' % ord(c) if unicodedata.category(c) in ('Cc', 'Zl', 'Zp') else c for c in str(value))


def now():
    """UTC now; KIT_BOARD_NOW (an ISO time) fixes the clock for tests."""
    value = os.environ.get('KIT_BOARD_NOW')
    if value:
        parsed = parse_time(value)
        if parsed is None:
            raise InvalidInput('KIT_BOARD_NOW must be an ISO timestamp')
        return parsed
    return datetime.datetime.now(datetime.timezone.utc)


def stamp(when):
    return when.isoformat().replace('+00:00', 'Z')


def last_time(fd, size):
    """Time of the newest complete record at the end of the board file, or None."""
    tail = os.pread(fd, min(size, 65536), max(0, size - 65536)).split(b'\n')
    for line in reversed(tail[:-1] if tail and tail[-1] == b'' else tail):
        try:
            return parse_time(json.loads(line)['time'])
        except (ValueError, KeyError, TypeError):
            continue
    return None


def append(record):
    validate_text(record['text'])
    with locked(True):
        fd = os.open(str(directory() / 'board.jsonl'), os.O_CREAT | os.O_RDWR | os.O_APPEND, 0o600)
        try:
            os.fchmod(fd, 0o600)
            size = os.fstat(fd).st_size
            # The time is taken under the lock and never goes backwards, so file
            # order and time order agree (the read cursor falls back on time).
            when, newest = now(), last_time(fd, size) if size else None
            # A fixed test clock (KIT_BOARD_NOW) is taken as given.
            # A newest time far ahead of the clock is a bad row, not a reason to jump.
            if (newest and when <= newest < when + datetime.timedelta(hours=1)
                    and not os.environ.get('KIT_BOARD_NOW')):
                when = newest + datetime.timedelta(microseconds=1)
            record['time'] = stamp(when)
            data = (json.dumps(record, ensure_ascii=True) + '\n').encode('ascii')
            # A crashed writer can leave a partial line: start on a fresh line.
            if size and os.pread(fd, 1, size - 1) != b'\n':
                data = b'\n' + data
            if os.write(fd, data) != len(data):
                raise OSError('incomplete board write')
        finally:
            os.close(fd)


def records():
    """Every well-formed record; unreadable lines are skipped and counted on stderr."""
    with locked():
        path = directory() / 'board.jsonl'
        raw = path.read_bytes().decode('utf-8', errors='replace') if path.exists() else ''
    rows, skipped = [], 0
    for line in raw.split('\n'):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            row = None
        if isinstance(row, dict) and all(isinstance(row.get(k), str) for k in REQUIRED):
            rows.append(row)
        else:
            skipped += 1
    if skipped:
        print('board.py: skipped %d unreadable board line(s)' % skipped, file=sys.stderr)
    return rows


def visible(reader, repo, all_repos=False, rows=None):
    rows = records() if rows is None else rows
    struck = {r.get('ref') for r in rows if r['kind'] == 'strike'}
    # The repo filter narrows broadcasts only; a message addressed to the
    # reader or to the reader's repo is theirs wherever it was posted.
    return [r for r in rows if r['kind'] not in ('strike', 'seen') and r['id'] not in struck
            and (r['to'] in (reader, 'repo:' + repo)
                 or (r['to'] == 'all' and (all_repos or r['repo'] == repo)))]


def cursor_path(reader):
    # Keep ordinary names readable while preventing directory traversal.
    safe_name = reader if reader and all(c.isalnum() or c in '-_' for c in reader) else hashlib.sha256(reader.encode()).hexdigest()
    return directory() / 'cursors' / (safe_name + '.json')


def cursor_get(reader):
    """The saved cursor ({'id', 'time'} or a bare id), or None when missing or unreadable."""
    with locked():
        try:
            return json.loads(cursor_path(reader).read_text())
        except (OSError, ValueError):
            return None


def cursor_set(reader, record_id, time=None):
    path = cursor_path(reader)
    tmp = path.with_name(path.name + '.tmp')
    with locked(True):
        fd = os.open(str(tmp), os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump({'id': record_id, 'time': time} if time else record_id, stream)
        os.replace(str(tmp), str(path))


FAMILIES = ('claude', 'codex', 'gemini', 'owner')

# The id each agent puts in its own environment, in the order they are tried. A program started
# by another agent inherits that agent's variables too (a Codex or Antigravity worker started from
# Claude still sees CLAUDE_CODE_SESSION_ID), so Claude's comes last.
ENV_SESSIONS = (('ANTIGRAVITY_CONVERSATION_ID', 'gemini'), ('CODEX_SESSION_ID', 'codex'),
                ('CODEX_THREAD_ID', 'codex'), ('CLAUDE_CODE_SESSION_ID', 'claude'))


def session_name(family, session):
    """The board name of a session: the one name the hooks and the CLI both derive."""
    return family + '-' + hashlib.sha1(session.encode()).hexdigest()[:4]


def env_session(family=None):
    """(family, session id) of the agent this process runs in, from its environment, or None.
    With `family` given, only that family's variables count."""
    for var, owner in ENV_SESSIONS:
        value = os.environ.get(var)
        if value and (family is None or family == owner):
            return owner, value
    return None


def identity():
    """(name, family): KIT_BOARD_NAME, else KIT_BOARD_SESSION, else the agent's own session id from
    its environment. Hooks drop an inherited KIT_BOARD_NAME first (board_dm.check)."""
    family = os.environ.get('KIT_BOARD_FAMILY')
    if family is not None and family not in FAMILIES:
        raise InvalidInput('unknown board family')
    name = os.environ.get('KIT_BOARD_NAME')
    session = os.environ.get('KIT_BOARD_SESSION')
    inferred = env_session(family)
    if not family:
        family = inferred[0] if inferred else 'claude'
    if not name:
        if not session and inferred:
            session = inferred[1]
        if not session:
            raise InvalidInput('no board name: set KIT_BOARD_NAME or KIT_BOARD_SESSION '
                               '(an agent is recognised by its own session id in its environment)')
        name = session_name(family, session)
    validate_name(name)
    return name, family


def whoami(args):
    name, family = identity()
    print(name, family)


def repository(path=None):
    if path:
        return str(Path(path).resolve())
    result = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    return str(Path(result.stdout.strip() if result.returncode == 0 else os.getcwd()).resolve())


def repository_of(cwd):
    """The git top level of a folder (the repo name claims are posted under), else the folder itself.
    With no usable folder: the process's own, as repository() finds it."""
    if not isinstance(cwd, str) or not os.path.isabs(cwd) or not os.path.isdir(cwd):
        return repository()
    result = subprocess.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    return str(Path(result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else cwd).resolve())


def validate_text(text):
    if len(text) > 500 or unsafe(text, allow_tab=True):
        raise InvalidInput('text must be one line of at most 500 plain characters')


def validate_name(name):
    if not NAME.fullmatch(name):
        raise InvalidInput('names use only letters, digits, dot, underscore and dash (1 to 64 characters)')


def validate_target(to):
    if to.startswith('repo:'):
        if len(to) == 5 or len(to) > 1024 or unsafe(to):
            raise InvalidInput('repo target must be repo:<path> on one line')
    else:
        validate_name(to)


def make_record(text, repo, to='all', kind='note', ref=None):
    validate_text(text)
    validate_target(to)
    name, family = identity()
    return dict(id='b-' + uuid.uuid4().hex[:12], time=stamp(now()),
                **{'from': name}, family=family, to=to, repo=repo, kind=kind, ref=ref, text=text, owner_quote=False)


def post(args):
    row = make_record(args.text, repository(args.repo), args.to, args.kind)
    append(row)
    print(row['id'])


def parse_time(value):
    try:
        when = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except (AttributeError, ValueError):
        return None
    return when if when.tzinfo else when.replace(tzinfo=datetime.timezone.utc)


def read(args):
    reader = args.reader or identity()[0]
    validate_name(reader)
    rows = records()
    cursor = cursor_get(reader)
    cursor_id, cursor_time = (cursor.get('id'), cursor.get('time')) if isinstance(cursor, dict) else (cursor, None)
    ids = [r['id'] for r in rows]
    if cursor_id in ids:
        # Locate the cursor in the full log even when its record was struck.
        newer = set(ids[ids.index(cursor_id) + 1:])
    else:
        # The cursor's record is gone (tidied away): fall back to its time.
        when = parse_time(cursor_time)
        newer = {r['id'] for r in rows if when is None or (parse_time(r['time']) or when) > when}
    shown = [r for r in visible(reader, repository(args.repo), args.all, rows) if r['id'] in newer]
    for row in shown:
        print('{} {} {}: {}'.format(*map(safe, (row['id'], row['time'], row['from'], row['text']))))
    if shown and not args.peek:
        cursor_set(reader, shown[-1]['id'], shown[-1]['time'])


def strike(args):
    row = make_record(args.reason, repository(), kind='strike', ref=args.id)
    append(row)


COMMANDS = {}


def register(name, help_text, configure, handler):
    """Register a command with an argparse setup callback and handler."""
    COMMANDS[name] = (help_text, configure, handler)


def configure_post(p):
    p.add_argument('--to', default='all')
    p.add_argument('--repo')
    p.add_argument('--kind', default='note', choices=('note', 'claim', 'question', 'done', 'dm', 'strike', 'seen'))
    p.add_argument('text')


def configure_read(p):
    p.add_argument('--repo')
    p.add_argument('--all', action='store_true')
    p.add_argument('--as', dest='reader')
    p.add_argument('--peek', action='store_true')


def configure_strike(p):
    p.add_argument('id')
    p.add_argument('reason', nargs='?', default='')


register('post', 'Leave a message.', configure_post, post)
register('read', 'Read new messages.', configure_read, read)
register('strike', 'Hide a message.', configure_strike, strike)
register('whoami', 'Show this session\'s board name and family.', lambda p: None, whoami)


def main(argv=None):
    parser = argparse.ArgumentParser(prog='kit-board', description='Leave and read board messages.')
    commands = parser.add_subparsers(dest='command', required=True)
    for name, (help_text, configure, handler) in COMMANDS.items():
        command = commands.add_parser(name, help=help_text)
        configure(command)
        command.set_defaults(handler=handler)
    args = parser.parse_args(argv)
    try:
        args.handler(args)
    except InvalidInput as error:
        parser.error(str(error))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
