#!/usr/bin/env python3
"""Misst TTFT und Decode-tok/s gegen einen OpenAI-kompatiblen Server (Strata oder vLLM).
  bench.py --url https://<pod>-8080.proxy.runpod.net --key K --model NAME [--n 5] [--max-tokens 512]
Zählt Tokens aus usage (stream_options.include_usage); Fallback: Chunk-Anzahl."""
import argparse, json, statistics as st, time, urllib.request

PROMPTS = ["Erkläre kurz, wie ein Transformer funktioniert.",
           "Schreibe eine Python-Funktion, die eine Liste von Primzahlen bis n liefert, mit Erklärung.",
           "Fasse die Vor- und Nachteile von Mixture-of-Experts-Modellen zusammen."]


def run(a, prompt):
    body = {"model": a.model, "stream": True, "max_tokens": a.max_tokens, "temperature": 0,
            "stream_options": {"include_usage": True},
            "messages": [{"role": "user", "content": prompt}]}
    h = {"Content-Type": "application/json"}
    if a.key: h["Authorization"] = "Bearer " + a.key
    t0 = time.time(); first = None; chunks = 0; usage = None
    with urllib.request.urlopen(urllib.request.Request(a.url.rstrip("/") + "/v1/chat/completions",
                                json.dumps(body).encode(), h), timeout=600) as r:
        for line in r:
            if not line.startswith(b"data:") or b"[DONE]" in line: continue
            d = json.loads(line[5:])
            if d.get("usage"): usage = d["usage"]["completion_tokens"]
            ch = d.get("choices") or []
            if ch and (ch[0].get("delta", {}).get("content") or ch[0].get("delta", {}).get("reasoning_content")):
                first = first or time.time(); chunks += 1
    end = time.time(); n = usage or chunks
    return (first - t0) if first else None, n / max(end - (first or t0), 1e-9), n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True); ap.add_argument("--key"); ap.add_argument("--model", default="default")
    ap.add_argument("--n", type=int, default=5); ap.add_argument("--max-tokens", type=int, default=512)
    a = ap.parse_args()
    run(a, "Hallo")  # Warmup
    rs = [run(a, PROMPTS[i % len(PROMPTS)]) for i in range(a.n)]
    for t, v, n in rs: print(f"ttft={t:.2f}s  decode={v:.1f} tok/s  tokens={n}")
    print(f"MEDIAN ttft={st.median(r[0] for r in rs):.2f}s decode={st.median(r[1] for r in rs):.1f} tok/s")


if __name__ == "__main__":
    main()
