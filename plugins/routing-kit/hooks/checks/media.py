#!/usr/bin/env python3
"""On the first prompt of a turn, spot a media job (image, video, voice...) and add its route."""
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
from media_match import media_jobs, match_job

MAX_PROMPT = 2000


def route_for(job, agent=None):
    exe = shutil.which("kit-route") or str(Path(__file__).resolve().parents[2] / "bin/kit-route")
    try:
        args = [exe] + (["--agent", agent] if agent in ("claude", "codex", "gemini") else [])
        result = subprocess.run(args + [job["job"]], capture_output=True, text=True, timeout=1.5)
    except (OSError, subprocess.SubprocessError):
        return None
    text = " ".join(result.stdout.split()).rstrip(".")  # one line; the context adds the full stop
    return text if result.returncode == 0 and text else None


def log(home, agent, job, routed):
    entry = {"time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "agent": agent, "job": job}
    if not routed:
        entry["routed"] = False
    try:
        home.mkdir(parents=True, exist_ok=True)
        with (home / "route-log.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def main():
    event = json.loads(sys.stdin.read())
    prompt = event.get("prompt") or ""
    if (event.get("event") not in ("UserPromptSubmit", "PreInvocation") or not event.get("first_in_turn")
            or not prompt or len(prompt) > MAX_PROMPT):
        return
    home = Path(os.environ.get("ROUTING_KIT_HOME") or Path.home() / ".config/routing-kit")
    jobs = media_jobs(home)
    job_id = match_job(prompt, jobs)
    job = next((job for job in jobs if job["job"] == job_id), None)
    if job is None:
        return
    route = route_for(job, "gemini" if event.get("agent") == "agy" else event.get("agent"))
    log(home, event.get("agent") or "unknown", job["job"], route is not None)
    if route:
        print(json.dumps({"action": "context", "text":
              "If this is a media job (making, editing, transcribing, translating or reading images, video or audio; not code): %s. Route: %s. Follow it unless the user named a tool."
              % (job.get("label", job["job"]), route)}))


if __name__ == "__main__":
    main()
