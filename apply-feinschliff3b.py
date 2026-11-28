#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-feinschliff3b: Feinschliff Paket 3b - Pinneberg und ntfy vollstaendig entfernen.

Code: dashboard.py (Kachel-Reste, Route /api/pinneberg, Pushover-Quelle Pinneberg, ntfy-Texte; interne ID ntfyBox heisst jetzt pushoverBox;
zusaetzlich filtert /api/pushover den Schluessel src_pinneberg beim Lesen und Speichern, damit eine abweichende pushover_push.py ihn nicht ausliefert).
prepper_sdr.py (Rollen-Block pinnebergRolle samt Import und Selbsttest; die Flugfunk-Texte und die Flugfunk-Aufteilung bleiben unveraendert).
pushover_push.py wird nicht angefasst (unbekannter Stand auf dem Pi, Schluessel/Token duerfen nicht gelesen oder ausgegeben werden).
Falls pushover.cfg den Eintrag src_pinneberg enthaelt, wird nur dieser Schluessel entfernt (Sicherung, Werte nie ausgegeben).
Dateien: alle *pinneberg*- und *ntfy*-Dateien im Dashboard-Ordner (auch Sicherungen und __pycache__) werden NICHT geloescht, sondern nach
<Ordner>/archiv-pinneberg-ntfy-<Zeitstempel>/ verschoben (mit ARCHIV-MANIFEST.txt). Das Archiv ist Teil des Rueckbaus.
Vorher: Pruefung, dass kein verbleibendes *.py (ausser Sicherungen und apply-*) pinneberg_*/ntfy_push importiert oder laedt, und dass
prepper_sdr.py ohne diese Module in einer Kopie sauber importiert.
Erhalten bleiben: snMask (Paket 2) und die DSL/Starlink-Trennung (Paket 1). Keine Zeitsperre, keine Firewall-/Mesh-/Shutdown-Aenderung,
keine Seriennummern in der Ausgabe.
Nach dem Schreiben: prepper-sdr neu starten (nur wenn prepper_sdr.py geaendert wurde), Pruefung /api/sdr/status und Sticks, danach
prepper-dashboard neu starten, bis 45 s HTTP 200, alle Seiten. Bei jedem Fehler Rueckbau (Dateien, Archiv, Neustart) und rc != 0.
"""
from __future__ import annotations

import argparse
import fnmatch
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

KENNUNG = "feinschliff3b"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"
DIENST_SDR = "prepper-sdr"
ARCHIV_PRAEFIX = "archiv-pinneberg-ntfy-"
FESTE_SN = ()          # Seriennummern kommen nur aus den Konfigurationsdateien (siehe echte_seriennummern), nie aus dem Skript

DASH_START = ("bfdd36d7dbb9691572b1e31536f4a364c66bfd92a3e04fc768af16508f4a7809", 1438615)
DASH_ENDE = ("d759785cbcd144c87d6e0cc9ffc6fe97304afe2452b931f5ee5626380175effd", 1437729)
SDR_START = ("0d3fc5b4eacd0bbc3c6e0a9c42744894dfb29efc6f87163e869a0f6fee3b8f9a", 825150)
SDR_ENDE = ("ad62d9a56c6aa682246945bae7b65eaa75afb216b5a20dd1d4881ea42cc0d85c", 820331)
PSH_CFG = "pushover.cfg"


# ----------------------------------------------------------------- Hilfen
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


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise Stop("STOP %s: Anker %d mal gefunden, erwartet %d" % (name, c, n))
    return text.replace(alt, neu)


def scheibe_ersetzen(text, start, ende, neu, name):
    """Text von start (inklusive) bis ende (inklusive) durch neu ersetzen; beide Anker genau einmal."""
    if text.count(start) != 1:
        raise Stop("STOP %s: Startanker %d mal" % (name, text.count(start)))
    i = text.find(start)
    j = text.find(ende, i)
    if j < 0 or text.count(ende) != 1:
        raise Stop("STOP %s: Endanker %d mal" % (name, text.count(ende)))
    return text[:i] + neu + text[j + len(ende):]





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
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            continue
        err = (r.stderr or "") + (r.stdout or "")
        if "No module named" in err or "command not found" in err:
            continue
        if r.returncode == 0 and not err.strip():
            print("pyflakes %s ok" % os.path.basename(pfad))
            return True
        print("pyflakes %s:\n%s" % (os.path.basename(pfad), err.strip()[:800]))
        return False
    print("Hinweis: pyflakes nicht installiert, nur compile")
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
    print("systemctl rc %s, Zustand %s PID %s -> %s" % (gesehen, after.get("active") or "?", before.get("pid") or "-", after.get("pid") or "-"))
    return gesehen if gesehen != 0 else 1



URL = "http://127.0.0.1:5000"


def _get(pfad, timeout=6):
    """(Statuscode als str, Body) ueber curl; Fehler -> ('000', '')."""
    ziel = tempfile.mktemp(prefix="apply-feinschliff1-")
    try:
        r = subprocess.run(["curl", "-sS", "-m", str(timeout), "-o", ziel, "-w", "%{http_code}", URL + pfad],
                           capture_output=True, text=True, timeout=timeout + 3)
        code = (r.stdout or "").strip() or "000"
        body = ""
        if os.path.isfile(ziel):
            body = open(ziel, encoding="utf-8", errors="replace").read()
        return code, body
    except (OSError, subprocess.TimeoutExpired):
        return "000", ""
    finally:
        try:
            os.remove(ziel)
        except OSError:
            pass


def warte_200(pfade, timeout=45):
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
        print("STOP %s nicht 200 innerhalb %s s" % (p, timeout))
    return (not offen), seiten


def echte_seriennummern(root):
    """Alle Seriennummern aus den Konfigurations-/Statusdateien plus die festen. Werte werden nie ausgegeben."""
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
                if isinstance(ks, str) and re.fullmatch(r"stick[0-9]+", ks) and isinstance(v, (str, int)):
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



# ----------------------------------------------------------------- Anker und Patches
def _dash_ohne_filter(text):
    """Quelltext ohne die Filterfunktion _psh_cfg_sauber (dort steht src_pinneberg absichtlich)."""
    start = "def _psh_cfg_sauber("
    i = text.find(start)
    if i < 0:
        return text
    j = text.find("\ndef _psh_api(", i)
    if j < 0:
        return text
    return text[:i] + text[j + 1:]


def _kein_rest(text, name):
    pruef = _dash_ohne_filter(text) if name == "dashboard.py" else text
    low = pruef.lower()
    if "pinneberg" in low or "ntfy" in low:
        raise Stop("STOP %s: nach dem Patch steht noch pinneberg/ntfy im Code" % name)


# ---- dashboard.py
D_API_ALT = (
    "# ===== flugfunk: Kachel ersetzt Pinneberg. Hoeren nur im LAN. Kein Mesh. =====\n"
    "def _pn_api():\n"
    "    from flask import jsonify\n"
    "    return jsonify({\"txt\": \"Pinneberg aus\", \"messages\": []})\n"
    "\n"
    "\n"
    "def _ff_api():\n"
)
D_API_NEU = (
    "# ===== flugfunk: Kachel, Hoeren nur im LAN. Kein Mesh. =====\n"
    "def _ff_api():\n"
)
D_KARTE_ALT = ' and "ffPush" in _ff.KARTE and "Pinneberg" not in _ff.KARTE\n'
D_KARTE_NEU = ' and "ffPush" in _ff.KARTE\n'
D_ROUTE_ALT = (
    '    if "app" in globals() and not any(getattr(r, "rule", "") == "/api/pinneberg" for r in app.url_map.iter_rules()):\n'
    '        app.add_url_rule("/api/pinneberg", endpoint="pn_status", view_func=_pn_api, methods=["GET"])\n'
)
D_AFTER_ALT = '        funcs[:] = [f for f in funcs if getattr(f, "__name__", "") != "_pn_after"]\n'
D_SAMPLE_ALT = (
    '    if cfg.get("src_pinneberg") == "1":\n'
    '        try:\n'
    '            import pinneberg_rx as _rx\n'
    '            box = _rx.recent(_psh_os.path.join(_SDR_BASE, _rx.DB_NAME))\n'
    '            if box.get("empfang"):\n'
    '                out.append(("pinneberg", str(box.get("txt") or "")[:120]))\n'
    '        except Exception:\n'
    '            pass\n'
)
D_LABEL_ALT = '    \'<label><input type="checkbox" id="pshPin"> Pinneberg-Meldung</label>\'\n'
D_FILL_ALT = 'g("pshPin").checked=bit(c.src_pinneberg);'
D_BODY_ALT = 'src_pinneberg:g("pshPin").checked?"1":"0",'
D_ASSERT_PIN_ALT = ' and \'id="pshPin"\' in _PSH_CARD'
D_ASSERT_NTFY_ALT = '    assert "ntfy.sh" not in _PSH_CARD and '
D_ASSERT_NTFY_NEU = '    assert '
D_THREAD_ALT = '    if _psh_os.environ.get("NTFY_NO_THREAD") != "1" and _psh_os.environ.get("PUSHOVER_NO_THREAD") != "1":\n'
D_THREAD_NEU = '    if _psh_os.environ.get("PUSHOVER_NO_THREAD") != "1":\n'
D_FUA_ALT = (
    '    text = text.replace("Pinneberg: kein Empfang", "Flugfunk")\n'
    '    text = text.replace("Pinneberg reserviert, Empfang nicht gestartet", "Flugfunk")\n'
)
D_FUA_ASSERT_ALT = '    assert "Pinneberg" not in _fua_phrase("Stick 2 · Hobby: 433 fest · Stick 3 · Hobby: APRS fest", "Flugfunk")\n'
D_HB_TXT_ALT = "Kachel vor ntfy)"
D_HB_TXT_NEU = "Kachel vor Pushover)"
D_BOX_ALT = "ntfyBox"
D_BOX_NEU = "pushoverBox"
D_BOX_N = 9
D_PSH_API_ALT = (
    "def _psh_api():\n"
    "    from flask import jsonify, request\n"
    "    path = _PSH.cfg_path\n"
    "    if request.method != \"POST\":\n"
    "        if request.method == \"GET\":\n"
    "            return jsonify({\"ok\": True, \"cfg\": _psh.public(_psh.load_cfg(path))})\n"
    "        return jsonify({\"ok\": False, \"error\": \"nur POST\"}), 405\n"
    "    if not require_same_origin(request, \"X-Pushover\", True):\n"
    "        return jsonify({\"ok\": False, \"error\": \"nur lokal\"}), 403\n"
    "    body = request.get_json(silent=True) or {}\n"
    "    shown = _psh.save(path, body)\n"
    "    if shown is None:\n"
    "        return jsonify({\"ok\": False, \"error\": \"Schluessel ungueltig\", \"cfg\": _psh.public(_psh.load_cfg(path))}), 400\n"
    "    if body.get(\"test\") is True:\n"
    "        if shown.get(\"enabled\") != \"1\":\n"
    "            return jsonify({\"ok\": True, \"cfg\": shown, \"sent\": False, \"why\": \"aus\"})\n"
    "        if not shown.get(\"user_set\") or not shown.get(\"token_set\"):\n"
    "            return jsonify({\"ok\": True, \"cfg\": shown, \"sent\": False, \"why\": \"schluessel\"})\n"
    "        sent = bool(_PSH.push(\"test\", \"Test vom Lage-Dashboard\"))\n"
    "        if sent:\n"
    "            _PSH.flush()\n"
    "        return jsonify({\"ok\": True, \"cfg\": shown, \"sent\": sent})\n"
    "    return jsonify({\"ok\": True, \"cfg\": shown})\n"
)
D_PSH_API_NEU = (
    "def _psh_cfg_sauber(cfg):\n"
    "    \"\"\"src_pinneberg weder anzeigen noch uebernehmen. pushover_push.py bleibt unangetastet.\"\"\"\n"
    "    if not isinstance(cfg, dict):\n"
    "        return cfg\n"
    "    out = dict(cfg)\n"
    "    out.pop(\"src_pinneberg\", None)\n"
    "    return out\n"
    "\n"
    "\n"
    "def _psh_api():\n"
    "    from flask import jsonify, request\n"
    "    path = _PSH.cfg_path\n"
    "    if request.method != \"POST\":\n"
    "        if request.method == \"GET\":\n"
    "            return jsonify({\"ok\": True, \"cfg\": _psh_cfg_sauber(_psh.public(_psh.load_cfg(path)))})\n"
    "        return jsonify({\"ok\": False, \"error\": \"nur POST\"}), 405\n"
    "    if not require_same_origin(request, \"X-Pushover\", True):\n"
    "        return jsonify({\"ok\": False, \"error\": \"nur lokal\"}), 403\n"
    "    body = request.get_json(silent=True) or {}\n"
    "    if isinstance(body, dict):\n"
    "        body = _psh_cfg_sauber(body)\n"
    "    shown = _psh.save(path, body)\n"
    "    if shown is None:\n"
    "        return jsonify({\"ok\": False, \"error\": \"Schluessel ungueltig\", \"cfg\": _psh_cfg_sauber(_psh.public(_psh.load_cfg(path)))}), 400\n"
    "    shown = _psh_cfg_sauber(shown)\n"
    "    if body.get(\"test\") is True:\n"
    "        if shown.get(\"enabled\") != \"1\":\n"
    "            return jsonify({\"ok\": True, \"cfg\": shown, \"sent\": False, \"why\": \"aus\"})\n"
    "        if not shown.get(\"user_set\") or not shown.get(\"token_set\"):\n"
    "            return jsonify({\"ok\": True, \"cfg\": shown, \"sent\": False, \"why\": \"schluessel\"})\n"
    "        sent = bool(_PSH.push(\"test\", \"Test vom Lage-Dashboard\"))\n"
    "        if sent:\n"
    "            _PSH.flush()\n"
    "        return jsonify({\"ok\": True, \"cfg\": shown, \"sent\": sent})\n"
    "    return jsonify({\"ok\": True, \"cfg\": shown})\n"
)


def schon_dash(text):
    return (
        "def _psh_cfg_sauber(" in text
        and 'id="pushoverBox"' in text
        and "def _pn_api(" not in text
        and "ntfy" not in text.lower()
        and "pinneberg" not in _dash_ohne_filter(text).lower()
    )


def patch_dash(text):
    if schon_dash(text):
        return text
    if "def _pn_api(" not in text or 'id="ntfyBox"' not in text:
        raise Stop("STOP dashboard.py: Basis feinschliff2 erwartet (_pn_api / ntfyBox fehlen)")
    t = ersetze(text, D_API_ALT, D_API_NEU, "dash _pn_api")
    t = ersetze(t, D_KARTE_ALT, D_KARTE_NEU, "dash KARTE-Test")
    t = ersetze(t, D_ROUTE_ALT, "", "dash Route /api/pinneberg")
    t = ersetze(t, D_AFTER_ALT, "", "dash _pn_after")
    t = ersetze(t, D_SAMPLE_ALT, "", "dash Pushover Quelle")
    t = ersetze(t, D_LABEL_ALT, "", "dash Pushover Checkbox")
    t = ersetze(t, D_FILL_ALT, "", "dash Pushover fill")
    t = ersetze(t, D_BODY_ALT, "", "dash Pushover body")
    t = ersetze(t, D_ASSERT_PIN_ALT, "", "dash Test pshPin")
    t = ersetze(t, D_ASSERT_NTFY_ALT, D_ASSERT_NTFY_NEU, "dash Test ntfy.sh")
    t = ersetze(t, D_THREAD_ALT, D_THREAD_NEU, "dash NTFY_NO_THREAD")
    t = ersetze(t, D_FUA_ALT, "", "dash funkAuf Pinneberg-Text")
    t = ersetze(t, D_FUA_ASSERT_ALT, "", "dash funkAuf Test")
    t = ersetze(t, D_HB_TXT_ALT, D_HB_TXT_NEU, "dash hbMesh Text")
    t = ersetze(t, D_BOX_ALT, D_BOX_NEU, "dash ntfyBox", D_BOX_N)
    t = ersetze(t, D_PSH_API_ALT, D_PSH_API_NEU, "dash Pushover-Filter")
    _kein_rest(t, "dashboard.py")
    return t


# ---- prepper_sdr.py
S_HOLD1_ALT = "_hold = _flugfunk_an(self.base) or _pn.engaged(self.base)"
S_HOLD1_NEU = "_hold = _flugfunk_an(self.base)"
S_HOLD2_ALT = '_hold = _flugfunk_an(getattr(pl, "base", None)) or _pn.engaged(getattr(pl, "base", None))'
S_HOLD2_NEU = '_hold = _flugfunk_an(getattr(pl, "base", None))'
S_TEST_START = "        # pinnebergRolle Stufe 1: Datei an -> Stick 3 reserviert und still"
S_TEST_END = '        os.remove(os.path.join(tmp, "pinneberg_rolle.json"))\n'
S_BLK_START = "# ===== pinnebergRolle Stufe 1: Stick 3 nur reservieren"
S_BLK_END = "Planner.start = _pn_start\n"
S_BLK_NEU = '''# ===== flugfunkAnzeige: Stick-3-Text und Aufteilung bei Flugfunk (Verhalten wie bisher ohne Rollendatei) =====
_ffa_orig_sfx = _s3e_mode_sfx
_ffa_orig_split = _s3e_split


def _flugfunk_an(base):
    try:
        import flugfunk as _ffx
        return bool(_ffx.engaged(base))
    except Exception:
        return False


def _s3e_split(m, now=None):
    sp = _ffa_orig_split(m, now)
    try:
        if not sp:
            return sp
        base = getattr(m, "base", None)
        if _flugfunk_an(base):
            if sp.get("mode") == "s2":
                return dict(sp, txt="%s bleibt bei 433. %s: Flugfunk" % (_s3e_lb(3), _s3e_lb(S3E_SLOT)))
            if sp.get("mode") == "geteilt":
                return dict(sp, txt="%s: 433 fest · %s: Flugfunk" % (_s3e_lb(3), _s3e_lb(S3E_SLOT)))
    except Exception as ex:
        print("flugfunk split:", ex, flush=True)
    return sp


def _s3e_mode_sfx(pl):
    try:
        if _flugfunk_an(getattr(pl, "base", None)) and _s3e_is_h2(pl):
            return " · Flugfunk"
        return _ffa_orig_sfx(pl)
    except Exception:
        return _ffa_orig_sfx(pl)
'''


def schon_sdr(text):
    low = text.lower()
    return "pinneberg" not in low and "def _flugfunk_an(" in text and "_ffa_orig_split" in text


def patch_sdr(text):
    if schon_sdr(text):
        return text
    if "import pinneberg_rolle as _pn" not in text:
        raise Stop("STOP prepper_sdr.py: Basis erwartet (pinnebergRolle fehlt)")
    t = ersetze(text, S_HOLD1_ALT, S_HOLD1_NEU, "sdr Hold 1")
    t = ersetze(t, S_HOLD2_ALT, S_HOLD2_NEU, "sdr Hold 2")
    t = scheibe_ersetzen(t, S_TEST_START, S_TEST_END, "", "sdr Selbsttest Rolle")
    t = scheibe_ersetzen(t, S_BLK_START, S_BLK_END, S_BLK_NEU, "sdr Rollen-Block")
    low = t.lower()
    if "pinneberg" in low or re.search(r"\b_pn\b|\b_pn_", t):
        raise Stop("STOP prepper_sdr.py: nach dem Patch stehen noch Pinneberg-Reste")
    return t


# ----------------------------------------------------------------- Dateien und Stand
def _dateien():
    return (
        ("dashboard.py", DASH_START, DASH_ENDE, patch_dash, True),
        ("prepper_sdr.py", SDR_START, SDR_ENDE, patch_sdr, True),
    )


def berechne(root):
    """Liste von (name, pfad, alt_bytes, neu_bytes|None). Stop bei unbekanntem Stand einer Pflichtdatei."""
    out = []
    for name, start, ende, patch, pflicht in _dateien():
        pfad = os.path.join(root, name)
        if not os.path.isfile(pfad):
            if pflicht:
                raise Stop("STOP %s fehlt" % pfad)
            print("Hinweis: %s fehlt, wird uebersprungen" % name)
            continue
        alt = open(pfad, "rb").read()
        ist = stand(alt)
        print("%s sha16 %s bytes %d" % (name, ist[0][:16], ist[1]))
        if ist == ende:
            out.append((name, pfad, alt, None))
            continue
        if ist != start:
            if pflicht:
                raise Stop("STOP %s Hash %s/%d, erwartet %s/%d (Paket-2-Stand) oder Endstand %s/%d" % (
                    name, ist[0][:16], ist[1], start[0][:16], start[1], ende[0][:16], ende[1]))
            if "pinneberg" in alt.decode("utf-8", "replace").lower():
                print("Hinweis: %s hat einen unbekannten Stand und enthaelt noch den Pinneberg-Schluessel - bleibt unveraendert" % name)
            out.append((name, pfad, alt, None))
            continue
        neu = patch(alt.decode("utf-8")).encode("utf-8")
        hs = stand(neu)
        if hs != ende:
            raise Stop("STOP %s Endhash %s/%d, erwartet %s/%d" % (name, hs[0][:16], hs[1], ende[0][:16], ende[1]))
        compile(neu, name, "exec")
        out.append((name, pfad, alt, neu))
    return out


# ----------------------------------------------------------------- Archiv
def archiv_kandidaten(root):
    """[(unterordner, name)] aller *pinneberg*/*ntfy*-Dateien (nur Dateien, kein Ordner), auch in __pycache__."""
    out = []
    for sub in ("", "__pycache__"):
        d = os.path.join(root, sub) if sub else root
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            p = os.path.join(d, n)
            if not (os.path.isfile(p) or os.path.islink(p)):
                continue
            if not sub and (n.startswith("archiv-") or n.startswith("apply-" + KENNUNG)):
                continue
            low = n.lower()
            if fnmatch.fnmatchcase(low, "*pinneberg*") or fnmatch.fnmatchcase(low, "*ntfy*"):
                out.append((sub, n))
    return out


def verschiebe(root, kandidaten, stempel):
    """Verschiebt nach <root>/archiv-pinneberg-ntfy-<stempel>/. Gibt (archivordner, [(quelle, ziel)]) zurueck."""
    arch = os.path.join(root, ARCHIV_PRAEFIX + stempel)
    os.makedirs(arch)
    try:
        st = os.stat(root)
        os.chown(arch, st.st_uid, st.st_gid)
    except OSError:
        pass
    moved = []
    try:
        for sub, n in kandidaten:
            quelle = os.path.join(root, sub, n) if sub else os.path.join(root, n)
            zdir = os.path.join(arch, sub) if sub else arch
            if sub and not os.path.isdir(zdir):
                os.makedirs(zdir)
                try:
                    os.chown(zdir, st.st_uid, st.st_gid)
                except OSError:
                    pass
            ziel = os.path.join(zdir, n)
            if not os.path.lexists(quelle):
                continue
            shutil.move(quelle, ziel)
            moved.append((quelle, ziel))
        zeilen = []
        for quelle, ziel in moved:
            try:
                zeilen.append("%s\t%d\t%s" % (os.path.relpath(quelle, root), os.path.getsize(ziel), sha256(open(ziel, "rb").read())[:16]))
            except OSError:
                zeilen.append("%s\t?\t?" % os.path.relpath(quelle, root))
        mf = os.path.join(arch, "ARCHIV-MANIFEST.txt")
        with open(mf, "w", encoding="utf-8") as fh:
            fh.write("# %s: %d Dateien aus %s (Zurueck: Datei an den alten Ort verschieben)\n" % (KENNUNG, len(moved), root))
            fh.write("\n".join(zeilen) + ("\n" if zeilen else ""))
        try:
            os.chown(mf, st.st_uid, st.st_gid)
        except OSError:
            pass
    except Exception:
        zurueckholen(moved, arch)
        raise
    return arch, moved


def zurueckholen(moved, arch):
    n = 0
    for quelle, ziel in reversed(moved):
        try:
            if os.path.lexists(ziel) and not os.path.lexists(quelle):
                os.replace(ziel, quelle)
                n += 1
        except OSError as exc:
            print("Rueckbau-Fehler Archiv %s: %s" % (os.path.basename(ziel), exc))
    try:
        mf = os.path.join(arch, "ARCHIV-MANIFEST.txt")
        if os.path.isfile(mf):
            os.remove(mf)
        for dp, dn, fn in sorted(os.walk(arch), key=lambda x: -len(x[0])):
            if not os.listdir(dp):
                os.rmdir(dp)
    except OSError:
        pass
    if n:
        print("ZURUECKGESETZT Archiv: %d Dateien am alten Ort" % n)
    return n


# ----------------------------------------------------------------- Abhaengigkeiten
RX_IMPORT = re.compile(r"\b(?:import|from)\b[^\n#]*\b(?:pinneberg_\w+|ntfy_push)\b")
RX_LADEN = re.compile(r"""["'][^"'\n]*\b(?:pinneberg_\w+|ntfy_push)(?:\.py)?\b[^"'\n]*["']""")
RX_SYSTEM = re.compile(r"pinneberg|ntfy_push", re.I)


def scan_abhaengig(root, texte, zu_archiv):
    """Zeilen (Datei:Nr: Text) in verbleibenden *.py, die pinneberg_*/ntfy_push importieren oder als Datei laden.
    texte: name -> neuer Quelltext der geaenderten Dateien. Sicherungen (.bak-*), apply-*.py und die zu archivierenden Dateien zaehlen nicht."""
    arch = set(n for sub, n in zu_archiv if not sub)
    hits = []
    for n in sorted(os.listdir(root)):
        if not n.endswith(".py") or n in arch or n.startswith("apply-") or n.startswith("."):
            continue
        p = os.path.join(root, n)
        if not os.path.isfile(p):
            continue
        if n in texte:
            text = texte[n]
        else:
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
        for i, ln in enumerate(text.split("\n"), 1):
            c = ln.split("#", 1)[0]
            if RX_IMPORT.search(c) or RX_LADEN.search(c):
                hits.append("%s:%d: %s" % (n, i, ln.strip()[:110]))
    return hits


def scan_system():
    """Systemd-Units und Cron-Dateien, die pinneberg_*/ntfy_push nennen."""
    hits = []
    pfade = []
    for d in ("/etc/systemd/system", "/etc/cron.d", "/etc/cron.hourly", "/etc/cron.daily"):
        try:
            for n in sorted(os.listdir(d)):
                pfade.append(os.path.join(d, n))
        except OSError:
            pass
    pfade.append("/etc/crontab")
    for p in pfade:
        try:
            if not os.path.isfile(p) or os.path.getsize(p) > 200000:
                continue
            for i, ln in enumerate(open(p, encoding="utf-8", errors="replace").read().split("\n"), 1):
                if RX_SYSTEM.search(ln):
                    hits.append("%s:%d: %s" % (p, i, ln.strip()[:110]))
        except OSError:
            pass
    return hits


def import_probe(root, sdr_text):
    """prepper_sdr.py (neuer Stand) in einer Kopie ohne pinneberg_*/ntfy_push importieren. Rueckgabe (ok, Text). Kein Zugriff auf echte Daten."""
    tmp = tempfile.mkdtemp(prefix="feinschliff3-imp-")
    try:
        for n in os.listdir(root):
            p = os.path.join(root, n)
            if n.endswith(".py") and os.path.isfile(p) and not n.startswith("apply-") and "pinneberg" not in n.lower() and "ntfy" not in n.lower():
                shutil.copy2(p, os.path.join(tmp, n))
        with open(os.path.join(tmp, "prepper_sdr.py"), "w", encoding="utf-8") as fh:
            fh.write(sdr_text)
        code = (
            "import sys\n"
            "import prepper_sdr as m\n"
            "bad = [k for k in sys.modules if k.startswith('pinneberg') or k.startswith('ntfy')]\n"
            "assert not bad, bad\n"
            "assert callable(m._flugfunk_an) and callable(m._s3e_split) and callable(m._s3e_mode_sfx)\n"
            "for a in ('start', 'want', 'lage_apply', 'bc_queue', 'cal_due'):\n"
            "    assert callable(getattr(m.Planner, a)), a\n"
            "print('import ok')\n"
        )
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        r = subprocess.run([sys.executable, "-c", code], cwd=tmp, env=env, capture_output=True, text=True, timeout=120)
        ok = r.returncode == 0 and "import ok" in (r.stdout or "")
        return ok, ((r.stdout or "") + (r.stderr or "")).strip()[-600:]
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, "%s: %s" % (type(exc).__name__, exc)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ----------------------------------------------------------------- pushover.cfg: nur src_pinneberg entfernen, Werte nie ausgeben
def _cfg_lesen(pfad):
    """JSON-Objekt oder None. Inhalt wird nie ausgegeben."""
    try:
        with open(pfad, encoding="utf-8") as fh:
            raw = json.load(fh)
        return raw if isinstance(raw, dict) else None
    except Exception:
        return None


def cfg_plan(root):
    """(pfad, alt_bytes, neu_bytes) oder None. Nur wenn src_pinneberg vorkommt. Werte stehen nicht in der Ausgabe."""
    pfad = os.path.join(root, PSH_CFG)
    if not os.path.isfile(pfad):
        print("Hinweis: %s nicht vorhanden, nichts zu entfernen" % PSH_CFG)
        return None
    raw = _cfg_lesen(pfad)
    if raw is None:
        print("Hinweis: %s nicht als JSON-Objekt lesbar, bleibt unveraendert" % PSH_CFG)
        return None
    if "src_pinneberg" not in raw:
        print("%s: kein Eintrag src_pinneberg" % PSH_CFG)
        return None
    neu = dict(raw)
    neu.pop("src_pinneberg", None)
    alt = open(pfad, "rb").read()
    daten = (json.dumps(neu, ensure_ascii=True, sort_keys=True) + "\n").encode("utf-8")
    print("%s: Eintrag src_pinneberg wird entfernt (einen Schluessel, Werte nicht ausgegeben)" % PSH_CFG)
    return pfad, alt, daten

SEITEN_KERN = ["/", "/pi", "/system", "/umwelt", "/aprs", "/rundfunk", "/funk"]
SEITEN_MEHR = ["/energie", "/lokale-energie", "/speicher", "/luft", "/pegel", "/adsb", "/zuhause", "/mesh", "/mesh2", "/news",
               "/karte", "/medizin", "/funk433", "/meteor", "/dabhist", "/lage"]
API_LESEN = ["/api/sdr/status", "/api/sdr/ui", "/api/sdr/wd", "/api/sdr/live", "/api/broadcast", "/api/t2/status", "/api/t4/status",
             "/api/sdr/usbw", "/api/snmask", "/api/aprs", "/api/funk433", "/api/sdr/activity", "/api/sdr/noise", "/api/uplink",
             "/api/inet_split", "/api/broadcast/events", "/api/pushover", "/api/flugfunk"]
ENTFERNT_404 = ["/umwelt2", "/decoder", "/scanner", "/api/pinneberg"]
RX_REST = re.compile(r"pinneberg|ntfy", re.I)
# Code-Kennungen: ein Treffer darauf kann nicht aus Daten stammen -> Rueckbau
RX_CODE = re.compile(r"ntfyBox|pshPin|/api/pinneberg|src_pinneberg", re.I)


def treffer_info(text):
    """(Anzahl, Code-Treffer, erstes Beispiel)"""
    ms = list(RX_REST.finditer(text))
    code = [m for m in ms if RX_CODE.search(text[max(0, m.start() - 12): m.end() + 24])]
    bsp = ""
    if ms:
        m = ms[0]
        bsp = " ".join(text[max(0, m.start() - 40): m.end() + 40].split())
    return len(ms), len(code), bsp


def vorher_stand():
    """Zustand der laufenden Dienste vor der Aenderung: Seitencodes, Treffer, SDR-Schnappschuss. Nur lesen."""
    codes, treffer = {}, {}
    sdr = None
    for p in SEITEN_KERN + SEITEN_MEHR:
        code, body = _get(p, 12)
        codes[p] = code
        if code == "200":
            treffer[p] = treffer_info(body)[0]
    code, body = _get("/api/sdr/status", 10)
    if code == "200":
        sdr = sdr_snapshot(body)
    return {"codes": codes, "treffer": treffer, "sdr": sdr}


def sdr_snapshot(body):
    try:
        d = json.loads(body)
    except ValueError:
        return None
    st = d.get("status") if isinstance(d, dict) else None
    if not isinstance(st, dict):
        return None
    devs = []

    def walk(o, depth=0):
        if depth > 7:
            return
        if isinstance(o, dict):
            if "present" in o and "state" in o and ("kind" in o or "role" in o or "name" in o):
                devs.append((bool(o.get("present")), str(o.get("state"))))
            for v in o.values():
                walk(v, depth + 1)
        elif isinstance(o, list):
            for v in o[:60]:
                walk(v, depth + 1)

    walk(d)
    return {"t": st.get("t"), "sticks_n": st.get("sticks_n"), "err": bool(st.get("err")),
            "present": sum(1 for p, s in devs if p), "aktiv": sum(1 for p, s in devs if s == "aktiv"), "geraete": len(devs)}


def journal_zeilen(dienst, seit):
    r = subprocess.run(["journalctl", "-u", dienst, "--since", seit, "-o", "cat", "-n", "600"],
                       capture_output=True, text=True, timeout=20)
    return (r.stdout or "").splitlines()


def pruefe_sdr(vorher, epoch0, seit, timeout=60):
    """prepper-sdr nach dem Neustart: Dienst aktiv, /api/sdr/status 200 mit frischem Stand, Sticks wie vorher, Journal ohne Traceback."""
    ok = True
    t0 = time.time()
    s = None
    while time.time() - t0 < timeout:
        code, body = _get("/api/sdr/status", 8)
        if code == "200":
            s = sdr_snapshot(body)
            frisch = bool(s) and isinstance(s.get("t"), (int, float)) and s["t"] >= epoch0 - 1
            if frisch:
                gut = True
                if vorher:
                    gut = s["present"] >= vorher["present"] and s["aktiv"] >= vorher["aktiv"]
                    if isinstance(vorher.get("sticks_n"), int) and isinstance(s.get("sticks_n"), int):
                        gut = gut and s["sticks_n"] >= vorher["sticks_n"]
                    if s["err"] and not vorher.get("err"):
                        gut = False
                if gut:
                    break
        time.sleep(3)
    else:
        print("STOP /api/sdr/status nicht frisch/gesund innerhalb %d s (vorher %s, jetzt %s)" % (timeout, vorher, s))
        ok = False
    if ok:
        print("GET /api/sdr/status -> 200 nach %.1f s, Stand frisch, Geraete present %s aktiv %s (vorher %s/%s)" % (
            time.time() - t0, s["present"], s["aktiv"], (vorher or {}).get("present", "?"), (vorher or {}).get("aktiv", "?")))
    try:
        r = subprocess.run(["systemctl", "is-active", DIENST_SDR], capture_output=True, text=True, timeout=8)
        if (r.stdout or "").strip() != "active":
            print("STOP %s nicht active: %s" % (DIENST_SDR, (r.stdout or "").strip()))
            ok = False
        zeilen = journal_zeilen(DIENST_SDR, seit)
        bad = [ln for ln in zeilen if "Traceback" in ln or "ModuleNotFoundError" in ln or "ImportError" in ln]
        if bad:
            print("STOP Journal %s: %s" % (DIENST_SDR, "; ".join(x[:120] for x in bad[:4])))
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (DIENST_SDR, len(zeilen)))
    except (OSError, subprocess.TimeoutExpired):
        print("STOP Journal/Status %s nicht lesbar" % DIENST_SDR)
        ok = False
    return ok


def pruefe_live(seit, vorher, root=BASIS):
    ok, seiten = warte_200(SEITEN_KERN + ["/api/sdr/status", "/api/snmask", "/api/inet_split"], 45)
    if not ok:
        return False
    sns = echte_seriennummern(root)
    print("geprueft gegen %d Seriennummern (inkl. Airspy aus der Konfiguration)" % len(sns))
    gesamt = 0
    n_ok = 0
    treffer_nach = {}
    for p in SEITEN_KERN + SEITEN_MEHR + API_LESEN:
        if p in seiten:
            code, body = "200", seiten[p]
        else:
            code, body = _get(p, 12)
        if code != "200":
            if p in SEITEN_KERN or (vorher["codes"].get(p) == "200"):
                print("STOP %s -> %s (vorher 200)" % (p, code))
                ok = False
            continue
        n_ok += 1
        seiten[p] = body
        t = sn_treffer(body, sns)
        gesamt += t
        if t:
            print("STOP %s enthaelt noch %d echte Seriennummer(n)" % (p, t))
            ok = False
        n, ncode, bsp = treffer_info(body)
        if n:
            treffer_nach[p] = (n, ncode, bsp)
    print("%d Seiten/Antworten geprueft, echte Seriennummern: %d" % (n_ok, gesamt))
    seiten_html = [p for p in SEITEN_KERN + SEITEN_MEHR if p in seiten]
    print("Seiten 200: %d von %d (vorher 200: %d)" % (len(seiten_html), len(SEITEN_KERN + SEITEN_MEHR),
                                                      sum(1 for p in SEITEN_KERN + SEITEN_MEHR if vorher["codes"].get(p) == "200")))
    # Pinneberg/ntfy in den Antworten: Code-Kennungen = Fehler, Textreste aus Daten (z. B. alte Journalzeilen) = Hinweis
    n_html = sum(v[0] for p, v in treffer_nach.items() if p in SEITEN_KERN + SEITEN_MEHR)
    n_code = sum(v[1] for v in treffer_nach.values())
    vor_html = sum(vorher["treffer"].values())
    print("grep -i 'pinneberg|ntfy' ueber %d Seiten-HTMLs: %d Treffer (vorher %d), davon Code-Kennungen: %d" % (len(seiten_html), n_html, vor_html, n_code))
    for p, v in sorted(treffer_nach.items())[:8]:
        print("  Rest %s: %d Treffer, z. B. ...%s..." % (p, v[0], v[2][:100]))
    if n_code:
        print("STOP Code-Kennungen von Pinneberg/ntfy in Antworten")
        ok = False
    for p in ("/", "/pi", "/funk", "/rundfunk", "/aprs"):
        if 'id="snm-js"' not in seiten.get(p, ""):
            print("STOP %s ohne Maskierungs-Skript snm-js" % p)
            ok = False
    for p in ("/", "/pi", "/funk", "/rundfunk", "/aprs"):
        mm = re.search(r'id="sdrPiData">(.*?)</script>', seiten.get(p, ""), re.S)
        if mm:
            try:
                json.loads(mm.group(1))
            except ValueError:
                print("STOP sdrPiData auf %s ist kein gueltiges JSON" % p)
                ok = False
    try:
        st = json.loads(seiten.get("/api/sdr/status") or "null")
        if not (isinstance(st, dict) and "status" in st):
            raise ValueError("Schluessel status fehlt")
        sm = json.loads(seiten.get("/api/snmask") or "null")
        if not (isinstance(sm, dict) and sm.get("aktiv") is True and not sm.get("fehler")):
            raise ValueError("snmask %s" % (sm,))
        print("/api/snmask ok: %s Namen, %s Antworten gefiltert (snMask erhalten)" % (sm.get("anzahl"), sm.get("antworten")))
        sp = json.loads(seiten.get("/api/inet_split") or "null")
        if not (isinstance(sp, dict) and isinstance(sp.get("dsl"), dict) and isinstance(sp.get("sl"), dict)):
            raise ValueError("inet_split ohne dsl/sl")
        print("/api/inet_split ok: DSL und Starlink getrennt (erhalten)")
    except Exception as exc:
        print("STOP /api/sdr/status, /api/snmask oder /api/inet_split: %s" % exc)
        ok = False
    for p in ("/pi", "/system"):
        if 'id="usbwBox"' not in seiten.get(p, ""):
            print("STOP %s ohne usbwBox" % p)
            ok = False
    if 'id="pushoverBox"' not in seiten.get("/pi", "") or 'id="pshPin"' in seiten.get("/pi", ""):
        print("STOP /pi: Pushover-Kachel (pushoverBox) fehlt oder pshPin noch da")
        ok = False
    else:
        print("/pi: Pushover-Kachel ok (pushoverBox, ohne Pinneberg-Haken)")
    try:
        po = json.loads(seiten.get("/api/pushover") or "null")
        if not (isinstance(po, dict) and po.get("ok") is True and isinstance(po.get("cfg"), dict)):
            raise ValueError("Antwort ohne ok/cfg")
        if "src_pinneberg" in po.get("cfg") or "src_pinneberg" in json.dumps(po):
            raise ValueError("src_pinneberg noch in der Antwort")
        print("/api/pushover ok: ohne src_pinneberg (Filter in dashboard.py)")
    except Exception as exc:
        print("STOP /api/pushover: %s" % exc)
        ok = False
    for p in ENTFERNT_404:
        code, _ = _get(p)
        if code != "404":
            print("STOP %s liefert %s, erwartet 404" % (p, code))
            ok = False
    try:
        zeilen = journal_zeilen(DIENST, seit)
        bad = [ln for ln in zeilen if "Traceback" in ln]
        if bad:
            print("STOP Journal %s enthaelt Traceback" % DIENST)
            for ln in bad[:6]:
                print(ln[:160])
            ok = False
        else:
            print("Journal %s ohne Traceback (%d Zeilen)" % (DIENST, len(zeilen)))
        for pflicht in ("snMask aktiv:", "funkFlach aktiv:", "inetSplit aktiv", "usbwache Anzeige:"):
            if not any(pflicht in ln for ln in zeilen):
                print("STOP Journal ohne Zeile '%s'" % pflicht)
                ok = False
        for kennung in ("snMask Selbsttest FEHLER", "snMask FEHLER", "funkFlach FEHLER", "pushoverKachel FEHLER", "flugfunk FEHLER", "hbMesh FEHLER"):
            if any(kennung in ln for ln in zeilen):
                print("STOP Journal meldet '%s'" % kennung)
                ok = False
    except (OSError, subprocess.TimeoutExpired):
        print("STOP Journal %s unlesbar" % DIENST)
        ok = False
    try:
        r = subprocess.run(["pgrep", "-af", r"pinneberg_|ntfy_push"], capture_output=True, text=True, timeout=5)
        if (r.stdout or "").strip():
            print("Hinweis: Prozess mit pinneberg_/ntfy_push laeuft noch: %d Zeile(n)" % len((r.stdout or "").strip().splitlines()))
    except (OSError, subprocess.TimeoutExpired):
        pass
    return ok


# ----------------------------------------------------------------- Anwenden
def _alles_rueckbau(plan, moved, arch, neustart_sdr, neustart_dash, cfg_alt=None):
    """Dateien aus den Originalen, Archiv zurueck, Dienste neu starten."""
    try:
        for name, pfad, alt, neu in plan:
            if neu is not None:
                schreibe(pfad, alt)
                print("ZURUECKGESETZT %s sha256 %s" % (name, stand(alt)[0]))
        if cfg_alt:
            pfad, alt = cfg_alt
            schreibe(pfad, alt)
            print("ZURUECKGESETZT %s (Werte nicht ausgegeben)" % os.path.basename(pfad))
        if arch:
            zurueckholen(moved, arch)
        if neustart_sdr:
            if restart_dienst(DIENST_SDR) == 0:
                time.sleep(5)
        if neustart_dash:
            if restart_dienst(DIENST) == 0:
                warte_200(["/", "/pi"], 45)
    except Exception as exc:
        print("Rueckbau-Fehler: %s - bitte Sicherungen .bak-%s-* zurueckkopieren und das Archiv %s* zurueckverschieben" % (exc, KENNUNG, ARCHIV_PRAEFIX))


def anwenden(root, dry, kein):
    try:
        plan = berechne(root)
        texte = {name: (neu if neu is not None else alt).decode("utf-8") for name, pfad, alt, neu in plan}
        kand = archiv_kandidaten(root)
    except Stop as exc:
        print(exc)
        return 2
    except SyntaxError as exc:
        print("STOP Syntaxfehler im Ergebnis: %s" % exc)
        return 3
    geaendert = [p for p in plan if p[3] is not None]
    cfg = cfg_plan(root)
    if not geaendert and not kand and not cfg:
        print("bereits fertig: Code ohne Pinneberg/ntfy, keine Dateien zum Archivieren, Konfiguration ohne src_pinneberg")
        return 0
    # Abhaengigkeiten pruefen (vor jeder Aenderung)
    hits = scan_abhaengig(root, texte, kand)
    hits += scan_system()
    if hits:
        print("STOP: verbleibender Code oder Dienst laedt pinneberg_*/ntfy_push - nichts veraendert:")
        for h in hits[:20]:
            print("  " + h)
        return 6
    print("Abhaengigkeiten: kein verbleibendes *.py und keine Unit/Cron-Datei importiert oder laedt pinneberg_*/ntfy_push")
    if "prepper_sdr.py" in texte:
        ok, txt = import_probe(root, texte["prepper_sdr.py"])
        if not ok:
            print("STOP Import-Probe prepper_sdr.py ohne pinneberg/ntfy fehlgeschlagen:\n%s" % txt)
            return 7
        print("Import-Probe prepper_sdr.py ohne pinneberg_*/ntfy_push: ok")
    rest = []
    for n in sorted(os.listdir(root)):
        p = os.path.join(root, n)
        if n.endswith(".py") and os.path.isfile(p) and n not in texte and not n.startswith("apply-") and not any(n == k[1] for k in kand):
            try:
                if RX_REST.search(open(p, encoding="utf-8", errors="replace").read()):
                    rest.append(n)
            except OSError:
                pass
    if rest:
        print("Hinweis: weitere Module nennen pinneberg/ntfy (kein Import, bleiben unveraendert): %s" % ", ".join(rest))
    print("Archiv-Ziel: %s<Zeitstempel>/ mit %d Datei(en)" % (os.path.join(root, ARCHIV_PRAEFIX), len(kand)))
    for sub, n in kand:
        print("  verschieben: %s" % (os.path.join(sub, n) if sub else n))
    sdr_neu = any(p[0] == "prepper_sdr.py" and p[3] is not None for p in plan)
    dash_neu = bool(geaendert)
    for name, pfad, alt, neu in geaendert:
        print("%s %d -> %d Bytes sha256 %s" % (name, len(alt), len(neu), sha256(neu)))
    print("Neustart: %s" % (", ".join(([DIENST_SDR] if sdr_neu else []) + ([DIENST] if dash_neu else [])) or "keiner"))
    if dry:
        print("dry-run: keine Datei geschrieben, nichts verschoben, kein Neustart")
        return 0
    vorher = None
    if not kein and dash_neu:
        vorher = vorher_stand()
        print("Vorher: %d Seiten 200, SDR-Stand %s" % (sum(1 for c in vorher["codes"].values() if c == "200"),
                                                      "gelesen" if vorher["sdr"] else "nicht lesbar"))
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    gesichert = []
    arch, moved = None, []
    cfg_alt = None
    try:
        for name, pfad, alt, neu in geaendert:
            bak = sichern(pfad, stempel)
            gesichert.append(bak)
            print("Backup %s" % bak)
        for name, pfad, alt, neu in geaendert:
            schreibe(pfad, neu)
            hs, ns = stand(open(pfad, "rb").read())
            print("geschrieben %s sha256 %s bytes %d" % (name, hs, ns))
            if (hs, ns) != stand(neu):
                raise Stop("STOP geschriebene Datei %s weicht ab" % name)
            if not pyflakes_datei(pfad):
                raise Stop("STOP pyflakes %s" % name)
        if cfg:
            pfad, alt, neu = cfg
            bak = sichern(pfad, stempel)
            gesichert.append(bak)
            print("Backup %s (Werte nicht ausgegeben)" % bak)
            cfg_alt = (pfad, alt)
            schreibe(pfad, neu)
            if open(pfad, "rb").read() != neu:
                raise Stop("STOP geschriebene Datei %s weicht ab" % PSH_CFG)
            if "src_pinneberg" in (json.loads(neu.decode("utf-8")) if neu else {}):
                raise Stop("STOP %s enthaelt nach dem Schreiben noch src_pinneberg" % PSH_CFG)
            print("geschrieben %s (src_pinneberg entfernt, Werte nicht ausgegeben)" % PSH_CFG)
            cfg_alt = (pfad, alt)
        if kand:
            arch, moved = verschiebe(root, kand, stempel)
            print("verschoben nach %s: %d Datei(en)" % (arch, len(moved)))
    except (Stop, OSError) as exc:
        print("%s - Rueckbau" % exc)
        _alles_rueckbau(plan, moved, arch, False, False, cfg_alt)
        return 4
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    if not dash_neu:
        print("ok, nur Dateien archiviert%s, kein Neustart noetig" % (" und Konfiguration bereinigt" if cfg_alt else ""))
        return 0
    if sdr_neu:
        seit_sdr = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
        epoch0 = time.time()
        rc = restart_dienst(DIENST_SDR)
        if rc != 0:
            _alles_rueckbau(plan, moved, arch, True, True, cfg_alt)
            return rc
        if not pruefe_sdr(vorher["sdr"] if vorher else None, epoch0, seit_sdr):
            print("STOP SDR-Pruefung fehlgeschlagen - Rueckbau")
            _alles_rueckbau(plan, moved, arch, True, True, cfg_alt)
            return 8
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = restart_dienst(DIENST)
    if rc != 0:
        _alles_rueckbau(plan, moved, arch, sdr_neu, True, cfg_alt)
        return rc
    if not pruefe_live(seit, vorher or {"codes": {}, "treffer": {}, "sdr": None}, root):
        print("STOP Pruefung fehlgeschlagen - Rueckbau (Sicherungen: %s)" % ", ".join(os.path.basename(b) for b in gesichert))
        _alles_rueckbau(plan, moved, arch, sdr_neu, True, cfg_alt)
        return 5
    print("ok, Dienste: %s" % ", ".join(([DIENST_SDR] if sdr_neu else []) + [DIENST]))
    return 0


# ----------------------------------------------------------------- Selbsttest
def _selftest_restart_check():
    assert _restart_ok(1, {"pid": "1", "ts": "a", "active": "active"}, {"pid": "2", "ts": "b", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "10", "ts": "A", "active": "active"}) is False
    assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "11", "ts": "B", "active": "active"}) is True
    print("selftest Neustart-Check ok")


def _selftest_scan_archiv():
    # Erkennung von Importen/Laden
    assert RX_IMPORT.search("import pinneberg_rolle as _pn") and RX_IMPORT.search("    from ntfy_push import x") and RX_IMPORT.search("import json, pinneberg_rx")
    assert not RX_IMPORT.search("import flugfunk as _ff") 
    assert RX_LADEN.search('open(os.path.join(b, "pinneberg_status.json"))') and not RX_LADEN.search("print('Flugfunk')")
    assert RX_SYSTEM.search("ExecStart=/usr/bin/python3 pinneberg_rx.py")
    tmp = tempfile.mkdtemp(prefix="feinschliff3-ar-")
    try:
        for n in ("pinneberg_rx.py", "pinneberg_rx.py.bak-a", "pinneberg_rolle.json", "ntfy_push.py", "ntfy_push.py.bak-psh-1", "apply-pinneberg-fix.py",
                  "dashboard.py.bak-pinneberg2-1", "keep.py", "dashboard.py", "apply-feinschliff3.py"):
            with open(os.path.join(tmp, n), "w") as fh:
                fh.write("x = 1\n")
        os.makedirs(os.path.join(tmp, "__pycache__"))
        with open(os.path.join(tmp, "__pycache__", "pinneberg_rx.cpython-313.pyc"), "wb") as fh:
            fh.write(b"\0")
        os.makedirs(os.path.join(tmp, "archiv-pinneberg-ntfy-alt"))
        with open(os.path.join(tmp, "archiv-pinneberg-ntfy-alt", "pinneberg_x.py"), "w") as fh:
            fh.write("x = 1\n")
        k = archiv_kandidaten(tmp)
        namen = sorted((s + "/" + n) if s else n for s, n in k)
        assert len(k) == 8 and "keep.py" not in namen and "dashboard.py" not in namen and "apply-feinschliff3.py" not in namen, namen
        assert "__pycache__/pinneberg_rx.cpython-313.pyc" in namen and "dashboard.py.bak-pinneberg2-1" in namen
        arch, moved = verschiebe(tmp, k, "T1")
        assert len(moved) == 8 and os.path.isfile(os.path.join(arch, "ARCHIV-MANIFEST.txt")) and not archiv_kandidaten(tmp)
        assert os.path.isfile(os.path.join(arch, "__pycache__", "pinneberg_rx.cpython-313.pyc")) and os.path.isfile(os.path.join(tmp, "keep.py"))
        n = zurueckholen(moved, arch)
        assert n == 8 and len(archiv_kandidaten(tmp)) == 8 and not os.path.exists(arch)
        # Abhaengigkeit: keep.py importiert ein Pinneberg-Modul -> Treffer; Archivdatei selbst zaehlt nicht
        with open(os.path.join(tmp, "keep.py"), "w") as fh:
            fh.write("import pinneberg_rx\n")
        h = scan_abhaengig(tmp, {}, k)
        assert len(h) == 1 and h[0].startswith("keep.py:1:"), h
        assert scan_abhaengig(tmp, {"keep.py": "x = 1\n"}, k) == []
        assert scan_abhaengig(tmp, {"keep.py": "x = 1  # import pinneberg_rx\n# import ntfy_push\n"}, k) == []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("selftest Archiv und Abhaengigkeits-Pruefung ok (Glob, __pycache__, Manifest, Rueckholen, Import-Erkennung)")


def _selftest_cfg():
    """src_pinneberg aus pushover.cfg entfernen, andere Schluessel behalten, Werte nie ausgeben."""
    tmp = tempfile.mkdtemp(prefix="feinschliff3b-cfg-")
    secret = "SECRETTESTTOKEN-nicht-ausgeben"
    try:
        pfad = os.path.join(tmp, PSH_CFG)
        with open(pfad, "w", encoding="utf-8") as fh:
            json.dump({"enabled": "1", "src_dwd": "1", "src_pinneberg": "1", "token": secret, "user": "U1"}, fh)
        import io
        buf = io.StringIO()
        old = sys.stdout
        try:
            sys.stdout = buf
            plan = cfg_plan(tmp)
        finally:
            sys.stdout = old
        out = buf.getvalue()
        assert plan is not None and secret not in out and "U1" not in out and "src_pinneberg wird entfernt" in out, out
        pfad, alt, neu = plan
        data = json.loads(neu.decode("utf-8"))
        assert "src_pinneberg" not in data and data.get("token") == secret and data.get("src_dwd") == "1" and data.get("user") == "U1"
        schreibe(pfad, neu)
        assert "src_pinneberg" not in json.load(open(pfad, encoding="utf-8"))
        buf = io.StringIO()
        try:
            sys.stdout = buf
            assert cfg_plan(tmp) is None
        finally:
            sys.stdout = old
        assert secret not in buf.getvalue()
        schreibe(pfad, alt)
        assert json.load(open(pfad, encoding="utf-8")).get("src_pinneberg") == "1"
        print("selftest pushover.cfg ok (Schluessel entfernt, Werte erhalten und nicht ausgegeben, idempotent, Rueckbau)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _selftest_dash(t):
    assert "def _pn_api(" not in t and "_pn_after" not in t and "ntfy" not in t.lower()
    assert "def _psh_cfg_sauber(" in t and "pinneberg" not in _dash_ohne_filter(t).lower()
    for muss in ("def _inet_split(", "# ===== snMask:", "def _snm_after(", "def _ff_api(", "/api/flugfunk", "def _usbw_selftest_inner(", 'id="pushoverBox"', "def _psh_sample("):
        assert muss in t, muss
    assert t.count("def _ff_api(") == 1 and t.count("# ===== snMask:") == 1
    assert t.count('id="pushoverBox"') == 6 and t.count('getElementById("pushoverBox")') == 1 and t.count("ntfy") == 0
    # Filter: Anzeige und Speichern
    ns = {}
    i = t.find("def _psh_cfg_sauber(")
    j = t.find("\ndef _psh_api(", i)
    exec(compile(t[i:j], "psh-filter", "exec"), ns)
    f = ns["_psh_cfg_sauber"]
    assert f({"src_dwd": "1", "src_pinneberg": "1", "token": "gesetzt"}) == {"src_dwd": "1", "token": "gesetzt"}
    assert f({"src_dienst": "1"}) == {"src_dienst": "1"} and f("x") == "x"
    api = t[j:t.find("\ndef _psh_usv_live(", j)]
    assert api.count("_psh_cfg_sauber(") >= 4 and "body = _psh_cfg_sauber(body)" in api
    i = t.find("_PSH_CARD = (\n")
    j = t.find("\n\n\ndef _psh_place(", i)
    assert 0 < i < j
    card = eval(t[i + len("_PSH_CARD = "): j])
    assert 'id="pshDwd"' in card and 'id="pshUsv"' in card and 'id="pshDienst"' in card and "pshPin" not in card and "src_pinneberg" not in card
    assert 'id="pushoverBox"' in card and 'getElementById("pushoverBox")' in card and "PUSHOVER" in card
    # Der Ort der Pushover-Kachel wird weiter ueber die ID gefunden: Platzhalter in hbMesh/Test sind umbenannt
    assert t.count("pushoverBox") == 9


def _selftest_patch(name, patch, text, ende):
    t = patch(text)
    assert patch(t) == t, "%s: patch nicht idempotent" % name
    compile(t, name, "exec")
    if ende:
        assert stand(t.encode("utf-8")) == ende, "%s: Endhash %s/%d" % (name, stand(t.encode('utf-8'))[0][:16], len(t.encode("utf-8")))
    return t


def selftest(basis=BASIS):
    try:
        _selftest_restart_check()
        _selftest_scan_archiv()
        texte = {}
        for name, start, ende, patch, pflicht in _dateien():
            pfad = os.path.join(basis, name)
            if not os.path.isfile(pfad):
                assert not pflicht, "%s fehlt" % pfad
                print("selftest: %s fehlt, uebersprungen" % name)
                continue
            raw = open(pfad, "rb").read()
            ist = stand(raw)
            if ist == ende:
                print("selftest: %s steht schon auf dem Endstand" % name)
                t = _selftest_patch(name, patch, raw.decode("utf-8"), ende)
            elif ist == start:
                t = _selftest_patch(name, patch, raw.decode("utf-8"), ende)
                print("selftest %s: Patch, Idempotenz, Endhash ok" % name)
            elif not pflicht:
                print("selftest: %s hat unbekannten Stand, wird nicht gepatcht" % name)
                continue
            else:
                print("STOP selftest: %s %s/%d ist weder Paket-2-Stand noch Endstand" % (name, ist[0][:16], ist[1]))
                return 1
            texte[name] = t
        _selftest_dash(texte["dashboard.py"])
        print("selftest dashboard.py ok (keine Reste ausser Filter, snMask/DSL-Starlink/Flugfunk/USB-Wache erhalten, /api/pushover filtert src_pinneberg)")
        _selftest_cfg()
        s = texte["prepper_sdr.py"]
        assert "import pinneberg_rolle" not in s and "_pn." not in s and "def _flugfunk_an(" in s and s.count("def _s3e_split(") == 2 and s.count("Planner.start = _ff_start") == 1
        ok, txt = import_probe(basis, s)
        assert ok, "Import-Probe prepper_sdr.py: %s" % txt
        print("selftest prepper_sdr.py ok (Import ohne pinneberg_*/ntfy_push, Flugfunk-Funktionen und Planner-Kette da)")
        # Anwenden auf einer Kopie (ohne Neustart)
        tmp = tempfile.mkdtemp(prefix="feinschliff3-st-")
        try:
            for n in os.listdir(basis):
                p = os.path.join(basis, n)
                if n.endswith(".py") and os.path.isfile(p) and "pinneberg" not in n.lower() and "ntfy" not in n.lower() and not n.startswith("apply-"):
                    shutil.copy2(p, os.path.join(tmp, n))
            for n in ("pinneberg_rx.py", "pinneberg_rolle.py", "ntfy_push.py", "pinneberg_rolle.json", "pinneberg_status.json", "pinneberg_rx.py.bak-pnfix-1",
                      "apply-pinneberg-auto.py", "dashboard.py.bak-pinneberg2-1", "prepper_sdr.py.bak-pinnebergrolle-1"):
                with open(os.path.join(tmp, n), "w") as fh:
                    fh.write("x = 1\n")
            secret = "SECRETTESTTOKEN-nicht-ausgeben"
            with open(os.path.join(tmp, PSH_CFG), "w", encoding="utf-8") as fh:
                json.dump({"enabled": "1", "src_pinneberg": "1", "token": secret, "src_dwd": "1"}, fh)
            geaendert0 = any(p[3] is not None for p in berechne(tmp))
            rc = anwenden(tmp, True, True)
            assert rc == 0 and os.path.isfile(os.path.join(tmp, "ntfy_push.py")), "dry-run rc %s" % rc
            rc = anwenden(tmp, False, True)
            assert rc == 0, "anwenden rc %s" % rc
            assert not archiv_kandidaten(tmp), "Dateien nicht archiviert"
            arch = [d for d in os.listdir(tmp) if d.startswith(ARCHIV_PRAEFIX)]
            assert len(arch) == 1 and os.path.isfile(os.path.join(tmp, arch[0], "ARCHIV-MANIFEST.txt")) and os.path.isfile(os.path.join(tmp, arch[0], "ntfy_push.py"))
            assert stand(open(os.path.join(tmp, "dashboard.py"), "rb").read()) == DASH_ENDE
            assert stand(open(os.path.join(tmp, "prepper_sdr.py"), "rb").read()) == SDR_ENDE
            cfg = json.load(open(os.path.join(tmp, PSH_CFG), encoding="utf-8"))
            assert "src_pinneberg" not in cfg and cfg.get("token") == secret and cfg.get("src_dwd") == "1"
            assert any(p.startswith(PSH_CFG + ".bak-" + KENNUNG) for p in os.listdir(tmp))
            assert (not geaendert0) or (any(p.startswith("dashboard.py.bak-" + KENNUNG) for p in os.listdir(tmp)) and any(p.startswith("prepper_sdr.py.bak-" + KENNUNG) for p in os.listdir(tmp)))
            assert anwenden(tmp, False, True) == 0
            assert len([d for d in os.listdir(tmp) if d.startswith(ARCHIV_PRAEFIX)]) == 1, "zweiter Lauf hat ein weiteres Archiv angelegt"
            print("selftest apply auf Kopie ok (Backup, Endhash, Archiv mit Manifest, zweiter Lauf ohne Aenderung)")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        tmp = tempfile.mkdtemp(prefix="feinschliff3-rb-")
        try:
            for n in os.listdir(basis):
                p = os.path.join(basis, n)
                if n.endswith(".py") and os.path.isfile(p) and "pinneberg" not in n.lower() and "ntfy" not in n.lower() and not n.startswith("apply-"):
                    shutil.copy2(p, os.path.join(tmp, n))
            vor = {n: stand(open(os.path.join(tmp, n), "rb").read()) for n in ("dashboard.py", "prepper_sdr.py")}
            with open(os.path.join(tmp, PSH_CFG), "w", encoding="utf-8") as fh:
                json.dump({"src_pinneberg": "1", "token": "SECRETTESTTOKEN-nicht-ausgeben"}, fh)
            alt_cfg = open(os.path.join(tmp, PSH_CFG), "rb").read()
            pl = berechne(tmp)
            for name, pfad, alt, neu in pl:
                if neu is not None:
                    schreibe(pfad, neu)
            cplan = cfg_plan(tmp)
            schreibe(cplan[0], cplan[2])
            assert "src_pinneberg" not in json.load(open(os.path.join(tmp, PSH_CFG), encoding="utf-8"))
            _alles_rueckbau(pl, [], None, False, False, (cplan[0], alt_cfg))
            assert {n: stand(open(os.path.join(tmp, n), "rb").read()) for n in vor} == vor, "Rueckbau stellt die Originale nicht her"
            assert json.load(open(os.path.join(tmp, PSH_CFG), encoding="utf-8")).get("src_pinneberg") == "1"
            print("selftest Rueckbau der Dateien ok")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    except (AssertionError, Stop, SyntaxError, KeyError, ValueError, TypeError, IndexError, OSError) as exc:
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
    except Exception as exc:
        print("STOP unerwarteter Fehler: %s: %s" % (type(exc).__name__, exc))
        return 9


if __name__ == "__main__":
    sys.exit(main())
