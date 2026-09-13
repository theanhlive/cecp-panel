#!/usr/bin/env python3
"""Minimal Cloudflare API stand-in for scenario.sh.

Usage: mock_cf.py PORT LOGFILE [DELAY_SECONDS]
Records method, path, Authorization header and body of every call. The default delay (1.5 s)
gives the scenario time to scan /proc/*/cmdline for leaked tokens while curl is running.

Stateful bits: the http_request_cache_settings entrypoint ruleset (GET/PUT, 10003 when it
does not exist yet). Touch /tmp/mockcf.fail-rulesets to make ruleset reads fail with an
authentication error.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]
DELAY = float(sys.argv[3]) if len(sys.argv) > 3 else 1.5
RULESET = None
NEXT_ID = [1]


class Handler(BaseHTTPRequestHandler):
    def _reply(self, obj, body=""):
        time.sleep(DELAY)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{self.command} {self.path} auth={self.headers.get('Authorization', '')}"
                    + (f" body={body}" if body else "") + "\n")
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        return raw.decode("utf-8", "replace"), (json.loads(raw) if raw else {})

    def do_GET(self):
        global RULESET
        if self.path.startswith("/zones?"):
            self._reply({"success": True, "result": [{"id": "zone123"}]})
        elif "/dns_records" in self.path:
            self._reply({"success": True, "result": []})
        elif self.path.endswith("/rulesets/phases/http_request_cache_settings/entrypoint"):
            if os.path.exists("/tmp/mockcf.fail-rulesets"):
                self._reply({"success": False, "errors": [{"code": 10000, "message": "Authentication error"}]})
            elif RULESET is None:
                self._reply({"success": False, "errors": [{"code": 10003, "message": "could not find entrypoint ruleset"}]})
            else:
                self._reply({"success": True, "result": RULESET})
        else:
            self._reply({"success": True, "result": {}})

    def do_PUT(self):
        global RULESET
        raw, data = self._body()
        if self.path.endswith("/rulesets/phases/http_request_cache_settings/entrypoint"):
            rules = []
            for r in data.get("rules", []):
                if "id" not in r:
                    r = dict(r, id=f"rule{NEXT_ID[0]}")
                    NEXT_ID[0] += 1
                rules.append(r)
            RULESET = {"id": "rs1", "phase": "http_request_cache_settings", "rules": rules}
            self._reply({"success": True, "result": RULESET}, raw)
        else:
            self._reply({"success": True, "result": data}, raw)

    def do_POST(self):
        raw, data = self._body()
        self._reply({"success": True, "result": {"name": data.get("name", "x"), "content": data.get("content", "")}}, raw)

    do_PATCH = do_POST

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
