#!/usr/bin/env python3
"""ADSB Notlage/Sonder sq3 stub — loads sibling .zb64 (zlib+b64). /* adsbNotlageSq3 */"""
from pathlib import Path
import base64, sys, zlib, urllib.request, os

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
COMMIT = os.environ.get("COMMIT", "main")
BASE = "https://raw.githubusercontent.com/Frankenland90/prepper-patches/%s" % COMMIT

def load_payload():
    here = Path(__file__).resolve().parent / "patch-adsb-notlage-sq3.zb64"
    if here.is_file():
        return zlib.decompress(base64.b64decode(here.read_text().strip()))
    url = BASE + "/patch-adsb-notlage-sq3.zb64"
    with urllib.request.urlopen(url, timeout=60) as r:
        return zlib.decompress(base64.b64decode(r.read().decode().strip()))

code = load_payload()
if b"adsbNotlageSq3" not in code:
    raise SystemExit("STOP: zb64 payload fehlt adsbNotlageSq3")
g = {"__name__": "__main__", "__file__": str(Path(__file__).resolve())}
sys.argv = [sys.argv[0], str(TARGET)]
exec(compile(code, "patch-adsb-notlage-sq3.real.py", "exec"), g)
