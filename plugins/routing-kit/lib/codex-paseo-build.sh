# Paseo transport for kit-codex-build.
#
# One rule holds on every path, the exit trap and the sweep included: nothing is moved away or
# archived until build.patch is saved and checked against BASE (an empty patch is the explicit
# "no changes" result), and the ownership checks run first. The exported tree is never deleted
# once the agent has been started in it, unless its work is saved: when the run is finished the tree
# is deleted if build.patch is checked, nothing is outside the patch and no other agent is open in
# it, and moved, whole, to $KIT_HOME/retained otherwise (lib/export.sh), before anything is
# archived. A run that cannot pass the checks stays "pending" with its tree untouched.
#
# Lifecycle variables (the sweep sets them per manifest in a subshell):
#   run_dir BASE paseo_repo paseo_agent  the run; paseo_workspace is the id recorded at the start
#   paseo_stopped       true once the stop is confirmed
#   paseo_patch_state   "" not tried, ok, failed
#   paseo_patch_final   true once build.patch is final and tree deletion may begin (persisted first)
#   paseo_pending       true: leave tree, workspace and agent alone
#   paseo_cleanup       manifest value: pending, kept, done

# Persist the lifecycle before waiting and after cleanup.
codex_paseo_manifest() {
  local ended="" exit_code="${1:-}" archived=false exit_json=null
  [ -z "$exit_code" ] || ended=$(date -u +%FT%TZ)
  case "$exit_code" in ''|*[!0-9]*) ;; *) exit_json=$exit_code ;; esac
  [ "${paseo_archived:-false}" != true ] || archived=true
  kit_jq -n --arg agent "${paseo_id:-}" --arg repo "$paseo_repo" --arg base "$BASE" \
    --arg wt "$run_dir/wt" --arg branch "${paseo_branch:-}" --arg started "$paseo_started" \
    --arg ended "$ended" --argjson exit "$exit_json" --arg patch "${paseo_patch:-}" \
    --arg workspace "${paseo_workspace:-}" --arg cleanup "${paseo_cleanup:-pending}" \
    --argjson archived "$archived" --argjson wsarchived "${paseo_workspace_archived:-false}" \
    --argjson final "${paseo_patch_final:-false}" --argjson continues "${paseo_continues:-0}" \
    '{agent:$agent,repo:$repo,base:$base,worktree:$wt,branch:$branch,started:$started,ended:$ended,exit:$exit,patch:$patch,workspace:$workspace,cleanup:$cleanup,archived:$archived,workspace_archived:$wsarchived,patch_final:$final,continues:$continues}' > "$run_dir/manifest.json.tmp" &&
    mv -f "$run_dir/manifest.json.tmp" "$run_dir/manifest.json"
}

# codex_paseo_agent_ours: 0 only when Paseo's record for the recorded id is exactly that agent, in
# exactly this run's tree. `paseo inspect` also resolves id prefixes and titles, and a manifest can be
# stale, so an agent is never stopped or archived on the id alone.
codex_paseo_agent_ours() {
  local info
  [ -n "${paseo_agent:-}" ] || return 1
  info=$(paseo inspect "$paseo_agent" --json 2>/dev/null) || return 1
  printf '%s' "$info" | kit_jq -e --arg id "$paseo_agent" --arg cwd "$run_dir/wt" \
    'type == "object" and .Id == $id and .Cwd == $cwd' >/dev/null 2>&1
}

# Confirmed stop: nothing may read or delete the exported tree while the agent can still write it.
# Unconfirmed (not provably ours, still running, or inspect unreadable): tree and agent are left alone.
codex_paseo_stop() {
  [ -n "${paseo_agent:-}" ] || return 0
  [ "${paseo_stopped:-false}" != true ] || return 0
  if [ "${KIT_CODEX_KEEP_WORKTREE:-}" = 1 ]; then
    paseo_cleanup=kept
    return 0
  fi
  local attempt info
  if ! codex_paseo_agent_ours; then
    paseo_pending=true
    paseo_cleanup=pending
    paseo_kept_why='agent id and cwd not confirmed by Paseo'
    echo 'kit-codex-build: agent id and cwd not confirmed by Paseo; worktree and agent left alone' >&2
    return 4
  fi
  for attempt in 1 2 3; do
    paseo stop "$paseo_agent" >/dev/null 2>&1 || true
    [ "$attempt" -eq 1 ] || sleep 1
    info=$(paseo inspect "$paseo_agent" --json 2>/dev/null) || continue
    if printf '%s' "$info" | kit_jq -e 'type == "object" and (.Status | type == "string") and .Status != "running" and ((.PendingPermissions // []) | length == 0)' >/dev/null 2>&1; then
      paseo_stopped=true
      return 0
    fi
  done
  paseo_pending=true
  paseo_cleanup=pending
  paseo_kept_why='stop unconfirmed'
  echo 'kit-codex-build: stop unconfirmed; worktree and agent kept' >&2
  return 4
}

# codex_paseo_save_patch REPO BASE: write build.patch from the stopped tree and check that it applies
# to BASE. An empty patch is the explicit "no changes" result. Sets paseo_patch_state (ok or failed).
# A patch that was saved before is never deleted or overwritten: it is moved to
# build.patch.earlier-N first, moved back if no new patch can be written, and kept beside the new
# one otherwise (dropped only when the new one is byte for byte the same).
codex_paseo_save_patch() {
  local repo=$1 base=$2 patch=$run_dir/build.patch prev="" verify n=1
  paseo_patch_state=failed
  paseo_branch=""
  if [ -f "$patch" ]; then
    while [ -e "$run_dir/build.patch.earlier-$n" ] || [ -L "$run_dir/build.patch.earlier-$n" ]; do n=$((n + 1)); done
    prev=$run_dir/build.patch.earlier-$n
    mv "$patch" "$prev" || return 4
  fi
  if ! run_build_patch_fresh "$run_dir/wt" "$repo" "$base" || [ ! -f "$patch" ]; then
    [ -z "$prev" ] || mv "$prev" "$patch"
    return 4
  fi
  if [ -n "$prev" ] && cmp -s "$prev" "$patch"; then rm -f "$prev"; fi
  if [ -s "$patch" ]; then
    verify=$(mktemp -d "$KIT_HOME/verify-XXXXXX") || return 4
    if ! kit_git clone --no-local --quiet "$repo" "$verify" ||
       ! kit_git -C "$verify" read-tree "$base" ||
       ! kit_git -C "$verify" apply --cached --check "$patch"; then
      rm -rf "$verify"
      echo 'kit-codex-build: patch self-check failed' >&2
      return 4
    fi
    codex_paseo_keep_branch "$repo" "$base" "$verify" ||
      echo 'kit-codex-build: warning: could not keep the build as a branch; build.patch is complete' >&2
    rm -rf "$verify"
  else
    echo 'kit-codex-build: no changes' >&2
  fi
  paseo_patch_state=ok
  return 0
}

# codex_paseo_keep_branch REPO BASE VERIFY: keep the checked build as a branch in the source repo, so
# it outlives the exported tree and its Paseo workspace: kit-codex/<run dir name>, one commit on BASE
# holding BASE plus build.patch. The commit is made in the throwaway clone VERIFY (its index already
# holds BASE) and only fetched into REPO: nothing there is checked out, staged or moved, and a
# branch that already exists is never changed. Sets paseo_branch to the branch that holds this
# build, or to "" when there is none.
codex_paseo_keep_branch() {
  local repo=$1 base=$2 verify=$3 stem branch tree commit have n=1
  paseo_branch=""
  stem="kit-codex/$(basename "$run_dir")"
  kit_git -C "$repo" check-ref-format "refs/heads/$stem" || return 1
  kit_git -C "$verify" apply --cached "$run_dir/build.patch" || return 1
  tree=$(kit_git -C "$verify" write-tree) || return 1
  commit=$(kit_git -C "$verify" -c user.name=kit-codex-build -c user.email=kit-codex-build@localhost \
    commit-tree "$tree" -p "$base" -m "kit-codex-build: build result of $(basename "$run_dir")") || return 1
  [ -n "$commit" ] || return 1
  # A branch of an earlier attempt is never moved. Same content: it is this build's branch.
  # Other content (the tree was staged again and had changed): this result gets the next free
  # name, <stem>-2, <stem>-3, so the recorded branch always holds the final checked patch.
  branch=$stem
  while have=$(kit_git -C "$repo" rev-parse -q --verify "refs/heads/$branch^{tree}" 2>/dev/null); do
    if [ "$have" = "$tree" ]; then
      paseo_branch=$branch
      return 0
    fi
    n=$((n + 1))
    [ "$n" -le 99 ] || return 1
    branch="$stem-$n"
  done
  kit_git -C "$verify" update-ref refs/heads/kit-build-result "$commit" || return 1
  kit_git -C "$repo" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-tags --no-write-fetch-head \
      "$verify" "refs/heads/kit-build-result:refs/heads/$branch" 2>/dev/null ||
    kit_git -C "$repo" -c gc.auto=0 fetch --quiet --no-tags \
      "$verify" "refs/heads/kit-build-result:refs/heads/$branch" 2>/dev/null || return 1
  paseo_branch=$branch
  return 0
}

# codex_paseo_in_temp PATH: 0 when PATH is under a temp dir (/tmp, /var/folders, $TMPDIR). A Paseo
# build is refused for a repo there, and the sweep leaves such a run alone.
codex_paseo_in_temp() {
  local tmp
  case "$1/" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
  esac
  tmp=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || return 1
  case "$1/" in
    "$tmp"/*) return 0 ;;
  esac
  return 1
}

# codex_paseo_run_in_temp REPO RUN_DIR: 0 when the run's repo or its tree is under a temp dir, by
# the path as written or as resolved.
codex_paseo_run_in_temp() {
  local repo=$1 dir=$2 real
  real=$(kit_realpath "$repo")
  ! codex_paseo_in_temp "$repo" && ! codex_paseo_in_temp "${real:-$repo}" || return 0
  real=$(kit_realpath "$dir")
  ! codex_paseo_in_temp "$dir/wt" && ! codex_paseo_in_temp "${real:-$dir}/wt" || return 0
  return 1
}

# codex_paseo_agent_archive: archive the agent (ends its Codex server) and read the result from
# Paseo's own record. Sets paseo_archived to true only when `paseo inspect` says Archived; false when
# it says not archived; unconfirmed when the record cannot be read.
# The exit status of `paseo archive` is never the answer: it is non-zero for an agent that is already
# archived (archiving a workspace archives its agents), which printed a false "agent not archived".
codex_paseo_agent_archive() {
  local info
  paseo_archived=unconfirmed
  paseo_archive_why=""
  # `paseo archive` also archives the agent's open child agents, running or not. Those are not
  # the kit's, so an agent with any open child (or an unreadable list) is left open.
  if codex_paseo_no_open_children "$paseo_agent"; then
    paseo archive "$paseo_agent" >/dev/null 2>&1 || true
  else
    paseo_archive_why='it has open child agents in Paseo, or they could not be listed; archiving it would archive them too'
  fi
  info=$(paseo inspect "$paseo_agent" --json 2>/dev/null) || return 1
  printf '%s' "$info" | kit_jq -e --arg id "$paseo_agent" \
    'type == "object" and .Id == $id and (.Archived | type == "boolean")' >/dev/null 2>&1 || return 1
  if printf '%s' "$info" | kit_jq -e '.Archived == true' >/dev/null 2>&1; then
    paseo_archived=true
    return 0
  fi
  paseo_archived=false
  return 1
}

# codex_paseo_no_open_children AGENT: 0 only when Paseo's own list is readable and shows no open
# agent whose parent is AGENT (children carry the label paseo.parent-agent-id).
codex_paseo_no_open_children() {
  local listing
  listing=$(paseo ls -g --json --label "paseo.parent-agent-id=$1" 2>/dev/null) || return 1
  printf '%s' "$listing" | kit_jq -e 'type == "array" and length == 0' >/dev/null 2>&1
}

# codex_paseo_workspace_ours_alone: 0 only when no other open agent can be a member of this run's
# workspace. `paseo workspace archive` archives every agent of the workspace, whatever its cwd, and
# the CLI does not say which workspace an agent belongs to. What it does say is when an agent was
# created, and an agent joins a workspace when it is created: one created before this run's
# workspace existed cannot be in it. So every other open agent must be shown, by `paseo inspect`,
# to be older than this run (a minute to spare) and to have its cwd outside the run's tree.
# Anything else, or anything unreadable, leaves the workspace open.
codex_paseo_workspace_ours_alone() {
  local listing wt=$run_dir/wt short other info
  short=$wt
  case "$wt" in "$HOME"/*) short="~${wt#"$HOME"}" ;; esac
  [ -n "${paseo_started:-}" ] || return 1
  listing=$(paseo ls -g --json 2>/dev/null) || return 1
  printf '%s' "$listing" | kit_jq -e 'type == "array" and all(.[]; (.id | type == "string") and (.id | test("^[A-Za-z0-9._-]+$")))' >/dev/null 2>&1 || return 1
  printf '%s' "$listing" | kit_jq -e --arg id "$paseo_agent" --arg wt "$wt" --arg short "$short" \
    '[.[] | select(.id != $id) | select((.cwd // "") as $c | $c == $wt or $c == $short or ($c | startswith($wt + "/")) or ($c | startswith($short + "/")))] | length == 0' >/dev/null 2>&1 || return 1
  for other in $(printf '%s' "$listing" | kit_jq -r --arg id "$paseo_agent" '.[] | select(.id != $id) | .id | select(test("^[A-Za-z0-9._-]+$"))' 2>/dev/null); do
    info=$(paseo inspect "$other" --json 2>/dev/null) || return 1
    printf '%s' "$info" | kit_jq -e --arg id "$other" --arg wt "$wt" --arg started "$paseo_started" \
      'def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
       type == "object" and .Id == $id and (.Cwd | type == "string") and .Cwd != $wt and (.Cwd | startswith($wt + "/") | not)
       and ((.CreatedAt | secs) < (($started | secs) - 60))' >/dev/null 2>&1 || return 1
  done
  return 0
}

# codex_paseo_tree_plain: 0 while the tree's git metadata is still the plain directory the export
# made. The agent runs unconfined and can rewrite it; a .git that became a symlink or a gitfile, or
# that gained a commondir, gitdir or config.worktree file, points git somewhere else or adds config
# of the agent's choosing. The kit never runs git against it, but a run that did this is not
# deleted or archived unseen: the saved patch stays, and so does the tree, for a look.
codex_paseo_tree_plain() {
  local wt=$run_dir/wt g f
  g=$wt/.git
  [ -d "$wt" ] && [ ! -L "$wt" ] || return 1
  [ -d "$g" ] && [ ! -L "$g" ] || return 1
  for f in commondir gitdir config.worktree; do
    [ ! -e "$g/$f" ] && [ ! -L "$g/$f" ] || return 1
  done
  for f in config HEAD; do
    [ -f "$g/$f" ] && [ ! -L "$g/$f" ] || return 1
  done
  for f in objects refs; do
    [ -d "$g/$f" ] && [ ! -L "$g/$f" ] || return 1
  done
  return 0
}

# codex_paseo_workspace_check: decide what may happen to the tree and the workspace. Nothing is
# changed here; the caller runs it before the first deletion. Sets paseo_ws_action:
#   archive  exactly one listed workspace has exactly this cwd and its id is the non-empty id recorded
#            when the run started (paseo_ws_id); one listing gives both the count and the id
#   none     the recorded workspace is no longer open and no other workspace has this cwd:
#            nothing to archive, nobody else is in the tree
#   refuse   anything else (tree outside the worktree root, list unreadable, several matches, no
#            recorded id, another id): a sibling may be using the tree, so it must stay.
#            paseo_ws_retry says whether a later look can end differently.
# The worktree root is $KIT_HOME/runs, or KIT_CODEX_WORKTREES_ROOT.
codex_paseo_workspace_check() {
  local wt=$run_dir/wt root parent listing n id
  paseo_ws_action=refuse
  paseo_ws_id=""
  paseo_ws_retry=false
  paseo_workspace_why=""
  root=$(kit_realpath "${KIT_CODEX_WORKTREES_ROOT:-$KIT_HOME/runs}")
  parent=$(kit_realpath "$run_dir")
  if [ -z "$root" ] || [ -z "$parent" ] || [ "$parent/wt" != "$wt" ]; then
    paseo_workspace_why='worktree path is not canonical'
    return 0
  fi
  case "$wt" in
    "$root"/?*) ;;
    *) paseo_workspace_why='worktree is outside the worktree root'
       return 0 ;;
  esac
  if ! listing=$(paseo workspace ls --json 2>/dev/null) ||
     ! n=$(printf '%s' "$listing" | kit_jq -r --arg wt "$wt" 'if type == "array" then [.[] | select(.cwd == $wt)] | length else error("not a list") end' 2>/dev/null); then
    paseo_workspace_why='workspace list unreadable'
    paseo_ws_retry=true
    return 0
  fi
  case "$n" in
    0) if [ -z "${paseo_workspace:-}" ]; then
         # The run never saw its own workspace, so an empty list proves nothing about the tree.
         paseo_workspace_why='workspace lookup found 0 matches and the run recorded no workspace id'
         paseo_ws_retry=true
         return 0
       fi
       paseo_ws_action=none
       paseo_workspace_why='the recorded workspace is no longer open; nothing to archive'
       return 0 ;;
    1) ;;
    *) paseo_workspace_why="workspace lookup found ${n:-no answer} matches"
       paseo_ws_retry=true
       return 0 ;;
  esac
  id=$(printf '%s' "$listing" | kit_jq -r --arg wt "$wt" '[.[] | select(.cwd == $wt)][0].workspaceId // empty' 2>/dev/null) || id=""
  if [ -z "${paseo_workspace:-}" ]; then
    paseo_workspace_why='the run recorded no workspace id, so the workspace on this worktree cannot be told from a sibling'
  elif [ -z "$id" ] || [ "$paseo_workspace" != "$id" ]; then
    paseo_workspace_why='a different workspace now has this worktree'
  else
    paseo_ws_action=archive
    paseo_ws_id=$id
  fi
  return 0
}

# codex_paseo_persist_final: record, before the first deletion, that build.patch is final. A retry in
# that state never stages a folder again (a recreated one would replace the only copy of the work).
codex_paseo_persist_final() {
  paseo_patch_final=true
  if [ -n "${paseo_sweep_manifest:-}" ]; then
    kit_jq '.patch_final = true' "$paseo_sweep_manifest" > "$paseo_sweep_manifest.tmp" &&
      mv -f "$paseo_sweep_manifest.tmp" "$paseo_sweep_manifest"
  else
    paseo_cleanup=pending
    codex_paseo_manifest
  fi
}

# codex_paseo_finalize: everything after the wait, in the one order that cannot lose work. The exit
# trap runs it on every exit path once an agent exists (signals included) and the sweep runs it for
# earlier pending runs.
#   1 the agent is provably this run's (exact id and cwd) and its stop is confirmed
#   2 build.patch is saved and checked, unless it is already final
#   3 the workspace check passes: only then is the patch marked final and the tree deleted, or
#     moved to $KIT_HOME/retained when something in it is not saved (run_cleanup_checked)
#   4 the workspace is archived, then the agent; one line says what Paseo now holds
# Returns 4 when the run is left with no verified patch or an unconfirmed stop. Sets paseo_cleanup.
codex_paseo_finalize() {
  local wt=$run_dir/wt ws_note="" retry=false kept_note="" open_why="" ws_checked=false
  paseo_cleanup=pending
  paseo_workspace_archived=false
  codex_paseo_stop || return 4
  if [ "${paseo_patch_final:-false}" != true ]; then
    if [ -z "${paseo_patch_state:-}" ] && [ -d "$wt" ]; then
      codex_paseo_save_patch "$paseo_repo" "$BASE" || true
    fi
    if [ "${paseo_patch_state:-}" != ok ]; then
      paseo_kept_why='no verified patch'
      echo "kit-codex-build: no verified patch; worktree kept and nothing archived: $wt" >&2
      echo "kit-codex-build: run dir: $run_dir; nothing archived; worktree kept (no verified patch)"
      return 4
    fi
  elif [ ! -f "$run_dir/build.patch" ]; then
    echo "kit-codex-build: final patch is missing; nothing touched: $run_dir" >&2
    return 4
  fi
  codex_paseo_workspace_check
  if [ "${paseo_patch_final:-false}" != true ] && ! codex_paseo_tree_plain; then
    paseo_ws_action=refuse
    paseo_workspace_why='git metadata changed in the worktree; check it, then delete it and archive the workspace yourself'
  fi
  # The temp-dir rule of the start (refusal) and of the sweep (skip) holds at the finish too: a run
  # whose repo or tree is under a temp dir keeps its tree where it is and its workspace open.
  if [ "${paseo_patch_final:-false}" != true ] && codex_paseo_run_in_temp "$paseo_repo" "$run_dir"; then
    paseo_ws_action=refuse
    paseo_workspace_why='repo or worktree is under a temp dir; check it, then archive the workspace yourself'
  fi
  if [ "${paseo_patch_final:-false}" = true ]; then
    # The tree was deleted by an earlier attempt. A folder there now is not this build's work, and
    # no patch holds what is in it: it is left alone, and the run stays "pending" so that the stale
    # cleanup never deletes it either.
    if [ -e "$wt" ] || [ -L "$wt" ]; then
      paseo_ws_action=refuse
      paseo_workspace_why='a folder exists again at the worktree path; it is left alone, archive the workspace yourself after checking'
      retry=true
      kept_note="; folder left alone"
      paseo_kept_why=$paseo_workspace_why
    elif [ "$paseo_ws_action" = refuse ]; then
      # Nothing of the build is left to protect; only a refusal that can change is tried again.
      retry=$paseo_ws_retry
    fi
  elif [ "$paseo_ws_action" = refuse ]; then
    # The tree stays, and "pending" is what keeps the stale cleanup away from it.
    retry=true
    kept_note="; worktree kept"
    paseo_kept_why=$paseo_workspace_why
  elif ! codex_paseo_persist_final; then
    paseo_patch_final=false
    paseo_ws_action=refuse
    paseo_workspace_why='could not record the final patch'
    retry=true
    kept_note="; worktree kept"
    paseo_kept_why=$paseo_workspace_why
  else
    # Another open agent in this workspace (a child agent, or one created since the run started)
    # may be working in the tree: then it is moved, not deleted, and the workspace is not archived.
    # Asked whatever the workspace action is: no workspace listed does not mean no agent in the tree.
    ws_checked=true
    if ! { codex_paseo_no_open_children "$paseo_agent" && codex_paseo_workspace_ours_alone; }; then
      open_why='another open agent may be in this workspace (a child agent, or one created since the run started), or the agents could not be read'
    fi
    # The tree is deleted when its work is saved, otherwise moved, whole, to $KIT_HOME/retained,
    # outside the workspace, before anything is archived. A tree that can be neither stays, nothing
    # is archived around it, and the run is tried again.
    run_cleanup_checked "$run_dir" "kit-codex-build (Paseo) finished" "$paseo_repo" "$BASE" "$open_why" || true
    if [ -e "$wt" ] || [ -L "$wt" ]; then
      paseo_ws_action=refuse
      paseo_workspace_why='worktree folder still exists; archive the workspace yourself after moving it away'
      retry=true
      kept_note="; worktree kept"
      paseo_kept_why=$paseo_workspace_why
    elif [ "${RUN_CLEANUP_RESULT:-}" = deleted ]; then
      kept_note="; copy deleted (build.patch saved and checked, nothing outside it)"
    elif [ -s "$run_dir/retained-at" ]; then
      kept_note="; copy retained: $(cat "$run_dir/retained-at")"
    fi
  fi
  if [ "$paseo_ws_action" = archive ]; then
    # Archiving the workspace would archive agents the kit did not start. (Already asked above
    # when the tree was just dealt with: the answer is open_why.)
    if [ "$ws_checked" != true ]; then
      { codex_paseo_no_open_children "$paseo_agent" && codex_paseo_workspace_ours_alone; } \
        || open_why='another open agent may be in this workspace (a child agent, or one created since the run started), or the agents could not be read'
    fi
    if [ -n "$open_why" ]; then
      paseo_ws_action=refuse
      paseo_workspace_why=$open_why
      retry=true
    fi
  fi
  if [ "$paseo_ws_action" = archive ]; then
    if paseo workspace archive "$paseo_ws_id" >/dev/null 2>&1; then
      paseo_workspace_archived=true
    else
      paseo_workspace_why='paseo workspace archive failed'
      retry=true
    fi
  fi
  if ! codex_paseo_agent_archive; then
    retry=true
    if [ "$paseo_archived" = false ]; then
      echo "kit-codex-build: agent not archived: $paseo_agent${paseo_archive_why:+ ($paseo_archive_why)}" >&2
    else
      echo "kit-codex-build: agent archive unconfirmed (Paseo's record could not be read): $paseo_agent" >&2
    fi
  fi
  if [ "$paseo_workspace_archived" != true ]; then
    ws_note=" ($paseo_workspace_why)"
    [ "$paseo_ws_action" = none ] || echo "kit-codex-build: workspace not archived: $paseo_workspace_why" >&2
  fi
  [ "$retry" = true ] || paseo_cleanup=done
  echo "kit-codex-build: run dir: $run_dir; agent archived=$paseo_archived; workspace archived=$paseo_workspace_archived$ws_note$kept_note"
  return 0
}

# codex_paseo_wait_and_record AGENT SECS: waits for the agent, then saves its log and last message
# (log.txt, result.md). Sets $code to what the state maps to: 0 idle, 6 permission, 124 timeout,
# 4 anything else. (Not a command substitution: a signal must reach this shell during the wait.)
codex_paseo_wait_and_record() {
  local agent=$1 secs=$2 state
  paseo wait "$agent" --timeout "$secs" --json > "$run_dir/wait.json"
  state=$(kit_jq -r '.status' "$run_dir/wait.json")
  case "$state" in idle) code=0 ;; permission) code=6 ;; timeout) code=124 ;; *) code=4 ;; esac
  paseo logs "$agent" > "$run_dir/log.txt" 2>&1
  paseo logs "$agent" --filter text --tail 1 2>/dev/null | sed '/^---$/d' > "$run_dir/result.md"
  grep -q '[^[:space:]]' "$run_dir/result.md" || echo "(no final message from Codex; exit $code)" > "$run_dir/result.md"
}

# Optional Paseo transport for the Codex build runner.
codex_paseo_build() {
  local repo agent state code=0 info
  repo=$(kit_git -C "$REPO" rev-parse --show-toplevel) || return 2
  repo=$(cd "$repo" && pwd -P) || return 2
  ! codex_paseo_in_temp "$repo" || kit_die 2 'refusing temp repo for Paseo build'
  [ -z "$(kit_git -C "$repo" status --porcelain)" ] || echo 'kit-codex-build: dirty repo; building committed HEAD only' >&2
  command -v paseo >/dev/null 2>&1 || kit_die 3 'no paseo on PATH'
  [ "${KIT_CODEX_KEEP_WORKTREE:-}" = 1 ] || codex_paseo_sweep >&2
  BASE=$(kit_git -C "$repo" rev-parse HEAD) || return 2
  local export_repo export_code
  mkdir -p "$KIT_HOME" || return 4
  # paseo_head_copy: the exit trap of kit-codex-build removes it too, so a signal during the clone
  # or checkout leaves nothing behind.
  paseo_head_copy=$(mktemp -d "$KIT_HOME/head-XXXXXX") || return 4
  export_repo=$paseo_head_copy
  kit_git clone --no-local --quiet "$repo" "$export_repo" || { rm -rf "$export_repo"; return 4; }
  kit_git -C "$export_repo" checkout --quiet --detach "$BASE" || { rm -rf "$export_repo"; return 4; }
  run_dir=$(run_export "$export_repo" "$NAME")
  export_code=$?
  rm -rf "$export_repo"
  paseo_head_copy=""
  [ "$export_code" -eq 0 ] || return "$export_code"
  run_claim "$run_dir"
  # The brief is copied first, and the copy is the file that is scanned and sent: scanning the
  # original and sending a later copy would leave a gap for another process to swap in a secret.
  # The original's own name is checked first (secret_scan's file-name rules would never see "brief.md").
  secret_scan --credentials-only "$BRIEF" >"$run_dir/secret-scan-brief-name.txt" 2>&1 || return 5
  cp "$BRIEF" "$run_dir/brief.md" || return 2
  secret_scan --credentials-only "$run_dir/brief.md" "$run_dir/wt" >"$run_dir/secret-scan.txt" 2>&1 || return 5
  local child_var
  for child_var in $(compgen -e); do
    case "$child_var" in CLAUDE_CONFIG_DIR) ;; CLAUDE*) unset "$child_var" ;; esac
  done
  if [ "$(uname -s)" = Darwin ] && command -v caffeinate >/dev/null 2>&1; then
    caffeinate -is -w $$ >/dev/null 2>&1 &
  fi
  run_agent_started "$run_dir" || return 4
  # Taken before the workspace exists: agents older than this cannot be members of it.
  local run_at
  run_at=$(date -u +%FT%TZ)
  agent=$(paseo run -d -q --provider "codex/$MODEL" --mode full-access --new-workspace local --cwd "$run_dir/wt" \
    --title "Codex build: $NAME" --env KIT_ROLE=worker "$(cat "$run_dir/brief.md")" </dev/null) || return 3
  [ -n "$agent" ] || return 3
  paseo_agent=$agent
  paseo_repo=$repo
  paseo_id=$agent
  paseo_started=$run_at
  codex_paseo_manifest
  # The agent is this run's own (the id is from `paseo run` itself), so a wrong start is stopped,
  # best effort. Nothing else is touched: it stays pending with its tree, for a look in Paseo.
  info=$(paseo inspect "$agent" --json) || {
    paseo stop "$agent" >/dev/null 2>&1 || true
    paseo_pending=true
    return 4
  }
  if ! printf '%s' "$info" | kit_jq -e --arg id "$agent" --arg cwd "$run_dir/wt" '.Id == $id and .Cwd == $cwd' >/dev/null; then
    echo "kit-codex-build: agent id or cwd does not match scrubbed export; agent stopped, nothing archived" >&2
    paseo stop "$agent" >/dev/null 2>&1 || true
    paseo_pending=true
    paseo_kept_why='agent id or cwd does not match the export'
    return 4
  fi
  # Recorded only when exactly one workspace has this cwd; the archive step lists again and compares.
  paseo_workspace=$(paseo workspace ls --json 2>/dev/null | kit_jq -r --arg wt "$run_dir/wt" '[.[] | select(.cwd == $wt)] | if length == 1 then .[0].workspaceId // empty else empty end' 2>/dev/null) || paseo_workspace=""
  codex_paseo_manifest
  # One wait budget for the whole run: a continue never resets it.
  local deadline continue_why="" left
  deadline=$(( $(date +%s) + TIMEOUT ))
  paseo_continues=0
  codex_paseo_wait_and_record "$agent" "$TIMEOUT"
  # An agent that ended its turn with the work clearly unfinished gets a "continue" (up to
  # KIT_CODEX_CONTINUES times). Only a finished wait (idle) is ever continued: a timeout, a
  # permission wait and an error keep their own ending.
  while [ "$code" -eq 0 ] && continue_why=$(codex_continue_check "$run_dir/brief.md" "$run_dir/result.md"); do
    if [ "$paseo_continues" -ge "${KIT_CODEX_CONTINUES_N:-3}" ]; then
      echo "(stopped early after $paseo_continues continues: $continue_why)" >> "$run_dir/result.md"
      break
    fi
    left=$(( deadline - $(date +%s) ))
    if [ "$left" -lt 1 ]; then
      echo "(stopped early after $paseo_continues continues: $continue_why; the time budget is used up)" >> "$run_dir/result.md"
      code=124
      break
    fi
    codex_continue_message > "$run_dir/continue-message.txt"
    paseo send "$agent" --no-wait --prompt-file "$run_dir/continue-message.txt" >/dev/null 2>&1 || {
      echo "(stopped early after $paseo_continues continues: could not send the continue message)" >> "$run_dir/result.md"
      code=4
      break
    }
    paseo_continues=$((paseo_continues + 1))
    codex_paseo_manifest
    codex_paseo_wait_and_record "$agent" "$left"
  done
  [ "$paseo_continues" -eq 0 ] || echo "(continued $paseo_continues time(s) after the agent stopped early)" >> "$run_dir/result.md"
  [ "$code" -ne 124 ] || echo "(timed out after ${TIMEOUT}s; the text above may not be final)" >> "$run_dir/result.md"
  if [ "$code" -eq 6 ]; then
    echo '(waiting on a permission: answer it in the Paseo app)' >> "$run_dir/result.md"
    paseo_pending=true
    paseo_kept_why='waiting on a permission'
    return 6
  fi
  codex_paseo_stop || { [ "$code" -eq 124 ] || code=4; }
  [ "${paseo_pending:-false}" != true ] || return "$code"
  # Save and check the patch now; the exit trap (codex_paseo_finalize) moves the tree away and archives
  # the workspace and the agent only if this worked.
  if codex_paseo_save_patch "$repo" "$BASE"; then
    cat "$run_dir/build.patch"
    [ -z "${paseo_branch:-}" ] || echo "kit-codex-build: branch: $paseo_branch (kept in $repo)"
  else
    [ "$code" -eq 124 ] || code=4
  fi
  return "$code"
}

# codex_paseo_sweep_run MANIFEST: 0 when the manifest is a run of this transport that the sweep may
# look at; sets run_dir, wt and paseo_agent. Never eligible: a manifest without the transport's
# fields, a path that is not the plain <run dir>/wt, a run whose repo or tree is under a temp dir
# (same rule as the refusal at the start), and a run whose owner process is alive.
codex_paseo_sweep_run() {
  local m=$1 pid repo
  [ -f "$m" ] && [ ! -L "$m" ] || return 1
  kit_jq -e '(.base | type == "string") and (.repo | type == "string") and (.agent | type == "string") and .agent != ""' "$m" >/dev/null 2>&1 || return 1
  run_dir=${m%/manifest.json}
  wt=$(kit_jq -r '.worktree' "$m")
  [ "$wt" = "$run_dir/wt" ] && [ ! -L "$run_dir" ] && [ ! -L "$wt" ] || return 1
  repo=$(kit_jq -r '.repo' "$m")
  ! codex_paseo_run_in_temp "$repo" "$run_dir" || return 1
  pid=$(cat "$run_dir/owner.pid" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) ! kill -0 "$pid" 2>/dev/null || return 1 ;;
  esac
  paseo_agent=$(kit_jq -r '.agent' "$m")
  return 0
}

# Recover only manifests created by this transport: finish earlier runs whose cleanup is "pending"
# (waiting on a permission, an unconfirmed stop, no verified patch yet, or an archive that did not
# take). Kept runs and manifests without the marker are never touched, and neither is a run whose
# owner process is alive or whose agent Paseo does not show with exactly the recorded id and cwd.
# Then retire the stopped agents that finished earlier runs left open (see the second loop).
# Runs in a subshell to isolate lifecycle variables.
codex_paseo_sweep() (
  local m info age wt open
  for m in "$KIT_HOME"/runs/*/manifest.json; do
    codex_paseo_sweep_run "$m" || continue
    kit_jq -e '.cleanup == "pending"' "$m" >/dev/null 2>&1 || continue
    info=$(paseo inspect "$paseo_agent" --json 2>/dev/null) || continue
    # A stale or foreign id is left untouched: exact agent id and this run's tree, or nothing.
    printf '%s' "$info" | kit_jq -e --arg id "$paseo_agent" --arg cwd "$wt" \
      'type == "object" and .Id == $id and .Cwd == $cwd and (.Status | type == "string")' >/dev/null 2>&1 || continue
    age=$(kit_jq -r 'now - (.started | fromdateiso8601)' "$m" 2>/dev/null) || continue
    if printf '%s' "$info" | kit_jq -e '.Status == "running" or ((.PendingPermissions // []) | length > 0)' >/dev/null; then
      kit_jq -ne --argjson age "$age" '$age > 86400' >/dev/null || continue
    fi
    if [ ! -d "$wt" ] && [ ! -f "$run_dir/build.patch" ]; then
      kit_jq '.cleanup="gone"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
      continue
    fi
    paseo_pending=false
    paseo_stopped=false
    paseo_patch_state=""
    paseo_branch=""
    paseo_sweep_manifest=$m
    paseo_repo=$(kit_jq -r '.repo' "$m")
    paseo_started=$(kit_jq -r '.started // empty' "$m")
    BASE=$(kit_jq -r '.base' "$m")
    # The id recorded at the start is the only proof of which workspace the run made.
    paseo_workspace=$(kit_jq -r '.workspace // empty' "$m")
    paseo_patch_final=$(kit_jq -r '.patch_final == true' "$m")
    # A saved patch is final unless the manifest proves the tree beside it is the build's own:
    # only a manifest that says patch_final false does (deletion never began). Without a tree the
    # patch is all that is left. A manifest from before that field cannot say whether a folder there
    # is the build's tree or one that appeared later, so its patch is final too and never restaged.
    if [ -f "$run_dir/build.patch" ]; then
      if [ ! -e "$wt" ] || ! kit_jq -e 'has("patch_final")' "$m" >/dev/null 2>&1; then paseo_patch_final=true; fi
    fi
    codex_paseo_finalize || true
    [ "$paseo_archived" = true ] || paseo_archived=false
    paseo_patch=""
    [ ! -f "$run_dir/build.patch" ] || paseo_patch=$run_dir/build.patch
    kit_jq --arg patch "$paseo_patch" --arg cleanup "$paseo_cleanup" --arg branch "$paseo_branch" \
      --argjson archived "$paseo_archived" --argjson wsarchived "${paseo_workspace_archived:-false}" \
      --argjson final "${paseo_patch_final:-false}" \
      --argjson staged "$([ "$paseo_patch_state" = ok ] && echo true || echo false)" \
      '.cleanup=$cleanup | .archived=$archived | .workspace_archived=$wsarchived | .patch_final=$final | .patch=$patch | (if $staged then .branch=$branch else . end)' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  done
  # Retire agents that earlier kit runs left open: a stopped agent that is not archived keeps its
  # Codex server alive. Only an agent a manifest of this transport names, of a run that is finished
  # ("done" or "gone"), that Paseo still lists as open and not running, and that Paseo shows with
  # exactly the recorded id and that run's cwd. Agents the kit did not start are never looked at;
  # running ones and ones waiting on a permission are left alone. One listing bounds the work.
  open=unread
  for m in "$KIT_HOME"/runs/*/manifest.json; do
    codex_paseo_sweep_run "$m" || continue
    kit_jq -e '(.cleanup == "done" or .cleanup == "gone") and .archived != true' "$m" >/dev/null 2>&1 || continue
    if [ "$open" = unread ]; then
      # Asked once, and only when a finished run still has an agent that is not known to be archived.
      open=$(paseo ls -g --json 2>/dev/null | kit_jq -r 'if type == "array" then .[] | select(.status != "running") | .id // empty else empty end' 2>/dev/null) || return 0
    fi
    [ -n "$open" ] || return 0
    printf '%s\n' "$open" | grep -qxF -- "$paseo_agent" || continue
    info=$(paseo inspect "$paseo_agent" --json 2>/dev/null) || continue
    printf '%s' "$info" | kit_jq -e --arg id "$paseo_agent" --arg cwd "$wt" \
      'type == "object" and .Id == $id and .Cwd == $cwd and (.Status | type == "string") and .Status != "running" and ((.PendingPermissions // []) | length == 0)' >/dev/null 2>&1 || continue
    codex_paseo_agent_archive || continue
    kit_jq '.archived = true' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  done
)
