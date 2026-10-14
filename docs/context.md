# Project Context

## Overview

Runpod image for Strata, an OpenAI/Anthropic-compatible LLM server for NVIDIA GPUs (structure follows runpod-workers/pod-template),
for a Pod and for a Serverless endpoint (queue or load balancer).

## Technology Stack

- **Image**: `nvidia/cuda:13.0.0-devel-ubuntu24.04` + Python, build tools, sshd, rsync, zstd, fio, jq; Strata itself is cloned and its engine built on
  the machine, once per GPU architecture, CPU and Strata version
- **Build/registry**: GitHub Actions (`dev.yml`, started by hand) -> GHCR. Scripts: bash + fio/jq (`scripts/`). Control: `strata/runpod_ctl.py`

## Project Structure

```
.
├── Dockerfile, entry.sh, start.sh, sshd.sh, hwinfo.sh, post-setup.sh, publish.sh, update-scripts.sh, volume-check.sh
├── serverless/                  # proxy.py (/ping, load balancer), handler.py (queue endpoint)
├── scripts/                     # check-env, storage/download benchmarks, calibrate, bench-parallel, nvidia-smi shim
├── tests/                       # start logic, shim, handler, benchmark client (fake Strata, no GPU)
├── .github/workflows/dev.yml    # tests, then image build
├── strata/                      # runpod_ctl.py, bench/, README
└── docs/                        # context.md, handoff.md
```

## Key Facts for Strata

- API on :8080, health at `/health`; one sequence at a time unless `STRATA_PARALLEL` (batch slots) is set.
- Engine in `/tmp/Strata`, data in `/tmp/Strata-data`, both stored on the volume (`<volume>/strata-store`: `/workspace` on a Pod,
  `/runpod-volume` on Serverless). Calibration: Strata's own `settings.json` on the volume, one entry per hardware.
- RAM: about 48 GB or more for IQ2_XS; Strata's setup reads the host's RAM, so `LOW_RAM` is yours to set when the pod limit is small.
- Host driver >= 580 (CUDA 13.0). Container disk 85 GB for `COPY_DATA_LOCAL=yes`.
