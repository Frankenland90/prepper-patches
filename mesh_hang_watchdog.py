#!/usr/bin/env python3
"""Mesh Hang Watchdog: stuck Telemetrie + Reply-Stumm → Status JSON, optional Restart. # meshHang"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
STATUS_FILE = BASE / "mesh_hang_status.json"
COOLDOWN_FILE = BASE / "mesh_hang_watchdog_cooldown.json"
LOG_FILE = BASE / "mesh_hang_watchdog.log"
AUTORESTART_FLAG = BASE / "secrets" / "mesh_hang_autorestart"

STUCK_ACTION_SEC = 2700  # 45 min
COOLDOWN_SEC = 2 * 3600  # 2h

MESHES = {
    "m1": {
        "chutil": "mesh1_chutil.json",
        "bridge_svc": "mesh-bridge.service",
        "ping_svc": "mesh-ping-reply.service",
        "name": "Mesh1",
    },
    "m2": {
        "chutil": "mesh2_chutil.json",
        "bridge_svc": "mesh-bridge-bayern.service",
        "ping_svc": "mesh-ping-reply-2.service",
        "name": "Mesh2",
    },
}


def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def log(msg: str) -> None:
    line = f"{now_str()} {msg}"
    print(line, flush=True)
    try:
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _load_json(path: Path, default):
    try:
        data = json.loads(path.read_text() or "")
        return data if data is not None else default
    except Exception:
        return default


def _save_json(path: Path, data) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    tmp.replace(path)


def _cooldown_ok(mesh_key: str) -> bool:
    d = _load_json(COOLDOWN_FILE, {})
    if not isinstance(d, dict):
        d = {}
    last = d.get(mesh_key)
    try:
        last = float(last) if last is not None else 0.0
    except Exception:
        last = 0.0
    return (time.time() - last) >= COOLDOWN_SEC


def _mark_cooldown(mesh_key: str) -> None:
    d = _load_json(COOLDOWN_FILE, {})
    if not isinstance(d, dict):
        d = {}
    d[mesh_key] = time.time()
    _save_json(COOLDOWN_FILE, d)


def _autorestart_enabled() -> bool:
    if os.environ.get("MESH_HANG_WATCHDOG") == "1" and AUTORESTART_FLAG.exists():
        return True
    return AUTORESTART_FLAG.exists()


def _systemctl_restart(units: list[str], dry_run: bool) -> list[str]:
    done = []
    for u in units:
        if dry_run:
            log(f"DRY-RUN would restart {u}")
            done.append(u)
            continue
        try:
            r = subprocess.run(
                ["systemctl", "restart", u],
                capture_output=True,
                text=True,
                timeout=60,
            )
            if r.returncode == 0:
                log(f"restarted {u}")
                done.append(u)
            else:
                log(f"FAIL restart {u}: {r.stderr or r.stdout}")
        except Exception as e:
            log(f"FAIL restart {u}: {e}")
    return done


def evaluate_one(mesh_key: str, cfg: dict) -> dict:
    import mesh_chutil
    import mesh_reply_watch

    hist = mesh_chutil.load_hist(BASE / cfg["chutil"])
    stuck = mesh_chutil.detect_stuck(hist)
    tele = mesh_chutil.tele_health(hist)
    reply = mesh_reply_watch.status(mesh_key, stale_sec=3600)

    stuck_sec = int(stuck.get("sec") or 0) if stuck else 0
    reply_state = reply.get("state") or "unbekannt"
    silent = bool(reply.get("silent"))

    recommend_restart = False
    reason = None
    if stuck and stuck_sec >= STUCK_ACTION_SEC:
        if silent or reply_state == "stumm" or (
            reply_state == "unbekannt" and stuck
        ):
            recommend_restart = True
            reason = (
                f"stuck {stuck_sec}s (>= {STUCK_ACTION_SEC}) + reply {reply_state}"
                + (" silent" if silent else "")
            )

    return {
        "mesh": mesh_key,
        "name": cfg["name"],
        "tele_state": tele.get("state"),
        "tele_color": tele.get("color"),
        "stuck": stuck,
        "stuck_sec": stuck_sec if stuck else None,
        "reply": reply,
        "recommend_restart": recommend_restart,
        "reason": reason,
        "bridge_svc": cfg["bridge_svc"],
        "ping_svc": cfg["ping_svc"],
    }


def run(dry_run: bool = True, enable_restart: bool = False) -> dict:
    results = {}
    actions = []
    allow = enable_restart or _autorestart_enabled()
    # Env MESH_HANG_WATCHDOG=1 alone is not enough — need flag file OR --enable-restart
    # Spec: Autorestart OFF unless secrets/mesh_hang_autorestart exists
    allow_restart = AUTORESTART_FLAG.exists() if not enable_restart else True
    if enable_restart:
        allow_restart = True
    else:
        allow_restart = AUTORESTART_FLAG.exists()

    for key, cfg in MESHES.items():
        try:
            info = evaluate_one(key, cfg)
        except Exception as e:
            info = {
                "mesh": key,
                "name": cfg["name"],
                "error": str(e),
                "recommend_restart": False,
            }
            log(f"{key} evaluate error: {e}")
        results[key] = info

        if info.get("recommend_restart"):
            log(f"{key}: EMPFEHLUNG Restart — {info.get('reason')}")
            if allow_restart and not dry_run:
                if not _cooldown_ok(key):
                    log(f"{key}: cooldown aktiv — kein Restart")
                    info["action"] = "cooldown"
                else:
                    units = [cfg["bridge_svc"]]
                    # ping reply if unit exists
                    units.append(cfg["ping_svc"])
                    done = _systemctl_restart(units, dry_run=False)
                    _mark_cooldown(key)
                    info["action"] = "restarted"
                    info["restarted"] = done
                    actions.append({"mesh": key, "units": done})
            elif allow_restart and dry_run:
                log(f"{key}: DRY-RUN Restart {cfg['bridge_svc']} + {cfg['ping_svc']}")
                info["action"] = "dry-run"
            else:
                info["action"] = "detect-only"
                log(f"{key}: detect-only (kein Autorestart-Flag)")

    out = {
        "at": now_str(),
        "ts": time.time(),
        "dry_run": dry_run,
        "autorestart_enabled": allow_restart,
        "flag": str(AUTORESTART_FLAG),
        "meshes": results,
        "actions": actions,
    }
    _save_json(STATUS_FILE, out)
    log(f"status written {STATUS_FILE} autorestart={allow_restart}")
    return out


def main():
    ap = argparse.ArgumentParser(description="Mesh Hang Watchdog # meshHang")
    ap.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Nur loggen, keine Restarts (Status wird trotzdem geschrieben)",
    )
    ap.add_argument(
        "--apply",
        action="store_true",
        help="Restarts ausführen wenn Flag/enable gesetzt",
    )
    ap.add_argument(
        "--enable-restart",
        action="store_true",
        help="Restarts erlauben auch ohne Flag-Datei (vorsichtig)",
    )
    args = ap.parse_args()
    dry = True
    if args.apply and not args.dry_run:
        dry = False
    if args.dry_run:
        dry = True
    # Default when run from timer: detect-only write status (dry regarding restarts)
    # Timer should call without --apply → dry_run path for restarts
    if not args.apply:
        dry = True
    run(dry_run=dry, enable_restart=args.enable_restart)


if __name__ == "__main__":
    main()
