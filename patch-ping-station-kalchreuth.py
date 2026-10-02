#!/usr/bin/env python3
"""Ping-Antwort-Label: Station Kalchreuth (nicht Bayern/Mesh2). # pingStationKalch
Idempotent. Targets Mesh2 ping-reply (+ optional bayern alias / bridge).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "pingStationKalch"
WANTED = f'STATION = "Station Kalchreuth"  # {MARK}'
STATION_RE = re.compile(r'^STATION\s*=\s*["\'].*?["\'].*$', re.M)

# Files that answer Mesh2/Bayern pings (Mesh1 already Kalchreuth).
TARGETS = (
    "mesh_ping_reply2.py",
    "mesh_ping_reply_bayern.py",
    "mesh_bridge_bayern.py",
)


def patch_one(path: Path) -> str:
    if not path.exists():
        return "skip missing"
    src = path.read_text(encoding="utf-8")
    m = STATION_RE.search(src)
    if not m:
        raise SystemExit(f"STOP: keine STATION-Zeile in {path.name}")
    line = m.group(0)
    # Already correct + marked
    if 'STATION = "Station Kalchreuth"' in line and MARK in line:
        return "schon ok"
    # Correct value, missing marker → add marker only
    if re.search(r'STATION\s*=\s*["\']Station Kalchreuth["\']', line):
        new_src = STATION_RE.sub(WANTED, src, count=1)
        if new_src == src:
            return "schon ok"
        path.write_text(new_src, encoding="utf-8")
        return "marker"
    # Wrong label (Bayern / Mesh2 / other) → replace
    new_src = STATION_RE.sub(WANTED, src, count=1)
    if new_src == src:
        raise SystemExit(f"STOP: STATION unverändert in {path.name}: {line!r}")
    path.write_text(new_src, encoding="utf-8")
    return f"fix {line.strip()} -> {WANTED}"


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    any_hit = False
    for name in TARGETS:
        p = root / name
        status = patch_one(p)
        print(f"{name}: {status}")
        if status != "skip missing":
            any_hit = True
    if not any_hit:
        raise SystemExit("STOP: kein Ziel-File gefunden")
    # Assert at least reply2 (or bayern alias) now Kalchreuth if present
    for name in ("mesh_ping_reply2.py", "mesh_ping_reply_bayern.py"):
        p = root / name
        if p.exists():
            txt = p.read_text(encoding="utf-8")
            if 'STATION = "Station Kalchreuth"' not in txt:
                raise SystemExit(f"FAIL assert: {name} nicht Kalchreuth")
            if MARK not in txt:
                raise SystemExit(f"FAIL assert: Marker fehlt in {name}")


if __name__ == "__main__":
    main()
