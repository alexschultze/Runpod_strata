#!/usr/bin/env python3
"""Tests of strata/bench/bench_parallel.py against a fake streaming server (10 chunks per answer, 0.05 s apart)."""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = 0


def check(name, cond):
    global FAILS
    print(("  ok:   " if cond else "  FAIL: ") + name)
    FAILS += 0 if cond else 1


class Fake(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    fail = False

    def log_message(self, *a):
        pass

    def do_GET(self):
        b = json.dumps({"concurrency": {"serving": 2}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if Fake.fail:
            self.send_response(500); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        for i in range(10):
            c = ('data: {"choices":[{"delta":{"content":"x"}}]}\n\n').encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(c), c)); self.wfile.flush(); time.sleep(0.05)
        c = b'data: {"usage":{"completion_tokens":10},"choices":[]}\n\ndata: [DONE]\n\n'
        self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(c), c))


srv = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = "http://127.0.0.1:%d" % srv.server_address[1]
script = os.path.join(HERE, "..", "strata", "bench", "bench_parallel.py")


def run(*args):
    return subprocess.run([sys.executable, script, "--url", url, "--max-tokens", "10", *args], capture_output=True, text=True, timeout=120).stdout


out = run("--streams", "1,3", "--rounds", "1")
rows = {l.split()[0]: l.split() for l in out.splitlines() if l[:1].isdigit()}
check("reports the server's slots", "serves 2 request" in out)
check("one row per stream count", set(rows) == {"1", "3"})
check("N=3 total is about three times the single stream", float(rows["3"][3]) > 2 * float(rows["1"][3]))
Fake.fail = True
check("failed streams are reported, not hidden", "failed" in run("--streams", "2", "--rounds", "1"))
print("all tests passed" if not FAILS else "%d test(s) failed" % FAILS)
raise SystemExit(FAILS)
