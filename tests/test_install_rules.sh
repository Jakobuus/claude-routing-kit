#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
KI="$PLUGIN_ROOT/bin/kit-install-rules"
JQ=/usr/bin/jq; [ -x "$JQ" ] || JQ=jq

# Never let a test reach the real agent folders.
SAFE=$(mktmp)
export HOME="$SAFE/home" CODEX_HOME="$SAFE/codex-home"
mkdir -p "$HOME"
START='<!-- routing-kit:start -->'
END='<!-- routing-kit:end -->'

count() { grep -c -F -- "$2" "$1" 2>/dev/null || true; }

# ---- Codex -----------------------------------------------------------------
h=$(mktmp)
cat > "$h/hooks.json" <<'EOF'
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"/opt/other/start.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/opt/other/stop.sh"}]}]}}
EOF
printf '# My rules\n\nBe kind.\n' > "$h/AGENTS.md"
cp "$h/hooks.json" "$h/hooks.orig"; cp "$h/AGENTS.md" "$h/AGENTS.orig"
out=$("$KI" --agent codex --home "$h" 2>&1); code=$?
assert_eq 0 "$code" "codex install exits 0"
assert_contains "$out" "/hooks" "codex install tells the user to trust the hook with /hooks"
"$KI" --agent codex --home "$h" >/dev/null 2>&1
assert_eq 0 "$?" "codex second install exits 0"
cmd="$PLUGIN_ROOT/hooks/session-start codex"
n=$("$JQ" --arg c "$cmd" '[.hooks.SessionStart[].hooks[] | select(.command == $c)] | length' "$h/hooks.json")
assert_eq 1 "$n" "codex: exactly one routing-kit hook entry after two installs"
assert_eq '{"type":"command","command":"'"$cmd"'"}' "$("$JQ" -c --arg c "$cmd" '.hooks.SessionStart[].hooks[] | select(.command == $c)' "$h/hooks.json")" "codex: hook entry shape"
assert_eq "/opt/other/start.sh" "$("$JQ" -r '.hooks.SessionStart[0].hooks[0].command' "$h/hooks.json")" "codex: unrelated SessionStart entry kept"
assert_eq "/opt/other/stop.sh" "$("$JQ" -r '.hooks.Stop[0].hooks[0].command' "$h/hooks.json")" "codex: unrelated Stop entry kept"
assert_eq 1 "$(count "$h/AGENTS.md" "$START")" "codex: one start marker"
assert_eq 1 "$(count "$h/AGENTS.md" "$END")" "codex: one end marker"
assert_contains "$(cat "$h/AGENTS.md")" "Be kind." "codex: existing AGENTS.md text kept"
assert_contains "$(cat "$h/AGENTS.md")" "routing-kit is installed and loads its rules at session start. If this session shows no routing-kit rules, run \`$cmd\` and follow its output." "codex: pointer text"
[ -x "$PLUGIN_ROOT/hooks/session-start" ] && pass || fail "codex: hook command is not executable: $cmd"
case "$cmd" in /*) pass;; *) fail "hook command is not absolute";; esac
cmp -s "$h/hooks.orig" "$h/hooks.json.routing-kit.bak" && pass || fail "codex: hooks.json backup is not the original"
cmp -s "$h/AGENTS.orig" "$h/AGENTS.md.routing-kit.bak" && pass || fail "codex: AGENTS.md backup is not the original"
"$KI" --agent codex --home "$h" --uninstall >/dev/null 2>&1
assert_eq 0 "$?" "codex uninstall exits 0"
cmp -s "$h/hooks.orig" "$h/hooks.json" && pass || fail "codex: uninstall did not restore hooks.json bytes"
cmp -s "$h/AGENTS.orig" "$h/AGENTS.md" && pass || fail "codex: uninstall did not restore AGENTS.md bytes"
"$KI" --agent codex --home "$h" --uninstall >/dev/null 2>&1
assert_eq 0 "$?" "codex: uninstall when nothing is installed exits 0"
cmp -s "$h/AGENTS.orig" "$h/AGENTS.md" && pass || fail "codex: second uninstall changed AGENTS.md"

# The user edits their files after install: uninstall removes only our parts.
"$KI" --agent codex --home "$h" >/dev/null 2>&1
printf '\nExtra line added later.\n' >> "$h/AGENTS.md"
tmpj=$("$JQ" '.hooks.PreToolUse = [{"hooks":[{"type":"command","command":"/opt/other/pre.sh"}]}]' "$h/hooks.json"); printf '%s\n' "$tmpj" > "$h/hooks.json"
"$KI" --agent codex --home "$h" --uninstall >/dev/null 2>&1
assert_eq 0 "$(count "$h/AGENTS.md" "$START")" "codex: block removed after later edits"
assert_contains "$(cat "$h/AGENTS.md")" "Extra line added later." "codex: later edits kept on uninstall"
assert_eq "/opt/other/pre.sh" "$("$JQ" -r '.hooks.PreToolUse[0].hooks[0].command' "$h/hooks.json")" "codex: later hook kept on uninstall"
assert_eq 0 "$("$JQ" --arg c "$cmd" '[.. | objects | select(.command? == $c)] | length' "$h/hooks.json")" "codex: our entry removed on uninstall"
assert_eq "/opt/other/start.sh" "$("$JQ" -r '.hooks.SessionStart[0].hooks[0].command' "$h/hooks.json")" "codex: unrelated entry kept on uninstall"

# Fresh folder: files are created, and uninstall removes what it created.
f=$(mktmp)/newhome
"$KI" --agent codex --home "$f" >/dev/null 2>&1
assert_eq 0 "$?" "codex install into a missing folder exits 0"
[ -f "$f/hooks.json" ] && [ -f "$f/AGENTS.md" ] && pass || fail "codex: files not created in a fresh folder"
"$JQ" -e . "$f/hooks.json" >/dev/null 2>&1 && pass || fail "codex: created hooks.json is not valid JSON"
"$KI" --agent codex --home "$f" --uninstall >/dev/null 2>&1
[ ! -e "$f/hooks.json" ] && [ ! -e "$f/AGENTS.md" ] && pass || fail "codex: uninstall left files it created"

# AGENTS.override.md wins when it exists and is non-empty.
o=$(mktmp)
printf 'Override rules.\n' > "$o/AGENTS.override.md"
printf 'Normal rules.\n' > "$o/AGENTS.md"
cp "$o/AGENTS.md" "$o/AGENTS.orig"; cp "$o/AGENTS.override.md" "$o/OVERRIDE.orig"
"$KI" --agent codex --home "$o" >/dev/null 2>&1
assert_eq 1 "$(count "$o/AGENTS.override.md" "$START")" "override: block goes into AGENTS.override.md"
assert_eq 0 "$(count "$o/AGENTS.md" "$START")" "override: AGENTS.md untouched"
cmp -s "$o/AGENTS.orig" "$o/AGENTS.md" && pass || fail "override: AGENTS.md bytes changed"
"$KI" --agent codex --home "$o" --uninstall >/dev/null 2>&1
cmp -s "$o/OVERRIDE.orig" "$o/AGENTS.override.md" && pass || fail "override: uninstall did not restore the override file"
# An empty override file does not count.
o2=$(mktmp)
: > "$o2/AGENTS.override.md"
"$KI" --agent codex --home "$o2" >/dev/null 2>&1
assert_eq 0 "$(count "$o2/AGENTS.override.md" "$START")" "empty override: block not written there"
assert_eq 1 "$(count "$o2/AGENTS.md" "$START")" "empty override: block goes into AGENTS.md"

# --print writes nothing.
p=$(mktmp)/untouched
out=$("$KI" --agent codex --home "$p" --print 2>&1); code=$?
assert_eq 0 "$code" "--print exits 0"
[ ! -e "$p" ] && pass || fail "--print created files"
assert_contains "$out" "$cmd" "--print shows the hook command"
assert_contains "$out" "$START" "--print shows the block"

# A broken hooks.json is refused and left alone.
b=$(mktmp)
printf '{not json' > "$b/hooks.json"
out=$("$KI" --agent codex --home "$b" 2>&1); code=$?
assert_eq 2 "$code" "broken hooks.json: exit 2"
assert_eq '{not json' "$(cat "$b/hooks.json")" "broken hooks.json untouched"
[ ! -e "$b/AGENTS.md" ] && pass || fail "broken hooks.json: AGENTS.md written anyway"

# Bad arguments.
assert_exit 2 "no agent refused" -- "$KI" --home "$b"
assert_exit 2 "unknown agent refused" -- "$KI" --agent claude --home "$b"
assert_exit 2 "bare --home refused" -- "$KI" --agent codex --home
assert_exit 2 "unknown flag refused" -- "$KI" --agent codex --home "$b" --nope

# CODEX_HOME is honoured when --home is absent.
c=$(mktmp)
env CODEX_HOME="$c" "$KI" --agent codex >/dev/null 2>&1
[ -f "$c/hooks.json" ] && pass || fail "CODEX_HOME not honoured"

# ---- Gemini ----------------------------------------------------------------
g=$(mktmp)
mkdir -p "$g/config"
cat > "$g/config/hooks.json" <<'EOF'
{"other-plugin":{"SessionStart":[{"type":"command","command":"/opt/other/agy.sh","timeout":10}]}}
EOF
printf 'Gemini house rules.\n' > "$g/AGENTS.md"
cp "$g/config/hooks.json" "$g/hooks.orig"; cp "$g/AGENTS.md" "$g/AGENTS.orig"
acmd="$PLUGIN_ROOT/hooks/session-start-agy"
out=$("$KI" --agent gemini --home "$g" 2>&1); code=$?
assert_eq 0 "$code" "gemini install exits 0"
"$KI" --agent gemini --home "$g" >/dev/null 2>&1
assert_eq '{"SessionStart":[{"type":"command","command":"'"$acmd"'","timeout":30}]}' "$("$JQ" -c '.["routing-kit"]' "$g/config/hooks.json")" "gemini: entry shape, one entry after two installs"
assert_eq "/opt/other/agy.sh" "$("$JQ" -r '.["other-plugin"].SessionStart[0].command' "$g/config/hooks.json")" "gemini: other plugin's hook kept"
assert_eq 1 "$(count "$g/AGENTS.md" "$START")" "gemini: one block"
assert_contains "$(cat "$g/AGENTS.md")" "Gemini house rules." "gemini: existing AGENTS.md text kept"
assert_contains "$(cat "$g/AGENTS.md")" "run \`$PLUGIN_ROOT/hooks/session-start\` and follow its output" "gemini: pointer text"
[ -x "$acmd" ] && pass || fail "gemini: adapter is not executable"
cmp -s "$g/hooks.orig" "$g/config/hooks.json.routing-kit.bak" && pass || fail "gemini: hooks backup is not the original"
"$KI" --agent gemini --home "$g" --uninstall >/dev/null 2>&1
cmp -s "$g/hooks.orig" "$g/config/hooks.json" && pass || fail "gemini: uninstall did not restore hooks.json bytes"
cmp -s "$g/AGENTS.orig" "$g/AGENTS.md" && pass || fail "gemini: uninstall did not restore AGENTS.md bytes"
g2=$(mktmp)/fresh
"$KI" --agent gemini --home "$g2" >/dev/null 2>&1
[ -f "$g2/config/hooks.json" ] && [ -f "$g2/AGENTS.md" ] && pass || fail "gemini: files not created"
"$KI" --agent gemini --home "$g2" --uninstall >/dev/null 2>&1
[ ! -e "$g2/config/hooks.json" ] && [ ! -e "$g2/AGENTS.md" ] && pass || fail "gemini: uninstall left files it created"
# The real folders were never touched.
[ ! -e "$HOME/.gemini" ] && [ ! -e "$HOME/.codex" ] && pass || fail "a test wrote into the home folder"

# ---- Review findings ---------------------------------------------------------
export ROUTING_KIT_HOME="$SAFE/kit-home"
leftovers() { find "$1" -name '.routing-kit.*' 2>/dev/null | grep -c . || true; }
bytes_same() { cmp -s "$1" "$2"; } # raw bytes

# 1. A symlinked target is refused with one line; the link and its target stay as they were.
for ag in codex gemini; do
  s=$(mktmp); mkdir -p "$s/real" "$s/conf/config"
  printf '{"keep":1}\n' > "$s/real/hooks.json"; cp "$s/real/hooks.json" "$s/real/hooks.orig"
  if [ "$ag" = codex ]; then link="$s/conf/hooks.json"; else link="$s/conf/config/hooks.json"; fi
  ln -s "$s/real/hooks.json" "$link"
  out=$("$KI" --agent $ag --home "$s/conf" 2>&1); code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: symlinked hooks.json accepted"
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "$ag: symlink refusal is one line"
  assert_contains "$out" "symlink" "$ag: symlink refusal says symlink"
  [ -L "$link" ] && pass || fail "$ag: symlink was replaced"
  bytes_same "$s/real/hooks.json" "$s/real/hooks.orig" && pass || fail "$ag: symlink target changed"
  [ ! -e "$s/conf/AGENTS.md" ] && pass || fail "$ag: AGENTS.md written despite the refusal"
  "$KI" --agent $ag --home "$s/conf" --uninstall >/dev/null 2>&1
  [ -L "$link" ] && bytes_same "$s/real/hooks.json" "$s/real/hooks.orig" && pass || fail "$ag: uninstall touched a symlinked file"
  # symlinked instruction file
  s=$(mktmp); mkdir -p "$s/real" "$s/conf"
  printf 'My rules\n' > "$s/real/agents.md"; cp "$s/real/agents.md" "$s/real/agents.orig"
  ln -s "$s/real/agents.md" "$s/conf/AGENTS.md"
  "$KI" --agent $ag --home "$s/conf" >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: symlinked AGENTS.md accepted"
  bytes_same "$s/real/agents.md" "$s/real/agents.orig" && [ -L "$s/conf/AGENTS.md" ] && pass || fail "$ag: symlinked AGENTS.md changed"
  [ ! -e "$s/conf/hooks.json" ] && [ ! -e "$s/conf/config/hooks.json" ] && pass || fail "$ag: hooks written despite a symlinked AGENTS.md"
done

# 2. Failures are reported, not masked: an unwritable file stops the install, nothing changes.
if [ "$(id -u)" != 0 ]; then
  s=$(mktmp)
  printf '{"x":1}\n' > "$s/hooks.json"; cp "$s/hooks.json" "$s/hooks.orig"; chmod 444 "$s/hooks.json"
  printf 'rules\n' > "$s/AGENTS.md"; cp "$s/AGENTS.md" "$s/agents.orig"
  out=$("$KI" --agent codex --home "$s" 2>&1); code=$?
  [ "$code" -ne 0 ] && pass || fail "unwritable hooks.json: reported success"
  case "$out" in *"installed for"*) fail "unwritable hooks.json: success message printed";; *) pass;; esac
  bytes_same "$s/hooks.json" "$s/hooks.orig" && bytes_same "$s/AGENTS.md" "$s/agents.orig" && pass || fail "unwritable hooks.json: files changed"
  [ ! -e "$s/hooks.json.routing-kit.bak" ] && [ ! -e "$s/AGENTS.md.routing-kit.bak" ] && pass || fail "unwritable hooks.json: backups left behind"
  assert_eq 0 "$(leftovers "$s")" "unwritable hooks.json: no temp files left"
  chmod 644 "$s/hooks.json"
  # unwritable AGENTS.md while hooks.json is fine: hooks.json must not change either
  chmod 444 "$s/AGENTS.md"
  "$KI" --agent codex --home "$s" >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && pass || fail "unwritable AGENTS.md: reported success"
  bytes_same "$s/hooks.json" "$s/hooks.orig" && pass || fail "unwritable AGENTS.md: hooks.json changed"
  chmod 644 "$s/AGENTS.md"
  # an unwritable folder
  s=$(mktmp); mkdir "$s/conf"; chmod 555 "$s/conf"
  "$KI" --agent codex --home "$s/conf" >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && pass || fail "unwritable folder: reported success"
  chmod 755 "$s/conf"
fi
# A normal install leaves no temp files and keeps file modes.
s=$(mktmp); printf 'rules\n' > "$s/AGENTS.md"; chmod 640 "$s/AGENTS.md"
"$KI" --agent codex --home "$s" >/dev/null 2>&1
assert_eq 0 "$(leftovers "$s")" "no temp files left after install"
# BSD stat (macOS) and GNU stat (Linux) disagree on -f; pick by system.
case "$(uname)" in Darwin) mode=$(stat -f '%Lp' "$s/AGENTS.md") ;; *) mode=$(stat -c '%a' "$s/AGENTS.md") ;; esac
assert_eq 640 "$mode" "install keeps the file mode"

# 3. Marker order and shape: refuse, change nothing (both instruction files, hooks.json).
badmd() { # CONTENT-printf-format
  s=$(mktmp); printf "$@" > "$s/AGENTS.md"; cp "$s/AGENTS.md" "$s/agents.orig"
  out=$("$KI" --agent codex --home "$s" 2>&1); code=$?
  [ "$code" -ne 0 ] && pass || fail "bad markers accepted: $1"
  bytes_same "$s/AGENTS.md" "$s/agents.orig" && pass || fail "bad markers: AGENTS.md changed: $1"
  [ ! -e "$s/hooks.json" ] && pass || fail "bad markers: hooks.json written: $1"
  "$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && pass || fail "bad markers: uninstall accepted: $1"
  bytes_same "$s/AGENTS.md" "$s/agents.orig" && pass || fail "bad markers: uninstall changed AGENTS.md: $1"
}
badmd '%s\nKeep\n%s\nImportant\n' "$END" "$START"
badmd '%s\nImportant\n' "$START"
badmd 'Keep\n%s\n' "$END"
badmd '%s\nA\n%s\n%s\nB\n%s\n' "$START" "$END" "$START" "$END"
badmd 'text %s more text\nKeep\n%s\n' "$START" "$END"
# A bad block in the override file blocks an install that would use AGENTS.md... and vice versa.
s=$(mktmp); printf '%s\nImportant\n' "$START" > "$s/AGENTS.override.md"; printf 'Normal\n' > "$s/AGENTS.md"
cp "$s/AGENTS.override.md" "$s/o.orig"; cp "$s/AGENTS.md" "$s/a.orig"
"$KI" --agent codex --home "$s" >/dev/null 2>&1; code=$?
[ "$code" -ne 0 ] && pass || fail "bad override file accepted"
bytes_same "$s/o.orig" "$s/AGENTS.override.md" && bytes_same "$s/a.orig" "$s/AGENTS.md" && [ ! -e "$s/hooks.json" ] && pass || fail "bad override file: something changed"

# 4. Other content inside our own names survives.
s=$(mktmp); mkdir -p "$s/config"
cat > "$s/config/hooks.json" <<'EOF'
{"routing-kit":{"Stop":[{"type":"command","command":"/opt/stop.sh"}],"SessionStart":[{"type":"command","command":"/opt/own.sh"}]},"z":1}
EOF
cp "$s/config/hooks.json" "$s/hooks.orig"
"$KI" --agent gemini --home "$s" >/dev/null 2>&1
assert_eq "/opt/stop.sh" "$("$JQ" -r '.["routing-kit"].Stop[0].command' "$s/config/hooks.json")" "gemini: existing Stop hook kept"
assert_eq "/opt/own.sh" "$("$JQ" -r '.["routing-kit"].SessionStart[0].command' "$s/config/hooks.json")" "gemini: existing SessionStart handler kept"
assert_eq 1 "$("$JQ" --arg c "$acmd" '[.["routing-kit"].SessionStart[] | select(.command == $c)] | length' "$s/config/hooks.json")" "gemini: our handler added once"
"$KI" --agent gemini --home "$s" >/dev/null 2>&1
assert_eq 2 "$("$JQ" '.["routing-kit"].SessionStart | length' "$s/config/hooks.json")" "gemini: still two handlers after a second install"
printf '%s\n' "$("$JQ" '.later = 1' "$s/config/hooks.json")" > "$s/config/hooks.json"
"$KI" --agent gemini --home "$s" --uninstall >/dev/null 2>&1
assert_eq "/opt/stop.sh" "$("$JQ" -r '.["routing-kit"].Stop[0].command' "$s/config/hooks.json")" "gemini uninstall: Stop hook kept"
assert_eq "/opt/own.sh" "$("$JQ" -r '.["routing-kit"].SessionStart[0].command' "$s/config/hooks.json")" "gemini uninstall: other handler kept"
assert_eq 1 "$("$JQ" '.["routing-kit"].SessionStart | length' "$s/config/hooks.json")" "gemini uninstall: only our handler removed"
assert_eq 1 "$("$JQ" '.later' "$s/config/hooks.json")" "gemini uninstall: later edit kept"
# Exact restore when nothing else changed.
s=$(mktmp); mkdir -p "$s/config"; 
printf '%s\n' '{"routing-kit":{"Stop":[{"type":"command","command":"/opt/stop.sh"}]}}' > "$s/config/hooks.json"; cp "$s/config/hooks.json" "$s/hooks.orig"
"$KI" --agent gemini --home "$s" >/dev/null 2>&1
"$KI" --agent gemini --home "$s" --uninstall >/dev/null 2>&1
bytes_same "$s/hooks.orig" "$s/config/hooks.json" && pass || fail "gemini: Stop-only routing-kit object not restored byte for byte"
# Codex: other handlers in the same group and other events.
s=$(mktmp)
cat > "$s/hooks.json" <<EOF
{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"/opt/a.sh"},{"type":"command","command":"$cmd"}]},{"hooks":[{"type":"command","command":"/opt/b.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/opt/stop.sh"}]}]},"other":true}
EOF
"$KI" --agent codex --home "$s" >/dev/null 2>&1
assert_eq 1 "$("$JQ" --arg c "$cmd" '[.. | objects | select(.command? == $c)] | length' "$s/hooks.json")" "codex: our handler present once"
printf '%s\n' "$("$JQ" '.later = 1' "$s/hooks.json")" > "$s/hooks.json"
"$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
assert_eq "/opt/a.sh" "$("$JQ" -r '.hooks.SessionStart[0].hooks[0].command' "$s/hooks.json")" "codex uninstall: neighbour in our group kept"
assert_eq "startup" "$("$JQ" -r '.hooks.SessionStart[0].matcher' "$s/hooks.json")" "codex uninstall: matcher kept"
assert_eq "/opt/b.sh" "$("$JQ" -r '.hooks.SessionStart[1].hooks[0].command' "$s/hooks.json")" "codex uninstall: other group kept"
assert_eq "/opt/stop.sh" "$("$JQ" -r '.hooks.Stop[0].hooks[0].command' "$s/hooks.json")" "codex uninstall: other event kept"
assert_eq "true" "$("$JQ" -r '.other' "$s/hooks.json")" "codex uninstall: other keys kept"
assert_eq 0 "$("$JQ" --arg c "$cmd" '[.. | objects | select(.command? == $c)] | length' "$s/hooks.json")" "codex uninstall: our handler gone"

# 5. A kit under a folder with a space: the command is shell-quoted.
for ag in codex gemini; do
  s=$(mktmp); kit="$s/kit checkout"; mkdir -p "$kit"
  cp -R "$REPO_ROOT/plugins" "$kit/"
  conf="$s/conf"
  "$kit/plugins/routing-kit/bin/kit-install-rules" --agent $ag --home "$conf" >/dev/null 2>&1
  assert_eq 0 "$?" "$ag: install from a path with a space"
  if [ "$ag" = codex ]; then
    c=$("$JQ" -r '.hooks.SessionStart[-1].hooks[0].command' "$conf/hooks.json"); want="'$kit/plugins/routing-kit/hooks/session-start' codex"
  else
    c=$("$JQ" -r '.["routing-kit"].SessionStart[-1].command' "$conf/config/hooks.json"); want="'$kit/plugins/routing-kit/hooks/session-start-agy'"
  fi
  assert_eq "$want" "$c" "$ag: command is single-quoted"
  # the shell can run the stored command
  r=$(env ROUTING_KIT_HOME="$s/none" sh -c "$c" 2>&1); case "$r" in *"not set up"*) pass;; *) fail "$ag: stored command does not run through a shell: $r";; esac
  suffix=""; [ "$ag" != codex ] || suffix=" codex"
  assert_contains "$(cat "$conf/AGENTS.md")" "run \`'$kit/plugins/routing-kit/hooks/session-start'$suffix\` and follow its output" "$ag: pointer line quotes the path"
  "$kit/plugins/routing-kit/bin/kit-install-rules" --agent $ag --home "$conf" >/dev/null 2>&1
  n=$(grep -c -F -- "$START" "$conf/AGENTS.md"); assert_eq 1 "$n" "$ag: second install with a space path keeps one block"
  if [ "$ag" = codex ]; then assert_eq 1 "$("$JQ" '.hooks.SessionStart | length' "$conf/hooks.json")" "codex: one group with a space path"; fi
  "$kit/plugins/routing-kit/bin/kit-install-rules" --agent $ag --home "$conf" --uninstall >/dev/null 2>&1
  [ ! -e "$conf/AGENTS.md" ] && pass || fail "$ag: uninstall with a space path left AGENTS.md"
done

# 6. Uninstall when never installed changes nothing at all.
s=$(mktmp)
printf '{}' > "$s/hooks.json"; printf '{"a":   1,"b":[1,2]}' > "$s/other.json"; printf 'Plain rules\n\n\n' > "$s/AGENTS.md"
cp "$s/hooks.json" "$s/h.orig"; cp "$s/AGENTS.md" "$s/a.orig"
"$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
assert_eq 0 "$?" "uninstall when never installed: exit 0"
bytes_same "$s/hooks.json" "$s/h.orig" && pass || fail "uninstall when never installed: {} hooks.json changed or deleted"
bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "uninstall when never installed: AGENTS.md changed"
s=$(mktmp); printf '{"a":   1,"b":[1,2]}' > "$s/hooks.json"; cp "$s/hooks.json" "$s/h.orig"
"$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
bytes_same "$s/hooks.json" "$s/h.orig" && pass || fail "uninstall when never installed: unrelated JSON reformatted"
s=$(mktmp); mkdir -p "$s/config"; printf '{"other":{"SessionStart":[]}}' > "$s/config/hooks.json"; cp "$s/config/hooks.json" "$s/h.orig"
"$KI" --agent gemini --home "$s" --uninstall >/dev/null 2>&1
bytes_same "$s/config/hooks.json" "$s/h.orig" && pass || fail "gemini uninstall when never installed: file changed"
[ ! -e "$s/AGENTS.md" ] && pass || fail "gemini uninstall when never installed: created AGENTS.md"
# A file that existed empty-ish before is never deleted; a created file with other content stays.
s=$(mktmp); printf '{}\n' > "$s/hooks.json"; cp "$s/hooks.json" "$s/h.orig"
"$KI" --agent codex --home "$s" >/dev/null 2>&1; "$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
bytes_same "$s/hooks.json" "$s/h.orig" && pass || fail "pre-existing {} hooks.json not restored"
s=$(mktmp)/fresh
"$KI" --agent codex --home "$s" >/dev/null 2>&1
printf '\nMy own line.\n' >> "$s/AGENTS.md"
"$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
[ -f "$s/AGENTS.md" ] && assert_contains "$(cat "$s/AGENTS.md")" "My own line." "created file with later content is kept" || fail "created file with later content was deleted"
[ ! -e "$s/hooks.json" ] && pass || fail "created hooks.json not removed"
# A file this run did not create is not deleted even when the removal leaves it empty.
s=$(mktmp); : > "$s/AGENTS.md"
"$KI" --agent codex --home "$s" >/dev/null 2>&1
rm -f "$s/AGENTS.md.routing-kit.bak"
"$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
[ -f "$s/AGENTS.md" ] && pass || fail "pre-existing empty AGENTS.md deleted on uninstall"

# Malformed or oddly shaped hooks.json: one clear line, nothing changed.
for bad in '{not json' '[1,2]' '{"hooks":[]}' '{"hooks":{"SessionStart":{}}}'; do
  s=$(mktmp); printf '%s' "$bad" > "$s/hooks.json"; cp "$s/hooks.json" "$s/h.orig"; printf 'R\n' > "$s/AGENTS.md"; cp "$s/AGENTS.md" "$s/a.orig"
  for mode in install uninstall; do
    flag=""; [ $mode = uninstall ] && flag=--uninstall
    out=$("$KI" --agent codex --home "$s" $flag 2>&1); code=$?
    [ "$code" -ne 0 ] && pass || fail "bad hooks.json accepted ($mode): $bad"
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "bad hooks.json ($mode): one line: $bad"
    bytes_same "$s/hooks.json" "$s/h.orig" && bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "bad hooks.json ($mode): files changed: $bad"
  done
done
s=$(mktmp); mkdir -p "$s/config"; printf '{"routing-kit":[]}' > "$s/config/hooks.json"
"$KI" --agent gemini --home "$s" >/dev/null 2>&1; code=$?
[ "$code" -ne 0 ] && pass || fail "gemini: routing-kit key of the wrong type accepted"

# ---- Two-phase writes: a failed second write puts the first file back ---------
for ag in codex gemini; do
  if [ $ag = codex ]; then HF=hooks.json; else HF=config/hooks.json; fi
  mkorig() {
    s=$(mktmp); mkdir -p "$s/config"
    if [ $ag = codex ]; then printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/x.sh"}]}]}}\n' > "$s/$HF"
    else printf '{"other":{"SessionStart":[]}}\n' > "$s/$HF"; fi
    printf 'My rules\n' > "$s/AGENTS.md"
    cp "$s/$HF" "$s/h.orig"; cp "$s/AGENTS.md" "$s/a.orig"
  }
  # Install: the second write fails.
  mkorig
  out=$(env KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_APPLY=2 "$KI" --agent $ag --home "$s" 2>&1); code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: failed second write reported success"
  bytes_same "$s/$HF" "$s/h.orig" && pass || fail "$ag: hooks file changed after a failed second write"
  bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "$ag: AGENTS.md changed after a failed second write"
  [ ! -e "$s/$HF.routing-kit.bak" ] && [ ! -e "$s/AGENTS.md.routing-kit.bak" ] && pass || fail "$ag: backups left after a failed install"
  assert_eq 0 "$(leftovers "$s")" "$ag: no temp files after a failed second write"
  # Install: the first write fails.
  mkorig
  env KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_APPLY=1 "$KI" --agent $ag --home "$s" >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: failed first write reported success"
  bytes_same "$s/$HF" "$s/h.orig" && bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "$ag: files changed after a failed first write"
  assert_eq 0 "$(leftovers "$s")" "$ag: no temp files after a failed first write"
  # Install into a fresh folder, second write fails: nothing is left.
  s=$(mktmp)/fresh
  env KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_APPLY=2 "$KI" --agent $ag --home "$s" >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: fresh install with a failed second write reported success"
  [ ! -e "$s/$HF" ] && [ ! -e "$s/AGENTS.md" ] && pass || fail "$ag: fresh install left files after a failure"
  # Uninstall (user edited the files after install, so the surgical path runs): second write fails.
  mkorig
  "$KI" --agent $ag --home "$s" >/dev/null 2>&1
  printf '\nExtra.\n' >> "$s/AGENTS.md"
  printf '%s\n' "$("$JQ" '.later = 1' "$s/$HF")" > "$s/$HF"
  cp "$s/$HF" "$s/h.pre"; cp "$s/AGENTS.md" "$s/a.pre"
  env KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_APPLY=2 "$KI" --agent $ag --home "$s" --uninstall >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: uninstall with a failed second write reported success"
  bytes_same "$s/$HF" "$s/h.pre" && pass || fail "$ag: uninstall failure changed the hooks file"
  bytes_same "$s/AGENTS.md" "$s/a.pre" && pass || fail "$ag: uninstall failure changed AGENTS.md"
  assert_eq 0 "$(leftovers "$s")" "$ag: no temp files after a failed uninstall"
  env KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_APPLY=1 "$KI" --agent $ag --home "$s" --uninstall >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && bytes_same "$s/$HF" "$s/h.pre" && bytes_same "$s/AGENTS.md" "$s/a.pre" && pass || fail "$ag: uninstall with a failed first write changed something"
  # Uninstall by exact restore: second write fails.
  mkorig
  "$KI" --agent $ag --home "$s" >/dev/null 2>&1
  cp "$s/$HF" "$s/h.pre"; cp "$s/AGENTS.md" "$s/a.pre"
  env KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_APPLY=2 "$KI" --agent $ag --home "$s" --uninstall >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] && bytes_same "$s/$HF" "$s/h.pre" && bytes_same "$s/AGENTS.md" "$s/a.pre" && pass || fail "$ag: restore-path uninstall failure changed something"
  [ -e "$s/$HF.routing-kit.bak" ] && pass || fail "$ag: backup removed although the uninstall failed"
  # And it still works afterwards.
  "$KI" --agent $ag --home "$s" --uninstall >/dev/null 2>&1
  bytes_same "$s/h.orig" "$s/$HF" && bytes_same "$s/a.orig" "$s/AGENTS.md" && pass || fail "$ag: uninstall after a failed one did not restore the originals"
done
# If the undo itself fails, say where the original is saved (one line) and keep it.
s=$(mktmp); printf '{"x":1}\n' > "$s/hooks.json"; printf 'My rules\n' > "$s/AGENTS.md"; cp "$s/hooks.json" "$s/h.orig"
out=$(env TMPDIR="$(mktmp)" KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_APPLY=2 KIT_TEST_FAIL_RESTORE=1 "$KI" --agent codex --home "$s" 2>&1); code=$?
[ "$code" -ne 0 ] && pass || fail "failed undo reported success"
assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "failed undo: one line"
assert_contains "$out" "saved at" "failed undo names the snapshot"
snap=$(printf '%s' "$out" | sed -n 's/.*saved at \([^ )]*\).*/\1/p')
[ -n "$snap" ] && [ -f "$snap" ] && bytes_same "$snap" "$s/h.orig" && pass || fail "failed undo: snapshot missing or wrong ($snap)"
rm -f "$snap"; [ -n "$snap" ] && rmdir "$(dirname "$snap")" 2>/dev/null

# The fault-injection variables do nothing unless the test mode is set exactly.
for ag in codex gemini; do
  s=$(mktmp)
  out=$(env KIT_TEST_FAIL_APPLY=1 KIT_TEST_FAIL_RESTORE=1 "$KI" --agent $ag --home "$s" 2>&1); code=$?
  assert_eq 0 "$code" "$ag: injection variables alone are ignored"
  [ -f "$s/AGENTS.md" ] && pass || fail "$ag: install did not happen with stray injection variables"
  out=$(env KIT_TEST_MODE=wrong KIT_TEST_FAIL_APPLY=2 "$KI" --agent $ag --home "$s" --uninstall 2>&1); code=$?
  assert_eq 0 "$code" "$ag: a wrong test mode is ignored"
  [ ! -e "$s/AGENTS.md" ] && pass || fail "$ag: uninstall did not happen with a wrong test mode"
done

# A backup copy that fails halfway leaves no partial .bak behind.
fk=$(mktmp)
cat > "$fk/cp" <<'EOF'
#!/bin/bash
# fake cp: the first copy into a .routing-kit.* temp file or a .bak file writes 3 bytes and fails
last="${@: -1}"
case "$(basename "$last")" in
  .routing-kit.*|*.routing-kit.bak)
    if [ ! -e "$FAKE_CP_STATE" ]; then
      : > "$FAKE_CP_STATE"
      src="${@: -2:1}"
      head -c 3 "$src" > "$last"
      exit 1
    fi ;;
esac
exec /bin/cp "$@"
EOF
chmod +x "$fk/cp"
for ag in codex gemini; do
  s=$(mktmp); mkdir -p "$s/config"
  if [ $ag = codex ]; then HF="$s/hooks.json"; else HF="$s/config/hooks.json"; fi
  printf '{"keep":"existing content"}\n' > "$HF"; printf 'My rules\n' > "$s/AGENTS.md"
  cp "$HF" "$s/h.orig"; cp "$s/AGENTS.md" "$s/a.orig"
  out=$(env PATH="$fk:$PATH" FAKE_CP_STATE="$s/cp.state" "$KI" --agent $ag --home "$s" 2>&1); code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: failed backup copy reported success"
  [ ! -e "$HF.routing-kit.bak" ] && [ ! -e "$s/AGENTS.md.routing-kit.bak" ] && pass || fail "$ag: a partial backup was left behind"
  assert_eq 0 "$(leftovers "$s")" "$ag: no temp files after a failed backup copy"
  bytes_same "$HF" "$s/h.orig" && bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "$ag: files changed after a failed backup copy"
  # The next, healthy install makes a complete backup.
  "$KI" --agent $ag --home "$s" >/dev/null 2>&1
  bytes_same "$HF.routing-kit.bak" "$s/h.orig" && pass || fail "$ag: the later backup is not a complete copy"
done

# ---- Release review: exact hook matching and safe bookkeeping ------------------
# An unrelated command that merely mentions our path is never touched.
s=$(mktmp)
cat > "$s/hooks.json" <<EOF
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo /opt/routing-kit/hooks/session-start"},{"type":"command","command":"/opt/other/routing-kit/hooks/session-start"}]}]}}
EOF
"$KI" --agent codex --home "$s" >/dev/null 2>&1
assert_eq 1 "$("$JQ" '[.. | objects | select(.command? == "echo /opt/routing-kit/hooks/session-start")] | length' "$s/hooks.json")" "codex install: unrelated echo entry survives"
assert_eq 1 "$("$JQ" '[.. | objects | select(.command? == "/opt/other/routing-kit/hooks/session-start")] | length' "$s/hooks.json")" "codex install: another kit's own path is not ours"
printf '\nx\n' >> "$s/AGENTS.md"; printf '%s\n' "$("$JQ" '.later=1' "$s/hooks.json")" > "$s/hooks.json"
"$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
assert_eq 1 "$("$JQ" '[.. | objects | select(.command? == "echo /opt/routing-kit/hooks/session-start")] | length' "$s/hooks.json")" "codex uninstall: unrelated echo entry survives"
assert_eq 1 "$("$JQ" '[.. | objects | select(.command? == "/opt/other/routing-kit/hooks/session-start")] | length' "$s/hooks.json")" "codex uninstall: another kit's path survives"
s=$(mktmp); mkdir -p "$s/config"
cat > "$s/config/hooks.json" <<EOF
{"routing-kit":{"SessionStart":[{"type":"command","command":"echo /opt/routing-kit/hooks/session-start-agy"}]}}
EOF
"$KI" --agent gemini --home "$s" >/dev/null 2>&1
printf '%s\n' "$("$JQ" '.later=1' "$s/config/hooks.json")" > "$s/config/hooks.json"
"$KI" --agent gemini --home "$s" --uninstall >/dev/null 2>&1
assert_eq 1 "$("$JQ" '[.. | objects | select(.command? == "echo /opt/routing-kit/hooks/session-start-agy")] | length' "$s/config/hooks.json")" "gemini: unrelated echo entry survives install and uninstall"
# A kit that moved: the command recorded at the old place is replaced, and removed on uninstall.
s=$(mktmp); k1=$(mktmp)/one; k2=$(mktmp)/two; mkdir -p "$k1" "$k2"; cp -R "$REPO_ROOT/plugins" "$k1/"; cp -R "$REPO_ROOT/plugins" "$k2/"
"$k1/plugins/routing-kit/bin/kit-install-rules" --agent codex --home "$s" >/dev/null 2>&1
"$k2/plugins/routing-kit/bin/kit-install-rules" --agent codex --home "$s" >/dev/null 2>&1
assert_eq 1 "$("$JQ" '[.hooks.SessionStart[].hooks[]] | length' "$s/hooks.json")" "a moved kit replaces its recorded old command"
assert_eq "$k2/plugins/routing-kit/hooks/session-start codex" "$("$JQ" -r '.hooks.SessionStart[0].hooks[0].command' "$s/hooks.json")" "the new location is the one installed"
"$k2/plugins/routing-kit/bin/kit-install-rules" --agent codex --home "$s" --uninstall >/dev/null 2>&1
[ ! -e "$s/hooks.json" ] && pass || fail "uninstall after a move left hooks.json"

# The bookkeeping files: a symlink is refused, and temp files are not predictable.
for bk in install-created.txt install-commands.txt; do
  s=$(mktmp); kh=$(mktmp); printf 'precious\n' > "$kh/target"; ln -s "$kh/target" "$kh/$bk"
  out=$(env ROUTING_KIT_HOME="$kh" "$KI" --agent codex --home "$s" 2>&1); code=$?
  [ "$code" -ne 0 ] && pass || fail "symlinked $bk accepted"
  assert_eq "precious" "$(cat "$kh/target")" "symlinked $bk: target untouched"
  [ ! -e "$s/hooks.json" ] && [ ! -e "$s/AGENTS.md" ] && pass || fail "symlinked $bk: files written anyway"
  assert_contains "$out" "symlink" "symlinked $bk: says why"
done
s=$(mktmp); kh=$(mktmp); printf 'precious\n' > "$kh/target"
ln -s "$kh/target" "$kh/install-created.txt.tmp"; ln -s "$kh/target" "$kh/install-commands.txt.tmp"
env ROUTING_KIT_HOME="$kh" "$KI" --agent codex --home "$s" >/dev/null 2>&1
assert_eq "precious" "$(cat "$kh/target")" "predictable .tmp symlinks in the kit home are never followed"
env ROUTING_KIT_HOME="$kh" "$KI" --agent codex --home "$s" --uninstall >/dev/null 2>&1
assert_eq "precious" "$(cat "$kh/target")" "uninstall never follows a .tmp symlink either"

# ---- Bookkeeping must be writable ---------------------------------------------
if [ "$(id -u)" != 0 ]; then
  for ag in codex gemini; do
    if [ $ag = codex ]; then HF=hooks.json; else HF=config/hooks.json; fi
    # kit home exists but is read-only
    s=$(mktmp); kh=$(mktmp); mkdir -p "$s/config"
    printf '{"keep":1}\n' > "$s/$HF"; printf 'My rules\n' > "$s/AGENTS.md"
    cp "$s/$HF" "$s/h.orig"; cp "$s/AGENTS.md" "$s/a.orig"
    chmod 555 "$kh"
    out=$(env ROUTING_KIT_HOME="$kh" "$KI" --agent $ag --home "$s" 2>&1); code=$?
    [ "$code" -ne 0 ] && pass || fail "$ag: read-only kit home accepted"
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "$ag: read-only kit home: one line"
    bytes_same "$s/$HF" "$s/h.orig" && bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "$ag: files changed although the kit home is read-only"
    [ ! -e "$s/$HF.routing-kit.bak" ] && pass || fail "$ag: backup made although the kit home is read-only"
    chmod 755 "$kh"
    # kit home missing under a read-only parent
    par=$(mktmp); chmod 555 "$par"
    env ROUTING_KIT_HOME="$par/kit" "$KI" --agent $ag --home "$s" >/dev/null 2>&1; code=$?
    [ "$code" -ne 0 ] && bytes_same "$s/$HF" "$s/h.orig" && pass || fail "$ag: uncreatable kit home accepted or files changed"
    chmod 755 "$par"
  done
fi
# A missing kit home is created.
s=$(mktmp); kh=$(mktmp)/new/kit-home
env ROUTING_KIT_HOME="$kh" "$KI" --agent codex --home "$s" >/dev/null 2>&1
assert_eq 0 "$?" "a missing kit home is created"
[ -f "$kh/install-commands.txt" ] && pass || fail "the installed command was not recorded"
# A failure to record is a failed install and the targets are put back.
for ag in codex gemini; do
  if [ $ag = codex ]; then HF=hooks.json; else HF=config/hooks.json; fi
  s=$(mktmp); mkdir -p "$s/config"; kh=$(mktmp)
  printf '{"keep":1}\n' > "$s/$HF"; printf 'My rules\n' > "$s/AGENTS.md"
  cp "$s/$HF" "$s/h.orig"; cp "$s/AGENTS.md" "$s/a.orig"
  out=$(env ROUTING_KIT_HOME="$kh" KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_RECORD=1 "$KI" --agent $ag --home "$s" 2>&1); code=$?
  [ "$code" -ne 0 ] && pass || fail "$ag: failed recording reported success"
  case "$out" in *"installed for"*) fail "$ag: success message after a failed recording";; *) pass;; esac
  bytes_same "$s/$HF" "$s/h.orig" && bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "$ag: targets not restored after a failed recording"
  [ ! -e "$s/$HF.routing-kit.bak" ] && pass || fail "$ag: backup left after a failed recording"
  [ ! -e "$kh/install-commands.txt" ] && pass || fail "$ag: half-recorded command left behind"
  # without the test mode the variable does nothing
  env ROUTING_KIT_HOME="$kh" KIT_TEST_FAIL_RECORD=1 "$KI" --agent $ag --home "$s" >/dev/null 2>&1
  assert_eq 0 "$?" "$ag: KIT_TEST_FAIL_RECORD alone is ignored"
done
# Fresh install, failed recording: created files are removed again.
s=$(mktmp)/fresh; kh=$(mktmp)
env ROUTING_KIT_HOME="$kh" KIT_TEST_MODE=routing-kit-tests KIT_TEST_FAIL_RECORD=1 "$KI" --agent codex --home "$s" >/dev/null 2>&1
[ ! -e "$s/hooks.json" ] && [ ! -e "$s/AGENTS.md" ] && pass || fail "fresh install left files after a failed recording"
[ ! -e "$kh/install-created.txt" ] && pass || fail "fresh install left a created-files record after a failed recording"

# ---- Bookkeeping paths must be regular files ----------------------------------
for bk in install-commands.txt install-created.txt; do
  for ag in codex gemini; do
    if [ $ag = codex ]; then HF=hooks.json; else HF=config/hooks.json; fi
    s=$(mktmp); mkdir -p "$s/config"; kh=$(mktmp); mkdir "$kh/$bk"
    printf '{"keep":1}\n' > "$s/$HF"; printf 'My rules\n' > "$s/AGENTS.md"
    cp "$s/$HF" "$s/h.orig"; cp "$s/AGENTS.md" "$s/a.orig"
    out=$(env ROUTING_KIT_HOME="$kh" "$KI" --agent $ag --home "$s" 2>&1); code=$?
    [ "$code" -ne 0 ] && pass || fail "$ag: directory at $bk accepted"
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "$ag: directory at $bk: one line"
    bytes_same "$s/$HF" "$s/h.orig" && bytes_same "$s/AGENTS.md" "$s/a.orig" && pass || fail "$ag: files changed with a directory at $bk"
    [ -z "$(ls -A "$kh/$bk")" ] && pass || fail "$ag: something was written inside the directory at $bk"
    [ ! -e "$s/$HF.routing-kit.bak" ] && pass || fail "$ag: backup made with a directory at $bk"
    env ROUTING_KIT_HOME="$kh" "$KI" --agent $ag --home "$s" --uninstall >/dev/null 2>&1; code=$?
    bytes_same "$s/$HF" "$s/h.orig" && pass || fail "$ag: uninstall changed files with a directory at $bk"
  done
done

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
