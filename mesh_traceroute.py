#!/usr/bin/env python3
"""Mesh1 traceroute history + SNR parse. # meshTrace"""
from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path

# meshTrace
UNK_SNR = -128
HIST_HOURS = 48
HIST_MAX = 80  # ~48h @ 1/h + Puffer
DEFAULT_FILE = Path("/home/fmg/prepper-dashboard/mesh1_traceroute.json")
TRACE_DEST_DEFAULT = "!4191a2ef"


def now_str() -> str:
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def _snr_db(raw):
    """SNR scaled by 4; -128 = unknown → None."""
    if raw is None:
        return None
    try:
        v = int(raw)
    except Exception:
        try:
            v = int(float(raw))
        except Exception:
            return None
    if v == UNK_SNR:
        return None
    return round(v / 4.0, 2)


def _as_list(obj, *names):
    if obj is None:
        return []
    if isinstance(obj, dict):
        for n in names:
            if n in obj and obj[n] is not None:
                val = obj[n]
                if isinstance(val, (list, tuple)):
                    return list(val)
                return [val]
        return []
    for n in names:
        if hasattr(obj, n):
            val = getattr(obj, n)
            if val is None:
                continue
            try:
                return list(val)
            except Exception:
                return [val]
    return []


def parse_route_discovery(payload) -> dict:
    """Extract final snrTowards / snrBack (dB) and hop counts from RouteDiscovery."""
    if payload is None:
        return {
            "snr_towards": None,
            "snr_back": None,
            "hops_towards": None,
            "hops_back": None,
            "raw": None,
        }
    # decoded packet may nest under traceroute / routeDiscovery
    if isinstance(payload, dict):
        for nest in ("traceroute", "routeDiscovery", "route_discovery"):
            if nest in payload and payload[nest] is not None:
                payload = payload[nest]
                break
        if "decoded" in payload and isinstance(payload["decoded"], dict):
            dec = payload["decoded"]
            for nest in ("traceroute", "routeDiscovery", "route_discovery"):
                if nest in dec and dec[nest] is not None:
                    payload = dec[nest]
                    break

    snr_t = _as_list(payload, "snrTowards", "snr_towards")
    snr_b = _as_list(payload, "snrBack", "snr_back")
    route_t = _as_list(payload, "route")
    route_b = _as_list(payload, "routeBack", "route_back")

    snr_towards = _snr_db(snr_t[-1]) if snr_t else None
    snr_back = _snr_db(snr_b[-1]) if snr_b else None

    hops_towards = len(route_t) if route_t else (max(0, len(snr_t) - 1) if snr_t else None)
    hops_back = len(route_b) if route_b else (max(0, len(snr_b) - 1) if snr_b else None)

    return {
        "snr_towards": snr_towards,
        "snr_back": snr_back,
        "hops_towards": hops_towards,
        "hops_back": hops_back,
        "raw": {
            "snrTowards": snr_t,
            "snrBack": snr_b,
            "route": route_t,
            "routeBack": route_b,
        },
    }


def load_hist(path: Path | None = None) -> list:
    path = Path(path or DEFAULT_FILE)
    try:
        data = json.loads(path.read_text() or "[]")
        return data if isinstance(data, list) else []
    except Exception:
        return []


def prune(hist: list, hours: float = HIST_HOURS) -> list:
    cut = time.time() - hours * 3600
    out = [p for p in hist if float(p.get("ts") or 0) >= cut]
    return out[-HIST_MAX:]


def append_sample(path: Path | None, sample: dict) -> dict:
    """Append traceroute sample; prune to 48h+. Returns stored point."""
    path = Path(path or DEFAULT_FILE)
    hist = load_hist(path)
    now_ts = time.time()
    point = {
        "ts": now_ts,
        "t": datetime.now().strftime("%d.%m. %H:%M"),
        "ok": bool(sample.get("ok")),
        "snr_towards": sample.get("snr_towards"),
        "snr_back": sample.get("snr_back"),
        "hops_towards": sample.get("hops_towards"),
        "hops_back": sample.get("hops_back"),
        "error": sample.get("error"),
        "dest": sample.get("dest") or TRACE_DEST_DEFAULT,
    }
    hist.append(point)
    hist = prune(hist)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(hist, ensure_ascii=False))
    tmp.replace(path)
    return point


def consecutive_fails(path: Path | None = None) -> int:
    """Count trailing ok=false samples."""
    hist = load_hist(path)
    n = 0
    for p in reversed(hist):
        if p.get("ok"):
            break
        n += 1
    return n


def last_sample(path: Path | None = None) -> dict | None:
    hist = load_hist(path)
    return hist[-1] if hist else None


def hist_payload(path: Path | None = None, hours: float = HIST_HOURS) -> dict:
    """Chart + status payload for /funk and /traceroute."""
    path = Path(path or DEFAULT_FILE)
    hist = prune(load_hist(path), hours=hours)
    labels, snr_t, snr_b, oks = [], [], [], []
    for p in hist:
        labels.append(p.get("t") or "")
        snr_t.append(p.get("snr_towards"))
        snr_b.append(p.get("snr_back"))
        oks.append(bool(p.get("ok")))
    last = hist[-1] if hist else None
    fails = 0
    for p in reversed(hist):
        if p.get("ok"):
            break
        fails += 1
    age = None
    if last and last.get("ts"):
        try:
            age = max(0, int(time.time() - float(last["ts"])))
        except Exception:
            age = None
    return {
        "ok": True,
        "dest": (last or {}).get("dest") or TRACE_DEST_DEFAULT,
        "current": last,
        "at": now_str() if last else "",
        "age_sec": age,
        "consecutive_fails": fails,
        "hist_t": labels,
        "hist_snr_towards": snr_t,
        "hist_snr_back": snr_b,
        "hist_ok": oks,
        "n": len(hist),
    }


def store_result(
    path: Path | None,
    *,
    ok: bool,
    dest: str = TRACE_DEST_DEFAULT,
    snr_towards=None,
    snr_back=None,
    hops_towards=None,
    hops_back=None,
    error=None,
    payload=None,
) -> dict:
    """Convenience: parse payload if given, then append."""
    parsed = {}
    if payload is not None:
        parsed = parse_route_discovery(payload)
    return append_sample(
        path,
        {
            "ok": ok,
            "dest": dest,
            "snr_towards": snr_towards if snr_towards is not None else parsed.get("snr_towards"),
            "snr_back": snr_back if snr_back is not None else parsed.get("snr_back"),
            "hops_towards": hops_towards if hops_towards is not None else parsed.get("hops_towards"),
            "hops_back": hops_back if hops_back is not None else parsed.get("hops_back"),
            "error": error,
        },
    )
