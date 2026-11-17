#!/usr/bin/env python3
"""Scores the media matcher on tests/fixtures/checks/media/eval.tsv (prompt TAB expected job or none).
Usage: media_eval.py ROOT. Prints one summary line per measure and one line per problem:
  MEDIA right total   - media prompts routed to the expected job
  CODING matched total - prompts expected to match nothing that matched anyway (allowed, reported)
  EXPLICIT matched total - explicit-code-signal prompts that matched (must be 0) / that exist
  MISS / WRONG / FALSE / SIGNAL lines name the prompts."""
import re
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "plugins/routing-kit/lib"))
from media_match import media_jobs, match_job

# Written separately from the matcher on purpose: the owner's list of signals that must stop a match.
EXPLICIT = re.compile(
    r"`|\b[\w-]+\.(?:py|js|jsx|ts|tsx|json|yml|yaml|md|sh|css|html|sql|go|rs|java|rb|php|lua|cpp|cs)\b"
    r"|(?:^|\s)[~.]?/?[\w.-]+/[\w.-]+"
    r"|\b(?:typescript|javascript|python|rust|ruby|kotlin|java|swift|swiftui|bash|react|vue|svelte|php|lua"
    r"|nginx|django|flask|rails|c#|c\+\+)\b|\.net\b"
    r"|\b(?:function|class|bug|test|api|endpoint|component)(?:es|s)?\b", re.IGNORECASE)

jobs = media_jobs(Path(tempfile.mkdtemp()))
rows = [line.split("\t") for line in (root / "tests/fixtures/checks/media/eval.tsv").read_text().splitlines()
        if line and not line.startswith("#")]
media = [(prompt, job) for prompt, job in rows if job != "none"]
coding = [prompt for prompt, job in rows if job == "none"]

right = 0
for prompt, job in media:
    got = match_job(prompt, jobs)
    if got == job:
        right += 1
    else:
        print("%s %s got %s | %s" % ("WRONG" if got else "MISS", job, got, prompt))
matched = [prompt for prompt in coding if match_job(prompt, jobs)]
explicit = [prompt for prompt in matched if EXPLICIT.search(prompt)]
for prompt in explicit:
    print("SIGNAL matched despite a code signal | %s" % prompt)
print("MEDIA %d %d" % (right, len(media)))
print("CODING %d %d" % (len(matched), len(coding)))
print("EXPLICIT %d %d" % (len(explicit), sum(1 for prompt in coding if EXPLICIT.search(prompt))))
