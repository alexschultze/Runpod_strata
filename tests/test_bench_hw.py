"""Tests of scripts/bench-hw.py: every test prints one line with numbers, a missing GPU or fio is skipped, the exit code is 0.
The PCIe path runs against a small fake libcuda.so.1 (built with gcc when there is one)."""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(HERE, "scripts", "bench-hw.py")
FAILS = 0


def check(name, ok, detail=""):
    global FAILS
    print(("  ok:   " if ok else "  FAIL: ") + name + ("" if ok else "  " + detail))
    FAILS += 0 if ok else 1


def run(*args, env=None):
    e = dict(os.environ, **(env or {}))
    r = subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, timeout=120, env=e)
    return r.returncode, r.stdout


tmp = tempfile.mkdtemp()
try:
    rc, out = run("--only", "ram", "--seconds", "1")
    check("ram: one line with GB/s, exit 0", rc == 0 and "bench: ram  memcpy" in out and "GB/s" in out, out)
    check("only the chosen test runs", "bench: ssd" not in out and "bench: pcie" not in out, out)

    rc, out = run("--only", "ssd", "--seconds", "1", "--dir", tmp)
    if shutil.which("fio"):
        check("ssd: write and read in MB/s", rc == 0 and "write" in out and "read" in out and "MB/s" in out, out)
        check("ssd: the temporary file is gone", not os.path.exists(os.path.join(tmp, ".bench-ssd.tmp")))
    else:
        check("ssd: no fio is said, not an error", rc == 0 and "fio not found" in out, out)

    rc, out = run("--only", "pcie", "--seconds", "1", env={"LD_LIBRARY_PATH": "/nonexistent"})
    if not os.path.exists("/usr/lib/x86_64-linux-gnu/libcuda.so.1"):
        check("pcie: no driver library is skipped", rc == 0 and "skipped" in out, out)

    if shutil.which("gcc"):
        src = os.path.join(tmp, "fake.c")
        open(src, "w").write("""#include <stdlib.h>
#include <string.h>
#include <stdint.h>
int cuInit(unsigned f){return 0;}
int cuDeviceGet(int*d,int o){*d=0;return 0;}
int cuDevicePrimaryCtxRetain(void**c,int d){*c=(void*)1;return 0;}
int cuCtxSetCurrent(void*c){return 0;}
int cuMemAlloc_v2(uint64_t*p,size_t n){*p=(uint64_t)malloc(n);return *p?0:2;}
int cuMemAllocHost_v2(void**p,size_t n){if(getenv("FAKE_NO_PIN"))return 801;*p=malloc(n);return *p?0:2;}
int cuMemcpyHtoD_v2(uint64_t d,const void*s,size_t n){memcpy((void*)d,s,n);return 0;}
int cuMemcpyDtoH_v2(void*d,uint64_t s,size_t n){memcpy(d,(void*)s,n);return 0;}
int cuMemFree_v2(uint64_t p){free((void*)p);return 0;}
int cuMemFreeHost(void*p){free(p);return 0;}
""")
        subprocess.run(["gcc", "-shared", "-fPIC", "-o", os.path.join(tmp, "libcuda.so.1"), src], check=True)
        rc, out = run("--only", "pcie", "--seconds", "1", env={"LD_LIBRARY_PATH": tmp})
        check("pcie (fake driver): pinned, host->GPU and GPU->host", rc == 0 and "pinned memory" in out and "host->GPU" in out and "GPU->host" in out, out)
        rc, out = run("--only", "pcie", "--seconds", "1", env={"LD_LIBRARY_PATH": tmp, "FAKE_NO_PIN": "1"})
        check("pcie: refused pinned memory falls back to pageable and says why", rc == 0 and "pageable memory" in out and "memlock" in out, out)
    else:
        print("  skip: no gcc, the fake driver tests are not run")

    rc, out = run("--only", "nonsense", "--seconds", "1")
    check("an unknown test name is reported and ignored", rc == 0 and "unknown test" in out, out)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("all tests passed" if FAILS == 0 else "%d test(s) failed" % FAILS)
sys.exit(FAILS)
