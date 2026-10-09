#!/usr/bin/env python3
"""Small HTTP service for the demo chart.

APP_NAME and VERSION come from the environment. When the chart mounts the
ConfigMap at CONFIG_DIR, each request re-reads those files so a live
ConfigMap patch shows up on GET / without a process restart.
"""

import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _read_mounted(key: str) -> str | None:
    config_dir = os.environ.get("CONFIG_DIR", "").strip()
    if not config_dir:
        return None
    path = os.path.join(config_dir, key)
    try:
        with open(path, encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        return None
    return value or None


def setting(key: str) -> str:
    """Prefer the mounted ConfigMap file, then the environment variable."""
    mounted = _read_mounted(key)
    if mounted is not None:
        return mounted
    return os.environ.get(key, "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler name
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._send(200, b'{"status":"ok"}\n')
            return
        if path == "/":
            payload = {
                "app": setting("APP_NAME"),
                "version": setting("VERSION"),
                "pod": socket.gethostname(),
            }
            body = (json.dumps(payload, separators=(", ", ": ")) + "\n").encode()
            self._send(200, body)
            return
        self._send(404, b'{"error":"not found"}\n')

    def _send(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on {port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
