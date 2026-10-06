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

# Staging and diff failures must override a successful provider exit. A real
# exported run (so the preflight passes) with git itself faked to fail (rev-parse
# succeeds, so the --attr-source probe passes).
st_src=$(mk_src_repo)
st_home=$(mktmp)
st_run=$(env ROUTING_KIT_HOME="$st_home" bash -c ". \"$EXPORT_SH\"; run_export \"$st_src\" stagefail")
stage_out=$(bash -c '. "$1"; kit_git() { case " $* " in *" rev-parse "*) return 0 ;; esac; return 1; }; run_stage_and_diff "$2"' _ "$EXPORT_SH" "$st_run/wt" 2>&1); stage_code=$?
assert_eq 4 "$stage_code" "staging failure exits 4"
assert_eq "could not stage the build patch" "$stage_out" "staging failure is one line"
diff_out=$(bash -c '. "$1"; kit_git() { case " $* " in *" add "*|*" rev-parse "*) return 0 ;; esac; return 1; }; run_stage_and_diff "$2"' _ "$EXPORT_SH" "$st_run/wt" 2>&1); diff_code=$?
assert_eq 4 "$diff_code" "diff failure exits 4"
assert_contains "$diff_out" "could not read the build diff" "diff failure has one-line error"
if [ -e "$st_run/build.patch" ]; then fail "diff failure leaves no build.patch behind"; else pass; fi

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

# --- ledger_append: Linux (and WSL2, which reports uname as Linux) is a
# supported system now -- it must write the ledger line normally, not
# refuse the way it used to when the whole kit was macOS-only. ---------------
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
home=$(mktmp)
out=$(env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$home" bash -c ". \"$LEDGER_SH\"; ledger_append lane model name 1 2 0" 2>&1)
code=$?
assert_eq 0 "$code" "ledger_append works on a faked Linux uname"
if [ -f "$home/ledger.tsv" ]; then
  pass
else
  fail "ledger_append did not write ledger.tsv on a faked Linux uname"
fi

# --- ledger_append: must still refuse on an unsupported system (native
# Windows, faked here via a MINGW64_NT-shaped uname) instead of silently
# writing the ledger anyway. --------------------------------------------------
winbin=$(mktmp)
cat > "$winbin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0"
EOF
chmod +x "$winbin/uname"
winhome=$(mktmp)
out=$(env PATH="$winbin:$PATH" ROUTING_KIT_HOME="$winhome" bash -c ". \"$LEDGER_SH\"; ledger_append lane model name 1 2 0" 2>&1)
code=$?
assert_eq 2 "$code" "ledger_append refuses on a faked native-Windows uname"
assert_contains "$out" "routing-kit needs macOS, Linux, or WSL2 on Windows" "ledger_append prints the supported-systems message"
if [ -f "$winhome/ledger.tsv" ]; then
  fail "ledger_append wrote ledger.tsv despite the unsupported-system refusal"
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

# === run_stage_and_diff: build.patch ===========================================
# The patch file is the exact diff that was printed, and the printed output is
# the "--- diff ---" line plus that same diff.
src=$(mk_src_repo)
home=$(mktmp)
run=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" patchrun")
echo changed >> "$run/wt/a.txt"
echo brand-new > "$run/wt/new-file.txt"
printed=$(bash -c '. "$1"; run_stage_and_diff "$2"' _ "$EXPORT_SH" "$run/wt"); code=$?
assert_eq 0 "$code" "run_stage_and_diff succeeds on a changed tree"
if [ -f "$run/build.patch" ]; then
  assert_eq "--- diff ---
$(cat "$run/build.patch")" "$printed" "printed output is the header plus build.patch, byte for byte"
  assert_contains "$(cat "$run/build.patch")" "new-file.txt" "build.patch includes a file the build created"
  if git -C "$src" apply --check "$run/build.patch" 2>/dev/null; then pass; else fail "build.patch applies to the source repo"; fi
else
  fail "run_stage_and_diff did not write build.patch next to wt"
fi

# === run_cleanup ===============================================================
# fill_run RUNS_HOME NAME -- a run dir with the bulk dirs and the small files.
fill_run() {
  fr_home="$1"
  fr_run=$(env ROUTING_KIT_HOME="$fr_home" bash -c ". \"$EXPORT_SH\"; run_export \"$2\" fillrun" 2>/dev/null)
  mkdir -p "$fr_run/home" "$fr_run/cfg" "$fr_run/tmp"
  echo x > "$fr_run/home/h.txt"; echo x > "$fr_run/cfg/c.txt"; echo x > "$fr_run/tmp/t.txt"
  echo brief > "$fr_run/brief.md"; echo log > "$fr_run/canaries.log"
  echo '{}' > "$fr_run/claude-output.json"; echo patch > "$fr_run/build.patch"
  echo "$fr_run"
}
cleanup_run() {
  # cleanup_run KIT_HOME RUN_DIR [EXTRA_ENV...] -- runs run_cleanup, echoes its exit code
  cr_home="$1"; cr_run="$2"; shift 2
  env ROUTING_KIT_HOME="$cr_home" "$@" bash -c '. "$1"; run_cleanup "$2"; echo "exit=$?"' _ "$EXPORT_SH" "$cr_run" 2>&1
}

# --- removes the four bulk dirs, keeps the small files ---
src=$(mk_src_repo)
home=$(mktmp)
run=$(fill_run "$home" "$src")
out=$(cleanup_run "$home" "$run")
assert_contains "$out" "exit=0" "run_cleanup exits 0"
left=""
for d in wt home cfg tmp; do [ -e "$run/$d" ] && left="$left $d"; done
assert_eq "" "$left" "run_cleanup removes wt, home, cfg and tmp"
for f in brief.md canaries.log claude-output.json build.patch; do
  if [ -f "$run/$f" ]; then pass; else fail "run_cleanup kept $f"; fi
done
out=$(cleanup_run "$home" "$run")
assert_contains "$out" "exit=0" "run_cleanup on an already-cleaned run dir still exits 0"
out=$(cleanup_run "$home" "$home/runs/does-not-exist")
assert_eq "exit=0" "$out" "run_cleanup on a missing run dir is a quiet no-op"

# --- ROUTING_KIT_KEEP_RUNS=1 keeps everything and says where ---
src=$(mk_src_repo)
home=$(mktmp)
run=$(fill_run "$home" "$src")
out=$(cleanup_run "$home" "$run" ROUTING_KIT_KEEP_RUNS=1)
if [ -d "$run/wt/.git" ] && [ -d "$run/home" ]; then pass; else fail "ROUTING_KIT_KEEP_RUNS=1 kept the copy"; fi
assert_contains "$out" "ROUTING_KIT_KEEP_RUNS=1" "keep note names the variable"
assert_contains "$out" "$run/wt" "keep note says where the copy is"
assert_eq 1 "$(printf '%s\n' "$out" | grep -vc '^exit=')" "keep note is one line"
out=$(cleanup_run "$home" "$run" ROUTING_KIT_KEEP_RUNS=0)
if [ -e "$run/wt" ]; then fail "ROUTING_KIT_KEEP_RUNS=0 still keeps the copy"; else pass; fi

# --- refuses anything that is not a direct child of $KIT_HOME/runs ---
home=$(mktmp)
mkdir -p "$home/runs"
decoy=$(mktmp)
mkdir -p "$decoy/wt" "$decoy/home"
echo precious > "$decoy/wt/keep.txt"; echo precious > "$decoy/home/keep.txt"
out=$(cleanup_run "$home" "$decoy")
assert_contains "$out" "exit=0" "run_cleanup refusing a path still exits 0"
assert_contains "$out" "nothing deleted" "refusal warns on stderr"
if [ -f "$decoy/wt/keep.txt" ] && [ -f "$decoy/home/keep.txt" ]; then pass; else fail "run_cleanup deleted from a dir outside \$KIT_HOME/runs"; fi
# a path that only LOOKS like it is under runs (.. escape)
mkdir -p "$home/other/wt"; echo precious > "$home/other/wt/keep.txt"
out=$(cleanup_run "$home" "$home/runs/../other")
assert_contains "$out" "nothing deleted" "a .. path out of runs is refused"
if [ -f "$home/other/wt/keep.txt" ]; then pass; else fail "dotdot path deleted outside \$KIT_HOME/runs"; fi
# a symlink in runs/ pointing at the decoy
ln -s "$decoy" "$home/runs/link-run"
out=$(cleanup_run "$home" "$home/runs/link-run")
assert_contains "$out" "nothing deleted" "a symlinked run dir is refused"
if [ -f "$decoy/wt/keep.txt" ] && [ -f "$decoy/home/keep.txt" ]; then pass; else fail "run_cleanup followed a symlinked run dir"; fi
# $KIT_HOME/runs itself, and a grandchild of it
mkdir -p "$home/runs/a/b/wt"; echo precious > "$home/runs/a/b/wt/keep.txt"; mkdir -p "$home/runs/wt"; echo precious > "$home/runs/wt/keep.txt"
cleanup_run "$home" "$home/runs" >/dev/null
cleanup_run "$home" "$home/runs/a/b" >/dev/null
if [ -f "$home/runs/wt/keep.txt" ] && [ -f "$home/runs/a/b/wt/keep.txt" ]; then pass; else fail "run_cleanup touched the runs root or a nested dir"; fi
# an empty argument (and a missing one) never deletes anything: run it from a
# cwd that has a wt/ to prove nothing relative is touched either
mkdir -p "$decoy/cwd/wt"; echo precious > "$decoy/cwd/wt/keep.txt"
out=$( cd "$decoy/cwd" && env ROUTING_KIT_HOME="$home" bash -c '. "$1"; run_cleanup ""; echo "exit=$?"; run_cleanup; echo "exit=$?"' _ "$EXPORT_SH" 2>&1)
assert_contains "$out" "exit=0" "run_cleanup with an empty arg exits 0"
assert_contains "$out" "nothing deleted" "run_cleanup with an empty arg warns"
if [ -f "$decoy/cwd/wt/keep.txt" ]; then pass; else fail "run_cleanup with an empty arg deleted something"; fi

# --- read-only dirs inside wt are still removed; symlinks are not followed ---
src=$(mk_src_repo)
home=$(mktmp)
run=$(fill_run "$home" "$src")
outside=$(mktmp)
echo precious > "$outside/keep.txt"
chmod 600 "$outside/keep.txt"
mkdir -p "$run/wt/ro/deep/deeper" "$run/home/ro-home"
echo x > "$run/wt/ro/deep/deeper/f.txt"
echo x > "$run/home/ro-home/f.txt"
ln -s "$outside" "$run/wt/link-out"
ln -s "$outside/keep.txt" "$run/wt/link-file"
chmod 000 "$run/wt/ro/deep/deeper/f.txt"
chmod 555 "$run/wt/ro/deep/deeper"
chmod 500 "$run/wt/ro/deep"
chmod 000 "$run/wt/ro"
chmod 000 "$run/home/ro-home"
chmod 555 "$run/wt/.git"
out=$(cleanup_run "$home" "$run")
assert_contains "$out" "exit=0" "run_cleanup exits 0 with read-only dirs around"
left=""
for d in wt home cfg tmp; do [ -e "$run/$d" ] && left="$left $d"; done
assert_eq "" "$left" "read-only dirs inside wt/home are still removed"
chmod -R u+rwx "$run" 2>/dev/null
if [ -f "$outside/keep.txt" ] && [ "$(cat "$outside/keep.txt")" = precious ]; then pass; else fail "a symlink inside wt led run_cleanup out of the run dir"; fi
if [ -x "$outside/keep.txt" ]; then fail "chmod -R followed a symlink out of the run dir (made the outside file executable)"; else pass; fi
if [ -r "$outside" ] && [ -w "$outside" ]; then pass; else fail "chmod/rm touched the symlink's target dir"; fi

# --- stale sweep: run_export cleans old run dirs, leaves young ones ---
src=$(mk_src_repo)
home=$(mktmp)
old_run=$(fill_run "$home" "$src")
fresh_run=$(fill_run "$home" "$src")
old_nonrun="$home/runs/not-a-run-dir"          # a plain file in runs/ is never touched
echo keepme > "$old_nonrun"
touch -t 202001010000 "$old_run"
touch -t 202001010000 "$old_nonrun"
newrun=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" sweeprun" 2>"$home/sweep-stderr")
assert_eq 0 "$?" "run_export still succeeds with stale dirs around"
left=""
for d in wt home cfg tmp; do [ -e "$old_run/$d" ] && left="$left $d"; done
assert_eq "" "$left" "stale sweep removed the bulk of a run dir older than 24h"
if [ -f "$old_run/build.patch" ] && [ -f "$old_run/brief.md" ]; then pass; else fail "stale sweep removed small files"; fi
if [ -d "$fresh_run/wt/.git" ] && [ -d "$fresh_run/home" ]; then pass; else fail "stale sweep touched a young run dir"; fi
if [ -d "$newrun/wt/.git" ]; then pass; else fail "stale sweep touched the new run's own copy"; fi
if [ -f "$old_nonrun" ]; then pass; else fail "stale sweep removed a plain file"; fi
assert_eq "" "$(cat "$home/sweep-stderr")" "stale sweep is quiet"
# 23 hours old is still young
run23=$(fill_run "$home" "$src")
touch -t "$(date -v-23H +%Y%m%d%H%M 2>/dev/null || date -d '23 hours ago' +%Y%m%d%H%M)" "$run23"
env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" sweeprun2" >/dev/null 2>&1
if [ -d "$run23/wt/.git" ]; then pass; else fail "stale sweep removed a 23-hour-old run dir"; fi
# ROUTING_KIT_KEEP_RUNS=1 keeps old copies too, silently
old2=$(fill_run "$home" "$src")
touch -t 202001010000 "$old2"
env ROUTING_KIT_HOME="$home" ROUTING_KIT_KEEP_RUNS=1 bash -c ". \"$EXPORT_SH\"; run_export \"$src\" sweeprun3" >/dev/null 2>"$home/sweep-stderr2"
if [ -d "$old2/wt/.git" ]; then pass; else fail "ROUTING_KIT_KEEP_RUNS=1 did not stop the stale sweep"; fi
assert_eq "" "$(cat "$home/sweep-stderr2")" "stale sweep under KEEP_RUNS is quiet"

# === review round 1 fixes =====================================================
# --- run_stage_and_diff keeps binary changes (git diff --binary) ---
bsrc=$(mktmp)
git -C "$bsrc" init -q
git -C "$bsrc" config user.email you@example.com
git -C "$bsrc" config user.name "Test User"
printf '\000\001\002binary-original\377\376\000\000' > "$bsrc/blob.bin"
git -C "$bsrc" add blob.bin
git -C "$bsrc" commit -q -m init
home=$(mktmp)
run=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$bsrc\" binrun")
printf '\000\377\200changed-bytes\001\002\003\000' > "$run/wt/blob.bin"
printf '\000\000\377new-binary-file\376\000' > "$run/wt/added.bin"
bash -c '. "$1"; run_stage_and_diff "$2"' _ "$EXPORT_SH" "$run/wt" >/dev/null
fresh=$(mktmp)
git clone -q "$bsrc" "$fresh/c" 2>/dev/null
if git -C "$fresh/c" apply "$run/build.patch" 2>/dev/null \
  && cmp -s "$fresh/c/blob.bin" "$run/wt/blob.bin" && cmp -s "$fresh/c/added.bin" "$run/wt/added.bin"; then
  pass
else
  fail "build.patch must reproduce changed and new binary files byte for byte"
fi

# --- run_export removes its own run dir when it fails after mktemp ---
fail_export() {
  # fail_export KIT_HOME SRC PATTERN [EXTRA_ENV...] -- run_export with a kit_git that fails for PATTERN
  fe_home="$1"; fe_src="$2"; fe_pat="$3"; shift 3
  env ROUTING_KIT_HOME="$fe_home" FAIL_PAT="$fe_pat" "$@" bash -c '
    . "$1"
    eval "real_$(declare -f kit_git)"
    kit_git() { case " $* " in *" $FAIL_PAT "*) return 1 ;; esac; real_kit_git "$@"; }
    run_export "$2" failrun' _ "$EXPORT_SH" "$fe_src" 2>/dev/null
}
for pat in clone "remote remove"; do
  src=$(mk_src_repo)
  home=$(mktmp)
  fail_export "$home" "$src" "$pat" >/dev/null
  code=$?
  assert_eq 2 "$code" "run_export exits 2 when '$pat' fails"
  assert_eq 0 "$(find "$home/runs" -mindepth 1 | wc -l | tr -d ' ')" "a failed run_export ('$pat') leaves no run dir behind"
done
# with ROUTING_KIT_KEEP_RUNS=1 the half-made copy may stay (and the exit code is the same)
src=$(mk_src_repo)
home=$(mktmp)
fail_export "$home" "$src" "remote remove" ROUTING_KIT_KEEP_RUNS=1 >/dev/null
assert_eq 2 "$?" "run_export exits 2 on failure under KEEP_RUNS"
if [ -d "$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)/wt" ]; then pass; else fail "KEEP_RUNS=1 should keep the half-made copy"; fi

# --- stale sweep skips a run whose owner.pid is a live process ---
src=$(mk_src_repo)
home=$(mktmp)
live_run=$(fill_run "$home" "$src")
dead_run=$(fill_run "$home" "$src")
junk_run=$(fill_run "$home" "$src")
sleep 60 &
live_pid=$!
sleep 0 & dead_pid=$!; { wait "$dead_pid"; } 2>/dev/null
echo "$live_pid" > "$live_run/owner.pid"
echo "$dead_pid" > "$dead_run/owner.pid"
echo "not-a-pid" > "$junk_run/owner.pid"
for r in "$live_run" "$dead_run" "$junk_run"; do touch -t 202001010000 "$r"; done
env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" ownerrun" >/dev/null 2>&1
{ kill "$live_pid"; wait "$live_pid"; } 2>/dev/null
if [ -d "$live_run/wt/.git" ] && [ -d "$live_run/home" ]; then pass; else fail "stale sweep deleted a run whose owner.pid is alive"; fi
if [ -e "$dead_run/wt" ]; then fail "stale sweep kept a run whose owner is dead"; else pass; fi
if [ -e "$junk_run/wt" ]; then fail "stale sweep kept a run with a garbage owner.pid"; else pass; fi
# run_claim writes the calling shell's pid
claim_run=$(mktmp)
out=$(bash -c '. "$1"; run_claim "$2"; echo $$' _ "$EXPORT_SH" "$claim_run")
assert_eq "$out" "$(cat "$claim_run/owner.pid")" "run_claim writes the caller's pid to owner.pid"

# === run_export saves a pristine git directory; git runs against it, not wt/.git ===
src=$(mk_src_repo)
home=$(mktmp)
run=$(env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" metarun")
if [ -d "$run/git.pristine" ] && [ -f "$run/git.pristine/HEAD" ] && cmp -s "$run/git.pristine/config" "$run/wt/.git/config"; then pass; else fail "run_export saves a copy of wt/.git as git.pristine"; fi
case "$(cat "$run/git.pristine/config")" in *"$src"*) fail "the pristine config still names the source repo" ;; *) pass ;; esac
# a real copy: no hardlinks shared with wt/.git
shared=$(find "$run/git.pristine" -type f -links +1 | head -1)
assert_eq "" "$shared" "git.pristine shares no hardlinks with wt/.git"
if [ -s "$run/wt-size.kb" ]; then pass; else fail "run_export records wt's size"; fi
# the flags (not env vars, which kit_git's env -i drops) point git at git.pristine
gd=$(bash -c '. "$1"; kit_git --git-dir="$2/git.pristine" --work-tree="$2/wt" -C "$2/wt" rev-parse --absolute-git-dir' _ "$EXPORT_SH" "$run")
assert_eq "$run/git.pristine" "$gd" "kit_git --git-dir/--work-tree resolves to git.pristine, not wt/.git"
# GIT_DIR in the environment is dropped by kit_git (env -i): git would fall back to wt/.git
gd2=$(GIT_DIR="$run/git.pristine" bash -c '. "$1"; kit_git -C "$2/wt" rev-parse --absolute-git-dir' _ "$EXPORT_SH" "$run")
assert_eq "$run/wt/.git" "$gd2" "(why flags are needed) GIT_DIR in the env does not survive kit_git"
# run_cleanup removes git.pristine too, keeps the small files
env ROUTING_KIT_HOME="$home" bash -c ". \"$EXPORT_SH\"; run_cleanup \"$run\"" 2>/dev/null
if [ -e "$run/git.pristine" ] || [ -e "$run/wt" ]; then fail "run_cleanup removes wt and git.pristine"; else pass; fi
if [ -f "$run/wt-size.kb" ]; then pass; else fail "run_cleanup keeps the small files"; fi

# --- a planted filter/fsmonitor in wt/.git/config, a crafted index and a host
# gitattributes never run or leak: run_stage_and_diff ignores wt/.git ---
evil_home=$(mktmp); evil_marks=$(mktmp)
run=$(env ROUTING_KIT_HOME="$evil_home" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" evilrun")
printf '[filter "x"]\n\tclean = touch %s/clean; cat\n[core]\n\tfsmonitor = touch %s/fsmonitor\n' "$evil_marks" "$evil_marks" >> "$run/wt/.git/config"
echo '* filter=x' > "$run/wt/.gitattributes"
echo built > "$run/wt/built.txt"
printed=$(bash -c '. "$1"; run_stage_and_diff "$2"' _ "$EXPORT_SH" "$run/wt" 2>/dev/null); code=$?
assert_eq 0 "$code" "run_stage_and_diff succeeds with a poisoned wt/.git/config"
assert_eq 0 "$(ls -A "$evil_marks" | wc -l | tr -d ' ')" "no planted command ran (found: $(ls "$evil_marks" | tr '\n' ' '))"
assert_contains "$printed" "built.txt" "the diff still has the build's file"
assert_contains "$printed" "filter=x" "the diff still has the planted .gitattributes as plain content"

# --- run_preflight_wt: what makes it refuse ---
preflight() { bash -c '. "$1"; run_preflight_wt "$2"; echo "exit=$?"' _ "$EXPORT_SH" "$1" "${@:2}" 2>&1; }
fresh_run() { env ROUTING_KIT_HOME="$(mktmp)" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" pf"; }
pr=$(fresh_run)
assert_eq "exit=0" "$(preflight "$pr/wt")" "a clean worktree passes the preflight"
ln -s /nonexistent "$pr/wt/dangling-link"; ln -s "$pr/wt/a.txt" "$pr/wt/ok-link"
assert_eq "exit=0" "$(preflight "$pr/wt")" "symlinks inside the worktree are fine"
pf_refuses() { pf_out=$(preflight "$1"); assert_contains "$pf_out" "exit=4" "preflight refuses: $2"; assert_contains "$pf_out" "refusing to stage the build" "preflight says why: $2"; }
pr=$(fresh_run); mkdir -p "$pr/wt/sub/.git"; pf_refuses "$pr/wt" "a nested .git dir"
pr=$(fresh_run); mkdir -p "$pr/wt/sub/.GIT"; pf_refuses "$pr/wt" "a nested .GIT dir"
pr=$(fresh_run); mkdir -p "$pr/wt/sub"; echo "gitdir: /x" > "$pr/wt/sub/.git"; pf_refuses "$pr/wt" "a gitfile"
pr=$(fresh_run); mkfifo "$pr/wt/.gitattributes"; pf_refuses "$pr/wt" "a FIFO"
pr=$(fresh_run); ln "$pr/wt/a.txt" "$pr/wt/linked.txt"; pf_refuses "$pr/wt" "a hard-linked file"
pr=$(fresh_run); mkdir "$pr/wt/locked"; echo x > "$pr/wt/locked/f"; chmod 000 "$pr/wt/locked"; pf_refuses "$pr/wt" "an unreadable dir (fails closed)"; chmod 755 "$pr/wt/locked"
pr=$(fresh_run); pf_out=$(preflight "$pr/nonexistent"); assert_contains "$pf_out" "exit=4" "preflight refuses a missing worktree"
# growth cap: 4 MB over the export size with a 1 MB cap is refused; the default cap allows it
pr=$(fresh_run); dd if=/dev/zero of="$pr/wt/big.bin" bs=1048576 count=4 2>/dev/null
assert_eq "exit=0" "$(preflight "$pr/wt")" "4 MB of growth is fine under the default cap"
pf_out=$(ROUTING_KIT_MAX_GROWTH_MB=1 preflight "$pr/wt"); assert_contains "$pf_out" "exit=4" "preflight refuses growth past ROUTING_KIT_MAX_GROWTH_MB"
assert_contains "$pf_out" "grew by more than 1 MB" "growth refusal names the cap"
# a pristine-less run (or a fifo) never reaches git: no hang with a FIFO .gitignore either
pr=$(fresh_run); rm -f "$pr/wt/.gitignore"; mkfifo "$pr/wt/.gitignore"
( bash -c '. "$1"; run_stage_and_diff "$2"; echo "exit=$?"' _ "$EXPORT_SH" "$pr/wt" >"$pr/out" 2>&1 ) &
fp=$!; i=0
while kill -0 "$fp" 2>/dev/null && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
if kill -0 "$fp" 2>/dev/null; then { pkill -KILL -P "$fp"; kill -KILL "$fp"; wait "$fp"; } 2>/dev/null; fail "run_stage_and_diff hung on a FIFO .gitignore"
else { wait "$fp"; } 2>/dev/null; assert_contains "$(cat "$pr/out")" "exit=4" "run_stage_and_diff refuses a FIFO .gitignore without hanging"; fi

# --- a git without --attr-source (< 2.40) still works, with one extra rule:
# no symlink to a directory in the worktree ---
# old_git_build WT -- run_build_patch with a kit_git that rejects --attr-source,
# like a git older than 2.40; prints "exit=N" after any message
old_git_build() {
  FAIL_PAT="--attr-source=HEAD" bash -c '. "$1"; eval "real_$(declare -f kit_git)"; kit_git() { case " $* " in *" $FAIL_PAT "*) return 1 ;; esac; real_kit_git "$@"; }; run_build_patch "$2"; echo "exit=$?"' _ "$EXPORT_SH" "$1" 2>&1
}
src=$(mk_src_repo)
og=$(env ROUTING_KIT_HOME="$(mktmp)" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" oldgit")
echo oldgit-edit > "$og/wt/new.txt"
out=$(old_git_build "$og/wt")
assert_eq "exit=0" "$out" "an old git (no --attr-source) still builds a normal tree"
assert_contains "$(cat "$og/build.patch")" "new.txt" "the old-git patch has the build's file"
og=$(env ROUTING_KIT_HOME="$(mktmp)" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" oldgit2")
ext=$(mktmp)
ln -s "$ext" "$og/wt/dirlink"
out=$(old_git_build "$og/wt")
assert_contains "$out" "exit=4" "an old git refuses a symlink to a directory"
assert_contains "$out" "symlink to a directory" "the refusal says why"
assert_contains "$out" "older than 2.40" "the refusal says it is the old git"
if [ -e "$og/build.patch" ]; then fail "an old-git refusal left a build.patch"; else pass; fi
og=$(env ROUTING_KIT_HOME="$(mktmp)" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" oldgit3")
ln -s a.txt "$og/wt/filelink"; ln -s /nonexistent "$og/wt/danglinglink"
out=$(old_git_build "$og/wt")
assert_eq "exit=0" "$out" "an old git allows symlinks to files (and dangling ones)"
og=$(env ROUTING_KIT_HOME="$(mktmp)" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" oldgit4")
mkdir "$og/wt/sub"; ln -s "$ext" "$og/wt/sub/deep-dirlink"; ln -s "$og/wt/sub" "$og/wt/chain-to-dir"
rm -f "$og/wt/sub/deep-dirlink"; mkdir "$og/wt/odd
name"; ln -s "$ext" "$og/wt/odd
name/link"
out=$(old_git_build "$og/wt")
assert_contains "$out" "exit=4" "an old git finds a dir symlink under a newline-named dir (fail closed on odd names)"
# a new git allows the same dir symlink (attributes come from HEAD only)
og=$(env ROUTING_KIT_HOME="$(mktmp)" bash -c ". \"$EXPORT_SH\"; run_export \"$src\" newgit")
ln -s "$ext" "$og/wt/dirlink"
out=$(bash -c '. "$1"; run_build_patch "$2"; echo "exit=$?"' _ "$EXPORT_SH" "$og/wt" 2>&1)
assert_eq "exit=0" "$out" "a git with --attr-source allows symlinks to directories"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
