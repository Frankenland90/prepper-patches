#!/bin/bash
set -euo pipefail
# mesh2OneSession: Mesh2 bekommt genau EINE TCP-Session (die Bridge).
# - mesh-ping-reply-2 aus + maskiert (war der zweite Client, Ursache seit 5.10.)
# - Bridge: Status-JSON, Keeper-Reconnect, Reconnect vor dem Senden, Ping bleibt in der Bridge
# - Funk-Seite: rotes/gelbes Banner bei 2 Sessions, Abbruechen, Stille, Bridge getrennt
# - Probe-Connects (/funk, /pi) nur noch wenn keine Session besteht
# Smoke nur :8080 mit curl --compressed. /energie 302 ist ok.
# Aendert nie update_all() # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
# Stufe A (Bridge) und Stufe B (Funk/Dashboard) rollen bei Fehler einzeln zurueck.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
BRIDGE="$DASH_DIR/mesh_bridge_bayern.py"
FUNK="$DASH_DIR/funk_health.py"
DASH="$DASH_DIR/dashboard.py"
HANG="$DASH_DIR/mesh_hang_watchdog.py"
MSESS="$DASH_DIR/mesh_session.py"
STATUS="$DASH_DIR/mesh2_session.json"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"
W=/tmp/m2os
EXPECT_PATCH="3d60acca269a0752f1cdb4e7e08c0e529f47616bfac9cc79628ec3d86ace8ed8"
EXPECT_MSESS="9058ea53453352b215865eecd1f7def706b9d8ed40df44a0972e7f113a65cada"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-mesh2-onesession.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""mesh2OneSession: eine TCP-Session zu Mesh2 + Warnung auf der Funk-Seite.

Patcht (idempotent, Marker mesh2OneSession):
  mesh_bridge_bayern.py  PFLICHT  Status-JSON, Keeper-Reconnect, Reconnect vor Senden,
                                  Ping-Antwort nur falls die Bridge keine hat
  funk_health.py         PFLICHT  mesh_session.install(app) -> Banner + /api/funk/mesh_session
                         weich    Mesh-Status ohne Probe-Connect (Dienst = Bridge)
  dashboard.py           weich    Probe-Connects nur wenn keine Session besteht,
                                  Dienst-Anzeige = Bridge statt mesh-ping-reply*
  mesh_hang_watchdog.py  weich    startet mesh-ping-reply-2 nicht mehr neu
Fehlt ein PFLICHT-Anker: Exit 2, es wird NICHTS geschrieben.
Aendert nie update_all() # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

MARK = "mesh2OneSession"

BRIDGE_BLOCK = r'''
# ===== mesh2OneSession: eine TCP-Session zu Mesh2, Status-JSON, Reconnect vor Senden =====
import os as _m2os_os
import json as _m2os_json
import time as _m2os_time
import logging as _m2os_logging
import threading as _m2os_threading
from collections import deque as _m2os_deque
from pathlib import Path as _m2os_Path

M2OS_STATUS_FILE = _m2os_Path("/home/fmg/prepper-dashboard/mesh2_session.json")  # mesh2OneSession
M2OS_STALE_RECONNECT = 20 * 60   # so lange kein Paket -> sauber neu verbinden
M2OS_PRESEND_STALE = 10 * 60     # vor dem Senden: Verbindung aelter + stumm -> erst neu verbinden
M2OS_KEEPER_EVERY = 10
M2OS_ADD_PONG = __M2OS_ADD_PONG__  # True nur wenn die Bridge selbst keine Ping-Antwort hatte
M2OS_PONG_COOLDOWN = 20
_m2os_conn_lock = _m2os_threading.RLock()
_m2os = {
    "last_pkt": 0.0, "connected_at": 0.0, "events": _m2os_deque(maxlen=600),
    "last_err": "", "last_err_at": None, "hooked": False, "dirty": True,
    "last_write": 0.0, "pong_last": {}, "closing": 0, "closed_ids": _m2os_deque(maxlen=20),
    "reason": "", "started_at": 0.0,
}


def _m2os_event(kind, err=None):
    try:
        _m2os["events"].append((_m2os_time.time(), kind))
        if err:
            _m2os["last_err"] = str(err)[:160]
            _m2os["last_err_at"] = now_str()
        _m2os["dirty"] = True
    except Exception:
        pass


def _m2os_counts(window=3600):
    cut = _m2os_time.time() - window
    c = {}
    for ts, k in list(_m2os["events"]):
        if ts >= cut:
            c[k] = c.get(k, 0) + 1
    return c


class _M2osLogHook(_m2os_logging.Handler):
    def emit(self, record):
        try:
            low = record.getMessage().lower()
        except Exception:
            return
        if ("reconnect" in low or "re-connect" in low or "broken pipe" in low
                or "connection reset" in low):
            _m2os_event("libreconnect", record.getMessage())


def _m2os_on_lost(interface=None):
    try:
        if _m2os["closing"] or (interface is not None and id(interface) in _m2os["closed_ids"]):
            return  # selbst geschlossen (Reconnect/Hold) - kein Fehler
        if _iface is None or (interface is not None and interface is not _iface):
            return
        _state["connected"] = False
        _m2os_event("lost", "Verbindung verloren")
        log("mesh2OneSession: Verbindung verloren - Keeper verbindet neu")
    except Exception:
        pass


def _m2os_hook():
    if _m2os["hooked"]:
        return
    _m2os["hooked"] = True
    try:
        from pubsub import pub as _m2os_pub
        _m2os_pub.subscribe(_m2os_on_lost, "meshtastic.connection.lost")
    except Exception as e:
        log("mesh2OneSession lost-hook:", e)
    try:
        h = _M2osLogHook()
        h.setLevel(_m2os_logging.WARNING)
        _m2os_logging.getLogger("meshtastic").addHandler(h)
    except Exception:
        pass


def _m2os_dead():
    if _iface is None or not _state.get("connected"):
        return True
    try:
        ev = getattr(_iface, "isConnected", None)
        if ev is not None and hasattr(ev, "is_set") and not ev.is_set():
            return True
    except Exception:
        pass
    return False


_m2os_orig_close_iface = close_iface


def close_iface(*a, **kw):  # mesh2OneSession: eigenes Schliessen nicht als Abbruch zaehlen
    _m2os["closing"] += 1
    try:
        if _iface is not None:
            _m2os["closed_ids"].append(id(_iface))
        return _m2os_orig_close_iface(*a, **kw)
    finally:
        _m2os["closing"] -= 1


def _m2os_wrap_lib_reconnect(iface):
    """Neuere meshtastic-Libs verbinden nach Rauswurf still neu: mitzaehlen."""
    try:
        orig = getattr(iface, "_reconnect", None)
        if not callable(orig) or getattr(orig, "_m2os", False):
            return

        def _rc(*a, **kw):
            if not _m2os["closing"] and not getattr(iface, "_wantExit", False):
                _m2os_event("libreconnect", "vom Funkgeraet getrennt, Lib verbindet neu")
            return orig(*a, **kw)
        _rc._m2os = True
        iface._reconnect = _rc
    except Exception:
        pass


_m2os_orig_connect = connect


def connect(*a, **kw):  # mesh2OneSession: serialisiert, nie zwei Sessions gleichzeitig
    with _m2os_conn_lock:
        if (not _m2os_dead()
                and _m2os_time.time() - _m2os["connected_at"] < 5):
            return _iface  # paralleler Reconnect hat gerade verbunden
        first = not _m2os["connected_at"]
        try:
            iface = _m2os_orig_connect(*a, **kw)
        except Exception as e:
            _m2os_event("connect_fail", e)
            raise
        _m2os["connected_at"] = _m2os_time.time()
        if first:
            _m2os["started_at"] = _m2os["connected_at"]
        elif _m2os.get("reason") == "stale":
            _m2os_event("reconnect_planned")
        else:
            _m2os_event("reconnect")
        _m2os["reason"] = ""
        _m2os["dirty"] = True
        _m2os_hook()
        _m2os_wrap_lib_reconnect(iface)
        return iface


_m2os_orig_on_receive = on_receive


def _m2os_pong(packet):
    try:
        decoded = packet.get("decoded") or {}
        text = (decoded.get("text") or "").strip().lower()
        if text not in ("ping", "test"):
            return
        if "_is_self" in globals() and _is_self(packet):
            return
        ch = packet_channel(packet) if "packet_channel" in globals() else 0
        if ch != 0:
            return
        fid = _from_id(packet) if "_from_id" in globals() else str(packet.get("fromId") or packet.get("from"))
        now = _m2os_time.time()
        if now - _m2os["pong_last"].get(fid, 0) < M2OS_PONG_COOLDOWN:
            return
        _m2os["pong_last"][fid] = now
        try:
            import mesh_node_label as _m2os_mnl
            label = _m2os_mnl.label_from_iface(_iface, fid)
        except Exception:
            label = fid
        t = datetime.now().strftime("%H:%M:%S")
        snr, rssi = packet.get("rxSnr"), packet.get("rxRssi")
        hops = _hops(packet) if "_hops" in globals() else "–"
        reply = (
            f"{STATION}\nEmpfang {t}\nAntwort {t}\n"
            f"SNR {snr if snr is not None else '–'} dB · RSSI {rssi if rssi is not None else '–'} dBm\n"
            f"Hops {hops} · von {label}"
        )
        log("Pong-Trigger:", text, "von", label, "(mesh2OneSession)")
        try:
            import mesh_reply_watch as _m2os_mrw
            _m2os_mrw.note_rx("m2")
        except Exception:
            pass
        _send_q.put_nowait({"text": reply, "channel": 0})
        _state["queued"] = _send_q.qsize()
    except Exception as e:
        log("mesh2OneSession pong:", e)


def on_receive(packet, interface=None):  # mesh2OneSession: jedes Paket = Lebenszeichen
    try:
        if interface is None or interface is _iface:
            _m2os["last_pkt"] = _m2os_time.time()
    except Exception:
        pass
    if M2OS_ADD_PONG and packet:
        _m2os_pong(packet)
    return _m2os_orig_on_receive(packet, interface)


def _m2os_presend():
    if is_held():
        return
    now = _m2os_time.time()
    dead = _m2os_dead()
    ref = max(_m2os["last_pkt"], _m2os["connected_at"])
    stale = (not dead) and ref > 0 and (now - ref) > M2OS_PRESEND_STALE
    if not (dead or stale):
        return
    _m2os["reason"] = "dead" if dead else "stale"
    if dead:
        log("mesh2OneSession: vor Senden neu verbinden (Verbindung tot)")
    else:
        log("mesh2OneSession: vor Senden neu verbinden (kein Paket seit %d s)" % int(now - ref))
        _m2os_event("stale")
    with _lock:
        connect()


_m2os_orig_send_now = send_now


def send_now(*a, **kw):  # mesh2OneSession: erst pruefen, dann genau ein Sendeversuch
    try:
        _m2os_presend()
    except Exception as e:
        log("mesh2OneSession presend:", e)
    ok = _m2os_orig_send_now(*a, **kw)
    if not ok:
        _m2os_event("send_fail", _state.get("last_error") or "Senden fehlgeschlagen")
    _m2os["dirty"] = True
    return ok


def _m2os_write(force=False):
    now = _m2os_time.time()
    if not force and not _m2os["dirty"] and now - _m2os["last_write"] < 60:
        return
    c = _m2os_counts()
    lp = _m2os["last_pkt"] or None
    try:
        held = bool(is_held())
    except Exception:
        held = False
    try:
        q = _send_q.qsize()
    except Exception:
        q = None
    d = {
        "marker": "mesh2OneSession", "v": 1, "at": now_str(), "ts": now,
        "pid": _m2os_os.getpid(), "host": HOST,
        "connected": bool(_iface is not None and _state.get("connected") and not _m2os_dead()),
        "held": held, "hold_until": _state.get("hold_until"),
        "connected_at": _m2os["connected_at"] or None,
        "last_pkt": lp, "last_pkt_age": int(now - lp) if lp else None,
        "reconnects_1h": c.get("reconnect", 0),
        "errors_1h": sum(c.get(k, 0) for k in ("connect_fail", "send_fail", "lost", "libreconnect")),
        "stale_1h": c.get("stale", 0), "planned_1h": c.get("reconnect_planned", 0), "counts_1h": c,
        "started_at": _m2os["started_at"] or None,
        "last_error": _m2os["last_err"] or _state.get("last_error") or "",
        "last_error_at": _m2os["last_err_at"],
        "sent_ok": _state.get("sent_ok"), "sent_fail": _state.get("sent_fail"), "queued": q,
    }
    tmp = M2OS_STATUS_FILE.with_name(M2OS_STATUS_FILE.name + ".tmp")
    tmp.write_text(_m2os_json.dumps(d, ensure_ascii=False))
    _m2os_os.replace(str(tmp), str(M2OS_STATUS_FILE))
    _m2os["dirty"] = False
    _m2os["last_write"] = now


def _m2os_keeper():
    backoff = 10
    next_try = 0.0
    first = True
    while True:
        _m2os_time.sleep(3 if first else M2OS_KEEPER_EVERY)
        first = False
        try:
            now = _m2os_time.time()
            if not is_held():
                dead = _m2os_dead()
                ref = max(_m2os["last_pkt"], _m2os["connected_at"])
                stale = (not dead) and ref > 0 and (now - ref) > M2OS_STALE_RECONNECT
                busy = not _m2os_conn_lock.acquire(blocking=False)
                if not busy:
                    _m2os_conn_lock.release()
                if (dead or stale) and not busy and now >= next_try:
                    _m2os["reason"] = "stale" if stale else "dead"
                    if stale:
                        _m2os_event("stale")
                        log("mesh2OneSession: %d min kein Paket - neu verbinden" % int((now - ref) // 60))
                    else:
                        log("mesh2OneSession: Keeper verbindet neu")
                    try:
                        with _lock:
                            connect()
                        backoff = 10
                        next_try = 0.0
                    except Exception as e:
                        _state["ok"] = False
                        _state["last_error"] = str(e)[:160]
                        log("mesh2OneSession Keeper:", e)
                        next_try = now + backoff
                        backoff = min(backoff * 2, 300)
            _m2os_write()
        except Exception as e:
            log("mesh2OneSession keeper:", e)


_m2os_orig_main = main


def main(*a, **kw):  # mesh2OneSession
    _m2os_threading.Thread(target=_m2os_keeper, daemon=True, name="m2os-keeper").start()
    log("mesh2OneSession aktiv: eine TCP-Session, Keeper alle", M2OS_KEEPER_EVERY, "s")
    return _m2os_orig_main(*a, **kw)
# ===== /mesh2OneSession =====

'''

FUNK_INSTALL = (
    "    try:  # mesh2OneSession: Mesh-Problem-Banner + /api/funk/mesh_session\n"
    "        import mesh_session as _m2os_ms\n"
    "        _m2os_ms.install(app)\n"
    "    except Exception as _m2os_e:\n"
    "        print(\"mesh_session:\", _m2os_e)\n"
)

PROTECT_LINE = "update_all()  # einmal beim Start"


# ---------------------------------------------------------------- guards
def guard_counts(src: str) -> dict:
    tree = ast.parse(src)
    assign = clear = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "data_store":
                    assign += 1
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
            if isinstance(node.target, ast.Name) and node.target.id == "data_store":
                assign += 1
        elif isinstance(node, ast.Call):
            f = node.func
            if (isinstance(f, ast.Attribute) and f.attr == "clear"
                    and isinstance(f.value, ast.Name) and f.value.id == "data_store"):
                clear += 1
    boot = sum(1 for ln in src.splitlines() if ln.strip() == PROTECT_LINE)
    return {"data_store_assign": assign, "data_store_clear": clear, "boot_line": boot,
            "boot_text": src.count(PROTECT_LINE)}


def top_names(src: str):
    tree = ast.parse(src)
    funcs, names = set(), set()
    for n in tree.body:
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            funcs.add(n.name)
        elif isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    names.add(t.id)
        elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
            names.add(n.target.id)
    return funcs, names


# ---------------------------------------------------------------- bridge
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)


def patch_bridge(src: str):
    if MARK in src:
        return src, {"bridge": "schon", "pong": "ja" if "Pong-Trigger" in src else "?"}
    funcs, names = top_names(src)
    need_f = {"connect", "send_now", "on_receive", "main", "is_held", "log", "now_str"}
    need_n = {"_state", "_lock", "_send_q", "HOST", "STATION", "_iface"}
    miss = sorted((need_f - funcs) | (need_n - names))
    if miss:
        raise SystemExit("STOP bridge: fehlt %s" % ", ".join(miss))
    if not re.search(r"pub\.subscribe\(\s*on_receive\b", src):
        raise SystemExit("STOP bridge: pub.subscribe(on_receive ...) nicht gefunden")
    if "datetime" not in src:
        raise SystemExit("STOP bridge: datetime-Import fehlt")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP bridge: __main__-Block %d mal gefunden" % len(ms))
    has_pong = ("Pong-Trigger" in src) and ("TRIGGERS" in src)
    block = BRIDGE_BLOCK.replace("__M2OS_ADD_PONG__", "False" if has_pong else "True")
    pos = ms[0].start()
    new = src[:pos].rstrip("\n") + "\n\n" + block + "\n" + src[pos:]
    ast.parse(new)
    return new, {"bridge": "neu", "pong": "ja" if has_pong else "nein->ergänzt"}


# ---------------------------------------------------------------- funk_health
REG_RE = re.compile(r"^def register_funk\(\s*app\s*\)\s*:[^\n]*\n", re.M)
FETCH_RE = re.compile(
    r"^(?P<i>[ \t]+)from dashboard import fetch_mesh_status\n"
    r"(?P=i)st = fetch_mesh_status\(\) or \{\}\n", re.M)


def patch_funk(src: str):
    info = {}
    if "_m2os_ms.install(app)" in src:
        info["funk_banner"] = "schon"
    else:
        ms = list(REG_RE.finditer(src))
        if len(ms) != 1:
            raise SystemExit("STOP funk_health: def register_funk(app) %d mal gefunden" % len(ms))
        m = ms[0]
        src = src[:m.end()] + FUNK_INSTALL + src[m.end():]
        info["funk_banner"] = "neu"
    if "_m2os_ms2.mesh_status()" in src:
        info["funk_status"] = "schon"
    else:
        m = FETCH_RE.search(src)
        if m:
            i = m.group("i")
            repl = (
                f"{i}try:  # mesh2OneSession: ohne Probe-Connect, Dienst = Bridge\n"
                f"{i}    import mesh_session as _m2os_ms2\n"
                f"{i}    st = _m2os_ms2.mesh_status() or {{}}\n"
                f"{i}except Exception:\n"
                f"{i}    from dashboard import fetch_mesh_status\n"
                f"{i}    st = fetch_mesh_status() or {{}}\n"
            )
            src = src[:m.start()] + repl + src[m.end():]
            info["funk_status"] = "neu"
        else:
            info["funk_status"] = "Anker fehlt (weich)"
    ast.parse(src)
    return src, info


# ---------------------------------------------------------------- dashboard (weich)
PROBE_LINK_RE = re.compile(
    r"^(?P<i>[ \t]+)s = socket\.create_connection\(\(host, 4403\), timeout=2\)\n"
    r"(?P=i)s\.close\(\)\n"
    r"(?P=i)tcp = True\n", re.M)
PROBE_PI_RE = re.compile(
    r"^(?P<i>[ \t]+)s = socket\.create_connection\(\(str\(mesh_host\), 4403\), timeout=3\)\n"
    r"(?P=i)s\.close\(\)\n"
    r"(?P=i)mesh_ok = True\n", re.M)


def patch_dashboard(src: str):
    info = {}
    before = guard_counts(src)
    if "_m2os_ms3" in src:
        info["dash_link"] = "schon"
    else:
        m = PROBE_LINK_RE.search(src)
        if m and len(PROBE_LINK_RE.findall(src)) == 1:
            i = m.group("i")
            repl = (
                f"{i}try:  # mesh2OneSession: kein Probe-Connect wenn Bridge verbunden\n"
                f"{i}    import mesh_session as _m2os_ms3\n"
                f"{i}    tcp = _m2os_ms3.port_ok(host)\n"
                f"{i}except Exception:\n"
                f"{i}    s = socket.create_connection((host, 4403), timeout=2)\n"
                f"{i}    s.close()\n"
                f"{i}    tcp = True\n"
            )
            src = src[:m.start()] + repl + src[m.end():]
            info["dash_link"] = "neu"
        else:
            info["dash_link"] = "Anker fehlt (weich)"
    if "_m2os_ms4" in src:
        info["dash_pi"] = "schon"
    else:
        m = PROBE_PI_RE.search(src)
        if m and len(PROBE_PI_RE.findall(src)) == 1:
            i = m.group("i")
            repl = (
                f"{i}try:  # mesh2OneSession: kein Probe-Connect wenn Bridge verbunden\n"
                f"{i}    import mesh_session as _m2os_ms4\n"
                f"{i}    mesh_ok = _m2os_ms4.port_ok(str(mesh_host), 3)\n"
                f"{i}except Exception:\n"
                f"{i}    s = socket.create_connection((str(mesh_host), 4403), timeout=3)\n"
                f"{i}    s.close()\n"
                f"{i}    mesh_ok = True\n"
            )
            src = src[:m.start()] + repl + src[m.end():]
            info["dash_pi"] = "neu"
        else:
            info["dash_pi"] = "Anker fehlt (weich)"
    n = 0
    for old, new in (
        ('fetch_mesh_link(h2, "Mesh 2", "mesh-ping-reply-2")', 'fetch_mesh_link(h2, "Mesh 2", "mesh-bridge-bayern")'),
        ('fetch_mesh_link(h1, "Mesh 1", "mesh-ping-reply")', 'fetch_mesh_link(h1, "Mesh 1", "mesh-bridge")'),
    ):
        if src.count(old) == 1:
            src = src.replace(old, new, 1)
            n += 1
    info["dash_svc"] = str(n)
    after = guard_counts(src)
    if before != after:
        raise SystemExit("STOP dashboard guards %s -> %s" % (before, after))
    return src, info


# ---------------------------------------------------------------- hang watchdog (weich)
def patch_hang(src: str):
    if MARK in src:
        return src, {"hang": "schon"}
    old1 = '"ping_svc": "mesh-ping-reply-2.service",'
    old2_re = re.compile(r'^(?P<i>[ \t]+)units\.append\(cfg\["ping_svc"\]\)\n', re.M)
    if src.count(old1) != 1 or len(old2_re.findall(src)) != 1:
        return src, {"hang": "Anker fehlt (weich, Unit ist maskiert)"}
    src = src.replace(old1, '"ping_svc": None,  # mesh2OneSession: Ping laeuft in der Bridge', 1)
    m = old2_re.search(src)
    i = m.group("i")
    src = src[:m.start()] + (
        f'{i}if cfg.get("ping_svc"):  # mesh2OneSession\n'
        f'{i}    units.append(cfg["ping_svc"])\n') + src[m.end():]
    ast.parse(src)
    return src, {"hang": "neu"}


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    files = {
        "bridge": root / "mesh_bridge_bayern.py",
        "funk": root / "funk_health.py",
        "dash": root / "dashboard.py",
        "hang": root / "mesh_hang_watchdog.py",
    }
    for k in ("bridge", "funk", "dash"):
        if not files[k].is_file():
            raise SystemExit("STOP: fehlt %s" % files[k])
    srcs = {k: p.read_text(encoding="utf-8") for k, p in files.items() if p.is_file()}
    out, info = {}, {}
    # alles erst im Speicher, geschrieben wird nur wenn ALLES ok ist
    out["bridge"], i1 = patch_bridge(srcs["bridge"])
    out["funk"], i2 = patch_funk(srcs["funk"])
    out["dash"], i3 = patch_dashboard(srcs["dash"])
    info.update(i1); info.update(i2); info.update(i3)
    if "hang" in srcs:
        out["hang"], i4 = patch_hang(srcs["hang"])
        info.update(i4)
    else:
        info["hang"] = "Datei fehlt"
    for k, s in out.items():
        compile(s, str(files[k]), "exec")
    changed = []
    for k, s in out.items():
        if s != srcs[k]:
            files[k].write_text(s, encoding="utf-8")
            changed.append(files[k].name)
    for k, v in info.items():
        print("RESULT %s=%s" % (k, v))
    print("RESULT changed=%s" % (",".join(changed) or "-"))


if __name__ == "__main__":
    main()
PATCHPY_EOF
cat > "$W/mesh_session.py" << 'MSESSPY_EOF'
#!/usr/bin/env python3
"""Mesh-Sessions pruefen: genau EINE TCP-Session je Funkgeraet. # mesh2OneSession

Wird von funk_health.py geladen (Funk-Seite). Leichtgewichtig:
ein `ss -tnp` + ein `systemctl show`, Ergebnis 20 s gecacht.
Oeffnet KEINE eigene TCP-Verbindung zu einem Node, solange dort
schon eine Session besteht (ein zweiter Client wirft die Bridge raus).
"""
from __future__ import annotations

import html
import json
import re
import socket
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

MARK = "mesh2OneSession"
BASE = Path("/home/fmg/prepper-dashboard")
STATUS2 = BASE / "mesh2_session.json"
PORT = 4403
CACHE_SEC = 20
PKT_WARN_SEC = 30 * 60
PKT_RED_SEC = 90 * 60
ERR_WARN = 5
ERR_RED = 12
STATUS_OLD_SEC = 5 * 60

_cache = {"ts": 0.0, "data": None}
_cache_lock = threading.Lock()


def _now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def _hosts():
    h1, h2 = "192.168.178.141", "192.168.178.140"
    try:
        import config  # noqa: WPS433
        h1 = getattr(config, "MESH1_HOST", None) or getattr(config, "MESHTASTIC_HOST", None) or h1
        h2 = getattr(config, "MESH2_HOST", None) or getattr(config, "MESHTASTIC_HOST_BAYERN", None) or h2
    except Exception:
        pass
    return str(h1), str(h2)


def meshes():
    h1, h2 = _hosts()
    return [
        {"key": "m1", "name": "Mesh 1", "host": h1, "bridge": "mesh-bridge",
         "extra": ["mesh-ping-reply"], "extra_warn": False, "status": None},
        {"key": "m2", "name": "Mesh 2", "host": h2, "bridge": "mesh-bridge-bayern",
         "extra": ["mesh-ping-reply-2"], "extra_warn": True, "status": STATUS2},
    ]


def _run(cmd, timeout=3):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout or ""
    except Exception:
        return ""


def _unit_of_pid(pid):
    try:
        txt = Path("/proc/%s/cgroup" % int(pid)).read_text()
    except Exception:
        return None
    m = re.findall(r"([A-Za-z0-9@._-]+)\.service", txt)
    return m[-1] if m else None


def _peer_host(peer):
    p = peer.strip()
    if p.startswith("["):
        p = p[1:].split("]")[0]
    else:
        p = p.rsplit(":", 1)[0]
    if p.startswith("::ffff:"):
        p = p[7:]
    return p


def tcp_sessions(hosts):
    """{host: {estab, closewait, owners}} aus `ss -tnp` (nur lesen)."""
    res = {h: {"estab": 0, "closewait": 0, "owners": [], "ok": False} for h in hosts}
    out = _run(["ss", "-tnp"])
    if not out:
        out = _run(["ss", "-tn"])
    if not out:
        return res
    for h in hosts:
        res[h]["ok"] = True
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        state, peer = parts[0], parts[4]
        if not peer.endswith(":%d" % PORT):
            continue
        host = _peer_host(peer)
        if host not in res:
            continue
        if state.upper().startswith("ESTAB"):
            res[host]["estab"] += 1
            owner = None
            m = re.search(r"pid=(\d+)", line)
            if m:
                owner = _unit_of_pid(m.group(1)) or "pid %s" % m.group(1)
            if owner and owner not in res[host]["owners"]:
                res[host]["owners"].append(owner)
        elif "CLOSE-WAIT" in state.upper():
            res[host]["closewait"] += 1
    return res


def unit_states(units):
    """{unit: {active, file, load}} mit einem einzigen systemctl-Aufruf."""
    res = {u: {"active": "unknown", "file": "", "load": ""} for u in units}
    if not units:
        return res
    cmd = ["systemctl", "show", "-p", "Id", "-p", "ActiveState", "-p", "UnitFileState", "-p", "LoadState"]
    cmd += ["%s.service" % u for u in units]
    out = _run(cmd)
    for block in out.strip().split("\n\n"):
        d = {}
        for line in block.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
        uid = (d.get("Id") or "").replace(".service", "")
        if uid in res:
            res[uid] = {
                "active": d.get("ActiveState") or "unknown",
                "file": d.get("UnitFileState") or "",
                "load": d.get("LoadState") or "",
            }
    return res


def read_status(path):
    if not path:
        return None
    try:
        d = json.loads(Path(path).read_text() or "{}")
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def _mins(sec):
    return max(1, int(sec // 60))


def _probe(host, timeout=2):
    s = None
    try:
        s = socket.create_connection((host, PORT), timeout=timeout)
        return True
    except Exception:
        return False
    finally:
        try:
            if s is not None:
                s.close()
        except Exception:
            pass


def port_ok(host, timeout=2):
    """True wenn der Node erreichbar ist. Besteht schon eine Session
    (Bridge verbunden), wird NICHT geprobt: ein Probe-Connect wuerde die
    Bridge beim Funkgeraet rauswerfen."""
    try:
        if tcp_sessions([str(host)])[str(host)]["estab"] > 0:
            return True
    except Exception:
        pass
    return _probe(str(host), timeout)


def evaluate(force=False):
    now = time.time()
    with _cache_lock:
        if not force and _cache["data"] is not None and now - _cache["ts"] < CACHE_SEC:
            return _cache["data"]
    ms = meshes()
    hosts = [m["host"] for m in ms]
    units = []
    for m in ms:
        units.append(m["bridge"])
        units.extend(m["extra"])
    ss = tcp_sessions(hosts)
    us = unit_states(units)
    items = []
    per = {}
    for m in ms:
        name, host = m["name"], m["host"]
        s = ss.get(host) or {"estab": 0, "closewait": 0, "owners": [], "ok": False}
        b = us.get(m["bridge"]) or {}
        b_active = b.get("active") == "active"
        st = read_status(m["status"])
        w = []
        if not b_active and b.get("active") not in (None, "", "unknown"):
            w.append(("red", "%s: Bridge-Dienst %s läuft nicht (%s)" % (name, m["bridge"], b.get("active") or "?")))
        if s["estab"] > 1:
            owners = ", ".join(s["owners"]) if s["owners"] else "?"
            w.append(("red", "%s: %d TCP-Sessions gleichzeitig (%s) – Dienste werfen sich gegenseitig raus"
                      % (name, s["estab"], owners)))
        # Mesh1: mesh-ping-reply laeuft seit Wochen problemlos mit -> nur echte Befunde
        # (>1 Session, CLOSE-WAIT, Abbrueche, Stille). Mesh2: mesh-ping-reply-2 = Problem.
        for x in (m["extra"] if m.get("extra_warn") else []):
            u = us.get(x) or {}
            if u.get("active") in ("active", "activating", "reloading"):
                lvl = "red"
                w.append((lvl, "%s: %s läuft zusätzlich – zweiter TCP-Client, stört die Bridge" % (name, x)))
            elif u.get("file") in ("enabled", "enabled-runtime"):
                w.append(("yellow", "%s: %s ist beim Booten aktiviert (kommt nach Neustart wieder)" % (name, x)))
        if s["closewait"]:
            w.append(("yellow", "%s: %d hängende TCP-Verbindung(en) (CLOSE-WAIT)" % (name, s["closewait"])))
        held = False
        connected = None
        pkt_age = None
        if st:
            age = now - float(st.get("ts") or 0)
            held = bool(st.get("held"))
            connected = bool(st.get("connected"))
            if b_active and age > STATUS_OLD_SEC:
                w.append(("yellow", "%s: Bridge-Status seit %d min nicht aktualisiert" % (name, _mins(age))))
            elif held:
                left = 0
                try:
                    left = int((float(st.get("hold_until") or 0) - now) // 60)
                except Exception:
                    pass
                w.append(("yellow", "%s: manuell getrennt (Hold%s)" % (name, ", noch %d min" % left if left > 0 else "")))
            elif b_active and not connected:
                err = (st.get("last_error") or "").strip()
                w.append(("red", "%s: Bridge nicht mit dem Funkgerät verbunden%s" % (name, " (%s)" % err[:80] if err else "")))
            else:
                ref = st.get("last_pkt") or st.get("started_at") or st.get("connected_at")
                if ref:
                    pkt_age = now - float(ref)
                    if pkt_age > PKT_RED_SEC:
                        w.append(("red", "%s: seit %d min kein Paket vom Funkgerät" % (name, _mins(pkt_age))))
                    elif pkt_age > PKT_WARN_SEC:
                        w.append(("yellow", "%s: seit %d min kein Paket vom Funkgerät" % (name, _mins(pkt_age))))
            n = int(st.get("reconnects_1h") or 0) + int(st.get("errors_1h") or 0)
            if n >= ERR_WARN:
                err = (st.get("last_error") or "").strip()
                w.append(("red" if n >= ERR_RED else "yellow",
                          "%s: %d Abbrüche/Neuverbindungen in 1 h%s" % (name, n, " (zuletzt: %s)" % err[:60] if err else "")))
        elif b_active and s["ok"] and s["estab"] == 0:
            w.append(("yellow", "%s: Bridge hat gerade keine TCP-Session zum Funkgerät" % name))
        per[m["key"]] = {
            "name": name, "host": host, "estab": s["estab"], "closewait": s["closewait"],
            "owners": s["owners"], "bridge": m["bridge"], "bridge_active": b_active,
            "extra": {x: us.get(x) for x in m["extra"]}, "held": held, "connected": connected,
            "pkt_age": int(pkt_age) if pkt_age is not None else None,
            "status": st, "warnings": [{"level": l, "text": t} for l, t in w],
        }
        items.extend(w)
    level = "ok"
    if any(l == "red" for l, _ in items):
        level = "red"
    elif items:
        level = "yellow"
    data = {
        "marker": MARK, "at": _now_str(), "ts": now, "level": level,
        "items": [{"level": l, "text": t} for l, t in items], "meshes": per,
    }
    with _cache_lock:
        _cache["ts"] = now
        _cache["data"] = data
    return data


def mesh_status():
    """Ersatz fuer dashboard.fetch_mesh_status() ohne Probe-Connect.
    Dienst = Bridge (nicht mehr mesh-ping-reply*)."""
    ev = evaluate()
    out = {}
    for key, m in (ev.get("meshes") or {}).items():
        estab = m.get("estab") or 0
        b_ok = bool(m.get("bridge_active"))
        tcp = estab > 0
        if not tcp and not b_ok:
            tcp = _probe(m["host"])  # niemand verbunden -> Probe wirft keinen raus
        if m.get("held"):
            color, label = "#eab308", "manuell getrennt"
        elif tcp and b_ok and estab == 1:
            color, label = "#22c55e", "läuft"
        elif tcp and b_ok:
            color, label = "#dc2626", "%d Sessions – Konflikt" % estab
        elif b_ok:
            color, label = "#eab308", "Bridge ohne TCP-Session"
        elif tcp:
            color, label = "#eab308", "Port offen · Bridge aus"
        else:
            color, label = "#ef4444", "offline"
        out[key] = {
            "host": m["host"], "name": m["name"], "tcp": tcp, "svc_ok": b_ok,
            "heard_sec": None, "cw": m.get("closewait") or 0, "color": color,
            "label": label, "at": ev.get("at"),
        }
    return out


def banner_html(ev=None):
    try:
        ev = ev or evaluate()
    except Exception as e:
        return '<div id="m2osBanner" class="card" style="color:#94a3b8">Mesh-Check: %s</div>' % html.escape(str(e)[:80])
    items = ev.get("items") or []
    if not items:
        return ('<div id="m2osBanner" class="card" style="border-color:#166534;padding:8px 14px">'
                '<span style="color:#22c55e;font-weight:600">&#10003; Mesh-Verbindungen OK</span>'
                '<span style="color:#94a3b8;font-size:.8rem"> &middot; je eine TCP-Session &middot; %s</span></div>'
                % html.escape(str(ev.get("at") or "")))
    red = ev.get("level") == "red"
    border = "#b91c1c" if red else "#a16207"
    bg = "#450a0a" if red else "#422006"
    rows = []
    for it in items:
        c = "#fca5a5" if it.get("level") == "red" else "#fde68a"
        dot = "&#9679;"
        rows.append('<div style="margin:3px 0;color:%s">%s %s</div>' % (c, dot, html.escape(it.get("text") or "")))
    hint = ""
    txt = " ".join(i.get("text") or "" for i in items)
    if "mesh-ping-reply" in txt:
        hint = ('<div style="color:#cbd5e1;font-size:.78rem;margin-top:6px">Abhilfe: zweiten Dienst stoppen, '
                'z.B. <code>sudo systemctl disable --now mesh-ping-reply-2</code></div>')
    return ('<div id="m2osBanner" class="card" style="background:%s;border:1px solid %s">'
            '<div class="title" style="color:#fecaca">Mesh-Problem</div>%s%s'
            '<div style="color:#94a3b8;font-size:.75rem;margin-top:6px">Stand %s</div></div>'
            % (bg, border, "".join(rows), hint, html.escape(str(ev.get("at") or ""))))


_CARD_RE = re.compile(r'<div class="card">')
_BODY_RE = re.compile(r"<body[^>]*>", re.I)


def inject(page):
    """Banner vor die erste Karte setzen (sonst direkt nach <body>)."""
    if not isinstance(page, str) or 'id="m2osBanner"' in page:
        return page
    b = banner_html()
    m = _CARD_RE.search(page)
    if m:
        return page[:m.start()] + b + "\n" + page[m.start():]
    m = _BODY_RE.search(page)
    if m:
        return page[:m.end()] + "\n" + b + page[m.end():]
    return page


def install(app):
    """Route /api/funk/mesh_session + Banner auf /funk (after_request)."""
    if getattr(app, "_m2os_installed", False):
        return
    app._m2os_installed = True
    from flask import jsonify, request

    def _api():
        try:
            return jsonify(evaluate(force=True))
        except Exception as e:
            return jsonify({"marker": MARK, "level": "unknown", "error": str(e)[:200], "items": []})

    try:
        app.add_url_rule("/api/funk/mesh_session", "m2os_mesh_session", _api)
    except Exception as e:
        print("mesh_session route:", e)

    def _after(resp):
        try:
            if (request.path or "").rstrip("/") != "/funk":
                return resp
            if resp.status_code != 200 or resp.mimetype != "text/html":
                return resp
            if resp.headers.get("Content-Encoding") or resp.direct_passthrough:
                return resp
            page = resp.get_data(as_text=True)
            new = inject(page)
            if new != page:
                resp.set_data(new)
        except Exception as e:
            print("mesh_session banner:", e)
        return resp

    app.after_request(_after)


if __name__ == "__main__":
    print(json.dumps(evaluate(force=True), ensure_ascii=False, indent=1))
MSESSPY_EOF

if [[ "$PORT" == "5000" ]]; then
  echo "STOP: PORT=5000 verweigert - Smoke nur :8080"
  exit 1
fi
echo "=== mesh2OneSession apply PORT=$PORT ==="

# ---------- 0) Bytes pruefen ----------
echo "$EXPECT_PATCH  $W/patch-mesh2-onesession.py" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MSESS  $W/mesh_session.py" | sha256sum -c - >/dev/null || { echo "STOP: mesh_session sha256 falsch"; exit 1; }
for f in "$W/patch-mesh2-onesession.py" "$W/mesh_session.py"; do
  grep -q 'mesh2OneSession' "$f" || { echo "STOP: $f ohne Marker"; exit 1; }
  if grep -q 'PLACEHOLDER' "$f"; then echo "STOP: PLACEHOLDER in $f"; exit 1; fi
  python3 -m py_compile "$f"
done
set +e
python3 - "$W/patch-mesh2-onesession.py" "$W/mesh_session.py" << 'GUARDPY'
import ast, pathlib, sys
hit = False
for path in sys.argv[1:]:
    tree = ast.parse(pathlib.Path(path).read_text(encoding="utf-8"), filename=path)
    for node in ast.walk(tree):
        tg = []
        if isinstance(node, ast.Assign):
            tg = node.targets
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
            tg = [node.target]
        for t in tg:
            if isinstance(t, ast.Name) and t.id == "data_store":
                print("%s:%s data_store-Zuweisung" % (path, node.lineno)); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Attribute) and f.attr == "clear" and isinstance(f.value, ast.Name) and f.value.id == "data_store":
                print("%s:%s data_store.clear()" % (path, node.lineno)); hit = True
            if isinstance(f, ast.Name) and f.id == "update_all":
                print("%s:%s update_all()" % (path, node.lineno)); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard Patchdateien rc=$g"; exit 1; }
echo "OK Bytes + AST-Guard (kein data_store/update_all im Patch)"

# ---------- 1) Trockenlauf auf Kopien (aendert nichts) ----------
for f in "$BRIDGE" "$FUNK" "$DASH"; do
  [[ -f "$f" ]] || { echo "STOP: fehlt $f - nichts geaendert"; exit 1; }
done
rm -rf "$W/work" && mkdir -p "$W/work"
cp -a "$BRIDGE" "$FUNK" "$DASH" "$W/work/"
[[ -f "$HANG" ]] && cp -a "$HANG" "$W/work/"
set +e
python3 "$W/patch-mesh2-onesession.py" "$W/work" > "$W/dry.txt" 2>&1
rc=$?
set -e
cat "$W/dry.txt"
if [[ "$rc" -ne 0 ]]; then
  echo "STOP: Anker nicht gefunden - NICHTS geaendert. Bitte Ausgabe schicken."
  grep -n 'def connect\|def send_now\|def on_receive\|pub.subscribe\|__main__\|Pong-Trigger' "$BRIDGE" | head -12 || true
  grep -n 'def register_funk\|fetch_mesh_status' "$FUNK" | head -5 || true
  exit 1
fi
cp -a "$W/work" "$W/work1"
python3 "$W/patch-mesh2-onesession.py" "$W/work" > /dev/null
for f in "$W/work"/*.py; do
  cmp -s "$f" "$W/work1/$(basename "$f")" || { echo "STOP: nicht idempotent ($(basename "$f")) - nichts geaendert"; exit 1; }
  python3 -m py_compile "$f" || { echo "STOP: py_compile $(basename "$f") - nichts geaendert"; exit 1; }
done
PONG=$(sed -n 's/^RESULT pong=//p' "$W/dry.txt")
echo "OK Trockenlauf idempotent + kompiliert (Ping-Antwort in Bridge: $PONG)"

guard_snap() {
  python3 - "$1" << 'GPY'
import ast, pathlib, sys
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for k in ["update_all()  # einmal beim Start", "staleTsBoot", "strom14dChart", "navUnify",
          "gasLngSign", "lngColorFlip", "adsbMilThird", "keepLast", "pageFein"]:
    print("%s\t%d" % (k, t.count(k)))
a = c = 0
for n in ast.walk(ast.parse(t)):
    if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id == "data_store" for x in n.targets):
        a += 1
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "clear" \
            and isinstance(n.func.value, ast.Name) and n.func.value.id == "data_store":
        c += 1
print("data_store_assign\t%d\ndata_store_clear\t%d" % (a, c))
GPY
}
g_before=$(guard_snap "$DASH")
g_after=$(guard_snap "$W/work/dashboard.py")
if [[ "$g_before" != "$g_after" ]]; then
  echo "STOP: Guards im Trockenlauf geaendert - nichts geaendert"; printf '%s\n' "$g_before" "---" "$g_after"; exit 1
fi
echo "OK AST-Guard dashboard.py unveraendert (update_all-Boot, data_store)"

# ---------- 2) sudo + Dienst mesh-ping-reply-2 dauerhaft aus ----------
sudo -v
U=mesh-ping-reply-2.service
load=$(systemctl show -p LoadState --value "$U" 2>/dev/null || true)
frag=$(systemctl show -p FragmentPath --value "$U" 2>/dev/null || true)
if [[ "$load" == "masked" ]]; then
  sudo systemctl stop "$U" 2>/dev/null || true
  echo "OK $U schon maskiert"
elif [[ -z "$load" || "$load" == "not-found" ]]; then
  echo "OK $U gibt es nicht"
else
  sudo systemctl disable --now "$U" 2>&1 | grep -v '^Removed' || true
  if [[ -n "$frag" && "$frag" == /etc/systemd/system/* && -f "$frag" ]]; then
    cp -a "$frag" "$DASH_DIR/mesh-ping-reply-2.service.bak-m2os-$TS"
    sudo mv "$frag" "$frag.off-m2os-$TS"
    echo "OK Unit-Datei weggelegt: $frag.off-m2os-$TS"
  fi
  sudo systemctl daemon-reload
  if sudo systemctl mask "$U" >/dev/null 2>&1; then
    echo "OK $U gestoppt + maskiert (kann nicht mehr starten)"
  else
    echo "WARN $U nur deaktiviert (mask ging nicht)"
  fi
  sudo systemctl daemon-reload
fi
a2=$(systemctl is-active "$U" 2>/dev/null || true)
e2=$(systemctl is-enabled "$U" 2>/dev/null || true)
echo "Status $U: active=${a2:-?} enabled=${e2:-?}"
if [[ "$a2" == "active" ]]; then
  echo "STOP: $U laeuft noch - bitte Ausgabe schicken"; exit 1
fi

# ---------- 3) Stufe A: Bridge ----------
cp -a "$BRIDGE" "$BRIDGE.bak-m2os-$TS"
rollback_a() {
  echo "ROLLBACK Bridge: $1"
  cp -a "$BRIDGE.bak-m2os-$TS" "$BRIDGE"
  sudo systemctl restart mesh-bridge-bayern.service || true
  echo "mesh-ping-reply-2 bleibt aus (war die Ursache)."
  sudo journalctl -u mesh-bridge-bayern -n 25 --no-pager -o cat 2>/dev/null | tail -25 || true
}
changed_a=0
if ! cmp -s "$W/work/mesh_bridge_bayern.py" "$BRIDGE"; then
  cp "$W/work/mesh_bridge_bayern.py" "$BRIDGE"
  changed_a=1
fi
python3 -m py_compile "$BRIDGE" || { rollback_a "py_compile"; exit 1; }
T0=$(date +%s)
SINCE=$(date -d "@$T0" '+%Y-%m-%d %H:%M:%S')
sudo systemctl restart mesh-bridge-bayern.service
echo "--- warte auf Bridge Mesh2 (max 150 s) ---"
ok_a=0
for i in $(seq 1 50); do
  sleep 3
  systemctl is-active --quiet mesh-bridge-bayern.service || continue
  h=$(curl -s -m 3 http://127.0.0.1:5002/health || true)
  echo "$h" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("connected") else 1)' 2>/dev/null || continue
  if sudo journalctl -u mesh-bridge-bayern --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -q 'verbunden'; then
    ok_a=1; break
  fi
done
if [[ "$ok_a" -ne 1 ]]; then
  rollback_a "Bridge nicht verbunden (kein 'verbunden' im Journal / health connected)"
  exit 1
fi
echo "OK Bridge aktiv + verbunden ($(( $(date +%s) - T0 )) s)"
mp=$(systemctl show -p MainPID --value mesh-bridge-bayern.service 2>/dev/null || echo 0)
ok_s=0
for i in $(seq 1 12); do
  if python3 - "$STATUS" "$mp" << 'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
ok = d.get("marker") == "mesh2OneSession" and str(d.get("pid")) == sys.argv[2] and d.get("connected") and time.time() - float(d.get("ts") or 0) < 90
raise SystemExit(0 if ok else 1)
PY
  then ok_s=1; break; fi
  sleep 3
done
if [[ "$ok_s" -ne 1 ]]; then
  rollback_a "Status-JSON fehlt/alt (neuer Code laeuft nicht?)"
  exit 1
fi
sudo journalctl -u mesh-bridge-bayern --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E 'mesh2OneSession aktiv|verbunden ids' | tail -3 || true
n140=$(ss -tn 2>/dev/null | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.140\]?:4403$/' | wc -l)
echo "TCP-Sessions Pi -> Mesh2 (.140:4403): $n140"
if [[ "$n140" -gt 1 ]]; then echo "WARN: mehr als eine Session zu Mesh2 - Ausgabe schicken"; fi
echo "OK Stufe A: Mesh2 nur noch ueber die Bridge (Ping-Antwort: $PONG)"

# ---------- 4) Stufe B: Funk-Seite + Dashboard + Watchdog ----------
had_ms=0; [[ -f "$MSESS" ]] && had_ms=1
[[ "$had_ms" == 1 ]] && cp -a "$MSESS" "$MSESS.bak-m2os-$TS"
cp -a "$FUNK" "$FUNK.bak-m2os-$TS"
cp -a "$DASH" "$DASH.bak-m2os-$TS"
[[ -f "$HANG" ]] && cp -a "$HANG" "$HANG.bak-m2os-$TS"
rollback_b() {
  echo "ROLLBACK Funk/Dashboard: $1"
  cp -a "$FUNK.bak-m2os-$TS" "$FUNK"
  cp -a "$DASH.bak-m2os-$TS" "$DASH"
  [[ -f "$HANG.bak-m2os-$TS" ]] && cp -a "$HANG.bak-m2os-$TS" "$HANG"
  if [[ "$had_ms" == 1 ]]; then cp -a "$MSESS.bak-m2os-$TS" "$MSESS"; else rm -f "$MSESS"; fi
  sudo systemctl restart prepper-dashboard.service || true
  echo "Bridge-Fix (Stufe A) bleibt aktiv."
}
install -m 0644 "$W/mesh_session.py" "$MSESS"
cp "$W/work/funk_health.py" "$FUNK"
cp "$W/work/dashboard.py" "$DASH"
[[ -f "$W/work/mesh_hang_watchdog.py" ]] && cp "$W/work/mesh_hang_watchdog.py" "$HANG"
for f in "$MSESS" "$FUNK" "$DASH"; do
  python3 -m py_compile "$f" || { rollback_b "py_compile $(basename "$f")"; exit 1; }
done
[[ -f "$HANG" ]] && { python3 -m py_compile "$HANG" || { rollback_b "py_compile mesh_hang_watchdog.py"; exit 1; }; }
g_now=$(guard_snap "$DASH")
[[ "$g_now" == "$g_before" ]] || { rollback_b "Guards dashboard.py geaendert"; exit 1; }
grep -q 'update_all()  # einmal beim Start' "$DASH.bak-m2os-$TS" && { grep -q 'update_all()  # einmal beim Start' "$DASH" || { rollback_b "Boot-Zeile weg"; exit 1; }; }
sudo systemctl restart prepper-dashboard.service

echo "--- HTTP :$PORT (nie :5000) ---"
root=""
for i in $(seq 1 80); do
  root=$(curl --compressed -s -o "$W/root.html" -w "%{http_code}" --connect-timeout 3 --max-time 25 "http://127.0.0.1:${PORT}/" || true)
  [[ -z "$root" ]] && root=000
  [[ "$root" == "200" || "$root" == "500" ]] && break
  (( i % 10 == 1 )) && echo "warte auf Dashboard ... HTTP /=$root"
  sleep 3
done
[[ "$root" == "500" ]] && { rollback_b "HTTP / = 500"; exit 1; }
[[ "$root" == "200" ]] || { rollback_b "HTTP / = $root"; exit 1; }
echo "OK HTTP / = 200"
eng=$(curl --compressed -s -o "$W/energie.html" -w "%{http_code}" --connect-timeout 3 --max-time 25 "http://127.0.0.1:${PORT}/energie" || true)
echo "HTTP /energie=${eng:-000}"
[[ "$eng" == "500" ]] && { rollback_b "HTTP /energie = 500"; exit 1; }
funk=$(curl --compressed -s -o "$W/funk.html" -w "%{http_code}" --connect-timeout 3 --max-time 25 "http://127.0.0.1:${PORT}/funk" || true)
echo "HTTP /funk=${funk:-000}"
[[ "$funk" == "200" ]] || { rollback_b "HTTP /funk = $funk"; exit 1; }
grep -q 'id="m2osBanner"' "$W/funk.html" || { rollback_b "Banner fehlt auf /funk"; sudo journalctl -u prepper-dashboard -n 30 --no-pager -o cat 2>/dev/null | grep -i 'mesh_session' || true; exit 1; }
api=$(curl --compressed -s -o "$W/ms.json" -w "%{http_code}" --connect-timeout 3 --max-time 25 "http://127.0.0.1:${PORT}/api/funk/mesh_session" || true)
[[ "$api" == "200" ]] || { rollback_b "/api/funk/mesh_session = $api"; exit 1; }
echo "OK /funk 200 mit Banner, /api/funk/mesh_session 200"
grep 'RESULT dash_\|RESULT funk_status\|RESULT hang' "$W/dry.txt" | sed 's/^RESULT /  /' || true

# ---------- 5) Was die Funk-Seite jetzt zeigt ----------
echo "--- Funk-Seite Mesh-Check ---"
python3 - "$W/ms.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
items = d.get("items") or []
if not items:
    print("GRUEN: Mesh-Verbindungen OK, je eine TCP-Session")
for it in items:
    print(("ROT:  " if it.get("level") == "red" else "GELB: ") + it.get("text", ""))
for k, m in sorted((d.get("meshes") or {}).items()):
    ex = ", ".join("%s=%s/%s" % (u, (s or {}).get("active"), (s or {}).get("file")) for u, s in (m.get("extra") or {}).items())
    print("%s: Sessions=%s CLOSE-WAIT=%s Bridge=%s %s" % (m.get("name"), m.get("estab"), m.get("closewait"),
          "aktiv" if m.get("bridge_active") else "AUS", ex))
PY
echo "--- Mesh1 (nur Info, nichts geaendert) ---"
echo "mesh-bridge=$(systemctl is-active mesh-bridge 2>/dev/null || true) mesh-ping-reply=$(systemctl is-active mesh-ping-reply 2>/dev/null || true)/$(systemctl is-enabled mesh-ping-reply 2>/dev/null || true)"
sudo ss -tnp 2>/dev/null | awk '$5 ~ /:4403$/ {print "  " $1, $5, $6}' || true

had() { grep -q "$1" "$DASH" && echo 1 || echo 0; }
m2=0; grep -q 'mesh2OneSession' "$BRIDGE" && grep -q '_m2os_ms.install' "$FUNK" && m2=1
echo "OK guards boot=$(grep -q 'update_all()  # einmal beim Start' "$DASH" && echo 1 || echo 0) staleTsBoot=$(had staleTsBoot) strom14dChart=$(had strom14dChart) navUnify=$(had navUnify) gasLngSign=$(had gasLngSign) lngColorFlip=$(had lngColorFlip) adsbMilThird=$(had adsbMilThird) keepLast=$(had keepLast) mesh2OneSession=$m2"
echo "Backups: *.bak-m2os-$TS"
echo "OK mesh2OneSession fertig: Mesh2 eine TCP-Session, mesh-ping-reply-2 aus, Warnung auf /funk"
echo "COMMIT $COMMIT_ARG mesh2OneSession"
