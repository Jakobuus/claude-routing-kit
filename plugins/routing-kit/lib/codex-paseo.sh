# Finalize before the runner removes the exported working tree.
codex_paseo_cleanup() {
  [ -n "${paseo_agent:-}" ] || return 0
  local attempt info stopped=false archived=false failed=0
  for attempt in 1 2 3; do
    paseo stop "$paseo_agent" >/dev/null 2>&1 || true
    info=$(paseo inspect "$paseo_agent" --json) || continue
    if printf '%s' "$info" | kit_jq -e '.Status != "running" and ((.PendingPermissions // []) | length == 0)' >/dev/null; then
      stopped=true
      break
    fi
  done
  [ "$stopped" = true ] || failed=4
  if paseo archive "$paseo_agent" >/dev/null 2>&1; then
    archived=true
  else
    echo "kit-codex-build: agent not archived: $paseo_agent" >&2
  fi
  kit_jq -n --arg agent "$paseo_agent" --arg repo "$paseo_repo" --arg base "$BASE" --argjson archived "$archived" \
    '{agent:$agent,repo:$repo,base:$base,archived:$archived}' > "$run_dir/manifest.json" || failed=4
  echo "kit-codex-build: run dir: $run_dir; archived=$archived"
  paseo_agent=""
  return "$failed"
}

# Optional Paseo transport for the Codex build runner.
codex_paseo_build() {
  local repo tmp agent state archived=false code=0 info
  repo=$(kit_git -C "$REPO" rev-parse --show-toplevel) || return 2
  repo=$(cd "$repo" && pwd -P) || return 2
  tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P)
  case "$repo/" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|"$tmp/"*)
      kit_die 2 'refusing temp repo for Paseo build' ;;
  esac
  [ -z "$(kit_git -C "$repo" status --porcelain)" ] || kit_die 2 'repo must be clean'
  command -v paseo >/dev/null 2>&1 || kit_die 3 'no paseo on PATH'
  BASE=$(kit_git -C "$repo" rev-parse HEAD) || return 2
  run_dir=$(run_export "$repo" "$NAME") || return $?
  run_claim "$run_dir"
  secret_scan --credentials-only "$BRIEF" "$run_dir/wt" >"$run_dir/secret-scan.txt" 2>&1 || return 5
  cp "$BRIEF" "$run_dir/brief.md" || return 2
  agent=$(paseo run -d -q --provider "codex/$MODEL" --mode full-access --new-workspace local --cwd "$run_dir/wt" \
    --title "Codex build: $NAME" "$(cat "$run_dir/brief.md")" </dev/null) || return 3
  [ -n "$agent" ] || return 3
  paseo_agent=$agent
  paseo_repo=$repo
  info=$(paseo inspect "$agent" --json) || {
    codex_paseo_cleanup || true
    return 4
  }
  if ! printf '%s' "$info" | kit_jq -e --arg cwd "$run_dir/wt" '.Cwd == $cwd' >/dev/null; then
    echo "kit-codex-build: agent cwd does not match scrubbed export" >&2
    codex_paseo_cleanup || true
    return 4
  fi
  paseo wait "$agent" --timeout 1800 --json > "$run_dir/wait.json"
  state=$(kit_jq -r '.status' "$run_dir/wait.json")
  [ "$state" = idle ] || code=4
  paseo logs "$agent" --filter text --tail 1 > "$run_dir/result.md"
  codex_paseo_cleanup || code=4
  if [ "$code" -eq 0 ]; then
    run_build_patch_fresh "$run_dir/wt" "$repo" "$BASE" || code=4
  fi
  [ ! -f "$run_dir/build.patch" ] || cat "$run_dir/build.patch"
  echo "kit-codex-build: run dir: $run_dir; archived=$archived"
  return "$code"
}
