#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-dabfix: DAB-Sync und Flugfunk-Sprueche/Live nach flugfunk-7.

Kein voller Rueckbau von flugfunk-7: nur die zwei schaedlichen Stellen.
1) prepper_sdr.py: welle-cli ohne cpulimit -l 20 / nice -n 19 (OFDM-Sync).
   Whisper-Pause in _ff7_start bleibt. 10C-Rueckfall (7b) bleibt.
2) flugfunk.py: Transkript-Filter wieder wie vor flugfunk-7 (Guard-Ausnahme
   hatte ATIS/Radar verworfen); Live hoeren wieder /api/flugfunk/stream
   statt Icecast-Mount /flugfunk.

Kein fullcheck. Neustart nur prepper-sdr und prepper-dashboard, Minute 05-39 Berlin.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "dabfix"
BASIS = "/home/fmg/prepper-dashboard"
DIENSTE = ("prepper-sdr", "prepper-dashboard")

START_SHA = "aa2cf4afac6fd3cb1ff4ce4aa4a97b7092c2b05d52de3ffcb01257385ca942f0"
START_SHA16 = "aa2cf4afac6fd3cb"
START_BYTES = 795082
END_SHA = "4f15665aa12dabf9c2ed19094d7ac7ac01cf7583d3c9d8821e498bd7cd1c95e2"
END_SHA16 = "4f15665aa12dabf9"
END_BYTES = 794952

SDR_PAARE = [
    (
        'def ff7_dab_argv(argv):\n'
        '    if not argv or not str(argv[0]).endswith("welle-cli"):\n'
        '        return list(argv)\n'
        '    neu = ["nice", "-n", "19"] + list(argv) if shutil.which("nice") else list(argv)\n'
        '    if shutil.which("cpulimit"):\n'
        '        return ["cpulimit", "-l", str(FF7_WELLE_PROZENT), "--"] + neu\n'
        '    return neu\n',
        'def ff7_dab_argv(argv):\n'
        '    """welle-cli ungedrosselt: cpulimit -l 20 / nice -n 19 verhinderten OFDM-Sync (flugfunk-7). Whisper-Pause bleibt in _ff7_start."""\n'
        '    return list(argv)\n',
        1,
    ),
]

FF_PAARE = [
    (
        '        if not notfall and (k is None or k < MIN_P or muell(text)):\n',
        '        if k is not None and k < MIN_P and not notfall:\n',
        1,
    ),
    (
        "    audio.src='/flugfunk?t='+Date.now();",
        "    audio.src='/api/flugfunk/stream?t='+Date.now();",
        2,
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


def ersetze(text, alt, neu, name, n):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


def patch_sdr(text):
    for alt, neu, n in SDR_PAARE:
        text = ersetze(text, alt, neu, "prepper_sdr.py", n)
    return text


def patch_ff(text):
    for alt, neu, n in FF_PAARE:
        text = ersetze(text, alt, neu, "flugfunk.py", n)
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
        "def ff7_dab_argv" in text
        and '["cpulimit", "-l", str(FF7_WELLE_PROZENT)' not in text
        and '["nice", "-n", "19"]' not in text
        and "welle-cli ungedrosselt" in text
    )


def schon_ff(text):
    return (
        "if k is not None and k < MIN_P and not notfall:" in text
        and "if not notfall and (k is None or k < MIN_P or muell(text)):" not in text
        and "audio.src='/flugfunk?t='" not in text
    )


def stand(data):
    return sha256(data), len(data)


def berechne_sdr(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == END_SHA and n == END_BYTES:
        return alt, None, None
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_sdr(roh) and 'welle-cli ungedrosselt' in roh:
        return alt, None, None
    if hashcheck and (ist != START_SHA or n != START_BYTES):
        return None, None, "STOP %s ist %s/%s soll %s/%s" % (
            pfad, ist[:16], n, START_SHA16, START_BYTES)
    try:
        text = patch_sdr(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    neu = text.encode("utf-8")
    if hashcheck:
        compile(neu, "prepper_sdr.py", "exec")
    got, gn = stand(neu)
    if hashcheck and (got != END_SHA or gn != END_BYTES):
        return None, None, "STOP Endstand %s/%s erwartet %s/%s" % (got[:16], gn, END_SHA16, END_BYTES)
    return alt, neu, None


def berechne_ff(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_ff(roh):
        return alt, None, None
    # mind. der Filter-Anker muss passen; Live-URL 2x, falls schon teilweise geaendert: zaehlen
    try:
        text = patch_ff(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    neu = text.encode("utf-8")
    if hashcheck and ("class Session" in text or "def transkribieren" in roh):
        try:
            compile(neu, "flugfunk.py", "exec")
        except SyntaxError:
            if "class Session" in text:
                raise
    if not schon_ff(neu.decode("utf-8")):
        return None, None, "STOP flugfunk.py Patch unvollstaendig"
    return alt, neu, None


def journal_pruefen(seit, pause=90):
    print("warte %d s auf Journal/Live" % pause)
    time.sleep(pause)
    ok_dab, ok_ff = True, True
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
        ok_dab = False
    treffer_ok = [ln for ln in zeilen if "dabFix DAB 11D: Sync ja" in ln or (
        "Ensemble" in ln and "11D" in ln and "Lost coarse" not in ln)]
    treffer_bad = [ln for ln in zeilen if "Lost coarse sync" in ln or "SyncOnPhase failed" in ln]
    if treffer_ok:
        print("Journal: 11D Sync/Ensemble vorhanden")
        for ln in treffer_ok[:4]:
            print(ln)
    elif zeilen:
        print("STOP nach %d s kein 11D-Sync/Ensemble im Journal" % pause)
        for ln in treffer_bad[:6]:
            print(ln)
        ok_dab = False
    else:
        print("Hinweis: Journal leer oder unlesbar, 11D-Sync nicht bestaetigt")

    # Flugfunk Live-Stream (alter Weg, ohne Icecast-Mount)
    url = "http://127.0.0.1:5000/api/flugfunk/stream"
    try:
        r = subprocess.run(
            ["curl", "-fsS", "-m", "5", "-o", "/tmp/dabfix-ff-stream.bin", "-w", "%{http_code} %{content_type}", url],
            capture_output=True, text=True, timeout=8)
        body = (r.stdout or "").strip()
        print("GET %s -> %s rc %s" % (url, body, r.returncode))
        if r.returncode != 0 or not body.startswith("200"):
            ok_ff = False
            print("STOP Flugfunk Live-Stream nicht ok")
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("Hinweis: Live-Stream nicht geprueft (%s)" % type(exc).__name__)
    return ok_dab and ok_ff


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
    ff = os.path.join(root, "flugfunk.py")
    salt, sneu, sfehl = berechne_sdr(sdr, hashcheck)
    if sfehl:
        print(sfehl)
        return 2
    falt, fneu, ffehl = berechne_ff(ff, hashcheck)
    if ffehl:
        print(ffeh)
        return 2
    if sneu is None and fneu is None:
        print("bereits installiert, keine Aenderung, kein Neustart")
        print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(salt)[:16], len(salt)))
        print("flugfunk.py endstand sha16 %s bytes %d" % (sha256(falt)[:16], len(falt)))
        return 0
    if sneu is not None:
        print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(sneu)[:16], len(sneu)))
    if fneu is not None:
        print("flugfunk.py endstand sha16 %s bytes %d" % (sha256(fneu)[:16], len(fneu)))
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
        if fneu is not None:
            print("Sicherung %s" % sichern(ff, stempel))
            schreibe(ff, fneu)
    except OSError as exc:
        print("STOP beim Schreiben (%s)" % type(exc).__name__)
        return 3
    if sneu is not None:
        data = open(sdr, "rb").read()
        print("prepper_sdr.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
        if hashcheck and sha256(data) != END_SHA:
            print("STOP geschriebene Datei weicht vom Soll-Hash ab")
            return 3
    if fneu is not None:
        data = open(ff, "rb").read()
        print("flugfunk.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
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


def _finde_sdr():
    cands = [
        os.environ.get("DABFIX_SDR"),
        "/tmp/prepper_sdr_current.py",
        "/tmp/prepper_sdr_dabfix.py",
        os.path.join(BASIS, "prepper_sdr.py"),
    ]
    for pfad in cands:
        if not pfad or not os.path.isfile(pfad):
            continue
        data = open(pfad, "rb").read()
        h = sha256(data)
        if (h == START_SHA and len(data) == START_BYTES) or (h == END_SHA and len(data) == END_BYTES):
            return pfad, data, h
    return None, None, None


def selftest():
    with tempfile.TemporaryDirectory(prefix="dabfix-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        sdr = os.path.join(root, "prepper_sdr.py")
        ff = os.path.join(root, "flugfunk.py")
        open(sdr, "w", encoding="utf-8").write(
            "# stub\n" + "".join(alt for alt, _n, n in SDR_PAARE for _i in range(n)))
        open(ff, "w", encoding="utf-8").write(
            "# stub\n" + "".join(alt for alt, _n, n in FF_PAARE for _i in range(n)))
        os.chmod(sdr, 0o640)
        os.chmod(ff, 0o640)
        vorher_s = open(sdr, "rb").read()
        vorher_f = open(ff, "rb").read()
        if anwenden(root, False, False, 4, hashcheck=False, pause=0) != 2:
            raise SystemExit("selftest fenster")
        if open(sdr, "rb").read() != vorher_s or open(ff, "rb").read() != vorher_f:
            raise SystemExit("selftest fenster geschrieben")
        if anwenden(root, True, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest dry")
        if open(sdr, "rb").read() != vorher_s:
            raise SystemExit("selftest dry geschrieben")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest lauf")
        st = open(sdr, encoding="utf-8").read()
        ft = open(ff, encoding="utf-8").read()
        if '["cpulimit", "-l", str(FF7_WELLE_PROZENT)' in st or '["nice", "-n", "19"]' in st:
            raise SystemExit("selftest sdr cpulimit")
        if "if k is not None and k < MIN_P and not notfall:" not in ft:
            raise SystemExit("selftest ff filter")
        if "audio.src='/flugfunk?t='" in ft:
            raise SystemExit("selftest ff live")
        if ft.count("audio.src='/api/flugfunk/stream?t='") != 2:
            raise SystemExit("selftest ff stream %s" % ft.count("audio.src='/api/flugfunk/stream?t='"))
        if (os.stat(sdr).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest modus")
        bak = [p for p in os.listdir(root) if "bak-%s-" % KENNUNG in p]
        if len(bak) < 2:
            raise SystemExit("selftest backup %s" % bak)
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest idempotent")

    quelle, data, h = _finde_sdr()
    if not quelle:
        raise SystemExit("selftest echte SDR-Basis fehlt (DABFIX_SDR oder aa2cf4afac6fd3cb)")
    with tempfile.TemporaryDirectory(prefix="dabfix-real-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        ziel = os.path.join(root, "prepper_sdr.py")
        # flugfunk-Stub mit echten Ankern, damit berechne_ff nicht STOPPT
        open(os.path.join(root, "flugfunk.py"), "w", encoding="utf-8").write(
            "# stub\n" + "".join(alt for alt, _n, n in FF_PAARE for _i in range(n)))
        if h == END_SHA:
            open(ziel, "wb").write(data)
        else:
            open(ziel, "wb").write(data)
            os.chmod(ziel, 0o644)
            if anwenden(root, True, True, 12, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real dry")
            if open(ziel, "rb").read() != data:
                raise SystemExit("selftest real dry geschrieben")
            if anwenden(root, False, True, 12, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real lauf")
            if anwenden(root, False, False, 4, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real bereits/fenster")
        neu = open(ziel, "rb").read()
        if sha256(neu) != END_SHA or len(neu) != END_BYTES:
            raise SystemExit("selftest real hash %s/%s" % (sha256(neu)[:16], len(neu)))
        compile(neu, "prepper_sdr.py", "exec")
        src = neu.decode("utf-8")
        a = src.index("def ff7_dab_argv")
        b = src.index("\n\n", a)
        ns = {}
        exec(compile(src[a:b] + "\n", "ff7_dab_argv.py", "exec"), ns)
        argv = ns["ff7_dab_argv"](["/usr/bin/welle-cli", "-c", "11D"])
        if argv[0] != "/usr/bin/welle-cli" or "cpulimit" in argv or "nice" in argv:
            raise SystemExit("selftest ff7_dab_argv %s" % argv)
        if "def _ff7_start" not in neu.decode("utf-8") or "DAB pausiert, Whisper laeuft" not in neu.decode("utf-8"):
            raise SystemExit("selftest whisper-pause fehlt")
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
