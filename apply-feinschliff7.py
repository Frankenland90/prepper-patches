#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-feinschliff7: lange Hinweistexte gekuerzt. Sicherheitshinweise nur gekuerzt, nie geloescht.

Paket 7. Nur dashboard.py (Stand nach Paket 6). prepper_sdr.py und sdr_manager.py werden nur geprueft. Neustart: nur prepper-dashboard.
Vorbefund: seitenFlach kuerzt schon viele Texte. Es blieben (gemessen am gerenderten DOM, Text > 120 Zeichen, statisch):
- /pi, Alarm-Ansage: die vorhandene Regel passte nicht mehr (der Text hat inzwischen einen Zusatz "Ansage: thorsten-high, ..."); jetzt zwei kurze Zeilen.
  Sicherheitshinweise bleiben: KATASTROPHE immer 100 % (auch stumm/nachts), Stumm nur INFO/WARNUNG und max 8 h, Test nie ins Mesh, max alle 10 s.
- /dabhist, Grenzwert-Hinweis (zugeklappt): gekuerzt, die Zahlen bleiben.
- /system und /umwelt, Hinweise zu Rauschboden, Kurve und Gewitter (Zusatzinfo): gekuerzt; "keine Peilung/Garantie" und "keine Ortung, keine Unwetterwarnung" bleiben.
- /speicher, zwei Quellen-/Vorzeichen-Zeilen: gekuerzt, Quelle bleibt.
Technik: neue Eintraege in _SF_PAGES und _SF_RULES (genaue Textersetzung, kein Treffer = Seite unveraendert); keine Funktion geaendert.
Nicht angefasst: dynamische Statuszeilen (Datenquelle, Stick-Zeilen, Ereignisse) und die Klinik-/Sprechzeiten auf /zuhause (Auskunft, nicht Hinweis).
Erhalten: snMask, inet_split, usbwache, _psh_cfg_sauber, feinschliff4/5/6, Flugfunk-Logik. Keine Zeitsperre, keine Seriennummern in der Ausgabe."""
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

KENNUNG = "feinschliff7"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"
FESTE_SN = ()
VORGAENGER = "Paket 6"
DASH_START = ('2cb515c5be16726a9e0041e178732a2846593cf60557f5dfbba597750694aae8', 1468490)   # Stand nach Paket 6
DASH_ENDE = ('edb87829a843b909adade2375e349e53aff6dd5762d501ed6ef0e2d5413bb7cb', 1472250)
SDR_SOLL = ("ad62d9a56c6aa682246945bae7b65eaa75afb216b5a20dd1d4881ea42cc0d85c", 820331)      # prepper_sdr.py nach Paket 3b (unveraendert)
SM_SOLL = ("5a26efff608bf541a929fa775112d3593883a7423b6d9f6f29e61dc9b14db181", 288008)       # sdr_manager.py (unveraendert)
VORSTAENDE = {}
JOURNAL_PFLICHT = ["snMask aktiv:", "inetSplit aktiv", "usbwache Anzeige:", "feinschliff4 aktiv:"] + ['feinschliff5 aktiv:', 'seitenFlach aktiv:', 'funkFlach aktiv:']
JOURNAL_VERBOTEN = ["snMask Selbsttest FEHLER", "snMask FEHLER", "feinschliff4 Selbsttest FEHLER", "feinschliff4 FEHLER", "inetSplit FEHLER", "teil4 Lage-Seite:"] + ['feinschliff5 Menue:', 'feinschliff5 FEHLER', 'seitenFlach FEHLER', 'funkFlach FEHLER']


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

SCHON = "# feinschliff7:"

P_PG_ALT = '"/mesh", "/mesh2", "/zuhause")   # feinschliff6: /mesh2, /zuhause\n'
P_PG_NEU = '"/mesh", "/mesh2", "/zuhause", "/system", "/umwelt", "/speicher")   # feinschliff6: /mesh2, /zuhause; feinschliff7: /system, /umwelt, /speicher\n'

_AUI_ALT = ('<div class="aui-note">KATASTROPHE (echter Alarm) spielt immer mit 100 %, auch stumm und nachts, danach zur&uuml;ck auf den Regler. '
            'Stumm gilt nur f&uuml;r INFO/WARNUNG und endet nach 8 h von selbst. Test: Gong + kurze Ansage mit Regler-Pegel, nie ins Mesh, '
            'h&ouml;chstens alle 10 s. Ansage: thorsten-high, sonst mb-de7, sonst espeak.</div>')
_AUI_NEU = ('<div class="aui-note">KATASTROPHE immer 100 % (auch stumm/nachts) · Stumm nur INFO/WARNUNG, max 8 h</div>'
            '<div class="aui-note">Test: Gong + Ansage, nie ins Mesh, max alle 10 s · Stimme thorsten-high/mb-de7/espeak</div>')
_NOISE_ALT = ('Rauschboden je Band gegen Grundlinie (Median 7 Tage, MW/KW je Tagesstunde; Schwelle max(5 dB, 4×MAD) gelb, max(10 dB, 6×MAD) rot), '
              'langsamer Anstieg als ↗ Trend, neue Dauerträger. Nur Leistungsmessung, kein Inhalt.')
_NOISE_NEU = 'Rauschboden je Band vs. Grundlinie (7 Tage) · gelb 4×MAD, rot 6×MAD · nur Leistung'
_KURVE_ALT = 'Kurve: Rauschboden (dB, relativ) des gewählten Bandes. Hinweis, keine Peilung oder Garantie: eigene Geräte (Netzteile, Pi, LED) stören oft selbst.'
_KURVE_NEU = 'Kurve: Rauschboden (dB, relativ) · keine Peilung/Garantie · eigene Geräte stören oft'
_SFER_ALT = ('Nur ein Hinweis: Blitze erzeugen kurze breitbandige Knackse (Sferics) auf Mittel-/Kurzwelle, aber auch Weidezäune, Zündanlagen und Schaltnetzteile. '
             'Braucht Direktabtastung (NESDR SMArt v5) und eine Draht-/KW-Antenne; keine Entfernungs- oder Blitzortung, keine Unwetterwarnung.')
_SFER_NEU = 'Nur Hinweis: Blitze = Knackse (Sferics) auf MW/KW · keine Ortung, keine Unwetterwarnung'
_SP1_ALT = '− Entnahme · + Befüllung · Fluss ist Einspeisung minus Ausspeisung (TWh je Gastag), nicht die Bestandsänderung · Quelle: GIE AGSI'
_SP1_NEU = '− Entnahme · + Befüllung · Fluss = Ein- minus Ausspeisung (TWh/Gastag) · Quelle: GIE AGSI'
_SP2_ALT = '− Entnahme (Ausspeisung) · kein Plus · 5-Tage-Mittel · ohne Nachlieferung, Anlandung zählt nicht · 1 Tag bei einem Gastag · Quelle: GIE ALSI'
_SP2_NEU = '− Entnahme (Ausspeisung) · 5-Tage-Mittel · ohne Nachlieferung · Quelle: GIE ALSI'
_DAB_ALT = (r'<div class="fu-note">SNR niedrig unter ([0-9.]+) dB \(gut ab ([0-9.]+) dB\) · FIC-Fehlerrate schlecht über ([0-9.]+) % \(gut unter ([0-9.]+) %\) · '
            r'je ([0-9]+) Messungen in Folge · Standardwerte, einstellbar in sdr_config\.json \([^)<]*\)</div>')
_DAB_NEU = r'<div class="fu-note">SNR niedrig &lt;\1 dB (gut ab \2) · FIC-Fehler &gt;\3 % (gut &lt;\4 %) · \5 Messungen in Folge · Werte: sdr_config.json</div>'

_RULES = [("/pi", "s", _AUI_ALT, _AUI_NEU), ("/dabhist", "r", _DAB_ALT, _DAB_NEU), ("/system", "s", _NOISE_ALT, _NOISE_NEU), ("/system", "s", _KURVE_ALT, _KURVE_NEU),
          ("/system", "s", _SFER_ALT, _SFER_NEU), ("/umwelt", "s", _NOISE_ALT, _NOISE_NEU), ("/umwelt", "s", _KURVE_ALT, _KURVE_NEU), ("/umwelt", "s", _SFER_ALT, _SFER_NEU),
          ("/speicher", "s", _SP1_ALT, _SP1_NEU), ("/speicher", "s", _SP2_ALT, _SP2_NEU)]

P_RULE_ALT = '     "margin-top:12px;padding:12px 0 0;border-top:1px solid #334155"),\n]\n_SF = {"hits"'
P_RULE_NEU = ('     "margin-top:12px;padding:12px 0 0;border-top:1px solid #334155"),\n'
              '    # feinschliff7: lange Hinweistexte kurz, Sicherheitshinweise bleiben (gekuerzt)\n'
              + "".join("    (%r, %r, %r,\n     %r),\n" % r for r in _RULES) + ']\n_SF = {"hits"')

PATCHES = [("_SF_PAGES", P_PG_ALT, P_PG_NEU), ("_SF_RULES", P_RULE_ALT, P_RULE_NEU)]


def patch_extra(text):
    return text


def live_extra(seiten):
    ok = True
    pi = seiten.get("/pi", "")
    if "Ansage: thorsten-high, sonst mb-de7" in pi or "KATASTROPHE (echter Alarm)" in pi:
        print("STOP /pi: Ansage-Hinweis noch lang")
        ok = False
    if "KATASTROPHE" in pi and "nie ins Mesh" not in pi:
        print("STOP /pi: Sicherheitshinweis 'nie ins Mesh' fehlt")
        ok = False
    for p in ("/system", "/umwelt"):
        b = seiten.get(p, "")
        if "Nur ein Hinweis: Blitze erzeugen kurze breitbandige" in b or "Rauschboden je Band gegen Grundlinie (Median 7 Tage, MW/KW" in b:
            print("STOP %s: Rauschboden-/Gewitter-Hinweis noch lang" % p)
            ok = False
        if "Rauschboden je Band" in b and "keine Unwetterwarnung" not in b:
            print("STOP %s: Unwetter-Hinweis fehlt" % p)
            ok = False
        if 'id="sf-css"' not in b:
            print("STOP %s ohne sf-css (seitenFlach)" % p)
            ok = False
    if "Anlandung zählt nicht" in seiten.get("/speicher", "") or "Fluss ist Einspeisung minus" in seiten.get("/speicher", ""):
        print("STOP /speicher: Hinweis noch lang")
        ok = False
    if ok:
        print("Hinweistexte: /pi, /system, /umwelt, /speicher gekuerzt; Sicherheitshinweise (nie ins Mesh, keine Unwetterwarnung) vorhanden")
    return ok


def selftest_extra(t0, t):
    assert t.count("# feinschliff7:") == 1, t.count("# feinschliff7:")
    assert "nie ins Mesh" in t and "KATASTROPHE immer 100 %" in t
    assert '"/system", "/umwelt", "/speicher")' in t
    import re as _r
    # die neuen kurzen Texte muessen den Selbsttest von seitenFlach bestehen (s-Regeln: Text < 90 Zeichen oder mehrere Zeilen)
    i = t.index("# feinschliff7: lange Hinweistexte"); j = t.index('_SF = {"hits"', i)
    ns = {}
    exec("R = [\n" + t[t.index("\n", i) + 1:j].rsplit("]", 1)[0] + "]", ns)
    assert len(ns["R"]) == 10
    for pg, kind, old, new in ns["R"]:
        if kind == "s" and "+" not in new:
            assert len(_r.sub(r"<[^>]+>|&[a-z]+;", "", new)) < 90 or "</div><div" in new, new
        assert old != new and (pg in ("/pi", "/dabhist") or '"' not in new and "\\" not in new), new
    # Regex-Regel trifft das Beispiel
    alt = '<div class="fu-note">SNR niedrig unter 5 dB (gut ab 7 dB) · FIC-Fehlerrate schlecht über 10 % (gut unter 3 %) · je 2 Messungen in Folge · Standardwerte, einstellbar in sdr_config.json (tech_snr_low_db, tech_snr_ok_db)</div>'
    pg, kind, old, new = [r for r in ns["R"] if r[0] == "/dabhist"][0]
    assert _r.sub(old, new, alt) == '<div class="fu-note">SNR niedrig &lt;5 dB (gut ab 7) · FIC-Fehler &gt;10 % (gut &lt;3 %) · 2 Messungen in Folge · Werte: sdr_config.json</div>'


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
        raise Stop("STOP Basis stimmt nicht: prepper_sdr.py %s/%d ist nicht ad62d9a5.../820331 (Paket 3b). Nichts veraendert." % (s[0][:16], s[1]))
    m = stand(lies("sdr_manager.py"))
    if m != SM_SOLL:
        raise Stop("STOP Basis stimmt nicht: sdr_manager.py %s/%d ist nicht 5a26efff.../288008. Nichts veraendert." % (m[0][:16], m[1]))
    print("Basis ok: dashboard.py %s (%s), prepper_sdr.py ad62d9a5, sdr_manager.py 5a26efff" % (ds[0][:16], "Stand nach " + VORGAENGER if ds == DASH_START else "Endstand"))
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
        if p == "/funk" and code == "200":
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


def pruefe_live(seit, vorher, root=BASIS):
    ok, seiten = warte_200(SEITEN_KERN + ["/api/sdr/status", "/api/snmask", "/api/inet_split", "/api/lage_grund", "/api/t4/status"], 45)
    if not ok:
        return False
    sns = echte_seriennummern(root)
    print("geprueft gegen %d Seriennummern (aus der Konfiguration)" % len(sns))
    gesamt = n_ok = 0
    for p in SEITEN_KERN + SEITEN_MEHR + API_LESEN:
        if p in seiten:
            code, body = "200", seiten[p]
        else:
            code, body = _get(p, 12)
        if code != "200":
            if p in SEITEN_KERN or vorher["codes"].get(p) == "200" or p == "/api/lage_grund":
                print("STOP %s -> %s" % (p, code))
                ok = False
            continue
        n_ok += 1
        seiten[p] = body
        t = sn_treffer(body, sns)
        gesamt += t
        if t:
            print("STOP %s enthaelt %d echte Seriennummer(n)" % (p, t))
            ok = False
    print("%d Seiten/Antworten geprueft, echte Seriennummern: %d" % (n_ok, gesamt))
    for m in vorher.get("funk_marker", []):
        if m not in seiten.get("/funk", ""):
            print("STOP /funk hat '%s' verloren (war vorher da)" % m)
            ok = False
    for p in ("/", "/pi", "/funk", "/rundfunk", "/aprs"):
        if 'id="snm-js"' not in seiten.get(p, ""):
            print("STOP %s ohne snm-js (snMask)" % p)
            ok = False
        mm = re.search(r'id="sdrPiData">(.*?)</script>', seiten.get(p, ""), re.S)
        if mm:
            try:
                json.loads(mm.group(1))
            except ValueError:
                print("STOP sdrPiData auf %s kein gueltiges JSON" % p)
                ok = False
    try:
        st = json.loads(seiten.get("/api/sdr/status") or "null")
        if not (isinstance(st, dict) and "status" in st):
            raise ValueError("/api/sdr/status ohne status")
        sm = json.loads(seiten.get("/api/snmask") or "null")
        if not (isinstance(sm, dict) and sm.get("aktiv") is True and not sm.get("fehler")):
            raise ValueError("snmask nicht aktiv")
        print("/api/snmask ok: %s Namen (snMask erhalten)" % sm.get("anzahl"))
        sp = json.loads(seiten.get("/api/inet_split") or "null")
        if not (isinstance(sp, dict) and isinstance(sp.get("dsl"), dict) and isinstance(sp.get("sl"), dict)):
            raise ValueError("inet_split ohne dsl/sl")
        print("/api/inet_split ok: DSL %s, Starlink %s, Lage-Wirkung %s" % (sp["dsl"].get("txt"), sp["sl"].get("txt"), sp.get("lage")))
        t4 = json.loads(seiten.get("/api/t4/status") or "null")
        lv = (t4 or {}).get("level") or {}
        if not str(lv.get("line") or "").startswith("Alarm: "):
            raise ValueError("t4 level ohne Alarm-Zeile")
        if lv.get("lvl") == "offline":
            raise ValueError("t4 level offline (SDR-Technik darf die Lage nicht faerben)")
        print("/api/t4/status ok: %s (live %s)" % (lv["line"][:110], t4.get("live")))
        li = json.loads(seiten.get("/api/sdr/live") or "null")
        if not (isinstance(li, dict) and li.get("status")):
            raise ValueError("/api/sdr/live ohne status")
        print("/api/sdr/live ok: %s" % li.get("status"))
        ps = json.loads(seiten.get("/api/pushover") or "null")
        if "src_pinneberg" in json.dumps(ps):
            raise ValueError("/api/pushover nennt src_pinneberg (_psh_cfg_sauber)")
    except Exception as exc:
        print("STOP API-Pruefung: %s" % exc)
        ok = False
    home = seiten.get("/", "")
    alarm_ok, home2 = warte_alarm(60, home)
    if home2:
        seiten["/"] = home = home2
    if not alarm_ok:
        print("STOP / ohne Alarm-Zeile unter der Lage")
        ok = False
    if "Warnungen vorhanden" in home:
        print("STOP / zeigt noch 'Warnungen vorhanden'")
        ok = False
    if 'id="inet-split-js"' not in home:
        print("STOP / ohne inet-split-js")
        ok = False
    for p in ("/pi", "/system"):
        if 'id="usbwBox"' not in seiten.get(p, ""):
            print("STOP %s ohne usbwBox (usbwache)" % p)
            ok = False
    if 'id="pushoverBox"' not in seiten.get("/pi", ""):
        print("STOP /pi ohne Pushover-Kachel")
        ok = False
    for p in ENTFERNT_404:
        code, _ = _get(p)
        if code != "404":
            print("STOP %s liefert %s, erwartet 404" % (p, code))
            ok = False
    try:
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
    if ok:
        ok = lage_check()
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
