---
name: delegating
description: Build handoffs. Use before you start a build with another model (kit-codex-build, kit-gemini-build, kit-jules-build, locked-build, a subagent or a `claude -p` worker), and when a build's result comes back.
---

# Delegating a build

## Before you start

- Commit first. Builds work on a copy of your committed files; the commands refuse a dirty repo.
- Write the brief to a file: the goal, the exact files, the facts the worker needs, and the tests
  that show it is done. Ask for one run against the real data or system before finishing.
- The worker sees only the repo and the brief. Paste in anything it needs from outside the repo.
- Never put credentials or private details of people into a brief.
- Parallel builds only on files that don't overlap.
- Work that needs a signed-in account, private data, files git ignores or a live server stays in
  your own session (in Claude Code: a subagent).

## Commands

Pick the model from your routing table and name it.

```
kit-codex-build  --repo DIR --name NAME --brief FILE --model MODEL [--paseo|--no-paseo] [--timeout SECS]
kit-gemini-build --repo DIR --name NAME --brief FILE --model MODEL [--effort E] [--timeout SECS]
kit-jules-build  --repo DIR --name NAME --brief FILE --verify "CMD"      # repos on GitHub only
locked-build --provider kimi|glm --repo DIR --name NAME --brief FILE     # Kimi and GLM: only this way
```

Run them in the background; each prints the path of its result when it ends. Exit codes: 0 done,
2 bad input or dirty repo, 3 a tool or login is missing, 4 build or provider error, 5 a secret scan
or the sandbox check refused, 6 (Codex through Paseo) the agent waits for a permission, 124 timeout.
For 3, restore the missing tool or login; for 5, resolve the scan or sandbox refusal rather
than bypassing it; for 6, ask the user for the required permission. Resume only once resolved.

A one-off question or lookup needs no build script: `codex exec -m MODEL "..." </dev/null`,
`agy --model MODEL -p "..." </dev/null`, `claude -p --model MODEL "..."`.

## When it comes back

1. The result is `<run dir>/build.patch`; the worker's own summary is `result.md` next to it.
2. Apply it: `git apply --index <run dir>/build.patch`. The scripts never merge.
3. Run the checks yourself.
4. Review: the model in your table's Review row reads the diff, not the worker's summary. You did
   not build it, so for a small diff with green checks your own read is that review. Fix small
   findings yourself; rerun the checks.
5. Commit.

A build copy that could not be cleaned up safely is kept: `kit-retained list`,
`kit-retained prune --older-than DAYS`.

## Second opinion

Use the `ask-advisers` skill: one written brief, sent word for word, read-only.
