#!/bin/bash
set -euo pipefail
# uplinkDetect=1: Telekom vs. Starlink-Ausfallschutz sicher erkennen, nur Anzeige (keine Mesh-Meldung).
# - neues Modul uplink_detect.py: eigener Thread alle 60 s, Hop 2 + Rueckwaerts-DNS + Schuessel 192.168.100.1,
#   ASN nur bei neuer IP als Ergaenzung; mind. 2 gleiche Merkmale, sonst Pfad unklar; Umschalten nach 2 gleichen Ergebnissen
# - dashboard.py: nur ein kleiner Block vor if __name__ (Import + install), classify_uplink wird ersetzt (-> /pi)
# - Anzeige Lage-Kachel Internet, /api/uplink, Zustand uplink_state.json (seit bleibt nach Neustart)
# Smoke auf dem Dashboard-Port aus config.py (5000), 8080 = Kiwix wird verweigert. Automatischer Rollback.
# uplinkHistory=1 (Update von 052e9ddf): Zaehler + letzte 10 Starlink-Phasen (Start/Ende/Dauer) in uplink_state.json,
#   Anzeige unter den Zeilen der Internet-Kachel auf /pi, /api/uplink starlink_total/starlink_events. Lage-Kachel unveraendert.
#   uplink_detect.py wird mit Backup ersetzt, uplink_state.json bleibt (nur Backup-Kopie).
# Aendert nie update_all()  # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
MOD="$DASH_DIR/uplink_detect.py"
STATE="$DASH_DIR/uplink_state.json"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/uplinkhist
EXPECT_PATCH="ee2ceef56f3422f083d7ea642c5561b27f4036e5028b227a798cd3d7394608f1"
EXPECT_MOD="4f6f03c15a16a08f48cace5c370e8ef17ef0fd32ae6d7f7da8454d1bd39db41b"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-uplink-detect.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""uplinkDetect: haengt einen kleinen Block vor if __name__ == "__main__" in dashboard.py.

Der Block importiert uplink_detect.py (liegt daneben) und ruft install(app, globals()):
  - /api/uplink, Anzeige in der Lage-Kachel Internet (nach dem Rendern eingefuegt)
  - classify_uplink (f7785fdc) wird durch die nicht blockierende Zustandsabfrage ersetzt -> /pi
  - eigener Thread alle 60 s
Idempotent (Marker uplinkDetect). Aendert nie update_all()  # einmal beim Start.
Keine data_store-Zuweisung, kein data_store.clear(), keine Mesh-Sendung.
"""
import re
import sys
from pathlib import Path

MARK = "uplinkDetect"
BEGIN = "# ===== uplinkDetect: Telekom/Starlink-Erkennung (Lage-Kachel Internet, /pi, /api/uplink) ====="
END = "# ===== /uplinkDetect ====="
BLOCK = BEGIN + "\n" + """try:
    import uplink_detect as _uld_mod  # uplinkDetect
    _uld_mod.install(app, globals())
except Exception as _uld_e:
    print("uplinkDetect:", _uld_e)
""" + END + "\n\n"

d = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
p = d / "dashboard.py" if d.is_dir() else d
src = p.read_text(encoding="utf-8")

if BEGIN in src:
    a = src.index(BEGIN)
    if END not in src[a:]:
        raise SystemExit("STOP: uplinkDetect-Block ohne Ende-Marker")
    b = src.index(END, a) + len(END)
    while b < len(src) and src[b] == "\n":
        b += 1
    new = src[:a] + BLOCK + src[b:]
    print("RESULT block schon da (%s)" % ("gleich" if new == src else "aktualisiert"))
else:
    ms = list(re.finditer(r"^if __name__ == ['\"]__main__['\"]:", src, re.M))
    if not ms:
        raise SystemExit("STOP: if __name__ == '__main__' fehlt")
    m = ms[-1]
    if "update_all()  # einmal beim Start" not in src[m.start():]:
        raise SystemExit("STOP: Boot-Zeile nicht nach __main__")
    if not re.search(r"^app\s*=\s*Flask\(", src[:m.start()], re.M):
        raise SystemExit("STOP: app = Flask(...) nicht vor __main__")
    new = src[:m.start()] + BLOCK + src[m.start():]
    print("RESULT block neu eingefuegt vor __main__")
print("RESULT classify_uplink vorhanden: %s" % ("ja" if "def classify_uplink(" in src else "nein (wird trotzdem bereitgestellt)"))
print("RESULT starlinkUplink-Marker: %d" % src.count("# starlinkUplink"))
if new != src:
    p.write_text(new, encoding="utf-8")
PATCHPY_EOF
cat > "$W/uplink_detect.py" << 'MODPY_EOF'
#!/usr/bin/env python3
"""uplinkDetect: Telekom (Festnetz) vs. Starlink-Ausfallschutz sicher erkennen.

Eigener Hintergrund-Thread, alle 60 s (unabhaengig vom 15-Min-Voll-Update).
Merkmale (alle ohne sudo, jede Abfrage mit Timeout):
  1. Hop 2 (ping -n -c1 -W1 -t 2 1.1.1.1): 100.64.0.0/10 = Starlink, oeffentlich = Telekom
  2. Rueckwaerts-DNS der oeffentlichen IP: starlink.com/starlinkisp.net = Starlink,
     t-ipconnect.de/telekom = Telekom
  3. Starlink-Schuessel 192.168.100.1: antwortet = Starlink, keine Antwort = schwach Telekom
  4. ASN (ip-api.com) nur bei neuer oeffentlicher IP, gecacht, nur als Ergaenzung
Entscheidung: mindestens 2 uebereinstimmende Merkmale, Widerspruch/Ausfall = Pfad unklar.
Umschalten erst nach 2 gleichen Ergebnissen hintereinander. Zustand in uplink_state.json.
Sendet NIE etwas ins Mesh. Anzeige: Lage-Kachel Internet + /pi + /api/uplink.
uplinkHistory: Zaehler + letzte 10 Starlink-Phasen (Start/Ende) in uplink_state.json, Anzeige /pi-Kachel Internet.
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import statistics
import subprocess
import threading
import time
from datetime import datetime

MARK = "uplinkDetect"
VERSION = "uplinkDetect-2"
HIST_MARK = "uplinkHistory"
SL_KEEP = 10              # letzte Starlink-Phasen

BASE = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(BASE, "uplink_state.json")

CHECK_EVERY = 60          # Sekunden zwischen regulaeren Pruefungen
FAST_RECHECK = 15         # Nachpruefung bei moeglichem Wechsel
TICK = 5                  # Schleifentakt fuer Ausloeser (Latenz, IP)
LAT_JUMP_MS = 15.0        # Latenz > Median(5 Min) + 15 ms -> sofort pruefen
LAT_WINDOW = 300
SWITCH_AFTER = 2          # gleiche Ergebnisse hintereinander bis Umschalten
STALE_SEC = 300
HOP_TARGETS = ("1.1.1.1", "8.8.8.8")
DISH_IP = "192.168.100.1"
TRACE_URLS = ("https://1.1.1.1/cdn-cgi/trace", "https://one.one.one.one/cdn-cgi/trace")
IPIFY_URL = "https://api.ipify.org"
ASN_URL = "http://ip-api.com/json/%s?fields=status,isp,org,as"
ASN_RETRY_SEC = 600

CGNAT = ipaddress.ip_network("100.64.0.0/10")
# Deutsche Telekom (AS3320) Kernnetze - nur zur Info, jede oeffentliche Hop-2-Adresse zaehlt als Festnetz
DTAG_NETS = [ipaddress.ip_network(n) for n in (
    "80.128.0.0/11", "84.128.0.0/10", "87.128.0.0/10", "91.0.0.0/10", "93.192.0.0/10",
    "79.192.0.0/10", "217.0.0.0/13", "217.224.0.0/11", "62.152.0.0/14", "62.156.0.0/14",
    "62.224.0.0/14", "194.25.0.0/16", "217.80.0.0/12", "2003::/19")]
RDNS_STARLINK = ("starlink.com", "starlinkisp.net", "spacex.com")
RDNS_TELEKOM = ("t-ipconnect.de", "telekom.de", "telekom.net", "dtag.de")

LABELS = {
    "telekom": ("Festnetz \u00b7 Telekom", "\U0001f50c"),
    "starlink": ("Starlink \u00b7 Ausfallschutz", "\U0001f6f0\ufe0f"),
    "unclear": ("Pfad unklar", "\u2754"),
    None: ("Pfad wird gepr\u00fcft", "\u23f3"),
}

_lock = threading.Lock()
_wake = threading.Event()
_started = False
_G = None            # globals() des laufenden Dashboards (data_store wird bei jedem Zugriff neu gelesen)
_G_main = False
_orig_classify = None
_loaded = False

_state = {
    "marker": MARK, "version": VERSION,
    "current": None, "since": None, "since_str": None,
    "pending": None, "pending_n": 0,
    "candidate": None, "reason": None,
    "last_check": None, "last_check_str": None, "checks": 0,
    "signals": {}, "public_ip": None,
    "asn_cache": {}, "history": [],
    "trigger": None,
    "sl_total": 0, "sl_events": [],   # uplinkHistory, sl_events aelteste zuerst
}
_lat = []           # [(ts, ms)]
_last_trigger = {"t": 0.0, "why": None}
_last_saved = {"t": 0.0, "key": None}


# ---------------------------------------------------------------- Hilfen
def _now():
    return time.time()


def _fmt(ts, with_date=False):
    if not ts:
        return None
    d = datetime.fromtimestamp(ts)
    return d.strftime("%d.%m. %H:%M" if with_date else "%H:%M")


def _since_hm(ts):
    if not ts:
        return None
    d = datetime.fromtimestamp(ts)
    if d.date() == datetime.now().date():
        return d.strftime("%H:%M")
    return d.strftime("%d.%m. %H:%M")


def _run(cmd, timeout):
    """subprocess mit hartem Timeout, liefert (rc, stdout)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return -1, "ERR %s" % e


def _ip_or_none(s):
    try:
        return ipaddress.ip_address((s or "").strip())
    except Exception:
        return None


# ---------------------------------------------------------------- Merkmale
def probe_hop2():
    for tgt in HOP_TARGETS:
        rc, out = _run(["ping", "-n", "-c", "1", "-W", "1", "-t", "2", tgt], 4)
        m = re.search(r"From (\d{1,3}(?:\.\d{1,3}){3})", out)
        if m:
            return m.group(1)
    return None


def classify_hop(hop):
    ip = _ip_or_none(hop)
    if ip is None:
        return {"ip": hop, "vote": None, "why": "keine Antwort"}
    if ip.version == 4 and ip in CGNAT:
        return {"ip": hop, "vote": "starlink", "why": "CGNAT 100.64/10"}
    if ip.is_private or ip.is_loopback or ip.is_link_local or not ip.is_global:
        return {"ip": hop, "vote": None, "why": "privat - unklar"}
    dtag = any(ip.version == n.version and ip in n for n in DTAG_NETS)
    return {"ip": hop, "vote": "telekom", "why": "Telekom-Netz" if dtag else "oeffentlich (kein CGNAT)"}


def probe_public_ip():
    try:
        import requests
    except Exception:
        return None, "kein requests"
    for url in TRACE_URLS:
        try:
            r = requests.get(url, timeout=(3, 4))
            for line in r.text.splitlines():
                if line.startswith("ip="):
                    ip = _ip_or_none(line[3:])
                    if ip is not None and ip.version == 4:
                        return str(ip), "cloudflare"
        except Exception:
            pass
    try:
        r = requests.get(IPIFY_URL, timeout=(3, 4))
        ip = _ip_or_none(r.text)
        if ip is not None:
            return str(ip), "ipify"
    except Exception:
        pass
    return None, "keine Antwort"


def probe_rdns(ip):
    if not ip:
        return None
    rc, out = _run(["getent", "hosts", ip], 4)
    if rc != 0:
        return None
    parts = out.split()
    return parts[1].rstrip(".").lower() if len(parts) >= 2 else None


def classify_rdns(name):
    if not name:
        return {"name": None, "vote": None, "why": "kein Name"}
    n = name.lower()
    if any(n.endswith(s) or ("." + s) in n for s in RDNS_STARLINK):
        return {"name": name, "vote": "starlink", "why": "starlink-Name"}
    if any(n.endswith(s) or ("." + s) in n for s in RDNS_TELEKOM):
        return {"name": name, "vote": "telekom", "why": "t-ipconnect-Name"}
    return {"name": name, "vote": None, "why": "fremder Name"}


def probe_dish():
    rc, out = _run(["ping", "-n", "-c", "2", "-i", "0.3", "-W", "1", DISH_IP], 5)
    if rc == 0:
        return True
    if re.search(r"\b[1-9]\d* (?:packets )?received", out):
        return True
    return False


def classify_dish(reach):
    if reach:
        return {"reachable": True, "vote": "starlink", "weak": False, "why": "Schuessel antwortet"}
    return {"reachable": False, "vote": "telekom", "weak": True, "why": "Schuessel still (schwach)"}


def lookup_asn(ip):
    try:
        import requests
        r = requests.get(ASN_URL % ip, timeout=(3, 4))
        d = r.json() if r.status_code == 200 else {}
    except Exception as e:
        return {"ip": ip, "ok": False, "err": str(e)[:80], "at": _now()}
    if not isinstance(d, dict) or d.get("status") not in (None, "success"):
        return {"ip": ip, "ok": False, "err": str(d)[:80], "at": _now()}
    asn = str(d.get("as") or "")
    isp = str(d.get("isp") or "")
    org = str(d.get("org") or "")
    return {"ip": ip, "ok": True, "as": asn, "isp": isp, "org": org, "at": _now()}


def classify_asn(c):
    if not c or not c.get("ok"):
        return None
    blob = " ".join([c.get("as") or "", c.get("isp") or "", c.get("org") or ""]).lower()
    if blob.startswith("as14593 ") or " as14593" in (" " + blob) or "starlink" in blob or "spacex" in blob:
        return "starlink"
    if blob.startswith("as3320 ") or "telekom" in blob:
        return "telekom"
    return None


# ---------------------------------------------------------------- Entscheidung
def decide(sig):
    """sig: hop/rdns/dish/asn-Dicts. Liefert (Ergebnis, Begruendung)."""
    strong = []
    for k in ("hop", "rdns"):
        v = (sig.get(k) or {}).get("vote")
        if v:
            strong.append((k, v))
    dish = sig.get("dish") or {}
    weak_t = 0
    if dish.get("vote") == "starlink" and not dish.get("weak"):
        strong.append(("dish", "starlink"))
    elif dish.get("vote") == "telekom" and dish.get("weak"):
        weak_t = 1
    S = sum(1 for _, v in strong if v == "starlink")
    T = sum(1 for _, v in strong if v == "telekom")
    asn = (sig.get("asn") or {}).get("vote")
    if S and T:
        return "unclear", "Widerspruch: " + ", ".join("%s=%s" % kv for kv in strong)
    if S >= 2:
        return "starlink", "%d Merkmale Starlink" % S
    if T >= 1 and T + weak_t >= 2:
        return "telekom", "%d Merkmale Telekom%s" % (T, " + Schuessel still" if weak_t else "")
    # nur ein Merkmal: ASN darf ergaenzen, nie ueberstimmen
    if S == 1 and asn == "starlink":
        return "starlink", "1 Merkmal + ASN Starlink"
    if T == 1 and asn == "telekom":
        return "telekom", "1 Merkmal + ASN Telekom"
    if S == 0 and T == 0:
        return "unclear", "keine Merkmale (Ausfall/Timeout)"
    return "unclear", "zu wenig Merkmale (%s)" % (", ".join("%s=%s" % kv for kv in strong) or "-")


def gather():
    hop = classify_hop(probe_hop2())
    pip, src = probe_public_ip()
    rd = classify_rdns(probe_rdns(pip))
    dish = classify_dish(probe_dish())
    asn_vote = None
    asn_info = None
    if pip:
        with _lock:
            cache = dict(_state.get("asn_cache") or {})
        if cache.get("ip") != pip or (not cache.get("ok") and _now() - float(cache.get("at") or 0) > ASN_RETRY_SEC):
            cache = lookup_asn(pip)
            with _lock:
                _state["asn_cache"] = cache
        asn_vote = classify_asn(cache)
        asn_info = {"as": cache.get("as"), "isp": cache.get("isp"), "vote": asn_vote, "cached_for": cache.get("ip")}
    return {"hop": hop, "rdns": rd, "dish": dish, "asn": asn_info or {"vote": None},
            "public_ip": pip, "ip_source": src}


# ---------------------------------------------------------------- Zustand
def _apply_result(result, reason, sig, ts=None):
    """Hysterese: Umschalten erst nach SWITCH_AFTER gleichen Ergebnissen."""
    ts = ts or _now()
    switched = None
    with _lock:
        st = _state
        st["candidate"], st["reason"] = result, reason
        st["signals"] = sig
        st["last_check"], st["last_check_str"] = ts, _fmt(ts, True)
        st["checks"] = int(st.get("checks") or 0) + 1
        old_ip = st.get("public_ip")
        if sig.get("public_ip"):
            st["public_ip"] = sig.get("public_ip")
        if result == st.get("current"):
            st["pending"], st["pending_n"] = None, 0
        else:
            if st.get("pending") == result:
                st["pending_n"] = int(st.get("pending_n") or 0) + 1
            else:
                st["pending"], st["pending_n"] = result, 1
            if st["pending_n"] >= SWITCH_AFTER:
                prev = st.get("current")
                st["current"] = result
                st["since"], st["since_str"] = ts, _fmt(ts, True)
                st["pending"], st["pending_n"] = None, 0
                hist = list(st.get("history") or [])
                hist.append({"t": ts, "t_str": _fmt(ts, True), "from": prev, "to": result, "why": reason})
                st["history"] = hist[-30:]
                _sl_transition(st, prev, result, ts)
                switched = (prev, result)
        ip_changed = bool(old_ip and sig.get("public_ip") and old_ip != sig.get("public_ip"))
    if switched:
        print("uplinkDetect: Pfad %s -> %s (%s) hop2=%s rdns=%s dish=%s" % (
            switched[0], switched[1], reason, (sig.get("hop") or {}).get("ip"),
            (sig.get("rdns") or {}).get("name"), (sig.get("dish") or {}).get("reachable")), flush=True)
    return switched, ip_changed


# ---------------------------------------------------------------- uplinkHistory
def _sl_open(st):
    ev = st.get("sl_events") or []
    return ev[-1] if ev and not ev[-1].get("end") else None


def _sl_transition(st, prev, new, ts):
    """Bestaetigter Wechsel: rein nach Starlink -> neue Phase, raus nach Telekom -> Ende.
    'Pfad unklar' beendet eine laufende Starlink-Phase nicht (kurze Aussetzer teilen sie nicht)."""
    ev = list(st.get("sl_events") or [])
    st["sl_events"] = ev
    if new == "starlink":
        if not _sl_open(st):
            ev.append({"start": ts, "end": None})
            st["sl_total"] = int(st.get("sl_total") or 0) + 1
    elif new == "telekom":
        o = _sl_open(st)
        if o:
            o["end"] = ts
    st["sl_events"] = ev[-SL_KEEP:]


def _sl_seed(st):
    """Einmalig nach Update: Phasen aus der Wechsel-Historie nachbauen, laufende Phase ab 'since'."""
    st["sl_events"], st["sl_total"] = [], 0
    for h in st.get("history") or []:
        try:
            _sl_transition(st, h.get("from"), h.get("to"), float(h.get("t")))
        except Exception:
            pass
    if st.get("current") == "starlink" and not _sl_open(st) and st.get("since"):
        st["sl_events"].append({"start": float(st["since"]), "end": None})
        st["sl_events"] = st["sl_events"][-SL_KEEP:]
        st["sl_total"] = int(st.get("sl_total") or 0) + 1
    if st.get("current") != "starlink":
        o = _sl_open(st)
        if o and st.get("current") == "telekom":
            o["end"] = float(st.get("since") or _now())


def _dur(sec):
    m = max(0, int(round(sec / 60.0)))
    if m < 60:
        return "%d min" % m
    h, m = divmod(m, 60)
    if h < 24:
        return "%d h %02d min" % (h, m)
    d, h = divmod(h, 24)
    return "%d T %d h" % (d, h)


def sl_lines():
    """Neueste zuerst: '08.10.2026 22:49 \u2013 22:58 (9 min)' bzw. '... \u2013 l\u00e4uft'."""
    with _lock:
        ev = [dict(e) for e in (_state.get("sl_events") or [])]
    out = []
    for e in reversed(ev):
        try:
            a = datetime.fromtimestamp(float(e["start"]))
        except Exception:
            continue
        s = a.strftime("%d.%m.%Y %H:%M") + " \u2013 "
        if e.get("end"):
            b = datetime.fromtimestamp(float(e["end"]))
            s += b.strftime("%H:%M") if b.date() == a.date() else b.strftime("%d.%m. %H:%M")
            s += " (%s)" % _dur(float(e["end"]) - float(e["start"]))
        else:
            s += "l\u00e4uft (%s)" % _dur(_now() - float(e["start"]))
        out.append({"start": e["start"], "end": e.get("end"), "line": s})
    return out


def _save(force=False):
    with _lock:
        snap = {k: _state.get(k) for k in ("marker", "version", "current", "since", "since_str", "pending",
                                           "pending_n", "candidate", "reason", "last_check", "last_check_str",
                                           "signals", "public_ip", "asn_cache", "history",
                                           "sl_total", "sl_events")}
    key = (snap["current"], snap["since"], snap["pending"], snap["pending_n"], snap["candidate"], snap["public_ip"],
           snap["sl_total"], len(snap["sl_events"] or []))
    if not force and key == _last_saved["key"] and _now() - _last_saved["t"] < 600:
        return
    try:
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(snap, f, ensure_ascii=False, indent=1)
        os.replace(tmp, STATE_FILE)
        _last_saved["key"], _last_saved["t"] = key, _now()
    except Exception as e:
        print("uplinkDetect save:", e)


def _load():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        return False
    if not isinstance(d, dict) or d.get("marker") != MARK:
        return False
    with _lock:
        for k in ("current", "since", "since_str", "candidate", "reason", "last_check", "last_check_str",
                  "signals", "public_ip", "asn_cache", "history"):
            if k in d:
                _state[k] = d[k]
        if _state.get("current") not in ("telekom", "starlink", "unclear"):
            _state["current"] = None
        # Hysterese-Zaehler nach Neustart frisch beginnen
        _state["pending"], _state["pending_n"] = None, 0
        seeded = False
        if "sl_total" in d and isinstance(d.get("sl_events"), list):
            _state["sl_total"] = int(d.get("sl_total") or 0)
            _state["sl_events"] = [e for e in d["sl_events"] if isinstance(e, dict) and e.get("start")][-SL_KEEP:]
            if _state.get("current") == "starlink" and not _sl_open(_state) and _state.get("since"):
                _state["sl_events"] = (_state["sl_events"] + [{"start": float(_state["since"]), "end": None}])[-SL_KEEP:]
                _state["sl_total"] += 1
                seeded = True
        else:
            _sl_seed(_state)
            seeded = True
    if seeded:
        _save(force=True)
    return True


def public_state():
    with _lock:
        st = json.loads(json.dumps(_state, default=str))
    cur = st.get("current")
    label, icon = LABELS.get(cur, LABELS[None])
    age = None
    if st.get("last_check"):
        age = int(_now() - float(st["last_check"]))
    st["label"], st["icon"] = label, icon
    st["since_hm"] = _since_hm(st.get("since"))
    st["last_check_age_s"] = age
    st["stale"] = age is None or age > STALE_SEC
    if cur == "telekom":
        st["text"] = "\U0001f50c via Telekom"
    elif cur == "starlink":
        st["text"] = "\U0001f6f0\ufe0f via Starlink \u00b7 Ausfallschutz" + (" seit %s" % st["since_hm"] if st["since_hm"] else "")
    elif cur == "unclear":
        st["text"] = "\u2754 Pfad unklar"
    else:
        st["text"] = "\u23f3 Pfad wird gepr\u00fcft \u2026"
    st["path"] = {"telekom": "landline", "starlink": "starlink", "unclear": "unclear"}.get(cur, "unclear")
    st.pop("asn_cache", None)
    st.pop("sl_events", None)
    st["starlink_total"] = int(st.pop("sl_total", 0) or 0)
    st["starlink_events"] = sl_lines()
    return st


def _push_to_data_store():
    """Nach jedem Check in den aktuellen data_store schreiben (Voll-Update ersetzt das dict)."""
    g = _G
    if not isinstance(g, dict):
        return
    ds = g.get("data_store")
    if not isinstance(ds, dict):
        return
    ps = public_state()
    try:
        ds["uplink"] = ps
        if ds.get("conn_type") != "Offline":
            up = classify_uplink(ps.get("public_ip") or ds.get("public_ip") or "x")
            ds["conn_type"], ds["conn_icon"] = up["conn_type"], up["conn_icon"]
            ds["uplink_path"], ds["uplink_hint"] = up["path"], up["hint"]
            if up.get("isp"):
                ds["uplink_isp"] = up["isp"]
            if up.get("as"):
                ds["uplink_as"] = up["as"]
        if ps.get("public_ip"):
            ds["public_ip"] = ps["public_ip"]
    except Exception as e:
        print("uplinkDetect data_store:", e)


def check_now():
    sig = gather()
    res, why = decide(sig)
    switched, ip_changed = _apply_result(res, why, sig)
    _save(force=bool(switched))
    _push_to_data_store()
    return res, why, switched, ip_changed


# ---------------------------------------------------------------- Ausloeser
def _latency_trigger():
    g = _G
    if not isinstance(g, dict):
        return False
    ds = g.get("data_store")
    v = ds.get("ping") if isinstance(ds, dict) else None
    try:
        v = float(v)
    except Exception:
        return False
    t = _now()
    if _lat and t - _lat[-1][0] < 20:
        return False
    hist = [x for x in _lat if t - x[0] <= LAT_WINDOW]
    _lat[:] = hist + [(t, v)]
    if len(hist) < 4:
        return False
    med = statistics.median([x[1] for x in hist])
    return v > med + LAT_JUMP_MS


def _ip_trigger():
    g = _G
    ds = g.get("data_store") if isinstance(g, dict) else None
    ip = ds.get("public_ip") if isinstance(ds, dict) else None
    with _lock:
        known = _state.get("public_ip")
    return bool(ip and known and ip != known)


def request_check(why="api"):
    t = _now()
    if t - _last_trigger["t"] < 10:
        return False
    _last_trigger["t"], _last_trigger["why"] = t, why
    with _lock:
        _state["trigger"] = why
    _wake.set()
    return True


def _loop():
    next_at = 0.0
    while True:
        try:
            t = _now()
            if _wake.is_set() or t >= next_at:
                _wake.clear()
                res, why, switched, ip_changed = check_now()
                with _lock:
                    pending = _state.get("pending")
                    _state["trigger"] = None
                next_at = _now() + (FAST_RECHECK if (pending or ip_changed) else CHECK_EVERY)
            else:
                trig = None
                if _latency_trigger():
                    trig = "latenz"
                elif _ip_trigger():
                    trig = "ip"
                if trig and _now() - _last_trigger["t"] > 60:
                    _last_trigger["t"], _last_trigger["why"] = _now(), trig
                    with _lock:
                        _state["trigger"] = trig
                    next_at = 0.0
                    continue
        except Exception as e:
            print("uplinkDetect loop:", e)
            next_at = _now() + CHECK_EVERY
        _wake.wait(TICK)


def start():
    global _started
    with _lock:
        if _started:
            return False
        _started = True
    threading.Thread(target=_loop, name="uplinkDetect", daemon=True).start()
    print("uplinkDetect: Thread gestartet (alle %ss, Zustand %s)" % (CHECK_EVERY, STATE_FILE), flush=True)
    return True


# ---------------------------------------------------------------- classify_uplink-Ersatz
def classify_uplink(public_ip, ping_ms=None):
    """Ersatz fuer f7785fdc classify_uplink: nicht blockierend, liest nur den Zustand. # uplinkDetect"""
    if not public_ip:
        return {"conn_type": "Offline", "conn_icon": "\U0001f534", "path": "offline",
                "isp": None, "org": None, "as": None, "hint": None}
    with _lock:
        cur = _state.get("current")
        since = _state.get("since")
        cache = dict(_state.get("asn_cache") or {})
        reason = _state.get("reason")
    label, icon = LABELS.get(cur, LABELS[None])
    path = {"telekom": "landline", "starlink": "starlink", "unclear": "unclear"}.get(cur, "unclear")
    hint = None
    if cur == "starlink":
        hint = "Ausfallschutz aktiv" + (" seit %s" % _since_hm(since) if since else "")
    elif cur == "unclear":
        hint = "Pfad unklar: %s" % (reason or "-")
    elif cur is None:
        hint = "Erkennung l\u00e4uft"
    return {"conn_type": label, "conn_icon": icon, "path": path,
            "isp": cache.get("isp") or None, "org": cache.get("org") or None,
            "as": cache.get("as") or None, "hint": hint}


classify_uplink._uplinkDetect = True


# ---------------------------------------------------------------- Anzeige Lage-Kachel
_JS = r"""<script data-uplinkdetect="1">(function(){
var S=__INIT__;
function card(){
  var p=document.getElementById('ping-value');
  if(p&&p.closest){var c=p.closest('.card');if(c)return c;}
  var ts=document.querySelectorAll('.card .title');
  for(var i=0;i<ts.length;i++){if(/Internet/i.test(ts[i].textContent||''))return ts[i].closest('.card');}
  return null;
}
function line(){
  var e=document.getElementById('uplink-line');if(e)return e;
  var c=card();if(!c)return null;
  e=document.createElement('div');e.id='uplink-line';
  e.style.cssText='margin-top:4px;font-size:.85rem;font-weight:600;line-height:1.25';
  var m=null,ch=c.children;
  for(var i=0;i<ch.length;i++){if(ch[i].classList&&ch[i].classList.contains('medium')){m=ch[i];break;}}
  if(m){m.insertAdjacentElement('afterend',e);}
  else{var p=document.getElementById('ping-value');var s=p&&p.closest?p.closest('.small'):null;
    if(s&&s.parentNode===c){c.insertBefore(e,s);}else{c.appendChild(e);}}
  return e;
}
function render(d){
  var e=line();if(!e||!d)return;
  var col='#94a3b8',c=card();
  if(d.current==='telekom'){col='#93c5fd';}
  else if(d.current==='starlink'){col='#f59e0b';}
  else if(d.current==='unclear'){col='#eab308';}
  e.textContent=d.text||'';
  if(d.stale&&d.current){e.textContent+=' \u00b7 Pr\u00fcfung veraltet';}
  if(d.pending&&d.pending!==d.current){e.textContent+=' \u00b7 pr\u00fcfe Wechsel';}
  e.style.color=col;
  var sg=d.signals||{},h=sg.hop||{},r=sg.rdns||{},di=sg.dish||{};
  e.title='Hop2 '+(h.ip||'-')+' \u00b7 DNS '+(r.name||'-')+' \u00b7 Sch\u00fcssel '+(di.reachable?'ja':'nein')+' \u00b7 '+(d.reason||'')+' \u00b7 gepr\u00fcft '+(d.last_check_str||'-');
  if(c){c.style.borderColor=(d.current==='starlink')?'#f59e0b':'';}
}
try{render(S);}catch(x){}
setInterval(function(){
  fetch('/api/uplink',{cache:'no-store'}).then(function(r){return r.json();}).then(function(d){try{render(d);}catch(x){}}).catch(function(){});
},30000);
})();</script>"""


_JS_PI = r"""<script data-uplinkhistory="1">(function(){
var S=__INIT__;
function card(){
  var ts=document.querySelectorAll('.card .title');
  for(var i=0;i<ts.length;i++){if(/Internet/i.test(ts[i].textContent||''))return ts[i].closest('.card');}
  return null;
}
function box(){
  var e=document.getElementById('uplink-hist');if(e)return e;
  var c=card();if(!c)return null;
  e=document.createElement('div');e.id='uplink-hist';
  e.style.cssText='margin-top:6px;font-size:.72rem;line-height:1.3;color:var(--muted,#94a3b8)';
  var rows=c.querySelectorAll(':scope > .row'),last=rows.length?rows[rows.length-1]:null;
  if(last){last.insertAdjacentElement('afterend',e);}
  else{var sm=c.querySelector(':scope > .small');if(sm){c.insertBefore(e,sm);}else{c.appendChild(e);}}
  return e;
}
function render(d){
  var e=box();if(!e||!d)return;
  while(e.firstChild)e.removeChild(e.firstChild);
  var h=document.createElement('div');h.style.margin='0';
  var b=document.createElement('b');b.style.color='#e2e8f0';
  b.textContent='Starlink-Wechsel gesamt: '+(d.starlink_total||0);h.appendChild(b);e.appendChild(h);
  var ev=d.starlink_events||[];
  for(var i=0;i<ev.length&&i<10;i++){
    var l=document.createElement('div');l.style.margin='0';l.textContent=ev[i].line||'';
    if(!ev[i].end){l.style.color='#f59e0b';}
    e.appendChild(l);
  }
}
try{render(S);}catch(x){}
setInterval(function(){
  fetch('/api/uplink',{cache:'no-store'}).then(function(r){return r.json();}).then(function(d){try{render(d);}catch(x){}}).catch(function(){});
},60000);
})();</script>"""


def inject_pi(page):
    if 'data-uplinkhistory="1"' in page:
        return page
    ps = public_state()
    init = json.dumps({"starlink_total": ps.get("starlink_total"), "starlink_events": ps.get("starlink_events")},
                      ensure_ascii=False, default=str).replace("</", "<\\/")
    snip = _JS_PI.replace("__INIT__", init)
    low = page.lower()
    i = low.rfind("</body>")
    if i < 0:
        return page + snip
    return page[:i] + snip + page[i:]


def inject(page):
    if 'data-uplinkdetect="1"' in page:
        return page
    init = json.dumps(public_state(), ensure_ascii=False, default=str).replace("</", "<\\/")
    snip = _JS.replace("__INIT__", init)
    low = page.lower()
    i = low.rfind("</body>")
    if i < 0:
        return page + snip
    return page[:i] + snip + page[i:]


# ---------------------------------------------------------------- Einbau
def install(app, g):
    """Aus dashboard.py (Block vor __main__): Route, Anzeige, classify_uplink-Ersatz, Thread."""
    global _G, _G_main, _orig_classify, _loaded
    is_main = isinstance(g, dict) and g.get("__name__") == "__main__"
    if isinstance(g, dict):
        old = g.get("classify_uplink")
        if callable(old) and not getattr(old, "_uplinkDetect", False) and _orig_classify is None:
            _orig_classify = old
        g["classify_uplink"] = classify_uplink
        if is_main or _G is None:
            _G, _G_main = g, is_main
    if not _loaded:
        _loaded = True
        _load()
    if getattr(app, "_uplinkDetect", False):
        return
    app._uplinkDetect = True
    app._uplinkDetect_g = g
    from flask import jsonify, request

    def _api():
        try:
            if request.args.get("refresh"):
                request_check("api")
            d = public_state()
            d["thread"] = _started
            d["had_classify"] = _orig_classify is not None
            return jsonify(d)
        except Exception as e:
            return jsonify({"marker": MARK, "error": str(e)[:200]})

    try:
        app.add_url_rule("/api/uplink", "uplink_detect_api", _api)
    except Exception as e:
        print("uplinkDetect route:", e)

    def _before():
        global _G, _G_main
        if not _started:
            try:
                ag = getattr(app, "_uplinkDetect_g", None)
                if isinstance(ag, dict) and not _G_main:
                    _G = ag
                start()
            except Exception as e:
                print("uplinkDetect start:", e)

    def _after(resp):
        try:
            if request.path not in ("/", "/pi") or request.method != "GET":
                return resp
            if resp.status_code != 200 or resp.mimetype != "text/html" or resp.direct_passthrough:
                return resp
            enc = (resp.headers.get("Content-Encoding") or "").lower()
            if enc and enc != "gzip":
                return resp
            raw = resp.get_data()
            if enc == "gzip":
                import gzip
                raw = gzip.decompress(raw)
            cs = (resp.mimetype_params or {}).get("charset") or "utf-8"
            page = raw.decode(cs)
            new = inject(page) if request.path == "/" else inject_pi(page)
            if new != page:
                out = new.encode(cs)
                if enc == "gzip":
                    import gzip
                    out = gzip.compress(out)
                resp.set_data(out)
        except Exception as e:
            print("uplinkDetect inject:", e)
        return resp

    app.before_request(_before)
    app.after_request(_after)
    if is_main:
        start()


if __name__ == "__main__":
    sig = gather()
    print(json.dumps({"signals": sig, "decision": decide(sig)}, ensure_ascii=False, indent=1, default=str))
MODPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1
fi
if [[ "$PORT" == "8080" ]]; then
  echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1
fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
echo "=== uplinkDetect + uplinkHistory apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="

# ---------- 0) Bytes + Guards der eingebetteten Dateien ----------
echo "$EXPECT_PATCH  $W/patch-uplink-detect.py" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $W/uplink_detect.py" | sha256sum -c - >/dev/null || { echo "STOP: uplink_detect.py sha256 falsch"; exit 1; }
for f in patch-uplink-detect.py uplink_detect.py; do
  grep -q 'uplinkDetect' "$W/$f" || { echo "STOP: $f ohne Marker"; exit 1; }
  if grep -q 'PLACEHOLDER' "$W/$f"; then echo "STOP: PLACEHOLDER in $f"; exit 1; fi
  python3 -m py_compile "$W/$f" || { echo "STOP: py_compile $f"; exit 1; }
done
grep -q 'uplinkHistory' "$W/uplink_detect.py" || { echo "STOP: uplink_detect.py ohne uplinkHistory"; exit 1; }
if grep -q 'send_meshtastic\|sendText\|meshtastic' "$W/uplink_detect.py"; then
  echo "STOP: uplink_detect.py darf nichts ins Mesh senden"; exit 1
fi
set +e
python3 - "$W/patch-uplink-detect.py" "$W/uplink_detect.py" << 'GUARDPY'
import ast, pathlib, sys
hit = False
for path in sys.argv[1:]:
    src = pathlib.Path(path).read_text(encoding="utf-8")
    trees = [ast.parse(src, filename=path)]
    for node in ast.walk(trees[0]):
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "BLOCK" for t in node.targets):
            try:
                trees.append(ast.parse(ast.literal_eval(node.value) if not isinstance(node.value, ast.Constant) else node.value.value))
            except Exception:
                pass
    for tree in trees:
        for n in ast.walk(tree):
            tg = []
            if isinstance(n, ast.Assign):
                tg = n.targets
            elif isinstance(n, (ast.AnnAssign, ast.AugAssign)):
                tg = [n.target]
            for t in tg:
                if isinstance(t, ast.Name) and t.id == "data_store":
                    print("%s:%s data_store-Zuweisung" % (path, n.lineno)); hit = True
            if isinstance(n, ast.Call):
                f = n.func
                if isinstance(f, ast.Attribute) and f.attr == "clear" and isinstance(f.value, ast.Name) and f.value.id == "data_store":
                    print("%s:%s data_store.clear()" % (path, n.lineno)); hit = True
                if isinstance(f, ast.Name) and f.id == "update_all":
                    print("%s:%s update_all()" % (path, n.lineno)); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g"; exit 1; }
echo "OK Bytes + AST-Guard (keine data_store-Zuweisung, kein update_all, keine Mesh-Sendung)"

[[ -f "$DASH" ]] || { echo "STOP: fehlt $DASH"; exit 1; }
grep -q 'update_all()  # einmal beim Start' "$DASH" || { echo "STOP: Boot-Zeile in dashboard.py nicht gefunden - nichts geaendert"; exit 1; }

# ---------- 1) Trockenlauf auf Kopie ----------
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$DASH" "$W/work/"
cp "$W/uplink_detect.py" "$W/work/uplink_detect.py"
set +e
python3 "$W/patch-uplink-detect.py" "$W/work" > "$W/dry.txt" 2>&1
rc=$?
set -e
cat "$W/dry.txt"
if [[ "$rc" -ne 0 ]]; then
  echo "STOP: Anker nicht gefunden - NICHTS geaendert. Bitte Ausgabe schicken."
  grep -n '^if __name__\|^app = Flask\|def classify_uplink' "$DASH" | head -10 || true
  exit 1
fi
cp -a "$W/work" "$W/work1"
python3 "$W/patch-uplink-detect.py" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
python3 -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert"

guard_snap() {
  python3 - "$1" << 'GPY'
import ast, pathlib, sys
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for k in ["update_all()  # einmal beim Start", "staleTsBoot", "strom14dChart", "navUnify", "gasLngSign",
          "lngColorFlip", "adsbMilThird", "keepLast", "pageFein", "meshBootQuiet", "mesh2OneSession",
          "starlinkUplink", "def classify_uplink("]:
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
echo "OK Guards dashboard.py unveraendert (Strompreis, Zeitstempel, keepLast, meshBootQuiet, mesh2, data_store)"

# Lesende Probe der echten Merkmale (nichts wird gesendet, kein sudo)
echo "--- Probe jetzt (nur lesen) ---"
( cd "$W/work" && timeout 60 python3 - << 'PROBE'
import uplink_detect as u
s = u.gather(); r, why = u.decide(s)
h, d, di, a = s["hop"], s["rdns"], s["dish"], s.get("asn") or {}
print("  Hop2      %s -> %s" % (h.get("ip"), h.get("vote") or "-"))
print("  DNS       %s -> %s" % (d.get("name"), d.get("vote") or "-"))
print("  Schuessel %s -> %s" % ("antwortet" if di.get("reachable") else "still", di.get("vote")))
print("  ASN       %s -> %s (nur Ergaenzung)" % (a.get("as"), a.get("vote") or "-"))
print("  IP        %s" % s.get("public_ip"))
print("  ERGEBNIS  %s (%s)" % (r, why))
PROBE
) || echo "WARN: Probe lief nicht durch (kein Abbruch)"
rm -f "$W/work/uplink_state.json"

# ---------- 2) Vorher-Stand HTTP ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
pre_root=$(code "$B/")
pre_pi=$(code -L --max-redirs 5 "$B/pi")
pre_funk=$(code -L --max-redirs 5 "$B/funk")
pre_en=$(code "$B/energie")
echo "vorher HTTP / =$pre_root /pi=$pre_pi /funk=$pre_funk /energie=$pre_en"

# ---------- 3) Installieren ----------
mod_same=0; dash_same=0
[[ -f "$MOD" ]] && cmp -s "$W/uplink_detect.py" "$MOD" && mod_same=1
cmp -s "$W/work/dashboard.py" "$DASH" && dash_same=1
if [[ "$mod_same" -eq 1 && "$dash_same" -eq 1 ]]; then
  need=0
  echo "OK uplinkDetect + uplinkHistory schon drin - nichts geaendert, kein Neustart"
  rollback() { echo "STOP (nichts geaendert): $1"; }
else
  need=1
  sudo -v
  had_mod=0
  cp -a "$DASH" "$DASH.bak-uplinkhist-$TS"
  if [[ -f "$MOD" ]]; then had_mod=1; cp -a "$MOD" "$MOD.bak-uplinkhist-$TS"; fi
  if [[ -f "$STATE" ]]; then cp -a "$STATE" "$STATE.bak-uplinkhist-$TS"; fi
  rollback() {
    echo "ROLLBACK uplinkHistory: $1"
    cp -a "$DASH.bak-uplinkhist-$TS" "$DASH"
    if [[ "$had_mod" -eq 1 ]]; then cp -a "$MOD.bak-uplinkhist-$TS" "$MOD"; else rm -f "$MOD"; fi
    sudo systemctl restart prepper-dashboard.service || true
    echo "dashboard.py + uplink_detect.py zurueck auf Backup, Dashboard neu gestartet. Mesh/Bridge unberuehrt."
  }
  cp "$W/uplink_detect.py" "$MOD"
  cp "$W/work/dashboard.py" "$DASH"
  python3 -m py_compile "$DASH" || { rollback "py_compile dashboard.py"; exit 1; }
  python3 -m py_compile "$MOD" || { rollback "py_compile uplink_detect.py"; exit 1; }
  g_now=$(guard_snap "$DASH")
  [[ "$g_now" == "$g_before" ]] || { rollback "Guards dashboard.py geaendert"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "OK installiert, Dashboard neu gestartet (Bridge NICHT)"
fi

# ---------- 4) Smoke Dashboard-Port ----------
echo "--- HTTP Dashboard :$PORT (nicht :8080 = Kiwix) ---"
root=""
for i in $(seq 1 80); do
  root=$("${CURL[@]}" -o "$W/root.html" -w "%{http_code}" "$B/" || true)
  [[ -z "$root" ]] && root=000
  [[ "$root" == "200" || "$root" == "500" ]] && break
  (( i % 10 == 1 )) && echo "warte auf Dashboard ... HTTP /=$root"
  sleep 3
done
[[ "$root" == "200" ]] || { rollback "HTTP / = $root"; exit 1; }
echo "OK HTTP / = 200"
grep -q 'data-uplinkdetect' "$W/root.html" || { rollback "Lage-Seite ohne Uplink-Anzeige"; exit 1; }
grep -q 'ping-value\|Internet' "$W/root.html" && echo "OK Lage-Seite: Uplink-Anzeige in Kachel Internet eingebaut" \
  || echo "WARN: Kachel Internet nicht gefunden - Anzeige haengt am Seitenende"
api=$(code "$B/api/uplink")
[[ "$api" == "200" ]] || { rollback "HTTP /api/uplink = $api"; exit 1; }
for path in pi funk; do
  pre_var="pre_$path"; pre="${!pre_var}"
  now=$(code -L --max-redirs 5 "$B/$path")
  if [[ "$now" != "200" ]]; then
    if [[ "$pre" == "200" ]]; then rollback "HTTP /$path = $now (vorher 200)"; exit 1; fi
    echo "WARN: HTTP /$path = $now, war schon vorher $pre (nicht von diesem Patch)"
  else
    echo "OK HTTP /$path = 200 (vorher $pre)"
  fi
done
pi=$("${CURL[@]}" -o "$W/pi.html" -w "%{http_code}" "$B/pi" || true)
if [[ "$pi" == "200" ]]; then
  grep -q 'data-uplinkhistory' "$W/pi.html" || { rollback "System-Seite /pi ohne Starlink-Verlauf"; exit 1; }
  grep -q 'Internet' "$W/pi.html" && echo "OK System-Seite: Starlink-Verlauf in Kachel Internet eingebaut" \
    || echo "WARN: Kachel Internet auf /pi nicht gefunden - Verlauf haengt am Seitenende"
fi
en=$(code "$B/energie")
if [[ "$pre_en" =~ ^[23] && ! "$en" =~ ^[23] ]]; then rollback "HTTP /energie = $en (vorher $pre_en)"; exit 1; fi
echo "OK HTTP /energie = $en (302 = Weiterleitung, ok)"

ok_s=0
for i in $(seq 1 30); do
  "${CURL[@]}" -o "$W/api.json" "$B/api/uplink" || true
  if python3 - "$W/api.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("marker") == "uplinkDetect" and d.get("thread") and d.get("last_check")
                 and "starlink_total" in d and d.get("version") == "uplinkDetect-2" else 1)
PY
  then ok_s=1; break; fi
  sleep 3
done
[[ "$ok_s" -eq 1 ]] || { rollback "/api/uplink: Thread prueft nicht"; exit 1; }
"${CURL[@]}" -o /dev/null "$B/api/uplink?refresh=1" || true
sleep 12
"${CURL[@]}" -o "$W/api.json" "$B/api/uplink" || true
python3 - "$W/api.json" << 'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("signals") or {}
h, r, di = s.get("hop") or {}, s.get("rdns") or {}, s.get("dish") or {}
pend = d.get("pending")
print("OK uplinkDetect laeuft: Anzeige jetzt: %s%s" % (d.get("text"), (" (Wechsel wird geprueft: %s)" % pend) if pend and pend != d.get("current") else ""))
print("  letzter Check %s: %s (%s)" % (d.get("last_check_str"), d.get("candidate"), d.get("reason")))
print("  Hop2 %s | DNS %s | Schuessel %s | IP %s" % (h.get("ip"), r.get("name"), "ja" if di.get("reachable") else "nein", d.get("public_ip")))
print("  classify_uplink ersetzt (System-Seite): %s" % ("ja" if d.get("had_classify") else "neu bereitgestellt"))
print("OK uplinkHistory: Starlink-Wechsel gesamt: %s" % d.get("starlink_total"))
for e in (d.get("starlink_events") or [])[:10]:
    print("  " + str(e.get("line")))
PY
sudo journalctl -u prepper-dashboard --since "-3min" --no-pager -o cat 2>/dev/null | grep -E 'uplinkDetect' | tail -6 || true

had() { grep -q "$1" "$DASH" && echo 1 || echo 0; }
echo "OK guards boot=$(grep -q 'update_all()  # einmal beim Start' "$DASH" && echo 1 || echo 0) staleTsBoot=$(had staleTsBoot) strom14dChart=$(had strom14dChart) navUnify=$(had navUnify) gasLngSign=$(had gasLngSign) lngColorFlip=$(had lngColorFlip) adsbMilThird=$(had adsbMilThird) keepLast=$(had keepLast) meshBootQuiet=$(had meshBootQuiet) uplinkDetect=$(had uplinkDetect) uplinkHistory=$(grep -q uplinkHistory "$MOD" && echo 1 || echo 0)"
if [[ "$need" -eq 1 ]]; then echo "Backup: $MOD.bak-uplinkhist-$TS (+ dashboard.py, uplink_state.json)"; fi
echo "OK uplinkHistory=1 fertig: System-Seite Kachel Internet zeigt Starlink-Wechsel gesamt + letzte 10"
echo "COMMIT $COMMIT_ARG uplinkDetect=1 uplinkHistory=1"
