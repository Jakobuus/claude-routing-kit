#!/bin/bash
# kit-retained: the only thing that deletes retained build copies, and only when told how old.
# Every section works in a kit home of its own; the harness removes them all at the end.
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/plugins/routing-kit/bin/kit-retained"
DOCTOR="$ROOT/plugins/routing-kit/bin/kit-doctor"
LIB="$ROOT/plugins/routing-kit/lib/retained.py"
. "$ROOT/plugins/routing-kit/bin/kit-common"
now=$(date +%s)
newhome() { # a fresh kit home; sets T, R and ROUTING_KIT_HOME
  T=$(mktmp)
  export ROUTING_KIT_HOME="$T/home"
  R="$T/home/retained"
}
mkcopy() { # NAME AGE_DAYS: a retained copy with its note
  mkdir -p "$R/$1/sub"
  echo work > "$R/$1/sub/file.txt"
  printf 'retained_at=%s\nretained=x\nfrom=/somewhere/%s/wt\nwhy=test copy %s\n' "$((now - $2 * 86400 - 60))" "$1" "$1" > "$R/$1.why"
}

# --- nothing retained yet
newhome
out=$("$BIN" list 2>&1)
assert_eq 0 "$?" "list with no retained folder exits 0"
assert_contains "$out" "kit-retained: 0 retained" "list with nothing retained says so"
out=$("$BIN" prune --older-than 1 2>&1)
assert_eq 0 "$?" "prune with no retained folder exits 0"

# --- list, usage, and what prune may touch
newhome
mkcopy old-run 40
mkcopy mid-run 10
mkcopy new-run 0
mkdir -p "$R/no-note"; echo work > "$R/no-note/file.txt"
mkdir -p "$T/outside/precious"; echo keep > "$T/outside/precious/keep.txt"
ln -s "$T/outside/precious" "$R/link-out"
printf 'retained_at=1\nwhy=link\n' > "$R/link-out.why"
mkdir -p "$T/home/runs/some-run/wt"; echo keep > "$T/home/runs/some-run/wt/keep.txt"
mkdir -p "$R/old-run/readonly"; echo x > "$R/old-run/readonly/f"; chmod 555 "$R/old-run/readonly"

out=$("$BIN" list 2>&1)
assert_contains "$out" "old-run	test copy old-run" "list shows name and reason"
assert_contains "$out" "40d	" "list shows the age in days"
assert_contains "$out" "kit-retained: 4 retained" "list counts the copies (links are not copies)"
assert_eq "" "$(printf '%s\n' "$out" | grep 'link-out')" "list leaves links out"

# DAYS is required, a whole number of 1 or more: no default, nothing deleted without it.
for args in "prune" "prune --older-than" "prune --older-than soon" "prune --older-than -1" "prune 30" \
  "prune --older-than 30 extra" "delete" "" "prune --older-than 0" "prune --older-than 00" \
  "prune --older-than 1.5" "prune --older-than 0x10" "prune --older-than 1234567"; do
  $BIN $args >/dev/null 2>&1
  assert_eq 2 "$?" "bad usage exits 2: [$args]"
done
assert_eq true "$([ -f "$R/old-run/sub/file.txt" ] && [ -f "$R/mid-run/sub/file.txt" ] && echo true)" "bad usage deletes nothing"

out=$("$BIN" prune --older-than 30 2>&1)
assert_eq 0 "$?" "prune exits 0"
assert_eq true "$([ ! -e "$R/old-run" ] && [ ! -e "$R/old-run.why" ] && echo true)" "prune deletes the copy older than DAYS, read-only parts and note included"
assert_eq true "$([ -f "$R/mid-run/sub/file.txt" ] && [ -f "$R/mid-run.why" ] && [ -f "$R/new-run/sub/file.txt" ] && echo true)" "prune keeps younger copies"
assert_eq true "$([ -f "$R/no-note/file.txt" ] && echo true)" "prune never deletes a copy of unknown age"
assert_contains "$out" "age unknown, not pruned" "prune says which copy it could not date"
assert_contains "$out" "kit-retained: pruned 1, kept 3" "prune reports what it did"
assert_eq true "$([ -L "$R/link-out" ] && [ -f "$T/outside/precious/keep.txt" ] && echo true)" "prune leaves a link alone and never follows it"
assert_eq true "$([ -f "$T/home/runs/some-run/wt/keep.txt" ] && echo true)" "prune touches nothing outside retained"
assert_eq "" "$(ls -A "$R" | grep '^\.trash$')" "the private trash folder is gone after a prune"

out=$("$BIN" prune --older-than 1 2>&1)
assert_eq true "$([ ! -e "$R/mid-run" ] && [ -f "$R/new-run/sub/file.txt" ] && [ -f "$R/no-note/file.txt" ] && echo true)" "prune --older-than 1 deletes only dated copies older than a day"
assert_eq true "$([ -f "$T/outside/precious/keep.txt" ] && [ -f "$T/home/runs/some-run/wt/keep.txt" ] && echo true)" "still nothing outside retained is touched"

# --- review finding 4: DAYS is decimal. 010 is ten days, not eight; 08 is eight, not an error.
newhome
mkcopy nine-days 9
mkcopy seven-days 7
out=$("$BIN" prune --older-than 010 2>&1)
assert_eq 0 "$?" "prune --older-than 010 exits 0"
assert_eq true "$([ -f "$R/nine-days/sub/file.txt" ] && echo true)" "010 means ten days: a nine-day-old copy stays"
out=$("$BIN" prune --older-than 08 2>&1)
assert_eq 0 "$?" "prune --older-than 08 exits 0"
assert_eq true "$([ ! -e "$R/nine-days" ] && [ -f "$R/seven-days/sub/file.txt" ] && echo true)" "08 means eight days: nine days goes, seven stays"

# --- review finding 5: a retained_at that is not a plain, sane time is an unknown age.
newhome
n=0
for at in 99999999999999999999999999999999 "$((now + 86400))" 0 -5 12abc "" 007; do
  n=$((n + 1)); mkdir -p "$R/odd-$n"; echo work > "$R/odd-$n/file.txt"
  printf 'retained_at=%s\nwhy=odd\n' "$at" > "$R/odd-$n.why"
done
mkdir -p "$R/odd-nokey"; echo work > "$R/odd-nokey/file.txt"; printf 'why=no time at all\n' > "$R/odd-nokey.why"
mkcopy dated 40
out=$("$BIN" prune --older-than 30 2>&1)
assert_eq 0 "$?" "prune with unusable times exits 0"
assert_eq 8 "$(find "$R" -mindepth 2 -maxdepth 2 -name file.txt -path '*/odd-*' | wc -l | tr -d ' ')" "copies with an unusable retained_at are never pruned"
assert_eq "" "$(printf '%s\n' "$out" | grep -i 'integer expression')" "no shell arithmetic on the recorded time"
assert_contains "$out" "age unknown, not pruned: odd-1" "prune names a copy with an unusable time"
assert_eq true "$([ ! -e "$R/dated" ] && echo true)" "the properly dated old copy next to them is pruned"

# --- review finding 2: what is deleted is the very folder whose age was read, reached through
# the opened retained folder. Swapping the folder or the copy after the checks changes nothing.
# (a) A stand-in `chmod` on PATH makes the swap at the moment the old code had finished its
#     checks: retained becomes a link to another folder that holds a child of the same name.
newhome
mkcopy swap-root 40
mkdir -p "$T/victim/swap-root" "$T/shim"; echo outside > "$T/victim/swap-root/keep.txt"
cat > "$T/shim/chmod" <<SHIM
#!/bin/bash
if [ -d "$R" ] && [ ! -L "$R" ]; then mv "$R" "$T/retained.aside" && ln -s "$T/victim" "$R"; fi
exec /bin/chmod "\$@"
SHIM
chmod +x "$T/shim/chmod"
PATH="$T/shim:$PATH" "$BIN" prune --older-than 30 >/dev/null 2>&1
assert_eq outside "$(cat "$T/victim/swap-root/keep.txt" 2>/dev/null)" "a retained folder swapped for a link mid-prune is not followed"

# prune_with BODY: runs prune 30 with BODY as the code that runs between the checks and the move.
prune_with() {
  "$KIT_PYTHON3_BIN" -I - "$LIB" "$T/home" "$T" <<PY
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location('retained', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home, t = sys.argv[2], sys.argv[3]
def swap(root_fd, name):
$1
m.before_move = swap
sys.exit(m.prune(home, 30))
PY
}
# (b) The same swap in the new code's own gap.
newhome
mkcopy swap-root 40
mkdir -p "$T/victim/swap-root"; echo outside > "$T/victim/swap-root/keep.txt"
prune_with "    os.rename(home + '/retained', t + '/retained.aside'); os.symlink(t + '/victim', home + '/retained')" >/dev/null 2>&1
assert_eq outside "$(cat "$T/victim/swap-root/keep.txt" 2>/dev/null)" "swap in the gap: the outside folder is untouched"
# (c) The copy is replaced by a fresh one of the same name, with a fresh note, in the gap: the
#     fresh copy is not deleted on the strength of the old copy's age.
newhome
mkcopy swap-copy 40
prune_with "    os.rename(home + '/retained/' + name, t + '/old-copy'); os.mkdir(home + '/retained/' + name)
    open(home + '/retained/' + name + '/fresh.txt', 'w').write('fresh')
    open(home + '/retained/' + name + '.why', 'w').write('retained_at=%d' % time.time())" >/dev/null 2>&1
assert_eq fresh "$(cat "$R/swap-copy/fresh.txt" 2>/dev/null)" "a fresh copy that took the name in the gap is not deleted"
assert_eq true "$([ -f "$T/old-copy/sub/file.txt" ] && echo true)" "the copy that was moved away is not deleted either"
# (d) The same replacement against the old code, through a stand-in chmod.
newhome
mkcopy swap-shim 40
mkdir -p "$T/shim"
cat > "$T/shim/chmod" <<SHIM
#!/bin/bash
if [ ! -e "$T/old-shim" ] && [ -d "$R/swap-shim" ]; then
  mv "$R/swap-shim" "$T/old-shim"; mkdir -p "$R/swap-shim"; echo fresh > "$R/swap-shim/fresh.txt"
  printf 'retained_at=%s\nwhy=fresh\n' "\$(date +%s)" > "$R/swap-shim.why"
fi
exec /bin/chmod "\$@"
SHIM
chmod +x "$T/shim/chmod"
PATH="$T/shim:$PATH" "$BIN" prune --older-than 30 >/dev/null 2>&1
if [ -e "$T/old-shim" ]; then
  assert_eq fresh "$(cat "$R/swap-shim/fresh.txt" 2>/dev/null)" "a fresh copy swapped in by a stand-in chmod is not deleted"
else
  pass  # the new code never runs chmod, so this swap cannot happen; (c) covers its own gap
fi

# --- a retained folder that is itself a link is not trusted
newhome
mkdir -p "$T/real-retained/dated"; printf 'retained_at=1\n' > "$T/real-retained/dated.why"
mkdir -p "$T/home"; ln -s "$T/real-retained" "$R"
"$BIN" prune --older-than 1 >/dev/null 2>&1
assert_eq true "$([ -d "$T/real-retained/dated" ] && echo true)" "prune does nothing when retained is a link"

# --- kit-doctor: the full report counts retained copies and their size; the fast run leaves them out
newhome
out=$("$DOCTOR" --home-claude "$T/none" --home-codex "$T/none" --home-gemini "$T/none" --repos-root "$T/none" 2>&1)
assert_eq "" "$(printf '%s\n' "$out" | grep retained)" "doctor says nothing when nothing is retained"
mkcopy doc-one 1
mkcopy doc-two 2
mkdir -p "$R/.trash/leftover"
out=$("$DOCTOR" --home-claude "$T/none" --home-codex "$T/none" --home-gemini "$T/none" --repos-root "$T/none" 2>&1)
assert_contains "$out" "retained build copies: 2, " "doctor counts retained copies, not the private trash folder"
assert_contains "$out" "MB (kit-retained list; kit-retained prune --older-than DAYS)" "doctor shows the size and the command"
out=$("$DOCTOR" --fast --home-claude "$T/none" --home-codex "$T/none" --home-gemini "$T/none" --repos-root "$T/none" 2>&1)
assert_eq "" "$(printf '%s\n' "$out" | grep retained)" "doctor --fast does not walk retained copies"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
