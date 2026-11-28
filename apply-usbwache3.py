#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-usbwache3: USB-Wache-Kachel auf /system nach allen after_request-Haken.

/system und /umwelt sind dieselbe Seite (page3). Die Nav-Bezeichnung "System"
zeigt auf /pi, nicht auf /system. usbwache2 haengt die Kachel bereits in page3()
ein, aber after_request-Haken behandeln /system wie eine Systemseite (HB-Mesh,
Diagnosebericht) und /umwelt separat (umweltWide/evLog nur bei path==/umwelt).
Dieser Nachfix setzt die Kachel am registrierten View und als letzten
after_request (insert 0) fuer /system, /umwelt und /pi nach, falls sie fehlt.
/pi bleibt unveraendert, wenn die Kachel schon da ist. Ohne usbwache.json:
gruen "USB-Wache aktiv, keine Eingriffe". Rahmen, keine Schachtelung, keine
Seriennummer, Lage unberuehrt, keine Zeitfenster-Sperre.
Nur dashboard.py, nur Dienst prepper-dashboard. 45 s HTTP 200 und grep auf
die Kachel; fehlt sie, ehrlicher STOP.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
import zlib
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "usbwache3"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"

DASH_START_SHA = "fe07df700e8e17992a5914c0a8e426bffff3f53f833db175a6576a14e5be9593"
DASH_START_SHA16 = "fe07df700e8e1799"
DASH_START_BYTES = 1410122
DASH_END_SHA = "80bf111f45cb21a0e4a334773539549aced1ba4f02dc0ee5ea971d4c145f5b41"
DASH_END_SHA16 = "80bf111f45cb21a0"
DASH_END_BYTES = 1414043

MAIN_ANKER = "if __name__ == \"__main__\":\n    # sourceWatch final\n"
ALT_START = "# ===== usbwache2:"
ALT_END = "# ===== /usbwache2 ====="

DASH_BLOB = (
    "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"
    "ZRb21MX9ToEkeQX/vzO4Zvo="
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


def dash_block():
    raw = zlib.decompress(base64.b64decode("".join(DASH_BLOB) if not isinstance(DASH_BLOB, str) else DASH_BLOB))
    return raw.decode("utf-8")


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu, n)


def schon(text):
    return (
        text.count("_usbw_inject(html)  # usbwache2") == 2
        and "# ===== usbwache3:" in text
        and "def _usbw_after(" in text
        and "def _usbw_hook_routes(" in text
        and text.find("# ===== usbwache3:") < text.find(MAIN_ANKER)
        and ALT_START not in text
    )


def ersetze_block(text):
    """usbwache2-Block (vor __main__) durch usbwache3 ersetzen."""
    start = text.find(ALT_START)
    if start < 0:
        if "# ===== usbwache3:" in text:
            return text
        raise SystemExit("STOP usbwache2-Block fehlt (Startstand fe07df70 erwartet)")
    end = text.find(ALT_END, start)
    if end < 0:
        raise SystemExit("STOP usbwache2-Block ohne Ende")
    end = end + len(ALT_END)
    if end < len(text) and text[end] == "\n":
        end += 1
    return text[:start] + dash_block() + text[end:]


def patch_dash(text):
    if schon(text):
        return text
    text = ersetze_block(text)
    if text.count("_usbw_inject(html)  # usbwache2") != 2:
        raise SystemExit("STOP page3()/page_pi() ohne _usbw_inject (usbwache2-Haken fehlen)")
    if not schon(text):
        raise SystemExit("STOP Markierungen nach dem Patch unvollstaendig")
    return text


def berechne_dash(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == DASH_END_SHA and n == DASH_END_BYTES:
        return alt, None, None
    text = alt.decode("utf-8")
    if schon(text):
        return alt, None, None
    if hashcheck and not (ist == DASH_START_SHA and n == DASH_START_BYTES):
        return None, None, "STOP dashboard.py Hash %s/%d, erwartet %s/%d oder Endstand %s/%d" % (
            ist[:16], n, DASH_START_SHA16, DASH_START_BYTES, DASH_END_SHA16, DASH_END_BYTES)
    neu = patch_dash(text).encode("utf-8")
    hs, ns = stand(neu)
    if hashcheck and (hs != DASH_END_SHA or ns != DASH_END_BYTES):
        return None, None, "STOP dashboard.py Endhash %s/%d, erwartet %s/%d" % (hs[:16], ns, DASH_END_SHA16, DASH_END_BYTES)
    return alt, neu, None


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
    st = os.stat(pfad) if os.path.exists(pfad) else None
    tmp = pfad + ".%s-tmp" % KENNUNG
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
    os.replace(tmp, pfad)
    if st is not None:
        try:
            os.chown(pfad, st.st_uid, st.st_gid)
            os.chmod(pfad, stat.S_IMODE(st.st_mode))
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


def restart_dienst(dienst):
    before = _unit_snap(dienst)
    try:
        rc = subprocess.call(["systemctl", "restart", dienst])
    except OSError:
        rc = 127
    after = _unit_snap(dienst)
    if _restart_ok(rc, before, after):
        print("restart %s rc %s" % (dienst, rc))
        return 0
    try:
        rc2 = subprocess.call(["sudo", "systemctl", "restart", dienst])
    except OSError:
        rc2 = 127
    after = _unit_snap(dienst)
    if _restart_ok(rc2, before, after):
        print("restart %s rc %s (sudo)" % (dienst, rc2))
        return 0
    gesehen = rc2 if rc2 != 0 else rc
    print("STOP Neustart fehlgeschlagen – bitte sudo systemctl restart %s" % dienst)
    print("systemctl rc %s, Zustand %s PID %s -> %s" % (
        gesehen, after.get("active") or "?", before.get("pid") or "-", after.get("pid") or "-"))
    return gesehen if gesehen != 0 else 1


def kachel_im_html(html):
    if not html:
        return False
    if 'id="usbwBox"' not in html:
        return False
    if not re.search(r"usb-wache", html, re.I):
        return False
    return True


def warte_http_und_grep(timeout=45):
    urls = [
        ("http://127.0.0.1:5000/pi", "/tmp/apply-usbwache3-pi.html"),
        ("http://127.0.0.1:5000/system", "/tmp/apply-usbwache3-system.html"),
        ("http://127.0.0.1:5000/umwelt", "/tmp/apply-usbwache3-umwelt.html"),
    ]
    t0 = time.time()
    offen = list(urls)
    letzte = {}
    ok_urls = set()
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
                    ok_urls.add(url)
                    continue
            except (OSError, subprocess.TimeoutExpired) as exc:
                letzte[url] = type(exc).__name__
            noch.append((url, ziel))
        offen = noch
        if offen:
            time.sleep(2)
    ok = True
    # /umwelt ist Alias von page3; Pflicht sind /pi und /system
    for url, ziel in urls:
        pflicht = url.endswith("/pi") or url.endswith("/system")
        if url not in ok_urls:
            msg = "STOP %s nicht 200 innerhalb %s s (zuletzt %s)" if pflicht else "Hinweis: %s nicht 200 innerhalb %s s (zuletzt %s)"
            print(msg % (url, timeout, letzte.get(url)))
            if pflicht:
                ok = False
            continue
        html = open(ziel, encoding="utf-8", errors="replace").read() if os.path.isfile(ziel) else ""
        treffer = 0
        try:
            r = subprocess.run(["grep", "-ci", "usb-wache", ziel], capture_output=True, text=True, timeout=5)
            treffer = int((r.stdout or "0").strip() or 0)
        except Exception:
            treffer = len(re.findall(r"usb-wache", html, re.I))
        if not kachel_im_html(html) or treffer < 1:
            msg = "STOP %s ohne USB-Wache-Kachel (grep -ci usb-wache = %s, usbwBox %s)" if pflicht else "Hinweis: %s ohne USB-Wache-Kachel (grep -ci usb-wache = %s, usbwBox %s)"
            print(msg % (url, treffer, "ja" if 'id="usbwBox"' in html else "nein"))
            if pflicht:
                ok = False
        else:
            print("Kachel auf %s vorhanden (grep -ci usb-wache = %s)" % (url, treffer))
    return ok


def journal_pruefen(seit, pause=0):
    if pause:
        print("warte %s s auf Journal" % pause)
        time.sleep(pause)
    ok = True
    if not warte_http_und_grep(timeout=45):
        ok = False
    try:
        r = subprocess.run(
            ["journalctl", "-u", DIENST, "--since", seit, "-o", "cat", "-n", "80"],
            capture_output=True, text=True, timeout=10)
        zeilen = (r.stdout or "").splitlines()
        if any("Traceback" in ln for ln in zeilen):
            print("STOP Journal %s enthaelt Traceback" % DIENST)
            for ln in [x for x in zeilen if "Traceback" in x][:8]:
                print(ln)
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (DIENST, len(zeilen)))
    except (OSError, subprocess.TimeoutExpired):
        print("Hinweis: Journal %s unlesbar" % DIENST)
    return ok


def anwenden(root, dry, kein, hashcheck=True, pause=0):
    dash = os.path.join(root, "dashboard.py")
    alt, neu, err = berechne_dash(dash, hashcheck=hashcheck)
    if err:
        print(err)
        return 2
    if neu is None:
        print("dashboard.py bereits auf Endstand, unveraendert")
        return 0
    if dry:
        print("dry-run dashboard.py %d -> %d Bytes sha256 %s" % (len(alt), len(neu), sha256(neu)))
        print("dry-run: keine Datei geschrieben, kein Neustart")
        return 0
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    bak = sichern(dash, stempel)
    print("Backup %s" % bak)
    schreibe(dash, neu)
    hs, ns = stand(open(dash, "rb").read())
    print("geschrieben dashboard.py sha256 %s bytes %d" % (hs, ns))
    compile(neu, "dashboard.py", "exec")
    if not pyflakes_datei(dash):
        print("STOP pyflakes dashboard.py")
        return 4
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = restart_dienst(DIENST)
    if rc != 0:
        return rc
    if not journal_pruefen(seit, pause=pause):
        return 5
    print("ok, Dienst: %s" % DIENST)
    return 0


def _selftest_restart_check():
    assert _restart_ok(1, {"pid": "1", "ts": "a", "active": "active"}, {"pid": "2", "ts": "b", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"},
                       {"pid": "10", "ts": "A", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"},
                       {"pid": "11", "ts": "B", "active": "active"}) is True
    print("selftest Neustart-Check ok")


def _selftest_block():
    ns = {}
    exec(dash_block(), ns)
    assert str(ns["_usbw_selftest"]()).startswith("usbwache3 ok")
    assert "def im_" "fenster" not in dash_block()
    print("selftest Anzeige-Block ok")


def _vorlage():
    for p in ("/tmp/dashboard_usbw2.py", os.path.join(BASIS, "dashboard.py")):
        if os.path.isfile(p):
            raw = open(p, "rb").read()
            if sha256(raw) == DASH_START_SHA and len(raw) == DASH_START_BYTES:
                return p, raw
    return None, None


def selftest():
    _selftest_restart_check()
    _selftest_block()
    pfad, raw = _vorlage()
    if raw is None:
        print("Hinweis: Vollvorlage fe07df70 nicht unter /tmp/dashboard_usbw2.py – Patch-Test an synthetischem Anker")
        fake = (
            "x = 1\n"
            "    html = html.replace(\"</body>\", box + \"</body>\")\n"
            "    try:\n"
            "        html = _usbw_inject(html)  # usbwache2\n"
            "    except Exception as _usbw_ex:\n"
            "        print(\"usbwache /pi:\", type(_usbw_ex).__name__, flush=True)\n"
            "    return html\n"
            "def page3():\n"
            "    html = render_template_string(PAGE3, **_page_stability_defaults(data_store))  # pageStability\n"
            "    try:\n"
            "        html = _usbw_inject(html)  # usbwache2\n"
            "    except Exception as _usbw_ex:\n"
            "        print(\"usbwache /system:\", type(_usbw_ex).__name__, flush=True)\n"
            "    return html\n"
            "# ===== usbwache2:\n"
            "old = 1\n"
            "# ===== /usbwache2 =====\n"
            "if __name__ == \"__main__\":\n"
            "    # sourceWatch final\n"
            "    pass\n"
        )
        neu = patch_dash(fake)
        assert schon(neu) and ALT_START not in neu
        compile(dash_block() + "\nx=1\n", "usbw3.py", "exec")
    else:
        print("Vorlage %s sha16 %s bytes %d" % (pfad, sha256(raw)[:16], len(raw)))
        neu = patch_dash(raw.decode("utf-8")).encode("utf-8")
        if sha256(neu) != DASH_END_SHA or len(neu) != DASH_END_BYTES:
            raise SystemExit("selftest dash Endhash %s/%d" % (sha256(neu), len(neu)))
        compile(neu, "dashboard.py", "exec")
        txt = neu.decode("utf-8")
        assert schon(txt)
        assert "def im_" "fenster" not in txt
        root = tempfile.mkdtemp(prefix="usbw3-st-")
        p = os.path.join(root, "dashboard.py")
        open(p, "wb").write(raw)
        os.chmod(p, 0o644)
        rc = anwenden(root, True, False, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest dry-run rc %s" % rc)
        if open(p, "rb").read() != raw:
            raise SystemExit("selftest dry-run hat geschrieben")
        rc = anwenden(root, False, True, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest kein-neustart rc %s" % rc)
        if sha256(open(p, "rb").read()) != DASH_END_SHA:
            raise SystemExit("selftest geschrieben falsch")
        rc = anwenden(root, False, True, hashcheck=True)
        if rc != 0:
            raise SystemExit("selftest idempotent rc %s" % rc)
        print("selftest apply auf Vorlage ok")
    me = open(__file__, encoding="utf-8").read() if os.path.isfile(__file__) else ""
    if "def im_" "fenster" in me:
        raise SystemExit("selftest: Zeitfenster-Funktion darf nicht vorkommen")
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    return anwenden(args.basis, args.dry_run, args.kein_neustart)


if __name__ == "__main__":
    raise SystemExit(main())
