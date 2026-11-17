#!/usr/bin/env python3
"""guide_schema.py -- validate guide/guide.json (the field-guide facts).

Usage:  python3 -I guide_schema.py FILE [DOMAINS_FILE]

Exit 0 when valid (warnings go to stderr as "warning: PATH: ..."), exit 1
with one "PATH: problem" line per violation on stdout, exit 2 on usage or an
unreadable file. Python 3.9 stdlib only.

Every string in the file ends up in a document an agent reads, so text is
held to a narrow shape: one short line of plain words. No backticks, URLs,
HTML or instruction-like phrases. Sources are https URLs on a host listed in
guide/source-domains.txt; a null source is a warning, not an error (first
release).
"""

import json
import math
import os
import re
import sys
from urllib.parse import urlsplit

MAX_TEXT = 400
MAX_URL = 300
MAX_PRICE = 1e9

# Case-insensitive substrings that make a text field look like an instruction.
INSTRUCTION_PATTERNS = (
    "ignore ",
    "disregard",
    "you must",
    "run the",
    "execute",
    "system prompt",
    "curl ",
    "sudo ",
)

MODEL_ID_RE = re.compile(r"[a-z0-9][a-z0-9.-]{2,60}")
DATE_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
URL_IN_TEXT_RE = re.compile(r"[a-zA-Z][a-zA-Z0-9+.-]*://|www\.")
HTML_RE = re.compile(r"<\s*/?\s*[a-zA-Z!?]|&[a-zA-Z#][a-zA-Z0-9]*;")
# Control characters, C1 controls, Unicode line separators and lone surrogates.
CONTROL_RE = re.compile("[\\x00-\\x1f\\x7f-\\x9f\\u2028\\u2029\\ud800-\\udfff]")
SAFE_URL_RE = re.compile(r"[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]+")

FAMILIES = ("claude", "codex", "gemini")
RUN_BY = ("independent", "vendor")


def is_finite(value):
    """True for an int or float that is a normal finite number."""
    try:
        return math.isfinite(float(value))
    except OverflowError:
        return False


def load_domains(path):
    """Host names from a one-per-line file; '#' starts a comment."""
    hosts = set()
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip().lower()
            if line:
                hosts.add(line)
    return hosts


def text_problems(value):
    """Reasons a text field is refused (empty list = fine)."""
    if not isinstance(value, str):
        return ["must be a string"]
    problems = []
    if not value.strip():
        problems.append("is empty")
    if len(value) > MAX_TEXT:
        problems.append("is longer than %d characters (%d)" % (MAX_TEXT, len(value)))
    if CONTROL_RE.search(value):
        problems.append("is not one plain line (control character or line break)")
    if "`" in value:
        problems.append("contains a backtick")
    if URL_IN_TEXT_RE.search(value):
        problems.append("contains a URL")
    if HTML_RE.search(value):
        problems.append("contains HTML")
    lowered = value.lower()
    for pat in INSTRUCTION_PATTERNS:
        if pat in lowered:
            problems.append("contains the instruction-like phrase %r" % pat)
    return problems


class Checker(object):
    def __init__(self, domains):
        self.domains = domains
        self.errors = []
        self.warnings = []

    def err(self, path, msg):
        self.errors.append("%s: %s" % (path, msg))

    def warn(self, path, msg):
        self.warnings.append("%s: %s" % (path, msg))

    # -- leaf checks ---------------------------------------------------------
    def text(self, path, value, optional=False):
        if value is None and optional:
            return
        for p in text_problems(value):
            self.err(path, p)

    def source(self, path, value):
        if value is None:
            self.warn(path, "no source (null)")
            return
        if not isinstance(value, str):
            self.err(path, "source must be an https URL or null")
            return
        if (len(value) > MAX_URL or CONTROL_RE.search(value)
                or not SAFE_URL_RE.fullmatch(value)):
            self.err(path, "source is not a plain URL (odd characters or too long)")
            return
        if not value.startswith("https://"):
            self.err(path, "source must start with https://")
            return
        try:
            parts = urlsplit(value)
            host = (parts.hostname or "").lower()
            port = parts.port
        except ValueError as e:
            self.err(path, "source is not a valid URL (%s)" % str(e).splitlines()[0])
            return
        if "@" in parts.netloc or port is not None:
            self.err(path, "source must not carry user info or a port")
            return
        if host not in self.domains:
            self.err(path, "source host %r is not in source-domains.txt" % host)

    def sources(self, path, value):
        if not isinstance(value, list):
            self.err(path, "must be a list of https URLs")
            return
        if not value:
            self.warn(path, "no source (empty list)")
        for i, s in enumerate(value):
            if s is None:
                self.err("%s[%d]" % (path, i), "source must be an https URL")
            else:
                self.source("%s[%d]" % (path, i), s)

    def price(self, path, value):
        if value is None:
            return
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            self.err(path, "must be a number >= 0 or null")
        elif not is_finite(value):
            self.err(path, "must be a finite number (no NaN, Infinity or huge values)")
        elif value < 0 or value > MAX_PRICE:
            self.err(path, "must be a number between 0 and %g or null" % MAX_PRICE)

    def keys(self, path, obj, required, optional):
        if not isinstance(obj, dict):
            self.err(path, "must be an object")
            return False
        for k in required:
            if k not in obj:
                self.err("%s.%s" % (path, k), "is missing")
        for k in obj:
            if k not in required and k not in optional:
                self.err("%s.%s" % (path, k), "is not an allowed field")
        return True

    def items(self, path, value):
        if not isinstance(value, list):
            self.err(path, "must be a list")
            return []
        return list(enumerate(value))

    # -- sections ------------------------------------------------------------
    def media(self, rows):
        jobs = ("images image-editing logo-svg layouts text-to-video image-to-video "
                "video-editing avatars 3d-code 3d-mesh usdz voiceover voice-cloning "
                "transcription music ocr translation ui-mockups upscaling vectorising "
                "background-removal deep-research video-understanding audio-understanding").split()
        products = ("chatgpt", "google-ai-pro", "claude", "canva-connector",
                    "figma-connector", "local")
        seen = set()

        def scan(path, value):
            if isinstance(value, str) and "sandbox" in value.lower():
                self.err(path, "contains sandbox")
            elif isinstance(value, dict):
                for k, v in value.items():
                    scan(path + "." + k, k)
                    scan(path + "." + k, v)
            elif isinstance(value, list):
                for i, v in enumerate(value):
                    scan("%s[%d]" % (path, i), v)

        for i, row in self.items("media", rows):
            job = row.get("job") if isinstance(row, dict) else None
            p = "media[%d](%s)" % (i, job)
            scan(p, row)
            if not self.keys(p, row, ("job", "label", "match", "options",
                                      "best_overall", "note"), ()):
                continue
            if not isinstance(job, str) or job not in jobs:
                self.err(p + ".job", "unknown job id")
            elif job in seen:
                self.err(p + ".job", "duplicate job id %r" % job)
            else:
                seen.add(job)
            self.text(p + ".label", row.get("label"))
            matches = row.get("match")
            if not isinstance(matches, list) or not matches:
                self.err(p + ".match", "must be a non-empty list of lowercase strings")
            else:
                for j, value in enumerate(matches):
                    q = "%s.match[%d]" % (p, j)
                    self.text(q, value)
                    if isinstance(value, str) and value != value.lower():
                        self.err(q, "must be lowercase")
            self.text(p + ".note", row.get("note"), optional=True)
            options = row.get("options")
            if options == [] and not (isinstance(row.get("note"), str)
                                      and row["note"].strip()):
                self.err(p + ".options", "empty options require a non-empty note")
            ranks = set()
            names = []
            for j, option in self.items(p + ".options", options):
                q = "%s.options[%d]" % (p, j)
                if not self.keys(q, option, ("name", "product", "price_month_usd",
                                             "who", "how", "rank"), ()):
                    continue
                for k in ("name", "how"):
                    self.text(q + "." + k, option.get(k))
                names.append(option.get("name"))
                product = option.get("product")
                # A subscription name is a short plain name: this text reaches agents'
                # prompts, so nothing that could carry instructions gets through.
                if not isinstance(product, str) or not (
                    product in products or re.match(
                        r"subscription:[A-Za-z0-9][A-Za-z0-9 .+&'-]{0,40}\Z", product)
                ):
                    self.err(q + ".product", "must be an allowed product or subscription:<name>")
                self.price(q + ".price_month_usd", option.get("price_month_usd"))
                if option.get("who") not in ("agent", "owner"):
                    self.err(q + ".who", "must be agent|owner")
                rank = option.get("rank")
                if isinstance(rank, bool) or not isinstance(rank, int) or rank < 1:
                    self.err(q + ".rank", "must be an integer >= 1")
                elif rank in ranks:
                    self.err(q + ".rank", "duplicate rank")
                else:
                    ranks.add(rank)
            best = row.get("best_overall")
            if best is not None and (not isinstance(best, str) or best not in names):
                self.err(p + ".best_overall", "must name an option or be null")

    def bottom_line(self, rows):
        for i, row in self.items("bottom_line", rows):
            p = "bottom_line[%d]" % i
            if not self.keys(p, row, ("work", "send_to", "why", "sources"), ()):
                continue
            for k in ("work", "send_to", "why"):
                if k in row:
                    self.text("%s.%s" % (p, k), row[k])
            if "sources" in row:
                self.sources(p + ".sources", row["sources"])

    def scores(self, path, rows):
        for i, row in self.items(path, rows):
            p = "%s[%d]" % (path, i)
            if not self.keys(p, row, ("bench", "value", "run_by", "source"), ()):
                continue
            self.text(p + ".bench", row.get("bench"))
            if "value" in row:
                v = row["value"]
                if isinstance(v, bool):
                    self.err(p + ".value", "must be text or a number")
                elif isinstance(v, (int, float)):
                    if not is_finite(v):
                        self.err(p + ".value", "must be a finite number")
                    else:
                        self.text(p + ".value", str(v))
                else:
                    self.text(p + ".value", v)
            if row.get("run_by") not in RUN_BY:
                self.err(p + ".run_by", "must be one of %s" % "|".join(RUN_BY))
            if "source" in row:
                self.source(p + ".source", row["source"])

    def claims(self, path, rows):
        for i, row in self.items(path, rows):
            p = "%s[%d]" % (path, i)
            if not self.keys(p, row, ("text", "source"), ()):
                continue
            self.text(p + ".text", row.get("text"))
            if "source" in row:
                self.source(p + ".source", row["source"])

    def models(self, rows, seen_ids):
        for i, row in self.items("models", rows):
            p = "models[%d]" % i
            if not self.keys(
                p, row,
                ("id", "family", "name", "released", "price_in", "price_out",
                 "use_for", "scores", "pros", "cons"),
                ("price_note", "summary", "retired"),
            ):
                continue
            if "retired" in row and not isinstance(row["retired"], bool):
                self.err(p + ".retired", "must be true or false")
            mid = row.get("id")
            if not isinstance(mid, str) or not MODEL_ID_RE.fullmatch(mid):
                self.err(p + ".id", "must match ^[a-z0-9][a-z0-9.-]{2,60}$")
            elif mid in seen_ids:
                self.err(p + ".id", "duplicate model id %r" % mid)
            else:
                seen_ids.add(mid)
            if row.get("family") not in FAMILIES:
                self.err(p + ".family", "must be one of %s" % "|".join(FAMILIES))
            for k in ("name", "released", "use_for"):
                if k in row:
                    self.text("%s.%s" % (p, k), row[k])
            for k in ("price_note", "summary"):
                if k in row:
                    self.text("%s.%s" % (p, k), row[k], optional=True)
            self.price(p + ".price_in", row.get("price_in"))
            self.price(p + ".price_out", row.get("price_out"))
            if "scores" in row:
                self.scores(p + ".scores", row["scores"])
            if "pros" in row:
                self.claims(p + ".pros", row["pros"])
            if "cons" in row:
                self.claims(p + ".cons", row["cons"])

    def best_at(self, rows):
        for i, row in self.items("best_at", rows):
            p = "best_at[%d]" % i
            if not self.keys(
                p, row,
                ("work", "best", "runner_up", "evidence", "confidence", "sources"), (),
            ):
                continue
            for k in ("work", "best", "runner_up", "evidence", "confidence"):
                if k in row:
                    self.text("%s.%s" % (p, k), row[k])
            if "sources" in row:
                self.sources(p + ".sources", row["sources"])

    def families(self, rows):
        seen = set()
        for i, row in self.items("families", rows):
            p = "families[%d]" % i
            if not self.keys(
                p, row, ("id", "tends_to", "watch_for", "brief_with"),
                ("summary", "plans_note"),
            ):
                continue
            fid = row.get("id")
            if fid not in FAMILIES:
                self.err(p + ".id", "must be one of %s" % "|".join(FAMILIES))
            elif fid in seen:
                self.err(p + ".id", "duplicate family %r" % fid)
            else:
                seen.add(fid)
            for k in ("tends_to", "watch_for", "brief_with"):
                if k in row:
                    self.text("%s.%s" % (p, k), row[k])
            for k in ("summary", "plans_note"):
                if k in row:
                    self.text("%s.%s" % (p, k), row[k], optional=True)


TOP_REQUIRED = ("version", "checked", "bottom_line", "models", "families", "reading_notes")
TOP_OPTIONAL = ("summary", "headline_benches", "comparison_note", "best_at", "best_at_note",
                "personalities_note", "media")


def validate(data, domains):
    """Return (errors, warnings), each a list of 'PATH: message' strings."""
    c = Checker(domains)
    if not c.keys("$", data, TOP_REQUIRED, TOP_OPTIONAL):
        return c.errors, c.warnings
    if data.get("version") != 1 or isinstance(data.get("version"), bool):
        c.err("version", "must be 1")
    checked = data.get("checked")
    if not isinstance(checked, str) or not DATE_RE.fullmatch(checked):
        c.err("checked", "must be a YYYY-MM-DD date")
    for k in ("summary", "comparison_note", "best_at_note", "personalities_note"):
        if k in data:
            c.text(k, data[k], optional=True)
    if "headline_benches" in data:
        for i, b in c.items("headline_benches", data["headline_benches"]):
            c.text("headline_benches[%d]" % i, b)
    if "media" in data:
        c.media(data["media"])
    if "bottom_line" in data:
        c.bottom_line(data["bottom_line"])
    if "models" in data:
        c.models(data["models"], set())
    if "best_at" in data:
        c.best_at(data["best_at"])
    if "families" in data:
        c.families(data["families"])
    if "reading_notes" in data:
        c.claims("reading_notes", data["reading_notes"])
    return c.errors, c.warnings


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main(argv):
    if len(argv) not in (2, 3):
        sys.stderr.write("usage: kit-guide-validate FILE [DOMAINS_FILE]\n")
        return 2
    path = argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    domains_path = argv[2] if len(argv) == 3 else os.path.join(here, "..", "guide", "source-domains.txt")
    try:
        domains = load_domains(domains_path)
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write("kit-guide-validate: cannot read %s: %s\n" % (domains_path, e))
        return 2
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write("kit-guide-validate: cannot read %s: %s\n" % (path, e))
        return 2
    try:
        data = json.loads(raw)
    except ValueError as e:
        print("$: not valid JSON (%s)" % str(e).splitlines()[0])
        return 1
    except RecursionError:
        print("$: not valid JSON (nested too deeply)")
        return 1
    errors, warnings = validate(data, domains)
    for w in warnings:
        sys.stderr.write("warning: %s\n" % w)
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
