#!/usr/bin/env python3
"""Ping/Test Reply-Watch: last_rx/last_tx pro Mesh. # meshHang"""
from __future__ import annotations

import json
import time
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")

_KEY_FILE = {
    "m1": "mesh1_reply.json",
    "mesh1": "mesh1_reply.json",
    "m2": "mesh2_reply.json",
    "mesh2": "mesh2_reply.json",
}


def _path(mesh_key: str) -> Path:
    name = _KEY_FILE.get(str(mesh_key).strip().lower())
    if not name:
        name = f"{mesh_key}_reply.json"
    return BASE / name


def _load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text() or "{}")
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save(path: Path, data: dict) -> None:
    path = Path(path)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    tmp.replace(path)


def note_rx(mesh_key, from_id=None):  # meshHang
    path = _path(mesh_key)
    d = _load(path)
    now = time.time()
    d["last_rx_ts"] = now
    d["last_rx_from"] = str(from_id) if from_id is not None else d.get("last_rx_from")
    d["rx_count"] = int(d.get("rx_count") or 0) + 1
    if "tx_count" not in d:
        d["tx_count"] = int(d.get("tx_count") or 0)
    if "last_tx_ts" not in d:
        d["last_tx_ts"] = d.get("last_tx_ts")
    _save(path, d)
    return d


def note_tx(mesh_key, to_id=None):  # meshHang
    path = _path(mesh_key)
    d = _load(path)
    now = time.time()
    d["last_tx_ts"] = now
    d["last_tx_to"] = str(to_id) if to_id is not None else d.get("last_tx_to")
    d["tx_count"] = int(d.get("tx_count") or 0) + 1
    if "rx_count" not in d:
        d["rx_count"] = int(d.get("rx_count") or 0)
    if "last_rx_ts" not in d:
        d["last_rx_ts"] = d.get("last_rx_ts")
    _save(path, d)
    return d


def status(mesh_key, stale_sec=3600):  # meshHang
    """ok|stumm|unbekannt — silent wenn RX ohne zeitnahe TX danach."""
    path = _path(mesh_key)
    d = _load(path)
    now = time.time()
    rx_ts = d.get("last_rx_ts")
    tx_ts = d.get("last_tx_ts")
    try:
        rx_ts = float(rx_ts) if rx_ts is not None else None
    except Exception:
        rx_ts = None
    try:
        tx_ts = float(tx_ts) if tx_ts is not None else None
    except Exception:
        tx_ts = None

    last_rx_age = int(now - rx_ts) if rx_ts is not None else None
    last_tx_age = int(now - tx_ts) if tx_ts is not None else None

    if rx_ts is None and tx_ts is None:
        return {
            "ok": False,
            "last_rx_age": None,
            "last_tx_age": None,
            "silent": False,
            "state": "unbekannt",
            "rx_count": int(d.get("rx_count") or 0),
            "tx_count": int(d.get("tx_count") or 0),
        }

    # silent: hatten RX, aber keine TX danach (oder TX deutlich älter)
    silent = False
    if rx_ts is not None:
        if tx_ts is None:
            silent = True
        elif tx_ts < rx_ts - 5:  # TX vor dem RX → Antwort fehlt
            silent = True
        elif (rx_ts - tx_ts) > 120 and last_tx_age is not None and last_tx_age > 300:
            # TX viel älter als RX
            silent = True
        # Wenn TX nach RX: ok (auch wenn alt), solange Antwort kam
        elif tx_ts >= rx_ts - 5:
            silent = False

    # Wenn letzte Aktivität sehr alt und keine frische RX: unbekannt eher als stumm?
    # Spec: state ok|stumm|unbekannt — stumm wenn silent
    if silent:
        state = "stumm"
        ok = False
    elif last_rx_age is not None and last_rx_age <= stale_sec:
        state = "ok"
        ok = True
    elif last_tx_age is not None and last_tx_age <= stale_sec:
        state = "ok"
        ok = True
    else:
        # Daten vorhanden aber alt — nicht silent → ok wenn antwortete, sonst unbekannt
        if tx_ts is not None and rx_ts is not None and tx_ts >= rx_ts - 5:
            state = "ok"
            ok = True
        else:
            state = "unbekannt"
            ok = False

    return {
        "ok": ok,
        "last_rx_age": last_rx_age,
        "last_tx_age": last_tx_age,
        "silent": silent,
        "state": state,
        "rx_count": int(d.get("rx_count") or 0),
        "tx_count": int(d.get("tx_count") or 0),
        "last_rx_from": d.get("last_rx_from"),
        "last_tx_to": d.get("last_tx_to"),
    }
