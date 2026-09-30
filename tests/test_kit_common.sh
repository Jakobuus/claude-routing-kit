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

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
