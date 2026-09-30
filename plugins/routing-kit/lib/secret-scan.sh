#!/bin/bash
# lib/secret-scan.sh — secret_scan PATH...
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers, not run directly. Depends on kit-common
# (kit_require_macos, kit_die) and the shared patterns in secret_patterns.py
# (the same list scripts/privacy-check uses, so kinds don't drift apart).

SCAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCAN_LIB_DIR/../bin/kit-common"

# secret_scan [--credentials-only] PATH... — exits 0 when none hold a secret-shaped
# string, 5 on the first hit. Prints "file:line: kind" for every hit,
# never the matched text itself.
secret_scan() {
  kit_require_macos
  local mode=full
  if [ "${1:-}" = --credentials-only ]; then mode=credentials; shift; fi
  if [ "$#" -eq 0 ]; then
    kit_die 2 "usage: secret_scan PATH..."
  fi

  /usr/bin/python3 - "$SCAN_LIB_DIR" "$mode" "$@" <<'PYEOF'
import fnmatch
import os
import re
import sys

lib_dir = sys.argv[1]
mode = sys.argv[2]
paths = sys.argv[3:]

sys.path.insert(0, lib_dir)
from secret_patterns import GENERIC, is_allowed

FILENAME_KINDS = [
    ("dotenv-file", ".env*"),
    ("ssh-key-file", "id_rsa*"),
    ("pem-file", "*.pem"),
    ("p12-file", "*.p12"),
]

PASSWORD_RE = re.compile(r"password\s*[:=]\s*\S{6,}")

hits = []


def _raise(exc):
    raise exc


def iter_files(root):
    if not os.path.exists(root):
        raise OSError("no such path: %s" % root)
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root, onerror=_raise):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in filenames:
            yield os.path.join(dirpath, fn)


# A scan that can't actually read everything it was asked to must refuse,
# never report "clean" -- a nonexistent root, a permission error while
# walking, or a file it can't open are all reasons it did NOT prove the
# content secret-free, so each becomes its own hit (exit 5, same as a real
# match) instead of being silently skipped.
for root in paths:
    try:
        for path in iter_files(root):
            base = os.path.basename(path)
            for kind, pattern in FILENAME_KINDS:
                if fnmatch.fnmatch(base, pattern):
                    hits.append("%s:1: %s" % (path, kind))
                    break

            try:
                with open(path, "r", errors="ignore") as f:
                    for lineno, line in enumerate(f, start=1):
                        for name, pattern in GENERIC:
                            if mode == 'credentials' and name in ('home-path', 'email'):
                                continue
                            for m in pattern.finditer(line):
                                if is_allowed(line, m.start(), m.end(), m.group(0)):
                                    continue
                                hits.append("%s:%d: %s" % (path, lineno, name))
                        for m in PASSWORD_RE.finditer(line):
                            hits.append("%s:%d: password" % (path, lineno))
            except OSError:
                hits.append("%s: read-error" % path)
    except OSError:
        hits.append("%s: scan-error" % root)

if hits:
    for h in hits:
        print(h)
    sys.exit(5)

sys.exit(0)
PYEOF
  code=$?
  return $code
}
