#!/usr/bin/env python3
"""pageFein stub — loads sibling .zb64 or .zb64.p0+.p1 (zlib+b64)."""
from pathlib import Path
import base64, sys, zlib, urllib.request, os

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
COMMIT = os.environ.get("COMMIT", "main")
BASE = "https://raw.githubusercontent.com/Frankenland90/prepper-patches/%s" % COMMIT

def _read_local_or_url(name: str) -> str:
    here = Path(__file__).resolve().parent / name
    if here.is_file():
        return here.read_text().strip()
    tmp = Path("/tmp") / name
    if tmp.is_file():
        return tmp.read_text().strip()
    with urllib.request.urlopen(BASE + "/" + name, timeout=60) as r:
        return r.read().decode().strip()

def load_payload():
    try:
        p0 = _read_local_or_url("patch-page-fein.zb64.p0")
        p1 = _read_local_or_url("patch-page-fein.zb64.p1")
        return zlib.decompress(base64.b64decode(p0 + p1))
    except Exception:
        zb = _read_local_or_url("patch-page-fein.zb64")
        return zlib.decompress(base64.b64decode(zb))

code = load_payload()
if b"pageFein" not in code or b"dataStoreLock" not in code or b"ninaDualGuard" not in code:
    raise SystemExit("STOP: zb64 payload fehlt pageFein/dataStoreLock/ninaDualGuard")
if b"Referenz-Tausch" not in code:
    raise SystemExit("STOP: zb64 payload fehlt Referenz-Tausch")
if b"ABANDONED" not in code and b"SAFE Feinschliff" not in code and b"Boot-safe" not in code:
    raise SystemExit("STOP: zb64 payload ist nicht SAFE-Variante")
g = {"__name__": "__main__", "__file__": str(Path(__file__).resolve())}
sys.argv = [sys.argv[0], str(TARGET)]
exec(compile(code, "patch-page-fein.real.py", "exec"), g)
