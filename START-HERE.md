# START HERE: set up routing-kit

**For the agent reading this** (Claude Code, Codex or Gemini). The person who gave you this file
wants routing-kit set up. Walk them through the steps below, in order. They may not be a
programmer.

How to talk to them:

- Plain words, short sentences. Say what you are doing and why it matters to them.
- Ask one question at a time. Wait for the answer before the next one.
- Run the checks and commands yourself. Show them only what they need to decide or type.
- **Never ask for an API key, and never touch one.** When a key or login is needed, give them the
  exact line from step 5 to type into their own terminal window. If they paste a key into the chat
  anyway, tell them to delete that key on the provider's site and make a new one.
- If a step fails, say what went wrong in one sentence and what fixes it. Don't guess.

The kit lives at https://github.com/Jakobuus/claude-routing-kit.

## Step 1: Ask which agent they mainly work in

This is the first question, and the person decides. Ask exactly:

"Which agent do you mainly work in: Claude Code, Codex, or Gemini (Antigravity)?"

Remember the answer as **main agent**. Tell them plainly what their choice gets:

- **Claude Code.** The full kit, as a plugin. The rules and the routing table load by themselves
  at the start of every session. It also adds its skills, the optional status line that tracks
  your Claude limit, and one-command updates.
- **Codex.** The rules, the routing table, the field guide and the helper commands, installed from
  a copy of the kit on this computer (a git clone). The rules load at the start of every Codex
  session once you have trusted the kit's hook one time. There is no status line, and the kit does
  not update by itself: you run one update command when you want a newer version. If you also have
  a Claude plan, Claude helps with reviews and quick lookups; it does not build for you.
- **Gemini (Antigravity).** The same as Codex, installed the same way. **Say this plainly: Gemini as
  main agent has not been tested end to end yet.** It should work, but you may meet rough edges.

Do not save the answer yet. The kit refuses a main agent whose plan is not saved, so it is saved in
step 4, after the plan questions.

Ask what models and plans they already have, including free options such as Google AI Pro for
students. Record the details in step 4. The routing table follows their chosen lead; Claude is
the default when no lead is chosen.

## Step 2: Check the machine

1. Find the system. Run `uname -s`:
   - `Darwin`: **Mac**. Everything in the kit is available.
   - `Linux`: run `grep -qi microsoft /proc/version && echo WSL`. If it prints `WSL`, this is
     **WSL** (Linux inside Windows); otherwise **Linux**. Both are handled the same way below.
   - Anything else (`MINGW...`, `MSYS...`, `CYGWIN...`, or `uname` not found): **Windows without
     WSL**. Stop. Tell them: "routing-kit needs a Mac, Linux, or WSL2 on Windows. Nothing was
     installed. To get WSL2, open PowerShell as administrator, run `wsl --install`, restart the
     computer, then install their agent inside Ubuntu and give this link again."
2. Check the main agent is installed, and note its version: `claude --version` for Claude Code,
   `codex --version` for Codex, `agy --version` for Gemini. If it is missing, they are not running
   it from this terminal: stop and ask them to start the setup from inside that agent.
3. Check which tools are there, and say it back as a short list:
   - `command -v git jq python3`: all three are needed, and `python3 --version` must be 3.9 or
     newer.
     - Mac: they come with the Command Line Tools. If `git` is missing, run
       `xcode-select --install` and wait for it to finish.
     - Linux or WSL: if any is missing, ask them to run this in their own terminal (it asks for
       their password): `sudo apt update && sudo apt install -y git jq python3`. On a system
       without `apt`, they use their own package manager for the same three.
   - `command -v claude`: Claude Code. Needed for Claude as main agent, or if they have a Claude
     plan and want Claude to help.
   - `command -v agy`: the Antigravity CLI for Gemini (optional unless it is their main agent).
   - `command -v codex`: the OpenAI Codex CLI (optional unless it is their main agent).
   - `command -v jules`: the Google Jules CLI (optional).
   - `command -v gh`: the GitHub CLI. Only needed for Jules, which works on code on GitHub.
   - Paseo: `command -v paseo`, or on a Mac `/Applications/Paseo.app` (optional).

On Linux and WSL, tell them once: "Kimi and GLM won't be offered here: the kit only runs them
inside the Mac's sandbox, and Linux has no equivalent it trusts yet."

## Step 3: Install the kit

### If the main agent is Claude Code

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
   ask them to restart Claude Code (type `/exit`, start `claude` again in the same folder) and give
   this file again. Don't work around it by changing PATH or calling paths inside the plugin
   folder. `kit-profile get` shows answers already saved, so you can pick up where you left off.

### If the main agent is Codex or Gemini

1. Copy the kit onto this computer:
   ```
   git clone https://github.com/Jakobuus/claude-routing-kit ~/.config/routing-kit/kit
   ```
   If that folder already exists, run `git -C ~/.config/routing-kit/kit pull` instead.
2. **In this setup session, call the kit's commands by their full path.** A `PATH` change made in
   one shell call does not carry over to your next shell call, so do not rely on one. Every
   `kit-...` command named in this file (and `locked-build`) is then run as
   `~/.config/routing-kit/kit/plugins/routing-kit/bin/<command>`: for example,
   `~/.config/routing-kit/kit/plugins/routing-kit/bin/kit-profile get`.
3. Check the folder works:
   ```
   test -x ~/.config/routing-kit/kit/plugins/routing-kit/bin/kit-profile && echo ok
   ```
   If it does not print `ok`, the clone failed: say what the `git clone` error was and stop.
4. **Ask before editing their shell file.** So the person can type the kit's commands in their own
   terminal later, offer: "I can add one line to your shell start file so the kit's commands work
   in any new terminal. May I?" Only if they say yes, run `basename "$SHELL"` and use the line that
   fits:
   - `zsh` (the Mac default):
     ```
     echo 'export PATH="$HOME/.config/routing-kit/kit/plugins/routing-kit/bin:$PATH"' >> ~/.zshrc
     ```
   - `bash`:
     ```
     echo 'export PATH="$HOME/.config/routing-kit/kit/plugins/routing-kit/bin:$PATH"' >> ~/.bashrc
     ```
     (On a Mac, bash reads `~/.bash_profile` instead: use that file there.)

   It takes effect in the next terminal window they open. If they say no, nothing breaks: the
   rules in later sessions name the kit's commands by name, and the start-up hook tells the agent
   where they live, so a session does not depend on the PATH.

## Step 4: Ask about their plans

One question at a time. Save each answer straight away.

1. **Claude plan.** Anthropic's plan names were checked on https://claude.com/pricing on
   16/11/2026. Ask: "Which Claude plan do you have: Pro, Max, Ultra, a Team or Enterprise plan, or
   do you pay per use through the API? You can also say none." Save the matching value:

   | They say | Save |
   |---|---|
   | Pro | `kit-profile set claude_plan pro` |
   | Max (older name: Max 5x) | `kit-profile set claude_plan max5` |
   | Ultra (older name: Max 20x) | `kit-profile set claude_plan max20` |
   | Team, or Enterprise (seats) | `kit-profile set claude_plan team` |
   | API, pay per use | `kit-profile set claude_plan api` |
   | None, or Free | see below |

   Free is not a plan the kit can use. If their main agent is Claude Code, they need a paid plan or
   the API: tell them so and stop. If their main agent is Codex or Gemini, **no Claude plan is
   fine**: save `kit-profile set claude_plan none` once `main_agent` is saved (see the end of this
   step). `none` is only allowed when the main agent is not Claude Code. Claude then simply does
   not appear in their routing table.

   **If the main agent is Codex or Gemini and they have a Claude plan** (anything but none), the
   table uses Claude as a helper by running `claude -p ...`, so Claude Code must be installed and
   signed in. Do this now, before the Kimi and GLM questions:
   - If `command -v claude` finds nothing, install it with the native installer (checked on
     https://code.claude.com/docs/en/setup on 16/11/2026):
     ```
     curl -fsSL https://claude.ai/install.sh | bash
     ```
     (Mac, Linux, WSL.) Then ask them to open a new terminal window.
   - Ask them to run `claude` once in their own terminal and sign in with their Claude account,
     then close it. Don't ask for anything they see there.
   - Check by the full path, because opening a new terminal does not change the PATH of the agent
     you are running in: `~/.local/bin/claude --version` (where the native installer puts it).
     If that fails, ask them to close this agent, start it again from a new terminal window, and
     give you this file again. Their saved answers come back through `kit-profile get`.
2. **ChatGPT plan, for Codex.** "Do you have a ChatGPT plan? Codex, OpenAI's coding helper, comes
   with it. Which one: Plus, Pro, Business, API, or none?"
   `kit-profile set codex plus` (or `pro`, `business`, `api`, `none`)
3. **Gemini.** "Do you have Google AI Pro, Google AI Ultra, or neither?"
   `kit-profile set gemini pro` (or `ultra`, `none`). Google AI Pro for students counts as Pro: `kit-profile set gemini pro`.
4. **Jules.** "Do you want to use Jules, Google's coding helper? It only works on code that is on
   GitHub. Which Jules plan: free, Pro or Ultra?"
   If yes: `kit-profile set jules true`, then save the daily limit that matches the plan they named:

   | Jules plan | Save |
   |---|---|
   | free | `kit-profile set jules_daily_limit 15` |
   | Pro | `kit-profile set jules_daily_limit 100` |
   | Ultra | `kit-profile set jules_daily_limit 300` |

   If no: `kit-profile set jules false`.
5. **Kimi** and 6. **GLM.** Not on Linux or WSL: save `kit-profile set kimi false` and
   `kit-profile set glm false` without asking. On a Mac, these checks come first, whatever their main
   agent is. Kimi and GLM run through Claude Code's own program inside the Mac's sandbox, so they
   need the native Claude Code install, reachable as `claude`:
   ```
   command -v claude && readlink -f "$(command -v claude)"
   ```
   (This is the same check `locked-build` makes.) The second line must show a path that contains
   `/.local/share/claude/versions/`. If `claude` is not found, or the path points anywhere else
   (for example an npm or Homebrew install sits first on the PATH), Claude Code is not the native
   install this agent can reach. Save both as `false` and tell them why in one sentence.
   If it passes, then check that the lockdown test passed on this
   version of the kit. With the Claude Code plugin:
   ```
   ls "$(dirname "$(command -v locked-build)")/../LOCKDOWN-PASSED"
   ```
   With Codex or Gemini as main agent, look in the clone instead:
   ```
   ls ~/.config/routing-kit/kit/plugins/routing-kit/LOCKDOWN-PASSED
   ```
   If that file is missing, save both as `false` and tell them these two are switched off in this
   version. If it is there, ask about each one separately: "Kimi (from Moonshot) and GLM (from
   Z.ai) are cheap pay-per-use coding models. The kit runs them locked in a sandbox. Do you want
   Kimi?" Before they answer, read them the Kimi and GLM notes from step 6. Then
   `kit-profile set kimi true` or `false`; same for `glm`.

7. **Guards.** Ask two questions. "Turn on the guard against destructive commands?" It stops commands such as deleting a home folder, a force push, or reading folders where passwords and keys live. "Turn on the guard for owner checkouts?" It stops agents from writing in folders the user names as theirs (for example a client folder they edit by hand); if yes, ask which folders. Both are a seatbelt against agent mistakes, not a security boundary, and both are off unless the user says yes. The setting is `blocks: {"destructive": <true|false>, "owner_checkout": <true|false>}`; save the answers with `kit-profile set blocks '{"destructive": <true|false>, "owner_checkout": <true|false>}'` and, if they named folders, `kit-profile set owner_checkouts '["/full/path", ...]'`.

When all answers are in, save the main agent from step 1. The kit checks that its plan is saved,
so the order matters:

- Claude Code: `kit-profile set claude_plan ...` first (above), then `kit-profile set main_agent claude`.
- Codex: `kit-profile set codex ...` must already be a real plan, then
  `kit-profile set main_agent codex`, then (if they have no Claude plan)
  `kit-profile set claude_plan none`.
- Gemini: `kit-profile set gemini ...` must already be a real plan, then
  `kit-profile set main_agent gemini`, then (if they have no Claude plan)
  `kit-profile set claude_plan none`.

If they chose Codex or Gemini as main agent but said "none" to its plan, say so: that agent needs
its own plan, so ask which agent they will really use.

Then run `kit-profile validate`. It exits 0 when the profile is good.

## Step 5: Set up each helper they chose

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

**Gemini.** Install Antigravity from https://antigravity.google. Ask them to run `agy` in
their own terminal and sign in with Google. Check with `agy models`. The old Gemini CLI stopped
accepting Google AI plans on 18 Jun 2026.

**Jules.** Google shuts Jules down on 31 Dec 2026. Tell Jules users to move to Gemini.
If `gh` is missing, install the GitHub CLI: on a Mac `brew install gh` (no Homebrew:
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

**Status line** (only when Claude Code is their main agent; it is a Claude Code feature). Offer: "I can add a small status line at the bottom of Claude Code. It records how
much of your Claude limit you have used, so the kit can spread work fairly. If you already have a
status line, it keeps showing." If yes, run `kit-statusline install`.

**Paseo** (only if `paseo` was found in step 2). Offer the Paseo pill: a small badge in Paseo that
shows how much of each plan is used. If yes:
```
paseo plugin install https://github.com/Jakobuus/claude-routing-kit.git --path paseo-pill
kit-profile set paseo true
```
Otherwise `kit-profile set paseo false`. The `paseo` key only turns the pill on; it does not change
how builds run. If they also want Codex builds to go through Paseo, run
`kit-profile set codex_build_transport paseo` (the default is `direct`).

## Step 6: Safety notes

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
- **Codex runs without a sandbox or approval prompts**, with
  `--dangerously-bypass-approvals-and-sandbox`.
- **Gemini runs under the user's own Google account and login, without a sandbox or permission
  prompts**, with `--dangerously-skip-permissions`. Its environment is scrubbed: their shell's
  tokens and keys are not passed on. Codex and Gemini builds use fresh clones, and patches come
  from private snapshots taken after the helpers stop. Review their patches. On Linux, if a
  Gemini build reports that agy is not signed in, run it with `KIT_AGY_ALLOW_DBUS=1`, which lets
  agy reach the desktop keyring.
- **While a Kimi or GLM job runs, the model could read the command lines of your other running
  programs (not files, not keys), so don't have passwords or tokens typed into command lines
  then.**

## Step 7: Turn the rules on (Codex or Gemini only)

Skip this step if their main agent is Claude Code: the plugin already did it.

First show them what will change. Run the line for their agent with `--print`. It writes nothing:

```
kit-install-rules --agent codex --print
```
```
kit-install-rules --agent gemini --print
```

It names the settings folder, the hook file and the instructions file. Read those paths back to
them in plain words. Where they come from:

- **Codex:** the folder is `~/.codex`, or the folder named by the `CODEX_HOME` setting if they have
  one. The hook goes into `hooks.json` there. The short note goes into `AGENTS.override.md` if that
  file exists and is not empty, otherwise into `AGENTS.md`.
- **Gemini:** the hook goes into `~/.gemini/config/hooks.json` and the note into
  `~/.gemini/AGENTS.md`.

Tell them: "The kit adds one start-up hook and one short note (between `routing-kit:start` and
`routing-kit:end` lines) in those files, so the rules load at the start of each session. Anything
else already in those files stays. Before the first change I keep a backup of each existing file,
next to it, as `<file>.routing-kit.bak`." If they agree, run the same line without `--print`:

```
kit-install-rules --agent codex
```
```
kit-install-rules --agent gemini
```

Running it twice is safe.

- **Codex hook trust.** Codex runs a hook only once it is trusted. `kit-sync all` (step 7b) runs the
  hooks selftest and, only if it passes, marks the kit hooks trusted in `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`). If it
  prints a trust warning, or Codex still shows the hooks as untrusted (for example after an update before `kit-sync all` ran
  again), tell them: "Start Codex, type `/hooks`, and approve routing-kit."
- **Gemini:** say plainly once more that this path has not been tested end to end.

The hook's command is the clone's full path. If they ever move the clone, run
`kit-install-rules --agent codex` (or `gemini`) again.

## Step 7b: Share rules, skills and hooks (every main agent)

If they have their own CLAUDE.md or AGENTS.md text, move it by hand to `~/.config/routing-kit/private/rules.md` (or `$ROUTING_KIT_HOME/private/rules.md` if they set ROUTING_KIT_HOME), and empty the old file before syncing. There is no automatic adoption. Run `kit-profile set kit_rules replace` only once that file holds their full rules. The kit then keeps only its own board and media section and the routing table.

Run `kit-sync all --dry-run`, name the files it will touch, and ask. If they say yes, run `kit-sync all`. Codex and Antigravity get the blocks, the delegation check and media routing only through this step. `kit-sync hooks` runs `kit-selftest --hooks` and, only if it passes, marks the kit's Codex hooks trusted in `~/.codex/config.toml` (so they also run in scripted `codex exec` runs, with no `/hooks` step). If the selftest fails the trust is removed again and the command exits 1; Codex then skips the kit hooks until it passes.

For each repo they name, first run `kit-sync repo PATH --dry-run` and read the result back. Tell them: it moves the repo's CLAUDE.md text into AGENTS.md, leaves CLAUDE.md as one line that points to it, moves repo skills to `.agents/skills`, and makes one git commit. The repo must have no uncommitted changes. Run it only if they say yes. To take it back, revert that commit (`git revert`); `--undo` does not apply here.

`kit-sync rules|skills|hooks --undo` (or `kit-sync all --undo`) takes out the kit's rules block, skill links and hook entries. It never restores old copies. It removes the Codex trust block it wrote (one block at the end of config.toml between two `# routing-kit hook trust` comment lines; if anything was added after it, nothing is removed and it tells you to remove it by hand) and leaves the `project_doc_max_bytes` line in Codex's config.toml; remove that by hand if wanted. It refuses a rules block edited by hand unless `--force` is added. Shared skills are the kit's own skills plus folders listed under `skills` in the profile. Edit `skills` and `products` by hand in `~/.config/routing-kit/profile.json`; `kit-route` uses `products` to find options for media and document jobs.

`kit-doctor` lists hand edits and missing pieces in what kit-sync wrote, rule files too big for an agent, new hook errors since the last check, and media jobs from the last 7 days with how many got a suggested route (it cannot tell whether the agent followed it). `kit-board` supports post, read, claims and send. `<owner> says (quoted via <from>)` shows the profile's `owner_name` (`kit-profile set owner_name NAME`), or "the owner"; another agent's note is not the owner's approval. `kit-quota --pick "<row name from the routing table>"`, for example `kit-quota --pick "Read-only lookups"`, names the model in that row whose plan has the most room left this week.

## Step 8: Run the self-test

Run `kit-selftest`. Check lines say `<check>: ok`, `<check>: FAIL: <fix>` or `<check>: SKIP`; a `WARN: KNOWN-GAP` line is a note, and diagnostic and summary lines may appear too.

- For every `FAIL`, tell them in one sentence what it means and do the fix it names (or ask them to,
  if it needs their login or their terminal). Then run `kit-selftest` again.
- Exit code 5 or `canaries: FAIL:` means the Kimi/GLM sandbox did not hold on this Mac. Switch both
  off (`kit-profile set kimi false`, `kit-profile set glm false`) and tell them plainly. Everything
  else still works.
- `KNOWN-GAP` is the command-line note from step 6. `SKIP` marks a check that doesn't apply here,
  such as the Kimi/GLM sandbox on Linux. Neither needs a fix.
- **If you (the agent) run inside a sandbox**, some checks can fail for that reason
  alone: the Codex build check needs the network, and the lockdown check needs to create test files
  under the home folder. Do not switch anything off because of such a failure, and do not tell
  them the kit is broken. Report it as "could not be checked from inside my sandbox". Then ask them
  to run the self-test once in their own terminal and paste the result. Codex or Gemini installs:
  `~/.config/routing-kit/kit/plugins/routing-kit/bin/kit-selftest`. Claude Code: `kit-selftest`.
  Real failures, which still show when run in their own terminal, keep the guidance above.
- For Codex or Gemini as main agent, the self-test checks the kit and the helpers. It cannot see
  whether the agent itself loaded the rules. Step 9 has the one-question check for that.

## Step 9: Last screen

Show them, briefly:

1. **What was installed.** Only what applies:
   - Claude Code: the routing-kit plugin;
   - Codex or Gemini: a copy of the kit in `~/.config/routing-kit/kit`, one line in their shell
     settings file (the PATH line, only if they agreed), and the start-up hook plus a short note in the agent's own
     settings folder (step 7);
   - if they ran `kit-sync all`: a marked rules block in CLAUDE.md and both AGENTS.md files, the kit hooks in Codex and Antigravity hooks files, skill links in `~/.agents/skills` and `~/.claude/skills`, and in `~/.codex/config.toml` one line plus, once the hooks selftest passes, one trust table per kit hook;
   - the superpowers plugin, if they took it;
   - the status line, if they said yes;
   - the Paseo pill, if they said yes;
   - Keychain items `routing-kit-kimi` and `routing-kit-glm`, if they stored those keys;
   - their answers, in `~/.config/routing-kit/`.
2. **Who does what for them.** Run `kit-routing-table` and show the table. Say in one line what it
   means: strong models plan and review, cheaper ones build, and work goes to whichever plan has
   the most room left this week.
3. **The field guide.** The table follows a field guide of the current models: which model is good
   at what, with sources and the date the facts were checked. The maintainer refreshes it from
   time to time and ships it as a kit update. Offer to open it for them:
   ```
   cat "$(dirname "$(command -v kit-profile)")/../guide/FIELD-GUIDE.md"
   ```
   (Codex or Gemini: `cat ~/.config/routing-kit/kit/plugins/routing-kit/guide/FIELD-GUIDE.md`.)
   At the start of each session the kit adds one line if the guide is more than 7 days old, and
   the table carries a note when a model is not offered by their installed Codex or Gemini. Both
   say how to update.
4. **Start a new session** so the rules and this table load: for Claude Code `/exit`, then `claude`;
   for Codex or Gemini, start the agent again (Codex: `kit-sync all` trusts the hooks after its selftest unless it
   printed a trust warning; see step 7). From then on they load by themselves at the start of every session. Check once: in the
   new session, ask "Which model do you send a read-only lookup to?" The answer should match the
   Read-only lookups row of the table. If it does not, the rules did not load: go back to step 7.
5. **How to see usage:** `kit-quota`. See [Usage and build commands](README.md#usage-and-build-commands)
   for optional Claude database and banked-reset settings, stale readings, Jules limits,
   and the Codex/Gemini build flags and exit codes. Codex builds go through Paseo by default
   only when the profile has `"codex_build_transport": "paseo"` (default `direct`); `--paseo` and
   `--no-paseo` override it. Build copies are deleted once their work is saved; otherwise they are kept, in
   `retained` (see `kit-retained`) or, for refused or pending runs, in their run folder.
   Blocking guards get 10 seconds each; `hook-errors.log` entries have timestamps.
   With Gemini available, the "Exploration, big reads" row uses its research model to write a
   summary of facts and decide nothing.
6. **How to update.** Claude Code:
   ```
   claude plugin update routing-kit@routing-kit
   ```
   Codex or Gemini: pull the newest copy, then write the rules in again:
   ```
   git -C ~/.config/routing-kit/kit pull
   kit-install-rules --agent codex
   ```
   (use `--agent gemini` for Gemini).
   Every user must run `kit-sync hooks` after updating to refresh hook timeouts.
   Then run `kit-sync all` again. Do the same after changing private/rules.md or their plans; edit that file, never the block between the routing-kit:rules lines.
   Then start a new session. The Paseo pill, if they have it, updates on its own:
   ```
   paseo plugin update routing-kit-pill
   ```
7. **How to remove it**, in this order.
   Run `kit-sync all --undo` only if they ran kit-sync; it must come first, while the kit and its record in `~/.config/routing-kit` still exist.
   Claude Code:
   ```
   kit-sync all --undo
   kit-statusline uninstall
   paseo plugin remove routing-kit-pill
   claude plugin uninstall routing-kit@routing-kit
   rm -r ~/.config/routing-kit
   ```
   `kit-statusline uninstall` must come first, while the kit's commands still exist. It is safe even
   if they never took the status line: it only changes Claude Code's status line setting when the
   kit's own is still installed, and then puts back the one they had before. Skip the `paseo` line
   if they don't have the pill.

   Codex or Gemini:
   ```
   kit-sync all --undo
   kit-install-rules --agent codex --uninstall
   paseo plugin remove routing-kit-pill
   rm -r ~/.config/routing-kit
   ```
   (use `--agent gemini` for Gemini). The first line must come while the kit's commands still
   exist: it takes the hook and the note out of the agent's settings folder and puts back the
   original files where it can. Skip the `paseo` line if they don't have the pill. Last, if they
   agreed to the PATH line in step 3, ask them to open their shell settings file (`~/.zshrc`, `~/.bashrc` or `~/.bash_profile`) and delete the line that mentions
   `.config/routing-kit/kit/plugins/routing-kit/bin`.

   Either way: if they stored Kimi or GLM keys, they can delete them with
   `security delete-generic-password -s routing-kit-kimi` (and `routing-kit-glm`), and delete the
   keys on the provider's site.
