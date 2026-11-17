"""Convert a repository's shared agent rules transactionally."""
import fcntl
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from contextlib import redirect_stdout
from io import StringIO
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
import board
import board_claims


def main():
    args = sys.argv[1:]
    dry = '--dry-run' in args
    force = '--force' in args
    args = [a for a in args if a not in ('--dry-run', '--force')]
    if len(args) != 1 or args[0].startswith('--'):
        raise ValueError('usage: kit-sync repo PATH [--dry-run] [--force]')
    root = Path(args[0]).resolve()

    def git(*argv):
        return subprocess.check_output(['git', '-C', str(root)] + list(argv), stderr=subprocess.PIPE)

    root = Path(os.fsdecode(git('rev-parse', '--show-toplevel')).strip())
    git_dir = Path(os.fsdecode(git('rev-parse', '--git-dir')).strip())
    if not git_dir.is_absolute():
        git_dir = root / git_dir
    lock = open(git_dir / 'kit-sync.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX)
    start_head = git('rev-parse', 'HEAD')
    if git('status', '--porcelain', '--untracked-files=all'):
        print('refused: working tree is dirty')
        return 4
    # The listing owns claim expiry and strike handling; do not mark anything seen.
    listing = StringIO()
    with redirect_stdout(listing):
        board_claims.claims(SimpleNamespace(repo=str(root)))
    try:
        name = board.identity()[0]
    except board.InvalidInput:
        name = 'kit-sync'
    if not force:
        for line in listing.getvalue().splitlines():
            claimer = line.split(' ', 2)[2].split(': ', 1)[0]
            if claimer != name:
                print('refused: open claim by ' + line.split(' ', 2)[2])
                return 3
    updates = {}
    a, c = root / 'AGENTS.md', root / 'CLAUDE.md'
    for p in (a, c):
        if p.is_symlink():
            raise ValueError('rules files must be regular files')

    def ignored(p):
        # git check-ignore exits 0 when the path is ignored, 1 when it is not.
        result = subprocess.run(['git', '-C', str(root), 'check-ignore', '-q', '--', str(p.relative_to(root))],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode not in (0, 1):
            raise subprocess.CalledProcessError(result.returncode, result.args, stderr=result.stderr)
        return result.returncode == 0

    def tracked(p):
        return bool(git('ls-files', '--', str(p.relative_to(root))))

    # Never commit what the repo keeps out of git on purpose.
    for p in (a, c):
        if (p.exists() and not tracked(p)) or ignored(p):
            print('refused: ' + p.name + ' is ignored or not tracked by git')
            return 4
    old_a = a.read_bytes() if a.exists() else None
    old_c = c.read_bytes() if c.exists() else None
    merged = old_a
    if old_c is not None and old_c != b'@AGENTS.md\n':
        if old_a is None:
            merged = old_c
        elif old_a != old_c:
            def sections(data):
                parts = []
                current = b''
                fence = None
                for line in data.splitlines(keepends=True):
                    if fence is None:
                        if re.match(br'^#{1,6} +', line):
                            parts.append(current)
                            current = b''
                        opening = re.match(br'^ {0,3}(`{3,}|~{3,})(.*)', line)
                        if opening and not (opening[1].startswith(b'`') and b'`' in opening[2]):
                            fence = opening[1]
                    elif re.match(br'^ {0,3}' + fence[:1] + br'{' + str(len(fence)).encode() + br',}[ \t]*[\r\n]*$', line):
                        fence = None
                    current += line
                parts.append(current)
                return parts
            existing = set(sections(old_a))
            cleaned = b''.join(line for line in old_c.splitlines(keepends=True)
                               if line.strip() != b'@AGENTS.md')
            extra = [section for section in sections(cleaned) if section and section not in existing]
            if extra:
                merged = old_a + (b'\n' if old_a and not old_a.endswith(b'\n') else b'')
                merged += b'## From CLAUDE.md\n' + b''.join(extra)
    if merged is not None:
        if merged != old_a:
            updates[a] = merged
        if old_c != b'@AGENTS.md\n':
            updates[c] = b'@AGENTS.md\n'
    moves = []
    skills = root / '.claude/skills'
    if skills.is_dir():
        for src in sorted(skills.iterdir()):
            if src.is_dir() and not src.is_symlink():
                dst = root / '.agents/skills' / src.name
                inside = [f for f in src.rglob('*') if os.path.lexists(f) and (f.is_symlink() or f.is_file())]
                if not tracked(src) or ignored(src) or ignored(dst) or any(ignored(f) for f in inside) \
                        or any(not tracked(f) for f in inside) \
                        or any(ignored(dst / f.relative_to(src)) for f in inside):
                    print('skipped skill ' + src.name + ': not fully tracked by git, or ignored')
                    continue
                if os.path.lexists(dst):
                    raise ValueError('skill destination already exists: ' + str(dst))
                moves.append((src, dst))
    if not updates and not moves:
        print('no changes')
        return 0
    if dry:
        for p in updates:
            print('would write ' + str(p.relative_to(root)))
        for src, dst in moves:
            print('would move ' + str(src.relative_to(root)) + ' to ' + str(dst.relative_to(root)))
        return 0
    expected = [str((dst / f.relative_to(src)).relative_to(root))
                for src, dst in moves for f in src.rglob("*") if os.path.lexists(f) and (f.is_symlink() or f.is_file())]
    undo = []
    created = []

    def write(p, data):
        fd, name = tempfile.mkstemp(prefix='.' + p.name + '.', dir=str(p.parent))
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(data)
            if p.exists():
                os.chmod(name, p.stat().st_mode)
            os.replace(name, p)
        finally:
            if os.path.lexists(name):
                os.unlink(name)

    try:
        for p, data in updates.items():
            original = p.read_bytes() if p.exists() else None
            undo.append(('file', p, original))
            write(p, data)
        for src, dst in moves:
            for parent in (dst.parent.parent, dst.parent):
                if not parent.exists():
                    parent.mkdir()
                    created.append(parent)
            os.rename(src, dst)
            undo.append(('move', src, dst))
            fd, name = tempfile.mkstemp(prefix='.' + src.name + '.', dir=str(src.parent))
            os.close(fd)
            os.unlink(name)
            try:
                os.symlink(os.path.relpath(dst, src.parent), name)
                os.replace(name, src)
            finally:
                if os.path.lexists(name):
                    os.unlink(name)
        paths = [str(p.relative_to(root)) for p in updates]
        for src, dst in moves:
            paths.extend([str(src.relative_to(root)), str(dst.relative_to(root))])
        git('add', '--', *paths)
        staged = set(os.fsdecode(git('diff', '--cached', '--name-only', '-z')).split('\0'))
        if not set(expected) <= staged or git('rev-parse', 'HEAD') != start_head:
            raise RuntimeError('refused: repository changed during conversion')
        git('commit', '-m', 'Rules in AGENTS.md for all agents (routing kit)', '--', *paths)
    except BaseException as exc:
        for kind, p, original in reversed(undo):
            if kind == 'move':
                if p.is_symlink():
                    p.unlink()
                os.rename(original, p)
            elif original is None:
                if p.exists():
                    p.unlink()
            else:
                write(p, original)
        for p in reversed(created):
            p.rmdir()
        git('reset', '-q', 'HEAD', '--', *paths) if 'paths' in locals() else None
        if isinstance(exc, RuntimeError):
            print(str(exc))
            return 4
        raise
    # Standalone conversions also have a stable identity when no session is set.
    try:
        board.identity()
    except board.InvalidInput:
        os.environ['KIT_BOARD_NAME'] = name
    sha = os.fsdecode(git('rev-parse', 'HEAD')).strip()
    board.append(board.make_record(
        "kit-sync repo converted this repo's rule files (commit " + sha + ")",
        str(root)))
    print('converted rules and skills')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        detail = os.fsdecode(exc.stderr).strip() if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else str(exc)
        print('refused: ' + ' '.join(detail.splitlines()), file=sys.stderr)
        sys.exit(2)
