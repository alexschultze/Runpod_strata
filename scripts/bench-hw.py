#!/usr/bin/env python3
"""Hardware bench for the start log: local SSD, RAM and PCIe (host <-> GPU) bandwidth, each step time-boxed.

start.sh runs it when RUNPOD_BENCH is set (RUNPOD_BENCH=1 or all: every test; or a list such as ssd,ram,pcie).
By hand: python3 /app/scripts/bench-hw.py [--only ssd,ram,pcie] [--seconds 4] [--dir /data]

  ssd   fio, sequential write and read, 1 MiB blocks, queue depth 16, O_DIRECT (buffered when the file system refuses it, then the read may be
        inflated by the page cache). A temporary file in --dir, removed afterwards.
  ram   memcpy of 128 MiB buffers in Python (one process, then one per core up to 8): bytes copied per second, which is half the memory traffic.
  pcie  cuMemcpy host -> GPU and GPU -> host through the driver library (libcuda.so.1, no CUDA toolkit needed), pinned memory when the system
        allows it (it needs a memlock limit that permits it), else pageable memory.

Every test is limited to about 2 x --seconds plus a short setup. A failing test is logged and skipped, the exit code is always 0.
"""
import argparse
import ctypes
import json
import multiprocessing
import os
import shutil
import subprocess
import sys
import time


def log(msg):
    print("bench: " + msg, flush=True)


# ------------------------------------------------------------------------------------------------------------------------ ssd
def _fstype(path):
    try:
        out = subprocess.run(["findmnt", "-no", "FSTYPE", "-T", path], capture_output=True, text=True, timeout=5).stdout.strip()
        if out:
            return out.splitlines()[0]
    except Exception:
        pass
    return "?"


def _fio(path, size_mib, secs, direct):
    cmd = ["fio", "--output-format=json", "--filename=" + path, "--size=%dM" % size_mib, "--bs=1M", "--time_based", "--runtime=%d" % max(1, round(secs)),
           "--ioengine=libaio" if direct else "--ioengine=psync", "--iodepth=16" if direct else "--iodepth=1", "--direct=%d" % direct,
           "--name=write", "--rw=write", "--stonewall", "--name=read", "--rw=read", "--stonewall"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=secs * 2 + 30)
    out = r.stdout
    if "{" not in out:
        raise RuntimeError((r.stderr or out or "fio printed nothing").strip().splitlines()[-1][:160])
    data = json.loads(out[out.index("{"):])
    errs = [j.get("error", 0) for j in data["jobs"]]
    if any(errs):
        raise RuntimeError("fio error %s" % errs)
    jobs = {j["jobname"]: j for j in data["jobs"]}
    return jobs["write"]["write"]["bw_bytes"] / 1e6, jobs["read"]["read"]["bw_bytes"] / 1e6


def bench_ssd(directory, secs, size_mib=4096):
    if not shutil.which("fio"):
        log("ssd  fio not found, skipped")
        return
    d = directory if directory and os.path.isdir(directory) and os.access(directory, os.W_OK) else "/tmp"
    free_mib = shutil.disk_usage(d).free // (1 << 20)
    size_mib = min(size_mib, free_mib // 4)
    if size_mib < 256:
        log("ssd  %s: only %d MiB free, skipped" % (d, free_mib))
        return
    path = os.path.join(d, ".bench-ssd.tmp")
    try:
        for direct in (1, 0):
            try:
                w, r = _fio(path, size_mib, secs, direct)
                break
            except Exception as e:
                if not direct:
                    raise
                last = str(e)                                  # O_DIRECT refused by this file system: again, buffered
        else:
            raise RuntimeError(last)
        log("ssd  %s (%s), 1 MiB sequential, %s: write %.0f MB/s, read %.0f MB/s%s"
            % (d, _fstype(d), "O_DIRECT, queue depth 16" if direct else "buffered", w, r, "" if direct else " (read may include the page cache)"))
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


# ------------------------------------------------------------------------------------------------------------------------ ram
def _ram_worker(barrier, size, secs, queue):
    chunk = os.urandom(1 << 20)
    src = bytearray(size)
    for i in range(0, size, 1 << 20):
        src[i:i + (1 << 20)] = chunk                          # real pages (a fresh bytearray is zero pages)
    dst = bytearray(size)
    dst[:] = src                                              # warm up: first touch of the target
    barrier.wait()
    t0 = time.perf_counter()
    n = 0
    while time.perf_counter() - t0 < secs:
        dst[:] = src
        n += size
    queue.put((n, time.perf_counter() - t0))


def _cpus():
    try:
        n = len(os.sched_getaffinity(0))
    except AttributeError:
        n = os.cpu_count() or 1
    try:
        q, p = open("/sys/fs/cgroup/cpu.max").read().split()
        if q != "max":
            n = min(n, max(1, int(int(q) / int(p))))
    except Exception:
        pass
    return n


def _mem_available_mib():
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    except Exception:
        pass
    return 0


def _ram_run(procs, size, secs):
    ctx = multiprocessing.get_context("fork")
    barrier, queue = ctx.Barrier(procs), ctx.Queue()
    ps = [ctx.Process(target=_ram_worker, args=(barrier, size, secs, queue)) for _ in range(procs)]
    for p in ps:
        p.start()
    res = [queue.get(timeout=secs + 60) for _ in ps]
    for p in ps:
        p.join(10)
    return sum(n / t for n, t in res) / 1e9


def bench_ram(secs, size_mib=128):
    size = size_mib << 20
    procs = min(8, _cpus())
    while procs > 1 and procs * 2 * size_mib * 3 > _mem_available_mib():
        procs -= 1                                            # keep it well inside the free memory
    one = _ram_run(1, size, secs)
    many = _ram_run(procs, size, secs) if procs > 1 else one
    log("ram  memcpy of %d MiB buffers: 1 process %.1f GB/s, %d processes %.1f GB/s (bytes copied per second; memory traffic is twice that)"
        % (size_mib, one, procs, many))


# ------------------------------------------------------------------------------------------------------------------------ pcie
_LANE_GBS = {1: 0.25, 2: 0.5, 3: 0.985, 4: 1.969, 5: 3.938, 6: 7.563}   # per lane and direction, after encoding


def _link():
    """(name, gen_now, gen_max, width_now, width_max) of GPU 0 from nvidia-smi, or None."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=15).stdout.strip().splitlines()[0]
        f = [x.strip() for x in out.split(",")]
        return f[0], int(f[1]), int(f[2]), int(f[3]), int(f[4])
    except Exception:
        return None


def bench_pcie(secs, size_mib=256):
    cu = None
    for name in ("libcuda.so.1", "libcuda.so"):
        try:
            cu = ctypes.CDLL(name)
            break
        except OSError:
            pass
    if cu is None:
        log("pcie no NVIDIA driver library (libcuda.so.1) here, skipped")
        return
    size = size_mib << 20
    u64, vp, st = ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t

    def chk(rc, what):
        if rc != 0:
            raise RuntimeError("%s failed (CUDA error %d)" % (what, rc))

    cu.cuMemAlloc_v2.argtypes = [ctypes.POINTER(u64), st]
    cu.cuMemAllocHost_v2.argtypes = [ctypes.POINTER(vp), st]
    cu.cuMemcpyHtoD_v2.argtypes = [u64, vp, st]
    cu.cuMemcpyDtoH_v2.argtypes = [vp, u64, st]
    cu.cuMemFree_v2.argtypes = [u64]
    cu.cuMemFreeHost.argtypes = [vp]
    cu.cuDevicePrimaryCtxRetain.argtypes = [ctypes.POINTER(vp), ctypes.c_int]
    cu.cuCtxSetCurrent.argtypes = [vp]

    chk(cu.cuInit(0), "cuInit")
    dev, ctx, dptr, host = ctypes.c_int(), vp(), u64(), vp()
    chk(cu.cuDeviceGet(ctypes.byref(dev), 0), "cuDeviceGet")
    chk(cu.cuDevicePrimaryCtxRetain(ctypes.byref(ctx), dev.value), "cuDevicePrimaryCtxRetain")
    chk(cu.cuCtxSetCurrent(ctx), "cuCtxSetCurrent")
    chk(cu.cuMemAlloc_v2(ctypes.byref(dptr), size), "cuMemAlloc")
    pinned = cu.cuMemAllocHost_v2(ctypes.byref(host), size) == 0
    keep = None
    if pinned:
        ptr = host.value
    else:                                                     # page-locked memory refused (memlock limit?): pageable memory
        keep = ctypes.create_string_buffer(size)
        ptr = ctypes.addressof(keep)
    ctypes.memset(ptr, 0x5a, size)

    def run(copy):
        copy()                                                # warm up
        n, t0 = 0, time.perf_counter()
        while time.perf_counter() - t0 < secs:
            copy()
            n += size
        return n / (time.perf_counter() - t0) / 1e9

    try:
        h2d = run(lambda: chk(cu.cuMemcpyHtoD_v2(dptr.value, ptr, size), "cuMemcpyHtoD"))
        d2h = run(lambda: chk(cu.cuMemcpyDtoH_v2(ptr, dptr.value, size), "cuMemcpyDtoH"))
    finally:
        cu.cuMemFree_v2(dptr.value)
        if pinned:
            cu.cuMemFreeHost(host.value)
    link = _link()                                            # read after the copies: an idle card lowers its link
    desc = ""
    if link:
        name, gn, gx, wn, wx = link
        theo = _LANE_GBS.get(gx, 0) * wx
        desc = " %s, link now gen%d x%d (max gen%d x%d%s)," % (name, gn, wn, gx, wx, ", ~%.0f GB/s per direction" % theo if theo else "")
    log("pcie GPU 0,%s %s memory: host->GPU %.1f GB/s, GPU->host %.1f GB/s%s"
        % (desc, "pinned" if pinned else "pageable", h2d, d2h,
           "" if pinned else " (page-locked memory refused: memlock limit? Strata recommends --ulimit memlock=-1:-1)"))


# ------------------------------------------------------------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--only", default="all", help="all, or a comma list of ssd,ram,pcie")
    ap.add_argument("--seconds", type=float, default=float(os.environ.get("BENCH_SECONDS", "4")), help="per step (write, read, 1 process, many ...)")
    ap.add_argument("--dir", default="/data", help="directory of the SSD test (the local container disk)")
    a = ap.parse_args()
    want = {"ssd", "ram", "pcie"} if a.only in ("all", "1", "") else {x.strip().lower() for x in a.only.split(",") if x.strip()}
    unknown = want - {"ssd", "ram", "pcie"}
    if unknown:
        log("unknown test(s) %s ignored (ssd, ram, pcie)" % ", ".join(sorted(unknown)))
    t0 = time.time()
    log("---- hardware bench (RUNPOD_BENCH): %s, %g s per step ----" % (",".join(t for t in ("ssd", "ram", "pcie") if t in want), a.seconds))
    took = []
    for name, fn in (("ssd", lambda: bench_ssd(a.dir, a.seconds)), ("ram", lambda: bench_ram(a.seconds)), ("pcie", lambda: bench_pcie(a.seconds))):
        if name in want:
            t1 = time.time()
            try:
                fn()
            except Exception as e:
                log("%s  failed: %s" % (name, e))
            took.append("%s %d s" % (name, round(time.time() - t1)))
    log("---- bench done in %d s (%s) ----" % (round(time.time() - t0), ", ".join(took)))


if __name__ == "__main__":
    main()
