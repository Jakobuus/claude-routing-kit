#!/bin/bash
# lib/export.sh — run_export REPO NAME
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers, not run directly. Depends on kit-common (kit_require_supported,
# kit_die, kit_realpath, KIT_HOME).

EXPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Set to 1 by run_agent_started, in this process. It only ever goes from 0 to 1: sourcing this
# file again does not reset it, and a 1 from outside can only make a cleanup keep more.
[ "${_run_agent_started:-}" = 1 ] || _run_agent_started=0
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

  # A pristine copy of the scrubbed .git, kept outside wt. Codex and Gemini
  # run without a sandbox and can write outside wt. Every git step after the
  # build runs against THIS copy with
  # --git-dir/--work-tree (see run_build_patch) and never reads wt/.git, which
  # the build could have rewritten: config, index, objects, hooks, anything.
  # A real copy (cp -R), no hardlinks shared with wt/.git. Also record wt's
  # size, for the growth cap in run_preflight_wt.
  run_dir="$(dirname "$wt")"
  /bin/cp -R "$wt/.git" "$run_dir/git.pristine" \
    || kit_die 2 "could not save a pristine copy of the git directory"
  du -sk "$wt" 2>/dev/null | cut -f1 > "$run_dir/wt-size.kb"
  [ -s "$run_dir/wt-size.kb" ] || kit_die 2 "could not measure the copy"
  # What the copy holds before any agent touches it: the base commit and every file and link in it
  # (NUL separated, ./-relative, .git left out). run_cleanup_checked compares the end state with it.
  kit_git -C "$wt" rev-parse HEAD > "$run_dir/export-base" 2>/dev/null \
    || kit_die 2 "could not record the base commit"
  ( cd "$wt" && find . -path ./.git -prune -o ! -type d -print0 ) > "$run_dir/export-files" 2>/dev/null \
    || kit_die 2 "could not list the copy"
  kit_git -C "$wt" for-each-ref --format='%(refname)' > "$run_dir/export-refs" 2>/dev/null \
    || kit_die 2 "could not list the copy's refs"
}

# run_export REPO NAME — makes a self-contained working copy of REPO's
# current HEAD under $KIT_HOME/runs/<date>-<slug>/wt and prints the
# resolved run dir. Exit 2 if REPO is dirty, has no HEAD, or isn't a repo.
#
# The copy is scratch: callers clean up on exit (run_cleanup_own): wt is deleted when its work is
# saved (build.patch checked, nothing outside it) and moved to retained otherwise; the jail's home,
# cfg and tmp go either way, and the small files, build.patch included, stay. Before it makes a new copy, run_export also sweeps copies left
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
    # No agent has been near this half-made copy: this process only just created it.
    _run_cleanup_impl "$run_dir" "export failed" 1 >/dev/null 2>&1
    rmdir "$run_dir" 2>/dev/null
    exit "$r"
  fi

  run_dir="$(kit_realpath "$run_dir")"
  echo "$run_dir"
}

# run_agent_started RUN_DIR — call it right before an agent is started in RUN_DIR/wt, in the
# builder's own shell (not a subshell), and do not start the agent if it fails. It is one-way:
# it sets a flag in this process, which no agent can reach, and creates RUN_DIR/agent-started,
# which the kit never removes. From then on nothing deletes that copy (see run_cleanup_own).
run_agent_started() {
  local run_dir="${1:-}"
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || return 1
  _run_agent_started=1
  : > "$run_dir/agent-started" 2>/dev/null || return 1
  [ -f "$run_dir/agent-started" ] || return 1
  return 0
}

# run_retain RUN_DIR [WHY] — move RUN_DIR/wt, whole, to $KIT_HOME/retained/<run dir name> and print
# the new path. One rename on the same file system, under a lock on the retained folder, so the
# copy is never half moved and never lands on another copy; nothing is copied or deleted. A small
# file next to it, <name>.why, says when, from where and why. If the move cannot be made the copy
# stays where it is and this returns 1 (lib/retained.py).
# Retained copies are deleted only by hand: kit-retained prune --older-than DAYS.
run_retain() {
  local run_dir="${1:-}" why="${2:-}" real dest
  real="$(kit_realpath "$run_dir")"
  [ -n "$real" ] && [ -d "$real/wt" ] && [ ! -L "$real/wt" ] || return 1
  dest="$(kit_python3 "$EXPORT_LIB_DIR/retained.py" retain "$KIT_HOME" "$real" "${why:-run ended}" 2>/dev/null)" || return 1
  [ -n "$dest" ] || return 1
  printf '%s\n' "$dest" > "$real/retained-at" 2>/dev/null
  printf '%s\n' "$dest"
  return 0
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
  local worktree="$1" run_dir patch pristine attr old_git expected head
  run_dir="$(dirname "$worktree")"
  patch="$run_dir/build.patch"
  pristine="${2:-$run_dir/git.pristine}"
  expected="${3:-}"
  rm -f "$patch"
  if [ ! -d "$pristine" ]; then
    echo "refusing to stage the build in $worktree: no pristine git directory was saved" >&2
    return 4
  fi
  if [ -n "$expected" ]; then
    head=$(kit_git --git-dir="$pristine" rev-parse HEAD 2>/dev/null) || head=''
    if [ "$head" != "$expected" ]; then
      echo "refusing to stage the build in $worktree: pristine HEAD differs from source BASE" >&2
      return 4
    fi
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

# Gemini creates its staging repository only after agy and its process group
# have exited. Nothing from the agent's .git or the old git.pristine is used.
# run_build_patch_fresh WT SOURCE BASE [OUT] — OUT defaults to <run dir>/build.patch; run_cleanup_checked
# passes its own file to stage the copy a second time and compare.
run_build_patch_fresh() {
  local worktree="$1" source="$2" base="$3" patch
  patch="${4:-$(dirname "$worktree")/build.patch}"
  rm -f "$patch"
  if (
    local scratch attr old_git drivers key
    drivers=()
    mkdir -p "$KIT_HOME/scratch" || exit 4
    scratch=''
    trap '[ -z "$scratch" ] || rm -rf "$scratch"' EXIT
    trap 'exit 4' HUP INT TERM
    scratch=$(mktemp -d "$KIT_HOME/scratch/kit-build-git.XXXXXX") || exit 4
    printf '%s\n' "$$" > "$scratch/owner.pid"
    chmod 700 "$scratch" || exit 4
    mkdir "$scratch/home" || exit 4
    # The index, home, configuration and object store are all new. The clone
    # has no checkout, so source attributes and filters cannot run here.
    staging_git() {
      env -i PATH=/usr/bin:/bin HOME="$scratch/home" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 GIT_INDEX_FILE="$scratch/index" \
        git ${drivers[@]+"${drivers[@]}"} -c core.hooksPath=/dev/null -c core.fsmonitor=false \
          -c core.attributesFile=/dev/null "$@"
    }
    staging_git clone --template= --depth 1 --single-branch --no-local --no-checkout --no-hardlinks \
      "file://$source" "$scratch/git" >/dev/null 2>&1 || exit 4
    # The clone holds only the branch tip. If the source moved on since BASE (a commit during the
    # build), fetch BASE itself by id.
    staging_git -C "$scratch/git" cat-file -e "$base^{commit}" 2>/dev/null \
      || staging_git -C "$scratch/git" fetch --quiet --depth 1 --no-tags "file://$source" "$base" >/dev/null 2>&1 \
      || exit 4
    staging_git -C "$scratch/git" cat-file -e "$base^{commit}" || exit 4
    while IFS= read -r key; do
      [ -n "$key" ] && drivers=(${drivers[@]+"${drivers[@]}"} -c "$key=")
    done < <(staging_git -C "$scratch/git" config --local --name-only \
      --get-regexp '^(filter|diff|merge)\.' 2>/dev/null)
    rm -f "$scratch/git/.git/info/attributes" || exit 4
    [ ! -e "$scratch/git/.git/info/attributes" ] || exit 4
    attr=()
    old_git=1
    if staging_git --attr-source="$base" -C "$scratch/git" rev-parse "$base" >/dev/null 2>&1; then
      attr=(--attr-source="$base")
      old_git=0
    fi
    kit_python3 - "$worktree" "$scratch/wt" <<'SNAPSHOT'
import os, stat, sys
source, dest = sys.argv[1:]
maximum = os.environ.get('ROUTING_KIT_MAX_GROWTH_MB', '2048')
if not maximum or any(c not in '0123456789' for c in maximum):
    maximum = '2048'
used = 0
with open(os.path.join(os.path.dirname(source), 'wt-size.kb')) as baseline:
    limit = int(baseline.read().strip()) * 1024 + int(maximum) * 1024 * 1024
def charge(size):
    global used
    used += size
    if used > limit:
        raise ValueError('it grew by more than %s MB' % maximum)
def copy_tree(fd, dst, root=False):
    os.mkdir(dst, 0o700)
    with os.scandir(fd) as entries:
        for entry in entries:
            name = entry.name
            if root and name == '.git':
                continue
            mode = os.stat(name, dir_fd=fd, follow_symlinks=False)
            reason = None
            if name.lower() == '.git':
                reason = 'a nested git repository or submodule'
            elif not (stat.S_ISREG(mode.st_mode) or stat.S_ISDIR(mode.st_mode) or stat.S_ISLNK(mode.st_mode)):
                reason = 'a FIFO, socket or device file'
            elif stat.S_ISREG(mode.st_mode) and mode.st_nlink > 1:
                reason = 'a file with more than one hard link'
            if reason:
                raise ValueError('%s (%s)' % (reason, name))
            target = os.path.join(dst, name)
            if stat.S_ISLNK(mode.st_mode):
                charge(mode.st_size)
                os.symlink(os.readlink(name, dir_fd=fd), target)
            elif stat.S_ISDIR(mode.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    copy_tree(child, target)
                finally:
                    os.close(child)
            else:
                child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                with os.fdopen(child, 'rb') as reader:
                    actual = os.fstat(reader.fileno())
                    if not stat.S_ISREG(actual.st_mode):
                        raise ValueError('a FIFO, socket or device file (%s)' % name)
                    if actual.st_nlink != 1:
                        raise ValueError('a file with more than one hard link (%s)' % name)
                    charge(actual.st_size)
                    remaining = actual.st_size
                    with open(target, 'wb') as writer:
                        while remaining:
                            data = reader.read(min(remaining, 1024 * 1024))
                            if not data:
                                break
                            writer.write(data)
                            remaining -= len(data)
                        os.fchmod(writer.fileno(), stat.S_IMODE(actual.st_mode))
try:
    fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        copy_tree(fd, dest, True)
    finally:
        os.close(fd)
except (OSError, ValueError) as error:
    print('refusing to stage the build in %s: %s' % (source, error), file=sys.stderr)
    sys.exit(4)
SNAPSHOT
    [ "$?" -eq 0 ] || exit 4
    cp "$(dirname "$worktree")/wt-size.kb" "$scratch/wt-size.kb" || exit 4
    worktree="$scratch/wt"
    run_preflight_wt "$worktree" "$old_git" || exit 4
    staging_git -C "$scratch/git" read-tree "$base" || exit 4
    staging_git ${attr[@]+"${attr[@]}"} --git-dir="$scratch/git/.git" \
      --work-tree="$worktree" -c submodule.recurse=false add -A >/dev/null 2>&1 || exit 4
    staging_git ${attr[@]+"${attr[@]}"} --git-dir="$scratch/git/.git" \
      --work-tree="$worktree" diff --cached --binary --no-ext-diff \
      --no-textconv --ignore-submodules=all "$base" > "$patch" 2>/dev/null || exit 4
    if [ -s "$patch" ]; then
      staging_git -C "$scratch/git" read-tree "$base" || exit 4
      staging_git -C "$scratch/git" apply --cached --check "$patch" || exit 4
    fi
  ); then
    return 0
  fi
  rm -f "$patch"
  echo 'could not safely stage the build patch' >&2
  return 4
}

# Stage a provider's scratch tree and print its complete diff (run_build_patch,
# which also writes it to <run dir>/build.patch).
run_stage_and_diff() {
  local worktree="$1"
  run_build_patch "$worktree" || return 4
  echo "--- diff ---"
  cat "$(dirname "$worktree")/build.patch"
}

# run_cleanup RUN_DIR [WHY] — clears the bulky per-run dirs (wt, home, cfg, tmp and
# the pristine git.pristine) and keeps the small files: logs, brief.md,
# build.patch, the provider's output. Never fails (callers run it from exit
# traps, which must keep the script's own exit code) and never touches
# anything but those five dirs
# inside a direct child of $KIT_HOME/runs. ROUTING_KIT_KEEP_RUNS=1 keeps the
# copy for debugging.
# wt is never deleted here: it is moved to $KIT_HOME/retained with WHY
# (run_retain), and a copy that cannot be moved stays where it is. No file in
# the run dir can change that, because an agent could have written it. This
# is what every recovery cleanup uses that cannot know what happened in the
# copy (the stale sweep). A builder that knows the repo and the base commit uses
# run_cleanup_own or run_cleanup_checked, which delete a copy whose work is saved.
run_cleanup() {
  _run_cleanup_impl "${1:-}" "${2:-}" 0
}

# _run_patch_verified RUN_DIR REPO BASE — 0 when RUN_DIR/build.patch is a plain file and either
# empty (the verified "no changes" result) or applies to BASE of REPO (git apply --check, in a
# throwaway clone). Anything else prints the reason and returns 1.
_run_patch_verified() {
  local run_dir="$1" repo="$2" base="$3" patch scratch rc=1
  patch="$run_dir/build.patch"
  if [ ! -f "$patch" ] || [ -L "$patch" ]; then echo "no build.patch saved"; return 1; fi
  [ -s "$patch" ] || return 0
  if [ -z "$repo" ] || [ -z "$base" ]; then echo "build.patch cannot be checked (no repo or base commit)"; return 1; fi
  scratch="$(mktemp -d "$KIT_HOME/verify-XXXXXX" 2>/dev/null)" || { echo "build.patch could not be checked"; return 1; }
  if kit_git clone --no-local --no-checkout --quiet "$repo" "$scratch" >/dev/null 2>&1 \
    && kit_git -C "$scratch" read-tree "$base" >/dev/null 2>&1 \
    && kit_git -C "$scratch" apply --cached --check "$patch" >/dev/null 2>&1; then
    rc=0
  else
    echo "build.patch does not apply to the base commit"
  fi
  rm -rf "$scratch"
  return "$rc"
}

# Source of the check in _run_outside_patch (a variable: bash 3.2 cannot parse a heredoc inside $( )).
IFS= read -r -d '' _RUN_OUTSIDE_PY <<'OUTSIDE' || true
import os, sys
run_dir, names_file = sys.argv[1:]
def paths(blob):
    return set(os.fsdecode(p) for p in blob.split(b'\0') if p)
exported = set(p[2:] if p.startswith('./') else p for p in paths(open(os.path.join(run_dir, 'export-files'), 'rb').read()))
fields = open(names_file, 'rb').read().split(b'\0')
named, i = set(), 0
while i < len(fields):
    parts = fields[i].split(b'\t', 2)
    if len(parts) == 3 and parts[2] == b'':
        named.update(os.fsdecode(f) for f in fields[i + 1:i + 3]); i += 3
    else:
        if len(parts) == 3:
            named.add(os.fsdecode(parts[2]))
        i += 1
wt = os.path.join(run_dir, 'wt')
found = []
def unreadable(error):
    found.append('%s (could not be read)' % getattr(error, 'filename', None))
for top, dirs, files in os.walk(wt, onerror=unreadable):
    if top == wt and '.git' in dirs:
        dirs.remove('.git')
    for name in files + [d for d in dirs if os.path.islink(os.path.join(top, d))]:
        rel = os.path.relpath(os.path.join(top, name), wt)
        if rel not in exported and rel not in named:
            found.append(rel + ' (ignored by git, not in build.patch)')
print('\n'.join(sorted(found)[:3]))
sys.exit(1 if found else 0)
OUTSIDE

# _run_outside_patch RUN_DIR — prints (at most three of) the files in RUN_DIR/wt that the patch cannot
# hold, and returns 1 if there are any: a file that is neither in the copy as exported nor named by
# build.patch (an ignored file, say), or any path the walk could not read. 2 when it cannot tell.
# (Contents are compared separately, by staging the copy again; see _run_keep_reason.)
_run_outside_patch() {
  local run_dir="$1" names out rc
  [ -f "$run_dir/export-files" ] && [ -f "$run_dir/build.patch" ] || { echo "no record of the exported copy"; return 2; }
  names="$(mktemp "$KIT_HOME/patch-names-XXXXXX" 2>/dev/null)" || { echo "could not read build.patch"; return 2; }
  if [ -s "$run_dir/build.patch" ]; then
    (cd / && kit_git apply --numstat -z "$run_dir/build.patch") > "$names" 2>/dev/null
  else
    : > "$names"
  fi
  if [ "$?" -ne 0 ]; then
    rm -f "$names"; echo "could not read build.patch"; return 2
  fi
  out="$(kit_python3 -c "$_RUN_OUTSIDE_PY" "$run_dir" "$names")"
  rc=$?
  rm -f "$names"
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$rc"
}

# _run_keep_reason RUN_DIR REPO BASE OPEN_WHY — prints why the copy in RUN_DIR must be kept, or
# nothing when it may be deleted: all of
#  (a) build.patch is saved and applies to BASE (or is the checked "no changes");
#  (b) staging the copy again, exactly as build.patch was made, gives a byte-identical patch (so
#      every content, mode, symlink and deletion change is in it), no path of the copy is
#      unreadable, and no file git ignores was added since export;
#  (b2) the copy's own .git has no ref the export did not create (a stash, another branch);
#  (c) no agent is still open in it: OPEN_WHY is the caller's answer, empty when none is.
# The export lists (export-files, export-refs) sit in the run dir, which an unconfined agent could
# have rewritten: a known limit, as with agent-started.
_run_keep_reason() {
  local run_dir="$1" repo="$2" base="$3" open_why="${4:-}" why files tmp refs
  [ -z "$open_why" ] || { printf '%s\n' "an agent may still be open in it: $open_why"; return 0; }
  [ -n "$base" ] || base="$(cat "$run_dir/export-base" 2>/dev/null)"
  if ! why="$(_run_patch_verified "$run_dir" "$repo" "$base")"; then
    printf '%s\n' "$why"; return 0
  fi
  tmp="$(mktemp "$KIT_HOME/restage-XXXXXX" 2>/dev/null)" || { echo "could not stage the copy again"; return 0; }
  # In a shell of its own: this runs from exit traps, where a subshell's own EXIT trap (which removes
  # the staging scratch) does not fire.
  if ! bash -c '. "$1"; run_build_patch_fresh "$2" "$3" "$4" "$5"' _ "$EXPORT_LIB_DIR/export.sh" "$run_dir/wt" "$repo" "$base" "$tmp" >/dev/null 2>&1 \
    || ! cmp -s "$tmp" "$run_dir/build.patch"; then
    rm -f "$tmp"
    echo "the copy no longer matches build.patch (staging it again gives a different patch, or fails)"
    return 0
  fi
  rm -f "$tmp"
  if ! files="$(_run_outside_patch "$run_dir")"; then
    printf 'files the patch does not hold: %s\n' "$(printf '%s' "$files" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    return 0
  fi
  if ! refs="$(kit_git --git-dir="$run_dir/wt/.git" for-each-ref --format='%(refname)' 2>/dev/null)"; then
    echo "the copy's .git cannot be read"
    return 0
  fi
  refs="$(printf '%s\n' "$refs" | grep -vxF -f "$run_dir/export-refs" | grep -v '^$' | head -n 3 | tr '\n' ' ')"
  [ -z "$refs" ] || printf 'the copy'"'"'s .git holds work the patch does not: %s\n' "$refs"
  return 0
}

# run_copy_busy RUN_DIR — prints why the copy cannot be shown to be idle, and returns 0, when any
# process has its working directory or an open file inside RUN_DIR/wt (one lsof call), or when lsof
# cannot be run. Prints nothing and returns 1 when none does. A direct builder only killed the
# process group of the agent it started; a child that left it may still be writing.
run_copy_busy() {
  local wt out rc lsof_bin
  wt="$(kit_realpath "${1:-}/wt")"
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  # /usr/sbin is not on every minimal PATH (macOS keeps lsof there).
  lsof_bin="$(command -v lsof 2>/dev/null)"
  [ -n "$lsof_bin" ] || { [ -x /usr/sbin/lsof ] && lsof_bin=/usr/sbin/lsof; }
  [ -n "$lsof_bin" ] || { echo "lsof is not available to show that no process is still in it"; return 0; }
  out="$("$lsof_bin" -w +D "$wt" 2>/dev/null)"
  rc=$?
  if [ -n "$out" ]; then
    echo "a process still has its working directory or an open file in it: $(printf '%s\n' "$out" | sed -n '2p' | awk '{print $1" pid "$2}')"
    return 0
  fi
  [ "$rc" -le 1 ] || { echo "lsof failed, so it cannot be shown that no process is still in it"; return 0; }
  return 1
}

# run_cleanup_checked RUN_DIR WHY REPO [BASE [OPEN_WHY]] — the cleanup for a run an agent worked in,
# whose builder knows the repo (and the base commit; default: the one recorded at export). The
# copy is DELETED when _run_keep_reason finds nothing to keep it for; otherwise it is MOVED to
# $KIT_HOME/retained as run_cleanup does, with "WHY; kept: <reason>" in its note. Sets
# RUN_CLEANUP_RESULT to deleted or kept (kept also when the copy could not be moved: it then
# stays in the run dir). Never fails.
run_cleanup_checked() {
  local run_dir="${1:-}" why="${2:-}" repo="${3:-}" base="${4:-}" open_why="${5:-}" reason=""
  RUN_CLEANUP_RESULT=kept
  if [ -n "$run_dir" ] && [ -d "$run_dir" ] && [ ! -L "$run_dir" ]; then
    reason="$(_run_keep_reason "$run_dir" "$repo" "$base" "$open_why")" || reason="could not check the copy"
  else
    reason="no run dir"
  fi
  if [ -z "$reason" ]; then
    _run_cleanup_impl "$run_dir" "$why" 1
    [ -e "$run_dir/wt" ] || [ -L "$run_dir/wt" ] || RUN_CLEANUP_RESULT=deleted
  else
    _run_cleanup_impl "$run_dir" "${why:+$why; }kept: $reason" 0
  fi
  return 0
}

# run_cleanup_own RUN_DIR WHY [REPO [BASE [OPEN_WHY]]] — for the builder that made RUN_DIR in this
# very process. A copy no agent was started in (this process has not called run_agent_started, and
# RUN_DIR/agent-started does not exist) is deleted: it is nothing but HEAD. Otherwise
# run_cleanup_checked with the given REPO, or plain run_cleanup (move it) without one.
run_cleanup_own() {
  local run_dir="${1:-}"
  if [ "${_run_agent_started:-0}" != 1 ] && [ -n "$run_dir" ] \
    && [ ! -e "$run_dir/agent-started" ] && [ ! -L "$run_dir/agent-started" ]; then
    _run_cleanup_impl "$run_dir" "${2:-}" 1
    RUN_CLEANUP_RESULT=deleted
  elif [ -n "${3:-}" ]; then
    run_cleanup_checked "$run_dir" "${2:-}" "$3" "${4:-}" "${5:-}"
  else
    _run_cleanup_impl "$run_dir" "${2:-}" 0
    RUN_CLEANUP_RESULT=kept
  fi
  return 0
}

# _run_cleanup_impl RUN_DIR WHY DELETE_WT — DELETE_WT is 1 only from run_cleanup_own (no agent was
# started), run_cleanup_checked (after its checks passed) and run_export's own failed copy.
_run_cleanup_impl() {
  local run_dir real runs_root d p delete_wt
  delete_wt="${3:-0}"
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
    elif [ "$d" = wt ] && [ -e "$p" ] && [ "$delete_wt" != 1 ]; then
      # An agent may have worked in this copy, and no patch is proof that every file of that work
      # is saved elsewhere (ignored files, the copy's own .git). It is moved aside, never deleted.
      if ! run_retain "$real" "${2:-run ended}" >/dev/null; then
        echo "run_cleanup: could not move $p to $KIT_HOME/retained; it stays where it is" >&2
      fi
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
  if [ -d "$KIT_HOME/scratch" ]; then
    find "$KIT_HOME/scratch" -mindepth 1 -maxdepth 1 -type d -name 'kit-build-git.*' -mmin +1440 2>/dev/null |
      while IFS= read -r d; do
        pid="$(cat "$d/owner.pid" 2>/dev/null)"
        case "$pid" in
          ''|*[!0-9]*) ;;
          *) kill -0 "$pid" 2>/dev/null && continue ;;
        esac
        rm -rf "$d"
      done
  fi
  # The Paseo transport's head-XXXXXX copy of the source lives only while the export is made; one
  # older than a day is the leftover of a run that was killed hard.
  find "$KIT_HOME" -mindepth 1 -maxdepth 1 -type d -name 'head-??????' -mmin +1440 2>/dev/null |
    while IFS= read -r d; do rm -rf "$d"; done
  [ -d "$KIT_HOME/runs" ] || return 0
  find "$KIT_HOME/runs" -mindepth 1 -maxdepth 1 -type d -mmin +1440 2>/dev/null \
    | while IFS= read -r d; do
        pid="$(cat "$d/owner.pid" 2>/dev/null)"
        case "$pid" in
          ''|*[!0-9]*) ;;
          *) kill -0 "$pid" 2>/dev/null && continue ;;
        esac
        # A Paseo run waiting to be finished, or one kept on purpose, keeps its copy at any age.
        kit_jq -e '.cleanup == "pending" or .cleanup == "kept"' "$d/manifest.json" >/dev/null 2>&1 && continue
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
