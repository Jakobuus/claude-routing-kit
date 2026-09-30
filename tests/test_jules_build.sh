#!/bin/bash
. "$(dirname "$0")/lib.sh"
BIN="$(cd "$(dirname "$0")/.." && pwd -P)/plugins/routing-kit/bin/kit-jules-build"

mk_brief() {
  d=$(mktmp)
  printf 'add hello.txt\n' > "$d/brief.md"
  echo "$d/brief.md"
}

# a clean repo pushed to a local bare "origin" whose HEAD symref is main, so
# the GitHub-default-branch check passes via KIT_JULES_ALLOW_LOCAL_ORIGIN.
mk_src_repo() {
  bare_dir=$(mktmp)
  bare="$bare_dir/repo.git"
  git init -q --bare "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  src=$(mktmp)
  git -C "$src" init -q -b main
  git -C "$src" config user.email you@example.com
  git -C "$src" config user.name "Test User"
  echo hello > "$src/a.txt"
  git -C "$src" add a.txt
  git -C "$src" commit -q -m init
  git -C "$src" remote add origin "$bare"
  git -C "$src" push -q origin main
  echo "$src"
}

# --- a fake jules on PATH: starts a session, reports the given status
# (Completed by default) right away, and hands back a small patch that adds
# hello.txt. -------------------------------------------------------------
mk_fake_jules_bin() {
  status="${1:-Completed}"
  bindir=$(mktmp)
  cat > "$bindir/jules" <<EOF
#!/bin/bash
case "\$1" in
  new)
    cat >/dev/null
    echo "https://jules.google.com/session/fakesession001"
    exit 0
    ;;
  remote)
    case "\$2" in
      list)
        echo "fakesession001  myrepo  $status"
        exit 0
        ;;
      pull)
        cat <<'PATCH'
diff --git a/hello.txt b/hello.txt
new file mode 100644
index 0000000..e69de29
--- /dev/null
+++ b/hello.txt
@@ -0,0 +1 @@
+hi
PATCH
        exit 0
        ;;
    esac
    ;;
esac
exit 1
EOF
  chmod +x "$bindir/jules"
  echo "$bindir"
}

# --- a fake jules that, on `new`, first overwrites some OTHER file (the
# original brief, named via $2) with tamper_content, then captures whatever
# it actually receives on stdin into stdin_capture. If the script under
# test still opens the original brief for `jules new`'s stdin (instead of a
# snapshot copy made earlier), this fake's own overwrite -- happening
# before it reads its stdin -- would already have landed in that same
# file, and the capture would show the tampered bytes instead of the
# pre-tamper ones. It completes the rest of the session flow normally so
# the script can run to a clean exit. --------------------------------------
mk_fake_jules_bin_toctou() {
  stdin_capture="$1"
  tamper_path="$2"
  tamper_content="$3"
  bindir=$(mktmp)
  cat > "$bindir/jules" <<EOF
#!/bin/bash
case "\$1" in
  new)
    printf '%s' "$tamper_content" > "$tamper_path"
    cat > "$stdin_capture"
    echo "https://jules.google.com/session/fakesession001"
    exit 0
    ;;
  remote)
    case "\$2" in
      list)
        echo "fakesession001  myrepo  Completed"
        exit 0
        ;;
      pull)
        cat <<'PATCH'
diff --git a/hello.txt b/hello.txt
new file mode 100644
index 0000000..e69de29
--- /dev/null
+++ b/hello.txt
@@ -0,0 +1 @@
+hi
PATCH
        exit 0
        ;;
    esac
    ;;
esac
exit 1
EOF
  chmod +x "$bindir/jules"
  echo "$bindir"
}

# --- dirty repo -> 2 ---
src=$(mk_src_repo)
echo more >> "$src/a.txt"
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_jules_bin)
assert_exit 2 "dirty repo refused" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  "$BIN" --repo "$src" --name myrun --brief "$brief" --verify "true"

# --- jules missing -> 3, with the install line ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
emptybin=$(mktmp)
out=$(env PATH="$emptybin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  "$BIN" --repo "$src" --name myrun --brief "$brief" --verify "true" 2>&1)
code=$?
assert_eq 3 "$code" "missing jules exits 3"
assert_contains "$out" "npm install -g @google/jules" "missing-jules message has the install line"
assert_contains "$out" "jules login" "missing-jules message has the login step"

# --- verify passes: exit 0, ledger gets one jules line ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin)
assert_exit 0 "passing verify exits 0" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name myrun --brief "$brief" --verify "test -f hello.txt"

ledger="$home/ledger.tsv"
if [ -f "$ledger" ]; then
  lines=$(grep -c $'\tjules\t' "$ledger")
  assert_eq 1 "$lines" "ledger has exactly one jules line"
else
  fail "ledger.tsv was not created"
fi

# --- verify fails: script exits non-zero, patch stays staged in the worktree ---
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin)
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name myrun --brief "$brief" --verify "exit 1" 2>&1)
code=$?
if [ "$code" -ne 0 ]; then pass; else fail "failing verify must exit non-zero (got 0)"; fi

wt_dir=$(find "$wts" -mindepth 1 -maxdepth 1 -type d | head -1)
if [ -n "$wt_dir" ]; then
  staged=$(git -C "$wt_dir" diff --cached --name-only)
  assert_contains "$staged" "hello.txt" "failed-verify patch is left staged in the worktree"
else
  fail "no worktree was created for the failed-verify run"
fi

# --- P1: a secret in the brief refuses the run. It's caught by the
# original-path scan (content rules apply regardless of filename), which
# runs before anything is copied anywhere. --------------------------------
src=$(mk_src_repo)
d=$(mktmp)
k="sk-""ant-api03-$(printf 'A%.0s' {1..24})"
printf 'notes\n\nkey: %s\n' "$k" > "$d/brief.md"
home=$(mktmp)
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin)
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name secrun --brief "$d/brief.md" --verify "true" >/tmp/rk-test-jules-p1-out.$$ 2>&1
code=$?
rm -f /tmp/rk-test-jules-p1-out.$$
assert_eq 5 "$code" "secret in the jules brief refuses the run"

# --- finding 4: the secret-scan refusal above still writes one ledger line.
# Checked right here, against secrun's own $home, before any other run
# below gets a fresh home of its own -- reusing $home for a later run would
# make this assertion inspect that later run's ledger instead, and a real
# regression that drops the ledger write on exit 5 would slip past it. -----
ledger="$home/ledger.tsv"
if [ -f "$ledger" ]; then
  lines=$(grep -c $'\tjules\t' "$ledger")
  assert_eq 1 "$lines" "secret-scan refusal still writes exactly one ledger line"
else
  fail "ledger.tsv was not created for the secret-scan refusal"
fi

# --- P1: on a clean run, the run dir still holds a brief snapshot whose
# content matches the original exactly -- that snapshot, not a fresh
# re-read of the original, is what a passing scan goes on to send. Uses its
# own $snap_runs so it can't be confused with secrun's ledger above. -------
src=$(mk_src_repo)
brief=$(mk_brief)
snap_home=$(mktmp)
snap_runs=$(mktmp); snap_wts=$(mktmp)
fakebin=$(mk_fake_jules_bin)
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$snap_home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$snap_runs" KIT_JULES_WORKTREES_DIR="$snap_wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name snaprun --brief "$brief" --verify "true" >/dev/null 2>&1
run_dir=$(find "$snap_runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -n "$run_dir" ] && [ -f "$run_dir/brief.md" ] && diff -q "$brief" "$run_dir/brief.md" >/dev/null 2>&1; then
  pass
else
  fail "no matching brief snapshot was left in the run dir for a clean run"
fi

# --- re-review2 P1: jules must receive the frozen snapshot bytes, not a
# live read of the original brief. A fake jules tampers the original brief
# file (as another process might, in the gap between the snapshot being
# taken and `jules new` being launched) before reading its own stdin, then
# records exactly what it received. If the script fed `jules new`
# "$BRIEF" directly instead of the snapshot, jules's own tamper write --
# landing in the same file its stdin is reading from -- would show up in
# the capture. --------------------------------------------------------------
src=$(mk_src_repo)
d=$(mktmp)
printf 'ORIGINAL-MARKER\n' > "$d/brief.md"
toctou_home=$(mktmp)
toctou_runs=$(mktmp); toctou_wts=$(mktmp)
stdin_capture=$(mktmp)/jules-stdin.txt
fakebin=$(mk_fake_jules_bin_toctou "$stdin_capture" "$d/brief.md" 'TAMPERED-MARKER
')
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$toctou_home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$toctou_runs" KIT_JULES_WORKTREES_DIR="$toctou_wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name toctourun --brief "$d/brief.md" --verify "true" >/dev/null 2>&1
if [ -f "$stdin_capture" ] && grep -q "ORIGINAL-MARKER" "$stdin_capture" \
  && ! grep -q "TAMPERED-MARKER" "$stdin_capture"; then
  pass
else
  fail "jules must receive the frozen snapshot, not a live re-read of a tampered original brief"
fi

# --- finding 4: missing-jules (an early preflight failure) also logs one
# ledger line. ----------------------------------------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
emptybin=$(mktmp)
env PATH="$emptybin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  "$BIN" --repo "$src" --name myrun --brief "$brief" --verify "true" >/dev/null 2>&1
if [ -f "$home/ledger.tsv" ]; then
  lines=$(grep -c $'\tjules\t' "$home/ledger.tsv")
  assert_eq 1 "$lines" "missing-jules preflight failure still writes exactly one ledger line"
else
  fail "ledger.tsv was not created for the missing-jules failure"
fi

# --- finding 2: a Jules "Failed" status maps to the global provider-error
# code 4, not 3. ---------------------------------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin Failed)
assert_exit 4 "Jules Failed status maps to provider-error exit 4" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name failrun --brief "$brief" --verify "true"

# --- finding 2: a status needing a human (e.g. "Awaiting User Feedback")
# maps to 4, not the old lockdown code 5. ---------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin "Awaiting User Feedback")
assert_exit 4 "a needs-a-human Jules status maps to provider-error exit 4" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name humanrun --brief "$brief" --verify "true"

# --- finding 2: a timeout maps to 4, not the undocumented 124. -----------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin Pending)
assert_exit 4 "a Jules timeout maps to provider-error exit 4" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name timeoutrun --brief "$brief" --verify "true" --timeout 1

# --- finding 3: a git failure after Jules verify must not report success ----
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin Completed)
out=$(env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name stagefailrun --brief "$brief" --verify "chmod 000 .git" 2>&1)
code=$?
wt_dir=$(find "$wts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -n "$wt_dir" ] && chmod -R 755 "$wt_dir/.git" 2>/dev/null
if [ "$code" -ne 0 ]; then
  pass
else
  fail "a git add/diff failure after Jules verify must not exit 0"
fi

# --- finding 5: a --name with a tab/newline/CR is refused before anything is
# logged, so it can never forge extra ledger rows or columns. ----------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
bad_name=$'job\nforged\trow'
assert_exit 2 "a --name with an embedded newline/tab is refused" -- env ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  "$BIN" --repo "$src" --name "$bad_name" --brief "$brief" --verify "true"
if [ -f "$home/ledger.tsv" ]; then
  fail "a rejected --name must never reach the ledger"
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
runs=$(mktmp); wts=$(mktmp)
fakebin=$(mk_fake_jules_bin)
env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$runs" KIT_JULES_WORKTREES_DIR="$wts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name envrun --brief "$d/.env" --verify "true" >/tmp/rk-test-jules-env-out.$$ 2>&1
code=$?
rm -f /tmp/rk-test-jules-env-out.$$
if [ "$code" -eq 5 ]; then
  pass
else
  fail "a .env-named brief must be refused by the filename rule (got exit $code)"
fi

# --- re-review P2: a ledger write failure (KIT_HOME can't be created) must
# never mask the real exit code. The trap has to isolate ledger_append's
# own kit_die/exit, or a failed ledger write for a missing-jules run would
# be reported as exit 2 instead of 3. -------------------------------------
src=$(mk_src_repo)
brief=$(mk_brief)
emptybin=$(mktmp)
badhome="/dev/null/rk-review-$$"
out=$(env PATH="$emptybin:/usr/bin:/bin" ROUTING_KIT_HOME="$badhome" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  "$BIN" --repo "$src" --name myrun --brief "$brief" --verify "true" 2>&1)
code=$?
assert_eq 3 "$code" "a ledger write failure must not mask the real (missing-jules) exit code"
assert_contains "$out" "jules login" "the missing-jules message still comes through"

# --- re-review P3: a --name that sanitizes to an empty slug must be refused
# before the ledger trap is installed -- not after. Installing the trap too
# early let a rejected name still produce a ledger line. -------------------
src=$(mk_src_repo)
brief=$(mk_brief)
home=$(mktmp)
fakebin=$(mk_fake_jules_bin)
assert_exit 2 "a --name with no slug-safe characters is refused" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  "$BIN" --repo "$src" --name '!!!' --brief "$brief" --verify "true"
if [ -f "$home/ledger.tsv" ]; then
  fail "a --name that fails slug validation must never reach the ledger"
else
  pass
fi

# --- lockdown fix wave 1, item 25: a fake `cp` earlier on PATH that plants a
# secret in the brief snapshot must be caught by the SECOND secret_scan
# (over $RUN/brief.md), not just the first (over the original --brief
# path). Every secret in the ORIGINAL file is already caught by the first
# scan, so deleting the second scan would still pass a test that only ever
# put the secret in the original -- this test puts it in the snapshot
# instead, after the copy, so only the second scan can see it. -------------
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
cpruns=$(mktmp); cpwts=$(mktmp)
fakecpbin=$(mk_fake_cp_bin_plants_secret)
fakebin=$(mk_fake_jules_bin)
out=$(env PATH="$fakecpbin:$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$cphome" \
  KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo \
  KIT_JULES_RUNS_DIR="$cpruns" KIT_JULES_WORKTREES_DIR="$cpwts" KIT_JULES_POLL_SECS=1 \
  "$BIN" --repo "$src" --name cprun --brief "$brief" --verify "true" 2>&1)
code=$?
assert_eq 5 "$code" "a secret planted into the jules snapshot (after the original-file scan) is still caught"
run_dir=$(find "$cpruns" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -n "$run_dir" ] && [ -f "$run_dir/secret-scan.txt" ] && [ -s "$run_dir/secret-scan.txt" ]; then
  pass
else
  fail "the second secret scan (over the run dir's snapshot) did not run or found nothing"
fi

# --- item 25: the refusal above writes a ledger line whose exit COLUMN is
# 5, not just some line mentioning "jules". ----------------------------------
ledger="$cphome/ledger.tsv"
if [ -f "$ledger" ]; then
  ledger_line=$(grep $'\tjules\t' "$ledger")
  ledger_exit=$(printf '%s\n' "$ledger_line" | cut -f7)
  assert_eq 5 "$ledger_exit" "the snapshot-secret refusal's ledger line has exit column 5"
else
  fail "ledger.tsv was not created for the snapshot-secret refusal"
fi

# The account is trusted, so contact details pass; API keys still refuse.
src=$(mk_src_repo); brief=$(mk_brief); home=$(mktmp); fakebin=$(mk_fake_jules_bin)
printf 'contact someone''@example.org in /Us''ers/example/project\n' >> "$brief"
assert_exit 0 "contact details pass Jules credential scan" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo KIT_JULES_POLL_SECS=1 "$BIN" --repo "$src" --name contact --brief "$brief" --verify true
printf 'token gh''p_abcdefgh1234\n' >> "$brief"
assert_exit 5 "token fails Jules credential scan" -- env PATH="$fakebin:/usr/bin:/bin" ROUTING_KIT_HOME="$(mktmp)" KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo KIT_JULES_POLL_SECS=1 "$BIN" --repo "$src" --name secret --brief "$brief" --verify true

authbin=$(mktmp); brief=$(mk_brief)
printf '#!/bin/bash\necho "not logged in"\nexit 1\n' > "$authbin/jules"; chmod +x "$authbin/jules"
out=$(env PATH="$authbin:/usr/bin:/bin" ROUTING_KIT_HOME="$(mktmp)" KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo "$BIN" --repo "$src" --name auth --brief "$brief" --verify true 2>&1); code=$?
assert_eq 3 "$code" "Jules login failure exits 3"
assert_contains "$out" "jules login" "Jules login failure gives command"
printf '#!/bin/bash\necho "provider overloaded"\nexit 1\n' > "$authbin/jules"; chmod +x "$authbin/jules"
assert_exit 4 "Jules provider failure exits 4" -- env PATH="$authbin:/usr/bin:/bin" ROUTING_KIT_HOME="$(mktmp)" KIT_JULES_ALLOW_LOCAL_ORIGIN=1 KIT_JULES_REPO_SLUG=test/repo "$BIN" --repo "$src" --name provider --brief "$brief" --verify true

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
