#!/bin/bash
# tests/test_sync_repo.sh — tests for `kit-sync repo PATH [--dry-run]`.
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
KS="$PLUGIN_ROOT/bin/kit-sync"
FIX="$REPO_ROOT/tests/fixtures/sync-repo"

# Isolate HOME and ROUTING_KIT_HOME in mktmp directories.
HOME_TMP=$(mktmp)
RK_HOME_TMP=$(mktmp)
export HOME="$HOME_TMP"
export ROUTING_KIT_HOME="$RK_HOME_TMP"
export KIT_BOARD_NAME=sync-test

WORK=$(mktmp)
POINTER_EXPECTED="$WORK/pointer.expected"
printf '@AGENTS.md\n' > "$POINTER_EXPECTED"
COMMIT_MSG="Rules in AGENTS.md for all agents (routing kit)"

bytes_same() { cmp -s "$1" "$2"; }

init_repo() {
  local d
  d=$(mktmp)
  git -C "$d" init -q
  git -C "$d" config user.name "Test User"
  git -C "$d" config user.email "you@example.com"
  git -C "$d" config commit.gpgsign false
  echo "$d"
}

# ---- 1. CLAUDE.md only -----------------------------------------------------
r1=$(init_repo)
cp "$FIX/claude-only.md" "$r1/CLAUDE.md"
git -C "$r1" add CLAUDE.md
git -C "$r1" commit -q -m "initial"
c1_before=$(git -C "$r1" rev-list --count HEAD)

out1=$("$KS" repo "$r1" 2>&1); code1=$?
assert_eq 0 "$code1" "case 1: CLAUDE.md only exits 0"
[ -f "$r1/AGENTS.md" ] && bytes_same "$FIX/claude-only.md" "$r1/AGENTS.md" && pass || fail "case 1: AGENTS.md does not match old CLAUDE.md bytes"
[ -f "$r1/CLAUDE.md" ] && bytes_same "$POINTER_EXPECTED" "$r1/CLAUDE.md" && pass || fail "case 1: CLAUDE.md is not @AGENTS.md\\n"
c1_after=$(git -C "$r1" rev-list --count HEAD)
assert_eq $((c1_before + 1)) "$c1_after" "case 1: exactly one new commit"
assert_eq "$COMMIT_MSG" "$(git -C "$r1" log -1 --format=%s)" "case 1: commit message"
assert_eq "" "$(git -C "$r1" status --porcelain)" "case 1: working tree clean after"

# ---- 2. Both files present and identical -----------------------------------
r2=$(init_repo)
cp "$FIX/claude-only.md" "$r2/CLAUDE.md"
cp "$FIX/claude-only.md" "$r2/AGENTS.md"
git -C "$r2" add CLAUDE.md AGENTS.md
git -C "$r2" commit -q -m "initial"
c2_before=$(git -C "$r2" rev-list --count HEAD)

out2=$("$KS" repo "$r2" 2>&1); code2=$?
assert_eq 0 "$code2" "case 2: identical files exits 0"
[ -f "$r2/AGENTS.md" ] && bytes_same "$FIX/claude-only.md" "$r2/AGENTS.md" && pass || fail "case 2: AGENTS.md changed when identical to CLAUDE.md"
[ -f "$r2/CLAUDE.md" ] && bytes_same "$POINTER_EXPECTED" "$r2/CLAUDE.md" && pass || fail "case 2: CLAUDE.md is not @AGENTS.md\\n"
if grep -q -F "## From CLAUDE.md" "$r2/AGENTS.md" 2>/dev/null; then
  fail "case 2: AGENTS.md contains ## From CLAUDE.md line"
else
  pass
fi
c2_after=$(git -C "$r2" rev-list --count HEAD)
assert_eq $((c2_before + 1)) "$c2_after" "case 2: one new commit"
assert_eq "$COMMIT_MSG" "$(git -C "$r2" log -1 --format=%s)" "case 2: commit message"
assert_eq "" "$(git -C "$r2" status --porcelain)" "case 2: working tree clean after"

# ---- 3. Both present and different -----------------------------------------
r3=$(init_repo)
cp "$FIX/agents-diff.md" "$r3/AGENTS.md"
cp "$FIX/claude-diff.md" "$r3/CLAUDE.md"
git -C "$r3" add AGENTS.md CLAUDE.md
git -C "$r3" commit -q -m "initial"
c3_before=$(git -C "$r3" rev-list --count HEAD)

out3=$("$KS" repo "$r3" 2>&1); code3=$?
assert_eq 0 "$code3" "case 3: differing files exits 0"
[ -f "$r3/AGENTS.md" ] && bytes_same "$FIX/agents-merged.expected.md" "$r3/AGENTS.md" && pass || fail "case 3: AGENTS.md does not match expected merged fixture"
[ -f "$r3/CLAUDE.md" ] && bytes_same "$POINTER_EXPECTED" "$r3/CLAUDE.md" && pass || fail "case 3: CLAUDE.md is not @AGENTS.md\\n"
c3_after=$(git -C "$r3" rev-list --count HEAD)
assert_eq $((c3_before + 1)) "$c3_after" "case 3: one new commit"
assert_eq "$COMMIT_MSG" "$(git -C "$r3" log -1 --format=%s)" "case 3: commit message"
assert_eq "" "$(git -C "$r3" status --porcelain)" "case 3: working tree clean after"

# ---- 4. Already converted (run twice) --------------------------------------
r4=$(init_repo)
cp "$FIX/claude-only.md" "$r4/CLAUDE.md"
git -C "$r4" add CLAUDE.md
git -C "$r4" commit -q -m "initial"

"$KS" repo "$r4" >/dev/null 2>&1; code4_first=$?
assert_eq 0 "$code4_first" "case 4: first run exits 0"
head4_first=$(git -C "$r4" rev-parse HEAD)

out4=$("$KS" repo "$r4" 2>&1); code4_second=$?
assert_eq 0 "$code4_second" "case 4: second run exits 0"
assert_contains "$out4" "no changes" "case 4: second run prints no changes"
head4_second=$(git -C "$r4" rev-parse HEAD)
assert_eq "$head4_first" "$head4_second" "case 4: second run makes no new commit"
[ -f "$r4/AGENTS.md" ] && bytes_same "$FIX/claude-only.md" "$r4/AGENTS.md" && pass || fail "case 4: AGENTS.md unchanged on second run"
[ -f "$r4/CLAUDE.md" ] && bytes_same "$POINTER_EXPECTED" "$r4/CLAUDE.md" && pass || fail "case 4: CLAUDE.md unchanged on second run"

# ---- 5. Dirty tree (an uncommitted edit) -----------------------------------
r5=$(init_repo)
cp "$FIX/claude-only.md" "$r5/CLAUDE.md"
git -C "$r5" add CLAUDE.md
git -C "$r5" commit -q -m "initial"
printf -- '- Uncommitted local edit.\n' >> "$r5/CLAUDE.md"
cp "$r5/CLAUDE.md" "$WORK/r5-claude.dirty"
head5_before=$(git -C "$r5" rev-parse HEAD)

assert_exit 4 "case 5: dirty tree exits 4" -- "$KS" repo "$r5"
out5=$("$KS" repo "$r5" 2>&1); code5=$?
assert_eq 4 "$code5" "case 5: dirty tree exit code is 4"
assert_eq 1 "$(printf '%s\n' "$out5" | grep -c .)" "case 5: dirty tree refusal is one line"
[ ! -e "$r5/AGENTS.md" ] && pass || fail "case 5: dirty tree wrote AGENTS.md"
bytes_same "$WORK/r5-claude.dirty" "$r5/CLAUDE.md" && pass || fail "case 5: dirty tree changed CLAUDE.md"
assert_eq "$head5_before" "$(git -C "$r5" rev-parse HEAD)" "case 5: dirty tree made no commit"

# ---- 6. An extra worktree (git worktree add) -------------------------------
r6=$(init_repo)
cp "$FIX/claude-only.md" "$r6/CLAUDE.md"
git -C "$r6" add CLAUDE.md
git -C "$r6" commit -q -m "initial"
head6_before=$(git -C "$r6" rev-parse HEAD)
wt6_parent=$(mktmp)
wt6="$wt6_parent/extra-wt"
git -C "$r6" worktree add -q -b extra-wt-branch "$wt6"

out6=$("$KS" repo "$wt6" 2>&1); code6=$?
assert_eq 0 "$code6" "case 6: linked worktree converts"
bytes_same "$FIX/claude-only.md" "$wt6/AGENTS.md" && pass || fail "case 6: linked rules missing"
bytes_same "$POINTER_EXPECTED" "$wt6/CLAUDE.md" && pass || fail "case 6: linked pointer missing"
assert_eq "$COMMIT_MSG" "$(git -C "$wt6" log -1 --format=%s)" "case 6: linked commit"
assert_eq "$head6_before" "$(git -C "$wt6" rev-parse HEAD^)" "case 6: exactly one commit"
assert_eq "$head6_before" "$(git -C "$r6" rev-parse HEAD)" "case 6: main branch unchanged"
assert_eq '' "$(git -C "$wt6" status --porcelain)" "case 6: linked tree clean"
[ -f "$(git -C "$wt6" rev-parse --git-dir)/kit-sync.lock" ] && pass || fail "case 6: per-worktree lock missing"
[ ! -e "$r6/AGENTS.md" ] && pass || fail "case 6: main files unchanged"

# ---- 7. Repo skills: .claude/skills/foo/SKILL.md ---------------------------
r7=$(init_repo)
cp "$FIX/claude-only.md" "$r7/CLAUDE.md"
mkdir -p "$r7/.claude/skills/foo"
cp "$FIX/SKILL.md" "$r7/.claude/skills/foo/SKILL.md"
git -C "$r7" add CLAUDE.md .claude/skills/foo/SKILL.md
git -C "$r7" commit -q -m "initial"

out7=$("$KS" repo "$r7" 2>&1); code7=$?
assert_eq 0 "$code7" "case 7: repo skills sync exits 0"
[ -f "$r7/.agents/skills/foo/SKILL.md" ] && bytes_same "$FIX/SKILL.md" "$r7/.agents/skills/foo/SKILL.md" && pass || fail "case 7: .agents/skills/foo/SKILL.md missing or differs"
[ -L "$r7/.claude/skills/foo" ] && pass || fail "case 7: .claude/skills/foo is not a symlink"
link_target=$(readlink "$r7/.claude/skills/foo" 2>/dev/null || true)
case "$link_target" in
  ""|/*) fail "case 7: .claude/skills/foo is not a relative symlink ($link_target)" ;;
  *) pass ;;
esac
resolved_link=$(cd "$r7/.claude/skills/foo" 2>/dev/null && pwd -P || true)
resolved_agents=$(cd "$r7/.agents/skills/foo" 2>/dev/null && pwd -P || true)
if [ -n "$resolved_link" ] && [ -n "$resolved_agents" ] && [ "$resolved_link" = "$resolved_agents" ]; then
  pass
else
  fail "case 7: .claude/skills/foo target does not resolve to .agents/skills/foo ([$resolved_link] vs [$resolved_agents])"
fi
committed7=$(git -C "$r7" show --name-only --format= HEAD 2>/dev/null)
assert_contains "$committed7" ".agents/skills/foo/SKILL.md" "case 7: .agents/skills/foo/SKILL.md is in the commit"
assert_contains "$(git -C "$r7" ls-tree HEAD .claude/skills/foo 2>/dev/null)" "120000" "case 7: .claude/skills/foo symlink is in the commit"
assert_eq "$COMMIT_MSG" "$(git -C "$r7" log -1 --format=%s)" "case 7: commit message"
assert_eq "" "$(git -C "$r7" status --porcelain)" "case 7: working tree clean after"

# ---- 8. --dry-run ----------------------------------------------------------
r8=$(init_repo)
cp "$FIX/claude-only.md" "$r8/CLAUDE.md"
mkdir -p "$r8/.claude/skills/foo"
cp "$FIX/SKILL.md" "$r8/.claude/skills/foo/SKILL.md"
git -C "$r8" add CLAUDE.md .claude/skills/foo/SKILL.md
git -C "$r8" commit -q -m "initial"
head8_before=$(git -C "$r8" rev-parse HEAD)

out8=$("$KS" repo "$r8" --dry-run 2>&1); code8=$?
assert_eq 0 "$code8" "case 8: --dry-run exits 0"
assert_contains "$out8" "AGENTS.md" "case 8: --dry-run output names AGENTS.md"
assert_contains "$out8" "CLAUDE.md" "case 8: --dry-run output names CLAUDE.md"
assert_contains "$out8" "foo" "case 8: --dry-run output names skill foo"
[ ! -e "$r8/AGENTS.md" ] && pass || fail "case 8: --dry-run created AGENTS.md"
[ ! -e "$r8/.agents" ] && pass || fail "case 8: --dry-run created .agents"
[ ! -L "$r8/.claude/skills/foo" ] && [ -d "$r8/.claude/skills/foo" ] && pass || fail "case 8: --dry-run modified .claude/skills/foo directory"
bytes_same "$FIX/claude-only.md" "$r8/CLAUDE.md" && pass || fail "case 8: --dry-run modified CLAUDE.md bytes"
bytes_same "$FIX/SKILL.md" "$r8/.claude/skills/foo/SKILL.md" && pass || fail "case 8: --dry-run modified SKILL.md bytes"
assert_eq "$head8_before" "$(git -C "$r8" rev-parse HEAD)" "case 8: --dry-run leaves HEAD unchanged"
assert_eq "" "$(git -C "$r8" status --porcelain)" "case 8: --dry-run leaves tree clean"

# ---- 9. CLAUDE.md already imports AGENTS.md plus Claude-only lines --------
r9=$(init_repo)
printf '# Rules\n- shared\n' > "$r9/AGENTS.md"
printf '@AGENTS.md\n- claude only\n' > "$r9/CLAUDE.md"
git -C "$r9" add AGENTS.md CLAUDE.md
git -C "$r9" commit -q -m "initial"
"$KS" repo "$r9" >/dev/null 2>&1
assert_eq "$(printf '# Rules\n- shared\n## From CLAUDE.md\n- claude only')" "$(cat "$r9/AGENTS.md")" "case 9: import line not copied into AGENTS.md"

# ---- 10. Ignored skill folder: left alone, never committed -----------------
r10=$(init_repo)
cp "$FIX/claude-only.md" "$r10/CLAUDE.md"
mkdir -p "$r10/.claude/skills/kept" "$r10/.claude/skills/private"
cp "$FIX/SKILL.md" "$r10/.claude/skills/kept/SKILL.md"
printf 'secret\n' > "$r10/.claude/skills/private/SKILL.md"
printf '.claude/skills/private/\n' > "$r10/.gitignore"
git -C "$r10" add CLAUDE.md .gitignore .claude/skills/kept/SKILL.md
git -C "$r10" commit -q -m "initial"
out10=$("$KS" repo "$r10" 2>&1); code10=$?
assert_eq 0 "$code10" "case 10: exits 0"
assert_contains "$out10" "skipped skill private" "case 10: ignored skill named as skipped"
[ -d "$r10/.claude/skills/private" ] && [ ! -L "$r10/.claude/skills/private" ] && pass || fail "case 10: ignored skill was moved"
[ -L "$r10/.claude/skills/kept" ] && pass || fail "case 10: tracked skill not moved"
case "$(git -C "$r10" ls-files)" in *private*) fail "case 10: ignored skill was committed";; *) pass;; esac

# Shared instruction lines under differing headings must survive.
r11=$(init_repo)
printf '## Production\n- Require approval\n' > "$r11/AGENTS.md"
printf '## Deployment\n- Require approval\n' > "$r11/CLAUDE.md"
git -C "$r11" add .
git -C "$r11" commit -q -m initial
"$KS" repo "$r11" >/dev/null 2>&1
assert_eq 2 "$(grep -c 'Require approval' "$r11/AGENTS.md")" "case 11: complete sections survive"

r12=$(init_repo)
mkdir -p "$r12/.claude/skills/foo"
printf 'reference\n' > "$r12/.claude/skills/foo/reference.md"
printf '.agents/skills/foo/reference.md\n' > "$r12/.gitignore"
git -C "$r12" add .
git -C "$r12" commit -q -m initial
out12=$("$KS" repo "$r12" 2>&1)
assert_contains "$out12" "skipped skill foo" "case 12: ignored destination file skips skill"
[ -f "$r12/.claude/skills/foo/reference.md" ] && [ ! -L "$r12/.claude/skills/foo" ] && pass || fail "case 12: source preserved"

# Inject concurrent staging at git add, after the initial clean check.
r13=$(init_repo)
printf 'rules\n' > "$r13/CLAUDE.md"
git -C "$r13" add .
git -C "$r13" commit -q -m initial
shim=$(mktmp)
real_git=$(command -v git)
cat > "$shim/git" <<EOF
#!/bin/bash
if [ "\$3" = add ]; then
  printf 'private\n' > "\$2/private.txt"
  "$real_git" -C "\$2" add private.txt
fi
exec "$real_git" "\$@"
EOF
chmod +x "$shim/git"
PATH="$shim:$PATH" "$KS" repo "$r13" >/dev/null 2>&1
assert_eq '' "$(git -C "$r13" ls-tree HEAD private.txt)" "case 13: concurrent staged file excluded"
assert_contains "$(git -C "$r13" diff --cached --name-only)" private.txt "case 13: concurrent staging preserved"

# Fenced headings belong to their surrounding section.
for fence in '```' '~~~'; do
  r14=$(init_repo)
  printf '# Existing\n%s shell\n# shared\necho hello\n%s\n' "$fence" "$fence" > "$r14/AGENTS.md"
  printf '# Deployment\n%s shell\n# shared\necho hello\n%s\n' "$fence" "$fence" > "$r14/CLAUDE.md"
  cat "$r14/AGENTS.md" > "$WORK/fenced.expected"
  printf '## From CLAUDE.md\n' >> "$WORK/fenced.expected"
  cat "$r14/CLAUDE.md" >> "$WORK/fenced.expected"
  git -C "$r14" add .
  git -C "$r14" commit -q -m initial
  "$KS" repo "$r14" >/dev/null 2>&1
  bytes_same "$WORK/fenced.expected" "$r14/AGENTS.md" && pass || fail "case 14: $fence preserves complete fenced sections"
done

# Both dangling and resolving symlinks must have their destinations checked.
for target in missing SKILL.md; do
  r15=$(init_repo)
  mkdir -p "$r15/.claude/skills/foo"
  printf 'skill\n' > "$r15/.claude/skills/foo/SKILL.md"
  ln -s "$target" "$r15/.claude/skills/foo/reference"
  printf '.agents/skills/foo/reference\n' > "$r15/.gitignore"
  git -C "$r15" add .
  git -C "$r15" commit -q -m initial
  before15=$(git -C "$r15" rev-parse HEAD)
  out15=$("$KS" repo "$r15" 2>&1); code15=$?
  assert_eq 0 "$code15" "case 15: $target exits successfully"
  assert_contains "$out15" 'skipped skill foo' "case 15: $target destination skips skill"
  assert_eq "$before15" "$(git -C "$r15" rev-parse HEAD)" "case 15: $target source remains committed"
  [ -L "$r15/.claude/skills/foo/reference" ] && [ ! -L "$r15/.claude/skills/foo" ] && pass || fail "case 15: $target source preserved"
done

# Git failures outside a repository give a single clear refusal.
not_repo=$(mktmp)
out16=$("$KS" repo "$not_repo" 2>&1); code16=$?
assert_eq 2 "$code16" "case 16: git failure exits 2"
assert_contains "$out16" 'refused:' "case 16: clear refusal"
assert_eq 1 "$(printf '%s\n' "$out16" | grep -c .)" "case 16: one-line git failure"

# Another session blocks conversion; force bypasses only the claim.
r17=$(init_repo)
printf 'rules\n' > "$r17/CLAUDE.md"
git -C "$r17" add .
git -C "$r17" commit -q -m initial
KB="$PLUGIN_ROOT/bin/kit-board"
KIT_BOARD_NAME=other "$KB" post --repo "$r17" --kind claim "editing rules" >/dev/null
before17=$(git -C "$r17" rev-parse HEAD)
out17=$("$KS" repo "$r17" 2>&1); code17=$?
assert_eq 3 "$code17" "case 17: other claim refuses"
assert_contains "$out17" "other" "case 17: names claimer"
assert_contains "$out17" "editing rules" "case 17: names claim"
assert_eq 1 "$(printf '%s\n' "$out17" | grep -c .)" "case 17: one line"
assert_eq "$before17" "$(git -C "$r17" rev-parse HEAD)" "case 17: no commit"
"$KS" repo "$r17" --force >/dev/null 2>&1; code17=$?
assert_eq 0 "$code17" "case 17: force converts"
note17="kit-sync repo converted this repo's rule files (commit $(git -C "$r17" rev-parse HEAD))"
notes17=$("$KB" read --repo "$r17" --peek)
assert_contains "$notes17" "$note17" "case 17: conversion note has commit"
assert_eq 1 "$(printf '%s\n' "$notes17" | grep -c 'kit-sync repo converted')" "case 17: exactly one note"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
