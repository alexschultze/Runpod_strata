#!/usr/bin/env python3
"""Tests of scripts/nvidia-smi-shim.py with a fake nvidia-smi and a mocked CUDA call (no GPU needed)."""
import contextlib
import importlib.util
import io
import os
import stat
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("shim", os.path.join(HERE, "..", "scripts", "nvidia-smi-shim.py"))
shim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shim)

tmp = tempfile.mkdtemp()
fake = os.path.join(tmp, "nvidia-smi")
with open(fake, "w") as f:
    f.write('#!/bin/sh\necho "0, NVIDIA RTX PRO 6000 Blackwell Server Edition, [Insufficient Permissions], 12.0, 580.159.04"\n')
os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
os.environ["PATH"] = tmp + os.pathsep + os.environ["PATH"]
QUERY = "--query-gpu=index,name,memory.total,compute_cap,driver_version"


def run(argv, mib):
    shim.cuda_total_mib = lambda: mib
    sys.argv = ["nvidia-smi"] + argv
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            shim.main()
        except SystemExit:
            pass
    return out.getvalue().strip()


failed = 0
for name, got, want in [
    ("nounits", run([QUERY, "--format=csv,noheader,nounits"], 24064),
     "0, NVIDIA RTX PRO 6000 Blackwell Server Edition, 24064, 12.0, 580.159.04"),
    ("with units", run([QUERY, "--format=csv,noheader"], 24064),
     "0, NVIDIA RTX PRO 6000 Blackwell Server Edition, 24064 MiB, 12.0, 580.159.04"),
    ("no CUDA value: line unchanged", run([QUERY, "--format=csv,noheader,nounits"], None),
     "0, NVIDIA RTX PRO 6000 Blackwell Server Edition, [Insufficient Permissions], 12.0, 580.159.04"),
]:
    if got == want:
        print("  ok:  ", name)
    else:
        print("  FAIL:", name, "\n    got ", got, "\n    want", want)
        failed += 1
sys.exit(1 if failed else 0)
