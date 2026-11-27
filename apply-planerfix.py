#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-planerfix: Planer stuerzt nicht mehr bei active=None (startswith cal:/nz:).

Setzt in _ff7_start, stick_watchdog und manueller Freigabe "idle" statt None.
Nur prepper_sdr.py. Kein fullcheck. Neustart nur prepper-sdr, Minute 05-39 Berlin.
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

KENNUNG = "planerfix"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-sdr"

START_SHA = "17ee0ae046d25be9805c3abcd92a4b5e4185514e82f7deac218f748f362fc356"
START_SHA16 = "17ee0ae046d25be9"
START_BYTES = 794528
END_SHA = "f8f1094e54ce0c6718d9ea19fcd3201d57219e29468526c78fe439ba5752c4f1"
END_SHA16 = "f8f1094e54ce0c67"
END_BYTES = 794568

PAARE = [
    (
        '        if self.active.startswith("cal:") and self.procs and self.alive() and now - self.last_calpoll >= 4:\n',
        '        if self.active and self.active.startswith("cal:") and self.procs and self.alive() and now - self.last_calpoll >= 4:\n',
        1,
    ),
    (
        '            if self.active.startswith("nz:"):\n',
        '            if self.active and self.active.startswith("nz:"):\n',
        1,
    ),
    (
        '            self.kill()\n            self.active = None\n            time.sleep(1.5)\n',
        '            self.kill()\n            self.active = "idle"\n            time.sleep(1.5)\n',
        2,
    ),
    (
        '                        self.kill()\n                        self.active = None\n',
        '                        self.kill()\n                        self.active = "idle"\n',
        1,
    ),
    (
        '        self.active, self.retry_at = None, time.time() + 30\n',
        '        self.active, self.retry_at = "idle", time.time() + 30\n',
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


def ersetze(text, alt, neu, name, n):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


def patch(text):
    for alt, neu, n in PAARE:
        text = ersetze(text, alt, neu, "prepper_sdr.py", n)
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


def schon_gefixt(text):
    if any(text.count(alt) for alt, _neu, _n in PAARE):
        return False
    return all(neu in text for _alt, neu, _n in PAARE)


def stand(data):
    return sha256(data), len(data)


def berechne(pfad, hashcheck=True):
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
    if schon_gefixt(roh):
        return alt, None, None
    if hashcheck and (ist != START_SHA or n != START_BYTES):
        return None, None, "STOP %s ist %s/%s soll %s/%s" % (
            pfad, ist[:16], n, START_SHA16, START_BYTES)
    try:
        text = patch(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    neu = text.encode("utf-8")
    if hashcheck:
        compile(neu, "prepper_sdr.py", "exec")
    got, gn = stand(neu)
    if hashcheck and (got != END_SHA or gn != END_BYTES):
        return None, None, "STOP Endstand %s/%s erwartet %s/%s" % (got[:16], gn, END_SHA16, END_BYTES)
    return alt, neu, None


def journal_pruefen(seit, pause=30):
    print("warte %d s auf Journal" % pause)
    time.sleep(pause)
    try:
        out = subprocess.run(
            ["journalctl", "-u", DIENST, "--since", seit, "--no-pager", "-o", "short-iso"],
            capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("Hinweis: Journal nicht gelesen (%s)" % type(exc).__name__)
        return True
    if out.returncode != 0:
        print("Hinweis: journalctl rc %s" % out.returncode)
        return True
    treffer = [ln for ln in (out.stdout or "").splitlines() if "Planer-Fehler" in ln]
    if treffer:
        print("STOP nach Neustart %d neue Planer-Fehler" % len(treffer))
        for ln in treffer[:8]:
            print(ln)
        return False
    print("Journal %d s: kein neuer Planer-Fehler" % pause)
    return True


def neustart():
    rc = subprocess.call(["systemctl", "restart", DIENST])
    if rc != 0:
        rc = subprocess.call(["sudo", "systemctl", "restart", DIENST])
    return rc


def anwenden(root, dry, kein, minute, hashcheck=True, pause=30):
    pfad = os.path.join(root, "prepper_sdr.py")
    alt, neu, fehler = berechne(pfad, hashcheck)
    if fehler:
        print(fehler)
        return 2
    if neu is None:
        print("bereits installiert, keine Aenderung, kein Neustart")
        print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(alt)[:16], len(alt)))
        return 0
    print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(neu)[:16], len(neu)))
    if dry:
        print("dry-run: nichts geschrieben")
        return 0
    if not kein and not im_fenster(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    try:
        bak = sichern(pfad, stempel)
        print("Sicherung %s" % bak)
        schreibe(pfad, neu)
    except OSError as exc:
        print("STOP beim Schreiben (%s)" % type(exc).__name__)
        return 3
    data = open(pfad, "rb").read()
    print("prepper_sdr.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
    if hashcheck and sha256(data) != END_SHA:
        print("STOP geschriebene Datei weicht vom Soll-Hash ab")
        return 3
    if kein:
        print("kein Neustart. Aktiv nach: sudo systemctl restart %s" % DIENST)
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = neustart()
    print("restart %s rc %s" % (DIENST, rc))
    if rc != 0:
        print("Neustart fehlgeschlagen. Dateien sind neu. Von Hand: sudo systemctl restart %s" % DIENST)
        return 4
    if not journal_pruefen(seit, pause):
        return 4
    return 0


def _stub_module():
    teile = [alt for alt, _neu, n in PAARE for _i in range(n)]
    return "# stub planerfix\n" + "".join(teile)


def _stub_fehlende():
    import types
    for name in ("pinneberg_rolle", "flugfunk"):
        if name not in sys.modules:
            mod = types.ModuleType(name)
            mod.engaged = lambda base: False
            sys.modules[name] = mod


def _lade_sdr(pfad, name):
    import importlib.util
    _stub_fehlende()
    spec = importlib.util.spec_from_file_location(name, pfad)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _finde_basis_sdr():
    cands = [
        os.environ.get("PLANERFIX_SDR"),
        "/tmp/prepper_sdr_base.py",
        "/tmp/prepper_sdr_patched.py",
        os.path.join(BASIS, "prepper_sdr.py"),
        os.path.join(os.getcwd(), "prepper_sdr.py"),
    ]
    for pfad in cands:
        if not pfad or not os.path.isfile(pfad):
            continue
        data = open(pfad, "rb").read()
        h = sha256(data)
        if (h == START_SHA and len(data) == START_BYTES) or (h == END_SHA and len(data) == END_BYTES):
            return pfad, data, h
    return None, None, None


def _unit_step(pfad):
    import json
    arbeit = tempfile.mkdtemp(prefix="planerfix-unit-")
    try:
        open(os.path.join(arbeit, "sdr_config.json"), "w", encoding="utf-8").write(
            json.dumps({"serial": "90000001", "usb_ids": ["0bda:2838"], "home": [0, 0]}))
        mod = _lade_sdr(pfad, "planerfix_sdr")
        pl = mod.Planner(arbeit)
        sn = mod.cfg_serial(pl.cfg)
        if not sn:
            raise SystemExit("selftest serial")
        mod.get_mode = lambda _b: {"mode": "off"}
        mod.stick_info = lambda _ids: [{"serial": sn, "product": "NESDR"}]
        pl.active = None
        pl.procs = []
        wait, mode = pl.step()
        if mode.get("mode") != "off":
            raise SystemExit("selftest step mode %s" % mode)
        if wait is None:
            raise SystemExit("selftest step wait")
        pl.active = "dab:0"
        pl.retry_at = 0
        orig = getattr(mod, "ff7_whisper_laeuft", None)
        mod.ff7_whisper_laeuft = lambda: True
        try:
            mod._ff7_start(pl, "dab:0")
        finally:
            if orig is not None:
                mod.ff7_whisper_laeuft = orig
        if pl.active != "idle":
            raise SystemExit("selftest ff7 active %r" % pl.active)
        pl.active = "rds:0"
        pl.procs = [type("P", (), {"poll": staticmethod(lambda: None), "pid": 0})()]
        pl.since = time.time() - 200

        def _noop(*_a, **_k):
            pl.procs = []

        pl.kill = _noop
        schlaf = time.sleep
        time.sleep = lambda _s: None
        try:
            pl.stick_watchdog(time.time())
        finally:
            time.sleep = schlaf
        if pl.active != "idle":
            raise SystemExit("selftest watchdog active %r" % pl.active)
    finally:
        shutil.rmtree(arbeit, ignore_errors=True)


def selftest():
    with tempfile.TemporaryDirectory(prefix="planerfix-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        pfad = os.path.join(root, "prepper_sdr.py")
        open(pfad, "w", encoding="utf-8").write(_stub_module())
        os.chmod(pfad, 0o640)
        vorher = open(pfad, "rb").read()
        if anwenden(root, False, False, 4, hashcheck=False, pause=0) != 2:
            raise SystemExit("selftest fenster")
        if open(pfad, "rb").read() != vorher:
            raise SystemExit("selftest fenster geschrieben")
        if anwenden(root, True, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest dry")
        if open(pfad, "rb").read() != vorher:
            raise SystemExit("selftest dry geschrieben")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest lauf")
        text = open(pfad, encoding="utf-8").read()
        if 'self.active and self.active.startswith("cal:")' not in text:
            raise SystemExit("selftest cal")
        if 'self.active and self.active.startswith("nz:")' not in text:
            raise SystemExit("selftest nz")
        if text.count('self.active = "idle"') < 3:
            raise SystemExit("selftest idle %s" % text.count('self.active = "idle"'))
        if "self.active = None" in text or "retry_at = None," in text:
            raise SystemExit("selftest None bleibt")
        if (os.stat(pfad).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest modus")
        bak = [p for p in os.listdir(root) if "bak-%s-" % KENNUNG in p]
        if not bak:
            raise SystemExit("selftest backup")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest idempotent")

    quelle, data, h = _finde_basis_sdr()
    if not quelle:
        raise SystemExit("selftest echte Basis fehlt (PLANERFIX_SDR oder 17ee0ae046d25be9)")
    with tempfile.TemporaryDirectory(prefix="planerfix-real-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        ziel = os.path.join(root, "prepper_sdr.py")
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
        _unit_step(ziel)
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
