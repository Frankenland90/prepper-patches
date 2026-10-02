#!/usr/bin/env python3
"""pageStability stub — loads sibling .zb64 (zlib+b64)."""
from pathlib import Path
import base64, sys, zlib, urllib.request, os

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
ZUH = Path(sys.argv[2]) if len(sys.argv) > 2 else TARGET.with_name("zuhause.py")
COMMIT = os.environ.get("COMMIT", "main")
BASE = "https://raw.githubusercontent.com/Frankenland90/prepper-patches/%s" % COMMIT

def load_payload():
    here = Path(__file__).resolve().parent / "patch-page-stability.zb64"
    if here.is_file():
        return zlib.decompress(base64.b64decode(here.read_text().strip()))
    url = BASE + "/patch-page-stability.zb64"
    with urllib.request.urlopen(url, timeout=60) as r:
        return zlib.decompress(base64.b64decode(r.read().decode().strip()))

code = load_payload()
if b"pageStability" not in code or b"stratumTsGuard" not in code:
    raise SystemExit("STOP: zb64 payload fehlt pageStability/stratumTsGuard")
g = {"__name__": "__main__", "__file__": str(Path(__file__).resolve())}
sys.argv = [sys.argv[0], str(TARGET), str(ZUH)]
exec(compile(code, "patch-page-stability.real.py", "exec"), g)
