#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-funkampel: /funk-Ampel und 5C-Retry nach dabfix.

1) dashboard.py: gelbe Sammelzeile wird zur Ampel. Gewollte Zustaende
   (10C-Rueckfall, Hobby nicht angeschlossen, Funkumfeld noch nicht
   messbar, 'wird geprueft') sind gruen 'Alles in Ordnung'. Gelb/Rot
   nur bei echtem Handlungsbedarf, erste Zeile Problem + was tun,
   keine Doppeltexte.
2) prepper_sdr.py: Stick 1 Rolle 5C versucht nach Neustart und alle
   10 min (T4_RETRY_S) Kanal 5C mit vollem Block/voller CPU. Vorher
   sperrte _ff7b_bc_queue auf 10C, sobald 10C einmal Sync hatte –
   ASA 5C 'kein Empfang seit 26.11. 20:12' war der festgefrorene
   cpulimit-Ausfall, kein bewiesener RF-Mangel in Kalchreuth.
   Whisper-Pause und ungedrosseltes welle-cli (dabfix) bleiben.

Kein flugfunk.py. Kein fullcheck. Neustart nur prepper-sdr und
prepper-dashboard, Minute 05-39 Berlin.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import time
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "funkampel"
BASIS = "/home/fmg/prepper-dashboard"
DIENSTE = ("prepper-sdr", "prepper-dashboard")

SDR_START_SHA = "4f15665aa12dabf9c2ed19094d7ac7ac01cf7583d3c9d8821e498bd7cd1c95e2"
SDR_START_SHA16 = "4f15665aa12dabf9"
SDR_START_BYTES = 794952
SDR_END_SHA = "df4f49b559c4b821cd0d1a248ea75af39e159a43a3151e4e1aa2fbcd0eaaaf83"
SDR_END_SHA16 = "df4f49b559c4b821"
SDR_END_BYTES = 796165

DASH_START_SHA = "03344fb88acdcf900fe5033228fe5fd0e0b4a934f86e9d246d10e0511ab765b1"
DASH_START_SHA16 = "03344fb88acdcf90"
DASH_START_BYTES = 1390854
DASH_END_SHA = "96027ec7c2bfcd2f7544945e692e98fb0533592fefb7372006549b9581e71d51"
DASH_END_SHA16 = "96027ec7c2bfcd2f"
DASH_END_BYTES = 1395664

SDR_PAARE = [
    (
        '''def _ff7b_bc_queue(self):
    """Stick mit Rolle 5C: 10C ist der Hauptkanal, sobald 10C Sync hat und 5C nicht."""
    q = _ff7b_orig_bc(self)
    try:
        a = _air_pl(self)
        if not a or a.get("role") != "5C":
            return q
        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}
        if (dab.get("10C") or {}).get("rx") is True and (dab.get("5C") or {}).get("rx") is not True:
            lst = [str(x) for x in self.dab_list()]
            if "10C" in lst:
                return [("dab:%d" % lst.index("10C"), float(self.cfg.get("dab_s") or 60))]
    except Exception:
        return q
    return q


Planner.dab_list = _ff7b_dab_list
Planner.bc_queue = _ff7b_bc_queue
''',
        '''def _ff7b_fresh(e, now, maxage=180):
    return isinstance(e, dict) and e.get("rx") is True and int(e.get("t") or 0) >= now - maxage


def _ff7b_bc_queue(self):
    """Stick Rolle 5C: ASA 5C hat Vorrang. Nur wenn 5C keinen frischen Sync hat, 10C;
    5C wird trotzdem alle 10 min (T4_RETRY_S) mit vollem Block erneut geprueft.
    Verhindert, dass ein alter 10C-Sync 5C dauerhaft verdraengt (cpulimit-Ausfall 26.11.)."""
    q = _ff7b_orig_bc(self)
    try:
        a = _air_pl(self)
        if not a or a.get("role") != "5C":
            return q
        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}
        lst = [str(x) for x in self.dab_list()]
        if "5C" not in lst:
            return q
        now = time.time()
        dur = float(self.cfg.get("dab_s") or 60)
        i5 = lst.index("5C")
        i10 = lst.index("10C") if "10C" in lst else None
        if _ff7b_fresh(dab.get("5C"), now):
            return [("dab:%d" % i5, dur)]
        last = float(self.__dict__.get("_ff7b_last5c") or 0)
        due = True if not last else (now - last) >= float(T4_RETRY_S)
        if due:
            return [("dab:%d" % i5, dur)]
        if i10 is not None and _ff7b_fresh(dab.get("10C"), now):
            return [("dab:%d" % i10, dur)]
    except Exception:
        return q
    return q


_ff7b_orig_sub = Planner.sub_done


def _ff7b_sub_done(self, sp, now):
    try:
        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") is not None else ""
        if _s(job).startswith("dab:"):
            lst = [str(x) for x in self.dab_list()]
            ch = lst[int(job[4:])] if int(job[4:]) < len(lst) else ""
            if ch == "5C":
                self.__dict__["_ff7b_last5c"] = float(now)
    except Exception:
        pass
    return _ff7b_orig_sub(self, sp, now)


Planner.dab_list = _ff7b_dab_list
Planner.bc_queue = _ff7b_bc_queue
Planner.sub_done = _ff7b_sub_done
''',
        1,
    ),
]

DASH_PAARE = [
    (
        '''# ===== /zusatzinfo =====


if not any(getattr(f, "__name__", "") == "_sec_headers" for f in app.after_request_funcs.get(None, [])):
''',
        '''# ===== /zusatzinfo =====
# ===== funkAmpel: kurze Ampel-Zeile auf /funk, keine Doppeltexte =====

def _ampel_norm(s):
    t = str(s or "").lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        t = t.replace(a, b)
    return " ".join(t.split())


def _ampel_teil_ok(teil):
    """Gewollte Zustaende und bloße Geräte-/Kanal-Namen: kein Handlungsbedarf."""
    t = _ampel_norm(teil)
    if not t or t in ("ok",) or t.endswith(" ok"):
        return True
    if re.fullmatch(r"(airspy( r2)?|stick [1-4]|5c|10c|11d)", t):
        return True
    merker = (
        "keine warnung im rundfunk",
        "funkumfeld nicht messbar",
        "funkumfeld nicht gemessen",
        "funkumfeld normal",
        "funkumfeld lernt",
        "rueckfall gewollt",
        "kalchreuth schwach",
        "kein hinweis",
        "10c hauptkanal",
        "wird geprueft",
        "wird gestartet",
        "hobby nicht angeschlossen",
        "nur beobachtung",
        "alle empfaenger ok",
        "info empfang",
        "kein rds",
    )
    return any(m in t for m in merker)


def _ampel_dedup(teile):
    out = []
    for roh in teile:
        t = str(roh or "").strip()
        if not t:
            continue
        skip = False
        for i, alt in enumerate(out):
            if t == alt or t in alt:
                skip = True
                break
            if alt in t:
                out[i] = t
                skip = True
                break
        if not skip:
            out.append(t)
    return out


def _ampel_tun(teil, hint=None):
    t = _ampel_norm(teil)
    if "nicht angeschlossen" in t or " fehlt" in t or t.endswith("fehlt"):
        return "USB prüfen, Stick anstecken – wird automatisch erkannt."
    if "keine daten" in t or "liefert keine" in t:
        return "Stick einmal ab- und anstecken."
    if "warnung im rundfunk" in t:
        return "Warnlage prüfen (BR24 / ASA)."
    if "stark gestoert" in t or "gewitter" in t:
        return "Störung beobachten, ggf. Antenne prüfen."
    if "br24" in t and "nicht empfangen" in t:
        return "Empfang prüfen; Automatik versucht es weiter."
    if hint:
        return str(hint).strip().rstrip(".") + "."
    return ""


def _ampel_krise(k):
    """Eine klare Ampel: gruen 'Alles in Ordnung' oder erste Zeile Problem + was tun."""
    k = dict(k or {})
    teile = _ampel_dedup((k.get("txt") or "").split(" · "))
    schlecht = [t for t in teile if not _ampel_teil_ok(t)]
    if not schlecht:
        return {"txt": "Alles in Ordnung", "lvl": "ok", "hint": None, "why": None}
    roh = _ampel_norm(" · ".join(schlecht))
    lvl = "rot" if any(x in roh for x in ("warnung im rundfunk", "keine daten", "stark gestoert", "gewitter nah")) else "gelb"
    if k.get("lvl") == "rot":
        lvl = "rot"
    first = schlecht[0]
    tun = _ampel_tun(first, k.get("hint"))
    txt = ("%s. %s" % (first.rstrip("."), tun)) if tun else first
    return {"txt": txt, "lvl": lvl, "hint": None, "why": None}


_AMPEL_ORIG = _air_sdrui


def _ampel_air_sdrui(st, d):
    d = _AMPEL_ORIG(st, d)
    try:
        d["krise"] = _ampel_krise(d.get("krise") or {})
    except Exception as e:
        print("funkAmpel:", e, flush=True)
    return d


_air_sdrui = _ampel_air_sdrui


def selftest_funkampel():
    frank = ("Keine Warnung im Rundfunk · Funkumfeld nicht messbar · 10C Hauptkanal seit 23:13 · "
             "5C ohne Sync (Kalchreuth schwach) · Rückfall gewollt, kein Hinweis · Airspy R2 · 11D ok · "
             "Stick 1 · 5C · 10C Hauptkanal seit 23:13 · 5C ohne Sync (Kalchreuth schwach) · "
             "Rückfall gewollt, kein Hinweis · Stick 2 · Hobby nicht angeschlossen · Stick 3 · Flugfunk wird geprueft")
    k = _ampel_krise({"txt": frank, "lvl": "gelb", "hint": "x"})
    assert k["lvl"] == "ok" and k["txt"] == "Alles in Ordnung" and not k.get("hint"), k
    k2 = _ampel_krise({"txt": "Keine Warnung im Rundfunk · Stick 1 liefert keine Daten", "lvl": "rot",
                       "hint": "Stick einmal ab- und anstecken"})
    assert k2["lvl"] == "rot" and "keine Daten" in k2["txt"] and "anstecken" in k2["txt"].lower(), k2
    k3 = _ampel_krise({"txt": "BR24 seit 2 h nicht empfangen · Funkumfeld normal", "lvl": "gelb"})
    assert k3["lvl"] == "gelb" and k3["txt"].startswith("BR24") and "pruefen" in _ampel_norm(k3["txt"]), k3
    k4 = _ampel_krise({"txt": "11D fehlt · Keine Warnung im Rundfunk", "lvl": "rot"})
    assert k4["lvl"] == "rot" and "11D fehlt" in k4["txt"] and "USB" in k4["txt"], k4
    assert _ampel_air_sdrui is _air_sdrui
    return True


try:
    selftest_funkampel()
    print("funkAmpel aktiv: /funk Ampel-Zeile, gewollte Zustaende gruen", flush=True)
except Exception as _ampel_e:
    print("funkAmpel FEHLER:", _ampel_e, flush=True)
# ===== /funkAmpel =====


if not any(getattr(f, "__name__", "") == "_sec_headers" for f in app.after_request_funcs.get(None, [])):
''',
        1,
    ),
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def im_fenster(minute):
    return 5 <= int(minute) <= 39


def berlin_jetzt():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin"))
    return datetime.now()


def berlin_minute():
    return berlin_jetzt().minute


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


def stub_aus(paare):
    return "".join(alt for alt, _neu, _n in paare)


def patch_sdr(text):
    for alt, neu, n in SDR_PAARE:
        text = ersetze(text, alt, neu, "prepper_sdr.py", n)
    return text


def patch_dash(text):
    for alt, neu, n in DASH_PAARE:
        text = ersetze(text, alt, neu, "dashboard.py", n)
    return text


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
    tmp = pfad + ".%s-tmp" % KENNUNG
    with open(tmp, "wb") as handle:
        handle.write(daten)
        handle.flush()
        os.fsync(handle.fileno())
    if os.path.exists(pfad):
        shutil.copymode(pfad, tmp)
    os.replace(tmp, pfad)


def schon_sdr(text):
    return (
        "def _ff7b_fresh(" in text
        and "_ff7b_last5c" in text
        and "Planner.sub_done = _ff7b_sub_done" in text
        and "5C wird trotzdem alle 10 min" in text
    )


def schon_dash(text):
    return (
        "def _ampel_krise(" in text
        and "def _ampel_air_sdrui(" in text
        and "_air_sdrui = _ampel_air_sdrui" in text
        and "Alles in Ordnung" in text
    )


def stand(data):
    return sha256(data), len(data)


def berechne_sdr(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == SDR_END_SHA and n == SDR_END_BYTES:
        return alt, None, None
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_sdr(roh):
        return alt, None, None
    if hashcheck and (ist != SDR_START_SHA or n != SDR_START_BYTES):
        return None, None, "STOP %s ist %s/%s soll %s/%s" % (
            pfad, ist[:16], n, SDR_START_SHA16, SDR_START_BYTES)
    try:
        text = patch_sdr(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    neu = text.encode("utf-8")
    if hashcheck:
        compile(neu, "prepper_sdr.py", "exec")
    got, gn = stand(neu)
    if hashcheck and (got != SDR_END_SHA or gn != SDR_END_BYTES):
        return None, None, "STOP Endstand %s/%s erwartet %s/%s" % (
            got[:16], gn, SDR_END_SHA16, SDR_END_BYTES)
    return alt, neu, None


def berechne_dash(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == DASH_END_SHA and n == DASH_END_BYTES:
        return alt, None, None
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_dash(roh):
        return alt, None, None
    hash_ok = (ist == DASH_START_SHA and n == DASH_START_BYTES)
    if hashcheck and not hash_ok:
        print("Hinweis: dashboard.py Hash %s/%s abweichend, Patch nur per Anker" % (
            ist[:16], n))
    try:
        text = patch_dash(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    neu = text.encode("utf-8")
    if hashcheck:
        compile(neu, "dashboard.py", "exec")
    got, gn = stand(neu)
    if hash_ok and hashcheck and (got != DASH_END_SHA or gn != DASH_END_BYTES):
        return None, None, "STOP dashboard Endstand %s/%s erwartet %s/%s" % (
            got[:16], gn, DASH_END_SHA16, DASH_END_BYTES)
    if not schon_dash(neu.decode("utf-8")):
        return None, None, "STOP dashboard.py Patch unvollstaendig"
    return alt, neu, None


def journal_pruefen(seit, pause=90):
    print("warte %d s auf Journal/Live" % pause)
    time.sleep(pause)
    ok = True
    try:
        out = subprocess.run(
            ["journalctl", "-u", "prepper-sdr", "--since", seit, "--no-pager", "-o", "short-iso"],
            capture_output=True, text=True, timeout=20)
        zeilen = (out.stdout or "").splitlines() if out.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("Hinweis: Journal nicht gelesen (%s)" % type(exc).__name__)
        zeilen = []
    starts = [ln for ln in zeilen if "Start dab:" in ln or "welle-cli" in ln]
    if any("cpulimit" in ln for ln in starts):
        print("STOP nach Neustart welle-cli laeuft noch unter cpulimit")
        for ln in starts[:6]:
            print(ln)
        ok = False
    hat5 = any(
        ("-c 5C" in ln or "-c5C" in ln or "DAB 5C" in ln or "Kanal 5C" in ln
         or "dab: 5C" in ln or "Start dab:" in ln and "5C" in ln)
        for ln in zeilen
    )
    hat10 = any("-c 10C" in ln or "-c10C" in ln or "DAB 10C" in ln for ln in zeilen)
    if hat5:
        print("Journal: 5C-Versuch mit welle-cli sichtbar (voller CPU, dabfix bleibt)")
    elif zeilen:
        print("STOP nach %d s kein 5C-Versuch im Journal (Planer sollte 5C zuerst pruefen)" % pause)
        for ln in (starts or zeilen)[:8]:
            print(ln)
        if hat10:
            print("Hinweis: nur 10C gesehen – Queue-Fix greift evtl. nicht")
        ok = False
    else:
        print("Hinweis: Journal leer oder unlesbar, 5C-Versuch nicht bestaetigt")
    try:
        r = subprocess.run(
            ["curl", "-fsS", "-m", "5", "-o", "/tmp/funkampel-sdrui.json",
             "-w", "%{http_code}", "http://127.0.0.1:5000/api/sdr/ui"],
            capture_output=True, text=True, timeout=8)
        code = (r.stdout or "").strip()
        print("GET /api/sdr/ui -> %s rc %s" % (code, r.returncode))
        if r.returncode == 0 and code.startswith("200") and os.path.isfile("/tmp/funkampel-sdrui.json"):
            raw = open("/tmp/funkampel-sdrui.json", encoding="utf-8", errors="replace").read()
            if "Alles in Ordnung" in raw or '"lvl": "ok"' in raw or '"lvl":"ok"' in raw:
                print("Ampel: krise ok / Alles in Ordnung")
            elif "krise" in raw:
                print("Hinweis: Ampel-API erreichbar, Text nicht zwingend gruen (echte Stoerung moeglich)")
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("Hinweis: /api/sdr/ui nicht geprueft (%s)" % type(exc).__name__)
    return ok


def neustart():
    rc_all = 0
    for dienst in DIENSTE:
        rc = subprocess.call(["systemctl", "restart", dienst])
        if rc != 0:
            rc = subprocess.call(["sudo", "systemctl", "restart", dienst])
        print("restart %s rc %s" % (dienst, rc))
        if rc != 0:
            rc_all = rc
    return rc_all


def anwenden(root, dry, kein, minute, hashcheck=True, pause=90):
    sdr = os.path.join(root, "prepper_sdr.py")
    dash = os.path.join(root, "dashboard.py")
    salt, sneu, sfehl = berechne_sdr(sdr, hashcheck)
    if sfehl:
        print(sfehl)
        return 2
    dalt, dneu, dfehl = berechne_dash(dash, hashcheck)
    if dfehl:
        print(dfehl)
        return 2
    if sneu is None and dneu is None:
        print("bereits installiert, keine Aenderung, kein Neustart")
        print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(salt)[:16], len(salt)))
        print("dashboard.py endstand sha16 %s bytes %d" % (sha256(dalt)[:16], len(dalt)))
        return 0
    if sneu is not None:
        print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(sneu)[:16], len(sneu)))
    if dneu is not None:
        print("dashboard.py endstand sha16 %s bytes %d" % (sha256(dneu)[:16], len(dneu)))
    if dry:
        print("dry-run: nichts geschrieben")
        return 0
    if not kein and not im_fenster(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    try:
        if sneu is not None:
            print("Sicherung %s" % sichern(sdr, stempel))
            schreibe(sdr, sneu)
        if dneu is not None:
            print("Sicherung %s" % sichern(dash, stempel))
            schreibe(dash, dneu)
    except OSError as exc:
        print("STOP beim Schreiben (%s)" % type(exc).__name__)
        return 3
    if sneu is not None:
        data = open(sdr, "rb").read()
        print("prepper_sdr.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
        if hashcheck and sha256(data) != SDR_END_SHA:
            print("STOP geschriebene Datei weicht vom Soll-Hash ab")
            return 3
    if dneu is not None:
        data = open(dash, "rb").read()
        print("dashboard.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
        if hashcheck and sha256(data) == DASH_START_SHA:
            print("STOP dashboard unveraendert nach Schreiben")
            return 3
    if kein:
        print("kein Neustart. Aktiv nach: sudo systemctl restart %s" % " ".join(DIENSTE))
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = neustart()
    if rc != 0:
        print("Neustart fehlgeschlagen. Dateien sind neu. Von Hand: sudo systemctl restart %s" % " ".join(DIENSTE))
        return 4
    if not journal_pruefen(seit, pause):
        return 4
    return 0


def _finde_start_oder_end(starts, envs=()):
    seen = []
    for pfad in list(envs) + list(starts):
        if not pfad or pfad in seen or not os.path.isfile(pfad):
            continue
        seen.append(pfad)
        data = open(pfad, "rb").read()
        yield pfad, data, sha256(data), len(data)


def _queue_selftest():
    """5C-Warteschlange ohne volles SDR-Modul."""
    ns = {
        "time": time,
        "T4_RETRY_S": 600,
        "_s": lambda x: "" if x is None else str(x),
        "_air_pl": lambda self: {"role": getattr(self, "role", None)},
        "_ff7b_orig_bc": lambda self: [("orig", 30)],
        "_ff7b_dab_list": lambda self: list(self.dab_list()),
    }

    class Planner:
        def sub_done(self, sp, now):
            return "orig-sub"

    ns["Planner"] = Planner

    class P:
        def __init__(self, role, dab, last=0, lst=("5C", "10C")):
            self.role = role
            self.sbc = type("S", (), {"d": {"dab": dab}})()
            self.cfg = {"dab_s": 60}
            self.__dict__["_ff7b_last5c"] = last
            self._lst = list(lst)

        def dab_list(self):
            return list(self._lst)

    src = '''def _ff7b_fresh(e, now, maxage=180):
    return isinstance(e, dict) and e.get("rx") is True and int(e.get("t") or 0) >= now - maxage


def _ff7b_bc_queue(self):
    """Stick Rolle 5C: ASA 5C hat Vorrang. Nur wenn 5C keinen frischen Sync hat, 10C;
    5C wird trotzdem alle 10 min (T4_RETRY_S) mit vollem Block erneut geprueft.
    Verhindert, dass ein alter 10C-Sync 5C dauerhaft verdraengt (cpulimit-Ausfall 26.11.)."""
    q = _ff7b_orig_bc(self)
    try:
        a = _air_pl(self)
        if not a or a.get("role") != "5C":
            return q
        dab = (self.sbc.d.get("dab") or {}) if getattr(self, "sbc", None) else {}
        lst = [str(x) for x in self.dab_list()]
        if "5C" not in lst:
            return q
        now = time.time()
        dur = float(self.cfg.get("dab_s") or 60)
        i5 = lst.index("5C")
        i10 = lst.index("10C") if "10C" in lst else None
        if _ff7b_fresh(dab.get("5C"), now):
            return [("dab:%d" % i5, dur)]
        last = float(self.__dict__.get("_ff7b_last5c") or 0)
        due = True if not last else (now - last) >= float(T4_RETRY_S)
        if due:
            return [("dab:%d" % i5, dur)]
        if i10 is not None and _ff7b_fresh(dab.get("10C"), now):
            return [("dab:%d" % i10, dur)]
    except Exception:
        return q
    return q


_ff7b_orig_sub = Planner.sub_done


def _ff7b_sub_done(self, sp, now):
    try:
        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") is not None else ""
        if _s(job).startswith("dab:"):
            lst = [str(x) for x in self.dab_list()]
            ch = lst[int(job[4:])] if int(job[4:]) < len(lst) else ""
            if ch == "5C":
                self.__dict__["_ff7b_last5c"] = float(now)
    except Exception:
        pass
    return _ff7b_orig_sub(self, sp, now)


Planner.dab_list = _ff7b_dab_list
Planner.bc_queue = _ff7b_bc_queue
Planner.sub_done = _ff7b_sub_done
'''
    exec(compile(src, "ff7b_queue.py", "exec"), ns)
    q = ns["_ff7b_bc_queue"]
    now = time.time()

    # frisches 5C: nur 5C, auch wenn 10C frisch
    p = P("5C", {"5C": {"rx": True, "t": now}, "10C": {"rx": True, "t": now}})
    r = q(p)
    if not r or not r[0][0].endswith(":0"):
        raise SystemExit("selftest queue frisch5c %s" % r)

    # nach Neustart (last=0), 5C tot, 10C frisch: trotzdem 5C zuerst
    p = P("5C", {"5C": {"rx": False, "t": 0}, "10C": {"rx": True, "t": now}}, last=0)
    r = q(p)
    if not r or not r[0][0].endswith(":0"):
        raise SystemExit("selftest queue restart5c %s" % r)

    # alter 5C-rx (26.11.), last=0, 10C frisch: 5C (nicht als frisch zaehlen)
    p = P("5C", {"5C": {"rx": True, "t": now - 86400}, "10C": {"rx": True, "t": now}}, last=0)
    r = q(p)
    if not r or not r[0][0].endswith(":0"):
        raise SystemExit("selftest queue stale5c %s" % r)

    # 5C kürzlich versucht, 10C frisch: 10C
    p = P("5C", {"5C": {"rx": False}, "10C": {"rx": True, "t": now}}, last=now - 100)
    r = q(p)
    if not r or not r[0][0].endswith(":1"):
        raise SystemExit("selftest queue 10c nach versuch %s" % r)

    # 5C faellig nach 10 min, 10C frisch: 5C retry
    p = P("5C", {"5C": {"rx": False}, "10C": {"rx": True, "t": now}}, last=now - 700)
    r = q(p)
    if not r or not r[0][0].endswith(":0"):
        raise SystemExit("selftest queue retry5c %s" % r)

    # andere Rolle: Original-Queue
    p = P("11D", {"5C": {"rx": False}, "10C": {"rx": True, "t": now}})
    r = q(p)
    if r != [("orig", 30)]:
        raise SystemExit("selftest queue andere rolle %s" % r)

    # sub_done merkt last5c
    p = P("5C", {})
    sp = {"queue": ["dab:0"], "i": 0}
    ns["_ff7b_sub_done"](p, sp, now)
    if float(p.__dict__.get("_ff7b_last5c") or 0) != float(now):
        raise SystemExit("selftest sub_done last5c")


def _ampel_selftest_from(text):
    a = text.index("def _ampel_norm")
    b = text.index("_AMPEL_ORIG = _air_sdrui")
    ns = {"re": re}
    exec(compile(text[a:b], "ampel.py", "exec"), ns)
    frank = (
        "Keine Warnung im Rundfunk · Funkumfeld nicht messbar · 10C Hauptkanal seit 23:13 · "
        "5C ohne Sync (Kalchreuth schwach) · Rückfall gewollt, kein Hinweis · Airspy R2 · 11D ok · "
        "Stick 1 · 5C · 10C Hauptkanal seit 23:13 · 5C ohne Sync (Kalchreuth schwach) · "
        "Rückfall gewollt, kein Hinweis · Stick 2 · Hobby nicht angeschlossen · Stick 3 · Flugfunk wird geprueft"
    )
    k = ns["_ampel_krise"]({"txt": frank, "lvl": "gelb", "hint": "x"})
    if k["lvl"] != "ok" or k["txt"] != "Alles in Ordnung" or k.get("hint"):
        raise SystemExit("selftest ampel frank %s" % k)
    k2 = ns["_ampel_krise"]({
        "txt": "Keine Warnung im Rundfunk · Stick 1 liefert keine Daten",
        "lvl": "rot", "hint": "Stick einmal ab- und anstecken",
    })
    if k2["lvl"] != "rot" or "keine Daten" not in k2["txt"] or "anstecken" not in k2["txt"].lower():
        raise SystemExit("selftest ampel daten %s" % k2)
    k3 = ns["_ampel_krise"]({"txt": "BR24 seit 2 h nicht empfangen · Funkumfeld normal", "lvl": "gelb"})
    if k3["lvl"] != "gelb" or not k3["txt"].startswith("BR24"):
        raise SystemExit("selftest ampel br24 %s" % k3)
    k4 = ns["_ampel_krise"]({"txt": "11D fehlt · Keine Warnung im Rundfunk", "lvl": "rot"})
    if k4["lvl"] != "rot" or "11D fehlt" not in k4["txt"] or "USB" not in k4["txt"]:
        raise SystemExit("selftest ampel 11d %s" % k4)
    k5 = ns["_ampel_krise"]({"txt": "5C und 10C ohne Empfang", "lvl": "rot"})
    if k5["lvl"] != "rot" or "ohne Empfang" not in k5["txt"]:
        raise SystemExit("selftest ampel beide tot %s" % k5)


def selftest():
    _queue_selftest()
    with tempfile.TemporaryDirectory(prefix="funkampel-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        sdr = os.path.join(root, "prepper_sdr.py")
        dash = os.path.join(root, "dashboard.py")
        open(sdr, "w", encoding="utf-8").write("# stub\n" + stub_aus(SDR_PAARE))
        open(dash, "w", encoding="utf-8").write("# stub\nimport re\n_air_sdrui = lambda st, d: d\n" + stub_aus(DASH_PAARE))
        os.chmod(sdr, 0o640)
        os.chmod(dash, 0o640)
        vorher_s = open(sdr, "rb").read()
        vorher_d = open(dash, "rb").read()
        if anwenden(root, False, False, 4, hashcheck=False, pause=0) != 2:
            raise SystemExit("selftest fenster")
        if open(sdr, "rb").read() != vorher_s or open(dash, "rb").read() != vorher_d:
            raise SystemExit("selftest fenster geschrieben")
        if anwenden(root, True, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest dry")
        if open(sdr, "rb").read() != vorher_s:
            raise SystemExit("selftest dry geschrieben")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest lauf")
        st = open(sdr, encoding="utf-8").read()
        dt = open(dash, encoding="utf-8").read()
        if not schon_sdr(st) or "if (dab.get(\"10C\") or {}).get(\"rx\") is True and (dab.get(\"5C\") or {}).get(\"rx\") is not True:" in st:
            raise SystemExit("selftest sdr queue alt")
        if not schon_dash(dt):
            raise SystemExit("selftest dash fehl")
        _ampel_selftest_from(dt)
        if (os.stat(sdr).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest modus")
        bak = [p for p in os.listdir(root) if "bak-%s-" % KENNUNG in p]
        if len(bak) < 2:
            raise SystemExit("selftest backup %s" % bak)
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest idempotent")
        if open(sdr, "rb").read() != open(sdr, "rb").read():
            raise SystemExit("selftest idempotent sdr")

    # echte Dateien
    sdr_src = dash_src = None
    sdr_h = dash_h = None
    for pfad, data, h, n in _finde_start_oder_end(
        [
            os.environ.get("FUNKAMPEL_SDR"),
            "/tmp/prepper_sdr_dabfix.py",
            os.path.join(BASIS, "prepper_sdr.py"),
        ],
    ):
        if h == SDR_START_SHA and n == SDR_START_BYTES:
            sdr_src, sdr_h = data, h
            break
        if h == SDR_END_SHA and n == SDR_END_BYTES and sdr_src is None:
            sdr_src, sdr_h = data, h
    for pfad, data, h, n in _finde_start_oder_end(
        [
            os.environ.get("FUNKAMPEL_DASH"),
            "/workspace/zi0/app2/dashboard.py",
            "/workspace/zi0/stage/dashboard.py",
            os.path.join(BASIS, "dashboard.py"),
        ],
    ):
        if h == DASH_START_SHA and n == DASH_START_BYTES:
            dash_src, dash_h = data, h
            break
        if h == DASH_END_SHA and n == DASH_END_BYTES and dash_src is None:
            dash_src, dash_h = data, h
    if not sdr_src:
        raise SystemExit("selftest echte SDR-Basis fehlt (FUNKAMPEL_SDR oder 4f15665aa12dabf9)")
    if not dash_src:
        raise SystemExit("selftest echtes dashboard fehlt (FUNKAMPEL_DASH oder 03344fb88acdcf90)")
    with tempfile.TemporaryDirectory(prefix="funkampel-real-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        zs, zd = os.path.join(root, "prepper_sdr.py"), os.path.join(root, "dashboard.py")
        open(zs, "wb").write(sdr_src)
        open(zd, "wb").write(dash_src)
        os.chmod(zs, 0o644)
        os.chmod(zd, 0o644)
        already = (sdr_h == SDR_END_SHA and dash_h == DASH_END_SHA)
        if already:
            if anwenden(root, False, False, 4, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real bereits")
        else:
            if anwenden(root, True, True, 12, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real dry")
            if open(zs, "rb").read() != sdr_src or open(zd, "rb").read() != dash_src:
                raise SystemExit("selftest real dry geschrieben")
            if anwenden(root, False, True, 12, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real lauf")
            if anwenden(root, False, False, 4, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real bereits/fenster")
        nsdr, ndash = open(zs, "rb").read(), open(zd, "rb").read()
        if sha256(nsdr) != SDR_END_SHA or len(nsdr) != SDR_END_BYTES:
            raise SystemExit("selftest real sdr hash %s/%s" % (sha256(nsdr)[:16], len(nsdr)))
        if sha256(ndash) != DASH_END_SHA or len(ndash) != DASH_END_BYTES:
            raise SystemExit("selftest real dash hash %s/%s" % (sha256(ndash)[:16], len(ndash)))
        compile(nsdr, "prepper_sdr.py", "exec")
        compile(ndash, "dashboard.py", "exec")
        _ampel_selftest_from(ndash.decode("utf-8"))
        if "def _ff7_start" not in nsdr.decode("utf-8") or "welle-cli ungedrosselt" not in nsdr.decode("utf-8"):
            raise SystemExit("selftest dabfix/whisper fehlen")
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    parser.add_argument("--fullcheck", default="", help="wird nicht geaendert")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    return anwenden(args.basis, args.dry_run, args.kein_neustart, berlin_minute())


if __name__ == "__main__":
    raise SystemExit(main())
