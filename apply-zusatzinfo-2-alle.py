#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-zusatzinfo-2-alle. Schritt 2: Zusatzinfo je Kachel ein-/ausblendbar auf allen Seiten AUSSER der Lage-Seite ("/").
Seiten: /energie (bleibt), /speicher, /luft, /pegel, /lokale-energie, /umwelt, /adsb, /zuhause, /mesh, /pi, /funk.
Ersetzt NUR zusatzinfo.py (zi1-energie -> zi2-alle). dashboard.py und fullcheck.sh werden nicht angefasst (dashboard.py nur gelesen: Haken muss da sein).
Standard zugeklappt, Zustand gemeinsam in zusatzinfo.json (wird nicht angefasst), bei gelb/rot automatisch auf und danach wieder zu.
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
KENNUNG = "zusatzinfo2"

# Ausgangsstand: Pilot /energie (vom Pi bestaetigt). Nur zusatzinfo.py ist per Hash gesperrt.
VORHER = {
    "zusatzinfo.py": ("152f0b8ea2ff421b221ecf0d82bc8b162a92480781e8f7fba8bcd581855f0400", 33740),
}
HAKEN = "# ===== zusatzinfo (Schritt 0)"   # Block in dashboard.py (Schritt 0), nur gelesen
# Erwartung je Seite: (Regeln, markierte Kacheln mindestens). "/" (Lage) muss 0 haben.
SEITEN = {
    "/energie": (6, 6), "/speicher": (3, 3), "/luft": (5, 4), "/pegel": (1, 1), "/lokale-energie": (4, 4),
    "/umwelt": (5, 5), "/adsb": (6, 5), "/zuhause": (2, 1), "/mesh": (1, 1), "/pi": (9, 8), "/funk": (2, 2),
}
MOD_SHA = "eafa11a83ec3593672bd5235cd19f3b487b23ba99853f8f0736a3127e49428a5"
MOD_N = 44741
MOD_B64 = (
"""
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
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
    for name in ("zusatzinfo.py", "dashboard.py"):
        if os.path.islink(pfad[name]) or not os.path.isfile(pfad[name]):
            return pfad, {}, {}, "STOP %s fehlt oder ist ein Verweis" % pfad[name]
        with open(pfad[name], "rb") as handle:
            alt[name] = handle.read()
    if HAKEN not in alt["dashboard.py"].decode("utf-8", "replace"):
        return pfad, alt, {}, "STOP dashboard.py hat den zusatzinfo-Haken (Schritt 0) nicht. Nichts geschrieben."
    try:
        ziel = modul_neu()
        compile(ziel, "zusatzinfo.py", "exec")
    except (ValueError, SyntaxError) as exc:
        return pfad, alt, {}, "STOP %s" % exc
    if alt["zusatzinfo.py"] == ziel:
        return pfad, alt, None, ""
    if hashcheck:
        voll, n = VORHER["zusatzinfo.py"]
        ist = sha256(alt["zusatzinfo.py"])
        if ist != voll or len(alt["zusatzinfo.py"]) != n:
            return pfad, alt, {}, "STOP zusatzinfo.py ist %s/%d, Soll %s/%d. Nichts geschrieben." % (ist[:16], len(alt["zusatzinfo.py"]), voll[:16], n)
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


def _hole(pfad, timeout=30):
    import urllib.request
    with urllib.request.urlopen("http://127.0.0.1:5000" + pfad, timeout=timeout) as antwort:
        return antwort.read().decode("utf-8", "replace")


def pruefe_live(timeout=150, hole=None):
    """Nur lesen: Status-API, dann jede Seite auf 127.0.0.1:5000. -> (ok, info, zeilen)"""
    hole = hole or _hole
    ende = time.time() + timeout
    letzter = "keine Antwort"
    zeilen = []
    while time.time() < ende:
        try:
            j = json.loads(hole("/api/zusatzinfo/status", 10))
            if not (j.get("version") == "zi2-alle" and j.get("aktiv") is True):
                letzter = "Status unerwartet (noch alter Stand?)"
                time.sleep(5)
                continue
            fehl = []
            zeilen = []
            for pfad, (regeln, mind) in SEITEN.items():
                if (j.get("regeln") or {}).get(pfad) != regeln:
                    fehl.append("%s Regeln %s statt %d" % (pfad, (j.get("regeln") or {}).get(pfad), regeln))
                html = hole(pfad, 40)
                n = html.count('<div data-zi="')
                ok = n >= mind and 'id="zi-js"' in html
                zeilen.append("%-16s %2d Kacheln markiert (Soll >= %d) %s" % (pfad, n, mind, "ok" if ok else "ABWEICHUNG"))
                if not ok:
                    fehl.append("%s %d Kacheln statt >= %d" % (pfad, n, mind))
            lage = hole("/", 40)
            lage_n = lage.count(' data-zi="') + lage.count('id="zi-css"')
            zeilen.append("%-16s %2d Kacheln markiert (Soll 0, Lage bleibt unberuehrt) %s" % ("/ (Lage)", lage_n, "ok" if lage_n == 0 else "FEHLER"))
            if lage_n:
                fehl.append("Lage-Seite ist markiert")
            if not fehl:
                return True, "%s, aktiv, %d Seiten, Lage unberuehrt" % (j.get("version"), len(SEITEN)), zeilen
            letzter = "; ".join(fehl)[:200]
        except Exception as exc:
            letzter = type(exc).__name__
        time.sleep(6)
    return False, letzter, zeilen


def anwenden(basis, fullcheck, dry, kein, minute, hashcheck=True, neustart=None, live=None):
    pfad, alt, neu, fehler = berechne(basis, fullcheck, hashcheck)
    if fehler:
        print(fehler)
        return 2
    if neu is None:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    print("zusatzinfo.py endstand sha16 %s bytes %d (dashboard.py und fullcheck.sh werden nicht angefasst)" % (sha256(neu["zusatzinfo.py"])[:16], len(neu["zusatzinfo.py"])))
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
    erg = (live or pruefe_live)()
    ok, info = erg[0], erg[1]
    for zeile in (erg[2] if len(erg) > 2 else []):
        print("  " + zeile)
    print("zusatzinfo live: %s (%s)" % ("OK" if ok else "NICHT bestaetigt", info))
    print("Pfeil rechts im Kachelkopf klappt Details auf, je Seite 'Details: alle ein / alle aus'. Lage-Seite unveraendert.")
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
        dash = "x = 1\n" + HAKEN + "\nimport zusatzinfo\n"
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
        with open(dp, "w") as handle:
            handle.write("x = 1\n")
        if anwenden(arbeit, fcp, False, True, 12, False) != 2 or lies(zp) != alt_mod.encode():
            raise SystemExit("selftest haken")
        with open(dp, "w") as handle:
            handle.write(dash)
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
        # Live-Pruefung mit Attrappe: alles gut / Seite mit zu wenig Kacheln / Lage markiert / altes Modul
        def fake(zahl, lage=0, version="zi2-alle"):
            def h(pfad, t=10):
                if pfad.endswith("/status"):
                    return json.dumps({"version": version, "aktiv": True, "regeln": dict((p, v[0]) for p, v in SEITEN.items())})
                if pfad == "/":
                    return "<html>" + ' data-zi="x"' * lage + "</html>"
                return '<html>' + '<div data-zi="a.b" class="card"></div>' * zahl.get(pfad, SEITEN[pfad][1]) + '<script id="zi-js"></script></html>'
            return h
        if not pruefe_live(1, fake({}))[0]:
            raise SystemExit("selftest live ok")
        if pruefe_live(1, fake({"/pi": 2}))[0] or pruefe_live(1, fake({}, lage=1))[0] or pruefe_live(1, fake({}, version="zi1-energie"))[0]:
            raise SystemExit("selftest live fehler")
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
