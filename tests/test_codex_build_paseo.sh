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
  [ "${STUB_NO_CHANGE:-}" = yes ] || echo work > "$wt/NEW.txt"
  # A nested repository makes the kit refuse to stage the tree: no patch can be saved.
  [ "${STUB_NESTED_GIT:-}" != yes ] || { mkdir -p "$wt/nested/.git"; echo x > "$wt/nested/.git/HEAD"; }
  [ "${STUB_BINARY:-}" != yes ] || printf 'a\000b' > "$wt/binary.dat"
  # What an agent can do to the tree's git metadata. "commit" is ordinary git use.
  case "${STUB_SHAPE:-}" in
   cfgworktree) printf '[filter "x"]\n\tclean = sh ./clean.sh\n' > "$wt/.git/config.worktree";;
   gsymlink) mv "$wt/.git" "$STUB_WTS/moved-git.$$"; ln -s "$STUB_WTS/moved-git.$$" "$wt/.git";;
   badcommondir) echo ../../x > "$wt/.git/commondir";;
   gitfile) mv "$wt/.git" "$STUB_WTS/moved-git.$$"; echo "gitdir: $STUB_WTS/moved-git.$$" > "$wt/.git";;
   commit) git -C "$wt" add NEW.txt && git -C "$wt" commit -qm 'agent commit';;
   # An agent that forges the run dir's marks: work git ignores, then "no agent was started here".
   fakemark) printf 'artifact.json\n' > "$wt/.gitignore"; echo '{"unique":"work-0815"}' > "$wt/artifact.json"
     : > "$wt/../agent-not-started"; rm -f "$wt/../agent-started";;
  esac
  [ -z "${CLAUDE_TEST_LEAK:-}" ] || exit 92
  [ "${CLAUDE_CONFIG_DIR:-}" = preserved ] || exit 92
  echo "$wt" > "$STUB_WTS/last"
  echo agent-from-paseo-762;;
 wait) jq -e '.cleanup == "pending" and .started != ""' "$(dirname "$(cat "$STUB_WTS/last")")/manifest.json" >/dev/null || exit 94
 [ "${STUB_SIGNAL:-}" != yes ] || kill -TERM "$PPID"
 [ -z "${STUB_COMMIT_SRC:-}" ] || git -C "$STUB_COMMIT_SRC" -c user.name=Test -c user.email=you@example.com commit -q --allow-empty -m 'user commit during the build'
 printf '{"status":"%s"}\n' "${STUB_STATUS:-idle}";;
 inspect)
 # Agents of earlier runs, one record per id (see mkagent below).
 if [ -f "$STUB_WTS/agents/$1.json" ]; then cat "$STUB_WTS/agents/$1.json"; exit 0; fi
 [ "${STUB_INSPECT_OTHER_FAIL:-}" != yes ] || [ "$1" = agent-from-paseo-762 ] || exit 1
 [ "${STUB_INSPECT_FAIL:-}" != yes ] || exit 1
 # Like the real CLI, inspect answers for whatever agent the id resolves to: STUB_AGENT_ID and
 # STUB_AGENT_CWD make that a foreign agent or a foreign folder.
 agent_id=${STUB_AGENT_ID:-agent-from-paseo-762}
 agent_cwd=${STUB_AGENT_CWD:-$(cat "$STUB_WTS/last")}
 [ "${STUB_RUNNING:-}" != yes ] || { jq -n --arg id "$agent_id" --arg cwd "$agent_cwd" '{Id:$id,Status:"running",Cwd:$cwd}'; exit 0; }
 if [ "${STUB_RETRY:-}" = yes ] && grep -q '^stop ' "$STUB_ARGS" && [ "$(grep -c '^stop ' "$STUB_ARGS")" -lt 2 ]; then
   echo '{"Status":"running"}'; exit 0
 fi
 archived=false; [ ! -f "$STUB_WTS/agent-archived" ] || archived=true
 if [ "${STUB_NO_ARCHIVED_FIELD:-}" = yes ]; then
  jq -n --arg id "$agent_id" --arg cwd "$agent_cwd" '{Id:$id,Cwd:$cwd,Status:"idle",PendingPermissions:[]}'; exit 0
 fi
 jq -n --arg id "$agent_id" --arg cwd "${STUB_WRONG_CWD:+/wrong}${STUB_WRONG_CWD:-$agent_cwd}" --argjson archived "$archived" \
  '{Id:$id,Cwd:$cwd,Status:(if $archived then "closed" else "idle" end),Archived:$archived,PendingPermissions:[]}' ;;
 logs) echo '---'; [ "${STUB_EMPTY_LOG:-}" = yes ] || echo 'stub final message';;
 stop) exit 0;;
 # Like the real CLI: archiving an agent that is already archived is an error.
 archive)
  if [ -f "$STUB_WTS/agents/$1.json" ]; then
   jq -e '.Archived != true' "$STUB_WTS/agents/$1.json" >/dev/null || exit 1
   jq '.Archived = true | .Status = "closed"' "$STUB_WTS/agents/$1.json" > "$STUB_WTS/agents/$1.tmp" && mv "$STUB_WTS/agents/$1.tmp" "$STUB_WTS/agents/$1.json"
   exit 0
  fi
  [ "${STUB_ARCHIVE_FAIL:-}" != yes ] || exit 1
  [ ! -f "$STUB_WTS/agent-archived" ] || { echo 'already archived' >&2; exit 1; }
  : > "$STUB_WTS/agent-archived";;
 ls)
  # With --label paseo.parent-agent-id=ID: that agent's open children (one file per parent).
  parent=
  for a in "$@"; do case "$a" in paseo.parent-agent-id=*) parent=${a#paseo.parent-agent-id=};; esac; done
  if [ -n "$parent" ]; then
   if [ -f "$STUB_WTS/children-$parent.json" ]; then cat "$STUB_WTS/children-$parent.json"; else echo '[]'; fi
   exit 0
  fi
  if [ "${STUB_OTHER_IN_TREE:-}" = yes ]; then
   jq -n --arg cwd "$(cat "$STUB_WTS/last")" '[{id:"agent-from-paseo-762",status:"idle",cwd:$cwd},{id:"someone-in-the-tree",status:"running",cwd:$cwd}]'
   exit 0
  fi
  echo "${STUB_LS:-[]}";;
 workspace)
  case "$1" in
   ls)
    id=workspace-762
    # STUB_WS_CHANGED: a different workspace has the cwd from the second listing on.
    [ "${STUB_WS_CHANGED:-}" != yes ] || [ "$(grep -c '^workspace ls' "$STUB_ARGS")" -lt 2 ] || id=workspace-other
    [ -z "${STUB_WS_ID:-}" ] || id=$STUB_WS_ID
    # STUB_WS_GONE_LATER: the workspace is listed once, at the start, and closed after that.
    if [ "${STUB_WS_GONE_LATER:-}" = yes ] && [ "$(grep -c '^workspace ls' "$STUB_ARGS")" -ge 2 ]; then echo '[]'; exit 0; fi
    # STUB_WS_FIRST=two: two workspaces on the first listing, afterwards only the sibling.
    if [ "${STUB_WS_FIRST:-}" = two ]; then
     if [ "$(grep -c '^workspace ls' "$STUB_ARGS")" -lt 2 ]; then
      jq -n --arg cwd "$(cat "$STUB_WTS/last")" '[{workspaceId:"workspace-762",cwd:$cwd},{workspaceId:"workspace-sibling",cwd:$cwd}]'
     else
      jq -n --arg cwd "$(cat "$STUB_WTS/last")" '[{workspaceId:"workspace-sibling",cwd:$cwd}]'
     fi
     exit 0
    fi
    if [ -f "$STUB_WTS/ws-archived" ] || [ "${STUB_WS_LIST:-one}" = none ]; then echo '[]'
    elif [ "${STUB_WS_LIST:-one}" = two ]; then
     jq -n --arg cwd "$(cat "$STUB_WTS/last")" --arg id "$id" '[{workspaceId:$id,cwd:$cwd},{workspaceId:"workspace-sibling",cwd:$cwd}]'
    else
     jq -n --arg cwd "$(cat "$STUB_WTS/last")" --arg id "$id" '[{workspaceId:"workspace-elsewhere",cwd:($cwd + "/sub")},{workspaceId:$id,cwd:$cwd}]'
    fi;;
   # Like the real CLI: archiving a workspace archives the agents it owns.
   archive)
    [ "${STUB_WS_ARCHIVE_FAIL:-}" != yes ] || exit 1
    wt=$(cat "$STUB_WTS/last")
    if [ -e "$wt" ] || [ -L "$wt" ]; then echo tree-present >> "$STUB_WTS/ws-archive-log"; else echo tree-gone >> "$STUB_WTS/ws-archive-log"; fi
    : > "$STUB_WTS/ws-archived"
    [ "${STUB_ARCHIVE_FAIL:-}" = yes ] || : > "$STUB_WTS/agent-archived";;
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
export CLAUDE_TEST_LEAK=remove CLAUDE_CONFIG_DIR=preserved
repo "$T/repo"
echo 'create NEW.txt' > "$T/brief.md"
invoke() {
 : > "$STUB_ARGS"
 rm -f "$STUB_WTS/agent-archived" "$STUB_WTS/ws-archived" "$STUB_WTS/ws-archive-log"
 # The kit home is outside the temp roots too: the sweep leaves runs under a temp dir alone.
 # TEST_HOME_TMP=yes puts it under the system temp dir.
 if [ "${TEST_HOME_TMP:-}" = yes ]; then home=$(mktmp); else home=$(TMPDIR="$HOME" mktmp); fi
 [ "${TEST_PROFILE:-}" != broken ] || echo broken > "$home/profile.json"
 [ "${TEST_PROFILE:-}" != yes ] || echo '{"codex_build_transport":"paseo"}' > "$home/profile.json"
 [ "${TEST_PROFILE:-}" != pill ] || echo '{"paseo":true}' > "$home/profile.json"
 [ "${TEST_PROFILE:-}" != pill-direct ] || echo '{"paseo":true,"codex_build_transport":"direct"}' > "$home/profile.json"
 [ "${TEST_PROFILE:-}" != pill-transport ] || echo '{"paseo":false,"codex_build_transport":"paseo"}' > "$home/profile.json"
 out=$(env ROUTING_KIT_HOME="$home" ${TEST_ENV:-} "$BIN" ${TEST_TRANSPORT:---paseo} --repo "$1" --name "$2" --brief "$T/brief.md" ${TEST_OPTIONS:-} 2>&1)
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
label='workspace discovered from workspace list'; check jq -e '.workspace == "workspace-762"' "$run/manifest.json"
label='single truthful archive report'; check test "$(printf '%s\n' "$out" | grep -c 'archived=false')" -eq 0
label='separator stripped from nonempty result'; check test "$(cat "$run/result.md")" = 'stub final message'
label='run directory contains final result.md'; check grep -qx 'stub final message' "$run/result.md" 2>/dev/null
label='run directory contains manifest identifying the agent'; check jq -e '.agent == "agent-from-paseo-762"' "$run/manifest.json" 2>/dev/null
# Regression: archive takes the manifest agent id, and success is recorded
# as archived without the owner's misleading "agent not archived" warning.
label='successful archive uses manifest agent id and reports archived'
agent=$(jq -r '.agent // empty' "$run/manifest.json" 2>/dev/null)
if [ -n "$agent" ] && grep -qx "archive $agent" "$STUB_ARGS" &&
 jq -e '.archived == true' "$run/manifest.json" >/dev/null 2>&1 &&
 ! printf '%s\n' "$out" | grep -q 'agent not archived'; then pass; else fail "$label"; fi
# Items 9 and 10: the workspace is archived on a normal finish, after the tree is gone, and the
# report is true although `paseo archive` fails for the agent the workspace archive already took.
label='normal finish archives the single matching workspace by its listed id'
check grep -qx 'workspace archive workspace-762' "$STUB_ARGS"
label='workspace archived only after the exported tree was deleted'
check test "$(cat "$STUB_WTS/ws-archive-log" 2>/dev/null)" = tree-gone
label='agent archived by its workspace is reported archived, not "agent not archived"'
if printf '%s\n' "$out" | grep -q 'agent archived=true; workspace archived=true; copy deleted (build.patch saved and checked, nothing outside it)' &&
 jq -e '.archived == true and .workspace_archived == true and .cleanup == "done"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# The copy an agent worked in is deleted once its work is saved (build.patch checked, nothing outside
# it, no agent open in it), before the workspace is archived; nothing goes to retained.
label='finished copy is deleted, not retained'
if [ ! -e "$run/wt" ] && [ ! -e "$home/retained" ] && [ ! -e "$run/retained-at" ]; then pass; else fail "$label"; fi
label='copy was deleted before the workspace was archived'
check test "$(cat "$STUB_WTS/ws-archive-log" 2>/dev/null)" = tree-gone
label='report says the copy was deleted'
check grep -qF "copy deleted (build.patch saved and checked" <<EOF
$out
EOF
label='last line still names patch and result after the archive report'
if printf '%s\n' "$out" | tail -1 | grep -q "^kit-codex-build: exit=0 patch=$run/build.patch result=$run/result.md$"; then pass; else fail "$label"; fi
# 8.1b3 item 1: the checked build stays in the source repo as a branch after the tree and the
# workspace are gone, and the manifest names it. Nothing in the source checkout moves.
branch="kit-codex/$(basename "$run")"
base=$(git -C "$T/repo" rev-parse HEAD)
label='build kept as a branch in the source repo after the tree is gone'
if [ ! -d "$run/wt" ] && [ "$(git -C "$T/repo" show "$branch:NEW.txt" 2>/dev/null)" = work ] &&
 [ "$(git -C "$T/repo" rev-parse "$branch^" 2>/dev/null)" = "$base" ] &&
 [ "$(git -C "$T/repo" show "$branch:a.txt" 2>/dev/null)" = original ]; then pass; else fail "$label"; fi
label='manifest records the branch'
check jq -e --arg b "$branch" '.branch == $b' "$run/manifest.json"
label='source checkout is untouched by the branch'
if [ -z "$(git -C "$T/repo" status --porcelain)" ] && [ "$(git -C "$T/repo" rev-parse HEAD)" = "$base" ] &&
 [ "$(git -C "$T/repo" symbolic-ref --short HEAD)" != "$branch" ] && [ ! -e "$T/repo/NEW.txt" ]; then pass; else fail "$label"; fi
label='output names the kept branch'
check grep -q "kit-codex-build: branch: $branch " <<EOF
$out
EOF
export KIT_CODEX_KEEP_WORKTREE=1
invoke "$T/repo" kept
unset KIT_CODEX_KEEP_WORKTREE
# 8.1b3 item 2: the last line says the worktree is kept and where, after the patch and the result.
label='KEEP_WORKTREE final line says the worktree is kept and where'
if printf '%s\n' "$out" | tail -1 | grep -qF "exit=0 patch=$run/build.patch result=$run/result.md worktree=$run/wt (worktree kept: KIT_CODEX_KEEP_WORKTREE=1)"; then pass; else fail "$label"; fi
label='keep saves patch and tree without stopping or archiving'
if [ "$code" -eq 0 ] && [ -s "$run/build.patch" ] && [ -d "$run/wt" ] && ! grep -Eq '^(stop|archive) ' "$STUB_ARGS" && jq -e '.cleanup == "kept"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='kept run older than 24 h survives the generic stale cleanup'
touch -t 202001010000 "$run"
ROUTING_KIT_HOME="$home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; run_sweep_stale' _ "$BIN"
if [ -f "$run/wt/NEW.txt" ] && [ -f "$run/wt/a.txt" ]; then pass; else fail "$label"; fi
# Replay a stopped pending run through the next startup sweep.
jq '.cleanup="pending" | .started="2020-01-01T00:00:00Z"' "$run/manifest.json" > "$run/m.tmp"
mv "$run/m.tmp" "$run/manifest.json"
saved=$run
ROUTING_KIT_HOME="$home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; . "$(dirname "$1")/../lib/codex-paseo-build.sh"; codex_paseo_sweep' _ "$BIN" >/dev/null 2>&1
label='pending sweep salvages patch and marks done'
if [ -s "$saved/build.patch" ] && [ ! -d "$saved/wt" ] && jq -e '.cleanup == "done"' "$saved/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_NO_CHANGE=yes
invoke "$T/repo" empty
unset STUB_NO_CHANGE
label='no changes succeeds separately from failure'
if [ "$code" -eq 0 ] && [ -f "$run/build.patch" ] && [ ! -s "$run/build.patch" ]; then pass; else fail "$label"; fi
label='no changes leaves no branch'
if jq -e '.branch == ""' "$run/manifest.json" >/dev/null && ! git -C "$T/repo" rev-parse -q --verify "refs/heads/kit-codex/$(basename "$run")" >/dev/null; then pass; else fail "$label"; fi
export STUB_BINARY=yes
invoke "$T/repo" binary
unset STUB_BINARY
label='binary patch survives self-check'
if [ "$code" -eq 0 ] && grep -q 'GIT binary patch' "$run/build.patch"; then pass; else fail "$label"; fi
export PASEO_WORKSPACE_ID=caller
invoke "$T/repo" ambient
unset PASEO_WORKSPACE_ID
label='ambient workspace uses explicit local export and verifies before wait'
if [ "$code" -eq 0 ] && grep -q -- '--new-workspace local' "$STUB_ARGS" && [ "$(sed -n '2p' "$STUB_ARGS")" = 'inspect agent-from-paseo-762 --json' ]; then pass; else fail "$label"; fi
export STUB_WRONG_CWD=yes
invoke "$T/repo" wrong-cwd
unset STUB_WRONG_CWD
label='wrong cwd: agent stopped, no wait, nothing archived or deleted, left pending'
if [ "$code" -ne 0 ] && ! grep -q '^wait ' "$STUB_ARGS" && grep -q '^stop ' "$STUB_ARGS" && ! grep -Eq '^(archive|workspace archive) ' "$STUB_ARGS" &&
 [ -d "$run/wt" ] && jq -e '.cleanup == "pending" and .archived == false' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_STATUS=error
invoke "$T/repo" failed
unset STUB_STATUS
label='failed build salvages patch and archives its agent'
if [ "$code" -ne 0 ] && [ -s "$run/build.patch" ] && grep -qx 'archive agent-from-paseo-762' "$STUB_ARGS"; then pass; else fail "$label"; fi
export STUB_INSPECT_FAIL=yes
invoke "$T/repo" inspect-error
unset STUB_INSPECT_FAIL
label='inspect failure keeps worktree and pending manifest'
if [ "$code" -ne 0 ] && ! grep -q '^archive ' "$STUB_ARGS" && [ -d "$run/wt" ] && jq -e '.cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_RETRY=yes
invoke "$T/repo" retry
unset STUB_RETRY
label='stop retries and verifies a still running agent'
if [ "$code" -eq 0 ] && [ "$(grep -c '^stop ' "$STUB_ARGS")" -eq 2 ]; then pass; else fail "$label"; fi
export STUB_SIGNAL=yes
invoke "$T/repo" signal
unset STUB_SIGNAL
label='signal stops and archives agent and writes manifest'
if [ "$code" -ne 0 ] && grep -qx 'stop agent-from-paseo-762' "$STUB_ARGS" && jq -e '.archived == true and .cleanup == "done"' "$run/manifest.json" >/dev/null && [ -f "$run/result.md" ]; then pass; else fail "$label"; fi
# Finding 1: an interrupted run saves its edits as a checked patch before the tree goes.
label='signal during the wait saves the patch before the tree is deleted'
if [ "$code" -eq 143 ] && grep -q '^+++ b/NEW.txt' "$run/build.patch" 2>/dev/null && [ ! -d "$run/wt" ] &&
 printf '%s\n' "$out" | tail -1 | grep -q "exit=143 patch=$run/build.patch result="; then pass; else fail "$label"; fi
export STUB_SIGNAL=yes STUB_NESTED_GIT=yes
invoke "$T/repo" signal-no-patch
unset STUB_SIGNAL STUB_NESTED_GIT
label='signal with no saveable patch keeps the tree and archives nothing'
if [ "$code" -eq 143 ] && [ -f "$run/wt/NEW.txt" ] && [ ! -f "$run/build.patch" ] && ! grep -Eq '^(archive|workspace archive) ' "$STUB_ARGS" &&
 jq -e '.cleanup == "pending" and .archived == false and .workspace_archived == false' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# Finding 1: the tree is the only copy of the work; without a saved patch it is never deleted.
export STUB_NESTED_GIT=yes
invoke "$T/repo" no-patch
unset STUB_NESTED_GIT
label='refused staging keeps the tree, archives nothing and stays pending'
if [ "$code" -eq 4 ] && [ -f "$run/wt/NEW.txt" ] && [ ! -f "$run/build.patch" ] && ! grep -Eq '^(archive|workspace archive) ' "$STUB_ARGS" &&
 jq -e '.cleanup == "pending" and .archived == false and .workspace_archived == false and .patch == ""' "$run/manifest.json" >/dev/null &&
 printf '%s\n' "$out" | grep -q 'no verified patch'; then pass; else fail "$label"; fi
label='stale cleanup leaves the unsaved tree alone after 24 h'
touch -t 202001010000 "$run"
ROUTING_KIT_HOME="$home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; run_sweep_stale' _ "$BIN"
check test -f "$run/wt/NEW.txt"
export STUB_ARCHIVE_FAIL=yes
invoke "$T/repo" archive-error
unset STUB_ARCHIVE_FAIL
label='archive failure is reported truthfully'
if [ "$code" -eq 0 ] && grep -q "^+++ b/NEW.txt" "$run/build.patch" && printf '%s' "$out" | grep -q "^+++ b/NEW.txt" && jq -e '.archived == false' "$run/manifest.json" >/dev/null && printf '%s' "$out" | grep -q 'agent not archived'; then pass; else fail "$label"; fi
export TEST_PROFILE=yes TEST_TRANSPORT=' '
invoke "$T/repo" profile-default
label='profile selects Paseo by default'
if [ "$code" -eq 0 ] && grep -q '^run ' "$STUB_ARGS"; then pass; else fail "$label"; fi
export TEST_TRANSPORT=--no-paseo
invoke "$T/repo" profile-optout
label='no-paseo overrides profile'
if ! grep -q '^run ' "$STUB_ARGS" && grep -q 'unexpected direct provider' "$STUB_ARGS"; then pass; else fail "$label"; fi
# The profile key "paseo" is the usage-pill flag: it no longer changes builds. Only
# codex_build_transport does, and --paseo / --no-paseo override it.
export TEST_PROFILE=pill TEST_TRANSPORT=' '
invoke "$T/repo" pill-only
label='profile "paseo": true (the pill flag) alone no longer selects Paseo'
if ! grep -q '^run ' "$STUB_ARGS" && grep -q 'unexpected direct provider' "$STUB_ARGS"; then pass; else fail "$label"; fi
export TEST_PROFILE=pill-direct
invoke "$T/repo" pill-direct
label='codex_build_transport direct stays direct even with the pill flag on'
if ! grep -q '^run ' "$STUB_ARGS" && grep -q 'unexpected direct provider' "$STUB_ARGS"; then pass; else fail "$label"; fi
export TEST_PROFILE=pill-transport
invoke "$T/repo" transport-paseo
label='codex_build_transport paseo selects Paseo with the pill flag off'
if [ "$code" -eq 0 ] && grep -q '^run ' "$STUB_ARGS"; then pass; else fail "$label"; fi
export TEST_TRANSPORT=--no-paseo
invoke "$T/repo" transport-paseo-optout
label='--no-paseo overrides codex_build_transport paseo'
if ! grep -q '^run ' "$STUB_ARGS" && grep -q 'unexpected direct provider' "$STUB_ARGS"; then pass; else fail "$label"; fi
export TEST_PROFILE=pill-direct TEST_TRANSPORT=--paseo
invoke "$T/repo" direct-paseo-flag
label='--paseo overrides codex_build_transport direct'
if [ "$code" -eq 0 ] && grep -q '^run ' "$STUB_ARGS"; then pass; else fail "$label"; fi
unset TEST_PROFILE TEST_TRANSPORT
# The brief is copied first; the copy is scanned and is what is sent. A secret that appears in the
# copy (a swap between the scan and the copy, simulated by a cp that appends one) is refused.
cpbin=$(mktmp)
key="sk-""ant-api03-$(printf 'A%.0s' {1..24})"
cat > "$cpbin/cp" <<CPEOF
#!/bin/bash
/bin/cp "\$@"; rc=\$?
for a in "\$@"; do last="\$a"; done
case "\$last" in */brief.md) printf 'key: %s\n' '$key' >> "\$last" ;; esac
exit \$rc
CPEOF
chmod +x "$cpbin/cp"
export TEST_ENV="PATH=$cpbin:$PATH"
invoke "$T/repo" swapped-brief
unset TEST_ENV
label='a secret in the copied brief is refused (exit 5) and nothing is started'
if [ "$code" -eq 5 ] && ! grep -q '^run ' "$STUB_ARGS" && grep -q 'brief.md:2: anthropic-key' "$home"/runs/*/secret-scan.txt 2>/dev/null; then pass; else fail "$label"; fi
label='the manifest exit is a JSON number'
invoke "$T/repo" exit-number
check jq -e '.exit == 0 and (.exit | type) == "number"' "$run/manifest.json"
# The open-agent check also runs when the run's workspace is no longer listed: an open child agent
# keeps the copy (retained, not deleted).
export STUB_WS_GONE_LATER=yes
echo '[{"id":"unrecorded-child","status":"running"}]' > "$STUB_WTS/children-agent-from-paseo-762.json"
invoke "$T/repo" gone-workspace-child
rm -f "$STUB_WTS/children-agent-from-paseo-762.json"
unset STUB_WS_GONE_LATER
label='workspace no longer listed but a child agent is open: the copy is retained, not deleted'
check test "$(cat "$home/retained/$(basename "$run")/NEW.txt" 2>/dev/null)" = work
# A commit in the source repo while the agent works must not break staging: BASE is fetched by id.
repo "$T/moving"
export STUB_COMMIT_SRC="$T/moving"
invoke "$T/moving" commit-during
unset STUB_COMMIT_SRC
label='a commit in the source repo during the build: the patch is still made and checked'
if [ "$code" -eq 0 ] && grep -q '^+++ b/NEW.txt' "$run/build.patch" && jq -e '.cleanup == "done"' "$run/manifest.json" >/dev/null &&
 [ "$(git -C "$T/moving" log --oneline | wc -l | tr -d ' ')" -ge 2 ]; then pass; else fail "$label"; fi
# The extra head copy: a signal while it is being cloned leaves none behind, and a later run's sweep
# removes one older than a day.
repo "$T/bigrepo"
( cd "$T/bigrepo" && i=0 && while [ "$i" -lt 12000 ]; do printf 'file %s\n' "$i" > "f$i.txt"; i=$((i + 1)); done && git add -A && git commit -qm many )
hh=$(TMPDIR="$HOME" mktmp)
: > "$STUB_ARGS"
env ROUTING_KIT_HOME="$hh" "$BIN" --paseo --repo "$T/bigrepo" --name sigclone --brief "$T/brief.md" >/dev/null 2>&1 &
bpid=$!
seen=no
for ((w=0; w<2000; w++)); do
  if ls -d "$hh"/head-* >/dev/null 2>&1; then seen=yes; kill -TERM "$bpid" 2>/dev/null; break; fi
  sleep 0.005
done
wait "$bpid" 2>/dev/null
label='the head copy was seen while it was being made (the signal hit the clone)'
check test "$seen" = yes
label='a signal during the clone leaves no head copy behind'
check test -z "$(ls -d "$hh"/head-* 2>/dev/null)"
mkdir -p "$hh/head-OLD123" "$hh/head-NEW456"
touch -t 202001010000 "$hh/head-OLD123"
env ROUTING_KIT_HOME="$hh" "$BIN" --paseo --repo "$T/repo" --name headsweep --brief "$T/brief.md" >/dev/null 2>&1
label='a later run removes a head copy older than a day and leaves a young one'
check test ! -e "$hh/head-OLD123" -a -d "$hh/head-NEW456"
export STUB_EMPTY_LOG=yes
invoke "$T/repo" empty-log
unset STUB_EMPTY_LOG
label='empty final message gets fallback'
check grep -q 'no final message' "$run/result.md"
export TEST_OPTIONS='--timeout 7'
invoke "$T/repo" custom-timeout
unset TEST_OPTIONS
label='custom timeout reaches Paseo'
check grep -q -- '--timeout 7 --json' "$STUB_ARGS"
export STUB_STATUS=permission
invoke "$T/repo" permission
unset STUB_STATUS
label='permission leaves agent and export running with pending manifest'
if [ "$code" -eq 6 ] && ! grep -q '^stop\|^archive' "$STUB_ARGS" && [ -d "$run/wt" ] && jq -e '.cleanup == "pending" and .exit == 6' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='permission wait names the kept worktree on the last line'
if printf '%s\n' "$out" | tail -1 | grep -qF "result=$run/result.md worktree=$run/wt (worktree kept: waiting on a permission)"; then pass; else fail "$label"; fi
label='permission note and final contract'
if grep -q 'waiting on a permission' "$run/result.md" && printf '%s\n' "$out" | tail -1 | grep -q 'exit=6 patch= result='; then pass; else fail "$label"; fi
export STUB_STATUS=timeout
invoke "$T/repo" timeout
unset STUB_STATUS
label='timeout saves edits and exits 124'
if [ "$code" -eq 124 ] && [ -s "$run/build.patch" ] && grep -q 'timed out' "$run/result.md"; then pass; else fail "$label"; fi
label='timeout stops and final line names patch'
if grep -q '^stop ' "$STUB_ARGS" && printf '%s\n' "$out" | tail -1 | grep -q "patch=$run/build.patch"; then pass; else fail "$label"; fi
label='manifest records lifecycle and full log'
if jq -e '.started != "" and .ended != "" and .worktree != "" and .cleanup != "" and .exit == 124' "$run/manifest.json" >/dev/null && [ -s "$run/log.txt" ]; then pass; else fail "$label"; fi
for opts in '--timeout 0' '--no-paseo --timeout 60'; do
 export TEST_OPTIONS="$opts"
 invoke "$T/repo" invalid-timeout
 label="reject invalid timeout: $opts"; check test "$code" -eq 2
done
unset TEST_OPTIONS
export STUB_STATUS=timeout STUB_RUNNING=yes
invoke "$T/repo" unconfirmed
unset STUB_STATUS STUB_RUNNING
label='unconfirmed timeout preserves tree without patch or archive'
if [ "$code" -eq 124 ] && [ -d "$run/wt" ] && [ ! -f "$run/build.patch" ] && ! grep -q '^archive ' "$STUB_ARGS" && jq -e '.cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='stale sweep preserves pending run'
touch -t 202001010000 "$run"
ROUTING_KIT_HOME="$home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; run_sweep_stale' _ "$BIN"
check test -d "$run/wt"
export TEST_PROFILE=broken
invoke "$T/repo" broken-profile
unset TEST_PROFILE
label='malformed profile has clear warning without jq error'
if printf '%s' "$out" | grep -q 'cannot read profile' && ! printf '%s' "$out" | grep -q 'parse error'; then pass; else fail "$label"; fi
echo dirty >> "$T/repo/a.txt"
invoke "$T/repo" dirty
label='dirty tree builds from HEAD with a warning'
if [ "$code" -eq 0 ] && [ -s "$run/build.patch" ] && ! grep -q dirty "$run/build.patch" && printf '%s\n' "$out" | grep -Ei 'dirty|clean' >/dev/null; then pass; else fail "$label"; fi
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
# Workspace archive guards (item 9). Each refusal must make no `workspace archive` call at all.
sweep_home() {
 : > "$STUB_ARGS"
 sweep_out=$(ROUTING_KIT_HOME="$home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; . "$(dirname "$1")/../lib/codex-paseo-build.sh"; codex_paseo_sweep' _ "$BIN" 2>&1)
}
export STUB_WS_LIST=two
invoke "$T/repo" two-workspaces
unset STUB_WS_LIST
label='two workspaces on the same tree: none archived, agent archived, left pending'
if [ "$code" -eq 0 ] && [ -f "$run/wt/NEW.txt" ] && grep -q '^+++ b/NEW.txt' "$run/build.patch" && ! grep -q '^workspace archive' "$STUB_ARGS" && grep -qx 'archive agent-from-paseo-762' "$STUB_ARGS" &&
 printf '%s\n' "$out" | grep -q 'workspace not archived: workspace lookup found 2 matches' &&
 printf '%s\n' "$out" | grep -q 'agent archived=true; workspace archived=false' &&
 jq -e '.archived == true and .workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='ambiguous workspace still ends with the patch contract line'
if printf '%s\n' "$out" | tail -1 | grep -q "exit=0 patch=$run/build.patch result="; then pass; else fail "$label"; fi
# The run never saw its own workspace: an empty list proves nothing about who is in the tree, so
# the tree stays and the run is pending (the owner's helper did the same on 0 matches).
export STUB_WS_LIST=none
invoke "$T/repo" no-workspace
unset STUB_WS_LIST
label='no workspace ever listed for the tree: tree kept, run pending'
if [ "$code" -eq 0 ] && ! grep -q '^workspace archive' "$STUB_ARGS" && [ -f "$run/wt/NEW.txt" ] && [ -s "$run/build.patch" ] &&
 printf '%s\n' "$out" | grep -q 'workspace lookup found 0 matches' &&
 jq -e '.workspace == "" and .workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_WS_GONE_LATER=yes
invoke "$T/repo" workspace-closed
unset STUB_WS_GONE_LATER
label='recorded workspace already closed at the finish: tree deleted, nothing to archive, run done'
if [ "$code" -eq 0 ] && ! grep -q '^workspace archive' "$STUB_ARGS" && [ ! -d "$run/wt" ] && [ -s "$run/build.patch" ] &&
 jq -e '.workspace == "workspace-762" and .archived == true and .workspace_archived == false and .cleanup == "done"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# The agent rewrote the tree's git metadata: the patch is saved, the tree stays, no workspace is
# archived, and the last line says why (the owner's helper refused the same way).
for shape in cfgworktree gsymlink badcommondir gitfile; do
 export STUB_SHAPE=$shape
 invoke "$T/repo" "meta-$shape"
 unset STUB_SHAPE
 label="changed git metadata ($shape): patch saved, tree kept, workspace not archived, pending"
 if grep -q '^+++ b/NEW.txt' "$run/build.patch" 2>/dev/null && [ -f "$run/wt/NEW.txt" ] && ! grep -q '^workspace archive' "$STUB_ARGS" &&
  jq -e '.cleanup == "pending" and .workspace_archived == false and .patch_final == false' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
 label="changed git metadata ($shape): last line says so and names the tree"
 if printf '%s\n' "$out" | tail -1 | grep -qF "patch=$run/build.patch result=$run/result.md worktree=$run/wt (worktree kept: git metadata changed"; then pass; else fail "$label"; fi
done
label='stale cleanup leaves a tree with changed git metadata alone after 24 h'
touch -t 202001010000 "$run"
ROUTING_KIT_HOME="$home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; run_sweep_stale' _ "$BIN"
check test -f "$run/wt/NEW.txt"
sweep_home
label='sweep leaves a tree with changed git metadata alone too'
if [ -f "$run/wt/NEW.txt" ] && ! grep -q '^workspace archive' "$STUB_ARGS" && jq -e '.cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_SHAPE=commit
invoke "$T/repo" meta-commit
unset STUB_SHAPE
label='a commit made by the agent is ordinary: patch holds it, tree deleted, workspace archived'
if [ "$code" -eq 0 ] && grep -q '^+++ b/NEW.txt' "$run/build.patch" && [ ! -d "$run/wt" ] && jq -e '.cleanup == "done" and .workspace_archived == true' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
mkdir -p "$T/other-root"
export KIT_CODEX_WORKTREES_ROOT="$T/other-root"
invoke "$T/repo" outside-root
unset KIT_CODEX_WORKTREES_ROOT
label='tree outside the worktree root: workspace never archived, tree kept'
if [ "$code" -eq 0 ] && [ -f "$run/wt/NEW.txt" ] && ! grep -q '^workspace archive' "$STUB_ARGS" && grep -qx 'archive agent-from-paseo-762' "$STUB_ARGS" &&
 printf '%s\n' "$out" | grep -q 'outside the worktree root' &&
 jq -e '.archived == true and .workspace_archived == false' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export ROUTING_KIT_KEEP_RUNS=1
invoke "$T/repo" tree-left
unset ROUTING_KIT_KEEP_RUNS
label='tree still on disk: workspace never archived'
if [ "$code" -eq 0 ] && [ -d "$run/wt" ] && ! grep -q '^workspace archive' "$STUB_ARGS" &&
 printf '%s\n' "$out" | grep -q 'worktree folder still exists'; then pass; else fail "$label"; fi
label='tree still on disk: the manifest says pending (tried again later), never done'
check jq -e '.cleanup == "pending"' "$run/manifest.json"
export STUB_WS_CHANGED=yes
invoke "$T/repo" changed-workspace
unset STUB_WS_CHANGED
label='a different workspace on the tree than at the start is not archived and its tree stays'
if [ "$code" -eq 0 ] && [ -f "$run/wt/NEW.txt" ] && jq -e '.cleanup == "pending"' "$run/manifest.json" >/dev/null && jq -e '.workspace == "workspace-762" and .workspace_archived == false' "$run/manifest.json" >/dev/null &&
 ! grep -q '^workspace archive' "$STUB_ARGS" && printf '%s\n' "$out" | grep -q 'different workspace'; then pass; else fail "$label"; fi
# A failed workspace archive is said, left pending, and finished by the next run's sweep.
export STUB_WS_ARCHIVE_FAIL=yes
invoke "$T/repo" workspace-archive-error
unset STUB_WS_ARCHIVE_FAIL
label='failed workspace archive is reported and left pending'
if [ "$code" -eq 0 ] && [ -s "$run/build.patch" ] && [ ! -d "$run/wt" ] &&
 printf '%s\n' "$out" | grep -q 'workspace not archived: paseo workspace archive failed' &&
 jq -e '.archived == true and .workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# Finding 2: after the tree is gone the saved patch is final. A folder that appears at the same
# path later is not this build's work: it is never staged, and the patch stays byte for byte.
cp "$run/build.patch" "$T/final.patch"
mkdir -p "$run/wt/nested/.git"; echo later > "$run/wt/later.txt"
export STUB_WS_ARCHIVE_FAIL=yes
sweep_home
unset STUB_WS_ARCHIVE_FAIL
label='sweep keeps the final patch when a folder with a nested repo reappears'
if cmp -s "$T/final.patch" "$run/build.patch" && [ -f "$run/wt/later.txt" ] && ! grep -q '^workspace archive' "$STUB_ARGS"; then pass; else fail "$label"; fi
rm -rf "$run/wt"; mkdir -p "$run/wt"; echo original > "$run/wt/a.txt"; echo later > "$run/wt/later.txt"
sweep_home
label='sweep keeps the final patch when a clean folder reappears'
if cmp -s "$T/final.patch" "$run/build.patch" && [ -f "$run/wt/a.txt" ] && ! grep -q '^workspace archive' "$STUB_ARGS"; then pass; else fail "$label"; fi
label='manifest records that the patch is final'
check jq -e '.patch_final == true' "$run/manifest.json"
# Re-review 2: no patch holds what is in a folder that reappeared, so the run stays pending and
# the generic stale cleanup never deletes that folder, however old the run is.
label='run with a reappeared folder stays pending'
check jq -e '.cleanup == "pending"' "$run/manifest.json"
label='stale cleanup leaves a reappeared folder alone after 24 h'
touch -t 202001010000 "$run"
ROUTING_KIT_HOME="$home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; run_sweep_stale' _ "$BIN"
check test -f "$run/wt/later.txt"
rm -rf "$run/wt"
# Re-review 1: a pending manifest written before patch_final existed cannot say whether a folder
# at the tree path is the build's own. Its saved patch is final: never staged again, never replaced.
export STUB_WS_ARCHIVE_FAIL=yes
invoke "$T/repo" old-manifest
unset STUB_WS_ARCHIVE_FAIL
jq 'del(.patch_final)' "$run/manifest.json" > "$run/m.tmp" && mv "$run/m.tmp" "$run/manifest.json"
cp "$run/build.patch" "$T/final.patch"
mkdir -p "$run/wt"; echo original > "$run/wt/a.txt"; echo later > "$run/wt/later.txt"
sweep_home
label='old pending manifest: saved patch survives a sweep over a reappeared folder'
if cmp -s "$T/final.patch" "$run/build.patch" && grep -q '^+++ b/NEW.txt' "$run/build.patch"; then pass; else fail "$label"; fi
label='old pending manifest: reappeared folder is not deleted and its workspace not archived'
if [ -f "$run/wt/later.txt" ] && ! grep -q '^workspace archive' "$STUB_ARGS" && jq -e '.cleanup == "pending" and .patch_final == true' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
rm -rf "$run/wt"
sweep_home
label='old pending manifest finishes once the folder is gone, patch unchanged'
if cmp -s "$T/final.patch" "$run/build.patch" && grep -qx 'workspace archive workspace-762' "$STUB_ARGS" && jq -e '.cleanup == "done"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# A patch that was saved is never overwritten: staging the build's own tree again (it stayed
# because two workspaces had it) keeps the earlier patch beside the new one.
export STUB_STATUS=permission
invoke "$T/repo" restage
unset STUB_STATUS
export STUB_WS_LIST=two
sweep_home
unset STUB_WS_LIST
cp "$run/build.patch" "$T/first.patch"
sweep_home
label='staging the same tree again leaves one patch and no copy'
if cmp -s "$T/first.patch" "$run/build.patch" && [ ! -e "$run/build.patch.earlier-1" ] && [ ! -d "$run/wt" ]; then pass; else fail "$label"; fi
export STUB_STATUS=permission
invoke "$T/repo" restage-changed
unset STUB_STATUS
export STUB_WS_LIST=two
sweep_home
unset STUB_WS_LIST
cp "$run/build.patch" "$T/first.patch"
echo more > "$run/wt/MORE.txt"; rm -f "$run/wt/NEW.txt"
sweep_home
label='staging a changed tree again keeps the earlier patch beside the new one'
if cmp -s "$T/first.patch" "$run/build.patch.earlier-1" && grep -q '^+++ b/MORE.txt' "$run/build.patch" && ! grep -q 'NEW.txt' "$run/build.patch" &&
 jq -e --arg p "$run/build.patch" '.cleanup == "done" and .patch == $p' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# Review B1: the manifest's branch is the one that holds the final checked patch. The branch of
# the first staging is not moved; the changed result gets the next name.
first_branch="kit-codex/$(basename "$run")"
label='manifest branch holds the final patch after the tree was staged again'
final_branch=$(jq -r '.branch' "$run/manifest.json")
if [ "$final_branch" = "$first_branch-2" ] && [ "$(git -C "$T/repo" show "$final_branch:MORE.txt" 2>/dev/null)" = more ] &&
 ! git -C "$T/repo" cat-file -e "$final_branch:NEW.txt" 2>/dev/null; then pass; else fail "$label"; fi
label='branch of the first staging is left as it was'
check test "$(git -C "$T/repo" show "$first_branch:NEW.txt" 2>/dev/null)" = work
# Sweep safety: the id saved in the manifest is never archived on its own word.
export STUB_STATUS=permission
invoke "$T/repo" sweep-two
unset STUB_STATUS
export STUB_WS_LIST=two
sweep_home
unset STUB_WS_LIST
label='sweep with two workspaces on the tree archives no workspace and stays pending'
if jq -e '.workspace == "workspace-762" and .workspace_archived == false and .archived == true and .cleanup == "pending"' "$run/manifest.json" >/dev/null &&
 ! grep -q '^workspace archive' "$STUB_ARGS" && [ -s "$run/build.patch" ] && [ -f "$run/wt/NEW.txt" ]; then pass; else fail "$label"; fi
sweep_home
label='sweep archives the workspace once it is the single match'
if grep -qx 'workspace archive workspace-762' "$STUB_ARGS" && [ ! -d "$run/wt" ] && [ -s "$run/build.patch" ] && jq -e '.workspace_archived == true and .cleanup == "done"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_STATUS=permission
invoke "$T/repo" sweep-other-id
unset STUB_STATUS
export STUB_WS_ID=workspace-other
sweep_home
unset STUB_WS_ID
label='sweep does not archive a workspace whose id differs from the saved one, and keeps the tree'
if ! grep -q '^workspace archive' "$STUB_ARGS" && [ -f "$run/wt/NEW.txt" ] && jq -e '.workspace == "workspace-762" and .workspace_archived == false and .archived == true' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_STATUS=permission
invoke "$T/repo" sweep-outside-root
unset STUB_STATUS
export KIT_CODEX_WORKTREES_ROOT="$T/other-root"
sweep_home
unset KIT_CODEX_WORKTREES_ROOT
label='sweep outside the worktree root archives no workspace and keeps the tree'
if ! grep -q '^workspace archive' "$STUB_ARGS" && [ -f "$run/wt/NEW.txt" ] && jq -e '.workspace_archived == false and .archived == true' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# Finding 4: without a recorded workspace id nothing proves which workspace the run made, so a
# later single occupant of the tree is never archived and the tree stays.
export STUB_WS_FIRST=two
invoke "$T/repo" sibling-later
unset STUB_WS_FIRST
label='no recorded workspace id: the later single workspace on the tree is not archived'
if [ "$code" -eq 0 ] && jq -e '.workspace == "" and .workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null &&
 ! grep -q '^workspace archive' "$STUB_ARGS" && [ -f "$run/wt/NEW.txt" ] && [ -s "$run/build.patch" ] &&
 printf '%s\n' "$out" | grep -q 'recorded no workspace id'; then pass; else fail "$label"; fi
export STUB_STATUS=permission
invoke "$T/repo" sweep-no-id
unset STUB_STATUS
jq '.workspace=""' "$run/manifest.json" > "$run/m.tmp" && mv "$run/m.tmp" "$run/manifest.json"
sweep_home
label='sweep of a manifest without a workspace id archives no workspace and keeps the tree'
if ! grep -q '^workspace archive' "$STUB_ARGS" && [ -f "$run/wt/NEW.txt" ] && [ -s "$run/build.patch" ] &&
 jq -e '.workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# Finding 5: a pending manifest is acted on only when Paseo shows exactly that agent id in exactly
# that run's tree. Anything else is a stale or foreign id and is left untouched.
export STUB_WS_ARCHIVE_FAIL=yes
invoke "$T/repo" foreign-agent
unset STUB_WS_ARCHIVE_FAIL
cp "$run/manifest.json" "$T/manifest.before"
rm -f "$STUB_WTS/agent-archived"
export STUB_AGENT_ID=foreign-agent STUB_AGENT_CWD="$T/repo"
sweep_home
unset STUB_AGENT_ID STUB_AGENT_CWD
label='sweep leaves a foreign agent behind a stale id alone (tree gone, patch saved)'
if ! grep -Eq '^(stop|archive|workspace archive) ' "$STUB_ARGS" && cmp -s "$T/manifest.before" "$run/manifest.json"; then pass; else fail "$label"; fi
export STUB_STATUS=permission
invoke "$T/repo" foreign-cwd
unset STUB_STATUS
cp "$run/manifest.json" "$T/manifest.before"
export STUB_AGENT_CWD="$T/repo"
sweep_home
unset STUB_AGENT_CWD
label='sweep leaves an agent with the right id but another cwd alone'
if ! grep -Eq '^(stop|archive|workspace archive) ' "$STUB_ARGS" && [ -f "$run/wt/NEW.txt" ] && cmp -s "$T/manifest.before" "$run/manifest.json"; then pass; else fail "$label"; fi
sweep_home
label='sweep keeps the finished run as a branch and records it'
sweep_branch="kit-codex/$(basename "$run")"
if [ "$(git -C "$T/repo" show "$sweep_branch:NEW.txt" 2>/dev/null)" = work ] && jq -e --arg b "$sweep_branch" '.branch == $b' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='sweep finishes the same run once id and cwd match'
if grep -qx 'stop agent-from-paseo-762' "$STUB_ARGS" && [ ! -d "$run/wt" ] && grep -q '^+++ b/NEW.txt' "$run/build.patch" &&
 jq -e '.cleanup == "done" and .archived == true and .workspace_archived == true' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# Finding 6: "agent archived=true" needs Paseo's record to say Archived. A successful `paseo archive`
# with an unreadable record is unconfirmed: said so, recorded as not archived, left pending.
export STUB_NO_ARCHIVED_FIELD=yes
invoke "$T/repo" no-archived-field
unset STUB_NO_ARCHIVED_FIELD
label='archive without a readable Archived record is unconfirmed, not archived'
if [ "$code" -eq 0 ] && grep -qx 'archive agent-from-paseo-762' "$STUB_ARGS" && jq -e '.archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null &&
 printf '%s\n' "$out" | grep -q 'agent archived=unconfirmed' && ! printf '%s\n' "$out" | grep -q 'agent archived=true'; then pass; else fail "$label"; fi
sweep_home
label='sweep confirms the archive once the record is readable'
check jq -e '.archived == true and .cleanup == "done"' "$run/manifest.json"
# 8.1b3 item 3: the sweep leaves a run alone when its repo or its tree is under a temp dir, the
# same rule as the refusal at the start. "Alone" means not one Paseo call and the same manifest.
export STUB_STATUS=permission
invoke "$T/repo" sweep-temp-repo
unset STUB_STATUS
jq '.repo="/tmp/kit-test-no-such-repo"' "$run/manifest.json" > "$run/m.tmp" && mv "$run/m.tmp" "$run/manifest.json"
cp "$run/manifest.json" "$T/manifest.before"
sweep_home
label='sweep leaves a pending run with a temp-dir repo alone'
if [ ! -s "$STUB_ARGS" ] && [ -f "$run/wt/NEW.txt" ] && [ ! -f "$run/build.patch" ] && cmp -s "$T/manifest.before" "$run/manifest.json"; then pass; else fail "$label"; fi
jq --arg r "$T/repo" '.repo=$r' "$run/manifest.json" > "$run/m.tmp" && mv "$run/m.tmp" "$run/manifest.json"
cp "$run/manifest.json" "$T/manifest.before"
old_tmp=${TMPDIR:-/tmp}
export TMPDIR="$home"
sweep_home
export TMPDIR="$old_tmp"
label='sweep leaves a pending run with a tree under TMPDIR alone'
if [ ! -s "$STUB_ARGS" ] && [ -f "$run/wt/NEW.txt" ] && cmp -s "$T/manifest.before" "$run/manifest.json"; then pass; else fail "$label"; fi
sweep_home
label='the same run is finished once neither path is under a temp dir'
if [ ! -d "$run/wt" ] && [ -s "$run/build.patch" ] && jq -e '.cleanup == "done"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_STATUS=permission TEST_HOME_TMP=yes
invoke "$T/repo" sweep-temp-tree
unset STUB_STATUS TEST_HOME_TMP
cp "$run/manifest.json" "$T/manifest.before"
sweep_home
label='sweep leaves a pending run with a tree under the system temp dir alone'
if [ ! -s "$STUB_ARGS" ] && [ -f "$run/wt/NEW.txt" ] && [ ! -f "$run/build.patch" ] && cmp -s "$T/manifest.before" "$run/manifest.json"; then pass; else fail "$label"; fi
# The same rule at the finish: a run whose tree is under a temp dir keeps its tree where it is and
# its workspace open; the patch is saved and the last line says why.
export TEST_HOME_TMP=yes
invoke "$T/repo" finish-temp-tree
unset TEST_HOME_TMP
label='finish under a temp dir: patch saved, tree kept in place, workspace not archived, pending'
if [ "$code" -eq 0 ] && grep -q '^+++ b/NEW.txt' "$run/build.patch" && [ -f "$run/wt/NEW.txt" ] && [ ! -e "$home/retained" ] &&
 ! grep -q '^workspace archive' "$STUB_ARGS" && jq -e '.cleanup == "pending" and .workspace_archived == false and .patch_final == false' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='finish under a temp dir: last line says so and names the tree'
if printf '%s\n' "$out" | tail -1 | grep -qF "result=$run/result.md worktree=$run/wt (worktree kept: repo or worktree is under a temp dir"; then pass; else fail "$label"; fi
# 8.1b3 item 4: the sweep archives stopped agents that finished earlier kit runs left open, and
# only those: named by a manifest of this transport, run done or gone, still listed by Paseo and
# not running, shown by Paseo with exactly the recorded id and that run's cwd.
invoke "$T/repo" retire-home
mkdir -p "$STUB_WTS/agents"
mkrun() { # NAME CLEANUP [REPO]
 mkdir -p "$home/runs/m1-$1"
 jq -n --arg a "$1" --arg c "$2" --arg repo "${3:-$T/repo}" --arg base "$base" --arg wt "$home/runs/m1-$1/wt" \
  '{agent:$a,repo:$repo,base:$base,worktree:$wt,started:"2020-01-01T00:00:00Z",cleanup:$c,archived:false}' > "$home/runs/m1-$1/manifest.json"
}
mkagent() { # ID CWD STATUS PERMISSIONS-JSON [REPORTED-ID]
 jq -n --arg id "${5:-$1}" --arg cwd "$2" --arg st "$3" --argjson perms "$4" \
  '{Id:$id,Cwd:$cwd,Status:$st,Archived:false,PendingPermissions:$perms}' > "$STUB_WTS/agents/$1.json"
}
mkrun leak-done done;       mkagent leak-done "$home/runs/m1-leak-done/wt" idle '[]'
mkrun leak-gone gone;       mkagent leak-gone "$home/runs/m1-leak-gone/wt" idle '[]'
mkrun leak-perm done;       mkagent leak-perm "$home/runs/m1-leak-perm/wt" idle '[{"id":"p1"}]'
mkrun leak-run done;        mkagent leak-run "$home/runs/m1-leak-run/wt" running '[]'
mkrun leak-unlisted done;   mkagent leak-unlisted "$home/runs/m1-leak-unlisted/wt" idle '[]'
mkrun leak-cwd done;        mkagent leak-cwd "$T/repo" idle '[]'
mkrun leak-id done;         mkagent leak-id "$home/runs/m1-leak-id/wt" idle '[]' some-other-agent
mkrun leak-kept kept;       mkagent leak-kept "$home/runs/m1-leak-kept/wt" idle '[]'
mkrun leak-temp done /tmp/kit-test-no-such-repo; mkagent leak-temp "$home/runs/m1-leak-temp/wt" idle '[]'
mkdir -p "$home/runs/m1-leak-legacy"
echo '{"agent":"leak-legacy","cleanup":"done","exit":"0"}' > "$home/runs/m1-leak-legacy/manifest.json"
mkagent leak-legacy "$home/runs/m1-leak-legacy/wt" idle '[]'
mkagent someone-else "$T/repo" idle '[]'
export STUB_LS='[{"id":"leak-done","status":"idle"},{"id":"leak-gone","status":"idle"},{"id":"leak-perm","status":"idle"},{"id":"leak-run","status":"running"},{"id":"leak-cwd","status":"idle"},{"id":"leak-id","status":"idle"},{"id":"leak-kept","status":"idle"},{"id":"leak-temp","status":"idle"},{"id":"leak-legacy","status":"idle"},{"id":"someone-else","status":"idle"}]'
sweep_home
label='sweep archives the stopped agents of done and gone earlier runs'
if grep -qx 'archive leak-done' "$STUB_ARGS" && grep -qx 'archive leak-gone' "$STUB_ARGS" &&
 jq -e '.archived == true' "$home/runs/m1-leak-done/manifest.json" >/dev/null && jq -e '.archived == true and .cleanup == "gone"' "$home/runs/m1-leak-gone/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='sweep leaves waiting, running, unlisted, wrong-cwd, wrong-id, kept, temp-dir and legacy agents alone'
if ! grep -qxE '(archive|stop) (leak-perm|leak-run|leak-unlisted|leak-cwd|leak-id|leak-kept|leak-temp|leak-legacy)' "$STUB_ARGS" &&
 jq -e '.archived == false' "$home/runs/m1-leak-perm/manifest.json" >/dev/null && jq -e '.archived == false' "$home/runs/m1-leak-cwd/manifest.json" >/dev/null; then pass; else fail "$label"; fi
label='sweep never looks at an agent no manifest names'
if ! grep -q 'someone-else' "$STUB_ARGS" && ! grep -qE '^(inspect|archive) (leak-unlisted|leak-run|leak-legacy|leak-kept)' "$STUB_ARGS"; then pass; else fail "$label"; fi
label='sweep makes exactly the two archive calls and no workspace or stop call'
if [ "$(grep -c '^archive ' "$STUB_ARGS")" -eq 2 ] && ! grep -Eq '^(stop|workspace archive) ' "$STUB_ARGS"; then pass; else fail "$label"; fi
sweep_home
unset STUB_LS
label='a second sweep has nothing left to archive'
check test "$(grep -c '^archive ' "$STUB_ARGS")" -eq 0
rm -rf "$STUB_WTS/agents"
# Review B2: `paseo archive` also archives an agent's open children, and `paseo workspace archive`
# every agent in the workspace. Neither is called while agents the kit did not start would go too.
invoke "$T/repo" retire-children
mkdir -p "$STUB_WTS/agents"
mkrun leak-parent done;     mkagent leak-parent "$home/runs/m1-leak-parent/wt" idle '[]'
mkrun leak-single done;     mkagent leak-single "$home/runs/m1-leak-single/wt" idle '[]'
echo '[{"id":"unrecorded-child","status":"running"}]' > "$STUB_WTS/children-leak-parent.json"
export STUB_LS='[{"id":"leak-parent","status":"idle"},{"id":"leak-single","status":"idle"},{"id":"unrecorded-child","status":"running"}]'
sweep_home
label='sweep leaves a finished agent with an open child agent alone'
if ! grep -qx 'archive leak-parent' "$STUB_ARGS" && jq -e '.archived == false' "$home/runs/m1-leak-parent/manifest.json" >/dev/null &&
 grep -qx 'archive leak-single' "$STUB_ARGS"; then pass; else fail "$label"; fi
rm -f "$STUB_WTS/children-leak-parent.json"
sweep_home
unset STUB_LS
label='sweep archives that agent once it has no open child'
check grep -qx 'archive leak-parent' "$STUB_ARGS"
rm -rf "$STUB_WTS/agents"
echo '[{"id":"unrecorded-child","status":"running"}]' > "$STUB_WTS/children-agent-from-paseo-762.json"
invoke "$T/repo" finish-children
label='finish with an open child agent archives neither the agent nor the workspace'
if [ "$code" -eq 0 ] && ! grep -Eq '^(archive|workspace archive) ' "$STUB_ARGS" && [ -s "$run/build.patch" ] &&
 jq -e '.archived == false and .workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null &&
 printf '%s\n' "$out" | grep -q 'open child agents'; then pass; else fail "$label"; fi
label='its copy is retained all the same'
check test "$(cat "$home/retained/$(basename "$run")/NEW.txt" 2>/dev/null)" = work
rm -f "$STUB_WTS/children-agent-from-paseo-762.json"
sweep_home
label='the next sweep archives both once the child is gone'
if grep -qx 'workspace archive workspace-762' "$STUB_ARGS" && jq -e '.archived == true and .workspace_archived == true and .cleanup == "done"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
export STUB_OTHER_IN_TREE=yes
invoke "$T/repo" finish-occupant
unset STUB_OTHER_IN_TREE
label='another open agent in the same folder: workspace not archived'
if [ "$code" -eq 0 ] && ! grep -q '^workspace archive' "$STUB_ARGS" && jq -e '.workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
# No path deletes a copy an agent worked in. Files git ignores are in no patch and no branch, so a
# pending run swept as done used to lose them; now the whole copy is in retained.
export STUB_STATUS=permission
invoke "$T/repo" ignored-files
unset STUB_STATUS
printf 'artifact.json\n' > "$run/wt/.gitignore"; echo '{"unique":"work-4711"}' > "$run/wt/artifact.json"
sweep_home
kept="$home/retained/$(basename "$run")"
label='sweep of a pending run keeps files git ignores: the copy is retained whole'
if jq -e '.cleanup == "done"' "$run/manifest.json" >/dev/null && [ ! -e "$run/wt" ] && ! grep -q 'work-4711' "$run/build.patch" &&
 grep -q 'work-4711' "$kept/artifact.json" 2>/dev/null && [ -f "$kept/NEW.txt" ]; then pass; else fail "$label"; fi
# The stale cleanup has no manifest to go by here. It still never deletes a copy an agent may have
# worked in; only a copy that still carries the agent-not-started mark is deleted.
stale_home=$(TMPDIR="$HOME" mktmp)
for kind in unreadable-manifest no-manifest never-started; do
 mkdir -p "$stale_home/runs/$kind/wt"; echo precious > "$stale_home/runs/$kind/wt/work.txt"
done
echo 'not json' > "$stale_home/runs/unreadable-manifest/manifest.json"
: > "$stale_home/runs/never-started/agent-not-started"
touch -t 202001010000 "$stale_home/runs/unreadable-manifest" "$stale_home/runs/no-manifest" "$stale_home/runs/never-started"
ROUTING_KIT_HOME="$stale_home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; run_sweep_stale' _ "$BIN"
label='stale cleanup retains a copy whose manifest is unreadable'
if [ ! -e "$stale_home/runs/unreadable-manifest/wt" ] && [ "$(cat "$stale_home/retained/unreadable-manifest/work.txt" 2>/dev/null)" = precious ]; then pass; else fail "$label"; fi
label='stale cleanup retains a copy without a manifest'
if [ ! -e "$stale_home/runs/no-manifest/wt" ] && [ "$(cat "$stale_home/retained/no-manifest/work.txt" 2>/dev/null)" = precious ]; then pass; else fail "$label"; fi
# Review finding 1: a file in the run dir is no permission to delete; an agent can write it.
label='stale cleanup retains a copy even when a file says no agent was started'
if [ ! -e "$stale_home/runs/never-started/wt" ] && [ "$(cat "$stale_home/retained/never-started/work.txt" 2>/dev/null)" = precious ]; then pass; else fail "$label"; fi
# A second copy with the same run name never replaces the first.
mkdir -p "$stale_home/runs/no-manifest/wt"; echo second > "$stale_home/runs/no-manifest/wt/work.txt"
ROUTING_KIT_HOME="$stale_home" bash -c '. "$(dirname "$1")/kit-common"; . "$(dirname "$1")/../lib/export.sh"; run_cleanup "$2" again' _ "$BIN" "$stale_home/runs/no-manifest"
label='a retained copy is never overwritten by a later one of the same name'
if [ "$(cat "$stale_home/retained/no-manifest/work.txt")" = precious ] && [ "$(cat "$stale_home/retained/no-manifest-2/work.txt" 2>/dev/null)" = second ] && grep -q '^why=again$' "$stale_home/retained/no-manifest-2.why"; then pass; else fail "$label"; fi
# Review finding 1 (Paseo): the agent recreates the "not started" mark and removes the started
# one. Its copy, ignored file included, is retained all the same.
export STUB_SHAPE=fakemark
invoke "$T/repo" forged-marks
unset STUB_SHAPE
label='forged run-dir marks do not get the copy deleted'
if [ "$code" -eq 0 ] && [ ! -e "$run/wt" ] && ! grep -q 'work-0815' "$run/build.patch" &&
 grep -q 'work-0815' "$home/retained/$(basename "$run")/artifact.json" 2>/dev/null; then pass; else fail "$label"; fi
# Review finding 3: the workspace is archived by id, so any agent that may be in it blocks the
# archive, whatever its cwd. An agent is "maybe in it" unless Paseo shows it is older than the run.
mkdir -p "$STUB_WTS/agents"
mkother() { # ID CWD CREATED
 jq -n --arg id "$1" --arg cwd "$2" --arg at "$3" '{Id:$id,Cwd:$cwd,Status:"running",Archived:false,CreatedAt:$at,PendingPermissions:[]}' > "$STUB_WTS/agents/$1.json"
}
mkother detached-worker "$T/repo" 2099-01-01T00:00:00.000Z
export STUB_LS="$(jq -cn --arg cwd "$T/repo" '[{id:"agent-from-paseo-762",status:"idle"},{id:"detached-worker",status:"running",cwd:$cwd}]')"
invoke "$T/repo" member-elsewhere
label='an agent created since the run started blocks the workspace archive, whatever its cwd'
if [ "$code" -eq 0 ] && ! grep -q '^workspace archive' "$STUB_ARGS" && [ -s "$run/build.patch" ] &&
 jq -e '.workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null &&
 printf '%s\n' "$out" | grep -q 'another open agent may be in this workspace'; then pass; else fail "$label"; fi
mkother detached-worker "$T/repo" 2020-01-01T00:00:00.000Z
sweep_home
label='an agent older than the run cannot be in its workspace: the sweep archives it'
if grep -qx 'workspace archive workspace-762' "$STUB_ARGS" && jq -e '.workspace_archived == true and .cleanup == "done"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
rm -f "$STUB_WTS/agents/detached-worker.json"
export STUB_LS='[{"id":"agent-from-paseo-762","status":"idle"},{"id":"unreadable-agent","status":"running"}]' STUB_INSPECT_OTHER_FAIL=yes
invoke "$T/repo" member-unreadable
unset STUB_LS STUB_INSPECT_OTHER_FAIL
label='an agent Paseo cannot describe blocks the workspace archive'
if [ "$code" -eq 0 ] && ! grep -q '^workspace archive' "$STUB_ARGS" && jq -e '.workspace_archived == false and .cleanup == "pending"' "$run/manifest.json" >/dev/null; then pass; else fail "$label"; fi
rm -rf "$STUB_WTS/agents"
# The Paseo agent runs as a worker (the owner's helper passed KIT_ROLE=worker; worker sessions get worker rules).
label='paseo run passes --env KIT_ROLE=worker'
check grep -q '^run .*--env KIT_ROLE=worker' "$STUB_ARGS"
printf 'test_codex_build_paseo: %s passed, %s failed (expanded cases)\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
