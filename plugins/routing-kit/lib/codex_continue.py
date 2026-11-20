#!/usr/bin/env python3
"""Decide whether a Codex build stopped early, and say what to send to make it go on.

  codex_continue.py check BRIEF_FILE FINAL_MESSAGE_FILE
      exit 0 and the reason on stdout: the work is clearly not finished
      exit 1: nothing says it is unfinished (a missing or empty message counts as empty)
  codex_continue.py message
      the text sent to the agent to continue

"Clearly not finished" is any of:
  (a) the final message has a done-count line ("items done: 1 of 2") with N < M;
  (b) the brief asks for such a line and the final message has none;
  (c) the last paragraph of the final message holds a plan-to-act phrase ("I'll ", "I will ",
      "Next I ", "Let me ") or says the work is unfinished ("captures are incomplete", "I did not finish").
      The last paragraph is taken before the three closing lists ("What I did" ...); a plan or a status
      statement in the very last paragraph counts too, but "What I didn't do: none" does not.
No model judges this; it is a few patterns, so a wrong call costs at most one extra message.
"""
import re
import sys

MESSAGE = (
    "Continue. Nobody will answer you: this build runs unattended. Do the remaining work now; "
    "do not report progress or plans. End your turn only when every item is done and the "
    "done-count line shows N of N, or when you are truly blocked (then say exactly why)."
)

# "items done: 1 of 2", "findings fixed: 3 of 9", "features completed: 2 of 2".
COUNT = re.compile(r"\b[a-z]+\s+(?:done|fixed|completed?)\s*:\s*(\d+)\s+of\s+(\d+)", re.I)
# The brief may show the line as a template ("items done: N of M") or with numbers.
ASK = re.compile(r"\b[a-z]+\s+(?:done|fixed|completed?)\s*:\s*(?:\d+|N)\s+of\s+(?:\d+|M)\b", re.I)
PLAN = re.compile(r"(?:\bI['’]ll |\bI will |\bNext I |\bLet me (?!know\b))", re.I)
# Status statements ("captures are incomplete", "I did not finish"), not "rejects incomplete input".
# They count in the work paragraph and in the very last paragraph, whatever the closing lists look like.
STATUS = re.compile(r"(?:^\s*(?:[-*+]\s+)?(?:\*\*|__)?(?:incomplete|unfinished|not finished)(?:\*\*|__)?\s*:|\b(?:is|are|remains?|still) (?:still )?(?:incomplete|unfinished|not finished)\b|\bnot finished yet\b|\bI (?:didn['’]t|did not) finish\b)", re.I | re.M)
# "I didn't do item 3" counts only in the work paragraph: the closing list "What I didn't do: none" is not status.
SKIPPED = re.compile(r"\bI (?:didn['’]t|did not) do\b", re.I)
CLOSING = re.compile(r"^\s*(?:[-*+]\s+|#{1,6}\s*)?(?:\*\*|__)?what I (?:did|didn['’]t do|did not do|couldn['’]t check|could not check)(?=\s*(?::|\*|_|$))", re.I | re.M)


def last_paragraph(text):
    paragraphs = [p for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]
    return paragraphs[-1] if paragraphs else ""


def unfinished(brief, final):
    """The reason the work is clearly not finished, or None."""
    counts = COUNT.findall(final)
    if counts:
        done, total = (int(x) for x in counts[-1])
        if done < total:
            return "done-count line shows %d of %d" % (done, total)
    elif ASK.search(brief):
        return "the brief asks for a done-count line and the final message has none"
    closing = CLOSING.search(final)
    work = last_paragraph(final[:closing.start()] if closing else final)
    last = last_paragraph(final)
    # A plan on the very last paragraph counts too ("I'll do X next." after the closing lists).
    # A closing label is the whole label ("What I did:"), so "What I did so far: ..." is work, not closing.
    if PLAN.search(work) or PLAN.search(last):
        return "the final message ends with a plan to act"
    if STATUS.search(work) or STATUS.search(last) or SKIPPED.search(work):
        return "the final message says the work is incomplete"
    return None


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def main(argv):
    if argv[1:2] == ["message"] and len(argv) == 2:
        print(MESSAGE)
        return 0
    if argv[1:2] == ["check"] and len(argv) == 4:
        reason = unfinished(read(argv[2]), read(argv[3]))
        if reason is None:
            return 1
        print(reason)
        return 0
    print("usage: codex_continue.py check BRIEF FINAL | message", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
