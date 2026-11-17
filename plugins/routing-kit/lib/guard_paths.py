"""Credential and protected-path check for shell commands (used by guard_destructive.sh).

Reads the raw shell command on stdin; KIT_CRED_ROOTS (one absolute path per line) holds the
protected roots; KIT_CWD (optional) is the directory the command runs in. Prints "1" (a ~/.ssh,
~/.aws or ~/.gnupg path), "2" (another protected root) or "0" (nothing named). A crash exits
non-zero with no output: the caller treats that as "unknown" (see guard_destructive.sh).

Default is DENY: every word of the command, quoted or not, and every heredoc body is turned into
candidate paths (home and $USER expanded, ./.. normalised, braces and globs matched, symlinks
resolved, case ignored) and compared with the roots. Only these places are left alone:
  - the argument text of echo / printf (not piped, captured, grouped or redirected anywhere),
  - the message of `git commit -m ...` (and a quoted heredoc given to it),
  - the text of `kit-board post|send`,
  - public key-folder files (known_hosts, config, *.pub) named to the ssh tools.
The common prefixes `env A=1`, `command`, `nohup`, `time`, `exec` and git's `-C dir` / `-c k=v`
are skipped before an exemption is decided. Relative words are also resolved against KIT_CWD (and
any `cd` earlier in the command). A word holding spaces is checked whole as well as in pieces.
Doubt means deny.
"""
import fnmatch
import os
import posixpath
import pwd
import re
import sys

CRED = {".ssh", ".aws", ".gnupg"}
SSH_TOOLS = {"ssh", "scp", "sftp", "rsync", "ssh-keygen", "ssh-keyscan", "ssh-add"}
PUBLIC = {"known_hosts", "known_hosts.old", "config"}
GLOB = re.compile(r"[*?\[]")
SEP = re.compile(r"[\s;|&()<>`'\"=:]")
SEP_KEEP_SPACE = re.compile(r"[;|&()<>`'\"=:]")
CWD = (os.environ.get("KIT_CWD") or "").rstrip("/")
if not CWD.startswith("/"):
    CWD = ""
ASSIGN = re.compile(r"^[A-Za-z_]\w*=")
HOME = (os.environ.get("HOME") or "").rstrip("/")
if not HOME:
    HOME = pwd.getpwuid(os.getuid()).pw_dir.rstrip("/")
USER = os.environ.get("USER") or os.environ.get("LOGNAME") or posixpath.basename(HOME)
ROOTS = [r for r in os.environ.get("KIT_CRED_ROOTS", "").split("\n") if r]
ROOT_COMPS = [[c.casefold() for c in r.split("/") if c] for r in ROOTS]
ROOT_BASE = {c[-1] for c in ROOT_COMPS if c}


# ------------------------------------------------------------------ tokeniser

class Word:
    def __init__(self, text, expands, redir):
        self.text, self.expands, self.redir = text, expands, redir


class Seg:
    def __init__(self, captured):
        self.words = []
        self.captured = captured
        self.piped_out = False
        self.out_redir = False
        self.heredocs = []  # (quoted_delimiter, body)


ANSI = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b",
        "f": "\f", "v": "\v", "\\": "\\", "'": "'", '"': '"'}


def ansi_c(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 >= len(s):
            out.append(c); i += 1; continue
        n = s[i + 1]
        m = re.match(r"x([0-9A-Fa-f]{1,2})|([0-7]{1,3})|u([0-9A-Fa-f]{1,4})|U([0-9A-Fa-f]{1,8})", s[i + 1:])
        if m:
            digits = m.group(1) or m.group(2) or m.group(3) or m.group(4)
            base = 8 if m.group(2) else 16
            try:
                out.append(chr(int(digits, base)))
            except ValueError:
                out.append(m.group(0))
            i += 1 + len(m.group(0))
        else:
            out.append(ANSI.get(n, n)); i += 2
    return "".join(out)


def tokenise(s):
    segs = []
    depth = 0          # open ( $( { and backtick groups
    backtick = False
    cur = Seg(False)
    word = []
    has = False        # a word is in progress (even an empty quoted one)
    expands = False
    pending = []       # heredocs waiting for their body: (seg, delim, quoted, strip_tabs)
    next_is = None     # None | "redir" | "heredoc"
    redir_out = False
    heredoc_dash = False
    i, n = 0, len(s)

    def new_seg():
        nonlocal cur
        segs.append(cur)
        cur = Seg(depth > 0 or backtick)

    def flush():
        nonlocal word, has, expands, next_is, redir_out, heredoc_dash, depth
        if not has:
            return
        text = "".join(word)
        if next_is == "heredoc":
            pending.append((cur, text, quoted_delim[0], heredoc_dash))
            next_is = None
        else:
            is_redir = next_is == "redir"
            if is_redir and redir_out and text != "/dev/null" and not re.match(r"^&?\d+-?$", text):
                cur.out_redir = True
            cur.words.append(Word(text, expands, is_redir))
            next_is = None
            if not cur.words[:-1] and text in ("{", "}") and not is_redir:
                cur.words.pop()
                depth = max(0, depth + (1 if text == "{" else -1))
                new_seg()
        word, has, expands = [], False, False

    quoted_delim = [False]
    while i < n:
        c = s[i]
        if c == "\\":
            if i + 1 < n:
                if s[i + 1] != "\n":
                    word.append(s[i + 1]); has = True
                    if next_is == "heredoc":
                        quoted_delim[0] = True
                i += 2
            else:
                i += 1
            continue
        if c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            word.append(s[i + 1:j]); has = True
            if next_is == "heredoc":
                quoted_delim[0] = True
            i = j + 1
            continue
        if c == '"' or (c == "$" and s[i + 1:i + 2] == '"'):
            i += 1 if c == '"' else 2
            j, buf = i, []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    if s[j + 1] in '$`"\\':
                        buf.append(s[j + 1])
                    elif s[j + 1] != "\n":
                        buf.append(s[j:j + 2])
                    j += 2
                    continue
                buf.append(s[j]); j += 1
            body = "".join(buf)
            if "$(" in body or "`" in body or "<(" in body or ">(" in body:
                expands = True
            word.append(body); has = True
            if next_is == "heredoc":
                quoted_delim[0] = True
            i = j + 1
            continue
        if c == "$" and s[i + 1:i + 2] == "'":
            j = i + 2
            while j < n and not (s[j] == "'" and s[j - 1] != "\\"):
                j += 1
            word.append(ansi_c(s[i + 2:j])); has = True
            if next_is == "heredoc":
                quoted_delim[0] = True
            i = j + 1
            continue
        if c == "$" and s[i + 1:i + 2] == "(":
            flush(); depth += 1; new_seg(); i += 2
            continue
        if c in "<>" and s[i + 1:i + 2] == "(":
            flush(); depth += 1; new_seg(); i += 2
            continue
        if c == "(":
            flush(); depth += 1; new_seg(); i += 1
            continue
        if c == ")":
            flush(); depth = max(0, depth - 1); new_seg(); i += 1
            continue
        if c == "`":
            flush(); backtick = not backtick; new_seg(); i += 1
            continue
        if c in " \t":
            flush(); i += 1
            continue
        if c == "\n":
            flush()
            new_seg()
            i += 1
            for (seg, delim, quoted, dash) in pending:
                body = []
                while i < n:
                    j = s.find("\n", i)
                    line = s[i:] if j < 0 else s[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if dash else line) == delim:
                        break
                    body.append(line)
                seg.heredocs.append((quoted, "\n".join(body)))
            pending = []
            continue
        if c in ";|&" and not (c == "&" and s[i + 1:i + 2] == ">"):
            flush()
            two = s[i:i + 2]
            if c == "|" and two != "||":
                cur.piped_out = True
            i += 2 if two in ("&&", "||", "|&", ";;") else 1
            new_seg()
            continue
        if c in "<>" or (c == "&" and s[i + 1:i + 2] == ">"):
            flush()
            m = re.match(r"&>>?|<<<|<<-?|>>|>\||>&|<&|<>|>|<", s[i:])
            op = m.group(0)
            i += len(op)
            if op in ("<<", "<<-"):
                next_is, heredoc_dash = "heredoc", op == "<<-"
                quoted_delim[0] = False
            else:
                next_is = "redir"
                redir_out = op.startswith(">") or op.startswith("&>") or op == "<>"
            continue
        word.append(c); has = True
        i += 1
    flush()
    segs.append(cur)
    # an unterminated heredoc still has its text scanned
    return segs


# -------------------------------------------------------------- path candidates

def expand_braces(s, limit=64):
    out = [s]
    for _ in range(6):
        nxt, changed = [], False
        for w in out:
            m = re.search(r"\{([^{}]*,[^{}]*)\}", w)
            if not m:
                nxt.append(w); continue
            changed = True
            for part in m.group(1).split(","):
                nxt.append(w[:m.start()] + part + w[m.end():])
        out = nxt[:limit]
        if not changed:
            break
    return out


def expand_vars(c):
    m = re.match(r"^~([A-Za-z0-9_.-]*)(?=/|$)", c)
    if m:
        if m.group(1) == "":
            c = HOME + c[1:]
        else:
            try:
                c = pwd.getpwnam(m.group(1)).pw_dir + c[m.end():]
            except KeyError:
                c = "$~" + c[1:]
    c = re.sub(r"\$\{HOME\}|\$HOME(?![A-Za-z0-9_])", HOME, c)
    c = re.sub(r"\$\{(?:USER|LOGNAME)\}|\$(?:USER|LOGNAME)(?![A-Za-z0-9_])", USER, c)
    return c


def comp_match(pat, name):
    if "$" in pat:
        return True  # unresolved variable: could be anything
    if not GLOB.search(pat):
        return pat == name
    if name.startswith(".") and not pat.startswith("."):
        return False
    return fnmatch.fnmatchcase(name, pat)


def match_root(comps, rc):
    for i, r in enumerate(rc):
        if i >= len(comps):
            return False
        if not comp_match(comps[i], r):
            return False
    return True


def check_candidate(cand, cwd=""):
    """Return (kind, normalised path) for a hit, or None. A relative candidate is also tried
    against cwd (the directory the command runs in)."""
    for alt in expand_braces(expand_vars(cand)):
        if not alt:
            continue
        variants = [alt]
        if cwd and not alt.startswith(("/", "-", "$")) and "$" not in alt:
            variants.append(cwd + "/" + alt)
        for v in variants:
            r = check_one(v)
            if r:
                return r
    return None


def check_one(alt):
    absolute = alt.startswith("/")
    p = posixpath.normpath(alt)
    if p.startswith("//"):
        p = "/" + p.lstrip("/")
    comps = [x.casefold() for x in p.split("/") if x]
    if any(x in CRED for x in comps):
        return "1", p
    if absolute:
        for rc in ROOT_COMPS:
            if match_root(comps, rc):
                return "2", p
        if not GLOB.search(p) and "$" not in p:
            try:
                if "\0" in p:
                    raise ValueError("embedded null byte")  # some Pythons resolve it silently
                os.fsencode(p)  # a character the file system cannot hold raises here
                rp = os.path.realpath(p)
            except (OSError, ValueError):
                return "2", p  # cannot be resolved: doubt means deny
            rcomps = [x.casefold() for x in rp.split("/") if x]
            for rc in ROOT_COMPS:
                if rcomps[:len(rc)] == rc:
                    return "2", p
    if "$" in p and any(x in ROOT_BASE for x in comps):
        return "2", p
    return None


def pieces(text, sep=SEP):
    seen = set()
    for w in expand_braces(text):
        for piece in sep.split(w):
            if not piece:
                continue
            idx = {0} | {k for k, ch in enumerate(piece) if ch in "~$/"}
            for k in idx:
                seen.add(piece[k:])
    return seen


def hits(text, cwd=""):
    cands = pieces(text)
    # a word or line holding spaces (a quoted or escaped path such as ".../Application Support/x")
    # is also checked whole, so a configured path with spaces cannot slip through in pieces
    for line in text.split("\n"):
        if re.search(r"[ \t]", line.strip()):
            cands |= pieces(line.strip(), SEP_KEEP_SPACE)
    for cand in cands:
        r = check_candidate(cand, cwd)
        if r:
            yield r


def public_ssh_file(p):
    comps = [x for x in p.split("/") if x]
    if len(comps) < 2 or comps[-2].casefold() != ".ssh":
        return False
    base = comps[-1].casefold()
    return base in PUBLIC or base.endswith(".pub")


# ------------------------------------------------------------------ exemptions

COMMIT_HEREDOC = re.compile(r"^\$\(\s*cat\s+<<-?\s*'(\w+)'\s*\n.*?\n[ \t]*\1[ \t]*\n?\s*\)$", re.S)


KEYWORDS = ("then", "do", "else", "elif", "if", "while", "until", "!")
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}


def program_index(args):
    """Index of the real program: assignments, shell keywords and the plain prefixes `env`
    (with its options), `command`, `nohup`, `time`, `exec`, `builtin` are skipped. An `env -S`
    (split-string) hides the program, so nothing after it counts as known."""
    i = 0
    while i < len(args):
        t = args[i].text
        if ASSIGN.match(t) or t in KEYWORDS:
            i += 1
            continue
        b = posixpath.basename(t)
        if b == "env":
            i += 1
            while i < len(args):
                o = args[i].text
                if o in ("-S", "--split-string") or o.startswith("--split-string=") or (o.startswith("-S") and len(o) > 2 and not o.startswith("--")):
                    return len(args)
                if o in ("-u", "-C", "--unset", "--chdir"):
                    i += 2
                elif o.startswith("-") and o != "-" and o != "--":
                    i += 1
                elif o == "--":
                    i += 1
                    break
                elif ASSIGN.match(o):
                    i += 1
                else:
                    break
            continue
        if b in ("command", "nohup", "time", "exec", "builtin"):
            i += 1
            while i < len(args) and args[i].text.startswith("-") and args[i].text not in ("-",):
                if args[i].text in ("-v", "-V") and b == "command":
                    return len(args)
                i += 1
            continue
        break
    return i


def git_subcommand(args, p):
    """Index (into args) of the git subcommand after git's global options, or len(args)."""
    k = p + 1
    while k < len(args):
        t = args[k].text
        if t in GIT_VALUE_OPTS:
            k += 2
        elif t.startswith("-"):
            k += 1
        else:
            return k
    return len(args)


def exempt_words(seg):
    """Indexes (into seg.words) of words whose text is harmless, and whether heredocs are."""
    words = seg.words
    idx = [k for k, w in enumerate(words) if not w.redir]
    args = [words[k] for k in idx]
    p = program_index(args)
    if p >= len(args):
        return set(), False
    name = posixpath.basename(args[p].text)
    rest = idx[p + 1:]
    out = set()
    if name in ("echo", "printf") and not (seg.piped_out or seg.captured or seg.out_redir):
        if name == "printf" and any(re.match(r"^-[a-zA-Z]*v", words[k].text) for k in rest):
            return set(), False
        for k in rest:
            if not words[k].expands:
                out.add(k)
        return out, False
    g = git_subcommand(args, p) if name == "git" else len(args)
    if name == "git" and g < len(args) and args[g].text == "commit":
        k = g + 1
        while k < len(idx):
            w = words[idx[k]]
            t = w.text
            if t in ("-m", "--message") or re.match(r"^-[aeqsnvpuoi]*m$", t):
                if k + 1 < len(idx):
                    out.add(idx[k + 1])
                k += 2
                continue
            if t.startswith("--message="):
                out.add(idx[k]); k += 1; continue
            m = re.match(r"^-[aeqsnvpuoi]*m(.+)$", t)
            if m:
                out.add(idx[k]); k += 1; continue
            k += 1
        # the message words may carry the standard heredoc form; others must not expand
        out = {k for k in out if (not words[k].expands) or COMMIT_HEREDOC.match(words[k].text)}
        return out, True
    if name == "kit-board" and p + 1 < len(args) and args[p + 1].text in ("post", "send"):
        for k in idx[p + 2:]:
            if not words[k].expands and not words[k].text.startswith("-"):
                out.add(k)
        # option values (--to NAME) are plain words too; they are scanned like any other word
        return out, True
    return out, False


def cd_target(args, p, cwd):
    """The directory a `cd`/`pushd` segment moves to, or None when it cannot be told."""
    rest = [a.text for a in args[p + 1:] if a.text not in ("-L", "-P", "-e", "-@", "--")]
    if not rest:
        return HOME or None
    t = rest[0]
    if t == "-" or "$" in expand_vars(t) or GLOB.search(t):
        return None
    t = expand_vars(t)
    if not t.startswith("/"):
        if not cwd:
            return None
        t = cwd + "/" + t
    return posixpath.normpath(t)


def scan(text):
    cwd = CWD
    for seg in tokenise(text):
        ex, heredoc_ok = exempt_words(seg)
        args = [w for w in seg.words if not w.redir]
        p = program_index(args)
        prog = posixpath.basename(args[p].text) if p < len(args) else ""
        prog_word = args[p] if p < len(args) else None
        ssh = prog in SSH_TOOLS
        for k, w in enumerate(seg.words):
            if k in ex:
                continue
            # the program name itself is never a path in the working directory
            where = "" if w is prog_word else cwd
            for kind, path in hits(w.text, where):
                if ssh and not w.redir and public_ssh_file(path):
                    continue
                return kind
        for quoted, body in seg.heredocs:
            if heredoc_ok and quoted:
                continue
            for kind, path in hits(body):
                return kind
        if prog in ("cd", "pushd"):
            moved = cd_target(args, p, cwd)
            if moved:
                cwd = moved
    return ""


def main():
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    print(scan(text) or "0")


if __name__ == "__main__":
    main()
