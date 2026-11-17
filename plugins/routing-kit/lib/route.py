"""Choose media tools covered by the user's plans."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from media_match import media_jobs, match_job


def read_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def covered(product, profile):
    if product == "local":
        return True
    if product == "chatgpt":
        return profile.get("codex") in ("plus", "pro", "business")
    if product == "google-ai-pro":
        return profile.get("gemini") in ("pro", "ultra")
    if product == "claude":
        return profile.get("claude_plan", "none") != "none"
    return product in profile.get("products", [])


LANES = {"chatgpt": "codex", "google-ai-pro": "gemini", "claude": "claude"}
ROLE_ORDER = ("top", "strong", "build", "review", "screens", "mid", "long_read", "research", "lookup")
NOT_A_NAME = {"gpt", "claude", "gemini", "high", "medium", "low", "mid", "max", "xhigh", "k", "code"}


def model_for(lane, option_name, models):
    """The model the option names (Sonnet, Astra, Argon ...) when models.json has it, else the lane's
    build model: media work is ordinary agent work, not a strong-model job."""
    roles = models[lane]
    name = " ".join(re.findall(r"[a-z]+", option_name.lower()))
    for role in ROLE_ORDER:
        model = roles.get(role)
        if not isinstance(model, str):
            continue
        tokens = [t for t in re.findall(r"[a-z]+", model.lower()) if t not in NOT_A_NAME and len(t) > 2]
        if any(re.search(r"\b%s\b" % t, name) for t in tokens):
            return model
    return roles["build"]


def installed_model(lane, model, models):
    """The model when the lane's CLI offers it (or the offer is unknown), its fallback when only that is
    offered, else None. Same rule as kit-routing-table."""
    exe = Path(__file__).resolve().parents[1] / "bin/kit-models-available"
    try:
        result = subprocess.run([str(exe), lane], capture_output=True, text=True, timeout=1.0, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return model
    if result.returncode != 0:
        return model
    offered = set(result.stdout.split())
    if model in offered:
        return model
    fallback = (models.get("fallbacks") or {}).get(model)
    return fallback if fallback in offered else None


def reach_command(lane, model):
    """A command an agent can run from its own shell as printed: no stdin wait, no repo needed, no
    permission prompt in print mode, and the helper marked a worker so it is not treated as a lead."""
    return {
        "codex": f'KIT_ROLE=worker codex exec --skip-git-repo-check -m {model} -c model_reasoning_effort=high "<task>" </dev/null',
        "gemini": f'KIT_ROLE=worker agy --dangerously-skip-permissions --model {model} -p "<task>" </dev/null',
        "claude": f'KIT_ROLE=worker claude -p --model {model} --effort medium "<task>" </dev/null',
    }[lane]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--guide", type=Path,
                        default=Path(__file__).resolve().parents[1] / "guide/guide.json")
    parser.add_argument("--agent", choices=("claude", "codex", "gemini"))
    parser.add_argument("query", nargs="+")
    args = parser.parse_args()
    home = Path(os.environ.get("ROUTING_KIT_HOME") or str(Path.home() / ".config/routing-kit"))
    try:
        profile = read_json(home / "profile.json")
        if not isinstance(profile, dict) or not isinstance(profile.get("products", []), list):
            raise ValueError("invalid profile")
    except (OSError, ValueError):
        print("kit-route: invalid profile; run kit-profile", file=sys.stderr)
        return 2
    jobs = media_jobs(home, args.guide)
    job_id = match_job(" ".join(args.query), jobs)
    job = next((job for job in jobs if job["job"] == job_id), None)
    if job is None:
        print("no route; ask the user", file=sys.stderr)
        return 3
    options = sorted(job["options"], key=lambda option: option["rank"])
    selected = next((o for o in options if covered(o["product"], profile)), None)
    if selected is None:
        print("Do: nothing in your plans covers this — tell the user the options below; do not make a substitute yourself")
    else:
        lane = LANES.get(selected["product"])
        if selected["who"] == "owner":
            print(f'Do: this is for the user — tell them to do it in {selected["how"]} ({selected["name"]}); do not do it yourself.')
        else:
            print(f'Do: {selected["name"]} — {selected["who"]} ({selected["how"]})')
            if args.agent and lane and lane != args.agent:
                models = read_json(Path(__file__).resolve().parents[1] / "rules/models.json")
                model = installed_model(lane, model_for(lane, selected["name"], models), models)
                if model:
                    print(f"Reach it with: {reach_command(lane, model)}")
    better = next((o for o in options if not covered(o["product"], profile)
                   and (selected is None or o["rank"] < selected["rank"])), None)
    if better:
        price = better.get("price_month_usd")
        cost = "price unknown" if price is None else f"about ${price:g}/month"
        print(f'Better, needs a new subscription: {better["name"]}, {cost}')
    if job.get("note"):
        print(" ".join(job["note"].splitlines()))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"kit-route: {error}", file=sys.stderr)
        sys.exit(2)
