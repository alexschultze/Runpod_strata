#!/usr/bin/env python3
"""Misst N gleichzeitige Streams gegen einen OpenAI-kompatiblen Server (Strata): tok/s pro Stream, Summe, TTFT.
  bench_parallel.py --url http://127.0.0.1:8080 --key K [--streams 1,2,3] [--rounds 2] [--max-tokens 256]
Ablauf je N: N Streams starten gleichzeitig (verschiedene Prompts), --rounds Wiederholungen, Median. Die Summe ist
alle Tokens / (Ende des letzten Streams - erstes Token des ersten). Vergleiche N=1 mit N=2: ein Batch lohnt nur, wenn die Summe
deutlich steigt und der einzelne Stream nicht zu stark einbricht. Auch --batch / STRATA_PARALLEL / --batch-mtp werden so verglichen."""
import argparse, json, statistics as st, threading, time, urllib.request

PROMPTS = ["Erkläre kurz, wie ein Transformer funktioniert.",
           "Schreibe eine Python-Funktion, die eine Liste von Primzahlen bis n liefert, mit Erklärung.",
           "Fasse die Vor- und Nachteile von Mixture-of-Experts-Modellen zusammen.",
           "Nenne zehn europäische Hauptstädte mit je einem Satz dazu.",
           "Erkläre, wie ein Kühlschrank Wärme von innen nach außen bringt."]


def headers(a):
    h = {"Content-Type": "application/json"}
    if a.key:
        h["Authorization"] = "Bearer " + a.key
    return h


def stream_one(a, prompt, out, i):
    body = {"model": a.model, "stream": True, "max_tokens": a.max_tokens, "temperature": 0,
            "stream_options": {"include_usage": True}, "messages": [{"role": "user", "content": prompt}]}
    t0 = time.time(); first = None; chunks = 0; usage = None
    try:
        req = urllib.request.Request(a.url.rstrip("/") + "/v1/chat/completions", json.dumps(body).encode(), headers(a))
        with urllib.request.urlopen(req, timeout=a.timeout) as r:
            for line in r:
                if not line.startswith(b"data:") or b"[DONE]" in line:
                    continue
                d = json.loads(line[5:])
                if d.get("usage"):
                    usage = d["usage"]["completion_tokens"]
                ch = d.get("choices") or []
                if ch and (ch[0].get("delta", {}).get("content") or ch[0].get("delta", {}).get("reasoning_content")):
                    first = first or time.time(); chunks += 1
    except Exception as e:   # one failed stream must not hide the others
        out[i] = {"error": str(e)}; return
    end = time.time()
    out[i] = {"t0": t0, "first": first, "end": end, "n": usage or chunks}


def one_round(a, n):
    out = [None] * n
    ts = [threading.Thread(target=stream_one, args=(a, PROMPTS[i % len(PROMPTS)], out, i)) for i in range(n)]
    for t in ts: t.start()
    for t in ts: t.join()
    return out


def status(a):
    try:
        req = urllib.request.Request(a.url.rstrip("/") + "/v1/status", headers=headers(a))
        s = json.loads(urllib.request.urlopen(req, timeout=10).read())
        return (s.get("concurrency") or {}).get("serving")
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True); ap.add_argument("--key"); ap.add_argument("--model", default="default")
    ap.add_argument("--streams", default="1,2", help="comma separated stream counts, e.g. 1,2,3")
    ap.add_argument("--rounds", type=int, default=2); ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    print("server serves %s request(s) at a time (GET /v1/status concurrency.serving)" % (status(a) or "?"))
    one_round(a, 1)   # warm-up
    print("%-8s %-22s %-14s %-12s" % ("streams", "tok/s per stream", "tok/s total", "ttft (s)"))
    for n in [int(x) for x in a.streams.split(",") if x.strip()]:
        per, tot, ttft, errs = [], [], [], 0
        for _ in range(a.rounds):
            rs = one_round(a, n)
            ok = [r for r in rs if r and "error" not in r and r["first"]]
            errs += n - len(ok)
            if not ok:
                continue
            per += [r["n"] / max(r["end"] - r["first"], 1e-9) for r in ok]
            ttft += [r["first"] - r["t0"] for r in ok]
            tot.append(sum(r["n"] for r in ok) / max(max(r["end"] for r in ok) - min(r["first"] for r in ok), 1e-9))
        if per:
            print("%-8d %-22s %-14.1f %-12.2f%s" % (n, "%.1f (median)" % st.median(per), st.median(tot), st.median(ttft),
                                                    ("  (%d failed)" % errs) if errs else ""))
        else:
            print("%-8d all streams failed" % n)


if __name__ == "__main__":
    main()
