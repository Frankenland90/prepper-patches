#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-acarsklar: Datalink-Kachel ACARS/VDL2 auf /adsb zeigt mehr Klartext. Nur lokal (§ 5 TTDSG), nichts wird gesendet.

Basis: dashboard.py nach Paket 8 (e27446eb.../1476113). Neustart: nur prepper-dashboard (prepper-sdr wird nicht angefasst).
Aenderungen:
- Neue Datei acars_klar.py (Klartext-Modul): Positionsmeldungen aus dem Text (drei Formen, u.a. "MASEK ,N 50.443,E 10.117,32000,...\\TS121853,281126"
  und "/.POS/TS122123,281126N49266E011005,..."), Labels/Kuerzel auf Deutsch (Q0, SQ, SA, H1, 5Z, 5U, _d, QA-QD/OOOI, RESREQ, Gate, Wetteranfrage),
  libacars-Inhalte (ARINC 622 ADS-C/CPDLC, Media Advisory) lesbar, soweit der Decoder sie liefert.
- dashboard.py: ein Block hinter dem acarsKachel-Block haengt das Modul an acars_kachel (Anzeige und /api/acars; Rohtext bleibt einklappbar).
  /api/acars bekommt zusaetzlich "punkte" (Fluege ohne ADS-B-Radar mit gelesener Position) fuer eine spaetere Karten-Ebene; gezeichnet wird nichts.
- acars_kachel.py: ein kleiner Haken in extract() legt den libacars-Klartext beim Einlesen ab. Greift erst, wenn prepper-sdr acars_kachel neu laedt
  (naechster ohnehin faelliger SDR-Neustart); bis dahin laufen Positionen und Label-Namen schon beim Anzeigen. Passt die Datei nicht zur bekannten Basis, bleibt sie unveraendert.
Version 2: Die Live-Pruefung wartet auf das erste Voll-Update (sysBoot); Layout-Marker wie navUnify sind nur noch ein Hinweis.
Nichts wird installiert, gesendet oder weitergeleitet. Keine Seriennummern, keine Mesh-Wege. Info: Decoder-Pruefung per readelf/ldd (nur Lesen)."""
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
import sys
import tempfile
import time
import zlib
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "acarsklar"
BASIS = "/home/fmg/prepper-dashboard"
DIENST = "prepper-dashboard"
FESTE_SN = ()
VORGAENGER = "Paket 8"
DASH_START = ('e27446ebbff47cc0de9337b8108d7e5832fe28cf28d798d341f485a7b620d1a4', 1476113)   # Stand nach Paket 8
DASH_ENDE = ('8d0a09e8ad76f8fa27faef1020da54c3ae9b3b2ada3a5aef784db9291f59c0a6', 1476602)
KACHEL_START = ('68f52f16a3949fd2b1f9086bb70b91626a1f33a968bf5edcce28a75d4fed91b3', 38999)    # acars_kachel.py wie bisher
KACHEL_ENDE = ('278b5bc287f5187674e0c79a9b3821475fd35c1f29f1084571a6457d71bb6fc2', 39105)
KLAR_SHA = ('9155c20f69fef53ce209fed5bbf3270af5af0482aeb7c5c94f0bc5fcd09f5667', 30466)       # acars_klar.py (eingebettet)
SDR_SOLL = ("ad62d9a56c6aa682246945bae7b65eaa75afb216b5a20dd1d4881ea42cc0d85c", 820331)      # prepper_sdr.py nach Paket 3b (unveraendert)
SM_SOLL = ("5a26efff608bf541a929fa775112d3593883a7423b6d9f6f29e61dc9b14db181", 288008)       # sdr_manager.py (unveraendert)
JOURNAL_PFLICHT = ["acarsKachel aktiv:", "acarsKlar aktiv:"]
JOURNAL_VERBOTEN = ["acarsKlar FEHLER", "acarsKachel FEHLER", "snMask FEHLER", "snMask Selbsttest FEHLER"]
PAGE_MARKER = ("snm-js", "inet-split-js", "usbwBox", "pushoverBox", "t4Why", "navUnify", "sdrCard", "flugfunkBox", "acarsBox")


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


# ----------------------------------------------------------------- Paket
KLAR_ZB64 = """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"""


def klar_quelle():
    return zlib.decompress(base64.b64decode("".join(KLAR_ZB64.split())))


SCHON = "# ===== acarsKlar:"

BLOCK = r"""# ===== acarsKlar: Datalink-Kachel (/adsb) in Klartext - Positionen, Label-Namen, libacars-Zeilen; nur lokal, sendet nichts =====
try:
    if "_ak" not in globals():
        raise RuntimeError("acars_kachel nicht geladen")
    import acars_klar as _akl
    _akl_st = _akl.selftest()
    _akl_in = _akl.install(_ak)
    print("acarsKlar aktiv: %s; %s" % (_akl_st, _akl_in), flush=True)
except Exception as _akl_e:
    print("acarsKlar FEHLER:", _akl_e, flush=True)
# ===== /acarsKlar =====
"""

P_ALT = '# ===== /acarsKachel =====\n'
P_NEU = '# ===== /acarsKachel =====\n' + BLOCK
PATCHES = [("Block", P_ALT, P_NEU)]

K_ALT = '    art, klar, gelb, rot, extra = deuten(rec)\n    rec["art"] = art\n'
K_NEU = ('    try:\n        import acars_klar as _kl\n        _kl.ingest(rec, obj)\n    except Exception:\n        pass\n') + K_ALT


def patch_dash(text):
    if SCHON in text:
        return text
    for name, alt, neu in PATCHES:
        text = ersetze(text, alt, neu, name)
    compile(text, "dashboard.py", "exec")
    return text


def patch_kachel(text):
    if "_kl.ingest(rec, obj)" in text:
        return text
    text = ersetze(text, K_ALT, K_NEU, "acars_kachel extract")
    compile(text, "acars_kachel.py", "exec")
    return text


def lies(root, n, pflicht=True):
    p = os.path.join(root, n)
    if not os.path.isfile(p):
        if pflicht:
            raise Stop("STOP %s fehlt in %s" % (n, root))
        return None
    with open(p, "rb") as fh:
        return fh.read()


def basis_pruefen(root):
    """-> dashboard.py (bytes). Stop bei falscher Basis."""
    d = lies(root, "dashboard.py")
    ds = stand(d)
    if ds not in (DASH_START, DASH_ENDE):
        raise Stop("STOP Basis stimmt nicht: dashboard.py %s/%d ist weder der Stand nach %s (%s.../%d) noch der Endstand. Nichts veraendert." % (
            ds[0][:16], ds[1], VORGAENGER, DASH_START[0][:8], DASH_START[1]))
    s = stand(lies(root, "prepper_sdr.py"))
    if s != SDR_SOLL:
        raise Stop("STOP Basis stimmt nicht: prepper_sdr.py %s/%d ist nicht ad62d9a5.../820331. Nichts veraendert." % (s[0][:16], s[1]))
    m = stand(lies(root, "sdr_manager.py"))
    if m != SM_SOLL:
        raise Stop("STOP Basis stimmt nicht: sdr_manager.py %s/%d ist nicht 5a26efff.../288008. Nichts veraendert." % (m[0][:16], m[1]))
    print("Basis ok: dashboard.py %s (%s), prepper_sdr.py ad62d9a5, sdr_manager.py 5a26efff" % (ds[0][:16], "Stand nach " + VORGAENGER if ds == DASH_START else "Endstand"))
    return d


def berechne(root):
    """-> Liste (name, alt|None, neu|None). neu None = unveraendert."""
    raw = basis_pruefen(root)
    d_neu = patch_dash(raw.decode("utf-8")).encode("utf-8")
    if stand(d_neu) != DASH_ENDE:
        raise Stop("STOP Ergebnis dashboard.py %s/%d weicht vom erwarteten Endstand ab" % (stand(d_neu)[0][:16], len(d_neu)))
    k_alt = lies(root, "acars_kachel.py")
    ks = stand(k_alt)
    if ks == KACHEL_START:
        k_neu = patch_kachel(k_alt.decode("utf-8")).encode("utf-8")
        if stand(k_neu) != KACHEL_ENDE:
            raise Stop("STOP Ergebnis acars_kachel.py %s/%d weicht vom erwarteten Endstand ab" % (stand(k_neu)[0][:16], len(k_neu)))
        print("acars_kachel.py: bekannte Basis, Haken fuer libacars-Klartext wird eingesetzt")
    elif ks == KACHEL_ENDE:
        k_neu = None
        print("acars_kachel.py: Haken schon vorhanden")
    else:
        k_neu = None
        print("Hinweis: acars_kachel.py %s/%d ist nicht die bekannte Basis - bleibt unveraendert; libacars-Klartext beim Einlesen entfaellt, Positionen und Label-Namen laufen trotzdem" % (ks[0][:16], ks[1]))
    l_alt = lies(root, "acars_klar.py", pflicht=False)
    l_src = klar_quelle()
    if stand(l_src) != KLAR_SHA:
        raise Stop("STOP eingebettetes acars_klar.py %s/%d stimmt nicht" % (stand(l_src)[0][:16], len(l_src)))
    l_neu = None if l_alt == l_src else l_src
    plan = [("acars_klar.py", l_alt, l_neu), ("acars_kachel.py", k_alt, k_neu), ("dashboard.py", raw, None if d_neu == raw else d_neu)]
    return plan


def schreibe_mit_vorlage(pfad, daten, vorlage):
    existiert = os.path.exists(pfad)
    schreibe(pfad, daten)
    if not existiert and os.path.exists(vorlage):
        st = os.stat(vorlage)
        try:
            os.chown(pfad, st.st_uid, st.st_gid)
            os.chmod(pfad, stat.S_IMODE(st.st_mode))
        except OSError as exc:
            print("Hinweis: Besitzer/Modus %s nicht gesetzt (%s)" % (pfad, exc))


# ----------------------------------------------------------------- Decoder-Pruefung (nur Lesen)
def decoder_pruefung():
    """Ist libacars in den Decodern gelinkt? Nur Lesen (readelf/ldd), nichts wird gestartet oder installiert."""
    erg = {}
    for name in ("dumpvdl2", "acarsdec"):
        pfad = None
        for cand in (shutil.which(name), "/usr/local/bin/" + name, "/usr/bin/" + name):
            if cand and os.path.isfile(cand):
                pfad = cand
                break
        if not pfad:
            erg[name] = "nicht installiert"
            continue
        out = ""
        for cmd in (["readelf", "-d", pfad], ["ldd", pfad]):
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            except (OSError, subprocess.TimeoutExpired):
                continue
            if r.returncode == 0 and r.stdout:
                out = r.stdout
                break
        if not out:
            erg[name] = "unklar (readelf/ldd nicht verfuegbar)"
        elif "libacars" in out:
            erg[name] = "libacars gelinkt"
        else:
            erg[name] = "KEIN libacars gelinkt"
    return erg


def decoder_bericht():
    erg = decoder_pruefung()
    print("Decoder: dumpvdl2 %s · acarsdec %s" % (erg["dumpvdl2"], erg["acarsdec"]))
    if erg["acarsdec"].startswith("KEIN") or erg["dumpvdl2"].startswith("KEIN"):
        print("Hinweis: ohne libacars kommen ARINC-622-/CPDLC-Zahlenbloecke nur als Rohtext. Pruefen: "
              "ldd $(command -v acarsdec) $(command -v dumpvdl2) | grep -i acars")
    return erg


# ----------------------------------------------------------------- Live-Pruefung
SEITEN_KERN = ["/", "/pi", "/adsb", "/api/acars"]
SEITEN_MEHR = ["/system", "/umwelt", "/aprs", "/rundfunk", "/funk", "/energie", "/lokale-energie", "/speicher", "/luft", "/pegel", "/zuhause",
               "/mesh", "/mesh2", "/news", "/karte", "/medizin", "/funk433", "/meteor", "/dabhist", "/lage",
               "/api/sdr/status", "/api/sdr/ui", "/api/sdr/live", "/api/t4/status", "/api/snmask", "/api/inet_split", "/api/lage_grund",
               "/api/aprs", "/api/flugfunk", "/api/acars?interessant=0"]


def _fehler_keys(zeilen):
    out = set()
    for ln in zeilen:
        if "Traceback" in ln or "FEHLER" in ln:
            out.add(re.sub(r"[0-9]+", "#", ln)[:48])
    return out


def journal_vorher():
    """FEHLER-/Traceback-Zeilen des laufenden Dienstes seit seinem Start (Vergleichsbasis). None, wenn nicht lesbar."""
    snap = _unit_snap(DIENST)
    for seit in (snap.get("ts") or "", "-3 days"):
        if not seit:
            continue
        try:
            r = subprocess.run(["journalctl", "-u", DIENST, "--since", seit, "-o", "cat", "-n", "6000"], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        zeilen = (r.stdout or "").splitlines()
        if r.returncode == 0 and any("aktiv:" in ln for ln in zeilen):
            return _fehler_keys(zeilen)
    return None


def vorher_stand():
    codes, marker = {}, {}
    for p in SEITEN_KERN + SEITEN_MEHR:
        code, body = _get(p, 12)
        codes[p] = code
        if code == "200" and 'id="sbLoading"' not in body:
            marker[p] = [m for m in PAGE_MARKER if m in body]
    return {"codes": codes, "marker": marker, "fehler": journal_vorher()}


def acars_statistik(root):
    """Zaehler ueber acars_msgs.jsonl (2 Tage) - nur Info. Import ohne .pyc im Programmordner."""
    code = ("import sys,json;sys.dont_write_bytecode=True;sys.path.insert(0,%r)\n"
            "import acars_kachel as ak, acars_klar as kl\n"
            "r=ak.laden(%r)\n"
            "print(json.dumps(kl.statistik(r)))\n" % (root, root))
    try:
        r = subprocess.run([sys.executable, "-B", "-c", code], capture_output=True, text=True, timeout=40, cwd=tempfile.gettempdir())
        return json.loads((r.stdout or "").strip().splitlines()[-1])
    except Exception:
        return None


def warte_bereit(timeout=150):
    """Wartet auf das erste Voll-Update (sysBoot). Bis dahin liefert der Dienst bei manchen Seiten (/, /system, /umwelt, /energie, /speicher)
    mit 200 nur den Ladehinweis 'Dashboard startet' ohne Navigation - das ist kein Zustand, an dem man Layout misst."""
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


def pruefe_live(seit, vorher, root=BASIS):
    # 1) Die Seiten, die es braucht, antworten (kein Annahme ueber den Inhalt von /)
    ok, seiten = warte_200(SEITEN_KERN, 45)
    if not ok:
        return False
    war200 = [p for p in SEITEN_MEHR if vorher["codes"].get(p) == "200"]
    ok2, mehr = warte_200(war200, 45) if war200 else (True, {})
    seiten.update(mehr)
    if not ok2:
        print("STOP eine vorher erreichbare Seite antwortet nicht mehr")
        ok = False
    bereit = warte_bereit(int(os.environ.get("FS_BEREIT_WAIT") or 150))
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
    # 2) keine Seriennummern, nichts verloren
    sns = echte_seriennummern(root)
    gesamt = 0
    for p, body in seiten.items():
        t = sn_treffer(body, sns)
        gesamt += t
        if t:
            print("STOP %s enthaelt %d echte Seriennummer(n)" % (p, t))
            ok = False
    print("%d Seiten/Antworten geprueft (%d Seriennummern aus der Konfiguration), echte Seriennummern: %d" % (len(seiten), len(sns), gesamt))
    for p, ms in (vorher.get("marker") or {}).items():
        if p in seiten and p not in laed:
            fehlt = [m for m in ms if m not in seiten[p] and m != "acarsBox"]
            if fehlt:
                print("Hinweis: %s ohne %s gegenueber vorher (Layout, nicht dieses Paket - kein Rollback-Grund)" % (p, ", ".join(fehlt)))
    # 3) /api/acars und die Kachel
    try:
        api = json.loads(seiten.get("/api/acars") or "null")
        if not (isinstance(api, dict) and api.get("ok") is True and isinstance(api.get("fluege"), list)):
            raise ValueError("/api/acars ohne ok/fluege")
        if api.get("klartext") is not True or not isinstance(api.get("punkte"), list):
            raise ValueError("/api/acars ohne klartext/punkte (acarsKlar nicht eingehaengt)")
        zeilen = [z for g in api["fluege"] for z in (g.get("zeilen") or [])]
        for z in zeilen:
            if not isinstance(z.get("klar"), str) or len(z["klar"].split("\n")) > 5:
                raise ValueError("Zeile ohne Klartext oder zu lang")
        print("/api/acars ok: %d Fluege, %d Zeilen, %d Punkte ohne Radar%s" % (
            len(api["fluege"]), len(zeilen), len(api["punkte"]), "" if zeilen else " (gerade keine Meldung - kein Fehler)"))
        for z in [z for z in zeilen if z.get("art") in ("position", "phase", "wetter", "bord")][:3]:
            print("  Beispiel: " + z["klar"].replace("\n", " | ")[:140])
    except Exception as exc:
        print("STOP API-Pruefung: %s" % exc)
        ok = False
    ad = seiten.get("/adsb", "")
    if "/adsb" in laed:
        print("Hinweis: /adsb zeigt noch den Ladehinweis - Kachel nicht geprueft; spaeter: curl -s %s/adsb | grep -c acarsBox" % URL)
    elif ad.count('id="acarsBox"') != 1 or 'id="acars-js"' not in ad:
        print("STOP /adsb: Datalink-Kachel nicht genau einmal da")
        ok = False
    elif 'L.slice(1)' in ad:
        print("/adsb ok: Datalink-Kachel einmal, mehrzeiliger Klartext, Rohtext einklappbar")
    else:
        print("Hinweis: /adsb Kachel da, aber ohne mehrzeilige Darstellung (Zeilen erscheinen hintereinander)")
    if "/adsb" not in laed and "Rohtext" not in ad:
        print("STOP /adsb: 'Rohtext' fehlt")
        ok = False
    st = acars_statistik(root)
    if st:
        print("ACARS 2 Tage: %d Meldungen, %d mit lesbarer Position, %d mit libacars-Klartext, %d ARINC-622-Texte" % (st["n"], st["pos"], st["lc"], st["a622"]))
        if st["a622"] and not st["lc"]:
            print("Hinweis: ARINC-622-Texte vorhanden, libacars-Klartext wird erst nach dem naechsten prepper-sdr-Neustart mitgespeichert")
    # 4) Journal
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
        print("STOP Journal %s unlesbar" % DIENST)
        ok = False
    # 5) Lage nur zur Info (kein Rollback-Grund)
    code, body = _get("/api/lage_grund", 10)
    if code == "200":
        try:
            print("Lage (Info): %s" % str((json.loads(body).get("lage") or {}).get("text")))
        except ValueError:
            pass
    return ok


# ----------------------------------------------------------------- Anwenden
def _rueckbau(plan, geschrieben, neustart, root):
    try:
        for name, alt, neu in reversed(plan):
            if name not in geschrieben:
                continue
            pfad = os.path.join(root, name)
            if alt is None:
                if os.path.exists(pfad):
                    os.remove(pfad)
                print("ZURUECKGESETZT %s entfernt (war neu)" % name)
            else:
                schreibe(pfad, alt)
                print("ZURUECKGESETZT %s sha256 %s" % (name, stand(alt)[0]))
        if neustart and restart_dienst(DIENST) == 0:
            warte_200(["/", "/pi"], 45)
    except Exception as exc:
        print("Rueckbau-Fehler: %s - bitte *.bak-%s-* zurueckkopieren" % (exc, KENNUNG))


def anwenden(root, dry, kein):
    try:
        plan = berechne(root)
    except Stop as exc:
        print(exc)
        return 2
    except SyntaxError as exc:
        print("STOP Syntaxfehler im Ergebnis: %s" % exc)
        return 3
    aendern = [(n, a, b) for n, a, b in plan if b is not None]
    if not aendern:
        print("bereits auf Endstand, unveraendert")
        decoder_bericht()
        return 0
    for n, a, b in aendern:
        print("%s %s -> %d Bytes sha256 %s" % (n, ("%d" % len(a)) if a is not None else "neu", len(b), sha256(b)))
    print("Neustart: %s (prepper-sdr nicht angefasst)" % DIENST)
    decoder_bericht()
    if dry:
        print("dry-run: keine Datei geschrieben, kein Neustart")
        return 0
    vorher = vorher_stand() if not kein else {"codes": {}, "marker": {}, "fehler": None}
    if not kein:
        print("Vorher: %d Seiten 200" % sum(1 for c in vorher["codes"].values() if c == "200"))
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    geschrieben = []
    try:
        for n, a, b in aendern:
            pfad = os.path.join(root, n)
            if a is not None:
                print("Backup %s" % sichern(pfad, stempel))
        bak_dash = None
        for n, a, b in aendern:
            pfad = os.path.join(root, n)
            geschrieben.append(n)
            schreibe_mit_vorlage(pfad, b, os.path.join(root, "acars_kachel.py"))
            hs, ns = stand(open(pfad, "rb").read())
            print("geschrieben %s sha256 %s bytes %d" % (n, hs, ns))
            if (hs, ns) != stand(b):
                raise Stop("STOP geschriebene Datei %s weicht ab" % n)
            if n == "dashboard.py":
                bak_dash = [p for p in sorted(os.listdir(root)) if p.startswith("dashboard.py.bak-%s-" % KENNUNG)][-1:]
        if bak_dash and not pyflakes_vergleich(os.path.join(root, bak_dash[0]), os.path.join(root, "dashboard.py")):
            raise Stop("STOP pyflakes dashboard.py")
    except (Stop, OSError) as exc:
        print("%s - Rueckbau" % exc)
        _rueckbau(plan, geschrieben, False, root)
        return 4
    if kein:
        print("kein Neustart (--kein-neustart)")
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = restart_dienst(DIENST)
    if rc != 0:
        _rueckbau(plan, geschrieben, True, root)
        return rc
    if not pruefe_live(seit, vorher, root):
        print("STOP Pruefung fehlgeschlagen - Rueckbau (Sicherungen: *.bak-%s-%s)" % (KENNUNG, stempel))
        _rueckbau(plan, geschrieben, True, root)
        return 5
    print("ok, Dienst: %s (prepper-sdr nicht angefasst)" % DIENST)
    return 0


# ----------------------------------------------------------------- Selbsttest (isoliert, ohne den Dienst zu importieren)
SELFTEST_PROG = r'''
import sys, json, os, time, tempfile
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import acars_kachel as ak, acars_klar as kl
print(kl.selftest())
assert ak.selftest() is True
print(kl.install(ak)); print(kl.install(ak))
d = tempfile.mkdtemp(prefix="acarsklar-st-")
now = time.time()
msgs = [
 ({"timestamp": now-60, "label": "H1", "flight": "DLH123", "reg": ".D-AIBC", "text": "MASEK ,N 50.443,E 10.117,32000,0485,2009,150\\TS121853,281126"}, "acars"),
 ({"timestamp": now-50, "label": "H1", "flight": "DLH123", "text": "/.POS/TS122123,281126N49266E011005,,,,"}, "acars"),
 ({"timestamp": now-40, "label": "H1", "flight": "EWG77", "text": "RESREQ/AK,1158AF6"}, "acars"),
 ({"timestamp": now-30, "label": "_d", "flight": "EWG77", "text": ""}, "acars"),
 ({"timestamp": now-20, "label": "5U", "flight": "EWG78", "text": "WXRQ 0621/29 EDDF/EDDM"}, "acars"),
 ({"timestamp": now-10, "label": "H1", "flight": "XYZ1", "text": "MAYDAY MAYDAY", "serial": "90000002"}, "acars"),
 ({"vdl2": {"t": {"sec": int(now)-3, "usec": 0}, "freq": 136975000, "avlc": {"src": {"addr": "3C5EE1"}, "acars": {"reg": ".D-AIXX", "label": "B6", "flight": "LH400", "msg_text": "/FRARRXA.ADS.D-AIXX",
   "arinc622": {"msg_type": "adsc_msg", "crc_ok": True, "adsc": {"err": False, "tags": [{"basic_report": {"lat": 50.1, "lon": 9.0, "alt": 36000}}, {"earth_ref_data": {"gnd_spd_kts": 440, "true_trk_deg": 270, "vspd_ftmin": 0}}]}}}}}}, "vdl2"),
]
for m, q in msgs:
    ak.schreiben(d, m, q, now)
txt = open(os.path.join(d, "acars_msgs.jsonl")).read()
assert "90000002" not in txt and '"lc"' in txt
st = ak.status(d, adsb_idx={}, interessant_filter=False, now=now)
assert st["klartext"] is True and isinstance(st["punkte"], list) and len(st["punkte"]) >= 2, st["punkte"]
kl_ = [z["klar"] for g in st["fluege"] for z in g["zeilen"]]
assert any(k.startswith("Position 50.443N 10.117E · FL320 · 12:18:53 UTC") for k in kl_), kl_
assert any(k.startswith("Position 49.443N 11.008E · 12:21:23 UTC") for k in kl_), kl_
assert any(k.startswith("ADS-C · Position 50.100N 9.000E · FL360") for k in kl_), kl_
assert any("Wetteranfrage" in k for k in kl_) and any("quittiert Anfrage" in k for k in kl_) and any("Quittung der Bodenstation" in k for k in kl_), kl_
assert any(k.startswith("Notfallmeldung") for k in kl_), kl_
js = ak.KARTE
assert js.count('id="acarsBox"') == 1 and "Rohtext" in js and "L.slice(1)" in js
html = ak.seite("<html><body>x</body></html>")
assert html.count('id="acarsBox"') == 1 and ak.seite(html).count('id="acarsBox"') == 1
st2 = ak.status(d, adsb_idx={}, interessant_filter=True, now=now)
assert st2["lvl"] == "rot", st2["lvl"]
import shutil; shutil.rmtree(d, ignore_errors=True)
print("Datenfluss ok (7 Meldungen, Notfall bleibt rot, Rohtext einklappbar, keine Seriennummer)")
'''


def selftest_extra(basis):
    """acars_klar (eingebettet) + acars_kachel (gepatcht) in einem Temp-Ordner gegeneinander laufen lassen."""
    k_alt = lies(basis, "acars_kachel.py")
    ks = stand(k_alt)
    if ks == KACHEL_START:
        k_neu = patch_kachel(k_alt.decode("utf-8")).encode("utf-8")
        assert stand(k_neu) == KACHEL_ENDE, "acars_kachel Endhash %s" % stand(k_neu)[0][:16]
        assert patch_kachel(k_neu.decode("utf-8")).encode("utf-8") == k_neu, "acars_kachel nicht idempotent"
        print("selftest acars_kachel Haken ok %s" % KACHEL_ENDE[0][:16])
    elif ks == KACHEL_ENDE:
        k_neu = k_alt
    else:
        k_neu = None
        print("Hinweis: acars_kachel.py nicht die bekannte Basis - Datenfluss-Test uebersprungen")
    src = klar_quelle()
    assert stand(src) == KLAR_SHA, "acars_klar Hash"
    if k_neu is None:
        return
    tmp = tempfile.mkdtemp(prefix="acarsklar-selftest-")
    try:
        with open(os.path.join(tmp, "acars_kachel.py"), "wb") as fh:
            fh.write(k_neu)
        with open(os.path.join(tmp, "acars_klar.py"), "wb") as fh:
            fh.write(src)
        r = subprocess.run([sys.executable, "-B", "-c", SELFTEST_PROG, tmp], capture_output=True, text=True, timeout=120, cwd=tmp)
        for ln in (r.stdout or "").splitlines():
            print("selftest " + ln)
        if r.returncode != 0:
            raise AssertionError("Datenfluss-Test: " + (r.stderr or "")[-600:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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
        print("selftest Endhash ok %s" % DASH_ENDE[0][:16])
        for name in ("snMask aktiv:", "def _psh_cfg_sauber", "def _fs4_t4_after", "def _fs8_after", "acarsKachel aktiv:", "def _acars_api", "def _acars_after", "def _inet_split", "usbwache Anzeige:"):
            assert name in t, "Erhaltenes fehlt: %s" % name
        assert t.count("# ===== acarsKlar:") == 1 and t.count("# ===== /acarsKlar =====") == 1
        assert t.index("# ===== acarsKlar:") > t.index("# ===== /acarsKachel =====") and t.index("# ===== acarsKlar:") < t.index('if not any(getattr(f, "__name__", "") == "_sec_headers"')
        assert t.encode("utf-8") == raw or len(t.encode("utf-8")) - len(raw) == len(BLOCK.encode("utf-8")), "mehr als der Block geaendert"
        print("selftest Paket ok (nur der Block eingefuegt)")
        compile(t, "dashboard.py", "exec")
        print("selftest compile ok")
        selftest_extra(basis)
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
    except Exception as exc:
        print("STOP unerwarteter Fehler: %s: %s" % (type(exc).__name__, exc))
        return 9


if __name__ == "__main__":
    sys.exit(main())
