# Control and benchmark tools

| File | Purpose |
|---|---|
| `runpod_ctl.py` | create, start, stop and delete a Pod or a queue endpoint through Runpod's REST API (state in `.runpod_state.json`) |
| `bench/bench.py` | time to first token and decode tok/s against Strata (or any OpenAI-compatible server) |
| `bench/bench_parallel.py` | N concurrent streams: tok/s per stream and in total (`/app/scripts/bench-parallel.sh` in the pod) |

The image is built by the GitHub Actions workflow `.github/workflows/dev.yml` (started by hand). The user documentation is in the repo's
[README.md](../README.md), the details in [README_DETAILS.md](../README_DETAILS.md).

## runpod_ctl.py

```
export RUNPOD_API_KEY=... STRATA_API_KEY=<secret> IMAGE=ghcr.io/<owner>/strata-runpod:<tag>
strata/runpod_ctl.py pod create     # container disk 85 GB (--container-gb), volume at /workspace (--volume-gb), port 8080/http, 22/tcp
strata/runpod_ctl.py pod url        # https://<pod id>-8080.proxy.runpod.net
strata/runpod_ctl.py pod stop | start | delete | status
strata/runpod_ctl.py --network-volume <ID> ep create    # template + queue endpoint (container disk --container-gb)
strata/runpod_ctl.py ep down | up | delete              # workers 0/0, 1/1, remove
```
Options: `--model`, `--family`, `--context`, `--copy-data-local yes|no`, `--low-ram ...` (only when given), `--gpu`, `--min-ram`, and `--env KEY=VALUE`
(repeatable) for any other variable, for example `--env STRATA_CALIBRATE=yes`. A load-balancing endpoint cannot be created through the API
(adopt one made in the console with `ep adopt <ENDPOINT_ID>`; set `MODE=lb`).

Not tried against a real account in this repository's tests: the calls follow Runpod's OpenAPI schema (`https://rest.runpod.io/v1/openapi.json`).

## Benchmarks

```
python3 strata/bench/bench.py --url $(strata/runpod_ctl.py pod url) --key $STRATA_API_KEY --model default
python3 strata/bench/bench_parallel.py --url <url> --key $STRATA_API_KEY --streams 1,2
```
