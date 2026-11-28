#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-adsbbreite2 (Basis prepper_sdr.py nach usbcycle 3496de46.../822016): /adsb nie breiter als der Bildschirm (iPhone ca. 390 px) - die Seite liess sich zoomen und seitlich verschieben, anders als alle anderen Seiten.

Nur dashboard.py (Stand nach zuhauseflach, 713348c3.../1477522). prepper_sdr.py und sdr_manager.py werden nur geprueft. Neustart: nur prepper-dashboard.
Aenderungen (zwei Daten-Zeilen in der vorhandenen seitenFlach-Tabelle, keine neue Funktion, kein neuer Haken):
- _SF_PAGES: + "/adsb".
- _SF_CSS["/adsb"]: html{overflow-x:hidden}, body{max-width:100%}; .card{min-width:0;max-width:100%;box-sizing:border-box}; Tabellen direkt in der Kachel (oder in einem Container
  ohne eigenes Scrollen) scrollen seitlich innerhalb der Kachel (display:block;overflow-x:auto), die vorhandenen Container (Militaer-Tabelle) bleiben; die Squawk-/Notlage-Zeilen
  (white-space:nowrap) bekommen overflow:hidden + text-overflow:ellipsis. Kein Inhalt wird entfernt (der volle Text bleibt im HTML).
Der Viewport-Meta-Tag von /adsb (width=device-width,initial-scale=1,maximum-scale=1) ist schon gleich dem von /pi; die Live-Pruefung vergleicht beide.
Keine Kachel in Kachel, keine Inhalte entfernt. Erhalten: snMask, inet_split, usbwache, _psh_cfg_sauber, feinschliff4-8, acarsKlar, zuhauseflach, Flugfunk-Logik.
Live-Pruefung wie zuhauseflach2: wartet auf das erste Voll-Update (sysBoot, loading:false), alle vorher erreichbaren Seiten 200, keine Seriennummern, Journal, Rollback bei Fehler.
Keine Zeitsperre, keine Seriennummern in der Ausgabe."""
from __future__ import annotations

import argparse
import ast
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

KENNUNG = "adsbbreite"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"
FESTE_SN = ()
VORGAENGER = "zuhauseflach"
DASH_START = ('713348c3be2341310658c8c3899733a21e3abfd9e081955af1387853afd21a06', 1477522)   # Stand nach zuhauseflach
DASH_ENDE = ('84e48878f1ca071ec873dd0a809b2b9ba693ab8f76e4044bcb68e49aae4a9706', 1478022)
SDR_SOLL = ("3496de46b67fc16468a6f2e089dea6c3ebebd6162cbfe36725e4efd240129b2a", 822016)      # prepper_sdr.py nach usbcycle (unveraendert)
SM_SOLL = ("5a26efff608bf541a929fa775112d3593883a7423b6d9f6f29e61dc9b14db181", 288008)       # sdr_manager.py (unveraendert)
VORSTAENDE = {'8d0a09e8ad76f8fa27faef1020da54c3ae9b3b2ada3a5aef784db9291f59c0a6': 'dashboard.py steht noch auf acarsklar - bitte zuerst apply-zuhauseflach2.py. ', 'e27446ebbff47cc0de9337b8108d7e5832fe28cf28d798d341f485a7b620d1a4': 'dashboard.py steht noch auf Paket 8 - bitte zuerst apply-acarsklar.py und apply-zuhauseflach2.py. '}
JOURNAL_PFLICHT = ["snMask aktiv:", "inetSplit aktiv", "usbwache Anzeige:", "feinschliff4 aktiv:"] + ['feinschliff5 aktiv:', 'feinschliff8 aktiv:', 'seitenFlach aktiv:', 'funkFlach aktiv:', 'acarsKachel aktiv:', 'acarsKlar aktiv:']
JOURNAL_VERBOTEN = ["snMask Selbsttest FEHLER", "snMask FEHLER", "feinschliff4 Selbsttest FEHLER", "feinschliff4 FEHLER", "inetSplit FEHLER", "teil4 Lage-Seite:"] + ['feinschliff5 Menue:', 'feinschliff5 FEHLER', 'feinschliff8 FEHLER', 'seitenFlach FEHLER', 'funkFlach FEHLER', 'acarsKlar FEHLER', 'acarsKachel FEHLER']


# ----------------------------------------------------------------- Hilfen
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


def _python_mit_flask(basis):
    cands = [sys.executable]
    ve = os.environ.get("VIRTUAL_ENV")
    if ve:
        cands.append(os.path.join(ve, "bin", "python"))
    for rel in (("venv", "bin", "python"), (".venv", "bin", "python"), ("venv", "bin", "python3")):
        cands.append(os.path.join(basis, *rel))
        cands.append(os.path.join(os.path.dirname(basis), *rel))
    cands += ["/workspace/feinschliff/venv/bin/python", "/home/fmg/prepper-dashboard/venv/bin/python"]
    seen = set()
    for py in cands:
        if not py or py in seen or not os.path.isfile(py):
            continue
        seen.add(py)
        try:
            r = subprocess.run([py, "-c", "import flask"], capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0:
            return py
    return None


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise Stop("STOP %s: Anker %d mal gefunden, erwartet %d" % (name, c, n))
    return text.replace(alt, neu)


def sichern(pfad, stempel):
    ziel = "%s.bak-%s-%s" % (pfad, KENNUNG, stempel)
    shutil.copy2(pfad, ziel)
    ordner = os.path.dirname(pfad) or "."
    name = os.path.basename(pfad) + ".bak-" + KENNUNG + "-"
    for p in sorted(p for p in os.listdir(ordner) if p.startswith(name))[:-3]:
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


def _pyflakes_msgs(pfad):
    """Meldungen ohne Zeilennummern als Zaehler, oder None ohne pyflakes."""
    for cmd in (["pyflakes", pfad], ["python3", "-m", "pyflakes", pfad]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            continue
        err = (r.stderr or "") + (r.stdout or "")
        if "No module named" in err or "command not found" in err:
            continue
        out = {}
        for ln in err.splitlines():
            m = re.match(r"^.*?:\d+(?::\d+)?:? (.*)$", ln)
            k = m.group(1) if m else ln
            out[k] = out.get(k, 0) + 1
        return out
    return None


def pyflakes_vergleich(pfad_alt, pfad_neu):
    """True, wenn die neue Datei keine zusaetzliche pyflakes-Meldung hat (gegenueber der alten)."""
    a, n = _pyflakes_msgs(pfad_alt), _pyflakes_msgs(pfad_neu)
    if a is None or n is None:
        print("Hinweis: pyflakes nicht installiert, nur compile")
        return True
    neu = [k for k, c in n.items() if c > a.get(k, 0)]
    if neu:
        print("pyflakes %s: neue Meldungen:\n%s" % (os.path.basename(pfad_neu), "\n".join(neu[:20])))
        return False
    print("pyflakes %s: keine neue Meldung (alt %d, neu %d)" % (os.path.basename(pfad_neu), sum(a.values()), sum(n.values())))
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
    return gesehen if gesehen != 0 else 1


URL = "http://127.0.0.1:5000"


def _get(pfad, timeout=6):
    ziel = tempfile.mktemp(prefix="apply-" + KENNUNG + "-")
    try:
        r = subprocess.run(["curl", "-sS", "-m", str(timeout), "-o", ziel, "-w", "%{http_code}", URL + pfad],
                           capture_output=True, text=True, timeout=timeout + 3)
        code = (r.stdout or "").strip() or "000"
        body = open(ziel, encoding="utf-8", errors="replace").read() if os.path.isfile(ziel) else ""
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
    """Seriennummern aus den Konfigurations-/Statusdateien. Werte werden nie ausgegeben."""
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
                if re.fullmatch(r"stick[0-9]+", ks) and isinstance(v, (str, int)):
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


def journal_zeilen(dienst, seit):
    r = subprocess.run(["journalctl", "-u", dienst, "--since", seit, "-o", "cat", "-n", "800"], capture_output=True, text=True, timeout=20)
    return (r.stdout or "").splitlines()


# ----------------------------------------------------------------- Paket

SCHON = "# adsbbreite:"

_AB_CSS = ('html{overflow-x:hidden}body{max-width:100%}'
           '.card{min-width:0;max-width:100%;box-sizing:border-box}'
           '.card>table,.card>div:not([style*="overflow-x:auto"])>table{display:block;max-width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch}'
           '.card div[style*="white-space:nowrap"]{max-width:100%;overflow:hidden!important;text-overflow:ellipsis}')

P_PG_ALT = '"/speicher")   # feinschliff6: /mesh2, /zuhause; feinschliff7: /system, /umwelt, /speicher\n'
P_PG_NEU = '"/speicher", "/adsb")   # feinschliff6: /mesh2, /zuhause; feinschliff7: /system, /umwelt, /speicher; adsbbreite: /adsb\n'
P_CSS_ALT = '    "/zuhause": ('
P_CSS_NEU = '    "/adsb": (' + repr(_AB_CSS) + '),   # adsbbreite: Seite nie breiter als der Bildschirm (Tabellen/Squawk-Zeilen scrollen oder kuerzen in der Kachel)\n    "/zuhause": ('

PATCHES = [("_SF_PAGES adsb", P_PG_ALT, P_PG_NEU), ("_SF_CSS adsb", P_CSS_ALT, P_CSS_NEU)]


def patch_extra(text):
    return text


def _ausschnitt(text, pos, n=300):
    """Diagnose: HTML-Ausschnitt um pos, ca. n Zeichen, Zeilenumbrueche zusammengefasst, Seriennummern und lange Ziffernfolgen maskiert."""
    a = max(0, pos - n // 3)
    t = " ".join(text[a:a + n].split())
    try:
        for sn in echte_seriennummern(BASIS):
            t = t.replace(sn, "***")
    except Exception:
        pass
    return re.sub(r"[0-9]{8,}", "***", t)


def _viewports(html):
    out = []
    for m in re.finditer(r"<meta\b[^>]*>", html, re.I):
        tag = m.group(0)
        if re.search(r'name=["\']viewport["\']', tag, re.I):
            c = re.search(r'content=["\']([^"\']*)["\']', tag, re.I)
            out.append(re.sub(r"\s+", "", c.group(1)).lower() if c else "")
    return out


def live_extra(seiten):
    ok = True
    a = seiten.get("/adsb")
    if a is None:
        print("Hinweis: /adsb nicht geladen (nicht 200, auch vorher nicht) - Breite nicht geprueft")
        return ok
    css = re.search(r'<style id="sf-css">(.*?)</style>', a, re.S)
    muss = ("html{overflow-x:hidden}", ".card{min-width:0;max-width:100%", "overflow-x:auto", "text-overflow:ellipsis")
    fehlt = [m for m in muss if not css or m not in css.group(1)]
    if fehlt:
        print("STOP /adsb: Breiten-CSS fehlt oder unvollstaendig (%s)" % ", ".join(fehlt))
        print("  Ausschnitt: %s" % _ausschnitt(a, max(0, a.find("</head>") - 200)))
        ok = False
    else:
        print("/adsb: Breiten-Regeln da (html/Kacheln min-width:0, Tabellen scrollen, Squawk-Zeilen mit Ellipse)")
    va = _viewports(a)
    p = seiten.get("/pi")
    if p is None or 'id="sbLoading"' in p:
        vp = None
        print("Hinweis: /pi nicht auswertbar - Viewport nur gegen den Sollwert geprueft")
    else:
        vp = _viewports(p)
    if len(va) != 1:
        print("STOP /adsb: %d Viewport-Meta-Tags (erwartet 1): %s" % (len(va), va))
        ok = False
    elif vp is not None and (len(vp) != 1 or va != vp):
        print("STOP /adsb: Viewport weicht von /pi ab: /adsb %s, /pi %s" % (va, vp))
        i = a.lower().find('name="viewport"')
        print("  Ausschnitt: %s" % _ausschnitt(a, max(0, i - 40)))
        ok = False
    elif "width=device-width" not in va[0]:
        print("STOP /adsb: Viewport ohne width=device-width: %s" % va)
        ok = False
    else:
        print("/adsb: Viewport-Meta wie /pi (%s)" % va[0])
    return ok


def selftest_extra(t0, t):
    assert t.count("# adsbbreite:") == 1 and t.count("adsbbreite: /adsb") == 1, t.count("# adsbbreite:")
    assert '"/speicher", "/adsb")' in t and '"/adsb": (' in t and "html{overflow-x:hidden}" in t and "text-overflow:ellipsis" in t
    assert len(t) - len(t0) < 1000, len(t) - len(t0)
    assert t.count("\n") - t0.count("\n") == 1, "mehr als eine neue Zeile"
    assert "def _sf_apply(" in t and "def _fs5_after(" in t and "acarsKlar" in t and '"/zuhause": (' in t
    assert _viewports('<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1,maximum-scale=1">') == ["width=device-width,initial-scale=1,maximum-scale=1"]


def schon_dash(text):
    return SCHON in text


def patch_dash(text):
    if schon_dash(text):
        return text
    for name, alt, neu in PATCHES:
        text = ersetze(text, alt, neu, name)
    text = patch_extra(text)
    compile(text, "dashboard.py", "exec")
    return text


def basis_pruefen(root):
    """-> dashboard.py (bytes). Stop bei falscher Basis."""
    def lies(n):
        p = os.path.join(root, n)
        if not os.path.isfile(p):
            raise Stop("STOP %s fehlt in %s" % (n, root))
        return open(p, "rb").read()
    d = lies("dashboard.py")
    ds = stand(d)
    if ds not in (DASH_START, DASH_ENDE):
        hinweis = VORSTAENDE.get(ds[0], "")
        raise Stop("STOP Basis stimmt nicht: dashboard.py %s/%d ist weder der Stand nach %s (%s.../%d) noch der Endstand. %sNichts veraendert." % (
            ds[0][:16], ds[1], VORGAENGER, DASH_START[0][:8], DASH_START[1], hinweis))
    s = stand(lies("prepper_sdr.py"))
    if s != SDR_SOLL:
        raise Stop("STOP Basis stimmt nicht: prepper_sdr.py %s/%d ist nicht 3496de46.../822016 (nach usbcycle). Nichts veraendert." % (s[0][:16], s[1]))
    m = stand(lies("sdr_manager.py"))
    if m != SM_SOLL:
        raise Stop("STOP Basis stimmt nicht: sdr_manager.py %s/%d ist nicht 5a26efff.../288008. Nichts veraendert." % (m[0][:16], m[1]))
    print("Basis ok: dashboard.py %s (%s), prepper_sdr.py 3496de46, sdr_manager.py 5a26efff" % (ds[0][:16], "Stand nach " + VORGAENGER if ds == DASH_START else "Endstand"))
    return d


def berechne(root):
    raw = basis_pruefen(root)
    t = raw.decode("utf-8")
    neu = patch_dash(t).encode("utf-8")
    if stand(neu) != DASH_ENDE:
        raise Stop("STOP Ergebnis dashboard.py %s/%d weicht vom erwarteten Endstand ab" % (stand(neu)[0][:16], len(neu)))
    return raw, (None if neu == raw else neu)


# ----------------------------------------------------------------- Live-Pruefung
SEITEN_KERN = ["/", "/pi", "/system", "/umwelt", "/aprs", "/rundfunk", "/funk"]
SEITEN_MEHR = ["/energie", "/lokale-energie", "/speicher", "/luft", "/pegel", "/adsb", "/zuhause", "/mesh", "/mesh2", "/news",
               "/karte", "/medizin", "/funk433", "/meteor", "/dabhist", "/lage"]
API_LESEN = ["/api/sdr/status", "/api/sdr/ui", "/api/sdr/wd", "/api/sdr/live", "/api/broadcast", "/api/t2/status", "/api/t4/status",
             "/api/sdr/usbw", "/api/snmask", "/api/aprs", "/api/funk433", "/api/sdr/activity", "/api/sdr/noise", "/api/uplink",
             "/api/inet_split", "/api/broadcast/events", "/api/pushover", "/api/flugfunk", "/api/lage_grund"]
ENTFERNT_404 = ["/umwelt2", "/decoder", "/scanner", "/api/pinneberg"]


FUNK_MARKER = ("flugfunkBox", "ffPush", "ffLive", "sdrui-css", "sdrui-data", "fuLage", "snm-js")


def _fehler_keys(zeilen):
    out = set()
    for ln in zeilen:
        if "Traceback" in ln or "FEHLER" in ln:
            out.add(re.sub(r"[0-9]+", "#", ln)[:48])
    return out


def journal_vorher():
    """FEHLER-/Traceback-Zeilen des laufenden Dienstes seit seinem Start (Vergleichsbasis). None, wenn der Start nicht im Journal zu sehen ist."""
    snap = _unit_snap(DIENST)
    for seit in (snap.get("ts") or "", "-3 days"):
        if not seit:
            continue
        try:
            r = subprocess.run(["journalctl", "-u", DIENST, "--since", seit, "-o", "cat", "-n", "6000"], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        zeilen = (r.stdout or "").splitlines()
        if r.returncode == 0 and any("snMask aktiv:" in ln for ln in zeilen):
            return _fehler_keys(zeilen)
    return None


def vorher_stand():
    codes = {}
    marker = []
    for p in SEITEN_KERN + SEITEN_MEHR:
        code, body = _get(p, 12)
        codes[p] = code
        if p == "/funk" and code == "200" and 'id="sbLoading"' not in body:
            marker = [m for m in FUNK_MARKER if m in body]
    return {"codes": codes, "funk_marker": marker, "fehler": journal_vorher()}


def lage_check(timeout=None):
    """Die Lage gibt es weiter (/api/lage_grund) und der feinschliff4-Selbsttest im Dienst ist gruen. Unlesbar/noch nicht geladen -> Hinweis, kein Rollback."""
    timeout = timeout or int(os.environ.get("FS_LAGE_WAIT") or 120)
    t0 = time.time()
    g = None
    while time.time() - t0 < timeout:
        code, body = _get("/api/lage_grund", 10)
        if code == "200":
            try:
                g = json.loads(body)
            except ValueError:
                g = None
            if isinstance(g, dict) and isinstance(g.get("lage"), dict) and g["lage"].get("text") not in (None, "–"):
                break
        time.sleep(5)
    else:
        print("Hinweis: Lage nach %d s noch nicht geladen - bitte spaeter: curl -s %s/api/lage_grund | python3 -m json.tool" % (timeout, URL))
        return True
    lage = g["lage"]
    print("Lage: %s - %s" % (lage.get("text"), str(lage.get("reason") or "")[:100]))
    if not str(g.get("selftest") or "").startswith("feinschliff4 ok"):
        print("STOP feinschliff4-Selbsttest im Dienst: %s" % g.get("selftest"))
        return False
    return True


def _t4why_ok(body):
    """True, wenn die Lage-Seite serverseitig eine Alarm-Zeile mit Anker hat (oder den Platzhalter). Nie 'Status:'."""
    if not body:
        return False
    i = body.find('id="t4Why">')
    if i < 0:
        return False
    txt = body[i:i + 120]
    if "Status:" in txt:
        return False
    return "Alarm:" in txt


def warte_alarm(timeout=60, schon=None):
    """Mehrfach GET / bis zu timeout s. Akzeptiert 'Alarm:' oder 'Alarm: wird geprüft' an id=t4Why."""
    if schon and _t4why_ok(schon):
        print("GET / Alarm-Zeile schon im ersten 200-Lauf")
        return True, schon
    t0 = time.time()
    last = schon or ""
    while time.time() - t0 < timeout:
        code, body = _get("/", 20)
        if code == "200":
            last = body
            if _t4why_ok(body):
                print("GET / Alarm-Zeile ok nach %.1f s" % (time.time() - t0))
                return True, body
        time.sleep(2)
    print("STOP / ohne Alarm-Zeile (id=t4Why mit Alarm:, nicht Status:) innerhalb %s s" % timeout)
    return False, last


def warte_bereit(timeout=150):
    """Wartet auf das erste Voll-Update (sysBoot). Bis dahin liefert der Dienst bei manchen Seiten (/, /system, /umwelt, /energie, /speicher)
    mit 200 nur den Ladehinweis 'Dashboard startet' ohne Navigation - an diesem Zustand misst man kein Layout."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        code, body = _get("/api/sysboot/status", 8)
        if code == "200":
            try:
                st = json.loads(body)
            except ValueError:
                st = None
            if isinstance(st, dict) and st.get("loading") is False:
                print("Dashboard bereit nach %.0f s (erstes Voll-Update fertig)" % (time.time() - t0))
                return True
        elif code == "404":
            c2, b2 = _get("/", 15)
            if c2 == "200" and 'id="sbLoading"' not in b2:
                print("Dashboard bereit nach %.0f s" % (time.time() - t0))
                return True
        time.sleep(3)
    print("Hinweis: Dashboard nach %d s noch im Start (Ladehinweis) - Seiteninhalt wird nicht bewertet; spaeter pruefen: curl -s %s/api/sysboot/status" % (timeout, URL))
    return False


def pruefe_live(seit, vorher, root=BASIS):
    # Hart: Seiten antworten (vorher 200 -> nachher 200), keine Seriennummern, Journal, die eigene Aenderung (/adsb).
    # Nur Hinweis: Layout-Marker, die dieses Paket nicht verantwortet (Navigation, snMask-Skript, USB-Wache, Alarm-Zeile ...).
    ok, seiten = warte_200(["/", "/pi", "/adsb"], 45)
    if not ok:
        return False
    alle = SEITEN_KERN + SEITEN_MEHR + API_LESEN
    war200 = [p for p in alle if p not in seiten and vorher["codes"].get(p) == "200"]
    ok2, mehr = warte_200(war200, 45) if war200 else (True, {})
    seiten.update(mehr)
    if not ok2:
        print("STOP eine vorher erreichbare Seite antwortet nicht mehr")
        ok = False
    warte_bereit(int(os.environ.get("FS_BEREIT_WAIT") or 150))
    laed = set()
    for p in list(seiten):
        if 'id="sbLoading"' in seiten[p]:
            code, body = _get(p, 20)
            if code == "200":
                seiten[p] = body
            if 'id="sbLoading"' in seiten[p]:
                laed.add(p)
    if laed:
        print("Hinweis: noch Ladehinweis auf %s - Inhalt dort nicht bewertet" % ", ".join(sorted(laed)))
    sns = echte_seriennummern(root)
    gesamt = 0
    for p, body in seiten.items():
        t = sn_treffer(body, sns)
        gesamt += t
        if t:
            print("STOP %s enthaelt %d echte Seriennummer(n)" % (p, t))
            ok = False
    print("%d Seiten/Antworten geprueft (%d Seriennummern aus der Konfiguration), echte Seriennummern: %d" % (len(seiten), len(sns), gesamt))
    # --- nur Hinweise (Layout/Funktion anderer Pakete) ---
    hinweise = []
    fm = [m for m in vorher.get("funk_marker", []) if "/funk" in seiten and "/funk" not in laed and m not in seiten["/funk"]]
    if fm:
        hinweise.append("/funk ohne %s gegenueber vorher" % ", ".join(fm))
    for p, marker in (("/", ("snm-js", "inet-split-js")), ("/pi", ("snm-js", "usbwBox", "pushoverBox")), ("/funk", ("snm-js",)),
                      ("/rundfunk", ("snm-js",)), ("/aprs", ("snm-js",))):
        if p in seiten and p not in laed:
            fehlt = [m for m in marker if m not in seiten[p]]
            if fehlt:
                hinweise.append("%s ohne %s" % (p, ", ".join(fehlt)))
    if "/" in seiten and "/" not in laed and not _t4why_ok(seiten["/"]):
        hinweise.append("/ ohne Alarm-Zeile (t4Why)")
    for p in ("/api/snmask", "/api/inet_split", "/api/t4/status", "/api/sdr/status"):
        if p in seiten:
            try:
                json.loads(seiten[p])
            except ValueError:
                hinweise.append("%s kein gueltiges JSON" % p)
    for h in hinweise:
        print("Hinweis: %s (Layout/Funktion anderer Pakete, kein Rollback-Grund)" % h)
    if not hinweise:
        print("Layout-Marker wie vorher (nur Hinweis-Pruefung)")
    # --- eigene Aenderung ---
    try:
        if "/adsb" in laed:
            print("Hinweis: /adsb zeigt noch den Ladehinweis - Breite nicht geprueft; spaeter: curl -s %s/adsb | grep -c 'id=\"sf-css\"'" % URL)
        else:
            ok = bool(live_extra(seiten)) and ok
    except Exception as exc:
        print("STOP Paket-Pruefung: %s: %s" % (type(exc).__name__, exc))
        ok = False
    try:
        zeilen = journal_zeilen(DIENST, seit)
        bad = [ln for ln in zeilen if "Traceback" in ln]
        if bad:
            print("STOP Journal %s enthaelt Traceback" % DIENST)
            for ln in bad[:6]:
                print(ln[:160])
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (DIENST, len(zeilen)))
        if vorher.get("fehler") is None:
            print("Hinweis: Journal vor dem Neustart nicht lesbar - kein Vergleich neuer FEHLER-Zeilen")
        else:
            neu_f = sorted(_fehler_keys(zeilen) - vorher["fehler"])
            if neu_f:
                print("STOP Journal hat neue FEHLER-/Traceback-Zeilen (nicht vor dem Neustart):")
                for k in neu_f[:6]:
                    print("  " + k)
                ok = False
            else:
                print("Journal: keine neuen FEHLER-Zeilen gegenueber vor dem Neustart (%d bekannte)" % len(vorher["fehler"]))
        for pflicht in JOURNAL_PFLICHT:
            if not any(pflicht in ln for ln in zeilen):
                print("STOP Journal ohne Zeile '%s'" % pflicht)
                ok = False
        for kennung in JOURNAL_VERBOTEN:
            if any(kennung in ln for ln in zeilen):
                print("STOP Journal meldet '%s'" % kennung)
                ok = False
    except (OSError, subprocess.TimeoutExpired):
        print("STOP Journal %s unlesbar" % DIENST)
        ok = False
    code, body = _get("/api/lage_grund", 10)
    if code == "200":
        try:
            print("Lage (Info): %s" % str((json.loads(body).get("lage") or {}).get("text")))
        except ValueError:
            pass
    return ok


# ----------------------------------------------------------------- Anwenden
def _rueckbau(pfad, alt, neustart):
    try:
        schreibe(pfad, alt)
        print("ZURUECKGESETZT dashboard.py sha256 %s" % stand(alt)[0])
        if neustart and restart_dienst(DIENST) == 0:
            warte_200(["/", "/pi"], 45)
    except Exception as exc:
        print("Rueckbau-Fehler: %s - bitte dashboard.py.bak-%s-* zurueckkopieren" % (exc, KENNUNG))


def anwenden(root, dry, kein):
    pfad = os.path.join(root, "dashboard.py")
    try:
        alt, neu = berechne(root)
    except Stop as exc:
        print(exc)
        return 2
    except SyntaxError as exc:
        print("STOP Syntaxfehler im Ergebnis: %s" % exc)
        return 3
    if neu is None:
        print("dashboard.py bereits auf Endstand, unveraendert")
        return 0
    print("dashboard.py %d -> %d Bytes sha256 %s" % (len(alt), len(neu), sha256(neu)))
    print("Neustart: %s" % DIENST)
    if dry:
        print("dry-run: keine Datei geschrieben, kein Neustart")
        return 0
    vorher = vorher_stand() if not kein else {"codes": {}}
    if not kein:
        print("Vorher: %d Seiten 200" % sum(1 for c in vorher["codes"].values() if c == "200"))
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    try:
        bak = sichern(pfad, stempel)
        print("Backup %s" % bak)
        schreibe(pfad, neu)
        hs, ns = stand(open(pfad, "rb").read())
        print("geschrieben dashboard.py sha256 %s bytes %d" % (hs, ns))
        if (hs, ns) != stand(neu):
            raise Stop("STOP geschriebene Datei weicht ab")
        if not pyflakes_vergleich(bak, pfad):
            raise Stop("STOP pyflakes dashboard.py")
    except (Stop, OSError) as exc:
        print("%s - Rueckbau" % exc)
        _rueckbau(pfad, alt, False)
        return 4
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = restart_dienst(DIENST)
    if rc != 0:
        _rueckbau(pfad, alt, True)
        return rc
    if not pruefe_live(seit, vorher, root):
        print("STOP Pruefung fehlgeschlagen - Rueckbau (Sicherung: %s)" % os.path.basename(bak))
        _rueckbau(pfad, alt, True)
        return 5
    print("ok, Dienst: %s (prepper-sdr nicht angefasst)" % DIENST)
    return 0


# ----------------------------------------------------------------- Selbsttest (isoliert, ohne den Dienst zu importieren)
def selftest(basis=BASIS):
    try:
        assert _restart_ok(1, {"pid": "1", "ts": "a", "active": "active"}, {"pid": "2", "ts": "b", "active": "active"}) is False
        assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "10", "ts": "A", "active": "active"}) is False
        assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "11", "ts": "B", "active": "active"}) is True
        print("selftest Neustart-Check ok")
        raw = basis_pruefen(basis)
        t0 = raw.decode("utf-8")
        t = patch_dash(t0)
        assert patch_dash(t) == t, "nicht idempotent"
        assert stand(t.encode("utf-8")) == DASH_ENDE, "Endhash %s" % stand(t.encode("utf-8"))[0][:16]
        print("selftest Endhash ok %s" % DASH_ENDE[0][:16])
        for name in ("snMask aktiv:", "def _psh_cfg_sauber", "def _fs4_t4_after", "fs4Hint", "t4Why", "def _inet_split", "usbwache Anzeige:"):
            assert name in t, "Erhaltenes fehlt: %s" % name
        assert t.count("app.after_request(_fs4_t4_after)") + t.count("funcs[i] = _fs4_t4_after") >= 1
        selftest_extra(t0, t)
        print("selftest Paket ok")
        # Syntax/Kompilieren
        compile(t, "dashboard.py", "exec")
        print("selftest compile ok")
    except Exception as exc:
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
