#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-feinschliff4: Lage nennt immer den Grund; NINA "gering" (Minor) ausserhalb des eigenen Kreises ERH ist nur ein Hinweis; SDR-Kette ehrlich.

Nur dashboard.py (auf dem Stand nach Paket 3b / feinschliff3b; _psh_cfg_sauber aus 3b bleibt erhalten). prepper_sdr.py und sdr_manager.py werden NICHT geaendert, nur ihre Staende geprueft
(die neuen Huellen in dashboard.py setzen sdr_manager 5a26efff... voraus). Neustart: nur prepper-dashboard.
Aenderungen:
- fetch_nina: je Meldung zusaetzlich severity und status (aus der NINA-Dashboard-Antwort).
- _fs4_nina_lage: Aufhebung (Cancel/Entwarnung), Probe/Test/Uebung/Warntag/SIM, nicht-Actual und abgelaufene Meldungen raus;
  mittel/schwer/extrem (und unbekannter Grad) = gelb, gering nur im Kreis ERH gelb, sonst einzeiliger Hinweis im Lage-Kasten.
  NINA-Altdaten (Abruf fehlgeschlagen, error/kept) aelter als 2 h: nie gelb.
- calculate_lage: gelb nennt die Meldung ("NINA: <Titel> (<Kreis>)") statt "Warnungen vorhanden". Rot-Pfade unveraendert.
- _inet_split: Starlink-Ausfallschutz erst nach 120 s durchgehend = DSL weg (gelb); der teil4-Faden zaehlt alle 10 s weiter und rechnet bei Wechsel die Lage neu.
- teil4: _t4_after bettet einen frischen Stand ein (hoechstens 5 s alt) statt eines alten Zwischenspeichers; Zeile "Alarm: keiner · ..." statt "Status: OK – ...".
- SDR: Lesefehler in sdr_manager.live() = eigener Zustand STATUS_UNLESBAR ("Status nicht lesbar") statt SDR_OFFLINE, nie lagewirksam;
  "SDR-Empfang ungeprueft" statt fest "SDR liefert Daten", wenn kein Watchdog-Ergebnis da ist. Gesundheits-Pruefung (_hp_probe) zaehlt STATUS_UNLESBAR nicht als "SDR ok".
- /api/lage_grund (nur lesen): Lage, NINA-Einstufung, Starlink-Entprellung.
Erhalten: snMask, inet_split (DSL/Starlink getrennt), usbwache, Pushover-Kachel. Keine Zeitsperre, keine Seriennummern in der Ausgabe.
"""
from __future__ import annotations

import argparse
import ast
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

KENNUNG = "feinschliff4"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"
FESTE_SN = ()

DASH_START = ("d759785cbcd144c87d6e0cc9ffc6fe97304afe2452b931f5ee5626380175effd", 1437729)   # nach Paket 3b (feinschliff3b)
DASH_P3_ALT = ("13b30ffe279bd2746aae13d8149ffbdc43fc9aab76a58e85f8c927271d86ef15", 1437346)   # zurueckgerolltes Paket 3
DASH_ENDE = ("e56d0d591007a00d3a255c1aa0dc99f277031f26117c6493dcb75adb2c0ce8da", 1458295)
DASH_PAKET2 = ("bfdd36d7dbb9691572b1e31536f4a364c66bfd92a3e04fc768af16508f4a7809", 1438615)
SDR_SOLL = ("ad62d9a56c6aa682246945bae7b65eaa75afb216b5a20dd1d4881ea42cc0d85c", 820331)      # prepper_sdr.py nach Paket 3b (unveraendert)
SDR_PAKET2 = ("0d3fc5b4eacd0bbc3c6e0a9c42744894dfb29efc6f87163e869a0f6fee3b8f9a", 825150)
SM_SOLL = ("5a26efff608bf541a929fa775112d3593883a7423b6d9f6f29e61dc9b14db181", 288008)       # sdr_manager.py (Stand commit64, unveraendert)


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


def pyflakes_datei(pfad):
    for cmd in (["pyflakes", pfad], ["python3", "-m", "pyflakes", pfad]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            continue
        err = (r.stderr or "") + (r.stdout or "")
        if "No module named" in err or "command not found" in err:
            continue
        neu = [ln for ln in err.splitlines() if "fs4" in ln or "feinschliff4" in ln]
        if neu:
            print("pyflakes %s (neue Stellen):\n%s" % (os.path.basename(pfad), "\n".join(neu[:20])))
            return False
        print("pyflakes %s: keine Meldung zu den neuen Stellen" % os.path.basename(pfad))
        return True
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
    return gesehen if gesehen != 0 else 1


URL = "http://127.0.0.1:5000"


def _get(pfad, timeout=6):
    ziel = tempfile.mktemp(prefix="apply-feinschliff4-")
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


# ----------------------------------------------------------------- Anker und Patch
BLOCK = r'''# ===== feinschliff4: Lage nennt den Grund, NINA gering ausserhalb ERH nur Hinweis, NINA-Altdaten nie gelb, Starlink entprellt, Alarm-Zeile statt Status, SDR-Lesefehler eigener Zustand =====
import re as _fs4_re
import time as _fs4_time
import html as _fs4_html
from datetime import datetime as _fs4_dt

FS4_NINA_EIGEN = ("LK Erlangen-Höchstadt",)     # eigener Kreis ERH: dort zaehlt auch "gering" (Minor) fuer die Lage
FS4_KEPT_MAX_S = 2 * 3600                       # NINA-Altdaten (Abruf fehlgeschlagen, letzter Stand behalten) aelter als 2 h: nie gelb
FS4_SL_CONFIRM_S = 120                          # Starlink-Ausfallschutz erst nach 120 s durchgehend als "DSL weg" werten
_FS4 = {"sl_since": None, "sl_lage_prev": None, "selftest": None, "err": None, "kick": 0}
_FS4_SEV = {"minor": 1, "moderate": 2, "severe": 3, "extreme": 4}
_FS4_SEV_TXT = {1: "gering", 2: "mittel", 3: "schwer", 4: "extrem"}
_FS4_SKIP = _fs4_re.compile(r"(?i)^\s*(sim|test|probe)\s*[:\-\u2013]|^\s*test\s*$|\w*(probealarm|probewarnung|warntag|testalarm|testwarnung|testmeldung|übung|uebung)\b")
_FS4_STATUS_OK = ("", "actual")


# --- fs4 rein (ohne Flask, ohne Dateien; der Apply-Selbsttest fuehrt diesen Teil isoliert aus) ---
def _fs4_ts(s):
    """NINA-Zeit (ISO 8601) -> Epoch-Sekunden oder None."""
    if not isinstance(s, str) or not s.strip():
        return None
    try:
        return _fs4_dt.fromisoformat(s.strip().replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _fs4_alter_s(updated, now=None):
    """Alter eines Zeitstempels "TT.MM.JJJJ HH:MM[:SS]" in Sekunden, sonst None."""
    if not isinstance(updated, str):
        return None
    now = _fs4_time.time() if now is None else float(now)
    for fmt in ("%d.%m.%Y %H:%M:%S", "%d.%m.%Y %H:%M"):
        try:
            return now - _fs4_dt.strptime(updated.strip(), fmt).timestamp()
        except Exception:
            pass
    return None


def _fs4_kurz(t, n=90):
    t = " ".join(str(t or "").split())
    if len(t) <= n:
        return t
    k = t.rfind(" ", 0, n)
    return t[:k if k > n // 2 else n].rstrip(" ,;-–") + "…"


def _fs4_sev(w, det):
    best = 0
    for s in (w.get("severity"), (det or {}).get("severity")):
        r = _FS4_SEV.get(str(s or "").strip().lower(), 0)
        best = max(best, r)
    return best


def _fs4_nina_lage(slot, now=None, details=None, alert=None):
    """NINA-Slot -> {"gelb": [...], "hinweis": [...], "grund": str|None, "hinweis_txt": str|None, "kept": bool, "alt": bool}.
    gelb: mittel/schwer/extrem, unbekannter Grad, oder gering im eigenen Kreis (ERH). hinweis: gering ausserhalb ERH.
    Ausgefiltert: Aufhebung (Cancel/Entwarnung), Probe/Test/Uebung/Warntag/SIM, Status nicht Actual, abgelaufen.
    Altdaten (error=True) aelter als 2 h oder ohne lesbaren Stand: nie gelb, nur Technik-Hinweis. Wirft nie."""
    out = {"gelb": [], "hinweis": [], "grund": None, "hinweis_txt": None, "kept": False, "alt": False, "stand": None}
    try:
        now = _fs4_time.time() if now is None else float(now)
        if details is None:
            details = ((globals().get("_T2D") or {}).get("nina") or {})
        if alert is None:
            alert = globals().get("nina_is_alert") or (lambda t: bool(str(t or "").strip()))
        if not isinstance(slot, dict) or not isinstance(slot.get("value"), list):
            return out
        out["kept"] = slot.get("error") is True
        out["stand"] = slot.get("updated") if isinstance(slot.get("updated"), str) else None
        seen = {}
        for w in slot["value"]:
            if not isinstance(w, dict):
                continue
            title = str(w.get("title") or w.get("headline") or "").strip()
            if not title or not alert(title) or _FS4_SKIP.search(title):
                continue
            wid = str(w.get("id") or "") or ("t:" + title)
            det = details.get(w.get("id")) if isinstance(details, dict) and w.get("id") else None
            det = det if isinstance(det, dict) else {}
            if str(w.get("msgType") or "") == "Cancel" or str(det.get("msgType") or "") == "Cancel":
                continue
            stt = [str(x or "").strip().lower() for x in (w.get("status"), det.get("status"))]
            if any(s not in _FS4_STATUS_OK for s in stt):
                continue
            ex = _fs4_ts(w.get("expires"))
            if ex is not None and ex < now:
                continue
            city = str(w.get("city") or w.get("area") or "").strip()
            it = seen.get(wid)
            if it is None:
                it = seen[wid] = {"id": wid, "title": title, "kreise": [], "sev": 0, "eigen": False}
            if city and city not in it["kreise"]:
                it["kreise"].append(city)
            it["eigen"] = it["eigen"] or city in FS4_NINA_EIGEN
            it["sev"] = max(it["sev"], _fs4_sev(w, det))
        gelb, hinw = [], []
        for it in seen.values():
            (hinw if (it["sev"] == 1 and not it["eigen"]) else gelb).append(it)
        gelb.sort(key=lambda x: (-(x["sev"] or 2), not x["eigen"]))
        if out["kept"]:
            age = _fs4_alter_s(out["stand"], now)
            if age is None or age > FS4_KEPT_MAX_S:
                out["alt"] = True
                out["hinweis_txt"] = "ℹ NINA nicht erreichbar – letzter Stand %s, nicht lagewirksam" % (out["stand"] or "unbekannt")
                return out
        out["gelb"], out["hinweis"] = gelb, hinw
        if gelb:
            w = gelb[0]
            g = "NINA: %s (%s)" % (_fs4_kurz(w["title"]), ", ".join(w["kreise"][:2]) or "Region")
            if len(gelb) > 1:
                g += " +%d weitere" % (len(gelb) - 1)
            if out["kept"]:
                g += " – Stand %s" % (out["stand"] or "?")
            out["grund"] = g
        if hinw:
            w = hinw[0]
            h = "ℹ NINA-Hinweis (gering): %s (%s)" % (_fs4_kurz(w["title"]), ", ".join(w["kreise"][:2]) or "Region")
            if len(hinw) > 1:
                h += " +%d" % (len(hinw) - 1)
            out["hinweis_txt"] = h
    except Exception as e:
        _FS4["err"] = "nina: %s" % str(e)[:120]
        v = slot.get("value") if isinstance(slot, dict) else None
        if isinstance(v, list) and v and not (isinstance(slot, dict) and slot.get("error") is True):
            out["gelb"] = [{"title": "?", "kreise": [], "sev": 0}]
            out["grund"] = "NINA-Meldung vorhanden (Bewertung fehlgeschlagen)"
    return out


def _fs4_sl_bestaetigt(on, now=None):
    """Starlink-Ausfallschutz entprellen: True erst, wenn er seit FS4_SL_CONFIRM_S durchgehend aktiv gemeldet wird."""
    now = _fs4_time.monotonic() if now is None else float(now)
    if not on:
        _FS4["sl_since"] = None
        return False
    if _FS4["sl_since"] is None:
        _FS4["sl_since"] = now
    return now - _FS4["sl_since"] >= FS4_SL_CONFIRM_S


def _fs4_line(lvl):
    """Zeile unter der Lage: "Alarm: keiner · ..." statt "Status: OK – ...". ECHTALARM/VORALARM bleiben am Anfang erkennbar."""
    lab = str(lvl.get("label") or "?")
    why = str(lvl.get("why") or "")
    l = lvl.get("lvl")
    if l == "ok":
        teile = [p.strip() for p in _fs4_re.split(r",\s*", why) if p.strip()]
        teile = [p for p in teile if p.lower() != "kein echter alarm"]
        return ("Alarm: keiner · " + " · ".join(teile)).strip(" ·")[:280]
    return ("Alarm: %s – %s" % (lab, why))[:280]


def _fs4_level(lvl, live, sd=None):
    """Nach _los_lage: ehrlicher SDR-Text (nicht lesbar / ungeprueft / ohne frische Daten) und die Alarm-Zeile. Stufe, Label, Blinken bleiben."""
    try:
        if not isinstance(lvl, dict):
            return lvl
        out = dict(lvl)
        why = str(out.get("why") or "")
        w = (sd or {}).get("wd") if isinstance(sd, dict) else None
        if live == "STATUS_UNLESBAR":
            why = why.replace("SDR liefert Daten", "SDR-Status nicht lesbar") if "SDR liefert Daten" in why else (why + ", SDR-Status nicht lesbar").strip(", ")
            out["sdr"] = {"lvl": "grau", "color": "#94a3b8", "txt": "SDR-Status nicht lesbar"}
        elif not isinstance(w, dict) and "SDR liefert Daten" in why:
            why = why.replace("SDR liefert Daten", "SDR-Empfang ungeprüft")
            out["sdr"] = {"lvl": "grau", "color": "#94a3b8", "txt": "SDR-Empfang ungeprüft"}
        if "SDR_OFFLINE nicht in der Lage" in (out.get("notes") or []):
            why = why.replace(" – SDR-Technik gesondert (nicht die Lage)", ", SDR ohne frische Daten (nur Technikhinweis)")
        out["why"] = why[:260]
        out["line"] = _fs4_line(out)
        return out
    except Exception as e:
        _FS4["err"] = "level: %s" % str(e)[:120]
        return lvl


def _fs4_live_core(mgr, base, path=None, br=None, extra=None, now=None):
    """sdr_manager.live(), aber Lesefehler (Ausnahme, database fehlt, DB unlesbar ohne Telemetrie) = STATUS_UNLESBAR statt SDR_OFFLINE.
    Ein echter Ausfall (Telemetrie lesbar, aber zu alt) bleibt SDR_OFFLINE. Beides ist nie lagewirksam."""
    dbm = getattr(mgr, "db", None)
    le = getattr(dbm, "last_error", None)
    e0 = le() if callable(le) else None
    r = mgr.live(base, path, br, extra, now)
    try:
        if isinstance(r, dict) and r.get("status") == "SDR_OFFLINE":
            rd = callable(le) and le() is not e0 and le() is not None
            wd = r.get("watchdog") if isinstance(r.get("watchdog"), dict) else {}
            if r.get("error") or (rd and wd.get("newest_ts") is None):
                r = dict(r, status="STATUS_UNLESBAR", status_txt="Status nicht lesbar", status_grund=str(r.get("error") or "Datenbank gerade nicht lesbar")[:120])
    except Exception as e:
        _FS4["err"] = "live: %s" % str(e)[:120]
    return r


def _fs4_inject(body, txt, full=None):
    """Hinweis-Zeile (einzeilig) in den Lage-Kasten nach der Grund-Zeile; der Kasten-Kopf bleibt unveraendert (teil4 sucht ihn)."""
    if not txt or not isinstance(body, str) or 'id="fs4Hint"' in body:
        return body
    i = body.find('<div class="lage ')
    if i < 0:
        return body
    j = body.find("</div>", i)
    if j < 0:
        return body
    k = body.find("</small>", i, j)
    pos = (k + len("</small>")) if k >= 0 else j
    e = _fs4_html.escape
    tag = '<small class="fs4-hint" id="fs4Hint" title="%s">%s</small>' % (e(full or txt, quote=True), e(txt, quote=False))
    body = body[:pos] + tag + body[pos:]
    h = body.find("</head>")
    if h >= 0 and 'id="fs4-css"' not in body:
        body = body[:h] + _FS4_CSS + body[h:]
    return body


_FS4_CSS = ('<style id="fs4-css">.lage small.fs4-hint{display:block;font-size:.78rem;font-weight:500;margin-top:4px;opacity:.85;'
            'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}</style>')
# --- /fs4 rein ---


def _fs4_live(base, path=None, br=None, extra=None, now=None):
    return _fs4_live_core(globals().get("_lz_mgr"), base, path, br, extra, now)


def _fs4_tick():
    """Aus dem teil4-Faden (alle 10 s): Starlink-Entprellung weiterzaehlen; wechselt deren Lage-Wirkung, Lage sofort neu rechnen."""
    try:
        if (globals().get("_T4") or {}).get("fake"):
            return
        sp = _inet_split()
        neu = sp.get("lage")
        if neu != _FS4["sl_lage_prev"]:
            _FS4["sl_lage_prev"] = neu
            ds = globals().get("data_store")
            if isinstance(ds, dict) and isinstance(ds.get("lage"), dict):
                t, c, r = calculate_lage(ds)
                ds["lage"] = {"text": t, "color": c, "reason": r}
                _FS4["kick"] += 1
    except Exception as e:
        _FS4["err"] = "tick: %s" % str(e)[:120]


def _fs4_level_hook(lvl, live, sd=None):
    _fs4_tick()
    return _fs4_level(lvl, live, sd)


def _fs4_after(resp):
    try:
        from flask import request as _fs4_rq
        if ((_fs4_rq.path or "").rstrip("/") or "/") != "/" or resp.status_code != 200 or getattr(resp, "direct_passthrough", False):
            return resp
        if resp.headers.get("Content-Encoding") or not (resp.mimetype or "").startswith("text/html"):
            return resp
        nl = _fs4_nina_lage((globals().get("data_store") or {}).get("nina"))
        txt = nl.get("hinweis_txt")
        if not txt:
            return resp
        full = "; ".join("%s (%s)" % (w["title"], ", ".join(w["kreise"])) for w in nl.get("hinweis") or []) or txt
        body = resp.get_data(as_text=True)
        neu = _fs4_inject(body, txt, full)
        if neu != body:
            resp.set_data(neu)
    except Exception as e:
        _FS4["err"] = "after: %s" % str(e)[:120]
    return resp


def _fs4_api():
    from flask import jsonify
    ds = globals().get("data_store") or {}
    nl = _fs4_nina_lage(ds.get("nina"))
    try:
        jetzt = calculate_lage(ds)
    except Exception as e:
        jetzt = ("?", "?", "Fehler: %s" % str(e)[:80])
    sp = _inet_split()
    r = jsonify({"lage": ds.get("lage"), "jetzt": {"text": jetzt[0], "reason": jetzt[2]}, "nina_geladen": isinstance((ds.get("nina") or {}).get("value"), list),
                 "nina": {"gelb": [{"title": w["title"], "kreise": w["kreise"], "grad": _FS4_SEV_TXT.get(w["sev"], "unbekannt"), "eigen": w.get("eigen")} for w in nl["gelb"]],
                          "hinweis": [{"title": w["title"], "kreise": w["kreise"], "grad": _FS4_SEV_TXT.get(w["sev"], "unbekannt")} for w in nl["hinweis"]],
                          "grund": nl["grund"], "hinweis_txt": nl["hinweis_txt"], "kept": nl["kept"], "alt": nl["alt"]},
                 "inet": {"cur": sp.get("cur"), "lage": sp.get("lage"), "dsl": sp.get("dsl"), "sl": sp.get("sl"), "sl_seit_s": (round(_fs4_time.monotonic() - _FS4["sl_since"]) if _FS4["sl_since"] is not None else None)},
                 "selftest": _FS4["selftest"], "err": _FS4["err"]})
    r.headers["Cache-Control"] = "no-store"
    return r


def _fs4_selftest():
    now = 1795000000.0
    d = {}
    ros = {"city": "LK Fürth", "title": "Trinkwasserverschmutzung - Kerngebiet Roßtal, Buttendorf, Neuses, Stöckach, Weitersdorf (teilweise)",
           "id": "mow.DE-BY-N-SE137-20261110-166-000", "msgType": "Update", "severity": "Minor", "expires": None}
    al = lambda t: bool(str(t or "").strip()) and "entwarn" not in str(t).lower()
    r = _fs4_nina_lage({"value": [ros]}, now, d, al)
    assert not r["gelb"] and r["hinweis"] and "Roßtal" in r["hinweis_txt"] and "LK Fürth" in r["hinweis_txt"], r
    r = _fs4_nina_lage({"value": [dict(ros, city="LK Erlangen-Höchstadt")]}, now, d, al)
    assert r["gelb"] and r["grund"].startswith("NINA: Trinkwasserverschmutzung") and "(LK Erlangen-Höchstadt)" in r["grund"], r
    r = _fs4_nina_lage({"value": [dict(ros, severity="Moderate")]}, now, d, al)
    assert r["gelb"] and "(LK Fürth)" in r["grund"]
    r = _fs4_nina_lage({"value": [ros]}, now, {ros["id"]: {"severity": "Severe", "status": "Actual"}}, al)
    assert r["gelb"], "Hochstufung aus Teil-2-Details zaehlt"
    for x in (dict(ros, severity="Severe", msgType="Cancel"), dict(ros, severity="Severe", title="Warntag: Probewarnung"), dict(ros, severity="Severe", status="Exercise"),
              dict(ros, severity="Severe", title="Katastrophenschutzübung Hafen"), dict(ros, severity="Severe", title="SIM: Verunreinigung Trinkwasser"),
              dict(ros, severity="Severe", expires="2020-01-01T00:00:00+01:00")):
        assert not _fs4_nina_lage({"value": [x]}, now, d, al)["gelb"], x
    assert _fs4_nina_lage({"value": [dict(ros, severity="Moderate", title="Trinkwasserprobe positiv")]}, now, d, al)["gelb"]
    st = _fs4_dt.fromtimestamp(now - 3 * 3600).strftime("%d.%m.%Y %H:%M:%S")
    r = _fs4_nina_lage({"value": [dict(ros, severity="Moderate")], "error": True, "updated": st}, now, d, al)
    assert not r["gelb"] and r["alt"] and "nicht lagewirksam" in r["hinweis_txt"], r
    st = _fs4_dt.fromtimestamp(now - 1800).strftime("%d.%m.%Y %H:%M:%S")
    r = _fs4_nina_lage({"value": [dict(ros, severity="Moderate")], "error": True, "updated": st}, now, d, al)
    assert r["gelb"] and "Stand" in r["grund"]
    old = _FS4["sl_since"]
    try:
        _FS4["sl_since"] = None
        assert _fs4_sl_bestaetigt(True, 100) is False and _fs4_sl_bestaetigt(True, 219) is False and _fs4_sl_bestaetigt(True, 220) is True
        assert _fs4_sl_bestaetigt(False, 221) is False and _fs4_sl_bestaetigt(True, 222) is False
    finally:
        _FS4["sl_since"] = old
    ok = {"lvl": "ok", "label": "OK", "blink": False, "why": "kein echter Alarm, keine ASA-Probe, SDR liefert Daten, kein Vor-Alarm", "notes": []}
    o = _fs4_level(ok, "ECHTALARM", {"wd": {"lvl": "ok"}})
    assert o["line"] == "Alarm: keiner · keine ASA-Probe · SDR liefert Daten · kein Vor-Alarm", o["line"]
    o = _fs4_level(ok, "STATUS_UNLESBAR", {"wd": {"lvl": "ok"}})
    assert "SDR-Status nicht lesbar" in o["why"] and o["lvl"] == "ok" and not o["blink"] and o["line"].startswith("Alarm: keiner")
    assert "SDR-Empfang ungeprüft" in _fs4_level(ok, "ECHTALARM", {})["why"]
    o = _fs4_level({"lvl": "alarm", "label": "ECHTALARM", "blink": True, "why": "NINA: x"}, "ECHTALARM", {"wd": {}})
    assert o["line"].startswith("Alarm: ECHTALARM") and o["blink"]
    b = '<html><head></head><body><div class="lage normal">\n  <span class="lage-icon">🛡</span>\n  LAGE: NORMAL\n  <small>Keine</small>\n  <small>x</small>\n</div></body></html>'
    h = _fs4_inject(b, "ℹ NINA-Hinweis (gering): <a> (LK Fürth)")
    assert 'id="fs4Hint"' in h and "&lt;a&gt;" in h and '<div class="lage normal">' in h and h.index("fs4Hint") < h.index("<small>x</small>") and 'id="fs4-css"' in h
    assert _fs4_inject(h, "y") == h
    return "feinschliff4 ok (NINA gering ausserhalb ERH = Hinweis, Grund benannt, Aufhebung/Probe/Uebung/abgelaufen/nicht Actual raus, Altdaten > 2 h nie gelb, Starlink 120 s, Alarm-Zeile, SDR nicht lesbar/ungeprueft)"


try:
    try:
        _FS4["selftest"] = _fs4_selftest()
    except Exception as _fs4_e1:
        _FS4["selftest"] = "FEHLER: %s: %s" % (type(_fs4_e1).__name__, _fs4_e1)
        print("feinschliff4 Selbsttest FEHLER:", _FS4["selftest"], flush=True)
    if "app" in globals():
        if "fs4_api" not in app.view_functions:
            app.add_url_rule("/api/lage_grund", endpoint="fs4_api", view_func=_fs4_api, methods=["GET"])
        if not any(getattr(f, "__name__", "") == "_fs4_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_fs4_after)
    print("feinschliff4 aktiv: Lage-Grund, NINA-Hinweis, Starlink %d s, /api/lage_grund; %s" % (FS4_SL_CONFIRM_S, _FS4["selftest"]), flush=True)
except Exception as _fs4_e:
    _FS4["err"] = str(_fs4_e)[:160]
    print("feinschliff4 FEHLER:", _fs4_e, flush=True)
# ===== /feinschliff4 =====

'''

P_NINA_ALT = '"sent": w.get("sent"), "expires": w.get("expires")})  # ninaCalm\n'
P_NINA_NEU = ('"sent": w.get("sent"), "expires": w.get("expires"), "severity": ((w.get("payload") or {}).get("data") or {}).get("severity"), '
              '"status": ((w.get("payload") or {}).get("data") or {}).get("status")})  # ninaCalm feinschliff4\n')
P_LAGE_ALT = '    if nina: return "AUFFÄLLIG", "#eab308", "Warnungen vorhanden"\n'
P_LAGE_NEU = (
    '    _fs4n = globals().get("_fs4_nina_lage")   # feinschliff4: NINA benannt, gering ausserhalb ERH nur Hinweis, Altdaten > 2 h nie gelb\n'
    '    if callable(_fs4n):\n'
    '        _fs4r = _fs4n(data.get("nina"))\n'
    '        if _fs4r.get("gelb"): return "AUFFÄLLIG", "#eab308", _fs4r.get("grund") or "NINA-Meldung"\n'
    '    elif nina: return "AUFFÄLLIG", "#eab308", "NINA-Meldung vorhanden"\n'
)
P_SL_ALT = (
    '    elif cur == "starlink":\n'
    '        dsl, sl = ("weg", "ausgefallen"), ("aktiv", "Ausfallschutz aktiv")\n'
    '        lage = "gelb"\n'
)
P_SL_NEU = (
    '    elif cur == "starlink":\n'
    '        if globals().get("_fs4_sl_bestaetigt", lambda on: True)(True):   # feinschliff4: erst nach 120 s durchgehend\n'
    '            dsl, sl = ("weg", "ausgefallen"), ("aktiv", "Ausfallschutz aktiv")\n'
    '            lage = "gelb"\n'
    '        else:\n'
    '            dsl, sl = ("unklar", "Ausfall wird bestätigt"), ("aktiv", "Ausfallschutz aktiv")\n'
)
P_SLR_ALT = '    lage = None\n    if online is None:\n        dsl, sl = ("pruefe", "wird geprüft"), ("pruefe", "wird geprüft")\n'
P_SLR_NEU = ('    lage = None\n    if cur != "starlink" or online is not True:\n        globals().get("_fs4_sl_bestaetigt", lambda on: False)(False)\n'
             '    if online is None:\n        dsl, sl = ("pruefe", "wird geprüft"), ("pruefe", "wird geprüft")\n')
P_HINT_ALT = '    """Hinweis fuer /funk SDR-Kachel. Waehrend Karenz kein OFFLINE."""\n    if live != "SDR_OFFLINE":\n'
P_HINT_NEU = ('    """Hinweis fuer /funk SDR-Kachel. Waehrend Karenz kein OFFLINE."""\n'
              '    if live == "STATUS_UNLESBAR":   # feinschliff4: Lesefehler ist kein Ausfall\n'
              '        return "SDR-Status gerade nicht lesbar (Lesefehler) – nur Systemhinweis, nicht die Lage", live\n'
              '    if live != "SDR_OFFLINE":\n')
P_LIVE_ALT = '        live_st = _lz_mgr.live(base, path, br, None, now).get("status")\n'
P_LIVE_NEU = '        live_st = globals().get("_fs4_live", _lz_mgr.live)(base, path, br, None, now).get("status")   # feinschliff4: Lesefehler eigener Zustand\n'
P_LVL_ALT = '    lvl = _los_lage(lvl, live_st, now, base)\n'
P_LVL_NEU = ('    lvl = _los_lage(lvl, live_st, now, base)\n'
             '    lvl = globals().get("_fs4_level_hook", lambda a, *b: a)(lvl, live_st, sd)   # feinschliff4: Alarm-Zeile, SDR-Text ehrlich, Starlink-Takt\n')
P_AFT_ALT = '                    s = _T4.get("status") or _t4_status_calc()\n'
P_AFT_NEU = (
    '                    s = _T4.get("status") if (_T4.get("status") and 0 <= _t4_now() - (_T4.get("status_t") or 0) <= 5) else None   # feinschliff4: frisch statt alter Zwischenspeicher\n'
    '                    if not s:\n'
    '                        if _T4_LOCK.acquire(timeout=3):\n'
    '                            try:\n'
    '                                s = _t4_status_calc()\n'
    '                            finally:\n'
    '                                _T4_LOCK.release()\n'
    '                        else:\n'
    '                            s = _T4.get("status") or {}\n'
)
P_WHY_ALT = '                    why = _t4_html_esc("Status: %s – %s" % (lv.get("label", "?"), lv.get("why", "")))\n'
P_WHY_NEU = '                    why = _t4_html_esc(lv.get("line") or ("Status: %s – %s" % (lv.get("label", "?"), lv.get("why", ""))))\n'
P_JS_ALT = "if(w)w.textContent='Status: '+v.label+' – '+(v.why||'');}"
P_JS_NEU = "if(w)w.textContent=v.line||('Status: '+v.label+' – '+(v.why||''));}"
P_GEO1_ALT = "t.indexOf('Status: ECHTALARM')===0"
P_GEO1_NEU = "/^(Status|Alarm): ECHTALARM/.test(t)"
P_GEO2_ALT = "t.indexOf('Status: VORALARM')===0"
P_GEO2_NEU = "/^(Status|Alarm): VORALARM/.test(t)"
P_HP_ALT = '        elif live:\n            out["SDR"] = (False, "")\n'
P_HP_NEU = '        elif live and live != "STATUS_UNLESBAR":   # feinschliff4: nicht lesbar ist nicht "ok"\n            out["SDR"] = (False, "")\n'
P_API_ALT = '        return jsonify(_lz_mgr.live(_SDR_BASE, _LZ_PATH, ctx.get("br24"), extra))\n'
P_API_NEU = '        return jsonify(globals().get("_fs4_live", _lz_mgr.live)(_SDR_BASE, _LZ_PATH, ctx.get("br24"), extra))   # feinschliff4\n'
P_END_ALT = '# ===== /snMask =====\n\nif __name__ == "__main__":\n'
P_END_NEU = '# ===== /snMask =====\n\n' + BLOCK + '\nif __name__ == "__main__":\n'

PATCHES = [
    ("fetch_nina", P_NINA_ALT, P_NINA_NEU), ("calculate_lage", P_LAGE_ALT, P_LAGE_NEU), ("inet starlink", P_SL_ALT, P_SL_NEU),
    ("inet reset", P_SLR_ALT, P_SLR_NEU), ("los_hint", P_HINT_ALT, P_HINT_NEU), ("t4 live", P_LIVE_ALT, P_LIVE_NEU),
    ("t4 level", P_LVL_ALT, P_LVL_NEU), ("t4_after frisch", P_AFT_ALT, P_AFT_NEU), ("t4_after Zeile", P_WHY_ALT, P_WHY_NEU),
    ("t4 JS Zeile", P_JS_ALT, P_JS_NEU), ("geo ECHTALARM", P_GEO1_ALT, P_GEO1_NEU), ("geo VORALARM", P_GEO2_ALT, P_GEO2_NEU),
    ("hp_probe", P_HP_ALT, P_HP_NEU), ("api sdr/live", P_API_ALT, P_API_NEU), ("Block", P_END_ALT, P_END_NEU),
]


def schon_dash(text):
    return "# ===== feinschliff4:" in text


def patch_dash(text):
    if schon_dash(text):
        return text
    for name, alt, neu in PATCHES:
        text = ersetze(text, alt, neu, name)
    compile(text, "dashboard.py", "exec")
    return text


def basis_pruefen(root):
    """-> (dash_raw, Meldungen). Stop bei falscher Basis."""
    def lies(n):
        p = os.path.join(root, n)
        if not os.path.isfile(p):
            raise Stop("STOP %s fehlt in %s" % (n, root))
        return open(p, "rb").read()
    d = lies("dashboard.py")
    ds = stand(d)
    if ds == DASH_PAKET2:
        raise Stop("STOP Basis stimmt nicht: dashboard.py steht noch auf Paket 2 (bfdd36d7...). Bitte zuerst Paket 3b (apply-feinschliff3b.py) installieren. Nichts veraendert.")
    if ds == DASH_P3_ALT:
        raise Stop("STOP Basis stimmt nicht: dashboard.py steht auf dem alten Paket 3 (13b30ffe...). Paket 4 setzt auf Paket 3b (d759785c...) auf. Nichts veraendert.")
    if ds not in (DASH_START, DASH_ENDE):
        raise Stop("STOP Basis stimmt nicht: dashboard.py %s/%d ist weder Paket-3b-Stand (d759785c.../1437729) noch Endstand. Nichts veraendert." % (ds[0][:16], ds[1]))
    s = stand(lies("prepper_sdr.py"))
    if s == SDR_PAKET2:
        raise Stop("STOP Basis stimmt nicht: prepper_sdr.py steht noch auf Paket 2 (0d3fc5b4...). Bitte zuerst Paket 3b installieren. Nichts veraendert.")
    if s != SDR_SOLL:
        raise Stop("STOP Basis stimmt nicht: prepper_sdr.py %s/%d ist nicht der Paket-3b-Stand (ad62d9a5.../820331). Nichts veraendert." % (s[0][:16], s[1]))
    m = stand(lies("sdr_manager.py"))
    if m != SM_SOLL:
        raise Stop("STOP Basis stimmt nicht: sdr_manager.py %s/%d ist nicht 5a26efff.../288008 (die neuen Huellen setzen ihn voraus). Nichts veraendert." % (m[0][:16], m[1]))
    print("Basis ok: dashboard.py %s (%s), prepper_sdr.py ad62d9a5 (Paket 3b), sdr_manager.py 5a26efff" % (ds[0][:16], "Paket 3b" if ds == DASH_START else "Endstand"))
    return d


def berechne(root):
    raw = basis_pruefen(root)
    t = raw.decode("utf-8")
    neu = patch_dash(t).encode("utf-8")
    if stand(neu) != DASH_ENDE:
        raise Stop("STOP Ergebnis dashboard.py %s/%d weicht vom erwarteten Endstand ab" % (stand(neu)[0][:16], len(neu)))
    return raw, (None if neu == raw else neu)


# ----------------------------------------------------------------- Live-Pruefung
SEITEN_KERN = ["/", "/pi", "/system", "/umwelt", "/aprs", "/rundfunk", "/funk"]
SEITEN_MEHR = ["/energie", "/lokale-energie", "/speicher", "/luft", "/pegel", "/adsb", "/zuhause", "/mesh", "/mesh2", "/news",
               "/karte", "/medizin", "/funk433", "/meteor", "/dabhist", "/lage"]
API_LESEN = ["/api/sdr/status", "/api/sdr/ui", "/api/sdr/wd", "/api/sdr/live", "/api/broadcast", "/api/t2/status", "/api/t4/status",
             "/api/sdr/usbw", "/api/snmask", "/api/aprs", "/api/funk433", "/api/sdr/activity", "/api/sdr/noise", "/api/uplink",
             "/api/inet_split", "/api/broadcast/events", "/api/pushover", "/api/flugfunk", "/api/lage_grund"]
ENTFERNT_404 = ["/umwelt2", "/decoder", "/scanner", "/api/pinneberg"]
NICHT_NINA = ("DSL", "Internet", "Netzfrequenz", "Frequenz", "DWD", "Daten werden")


def vorher_stand():
    codes = {}
    for p in SEITEN_KERN + SEITEN_MEHR:
        codes[p] = _get(p, 12)[0]
    return {"codes": codes}


def nina_live_check(timeout=180):
    """Live: Lage gegen die aktuelle NINA-Einstufung. Gering ausserhalb ERH (z. B. Rosstal/LK Fuerth) -> Lage NORMAL und Hinweis sichtbar."""
    t0 = time.time()
    g = None
    while time.time() - t0 < timeout:
        code, body = _get("/api/lage_grund", 10)
        if code == "200":
            try:
                g = json.loads(body)
            except ValueError:
                g = None
            if isinstance(g, dict) and g.get("nina_geladen") and isinstance(g.get("lage"), dict) and g["lage"].get("text") not in (None, "–"):
                break
        time.sleep(5)
    else:
        print("Hinweis: NINA/Lage nach %d s noch nicht geladen - Live-Check NINA offen, bitte spaeter: curl -s %s/api/lage_grund | python3 -m json.tool" % (timeout, URL))
        return True
    ok = True
    lage, nina = g["lage"], g.get("nina") or {}
    txt, grund = str(lage.get("text")), str(lage.get("reason") or "")
    print("Lage: %s - %s" % (txt, grund[:120]))
    print("NINA: gelb %d, Hinweis %d%s" % (len(nina.get("gelb") or []), len(nina.get("hinweis") or []), ", Altdaten" if nina.get("alt") else ""))
    if g.get("selftest", "").startswith("FEHLER") or not str(g.get("selftest") or "").startswith("feinschliff4 ok"):
        print("STOP feinschliff4-Selbsttest im Dienst: %s" % g.get("selftest"))
        ok = False
    if "Warnungen vorhanden" in grund:
        print("STOP Lage nennt noch den alten Text 'Warnungen vorhanden'")
        ok = False
    if txt == "AUFFÄLLIG" and grund.startswith("NINA") and not nina.get("gelb"):
        print("STOP Lage gelb wegen NINA, aber keine lagewirksame NINA-Meldung")
        ok = False
    if txt == "AUFFÄLLIG" and not grund.strip():
        print("STOP Lage gelb ohne Grund")
        ok = False
    if nina.get("gelb") and txt == "NORMAL":
        print("STOP lagewirksame NINA-Meldung, aber Lage NORMAL")
        ok = False
    code, home = _get("/", 15)
    if nina.get("hinweis_txt"):
        sichtbar = 'id="fs4Hint"' in home
        print("Hinweis-Zeile: %s (%s)" % (nina["hinweis_txt"][:110], "sichtbar" if sichtbar else "FEHLT"))
        if not sichtbar:
            print("STOP Hinweis-Zeile fehlt auf /")
            ok = False
    if any("Roßtal" in str(w.get("title")) for w in (nina.get("hinweis") or [])):
        anders = txt == "AUFFÄLLIG" and not grund.startswith("NINA") and any(k in grund for k in NICHT_NINA)
        if txt == "NORMAL" or anders:
            print("Live-Check Roßtal (gering, LK Fürth): Lage %s%s, Hinweis sichtbar" % (txt, " (anderer Grund)" if anders else ""))
        else:
            print("STOP Live-Check Roßtal: Lage %s - %s (erwartet NORMAL)" % (txt, grund[:80]))
            ok = False
    elif not nina.get("gelb") and not nina.get("hinweis"):
        print("Live-Check: derzeit keine aktive NINA-Meldung (Roßtal nicht mehr gemeldet) - Lage %s" % txt)
    return ok


def pruefe_live(seit, vorher, root=BASIS):
    ok, seiten = warte_200(SEITEN_KERN + ["/api/sdr/status", "/api/snmask", "/api/inet_split", "/api/lage_grund", "/api/t4/status"], 45)
    if not ok:
        return False
    sns = echte_seriennummern(root)
    print("geprueft gegen %d Seriennummern (aus der Konfiguration)" % len(sns))
    gesamt = n_ok = 0
    for p in SEITEN_KERN + SEITEN_MEHR + API_LESEN:
        if p in seiten:
            code, body = "200", seiten[p]
        else:
            code, body = _get(p, 12)
        if code != "200":
            if p in SEITEN_KERN or vorher["codes"].get(p) == "200" or p == "/api/lage_grund":
                print("STOP %s -> %s" % (p, code))
                ok = False
            continue
        n_ok += 1
        seiten[p] = body
        t = sn_treffer(body, sns)
        gesamt += t
        if t:
            print("STOP %s enthaelt %d echte Seriennummer(n)" % (p, t))
            ok = False
    print("%d Seiten/Antworten geprueft, echte Seriennummern: %d" % (n_ok, gesamt))
    for p in ("/", "/pi", "/funk", "/rundfunk", "/aprs"):
        if 'id="snm-js"' not in seiten.get(p, ""):
            print("STOP %s ohne snm-js (snMask)" % p)
            ok = False
        mm = re.search(r'id="sdrPiData">(.*?)</script>', seiten.get(p, ""), re.S)
        if mm:
            try:
                json.loads(mm.group(1))
            except ValueError:
                print("STOP sdrPiData auf %s kein gueltiges JSON" % p)
                ok = False
    try:
        st = json.loads(seiten.get("/api/sdr/status") or "null")
        if not (isinstance(st, dict) and "status" in st):
            raise ValueError("/api/sdr/status ohne status")
        sm = json.loads(seiten.get("/api/snmask") or "null")
        if not (isinstance(sm, dict) and sm.get("aktiv") is True and not sm.get("fehler")):
            raise ValueError("snmask nicht aktiv")
        print("/api/snmask ok: %s Namen (snMask erhalten)" % sm.get("anzahl"))
        sp = json.loads(seiten.get("/api/inet_split") or "null")
        if not (isinstance(sp, dict) and isinstance(sp.get("dsl"), dict) and isinstance(sp.get("sl"), dict)):
            raise ValueError("inet_split ohne dsl/sl")
        print("/api/inet_split ok: DSL %s, Starlink %s, Lage-Wirkung %s" % (sp["dsl"].get("txt"), sp["sl"].get("txt"), sp.get("lage")))
        t4 = json.loads(seiten.get("/api/t4/status") or "null")
        lv = (t4 or {}).get("level") or {}
        if not str(lv.get("line") or "").startswith("Alarm: "):
            raise ValueError("t4 level ohne Alarm-Zeile")
        if lv.get("lvl") == "offline":
            raise ValueError("t4 level offline (SDR-Technik darf die Lage nicht faerben)")
        print("/api/t4/status ok: %s (live %s)" % (lv["line"][:110], t4.get("live")))
        li = json.loads(seiten.get("/api/sdr/live") or "null")
        if not (isinstance(li, dict) and li.get("status")):
            raise ValueError("/api/sdr/live ohne status")
        print("/api/sdr/live ok: %s" % li.get("status"))
    except Exception as exc:
        print("STOP API-Pruefung: %s" % exc)
        ok = False
    home = seiten.get("/", "")
    if 'id="t4Why">Alarm: ' not in home or 'id="t4Why">Status: ' in home:
        print("STOP / ohne Alarm-Zeile unter der Lage")
        ok = False
    if "Warnungen vorhanden" in home:
        print("STOP / zeigt noch 'Warnungen vorhanden'")
        ok = False
    if 'id="inet-split-js"' not in home:
        print("STOP / ohne inet-split-js")
        ok = False
    for p in ("/pi", "/system"):
        if 'id="usbwBox"' not in seiten.get(p, ""):
            print("STOP %s ohne usbwBox (usbwache)" % p)
            ok = False
    if 'id="pushoverBox"' not in seiten.get("/pi", ""):
        print("STOP /pi ohne Pushover-Kachel")
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
        for pflicht in ("snMask aktiv:", "inetSplit aktiv", "usbwache Anzeige:", "feinschliff4 aktiv:"):
            if not any(pflicht in ln for ln in zeilen):
                print("STOP Journal ohne Zeile '%s'" % pflicht)
                ok = False
        for kennung in ("snMask Selbsttest FEHLER", "snMask FEHLER", "feinschliff4 Selbsttest FEHLER", "feinschliff4 FEHLER", "inetSplit FEHLER", "teil4 Lage-Seite:"):
            if any(kennung in ln for ln in zeilen):
                print("STOP Journal meldet '%s'" % kennung)
                ok = False
    except (OSError, subprocess.TimeoutExpired):
        print("STOP Journal %s unlesbar" % DIENST)
        ok = False
    if ok:
        ok = nina_live_check()
    return ok


# ----------------------------------------------------------------- Anwenden
def _rueckbau(pfad, alt, neustart):
    try:
        schreibe(pfad, alt)
        print("ZURUECKGESETZT dashboard.py sha256 %s" % stand(alt)[0])
        if neustart and restart_dienst(DIENST) == 0:
            warte_200(["/", "/pi"], 45)
    except Exception as exc:
        print("Rueckbau-Fehler: %s - bitte dashboard.py.bak-%s-* zurueckkopieren" % (exc, KENNUNG))


def anwenden(root, dry, kein):
    pfad = os.path.join(root, "dashboard.py")
    try:
        alt, neu = berechne(root)
    except Stop as exc:
        print(exc)
        return 2
    except SyntaxError as exc:
        print("STOP Syntaxfehler im Ergebnis: %s" % exc)
        return 3
    if neu is None:
        print("dashboard.py bereits auf Endstand, unveraendert")
        return 0
    print("dashboard.py %d -> %d Bytes sha256 %s" % (len(alt), len(neu), sha256(neu)))
    print("Neustart: %s" % DIENST)
    if dry:
        print("dry-run: keine Datei geschrieben, kein Neustart")
        return 0
    vorher = vorher_stand() if not kein else {"codes": {}}
    if not kein:
        print("Vorher: %d Seiten 200" % sum(1 for c in vorher["codes"].values() if c == "200"))
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    try:
        bak = sichern(pfad, stempel)
        print("Backup %s" % bak)
        schreibe(pfad, neu)
        hs, ns = stand(open(pfad, "rb").read())
        print("geschrieben dashboard.py sha256 %s bytes %d" % (hs, ns))
        if (hs, ns) != stand(neu):
            raise Stop("STOP geschriebene Datei weicht ab")
        if not pyflakes_datei(pfad):
            raise Stop("STOP pyflakes dashboard.py")
    except (Stop, OSError) as exc:
        print("%s - Rueckbau" % exc)
        _rueckbau(pfad, alt, False)
        return 4
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = restart_dienst(DIENST)
    if rc != 0:
        _rueckbau(pfad, alt, True)
        return rc
    if not pruefe_live(seit, vorher, root):
        print("STOP Pruefung fehlgeschlagen - Rueckbau (Sicherung: %s)" % os.path.basename(bak))
        _rueckbau(pfad, alt, True)
        return 5
    print("ok, Dienst: %s (prepper-sdr nicht angefasst)" % DIENST)
    return 0


# ----------------------------------------------------------------- Selbsttest (isoliert, ohne den Dienst zu importieren)
def _funcs(text, namen):
    tree = ast.parse(text)
    out = {}
    lines = text.split("\n")
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in namen and node.name not in out:
            out[node.name] = "\n".join(lines[node.lineno - 1: node.end_lineno])
    fehlt = [n for n in namen if n not in out]
    assert not fehlt, "Funktionen fehlen: %s" % fehlt
    return out


def _letzte_def(text, name):
    """Letzte Top-Level-Definition (falls spaeter ueberschrieben)."""
    tree = ast.parse(text)
    lines = text.split("\n")
    src = None
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            src = "\n".join(lines[node.lineno - 1: node.end_lineno])
    assert src, name
    return src


def _ns(t):
    i = t.index("# ===== feinschliff4:")
    j = t.index("# --- /fs4 rein ---", i)
    ns = {"__name__": "fs4test"}
    exec(compile(t[i:j], "fs4-rein", "exec"), ns)
    for name in ("nina_is_alert", "_inet_split", "calculate_lage", "_los_lage", "_los_hint", "_fs4_selftest"):
        exec(compile(_letzte_def(t, name), name, "exec"), ns)
    ns["US"] = {"current": "telekom", "stale": False, "signals": {}}
    ns["_t4_us"] = lambda: ns["US"]
    ns["_los_grace"] = lambda now: False
    ns["LOS_GRACE_S"] = 120
    ns["_T2D"] = {"nina": {}}
    return ns


ROSSTAL = {"city": "LK Fürth", "title": "Trinkwasserverschmutzung - Kerngebiet Roßtal, Buttendorf, Neuses, Stöckach, Weitersdorf (teilweise)",
           "id": "mow.DE-BY-N-SE137-20261110-166-000", "msgType": "Update", "sent": "2026-11-10T17:12:47+01:00", "expires": None, "severity": "Minor"}


def _lage(ns, nina, online=True, cur="telekom", freq=50.0, dwd=0, slot_extra=None):
    ns["US"] = {"current": cur, "stale": False, "signals": {}}
    slot = dict({"value": nina, "updated": "x"}, **(slot_extra or {}))
    d = {"internet": {"value": online}, "frequenz": {"value": freq}, "nina": slot, "dwd_warn": {"value": {"max_level": dwd}},
         "sdr": {"status": "SDR_OFFLINE"}, "usbw": {"lvl": "rot"}, "sdr_wd": {"lvl": "rot"}}
    return ns["calculate_lage"](d)


def _selftest_lage(t):
    ns = _ns(t)
    r = ns["_fs4_selftest"]()
    assert r.startswith("feinschliff4 ok"), r
    print("selftest Block: %s" % r[:90])
    ns["_FS4"]["sl_since"] = None
    # Live-Fall: Rosstal gering, LK Fuerth -> NORMAL, Hinweis
    x = _lage(ns, [ROSSTAL])
    assert x[0] == "NORMAL", x
    h = ns["_fs4_nina_lage"]({"value": [ROSSTAL]})
    assert h["hinweis_txt"] and "Roßtal" in h["hinweis_txt"] and not h["gelb"]
    # dasselbe ohne severity im Dashboard-Feld, aber Teil-2-Detail Minor -> Hinweis; Detail Severe -> gelb
    ros0 = dict(ROSSTAL)
    ros0.pop("severity")
    ns["_T2D"] = {"nina": {ROSSTAL["id"]: {"severity": "Minor", "status": "Actual"}}}
    assert _lage(ns, [ros0])[0] == "NORMAL"
    ns["_T2D"] = {"nina": {ROSSTAL["id"]: {"severity": "Severe", "status": "Actual"}}}
    assert _lage(ns, [ros0])[0] == "AUFFÄLLIG"
    ns["_T2D"] = {"nina": {}}
    x = _lage(ns, [ros0])
    assert x[0] == "AUFFÄLLIG" and x[2].startswith("NINA: Trinkwasser"), "unbekannter Grad bleibt vorsichtig gelb"
    x = _lage(ns, [dict(ROSSTAL, city="LK Erlangen-Höchstadt")])
    assert x[0] == "AUFFÄLLIG" and x[2].startswith("NINA: Trinkwasserverschmutzung") and x[2].endswith("(LK Erlangen-Höchstadt)"), x
    for sev in ("Moderate", "Severe", "Extreme"):
        x = _lage(ns, [dict(ROSSTAL, severity=sev)])
        assert x[0] == "AUFFÄLLIG" and "(LK Fürth)" in x[2], (sev, x)
    x = _lage(ns, [dict(ROSSTAL, severity="Moderate"), dict(ROSSTAL, id="b", title="Gefahrstoff", city="Nürnberg", severity="Severe")])
    assert x[2].startswith("NINA: Gefahrstoff (Nürnberg)") and "+1 weitere" in x[2], x
    for w in (dict(ROSSTAL, severity="Severe", msgType="Cancel"), dict(ROSSTAL, severity="Severe", title="Probewarnung"),
              dict(ROSSTAL, severity="Severe", title="Warntag: Probewarnung"), dict(ROSSTAL, severity="Severe", status="Exercise"),
              dict(ROSSTAL, severity="Severe", status="Test"), dict(ROSSTAL, severity="Severe", title="Übung Katastrophenschutz"),
              dict(ROSSTAL, severity="Severe", expires="2026-01-01T10:00:00+01:00"), dict(ROSSTAL, severity="Severe", title="Entwarnung Trinkwasser"),
              dict(ROSSTAL, severity="Severe", title="SIM: Verunreinigung Trinkwasser")):
        assert _lage(ns, [w])[0] == "NORMAL", w
    assert _lage(ns, [dict(ROSSTAL, severity="Moderate", title="Trinkwasserprobe positiv")])[0] == "AUFFÄLLIG"
    alt = datetime.fromtimestamp(time.time() - 3 * 3600).strftime("%d.%m.%Y %H:%M:%S")
    frisch = datetime.fromtimestamp(time.time() - 1200).strftime("%d.%m.%Y %H:%M:%S")
    assert _lage(ns, [dict(ROSSTAL, severity="Severe")], slot_extra={"error": True, "updated": alt})[0] == "NORMAL", "Altdaten > 2 h nie gelb"
    assert _lage(ns, [dict(ROSSTAL, severity="Severe")], slot_extra={"error": True, "updated": "kaputt"})[0] == "NORMAL"
    x = _lage(ns, [dict(ROSSTAL, severity="Severe")], slot_extra={"error": True, "updated": frisch})
    assert x[0] == "AUFFÄLLIG" and "Stand" in x[2], x
    assert _lage(ns, [])[0] == "NORMAL"
    print("selftest NINA ok (Rosstal gering LK Fuerth = NORMAL + Hinweis; ERH/mittel/schwer gelb mit Namen; Aufhebung/Probe/Uebung/Test/abgelaufen/SIM raus; Altdaten > 2 h nie gelb)")
    # Rot-Pfade unveraendert
    assert _lage(ns, [], online=False)[0] == "KRITISCH"
    assert _lage(ns, [], freq=49.7)[0] == "KRITISCH"
    assert _lage(ns, [dict(ROSSTAL, severity="Severe")], online=False)[0] == "KRITISCH"
    assert _lage(ns, [], dwd=3)[0] == "AUFFÄLLIG" and _lage(ns, [], freq=49.93)[2] == "Frequenz auffällig"
    assert _lage(ns, [], online=None)[0] == "–"
    # Starlink: still/unbekannt nie gelb, aktiv erst nach 120 s
    ns["US"] = {"current": "telekom", "stale": False, "signals": {}}
    sp = ns["_inet_split"]({"internet": {"value": True}})
    assert sp["sl"]["lvl"] == "still" and sp["lage"] is None
    assert _lage(ns, [], cur="telekom")[0] == "NORMAL"
    ns["_FS4"]["sl_since"] = None
    assert _lage(ns, [], cur="starlink")[0] == "NORMAL", "Starlink nicht sofort gelb"
    sp = ns["_inet_split"]({"internet": {"value": True}})
    assert sp["lage"] is None and sp["dsl"]["txt"] == "Ausfall wird bestätigt"
    ns["_FS4"]["sl_since"] -= 121
    x = _lage(ns, [], cur="starlink")
    assert x[0] == "AUFFÄLLIG" and x[2].startswith("DSL ausgefallen"), x
    assert _lage(ns, [], cur="telekom")[0] == "NORMAL" and ns["_FS4"]["sl_since"] is None, "Reset bei DSL wieder da"
    assert _lage(ns, [], cur="unclear")[0] == "NORMAL" and _lage(ns, [], cur=None)[0] == "NORMAL"
    print("selftest Internet ok (Starlink still/unklar nie gelb, aktiv gelb erst nach 120 s, Reset, DSL+Starlink weg rot)")
    # SDR/Technik nie in der Lage
    src = _letzte_def(t, "calculate_lage")
    low = src.lower()
    for bad in ("sdr", "usbw", "watchdog", "_wd", "stick", "t4_"):
        assert bad not in low, "calculate_lage liest %s" % bad
    lo = ns["_los_lage"]({"lvl": "offline", "label": "SDR_OFFLINE", "blink": True, "why": "SDR_OFFLINE: x", "notes": []}, "SDR_OFFLINE")
    assert lo["lvl"] == "ok" and lo["blink"] is False
    o = ns["_fs4_level"](lo, "SDR_OFFLINE", {"wd": {"lvl": "rot"}})
    assert o["line"].startswith("Alarm: keiner") and "nur Technikhinweis" in o["line"] and o["lvl"] == "ok" and not o["blink"], o
    ok = {"lvl": "ok", "label": "OK", "blink": False, "why": "kein echter Alarm, keine ASA-Probe, SDR liefert Daten, kein Vor-Alarm", "notes": []}
    o = ns["_fs4_level"](ok, "STATUS_UNLESBAR", {"wd": {"lvl": "ok"}})
    assert "SDR-Status nicht lesbar" in o["line"] and o["lvl"] == "ok" and not o["blink"]
    assert "SDR-Empfang ungeprüft" in ns["_fs4_level"](ok, "ECHTALARM", {"wd": None})["line"]
    assert ns["_fs4_level"](ok, "ECHTALARM", {"wd": {"lvl": "ok"}})["line"] == "Alarm: keiner · keine ASA-Probe · SDR liefert Daten · kein Vor-Alarm"
    pre = ns["_fs4_level"]({"lvl": "pre", "label": "VORALARM NETZFREQUENZ", "blink": True, "why": "VORALARM NETZ: x"}, "SDR_OFFLINE", {"wd": {}})
    assert pre["line"].startswith("Alarm: VORALARM") and pre["blink"], "Netz-Voralarm bleibt"
    h, live = ns["_los_hint"]("STATUS_UNLESBAR", 0)
    assert live == "STATUS_UNLESBAR" and "nicht lesbar" in h and "OFFLINE" not in h
    assert ns["_los_hint"]("ECHTALARM", 0) == (None, "ECHTALARM")
    print("selftest SDR ok (calculate_lage ohne SDR/usbwache/Watchdog, SDR_OFFLINE = ok ohne Blinken, nicht lesbar/ungeprueft ehrlich, Netz-Voralarm bleibt)")

    class DB:
        e = [None]

        def last_error(self):
            return self.e[0]

    class M:
        def __init__(self, res, err=None):
            self.db, self.res, self.err = DB(), res, err

        def live(self, *a):
            if self.err:
                self.db.e[0] = self.err
            return dict(self.res)
    lc = ns["_fs4_live_core"]
    assert lc(M({"status": "SDR_OFFLINE", "error": "boom"}), "/b")["status"] == "STATUS_UNLESBAR"
    assert lc(M({"status": "SDR_OFFLINE", "watchdog": {"newest_ts": 100, "age_s": 999}}), "/b")["status"] == "SDR_OFFLINE", "echter Ausfall bleibt"
    assert lc(M({"status": "SDR_OFFLINE", "watchdog": {"newest_ts": None}}, err="database is locked"), "/b")["status"] == "STATUS_UNLESBAR"
    assert lc(M({"status": "SDR_OFFLINE", "watchdog": {"newest_ts": 100}}, err="database is locked x"), "/b")["status"] == "SDR_OFFLINE"
    assert lc(M({"status": "ECHTALARM"}, err="y"), "/b")["status"] == "ECHTALARM"
    print("selftest live ok (Lesefehler = STATUS_UNLESBAR, alte Telemetrie = SDR_OFFLINE)")
    # Seiten-Einbau: teil4/geo finden den Kasten weiter
    b = '<html><head></head><body><div class="lage normal">\n  <span class="lage-icon">🛡</span>\n  LAGE: NORMAL\n  <small>Keine akuten Gefahrenlagen erfasst.</small>\n  <small style="opacity:0.75;margin-top:4px">Nächste Voll-Bewertung in 4 min</small>\n</div></body></html>'
    hb = ns["_fs4_inject"](b, h and ns["_fs4_nina_lage"]({"value": [ROSSTAL]})["hinweis_txt"])
    assert re.search(r'<div class="lage (normal|auffaellig|kritisch|neutral)">', hb) and 'id="fs4Hint"' in hb and "Roßtal" in hb
    i = hb.find('<div class="lage ')
    assert hb.find('id="fs4Hint"') < hb.find("</div>", i)
    assert "/^(Status|Alarm): ECHTALARM/.test(t)" in t and "/^(Status|Alarm): VORALARM/.test(t)" in t and "w.textContent=v.line||(" in t
    assert "Warnungen vorhanden" not in src
    for muss in ("def _inet_split(", "# ===== snMask:", "def _snm_after(", "def _usbw_selftest_inner(", 'id="pushoverBox"', "/api/lage_grund", "_psh_cfg_sauber"):
        assert muss in t, muss
    print("selftest Seite ok (Hinweis einzeilig im Lage-Kasten, teil4/geo-Anker, Alarm-Zeile; snMask/inet_split/usbwache/Pushover/_psh_cfg_sauber erhalten)")


def selftest(basis=BASIS):
    try:
        assert _restart_ok(1, {"pid": "1", "ts": "a", "active": "active"}, {"pid": "2", "ts": "b", "active": "active"}) is False
        assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "10", "ts": "A", "active": "active"}) is False
        assert _restart_ok(0, {"pid": "10", "ts": "A", "active": "active"}, {"pid": "11", "ts": "B", "active": "active"}) is True
        print("selftest Neustart-Check ok")
        raw = basis_pruefen(basis)
        t0 = raw.decode("utf-8")
        t = patch_dash(t0)
        assert patch_dash(t) == t, "nicht idempotent"
        assert stand(t.encode("utf-8")) == DASH_ENDE, "Endhash %s" % stand(t.encode("utf-8"))[0][:16]
        print("selftest Patch, Idempotenz, Endhash ok")
        _selftest_lage(t)
        tmp = tempfile.mkdtemp(prefix="feinschliff4-st-")
        try:
            for n in ("dashboard.py", "prepper_sdr.py", "sdr_manager.py"):
                shutil.copy2(os.path.join(basis, n), os.path.join(tmp, n))
            erst = stand(raw) == DASH_START
            assert anwenden(tmp, True, True) == 0
            assert stand(open(os.path.join(tmp, "dashboard.py"), "rb").read()) == stand(raw), "dry-run hat geschrieben"
            assert anwenden(tmp, False, True) == 0
            assert stand(open(os.path.join(tmp, "dashboard.py"), "rb").read()) == DASH_ENDE
            assert (not erst) or any(p.startswith("dashboard.py.bak-" + KENNUNG) for p in os.listdir(tmp)), "kein Backup"
            assert anwenden(tmp, False, True) == 0
            if erst:
                _rueckbau(os.path.join(tmp, "dashboard.py"), raw, False)
                assert stand(open(os.path.join(tmp, "dashboard.py"), "rb").read()) == DASH_START, "Rueckbau stellt das Original nicht her"
            open(os.path.join(tmp, "dashboard.py"), "w").write("x = 1\n")
            assert anwenden(tmp, True, True) == 2, "falsche Basis muss stoppen"
            print("selftest apply auf Kopie ok (dry-run schreibt nicht, Backup, Endhash, zweiter Lauf ohne Aenderung, Rueckbau, falsche Basis stoppt)")
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
