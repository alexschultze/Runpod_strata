#!/bin/sh
# Local build (needs ~40 GB free disk): Strata engine image + Runpod layer. GitHub Actions does the same (dev.yml).
# Usage: IMAGE=ghcr.io/<user>/strata-runpod:v0.1.1 strata/build.sh
set -e
cd "$(dirname "$0")/.."
IMAGE="${IMAGE:?IMAGE=<registry>/<name>:<tag> setzen}"
ARCHS="${CUDA_ARCHITECTURES:-80;86;89;90;100;103;120}"
SRC="${STRATA_SRC:-$(mktemp -d)/strata}"
[ -d "$SRC/.git" ] || git clone --depth 1 https://github.com/Niko1221/Strata "$SRC"
docker build --platform linux/amd64 -t "$IMAGE-engine" --build-arg "CUDA_ARCHITECTURES=$ARCHS" "$SRC"
docker build --platform linux/amd64 -t "$IMAGE" --build-arg "BASE=$IMAGE-engine" .
docker push "$IMAGE"
