#!/bin/bash
# Contract tests for the synthetic hooks selftest; no provider is invoked.
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SELFTEST="$REPO_ROOT/plugins/routing-kit/bin/kit-selftest"
REGISTRY="$REPO_ROOT/plugins/routing-kit/hooks/checks/registry.json"
scratch=$(mktmp)
mkdir -p "$scratch/home" "$scratch/tmp" "$scratch/config"
# Deliberately no caller profile: --hooks must create its own.
python3 - "$REGISTRY" "$scratch/registry.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    registry = json.load(f)
for event, checks in registry.items():
    registry[event] = [c for c in checks if not c['check'].startswith('guard_')]
with open(sys.argv[2], 'w') as f:
    json.dump(registry, f)
PY

# Snapshot names and metadata, without opening file contents (including secrets).
# The private scratch directory is the only excluded writable area.
snapshot() {
  python3 - "$scratch/home" "$REPO_ROOT" "$scratch" <<'PY'
import os, sys, json
rows = []
for root in sys.argv[1:3]:
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not os.path.join(base, d).startswith(sys.argv[3] + os.sep))
        # Python's bytecode cache and other agents' worktrees change on their own.
        dirs[:] = [d for d in dirs if d not in ('__pycache__', '.git') and not (d == 'worktrees' and base.endswith('.claude'))]
        for name in sorted(dirs + files):
            path = os.path.join(base, name)
            s = os.lstat(path)
            rows.append((path, s.st_mode, s.st_size, s.st_mtime_ns))
print(json.dumps(rows))
PY
}
run_hooks() {
  run_with_timeout 20 env HOME="$scratch/home" TMPDIR="$scratch/tmp" \
    XDG_CONFIG_HOME="$scratch/config" ROUTING_KIT_HOME="$scratch/config/routing-kit" \
    KIT_HOOK_REGISTRY="$1" DOUBLE_SHOT_LATTE=0 "$SELFTEST" --hooks
}
before=$(snapshot)
out=$(run_hooks "$REGISTRY" 2>&1)
code=$?
after=$(snapshot)
# Each contract is one test so an absent mode produces a useful complete list.
if [ "$code" = 0 ] && printf '%s\n' "$out" | grep -Eq '^hooks selftest: [1-9][0-9]* ok, 0 failed$'; then
  pass
else
  fail 'hooks mode exits 0 with a passing hooks selftest summary'
fi
# Case labels describe the public assertion names expected from the new mode.
for agent in claude codex agy; do
  for case_name in rm_rf_home force_push owner_checkout claude_no_model claude_bad_model ls normal_write codex_exec prep_for_exit stop_without_latte stop_with_latte; do
    if printf '%s\n' "$out" | grep -Fxq "ok $agent $case_name"; then
      pass
    else
      fail "$agent $case_name"
    fi
  done
done
if printf '%s\n' "$out" | grep -Fxq 'ok agy prep_for_exit_once_per_turn'; then
  pass
else
  fail 'agy prep_for_exit_once_per_turn'
fi
broken_out=$(run_hooks "$scratch/registry.json" 2>&1)
broken_code=$?
missing_named=0
for agent in claude codex agy; do
  for case_name in rm_rf_home force_push owner_checkout; do
    printf '%s\n' "$broken_out" | grep -Fxq "FAIL $agent $case_name" || missing_named=1
  done
done
if [ "$broken_code" = 1 ] && [ "$missing_named" = 0 ] && \
    printf '%s\n' "$broken_out" | grep -Eq '^hooks selftest: [0-9]+ ok, [1-9][0-9]* failed$'; then
  pass
else
  fail 'missing guards exits 1, names failed guard cases, and reports failures'
fi
# Every handler the kit trusts in Codex is exercised: the kit-hook events and the standalone session-start commands.
for agent in claude codex agy; do
  for case_name in kit_hook_SessionStart kit_hook_PostToolUse session_start_command; do
    if printf '%s\n' "$out" | grep -Fxq "ok $agent $case_name"; then pass; else fail "$agent $case_name"; fi
  done
done
# A Claude Code plugin install ships only plugins/routing-kit (no tests/): the selftest must pass there.
plugin_only="$scratch/plugin-cache/routing-kit/0.4.1"
mkdir -p "$plugin_only"
cp -R "$REPO_ROOT/plugins/routing-kit/." "$plugin_only/"
po_out=$(run_with_timeout 40 env HOME="$scratch/home" TMPDIR="$scratch/tmp" XDG_CONFIG_HOME="$scratch/config" \
  ROUTING_KIT_HOME="$scratch/config/routing-kit" DOUBLE_SHOT_LATTE=0 "$plugin_only/bin/kit-selftest" --hooks 2>&1)
po_code=$?
if [ "$po_code" = 0 ] && printf '%s\n' "$po_out" | grep -Eq '^hooks selftest: [0-9]+ ok, 0 failed$'; then
  pass
else
  fail "hooks selftest passes from a plugin-only copy (exit $po_code): $(printf '%s\n' "$po_out" | tail -3)"
fi
# A session-start command that exits 42 must fail the selftest (it used to pass: 34 ok, 0 failed).
copy="$scratch/broken-kit"
mkdir -p "$copy/plugins"
cp -R "$REPO_ROOT/plugins/routing-kit" "$copy/plugins/routing-kit"
printf '#!/bin/sh\nexit 42\n' > "$copy/plugins/routing-kit/hooks/session-start"
chmod +x "$copy/plugins/routing-kit/hooks/session-start"
bad_out=$(run_with_timeout 40 env HOME="$scratch/home" TMPDIR="$scratch/tmp" XDG_CONFIG_HOME="$scratch/config" \
  ROUTING_KIT_HOME="$scratch/config/routing-kit" DOUBLE_SHOT_LATTE=0 "$copy/plugins/routing-kit/bin/kit-selftest" --hooks 2>&1)
bad_code=$?
if [ "$bad_code" = 1 ] && printf '%s\n' "$bad_out" | grep -Fxq 'FAIL codex session_start_command' && printf '%s\n' "$bad_out" | grep -Fxq 'FAIL claude session_start_command'; then
  pass
else
  fail 'a broken session-start command fails the hooks selftest'
fi
final_snapshot=$(snapshot)
# Require the hooks summary too: an unsupported option doing nothing must not
# earn a passing isolation test.
if [ "$before" = "$after" ] && [ "$before" = "$final_snapshot" ] && \
    printf '%s\n' "$out" | grep -Eq '^hooks selftest: [0-9]+ ok, [0-9]+ failed$'; then
  pass
else
  fail 'hooks mode leaves HOME and repository unchanged outside its temp folder'
fi
printf 'selftest hooks tests: %s ok, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
