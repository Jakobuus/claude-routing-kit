<img width="1254" height="1254" alt="image" src="https://github.com/user-attachments/assets/0f647fa8-0945-48f2-aa10-0f3a30519299" />
# routing-kit

Decides which AI model does which job, by a field guide of the current models. It installs for
Claude Code, Codex or Gemini (Antigravity), whichever you mainly work in.

## If you are an AI agent

The person who gave you this link wants routing-kit set up. Fetch `START-HERE.md` from this repo
and follow it step by step.

If you are the person, paste this into your agent (Claude Code, Codex or Gemini):

```
Set up https://github.com/Jakobuus/claude-routing-kit for me
```

## What it is

- **What it does.** Your main agent stays in charge: it plans, reviews and talks to you. The
  building goes to cheaper models: Claude's smaller models and, if you have them, OpenAI's Codex,
  Google's Gemini and Jules, Kimi or GLM. Before handing out work, it checks how much of each plan
  you have used this week and picks the one with the most room left. No plan runs out early while
  another sits unused.
- **Who it is for.** People who use Claude Code, Codex or Gemini and pay for more than one AI plan,
  or want to.
- **What you get.** A set of working rules that load at the start of every session, a table of
  which model does which job for your plans, build commands for each helper, a usage check
  (`kit-quota`), and a self-test.
- **What it needs.** One of the three agents on macOS, Linux, or Windows through WSL2. Everything
  else is optional.

## What is new in 0.3

- **A field guide.** The routing follows `plugins/routing-kit/guide/FIELD-GUIDE.md`: a guide to the
  current models, what each is best at, with sources and the date the facts were checked. The
  maintainer refreshes it from time to time and ships it as a kit update. The kit tells you at
  session start when the guide is more than 7 days old, and the table notes any model your
  installed Codex or Gemini does not offer.
- **Effort limits per model.** The table says how much thinking effort each model should get, and
  where more effort only costs money (for example, one model is never used above `high`).
- **Different briefs per model family.** A job handed to a Claude, OpenAI or Google model is
  written the way that family works best.
- **Your choice of main agent.** Claude Code, Codex or Gemini can be the one in charge. The table
  is written for it. You can use it with no Claude plan at all.

## Install

Give [START-HERE.md](START-HERE.md) to your agent, or paste the one line above. The agent asks which
agent you mainly work in, checks your computer, installs the kit, asks about your plans one
question at a time, and runs a self-test.

It never asks for an API key in the chat. Where a key or login is needed, you type it into your own
terminal.

## What it looks like

Someone who works in Claude Code, with Claude Pro and ChatGPT Plus, gets this table (model names as
of November 2026). The kit builds it from their answers and loads it into every session:

<!-- example:start claude_plan=pro codex=plus gemini=none jules=false kimi=false glm=false main_agent=claude -->
| Work | Use | Notes |
|---|---|---|
| Plans, architecture, judgment | Claude opus | medium, high for checks; big plans also get Codex gpt-6-astra advice |
| Features, bug fixes, tests | Codex gpt-6.1-sol · Claude sonnet | sonnet: medium or high, never above; pick by quota |
| Review | Claude work → Codex gpt-6.1-sol, risky changes → gpt-6-astra; Codex work → Claude opus | the reviewer reads the diff itself, never the builder's report |
| Second opinion | Codex gpt-6-astra; big calls add a fresh Claude opus subagent | via ask-advisers |
| Screenshots, UI checks, prose from supplied material | Codex gpt-6.1-terra | on trial: first 5 runs logged, dropped if 2 need real fixes |
| UI building | Claude opus | |
| Read-only lookups | Claude haiku · Codex gpt-6-luna | haiku prompts under 100K tokens; Codex gpt-6-luna at high, never low |
| Bulk mechanical edits | Codex gpt-6-luna (or a script it writes, run here) · Claude sonnet | Codex gpt-6-luna at high, never low; only where a script or test checks the result |
| Web research | Codex gpt-6.1-sol with -c web_search="live" · Claude sonnet | |
| Reading untrusted web pages or email while holding tools that can act | Claude opus | never Fable |
<!-- example:end -->

Someone who works in Codex, with ChatGPT Plus and no Claude plan, gets this one:

<!-- example:start claude_plan=none codex=plus gemini=none jules=false kimi=false glm=false main_agent=codex -->
| Work | Use | Notes |
|---|---|---|
| Plans, architecture, judgment | Codex gpt-6-astra (the main session) | strong models plan, judge and review; they don't write code |
| Features, bug fixes, tests | Codex gpt-6.1-sol | |
| Review | fresh Codex gpt-6-astra session | no other lane to cross-check against |
| Second opinion | fresh Codex gpt-6-astra session | follow the Advisers rules; no other lane to ask |
| Screenshots, UI checks, prose from supplied material | Codex gpt-6.1-terra | on trial: first 5 runs logged, dropped if 2 need real fixes |
| UI building | Codex gpt-6.1-sol | |
| Read-only lookups | Codex gpt-6-luna | Codex gpt-6-luna at high, never low |
| Bulk mechanical edits | Codex gpt-6-luna (or a script it writes, run here) | Codex gpt-6-luna at high, never low; only where a script or test checks the result |
| Web research | Codex gpt-6.1-sol with -c web_search="live" | |
| Reading untrusted web pages or email while holding tools that can act | Codex gpt-6.1-sol | never the top model |
<!-- example:end -->

With a Google AI plan, the table also offers Argon for builds and Hydrogen for bulk edits.
Argon has a small separate weekly pool on Pro. Gemini builds use `kit-gemini-build`; usage
appears in `kit-quota`. A bucket with a reset time but no remaining fraction shows as unknown.

Where a row lists two models, your main agent picks the one whose plan has used less of its week.
Helpers you don't have never appear.

## Which systems get what

| | macOS | Linux | Windows with WSL2 | Windows without WSL |
|---|---|---|---|---|
| Rules and routing table | yes | yes | yes | no |
| Claude Code as main agent | yes | yes | yes | no |
| Codex as main agent | yes | yes | yes | no |
| Gemini (Antigravity) as main agent | yes (untested end to end) | yes (untested end to end) | yes (untested end to end) | no |
| Codex as helper | yes | yes | yes | no |
| Gemini (Antigravity CLI) as helper | yes | yes | yes | no |
| Jules | yes | yes | yes | no |
| Kimi and GLM | yes | no | no | no |
| Paseo pill | yes | only if Paseo runs there (untested) | only if Paseo runs there (untested) | no |

Linux and WSL2 need `jq`, `python3` (3.9 or newer) and `git`. On a Mac they come with Apple's
Command Line Tools. Windows without WSL is not supported: install WSL2 first (`wsl --install` in
an administrator PowerShell, then restart).

### What each main agent gets

| | Claude Code | Codex | Gemini (Antigravity) |
|---|---|---|---|
| How it installs | plugin | `git clone` to `~/.config/routing-kit/kit`, then `kit-install-rules --agent codex` | the same, with `--agent gemini` |
| Rules and routing table at session start | yes, by itself | yes, after you trust the hook once with `/hooks` in Codex | yes (untested end to end) |
| Field guide and helper commands | yes | yes | yes |
| Skills and status line | yes | no | no |
| Updates | `claude plugin update` | `git pull`, then `kit-install-rules` again | the same |
| Claude's part | main agent | reviews and lookups only, and only if you have a Claude plan (Claude Code installed and signed in) | the same |

Setup puts one start-up hook and a short note into the agent's own settings folder: `~/.codex`
(or the folder `CODEX_HOME` names; the note goes into `AGENTS.override.md` if that file exists and
is not empty, otherwise `AGENTS.md`), or `~/.gemini`. Anything else in those files stays. It keeps a
backup of each existing file it changes, next to it, as `<file>.routing-kit.bak`. The agent shows
you the exact files first (`kit-install-rules --agent codex --print` writes nothing).

## Kimi and GLM: Mac only, locked down

Kimi (Moonshot) and GLM (Z.ai) are cheap pay-per-use coding models. They keep what they are sent
and may train on it. So the kit only ever runs them inside the macOS sandbox, through one command
(`locked-build`):

- They see a fresh copy of your committed code and nothing else: not your home folder, your keys,
  or files git ignores.
The patch is built from a fresh clone of your repo and a private snapshot of the helper's output after the helper has stopped, so a helper's leftovers cannot change the patch. Codex and Gemini themselves run with full access to your machine under your own account; Kimi and GLM run locked in the Mac's sandbox.
- The copy is deleted when the job ends. What you keep is a patch file (`build.patch`, in the
  job's run folder under `~/.config/routing-kit/runs`); apply it with `git apply`. Set
  `ROUTING_KIT_KEEP_RUNS=1` to keep the copy for debugging.
  A build that leaves a nested git repo (submodules), a FIFO or a hard-linked file in the copy is refused.
  (On a git older than 2.40 a symlink to a directory is refused too.)
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
- Codex runs without a sandbox or approval prompts, with
  `--dangerously-bypass-approvals-and-sandbox`.
- Gemini runs under your own Google account and login, without a sandbox or permission prompts,
  with `--dangerously-skip-permissions`. Its environment is scrubbed: your shell's tokens and keys
  are not passed on. Codex and Gemini builds use fresh clones, and patches come from private
  snapshots taken after the helpers stop. Review their patches. On Linux, if a Gemini build
  reports that agy is not signed in, run it with `KIT_AGY_ALLOW_DBUS=1`, which lets agy reach the
  desktop keyring.
- In 0.2.4, a profile without a `codex` key no longer loads the Codex rules, matching its routing table.
- Google shuts Jules down on 31 Dec 2026. Jules users should move to Gemini; Jules support remains until then.

## Update

Claude Code:

```
claude plugin update routing-kit@routing-kit
```

Codex or Gemini (use `--agent gemini` for Gemini):

```
git -C ~/.config/routing-kit/kit pull
kit-install-rules --agent codex
```

Then start a new session. The Paseo pill, if you have it, updates on its own with
`paseo plugin update routing-kit-pill`.

## Remove

Run these in order. The first must come while the kit's commands still exist.

Claude Code:

```
kit-statusline uninstall
paseo plugin remove routing-kit-pill
claude plugin uninstall routing-kit@routing-kit
rm -r ~/.config/routing-kit
```

Codex or Gemini (use `--agent gemini` for Gemini):

```
kit-install-rules --agent codex --uninstall
paseo plugin remove routing-kit-pill
rm -r ~/.config/routing-kit
```

Then delete the PATH line, if you let the agent add one to `~/.zshrc`, `~/.bashrc` or `~/.bash_profile`. Skip the `paseo` line if you
don't have the pill. [START-HERE.md](START-HERE.md) has the details, including how to delete stored
Kimi and GLM keys.
