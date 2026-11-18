#!/usr/bin/env python3
"""Retained build copies: move one in, list them, prune them.

Everything here works through an open descriptor of the retained folder, never through its path
again, and holds a lock on it: a folder or a copy that is swapped for something else while this
runs is not followed, and two runs never work on the same name at once.

  retained.py retain KIT_HOME RUN_DIR WHY    move RUN_DIR/wt in; prints the new path
  retained.py list KIT_HOME
  retained.py prune KIT_HOME DAYS
"""
import fcntl
import os
import re
import stat
import sys
import time

TRASH = '.trash'
NOFOLLOW_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
MAX_AT_DIGITS = 12


def open_root(kit_home, create):
    """The retained folder as a locked descriptor. A link in its place is refused."""
    path = os.path.join(kit_home, 'retained')
    if create:
        os.makedirs(path, exist_ok=True)
    fd = os.open(path, NOFOLLOW_DIR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd, path


def read_note(root_fd, name):
    """The .why note of a copy as a dict; {} when it is missing, a link, or unreadable."""
    try:
        fd = os.open(name + '.why', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=root_fd)
    except OSError:
        return {}
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return {}
        text = os.read(fd, 65536).decode('utf-8', 'replace')
    except OSError:
        return {}
    finally:
        os.close(fd)
    note = {}
    for line in text.splitlines():
        key, sep, value = line.partition('=')
        if sep and key not in note:
            note[key] = value
    return note


def retained_at(note, now):
    """When the copy was retained, or None. Only a plain, bounded number of seconds that is not
    in the future counts; anything else is an unknown age, and an unknown age is never pruned."""
    value = note.get('retained_at', '')
    if not re.fullmatch(r'[1-9][0-9]{0,%d}' % (MAX_AT_DIGITS - 1), value):
        return None
    at = int(value)
    return at if at <= now else None


def copies(root_fd):
    """Names of the retained copies: real folders directly in the retained folder."""
    names = []
    for name in sorted(os.listdir(root_fd)):
        if name.startswith('.') or name.endswith('.why'):
            continue
        try:
            st = os.lstat(name, dir_fd=root_fd)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode):
            names.append(name)
    return names


def tree_size(parent_fd, name):
    """Bytes in a folder, links not followed."""
    total = 0
    try:
        fd = os.open(name, NOFOLLOW_DIR, dir_fd=parent_fd)
    except OSError:
        return 0
    try:
        for entry in os.listdir(fd):
            try:
                st = os.lstat(entry, dir_fd=fd)
            except OSError:
                continue
            total += tree_size(fd, entry) if stat.S_ISDIR(st.st_mode) else st.st_size
    except OSError:
        pass
    finally:
        os.close(fd)
    return total


def make_writable(parent_fd, name, mode):
    """Give the owner full access to a folder that lstat just showed to be a folder."""
    try:
        os.chmod(name, stat.S_IMODE(mode) | 0o700, dir_fd=parent_fd, follow_symlinks=False)
    except NotImplementedError:
        try:
            os.chmod(name, stat.S_IMODE(mode) | 0o700, dir_fd=parent_fd)
        except OSError:
            pass
    except OSError:
        pass


def delete_tree(parent_fd, name):
    """Delete a folder below an open descriptor. Links are removed, never followed."""
    make_writable(parent_fd, name, os.lstat(name, dir_fd=parent_fd).st_mode)
    fd = os.open(name, NOFOLLOW_DIR, dir_fd=parent_fd)
    try:
        for entry in os.listdir(fd):
            st = os.lstat(entry, dir_fd=fd)
            if stat.S_ISDIR(st.st_mode):
                delete_tree(fd, entry)
            else:
                os.unlink(entry, dir_fd=fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=parent_fd)


def before_move(root_fd, name):
    """Nothing. The moment between the checks and the move, named so a test can act in it."""


def retain(kit_home, run_dir, why):
    run_dir = os.path.realpath(run_dir)
    source = os.path.join(run_dir, 'wt')
    if os.path.islink(source) or not os.path.isdir(source):
        return 1
    root_fd, root = open_root(kit_home, True)
    try:
        base = os.path.basename(run_dir)
        name, n = base, 1
        while True:
            try:
                os.lstat(name, dir_fd=root_fd)
            except FileNotFoundError:
                try:
                    os.lstat(name + '.why', dir_fd=root_fd)
                except FileNotFoundError:
                    break
            n += 1
            name = '%s-%d' % (base, n)
        why = ' '.join((why or 'run ended').split())
        note = 'retained_at=%d\nretained=%s\nfrom=%s\nwhy=%s\n' % (
            time.time(), time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), source, why)
        fd = os.open(name + '.why', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
        try:
            os.write(fd, note.encode())
        finally:
            os.close(fd)
        try:
            # One rename: never a copy-and-delete, and never onto an existing name.
            os.rename(source, name, dst_dir_fd=root_fd)
        except OSError:
            os.unlink(name + '.why', dir_fd=root_fd)
            return 1
        print(os.path.join(os.path.realpath(root), name))
        return 0
    finally:
        os.close(root_fd)


def list_copies(kit_home):
    path = os.path.join(kit_home, 'retained')
    try:
        root_fd, _ = open_root(kit_home, False)
    except OSError:
        print('kit-retained: 0 retained, 0 KB in %s' % path)
        return 0
    try:
        now, total, names = int(time.time()), 0, copies(root_fd)
        for name in names:
            note = read_note(root_fd, name)
            at = retained_at(note, now)
            kb = (tree_size(root_fd, name) + 1023) // 1024
            total += kb
            print('%s\t%d KB\t%s\t%s' % ('?' if at is None else '%dd' % ((now - at) // 86400), kb, name,
                                         note.get('why') or 'no reason recorded'))
        print('kit-retained: %d retained, %d KB in %s' % (len(names), total, path))
        return 0
    finally:
        os.close(root_fd)


def prune(kit_home, days):
    try:
        root_fd, _ = open_root(kit_home, False)
    except OSError:
        print('kit-retained: pruned 0, kept 0')
        return 0
    pruned = kept = failed = 0
    try:
        now = int(time.time())
        cutoff = now - days * 86400
        for name in copies(root_fd):
            try:
                seen = os.lstat(name, dir_fd=root_fd)
            except OSError:
                continue
            at = retained_at(read_note(root_fd, name), now)
            if at is None:
                print('kit-retained: age unknown, not pruned: %s' % name, file=sys.stderr)
                kept += 1
                continue
            if at >= cutoff:
                kept += 1
                continue
            before_move(root_fd, name)
            # Take the copy out of reach first, into a private folder, then look at what was
            # taken: it must be the very folder whose age was read. Only that is deleted.
            try:
                os.mkdir(TRASH, 0o700, dir_fd=root_fd)
            except FileExistsError:
                pass
            trash_fd = os.open(TRASH, NOFOLLOW_DIR, dir_fd=root_fd)
            try:
                held = '%s.%d.%d' % (name, os.getpid(), pruned + kept + failed)
                os.rename(name, held, src_dir_fd=root_fd, dst_dir_fd=trash_fd)
                got = os.lstat(held, dir_fd=trash_fd)
                same = stat.S_ISDIR(got.st_mode) and (got.st_dev, got.st_ino) == (seen.st_dev, seen.st_ino)
                if not same or retained_at(read_note(root_fd, name), now) != at:
                    # Not what was checked: put it back where it was and leave it.
                    try:
                        os.lstat(name, dir_fd=root_fd)
                        print('kit-retained: %s changed while pruning; what was there is in %s/%s'
                              % (name, TRASH, held), file=sys.stderr)
                    except FileNotFoundError:
                        os.rename(held, name, src_dir_fd=trash_fd, dst_dir_fd=root_fd)
                        print('kit-retained: %s changed while pruning; not pruned' % name, file=sys.stderr)
                    kept += 1
                    continue
                try:
                    delete_tree(trash_fd, held)
                except OSError as error:
                    print('kit-retained: could not delete %s: %s' % (name, error), file=sys.stderr)
                    failed += 1
                    continue
                try:
                    os.unlink(name + '.why', dir_fd=root_fd)
                except OSError:
                    pass
                print('pruned %s' % name)
                pruned += 1
            except OSError as error:
                print('kit-retained: could not prune %s: %s' % (name, error), file=sys.stderr)
                failed += 1
            finally:
                os.close(trash_fd)
        try:
            os.rmdir(TRASH, dir_fd=root_fd)
        except OSError:
            pass
    finally:
        os.close(root_fd)
    print('kit-retained: pruned %d, kept %d' % (pruned, kept))
    return 4 if failed else 0


def main(argv):
    if len(argv) == 5 and argv[1] == 'retain':
        return retain(argv[2], argv[3], argv[4])
    if len(argv) == 3 and argv[1] == 'list':
        return list_copies(argv[2])
    if len(argv) == 4 and argv[1] == 'prune' and re.fullmatch(r'[0-9]{1,6}', argv[3]):
        days = int(argv[3], 10)
        if days >= 1:
            return prune(argv[2], days)
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except OSError as error:
        print('kit-retained: %s' % error, file=sys.stderr)
        sys.exit(4)
