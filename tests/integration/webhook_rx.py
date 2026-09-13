#!/usr/bin/env python3
"""Webhook receiver for scenario.sh: records headers + body of every POST as a JSON line.

Usage: webhook_rx.py PORT LOGFILE      (serve)
       webhook_rx.py check LOGFILE SECRET EVENT   exit 0 if EVENT arrived with a valid signature
       webhook_rx.py count LOGFILE EVENT          print how many EVENT deliveries arrived
"""
import hashlib
import hmac
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def entries(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                yield json.loads(line)
    except OSError:
        return


def event_of(entry):
    try:
        return json.loads(entry["body"]).get("event")
    except ValueError:
        return None


def main():
    if sys.argv[1] == "check":
        _, _, log, secret, event = sys.argv
        for e in entries(log):
            if event_of(e) != event:
                continue
            h = {k.lower(): v for k, v in e["headers"].items()}
            want = hmac.new(secret.encode(), (h["x-cecp-timestamp"] + "." + e["body"]).encode(),
                            hashlib.sha256).hexdigest()
            if hmac.compare_digest("sha256=" + want, h.get("x-cecp-signature", "")):
                return 0
        return 1
    if sys.argv[1] == "count":
        _, _, log, event = sys.argv
        print(sum(1 for e in entries(log) if event_of(e) == event))
        return 0
    port, log = int(sys.argv[1]), sys.argv[2]

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            with open(log, "a", encoding="utf-8") as f:
                f.write(json.dumps({"headers": dict(self.headers), "body": body}) + "\n")
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
