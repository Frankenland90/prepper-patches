#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-usbwache: USB-Wache fuer fehlende RTL-Sticks (sysfs > 60 s).

Wenn ein bekannter RTL-Stick laenger als usbw_missing_s (60) in /sys fehlt:
Stufe 0 authorized-Toggle nur am Genesys 1-1.1 (05e3:0610), danach
`uhubctl -l 1-1 -p 1 -a cycle -d 5` (nur Port 1 des VIA-Haupt-Hubs) und
Neustart von prepper-sdr. Nie Port 3 (Eaton-USV), Port 4 (Airspy), nie Hub 2
(52Pi-Platte). Hoechstens usbw_max_per_h (4) Eingriffe pro Stunde, danach roter
Hinweis und Ereignisliste auf /system und /pi. Die Lage bleibt unberuehrt
(kein AUFFAELLIG, kein Blinken).

Umsetzung: Erweiterung von /usr/local/sbin/prepper-sdr-wdhelper (harter Pfad,
nur erlaubte Argumente) und sudoers zz-prepper-sdr-wd. Eigener Faden in
prepper_sdr, damit der Planer/die Telemetrie nicht blockiert. Konfiguration in
sdr_config.json (usbw_enable, usbw_missing_s, usbw_max_per_h).

Muster wie lageohnesdr: Hash-Waechter, --dry-run/--kein-neustart/--selftest,
Backup, atomar, Besitzer/Modus erhalten, ehrlicher systemctl-Check, 45 s auf
HTTP 200. Keine Zeitfenster-Sperre (am 28.11. abgeschafft). Selbsttest ohne
echten Cycle. Nichts wird hier auf den Pi geschrieben.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import threading
import time
import zlib
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "usbwache"
BASIS = "/home/fmg/prepper-dashboard"
DIENSTE_SDR = "prepper-sdr"
DIENSTE_DASH = "prepper-dashboard"
HELPER_DST = "/usr/local/sbin/prepper-sdr-wdhelper"
SUDOERS_DST = "/etc/sudoers.d/zz-prepper-sdr-wd"

SDR_START_SHA = "9ac15b0981b91f80236ce847c7a77fc081877a786f01e7c99422a1b8e13e0e30"
SDR_START_SHA16 = "9ac15b0981b91f80"
SDR_START_BYTES = 806307
DASH_START_SHA = "c9bd7612a06dc290f91a4e826b16ab3b944a87a0ab51407be67bcc5e7e121af7"
DASH_START_SHA16 = "c9bd7612a06dc290"
DASH_START_BYTES = 1401463
SDR_END_SHA = "0d3fc5b4eacd0bbc3c6e0a9c42744894dfb29efc6f87163e869a0f6fee3b8f9a"
SDR_END_SHA16 = "0d3fc5b4eacd0bbc"
SDR_END_BYTES = 825150
DASH_END_SHA = "209d1b995497831acf69b7489350f2c7cb561be0a58fe1c7403fbffc94478730"
DASH_END_SHA16 = "209d1b995497831a"
DASH_END_BYTES = 1408116
HELPER_SHA = "c40c5a62bfb8294d608ff46d1843867bdb8ab2834058cc7b8ea964823d83170a"
HELPER_SHA16 = "c40c5a62bfb8294d"
HELPER_BYTES = 19096

SDR_ANCHOR = 'if __name__ == "__main__":\n    a = sys.argv[1] if len(sys.argv) > 1 else "status"\n'

HELPER_BLOB = (
    "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"
)

SDR_BLOB = (
    "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"
)

DASH_BLOB = (
    "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"
)

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


def unpack(blob):
    return zlib.decompress(base64.b64decode("".join(blob) if not isinstance(blob, str) else blob))


def helper_bytes():
    return unpack(HELPER_BLOB)


def sdr_block():
    return unpack(SDR_BLOB).decode("utf-8")


def dash_block():
    return unpack(DASH_BLOB).decode("utf-8")


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


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


def schreibe(pfad, daten, uidgid=None, mode=None):
    """Atomic ersetzen; Besitzer/Modus der Originaldatei behalten (oder uidgid/mode)."""
    st = os.stat(pfad) if os.path.exists(pfad) else None
    tmp = pfad + ".%s-tmp" % KENNUNG
    os.makedirs(os.path.dirname(pfad) or ".", exist_ok=True)
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
    if mode is not None:
        os.chmod(tmp, mode)
    if uidgid is not None:
        try:
            os.chown(tmp, uidgid[0], uidgid[1])
        except OSError:
            pass
    os.replace(tmp, pfad)
    if st is not None and uidgid is None:
        try:
            os.chown(pfad, st.st_uid, st.st_gid)
            os.chmod(pfad, stat.S_IMODE(st.st_mode))
        except OSError as exc:
            print("Hinweis: Besitzer/Modus %s nicht gesetzt (%s)" % (pfad, exc))
    elif uidgid is not None or mode is not None:
        try:
            if uidgid is not None:
                os.chown(pfad, uidgid[0], uidgid[1])
            if mode is not None:
                os.chmod(pfad, mode)
        except OSError as exc:
            print("Hinweis: Besitzer/Modus %s nicht gesetzt (%s)" % (pfad, exc))


def pyflakes_datei(pfad):
    for cmd in (["pyflakes", pfad], ["python3", "-m", "pyflakes", pfad]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except OSError:
            continue
        if r.returncode == 0 and not (r.stdout or "").strip() and not (r.stderr or "").strip():
            print("pyflakes %s ok" % os.path.basename(pfad))
            return True
        err = (r.stderr or "") + (r.stdout or "")
        if "No module named" in err or "command not found" in err:
            continue
        print("pyflakes %s:\n%s" % (os.path.basename(pfad), err.strip()[:800]))
        return False
    print("Hinweis: pyflakes nicht installiert, nur py_compile")
    return True


def schon_sdr(text):
    return "# ===== usbwache:" in text and "def usbw_tick(" in text and "Planner.loop = _usbw_loop" in text


def schon_dash(text):
    return 'id="usbwBox"' in text and "def _usbw_after(" in text and "Lage bleibt unberührt" in text


def patch_sdr(text):
    if schon_sdr(text):
        return text
    return ersetze(text, SDR_ANCHOR, sdr_block() + "\n" + SDR_ANCHOR, "prepper_sdr.py", 1)


def patch_dash(text):
    if schon_dash(text):
        return text
    if not text.endswith("\n"):
        text += "\n"
    return text + "\n" + dash_block()


def berechne_sdr(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == SDR_END_SHA and n == SDR_END_BYTES:
        return alt, None, None
    text = alt.decode("utf-8")
    if schon_sdr(text):
        return alt, None, None
    if hashcheck and not (ist == SDR_START_SHA and n == SDR_START_BYTES):
        return None, None, "STOP prepper_sdr.py Hash %s/%d, erwartet %s/%d oder Endstand %s/%d" % (
            ist[:16], n, SDR_START_SHA16, SDR_START_BYTES, SDR_END_SHA16, SDR_END_BYTES)
    neu = patch_sdr(text).encode("utf-8")
    hs, ns = stand(neu)
    if hashcheck and (hs != SDR_END_SHA or ns != SDR_END_BYTES):
        return None, None, "STOP prepper_sdr.py Endhash %s/%d, erwartet %s/%d" % (hs[:16], ns, SDR_END_SHA16, SDR_END_BYTES)
    if not schon_sdr(neu.decode("utf-8")):
        return None, None, "STOP prepper_sdr.py Markierungen unvollstaendig"
    return alt, neu, None


def berechne_dash(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == DASH_END_SHA and n == DASH_END_BYTES:
        return alt, None, None
    text = alt.decode("utf-8")
    if schon_dash(text):
        return alt, None, None
    if hashcheck and not (ist == DASH_START_SHA and n == DASH_START_BYTES):
        return None, None, "STOP dashboard.py Hash %s/%d, erwartet %s/%d oder Endstand %s/%d" % (
            ist[:16], n, DASH_START_SHA16, DASH_START_BYTES, DASH_END_SHA16, DASH_END_BYTES)
    neu = patch_dash(text).encode("utf-8")
    hs, ns = stand(neu)
    if hashcheck and (hs != DASH_END_SHA or ns != DASH_END_BYTES):
        return None, None, "STOP dashboard.py Endhash %s/%d, erwartet %s/%d" % (hs[:16], ns, DASH_END_SHA16, DASH_END_BYTES)
    if not schon_dash(neu.decode("utf-8")):
        return None, None, "STOP dashboard.py Markierungen unvollstaendig"
    return alt, neu, None


def sdr_user():
    try:
        r = subprocess.run(["systemctl", "show", "-p", "User", "--value", "prepper-sdr"],
                           capture_output=True, text=True, timeout=5)
        u = (r.stdout or "").strip() or "fmg"
    except Exception:
        u = "fmg"
    if not re.match(r"^[a-z_][a-z0-9_-]*$", u):
        u = "fmg"
    if u == "root":
        return "root"
    return u


def sudoers_text(user):
    hx = "[0-9A-F]"
    hx16 = hx * 16
    h = HELPER_DST
    return ("%s ALL=(root) NOPASSWD: %s check, %s usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], "
            "%s usb-reset-air %s, %s reboot, %s hub-port-auth, %s hub-cycle\n" % (user, h, h, h, hx16, h, h, h))


def visudo_ok(text):
    tmp = tempfile.NamedTemporaryFile("w", delete=False, prefix="zz-usbw-", suffix="")
    try:
        tmp.write(text)
        tmp.flush()
        tmp.close()
        os.chmod(tmp.name, 0o440)
        r = subprocess.run(["visudo", "-c", "-f", tmp.name], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            print("STOP visudo: %s" % ((r.stderr or r.stdout) or "")[:300])
            return False
        return True
    except OSError:
        print("Hinweis: visudo nicht verfuegbar, sudoers-Syntax nicht geprueft")
        return True
    finally:
        try:
            os.remove(tmp.name)
        except OSError:
            pass


def config_neu(pfad):
    """usbw-Schluessel ergaenzen, bestehende Werte nicht ueberschreiben."""
    if not os.path.isfile(pfad):
        return None, None, "Hinweis: sdr_config.json fehlt, Schluessel werden nicht gesetzt"
    try:
        d = json.load(open(pfad, encoding="utf-8"))
    except Exception as e:
        return None, None, "STOP sdr_config.json unlesbar: %s" % e
    if not isinstance(d, dict):
        return None, None, "STOP sdr_config.json kein Objekt"
    alt = json.dumps(d, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    changed = False
    for k, v in (("usbw_enable", True), ("usbw_missing_s", 60), ("usbw_max_per_h", 4)):
        if k not in d:
            d[k] = v
            changed = True
    if not changed:
        return alt.encode("utf-8"), None, None
    neu = (json.dumps(d, ensure_ascii=False, indent=2, sort_keys=False) + "\n").encode("utf-8")
    return alt.encode("utf-8"), neu, None


def _unit_snap(dienst):
    snap = {"pid": "", "ts": "", "active": ""}
    try:
        r = subprocess.run(
            ["systemctl", "show", dienst, "-p", "MainPID", "-p", "ActiveEnterTimestamp", "-p", "ActiveState"],
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


def _run_restart(cmd):
    try:
        return subprocess.call(cmd)
    except OSError:
        return 127


def restart_dienst(dienst):
    before = _unit_snap(dienst)
    rc = _run_restart(["systemctl", "restart", dienst])
    after = _unit_snap(dienst)
    if _restart_ok(rc, before, after):
        print("restart %s rc %s" % (dienst, rc))
        return 0
    rc2 = _run_restart(["sudo", "systemctl", "restart", dienst])
    after = _unit_snap(dienst)
    if _restart_ok(rc2, before, after):
        print("restart %s rc %s (sudo)" % (dienst, rc2))
        return 0
    gesehen = rc2 if rc2 != 0 else rc
    print("STOP Neustart fehlgeschlagen – bitte sudo systemctl restart %s" % dienst)
    print("systemctl rc %s, Zustand %s PID %s -> %s" % (
        gesehen, after.get("active") or "?", before.get("pid") or "-", after.get("pid") or "-"))
    return gesehen if gesehen != 0 else 1


def neustart(dienste):
    rc_all = 0
    for dienst in dienste:
        rc = restart_dienst(dienst)
        if rc != 0:
            rc_all = rc
    return rc_all


def warte_http(urls, timeout=45):
    t0 = time.time()
    offen = list(urls)
    letzte = {}
    while offen and (time.time() - t0) < timeout:
        noch = []
        for url, ziel in offen:
            try:
                r = subprocess.run(
                    ["curl", "-sS", "-m", "5", "-o", ziel, "-w", "%{http_code}", url],
                    capture_output=True, text=True, timeout=8)
                code = (r.stdout or "").strip()
                letzte[url] = code
                if r.returncode == 0 and code.startswith("200"):
                    print("GET %s -> 200 nach %.1f s" % (url, time.time() - t0))
                    continue
            except (OSError, subprocess.TimeoutExpired) as exc:
                letzte[url] = type(exc).__name__
            noch.append((url, ziel))
        offen = noch
        if offen:
            time.sleep(2)
    ok = True
    for url, ziel in offen:
        print("STOP %s nicht 200 innerhalb %s s (zuletzt %s)" % (url, timeout, letzte.get(url)))
        ok = False
    return ok


def journal_pruefen(seit, dienste, pause=0):
    if pause:
        print("warte %s s auf Journal" % pause)
        time.sleep(pause)
    ok = True
    urls = [
        ("http://127.0.0.1:5000/pi", "/tmp/apply-usbwache-pi.html"),
        ("http://127.0.0.1:5000/system", "/tmp/apply-usbwache-system.html"),
    ]
    if DIENSTE_DASH in dienste or not dienste:
        if not warte_http(urls, timeout=45):
            ok = False
    for dienst in dienste:
        try:
            r = subprocess.run(
                ["journalctl", "-u", dienst, "--since", seit, "-o", "cat", "-n", "80"],
                capture_output=True, text=True, timeout=10)
            zeilen = (r.stdout or "").splitlines()
        except (OSError, subprocess.TimeoutExpired):
            print("Hinweis: Journal %s unlesbar" % dienst)
            continue
        if any("Traceback" in ln for ln in zeilen):
            print("STOP Journal %s enthaelt Traceback" % dienst)
            for ln in [x for x in zeilen if "Traceback" in x][:8]:
                print(ln)
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (dienst, len(zeilen)))
    for html_p, mark in (("/tmp/apply-usbwache-pi.html", "pi"), ("/tmp/apply-usbwache-system.html", "system")):
        if os.path.isfile(html_p):
            html = open(html_p, encoding="utf-8", errors="replace").read()
            if html and 'id="usbwBox"' not in html:
                print("Hinweis: /%s ohne USB-Wache-Kachel (Seite evtl. noch ohne after_request)" % mark)
            elif html:
                print("USB-Wache-Kachel auf /%s vorhanden" % mark)
    return ok


def anwenden(root, dry, kein, hashcheck=True, pause=0, sys_install=None):
    if sys_install is None:
        sys_install = os.path.abspath(os.path.expanduser(root)) == os.path.abspath(BASIS)
    sdr = os.path.join(root, "prepper_sdr.py")
    dash = os.path.join(root, "dashboard.py")
    cfg = os.path.join(root, "sdr_config.json")
    paare = []
    dienste = []
    alt_s, neu_s, err = berechne_sdr(sdr, hashcheck=hashcheck)
    if err:
        print(err)
        return 2
    if neu_s is not None:
        paare.append((sdr, alt_s, neu_s, "prepper_sdr.py", None, None))
        dienste.append(DIENSTE_SDR)
    else:
        print("prepper_sdr.py bereits auf Endstand, unveraendert")
    alt_d, neu_d, err = berechne_dash(dash, hashcheck=hashcheck)
    if err:
        print(err)
        return 2
    if neu_d is not None:
        paare.append((dash, alt_d, neu_d, "dashboard.py", None, None))
        if DIENSTE_DASH not in dienste:
            dienste.append(DIENSTE_DASH)
    else:
        print("dashboard.py bereits auf Endstand, unveraendert")
    hb = helper_bytes()
    if sha256(hb) != HELPER_SHA:
        print("STOP interner Helfer-Hash")
        return 2
    helper_neu = False
    sudo_neu = False
    user = sdr_user()
    sudo = sudoers_text(user)
    if not sys_install:
        print("Hinweis: Hilfsprogramm/sudoers nur bei Basis %s (kein Systemeingriff in diesem Lauf)" % BASIS)
    else:
        helper_neu = True
        if os.path.isfile(HELPER_DST) and sha256(open(HELPER_DST, "rb").read()) == HELPER_SHA:
            helper_neu = False
            print("Hilfsprogramm bereits auf Endstand, unveraendert")
        sudo_neu = True
        if os.path.isfile(SUDOERS_DST):
            cur = open(SUDOERS_DST, encoding="utf-8", errors="replace").read()
            if "hub-cycle" in cur and "hub-port-auth" in cur and HELPER_DST in cur:
                sudo_neu = False
                print("sudoers bereits mit hub-cycle, unveraendert")
    alt_c, neu_c, cerr = config_neu(cfg)
    if cerr and cerr.startswith("STOP"):
        print(cerr)
        return 2
    if cerr:
        print(cerr)
    if dry:
        for fn, alt, neu, name, _u, _m in paare:
            print("dry-run %s %d -> %d Bytes sha256 %s" % (name, len(alt), len(neu), sha256(neu)))
        if helper_neu:
            print("dry-run Hilfsprogramm %s (%d Bytes, kein echter Cycle)" % (HELPER_DST, len(hb)))
        if sudo_neu:
            print("dry-run sudoers %s (Benutzer %s)" % (SUDOERS_DST, user))
        if neu_c is not None:
            print("dry-run sdr_config.json: usbw_enable/usbw_missing_s/usbw_max_per_h ergaenzen")
        print("dry-run: keine Datei geschrieben, kein Neustart, kein uhubctl-Cycle")
        return 0
    if helper_neu or sudo_neu:
        if os.geteuid() != 0:
            print("STOP Hilfsprogramm/sudoers brauchen root – bitte sudo python3 apply-usbwache.py")
            return 2
    if helper_neu or sudo_neu or neu_c is not None:
        if helper_neu and DIENSTE_SDR not in dienste:
            dienste.append(DIENSTE_SDR)
        if neu_c is not None and DIENSTE_SDR not in dienste:
            dienste.append(DIENSTE_SDR)
    if not paare and not helper_neu and not sudo_neu and neu_c is None:
        print("nichts zu tun")
        return 0
    if sudo_neu and not visudo_ok(sudo):
        return 2
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    for fn, alt, neu, name, uidgid, mode in paare:
        bak = sichern(fn, stempel)
        print("Backup %s" % bak)
        schreibe(fn, neu)
        hs, ns = stand(open(fn, "rb").read())
        print("geschrieben %s sha256 %s bytes %d" % (name, hs, ns))
        compile(neu, name, "exec")
        if not pyflakes_datei(fn):
            print("STOP pyflakes %s" % name)
            return 4
    if neu_c is not None:
        bak = sichern(cfg, stempel)
        print("Backup %s" % bak)
        schreibe(cfg, neu_c)
        print("sdr_config.json: usbw-Schluessel ergaenzt")
    if helper_neu:
        if os.path.isfile(HELPER_DST):
            bak = sichern(HELPER_DST, stempel)
            print("Backup %s" % bak)
        schreibe(HELPER_DST, hb, uidgid=(0, 0) if os.geteuid() == 0 else None, mode=0o755)
        print("geschrieben %s sha256 %s bytes %d" % (HELPER_DST, sha256(hb), len(hb)))
        r = subprocess.run([HELPER_DST, "selftest"], capture_output=True, text=True, timeout=30, env=dict(os.environ, WDH_QUIET="1"))
        if r.returncode != 0:
            print("STOP Helfer-selftest rc %s: %s" % (r.returncode, (r.stderr or r.stdout)[-400:]))
            return 4
        print((r.stdout or "").strip().splitlines()[-1] if r.stdout else "Helfer selftest ok")
    if sudo_neu:
        if os.path.isfile(SUDOERS_DST):
            bak = sichern(SUDOERS_DST, stempel)
            print("Backup %s" % bak)
        schreibe(SUDOERS_DST, sudo.encode("utf-8"), uidgid=(0, 0) if os.geteuid() == 0 else None, mode=0o440)
        if not visudo_ok(open(SUDOERS_DST, encoding="utf-8").read()):
            print("STOP sudoers nach dem Schreiben ungueltig")
            return 4
        print("sudoers %s geschrieben (Benutzer %s)" % (SUDOERS_DST, user))
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = neustart(dienste or [DIENSTE_SDR, DIENSTE_DASH])
    if rc != 0:
        return rc
    if not journal_pruefen(seit, dienste or [DIENSTE_SDR, DIENSTE_DASH], pause=pause):
        return 5
    print("ok, Dienste: %s" % ", ".join(dienste or [DIENSTE_SDR, DIENSTE_DASH]))
    return 0


def _selftest_restart_check():
    assert _restart_ok(1, {"pid": "1", "ts": "a", "active": "active"}, {"pid": "2", "ts": "b", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"},
                       {"pid": "10", "ts": "A", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"},
                       {"pid": "11", "ts": "B", "active": "active"}) is True
    print("selftest Neustart-Check ok")


def _selftest_helper():
    raw = helper_bytes()
    assert sha256(raw) == HELPER_SHA and len(raw) == HELPER_BYTES
    tmp = tempfile.NamedTemporaryFile("wb", delete=False, prefix="usbw-hl-")
    tmp.write(raw)
    tmp.close()
    os.chmod(tmp.name, 0o755)
    r = subprocess.run(["python3", tmp.name, "selftest"], capture_output=True, text=True, timeout=30, env=dict(os.environ, WDH_QUIET="1"))
    os.remove(tmp.name)
    if r.returncode != 0:
        raise SystemExit("selftest Helfer rc %s: %s" % (r.returncode, (r.stderr or r.stdout)[-400:]))
    out = r.stdout or ""
    assert "uhubctl -l 1-1 -p 1" in out or "usbwache" in out or "selftest ok" in out, out[-400:]
    print("selftest Helfer ok (kein echter Cycle)")


def _selftest_sdr_block():
    import json as _j, os as _o, re as _re, subprocess as _sp, tempfile as _tf, threading as _th, time as _tm
    DEFAULT_CFG = {"serial": "11111111", "serial2": None, "devs_on": False, "devs": []}
    SERIAL_RE = _re.compile(r"^[0-9]{1,16}$")
    WD_SN_RE = _re.compile(r"^[0-9]{8}$")
    WD_HELPER = HELPER_DST

    def p(name, base=None):
        return _o.path.join(base or "/tmp", name)

    def write_json(path, obj):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = path + ".tmp"
        open(tmp, "w").write(_j.dumps(obj))
        os.replace(tmp, path)

    def load_json(path, default=None):
        try:
            return _j.load(open(path, encoding="utf-8"))
        except Exception:
            return default

    def config(base=None):
        c = dict(DEFAULT_CFG)
        u = load_json(p("sdr_config.json", base), {}) or {}
        if isinstance(u, dict):
            for k, v in u.items():
                if k in c or str(k).startswith("usbw") or k in ("devs", "devs_on"):
                    c[k] = v
        return c

    def air_reg(cfg):
        if not isinstance(cfg, dict) or cfg.get("devs_on") is not True:
            return None
        devs = []
        for x in cfg.get("devs") or []:
            if x.get("kind") == "rtl":
                devs.append({"name": x.get("name") or "Stick", "kind": "rtl", "usb": x.get("usb"),
                             "serial": x.get("serial"), "role": x.get("role") or ""})
        by = {e["role"]: e for e in devs if e.get("role")}
        return {"devs": devs, "by_role": by, "err": []} if "11D" in by else None

    class Planner(object):
        def loop(self):
            return None

    ns = dict(json=_j, os=_o, re=_re, subprocess=_sp, tempfile=_tf, threading=_th, time=_tm,
              DEFAULT_CFG=DEFAULT_CFG, SERIAL_RE=SERIAL_RE, WD_SN_RE=WD_SN_RE, WD_HELPER=WD_HELPER,
              p=p, write_json=write_json, load_json=load_json, config=config, air_reg=air_reg, Planner=Planner)
    exec(sdr_block(), ns)
    assert "im_fenster" not in sdr_block()
    print(ns["selftest_usbwache"]())


def _selftest_dash_block():
    ns = {}
    exec(dash_block(), ns)
    print(ns["_usbw_selftest"]())


def selftest():
    _selftest_restart_check()
    _selftest_helper()
    _selftest_sdr_block()
    _selftest_dash_block()
    src_s = "/tmp/prepper_sdr_lage.py"
    src_d = "/tmp/dashboard_lage.py"
    if os.path.isfile(src_s) and os.path.isfile(src_d):
        raw_s, raw_d = open(src_s, "rb").read(), open(src_d, "rb").read()
        if sha256(raw_s) != SDR_START_SHA or sha256(raw_d) != DASH_START_SHA:
            raise SystemExit("selftest Vorlagen-Hash %s %s" % (sha256(raw_s)[:16], sha256(raw_d)[:16]))
        neu_s = patch_sdr(raw_s.decode("utf-8")).encode("utf-8")
        neu_d = patch_dash(raw_d.decode("utf-8")).encode("utf-8")
        if sha256(neu_s) != SDR_END_SHA or len(neu_s) != SDR_END_BYTES:
            raise SystemExit("selftest sdr Endhash %s/%d" % (sha256(neu_s), len(neu_s)))
        if sha256(neu_d) != DASH_END_SHA or len(neu_d) != DASH_END_BYTES:
            raise SystemExit("selftest dash Endhash %s/%d" % (sha256(neu_d), len(neu_d)))
        compile(neu_s, "prepper_sdr.py", "exec")
        compile(neu_d, "dashboard.py", "exec")
        assert "im_fenster" not in neu_s.decode("utf-8")
        assert "05-39" not in neu_s.decode("utf-8")
        root = tempfile.mkdtemp(prefix="usbw-st-")
        p1, p2 = os.path.join(root, "prepper_sdr.py"), os.path.join(root, "dashboard.py")
        open(p1, "wb").write(raw_s)
        open(p2, "wb").write(raw_d)
        os.chmod(p1, 0o644)
        os.chmod(p2, 0o644)
        rc = anwenden(root, True, False, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest dry-run rc %s" % rc)
        if open(p1, "rb").read() != raw_s:
            raise SystemExit("selftest dry-run hat geschrieben")
        rc = anwenden(root, False, True, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest kein-neustart rc %s" % rc)
        if sha256(open(p1, "rb").read()) != SDR_END_SHA or sha256(open(p2, "rb").read()) != DASH_END_SHA:
            raise SystemExit("selftest geschrieben falsch")
        rc = anwenden(root, False, True, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest idempotent rc %s" % rc)
        print("selftest apply auf Vorlagen ok")
    else:
        print("Hinweis: /tmp-Vorlagen fehlen, Hash-Pfad nur teilweise")
    # sicher: im Skript selbst kein Zeitfenster
    me = open(__file__, encoding="utf-8").read() if os.path.isfile(__file__) else ""
    if "def im_" "fenster" in me:
        raise SystemExit("selftest: Zeitfenster-Funktion darf nicht vorkommen")
    if not visudo_ok(sudoers_text("fmg")):
        print("Hinweis: visudo-Pruefung uebersprungen oder fehlgeschlagen (nicht immer installiert)")
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
    return anwenden(args.basis, args.dry_run, args.kein_neustart)


if __name__ == "__main__":
    raise SystemExit(main())
