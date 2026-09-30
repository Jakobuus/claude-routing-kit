#!/bin/bash
# tests/live/boot-check.sh -- item 19. A real start-up check: the actual
# native Claude binary, actually booted inside the actual Seatbelt jail,
# talking to a fake upstream over the real gate. Nothing here is faked
# except the upstream provider and the Keychain lookup -- everything else
# (locked-build, the profile, the canaries, gate.py, the real Claude
# binary) is the genuine article.
#
# NOT run by tests/run: it needs the real native Claude install, which
# tests/run's fake-Claude suite deliberately never assumes is present.
# Run this file directly, on a Mac with Claude Code installed natively.
#
# bash 3.2 compatible: no mapfile, no ${x,,}, no associative arrays.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LOCKED_BUILD="$REPO_ROOT/plugins/routing-kit/bin/locked-build"

PASS_COUNT=0
FAIL_COUNT=0

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$1"
}

bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

case "$(uname)" in
  Darwin) ;;
  *)
    echo "SKIP: boot-check.sh needs macOS (real Seatbelt jail, real native Claude)" >&2
    echo "PASS 0 / FAIL 0"
    exit 0
    ;;
esac

# --- the real native Claude binary, the same check locked-build itself
# makes (kept here too so a failure is diagnosed before anything else runs,
# with a clear message pointing at the actual hard rule) -------------------
claude_cmd="$(command -v claude 2>/dev/null || true)"
if [ -z "$claude_cmd" ]; then
  bad "real claude on PATH" "no 'claude' found on PATH; install the native app first"
  echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
  exit 1
fi
claude_bin_resolved="$(readlink -f "$claude_cmd" 2>/dev/null || true)"
case "$claude_bin_resolved" in
  */.local/share/claude/versions/*)
    ok "real claude resolves under ~/.local/share/claude/versions/ ($claude_bin_resolved)"
    ;;
  *)
    bad "real claude is the native install" "readlink -f \"\$(command -v claude)\" gave: $claude_bin_resolved"
    echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
    exit 1
    ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rk-boot-check.XXXXXX")
cleanup() {
  [ -n "${UPSTREAM_PID:-}" ] && kill "$UPSTREAM_PID" 2>/dev/null
  [ -n "${UPSTREAM_PID:-}" ] && wait "$UPSTREAM_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- a fake upstream: accepts POST /v1/messages(?beta=true) with ANY query
# string (the real Claude binary sends ?beta=true; a fake that matched the
# exact path only would 404 and Claude would report a model-selection
# error, per the plan's Learnings), and drives exactly one tool call: the
# first request (no tool_result in its messages yet) gets back a Write
# tool_use for hello.txt/"hi"; the second (after that tool_result) gets a
# plain end_turn reply so the conversation actually finishes. -------------
cat > "$WORK/fake_upstream.py" <<'PYEOF'
import http.server
import json
import sys

port_file = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        try:
            req = json.loads(body) if body else {}
        except ValueError:
            req = {}

        has_tool_result = False
        for m in req.get("messages", []):
            content = m.get("content")
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        has_tool_result = True

        if not has_tool_result:
            resp = {
                "id": "msg_boot_1",
                "type": "message",
                "role": "assistant",
                "model": "kimi-boot-check",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_boot_1",
                        "name": "Write",
                        "input": {"file_path": "hello.txt", "content": "hi"},
                    }
                ],
                "stop_reason": "tool_use",
                "usage": {"input_tokens": 5, "output_tokens": 7},
            }
        else:
            resp = {
                "id": "msg_boot_2",
                "type": "message",
                "role": "assistant",
                "model": "kimi-boot-check",
                "content": [{"type": "text", "text": "done"}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 3, "output_tokens": 2},
            }

        data = json.dumps(resp).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(httpd.server_port))
httpd.serve_forever()
PYEOF

/usr/bin/python3 "$WORK/fake_upstream.py" "$WORK/upstream-port" >"$WORK/upstream.log" 2>&1 &
UPSTREAM_PID=$!

i=0
while [ ! -s "$WORK/upstream-port" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    bad "fake upstream started" "no port file after 5s (see $WORK/upstream.log)"
    echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
    exit 1
  fi
  sleep 0.05
done
UPSTREAM_PORT="$(cat "$WORK/upstream-port")"
ok "fake upstream listening on 127.0.0.1:$UPSTREAM_PORT"

# --- a fake keychain: never a real key, built at runtime the same way the
# other test suites build their runtime-only test secrets --------------------
cat > "$WORK/security" <<'EOF'
#!/bin/bash
if [ "$1" = "-s" ] && [ "$3" = "-w" ]; then
  echo "boot-check-fake-key-$$"
  exit 0
fi
exit 44
EOF
chmod +x "$WORK/security"

# --- a temp repo, committed and clean (run_export refuses a dirty one) -----
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email you@example.com
git -C "$REPO" config user.name "boot-check"
echo hello > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m init >/dev/null

KIT_HOME="$WORK/kit-home"
mkdir -p "$KIT_HOME"
printf '{"version":1,"claude_plan":"api","codex":"none","jules":false,"kimi":true,"glm":false,"paseo":false}\n' \
  > "$KIT_HOME/profile.json"

BRIEF="$WORK/brief.md"
printf 'Use the Write tool to create hello.txt containing hi, then stop.\n' > "$BRIEF"

# --- snapshot /private/tmp/claude-<uid> before the run ----------------------
CLAUDE_SHARED_TMP="/private/tmp/claude-$(id -u)"
before_snapshot="$WORK/before.txt"
after_snapshot="$WORK/after.txt"
if [ -d "$CLAUDE_SHARED_TMP" ]; then
  find "$CLAUDE_SHARED_TMP" 2>/dev/null | sort > "$before_snapshot"
else
  : > "$before_snapshot"
fi

# --- the real run ------------------------------------------------------------
CANARY_PID_LOG="$WORK/canary-pids.txt"
run_log="$WORK/locked-build.log"
env ROUTING_KIT_HOME="$KIT_HOME" \
    KIT_KEYCHAIN_CMD="$WORK/security" \
    KIT_GATE_UPSTREAM="http://127.0.0.1:$UPSTREAM_PORT" \
    GATE_TEST_UPSTREAM_INSECURE=1 \
    KIT_CANARY_PID_FILE="$CANARY_PID_LOG" \
    bash "$LOCKED_BUILD" --provider kimi --repo "$REPO" --name boot-check --brief "$BRIEF" \
    > "$run_log" 2>&1
run_code=$?

cat "$run_log"

if [ "$run_code" -eq 0 ]; then
  ok "locked-build exits 0"
else
  bad "locked-build exits 0" "got exit $run_code (see $run_log above)"
fi

if grep -q '^+++ b/hello\.txt$' "$run_log"; then
  ok "the diff shows hello.txt"
else
  bad "the diff shows hello.txt" "no '+++ b/hello.txt' line in locked-build's output"
fi

# --- nothing new under the shared /private/tmp/claude-<uid> dir -------------
if [ -d "$CLAUDE_SHARED_TMP" ]; then
  find "$CLAUDE_SHARED_TMP" 2>/dev/null | sort > "$after_snapshot"
else
  : > "$after_snapshot"
fi
new_entries="$(comm -13 "$before_snapshot" "$after_snapshot" 2>/dev/null)"
if [ -z "$new_entries" ]; then
  ok "nothing new under $CLAUDE_SHARED_TMP"
else
  bad "nothing new under $CLAUDE_SHARED_TMP" "new entries: $new_entries"
fi

# --- no process this run started is still alive -----------------------------
run_dir="$(grep -m1 '^run dir: ' "$run_log" | sed 's/^run dir: //')"
sleep 0.3
still_alive=""
if [ -n "$run_dir" ] && pgrep -f "$run_dir" >/dev/null 2>&1; then
  still_alive="$(pgrep -fl "$run_dir" 2>/dev/null)"
fi
if [ -f "$CANARY_PID_LOG" ]; then
  while IFS= read -r rec_pid; do
    [ -n "$rec_pid" ] || continue
    if kill -0 "$rec_pid" 2>/dev/null; then
      still_alive="$still_alive
canary pid $rec_pid still alive"
    fi
  done < "$CANARY_PID_LOG"
fi
if [ -z "$still_alive" ]; then
  ok "no process this run started is still alive"
else
  bad "no process this run started is still alive" "$still_alive"
fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
