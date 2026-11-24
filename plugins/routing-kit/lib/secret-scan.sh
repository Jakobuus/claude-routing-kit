#!/bin/bash
# lib/secret-scan.sh — secret_scan PATH...
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers, not run directly. Depends on kit-common
# (kit_require_supported, kit_die) and the shared patterns in secret_patterns.py
# (the same list scripts/privacy-check uses, so kinds don't drift apart).

SCAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCAN_LIB_DIR/../bin/kit-common"

# secret_scan [--credentials-only] PATH... — exits 0 when none hold a secret-shaped
# string, 5 on the first hit. Prints "file:line: kind" for every hit,
# never the matched text itself.
secret_scan() {
  kit_require_supported
  local mode=full
  if [ "${1:-}" = --credentials-only ]; then mode=credentials; shift; fi
  if [ "$#" -eq 0 ]; then
    kit_die 2 "usage: secret_scan PATH..."
  fi

  kit_python3 - "$SCAN_LIB_DIR" "$mode" "$@" <<'PYEOF'
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

# A file named exactly .env.example lists key NAMES for a repo (the owner, 23 Nov 2026:
# "allowed!"). It skips the dotenv filename rule, but its contents are still
# scanned, failing closed. A value passes only if it is empty, an exact placeholder
# token, a number, true/false, or a plain URL (no user:pass@, no query string, no
# long opaque path segment). Any run of 20+ key characters is always a hit.
ENV_EXAMPLE = ".env.example"
ENV_EXAMPLE_LINE_RE = re.compile(r"^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=(.*)$")
ENV_EXAMPLE_PLACEHOLDER_RE = re.compile(
    r"^(?:<[^<>]{1,40}>|your[-_]?(?:api[-_]?)?(?:key|token|secret|value|id)(?:[-_]here)?"
    r"|changeme|change[-_]me|x{3,}|\.\.\.|todo|placeholder|example|true|false|\d{1,6})$",
    re.IGNORECASE,
)
ENV_EXAMPLE_URL_RE = re.compile(r"^[a-z][a-z0-9+.-]*://[A-Za-z0-9.-]+(?::\d{1,5})?(?:/[A-Za-z0-9._~-]{0,19})*/?$",
                                re.IGNORECASE)
ENV_EXAMPLE_LONG_RE = re.compile(r"[A-Za-z0-9_\-+/=]{20,}")


def _env_example_value(raw):
    """Parse a dotenv value. Returns None for an unterminated quote (fail closed)."""
    stripped = raw.strip()
    if stripped[:1] in ("'", '"'):
        end = stripped.find(stripped[0], 1)
        return None if end == -1 else stripped[1:end]
    # '#' starts a comment only after whitespace (incl. "KEY= # note"), not in "KEY=#abc"
    return re.split(r"\s#", raw, maxsplit=1)[0].strip()


def env_example_value_hit(line):
    if line.lstrip().startswith("#"):
        return False
    m = ENV_EXAMPLE_LINE_RE.match(line)
    if not m:
        return bool(line.strip())  # anything that is not KEY=value or a comment fails closed
    value = _env_example_value(m.group(1))
    if value is None:
        return True
    if value == "":
        return False
    if ENV_EXAMPLE_LONG_RE.search(value.replace("://", " ").replace(".", " ")):
        return True
    return not (ENV_EXAMPLE_PLACEHOLDER_RE.match(value) or ENV_EXAMPLE_URL_RE.match(value))

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
                if base == ENV_EXAMPLE and kind == "dotenv-file":
                    continue
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
                        if base == ENV_EXAMPLE and env_example_value_hit(line):
                            hits.append("%s:%d: dotenv-example-value" % (path, lineno))
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
