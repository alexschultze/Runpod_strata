#!/usr/bin/env python3
"""nvidia-smi wrapper for MIG slices. Installed as /usr/local/bin/nvidia-smi, in front of the real one.

In a container that only sees a MIG instance, `nvidia-smi --query-gpu=...,memory.total,...` prints
"[Insufficient Permissions]" instead of the memory size. Strata's setup.py converts that column with float(), skips the
whole line and reports "no NVIDIA GPU found". This wrapper passes every call through unchanged, and only in a
--query-gpu call that asks for memory.total it replaces a bracketed value ("[Insufficient Permissions]", "[N/A]") by the
total memory CUDA reports for the visible device (the MIG instance). Used only when exactly one CUDA device is visible.
"""
import ctypes
import os
import subprocess
import sys


def real_nvidia_smi():
    me = os.path.realpath(__file__)
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, "nvidia-smi")
        if os.path.isfile(p) and os.access(p, os.X_OK) and os.path.realpath(p) != me:
            return p
    sys.exit("nvidia-smi (shim): the real nvidia-smi was not found in PATH")


def cuda_total_mib():
    """Total memory of the single visible CUDA device in MiB, or None."""
    try:
        lib = ctypes.CDLL("libcuda.so.1")
        if lib.cuInit(0):
            return None
        n = ctypes.c_int()
        if lib.cuDeviceGetCount(ctypes.byref(n)) or n.value != 1:
            return None
        dev = ctypes.c_int()
        if lib.cuDeviceGet(ctypes.byref(dev), 0):
            return None
        mem = ctypes.c_size_t()
        if lib.cuDeviceTotalMem_v2(ctypes.byref(mem), dev):
            return None
        return mem.value // (1024 * 1024)
    except (OSError, AttributeError):
        return None


def main():
    args = sys.argv[1:]
    exe = real_nvidia_smi()
    query = next((a.split("=", 1)[1] for a in args if a.startswith("--query-gpu=")), None)
    cols = query.split(",") if query else []
    if "memory.total" not in cols:
        os.execv(exe, [exe] + args)
    fmt = next((a for a in args if a.startswith("--format=")), "")
    r = subprocess.run([exe] + args, capture_output=True, text=True)
    i = cols.index("memory.total")
    lines = []
    for line in r.stdout.splitlines():
        parts = [x.strip() for x in line.split(",")]
        if len(parts) == len(cols) and parts[i].startswith("[") and parts[i].endswith("]"):
            mib = cuda_total_mib()
            if mib:
                parts[i] = str(mib) if "nounits" in fmt else f"{mib} MiB"
                line = ", ".join(parts)
        lines.append(line)
    sys.stdout.write("\n".join(lines) + ("\n" if lines else ""))
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
