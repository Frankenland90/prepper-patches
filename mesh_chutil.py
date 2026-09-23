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
THRESH_YELLOW = 25.0
THRESH_RED = 40.0
STUCK_MIN_SEC = 1800  # 30 min  # meshHang
STUCK_MIN_POINTS = 4  # meshHang
HEARD_STALE_SEC = 1800  # meshHang


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


def _last_heard_ts(info):
    if not isinstance(info, dict):
        return None
    for k in ("lastHeard", "last_heard", "lastheard"):
        v = info.get(k)
        if v is None:
            continue
        try:
            return float(v)
        except Exception:
            pass
    return None


def pick_local_metrics(iface, my_ids=None):
    """Eigene Node-DeviceMetrics aus iface.nodes (+ nodedb, lastHeard)."""
    nodes = getattr(iface, "nodes", None) or {}
    my_ids = {_node_key(x) for x in (my_ids or []) if x}
    try:
        mi = getattr(iface, "myInfo", None)
        num = getattr(mi, "my_node_num", None) if mi is not None else None
        if num is None and isinstance(mi, dict):
            num = mi.get("my_node_num")
        if num is not None:
            my_ids.add(_node_key(num))
            my_ids.add(_node_key(f"!{int(num):08x}"))
        # nodedb_count aus myInfo falls vorhanden
        ndb_mi = getattr(mi, "nodedb_count", None) if mi is not None else None
        if ndb_mi is None and isinstance(mi, dict):
            ndb_mi = mi.get("nodedb_count")
    except Exception:
        ndb_mi = None

    candidates = []
    for nid, info in nodes.items():
        if not isinstance(info, dict):
            continue
        dm = info.get("deviceMetrics") or info.get("device_metrics") or {}
        if not isinstance(dm, dict):
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
        lh = _last_heard_ts(info)
        candidates.append((is_local, key, float(ch), float(dm.get("airUtilTx") or 0), lh, info))

    if not candidates:
        return None
    locals_ = [c for c in candidates if c[0]]
    pick = locals_[0] if locals_ else max(candidates, key=lambda c: c[2])
    nodedb = int(ndb_mi) if ndb_mi is not None else len(nodes)
    lh = pick[4]
    heard_sec = None
    if lh is not None:
        if lh > 1e12:  # ms
            heard_sec = max(0, int(time.time() - lh / 1000.0))
        elif lh > 1e8:  # unix seconds
            heard_sec = max(0, int(time.time() - lh))
    return {
        "node": pick[1],
        "ch_util": round(pick[2], 2),
        "air_tx": round(pick[3], 3),
        "local": bool(pick[0]),
        "nodedb": nodedb,
        "heard_sec": heard_sec,
    }


def load_hist(path: Path):
    try:
        data = json.loads(Path(path).read_text() or "[]")
        return data if isinstance(data, list) else []
    except Exception:
        return []


def append_sample(path: Path, sample: dict, min_gap: int = SAMPLE_MIN_GAP):
    path = Path(path)
    hist = load_hist(path)
    now_ts = time.time()
    if hist and now_ts - float(hist[-1].get("ts") or 0) < min_gap:
        last = hist[-1]
        # Meta nachziehen (nodedb/heard), ohne neuen Punkt
        changed = False
        for k in ("nodedb", "heard_sec"):
            if last.get(k) is None and sample.get(k) is not None:
                last[k] = sample.get(k)
                changed = True
        if changed:
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(hist, ensure_ascii=False))
            tmp.replace(path)
            return True, last
        return False, last
    point = {
        "ts": now_ts,
        "t": datetime.now().strftime("%d.%m. %H:%M"),
        "ch_util": sample.get("ch_util"),
        "air_tx": sample.get("air_tx"),
        "node": sample.get("node") or "",
        "local": bool(sample.get("local")),
        "nodedb": sample.get("nodedb"),
        "heard_sec": sample.get("heard_sec"),
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


def _window(hist, hours: float):
    now_ts = time.time()
    return [p for p in hist if now_ts - float(p.get("ts") or 0) <= hours * 3600]


def _avg_peak(win):
    vals = []
    for p in win:
        v = p.get("ch_util")
        if v is None:
            continue
        try:
            vals.append(float(v))
        except Exception:
            pass
    if not vals:
        return None, None
    return round(sum(vals) / len(vals), 2), round(max(vals), 2)


def threshold_streak(hist, threshold: float = THRESH_YELLOW):
    """Wenn aktueller Wert >= threshold: Start der durchgehenden Überschreitung (rückwärts)."""
    if not hist:
        return None
    cur = hist[-1]
    try:
        ch = float(cur.get("ch_util"))
    except Exception:
        return None
    if ch < threshold:
        return None
    start = cur
    for p in reversed(hist):
        try:
            v = float(p.get("ch_util"))
        except Exception:
            break
        if v < threshold:
            break
        start = p
    since_ts = float(start.get("ts") or 0)
    sec = max(0, int(time.time() - since_ts))
    return {
        "ch": ch,
        "threshold": threshold,
        "since_t": start.get("t") or "",
        "since_ts": since_ts,
        "sec": sec,
        "level": "red" if ch >= THRESH_RED else "yellow",
    }


def fmt_duration(sec):
    if sec is None:
        return ""
    sec = int(sec)
    if sec < 60:
        return f"{sec} s"
    if sec < 3600:
        return f"{sec // 60} min"
    h = sec // 3600
    m = (sec % 3600) // 60
    if h < 48:
        return f"{h} h {m} min" if m else f"{h} h"
    return f"{h // 24} d {h % 24} h"



def detect_stuck(hist):  # meshHang
    """Flatline: gleiche ch_util+air_tx über genug Punkte und Dauer."""
    if not hist or len(hist) < STUCK_MIN_POINTS:
        return None
    try:
        ch0 = round(float(hist[-1].get("ch_util")), 2)
        tx0 = round(float(hist[-1].get("air_tx") or 0), 3)
    except Exception:
        return None
    start = hist[-1]
    count = 0
    for p in reversed(hist):
        try:
            ch = round(float(p.get("ch_util")), 2)
            tx = round(float(p.get("air_tx") or 0), 3)
        except Exception:
            break
        if ch != ch0 or tx != tx0:
            break
        start = p
        count += 1
    if count < STUCK_MIN_POINTS:
        return None
    since_ts = float(start.get("ts") or 0)
    end_ts = float(hist[-1].get("ts") or time.time())
    span = max(0, int(end_ts - since_ts))
    if span < STUCK_MIN_SEC:
        return None
    sec = max(0, int(time.time() - since_ts))
    return {
        "since_t": start.get("t") or "",
        "since_ts": since_ts,
        "sec": sec,
        "ch_util": ch0,
        "air_tx": tx0,
        "points": count,
    }


def tele_health(hist):  # meshHang
    """Telemetrie-Zustand: ok|stuck|stale|none + Farben für /funk."""
    stuck = detect_stuck(hist) if hist else None
    heard_sec = None
    if hist:
        try:
            hs = hist[-1].get("heard_sec")
            heard_sec = int(hs) if hs is not None else None
        except Exception:
            heard_sec = None
    if stuck:
        state = "stuck"
        color = "#eab308"
        if int(stuck.get("sec") or 0) >= 7200:
            color = "#ef4444"
    elif heard_sec is not None and heard_sec > HEARD_STALE_SEC:
        state = "stale"
        color = "#eab308"
    elif hist:
        state = "ok"
        color = "#22c55e"
    else:
        state = "none"
        color = "#94a3b8"
    return {
        "state": state,
        "stuck": stuck,
        "heard_sec": heard_sec,
        "color": color,
        "tele_state": state,
        "tele_color": color,
    }


def hist_payload(path: Path, hours: float = 24):
    hist = load_hist(path)
    now_ts = time.time()
    win = _window(hist, hours)
    if not win and hist:
        win = hist[-min(len(hist), 200):]
    cur = hist[-1] if hist else None
    w24 = _window(hist, 24)
    w7 = _window(hist, 24 * 7)
    avg24, peak24 = _avg_peak(w24)
    avg7, peak7 = _avg_peak(w7)
    streak = threshold_streak(hist, THRESH_YELLOW)
    hint = None
    if streak:
        hint = (
            f"Kanal über {int(streak['threshold'])} % seit {streak['since_t'] or '?'} "
            f"({fmt_duration(streak['sec'])})"
        )
    # meshHang: stuck/tele getrennt von Kanal-%-Ampel
    stuck = detect_stuck(hist)
    tele = tele_health(hist)
    stuck_hint = None
    if stuck:
        stuck_hint = (
            f"Telemetrie stuck seit {stuck.get('since_t') or '?'} "
            f"({fmt_duration(stuck.get('sec'))}, gleicher Kanalwert "
            f"{stuck.get('ch_util')} % / Air-TX {stuck.get('air_tx')} %)"
        )
    return {
        "ok": True,
        "at": now_str(),
        "current": cur,
        "points": len(win),
        "hist_t": [p.get("t") for p in win],
        "hist_ch": [p.get("ch_util") for p in win],
        "hist_tx": [p.get("air_tx") for p in win],
        "avg_24h": avg24,
        "peak_24h": peak24,
        "avg_7d": avg7,
        "peak_7d": peak7,
        "hint": hint,
        "streak": streak,
        "nodedb": (cur or {}).get("nodedb"),
        "heard_sec": (cur or {}).get("heard_sec"),
        "stuck": stuck,
        "stuck_hint": stuck_hint,
        "tele_state": tele.get("state"),
        "tele_color": tele.get("color"),
    }
