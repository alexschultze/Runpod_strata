# Strata 0.2 on Runpod: Strata's own ready-made image (engine and Terminal built in, nothing is compiled on the pod) plus our layer: SSH, the start
# logic (data on the local disk, store on the network volume), the queue handler and the load-balancer proxy. Branch main (Strata 0.2).
#   STRATA_IMAGE  Strata's image: ghcr.io/niko1221/strata:<version>-cuda13, pinned to a version for reproducible builds (latest-cuda13 moves with every
#                 Strata release). cuda12 for drivers 575-579 and older cards (Pascal, Volta). The workflow takes it from its input, the
#                 repository variable STRATA_IMAGE, or this default.
ARG STRATA_IMAGE=ghcr.io/niko1221/strata:0.2.9-cuda13
FROM ${STRATA_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# openssh-server (SSH), rsync (volume <-> local copies), fio/jq (benchmarks, JSON), tmux/htop/nano, curl, Python with venv for the handler
RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends \
    openssh-server rsync fio jq tmux htop nano curl dmidecode \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/* && \
    python3 -m venv /opt/runpod/venv && \
    /opt/runpod/venv/bin/pip install --no-cache-dir runpod requests

COPY serverless/proxy.py serverless/handler.py /opt/runpod/
COPY scripts /app/scripts
COPY strata/bench /app/bench
COPY entry.sh start.sh sshd.sh sync.sh volume-check.sh update-scripts.sh hwinfo.sh /opt/runpod/
RUN chmod +x /opt/runpod/*.sh /app/scripts/*.sh /app/bench/bench.py /app/scripts/nvidia-smi-shim.py && \
    install -m 755 /app/scripts/nvidia-smi-shim.py /usr/local/bin/nvidia-smi

# what this image is made of, for the start log (hwinfo.sh) and `docker inspect`; last, so a new commit only rebuilds these layers
ARG STRATA_IMAGE
ARG IMAGE_VERSION=dev
ARG IMAGE_COMMIT=unknown
ARG STRATA_BASE_DIGEST=unknown
ENV RUNPOD_IMAGE_VERSION=${IMAGE_VERSION} RUNPOD_IMAGE_COMMIT=${IMAGE_COMMIT} RUNPOD_IMAGE_BASE=${STRATA_IMAGE} RUNPOD_IMAGE_BASE_DIGEST=${STRATA_BASE_DIGEST}
LABEL org.opencontainers.image.source="https://github.com/alexschultze/Runpod_strata" \
      io.runpod-strata.image-version="${IMAGE_VERSION}" io.runpod-strata.commit="${IMAGE_COMMIT}" \
      io.runpod-strata.base-image="${STRATA_IMAGE}" io.runpod-strata.base-digest="${STRATA_BASE_DIGEST}"

EXPOSE 22 8080

# Strata's image runs tini as PID 1 (forwards docker stop to its entrypoint, which unloads the model). entry.sh starts sshd and waits;
# AUTO_START=yes (or MODE=lb|queue) starts Strata through start.sh, otherwise run /opt/runpod/start.sh by hand (in tmux).
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/runpod/entry.sh"]
CMD ["run"]
