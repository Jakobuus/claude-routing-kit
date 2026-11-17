#!/usr/bin/env bash
. "$(cd "$(dirname "$0")/../../bin" && pwd)/kit-common"
input=$(cat)
decision=$(printf '%s' "$input" | kit_python3 -c '
import json, os, pathlib, sys
try:
    event = json.load(sys.stdin)
    profile = json.loads((pathlib.Path(os.environ.get("ROUTING_KIT_HOME", pathlib.Path.home()/".config/routing-kit"))/"profile.json").read_text())
    blocks = profile.get("blocks")
    enabled = blocks is True or (isinstance(blocks, dict) and blocks.get("destructive") is True)
    if not enabled or event.get("event") != "PreToolUse":
        sys.exit()
    tool = event.get("tool") or {}
    if tool.get("kind") == "write":
        cwd = pathlib.Path(event.get("cwd") or os.getcwd())
        for raw in tool.get("paths", []):
            target = (cwd/pathlib.Path(raw).expanduser()).resolve()
            where = str(target)
            if where.endswith("/board/board.jsonl") or "/board/owner-prompts/" in where + "/":
                print(json.dumps({"action":"deny","reason":"Blocked: the message board files are written only by kit-board."}))
                sys.exit()
            for protected in profile.get("protected_paths", []):
                parent = pathlib.Path(protected).expanduser().resolve()
                if target == parent or parent in target.parents:
                    print(json.dumps({"action":"deny","reason":"Blocked: write to protected path."}))
                    sys.exit()
    elif tool.get("kind") == "shell":
        # first line: the directory the command runs in; the rest: the command itself
        print(str(event.get("cwd") or os.getcwd()).replace("\n", " "))
        print(tool.get("command") or "")
except (ValueError, OSError, TypeError):
    pass
')
case "$decision" in
  '{"action":'*) printf '%s\n' "$decision"; exit 0 ;;
esac
case "$decision" in
  *$'\n'*) KIT_CWD=${decision%%$'\n'*}; cmd=${decision#*$'\n'} ;;
  *) KIT_CWD=""; cmd="" ;;
esac
export KIT_CWD
raw_cmd="$cmd"
[ -n "$cmd" ] || exit 0
deny() {
  kit_python3 -c 'import json,sys; print(json.dumps({"action":"deny","reason":sys.argv[1]}))' "$1"
  exit 0
}
# Board files (board.jsonl, owner-prompts/) are written only through kit-board. One rule over the
# raw command: a segment that names one of them is allowed when its program only reads or prints
# (cat, grep, echo, git, kit-board ...) and does not redirect into it; any other program is denied.
case "$cmd" in
  *board/owner-prompts*|*board/board.jsonl*|*owner-prompts/*|*board.jsonl*)
    board_hit=$(printf '%s' "$cmd" | kit_python3 -c '
import re, sys
FRAG = r"board/(?:owner-prompts|board\.jsonl)|owner-prompts/|(?<![\w.-])board\.jsonl"
NAMED, REDIR = re.compile(FRAG), re.compile(r">>?[|&]?\s*[\"\x27]?[^\s;|&]*(?:" + FRAG + ")")
SAFE = {"cat","head","tail","grep","egrep","fgrep","rg","wc","ls","stat","jq","file","diff",
        "cmp","echo","printf","git-commit","git-read","pager-read","kit-board","sha256sum","shasum",
        "test","[","cd","cut"}
SKIP = {"sudo","env","time","command","nohup","exec","!","then","do","else"}
# Read-only use of git (diff, log, show, status) and the pagers (less, more) is plain reading; a
# write option (--output / -o for git, -o -O --log-file for the pagers) makes them a writer.
GIT_VAL = {"-C","-c","--git-dir","--work-tree","--namespace","--exec-path","--super-prefix","--config-env"}
GIT_WRITE = re.compile(r"^(?:--out|-o)")
PAGER_WRITE = re.compile(r"^(?:--(?:log|LOG)|-[A-Za-z~]*[oO])")
def git_kind(toks):
    k = 1
    while k < len(toks):
        t = toks[k]
        if t in GIT_VAL:
            k += 2
        elif t.startswith("-"):
            k += 1
        else:
            break
    sub = toks[k] if k < len(toks) else ""
    if sub == "commit":
        return "git-commit"
    if sub in ("diff", "log", "show", "status") and not any(GIT_WRITE.match(t.strip("\"\x27")) for t in toks[k + 1:]):
        return "git-read"
    return "git"
def program(seg):
    toks = seg.split()
    while toks and (re.match(r"^[A-Za-z_]\w*=", toks[0]) or toks[0] in SKIP):
        toks.pop(0)
    name = toks[0].lstrip("({!").rsplit("/", 1)[-1] if toks else ""
    if name == "git":
        return git_kind(toks)
    if name in ("less", "more"):
        return "pager-read" if not any(PAGER_WRITE.match(t.strip("\"\x27")) for t in toks[1:]) else name
    return name
# The message of `kit-board post|send` is text, not shell: a quoted word there is blanked before
# the command is split, so `;`, `>>` or a board path inside it mean nothing. A word is left alone
# when it is not a whole quoted word, follows a redirect, or is a "..." that expands ($ or `).
START = re.compile(r"(?:^|[;&|(\n])[ \t]*(?:[A-Za-z_]\w*=\S*[ \t]+)*(?:\S*/)?kit-board[ \t]+(?:post|send)\b")
def close_of(text, i):
    q = text[i]
    j = i + 1
    while j < len(text):
        if text[j] == "\\" and q == "\"":
            j += 2
            continue
        if text[j] == q:
            return j
        j += 1
    return -1
def mask(text):
    out, pos = [], 0
    for m in START.finditer(text):
        if m.start() < pos:
            continue
        i = m.end()
        while i < len(text) and text[i] not in ";&|\n(`":
            c = text[i]
            if c in "\x27\"" and text[i - 1] in " \t":
                j = close_of(text, i)
                if j < 0:
                    break
                k = j + 1
                body = text[i + 1:j]
                after_ok = k >= len(text) or text[k] in " \t;&|\n"
                prior = text[:i].rstrip()
                if after_ok and not prior.endswith((">", "<")) and not (c == "\"" and re.search(r"[$`]", body)):
                    out.append(text[pos:i + 1] + "x")
                    pos = j
                i = k
                continue
            i += 1
    out.append(text[pos:])
    return "".join(out)
try:
    lines, i = mask(sys.stdin.read()).split("\n"), 0
    while i < len(lines):
        line, i = lines[i], i + 1
        body = ""
        m = re.search(r"(?<!<)<<(?!<)-?\s*[\"\x27]?(\w+)[\"\x27]?", line)
        if m:
            while i < len(lines):
                end, i = lines[i], i + 1
                if end.strip() == m.group(1):
                    break
                body += end + "\n"
        segs = re.split(r";|&&|\|\||\||(?<![<>])&(?!>)", line)
        for seg in segs:
            prog = program(seg)
            plain = prog in SAFE
            if plain and REDIR.search(seg):
                print(1); sys.exit()
            if not plain and prog and (NAMED.search(seg) or (m and NAMED.search(body))):
                print(1); sys.exit()
except Exception:
    pass
' 2>/dev/null)
    [ "$board_hit" = 1 ] && deny "Blocked: the message board files are written only by kit-board. Use kit-board send or post."
    ;;
esac
# Absolute credential roots, one per line: $HOME's ~/.ssh, ~/.aws, ~/.gnupg plus
# every absolute profile protected_paths entry (raw and symlink-resolved). Never
# hard-coded; read as literal data, never as a pattern.
KIT_CRED_ROOTS=$(kit_python3 -c '
import json, os, pathlib
roots = []
def add(p):
    for v in (p, pathlib.Path(os.path.realpath(p))):
        v = str(v).rstrip("/")
        if v.startswith("/") and v not in roots and "\n" not in v:
            roots.append(v)
try:
    home = pathlib.Path(os.environ.get("HOME") or pathlib.Path.home())
    for d in (".ssh", ".aws", ".gnupg"):
        add(home / d)
    profile = json.loads((pathlib.Path(os.environ.get("ROUTING_KIT_HOME", pathlib.Path.home()/".config/routing-kit"))/"profile.json").read_text())
    for p in profile.get("protected_paths", []):
        if isinstance(p, str) and p:
            add(pathlib.Path(p).expanduser())
except (ValueError, OSError, TypeError, RuntimeError):
    pass
print("\n".join(roots))
' 2>/dev/null)
export KIT_CRED_ROOTS
# Keep shell code while hiding data passed as quoted text or a heredoc body.
cmd=$(printf '%s\n' "$cmd" | awk '
  function under_root(s,    n,i,roots,r) {
    n = split(ENVIRON["KIT_CRED_ROOTS"], roots, "\n")
    for (i = 1; i <= n; i++) {
      r = roots[i]
      if (r != "" && (s == r || substr(s, 1, length(r) + 1) == r "/")) return 1
    }
    return 0
  }
  function quoted_path(s) {
    return s ~ /^\/(\*)?$/ || s ~ /^~(\/\*)?$/ ||
      s ~ /^\$HOME(\/\*)?$/ || s ~ /^\$\{HOME\}(\/\*)?$/ ||
      s ~ /^(~|\$HOME|\$\{HOME\})\/\.(ssh|aws|gnupg)(\/|$)/ ||
      under_root(s)
  }
  function heredoc_marker(s,    i,c,q,rest,sub_dq) {
    q = ""; sub_dq = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\" && q != "\047") { i++; continue }
      # Inside "$(...)" a heredoc is real shell (git commit -m "$(cat <<EOF ...)").
      if (q == "\042" && substr(s, i, 2) == "$(") sub_dq = 1
      if (q != "" && !(q == "\042" && sub_dq && substr(s, i, 2) == "<<")) { if (c == q) { q = ""; sub_dq = 0 }; continue }
      if (c == "\047" || c == "\042") { q = c; continue }
      rest = substr(s, i)
      if (match(rest, /^<<-?[\047\042]?[A-Za-z_][A-Za-z_0-9]*[\047\042]?/))
        return substr(rest, RSTART, RLENGTH)
    }
    return ""
  }
  function heredoc_expansions(s,    i,j,c,depth,q,out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      if (substr(s, i, 1) == "\\") { i++; continue }
      if (substr(s, i, 2) == "$(") {
        depth = 1; q = ""
        for (j = i + 2; j <= length(s); j++) {
          c = substr(s, j, 1)
          if (c == "\\") { j++; continue }
          if (c == q && q != "") { q = ""; continue }
          if (q == "\047") continue
          if (c == "\047" || c == "\042" || c == "`") { if (q == "") q = c; continue }
          if (substr(s, j, 2) == "$(") { depth++; j++; continue }
          if (q != "") continue
          if (c == ")" && --depth == 0) break
        }
        out = out " ; " substr(s, i, j - i + 1)
        i = j
      } else if (substr(s, i, 1) == "`") {
        for (j = i + 1; j <= length(s) && substr(s, j, 1) != "`"; j++)
          if (substr(s, j, 1) == "\\") j++
        out = out " ; " substr(s, i, j - i + 1)
        i = j
      }
    }
    return out
  }
  function strip_quotes(s,    i,j,c,q,start,value,prefix,simple,shell_command,keep,out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c != "\047" && c != "\042") { out = out c; continue }
      q = c
      start = i + 1
      j = start
      while (j <= length(s)) {
        if (q == "\042" && substr(s, j, 1) == "\\") { j += 2; continue }
        if (substr(s, j, 1) == q) break
        j++
      }
      value = substr(s, start, j - start)
      prefix = out
      simple = prefix
      sub(/^.*[;&|]/, "", simple)
      shell_command = simple ~ /(^|[^[:alnum:]_])(bash|sh|zsh)([[:space:]]+[^[:space:]]+)*[[:space:]]+-[a-zA-Z]*c[a-zA-Z]*[[:space:]]*$/ ||
        simple ~ /(^|[^[:alnum:]_])eval[[:space:]]*$/
      keep = shell_command || quoted_path(value)
      # $(...) and backticks inside double quotes still run.
      if (q == "\042" && (index(value, "$(") || index(value, "`"))) shell_command = 1
      if (shell_command) out = out "; " value
      else if (keep) out = out value
      else out = out " \001 "  # hidden quoted text stays an operand slot (stripped before the pattern checks)
      i = j
    }
    return out
  }
  {
    if (delimiter != "") {
      end = $0
      if (strip_tabs) sub(/^\t+/, "", end)
      if (end == delimiter) { delimiter = ""; next }
      if (!shell_body) {
        if (quoted_delimiter) next
        line = heredoc_expansions($0)
        if (line == "") next
        $0 = line
      }
    } else {
      marker = heredoc_marker($0)
      if (marker != "") {
        strip_tabs = marker ~ /^<<-/
        delimiter = marker
        sub(/^<<-?/, "", delimiter)
        gsub(/[\047\042]/, "", delimiter)
        quoted_delimiter = marker ~ /[\047\042]/
        shell_body = $0 ~ /(^|[;&|][[:space:]]*)(\/(usr\/)?bin\/)?(bash|sh|zsh)[[:space:]]*<</ ||
          $0 ~ /\|[[:space:]]*(\/(usr\/)?bin\/)?(bash|sh|zsh)([[:space:]]|$)/ ||
          $0 ~ /((bash|sh|zsh)[[:space:]]+-c|eval)[[:space:]]+"\$\(/
      }
    }
    # Command substitutions start new commands: $(rm …) and `rm …` must match like rm at line start.
    line = strip_quotes($0)
    gsub(/\$\(|`|\)/, " ; ", line)
    print line
  }
')
cmd_sentinel="$cmd"   # \001 marks hidden quoted text; the pattern checks below do not see it
cmd=$(printf '%s' "$cmd" | tr -d '\001')
if printf '%s' "$cmd" | grep -qE '(^|[;&|][[:space:]]*)(/bin/|/usr/bin/)?rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(/(\*)?([[:space:];&|]|$)|~(/(\*)?)?([[:space:];&|]|$)|(\$HOME|\$\{HOME\})(/(\*)?)?([[:space:];&|]|$))'; then
  deny "Blocked: rm targeting /, ~ or \$HOME root. Use a scoped subdirectory path."
fi
if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^|;]*([[:space:]]*--force([[:space:];&|]|$)|[[:space:]]*-f([[:space:];&|]|$))'; then
  deny "Blocked: force push. Run this command manually if needed."
fi
# Credential and protected paths: DENIED by default. Any shell command that names ~/.ssh, ~/.aws,
# ~/.gnupg or a profile protected path in any word (quoted or not, after home expansion and
# normalisation) is blocked, unless the only places it appears are echo/printf text, a git commit
# message or kit-board post/send text (see lib/guard_paths.py). Runs on the raw command, so hiding
# text in quotes or a heredoc does not help. A checker that fails, or prints nothing readable,
# denies when the command names a protected root; any other crash of the hook fails open.
checker="$(cd "$(dirname "$0")/../../lib" && pwd)/guard_paths.py"
hit=$(printf '%s' "$raw_cmd" | kit_python3 "$checker" 2>/dev/null); checker_rc=$?
case "$checker_rc:$hit" in
  0:0) ;;
  0:1) deny "Blocked: command names a credential directory (~/.ssh, ~/.aws, ~/.gnupg). Ask the owner if needed." ;;
  0:2) deny "Blocked: command names a protected or credential path. Ask the owner if needed." ;;
  *)
    # The checker failed or said something unreadable. For this rule only, that is no longer an
    # implicit allow: when the command text names a protected root (its full path or its last
    # folder name, any case), deny. Plain commands that name none go on unchecked.
    lower_cmd=$(printf '%s' "$raw_cmd" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      lower_root=$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]')
      base=${lower_root##*/}
      case "$lower_cmd" in
        *"$lower_root"*|*"$base"*) deny "Blocked: the path check did not finish and the command names a protected or credential path. Ask the owner if needed." ;;
      esac
    done <<EOF_ROOTS
$KIT_CRED_ROOTS
EOF_ROOTS
    ;;
esac
if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*x'; then
  deny "Blocked: git clean -x deletes ignored files (.env, local configs)."
fi
if printf '%s' "$cmd" | grep -qE '(curl|wget)[^|;]*\|[[:space:]]*(ba|z|da)?sh([[:space:]]|$)'; then
  deny "Blocked: piping a download into a shell. Download to a file, inspect, then run."
fi
exit 0
