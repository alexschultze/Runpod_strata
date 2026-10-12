# Strata auf RunPod

Strata = https://github.com/Niko1221/Strata (OpenAI-/Anthropic-API auf :8080, `/health`, 1 Sequenz gleichzeitig).

| Datei | Zweck |
|---|---|
| `strata/build.sh`, `.github/workflows/dev.yml` | Strata-Image (CUDA-Architektur Standard `120`, siehe Workflow-Eingabe) bauen + pushen, plus dünne RunPod-Schicht (`Dockerfile`, `start.sh`, `serverless/` im Repo-Root) |
| `start.sh` (Repo-Root) | `MODE=pod` (Strata pur), `lb` (Proxy + `/ping`), `queue` (runpod-Handler) |
| `runpod_ctl.py` | Pod / Endpoint per REST-API erstellen, starten, stoppen, löschen |
| `bench/bench.py` | TTFT + Decode-tok/s gegen Strata oder vLLM |

## 0. Image
```
IMAGE=ghcr.io/<user>/strata-runpod:v0.1.1 strata/build.sh   # oder Workflow "Build and Push Strata Image" in GitHub Actions (Standard)
```
Image-Paket in GHCR auf *public* stellen (oder Registry-Credentials in RunPod hinterlegen).
Host-Treiber ≥ 580 (CUDA 13) nötig: `runpod_ctl.py` setzt `allowedCudaVersions: ["13.0"]`.

## 1. Pod-Test + Benchmark
```
export RUNPOD_API_KEY=... STRATA_API_KEY=$(openssl rand -hex 16) IMAGE=ghcr.io/<user>/strata-runpod:v1
strata/runpod_ctl.py pod create          # H100, Volume 150 GB nach /data, Port 8080/http, MODEL=IQ2_XS, LOW_RAM=on
strata/runpod_ctl.py pod url             # erster Start: ~70 GB Download, dann Modell laden (Minuten)
curl $(strata/runpod_ctl.py pod url)/health
python3 strata/bench/bench.py --url $(strata/runpod_ctl.py pod url) --key $STRATA_API_KEY --model default
```
Vergleich vLLM: gleiche GPU, RunPod-Template `vllm/vllm-openai` mit Qwen-27B (gleiche Quantisierungs-Klasse
wählen, z. B. AWQ/FP8, sonst ist der Vergleich unfair), dann derselbe `bench.py`-Aufruf mit `--model <HF-Name>`.
Ergebnisse (tok/s, TTFT, €/h) hier eintragen: _noch nicht gemessen – das braucht einen echten Pod._

Hinweis: mit `API_KEY` ist Strata's Host-Header-Check (DNS-Rebinding) aus; ohne Key liefert der RunPod-Proxy 403.

## 2. Serverless (nach docs.runpod.io: serverless/quickstart, workers/deploy, load-balancing/*)
Image mit festem Tag (nicht `:latest`) und `--platform linux/amd64` bauen (`build.sh` tut das), in eine Registry pushen.

- **Load-Balancing-Endpoint (Konsole, einmalig)** – per REST-API nicht anlegbar (das OpenAPI-Schema hat kein Typ-Feld):
  Serverless → New Endpoint → *Import from Docker Registry* → Image `...:v1` → Name → **Endpoint Type: Load Balancer** →
  mind. eine GPU (H100/H200 80 GB) → Network Volume (gleiche Region) → Env-Variablen setzen:
  `MODE=lb`, `PORT=8000`, `PORT_HEALTH=8001`, `API_KEY=<geheim>`, `MODEL=IQ2_XS`, `LOW_RAM=on`
  und unter *Expose HTTP Ports* `8000` und `8001` eintragen. Danach `strata/runpod_ctl.py ep adopt <ENDPOINT_ID>`.
  `proxy.py` beantwortet `/ping` (Port 8001) mit 204 während des Ladens, 200 wenn bereit; alles andere reicht er gestreamt an Strata weiter.
  Aufruf: `https://<ID>.api.runpod.ai/v1/chat/completions`, Header `Authorization: Bearer <RUNPOD_API_KEY>`.
  Grenzen laut Doku: 2 min Wartezeit ohne Worker (`no workers available` → mit Retry auf `/ping` arbeiten), 5,5 min pro Request, 30 MB Payload.
  Ein Cold Start dauert länger als 2 min, der erste Request scheitert also typischerweise.
- **Queue-Endpoint (per API)**: `strata/runpod_ctl.py --network-volume <ID> ep create` (legt Template + Endpoint an, `minCudaVersion 13.0`).
  Input `{"input":{"body":{"messages":[...],"max_tokens":256}}}` (`path` optional), Aufruf über `/run`, `/runsync`, `/stream`. Für lange Generierungen und garantierte Ausführung besser als LB.
- **Network Volume ist Pflicht**: `start.sh` nutzt `/runpod-volume/strata`, sonst lädt jeder Cold Start 70 GB neu. Auch mit Volume dauert ein Cold Start Minuten.
- Strata ist single-sequence: `workersMax` = max. parallele Anfragen.

## 3. Start/Stop
```
strata/runpod_ctl.py pod stop | start | delete | status
strata/runpod_ctl.py ep down      # workersMin/Max = 0 (keine Kosten); ep up = 1/1; ep delete räumt auf
```
Gestoppte Pods behalten das Volume (Speicherkosten laufen weiter); `delete` löscht es.

## Ungeprüft
Nichts lief gegen RunPod oder eine GPU. Lokal getestet: Syntax, Proxy-Streaming und `/ping` gegen einen Fake-Upstream.
Gegen `https://rest.runpod.io/v1/openapi.json` geprüft: Felder von `/pods`, `/templates`, `/endpoints` und die Methoden (PATCH für Updates).
Offen: Der Default von `PORT_HEALTH` ist in der Doku widersprüchlich (Overview: = PORT, Troubleshooting: abweichender Port), deshalb ist er hier explizit gesetzt.
Auf H100/H200 muss das Image mit sm_90 gebaut sein, sonst startet die Engine nicht.
