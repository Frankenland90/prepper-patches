#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-zusatzinfo-0. Schritt 0: Geruest fuer ein-/ausblendbare Zusatzinfo je Kachel.
Neue Datei zusatzinfo.py, ein Block in dashboard.py (letzter after_request, /api/zusatzinfo, /api/zusatzinfo/status),
fullcheck.sh Soll neu. Auf den Seiten aendert sich nichts Sichtbares (nur ein untaetiger Marker vor </body>).
Kein Mesh, keine Sticks, keine Schluessel, kein Abruf von aussen."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zlib
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

BASIS = "/home/fmg/prepper-dashboard"
FULLCHECK = "/home/fmg/fullcheck.sh"
KENNUNG = "zusatzinfo"

# Ausgangsstand (nach Logbericht-Tage, vom Pi bestaetigt)
VORHER = {
    "dashboard.py": ("0f03b1ff6f1686ac3cce2be767888f5b65ad69d6b4c8376c75ea1c38ade5e6dd", 1389185),
    "fullcheck.sh": ("4df71cde44f4aab2444e8126e01c876dda3f57a0d8afb12d2280157f04badd08", 99209),
}
MOD_SHA = "80a61ea8816ad57b65728f44ac09af979ef917536a0a0c3add17f5bfa772394e"
MOD_N = 24387
MARKE = "# ===== zusatzinfo (Schritt 0)"
ANKER = (
    'if not any(getattr(f, "__name__", "") == "_sec_headers" for f in app.after_request_funcs.get(None, [])):\n'
    '    app.after_request(_sec_headers)\n'
    '\n'
    '\n'
    'if __name__ == "__main__":\n'
    '    # sourceWatch final\n'
)
BLOCK = '# ===== zusatzinfo (Schritt 0): Zusatzinfo je Kachel ein-/ausblendbar - hier nur Geruest, auf den Seiten aendert sich nichts Sichtbares =====\n# Modul zusatzinfo.py: Regeltabelle leer, AKTIV aus. Liefert nur einen untaetigen Marker vor </body>, Zustand in zusatzinfo.json, Zaehler unter /api/zusatzinfo/status.\n# Haken laeuft als LETZTER after_request (insert(0), Flask ruft in umgekehrter Reihenfolge); Notschalter: Umgebungsvariable ZUSATZINFO_AUS=1.\ntry:\n    import zusatzinfo as _zi\n    _zi.init(_SDR_BASE)\n\n    def _zi_after(resp):\n        try:\n            from flask import request as _zi_rq\n            return _zi.nach_antwort(resp, _zi_rq.path)\n        except Exception as _zi_x:\n            print("zusatzinfo:", type(_zi_x).__name__, flush=True)\n            return resp\n\n    def _zi_api():\n        from flask import request as _zi_rq\n        return _zi.api(_zi_rq, require_same_origin)\n\n    _ZI_ST = _zi.selbsttest()\n    if "app" in globals() and not any(getattr(r, "rule", "") == "/api/zusatzinfo" for r in app.url_map.iter_rules()):\n        app.add_url_rule("/api/zusatzinfo", endpoint="zi_api", view_func=_zi_api, methods=["GET", "POST"])\n        app.add_url_rule("/api/zusatzinfo/status", endpoint="zi_status", view_func=_zi.status_api, methods=["GET"])\n    if "app" in globals() and not any(getattr(f, "__name__", "") == "_zi_after" for f in app.after_request_funcs.get(None, [])):\n        app.after_request_funcs.setdefault(None, []).insert(0, _zi_after)\n    print("zusatzinfo aktiv: %s" % _ZI_ST, flush=True)\nexcept Exception as _zi_e:\n    print("zusatzinfo FEHLER: %s - Seiten wie bisher" % type(_zi_e).__name__, flush=True)\n# ===== /zusatzinfo =====\n\n\n'
MOD_B64 = (
"""
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
WKTV+H9MbjDk
"""
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def sperre(minute):
    minute = int(minute)
    return minute >= 40 or minute <= 4


def berlin_minute():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin")).minute
    return datetime.now().minute


def modul_neu():
    data = zlib.decompress(base64.b64decode("".join(MOD_B64.split())))
    if sha256(data) != MOD_SHA or len(data) != MOD_N:
        raise ValueError("eingebettetes zusatzinfo.py beschaedigt")
    return data


def ersetze(text, alt, neu, name):
    if text.count(alt) != 1:
        raise ValueError("%s Anker %d statt 1" % (name, text.count(alt)))
    return text.replace(alt, neu, 1)


def dash_neu(text):
    """Block genau einmal vor den Start-Block (nach _sec_headers) setzen."""
    return ersetze(text, ANKER, BLOCK.rstrip("\n") + "\n\n\n" + ANKER, "dashboard.py") if MARKE not in text else text


def fullcheck_neu(text, d16, dn):
    m = re.findall(r'^FC_VERSION="(\d+)\.(\d+)"$', text, re.M)
    if len(m) != 1:
        raise ValueError("fullcheck FC_VERSION nicht eindeutig")
    alt_v = 'FC_VERSION="%s.%s"' % m[0]
    neu_v = 'FC_VERSION="%s.%d"' % (m[0][0], int(m[0][1]) + 1)
    text = ersetze(text, alt_v, neu_v, "fullcheck.sh")
    for name, wert in (("FC_DASH_SHA16", d16), ("FC_DASH_BYTES", str(dn))):
        muster = r"(\$\{%s:-)[^}\n]+" % name
        text, n = re.subn(muster, r"\g<1>" + wert, text, count=1)
        if n != 1:
            raise ValueError("fullcheck " + name)
    return text


def berechne(basis, fullcheck, hashcheck=True):
    """Liest nur. -> (pfad, alt, neu, fehler). neu None = bereits installiert."""
    pfad = {
        "dashboard.py": os.path.join(basis, "dashboard.py"),
        "fullcheck.sh": fullcheck,
        "zusatzinfo.py": os.path.join(basis, "zusatzinfo.py"),
    }
    alt = {}
    for name in ("dashboard.py", "fullcheck.sh"):
        if os.path.islink(pfad[name]) or not os.path.isfile(pfad[name]):
            return pfad, {}, {}, "STOP %s fehlt" % pfad[name]
        alt[name] = open(pfad[name], "rb").read()
    if os.path.islink(pfad["zusatzinfo.py"]):
        return pfad, {}, {}, "STOP zusatzinfo.py ist ein Verweis"
    alt["zusatzinfo.py"] = open(pfad["zusatzinfo.py"], "rb").read() if os.path.isfile(pfad["zusatzinfo.py"]) else None
    try:
        ziel = modul_neu()
    except ValueError as exc:
        return pfad, alt, {}, "STOP %s" % exc
    if alt["zusatzinfo.py"] == ziel and MARKE in alt["dashboard.py"].decode("utf-8", "replace"):
        return pfad, alt, None, ""
    if hashcheck:
        for name, (voll, n) in VORHER.items():
            ist = sha256(alt[name])
            if ist != voll or len(alt[name]) != n:
                return pfad, alt, {}, "STOP %s ist %s/%d, Soll %s/%d. Nichts geschrieben." % (name, ist[:16], len(alt[name]), voll[:16], n)
    neu = {"zusatzinfo.py": ziel}
    try:
        dash = dash_neu(alt["dashboard.py"].decode("utf-8"))
        compile(dash, "dashboard.py", "exec")
        compile(ziel, "zusatzinfo.py", "exec")
        neu["dashboard.py"] = dash.encode("utf-8")
        fc = fullcheck_neu(alt["fullcheck.sh"].decode("utf-8"), sha256(neu["dashboard.py"])[:16], len(neu["dashboard.py"]))
        neu["fullcheck.sh"] = fc.encode("utf-8")
    except (ValueError, SyntaxError, UnicodeError) as exc:
        return pfad, alt, {}, "STOP Anker/Syntax: %s. Nichts geschrieben." % str(exc)[:80]
    probe = tempfile.mktemp(prefix="fcpruef-")
    with open(probe, "wb") as handle:
        handle.write(neu["fullcheck.sh"])
    rc = subprocess.run(["bash", "-n", probe], capture_output=True).returncode
    os.remove(probe)
    if rc != 0:
        return pfad, alt, {}, "STOP bash -n fullcheck. Nichts geschrieben."
    return pfad, alt, neu, ""


def sichern(pfad, stempel):
    ziel = "%s.bak-%s-%s" % (pfad, KENNUNG, stempel)
    shutil.copy2(pfad, ziel)
    alte = sorted(p for p in os.listdir(os.path.dirname(pfad) or ".") if p.startswith(os.path.basename(pfad) + ".bak-" + KENNUNG + "-"))
    for p in alte[:-3]:
        try:
            os.remove(os.path.join(os.path.dirname(pfad) or ".", p))
        except OSError:
            pass
    return ziel


def schreibe(pfad, daten, vorlage=None):
    tmp = pfad + ".zi-tmp"
    with open(tmp, "wb") as handle:
        handle.write(daten)
        handle.flush()
        os.fsync(handle.fileno())
    if vorlage and os.path.exists(vorlage):
        shutil.copymode(vorlage, tmp)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, pfad)


def pruefe_live(timeout=120):
    """Nur lesen: GET /api/zusatzinfo/status auf 127.0.0.1:5000."""
    import urllib.request
    ende = time.time() + timeout
    letzter = "keine Antwort"
    while time.time() < ende:
        try:
            with urllib.request.urlopen("http://127.0.0.1:5000/api/zusatzinfo/status", timeout=10) as antwort:
                j = json.loads(antwort.read().decode("utf-8"))
            if j.get("version") == "zi0" and j.get("aktiv") is False:
                return True, "HTTP 200, %s, inaktiv, Seiten gezaehlt %d" % (j.get("version"), len(j.get("seiten") or {}))
            letzter = "Antwort unerwartet"
        except Exception as exc:
            letzter = type(exc).__name__
        time.sleep(5)
    return False, letzter


def anwenden(basis, fullcheck, dry, kein, minute, hashcheck=True, neustart=None):
    pfad, alt, neu, fehler = berechne(basis, fullcheck, hashcheck)
    if fehler:
        print(fehler)
        return 2
    if neu is None:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    for name in ("zusatzinfo.py", "dashboard.py", "fullcheck.sh"):
        print("%s endstand sha16 %s bytes %d" % (name, sha256(neu[name])[:16], len(neu[name])))
    if dry:
        print("dry-run: nichts geschrieben")
        return 0
    if not kein and sperre(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    stempel = datetime.now().strftime("%Y%m%dT%H%M%S")
    gesichert = []
    neu_angelegt = False
    try:
        for name in ("zusatzinfo.py", "dashboard.py", "fullcheck.sh"):
            if alt[name] is not None:
                gesichert.append((pfad[name], sichern(pfad[name], stempel)))
        for name in ("zusatzinfo.py", "dashboard.py", "fullcheck.sh"):
            if alt[name] is None:
                neu_angelegt = True
            schreibe(pfad[name], neu[name], pfad["dashboard.py"] if name == "zusatzinfo.py" else pfad[name])
            data = open(pfad[name], "rb").read()
            print("%s endstand sha256 %s bytes %d" % (name, sha256(data), len(data)))
    except OSError as exc:
        print("STOP beim Schreiben (%s), stelle zurueck" % type(exc).__name__)
        for ziel, bak in gesichert:
            try:
                shutil.copy2(bak, ziel)
            except OSError:
                pass
        if neu_angelegt and alt["zusatzinfo.py"] is None:
            try:
                os.remove(pfad["zusatzinfo.py"])
            except OSError:
                pass
        return 3
    if kein:
        print("kein Neustart. Aktiv nach: sudo systemctl restart prepper-dashboard")
        return 0
    rc = (neustart or (lambda: subprocess.call(["sudo", "systemctl", "restart", "prepper-dashboard"])))()
    print("restart prepper-dashboard rc %s (prepper-sdr, Icecast, Mesh unveraendert)" % rc)
    if rc != 0:
        print("Neustart fehlgeschlagen. Dateien sind neu. Von Hand: sudo systemctl restart prepper-dashboard")
        return 4
    ok, info = pruefe_live()
    print("zusatzinfo live: %s (%s)" % ("OK" if ok else "NICHT bestaetigt", info))
    print("Sichtbar aendert sich nichts. Zaehler und Kachel-Inventar: curl -s http://127.0.0.1:5000/api/zusatzinfo/status")
    return 0 if ok else 5


def selftest():
    ziel = modul_neu()
    ns = {"__name__": "zusatzinfo"}
    exec(compile(ziel, "zusatzinfo.py", "exec"), ns)
    meldung = ns["selbsttest"]()
    if "ok" not in meldung:
        raise SystemExit("selftest modul")
    print("selftest modul:", meldung)
    arbeit = tempfile.mkdtemp(prefix="zusatzinfo0-")
    try:
        dash = (
            "x = 1\n\ndef _sec_headers(resp):\n    return resp\n\n\n" + ANKER + "    print('start')\n"
        )
        fc = 'FC_VERSION="2.10"\nDASH_SHA16="${FC_DASH_SHA16:-aaaa}"\nDASH_BYTES="${FC_DASH_BYTES:-1}"\necho ok\n'
        open(os.path.join(arbeit, "dashboard.py"), "w").write(dash)
        fcp = os.path.join(arbeit, "fullcheck.sh")
        open(fcp, "w").write(fc)
        os.chmod(fcp, 0o750)
        os.chmod(os.path.join(arbeit, "dashboard.py"), 0o640)
        # Hash-Sperre: falsche Dateien -> nichts geschrieben
        if anwenden(arbeit, fcp, False, True, 12, True) != 2:
            raise SystemExit("selftest hashsperre")
        if open(fcp).read() != fc or os.path.exists(os.path.join(arbeit, "zusatzinfo.py")):
            raise SystemExit("selftest hashsperre schrieb")
        if anwenden(arbeit, fcp, True, False, 12, False) != 0:
            raise SystemExit("selftest dry")
        if open(fcp).read() != fc or os.path.exists(os.path.join(arbeit, "zusatzinfo.py")):
            raise SystemExit("selftest dry schrieb")
        if anwenden(arbeit, fcp, False, False, 41, False) != 2:
            raise SystemExit("selftest sperre")
        if open(fcp).read() != fc or os.path.exists(os.path.join(arbeit, "zusatzinfo.py")):
            raise SystemExit("selftest sperre schrieb")
        if anwenden(arbeit, fcp, False, True, 41, False) != 0:
            raise SystemExit("selftest kein-neustart")
        neu = open(fcp).read()
        if 'FC_VERSION="2.11"' not in neu or "aaaa" in neu or "@@" in neu:
            raise SystemExit("selftest soll")
        if (os.stat(fcp).st_mode & 0o777) != 0o750 or (os.stat(os.path.join(arbeit, "dashboard.py")).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest mode")
        if (os.stat(os.path.join(arbeit, "zusatzinfo.py")).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest mode modul")
        if not any(p.startswith("dashboard.py.bak-" + KENNUNG) for p in os.listdir(arbeit)):
            raise SystemExit("selftest backup")
        d = open(os.path.join(arbeit, "dashboard.py")).read()
        if d.count(MARKE) != 1 or d.index(MARKE) > d.index('if __name__ == "__main__":'):
            raise SystemExit("selftest block")
        if open(os.path.join(arbeit, "zusatzinfo.py"), "rb").read() != ziel:
            raise SystemExit("selftest modul datei")
        if [p for p in os.listdir(arbeit) if p.endswith(".zi-tmp")]:
            raise SystemExit("selftest tmp")
        vorher = open(os.path.join(arbeit, "dashboard.py"), "rb").read()
        if anwenden(arbeit, fcp, False, True, 12, False) != 0 or open(os.path.join(arbeit, "dashboard.py"), "rb").read() != vorher:
            raise SystemExit("selftest zweiter lauf")
        print("selftest apply ok")
    finally:
        shutil.rmtree(arbeit, ignore_errors=True)
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    parser.add_argument("--fullcheck", default=FULLCHECK)
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    return anwenden(args.basis, args.fullcheck, args.dry_run, args.kein_neustart, berlin_minute())


if __name__ == "__main__":
    raise SystemExit(main())
