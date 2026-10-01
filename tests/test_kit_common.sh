#!/bin/bash
. "$(dirname "$0")/lib.sh"
KC="$(cd "$(dirname "$0")/.." && pwd -P)/plugins/routing-kit/bin/kit-common"

# Regression: KIT_KEYCHAIN_CMD must be read with a default (${KIT_KEYCHAIN_CMD:-})
# so callers that source kit-common under `set -u` don't crash with an
# unbound-variable error before kit_key can report "no key for provider".
out=$(bash -c '
  set -u
  . "'"$KC"'"
  unset KIT_KEYCHAIN_CMD
  kit_key nonexistent-provider-xyz
' 2>&1)
code=$?
assert_eq 3 "$code" "kit_key exits 3 (no key), not a set -u crash"
case "$out" in
  *"unbound variable"*) fail "kit_key crashed on unbound KIT_KEYCHAIN_CMD under set -u" ;;
  *) pass ;;
esac


# --- item 1: kit_git must not let an inherited GIT_CONFIG_COUNT clean/smudge
# filter run during a collection command (add/diff), even with a matching
# .gitattributes already committed in the repo. A prior form of kit_git only
# ever *added* GIT_CONFIG_NOSYSTEM/GIT_CONFIG_GLOBAL on top of the caller's
# full environment; it never cleared GIT_CONFIG_COUNT/KEY_*/VALUE_*, so the
# filter still ran and could write a marker outside the repo it was never
# supposed to touch. ------------------------------------------------------
d=$(mktmp)
git -C "$d" init -q
git -C "$d" config user.email you@example.com
git -C "$d" config user.name "Test User"
echo hi > "$d/a.txt"
git -C "$d" add a.txt
git -C "$d" commit -q -m init

marker_dir=$(mktmp)
marker="$marker_dir/marker"
filter_dir=$(mktmp)
filter_script="$filter_dir/filter.sh"
cat > "$filter_script" <<EOF
#!/bin/bash
echo planted > "$marker"
cat
EOF
chmod +x "$filter_script"
echo "*.txt filter=rk-test-evil" > "$d/.gitattributes"
git -C "$d" add .gitattributes
git -C "$d" commit -q -m attrs
echo more >> "$d/a.txt"

env GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="filter.rk-test-evil.clean" \
    GIT_CONFIG_VALUE_0="$filter_script" \
    bash -c '. "'"$KC"'"; kit_git -C "'"$d"'" add -A; kit_git -C "'"$d"'" diff --cached' >/dev/null 2>&1

if [ -f "$marker" ]; then
  fail "kit_git ran a GIT_CONFIG_COUNT-configured smudge/clean filter during add/diff"
else
  pass
fi

# --- item 4: the same inherited GIT_CONFIG_COUNT filter must not run
# during `kit_git clone` either -- run_export (lib/export.sh) clones the
# source repo through kit_git, and a clone's checkout step runs the SMUDGE
# side of any filter named in a checked-out .gitattributes, a different
# code path from the add/diff case above (which only ever exercises
# clean). Same repo, same filter config, a fresh marker so a leftover from
# the add/diff case above can't make this look like it passed. -----------
clone_marker_dir=$(mktmp)
clone_marker="$clone_marker_dir/marker"
clone_filter_dir=$(mktmp)
clone_filter_script="$clone_filter_dir/filter.sh"
cat > "$clone_filter_script" <<EOF
#!/bin/bash
echo planted > "$clone_marker"
cat
EOF
chmod +x "$clone_filter_script"
clone_dest_dir=$(mktmp)
clone_dest="$clone_dest_dir/wt"
rm -rf "$clone_dest"

env GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="filter.rk-test-evil.smudge" \
    GIT_CONFIG_VALUE_0="$clone_filter_script" \
    bash -c '. "'"$KC"'"; kit_git clone --template= --depth 1 --single-branch --no-local "file://'"$d"'" "'"$clone_dest"'"' >/dev/null 2>&1
clone_code=$?

# Guard against a false pass: if the clone itself failed (e.g. because
# clearing GIT_CONFIG_COUNT broke something else), the marker would also
# be absent -- but that's a broken clone, not a proven-safe filter. Assert
# the clone actually succeeded and checked a.txt out before trusting the
# marker's absence.
if [ "$clone_code" -ne 0 ]; then
  fail "kit_git clone exited $clone_code -- can't trust the marker check on a failed clone"
elif [ ! -f "$clone_dest/a.txt" ]; then
  fail "kit_git clone reported success but a.txt is missing from the checkout"
else
  pass
fi

if [ -f "$clone_marker" ]; then
  fail "kit_git ran a GIT_CONFIG_COUNT-configured smudge filter during clone"
else
  pass
fi

# --- item 8: kit_git must not leave its throwaway HOME behind. A prior
# form created $TMPDIR/kit-git-home.XXXXXX once per process and cached it
# for every later kit_git call in that process, but never removed it --
# every process that ever called kit_git left one more such directory
# under $TMPDIR permanently. Call kit_git several times in one process
# (mirrors real use: run_export calls it for rev-parse, status, clone,
# remote, remote remove -- five-plus calls per run) and assert none of
# those directories exist afterward. -------------------------------------
git_home_glob="${TMPDIR:-/tmp}/kit-git-home.*"
before_count=$(ls -d $git_home_glob 2>/dev/null | wc -l | tr -d ' ')
bash -c '
  . "'"$KC"'"
  d=$(mktemp -d)
  kit_git -C "$d" init -q
  kit_git -C "$d" config user.email you@example.com
  kit_git -C "$d" config user.name "Test User"
  kit_git -C "$d" status --porcelain >/dev/null
  kit_git -C "$d" rev-parse --git-dir >/dev/null
' >/dev/null 2>&1
after_count=$(ls -d $git_home_glob 2>/dev/null | wc -l | tr -d ' ')
if [ "$after_count" -gt "$before_count" ]; then
  fail "item 8: kit_git left a kit-git-home.* directory behind (before=$before_count after=$after_count)"
else
  pass
fi


# --- kit_require_supported: macOS and Linux (incl. WSL2, which reports
# uname as Linux) pass; anything else (native Windows' MINGW/MSYS/CYGWIN
# uname, or anything unrecognized) refuses with the supported-systems
# message, exit 2. -----------------------------------------------------------
for fake_os in Darwin Linux; do
  fakebin=$(mktmp)
  cat > "$fakebin/uname" <<EOF
#!/bin/bash
echo "$fake_os"
EOF
  chmod +x "$fakebin/uname"
  out=$(env PATH="$fakebin:$PATH" bash -c '. "'"$KC"'"; kit_require_supported; echo passed' 2>&1)
  code=$?
  assert_eq 0 "$code" "kit_require_supported passes on a faked $fake_os uname"
  assert_contains "$out" "passed" "kit_require_supported returns (doesn't exit) on a faked $fake_os uname"
done

winbin=$(mktmp)
cat > "$winbin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0"
EOF
chmod +x "$winbin/uname"
out=$(env PATH="$winbin:$PATH" bash -c '. "'"$KC"'"; kit_require_supported; echo unreachable' 2>&1)
code=$?
assert_eq 2 "$code" "kit_require_supported refuses on a faked native-Windows uname"
assert_contains "$out" "routing-kit needs macOS, Linux, or WSL2 on Windows" "kit_require_supported prints the supported-systems message"
case "$out" in
  *unreachable*) fail "kit_require_supported did not actually exit before the next line" ;;
  *) pass ;;
esac

# --- kit_require_kimi_glm_macos: Darwin passes; anything else refuses with
# the Kimi/GLM-specific message (distinct from the generic macOS-only and
# supported-systems messages), exit 2. Platform-aware, since this test file
# itself must pass on real macOS AND real Ubuntu: on whichever real host
# this actually runs, it expects the outcome that host's real uname gives. -
out=$(bash -c '. "'"$KC"'"; kit_require_kimi_glm_macos; echo passed' 2>&1)
code=$?
if [ "$(uname)" = Darwin ]; then
  assert_eq 0 "$code" "kit_require_kimi_glm_macos passes on this real Mac"
  assert_contains "$out" "passed" "kit_require_kimi_glm_macos returns on this real Mac"
else
  assert_eq 2 "$code" "kit_require_kimi_glm_macos refuses on this real, non-macOS host"
  assert_contains "$out" "Kimi and GLM need a Mac" "kit_require_kimi_glm_macos prints the Kimi/GLM-specific message here"
fi

out=$(env PATH="$fakebin:$PATH" bash -c '. "'"$KC"'"; kit_require_kimi_glm_macos; echo unreachable' 2>&1)
code=$?
assert_eq 2 "$code" "kit_require_kimi_glm_macos refuses on a faked Linux uname"
assert_contains "$out" "Kimi and GLM need a Mac" "kit_require_kimi_glm_macos prints the Kimi/GLM-specific message"
case "$out" in
  *unreachable*) fail "kit_require_kimi_glm_macos did not actually exit before the next line" ;;
  *) pass ;;
esac

# --- kit_mtime: a real file's mtime is a plausible epoch second count
# (within the last minute, given the file was just created), on whichever
# platform this test happens to run. -----------------------------------------
mt_file=$(mktmp)/mt.txt
mkdir -p "$(dirname "$mt_file")"
echo hi > "$mt_file"
now=$(date +%s)
mt=$(bash -c '. "'"$KC"'"; kit_mtime "'"$mt_file"'"')
if [[ "$mt" =~ ^[0-9]+$ ]] && [ $((now - mt)) -ge -5 ] && [ $((now - mt)) -lt 60 ]; then
  pass
else
  fail "kit_mtime gave an implausible mtime for a just-created file (now=$now mtime=$mt)"
fi

# --- kit_jq / kit_python3: resolve to a working interpreter on this
# machine (stock macOS's /usr/bin/jq and /usr/bin/python3, per
# kit_resolve_tools's preference) and actually run. ---------------------------
out=$(bash -c '. "'"$KC"'"; echo "{}" | kit_jq -e .' 2>&1)
assert_eq '{}' "$out" "kit_jq resolves to a working jq"
out=$(bash -c '. "'"$KC"'"; kit_python3 -c "print(1 + 1)"' 2>&1)
assert_eq '2' "$out" "kit_python3 resolves to a working python3"

# --- kit_jq / kit_python3 / kit_require_jq / kit_require_python3
# unresolvable case (exit 3, install hint, never a raw command-not-found
# crash): only provable where /usr/bin/jq and /usr/bin/python3 genuinely
# don't exist, since kit_resolve_tools checks those absolute paths
# directly, ahead of PATH, on every OS -- this dev Mac (like stock macOS)
# has both, so this can't be faked here via PATH alone. Proven via
# KIT_TEST_NO_JQ/KIT_TEST_NO_PYTHON3 instead, the same override the public
# commands' own missing-dependency tests use (test_codex_build.sh,
# test_jules_build.sh, test_quota.sh) -- this dev Mac having both tools for
# real is what CI's Ubuntu job, with no jq installed until its own
# `apt-get install jq` step, proves end-to-end instead.
out=$(env KIT_TEST_NO_JQ=1 bash -c '. "'"$KC"'"; kit_jq -e . <<< "{}"' 2>&1)
code=$?
assert_eq 3 "$code" "kit_jq exits 3 when no jq is resolvable"
assert_contains "$out" "install jq" "kit_jq gives an install hint when unresolvable"
out=$(env KIT_TEST_NO_PYTHON3=1 bash -c '. "'"$KC"'"; kit_python3 -c "pass"' 2>&1)
code=$?
assert_eq 3 "$code" "kit_python3 exits 3 when no python3 is resolvable"
assert_contains "$out" "install python3" "kit_python3 gives an install hint when unresolvable"

out=$(env KIT_TEST_NO_JQ=1 bash -c '. "'"$KC"'"; kit_require_jq; echo unreachable' 2>&1)
code=$?
assert_eq 3 "$code" "kit_require_jq exits 3 when no jq is resolvable"
assert_contains "$out" "install jq" "kit_require_jq gives an install hint when unresolvable"
case "$out" in
  *unreachable*) fail "kit_require_jq did not actually exit before the next line" ;;
  *) pass ;;
esac
out=$(env KIT_TEST_NO_PYTHON3=1 bash -c '. "'"$KC"'"; kit_require_python3; echo unreachable' 2>&1)
code=$?
assert_eq 3 "$code" "kit_require_python3 exits 3 when no python3 is resolvable"
assert_contains "$out" "install python3" "kit_require_python3 gives an install hint when unresolvable"
case "$out" in
  *unreachable*) fail "kit_require_python3 did not actually exit before the next line" ;;
  *) pass ;;
esac

# --- kit_canary_verdict: validates lib/canaries.sh's own "CANARY SUMMARY
# pass=N fail=N env_fail=N" line against the real canaries_run exit status
# and returns 0 (proceed), 4 (environment problem), or 5 (refuse). A real
# leak (fail>0) must always win 5, even alongside an env_fail; an
# unrecoverable environment problem alone (fail=0, env_fail>0, status !=0)
# must be 4, not 5 -- that is the entire point (locked-build must not
# report "lockdown failed" when nothing actually leaked); anything
# unreadable, or inconsistent with the status, defaults to the stricter 5.
# Called on every round, including a clean one (status 0): that must be
# backed by an all-zero summary, or it is also refused (security review,
# round 2). The cases below are the exact ones security review reported
# across both rounds.
. "$KC"

log=$(mktmp)/log
printf 'CANARY OK   x\nCANARY SUMMARY pass=5 fail=0 env_fail=0\n' > "$log"
assert_eq 0 "$(kit_canary_verdict "$log" 0)" "status 0 with a clean (all-zero) summary is verdict 0, proceed"

printf 'CANARY SUMMARY pass=5 fail=1 env_fail=0\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "a real leak (fail=1) is exit 5"

printf 'CANARY SUMMARY pass=5 fail=0 env_fail=2\n' > "$log"
assert_eq 4 "$(kit_canary_verdict "$log" 1)" "env_fail alone (fail=0) is exit 4, not 5"

printf 'CANARY SUMMARY pass=5 fail=1 env_fail=2\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "a real leak alongside an env_fail still wins 5"

: > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "a missing CANARY SUMMARY line defaults to 5, not a false 4"

# --- security review (round 1): a STATUS of 0 must be backed by an
# all-zero summary -- a log that would otherwise look like env_fail is
# refused outright (5), not silently accepted as clean (0) or
# misread as an environment problem (4). ------------------------------------
printf 'CANARY SUMMARY pass=5 fail=0 env_fail=2\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 0)" "status 0 with a non-zero summary is inconsistent -> 5, never 0 or 4"

# --- security review (round 1): "fail=0garbage" -- a loose ".* fail="
# pattern (digit then ANY characters) previously accepted this and misread
# env_fail as if it were fail. -----------------------------------------
printf 'CANARY SUMMARY pass=5 fail=0garbage env_fail=2\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "a non-numeric fail field (fail=0garbage) is malformed -> 5, never 4"

# --- security review (round 1): a duplicated/conflicting fail field. The
# whole-line format check must reject this outright, not pick whichever
# "fail=" a regex happened to match. -------------------------------------
printf 'CANARY SUMMARY pass=5 fail=1 fail=0 env_fail=0\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "a duplicated fail field is malformed -> 5, never a false 4"

# --- security review (round 2): "CANARY SUMMARYjunk ... fail=1 ..." must
# still be counted as a CANDIDATE line (no space required in the match),
# even though it's not itself well-formed -- so that a log containing this
# junk line PLUS one otherwise-valid env-only summary is rejected outright
# (more than one candidate line) instead of silently picking the valid-
# looking one and returning a false 4. Reproduced by security review: the
# prior match required a literal space after "SUMMARY", which "SUMMARYjunk"
# doesn't have, so it was invisible to the line count. -----------------
printf 'CANARY SUMMARY pass=5 fail=0 env_fail=2\n' > "$log"
assert_eq 4 "$(kit_canary_verdict "$log" 1)" "sanity: the valid env-only summary alone is still exit 4"
printf 'CANARY SUMMARYjunk ... fail=1 ...\nCANARY SUMMARY pass=5 fail=0 env_fail=2\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "a junk 'CANARY SUMMARY...' line alongside a valid one is refused (5), never the valid line's 4"
printf 'CANARY SUMMARYjunk pass=5 fail=0 env_fail=2\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "CANARY SUMMARYjunk alone (no space, not well-formed) is also 5"

# --- two well-formed summary lines in one log (e.g. a caller accidentally
# concatenated two runs) -- must refuse to pick either one. -----------------
printf 'CANARY SUMMARY pass=5 fail=0 env_fail=2\nCANARY SUMMARY pass=3 fail=0 env_fail=1\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "more than one CANARY SUMMARY line -> 5, never guesses which one"

# --- status says the round failed, but the summary claims nothing failed
# at all -- contradicts canaries_run's own return convention and must not
# be trusted either way. -----------------------------------------------------
printf 'CANARY SUMMARY pass=5 fail=0 env_fail=0\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 1)" "nonzero status with an all-zero summary is self-contradictory -> 5"

# --- security review (round 2): status 0 validated too -- a missing or
# malformed summary alongside a clean status must still be refused, not
# silently treated as success. ----------------------------------------------
: > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 0)" "status 0 with no summary line at all -> 5, never a silent 0"
printf 'CANARY SUMMARY pass=5 fail=0garbage env_fail=0\n' > "$log"
assert_eq 5 "$(kit_canary_verdict "$log" 0)" "status 0 with a malformed summary -> 5, never a silent 0"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
