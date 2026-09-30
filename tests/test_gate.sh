#!/bin/bash
# tests/test_gate.sh -- the auth relay (lib/gate.py) against a fake upstream.
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GATE="$REPO_ROOT/plugins/routing-kit/lib/gate.py"

# The provider key must never be a literal in this source file. Build it at
# runtime from pid + timestamp so nothing resembling a real key ever sits in
# the repo, and privacy-check has nothing fixed to flag.
TEST_KEY="test-key-$$-$(date +%s)-$RANDOM"

d=$(mktmp)
UPSTREAM_DIR="$d/upstream"
mkdir -p "$UPSTREAM_DIR"
UPSTREAM_PORT_FILE="$UPSTREAM_DIR/port"
UPSTREAM_LOG="$UPSTREAM_DIR/requests.log"
FAKE_UPSTREAM="$UPSTREAM_DIR/fake_upstream.py"

# --- the fake upstream: records headers it received, and streams three SSE
# chunks with delays on POST /v1/messages so we can prove the gate does not
# buffer the response. ------------------------------------------------------
cat > "$FAKE_UPSTREAM" <<'PYEOF'
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file = sys.argv[1]
log_file = sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _record(self):
        with open(log_file, "a") as f:
            f.write(json.dumps({
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers.items()),
            }) + "\n")

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(n) if n > 0 else b""

    def do_POST(self):
        self._body()
        self._record()
        if self.path == "/v1/messages":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            for i in range(1, 4):
                chunk = ("event: chunk%d\ndata: {}\n\n" % i).encode("utf-8")
                self.wfile.write(("%x\r\n" % len(chunk)).encode("ascii"))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                if i < 3:
                    time.sleep(0.3)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path == "/v1/messages/count_tokens":
            auth = self.headers.get("Authorization", "")
            key_only = auth[len("Bearer "):] if auth.startswith("Bearer ") else auth
            body = json.dumps({"error": "bad key, saw: %s" % auth}).encode("utf-8")
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Upstream-Debug", auth)
            # A header whose NAME (not just its value) embeds the key, to
            # prove the gate scrubs header names too.
            if key_only:
                self.send_header("X-Debug-%s" % key_only, "1")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def do_GET(self):
        self._record()
        if self.path == "/v1/models":
            import gzip
            body = gzip.compress(b'{"models":[]}')
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PYEOF

/usr/bin/python3 "$FAKE_UPSTREAM" "$UPSTREAM_PORT_FILE" "$UPSTREAM_LOG" &
UPSTREAM_PID=$!

i=0
while [ ! -s "$UPSTREAM_PORT_FILE" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    fail "fake upstream never wrote its port file"
    kill "$UPSTREAM_PID" 2>/dev/null
    echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
    exit 1
  fi
  sleep 0.05
done
UPSTREAM_PORT=$(cat "$UPSTREAM_PORT_FILE")
BASE_URL="http://127.0.0.1:$UPSTREAM_PORT"

# --- start the gate against the fake upstream -------------------------------
GATE_DIR="$d/gate"
mkdir -p "$GATE_DIR"
GATE_PORT_FILE="$GATE_DIR/port"
GATE_STDERR="$GATE_DIR/stderr.log"

printf '%s\n' "$TEST_KEY" | GATE_TEST_UPSTREAM_INSECURE=1 /usr/bin/python3 "$GATE" \
  --upstream "$BASE_URL" --port-file "$GATE_PORT_FILE" >"$GATE_DIR/stdout.log" 2>"$GATE_STDERR" &
GATE_PID=$!

i=0
while [ ! -s "$GATE_PORT_FILE" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    fail "gate never wrote its port file"
    kill "$GATE_PID" 2>/dev/null
    kill "$UPSTREAM_PID" 2>/dev/null
    echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
    exit 1
  fi
  sleep 0.05
done
GATE_PORT=$(cat "$GATE_PORT_FILE")
GATE_URL="http://127.0.0.1:$GATE_PORT"

cleanup() {
  kill "$GATE_PID" 2>/dev/null
  kill "$UPSTREAM_PID" 2>/dev/null
  wait "$GATE_PID" 2>/dev/null
  wait "$UPSTREAM_PID" 2>/dev/null
}
trap cleanup EXIT

# --- test: key never on the gate's argv (ps -o args) ------------------------
ps_out=$(ps -o args= -p "$GATE_PID" 2>/dev/null)
case "$ps_out" in
  *"$TEST_KEY"*) fail "gate process argv (ps -o args) contains the key" ;;
  *) pass ;;
esac

# --- test: allowed POST /v1/messages streams, and upstream sees the real key,
# not the client's placeholder x-api-key -------------------------------------
stream_out="$d/stream.out"
: > "$stream_out"
curl -s -N --max-time 5 \
  -H "x-api-key: placeholder" \
  -H "content-type: application/json" \
  -X POST -d '{}' \
  "$GATE_URL/v1/messages" > "$stream_out" 2>/dev/null &
CURL_PID=$!

# The fake upstream sleeps 0.3s between each of its 3 chunks (~0.9s total).
# If the gate streams instead of buffering, chunk1 must be visible well
# before that.
sleep 0.15
early_out=$(cat "$stream_out")
case "$early_out" in
  *chunk1*) pass ;;
  *) fail "first SSE chunk did not arrive within 0.15s (gate is buffering)" ;;
esac
case "$early_out" in
  *chunk3*) fail "all chunks arrived within 0.15s (upstream delay not respected by test, or gate buffered whole reply before forwarding any of it)" ;;
  *) pass ;;
esac

wait "$CURL_PID" 2>/dev/null
final_out=$(cat "$stream_out")
assert_contains "$final_out" "chunk1" "streamed response contains chunk1"
assert_contains "$final_out" "chunk2" "streamed response contains chunk2"
assert_contains "$final_out" "chunk3" "streamed response contains chunk3"

# the upstream must have received the real key as a Bearer token, not the
# client's x-api-key
last_req=$(tail -n 1 "$UPSTREAM_LOG")
auth_seen=$(echo "$last_req" | /usr/bin/python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
print(rec["headers"].get("Authorization", ""))
')
assert_eq "Bearer $TEST_KEY" "$auth_seen" "upstream saw Authorization: Bearer <key>"
xapikey_seen=$(echo "$last_req" | /usr/bin/python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
print(rec["headers"].get("x-api-key", "MISSING"))
')
assert_eq "MISSING" "$xapikey_seen" "client x-api-key never reached upstream"

# --- test: denied routes never reach upstream, and get 403 ------------------
status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$GATE_URL/")
assert_eq "403" "$status" "GET / is denied"

status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -d '{}' "$GATE_URL/v1/files")
assert_eq "403" "$status" "POST /v1/files is denied"

# CONNECT is not something curl's -X sends as a real CONNECT request in this
# context reliably across curl versions, so speak raw HTTP over a socket.
connect_status=$(/usr/bin/python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", '"$GATE_PORT"'), timeout=5)
s.sendall(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
data = s.recv(200)
s.close()
print(data.split(b" ")[1].decode() if b" " in data else "")
')
assert_eq "403" "$connect_status" "CONNECT is denied"

# --- test: an upstream error body (and header) that echoes the key comes
# back with the key scrubbed --------------------------------------------------
err_out="$d/err.out"
curl -s --max-time 5 -D "$d/err.headers" -X POST -d '{}' "$GATE_URL/v1/messages/count_tokens" > "$err_out" 2>/dev/null
err_body=$(cat "$err_out")
err_headers=$(cat "$d/err.headers")
case "$err_body" in
  *"$TEST_KEY"*) fail "scrubbed error body still contains the key" ;;
  *) pass ;;
esac
assert_contains "$err_body" "REDACTED" "scrubbed error body shows a redaction marker"
case "$err_headers" in
  *"$TEST_KEY"*) fail "scrubbed error response headers still contain the key (name or value)" ;;
  *) pass ;;
esac
case "$err_headers" in
  *X-Debug-*) fail "a header whose name held the key was rewritten (invalid token) instead of dropped" ;;
  *) pass ;;
esac

# --- test: a request-target that isn't origin-form (absolute-form, or a
# bare "*") must be denied, even when its parsed path would otherwise match
# an allowed route ------------------------------------------------------------
absolute_status=$(/usr/bin/python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", '"$GATE_PORT"'), timeout=5)
s.sendall(b"GET http://elsewhere.example/v1/models HTTP/1.1\r\nHost: elsewhere.example\r\nConnection: close\r\n\r\n")
data = s.recv(200)
s.close()
print(data.split(b" ")[1].decode() if b" " in data else "")
')
assert_eq "403" "$absolute_status" "absolute-form request target is denied"

asterisk_status=$(/usr/bin/python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", '"$GATE_PORT"'), timeout=5)
s.sendall(b"OPTIONS * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
data = s.recv(200)
s.close()
print(data.split(b" ")[1].decode() if b" " in data else "")
')
assert_eq "403" "$asterisk_status" "asterisk-form request target is denied"

# --- test: an unlisted method (not just the ones the gate enumerates) is
# denied with 403, not the stdlib default of 501 ------------------------------
trace_status=$(/usr/bin/python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", '"$GATE_PORT"'), timeout=5)
s.sendall(b"TRACE /v1/models HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
data = s.recv(200)
s.close()
print(data.split(b" ")[1].decode() if b" " in data else "")
')
assert_eq "403" "$trace_status" "TRACE (an unlisted method) is denied with 403, not 501"

# --- test: a client-supplied query string never reaches the gate's stderr
# log -- the log line carries the path only ------------------------------------
curl -s -o /dev/null --max-time 5 -X POST -d '{}' "$GATE_URL/v1/messages/count_tokens?echo=$TEST_KEY" >/dev/null 2>&1
sleep 0.1
log_after_query=$(cat "$GATE_STDERR")
case "$log_after_query" in
  *"$TEST_KEY"*) fail "gate stderr log leaked the key via a request query string" ;;
  *) pass ;;
esac
assert_contains "$log_after_query" "allow POST /v1/messages/count_tokens 400" "gate logs the path without its query string"

# --- test: a key in the request path itself (denied, 403) never reaches the log
curl -s -o /dev/null --max-time 5 "$GATE_URL/$TEST_KEY" >/dev/null 2>&1
sleep 0.1
case "$(cat "$GATE_STDERR")" in
  *"$TEST_KEY"*) fail "gate stderr log leaked the key via the request path" ;;
  *) pass ;;
esac

# --- test: an upstream response with a non-identity Content-Encoding is
# refused outright (502), never decoded-and-scrubbed or passed through as-is,
# and the gate asks upstream for identity encoding in the first place --------
models_out="$d/models.out"
models_status=$(curl -s -o "$models_out" -w '%{http_code}' --max-time 5 "$GATE_URL/v1/models")
assert_eq "502" "$models_status" "a gzip-encoded upstream response is refused, not passed through"
models_body=$(cat "$models_out")
case "$models_body" in
  *models*) fail "refused response still leaked (decoded or raw) upstream body content" ;;
  *) pass ;;
esac
models_req=$(grep '"path": "/v1/models"' "$UPSTREAM_LOG" | tail -n 1)
ae_seen=$(echo "$models_req" | /usr/bin/python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
print(rec["headers"].get("Accept-Encoding", "MISSING"))
')
assert_eq "identity" "$ae_seen" "gate asks the upstream for Accept-Encoding: identity"

# --- test: the key never appears in the gate's stderr log -------------------
sleep 0.1
log_contents=$(cat "$GATE_STDERR")
case "$log_contents" in
  *"$TEST_KEY"*) fail "gate stderr log contains the key" ;;
  *) pass ;;
esac
assert_contains "$log_contents" "allow POST /v1/messages 200" "gate logs the allowed streaming request"
assert_contains "$log_contents" "deny GET / 403" "gate logs the denied GET /"
assert_contains "$log_contents" "deny POST /v1/files 403" "gate logs the denied POST /v1/files"

# --- test: missing key on stdin exits 3 (the kit's "missing key" code),
# not the generic bad-input 2 --------------------------------------------------
missing_key_dir="$d/missing-key"
mkdir -p "$missing_key_dir"
out=$(printf '' | GATE_TEST_UPSTREAM_INSECURE=1 /usr/bin/python3 "$GATE" \
  --upstream "$BASE_URL" --port-file "$missing_key_dir/port" 2>&1)
code=$?
assert_eq 3 "$code" "gate.py exits 3 when stdin has no key"

# --- test: the macOS guard runs before anything else, matching kit_require_macos
# (exit 2, "routing-kit is macOS-only", real uname faked via PATH like the
# session-start hook's test does) --------------------------------------------
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
macos_guard_dir="$d/macos-guard"
mkdir -p "$macos_guard_dir"
macos_guard_out="$macos_guard_dir/out.log"
# Run in the background and poll for exit rather than a blocking command
# substitution: on unfixed code (no guard at all) this process would just
# start serving forever, and a plain $(...) would hang the whole test run
# waiting for a stdout that never closes.
printf '%s\n' "$TEST_KEY" | PATH="$fakebin:$PATH" GATE_TEST_UPSTREAM_INSECURE=1 /usr/bin/python3 "$GATE" \
  --upstream "$BASE_URL" --port-file "$macos_guard_dir/port" >"$macos_guard_out" 2>&1 &
MACOS_GUARD_PID=$!
i=0
macos_guard_exited=1
while [ "$i" -lt 40 ]; do
  if ! kill -0 "$MACOS_GUARD_PID" 2>/dev/null; then
    macos_guard_exited=0
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
if [ "$macos_guard_exited" -eq 0 ]; then
  wait "$MACOS_GUARD_PID" 2>/dev/null
  code=$?
  assert_eq 2 "$code" "gate.py refuses on non-macOS"
else
  fail "gate.py did not exit within 4s on non-macOS (no guard, or it hung instead of refusing)"
  kill -9 "$MACOS_GUARD_PID" 2>/dev/null
fi
out=$(cat "$macos_guard_out")
assert_contains "$out" "routing-kit is macOS-only" "gate.py prints the exact macOS-only message"
if [ -e "$macos_guard_dir/port" ]; then
  fail "gate.py wrote a port file despite the non-macOS refusal"
else
  pass
fi

# --- test: a malformed upstream HTTP response (an invalid status line that
# itself contains the key) must never crash the gate into dumping a traceback
# -- and thus the key -- to stderr; the client gets a plain 502 instead -------
badstatus_dir="$d/badstatus"
mkdir -p "$badstatus_dir"
BADSTATUS_UPSTREAM="$badstatus_dir/badstatus_upstream.py"
cat > "$BADSTATUS_UPSTREAM" <<'PYEOF'
import socket
import sys

port_file = sys.argv[1]
key = sys.argv[2]

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(1)
with open(port_file, "w") as f:
    f.write(str(srv.getsockname()[1]))

conn, _ = srv.accept()
buf = b""
while b"\r\n\r\n" not in buf:
    chunk = conn.recv(4096)
    if not chunk:
        break
    buf += chunk
# An invalid status line that embeds the key -- this is what a broken (or
# adversarial) upstream might send, and it must never surface verbatim.
conn.sendall(("GARBAGE %s NOT AN HTTP STATUS LINE\r\n\r\n" % key).encode("latin-1"))
conn.close()
srv.close()
PYEOF
/usr/bin/python3 "$BADSTATUS_UPSTREAM" "$badstatus_dir/upstream_port" "$TEST_KEY" &
BADSTATUS_UPSTREAM_PID=$!
i=0
while [ ! -s "$badstatus_dir/upstream_port" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    fail "bad-status fake upstream never wrote its port file"
    break
  fi
  sleep 0.05
done
BADSTATUS_UPSTREAM_PORT=$(cat "$badstatus_dir/upstream_port")
printf '%s\n' "$TEST_KEY" | GATE_TEST_UPSTREAM_INSECURE=1 /usr/bin/python3 "$GATE" \
  --upstream "http://127.0.0.1:$BADSTATUS_UPSTREAM_PORT" --port-file "$badstatus_dir/gate_port" \
  >"$badstatus_dir/stdout.log" 2>"$badstatus_dir/stderr.log" &
BADSTATUS_GATE_PID=$!
i=0
while [ ! -s "$badstatus_dir/gate_port" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    fail "bad-status gate never wrote its port file"
    break
  fi
  sleep 0.05
done
BADSTATUS_GATE_PORT=$(cat "$badstatus_dir/gate_port")
badstatus_client_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$BADSTATUS_GATE_PORT/v1/models")
assert_eq "502" "$badstatus_client_status" "a malformed upstream response comes back to the client as a plain 502"
sleep 0.1
badstatus_log=$(cat "$badstatus_dir/stderr.log")
case "$badstatus_log" in
  *"$TEST_KEY"*) fail "gate stderr leaked the key from an unparseable upstream response" ;;
  *) pass ;;
esac
kill "$BADSTATUS_GATE_PID" 2>/dev/null
kill "$BADSTATUS_UPSTREAM_PID" 2>/dev/null
wait "$BADSTATUS_GATE_PID" 2>/dev/null
wait "$BADSTATUS_UPSTREAM_PID" 2>/dev/null

# --- test: SIGTERM makes the process exit cleanly and promptly --------------
kill -TERM "$GATE_PID"
i=0
gate_alive=1
while [ "$i" -lt 50 ]; do
  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    gate_alive=0
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
if [ "$gate_alive" -eq 0 ]; then
  pass
else
  fail "gate did not exit within 5s of SIGTERM"
  kill -9 "$GATE_PID" 2>/dev/null
fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
