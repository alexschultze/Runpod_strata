# Strata on Runpod

Runpod image for [Strata](https://github.com/Niko1221/Strata) (OpenAI-/Anthropic-compatible LLM server, API on :8080, `/health`).
Layout follows [runpod-workers/pod-template](https://github.com/runpod-workers/pod-template). Plan: [`docs/plan.md`](docs/plan.md).

## How it works

One image (`ghcr.io/<owner>/strata-runpod:v0.1.<run>`, built by `.github/workflows/dev.yml`, base `nvidia/cuda:13.0.0-devel-ubuntu24.04`).
The network volume is slow for small files and random reads (measured: geesefs 8 MiB/s, MooseFS 15 MiB/s at 4 KiB random), so **engine
and data are installed and run under `/tmp`** (local disk); the volume is only the store.

`start.sh` does, in this order:
1. **Engine.** Computes a key `sm<GPU arch>-<CPU flags hash>-<Strata tag>` (for example `sm86-aeb253d3-v0.1.43.1`; for a branch or HEAD `sm86-aeb253d3-head-<commit>`). If `<store>/app-<key>.tar.zst` exists it is unpacked to
   `/tmp/Strata` (about 0.5 GB). Otherwise it clones Strata, creates the Python environment, and Strata's `setup.py` builds the engine
   (3-4 minutes measured on a 128-core host; longer with fewer CPUs).
2. **Data** (`models/`, `packs/` with `experts.bin`, `mtp/`, `config/`) in `/tmp/Strata-data`:
   - `COPY_DATA_LOCAL=yes` (default): copied from the store to `/tmp/Strata-data` once per pod (needs a container disk of ~150 GB);
   - `COPY_DATA_LOCAL=no`: stay on the volume, `/tmp/Strata-data/{models,packs,mtp}` are links into the store (slow random reads).
   The config paths are always `/tmp/Strata-data/...`, so both modes use the same config.
3. **First setup** (nothing in the store): Strata downloads and packs into `/tmp`; afterwards `post-setup.sh` archives the engine and
   `publish.sh` pushes the data to the store (background, `<store>/logs/publish.log`). Later pods and workers only restore.
4. **Start** Strata from `/tmp` (`MODE` pod | lb | queue).

The store is `<volume>/strata-store` (volume: `/runpod-volume`, else `/workspace` if a volume is mounted there):
`app-<key>.tar.zst` (zstd-compressed, the Strata folder is thousands of small files), `data/` (mirror of `/tmp/Strata-data`, `data/.complete` marks a finished push), `logs/`, `xdg/` (Strata's `settings.json`
incl. calibrations). A different CPU, GPU architecture or Strata version gives a different key and a rebuild; `app-<key>.json` next to the archive names version, tag and commit; the newest 3 archives per GPU and CPU are kept (the engine is compiled for
the CPU's instruction sets and the GPU architecture it was built on).

`entry.sh` (entry point) starts sshd and then waits; **nothing starts automatically** unless `AUTO_START=yes` (always for `MODE=lb|queue`).
Run it by hand, in tmux so it stays in the foreground:

```bash
tmux new -s strata
STRATA_STRATA_API_KEY=<secret> MODEL=IQ2_XS /opt/runpod/start.sh
```

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `STRATA_API_KEY` | - (required) | API key for Strata (`API_KEY`, Strata's own name, works as an alias). Without it `start.sh` stops before Strata (Strata's rule: never expose the server without a key); sshd keeps running. Recorded in the config on the first start, later changes need `REINSTALL=1`. Use a Runpod Secret |
| `FAMILY`, `MODEL` | `qwen`, `IQ2_XS` | Strata's setup choices. qwen: `Q2_0`, `IQ2_XS`, `IQ3_XXS`, `IQ3_S`; `coder`: `IQ1_M`; `unsloth`: `UD-IQ4_XS`, `UD-Q4_K_XL` |
| `CONTEXT` | `32768` | context length |
| `LOW_RAM` | unset (Strata decides, `auto`) | only passed on when you set it (your explicit override); it is applied when Strata's setup runs, i.e. on the first start or with `REINSTALL=1`, not on later starts of an existing config: `auto`, `on`, `off`, `resident` (experts copied into RAM once at start), `mmap` (read from the data folder). Strata reads the host's RAM, not the pod's limit: `start.sh` warns when the limit is clearly below experts + ~12 GiB; then set `resident`. No effect for `unsloth` |
| `STRATA_CALIBRATE` | `no` | `no`: never calibrates (Strata's 15-30 min calibration is skipped, also when none exists). `yes`: calibrates on start only if the config has no calibration yet. `force`: always. Alternatively run `/app/scripts/calibrate.sh` by hand (stop the server first); it prints the `STRATA_ENGINE_ARGS` line to reuse |
| `STRATA_ENGINE_ARGS` | unset | Strata engine arguments merged into the config on every start (replaces same-named flags, takes precedence over the automatic `--pool-workers`). Calibration result in one variable, e.g. `--pcie-frac 1.00 --spec-min-p 0.70`; may also contain `--pool-workers N` and `--adapt-*` |
| `COPY_DATA_LOCAL` | `yes` | copy model data from the store to `/tmp` (needs a big container disk), or use it on the volume |
| `AUTO_START` | `no` | start Strata automatically (otherwise run `/opt/runpod/start.sh`) |
| `STRATA_REF`, `STRATA_REPO` | `latest`, `Niko1221/Strata` | Strata to use: `latest` (newest release tag `v*`), a tag such as `v0.1.43.1` (pin), a branch or `HEAD` (key `head-<commit>`, rebuild on every upstream commit). A new version rebuilds the engine and runs Strata's setup again (`REINSTALL=1`) for the existing data |
| `POOL_WORKERS` | pod CPU quota - 3 (min 4) | `--pool-workers` written into a new config (Strata would use the host's physical cores and be throttled by the pod's CPU quota); `0` = leave it to Strata |
| `RESIDENT_BUDGET_GIB` | pod RAM - 24 | `unsloth` only: GiB of experts kept in RAM |
| `STRATA_STORE`, `STRATA_LOCAL` | `<volume>/strata-store`, `/tmp` | store and local base; with the local base also the config paths change |
| `MODE`, `PORT`, `KV`, `GPU`, `GPUS`, `VISION`, `REINSTALL`, ... | Strata defaults | passed on to Strata's `docker-entrypoint.sh`; see the header of Strata's `Dockerfile` |
| `PUBLIC_KEY` | set by Runpod | sshd starts with this key (key login only, no password) |
| `SSH_PUBLIC_KEY` | - | your public key line, used when Runpod does not pass `PUBLIC_KEY` (seen on a pod: the `ssh.runpod.io` proxy worked, the direct TCP login failed). A public key is no secret |

## Pod template in the console

- **Container Image**: `ghcr.io/<owner>/strata-runpod:v0.1.<run>` (make the package public, or add a Container Registry Auth entry for `ghcr.io`)
- **Container Disk**: 150 GB (engine and data live under `/tmp`; IQ2_XS measured 73 GiB, up to ~106 GiB if the setup also writes `experts.bin`; IQ3_XXS ~81-121 GiB, estimated); **Volume**: the store, 150 GB+
- **TCP Port** `22` (SSH), **HTTP Port** `8080`; pod filter CUDA 13.0 (driver >= 580), RAM at least what `MODEL` needs
- Env: see the table. Connect via Web Terminal or SSH (add your public key under Settings -> SSH Public Keys first).

## Calibration

`/app/scripts/calibrate.sh` runs Strata's calibration (15-30 minutes; stop the server first), copies the rewritten config back to the
data folder and pushes it to the store, so the next start uses it. A calibration is valid for one GPU + CPU + RAM + model + context
(Strata's hardware key), so run it once per pod type.

## Strata and the pod's limits

- **RAM and CPU** are read from the host by Strata (`RAM: 1007 GB`, 128 cores) while the pod has a limit (cgroup: `memory.max`,
  `cpu.max`). `start.sh` derives `POOL_WORKERS` (and the unsloth budget) from the limits; `LOW_RAM` you set yourself.
- **MIG slices** (RTX PRO 6000 `1g.24gb`): `nvidia-smi` prints `[Insufficient Permissions]` for `memory.total`, Strata's `setup.py` then stops
  with "no NVIDIA GPU found". `scripts/nvidia-smi-shim.py` (installed as `/usr/local/bin/nvidia-smi`) fills in the memory CUDA reports.
- **Questions of `setup.py`**: the setup run uses `--yes` (recommended answers, images off, KV int8, no calibration). Two questions can
  still come up at the start; `start.sh` prevents both (stale configs of other models are removed from `/opt/strata`, `GPU=0` on a
  multi-GPU pod). A start on a GPU the config's engine does not run on may ask for an engine rebuild and then stop: use `REINSTALL=1`.

## GPUs and CUDA architectures

From Runpod's REST API schema (NVIDIA GPUs with 24 GB or more). `setup.py` builds the engine for the GPU it finds, the archive is per architecture:

| Architecture | GPUs |
|---|---|
| `80` | A100 |
| `86` | RTX 3090, 3090 Ti, RTX A5000, A40, RTX A6000 |
| `89` | RTX 4090, L4, L40, L40S, RTX 6000 Ada, RTX 5000 Ada |
| `90` | H100, H200 |
| `100` / `103` | B200 / B300 |
| `120` | RTX 5090, RTX PRO 6000 Blackwell (also as MIG slice), RTX PRO 5000 Blackwell |

Not covered: AMD Instinct MI300X (needs Strata's HIP build). Strata documents tested builds for 75/86/89/120 only; the others are untested.

## Scripts (in the pod: `/app/scripts/`)

| Script | What it does | Paths it checks |
|---|---|---|
| `check-env.sh` | driver/CUDA, GPU, RAM and cgroup limit, CPU/AVX2, free space | `/`, `/workspace`, `/runpod-volume`, `/dev/shm` |
| `test-local-storage.sh [size_gib] [runtime_s] [dir...]` | fio: sequential write/read, random 4k/128k reads, small files | `/tmp/strata-bench` (container disk), `/dev/shm` |
| `test-network-storage.sh [size_gib] [runtime_s] [dir...]` | same tests on the volumes, classified network/local by filesystem | `/workspace`, `/data`, `/runpod-volume` (those that exist) |
| `test-smallfiles.sh [dir] [files] [ref]` | small-file/metadata speed next to a local reference (`GIT=1` adds `git clone`/`git status`) | `/workspace` and `/tmp` |
| `test-download.sh [url] [mib]` | internet download speed, nothing stored | `https://huggingface.co/bert-base-uncased/resolve/main/model.safetensors` (512 MiB) |
| `bench-local.sh [options]` | waits for `/health`, then runs `bench/bench.py` (TTFT, tokens/s) against Strata in the pod | `http://127.0.0.1:$PORT` |
| `calibrate.sh` | Strata's calibration, result saved to the store | `/opt/strata`, data folder, store |
| `storage-bench.sh <dir>` | the fio tests for one directory | the given directory |

## Where files live

- **Local (`/tmp`, lost with the pod)**: `Strata/` (engine, Python environment), `Strata-data/` (models, packs, mtp, config), `strata-bench/`.
- **Store (volume)**: see "How it works". The engine log is linked to `<store>/logs/`.
- Moving to another pod/GPU: the key picks the matching archive or rebuilds; data is copied from the store.

## Tests

`tests/run.sh` runs `start.sh`, `post-setup.sh` and `publish.sh` against a fake Strata repo (no GPU, no download; needs root, it uses
`/opt/runpod` and `/opt/strata`): key with the release tag, engine archive and restore, data copy, `COPY_DATA_LOCAL=no`, a new Strata
version (`REINSTALL`), calibrated configs, `STRATA_API_KEY` and the `LOW_RAM` override. `tests/test_shim.py` tests the nvidia-smi shim.
The workflow runs both before it builds; the image gets the tags `v0.1.<run>` and the commit SHA.

## Structure

- `Dockerfile`, `entry.sh`, `start.sh`, `sshd.sh`, `post-setup.sh`, `publish.sh` - image and start logic
- `serverless/` - `proxy.py` (`/ping`) and `handler.py` (queue endpoint)
- `scripts/` - benchmarks, environment check, calibration, nvidia-smi shim; `strata/bench/bench.py` is `/app/bench/bench.py`
- `strata/` - control tools: `runpod_ctl.py`, `build.sh`, README
- `.github/workflows/dev.yml` - tests, then build in GitHub Actions
- `tests/` - tests of the start logic and the shim
- `docs/` - context, plan, handoff

## Status

Built by the workflow; tested in a sandbox with a fake Strata (key, archive restore, data copy, `COPY_DATA_LOCAL=no`, hook, pool workers).
Not tested: the real Strata setup through `start.sh`, the post-setup hook against Strata's real `docker-entrypoint.sh`, Serverless.
