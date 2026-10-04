#!/usr/bin/env python3
"""Loopback System One server for a saved Laya checkpoint.

Binds 127.0.0.1 only. Speech never leaves this Mac.
Prints LAYA_READY on stdout once /v1/models will answer.
"""
from __future__ import annotations

import argparse
import json
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading


def load_agent(model_dir: Path):
    parent = model_dir.resolve().parent
    sys.path.insert(0, str(parent))
    from rl_agent_api import RLAgent

    device = None
    try:
        import torch
        if torch.backends.mps.is_available():
            device = "mps"
    except Exception:
        device = None
    return RLAgent(str(model_dir), device=device)


class Handler(BaseHTTPRequestHandler):
    agent = None
    model_id = "laya:en"
    infer_lock = threading.Lock()

    def log_message(self, format, *args):
        sys.stderr.write("laya-serve: " + (format % args) + "\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send(self, status: int, body: dict):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self._cors()
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/v1/models":
            self._send(200, {"object": "list", "data": [{"id": self.model_id}]})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if path == "/api/pull":
            self._send(200, {"status": "ok", "model": self.model_id})
            return
        if path != "/v1/systemone":
            self._send(404, {"error": "not found"})
            return
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
            state = body.get("state") or {}
            questions = body.get("questions") or {}
            with self.infer_lock:
                result = self.agent.system_one(state, questions)
            self._send(200, result)
        except BrokenPipeError:
            return
        except Exception as exc:
            traceback.print_exc()
            try:
                self._send(500, {"error": str(exc)})
            except BrokenPipeError:
                return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11435)
    args = parser.parse_args()
    model_dir = Path(args.model_dir)
    if not (model_dir / "model.safetensors").is_file():
        sys.stderr.write("laya-serve: missing model.safetensors in %s\n" % model_dir)
        sys.exit(2)
    Handler.agent = load_agent(model_dir)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    sys.stdout.write("LAYA_READY\n")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
