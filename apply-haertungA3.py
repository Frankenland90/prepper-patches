#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-haertungA3: Haertung Paket A (Minimal-Diff).

1) Flugfunk: 123,080 MHz und 121,500 je allein im Scan (Mitte des Empfangsfensters).
   Bisher eine 1,58-MHz-Gruppe (ATIS+Notfrequenz) am Fensterrand; 24 h keine Sprueche auf 123,080.
2) Dashboard: fehlt 192.168.178.99, Bind 127.0.0.1 statt 0.0.0.0, mit Journalzeile.
3) rtl_tcp: tcp_bind 127.0.0.1 (Default und Aufruf).
4) flugfunk lan_ok: leere IP ablehnen, nur 192.168.178.0/24 plus Loopback.
5) Whisper-Warteschlange: transkribieren()=None/Timeout als erledigt, Fehler zaehlen.

flugfunk.py: erlaubte Live-Basis 5d7c1e27.../100944. Anker nur kurze eindeutige Zeilen (kein langer lan_ok-Block). Sonst STOP.
Basis: dashboard.py 84e48878.../1478022 (nach adsbbreite2), prepper_sdr.py 3496de46.../822016 (nach usbcycle),
sdr_manager.py 5a26efff.../288008 unveraendert.
Neustart: prepper-sdr und prepper-dashboard. Keine Firewall, kein Mesh, keine Schluessel.
Live: sysBoot loading:false, alle Seiten und Kern-APIs 200, /api/sdr/usbw 200, rtl_airband laeuft, keine Seriennummern, Rollback bei Fehler. APIs, die vor dem Patch nicht 200 waren, nur Hinweis. /api/funk433 bis 180 s, danach nur Hinweis (433-Empfaenger nach prepper-sdr-Neustart).
Keine Zeitsperre, keine Seriennummern in der Ausgabe."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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

KENNUNG = "haertungA3"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"
DIENST_SDR = "prepper-sdr"
FESTE_SN = ()
VORGAENGER = "adsbbreite2"
DASH_START = ("84e48878f1ca071ec873dd0a809b2b9ba693ab8f76e4044bcb68e49aae4a9706", 1478022)
DASH_ENDE = ("cba07a04c120dc79f7b4dd0f34dadcfb81a548d7e1a048fe4895281929439d51", 1478064)
SDR_START = ("3496de46b67fc16468a6f2e089dea6c3ebebd6162cbfe36725e4efd240129b2a", 822016)
SDR_ENDE = ("c5b73d264df47ad0782e624b1b900dae18830f0f3ee239904f48026c37567e99", 822011)
SM_SOLL = ("5a26efff608bf541a929fa775112d3593883a7423b6d9f6f29e61dc9b14db181", 288008)
VORSTAENDE = {
    "713348c3be2341310658c8c3899733a21e3abfd9e081955af1387853afd21a06": "dashboard.py steht noch auf zuhauseflach - bitte zuerst apply-adsbbreite2.py. ",
    "8d0a09e8ad76f8fa27faef1020da54c3ae9b3b2ada3a5aef784db9291f59c0a6": "dashboard.py steht noch auf acarsklar - bitte zuerst apply-zuhauseflach2.py und apply-adsbbreite2.py. ",
}
JOURNAL_PFLICHT = ["snMask aktiv:", "inetSplit aktiv", "usbwache Anzeige:", "feinschliff4 aktiv:",
                  "feinschliff5 aktiv:", "feinschliff8 aktiv:", "seitenFlach aktiv:", "funkFlach aktiv:",
                  "acarsKachel aktiv:", "acarsKlar aktiv:"]
JOURNAL_VERBOTEN = ["snMask Selbsttest FEHLER", "snMask FEHLER", "feinschliff4 Selbsttest FEHLER", "feinschliff4 FEHLER",
                    "inetSplit FEHLER", "teil4 Lage-Seite:", "feinschliff5 Menue:", "feinschliff5 FEHLER",
                    "feinschliff8 FEHLER", "seitenFlach FEHLER", "funkFlach FEHLER", "acarsKlar FEHLER", "acarsKachel FEHLER"]

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


class Stop(Exception):
    pass


def _python_mit_flask(basis):
    cands = [sys.executable]
    ve = os.environ.get("VIRTUAL_ENV")
    if ve:
        cands.append(os.path.join(ve, "bin", "python"))
    for rel in (("venv", "bin", "python"), (".venv", "bin", "python"), ("venv", "bin", "python3")):
        cands.append(os.path.join(basis, *rel))
        cands.append(os.path.join(os.path.dirname(basis), *rel))
    cands += ["/workspace/feinschliff/venv/bin/python", "/home/fmg/prepper-dashboard/venv/bin/python"]
    seen = set()
    for py in cands:
        if not py or py in seen or not os.path.isfile(py):
            continue
        seen.add(py)
        try:
            r = subprocess.run([py, "-c", "import flask"], capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0:
            return py
    return None


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise Stop("STOP %s: Anker %d mal gefunden, erwartet %d" % (name, c, n))
    return text.replace(alt, neu)


def sichern(pfad, stempel):
    ziel = "%s.bak-%s-%s" % (pfad, KENNUNG, stempel)
    shutil.copy2(pfad, ziel)
    ordner = os.path.dirname(pfad) or "."
    name = os.path.basename(pfad) + ".bak-" + KENNUNG + "-"
    for p in sorted(p for p in os.listdir(ordner) if p.startswith(name))[:-3]:
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


def _pyflakes_msgs(pfad):
    """Meldungen ohne Zeilennummern als Zaehler, oder None ohne pyflakes."""
    for cmd in (["pyflakes", pfad], ["python3", "-m", "pyflakes", pfad]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            continue
        err = (r.stderr or "") + (r.stdout or "")
        if "No module named" in err or "command not found" in err:
            continue
        out = {}
        for ln in err.splitlines():
            m = re.match(r"^.*?:\d+(?::\d+)?:? (.*)$", ln)
            k = m.group(1) if m else ln
            out[k] = out.get(k, 0) + 1
        return out
    return None


def pyflakes_vergleich(pfad_alt, pfad_neu):
    """True, wenn die neue Datei keine zusaetzliche pyflakes-Meldung hat (gegenueber der alten)."""
    a, n = _pyflakes_msgs(pfad_alt), _pyflakes_msgs(pfad_neu)
    if a is None or n is None:
        print("Hinweis: pyflakes nicht installiert, nur compile")
        return True
    neu = [k for k, c in n.items() if c > a.get(k, 0)]
    if neu:
        print("pyflakes %s: neue Meldungen:\n%s" % (os.path.basename(pfad_neu), "\n".join(neu[:20])))
        return False
    print("pyflakes %s: keine neue Meldung (alt %d, neu %d)" % (os.path.basename(pfad_neu), sum(a.values()), sum(n.values())))
    return True


def _unit_snap(dienst):
    snap = {"pid": "", "ts": "", "active": ""}
    try:
        r = subprocess.run(["systemctl", "show", dienst, "-p", "MainPID", "-p", "ActiveEnterTimestamp", "-p", "ActiveState"],
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
    print("STOP Neustart fehlgeschlagen - bitte sudo systemctl restart %s" % dienst)
    return gesehen if gesehen != 0 else 1


URL = "http://127.0.0.1:5000"


def _get(pfad, timeout=6):
    ziel = tempfile.mktemp(prefix="apply-" + KENNUNG + "-")
    try:
        r = subprocess.run(["curl", "-sS", "-m", str(timeout), "-o", ziel, "-w", "%{http_code}", URL + pfad],
                           capture_output=True, text=True, timeout=timeout + 3)
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


def warte_200(pfade, timeout=45, pflicht=True):
    t0 = time.time()
    offen = list(pfade)
    seiten = {}
    while offen and time.time() - t0 < timeout:
        noch = []
        for p in offen:
            code, body = _get(p)
            if code == "200":
                print("GET %s -> 200 nach %.1f s" % (p, time.time() - t0))
                seiten[p] = body
            else:
                noch.append(p)
        offen = noch
        if offen:
            time.sleep(2)
    for p in offen:
        print("%s %s nicht 200 innerhalb %s s" % ("STOP" if pflicht else "Hinweis:", p, timeout))
    return (not offen), seiten


def echte_seriennummern(root):
    """Seriennummern aus den Konfigurations-/Statusdateien. Werte werden nie ausgegeben."""
    sns = set(FESTE_SN)

    def walk(o, d=0):
        if d > 9:
            return
        if isinstance(o, dict):
            for k, v in o.items():
                ks = str(k)
                if re.fullmatch(r"(?i)serial|usb_serial|sn[0-9]?|stick[0-9]?_?sn", ks) and isinstance(v, (str, int)):
                    sns.add(str(v).strip())
                elif ks in ("others", "serials") and isinstance(v, list):
                    sns.update(str(x).strip() for x in v if isinstance(x, (str, int)))
                elif re.fullmatch(r"[0-9A-Fa-f]{8,20}", ks) and any(c.isdigit() for c in ks) and isinstance(v, (dict, list)):
                    sns.add(ks)
                if re.fullmatch(r"stick[0-9]+", ks) and isinstance(v, (str, int)):
                    sns.add(str(v).strip())
                walk(v, d + 1)
        elif isinstance(o, list):
            for x in o[:200]:
                walk(x, d + 1)

    for name in ("sdr_config.json", "sdr_status.json", "sdr_serials.local.json", "sdr_wd.json"):
        try:
            with open(os.path.join(root, name), encoding="utf-8") as fh:
                walk(json.load(fh))
        except Exception:
            pass
    return sorted(s for s in sns if len(s) >= 6 and any(c.isdigit() for c in s) and re.fullmatch(r"[0-9A-Za-z]+", s))


def sn_treffer(text, sns):
    return sum(1 for s in sns if re.search(r"(?<![0-9A-Za-z])" + re.escape(s) + r"(?![0-9A-Za-z])", text, re.I))


def journal_zeilen(dienst, seit):
    r = subprocess.run(["journalctl", "-u", dienst, "--since", seit, "-o", "cat", "-n", "800"], capture_output=True, text=True, timeout=20)
    return (r.stdout or "").splitlines()

# ----------------------------------------------------------------- Paket

D_PW_A = 'PW_HOST = "192.168.178.99"     # LAN plus 127.0.0.1. Fehlt die Adresse beim Start, Fallback 0.0.0.0 mit Journalzeile.\n'
D_PW_B = 'PW_HOST = "192.168.178.99"     # LAN plus 127.0.0.1. Fehlt die Adresse beim Start, Fallback 127.0.0.1 mit Journalzeile.\n'
D_WZ_A = '        print("perfWsgi FEHLER: waitress nicht ladbar (%s) - Start wie bisher mit Werkzeug (app.run), Bind 0.0.0.0" % e, flush=True)\n        app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False, threaded=True)\n'
D_WZ_B = '        print("perfWsgi FEHLER: waitress nicht ladbar (%s) - Start wie bisher mit Werkzeug (app.run), Bind 127.0.0.1 (kein 0.0.0.0)" % e, flush=True)\n        app.run(host="127.0.0.1", port=PORT, debug=False, use_reloader=False, threaded=True)\n'
D_FB_A = '        print("perfWsgi: Bind 192.168.178.99 fehlgeschlagen (%s), Fallback 0.0.0.0" % type(_pw_bind).__name__, flush=True)\n        srv = _pw_create(app, host="0.0.0.0", port=int(PORT), threads=PW_THREADS, ident="waitress", asyncore_use_poll=True, connection_limit=100, channel_timeout=120, expose_tracebacks=False, clear_untrusted_proxy_headers=True)\n        gebunden = "0.0.0.0"\n'
D_FB_B = '        print("perfWsgi: Bind 192.168.178.99 fehlgeschlagen (%s), Fallback 127.0.0.1 (kein 0.0.0.0)" % type(_pw_bind).__name__, flush=True)\n        srv = _pw_create(app, host="127.0.0.1", port=int(PORT), threads=PW_THREADS, ident="waitress", asyncore_use_poll=True, connection_limit=100, channel_timeout=120, expose_tracebacks=False, clear_untrusted_proxy_headers=True)\n        gebunden = "127.0.0.1"\n'
DASH_PATCHES = [("PW_HOST Fallback-Hinweis", D_PW_A, D_PW_B), ("Werkzeug-Bind", D_WZ_A, D_WZ_B), ("waitress-Fallback", D_FB_A, D_FB_B)]

S_DEF_A = '"tcp_bind": "0.0.0.0"'
S_DEF_B = '"tcp_bind": "127.0.0.1"'
S_CMD_A = 'return [self._dev(["rtl_tcp", "-a", str(c["tcp_bind"]), "-p", str(int(c["tcp_port"])), "-P", str(ppm_val(c))])]'
S_CMD_B = 'return [self._dev(["rtl_tcp", "-a", "127.0.0.1", "-p", str(int(c["tcp_port"])), "-P", str(ppm_val(c))])]'
SDR_PATCHES = [("tcp_bind Default", S_DEF_A, S_DEF_B), ("rtl_tcp -a", S_CMD_A, S_CMD_B)]

FF_NET_A = '    if adresse.version == 4 and adresse in ipaddress.ip_network("100.64.0.0/10"):'
FF_NET_B = '    if adresse.version == 4 and adresse in ipaddress.ip_network("192.168.178.0/24"):'
FF_RET_A = "    return bool(adresse.is_loopback or adresse.is_private or adresse.is_link_local)"
FF_RET_B = "    return bool(adresse.is_loopback)"
FF_DEF_A = "def lan_ok(ip):\n"
FF_DEF_B = "def lan_ok(ip):\n    if not ip:\n        return False\n"
FF_ST_A = '    assert lan_ok("192.168.178.20") and lan_ok("127.0.0.1") and lan_ok("::1") and lan_ok("100.64.1.1")'
FF_ST_B = '    assert lan_ok("192.168.178.20") and lan_ok("127.0.0.1") and lan_ok("::1") and not lan_ok("100.64.1.1") and not lan_ok("") and not lan_ok("192.168.1.20")'
FF_GRP_A = "        if cur and (hz - cur[0][0]) / 1e6 > SPANNE_MHZ:"
FF_GRP_B = "        allein = hz in (NOTFREQUENZ, ATIS_HZ)\n        if cur and (allein or cur[0][0] in (NOTFREQUENZ, ATIS_HZ) or (hz - cur[0][0]) / 1e6 > SPANNE_MHZ):"
FF_Q_A = (
    '        if text is None and werkzeug("whisper-cli", base) and modell_pfad(base):\n'
    "            return\n"
    '        if text is None and not (werkzeug("whisper-cli", base) and modell_pfad(base)):\n'
    "            return\n"
    "        con = connect(db_pfad(base))\n"
    "        try:\n"
    "            fertig(con, qid)"
)
FF_Q_B = (
    "        con = connect(db_pfad(base))\n"
    "        try:\n"
    "            if text is None:\n"
    "                n = 1\n"
    "                try:\n"
    "                    n = int(_meta(con, \"transkript_fehler\") or 0) + 1\n"
    "                except (TypeError, ValueError):\n"
    "                    n = 1\n"
    "                con.execute(\n"
    "                    \"INSERT INTO meta(key, wert) VALUES ('transkript_fehler', ?) \"\n"
    "                    \"ON CONFLICT(key) DO UPDATE SET wert=excluded.wert\",\n"
    "                    (str(n),),\n"
    "                )\n"
    "                con.commit()\n"
    "                _log(base, \"verworfen\", \"transkript\")\n"
    "            fertig(con, qid)"
)
# Einzeilige bzw. kurze, in der Live-Datei als eindeutig erwartete Anker.
# "lan_ok leer" bleibt als Prefix in der Datei (def lan_ok); schon_ff daher extra, nicht "alt fehlt".
FF_PATCHES = [
    ("gruppen ATIS/Guard allein", FF_GRP_A, FF_GRP_B),
    ("lan_ok Netz", FF_NET_A, FF_NET_B),
    ("lan_ok Rueckgabe", FF_RET_A, FF_RET_B),
    ("lan_ok leer", FF_DEF_A, FF_DEF_B),
    ("lan_ok selftest", FF_ST_A, FF_ST_B),
    ("Warteschlange fertig", FF_Q_A, FF_Q_B),
]
FF_BASIS = ("5d7c1e2716c56457cca64db5e3e639b752fbdf029ed9baf5988777087dd5e2a0", 100944)


def schon_ff(text):
    return (
        'ipaddress.ip_network("192.168.178.0/24")' in text
        and 'ipaddress.ip_network("100.64.0.0/10")' not in text
        and 'and not lan_ok("100.64.1.1")' in text
        and "allein = hz in (NOTFREQUENZ, ATIS_HZ)" in text
        and "transkript_fehler" in text
        and "def lan_ok(ip):\n    if not ip:\n        return False" in text
        and "adresse.is_private or adresse.is_link_local" not in text
    )


def schon_dash(text):
    return D_PW_B in text and D_WZ_B in text and D_FB_B in text


def schon_sdr(text):
    return S_DEF_B in text and S_CMD_B in text and S_DEF_A not in text and S_CMD_A not in text


def _anker_ok(text, paare, name):
    """Vor dem Schreiben: jeder Anker genau einmal, oder Datei schon vollstaendig gepatcht."""
    if name == "flugfunk.py":
        fertig = schon_ff(text)
    elif name == "dashboard.py":
        fertig = schon_dash(text)
    else:
        fertig = schon_sdr(text)
    if fertig:
        return True
    for titel, alt, neu in paare:
        c = text.count(alt)
        if c != 1:
            raise Stop("STOP %s: Anker '%s' %d mal gefunden, erwartet 1. Nichts veraendert." % (name, titel, c))
    return True


def patch_dash(text):
    if schon_dash(text):
        return text
    for name, alt, neu in DASH_PATCHES:
        text = ersetze(text, alt, neu, "dashboard.py " + name)
    return text


def patch_sdr(text):
    if schon_sdr(text):
        return text
    for name, alt, neu in SDR_PATCHES:
        text = ersetze(text, alt, neu, "prepper_sdr.py " + name)
    return text


def patch_ff(text):
    if schon_ff(text):
        return text
    for name, alt, neu in FF_PATCHES:
        text = ersetze(text, alt, neu, "flugfunk.py " + name)
    return text


def basis_pruefen(root):
    """-> {name: bytes}. Stop bei falscher Basis oder uneindeutigem flugfunk-Anker."""
    def lies(n, muss=True):
        p = os.path.join(root, n)
        if not os.path.isfile(p):
            if muss:
                raise Stop("STOP %s fehlt in %s" % (n, root))
            return None
        return open(p, "rb").read()
    d = lies("dashboard.py")
    ds = stand(d)
    if ds not in (DASH_START, DASH_ENDE):
        hinweis = VORSTAENDE.get(ds[0], "")
        raise Stop("STOP Basis stimmt nicht: dashboard.py %s/%d ist weder der Stand nach %s (%s.../%d) noch der Endstand. %sNichts veraendert." % (
            ds[0][:16], ds[1], VORGAENGER, DASH_START[0][:8], DASH_START[1], hinweis))
    s = lies("prepper_sdr.py")
    ss = stand(s)
    if ss not in (SDR_START, SDR_ENDE):
        raise Stop("STOP Basis stimmt nicht: prepper_sdr.py %s/%d ist nicht 3496de46.../822016 (nach usbcycle) und nicht der Endstand. Nichts veraendert." % (ss[0][:16], ss[1]))
    m = lies("sdr_manager.py")
    ms = stand(m)
    if ms != SM_SOLL:
        raise Stop("STOP Basis stimmt nicht: sdr_manager.py %s/%d ist nicht 5a26efff.../288008. Nichts veraendert." % (ms[0][:16], ms[1]))
    ff = lies("flugfunk.py")
    if ff.strip() == b"# platzhalter" or len(ff) < 1000:
        raise Stop("STOP flugfunk.py ist nur ein Platzhalter oder zu kurz (%d Bytes). Nichts veraendert." % len(ff))
    fft = ff.decode("utf-8")
    fh = stand(ff)
    bekannt = "erlaubte Live-Basis" if fh == FF_BASIS else ("Endstand oder Anker" if schon_ff(fft) else "Anker")
    _anker_ok(fft, FF_PATCHES, "flugfunk.py")
    print("Basis ok: dashboard.py %s (%s), prepper_sdr.py %s, sdr_manager.py 5a26efff, flugfunk.py %s/%d (%s ok)" % (
        ds[0][:16], "Stand nach " + VORGAENGER if ds == DASH_START else "Endstand",
        ss[0][:16], fh[0][:16], len(ff), bekannt))
    return {"dashboard.py": d, "prepper_sdr.py": s, "sdr_manager.py": m, "flugfunk.py": ff}


def berechne(root):
    raw = basis_pruefen(root)
    out = {}
    td = raw["dashboard.py"].decode("utf-8")
    nd = patch_dash(td).encode("utf-8")
    if stand(nd) != DASH_ENDE:
        raise Stop("STOP Ergebnis dashboard.py %s/%d weicht vom erwarteten Endstand ab" % (stand(nd)[0][:16], len(nd)))
    out["dashboard.py"] = None if nd == raw["dashboard.py"] else nd
    ts = raw["prepper_sdr.py"].decode("utf-8")
    ns = patch_sdr(ts).encode("utf-8")
    if stand(ns) != SDR_ENDE:
        raise Stop("STOP Ergebnis prepper_sdr.py %s/%d weicht vom erwarteten Endstand ab" % (stand(ns)[0][:16], len(ns)))
    out["prepper_sdr.py"] = None if ns == raw["prepper_sdr.py"] else ns
    tf = raw["flugfunk.py"].decode("utf-8")
    nf = patch_ff(tf).encode("utf-8")
    if not schon_ff(nf.decode("utf-8")):
        raise Stop("STOP flugfunk.py nach dem Patch ohne alle neuen Anker")
    out["flugfunk.py"] = None if nf == raw["flugfunk.py"] else nf
    return raw, out


# ----------------------------------------------------------------- Live-Pruefung
SEITEN_KERN = ["/", "/pi", "/system", "/umwelt", "/aprs", "/rundfunk", "/funk"]
SEITEN_MEHR = ["/energie", "/lokale-energie", "/speicher", "/luft", "/pegel", "/adsb", "/zuhause", "/mesh", "/mesh2", "/news",
               "/karte", "/medizin", "/meteor", "/dabhist"]
SEITEN_ALLE = SEITEN_KERN + SEITEN_MEHR
API_LESEN = ["/api/sdr/status", "/api/sdr/ui", "/api/sdr/wd", "/api/sdr/live", "/api/broadcast", "/api/t2/status", "/api/t4/status",
             "/api/sdr/usbw", "/api/snmask", "/api/aprs", "/api/funk433", "/api/sdr/activity", "/api/sdr/noise", "/api/uplink",
             "/api/inet_split", "/api/broadcast/events", "/api/pushover", "/api/flugfunk", "/api/lage_grund"]
API_KERN = ["/api/sdr/usbw", "/api/sdr/status", "/api/sdr/ui", "/api/sdr/wd", "/api/sdr/live",
            "/api/lage_grund", "/api/flugfunk", "/api/t4/status", "/api/snmask"]
API_WEICH = ["/api/funk433"]  # nach SDR-Neustart kann der 433-Empfaenger spaeter kommen; kein Rollback
FUNK_MARKER = ("flugfunkBox", "ffPush", "ffLive", "sdrui-css", "sdrui-data", "fuLage", "snm-js")

def _fehler_keys(zeilen):
    out = set()
    for ln in zeilen:
        if "Traceback" in ln or "FEHLER" in ln:
            out.add(re.sub(r"[0-9]+", "#", ln)[:48])
    return out

def journal_vorher():
    """FEHLER-/Traceback-Zeilen des laufenden Dienstes seit seinem Start (Vergleichsbasis). None, wenn der Start nicht im Journal zu sehen ist."""
    snap = _unit_snap(DIENST)
    for seit in (snap.get("ts") or "", "-3 days"):
        if not seit:
            continue
        try:
            r = subprocess.run(["journalctl", "-u", DIENST, "--since", seit, "-o", "cat", "-n", "6000"], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        zeilen = (r.stdout or "").splitlines()
        if r.returncode == 0 and any("snMask aktiv:" in ln for ln in zeilen):
            return _fehler_keys(zeilen)
    return None

def vorher_stand():
    codes = {}
    marker = []
    for p in SEITEN_KERN + SEITEN_MEHR + API_LESEN:
        code, body = _get(p, 8)
        codes[p] = code
        if p == "/funk" and code == "200" and 'id="sbLoading"' not in body:
            marker = [m for m in FUNK_MARKER if m in body]
    nicht = [p for p in API_LESEN if codes.get(p) != "200"]
    if nicht:
        print("Vorher nicht 200 (nach dem Patch nur Hinweis, kein Rollback): %s" % ", ".join(nicht))
    return {"codes": codes, "funk_marker": marker, "fehler": journal_vorher()}

def lage_check(timeout=None):
    """Die Lage gibt es weiter (/api/lage_grund) und der feinschliff4-Selbsttest im Dienst ist gruen. Unlesbar/noch nicht geladen -> Hinweis, kein Rollback."""
    timeout = timeout or int(os.environ.get("FS_LAGE_WAIT") or 120)
    t0 = time.time()
    g = None
    while time.time() - t0 < timeout:
        code, body = _get("/api/lage_grund", 10)
        if code == "200":
            try:
                g = json.loads(body)
            except ValueError:
                g = None
            if isinstance(g, dict) and isinstance(g.get("lage"), dict) and g["lage"].get("text") not in (None, "–"):
                break
        time.sleep(5)
    else:
        print("Hinweis: Lage nach %d s noch nicht geladen - bitte spaeter: curl -s %s/api/lage_grund | python3 -m json.tool" % (timeout, URL))
        return True
    lage = g["lage"]
    print("Lage: %s - %s" % (lage.get("text"), str(lage.get("reason") or "")[:100]))
    if not str(g.get("selftest") or "").startswith("feinschliff4 ok"):
        print("STOP feinschliff4-Selbsttest im Dienst: %s" % g.get("selftest"))
        return False
    return True

def _t4why_ok(body):
    """True, wenn die Lage-Seite serverseitig eine Alarm-Zeile mit Anker hat (oder den Platzhalter). Nie 'Status:'."""
    if not body:
        return False
    i = body.find('id="t4Why">')
    if i < 0:
        return False
    txt = body[i:i + 120]
    if "Status:" in txt:
        return False
    return "Alarm:" in txt

def warte_alarm(timeout=60, schon=None):
    """Mehrfach GET / bis zu timeout s. Akzeptiert 'Alarm:' oder 'Alarm: wird geprüft' an id=t4Why."""
    if schon and _t4why_ok(schon):
        print("GET / Alarm-Zeile schon im ersten 200-Lauf")
        return True, schon
    t0 = time.time()
    last = schon or ""
    while time.time() - t0 < timeout:
        code, body = _get("/", 20)
        if code == "200":
            last = body
            if _t4why_ok(body):
                print("GET / Alarm-Zeile ok nach %.1f s" % (time.time() - t0))
                return True, body
        time.sleep(2)
    print("STOP / ohne Alarm-Zeile (id=t4Why mit Alarm:, nicht Status:) innerhalb %s s" % timeout)
    return False, last

def warte_bereit(timeout=150):
    """Wartet auf das erste Voll-Update (sysBoot). Bis dahin liefert der Dienst bei manchen Seiten (/, /system, /umwelt, /energie, /speicher)
    mit 200 nur den Ladehinweis 'Dashboard startet' ohne Navigation - an diesem Zustand misst man kein Layout."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        code, body = _get("/api/sysboot/status", 8)
        if code == "200":
            try:
                st = json.loads(body)
            except ValueError:
                st = None
            if isinstance(st, dict) and st.get("loading") is False:
                print("Dashboard bereit nach %.0f s (erstes Voll-Update fertig)" % (time.time() - t0))
                return True
        elif code == "404":
            c2, b2 = _get("/", 15)
            if c2 == "200" and 'id="sbLoading"' not in b2:
                print("Dashboard bereit nach %.0f s" % (time.time() - t0))
                return True
        time.sleep(3)
    print("Hinweis: Dashboard nach %d s noch im Start (Ladehinweis) - Seiteninhalt wird nicht bewertet; spaeter pruefen: curl -s %s/api/sysboot/status" % (timeout, URL))
    return False

def warte_airband(timeout=45):
    """rtl_airband muss nach dem Neustart von prepper-sdr wieder laufen."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            r = subprocess.run(["pgrep", "-a", "rtl_airband"], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            r = None
        if r is not None and r.returncode == 0 and (r.stdout or "").strip():
            zeile = (r.stdout or "").strip().splitlines()[0]
            zeile = re.sub(r"[0-9]{8,}", "***", zeile)[:120]
            print("rtl_airband laeuft nach %.1f s: %s" % (time.time() - t0, zeile))
            return True
        time.sleep(2)
    print("STOP rtl_airband laeuft nicht innerhalb %s s" % timeout)
    return False


def live_extra(seiten):
    body = seiten.get("/api/sdr/usbw")
    if body is None:
        print("STOP /api/sdr/usbw fehlt in der Live-Pruefung")
        return False
    try:
        d = json.loads(body)
    except ValueError:
        print("STOP /api/sdr/usbw kein JSON")
        return False
    if not isinstance(d, dict):
        print("STOP /api/sdr/usbw unerwartete Antwort")
        return False
    print("/api/sdr/usbw: 200, JSON ok")
    return True


def pruefe_live(seit, vorher, root=BASIS):
    ok, seiten = warte_200(["/", "/pi", "/adsb"] + [p for p in API_KERN if p == "/api/sdr/usbw"], 45)
    if not ok:
        return False
    pflicht = [p for p in (SEITEN_ALLE + API_KERN) if p not in seiten]
    ok2, mehr = warte_200(pflicht, 60) if pflicht else (True, {})
    seiten.update(mehr)
    if not ok2:
        print("STOP eine Seite oder Kern-API antwortet nicht mit 200")
        ok = False
    weich = [p for p in API_WEICH if p not in seiten]
    if weich:
        ok3, mehr = warte_200(weich, 180, pflicht=False)
        seiten.update(mehr)
        if not ok3:
            print("Hinweis: %s nach 180 s nicht 200 (vermutlich 433-Empfaenger nach prepper-sdr-Neustart) - kein Rollback" % ", ".join(weich))
    rest = [p for p in API_LESEN if p not in seiten and p not in API_WEICH]
    muss = [p for p in rest if vorher.get("codes", {}).get(p) == "200"]
    nur_h = [p for p in rest if vorher.get("codes", {}).get(p) != "200"]
    if muss:
        ok4, mehr = warte_200(muss, 60)
        seiten.update(mehr)
        if not ok4:
            print("STOP eine vorher erreichbare API antwortet nicht mehr mit 200")
            ok = False
    if nur_h:
        ok5, mehr = warte_200(nur_h, 30, pflicht=False)
        seiten.update(mehr)
        if not ok5:
            print("Hinweis: APIs, die schon vor dem Patch nicht 200 waren, weiterhin nicht 200: %s - kein Rollback" % ", ".join(p for p in nur_h if p not in mehr))
    warte_bereit(int(os.environ.get("FS_BEREIT_WAIT") or 150))
    laed = set()
    for p in list(seiten):
        if 'id="sbLoading"' in seiten[p]:
            code, body = _get(p, 20)
            if code == "200":
                seiten[p] = body
            if 'id="sbLoading"' in seiten[p]:
                laed.add(p)
    if laed:
        print("Hinweis: noch Ladehinweis auf %s - Inhalt dort nicht bewertet" % ", ".join(sorted(laed)))
    sns = echte_seriennummern(root)
    gesamt = 0
    for p, body in seiten.items():
        t = sn_treffer(body, sns)
        gesamt += t
        if t:
            print("STOP %s enthaelt %d echte Seriennummer(n)" % (p, t))
            ok = False
    print("%d Seiten/Antworten geprueft (%d Seriennummern aus der Konfiguration), echte Seriennummern: %d" % (len(seiten), len(sns), gesamt))
    hinweise = []
    fm = [m for m in vorher.get("funk_marker", []) if "/funk" in seiten and "/funk" not in laed and m not in seiten["/funk"]]
    if fm:
        hinweise.append("/funk ohne %s gegenueber vorher" % ", ".join(fm))
    for p, marker in (("/", ("snm-js", "inet-split-js")), ("/pi", ("snm-js", "usbwBox", "pushoverBox")), ("/funk", ("snm-js",)),
                      ("/rundfunk", ("snm-js",)), ("/aprs", ("snm-js",))):
        if p in seiten and p not in laed:
            fehlt = [m for m in marker if m not in seiten[p]]
            if fehlt:
                hinweise.append("%s ohne %s" % (p, ", ".join(fehlt)))
    if "/" in seiten and "/" not in laed and not _t4why_ok(seiten["/"]):
        hinweise.append("/ ohne Alarm-Zeile (t4Why)")
    for p in ("/api/snmask", "/api/inet_split", "/api/t4/status", "/api/sdr/status", "/api/sdr/usbw"):
        if p in seiten:
            try:
                json.loads(seiten[p])
            except ValueError:
                hinweise.append("%s kein gueltiges JSON" % p)
    for h in hinweise:
        print("Hinweis: %s (Layout/Funktion anderer Pakete, kein Rollback-Grund)" % h)
    if not hinweise:
        print("Layout-Marker wie vorher (nur Hinweis-Pruefung)")
    try:
        ok = bool(live_extra(seiten)) and ok
    except Exception as exc:
        print("STOP Paket-Pruefung: %s: %s" % (type(exc).__name__, exc))
        ok = False
    if not warte_airband(45):
        ok = False
    for dienst in (DIENST, DIENST_SDR):
        try:
            zeilen = journal_zeilen(dienst, seit)
            bad = [ln for ln in zeilen if "Traceback" in ln]
            if bad:
                print("STOP Journal %s enthaelt Traceback" % dienst)
                for ln in bad[:6]:
                    print(ln[:160])
                ok = False
            else:
                print("Journal %s ohne Traceback (%d Zeilen)" % (dienst, len(zeilen)))
            if dienst == DIENST:
                if vorher.get("fehler") is None:
                    print("Hinweis: Journal vor dem Neustart nicht lesbar - kein Vergleich neuer FEHLER-Zeilen")
                else:
                    neu_f = sorted(_fehler_keys(zeilen) - vorher["fehler"])
                    if neu_f:
                        print("STOP Journal hat neue FEHLER-/Traceback-Zeilen (nicht vor dem Neustart):")
                        for k in neu_f[:6]:
                            print("  " + k)
                        ok = False
                    else:
                        print("Journal: keine neuen FEHLER-Zeilen gegenueber vor dem Neustart (%d bekannte)" % len(vorher["fehler"]))
                for pflicht in JOURNAL_PFLICHT:
                    if not any(pflicht in ln for ln in zeilen):
                        print("STOP Journal ohne Zeile '%s'" % pflicht)
                        ok = False
                for kennung in JOURNAL_VERBOTEN:
                    if any(kennung in ln for ln in zeilen):
                        print("STOP Journal meldet '%s'" % kennung)
                        ok = False
        except (OSError, subprocess.TimeoutExpired):
            print("STOP Journal %s unlesbar" % dienst)
            ok = False
    code, body = _get("/api/lage_grund", 10)
    if code == "200":
        try:
            print("Lage (Info): %s" % str((json.loads(body).get("lage") or {}).get("text")))
        except ValueError:
            pass
    return ok


def _rueckbau(geaendert, neustart):
    """geaendert: Liste (pfad, alt-bytes)."""
    try:
        for pfad, alt in geaendert:
            schreibe(pfad, alt)
            print("ZURUECKGESETZT %s sha256 %s" % (os.path.basename(pfad), stand(alt)[0]))
        if neustart:
            restart_dienst(DIENST_SDR)
            if restart_dienst(DIENST) == 0:
                warte_200(["/", "/pi"], 45)
    except Exception as exc:
        print("Rueckbau-Fehler: %s - bitte *.bak-%s-* zurueckkopieren" % (exc, KENNUNG))


def _selftest_ff_logik(text):
    """gruppen, lan_ok und Warteschlangen-Anker ohne Geraet pruefen."""
    ns = {}
    stueck = []
    for name in ("NOTFREQUENZ", "ATIS_HZ", "SPANNE_MHZ", "HALB_MHZ"):
        m = re.search(r"^%s = .+" % name, text, re.M)
        if not m:
            raise Stop("selftest flugfunk: %s nicht gefunden" % name)
        stueck.append(m.group(0))
    i = text.index("KANAELE = (")
    j = text.index("\nADSB_URL", i)
    stueck.append(text[i:j])
    for fn, end in (("def gruppen(", "def mitte("), ("def mitte(", "def reihenfolge("),
                    ("def reihenfolge(", "def freq_text("), ("def lan_ok(", "def adsb_pfad(")):
        a = text.index(fn)
        b = text.index(end, a)
        stueck.append(text[a:b])
    exec("\n\n".join(stueck), ns, ns)
    liste = ns["gruppen"]()
    flach = [hz for g in liste for hz, _n in g]
    for hz in (ns["NOTFREQUENZ"], ns["ATIS_HZ"], 128825000, 131540000, 134800000, 135720000):
        assert hz in flach, "Frequenz %s fehlt im Scan" % hz
    atis = [g for g in liste if any(hz == ns["ATIS_HZ"] for hz, _n in g)]
    guard = [g for g in liste if any(hz == ns["NOTFREQUENZ"] for hz, _n in g)]
    assert len(atis) == 1 and len(atis[0]) == 1, "ATIS 123,080 muss allein stehen: %s" % atis
    assert len(guard) == 1 and len(guard[0]) == 1, "Notfrequenz 121,500 muss allein stehen: %s" % guard
    assert all((g[-1][0] - g[0][0]) / 1e6 <= ns["SPANNE_MHZ"] for g in liste)
    assert all(abs(hz - ns["mitte"](g)) / 1e6 <= ns["HALB_MHZ"] for g in liste for hz, _n in g)
    plan = ns["reihenfolge"](liste)
    not_i = next(i for i, g in enumerate(liste) if any(hz == ns["NOTFREQUENZ"] for hz, _n in g))
    andere = [i for i in range(len(liste)) if i != not_i]
    assert all(plan.count(not_i) >= plan.count(i) for i in andere)
    lan = ns["lan_ok"]
    assert lan("192.168.178.20") and lan("127.0.0.1") and lan("::1") and lan("::ffff:127.0.0.1")
    assert lan("::ffff:192.168.178.99")
    assert not lan("") and not lan(None) and not lan("100.64.1.1") and not lan("192.168.1.20") and not lan("10.0.0.1")
    assert "transkript_fehler" in text and "fertig(con, qid)" in text
    return "flugfunk Logik ok (ATIS+Guard allein, lan_ok, Queue-Anker)"


def selftest_extra(raw, neu):
    td = neu["dashboard.py"].decode("utf-8") if neu["dashboard.py"] else raw["dashboard.py"].decode("utf-8")
    ts = neu["prepper_sdr.py"].decode("utf-8") if neu["prepper_sdr.py"] else raw["prepper_sdr.py"].decode("utf-8")
    tf = neu["flugfunk.py"].decode("utf-8") if neu["flugfunk.py"] else raw["flugfunk.py"].decode("utf-8")
    assert "host=\"0.0.0.0\"" not in td[td.index("def _perf_serve"):td.index("def _selftest_perfwsgi")]
    assert "Fallback 127.0.0.1 (kein 0.0.0.0)" in td
    assert '"tcp_bind": "127.0.0.1"' in ts and 'rtl_tcp", "-a", "127.0.0.1"' in ts
    assert '"tcp_bind": "0.0.0.0"' not in ts
    print(_selftest_ff_logik(tf))


def anwenden(root, dry, kein):
    raw, neu = berechne(root)
    aender = [(n, neu[n]) for n in ("dashboard.py", "prepper_sdr.py", "flugfunk.py") if neu[n] is not None]
    if not aender:
        print("schon angewandt (Endstand), nichts zu tun")
        return 0
    for n, data in aender:
        alt = raw[n]
        print("%s %d -> %d Bytes sha256 %s" % (n, len(alt), len(data), sha256(data)))
    print("Neustart: %s, %s" % (DIENST_SDR, DIENST))
    if dry:
        print("dry-run: keine Datei geschrieben, kein Neustart")
        return 0
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    vorher = vorher_stand()
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    geschrieben = []
    try:
        for n, data in aender:
            pfad = os.path.join(root, n)
            bak = sichern(pfad, stempel)
            print("Backup %s" % bak)
        for n, data in aender:
            pfad = os.path.join(root, n)
            compile(data, n, "exec")
            tmpc = tempfile.NamedTemporaryFile(prefix="haertungA-%s-" % n, suffix=".py", delete=False)
            try:
                tmpc.write(data)
                tmpc.close()
                if not pyflakes_vergleich(pfad, tmpc.name):
                    raise Stop("STOP pyflakes %s hat neue Meldungen" % n)
            finally:
                try:
                    os.remove(tmpc.name)
                except OSError:
                    pass
            schreibe(pfad, data)
            geschrieben.append((pfad, raw[n]))
            print("geschrieben %s sha256 %s bytes %d" % (n, stand(data)[0], len(data)))
    except Exception as exc:
        print("STOP Schreiben: %s" % exc)
        if geschrieben:
            _rueckbau(geschrieben, False)
        return 1
    if kein:
        print("kein Neustart (--kein-neustart)")
        print("ok, Dateien geschrieben, Dienste nicht neu gestartet")
        return 0
    rc_s = restart_dienst(DIENST_SDR)
    rc_d = restart_dienst(DIENST)
    if rc_s != 0 or rc_d != 0:
        print("STOP Neustart fehlgeschlagen - Rollback")
        _rueckbau(geschrieben, True)
        return 1
    try:
        live_ok = pruefe_live(seit, vorher, root)
    except Exception as exc:
        print("STOP Live-Pruefung: %s: %s" % (type(exc).__name__, exc))
        live_ok = False
    if not live_ok:
        print("STOP Live-Pruefung fehlgeschlagen - Rollback")
        _rueckbau(geschrieben, True)
        return 1
    print("ok, Dienste: %s, %s" % (DIENST, DIENST_SDR))
    return 0


def selftest(basis=BASIS):
    try:
        assert _restart_ok(1, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "11", "ts": "B", "active": "active"}) is False
        assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "10", "ts": "A", "active": "active"}) is False
        assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "11", "ts": "B", "active": "active"}) is True
        print("selftest Neustart-Check ok")
        raw = basis_pruefen(basis)
        td = patch_dash(raw["dashboard.py"].decode("utf-8"))
        assert patch_dash(td) == td, "dashboard nicht idempotent"
        assert stand(td.encode("utf-8")) == DASH_ENDE, "Endhash dashboard %s" % stand(td.encode("utf-8"))[0][:16]
        print("selftest dashboard Endhash ok %s" % DASH_ENDE[0][:16])
        ts = patch_sdr(raw["prepper_sdr.py"].decode("utf-8"))
        assert patch_sdr(ts) == ts, "prepper_sdr nicht idempotent"
        assert stand(ts.encode("utf-8")) == SDR_ENDE, "Endhash prepper_sdr %s" % stand(ts.encode("utf-8"))[0][:16]
        print("selftest prepper_sdr Endhash ok %s" % SDR_ENDE[0][:16])
        tf = patch_ff(raw["flugfunk.py"].decode("utf-8"))
        assert patch_ff(tf) == tf, "flugfunk nicht idempotent"
        print("selftest flugfunk Endhash %s bytes %d (Live-Endhash, kein fester Soll-Hash)" % stand(tf.encode("utf-8")))
        compile(td, "dashboard.py", "exec")
        compile(ts, "prepper_sdr.py", "exec")
        compile(tf, "flugfunk.py", "exec")
        print("selftest compile ok")
        neu = {"dashboard.py": td.encode("utf-8"), "prepper_sdr.py": ts.encode("utf-8"), "flugfunk.py": tf.encode("utf-8")}
        selftest_extra(raw, neu)
        for name in ("snMask aktiv:", "def _psh_cfg_sauber", "def _fs4_t4_after", "usbwache Anzeige:"):
            assert name in td, "Erhaltenes fehlt: %s" % name
        print("selftest Paket ok")
    except Exception as exc:
        import traceback
        traceback.print_exc()
        print("STOP selftest FEHLER: %s" % exc)
        return 1
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    args = parser.parse_args(argv)
    try:
        if args.selftest:
            return selftest(args.basis)
        return anwenden(args.basis, args.dry_run, args.kein_neustart)
    except Stop as exc:
        print(str(exc))
        return 2
    except Exception as exc:
        print("STOP unerwarteter Fehler: %s: %s" % (type(exc).__name__, exc))
        return 9


if __name__ == "__main__":
    sys.exit(main())
