#!/bin/bash
set -euo pipefail
# funkHarden2: alle Restpunkte der 100/100-Pruefung Funk/Mesh (Teil 2 nach funkHarden)
# Stufe 1 Bridges (Mesh 1 + 2): keine Doppelsendung nach Reconnect, /send prueft Kanal 0-7 und
#   Text, Routine-HTTP nicht mehr im Log, Ping-Antworten getrennt gezaehlt.
#   mesh_reply_watch: Sperre + eindeutige Temp-Datei. Hang-Watchdog: maskierte Dienste nie starten.
# Stufe 2 Dashboard: Haltezeit gegen Flattern (2 h, Pegel 3 h), Entwarnung erst nach Bestaetigung,
#   Retry-Deckel, Ruhezeit auch fuer DWD/WBI/Frequenz/Stromausfall, NINA Bayern nicht doppelt,
#   fail-closed Regeln, /api/mesh_test nur per Button, Sende-APIs geprueft + Rate, atomare JSON.
# Jede Datei nur bei exakt geprueftem Live-Stand (sha256), sonst STOP ohne Aenderung.
# Sendet nichts. Neustart: mesh-bridge-bayern, mesh-bridge, dann prepper-dashboard (5 min Ruhezeit).
# Smoke gegen config.py PORT, nie :8080. Jede Stufe mit eigenem ROLLBACK.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
STATUS2="$DASH_DIR/mesh2_session.json"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/funkharden2
S1="mesh_bridge.py mesh_bridge_bayern.py mesh_reply_watch.py mesh_hang_watchdog.py"
S2="dashboard.py funk_health.py"
EXPECT_PATCH="6a1312d5d0f11ab7b16d530ce05779dfc13f1190eb0f4915248c45ef6a39f010"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-funk-harden2.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""funkHarden2: Haertung Funk/Mesh-Stack Teil 2 (alle Restpunkte der 100/100-Pruefung).

Stufe bridges: mesh_bridge.py, mesh_bridge_bayern.py, mesh_reply_watch.py, mesh_hang_watchdog.py
Stufe dash:    dashboard.py, funk_health.py
Jede Datei wird nur angefasst, wenn ihr sha256 (16) exakt dem geprueften Live-Stand entspricht
oder sie schon funkHarden2 enthaelt. Sonst STOP, nichts geschrieben. Sendet nichts.
"""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== funkHarden2"
EXPECT = {
    "mesh_bridge.py": "90e27fc38aa3d370",
    "mesh_bridge_bayern.py": "a33147cfbae64cfe",
    "mesh_reply_watch.py": "7bcf7bb9a7b9a19b",
    "mesh_hang_watchdog.py": "8d486b2d3c3bce32",
    "funk_health.py": "38371aec3cab580f",
    "dashboard.py": "1cdbd04bd889523d",
}
STAGES = {
    "bridges": ["mesh_bridge.py", "mesh_bridge_bayern.py", "mesh_reply_watch.py", "mesh_hang_watchdog.py"],
    "dash": ["dashboard.py", "funk_health.py"],
}
BRIDGE_BLOCK = r'''
# ===== funkHarden2 bridge: keine Doppelsendung, Eingabe pruefen, leises HTTP-Log =====
import re as _fh2_re
import hashlib as _fh2_hl
import collections as _fh2_col
FH2_DUP_SEC = 120      # gleiche Nachricht + Kanal innerhalb 120 s nur einmal
FH2_TEXT_MAX = 220
_fh2 = {"recent": _fh2_col.OrderedDict(), "dup": 0, "unsure": 0, "pre_fail": 0, "bad": 0,
        "http_quiet": 0, "replies": 0}
_fh2_ctrl = _fh2_re.compile("[\x00-\x08\x0b-\x1f\x7f]")


def _fh2_mesh_key():
    return "m2" if "_m2os" in globals() else "m1"


def _fh2_clean(text):
    if not isinstance(text, str):
        return ""
    t = text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", " ")
    t = _fh2_ctrl.sub("", t).strip()
    return t[:FH2_TEXT_MAX]


def _fh2_channel(v):
    """Kanal 0-7 oder None (ungueltig). Leer/fehlend = 0."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return None
    try:
        if isinstance(v, float) and v != int(v):
            return None
        c = int(str(v).strip()) if not isinstance(v, (int, float)) else int(v)
    except Exception:
        return None
    return c if 0 <= c <= 7 else None


def _fh2_is_reply(text):
    try:
        return isinstance(text, str) and text.startswith(STATION + "\nEmpfang ")
    except Exception:
        return False


def _fh2_key(text, ch):
    return "%d:%s" % (ch, _fh2_hl.sha1(text.encode("utf-8", "replace")).hexdigest())


def _fh2_seen(key):
    now = time.time()
    rec = _fh2["recent"]
    while rec:
        k0, t0 = next(iter(rec.items()))
        if now - t0 > FH2_DUP_SEC or len(rec) > 200:
            rec.popitem(last=False)
        else:
            break
    return key in rec


def _fh2_mark(key):
    _fh2["recent"][key] = time.time()
    _fh2["recent"].move_to_end(key)


def _fh2_pre():
    """Verbindung VOR dem Schreiben sicherstellen. Fehler hier = sicher nicht gesendet."""
    if "_m2os_presend" in globals():
        try:
            _m2os_presend()
        except Exception as e:
            log("funkHarden2 presend:", e)
    ensure_iface()


def worker():  # funkHarden2: genau ein Schreibversuch je Nachricht
    last = 0.0
    while True:
        try:
            item = _send_q.get()
            try:
                if isinstance(item, dict):
                    text = item.get("text") or ""
                    ch = _fh2_channel(item.get("channel"))
                else:
                    text = str(item or "")
                    ch = 0
                text = _fh2_clean(text)
                if ch is None:
                    _fh2["bad"] += 1
                    log("funkHarden2: Kanal ungueltig - verworfen")
                    continue
                if not text:
                    continue
                log("QUEUE take ch=", ch)
                key = _fh2_key(text, ch)
                if _fh2_seen(key):
                    _fh2["dup"] += 1
                    log("funkHarden2: gleiche Nachricht ch%d vor weniger als %d s schon gesendet - verworfen" % (ch, FH2_DUP_SEC))
                    continue
                _state["queued"] = _send_q.qsize()
                wait = SEND_GAP - (time.time() - last)
                if wait > 0:
                    time.sleep(wait)
                if is_held():
                    log("funkHarden2: Bridge getrennt (Hold) - Nachricht verworfen")
                    continue
                pre_ok = True
                try:
                    _fh2_pre()
                except Exception as e:
                    pre_ok = False
                    _fh2["pre_fail"] += 1
                    log("funkHarden2: keine Verbindung vor dem Senden:", e)
                ok = False
                if pre_ok:
                    ok = send_now(text, ch)
                    if not ok:
                        _fh2["unsure"] += 1
                        log("funkHarden2: Senden unsicher (Fehler beim Schreiben) - KEIN Wiederholversuch, keine Doppelsendung")
                else:
                    time.sleep(RECONNECT_WAIT)
                    try:
                        if "_m2os" in globals():
                            connect()
                        else:
                            with _lock:
                                connect()
                        ok = send_now(text, ch)
                    except Exception as e:
                        log("Reconnect-Send:", e)
                if ok or pre_ok:
                    _fh2_mark(key)
                if ok and _fh2_is_reply(text):
                    _fh2["replies"] += 1
                    try:
                        mesh_reply_watch.note_reply(_fh2_mesh_key())
                    except Exception:
                        pass
                last = time.time()
            finally:
                _send_q.task_done()
                _state["queued"] = _send_q.qsize()
        except Exception:
            traceback.print_exc()
            time.sleep(2)


_fh2_orig_do_POST = Handler.do_POST


def _fh2_do_POST(self):  # funkHarden2: /send pruefen (Kanal 0-7, Text 1-220, keine Steuerzeichen)
    if not self.path.startswith("/send"):
        return _fh2_orig_do_POST(self)
    try:
        n = int(self.headers.get("Content-Length") or 0)
    except Exception:
        n = 0
    if n < 0:
        n = 0
    if n > 4096:
        self._json(413, {"ok": False, "error": "body too large"})
        return
    body = self.rfile.read(n).decode("utf-8", errors="replace") if n else "{}"
    try:
        data = json.loads(body) if body else {}
    except Exception:
        data = None
    if not isinstance(data, dict):
        _fh2["bad"] += 1
        self._json(400, {"ok": False, "error": "json ungueltig"})
        return
    text = _fh2_clean(data.get("text"))
    ch = _fh2_channel(data.get("channel"))
    if ch is None:
        _fh2["bad"] += 1
        self._json(400, {"ok": False, "error": "channel ungueltig (0-7)"})
        return
    if not text:
        self._json(400, {"ok": False, "error": "text fehlt"})
        return
    try:
        _send_q.put_nowait({"text": text, "channel": ch})
        _state["queued"] = _send_q.qsize()
        self._json(200, {"ok": True, "queued": _state["queued"]})
    except queue.Full:
        self._json(429, {"ok": False, "error": "queue full"})


def _fh2_log_message(self, fmt, *args):  # funkHarden2: Routine-Abfragen nicht loggen
    try:
        req = str(args[0]) if args else ""
        code = int(args[1]) if len(args) > 1 and str(args[1]).isdigit() else 0
        if code and code < 400 and not any(p in req for p in (" /send", " /hold", " /resume")):
            _fh2["http_quiet"] += 1
            return
    except Exception:
        pass
    log("HTTP", fmt % args)


Handler.do_POST = _fh2_do_POST
Handler.log_message = _fh2_log_message
log("funkHarden2 aktiv (%s): Doppelsendeschutz %d s, kein Retry nach Schreibfehler, /send geprueft, HTTP-Log leise" % (
    _fh2_mesh_key(), FH2_DUP_SEC))
# ===== /funkHarden2 bridge =====
'''
RW_BLOCK = r'''

# ===== funkHarden2 replywatch: Sperre, eindeutige Temp-Datei, echte Ping-Antworten =====
import os as _fh2_os
import threading as _fh2_threading
import contextlib as _fh2_ctx
try:
    import fcntl as _fh2_fcntl
except Exception:  # pragma: no cover
    _fh2_fcntl = None

_fh2_tlock = _fh2_threading.RLock()


@_fh2_ctx.contextmanager
def _fh2_locked(path):
    path = Path(path)
    with _fh2_tlock:
        fh = None
        try:
            if _fh2_fcntl is not None:
                fh = open(str(path) + ".lock", "a")
                _fh2_fcntl.flock(fh.fileno(), _fh2_fcntl.LOCK_EX)
        except Exception:
            fh = None
        try:
            yield
        finally:
            if fh is not None:
                try:
                    _fh2_fcntl.flock(fh.fileno(), _fh2_fcntl.LOCK_UN)
                except Exception:
                    pass
                fh.close()


def _save(path: Path, data: dict) -> None:  # funkHarden2: Temp-Name je Prozess/Thread
    path = Path(path)
    tmp = path.with_name("%s.tmp-%d-%d" % (path.name, _fh2_os.getpid(), _fh2_threading.get_ident()))
    try:
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        tmp.replace(path)
    finally:
        try:
            if tmp.exists():
                tmp.unlink()
        except Exception:
            pass


_fh2_orig_note_rx = note_rx
_fh2_orig_note_tx = note_tx


def note_rx(mesh_key, from_id=None):  # funkHarden2
    with _fh2_locked(_path(mesh_key)):
        return _fh2_orig_note_rx(mesh_key, from_id)


def note_tx(mesh_key, to_id=None):  # funkHarden2: jede Sendung (TX gesamt)
    with _fh2_locked(_path(mesh_key)):
        return _fh2_orig_note_tx(mesh_key, to_id)


def note_reply(mesh_key, to_id=None):  # funkHarden2: nur echte Ping-Antworten
    path = _path(mesh_key)
    with _fh2_locked(path):
        d = _load(path)
        d["last_reply_ts"] = time.time()
        d["reply_count"] = int(d.get("reply_count") or 0) + 1
        if to_id is not None:
            d["last_reply_to"] = str(to_id)
        _save(path, d)
        return d


def _fh2_status_d(d, stale_sec=3600):  # funkHarden2: Logik wie status(), Daten uebergeben
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


def status(mesh_key, stale_sec=3600):  # funkHarden2: stumm = Ping ohne echte Ping-Antwort
    d = _load(_path(mesh_key))
    rep = d.get("last_reply_ts")
    try:
        rep = float(rep) if rep is not None else None
    except Exception:
        rep = None
    now = time.time()
    if rep is None:
        r = _fh2_status_d(d, stale_sec)
        r["last_reply_age"] = None
        r["reply_src"] = "tx"
    else:
        real_tx = d.get("last_tx_ts")
        r = _fh2_status_d(dict(d, last_tx_ts=rep), stale_sec)
        try:
            r["last_tx_age"] = int(now - float(real_tx)) if real_tx is not None else None
        except Exception:
            r["last_tx_age"] = None
        r["last_reply_age"] = int(now - rep)
        r["reply_src"] = "reply"
    r["reply_count"] = int(d.get("reply_count") or 0)
    return r
# ===== /funkHarden2 replywatch =====
'''
HW_BLOCK = r'''
# ===== funkHarden2 hangwatch: maskierte/abgeschaltete Dienste nie neu starten =====
_fh2_orig_systemctl_restart = _systemctl_restart


def _fh2_unit_state(u: str):
    """(ok, info): ok=False bei masked/not-found/disabled. Abfragefehler -> wie bisher erlauben."""
    try:
        r = subprocess.run(["systemctl", "show", "-p", "LoadState", "-p", "UnitFileState", u],
                           capture_output=True, text=True, timeout=10)
        kv = {}
        for line in (r.stdout or "").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip()
        load = kv.get("LoadState", "")
        ufs = kv.get("UnitFileState", "")
        if load in ("masked", "not-found") or ufs in ("masked", "masked-runtime", "disabled"):
            return False, "%s/%s" % (load or "?", ufs or "?")
        return True, "%s/%s" % (load or "?", ufs or "?")
    except Exception as e:
        return True, "unbekannt (%s)" % e


def _systemctl_restart(units: list[str], dry_run: bool) -> list[str]:  # funkHarden2
    keep = []
    for u in units:
        ok, info = _fh2_unit_state(u)
        if ok:
            keep.append(u)
        else:
            log(f"skip {u}: {info} (funkHarden2: nicht neu starten)")
    if not keep:
        return []
    return _fh2_orig_systemctl_restart(keep, dry_run)
# ===== /funkHarden2 hangwatch =====

'''
DASH_BLOCK = r'''
# ===== funkHarden2: Sende-Schutz im Dashboard =====
# Alle Auto-Sender laufen weiter ueber send_meshtastic / send_nina_to_bayern / send_chunks_*.
# Hier nur ein Tor davor (kein neuer Sendeweg):
# - Haltezeit: gleiche Meldung (Zahlen-Schwankung egal) je Sender 2 h nicht erneut (Pegel 3 h)
# - Entwarnung/Rueckkehr zu normal erst nach Bestaetigung (2. Pruefung >= 8 min spaeter)
# - nach 3 Fehlversuchen derselben Meldung 30 min Pause (kein Dauer-Retry)
# - Ruhezeit nach Start auch fuer DWD, DWD-WBI, Frequenz, Stromausfall (nur merken)
# - Stromausfall: leere Liste erst nach 2. leerer Abfrage als Entwarnung
# - NINA Bayern doppelt? ninaCalm sendet schon an Mesh 2 -> zweiter Weg aus
# - nina_bayern_auto_enabled / Luft-Regeln: bei Fehler AUS (fail-closed)
# - /api/mesh_test nur per Button (POST oder Browser-fetch), 1x/min; /api/mesh*_send geprueft + 10/min
# Manuell (force=True, Buttons) bleibt sofort erlaubt.
import threading as _fh2_th
import time as _fh2_t
import re as _fh2_re
import json as _fh2_json
import os as _fh2_os
import inspect as _fh2_insp
import functools as _fh2_ft
import collections as _fh2_col

FH2_HOLD = {"spaceweather": 7200, "odl": 7200, "luft": 7200, "dwd": 7200, "dwd_wbi": 7200,
            "pegel": 10800, "stromausfall": 7200, "frequenz": 7200, "nina_bayern": 7200}
FH2_CLEAR_TAGS = ("dwd", "dwd_wbi", "odl", "luft", "spaceweather")
FH2_CLEAR_WORDS = ("entwarnung", "wieder normal", "normalbereich", "keine warnung", "aufgehoben",
                   "beendet", "vorbei", "unauffaellig", "unauffällig", "\u2705")
FH2_CLEAR_GAP = 480
FH2_CLEAR_MAX = 7200
FH2_FAIL_MAX = 3
FH2_FAIL_WIN = 1800
FH2_QUIET_LEARN = ("dwd", "dwd_wbi", "frequenz", "stromausfall")
FH2_TAGS = {"maybe_mesh_spaceweather": "spaceweather", "maybe_mesh_odl": "odl",
            "maybe_mesh_luft": "luft", "maybe_mesh_pegel": "pegel", "maybe_mesh_dwd": "dwd",
            "maybe_mesh_dwd_wbi": "dwd_wbi", "maybe_mesh_frequenz": "frequenz",
            "maybe_mesh_stromausfall": "stromausfall", "maybe_mesh_nina_bayern": "nina_bayern"}
_fh2_tls = _fh2_th.local()
_fh2_lk = _fh2_th.RLock()
_fh2_t0 = _fh2_t.time()
_fh2 = {"sent": {}, "fail": {}, "clear": {}, "ctx": {}, "strom": {"nonempty": False, "empty_t": None},
        "rate": {}, "res": {}, "n": _fh2_col.Counter(), "last": _fh2_col.deque(maxlen=40)}


def _fh2_note(kind, msg):
    _fh2["n"][kind] += 1
    _fh2["last"].append("%s %s %s" % (_fh2_t.strftime("%H:%M:%S"), kind, msg[:120]))
    print("funkHarden2 %s: %s" % (kind, msg[:160]), flush=True)


def _fh2_quiet():
    f = globals().get("_mbq_quiet")
    if callable(f):
        try:
            return bool(f())
        except Exception:
            pass
    return (_fh2_t.time() - _fh2_t0) < 300


def _fh2_norm(text):
    t = str(text or "").lower()
    t = _fh2_re.sub(r"\d+[.,:]\d+", "#", t)
    t = _fh2_re.sub(r"\d{2,}", "#", t)
    return _fh2_re.sub(r"\s+", " ", t).strip()[:240]


def _fh2_is_clear(text):
    t = str(text or "").lower()
    return any(w in t for w in FH2_CLEAR_WORDS)


def _fh2_luft_allowed():
    try:
        import mesh_rules as _fh2_mr
        rules = _fh2_mr.load_rules().get("rules") or {}
        return bool((rules.get("luft") or {}).get("m1_auto")) or bool((rules.get("firms") or {}).get("m1_auto"))
    except Exception:
        return False


def _fh2_k(text, tag, mesh):
    """Schluessel: Entwarnung gilt je vorheriger Warnung (neue Warnung -> neue Entwarnung erlaubt)."""
    norm = _fh2_norm(text)
    clear = _fh2_is_clear(text)
    ctx = _fh2["ctx"].get((tag, mesh)) if clear else None
    return (tag, mesh, norm, ctx), clear, norm


def _fh2_gate(text, mesh):
    """None = senden; True/False = nicht senden, diesen Wert zurueckgeben."""
    tag = getattr(_fh2_tls, "tag", None)
    if tag is None or getattr(_fh2_tls, "manual", False) or getattr(_fh2_tls, "in_chunks", False):
        return None
    now = _fh2_t.time()
    with _fh2_lk:
        key, clear, norm = _fh2_k(text, tag, mesh)
        ck = (tag, mesh)
        if tag in FH2_QUIET_LEARN and _fh2_quiet():
            _fh2["sent"][key] = now
            if not clear:
                _fh2["ctx"][ck] = norm
            _fh2_note("ruhe", "%s nach Start nur gemerkt: %s" % (tag, norm[:60]))
            return True
        if tag == "luft" and not _fh2_luft_allowed():
            _fh2_note("regel", "luft Auto laut Regeln aus (oder Regeln unlesbar) - nicht gesendet")
            return False
        t_last = _fh2["sent"].get(key)
        if t_last and now - t_last < FH2_HOLD.get(tag, 7200):
            if not clear:
                _fh2["ctx"][ck] = norm
            _fh2["clear"].pop(ck, None)
            _fh2_note("halte", "%s gleiche Meldung vor %d min schon gesendet: %s" % (tag, (now - t_last) // 60, norm[:60]))
            return True
        f = _fh2["fail"].get(key)
        if f:
            if now - f[1] >= FH2_FAIL_WIN:
                _fh2["fail"].pop(key, None)
            elif f[0] >= FH2_FAIL_MAX:
                _fh2_note("pause", "%s %dx fehlgeschlagen - Pause bis %d min nach erstem Fehler" % (tag, f[0], FH2_FAIL_WIN // 60))
                return False
        if tag in FH2_CLEAR_TAGS:
            if clear:
                p = _fh2["clear"].get(ck)
                if not p or p[0] != norm or now - p[1] > FH2_CLEAR_MAX:
                    _fh2["clear"][ck] = (norm, now)
                    _fh2_note("bestaetigen", "%s Entwarnung vorgemerkt, sendet erst bei 2. Pruefung (>= %d min)" % (tag, FH2_CLEAR_GAP // 60))
                    return False
                if now - p[1] < FH2_CLEAR_GAP:
                    return False
                _fh2["clear"].pop(ck, None)
            else:
                _fh2["clear"].pop(ck, None)
    return None


def _fh2_after(text, mesh, ok):
    tag = getattr(_fh2_tls, "tag", None)
    if tag is None or getattr(_fh2_tls, "manual", False) or getattr(_fh2_tls, "in_chunks", False):
        return
    now = _fh2_t.time()
    with _fh2_lk:
        key, clear, norm = _fh2_k(text, tag, mesh)
        if ok:
            _fh2["sent"][key] = now
            _fh2["fail"].pop(key, None)
            if not clear:
                _fh2["ctx"][(tag, mesh)] = norm
            if len(_fh2["sent"]) > 300:
                for k in sorted(_fh2["sent"], key=_fh2["sent"].get)[:100]:
                    _fh2["sent"].pop(k, None)
        else:
            n, t1 = _fh2["fail"].get(key, (0, now))
            _fh2["fail"][key] = (n + 1, t1)


def _fh2_install_send():
    res = {}
    o1 = globals().get("send_meshtastic")
    if callable(o1) and not getattr(o1, "_fh2", False):
        def send_meshtastic(text, channel=0, *a, **kw):  # funkHarden2 (Parameter channel bleibt sichtbar)
            g = _fh2_gate(text, "m1")
            if g is not None:
                return g
            ok = o1(text, channel, *a, **kw)
            _fh2_after(text, "m1", ok)
            return ok
        send_meshtastic._fh2 = True
        send_meshtastic.__wrapped__ = o1
        globals()["send_meshtastic"] = send_meshtastic
        res["send_meshtastic"] = "neu"
    o2 = globals().get("send_nina_to_bayern")
    if callable(o2) and not getattr(o2, "_fh2", False):
        def send_nina_to_bayern(text, *a, **kw):  # funkHarden2
            g = _fh2_gate(text, "m2")
            if g is not None:
                return g
            ok = o2(text, *a, **kw)
            _fh2_after(text, "m2", ok)
            return ok
        send_nina_to_bayern._fh2 = True
        send_nina_to_bayern.__wrapped__ = o2
        globals()["send_nina_to_bayern"] = send_nina_to_bayern
        res["send_nina_to_bayern"] = "neu"
    for name, mesh in (("send_chunks_local", "m1"), ("send_chunks_bayern", "m2")):
        o = globals().get(name)
        if not callable(o) or getattr(o, "_fh2", False):
            continue

        def _mk(o, mesh, name):
            def _fh2_chunks(chunks, *a, **kw):  # funkHarden2: ganze Meldung pruefen, nicht je Teil
                text = "\n".join(str(c) for c in (chunks or []))
                g = _fh2_gate(text, mesh)
                if g is not None:
                    return g
                prev = getattr(_fh2_tls, "in_chunks", False)
                _fh2_tls.in_chunks = True
                try:
                    ok = o(chunks, *a, **kw)
                finally:
                    _fh2_tls.in_chunks = prev
                _fh2_after(text, mesh, ok)
                return ok
            _fh2_chunks._fh2 = True
            _fh2_chunks.__wrapped__ = o
            _fh2_chunks.__name__ = name
            return _fh2_chunks
        globals()[name] = _mk(o, mesh, name)
        res[name] = "neu"

    def send_meshtastic_to(*a, **kw):  # funkHarden2: tot + gefaehrlich (eigene TCP-Verbindung)
        _fh2_note("gesperrt", "send_meshtastic_to: direkte TCP-Verbindung zum Funkgeraet wuerde die Bridge trennen")
        return False

    def send_nina_both(*a, **kw):  # funkHarden2: tot (nutzte send_meshtastic_to + mesh2_outbox)
        _fh2_note("gesperrt", "send_nina_both: alter Weg, nicht mehr benutzt")
        return False
    for f in (send_meshtastic_to, send_nina_both):
        f._fh2 = True
        if f.__name__ in globals():
            globals()[f.__name__] = f
            res[f.__name__] = "gesperrt"
    return res


def _fh2_is_force(base, a, kw):
    if kw.get("force") is True:
        return True
    try:
        ba = _fh2_insp.signature(base).bind(*a, **kw)
        ba.apply_defaults()
        return ba.arguments.get("force") is True
    except Exception:
        return False


def _fh2_tagwrap(name, tag):
    cur = globals().get(name)
    if not callable(cur):
        return "fehlt"
    if getattr(cur, "_fh2", False):
        return "schon"
    base = _fh2_insp.unwrap(cur)

    def wrapped(*a, **kw):  # funkHarden2
        prev = (getattr(_fh2_tls, "tag", None), getattr(_fh2_tls, "manual", False))
        _fh2_tls.tag = tag
        _fh2_tls.manual = _fh2_is_force(base, a, kw)
        try:
            if not _fh2_tls.manual:
                if tag == "nina_bayern" and globals().get("_nc_mesh2"):
                    if not _fh2.get("nb_noted"):
                        _fh2["nb_noted"] = True
                        _fh2_note("doppelt", "NINA Bayern Auto aus: ninaCalm sendet NINA schon an Mesh 2")
                    return False
                if tag == "stromausfall":
                    items = a[0] if a else kw.get("items")
                    if isinstance(items, list):
                        st = _fh2["strom"]
                        if items:
                            st["nonempty"], st["empty_t"] = True, None
                        elif st["nonempty"]:
                            now = _fh2_t.time()
                            if st["empty_t"] is None:
                                st["empty_t"] = now
                                _fh2_note("bestaetigen", "Stromausfall-Liste leer - Entwarnung erst bei 2. leerer Abfrage")
                                return None
                            if now - st["empty_t"] < FH2_CLEAR_GAP:
                                return None
                            st["nonempty"], st["empty_t"] = False, None
            return cur(*a, **kw)
        finally:
            _fh2_tls.tag, _fh2_tls.manual = prev

    wrapped._fh2 = True
    wrapped._mbq = getattr(cur, "_mbq", False)
    wrapped.__wrapped__ = cur
    wrapped.__name__ = name
    wrapped.__doc__ = getattr(cur, "__doc__", None)
    globals()[name] = wrapped
    return "neu"


def nina_bayern_auto_enabled():  # funkHarden2: eine Definition, bei Fehler AUS
    try:
        import mesh_rules as _fh2_mr
        row = (_fh2_mr.load_rules().get("rules") or {}).get("nina") or {}
        return bool(row.get("m2_auto", False))
    except Exception as e:
        print("nina_bayern_auto_enabled (funkHarden2): Regeln unlesbar -> AUS:", e, flush=True)
        return False


def _fh2_atomic_json(path, data):
    tmp = "%s.tmp-%d-%d" % (path, _fh2_os.getpid(), _fh2_th.get_ident())
    with open(tmp, "w") as f:
        _fh2_json.dump(data, f, ensure_ascii=False)
    _fh2_os.replace(tmp, path)


def note_mesh_tx(which):  # funkHarden2: atomar + Sperre
    """which: local | bayern | both"""
    path = globals().get("MESH_WATCH_TX") or "/home/fmg/prepper-dashboard/mesh_watch_tx.json"
    with _fh2_lk:
        try:
            with open(path) as f:
                d = _fh2_json.load(f)
            if not isinstance(d, dict):
                d = {}
        except Exception:
            d = {}
        now = _fh2_t.time()
        if which in ("local", "both"):
            d["local"] = now
        if which in ("bayern", "both"):
            d["bayern"] = now
        try:
            _fh2_atomic_json(path, d)
        except Exception as e:
            print("watch tx:", e, flush=True)


def set_nina_bayern_auto(enabled):  # funkHarden2: atomar
    with _fh2_lk:
        _fh2_atomic_json(globals().get("NINA_BAYERN_CFG"), {"enabled": bool(enabled)})


def _fh2_rl(key, n, win):
    now = _fh2_t.time()
    with _fh2_lk:
        q = _fh2["rate"].setdefault(key, _fh2_col.deque())
        while q and now - q[0] > win:
            q.popleft()
        if len(q) >= n:
            return False
        q.append(now)
        return True


_fh2_ctrl = _fh2_re.compile("[\x00-\x08\x0b-\x1f\x7f]")


def _fh2_check_payload():
    """(ok, fehler) fuer text/channel aus JSON oder Formular."""
    from flask import request as _rq
    if _rq.is_json:
        data = _rq.get_json(silent=True)
        if not isinstance(data, dict):
            return False, "json ungueltig"
        text, ch = data.get("text"), data.get("channel")
    else:
        text, ch = _rq.form.get("text"), (_rq.form.get("channel") or _rq.args.get("ch"))
    if text is not None and not isinstance(text, str):
        return False, "text ungueltig"
    if text and _fh2_ctrl.search(text.replace("\t", " ")):
        return False, "Steuerzeichen im Text"
    if ch not in (None, ""):
        if isinstance(ch, bool):
            return False, "channel ungueltig (0-7)"
        try:
            c = int(str(ch).strip()) if not isinstance(ch, (int, float)) else ch
            if isinstance(c, float) and c != int(c):
                raise ValueError
            c = int(c)
        except Exception:
            return False, "channel ungueltig (0-7)"
        if not 0 <= c <= 7:
            return False, "channel ungueltig (0-7)"
    return True, None


def _fh2_install_routes():
    res = {}
    try:
        from flask import request as _rq, jsonify as _js
    except Exception as e:
        return {"routes": "flask fehlt: %s" % e}
    vf_all = app.view_functions

    def _wrap(ep, fn):
        vf = vf_all.get(ep)
        if vf is None:
            res[ep] = "fehlt"
            return None
        if getattr(vf, "_fh2", False):
            res[ep] = "schon"
            return None
        w = _fh2_ft.wraps(vf)(fn(vf))
        w._fh2 = True
        vf_all[ep] = w
        res[ep] = "neu"
        return w

    def _test(vf):
        def v(*a, **kw):  # funkHarden2: nur Button
            if _rq.method != "POST":
                sfs = _rq.headers.get("Sec-Fetch-Site", "")
                sfm = _rq.headers.get("Sec-Fetch-Mode", "")
                pre = _rq.headers.get("Sec-Purpose", "") or _rq.headers.get("Purpose", "")
                if not (sfs == "same-origin" and sfm in ("cors", "same-origin") and not pre):
                    _fh2_note("api", "/api/mesh_test GET ohne Button abgelehnt")
                    return _js({"ok": False, "error": "nur per Button (POST)"}), 405
            if not _fh2_rl("mesh_test", 1, 60):
                return _js({"ok": False, "error": "zu oft - hoechstens 1x pro Minute"}), 429
            return vf(*a, **kw)
        return v

    def _send(key):
        def deco(vf):
            def v(*a, **kw):  # funkHarden2: Eingabe pruefen + 10/min
                ok, err = _fh2_check_payload()
                if not ok:
                    return _js({"ok": False, "error": err}), 400
                if not _fh2_rl(key, 10, 60):
                    return _js({"ok": False, "error": "zu oft - hoechstens 10 pro Minute"}), 429
                return vf(*a, **kw)
            return v
        return deco

    w = _wrap("api_mesh_test", _test)
    if w is not None:
        try:
            meths = set()
            for r in app.url_map.iter_rules():
                if r.endpoint == "api_mesh_test":
                    meths |= set(r.methods or ())
            if "POST" not in meths:
                app.add_url_rule("/api/mesh_test", endpoint="api_mesh_test", view_func=w, methods=["POST"])
        except Exception as e:
            res["api_mesh_test_post"] = "Fehler: %s" % e
    _wrap("api_mesh_send", _send("mesh1_send"))
    _wrap("api_mesh2_send", _send("mesh2_send"))

    def fh2_status():  # funkHarden2: nur lesen
        with _fh2_lk:
            return _js({"funkHarden2": 1, "res": _fh2["res"], "quiet": _fh2_quiet(),
                        "count": dict(_fh2["n"]), "last": list(_fh2["last"]),
                        "nina_mesh2_ninacalm": bool(globals().get("_nc_mesh2")),
                        "hold_entries": len(_fh2["sent"])})
    if "fh2_status" not in vf_all:
        try:
            app.add_url_rule("/api/funk/harden", endpoint="fh2_status", view_func=fh2_status, methods=["GET"])
            res["fh2_status"] = "neu"
        except Exception as e:
            res["fh2_status"] = "Fehler: %s" % e
    return res


def _fh2_install():
    res = {}
    res.update(_fh2_install_send())
    for name, tag in FH2_TAGS.items():
        res[tag] = _fh2_tagwrap(name, tag)
    res.update(_fh2_install_routes())
    _fh2["res"] = res
    print("funkHarden2 aktiv: %s" % res, flush=True)
    return res


try:
    _fh2_install()
except Exception as _fh2_e:
    print("funkHarden2 install:", _fh2_e, flush=True)
# ===== /funkHarden2 =====

'''

FH_OLD1 = '                    m["ping_tx"] = _age(rs.get("last_tx_age"))\n'
FH_NEW1 = ('                    m["ping_tx"] = _age(rs.get("last_reply_age") if rs.get("last_reply_age") is not None else rs.get("last_tx_age"))  # funkHarden2\n'
           '                    m["tx_all"] = _age(rs.get("last_tx_age"))  # funkHarden2\n')
FH_OLD2 = '  <div class="k">Ping TX</div><div>{{ m.ping_tx or "–" }}</div>\n'
FH_NEW2 = ('  <div class="k">Ping-Antwort</div><div>{{ m.ping_tx or "–" }}</div>\n'
           '  <div class="k">TX gesamt</div><div>{{ m.tx_all or "–" }}</div>\n')
FH_OLD3 = '            m["ping_tx"] = "–"\n'
FH_NEW3 = '            m["ping_tx"] = "–"\n            m["tx_all"] = "–"  # funkHarden2\n'
HTML_OLD = 'fetch("/api/mesh_test")'
HTML_NEW = 'fetch("/api/mesh_test",{method:"POST"})'
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
DASH_NEED = ["send_meshtastic", "send_nina_to_bayern", "send_chunks_local", "send_chunks_bayern",
             "maybe_mesh_spaceweather", "maybe_mesh_odl", "maybe_mesh_luft", "maybe_mesh_pegel",
             "maybe_mesh_dwd", "maybe_mesh_dwd_wbi", "maybe_mesh_frequenz", "maybe_mesh_stromausfall",
             "maybe_mesh_nina_bayern", "maybe_mesh_nina", "nina_bayern_auto_enabled", "note_mesh_tx",
             "set_nina_bayern_auto", "api_mesh_test", "api_mesh_send", "api_mesh2_send", "_mbq_quiet", "_mbq_wrap"]


def sha16(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]


def top_defs(src):
    t = ast.parse(src)
    return {n.name for n in t.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))}


def before_main(src, block):
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__-Block %d mal" % len(ms))
    p = ms[0].start()
    return src[:p].rstrip("\n") + "\n\n" + block + "\n\n" + src[p:]


def p_bridge(src, name):
    need = {"worker", "send_now", "ensure_iface", "connect", "is_held", "log", "Handler", "main"}
    miss = need - top_defs(src)
    if miss:
        raise SystemExit("STOP %s: fehlt %s" % (name, ",".join(sorted(miss))))
    for frag in ("_send_q", "STATION", "SEND_GAP", "RECONNECT_WAIT", "def do_POST(self):", "def log_message(self, fmt, *args):"):
        if frag not in src:
            raise SystemExit("STOP %s: Anker fehlt %s" % (name, frag))
    if name == "mesh_bridge_bayern.py" and "# ===== funkHarden m2:" not in src:
        raise SystemExit("STOP %s: funkHarden fehlt" % name)
    if name == "mesh_bridge.py" and "# ===== funkHarden m1:" not in src:
        raise SystemExit("STOP %s: funkHarden fehlt" % name)
    return before_main(src, BRIDGE_BLOCK), "neu"


def p_rw(src, name):
    need = {"_path", "_load", "_save", "note_rx", "note_tx", "status"}
    if need - top_defs(src):
        raise SystemExit("STOP %s: fehlt %s" % (name, need - top_defs(src)))
    if "if __name__" in src:
        raise SystemExit("STOP %s: unerwarteter __main__" % name)
    return src.rstrip("\n") + "\n" + RW_BLOCK, "neu"


def p_hw(src, name):
    if "_systemctl_restart" not in top_defs(src) or "import subprocess" not in src:
        raise SystemExit("STOP %s: _systemctl_restart/subprocess fehlt" % name)
    return before_main(src, HW_BLOCK), "neu"


def p_fh(src, name):
    for o in (FH_OLD1, FH_OLD2, FH_OLD3):
        if src.count(o) != 1:
            raise SystemExit("STOP %s: Anker %d mal: %s" % (name, src.count(o), o.strip()[:50]))
    s = src.replace(FH_OLD1, FH_NEW1).replace(FH_OLD2, FH_NEW2).replace(FH_OLD3, FH_NEW3)
    return s.rstrip("\n") + "\n# ===== funkHarden2 funk: Ping-Antwort + TX gesamt =====\n", "neu"


def p_dash(src, name):
    defs = top_defs(src)
    miss = [n for n in DASH_NEED if n not in defs]
    if miss:
        raise SystemExit("STOP %s: fehlt %s" % (name, ",".join(miss)))
    for frag in ("app = Flask(", "# ===== /meshBootQuiet =====", "_mbq_install()"):
        if frag not in src:
            raise SystemExit("STOP %s: Anker fehlt %s" % (name, frag))
    if src.index("# ===== /meshBootQuiet =====") > MAIN_RE.search(src).start():
        raise SystemExit("STOP %s: meshBootQuiet nach __main__" % name)
    s = before_main(src, DASH_BLOCK)
    n = s.count(HTML_OLD)
    s = s.replace(HTML_OLD, HTML_NEW)
    return s, "neu (Button POST %d)" % n


PATCH = {"mesh_bridge.py": p_bridge, "mesh_bridge_bayern.py": p_bridge, "mesh_reply_watch.py": p_rw,
         "mesh_hang_watchdog.py": p_hw, "funk_health.py": p_fh, "dashboard.py": p_dash}


def main():
    root = Path(sys.argv[1])
    stage = sys.argv[2]
    nosha = "--nosha" in sys.argv[3:]
    out = {}
    for name in STAGES[stage]:
        f = root / name
        if not f.is_file():
            raise SystemExit("STOP: fehlt %s - nichts geaendert" % f)
        src = f.read_text(encoding="utf-8")
        if MARK in src:
            out[name] = (None, "schon")
            continue
        h = sha16(src)
        if h != EXPECT[name] and not nosha:
            raise SystemExit("STOP: %s sha16 %s statt %s (Live-Stand anders als geprueft) - nichts geaendert" % (name, h, EXPECT[name]))
        new, info = PATCH[name](src, name)
        ast.parse(new)
        compile(new, str(f), "exec")
        out[name] = (new, info)
    for name, (new, info) in out.items():
        if new is not None:
            (root / name).write_text(new, encoding="utf-8")
        print("RESULT %s=%s" % (name, info))


if __name__ == "__main__":
    main()
PATCHPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
[[ -x "$VPY" ]] || VPY=python3
echo "=== funkHarden2 apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-funk-harden2.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
trees = [("patch", ast.parse(src))]
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id.endswith("_BLOCK") for t in n.targets):
        trees.append((n.targets[0].id, ast.parse(n.value.value)))
hit = False
for nm, tree in trees:
    for node in ast.walk(tree):
        tg = node.targets if isinstance(node, ast.Assign) else ([node.target] if isinstance(node, (ast.AnnAssign, ast.AugAssign)) else [])
        for t in tg:
            if isinstance(t, ast.Name) and t.id == "data_store":
                print(nm, "data_store-Zuweisung Zeile", node.lineno); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if fn in ("update_all", "TCPInterface", "sendText", "sendData", "sendHeartbeat", "urlopen", "create_connection"):
                print(nm, "verbotener Aufruf", fn, "Zeile", node.lineno); hit = True
            if isinstance(f, ast.Attribute) and f.attr in ("post", "get", "request") and isinstance(f.value, ast.Name) and f.value.id in ("requests", "_rq_http", "urllib"):
                print(nm, "neuer Netz-Aufruf", f.attr, "Zeile", node.lineno); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein data_store, kein update_all, kein sendText/TCP/HTTP-Sendeweg im Patch)"

# ---------- 1) Live-Stand pruefen ----------
bad=0
for f in $S1 $S2; do
  [[ -f "$DASH_DIR/$f" ]] || { echo "STOP: fehlt $f - nichts geaendert"; exit 1; }
  h=$(sha256sum "$DASH_DIR/$f" | cut -c1-16)
  if grep -q '# ===== funkHarden2' "$DASH_DIR/$f"; then st=schon
  elif python3 -c "import sys; sys.path.insert(0, '$W'); import importlib.util as u; s=u.spec_from_file_location('p', '$P'); m=u.module_from_spec(s); s.loader.exec_module(m); sys.exit(0 if m.EXPECT['$f'] == '$h' else 1)"; then st=geprueft
  else st=ANDERS; bad=1; fi
  echo "  $f $h $st"
done
[[ "$bad" -eq 0 ]] || { echo "STOP: Live-Datei weicht vom geprueften Stand ab - NICHTS geaendert. Bitte Ausgabe schicken."; exit 1; }

# ---------- 2) Trockenlauf ----------
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
for f in $S1 $S2; do cp -a "$DASH_DIR/$f" "$W/work/"; done
python3 "$P" "$W/work" bridges > "$W/dry1.txt" 2>&1 || { cat "$W/dry1.txt"; echo "STOP: Trockenlauf Bridges - nichts geaendert"; exit 1; }
python3 "$P" "$W/work" dash > "$W/dry2.txt" 2>&1 || { cat "$W/dry2.txt"; echo "STOP: Trockenlauf Dashboard - nichts geaendert"; exit 1; }
cat "$W/dry1.txt" "$W/dry2.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" bridges > /dev/null && python3 "$P" "$W/work" dash > /dev/null
for f in $S1 $S2; do
  cmp -s "$W/work/$f" "$W/work1/$f" || { echo "STOP: nicht idempotent ($f) - nichts geaendert"; exit 1; }
  "$VPY" -m py_compile "$W/work/$f" || { echo "STOP: py_compile $f - nichts geaendert"; exit 1; }
done
/usr/bin/python3 -m py_compile "$W/work/mesh_hang_watchdog.py" || { echo "STOP: System-Python Hang-Watchdog - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert (venv + System-Python)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /funk /mesh /mesh2 /luft /pi; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /funk=${PRE[/funk]} /mesh=${PRE[/mesh]} /mesh2=${PRE[/mesh2]} /luft=${PRE[/luft]} /pi=${PRE[/pi]}"
sudo -v
mainpid() { systemctl show -p MainPID --value "$1" 2>/dev/null || echo 0; }

# ---------- 3) Stufe 1: Bridges ----------
rb1() {
  echo "ROLLBACK Stufe 1 (Bridges): $1"
  for f in $S1; do [[ -f "$DASH_DIR/$f.bak-fh2-$TS" ]] && cp -a "$DASH_DIR/$f.bak-fh2-$TS" "$DASH_DIR/$f"; done
  sudo systemctl restart mesh-bridge-bayern.service mesh-bridge.service || true
  echo "alter Bridge-Stand wieder aktiv"
}
ch1=0
for f in $S1; do cmp -s "$W/work/$f" "$DASH_DIR/$f" || ch1=1; done
if [[ "$ch1" -eq 0 ]]; then
  echo "OK Stufe 1 hat funkHarden2 schon - kein Neustart"
else
  for f in $S1; do cp -a "$DASH_DIR/$f" "$DASH_DIR/$f.bak-fh2-$TS"; cp "$W/work/$f" "$DASH_DIR/$f"; done
  for f in $S1; do "$VPY" -m py_compile "$DASH_DIR/$f" || { rb1 "py_compile $f"; exit 1; }; done
  hw=$(cd "$DASH_DIR" && /usr/bin/python3 -c 'import mesh_hang_watchdog as h; print(h._fh2_unit_state("mesh-ping-reply.service")[1])' 2>&1 | tail -1 || true)
  echo "Hang-Watchdog (System-Python) sieht mesh-ping-reply: $hw"
  [[ -n "$hw" && "$hw" != *Error* && "$hw" != *Traceback* ]] || { rb1 "Hang-Watchdog laedt nicht"; exit 1; }
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl restart mesh-bridge-bayern.service
  echo "Mesh-2-Bridge neu gestartet - warte auf Verbindung (max 120 s, sendet nichts) ..."
  ok=0
  for i in $(seq 1 60); do
    sleep 2
    st=$(systemctl is-active mesh-bridge-bayern 2>/dev/null || true)
    [[ "$st" == "failed" || "$st" == "inactive" ]] && break
    pid=$(mainpid mesh-bridge-bayern)
    if python3 - "$STATUS2" "$pid" << 'PY'
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if (str(d.get("pid")) == sys.argv[2] and d.get("connected") is True and time.time() - float(d.get("ts") or 0) < 90) else 1)
except Exception:
    sys.exit(1)
PY
    then ok=1; break; fi
    (( i % 10 == 0 )) && echo "  ... $((i*2)) s, Dienst=$st"
  done
  sudo journalctl -u mesh-bridge-bayern --since "$SINCE" --no-pager -o cat 2>/dev/null > "$W/j2.txt" || true
  grep -E 'funkHarden2|Traceback' "$W/j2.txt" | head -3 || true
  [[ "$ok" -eq 1 ]] || { rb1 "Mesh 2 nach 120 s nicht verbunden"; exit 1; }
  grep -q 'funkHarden2 aktiv (m2)' "$W/j2.txt" || { rb1 "Mesh 2: neuer Code laeuft nicht"; exit 1; }
  echo "OK Mesh 2 verbunden mit funkHarden2 (PID $(mainpid mesh-bridge-bayern))"
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl restart mesh-bridge.service
  echo "Mesh-1-Bridge neu gestartet - warte auf Verbindung (max 120 s, sendet nichts) ..."
  ok=0
  for i in $(seq 1 60); do
    sleep 2
    st=$(systemctl is-active mesh-bridge 2>/dev/null || true)
    [[ "$st" == "failed" || "$st" == "inactive" ]] && break
    h=$("${CURL[@]}" "http://127.0.0.1:5001/health" || true)
    if echo "$h" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("connected") is True else 1)' 2>/dev/null; then ok=1; break; fi
    (( i % 10 == 0 )) && echo "  ... $((i*2)) s, Dienst=$st"
  done
  sudo journalctl -u mesh-bridge --since "$SINCE" --no-pager -o cat 2>/dev/null > "$W/j1.txt" || true
  grep -E 'funkHarden2|Traceback' "$W/j1.txt" | head -3 || true
  [[ "$ok" -eq 1 ]] || { rb1 "Mesh 1 nach 120 s nicht verbunden"; exit 1; }
  grep -q 'funkHarden2 aktiv (m1)' "$W/j1.txt" || { rb1 "Mesh 1: neuer Code laeuft nicht"; exit 1; }
  echo "OK Mesh 1 verbunden mit funkHarden2 (PID $(mainpid mesh-bridge))"
fi

# ---------- 4) Stufe 2: Dashboard ----------
rb2() {
  echo "ROLLBACK Stufe 2 (Dashboard): $1"
  for f in $S2; do [[ -f "$DASH_DIR/$f.bak-fh2-$TS" ]] && cp -a "$DASH_DIR/$f.bak-fh2-$TS" "$DASH_DIR/$f"; done
  sudo systemctl restart prepper-dashboard.service || true
  for i in $(seq 1 60); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
  echo "alter Dashboard-Stand wieder aktiv (HTTP / = $(code "$B/")), Bridges behalten funkHarden2"
}
ch2=0
for f in $S2; do cmp -s "$W/work/$f" "$DASH_DIR/$f" || ch2=1; done
if [[ "$ch2" -eq 0 ]]; then
  echo "OK Stufe 2 hat funkHarden2 schon - kein Neustart"
else
  for f in $S2; do cp -a "$DASH_DIR/$f" "$DASH_DIR/$f.bak-fh2-$TS"; cp "$W/work/$f" "$DASH_DIR/$f"; done
  for f in $S2; do "$VPY" -m py_compile "$DASH_DIR/$f" || { rb2 "py_compile $f"; exit 1; }; done
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; 5 min Ruhezeit, sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb2 "Dashboard antwortet nicht"; exit 1; }
  "${CURL[@]}" "$B/api/funk/harden" -o "$W/h.json" || true
  python3 - "$W/h.json" << 'PY' || { rb2 "funkHarden2 im Dashboard nicht aktiv"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
res = d.get("res") or {}
need = ["send_meshtastic", "send_nina_to_bayern", "dwd", "dwd_wbi", "stromausfall", "pegel", "api_mesh_test", "api_mesh_send", "api_mesh2_send"]
bad = [k for k in need if not str(res.get(k, "")).startswith(("neu", "schon"))]
print("Dashboard funkHarden2:", ", ".join("%s=%s" % (k, res.get(k)) for k in need))
print("Ruhezeit aktiv:", d.get("quiet"), "| ninaCalm sendet Mesh 2:", d.get("nina_mesh2_ninacalm"))
sys.exit(0 if d.get("funkHarden2") == 1 and not bad else 1)
PY
  fk=$("${CURL[@]}" -L --max-redirs 5 "$B/funk" || true)
  echo "$fk" | grep -q 'Ping-Antwort' || { rb2 "/funk zeigt neue Zeile nicht"; exit 1; }
  echo "OK Dashboard laeuft mit funkHarden2"
fi
fail=0
for p in / /funk /mesh /mesh2 /luft /pi; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
[[ "$fail" -eq 0 ]] || { rb2 "Seite antwortet schlechter als vorher"; exit 1; }
n1=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.141\]?:4403$/' | wc -l)
n2=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.140\]?:4403$/' | wc -l)
c1=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^CLOSE-WAIT/ && $5 ~ /4403$/' | wc -l)
echo "TCP Pi -> Mesh1 ESTAB=$n1 | Mesh2 ESTAB=$n2 | CLOSE-WAIT=$c1"
g=""
for f in $S1 $S2; do grep -q '# ===== funkHarden2' "$DASH_DIR/$f" && g="$g 1" || g="$g 0"; done
fh2=1; [[ "$g" == *0* ]] && fh2=0
echo "OK guards funkHarden2=$fh2 (Dateien:$g) funkHarden=$(grep -q '# ===== funkHarden m2:' "$DASH_DIR/mesh_bridge_bayern.py" && echo 1 || echo 0) mesh2Calm=$(grep -q '# ===== mesh2Calm:' "$DASH_DIR/mesh_bridge_bayern.py" && echo 1 || echo 0) meshBootQuiet=$(grep -q '# ===== /meshBootQuiet' "$DASH" && echo 1 || echo 0)"
echo "Backups: *.bak-fh2-$TS"
echo "OK funkHarden2 fertig: keine Doppel-/Flattersendungen, Eingaben geprueft, Status unter /api/funk/harden"
echo "COMMIT $COMMIT_ARG funkHarden2=$fh2"
