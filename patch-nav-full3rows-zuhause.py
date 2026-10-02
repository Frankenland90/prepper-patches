#!/usr/bin/env python3
"""navFull3 zuhause inject — same payload, target zuhause.py."""
from pathlib import Path
import base64, sys, zlib, urllib.request, os

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/zuhause.py")
COMMIT = os.environ.get("COMMIT", "main")
BASE = "https://raw.githubusercontent.com/Frankenland90/prepper-patches/%s" % COMMIT

def load_payload():
    for p in (
        Path(__file__).resolve().parent / "patch-nav-full3rows.zb64",
        Path("/tmp/patch-nav-full3rows.zb64"),
    ):
        if p.is_file():
            return zlib.decompress(base64.b64decode(p.read_text().strip()))
    with urllib.request.urlopen(BASE + "/patch-nav-full3rows.zb64", timeout=60) as r:
        return zlib.decompress(base64.b64decode(r.read().decode().strip()))

code = load_payload()
if b"navFull3" not in code or b"navFull3v2" not in code:
    raise SystemExit("STOP: zb64 fehlt navFull3v2")
g = {"__name__": "__main__", "__file__": str(Path(__file__).resolve())}
sys.argv = [sys.argv[0], str(TARGET)]
exec(compile(code, "patch-nav-full3rows.real.py", "exec"), g)
