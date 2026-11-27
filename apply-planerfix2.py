#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-planerfix2: None-sichere startswith im Planer plus einmaliger Traceback.

Nach planerfix (active=idle) blieb Planer-Fehler startswith auf None.
Haertet alle im Planer-Lauf erreichbaren .startswith per _s(x), und loggt
den Traceback beim ersten Planer-Fehler je Stick.
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

KENNUNG = "planerfix2"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-sdr"

START_SHA = "f8f1094e54ce0c6718d9ea19fcd3201d57219e29468526c78fe439ba5752c4f1"
START_SHA16 = "f8f1094e54ce0c67"
START_BYTES = 794568
END_SHA = "aa2cf4afac6fd3cb1ff4ce4aa4a97b7092c2b05d52de3ffcb01257385ca942f0"
END_SHA16 = "aa2cf4afac6fd3cb"
END_BYTES = 795082

_HELPER_ALT = "\nclass Planner:\n    def __init__(self, base, stick=1, main=None):\n"
_HELPER_NEU = '''
def _s(x):
    """Leerstring wenn kein Text - verhindert startswith auf None."""
    return x if isinstance(x, str) else ""


def _planer_exc(pl, e):
    pl.log("Planer-Fehler:", e)
    if getattr(pl, "_planer_tb", False):
        return
    pl._planer_tb = True
    import traceback
    pl.log("Planer-Fehler Traceback:\\n" + traceback.format_exc())


class Planner:
    def __init__(self, base, stick=1, main=None):
'''

PAARE = [
    (_HELPER_ALT, _HELPER_NEU, 1),
    ("what.startswith(", "_s(what).startswith(", 9),
    ("job.startswith(", "_s(job).startswith(", 9),
    ("j.startswith(", "_s(j).startswith(", 11),
    ("x[0].startswith(", "_s(x[0]).startswith(", 2),
    ("self.pin_err.startswith(", "_s(self.pin_err).startswith(", 1),
    ("perr.startswith(", "_s(perr).startswith(", 1),
    ("tmp.startswith(", "_s(tmp).startswith(", 1),
    ("a.startswith(", "_s(a).startswith(", 2),
    ("line.startswith(", "_s(line).startswith(", 4),
    ("sn.startswith(", "_s(sn).startswith(", 1),
    ("to.startswith(", "_s(to).startswith(", 1),
    ("txt.startswith(", "_s(txt).startswith(", 1),
    ("s.upper().startswith", "_s(s).upper().startswith", 1),
    ("if s.startswith(pre):", "if _s(s).startswith(pre):", 1),
    (
        'self.log("Planer-Fehler:", e)\n                wait = 10\n                # Watchdog\n',
        "_planer_exc(self, e)\n                wait = 10\n                # Watchdog\n",
        1,
    ),
    (
        'self.log("Planer-Fehler:", e)\n                wait = 10\n            try:\n',
        "_planer_exc(self, e)\n                wait = 10\n            try:\n",
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
    return (
        "def _s(" in text
        and "def _planer_exc(" in text
        and "_s(what).startswith(" in text
        and "what.startswith(" not in text
        and "_planer_exc(self, e)" in text
        and 'self.log("Planer-Fehler:", e)' not in text
    )


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
    zeilen = (out.stdout or "").splitlines()
    treffer = [ln for ln in zeilen if "Planer-Fehler" in ln]
    if treffer:
        print("STOP nach Neustart %d neue Planer-Fehler" % len(treffer))
        for ln in treffer[:12]:
            print(ln)
        tb = [ln for ln in zeilen if any(k in ln for k in (
            "Planer-Fehler Traceback", "Traceback (most recent", 'File "', "startswith"))]
        if tb:
            print("--- Traceback-Zeilen ---")
            for ln in tb[:60]:
                print(ln)
        else:
            print("Hinweis: kein Traceback im Journal (Patch evtl. nicht aktiv)")
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
    return "# stub planerfix2\n" + "".join(teile)


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
        os.environ.get("PLANERFIX2_SDR"),
        os.environ.get("PLANERFIX_SDR"),
        "/tmp/prepper_sdr_patched.py",
        "/tmp/prepper_sdr_fix2.py",
        "/tmp/prepper_sdr_base.py",
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


class _DummyP:
    pid = 1

    def poll(self):
        return None

    def communicate(self, timeout=None):
        return b"", b""

    def kill(self):
        pass


def _fakestart(pl, what):
    pl.active = what if isinstance(what, str) and what else "idle"
    pl.procs = [_DummyP()]
    pl.since = time.time()
    pl.err = None


def _unit_fresh(pfad, kontrast=None):
    """Frischer Start wie im Dienst: Airspy + Stick 1·5C + Stick 2, step() mehrfach.
    Danach None in allen plausiblen Textfeldern. contrast=unpatched path wirft noch."""
    import json
    import types

    arbeit = tempfile.mkdtemp(prefix="planerfix2-unit-")
    sysfs = os.path.join(arbeit, "sys")
    alt_sysfs = os.environ.get("SDR_SYSFS_USB")
    try:
        os.makedirs(sysfs)
        os.environ["SDR_SYSFS_USB"] = sysfs
        as_sn = "AB12CD34EF560001"

        def mk(n, vid, pid, sn, prod):
            d = os.path.join(sysfs, n)
            os.makedirs(d)
            for k, v in (("idVendor", vid), ("idProduct", pid), ("serial", sn), ("product", prod)):
                open(os.path.join(d, k), "w").write(v + "\n")

        mk("1-1.1", "0bda", "2838", "90000001", "RTL2838UHIDIR")
        mk("1-1.2", "0bda", "2838", "90000002", "RTL2838UHIDIR")
        mk("1-1.3", "1d50", "60a1", "AIRSPY SN:%s" % as_sn.lower(), "AIRSPY")
        devs = [
            {"name": "Airspy R2", "kind": "airspy", "usb": "1d50:60a1", "serial": "0x" + as_sn.lower(), "role": "11D"},
            {"name": "Stick 1", "kind": "rtl", "usb": "0bda:2838", "serial": "90000001", "role": "5C", "ppm_sfx": ""},
            {"name": "Stick 2", "kind": "rtl", "usb": "0bda:2838", "serial": "90000002", "role": "hobby", "ppm_sfx": "2"},
        ]
        cfg = {
            "devs_on": True,
            "devs": devs,
            "home": [49.0, 11.0],
            "bc_enable": True,
            "usb_ids": ["0bda:2838", "1d50:60a1"],
            "t2_roles": True,
        }
        open(os.path.join(arbeit, "sdr_config.json"), "w", encoding="utf-8").write(json.dumps(cfg))

        if kontrast:
            alt = _lade_sdr(kontrast, "planerfix2_alt")
            # unpatched: cmd/start/sub_done/lage_shares werfen bei None
            pl0 = alt.Planner(arbeit)
            threw = []
            try:
                pl0.cmd(None)
            except AttributeError as ex:
                if "startswith" in str(ex):
                    threw.append("cmd")
            try:
                pl0.start(None)
            except AttributeError as ex:
                if "startswith" in str(ex):
                    threw.append("start")
            try:
                pl0.sub_done({"queue": [None], "i": 0, "kind": "bc"}, time.time())
            except AttributeError as ex:
                if "startswith" in str(ex):
                    threw.append("sub_done")
            try:
                pl0.lage_shares = types.MethodType(alt.Planner.lage_shares, pl0)
                pl0.bc_queue = lambda: [(None, 60)]
                pl0.lage_shares(time.time())
            except AttributeError as ex:
                if "startswith" in str(ex):
                    threw.append("lage_shares")
            if "cmd" not in threw or "sub_done" not in threw or "lage_shares" not in threw:
                raise SystemExit("selftest kontrast fehlt %s" % threw)

        mod = _lade_sdr(pfad, "planerfix2_sdr")
        logs = []

        def _log(*a):
            logs.append(" ".join(str(x) for x in a))

        m = mod.Planner(arbeit)
        w = mod.Planner(arbeit, stick=2, main=m)
        h = mod.Planner(arbeit, stick=3, main=m)
        m.worker, m.hobbies, m.t2 = w, [h], True
        w.t2 = h.t2 = True
        for x in (m, w, h):
            x.log = _log
            x.tools = {"welle": "/usr/bin/welle-cli", "redsea": "/usr/bin/redsea"}
            x.start = types.MethodType(lambda self, what: _fakestart(self, what), x)
        try:
            m.dual_tick()
        except Exception as ex:
            raise SystemExit("selftest dual_tick %s" % ex)
        # Rollen wie im Dienst nach dual_tick
        if (m.role, w.role, h.role) != ("bc", "rot", "rot"):
            # dual_tick kann am Register scheitern, Rollen setzen
            try:
                m.set_role("bc")
                w.set_role("rot")
                h.set_role("rot")
            except Exception:
                m.role, w.role, h.role = "bc", "rot", "rot"

        for i in range(4):
            for pl, name in ((m, "main"), (w, "5C"), (h, "hobby")):
                try:
                    wait, mode = pl.step()
                except AttributeError as ex:
                    if "startswith" in str(ex):
                        raise SystemExit("selftest frisch startswith %s round %s: %s" % (name, i, ex))
                    raise
                except Exception:
                    # andere Fehler (fehlende Binaries etc.) sind hier egal
                    pass
                try:
                    pl.want(mode if isinstance(mode, dict) else {"mode": "auto"}, time.time())
                except AttributeError as ex:
                    if "startswith" in str(ex):
                        raise SystemExit("selftest frisch want %s: %s" % (name, ex))
                    raise

        # None in jedem plausiblen Textfeld, dann step/want/cmd/start/sub_done
        felder = (
            "active", "role", "err", "pin_err", "dev_sn", "nz_end",
            "_last_try", "last_err",
        )
        for pl, name in ((m, "main"), (w, "5C"), (h, "hobby")):
            for f in felder:
                setattr(pl, f, None)
            try:
                pl.cfg["auto"] = [None, "aprs"]
            except Exception:
                pass
            pl.special = {
                "kind": "bc",
                "queue": [None, "dab:0"],
                "durs": [1, 1],
                "i": 0,
                "sub_end": time.time() - 1,
                "hard_end": time.time() + 60,
                "t0": time.time() - 10,
            }
            def _kein_startswith(fn, *a, **k):
                try:
                    return fn(*a, **k)
                except AttributeError as ex:
                    if "startswith" in str(ex):
                        raise SystemExit("selftest None-Felder %s %s: %s logs=%s" % (name, getattr(fn, "__name__", fn), ex, logs[-6:]))
                    raise

            _kein_startswith(pl.cmd, None)
            try:
                pl.cmd("dab:0")
            except AttributeError as ex:
                if "startswith" in str(ex):
                    raise SystemExit("selftest None-Felder %s cmd dab: %s" % (name, ex))
            except Exception:
                pass
            _kein_startswith(pl.start, None)
            try:
                pl.start("rds:0")
            except AttributeError as ex:
                if "startswith" in str(ex):
                    raise SystemExit("selftest None-Felder %s start rds: %s" % (name, ex))
            except Exception:
                pass
            _kein_startswith(pl._pkind, None)
            _kein_startswith(pl.sub_done, {"queue": [None], "i": 0, "kind": "bc"}, time.time())
            _kein_startswith(pl.lage_shares, time.time())
            _kein_startswith(pl.stick_health, time.time())
            _kein_startswith(pl.want, {"mode": "auto"}, time.time())
            try:
                pl.want({"mode": None}, time.time())
            except AttributeError as ex:
                if "startswith" in str(ex):
                    raise SystemExit("selftest None-Felder %s want None-mode: %s" % (name, ex))
            except Exception:
                pass
            _kein_startswith(pl.bc_queue)
            try:
                pl.step()
            except AttributeError as ex:
                if "startswith" in str(ex):
                    raise SystemExit("selftest None-Felder %s step: %s logs=%s" % (name, ex, logs[-6:]))
            except Exception:
                pass

        # Traceback nur einmal je Planer
        if not hasattr(mod, "_planer_exc"):
            raise SystemExit("selftest _planer_exc fehlt")
        bag = []

        class _L:
            def log(self, *a):
                bag.append(" ".join(str(x) for x in a))

        dummy = _L()
        try:
            raise RuntimeError("tb-probe")
        except RuntimeError as ex:
            mod._planer_exc(dummy, ex)
            n1 = sum(1 for x in bag if "Traceback" in x)
            mod._planer_exc(dummy, ex)
            n2 = sum(1 for x in bag if "Traceback" in x)
        if n1 != 1 or n2 != 1:
            raise SystemExit("selftest traceback einmal %s/%s %s" % (n1, n2, bag))
        if not any("Planer-Fehler:" in x for x in bag):
            raise SystemExit("selftest traceback log %s" % bag)
        if not getattr(mod, "_s", None) or mod._s(None) != "" or mod._s("cal:0") != "cal:0":
            raise SystemExit("selftest _s")
        if mod._s(None).startswith("cal:"):
            raise SystemExit("selftest _s startswith")
    finally:
        if alt_sysfs is None:
            os.environ.pop("SDR_SYSFS_USB", None)
        else:
            os.environ["SDR_SYSFS_USB"] = alt_sysfs
        shutil.rmtree(arbeit, ignore_errors=True)


def selftest():
    with tempfile.TemporaryDirectory(prefix="planerfix2-") as tmp:
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
        if "def _s(" not in text or "def _planer_exc(" not in text:
            raise SystemExit("selftest helper")
        if "_s(what).startswith(" not in text or "what.startswith(" in text:
            raise SystemExit("selftest what")
        if "_planer_exc(self, e)" not in text or 'self.log("Planer-Fehler:", e)' in text:
            raise SystemExit("selftest except")
        if (os.stat(pfad).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest modus")
        bak = [p for p in os.listdir(root) if "bak-%s-" % KENNUNG in p]
        if not bak:
            raise SystemExit("selftest backup")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest idempotent")

    quelle, data, h = _finde_basis_sdr()
    if not quelle:
        raise SystemExit("selftest echte Basis fehlt (PLANERFIX2_SDR oder f8f1094e54ce0c67)")
    with tempfile.TemporaryDirectory(prefix="planerfix2-real-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        ziel = os.path.join(root, "prepper_sdr.py")
        start_pfad = None
        if h == END_SHA:
            open(ziel, "wb").write(data)
        else:
            open(ziel, "wb").write(data)
            os.chmod(ziel, 0o644)
            start_pfad = os.path.join(tmp, "start.py")
            open(start_pfad, "wb").write(data)
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
        _unit_fresh(ziel, kontrast=start_pfad)
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
