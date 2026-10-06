#!/bin/bash
# lib/export.sh — run_export REPO NAME
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers, not run directly. Depends on kit-common (kit_require_supported,
# kit_die, kit_realpath, KIT_HOME).

EXPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$EXPORT_LIB_DIR/../bin/kit-common"

# _run_export_copy REPO WT — the clone-and-scrub half of run_export. Runs in a
# subshell (see run_export), so a kit_die in here only ends that subshell.
_run_export_copy() {
  local repo="$1" wt="$2" r
  # --no-local: no object-hardlink sharing with the source .git. --template=
  # (empty): no host clone template (hooks, excludes) copied in.
  # kit_git: no host gitconfig, no hooks, no fsmonitor -- so a clone whose
  # source repo somehow set a smudge/clean filter can't run one during the
  # clone itself either.
  if ! kit_git clone --template= --depth 1 --single-branch --no-local "file://$repo" "$wt" >/dev/null 2>&1; then
    kit_die 2 "clone failed for $repo"
  fi

  # Strip every remote so nothing in wt links back to the source .git: its
  # config, remote URLs, stashes and reflogs stay out (advisers 28/09).
  for r in $(kit_git -C "$wt" remote); do
    kit_git -C "$wt" remote remove "$r" >/dev/null 2>&1 \
      || kit_die 2 "could not remove remote $r from the copy"
  done

  # `git remote remove` only clears the remote's config section and refs; it
  # leaves the reflogs behind, and a fresh clone's reflog always has a
  # "clone: from <source-url>" line -- worse, git stamps that line with the
  # *local machine's* committer identity (name + email from git config), not
  # anything from the source repo, so this can leak real identity as well as
  # a path. Drop every reflog outright (fine for a scratch export tree) and
  # remove FETCH_HEAD too, since some git versions write it during clone.
  rm -rf "$wt/.git/logs"
  rm -f "$wt/.git/FETCH_HEAD"

  # Belt and suspenders: some git versions leave packed remote-tracking refs
  # behind even after `remote remove`. Strip any such lines from packed-refs
  # if present (the ref names themselves never contain the source URL, but
  # nothing here should still be pointing at a "remotes/" namespace either).
  if [ -f "$wt/.git/packed-refs" ]; then
    grep -v 'refs/remotes/' "$wt/.git/packed-refs" > "$wt/.git/packed-refs.tmp" 2>/dev/null
    mv "$wt/.git/packed-refs.tmp" "$wt/.git/packed-refs" \
      || kit_die 2 "could not rewrite packed-refs in the copy"
  fi
}

# run_export REPO NAME — makes a self-contained working copy of REPO's
# current HEAD under $KIT_HOME/runs/<date>-<slug>/wt and prints the
# resolved run dir. Exit 2 if REPO is dirty, has no HEAD, or isn't a repo.
#
# The copy is scratch: callers run run_cleanup on exit, which deletes wt (and
# the jail's home, cfg and tmp) and keeps the small files, build.patch
# included. Before it makes a new copy, run_export also sweeps copies left
# behind by runs that never got to clean up (see run_sweep_stale).
run_export() {
  local repo name date_str slug run_dir wt r
  repo="$1"
  name="$2"
  kit_require_supported
  if [ -z "${repo:-}" ] || [ -z "${name:-}" ]; then
    kit_die 2 "usage: run_export REPO NAME"
  fi

  repo="$(kit_realpath "$repo")"
  if [ -z "$repo" ]; then
    kit_die 2 "no such repo directory"
  fi
  if ! kit_git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    kit_die 2 "not a git repo: $repo"
  fi
  if ! kit_git -C "$repo" rev-parse HEAD >/dev/null 2>&1; then
    kit_die 2 "no HEAD: commit first"
  fi
  if [ -n "$(kit_git -C "$repo" status --porcelain)" ]; then
    kit_die 2 "commit first"
  fi

  date_str="$(date +%Y-%m-%d)"
  slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$slug" ] || slug="run"

  # Every run gets its own fresh, exclusive directory (mktemp -d's atomic
  # create-or-fail), never a reused date+slug path: a second run with the
  # same name on the same day must never see a prior run's wt, home, cfg,
  # tmp or gate-port (advisers 29/09 -- reuse was letting one run's jailed
  # writes and a stale gate-port file leak into the next).
  mkdir -p "$KIT_HOME/runs" || kit_die 2 "could not create $KIT_HOME/runs"
  run_sweep_stale
  run_dir="$(mktemp -d "$KIT_HOME/runs/${date_str}-${slug}-XXXXXX")" \
    || kit_die 2 "could not create a fresh run dir"
  wt="$run_dir/wt"

  # The copy runs in a subshell so any failure inside it -- including a
  # kit_die, which exits -- comes back here as a plain status. The caller
  # never learns run_dir when run_export fails, so this is the only place that
  # can remove the half-made dir (a failed clone, a failed remote removal, a
  # throwaway-HOME failure in kit_git). run_cleanup carries the guard and
  # ROUTING_KIT_KEEP_RUNS; rmdir then only removes the dir if it is empty.
  ( _run_export_copy "$repo" "$wt" )
  r=$?
  if [ "$r" -ne 0 ]; then
    run_cleanup "$run_dir" >/dev/null 2>&1
    rmdir "$run_dir" 2>/dev/null
    exit "$r"
  fi

  run_dir="$(kit_realpath "$run_dir")"
  echo "$run_dir"
}

# Stage a provider's scratch tree and print its complete diff. A failed
# local git step is a provider-run failure even when the model exited 0.
# The same diff is also written to <run dir>/build.patch (the run dir is the
# worktree's parent): that file is the result, since the worktree itself is
# deleted when the run ends. --binary, so a changed or new binary file
# survives in the patch (git apply restores it byte for byte).
run_stage_and_diff() {
  local worktree="$1" patch
  patch="$(dirname "$worktree")/build.patch"
  if ! kit_git -C "$worktree" add -A >/dev/null 2>&1; then
    echo "could not stage the build patch" >&2
    return 4
  fi
  echo "--- diff ---"
  if ! kit_git -C "$worktree" diff --binary --no-ext-diff --no-textconv HEAD >"$patch" 2>/dev/null; then
    rm -f "$patch"
    echo "could not read the build diff" >&2
    return 4
  fi
  cat "$patch"
}

# run_cleanup RUN_DIR — deletes the bulky per-run dirs (wt, home, cfg, tmp)
# and keeps the small files: logs, brief.md, build.patch, the provider's
# output. Never fails (callers run it from exit traps, which must keep the
# script's own exit code) and never deletes anything but those four dirs
# inside a direct child of $KIT_HOME/runs. ROUTING_KIT_KEEP_RUNS=1 keeps the
# copy for debugging.
run_cleanup() {
  local run_dir real runs_root d p
  run_dir="${1:-}"
  if [ -z "$run_dir" ]; then
    echo "run_cleanup: no run dir given; nothing deleted" >&2
    return 0
  fi
  # Already gone (e.g. locked-build removed it itself): nothing to do.
  [ -e "$run_dir" ] || [ -L "$run_dir" ] || return 0
  real="$(kit_realpath "$run_dir")"
  runs_root="$(kit_realpath "$KIT_HOME/runs")"
  if [ -L "$run_dir" ] || [ -z "$real" ] || [ -z "$runs_root" ] \
    || [ "$real" = "$runs_root" ] || [ "$(dirname "$real")" != "$runs_root" ]; then
    echo "run_cleanup: $run_dir is not a run dir under $KIT_HOME/runs; nothing deleted" >&2
    return 0
  fi
  if [ "${ROUTING_KIT_KEEP_RUNS:-}" = "1" ]; then
    echo "run_cleanup: ROUTING_KIT_KEEP_RUNS=1, repo copy kept at $real/wt" >&2
    return 0
  fi
  for d in wt home cfg tmp; do
    p="$real/$d"
    if [ -L "$p" ]; then
      rm -f "$p"
    elif [ -e "$p" ]; then
      # A jailed build can leave read-only dirs that rm -rf alone can't
      # enter. chmod -R doesn't follow symlinks it meets inside the tree
      # (p itself is a real dir, checked above), and neither does rm -rf.
      chmod -R u+rwx "$p" 2>/dev/null
      rm -rf "$p" 2>/dev/null
    fi
  done
  return 0
}

# run_sweep_stale — run_cleanup on every run dir under $KIT_HOME/runs not
# touched for over 24 hours: the leftovers of runs that were killed before
# their exit trap ran. Younger dirs are left alone (a concurrent run may be
# using one), and so is any dir whose owner.pid names a live process: writes
# inside wt don't touch the run dir's own mtime, so age alone can't tell a
# long live run from a dead one. Quiet, and never fails the caller.
run_sweep_stale() {
  local d pid
  [ -d "$KIT_HOME/runs" ] || return 0
  find "$KIT_HOME/runs" -mindepth 1 -maxdepth 1 -type d -mmin +1440 2>/dev/null \
    | while IFS= read -r d; do
        pid="$(cat "$d/owner.pid" 2>/dev/null)"
        case "$pid" in
          ''|*[!0-9]*) ;;
          *) kill -0 "$pid" 2>/dev/null && continue ;;
        esac
        run_cleanup "$d" >/dev/null 2>&1
      done
  return 0
}

# run_claim RUN_DIR — records this process as the run's owner (owner.pid), so
# run_sweep_stale leaves the dir alone while the process is alive. Callers run
# it right after run_export. Never fails.
run_claim() {
  printf '%s\n' "$$" > "${1:-/nonexistent}/owner.pid" 2>/dev/null
  return 0
}
