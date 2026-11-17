#!/bin/bash
# Paseo behavior and scrubbed-export isolation regressions.
. "$(dirname "$0")/lib.sh"
BIN="$(cd "$(dirname "$0")/.." && pwd -P)/plugins/routing-kit/bin/kit-codex-build"
# Successful repos must be outside the forbidden system temp roots.
T=$(TMPDIR="$HOME" mktmp) || exit 1
mkdir -p "$T/bin" "$T/wts"
export STUB_ARGS="$T/args" STUB_WTS="$T/wts"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@localhost
cat > "$T/bin/paseo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_ARGS"
cmd=$1; shift
case "$cmd" in
 run)
  cwd= slug= workspace= prev=
  for a in "$@"; do
   [ "$prev" = --cwd ] && cwd=$a
   [ "$prev" = --new-workspace ] && workspace=$a
   [ "$prev" = --worktree-slug ] && slug=$a
   prev=$a
  done
  if [ "$1" = --help ]; then echo "--new-workspace <local> --cwd <path>"; exit 0; fi
  [ -z "${PASEO_WORKSPACE_ID:-}" ] || [ "$workspace" = local ] || cwd=$STUB_WTS
  wt="$STUB_WTS/${slug:-build}"
  if [ -n "$slug" ]; then
   git -C "$cwd" worktree add -q --detach "$wt" || exit 1
  else
   wt=$cwd
  fi
  echo work > "$wt/NEW.txt"
  echo "$wt" > "$STUB_WTS/last"
  echo agent-from-paseo-762;;
 wait) [ "${STUB_SIGNAL:-}" != yes ] || kill -TERM "$PPID"
 printf '{"status":"%s"}\n' "${STUB_STATUS:-idle}";;
 inspect)
 [ "${STUB_INSPECT_FAIL:-}" != yes ] || exit 1
 if [ "${STUB_RETRY:-}" = yes ] && grep -q '^stop ' "$STUB_ARGS" && [ "$(grep -c '^stop ' "$STUB_ARGS")" -lt 2 ]; then
   echo '{"Status":"running"}'; exit 0
 fi
 jq -n --arg cwd "${STUB_WRONG_CWD:+/wrong}${STUB_WRONG_CWD:-$(cat "$STUB_WTS/last")}" '{Id:"agent-from-paseo-762",Cwd:$cwd,Status:"idle",PendingPermissions:[]}' ;;
 logs) echo 'stub final message';;
 stop) exit 0;;
 archive) [ "${STUB_ARCHIVE_FAIL:-}" != yes ];;
 ls) echo '[]';;
 workspace)
  case "$1" in
   ls) jq -n --arg cwd "$(cat "$STUB_WTS/last")" '[{workspaceId:"workspace-762",cwd:$cwd}]';;
   archive) exit 0;;
  esac;;
 *) exit 91;;
esac
STUB
for provider in codex claude agy; do
 cat > "$T/bin/$provider" <<'STUB'
#!/bin/bash
printf 'unexpected direct provider: %s\n' "$0" >> "$STUB_ARGS"
exit 93
STUB
 done
chmod +x "$T/bin/"*
export PATH="$T/bin:/usr/bin:/bin"
repo() {
 mkdir -p "$1"
 git -C "$1" init -q
 echo original > "$1/a.txt"
 git -C "$1" add a.txt
 git -C "$1" commit -qm init
}
repo "$T/repo"
echo 'create NEW.txt' > "$T/brief.md"
invoke() {
 : > "$STUB_ARGS"
 home=$(mktmp)
 out=$(env ROUTING_KIT_HOME="$home" "$BIN" --paseo --repo "$1" --name "$2" --brief "$T/brief.md" 2>&1)
 code=$?
 run=$(find "$home/runs" -name manifest.json -print 2>/dev/null | head -1)
 run=${run%/manifest.json}
}
check() { if "$@"; then pass; else fail "$label"; fi; }
invoke "$T/repo" success
label='paseo run completes successfully'; check test "$code" -eq 0
label='paseo argv uses only the scrubbed export without a source worktree'
if grep -F -- "--cwd $run/wt " "$STUB_ARGS" >/dev/null &&
 ! grep -F -- "$T/repo" "$STUB_ARGS" >/dev/null &&
 ! grep -E -- '--worktree-|--new-branch|--base ' "$STUB_ARGS" >/dev/null; then pass; else fail "$label"; fi
label='paseo run uses full-access mode'; check grep -E '^run .*--mode full-access( |$)' "$STUB_ARGS"
label='finished agent archived'; check grep -qx 'archive agent-from-paseo-762' "$STUB_ARGS"
label='run directory contains build.patch with generated change'; check grep -q '^+++ b/NEW.txt' "$run/build.patch" 2>/dev/null
label='run directory contains final result.md'; check grep -qx 'stub final message' "$run/result.md" 2>/dev/null
label='run directory contains manifest identifying the agent'; check jq -e '.agent == "agent-from-paseo-762"' "$run/manifest.json" 2>/dev/null
# Regression: archive takes the manifest agent id, and success is recorded
# as archived without the owner's misleading "agent not archived" warning.
label='successful archive uses manifest agent id and reports archived'
agent=$(jq -r '.agent // empty' "$run/manifest.json" 2>/dev/null)
if [ -n "$agent" ] && grep -qx "archive $agent" "$STUB_ARGS" &&
 jq -e '.archived == true' "$run/manifest.json" >/dev/null 2>&1 &&
 ! printf '%s\n' "$out" | grep -q 'agent not archived'; then pass; else fail "$label"; fi
export PASEO_WORKSPACE_ID=caller
invoke "$T/repo" ambient
unset PASEO_WORKSPACE_ID
label='ambient workspace uses explicit local export and verifies before wait'
if [ "$code" -eq 0 ] && grep -q -- '--new-workspace local' "$STUB_ARGS" && [ "$(sed -n '2p' "$STUB_ARGS")" = 'inspect agent-from-paseo-762 --json' ]; then pass; else fail "$label"; fi
export STUB_WRONG_CWD=yes
invoke "$T/repo" wrong-cwd
unset STUB_WRONG_CWD
label='wrong cwd stops and archives without waiting or patch'
if [ "$code" -ne 0 ] && ! grep -q '^wait ' "$STUB_ARGS" && grep -q '^stop ' "$STUB_ARGS" && grep -q '^archive ' "$STUB_ARGS" && [ ! -f "$run/build.patch" ]; then pass; else fail "$label"; fi
export STUB_STATUS=error
invoke "$T/repo" failed
unset STUB_STATUS
label='failed build still archives its agent'
if [ "$code" -ne 0 ] && grep -qx 'archive agent-from-paseo-762' "$STUB_ARGS"; then pass; else fail "$label"; fi
export STUB_INSPECT_FAIL=yes
invoke "$T/repo" inspect-error
unset STUB_INSPECT_FAIL
label='inspect failure still archives and writes manifest'
if [ "$code" -ne 0 ] && grep -qx 'archive agent-from-paseo-762' "$STUB_ARGS" && jq -e '.archived == true' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_RETRY=yes
invoke "$T/repo" retry
unset STUB_RETRY
label='stop retries and verifies a still running agent'
if [ "$code" -eq 0 ] && [ "$(grep -c '^stop ' "$STUB_ARGS")" -eq 2 ]; then pass; else fail "$label"; fi
export STUB_SIGNAL=yes
invoke "$T/repo" signal
unset STUB_SIGNAL
label='signal stops and archives agent and writes manifest'
if [ "$code" -ne 0 ] && grep -qx 'stop agent-from-paseo-762' "$STUB_ARGS" && jq -e '.archived == true' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_ARCHIVE_FAIL=yes
invoke "$T/repo" archive-error
unset STUB_ARCHIVE_FAIL
label='archive failure is reported truthfully'
if [ "$code" -eq 0 ] && grep -q "^+++ b/NEW.txt" "$run/build.patch" && printf '%s' "$out" | grep -q "^+++ b/NEW.txt" && jq -e '.archived == false' "$run/manifest.json" >/dev/null && printf '%s' "$out" | grep -q 'agent not archived'; then pass; else fail "$label"; fi
echo dirty >> "$T/repo/a.txt"
invoke "$T/repo" dirty
label='dirty tree refused before paseo run, with a clean-tree diagnostic'
if [ "$code" -eq 2 ] && [ ! -s "$STUB_ARGS" ] && printf '%s\n' "$out" | grep -Ei 'dirty|clean' >/dev/null; then pass; else fail "$label"; fi
# Each forbidden root is a separate case. For /var/folders use a real
# writable descendant provided by macOS, rather than attempting root writes.
for root in /tmp "$T/custom-temp" /var/folders; do
 mkdir -p "$T/custom-temp"
 case "$root" in
  /var/folders) target=$(mktmp);;
  *) target=$(TMPDIR="$root" mktmp);;
 esac
 repo "$target"
 old_tmp=${TMPDIR:-/tmp}
 [ "$root" = "$T/custom-temp" ] && export TMPDIR="$root"
 invoke "$target" forbidden
 export TMPDIR="$old_tmp"
 label="repo under $root refused with temp-repo diagnostic"
 if [ "$code" -eq 2 ] && [ ! -s "$STUB_ARGS" ] && printf '%s\n' "$out" | grep -Ei 'refus.*temp|temp.*refus' >/dev/null; then pass; else fail "$label"; fi
done
printf 'test_codex_build_paseo: %s passed, %s failed (19 cases)\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
