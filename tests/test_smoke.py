"""Test of tests/smoke-image.sh (the check the workflow runs inside the built image) against a fake image root: it passes on a complete tree
and fails when Strata's entrypoint, its command line or a variable start.sh passes goes missing."""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILS = 0
VARS = "MODEL FAMILY CONTEXT PARALLEL TUNE RETUNE PRESET API_KEY STRATA_SET PORT"


def check(name, ok, detail=""):
    global FAILS
    print(("  ok:   " if ok else "  FAIL: ") + name + ("" if ok else "  " + detail))
    FAILS += 0 if ok else 1


root = tempfile.mkdtemp()


def w(path, text="#!/bin/sh\n", mode=0o755):
    p = root + path
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)
    os.chmod(p, mode)


def run():
    r = subprocess.run(["bash", os.path.join(HERE, "tests", "smoke-image.sh")], capture_output=True, text=True,
                       env=dict(os.environ, SMOKE_ROOT=root, SMOKE_NO_EXEC="1"))
    return r.returncode, r.stdout


try:
    for f in ("/opt/strata/terminal/bin/strata", "/usr/bin/tini"):
        w(f)
    w("/opt/strata/entrypoint.sh", "#!/bin/sh\n# " + VARS + "\n")
    for f in "entry start sync sshd hwinfo volume-check update-scripts".split():
        w("/opt/runpod/%s.sh" % f, "#!/bin/bash\ntrue\n")
    w("/app/scripts/bench-hw.py", "", 0o644)

    rc, out = run()
    check("a complete image passes", rc == 0 and "smoke test passed" in out, out)

    w("/opt/strata/entrypoint.sh", "#!/bin/sh\n# " + VARS.replace("TUNE ", "") + "\n")
    rc, out = run()
    check("a variable the entrypoint no longer reads fails", rc == 1 and "no longer mentions TUNE" in out, out)

    w("/opt/strata/entrypoint.sh", "#!/bin/sh\n# " + VARS + "\n")
    os.remove(root + "/opt/strata/terminal/bin/strata")
    rc, out = run()
    check("a missing Strata command line fails", rc == 1 and "Strata's command line is missing" in out, out)

    w("/opt/strata/terminal/bin/strata")
    os.remove(root + "/opt/strata/entrypoint.sh")
    rc, out = run()
    check("a missing Strata entrypoint fails", rc == 1 and "Strata's entrypoint is missing" in out, out)
finally:
    shutil.rmtree(root, ignore_errors=True)

print("all tests passed" if FAILS == 0 else "%d test(s) failed" % FAILS)
sys.exit(FAILS)
