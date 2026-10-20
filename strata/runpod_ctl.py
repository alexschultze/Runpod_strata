#!/usr/bin/env python3
"""Pods und Serverless-Endpoints per RunPod-REST-API steuern (nur stdlib).
Env: RUNPOD_API_KEY (Pflicht). Zustand (IDs) liegt in .runpod_state.json.

  pod create  [--gpu "NVIDIA H100 80GB HBM3"] [--image IMG] [--volume-gb 150] [--api-key-strata K]
  pod start|stop|delete|status|url
  ep create   [--gpu ...] [--image IMG:TAG] [--network-volume ID] [--idle 60]   (nur Queue-Endpoints)
  ep adopt ID  (bestehenden Endpoint, z. B. den in der Konsole angelegten Load-Balancer, merken)
  ep up | ep down | ep status | ep delete     (down = workersMin/Max 0, Endpoint bleibt bestehen)

Load-Balancing-Endpoints lassen sich laut OpenAPI-Schema (rest.runpod.io/v1/openapi.json) nicht per REST
anlegen (kein Typ-Feld): einmalig in der Konsole erstellen (README), danach `ep adopt` + up/down.
"""
import argparse, json, os, sys, urllib.request, urllib.error

API = "https://rest.runpod.io/v1"
STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".runpod_state.json")
DEFAULT_GPU = "NVIDIA H100 80GB HBM3"  # the engine is built on the pod for whatever GPU it gets (once per GPU architecture)


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + os.environ["RUNPOD_API_KEY"],
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} {method} {path}: {e.read().decode()[:500]}")


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(s):
    json.dump(s, open(STATE, "w"), indent=1)


def env_for(a, mode):
    e = {"MODE": mode, "AUTO_START": "yes", "COPY_DATA_LOCAL": a.copy_data_local, "MODEL": a.model, "FAMILY": a.family, "CONTEXT": str(a.context)}
    if a.low_ram:   # only when given: otherwise Strata decides
        e["LOW_RAM"] = a.low_ram
    for kv in a.env:  # beliebige weitere Strata-/Runpod-Variablen: --env KEY=VALUE (wiederholbar)
        k, _, v = kv.partition("=")
        e[k] = v
    if a.api_key_strata:
        e["STRATA_API_KEY"] = a.api_key_strata
    return e


def pod(a):
    s = load()
    if a.cmd == "create":
        body = {"name": "strata", "imageName": a.image, "gpuTypeIds": [a.gpu], "gpuCount": 1,
                "containerDiskInGb": a.container_gb, "volumeInGb": a.volume_gb, "volumeMountPath": "/workspace",
                "ports": ["8080/http", "22/tcp"], "env": env_for(a, "pod"), "cloudType": "SECURE",
                "minRAMPerGPU": a.min_ram, "minVCPUPerGPU": 8, "allowedCudaVersions": ["13.0"]}
        p = call("POST", "/pods", body)
        s["pod"] = p["id"]; save(s)
        print(p["id"], "->", f"https://{p['id']}-8080.proxy.runpod.net")
        return
    pid = s.get("pod") or sys.exit("kein Pod im State")
    if a.cmd in ("start", "stop"):
        print(call("POST", f"/pods/{pid}/{a.cmd}"))
    elif a.cmd == "delete":
        call("DELETE", f"/pods/{pid}"); s.pop("pod"); save(s)
    elif a.cmd == "url":
        print(f"https://{pid}-8080.proxy.runpod.net")
    else:
        p = call("GET", f"/pods/{pid}")
        print(json.dumps({k: p.get(k) for k in ("id", "desiredStatus", "costPerHr", "gpu", "publicIp", "portMappings")}, indent=1))


def ep(a):
    s = load()
    if a.cmd == "adopt":
        s["ep"] = a.id; s.pop("tpl", None); save(s); return
    if a.cmd == "create":
        t = call("POST", "/templates", {
            "name": "strata-queue", "imageName": a.image, "isServerless": True,
            "containerDiskInGb": a.container_gb, "env": env_for(a, "queue")})
        body = {"name": "strata-queue", "templateId": t["id"], "gpuTypeIds": [a.gpu],
                "workersMin": 0, "workersMax": 1, "idleTimeout": a.idle, "scalerType": "QUEUE_DELAY",
                "scalerValue": 4, "executionTimeoutMs": 600000, "flashboot": False,
                "minCudaVersion": "13.0"}
        if a.network_volume:
            body["networkVolumeId"] = a.network_volume
        e = call("POST", "/endpoints", body)
        s["ep"], s["tpl"] = e["id"], t["id"]; save(s)
        print(e["id"], "->", f"https://api.runpod.ai/v2/{e['id']}")
        return
    eid = s.get("ep") or sys.exit("kein Endpoint im State")
    if a.cmd in ("up", "down"):
        up = a.cmd == "up"
        print(call("PATCH", f"/endpoints/{eid}", {"workersMin": 1 if up else 0, "workersMax": 1 if up else 0})
              and ("up" if up else "down"))
    elif a.cmd == "delete":
        call("PATCH", f"/endpoints/{eid}", {"workersMin": 0, "workersMax": 0})
        call("DELETE", f"/endpoints/{eid}")
        if s.get("tpl"): call("DELETE", f"/templates/{s['tpl']}")
        for k in ("ep", "tpl"): s.pop(k, None)
        save(s)
    else:
        print(json.dumps(call("GET", f"/endpoints/{eid}"), indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", default=os.environ.get("IMAGE", "ghcr.io/OWNER/strata-runpod:v1"))
    ap.add_argument("--gpu", default=DEFAULT_GPU)
    ap.add_argument("--model", default="IQ2_XS"); ap.add_argument("--context", type=int, default=32768)
    ap.add_argument("--api-key-strata", default=os.environ.get("STRATA_API_KEY"))
    ap.add_argument("--copy-data-local", default="yes", choices=["yes", "no"])
    ap.add_argument("--family", default="qwen"); ap.add_argument("--low-ram", default=None, choices=["auto", "on", "off", "resident", "mmap"], help="LOW_RAM (nur Strata 0.1 Image, in 0.2 ignoriert)")
    ap.add_argument("--env", action="append", default=[], metavar="KEY=VALUE", help="weitere Umgebungsvariable (wiederholbar)")
    ap.add_argument("--volume-gb", type=int, default=150)
    ap.add_argument("--container-gb", type=int, default=85, help="Container-Disk: Engine und Modelldaten liegen lokal unter /tmp (COPY_DATA_LOCAL=yes)")
    ap.add_argument("--min-ram", type=int, default=48, help="mindestens GB RAM pro GPU (Pod-Limit, nicht Host-RAM)")
    ap.add_argument("--network-volume"); ap.add_argument("--idle", type=int, default=60)
    sub = ap.add_subparsers(dest="kind", required=True)
    for k, f, cmds in (("pod", pod, "create start stop delete status url"),
                       ("ep", ep, "create adopt up down delete status")):
        p = sub.add_parser(k); p.add_argument("cmd", choices=cmds.split()); p.add_argument("id", nargs="?")
        p.set_defaults(f=f)
    a = ap.parse_args(); a.f(a)


if __name__ == "__main__":
    main()
