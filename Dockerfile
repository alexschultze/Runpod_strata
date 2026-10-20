# Strata 0.2 on Runpod: Strata's own ready-made image (engine and Terminal built in, nothing is compiled on the pod) plus our layer: SSH, the start
# logic (data on the local disk, store on the network volume), the queue handler and the load-balancer proxy. Branch strata-v2-dev.
#   STRATA_IMAGE  Strata's image: ghcr.io/niko1221/strata:<version>-cuda13 (latest-cuda13 = the newest release of that flavor; pin a version for
#                 reproducible builds, e.g. 0.2.1-cuda13). cuda12 for drivers 575-579 and older cards (Pascal, Volta).
ARG STRATA_IMAGE=ghcr.io/niko1221/strata:latest-cuda13
FROM ${STRATA_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# openssh-server (SSH), rsync (volume <-> local copies), fio/jq (benchmarks, JSON), tmux/htop/nano, curl, Python with venv for the handler
RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends \
    openssh-server rsync fio jq tmux htop nano curl \
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

EXPOSE 22 8080

# Strata's image runs tini as PID 1 (forwards docker stop to its entrypoint, which unloads the model). entry.sh starts sshd and waits;
# AUTO_START=yes (or MODE=lb|queue) starts Strata through start.sh, otherwise run /opt/runpod/start.sh by hand (in tmux).
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/runpod/entry.sh"]
CMD ["run"]
