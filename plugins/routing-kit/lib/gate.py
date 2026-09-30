#!/usr/bin/python3
"""gate.py -- single-upstream auth relay (the jail's only way out).

Usage:
    python3 gate.py --upstream BASE_URL --port-file FILE

The provider key is read from stdin (one line), never from argv or the
environment. The gate binds 127.0.0.1:0, writes the chosen port to
FILE, and forwards only:

    POST /v1/messages
    POST /v1/messages/count_tokens
    GET  /v1/models        (query strings allowed)

to BASE_URL + path over HTTPS, adding "Authorization: Bearer <key>"
itself. Every other method or path -- including CONNECT -- gets 403.

Python 3.9 stdlib only (http.server, http.client, ssl). See
plugins/routing-kit/lib for the rest of the kit; this file has no
routing-kit-specific imports so it can be dropped into a jail alone.
"""

import argparse
import os
import signal
import socket
import ssl
import subprocess
import sys
import threading
from http.client import HTTPConnection, HTTPException, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ALLOWED_ROUTES = {
    ("POST", "/v1/messages"),
    ("POST", "/v1/messages/count_tokens"),
    ("GET", "/v1/models"),
}

# Headers forwarded from the client to upstream, verbatim, in addition to
# the Authorization/Host the gate computes itself. Everything else the
# client sends (including any Authorization or x-api-key it tried to set)
# is dropped.
FORWARD_REQUEST_HEADERS = {
    "content-type",
    "anthropic-version",
    "anthropic-beta",
    "content-length",
}

# Headers never mirrored back from the upstream response: the gate always
# re-frames the body as its own chunked stream, so any framing headers
# from upstream would be stale or wrong.
DROP_RESPONSE_HEADERS = {
    "connection",
    "transfer-encoding",
    "content-length",
    "keep-alive",
    "upgrade",
    # The gate's own send_response() already emits Server/Date; forwarding
    # the upstream's copies too would just duplicate the header lines.
    "server",
    "date",
}

READ_CHUNK = 65536
REDACTED = b"[REDACTED]"

# Ask the real upstream for uncompressed bodies only. The scrubber works on
# raw bytes; it cannot see a key inside a compressed body, so decoding
# would have to happen before scrubbing anyway. Refusing anything else is
# simpler and strictly safer than adding a decompression codepath (with its
# own risks, e.g. a compression bomb) just to scrub it afterwards.
REQUIRED_ACCEPT_ENCODING = "identity"


class Scrubber:
    """Streaming search-and-replace of a secret across arbitrary chunk
    boundaries. Only holds back bytes whose tail could actually be the
    start of the secret (checked via a KMP-style longest-prefix-suffix
    scan), instead of unconditionally buffering len(secret) - 1 bytes on
    every call -- with a ~100-char real API key, unconditional buffering
    would stall every SSE event smaller than the key itself, which is most
    of them, defeating streaming entirely."""

    def __init__(self, secret):
        self.secret = secret
        self.buf = b""

    def _longest_partial_match(self, buf):
        # Longest suffix of buf that equals a (non-full) prefix of secret.
        # A full match was already replaced above, so this only needs to
        # check up to len(secret) - 1.
        max_check = min(len(buf), len(self.secret) - 1)
        for length in range(max_check, 0, -1):
            if buf[-length:] == self.secret[:length]:
                return length
        return 0

    def feed(self, data):
        self.buf += data
        if not self.secret:
            out, self.buf = self.buf, b""
            return out
        self.buf = self.buf.replace(self.secret, REDACTED)
        if len(self.secret) <= 1:
            out, self.buf = self.buf, b""
            return out
        keep = self._longest_partial_match(self.buf)
        if keep == 0:
            out, self.buf = self.buf, b""
            return out
        emit_len = len(self.buf) - keep
        out = self.buf[:emit_len]
        self.buf = self.buf[emit_len:]
        return out

    def flush(self):
        if self.secret:
            self.buf = self.buf.replace(self.secret, REDACTED)
        out, self.buf = self.buf, b""
        return out

    def scrub_text(self, text):
        if not self.secret:
            return text
        try:
            return text.encode("latin-1").replace(self.secret, REDACTED).decode(
                "latin-1"
            )
        except (UnicodeDecodeError, UnicodeEncodeError):
            return text


def _write_chunk(wfile, data):
    if not data:
        return
    wfile.write(("%x\r\n" % len(data)).encode("ascii"))
    wfile.write(data)
    wfile.write(b"\r\n")
    wfile.flush()


class GateHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Set by main() before serve_forever().
    upstream_scheme = None
    upstream_host = None
    upstream_port = None
    upstream_base_path = ""
    upstream_host_header = ""
    provider_key = b""

    def setup(self):
        super().setup()
        # SSE responses are written as several small chunks per event
        # (hex length, data, CRLF). Without TCP_NODELAY, Nagle's algorithm
        # plus the client's delayed ACKs can stall each of those writes by
        # ~200ms, which defeats the whole point of streaming.
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        # Suppress BaseHTTPRequestHandler's default access log; we emit
        # our own single line per request instead (see _log).
        pass

    def _log(self, decision, status):
        # Only the path, never the query string: a query is entirely
        # client-controlled and could carry the key (or anything else) in
        # plain sight, e.g. "/v1/models?echo=<key>".
        try:
            log_path = urlsplit(self.path).path
        except ValueError:
            log_path = "(unparseable)"
        # The path is client-controlled too ("GET /<key>"): scrub it, and fail
        # closed if the scrubber can't be sure.
        scrubbed = Scrubber(self.provider_key).scrub_text(log_path)
        if self.provider_key and self.provider_key in scrubbed.encode("latin-1", "replace"):
            scrubbed = "(redacted)"
        log_path = scrubbed
        sys.stderr.write("%s %s %s %s\n" % (decision, self.command, log_path, status))
        sys.stderr.flush()

    def _deny(self, status=403):
        body = b"forbidden"
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self._log("deny", status)

    def _read_request_body(self):
        length = self.headers.get("Content-Length")
        if length is None:
            return b""
        try:
            n = int(length)
        except ValueError:
            return b""
        if n <= 0:
            return b""
        return self.rfile.read(n)

    def _connect_upstream(self):
        if self.upstream_scheme == "https":
            context = ssl.create_default_context()
            conn = HTTPSConnection(
                self.upstream_host, self.upstream_port, context=context, timeout=60
            )
        else:
            conn = HTTPConnection(self.upstream_host, self.upstream_port, timeout=60)
        conn.connect()
        try:
            conn.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        return conn

    def _dispatch(self):
        # Only origin-form request-targets are allowed ("/path?query").
        # Absolute-form ("GET http://elsewhere/v1/models HTTP/1.1"),
        # authority-form (what CONNECT sends) and asterisk-form ("*") all
        # get refused here, before the path is even inspected -- otherwise
        # an absolute-form target's *parsed path* could match an allowed
        # route while the *literal text forwarded upstream* is something
        # else entirely.
        if not self.path.startswith("/"):
            self._deny(403)
            return
        parts = urlsplit(self.path)
        if parts.scheme or parts.netloc:
            self._deny(403)
            return
        route = (self.command, parts.path)
        if route not in ALLOWED_ROUTES:
            self._deny(403)
            return

        body = self._read_request_body()

        outbound_headers = {}
        for name in self.headers.keys():
            lname = name.lower()
            if lname in FORWARD_REQUEST_HEADERS:
                outbound_headers[name] = self.headers.get(name)
        outbound_headers["Authorization"] = "Bearer " + self.provider_key.decode(
            "latin-1"
        )
        outbound_headers["Host"] = self.upstream_host_header
        outbound_headers["Accept-Encoding"] = REQUIRED_ACCEPT_ENCODING

        upstream_path = self.upstream_base_path + self.path

        scrubber = Scrubber(self.provider_key)

        conn = None
        try:
            conn = self._connect_upstream()
            conn.request(self.command, upstream_path, body=body, headers=outbound_headers)
            resp = conn.getresponse()
        except Exception:
            # Covers connection failures (OSError) as well as a malformed
            # upstream response (http.client.HTTPException, e.g. an invalid
            # status line) and anything else unforeseen. The exception text
            # is never used anywhere -- for HTTPException in particular it
            # can literally be the raw bytes an upstream sent, which might
            # itself contain the key (a broken or adversarial upstream can
            # put arbitrary bytes there).
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
            self._respond_fixed(502, b"upstream error")
            self._log("error", 502)
            return

        content_encoding = resp.getheader("Content-Encoding")
        if content_encoding and content_encoding.strip().lower() != REQUIRED_ACCEPT_ENCODING:
            # The scrubber only ever sees raw bytes; it cannot find a key
            # inside a compressed body. Refuse outright rather than pass a
            # possibly key-bearing compressed body through unscrubbed.
            conn.close()
            self._respond_fixed(502, b"upstream response encoding not supported")
            self._log("error", 502)
            return

        self.close_connection = True
        try:
            self.send_response(resp.status)
            for name, value in resp.getheaders():
                if name.lower() in DROP_RESPONSE_HEADERS:
                    continue
                # A key in a header name can't be redacted into a valid
                # token, so drop that header; scrub the key out of values.
                if scrubber.scrub_text(name) != name:
                    continue
                self.send_header(name, scrubber.scrub_text(value))
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                data = resp.read1(READ_CHUNK)
                if not data:
                    break
                out = scrubber.feed(data)
                _write_chunk(self.wfile, out)
            tail = scrubber.flush()
            _write_chunk(self.wfile, tail)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            # Same rationale as above: never let an exception's text (which
            # could contain upstream-controlled, possibly key-bearing data)
            # propagate to the default traceback logger. The status line is
            # already sent by this point, so there is nothing left to do but
            # stop cleanly.
            pass
        finally:
            conn.close()

        self._log("allow", resp.status)

    def _respond_fixed(self, status, msg):
        # A response body that is always the same fixed text for a given
        # status -- used for every error path where upstream-controlled
        # content must never reach the client or the log.
        self.close_connection = True
        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(msg)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    # Every method the client might send funnels through the same
    # allow-list check, including CONNECT (which otherwise BaseHTTPRequestHandler
    # would answer with 501 Not Implemented instead of our 403).
    do_GET = _dispatch
    do_POST = _dispatch
    do_PUT = _dispatch
    do_DELETE = _dispatch
    do_PATCH = _dispatch
    do_HEAD = _dispatch
    do_OPTIONS = _dispatch
    do_CONNECT = _dispatch

    def __getattr__(self, name):
        # Catch-all for any method not explicitly listed above (TRACE, or
        # anything else a client sends): BaseHTTPRequestHandler's own
        # dispatch checks hasattr(self, "do_" + command) and falls back to
        # 501 Not Implemented when it's missing. Since hasattr() consults
        # __getattr__ too, this makes every possible method resolve to the
        # same _dispatch -> allow-list check -> 403, instead of 501.
        if name.startswith("do_"):
            return self._dispatch
        raise AttributeError(name)


class GateServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # Defense in depth: GateHandler's own dispatch already catches
        # every exception it can reach around the upstream call, but if
        # something still escapes, the stdlib default here is to print a
        # full traceback -- which, for an HTTPException raised while
        # parsing a malformed upstream response, can literally be upstream-
        # controlled bytes (see the comment in _dispatch's except clause).
        # Log one fixed line instead of ever repeating that risk.
        sys.stderr.write("error - internal 500\n")
        sys.stderr.flush()


def _require_macos():
    # This file has no routing-kit-specific imports (it can be dropped into
    # a jail alone), so it can't just source kit-common's kit_require_macos.
    # Shell out to the real `uname` the same way that function does, rather
    # than e.g. platform.system() (which reads a syscall result directly
    # and can't be overridden via PATH) -- that keeps this guard testable
    # the same way every other entry point's guard is.
    try:
        out = subprocess.run(
            ["uname"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    if out != "Darwin":
        sys.stderr.write("routing-kit is macOS-only\n")
        sys.exit(2)


def _read_key_from_stdin():
    line = sys.stdin.readline()
    try:
        sys.stdin.close()
    except OSError:
        pass
    return line.rstrip("\n").rstrip("\r").encode("latin-1")


def main(argv):
    _require_macos()
    parser = argparse.ArgumentParser(prog="gate.py")
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args(argv)

    parsed = urlsplit(args.upstream)
    if parsed.scheme == "http":
        if os.environ.get("GATE_TEST_UPSTREAM_INSECURE") != "1":
            sys.stderr.write(
                "gate.py: http:// upstream requires GATE_TEST_UPSTREAM_INSECURE=1\n"
            )
            return 2
        default_port = 80
    elif parsed.scheme == "https":
        default_port = 443
    else:
        sys.stderr.write("gate.py: --upstream must be http:// or https://\n")
        return 2

    key = _read_key_from_stdin()
    if not key:
        sys.stderr.write("gate.py: no key on stdin\n")
        return 3

    GateHandler.upstream_scheme = parsed.scheme
    GateHandler.upstream_host = parsed.hostname
    GateHandler.upstream_port = parsed.port or default_port
    GateHandler.upstream_base_path = parsed.path.rstrip("/") if parsed.path not in ("", "/") else ""
    GateHandler.upstream_host_header = parsed.netloc
    GateHandler.provider_key = key

    server = GateServer(("127.0.0.1", 0), GateHandler)
    server.daemon_threads = True

    port = server.server_address[1]
    tmp_port_file = args.port_file + ".tmp"
    with open(tmp_port_file, "w") as f:
        f.write(str(port))
    os.replace(tmp_port_file, args.port_file)

    def _on_sigterm(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _on_sigterm)

    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
