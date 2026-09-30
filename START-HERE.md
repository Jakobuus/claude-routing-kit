# START HERE: set up routing-kit

**For Claude.** The person who dropped this file into Claude Code wants routing-kit set up. Walk
them through the steps below, in order. They may not be a programmer.

How to talk to them while you do this:

- Plain words, short sentences. Say what you are doing and why it matters to them.
- Ask one question at a time. Wait for the answer before the next one.
- Run the checks and commands yourself. Show them only what they need to decide or type.
- **Never ask for an API key, and never touch one.** If a key is needed, give them the one
  `security` line from step 4 to type into their own Terminal window. If they paste a key into the
  chat anyway, tell them to delete that key on the provider's site and make a new one.
- If a step fails, say what went wrong in one sentence and what fixes it. Don't guess.

The kit lives at https://github.com/Jakobuus/claude-routing-kit.

## Step 1: Check the machine

1. Run `uname`. If it is not `Darwin`, stop. Tell them: "routing-kit only works on a Mac. Nothing
   was installed, and nothing on this computer was changed."
2. Run `claude --version` and note it.
3. Check which tools are already there, and say it back as a short list:
   - `command -v git jq python3`: needed. On a stock Mac they come with the Command Line Tools.
     If `git` is missing, run `xcode-select --install` and wait for it to finish.
   - `command -v codex`: the OpenAI Codex CLI (optional).
   - `command -v jules`: the Google Jules CLI (optional).
   - `command -v gh`: the GitHub CLI. Only needed if they want Jules, because Jules works on code
     that is on GitHub. If it is missing and they want Jules, install it in step 4.
   - Paseo: `/Applications/Paseo.app` exists, or `command -v paseo` (optional).

## Step 2: Install the plugin

1. Run:
   ```
   claude plugin marketplace add Jakobuus/claude-routing-kit
   claude plugin install routing-kit@routing-kit
   ```
2. Offer the superpowers plugin as a recommended add-on. Say: "It adds skills for writing plans
   and working through them step by step. The kit's rules use it for big jobs when it is there."
   If they want it:
   ```
   claude plugin install superpowers@claude-plugins-official
   ```
3. Check that the kit's commands are reachable: `command -v kit-profile`. If it is not found, stop
   and ask them to restart Claude Code (type `/exit`, start `claude` again in the same folder) and
   drop this file in again. Do not work around it by changing PATH or calling full paths into the
   plugin folder. You will pick up where you left off: `kit-profile get` shows the answers already
   saved.

## Step 3: Ask about their plans

Ask these one at a time. Save each answer straight away with `kit-profile set`.

1. **Claude plan.** "Which Claude plan do you have: Pro, Max 5x, Max 20x, Team, or do you pay per
   use through the API?"
   `kit-profile set claude_plan pro` (or `max5`, `max20`, `team`, `api`)
2. **ChatGPT plan, for Codex.** "Do you have a ChatGPT plan? Codex, OpenAI's coding helper, comes
   with it. Which one: Plus, Pro, Business, API, or none?"
   `kit-profile set codex plus` (or `pro`, `business`, `api`, `none`)
3. **Jules.** "Do you want to use Jules, Google's coding helper? It only works on code that is on
   GitHub. Which Jules plan: free, Pro or Ultra?"
   If yes: `kit-profile set jules true` and `kit-profile set jules_daily_limit 15` (free is 15 tasks
   a day, Pro 100, Ultra 300). If no: `kit-profile set jules false`.
4. **Kimi** and 5. **GLM.** First check that the lockdown test passed on this version of the kit:
   ```
   ls "$(dirname "$(command -v locked-build)")/../LOCKDOWN-PASSED"
   ```
   If that file is missing, don't offer Kimi or GLM. Save `kit-profile set kimi false` and
   `kit-profile set glm false`, and tell them these two are switched off in this version.
   If the file is there, ask about each one separately: "Kimi (from Moonshot) and GLM (from Z.ai)
   are cheap pay-per-use coding models. The kit runs them locked in a sandbox. Do you want Kimi?"
   Before they answer, read them the safety notes in step 5 that are about Kimi and GLM.
   Then `kit-profile set kimi true` or `false`; same for `glm`.

When all answers are in, run `kit-profile validate`. It exits 0 when the profile is good.

## Step 4: Set up each helper they chose

Skip any helper they said no to.

**Codex.** If `codex` is missing, install it with one of these (check that the command still
works with `npm view @openai/codex version` or `brew info --cask codex` first):
```
npm i -g @openai/codex
```
or `brew install --cask codex`. Then sign them in. Which way depends on their answer in step 3:

- **ChatGPT plan** (Plus, Pro, Business): ask them to run `codex login` in their own Terminal
  window and sign in with their ChatGPT account.
- **API** (they pay OpenAI per use): they need an OpenAI API key from
  https://platform.openai.com/api-keys. Ask them to copy the key on that page, then open the
  Terminal app (not this chat) and paste this line:
  ```
  pbpaste | codex login --with-api-key
  ```
  It hands the copied key to Codex without showing it or saving it in the shell history. Then
  they copy something else, so the key doesn't stay on the clipboard. Don't ask to see the key,
  and don't run this line for them.

Check with `codex login status`.

**Jules.** If `gh` is missing, install the GitHub CLI:
```
brew install gh
```
(If they have no Homebrew, point them to https://cli.github.com for the Mac installer.) Then ask
them to run `gh auth login` in their own Terminal window and sign in to GitHub. Check with
`gh auth status`.

If `jules` is missing:
```
npm install -g @google/jules
```
Then ask them to run `jules login` in their own Terminal window and sign in with Google. Check with
`jules remote list --repo`.

Tell them one limit: Jules only starts from the repo's default branch on GitHub (usually `main`),
because the Jules command line has no way to pick another branch. So before a Jules job, the work
must be pushed to that branch. The kit refuses the job and says "push first" if it isn't.

**Kimi** (only if they said yes). Tell them:
1. Open https://platform.kimi.ai, sign in, and create an API key.
2. Set a spend cap there. The account is prepaid, so the simplest cap is to top up only a small
   amount. If the page offers a spending limit, set that too.
3. Open the Terminal app (not this chat) and paste this line:
   ```
   security add-generic-password -s routing-kit-kimi -a "$USER" -w
   ```
   It asks for the key, twice, without showing it. The key goes into the Mac's Keychain and never
   lands in the shell history. Don't paste the key here.

**GLM** (only if they said yes). Same as Kimi:
1. Open https://z.ai/manage-apikey/apikey-list and create an API key.
2. Set a spend cap. Z.ai is also prepaid (https://z.ai/manage-apikey/billing): top up only a
   small amount.
3. In their own Terminal window:
   ```
   security add-generic-password -s routing-kit-glm -a "$USER" -w
   ```

For both Kimi and GLM, tell them this in plain words: **While a Kimi or GLM job runs, the model
could read the command lines of your other running programs (not files, not keys), so don't have
passwords or tokens typed into command lines then.** The self-test shows this as `KNOWN-GAP`. It is
a known limit of the Mac sandbox, not a failure.

**Status line.** Offer: "I can add a small status line at the bottom of Claude Code. It records how
much of your Claude limit you have used, so the kit can spread work fairly. If you already have a
status line, it keeps showing." If yes, run `kit-statusline install`. It saves their existing
status line from Claude Code's settings and runs its command after the kit's step.

**Paseo** (only if Paseo is installed). Offer the Paseo pill: a small badge in Paseo that shows how
much of each plan is used. If yes:
```
paseo plugin install https://github.com/Jakobuus/claude-routing-kit.git --path paseo-pill
kit-profile set paseo true
```
Otherwise `kit-profile set paseo false`.

## Step 5: Safety notes

Read these to them in plain words. Don't skip any that apply to what they chose.

- **Kimi and GLM keep what they are sent and may train on it.**
- **Only committed code goes to them. Keep secrets out of git.**
- **Never add Kimi or GLM as agents inside Paseo: Paseo would run them with full access.**
- **Never put personal details, names of people or clients, or secrets in a brief or in code you
  hand to a helper.** Briefs go to other companies' servers. Write "the client" instead of a name.
- **Jules sees whatever is in the GitHub repo you give it.** Google says it does not train on
  private repos
  ([Jules FAQ](https://jules.google/docs/faq/), checked 29/09/2026). It makes no such promise for
  public repos, and it doesn't say how long it keeps your code. So treat anything Jules sees as
  seen by Google.
- **Muse is not part of the kit.** Muse tokens only work inside the Muse app. They can't power a
  command line or an API, so the kit has no way to use them.
- **Antigravity is left out on purpose, because it escaped its sandbox when run from a script.**
- **While a Kimi or GLM job runs, the model could read the command lines of your other running
  programs (not files, not keys), so don't have passwords or tokens typed into command lines
  then.**

## Step 6: Run the self-test

Run `kit-selftest`. Each line says `ok`, `FAIL: <fix>` or `KNOWN-GAP`.

- For every `FAIL`, tell them in one sentence what it means and do the fix it names (or ask them to
  do it, if it needs their login or their Terminal). Then run `kit-selftest` again.
- Exit code 5 or `FAIL: lockdown` means the Kimi/GLM sandbox did not hold on this Mac. Switch both
  off (`kit-profile set kimi false`, `kit-profile set glm false`) and tell them plainly. Everything
  else in the kit still works.
- `KNOWN-GAP` is the command-line note from step 5. No fix needed.

## Step 7: Last screen

Show them, briefly:

1. **What was installed.** List only what applies:
   - the routing-kit plugin in Claude Code;
   - the superpowers plugin, if they took it;
   - the status line, if they said yes to it;
   - the Paseo pill, if they said yes to it;
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
   If they have the Paseo pill, it updates on its own track:
   ```
   paseo plugin update routing-kit-pill
   ```
6. **How to remove it:**
   ```
   kit-statusline uninstall
   paseo plugin remove routing-kit-pill
   claude plugin uninstall routing-kit@routing-kit
   rm -r ~/.config/routing-kit
   ```
   `kit-statusline uninstall` must come first, while the kit's commands still exist. It is safe to
   run even if they never took the status line: it only changes Claude Code's status line setting
   when the kit's own status line is still the one installed, and then puts back the one they had
   before. If they changed their status line since, it leaves it alone. Skip the `paseo` line if
   they don't have the pill. If they stored Kimi or GLM keys, they can also delete them from the
   Keychain with `security delete-generic-password -s routing-kit-kimi` (and `routing-kit-glm`),
   and delete the keys on the provider's site.
