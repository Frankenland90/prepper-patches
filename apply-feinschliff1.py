#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-feinschliff1: Feinschliff Paket 1 (nur dashboard.py, nur Dienst prepper-dashboard).

1. Lage/Internet: DSL und Starlink getrennt (nur vorhandene Erkennung: uplinkDetect ueber _t4_us(),
   Internet-Slot; Starlink = Ausfallschutz an der FRITZ!Box). Nur DSL weg = Lage AUFFAELLIG (gelb),
   Internet offline (DSL und Starlink weg) = KRITISCH (rot). Anzeige in der Internet-Kachel auf / und /pi,
   /api/inet_split. Die gelbe/rote Lage-Farbe setzt sich gegen die gruene Teil-4-Faerbung durch.
   Startzustand ohne Daten: neutral (grau, Sanduhr), nie rot. Toter Code in calculate_lage entfernt.
   "Internet wieder online" rechnet die Lage neu statt pauschal NORMAL.
2. Routen /umwelt2, /decoder, /scanner entfernt (/system bleibt; PAGE_UMWELT2 bleibt fuer die Selbsttests).
3. usbwache3: Selbsttest unabhaengig von Live-Daten (usbwache.json); Haken werden immer gesetzt;
   Kachelpruefung im Apply auf id="usbwBox".
Basis: dashboard.py 80bf111f (usbwache3-Ergebnis), prepper_sdr.py unveraendert.
Selbsttest/Dry-run liefern bei jedem Fehler rc != 0 (Dreizeiler bricht per && ab). Keine Zeitsperre.
Nach dem Schreiben: Neustart prepper-dashboard, bis 45 s HTTP 200, echte Pruefung; bei Fehler Rueckbau
aus dem Backup (rc != 0).
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

KENNUNG = "feinschliff1"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"

DASH_START_SHA = "80bf111f45cb21a0e4a334773539549aced1ba4f02dc0ee5ea971d4c145f5b41"
DASH_START_BYTES = 1414043
DASH_END_SHA = "49314ffcce89ccff3ede9dcaa13251b229efaab4ea33b5364e7ced712e1a3eb2"
DASH_END_BYTES = 1421681

MARKE = "# ===== inetSplit:"


# ----------------------------------------------------------------- Bausteine
LAGE_BLOCK = r'''def _inet_split(data=None):
    """feinschliff1: DSL und Starlink getrennt, nur aus der vorhandenen Erkennung (uplinkDetect ueber _t4_us, Internet-Slot).
    Starlink haengt als Ausfallschutz an der FRITZ!Box: current=starlink heisst DSL weg, Internet offline heisst beide weg. Wirft nie."""
    ds = data if isinstance(data, dict) else (globals().get("data_store") or {})
    inet = ds.get("internet")
    online = None
    if isinstance(inet, dict) and inet.get("value") is not None:
        online = bool(inet.get("value"))
    cur, dish = None, None
    try:
        us = _t4_us()
    except Exception:
        us = None
    if isinstance(us, dict):
        if not us.get("stale"):
            cur = us.get("current")
        dd = (us.get("signals") or {}).get("dish")
        if isinstance(dd, dict) and dd.get("reachable") is not None:
            dish = bool(dd.get("reachable"))
    if cur not in ("telekom", "starlink", "unclear"):
        cur = {"landline": "telekom", "starlink": "starlink", "unclear": "unclear"}.get(ds.get("uplink_path"))
    lage = None
    if online is None:
        dsl, sl = ("pruefe", "wird geprüft"), ("pruefe", "wird geprüft")
    elif online is False:
        dsl, sl = ("weg", "ausgefallen"), ("weg", "ausgefallen")
        lage = "rot"
    elif cur == "telekom":
        dsl = ("ok", "OK")
        sl = ("bereit", "bereit (Schüssel antwortet)") if dish else ("still", "Bereitschaft nicht prüfbar")
    elif cur == "starlink":
        dsl, sl = ("weg", "ausgefallen"), ("aktiv", "Ausfallschutz aktiv")
        lage = "gelb"
    elif cur == "unclear":
        dsl, sl = ("unklar", "Pfad unklar"), ("unklar", "Pfad unklar")
    else:
        dsl, sl = ("pruefe", "wird geprüft"), ("pruefe", "wird geprüft")
    return {"online": online, "cur": cur, "dsl": {"lvl": dsl[0], "txt": dsl[1]}, "sl": {"lvl": sl[0], "txt": sl[1]}, "lage": lage}


def calculate_lage(data):
    try:
        nv = (data.get("nina") or {}).get("value")
        if isinstance(nv, list):
            data = dict(data)
            nd = dict(data.get("nina") or {})
            nd["value"] = [w for w in nv if nina_is_alert((w.get("title") if isinstance(w, dict) else str(w)))]
            data["nina"] = nd
    except Exception:
        pass
    sp = _inet_split(data)
    if sp["online"] is None:
        return "–", "#94a3b8", "Daten werden geladen"   # feinschliff1: ohne Daten neutral, nie rot
    freq = data.get("frequenz",{}).get("value")
    nina = data.get("nina",{}).get("value", [])
    if sp["online"] is False: return "KRITISCH", "#ef4444", "Internet offline (DSL und Starlink weg)"
    if freq and (freq < 49.80 or freq > 50.20): return "KRITISCH", "#ef4444", "Netzfrequenz kritisch"
    if sp["lage"] == "gelb": return "AUFFÄLLIG", "#eab308", "DSL ausgefallen – Starlink-Ausfallschutz aktiv"
    if nina: return "AUFFÄLLIG", "#eab308", "Warnungen vorhanden"
    try:
        _dw = (data.get("dwd_warn") or {}).get("value") or {}
        if isinstance(_dw, dict) and int(_dw.get("max_level") or 0) >= 3:
            return "AUFFÄLLIG", "#eab308", "DWD-Wetterwarnung Stufe %s" % _dw.get("max_level")
    except Exception:
        pass
    if freq and (freq < 49.95 or freq > 50.05): return "AUFFÄLLIG", "#eab308", "Frequenz auffällig"
    return "NORMAL", "#22c55e", "Keine akuten Gefahrenlagen erfasst."
'''

INET_BLOCK = r'''# ===== inetSplit: Internet-Kachel zeigt DSL und Starlink getrennt; Start ohne Daten neutral (feinschliff1) =====
import json as _inet_json
import re as _inet_re

_INET_D = {"err": None}
_LAGE_NEUTRAL_RE = _inet_re.compile(r'<div class="lage kritisch">(\s*)<span class="lage-icon">[^<]*</span>(\s*LAGE: –)')


def _lage_neutral_html(html):
    """Ohne Daten (LAGE: –) zeigt die Vorlage rot/kritisch; hier neutral (grau, Sanduhr). Alles andere unveraendert."""
    try:
        if not isinstance(html, str):
            return html
        return _LAGE_NEUTRAL_RE.sub(lambda m: '<div class="lage neutral">%s<span class="lage-icon">⏳</span>%s' % (m.group(1), m.group(2)), html, count=1)
    except Exception:
        return html


def _inet_view():
    sp = _inet_split()
    return {"online": sp["online"], "cur": sp["cur"], "dsl": sp["dsl"], "sl": sp["sl"], "lage": sp["lage"]}


_INET_CSS = '<style id="inet-split-css">#inet-split{margin-top:4px;font-size:.85rem;font-weight:600;line-height:1.35;text-align:left}#inet-split div{white-space:normal;overflow-wrap:anywhere}</style>'
_INET_CSS_HOME = '<style id="inet-split-css2">#uplink-line{display:none!important}</style>'

_INET_JS = r"""<script id="inet-split-js">(function(){
var S=__INIT__;
var COL={ok:'#22c55e',bereit:'#22c55e',weg:'#ef4444',aktiv:'#f59e0b',still:'#94a3b8',unklar:'#eab308',pruefe:'#94a3b8'};
function card(){var ts=document.querySelectorAll('.card .title');for(var i=0;i<ts.length;i++){if(/Internet/i.test(ts[i].textContent||''))return ts[i].closest('.card');}return null;}
function box(){var e=document.getElementById('inet-split');if(e)return e;var c=card();if(!c)return null;
e=document.createElement('div');e.id='inet-split';var m=null,ch=c.children;
for(var i=0;i<ch.length;i++){if(ch[i].classList&&ch[i].classList.contains('medium')){m=ch[i];break;}}
if(!m){m=c.querySelector('.title');}
if(m){m.insertAdjacentElement('afterend',e);}else{c.appendChild(e);}return e;}
function row(e,ico,name,o){var d=document.createElement('div');var k=document.createElement('span');k.textContent='\u25cf ';k.style.color=COL[o.lvl]||'#94a3b8';
d.appendChild(document.createTextNode(ico+' '+name+': '));d.appendChild(k);var t=document.createElement('span');t.textContent=o.txt||'';t.style.color=COL[o.lvl]||'#94a3b8';d.appendChild(t);e.appendChild(d);}
function render(d){var e=box();if(!e||!d||!d.dsl||!d.sl)return;while(e.firstChild)e.removeChild(e.firstChild);
row(e,'\ud83d\udd0c','DSL \u00b7 Telekom',d.dsl);row(e,'\ud83d\udef0\ufe0f','Starlink',d.sl);}
try{render(S);}catch(x){}
setInterval(function(){fetch('/api/inet_split',{cache:'no-store'}).then(function(r){return r.json();}).then(function(d){try{render(d);}catch(x){}}).catch(function(){});},30000);
})();</script>"""


def _inet_inject(body, path="/"):
    try:
        if not isinstance(body, str) or 'id="inet-split-js"' in body:
            return body
        k = body.rfind("</body>")
        if k < 0:
            return body
        init = _inet_json.dumps(_inet_view(), ensure_ascii=False).replace("</", "<\\/")
        add = _INET_CSS + (_INET_CSS_HOME if path == "/" else "") + _INET_JS.replace("__INIT__", init)
        return body[:k] + add + body[k:]
    except Exception as ex:
        print("inetSplit inject:", type(ex).__name__, flush=True)
        return body


def _inet_api():
    from flask import jsonify
    r = jsonify(_inet_view())
    r.headers["Cache-Control"] = "no-store"
    return r


def _inet_after(resp):
    try:
        from flask import request as _inet_rq
        pth = (_inet_rq.path or "").rstrip("/") or "/"
        if pth not in ("/", "/pi") or resp.status_code != 200 or getattr(resp, "direct_passthrough", False):
            return resp
        if resp.headers.get("Content-Encoding") or not (resp.mimetype or "").startswith("text/html"):
            return resp
        body = resp.get_data(as_text=True)
        neu = _inet_inject(body, pth)
        if neu != body:
            resp.set_data(neu)
    except Exception as ex:
        print("inetSplit after:", type(ex).__name__, flush=True)
    return resp


try:
    if "app" in globals():
        if "inet_split_api" not in app.view_functions:
            app.add_url_rule("/api/inet_split", endpoint="inet_split_api", view_func=_inet_api, methods=["GET"])
        if not any(getattr(f, "__name__", "") == "_inet_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_inet_after)
        print("inetSplit aktiv: / und /pi, /api/inet_split", flush=True)
except Exception as _inet_e:
    _INET_D["err"] = str(_inet_e)[:160]
    print("inetSplit FEHLER:", _inet_e, flush=True)
# ===== /inetSplit =====

'''

# Neue usbwache-Selbstpruefung: unabhaengig von Live-Daten (usbwache.json), Hooks nie vom Selbsttest abhaengig
USBW_WRAP = r'''def _usbw_selftest():
    """feinschliff1: Selbsttest ohne Live-Daten (leerer Ruhezustand erzwungen), danach Original zurueck."""
    orig = globals().get("_usbw_load_view")
    globals()["_usbw_load_view"] = lambda: {"on": True, "rot": False, "events": [], "rows": [], "n_h": 0, "max_h": 4, "live": False}
    try:
        return _usbw_selftest_inner()
    finally:
        globals()["_usbw_load_view"] = orig


'''

USBW_TAIL_ALT = '''try:
    _USBW_D["selftest"] = _usbw_selftest()
    if not str(_USBW_D["selftest"]).startswith("usbwache3 ok"):
        print("usbwache Anzeige FEHLER: %s" % _USBW_D["selftest"], flush=True)
    else:
        _usbw_n = 0
        try:
            _usbw_n = _usbw_hook_routes()
        except Exception as _usbw_he:
            print("usbwache Haken:", type(_usbw_he).__name__, flush=True)
        print("usbwache Anzeige: page3()+page_pi()+letzter after_request /system;/umwelt;/pi, Hooks=%s; %s" % (_usbw_n, _USBW_D["selftest"]), flush=True)
except Exception as _usbw_de:
    _USBW_D["err"] = str(_usbw_de)[:160]
    print("usbwache Anzeige FEHLER:", _usbw_de, flush=True)
'''

USBW_TAIL_NEU = '''try:
    _USBW_D["selftest"] = _usbw_selftest()
except Exception as _usbw_de:
    _USBW_D["err"] = str(_usbw_de)[:160]
    _USBW_D["selftest"] = "FEHLER: %s" % _USBW_D["err"]
    print("usbwache Selbsttest FEHLER:", _usbw_de, flush=True)
_usbw_n = 0
try:
    _usbw_n = _usbw_hook_routes()   # feinschliff1: Haken immer setzen, nie vom Selbsttest abhaengig
except Exception as _usbw_he:
    print("usbwache Haken:", type(_usbw_he).__name__, flush=True)
print("usbwache Anzeige: page3()+page_pi()+letzter after_request /system;/umwelt;/pi, Hooks=%s; %s" % (_usbw_n, _USBW_D["selftest"]), flush=True)
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
A_LAGE_START = "def calculate_lage(data):\n"
A_LAGE_ENDE = '    return "NORMAL", "#22c55e", "Keine akuten Gefahrenlagen erfasst."\n'

A_FREQ_ALT = (
    '                lage = data_store.get("lage") or {}\n'
    '                if isinstance(lage, dict) and "offline" in str(lage.get("reason") or lage.get("text") or "").lower():\n'
    '                    data_store["lage"] = {"text": "NORMAL", "color": "#22c55e", "reason": "Internet wieder online"}\n'
)
A_FREQ_NEU = (
    '                lage = data_store.get("lage") or {}\n'
    '                if isinstance(lage, dict) and "offline" in str(lage.get("reason") or lage.get("text") or "").lower():\n'
    '                    try:   # feinschliff1: neu rechnen statt pauschal NORMAL (DSL weg bleibt gelb)\n'
    '                        _lt, _lc, _lr = calculate_lage(data_store)\n'
    '                        if _lt == "NORMAL":\n'
    '                            _lr = "Internet wieder online"\n'
    '                    except Exception:\n'
    '                        _lt, _lc, _lr = "NORMAL", "#22c55e", "Internet wieder online"\n'
    '                    data_store["lage"] = {"text": _lt, "color": _lc, "reason": _lr}\n'
)

A_CSS_ALT = ".lage.kritisch{background:#ef444422;color:#fca5a5;border-color:#ef4444aa;box-shadow:0 0 28px #ef444433}\n"
A_CSS_NEU = A_CSS_ALT + ".lage.neutral{background:#1e293b;color:#94a3b8;border-color:#334155;box-shadow:none}\n"

A_P1_ALT = (
    '    return _stale_ts_render(render_template_string(\n'
    '        PAGE1,\n'
    '        minutes_left=_ml,\n'
    '        clock_off=globals().get("_clk_view", lambda s: None)(_ds.get("stratum")),  # clockOff: chrony-Wert, Cache 60 s\n'
    '        nina_cert=globals().get("_nina_cert_view", lambda: None)(),  # ninaFix: Hinweis Zertifikatskette (None = nichts anzeigen)\n'
    '        **_ds\n'
    '    ))\n'
)
A_P1_NEU = (
    '    return _lage_neutral_html(_stale_ts_render(render_template_string(  # feinschliff1: ohne Daten neutral\n'
    '        PAGE1,\n'
    '        minutes_left=_ml,\n'
    '        clock_off=globals().get("_clk_view", lambda s: None)(_ds.get("stratum")),  # clockOff: chrony-Wert, Cache 60 s\n'
    '        nina_cert=globals().get("_nina_cert_view", lambda: None)(),  # ninaFix: Hinweis Zertifikatskette (None = nichts anzeigen)\n'
    '        **_ds\n'
    '    )))\n'
)

A_T4RE_ALT = "m = _t4_re.search(r'<div class=\"lage (normal|auffaellig|kritisch)\">', body)"
A_T4RE_NEU = "m = _t4_re.search(r'<div class=\"lage (normal|auffaellig|kritisch|neutral)\">', body)"

A_T4CSS_ALT = ".lage.t4s.t4-blink{animation:t4blink 1s infinite}\n"
A_T4CSS_NEU = (
    ".lage.neutral.t4s.t4-ok,.lage.neutral.t4s.t4-probe{background:#1e293b!important;color:#94a3b8!important;border-color:#334155!important;box-shadow:none!important}\n"
    ".lage.auffaellig.t4s.t4-ok{background:#eab30818!important;color:#eab308!important;border-color:#eab30855!important;box-shadow:0 0 24px #eab30822!important}\n"
    ".lage.kritisch.t4s.t4-ok,.lage.kritisch.t4s.t4-probe{background:#ef444433!important;color:#fecaca!important;border-color:#ef4444!important;box-shadow:0 0 28px #ef444466!important}\n"
    + A_T4CSS_ALT
)

A_R_UMW2 = (
    '@app.route("/umwelt2")\n'
    'def page_umwelt2():\n'
    '    return render_template_string(PAGE_UMWELT2, **_page_stability_defaults(data_store))  # pageStability\n'
    '\n\n'
)
A_R_SCAN = (
    '@app.route("/scanner")\n'
    'def page_scanner():\n'
    '    from flask import redirect\n'
    '    return redirect("/", code=302)\n'
    '\n\n'
    '@app.route("/decoder")\n'
    'def page_decoder():\n'
    '    from flask import redirect\n'
    '    return redirect("/", code=302)\n'
    '\n\n'
)

A_USBW_MARKE = "# ===== usbwache3: Kachel auf /system nach allen Haken, /pi unveraendert =====\n"
A_USBW_DEF = "def _usbw_selftest():\n    page = '<html><head></head><body><div class=\"card\" id=\"backupBox\">Sicherung</div></body>'\n"


def patch_dash(text):
    if schon(text):
        return text
    if "# ===== usbwache3:" not in text:
        raise Stop("STOP usbwache3-Block fehlt (Basis 80bf111f erwartet)")
    t = scheibe_ersetzen(text, A_LAGE_START, A_LAGE_ENDE, LAGE_BLOCK, "calculate_lage")
    t = ersetze(t, A_FREQ_ALT, A_FREQ_NEU, "Internet wieder online")
    t = ersetze(t, A_CSS_ALT, A_CSS_NEU, "BASE_STYLE neutral")
    t = ersetze(t, A_P1_ALT, A_P1_NEU, "page1 neutral")
    t = ersetze(t, A_T4RE_ALT, A_T4RE_NEU, "t4 Lage-Regex")
    t = ersetze(t, A_T4CSS_ALT, A_T4CSS_NEU, "t4 CSS")
    t = ersetze(t, A_R_UMW2, "", "Route /umwelt2")
    t = ersetze(t, A_R_SCAN, "", "Routen /scanner /decoder")
    t = ersetze(t, A_USBW_DEF, USBW_WRAP + "def _usbw_selftest_inner():\n" + A_USBW_DEF.split("\n", 1)[1], "usbw Selbsttest")
    t = ersetze(t, USBW_TAIL_ALT, USBW_TAIL_NEU, "usbw Ende")
    t = ersetze(t, A_USBW_MARKE, INET_BLOCK + A_USBW_MARKE, "inetSplit Block")
    if not schon(t):
        raise Stop("STOP Markierungen nach dem Patch unvollstaendig")
    return t


def schon(text):
    return (
        MARKE in text
        and "def _inet_split(" in text
        and "def _usbw_selftest_inner(" in text
        and '@app.route("/umwelt2")' not in text
        and '"data" in dir()' not in text
        and "_lage_neutral_html(_stale_ts_render(" in text
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
        raise Stop("STOP dashboard.py Hash %s/%d, erwartet %s/%d (usbwache3-Stand) oder Endstand %s/%d" % (
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


def pruefe_live(seit):
    """Echte Pruefung am laufenden Dienst. True = alles ok."""
    ok, seiten = warte_200(["/", "/pi", "/system", "/umwelt", "/api/inet_split"], 45)
    if not ok:
        return False
    for p in ("/pi", "/system"):
        if 'id="usbwBox"' not in seiten.get(p, ""):
            print("STOP %s ohne Element id=\"usbwBox\"" % p)
            ok = False
        else:
            print("usbwBox auf %s vorhanden" % p)
    if 'id="usbwBox"' not in seiten.get("/umwelt", ""):
        print("Hinweis: /umwelt ohne usbwBox")
    for p in ("/", "/pi"):
        if 'id="inet-split-js"' not in seiten.get(p, ""):
            print("STOP %s ohne Internet-Anzeige (inet-split-js)" % p)
            ok = False
        else:
            print("Internet-Anzeige DSL/Starlink auf %s vorhanden" % p)
    try:
        j = json.loads(seiten.get("/api/inet_split") or "null")
        if not (isinstance(j, dict) and isinstance(j.get("dsl"), dict) and isinstance(j.get("sl"), dict) and "online" in j):
            raise ValueError("Schluessel fehlen")
        print("/api/inet_split ok: online=%s DSL=%s Starlink=%s Lage=%s" % (j.get("online"), j["dsl"].get("txt"), j["sl"].get("txt"), j.get("lage")))
    except Exception as exc:
        print("STOP /api/inet_split kein gueltiges JSON (%s)" % exc)
        ok = False
    for p in ("/umwelt2", "/decoder", "/scanner"):
        code, _ = _get(p)
        if code != "404":
            print("STOP %s liefert %s, erwartet 404" % (p, code))
            ok = False
        else:
            print("%s -> 404 (entfernt)" % p)
    code, _ = _get("/api/sdr/usbw")
    if code != "200":
        print("STOP /api/sdr/usbw liefert %s" % code)
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
        if not any("inetSplit aktiv" in ln for ln in zeilen):
            print("STOP Journal ohne Zeile 'inetSplit aktiv'")
            ok = False
        if not any("usbwache Anzeige:" in ln for ln in zeilen):
            print("STOP Journal ohne Zeile 'usbwache Anzeige:'")
            ok = False
        if any("usbwache Selbsttest FEHLER" in ln or "inetSplit FEHLER" in ln for ln in zeilen):
            print("STOP Journal meldet Selbsttest-/inetSplit-FEHLER")
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
    if not pruefe_live(seit):
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


def _lage_ns():
    ns = {"nina_is_alert": lambda t: True}
    exec(LAGE_BLOCK, ns)
    return ns


def _selftest_lage():
    ns = _lage_ns()

    def lage(online="fehlt", path=None, cur=None, stale=False, dish=None, freq=50.0, nina=None, dwd=0):
        d = {"frequenz": {"value": freq}, "nina": {"value": nina or []}, "uplink_path": path,
             "dwd_warn": {"value": {"max_level": dwd}}}
        if online != "fehlt":
            d["internet"] = {"value": online}
        sig = {"dish": {"reachable": dish}} if dish is not None else {}
        ns["_t4_us"] = (lambda: {"current": cur, "stale": stale, "signals": sig}) if cur is not None or stale else (lambda: None)
        return ns["calculate_lage"](d), ns["_inet_split"](d)

    (t, c, r), sp = lage()                                   # keine Daten: neutral, nie rot
    assert t == "–" and c == "#94a3b8" and sp["dsl"]["lvl"] == "pruefe", (t, c, r)
    (t, c, r), sp = lage(online=None)
    assert t == "–", t
    (t, c, r), sp = lage(online=True, cur="telekom")         # DSL ok
    assert t == "NORMAL" and sp["dsl"]["lvl"] == "ok" and sp["sl"]["lvl"] == "still" and sp["lage"] is None, (t, sp)
    (t, c, r), sp = lage(online=True, cur="telekom", dish=True)
    assert sp["sl"]["lvl"] == "bereit" and t == "NORMAL", sp
    (t, c, r), sp = lage(online=True, cur="starlink")        # nur DSL weg = gelb
    assert t == "AUFFÄLLIG" and c == "#eab308" and "DSL" in r and sp["dsl"]["lvl"] == "weg" and sp["sl"]["lvl"] == "aktiv" and sp["lage"] == "gelb", (t, r, sp)
    (t, c, r), sp = lage(online=False, cur="starlink")       # beide weg = rot
    assert t == "KRITISCH" and c == "#ef4444" and "offline" in r and sp["dsl"]["lvl"] == "weg" and sp["sl"]["lvl"] == "weg" and sp["lage"] == "rot", (t, r, sp)
    (t, c, r), sp = lage(online=False, cur="telekom")
    assert t == "KRITISCH", t
    (t, c, r), sp = lage(online=False)
    assert t == "KRITISCH" and "offline" in r.lower(), (t, r)
    (t, c, r), sp = lage(online=True, cur="starlink", stale=True, path="landline")   # veraltete Erkennung: Ersatz aus uplink_path
    assert t == "NORMAL" and sp["dsl"]["lvl"] == "ok", (t, sp)
    (t, c, r), sp = lage(online=True, cur="starlink", stale=True, path="starlink")
    assert t == "AUFFÄLLIG", t
    (t, c, r), sp = lage(online=True, cur="unclear")         # unklar: keine Lage-Wirkung
    assert t == "NORMAL" and sp["dsl"]["lvl"] == "unklar", (t, sp)
    (t, c, r), sp = lage(online=True, cur="telekom", freq=49.7)
    assert t == "KRITISCH" and "Netzfrequenz" in r, (t, r)
    (t, c, r), sp = lage(online=True, cur="telekom", freq=49.9)
    assert t == "AUFFÄLLIG" and "Frequenz" in r, (t, r)
    (t, c, r), sp = lage(online=True, cur="telekom", nina=[{"title": "x"}])
    assert t == "AUFFÄLLIG" and "Warnung" in r, (t, r)
    (t, c, r), sp = lage(online=True, cur="starlink", nina=[{"title": "x"}])
    assert t == "AUFFÄLLIG" and "DSL" in r, (t, r)
    (t, c, r), sp = lage(online=True, cur="telekom", dwd=3)
    assert t == "AUFFÄLLIG" and "DWD" in r, (t, r)
    assert '"data" in dir()' not in LAGE_BLOCK
    print("selftest Lage ok (neutral ohne Daten, DSL weg gelb, DSL+Starlink weg rot, unklar/veraltet ohne Wirkung)")


def _selftest_inet():
    ns = _lage_ns()
    ns["data_store"] = {"internet": {"value": True}, "uplink_path": "starlink"}
    ns["_t4_us"] = lambda: {"current": "starlink", "stale": False, "signals": {}}
    exec(INET_BLOCK, ns)
    html = ('<div class="lage kritisch">\n  <span class="lage-icon">🚨</span>\n  LAGE: –\n  <small>Update läuft…</small></div>')
    out = ns["_lage_neutral_html"](html)
    assert 'class="lage neutral"' in out and "⏳" in out and "🚨" not in out and "LAGE: –" in out, out
    real = html.replace("LAGE: –", "LAGE: KRITISCH")
    assert ns["_lage_neutral_html"](real) == real                   # echte Lage bleibt rot
    ok = html.replace("kritisch", "normal").replace("LAGE: –", "LAGE: NORMAL")
    assert ns["_lage_neutral_html"](ok) == ok
    body = "<html><head></head><body><div class=\"card\"><div class=\"title\">🌐 Internet</div></div></body></html>"
    a = ns["_inet_inject"](body, "/")
    assert 'id="inet-split-js"' in a and "#uplink-line{display:none" in a and a.rfind("</body>") > a.find("inet-split-js"), a[:200]
    p = ns["_inet_inject"](body, "/pi")
    assert 'id="inet-split-js"' in p and "#uplink-line{display:none" not in p
    assert ns["_inet_inject"](a, "/") == a                             # idempotent
    assert ns["_inet_inject"]("kein body", "/") == "kein body"
    m = re.search(r"var S=(\{.*?\});\nvar COL", a, re.S)
    j = json.loads(m.group(1))
    assert j["dsl"]["lvl"] == "weg" and j["sl"]["lvl"] == "aktiv" and j["online"] is True and j["lage"] == "gelb", j
    assert not re.search(r"\b[0-9]{8}\b", a), "Seriennummer-aehnliche Zahl in der Anzeige"
    print("selftest Internet-Anzeige ok (DSL/Starlink getrennt, / und /pi, neutral nur ohne Daten)")


def _selftest_patch(text):
    t = patch_dash(text)
    assert patch_dash(t) == t, "patch nicht idempotent"
    compile(t, "dashboard.py", "exec")
    assert '"data" in dir()' not in t
    for r in ('@app.route("/umwelt2")', '@app.route("/scanner")', '@app.route("/decoder")', "def page_umwelt2", "def page_scanner", "def page_decoder"):
        assert r not in t, r
    assert '@app.route("/system")' in t and '@app.route("/api/scanner_mode"' in t and "PAGE_UMWELT2 = _lp_page_umwelt2(NAV_UNIFY)" in t
    assert t.count("def calculate_lage(") == 1 and t.count("def _inet_split(") == 1 and t.count("def _inet_after(") == 1
    i_main = t.find('if __name__ == "__main__":\n    # sourceWatch final')
    assert 0 < t.find(MARKE) < t.find("# ===== usbwache3:") < i_main, "Bloecke muessen VOR __main__ stehen"
    assert t.find("# ===== /usbwache3 =====") < i_main
    assert "m = _t4_re.search(r'<div class=\"lage (normal|auffaellig|kritisch|neutral)\">', body)" in t
    assert ".lage.neutral{background" in t and ".lage.kritisch.t4s.t4-ok" in t
    # usbwache3-Selbsttest unabhaengig von Live-Daten (Altfehler reproduzieren, dann Fix pruefen)
    a = t.find("# ===== usbwache3:")
    b = t.find("# ===== /usbwache3 =====")
    ns = {"__name__": "usbwtest"}
    exec(compile(t[a:b], "usbwache3-block", "exec"), ns)
    assert str(ns["_USBW_D"]["selftest"]).startswith("usbwache3 ok"), ns["_USBW_D"]
    laut = {"on": True, "rot": True, "hint": "x", "events": [{"t": 1, "hm": "01:00:00", "txt": "e", "lvl": "gelb"}],
            "rows": [], "n_h": 3, "max_h": 4}
    ns["_usbw_load_view"] = lambda: laut
    try:
        ns["_usbw_selftest_inner"]()
        alt_fehler = False
    except AssertionError:
        alt_fehler = True
    assert alt_fehler, "Altfehler (Selbsttest haengt an Live-Daten) nicht reproduziert"
    erg = ns["_usbw_selftest"]()
    assert str(erg).startswith("usbwache3 ok"), erg
    assert ns["_usbw_load_view"]() is laut, "Live-Ansicht nach dem Selbsttest nicht zurueckgesetzt"
    print("selftest usbwache3 ok (laeuft jetzt auch mit Live-Ereignissen, Original wird zurueckgesetzt)")
    return t


def selftest(basis=BASIS):
    try:
        _selftest_restart_check()
        _selftest_lage()
        _selftest_inet()
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
            tmp = tempfile.mkdtemp(prefix="feinschliff1-st-")
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
            print("STOP selftest: dashboard.py %s/%d ist weder usbwache3-Stand noch Endstand" % (ist[:16], n))
            return 1
    except (AssertionError, Stop, SyntaxError, KeyError, ValueError, TypeError) as exc:
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
