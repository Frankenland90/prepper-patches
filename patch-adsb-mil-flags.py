#!/usr/bin/env python3
"""Restore ADSB Militär Land-Flaggen. /* milFlags */ — assembles .part0+.part1."""
from pathlib import Path
import sys, urllib.request, os
TARGET = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
COMMIT = os.environ.get("COMMIT", "main")
BASE = "https://raw.githubusercontent.com/Frankenland90/prepper-patches/%s/" % COMMIT
here = Path(__file__).resolve().parent

def fetch(name):
    local = here / name
    if local.is_file():
        return local.read_text(encoding="utf-8")
    with urllib.request.urlopen(BASE + name, timeout=30) as r:
        return r.read().decode("utf-8")

code = fetch("patch-adsb-mil-flags.part0") + fetch("patch-adsb-mil-flags.part1")
if "/* milFlags */" not in code or "def _adsb_icao_cc" not in code:
    raise SystemExit("FAIL: milFlags parts incomplete")
g = {"__name__": "__main__", "__file__": str(here / "patch-adsb-mil-flags.real.py")}
sys.argv = [sys.argv[0], str(TARGET)]
exec(compile(code, "patch-adsb-mil-flags.real.py", "exec"), g)
