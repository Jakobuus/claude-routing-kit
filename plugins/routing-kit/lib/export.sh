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
  local repo="$1" wt="$2" r run_dir
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

  # A pristine copy of the scrubbed .git, kept outside wt where no build can
  # write (Seatbelt grants wt/home/cfg/tmp only; Codex's workspace-write is its
  # cwd, wt). Every git step after the build runs against THIS copy with
  # --git-dir/--work-tree (see run_build_patch) and never reads wt/.git, which
  # the build could have rewritten: config, index, objects, hooks, anything.
  # A real copy (cp -R), no hardlinks shared with wt/.git. Also record wt's
  # size, for the growth cap in run_preflight_wt.
  run_dir="$(dirname "$wt")"
  /bin/cp -R "$wt/.git" "$run_dir/git.pristine" \
    || kit_die 2 "could not save a pristine copy of the git directory"
  du -sk "$wt" 2>/dev/null | cut -f1 > "$run_dir/wt-size.kb"
  [ -s "$run_dir/wt-size.kb" ] || kit_die 2 "could not measure the copy"
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

# _run_has_attr_source GIT-OPTIONS... — returns 0 if this git knows the global
# --attr-source option (git 2.40+). run_build_patch uses it so gitattributes
# come from HEAD only, never from the build's worktree. On an older git the
# build still runs, without it, and run_preflight_wt adds one restriction
# instead (no symlink to a directory; see there).
_run_has_attr_source() {
  kit_git --attr-source=HEAD "$@" rev-parse HEAD >/dev/null 2>&1
}

# _run_find_hit WT WHAT FIND-TESTS... — one preflight scan of the worktree:
# prints the first match for FIND-TESTS (skipping wt/.git, which is never read)
# and returns 4 with a "refusing" message, or returns 0 if nothing matches.
# Fails closed: if find itself errors (unreadable dir), that is a refusal too.
_run_find_hit() {
  local wt="$1" what="$2" hit rc
  shift 2
  hit="$(find "$wt" -path "$wt/.git" -prune -o "$@" -print 2>/dev/null | head -n 1; exit "${PIPESTATUS[0]}")"
  rc=$?
  if [ -n "$hit" ]; then
    echo "refusing to stage the build in $wt: $what ($hit)" >&2
    return 4
  fi
  if [ "$rc" -ne 0 ]; then
    echo "refusing to stage the build in $wt: could not scan it" >&2
    return 4
  fi
  return 0
}

# run_preflight_wt WT [OLD_GIT] — checks the build's worktree before any git command
# touches it; returns 4 (message on stderr) if it holds anything git could be
# tricked or stalled by:
#  - a nested .git in any letter case (APFS treats .GIT as .git): a nested
#    repo has its own config, which git add/status can act on;
#  - a FIFO, socket or device: a FIFO .gitattributes or .gitignore hangs git;
#  - a regular file with several hard links: it may be a host file;
#  - on a git without --attr-source (older than 2.40) only: a symlink to a
#    directory. git follows a symlinked parent dir when it looks up the
#    attributes of a deleted tracked file, so a build could make it read a
#    .gitattributes outside the copy. (With --attr-source=HEAD attributes never
#    come from the worktree, so symlinked dirs are fine there.)
#  - growth past ROUTING_KIT_MAX_GROWTH_MB (default 2048) over wt's size at
#    export: a build that fills the disk is refused, not diffed.
# Symlinks in the tree are fine: git stores them as links, never follows them.
run_preflight_wt() {
  local wt="${1:-}" old_git="${2:-}" base now max hit rc
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "refusing to stage the build: no worktree at ${wt:-(none)}" >&2
    return 4
  fi
  _run_find_hit "$wt" "a nested git repository or submodule" -iname .git || return 4
  _run_find_hit "$wt" "a FIFO, socket or device file" ! -type f ! -type d ! -type l || return 4
  _run_find_hit "$wt" "a file with more than one hard link" -type f -links +1 || return 4
  if [ -z "$old_git" ]; then
    # called on its own: decide from the pristine copy next to wt
    if _run_has_attr_source --git-dir="$(dirname "$wt")/git.pristine"; then old_git=0; else old_git=1; fi
  fi
  if [ "$old_git" = 1 ]; then
    # -print0 + read -d '': any file name, newlines included; the loop stops at
    # the first symlink whose target is a directory ([ -d ] follows the link).
    hit="$(find "$wt" -path "$wt/.git" -prune -o -type l -print0 2>/dev/null \
      | while IFS= read -r -d '' link; do
          if [ -d "$link" ]; then printf '%s' "$link"; break; fi
        done; exit "${PIPESTATUS[0]}")"
    rc=$?
    if [ -n "$hit" ]; then
      echo "refusing to stage the build in $wt: a symlink to a directory ($hit); this git is older than 2.40, so update git to allow them" >&2
      return 4
    fi
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 141 ]; then
      echo "refusing to stage the build in $wt: could not scan it for symlinks" >&2
      return 4
    fi
  fi
  max="${ROUTING_KIT_MAX_GROWTH_MB:-2048}"
  case "$max" in ''|*[!0-9]*) max=2048 ;; esac
  base="$(cat "$(dirname "$wt")/wt-size.kb" 2>/dev/null)"
  now="$(du -sk "$wt" 2>/dev/null | cut -f1)"
  case "$base" in ''|*[!0-9]*) echo "refusing to stage the build in $wt: could not measure its size" >&2; return 4 ;; esac
  case "$now" in ''|*[!0-9]*) echo "refusing to stage the build in $wt: could not measure its size" >&2; return 4 ;; esac
  if [ $((now - base)) -gt $((max * 1024)) ]; then
    echo "refusing to stage the build in $wt: it grew by more than $max MB" >&2
    return 4
  fi
  return 0
}

# run_build_patch WT — stages everything the build changed and writes the
# complete diff to <run dir>/build.patch (the run dir is WT's parent; the
# worktree itself is deleted when the run ends, so that file is the result).
# Prints nothing on success; returns 4 with a message on any failure, and a
# failed run leaves no build.patch behind. A failed local git step is a
# provider-run failure even when the model exited 0.
#
# git runs against the pristine copy of .git that run_export saved outside WT,
# never against WT/.git: the build could have rewritten that (a filter or
# fsmonitor in its config, a crafted index, ...). It must be the FLAGS
# --git-dir/--work-tree: kit_git runs git under `env -i`, which drops
# GIT_DIR/GIT_WORK_TREE, and git would quietly fall back to WT/.git. Staging
# happens in the pristine index, then `diff --cached` reads only that index
# against HEAD, so the worktree is not read a second time. --binary keeps
# changed or new binary files (git apply restores them byte for byte).
# --attr-source=HEAD on both git calls when git has it (2.40+): gitattributes
# come from the pristine HEAD tree only, never from the worktree, so neither the
# build's own .gitattributes nor a symlinked dir (git follows a parent symlink
# when it looks up the attributes of a deleted file) can change how the patch
# is made. On an older git the preflight refuses dir symlinks instead, and a
# build's own .gitattributes may affect the patch's formatting (accepted).
run_build_patch() {
  local worktree="$1" run_dir patch pristine attr old_git
  run_dir="$(dirname "$worktree")"
  patch="$run_dir/build.patch"
  pristine="$run_dir/git.pristine"
  if [ ! -d "$pristine" ]; then
    echo "refusing to stage the build in $worktree: no pristine git directory was saved" >&2
    return 4
  fi
  # git 2.40+: attributes from HEAD only. Older git: no such option, so the
  # preflight refuses symlinks to directories instead.
  attr=()
  old_git=1
  if _run_has_attr_source --git-dir="$pristine"; then
    attr=(--attr-source=HEAD)
    old_git=0
  fi
  run_preflight_wt "$worktree" "$old_git" || return 4
  if ! kit_git ${attr[@]+"${attr[@]}"} --git-dir="$pristine" --work-tree="$worktree" -C "$worktree" \
      -c submodule.recurse=false add -A >/dev/null 2>&1; then
    echo "could not stage the build patch" >&2
    return 4
  fi
  if ! kit_git ${attr[@]+"${attr[@]}"} --git-dir="$pristine" --work-tree="$worktree" -C "$worktree" \
      diff --cached --binary --no-ext-diff --no-textconv --ignore-submodules=all HEAD >"$patch" 2>/dev/null; then
    rm -f "$patch"
    echo "could not read the build diff" >&2
    return 4
  fi
  return 0
}

# Stage a provider's scratch tree and print its complete diff (run_build_patch,
# which also writes it to <run dir>/build.patch).
run_stage_and_diff() {
  local worktree="$1"
  run_build_patch "$worktree" || return 4
  echo "--- diff ---"
  cat "$(dirname "$worktree")/build.patch"
}

# run_cleanup RUN_DIR — deletes the bulky per-run dirs (wt, home, cfg, tmp and
# the pristine git.pristine) and keeps the small files: logs, brief.md,
# build.patch, the provider's output. Never fails (callers run it from exit
# traps, which must keep the script's own exit code) and never deletes
# anything but those five dirs
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
  for d in wt home cfg tmp git.pristine; do
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
