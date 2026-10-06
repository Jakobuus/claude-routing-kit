#!/bin/bash
. "$(dirname "$0")/lib.sh"
BIN="$(cd "$(dirname "$0")/.." && pwd -P)/plugins/routing-kit/bin/kit-codex-build"

mk_src_repo() {
  d=$(mktmp)
  git -C "$d" init -q
  git -C "$d" config user.email you@example.com
  git -C "$d" config user.name "Test User"
  echo hello > "$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" commit -q -m init
  echo "$d"
}

mk_brief() {
  d=$(mktmp)
  printf 'create hello.txt containing hi\n' > "$d/brief.md"
  echo "$d/brief.md"
}

# --- a fake codex on PATH: logs its argv, reads (and discards) the brief on
# stdin, then makes a small change in the -C directory so the diff isn't
# empty. -----------------------------------------------------------------
mk_fake_codex_bin() {
  argv_log="$1"
  bindir=$(mktmp)
  cat > "$bindir/codex" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$argv_log"
cat >/dev/null
dir=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then dir="\$a"; fi
  prev="\$a"
done
[ -n "\$dir" ] && echo hi > "\$dir/hello.txt"
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

# --- a fake codex that makes its change, then wrecks the exported tree's
# .git directory so a later `git add`/`git diff` in it fails. -------------
mk_fake_codex_bin_breaks_git() {
  bindir=$(mktmp)
  cat > "$bindir/codex" <<'EOF'
#!/bin/bash
cat >/dev/null
dir=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then dir="$a"; fi
  prev="$a"
done
[ -n "$dir" ] && echo hi > "$dir/hello.txt"
[ -n "$dir" ] && chmod 000 "$dir/.git"
# git now runs against the pristine copy beside wt, not wt/.git: break that
# too (a real build can't reach it; this simulates any failing git step)
[ -n "$dir" ] && chmod 000 "$dir/../git.pristine"
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

# --- a fake codex that, on invocation, first overwrites some OTHER file
# (the original brief, named via $2) with tamper_content, then captures
# whatever it actually receives on stdin into stdin_capture. If the script
# under test still opens the original brief for the exec's stdin (instead
# of a snapshot copy made earlier), this fake's own overwrite -- happening
# before it reads its stdin -- would already have landed in that same
# file, and the capture would show the tampered bytes instead of the
# pre-tamper ones. ---------------------------------------------------------
mk_fake_codex_bin_toctou() {
  stdin_capture="$1"
  tamper_path="$2"
  tamper_content="$3"
  bindir=$(mktmp)
  cat > "$bindir/codex" <<EOF
#!/bin/bash
printf '%s' "$tamper_content" > "$tamper_path"
cat > "$stdin_capture"
dir=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then dir="\$a"; fi
  prev="\$a"
done
[ -n "\$dir" ] && echo hi > "\$dir/hello.txt"
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

# --- dirty repo -> 2 ---
src=$(mk_src_repo)
echo more >> "$src/a.txt"
brief=$(mk_brief)
home=$(mktmp)
argv_log=$(mktmp)/argv.log
fakebin=$(mk_fake_codex_bin "$argv_log")
assert_exit 2 "dirty repo refused" -- env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name myrun --brief "$brief"

# --- codex missing -> 3, with an install hint ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
emptybin=$(mktmp)
out=$(env PATH="$emptybin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name myrun --brief "$brief" 2>&1)
code=$?
assert_eq 3 "$code" "missing codex exits 3"
assert_contains "$out" "codex login" "missing-codex message mentions login"

# --- successful run: fake codex gets -m gpt-6-sol -s workspace-write, never
# the forbidden bypass flag; diff and run dir are printed; ledger gets one
# line. ---------------------------------------------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
argv_log=$(mktmp)/argv.log
: > "$argv_log"
fakebin=$(mk_fake_codex_bin "$argv_log")
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name myrun --brief "$brief")
code=$?
assert_eq 0 "$code" "successful codex build exits 0"
assert_contains "$out" "hello.txt" "diff shows the new file"
assert_contains "$out" "run dir:" "run dir is printed"

argv=$(cat "$argv_log")
assert_contains "$argv" "-m gpt-6-sol" "fake codex received the default build model"
assert_contains "$argv" "-s workspace-write" "fake codex received the sandbox flag"
case "$argv" in
  *"--dangerously-bypass-approvals-and-sandbox"*)
    fail "forbidden flag reached codex" ;;
  *) pass ;;
esac

ledger="$home/ledger.tsv"
if [ -f "$ledger" ]; then
  lines=$(grep -c $'\tcodex\t' "$ledger")
  assert_eq 1 "$lines" "ledger has exactly one codex line"
else
  fail "ledger.tsv was not created"
fi

# --- explicit --model overrides the default ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
argv_log=$(mktmp)/argv.log
: > "$argv_log"
fakebin=$(mk_fake_codex_bin "$argv_log")
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name myrun --brief "$brief" --model gpt-6-luna >/dev/null
assert_contains "$(cat "$argv_log")" "-m gpt-6-luna" "explicit --model is passed through"

# --- P1: a secret in the brief refuses the run. It's caught by the
# original-path scan (content rules apply regardless of filename), which
# runs before anything is copied anywhere. --------------------------------
src=$(mk_src_repo)
d=$(mktmp)
k="sk-""ant-api03-$(printf 'A%.0s' {1..24})"
printf 'notes\n\nkey: %s\n' "$k" > "$d/brief.md"
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name secrun --brief "$d/brief.md" 2>&1)
code=$?
assert_eq 5 "$code" "secret in the brief refuses the run"

# --- finding 4: the secret-scan refusal above still writes one ledger line.
# Checked right here, against secrun's own $home, before any other run
# below gets a fresh home of its own -- reusing $home for a later run would
# make this assertion inspect that later run's ledger instead, and a real
# regression that drops the ledger write on exit 5 would slip past it. -----
ledger="$home/ledger.tsv"
if [ -f "$ledger" ]; then
  lines=$(grep -c $'\tcodex\t' "$ledger")
  assert_eq 1 "$lines" "secret-scan refusal still writes exactly one ledger line"
else
  fail "ledger.tsv was not created for the secret-scan refusal"
fi

# --- P1: on a clean run, the run dir still holds a brief snapshot whose
# content matches the original exactly -- that snapshot, not a fresh
# re-read of the original, is what a passing scan goes on to send. Uses its
# own $snap_home so it can't be confused with secrun's ledger above. -------
src=$(mk_src_repo)
brief=$(mk_brief)
snap_home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$snap_home" \
  "$BIN" --repo "$src" --name snaprun --brief "$brief" >/dev/null 2>&1
run_dir=$(find "$snap_home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -n "$run_dir" ] && [ -f "$run_dir/brief.md" ] && diff -q "$brief" "$run_dir/brief.md" >/dev/null 2>&1; then
  pass
else
  fail "no matching brief snapshot was left in the run dir for a clean run"
fi

# --- re-review2 P1: codex must receive the frozen snapshot bytes, not a
# live read of the original brief. A fake codex tampers the original brief
# file (as another process might, in the gap between the snapshot being
# taken and codex being launched) before reading its own stdin, then
# records exactly what it received. If the script fed codex "$BRIEF"
# directly instead of the snapshot, codex's own tamper write -- landing in
# the same file its stdin is reading from -- would show up in the capture. -
src=$(mk_src_repo)
d=$(mktmp)
printf 'ORIGINAL-MARKER\n' > "$d/brief.md"
toctou_home=$(mktmp)
stdin_capture=$(mktmp)/codex-stdin.txt
fakebin=$(mk_fake_codex_bin_toctou "$stdin_capture" "$d/brief.md" 'TAMPERED-MARKER
')
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$toctou_home" \
  "$BIN" --repo "$src" --name toctourun --brief "$d/brief.md" >/dev/null 2>&1
if [ -f "$stdin_capture" ] && grep -q "ORIGINAL-MARKER" "$stdin_capture" \
  && ! grep -q "TAMPERED-MARKER" "$stdin_capture"; then
  pass
else
  fail "codex must receive the frozen snapshot, not a live re-read of a tampered original brief"
fi

# --- finding 4: missing-codex (an early preflight failure) also logs one
# ledger line. ----------------------------------------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
emptybin=$(mktmp)
env PATH="$emptybin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name myrun --brief "$brief" >/dev/null 2>&1
if [ -f "$home/ledger.tsv" ]; then
  lines=$(grep -c $'\tcodex\t' "$home/ledger.tsv")
  assert_eq 1 "$lines" "missing-codex preflight failure still writes exactly one ledger line"
else
  fail "ledger.tsv was not created for the missing-codex failure"
fi

# --- finding 2/3: a git failure after codex succeeds must not report success ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin_breaks_git)
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name gitfailrun --brief "$brief" 2>&1)
code=$?
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -n "$run_dir" ] && chmod -R 755 "$run_dir/wt/.git" "$run_dir/git.pristine" 2>/dev/null
if [ "$code" -ne 0 ]; then
  pass
else
  fail "a git add/diff failure after codex succeeded must not exit 0"
fi
assert_eq 4 "$code" "a git failure after codex succeeded exits 4"
# ... and the exported tree and pristine .git (even with 000 modes) are deleted anyway.
if [ -n "$run_dir" ] && [ ! -e "$run_dir/wt" ] && [ ! -e "$run_dir/git.pristine" ]; then
  pass
else
  fail "the repo copy was not deleted after a git failure"
fi

# --- finding 5: a --name or --model with a tab/newline/CR is refused before
# anything is logged, so it can never forge extra ledger rows or columns. -----
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
bad_name=$'job\nforged\trow'
assert_exit 2 "a --name with an embedded newline/tab is refused" -- env ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name "$bad_name" --brief "$brief"
if [ -f "$home/ledger.tsv" ]; then
  fail "a rejected --name must never reach the ledger"
else
  pass
fi

home=$(mktmp)
assert_exit 2 "a --model with an embedded tab is refused" -- env ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name okname --brief "$brief" --model $'bad\tmodel'
if [ -f "$home/ledger.tsv" ]; then
  fail "a rejected --model must never reach the ledger"
else
  pass
fi

# --- re-review P1: a filename-only secret rule (.env) must still fire even
# though the brief gets snapshotted to a fixed "brief.md" name. A rename
# without also checking the original name would let a mislabeled secret
# file through. ---------------------------------------------------------
src=$(mk_src_repo)
d=$(mktmp)
printf 'VENDOR_TOKEN=opaque-value\n' > "$d/.env"
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name envrun --brief "$d/.env" >/tmp/rk-test-codex-env-out.$$ 2>&1
code=$?
rm -f /tmp/rk-test-codex-env-out.$$
if [ "$code" -eq 5 ]; then
  pass
else
  fail "a .env-named brief must be refused by the filename rule (got exit $code)"
fi

# --- re-review P2: a ledger write failure (KIT_HOME can't be created) must
# never mask the real exit code. The trap has to isolate ledger_append's
# own kit_die/exit, or a failed ledger write for a missing-codex run would
# be reported as exit 2 instead of 3. -------------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
emptybin=$(mktmp)
badhome="/dev/null/rk-review-$$"
out=$(env PATH="$emptybin:/usr/bin:/bin" ROUTING_KIT_HOME="$badhome" \
  "$BIN" --repo "$src" --name myrun --brief "$brief" 2>&1)
code=$?
assert_eq 3 "$code" "a ledger write failure must not mask the real (missing-codex) exit code"
assert_contains "$out" "codex login" "the missing-codex message still comes through"

# --- lockdown fix wave 1, item 25: a fake `cp` earlier on PATH that plants a
# secret in the brief snapshot must be caught by the SECOND secret_scan
# (the one over the run dir's brief.md), not just the first (over the
# original --brief path). Every secret in the ORIGINAL file is already
# caught by the first scan, so deleting the second scan would still pass a
# test that only ever put the secret in the original -- this test puts it
# in the snapshot instead, after the copy, so only the second scan can see
# it. ---------------------------------------------------------------------
mk_fake_cp_bin_plants_secret() {
  bindir=$(mktmp)
  cat > "$bindir/cp" <<'EOF'
#!/bin/bash
/bin/cp "$@"
dest=""
for a in "$@"; do dest="$a"; done
printf 'sk-''ant-api03-%s\n' "AAAAAAAAAAAAAAAAAAAAAAAA" >> "$dest"
EOF
  chmod +x "$bindir/cp"
  echo "$bindir"
}
src=$(mk_src_repo)
brief=$(mk_brief)
cphome=$(mktmp)
fakecpbin=$(mk_fake_cp_bin_plants_secret)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
out=$(env PATH="$fakecpbin:$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$cphome" \
  "$BIN" --repo "$src" --name cprun --brief "$brief" 2>&1)
code=$?
assert_eq 5 "$code" "a secret planted into the snapshot (after the original-file scan) is still caught"
run_dir=$(find "$cphome/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -n "$run_dir" ] && [ -f "$run_dir/secret-scan.txt" ] && [ -s "$run_dir/secret-scan.txt" ]; then
  pass
else
  fail "the second secret scan (over the run dir's snapshot) did not run or found nothing"
fi

# --- item 25: the refusal above writes a ledger line whose exit COLUMN is
# 5, not just some line mentioning "codex" (a bug that always logged exit
# 0, or blank, would still pass a line-count-only check). -------------------
ledger="$cphome/ledger.tsv"
if [ -f "$ledger" ]; then
  ledger_line=$(grep $'\tcodex\t' "$ledger")
  ledger_exit=$(printf '%s\n' "$ledger_line" | cut -f7)
  assert_eq 5 "$ledger_exit" "the snapshot-secret refusal's ledger line has exit column 5"
else
  fail "ledger.tsv was not created for the snapshot-secret refusal"
fi

# Trusted account: contact details pass, credentials still fail.
src=$(mk_src_repo); brief=$(mk_brief); home=$(mktmp); fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
printf 'write for someone''@example.org under /Us''ers/example/project\n' >> "$brief"
assert_exit 0 "contact details pass Codex credential scan" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$BIN" --repo "$src" --name contact --brief "$brief"
printf 'token sk-''abcdefgh1234\n' >> "$brief"
assert_exit 5 "API key fails Codex credential scan" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$(mktmp)" "$BIN" --repo "$src" --name secret --brief "$brief"

authbin=$(mktmp)
printf '#!/bin/bash\necho "not logged in"\nexit 1\n' > "$authbin/codex"; chmod +x "$authbin/codex"
brief=$(mk_brief)
out=$(env PATH="$authbin:/usr/bin:/bin" ROUTING_KIT_HOME="$(mktmp)" "$BIN" --repo "$src" --name auth --brief "$brief" 2>&1); code=$?
assert_eq 3 "$code" "Codex login failure exits 3"
assert_contains "$out" "codex login" "Codex login failure gives command"
printf '#!/bin/bash\necho "provider overloaded"\nexit 1\n' > "$authbin/codex"; chmod +x "$authbin/codex"
assert_exit 4 "Codex provider failure exits 4" -- env PATH="$authbin:/usr/bin:/bin" ROUTING_KIT_HOME="$(mktmp)" "$BIN" --repo "$src" --name provider --brief "$brief"

# --- Linux (and WSL2, which reports uname as Linux) is a supported system
# now: a faked Linux uname must run the whole build normally, not refuse
# the way it used to when the kit was macOS-only. --------------------------
fakeuname=$(mktmp)
cat > "$fakeuname/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakeuname/uname"
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
assert_exit 0 "codex build runs on a faked Linux uname" -- env PATH="$fakeuname:$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name linuxrun --brief "$brief"

# Native Windows (no WSL) is not supported: a MINGW64_NT-shaped uname
# refuses with the supported-systems message.
winbin=$(mktmp)
cat > "$winbin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0"
EOF
chmod +x "$winbin/uname"
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
out=$(env PATH="$winbin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$BIN" --repo "$src" --name winrun --brief "$brief" 2>&1)
code=$?
assert_eq 2 "$code" "codex build refuses on a faked native-Windows uname"
assert_contains "$out" "routing-kit needs macOS, Linux, or WSL2 on Windows" "codex build prints the supported-systems message on native Windows"

# --- a missing jq exits 3 with an install hint, not a masked "invalid
# models file" (exit 2) -- KIT_TEST_NO_JQ forces "not found" the way a
# genuinely jq-less host would resolve, since this dev Mac always has
# /usr/bin/jq for real. -------------------------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
out=$(env KIT_TEST_NO_JQ=1 PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name nojqrun --brief "$brief" 2>&1)
code=$?
assert_eq 3 "$code" "codex build exits 3 when jq is missing"
assert_contains "$out" "install jq" "codex build gives the install-jq hint, not a generic models-file error"

# --- a missing python3 exits 3 with an install hint, not a false
# "possible secret" refusal (exit 5) from the secret scan. -----------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
out=$(env KIT_TEST_NO_PYTHON3=1 PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name nopy3run --brief "$brief" 2>&1)
code=$?
assert_eq 3 "$code" "codex build exits 3 when python3 is missing"
assert_contains "$out" "install python3" "codex build gives the install-python3 hint, not a false secret-scan refusal"

# === the repo copy is deleted when the run ends ===============================
# bulk_gone RUN_DIR LABEL -- wt, home, cfg and tmp are all gone.
bulk_gone() {
  bg_left=""
  for bg_d in wt home cfg tmp; do
    [ -e "$1/$bg_d" ] && bg_left="$bg_left $bg_d"
  done
  if [ -z "$bg_left" ]; then pass; else fail "$2: still in the run dir:$bg_left"; fi
}

# a fake codex that fails (provider error)
mk_fake_codex_bin_fails() {
  bindir=$(mktmp)
  cat > "$bindir/codex" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "boom: provider error"
exit 1
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

# --- success: bulk gone, build.patch is exactly the printed diff, logs kept ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name cleanrun --brief "$brief" 2>/dev/null)
code=$?
assert_eq 0 "$code" "cleanup: a normal run exits 0"
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then
  fail "cleanup: no run dir found"
else
  bulk_gone "$run_dir" "cleanup: success"
  if [ -f "$run_dir/build.patch" ]; then
    printed=$(printf '%s\n' "$out" | sed '/^kit-codex-build: run dir: /,$d')
    assert_eq "$(cat "$run_dir/build.patch")" "$printed" "cleanup: build.patch is exactly the printed diff"
    assert_contains "$printed" "hello.txt" "cleanup: the printed diff has the new file"
    case "$printed" in
      "--- diff ---"*) fail "cleanup: the printed output gained a diff header" ;;
      "diff --git"*) pass ;;
      *) fail "cleanup: the printed output does not start with the raw diff" ;;
    esac
    if git -C "$src" apply --check "$run_dir/build.patch" 2>/dev/null; then pass; else fail "cleanup: build.patch does not apply to the source repo"; fi
  else
    fail "cleanup: build.patch was not written"
  fi
  assert_contains "$out" "kit-codex-build: run dir: $run_dir" "cleanup: run dir line unchanged"
  assert_contains "$out" "kit-codex-build: build patch: $run_dir/build.patch" "cleanup: the patch path is printed"
  for keep in brief.md codex-output.txt secret-scan.txt; do
    if [ -f "$run_dir/$keep" ]; then pass; else fail "cleanup: $keep should survive in the run dir"; fi
  done
fi
lines=$(grep -c $'\tcodex\t' "$home/ledger.tsv")
assert_eq 1 "$lines" "cleanup: still exactly one ledger line"

# --- ROUTING_KIT_KEEP_RUNS=1 keeps the copy and says where ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" ROUTING_KIT_KEEP_RUNS=1 \
  "$BIN" --repo "$src" --name keeprun --brief "$brief" 2>&1)
code=$?
assert_eq 0 "$code" "keep-runs: exits 0"
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -f "$run_dir/wt/hello.txt" ] && [ -f "$run_dir/build.patch" ]; then pass; else fail "keep-runs: ROUTING_KIT_KEEP_RUNS=1 did not keep wt"; fi
assert_contains "$out" "ROUTING_KIT_KEEP_RUNS=1" "keep-runs: one-line note about the kept copy"
assert_contains "$out" "$run_dir/wt" "keep-runs: the note says where the copy is"

# --- a secret-scan refusal (exit 5): copy deleted, exit code and ledger unchanged ---
src=$(mk_src_repo)
printf 'SECRET=plain-value\n' > "$src/.env"
git -C "$src" add .env
git -C "$src" commit -q -m "add env"
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name cleanscan --brief "$brief" >/dev/null 2>&1
code=$?
assert_eq 5 "$code" "cleanup: a secret-scan refusal still exits 5"
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then fail "cleanup: no run dir found for the refusal"; else bulk_gone "$run_dir" "cleanup: secret-scan refusal"; fi
assert_eq 5 "$(grep $'\tcodex\t' "$home/ledger.tsv" | tail -1 | cut -f7)" "cleanup: the refusal's ledger line still says exit 5"

# --- a provider failure (codex exits 1): exit 4, copy deleted, one ledger line ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin_fails)
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name cleanfail --brief "$brief" >/dev/null 2>&1
code=$?
assert_eq 4 "$code" "cleanup: a provider failure still exits 4"
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -z "$run_dir" ]; then fail "cleanup: no run dir found for the provider failure"; else
  bulk_gone "$run_dir" "cleanup: provider failure"
  [ -f "$run_dir/codex-output.txt" ] && pass || fail "cleanup: codex-output.txt should survive a provider failure"
fi
assert_eq 1 "$(grep -c $'\tcodex\t' "$home/ledger.tsv")" "cleanup: provider failure writes exactly one ledger line"

# --- a dirty-repo refusal exits before any copy exists: nothing to delete, still exit 2 ---
src=$(mk_src_repo)
echo more >> "$src/a.txt"
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name cleandirty --brief "$brief" >/dev/null 2>&1
assert_eq 2 "$?" "cleanup: a dirty repo still exits 2"

# === review round 1 fixes =====================================================
# a fake codex that adds a new binary file and changes a tracked binary one
mk_fake_codex_bin_binary() {
  bindir=$(mktmp)
  cat > "$bindir/codex" <<'EOF'
#!/bin/bash
cat >/dev/null
dir=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then dir="$a"; fi
  prev="$a"
done
printf '\000\000\377new-binary-file\376\000' > "$dir/added.bin"
printf '\000\377\200changed-bytes\001\002\003\000' > "$dir/blob.bin"
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

# --- binary changes survive in build.patch: git apply reproduces them byte for byte ---
src=$(mk_src_repo)
printf '\000\001\002binary-original\377\376\000\000' > "$src/blob.bin"
git -C "$src" add blob.bin
git -C "$src" commit -q -m "add binary"
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin_binary)
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" ROUTING_KIT_KEEP_RUNS=1 \
  "$BIN" --repo "$src" --name binrun --brief "$brief" >/dev/null 2>&1
assert_eq 0 "$?" "binary build exits 0"
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
fresh=$(mktmp)
git clone -q "$src" "$fresh/c" 2>/dev/null
if [ -f "$run_dir/build.patch" ] && git -C "$fresh/c" apply "$run_dir/build.patch" 2>/dev/null \
  && cmp -s "$fresh/c/blob.bin" "$run_dir/wt/blob.bin" && cmp -s "$fresh/c/added.bin" "$run_dir/wt/added.bin"; then
  pass
else
  fail "build.patch must reproduce changed and new binary files byte for byte"
fi

# --- the run dir records its owner ---
owner=$(cat "$run_dir/owner.pid" 2>/dev/null)
case "$owner" in
  ''|*[!0-9]*) fail "kit-codex-build did not write a numeric owner.pid ($owner)" ;;
  *) pass ;;
esac

# --- codex fails after editing: the partial edits are saved as build.patch ---
mk_fake_codex_bin_edits_then_fails() {
  bindir=$(mktmp)
  cat > "$bindir/codex" <<'EOF'
#!/bin/bash
cat >/dev/null
dir=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then dir="$a"; fi
  prev="$a"
done
echo "half-done" > "$dir/partial.txt"
echo "boom" >&2
exit 1
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin_edits_then_fails)
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name salvage --brief "$brief" 2>&1)
code=$?
assert_eq 4 "$code" "a failing codex still exits 4"
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
bulk_gone "$run_dir" "salvage: failure"
if [ -f "$run_dir/build.patch" ] && grep -q "partial.txt" "$run_dir/build.patch"; then pass; else fail "a codex failure after edits must still leave a build.patch"; fi
assert_contains "$out" "$run_dir/build.patch" "the error names the salvaged patch"
# no edits -> no empty patch file, and the old message
src=$(mk_src_repo)
home=$(mktmp)
fakebin=$(mk_fake_codex_bin_fails)
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$BIN" --repo "$src" --name nosalvage --brief "$brief" 2>&1)
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -e "$run_dir/build.patch" ]; then fail "an empty salvage patch was left behind"; else pass; fi

# --- SIGTERM to the script while codex is running: codex and its children
# are killed, the copy is deleted, the ledger line is still written ---------
mk_fake_codex_bin_hangs() {
  pidfile="$1"
  bindir=$(mktmp)
  cat > "$bindir/codex" <<EOF
#!/bin/bash
cat >/dev/null
sleep 300 &
echo \$! > "$pidfile"
echo \$\$ > "$pidfile.leader"
wait
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
pid_dir=$(mktmp)
fakebin=$(mk_fake_codex_bin_hangs "$pid_dir/child.pid")
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$BIN" --repo "$src" --name sigrun --brief "$brief" >/dev/null 2>&1 &
sig_pid=$!
i=0
while [ ! -s "$pid_dir/child.pid" ] && [ "$i" -lt 200 ]; do i=$((i + 1)); sleep 0.1; done
if [ -s "$pid_dir/child.pid" ]; then
  child=$(cat "$pid_dir/child.pid")
  leader=$(cat "$pid_dir/child.pid.leader")
  # one { } group so bash's own "Terminated" job notice stays out of the output;
  # poll (never a bare wait) so a script that hangs fails instead of hanging us
  {
    kill -TERM "$sig_pid"
    i=0
    while kill -0 "$sig_pid" 2>/dev/null && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
    if kill -0 "$sig_pid" 2>/dev/null; then kill -KILL "$sig_pid"; sig_hung=1; else sig_hung=0; fi
    wait "$sig_pid"
  } 2>/dev/null
  sleep 0.2
  if kill -0 "$child" 2>/dev/null || kill -0 "$leader" 2>/dev/null; then
    fail "SIGTERM to kit-codex-build left codex (or its child) running"
    kill -KILL "$child" "$leader" 2>/dev/null
  elif [ "$sig_hung" = 1 ]; then
    fail "SIGTERM to kit-codex-build did not end it within 10s"
  else
    pass
  fi
  run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  bulk_gone "$run_dir" "SIGTERM: the copy is deleted"
  assert_eq 1 "$(grep -c $'\tcodex\t' "$home/ledger.tsv")" "SIGTERM: one ledger line is still written"
else
  kill -KILL "$sig_pid" 2>/dev/null
  { wait "$sig_pid"; } 2>/dev/null
  fail "the hanging fake codex never started"
fi

# === a build must not be able to run host commands through wt/.git ============
# A fake codex that plants a clean filter, a textconv, an external diff command,
# core.fsmonitor and an include.path in wt/.git/config, plus a .gitattributes
# and .git/info/attributes using them. Every planted command touches a marker
# file OUTSIDE wt.
mk_fake_codex_bin_evil_git() {
  marks="$1"
  bindir=$(mktmp)
  cat > "$bindir/codex" <<EOF
#!/bin/bash
cat >/dev/null
dir=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then dir="\$a"; fi
  prev="\$a"
done
printf '[core]\n\tfsmonitor = touch $marks/fsmonitor\n' > "$marks/included.cfg"
cat >> "\$dir/.git/config" <<CFG
[filter "evil"]
	clean = touch $marks/clean; cat
	smudge = touch $marks/smudge; cat
[diff "evil"]
	textconv = touch $marks/textconv; cat
	command = touch $marks/extdiff
[core]
	fsmonitor = touch $marks/fsmonitor2
	hooksPath = $marks/hooks
[include]
	path = $marks/included.cfg
CFG
mkdir -p "$marks/hooks"
printf '#!/bin/sh\ntouch $marks/hook\n' > "$marks/hooks/pre-commit"
chmod +x "$marks/hooks/pre-commit"
printf '*.txt filter=evil diff=evil\n' > "\$dir/.gitattributes"
mkdir -p "\$dir/.git/info"
printf '*.txt filter=evil diff=evil\n' > "\$dir/.git/info/attributes"
echo "hello evil" > "\$dir/evil.txt"
echo "changed" >> "\$dir/a.txt"
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}

marker_count() { find "$1" -maxdepth 1 -type f \( -name clean -o -name smudge -o -name textconv -o -name extdiff -o -name fsmonitor -o -name fsmonitor2 -o -name hook \) | wc -l | tr -d ' '; }

for mode in ok failing; do
  src=$(mk_src_repo)
  brief=$(mk_brief)
  home=$(mktmp)
  marks=$(mktmp)
  fakebin=$(mk_fake_codex_bin_evil_git "$marks")
  if [ "$mode" = failing ]; then
    # same planting, then codex fails: the salvage path must be just as safe
    sed -i.bak 's/^exit 0$/exit 1/' "$fakebin/codex"
  fi
  out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
    "$BIN" --repo "$src" --name "evil$mode" --brief "$brief" 2>/dev/null)
  code=$?
  if [ "$mode" = ok ]; then assert_eq 0 "$code" "evil git config: the run still exits 0"; else assert_eq 4 "$code" "evil git config: a failing run still exits 4"; fi
  assert_eq 0 "$(marker_count "$marks")" "evil git config ($mode): no planted command ran on the host (found: $(ls "$marks" | tr '\n' ' '))"
  run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  if [ -f "$run_dir/build.patch" ] && grep -q "hello evil" "$run_dir/build.patch" && grep -q "filter=evil" "$run_dir/build.patch" \
    && git -C "$src" apply --check "$run_dir/build.patch" 2>/dev/null; then
    pass
  else
    fail "evil git config ($mode): build.patch is missing or wrong"
  fi
  if [ "$mode" = ok ]; then
    assert_eq "$(cat "$run_dir/build.patch")" "$(printf '%s\n' "$out" | sed '/^kit-codex-build: run dir: /,$d')" "evil git config: the printed diff is exactly build.patch"
  fi
done

# --- a build that tampers with wt/.git itself (a symlinked .git, alternates, a
# symlinked or FIFO index, a symlinked object fanout dir, or a crafted binary
# index naming ../outside.txt) changes nothing: git runs against the pristine
# copy beside wt and never reads wt/.git. The run succeeds, nothing is written
# or read outside the copy, and build.patch is the build's real diff. --------
# The refusal modes (nested repo, FIFO, hard link, growth, unreadable dir) are
# build outputs git itself would be fooled by: exit 4, nothing runs.
mk_fake_codex_bin_tamper() {
  mode="$1"; marks="$2"
  bindir=$(mktmp)
  cat > "$bindir/codex" <<EOF
#!/bin/bash
cat >/dev/null
dir=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then dir="\$a"; fi
  prev="\$a"
done
echo hi > "\$dir/hello.txt"
case "$mode" in
  symlink)
    mv "\$dir/.git" "$marks/real-git"
    ln -s "$marks/real-git" "\$dir/.git"
    printf '[core]\n\tfsmonitor = touch $marks/fsmonitor\n' >> "$marks/real-git/config" ;;
  alternates)
    mkdir -p "\$dir/.git/objects/info"
    echo "$marks" > "\$dir/.git/objects/info/alternates" ;;
  index)
    rm -f "\$dir/.git/index"
    ln -s "$marks/outside/never-created" "\$dir/.git/index" ;;
  fanout)
    # the blob for hello.txt ("hi\n") is 45b983be...: aim its fanout dir outside
    mkdir -p "\$dir/.git/objects"
    ln -s "$marks/outside" "\$dir/.git/objects/45" ;;
  fifo)
    rm -f "\$dir/.git/index"
    mkfifo "\$dir/.git/index" ;;
  craftedindex)
    # a binary index with one entry whose path is ../outside.txt, a host file
    echo "HOST-SECRET-CONTENT" > "\$dir/../outside.txt"
    /usr/bin/python3 - "\$dir/.git/index" <<'PY'
import hashlib, struct, sys
path = b"../outside.txt"
entry = struct.pack(">10I", 0, 0, 0, 0, 0, 0, 0o100644, 0, 0, 20) + hashlib.sha1(b"blob 0\0").digest() + struct.pack(">H", len(path)) + path + b"\0"
entry += b"\0" * ((8 - len(entry) % 8) % 8)
body = b"DIRC" + struct.pack(">II", 2, 1) + entry
open(sys.argv[1], "wb").write(body + hashlib.sha1(body).digest())
PY
    ;;
  nested)
    mkdir -p "\$dir/sub/.git"
    printf '[filter "x"]\n\tclean = touch $marks/nested-clean\n' > "\$dir/sub/.git/config"
    echo "* filter=x" > "\$dir/sub/.gitattributes"; echo data > "\$dir/sub/f.txt" ;;
  nestedcase)
    mkdir -p "\$dir/sub/.GIT"
    echo data > "\$dir/sub/f.txt" ;;
  gitfile)
    echo "gitdir: $marks/outside" > "\$dir/sub.gitfile"; mkdir -p "\$dir/mod"; echo "gitdir: $marks/outside" > "\$dir/mod/.git" ;;
  fifoattr)
    mkfifo "\$dir/.gitattributes" ;;
  hardlink)
    ln "\$dir/a.txt" "\$dir/a-link.txt" ;;
  growth)
    dd if=/dev/zero of="\$dir/big.bin" bs=1048576 count=4 2>/dev/null ;;
  unreadable)
    mkdir "\$dir/locked"; echo x > "\$dir/locked/f"; chmod 000 "\$dir/locked" ;;
esac
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}
run_tamper() {
  # run_tamper MODE [EXTRA_ENV...] -- sets out, code, run_dir, marks, src; 60s deadline
  rt_mode="$1"; shift
  src=$(mk_src_repo)
  brief=$(mk_brief)
  home=$(mktmp)
  marks=$(mktmp)
  mkdir -p "$marks/outside"
  fakebin=$(mk_fake_codex_bin_tamper "$rt_mode" "$marks")
  out=$(run_with_timeout 60 env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$@" "$BIN" --repo "$src" --name "tamper$rt_mode" --brief "$brief" 2>&1)
  code=$?
  run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
}
for mode in symlink alternates index fanout fifo craftedindex; do
  run_tamper "$mode"
  assert_eq 0 "$code" "tampered wt/.git ($mode) changes nothing: the run still exits 0"
  assert_eq 0 "$(ls -A "$marks/outside" | wc -l | tr -d ' ')" "tampered wt/.git ($mode): nothing was written outside the copy"
  assert_eq 0 "$(marker_count "$marks")" "tampered wt/.git ($mode): nothing ran on the host"
  if [ -f "$run_dir/build.patch" ] && grep -q "hello.txt" "$run_dir/build.patch" && ! grep -q "HOST-SECRET" "$run_dir/build.patch" \
    && git -C "$src" apply --check "$run_dir/build.patch" 2>/dev/null; then pass; else fail "tampered wt/.git ($mode): build.patch is missing, wrong, or leaked a host file"; fi
  if [ -e "$run_dir/wt" ] || [ -e "$run_dir/git.pristine" ]; then fail "tampered wt/.git ($mode): the copy was not deleted"; else pass; fi
done
for mode in nested nestedcase gitfile fifoattr hardlink growth unreadable; do
  extra=""
  [ "$mode" = growth ] && extra="ROUTING_KIT_MAX_GROWTH_MB=1"
  run_tamper "$mode" $extra
  assert_eq 4 "$code" "a build with $mode is refused with exit 4 (no hang)"
  assert_contains "$out" "refusing to stage the build" "$mode: says why"
  assert_eq 0 "$(marker_count "$marks")" "$mode: nothing ran on the host"
  if [ -e "$marks/nested-clean" ]; then fail "$mode: the nested repo's filter ran"; else pass; fi
  if [ -e "$run_dir/wt" ] || [ -e "$run_dir/git.pristine" ]; then fail "$mode: the copy was not deleted"; else pass; fi
  if [ -e "$run_dir/build.patch" ]; then fail "$mode: a refused build left a build.patch"; else pass; fi
done

# --- the diff ignores the host's git config (kit_git): a user's diff.noprefix
# must not change build.patch, or `git apply` of it would break ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakehome=$(mktmp)
printf '[diff]\n\tnoprefix = true\n' > "$fakehome/.gitconfig"
fakebin=$(mk_fake_codex_bin "$(mktmp)/argv.log")
env HOME="$fakehome" PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  "$BIN" --repo "$src" --name hostcfg --brief "$brief" >/dev/null 2>&1
run_dir=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
case "$(head -n 1 "$run_dir/build.patch")" in
  "diff --git a/hello.txt b/hello.txt") pass ;;
  *) fail "the host's diff.noprefix leaked into build.patch: $(head -n 1 "$run_dir/build.patch")" ;;
esac

# === attributes come from HEAD only (git --attr-source=HEAD) ====================
# (1) a build swaps the tracked dir sub/ for a symlink to an outside dir that
# holds a .gitattributes marking everything binary: git follows the symlinked
# parent when it looks up attributes for the deleted sub/file.txt. The patch
# must be byte-identical to the one from the same build with no outside file.
# (2) the build's own new .gitattributes (* binary) must not change how its
# edits are diffed either.
mk_fake_codex_bin_attr() {
  mode="$1"; ext="$2"
  bindir=$(mktmp)
  cat > "$bindir/codex" <<EOF
#!/bin/bash
cat >/dev/null
dir=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then dir="\$a"; fi
  prev="\$a"
done
case "$mode" in
  symlinkdir)
    rm -rf "\$dir/sub"
    ln -s "$ext" "\$dir/sub" ;;
  ownattrs)
    echo "* binary" > "\$dir/.gitattributes"
    echo "changed text" >> "\$dir/a.txt" ;;
esac
exit 0
EOF
  chmod +x "$bindir/codex"
  echo "$bindir"
}
attr_run() {
  # attr_run MODE EXT -- echoes the build.patch path of a fresh run (a repo with a tracked sub/file.txt)
  ar_src=$(mk_src_repo)
  mkdir -p "$ar_src/sub"; printf 'line one\nline two\n' > "$ar_src/sub/file.txt"
  git -C "$ar_src" add sub; git -C "$ar_src" commit -q -m sub
  ar_home=$(mktmp)
  ar_bin=$(mk_fake_codex_bin_attr "$1" "$2")
  env PATH="$ar_bin:/usr/bin:/bin" ROUTING_KIT_HOME="$ar_home" ROUTING_KIT_KEEP_RUNS=1 \
    "$BIN" --repo "$ar_src" --name attrrun --brief "$(mk_brief)" >/dev/null 2>&1
  ar_code=$?
  ar_patch=$(find "$ar_home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)/build.patch
}
ext=$(mktmp)
attr_run symlinkdir "$ext"; clean_patch=$(cat "$ar_patch"); assert_eq 0 "$ar_code" "symlinked-dir build (clean) exits 0"
echo "* binary" > "$ext/.gitattributes"
attr_run symlinkdir "$ext"; evil_patch=$(cat "$ar_patch"); assert_eq 0 "$ar_code" "symlinked-dir build (outside .gitattributes) exits 0"
assert_contains "$clean_patch" "-line one" "the deleted file shows as a text diff in the clean run"
assert_eq "$clean_patch" "$evil_patch" "an outside .gitattributes reached through a symlinked dir does not change the patch"
attr_run ownattrs "$ext"; own_patch=$(cat "$ar_patch")
assert_eq 0 "$ar_code" "own-.gitattributes build exits 0"
assert_contains "$own_patch" "+changed text" "a build's own '* binary' .gitattributes does not turn its edits into binary patches"
case "$own_patch" in *"GIT binary patch"*) fail "the build's own .gitattributes changed the patch to binary" ;; *) pass ;; esac

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
