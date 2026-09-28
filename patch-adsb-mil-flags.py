#!/usr/bin/env python3
"""Restore ADSB Militär Land-Flaggen. /* milFlags */ — loads sibling .zb64."""
from pathlib import Path
import base64, sys, zlib, urllib.request, os

TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
COMMIT = os.environ.get("COMMIT", "main")
BASE = "https://raw.githubusercontent.com/Frankenland90/prepper-patches/%s" % COMMIT

def load_payload():
    here = Path(__file__).resolve().parent / "patch-adsb-mil-flags.zb64"
    if here.is_file():
        return zlib.decompress(base64.b64decode(here.read_text().strip()))
    url = BASE + "/patch-adsb-mil-flags.zb64"
    with urllib.request.urlopen(url, timeout=30) as r:
        return zlib.decompress(base64.b64decode(r.read().decode().strip()))

code = load_payload()
# Execute real patcher with TARGET as argv[1]
g = {"__name__": "__main__", "__file__": str(Path(__file__).resolve())}
sys.argv = [sys.argv[0], str(TARGET)]
exec(compile(code, "patch-adsb-mil-flags.real.py", "exec"), g)
