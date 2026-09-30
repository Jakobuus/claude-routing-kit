# START HERE: set up routing-kit

**For Claude.** The person who dropped this file into Claude Code wants routing-kit set up. Walk
them through the steps below, in order. They may not be a programmer.

How to talk to them:

- Plain words, short sentences. Say what you are doing and why it matters to them.
- Ask one question at a time. Wait for the answer before the next one.
- Run the checks and commands yourself. Show them only what they need to decide or type.
- **Never ask for an API key, and never touch one.** When a key or login is needed, give them the
  exact line from step 4 to type into their own terminal window. If they paste a key into the chat
  anyway, tell them to delete that key on the provider's site and make a new one.
- If a step fails, say what went wrong in one sentence and what fixes it. Don't guess.

The kit lives at https://github.com/Jakobuus/claude-routing-kit.

## Step 1: Check the machine

1. Find the system. Run `uname -s`:
   - `Darwin`: **Mac**. Everything in the kit is available.
   - `Linux`: run `grep -qi microsoft /proc/version && echo WSL`. If it prints `WSL`, this is
     **WSL** (Linux inside Windows); otherwise **Linux**. Both are handled the same way below.
   - Anything else (`MINGW...`, `MSYS...`, `CYGWIN...`, or `uname` not found): **Windows without
     WSL**. Stop. Tell them: "routing-kit needs a Mac, Linux, or WSL2 on Windows. Nothing was
     installed. To get WSL2, open PowerShell as administrator, run `wsl --install`, restart the
     computer, then install Claude Code inside Ubuntu and drop this file in again."
2. Run `claude --version` and note it.
3. Check which tools are there, and say it back as a short list:
   - `command -v git jq python3`: all three are needed, and `python3 --version` must be 3.9 or
     newer.
     - Mac: they come with the Command Line Tools. If `git` is missing, run
       `xcode-select --install` and wait for it to finish.
     - Linux or WSL: if any is missing, ask them to run this in their own terminal (it asks for
       their password): `sudo apt update && sudo apt install -y git jq python3`. On a system
       without `apt`, they use their own package manager for the same three.
   - `command -v codex`: the OpenAI Codex CLI (optional).
   - `command -v jules`: the Google Jules CLI (optional).
   - `command -v gh`: the GitHub CLI. Only needed for Jules, which works on code on GitHub.
   - Paseo: `command -v paseo`, or on a Mac `/Applications/Paseo.app` (optional).

On Linux and WSL, tell them once: "Kimi and GLM won't be offered here: the kit only runs them
inside the Mac's sandbox, and Linux has no equivalent it trusts yet."

## Step 2: Install the plugin

1. Run:
   ```
   claude plugin marketplace add Jakobuus/claude-routing-kit
   claude plugin install routing-kit@routing-kit
   ```
2. Offer the superpowers plugin as an add-on: "It adds skills for writing plans and working through
   them step by step. The kit's rules use it for big jobs when it is there." If they want it:
   ```
   claude plugin install superpowers@claude-plugins-official
   ```
3. Check that the kit's commands are reachable: `command -v kit-profile`. If not found, stop and
   ask them to restart Claude Code (type `/exit`, start `claude` again in the same folder) and drop
   this file in again. Don't work around it by changing PATH or calling paths inside the plugin
   folder. `kit-profile get` shows answers already saved, so you can pick up where you left off.

## Step 3: Ask about their plans

One question at a time. Save each answer straight away.

1. **Claude plan.** "Which Claude plan do you have: Pro, Max 5x, Max 20x, Team, or do you pay per
   use through the API?"
   `kit-profile set claude_plan pro` (or `max5`, `max20`, `team`, `api`)
2. **ChatGPT plan, for Codex.** "Do you have a ChatGPT plan? Codex, OpenAI's coding helper, comes
   with it. Which one: Plus, Pro, Business, API, or none?"
   `kit-profile set codex plus` (or `pro`, `business`, `api`, `none`)
3. **Jules.** "Do you want to use Jules, Google's coding helper? It only works on code that is on
   GitHub. Which Jules plan: free, Pro or Ultra?"
   If yes: `kit-profile set jules true` and `kit-profile set jules_daily_limit 15` (free 15 tasks a
   day, Pro 100, Ultra 300). If no: `kit-profile set jules false`.
4. **Kimi** and 5. **GLM.** Not on Linux or WSL: save `kit-profile set kimi false` and
   `kit-profile set glm false` without asking. On a Mac, first check that the lockdown test passed
   on this version of the kit:
   ```
   ls "$(dirname "$(command -v locked-build)")/../LOCKDOWN-PASSED"
   ```
   If that file is missing, save both as `false` and tell them these two are switched off in this
   version. If it is there, ask about each one separately: "Kimi (from Moonshot) and GLM (from
   Z.ai) are cheap pay-per-use coding models. The kit runs them locked in a sandbox. Do you want
   Kimi?" Before they answer, read them the Kimi and GLM notes from step 5. Then
   `kit-profile set kimi true` or `false`; same for `glm`.

When all answers are in, run `kit-profile validate`. It exits 0 when the profile is good.

## Step 4: Set up each helper they chose

Skip any helper they said no to.

**Codex.** If `codex` is missing, check the package still exists with
`npm view @openai/codex version`, then install it:
```
npm i -g @openai/codex
```
On a Mac, `brew install --cask codex` works too. Then sign them in:

- **ChatGPT plan** (Plus, Pro, Business): ask them to run `codex login` in their own terminal and
  sign in with their ChatGPT account.
- **API** (they pay OpenAI per use): they create a key at https://platform.openai.com/api-keys,
  copy it, then paste this line into their own terminal (not this chat):
  ```
  read -rs K && printf '%s' "$K" | codex login --with-api-key; unset K
  ```
  It shows nothing. They paste the key and press Enter. The key goes to Codex without being shown
  or saved in the shell history. Don't ask to see it, and don't run this line for them.

Check with `codex login status`.

**Jules.** If `gh` is missing, install the GitHub CLI: on a Mac `brew install gh` (no Homebrew:
the installer at https://cli.github.com); on Linux or WSL follow
https://github.com/cli/cli/blob/trunk/docs/install_linux.md. Then ask them to run `gh auth login`
in their own terminal. Check with `gh auth status`.

If `jules` is missing:
```
npm install -g @google/jules
```
Then ask them to run `jules login` in their own terminal and sign in with Google. Check with
`jules remote list --repo`.

Tell them one limit: Jules only starts from the repo's default branch on GitHub (usually `main`),
because its command line can't pick another branch. So the work must be pushed there first. The
kit refuses the job and says "push first" if it isn't.

**Kimi** (Mac only, and only if they said yes). Tell them:
1. Open https://platform.kimi.ai, sign in, and create an API key.
2. Set a spend cap there. The account is prepaid, so the simplest cap is to top up only a small
   amount. If the page offers a spending limit, set that too.
3. Open the Terminal app (not this chat) and paste:
   ```
   security add-generic-password -s routing-kit-kimi -a "$USER" -w
   ```
   It asks for the key twice without showing it. The key goes into the Mac's Keychain and never
   lands in the shell history.

**GLM** (Mac only, and only if they said yes). Same as Kimi:
1. Open https://z.ai/manage-apikey/apikey-list and create an API key.
2. Set a spend cap. Z.ai is also prepaid (https://z.ai/manage-apikey/billing): top up only a
   small amount.
3. In the Terminal app:
   ```
   security add-generic-password -s routing-kit-glm -a "$USER" -w
   ```

For both, tell them plainly: **While a Kimi or GLM job runs, the model could read the command
lines of your other running programs (not files, not keys), so don't have passwords or tokens typed
into command lines then.** The self-test shows this as `KNOWN-GAP`: a known limit of the Mac
sandbox, not a failure.

**Status line.** Offer: "I can add a small status line at the bottom of Claude Code. It records how
much of your Claude limit you have used, so the kit can spread work fairly. If you already have a
status line, it keeps showing." If yes, run `kit-statusline install`.

**Paseo** (only if `paseo` was found in step 1). Offer the Paseo pill: a small badge in Paseo that
shows how much of each plan is used. If yes:
```
paseo plugin install https://github.com/Jakobuus/claude-routing-kit.git --path paseo-pill
kit-profile set paseo true
```
Otherwise `kit-profile set paseo false`.

## Step 5: Safety notes

Read them the ones that apply to what they chose, in plain words.

- **Kimi and GLM keep what they are sent and may train on it.**
- **Only committed code goes to them. Keep secrets out of git.**
- **Never add Kimi or GLM as agents inside Paseo: Paseo would run them with full access.**
- **Never put personal details, names of people or clients, or secrets in a brief or in code you
  hand to a helper.** Briefs go to other companies' servers. Write "the client" instead of a name.
- **Jules sees whatever is in the GitHub repo you give it.** Google says it does not train on
  private repos ([Jules FAQ](https://jules.google/docs/faq/), checked 29/09/2026). It makes no such
  promise for public repos and doesn't say how long it keeps your code. Treat anything Jules sees
  as seen by Google.
- **Muse is not part of the kit.** Muse tokens only work inside the Muse app, not from a command
  line or an API.
- **Antigravity is left out on purpose, because it escaped its sandbox when run from a script.**
- **While a Kimi or GLM job runs, the model could read the command lines of your other running
  programs (not files, not keys), so don't have passwords or tokens typed into command lines
  then.**

## Step 6: Run the self-test

Run `kit-selftest`. Each line says `ok`, `FAIL: <fix>`, `KNOWN-GAP` or `SKIP`.

- For every `FAIL`, tell them in one sentence what it means and do the fix it names (or ask them to,
  if it needs their login or their terminal). Then run `kit-selftest` again.
- Exit code 5 or `FAIL: lockdown` means the Kimi/GLM sandbox did not hold on this Mac. Switch both
  off (`kit-profile set kimi false`, `kit-profile set glm false`) and tell them plainly. Everything
  else still works.
- `KNOWN-GAP` is the command-line note from step 5. `SKIP` marks a check that doesn't apply here,
  such as the Kimi/GLM sandbox on Linux. Neither needs a fix.

## Step 7: Last screen

Show them, briefly:

1. **What was installed.** Only what applies:
   - the routing-kit plugin in Claude Code;
   - the superpowers plugin, if they took it;
   - the status line, if they said yes;
   - the Paseo pill, if they said yes;
   - Keychain items `routing-kit-kimi` and `routing-kit-glm`, if they stored those keys;
   - their answers, in `~/.config/routing-kit/`.
2. **Who does what for them.** Run `kit-routing-table` and show the table. Say in one line what it
   means: strong models plan and review, cheaper ones build, and work goes to whichever plan has
   the most room left this week.
3. **Start a new session** (`/exit`, then `claude`) so the rules and this table load. From then on
   they load by themselves at the start of every session.
4. **How to see usage:** `kit-quota`.
5. **How to update:**
   ```
   claude plugin update routing-kit@routing-kit
   ```
   The Paseo pill, if they have it, updates on its own:
   ```
   paseo plugin update routing-kit-pill
   ```
6. **How to remove it**, in this order:
   ```
   kit-statusline uninstall
   paseo plugin remove routing-kit-pill
   claude plugin uninstall routing-kit@routing-kit
   rm -r ~/.config/routing-kit
   ```
   `kit-statusline uninstall` must come first, while the kit's commands still exist. It is safe even
   if they never took the status line: it only changes Claude Code's status line setting when the
   kit's own is still installed, and then puts back the one they had before. Skip the `paseo` line
   if they don't have the pill. If they stored Kimi or GLM keys, they can delete them with
   `security delete-generic-password -s routing-kit-kimi` (and `routing-kit-glm`), and delete the
   keys on the provider's site.
