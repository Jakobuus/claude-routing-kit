#!/usr/bin/env python3
"""kit-sync skills implementation (invoked via kit_python3)."""

import json
import os
import re
import stat
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync_lock  # noqa: E402

USAGE = (
    "usage: kit-sync skills [--dry-run] [--undo] "
    "[--home-claude D] [--home-gemini D] [--agents-dir D]"
)

_FM_KEY_RE = re.compile(r"^([A-Za-z0-9_-]+)\s*:\s*(.*)$")


def parse_args(argv):
    dry_run = False
    undo = False
    home = os.environ.get("HOME") or os.path.expanduser("~")
    home_claude = os.path.join(home, ".claude")
    home_gemini = os.path.join(home, ".gemini")
    agents_dir = os.path.join(home, ".agents", "skills")

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            print(USAGE)
            sys.exit(0)
        elif arg == "--dry-run":
            dry_run = True
            i += 1
        elif arg == "--undo":
            undo = True
            i += 1
        elif arg == "--home-claude":
            if i + 1 >= len(argv):
                print(USAGE, file=sys.stderr)
                sys.exit(2)
            home_claude = argv[i + 1]
            i += 2
        elif arg == "--home-gemini":
            if i + 1 >= len(argv):
                print(USAGE, file=sys.stderr)
                sys.exit(2)
            home_gemini = argv[i + 1]
            i += 2
        elif arg == "--agents-dir":
            if i + 1 >= len(argv):
                print(USAGE, file=sys.stderr)
                sys.exit(2)
            agents_dir = argv[i + 1]
            i += 2
        else:
            print(USAGE, file=sys.stderr)
            sys.exit(2)

    return {
        "dry_run": dry_run,
        "undo": undo,
        "home_claude": os.path.abspath(os.path.expanduser(home_claude)),
        "home_gemini": os.path.abspath(os.path.expanduser(home_gemini)),
        "agents_dir": os.path.abspath(os.path.expanduser(agents_dir)),
    }


def has_valid_frontmatter(skill_dir):
    skill_md = os.path.join(skill_dir, "SKILL.md")
    if not os.path.isfile(skill_md):
        return False, "missing SKILL.md"
    try:
        with open(skill_md, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as exc:
        return False, f"cannot read SKILL.md: {exc}"

    if not lines or lines[0].strip() != "---":
        return False, "SKILL.md missing YAML frontmatter"

    end_idx = None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            end_idx = idx
            break
    if end_idx is None:
        return False, "SKILL.md has unclosed YAML frontmatter"

    fm_lines = lines[1:end_idx]
    fields = {}
    current_key = None
    for line in fm_lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] not in (" ", "\t"):
            m = _FM_KEY_RE.match(line)
            if m:
                current_key = m.group(1)
                val = m.group(2).strip()
                if val in (">-", ">", "|", "|-", "|+", ">+"):
                    fields[current_key] = ""
                else:
                    fields[current_key] = val.strip("\"'")
            else:
                current_key = None
        else:
            if current_key is not None and not fields.get(current_key):
                fields[current_key] = line.strip()

    missing = [k for k in ("name", "description") if not fields.get(k)]
    if missing:
        return False, f"SKILL.md missing frontmatter: {', '.join(missing)}"
    return True, ""


def is_claude_plugin_skill(src, home_claude):
    plugins_dir = os.path.join(home_claude, "plugins")
    for s_path, p_dir in (
        (os.path.abspath(src), os.path.abspath(plugins_dir)),
        (os.path.realpath(src), os.path.realpath(plugins_dir)),
    ):
        if s_path == p_dir or s_path.startswith(p_dir + os.sep):
            return True
    return False


def write_json_atomic(path, data):
    path = os.path.realpath(path)
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else None
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        dir=parent, prefix=os.path.basename(path) + ".tmp."
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        if mode is not None:
            os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def load_json_dict(path):
    if not os.path.lexists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("expected JSON object")
        return data
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc


def discover_skills(plugin_root, kit_home):
    candidates = []
    kit_skills_dir = os.path.join(plugin_root, "skills")
    if os.path.isdir(kit_skills_dir):
        for name in sorted(os.listdir(kit_skills_dir)):
            if name.startswith("."):
                continue
            p = os.path.join(kit_skills_dir, name)
            if os.path.isdir(p):
                candidates.append(p)

    profile_path = os.path.join(kit_home, "profile.json")
    if os.path.isfile(profile_path):
        profile = load_json_dict(profile_path)
        raw_skills = profile.get("skills")
        if isinstance(raw_skills, list):
            for entry in raw_skills:
                if isinstance(entry, str) and entry:
                    expanded = os.path.abspath(os.path.expanduser(entry))
                    norm = expanded.rstrip("/") or "/"
                    candidates.append(norm)

    valid = []
    seen = {}
    for src in candidates:
        if not os.path.isdir(src):
            print(f"warning: skill folder not found: {src}", file=sys.stderr)
            continue
        ok, reason = has_valid_frontmatter(src)
        name = os.path.basename(src)
        if not ok:
            print(f"warning: skipping {name} ({src}): {reason}", file=sys.stderr)
            continue
        if name in seen:
            idx = seen[name]
            valid[idx] = (name, src)
        else:
            seen[name] = len(valid)
            valid.append((name, src))
    return valid


def run_undo(opts, state_path):
    dry_run = opts["dry_run"]
    home_gemini = opts["home_gemini"]
    agents_dir = opts["agents_dir"]

    state = load_json_dict(state_path)
    links = state.get("links")
    if not isinstance(links, dict):
        links = {}

    changes = []
    remaining_links = {}
    for link_path, info in links.items():
        target = info.get("target") if isinstance(info, dict) else None
        if os.path.islink(link_path):
            cur = os.readlink(link_path)
            if target is not None and cur == target:
                if not dry_run:
                    os.unlink(link_path)
                changes.append(f"removed link {link_path}")
            else:
                remaining_links[link_path] = info

    sj_info = state.get("skills_json")
    sj_file = os.path.join(home_gemini, "config", "skills.json")
    sj_path = agents_dir
    if isinstance(sj_info, dict):
        sj_file = sj_info.get("file") or sj_file
        sj_path = sj_info.get("path") or sj_path

    if isinstance(sj_info, dict) and sj_info.get("added") is True and os.path.isfile(sj_file):
        sj_data = load_json_dict(sj_file)
        entries = sj_data.get("entries")
        if isinstance(entries, list):
            new_entries = [
                e for e in entries
                if not (isinstance(e, dict) and e.get("path") == sj_path)
            ]
            if len(new_entries) != len(entries):
                sj_data["entries"] = new_entries
                if not dry_run:
                    write_json_atomic(sj_file, sj_data)
                changes.append(f"removed {sj_path} from {sj_file}")

    if not dry_run and os.path.exists(state_path) or changes:
        state["links"] = remaining_links
        state.pop("skills_json", None)
        if not dry_run:
            write_json_atomic(state_path, state)

    if changes:
        for line in changes:
            print(line)
    else:
        print("no changes")
    return 0


def run_sync(opts, plugin_root, kit_home, state_path):
    dry_run = opts["dry_run"]
    home_claude = opts["home_claude"]
    home_gemini = opts["home_gemini"]
    agents_dir = opts["agents_dir"]

    skills = discover_skills(plugin_root, kit_home)
    state = load_json_dict(state_path)
    old_links = state.get("links")
    if not isinstance(old_links, dict):
        old_links = {}

    new_links = dict(old_links)
    changes = []

    claude_skills_dir = os.path.join(home_claude, "skills")

    try:
        for name, src in skills:
            # 1. Link in <agents-dir>/<name> -> src
            agent_link = os.path.join(agents_dir, name)
            if os.path.islink(agent_link):
                cur = os.readlink(agent_link)
                if old_links.get(agent_link, {}).get("target") != cur:
                    print(f"kept your own {name} ({agent_link})")
                    new_links.pop(agent_link, None)
                    continue
                if cur != src:
                    if not dry_run:
                        os.makedirs(agents_dir, exist_ok=True)
                        os.unlink(agent_link)
                        os.symlink(src, agent_link)
                    changes.append(f"link {agent_link} -> {src}")
                new_links[agent_link] = {
                    "target": src,
                    "skill": name,
                    "agent": "codex",
                }
            elif os.path.exists(agent_link):
                print(f"kept your own {name} ({agent_link})")
            else:
                if not dry_run:
                    os.makedirs(agents_dir, exist_ok=True)
                    os.symlink(src, agent_link)
                changes.append(f"link {agent_link} -> {src}")
                new_links[agent_link] = {
                    "target": src,
                    "skill": name,
                    "agent": "codex",
                }
    
            # 2. Link in <claude-home>/skills/<name> -> <agents-dir>/<name>
            if (is_claude_plugin_skill(src, home_claude)
                    or os.path.realpath(claude_skills_dir) == os.path.realpath(agents_dir)
                    or os.path.realpath(os.path.dirname(src)) == os.path.realpath(claude_skills_dir)):
                continue
    
            claude_link = os.path.join(claude_skills_dir, name)
            claude_target = agent_link
            if os.path.islink(claude_link):
                cur = os.readlink(claude_link)
                if old_links.get(claude_link, {}).get("target") != cur:
                    print(f"kept your own {name} ({claude_link})")
                    new_links.pop(claude_link, None)
                    continue
                if cur != claude_target:
                    if not dry_run:
                        os.makedirs(claude_skills_dir, exist_ok=True)
                        os.unlink(claude_link)
                        os.symlink(claude_target, claude_link)
                    changes.append(f"link {claude_link} -> {claude_target}")
                new_links[claude_link] = {
                    "target": claude_target,
                    "skill": name,
                    "agent": "claude",
                }
            elif os.path.exists(claude_link):
                print(f"kept your own {name}")
            else:
                if not dry_run:
                    os.makedirs(claude_skills_dir, exist_ok=True)
                    os.symlink(claude_target, claude_link)
                changes.append(f"link {claude_link} -> {claude_target}")
                new_links[claude_link] = {
                    "target": claude_target,
                    "skill": name,
                    "agent": "claude",
                }
    
        # 3. Antigravity <gemini-home>/config/skills.json
        skills_json_path = os.path.join(home_gemini, "config", "skills.json")
        sj_data = load_json_dict(skills_json_path)
        entries = sj_data.get("entries", [])
        if not isinstance(entries, list):
            raise ValueError(f"cannot read {skills_json_path}: entries must be a list")
        matching = any(
            isinstance(e, dict) and isinstance(e.get("path"), str)
            and os.path.realpath(os.path.expanduser(os.path.expandvars(e["path"])))
            == os.path.realpath(agents_dir) for e in entries
        )
        if not matching:
            sj_data["entries"] = entries + [{"path": agents_dir}]
            if not dry_run:
                write_json_atomic(skills_json_path, sj_data)
                state["skills_json"] = {"file": skills_json_path, "path": agents_dir, "added": True}
            changes.append(f"skills.json {skills_json_path} (+ {agents_dir})")
    finally:
        if not dry_run:
            state["links"] = new_links
            write_json_atomic(state_path, state)

    if changes:
        for line in changes:
            print(line)
    else:
        print("no changes")
    return 0


def main():
    opts = parse_args(sys.argv[1:])
    home = os.environ.get("HOME") or os.path.expanduser("~")
    kit_home = os.environ.get("ROUTING_KIT_HOME") or os.path.join(
        home, ".config", "routing-kit"
    )
    plugin_root = os.path.realpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    )
    state_path = os.path.join(kit_home, "sync-state.json")

    try:
        sync_lock.acquire(kit_home)
        return run_undo(opts, state_path) if opts["undo"] else run_sync(opts, plugin_root, kit_home, state_path)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
