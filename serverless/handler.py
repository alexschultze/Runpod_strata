"""Queue-based RunPod handler for Strata (MODE=queue). Strata handles one sequence at a time -> concurrency 1 (the SDK default).

Accepted job inputs:
  RunPod's OpenAI route (https://api.runpod.ai/v2/<endpoint>/openai/v1/...), like runpod-workers/worker-vllm:
    {"openai_route": "/v1/chat/completions", "openai_input": {...OpenAI request...}}   -> POST; "stream": true yields the raw SSE text
    {"openai_route": "/v1/models"}                                                      -> GET
  our own format (/run, /runsync):
    {"path": "/v1/chat/completions", "body": {...}}   (path optional); "stream": true yields the parsed chunks
Only /v1/* is forwarded. The worker takes no jobs before Strata reports loaded (/health), so the queue only gets a worker that can answer."""
import codecs
import json
import os
import sys
import time

import requests

BASE = "http://127.0.0.1:%s" % os.environ.get("STRATA_PORT", "8080")
H = {"Authorization": "Bearer " + os.environ["API_KEY"]} if os.environ.get("API_KEY") else {}
DEFAULT_ROUTE = "/v1/chat/completions"


def wait_ready(timeout=float(os.environ.get("READY_TIMEOUT", "3600"))):
    t = time.time()
    while time.time() - t < timeout:
        try:
            r = requests.get(BASE + "/health", timeout=3)
            if r.ok and r.json().get("loaded") is not False:
                return
        except Exception:
            pass
        time.sleep(3)
    raise RuntimeError("Strata did not become ready within %ds" % timeout)


def error(msg, kind="worker_error"):
    return {"error": {"message": msg, "type": kind, "code": None}}


def parse(inp):
    """(path, method, body, raw_stream) of a job input."""
    if "openai_input" in inp:
        return inp.get("openai_route") or DEFAULT_ROUTE, "POST", inp["openai_input"], True
    if "openai_route" in inp:
        return inp["openai_route"], "GET", None, True
    return inp.get("path", DEFAULT_ROUTE), "POST", inp.get("body", inp), False


def handler(job):
    path, method, body, raw = parse(job.get("input") or {})
    if not isinstance(path, str) or not path.startswith("/v1/"):
        yield error("only /v1/* is allowed", "invalid_request")
        return
    stream = isinstance(body, dict) and body.get("stream") is True
    try:
        with requests.request(method, BASE + path, json=body, headers=H, stream=stream, timeout=3600) as r:
            if r.status_code >= 400:
                yield error("Strata returned HTTP %d: %s" % (r.status_code, r.text[:500]))
            elif not stream:
                ctype = r.headers.get("content-type", "")
                yield r.json() if ctype.startswith("application/json") else error(r.text[:500])
            elif raw:   # the OpenAI route: the SSE text as it comes
                dec = codecs.getincrementaldecoder("utf-8")("replace")
                for chunk in r.iter_content(chunk_size=None):
                    text = dec.decode(chunk)
                    if text:
                        yield text
            else:
                for line in r.iter_lines():
                    if line.startswith(b"data:") and line[5:].strip() != b"[DONE]":
                        yield json.loads(line[5:])
    except requests.RequestException as e:
        yield error("request to Strata failed: %s" % e)


if __name__ == "__main__":
    import runpod
    try:
        wait_ready()
    except RuntimeError as e:
        print("handler.py:", e, file=sys.stderr)
        sys.exit(1)
    print("handler.py: Strata is ready, taking jobs", flush=True)
    runpod.serverless.start({"handler": handler, "return_aggregate_stream": True})
