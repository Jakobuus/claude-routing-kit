#!/bin/bash
# lib/seatbelt.sh — seatbelt_generate OUTFILE WT RUN_HOME RUN_CFG RUN_TMP CLAUDE_BIN GATE_PORT [EXTRA]
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
#
# Sourced by callers, not run directly. Depends on kit-common (kit_die).
#
# Writes a Seatbelt (sandbox-exec) profile that imports system.sb (needed for
# the dyld cache and other paths nobody can enumerate by hand), then takes
# back the broad mach-lookup and network-outbound grants system.sb makes,
# and allows only: reading the jail's own paths (the working tree, the
# throwaway HOME/CLAUDE_CONFIG_DIR/TMPDIR, and the single resolved Claude
# binary) plus one specific loopback port (the gate). There is no
# Unix-socket rule at all, and /usr/local and /opt/homebrew stay unreadable.

SEATBELT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SEATBELT_LIB_DIR/../bin/kit-common"

# seatbelt_validate_path PATH — exit 2 if PATH contains a double quote,
# backslash or newline: none of those can be written safely into Seatbelt's
# scheme-like profile syntax.
seatbelt_validate_path() {
  local path
  path="$1"
  case "$path" in
    *'"'*)
      kit_die 2 "path unsafe for seatbelt profile (contains a double quote): $path"
      ;;
  esac
  case "$path" in
    *'\'*)
      kit_die 2 "path unsafe for seatbelt profile (contains a backslash): $path"
      ;;
  esac
  case "$path" in
    *"
"*)
      kit_die 2 "path unsafe for seatbelt profile (contains a newline): $path"
      ;;
  esac
}

# seatbelt_generate OUTFILE WT RUN_HOME RUN_CFG RUN_TMP CLAUDE_BIN GATE_PORT [EXTRA_RULES]
#
# WT, RUN_HOME, RUN_CFG, RUN_TMP, CLAUDE_BIN must already be resolved with
# `cd "$p" && pwd -P` (kit_realpath) by the caller — Seatbelt only matches
# resolved paths. CLAUDE_BIN is a single file (the native Claude binary
# under ~/.local/share/claude/versions/<ver>), not a directory.
# EXTRA_RULES, if given, is a string of additional profile lines appended
# verbatim at the end — used only to record the one missing path or mach
# service `log stream` turns up while debugging a jailed start, never a
# blanket rule.
seatbelt_generate() {
  # local: this file is sourced into the caller's shell, not run in a
  # subshell, so these names (wt, run_home, run_cfg, run_tmp, claude_bin,
  # gate_port) must not leak into and clobber the caller's own variables
  # of the same name.
  local outfile wt run_home run_cfg run_tmp claude_bin gate_port extra wt_git
  outfile="$1"; wt="$2"; run_home="$3"; run_cfg="$4"; run_tmp="$5"
  claude_bin="$6"; gate_port="$7"; extra="${8:-}"

  if [ -z "$outfile" ] || [ -z "$wt" ] || [ -z "$run_home" ] || [ -z "$run_cfg" ] \
     || [ -z "$run_tmp" ] || [ -z "$claude_bin" ] || [ -z "$gate_port" ]; then
    kit_die 2 "usage: seatbelt_generate OUTFILE WT RUN_HOME RUN_CFG RUN_TMP CLAUDE_BIN GATE_PORT [EXTRA]"
  fi

  seatbelt_validate_path "$wt"
  seatbelt_validate_path "$run_home"
  seatbelt_validate_path "$run_cfg"
  seatbelt_validate_path "$run_tmp"
  seatbelt_validate_path "$claude_bin"

  case "$gate_port" in
    ''|*[!0-9]*) kit_die 2 "invalid gate port: $gate_port" ;;
  esac

  # No /private/tmp/claude-<uid> grant: that directory is shared with every
  # OTHER Claude session the user runs unjailed on this machine (lockdown
  # fix wave 1, item 2). CLAUDE_CODE_TMPDIR relocates Claude's whole per-uid
  # IPC/lock dir to a caller-chosen path instead -- confirmed against the
  # real binary (`strings` on it: "CLAUDE_CODE_TMPDIR makes the per-uid temp
  # dir", "Point XDG_RUNTIME_DIR or CLAUDE_CODE_TMPDIR at a private (0700)
  # directory you own to use a different location") and by running it in a
  # real jail with CLAUDE_CODE_TMPDIR=<run_tmp>: it creates claude-<uid>/ and
  # cc-socks/ there instead, never touching /private/tmp/claude-<uid>. The
  # caller (bin/locked-build) is responsible for setting CLAUDE_CODE_TMPDIR
  # in the jail's env; this profile only needs to allow run_tmp, which it
  # already does.

  wt_git="$wt/.git"
  seatbelt_validate_path "$wt_git"

  cat > "$outfile" <<EOF
(version 1)
(deny default)
(import "system.sb")
;; take back system.sb's broad grants. Checked 28/09-29/09 on macOS 26.5.1:
;; system.sb also grants many *named* (global-name) mach services outside
;; the xpc-service-name-prefix filter (advisers, codex review) -- deny ALL
;; mach-lookup outright rather than trying to enumerate every prefix/name
;; system.sb grants. Confirmed by running the real Claude binary (and git,
;; which it shells out to) against a profile with a total mach-lookup deny
;; and no exceptions at all: both tolerate every resulting denial
;; gracefully (FSEvents, SecurityServer, securityd.xpc, git's own
;; CommandLineTools.installondemand, etc. all get refused and the build
;; still completes) -- see task7-canaries.txt for the log stream evidence.
(deny mach-lookup)
(deny network-outbound)
;; system.sb (line ~191 on macOS 26.5.1) unconditionally allows
;; sysctl-read; deleting our own former duplicate grant (wave 1) revoked
;; nothing, since the import's own grant was still standing underneath.
;; Deny it outright, then allow back only the exact names the real Claude
;; binary (Bun v1.4.3) was seen reading via /usr/bin/log stream (predicate:
;; eventMessage contains sysctl) while it booted under this jail: with
;; sysctl-read fully denied and no allowlist, the real binary crashed hard
;; ("panic(main thread): Trap instruction ... Bun has crashed") right after
;; the kernel logged denials for hw.optional.arm.FEAT_AES / AdvSIMD /
;; floatingpoint / armv8_crc32 / FEAT_LSE -- Bun's JIT reads these to detect
;; CPU features before emitting code, and a denied read (rather than a
;; clean "unsupported") apparently feeds it a bad value. None of the names
;; below expose another process's identity or arguments (that's
;; kern.procargs*/kern.proc*, deliberately NOT in this list): they're OS
;; version/variant flags and CPU capability bits. Re-tested with this exact
;; list: the real binary boots and completes a build (see
;; tests/live/boot-check.sh and the evidence file).
(deny sysctl-read)
(allow sysctl-read
  (sysctl-name "kern.osproductversion")
  (sysctl-name "kern.iossupportversion")
  (sysctl-name "kern.osvariant_status")
  (sysctl-name "security.mac.lockdown_mode_state")
  (sysctl-name "hw.ephemeral_storage")
  (sysctl-name "hw.pagesize_compat")
  (sysctl-name "hw.optional.arm.FEAT_AES")
  (sysctl-name "hw.optional.arm.AdvSIMD")
  (sysctl-name "hw.optional.floatingpoint")
  (sysctl-name "hw.optional.armv8_crc32")
  (sysctl-name "hw.optional.arm.FEAT_LSE"))
;; what the jail may do
(allow process-exec* process-fork signal)
(allow file-read-metadata (subpath "$wt") (subpath "$run_home") (subpath "$run_cfg") (subpath "$run_tmp")
                          (literal "$claude_bin") (subpath "/usr/bin") (subpath "/bin"))
(allow file-read*
  (subpath "/usr/lib") (subpath "/usr/bin") (subpath "/usr/share") (subpath "/bin")
  (subpath "/System") (subpath "/private/var/db/dyld")
  (literal "/private/etc/hosts") (literal "/private/etc/resolv.conf") (subpath "/private/etc/ssl")
  ;; macOS's /bin/sh dispatcher reads this to pick bash-as-sh vs zsh-as-sh;
  ;; without it every /bin/sh invocation in the jail (including Claude's own
  ;; Bash tool calls) logs a benign but noisy "Operation not permitted" on
  ;; startup. The file only names a shell, nothing sensitive.
  (literal "/private/var/select/sh")
  ;; /usr/bin/git (and /usr/bin/python3) on stock macOS are trampolines
  ;; into the Xcode Command Line Tools: without read access here, plain
  ;; git status -- the very thing item 1 requires still works read-only in
  ;; the jail -- fails hard with "developer directory ... isn't
  ;; accessible" instead of running. Confirmed narrowly: file-read-metadata
  ;; alone is not enough (still fails "isn't accessible"); this subpath is
  ;; the minimum that got git status itself to exit 0. No secrets live
  ;; here; it is Apple's own toolchain, not the run's data.
  (subpath "/Library/Developer/CommandLineTools")
  (literal "$claude_bin")
  (subpath "$wt") (subpath "$run_home") (subpath "$run_cfg") (subpath "$run_tmp"))
(allow file-write*
  (subpath "$wt") (subpath "$run_home") (subpath "$run_cfg") (subpath "$run_tmp")
  (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr") (literal "/dev/tty"))
;; The jail may edit the working files only, never wt's own git metadata:
;; the kit reads the build back as a diff with an isolated git config
;; (kit_git) run OUTSIDE the jail, so a build that plants a smudge/clean
;; filter, a diff textconv, or core.fsmonitor in wt/.git/config could still
;; get THAT config read (and executed) by the unsandboxed git call
;; afterward. Last matching rule wins, so this narrows the file-write*
;; grant just above for this one subpath. Read stays allowed (git status
;; read-only works fine jailed).
(deny file-write* (subpath "$wt_git"))
;; TCP only, and only to the gate's one loopback port -- not "ip" (which
;; also matches UDP). Confirmed (remote tcp "...") is valid syntax on this
;; sandbox-exec/macOS 26.5.1.
(allow network-outbound (remote tcp "localhost:$gate_port"))
EOF

  if [ -n "$extra" ]; then
    printf '%s\n' "$extra" >> "$outfile"
  fi
}
