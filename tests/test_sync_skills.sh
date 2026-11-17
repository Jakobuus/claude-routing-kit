#!/bin/bash
# tests/test_sync_skills.sh — tests for `kit-sync skills`.
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
KS="$PLUGIN_ROOT/bin/kit-sync"
FIXTURES="$REPO_ROOT/tests/fixtures/skills"
JQ=/usr/bin/jq; [ -x "$JQ" ] || JQ=jq

SAFE=$(mktmp)
export HOME="$SAFE/home" CODEX_HOME="$SAFE/codex-home" ROUTING_KIT_HOME="$SAFE/kit-home"
mkdir -p "$HOME" "$CODEX_HOME" "$ROUTING_KIT_HOME"

write_profile() {
  local kh="$1"; shift
  local skills_json="["
  local sep=""
  local s
  for s in "$@"; do
    skills_json="${skills_json}${sep}\"${s}\""
    sep=","
  done
  skills_json="${skills_json}]"
  mkdir -p "$kh"
  printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"skills":%s}\n' "$skills_json" > "$kh/profile.json"
}

# ---- 1. Kit skills and profile skills linked; Claude links; skills.json -----
c1_home=$(mktmp); c1_codex=$(mktmp); c1_kh=$(mktmp)
c1_claude=$(mktmp); c1_gemini=$(mktmp); c1_agents=$(mktmp)
export HOME="$c1_home" CODEX_HOME="$c1_codex" ROUTING_KIT_HOME="$c1_kh"
write_profile "$c1_kh" "$FIXTURES/good-alpha" "$FIXTURES/good-beta"

assert_exit 0 "case 1: kit-sync skills exits 0" -- \
  "$KS" skills --home-claude "$c1_claude" --home-gemini "$c1_gemini" --agents-dir "$c1_agents"

for sk in "$PLUGIN_ROOT"/skills/*; do
  [ -d "$sk" ] || continue
  sk_name=$(basename "$sk")
  assert_eq "$sk" "$(readlink "$c1_agents/$sk_name")" "case 1: kit skill $sk_name linked in agents dir"
  assert_eq "$c1_agents/$sk_name" "$(readlink "$c1_claude/skills/$sk_name")" "case 1: claude link for kit skill $sk_name points at agents dir entry"
done
assert_eq "$FIXTURES/good-alpha" "$(readlink "$c1_agents/good-alpha")" "case 1: profile skill good-alpha linked in agents dir"
assert_eq "$FIXTURES/good-beta" "$(readlink "$c1_agents/good-beta")" "case 1: profile skill good-beta linked in agents dir"
assert_eq "$c1_agents/good-alpha" "$(readlink "$c1_claude/skills/good-alpha")" "case 1: claude link for good-alpha points at agents dir entry"
assert_eq "$c1_agents/good-beta" "$(readlink "$c1_claude/skills/good-beta")" "case 1: claude link for good-beta points at agents dir entry"
[ -f "$c1_gemini/config/skills.json" ] && pass || fail "case 1: gemini config/skills.json not created"
assert_eq 1 "$("$JQ" --arg p "$c1_agents" '[.entries[]? | select(.path == $p)] | length' "$c1_gemini/config/skills.json" 2>/dev/null)" "case 1: skills.json holds our agents-dir entry once"

# ---- 2. Missing profile path -> one warning line naming it; others linked ---
c2_home=$(mktmp); c2_codex=$(mktmp); c2_kh=$(mktmp)
c2_claude=$(mktmp); c2_gemini=$(mktmp); c2_agents=$(mktmp)
c2_missing="$c2_home/no-such-skill-dir"
export HOME="$c2_home" CODEX_HOME="$c2_codex" ROUTING_KIT_HOME="$c2_kh"
write_profile "$c2_kh" "$FIXTURES/good-alpha" "$c2_missing" "$FIXTURES/good-beta"

out=$("$KS" skills --home-claude "$c2_claude" --home-gemini "$c2_gemini" --agents-dir "$c2_agents" 2>&1)
code=$?
assert_eq 0 "$code" "case 2: missing profile path still exits 0"
assert_contains "$out" "$c2_missing" "case 2: warning names the missing profile path"
warn_count=$(printf '%s\n' "$out" | grep -c -F -- "$c2_missing" || true)
assert_eq 1 "$warn_count" "case 2: exactly one warning line naming the missing path"
assert_eq "$PLUGIN_ROOT/skills/ask-advisers" "$(readlink "$c2_agents/ask-advisers")" "case 2: kit skill ask-advisers still linked"
assert_eq "$FIXTURES/good-alpha" "$(readlink "$c2_agents/good-alpha")" "case 2: good-alpha still linked in agents dir"
assert_eq "$FIXTURES/good-beta" "$(readlink "$c2_agents/good-beta")" "case 2: good-beta still linked in agents dir"
assert_eq "$c2_agents/good-alpha" "$(readlink "$c2_claude/skills/good-alpha")" "case 2: good-alpha linked in claude skills"
assert_eq "$c2_agents/good-beta" "$(readlink "$c2_claude/skills/good-beta")" "case 2: good-beta linked in claude skills"

# ---- 3. Real folder <claude-home>/skills/<name> untouched -------------------
c3_home=$(mktmp); c3_codex=$(mktmp); c3_kh=$(mktmp)
c3_claude=$(mktmp); c3_gemini=$(mktmp); c3_agents=$(mktmp)
export HOME="$c3_home" CODEX_HOME="$c3_codex" ROUTING_KIT_HOME="$c3_kh"
mkdir -p "$c3_claude/skills/good-alpha"
printf 'custom user skill\n' > "$c3_claude/skills/good-alpha/SKILL.md"
printf 'keep me\n' > "$c3_claude/skills/good-alpha/extra.txt"
write_profile "$c3_kh" "$FIXTURES/good-alpha" "$FIXTURES/good-beta"

out=$("$KS" skills --home-claude "$c3_claude" --home-gemini "$c3_gemini" --agents-dir "$c3_agents" 2>&1)
code=$?
assert_eq 0 "$code" "case 3: exits 0 when real skill folder exists in claude home"
assert_contains "$out" "kept your own good-alpha" "case 3: output says kept your own good-alpha"
[ -d "$c3_claude/skills/good-alpha" ] && [ ! -L "$c3_claude/skills/good-alpha" ] && pass || fail "case 3: real folder in claude skills was replaced or became a symlink"
assert_eq "custom user skill" "$(cat "$c3_claude/skills/good-alpha/SKILL.md" 2>/dev/null)" "case 3: real folder SKILL.md untouched"
assert_eq "keep me" "$(cat "$c3_claude/skills/good-alpha/extra.txt" 2>/dev/null)" "case 3: real folder extra.txt untouched"
assert_eq "$FIXTURES/good-alpha" "$(readlink "$c3_agents/good-alpha")" "case 3: good-alpha still linked in agents dir"
assert_eq "$c3_agents/good-beta" "$(readlink "$c3_claude/skills/good-beta")" "case 3: non-conflicting skill good-beta linked in claude skills"

# ---- 4 & 4b. Existing skills.json entries kept; plugin skill not in claude --
c4_home=$(mktmp); c4_codex=$(mktmp); c4_kh=$(mktmp)
c4_claude=$(mktmp); c4_gemini=$(mktmp); c4_agents=$(mktmp)
export HOME="$c4_home" CODEX_HOME="$c4_codex" ROUTING_KIT_HOME="$c4_kh"
mkdir -p "$c4_gemini/config"
cat > "$c4_gemini/config/skills.json" <<'EOF'
{"entries":[{"path":"/opt/other-skills-one"},{"path":"/opt/other-skills-two"}]}
EOF
c4_plugin_skill="$c4_claude/plugins/some-plugin/skills/good-beta"
mkdir -p "$(dirname "$c4_plugin_skill")"
cp -R "$FIXTURES/good-beta" "$c4_plugin_skill"
write_profile "$c4_kh" "$FIXTURES/good-alpha" "$c4_plugin_skill"

out=$("$KS" skills --home-claude "$c4_claude" --home-gemini "$c4_gemini" --agents-dir "$c4_agents" 2>&1)
code=$?
assert_eq 0 "$code" "case 4: exits 0"
assert_eq 3 "$("$JQ" '.entries | length' "$c4_gemini/config/skills.json" 2>/dev/null)" "case 4: skills.json has 3 entries total"
assert_eq "/opt/other-skills-one" "$("$JQ" -r '.entries[0].path' "$c4_gemini/config/skills.json" 2>/dev/null)" "case 4: first existing skills.json entry kept in order"
assert_eq "/opt/other-skills-two" "$("$JQ" -r '.entries[1].path' "$c4_gemini/config/skills.json" 2>/dev/null)" "case 4: second existing skills.json entry kept in order"
assert_eq "$c4_agents" "$("$JQ" -r '.entries[2].path' "$c4_gemini/config/skills.json" 2>/dev/null)" "case 4: our agents-dir entry added after existing entries"
assert_eq 1 "$("$JQ" --arg p "$c4_agents" '[.entries[]? | select(.path == $p)] | length' "$c4_gemini/config/skills.json" 2>/dev/null)" "case 4: our entry appears exactly once"

# 4b: profile skill under <claude-home>/plugins/... -> in agents dir, not in <claude-home>/skills/
assert_eq "$c4_plugin_skill" "$(readlink "$c4_agents/good-beta")" "case 4b: plugin skill linked in agents dir"
if [ -e "$c4_claude/skills/good-beta" ] || [ -L "$c4_claude/skills/good-beta" ]; then
  fail "case 4b: skill under claude-home/plugins must not be linked in claude-home/skills"
else
  pass
fi
assert_eq "$c4_agents/good-alpha" "$(readlink "$c4_claude/skills/good-alpha")" "case 4b: non-plugin profile skill linked in claude-home/skills"

# ---- 5. Second run -> nothing changes, output contains "no changes" ---------
c5_snap=$(mktmp)
cp "$c4_gemini/config/skills.json" "$c5_snap/skills.json.before" 2>/dev/null || : > "$c5_snap/skills.json.before"
out=$("$KS" skills --home-claude "$c4_claude" --home-gemini "$c4_gemini" --agents-dir "$c4_agents" 2>&1)
code=$?
assert_eq 0 "$code" "case 5: second run exits 0"
assert_contains "$out" "no changes" "case 5: second run output contains no changes"
if [ -f "$c4_gemini/config/skills.json" ] && cmp -s "$c5_snap/skills.json.before" "$c4_gemini/config/skills.json"; then
  pass
else
  fail "case 5: skills.json bytes changed on second run"
fi
assert_eq "$PLUGIN_ROOT/skills/ask-advisers" "$(readlink "$c4_agents/ask-advisers")" "case 5: ask-advisers link unchanged in agents dir"
assert_eq "$FIXTURES/good-alpha" "$(readlink "$c4_agents/good-alpha")" "case 5: good-alpha link unchanged in agents dir"
assert_eq "$c4_plugin_skill" "$(readlink "$c4_agents/good-beta")" "case 5: good-beta link unchanged in agents dir"
assert_eq "$c4_agents/good-alpha" "$(readlink "$c4_claude/skills/good-alpha")" "case 5: claude good-alpha link unchanged"

# ---- 6. --undo -> removes only what we made; keeps user folders/entries/links
c6_home=$(mktmp); c6_codex=$(mktmp); c6_kh=$(mktmp)
c6_claude=$(mktmp); c6_gemini=$(mktmp); c6_agents=$(mktmp)
c6_hand_target=$(mktmp)
export HOME="$c6_home" CODEX_HOME="$c6_codex" ROUTING_KIT_HOME="$c6_kh"

mkdir -p "$c6_claude/skills/good-alpha"
printf 'custom user skill\n' > "$c6_claude/skills/good-alpha/SKILL.md"
printf 'keep me\n' > "$c6_claude/skills/good-alpha/extra.txt"

mkdir -p "$c6_gemini/config"
cat > "$c6_gemini/config/skills.json" <<'EOF'
{"entries":[{"path":"/opt/other-skills-one"},{"path":"/opt/other-skills-two"}]}
EOF

ln -s "$c6_hand_target" "$c6_agents/user-handmade"
ln -s "$c6_hand_target" "$c6_claude/skills/user-handmade"

write_profile "$c6_kh" "$FIXTURES/good-alpha" "$FIXTURES/good-beta"
"$KS" skills --home-claude "$c6_claude" --home-gemini "$c6_gemini" --agents-dir "$c6_agents" >/dev/null 2>&1
assert_eq "$FIXTURES/good-beta" "$(readlink "$c6_agents/good-beta")" "case 6 setup: good-beta linked before undo"
assert_eq 1 "$("$JQ" --arg p "$c6_agents" '[.entries[]? | select(.path == $p)] | length' "$c6_gemini/config/skills.json" 2>/dev/null)" "case 6 setup: our skills.json entry present before undo"

assert_exit 0 "case 6: kit-sync skills --undo exits 0" -- \
  "$KS" skills --undo --home-claude "$c6_claude" --home-gemini "$c6_gemini" --agents-dir "$c6_agents"

for removed in "$c6_agents/ask-advisers" "$c6_agents/good-alpha" "$c6_agents/good-beta" \
               "$c6_claude/skills/ask-advisers" "$c6_claude/skills/good-beta"; do
  if [ -e "$removed" ] || [ -L "$removed" ]; then
    fail "case 6: undo did not remove $removed"
  else
    pass
  fi
done

assert_eq 0 "$("$JQ" --arg p "$c6_agents" '[.entries[]? | select(.path == $p)] | length' "$c6_gemini/config/skills.json" 2>/dev/null)" "case 6: our skills.json entry removed"
assert_eq 2 "$("$JQ" '.entries | length' "$c6_gemini/config/skills.json" 2>/dev/null)" "case 6: two other skills.json entries kept"
assert_eq "/opt/other-skills-one" "$("$JQ" -r '.entries[0].path' "$c6_gemini/config/skills.json" 2>/dev/null)" "case 6: first other skills.json entry still there"
assert_eq "/opt/other-skills-two" "$("$JQ" -r '.entries[1].path' "$c6_gemini/config/skills.json" 2>/dev/null)" "case 6: second other skills.json entry still there"

[ -d "$c6_claude/skills/good-alpha" ] && [ ! -L "$c6_claude/skills/good-alpha" ] && pass || fail "case 6: real folder good-alpha missing or symlink after undo"
assert_eq "custom user skill" "$(cat "$c6_claude/skills/good-alpha/SKILL.md" 2>/dev/null)" "case 6: real folder SKILL.md intact after undo"
assert_eq "keep me" "$(cat "$c6_claude/skills/good-alpha/extra.txt" 2>/dev/null)" "case 6: real folder extra.txt intact after undo"

assert_eq "$c6_hand_target" "$(readlink "$c6_agents/user-handmade")" "case 6: user hand-made link in agents dir still there"
assert_eq "$c6_hand_target" "$(readlink "$c6_claude/skills/user-handmade")" "case 6: user hand-made link in claude skills still there"

# ---- 7. Skill whose SKILL.md lacks name or description -> skipped with warning
c7_home=$(mktmp); c7_codex=$(mktmp); c7_kh=$(mktmp)
c7_claude=$(mktmp); c7_gemini=$(mktmp); c7_agents=$(mktmp)
export HOME="$c7_home" CODEX_HOME="$c7_codex" ROUTING_KIT_HOME="$c7_kh"
write_profile "$c7_kh" "$FIXTURES/missing-name" "$FIXTURES/missing-desc" "$FIXTURES/good-alpha"

out=$("$KS" skills --home-claude "$c7_claude" --home-gemini "$c7_gemini" --agents-dir "$c7_agents" 2>&1)
code=$?
assert_eq 0 "$code" "case 7: exits 0 when skills with invalid frontmatter are skipped"
assert_contains "$out" "missing-name" "case 7: warning names skill missing name frontmatter"
assert_contains "$out" "missing-desc" "case 7: warning names skill missing description frontmatter"
for bad_skill in missing-name missing-desc; do
  if [ -e "$c7_agents/$bad_skill" ] || [ -L "$c7_agents/$bad_skill" ]; then
    fail "case 7: $bad_skill was linked in agents dir"
  else
    pass
  fi
  if [ -e "$c7_claude/skills/$bad_skill" ] || [ -L "$c7_claude/skills/$bad_skill" ]; then
    fail "case 7: $bad_skill was linked in claude skills dir"
  else
    pass
  fi
done
assert_eq "$FIXTURES/good-alpha" "$(readlink "$c7_agents/good-alpha")" "case 7: valid skill good-alpha still linked in agents dir"
assert_eq "$c7_agents/good-alpha" "$(readlink "$c7_claude/skills/good-alpha")" "case 7: valid skill good-alpha still linked in claude skills"


# Review regressions: isolated Python sandboxes, one case per finding.
python3 - "$PLUGIN_ROOT/lib/sync_skills.py" "$FIXTURES" <<'PYTEST'
import importlib.util, pathlib, tempfile, os, json, sys
spec = importlib.util.spec_from_file_location("sync", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fixture = sys.argv[2]
for case in range(1, 10):
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d).resolve()
        kh = root / "kit"; kh.mkdir()
        c = root / "claude"; c.mkdir()
        a = root / "agents"; a.mkdir()
        g = root / "gemini"; (g / "config").mkdir(parents=True)
        state = str(kh / "sync-state.json")
        sj = g / "config/skills.json"
        opts = dict(dry_run=False, home_claude=str(c), home_gemini=str(g), agents_dir=str(a))
        (kh / "profile.json").write_text(json.dumps({"skills":[fixture + "/good-alpha"]}))
        def sync(): return m.run_sync(opts, str(root / "empty"), str(kh), state)
        def undo(): return m.run_undo(opts, state)
        if case == 1:
            (c / "skills").mkdir()
            for link, target in [(a / "good-alpha", fixture + "/good-alpha"),
                                 (c / "skills/good-alpha", "../../missing")]:
                link.symlink_to(target)
            sync(); undo()
            assert os.readlink(a / "good-alpha") == fixture + "/good-alpha"
            assert os.readlink(c / "skills/good-alpha") == "../../missing"
        elif case == 2:
            (c / "skills").symlink_to(a)
            sync(); sync()
            assert (a / "good-alpha").resolve() == pathlib.Path(fixture + "/good-alpha").resolve()
        elif case == 3:
            for bad in ['// mine', '[]', '{"entries":{}}']:
                sj.write_text(bad)
                try: sync()
                except ValueError: pass
                else: raise AssertionError("invalid skills JSON accepted")
                assert sj.read_text() == bad
        elif case == 4:
            for bad in ['{"files":{},}', '[]']:
                pathlib.Path(state).write_text(bad)
                for action in [sync, undo]:
                    try: action()
                    except ValueError: pass
                    else: raise AssertionError("invalid state accepted")
                    assert pathlib.Path(state).read_text() == bad
        elif case == 5:
            original = json.dumps({"entries":[{"path":str(a)}]})
            sj.write_text(original)
            undo(); sync(); undo(); undo()
            assert sj.read_text() == original
        elif case == 6:
            for path in [sj, pathlib.Path(state)]:
                backing = root / (path.name + ".backing")
                backing.write_text('{}'); backing.chmod(0o640)
                path.symlink_to(backing)
                m.write_json_atomic(str(path), {"files":{}})
                assert path.is_symlink()
                assert backing.stat().st_mode & 0o777 == 0o640
                assert json.loads(backing.read_text()) == {"files":{}}
        elif case == 7:
            prev = os.getcwd()
            try:
                os.chdir(root)
                parsed = m.parse_args(["--agents-dir","agents","--home-claude","claude","--home-gemini","gemini"])
                assert parsed["agents_dir"] == str(a)
                (kh / "profile.json").write_text('{"skills":["agents/good-alpha"]}')
                (a / "good-alpha").symlink_to(fixture + "/good-alpha")
                assert m.discover_skills(str(root / "empty"), str(kh))[0][1] == str(a / "good-alpha")
            finally: os.chdir(prev)
        elif case == 8:
            (c / "skills").symlink_to(root / "missing/skills")
            try: sync()
            except OSError: pass
            else: raise AssertionError("expected failure")
            assert (a / "good-alpha").is_symlink()
            undo()
            assert not (a / "good-alpha").is_symlink()
        elif case == 9:
            alias = root / "alias"; alias.symlink_to(a)
            sj.write_text(json.dumps({"entries":[{"path":str(alias) + "/"}]}))
            sync()
            assert len(json.loads(sj.read_text())["entries"]) == 1
    print("review finding", case, "passed")
PYTEST
assert_eq 0 "$?" "review regressions: all nine findings"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
