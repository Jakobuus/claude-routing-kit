"""One lock for every kit-sync run that writes shared state (sync-state.json and friends)."""
import fcntl
import os
import time


def acquire(kit_home):
    """Take $KIT_HOME/sync.lock exclusively and keep it until the process exits.

    Waits up to KIT_SYNC_LOCK_WAIT seconds (default 30), then raises OSError.
    The lock file stays on disk; the lock itself dies with the process."""
    os.makedirs(kit_home, exist_ok=True)
    fd = os.open(os.path.join(kit_home, 'sync.lock'), os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.monotonic() + float(os.environ.get('KIT_SYNC_LOCK_WAIT', '30'))
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise OSError('another kit-sync is running')
            time.sleep(0.1)
