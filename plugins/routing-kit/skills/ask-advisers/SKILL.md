---
name: ask-advisers
description: Use for a second opinion — a fork you're weighing, a surprise, a stubborn bug, a plan or diff before you commit to it, or when the user says "ask advisers", "second opinion", "get advice". Codex is the default adviser when the user has it; a fresh Claude Opus subagent joins for big decisions, or stands alone for Claude-only users.
---

# Ask advisers

One frozen brief, sent word for word to every adviser you use. Answers go to files; you read the
verdicts.

## Who to ask

Check the routing table in your context to see which lanes the user has.

- **Normal doubt**
  - With Codex: Codex alone. It doesn't spend Claude's limits, so ask freely.
  - Claude only: one fresh Claude reviewer model subagent from Your routing table.
- **Big decision** (hard to undo, a plan before committing to it, a bug after two failed fixes, or
  the user asks):
  - With Codex: Codex and a fresh Claude reviewer model subagent from Your routing table, in parallel, on the same brief.
  - Claude only: a fresh Claude reviewer model subagent from Your routing table. Say in your reply that only one company's model
    looked at it.
- **The advisers disagree on something that matters**: settle it with a test, a search or a check,
  or ask the user. Another round of argument settles nothing.

## The brief

Save it to `<plan or repo folder>/advice/<slug>/brief.md`, then don't edit it. Five parts, in this
order:

1. **DECISION**: the open question. Never "confirm that…".
2. **FACTS**: copied word for word: file paths, numbers, error text. Not your summary of them.
3. **OPTIONS**: the real options, including doing nothing.
4. **COST-OF-WRONG**: what breaks, and how hard it is to undo, if the choice is wrong.
5. **LEANING**: your own leaning, labelled, or leave it out. Always last.

Never ask the adviser to explain its reasoning step by step. The brief's first line asks for:
`MODEL: <name>`, then `VERDICT: <one line>`, then at most 400 words.

For a security review of your own code, frame it as a defensive review ("which of these properties
does the policy not enforce, and what would close each gap?") and ask for one line per gap. Briefs
worded like an attack ("where can it escape?") can be refused by the adviser's safety filter.

## Running the advisers

Run each one in the background. Always name the model.

Codex (read-only, strongest model):

```bash
codex exec -m "<Codex reviewer model from Your routing table>" -s read-only --skip-git-repo-check -C <repo> -o <dir>/codex.md \
  "Read <dir>/brief.md and answer it exactly as it asks. You may read files to check facts. Change nothing." \
  < /dev/null 2>&1 | tee <dir>/codex.log
```

Claude: an Agent call with `model` set to the Claude reviewer model from Your routing table, `run_in_background: true` and the prompt
"Read <dir>/brief.md and answer it exactly as it asks. You may read files to check facts. Change
nothing." Give it no other context, so it judges the brief fresh. Save its reply to
`<dir>/claude.md`.

## Reading the answers

- Read the `VERDICT` lines first. Open the full answer only where the verdicts differ or one
  surprises you.
- Agreement means no red flag, not certainty.
- Take the advice into your work, or write one line in the plan saying why you didn't.
