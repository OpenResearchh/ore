#!/usr/bin/env python3
"""Serve laya-flow.html and proxy System One to the local Laya runner."""
from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError, HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
HTML = ROOT / "laya-flow.html"
LAYA = "http://127.0.0.1:11435"
LAYA_TOKEN = os.environ.get("LAYA_TOKEN")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/laya-flow.html"):
            body = HTML.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/v1/models":
            self.proxy("GET", b"")
            return
        self.send_error(404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if path == "/v1/systemone":
            self.proxy("POST", raw)
            return
        self.send_error(404)

    def proxy(self, method: str, raw: bytes):
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if LAYA_TOKEN:
            headers["Authorization"] = "Bearer " + LAYA_TOKEN
        req = Request(
            LAYA + self.path.split("?", 1)[0],
            data=raw if method == "POST" else None,
            method=method,
            headers=headers,
        )
        try:
            with urlopen(req, timeout=60) as resp:
                body = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except HTTPError as exc:
            body = exc.read()
            self.send_response(exc.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body or json.dumps({"error": str(exc)}).encode())
        except URLError as exc:
            body = json.dumps({"error": f"Laya is not answering: {exc.reason}"}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    print("Open http://127.0.0.1:8765/")
    server.serve_forever()
