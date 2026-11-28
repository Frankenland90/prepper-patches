#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-usbcycle.py (Paket 10) - USB-Wache: Hub-Zyklus + Neustart robust (kein rc -15 mehr).

Ursache (aus der Ereignisliste 09:11-10:14): prepper-sdr-wdhelper hub-cycle laeuft als Kind von prepper_sdr (sudo -n helper) in
der cgroup von prepper-sdr. Nach uhubctl (cycle -d 5, ca. 6 s - der Timeout 40/90 s reicht) ruft der Helfer `systemctl restart
prepper-sdr`; der Neustart schickt SIGTERM an die ganze cgroup, also auch an sudo/Helfer/Wache -> rc -15 und kein Ergebnis-Log.
Der Zyklus selbst lief; Ergebnis und Folgelog gingen verloren.

Fix:
  prepper-sdr-wdhelper: hub-cycle startet `systemd-run --no-block --collect` -> transiente Einheit prepper-sdr-usbcycle-<epoch>
      (eigene cgroup, RuntimeMaxSec=240) mit `hub-cycle-run`: uhubctl -l 1-1 -p 1 -a cycle -d 5 (Timeout 40 s), bis zu 20 s auf den
      Genesys-Hub 1-1.1 warten, dann systemctl restart prepper-sdr (Timeout 60 s). Ergebnis nach /run/prepper-sdr-usbcycle.json (0644).
      Nur in der Einheit lauffaehig (INVOCATION_ID). Nie USV (1-1 Port 3), Airspy (Port 4), Hub 2: _uhubctl_cmd/_verify_rtl_hub unveraendert.
      Fallback ohne systemd-run: alter Weg.
  prepper_sdr.py: Stufe-0-Zeilen im Ereignis-Log bekommen den Text (rc 4 = "1-1.1/authorized fehlt" oder authorized-Schreibfehler);
      "Hub-Zyklus gestartet" statt rc -15; nach dem Neustart schreibt die Wache "Ergebnis Hub-Zyklus + Neustart: rc N ..." (einmal je Lauf).
sudoers (zz-prepper-sdr-wd) bleibt UNVERAENDERT (Argument hub-cycle ist schon erlaubt); wird nur mit visudo -c geprueft.

Aufruf (Pi, als root):  sudo python3 apply-usbcycle.py [--dry-run] [--kein-neustart] [--selftest]
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
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

KENNUNG = "usbcycle"
BASIS = "/home/fmg/prepper-dashboard"
HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"
SUDOERS = "/etc/sudoers.d/zz-prepper-sdr-wd"
HELPER_SOLL = ("c40c5a62bfb8294d608ff46d1843867bdb8ab2834058cc7b8ea964823d83170a", 19096)
SDR_SOLL = ("ad62d9a56c6aa682246945bae7b65eaa75afb216b5a20dd1d4881ea42cc0d85c", 820331)
URL = "http://127.0.0.1:5000"
RESULT_FILE = "/run/prepper-sdr-usbcycle.json"


class Stop(Exception):
    pass


def sha256(b):
    if isinstance(b, str):
        b = b.encode("utf-8")
    return hashlib.sha256(b).hexdigest()


def stand(b):
    return sha256(b), len(b)


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise Stop("STOP %s: Anker %d mal gefunden, erwartet %d" % (name, c, n))
    return text.replace(alt, neu)


# ------------------------------------------------------------------ Helfer (wdhelper)
H_CONST = 'SDR_UNIT = "prepper-sdr"\nSYSTEMD_RUN = ("/usr/bin/systemd-run", "/bin/systemd-run")\nHELPER_PATH = "/usr/local/sbin/prepper-sdr-wdhelper"\nRESULT = "/run/prepper-sdr-usbcycle.json"      # Ergebnis des Hub-Zyklus, lesbar fuer prepper-sdr (usbwache)\n'
H_FUNCS = 'def _result(phase, t0, unit, rc=None, txt=""):\n    """usbcycle: Ergebnisdatei (0644, atomar) fuer die USB-Wache in prepper-sdr. Ein Fehler hier bricht den Zyklus nie ab."""\n    try:\n        d = {"t": t0, "unit": unit, "phase": phase, "rc": rc, "txt": str(txt)[:160],\n             "t_end": int(time.time()) if phase == "fertig" else None}\n        tmp = RESULT + ".tmp"\n        with open(tmp, "w", encoding="utf-8") as fh:\n            json.dump(d, fh)\n        os.chmod(tmp, 0o644)\n        os.replace(tmp, RESULT)\n    except Exception:\n        pass\n\n\ndef hub_cycle_async(root=SYS, run=None, now=time.time, helper=HELPER_PATH, me=None):\n    """usbcycle: hub-cycle aus prepper-sdr heraus. Zyklus + Neustart laufen als eigene transiente systemd-Einheit\n    ausserhalb der cgroup von prepper-sdr - sonst beendet `systemctl restart prepper-sdr` den Aufrufer samt Helfer (rc -15).\n    Kehrt sofort zurueck. 125 = so nicht moeglich (dann alter Weg)."""\n    ok, why = _verify_rtl_hub(root)\n    if not ok:\n        return 3, why\n    sr = next((x for x in SYSTEMD_RUN if os.path.isfile(x)), None)\n    py = sys.executable or "/usr/bin/python3"\n    me = me or os.path.realpath(__file__)\n    if sr is None or me != helper or not os.path.isfile(py):\n        return 125, "systemd-run oder Hilfsprogramm-Pfad nicht nutzbar"\n    t0 = int(now())\n    unit = "prepper-sdr-usbcycle-%d" % t0\n    cmd = [sr, "--no-block", "--collect", "--quiet", "--unit", unit, "--property=RuntimeMaxSec=240",\n           "--setenv=USBCYCLE_T0=%d" % t0, py, "-I", helper, "hub-cycle-run"]\n    r = (run or subprocess.run)(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)\n    if getattr(r, "returncode", 1) != 0:\n        err = ((r.stderr or r.stdout) or "").strip().splitlines()\n        return 125, "systemd-run rc %d: %s" % (r.returncode, (err[-1] if err else "")[:80])\n    _result("gestartet", t0, unit)\n    return 0, "uhubctl -l 1-1 -p 1 cycle und Neustart prepper-sdr laufen als eigene Einheit %s" % unit\n\n\ndef hub_cycle_run(root=SYS, run=None, sleep=time.sleep, uhub=None, env=None):\n    """usbcycle: nur innerhalb der transienten Einheit (INVOCATION_ID gesetzt). uhubctl -l 1-1 -p 1 -a cycle -d 5, auf den\n    Genesys-Hub warten (max. 20 s), dann systemctl restart prepper-sdr. Ergebnis immer nach RESULT."""\n    env = os.environ if env is None else env\n    if not env.get("INVOCATION_ID"):\n        return 2, "hub-cycle-run nur als eigene systemd-Einheit"\n    try:\n        t0 = int(env.get("USBCYCLE_T0") or time.time())\n    except ValueError:\n        t0 = int(time.time())\n    unit = "prepper-sdr-usbcycle-%d" % t0\n\n    def fertig(rc, txt):\n        _result("fertig", t0, unit, rc, txt)\n        return rc, txt\n    _result("zyklus", t0, unit)\n    ok, why = _verify_rtl_hub(root)\n    if not ok:\n        return fertig(3, why)\n    binpath = uhub or _uhubctl_bin()\n    if not binpath:\n        return fertig(7, "uhubctl fehlt (/usr/sbin/uhubctl oder /usr/bin/uhubctl)")\n    try:\n        cmd = _uhubctl_cmd(binpath)\n    except Exception as e:\n        return fertig(2, str(e))\n    try:\n        r = (run or subprocess.run)(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=40)\n    except subprocess.TimeoutExpired:\n        return fertig(4, "uhubctl Zeitueberschreitung nach 40 s")\n    lines = ((r.stdout or "") + "\\n" + (r.stderr or "")).strip().splitlines()\n    tail = (lines[-1] if lines else "")[:120]\n    if getattr(r, "returncode", 1) != 0:\n        return fertig(4, "uhubctl rc %d: %s" % (r.returncode, tail))\n    note = "uhubctl -l 1-1 -p 1 -a cycle -d 5 ok"\n    child = os.path.join(root, CHILD_LOC)\n    waited = 0\n    while not os.path.isdir(child) and waited < 20:\n        sleep(1)\n        waited += 1\n    if not os.path.isdir(child):\n        note += "; Genesys 1-1.1 nach 20 s nicht zurueck"\n    _result("neustart", t0, unit, None, note)\n    sc = next((x for x in SYSTEMCTL if os.path.isfile(x)), None)\n    if sc is None:\n        return fertig(7, note + "; systemctl fehlt")\n    try:\n        r2 = (run or subprocess.run)([sc, "restart", SDR_UNIT], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)\n    except subprocess.TimeoutExpired:\n        return fertig(7, note + "; systemctl restart prepper-sdr Zeitueberschreitung nach 60 s")\n    if getattr(r2, "returncode", 1) != 0:\n        err = ((r2.stderr or r2.stdout) or "").strip().splitlines()\n        return fertig(7, note + "; systemctl restart prepper-sdr rc %d: %s" % (r2.returncode, (err[-1] if err else "")[:80]))\n    return fertig(0, note + "; prepper-sdr neu gestartet")\n\n\ndef hub_cycle(root=SYS, run=None, restart=True, uhub=None):\n'
H_ASYNC_CALL = '    """Nur uhubctl -l 1-1 -p 1 -a cycle -d 5, optional systemctl restart prepper-sdr."""\n    if restart and run is None and uhub is None and root == SYS:\n        rc0, txt0 = hub_cycle_async()\n        if rc0 != 125:\n            return rc0, txt0\n    ok, why = _verify_rtl_hub(root)\n'
H_TEST = '    # usbcycle: Zyklus + Neustart in eigener Einheit, nie im Aufrufer\n    global RESULT, SYSTEMD_RUN\n    old_res, old_sr = RESULT, SYSTEMD_RUN\n    RESULT = os.path.join(t, "usbcycle.json")\n    SYSTEMD_RUN = (sys.executable,)\n    try:\n        sr_ran = []\n        def fake_sr(cmd, **kw):\n            sr_ran.append(list(cmd))\n            return R2()\n        hp = "/usr/local/sbin/prepper-sdr-wdhelper"\n        rc, txt = hub_cycle_async(root, fake_sr, lambda: 1700000000, hp, hp)\n        assert rc == 0 and "eigene Einheit" in txt and len(sr_ran) == 1, (rc, txt, sr_ran)\n        c = sr_ran[0]\n        assert "--no-block" in c and "--collect" in c and c[-2:] == [hp, "hub-cycle-run"] and "restart" not in c and "uhubctl" not in " ".join(c), c\n        assert json.load(open(RESULT))["phase"] == "gestartet"\n        assert hub_cycle_async(root, fake_sr, lambda: 1, hp, "/tmp/anderer-pfad")[0] == 125   # fremder Pfad -> alter Weg\n        class RF(R2):\n            returncode = 1\n            stderr = "boom"\n        assert hub_cycle_async(root, lambda c, **k: RF(), lambda: 1, hp, hp)[0] == 125\n        assert hub_cycle_run(root, fake_uh, lambda s: None, "/usr/sbin/uhubctl", {})[0] == 2   # ausserhalb der Einheit nie\n        cyc = []\n        def fake_cy(cmd, **kw):\n            cyc.append(list(cmd))\n            return R2()\n        env = {"INVOCATION_ID": "x", "USBCYCLE_T0": "1700000000"}\n        rc, txt = hub_cycle_run(root, fake_cy, lambda s: None, "/usr/sbin/uhubctl", env)\n        assert rc == 0 and cyc[0] == ["/usr/sbin/uhubctl", "-l", "1-1", "-p", "1", "-a", "cycle", "-d", "5"] and cyc[1][1:] == ["restart", "prepper-sdr"], (rc, txt, cyc)\n        res = json.load(open(RESULT))\n        assert res["phase"] == "fertig" and res["rc"] == 0 and res["t"] == 1700000000 and "neu gestartet" in res["txt"], res\n        class RE(R2):\n            returncode = 1\n            stdout = ""\n            stderr = "No compatible devices found"\n        cyc2 = []\n        def fake_cy2(cmd, **kw):\n            cyc2.append(list(cmd))\n            return RE()\n        rc, txt = hub_cycle_run(root, fake_cy2, lambda s: None, "/usr/sbin/uhubctl", env)\n        res = json.load(open(RESULT))\n        assert rc == 4 and len(cyc2) == 1 and res["rc"] == 4 and "No compatible" in res["txt"], (rc, txt, cyc2, res)   # kein Neustart bei Fehlschlag\n        assert main(["hub-cycle-run", "x"]) == 2\n    finally:\n        RESULT, SYSTEMD_RUN = old_res, old_sr\n    # falscher Genesys\n'


def helper_neu(text):
    if "def hub_cycle_run(" in text:
        return text
    t = ersetze(text, 'SDR_UNIT = "prepper-sdr"\n', H_CONST, "helper-konstanten")
    t = ersetze(t, "def hub_cycle(root=SYS, run=None, restart=True, uhub=None):\n", H_FUNCS, "helper-funktionen")
    t = ersetze(t, '    """Nur uhubctl -l 1-1 -p 1 -a cycle -d 5, optional systemctl restart prepper-sdr."""\n    ok, why = _verify_rtl_hub(root)\n',
                H_ASYNC_CALL, "helper-hub_cycle")
    t = ersetze(t, "    # falscher Genesys\n", H_TEST, "helper-selbsttest")
    t = ersetze(t, '        or argv == ["hub-cycle"]\n', '        or argv == ["hub-cycle"]\n        or argv == ["hub-cycle-run"]\n', "helper-allowed")
    t = ersetze(t, '    elif argv[0] == "hub-cycle":\n        rc, txt = hub_cycle()\n',
                '    elif argv[0] == "hub-cycle":\n        rc, txt = hub_cycle()\n    elif argv[0] == "hub-cycle-run":\n        rc, txt = hub_cycle_run()\n', "helper-dispatch")
    t = ersetze(t, "hub-port-auth | hub-cycle | selftest", "hub-port-auth | hub-cycle | selftest (intern: hub-cycle-run)", "helper-usage")
    t = ersetze(t, "                     danach systemctl restart prepper-sdr. Nie Port 3 (Eaton-USV), Port 4 (Airspy), nie Hub 2 (Platte).\n",
                "                     danach systemctl restart prepper-sdr. Nie Port 3 (Eaton-USV), Port 4 (Airspy), nie Hub 2 (Platte).\n"
                "                     usbcycle: laeuft als eigene transiente systemd-Einheit (hub-cycle-run, nur dort), Ergebnis /run/prepper-sdr-usbcycle.json\n",
                "helper-doku")
    return t


# ------------------------------------------------------------------ prepper_sdr.py
S_NEW_A = '"rot": False, "rot_why": None, "busy": None}'
S_NEW_B = '"rot": False, "rot_why": None, "busy": None, "cyc": 0}'
S_CLEAN_A = '    o["rot_why"] = str(d.get("rot_why") or "")[:160] or None\n    return o\n'
S_CLEAN_B = '    o["rot_why"] = str(d.get("rot_why") or "")[:160] or None\n    o["cyc"] = int(num(d.get("cyc")) or 0)\n    return o\n'
S_NUDGE1_A = '            did.append("usb-reset %s rc %d" % (names.get(sn, "Stick"), rc))\n'
S_NUDGE1_B = '            did.append("usb-reset %s rc %d%s" % (names.get(sn, "Stick"), rc, (" (%s)" % txt[:60]) if rc else ""))\n'
S_NUDGE2_A = '            did.append("Stufe 0 authorized 1-1.1 rc %d" % rc)\n'
S_NUDGE2_B = '            did.append("Stufe 0 authorized 1-1.1 rc %d%s" % (rc, (" (%s)" % txt[:60]) if rc else ""))\n'
S_CYC_A = '''    rc, txt = _usbw_helper(["hub-cycle"], 90)
    _usbw_log(base, d, now2, "cycle", ("uhubctl nur -l 1-1 -p 1 (nicht USV/Airspy/Hub 2), dann prepper-sdr neu: rc %d %s" % (rc, txt))[:200], "gelb" if rc == 0 else "rot", label)
    return "cycle"
'''
S_CYC_B = '''    rc, txt = _usbw_helper(["hub-cycle"], 90)
    if rc == 0 and "eigene Einheit" in txt:
        # usbcycle: Zyklus + Neustart laufen in einer eigenen systemd-Einheit; das Ergebnis meldet die Wache nach dem Neustart
        _usbw_log(base, d, now2, "cycle", "uhubctl nur -l 1-1 -p 1 (nicht USV/Airspy/Hub 2) + Neustart prepper-sdr in eigener systemd-Einheit gestartet, Ergebnis folgt nach dem Neustart", "gelb", label)
    else:
        _usbw_log(base, d, now2, "cycle", ("uhubctl nur -l 1-1 -p 1 (nicht USV/Airspy/Hub 2), dann prepper-sdr neu: rc %d %s" % (rc, txt))[:200], "gelb" if rc == 0 else "rot", label)
    return "cycle"
'''
S_TICK_A = 'def usbw_tick(base, now=None, root=None):\n'
S_TICK_B = '''USBW_CYC_FILE = "/run/prepper-sdr-usbcycle.json"


def _usbw_cycle_result(base, d, now):
    """usbcycle: Ergebnis des Hub-Zyklus (wdhelper hub-cycle-run, eigene systemd-Einheit) einmal je Lauf ins Ereignis-Log (d['cyc'])."""
    try:
        fn = os.environ.get("USBW_CYC_FILE") or USBW_CYC_FILE
        if not os.path.isfile(fn):
            return
        with open(fn, encoding="utf-8") as fh:
            r = json.load(fh)
        t = int(r.get("t") or 0)
        if not t or t <= int(d.get("cyc") or 0):
            return
        if r.get("phase") == "fertig":
            rc = r.get("rc")
            _usbw_log(base, d, now, "cycle", "Ergebnis Hub-Zyklus + Neustart prepper-sdr: rc %s %s" % (rc, str(r.get("txt") or "")[:140]), "ok" if rc == 0 else "rot", "")
        elif now - t > 300:
            _usbw_log(base, d, now, "cycle", "Hub-Zyklus-Einheit ohne Ergebnis (zuletzt Phase %s)" % str(r.get("phase"))[:20], "rot", "")
        else:
            return
        d["cyc"] = t
        _usbw_save(base, d, now)
    except Exception as ex:
        print("usbwache Zyklus-Ergebnis:", type(ex).__name__, flush=True)


def usbw_tick(base, now=None, root=None):
'''
S_CALL_A = '    with _USBW_LOCK:\n        d = _usbw_state(base, now)\n        '


def sdr_neu(text):
    if "def _usbw_cycle_result(" in text:
        return text
    t = ersetze(text, S_NEW_A, S_NEW_B, "sdr-new")
    t = ersetze(t, S_CLEAN_A, S_CLEAN_B, "sdr-clean")
    t = ersetze(t, S_NUDGE1_A, S_NUDGE1_B, "sdr-nudge1")
    t = ersetze(t, S_NUDGE2_A, S_NUDGE2_B, "sdr-nudge2")
    t = ersetze(t, S_CYC_A, S_CYC_B, "sdr-cycle")
    t = ersetze(t, S_TICK_A, S_TICK_B, "sdr-tick")
    # Aufruf in usbw_tick: direkt nach dem Laden des Zustands
    i = t.index("def usbw_tick(")
    anker = "    with _USBW_LOCK:\n        d = _usbw_state(base, now)\n"
    j = t.index(anker, i)
    t = t[:j + len(anker)] + "        _usbw_cycle_result(base, d, now)\n" + t[j + len(anker):]
    return t


# ------------------------------------------------------------------ Hilfen
def berlin_jetzt():
    return datetime.now(ZoneInfo("Europe/Berlin")) if ZoneInfo else datetime.now()


def sichern(pfad, stempel):
    ziel = "%s.bak-%s-%s" % (pfad, KENNUNG, stempel)
    shutil.copy2(pfad, ziel)
    ordner = os.path.dirname(pfad) or "."
    name = os.path.basename(pfad) + ".bak-" + KENNUNG + "-"
    for p in sorted(x for x in os.listdir(ordner) if x.startswith(name))[:-3]:
        try:
            os.remove(os.path.join(ordner, p))
        except OSError:
            pass
    return ziel


def schreibe(pfad, daten):
    st = os.stat(pfad) if os.path.exists(pfad) else None
    tmp = pfad + ".%s-tmp" % KENNUNG
    with open(tmp, "wb") as fh:
        fh.write(daten)
        fh.flush()
        os.fsync(fh.fileno())
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


def _unit_snap(dienst):
    snap = {"pid": "", "ts": "", "active": ""}
    try:
        r = subprocess.run(["systemctl", "show", dienst, "-p", "MainPID", "-p", "ActiveEnterTimestamp", "-p", "ActiveState"],
                           capture_output=True, text=True, timeout=8)
        for ln in (r.stdout or "").splitlines():
            if "=" in ln:
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


def restart_dienst(dienst):
    before = _unit_snap(dienst)
    try:
        rc = subprocess.call(["systemctl", "restart", dienst])
    except OSError:
        rc = 127
    after = _unit_snap(dienst)
    if rc == 0 and after.get("active") in ("active", "activating", "reloading") and not (
            before.get("pid") and after.get("pid") == before["pid"] and before["pid"] != "0" and before.get("ts") == after.get("ts")):
        print("restart %s rc %s" % (dienst, rc))
        return 0
    print("STOP Neustart %s fehlgeschlagen (rc %s) - bitte sudo systemctl restart %s" % (dienst, rc, dienst))
    return rc if rc != 0 else 1


def _get(pfad, timeout=6):
    ziel = tempfile.mktemp(prefix="apply-" + KENNUNG + "-")
    try:
        r = subprocess.run(["curl", "-sS", "-m", str(timeout), "-o", ziel, "-w", "%{http_code}", URL + pfad], capture_output=True, text=True, timeout=timeout + 3)
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


def run(cmd, timeout=30, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, env=env)


def visudo_ok():
    if not os.path.isfile(SUDOERS):
        print("STOP sudoers %s fehlt - der Helfer ist so nicht installiert" % SUDOERS)
        return False
    txt = open(SUDOERS, encoding="utf-8", errors="replace").read()
    if "prepper-sdr-wdhelper hub-cycle" not in txt:
        print("STOP sudoers erlaubt hub-cycle nicht (Paket usbwache fehlt?)")
        return False
    try:
        r = run(["visudo", "-c"], 20)
    except (OSError, subprocess.TimeoutExpired):
        print("Hinweis: visudo nicht verfuegbar, sudoers-Syntax nicht geprueft")
        return True
    if r.returncode != 0:
        print("STOP visudo -c: %s" % ((r.stderr or r.stdout) or "")[:300])
        return False
    print("visudo -c ok (sudoers unveraendert, hub-cycle bereits erlaubt)")
    return True


def pyflakes_msgs(pfad):
    try:
        r = subprocess.run([sys.executable, "-m", "pyflakes", pfad], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if "No module named pyflakes" in (r.stderr or ""):
        return None
    return sorted(set(ln.split(":", 2)[-1].strip() for ln in (r.stdout or "").splitlines()))


# ------------------------------------------------------------------ Selbsttest
def selbsttest(helper_alt, sdr_alt, basis=BASIS):
    th = helper_neu(helper_alt)
    ts = sdr_neu(sdr_alt)
    assert helper_neu(th) == th and sdr_neu(ts) == ts, "nicht idempotent"
    ast.parse(th)
    ast.parse(ts)
    assert "--no-block" in th and "hub-cycle-run" in th and 'argv == ["hub-cycle-run"]' in th
    for verboten in ("-p 3", '"-p", "3"', '"-p", "4"', "-l 2-1"):
        assert verboten not in th.split("def hub_cycle_async")[1].split("def hub_cycle(")[0], verboten
    tmp = tempfile.mkdtemp(prefix="usbcycle-st-")
    try:
        hp = os.path.join(tmp, "helper.py")
        open(hp, "w", encoding="utf-8").write(th)
        r = run([sys.executable, hp, "selftest"], 60)
        assert r.returncode == 0 and "wdhelper selftest ok" in r.stdout, (r.returncode, r.stdout[-300:], r.stderr[-600:])
        sp = os.path.join(tmp, "prepper_sdr.py")
        open(sp, "w", encoding="utf-8").write(ts)
        code = r'''
import importlib.util, json, os, sys, time
sys.path.insert(0, %r)
sys.argv = ["x", "status"]
spec = importlib.util.spec_from_file_location("prepper_sdr", %r)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.selftest_usbwache()
tmp = %r
fn = os.path.join(tmp, "cyc.json"); os.environ["USBW_CYC_FILE"] = fn
m.USBW_FILE = "usbwache.json"
base = tmp
os.makedirs(base, exist_ok=True)
d = m._usbw_clean({"cyc": 5, "events": []}); assert d["cyc"] == 5 and m._usbw_new()["cyc"] == 0
now = time.time()
m._usbw_cycle_result(base, d, now); assert not d["events"]                       # keine Datei
json.dump({"t": int(now) - 10, "phase": "zyklus", "rc": None, "txt": ""}, open(fn, "w")); d["cyc"] = 0
m._usbw_cycle_result(base, d, now); assert not d["events"] and d["cyc"] == 0     # laeuft noch
json.dump({"t": int(now) - 10, "phase": "fertig", "rc": 0, "txt": "uhubctl ok; prepper-sdr neu gestartet"}, open(fn, "w"))
m._usbw_cycle_result(base, d, now); assert d["events"][-1]["lvl"] == "ok" and "Ergebnis Hub-Zyklus" in d["events"][-1]["txt"] and d["cyc"] == int(now) - 10
n = len(d["events"]); m._usbw_cycle_result(base, d, now); assert len(d["events"]) == n   # nur einmal
json.dump({"t": int(now) - 5, "phase": "fertig", "rc": 4, "txt": "uhubctl rc 1: x"}, open(fn, "w"))
m._usbw_cycle_result(base, d, now); assert d["events"][-1]["lvl"] == "rot" and d["cyc"] == int(now) - 5
json.dump({"t": int(now) - 1, "phase": "neustart", "rc": None, "txt": ""}, open(fn, "w"))
m._usbw_cycle_result(base, d, now + 400); assert d["events"][-1]["lvl"] == "rot" and "ohne Ergebnis" in d["events"][-1]["txt"]
print("usbcycle sdr ok")
''' % (basis, sp, tmp)
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=240, cwd=tmp,
                           env=dict(os.environ, HOME=tmp))
        assert r.returncode == 0 and "usbcycle sdr ok" in r.stdout, (r.returncode, r.stdout[-400:], r.stderr[-900:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("Selbsttest ok (Helfer-Selbsttest inkl. neuer Faelle, prepper_sdr-Selbsttest usbwache + Ergebnisleser, idempotent)")


# ------------------------------------------------------------------ Live-Checks
def live_checks(seit):
    ok = True
    r = run([HELPER, "check"], 20)
    if r.returncode != 0:
        print("STOP helper check rc %d" % r.returncode)
        ok = False
    env = {k: v for k, v in os.environ.items() if k != "INVOCATION_ID"}
    r = run([HELPER, "hub-cycle-run"], 20, env)
    if r.returncode != 2:
        print("STOP hub-cycle-run ausserhalb der Einheit muss rc 2 liefern, war %d (%s)" % (r.returncode, (r.stdout or r.stderr).strip()[:100]))
        ok = False
    else:
        print("hub-cycle-run ausserhalb der Einheit: rc 2 (richtig, es wurde nichts am USB gemacht)")
    unit = "prepper-sdr-usbcycle-test-%d" % int(time.time())
    r = run(["systemd-run", "--no-block", "--collect", "--quiet", "--unit", unit, "/bin/true"], 20)
    if r.returncode != 0:
        print("STOP systemd-run (transiente Einheit) rc %d: %s" % (r.returncode, (r.stderr or r.stdout).strip()[:120]))
        ok = False
    else:
        print("systemd-run transiente Testeinheit (/bin/true) ok")
    return ok


def live_nach_neustart(seit):
    ok = True
    t0 = time.time()
    while time.time() - t0 < 45:
        if _unit_snap("prepper-sdr").get("active") == "active":
            break
        time.sleep(2)
    else:
        print("STOP prepper-sdr nicht active")
        return False
    t0 = time.time()
    code, body = "000", ""
    while time.time() - t0 < 45:
        code, body = _get("/api/sdr/usbw")
        if code == "200":
            break
        time.sleep(2)
    try:
        j = json.loads(body)
        assert "rows" in j and "events" in j
        print("GET /api/sdr/usbw -> 200, on=%s, live=%s, Eingriffe/h %s" % (j.get("on"), j.get("live"), j.get("n_h")))
    except Exception:
        print("STOP /api/sdr/usbw (%s) nicht lesbar" % code)
        ok = False
    time.sleep(8)
    r = run(["journalctl", "-u", "prepper-sdr", "--since", seit, "-o", "cat", "-n", "800"], 25)
    zeilen = (r.stdout or "").splitlines()
    for bad in ("Traceback", "usbwache Start:", "usbwache: "):
        hit = [z for z in zeilen if bad in z]
        if hit:
            print("STOP Journal prepper-sdr enthaelt %r: %s" % (bad, hit[0][:160]))
            ok = False
    if not any(z.startswith("usbwache AN") or z.startswith("usbwache AUS") for z in zeilen):
        print("STOP Journal prepper-sdr: keine Zeile 'usbwache AN/AUS' seit dem Neustart")
        ok = False
    else:
        print("Journal prepper-sdr: usbwache gestartet, keine Traceback/Fehlerzeile")
    return ok


# ------------------------------------------------------------------ Ablauf
def anwenden(a):
    basis = a.basis
    sdr_pfad = os.path.join(basis, "prepper_sdr.py")
    helper_pfad = a.helper
    for pfad in (sdr_pfad, helper_pfad):
        if not os.path.isfile(pfad):
            print("STOP %s fehlt" % pfad)
            return 2
    sdr_alt = open(sdr_pfad, "rb").read()
    helper_alt = open(helper_pfad, "rb").read()
    sdr_s, helper_s = stand(sdr_alt), stand(helper_alt)
    sdr_schon = b"def _usbw_cycle_result(" in sdr_alt
    helper_schon = b"def hub_cycle_run(" in helper_alt
    if not sdr_schon and sdr_s != SDR_SOLL:
        print("STOP prepper_sdr.py weicht ab: %s %d (erwartet %s %d)" % (sdr_s + SDR_SOLL))
        return 2
    if not helper_schon and helper_s != HELPER_SOLL:
        print("STOP wdhelper weicht ab: %s %d (erwartet %s %d)" % (helper_s + HELPER_SOLL))
        return 2
    print("Basis ok: prepper_sdr.py %s %d%s | wdhelper %s %d%s" % (sdr_s[0][:8], sdr_s[1], " (schon neu)" if sdr_schon else "",
                                                                helper_s[0][:8], helper_s[1], " (schon neu)" if helper_schon else ""))
    try:
        sdr_neu_t = sdr_neu(sdr_alt.decode("utf-8"))
        helper_neu_t = helper_neu(helper_alt.decode("utf-8"))
        selbsttest(helper_alt.decode("utf-8"), sdr_alt.decode("utf-8"), basis)
    except (Stop, AssertionError, SyntaxError) as exc:
        print("STOP %s" % exc)
        return 3
    if sdr_schon and helper_schon:
        print("Schon angewendet, nichts zu tun.")
        return 0
    sdr_b, helper_b = sdr_neu_t.encode("utf-8"), helper_neu_t.encode("utf-8")
    print("prepper_sdr.py neu: %s %d | wdhelper neu: %s %d" % (stand(sdr_b)[0][:12], len(sdr_b), stand(helper_b)[0][:12], len(helper_b)))
    p0, p1 = None, None
    tmp = tempfile.mkdtemp(prefix="usbcycle-pf-")
    try:
        np = os.path.join(tmp, "prepper_sdr.py")
        open(np, "wb").write(sdr_b)
        alt_msgs, neu_msgs = pyflakes_msgs(sdr_pfad), pyflakes_msgs(np)
        if alt_msgs is not None and neu_msgs is not None:
            neu_nur = [m for m in neu_msgs if m not in alt_msgs]
            if neu_nur:
                print("STOP pyflakes: neue Meldungen: %s" % neu_nur[:5])
                return 3
            print("pyflakes: keine neuen Meldungen")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if a.dry_run:
        print("Trockenlauf: nichts geschrieben.")
        return 0
    if os.geteuid() != 0:
        print("STOP bitte als root: sudo python3 apply-usbcycle.py")
        return 2
    if not visudo_ok():
        return 2
    if not any(os.path.isfile(x) for x in ("/usr/bin/systemd-run", "/bin/systemd-run")):
        print("STOP systemd-run fehlt - ohne wuerde der Fix nicht greifen, nichts geaendert")
        return 2
    if not any(os.path.isfile(x) for x in ("/usr/sbin/uhubctl", "/usr/bin/uhubctl")):
        print("STOP uhubctl fehlt, nichts geaendert")
        return 2
    stempel = berlin_jetzt().strftime("%Y%m%d-%H%M%S")
    bak_h = sichern(helper_pfad, stempel)
    bak_s = sichern(sdr_pfad, stempel)
    print("Sicherungen: %s | %s" % (bak_h, bak_s))
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    def rueckbau(grund):
        print("Rueckbau: %s" % grund)
        try:
            schreibe(helper_pfad, open(bak_h, "rb").read())
            schreibe(sdr_pfad, open(bak_s, "rb").read())
            if not a.kein_neustart:
                restart_dienst("prepper-sdr")
            print("Rueckbau fertig (wdhelper und prepper_sdr.py wie vorher)")
        except Exception as exc:
            print("Rueckbau-Fehler: %s - bitte %s und %s zurueckkopieren" % (exc, bak_h, bak_s))
    try:
        schreibe(helper_pfad, helper_b)
        if stand(open(helper_pfad, "rb").read()) != stand(helper_b):
            raise Stop("Helfer nach dem Schreiben anders")
        schreibe(sdr_pfad, sdr_b)
        if stand(open(sdr_pfad, "rb").read()) != stand(sdr_b):
            raise Stop("prepper_sdr.py nach dem Schreiben anders")
        compile(sdr_b, sdr_pfad, "exec")
    except Exception as exc:
        rueckbau("Schreiben/Pruefen fehlgeschlagen: %s" % exc)
        return 4
    print("Dateien geschrieben (nur Helfer + prepper_sdr.py, sudoers unveraendert)")
    if not live_checks(seit):
        rueckbau("Live-Check vor Neustart")
        return 5
    if a.kein_neustart:
        print("--kein-neustart: prepper-sdr laeuft noch mit altem Code. Spaeter: sudo systemctl restart prepper-sdr")
        return 0
    if restart_dienst("prepper-sdr") != 0:
        rueckbau("Neustart prepper-sdr")
        return 5
    if not live_nach_neustart(seit):
        rueckbau("Live-Check nach Neustart")
        return 5
    print("ok: Hub-Zyklus laeuft jetzt in eigener Einheit; USB-Hardware wurde NICHT angefasst (kein Zyklus ausgeloest)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--kein-neustart", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--basis", default=BASIS)
    ap.add_argument("--helper", default=HELPER)
    a = ap.parse_args()
    if a.selftest:
        try:
            selbsttest(open(a.helper, encoding="utf-8").read(), open(os.path.join(a.basis, "prepper_sdr.py"), encoding="utf-8").read(), a.basis)
        except Stop as exc:
            print(exc)
            return 3
        return 0
    return anwenden(a)


if __name__ == "__main__":
    sys.exit(main())
