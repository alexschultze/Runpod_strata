# Project Context

## Overview

Runpod template repository (structure follows runpod-workers/pod-template) that prepares running Strata, an
OpenAI/Anthropic-compatible LLM server for NVIDIA GPUs, on Runpod: first as a Pod, later as a Serverless endpoint.

## Technology Stack

- **Image**: `nvidia/cuda:13.0.0-devel-ubuntu24.04` + Python, build tools, sshd, rsync, fio, jq; Strata itself is cloned and built on the pod
- **Build/registry**: GitHub Actions (`dev.yml`) -> GHCR. Scripts: bash + fio/jq (`scripts/`). Control: `strata/runpod_ctl.py`

## Project Structure

```
.
├── Dockerfile, entry.sh, start.sh, sshd.sh, post-setup.sh, publish.sh
├── serverless/                  # proxy.py (/ping), handler.py (queue endpoint)
├── scripts/                     # check-env, storage/download benchmarks, calibrate, nvidia-smi shim
├── .github/workflows/dev.yml    # builds the image
├── strata/                      # runpod_ctl.py, bench/bench.py, build.sh, README
└── docs/                        # context.md, plan.md, handoff.md
```

## Key Facts for Strata

- API on :8080, health at `/health`; one sequence at a time. Engine compiled in the image (`/opt/strata`),
  engine in `/tmp/Strata`, data in `/tmp/Strata-data`, stored on the volume (`<volume>/strata-store`).
- 32-62 GB RAM needed; `LOW_RAM=on` maps experts from disk (`experts.bin`), so random-read speed of the volume matters.
- Host driver >= 580 (CUDA 13.0).
- Network volume for Serverless (`/runpod-volume`), pod volume for the first benchmark.
