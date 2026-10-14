#!/usr/bin/env python3
"""Tests of serverless/handler.py against a fake Strata (no GPU, no RunPod)."""
import importlib.util
import json
import os
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
    seen = []

    def log_message(self, *a):
        pass

    def send_json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        Fake.seen.append(("GET", self.path, self.headers.get("Authorization")))
        self.send_json({"loaded": True} if self.path == "/health" else {"data": [{"id": "strata"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        Fake.seen.append(("POST", self.path, self.headers.get("Authorization")))
        if body.get("bad"):
            return self.send_json({"error": "nope"}, 400)
        if not body.get("stream"):
            return self.send_json({"choices": [{"message": {"content": "hi"}}]})
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        for c in ('data: {"n": 1}\n\n', 'data: {"n": 2}\n\n', "data: [DONE]\n\n"):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(c.encode()), c.encode())); self.wfile.flush(); time.sleep(0.05)
        self.wfile.write(b"0\r\n\r\n")


srv = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
os.environ["STRATA_PORT"] = str(srv.server_address[1])
os.environ["API_KEY"] = "secret"
spec = importlib.util.spec_from_file_location("handler", os.path.join(HERE, "..", "serverless", "handler.py"))
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)


def run(inp):
    return list(h.handler({"input": inp}))


h.wait_ready(10); check("wait_ready returns when /health says loaded", True)
out = run({"openai_route": "/v1/chat/completions", "openai_input": {"messages": []}})
check("openai route, POST, JSON answer", out == [{"choices": [{"message": {"content": "hi"}}]}])
out = run({"openai_route": "/v1/chat/completions", "openai_input": {"stream": True}})
text = "".join(out)
check("openai route, stream: raw SSE text", 'data: {"n": 1}' in text and "[DONE]" in text and all(isinstance(x, str) for x in out))
out = run({"openai_route": "/v1/models"})
check("openai route without input: GET /v1/models", out == [{"data": [{"id": "strata"}]}] and ("GET", "/v1/models", "Bearer secret") in Fake.seen)
out = run({"path": "/v1/chat/completions", "body": {"messages": []}})
check("own format, JSON answer", out[0].get("choices"))
out = run({"body": {"stream": True}})
check("own format, stream: parsed chunks", out == [{"n": 1}, {"n": 2}])
out = run({"openai_route": "/v1/chat/completions", "openai_input": {"bad": 1}})
check("HTTP error -> error object", out[0]["error"]["type"] == "worker_error" and "400" in out[0]["error"]["message"])
out = run({"openai_route": "/admin", "openai_input": {}})
check("paths outside /v1/ are refused", out[0]["error"]["type"] == "invalid_request")
check("the Strata key is sent on /v1 requests", all(a == "Bearer secret" for _, p, a in Fake.seen if p.startswith("/v1/")))
print("all tests passed" if not FAILS else "%d test(s) failed" % FAILS)
raise SystemExit(FAILS)
