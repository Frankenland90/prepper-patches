#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-logbericht-tage. Mehrtagesbericht im Diagnosebericht. Nur lesen, kein Mesh, keine Sticks."""
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
KENNUNG = "logbericht-tage"

# Stand nach Patch C (vom Pi bestaetigt) plus prepper_log.py aus der Kette 6/sdr-stabil/7c.
VORHER = {
    "dashboard.py": ("3a049826f2aae3e4f5980020c2d3f104f02a8da9ade5b1b694b37c41f8fe1d9d", 1389101),
    "prepper_log.py": ("fd79a1c81de167f0941a122140abe3ae22f6abe3920f8ee4d18e286fa116b1dd", 17791),
    "fullcheck.sh": ("3415dff56f555fda74d18a6f018463ec56eb7d3b8fe12e4e688569c353d1ce14", 99209),
}
NUR_PRUEFEN = {
    "lage_pages.py": ("696638fd9ea3cd1723b25883d02d4516a1db9f3ba98711657f671ad6f29240c0", 231498),
    "flugfunk.py": ("d58c3ca548fc57171f95f9b64c0898bc18f23cab59662ef4259dc5cbe15913e6", 99286),
}
# dashboard.py: nur Schutz im Antwort-Haken, damit Streams (Live hoeren) nie gelesen werden.
DASH_PAARE = [
    (
        '            if resp.status_code >= 500 or (request.path.startswith("/api") and resp.status_code == 200):\n',
        '            if not resp.is_streamed and not resp.direct_passthrough and (resp.status_code >= 500 or (request.path.startswith("/api") and resp.status_code == 200)):\n',
    ),
    (
        '        if resp.status_code == 200 and (resp.mimetype or "") == "text/html" and not resp.direct_passthrough:\n            neu = _kachel_css(_pl.in_seite(',
        '        if resp.status_code == 200 and (resp.mimetype or "") == "text/html" and not resp.direct_passthrough and not resp.is_streamed:\n            neu = _kachel_css(_pl.in_seite(',
    ),
]
FC_PAARE = [
    ('DASH_SHA16="${FC_DASH_SHA16:-3a049826f2aae3e4}"', 'DASH_SHA16="${FC_DASH_SHA16:-@@DASH16@@}"'),
    ('DASH_BYTES="${FC_DASH_BYTES:-1389101}"', 'DASH_BYTES="${FC_DASH_BYTES:-@@DASHN@@}"'),
]
LOG_NEU_B64 = "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"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def sperre(minute):
    minute = int(minute)
    return minute >= 40 or minute <= 4


def berlin_minute():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin")).minute
    return datetime.now().minute


def log_neu():
    return zlib.decompress(base64.b64decode(LOG_NEU_B64))


def ersetze(text, alt, neu, name):
    if text.count(alt) != 1:
        raise ValueError("%s Anker %d statt 1" % (name, text.count(alt)))
    return text.replace(alt, neu, 1)


def berechne(basis, fullcheck, hashcheck=True):
    """Liest nur. Gibt (alt, neu, fehler) zurueck. neu ist leer bei Fehler."""
    pfad = {
        "dashboard.py": os.path.join(basis, "dashboard.py"),
        "prepper_log.py": os.path.join(basis, "prepper_log.py"),
        "fullcheck.sh": fullcheck,
        "lage_pages.py": os.path.join(basis, "lage_pages.py"),
        "flugfunk.py": os.path.join(basis, "flugfunk.py"),
    }
    alt = {}
    for name in ("dashboard.py", "prepper_log.py", "fullcheck.sh", "lage_pages.py", "flugfunk.py"):
        if os.path.islink(pfad[name]) or not os.path.isfile(pfad[name]):
            return pfad, {}, {}, "STOP %s fehlt" % pfad[name]
        alt[name] = open(pfad[name], "rb").read()
    ziel = log_neu()
    ende_log = sha256(ziel)
    # schon installiert?
    if alt["prepper_log.py"] == ziel and "not resp.is_streamed" in alt["dashboard.py"].decode("utf-8", "replace"):
        return pfad, alt, None, ""
    if hashcheck:
        soll = dict(VORHER)
        soll.update(NUR_PRUEFEN)
        for name, (voll, n) in soll.items():
            ist = sha256(alt[name])
            if ist != voll or len(alt[name]) != n:
                return pfad, alt, {}, "STOP %s ist %s/%d, Soll %s/%d. Nichts geschrieben." % (name, ist[:16], len(alt[name]), voll[:16], n)
    neu = {}
    try:
        dash = alt["dashboard.py"].decode("utf-8")
        for a, b in DASH_PAARE:
            dash = ersetze(dash, a, b, "dashboard.py")
        compile(dash, "dashboard.py", "exec")
        compile(ziel, "prepper_log.py", "exec")
        neu["dashboard.py"] = dash.encode("utf-8")
        neu["prepper_log.py"] = ziel
        d16 = sha256(neu["dashboard.py"])[:16]
        fc = alt["fullcheck.sh"].decode("utf-8")
        for a, b in FC_PAARE:
            b = b.replace("@@DASH16@@", d16).replace("@@DASHN@@", str(len(neu["dashboard.py"])))
            fc = ersetze(fc, a, b, "fullcheck.sh")
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


def schreibe(pfad, daten):
    tmp = pfad + ".tage-tmp"
    with open(tmp, "wb") as handle:
        handle.write(daten)
        handle.flush()
        os.fsync(handle.fileno())
    shutil.copymode(pfad, tmp)
    os.replace(tmp, pfad)


def pruefe_live(timeout=120):
    """Nur lesen: GET /api/logbericht auf 127.0.0.1:5000 (Loopback, LAN-Sperre ok)."""
    import urllib.request
    ende = time.time() + timeout
    letzter = "keine Antwort"
    while time.time() < ende:
        try:
            with urllib.request.urlopen("http://127.0.0.1:5000/api/logbericht?zeitraum=3d", timeout=10) as antwort:
                text = json.loads(antwort.read().decode("utf-8")).get("text", "")
            if "Diagnosebericht 3d" in text:
                return True, "HTTP 200, %d Zeilen, Tage-Block %s" % (text.count("\n"), "ja" if "Tage (Berlin)" in text else "nein")
            letzter = "Antwort ohne Bericht"
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
    for name in ("dashboard.py", "prepper_log.py", "fullcheck.sh"):
        print("%s endstand sha16 %s bytes %d" % (name, sha256(neu[name])[:16], len(neu[name])))
    if dry:
        print("dry-run: nichts geschrieben")
        return 0
    if not kein and sperre(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    stempel = datetime.now().strftime("%Y%m%dT%H%M%S")
    gesichert = []
    try:
        for name in ("prepper_log.py", "dashboard.py", "fullcheck.sh"):
            gesichert.append((pfad[name], sichern(pfad[name], stempel)))
        for name in ("prepper_log.py", "dashboard.py", "fullcheck.sh"):
            schreibe(pfad[name], neu[name])
            data = open(pfad[name], "rb").read()
            print("%s endstand sha256 %s bytes %d" % (name, sha256(data), len(data)))
    except OSError as exc:
        print("STOP beim Schreiben (%s), stelle zurueck" % type(exc).__name__)
        for ziel, bak in gesichert:
            try:
                shutil.copy2(bak, ziel)
            except OSError:
                pass
        return 3
    if kein:
        print("kein Neustart. Aktiv nach: sudo systemctl restart prepper-dashboard")
        return 0
    rc = (neustart or (lambda: subprocess.call(["sudo", "systemctl", "restart", "prepper-dashboard"])))()
    print("restart prepper-dashboard rc %s (prepper-sdr unveraendert)" % rc)
    if rc != 0:
        print("Neustart fehlgeschlagen. Dateien sind neu. Von Hand: sudo systemctl restart prepper-dashboard")
        return 4
    ok, info = pruefe_live()
    print("Bericht live: %s (%s)" % ("OK" if ok else "NICHT bestaetigt", info))
    print("Danach ansehen: /pi, Kachel Diagnosebericht, Zeitraum 7d. Oder: python3 %s/prepper_log.py bericht 7d" % basis)
    return 0 if ok else 5


def selftest():
    ziel_log = log_neu()
    ns = {"__name__": "prepper_log"}
    exec(compile(ziel_log, "prepper_log.py", "exec"), ns)
    if ns["selftest"]() != "logbericht ok":
        raise SystemExit("selftest prepper_log")
    arbeit = tempfile.mkdtemp(prefix="logbericht-tage-")
    try:
        dash = (
            "def _log_after(resp, request, _pl, _kachel_css):\n    try:\n        if True:\n            body = ''\n"
            + DASH_PAARE[0][0] + "                body = 1\n"
            + DASH_PAARE[1][0] + "1, 2))\n    except Exception:\n        pass\n"
        )
        fc = 'FC_VERSION="2.10"\n' + FC_PAARE[0][0] + "\n" + FC_PAARE[1][0] + "\necho ok\n"
        open(os.path.join(arbeit, "dashboard.py"), "w").write(dash)
        open(os.path.join(arbeit, "prepper_log.py"), "w").write("# alt\n")
        for name in ("lage_pages.py", "flugfunk.py"):
            open(os.path.join(arbeit, name), "w").write("# x\n")
        fcp = os.path.join(arbeit, "fullcheck.sh")
        open(fcp, "w").write(fc)
        os.chmod(fcp, 0o750)
        os.chmod(os.path.join(arbeit, "dashboard.py"), 0o640)
        # Hash-Sperre: falsche Dateien werden abgelehnt, nichts geschrieben
        if anwenden(arbeit, fcp, False, True, 12, True) != 2:
            raise SystemExit("selftest hashsperre")
        if open(fcp).read() != fc or open(os.path.join(arbeit, "prepper_log.py")).read() != "# alt\n":
            raise SystemExit("selftest hashsperre schrieb")
        if anwenden(arbeit, fcp, True, False, 12, False) != 0:
            raise SystemExit("selftest dry")
        if open(fcp).read() != fc:
            raise SystemExit("selftest dry schrieb")
        if anwenden(arbeit, fcp, False, False, 41, False) != 2:
            raise SystemExit("selftest sperre")
        if open(fcp).read() != fc:
            raise SystemExit("selftest sperre schrieb")
        if anwenden(arbeit, fcp, False, True, 41, False) != 0:
            raise SystemExit("selftest kein-neustart")
        neu = open(fcp).read()
        if "3a049826f2aae3e4" in neu or "@@" in neu or "FC_DASH_SHA16" not in neu:
            raise SystemExit("selftest soll")
        if (os.stat(fcp).st_mode & 0o777) != 0o750 or (os.stat(os.path.join(arbeit, "dashboard.py")).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest mode")
        if not any(p.startswith("fullcheck.sh.bak-" + KENNUNG) for p in os.listdir(arbeit)):
            raise SystemExit("selftest backup")
        if open(os.path.join(arbeit, "prepper_log.py"), "rb").read() != ziel_log:
            raise SystemExit("selftest log")
        if anwenden(arbeit, fcp, False, True, 12, False) != 0:
            raise SystemExit("selftest zweiter lauf")
        print("selftest apply ok")
    finally:
        shutil.rmtree(arbeit, ignore_errors=True)
    # Streaming-Schutz mit echtem Flask, falls vorhanden
    try:
        import flask
    except ImportError:
        print("selftest Flask: uebersprungen (Flask fehlt in dieser Umgebung)")
    else:
        import threading
        app = flask.Flask("t")

        def gen():
            while True:
                yield b"x" * 64
                time.sleep(0.02)

        app.add_url_rule("/api/s", "s", lambda: flask.Response(gen(), mimetype="audio/mpeg"))
        app.add_url_rule("/api/j", "j", lambda: flask.jsonify({"a": 1}))
        code = (
            "def _a(resp):\n    from flask import request\n    body = ''\n"
            + DASH_PAARE[0][1].replace("            ", "    ", 1)
            + "        body = resp.get_data(as_text=True)[:4000]\n    resp.headers['X-Body'] = str(len(body))\n    return resp\n"
        )
        lokal = {}
        exec(code, lokal)
        app.after_request(lokal["_a"])
        ergebnis = {}

        def lauf():
            c = app.test_client()
            ergebnis["s"] = c.get("/api/s", buffered=False).status_code
            ergebnis["j"] = c.get("/api/j").headers.get("X-Body")

        t = threading.Thread(target=lauf, daemon=True)
        t.start()
        t.join(5)
        if t.is_alive() or ergebnis.get("s") != 200 or ergebnis.get("j") in (None, "0"):
            raise SystemExit("selftest stream haengt oder JSON leer %s" % ergebnis)
        print("selftest Stream-Schutz ok (Stream nicht gelesen, JSON gelesen)")
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
