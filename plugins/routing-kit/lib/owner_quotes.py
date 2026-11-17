"""Owner quotes: a session may pass on the owner's own words, and the receiver can check them.

What this can and cannot promise: agents run as the owner's user with full access, so a
determined agent can forge a record. The design makes forging take a deliberate act that the
guards catch on the usual paths (shell and write tools, all three agents); it does not make it
impossible. Accepted hole: text sent into the lead session through Paseo looks like the
owner's typing.

How it works:
  * The prompt hook of a lead session (KIT_ROLE is not "worker") records what the owner typed to
    <board>/owner-prompts/<session name>.jsonl as {"id","time","sha256","text"}, mode 600,
    kept 7 days. A whole prompt is stored or none: one over MAX_PROMPT characters is not
    recorded, so no quote can be cut out of a half-kept prompt.
  * `kit-board send --owner-quote TEXT --to ...` succeeds only when TEXT equals one or more whole
    consecutive lines of one prompt recorded by the posting session within 24 hours. The record
    carries owner_quote, owner_quote_lines (the quoted lines; the text is them joined by single
    spaces), owner_prompt_id and owner_prompt_sha256.
  * The receiver re-checks that proof (verify) before it shows a message as the owner's words,
    one record at a time (a result is never shared by board id: a copy carrying the same id is
    checked, and shown, on its own); anything failing a check is shown as the sender's own note. The same quote sent again to the
    same receiver is shown as a repeat.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import board

KEEP = datetime.timedelta(days=7)
QUOTE_WINDOW = datetime.timedelta(hours=24)
MAX_PROMPT = 100000


def owner_name():
    """The owner's display name from profile key owner_name, else "the owner"."""
    home = Path(os.environ.get('ROUTING_KIT_HOME', str(Path.home() / '.config/routing-kit')))
    try:
        name = json.loads((home / 'profile.json').read_text()).get('owner_name')
    except (OSError, ValueError, AttributeError):
        name = None
    if isinstance(name, str) and name.strip() and len(name.strip()) <= 40:
        return board.safe(name.strip())
    return 'the owner'


def sha(text):
    return hashlib.sha256(text.encode('utf-8', errors='replace')).hexdigest()


def prompt_path(name):
    board.validate_name(name)
    return board.directory() / 'owner-prompts' / (name + '.jsonl')


def entries(name):
    """Well-formed recorded prompts of one session, oldest first (caller holds no board lock)."""
    try:
        with board.locked():
            raw = prompt_path(name).read_text(errors='replace')
    except (OSError, board.InvalidInput):
        return []
    rows = []
    for line in raw.split('\n'):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and all(isinstance(row.get(k), str) for k in ('id', 'time', 'sha256', 'text')):
            rows.append(row)
    return rows


def record(name, text):
    """Append one typed prompt for session `name`; prompts older than 7 days are dropped.

    A prompt over MAX_PROMPT characters is not recorded at all (returns None): cutting it would
    leave a partial last line that could be quoted as if the owner had typed it."""
    if len(text) > MAX_PROMPT:
        return None
    when = board.now()
    entry = dict(id='p-' + uuid.uuid4().hex[:12], time=board.stamp(when), sha256=sha(text), text=text)
    path = prompt_path(name)
    with board.locked(True):
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        kept = []
        try:
            old = path.read_text(errors='replace').split('\n')
        except OSError:
            old = []
        for line in old:
            try:
                row = json.loads(line)
                stamp = board.parse_time(row['time'])
            except (ValueError, KeyError, TypeError):
                continue
            if isinstance(row, dict) and stamp and when - stamp <= KEEP:
                kept.append(line)
        kept.append(json.dumps(entry, ensure_ascii=True))
        tmp = path.with_name(path.name + '.tmp')
        fd = os.open(str(tmp), os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write('\n'.join(kept) + '\n')
        os.replace(str(tmp), str(path))
    return entry


def lines_of(text):
    return [line.strip() for line in text.split('\n')]


def has_run(prompt_text, wanted):
    """True when `wanted` (a list of non-empty lines) is a run of consecutive whole lines of the prompt.

    One linear pass: lines become small integers and the run is looked for with the
    Knuth-Morris-Pratt prefix table, so no pair of line positions is ever tried twice."""
    ids = {}
    have = [ids.setdefault(line, len(ids)) for line in lines_of(prompt_text)]
    want = [ids.get(line, -1) for line in wanted]
    if not want or -1 in want or len(want) > len(have):
        return False
    fail, k = [0] * len(want), 0
    for i in range(1, len(want)):
        while k and want[i] != want[k]:
            k = fail[k - 1]
        if want[i] == want[k]:
            k += 1
        fail[i] = k
    k = 0
    for value in have:
        while k and value != want[k]:
            k = fail[k - 1]
        if value == want[k]:
            k += 1
            if k == len(want):
                return True
    return False


def find(name, quote):
    """The newest recent prompt of `name` holding `quote` as whole lines, and the one-line text to send.

    The entry comes back with "lines" added: the quoted lines the text was joined from."""
    wanted = lines_of(quote)
    if not wanted or any(not line for line in wanted):
        raise board.InvalidInput('an owner quote is one or more whole, non-empty lines of what the owner typed')
    now = board.now()
    for entry in reversed(entries(name)):
        when = board.parse_time(entry['time'])
        if (when and now - when <= QUOTE_WINDOW and sha(entry['text']) == entry['sha256']
                and has_run(entry['text'], wanted)):
            return dict(entry, lines=wanted), ' '.join(wanted)
    raise board.InvalidInput('not a whole-line quote of something the owner typed in this session in the last 24 hours')


def quote_lines(row):
    """The quoted lines a record claims, or None unless they are clean and join to its text."""
    lines = row.get('owner_quote_lines')
    if (not isinstance(lines, list) or not lines or not isinstance(row.get('text'), str)
            or not all(isinstance(line, str) and line and line == line.strip() and '\n' not in line
                       for line in lines)
            or ' '.join(lines) != row['text']):
        return None
    return lines


def verify(row, receiver, cache=None):
    """True when `row` really is a quote of the owner's recorded prompt, addressed to `receiver`.

    Judged on this record alone: nothing here depends on any other record with the same id."""
    if (row.get('owner_quote') is not True or row.get('kind') != 'dm' or row.get('to') != receiver
            or not isinstance(row.get('from'), str) or not board.NAME.fullmatch(row['from'])):
        return False
    prompt_id, proof = row.get('owner_prompt_id'), row.get('owner_prompt_sha256')
    lines = quote_lines(row)
    if not isinstance(prompt_id, str) or not isinstance(proof, str) or lines is None:
        return False
    cache = {} if cache is None else cache
    if row['from'] not in cache:
        cache[row['from']] = entries(row['from'])
    sent = board.parse_time(row.get('time'))
    for entry in cache[row['from']]:
        if entry['id'] != prompt_id:
            continue
        typed = board.parse_time(entry['time'])
        if (entry['sha256'] == proof and sha(entry['text']) == proof and sent is not None
                and typed is not None and sent - typed <= QUOTE_WINDOW
                and has_run(entry['text'], lines)):
            return True
    return False


def record_key(row):
    """A key for exactly this record: the hash of all of its fields, never its board id alone."""
    return sha(json.dumps(row, sort_keys=True, ensure_ascii=True, default=str))


def classify(rows, receiver):
    """{record_key(row): ('quote', None) | ('repeat', first id)} for the owner-quote dms to `receiver`.

    Keyed by the whole record, so two records sharing a board id are told apart. An exact copy of
    an earlier record is never shown as a fresh quote (both are shown as repeats)."""
    out, first, keys, cache = {}, {}, set(), {}
    for row in rows:
        if row.get('owner_quote') is not True or not verify(row, receiver, cache):
            continue
        key = record_key(row)
        if key in keys:
            out[key] = ('repeat', row['id'])
            continue
        keys.add(key)
        same = (row['from'], row['owner_prompt_id'], row['text'])
        if same in first:
            out[key] = ('repeat', first[same])
        else:
            first[same] = row['id']
            out[key] = ('quote', None)
    return out
