# Strata on Runpod

> **Branch `strata-v2-dev`: Strata 0.2 integration, work in progress.** The image is built on Strata's own ready-made image (engine included, nothing is
> compiled on the pod). `v0.2.26` was started on Runpod and works (start time below); speed, Serverless modes and other GPU types are not measured yet. The stable line for Strata 0.1 is the
> branch `claude/strata-runpod-deploy-zegtn6` (images `v0.1.<n>`); images of this branch are tagged `v0.2.<n>`.

One Docker image that runs [Strata](https://github.com/Niko1221/Strata) (an OpenAI-compatible server for Qwen3.8-Flash-Next) on a Runpod
**Pod** or **Serverless** endpoint. The engine is built on the machine the first time, archived on your network volume, and restored in
minutes afterwards. Details for tinkerers: [README_DETAILS.md](README_DETAILS.md).

```
ghcr.io/alexschultze/strata-runpod:<tag>        # the tag of the latest successful build in GitHub Actions
```

## Key points

1. **Strata brings its own engine.** The image is built `FROM ghcr.io/niko1221/strata:<version>-cuda13` (build argument `STRATA_IMAGE`, default
   `latest-cuda13`; pin a version such as `0.2.1-cuda13` for a reproducible build). No compile on the pod: the 3-4 minutes and the engine archives of the 0.1 line are gone.
2. **Serverless: use a network volume** in the same data center. Model, presets and tuning are kept there (`<volume>/strata-store/v2`) and copied to the local disk
   at start, so a new worker does not download or tune again.
3. **Tuning is per kind of card:** `TUNE=quick` runs Strata's quick tuning (about 20 minutes, once) for a preset that is named after the GPU
   (`docker-<gpu>-<vram>g`), so every card type is tuned once and keeps its result. Without it nothing is tuned.
4. **Not measured yet on this branch:** speed, the Docker options Strata recommends (`--ulimit memlock`, `--shm-size`) on Runpod, and which
   GPU architectures the engine in the image covers (check with `strata components engine` in the container; the start log prints it).

## What you need

| | |
|---|---|
| **GPU** | NVIDIA with at least ~22 GB VRAM (tested: RTX PRO 4500 Blackwell 32 GB, RTX 3090 24 GB, L4 22 GB) |
| **RAM** | about 48 GB or more for the recommended model (IQ2_XS). Strata plans from the host's RAM, so it warns about a pod memory limit |
| **Local disk (container disk)** | **85 GB** for the recommended model. The model data (73 GiB) is copied there for speed |
| **Network volume** | **in the same data center as the pod or endpoint.** It stores the model, presets and tuning (`<volume>/strata-store/v2`), so a restart or a new worker does not download or tune again |
| **API key** | a secret of your own (`API_KEY`). Without it nothing starts |

## Quick start

**Pod:** use the image, set the container disk to 85 GB, attach your network volume at `/workspace`, set the variables below, start. The
pod waits; run `/opt/runpod/start.sh` in `tmux` (or set `AUTO_START=yes` to start by itself). The API is on port 8080
(`https://<pod id>-8080.proxy.runpod.net`).

**Serverless:** create a queue-based endpoint with the image, a network volume in the same data center and an 85 GB container disk. Workers start
Strata automatically (`MODE=queue` is the default there; set it yourself if your worker does not). Call `/runsync` or `/run`, or Runpod's OpenAI route (`https://api.runpod.ai/v2/<endpoint id>/openai/v1/...`).

**The first request after idle waits for a worker to start** (image pull, copying the data to the local disk, loading the model; start about 180 s with the model on the network volume; other cases not measured). Set client timeouts to 10-15 minutes and prefer `/run` + `/status/<id>` over `/runsync`. In LiteLLM: `timeout: 900`, `stream_timeout: 900`, `num_retries: 0`.

## The variables you will actually use

| Variable | Default | What it does |
|---|---|---|
| `API_KEY` | – (**required**) | the key clients send as `Authorization: Bearer ...` (Strata's own name). Put it in Runpod Secrets, never in the image or repo. Use 16+ characters |
| `MODEL` | `IQ2_XS` | the model size: `IQ2_XS` (recommended), `Q2_0`, `IQ3_XXS`, `IQ3_S`, ... (Strata's list); empty would let Strata choose |
| `FAMILY` | unset | `qwen`, `coder`, ... only when a size exists in several families |
| `CONTEXT` | `32768` | context length in tokens (Strata alone would take the largest that fits; ours is smaller to keep VRAM for the experts) |
| `COPY_DATA_LOCAL` | `yes` | `yes`: copy the store on the volume to the local disk at start (needs about 85 GB container disk for IQ2_XS). `no`: the model files stay on the volume (slower to run) |
| `TUNE` | `skip` | Strata's own: `skip` (no tuning), `quick` (up to about 20 minutes, once per preset) or `thorough`. `RETUNE=1` tunes again |
| `PARALLEL` | unset | Strata's own: requests answered together (1-8). Leave unset unless you measured a gain |
| `STRATA_SET` | unset | advanced engine settings, space separated `key=value` (Strata's `--set`), for example `prefill=65536` |
| `PRESET` | `docker-<gpu>-<vram>g` | Strata's preset name; the default gives every card type its own preset and tuning |
| `AUTO_START` | `no` | Pods only: `yes` starts Strata without you running `start.sh` |
| `SSH_PUBLIC_KEY` | – | your public key for SSH into the pod (a Runpod `PUBLIC_KEY` also works) |
| `SCRIPTS_REF` | unset | a git branch or tag of this repo: the scripts are pulled from it at start instead of the ones in the image |
| `MODE` | `pod` (Serverless: `queue`) | `pod`, `queue` (Runpod queue handler) or `lb` (load-balancer proxy on `LB_PORT`, default 8000) |

Our former names `STRATA_API_KEY`, `STRATA_PARALLEL`, `STRATA_CALIBRATE` are gone (the start reports them; use `API_KEY`, `PARALLEL`, `TUNE`).
Gone from the 0.1 line (ignored with a warning): `LOW_RAM`, `REINSTALL`, `RESIDENT_BUDGET_GIB`, `STRATA_REF`, `STRATA_REPO`, `STRATA_ENGINE_ARGS`, `POOL_WORKERS`.
Strata 0.2 plans RAM and the engine itself.

All other variables are listed in [README_DETAILS.md](README_DETAILS.md).

## How long does a start take

| Case | Time |
|---|---|
| Worker starts, model and presets on the network volume in the pod's data center (`v0.2.26`) | **about 180 s** (reported by the project owner; GPU, mode and copy setting not recorded) |
| Very first start, no model data on the volume | the model download (about 70 GB, not measured) plus Strata's preparation of the pack |
| `TUNE=quick` on a card type nobody has tuned | + up to about 20 minutes (Strata's quick tuning), once per card type |
| Image not yet cached on the host | + pull of the image (Strata's engine image is about 640 MB to download, ours adds SSH, Python and tools; not measured) |

At start the log shows an **info block** (GPU, VRAM, CPU, RAM, Runpod ids, URL), the **volume** and the **engine** of the image, then a progress line every 10 s while copying.

## Measured performance (for reference)

Decode speed (Strata, IQ2_XS, `scripts/bench-local.sh`, which cycles through fixed prompts, so single runs vary with the prompt):

| Setup | Median | Spread of single runs |
|---|---|---|
| `v0.2.26`, model read from the network volume (`COPY_DATA_LOCAL=no`), 15 runs | 128.5 tok/s | 76-206 tok/s |
| `v0.2.27`, local copy (`COPY_DATA_LOCAL=yes`), 2 x 5 runs | 155 and 158 tok/s | 148-199 tok/s |

Both on the project owner's pod (RTX PRO 4500 Blackwell 32 GB in the first row; GPU of the second row, `CONTEXT` and `PARALLEL` not recorded). The prompts that
dropped to 76-116 tok/s from the network volume ran at 150-158 tok/s locally. Whether Strata read the model from the local disk in the second row was not
checked (start log line `settings file(s) pointed into a volume store` or the open files of the Strata process). Earlier, on the 0.1 line: about 150 tok/s on that card
with a calibration, about 60 tok/s on an L4 (22 GB). Strata's docs say batch slots (`PARALLEL`) can slow a single request down where the experts do not fit in VRAM; we measured no gain.

Storage (fio, 1 MiB blocks unless noted; measured on pods by the project owner):

| | seq. write | seq. read | random 4 KiB, queue depth 1 | random 128 KiB, depth 16 x4 | 300 small files |
|---|---|---|---|---|---|
| **Network volume in the pod's data center** (`/workspace`, MooseFS) | 989 MiB/s | 1.4-1.5 GiB/s (may include cache) | 2 MiB/s (533 IOPS) | 604 MiB/s | 8.1 s |
| **Global network volume** (geesefs) | 130-169 MiB/s | about 60 MiB/s (4 GiB test file) | 7.8 MiB/s (3722 IOPS) | – | 1.1 s |
| **Local disk** (container disk) | about 4000 MB/s (reported by the project owner; read or write and test details not recorded, rerun `/app/scripts/test-local-storage.sh` for the full table) | | | | |

Notes: later geesefs read results of 4-13 GiB/s were **cache hits** and are not valid. Copying the model with `rsync` ran at about 300 MB/s.
A short rule: use the volume in the pod's data center; the global one is five to six times slower to write and much slower to read.
Test your own volume with `/app/scripts/test-network-storage.sh [dir]` and the model speed with `/app/scripts/bench-local.sh` or
`/app/scripts/bench-parallel.sh`.

## What it costs

At 1 $/hour and 150 tok/s the cost per million output tokens is about **3.70 $ at 50% utilisation** (1.85 $ at 100%). Serverless bills the
4-minute start and the idle timeout too, so rare requests cost more per token.

## Good to know

- **Security:** Strata is reachable on the worker's/pod's public Runpod proxy URL; the API key is the only protection. Never run without one.
- **One request at a time** is Strata's default; others wait in its queue. The prompt cache reuses the start of a repeated prompt.
- **Serverless job input** `{"input": {"path": "/api_direct"}}` returns the worker's own URL (`https://<id>-8080.proxy.runpod.net/`, for the website). It
  keeps nothing alive; the worker still stops after the endpoint's idle timeout.
- **A new GPU type** on the same volume: it gets its own preset (`docker-<gpu>-<vram>g`), so with `TUNE=quick` its first start runs Strata's quick tuning once
  and keeps the result. Whether the engine in the image supports the card: the start log prints `strata components engine`.
- **Strata reads the host's RAM,** not the pod's limit, when it plans (its entrypoint warns about a memory limit). `LOW_RAM` no longer exists in 0.2.
- **Docker options Strata recommends** (`--ulimit memlock=-1:-1`, `--shm-size 2g`, `--stop-timeout 120`) cannot always be set on Runpod: untested there.
- **What goes back to the volume:** `/data` is synced to the store once the model is loaded and once more at shutdown (SIGTERM, within the time Runpod gives). Runtime files of a running Strata (`state/strata/runtime`, `procs`, `*.lock`), the key file and logs are left out. Whether a preset is tuned: `/opt/strata/terminal/bin/strata launch --list-presets`.
- **Debugging:** SSH in (`SSH_PUBLIC_KEY`), logs are in `<volume>/strata-store/v2/logs/` (`sync.log`) and in `/data/install` (Strata's logs).
