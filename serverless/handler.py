"""Queue-basierter RunPod-Handler. Input:
  {"input": {"path": "/v1/chat/completions", "body": {...OpenAI-Request...}}}
  (path optional, Default /v1/chat/completions; body mit "stream": true -> Chunks werden gestreamt)
Strata bearbeitet eine Sequenz gleichzeitig -> concurrency 1."""
import json, os, time
import requests, runpod

BASE = "http://127.0.0.1:%s" % os.environ.get("STRATA_PORT", "8080")
H = {"Authorization": "Bearer " + os.environ["API_KEY"]} if os.environ.get("API_KEY") else {}


def wait_ready(timeout=float(os.environ.get("READY_TIMEOUT", "1800"))):
    t = time.time()
    while time.time() - t < timeout:
        try:
            r = requests.get(BASE + "/health", timeout=3)
            if r.ok and r.json().get("loaded") is not False:
                return
        except Exception:
            pass
        time.sleep(3)
    raise RuntimeError("Strata wurde nicht bereit")


def handler(job):
    inp = job["input"]
    path, body = inp.get("path", "/v1/chat/completions"), inp.get("body", inp)
    if not path.startswith("/v1/"):
        return {"error": "nur /v1/* erlaubt"}
    wait_ready()
    if not body.get("stream"):
        r = requests.post(BASE + path, json=body, headers=H, timeout=3600)
        return r.json() if r.headers.get("content-type", "").startswith("application/json") else {"error": r.text}
    with requests.post(BASE + path, json=body, headers=H, stream=True, timeout=3600) as r:
        for line in r.iter_lines():
            if line.startswith(b"data:") and line[5:].strip() != b"[DONE]":
                yield json.loads(line[5:])


runpod.serverless.start({"handler": handler, "return_aggregate_stream": True})
