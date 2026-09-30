# routing-kit

A Claude Code plugin that decides which AI model does which job.

- **What it does.** Claude stays in charge: it plans, reviews and talks to you. The building goes
  to cheaper models: Claude's own smaller models and, if you have them, OpenAI's Codex, Google's
  Jules, Kimi or GLM. Before handing out work, it checks how much of each plan you have used this
  week and picks the one with the most room left. No plan runs out early while another sits unused.
- **Who it is for.** People who use Claude Code and pay for more than one AI plan, or want to.
- **What you get.** A set of working rules that load at the start of every Claude Code session, a
  table of which model does which job for your plans, build commands for each helper, a usage
  check (`kit-quota`), and a self-test.
- **What it needs.** Claude Code on macOS, Linux, or Windows through WSL2. Everything else is
  optional.

## Install

Open Claude Code and drop [START-HERE.md](START-HERE.md) into the chat. Claude checks your
computer, installs the plugin, asks about your plans one question at a time, and runs a self-test.

It never asks for an API key in the chat. Where a key or login is needed, you type it into your own
terminal.

## What it looks like

Someone with Claude Pro and ChatGPT Plus gets this table (model names as of September 2026). The kit builds it from their answers and
loads it into every session:

| Work | Use | Notes |
|---|---|---|
| Plans and architecture | Claude opus | big plans also get Codex gpt-6-astra advice |
| Review | Claude work → Codex gpt-6-astra; Codex work → Claude opus | the strong model of a different company than the builder |
| Reviewer models | Claude: opus · Codex: gpt-6-astra | use these model IDs for adviser and review calls |
| Second opinion | Codex gpt-6-astra; big calls add a fresh Claude opus subagent | via ask-advisers |
| Features, bug fixes, tests | Codex gpt-6-sol · Claude sonnet | |
| Bulk mechanical edits | Codex gpt-6-luna (or a script it writes, run here) · Claude sonnet | |
| Read-only lookups | Codex gpt-6-luna · Claude haiku | |
| Web research | Codex gpt-6-sol with -c web_search="live" · Claude sonnet | |

Where a row lists two models, Claude picks the one whose plan has used less of its week. Helpers
you don't have never appear.

## Which systems get what

| | macOS | Linux | Windows with WSL2 | Windows without WSL |
|---|---|---|---|---|
| Rules and routing table | yes | yes | yes | no |
| Codex | yes | yes | yes | no |
| Jules | yes | yes | yes | no |
| Kimi and GLM | yes | no | no | no |
| Paseo pill | yes | only if Paseo runs there (untested) | only if Paseo runs there (untested) | no |

Linux and WSL2 need `jq`, `python3` (3.9 or newer) and `git`. On a Mac they come with Apple's
Command Line Tools. Windows without WSL is not supported: install WSL2 first (`wsl --install` in
an administrator PowerShell, then restart).

## Kimi and GLM: Mac only, locked down

Kimi (Moonshot) and GLM (Z.ai) are cheap pay-per-use coding models. They keep what they are sent
and may train on it. So the kit only ever runs them inside the macOS sandbox, through one command
(`locked-build`):

- They see a fresh copy of your committed code and nothing else: not your home folder, your keys,
  or files git ignores.
- They can only reach their own company's server.
- A secret scan runs first. If it finds anything that looks like a key, the job does not start.
- Your API key stays in the Mac's Keychain. The kit hands it only to that one job.

Linux has no equivalent the kit trusts yet, so Kimi and GLM are not offered there.

## Safety, in brief

- Kimi and GLM only get committed code. Keep secrets out of git.
- While a Kimi or GLM job runs, it could read the command lines of your other running programs
  (not files, not keys). Don't type passwords or tokens into command lines then.
- Never add Kimi or GLM as agents inside Paseo: Paseo would run them with full access.
- Never put personal details, names or secrets in a brief. Briefs go to other companies' servers.
- Jules sees whatever is in the GitHub repo you give it. Google says it doesn't train on private
  repos; it makes no such promise for public ones.
- Muse is not part of the kit: Muse tokens only work in the Muse app, not from a command line or
  API.
- Antigravity is left out on purpose, because it escaped its sandbox when run from a script.

## Update

```
claude plugin update routing-kit@routing-kit
```

Then start a new Claude Code session. The Paseo pill, if you have it, updates on its own with
`paseo plugin update routing-kit-pill`.

## Remove

Run these in order. The first must come while the kit's commands still exist:

```
kit-statusline uninstall
paseo plugin remove routing-kit-pill
claude plugin uninstall routing-kit@routing-kit
rm -r ~/.config/routing-kit
```

Skip the `paseo` line if you don't have the pill. [START-HERE.md](START-HERE.md) has the details,
including how to delete stored Kimi and GLM keys.
