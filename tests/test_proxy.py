#!/usr/bin/env python3
"""Tests of serverless/proxy.py: /api_direct redirect and /ping (no Strata, no RunPod)."""
import http.client
import importlib.util
import os
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = 0


def check(name, cond):
    global FAILS
    print(("  ok:   " if cond else "  FAIL: ") + name)
    FAILS += 0 if cond else 1


os.environ["STRATA_PORT"] = "8080"
spec = importlib.util.spec_from_file_location("proxy", os.path.join(HERE, "..", "serverless", "proxy.py"))
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
srv = p.S(("127.0.0.1", 0), p.H)
threading.Thread(target=srv.serve_forever, daemon=True).start()


def get(path, method="GET"):
    c = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=10)
    c.request(method, path)
    r = c.getresponse(); r.read()
    return r.status, r.getheader("Location")


os.environ["RUNPOD_POD_ID"] = "abc123"
base = "https://abc123-8080.proxy.runpod.net"
check("/api_direct -> 307 to the worker's root", get("/api_direct") == (307, base + "/"))
check("/api_direct/ -> 307", get("/api_direct/") == (307, base + "/"))
check("path and query are kept", get("/api_direct/v1/models?x=1") == (307, base + "/v1/models?x=1"))
check("query only", get("/api_direct?a=1") == (307, base + "/?a=1"))
check("POST is redirected with 307 too (keeps method and body)", get("/api_direct/v1/chat/completions", "POST") == (307, base + "/v1/chat/completions"))
check("only this worker's host is the target", get("/api_direct//evil.example/x")[1] == base + "//evil.example/x")
check("/api_directory is not the redirect (goes to Strata, which is down here: 503)", get("/api_directory")[0] == 503)
check("/ping: 204 while Strata is not loaded", get("/ping") == (204, None))
del os.environ["RUNPOD_POD_ID"]
check("without RUNPOD_POD_ID: 503, no redirect", get("/api_direct") == (503, None))
print("all tests passed" if not FAILS else "%d test(s) failed" % FAILS)
raise SystemExit(FAILS)
