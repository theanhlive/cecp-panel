#!/usr/bin/env python3
"""Minimal Cloudflare API stand-in for scenario.sh.

Usage: mock_cf.py PORT LOGFILE
Records method, path and Authorization header of every call; replies slowly so the
scenario has time to scan /proc/*/cmdline for leaked tokens while curl is running.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def _reply(self, obj):
        time.sleep(1.5)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{self.command} {self.path} auth={self.headers.get('Authorization', '')}\n")
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/zones?"):
            self._reply({"success": True, "result": [{"id": "zone123"}]})
        elif "/dns_records" in self.path:
            self._reply({"success": True, "result": []})
        else:
            self._reply({"success": True, "result": {}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length) or b"{}")
        self._reply({"success": True, "result": {"name": data.get("name", "x"), "content": data.get("content", "")}})

    do_PUT = do_POST
    do_PATCH = do_POST

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
