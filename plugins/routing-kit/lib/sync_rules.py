"""Transactional synchronization of global agent rules.

The one invariant: bytes outside our markers are never removed. Text flows only from the source into our block.
Sync replaces the block (or appends one); undo removes the block and nothing else. No backups are read or written."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync_lock  # noqa: E402

START = b'<!-- routing-kit:rules:start -->\n'
END = b'<!-- routing-kit:rules:end -->\n'


def read(p):
    return p.read_bytes() if p.exists() else None


def split(t):
    t = t or b''
    if not (START.strip() in t or END.strip() in t):
        return t, None, b''
    if t.count(START) != 1 or t.count(END) != 1:
        raise ValueError('misplaced or duplicated rules markers')
    a, rest = t.split(START)
    b, end, c = rest.partition(END)
    if not end or END in a or (a and not a.endswith(b'\n')):
        raise ValueError('misplaced rules markers')
    return a, b, c


def sha(b):
    return hashlib.sha256(b).hexdigest()


KEY = b'project_doc_max_bytes'
LINE = KEY + b' = 65536\n'
BOM = b'\xef\xbb\xbf'


def guard(old, new, block):
    """Refuse a write that changes any byte outside our block. The one allowed change: a newline added in front of a
    block appended to a file that did not end in one."""
    oa, ob, oc = split(old)
    na, nb, nc = split(new)
    allowed = {oa + oc} | ({oa + oc + b'\n'} if ob is None and block else set())
    if (nb is not None) != block or na + nc not in allowed:
        raise ValueError('refusing to write: it would change text outside the rules block')


def config_edit(text):
    """text with our key line on top of it; the same text when our exact line is already there.
    ValueError = hands off (the key spelled any other way, or a BOM): the caller prints the hint.
    The top of a TOML file is always top level."""
    if LINE.rstrip() in (l.rstrip(b'\r') for l in text.split(b'\n')):
        return text
    if KEY in text or text.startswith(BOM):
        raise ValueError('project_doc_max_bytes is spelled or placed in a way kit-sync does not touch')
    return LINE + text


def main():
    ap = argparse.ArgumentParser()
    for flag in ('dry-run', 'undo', 'force'):
        ap.add_argument('--' + flag, action='store_true')
    for agent in ('claude', 'codex', 'gemini'):
        ap.add_argument('--home-' + agent)
    ap.add_argument('--private-rules')
    args = ap.parse_args()
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get('ROUTING_KIT_HOME', str(Path.home() / '.config/routing-kit')))
    statepath = home / 'sync-state.json'
    sync_lock.acquire(home)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    homes = {a: Path(getattr(args, 'home_' + a) or (os.environ.get('CODEX_HOME') if a == 'codex' else None) or str(Path.home() / ('.' + a))) for a in ('claude', 'codex', 'gemini')}
    override = homes['codex'] / 'AGENTS.override.md'
    targets = {'claude': homes['claude'] / 'CLAUDE.md', 'codex': override if override.exists() and override.stat().st_size else homes['codex'] / 'AGENTS.md', 'gemini': homes['gemini'] / 'AGENTS.md'}
    config = homes['codex'] / 'config.toml'
    private = Path(args.private_rules) if args.private_rules else home / 'private/rules.md'
    # Folders above the home folder belong to the system (/tmp on a Mac, /home on Fedora Atomic are
    # symlinks); only the target and folders from the home folder down must be real.
    above_home = set(Path.home().parents)
    def check(p):
        for q in [p] + list(p.parents):
            if q not in above_home and q.is_symlink():
                raise ValueError('symlink: ' + str(q))
        if p.exists() and not p.is_file():
            raise ValueError('not a regular file: ' + str(p))
    # The private rules file is only read, so it may be a symlink (e.g. into the owner's own git).
    for p in list(targets.values()) + [override, config, statepath]:
        check(p)
    if private.is_symlink() and not private.exists():
        raise ValueError('private rules link points to a missing file: ' + str(private))
    state = json.loads((read(statepath) or b'{}').decode())
    # state: {path: sha of the block we wrote}; records from older versions carried more, only the sha is used
    records = {k: v['sha256'] if isinstance(v, dict) else v for k, v in state.get('files', {}).items()}
    plan, notes = {}, []

    def ours(p, b):
        """Refuse a block we did not write or that was edited since, unless --force."""
        if args.force:
            return
        rec = records.get(str(p))
        if rec is None:
            raise ValueError('rules block in %s is not recorded as written by kit-sync; kit-sync rules %s--force overwrites it' % (p, '--undo ' if args.undo else ''))
        if sha(b) != rec:
            raise ValueError('edited by hand: %s; kit-sync rules %s--force overwrites it' % (p, '--undo ' if args.undo else ''))

    if args.undo:
        for p in dict.fromkeys([Path(n) for n in records] + list(targets.values())):
            check(p)
            cur = read(p)
            if cur is None:
                continue
            a, b, c = split(cur)
            if b is None:
                continue
            ours(p, b)
            new = a + c
            guard(cur, new, False)
            plan[p] = new or None
        records = {}
        if LINE.rstrip() in (l.rstrip(b'\r') for l in (read(config) or b'').split(b'\n')):
            notes.append('left project_doc_max_bytes in %s; remove it by hand if you want' % config)
    else:
        table = subprocess.check_output([str(root / 'bin/kit-routing-table'), '--profile', str(home / 'profile.json')])
        with tempfile.TemporaryDirectory() as td:
            t = Path(td) / 'table'
            t.write_bytes(table)
            source = read(private) or b''
            rendered = {a: subprocess.check_output([sys.executable, str(root / 'lib/render_rules.py'), '--agent', a, '--kit-rules', str(root / 'rules/RULES.md'), '--private-rules', '-', '--table', str(t), '--profile', str(home / 'profile.json'), '--role', 'lead'], input=source) for a in targets}
        for agent, p in targets.items():
            old = read(p)
            a, b, c = split(old)
            block = START + rendered[agent] + END
            if b is not None:
                ours(p, b)
                new = a + block + c
            else:
                new = a + (b'\n' if a and not a.endswith(b'\n') else b'') + block
            guard(old, new, True)
            plan[p] = new
            records[str(p)] = sha(rendered[agent])
        text = read(config) or b''
        try:
            plan[config] = config_edit(text)
            assert plan[config].endswith(text)
        except ValueError:
            print('set project_doc_max_bytes = 65536 in %s yourself' % config)
    for key in ('undo', 'cfg'):
        state.pop(key, None)
    if records:
        state['files'] = records
    else:
        state.pop('files', None)
    # targets and config first, state last
    plan = {p: d for p, d in plan.items() if read(p) != d}
    if state or statepath.exists():
        new_state = (json.dumps(state, indent=2) + '\n').encode()
        if read(statepath) != new_state:
            plan[statepath] = new_state
    if not plan:
        print('no changes')
        return
    if args.dry_run:
        for p, data in plan.items():
            print(p)
            print(''.join(difflib.unified_diff((read(p) or b'').decode(errors='replace').splitlines(True), (data or b'').decode(errors='replace').splitlines(True), fromfile=str(p), tofile=str(p))))
        return
    apply_plan(plan, check)
    for note in notes:
        print(note)


def apply_plan(plan, check):
    temps, originals, moved, dirs = {}, {}, [], []
    try:
        for p, data in plan.items():
            check(p)
            parent = p.parent
            while not parent.exists():
                parent = parent.parent
            if not parent.stat().st_mode & 0o222:
                raise ValueError('not writable: ' + str(parent))
        for p, data in plan.items():
            missing = []
            parent = p.parent
            while not parent.exists():
                missing.append(parent)
                parent = parent.parent
            for parent in reversed(missing):
                parent.mkdir()
                dirs.append(parent)
            originals[p] = read(p)
            if data is not None:
                fd, name = tempfile.mkstemp(prefix='.routing-kit.', dir=str(p.parent))
                temps[p] = Path(name)
                with os.fdopen(fd, 'wb') as f:
                    f.write(data)
                if p.exists():
                    os.chmod(name, p.stat().st_mode & 0o777)
        for p, data in plan.items():
            moved.append(p)
            if data is None:
                p.unlink(missing_ok=True)
            else:
                os.replace(temps[p], p)
    except BaseException:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        for p in reversed(moved):
            try:
                if originals[p] is None:
                    p.unlink(missing_ok=True)
                else:
                    fd, name = tempfile.mkstemp(dir=str(p.parent))
                    with os.fdopen(fd, 'wb') as f:
                        f.write(originals[p])
                    os.replace(name, p)
            except OSError as exc:
                print('could not roll back %s: %s' % (p, exc), file=sys.stderr)
        raise
    finally:
        for p in temps.values():
            p.unlink(missing_ok=True)
        for p in reversed(dirs):
            try:
                p.rmdir()
            except OSError:
                pass


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('interrupted; changes rolled back', file=sys.stderr)
        sys.exit(130)
