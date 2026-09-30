#!/bin/bash
. "$(dirname "$0")/lib.sh"
LIB_DIR="$(cd "$(dirname "$0")/.." && pwd -P)/plugins/routing-kit/lib"
EXPORT_SH="$LIB_DIR/export.sh"
LEDGER_SH="$LIB_DIR/ledger.sh"
SCAN_SH="$LIB_DIR/secret-scan.sh"

mk_src_repo() {
  # a small committed repo with a gitignored, untracked file left dirty-free
  d=$(mktmp)
  git -C "$d" init -q
  git -C "$d" config user.email you@example.com
  git -C "$d" config user.name "Test User"
  echo hello > "$d/a.txt"
  echo 'ignored.local' > "$d/.gitignore"
  git -C "$d" add a.txt .gitignore
  git -C "$d" commit -q -m init
  echo "secret-local-content" > "$d/ignored.local"
  echo "$d"
}

# --- run_export: dirty repo -> exit 2 ---
src=$(mk_src_repo)
echo more >> "$src/a.txt"
home=$(mktmp)
assert_exit 2 "dirty repo refused" -- env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" myrun >/dev/null"

# --- run_export: repo with no HEAD (no commits) -> exit 2 ---
src_empty=$(mktmp)
git -C "$src_empty" init -q
home=$(mktmp)
assert_exit 2 "repo with no HEAD refused" -- env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src_empty\" myrun >/dev/null"

# --- run_export: clean repo -> wt exists, HEAD matches, no remote, no .git file, no gitignored file ---
src=$(mk_src_repo)
src_head=$(git -C "$src" rev-parse HEAD)
home=$(mktmp)
out=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" \"My Run\"")
code=$?
assert_eq 0 "$code" "clean repo export succeeds"

if [ -d "$out/wt" ]; then
  pass
else
  fail "wt/ was not created under the run dir ($out)"
fi

wt_head=$(git -C "$out/wt" rev-parse HEAD 2>/dev/null)
assert_eq "$src_head" "$wt_head" "wt HEAD equals source HEAD"

wt_remote=$(git -C "$out/wt" remote)
assert_eq "" "$wt_remote" "wt has no remotes"

if [ -d "$out/wt/.git" ]; then
  pass
else
  fail "wt/.git is not a directory"
fi

if [ -e "$out/wt/ignored.local" ]; then
  fail "gitignored source file leaked into wt"
else
  pass
fi

# --- ledger_append: two appends write one header ---
home=$(mktmp)
ledger_out=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$LEDGER_SH\"; ledger_append lane-a model-a run-a 10 20 0; ledger_append lane-b model-b run-b - - 1; cat \"$home/ledger.tsv\"")
expected_header=$(printf 'date\tlane\tmodel\tname\tin\tout\texit')
header_count=$(printf '%s\n' "$ledger_out" | grep -c -F "$expected_header")
assert_eq 1 "$header_count" "ledger header written exactly once across two appends"
line_count=$(printf '%s\n' "$ledger_out" | wc -l | tr -d ' ')
assert_eq 3 "$line_count" "ledger has header plus two data lines"
legacy_home=$(mktmp)
printf 'date\tlane\tmodel\tname\tin\tout\texit\n2026-01-01\tlocked-build\told\told-run\t1\t2\t0\n' > "$legacy_home/ledger.tsv"
env ROUTING_KIT_HOME="$legacy_home" bash -c '. "$1"; ledger_append locked-build custom new-run 3 4 0 kimi 0.25' _ "$LEDGER_SH"
assert_eq 'provider' "$(head -n 1 "$legacy_home/ledger.tsv" | cut -f8)" "old ledger header gains provider column"
assert_eq 'kimi' "$(tail -n 1 "$legacy_home/ledger.tsv" | cut -f8)" "new rows carry provider after old rows"

# Price calculation is independent of the jailed provider run.
model_file=$(mktmp)/models.json
printf '{"pricing":{"sample":{"price_in_per_mtok":2,"price_out_per_mtok":4}}}\n' > "$model_file"
cost=$(bash -c '. "$1"; ledger_model_cost "$2" sample 1000000 500000' _ "$LEDGER_SH" "$model_file")
assert_eq 4.000000 "$cost" "model cost uses separate input and output prices (fixed decimals)"
assert_eq "" "$(bash -c '. "$1"; ledger_model_cost "$2" sample - 500000' _ "$LEDGER_SH" "$model_file")" "unknown count gives unknown cost"
assert_eq "" "$(bash -c '. "$1"; ledger_model_cost "$2" missing 100 200' _ "$LEDGER_SH" "$model_file")" "unknown price gives unknown cost"

# Staging and diff failures must override a successful provider exit.
stage_out=$(bash -c '. "$1"; kit_git() { return 1; }; run_stage_and_diff "$2"' _ "$EXPORT_SH" "$home" 2>&1); stage_code=$?
assert_eq 4 "$stage_code" "staging failure exits 4"
assert_eq "could not stage the build patch" "$stage_out" "staging failure is one line"
diff_out=$(bash -c '. "$1"; kit_git() { [ "$3" = add ]; }; run_stage_and_diff "$2"' _ "$EXPORT_SH" "$home" 2>&1); diff_code=$?
assert_eq 4 "$diff_code" "diff failure exits 4"
assert_contains "$diff_out" "could not read the build diff" "diff failure has one-line error"

# --- secret_scan: .env file -> 5 ---
d=$(mktmp)
printf 'SOME_VAR=plain-value\n' > "$d/.env"
out=$(bash -c ". \"$SCAN_SH\"; secret_scan \"$d\"" 2>&1)
code=$?
assert_eq 5 "$code" "secret_scan flags a .env file"

# --- secret_scan: password assignment -> 5 ---
# Built via adjacent-quote concatenation at runtime: both the key ("pass"
# next to "word") and the value ("hunter" next to "22"). Even the printf
# template "password = ..." followed by 6+ non-space chars would itself
# match secret_scan's own pattern if written literally, so this source
# file must never contain "password" immediately followed by "=" either
# (secret_scan would flag this very file when scanning the repo, e.g.
# during the real-data run).
d=$(mktmp)
pw_key="pass""word"
pw="hunter""22"
printf '%s = "%s"\n' "$pw_key" "$pw" > "$d/config.txt"
out=$(bash -c ". \"$SCAN_SH\"; secret_scan \"$d\"" 2>&1)
code=$?
assert_eq 5 "$code" "secret_scan flags a password assignment"
case "$out" in
  *"$pw"*) fail "secret_scan printed the password value" ;;
  *) pass ;;
esac

# --- secret_scan: clean dir -> 0 ---
d=$(mktmp)
printf 'hello world, nothing secret here\n' > "$d/clean.txt"
assert_exit 0 "secret_scan passes on a clean dir" -- bash -c ". \"$SCAN_SH\"; secret_scan \"$d\""

# --- secret_scan: a brief file holding a key -> 5, and the key never leaks ---
# Built via adjacent-quote concatenation at runtime so the fixture secret
# never appears as a contiguous token in this source file (privacy-check
# would otherwise flag its own test fixtures).
d=$(mktmp)
k="sk-""ant-api03-$(printf 'A%.0s' {1..24})"
printf 'notes\n\nkey: %s\n' "$k" > "$d/brief.md"
out=$(bash -c ". \"$SCAN_SH\"; secret_scan \"$d\"" 2>&1)
code=$?
assert_eq 5 "$code" "secret_scan flags a key inside a brief file"
case "$out" in
  *"$k"*) fail "secret_scan printed the key value" ;;
  *) pass ;;
esac

# --- run_export: no clone metadata (reflogs / FETCH_HEAD / packed-refs) may
# name the source -- git writes a "clone: from <url>" reflog line, and gives
# it the *local machine's* committer identity (name + email from git config),
# not anything from the source repo, so this can leak real identity too, not
# just a path ------------------------------------------------------------------
src=$(mk_src_repo)
home=$(mktmp)
out=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" leakcheck")
wt="$out/wt"
if [ -e "$wt/.git/logs" ]; then
  fail "wt/.git/logs still exists after export (its reflog can name the source and the local identity)"
else
  pass
fi
if [ -e "$wt/.git/FETCH_HEAD" ]; then
  fail "wt/.git/FETCH_HEAD still exists after export"
else
  pass
fi
if [ -f "$wt/.git/packed-refs" ] && grep -q "refs/remotes" "$wt/.git/packed-refs"; then
  fail "wt/.git/packed-refs still names a remote"
else
  pass
fi
if grep -rIl "$src" "$wt/.git" >/dev/null 2>&1; then
  fail "something under wt/.git still names the source repo's path"
else
  pass
fi

# --- secret_scan: a nonexistent root must refuse (nonzero), never report
# "clean" just because there was nothing to walk ------------------------------
missing_root="$(mktmp)/does-not-exist-$$"
out=$(bash -c ". \"$SCAN_SH\"; secret_scan \"$missing_root\"" 2>&1)
code=$?
if [ "$code" -eq 0 ]; then
  fail "secret_scan returned 0 (clean) for a nonexistent path -- fails open"
else
  pass
fi

# --- secret_scan: a file it cannot read must also refuse, not be silently
# skipped as if it were clean --------------------------------------------------
d=$(mktmp)
k="sk-""ant-api03-$(printf 'B%.0s' {1..24})"
printf 'key: %s\n' "$k" > "$d/unreadable.txt"
chmod 000 "$d/unreadable.txt"
out=$(bash -c ". \"$SCAN_SH\"; secret_scan \"$d\"" 2>&1)
code=$?
chmod 600 "$d/unreadable.txt"
if [ "$code" -eq 0 ]; then
  fail "secret_scan returned 0 (clean) for a directory containing an unreadable file -- fails open"
else
  pass
fi

# --- ledger_append: must refuse on non-macOS instead of silently writing the
# ledger anyway (every routing-kit entry point needs this guard) --------------
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
home=$(mktmp)
out=$(env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$home" bash -c ". \"$LEDGER_SH\"; ledger_append lane model name 1 2 0" 2>&1)
code=$?
assert_eq 2 "$code" "ledger_append refuses on non-macOS"
assert_contains "$out" "routing-kit is macOS-only" "ledger_append prints the macOS-only message"
if [ -f "$home/ledger.tsv" ]; then
  fail "ledger_append wrote ledger.tsv despite the non-macOS refusal"
else
  pass
fi

# --- ledger_append: a tab, newline or CR inside a field must never forge
# extra rows or columns in the TSV -- it gets replaced with a space --------
home=$(mktmp)
forged_name=$(printf 'job\nforged\trow')
env ROUTING_KIT_HOME="$home" bash -c ". \"$LEDGER_SH\"; ledger_append lane-a model-a \"\$1\" 1 2 0" _ "$forged_name" >/dev/null 2>&1
line_count=$(wc -l < "$home/ledger.tsv" | tr -d ' ')
assert_eq 2 "$line_count" "a forged newline/tab in a field doesn't add extra ledger rows"
field_count=$(sed -n '2p' "$home/ledger.tsv" | awk -F'\t' '{print NF}')
assert_eq 9 "$field_count" "a forged tab in a field doesn't add extra ledger columns"
case "$(cat "$home/ledger.tsv")" in
  *"forged"*"row"*) pass ;;
  *) fail "the field's own content (with tab/newline replaced by a space) should still be visible" ;;
esac


# --- ledger_append / run_export: must not clobber a caller's variables of
# the same name (name, model, repo, lane) when called un-subshelled in the
# current shell -- every variable the functions assign must be `local` -----
name=keep
model=keep
repo=keep
lane=keep
home=$(mktmp)
src=$(mk_src_repo)
export ROUTING_KIT_HOME="$home"
. "$LEDGER_SH"
. "$EXPORT_SH"
ledger_append lane-x model-x run-x 1 2 0 >/dev/null
run_export "$src" myrun >/dev/null
unset ROUTING_KIT_HOME
assert_eq keep "$name" "ledger_append/run_export leave caller's \$name untouched"
assert_eq keep "$model" "ledger_append/run_export leave caller's \$model untouched"
assert_eq keep "$repo" "ledger_append/run_export leave caller's \$repo untouched"
assert_eq keep "$lane" "ledger_append/run_export leave caller's \$lane untouched"

# --- run_export: fresh, exclusive run dirs (lockdown fix wave 1, item 4) ---
# Two runs with the same name on the same day must never share a run dir:
# a marker planted in the first run's home must not be visible from the
# second, and gate-port must not carry over.
src=$(mk_src_repo)
home=$(mktmp)
run1=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" samename")
mkdir -p "$run1/home"
printf 'first-run-marker\n' > "$run1/home/marker"
printf '54321\n' > "$run1/gate-port"

run2=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" samename")

if [ "$run1" = "$run2" ]; then
  fail "two run_export calls with the same name reused the same run dir"
else
  pass
fi
if [ -e "$run2/home/marker" ]; then
  fail "the second run's home can see the first run's marker"
else
  pass
fi
if [ -e "$run2/gate-port" ]; then
  fail "the second run inherited the first run's gate-port file"
else
  pass
fi

# --- run_export: clone isolation from host git config (item 5) -------------
# A "global" gitconfig pointing core.hooksPath at a hook that plants a
# marker outside the clone must never fire during run_export's clone --
# kit_git forces GIT_CONFIG_GLOBAL=/dev/null and GIT_CONFIG_NOSYSTEM=1
# regardless of $HOME, so this hook must never even be consulted.
src2=$(mk_src_repo)
fake_global_dir=$(mktmp)
fake_hooks_dir=$(mktmp)
marker_outside="$fake_global_dir/outside-marker"
cat > "$fake_hooks_dir/post-checkout" <<EOF
#!/bin/sh
echo planted > "$marker_outside"
EOF
chmod +x "$fake_hooks_dir/post-checkout"
cat > "$fake_global_dir/gitconfig" <<EOF
[core]
	hooksPath = $fake_hooks_dir
EOF
home2=$(mktmp)
env ROUTING_KIT_HOME="$home2" HOME="$fake_global_dir" GIT_CONFIG_GLOBAL="$fake_global_dir/gitconfig" \
  bash -c ". \"$EXPORT_SH\"; run_export \"$src2\" hookrun" >/dev/null
if [ -e "$marker_outside" ]; then
  fail "run_export's clone ran the host's core.hooksPath post-checkout hook"
else
  pass
fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
