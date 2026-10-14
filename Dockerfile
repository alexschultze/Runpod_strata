# One image: the Strata engine is built on the pod (3-4 minutes on a big CPU, once per GPU/CPU/Strata commit) and archived to the
# volume; start.sh restores it to /tmp. The devel base image is the one Strata's own Dockerfile uses (nvcc for the build).
FROM nvidia/cuda:13.0.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8 STRATA_EXECV=1

# The packages of Strata's own Dockerfile (build tools, Python with venv) plus
# openssh-server (SSH), rsync (volume <-> local copies), fio/jq (benchmarks, config edits), tmux/htop/nano
RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends \
    build-essential ca-certificates curl git libatomic1 libgomp1 \
    python3 python3-pip python3-venv unzip \
    openssh-server rsync zstd fio jq tmux htop nano \
    && rm -rf /var/lib/apt/lists/*

COPY serverless/proxy.py serverless/handler.py /opt/runpod/
COPY scripts /app/scripts
COPY strata/bench /app/bench
COPY entry.sh start.sh sshd.sh post-setup.sh publish.sh volume-check.sh update-scripts.sh hwinfo.sh /opt/runpod/
RUN chmod +x /opt/runpod/*.sh /app/scripts/*.sh /app/bench/bench.py /app/scripts/nvidia-smi-shim.py && \
    install -m 755 /app/scripts/nvidia-smi-shim.py /usr/local/bin/nvidia-smi

EXPOSE 22 8080

# entry.sh starts sshd and waits; AUTO_START=yes (or MODE=lb|queue) starts Strata through start.sh, otherwise run
# /opt/runpod/start.sh by hand (in tmux)
ENTRYPOINT ["/opt/runpod/entry.sh"]
