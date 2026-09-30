#!/bin/bash
# lib/canaries.sh — canaries_run PROFILE WT SRC_REPO PORT MODE
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers (locked-build, kit-selftest), not run directly except
# for its own manual smoke use at the bottom of this file. Depends on
# kit-common (kit_die).
#
# Every probe runs a child /bin/sh through `sandbox-exec -f PROFILE`. A
# probe that should be *denied* has a positive control: the same command run
# outside the jail first, which must succeed — otherwise the canary itself
# is broken (nothing was actually being tested) and that counts as a
# failure. Fixtures live under the real $HOME (never the jail's throwaway
# HOME) so the probes exercise exactly the paths the profile must not leak:
# $HOME/.routing-kit-canary is created and torn down by this file, never
# left behind on a failure.
#
# PORT is the one loopback port the given PROFILE allows outbound traffic
# to (see lib/seatbelt.sh) — canaries_run stands up its own tiny stub
# listeners on PORT and PORT+1 for the network checks, so it never talks to
# the real gate or a real provider. MODE is "quick" (skips the source
# repo's gitignored-file probe; used by locked-build before every run) or
# "full" (every probe; used by tests/test_canaries.sh and kit-selftest).
#
# Prints one "CANARY OK ..." or "CANARY FAIL ..." line per probe to stdout,
# then a final "CANARY SUMMARY pass=N fail=N" line. Returns 0 (shell true)
# if every probe passed, 1 (shell false) if any failed (including a broken
# positive control) -- callers such as locked-build turn that into their
# own exit 5, since "5 = lockdown/secret-scan refusal" is a whole-program
# exit-code convention this library doesn't own.

CANARIES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CANARIES_LIB_DIR/../bin/kit-common"

# The exact denial pattern the Keychain probe below requires (see its own
# comment): a plain "could not be found" miss is NOT enough on its own,
# because that's also what a legitimate empty search looks like from
# outside the jail. Kept as one named constant, not a literal repeated at
# each call site, so a test asserting on this probe's behavior exercises
# the production probe's own pattern rather than a copy that could quietly
# drift out of sync with it.
_CANARY_KEYCHAIN_DENIAL_PATTERN='*SecKeychainSearchCreateFromAttributes*'

_CANARY_PASS=0
_CANARY_FAIL=0
# Counts invocations of canaries_run within this sourced-in process (see
# KIT_CANARY_FORCE_SUCCEED_CALL above). Deliberately a top-level global,
# not local to canaries_run, so it persists across locked-build's two
# calls (scratch-port, then final-port).
_CANARIES_CALL_COUNT=0

_canary_ok() {
  _CANARY_PASS=$((_CANARY_PASS + 1))
  printf 'CANARY OK   %s\n' "$1"
}

_canary_fail() {
  _CANARY_FAIL=$((_CANARY_FAIL + 1))
  printf 'CANARY FAIL %s: %s\n' "$1" "$2"
}

# _canary_record_pid PID — appends PID to $KIT_CANARY_PID_FILE, if the
# caller set that variable (locked-build and the tests do; a bare manual
# invocation of this file does not). Item 6/7: every listener and stub
# server canaries_run starts must be verifiably dead once it returns --
# this file is what a caller checks against, rather than trusting that
# every kill call above actually landed.
_canary_record_pid() {
  [ -n "$1" ] || return 0
  [ -n "${KIT_CANARY_PID_FILE:-}" ] || return 0
  printf '%s\n' "$1" >> "$KIT_CANARY_PID_FILE"
}

# _canary_denied NAME POSITIVE_CMD JAILED_CMD PROFILE — POSITIVE_CMD and
# JAILED_CMD are strings run through `/bin/sh -c`. POSITIVE_CMD (outside
# the jail) must exit 0, or the canary is broken. JAILED_CMD (inside the
# jail) must exit non-zero AND mention a permission/connection refusal in
# its combined output, or the jail leaked.
#
# KIT_CANARY_FORCE_SUCCEED, a test-only hook: when it equals NAME, the
# jailed command is skipped and treated as if it had leaked (exit 0) —
# this lets tests/test_locked_build.sh prove that locked-build reacts
# correctly to a caught leak without needing a real broken profile.
#
# KIT_CANARY_FORCE_SUCCEED_CALL, an optional companion hook: when set, the
# force only applies on that Nth call to canaries_run within this process
# (locked-build sources this file once and calls canaries_run twice --
# once against the scratch-port profile before the gate starts, once
# against the final, real-port profile right before Claude runs). This is
# what lets a test simulate item 16 -- a hole that exists only in the
# FINAL profile -- distinctly from item 7's "any leak, first check,
# before the gate ever starts" scenario.
_canary_denied() {
  local name positive_cmd jailed_cmd profile extra_pattern pos_out pos_code jail_out jail_code force
  name="$1"; positive_cmd="$2"; jailed_cmd="$3"; profile="$4"; extra_pattern="${5:-}"

  pos_out=$(/bin/sh -c "$positive_cmd" 2>&1)
  pos_code=$?
  if [ "$pos_code" -ne 0 ]; then
    _canary_fail "$name" "positive control failed outside the jail (exit $pos_code): $pos_out"
    return
  fi

  force=0
  if [ "${KIT_CANARY_FORCE_SUCCEED:-}" = "$name" ]; then
    if [ -z "${KIT_CANARY_FORCE_SUCCEED_CALL:-}" ] || [ "${KIT_CANARY_FORCE_SUCCEED_CALL}" = "$_CANARIES_CALL_COUNT" ]; then
      force=1
    fi
  fi

  if [ "$force" -eq 1 ]; then
    jail_out="forced success via KIT_CANARY_FORCE_SUCCEED (test hook)"
    jail_code=0
  else
    # cd into the allowed working tree first: the child /bin/sh otherwise
    # inherits this process's cwd, which the profile may not allow, and its
    # own getcwd() failure noise would otherwise be indistinguishable from
    # the probe's real result.
    jail_out=$(_canary_jail "$profile" "$jailed_cmd")
    jail_code=$?
  fi

  if [ "$jail_code" -eq 0 ]; then
    _canary_fail "$name" "jail allowed it (expected a denial): $jail_out"
    return
  fi
  if [ -n "$extra_pattern" ]; then
    case "$jail_out" in
      $extra_pattern) _canary_ok "$name"; return ;;
    esac
  fi
  case "$jail_out" in
    *"Operation not permitted"*|*"operation not permitted"*|*"Permission denied"*|*"permission denied"* \
      |*"Connection refused"*|*"connection refused"*|*"Couldn't connect"*|*"couldn't connect"* \
      |*"could not connect"*|*"Network is unreachable"*|*"Connection timed out"*|*"timed out"*)
      _canary_ok "$name"
      ;;
    *)
      _canary_fail "$name" "denied, but without a permission/connection refusal message: $jail_out"
      ;;
  esac
}

# _canary_allowed NAME JAILED_CMD PROFILE — JAILED_CMD must succeed (exit 0)
# inside the jail.
_canary_allowed() {
  local name jailed_cmd profile out code
  name="$1"; jailed_cmd="$2"; profile="$3"
  out=$(_canary_jail "$profile" "$jailed_cmd")
  code=$?
  if [ "$code" -eq 0 ]; then
    _canary_ok "$name"
  else
    _canary_fail "$name" "expected success inside the jail, got exit $code: $out"
  fi
}

_canary_wait_for_file() {
  local path i
  path="$1"
  i=0
  while [ ! -e "$path" ] && [ "$i" -lt 100 ]; do
    i=$((i + 1))
    sleep 0.05
  done
}

# _canary_wait_for_port PORT — block (bounded, up to ~5s) until something is
# actually accepting TCP connections on 127.0.0.1:PORT, instead of a fixed
# `sleep 0.2` guess. A background python3 http.server can take longer than
# that to start listening on a loaded/slow box (seen in CI, never on a fast
# local Mac), and the positive control right after this wait connects
# outside the jail -- if the listener isn't up yet, that curl fails with
# "Couldn't connect to server" and the whole canary reports a false
# lockdown failure. curl succeeding here (any HTTP response, any status
# code) is enough to prove the listener itself is up; the caller's own
# probe still does the real check.
_canary_wait_for_port() {
  local port i
  port="$1"
  i=0
  while [ "$i" -lt 100 ]; do
    curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$port/" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

# _canary_jail PROFILE CMD — runs CMD through sandbox-exec, in $_CANARY_WT,
# with the same discipline the real job uses: env -i (no host environment,
# including any credential the invoking shell happens to carry, reaches a
# sandboxed process just because it's "only a canary"), and every file
# descriptor above stderr closed first (a leaked fd would bypass Seatbelt's
# file rules entirely — Seatbelt checks opens, not fds already held).
_canary_jail() {
  local profile cmd
  profile="$1"; cmd="$2"
  # kit_close_extra_fds runs *inside* this subshell only -- closing fds in
  # the caller's own (sourced-in) shell would kill file descriptors
  # locked-build or the test harness still needs for the rest of the run.
  # A fixed "3 4 5 6 7 8 9" list (the prior form) missed any fd opened at
  # a higher number by something further up the call chain; the shared
  # helper closes every fd above stderr it actually finds open.
  ( kit_close_extra_fds
    cd "$_CANARY_WT" && exec sandbox-exec -f "$profile" /usr/bin/env -i \
      HOME="$_CANARY_WT" PATH=/usr/bin:/bin \
      /bin/sh -c "$cmd" ) 2>&1
}

# canaries_run PROFILE WT SRC_REPO PORT MODE
canaries_run() {
  # Every variable here is local: this file is sourced into the caller's
  # shell (locked-build, kit-selftest), not run in a subshell, so a bare
  # assignment to a common name like "name" or "port" would silently
  # clobber the caller's own variable of the same name. (Found the hard
  # way: locked-build's --name value was overwritten by canaries.sh's
  # internal probe names before ledger_append ever saw it.)
  local profile wt src_repo port mode
  local real_home claude_dir canary_dir marker ssh_created alt_pid gate_pid sock_pid
  local link sock gitignored gitignored_path alt_port testfile
  local procinfo_bin procinfo_src
  local argv_probe_bin argv_probe_src sibling_pid sibling_child argv_out argv_code
  local _argv_wait_i _argv_reason
  local rw_out rw_code grandchild_cmd pos_out jail_out gate_out gate_code
  local udp_port wt_sock wt_sock_pid _fd_probe ipv6_route_out

  profile="$1"; wt="$2"; src_repo="$3"; port="$4"; mode="${5:-quick}"
  _CANARY_PASS=0
  _CANARY_FAIL=0
  _CANARIES_CALL_COUNT=$((_CANARIES_CALL_COUNT + 1))

  if [ -z "$profile" ] || [ -z "$wt" ] || [ -z "$port" ]; then
    kit_die 2 "usage: canaries_run PROFILE WT SRC_REPO PORT MODE"
  fi

  _CANARY_WT="$wt"
  real_home="$(kit_realpath "$HOME")"
  claude_dir="$(kit_claude_dir)"
  canary_dir="$real_home/.routing-kit-canary"
  mkdir -p "$canary_dir"
  marker="$canary_dir/marker"
  printf 'canary-marker\n' > "$marker"

  ssh_created=0
  if [ ! -d "$real_home/.ssh" ]; then
    mkdir -p "$real_home/.ssh"
    ssh_created=1
  fi

  alt_pid=""
  gate_pid=""
  sock_pid=""

  _canary_cleanup() {
    rm -f "$marker" "$canary_dir/written" "$wt/.routing-kit-canary-link"
    if [ "$ssh_created" -eq 1 ]; then
      rmdir "$real_home/.ssh" 2>/dev/null
    fi
    [ -n "$alt_pid" ] && { kill "$alt_pid" 2>/dev/null; wait "$alt_pid" 2>/dev/null; }
    [ -n "$gate_pid" ] && { kill "$gate_pid" 2>/dev/null; wait "$gate_pid" 2>/dev/null; }
    [ -n "$sock_pid" ] && { kill "$sock_pid" 2>/dev/null; wait "$sock_pid" 2>/dev/null; }
    [ -n "${wt_sock_pid:-}" ] && { kill "$wt_sock_pid" 2>/dev/null; wait "$wt_sock_pid" 2>/dev/null; }
    rm -f "$canary_dir/sock" "$wt/.rk-wtsock"
    rm -f "$wt/.rk-procinfo-probe" "$wt/.rk-procinfo-probe.c"
    rm -f "$wt/.rk-procargs-probe" "$wt/.rk-procargs-probe.c"
    security delete-generic-password -s routing-kit-canary >/dev/null 2>&1
    # rmdir, not rm -rf: only removes it if every fixture above was
    # actually cleaned up first, so this never eats something unrelated a
    # broken run left behind.
    rmdir "$canary_dir" 2>/dev/null
  }
  trap _canary_cleanup RETURN

  # --- read the real-home marker ---------------------------------------
  _canary_denied "read real-home marker" \
    "cat '$marker'" \
    "cat '$marker'" \
    "$profile"

  # --- list the real .ssh -----------------------------------------------
  _canary_denied "list .ssh" \
    "ls '$real_home/.ssh'" \
    "ls '$real_home/.ssh'" \
    "$profile"

  # --- list Claude Code's config folder ---------------------------------
  if [ -d "$claude_dir" ]; then
    _canary_denied "list Claude config" \
      "ls '$claude_dir'" \
      "ls '$claude_dir'" \
      "$profile"
  fi

  # --- read another process's command line -------------------------------
  # ps -ax -o args: the practical vector anyone would actually use to browse
  # every other process's argv. Denied today via the blanket
  # `(deny mach-lookup)` (ps's own execve fails outright with "Operation
  # not permitted" before it ever gets to a sysctl) -- confirmed unaffected
  # by sysctl-read at all, positive AND negative (see the KERN_PROC probe
  # below, which is the one that actually depends on sysctl-read).
  _canary_denied "read another process's command line (ps -ax -o args)" \
    "ps -ax -o args" \
    "ps -ax -o args" \
    "$profile"

  # --- list processes via the raw sysctl(KERN_PROC) MIB -------------------
  # This is the probe with real teeth against `(deny sysctl-read)`: unlike
  # ps (blocked by mach-lookup regardless of sysctl-read, checked above), a
  # small compiled probe that calls sysctl({CTL_KERN,KERN_PROC,KERN_PROC_ALL})
  # directly is denied ONLY because of the sysctl-read deny/allowlist in
  # lib/seatbelt.sh -- confirmed by temporarily deleting that block and
  # re-running: this exact probe flips from denied to allowed, with no other
  # change. python3 can't be used here: /usr/bin/python3 on stock macOS is a
  # CLT trampoline that needs to write an xcrun cache under the *real*
  # $TMPDIR, which the profile denies, so it fails before ever reaching the
  # sysctl call -- indistinguishable from a real denial. A tiny binary
  # compiled with `cc` outside the jail and exec'd from wt (an already-
  # allowed path) has no such dependency.
  #
  # KNOWN GAP, accepted as a documented residual risk for v1 (see
  # START-HERE): sysctl({CTL_KERN, KERN_PROCARGS2, pid}) for another
  # same-user process succeeds inside the jail regardless. A jailed process
  # can just try every pid (0..99999), so it can read the command line of
  # every process the user is running, not only ones it already knows the
  # pid of. Confirmed unaffected by all four of: (deny sysctl-read), (deny
  # process-info*), (deny process-info*) (allow process-info* (target
  # self)), (deny process-info* (target others)). No Seatbelt primitive
  # found that closes this; not treated as a pass here, and not asserted as
  # a denial either -- asserting a fixed thing here would be a canary that
  # can never go green.
  procinfo_bin="$wt/.rk-procinfo-probe"
  procinfo_src="$wt/.rk-procinfo-probe.c"
  rm -f "$procinfo_bin" "$procinfo_src"
  cat > "$procinfo_src" <<'PROBE_EOF'
#include <sys/sysctl.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
int main(void) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
        fprintf(stderr, "sysctl(KERN_PROC_ALL) failed: %s\n", strerror(errno));
        return 1;
    }
    printf("OK: kern.proc.all size=%zu\n", size);
    return 0;
}
PROBE_EOF
  if command -v cc >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1 && cc -O2 -o "$procinfo_bin" "$procinfo_src" >/dev/null 2>&1; then
    rm -f "$procinfo_src"
    _canary_denied "list other processes via sysctl(KERN_PROC) (teeth-checked against sysctl-read)" \
      "'$procinfo_bin'" \
      "'$procinfo_bin'" \
      "$profile"
    rm -f "$procinfo_bin"
  else
    rm -f "$procinfo_src" "$procinfo_bin"
    printf 'CANARY SKIP list other processes via sysctl(KERN_PROC): no working cc on this machine\n'
  fi

  # --- KNOWN GAP probe: read a sibling process's command line via a pid ---
  # This never counts as a pass or a fail (see the KNOWN GAP comment above
  # the KERN_PROC probe): it just reports which side of the gap this
  # machine is on. Starts its own `sleep 30 MARKER` sibling (same user,
  # started by this canary, killed by its own pid right after -- never a
  # real process this kit didn't create itself) and tries to read that
  # pid's argv from inside the jail via sysctl(KERN_PROCARGS2).
  argv_probe_bin="$wt/.rk-procargs-probe"
  argv_probe_src="$wt/.rk-procargs-probe.c"
  rm -f "$argv_probe_bin" "$argv_probe_src"
  cat > "$argv_probe_src" <<'PROBE_EOF'
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
int main(int argc, char **argv) {
    int pid, mib[3];
    size_t size = 0;
    char *buf;
    if (argc < 2) { fprintf(stderr, "usage: probe pid\n"); return 2; }
    pid = atoi(argv[1]);
    mib[0] = CTL_KERN; mib[1] = KERN_PROCARGS2; mib[2] = pid;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
        fprintf(stderr, "sysctl(KERN_PROCARGS2) size query failed: %s\n", strerror(errno));
        return 1;
    }
    buf = malloc(size);
    if (buf == NULL) { fprintf(stderr, "malloc failed\n"); return 1; }
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) {
        fprintf(stderr, "sysctl(KERN_PROCARGS2) read failed: %s\n", strerror(errno));
        free(buf);
        return 1;
    }
    fwrite(buf, 1, size, stdout);
    free(buf);
    return 0;
}
PROBE_EOF
  if command -v cc >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1 && cc -O2 -o "$argv_probe_bin" "$argv_probe_src" >/dev/null 2>&1; then
    rm -f "$argv_probe_src"
    # macOS sleep rejects a non-number argument and exits at once, so the
    # marker rides on sh's argv instead; the trailing `:` keeps sh from
    # exec'ing sleep in its place (which would drop the marker).
    /bin/sh -c 'sleep 30; :' ROUTING-KIT-CANARY-ARGV-MARKER >/dev/null 2>&1 &
    sibling_pid=$!
    _canary_record_pid "$sibling_pid"
    # Poll (up to ~2s) for the marker to actually show up in the sibling's
    # argv instead of a fixed sleep -- a fixed delay either races a slow
    # fork/exec (flaky SKIP-as-KNOWN-GAP) or wastes time once the marker is
    # already there.
    _argv_wait_i=0
    while [ "$_argv_wait_i" -lt 40 ]; do
      case "$(ps -p "$sibling_pid" -o args= 2>/dev/null)" in
        *ROUTING-KIT-CANARY-ARGV-MARKER*) break ;;
      esac
      _argv_wait_i=$((_argv_wait_i + 1))
      sleep 0.05
    done
    argv_out=$(_canary_jail "$profile" "'$argv_probe_bin' $sibling_pid")
    argv_code=$?
    # `sleep 30; :` runs sleep as a *child* of the sh wrapper (the trailing
    # `:` stops sh from exec'ing sleep in its own place), so killing
    # sibling_pid alone leaves that sleep orphaned for up to 30s. Find and
    # kill its child too (pgrep is a lookup, not a kill of anything this
    # canary didn't start).
    sibling_child=$(pgrep -P "$sibling_pid" 2>/dev/null | head -1)
    kill "$sibling_pid" 2>/dev/null
    [ -n "$sibling_child" ] && kill "$sibling_child" 2>/dev/null
    wait "$sibling_pid" 2>/dev/null
    case "$argv_out" in
      *ROUTING-KIT-CANARY-ARGV-MARKER*)
        printf "CANARY KNOWN-GAP read another process's command line (accepted risk, see START-HERE)\n"
        ;;
      *"sysctl(KERN_PROCARGS2)"*"Operation not permitted"*)
        if [ "$argv_code" -ne 0 ]; then
          printf 'CANARY NOTE known gap now closed by macOS\n'
        else
          printf 'CANARY SKIP known-gap probe inconclusive: probe reported a permission error but exited 0\n'
        fi
        ;;
      *)
        if [ -z "$argv_out" ]; then
          _argv_reason="empty output (exit $argv_code)"
        else
          _argv_reason="exit $argv_code: $(printf '%s\n' "$argv_out" | head -1)"
        fi
        printf 'CANARY SKIP known-gap probe inconclusive: %s\n' "$_argv_reason"
        ;;
    esac
    rm -f "$argv_probe_bin"
  else
    rm -f "$argv_probe_src" "$argv_probe_bin"
    printf 'CANARY SKIP read another process command line (KNOWN GAP probe): no working cc on this machine\n'
  fi

  # --- source repo's gitignored file (full suite only) -------------------
  if [ "$mode" = "full" ] && [ -n "$src_repo" ] && [ -n "$src_repo" ]; then
    gitignored="$(cd "$src_repo" 2>/dev/null && git status --ignored --porcelain 2>/dev/null | awk '/^!! /{print $2; exit}')"
    if [ -n "$gitignored" ]; then
      gitignored_path="$src_repo/$gitignored"
      _canary_denied "read source repo's gitignored file" \
        "cat '$gitignored_path'" \
        "cat '$gitignored_path'" \
        "$profile"
    fi
  fi

  # --- source repo's .git/config ------------------------------------------
  if [ -n "$src_repo" ] && [ -f "$src_repo/.git/config" ]; then
    _canary_denied "read source repo's .git/config" \
      "cat '$src_repo/.git/config'" \
      "cat '$src_repo/.git/config'" \
      "$profile"
  fi

  # --- read the marker through a symlink placed inside wt ------------------
  link="$wt/.routing-kit-canary-link"
  ln -sf "$marker" "$link"
  _canary_denied "read marker through a symlink in wt" \
    "cat '$link'" \
    "cat '$link'" \
    "$profile"
  rm -f "$link"

  # --- inherited file descriptors above stderr ------------------------------
  # Item 4: a caller that happens to be holding an fd open (a pipe, a lock
  # file, anything) must never have that descriptor readable from inside
  # the jail -- Seatbelt's file rules only ever govern new opens, so a
  # leaked fd bypasses them completely regardless of what the profile
  # says. Only probed when the test harness explicitly lists the fd(s) it
  # opened via KIT_CANARY_TEST_FDS="8 10" -- bash itself can transiently
  # hold odd fd numbers open for its own bookkeeping (command substitution,
  # here-docs), so probing "is fd N open?" generically is flaky; a
  # production run never sets this variable, so this is always a no-op
  # outside tests that opt in.
  for _fd_probe in ${KIT_CANARY_TEST_FDS:-}; do
    # A closed fd read via /dev/fd/N on macOS reports "Bad file
    # descriptor", not "No such file or directory" -- confirmed against
    # the real jail.
    _canary_denied "read inherited fd $_fd_probe" \
      "cat /dev/fd/$_fd_probe" \
      "cat /dev/fd/$_fd_probe" \
      "$profile" \
      "*Bad file descriptor*"
  done

  # --- Keychain item -------------------------------------------------------
  # $USER, not "$USER" alone: under `set -u` (locked-build sources this
  # file into its own shell) an unset $USER (e.g. under a stripped env)
  # would abort the whole script, not just this probe.
  security add-generic-password -s routing-kit-canary -a "${USER:-$(id -un)}" -w "canary-secret-$$" -U >/dev/null 2>&1
  # With securityd's mach-lookup denied, the `security` CLI doesn't print
  # "Operation not permitted" itself -- it can't reach securityd to search
  # at all. It prints two lines; only the first is denial-specific --
  # "SecKeychainSearchCopyNext: ... could not be found" alone is also what
  # a normal, unrelated "no such item" miss looks like, so matching on that
  # line alone would pass even if the jail could reach securityd just fine
  # and legitimately found nothing. Require the CreateFromAttributes line,
  # which only appears when the search itself couldn't be started.
  _canary_denied "security find-generic-password" \
    "security find-generic-password -s routing-kit-canary -w" \
    "security find-generic-password -s routing-kit-canary -w" \
    "$profile" \
    "$_CANARY_KEYCHAIN_DENIAL_PATTERN"
  security delete-generic-password -s routing-kit-canary >/dev/null 2>&1

  # --- Unix socket standing in for Docker/ssh-agent -------------------------
  # The listener answers a minimal valid HTTP response, so curl's positive
  # control (outside the jail) gets a clean 0 exit instead of "empty reply".
  sock="$canary_dir/sock"
  rm -f "$sock"
  /usr/bin/python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$sock')
s.listen(1)
resp = b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
while True:
    conn, _ = s.accept()
    try:
        conn.recv(65536)
        conn.sendall(resp)
    except OSError:
        pass
    conn.close()
" >/dev/null 2>&1 &
  sock_pid=$!
  _canary_record_pid "$sock_pid"
  _canary_wait_for_file "$sock"
  # curl --unix-socket, not python3 or plain nc: /usr/bin/python3 on stock
  # macOS is a trampoline into the Xcode Command Line Tools tree, which the
  # profile does not allow reading -- inside the jail it fails with an
  # unrelated xcode-select error before it ever reaches the connect() this
  # probe is testing. Plain `nc -U` does exercise the real connect() and is
  # correctly denied, but macOS's nc prints no diagnostic at all on
  # failure (even with -v), so it can't satisfy "denied with a permission
  # or connection-refusal message in stderr". curl is a real binary under
  # the already-allowed /usr/bin and reports a clean "Couldn't connect".
  _canary_denied "connect to a Unix socket in the real home" \
    "curl -sS --max-time 2 --unix-socket '$sock' http://localhost/" \
    "curl -sS --max-time 2 --unix-socket '$sock' http://localhost/" \
    "$profile"
  kill "$sock_pid" 2>/dev/null
  wait "$sock_pid" 2>/dev/null
  sock_pid=""
  rm -f "$sock"

  # --- Docker socket, if present -------------------------------------------
  if [ -S /var/run/docker.sock ]; then
    _canary_denied "connect to /var/run/docker.sock" \
      "curl -sS --max-time 2 --unix-socket /var/run/docker.sock http://localhost/_ping" \
      "curl -sS --max-time 2 --unix-socket /var/run/docker.sock http://localhost/_ping" \
      "$profile"
  fi

  # --- real internet ---------------------------------------------------------
  # With mach-lookup denied, DNS resolution itself fails (mDNSResponder is
  # reached over mach IPC), so curl reports "Could not resolve host" rather
  # than a refused connection -- both are the network being genuinely cut
  # off, just at different layers.
  _canary_denied "curl https://example.com" \
    "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' https://example.com" \
    "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' https://example.com" \
    "$profile" \
    "*Could not resolve host*"

  # --- a literal IP on 443, no DNS involved at all ----------------------------
  # example.com alone only proves DNS is blocked -- a profile that also had
  # (allow network-outbound (remote ip "*:443")) would still pass that one.
  # 1.1.1.1 is a stable, well-known literal; curl never resolves anything.
  _canary_denied "curl a literal IP on 443 (no DNS)" \
    "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' https://1.1.1.1/" \
    "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' https://1.1.1.1/" \
    "$profile"

  # --- an IPv6 literal --------------------------------------------------------
  # Skipped, not failed, ONLY when this machine has no real IPv6 route at
  # all -- that's an environment limitation, not something the profile
  # controls. Checking "did curl succeed?" (the prior form) conflated that
  # with every other possible curl failure -- a working IPv6 route but a
  # deliberately-failing TLS endpoint, a timeout, anything -- all of which
  # would silently print SKIP instead of surfacing a real problem. `route
  # -n get -inet6` reports routing-table state directly, independent of
  # whatever curl does next; only its own no-route wording skips the probe.
  # Any other outcome (a route exists) runs the real probe through
  # _canary_denied, whose own positive-control check already fails loudly
  # if curl can't even reach the address outside the jail.
  ipv6_route_out=$(route -n get -inet6 2001:4860:4860::8888 2>&1)
  case "$ipv6_route_out" in
    *"not in table"*|*"No route to host"*|*"Network is unreachable"*|*"no route"*)
      printf 'CANARY SKIP curl an IPv6 literal on 443: no IPv6 route on this machine (%s)\n' "$ipv6_route_out"
      ;;
    *)
      _canary_denied "curl an IPv6 literal on 443" \
        "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' https://[2001:4860:4860::8888]/" \
        "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' https://[2001:4860:4860::8888]/" \
        "$profile"
      ;;
  esac

  # --- UDP -----------------------------------------------------------------
  # The relay rule is TCP-only (remote tcp ...): a UDP packet to the very
  # same host:port the rule names must still be denied. UDP has no
  # handshake, so "the send succeeded" proves nothing either way -- the
  # only thing that matters is whether the jail's sendto() itself was
  # allowed or refused, which nc's exit status/stderr still reflects for a
  # closed/refusing port. Positive control target: port+2, deliberately
  # nothing listening -- outside the jail nc still exits 0 for a one-shot
  # UDP send (no ICMP wait), which is what "not broken" means here.
  # -v (verbose): plain `nc -u` exits non-zero on a sandbox refusal but
  # prints nothing at all, which can't satisfy "denied with a message" --
  # -uv makes nc report the connectx() failure explicitly.
  udp_port=$((port + 2))
  _canary_denied "UDP to the relay's host:port" \
    "printf x | nc -uv -w1 127.0.0.1 $udp_port" \
    "printf x | nc -uv -w1 127.0.0.1 $port" \
    "$profile"

  # --- a Unix socket created inside wt (an allowed path) ----------------------
  # Proves the denial above is really the missing unix-socket grant, not
  # just wt's own file rules -- wt is fully allowed for read/write, so if
  # this were denied by a file-path rule instead of the network/socket
  # rule, that would be masking the real property under test.
  #
  # A short, wt-relative filename, not an absolute path: AF_UNIX socket
  # paths are capped at ~104 bytes on macOS, and a real run dir
  # (KIT_HOME/runs/<date>-<slug>-<mktemp suffix>/wt/...) can already be
  # close to that on its own -- bind/connect from inside wt instead.
  wt_sock=".rk-wtsock"
  rm -f "$wt/$wt_sock"
  # >/dev/null 2>&1 on the whole subshell, not just the python3 call: the
  # `cd &&` prefix keeps bash from exec-replacing the subshell with
  # python3, so `kill "$wt_sock_pid"` (below) only ever reaches the
  # subshell, orphaning python3 to keep running past this probe. Without
  # this redirect, that orphan inherits canaries_run's own stdout/stderr
  # and keeps writing to a fd that traces back to the caller's
  # `out=$(canaries_run ...)` pipe -- which then never sees EOF and hangs
  # forever, long after every probe has actually finished. (Found the hard
  # way: test_canaries.sh hung for minutes with no further output right
  # after this probe, even though every canary had already reported.)
  #
  # `exec /usr/bin/python3 ...`, not a bare `/usr/bin/python3 ...`: in bash
  # 3.2, `( cd "$wt" && cmd ) &` does NOT replace the subshell's own process
  # image with cmd merely because it's the last thing the subshell runs --
  # `kill "$wt_sock_pid"` (below) then only ever reaches that subshell
  # wrapper, orphaning python3 itself to keep listening forever after every
  # canaries_run call (found the hard way: 38 of these were still running
  # on the Mac, one per past run, cleaned up by PID). `exec` inside the
  # subshell replaces its process image with python3's, so $! (the
  # subshell's pid at fork time) and python3's own pid become the same
  # number, and `kill "$wt_sock_pid"` actually reaches it.
  ( cd "$wt" && exec /usr/bin/python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$wt_sock')
s.listen(1)
resp = b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
while True:
    conn, _ = s.accept()
    try:
        conn.recv(65536)
        conn.sendall(resp)
    except OSError:
        pass
    conn.close()
" ) >/dev/null 2>&1 &
  wt_sock_pid=$!
  _canary_record_pid "$wt_sock_pid"
  _canary_wait_for_file "$wt/$wt_sock"
  _canary_denied "connect to a Unix socket inside wt" \
    "( cd '$wt' && curl -sS --max-time 2 --unix-socket '$wt_sock' http://localhost/ )" \
    "curl -sS --max-time 2 --unix-socket '$wt_sock' http://localhost/" \
    "$profile"
  kill "$wt_sock_pid" 2>/dev/null
  wait "$wt_sock_pid" 2>/dev/null
  rm -f "$wt/$wt_sock"

  # --- another loopback port (not the one the profile allows) ---------------
  alt_port=$((port + 1))
  /usr/bin/python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(('127.0.0.1', $alt_port), H)
httpd.serve_forever()
" >/dev/null 2>&1 &
  alt_pid=$!
  _canary_record_pid "$alt_pid"
  if _canary_wait_for_port "$alt_port"; then
    _canary_denied "curl another loopback port" \
      "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$alt_port/" \
      "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$alt_port/" \
      "$profile"
  else
    _canary_fail "curl another loopback port" "listener on port $alt_port never came up"
  fi
  kill "$alt_pid" 2>/dev/null
  wait "$alt_pid" 2>/dev/null
  alt_pid=""

  # --- write into the real home -----------------------------------------
  rm -f "$canary_dir/written"
  _canary_denied "write into the real home" \
    "sh -c \"echo x > '$canary_dir/written' && rm -f '$canary_dir/written'\"" \
    "echo x > '$canary_dir/written'" \
    "$profile"
  rm -f "$canary_dir/written"

  # --- background grandchild still denied -----------------------------------
  grandchild_cmd="sh -c 'cat \"$marker\" & wait' 2>&1"
  pos_out=$(/bin/sh -c "$grandchild_cmd")
  case "$pos_out" in
    *canary-marker*) : ;;
    *) _canary_fail "background grandchild denied" "positive control did not read the marker: $pos_out" ;;
  esac
  case "$pos_out" in
    *canary-marker*)
      if [ "${KIT_CANARY_FORCE_SUCCEED:-}" = "background grandchild denied" ]; then
        jail_out="canary-marker (forced via KIT_CANARY_FORCE_SUCCEED test hook)"
      else
        jail_out=$(_canary_jail "$profile" "$grandchild_cmd")
      fi
      case "$jail_out" in
        *canary-marker*)
          _canary_fail "background grandchild denied" "jail's grandchild still read the marker: $jail_out"
          ;;
        *"Operation not permitted"*|*"Permission denied"*)
          _canary_ok "background grandchild denied"
          ;;
        *)
          _canary_fail "background grandchild denied" "denied, but without a permission message: $jail_out"
          ;;
      esac
      ;;
  esac

  # --- must succeed: read/write inside wt -----------------------------------
  testfile="$wt/.routing-kit-canary-rw"
  rw_out=$(_canary_jail "$profile" "echo hi > '$testfile' && cat '$testfile' && rm -f '$testfile'")
  rw_code=$?
  if [ "$rw_code" -eq 0 ]; then
    case "$rw_out" in
      *hi*) _canary_ok "read/write inside wt" ;;
      *) _canary_fail "read/write inside wt" "unexpected output: $rw_out" ;;
    esac
  else
    _canary_fail "read/write inside wt" "exit $rw_code: $rw_out"
  fi
  rm -f "$testfile"

  # --- must succeed: reaching the allowed port ------------------------------
  # If something is already listening on $port (locked-build's own re-check
  # of the FINAL profile, item 6, runs this against the real, already-
  # started gate), don't also try to bind our own stub there -- just probe
  # whatever's already there. A GET to "/" is denied (403) by the real gate
  # too, without forwarding anything upstream, so this stays provider-safe
  # either way.
  if ! curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$port/" >/dev/null 2>&1; then
    /usr/bin/python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(403)
        self.end_headers()
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(('127.0.0.1', $port), H)
httpd.serve_forever()
" >/dev/null 2>&1 &
    gate_pid=$!
    _canary_record_pid "$gate_pid"
    _canary_wait_for_port "$port"
  fi
  gate_out=$(_canary_jail "$profile" "curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/")
  gate_code=$?
  kill "$gate_pid" 2>/dev/null
  wait "$gate_pid" 2>/dev/null
  gate_pid=""
  case "$gate_out" in
    [1-9][0-9][0-9])
      if [ "$gate_code" -eq 0 ]; then
        _canary_ok "reach the allowed loopback port (status $gate_out)"
      else
        _canary_fail "reach the allowed loopback port" "curl exited $gate_code despite a status line: $gate_out"
      fi
      ;;
    *) _canary_fail "reach the allowed loopback port" "expected an HTTP status, got exit $gate_code: $gate_out" ;;
  esac

  printf 'CANARY SUMMARY pass=%s fail=%s\n' "$_CANARY_PASS" "$_CANARY_FAIL"
  [ "$_CANARY_FAIL" -eq 0 ]
}

# Allow `bash canaries.sh PROFILE WT SRC_REPO PORT MODE` for manual/CI use.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  kit_require_macos
  canaries_run "$1" "$2" "$3" "$4" "${5:-quick}"
  exit $?
fi
