#!/usr/bin/env python3
"""Kanalauslastung aus Meshtastic DeviceMetrics speichern/lesen. /* chutil */"""
from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
HIST_MAX = 2200  # ~14 Tage à 10 min
SAMPLE_MIN_GAP = 300  # Sekunden

def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")

def _node_key(nid) -> str:
    if nid is None:
        return ""
    s = str(nid).strip().lower()
    if s.startswith("!"):
        return s
    if s.isdigit():
        try:
            return f"!{int(s):08x}"
        except Exception:
            return s
    return s if s.startswith("!") else f"!{s}"

def pick_local_metrics(iface, my_ids=None):
    """Eigene Node-DeviceMetrics aus iface.nodes."""
    nodes = getattr(iface, "nodes", None) or {}
    my_ids = {_node_key(x) for x in (my_ids or []) if x}
    # myInfo.my_node_num
    try:
        mi = getattr(iface, "myInfo", None)
        num = getattr(mi, "my_node_num", None) if mi is not None else None
        if num is None and isinstance(mi, dict):
            num = mi.get("my_node_num")
        if num is not None:
            my_ids.add(_node_key(num))
            my_ids.add(_node_key(f"!{int(num):08x}"))
    except Exception:
        pass

    candidates = []
    for nid, info in nodes.items():
        if not isinstance(info, dict):
            continue
        dm = info.get("deviceMetrics") or info.get("device_metrics") or {}
        if not isinstance(dm, dict):
            # protobuf-like
            try:
                dm = {
                    "channelUtilization": getattr(dm, "channelUtilization", None),
                    "airUtilTx": getattr(dm, "airUtilTx", None),
                }
            except Exception:
                continue
        ch = dm.get("channelUtilization")
        if ch is None:
            continue
        key = _node_key(nid)
        is_local = key in my_ids or key.lstrip("!") in {x.lstrip("!") for x in my_ids}
        candidates.append((is_local, key, float(ch), float(dm.get("airUtilTx") or 0)))

    if not candidates:
        return None
    # bevorzugt lokal
    locals_ = [c for c in candidates if c[0]]
    pick = locals_[0] if locals_ else max(candidates, key=lambda c: c[2])
    return {
        "node": pick[1],
        "ch_util": round(pick[2], 2),
        "air_tx": round(pick[3], 3),
        "local": bool(pick[0]),
    }

def load_hist(path: Path):
    try:
        data = json.loads(path.read_text() or "[]")
        return data if isinstance(data, list) else []
    except Exception:
        return []

def append_sample(path: Path, sample: dict, min_gap: int = SAMPLE_MIN_GAP):
    path = Path(path)
    hist = load_hist(path)
    now_ts = time.time()
    if hist and now_ts - float(hist[-1].get("ts") or 0) < min_gap:
        return False, hist[-1]
    point = {
        "ts": now_ts,
        "t": datetime.now().strftime("%d.%m. %H:%M"),
        "ch_util": sample.get("ch_util"),
        "air_tx": sample.get("air_tx"),
        "node": sample.get("node") or "",
        "local": bool(sample.get("local")),
    }
    hist.append(point)
    cut = now_ts - 14 * 24 * 3600
    hist = [p for p in hist if float(p.get("ts") or 0) >= cut][-HIST_MAX:]
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(hist, ensure_ascii=False))
    tmp.replace(path)
    return True, point

def sample_and_store(iface, path, my_ids=None, min_gap: int = SAMPLE_MIN_GAP):
    if iface is None:
        return {"ok": False, "error": "no iface"}
    sample = pick_local_metrics(iface, my_ids)
    if not sample:
        return {"ok": False, "error": "no deviceMetrics"}
    wrote, point = append_sample(Path(path), sample, min_gap=min_gap)
    return {"ok": True, "wrote": wrote, "current": point, "sample": sample}

def hist_payload(path: Path, hours: float = 24):
    hist = load_hist(path)
    now_ts = time.time()
    win = [p for p in hist if now_ts - float(p.get("ts") or 0) <= hours * 3600]
    if not win and hist:
        win = hist[-min(len(hist), 200):]
    cur = hist[-1] if hist else None
    return {
        "ok": True,
        "at": now_str(),
        "current": cur,
        "points": len(win),
        "hist_t": [p.get("t") for p in win],
        "hist_ch": [p.get("ch_util") for p in win],
        "hist_tx": [p.get("air_tx") for p in win],
    }
