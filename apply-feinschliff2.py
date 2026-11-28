#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-feinschliff2: Feinschliff Paket 2 - zentrale Seriennummern-Maskierung (nur dashboard.py, nur Dienst prepper-dashboard).

Ein letzter after_request-Haken (snMask) filtert jede Antwort (HTML, JSON, Text): bekannte Seriennummern (aus sdr_config.json,
sdr_status.json, sdr_serials.local.json, sdr_wd.json) werden zu 'Stick 1/2/3' bzw. 'Airspy R2' - auch im eingebetteten
sdrPiData-JSON im Quelltext (/, /pi, /aprs, /rundfunk, /funk), in title=-Texten und in JSON-Feldern. Unbekannte 'SN <hex>' und
"serial":"<hex>" werden allgemein erkannt. Ein kleines Browser-Skript raeumt zusammengesetzte Zeilen auf ('SN Stick 3 · ' faellt weg).
Die alten funkFlach-Regeln fuer Seriennummern (nur /funk) entfallen. Daten auf der Platte und prepper_sdr.py bleiben unveraendert
(prepper_sdr.py wird nicht angefasst, kein Neustart von prepper-sdr noetig).
Basis: dashboard.py 49314ffc (feinschliff1-Ergebnis). Selbsttest/Dry-run liefern bei jedem Fehler rc != 0.
Nach dem Schreiben: Neustart prepper-dashboard, bis 45 s HTTP 200, Pruefung aller Seiten und JSON-Antworten auf echte Seriennummern
(= 0 Treffer); bei Fehler Rueckbau aus dem Backup (rc != 0). Keine Zeitsperre.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "feinschliff2"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"

DASH_START_SHA = "49314ffcce89ccff3ede9dcaa13251b229efaab4ea33b5364e7ced712e1a3eb2"
DASH_START_BYTES = 1421681
DASH_END_SHA = "bfdd36d7dbb9691572b1e31536f4a364c66bfd92a3e04fc768af16508f4a7809"
DASH_END_BYTES = 1438615

MARKE = "# ===== snMask:"
# Seriennummern, die sicher keine Anzeige haben duerfen (zusaetzlich: alle aus den Konfigurationsdateien, inkl. Airspy)
FESTE_SN = ("26102403", "19348831", "72055505")


# ----------------------------------------------------------------- Baustein
SNM_BLOCK = r'''# ===== snMask: zentrale Seriennummern-Maskierung (feinschliff2) - nur Anzeige =====
# Ein einziger Haken (letzter after_request) filtert JEDE Antwort (HTML, JSON, Text): bekannte Seriennummern (aus sdr_config.json,
# sdr_status.json, sdr_serials.local.json, sdr_wd.json) werden durch 'Stick 1/2/3' bzw. 'Airspy R2' ersetzt - auch im eingebetteten
# sdrPiData-JSON im Quelltext, in title=-Texten und in JSON-Feldern (serial, sn, sn1..). Unbekannte Seriennummern in 'SN <hex>' /
# "serial":"<hex>" werden allgemein erkannt ('Stick'). Die Daten auf der Platte und die Logik (Rollenzuordnung, prepper_sdr)
# bleiben unveraendert; Zuordnungen im Browser bleiben stimmig, weil ueberall derselbe Name steht.
# Ein kleines Skript (Textknoten + title) raeumt die im Browser zusammengesetzten Zeilen auf ('SN Stick 3 · ' faellt weg, 'Stick SN Stick 1' -> 'Stick 1').
# Ersetzt die alten funkFlach-Regeln fuer Seriennummern (nur /funk). Kein Abruf, kein Senden, keine neue Schreib-Route.
import json as _snm_json
import os as _snm_os
import re as _snm_re
import time as _snm_time

_SNM = {"t": 0.0, "map": {}, "rx": None, "rx_num": None, "n": 0, "hits": 0, "err": None, "selftest": None, "quellen": 0}
_SNM_FILES = ("sdr_config.json", "sdr_status.json", "sdr_serials.local.json", "sdr_wd.json")
_SNM_FIELD_RE = _snm_re.compile(r'("(?:serial|usb_serial|serial_no|serialnumber|sn[0-9]{0,2})"\s*:\s*")([^"\\]{4,40})(")', _snm_re.I)
_SNM_TEXT_RE = _snm_re.compile(r'\b(SN|S/N|Seriennummer|Serial)([ :=#]{1,3})(?=[0-9A-F]*[0-9])([0-9A-F]{6,20})\b')
_SNM_HEX_RE = _snm_re.compile(r'^[0-9A-Fa-f]{6,20}$')
_SNM_LABEL = r"(?:Stick [0-9]+|Airspy(?: R2)?|Gerät)"
# Regeln fuers Skript im Browser (JS-Muster, Ersatz mit $1): Reihenfolge wichtig
_SNM_CLIENT_RULES = [
    [r"\b(Stick [0-9]+|Airspy(?: R2)?|Gerät) SN \1\b", "$1"],
    [r"Stick SN (?=" + _SNM_LABEL + ")", ""],
    [r" ?\(SN " + _SNM_LABEL + r"\)", ""],
    [r"SN " + _SNM_LABEL + " · ", ""],
    [r" · SN " + _SNM_LABEL, ""],
    [r"\bSN (?=" + _SNM_LABEL + ")", ""],
    [r"(?: · )?\b(?:SN|S/N) (?=[0-9A-F]*[0-9])[0-9A-F]{6,20}\b", ""],
]
_SNM_JS = r"""(function(){if(window.__snm)return;window.__snm=1;var R=__R__,SK={SCRIPT:1,STYLE:1,TEXTAREA:1},RE=[];
for(var i=0;i<R.length;i++)RE.push([new RegExp(R[i][0],'g'),R[i][1]]);
function fx(v){if(v.indexOf('SN')<0&&v.indexOf('S/N')<0)return v;for(var i=0;i<RE.length;i++)v=v.replace(RE[i][0],RE[i][1]);return v;}
function at(e){var a=['title','aria-label'];for(var i=0;i<a.length;i++){var v=e.getAttribute&&e.getAttribute(a[i]);if(v){var x=fx(v);if(x!==v)e.setAttribute(a[i],x);}}}
function all(r){if(!r)return;if(r.nodeType===3){var p=r.parentNode;if(p&&!SK[p.nodeName]){var v=r.nodeValue,x=fx(v);if(x!==v)r.nodeValue=x;}return;}
if(r.nodeType!==1||SK[r.nodeName])return;at(r);var w=document.createTreeWalker(r,4,null),n;while((n=w.nextNode())){var q=n.parentNode;if(!q||SK[q.nodeName])continue;var v2=n.nodeValue,x2=fx(v2);if(x2!==v2)n.nodeValue=x2;}
var L=r.querySelectorAll?r.querySelectorAll('[title],[aria-label]'):[];for(var j=0;j<L.length;j++)at(L[j]);}
function go(){all(document.body);}
if(document.body){go();var mo=new MutationObserver(function(ms){for(var i=0;i<ms.length;i++){var m=ms[i];if(m.type==='childList'){for(var j=0;j<m.addedNodes.length;j++)all(m.addedNodes[j]);}else if(m.type==='characterData'){all(m.target);}else if(m.type==='attributes'){at(m.target);}}mo.takeRecords();});
mo.observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['title','aria-label']});}})();"""


def _snm_safe_label(name):
    """Anzeigename nur uebernehmen, wenn er selbst keine Seriennummer enthaelt."""
    s = str(name or "").strip()
    if not s or len(s) > 24 or _snm_re.search(r"[0-9A-Fa-f]{6,}", s) or "SN" in s.split():
        return None
    return s


def _snm_build(base):
    """Zuordnung SERIENNUMMER(gross) -> Anzeigename aus den vorhandenen Dateien (nur lesen)."""
    m = {}

    def put(sn, label=None):
        sn = str(sn if sn is not None else "").strip().upper()
        if len(sn) < 6 or len(sn) > 24 or not sn.isalnum() or not any(ch.isdigit() for ch in sn):
            return
        lab = _snm_safe_label(label)
        if lab and (m.get(sn) in (None, "Stick")):
            m[sn] = lab
        elif sn not in m:
            m[sn] = "Stick"

    def load(name):
        try:
            with open(_snm_os.path.join(base, name), encoding="utf-8") as fh:
                return _snm_json.load(fh)
        except Exception:
            return None

    def walk(o, depth=0):
        if depth > 9:
            return
        if isinstance(o, dict):
            for k, v in o.items():
                ks = str(k)
                if _snm_re.fullmatch(r"(?i)serial|usb_serial|sn[0-9]?|stick[0-9]?_?sn", ks) and isinstance(v, (str, int)):
                    put(v)
                elif ks in ("others", "serials") and isinstance(v, list):
                    for x in v:
                        if isinstance(x, (str, int)):
                            put(x)
                elif _SNM_HEX_RE.match(ks) and any(ch.isdigit() for ch in ks) and len(ks) >= 8 and isinstance(v, (dict, list)):
                    put(ks)        # Schluessel wie in sdr_wd.json
                walk(v, depth + 1)
        elif isinstance(o, list):
            for x in o[:200]:
                walk(x, depth + 1)

    def devs(lst):
        if not isinstance(lst, list):
            return
        for d in lst:
            if not isinstance(d, dict) or not d.get("serial"):
                continue
            lab = d.get("name") or d.get("label")
            if not _snm_safe_label(lab) and str(d.get("kind") or d.get("product") or "").lower() == "airspy":
                lab = "Airspy R2"
            put(d.get("serial"), lab)

    cfg = load("sdr_config.json")
    st = load("sdr_status.json")
    loc = load("sdr_serials.local.json")
    wd = load("sdr_wd.json")
    n = 0
    for o in (cfg, st, loc, wd):
        if o is not None:
            n += 1
    if isinstance(cfg, dict):
        devs(cfg.get("devs"))
        for k, v in cfg.items():
            mm = _snm_re.fullmatch(r"stick([0-9]+)", str(k))
            if mm and isinstance(v, dict):
                put(v.get("serial"), "Stick " + mm.group(1))
    if isinstance(st, dict):
        devs(st.get("devs"))
        for x in (st.get("stick") or []):
            if isinstance(x, dict) and str(x.get("product") or "").lower() == "airspy":
                put(x.get("serial"), "Airspy R2")
    if isinstance(loc, dict):
        for k, v in loc.items():
            mm = _snm_re.fullmatch(r"stick([0-9]+)", str(k))
            if mm and isinstance(v, (str, int)):
                put(v, "Stick " + mm.group(1))
    for o in (cfg, st, loc, wd):
        if o is not None:
            walk(o)
    return m, n


def _snm_compile(m):
    toks = sorted((k for k in m if len(k) >= 6), key=lambda s: (-len(s), s))
    if not toks:
        return None, None
    alt = "|".join(_snm_re.escape(t) for t in toks)
    rx = _snm_re.compile(r"(?<![0-9A-Za-z])(?:%s)(?![0-9A-Za-z])" % alt, _snm_re.I)
    rx_num = _snm_re.compile(r"([:\[,]\s*)(?:%s)(?=\s*[,}\]])" % alt, _snm_re.I)
    return rx, rx_num


def _snm_state(force=False):
    now = _snm_time.time()
    if force or now - _SNM["t"] > 20:
        base = globals().get("_SDR_BASE") or _snm_os.path.dirname(_snm_os.path.abspath(__file__))
        m, n = _snm_build(base)
        _SNM["map"] = m
        _SNM["rx"], _SNM["rx_num"] = _snm_compile(m)
        _SNM["quellen"] = n
        _SNM["t"] = now
    return _SNM["map"], _SNM["rx"], _SNM["rx_num"]


def _snm_filter(text, m=None, rx=None, rx_num=None):
    """Seriennummern in text durch Namen ersetzen (Text, HTML oder JSON)."""
    if m is None:
        m, rx, rx_num = _snm_state()
    elif rx is None and rx_num is None:
        rx, rx_num = _snm_compile(m)
    out = text
    if rx_num is not None:      # JSON-Zahl ohne Anfuehrungszeichen -> Zeichenkette
        out = rx_num.sub(lambda mo: _snm_num_sub(mo, m), out)
    if rx is not None:
        out = rx.sub(lambda mo: m.get(mo.group(0).upper(), "Stick"), out)

    def fld(mo):
        v = mo.group(2)
        if _SNM_HEX_RE.match(v) and any(ch.isdigit() for ch in v):
            return mo.group(1) + m.get(v.upper(), "Stick") + mo.group(3)
        return mo.group(0)
    out = _SNM_FIELD_RE.sub(fld, out)
    out = _SNM_TEXT_RE.sub(lambda mo: mo.group(1) + mo.group(2) + m.get(mo.group(3).upper(), "Stick"), out)
    return out


def _snm_num_sub(mo, m):
    core = mo.group(0)[len(mo.group(1)):]
    return mo.group(1) + '"' + m.get(core.strip().upper(), "Stick") + '"'


def _snm_js():
    return _SNM_JS.replace("__R__", _snm_json.dumps(_SNM_CLIENT_RULES, ensure_ascii=False).replace("</", "<\\/"))


def _snm_inject(html):
    if 'id="snm-js"' in html:
        return html
    k = html.rfind("</body>")
    if k < 0:
        return html
    return html[:k] + '<script id="snm-js">' + _snm_js() + "</script>" + html[k:]


def _snm_after(resp):
    try:
        if resp.direct_passthrough or resp.headers.get("Content-Encoding"):
            return resp
        mt = resp.mimetype or ""
        if not (mt in ("text/html", "application/json", "text/plain") or mt.endswith("javascript")):
            return resp
        body = resp.get_data(as_text=True)
        if len(body) > 8000000:
            return resp
        nb = _snm_filter(body)
        if mt == "text/html":
            nb = _snm_inject(nb)
        _SNM["n"] += 1
        if nb != body:
            resp.set_data(nb)
            _SNM["hits"] += 1
    except Exception as e:
        if not _SNM["err"]:
            print("snMask Haken:", type(e).__name__, str(e)[:120], flush=True)
        _SNM["err"] = "%s: %s" % (type(e).__name__, str(e)[:120])
    return resp


def _snm_api():
    from flask import jsonify
    m, _rx, _rn = _snm_state()
    return jsonify({"aktiv": True, "namen": sorted(set(m.values())), "anzahl": len(m), "quellen": _SNM["quellen"],
                    "antworten": _SNM["n"], "geaendert": _SNM["hits"], "fehler": _SNM["err"]})


def _snm_hook():
    if "app" not in globals():
        return 0
    n = 0
    funcs = app.after_request_funcs.setdefault(None, [])
    funcs[:] = [f for f in funcs if getattr(f, "__name__", "") != "_snm_after"]
    funcs.insert(0, _snm_after)        # Index 0 laeuft zuletzt: sieht die fertige Antwort aller anderen Haken
    n += 1
    if "snm_api" not in getattr(app, "view_functions", {}) and not any(r.rule == "/api/snmask" for r in app.url_map.iter_rules()):
        app.add_url_rule("/api/snmask", endpoint="snm_api", view_func=_snm_api, methods=["GET"])
        n += 1
    return n


def _snm_js_sim(text):
    """Die Browser-Regeln in Python nachgespielt (Ersatz $1 -> \\1)."""
    for pat, rp in _SNM_CLIENT_RULES:
        text = _snm_re.sub(pat, _snm_re.sub(r"\$([0-9])", r"\\\1", rp), text)
    return text


def _snm_selftest():
    import tempfile
    import shutil
    tmp = tempfile.mkdtemp(prefix="snm-")
    try:
        with open(_snm_os.path.join(tmp, "sdr_config.json"), "w", encoding="utf-8") as fh:
            _snm_json.dump({"serial": "11112222", "stick2": {"serial": "33334444"},
                            "devs": [{"name": "Airspy R2", "kind": "airspy", "serial": "AB12CD34EF560099"},
                                     {"name": "Stick 1", "kind": "rtl", "serial": "11112222"},
                                     {"name": "Stick 2", "kind": "rtl", "serial": "33334444"},
                                     {"name": "RTL-Stick SN 55556666", "kind": "rtl", "serial": "55556666"}]}, fh)
        with open(_snm_os.path.join(tmp, "sdr_status.json"), "w", encoding="utf-8") as fh:
            _snm_json.dump({"sn": "AB12CD34EF560099", "dual": {"sn3": "55556666", "sn9": "77778888"}, "others": ["99990000"],
                            "stick": [{"product": "AIRSPY", "serial": "AB12CD34EF560099"}]}, fh)
        with open(_snm_os.path.join(tmp, "sdr_wd.json"), "w", encoding="utf-8") as fh:
            _snm_json.dump({"sticks": {"33334444": {"n": 1}}}, fh)
        m, n = _snm_build(tmp)
        assert n == 3, n
        assert m["AB12CD34EF560099"] == "Airspy R2" and m["11112222"] == "Stick 1" and m["33334444"] == "Stick 2", m
        assert m["55556666"] == "Stick" and m["77778888"] == "Stick" and m["99990000"] == "Stick", m          # Name mit SN wird nicht uebernommen
        assert "55556666" not in " ".join(m.values())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # JSON: gueltig bleiben, Zahlen ohne Anfuehrungszeichen, Schluessel, Felder, Text
    j = ('{"serial":"AB12CD34EF560099","sn1":"ab12cd34ef560099","n":11112222,"l":[33334444, 99990000],"wd":{"33334444":{"n":1}},'
         '"t":"Stick SN 11112222 (Index 0)","x":"serial 55556666 ok","u":"unbekannt","sn":"ABCDEF0123456789","z":"SNR 10 dB 12345678"}')
    o = _snm_filter(j, m)
    d = _snm_json.loads(o)
    assert d["serial"] == "Airspy R2" and d["sn1"] == "Airspy R2" and d["n"] == "Stick 1" and d["l"] == ["Stick 2", "Stick"], d
    assert "Stick 2" in d["wd"] and d["t"] == "Stick SN Stick 1 (Index 0)" and d["x"] == "serial Stick ok", d
    assert d["sn"] == "Stick" and d["z"] == "SNR 10 dB 12345678" and d["u"] == "unbekannt", d
    for echt in ("11112222", "33334444", "55556666", "AB12CD34EF560099", "ABCDEF0123456789"):
        assert echt.lower() not in o.lower(), echt
    # HTML: sdrPiData im Quelltext, title=, Text
    h = ('<html><head></head><body><div title="Stick mit SN 33334444 · Liste">SN 11112222 · fest 11D</div>'
         '<script type="application/json" id="sdrPiData">{"status":{"serial":"AB12CD34EF560099","devs":[{"serial":"11112222"}]}}</script>'
         '<script>var a="serial";</script></body></html>')
    ho = _snm_inject(_snm_filter(h, m))
    for echt in ("11112222", "33334444", "AB12CD34EF560099"):
        assert echt not in ho, echt
    assert 'title="Stick mit SN Stick 2 · Liste"' in ho and "SN Stick 1 · fest 11D" in ho, ho
    assert _snm_json.loads(ho.split('id="sdrPiData">')[1].split("</script>")[0])["status"]["serial"] == "Airspy R2"
    assert ho.count('id="snm-js"') == 1 and _snm_inject(ho) == ho and _snm_inject("kein body") == "kein body"
    js = _snm_js()
    for bad in ("fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", ".click(", "submit", "location", "eval(", "localStorage", "/api/"):
        assert bad not in js, bad
    # Browser-Regeln (Texte, die das Dashboard im Browser zusammensetzt)
    s = _snm_js_sim
    assert s("🔌 Stick SN Stick 1 (Index 0) · 2 Sticks") == "🔌 Stick 1 (Index 0) · 2 Sticks", s("🔌 Stick SN Stick 1 (Index 0) · 2 Sticks")
    assert s("SN Stick 3 · USB 0bda:2838 · Hobby – nur Beobachtung") == "USB 0bda:2838 · Hobby – nur Beobachtung"
    assert s("weitere: SN Stick 2, Stick 3. Liste: sudo prepper-sdr-sticks") == "weitere: Stick 2, Stick 3. Liste: sudo prepper-sdr-sticks"
    assert s("Hobby · 433 fest · SN Stick 2") == "Hobby · 433 fest" and s("läuft auf Stick 2 (SN Stick 2)") == "läuft auf Stick 2"
    assert s("Stick 3 SN Stick 3") == "Stick 3" and s("erkannt: Airspy R2 SN Airspy R2 ok") == "erkannt: Airspy R2 ok"
    assert s("Stick 1 · SN 12345678 · 5C") == "Stick 1 · 5C" and s("SNR 10,0 dB · SN 12 · SNR") == "SNR 10,0 dB · SN 12 · SNR"
    # Haken: laeuft zuletzt, stoert keine Antwort
    try:
        from flask import Flask
        a = Flask("snm_test")
        a.config["TESTING"] = True

        @a.route("/t")
        def _t():
            return h

        @a.route("/j")
        def _j():
            from flask import jsonify
            return jsonify({"serial": "AB12CD34EF560099"})

        @a.route("/b")
        def _b():
            from flask import Response
            return Response(b"\x00\x01" + b"11112222", mimetype="application/octet-stream")
        a.after_request_funcs.setdefault(None, []).insert(0, lambda r: r)
        old = (dict(_SNM["map"]), _SNM["rx"], _SNM["rx_num"], _SNM["t"])
        try:
            _SNM["map"], (_SNM["rx"], _SNM["rx_num"]), _SNM["t"] = dict(m), _snm_compile(m), _snm_time.time()
            a.after_request_funcs[None].insert(0, _snm_after)
            c = a.test_client()
            r1 = c.get("/t").get_data(as_text=True)
            assert "11112222" not in r1 and 'id="snm-js"' in r1
            r2 = c.get("/j")
            assert r2.get_json()["serial"] == "Airspy R2"
            assert c.get("/b").get_data() == b"\x00\x01" + b"11112222"          # Binaer bleibt unberuehrt
        finally:
            _SNM["map"], _SNM["rx"], _SNM["rx_num"], _SNM["t"] = old
    except ImportError:
        pass
    return "snMask ok (Namen aus Konfiguration, JSON bleibt gueltig, sdrPiData/title/Text, Browser-Regeln, Haken)"


try:
    _SNM["selftest"] = _snm_selftest()
except Exception as _snm_e:
    _SNM["selftest"] = "FEHLER: %s: %s" % (type(_snm_e).__name__, _snm_e)
    print("snMask Selbsttest FEHLER:", _SNM["selftest"], flush=True)
_snm_n = 0
try:
    _snm_n = _snm_hook()      # Haken immer setzen: nie vom Selbsttest abhaengig
    _snm_state(True)
except Exception as _snm_he:
    print("snMask FEHLER Haken:", type(_snm_he).__name__, _snm_he, flush=True)
print("snMask aktiv: letzter after_request, %d Namen aus %s Dateien, Hooks=%s; %s" % (len(_SNM["map"]), _SNM["quellen"], _snm_n, _SNM["selftest"]), flush=True)
# ===== /snMask =====
'''


def sha256(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def stand(data):
    return sha256(data), len(data)


def berlin_jetzt():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin"))
    return datetime.now()


class Stop(Exception):
    pass


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise Stop("STOP %s: Anker %d mal gefunden, erwartet %d" % (name, c, n))
    return text.replace(alt, neu)


def scheibe_ersetzen(text, start, ende, neu, name):
    """Text von start (inklusive) bis ende (inklusive) durch neu ersetzen; beide Anker genau einmal."""
    if text.count(start) != 1:
        raise Stop("STOP %s: Startanker %d mal" % (name, text.count(start)))
    i = text.find(start)
    j = text.find(ende, i)
    if j < 0 or text.count(ende) != 1:
        raise Stop("STOP %s: Endanker %d mal" % (name, text.count(ende)))
    return text[:i] + neu + text[j + len(ende):]



# ----------------------------------------------------------------- Anker
A_FF_ALT = (
    '    ("/funk", "body", "t", r" ?\\(SN [0-9A-F]{6,20}\\)", ""),\n'
    '    ("/funk", "body", "t", r"SN [0-9A-F]{6,20} · ", ""),\n'
    '    ("/funk", "body", "t", r" · SN [0-9A-F]{6,20}", ""),\n'
)
A_FFC_ALT = "# Sichtbare Seriennummern auf /funk werden ausgeblendet (Rollen bleiben). Karte: Tabelle oben untereinander statt breiter als der Bildschirm.\n"
A_FFC_NEU = "# Seriennummern: seit snMask (feinschliff2) zentral fuer alle Seiten, hier keine Regeln mehr. Karte: Tabelle oben untereinander statt breiter als der Bildschirm.\n"
A_FFT_ALT = (
    '    assert tx("/funk", "body", "SN 0000ABCD · fest 11D (BR Bayern)") == "fest 11D (BR Bayern)"\n'
    '    assert tx("/funk", "body", "Hobby · 433 fest · SN 0000ABCD") == "Hobby · 433 fest" and tx("/funk", "body", "läuft auf Stick 2 (SN 0000ABCD)") == "läuft auf Stick 2"\n'
)
A_END_USBW = "# ===== /usbwache3 =====\n"


def patch_dash(text):
    if schon(text):
        return text
    if A_END_USBW not in text or "def _usbw_selftest_inner(" not in text:
        raise Stop("STOP Basis feinschliff1 erwartet (usbwache3-Ende fehlt)")
    t = ersetze(text, A_FF_ALT, "", "funkFlach SN-Regeln")
    t = ersetze(t, A_FFC_ALT, A_FFC_NEU, "funkFlach Kommentar")
    t = ersetze(t, A_FFT_ALT, "", "funkFlach Selbsttest SN")
    t = ersetze(t, A_END_USBW, A_END_USBW + "\n" + SNM_BLOCK, "snMask Block")
    if not schon(t):
        raise Stop("STOP Markierungen nach dem Patch unvollstaendig")
    return t


def schon(text):
    return (
        MARKE in text
        and "def _snm_after(" in text
        and 'r" ?\\(SN [0-9A-F]{6,20}\\)"' not in text
        and "\n# ===== /snMask =====\n" in text
    )


def berechne_dash(pfad):
    if not os.path.isfile(pfad):
        raise Stop("STOP %s fehlt" % pfad)
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("dashboard.py sha16 %s bytes %d" % (ist[:16], n))
    if ist == DASH_END_SHA and n == DASH_END_BYTES:
        return alt, None
    if not (ist == DASH_START_SHA and n == DASH_START_BYTES):
        raise Stop("STOP dashboard.py Hash %s/%d, erwartet %s/%d (feinschliff1-Stand) oder Endstand %s/%d" % (
            ist[:16], n, DASH_START_SHA[:16], DASH_START_BYTES, DASH_END_SHA[:16], DASH_END_BYTES))
    neu = patch_dash(alt.decode("utf-8")).encode("utf-8")
    hs, ns = stand(neu)
    if hs != DASH_END_SHA or ns != DASH_END_BYTES:
        raise Stop("STOP dashboard.py Endhash %s/%d, erwartet %s/%d" % (hs[:16], ns, DASH_END_SHA[:16], DASH_END_BYTES))
    compile(neu, "dashboard.py", "exec")
    return alt, neu


def sichern(pfad, stempel):
    ziel = "%s.bak-%s-%s" % (pfad, KENNUNG, stempel)
    shutil.copy2(pfad, ziel)
    ordner = os.path.dirname(pfad) or "."
    name = os.path.basename(pfad) + ".bak-" + KENNUNG + "-"
    alte = sorted(p for p in os.listdir(ordner) if p.startswith(name))
    for p in alte[:-3]:
        try:
            os.remove(os.path.join(ordner, p))
        except OSError:
            pass
    return ziel


def schreibe(pfad, daten):
    st = os.stat(pfad) if os.path.exists(pfad) else None
    tmp = pfad + ".%s-tmp" % KENNUNG
    with open(tmp, "wb") as handle:
        handle.write(daten)
        handle.flush()
        os.fsync(handle.fileno())
    if st is not None:
        shutil.copymode(pfad, tmp)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except OSError:
            pass
    os.replace(tmp, pfad)
    if st is not None:
        try:
            os.chown(pfad, st.st_uid, st.st_gid)
            os.chmod(pfad, stat.S_IMODE(st.st_mode))
        except OSError as exc:
            print("Hinweis: Besitzer/Modus %s nicht gesetzt (%s)" % (pfad, exc))


def pyflakes_datei(pfad):
    for cmd in (["pyflakes", pfad], ["python3", "-m", "pyflakes", pfad]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            continue
        err = (r.stderr or "") + (r.stdout or "")
        if "No module named" in err or "command not found" in err:
            continue
        if r.returncode == 0 and not err.strip():
            print("pyflakes %s ok" % os.path.basename(pfad))
            return True
        print("pyflakes %s:\n%s" % (os.path.basename(pfad), err.strip()[:800]))
        return False
    print("Hinweis: pyflakes nicht installiert, nur compile")
    return True


def _unit_snap(dienst):
    snap = {"pid": "", "ts": "", "active": ""}
    try:
        r = subprocess.run(["systemctl", "show", dienst, "-p", "MainPID", "-p", "ActiveEnterTimestamp", "-p", "ActiveState"],
                           capture_output=True, text=True, timeout=8)
        for ln in (r.stdout or "").splitlines():
            if "=" not in ln:
                continue
            k, v = ln.split("=", 1)
            if k == "MainPID":
                snap["pid"] = v.strip()
            elif k == "ActiveEnterTimestamp":
                snap["ts"] = v.strip()
            elif k == "ActiveState":
                snap["active"] = v.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return snap


def _restart_ok(rc, before, after):
    if rc != 0:
        return False
    if after.get("active") in ("failed", "inactive", "deactivating"):
        return False
    if before.get("pid") and after.get("pid") and before["pid"] != "0" and after["pid"] == before["pid"]:
        if before.get("ts") and after.get("ts") and before["ts"] == after["ts"]:
            return False
    if after.get("active") in ("active", "activating", "reloading"):
        return True
    if not after.get("active") and not before.get("active") and rc == 0:
        return True
    return after.get("active") == "active"


def restart_dienst(dienst):
    before = _unit_snap(dienst)
    try:
        rc = subprocess.call(["systemctl", "restart", dienst])
    except OSError:
        rc = 127
    after = _unit_snap(dienst)
    if _restart_ok(rc, before, after):
        print("restart %s rc %s" % (dienst, rc))
        return 0
    try:
        rc2 = subprocess.call(["sudo", "systemctl", "restart", dienst])
    except OSError:
        rc2 = 127
    after = _unit_snap(dienst)
    if _restart_ok(rc2, before, after):
        print("restart %s rc %s (sudo)" % (dienst, rc2))
        return 0
    gesehen = rc2 if rc2 != 0 else rc
    print("STOP Neustart fehlgeschlagen - bitte sudo systemctl restart %s" % dienst)
    print("systemctl rc %s, Zustand %s PID %s -> %s" % (gesehen, after.get("active") or "?", before.get("pid") or "-", after.get("pid") or "-"))
    return gesehen if gesehen != 0 else 1


# ----------------------------------------------------------------- Pruefung am laufenden Dienst
URL = "http://127.0.0.1:5000"


def _get(pfad, timeout=6):
    """(Statuscode als str, Body) ueber curl; Fehler -> ('000', '')."""
    ziel = tempfile.mktemp(prefix="apply-feinschliff1-")
    try:
        r = subprocess.run(["curl", "-sS", "-m", str(timeout), "-o", ziel, "-w", "%{http_code}", URL + pfad],
                           capture_output=True, text=True, timeout=timeout + 3)
        code = (r.stdout or "").strip() or "000"
        body = ""
        if os.path.isfile(ziel):
            body = open(ziel, encoding="utf-8", errors="replace").read()
        return code, body
    except (OSError, subprocess.TimeoutExpired):
        return "000", ""
    finally:
        try:
            os.remove(ziel)
        except OSError:
            pass


def warte_200(pfade, timeout=45):
    t0 = time.time()
    offen = list(pfade)
    seiten = {}
    while offen and time.time() - t0 < timeout:
        noch = []
        for p in offen:
            code, body = _get(p)
            if code == "200":
                print("GET %s -> 200 nach %.1f s" % (p, time.time() - t0))
                seiten[p] = body
            else:
                noch.append(p)
        offen = noch
        if offen:
            time.sleep(2)
    for p in offen:
        print("STOP %s nicht 200 innerhalb %s s" % (p, timeout))
    return (not offen), seiten


def echte_seriennummern(root):
    """Alle Seriennummern aus den Konfigurations-/Statusdateien plus die festen. Werte werden nie ausgegeben."""
    sns = set(FESTE_SN)

    def walk(o, d=0):
        if d > 9:
            return
        if isinstance(o, dict):
            for k, v in o.items():
                ks = str(k)
                if re.fullmatch(r"(?i)serial|usb_serial|sn[0-9]?|stick[0-9]?_?sn", ks) and isinstance(v, (str, int)):
                    sns.add(str(v).strip())
                elif ks in ("others", "serials") and isinstance(v, list):
                    sns.update(str(x).strip() for x in v if isinstance(x, (str, int)))
                elif re.fullmatch(r"[0-9A-Fa-f]{8,20}", ks) and any(c.isdigit() for c in ks) and isinstance(v, (dict, list)):
                    sns.add(ks)
                if isinstance(ks, str) and re.fullmatch(r"stick[0-9]+", ks) and isinstance(v, (str, int)):
                    sns.add(str(v).strip())
                walk(v, d + 1)
        elif isinstance(o, list):
            for x in o[:200]:
                walk(x, d + 1)

    for name in ("sdr_config.json", "sdr_status.json", "sdr_serials.local.json", "sdr_wd.json"):
        try:
            with open(os.path.join(root, name), encoding="utf-8") as fh:
                walk(json.load(fh))
        except Exception:
            pass
    return sorted(s for s in sns if len(s) >= 6 and any(c.isdigit() for c in s) and re.fullmatch(r"[0-9A-Za-z]+", s))


def sn_treffer(text, sns):
    return sum(1 for s in sns if re.search(r"(?<![0-9A-Za-z])" + re.escape(s) + r"(?![0-9A-Za-z])", text, re.I))


SEITEN_KERN = ["/", "/pi", "/system", "/umwelt", "/aprs", "/rundfunk", "/funk"]
SEITEN_MEHR = ["/energie", "/lokale-energie", "/speicher", "/luft", "/pegel", "/adsb", "/zuhause", "/mesh", "/mesh2", "/news",
               "/karte", "/medizin", "/funk433", "/meteor", "/dabhist", "/lage"]
API_LESEN = ["/api/sdr/status", "/api/sdr/ui", "/api/sdr/wd", "/api/sdr/live", "/api/broadcast", "/api/t2/status", "/api/t4/status",
             "/api/sdr/usbw", "/api/snmask", "/api/aprs", "/api/funk433", "/api/sdr/activity", "/api/sdr/noise", "/api/uplink",
             "/api/inet_split", "/api/broadcast/events"]


def pruefe_live(seit, root=BASIS):
    ok, seiten = warte_200(SEITEN_KERN + ["/api/sdr/status", "/api/snmask", "/api/inet_split"], 45)
    if not ok:
        return False
    sns = echte_seriennummern(root)
    print("geprueft gegen %d Seriennummern (inkl. Airspy aus der Konfiguration)" % len(sns))
    gesamt = 0
    n_ok = 0
    for p in SEITEN_KERN + SEITEN_MEHR + API_LESEN:
        if p in seiten:
            code, body = "200", seiten[p]
        else:
            code, body = _get(p, 12)
        if code != "200":
            if p in SEITEN_KERN:
                print("STOP %s -> %s" % (p, code))
                ok = False
            continue
        n_ok += 1
        seiten[p] = body
        t = sn_treffer(body, sns)
        gesamt += t
        if t:
            print("STOP %s enthaelt noch %d echte Seriennummer(n)" % (p, t))
            ok = False
    print("%d Seiten/Antworten geprueft, echte Seriennummern: %d" % (n_ok, gesamt))
    for p in ("/", "/pi", "/funk", "/rundfunk", "/aprs"):
        if 'id="snm-js"' not in seiten.get(p, ""):
            print("STOP %s ohne Maskierungs-Skript snm-js" % p)
            ok = False
    for p in ("/", "/pi", "/funk", "/rundfunk", "/aprs"):
        mm = re.search(r'id="sdrPiData">(.*?)</script>', seiten.get(p, ""), re.S)
        if mm:
            try:
                json.loads(mm.group(1))
                print("sdrPiData auf %s: gueltiges JSON, ohne echte Seriennummer" % p)
            except ValueError:
                print("STOP sdrPiData auf %s ist kein gueltiges JSON" % p)
                ok = False
    try:
        st = json.loads(seiten.get("/api/sdr/status") or "null")
        if not (isinstance(st, dict) and "status" in st):
            raise ValueError("Schluessel status fehlt")
        sm = json.loads(seiten.get("/api/snmask") or "null")
        if not (isinstance(sm, dict) and sm.get("aktiv") is True and not sm.get("fehler")):
            raise ValueError("snmask %s" % (sm,))
        if len(sns) > len(FESTE_SN) and sm.get("anzahl", 0) < 1:
            raise ValueError("keine Namen aus der Konfiguration geladen")
        print("/api/snmask ok: %s Namen (%s), %s Antworten gefiltert" % (sm.get("anzahl"), ", ".join(sm.get("namen") or []), sm.get("antworten")))
    except Exception as exc:
        print("STOP /api/sdr/status oder /api/snmask: %s" % exc)
        ok = False
    for p in ("/pi", "/system"):
        if 'id="usbwBox"' not in seiten.get(p, ""):
            print("STOP %s ohne usbwBox" % p)
            ok = False
    for p in ("/umwelt2", "/decoder", "/scanner"):
        code, _ = _get(p)
        if code != "404":
            print("STOP %s liefert %s, erwartet 404" % (p, code))
            ok = False
    try:
        r = subprocess.run(["journalctl", "-u", DIENST, "--since", seit, "-o", "cat", "-n", "400"],
                           capture_output=True, text=True, timeout=15)
        zeilen = (r.stdout or "").splitlines()
        if any("Traceback" in ln for ln in zeilen):
            print("STOP Journal %s enthaelt Traceback" % DIENST)
            for ln in [x for x in zeilen if "Traceback" in x][:6]:
                print(ln)
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (DIENST, len(zeilen)))
        for pflicht in ("snMask aktiv:", "funkFlach aktiv:", "inetSplit aktiv", "usbwache Anzeige:"):
            if not any(pflicht in ln for ln in zeilen):
                print("STOP Journal ohne Zeile '%s'" % pflicht)
                ok = False
        if any(x in ln for ln in zeilen for x in ("snMask Selbsttest FEHLER", "snMask FEHLER", "snMask Haken", "funkFlach FEHLER")):
            print("STOP Journal meldet snMask-/funkFlach-FEHLER")
            ok = False
    except (OSError, subprocess.TimeoutExpired):
        print("STOP Journal %s unlesbar" % DIENST)
        ok = False
    return ok


def anwenden(root, dry, kein):
    dash = os.path.join(root, "dashboard.py")
    try:
        alt, neu = berechne_dash(dash)
    except Stop as exc:
        print(exc)
        return 2
    except SyntaxError as exc:
        print("STOP Syntaxfehler im Ergebnis: %s" % exc)
        return 3
    if neu is None:
        print("dashboard.py bereits auf Endstand, unveraendert")
        return 0
    if dry:
        print("dry-run dashboard.py %d -> %d Bytes sha256 %s" % (len(alt), len(neu), sha256(neu)))
        print("dry-run: keine Datei geschrieben, kein Neustart")
        return 0
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    bak = sichern(dash, stempel)
    print("Backup %s" % bak)
    schreibe(dash, neu)
    hs, ns = stand(open(dash, "rb").read())
    print("geschrieben dashboard.py sha256 %s bytes %d" % (hs, ns))
    if hs != DASH_END_SHA or ns != DASH_END_BYTES:
        print("STOP geschriebene Datei weicht ab - Rueckbau")
        schreibe(dash, alt)
        return 4
    if not pyflakes_datei(dash):
        print("STOP pyflakes dashboard.py - Rueckbau")
        schreibe(dash, alt)
        return 4
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = restart_dienst(DIENST)
    if rc != 0:
        rueckbau(dash, alt)
        return rc
    if not pruefe_live(seit, root):
        print("STOP Pruefung fehlgeschlagen - Rueckbau auf %s" % bak)
        rueckbau(dash, alt)
        return 5
    print("ok, Dienst: %s" % DIENST)
    return 0


def rueckbau(dash, alt):
    try:
        schreibe(dash, alt)
        print("ZURUECKGESETZT dashboard.py sha256 %s" % stand(alt)[0])
        rc = restart_dienst(DIENST)
        if rc == 0:
            warte_200(["/", "/pi"], 45)
    except Exception as exc:
        print("Rueckbau-Fehler: %s - bitte Backup .bak-%s-* von Hand zurueckkopieren" % (exc, KENNUNG))


# ----------------------------------------------------------------- Selbsttest
def _selftest_restart_check():
    assert _restart_ok(1, {"pid": "1", "ts": "a", "active": "active"}, {"pid": "2", "ts": "b", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "10", "ts": "A", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "11", "ts": "B", "active": "active"}) is True
    print("selftest Neustart-Check ok")


def _selftest_snm():
    ns = {"__name__": "snmtest", "__file__": os.path.join(tempfile.gettempdir(), "dashboard.py")}
    code = SNM_BLOCK.replace("\n_snm_n = 0\ntry:\n    _snm_n = _snm_hook()", "\n_snm_n = 0\ntry:\n    _snm_n = 0 and _snm_hook()")
    exec(compile(code, "snMask-block", "exec"), ns)
    assert str(ns["_SNM"]["selftest"]).startswith("snMask ok"), ns["_SNM"]["selftest"]
    f = ns["_snm_filter"]
    m = {"11112222": "Stick 1", "AB12CD34EF560099": "Airspy R2"}
    assert "11112222" not in f('{"a": 11112222, "b": ["AB12CD34EF560099"]}', m)
    assert json.loads(f('{"a": 11112222, "b": ["AB12CD34EF560099"], "c": 11112222}', m)) == {"a": "Stick 1", "b": ["Airspy R2"], "c": "Stick 1"}
    assert f("Serial: 0A1B2C3D4E5F6071 bleibt nicht", m) == "Serial: Stick bleibt nicht"
    assert f("nichts zu tun 123 SNR 12.5", m) == "nichts zu tun 123 SNR 12.5"
    # leere Zuordnung: allgemeine Regeln greifen trotzdem
    assert f('{"serial":"ABCD1234EF"}', {}) == '{"serial":"Stick"}' and f("SN 55556666 x", {}) == "SN Stick x"
    # leere Zuordnung blockiert nichts
    assert f("kein Treffer", {}) == "kein Treffer"
    print("selftest snMask ok (Namen, JSON gueltig, sdrPiData/title/Text, Browser-Regeln, Haken)")


def _selftest_patch(text):
    t = patch_dash(text)
    assert patch_dash(t) == t, "patch nicht idempotent"
    compile(t, "dashboard.py", "exec")
    assert 'r" ?\\(SN [0-9A-F]{6,20}\\)"' not in t and "SN 0000ABCD" not in t
    assert t.count("def _snm_after(") == 1 and t.count("# ===== snMask:") == 1 and t.count("\n# ===== /snMask =====\n") == 1
    i_main = t.find('if __name__ == "__main__":\n    # sourceWatch final')
    assert 0 < t.find("# ===== /usbwache3 =====") < t.find(MARKE) < i_main, "snMask muss nach usbwache3 und VOR __main__ stehen"
    assert t.count("def _usbw_selftest_inner(") == 1 and "def _inet_split(" in t and '@app.route("/umwelt2")' not in t
    # funkFlach-Block mit den entfernten Regeln: Selbsttest laeuft weiter
    a = t.find("# ===== funkFlach (commit61)")
    b = t.find("# ===== /funkFlach =====")
    assert 0 < a < b
    ns = {"__name__": "fftest"}
    exec(compile(t[a:b], "funkFlach-block", "exec"), ns)
    assert str(ns["_FF"]["selftest"]).startswith("funkFlach ok"), ns["_FF"]["selftest"]
    assert not any(" SN " in r[3] or r[2].startswith("SN") or "SN [" in r[3] for r in ns["_FF_RULES"] if isinstance(r[3], str) and r[1] == "body")
    print("selftest funkFlach ok (ohne alte SN-Regeln)")
    return t


def selftest(basis=BASIS):
    try:
        _selftest_restart_check()
        _selftest_snm()
        dash = os.path.join(basis, "dashboard.py")
        if not os.path.isfile(dash):
            print("STOP %s fehlt" % dash)
            return 1
        raw = open(dash, "rb").read()
        ist, n = stand(raw)
        if ist == DASH_END_SHA and n == DASH_END_BYTES:
            text = raw.decode("utf-8")
            assert schon(text)
            print("selftest: dashboard.py steht schon auf dem Endstand")
            _selftest_patch(text)
        elif ist == DASH_START_SHA and n == DASH_START_BYTES:
            t = _selftest_patch(raw.decode("utf-8"))
            hs, ns_ = stand(t.encode("utf-8"))
            assert hs == DASH_END_SHA and ns_ == DASH_END_BYTES, "Endhash %s/%d" % (hs[:16], ns_)
            tmp = tempfile.mkdtemp(prefix="feinschliff2-st-")
            try:
                shutil.copy2(dash, os.path.join(tmp, "dashboard.py"))
                rc = anwenden(tmp, False, True)
                assert rc == 0, "anwenden rc %s" % rc
                assert stand(open(os.path.join(tmp, "dashboard.py"), "rb").read()) == (DASH_END_SHA, DASH_END_BYTES)
                assert anwenden(tmp, False, True) == 0
                assert any(p.startswith("dashboard.py.bak-" + KENNUNG) for p in os.listdir(tmp))
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
            print("selftest apply auf Kopie ok (Backup, Endhash, zweiter Lauf ohne Aenderung)")
        else:
            print("STOP selftest: dashboard.py %s/%d ist weder feinschliff1-Stand noch Endstand" % (ist[:16], n))
            return 1
    except (AssertionError, Stop, SyntaxError, KeyError, ValueError, TypeError, IndexError) as exc:
        import traceback
        traceback.print_exc()
        print("STOP selftest FEHLER: %s" % exc)
        return 1
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    args = parser.parse_args(argv)
    try:
        if args.selftest:
            return selftest(args.basis)
        return anwenden(args.basis, args.dry_run, args.kein_neustart)
    except Exception as exc:
        print("STOP unerwarteter Fehler: %s: %s" % (type(exc).__name__, exc))
        return 9


if __name__ == "__main__":
    sys.exit(main())
