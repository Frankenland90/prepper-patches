#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-usbwache2: USB-Wache-Kachel fest in page3() und page_pi().

Ursache des ersten Stands: der Anzeige-Block hing hinter dem blockierenden
if __name__ == "__main__" (Serverstart) und wurde nie geladen. after_request
lief daher nicht. Dieser Nachfix haengt die Kachel direkt an die Render-Wege
von /system (page3, auch /umwelt) und /pi (page_pi), auch ohne usbwache.json
(gruen: "USB-Wache aktiv, keine Eingriffe"). Ein Rahmen, keine Kachel in der
Kachel, keine Seriennummer, Lage unberuehrt. Keine Zeitfenster-Sperre.
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

KENNUNG = "usbwache2"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"

DASH_START_SHA = "209d1b995497831acf69b7489350f2c7cb561be0a58fe1c7403fbffc94478730"
DASH_START_SHA16 = "209d1b995497831a"
DASH_START_BYTES = 1408116
DASH_END_SHA = "fe07df700e8e17992a5914c0a8e426bffff3f53f833db175a6576a14e5be9593"
DASH_END_SHA16 = "fe07df700e8e1799"
DASH_END_BYTES = 1410122

PAGE3_ALT = "    return render_template_string(PAGE3, **_page_stability_defaults(data_store))  # pageStability\n"
PAGE3_NEU = (
    "    html = render_template_string(PAGE3, **_page_stability_defaults(data_store))  # pageStability\n"
    "    try:\n"
    "        html = _usbw_inject(html)  # usbwache2\n"
    "    except Exception as _usbw_ex:\n"
    '        print("usbwache /system:", type(_usbw_ex).__name__, flush=True)\n'
    "    return html\n"
)
PI_ALT = "    html = html.replace(\"</body>\", box + \"</body>\")\n    return html\n"
PI_NEU = (
    "    html = html.replace(\"</body>\", box + \"</body>\")\n"
    "    try:\n"
    "        html = _usbw_inject(html)  # usbwache2\n"
    "    except Exception as _usbw_ex:\n"
    '        print("usbwache /pi:", type(_usbw_ex).__name__, flush=True)\n'
    "    return html\n"
)
MAIN_ANKER = "if __name__ == \"__main__\":\n    # sourceWatch final\n"
ALT_EOF_START = "# ===== usbwache:"
ALT_EOF_END = "# ===== /usbwache ====="

DASH_BLOB = (
    "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"
    "vwX+Byxx1dI="
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
        and "USB-Wache aktiv, keine Eingriffe" in text
        and "# ===== usbwache2:" in text
        and text.find("# ===== usbwache2:") < text.find(MAIN_ANKER)
    )


def entferne_toten_block(text):
    """Alten Anzeige-Block hinter __main__ entfernen (wurde nie geladen)."""
    start = text.find(ALT_EOF_START)
    if start < 0:
        return text
    end = text.find(ALT_EOF_END, start)
    if end < 0:
        raise SystemExit("STOP alter usbwache-Block ohne Ende")
    end = end + len(ALT_EOF_END)
    if end < len(text) and text[end] == "\n":
        end += 1
    return text[:start] + text[end:]


def patch_dash(text):
    if schon(text):
        return text
    text = entferne_toten_block(text)
    if "_usbw_inject(html)  # usbwache2" not in text:
        text = ersetze(text, PAGE3_ALT, PAGE3_NEU, "page3()", 1)
        text = ersetze(text, PI_ALT, PI_NEU, "page_pi()", 1)
    if "# ===== usbwache2:" not in text:
        text = ersetze(text, MAIN_ANKER, dash_block() + "\n" + MAIN_ANKER, "__main__", 1)
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
        ("http://127.0.0.1:5000/pi", "/tmp/apply-usbwache2-pi.html"),
        ("http://127.0.0.1:5000/system", "/tmp/apply-usbwache2-system.html"),
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
    for url, ziel in urls:
        if url not in ok_urls:
            print("STOP %s nicht 200 innerhalb %s s (zuletzt %s)" % (url, timeout, letzte.get(url)))
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
            print("STOP %s ohne USB-Wache-Kachel (grep -ci usb-wache = %s, usbwBox %s)" % (
                url, treffer, "ja" if 'id="usbwBox"' in html else "nein"))
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
    assert str(ns["_usbw_selftest"]()).startswith("usbwache2 ok")
    assert "def im_" "fenster" not in dash_block()
    print("selftest Anzeige-Block ok")


def selftest():
    _selftest_restart_check()
    _selftest_block()
    src = "/tmp/dashboard_usbw.py"
    if not os.path.isfile(src):
        raise SystemExit("selftest Vorlage %s fehlt" % src)
    raw = open(src, "rb").read()
    if sha256(raw) != DASH_START_SHA or len(raw) != DASH_START_BYTES:
        raise SystemExit("selftest Vorlagen-Hash %s/%d" % (sha256(raw), len(raw)))
    neu = patch_dash(raw.decode("utf-8")).encode("utf-8")
    if sha256(neu) != DASH_END_SHA or len(neu) != DASH_END_BYTES:
        raise SystemExit("selftest dash Endhash %s/%d" % (sha256(neu), len(neu)))
    compile(neu, "dashboard.py", "exec")
    txt = neu.decode("utf-8")
    assert txt.find("# ===== usbwache2:") < txt.find(MAIN_ANKER)
    assert txt.count("_usbw_inject(html)  # usbwache2") == 2
    assert ALT_EOF_START not in txt
    assert "def im_" "fenster" not in txt
    # Ruhetext und grep-Muster im gerenderten Minimal-HTML
    cut = txt.find("# ===== usbwache2:")
    end = txt.find("# ===== /usbwache2 =====")
    ns = {}
    exec(txt[cut:end + len("# ===== /usbwache2 =====")], ns)
    html_sys = ns["_usbw_inject"]('<html><head></head><body><div class="grid" id="umwGrid"><div class="card">DWD</div></div></body>')
    html_pi = ns["_usbw_inject"]('<html><head></head><body><div class="card" id="backupBox">S</div></body>')
    assert kachel_im_html(html_sys) and kachel_im_html(html_pi)
    assert "USB-Wache aktiv, keine Eingriffe" in html_sys and "USB-Wache aktiv, keine Eingriffe" in html_pi
    assert html_sys.count('class="card"') >= 2  # usbw + DWD, Geschwister
    inner = html_pi[html_pi.find('id="usbwBox"'):html_pi.find('id="backupBox"')]
    assert inner.count('class="card"') == 1
    root = tempfile.mkdtemp(prefix="usbw2-st-")
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
    me = open(__file__, encoding="utf-8").read() if os.path.isfile(__file__) else ""
    if "def im_" "fenster" in me:
        raise SystemExit("selftest: Zeitfenster-Funktion darf nicht vorkommen")
    print("selftest apply auf Vorlage ok")
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
