#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-zusatzinfo-1-energie. Schritt 1 (Pilot): Zusatzinfo je Kachel ein-/ausblendbar, nur auf /energie (6 Kacheln).
Ersetzt NUR zusatzinfo.py (Schritt 0 -> zi1-energie). dashboard.py und fullcheck.sh bleiben unveraendert (nur Hash-Pruefung).
Standard zugeklappt, Zustand gemeinsam in zusatzinfo.json, bei gelb/rot automatisch auf und danach wieder zu.
Notschalter: Umgebungsvariable ZUSATZINFO_AUS=1 im Dienst. Kein Mesh, keine Sticks, keine Schluessel, kein Abruf von aussen."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
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
KENNUNG = "zusatzinfo1"

# Ausgangsstand (nach Schritt 0, vom Pi bestaetigt 07:13)
VORHER = {
    "zusatzinfo.py": ("80a61ea8816ad57b65728f44ac09af979ef917536a0a0c3add17f5bfa772394e", 24387),
    "dashboard.py": ("03344fb88acdcf900fe5033228fe5fd0e0b4a934f86e9d246d10e0511ab765b1", 1390854),
    "fullcheck.sh": ("a1c2f832fad1fdf2df2c12653d34717642353c53cec68227237d6b8ef845b397", 99209),
}
MOD_SHA = "152f0b8ea2ff421b221ecf0d82bc8b162a92480781e8f7fba8bcd581855f0400"
MOD_N = 33740
MOD_B64 = (
"""
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
xWCwcEEvDORZhSjGI1r6wrVV+/8qhozt
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


def berechne(basis, fullcheck, hashcheck=True):
    """Liest nur. -> (pfad, alt, neu, fehler). neu None = bereits installiert."""
    pfad = {
        "zusatzinfo.py": os.path.join(basis, "zusatzinfo.py"),
        "dashboard.py": os.path.join(basis, "dashboard.py"),
        "fullcheck.sh": fullcheck,
    }
    alt = {}
    for name in ("zusatzinfo.py", "dashboard.py", "fullcheck.sh"):
        if os.path.islink(pfad[name]) or not os.path.isfile(pfad[name]):
            return pfad, {}, {}, "STOP %s fehlt oder ist ein Verweis" % pfad[name]
        with open(pfad[name], "rb") as handle:
            alt[name] = handle.read()
    try:
        ziel = modul_neu()
        compile(ziel, "zusatzinfo.py", "exec")
    except (ValueError, SyntaxError) as exc:
        return pfad, alt, {}, "STOP %s" % exc
    if alt["zusatzinfo.py"] == ziel:
        return pfad, alt, None, ""
    if hashcheck:
        for name, (voll, n) in VORHER.items():
            ist = sha256(alt[name])
            if ist != voll or len(alt[name]) != n:
                return pfad, alt, {}, "STOP %s ist %s/%d, Soll %s/%d. Nichts geschrieben." % (name, ist[:16], len(alt[name]), voll[:16], n)
    return pfad, alt, {"zusatzinfo.py": ziel}, ""


def sichern(pfad, stempel):
    ziel = "%s.bak-%s-%s" % (pfad, KENNUNG, stempel)
    shutil.copy2(pfad, ziel)
    ordner = os.path.dirname(pfad) or "."
    alte = sorted(p for p in os.listdir(ordner) if p.startswith(os.path.basename(pfad) + ".bak-" + KENNUNG + "-"))
    for p in alte[:-3]:
        try:
            os.remove(os.path.join(ordner, p))
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
    """Nur lesen: Status-API und /energie auf 127.0.0.1:5000."""
    import urllib.request
    ende = time.time() + timeout
    letzter = "keine Antwort"
    while time.time() < ende:
        try:
            with urllib.request.urlopen("http://127.0.0.1:5000/api/zusatzinfo/status", timeout=10) as antwort:
                j = json.loads(antwort.read().decode("utf-8"))
            if j.get("version") == "zi1-energie" and j.get("aktiv") is True and (j.get("regeln") or {}).get("/energie") == 6:
                with urllib.request.urlopen("http://127.0.0.1:5000/energie", timeout=20) as seite:
                    html = seite.read().decode("utf-8", "replace")
                treffer = html.count('<div data-zi="')
                if treffer == 6 and 'id="zi-js"' in html:
                    return True, "HTTP 200, %s, aktiv, /energie: 6 Kacheln markiert" % j.get("version")
                letzter = "/energie: %d Kacheln markiert statt 6" % treffer
            else:
                letzter = "Status unerwartet (noch alter Stand?)"
        except Exception as exc:
            letzter = type(exc).__name__
        time.sleep(5)
    return False, letzter


def anwenden(basis, fullcheck, dry, kein, minute, hashcheck=True, neustart=None, live=None):
    pfad, alt, neu, fehler = berechne(basis, fullcheck, hashcheck)
    if fehler:
        print(fehler)
        return 2
    if neu is None:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    print("zusatzinfo.py endstand sha16 %s bytes %d (dashboard.py und fullcheck.sh bleiben unveraendert)" % (sha256(neu["zusatzinfo.py"])[:16], len(neu["zusatzinfo.py"])))
    if dry:
        print("dry-run: nichts geschrieben")
        return 0
    if not kein and sperre(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    stempel = datetime.now().strftime("%Y%m%dT%H%M%S")
    bak = None
    try:
        bak = sichern(pfad["zusatzinfo.py"], stempel)
        schreibe(pfad["zusatzinfo.py"], neu["zusatzinfo.py"], pfad["dashboard.py"])
        with open(pfad["zusatzinfo.py"], "rb") as handle:
            data = handle.read()
        print("zusatzinfo.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
    except OSError as exc:
        print("STOP beim Schreiben (%s), stelle zurueck" % type(exc).__name__)
        if bak:
            try:
                shutil.copy2(bak, pfad["zusatzinfo.py"])
            except OSError:
                pass
        return 3
    if kein:
        print("kein Neustart. Aktiv nach: sudo systemctl restart prepper-dashboard")
        return 0
    rc = (neustart or (lambda: subprocess.call(["sudo", "systemctl", "restart", "prepper-dashboard"])))()
    print("restart prepper-dashboard rc %s (prepper-sdr, Icecast, Mesh unveraendert)" % rc)
    if rc != 0:
        print("Neustart fehlgeschlagen. Datei ist neu. Von Hand: sudo systemctl restart prepper-dashboard")
        return 4
    ok, info = (live or pruefe_live)()
    print("zusatzinfo live: %s (%s)" % ("OK" if ok else "NICHT bestaetigt", info))
    print("Seite /energie: Pfeil rechts im Kachelkopf klappt Details auf, oben 'Details: alle ein / alle aus'.")
    print("Notfall zurueck: cp %s && sudo systemctl restart prepper-dashboard" % ("%s %s" % (bak, pfad["zusatzinfo.py"])))
    return 0 if ok else 5


def selftest():
    ziel = modul_neu()
    ns = {"__name__": "zusatzinfo"}
    exec(compile(ziel, "zusatzinfo.py", "exec"), ns)
    meldung = ns["selbsttest"]()
    if "ok" not in meldung:
        raise SystemExit("selftest modul")
    print("selftest modul:", meldung)
    arbeit = tempfile.mkdtemp(prefix="zusatzinfo1-")
    try:
        dash = "x = 1\n"
        fc = 'FC_VERSION="2.11"\necho ok\n'
        alt_mod = "AKTIV = False\n"
        dp = os.path.join(arbeit, "dashboard.py")
        fcp = os.path.join(arbeit, "fullcheck.sh")
        zp = os.path.join(arbeit, "zusatzinfo.py")
        for pf, inh in ((dp, dash), (fcp, fc), (zp, alt_mod)):
            with open(pf, "w") as handle:
                handle.write(inh)
        os.chmod(fcp, 0o750)
        os.chmod(dp, 0o640)
        os.chmod(zp, 0o600)

        def lies(pf):
            with open(pf, "rb") as handle:
                return handle.read()

        if anwenden(arbeit, fcp, False, True, 12, True) != 2 or lies(zp) != alt_mod.encode():
            raise SystemExit("selftest hashsperre")
        if anwenden(arbeit, fcp, True, False, 12, False) != 0 or lies(zp) != alt_mod.encode():
            raise SystemExit("selftest dry")
        for m in (41, 4, 40):
            if anwenden(arbeit, fcp, False, False, m, False) != 2 or lies(zp) != alt_mod.encode():
                raise SystemExit("selftest sperre %d" % m)
        if anwenden(arbeit, fcp, False, True, 41, False) != 0:
            raise SystemExit("selftest kein-neustart")
        if lies(zp) != ziel or lies(dp) != dash.encode() or lies(fcp) != fc.encode():
            raise SystemExit("selftest inhalt")
        if (os.stat(zp).st_mode & 0o777) != 0o640 or (os.stat(dp).st_mode & 0o777) != 0o640 or (os.stat(fcp).st_mode & 0o777) != 0o750:
            raise SystemExit("selftest mode")
        if not any(p.startswith("zusatzinfo.py.bak-" + KENNUNG) for p in os.listdir(arbeit)):
            raise SystemExit("selftest backup")
        if [p for p in os.listdir(arbeit) if p.endswith(".zi-tmp")]:
            raise SystemExit("selftest tmp")
        if anwenden(arbeit, fcp, False, False, 12, False) != 0 or lies(zp) != ziel:
            raise SystemExit("selftest zweiter lauf")
        # Neustart-Pfad mit Attrappen (kein echter Neustart): Rueckgabe 0 / Fehler 4 / Live nicht bestaetigt 5
        with open(zp, "w") as handle:
            handle.write(alt_mod)
        if anwenden(arbeit, fcp, False, False, 12, False, neustart=lambda: 0, live=lambda: (True, "attrappe")) != 0:
            raise SystemExit("selftest neustart ok")
        with open(zp, "w") as handle:
            handle.write(alt_mod)
        if anwenden(arbeit, fcp, False, False, 12, False, neustart=lambda: 1, live=lambda: (True, "x")) != 4:
            raise SystemExit("selftest neustart fehler")
        with open(zp, "w") as handle:
            handle.write(alt_mod)
        if anwenden(arbeit, fcp, False, False, 12, False, neustart=lambda: 0, live=lambda: (False, "x")) != 5:
            raise SystemExit("selftest live")
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
