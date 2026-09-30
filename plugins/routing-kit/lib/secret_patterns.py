# secret_patterns.py — shared secret-shaped-string patterns.
#
# Used by both scripts/privacy-check (repo hygiene, dev-only) and
# plugins/routing-kit/lib/secret-scan.sh (secret_scan, ships with the
# plugin). Lives here, inside the plugin, so secret-scan.sh never reaches
# outside the plugin folder for something it ships with; privacy-check
# reaches in to reuse it instead of duplicating the list.
#
# Token patterns match at a word boundary (start of line, or a
# non-alphanumeric char before the token) and require a minimum suffix
# length, so near-miss words like "ask-advisers" or "risk-free" pass while
# a real-looking key with a long enough suffix after the prefix is caught.
import re

NOT_ALNUM_BEFORE = r"(?<![A-Za-z0-9])"

GENERIC = [
    ("home-path", re.compile(r"/Users/[A-Za-z0-9._-]+")),
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
    ("anthropic-key", re.compile(NOT_ALNUM_BEFORE + r"sk-ant-[A-Za-z0-9_-]+")),
    ("api-key", re.compile(NOT_ALNUM_BEFORE + r"sk-[A-Za-z0-9_-]{8,}")),
    ("github-token", re.compile(NOT_ALNUM_BEFORE + r"ghp_[A-Za-z0-9_-]{8,}")),
    ("github-pat", re.compile(NOT_ALNUM_BEFORE + r"github_pat_[A-Za-z0-9_-]{8,}")),
    ("aws-key", re.compile(NOT_ALNUM_BEFORE + r"AKIA[A-Z0-9]{12,}")),
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("slack-token", re.compile(NOT_ALNUM_BEFORE + r"xox[bp]-[A-Za-z0-9_-]{8,}")),
]

# Literal allowlisted placeholders that must NOT trip the generic patterns.
ALLOWED_LITERALS = [
    "/Users/<you>",
    "you@example.com",
]


def is_allowed(line, start, end, matched_text):
    for lit in ALLOWED_LITERALS:
        if matched_text == lit:
            return True
        # Allow when the match is a substring of an allowed literal context,
        # e.g. "/Users/<you>/x" contains "/Users/<you>" as a prefix.
        idx = line.find(lit)
        if idx != -1 and idx <= start and (idx + len(lit)) >= end:
            return True
    return False
