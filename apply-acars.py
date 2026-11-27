#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-acars: ACARS/VDL2 auf Stick 2, Kachel auf /adsb.

Stick 2 (Rolle hobby) bindet Decoder an die Seriennummer (wird nicht angezeigt).
RDS-Block unveraendert und vorrangig; 433/APRS-Hobby bleibt aus; 10C,
Kalibrierung und Meteor haben Vorrang. Decoder vor RDS beenden + Pause.
Watchdog gegen haengende Decoder. Eine Kachel auf /adsb nach Konzept,
nur lokal, 2 Tage, § 5 TTDSG.

Kein fullcheck. Neustart nur prepper-sdr und prepper-dashboard, Minute 05-39 Berlin.
flugfunk.py bleibt unveraendert.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import zlib
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

KENNUNG = "acars"
BASIS = "/home/fmg/prepper-dashboard"
DIENSTE = ("prepper-sdr", "prepper-dashboard")
KACHEL_NAME = "acars_kachel.py"

SDR_START_SHA = "df4f49b559c4b821cd0d1a248ea75af39e159a43a3151e4e1aa2fbcd0eaaaf83"
SDR_START_SHA16 = "df4f49b559c4b821"
SDR_START_BYTES = 796165
SDR_END_SHA = "86da726a0fae96630e2a132f8ac2e8221bb3bd8e483ddb6b9b00fe1ee8d19637"
SDR_END_SHA16 = "86da726a0fae9663"
SDR_END_BYTES = 803996

DASH_START_SHA = "96027ec7c2bfcd2f7544945e692e98fb0533592fefb7372006549b9581e71d51"
DASH_START_SHA16 = "96027ec7c2bfcd2f"
DASH_START_BYTES = 1395664
DASH_END_SHA = "6e7715e851337f65e8fd504171e5b50c6dbf814b9f76718ddbab550b3105f467"
DASH_END_SHA16 = "6e7715e851337f65"
DASH_END_BYTES = 1397320

KACHEL_SHA = "68f52f16a3949fd2b1f9086bb70b91626a1f33a968bf5edcce28a75d4fed91b3"
KACHEL_SHA16 = "68f52f16a3949fd2"
KACHEL_BYTES = 38999

FF_SHA16 = "bd67c57b98e452fb"
FF_BYTES = 99285

KACHEL_BLOB = (
    "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"
    "qI8RTMyg/ozXnxWI8PDuuf8Ht7F1QQ=="
)

SDR_PAARE = [('''    return "sdr-stabil ok"


if __name__ == "__main__":
''', '''    return "sdr-stabil ok"


# ===== acarsDatalink: Stick 2 ACARS/VDL2 in RDS-Luecken, nur lokal =====
ACARS_SLOT_S = 600
ACARS_PAUSE_S = 2.5
ACARS_WD_EXTRA_S = 30

F_RANGES["acars"] = (131.50, 131.75)
F_RANGES["vdl2"] = (136.95, 137.00)
DEFAULT_CFG.update({"acars_s": 600, "vdl2_s": 600, "acars_pause_s": 2.5})


def _acars_hobby(pl):
    try:
        a = _air_pl(pl)
        return a is not None and a.get("regrole") == "hobby"
    except Exception:
        return False


def _acars_exe(name):
    import shutil
    exe = "acarsdec" if name == "acarsdec" else "dumpvdl2"
    for cand in (shutil.which(exe), "/usr/local/bin/" + exe, "/usr/bin/" + exe):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def _acars_scrub(text, sn):
    t = "" if text is None else str(text)
    if sn and str(sn) and str(sn) in t:
        t = t.replace(str(sn), "***")
    return t


def _acars_prio(what):
    w = _s(what)
    return w.startswith(("rds:", "dab:", "cal:", "nz:")) or w in ("meteor",) or w.startswith("p:")


def _acars_ppm(cfg):
    try:
        if "stabil_ppm" in globals():
            return int(round(float(stabil_ppm(cfg))))
    except Exception:
        pass
    try:
        return int(ppm_val(cfg) or 0)
    except Exception:
        return 0


def _acars_argv(pl, kind):
    sn = cfg_serial(pl.cfg)
    if not serial_ok(sn):
        raise RuntimeError("Stick nicht aufgeloest")
    if kind == "acars":
        check_tune("acars", "131.525M")
        check_tune("acars", "131.725M")
        exe = _acars_exe("acarsdec")
        if not exe:
            raise RuntimeError("acarsdec fehlt")
        a = [exe, "--output", "json:file:path=-", "--rtlsdr", str(sn)]
        ppm = _acars_ppm(pl.cfg)
        if ppm:
            a += ["-p", str(ppm)]
        a += ["131.525", "131.725"]
        return a
    check_tune("vdl2", "136.975M")
    exe = _acars_exe("dumpvdl2")
    if not exe:
        raise RuntimeError("dumpvdl2 fehlt")
    a = [exe, "--rtlsdr", str(sn), "--output", "decoded:json:file:path=-", "--gain", "40"]
    ppm = _acars_ppm(pl.cfg)
    if ppm:
        a += ["--correction", str(ppm)]
    a += ["136.975M"]
    return a


def _acars_err(pl, stream, sn):
    try:
        for raw in iter(stream.readline, b""):
            line = _acars_scrub(raw.decode("utf-8", "replace").strip(), sn)
            if line:
                pl.stderr = (pl.stderr + [line[-200:]])[-8:]
    except Exception:
        pass


def _acars_reader(pl, stream, kind):
    try:
        import sys as _sys
        base = getattr(pl, "base", None) or (BASE if "BASE" in globals() else "/home/fmg/prepper-dashboard")
        if base and base not in _sys.path:
            _sys.path.insert(0, base)
        import acars_kachel as ak
    except Exception:
        ak = None
    sn = None
    try:
        sn = cfg_serial(pl.cfg)
    except Exception:
        sn = None
    try:
        for raw in iter(stream.readline, b""):
            pl.raw_t = time.time()
            try:
                rec = raw.decode("utf-8", "replace").strip()
                if not rec or rec[0] not in "{[":
                    continue
                obj = json.loads(rec)
                if ak is not None:
                    ak.schreiben(pl.base, obj, quelle=kind, sn=sn)
            except Exception:
                pass
    except Exception:
        pass


_acars_orig_want = Planner.want
_acars_orig_start = Planner.start
_acars_orig_cmd = Planner.cmd
_acars_orig_wd = Planner.stick_watchdog


def _acars_want(self, mode, now):
    w = _acars_orig_want(self, mode, now)
    try:
        if not _acars_hobby(self):
            return w
        if w and w not in ("idle", "aprs", "433"):
            return w
        if not (_acars_exe("acarsdec") or _acars_exe("dumpvdl2")):
            return "idle"
        slot_a = float(self.cfg.get("acars_s") or ACARS_SLOT_S)
        slot_v = float(self.cfg.get("vdl2_s") or ACARS_SLOT_S)
        act = _s(self.active)
        if act == "acars" and self.procs and self.alive() and now - float(self.since or now) < slot_a:
            return "acars"
        if act == "vdl2" and self.procs and self.alive() and now - float(self.since or now) < slot_v:
            return "vdl2"
        last = self.__dict__.get("_acars_kind") or "vdl2"
        if last != "acars" and _acars_exe("acarsdec"):
            return "acars"
        if _acars_exe("dumpvdl2"):
            return "vdl2"
        if _acars_exe("acarsdec"):
            return "acars"
        return "idle"
    except Exception as ex:
        print("acars want:", ex, flush=True)
        return w if w not in ("aprs", "433") else "idle"


def _acars_cmd(self, what):
    if what in ("acars", "vdl2"):
        return [_acars_argv(self, what)]
    return _acars_orig_cmd(self, what)


def _acars_start(self, what):
    try:
        prev = _s(getattr(self, "active", None))
        if _acars_prio(what) and prev in ("acars", "vdl2"):
            if self.procs:
                self.kill()
            extra = float(self.cfg.get("acars_pause_s") or ACARS_PAUSE_S)
            time.sleep(max(0.0, extra - 1.0))
        if what in ("acars", "vdl2"):
            self.resolve()
            argv = _acars_argv(self, what)
            if not argv or not argv[0]:
                raise RuntimeError("Start %s: Programm fehlt" % what)
            sn = cfg_serial(self.cfg)
            self.stderr = []
            pr = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
            self.procs = [pr]
            threading.Thread(target=_acars_err, args=(self, pr.stderr, sn), daemon=True).start()
            threading.Thread(target=_acars_reader, args=(self, pr.stdout, what), daemon=True).start()
            self.active, self.since = what, time.time()
            self.__dict__["_acars_kind"] = what
            self.log("Start", what, _acars_scrub(" ".join(argv), sn))
            return
    except Exception as ex:
        print("acars start:", type(ex).__name__, flush=True)
        if what in ("acars", "vdl2"):
            try:
                self.kill()
            except Exception:
                pass
            self.active = "idle"
            return
    return _acars_orig_start(self, what)


def _acars_wd(self, now):
    try:
        if _s(self.active) in ("acars", "vdl2"):
            if not self.active or not self.procs or not self.alive():
                return
            key = "acars_s" if self.active == "acars" else "vdl2_s"
            slot = float(self.cfg.get(key) or ACARS_SLOT_S)
            if now - float(self.since or now) > slot + ACARS_WD_EXTRA_S:
                self.log("Watchdog: %s haengt seit %d s, beende Decoder" % (self.active, int(now - self.since)))
                self.kill()
                self.active = "idle"
                time.sleep(1.5)
            return
    except Exception as ex:
        print("acars watchdog:", ex, flush=True)
    return _acars_orig_wd(self, now)


Planner.want = _acars_want
Planner.cmd = _acars_cmd
Planner.start = _acars_start
Planner.stick_watchdog = _acars_wd


def selftest_acars_sdr():
    assert tune_ok("acars", "131.525M") and tune_ok("acars", "131.725M")
    assert tune_ok("vdl2", "136.975M")
    assert not tune_ok("acars", "136.975M")
    assert not tune_ok("vdl2", "131.525M")
    assert _acars_scrub("dumpvdl2 --rtlsdr 90000002 --gain 40", "90000002") == "dumpvdl2 --rtlsdr *** --gain 40"
    assert "90000002" not in _acars_scrub("serial 90000002", "90000002")
    return True


try:
    selftest_acars_sdr()
    print("acarsDatalink aktiv: Stick 2 ACARS/VDL2 in RDS-Luecken, nur lokal", flush=True)
except Exception as _acars_e:
    print("acarsDatalink FEHLER:", _acars_e, flush=True)
# ===== /acarsDatalink =====


if __name__ == "__main__":
''', 1)]
DASH_PAARE = [('''# ===== /funkAmpel =====


if not any(getattr(f, "__name__", "") == "_sec_headers" for f in app.after_request_funcs.get(None, [])):
''', '''# ===== /funkAmpel =====
# ===== acarsKachel: Datalink-Kachel auf /adsb, nur lokal =====
try:
    import acars_kachel as _ak

    def _acars_api():
        from flask import jsonify, request as _ac_rq
        base = globals().get("_SDR_BASE") or "/home/fmg/prepper-dashboard"
        interess = _ac_rq.args.get("interessant", "1") != "0"
        return jsonify(_ak.status(base, adsb_idx=_ak.lade_adsb(), interessant_filter=interess))

    def _acars_after(resp):
        try:
            from flask import request as _ac_rq
            if _ac_rq.path != "/adsb" or resp.status_code != 200 or getattr(resp, "direct_passthrough", False):
                return resp
            if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
                return resp
            body = resp.get_data(as_text=True)
            neu = _ak.seite(body)
            if neu != body:
                resp.set_data(neu)
        except Exception as e:
            print("acarsKachel after:", type(e).__name__, flush=True)
        return resp

    _ak.selftest()
    if "app" in globals() and not any(getattr(r, "rule", "") == "/api/acars" for r in app.url_map.iter_rules()):
        app.add_url_rule("/api/acars", endpoint="acars_status", view_func=_acars_api, methods=["GET"])
    if "app" in globals():
        funcs = app.after_request_funcs.setdefault(None, [])
        funcs[:] = [f for f in funcs if getattr(f, "__name__", "") != "_acars_after"]
        funcs.insert(0, _acars_after)
    print("acarsKachel aktiv: /adsb Datalink-Kachel, nur lokal", flush=True)
except Exception as _ak_e:
    print("acarsKachel FEHLER:", _ak_e, flush=True)
# ===== /acarsKachel =====


if not any(getattr(f, "__name__", "") == "_sec_headers" for f in app.after_request_funcs.get(None, [])):
''', 1)]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def kachel_bytes():
    return zlib.decompress(base64.b64decode(KACHEL_BLOB.encode("ascii")))


def im_fenster(minute):
    return 5 <= int(minute) <= 39


def berlin_jetzt():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin"))
    return datetime.now()


def berlin_minute():
    return berlin_jetzt().minute


def ersetze(text, alt, neu, name, n=1):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


def stub_aus(paare):
    return "".join(alt for alt, _neu, _n in paare)


def patch_sdr(text):
    for alt, neu, n in SDR_PAARE:
        text = ersetze(text, alt, neu, "prepper_sdr.py", n)
    return text


def patch_dash(text):
    for alt, neu, n in DASH_PAARE:
        text = ersetze(text, alt, neu, "dashboard.py", n)
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


def schon_sdr(text):
    return (
        "def _acars_want(" in text
        and "Planner.stick_watchdog = _acars_wd" in text
        and 'F_RANGES["acars"]' in text
        and "acarsDatalink" in text
    )


def schon_dash(text):
    return (
        "def _acars_after(" in text
        and "acarsKachel" in text
        and "/api/acars" in text
    )


def stand(data):
    return sha256(data), len(data)


def berechne_sdr(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == SDR_END_SHA and n == SDR_END_BYTES:
        return alt, None, None
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_sdr(roh):
        return alt, None, None
    if hashcheck and (ist != SDR_START_SHA or n != SDR_START_BYTES):
        return None, None, "STOP %s ist %s/%s soll %s/%s" % (
            pfad, ist[:16], n, SDR_START_SHA16, SDR_START_BYTES)
    try:
        text = patch_sdr(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    neu = text.encode("utf-8")
    if hashcheck:
        compile(neu, "prepper_sdr.py", "exec")
    got, gn = stand(neu)
    if hashcheck and (got != SDR_END_SHA or gn != SDR_END_BYTES):
        return None, None, "STOP Endstand %s/%s erwartet %s/%s" % (
            got[:16], gn, SDR_END_SHA16, SDR_END_BYTES)
    return alt, neu, None


def berechne_dash(pfad, hashcheck=True):
    if not os.path.isfile(pfad):
        return None, None, "STOP %s fehlt" % pfad
    alt = open(pfad, "rb").read()
    ist, n = stand(alt)
    print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
    if ist == DASH_END_SHA and n == DASH_END_BYTES:
        return alt, None, None
    try:
        roh = alt.decode("utf-8")
    except UnicodeDecodeError:
        return None, None, "STOP %s nicht UTF-8" % pfad
    if schon_dash(roh):
        return alt, None, None
    hash_ok = (ist == DASH_START_SHA and n == DASH_START_BYTES)
    if hashcheck and not hash_ok:
        print("Hinweis: dashboard.py Hash %s/%s abweichend, Patch nur per Anker" % (
            ist[:16], n))
    try:
        text = patch_dash(roh)
    except SystemExit as exc:
        return None, None, str(exc)
    neu = text.encode("utf-8")
    if hashcheck:
        compile(neu, "dashboard.py", "exec")
    got, gn = stand(neu)
    if hash_ok and hashcheck and (got != DASH_END_SHA or gn != DASH_END_BYTES):
        return None, None, "STOP dashboard Endstand %s/%s erwartet %s/%s" % (
            got[:16], gn, DASH_END_SHA16, DASH_END_BYTES)
    if not schon_dash(neu.decode("utf-8")):
        return None, None, "STOP dashboard.py Patch unvollstaendig"
    return alt, neu, None


def berechne_kachel(pfad, hashcheck=True):
    soll = kachel_bytes()
    if hashcheck and (sha256(soll) != KACHEL_SHA or len(soll) != KACHEL_BYTES):
        return None, None, "STOP eingebettetes acars_kachel.py weicht vom Soll-Hash ab"
    compile(soll, KACHEL_NAME, "exec")
    if os.path.isfile(pfad):
        alt = open(pfad, "rb").read()
        ist, n = stand(alt)
        print("%s sha16 %s bytes %d" % (os.path.basename(pfad), ist[:16], n))
        if ist == KACHEL_SHA and n == KACHEL_BYTES:
            return alt, None, None
        return alt, soll, None
    print("%s fehlt, wird neu geschrieben" % os.path.basename(pfad))
    return None, soll, None


def journal_pruefen(seit, pause=90):
    print("warte %d s auf Journal/Live" % pause)
    time.sleep(pause)
    ok = True
    try:
        out = subprocess.run(
            ["journalctl", "-u", "prepper-sdr", "--since", seit, "--no-pager", "-o", "short-iso"],
            capture_output=True, text=True, timeout=20)
        zeilen = (out.stdout or "").splitlines() if out.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("Hinweis: Journal nicht gelesen (%s)" % type(exc).__name__)
        zeilen = []
    starts = [ln for ln in zeilen if "Start " in ln or "acarsdec" in ln or "dumpvdl2" in ln]
    if any("cpulimit" in ln and "welle-cli" in ln for ln in zeilen):
        print("STOP nach Neustart welle-cli unter cpulimit")
        ok = False
    if any("Start acars" in ln or "Start vdl2" in ln or "acarsDatalink aktiv" in ln for ln in zeilen):
        print("Journal: Datalink-Planer sichtbar")
        for ln in [x for x in starts if "acars" in x.lower() or "vdl2" in x.lower()][:6]:
            print(ln)
    elif zeilen:
        print("Hinweis: noch kein ACARS/VDL2-Start (Stick 2 evtl. nicht angesteckt oder RDS-Block laeuft) – kein STOP")
    else:
        print("Hinweis: Journal leer oder unlesbar")
    url = "http://127.0.0.1:5000/api/acars"
    try:
        r = subprocess.run(
            ["curl", "-fsS", "-m", "5", "-o", "/tmp/apply-acars-api.json",
             "-w", "%{http_code}", url],
            capture_output=True, text=True, timeout=8)
        code = (r.stdout or "").strip()
        print("GET /api/acars -> %s rc %s" % (code, r.returncode))
        if r.returncode != 0 or not code.startswith("200"):
            print("STOP /api/acars nicht ok")
            ok = False
        else:
            raw = open("/tmp/apply-acars-api.json", encoding="utf-8", errors="replace").read()
            if "rtlsdr" in raw.lower() or '"serial"' in raw:
                print("STOP API enthaelt Geräte-Seriennummer oder rtlsdr")
                ok = False
            elif "Kopf" in raw or "kopf" in raw:
                print("Ampel/Kachel-API erreichbar")
            try:
                d = json.loads(raw)
                if not d.get("lokal") or "TTDSG" not in str(d.get("hinweis") or ""):
                    print("Hinweis: API ohne erwarteten Lokal-Hinweis")
            except Exception:
                print("Hinweis: API kein JSON")
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("Hinweis: /api/acars nicht geprueft (%s)" % type(exc).__name__)
    try:
        r = subprocess.run(
            ["curl", "-fsS", "-m", "5", "-o", "/tmp/apply-acars-adsb.html",
             "-w", "%{http_code}", "http://127.0.0.1:5000/adsb"],
            capture_output=True, text=True, timeout=8)
        code = (r.stdout or "").strip()
        print("GET /adsb -> %s rc %s" % (code, r.returncode))
        if r.returncode == 0 and code.startswith("200"):
            html = open("/tmp/apply-acars-adsb.html", encoding="utf-8", errors="replace").read()
            if 'id="acarsBox"' not in html:
                print("STOP /adsb ohne Datalink-Kachel")
                ok = False
            else:
                print("Kachel acarsBox auf /adsb vorhanden")
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("Hinweis: /adsb nicht geprueft (%s)" % type(exc).__name__)
    return ok


def neustart():
    rc_all = 0
    for dienst in DIENSTE:
        rc = subprocess.call(["systemctl", "restart", dienst])
        if rc != 0:
            rc = subprocess.call(["sudo", "systemctl", "restart", dienst])
        print("restart %s rc %s" % (dienst, rc))
        if rc != 0:
            rc_all = rc
    return rc_all


def anwenden(root, dry, kein, minute, hashcheck=True, pause=90):
    sdr = os.path.join(root, "prepper_sdr.py")
    dash = os.path.join(root, "dashboard.py")
    kach = os.path.join(root, KACHEL_NAME)
    ff = os.path.join(root, "flugfunk.py")
    if os.path.isfile(ff):
        raw = open(ff, "rb").read()
        print("flugfunk.py sha16 %s bytes %d (unverändert)" % (sha256(raw)[:16], len(raw)))
        if hashcheck and (sha256(raw)[:16] != FF_SHA16 or len(raw) != FF_BYTES):
            print("Hinweis: flugfunk.py Hash weicht ab, Datei wird nicht geaendert")
    salt, sneu, sfehl = berechne_sdr(sdr, hashcheck)
    if sfehl:
        print(sfehl)
        return 2
    dalt, dneu, dfehl = berechne_dash(dash, hashcheck)
    if dfehl:
        print(dfehl)
        return 2
    kalt, kneu, kfehl = berechne_kachel(kach, hashcheck)
    if kfehl:
        print(kfehl)
        return 2
    if sneu is None and dneu is None and kneu is None:
        print("bereits installiert, keine Aenderung, kein Neustart")
        print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(salt)[:16], len(salt)))
        print("dashboard.py endstand sha16 %s bytes %d" % (sha256(dalt)[:16], len(dalt)))
        print("acars_kachel.py endstand sha16 %s bytes %d" % (sha256(kalt)[:16], len(kalt)))
        return 0
    if sneu is not None:
        print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha256(sneu)[:16], len(sneu)))
    if dneu is not None:
        print("dashboard.py endstand sha16 %s bytes %d" % (sha256(dneu)[:16], len(dneu)))
    if kneu is not None:
        print("acars_kachel.py endstand sha16 %s bytes %d" % (sha256(kneu)[:16], len(kneu)))
    if dry:
        print("dry-run: nichts geschrieben")
        return 0
    if not kein and not im_fenster(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    stempel = berlin_jetzt().strftime("%Y%m%dT%H%M%S")
    try:
        if sneu is not None:
            print("Sicherung %s" % sichern(sdr, stempel))
            schreibe(sdr, sneu)
        if dneu is not None:
            print("Sicherung %s" % sichern(dash, stempel))
            schreibe(dash, dneu)
        if kneu is not None:
            if kalt is not None:
                print("Sicherung %s" % sichern(kach, stempel))
            schreibe(kach, kneu)
            if kalt is None and os.path.exists(sdr):
                try:
                    shutil.copymode(sdr, kach)
                except OSError:
                    pass
    except OSError as exc:
        print("STOP beim Schreiben (%s)" % type(exc).__name__)
        return 3
    if sneu is not None:
        data = open(sdr, "rb").read()
        print("prepper_sdr.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
        if hashcheck and sha256(data) != SDR_END_SHA:
            print("STOP geschriebene Datei weicht vom Soll-Hash ab")
            return 3
    if dneu is not None:
        data = open(dash, "rb").read()
        print("dashboard.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
    if kneu is not None or os.path.isfile(kach):
        data = open(kach, "rb").read()
        print("acars_kachel.py endstand sha256 %s bytes %d" % (sha256(data), len(data)))
        if hashcheck and sha256(data) != KACHEL_SHA:
            print("STOP acars_kachel.py weicht vom Soll-Hash ab")
            return 3
    if kein:
        print("kein Neustart. Aktiv nach: sudo systemctl restart %s" % " ".join(DIENSTE))
        return 0
    seit = berlin_jetzt().strftime("%Y-%m-%d %H:%M:%S")
    rc = neustart()
    if rc != 0:
        print("Neustart fehlgeschlagen. Dateien sind neu. Von Hand: sudo systemctl restart %s" % " ".join(DIENSTE))
        return 4
    if not journal_pruefen(seit, pause):
        return 4
    return 0


def _finde_start_oder_end(starts):
    seen = []
    for pfad in list(starts):
        if not pfad or pfad in seen or not os.path.isfile(pfad):
            continue
        seen.append(pfad)
        data = open(pfad, "rb").read()
        yield pfad, data, sha256(data), len(data)


def _queue_selftest():
    ns = {
        "time": time, "os": os, "json": json, "threading": __import__("threading"),
        "subprocess": __import__("subprocess"),
        "F_RANGES": {"ism433": (433.05, 434.79)},
        "DEFAULT_CFG": {},
        "BASE": "/tmp",
        "_s": lambda x: "" if x is None else str(x),
        "_air_pl": lambda self: getattr(self, "air", None),
        "cfg_serial": lambda c: (c or {}).get("serial"),
        "serial_ok": lambda s: bool(s) and str(s).isdigit(),
        "check_tune": lambda *a, **k: None,
        "tune_ok": lambda kind, f=None, ch=None: True,
        "stabil_ppm": lambda c: 0.69,
        "ppm_val": lambda c: 0,
        "print": print,
    }

    class Planner(object):
        def want(self, mode, now):
            return self._orig_w

        def start(self, what):
            return "orig-start"

        def cmd(self, what):
            return [("orig",)]

        def stick_watchdog(self, now):
            return "orig-wd"

    ns["Planner"] = Planner
    src = '''    return "sdr-stabil ok"


# ===== acarsDatalink: Stick 2 ACARS/VDL2 in RDS-Luecken, nur lokal =====
ACARS_SLOT_S = 600
ACARS_PAUSE_S = 2.5
ACARS_WD_EXTRA_S = 30

F_RANGES["acars"] = (131.50, 131.75)
F_RANGES["vdl2"] = (136.95, 137.00)
DEFAULT_CFG.update({"acars_s": 600, "vdl2_s": 600, "acars_pause_s": 2.5})


def _acars_hobby(pl):
    try:
        a = _air_pl(pl)
        return a is not None and a.get("regrole") == "hobby"
    except Exception:
        return False


def _acars_exe(name):
    import shutil
    exe = "acarsdec" if name == "acarsdec" else "dumpvdl2"
    for cand in (shutil.which(exe), "/usr/local/bin/" + exe, "/usr/bin/" + exe):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def _acars_scrub(text, sn):
    t = "" if text is None else str(text)
    if sn and str(sn) and str(sn) in t:
        t = t.replace(str(sn), "***")
    return t


def _acars_prio(what):
    w = _s(what)
    return w.startswith(("rds:", "dab:", "cal:", "nz:")) or w in ("meteor",) or w.startswith("p:")


def _acars_ppm(cfg):
    try:
        if "stabil_ppm" in globals():
            return int(round(float(stabil_ppm(cfg))))
    except Exception:
        pass
    try:
        return int(ppm_val(cfg) or 0)
    except Exception:
        return 0


def _acars_argv(pl, kind):
    sn = cfg_serial(pl.cfg)
    if not serial_ok(sn):
        raise RuntimeError("Stick nicht aufgeloest")
    if kind == "acars":
        check_tune("acars", "131.525M")
        check_tune("acars", "131.725M")
        exe = _acars_exe("acarsdec")
        if not exe:
            raise RuntimeError("acarsdec fehlt")
        a = [exe, "--output", "json:file:path=-", "--rtlsdr", str(sn)]
        ppm = _acars_ppm(pl.cfg)
        if ppm:
            a += ["-p", str(ppm)]
        a += ["131.525", "131.725"]
        return a
    check_tune("vdl2", "136.975M")
    exe = _acars_exe("dumpvdl2")
    if not exe:
        raise RuntimeError("dumpvdl2 fehlt")
    a = [exe, "--rtlsdr", str(sn), "--output", "decoded:json:file:path=-", "--gain", "40"]
    ppm = _acars_ppm(pl.cfg)
    if ppm:
        a += ["--correction", str(ppm)]
    a += ["136.975M"]
    return a


def _acars_err(pl, stream, sn):
    try:
        for raw in iter(stream.readline, b""):
            line = _acars_scrub(raw.decode("utf-8", "replace").strip(), sn)
            if line:
                pl.stderr = (pl.stderr + [line[-200:]])[-8:]
    except Exception:
        pass


def _acars_reader(pl, stream, kind):
    try:
        import sys as _sys
        base = getattr(pl, "base", None) or (BASE if "BASE" in globals() else "/home/fmg/prepper-dashboard")
        if base and base not in _sys.path:
            _sys.path.insert(0, base)
        import acars_kachel as ak
    except Exception:
        ak = None
    sn = None
    try:
        sn = cfg_serial(pl.cfg)
    except Exception:
        sn = None
    try:
        for raw in iter(stream.readline, b""):
            pl.raw_t = time.time()
            try:
                rec = raw.decode("utf-8", "replace").strip()
                if not rec or rec[0] not in "{[":
                    continue
                obj = json.loads(rec)
                if ak is not None:
                    ak.schreiben(pl.base, obj, quelle=kind, sn=sn)
            except Exception:
                pass
    except Exception:
        pass


_acars_orig_want = Planner.want
_acars_orig_start = Planner.start
_acars_orig_cmd = Planner.cmd
_acars_orig_wd = Planner.stick_watchdog


def _acars_want(self, mode, now):
    w = _acars_orig_want(self, mode, now)
    try:
        if not _acars_hobby(self):
            return w
        if w and w not in ("idle", "aprs", "433"):
            return w
        if not (_acars_exe("acarsdec") or _acars_exe("dumpvdl2")):
            return "idle"
        slot_a = float(self.cfg.get("acars_s") or ACARS_SLOT_S)
        slot_v = float(self.cfg.get("vdl2_s") or ACARS_SLOT_S)
        act = _s(self.active)
        if act == "acars" and self.procs and self.alive() and now - float(self.since or now) < slot_a:
            return "acars"
        if act == "vdl2" and self.procs and self.alive() and now - float(self.since or now) < slot_v:
            return "vdl2"
        last = self.__dict__.get("_acars_kind") or "vdl2"
        if last != "acars" and _acars_exe("acarsdec"):
            return "acars"
        if _acars_exe("dumpvdl2"):
            return "vdl2"
        if _acars_exe("acarsdec"):
            return "acars"
        return "idle"
    except Exception as ex:
        print("acars want:", ex, flush=True)
        return w if w not in ("aprs", "433") else "idle"


def _acars_cmd(self, what):
    if what in ("acars", "vdl2"):
        return [_acars_argv(self, what)]
    return _acars_orig_cmd(self, what)


def _acars_start(self, what):
    try:
        prev = _s(getattr(self, "active", None))
        if _acars_prio(what) and prev in ("acars", "vdl2"):
            if self.procs:
                self.kill()
            extra = float(self.cfg.get("acars_pause_s") or ACARS_PAUSE_S)
            time.sleep(max(0.0, extra - 1.0))
        if what in ("acars", "vdl2"):
            self.resolve()
            argv = _acars_argv(self, what)
            if not argv or not argv[0]:
                raise RuntimeError("Start %s: Programm fehlt" % what)
            sn = cfg_serial(self.cfg)
            self.stderr = []
            pr = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
            self.procs = [pr]
            threading.Thread(target=_acars_err, args=(self, pr.stderr, sn), daemon=True).start()
            threading.Thread(target=_acars_reader, args=(self, pr.stdout, what), daemon=True).start()
            self.active, self.since = what, time.time()
            self.__dict__["_acars_kind"] = what
            self.log("Start", what, _acars_scrub(" ".join(argv), sn))
            return
    except Exception as ex:
        print("acars start:", type(ex).__name__, flush=True)
        if what in ("acars", "vdl2"):
            try:
                self.kill()
            except Exception:
                pass
            self.active = "idle"
            return
    return _acars_orig_start(self, what)


def _acars_wd(self, now):
    try:
        if _s(self.active) in ("acars", "vdl2"):
            if not self.active or not self.procs or not self.alive():
                return
            key = "acars_s" if self.active == "acars" else "vdl2_s"
            slot = float(self.cfg.get(key) or ACARS_SLOT_S)
            if now - float(self.since or now) > slot + ACARS_WD_EXTRA_S:
                self.log("Watchdog: %s haengt seit %d s, beende Decoder" % (self.active, int(now - self.since)))
                self.kill()
                self.active = "idle"
                time.sleep(1.5)
            return
    except Exception as ex:
        print("acars watchdog:", ex, flush=True)
    return _acars_orig_wd(self, now)


Planner.want = _acars_want
Planner.cmd = _acars_cmd
Planner.start = _acars_start
Planner.stick_watchdog = _acars_wd


def selftest_acars_sdr():
    assert tune_ok("acars", "131.525M") and tune_ok("acars", "131.725M")
    assert tune_ok("vdl2", "136.975M")
    assert not tune_ok("acars", "136.975M")
    assert not tune_ok("vdl2", "131.525M")
    assert _acars_scrub("dumpvdl2 --rtlsdr 90000002 --gain 40", "90000002") == "dumpvdl2 --rtlsdr *** --gain 40"
    assert "90000002" not in _acars_scrub("serial 90000002", "90000002")
    return True


try:
    selftest_acars_sdr()
    print("acarsDatalink aktiv: Stick 2 ACARS/VDL2 in RDS-Luecken, nur lokal", flush=True)
except Exception as _acars_e:
    print("acarsDatalink FEHLER:", _acars_e, flush=True)
# ===== /acarsDatalink =====


if __name__ == "__main__":
'''
    a = src.index("ACARS_SLOT_S = 600")
    b = src.index("def selftest_acars_sdr")
    exec(compile(src[a:b], "acars_sdr.py", "exec"), ns)
    ns["_acars_exe"] = lambda n: "/usr/local/bin/" + n
    want = ns["_acars_want"]
    scrub = ns["_acars_scrub"]
    prio = ns["_acars_prio"]
    now = time.time()

    class P(Planner):
        def __init__(self, role="hobby", w="idle"):
            self.air = {"regrole": role, "role": "hobby" if role == "hobby" else role}
            self.cfg = {"acars_s": 600, "vdl2_s": 600, "serial": "90000002", "acars_pause_s": 2.5}
            self.active = "idle"
            self.since = now
            self.procs = []
            self.base = "/tmp"
            self._orig_w = w
            self.stderr = []

        def alive(self):
            return bool(self.procs)

        def log(self, *a):
            pass

        def kill(self):
            self.procs = []

        def resolve(self):
            pass

    p = P("hobby", "idle")
    r = want(p, {"mode": "auto"}, now)
    if r != "acars":
        raise SystemExit("selftest queue idle->acars %s" % r)
    p = P("hobby", "rds:0")
    if want(p, {"mode": "auto"}, now) != "rds:0":
        raise SystemExit("selftest queue rds vorrang")
    p = P("hobby", "dab:0")
    if want(p, {"mode": "auto"}, now) != "dab:0":
        raise SystemExit("selftest queue 10c vorrang")
    p = P("hobby", "meteor")
    if want(p, {"mode": "auto"}, now) != "meteor":
        raise SystemExit("selftest queue meteor vorrang")
    p = P("hobby", "cal:0")
    if want(p, {"mode": "auto"}, now) != "cal:0":
        raise SystemExit("selftest queue cal vorrang")
    p = P("hobby", "aprs")
    if want(p, {"mode": "auto"}, now) != "acars":
        raise SystemExit("selftest queue kein aprs %s" % want(p, {"mode": "auto"}, now))
    p = P("5C", "idle")
    if want(p, {"mode": "auto"}, now) != "idle":
        raise SystemExit("selftest queue nicht hobby")
    p = P("hobby", "idle")
    p.active, p.since, p.procs = "acars", now - 100, [object()]
    p.__dict__["_acars_kind"] = "acars"
    if want(p, {"mode": "auto"}, now) != "acars":
        raise SystemExit("selftest queue slot haelt")
    p.since = now - 700
    if want(p, {"mode": "auto"}, now) != "vdl2":
        raise SystemExit("selftest queue wechsel vdl2 %s" % want(p, {"mode": "auto"}, now))
    if not prio("rds:0") or prio("acars"):
        raise SystemExit("selftest prio")
    if "***" not in scrub(" --rtlsdr 90000002 ", "90000002") or "90000002" in scrub(" --rtlsdr 90000002 ", "90000002"):
        raise SystemExit("selftest scrub")
    # Watchdog: unter Slot kein Kill, darueber ja
    p = P("hobby", "idle")
    p.active, p.since, p.procs = "acars", now - 100, [object()]
    ns["_acars_wd"](p, now)
    if not p.procs:
        raise SystemExit("selftest wd zu früh")
    p.since = now - 700
    ns["_acars_wd"](p, now)
    if p.procs or p.active != "idle":
        raise SystemExit("selftest wd haenger")


def selftest():
    _queue_selftest()
    # Modul-Selbsttest
    import sys
    tmpk = tempfile.mkdtemp(prefix="acars-mod-")
    try:
        ziel = os.path.join(tmpk, KACHEL_NAME)
        open(ziel, "wb").write(kachel_bytes())
        if sha256(open(ziel, "rb").read()) != KACHEL_SHA:
            raise SystemExit("selftest kachel blob hash")
        sys.path.insert(0, tmpk)
        import acars_kachel as ak
        ak.selftest()
        sys.path.remove(tmpk)
        sys.modules.pop("acars_kachel", None)
    finally:
        shutil.rmtree(tmpk, ignore_errors=True)

    with tempfile.TemporaryDirectory(prefix="acars-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        sdr = os.path.join(root, "prepper_sdr.py")
        dash = os.path.join(root, "dashboard.py")
        open(sdr, "w", encoding="utf-8").write("# stub\n" + stub_aus(SDR_PAARE))
        open(dash, "w", encoding="utf-8").write("# stub\n" + stub_aus(DASH_PAARE))
        os.chmod(sdr, 0o640)
        os.chmod(dash, 0o640)
        vorher_s = open(sdr, "rb").read()
        vorher_d = open(dash, "rb").read()
        if anwenden(root, False, False, 4, hashcheck=False, pause=0) != 2:
            raise SystemExit("selftest fenster")
        if open(sdr, "rb").read() != vorher_s or open(dash, "rb").read() != vorher_d:
            raise SystemExit("selftest fenster geschrieben")
        if anwenden(root, True, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest dry")
        if open(sdr, "rb").read() != vorher_s:
            raise SystemExit("selftest dry geschrieben")
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest lauf")
        st = open(sdr, encoding="utf-8").read()
        dt = open(dash, encoding="utf-8").read()
        if not schon_sdr(st):
            raise SystemExit("selftest sdr fehl")
        if not schon_dash(dt):
            raise SystemExit("selftest dash fehl")
        if not os.path.isfile(os.path.join(root, KACHEL_NAME)):
            raise SystemExit("selftest kachel fehlt")
        if (os.stat(sdr).st_mode & 0o777) != 0o640:
            raise SystemExit("selftest modus")
        bak = [p for p in os.listdir(root) if "bak-%s-" % KENNUNG in p]
        if len(bak) < 2:
            raise SystemExit("selftest backup %s" % bak)
        if anwenden(root, False, True, 12, hashcheck=False, pause=0) != 0:
            raise SystemExit("selftest idempotent")

    sdr_src = dash_src = None
    sdr_h = dash_h = None
    for pfad, data, h, n in _finde_start_oder_end([
        os.environ.get("ACARS_SDR"),
        "/tmp/prepper_sdr_funkampel.py",
        os.path.join(BASIS, "prepper_sdr.py"),
    ]):
        if h == SDR_START_SHA and n == SDR_START_BYTES:
            sdr_src, sdr_h = data, h
            break
        if h == SDR_END_SHA and n == SDR_END_BYTES and sdr_src is None:
            sdr_src, sdr_h = data, h
    for pfad, data, h, n in _finde_start_oder_end([
        os.environ.get("ACARS_DASH"),
        "/tmp/dashboard_funkampel.py",
        "/workspace/zi0/app2/dashboard.py",
        os.path.join(BASIS, "dashboard.py"),
    ]):
        if h == DASH_START_SHA and n == DASH_START_BYTES:
            dash_src, dash_h = data, h
            break
        if h == DASH_END_SHA and n == DASH_END_BYTES and dash_src is None:
            dash_src, dash_h = data, h
    if not sdr_src:
        raise SystemExit("selftest echte SDR-Basis fehlt (ACARS_SDR oder df4f49b559c4b821)")
    if not dash_src:
        raise SystemExit("selftest echtes dashboard fehlt (ACARS_DASH oder 96027ec7c2bfcd2f)")
    with tempfile.TemporaryDirectory(prefix="acars-real-") as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        zs, zd = os.path.join(root, "prepper_sdr.py"), os.path.join(root, "dashboard.py")
        open(zs, "wb").write(sdr_src)
        open(zd, "wb").write(dash_src)
        os.chmod(zs, 0o644)
        os.chmod(zd, 0o644)
        already = (sdr_h == SDR_END_SHA and dash_h == DASH_END_SHA)
        if already:
            open(os.path.join(root, KACHEL_NAME), "wb").write(kachel_bytes())
            if anwenden(root, False, False, 4, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real bereits")
        else:
            if anwenden(root, True, True, 12, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real dry")
            if open(zs, "rb").read() != sdr_src or open(zd, "rb").read() != dash_src:
                raise SystemExit("selftest real dry geschrieben")
            if anwenden(root, False, True, 12, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real lauf")
            if anwenden(root, False, False, 4, hashcheck=True, pause=0) != 0:
                raise SystemExit("selftest real bereits/fenster")
        nsdr, ndash, nk = open(zs, "rb").read(), open(zd, "rb").read(), open(os.path.join(root, KACHEL_NAME), "rb").read()
        if sha256(nsdr) != SDR_END_SHA or len(nsdr) != SDR_END_BYTES:
            raise SystemExit("selftest real sdr hash %s/%s" % (sha256(nsdr)[:16], len(nsdr)))
        if sha256(ndash) != DASH_END_SHA or len(ndash) != DASH_END_BYTES:
            raise SystemExit("selftest real dash hash %s/%s" % (sha256(ndash)[:16], len(ndash)))
        if sha256(nk) != KACHEL_SHA or len(nk) != KACHEL_BYTES:
            raise SystemExit("selftest real kachel hash %s/%s" % (sha256(nk)[:16], len(nk)))
        compile(nsdr, "prepper_sdr.py", "exec")
        compile(ndash, "dashboard.py", "exec")
        compile(nk, KACHEL_NAME, "exec")
        if "def _acars_want" not in nsdr.decode("utf-8") or "welle-cli ungedrosselt" not in nsdr.decode("utf-8"):
            raise SystemExit("selftest dabfix/acars fehlen")
        if "def _ampel_krise" not in ndash.decode("utf-8"):
            raise SystemExit("selftest ampel fehlt")
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
