"""Route Anthropic Messages API calls to Anthropic or to ollama, per model.

Claude Code 2.1.223 has exactly one ANTHROPIC_BASE_URL. Its only alternates
are provider-specific (ANTHROPIC_BEDROCK_BASE_URL, ANTHROPIC_VERTEX_BASE_URL,
ANTHROPIC_FOUNDRY_BASE_URL), so there is no supported way to say "the main
loop goes to Anthropic, these subagents go to the local 35B". This process is
that missing piece: it speaks the same API on loopback and dispatches on the
request body's "model" field.

Three things here are load-bearing rather than stylistic:

  default-remote   Only models named in ROUTER_LOCAL_MODELS go to ollama.
                   Everything else, including paths this process does not
                   recognise, goes to Anthropic — Claude Code also talks to
                   its base URL for OAuth refresh and policy limits, and a
                   subscription session breaks if those are swallowed.

  never buffer     Every chunk is written and flushed as it arrives.
                   Accumulating a response would break incremental token
                   display, and would push auto mode's safety classifier
                   past its own ~60s budget even when the upstream answered
                   in time.

  loopback only    This process forwards a live Anthropic credential. It
                   refuses to bind anything but a loopback address, and it
                   never logs a header: the default BaseHTTPRequestHandler
                   access log is silenced for that reason, not for noise.

Configured entirely by environment, so nix/router.nix can hand it values
from the same settings prelude every other script in this flake uses:

  ROUTER_ADDR              host:port to listen on (loopback only)
  ROUTER_LOCAL_API         ollama base URL
  ROUTER_REMOTE_API        Anthropic base URL
  ROUTER_LOCAL_MODELS      "name:num_ctx,name:num_ctx" — the routing table
  ROUTER_LOCAL_TIMEOUT_S   cold prefill on the 35B is minutes, not seconds
  ROUTER_REMOTE_TIMEOUT_S
  ROUTER_USAGE_LOG         JSONL, one line per request; read by local-ai-usage
"""

import http.client
import json
import os
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _env(name, default):
    value = os.environ.get(name, "").strip()
    return value or default


def _routing_table(spec):
    """Parse "name:num_ctx,..." into {model: window}.

    rpartition, not partition: ollama model names may carry a tag, as in
    "qwen3:1.7b", so the window is after the *last* colon.
    """
    table = {}
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        name, _, window = item.rpartition(":")
        if not name:
            name, window = item, "0"
        try:
            table[name.strip()] = int(window)
        except ValueError:
            table[name.strip()] = 0
    return table


def _default_usage_log():
    """Same path cache_dir() in nix/common.sh produces.

    Computed here rather than passed in by the wrapper so that running
    local-ai-router by hand still accounts for its traffic; hybrid-agent
    overrides it explicitly.
    """
    base = os.environ.get("XDG_CACHE_HOME", "").strip()
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".cache")
    directory = os.path.join(base, "local-ai-agent")
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        return ""
    return os.path.join(directory, "router-usage.jsonl")


ADDR = _env("ROUTER_ADDR", "127.0.0.1:8787")
LOCAL_API = _env("ROUTER_LOCAL_API", "http://127.0.0.1:11434")
REMOTE_API = _env("ROUTER_REMOTE_API", "https://api.anthropic.com")
LOCAL_MODELS = _routing_table(os.environ.get("ROUTER_LOCAL_MODELS", ""))
LOCAL_TIMEOUT = float(_env("ROUTER_LOCAL_TIMEOUT_S", "1800"))
REMOTE_TIMEOUT = float(_env("ROUTER_REMOTE_TIMEOUT_S", "600"))
USAGE_LOG = _env("ROUTER_USAGE_LOG", _default_usage_log())

LOOPBACK = frozenset({"127.0.0.1", "::1", "localhost", "ip6-localhost"})

# Hop-by-hop headers, plus two deliberate extras:
#   content-length    recomputed, since the body is read in full
#   accept-encoding   stripped so upstreams answer in identity encoding. The
#                     usage tee has to read the SSE stream as text, and a
#                     gzipped body would be opaque to it.
_DROP_REQUEST = frozenset({
    "host", "content-length", "connection", "keep-alive",
    "transfer-encoding", "te", "trailer", "upgrade",
    "proxy-authorization", "proxy-authenticate", "accept-encoding",
})

_DROP_RESPONSE = frozenset({
    "content-length", "connection", "keep-alive",
    "transfer-encoding", "te", "trailer", "upgrade",
})

_IO_LOCK = threading.Lock()


def _log(message):
    with _IO_LOCK:
        sys.stderr.write("router: %s\n" % message)
        sys.stderr.flush()


class Usage(object):
    """Token counts scraped off a response without delaying it.

    Streaming responses carry usage in two places: message_start has the
    input and cache figures, message_delta the running output count. A
    non-streaming response carries one usage object in the whole body.

    Every method swallows its own errors. Accounting is a convenience; it is
    never allowed to break forwarding.
    """

    def __init__(self, content_type):
        self.sse = "event-stream" in (content_type or "")
        self.counts = {"input": 0, "cache_read": 0, "cache_write": 0,
                       "output": 0}
        self._buf = b""

    def feed(self, chunk):
        try:
            self._buf += chunk
            if self.sse:
                while b"\n" in self._buf:
                    line, self._buf = self._buf.split(b"\n", 1)
                    if line.startswith(b"data:"):
                        self._event(line[5:].strip())
                # A single SSE line should never reach this size; if one
                # does, drop it rather than grow without bound.
                if len(self._buf) > 1 << 16:
                    self._buf = b""
            elif len(self._buf) > 1 << 20:
                self._buf = b""
                self.sse = True  # stop accumulating a body this large
        except (ValueError, TypeError, MemoryError):
            self._buf = b""

    def finish(self):
        if not self.sse and self._buf:
            self._event(self._buf)
        self._buf = b""
        return self.counts

    def _event(self, raw):
        try:
            event = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(event, dict):
            return
        usage = event.get("usage")
        if not isinstance(usage, dict):
            message = event.get("message")
            usage = message.get("usage") if isinstance(message, dict) else None
        if not isinstance(usage, dict):
            return
        # max(), not +=: message_delta restates the running output total on
        # every event rather than reporting an increment.
        for key, field in (
            ("input", "input_tokens"),
            ("cache_read", "cache_read_input_tokens"),
            ("cache_write", "cache_creation_input_tokens"),
            ("output", "output_tokens"),
        ):
            try:
                value = int(usage.get(field) or 0)
            except (ValueError, TypeError):
                continue
            if value > self.counts[key]:
                self.counts[key] = value


def _model_of(body):
    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        return ""
    if not isinstance(payload, dict):
        return ""
    model = payload.get("model")
    return model if isinstance(model, str) else ""


def _connect(base, timeout):
    parts = urllib.parse.urlsplit(base)
    if parts.scheme == "https":
        conn = http.client.HTTPSConnection(parts.netloc, timeout=timeout)
    else:
        conn = http.client.HTTPConnection(parts.netloc, timeout=timeout)
    return conn, parts.path.rstrip("/")


class Router(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "local-ai-router"

    def log_message(self, fmt, *args):
        """Silence the access log — it would echo credential-bearing requests.

        This process sees a live Anthropic token. All of its logging goes
        through _log, which records the model, upstream and token counts and
        never touches a header.
        """

    def do_GET(self):  # noqa: N802 — BaseHTTPRequestHandler's naming
        if self.path.split("?")[0] == "/healthz":
            self._json(200, {
                "ok": True,
                "local": sorted(LOCAL_MODELS),
                "local_api": LOCAL_API,
                "remote_api": REMOTE_API,
            })
            return
        self._proxy()

    def do_POST(self):  # noqa: N802
        self._proxy()

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self):
        try:
            length = int(self.headers.get("content-length") or 0)
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b""

        model = _model_of(body)
        local = model in LOCAL_MODELS
        if local:
            base, timeout, upstream = LOCAL_API, LOCAL_TIMEOUT, "ollama"
            self._guard_window(model, body)
        else:
            base, timeout, upstream = REMOTE_API, REMOTE_TIMEOUT, "anthropic"

        conn, prefix = _connect(base, timeout)
        headers = {
            key: value for key, value in self.headers.items()
            if key.lower() not in _DROP_REQUEST
        }
        if body:
            headers["Content-Length"] = str(len(body))

        started = time.monotonic()
        try:
            conn.request(self.command, prefix + self.path, body=body,
                         headers=headers)
            response = conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            conn.close()
            _log("%s %s unreachable: %s" % (upstream, model or "-", exc))
            self._json(502, {"type": "error", "error": {
                "type": "api_error",
                "message": "local-ai-router: %s upstream unreachable: %s" % (
                    upstream, exc),
            }})
            return

        usage = self._stream(response, conn)
        elapsed = int((time.monotonic() - started) * 1000)
        self._record(upstream, model, response.status, usage, elapsed)

    def _guard_window(self, model, body):
        """Make failure mode 1 visible for local subagents.

        In hybrid mode CLAUDE_CODE_MAX_CONTEXT_TOKENS has to describe the
        *Claude* window, so Claude Code cannot keep a local subagent inside
        the 35B's. Ollama would then truncate the prompt and say so only in
        its own log, which is exactly the silent failure this project exists
        to avoid. The usable prompt is about num_ctx/2, since ollama reserves
        the remainder for the response (4096 -> limit 2050).
        """
        window = LOCAL_MODELS.get(model) or 0
        if window <= 0:
            return
        estimate = len(body) // 4
        usable = window // 2
        if estimate > usable:
            _log("WARNING: %s prompt is ~%d tokens but only ~%d are usable "
                 "at num_ctx=%d — ollama will truncate it silently; scope "
                 "the subagent's reads more tightly or raise AGENT_NUM_CTX"
                 % (model, estimate, usable, window))

    def _stream(self, response, conn):
        usage = Usage(response.getheader("content-type", ""))
        self.send_response(response.status)
        for key, value in response.getheaders():
            if key.lower() not in _DROP_RESPONSE:
                self.send_header(key, value)

        declared = response.getheader("content-length")
        chunked = declared is None
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", declared)
        self.end_headers()

        try:
            while True:
                chunk = response.read(4096)
                if not chunk:
                    break
                if chunked:
                    self.wfile.write(b"%x\r\n" % len(chunk))
                    self.wfile.write(chunk)
                    self.wfile.write(b"\r\n")
                else:
                    self.wfile.write(chunk)
                # Flush per chunk. Buffering here would defeat the whole
                # point of streaming; see the module docstring.
                self.wfile.flush()
                usage.feed(chunk)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (OSError, http.client.HTTPException) as exc:
            # The client hanging up mid-stream is routine: it is what auto
            # mode does when a classifier call passes its budget.
            _log("stream ended early: %s" % exc)
        finally:
            conn.close()
        return usage.finish()

    def _record(self, upstream, model, status, counts, elapsed_ms):
        entry = {
            "ts": int(time.time()),
            "upstream": upstream,
            "model": model,
            "status": status,
            "ms": elapsed_ms,
            "in": counts["input"],
            "cache_read": counts["cache_read"],
            "cache_write": counts["cache_write"],
            "out": counts["output"],
        }
        _log("%-9s %-28s %3d %6dms in=%d cache=%d out=%d"
             % (upstream, model or "-", status, elapsed_ms, counts["input"],
                counts["cache_read"], counts["output"]))
        if not USAGE_LOG:
            return
        with _IO_LOCK:
            try:
                with open(USAGE_LOG, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(entry) + "\n")
            except OSError as exc:
                sys.stderr.write("router: usage log: %s\n" % exc)


def main():
    host, _, port = ADDR.rpartition(":")
    host = host.strip("[]") or "127.0.0.1"
    if host not in LOOPBACK:
        _log("refusing to bind %s — this process forwards a live Anthropic "
             "credential and has no authentication of its own, so it must "
             "stay on loopback" % host)
        return 2
    try:
        bind_port = int(port)
    except ValueError:
        _log("ROUTER_ADDR=%s is not host:port" % ADDR)
        return 2

    if not LOCAL_MODELS:
        # Not fatal: a router with an empty table is a plain pass-through to
        # Anthropic, which is a legitimate way to measure a baseline.
        _log("warning: ROUTER_LOCAL_MODELS is empty — everything goes remote")

    server = ThreadingHTTPServer((host, bind_port), Router)
    server.daemon_threads = True
    _log("listening on %s:%d" % (host, bind_port))
    _log("local  %s -> %s" % (sorted(LOCAL_MODELS), LOCAL_API))
    _log("remote everything else -> %s" % REMOTE_API)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _log("stopping")
    return 0


if __name__ == "__main__":
    sys.exit(main())
