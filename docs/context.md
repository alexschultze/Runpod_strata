# Project Context

## Overview

Runpod image for Strata 0.2 (branch strata-v2-dev), an OpenAI/Anthropic-compatible LLM server for NVIDIA GPUs (structure follows runpod-workers/pod-template),
for a Pod and for a Serverless endpoint (queue or load balancer).

## Technology Stack

- **Image**: `FROM ghcr.io/niko1221/strata:<version>-cuda13` (Strata's ready-made image with the engine) + sshd, rsync, fio, jq, a Python venv for the handler; nothing is compiled on the pod
- **Build/registry**: GitHub Actions (`dev.yml`, started by hand) -> GHCR. Scripts: bash + fio/jq (`scripts/`). Control: `strata/runpod_ctl.py`

## Project Structure

```
.
├── Dockerfile, entry.sh, start.sh, sshd.sh, hwinfo.sh, sync.sh, update-scripts.sh, volume-check.sh
├── serverless/                  # proxy.py (/ping, load balancer), handler.py (queue endpoint)
├── scripts/                     # check-env, storage/download benchmarks, calibrate, bench-parallel, nvidia-smi shim
├── tests/                       # start logic, shim, handler, benchmark client (fake Strata, no GPU)
├── .github/workflows/dev.yml    # tests, then image build
├── strata/                      # runpod_ctl.py, bench/, README
└── docs/                        # context.md, handoff.md
```

## Key Facts for Strata

- API on :8080, health at `/health`; one sequence at a time unless `STRATA_PARALLEL` (batch slots) is set.
- State in `/data` (local disk: model, pack, presets, tuning), stored on the volume (`<volume>/strata-store/v2`: `/workspace` on a Pod,
  `/runpod-volume` on Serverless). Tuning: Strata's preset, named per GPU (`docker-<gpu>-<vram>g`).
- RAM: about 48 GB or more for IQ2_XS; Strata plans from the host's RAM and warns about a pod memory limit.
- Host driver >= 580 (CUDA 13.0). Container disk 85 GB for `COPY_DATA_LOCAL=yes`.
