#!/bin/bash
# tests/test_cleanup_checks.sh -- the copy an agent worked in is DELETED when its work is saved
# and MOVED to <kit home>/retained (with a reason) otherwise. lib/export.sh run_cleanup_checked:
#   (a) build.patch saved and applies to the base commit, or a checked "no changes"
#   (b) nothing in the copy outside the patch (ignored file, file written after the patch)
#   (c) no agent still open in it
# Cases run the shared function directly, then through each builder with stubs: direct Codex,
# Gemini, locked-build (macOS) and kit-selftest. Every kit home is a temp dir.
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BIN="$ROOT/plugins/routing-kit/bin"
export ROUTING_KIT_HOME=$(mktmp)/lib-home
. "$BIN/kit-common"
. "$ROOT/plugins/routing-kit/lib/export.sh"

mk_src_repo() {
  local d
  d=$(mktmp)
  git -C "$d" init -q
  git -C "$d" config user.email you@example.com
  git -C "$d" config user.name "Test User"
  echo hello > "$d/a.txt"
  echo '*.log' > "$d/.gitignore"
  git -C "$d" add a.txt .gitignore
  git -C "$d" commit -q -m init
  echo "$d"
}

# --- the shared function, case by case ---------------------------------------
# libcase NAME -- runs in a subshell with its own kit home; prints
#   result=<deleted|kept> wt=<yes|no> retained=<yes|no> why=<the note's why line>
libcase() {
  (
    local name="$1" repo home run base
    repo=$(mk_src_repo)
    home=$(mktmp)
    export ROUTING_KIT_HOME="$home"
    KIT_HOME="$home"
    base=$(git -C "$repo" rev-parse HEAD)
    run=$(run_export "$repo" "$name") || { echo "export failed"; exit 1; }
    if [ "$name" = nostart ]; then
      run_cleanup_own "$run" "case ended" "$repo" "$base"
    else
      run_agent_started "$run"
      case "$name" in
        clean|open)
          echo new > "$run/wt/new.txt"; echo changed >> "$run/wt/a.txt"
          run_build_patch "$run/wt" ;;
        nochange)
          run_build_patch "$run/wt" ;;
        nopatch)
          echo new > "$run/wt/new.txt" ;;
        badpatch)
          echo changed > "$run/wt/a.txt"
          run_build_patch "$run/wt"
          sed 's/^-hello$/-not hello/' "$run/build.patch" > "$run/build.patch.x" && mv "$run/build.patch.x" "$run/build.patch" ;;
        ignored)
          echo new > "$run/wt/new.txt"; echo secret > "$run/wt/debug.log"
          run_build_patch "$run/wt" ;;
        untracked)
          echo new > "$run/wt/new.txt"
          run_build_patch "$run/wt"
          sleep 1.1
          echo late > "$run/wt/late.txt" ;;
        overwrite)
          run_build_patch "$run/wt"
          echo overwritten > "$run/wt/a.txt"; touch -t 202001010000 "$run/wt/a.txt" ;;
        removed)
          run_build_patch "$run/wt"
          rm "$run/wt/a.txt" ;;
        stash)
          echo stashed-work >> "$run/wt/a.txt"
          git -C "$run/wt" -c user.name=a -c user.email=a@b stash push -q
          run_build_patch "$run/wt" ;;
        branch)
          git -C "$run/wt" branch alt
          run_build_patch "$run/wt" ;;
        unreadable)
          run_build_patch "$run/wt"
          mkdir "$run/wt/hidden"; echo work > "$run/wt/hidden/work.log"; chmod 000 "$run/wt/hidden" ;;
        modified-late)
          echo new > "$run/wt/new.txt"
          run_build_patch "$run/wt"
          sleep 1.1
          echo late >> "$run/wt/a.txt" ;;
      esac
      if [ "$name" = open ]; then
        run_cleanup_checked "$run" "case ended" "$repo" "$base" "agent abc is still running"
      else
        run_cleanup_checked "$run" "case ended" "$repo" "$base"
      fi
    fi
    printf 'result=%s wt=%s retained=%s why=%s\n' "${RUN_CLEANUP_RESULT:-unset}" \
      "$([ -e "$run/wt" ] && echo yes || echo no)" \
      "$([ -d "$home/retained/$(basename "$run")" ] && echo yes || echo no)" \
      "$(grep '^why=' "$home/retained/$(basename "$run").why" 2>/dev/null | head -1)"
  )
}

out=$(libcase clean)
assert_contains "$out" "result=deleted wt=no retained=no" "clean run: the copy is deleted"
out=$(libcase nochange)
assert_contains "$out" "result=deleted wt=no retained=no" "a checked 'no changes' run: the copy is deleted"
out=$(libcase nostart)
assert_contains "$out" "result=deleted wt=no retained=no" "a copy no agent started in is deleted"

out=$(libcase nopatch)
assert_contains "$out" "result=kept wt=no retained=yes" "(a) no build.patch: the copy is retained"
assert_contains "$out" "no build.patch saved" "(a) no build.patch: the note says why"
out=$(libcase badpatch)
assert_contains "$out" "result=kept wt=no retained=yes" "(a) a patch that does not apply to the base: retained"
assert_contains "$out" "does not apply to the base commit" "(a) bad patch: the note says why"
out=$(libcase ignored)
assert_contains "$out" "result=kept wt=no retained=yes" "(b) an ignored file the patch does not hold: retained"
assert_contains "$out" "debug.log (ignored by git, not in build.patch)" "(b) ignored file: the note names it"
out=$(libcase untracked)
assert_contains "$out" "result=kept wt=no retained=yes" "(b) an untracked file written after the patch: retained"
assert_contains "$out" "no longer matches build.patch" "(b) late file: the note says the copy changed after the patch"
out=$(libcase modified-late)
assert_contains "$out" "result=kept wt=no retained=yes" "(b) a tracked file changed after the patch: retained"
assert_contains "$out" "no longer matches build.patch" "(b) late change: the note says the copy changed after the patch"
# Astra review of 0a83f4e: content, not names or times.
out=$(libcase overwrite)
assert_contains "$out" "result=kept wt=no retained=yes" "a tracked file overwritten after the patch (old mtime kept): retained"
assert_contains "$out" "no longer matches build.patch" "overwritten file: the note says so"
out=$(libcase removed)
assert_contains "$out" "result=kept wt=no retained=yes" "a tracked file deleted after the patch: retained"
out=$(libcase stash)
assert_contains "$out" "result=kept wt=no retained=yes" "work in a git stash of the copy: retained"
assert_contains "$out" "refs/stash" "stash: the note names the ref"
out=$(libcase branch)
assert_contains "$out" "result=kept wt=no retained=yes" "a branch the export did not create: retained"
out=$(libcase unreadable)
assert_contains "$out" "result=kept wt=no retained=yes" "a directory that cannot be read: retained, not deleted"
out=$(libcase open)
assert_contains "$out" "result=kept wt=no retained=yes" "(c) an agent still open: retained"
assert_contains "$out" "agent abc is still running" "(c) open agent: the note says why"

# --- direct Codex ------------------------------------------------------------
mk_codex() { # NAME BODY -- a stub codex that runs BODY in the copy ($dir)
  local b
  b=$(mktmp)
  cat > "$b/codex" <<EOF
#!/bin/bash
cat >/dev/null
dir=""; prev=""
for a in "\$@"; do [ "\$prev" = "-C" ] && dir="\$a"; prev="\$a"; done
cd "\$dir" || exit 1
$2
exit 0
EOF
  chmod +x "$b/codex"
  echo "$b"
}
src=$(mk_src_repo)
brief=$(mktmp)/brief.md; echo 'do it' > "$brief"

home=$(mktmp)
bin=$(mk_codex clean 'echo hi > hello.txt')
out=$(env PATH="$bin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$BIN/kit-codex-build" --no-paseo --repo "$src" --name direct-clean --brief "$brief" 2>&1)
assert_eq 0 "$?" "direct Codex, clean run: exit 0"
run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq "no" "$([ -e "$run/wt" ] && echo yes || echo no)" "direct Codex, clean run: the copy is deleted"
assert_eq "" "$(ls -A "$home/retained" 2>/dev/null)" "direct Codex, clean run: nothing is retained"
assert_contains "$(cat "$run/build.patch")" "+hi" "direct Codex, clean run: build.patch holds the work"

home=$(mktmp)
bin=$(mk_codex ignored 'echo hi > hello.txt; echo notes > debug.log')
out=$(env PATH="$bin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$BIN/kit-codex-build" --no-paseo --repo "$src" --name direct-ignored --brief "$brief" 2>&1)
assert_eq 0 "$?" "direct Codex, ignored file: exit 0"
run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq notes "$(cat "$home/retained/$(basename "$run")/debug.log" 2>/dev/null)" "direct Codex, ignored file: the copy is retained"
assert_contains "$(cat "$home/retained/$(basename "$run").why")" "debug.log (ignored by git, not in build.patch)" "direct Codex, ignored file: the reason is in the note"

# --- Gemini ------------------------------------------------------------------
mk_agy() { # BODY
  local b
  b=$(mktmp)
  printf '#!/bin/bash\n%s\necho '"'"'{"response":"done"}'"'"'\n' "$1" > "$b/agy"
  chmod +x "$b/agy"
  echo "$b/agy"
}
home=$(mktmp)
agy=$(mk_agy 'echo hi > hello.txt')
KIT_AGY_BIN="$agy" ROUTING_KIT_HOME="$home" "$BIN/kit-gemini-build" --repo "$src" --name gem-clean --brief "$brief" --model stub >/dev/null 2>&1
assert_eq 0 "$?" "Gemini, clean run: exit 0"
run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq "no" "$([ -e "$run/wt" ] && echo yes || echo no)" "Gemini, clean run: the copy is deleted"
assert_eq "" "$(ls -A "$home/retained" 2>/dev/null)" "Gemini, clean run: nothing is retained"
assert_eq done "$(jq -r .cleanup "$run/manifest.json")" "Gemini, clean run: the manifest says done"

home=$(mktmp)
agy=$(mk_agy 'echo hi > hello.txt; echo notes > debug.log')
KIT_AGY_BIN="$agy" ROUTING_KIT_HOME="$home" "$BIN/kit-gemini-build" --repo "$src" --name gem-ignored --brief "$brief" --model stub >/dev/null 2>&1
run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq notes "$(cat "$home/retained/$(basename "$run")/debug.log" 2>/dev/null)" "Gemini, ignored file: the copy is retained"
assert_contains "$(cat "$home/retained/$(basename "$run").why")" "debug.log" "Gemini, ignored file: the reason is in the note"

# A copy that has to be kept but cannot be moved (the retained folder is a plain file): the manifest
# never says "done" while the copy is still in the run folder.
home=$(mktmp)
mkdir -p "$home"; : > "$home/retained"
KIT_AGY_BIN="$agy" ROUTING_KIT_HOME="$home" "$BIN/kit-gemini-build" --repo "$src" --name gem-stuck --brief "$brief" --model stub >/dev/null 2>&1
run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq "yes" "$([ -e "$run/wt" ] && echo yes || echo no)" "Gemini, unmovable copy: it stays in the run folder"
assert_eq kept "$(jq -r .cleanup "$run/manifest.json")" "Gemini, unmovable copy: the manifest says kept, not done"

# A child that left the agent's process group (own session) and still has its folder as cwd: the
# copy is kept, not deleted under it.
pidf=$(mktmp)/child.pid
spawn='python3 -c "import subprocess,sys; p=subprocess.Popen([\"sleep\",\"15\"], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); open(sys.argv[1],\"w\").write(str(p.pid))" '"$pidf"
home=$(mktmp)
bin=$(mk_codex child "echo hi > hello.txt; $spawn")
env PATH="$bin:/usr/bin:/bin" ROUTING_KIT_HOME="$home" "$BIN/kit-codex-build" --no-paseo --repo "$src" --name direct-child --brief "$brief" >/dev/null 2>&1
run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq hi "$(cat "$home/retained/$(basename "$run")/hello.txt" 2>/dev/null)" "direct Codex, detached child still in the copy: the copy is retained"
assert_contains "$(cat "$home/retained/$(basename "$run").why" 2>/dev/null)" "a process still has" "direct Codex, detached child: the note says why"
kill "$(cat "$pidf")" 2>/dev/null
home=$(mktmp)
agy=$(mk_agy "echo hi > hello.txt; $spawn")
KIT_AGY_BIN="$agy" ROUTING_KIT_HOME="$home" "$BIN/kit-gemini-build" --repo "$src" --name gem-child --brief "$brief" --model stub >/dev/null 2>&1
run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
assert_eq hi "$(cat "$home/retained/$(basename "$run")/hello.txt" 2>/dev/null)" "Gemini, detached child still in the copy: the copy is retained"
kill "$(cat "$pidf")" 2>/dev/null

# --- locked-build (macOS: the Seatbelt jail) -----------------------------------
if [ "$(uname)" = Darwin ]; then
  TEST_KEY="test-key-$$-$(date +%s)-$RANDOM"
  mk_claude() { # BODY -- a native-shaped fake claude (readlink -f resolves under .local/share/claude/versions/)
    local root
    root=$(mktmp)
    mkdir -p "$root/.local/share/claude/versions/9.9.9" "$root/.local/bin"
    printf '#!/bin/bash\n%s\nprintf '"'"'{"usage":{"input_tokens":1,"output_tokens":1}}\\n'"'"'\n' "$1" > "$root/.local/share/claude/versions/9.9.9/claude"
    chmod +x "$root/.local/share/claude/versions/9.9.9/claude"
    ln -s "$root/.local/share/claude/versions/9.9.9/claude" "$root/.local/bin/claude"
    echo "$root/.local/bin/claude"
  }
  kc=$(mktmp)/security
  printf '#!/bin/bash\necho "%s"\n' "$TEST_KEY" > "$kc"; chmod +x "$kc"
  run_locked() { # HOME CLAUDE NAME
    mkdir -p "$1"
    printf '{"version":1,"claude_plan":"api","codex":"none","jules":false,"kimi":true,"glm":false,"paseo":false}\n' > "$1/profile.json"
    env ROUTING_KIT_HOME="$1" KIT_CLAUDE_BIN="$2" KIT_KEYCHAIN_CMD="$kc" PROVIDER_FOR_FAKE_KEYCHAIN=kimi \
      KIT_GATE_UPSTREAM="http://127.0.0.1:1" GATE_TEST_UPSTREAM_INSECURE=1 ROUTING_KIT_KEEP_RUNS=0 \
      bash "$BIN/locked-build" --provider kimi --repo "$src" --name "$3" --brief "$brief"
  }
  home=$(mktmp)
  claude=$(mk_claude 'echo hi > hello.txt')
  out=$(run_locked "$home" "$claude" locked-clean 2>&1)
  assert_locked_build_ok "$?" "$out" "locked-build, clean run"
  run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
  assert_eq "no" "$([ -e "$run/wt" ] && echo yes || echo no)" "locked-build, clean run: the copy is deleted"
  assert_eq "" "$(ls -A "$home/retained" 2>/dev/null)" "locked-build, clean run: nothing is retained"
  assert_contains "$(cat "$run/build.patch")" "+hi" "locked-build, clean run: build.patch holds the work"

  home=$(mktmp)
  claude=$(mk_claude 'echo hi > hello.txt; echo notes > debug.log')
  out=$(run_locked "$home" "$claude" locked-ignored 2>&1)
  assert_locked_build_ok "$?" "$out" "locked-build, ignored file"
  run=$(find "$home/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
  assert_eq notes "$(cat "$home/retained/$(basename "$run")/debug.log" 2>/dev/null)" "locked-build, ignored file: the copy is retained"
  assert_contains "$(cat "$home/retained/$(basename "$run").why")" "debug.log" "locked-build, ignored file: the reason is in the note"
else
  echo "SKIP: locked-build cases need macOS (Seatbelt jail)" >&2
fi

# --- kit-selftest: its own copies are deleted ----------------------------------
home=$(mktmp)
printf '{"version":1,"claude_plan":"api","codex":"codex","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$home/profile.json"
bin=$(mk_codex selftest 'echo hi > hello.txt')
# selftest asks `codex --version` first; the stub answers any call that has no -C
sed -i.bak 's|^cat >/dev/null$|[ "$1" = "--version" ] \&\& { echo "codex fake 0.0.0"; exit 0; }\ncat >/dev/null|' "$bin/codex"
out=$(env ROUTING_KIT_HOME="$home" PATH="$bin:$PATH" "$BIN/kit-selftest" 2>&1)
assert_contains "$out" "codex: ok" "selftest: the codex check passes"
assert_eq "" "$(find "$home/runs" -mindepth 2 -maxdepth 2 -name wt 2>/dev/null)" "selftest: no copy is left in the run folder"
assert_eq "" "$(ls -A "$home/retained" 2>/dev/null)" "selftest: nothing is retained"
# A copy the builder had to keep (agent left an ignored file) is removed by selftest, by run name.
home=$(mktmp)
printf '{"version":1,"claude_plan":"api","codex":"codex","jules":false,"kimi":false,"glm":false,"paseo":false}\n' > "$home/profile.json"
bin=$(mk_codex selftest 'echo hi > hello.txt; echo notes > debug.log; echo "*.log" > .gitignore')
sed -i.bak 's|^cat >/dev/null$|[ "$1" = "--version" ] \&\& { echo "codex fake 0.0.0"; exit 0; }\ncat >/dev/null|' "$bin/codex"
# An unrelated retained copy whose name happens to match is never touched.
mkdir -p "$home/retained/2026-01-01-customer-kit-selftest-codex-ABC123"
echo valuable > "$home/retained/2026-01-01-customer-kit-selftest-codex-ABC123/valuable"
out=$(env ROUTING_KIT_HOME="$home" PATH="$bin:$PATH" "$BIN/kit-selftest" 2>&1)
assert_contains "$out" "codex: ok" "selftest with a kept copy: the codex check passes"
assert_eq "2026-01-01-customer-kit-selftest-codex-ABC123" "$(ls -A "$home/retained" 2>/dev/null)" "selftest removes its own kept copy and nothing else"
assert_eq valuable "$(cat "$home/retained/2026-01-01-customer-kit-selftest-codex-ABC123/valuable" 2>/dev/null)" "selftest leaves an unrelated retained copy with a matching name alone"

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
