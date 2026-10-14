# Strata on Runpod

One Docker image that runs [Strata](https://github.com/Niko1221/Strata) (an OpenAI-compatible server for Qwen3.8-Flash-Next) on a Runpod
**Pod** or **Serverless** endpoint. The engine is built on the machine the first time, archived on your network volume, and restored in
minutes afterwards. Details for tinkerers: [README_DETAILS.md](README_DETAILS.md).

```
ghcr.io/alexschultze/strata-runpod:<tag>        # the tag of the latest successful build in GitHub Actions
```

## Key points

1. **Serverless: use a network volume (strongly recommended), in the same data center, not the global volume.** This image keeps the compiled
   engine and the calibration on the volume (engine archive per GPU architecture and CPU, Strata's calibration per hardware). A worker on
   hardware that was seen before restores both instead of compiling and calibrating again. Without a volume every cold start repeats all of it.
2. **The first start on new hardware compiles the engine and, with `STRATA_CALIBRATE=yes`, calibrates: expect startup times of up to 15-20 minutes**
   (the project owner's figure; compiling takes 3-4 minutes, and Strata's documentation gives 15-30 minutes for the calibration alone, so allow 30 minutes or
   more to be safe). Set timeouts and idle limits accordingly, and start such a worker once by hand before real traffic arrives. Without calibration
   (`STRATA_CALIBRATE=no`, the default) only the compile applies.
3. **The fastest start** (engine compiled and calibrated, network volume in the same data center, not the global one): **about 90-150 seconds** (the
   project owner's figure; an earlier run that included copying the model to the local disk took 3.5 minutes).

## What you need

| | |
|---|---|
| **GPU** | NVIDIA with at least ~22 GB VRAM (tested: RTX PRO 4500 Blackwell 32 GB, RTX 3090 24 GB, L4 22 GB) |
| **RAM** | about 48 GB or more for the recommended model (IQ2_XS); below that set `LOW_RAM` |
| **Local disk (container disk)** | **85 GB** for the recommended model. The model data (73 GiB) is copied there for speed |
| **Network volume** | **in the same data center as the pod or endpoint.** It stores the engine archive and the model files, so a restart or a new worker does not rebuild or download anything |
| **API key** | a secret of your own (`STRATA_API_KEY`). Without it nothing starts |

## Quick start

**Pod:** use the image, set the container disk to 85 GB, attach your network volume at `/workspace`, set the variables below, start. The
pod waits; run `/opt/runpod/start.sh` in `tmux` (or set `AUTO_START=yes` to start by itself). The API is on port 8080
(`https://<pod id>-8080.proxy.runpod.net`).

**Serverless:** create a queue-based endpoint with the image, a network volume in the same data center and an 85 GB container disk. Workers start
Strata automatically (`MODE=queue` is the default there; set it yourself if your worker does not). Call `/runsync` or `/run`, or Runpod's OpenAI route (`https://api.runpod.ai/v2/<endpoint id>/openai/v1/...`).

**The first request after idle waits for a worker to start**: about 90-150 seconds at best, 3.5-4 minutes when the model is copied locally, and 15-20 minutes
on hardware nobody has run before (see "How long does a start take"). Set client timeouts to 10-15 minutes (more for new hardware) and prefer
`/run` + `/status/<id>` over `/runsync`. In LiteLLM: `timeout: 900`, `stream_timeout: 900`, `num_retries: 0`.

## The variables you will actually use

| Variable | Default | What it does |
|---|---|---|
| `STRATA_API_KEY` | – (**required**) | the key clients send as `Authorization: Bearer ...`. Put it in Runpod Secrets, never in the image or repo |
| `MODEL` | `IQ2_XS` | the quantisation: `IQ2_XS` (recommended), `Q2_0`, `IQ3_XXS`, `IQ3_S` (qwen); `IQ1_M` (coder); `UD-IQ4_XS`, `UD-Q4_K_XL` (unsloth) |
| `FAMILY` | `qwen` | `qwen`, `coder` or `unsloth` |
| `CONTEXT` | `32768` | context length in tokens (more context needs more VRAM and RAM) |
| `COPY_DATA_LOCAL` | `yes` | `yes`: copy the model from the volume to the local disk at start (fast to run, needs the 85 GB). `no`: use it on the volume (no copy, but slower to run) |
| `STRATA_CALIBRATE` | `no` | `no`: never calibrate. `yes`: calibrate (15-30 min) only when none exists for this GPU/CPU. `force`: always. Strata keeps one calibration per hardware on the volume and applies it automatically |
| `STRATA_PARALLEL` | unset (1) | number of requests decoded together. Leave unset unless you measured a gain (it can slow a single request down) |
| `LOW_RAM` | unset (Strata decides) | `resident`, `mmap`, `on`, `off`: only when the pod has much less RAM than the host reports |
| `AUTO_START` | `no` | Pods only: `yes` starts Strata without you running `start.sh` |
| `SSH_PUBLIC_KEY` | – | your public key for SSH into the pod (a Runpod `PUBLIC_KEY` also works) |
| `STRATA_REF` | `latest` | Strata version: `latest` release, a tag such as `v0.1.44.1`, a branch or `HEAD` |
| `STRATA_REPO` | `Niko1221/Strata` | where Strata is cloned from (`owner/repo` or a git URL, for a fork) |
| `SCRIPTS_REF` | unset | a git branch or tag of this repo: the scripts are pulled from it at start instead of the ones in the image (no rebuild for script changes) |
| `MODE` | `pod` (Serverless: `queue`) | `pod`, `queue` (Runpod queue handler) or `lb` (load-balancer proxy) |

All other variables are listed in [README_DETAILS.md](README_DETAILS.md).

## How long does a start take

| Case | Time |
|---|---|
| **Fastest:** engine compiled and calibrated, network volume in the same data center (not global) | **about 90-150 seconds** (project owner's figure) |
| Normal start with the model copied from the volume to the local disk (`COPY_DATA_LOCAL=yes`) | about 3.5 minutes (measured earlier) |
| **First start on new hardware:** compile the engine (once per GPU architecture and CPU) and, with `STRATA_CALIBRATE=yes`, calibrate | **up to 15-20 minutes** by the owner's figure (compiling 3-4 minutes; Strata's documentation gives 15-30 minutes for the calibration alone) |
| Very first start, no model data on the volume | + download of about 70 GB (not measured) |
| Image not yet cached on the host | + pull of the image (about 3.8 GiB compressed; not measured) |

At start the log shows an **info block** (GPU, VRAM, CPU, RAM, Runpod ids), then a progress line every 10 s while copying.

## Measured performance (for reference)

Decode speed (Strata, IQ2_XS): **about 150 tok/s** on an RTX PRO 4500 Blackwell (32 GB) with a calibration for that card
(`--pcie-frac 1.00 --spec-min-p 0.70`, measured 163 tok/s by the calibration). **About 60 tok/s** on an L4 (22 GB) running with the settings
calibrated for the Blackwell card: the cause is probably the smaller card and those settings, not confirmed yet (batch slots were set to 1 in that run).
Strata's docs say batch slots (`STRATA_PARALLEL`) can slow a single request down where the experts do not fit in VRAM; we measured no gain.

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
- **A new GPU type** on the same volume: the engine is built once per GPU architecture and CPU, and calibration is per hardware. With
  `STRATA_CALIBRATE=yes` the first start on new hardware calibrates by itself.
- **Strata reads the host's RAM,** not the pod's limit, when it sets itself up. The start warns if the limit looks too small for the model; then set `LOW_RAM`.
- **Debugging:** SSH in (`SSH_PUBLIC_KEY`), logs are in `/workspace/strata-store/logs/` and the engine log is linked there.
