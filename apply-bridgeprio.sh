#!/bin/bash
set -euo pipefail
# bridgeprio (commit21): Bridges: Prioritaetswarteschlange - Alarm vor Routine, kurze Obergrenze fuer Routine-Nachrichten (PERF-05 des Audits)
# Befund: Die Sende-Queue beider Bridges war eine einfache FIFO-Warteschlange (50 Plaetze, 3 s Abstand je Nachricht). Ein Alarm hinter 50 Routine-Nachrichten haette bis zu 2,5 Minuten gewartet oder (bei voller Queue) gar nicht angenommen.
# Neu: Warteschlange nach Prioritaet. Alarm (Text beginnt mit ALARM  / ALARM: / NINA: ) geht vor NINA-Details, vor Routine (Pong, Wetter, Pegel, Knoepfe), vor Test-Eintraegen; je Prioritaet bleibt die Reihenfolge (FIFO).
#   Routine-Nachrichten: hoechstens 10 gleichzeitig in der Queue (die elfte bekommt wie bisher bei voller Queue 429 queue full). Alarme zaehlen nicht dazu; ist die Queue voll, verdraengt ein Alarm die juengste Nachricht der niedrigsten Prioritaet.
#   Der Sendeabstand (3 s), der Doppelsendeschutz (120 s je Text und Kanal), Hold, Ruhezeit (Mesh 2) und alle Fehlerpfade bleiben unveraendert; der Abstand wird jetzt VOR dem Entnehmen abgewartet, damit ein waehrenddessen eingetroffener Alarm als Naechster rausgeht.
#   Optional im POST /send: prio 0..9 (sonst nach Text); ungueltig = 400. /health bekommt q_alarm, q_routine, prio (alle bisherigen Schluessel bleiben). mesh_router.py und das Dashboard werden nicht angefasst (6 h Dedup und max. 3 Alarme je Stunde liegen im Router).
# Pruefungen im Skript: sha16-Basis, sha256 der eingebetteten Dateien, py_compile (System-Python und venv), Guard (statisch, Stufe prio) mit Mutationstest, Regressionstest alt gegen neu und Prioritaets-/Zeitsimulation in der Sandbox (Fakes, nichts gesendet).
# Nach dem Einspielen: nur mesh-bridge.service und mesh-bridge-bayern.service werden neu gestartet (vorher: kein Hold, Warteschlange leer), danach Selbstpruefung (Prozess, /health inkl. q_alarm, Journal), sonst Rollback.
# Wichtig: Die Warteschlange der Bridge liegt im Arbeitsspeicher. Deshalb startet das Skript nur bei leerer Warteschlange und nie waehrend eines Hold. Basis dieses Patches ist commit20 (bridgededup).
# Aendert NUR: mesh_bridge.py, mesh_bridge_bayern.py im Projektordner. Keine Konfiguration, keine Secrets, nichts wird gesendet (kein Mesh, kein Telegram, keine Alarme, kein /send-Aufruf).
# Neustart: nur die betroffenen Bridge-Dienste (mesh-bridge.service, mesh-bridge-bayern.service), nie das Dashboard. Selbstpruefung nach dem Start, bei Fehler automatischer Rollback.
# Basis streng (sha16): alt oder neu akzeptiert, alles andere = STOP mit Diff, nichts geaendert.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
APPLY_NAME="bridgeprio"
DASH_DIR="/home/fmg/prepper-dashboard"
SVC1="mesh-bridge.service"; SVC2="mesh-bridge-bayern.service"
P1=5001; P2=5002
SYSTEMCTL=systemctl; SUDO=sudo; JOURNALCTL=journalctl
WAIT_Q=90; WAIT_UP=60; SLEEP=1
TS=$(date +%Y%m%d-%H%M%S)
KEEP_LAST=3
W=/tmp/bridgeprio-apply
if [[ "${BRIDGEAPPLY_TEST:-}" == 1 ]]; then   # nur fuer den Sandbox-Test des Apply-Skripts (Fakes, Port 5093)
  DASH_DIR="${BA_DASH:-$DASH_DIR}"; SYSTEMCTL="${BA_SYSTEMCTL:-$SYSTEMCTL}"; SUDO="${BA_SUDO:-$SUDO}"; JOURNALCTL="${BA_JOURNALCTL:-$JOURNALCTL}"
  P1="${BA_P1:-$P1}"; P2="${BA_P2:-$P2}"; WAIT_Q="${BA_WAIT_Q:-$WAIT_Q}"; WAIT_UP="${BA_WAIT_UP:-$WAIT_UP}"; SLEEP="${BA_SLEEP:-$SLEEP}"; TS="${BA_TS:-$TS}"
fi
PORT="${DASH_PORT:-5000}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
echo "=== bridgeprio apply ($COMMIT_ARG): mesh_bridge.py, mesh_bridge_bayern.py (nur Bridges; Dashboard bleibt unangetastet), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/new" "$W/base" "$W/test" "$W/sb"
F_NAME=("mesh_bridge.py" "mesh_bridge_bayern.py")
F_BASE16=("66fd139f02a2af4c" "fe2bf6f7de4ad59a")
F_NEW16=("1d790f663876fd7f" "1ce381878372527f")
G1="mesh_bridge.py"
G2="mesh_bridge_bayern.py"
EXPECT_1="1d790f663876fd7fd59c549abbe1b1417b6306af1cb35929ac46c81423ae9af8"
mkdir -p "$W/new"
cat > "$W/new/mesh_bridge.py" << 'BA_EMBED_1_EOF'
#!/usr/bin/env python3
"""G2-Bridge (Mesh 1): eine TCP-Session, Queue, Pong, Inbox.

bridgeDedup (MOD-02): jede Funktion genau einmal definiert. Die frueheren Schichten funkHarden, funkHarden2 und mesh1Fresh
(Umhuellungen am Dateiende) sind in die jeweils wirksame Funktion eingearbeitet, das Verhalten ist unveraendert.

bridgePrio (PERF-05): Sende-Queue mit Prioritaeten (Alarm vor Routine, siehe _SendQueue); Sendeabstand SEND_GAP, Doppelsendeschutz und alle
anderen Regeln unveraendert."""
from __future__ import annotations

import hashlib
import heapq
import json
import queue
import re
import sys
import threading
import time
import traceback
from collections import OrderedDict, deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import mesh_chutil  # /* chutilBridge */
import mesh_node_label  # /* pingName */
import mesh_reply_watch  # meshHangBridge

sys.path.insert(0, "/home/fmg/prepper-dashboard")
try:
    from config import MESHTASTIC_HOST
except Exception:
    MESHTASTIC_HOST = "192.168.178.141"

HOST = MESHTASTIC_HOST
LISTEN = ("127.0.0.1", 5001)
SEND_GAP = 3.0
RECONNECT_WAIT = 5.0
STATION = "Station Kalchreuth"
TRIGGERS = {"ping","pong","test","!ping","!test","wetter","pegel","odl","freq","frequenz","status","help","hilfe","nina","gas","nina test"}
INBOX_FILE = Path("/home/fmg/prepper-dashboard/mesh_inbox.json")
INBOX_DIR = Path("/home/fmg/prepper-dashboard/mesh_inbox")
INBOX_MAX = 300
HOLD_MAX = 3 * 3600  # 3 Stunden manuell getrennt
CHUTIL_FILE = Path("/home/fmg/prepper-dashboard/mesh1_chutil.json")
  # /* chutilBridge */

# ----- bridgePrio (PERF-05): Prioritaetswarteschlange - Alarm vor Routine, kurze Obergrenze fuer Routine-Nachrichten -----
PRIO_ALARM = 0        # echte Alarme: Text beginnt mit "ALARM " / "ALARM:" / "NINA: " (oder "prio": 0 im POST-Koerper)
PRIO_DETAIL = 1       # NINA-Details ("NINA Details: ...") kommen nach der Kurzmeldung
PRIO_ROUTINE = 5      # alles andere (Pong, Wetter, Pegel, Knoepfe ...)
PRIO_TEST = 9         # Probe/Test: nur Reihenfolge (Probe-/Testalarme gehen nie ins Mesh - das stellt der Router sicher)
ROUTINE_MAX = 10      # hoechstens so viele Nachrichten mit Prioritaet >= 5 gleichzeitig in der Warteschlange
_ALARM_PREFIX = ("ALARM ", "ALARM:", "NINA: ")
_pq = {"alarm": 0, "overtake": 0, "routine_full": 0, "displaced": 0}


def _prio_of(item):
    """Prioritaet eines Eintrags (str oder dict): "prio" 0-9 im dict gewinnt, sonst nach Textanfang."""
    text = item
    if isinstance(item, dict):
        p = item.get("prio")
        if isinstance(p, int) and not isinstance(p, bool) and 0 <= p <= 9:
            return p
        text = item.get("text")
    t = str(text or "").lstrip()
    if t.startswith(_ALARM_PREFIX):
        return PRIO_ALARM
    if t.startswith("NINA Details"):
        return PRIO_DETAIL
    if t[:4].upper() == "TEST" and "keine echte Warnung" in t:
        return PRIO_TEST
    return PRIO_ROUTINE


class _SendQueue(queue.Queue):
    """Sende-Queue als Heap nach (Prioritaet, Eingangsfolge): niedrigere Zahl zuerst, je Prioritaet FIFO. maxsize wie bisher (50 gesamt),
    zusaetzlich hoechstens ROUTINE_MAX Routine-Eintraege (neue Routine -> queue.Full). Ist die Queue voll, verdraengt ein wichtigerer Eintrag
    den juengsten der niedrigsten Prioritaet (statt abgelehnt zu werden). put ist nie blockierend (die Bridge ruft nur put_nowait)."""

    def _init(self, maxsize):
        self.queue = []
        self._seq = 0
        self._nroutine = 0

    def _qsize(self):
        return len(self.queue)

    def _put(self, entry):
        heapq.heappush(self.queue, entry)
        if entry[0] >= PRIO_ROUTINE:
            self._nroutine += 1

    def _get(self):
        entry = heapq.heappop(self.queue)
        if entry[0] >= PRIO_ROUTINE:
            self._nroutine -= 1
        return entry[2]

    def counts(self):
        with self.mutex:
            return sum(1 for e in self.queue if e[0] < PRIO_ROUTINE), self._nroutine

    def put(self, item, block=True, timeout=None):
        prio = _prio_of(item)
        with self.not_full:
            if prio >= PRIO_ROUTINE and self._nroutine >= ROUTINE_MAX:
                _pq["routine_full"] += 1
                raise queue.Full
            if self.maxsize > 0 and self._qsize() >= self.maxsize:
                worst = max(self.queue)
                if worst[0] <= prio:
                    raise queue.Full
                self.queue.remove(worst)
                heapq.heapify(self.queue)
                if worst[0] >= PRIO_ROUTINE:
                    self._nroutine -= 1
                self.unfinished_tasks -= 1
                _pq["displaced"] += 1
            overtaken = sum(1 for e in self.queue if e[0] > prio) if prio == PRIO_ALARM else 0
            self._seq += 1
            self._put((prio, self._seq, item))
            self.unfinished_tasks += 1
            self.not_empty.notify()
        if prio == PRIO_ALARM:
            _pq["alarm"] += 1
            if overtaken:
                _pq["overtake"] += 1
                log("bridgePrio: Alarm ueberholt %d wartende Nachricht(en)" % overtaken)


_send_q: queue.Queue = _SendQueue(maxsize=50)
_lock = threading.Lock()
_iface = None
_my_ids = set()
_inbox = deque(maxlen=INBOX_MAX)
_state = {
    "ok": False, "host": HOST, "connected": False, "last_error": "",
    "last_send": None, "last_text": "", "queued": 0,
    "sent_ok": 0, "sent_fail": 0, "last_rx": None, "hold_until": None,
}

# ----- funkHarden2: Doppelsendeschutz, Eingabepruefung, leises HTTP-Log (Konstanten, Zustand) -----
FH2_DUP_SEC = 120      # gleiche Nachricht + Kanal innerhalb 120 s nur einmal
FH2_TEXT_MAX = 220
_fh2 = {"recent": OrderedDict(), "dup": 0, "unsure": 0, "pre_fail": 0, "bad": 0,
        "http_quiet": 0, "replies": 0}
_fh2_ctrl = re.compile("[\x00-\x08\x0b-\x1f\x7f]")

# ----- mesh1Fresh: lastHeard/Node-DB aus der laufenden Sitzung (nur lesen, sendet nichts) -----
_m1f = {"rx": 0.0, "n": 0, "t0": time.time(), "last": OrderedDict()}
M1F_KEEP = 60


def now_str(fmt="%d.%m.%Y %H:%M:%S"):
    return datetime.now().strftime(fmt)


def log(*a):
    print(f"[{now_str()}]", *a, flush=True)


def load_inbox():
    try:
        data = json.loads(INBOX_FILE.read_text())
        if isinstance(data, list):
            for m in data[-INBOX_MAX:]:
                if isinstance(m, dict):
                    _inbox.append(m)
            log("Inbox geladen", len(_inbox))
    except Exception:
        pass


def save_inbox():
    try:
        INBOX_FILE.write_text(json.dumps(list(_inbox), ensure_ascii=False))
    except Exception as e:
        log("Inbox speichern:", e)


KNOWN_NAMES = {
    "!0c18a994": "Station Kalchreuth",
    "!c18a994": "Station Kalchreuth",
    "202942868": "Station Kalchreuth",
}

def node_name(nid):
    if not nid:
        return "?"
    key = str(nid).lower()
    if not key.startswith("!") and key.isdigit():
        try:
            key = f"!{int(key):08x}"
        except Exception:
            pass
    for k, v in KNOWN_NAMES.items():
        if k.lower() == key or k.lower().lstrip("!") == key.lstrip("!"):
            return v
    try:
        nodes = getattr(_iface, "nodes", None) or {}
        for n in nodes.values():
            user = n.get("user") if isinstance(n, dict) else None
            if not user:
                continue
            uid = str(user.get("id") or "").lower()
            longn = user.get("longName") or user.get("shortName")
            if longn and uid and (uid == key or uid.lstrip("!") == key.lstrip("!")):
                return longn
    except Exception:
        pass
    return str(nid)

def add_inbox(text, from_id, snr=None, rssi=None, hops=None, self_pkt=False, channel=0):
    item = {
        "at": now_str(),
        "from": from_id,
        "name": node_name(from_id),
        "text": (text or "")[:220],
        "snr": snr, "rssi": rssi, "hops": hops,
        "self": bool(self_pkt),
        "channel": int(channel or 0),
    }
    _inbox.append(item)
    save_inbox()
    items = load_channel_inbox(item["channel"])
    items.append(item)
    save_channel_inbox(item["channel"], items)
    return item


def is_held():
    t = _state.get("hold_until")
    if not t:
        return False
    if time.time() >= float(t):
        _state["hold_until"] = None
        log("Hold abgelaufen – Auto-Reconnect erlaubt")
        return False
    return True

def hold_bridge():
    _state["hold_until"] = time.time() + HOLD_MAX
    close_iface()
    _state["connected"] = False
    _state["ok"] = False
    _state["last_error"] = "manuell getrennt"
    log("HOLD 3h – TCP frei für anderes Gerät")
    return True

def resume_bridge():
    _state["hold_until"] = None
    _state["last_error"] = ""
    log("RESUME")
    try:
        connect()
        return True
    except Exception as e:
        _state["last_error"] = str(e)[:160]
        log("RESUME Fehler:", e)
        return False


def _ch_file(ch):
    INBOX_DIR.mkdir(parents=True, exist_ok=True)
    return INBOX_DIR / f"ch_{int(ch)}.json"

def load_channel_inbox(ch):
    try:
        data = json.loads(_ch_file(ch).read_text())
        return data if isinstance(data, list) else []
    except Exception:
        return []

def save_channel_inbox(ch, items):
    try:
        _ch_file(ch).write_text(json.dumps(items[-INBOX_MAX:], ensure_ascii=False))
    except Exception as e:
        log("inbox save ch", ch, e)

def list_station_channels():
    out = [{"index": 0, "name": "Primary"}]
    try:
        ln = getattr(_iface, "localNode", None)
        channels = getattr(ln, "channels", None) if ln is not None else None
        if not channels:
            return out
        found = []
        for i, ch in enumerate(channels):
            settings = getattr(ch, "settings", None) or ch
            name = (getattr(settings, "name", None) or "").strip()
            role = str(getattr(ch, "role", "") or "")
            if i == 0 and not name:
                name = "Primary"
            if not name and i > 0:
                continue
            found.append({"index": i, "name": name or f"Kanal {i}", "role": role})
        if found:
            return found
    except Exception as e:
        log("channels:", e)
    return out

def packet_channel(packet):
    try:
        if packet.get("channel") is not None:
            return int(packet.get("channel"))
        dec = packet.get("decoded") or {}
        if dec.get("channel") is not None:
            return int(dec.get("channel"))
    except Exception:
        pass
    return 0

def close_iface():
    global _iface
    if _iface is None:
        return
    try:
        _iface.close()
    except Exception:
        pass
    _iface = None
    _state["connected"] = False


def _collect_my_ids(iface):
    ids = set()
    try:
        info = getattr(iface, "myInfo", None)
        if info is not None:
            mid = getattr(info, "my_node_num", None) or getattr(info, "myNodeNum", None)
            if mid is not None:
                ids.add(int(mid))
                ids.add(f"!{int(mid):x}")
                ids.add(f"!{int(mid):08x}")
    except Exception:
        pass
    return {str(x).lower() for x in ids if x is not None}


def connect():
    global _iface, _my_ids
    close_iface()
    from meshtastic.tcp_interface import TCPInterface
    from pubsub import pub
    log("Verbinde", HOST)
    iface = TCPInterface(hostname=HOST)
    time.sleep(1.2)
    try:
        pub.unsubscribe(on_receive, "meshtastic.receive")
    except Exception:
        pass
    pub.subscribe(on_receive, "meshtastic.receive")
    _iface = iface
    _my_ids = _collect_my_ids(iface)
    _state["connected"] = True
    _state["ok"] = True
    _state["last_error"] = ""
    log("verbunden ids", _my_ids)
    return iface


def ensure_iface():
    if is_held():
        raise RuntimeError("Bridge manuell getrennt")
    with _lock:
        if _iface is not None:
            return _iface
        return connect()


def send_now(text: str, channel: int = 0) -> bool:
    msg = (text or "")[:220]
    if not msg.strip():
        return False
    try:
        iface = ensure_iface()
        iface.sendText(msg, channelIndex=int(channel or 0))
        try:
            mesh_reply_watch.note_tx("m1")  # meshHangBridge
        except Exception:
            pass
        time.sleep(0.4)
        _state["last_send"] = now_str()
        _state["last_text"] = msg.replace("\n", " | ")[:80]
        _state["sent_ok"] += 1
        _state["ok"] = True
        log("OK:", msg.replace("\n", " | ")[:140])
        try:
            add_inbox(msg, "!0c18a994", self_pkt=True, channel=int(channel or 0))
        except Exception as e:
            log("inbox send:", e)
        return True
    except Exception as e:
        _state["ok"] = False
        _state["sent_fail"] += 1
        _state["last_error"] = str(e)[:160]
        log("FEHLER:", e)
        close_iface()
        return False


def _hops(packet):
    try:
        hs, hl = packet.get("hopStart"), packet.get("hopLimit")
        if hs is not None and hl is not None:
            return max(0, int(hs) - int(hl))
    except Exception:
        pass
    return packet.get("hops") or 0


def _from_id(packet):
    fid = packet.get("fromId") or packet.get("from")
    if fid is None:
        return "?"
    if isinstance(fid, int):
        return f"!{fid:08x}"
    s = str(fid)
    if not s.startswith("!"):
        try:
            return f"!{int(s):08x}"
        except Exception:
            return s
    return s


def _is_self(packet):
    fid = str(packet.get("fromId") or packet.get("from") or "").lower()
    if not fid:
        return False
    others = {x.lstrip("!") for x in _my_ids}
    return fid in _my_ids or fid.lstrip("!") in others


def on_receive(packet, interface=None):
    # mesh1Fresh: Empfang von anderen Knoten merken (vor der Basislogik)
    try:
        if isinstance(packet, dict) and (interface is None or interface is _iface) and not _is_self(packet):
            now = time.time()
            _m1f["rx"] = now
            _m1f["n"] += 1
            dec = packet.get("decoded") or {}
            port = str(dec.get("portnum") or ("verschluesselt" if packet.get("encrypted") else "?"))
            fid = _from_id(packet)
            last = _m1f["last"]
            prev = last.pop(fid, None) or {}
            last[fid] = {"ts": now, "port": port, "snr": packet.get("rxSnr"), "rssi": packet.get("rxRssi"),
                         "hops": _hops(packet), "n": int(prev.get("n") or 0) + 1}
            while len(last) > M1F_KEEP:
                last.popitem(last=False)
            _state["rx_other_n"] = _m1f["n"]
            _state["rx_other_at"] = datetime.fromtimestamp(now).strftime("%d.%m.%Y %H:%M:%S")
            _state["rx_other_from"] = fid
            _state["rx_other_port"] = port
    except Exception:
        pass
    # Basis: Inbox fuehren, Ping/Test beantworten
    try:
        if not packet:
            return
        decoded = packet.get("decoded") or {}
        text = (decoded.get("text") or "").strip()
        port = str(decoded.get("portnum") or "")
        if not text and "TEXT" not in port.upper():
            # kein Klartext – trotzdem kein Pong
            pass
        self_pkt = _is_self(packet)
        if text:
            fid = _from_id(packet)
            item = add_inbox(
                text, fid,
                snr=packet.get("rxSnr"),
                rssi=packet.get("rxRssi"),
                hops=_hops(packet),
                self_pkt=self_pkt,
            )
            _state["last_rx"] = f"{item['at']} {item['from']} {text[:40]}"
        if self_pkt or not text:
            return
        if text.lower() not in TRIGGERS:
            return
        t = datetime.now().strftime("%H:%M:%S")
        snr, rssi = packet.get("rxSnr"), packet.get("rxRssi")
        reply = (
            f"{STATION}\nEmpfang {t}\nAntwort {t}\n"
            f"SNR {snr if snr is not None else '–'} dB · RSSI {rssi if rssi is not None else '–'} dBm\n"
            f"Hops {_hops(packet)} · von {mesh_node_label.label_from_iface(_iface, _from_id(packet))}"  # /* pingName */
        )
        log("Pong-Trigger:", text, "von", mesh_node_label.label_from_iface(_iface, _from_id(packet)))  # /* pingName */
        try:
            mesh_reply_watch.note_rx("m1")  # meshHangBridge
        except Exception:
            pass
        try:
            _send_q.put_nowait(reply)
            _state["queued"] = _send_q.qsize()
        except queue.Full:
            log("Queue voll")
    except Exception as e:
        log("on_receive:", e)


def _fh2_mesh_key():
    return "m1"


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
    return "%d:%s" % (ch, hashlib.sha1(text.encode("utf-8", "replace")).hexdigest())


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
    ensure_iface()


def worker():  # funkHarden2: genau ein Schreibversuch je Nachricht, Doppelsendeschutz
    last = 0.0
    while True:
        try:
            # bridgePrio: Sendeabstand VOR dem Entnehmen, damit ein inzwischen eingetroffener Alarm als Naechster rausgeht (Abstand unveraendert SEND_GAP)
            wait = SEND_GAP - (time.time() - last)
            if wait > 0:
                time.sleep(wait)
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


def watchdog():
    while True:
        time.sleep(60)
        try:
            if is_held():
                left = int(float(_state.get("hold_until") or 0) - time.time())
                log("Watchdog: Hold noch", left, "s")
                continue
            if _iface is None or not _state.get("connected"):
                log("Watchdog: reconnect")
                try:
                    with _lock:  # funkHarden: nie parallel zu ensure_iface()
                        connect()
                except Exception as e:
                    _state["ok"] = False
                    _state["last_error"] = str(e)[:160]
                    log("Watchdog:", e)
        except Exception as e:
            log("Watchdog:", e)



class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # funkHarden2: Routine-Abfragen nicht loggen
        try:
            req = str(args[0]) if args else ""
            code = int(args[1]) if len(args) > 1 and str(args[1]).isdigit() else 0
            if code and code < 400 and not any(p in req for p in (" /send", " /hold", " /resume")):
                _fh2["http_quiet"] += 1
                return
        except Exception:
            pass
        log("HTTP", fmt % args)

    def _json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith("/health"):
            held = is_held()
            left = 0
            if held:
                left = max(0, int(float(_state.get("hold_until") or 0) - time.time()))
            q_hi, q_lo = _send_q.counts()
            self._json(200, dict(_state, inbox=len(_inbox), held=held, hold_left=left, q_alarm=q_hi, q_routine=q_lo, prio=dict(_pq)))
            return
        if self.path.startswith("/channels"):
            self._json(200, {"channels": list_station_channels()})
            return
        if self.path.startswith("/inbox"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            ch = qs.get("channel", qs.get("ch", [None]))[0]
            if ch is not None:
                try:
                    chn = int(ch)
                    self._json(200, {"channel": chn, "messages": load_channel_inbox(chn)[-200:]})
                    return
                except Exception:
                    pass
            self._json(200, {"messages": list(_inbox)[-200:]})
            return
        if self.path.startswith("/chutil"):  # mesh1Fresh: /chutil um zuletzt gehoerte Knoten ergaenzen (nur lesen)
            try:
                with _lock:
                    iface = _iface
                    ids = set(_my_ids)
                live = mesh_chutil.pick_local_metrics(iface, ids) if iface else None
                hist = mesh_chutil.hist_payload(CHUTIL_FILE, hours=24)
                rx = _m1f["rx"]
                self._json(200, {"ok": True, "live": live, "hist": hist,
                                 "rx_other_n": _m1f["n"], "rx_other_age_s": (int(time.time() - rx) if rx else None),
                                 "since_start_s": int(time.time() - _m1f["t0"]),
                                 "heard": _m1f_heard(), "nodes_lastheard": _m1f_nodes_lastheard(iface) if iface else []})
            except Exception as e:
                self._json(500, {"ok": False, "error": str(e)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):  # meshSendHarden # meshSendStable # funkHarden2: /send pruefen (Kanal 0-7, Text 1-220, keine Steuerzeichen)
        if self.path.startswith("/hold"):
            hold_bridge()
            self._json(200, dict(_state, held=True))
            return
        if self.path.startswith("/resume"):
            ok = resume_bridge()
            self._json(200, dict(_state, held=is_held(), resume_ok=ok))
            return
        if not self.path.startswith("/send"):
            self._json(404, {"error": "not found"})
            return
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
        prio = data.get("prio")
        if prio is not None and (isinstance(prio, bool) or not isinstance(prio, int) or not 0 <= prio <= 9):
            _fh2["bad"] += 1
            self._json(400, {"ok": False, "error": "prio ungueltig (0-9)"})
            return
        item = {"text": text, "channel": ch}
        if prio is not None:
            item["prio"] = prio
        try:
            _send_q.put_nowait(item)
            _state["queued"] = _send_q.qsize()
            self._json(200, {"ok": True, "queued": _state["queued"]})
        except queue.Full:
            self._json(429, {"ok": False, "error": "queue full"})


def chutil_worker():  # /* chutilBridge */
    """DeviceMetrics periodisch in CHUTIL_FILE schreiben (keine 2. TCP-Session)."""
    while True:
        time.sleep(60)
        try:
            with _lock:
                iface = _iface
                ids = set(_my_ids)
            if not iface:
                continue
            r = mesh_chutil.sample_and_store(iface, CHUTIL_FILE, my_ids=ids, min_gap=300)
            if r.get("ok") and r.get("wrote"):
                cur = r.get("current") or {}
                log("chutil", cur.get("ch_util"), "% air", cur.get("air_tx"), cur.get("node"))
        except Exception as e:
            log("chutil:", e)


def main():
    load_inbox()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=watchdog, daemon=True).start()
    threading.Thread(target=chutil_worker, daemon=True).start()  # /* chutilBridge */
    try:
        connect()
    except Exception as e:
        log("Start-Connect:", e)
    httpd = ThreadingHTTPServer(LISTEN, Handler)
    log("Bridge auf http://127.0.0.1:5001")
    httpd.serve_forever()


def _m1f_label(fid):
    try:
        return mesh_node_label.label_from_iface(_iface, fid)
    except Exception:
        return fid


def _m1f_heard(limit=10):
    now = time.time()
    items = sorted(_m1f["last"].items(), key=lambda kv: kv[1]["ts"], reverse=True)[:limit]
    return [{"node": k, "name": _m1f_label(k), "age_s": int(now - v["ts"]), "port": v["port"],
             "snr": v["snr"], "rssi": v["rssi"], "hops": v["hops"], "n": v["n"]} for k, v in items]


def _m1f_nodes_lastheard(iface, limit=8):
    out = []
    try:
        now = time.time()
        for nid, info in (getattr(iface, "nodes", None) or {}).items():
            if not isinstance(info, dict):
                continue
            lh = info.get("lastHeard")
            try:
                lh = float(lh)
            except Exception:
                continue
            if lh > 1e12:
                lh = lh / 1000.0
            if lh > 1e8:
                out.append((lh, nid))
        out.sort(reverse=True)
        return [{"node": n, "name": _m1f_label(n), "age_s": max(0, int(now - t))} for t, n in out[:limit]]
    except Exception:
        return []


def _m1f_pick(iface, my_ids=None):  # mesh1Fresh
    r = _m1f_orig_pick(iface, my_ids)
    if not r or iface is None:
        return r
    try:
        n = len(getattr(iface, "nodes", None) or {})
        if n:
            r["nodedb_myinfo"] = r.get("nodedb")
            r["nodedb"] = n
    except Exception:
        pass
    try:
        if iface is _iface and _m1f["rx"] > 0:
            r["heard_sec"] = max(0, int(time.time() - _m1f["rx"]))
            r["heard_src"] = "bridge-rx"
    except Exception:
        pass
    r["m1fresh"] = 1
    r["rx_other_n"] = _m1f["n"]
    return r


# ===== Schichten, die beim Start aktiv werden (Reihenfolge wie bisher: funkHarden, funkHarden2, mesh1Fresh) =====
def _fh_on_lost(interface=None):  # funkHarden: tote Sitzung -> Watchdog verbindet neu (max 60 s)
    try:
        if interface is not None and interface is _iface and not is_held():
            _state["connected"] = False
            _state["last_error"] = "Verbindung verloren"
            log("funkHarden m1: Verbindung verloren - Watchdog verbindet neu (max 60 s)")
    except Exception:
        pass


def _fh_hook():
    try:
        from pubsub import pub as _fh_pub
        _fh_pub.subscribe(_fh_on_lost, "meshtastic.connection.lost")
        log("funkHarden m1 aktiv: Verlust-Erkennung, Watchdog-Reconnect unter Sperre")
    except Exception as e:
        log("funkHarden m1 lost-hook:", e)


_fh_hook()


log("funkHarden2 aktiv (%s): Doppelsendeschutz %d s, kein Retry nach Schreibfehler, /send geprueft, HTTP-Log leise" % (
    _fh2_mesh_key(), FH2_DUP_SEC))

_m1f_orig_pick = mesh_chutil.pick_local_metrics
mesh_chutil.pick_local_metrics = _m1f_pick
log("mesh1Fresh aktiv: lastHeard = letztes Paket eines anderen Knotens, Node-DB live aus Sitzung")


if __name__ == "__main__":
    main()
BA_EMBED_1_EOF
EXPECT_2="66fd139f02a2af4c66f8ed9632b1213f2c327dc8a8646a484f40d1668255f7a2"
mkdir -p "$W/base"
cat > "$W/base/mesh_bridge.py" << 'BA_EMBED_2_EOF'
#!/usr/bin/env python3
"""G2-Bridge (Mesh 1): eine TCP-Session, Queue, Pong, Inbox.

bridgeDedup (MOD-02): jede Funktion genau einmal definiert. Die frueheren Schichten funkHarden, funkHarden2 und mesh1Fresh
(Umhuellungen am Dateiende) sind in die jeweils wirksame Funktion eingearbeitet, das Verhalten ist unveraendert."""
from __future__ import annotations

import hashlib
import json
import queue
import re
import sys
import threading
import time
import traceback
from collections import OrderedDict, deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import mesh_chutil  # /* chutilBridge */
import mesh_node_label  # /* pingName */
import mesh_reply_watch  # meshHangBridge

sys.path.insert(0, "/home/fmg/prepper-dashboard")
try:
    from config import MESHTASTIC_HOST
except Exception:
    MESHTASTIC_HOST = "192.168.178.141"

HOST = MESHTASTIC_HOST
LISTEN = ("127.0.0.1", 5001)
SEND_GAP = 3.0
RECONNECT_WAIT = 5.0
STATION = "Station Kalchreuth"
TRIGGERS = {"ping","pong","test","!ping","!test","wetter","pegel","odl","freq","frequenz","status","help","hilfe","nina","gas","nina test"}
INBOX_FILE = Path("/home/fmg/prepper-dashboard/mesh_inbox.json")
INBOX_DIR = Path("/home/fmg/prepper-dashboard/mesh_inbox")
INBOX_MAX = 300
HOLD_MAX = 3 * 3600  # 3 Stunden manuell getrennt
CHUTIL_FILE = Path("/home/fmg/prepper-dashboard/mesh1_chutil.json")
  # /* chutilBridge */

_send_q: queue.Queue = queue.Queue(maxsize=50)
_lock = threading.Lock()
_iface = None
_my_ids = set()
_inbox = deque(maxlen=INBOX_MAX)
_state = {
    "ok": False, "host": HOST, "connected": False, "last_error": "",
    "last_send": None, "last_text": "", "queued": 0,
    "sent_ok": 0, "sent_fail": 0, "last_rx": None, "hold_until": None,
}

# ----- funkHarden2: Doppelsendeschutz, Eingabepruefung, leises HTTP-Log (Konstanten, Zustand) -----
FH2_DUP_SEC = 120      # gleiche Nachricht + Kanal innerhalb 120 s nur einmal
FH2_TEXT_MAX = 220
_fh2 = {"recent": OrderedDict(), "dup": 0, "unsure": 0, "pre_fail": 0, "bad": 0,
        "http_quiet": 0, "replies": 0}
_fh2_ctrl = re.compile("[\x00-\x08\x0b-\x1f\x7f]")

# ----- mesh1Fresh: lastHeard/Node-DB aus der laufenden Sitzung (nur lesen, sendet nichts) -----
_m1f = {"rx": 0.0, "n": 0, "t0": time.time(), "last": OrderedDict()}
M1F_KEEP = 60


def now_str(fmt="%d.%m.%Y %H:%M:%S"):
    return datetime.now().strftime(fmt)


def log(*a):
    print(f"[{now_str()}]", *a, flush=True)


def load_inbox():
    try:
        data = json.loads(INBOX_FILE.read_text())
        if isinstance(data, list):
            for m in data[-INBOX_MAX:]:
                if isinstance(m, dict):
                    _inbox.append(m)
            log("Inbox geladen", len(_inbox))
    except Exception:
        pass


def save_inbox():
    try:
        INBOX_FILE.write_text(json.dumps(list(_inbox), ensure_ascii=False))
    except Exception as e:
        log("Inbox speichern:", e)


KNOWN_NAMES = {
    "!0c18a994": "Station Kalchreuth",
    "!c18a994": "Station Kalchreuth",
    "202942868": "Station Kalchreuth",
}

def node_name(nid):
    if not nid:
        return "?"
    key = str(nid).lower()
    if not key.startswith("!") and key.isdigit():
        try:
            key = f"!{int(key):08x}"
        except Exception:
            pass
    for k, v in KNOWN_NAMES.items():
        if k.lower() == key or k.lower().lstrip("!") == key.lstrip("!"):
            return v
    try:
        nodes = getattr(_iface, "nodes", None) or {}
        for n in nodes.values():
            user = n.get("user") if isinstance(n, dict) else None
            if not user:
                continue
            uid = str(user.get("id") or "").lower()
            longn = user.get("longName") or user.get("shortName")
            if longn and uid and (uid == key or uid.lstrip("!") == key.lstrip("!")):
                return longn
    except Exception:
        pass
    return str(nid)

def add_inbox(text, from_id, snr=None, rssi=None, hops=None, self_pkt=False, channel=0):
    item = {
        "at": now_str(),
        "from": from_id,
        "name": node_name(from_id),
        "text": (text or "")[:220],
        "snr": snr, "rssi": rssi, "hops": hops,
        "self": bool(self_pkt),
        "channel": int(channel or 0),
    }
    _inbox.append(item)
    save_inbox()
    items = load_channel_inbox(item["channel"])
    items.append(item)
    save_channel_inbox(item["channel"], items)
    return item


def is_held():
    t = _state.get("hold_until")
    if not t:
        return False
    if time.time() >= float(t):
        _state["hold_until"] = None
        log("Hold abgelaufen – Auto-Reconnect erlaubt")
        return False
    return True

def hold_bridge():
    _state["hold_until"] = time.time() + HOLD_MAX
    close_iface()
    _state["connected"] = False
    _state["ok"] = False
    _state["last_error"] = "manuell getrennt"
    log("HOLD 3h – TCP frei für anderes Gerät")
    return True

def resume_bridge():
    _state["hold_until"] = None
    _state["last_error"] = ""
    log("RESUME")
    try:
        connect()
        return True
    except Exception as e:
        _state["last_error"] = str(e)[:160]
        log("RESUME Fehler:", e)
        return False


def _ch_file(ch):
    INBOX_DIR.mkdir(parents=True, exist_ok=True)
    return INBOX_DIR / f"ch_{int(ch)}.json"

def load_channel_inbox(ch):
    try:
        data = json.loads(_ch_file(ch).read_text())
        return data if isinstance(data, list) else []
    except Exception:
        return []

def save_channel_inbox(ch, items):
    try:
        _ch_file(ch).write_text(json.dumps(items[-INBOX_MAX:], ensure_ascii=False))
    except Exception as e:
        log("inbox save ch", ch, e)

def list_station_channels():
    out = [{"index": 0, "name": "Primary"}]
    try:
        ln = getattr(_iface, "localNode", None)
        channels = getattr(ln, "channels", None) if ln is not None else None
        if not channels:
            return out
        found = []
        for i, ch in enumerate(channels):
            settings = getattr(ch, "settings", None) or ch
            name = (getattr(settings, "name", None) or "").strip()
            role = str(getattr(ch, "role", "") or "")
            if i == 0 and not name:
                name = "Primary"
            if not name and i > 0:
                continue
            found.append({"index": i, "name": name or f"Kanal {i}", "role": role})
        if found:
            return found
    except Exception as e:
        log("channels:", e)
    return out

def packet_channel(packet):
    try:
        if packet.get("channel") is not None:
            return int(packet.get("channel"))
        dec = packet.get("decoded") or {}
        if dec.get("channel") is not None:
            return int(dec.get("channel"))
    except Exception:
        pass
    return 0

def close_iface():
    global _iface
    if _iface is None:
        return
    try:
        _iface.close()
    except Exception:
        pass
    _iface = None
    _state["connected"] = False


def _collect_my_ids(iface):
    ids = set()
    try:
        info = getattr(iface, "myInfo", None)
        if info is not None:
            mid = getattr(info, "my_node_num", None) or getattr(info, "myNodeNum", None)
            if mid is not None:
                ids.add(int(mid))
                ids.add(f"!{int(mid):x}")
                ids.add(f"!{int(mid):08x}")
    except Exception:
        pass
    return {str(x).lower() for x in ids if x is not None}


def connect():
    global _iface, _my_ids
    close_iface()
    from meshtastic.tcp_interface import TCPInterface
    from pubsub import pub
    log("Verbinde", HOST)
    iface = TCPInterface(hostname=HOST)
    time.sleep(1.2)
    try:
        pub.unsubscribe(on_receive, "meshtastic.receive")
    except Exception:
        pass
    pub.subscribe(on_receive, "meshtastic.receive")
    _iface = iface
    _my_ids = _collect_my_ids(iface)
    _state["connected"] = True
    _state["ok"] = True
    _state["last_error"] = ""
    log("verbunden ids", _my_ids)
    return iface


def ensure_iface():
    if is_held():
        raise RuntimeError("Bridge manuell getrennt")
    with _lock:
        if _iface is not None:
            return _iface
        return connect()


def send_now(text: str, channel: int = 0) -> bool:
    msg = (text or "")[:220]
    if not msg.strip():
        return False
    try:
        iface = ensure_iface()
        iface.sendText(msg, channelIndex=int(channel or 0))
        try:
            mesh_reply_watch.note_tx("m1")  # meshHangBridge
        except Exception:
            pass
        time.sleep(0.4)
        _state["last_send"] = now_str()
        _state["last_text"] = msg.replace("\n", " | ")[:80]
        _state["sent_ok"] += 1
        _state["ok"] = True
        log("OK:", msg.replace("\n", " | ")[:140])
        try:
            add_inbox(msg, "!0c18a994", self_pkt=True, channel=int(channel or 0))
        except Exception as e:
            log("inbox send:", e)
        return True
    except Exception as e:
        _state["ok"] = False
        _state["sent_fail"] += 1
        _state["last_error"] = str(e)[:160]
        log("FEHLER:", e)
        close_iface()
        return False


def _hops(packet):
    try:
        hs, hl = packet.get("hopStart"), packet.get("hopLimit")
        if hs is not None and hl is not None:
            return max(0, int(hs) - int(hl))
    except Exception:
        pass
    return packet.get("hops") or 0


def _from_id(packet):
    fid = packet.get("fromId") or packet.get("from")
    if fid is None:
        return "?"
    if isinstance(fid, int):
        return f"!{fid:08x}"
    s = str(fid)
    if not s.startswith("!"):
        try:
            return f"!{int(s):08x}"
        except Exception:
            return s
    return s


def _is_self(packet):
    fid = str(packet.get("fromId") or packet.get("from") or "").lower()
    if not fid:
        return False
    others = {x.lstrip("!") for x in _my_ids}
    return fid in _my_ids or fid.lstrip("!") in others


def on_receive(packet, interface=None):
    # mesh1Fresh: Empfang von anderen Knoten merken (vor der Basislogik)
    try:
        if isinstance(packet, dict) and (interface is None or interface is _iface) and not _is_self(packet):
            now = time.time()
            _m1f["rx"] = now
            _m1f["n"] += 1
            dec = packet.get("decoded") or {}
            port = str(dec.get("portnum") or ("verschluesselt" if packet.get("encrypted") else "?"))
            fid = _from_id(packet)
            last = _m1f["last"]
            prev = last.pop(fid, None) or {}
            last[fid] = {"ts": now, "port": port, "snr": packet.get("rxSnr"), "rssi": packet.get("rxRssi"),
                         "hops": _hops(packet), "n": int(prev.get("n") or 0) + 1}
            while len(last) > M1F_KEEP:
                last.popitem(last=False)
            _state["rx_other_n"] = _m1f["n"]
            _state["rx_other_at"] = datetime.fromtimestamp(now).strftime("%d.%m.%Y %H:%M:%S")
            _state["rx_other_from"] = fid
            _state["rx_other_port"] = port
    except Exception:
        pass
    # Basis: Inbox fuehren, Ping/Test beantworten
    try:
        if not packet:
            return
        decoded = packet.get("decoded") or {}
        text = (decoded.get("text") or "").strip()
        port = str(decoded.get("portnum") or "")
        if not text and "TEXT" not in port.upper():
            # kein Klartext – trotzdem kein Pong
            pass
        self_pkt = _is_self(packet)
        if text:
            fid = _from_id(packet)
            item = add_inbox(
                text, fid,
                snr=packet.get("rxSnr"),
                rssi=packet.get("rxRssi"),
                hops=_hops(packet),
                self_pkt=self_pkt,
            )
            _state["last_rx"] = f"{item['at']} {item['from']} {text[:40]}"
        if self_pkt or not text:
            return
        if text.lower() not in TRIGGERS:
            return
        t = datetime.now().strftime("%H:%M:%S")
        snr, rssi = packet.get("rxSnr"), packet.get("rxRssi")
        reply = (
            f"{STATION}\nEmpfang {t}\nAntwort {t}\n"
            f"SNR {snr if snr is not None else '–'} dB · RSSI {rssi if rssi is not None else '–'} dBm\n"
            f"Hops {_hops(packet)} · von {mesh_node_label.label_from_iface(_iface, _from_id(packet))}"  # /* pingName */
        )
        log("Pong-Trigger:", text, "von", mesh_node_label.label_from_iface(_iface, _from_id(packet)))  # /* pingName */
        try:
            mesh_reply_watch.note_rx("m1")  # meshHangBridge
        except Exception:
            pass
        try:
            _send_q.put_nowait(reply)
            _state["queued"] = _send_q.qsize()
        except queue.Full:
            log("Queue voll")
    except Exception as e:
        log("on_receive:", e)


def _fh2_mesh_key():
    return "m1"


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
    return "%d:%s" % (ch, hashlib.sha1(text.encode("utf-8", "replace")).hexdigest())


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
    ensure_iface()


def worker():  # funkHarden2: genau ein Schreibversuch je Nachricht, Doppelsendeschutz
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


def watchdog():
    while True:
        time.sleep(60)
        try:
            if is_held():
                left = int(float(_state.get("hold_until") or 0) - time.time())
                log("Watchdog: Hold noch", left, "s")
                continue
            if _iface is None or not _state.get("connected"):
                log("Watchdog: reconnect")
                try:
                    with _lock:  # funkHarden: nie parallel zu ensure_iface()
                        connect()
                except Exception as e:
                    _state["ok"] = False
                    _state["last_error"] = str(e)[:160]
                    log("Watchdog:", e)
        except Exception as e:
            log("Watchdog:", e)



class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # funkHarden2: Routine-Abfragen nicht loggen
        try:
            req = str(args[0]) if args else ""
            code = int(args[1]) if len(args) > 1 and str(args[1]).isdigit() else 0
            if code and code < 400 and not any(p in req for p in (" /send", " /hold", " /resume")):
                _fh2["http_quiet"] += 1
                return
        except Exception:
            pass
        log("HTTP", fmt % args)

    def _json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith("/health"):
            held = is_held()
            left = 0
            if held:
                left = max(0, int(float(_state.get("hold_until") or 0) - time.time()))
            self._json(200, dict(_state, inbox=len(_inbox), held=held, hold_left=left))
            return
        if self.path.startswith("/channels"):
            self._json(200, {"channels": list_station_channels()})
            return
        if self.path.startswith("/inbox"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            ch = qs.get("channel", qs.get("ch", [None]))[0]
            if ch is not None:
                try:
                    chn = int(ch)
                    self._json(200, {"channel": chn, "messages": load_channel_inbox(chn)[-200:]})
                    return
                except Exception:
                    pass
            self._json(200, {"messages": list(_inbox)[-200:]})
            return
        if self.path.startswith("/chutil"):  # mesh1Fresh: /chutil um zuletzt gehoerte Knoten ergaenzen (nur lesen)
            try:
                with _lock:
                    iface = _iface
                    ids = set(_my_ids)
                live = mesh_chutil.pick_local_metrics(iface, ids) if iface else None
                hist = mesh_chutil.hist_payload(CHUTIL_FILE, hours=24)
                rx = _m1f["rx"]
                self._json(200, {"ok": True, "live": live, "hist": hist,
                                 "rx_other_n": _m1f["n"], "rx_other_age_s": (int(time.time() - rx) if rx else None),
                                 "since_start_s": int(time.time() - _m1f["t0"]),
                                 "heard": _m1f_heard(), "nodes_lastheard": _m1f_nodes_lastheard(iface) if iface else []})
            except Exception as e:
                self._json(500, {"ok": False, "error": str(e)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):  # meshSendHarden # meshSendStable # funkHarden2: /send pruefen (Kanal 0-7, Text 1-220, keine Steuerzeichen)
        if self.path.startswith("/hold"):
            hold_bridge()
            self._json(200, dict(_state, held=True))
            return
        if self.path.startswith("/resume"):
            ok = resume_bridge()
            self._json(200, dict(_state, held=is_held(), resume_ok=ok))
            return
        if not self.path.startswith("/send"):
            self._json(404, {"error": "not found"})
            return
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


def chutil_worker():  # /* chutilBridge */
    """DeviceMetrics periodisch in CHUTIL_FILE schreiben (keine 2. TCP-Session)."""
    while True:
        time.sleep(60)
        try:
            with _lock:
                iface = _iface
                ids = set(_my_ids)
            if not iface:
                continue
            r = mesh_chutil.sample_and_store(iface, CHUTIL_FILE, my_ids=ids, min_gap=300)
            if r.get("ok") and r.get("wrote"):
                cur = r.get("current") or {}
                log("chutil", cur.get("ch_util"), "% air", cur.get("air_tx"), cur.get("node"))
        except Exception as e:
            log("chutil:", e)


def main():
    load_inbox()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=watchdog, daemon=True).start()
    threading.Thread(target=chutil_worker, daemon=True).start()  # /* chutilBridge */
    try:
        connect()
    except Exception as e:
        log("Start-Connect:", e)
    httpd = ThreadingHTTPServer(LISTEN, Handler)
    log("Bridge auf http://127.0.0.1:5001")
    httpd.serve_forever()


def _m1f_label(fid):
    try:
        return mesh_node_label.label_from_iface(_iface, fid)
    except Exception:
        return fid


def _m1f_heard(limit=10):
    now = time.time()
    items = sorted(_m1f["last"].items(), key=lambda kv: kv[1]["ts"], reverse=True)[:limit]
    return [{"node": k, "name": _m1f_label(k), "age_s": int(now - v["ts"]), "port": v["port"],
             "snr": v["snr"], "rssi": v["rssi"], "hops": v["hops"], "n": v["n"]} for k, v in items]


def _m1f_nodes_lastheard(iface, limit=8):
    out = []
    try:
        now = time.time()
        for nid, info in (getattr(iface, "nodes", None) or {}).items():
            if not isinstance(info, dict):
                continue
            lh = info.get("lastHeard")
            try:
                lh = float(lh)
            except Exception:
                continue
            if lh > 1e12:
                lh = lh / 1000.0
            if lh > 1e8:
                out.append((lh, nid))
        out.sort(reverse=True)
        return [{"node": n, "name": _m1f_label(n), "age_s": max(0, int(now - t))} for t, n in out[:limit]]
    except Exception:
        return []


def _m1f_pick(iface, my_ids=None):  # mesh1Fresh
    r = _m1f_orig_pick(iface, my_ids)
    if not r or iface is None:
        return r
    try:
        n = len(getattr(iface, "nodes", None) or {})
        if n:
            r["nodedb_myinfo"] = r.get("nodedb")
            r["nodedb"] = n
    except Exception:
        pass
    try:
        if iface is _iface and _m1f["rx"] > 0:
            r["heard_sec"] = max(0, int(time.time() - _m1f["rx"]))
            r["heard_src"] = "bridge-rx"
    except Exception:
        pass
    r["m1fresh"] = 1
    r["rx_other_n"] = _m1f["n"]
    return r


# ===== Schichten, die beim Start aktiv werden (Reihenfolge wie bisher: funkHarden, funkHarden2, mesh1Fresh) =====
def _fh_on_lost(interface=None):  # funkHarden: tote Sitzung -> Watchdog verbindet neu (max 60 s)
    try:
        if interface is not None and interface is _iface and not is_held():
            _state["connected"] = False
            _state["last_error"] = "Verbindung verloren"
            log("funkHarden m1: Verbindung verloren - Watchdog verbindet neu (max 60 s)")
    except Exception:
        pass


def _fh_hook():
    try:
        from pubsub import pub as _fh_pub
        _fh_pub.subscribe(_fh_on_lost, "meshtastic.connection.lost")
        log("funkHarden m1 aktiv: Verlust-Erkennung, Watchdog-Reconnect unter Sperre")
    except Exception as e:
        log("funkHarden m1 lost-hook:", e)


_fh_hook()


log("funkHarden2 aktiv (%s): Doppelsendeschutz %d s, kein Retry nach Schreibfehler, /send geprueft, HTTP-Log leise" % (
    _fh2_mesh_key(), FH2_DUP_SEC))

_m1f_orig_pick = mesh_chutil.pick_local_metrics
mesh_chutil.pick_local_metrics = _m1f_pick
log("mesh1Fresh aktiv: lastHeard = letztes Paket eines anderen Knotens, Node-DB live aus Sitzung")


if __name__ == "__main__":
    main()
BA_EMBED_2_EOF
EXPECT_3="1ce381878372527f6bd88d5c95426f68aeb13317209cfe08933b7f5d58d12e8a"
mkdir -p "$W/new"
cat > "$W/new/mesh_bridge_bayern.py" << 'BA_EMBED_3_EOF'
#!/usr/bin/env python3
"""G2-Bridge (Mesh 2): eine TCP-Session, Queue, Pong, Inbox.

bridgeDedup (MOD-02): jede Funktion genau einmal definiert. Die frueheren Schichten mesh2OneSession, mesh2Calm, funkHarden und
funkHarden2 (Umhuellungen am Dateiende) sind in die jeweils wirksame Funktion eingearbeitet, das Verhalten ist unveraendert.

bridgePrio (PERF-05): Sende-Queue mit Prioritaeten (Alarm vor Routine, siehe _SendQueue); Sendeabstand SEND_GAP, Doppelsendeschutz und alle
anderen Regeln unveraendert."""
from __future__ import annotations

import hashlib
import heapq
import json
import logging
import os
import queue
import re
import sys
import threading
import time
import traceback
from collections import OrderedDict, deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import mesh_chutil  # /* chutilBridge */
import mesh_node_label  # /* pingName */
import mesh_reply_watch  # meshHangBridge

sys.path.insert(0, "/home/fmg/prepper-dashboard")
try:
    MESHTASTIC_HOST = "192.168.178.140"
except Exception:
    MESHTASTIC_HOST = "192.168.178.140"

HOST = MESHTASTIC_HOST
LISTEN = ("127.0.0.1", 5002)
SEND_GAP = 3.0
RECONNECT_WAIT = 5.0
STATION = "Station Kalchreuth"  # pingStationKalch
TRIGGERS = {"ping","pong","test","!ping","!test","wetter","pegel","odl","freq","frequenz","status","help","hilfe","nina","gas","nina test"}
INBOX_FILE = Path("/home/fmg/prepper-dashboard/mesh_inbox_bayern.json")
INBOX_DIR = Path("/home/fmg/prepper-dashboard/mesh_inbox_bayern")
INBOX_MAX = 300
HOLD_MAX = 3 * 3600  # 3 Stunden manuell getrennt
CHUTIL_FILE = Path("/home/fmg/prepper-dashboard/mesh2_chutil.json")  # /* chutilBridge */

# ----- bridgePrio (PERF-05): Prioritaetswarteschlange - Alarm vor Routine, kurze Obergrenze fuer Routine-Nachrichten -----
PRIO_ALARM = 0        # echte Alarme: Text beginnt mit "ALARM " / "ALARM:" / "NINA: " (oder "prio": 0 im POST-Koerper)
PRIO_DETAIL = 1       # NINA-Details ("NINA Details: ...") kommen nach der Kurzmeldung
PRIO_ROUTINE = 5      # alles andere (Pong, Wetter, Pegel, Knoepfe ...)
PRIO_TEST = 9         # Probe/Test: nur Reihenfolge (Probe-/Testalarme gehen nie ins Mesh - das stellt der Router sicher)
ROUTINE_MAX = 10      # hoechstens so viele Nachrichten mit Prioritaet >= 5 gleichzeitig in der Warteschlange
_ALARM_PREFIX = ("ALARM ", "ALARM:", "NINA: ")
_pq = {"alarm": 0, "overtake": 0, "routine_full": 0, "displaced": 0}


def _prio_of(item):
    """Prioritaet eines Eintrags (str oder dict): "prio" 0-9 im dict gewinnt, sonst nach Textanfang."""
    text = item
    if isinstance(item, dict):
        p = item.get("prio")
        if isinstance(p, int) and not isinstance(p, bool) and 0 <= p <= 9:
            return p
        text = item.get("text")
    t = str(text or "").lstrip()
    if t.startswith(_ALARM_PREFIX):
        return PRIO_ALARM
    if t.startswith("NINA Details"):
        return PRIO_DETAIL
    if t[:4].upper() == "TEST" and "keine echte Warnung" in t:
        return PRIO_TEST
    return PRIO_ROUTINE


class _SendQueue(queue.Queue):
    """Sende-Queue als Heap nach (Prioritaet, Eingangsfolge): niedrigere Zahl zuerst, je Prioritaet FIFO. maxsize wie bisher (50 gesamt),
    zusaetzlich hoechstens ROUTINE_MAX Routine-Eintraege (neue Routine -> queue.Full). Ist die Queue voll, verdraengt ein wichtigerer Eintrag
    den juengsten der niedrigsten Prioritaet (statt abgelehnt zu werden). put ist nie blockierend (die Bridge ruft nur put_nowait)."""

    def _init(self, maxsize):
        self.queue = []
        self._seq = 0
        self._nroutine = 0

    def _qsize(self):
        return len(self.queue)

    def _put(self, entry):
        heapq.heappush(self.queue, entry)
        if entry[0] >= PRIO_ROUTINE:
            self._nroutine += 1

    def _get(self):
        entry = heapq.heappop(self.queue)
        if entry[0] >= PRIO_ROUTINE:
            self._nroutine -= 1
        return entry[2]

    def counts(self):
        with self.mutex:
            return sum(1 for e in self.queue if e[0] < PRIO_ROUTINE), self._nroutine

    def put(self, item, block=True, timeout=None):
        prio = _prio_of(item)
        with self.not_full:
            if prio >= PRIO_ROUTINE and self._nroutine >= ROUTINE_MAX:
                _pq["routine_full"] += 1
                raise queue.Full
            if self.maxsize > 0 and self._qsize() >= self.maxsize:
                worst = max(self.queue)
                if worst[0] <= prio:
                    raise queue.Full
                self.queue.remove(worst)
                heapq.heapify(self.queue)
                if worst[0] >= PRIO_ROUTINE:
                    self._nroutine -= 1
                self.unfinished_tasks -= 1
                _pq["displaced"] += 1
            overtaken = sum(1 for e in self.queue if e[0] > prio) if prio == PRIO_ALARM else 0
            self._seq += 1
            self._put((prio, self._seq, item))
            self.unfinished_tasks += 1
            self.not_empty.notify()
        if prio == PRIO_ALARM:
            _pq["alarm"] += 1
            if overtaken:
                _pq["overtake"] += 1
                log("bridgePrio: Alarm ueberholt %d wartende Nachricht(en)" % overtaken)


# ----- mesh2Calm: Sende-Queue, in der Ruhezeit werden automatische Antworten (aus on_receive) verworfen -----
class _M2cQueue(_SendQueue):
    """Sende-Queue: automatische Antworten (aus on_receive) in der Ruhezeit verwerfen."""

    def put_nowait(self, item):
        pkt = getattr(_m2c_tls, "rx", None)
        if pkt is not None:
            why = _m2c_quiet_reason(pkt)
            if why:
                _m2c["quiet_drop"] += 1
                log("mesh2Calm: automatische Antwort NICHT gesendet (%s)" % why)
                return None
        return super().put_nowait(item)


_send_q: queue.Queue = _M2cQueue(maxsize=50)
_lock = threading.Lock()
_iface = None
_my_ids = set()
_inbox = deque(maxlen=INBOX_MAX)
_state = {
    "ok": False, "host": HOST, "connected": False, "last_error": "",
    "last_send": None, "last_text": "", "queued": 0,
    "sent_ok": 0, "sent_fail": 0, "last_rx": None, "hold_until": None,
}


# ----- mesh2OneSession: eine TCP-Session zu Mesh2, Status-JSON, Reconnect vor Senden (Konstanten, Zustand) -----
M2OS_STATUS_FILE = Path("/home/fmg/prepper-dashboard/mesh2_session.json")  # mesh2OneSession
M2OS_STALE_RECONNECT = 20 * 60   # so lange kein Paket -> sauber neu verbinden
M2OS_PRESEND_STALE = 10 * 60     # vor dem Senden: Verbindung aelter + stumm -> erst neu verbinden
M2OS_KEEPER_EVERY = 10
M2OS_ADD_PONG = False  # True nur wenn die Bridge selbst keine Ping-Antwort hatte
M2OS_PONG_COOLDOWN = 20
_m2os_conn_lock = threading.RLock()
_m2os = {
    "last_pkt": 0.0, "connected_at": 0.0, "events": deque(maxlen=600),
    "last_err": "", "last_err_at": None, "hooked": False, "dirty": True,
    "last_write": 0.0, "pong_last": {}, "closing": 0, "closed_ids": deque(maxlen=20),
    "reason": "", "started_at": 0.0,
}

# ----- mesh2Calm: Keepalive, ein Reconnect-Besitzer, Episoden, Ruhezeit (Konstanten, Zustand) -----
M2C_KA_EVERY = 60        # Keepalive-Heartbeat (Lib sendet nur alle 300 s)
M2C_EP_GAP = 90          # Ereignisse innerhalb 90 s = EINE Abbruch-Episode
M2C_BOOT_QUIET = 300     # nach Bridge-Start 5 min keine automatische Antwort
M2C_BACKLOG_WIN = 60     # so lange nach (Re)Connect liefert das Geraet Rueckstau
M2C_BACKLOG_AGE = 120    # Ping aelter als 2 min im Rueckstau -> nie beantworten
_M2C_DISRUPT = ("lost", "libreconnect", "connect_fail", "send_fail", "reconnect")
_m2c = {
    "t0": time.time(), "eps": deque(maxlen=300), "ep": None, "ep_open": False,
    "ka_on": True, "ka_sent": 0, "ka_fail": 0, "ka_last": 0.0, "short": 0,
    "down_since": None, "quiet_drop": 0, "halfopen": 0, "n": 0,
}
_m2c_tls = threading.local()

# ----- funkHarden m2: Node-DB/lastHeard aus der laufenden Sitzung -----
_m2f = {"rx": 0.0, "n": 0}

# ----- funkHarden2: Doppelsendeschutz, Eingabepruefung, leises HTTP-Log -----
FH2_DUP_SEC = 120      # gleiche Nachricht + Kanal innerhalb 120 s nur einmal
FH2_TEXT_MAX = 220
_fh2 = {"recent": OrderedDict(), "dup": 0, "unsure": 0, "pre_fail": 0, "bad": 0,
        "http_quiet": 0, "replies": 0}
_fh2_ctrl = re.compile("[\x00-\x08\x0b-\x1f\x7f]")


def now_str(fmt="%d.%m.%Y %H:%M:%S"):
    return datetime.now().strftime(fmt)


def log(*a):
    print(f"[{now_str()}]", *a, flush=True)


def load_inbox():
    try:
        data = json.loads(INBOX_FILE.read_text())
        if isinstance(data, list):
            for m in data[-INBOX_MAX:]:
                if isinstance(m, dict):
                    _inbox.append(m)
            log("Inbox geladen", len(_inbox))
    except Exception:
        pass


def save_inbox():
    try:
        INBOX_FILE.write_text(json.dumps(list(_inbox), ensure_ascii=False))
    except Exception as e:
        log("Inbox speichern:", e)


KNOWN_NAMES = {
    "!0c18a994": "Station Kalchreuth",
    "!c18a994": "Station Kalchreuth",
    "202942868": "Station Kalchreuth",
}

def node_name(nid):
    if not nid:
        return "?"
    key = str(nid).lower()
    if not key.startswith("!") and key.isdigit():
        try:
            key = f"!{int(key):08x}"
        except Exception:
            pass
    for k, v in KNOWN_NAMES.items():
        if k.lower() == key or k.lower().lstrip("!") == key.lstrip("!"):
            return v
    try:
        nodes = getattr(_iface, "nodes", None) or {}
        for n in nodes.values():
            user = n.get("user") if isinstance(n, dict) else None
            if not user:
                continue
            uid = str(user.get("id") or "").lower()
            longn = user.get("longName") or user.get("shortName")
            if longn and uid and (uid == key or uid.lstrip("!") == key.lstrip("!")):
                return longn
    except Exception:
        pass
    return str(nid)

def add_inbox(text, from_id, snr=None, rssi=None, hops=None, self_pkt=False, channel=0):
    item = {
        "at": now_str(),
        "from": from_id,
        "name": node_name(from_id),
        "text": (text or "")[:220],
        "snr": snr, "rssi": rssi, "hops": hops,
        "self": bool(self_pkt),
        "channel": int(channel or 0),
    }
    _inbox.append(item)
    save_inbox()
    items = load_channel_inbox(item["channel"])
    items.append(item)
    save_channel_inbox(item["channel"], items)
    return item


def is_held():
    t = _state.get("hold_until")
    if not t:
        return False
    if time.time() >= float(t):
        _state["hold_until"] = None
        log("Hold abgelaufen – Auto-Reconnect erlaubt")
        return False
    return True

def hold_bridge():
    _state["hold_until"] = time.time() + HOLD_MAX
    close_iface()
    _state["connected"] = False
    _state["ok"] = False
    _state["last_error"] = "manuell getrennt"
    log("HOLD 3h – TCP frei für anderes Gerät")
    return True

def resume_bridge():
    _state["hold_until"] = None
    _state["last_error"] = ""
    log("RESUME")
    try:
        connect()
        return True
    except Exception as e:
        _state["last_error"] = str(e)[:160]
        log("RESUME Fehler:", e)
        return False


def _ch_file(ch):
    INBOX_DIR.mkdir(parents=True, exist_ok=True)
    return INBOX_DIR / f"ch_{int(ch)}.json"

def load_channel_inbox(ch):
    try:
        data = json.loads(_ch_file(ch).read_text())
        return data if isinstance(data, list) else []
    except Exception:
        return []

def save_channel_inbox(ch, items):
    try:
        _ch_file(ch).write_text(json.dumps(items[-INBOX_MAX:], ensure_ascii=False))
    except Exception as e:
        log("inbox save ch", ch, e)

def list_station_channels():
    out = [{"index": 0, "name": "Primary"}]
    try:
        ln = getattr(_iface, "localNode", None)
        channels = getattr(ln, "channels", None) if ln is not None else None
        if not channels:
            return out
        found = []
        for i, ch in enumerate(channels):
            settings = getattr(ch, "settings", None) or ch
            name = (getattr(settings, "name", None) or "").strip()
            role = str(getattr(ch, "role", "") or "")
            if i == 0 and not name:
                name = "Primary"
            if not name and i > 0:
                continue
            found.append({"index": i, "name": name or f"Kanal {i}", "role": role})
        if found:
            return found
    except Exception as e:
        log("channels:", e)
    return out

def packet_channel(packet):
    try:
        if packet.get("channel") is not None:
            return int(packet.get("channel"))
        dec = packet.get("decoded") or {}
        if dec.get("channel") is not None:
            return int(dec.get("channel"))
    except Exception:
        pass
    return 0

def close_iface():
    global _iface
    _m2os["closing"] += 1   # mesh2OneSession: eigenes Schliessen nicht als Abbruch zaehlen
    try:
        if _iface is not None:
            _m2os["closed_ids"].append(id(_iface))
        if _iface is None:
            return
        try:
            _iface.close()
        except Exception:
            pass
        _iface = None
        _state["connected"] = False
    finally:
        _m2os["closing"] -= 1


def _collect_my_ids(iface):
    ids = set()
    try:
        info = getattr(iface, "myInfo", None)
        if info is not None:
            mid = getattr(info, "my_node_num", None) or getattr(info, "myNodeNum", None)
            if mid is not None:
                ids.add(int(mid))
                ids.add(f"!{int(mid):x}")
                ids.add(f"!{int(mid):08x}")
    except Exception:
        pass
    return {str(x).lower() for x in ids if x is not None}


def _connect_tcp():  # Basis: TCP-Verbindung aufbauen
    global _iface, _my_ids
    close_iface()
    from meshtastic.tcp_interface import TCPInterface
    from pubsub import pub
    log("Verbinde", HOST)
    iface = TCPInterface(hostname=HOST)
    time.sleep(1.2)
    try:
        pub.unsubscribe(on_receive, "meshtastic.receive")
    except Exception:
        pass
    pub.subscribe(on_receive, "meshtastic.receive")
    _iface = iface
    _my_ids = _collect_my_ids(iface)
    _state["connected"] = True
    _state["ok"] = True
    _state["last_error"] = ""
    log("verbunden ids", _my_ids)
    return iface


def connect():  # mesh2OneSession: serialisiert, nie zwei Sessions gleichzeitig
    with _m2os_conn_lock:
        if (not _m2os_dead()
                and time.time() - _m2os["connected_at"] < 5):
            return _iface  # paralleler Reconnect hat gerade verbunden
        first = not _m2os["connected_at"]
        try:
            iface = _connect_tcp()
        except Exception as e:
            _m2os_event("connect_fail", e)
            raise
        _m2os["connected_at"] = time.time()
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


def ensure_iface():
    if is_held():
        raise RuntimeError("Bridge manuell getrennt")
    with _lock:
        if _iface is not None:
            return _iface
        return connect()


def _send_text(text: str, channel: int = 0) -> bool:  # Basis: genau ein Schreibversuch
    msg = (text or "")[:220]
    if not msg.strip():
        return False
    try:
        iface = ensure_iface()
        iface.sendText(msg, channelIndex=int(channel or 0))
        try:
            mesh_reply_watch.note_tx("m2")  # meshHangBridge
        except Exception:
            pass
        time.sleep(0.4)
        _state["last_send"] = now_str()
        _state["last_text"] = msg.replace("\n", " | ")[:80]
        _state["sent_ok"] += 1
        _state["ok"] = True
        log("OK:", msg.replace("\n", " | ")[:140])
        try:
            add_inbox(msg, "!0c18a994", self_pkt=True, channel=int(channel or 0))
        except Exception as e:
            log("inbox send:", e)
        return True
    except Exception as e:
        _state["ok"] = False
        _state["sent_fail"] += 1
        _state["last_error"] = str(e)[:160]
        log("FEHLER:", e)
        close_iface()
        return False


def send_now(text: str, channel: int = 0) -> bool:  # mesh2OneSession: erst pruefen, dann genau ein Sendeversuch
    try:
        _m2os_presend()
    except Exception as e:
        log("mesh2OneSession presend:", e)
    ok = _send_text(text, channel)
    if not ok:
        _m2os_event("send_fail", _state.get("last_error") or "Senden fehlgeschlagen")
    _m2os["dirty"] = True
    return ok


def _hops(packet):
    try:
        hs, hl = packet.get("hopStart"), packet.get("hopLimit")
        if hs is not None and hl is not None:
            return max(0, int(hs) - int(hl))
    except Exception:
        pass
    return packet.get("hops") or 0


def _from_id(packet):
    fid = packet.get("fromId") or packet.get("from")
    if fid is None:
        return "?"
    if isinstance(fid, int):
        return f"!{fid:08x}"
    s = str(fid)
    if not s.startswith("!"):
        try:
            return f"!{int(s):08x}"
        except Exception:
            return s
    return s


def _is_self(packet):
    fid = str(packet.get("fromId") or packet.get("from") or "").lower()
    if not fid:
        return False
    others = {x.lstrip("!") for x in _my_ids}
    return fid in _my_ids or fid.lstrip("!") in others


def on_receive(packet, interface=None):
    # funkHarden m2: Empfang von anderen Knoten merken
    try:
        if isinstance(packet, dict) and (interface is None or interface is _iface) and not _is_self(packet):
            _m2f["rx"] = time.time()
            _m2f["n"] += 1
    except Exception:
        pass
    # mesh2Calm: Antworten aus diesem Paket ggf. unterdruecken (siehe _M2cQueue)
    _m2c_tls.rx = packet if isinstance(packet, dict) else {}
    try:
        # mesh2OneSession: jedes Paket = Lebenszeichen
        try:
            if interface is None or interface is _iface:
                _m2os["last_pkt"] = time.time()
        except Exception:
            pass
        if M2OS_ADD_PONG and packet:
            _m2os_pong(packet)
        # Basis: Inbox fuehren, Ping/Test beantworten
        try:
                if not packet:
                    return
                decoded = packet.get("decoded") or {}
                text = (decoded.get("text") or "").strip()
                port = str(decoded.get("portnum") or "")
                if not text and "TEXT" not in port.upper():
                    # kein Klartext – trotzdem kein Pong
                    pass
                self_pkt = _is_self(packet)
                if text:
                    fid = _from_id(packet)
                    ch = packet_channel(packet)
                    name_guess = (node_name(fid) or "") + " " + text
                    if ch == 0 and ("knoten.eu" in name_guess.lower() or "mesh hessen" in name_guess.lower()):
                        ch = 3
                    item = add_inbox(
                        text, fid,
                        snr=packet.get("rxSnr"),
                        rssi=packet.get("rxRssi"),
                        hops=_hops(packet),
                        self_pkt=self_pkt,
                        channel=ch,
                    )
                    _state["last_rx"] = f"{item['at']} {item['from']} {text[:40]}"
                if self_pkt or not text:
                    return
                if packet_channel(packet) != 0:
                    return
                if text.lower() not in TRIGGERS:
                    return
                t = datetime.now().strftime("%H:%M:%S")
                snr, rssi = packet.get("rxSnr"), packet.get("rxRssi")
                reply = (
                    f"{STATION}\nEmpfang {t}\nAntwort {t}\n"
                    f"SNR {snr if snr is not None else '–'} dB · RSSI {rssi if rssi is not None else '–'} dBm\n"
                    f"Hops {_hops(packet)} · von {mesh_node_label.label_from_iface(_iface, _from_id(packet))}"  # /* pingName */
                )
                log("Pong-Trigger:", text, "von", mesh_node_label.label_from_iface(_iface, _from_id(packet)))  # /* pingName */
                try:
                    mesh_reply_watch.note_rx("m2")  # meshHangBridge
                except Exception:
                    pass
                try:
                    _send_q.put_nowait({"text": reply, "channel": 0})
                    _state["queued"] = _send_q.qsize()
                except queue.Full:
                    log("Queue voll")
        except Exception as e:
            log("on_receive:", e)
    finally:
        _m2c_tls.rx = None


def _m2os_pong(packet):
    try:
        decoded = packet.get("decoded") or {}
        text = (decoded.get("text") or "").strip().lower()
        if text not in ("ping", "test"):
            return
        if _is_self(packet):
            return
        ch = packet_channel(packet)
        if ch != 0:
            return
        fid = _from_id(packet)
        now = time.time()
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
        hops = _hops(packet)
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


def _m2os_event(kind, err=None):
    try:
        _m2os["events"].append((time.time(), kind))
        if err:
            _m2os["last_err"] = str(err)[:160]
            _m2os["last_err_at"] = now_str()
        _m2os["dirty"] = True
    except Exception:
        pass
    try:  # mesh2Calm: zusaetzlich zu Episoden zusammenfassen
        _m2c_episode(kind, err)
    except Exception as e:
        log("mesh2Calm episode:", e)


def _m2os_counts(window=3600):
    cut = time.time() - window
    c = {}
    for ts, k in list(_m2os["events"]):
        if ts >= cut:
            c[k] = c.get(k, 0) + 1
    return c


class _M2osLogHook(logging.Handler):
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
        h.setLevel(logging.WARNING)
        logging.getLogger("meshtastic").addHandler(h)
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


def _m2os_presend():
    if is_held():
        return
    now = time.time()
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


def _m2os_write(force=False):  # mesh2OneSession: Status-Datei; mesh2Calm: um Episoden ergaenzt
    before = _m2os.get("last_write")
    now = time.time()
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
        "pid": os.getpid(), "host": HOST,
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
    tmp.write_text(json.dumps(d, ensure_ascii=False))
    os.replace(str(tmp), str(M2OS_STATUS_FILE))
    _m2os["dirty"] = False
    _m2os["last_write"] = now
    if _m2os.get("last_write") == before:
        return
    try:
        d = json.loads(M2OS_STATUS_FILE.read_text() or "{}")
        d.update(_m2c_status(d))
        tmp = M2OS_STATUS_FILE.with_name(M2OS_STATUS_FILE.name + ".tmp")
        tmp.write_text(json.dumps(d, ensure_ascii=False))
        os.replace(str(tmp), str(M2OS_STATUS_FILE))
    except Exception as e:
        log("mesh2Calm status:", e)


def _m2os_keeper():
    backoff = 10
    next_try = 0.0
    first = True
    while True:
        time.sleep(3 if first else M2OS_KEEPER_EVERY)
        first = False
        try:
            now = time.time()
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


def _m2c_fmt(ts):
    try:
        return datetime.fromtimestamp(float(ts)).strftime("%H:%M:%S")
    except Exception:
        return "?"


def _m2c_episode(kind, err=None):
    if kind not in _M2C_DISRUPT:
        return
    now = time.time()
    ep = _m2c["ep"]
    same = ep is not None and (_m2c["ep_open"] or now - ep["last"] <= M2C_EP_GAP)
    if same:
        ep["kinds"][kind] = ep["kinds"].get(kind, 0) + 1
        ep["last"] = now
        if err and not ep.get("err"):
            ep["err"] = str(err)[:120]
        if kind == "reconnect":
            _m2c["ep_open"] = False
            ep["back"] = now
            log("mesh2Calm: wieder verbunden nach %d s (Episode %d)" % (int(now - ep["start"]), ep["no"]))
        else:
            _m2c["ep_open"] = True
        return
    ca = _m2os.get("connected_at") or 0
    lp = _m2os.get("last_pkt") or 0
    ka = _m2c.get("ka_last") or 0
    _m2c["n"] += 1
    ep = {
        "no": _m2c["n"], "start": now, "last": now, "kinds": {kind: 1}, "cause": kind,
        "err": str(err)[:120] if err else "",
        "sess": int(now - ca) if ca else None,
        "pkt": int(now - max(lp, ca)) if (lp or ca) else None,
        "ka": int(now - ka) if ka else None,
        "back": None,
    }
    _m2c["eps"].append(ep)
    _m2c["ep"] = ep
    _m2c["ep_open"] = kind != "reconnect"
    log("mesh2Calm: Abbruch-Episode %d: %s nach %s s Sitzung, letztes Paket vor %s s, Keepalive vor %s s%s" % (
        ep["no"], kind, ep["sess"], ep["pkt"], ep["ka"], (" - " + ep["err"]) if ep["err"] else ""))
    # Schutz: stirbt die Verbindung wiederholt direkt nach UNSEREM Keepalive, obwohl
    # bis eben Pakete kamen -> Keepalive abschalten (zurueck auf Lib-Standard 300 s).
    if (_m2c["ka_on"] and ep["sess"] is not None and ep["sess"] < M2C_KA_EVERY * 2 + 20
            and ep["pkt"] is not None and ep["pkt"] < 20 and ep["ka"] is not None and ep["ka"] < 8):
        _m2c["short"] += 1
        if _m2c["short"] >= 3:
            _m2c["ka_on"] = False
            log("mesh2Calm: Keepalive AUS - Verbindung fiel 3x direkt nach dem Keepalive (Lib-Standard 300 s bleibt)")
    else:
        _m2c["short"] = 0


def _m2c_status(d):
    now = time.time()
    cut = now - 3600
    eps = [e for e in list(_m2c["eps"]) if e["start"] >= cut]
    kinds = {}
    for e in eps:
        for k, v in e["kinds"].items():
            kinds[k] = kinds.get(k, 0) + v
    sess = [e["sess"] for e in eps if e.get("sess") is not None]
    conn = bool(d.get("connected"))
    if conn:
        _m2c["down_since"] = None
    elif _m2c["down_since"] is None:
        ep = _m2c["ep"]
        _m2c["down_since"] = ep["start"] if (ep is not None and _m2c["ep_open"]) else now
    quiet_left = int(max(0, M2C_BOOT_QUIET - (now - _m2c["t0"])))
    return {
        "calm": 1,
        "episodes_1h": len(eps),
        "ep_kinds_1h": kinds,
        "sess_avg_1h": int(sum(sess) / len(sess)) if sess else None,
        "episodes": [
            {"at": _m2c_fmt(e["start"]), "cause": e["cause"], "kinds": e["kinds"], "sess": e["sess"],
             "pkt": e["pkt"], "ka": e["ka"], "down": int((e["back"] or now) - e["start"]),
             "open": e["back"] is None, "err": e["err"][:80]}
            for e in eps[-6:]
        ],
        "down_since": _m2c["down_since"],
        "down_for": int(now - _m2c["down_since"]) if _m2c["down_since"] else 0,
        "keepalive": {"on": _m2c["ka_on"], "every": M2C_KA_EVERY, "sent": _m2c["ka_sent"],
                      "fail": _m2c["ka_fail"], "last": _m2c_fmt(_m2c["ka_last"]) if _m2c["ka_last"] else None},
        "quiet_left": quiet_left, "auto_reply_dropped": _m2c["quiet_drop"], "halfopen_closed": _m2c["halfopen"],
    }


def watchdog():  # mesh2Calm: alter 60-s-Watchdog verbindet NICHT mehr neu (das macht nur der Keeper)
    log("mesh2Calm: alter Watchdog ohne Reconnect - Keeper ist einziger Reconnect-Besitzer")
    while True:
        time.sleep(3600)


def _m2c_keepalive():
    while True:
        time.sleep(M2C_KA_EVERY)
        try:
            if not _m2c["ka_on"] or is_held():
                continue
            iface = _iface
            if iface is None or _m2os_dead():
                continue
            if not _m2os_conn_lock.acquire(blocking=False):
                continue  # Reconnect laeuft gerade
            _m2os_conn_lock.release()
            iface.sendHeartbeat()
            _m2c["ka_sent"] += 1
            _m2c["ka_last"] = time.time()
        except Exception as e:
            _m2c["ka_fail"] += 1
            log("mesh2Calm Keepalive:", e)


def _m2c_install_tcp_guard():
    """Schlaegt der Verbindungsaufbau fehl (z.B. Timed out waiting for connection
    completion), die halboffene Verbindung sofort schliessen - sonst bleibt ein
    zweiter Client im eigenen Prozess haengen."""
    try:
        import meshtastic.tcp_interface as _m2c_ti
        base = _m2c_ti.TCPInterface
        if getattr(base, "_m2c", False):
            return

        class _M2cTCPInterface(base):
            _m2c = True

            def __init__(self, *a, **kw):
                try:
                    super().__init__(*a, **kw)
                except Exception as e:
                    try:
                        self._wantExit = True
                        self.close()
                    except Exception:
                        pass
                    _m2c["halfopen"] += 1
                    log("mesh2Calm: halboffene Verbindung geschlossen nach:", str(e)[:100])
                    raise

        _m2c_ti.TCPInterface = _M2cTCPInterface
    except Exception as e:
        log("mesh2Calm tcp-guard:", e)


def _m2c_quiet_reason(pkt):
    now = time.time()
    left = M2C_BOOT_QUIET - (now - _m2c["t0"])
    if left > 0:
        return "Ruhezeit nach Bridge-Start, noch %d s" % int(left)
    try:
        ca = _m2os.get("connected_at") or 0
        rt = float((pkt or {}).get("rxTime") or 0)
        if ca and now - ca < M2C_BACKLOG_WIN and rt > 0 and M2C_BACKLOG_AGE < now - rt < 6 * 3600:
            return "Rueckstau nach Reconnect, Ping von vor %d s" % int(now - rt)
    except Exception:
        pass
    return None


def _m2f_pick(iface, my_ids=None):  # funkHarden
    r = _m2f_orig_pick(iface, my_ids)
    if not r or iface is None:
        return r
    try:
        n = len(getattr(iface, "nodes", None) or {})
        cur = r.get("nodedb")
        if n and (cur is None or n > int(cur)):
            r["nodedb"] = n
    except Exception:
        pass
    try:
        if iface is _iface and _m2f["rx"] > 0:
            r["heard_sec"] = max(0, int(time.time() - _m2f["rx"]))
            r["heard_src"] = "bridge-rx"
    except Exception:
        pass
    r["m2fresh"] = 1
    r["rx_other_n"] = _m2f["n"]
    return r


def _fh2_mesh_key():
    return "m2"


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
    return "%d:%s" % (ch, hashlib.sha1(text.encode("utf-8", "replace")).hexdigest())


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
    try:
        _m2os_presend()
    except Exception as e:
        log("funkHarden2 presend:", e)
    ensure_iface()


def worker():  # funkHarden2: genau ein Schreibversuch je Nachricht
    last = 0.0
    while True:
        try:
            # bridgePrio: Sendeabstand VOR dem Entnehmen, damit ein inzwischen eingetroffener Alarm als Naechster rausgeht (Abstand unveraendert SEND_GAP)
            wait = SEND_GAP - (time.time() - last)
            if wait > 0:
                time.sleep(wait)
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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # funkHarden2: Routine-Abfragen nicht loggen
        try:
            req = str(args[0]) if args else ""
            code = int(args[1]) if len(args) > 1 and str(args[1]).isdigit() else 0
            if code and code < 400 and not any(p in req for p in (" /send", " /hold", " /resume")):
                _fh2["http_quiet"] += 1
                return
        except Exception:
            pass
        log("HTTP", fmt % args)

    def _json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith("/health"):
            held = is_held()
            left = 0
            if held:
                left = max(0, int(float(_state.get("hold_until") or 0) - time.time()))
            q_hi, q_lo = _send_q.counts()
            self._json(200, dict(_state, inbox=len(_inbox), held=held, hold_left=left, q_alarm=q_hi, q_routine=q_lo, prio=dict(_pq)))
            return
        if self.path.startswith("/channels"):
            self._json(200, {"channels": list_station_channels()})
            return
        if self.path.startswith("/inbox"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            ch = qs.get("channel", qs.get("ch", [None]))[0]
            if ch is not None:
                try:
                    chn = int(ch)
                    self._json(200, {"channel": chn, "messages": load_channel_inbox(chn)[-200:]})
                    return
                except Exception:
                    pass
            self._json(200, {"messages": list(_inbox)[-200:]})
            return
        if self.path.startswith("/chutil"):  # /* chutilBridge */
            try:
                with _lock:
                    iface = _iface
                    ids = set(_my_ids)
                live = mesh_chutil.pick_local_metrics(iface, ids) if iface else None
                hist = mesh_chutil.hist_payload(CHUTIL_FILE, hours=24)
                self._json(200, {"ok": True, "live": live, "hist": hist})
            except Exception as e:
                self._json(500, {"ok": False, "error": str(e)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):  # meshSendHarden # meshSendStable # funkHarden2: /send pruefen (Kanal 0-7, Text 1-220, keine Steuerzeichen)
        if self.path.startswith("/hold"):
            hold_bridge()
            self._json(200, dict(_state, held=True))
            return
        if self.path.startswith("/resume"):
            ok = resume_bridge()
            self._json(200, dict(_state, held=is_held(), resume_ok=ok))
            return
        if not self.path.startswith("/send"):
            self._json(404, {"error": "not found"})
            return
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
        prio = data.get("prio")
        if prio is not None and (isinstance(prio, bool) or not isinstance(prio, int) or not 0 <= prio <= 9):
            _fh2["bad"] += 1
            self._json(400, {"ok": False, "error": "prio ungueltig (0-9)"})
            return
        item = {"text": text, "channel": ch}
        if prio is not None:
            item["prio"] = prio
        try:
            _send_q.put_nowait(item)
            _state["queued"] = _send_q.qsize()
            self._json(200, {"ok": True, "queued": _state["queued"]})
        except queue.Full:
            self._json(429, {"ok": False, "error": "queue full"})


def chutil_worker():  # /* chutilBridge */
    """DeviceMetrics periodisch in CHUTIL_FILE schreiben (keine 2. TCP-Session)."""
    while True:
        time.sleep(60)
        try:
            with _lock:
                iface = _iface
                ids = set(_my_ids)
            if not iface:
                continue
            r = mesh_chutil.sample_and_store(iface, CHUTIL_FILE, my_ids=ids, min_gap=300)
            if r.get("ok") and r.get("wrote"):
                cur = r.get("current") or {}
                log("chutil", cur.get("ch_util"), "% air", cur.get("air_tx"), cur.get("node"))
        except Exception as e:
            log("chutil:", e)


def main():
    # mesh2Calm: TCP-Wache, Keepalive-Faden
    _m2c_install_tcp_guard()
    threading.Thread(target=_m2c_keepalive, daemon=True, name="m2calm-keepalive").start()
    log("mesh2Calm aktiv: Keepalive alle %d s, Reconnect nur Keeper, Episoden %d s, Ruhezeit %d s" % (
        M2C_KA_EVERY, M2C_EP_GAP, M2C_BOOT_QUIET))
    # mesh2OneSession: Keeper-Faden
    threading.Thread(target=_m2os_keeper, daemon=True, name="m2os-keeper").start()
    log("mesh2OneSession aktiv: eine TCP-Session, Keeper alle", M2OS_KEEPER_EVERY, "s")
    # Basis
    load_inbox()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=watchdog, daemon=True).start()
    threading.Thread(target=chutil_worker, daemon=True).start()  # /* chutilBridge */
    try:
        connect()
    except Exception as e:
        log("Start-Connect:", e)
    httpd = ThreadingHTTPServer(LISTEN, Handler)
    log("Bridge auf http://127.0.0.1:5002")
    httpd.serve_forever()


# ===== Schichten, die beim Start aktiv werden (Reihenfolge wie bisher: funkHarden m2, funkHarden2) =====
_m2f_orig_pick = mesh_chutil.pick_local_metrics
mesh_chutil.pick_local_metrics = _m2f_pick
log("funkHarden m2 aktiv: lastHeard = letztes Paket eines anderen Knotens, Node-DB aus Sitzung")

log("funkHarden2 aktiv (%s): Doppelsendeschutz %d s, kein Retry nach Schreibfehler, /send geprueft, HTTP-Log leise" % (
    _fh2_mesh_key(), FH2_DUP_SEC))


if __name__ == "__main__":
    main()
BA_EMBED_3_EOF
EXPECT_4="fe2bf6f7de4ad59afe6eeacaca35f9f0f0128300f8e5890d36643d2375103195"
mkdir -p "$W/base"
cat > "$W/base/mesh_bridge_bayern.py" << 'BA_EMBED_4_EOF'
#!/usr/bin/env python3
"""G2-Bridge (Mesh 2): eine TCP-Session, Queue, Pong, Inbox.

bridgeDedup (MOD-02): jede Funktion genau einmal definiert. Die frueheren Schichten mesh2OneSession, mesh2Calm, funkHarden und
funkHarden2 (Umhuellungen am Dateiende) sind in die jeweils wirksame Funktion eingearbeitet, das Verhalten ist unveraendert."""
from __future__ import annotations

import hashlib
import json
import logging
import os
import queue
import re
import sys
import threading
import time
import traceback
from collections import OrderedDict, deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import mesh_chutil  # /* chutilBridge */
import mesh_node_label  # /* pingName */
import mesh_reply_watch  # meshHangBridge

sys.path.insert(0, "/home/fmg/prepper-dashboard")
try:
    MESHTASTIC_HOST = "192.168.178.140"
except Exception:
    MESHTASTIC_HOST = "192.168.178.140"

HOST = MESHTASTIC_HOST
LISTEN = ("127.0.0.1", 5002)
SEND_GAP = 3.0
RECONNECT_WAIT = 5.0
STATION = "Station Kalchreuth"  # pingStationKalch
TRIGGERS = {"ping","pong","test","!ping","!test","wetter","pegel","odl","freq","frequenz","status","help","hilfe","nina","gas","nina test"}
INBOX_FILE = Path("/home/fmg/prepper-dashboard/mesh_inbox_bayern.json")
INBOX_DIR = Path("/home/fmg/prepper-dashboard/mesh_inbox_bayern")
INBOX_MAX = 300
HOLD_MAX = 3 * 3600  # 3 Stunden manuell getrennt
CHUTIL_FILE = Path("/home/fmg/prepper-dashboard/mesh2_chutil.json")  # /* chutilBridge */

# ----- mesh2Calm: Sende-Queue, in der Ruhezeit werden automatische Antworten (aus on_receive) verworfen -----
class _M2cQueue(queue.Queue):
    """Sende-Queue: automatische Antworten (aus on_receive) in der Ruhezeit verwerfen."""

    def put_nowait(self, item):
        pkt = getattr(_m2c_tls, "rx", None)
        if pkt is not None:
            why = _m2c_quiet_reason(pkt)
            if why:
                _m2c["quiet_drop"] += 1
                log("mesh2Calm: automatische Antwort NICHT gesendet (%s)" % why)
                return None
        return super().put_nowait(item)


_send_q: queue.Queue = _M2cQueue(maxsize=50)
_lock = threading.Lock()
_iface = None
_my_ids = set()
_inbox = deque(maxlen=INBOX_MAX)
_state = {
    "ok": False, "host": HOST, "connected": False, "last_error": "",
    "last_send": None, "last_text": "", "queued": 0,
    "sent_ok": 0, "sent_fail": 0, "last_rx": None, "hold_until": None,
}


# ----- mesh2OneSession: eine TCP-Session zu Mesh2, Status-JSON, Reconnect vor Senden (Konstanten, Zustand) -----
M2OS_STATUS_FILE = Path("/home/fmg/prepper-dashboard/mesh2_session.json")  # mesh2OneSession
M2OS_STALE_RECONNECT = 20 * 60   # so lange kein Paket -> sauber neu verbinden
M2OS_PRESEND_STALE = 10 * 60     # vor dem Senden: Verbindung aelter + stumm -> erst neu verbinden
M2OS_KEEPER_EVERY = 10
M2OS_ADD_PONG = False  # True nur wenn die Bridge selbst keine Ping-Antwort hatte
M2OS_PONG_COOLDOWN = 20
_m2os_conn_lock = threading.RLock()
_m2os = {
    "last_pkt": 0.0, "connected_at": 0.0, "events": deque(maxlen=600),
    "last_err": "", "last_err_at": None, "hooked": False, "dirty": True,
    "last_write": 0.0, "pong_last": {}, "closing": 0, "closed_ids": deque(maxlen=20),
    "reason": "", "started_at": 0.0,
}

# ----- mesh2Calm: Keepalive, ein Reconnect-Besitzer, Episoden, Ruhezeit (Konstanten, Zustand) -----
M2C_KA_EVERY = 60        # Keepalive-Heartbeat (Lib sendet nur alle 300 s)
M2C_EP_GAP = 90          # Ereignisse innerhalb 90 s = EINE Abbruch-Episode
M2C_BOOT_QUIET = 300     # nach Bridge-Start 5 min keine automatische Antwort
M2C_BACKLOG_WIN = 60     # so lange nach (Re)Connect liefert das Geraet Rueckstau
M2C_BACKLOG_AGE = 120    # Ping aelter als 2 min im Rueckstau -> nie beantworten
_M2C_DISRUPT = ("lost", "libreconnect", "connect_fail", "send_fail", "reconnect")
_m2c = {
    "t0": time.time(), "eps": deque(maxlen=300), "ep": None, "ep_open": False,
    "ka_on": True, "ka_sent": 0, "ka_fail": 0, "ka_last": 0.0, "short": 0,
    "down_since": None, "quiet_drop": 0, "halfopen": 0, "n": 0,
}
_m2c_tls = threading.local()

# ----- funkHarden m2: Node-DB/lastHeard aus der laufenden Sitzung -----
_m2f = {"rx": 0.0, "n": 0}

# ----- funkHarden2: Doppelsendeschutz, Eingabepruefung, leises HTTP-Log -----
FH2_DUP_SEC = 120      # gleiche Nachricht + Kanal innerhalb 120 s nur einmal
FH2_TEXT_MAX = 220
_fh2 = {"recent": OrderedDict(), "dup": 0, "unsure": 0, "pre_fail": 0, "bad": 0,
        "http_quiet": 0, "replies": 0}
_fh2_ctrl = re.compile("[\x00-\x08\x0b-\x1f\x7f]")


def now_str(fmt="%d.%m.%Y %H:%M:%S"):
    return datetime.now().strftime(fmt)


def log(*a):
    print(f"[{now_str()}]", *a, flush=True)


def load_inbox():
    try:
        data = json.loads(INBOX_FILE.read_text())
        if isinstance(data, list):
            for m in data[-INBOX_MAX:]:
                if isinstance(m, dict):
                    _inbox.append(m)
            log("Inbox geladen", len(_inbox))
    except Exception:
        pass


def save_inbox():
    try:
        INBOX_FILE.write_text(json.dumps(list(_inbox), ensure_ascii=False))
    except Exception as e:
        log("Inbox speichern:", e)


KNOWN_NAMES = {
    "!0c18a994": "Station Kalchreuth",
    "!c18a994": "Station Kalchreuth",
    "202942868": "Station Kalchreuth",
}

def node_name(nid):
    if not nid:
        return "?"
    key = str(nid).lower()
    if not key.startswith("!") and key.isdigit():
        try:
            key = f"!{int(key):08x}"
        except Exception:
            pass
    for k, v in KNOWN_NAMES.items():
        if k.lower() == key or k.lower().lstrip("!") == key.lstrip("!"):
            return v
    try:
        nodes = getattr(_iface, "nodes", None) or {}
        for n in nodes.values():
            user = n.get("user") if isinstance(n, dict) else None
            if not user:
                continue
            uid = str(user.get("id") or "").lower()
            longn = user.get("longName") or user.get("shortName")
            if longn and uid and (uid == key or uid.lstrip("!") == key.lstrip("!")):
                return longn
    except Exception:
        pass
    return str(nid)

def add_inbox(text, from_id, snr=None, rssi=None, hops=None, self_pkt=False, channel=0):
    item = {
        "at": now_str(),
        "from": from_id,
        "name": node_name(from_id),
        "text": (text or "")[:220],
        "snr": snr, "rssi": rssi, "hops": hops,
        "self": bool(self_pkt),
        "channel": int(channel or 0),
    }
    _inbox.append(item)
    save_inbox()
    items = load_channel_inbox(item["channel"])
    items.append(item)
    save_channel_inbox(item["channel"], items)
    return item


def is_held():
    t = _state.get("hold_until")
    if not t:
        return False
    if time.time() >= float(t):
        _state["hold_until"] = None
        log("Hold abgelaufen – Auto-Reconnect erlaubt")
        return False
    return True

def hold_bridge():
    _state["hold_until"] = time.time() + HOLD_MAX
    close_iface()
    _state["connected"] = False
    _state["ok"] = False
    _state["last_error"] = "manuell getrennt"
    log("HOLD 3h – TCP frei für anderes Gerät")
    return True

def resume_bridge():
    _state["hold_until"] = None
    _state["last_error"] = ""
    log("RESUME")
    try:
        connect()
        return True
    except Exception as e:
        _state["last_error"] = str(e)[:160]
        log("RESUME Fehler:", e)
        return False


def _ch_file(ch):
    INBOX_DIR.mkdir(parents=True, exist_ok=True)
    return INBOX_DIR / f"ch_{int(ch)}.json"

def load_channel_inbox(ch):
    try:
        data = json.loads(_ch_file(ch).read_text())
        return data if isinstance(data, list) else []
    except Exception:
        return []

def save_channel_inbox(ch, items):
    try:
        _ch_file(ch).write_text(json.dumps(items[-INBOX_MAX:], ensure_ascii=False))
    except Exception as e:
        log("inbox save ch", ch, e)

def list_station_channels():
    out = [{"index": 0, "name": "Primary"}]
    try:
        ln = getattr(_iface, "localNode", None)
        channels = getattr(ln, "channels", None) if ln is not None else None
        if not channels:
            return out
        found = []
        for i, ch in enumerate(channels):
            settings = getattr(ch, "settings", None) or ch
            name = (getattr(settings, "name", None) or "").strip()
            role = str(getattr(ch, "role", "") or "")
            if i == 0 and not name:
                name = "Primary"
            if not name and i > 0:
                continue
            found.append({"index": i, "name": name or f"Kanal {i}", "role": role})
        if found:
            return found
    except Exception as e:
        log("channels:", e)
    return out

def packet_channel(packet):
    try:
        if packet.get("channel") is not None:
            return int(packet.get("channel"))
        dec = packet.get("decoded") or {}
        if dec.get("channel") is not None:
            return int(dec.get("channel"))
    except Exception:
        pass
    return 0

def close_iface():
    global _iface
    _m2os["closing"] += 1   # mesh2OneSession: eigenes Schliessen nicht als Abbruch zaehlen
    try:
        if _iface is not None:
            _m2os["closed_ids"].append(id(_iface))
        if _iface is None:
            return
        try:
            _iface.close()
        except Exception:
            pass
        _iface = None
        _state["connected"] = False
    finally:
        _m2os["closing"] -= 1


def _collect_my_ids(iface):
    ids = set()
    try:
        info = getattr(iface, "myInfo", None)
        if info is not None:
            mid = getattr(info, "my_node_num", None) or getattr(info, "myNodeNum", None)
            if mid is not None:
                ids.add(int(mid))
                ids.add(f"!{int(mid):x}")
                ids.add(f"!{int(mid):08x}")
    except Exception:
        pass
    return {str(x).lower() for x in ids if x is not None}


def _connect_tcp():  # Basis: TCP-Verbindung aufbauen
    global _iface, _my_ids
    close_iface()
    from meshtastic.tcp_interface import TCPInterface
    from pubsub import pub
    log("Verbinde", HOST)
    iface = TCPInterface(hostname=HOST)
    time.sleep(1.2)
    try:
        pub.unsubscribe(on_receive, "meshtastic.receive")
    except Exception:
        pass
    pub.subscribe(on_receive, "meshtastic.receive")
    _iface = iface
    _my_ids = _collect_my_ids(iface)
    _state["connected"] = True
    _state["ok"] = True
    _state["last_error"] = ""
    log("verbunden ids", _my_ids)
    return iface


def connect():  # mesh2OneSession: serialisiert, nie zwei Sessions gleichzeitig
    with _m2os_conn_lock:
        if (not _m2os_dead()
                and time.time() - _m2os["connected_at"] < 5):
            return _iface  # paralleler Reconnect hat gerade verbunden
        first = not _m2os["connected_at"]
        try:
            iface = _connect_tcp()
        except Exception as e:
            _m2os_event("connect_fail", e)
            raise
        _m2os["connected_at"] = time.time()
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


def ensure_iface():
    if is_held():
        raise RuntimeError("Bridge manuell getrennt")
    with _lock:
        if _iface is not None:
            return _iface
        return connect()


def _send_text(text: str, channel: int = 0) -> bool:  # Basis: genau ein Schreibversuch
    msg = (text or "")[:220]
    if not msg.strip():
        return False
    try:
        iface = ensure_iface()
        iface.sendText(msg, channelIndex=int(channel or 0))
        try:
            mesh_reply_watch.note_tx("m2")  # meshHangBridge
        except Exception:
            pass
        time.sleep(0.4)
        _state["last_send"] = now_str()
        _state["last_text"] = msg.replace("\n", " | ")[:80]
        _state["sent_ok"] += 1
        _state["ok"] = True
        log("OK:", msg.replace("\n", " | ")[:140])
        try:
            add_inbox(msg, "!0c18a994", self_pkt=True, channel=int(channel or 0))
        except Exception as e:
            log("inbox send:", e)
        return True
    except Exception as e:
        _state["ok"] = False
        _state["sent_fail"] += 1
        _state["last_error"] = str(e)[:160]
        log("FEHLER:", e)
        close_iface()
        return False


def send_now(text: str, channel: int = 0) -> bool:  # mesh2OneSession: erst pruefen, dann genau ein Sendeversuch
    try:
        _m2os_presend()
    except Exception as e:
        log("mesh2OneSession presend:", e)
    ok = _send_text(text, channel)
    if not ok:
        _m2os_event("send_fail", _state.get("last_error") or "Senden fehlgeschlagen")
    _m2os["dirty"] = True
    return ok


def _hops(packet):
    try:
        hs, hl = packet.get("hopStart"), packet.get("hopLimit")
        if hs is not None and hl is not None:
            return max(0, int(hs) - int(hl))
    except Exception:
        pass
    return packet.get("hops") or 0


def _from_id(packet):
    fid = packet.get("fromId") or packet.get("from")
    if fid is None:
        return "?"
    if isinstance(fid, int):
        return f"!{fid:08x}"
    s = str(fid)
    if not s.startswith("!"):
        try:
            return f"!{int(s):08x}"
        except Exception:
            return s
    return s


def _is_self(packet):
    fid = str(packet.get("fromId") or packet.get("from") or "").lower()
    if not fid:
        return False
    others = {x.lstrip("!") for x in _my_ids}
    return fid in _my_ids or fid.lstrip("!") in others


def on_receive(packet, interface=None):
    # funkHarden m2: Empfang von anderen Knoten merken
    try:
        if isinstance(packet, dict) and (interface is None or interface is _iface) and not _is_self(packet):
            _m2f["rx"] = time.time()
            _m2f["n"] += 1
    except Exception:
        pass
    # mesh2Calm: Antworten aus diesem Paket ggf. unterdruecken (siehe _M2cQueue)
    _m2c_tls.rx = packet if isinstance(packet, dict) else {}
    try:
        # mesh2OneSession: jedes Paket = Lebenszeichen
        try:
            if interface is None or interface is _iface:
                _m2os["last_pkt"] = time.time()
        except Exception:
            pass
        if M2OS_ADD_PONG and packet:
            _m2os_pong(packet)
        # Basis: Inbox fuehren, Ping/Test beantworten
        try:
                if not packet:
                    return
                decoded = packet.get("decoded") or {}
                text = (decoded.get("text") or "").strip()
                port = str(decoded.get("portnum") or "")
                if not text and "TEXT" not in port.upper():
                    # kein Klartext – trotzdem kein Pong
                    pass
                self_pkt = _is_self(packet)
                if text:
                    fid = _from_id(packet)
                    ch = packet_channel(packet)
                    name_guess = (node_name(fid) or "") + " " + text
                    if ch == 0 and ("knoten.eu" in name_guess.lower() or "mesh hessen" in name_guess.lower()):
                        ch = 3
                    item = add_inbox(
                        text, fid,
                        snr=packet.get("rxSnr"),
                        rssi=packet.get("rxRssi"),
                        hops=_hops(packet),
                        self_pkt=self_pkt,
                        channel=ch,
                    )
                    _state["last_rx"] = f"{item['at']} {item['from']} {text[:40]}"
                if self_pkt or not text:
                    return
                if packet_channel(packet) != 0:
                    return
                if text.lower() not in TRIGGERS:
                    return
                t = datetime.now().strftime("%H:%M:%S")
                snr, rssi = packet.get("rxSnr"), packet.get("rxRssi")
                reply = (
                    f"{STATION}\nEmpfang {t}\nAntwort {t}\n"
                    f"SNR {snr if snr is not None else '–'} dB · RSSI {rssi if rssi is not None else '–'} dBm\n"
                    f"Hops {_hops(packet)} · von {mesh_node_label.label_from_iface(_iface, _from_id(packet))}"  # /* pingName */
                )
                log("Pong-Trigger:", text, "von", mesh_node_label.label_from_iface(_iface, _from_id(packet)))  # /* pingName */
                try:
                    mesh_reply_watch.note_rx("m2")  # meshHangBridge
                except Exception:
                    pass
                try:
                    _send_q.put_nowait({"text": reply, "channel": 0})
                    _state["queued"] = _send_q.qsize()
                except queue.Full:
                    log("Queue voll")
        except Exception as e:
            log("on_receive:", e)
    finally:
        _m2c_tls.rx = None


def _m2os_pong(packet):
    try:
        decoded = packet.get("decoded") or {}
        text = (decoded.get("text") or "").strip().lower()
        if text not in ("ping", "test"):
            return
        if _is_self(packet):
            return
        ch = packet_channel(packet)
        if ch != 0:
            return
        fid = _from_id(packet)
        now = time.time()
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
        hops = _hops(packet)
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


def _m2os_event(kind, err=None):
    try:
        _m2os["events"].append((time.time(), kind))
        if err:
            _m2os["last_err"] = str(err)[:160]
            _m2os["last_err_at"] = now_str()
        _m2os["dirty"] = True
    except Exception:
        pass
    try:  # mesh2Calm: zusaetzlich zu Episoden zusammenfassen
        _m2c_episode(kind, err)
    except Exception as e:
        log("mesh2Calm episode:", e)


def _m2os_counts(window=3600):
    cut = time.time() - window
    c = {}
    for ts, k in list(_m2os["events"]):
        if ts >= cut:
            c[k] = c.get(k, 0) + 1
    return c


class _M2osLogHook(logging.Handler):
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
        h.setLevel(logging.WARNING)
        logging.getLogger("meshtastic").addHandler(h)
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


def _m2os_presend():
    if is_held():
        return
    now = time.time()
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


def _m2os_write(force=False):  # mesh2OneSession: Status-Datei; mesh2Calm: um Episoden ergaenzt
    before = _m2os.get("last_write")
    now = time.time()
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
        "pid": os.getpid(), "host": HOST,
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
    tmp.write_text(json.dumps(d, ensure_ascii=False))
    os.replace(str(tmp), str(M2OS_STATUS_FILE))
    _m2os["dirty"] = False
    _m2os["last_write"] = now
    if _m2os.get("last_write") == before:
        return
    try:
        d = json.loads(M2OS_STATUS_FILE.read_text() or "{}")
        d.update(_m2c_status(d))
        tmp = M2OS_STATUS_FILE.with_name(M2OS_STATUS_FILE.name + ".tmp")
        tmp.write_text(json.dumps(d, ensure_ascii=False))
        os.replace(str(tmp), str(M2OS_STATUS_FILE))
    except Exception as e:
        log("mesh2Calm status:", e)


def _m2os_keeper():
    backoff = 10
    next_try = 0.0
    first = True
    while True:
        time.sleep(3 if first else M2OS_KEEPER_EVERY)
        first = False
        try:
            now = time.time()
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


def _m2c_fmt(ts):
    try:
        return datetime.fromtimestamp(float(ts)).strftime("%H:%M:%S")
    except Exception:
        return "?"


def _m2c_episode(kind, err=None):
    if kind not in _M2C_DISRUPT:
        return
    now = time.time()
    ep = _m2c["ep"]
    same = ep is not None and (_m2c["ep_open"] or now - ep["last"] <= M2C_EP_GAP)
    if same:
        ep["kinds"][kind] = ep["kinds"].get(kind, 0) + 1
        ep["last"] = now
        if err and not ep.get("err"):
            ep["err"] = str(err)[:120]
        if kind == "reconnect":
            _m2c["ep_open"] = False
            ep["back"] = now
            log("mesh2Calm: wieder verbunden nach %d s (Episode %d)" % (int(now - ep["start"]), ep["no"]))
        else:
            _m2c["ep_open"] = True
        return
    ca = _m2os.get("connected_at") or 0
    lp = _m2os.get("last_pkt") or 0
    ka = _m2c.get("ka_last") or 0
    _m2c["n"] += 1
    ep = {
        "no": _m2c["n"], "start": now, "last": now, "kinds": {kind: 1}, "cause": kind,
        "err": str(err)[:120] if err else "",
        "sess": int(now - ca) if ca else None,
        "pkt": int(now - max(lp, ca)) if (lp or ca) else None,
        "ka": int(now - ka) if ka else None,
        "back": None,
    }
    _m2c["eps"].append(ep)
    _m2c["ep"] = ep
    _m2c["ep_open"] = kind != "reconnect"
    log("mesh2Calm: Abbruch-Episode %d: %s nach %s s Sitzung, letztes Paket vor %s s, Keepalive vor %s s%s" % (
        ep["no"], kind, ep["sess"], ep["pkt"], ep["ka"], (" - " + ep["err"]) if ep["err"] else ""))
    # Schutz: stirbt die Verbindung wiederholt direkt nach UNSEREM Keepalive, obwohl
    # bis eben Pakete kamen -> Keepalive abschalten (zurueck auf Lib-Standard 300 s).
    if (_m2c["ka_on"] and ep["sess"] is not None and ep["sess"] < M2C_KA_EVERY * 2 + 20
            and ep["pkt"] is not None and ep["pkt"] < 20 and ep["ka"] is not None and ep["ka"] < 8):
        _m2c["short"] += 1
        if _m2c["short"] >= 3:
            _m2c["ka_on"] = False
            log("mesh2Calm: Keepalive AUS - Verbindung fiel 3x direkt nach dem Keepalive (Lib-Standard 300 s bleibt)")
    else:
        _m2c["short"] = 0


def _m2c_status(d):
    now = time.time()
    cut = now - 3600
    eps = [e for e in list(_m2c["eps"]) if e["start"] >= cut]
    kinds = {}
    for e in eps:
        for k, v in e["kinds"].items():
            kinds[k] = kinds.get(k, 0) + v
    sess = [e["sess"] for e in eps if e.get("sess") is not None]
    conn = bool(d.get("connected"))
    if conn:
        _m2c["down_since"] = None
    elif _m2c["down_since"] is None:
        ep = _m2c["ep"]
        _m2c["down_since"] = ep["start"] if (ep is not None and _m2c["ep_open"]) else now
    quiet_left = int(max(0, M2C_BOOT_QUIET - (now - _m2c["t0"])))
    return {
        "calm": 1,
        "episodes_1h": len(eps),
        "ep_kinds_1h": kinds,
        "sess_avg_1h": int(sum(sess) / len(sess)) if sess else None,
        "episodes": [
            {"at": _m2c_fmt(e["start"]), "cause": e["cause"], "kinds": e["kinds"], "sess": e["sess"],
             "pkt": e["pkt"], "ka": e["ka"], "down": int((e["back"] or now) - e["start"]),
             "open": e["back"] is None, "err": e["err"][:80]}
            for e in eps[-6:]
        ],
        "down_since": _m2c["down_since"],
        "down_for": int(now - _m2c["down_since"]) if _m2c["down_since"] else 0,
        "keepalive": {"on": _m2c["ka_on"], "every": M2C_KA_EVERY, "sent": _m2c["ka_sent"],
                      "fail": _m2c["ka_fail"], "last": _m2c_fmt(_m2c["ka_last"]) if _m2c["ka_last"] else None},
        "quiet_left": quiet_left, "auto_reply_dropped": _m2c["quiet_drop"], "halfopen_closed": _m2c["halfopen"],
    }


def watchdog():  # mesh2Calm: alter 60-s-Watchdog verbindet NICHT mehr neu (das macht nur der Keeper)
    log("mesh2Calm: alter Watchdog ohne Reconnect - Keeper ist einziger Reconnect-Besitzer")
    while True:
        time.sleep(3600)


def _m2c_keepalive():
    while True:
        time.sleep(M2C_KA_EVERY)
        try:
            if not _m2c["ka_on"] or is_held():
                continue
            iface = _iface
            if iface is None or _m2os_dead():
                continue
            if not _m2os_conn_lock.acquire(blocking=False):
                continue  # Reconnect laeuft gerade
            _m2os_conn_lock.release()
            iface.sendHeartbeat()
            _m2c["ka_sent"] += 1
            _m2c["ka_last"] = time.time()
        except Exception as e:
            _m2c["ka_fail"] += 1
            log("mesh2Calm Keepalive:", e)


def _m2c_install_tcp_guard():
    """Schlaegt der Verbindungsaufbau fehl (z.B. Timed out waiting for connection
    completion), die halboffene Verbindung sofort schliessen - sonst bleibt ein
    zweiter Client im eigenen Prozess haengen."""
    try:
        import meshtastic.tcp_interface as _m2c_ti
        base = _m2c_ti.TCPInterface
        if getattr(base, "_m2c", False):
            return

        class _M2cTCPInterface(base):
            _m2c = True

            def __init__(self, *a, **kw):
                try:
                    super().__init__(*a, **kw)
                except Exception as e:
                    try:
                        self._wantExit = True
                        self.close()
                    except Exception:
                        pass
                    _m2c["halfopen"] += 1
                    log("mesh2Calm: halboffene Verbindung geschlossen nach:", str(e)[:100])
                    raise

        _m2c_ti.TCPInterface = _M2cTCPInterface
    except Exception as e:
        log("mesh2Calm tcp-guard:", e)


def _m2c_quiet_reason(pkt):
    now = time.time()
    left = M2C_BOOT_QUIET - (now - _m2c["t0"])
    if left > 0:
        return "Ruhezeit nach Bridge-Start, noch %d s" % int(left)
    try:
        ca = _m2os.get("connected_at") or 0
        rt = float((pkt or {}).get("rxTime") or 0)
        if ca and now - ca < M2C_BACKLOG_WIN and rt > 0 and M2C_BACKLOG_AGE < now - rt < 6 * 3600:
            return "Rueckstau nach Reconnect, Ping von vor %d s" % int(now - rt)
    except Exception:
        pass
    return None


def _m2f_pick(iface, my_ids=None):  # funkHarden
    r = _m2f_orig_pick(iface, my_ids)
    if not r or iface is None:
        return r
    try:
        n = len(getattr(iface, "nodes", None) or {})
        cur = r.get("nodedb")
        if n and (cur is None or n > int(cur)):
            r["nodedb"] = n
    except Exception:
        pass
    try:
        if iface is _iface and _m2f["rx"] > 0:
            r["heard_sec"] = max(0, int(time.time() - _m2f["rx"]))
            r["heard_src"] = "bridge-rx"
    except Exception:
        pass
    r["m2fresh"] = 1
    r["rx_other_n"] = _m2f["n"]
    return r


def _fh2_mesh_key():
    return "m2"


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
    return "%d:%s" % (ch, hashlib.sha1(text.encode("utf-8", "replace")).hexdigest())


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


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # funkHarden2: Routine-Abfragen nicht loggen
        try:
            req = str(args[0]) if args else ""
            code = int(args[1]) if len(args) > 1 and str(args[1]).isdigit() else 0
            if code and code < 400 and not any(p in req for p in (" /send", " /hold", " /resume")):
                _fh2["http_quiet"] += 1
                return
        except Exception:
            pass
        log("HTTP", fmt % args)

    def _json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith("/health"):
            held = is_held()
            left = 0
            if held:
                left = max(0, int(float(_state.get("hold_until") or 0) - time.time()))
            self._json(200, dict(_state, inbox=len(_inbox), held=held, hold_left=left))
            return
        if self.path.startswith("/channels"):
            self._json(200, {"channels": list_station_channels()})
            return
        if self.path.startswith("/inbox"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            ch = qs.get("channel", qs.get("ch", [None]))[0]
            if ch is not None:
                try:
                    chn = int(ch)
                    self._json(200, {"channel": chn, "messages": load_channel_inbox(chn)[-200:]})
                    return
                except Exception:
                    pass
            self._json(200, {"messages": list(_inbox)[-200:]})
            return
        if self.path.startswith("/chutil"):  # /* chutilBridge */
            try:
                with _lock:
                    iface = _iface
                    ids = set(_my_ids)
                live = mesh_chutil.pick_local_metrics(iface, ids) if iface else None
                hist = mesh_chutil.hist_payload(CHUTIL_FILE, hours=24)
                self._json(200, {"ok": True, "live": live, "hist": hist})
            except Exception as e:
                self._json(500, {"ok": False, "error": str(e)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):  # meshSendHarden # meshSendStable # funkHarden2: /send pruefen (Kanal 0-7, Text 1-220, keine Steuerzeichen)
        if self.path.startswith("/hold"):
            hold_bridge()
            self._json(200, dict(_state, held=True))
            return
        if self.path.startswith("/resume"):
            ok = resume_bridge()
            self._json(200, dict(_state, held=is_held(), resume_ok=ok))
            return
        if not self.path.startswith("/send"):
            self._json(404, {"error": "not found"})
            return
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


def chutil_worker():  # /* chutilBridge */
    """DeviceMetrics periodisch in CHUTIL_FILE schreiben (keine 2. TCP-Session)."""
    while True:
        time.sleep(60)
        try:
            with _lock:
                iface = _iface
                ids = set(_my_ids)
            if not iface:
                continue
            r = mesh_chutil.sample_and_store(iface, CHUTIL_FILE, my_ids=ids, min_gap=300)
            if r.get("ok") and r.get("wrote"):
                cur = r.get("current") or {}
                log("chutil", cur.get("ch_util"), "% air", cur.get("air_tx"), cur.get("node"))
        except Exception as e:
            log("chutil:", e)


def main():
    # mesh2Calm: TCP-Wache, Keepalive-Faden
    _m2c_install_tcp_guard()
    threading.Thread(target=_m2c_keepalive, daemon=True, name="m2calm-keepalive").start()
    log("mesh2Calm aktiv: Keepalive alle %d s, Reconnect nur Keeper, Episoden %d s, Ruhezeit %d s" % (
        M2C_KA_EVERY, M2C_EP_GAP, M2C_BOOT_QUIET))
    # mesh2OneSession: Keeper-Faden
    threading.Thread(target=_m2os_keeper, daemon=True, name="m2os-keeper").start()
    log("mesh2OneSession aktiv: eine TCP-Session, Keeper alle", M2OS_KEEPER_EVERY, "s")
    # Basis
    load_inbox()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=watchdog, daemon=True).start()
    threading.Thread(target=chutil_worker, daemon=True).start()  # /* chutilBridge */
    try:
        connect()
    except Exception as e:
        log("Start-Connect:", e)
    httpd = ThreadingHTTPServer(LISTEN, Handler)
    log("Bridge auf http://127.0.0.1:5002")
    httpd.serve_forever()


# ===== Schichten, die beim Start aktiv werden (Reihenfolge wie bisher: funkHarden m2, funkHarden2) =====
_m2f_orig_pick = mesh_chutil.pick_local_metrics
mesh_chutil.pick_local_metrics = _m2f_pick
log("funkHarden m2 aktiv: lastHeard = letztes Paket eines anderen Knotens, Node-DB aus Sitzung")

log("funkHarden2 aktiv (%s): Doppelsendeschutz %d s, kein Retry nach Schreibfehler, /send geprueft, HTTP-Log leise" % (
    _fh2_mesh_key(), FH2_DUP_SEC))


if __name__ == "__main__":
    main()
BA_EMBED_4_EOF
EXPECT_5="38eb565231b6b8193e81efe2c4c2212ccfd8119928e04dbdb75d60c51c658060"
cat > "$W/guardbridge.py" << 'BA_EMBED_5_EOF'
#!/usr/bin/env python3
"""Bridge-Guard (statische Pruefung der Bridge-Dateien) und Mutationstest der Pruefungen.
Aufruf: guardbridge.py check|mutation <Ordner> [dedup|prio]
Der Ordner enthaelt mesh_bridge.py und mesh_bridge_bayern.py. Stufe: bridgeDedup (genau eine Definition je Name, keine Schicht-Aliase, nur ein Sendepfad)."""
import ast, os, re, sys

FILES = ("mesh_bridge.py", "mesh_bridge_bayern.py")
REQ = {
    "mesh_bridge.py": {"on_receive", "worker", "main", "connect", "send_now", "watchdog", "chutil_worker", "close_iface", "ensure_iface", "is_held", "hold_bridge", "resume_bridge", "add_inbox", "Handler"},
    "mesh_bridge_bayern.py": {"on_receive", "worker", "main", "connect", "send_now", "_send_text", "_connect_tcp", "watchdog", "chutil_worker", "close_iface", "ensure_iface", "is_held", "hold_bridge",
                              "resume_bridge", "add_inbox", "Handler", "_m2os_event", "_m2os_write", "_m2os_keeper", "_m2os_presend", "_m2c_episode", "_m2c_keepalive", "_M2cQueue"},
}
HANDLER = {"do_GET", "do_POST", "log_message", "_json"}
BAD_IMPORT = {"subprocess", "socket", "requests", "urllib.request", "telegram", "smtplib", "http.client", "ftplib"}

def load(d):
    return {f: open(os.path.join(d, f), encoding="utf-8").read() for f in FILES}

def toplevel_names(tree):
    """Liste (Name, Art) aller Top-Level-Definitionen und Zuweisungen auf Namen."""
    out = []
    for n in tree.body:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
            out.append((n.name, "def"))
        elif isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    out.append((t.id, "assign"))
    return out

PRIO_CONST = {"PRIO_ALARM": 0, "PRIO_DETAIL": 1, "PRIO_ROUTINE": 5, "PRIO_TEST": 9, "ROUTINE_MAX": 10}

def prio_checks(f, t, tree):
    """Stufe bridgePrio: Prioritaetswarteschlange, Sendeabstand vor dem Entnehmen, Konstanten, kein zweites Entnehmen."""
    c = []
    consts = {}
    for n in tree.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Constant):
            consts[n.targets[0].id] = n.value.value
    bad = sorted(k for k, v in PRIO_CONST.items() if consts.get(k) != v or isinstance(consts.get(k), bool))
    c.append(("%s: Prioritaets-Konstanten 0/1/5/9, Routine-Grenze 10 (falsch: %s)" % (f, ",".join(bad) or "-"), not bad))
    c.append(("%s: SEND_GAP = 3.0 unveraendert" % f, consts.get("SEND_GAP") == 3.0))
    pre = [n for n in tree.body if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id == "_ALARM_PREFIX" for x in n.targets)]
    ok = bool(pre) and isinstance(pre[0].value, ast.Tuple) and [getattr(e, "value", None) for e in pre[0].value.elts] == ["ALARM ", "ALARM:", "NINA: "]
    c.append(("%s: Alarm-Praefixe ALARM / ALARM: / NINA: " % f, ok))
    sq = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "_SendQueue"]
    base = [ast.unparse(b) for b in sq[0].bases] if len(sq) == 1 else []
    c.append(("%s: _SendQueue genau einmal, von queue.Queue abgeleitet (Heap, kein PriorityQueue)" % f, base == ["queue.Queue"] and "PriorityQueue" not in t))
    asg = [n for n in tree.body if isinstance(n, ast.AnnAssign) and getattr(n.target, "id", "") == "_send_q"]
    v = ast.unparse(asg[0].value) if len(asg) == 1 else ""
    c.append(("%s: _send_q ist eine _SendQueue-Ableitung mit maxsize=50 (ist: %s)" % (f, v), v in ("_SendQueue(maxsize=50)", "_M2cQueue(maxsize=50)")))
    gets = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "get" and ast.unparse(n.func.value) == "_send_q"]
    c.append(("%s: genau ein Entnehmen aus der Sende-Queue (ist %d)" % (f, len(gets)), len(gets) == 1))
    w = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "worker"]
    ordok = False
    if w and len(gets) == 1:
        sl = [n.lineno for n in ast.walk(w[0]) if isinstance(n, ast.Call) and ast.unparse(n.func) == "time.sleep" and ast.unparse(n.args[0]) == "wait"]
        wa = [n.lineno for n in ast.walk(w[0]) if isinstance(n, ast.Assign) and ast.unparse(n.value) == "SEND_GAP - (time.time() - last)"]
        ordok = len(sl) == 1 and len(wa) == 1 and wa[0] < sl[0] < gets[0].lineno
    c.append(("%s: Sendeabstand (SEND_GAP) wird VOR dem Entnehmen eingehalten" % f, ordok))
    c.append(("%s: /health meldet q_alarm, q_routine, prio" % f, all(k in t for k in ("q_alarm=q_hi", "q_routine=q_lo", "prio=dict(_pq)"))))
    c.append(("%s: Prioritaet im POST geprueft (400 prio ungueltig)" % f, "prio ungueltig (0-9)" in t))
    return c

def checks(texts, stage="dedup"):
    c = []
    for f in FILES:
        t = texts[f]
        try:
            tree = ast.parse(t)
        except SyntaxError as e:
            c.append(("%s: Syntax" % f, False)); continue
        names = toplevel_names(tree)
        defs = [n for n, k in names if k == "def"]
        dup = sorted({n for n in defs if defs.count(n) > 1})
        c.append(("%s: jede Funktion/Klasse genau einmal definiert (doppelt: %s)" % (f, ",".join(dup) or "-"), not dup))
        # Name wird als Funktion definiert und spaeter neu zugewiesen (Monkey-Patch einer eigenen Funktion)
        rebind = sorted({n for n, k in names if k == "assign" and n in defs})
        c.append(("%s: keine Funktion wird nach der Definition ueberschrieben (%s)" % (f, ",".join(rebind) or "-"), not rebind))
        # Funktionen im Modul ueberschreiben per Attribut-Zuweisung auf eigenes Modul / Handler
        selfpatch = [m for m in re.findall(r"(?m)^(Handler\.\w+|sys\.modules\[__name__\]\.\w+|globals\(\)\[[^\]]+\])\s*=", t)]
        c.append(("%s: kein Handler-/Modul-Patching am Dateiende (%s)" % (f, ",".join(selfpatch) or "-"), not selfpatch))
        orig = sorted(set(re.findall(r"\b_\w*_orig_\w+\b", t)) - {"_m1f_orig_pick", "_m2f_orig_pick"})  # pick = Alias der Bibliotheksfunktion mesh_chutil.pick_local_metrics (bleibt)
        c.append(("%s: keine Schicht-Aliase _*_orig_* mehr (%s)" % (f, ",".join(orig[:5]) or "-"), not orig))
        missing = sorted(REQ[f] - set(defs))
        c.append(("%s: Pflicht-Funktionen vorhanden (fehlt: %s)" % (f, ",".join(missing) or "-"), not missing))
        hcls = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Handler"]
        if hcls:
            meth = [x.name for x in hcls[0].body if isinstance(x, ast.FunctionDef)]
            dm = sorted({x for x in meth if meth.count(x) > 1})
            c.append(("%s: Handler-Methoden genau einmal, do_GET/do_POST/log_message/_json vorhanden (doppelt: %s)" % (f, ",".join(dm) or "-"), not dm and HANDLER <= set(meth)))
        else:
            c.append(("%s: Handler vorhanden" % f, False))
        imps = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.Import):
                imps |= {a.name for a in n.names}
            elif isinstance(n, ast.ImportFrom) and n.module:
                imps.add(n.module)
        bad = sorted(imps & BAD_IMPORT)
        c.append(("%s: keine Netz-/Prozess-Importe ausser der Meshtastic-Bibliothek (%s)" % (f, ",".join(bad) or "-"), not bad))
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "sendText"]
        c.append(("%s: genau ein Sendepfad (sendText einmal im Code, ist %d)" % (f, len(calls)), len(calls) == 1))
        sysc = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("system", "popen", "Popen", "run", "check_output", "call")
                and isinstance(n.func.value, ast.Name) and n.func.value.id in ("os", "subprocess")]
        c.append(("%s: keine Prozessaufrufe" % f, not sysc))
        c.append(("%s: keine Geheimnisse/Zugangsdaten gelesen (config.py, secrets/)" % f, not re.search(r"config\.py|secrets/|TELEGRAM|token", re.sub(r"(?m)#.*$", "", t))))
        # Wiederholte Sendeversuche verboten: Wiederholungs-Hinweis muss erhalten bleiben
        c.append(("%s: Doppelsendeschutz erhalten (Marker 'KEIN Wiederholversuch', FH2_DUP_SEC = 120)" % f, "KEIN Wiederholversuch" in t and re.search(r"(?m)^FH2_DUP_SEC = 120\b", t) is not None))
        if stage == "prio":
            c += prio_checks(f, t, tree)
    return c

# Mutationen: (Beschreibung, Datei, alt, neu) - jede muss mindestens eine Pruefung kippen
MUT = [
 ("worker doppelt", "mesh_bridge.py", "\ndef chutil_worker", "\ndef worker():\n    pass\n\n\ndef chutil_worker"),
 ("on_receive doppelt", "mesh_bridge.py", "\ndef chutil_worker", "\ndef on_receive(packet, interface=None):\n    pass\n\n\ndef chutil_worker"),
 ("Alias wieder da", "mesh_bridge.py", "\ndef chutil_worker", "\n_m1f_orig_on_receive = on_receive\n\n\ndef chutil_worker"),
 ("main entfernt", "mesh_bridge.py", "def main(", "def main_x("),
 ("Handler-Patching", "mesh_bridge.py", "\ndef chutil_worker", "\nHandler.do_GET = lambda self: None\n\n\ndef chutil_worker"),
 ("Funktion ueberschrieben", "mesh_bridge.py", "\ndef chutil_worker", "\nworker = lambda: None\n\n\ndef chutil_worker"),
 ("zweiter Sendepfad", "mesh_bridge.py", "\ndef chutil_worker", "\ndef _x(i):\n    i.sendText('x')\n\n\ndef chutil_worker"),
 ("Prozessimport", "mesh_bridge.py", "\ndef chutil_worker", "\nimport subprocess\n\n\ndef chutil_worker"),
 ("Socket-Import", "mesh_bridge_bayern.py", "\ndef chutil_worker", "\nimport socket\n\n\ndef chutil_worker"),
 ("os.system", "mesh_bridge_bayern.py", "\ndef chutil_worker", "\ndef _y():\n    import os\n    os.system('x')\n\n\ndef chutil_worker"),
 ("Secret lesen", "mesh_bridge_bayern.py", "\ndef chutil_worker", "\n_z = open('config.py')\n\n\ndef chutil_worker"),
 ("send_now doppelt (m2)", "mesh_bridge_bayern.py", "\ndef chutil_worker", "\ndef send_now(t, c=0):\n    return True\n\n\ndef chutil_worker"),
 ("Keeper entfernt (m2)", "mesh_bridge_bayern.py", "def _m2os_keeper(", "def _m2os_keeper_x("),
 ("Wiederholhinweis entfernt", "mesh_bridge_bayern.py", "KEIN Wiederholversuch", "Wiederholversuch erlaubt"),
 ("Dublettenfenster geaendert", "mesh_bridge.py", "FH2_DUP_SEC = 120", "FH2_DUP_SEC = 12"),
 ("Handler-Methode doppelt", "mesh_bridge_bayern.py", "    def _json(self, code, obj):", "    def do_GET(self):\n        pass\n\n    def _json(self, code, obj):"),
 ("zweiter sendText (m2)", "mesh_bridge_bayern.py", "\ndef chutil_worker", "\ndef _w(i):\n    i.sendText('x')\n\n\ndef chutil_worker"),
 ("_m2c_orig-Alias (m2)", "mesh_bridge_bayern.py", "\ndef chutil_worker", "\n_m2c_orig_main = main\n\n\ndef chutil_worker"),
 ("Syntaxfehler", "mesh_bridge.py", "def main(", "def main(:"),
]

MUT_PRIO = [
 ("Konstante Alarm", "mesh_bridge.py", "PRIO_ALARM = 0 ", "PRIO_ALARM = 2 "),
 ("Konstante Routine", "mesh_bridge_bayern.py", "PRIO_ROUTINE = 5 ", "PRIO_ROUTINE = 6 "),
 ("Routine-Grenze", "mesh_bridge.py", "ROUTINE_MAX = 10 ", "ROUTINE_MAX = 40 "),
 ("Routine-Grenze m2", "mesh_bridge_bayern.py", "ROUTINE_MAX = 10 ", "ROUTINE_MAX = 0 "),
 ("Praefix NINA entfernt", "mesh_bridge.py", '"ALARM:", "NINA: ")', '"ALARM:")'),
 ("PriorityQueue", "mesh_bridge.py", "class _SendQueue(queue.Queue):", "class _SendQueue(queue.PriorityQueue):"),
 ("Queue-Groesse", "mesh_bridge.py", "_send_q: queue.Queue = _SendQueue(maxsize=50)", "_send_q: queue.Queue = _SendQueue(maxsize=500)"),
 ("Queue-Groesse m2", "mesh_bridge_bayern.py", "_M2cQueue(maxsize=50)", "_M2cQueue(maxsize=5)"),
 ("normale Queue", "mesh_bridge.py", "_SendQueue(maxsize=50)", "queue.Queue(maxsize=50)"),
 ("Sendeabstand nach Entnehmen", "mesh_bridge.py", "            if wait > 0:\n                time.sleep(wait)\n            item = _send_q.get()", "            item = _send_q.get()\n            if wait > 0:\n                time.sleep(wait)"),
 ("Sendeabstand nach Entnehmen m2", "mesh_bridge_bayern.py", "            if wait > 0:\n                time.sleep(wait)\n            item = _send_q.get()", "            item = _send_q.get()\n            if wait > 0:\n                time.sleep(wait)"),
 ("Sendeabstand entfernt", "mesh_bridge.py", "wait = SEND_GAP - (time.time() - last)", "wait = 0 - (time.time() - last)"),
 ("SEND_GAP", "mesh_bridge.py", "SEND_GAP = 3.0", "SEND_GAP = 1.0"),
 ("zweites Entnehmen", "mesh_bridge.py", "\ndef chutil_worker", "\ndef _g():\n    return _send_q.get()\n\n\ndef chutil_worker"),
 ("health ohne q_alarm", "mesh_bridge.py", "q_alarm=q_hi", "q_al=q_hi"),
 ("POST ohne Pruefung", "mesh_bridge_bayern.py", "prio ungueltig (0-9)", "prio kaputt"),
]

def main():
    mode, d = sys.argv[1], sys.argv[2]
    stage = sys.argv[3] if len(sys.argv) > 3 else "dedup"
    texts = load(d)
    res = checks(texts, stage)
    bad = [n for n, ok in res if not ok]
    if mode == "check":
        for n in bad:
            print("GUARD FEHLER:", n)
        print("guard: %d Pruefungen, %d fehlerhaft" % (len(res), len(bad)))
        sys.exit(1 if bad else 0)
    if mode == "mutation":
        if bad:
            print("Mutationstest abgebrochen: Guard schon im Original rot:", bad[0]); sys.exit(1)
        surv = []
        for name, f, a, b in (MUT + (MUT_PRIO if stage == "prio" else [])):
            if texts[f].count(a) < 1:
                print("Mutation nicht anwendbar:", name); sys.exit(1)
            t2 = dict(texts); t2[f] = texts[f].replace(a, b, 1)
            if all(ok for _, ok in checks(t2, stage)):
                surv.append(name)
        for s in surv:
            print("MUTATION UEBERSEHEN:", s)
        nm = len(MUT) + (len(MUT_PRIO) if stage == "prio" else 0)
        print("mutation: %d Mutationen, %d erkannt, %d uebersehen" % (nm, nm - len(surv), len(surv)))
        sys.exit(1 if surv else 0)

main()
BA_EMBED_5_EOF
EXPECT_6="5a437ab6869935a98a7e5d261caee54ab5a35884e0d960537f7d9fb64a75c7cf"
mkdir -p "$W/test"
cat > "$W/test/bridgeharness.py" << 'BA_EMBED_6_EOF'
#!/usr/bin/env python3
"""Pruefgeruest fuer die Mesh-Bridges (nur Sandbox, Fakes, nichts Echtes): laedt eine Bridge-Datei (oder Starter + Kern) mit
Fake-meshtastic/pubsub/mesh_*-Modulen, Fake-Uhr und Fake-Threads, fuehrt Szenarien aus und liefert ein normalisiertes Protokoll.
Es wird nie ein Socket geoeffnet, nichts gesendet, nichts am Pi oder im echten Projektordner angefasst (Pfade werden in ein Temp-Verzeichnis umgelenkt)."""
import contextlib, io, json, os, re, sys, tempfile, threading, time, types, shutil, queue as _queue

REAL = "/home/fmg/prepper-dashboard"


class StopLoop(BaseException):
    pass


class Env:
    def __init__(self, sandbox):
        self.sandbox = sandbox
        self.ev = []
        self.clock = 1_800_000_000.0
        self.sleep_budget = None
        self.knobs = {"fail_connect": 0, "fail_send": 0, "fail_heartbeat": 0}
        self.listeners = []
        self.probe = None
        self.ifaces = []
        self.sendlog = []
        self.last_send_t = 0.0
        self.threads = []
        env = self

        class FakeIface:
            def __init__(self, hostname=None, **kw):
                env.ev.append(("tcp_init", hostname, env.probe() if env.probe else None))
                if env.knobs["fail_connect"] > 0:
                    env.knobs["fail_connect"] -= 1
                    raise OSError(env.knobs.get("err_text") or "connect fail")
                self.hostname = hostname
                self.nodes = {"!aa": {"user": {"id": "!aa", "longName": "Alpha", "shortName": "A"}, "lastHeard": env.clock - 30},
                              "!bb": {"user": {"id": "!bb", "shortName": "B"}, "lastHeard": (env.clock - 90) * 1000.0},
                              "!cc": "kaputt"}
                self.myInfo = types.SimpleNamespace(my_node_num=0x0c18a994)
                self.localNode = types.SimpleNamespace(channels=[
                    types.SimpleNamespace(settings=types.SimpleNamespace(name=""), role="PRIMARY"),
                    types.SimpleNamespace(settings=types.SimpleNamespace(name="Privat"), role="SECONDARY"),
                    types.SimpleNamespace(settings=types.SimpleNamespace(name=""), role="DISABLED")])
                self.isConnected = threading.Event()
                self.isConnected.set()
                self._wantExit = False
                self.idx = len(env.ifaces)
                env.ifaces.append(self)

            def sendText(self, text, channelIndex=0, **kw):
                env.ev.append(("sendText", self.idx, text, channelIndex))
                env.sendlog.append((env.clock, text, channelIndex))
                env.last_send_t = env.clock
                if env.knobs["fail_send"] > 0:
                    env.knobs["fail_send"] -= 1
                    raise OSError(env.knobs.get("err_text") or "send fail")

            def sendHeartbeat(self):
                env.ev.append(("heartbeat", self.idx))
                if env.knobs["fail_heartbeat"] > 0:
                    env.knobs["fail_heartbeat"] -= 1
                    raise OSError(env.knobs.get("err_text") or "heartbeat fail")

            def close(self):
                env.ev.append(("close", self.idx))

            def _reconnect(self):
                env.ev.append(("lib_reconnect", self.idx))
        self.FakeIface = FakeIface

        class Pub:
            def subscribe(_s, fn, topic):
                env.ev.append(("subscribe", fn.__name__, topic))
                env.listeners.append((fn, topic))

            def unsubscribe(_s, fn, topic):
                for i, (f, t) in enumerate(env.listeners):
                    if f is fn and t == topic:
                        del env.listeners[i]
                        env.ev.append(("unsubscribe", fn.__name__, topic))
                        return
                env.ev.append(("unsubscribe-fehlt", fn.__name__, topic))
                raise Exception("not subscribed")
        self.pub = Pub()

        chut = types.ModuleType("mesh_chutil")

        def pick_local_metrics(iface, my_ids=None):
            env.ev.append(("chutil_pick", iface is not None, sorted(my_ids or [])))
            return {"nodedb": 3, "ch_util": 12.5, "air_tx": 1.0, "node": "n"} if iface is not None else None

        def hist_payload(path, hours=24):
            return {"file": os.path.basename(str(path)), "hours": hours}

        def sample_and_store(iface, path, my_ids=None, min_gap=300):
            r = chut.pick_local_metrics(iface, my_ids)
            env.ev.append(("chutil_sample", os.path.basename(str(path)), min_gap))
            return {"ok": True, "wrote": True, "current": {"ch_util": (r or {}).get("ch_util"), "air_tx": 1, "node": "n"}}
        chut.pick_local_metrics, chut.hist_payload, chut.sample_and_store = pick_local_metrics, hist_payload, sample_and_store
        lab = types.ModuleType("mesh_node_label")
        lab.label_from_iface = lambda iface, fid: "L:%s" % fid
        rw = types.ModuleType("mesh_reply_watch")
        for nm in ("note_tx", "note_rx", "note_reply"):
            def mk(nm=nm):
                def f(*a, **kw):
                    env.ev.append(("reply_watch", nm) + tuple(a))
                return f
            setattr(rw, nm, mk())
        mt = types.ModuleType("meshtastic")
        ti = types.ModuleType("meshtastic.tcp_interface")
        ti.TCPInterface = self.FakeIface
        mt.tcp_interface = ti
        ps = types.ModuleType("pubsub")
        ps.pub = self.pub
        self.modules = {"mesh_chutil": chut, "mesh_node_label": lab, "mesh_reply_watch": rw,
                        "meshtastic": mt, "meshtastic.tcp_interface": ti, "pubsub": ps}
        self.chut = chut

        class FakeThread:
            def __init__(t, target=None, args=(), kwargs=None, daemon=None, name=None, **kw):
                t.target, t.args, t.daemon, t.name = target, args, daemon, name

            def start(t):
                env.threads.append((getattr(t.target, "__name__", "?"), t.name, t.daemon))
                env.ev.append(("thread_start", getattr(t.target, "__name__", "?"), t.name, t.daemon))
        self.FakeThread = FakeThread

        class FakeServer:
            def __init__(s, addr, handler):
                env.ev.append(("server", tuple(addr), handler.__name__))

            def serve_forever(s):
                env.ev.append(("serve_forever",))
                raise StopLoop()
        self.FakeServer = FakeServer

    def fake_time(self):
        return self.clock

    def fake_sleep(self, s):
        self.ev.append(("sleep", round(float(s), 3)))
        self.clock += float(s)
        if self.sleep_budget is not None:
            self.sleep_budget -= 1
            if self.sleep_budget < 0:
                self.sleep_budget = None
                raise StopLoop()

    @contextlib.contextmanager
    def patched(self):
        saved_mod = {k: sys.modules.get(k) for k in list(self.modules) + ["mesh_bridge_core", "config"]}
        import socket as _sk
        saved = (time.time, time.sleep, threading.Thread, sys.path[:])
        saved_sock = (_sk.socket.connect, _sk.create_connection)
        def _no_net(*a, **k):
            self.ev.append(("SOCKET-VERSUCH",))
            raise OSError("Sandbox: kein Netzzugriff")
        _sk.socket.connect = _no_net
        _sk.create_connection = _no_net
        sys.modules.update(self.modules)
        sys.modules.pop("config", None)
        time.time, time.sleep, threading.Thread = self.fake_time, self.fake_sleep, self.FakeThread
        try:
            yield
        finally:
            time.time, time.sleep, threading.Thread = saved[0], saved[1], saved[2]
            _sk.socket.connect, _sk.create_connection = saved_sock
            sys.path[:] = saved[3]
            for k, v in saved_mod.items():
                if v is None:
                    sys.modules.pop(k, None)
                else:
                    sys.modules[k] = v


def _src(path, sandbox):
    return open(path, encoding="utf-8").read().replace(REAL, sandbox)


def load(files, env, target=None, name="bridge_under_test"):
    """files: Pfad der Bridge-Datei ODER Liste [(Modulname|None, Pfad)] - zuerst Kern(e), zuletzt Starter. target: Modul, dessen Namensraum die Szenarien sehen (Standard: das zuletzt geladene)."""
    if isinstance(files, str):
        files = [(None, files)]
    mods = {}
    out = io.StringIO()
    err = io.StringIO()
    with env.patched(), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        last = None
        for modname, path in files:
            m = types.ModuleType(modname or name)
            m.__file__ = path
            if modname:
                sys.modules[modname] = m
            exec(compile(_src(path, env.sandbox), path, "exec"), m.__dict__)
            mods[modname or name] = m
            last = m
            if hasattr(m, "ThreadingHTTPServer"):
                m.ThreadingHTTPServer = env.FakeServer
    m = mods[target] if target else last
    return m, out.getvalue() + err.getvalue()


DT = re.compile(r"\d\d\.\d\d\.\d{4} \d\d:\d\d:\d\d")
TM = re.compile(r"\b\d\d:\d\d:\d\d\b")
AD = re.compile(r" at 0x[0-9a-f]+")


SB = [""]


def norm(v):
    if isinstance(v, str):
        if SB[0]:
            v = v.replace(SB[0], "<SB>")
        v = DT.sub("<DT>", v)
        v = re.sub(r'"pid": \d+', '"pid": "<PID>"', v)
        return TM.sub("<T>", v)
    if isinstance(v, bytes):
        return norm(v.decode("utf-8", "replace"))
    if isinstance(v, bool) or v is None or isinstance(v, int):
        return v
    if isinstance(v, float):
        return round(v, 3)
    if isinstance(v, dict):
        return {str(k): ('<PID>' if (str(k) == 'pid' and x == os.getpid()) else norm(x)) for k, x in sorted(v.items(), key=lambda kv: str(kv[0]))}
    if isinstance(v, (list, tuple)):
        return [norm(x) for x in v]
    if isinstance(v, (set, frozenset)):
        return sorted(norm(x) for x in v)
    try:
        import collections
        if isinstance(v, collections.deque):
            return [norm(x) for x in v]
    except Exception:
        pass
    return AD.sub("", repr(v))


def drain(q):
    out = []
    while True:
        try:
            out.append(q.get_nowait())
        except _queue.Empty:
            return out


def jfiles(sandbox):
    res = {}
    for root, _d, fs in os.walk(sandbox):
        for f in sorted(fs):
            p = os.path.join(root, f)
            rel = os.path.relpath(p, sandbox)
            if rel.endswith(".tmp"):
                continue
            t = open(p, encoding="utf-8", errors="replace").read()
            try:
                res[rel] = json.loads(t)
            except Exception:
                res[rel] = t
    return res


def snap(m, env):
    g = lambda n: getattr(m, n, None)
    s = {"state": dict(g("_state") or {}), "inbox": list(g("_inbox") or []), "my_ids": sorted(g("_my_ids") or []),
         "iface": None if g("_iface") is None else g("_iface").idx, "q": g("_send_q").qsize() if g("_send_q") is not None else None}
    fh2 = g("_fh2")
    if fh2:
        s["fh2"] = {k: (list(v) if k == "recent" else v) for k, v in fh2.items()}
    for nm in ("_m1f", "_m2f"):
        x = g(nm)
        if x is not None:
            s[nm] = {k: (list(v.items()) if hasattr(v, "items") else v) for k, v in x.items()}
    x = g("_m2os")
    if x is not None:
        s["_m2os"] = {k: (list(v) if hasattr(v, "__iter__") and not isinstance(v, (str, dict)) else v) for k, v in x.items() if k != "closed_ids"}
        s["_m2os"]["closed_n"] = len(x["closed_ids"])
        s["_m2os"]["pong_last"] = dict(x["pong_last"])
    x = g("_m2c")
    if x is not None:
        s["_m2c"] = {k: (list(v) if hasattr(v, "__iter__") and not isinstance(v, (str, dict)) else v) for k, v in x.items()}
    s["files"] = jfiles(env.sandbox)
    return s


class Run:
    """Ein Szenario in frischer Sandbox: T(label, wert) schreibt ins Protokoll."""
    def __init__(self, path, scenario, target=None, files=None, setup=None):
        self.sandbox = tempfile.mkdtemp(prefix="bridgetest-")
        os.makedirs(os.path.join(self.sandbox, "x"), exist_ok=True)
        self.env = Env(self.sandbox)
        SB[0] = self.sandbox
        self.rec = []
        self.path, self.scenario, self.target, self.files, self.setup = path, scenario, target, files, setup

    def T(self, label, value=None):
        self.rec.append([label, norm(value)])

    def go(self):
        env = self.env
        try:
            m, imp = load(self.files or self.path, env, self.target)
            self.m = m
            env.probe = lambda: (m._lock.locked() if hasattr(m, "_lock") else None)
            self.T("import-log", imp.split("\n"))
            if self.setup:
                self.setup(self, m)
            err = io.StringIO()
            out = io.StringIO()
            with env.patched(), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    self.scenario(self, m, env)
                except StopLoop:
                    self.T("StopLoop")
            self.T("stdout", out.getvalue().split("\n"))
            tb = err.getvalue()
            self.T("stderr", {"tracebacks": tb.count("Traceback (most recent call"), "lines": [l for l in tb.split("\n") if l and not l.startswith((" ", "Traceback"))]})
            self.T("events", env.ev)
            self.T("snap", snap(m, env))
        finally:
            shutil.rmtree(self.sandbox, ignore_errors=True)
        return self.rec


def handler(m, path, body=None, headers=None, rec=None):
    H = m.Handler
    h = H.__new__(H)
    h.path = path
    hd = dict(headers or {})
    if body is not None and "Content-Length" not in hd:
        hd["Content-Length"] = str(len(body))
    h.headers = hd
    h.rfile = io.BytesIO(body or b"")
    h.wfile = io.BytesIO()
    out = []
    h.send_response = lambda code, message=None: out.append(["status", code])
    h.send_header = lambda k, v: out.append(["hdr", k, v])
    h.end_headers = lambda: None
    return h, out


def call_http(m, verb, path, body=None, headers=None):
    h, out = handler(m, path, body, headers)
    getattr(h, "do_" + verb)()
    raw = h.wfile.getvalue()
    try:
        j = json.loads(raw)
    except Exception:
        j = raw
    return out, j


def compare(a, b, label=""):
    """-> Liste der Abweichungen (leer = identisch)"""
    diffs = []
    if len(a) != len(b):
        diffs.append("%s: Protokolllaenge %d != %d" % (label, len(a), len(b)))
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            diffs.append("%s: Eintrag %d (%s) weicht ab:\n   alt: %s\n   neu: %s" % (label, i, x[0], json.dumps(x[1], ensure_ascii=False)[:600], json.dumps(y[1], ensure_ascii=False)[:600]))
    return diffs
BA_EMBED_6_EOF
EXPECT_7="d03229159c16a86137dec242e4e674bb0fb78a0339cb75ade208935b9804c08b"
mkdir -p "$W/test"
cat > "$W/test/scenarios.py" << 'BA_EMBED_7_EOF'
"""Szenario-Matrix fuer die Aequivalenzpruefung (alt gegen neu). Jedes Szenario laeuft in frischer Sandbox mit Fakes."""
import json, queue
from bridgeharness import *

def has(m, n):
    return hasattr(m, n)

def pk(frm="!1234abcd", text="ping", ch=None, port="TEXT_MESSAGE_APP", **kw):
    p = {"fromId": frm, "decoded": {"text": text, "portnum": port}, "rxSnr": 5.5, "rxRssi": -90, "hopStart": 3, "hopLimit": 2}
    if ch is not None:
        p["channel"] = ch
    p.update(kw)
    return p

def connected(R, m, env):
    iface = m.connect()
    R.T("connect", {"iface": iface.idx, "ids": m._my_ids})
    return iface

# ---------------------------------------------------------------- Szenarien
def s_import(R, m, env):
    R.T("konstanten", {n: getattr(m, n, None) for n in ("HOST", "LISTEN", "SEND_GAP", "RECONNECT_WAIT", "STATION", "INBOX_MAX", "HOLD_MAX", "FH2_DUP_SEC", "FH2_TEXT_MAX",
        "M1F_KEEP", "M2OS_STALE_RECONNECT", "M2OS_PRESEND_STALE", "M2OS_KEEPER_EVERY", "M2OS_ADD_PONG", "M2OS_PONG_COOLDOWN", "M2C_KA_EVERY", "M2C_EP_GAP", "M2C_BOOT_QUIET", "M2C_BACKLOG_WIN", "M2C_BACKLOG_AGE")})
    R.T("triggers", sorted(m.TRIGGERS))
    R.T("handler", {n: callable(getattr(m.Handler, n, None)) for n in ("do_GET", "do_POST", "log_message", "_json")})
    R.T("chutil-patched", m.mesh_chutil.pick_local_metrics.__name__)
    R.T("known", m.node_name("202942868"))

def s_conn(R, m, env):
    iface = connected(R, m, env)
    R.T("connect2", m.connect().idx)
    env.clock += 2
    R.T("connect3", m.connect().idx)
    env.clock += 3.2
    R.T("connect3b", m.connect().idx)
    env.clock += 100
    R.T("connect4", m.connect().idx)
    R.T("ensure", m.ensure_iface().idx)
    R.T("state", m._state)
    m.close_iface()
    R.T("after-close", m._state)
    R.T("close-twice", m.close_iface())
    R.T("ensure-after", m.ensure_iface().idx)
    R.T("hold", m.hold_bridge())
    R.T("held", m.is_held())
    try:
        m.ensure_iface()
    except Exception as e:
        R.T("ensure-held", repr(e))
    env.clock += m.HOLD_MAX + 1
    R.T("held-after", m.is_held())
    env.knobs["fail_connect"] = 1
    try:
        m.connect()
    except Exception as e:
        R.T("connect-fail", repr(e))
    R.T("resume-ok", m.resume_bridge())
    env.knobs["fail_connect"] = 1
    R.T("resume-fail", m.resume_bridge())
    R.T("channels", m.list_station_channels())
    R.T("names", [m.node_name(x) for x in (None, "", "!aa", "170", "!bb", "!zz", 202942868, "!c18a994")])
    if has(m, "_m2os_dead"):
        R.T("dead", m._m2os_dead())
        env.ifaces[-1].isConnected.clear()
        R.T("dead2", m._m2os_dead())

def s_rx(R, m, env):
    iface = connected(R, m, env)
    other = object()
    packets = [
        (None, iface), ({}, iface), (pk(), iface), (pk(text="PING"), None), (pk(text="Test "), iface), (pk(text="wetter", ch=0), iface),
        (pk(text="hallo welt"), iface), (pk(frm="!0c18a994", text="ping"), iface), (pk(frm=202942868, text="ping"), iface), (pk(frm="!c18a994", text="ping"), iface),
        (pk(text="ping", ch=1), iface), (pk(text="ping", ch=3), iface), (pk(text="Hallo von knoten.eu"), iface), (pk(text="mesh hessen gruss", ch=0), iface),
        (pk(port="TELEMETRY_APP", text=""), iface), (pk(encrypted=b"xx", text=""), iface), ({"fromId": None, "decoded": None}, iface), ({"decoded": "kaputt"}, iface),
        (pk(text="ping"), other), (pk(frm=12345, text="nina"), iface), (pk(text="pegel", hopStart=None), iface), (pk(text="odl", hops=4, hopStart=None, hopLimit=None), iface),
        (pk(text="help", rxSnr=None, rxRssi=None), iface), (pk(text="status", rxTime=env.clock - 500), iface), (pk(text="x" * 400), iface), (pk(frm="!aa", text="gas"), iface),
        ("kein dict", iface), ([1], iface),
    ]
    steps = [0, 10, 400]   # Uhr: Ruhezeit nach Start / danach
    for k, adv in enumerate(steps):
        env.clock += adv
        for i, (p, ifc) in enumerate(packets):
            before = m._send_q.qsize()
            r = m.on_receive(p, ifc)
            R.T("rx%d.%d" % (k, i), {"ret": r, "q": drain(m._send_q) if True else None, "state": {k2: v for k2, v in m._state.items()}})
        if has(m, "_m2c"):
            R.T("m2c%d" % k, m._m2c["quiet_drop"])
    R.T("inbox-files", jfiles(R.sandbox))
    # Pong-Zusatz (nur Bridge 2): M2OS_ADD_PONG = True
    if has(m, "M2OS_ADD_PONG"):
        m.M2OS_ADD_PONG = True
        env.clock += 100
        for i, (p, ifc) in enumerate(packets):
            r = m.on_receive(p, ifc)
            R.T("pong%d" % i, {"q": drain(m._send_q), "last": m._m2os["pong_last"]})
        env.clock += 30
        for i, (p, ifc) in enumerate(packets[:6]):
            m.on_receive(p, ifc)
            R.T("pongb%d" % i, drain(m._send_q))
    # volle Queue
    for i in range(55):
        try:
            m._send_q.put_nowait("füller %d" % i)
        except queue.Full:
            R.T("full-at", i)
            break
    m.on_receive(pk(text="ping"), iface)
    R.T("rx-queue-voll", m._state["queued"])

def s_worker(R, m, env):
    q = m._send_q
    real_get = q.get
    def get(*a, **k):
        if q.qsize() == 0:
            raise StopLoop()
        return real_get(*a, **k)
    q.get = get
    reply = m.STATION + "\nEmpfang 10:00:00\nAntwort 10:00:00\nSNR 5 dB"
    items = ["Text als String", {"text": "dict ch0", "channel": 0}, {"text": "dict ch2", "channel": 2}, {"text": "dict ch7", "channel": "7"}, {"text": "bad ch", "channel": 9},
             {"text": "bad ch2", "channel": "x"}, {"text": "bad ch3", "channel": True}, {"text": "bad ch4", "channel": 1.5}, {"text": "float ch", "channel": 2.0}, {"text": "   ", "channel": 0},
             {"text": "Steuer\x01zeichen\ttab\r\nzeile", "channel": None}, {"text": "A" * 300}, {"text": "dict ch0"}, "Text als String", {"text": reply, "channel": 0}, {"channel": 1}, None, 5]
    for chunk in (items[:9], items[9:]):   # hoechstens 10 Routine-Eintraege gleichzeitig (bridgePrio-Obergrenze)
        for it in chunk:
            q.put_nowait(it)
        m._state["queued"] = q.qsize()
        try:
            m.worker()
        except StopLoop:
            pass
    R.T("worker-1-ende")
    R.T("stand1", {"fh2": {k: v for k, v in m._fh2.items() if k != "recent"}, "clock": env.clock})
    env.clock += 130   # Dublettenfenster vorbei
    for it in ["Text als String", {"text": "dict ch0", "channel": 0}]:
        q.put_nowait(it)
    try:
        m.worker()
    except StopLoop:
        pass
    R.T("stand2", {k: v for k, v in m._fh2.items() if k != "recent"})
    # Senden schlaegt fehl
    env.knobs["fail_send"] = 1
    q.put_nowait({"text": "fehlschlag", "channel": 0}); q.put_nowait({"text": "danach", "channel": 0})
    try:
        m.worker()
    except StopLoop:
        pass
    env.knobs["fail_send"] = 2
    q.put_nowait({"text": "fehlschlag", "channel": 0}); q.put_nowait({"text": reply + "2", "channel": 0})
    try:
        m.worker()
    except StopLoop:
        pass
    R.T("stand3a", {k: v for k, v in m._fh2.items() if k != "recent"})
    R.T("stand3", {"fh2": {k: v for k, v in m._fh2.items() if k != "recent"}, "state": m._state})
    # Verbindung steht nicht und Aufbau scheitert
    m.close_iface()
    env.knobs["fail_connect"] = 2
    q.put_nowait({"text": "ohne verbindung", "channel": 0})
    try:
        m.worker()
    except StopLoop:
        pass
    R.T("stand4", {"fh2": {k: v for k, v in m._fh2.items() if k != "recent"}, "state": m._state})
    # Verbindung steht nicht, Aufbau klappt beim zweiten Versuch
    m.close_iface()
    env.knobs["fail_connect"] = 1
    q.put_nowait({"text": "reconnect hilft", "channel": 1})
    try:
        m.worker()
    except StopLoop:
        pass
    R.T("stand5", {"fh2": {k: v for k, v in m._fh2.items() if k != "recent"}, "state": m._state})
    # Hold
    m.hold_bridge()
    q.put_nowait({"text": "im hold", "channel": 0})
    try:
        m.worker()
    except StopLoop:
        pass
    R.T("stand6", {"fh2": {k: v for k, v in m._fh2.items() if k != "recent"}, "state": m._state})
    # Warteschlange > 200 Dubletten-Schluessel
    m._state["hold_until"] = None
    for blk in range(24):
        for i in range(10):
            q.put_nowait({"text": "n%d" % (blk * 10 + i), "channel": i % 8})
        try:
            m.worker()
        except StopLoop:
            pass
    R.T("stand7", {"recent_n": len(m._fh2["recent"]), "ok": m._state["sent_ok"]})
    # unerwartete Ausnahme in der Schleife
    q.put_nowait({"text": "boom", "channel": 0})
    orig = m.send_now
    m.send_now = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
    env.sleep_budget = 5
    try:
        m.worker()
    except StopLoop:
        pass
    m.send_now = orig

def s_http(R, m, env):
    iface = connected(R, m, env)
    m._inbox.append({"at": "x", "text": "t"})
    m.add_inbox("zwei", "!aa", channel=1)
    G = ["/health", "/health?x=1", "/channels", "/inbox", "/inbox?channel=0", "/inbox?ch=1", "/inbox?channel=x", "/inbox?channel=99", "/chutil", "/chutilX", "/foo", "/", "/healthz"]
    for p in G:
        R.T("GET " + p, call_http(m, "GET", p))
    m.add_inbox("hallo", "!bb", snr=1, rssi=-2, hops=1)
    m.on_receive(pk(frm="!aa", text="abc"), iface)
    m.on_receive(pk(frm="!bb", text="def", port="POSITION_APP"), iface)
    for p in ("/chutil", "/health"):
        R.T("GET2 " + p, call_http(m, "GET", p))
    env.clock += 77
    R.T("GET3 /chutil", call_http(m, "GET", "/chutil"))
    m.close_iface()
    R.T("GET4 /chutil ohne iface", call_http(m, "GET", "/chutil"))
    def post(p, body=None, headers=None):
        R.T("POST %s %s %s" % (p, body, headers), [call_http(m, "POST", p, body, headers), drain(m._send_q), m._state["queued"]])
    J = lambda o: json.dumps(o).encode()
    post("/send", J({"text": "hallo", "channel": 0})); post("/send", J({"text": "hallo"})); post("/send", J({"text": "  ", "channel": 0}))
    post("/send", J({"text": "x", "channel": 8})); post("/send", J({"text": "x", "channel": "3"})); post("/send", J({"text": "x", "channel": True}))
    post("/send", b"[1,2]"); post("/send", b"kein json"); post("/send", b""); post("/send", b"{}"); post("/send", J({"channel": 1}))
    post("/send", J({"text": 5, "channel": 1})); post("/send", J({"text": "\x07bel\x1b[0m", "channel": 1})); post("/send", J({"text": "y" * 500, "channel": 2}))
    pad = lambda n: json.dumps({"text": "p", "channel": 0, "pad": ""}).encode()[:-2] + b"x" * (n - len(json.dumps({"text": "p", "channel": 0, "pad": ""}).encode()) + 2) + b'"}'
    post("/send", pad(4096)); post("/send", pad(4097)); post("/send", pad(4095))
    post("/send", b"x" * 5000); post("/send", J({"text": "a"}), {"Content-Length": "abc"}); post("/send", J({"text": "a"}), {"Content-Length": "-4"})
    post("/send", J({"text": "a"}), {"Content-Length": "9999"}); post("/sendx", J({"text": "pfad", "channel": 0})); post("/send/", J({"text": "pfad2", "channel": 0}))
    post("/hold"); post("/resume"); post("/holdx"); post("/resumeX"); post("/nix"); post("/")
    R.T("held-nach-posts", m.is_held())
    for i in range(52):
        h, out = handler(m, "/send", json.dumps({"text": "q%d" % i, "channel": 0}).encode())
        h.do_POST()
        if h.wfile.getvalue().startswith(b'{"ok": false'):
            R.T("full", [i, h.wfile.getvalue(), out])
            break
    # Protokollzeilen
    h, _ = handler(m, "/x")
    for args in [('"%s" %s %s', "GET /health HTTP/1.1", "200", "-"), ('"%s" %s %s', "POST /send HTTP/1.1", "200", "-"), ('"%s" %s %s', "POST /hold HTTP/1.1", "200", "-"),
                 ('"%s" %s %s', "GET /x HTTP/1.1", "404", "-"), ('"%s" %s %s', "GET /inbox HTTP/1.1", "abc", "-"), ("%s", "text"), ("kein format",), ('"%s" %s %s', "POST /resume HTTP/1.1", "500", "-"), ('"%s" %s %s', "POST /resume HTTP/1.1", "200", "-"), ('"%s" %s %s', "GET /x HTTP/1.1", "301", "-"),
                 ('"%s" %s %s', "GET /x HTTP/1.1", "399", "-"), ('"%s" %s %s', "GET /x HTTP/1.1", "400", "-")]:
        try:
            h.log_message(*args)
        except Exception as e:
            R.T("logmsg-exc", repr(e))
    if has(m, "_fh2"):
        R.T("http_quiet", m._fh2["http_quiet"])

def s_main(R, m, env):
    m.main()

def s_main_fail(R, m, env):
    env.knobs["fail_connect"] = 3
    m.main()

def s_loops(R, m, env):
    # watchdog (je Bridge eigene Fassung)
    env.sleep_budget = 3
    try:
        m.watchdog()
    except StopLoop:
        R.T("watchdog-1")
    iface = connected(R, m, env)
    env.sleep_budget = 3
    try:
        m.watchdog()
    except StopLoop:
        R.T("watchdog-2-verbunden")
    m._state["connected"] = False
    env.sleep_budget = 2
    try:
        m.watchdog()
    except StopLoop:
        R.T("watchdog-3-reconnect")
    m.hold_bridge()
    env.sleep_budget = 2
    try:
        m.watchdog()
    except StopLoop:
        R.T("watchdog-4-hold")
    m._state["hold_until"] = None
    env.knobs["fail_connect"] = 2
    m._state["connected"] = False
    env.sleep_budget = 3
    try:
        m.watchdog()
    except StopLoop:
        R.T("watchdog-5-fehler")
    # chutil_worker
    env.knobs["fail_connect"] = 0
    env.sleep_budget = 2
    m.close_iface()
    try:
        m.chutil_worker()
    except StopLoop:
        R.T("chutil-ohne")
    connected(R, m, env)
    env.sleep_budget = 3
    try:
        m.chutil_worker()
    except StopLoop:
        R.T("chutil-mit")
    R.T("pick", m.mesh_chutil.pick_local_metrics(m._iface, m._my_ids))
    R.T("pick-none", m.mesh_chutil.pick_local_metrics(None, None))
    env.clock += 50
    R.T("pick-heard", m.mesh_chutil.pick_local_metrics(m._iface, set()))
    R.T("pick-fremd", m.mesh_chutil.pick_local_metrics(env.FakeIface("x"), set()))
    # Verlust-Hook
    for fn, topic in list(env.listeners):
        if topic == "meshtastic.connection.lost":
            fn(interface=m._iface); R.T("lost-" + fn.__name__, m._state)
            fn(interface=None); fn(interface=object()); fn()
            R.T("lost-2", m._state)
    R.T("listeners", [(f.__name__, t) for f, t in env.listeners])

def s_m2(R, m, env):
    """Bridge-2-Schichten: Keeper, Keepalive, Episoden, Status-Datei, Ruhezeit."""
    iface = connected(R, m, env)
    R.T("write-1", m._m2os_write(True)); env.clock += 5
    R.T("status-1", jfiles(R.sandbox))
    for kind, err, adv in [("lost", "x", 1), ("libreconnect", "y", 20), ("reconnect", None, 5), ("send_fail", "z", 100), ("connect_fail", "q", 10), ("lost", None, 30), ("reconnect", None, 3),
                           ("stale", None, 500), ("reconnect_planned", None, 1), ("lost", "a", 1), ("lost", "b", 1), ("lost", "c", 1), ("reconnect", None, 200)]:
        env.clock += adv
        m._m2os_event(kind, err)
        R.T("ev " + kind, {"eps": m._m2c["eps"], "ep_open": m._m2c["ep_open"], "short": m._m2c["short"], "ka_on": m._m2c["ka_on"]})
    R.T("counts", m._m2os_counts())
    env.clock += 10
    m._m2os_write(False); R.T("write-2", jfiles(R.sandbox))
    m._m2os_write(False); m._m2os["dirty"] = False; m._m2os_write(False)
    env.clock += 61; m._m2os_write(False)
    R.T("status-2", jfiles(R.sandbox))
    # Schreibfehler
    import os as _os
    p = m.M2OS_STATUS_FILE
    try:
        _os.makedirs(str(p) + ".tmp")
        m._m2os["dirty"] = True
        m._m2os_write(True)
    except Exception as e:
        R.T("write-fehler", type(e).__name__)
    # Keeper
    for scen in range(6):
        env.sleep_budget = 3
        if scen == 1:
            env.ifaces[-1].isConnected.clear()
        if scen == 2:
            m._m2os["last_pkt"] = env.clock - m.M2OS_STALE_RECONNECT - 5; m._m2os["connected_at"] = m._m2os["last_pkt"]
        if scen == 3:
            env.knobs["fail_connect"] = 5
            m._state["connected"] = False
        if scen == 4:
            m.hold_bridge()
        if scen == 5:
            m._state["hold_until"] = None; m._m2os["connected_at"] = 0.0
        try:
            m._m2os_keeper()
        except StopLoop:
            R.T("keeper-%d" % scen, [m._state, m._m2os["reason"]])
    env.knobs["fail_connect"] = 0
    # presend
    for scen in range(4):
        if scen == 1:
            m._m2os["last_pkt"] = env.clock - m.M2OS_PRESEND_STALE - 1; m._m2os["connected_at"] = m._m2os["last_pkt"]
        if scen == 2:
            m.close_iface()
        if scen == 3:
            m.hold_bridge()
        try:
            m._m2os_presend()
        except Exception as e:
            R.T("presend-exc", repr(e))
        R.T("presend-%d" % scen, [m._state, m._m2os["reason"]])
    m._state["hold_until"] = None
    # Keepalive
    env.sleep_budget = 2
    connected(R, m, env)
    try:
        m._m2c_keepalive()
    except StopLoop:
        pass
    env.knobs["fail_heartbeat"] = 1
    env.sleep_budget = 2
    try:
        m._m2c_keepalive()
    except StopLoop:
        pass
    m._m2c["ka_on"] = False
    env.sleep_budget = 2
    try:
        m._m2c_keepalive()
    except StopLoop:
        pass
    R.T("ka", {k: m._m2c[k] for k in ("ka_sent", "ka_fail", "ka_last")})
    # TCP-Wache
    m._m2c_install_tcp_guard()
    m._m2c_install_tcp_guard()
    import meshtastic.tcp_interface as ti
    R.T("guard", ti.TCPInterface.__name__)
    env.knobs["fail_connect"] = 1
    try:
        ti.TCPInterface(hostname="x")
    except Exception as e:
        R.T("guard-halboffen", [repr(e), m._m2c["halfopen"]])
    # Status
    R.T("status", m._m2c_status({"connected": True})); R.T("status2", m._m2c_status({"connected": False})); R.T("status3", m._m2c_status({"connected": False}))
    R.T("quiet", [m._m2c_quiet_reason({"rxTime": env.clock - 300}), m._m2c_quiet_reason({}), m._m2c_quiet_reason(None)])
    m._m2c["t0"] = env.clock - 10
    R.T("quiet-boot", m._m2c_quiet_reason(None))
    # Queue-Wrapper
    R.T("queue-class", type(m._send_q).__name__)
    m._m2c_tls.rx = {"rxTime": 0}
    m._send_q.put_nowait("verworfen"); R.T("tls-drop", [m._send_q.qsize(), m._m2c["quiet_drop"]])
    m._m2c_tls.rx = None
    m._send_q.put_nowait("ok"); R.T("tls-ok", m._send_q.qsize())
    # Bibliothek verbindet still neu
    m._m2os_wrap_lib_reconnect(m._iface)
    m._iface._reconnect(); m._iface._wantExit = True; m._iface._reconnect()
    m._m2os["closing"] = 1; m._iface._reconnect(); m._m2os["closing"] = 0
    R.T("libreconnect", m._m2os_counts())
    h = m._M2osLogHook(); import logging
    for msg in ("Reconnecting now", "nichts", "Broken pipe!", "connection reset by peer"):
        h.emit(logging.LogRecord("meshtastic", logging.WARNING, "x", 1, msg, None, None))
    R.T("loghook", m._m2os_counts())
    m._m2os_hook(); m._m2os_hook()
    m._m2os_on_lost(None)
    m._m2os_on_lost(object())
    m._m2os_on_lost(m._iface)
    R.T("on_lost", [m._state["connected"], m._m2os_counts()])

def s_many(R, m, env):
    iface = connected(R, m, env)
    for i in range(75):
        env.clock += 1
        m.on_receive(pk(frm="!%08x" % (0x100 + i), text="hallo %d" % i, port="POSITION_APP" if i % 2 else "TEXT_MESSAGE_APP"), iface)
        drain(m._send_q)
    for i in range(12):
        env.clock += 1
        m.on_receive(pk(frm="!%08x" % (0x100 + 74), text="x"), iface)
    iface.nodes = {"!n%d" % i: {"user": {"id": "!n%d" % i, "longName": "N%d" % i}, "lastHeard": env.clock - i * 10 - (0 if i % 3 else 1e12 / 1000 * 1000)} for i in range(14)}
    R.T("chutil", call_http(m, "GET", "/chutil"))
    R.T("inbox-n", [len(m._inbox), len(jfiles(R.sandbox))])
    for i in range(320):
        m.add_inbox("m%d" % i, "!aa", channel=1)
    R.T("inbox-limit", [len(m._inbox), {k: len(v) for k, v in jfiles(R.sandbox).items() if isinstance(v, list)}])
    R.T("get-inbox", [len(call_http(m, "GET", "/inbox?channel=1")[1]["messages"]), call_http(m, "GET", "/inbox?channel=1")[1]["messages"][:2]])
    R.T("get-inbox-all", len(call_http(m, "GET", "/inbox")[1]["messages"]))

def s_fh2_internals(R, m, env):
    R.T("clean", [m._fh2_clean(x) for x in (5, None, " a\tb\r\nc\x00d ", "x" * 300, "")])
    R.T("channel", [m._fh2_channel(x) for x in (None, "", True, False, 1.5, 2.0, "3", " 4 ", "x", 8, -1, 7, "7.0", [1])])
    R.T("is_reply", [m._fh2_is_reply(x) for x in (m.STATION + "\nEmpfang 1", "x", None, 5)])
    R.T("key", m._fh2_key("a", 0))
    for i in range(205):
        m._fh2_mark("k%d" % i)
    R.T("seen", [m._fh2_seen("k0"), m._fh2_seen("k204"), len(m._fh2["recent"])])
    env.clock += 119.5
    R.T("seen2a", [m._fh2_seen("k204"), len(m._fh2["recent"])])
    env.clock += 1
    R.T("seen2b", [m._fh2_seen("k204"), len(m._fh2["recent"])])
    env.clock += 100
    R.T("seen2c", [m._fh2_seen("k204"), len(m._fh2["recent"])])
    R.T("mesh_key", m._fh2_mesh_key())
    R.T("hops", [m._hops(x) for x in ({}, {"hops": 2}, {"hopStart": 3, "hopLimit": 1}, {"hopStart": 1, "hopLimit": 3}, {"hopStart": "a", "hopLimit": 1})])
    R.T("from_id", [m._from_id(x) for x in ({}, {"fromId": 5}, {"from": "12"}, {"fromId": "!ab"}, {"fromId": "zz"})])
    R.T("pkt_channel", [m.packet_channel(x) for x in ({}, {"channel": 2}, {"decoded": {"channel": 3}}, {"channel": "x"})])


def s_edges(R, m, env):
    """Grenzfaelle der verschmolzenen Funktionen (Worker, HTTP, Senden)."""
    iface = connected(R, m, env)
    q = m._send_q
    real_get = q.get
    sched = []
    def get(*a, **k):
        if q.qsize() == 0:
            raise StopLoop()
        if sched:
            env.clock += sched.pop(0)
        return real_get(*a, **k)
    q.get = get
    reply = m.STATION + "\nEmpfang 10:00:00\nAntwort 10:00:00\nSNR 5 dB"
    st = lambda: {"fh2": {k: v for k, v in m._fh2.items() if k != "recent"}, "state": dict(m._state), "ev": env.ev[-12:]}
    def run(label):
        try:
            m.worker()
        except StopLoop:
            pass
        R.T(label, st())
    # Abstand zwischen zwei Sendungen: 0 < Rest <= 1 Sekunde, Rest > 1, Rest 0
    for k, gap in enumerate((2.5, 0.2, 1.0, 3.0, 3.4, 2.0)):
        sched[:] = [0.0, gap]
        q.put_nowait({"text": "gap%da" % k, "channel": 0}); q.put_nowait({"text": "gap%db" % k, "channel": 0})
        run("gap%d" % k)
    # Verbindung steht nicht, Aufbau scheitert zweimal, Text ist eine Antwort (ok bleibt False)
    m.close_iface()
    env.knobs["fail_connect"] = 9
    q.put_nowait({"text": reply + "X", "channel": 0})
    run("reply-ohne-verbindung")
    env.knobs["fail_connect"] = 0
    # Senden schlaegt bei einer Antwort fehl: kein Antwortzaehler, aber Dublettenmarke
    connected(R, m, env)
    env.knobs["fail_send"] = 1
    q.put_nowait({"text": reply + "Y", "channel": 0})
    run("reply-sendefehler")
    env.knobs["fail_send"] = 1
    q.put_nowait({"text": reply + "Y", "channel": 0})
    run("reply-nochmal")
    q.get = real_get
    # lange Texte und lange Fehlertexte
    for n in (219, 220, 221, 300):
        m.send_now("L" * n + "ü", 0) if hasattr(m, "send_now") else None
        R.T("send-len%d" % n, {"state": {k: m._state[k] for k in ("last_text", "last_error", "sent_ok", "sent_fail")}, "ev": env.ev[-2:]})
    for n in (79, 80, 81, 82):
        m.send_now("K" * n, 0)
        R.T("last-text%d" % n, m._state["last_text"])
    env.knobs["err_text"] = "E" * 200
    env.knobs["fail_send"] = 1
    R.T("send-fail-long", m.send_now("lang", 0))
    R.T("err-len", [len(m._state["last_error"]), m._state["last_error"][-3:]])
    env.knobs["err_text"] = None
    R.T("send-defaults", [m.send_now("standard"), m.send_now("   "), m.send_now(""), m.send_now(None)])
    R.T("send-defaults-ev", env.ev[-6:])
    # HTTP-Grenzfaelle
    m.hold_bridge()
    R.T("GET health hold", call_http(m, "GET", "/health"))
    m._state["hold_until"] = env.clock + 0.5
    R.T("GET health hold 0.5", call_http(m, "GET", "/health"))
    m._state["hold_until"] = None
    m.add_inbox("Grüße \u00fcber ß", "!aa", channel=2)
    R.T("GET inbox ue", [call_http(m, "GET", "/inbox?channel=2"), call_http(m, "GET", "/inbox")])
    R.T("health ue", call_http(m, "GET", "/health")[1].get("last_rx"))
    orig = m.mesh_chutil.hist_payload
    m.mesh_chutil.hist_payload = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("kaputt \u00fc"))
    R.T("GET chutil 500", call_http(m, "GET", "/chutil"))
    m.mesh_chutil.hist_payload = orig
    # Warteschlange voll: Status und Text
    while True:
        try:
            q.put_nowait("fuell")
        except queue.Full:
            break
    h, out = handler(m, "/send", json.dumps({"text": "voll", "channel": 0}).encode())
    h.do_POST()
    R.T("POST voll", [out, h.wfile.getvalue()])
    for body in (b'{"text": "ok4096"' + b" " * (4096 - 17 - 1) + b"}", b'{"text": "ok4097"' + b" " * (4097 - 17 - 1) + b"}"):
        drain(q)
        h, out = handler(m, "/send", body, {"Content-Length": str(len(body))})
        h.do_POST()
        R.T("POST len%d" % len(body), [out, h.wfile.getvalue()])
    # Protokollzeilen mit 1, 2, 3, 4 Argumenten
    h, _ = handler(m, "/x")
    for args in [("a",), ("%s", "x"), ("%s %s", "GET /x", "200"), ('"%s" %s %s', "GET /x", "200", "-"), ('"%s" %s %s %s', "GET /x", "200", "-", "z"), ("%s %s", "POST /hold", "200"), ("%s %s", "POST /hold", "404")]:
        try:
            h.log_message(*args)
        except Exception as e:
            R.T("logmsg-exc", repr(e))
    R.T("logmsg-quiet", m._fh2["http_quiet"] if hasattr(m, "_fh2") else None)

def s_rx_edges(R, m, env):
    iface = connected(R, m, env)
    env.clock += 400
    other = object()
    for i, (p, ifc) in enumerate([(pk(text="ping"), None), (pk(text="ping"), other), (pk(text="ping"), iface), (pk(text="knoten.eu ping"), iface),
                                  (pk(text="ping", frm="!aa"), None), (pk(text="x", port=None), iface), (pk(text="", port="TEXT_MESSAGE_APP"), iface),
                                  (pk(text="ping", frm="!nichtda", ch=0), None)]):
        env.clock += 1
        m.on_receive(p, ifc)
        R.T("rxe%d" % i, {"q": drain(m._send_q), "last": m._state.get("last_rx"), "pkt": (m._m2os["last_pkt"] if hasattr(m, "_m2os") else None), "m2f": (dict(m._m2f) if hasattr(m, "_m2f") else None),
                          "m1f": (m._m1f["n"] if hasattr(m, "_m1f") else None)})
    R.T("inbox", [list(m._inbox)[-3:], {k: v for k, v in jfiles(R.sandbox).items()}])

def s_rx_names(R, m, env):
    iface = connected(R, m, env)
    iface.nodes["!dd"] = {"user": {"id": "!dd", "longName": "Mesh Hessen Relais", "shortName": "MH"}, "lastHeard": env.clock}
    iface.nodes["!ee"] = {"user": {"id": "!ee", "longName": "knoten.eu Test", "shortName": "KE"}, "lastHeard": env.clock}
    env.clock += 400
    for i, (frm, txt, ch) in enumerate([("!dd", "hallo", 0), ("!ee", "hallo", 0), ("!dd", "hallo", 1), ("!ff", "mesh hessen", 0), ("!ff", "hallo", 0), ("!dd", "hallo", None)]):
        m.on_receive(pk(frm=frm, text=txt, ch=ch), iface)
        R.T("name%d" % i, [list(m._inbox)[-1], drain(m._send_q), jfiles(R.sandbox)])

def s_m2_edges(R, m, env):
    iface = connected(R, m, env)
    R.T("conn+5.0", [m.connect().idx, env.clock])
    c0 = m._m2os["connected_at"]
    for dt in (4.9, 0.1, 0.0):
        env.clock = c0 + 5.0 - 0.0 + dt - 4.9 if dt == 4.9 else env.clock
    env.clock = c0 + 5.0
    R.T("connect-genau5", m.connect().idx)
    env.clock = c0 + 4.99
    R.T("connect-4.99", m.connect().idx)
    # Status-Datei: wann wird geschrieben
    f = m.M2OS_STATUS_FILE
    def written(label, lw=None, **kw):
        try:
            f.unlink()
        except Exception:
            pass
        if lw is not None:
            m._m2os["last_write"] = env.clock - lw
        m._m2os_write(**kw)
        R.T(label, [f.exists(), f.read_text(encoding="utf-8") if f.exists() else None])
    m._m2os["dirty"] = False; m._m2os["last_write"] = env.clock - 10
    written("w-frisch-kein-dirty")
    m._m2os["dirty"] = False; m._m2os["last_write"] = env.clock - 10
    written("w-force", force=True)
    R.T("w-dirty-danach", m._m2os["dirty"])
    m._m2os["dirty"] = True; m._m2os["last_write"] = env.clock - 10
    written("w-dirty")
    m._m2os["dirty"] = False; m._m2os["last_write"] = env.clock - 60.0
    written("w-genau60")
    m._m2os["dirty"] = False; m._m2os["last_write"] = env.clock - 59.0
    written("w-59")
    m._m2os["dirty"] = False; m._m2os["last_write"] = env.clock - 60.5
    written("w-60.5")
    m._m2os["dirty"] = False; m._m2os["last_write"] = env.clock - 60.9
    written("w-60.9")
    R.T("w-default-force", m._m2os_write.__defaults__)
    oh = m.is_held
    m.is_held = lambda: (_ for _ in ()).throw(RuntimeError("x"))
    m._m2os["dirty"] = True; written("w-held-fehler")
    m.is_held = oh
    m.hold_bridge(); m._m2os["dirty"] = True; written("w-held"); m._state["hold_until"] = None
    m._m2os_event("lost", "Fehler \u00fc " + "E" * 200)
    R.T("event-err", [len(m._m2os["last_err"]), m._m2os["last_err"][-3:], m._m2os["last_err_at"]])
    written("w-ue", lw=100, force=True)
    written("w-ue-gleiche-zeit", lw=0, force=True)
    iface.isConnected.clear(); m._state["connected"] = True
    written("w-tot", lw=100, force=True)
    iface.isConnected.set(); m._state["connected"] = False
    written("w-state-nicht-connected", lw=100, force=True)
    m._state["connected"] = True
    m.close_iface(); m._state["connected"] = True
    written("w-ohne-iface", lw=100, force=True)
    m._state["connected"] = False
    written("w-ohne-iface2", lw=100, force=True)
    # Pong: Abkuehlzeit genau erreicht / nicht erreicht
    m.M2OS_ADD_PONG = True
    connected(R, m, env)
    env.clock += 400
    m.on_receive(pk(text="ping", ch=0), m._iface)
    t0 = m._m2os["pong_last"].get("!1234abcd")
    drain(m._send_q)
    for dt in (m.M2OS_PONG_COOLDOWN - 0.5, m.M2OS_PONG_COOLDOWN, m.M2OS_PONG_COOLDOWN + 0.5):
        env.clock = (t0 or env.clock) + dt
        m._m2os["pong_last"]["!1234abcd"] = t0
        m.on_receive(pk(text="ping", ch=0), m._iface)
        R.T("pong-dt%s" % dt, [m._m2os["pong_last"].get("!1234abcd"), drain(m._send_q)])
    R.T("pong-neu", [m._m2os["pong_last"].pop("!1234abcd", None), m.on_receive(pk(text="ping", ch=0), m._iface), drain(m._send_q)])

SCENARIOS = [s_import, s_conn, s_rx, s_worker, s_http, s_main, s_main_fail, s_loops, s_many, s_fh2_internals, s_edges, s_rx_edges, s_rx_names]
SCENARIOS_M2 = [s_m2, s_m2_edges]
BA_EMBED_7_EOF
EXPECT_8="538206650521f46fa4620d7ff3bc1cb7e795daac0fb7a262f68b5c96998809e9"
mkdir -p "$W/test"
cat > "$W/test/equiv.py" << 'BA_EMBED_8_EOF'
#!/usr/bin/env python3
"""Aequivalenztest alt gegen neu: python3 equiv.py ALT.py NEU.py [m2]  (Exit 0 = identisch)"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridgeharness import Run, compare
import scenarios as S

def run_all(path, m2, **kw):
    res = {}
    for sc in S.SCENARIOS + (S.SCENARIOS_M2 if m2 else []):
        res[sc.__name__] = Run(path, sc, **kw).go()
    return res

def main():
    old, new = sys.argv[1], sys.argv[2]
    m2 = len(sys.argv) > 3 and sys.argv[3] == "m2"
    a, b = run_all(old, m2), run_all(new, m2)
    bad = 0; n = 0
    for k in a:
        d = compare(a[k], b[k], k)
        n += len(a[k])
        bad += len(d)
        for x in d[:6]:
            print(x)
    print("Aequivalenz: %d Szenarien, %d Vergleichspunkte, %d Abweichungen" % (len(a), n, bad))
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
BA_EMBED_8_EOF
EXPECT_9="2486466cc1190dbd8694940d90c5128829dcb9946aad2a3974dd5d599fd29ff0"
mkdir -p "$W/test"
cat > "$W/test/equiv_prio.py" << 'BA_EMBED_9_EOF'
#!/usr/bin/env python3
"""Regressionstest bridgePrio: alter Stand (bridgeDedup) gegen neuen Stand (Prioritaetswarteschlange).
python3 equiv_prio.py ALT NEU [m2]
Mit SEND_GAP = 0 in beiden (der Sendeabstand wird in test_prio.py per Zeitsimulation geprueft) muss jede Abweichung erwartet und begruendet sein:
 - /health hat drei zusaetzliche Schluessel (q_alarm, q_routine, prio), sie werden vor dem Vergleich entfernt;
 - volle Warteschlange: neu hoechstens 10 Routine-Nachrichten (statt 50) -> die Eintraege der Voll-Pruefungen duerfen abweichen (in test_prio.py gegengeprueft)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridgeharness import compare
import equiv

EXPECTED = {("s_rx", "full-at"), ("s_http", "full")}
NEWKEYS = {"q_alarm", "q_routine", "prio"}

def zero_gap(R, m):
    m.SEND_GAP = 0.0

def strip(v):
    if isinstance(v, dict):
        return {k: strip(x) for k, x in v.items() if k not in NEWKEYS}
    if isinstance(v, list):
        return [strip(x) for x in v]
    return v

FILL = ("s_rx", "s_http")   # Szenarien, die die Warteschlange fuellen: Endstand q/queued haengt von der Routine-Obergrenze ab

def fix_len(rec, sc=""):
    # Content-Length der /health-Antwort haengt von den neuen Schluesseln ab
    out = []
    for lab, val in rec:
        val = strip(val)
        if lab == "snap" and sc in FILL and isinstance(val, dict):
            val = dict(val, q="<n>", state=dict(val.get("state", {}), queued="<n>"))
        out.append([lab, _nolen(val)])
    return out

def _nolen(v):
    if isinstance(v, list):
        if len(v) == 3 and v[0] == "hdr" and v[1] == "Content-Length":
            return ["hdr", "Content-Length", "<n>"]
        return [_nolen(x) for x in v]
    if isinstance(v, dict):
        return {k: _nolen(x) for k, x in v.items()}
    return v

def main():
    old, new = sys.argv[1], sys.argv[2]
    m2 = "m2" in sys.argv[3:]
    a, b = equiv.run_all(old, m2, setup=zero_gap), equiv.run_all(new, m2, setup=zero_gap)
    bad = 0; n = 0; exp = 0
    for k in a:
        ra, rb = fix_len(a[k], k), fix_len(b[k], k)
        n += len(ra)
        for i, (x, y) in enumerate(zip(ra, rb)):
            if x != y:
                if (k, x[0]) in EXPECTED:
                    exp += 1
                    continue
                bad += 1
                if bad <= 6:
                    print("%s: Eintrag %d (%s) weicht ab:\n   alt: %s\n   neu: %s" % (k, i, x[0], str(x[1])[:500], str(y[1])[:500]))
        if len(ra) != len(rb):
            bad += 1; print("%s: Protokolllaenge %d != %d" % (k, len(ra), len(rb)))
    print("Regression alt/neu (SEND_GAP 0): %d Szenarien, %d Vergleichspunkte, %d erwartete Abweichungen (Voll-Pruefungen), %d unerwartete" % (len(a), n, exp, bad))
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
BA_EMBED_9_EOF
EXPECT_10="289a45aff9581c7440c1df5ea2e54df1cc204899b503af508d6afc4440cb4949"
mkdir -p "$W/test"
cat > "$W/test/test_prio.py" << 'BA_EMBED_10_EOF'
#!/usr/bin/env python3
"""Pruefungen fuer bridgePrio (PERF-05) mit Fakes und Zeitsimulation. Nichts wird gesendet (Fake-TCPInterface, Socket gesperrt, Fake-Uhr).
python3 test_prio.py NEU [m2] [ALT]     - ALT (optional): alter Stand fuer den Zeitvergleich (gleiche Prioritaet -> gleiche Sendezeiten)
Exit 0 = alle Pruefungen bestanden."""
import json, os, queue, random, sys, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridgeharness import Run, StopLoop, handler, call_http, drain
import scenarios as S

REAL_THREAD = threading.Thread     # vor dem Patchen der Harness sichern (echte Threads fuer den Stresstest)
RES = []

def ck(name, cond, detail=""):
    RES.append((name, bool(cond), str(detail)[:300]))

def put(m, item):
    try:
        m._send_q.put_nowait(item)
        return True
    except queue.Full:
        return False

def drive(m, env, arrivals):
    """Worker mit Ankunftszeiten: arrivals = [(t_abs, item)]. get() liefert faellige Eintraege, wartet sonst bis zur naechsten Ankunft (Fake-Uhr)."""
    q = m._send_q
    pend = sorted(arrivals, key=lambda a: a[0])
    real_get = q.get
    refused = []
    def get(*a, **k):
        while True:
            while pend and pend[0][0] <= env.clock:
                t, it = pend.pop(0)
                if not put(m, it):
                    refused.append(it)
            if q.qsize():
                return real_get(*a, **k)
            if not pend:
                raise StopLoop()
            env.clock = max(env.clock, pend[0][0])
    q.get = get
    try:
        m.worker()
    except StopLoop:
        pass
    q.get = real_get
    return refused

def texts(env):
    return [t for _c, t, _ch in env.sendlog]

def gaps(env):
    ts = [c for c, _t, _ch in env.sendlog]
    return [round(b - a, 6) for a, b in zip(ts, ts[1:])]

def setup_conn(R, m, env):
    S.connected(R, m, env)
    env.clock += 400      # Start-Ruhezeit (mesh2Calm) vorbei

def sc_unit(R, m, env):
    P = m._prio_of
    table = [("ALARM ASA DE: Sturm", 0), ("ALARM BR24: x", 0), ("ALARM NINA: y", 0), ("ALARM: z", 0), ("NINA: Nuernberg: Gefahrstoff", 0), ("  NINA: Entwarnung - keine Warnung mehr", 0),
             ("NINA Details: a || b", 1), ("Station Kalchreuth\nEmpfang 10:00:00", 5), ("alarm klein", 5), ("ALARMIERUNG", 5), ("NINAS: x", 5), ("Test hallo", 5),
             ("TEST Uebung 12 keine echte Warnung", 9), ("test x keine echte Warnung", 9), ("TEST ohne den Zusatz", 5), (None, 5), ("", 5), (5, 5),
             ({"text": "x"}, 5), ({"text": "ALARM ASA DE: x"}, 0), ({"text": "x", "prio": 0}, 0), ({"text": "ALARM x", "prio": 9}, 9), ({"text": "x", "prio": 3}, 3),
             ({"text": "x", "prio": True}, 5), ({"text": "x", "prio": 10}, 5), ({"text": "x", "prio": -1}, 5), ({"text": "x", "prio": "0"}, 5), ({"text": "ALARM x", "prio": 2.0}, 0),
             ({"text": "x", "prio": None}, 5), ({"prio": 4}, 4), ({}, 5)]
    for item, want in table:
        ck("prio_of %r" % (item,), P(item) == want, P(item))
    ck("Konstanten", (m.PRIO_ALARM, m.PRIO_DETAIL, m.PRIO_ROUTINE, m.PRIO_TEST, m.ROUTINE_MAX, m._send_q.maxsize, m.SEND_GAP) == (0, 1, 5, 9, 10, 50, 3.0), (m.PRIO_ALARM, m.PRIO_ROUTINE, m.PRIO_TEST, m.ROUTINE_MAX, m._send_q.maxsize, m.SEND_GAP))
    ck("FH2_DUP_SEC unveraendert", m.FH2_DUP_SEC == 120)

def sc_alarm_behind_50(R, m, env):
    setup_conn(R, m, env)
    acc = [put(m, {"text": "routine%d" % i, "channel": 0}) for i in range(50)]
    ck("50 Routine: genau 10 angenommen", sum(acc) == 10 and acc[:10] == [True] * 10, sum(acc))
    ck("Alarm trotz voller Routine-Grenze angenommen", put(m, {"text": "ALARM ASA DE: Sturmwarnung", "channel": 0}))
    ck("queued gesamt 11", m._send_q.qsize() == 11, m._send_q.qsize())
    drive(m, env, [])
    tx = texts(env)
    ck("Alarm wird als Naechstes gesendet", tx[:1] == ["ALARM ASA DE: Sturmwarnung"], tx[:3])
    ck("danach Routine in Eingangsreihenfolge", tx[1:] == ["routine%d" % i for i in range(10)], tx)
    g = gaps(env)
    ck("Sendeabstand >= SEND_GAP zwischen allen Nachrichten", g and min(g) >= m.SEND_GAP, g)
    ck("keine Netzversuche", not any(e[0] == "SOCKET-VERSUCH" for e in env.ev))
    ck("nur Fake-Sender benutzt", all(e[0] != "SOCKET-VERSUCH" for e in env.ev) and len(env.sendlog) == 11, len(env.sendlog))

def sc_inflight(R, m, env):
    setup_conn(R, m, env)
    LG = []
    m.log = lambda *a: LG.append(" ".join(str(x) for x in a))
    t0 = env.clock
    arr = [(t0, {"text": "A", "channel": 0})] + [(t0 + 0.1, {"text": "R%d" % i, "channel": 0}) for i in range(9)] + [(t0 + 1.0, {"text": "ALARM NINA: Gefahr", "channel": 0})]
    drive(m, env, arr)
    tx = texts(env)
    ck("Alarm waehrend der Sendepause: kommt vor den wartenden Routine-Nachrichten", tx[:3] == ["A", "ALARM NINA: Gefahr", "R0"], tx[:4])
    ck("Rest in Reihenfolge", tx[2:] == ["R%d" % i for i in range(9)], tx)
    g = gaps(env)
    ck("Abstand weiter >= SEND_GAP", min(g) >= m.SEND_GAP, g)
    ck("Alarm ueberholt (Zaehler)", m._pq["overtake"] == 1 and m._pq["alarm"] == 1, m._pq)
    ck("Log nennt die Zahl der ueberholten Nachrichten (9)", any("ueberholt 9 wartende" in l for l in LG), [l for l in LG if "bridgePrio" in l])

def sc_overtake_count(R, m, env):
    setup_conn(R, m, env)
    LG = []
    m.log = lambda *a: LG.append(" ".join(str(x) for x in a))
    put(m, "ALARM erster"); put(m, "r1"); put(m, "r2")
    put(m, "ALARM zweiter")      # ueberholt nur die zwei Routine-Nachrichten, nicht den ersten Alarm
    ck("zweiter Alarm ueberholt genau 2 (Alarme zaehlen nicht)", any("ueberholt 2 wartende" in l for l in LG) and m._pq["overtake"] == 1, LG)
    put(m, "ALARM dritter")
    ck("dritter Alarm: weiter 2 ueberholt", any("ueberholt 2 wartende" in l for l in LG[1:]) and m._pq["overtake"] == 2 and m._pq["alarm"] == 3, (LG, m._pq))
    q = m._SendQueue()    # unbegrenzt (maxsize 0) und maxsize 1
    ok = True
    for i in range(200):
        try: q.put_nowait("r%d" % i if i < 10 else {"text": "p", "prio": 3})
        except queue.Full: ok = False
    ck("unbegrenzte Queue (maxsize 0) nimmt 10 Routine + 190 weitere", ok and q.qsize() == 200, q.qsize())
    q1 = m._SendQueue(maxsize=1)
    q1.put_nowait("routine")
    try: q1.put_nowait("r2"); full = False
    except queue.Full: full = True
    ck("maxsize 1: Routine bei voller Queue abgelehnt", full)
    q1.put_nowait("ALARM x")
    ck("maxsize 1: Alarm verdraengt Routine", q1.qsize() == 1 and q1.get_nowait() == "ALARM x" and m._pq["displaced"] == 1, m._pq)
    ck("Eintraege tragen eine Folgenummer ab 1 (Heap-Eintrag (prio, seq, item))", (lambda qq: (qq.put_nowait("a"), qq.queue[0][1])[1])(m._SendQueue()) == 1)

def sc_pace_edge(R, m, env):
    setup_conn(R, m, env)
    t0 = env.clock
    drive(m, env, [(t0, {"text": "e1", "channel": 0}), (t0 + 0.4 + 2.6 - 0.5 + 0.0, {"text": "e2", "channel": 0})])
    g = gaps(env)
    ck("kurze Restwartezeit (<1 s) wird eingehalten", g and min(g) >= m.SEND_GAP, g)
def sc_order(R, m, env):
    setup_conn(R, m, env)
    items = ["r1", "ALARM a1", "r2", {"text": "d1 NINA Details: x"}, "NINA: n1", "ALARM a2", {"text": "p3", "prio": 3}, "TEST x keine echte Warnung", "r3", {"text": "NINA Details: d2"}]
    for it in items:
        put(m, it if isinstance(it, dict) else {"text": it, "channel": 0})
    drive(m, env, [])
    want = ["ALARM a1", "NINA: n1", "ALARM a2", "NINA Details: d2", "p3", "r1", "r2", "d1 NINA Details: x", "r3", "TEST x keine echte Warnung"]
    ck("Reihenfolge: Alarm (FIFO), Details, Prio 3, Routine (FIFO), Test zuletzt", texts(env) == want, texts(env))

def sc_cap(R, m, env):
    setup_conn(R, m, env)
    q = m._send_q
    ck("zehn Routine angenommen", all(put(m, "r%d" % i) for i in range(10)))
    ck("elfte Routine abgelehnt (Full)", not put(m, "r10"))
    ck("Test-Eintrag zaehlt als Routine (abgelehnt)", not put(m, {"text": "TEST x keine echte Warnung"}))
    ck("Zaehler routine_full", m._pq["routine_full"] == 2, m._pq)
    ck("Prio 3 zaehlt nicht zur Grenze", put(m, {"text": "p3", "prio": 3}))
    ck("Prio 4 zaehlt nicht zur Grenze", put(m, {"text": "p4", "prio": 4}))
    ck("Alarm angenommen", put(m, "ALARM x"))
    ck("counts", q.counts() == (3, 10), q.counts())
    drive(m, env, [])
    ck("nach dem Leeren wieder Platz fuer Routine", put(m, "r-neu") and q.counts() == (0, 1), q.counts())
    q.get_nowait(); q.task_done()
    ck("Zaehler stimmt nach get", q.counts() == (0, 0) and q._nroutine == 0, q.counts())

def sc_full(R, m, env):
    q = m._send_q
    ck("50 Eintraege Prio 3 angenommen", all(put(m, {"text": "p%d" % i, "prio": 3}) for i in range(50)) and q.qsize() == 50)
    ck("51. Eintrag Prio 3 abgelehnt", not put(m, {"text": "p50", "prio": 3}))
    ck("Routine bei voller Queue abgelehnt", not put(m, "routine"))
    ck("Alarm bei voller Queue angenommen (verdraengt den juengsten der niedrigsten Prioritaet)", put(m, "ALARM voll") and q.qsize() == 50 and m._pq["displaced"] == 1, m._pq)
    got = drain(q)
    names = [x["text"] if isinstance(x, dict) else x for x in got]
    ck("Alarm zuerst, p49 verdraengt, p0..p48 in Reihenfolge", names == ["ALARM voll"] + ["p%d" % i for i in range(49)], names[:3] + names[-2:])
    # gemischt: 10 Routine + 40 Prio 3, Alarm verdraengt eine Routine-Nachricht (niedrigste Prioritaet, juengste)
    m._pq["displaced"] = 0
    for i in range(10):
        put(m, "r%d" % i)
    for i in range(40):
        put(m, {"text": "q%d" % i, "prio": 3})
    ck("gemischt voll", m._send_q.qsize() == 50)
    ck("Alarm verdraengt juengste Routine", put(m, "ALARM zwei") and m._pq["displaced"] == 1 and m._send_q.counts() == (41, 9), (m._pq, m._send_q.counts()))
    got = [x["text"] if isinstance(x, dict) else x for x in drain(m._send_q)]
    ck("r9 fehlt, r0..r8 vorhanden", "r9" not in got and all(("r%d" % i) in got for i in range(9)), got[-10:])
    ck("Routine-Zaehler nach Verdraengen stimmt", m._send_q._nroutine == 0)
    # nur Alarme: 51. Alarm wird abgelehnt
    for i in range(50):
        put(m, "ALARM %d" % i)
    ck("51. Alarm bei 50 Alarmen abgelehnt", not put(m, "ALARM 50"))
    drain(m._send_q)

def sc_http(R, m, env):
    setup_conn(R, m, env)
    J = lambda o: json.dumps(o).encode()
    def post(o):
        h, out = handler(m, "/send", J(o))
        h.do_POST()
        return out[0][1], json.loads(h.wfile.getvalue())
    ck("POST ohne prio wie bisher", post({"text": "hallo", "channel": 0})[0] == 200)
    ck("POST prio 0", post({"text": "x", "channel": 0, "prio": 0})[0] == 200)
    for bad in (10, -1, "0", True, 1.5, [0], {}):
        c, b = post({"text": "y", "channel": 0, "prio": bad})
        ck("POST prio ungueltig %r -> 400" % (bad,), c == 400 and b.get("ok") is False, (c, b))
    ck("ungueltiger prio wurde nicht eingereiht", m._send_q.qsize() == 2, m._send_q.qsize())
    ck("bad-Zaehler", m._fh2["bad"] == 7, m._fh2["bad"])
    for i in range(9):
        post({"text": "r%d" % i, "channel": 0})
    c, b = post({"text": "r-elf", "channel": 0})
    ck("11. Routine per HTTP -> 429 queue full", c == 429 and b == {"ok": False, "error": "queue full"}, (c, b))
    c, b = post({"text": "ALARM ASA DE: x", "channel": 0})
    ck("Alarm per HTTP trotz Routine-Grenze -> 200", c == 200 and b["ok"] is True, (c, b))
    c, b = post({"text": "ALARM ASA DE: y", "channel": 0, "prio": 0})
    h = call_http(m, "GET", "/health")[1]
    ck("/health: q_alarm, q_routine, queued", h.get("q_alarm") == 3 and h.get("q_routine") == 10 and h.get("queued") == 13 and "prio" in h, {k: h.get(k) for k in ("q_alarm", "q_routine", "queued", "prio")})
    ck("/health: Zaehler", h["prio"]["alarm"] == 3 and h["prio"]["routine_full"] >= 1, h["prio"])
    drain(m._send_q)
    post({"text": "Gr\u00fc\u00dfe \u00e4", "channel": 0})
    drive(m, env, [])
    hh, _o = handler(m, "/health"); hh.do_GET()
    ck("/health: Umlaute als UTF-8 (nicht \\u-escaped)", "Gr\u00fc\u00dfe \u00e4".encode("utf-8") in hh.wfile.getvalue(), hh.wfile.getvalue()[:200])
    ck("alle bisherigen /health-Schluessel bleiben", all(k in h for k in ("ok", "connected", "queued", "held", "hold_left", "inbox", "host", "sent_ok", "sent_fail", "last_error")))

def sc_pacing_dedup(R, m, env):
    setup_conn(R, m, env)
    t0 = env.clock
    arr = [(t0, {"text": "ALARM ASA DE: Eins", "channel": 0}), (t0 + 1, {"text": "ALARM ASA DE: Eins", "channel": 0}), (t0 + 2, {"text": "ALARM NINA: Zwei", "channel": 0}),
           (t0 + 3, {"text": "routine", "channel": 0}), (t0 + 200, {"text": "ALARM ASA DE: Eins", "channel": 0})]
    drive(m, env, arr)
    ck("Doppelsendeschutz: gleiche Nachricht < 120 s einmal, nach 120 s wieder", texts(env) == ["ALARM ASA DE: Eins", "ALARM NINA: Zwei", "routine", "ALARM ASA DE: Eins"], texts(env))
    ck("dup-Zaehler 1", m._fh2["dup"] == 1, m._fh2["dup"])
    ck("Abstand >= SEND_GAP", min(gaps(env)) >= m.SEND_GAP, gaps(env))

def sc_hold(R, m, env):
    setup_conn(R, m, env)
    put(m, "ALARM im Hold")
    m.hold_bridge()
    drive(m, env, [])
    ck("Im Hold wird auch ein Alarm nicht gesendet (wie bisher fuer alle Nachrichten)", texts(env) == [], texts(env))

def sc_quiet(R, m, env):
    iface = S.connected(R, m, env)
    q = m._send_q
    m.on_receive(S.pk(text="ping"), iface)
    ck("Ruhezeit nach dem Start: automatische Antwort verworfen (mesh2Calm unveraendert)", q.qsize() == 0 and m._m2c["quiet_drop"] == 1, (q.qsize(), m._m2c["quiet_drop"]))
    env.clock += 400
    m.on_receive(S.pk(text="ping"), iface)
    items = drain(q)
    ck("danach Pong-Antwort als Routine eingereiht", len(items) == 1 and m._prio_of(items[0]) == 5, items)

def sc_stress(R, m, env):
    """Echte Threads: Hersteller/Verbraucher auf der echten Queue-Klasse (ohne Fake-Uhr)."""
    q = m._SendQueue(maxsize=50) if not hasattr(m, "_M2cQueue") else m._SendQueue(maxsize=50)
    N, P = 1500, 6
    errs = []; delivered = []; stop = []
    acc = [[] for _ in range(P)]
    def producer(pid):
        rnd = random.Random(pid)
        for i in range(N):
            pr = rnd.choice((None, 0, 1, 3, 5, 9))
            it = {"text": "t", "id": (pid, i)}
            if pr is not None:
                it["prio"] = pr
            try:
                q.put_nowait(it)
                acc[pid].append((i, m._prio_of(it)))
            except queue.Full:
                pass
            except Exception as e:
                errs.append(repr(e))
    def consumer():
        while True:
            try:
                it = q.get(timeout=0.3)
            except queue.Empty:
                if stop:
                    return
                continue
            delivered.append(it["id"]); q.task_done()
    cons = REAL_THREAD(target=consumer); cons.start()
    ths = [REAL_THREAD(target=producer, args=(p,)) for p in range(P)]
    for t in ths: t.start()
    for t in ths: t.join()
    stop.append(1)
    cons.join(10)
    ck("Stresstest: keine Ausnahme, Verbraucher beendet", not errs and not cons.is_alive(), errs[:2])
    want = sorted(id_ for p in range(P) for id_ in [(p, i) for i, _pr in acc[p]])
    ck("Stresstest: jede angenommene Nachricht genau einmal geliefert (Verdraengte ausgenommen)", len(delivered) == len(set(delivered)) and set(delivered) <= set(want) and len(delivered) + m._pq["displaced"] >= len(want) - 0, (len(delivered), len(want), m._pq["displaced"]))
    ck("Stresstest: Zaehler leer/konsistent", q._nroutine == 0 and q.qsize() == 0 and q.unfinished_tasks == 0, (q._nroutine, q.qsize(), q.unfinished_tasks))
    for p in range(P):   # je Hersteller und Prioritaet bleibt die Reihenfolge erhalten
        pr_of = dict(acc[p])
        last = {}
        ok = True
        for (pp, i) in delivered:
            if pp != p: continue
            k = pr_of.get(i)
            if k in last and i < last[k]:
                ok = False
            last[k] = i
        ck("Stresstest: FIFO je Prioritaet (Hersteller %d)" % p, ok)

def sc_tsim(R, m, env):
    """Zeitsimulation mit gleicher Prioritaet: die Sendezeiten muessen exakt denen des alten Stands entsprechen (FIFO + Abstand)."""
    setup_conn(R, m, env)
    rnd = random.Random(7)
    t = env.clock; arr = []
    for i in range(40):
        t += rnd.choice((0.0, 0.2, 1.0, 2.9, 3.0, 3.1, 3.5, 6.0, 9.0))
        arr.append((t, {"text": "msg%d" % i, "channel": i % 3}))
    drive(m, env, arr)
    R.T("sendlog", [(round(c - 1_800_000_000.0, 3), tx, ch) for c, tx, ch in env.sendlog])

SC1 = [sc_unit, sc_alarm_behind_50, sc_inflight, sc_overtake_count, sc_pace_edge, sc_order, sc_cap, sc_full, sc_http, sc_pacing_dedup, sc_hold, sc_stress]
SC2 = [sc_quiet]

def main():
    new = sys.argv[1]
    m2 = "m2" in sys.argv[2:]
    old = next((a for a in sys.argv[2:] if a.endswith(".py")), None)
    for sc in SC1 + (SC2 if m2 else []):
        Run(new, sc).go()
    if old:
        a = Run(old, sc_tsim).go(); b = Run(new, sc_tsim).go()
        la = next(v for k, v in a if k == "sendlog"); lb = next(v for k, v in b if k == "sendlog")
        ck("Zeitsimulation alt/neu: %d Sendungen, Sendezeiten und Reihenfolge identisch" % len(lb), la == lb and len(lb) > 30, (len(la), len(lb), [x for x, y in zip(la, lb) if x != y][:2]))
    bad = [r for r in RES if not r[1]]
    for n, _ok, d in bad:
        print("FEHLER:", n, "|", d)
    print("Prio-Tests: %d Pruefungen, %d Fehler" % (len(RES), len(bad)))
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
BA_EMBED_10_EOF
EMBED_CHECK=("EXPECT_1:new/mesh_bridge.py" "EXPECT_2:base/mesh_bridge.py" "EXPECT_3:new/mesh_bridge_bayern.py" "EXPECT_4:base/mesh_bridge_bayern.py" "EXPECT_5:guardbridge.py" "EXPECT_6:test/bridgeharness.py" "EXPECT_7:test/scenarios.py" "EXPECT_8:test/equiv.py" "EXPECT_9:test/equiv_prio.py" "EXPECT_10:test/test_prio.py")
SELFTESTS=('regress-mesh1|equiv_prio.py "$W/base/mesh_bridge.py" "$W/new/mesh_bridge.py"' 'regress-mesh2|equiv_prio.py "$W/base/mesh_bridge_bayern.py" "$W/new/mesh_bridge_bayern.py" m2' 'prio-mesh1|test_prio.py "$W/new/mesh_bridge.py" "$W/base/mesh_bridge.py"' 'prio-mesh2|test_prio.py "$W/new/mesh_bridge_bayern.py" m2 "$W/base/mesh_bridge_bayern.py"')
# ---------- 0) Voraussetzungen ----------
for c in python3 curl sha256sum diff sudo systemctl; do command -v "$c" >/dev/null 2>&1 || [[ "${BRIDGEAPPLY_TEST:-}" == 1 ]] || { echo "STOP: $c fehlt - nichts geaendert"; exit 1; }; done
[[ -d "$DASH_DIR" ]] || { echo "STOP: $DASH_DIR fehlt - nichts geaendert"; exit 1; }
s16() { sha256sum "$1" | cut -c1-16; }
active() { [[ "$("$SYSTEMCTL" is-active "$1" 2>/dev/null || true)" == active ]]; }
mainpid() { "$SYSTEMCTL" show -p MainPID --value "$1" 2>/dev/null || echo 0; }
active prepper-dashboard || { echo "STOP: prepper-dashboard ist nicht aktiv - nichts geaendert"; exit 1; }
# ---------- 1) Basis (streng) ----------
bad=""; NEED_ANY=0
declare -A CUR NEED
for i in "${!F_NAME[@]}"; do
  f="${F_NAME[$i]}"; p="$DASH_DIR/$f"
  if [[ -f "$p" ]]; then CUR[$f]=$(s16 "$p"); else CUR[$f]="-"; fi
  ok=0
  for k in ${F_BASE16[$i]}; do [[ "${CUR[$f]}" == "$k" ]] && ok=1; done
  [[ "${CUR[$f]}" == "${F_NEW16[$i]}" ]] && ok=1
  echo "Basis $f sha16 ${CUR[$f]} (erwartet ${F_BASE16[$i]} oder neu ${F_NEW16[$i]})"
  [[ $ok == 1 ]] || bad="$bad $f (sha16 ${CUR[$f]});"
  if [[ "${CUR[$f]}" == "${F_NEW16[$i]}" ]]; then NEED[$f]=0; else NEED[$f]=1; NEED_ANY=1; fi
done
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  for i in "${!F_NAME[@]}"; do
    f="${F_NAME[$i]}"; ok=0
    for k in ${F_BASE16[$i]} "${F_NEW16[$i]}"; do [[ "${CUR[$f]}" == "$k" ]] && ok=1; done
    if [[ $ok == 0 && -f "$DASH_DIR/$f" && -f "$W/base/$f" ]]; then echo "--- Diff $f (erwartete Basis -> Pi), erste 60 Zeilen:"; diff -u "$W/base/$f" "$DASH_DIR/$f" | head -60 || true; fi
  done
  echo "      Nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
NEED_M1=0; NEED_M2=0
for f in $G1; do [[ "${NEED[$f]:-0}" == 1 ]] && NEED_M1=1; done
for f in $G2; do [[ "${NEED[$f]:-0}" == 1 ]] && NEED_M2=1; done
for pair in "$NEED_M1:$SVC1" "$NEED_M2:$SVC2"; do
  [[ "${pair%%:*}" == 1 ]] || continue; sv=${pair#*:}
  active "$sv" || { echo "STOP: $sv ist nicht aktiv (Basis-Zustand unklar, Selbstpruefung nach dem Neustart waere nicht aussagekraeftig) - nichts geaendert"; exit 1; }
done
echo "OK Basis bekannt ($(for i in "${!F_NAME[@]}"; do f="${F_NAME[$i]}"; printf '%s: %s; ' "$f" "$([[ ${NEED[$f]} == 1 ]] && echo 'wird ersetzt' || echo 'schon neu')"; done))"
# ---------- 2) Eingebettete Dateien und Pruefungen (Trockenlauf, noch keine Aenderung am Pi) ----------
for pair in "${EMBED_CHECK[@]}"; do v=${pair%%:*}; f=${pair#*:}; [[ "$(sha256sum "$W/$f" | cut -d' ' -f1)" == "${!v}" ]] || { echo "STOP: eingebettete Datei $f beschaedigt (sha256) - nichts geaendert"; exit 1; }; done
for i in "${!F_NAME[@]}"; do f="${F_NAME[$i]}"; [[ "$(s16 "$W/new/$f")" == "${F_NEW16[$i]}" ]] || { echo "STOP: sha16 der neuen Datei $f stimmt nicht mit dem Skript ueberein - nichts geaendert"; exit 1; }; done
echo "OK sha256 der eingebetteten Dateien stimmt"
PY_SYS=python3
PY_VENV=""
[[ -x "$DASH_DIR/venv/bin/python" ]] && PY_VENV="$DASH_DIR/venv/bin/python"
for i in "${!F_NAME[@]}"; do
  f="${F_NAME[$i]}"
  mkdir -p "$W/pyc"
  "$PY_SYS" -c 'import sys,py_compile; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$W/new/$f" "$W/pyc/sys-$f.pyc" || { echo "STOP: py_compile (System-Python) $f - nichts geaendert"; exit 1; }
  if [[ -n "$PY_VENV" ]]; then "$PY_VENV" -c 'import sys,py_compile; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$W/new/$f" "$W/pyc/venv-$f.pyc" || { echo "STOP: py_compile (venv-Python) $f - nichts geaendert"; exit 1; }; fi
done
echo "OK py_compile: $(printf '%s ' "${F_NAME[@]}")(System-Python $("$PY_SYS" -c 'import sys;print("%d.%d"%sys.version_info[:2])')$([[ -n "$PY_VENV" ]] && echo ", venv $("$PY_VENV" -c 'import sys;print("%d.%d"%sys.version_info[:2])')" || echo ', keine venv gefunden'))"
nice -n 19 "$PY_SYS" "$W/guardbridge.py" check "$W/new" prio > "$W/guard.log" 2>&1 && echo "OK $(tail -1 "$W/guard.log")" || { cat "$W/guard.log"; echo "STOP: Guard - nichts geaendert"; exit 1; }
nice -n 19 "$PY_SYS" "$W/guardbridge.py" mutation "$W/new" prio > "$W/mut.log" 2>&1 && echo "OK $(tail -1 "$W/mut.log")" || { cat "$W/mut.log"; echo "STOP: Mutationstest der Pruefungen - nichts geaendert"; exit 1; }
echo "Selbsttests in der Sandbox (Fake-Meshtastic, Fake-Uhr, kein Socket, nichts wird gesendet; Pi-Last niedrig per nice) ..."
for cmd in "${SELFTESTS[@]}"; do
  label=${cmd%%|*}; rest=${cmd#*|}
  ( cd "$W/test" && eval "nice -n 19 \"\$PY_SYS\" $rest" ) > "$W/st-$label.log" 2>&1 && echo "OK $label: $(tail -1 "$W/st-$label.log")" || { tail -15 "$W/st-$label.log"; echo "STOP: Selbsttest $label in der Sandbox - nichts geaendert"; exit 1; }
done
# ---------- 3) Zustand vorher (nur lesend) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep "$((SLEEP*6))"; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
health() { "${CURL[@]}" "http://127.0.0.1:$1/health" 2>/dev/null || true; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print("" if v is None else v)' "$1" 2>/dev/null || true; }
for pp in $P1 $P2; do
  H=$(health "$pp"); echo "Bridge :$pp vorher: $( [[ -n "$H" ]] && printf '%s' "$H" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok=%s connected=%s queued=%s held=%s" % (d.get("ok"), d.get("connected"), d.get("queued"), d.get("held")))' 2>/dev/null || echo 'keine Antwort')"
done
DASH_BEFORE=$(mainpid prepper-dashboard)
if [[ "$MODE_ARG" == trocken ]]; then
  echo "TROCKENLAUF beendet: alle Pruefungen und Selbsttests gruen, NICHTS am Pi geaendert (kein Neustart). Ohne 'trocken' aufrufen zum Einspielen."
  exit 0
fi
if [[ $NEED_ANY == 0 ]]; then echo "OK bridgeprio ist schon installiert - nur Nachpruefung (keine Dateiaenderung, kein Neustart)"; fi
# ---------- 4) Vor dem Einspielen: Bridges duerfen nicht im Hold sein, Warteschlange leer ----------
if [[ $NEED_ANY == 1 ]]; then
  for pair in "$P1:$SVC1:$NEED_M1" "$P2:$SVC2:$NEED_M2"; do
    pp=${pair%%:*}; r=${pair#*:}; sv=${r%%:*}; nd=${r#*:}
    [[ "$nd" == 1 ]] || continue
    t=0; q=""; held=""
    while :; do
      H=$(health "$pp"); q=$(printf '%s' "$H" | jget queued); held=$(printf '%s' "$H" | jget held)
      [[ -n "$H" ]] || { echo "STOP: $sv antwortet auf :$pp/health nicht - nichts geaendert (Dienst zuerst pruefen: systemctl status $sv)"; exit 1; }
      [[ "$held" == "True" ]] && { echo "STOP: $sv ist im Hold (Funkgeraet fuer anderes Geraet freigegeben). Ein Neustart wuerde den Hold beenden. Bitte erst fortsetzen (Dashboard /mesh) und das Skript erneut starten - nichts geaendert"; exit 1; }
      [[ "${q:-0}" == "0" ]] && break
      (( t >= WAIT_Q )) && { echo "STOP: $sv hat noch $q Nachricht(en) in der Warteschlange (nach ${WAIT_Q}s). Ein Neustart wuerde sie verlieren. Bitte spaeter erneut starten - nichts geaendert"; exit 1; }
      sleep "$SLEEP"; t=$((t+SLEEP))
    done
    echo "OK $sv: Warteschlange leer, kein Hold"
  done
  echo "sudo wird fuer den Neustart der Bridge-Dienste gebraucht (Passwort-Abfrage jetzt, VOR jeder Aenderung) ..."
  "$SUDO" -v || { echo "STOP: sudo nicht verfuegbar - nichts geaendert"; exit 1; }
fi
# ---------- 5) Installieren (Strg-C wird ignoriert, bis fertig) ----------
trap '' INT
declare -A BAK CREATED INSTALLED
RESTARTED=()
rb() {
  echo "FEHLER: $1 - Rueckgaengig"
  for f in "${F_NAME[@]}"; do
    if [[ "${INSTALLED[$f]:-0}" == 1 ]]; then
      if [[ -n "${BAK[$f]:-}" && -f "${BAK[$f]}" ]]; then cp -p "${BAK[$f]}" "$DASH_DIR/$f.rb" && mv -f "$DASH_DIR/$f.rb" "$DASH_DIR/$f" && echo "  $f zurueck"
      elif [[ "${CREATED[$f]:-0}" == 1 ]]; then rm -f -- "$DASH_DIR/$f" && echo "  $f (neu angelegt) wieder entfernt"; fi
    fi
  done
  for sv in ${RESTARTED[@]+"${RESTARTED[@]}"}; do
    if "$SUDO" "$SYSTEMCTL" restart "$sv"; then echo "  $sv mit altem Stand neu gestartet"; else echo "  WARNUNG: $sv liess sich nicht neu starten - bitte pruefen: systemctl status $sv"; fi
  done
  for pair in "$P1:$SVC1" "$P2:$SVC2"; do
    pp=${pair%%:*}; sv=${pair#*:}
    for r in ${RESTARTED[@]+"${RESTARTED[@]}"}; do [[ "$r" == "$sv" ]] || continue; t=0; until [[ -n "$(health "$pp")" ]] || (( t >= WAIT_UP )); do sleep "$SLEEP"; t=$((t+SLEEP)); done; [[ -n "$(health "$pp")" ]] && echo "  $sv antwortet wieder (:$pp/health)" || echo "  WARNUNG: $sv antwortet nicht auf :$pp/health - bitte pruefen: journalctl -u $sv -n 40 --no-pager"; done
  done
  echo "  Rollback fertig. Bitte diese Ausgabe an Grok schicken."
  exit 1
}
if [[ $NEED_ANY == 1 ]]; then
  for f in "${F_NAME[@]}"; do
    [[ "${NEED[$f]}" == 1 ]] || continue
    if [[ -f "$DASH_DIR/$f" ]]; then BAK[$f]="$DASH_DIR/$f.bak-bridgeprio-$TS"; cp -p "$DASH_DIR/$f" "${BAK[$f]}" || { echo "STOP: Sicherung $f fehlgeschlagen - nichts geaendert"; exit 1; }; else CREATED[$f]=1; fi
  done
  for f in "${F_NAME[@]}"; do
    [[ "${NEED[$f]}" == 1 ]] || continue
    cp "$W/new/$f" "$DASH_DIR/$f.new" || rb "kopieren $f"
    if [[ -n "${BAK[$f]:-}" ]]; then chmod --reference="${BAK[$f]}" "$DASH_DIR/$f.new" || rb "Rechte $f"; else chmod 644 "$DASH_DIR/$f.new"; fi
    mv -f "$DASH_DIR/$f.new" "$DASH_DIR/$f" || rb "installieren $f"
    INSTALLED[$f]=1
  done
  for i in "${!F_NAME[@]}"; do f="${F_NAME[$i]}"; [[ "$(s16 "$DASH_DIR/$f")" == "${F_NEW16[$i]}" ]] || rb "sha16 nach dem Installieren stimmt nicht ($f)"; done
  for f in "${F_NAME[@]}"; do "$PY_SYS" -c 'import sys,py_compile; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$DASH_DIR/$f" "$W/pyc/post-$f.pyc" || rb "py_compile nach dem Installieren ($f)"; done
  for f in "${F_NAME[@]}"; do
    ls -1t "$DASH_DIR/$f".bak-bridgeprio-* 2>/dev/null | tail -n +$((KEEP_LAST+1)) | while read -r o; do rm -f -- "$o"; done || true
  done
  echo "OK installiert (atomar per mv): $(for f in "${F_NAME[@]}"; do [[ ${NEED[$f]} == 1 ]] && printf '%s %s; ' "$f" "$(s16 "$DASH_DIR/$f")"; done)Backups *.bak-bridgeprio-$TS (behalten: letzte $KEEP_LAST)"
  # ---------- 6) Neustart der betroffenen Bridges, Selbstpruefung nach dem Start ----------
  for pair in "$P1:$SVC1:$NEED_M1" "$P2:$SVC2:$NEED_M2"; do
    pp=${pair%%:*}; r=${pair#*:}; sv=${r%%:*}; nd=${r#*:}
    [[ "$nd" == 1 ]] || continue
    OLDPID=$(mainpid "$sv"); SINCE=$(date '+%Y-%m-%d %H:%M:%S')
    RESTARTED+=("$sv")
    "$SUDO" "$SYSTEMCTL" restart "$sv" || rb "Neustart $sv schlug fehl"
    t=0; NEWPID=0
    while (( t < WAIT_UP )); do
      sleep "$SLEEP"; t=$((t+SLEEP))
      active "$sv" || continue
      NEWPID=$(mainpid "$sv")
      [[ "$NEWPID" != "$OLDPID" && "$NEWPID" != 0 && -n "$(health "$pp")" ]] && break
    done
    active "$sv" || rb "$sv ist nach dem Neustart nicht aktiv"
    [[ "$NEWPID" != "$OLDPID" && "$NEWPID" != 0 ]] || rb "$sv hat keinen neuen Prozess (PID $OLDPID -> $NEWPID)"
    H=$(health "$pp"); [[ -n "$H" ]] || rb "$sv antwortet nach ${WAIT_UP}s nicht auf :$pp/health"
    printf '%s' "$H" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict) and "ok" in d and "queued" in d and "q_alarm" in d and "q_routine" in d' 2>/dev/null || rb "$sv: /health liefert kein gueltiges Status-JSON"
    sleep "$((SLEEP*3))"
    active "$sv" || rb "$sv ist kurz nach dem Start wieder ausgefallen"
    [[ "$(mainpid "$sv")" == "$NEWPID" ]] || rb "$sv wurde nach dem Start erneut gestartet (PID wechselt)"
    JL=$("$JOURNALCTL" -u "$sv" --since "$SINCE" --no-pager 2>&1 || true)
    if [[ "$JL" == *"Traceback (most recent call last)"* || "$JL" == *"SyntaxError"* || "$JL" == *"ModuleNotFoundError"* || "$JL" == *"ImportError"* ]]; then printf '%s\n' "$JL" | grep -E -B2 -A8 'Traceback|SyntaxError|Error' | head -40; rb "$sv: Traceback/Importfehler im Journal seit dem Neustart"; fi
    if [[ "$JL" == *"not permitted"* || "$JL" == *"No journal files"* || "$JL" == *"Permission denied"* ]]; then JNOTE="Journal nicht lesbar (Benutzer nicht in Gruppe systemd-journal) - Prozess, Gesundheit und Status-JSON wurden trotzdem geprueft"; else JNOTE="kein Traceback im Journal ($(printf '%s\n' "$JL" | wc -l) Zeilen seit $SINCE)"; fi
    echo "OK $sv neu gestartet: aktiv, PID $OLDPID -> $NEWPID, :$pp/health gueltig ($(printf '%s' "$H" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok=%s connected=%s queued=%s held=%s" % (d.get("ok"), d.get("connected"), d.get("queued"), d.get("held")))')), $JNOTE"
  done
fi
# ---------- 7) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rb "Seite/API antwortet schlechter als vorher"
active prepper-dashboard || rb "prepper-dashboard laeuft nicht mehr"
DASH_AFTER=$(mainpid prepper-dashboard)
[[ "$DASH_BEFORE" == "$DASH_AFTER" ]] && echo "OK prepper-dashboard unveraendert aktiv (gleicher Prozess $DASH_AFTER, kein Neustart)" || rb "prepper-dashboard wurde neu gestartet ($DASH_BEFORE -> $DASH_AFTER)"
echo "OK nur mesh_bridge.py und mesh_bridge_bayern.py geaendert (kein Router, kein Dashboard, keine Konfiguration, nichts gesendet)"
echo
echo "=== bridgeprio FERTIG ($COMMIT_ARG) ==="
echo "Dateien: $(for f in "${F_NAME[@]}"; do printf '%s %s; ' "$f" "$(s16 "$DASH_DIR/$f")"; done)"
for f in "${F_NAME[@]}"; do [[ -n "${BAK[$f]:-}" ]] && echo "Rueckgaengig: cp -p ${BAK[$f]} $DASH_DIR/$f"; [[ "${CREATED[$f]:-0}" == 1 ]] && echo "Rueckgaengig (neue Datei): rm $DASH_DIR/$f"; done
[[ -n "${BAK[*]-}" || -n "${CREATED[*]-}" ]] && echo "Nach dem Zurueckkopieren: sudo systemctl restart $SVC1 $SVC2" || true
echo "Hinweis: Es wurde nichts gesendet (kein Mesh, kein Telegram, keine Alarme)."
