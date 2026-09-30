# routing-kit

A Claude Code plugin that decides which AI model does which job.

Claude stays in charge. It plans, reviews and talks to you. The building goes to cheaper models:
Claude's own smaller models, and if you have them, OpenAI's Codex, Google's Jules, Kimi or GLM.
The kit reads how much of each plan you have used this week and sends work to the one with the most
room left, so no plan runs out early while another sits unused.

It is for people who already use Claude Code and pay for more than one AI plan, or want to.

## Install

Open Claude Code and drop [START-HERE.md](START-HERE.md) into the chat. Claude checks your Mac,
installs the plugin, asks about your plans one question at a time, and runs a self-test.

It never asks for an API key. Where a key is needed, you type it into your own Terminal and it goes
into the Mac's Keychain.

## Mac only

The kit uses the macOS Keychain and the macOS sandbox. It does not run on Linux or Windows.

## Safety, in brief

- Kimi and GLM keep what they are sent and may train on it. They only ever get committed code,
  inside a locked sandbox, and never your keys. Keep secrets out of git.
- While a Kimi or GLM job runs, it could read the command lines of your other running programs (not
  files, not keys). Don't type passwords or tokens into command lines then.
- Never add Kimi or GLM as agents inside Paseo: Paseo would run them with full access.
- Never put personal details, names or secrets in a brief. Briefs go to other companies' servers.
- Jules sees whatever is in the GitHub repo you give it. Google says it doesn't train on private
  repos; it makes no such promise for public ones.
- Muse is not part of the kit: Muse tokens only work in the Muse app, not from a command line or
  API.
- Antigravity is left out on purpose, because it escaped its sandbox when run from a script.

[START-HERE.md](START-HERE.md) has the full notes, plus how to update and remove the kit.
