#!/usr/bin/env python3
"""Tests of tools/redirect/strata.php with PHP's built-in server and a fake Runpod API (skipped when php or its curl extension is missing)."""
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = 0


def check(name, cond):
    global FAILS
    print(("  ok:   " if cond else "  FAIL: ") + name)
    FAILS += 0 if cond else 1


def have_php():
    if not shutil.which("php"):
        return False
    return subprocess.run(["php", "-r", "exit(function_exists('curl_init') ? 0 : 1);"]).returncode == 0


if not have_php():
    print("  skipped: php with the curl extension is not installed")
    sys.exit(0)

STATE = {"status_calls": 0, "answer": "ok", "auth": []}


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        STATE["auth"].append(self.headers.get("Authorization"))
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        STATE["posted"] = body
        self.send({"id": "job-1", "status": "IN_QUEUE"})

    def do_GET(self):
        STATE["auth"].append(self.headers.get("Authorization"))
        STATE["status_calls"] += 1
        if STATE["answer"] == "failed":
            return self.send({"id": "job-1", "status": "FAILED"})
        if STATE["status_calls"] < 2:
            return self.send({"id": "job-1", "status": "IN_QUEUE"})
        url = "https://wk123-8080.proxy.runpod.net/" if STATE["answer"] == "ok" else "https://evil.example/"
        self.send({"id": "job-1", "status": "COMPLETED", "output": [{"url": url, "worker_id": "wk123"}]})


fake = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=fake.serve_forever, daemon=True).start()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
env = dict(os.environ, RUNPOD_API_KEY="rp-secret", RUNPOD_ENDPOINT_ID="ep1", ACCESS_TOKEN="tok-123",
           RUNPOD_API_BASE="http://127.0.0.1:%d/v2" % fake.server_address[1])
php = subprocess.Popen(["php", "-S", "127.0.0.1:%d" % port, "-t", os.path.join(HERE, "..", "tools", "redirect")], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close(); break
        except OSError:
            time.sleep(0.1)

    def get(path):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
        c.request("GET", path)
        r = c.getresponse(); body = r.read().decode()
        return r.status, r.getheader("Location"), body

    code, _, _ = get("/strata.php")
    check("no token: 403", code == 403)
    code, _, _ = get("/strata.php?t=wrong")
    check("wrong token: 403", code == 403)
    check("no Runpod call without the token", not STATE["auth"])

    code, _, body = get("/strata.php?t=tok-123")
    check("start: a job {path: /api_direct} is queued", code == 200 and STATE["posted"] == {"input": {"path": "/api_direct"}})
    check("the page reloads itself with the job id", 'http-equiv="refresh"' in body and "job=job-1" in body)
    check("the Runpod key is sent to Runpod only, never to the browser", set(STATE["auth"]) == {"Bearer rp-secret"} and "rp-secret" not in body)

    code, loc, body = get("/strata.php?t=tok-123&job=job-1&since=%d" % int(time.time()))
    check("job still queued: status page, no redirect", code == 200 and loc is None and "IN_QUEUE" in body)
    code, loc, _ = get("/strata.php?t=tok-123&job=job-1")
    check("job completed: 302 to the worker's URL", code == 302 and loc == "https://wk123-8080.proxy.runpod.net/")

    STATE["answer"] = "evil"; STATE["status_calls"] = 5
    code, loc, _ = get("/strata.php?t=tok-123&job=job-1")
    check("a URL outside proxy.runpod.net is never followed", code == 502 and loc is None)
    STATE["answer"] = "failed"
    code, loc, body = get("/strata.php?t=tok-123&job=job-1")
    check("failed job: message and a retry link", code == 502 and "FAILED" in body and "Try again" in body)
    code, _, _ = get("/strata.php?t=tok-123&job=../../x")
    check("a bad job id is refused", code == 400)
finally:
    php.terminate()
print("all tests passed" if not FAILS else "%d test(s) failed" % FAILS)
raise SystemExit(FAILS)
