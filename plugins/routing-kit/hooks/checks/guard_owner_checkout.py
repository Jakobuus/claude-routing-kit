#!/usr/bin/env python3
"""Guard writes into owner checkouts from other repositories."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

KIT_HOME = Path(os.environ.get("ROUTING_KIT_HOME", Path.home() / ".config/routing-kit"))
WATCHED_TOOLS = {"Write", "Edit", "NotebookEdit", "MultiEdit"}
OVERRIDE_ENV = "CW_ALLOW_OWNER_WRITE"
OVERRIDE_LOG = KIT_HOME / "owner-checkout-overrides.log"


def real(p: Path) -> Path:
    """Resolve symlinks and `..` so neither can walk around the prefix test."""
    try:
        return p.resolve()
    except (OSError, RuntimeError):
        return p


def repo_root(cwd: str) -> Path | None:
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    top = out.stdout.strip()
    return real(Path(top)) if top else None


def inside(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def deny(reason: str) -> None:
    print(json.dumps({"action": "deny", "reason": reason}))


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return  # fail open

    try:
        profile = json.loads((KIT_HOME / "profile.json").read_text())
    except (OSError, ValueError):
        return
    blocks = profile.get("blocks")
    enabled = blocks is True or (isinstance(blocks, dict) and blocks.get("owner_checkout") is True)
    if not enabled or data.get("event") != "PreToolUse":
        return
    tool = data.get("tool") or {}
    if tool.get("kind") != "write":
        return
    for raw in tool.get("paths", []):
        for checkout in profile.get("owner_checkouts", []):
            if check_target(data, raw, checkout):
                return  # one decision per call: stop at the first denied target


def check_target(data, raw, checkout) -> bool:
    """Print a deny and return True when this target is forbidden."""
    target = real(Path(data.get("cwd") or os.getcwd()) / Path(raw).expanduser())
    owner = real(Path(checkout).expanduser())
    if not inside(target, owner):
        return False

    # The store lane's carve-out: the live store, never a tracked document.
    rel = target.relative_to(owner).as_posix()
    parts = rel.split("/")
    if len(parts) >= 3 and parts[0] == "clients" and parts[2] == "data":
        return False

    mine = repo_root(data.get("cwd") or os.getcwd())
    if mine is not None and mine == owner:
        return False  # this session IS his checkout; that case never failed

    override = os.environ.get(OVERRIDE_ENV, "").strip()
    if override and override.lower() not in {"1", "true", "yes", "y"}:
        try:
            OVERRIDE_LOG.parent.mkdir(parents=True, exist_ok=True)
            with OVERRIDE_LOG.open("a") as fh:
                fh.write(
                    "%s\t%s\t%s\n" % (time.strftime("%d/%m/%Y %H:%M:%S"), rel, override)
                )
        except OSError:
            pass
        return False

    deny("Write into owner checkout %s from another repository. "
         "Use this session's worktree, or set %s to a reason (logged)."
         % (owner, OVERRIDE_ENV))
    return True



if __name__ == "__main__":
    main()
