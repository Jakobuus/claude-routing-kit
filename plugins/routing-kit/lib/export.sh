#!/bin/bash
# lib/export.sh — run_export REPO NAME
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers, not run directly. Depends on kit-common (kit_require_macos,
# kit_die, kit_realpath, KIT_HOME).

EXPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$EXPORT_LIB_DIR/../bin/kit-common"

# run_export REPO NAME — makes a self-contained working copy of REPO's
# current HEAD under $KIT_HOME/runs/<date>-<slug>/wt and prints the
# resolved run dir. Exit 2 if REPO is dirty, has no HEAD, or isn't a repo.
run_export() {
  local repo name date_str slug run_dir wt r
  repo="$1"
  name="$2"
  kit_require_macos
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
  run_dir="$(mktemp -d "$KIT_HOME/runs/${date_str}-${slug}-XXXXXX")" \
    || kit_die 2 "could not create a fresh run dir"
  wt="$run_dir/wt"

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
    kit_git -C "$wt" remote remove "$r"
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
    mv "$wt/.git/packed-refs.tmp" "$wt/.git/packed-refs"
  fi

  run_dir="$(kit_realpath "$run_dir")"
  echo "$run_dir"
}

# Stage a provider's scratch tree and print its complete diff. A failed
# local git step is a provider-run failure even when the model exited 0.
run_stage_and_diff() {
  local worktree="$1"
  if ! kit_git -C "$worktree" add -A >/dev/null 2>&1; then
    echo "could not stage the build patch" >&2
    return 4
  fi
  echo "--- diff ---"
  if ! kit_git -C "$worktree" diff --no-ext-diff --no-textconv HEAD 2>/dev/null; then
    echo "could not read the build diff" >&2
    return 4
  fi
}
