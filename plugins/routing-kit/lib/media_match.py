"""Shared media loading and matching. Recall first: the injected line is conditional ("if this asks
is a media job … (not code)"), so a false match costs one ignorable sentence, while a
missed media request means the routing is not followed. Only explicit code signals stop a match."""
from datetime import datetime, timezone
import json
import re
from pathlib import Path

# Explicit code signals stop a match. Everyday nouns (card, page, job, table, file, script, chrome,
# link, view...) are not here: they block real media requests.
CODE_EXTENSIONS = (
    "py js jsx ts tsx mjs cjs json yml yaml toml md sh css scss html htm xml sql go rs java kt rb "
    "php c cpp h hpp cs swift ini cfg conf lock lua ps1 vue svelte dart scala gradle proto")
CODE_WORDS = set(
    "function component class method bug test api endpoint schema repo repository pr commit stack "
    "trace exception variable regex sdk cli module parser handler controller migration hydration "
    "webhook compile runtime refactor debug implement deploy config database backend frontend "
    "localstorage "
    # languages and tools
    "typescript javascript python rust java kotlin ruby swift swiftui bash react vue svelte node "
    "css html html5 json yaml sql nginx docker kubernetes webpack vite npm git flask django "
    "rails celery imagemagick "
    "php lua perl haskell clojure erlang golang powershell zsh laravel symfony jquery nextjs "
    "numpy tensorflow pytorch opencv matlab fortran cobol graphql".split())
# Two-part paths need a code extension, underscore, or a leading code folder.
CODE_DIRS = {"src", "lib", "app", "tests", "scripts"}
TWO_PART_PATH = re.compile(r"(?<![\w/.:-])([\w.-]*\w)/(\w[\w.-]*?)(?=[.,;:!?)\"']*(?:\s|$))")
CODE_FILE = re.compile(r"\b[\w-]+\.(?:%s)\b" % CODE_EXTENSIONS.replace(" ", "|"), re.IGNORECASE)
CODE_PATH = re.compile(r"(?:^|\s)(?:~|\.{1,2})?/[\w.~-]+|\b[\w.-]+/[\w.-]+\.\w+\b|\b[\w-]+(?:/[\w-]+){2}")
# A keyword right after one of these is what the prompt asks for; it beats a topic word elsewhere
# ("an image for an album about background music" is an image job, not a music job).
MAKE_VERBS = set(
    "make create generate design draw paint produce compose write need want give turn edit "
    "retouch restyle remove cut extract convert translate transcribe animate upscale enlarge "
    "sharpen vectorise vectorize trace isolate modify change run ocr localize localise read "
    "get add watch listen summarize".split())
# Verbs that mean "make this" rather than "take this in" (the watch/describe shortcut stops on these).
UNDERSTANDING_VERBS = {"watch", "listen", "summarize", "read", "get"}
MAX_FILLER = 2  # words allowed between a verb and its object, or inside a multi-word keyword


def words(text):
    return re.findall(r"[a-z0-9]+", text.lower())


def has_two_part_path(prompt):
    for first, second in TWO_PART_PATH.findall(prompt):
        if (first.lower() in CODE_DIRS or CODE_FILE.search(first + "/" + second)
                or "_" in first or "_" in second):
            return True
    return False


def has_code_signal(prompt):
    if re.search(r"(?i)\.net\b|\b(?:c[#+]+|(?:in|into|a|an)\s+(?:go|r|c)\b)", prompt):
        return True
    if "`" in prompt or CODE_FILE.search(prompt) or CODE_PATH.search(prompt) or has_two_part_path(prompt):
        return True
    return any(word in CODE_WORDS or re.sub(r"e?s$", "", word) in CODE_WORDS for word in words(prompt))


def keyword_hits(prompt, keyword):
    """Where a keyword appears (up to two filler words inside it, simple plural on the last word)."""
    parts = [re.escape(part) for part in words(keyword)]
    glue = r"(?:\W+\w+){0,%d}?\W+" % MAX_FILLER
    pattern = r"\b" + glue.join(parts) + r"(?:e?s)?\b"
    return [hit.start() for hit in re.finditer(pattern, prompt, re.IGNORECASE)]


def after_make_verb(prompt, start):
    """True when a make/edit verb sits up to MAX_FILLER words before `start`, in the same clause."""
    clause = re.split(r"[.,;:!?\n]", prompt[:start])[-1]
    return bool(set(words(clause)[-(MAX_FILLER + 1):]) & MAKE_VERBS)


def understands_video(prompt):
    """Watch/describe/summarize/"what happens" comes first, then a video word or file, and no make verb
    sits anywhere before that video in the clause ("Make a video to summarize ..." makes one, it does not watch one)."""
    verbs = list(re.finditer(r"\b(?:watch|describe|summarize|what[ -]happens)\b", prompt, re.I))
    if not verbs:
        return False
    for video in re.finditer(r"\bvideo\b|\.(?:mp4|mov|webm|mkv|avi)\b", prompt, re.I):
        if video.start() < verbs[0].end():
            continue
        clause = re.split(r"[.,;:!?\n]", prompt[:video.start()])[-1]
        if re.search(r"\b(?:in|into)\s+(?:a|an)\b", clause, re.I):
            continue
        if not set(words(clause)) & (MAKE_VERBS - UNDERSTANDING_VERBS):
            return True
    return False


def match_job(prompt, jobs):
    """The best job for the prompt, or None. Best = a keyword on a verb's object, then more words
    in the keyword ("image into a video" beats "image"), then the earliest in the prompt."""
    exact = next((job["job"] for job in jobs if job["job"].lower() == prompt.lower()), None)
    if exact is not None:
        return exact
    if has_code_signal(prompt):
        return None
    if (any(job["job"] == "video-understanding" for job in jobs)
            and understands_video(prompt)):
        return "video-understanding"
    best, best_score = None, None
    for job in jobs:
        for keyword in job["match"]:
            for start in keyword_hits(prompt, keyword):
                score = (after_make_verb(prompt, start) or words(keyword)[0] in MAKE_VERBS,
                         len(words(keyword)), -start)
                if best_score is None or score > best_score:
                    best, best_score = job["job"], score
    return best


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def private_error(job):
    """Why a private job is the wrong shape, or None when it is fine."""
    if not isinstance(job, dict):
        return "an entry is not an object"
    if not isinstance(job.get("job"), str) or not job["job"]:
        return "an entry has no job name"
    if not isinstance(job.get("match"), list) or not all(isinstance(m, str) and words(m) for m in job["match"]):
        return "job %s needs match as a list of words" % job["job"]
    for key in ("note", "label", "best_overall"):
        if key in job and not (isinstance(job[key], str) or key == "best_overall" and job[key] is None):
            return "job %s has invalid %s" % (job["job"], key)
    options = job.get("options")
    if not isinstance(options, list):
        return "job %s needs options as a list" % job["job"]
    for option in options:
        if not (isinstance(option, dict) and all(k in option for k in ("name", "product", "who", "how", "rank"))
                and type(option["rank"]) in (int, float)
                and all(isinstance(option[k], str) for k in ("name", "product", "who", "how"))
                and (option.get("price_month_usd") is None or type(option["price_month_usd"]) in (int, float))):
            return "job %s has an option without name, product, who, how and a numeric rank" % job["job"]
    return None


def private_jobs(home):
    """Jobs from private/media.json, or [] (with one line in hook-errors.log) on any shape error."""
    path = home / "private/media.json"
    if not path.exists():
        return []
    data = read_json(path)
    entries = data if isinstance(data, list) else data.get("media") if isinstance(data, dict) else None
    problem = "not a list of jobs" if not isinstance(entries, list) else next(
        filter(None, map(private_error, entries)), None)
    if problem is None:
        return entries
    try:
        home.mkdir(parents=True, exist_ok=True)
        with (home / "hook-errors.log").open("a", encoding="utf-8") as stream:
            stream.write(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ ") + "media: ignoring private/media.json: %s\n" % problem)
    except OSError:
        pass
    return []


def media_jobs(home, guide=None):
    guide = guide or Path(__file__).resolve().parents[1] / "guide/guide.json"
    jobs = {job["job"]: job for job in read_json(guide)["media"]}
    overrides = {job["job"]: job for job in private_jobs(home)}
    return list(overrides.values()) + [job for key, job in jobs.items() if key not in overrides]
