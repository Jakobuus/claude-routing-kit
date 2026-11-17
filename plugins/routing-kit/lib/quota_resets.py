import datetime, json, os, sys, time

path = sys.argv.pop(1)
TYPES = ("weekly", "fable")

def load():
    try:
        with open(path) as f: data = json.load(f)
        resets = data["resets"]
        if not isinstance(resets, list): raise ValueError
        for r in resets:
            if r["type"] not in TYPES: raise ValueError
            e = r["expires"]
            if isinstance(e, bool) or not isinstance(e, (int, float)): raise ValueError
        return data
    except FileNotFoundError:
        if sys.argv[1:2] == ["add"]:
            return {"resets": []}
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit(1)

def save(data):
    data["updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(tmp, "w") as f: json.dump(data, f, separators=(",", ":")); f.write("\n")
        os.replace(tmp, path)
    except OSError as e:
        try: os.unlink(tmp)
        except OSError: pass
        print(f"claude-resets: cannot write: {e}", file=sys.stderr); sys.exit(1)

def stamp(e):
    return datetime.datetime.fromtimestamp(e, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

args = sys.argv[1:]
data = load()
now = time.time()

if not args:
    live = [r for r in data["resets"] if r["expires"] > now]
    if not live:
        print("0 -"); sys.exit(0)
    label = "+".join(f"{n}{t}" for t in TYPES if (n := sum(r["type"] == t for r in live)))
    print(f"{len(live)} {int(min(r['expires'] for r in live))} {label}")
elif args == ["list"]:
    live = sorted((r for r in data["resets"] if r["expires"] > now), key=lambda r: r["expires"])
    if not live: print("no resets banked")
    for r in live: print(f"{r['type']}: expires {stamp(r['expires'])}")
elif len(args) == 2 and args[0] == "use" and args[1] in TYPES:
    cands = [r for r in data["resets"] if r["type"] == args[1] and r["expires"] > now]
    if not cands:
        print(f"claude-resets: no {args[1]} reset to use", file=sys.stderr); sys.exit(1)
    victim = min(cands, key=lambda r: r["expires"])
    data["resets"].remove(victim)
    save(data); print(f"used {args[1]} (was expiring {stamp(victim['expires'])})")
elif len(args) == 3 and args[0] == "add" and args[1] in TYPES:
    try:
        d = args[2]
        dt = datetime.datetime.strptime(d, "%Y-%m-%dT%H:%M") if "T" in d else \
             datetime.datetime.strptime(d, "%Y-%m-%d").replace(hour=23, minute=59)
    except ValueError:
        print("claude-resets: date must be YYYY-MM-DD[THH:MM]", file=sys.stderr); sys.exit(2)
    exp = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
    data["resets"].append({"type": args[1], "expires": exp})
    save(data); print(f"added {args[1]} expiring {stamp(exp)}")
else:
    print("usage: claude-resets [list | use weekly|fable | add weekly|fable YYYY-MM-DD[THH:MM]]", file=sys.stderr)
    sys.exit(2)
