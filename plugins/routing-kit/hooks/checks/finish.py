#!/usr/bin/env python3
"""Session exit prompt and optional continuation check."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

PREP_TEXT = 'SESSION-END TRIGGER: {owner} asked to prep for exit. Invoke the Skill tool with skill: "prep-for-exit" BEFORE any other action and follow the protocol exactly: every checklist item gets a LIVE check in this turn (verify, never assert from memory). End with the literal line \'✅ SAFE TO EXIT\' plus the correct exit command ONLY if every item passed; otherwise say \'⛔ NOT SAFE YET\' and list exactly what remains.'
PATTERN = re.compile(
    r"prep(are)? (for )?exit|prep.{0,12}end.{0,6}session|safe to (exit|leave)|"
    r"close (up )?(this |the )?session|wrap up (this |the )?session|"
    r"done for today|all pushed.*(committed|memory)", re.IGNORECASE)


def has_prep_skill(event):
    """The trigger names a "prep-for-exit" skill the kit does not ship: send it only when the agent of this
    event can load one (its own skill folders: user-level and the project's, as kit-sync shares them)."""
    home = Path.home()
    cwd = Path(event.get("cwd") or ".")
    projects = [cwd] + list(cwd.parents)   # a project skill may sit at the repo root above the cwd
    agent = event.get("agent")
    if agent == "claude":
        dirs = [Path(os.environ.get("CLAUDE_CONFIG_DIR") or str(home / ".claude"))] + [p / ".claude" for p in projects]
    elif agent == "codex":
        dirs = [home / ".agents", Path(os.environ.get("CODEX_HOME") or str(home / ".codex"))] + [p / ".agents" for p in projects]
    else:
        dirs = [home / ".agents", home / ".gemini"] + [p / ".agents" for p in projects]
    return any((d / "skills" / "prep-for-exit" / "SKILL.md").is_file() for d in dirs)


def main():
    raw = sys.stdin.read()
    event = json.loads(raw)
    if event.get("event") in ("UserPromptSubmit", "PreInvocation"):
        prompt = (event.get("prompt") or "").rstrip("\n")
        if not event.get("first_in_turn") or len(prompt) > 300:
            return
        # sed strips spans on each line, double quotes before single quotes.
        stripped = re.sub(r'"[^"\n]*"', "", prompt)
        stripped = re.sub(r"'[^'\n]*'", "", stripped)
        home = Path(os.environ.get("ROUTING_KIT_HOME") or str(Path.home() / ".config/routing-kit"))
        try:
            owner = json.loads((home / "profile.json").read_text()).get("owner_name", "the owner")
        except (OSError, ValueError):
            owner = "the owner"
        if PATTERN.search(stripped) and has_prep_skill(event):
            print(json.dumps({"action": "context", "text": PREP_TEXT.format(owner=owner)}))
        return
    if event.get("event") != "Stop" or os.environ.get("DOUBLE_SHOT_LATTE") != "1":
        return
    home = Path(os.environ.get("ROUTING_KIT_HOME") or
                str(Path.home() / ".config/routing-kit"))
    judge = json.loads((home / "profile.json").read_text()).get("continuation_judge")
    if not judge:
        return
    sid = str(event.get("session_id") or "unknown").replace("/", "_")
    counter = home / (".claude-continue-throttle-" + sid)
    count, last = 0, 0
    try:
        count, last = map(int, counter.read_text().strip().split(":"))
    except (OSError, ValueError):
        pass
    now = int(time.time())
    if event.get("stop_hook_active") and count >= 3 and now - last < 300:
        counter.unlink(missing_ok=True)
        return
    result = subprocess.run([judge], input=raw, text=True, capture_output=True, timeout=55)
    if result.returncode:
        return
    verdict = json.loads(result.stdout)
    if verdict.get("decision") == "approve":
        counter.unlink(missing_ok=True)
    elif verdict.get("decision") == "block":
        home.mkdir(parents=True, exist_ok=True)
        counter.write_text(f"{count + 1}:{now}\n")
        print(json.dumps({"action": "continue", "reason": verdict.get("reason", "")}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired):
        pass
