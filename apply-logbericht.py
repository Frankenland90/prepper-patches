#!/usr/bin/env python3
# Diagnosebericht. Kein Mesh. prepper-sdr bleibt.
from __future__ import annotations
import base64, hashlib, json, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
FULL = Path("/home/fmg/fullcheck.sh")
FEST = {
    "dashboard.py": ("3351c6fd29c51746", 1387903),
    "flugfunk.py": ("b52d0c0d54161f84", 78261),
    "pushover_push.py": ("3916f7d880b13569", 12237),
    "prepper_sdr.py": ("9519012e7a1142ba", 779574),
    "fullcheck.sh": ("28e47229c0d05d7c", 95388),
}


def load():
    return json.loads(PAYLOAD_TEXT)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fenster(now=None):
    from zoneinfo import ZoneInfo
    jetzt = now or datetime.now(ZoneInfo("Europe/Berlin"))
    return 5 <= jetzt.minute <= 39, "Berlin Minute %02d" % jetzt.minute


def verwandle(data, old, neu):
    if data.count(neu) >= 1 and data.count(old) == 0:
        return data
    if data.count(old) != 1 or old in neu:
        raise RuntimeError("Stelle")
    vor = data
    data = data.replace(old, neu, 1)
    if data.replace(neu, b"", 1) != vor.replace(old, b"", 1):
        raise RuntimeError("ausserhalb")
    return data


def fullcheck_neu(text, dash_sha, dash_n):
    if 'FC_VERSION="2.3"' in text and "logbericht.db" in text and dash_sha in text:
        return text
    if text.count('FC_VERSION="2.2"') != 1:
        raise RuntimeError("version")
    neu = text.replace('FC_VERSION="2.2"', 'FC_VERSION="2.3"', 1)
    alt = 'DASH_SHA16="${FC_DASH_SHA16:-3351c6fd29c51746}"'
    if alt not in neu:
        raise RuntimeError("dashsha")
    neu = neu.replace(
        alt,
        'DASH_SHA16="${FC_DASH_SHA16:-%s}"\nDASH_BYTES="${FC_DASH_BYTES:-%d}"' % (dash_sha, dash_n),
        1,
    )
    mark = 'if [[ "$DSH" == "$DASH_SHA16" ]]; then'
    if neu.count(mark) != 1:
        raise RuntimeError("dashif")
    neu = neu.replace(
        mark,
        'DBYTES="$(wc -c < "$DASHF")"; if [[ "$DSH" == "$DASH_SHA16" && "$DBYTES" == "$DASH_BYTES" ]]; then',
        1,
    )
    if "logbericht.db" not in neu:
        anker = 'else warn "pushover_push.py sha16"'
        if anker not in neu:
            anker = 'else warn "dashboard.py sha16"'
        if anker not in neu:
            raise RuntimeError("anker")
        block = (
            '  if [[ -r "$APP/prepper_log.py" ]]; then ok "prepper_log.py" "Modul vorhanden"; else fail "prepper_log.py" "fehlt" "apply-logbericht."; fi\n'
            '  if [[ -f "$APP/logbericht.db" ]]; then ok "logbericht.db" "Logging angelegt"; else warn "logbericht.db" "noch nicht angelegt" "erster Sammelzyklus."; fi\n'
            "  " + anker
        )
        neu = neu.replace(anker, block, 1)
    if "3916f7d880b13569" not in neu:
        import re as _re
        neu, _n = _re.subn(r"2267a556[0-9a-f]{8}", "3916f7d880b13569", neu)
        if _n < 1:
            raise RuntimeError("push")
    if "Basis logbericht" not in neu and "# fullcheck.sh" in neu:
        neu = neu.replace("# fullcheck.sh", "# fullcheck.sh Basis logbericht", 1)
    return neu


def sichern(path, data, ende):
    path = Path(path)
    stempel = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S")
    alt = sorted(path.parent.glob(path.name + ".bak-" + ende + "-*"))
    bak = path.with_name(path.name + ".bak-" + ende + "-" + stempel)
    shutil.copy2(path, bak)
    if bak.read_bytes() != data:
        bak.unlink()
        raise RuntimeError("Sicherung")
    for alt_pfad in alt[:-2]:
        try:
            alt_pfad.unlink()
        except OSError:
            pass


def schreiben(path, data, ende):
    path = Path(path)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    tmp = path.with_name("." + path.name + ".tmp-" + ende)
    if tmp.exists():
        raise RuntimeError("temporaer")
    try:
        with open(tmp, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


def apply_dir(ordner, dry, kein, jetzt=None, hashcheck=True):
    print("===== SCHRITT PAKETE, dieses Skript installiert nichts =====")
    print("===== ENDE SCHRITT PAKETE =====")
    ordner = Path(ordner)
    blobs = {}
    for name, (kopf, laenge) in FEST.items():
        pfad = FULL if name == "fullcheck.sh" else ordner / name
        if pfad.is_symlink() or not pfad.is_file():
            if not hashcheck and name != "dashboard.py":
                continue
            print("STOP: %s fehlt" % pfad)
            return 2
        data = pfad.read_bytes()
        blobs[name] = (pfad, data)
        print("%s sha16 %s bytes %d" % (name, sha(data)[:16], len(data)))
        if hashcheck and (not sha(data).startswith(kopf) or len(data) != laenge):
            print("STOP: %s ist nicht der Stand nach apply-flugfunk-5" % name)
            print("Live-Hash sha256 %s" % sha(data))
            return 2
    roh = load()
    old = base64.b64decode(roh["dash"]["old"])
    neu = base64.b64decode(roh["dash"]["new"])
    log_neu = base64.b64decode(roh["prepper_log"])
    try:
        dash = verwandle(blobs["dashboard.py"][1], old, neu)
        compile(log_neu, "prepper_log.py", "exec")
        if hashcheck:
            compile(dash, "dashboard.py", "exec")
        if "fullcheck.sh" in blobs:
            fc_pfad, fc_alt = blobs["fullcheck.sh"]
        else:
            fc_pfad, fc_alt = ordner / "fullcheck.sh", (ordner / "fullcheck.sh").read_bytes()
        fc = fullcheck_neu(fc_alt.decode("utf-8"), sha(dash)[:16], len(dash))
    except (RuntimeError, UnicodeError, KeyError):
        print("STOP: Stelle unbekannt. Nichts geschrieben.")
        return 2
    print("dashboard.py endstand sha16 %s bytes %d" % (sha(dash)[:16], len(dash)))
    print("prepper_log.py sha16 %s bytes %d" % (sha(log_neu)[:16], len(log_neu)))
    print("fullcheck.sh endstand sha16 %s bytes %d" % (sha(fc.encode())[:16], len(fc.encode())))
    log_pfad = ordner / "prepper_log.py"
    gleich = blobs["dashboard.py"][1] == dash and log_pfad.is_file() and log_pfad.read_bytes() == log_neu and fc_alt.decode("utf-8") == fc
    if gleich:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    frei, meldung = fenster(jetzt)
    print(meldung)
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        print("Live-Stand geprueft.")
        return 0
    if not frei:
        print("STOP: Neustart nur Minute 05-39 Berlin. Nichts geschrieben.")
        return 2
    try:
        sichern(blobs["dashboard.py"][0], blobs["dashboard.py"][1], "logbericht")
        schreiben(blobs["dashboard.py"][0], dash, "logbericht")
        if log_pfad.is_file():
            sichern(log_pfad, log_pfad.read_bytes(), "logbericht")
        schreiben(log_pfad, log_neu, "log")
        sichern(fc_pfad, fc_alt, "fullcheck")
        schreiben(fc_pfad, fc.encode("utf-8"), "fullcheck")
    except (OSError, RuntimeError):
        print("STOP beim Schreiben")
        return 3
    print("geschrieben. prepper-sdr bleibt laufen.")
    if kein or ordner != DASH:
        print("Kein Neustart in dieser Pruefung.")
        return 0
    frei, meldung = fenster()
    print(meldung)
    if not frei:
        print("STOP: Dateien sind neu, der Neustart bleibt aus.")
        return 2
    __import__("subprocess").run(["systemctl", "restart", "prepper-dashboard.service"], check=False)
    print("Nur prepper-dashboard neu gestartet.")
    return 0


def selftest():
    assert fenster(datetime(2026, 11, 21, 12, 5))[0]
    assert not fenster(datetime(2026, 11, 21, 12, 4))[0]
    neu = fullcheck_neu(FIX, "aabbccddeeff0011", 42)
    assert 'FC_VERSION="2.3"' in neu
    assert "aabbccddeeff0011" in neu and "DASH_BYTES" in neu and "logbericht.db" in neu
    assert "3916f7d880b13569" in neu
    import tempfile
    ordner = Path(tempfile.mkdtemp(prefix="logbericht-"))
    roh = load()
    alt = base64.b64decode(roh["dash"]["old"])
    (ordner / "dashboard.py").write_bytes(b"KOPF\n" + alt + b"\nFUSS\n")
    (ordner / "fullcheck.sh").write_text(FIX)
    assert apply_dir(ordner, False, True, datetime(2026, 11, 21, 12, 4), False) == 2
    assert (ordner / "fullcheck.sh").read_text() == FIX
    assert apply_dir(ordner, True, True, datetime(2026, 11, 21, 12, 12), False) == 0
    assert not (ordner / "prepper_log.py").exists()
    assert apply_dir(ordner, False, True, datetime(2026, 11, 21, 12, 12), False) == 0
    assert b"logbericht aktiv" in (ordner / "dashboard.py").read_bytes()
    assert 'FC_VERSION="2.3"' in (ordner / "fullcheck.sh").read_text()
    ns = {"__name__": "prepper_log"}
    exec(compile((ordner / "prepper_log.py").read_bytes(), "prepper_log.py", "exec"), ns)
    assert ns["selftest"]() == "logbericht ok"
    print("selftest ok")
    return 0


FIX = """#!/bin/bash
# fullcheck.sh
FC_VERSION="2.2"
DASH_SHA16="${FC_DASH_SHA16:-3351c6fd29c51746}"
if [[ "$DSH" == "$DASH_SHA16" ]]; then ok "dashboard.py sha16" "x"
else warn "pushover_push.py sha16" "3916f7d880b13569, Soll 3916f7d880b13569"
"""


def main(argv):
    args = argv[1:]
    dry = kein = False
    wurzel = DASH
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--dry-run":
            dry = True
        elif a == "--kein-neustart":
            kein = True
        elif a == "--selftest":
            return selftest()
        elif a == "--wurzel":
            i += 1
            wurzel = Path(args[i])
        else:
            print("STOP: unbekanntes Argument")
            return 2
        i += 1
    return apply_dir(wurzel, dry, kein)


PAYLOAD_TEXT = '''{"dash": {"old": "ICAgIHByaW50KCJmbHVnZnVuayBGRUhMRVI6ICVzIC0gRnVua3NlaXRlIHdpZSBiaXNoZXIiICUgX2ZmdW5rX2UsIGZsdXNoPVRydWUpCiMgPT09PT0gL2ZsdWdmdW5rID09PT09CgojID09PT09IHB1c2hvdmVyS2FjaGVsOiBLYWNoZWwgUFVTSE9WRVIgYXVmIC9waS4gU3RhbmRhcmQgYXVzLiBTY2hsdWVzc2VsIG51ciBpbiBwdXNob3Zlci5jZmcgNjAwLiBLZWluIE1lc2guID09PT09CmltcG9ydCBvcyBhcyBfcHNoX29zCmltcG9ydCB0aHJlYWRpbmcgYXMgX3BzaF90aAo=", "new": "ICAgIHByaW50KCJmbHVnZnVuayBGRUhMRVI6ICVzIC0gRnVua3NlaXRlIHdpZSBiaXNoZXIiICUgX2ZmdW5rX2UsIGZsdXNoPVRydWUpCiMgPT09PT0gL2ZsdWdmdW5rID09PT09CgojID09PT09IGxvZ2JlcmljaHQ6IERpYWdub3NlIGF1ZiAvc3lzdGVtLiBOdXIgTEFOLCBrZWluIE1lc2guID09PT09CmRlZiBfbG9nX2FwaSgpOgogICAgZnJvbSBmbGFzayBpbXBvcnQgcmVxdWVzdAogICAgaW1wb3J0IHByZXBwZXJfbG9nIGFzIF9wbAogICAgcmV0dXJuIF9wbC5hcGlfcmVzcG9uc2UoX1NEUl9CQVNFLCByZXF1ZXN0LmFyZ3MuZ2V0KCJ6ZWl0cmF1bSIpIG9yICI2aCIsIHJlcXVlc3QucmVtb3RlX2FkZHIpCgoKZGVmIF9sb2dfYmVmb3JlKCk6CiAgICB0cnk6CiAgICAgICAgZnJvbSBmbGFzayBpbXBvcnQgZwogICAgICAgIGcuX2xvZ190ID0gX19pbXBvcnRfXygidGltZSIpLnRpbWUoKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCgoKZGVmIF9sb2dfYWZ0ZXIocmVzcCk6CiAgICB0cnk6CiAgICAgICAgZnJvbSBmbGFzayBpbXBvcnQgZywgcmVxdWVzdAogICAgICAgIGltcG9ydCBwcmVwcGVyX2xvZyBhcyBfcGwKICAgICAgICBhbmZhbmcgPSBnZXRhdHRyKGcsICJfbG9nX3QiLCBOb25lKQogICAgICAgIGlmIGFuZmFuZyBhbmQgcmVxdWVzdC5wYXRoOgogICAgICAgICAgICBib2R5ID0gIiIKICAgICAgICAgICAgaWYgcmVzcC5zdGF0dXNfY29kZSA+PSA1MDAgb3IgKHJlcXVlc3QucGF0aC5zdGFydHN3aXRoKCIvYXBpIikgYW5kIHJlc3Auc3RhdHVzX2NvZGUgPT0gMjAwKToKICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgICAgICBib2R5ID0gcmVzcC5nZXRfZGF0YShhc190ZXh0PVRydWUpWzo0MDAwXQogICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgICAgICBib2R5ID0gIiIKICAgICAgICAgICAgX3BsLm5hY2hfYW50d29ydChyZXNwLCBfU0RSX0JBU0UsIHJlcXVlc3QucGF0aCwgcmVzcC5zdGF0dXNfY29kZSwgYW5mYW5nLCBib2R5KQogICAgICAgIGlmIHJlc3Auc3RhdHVzX2NvZGUgPT0gMjAwIGFuZCAocmVzcC5taW1ldHlwZSBvciAiIikgPT0gInRleHQvaHRtbCIgYW5kIG5vdCByZXNwLmRpcmVjdF9wYXNzdGhyb3VnaDoKICAgICAgICAgICAgbmV1ID0gX3BsLmluX3NlaXRlKHJlc3AuZ2V0X2RhdGEoYXNfdGV4dD1UcnVlKSwgcmVxdWVzdC5wYXRoKQogICAgICAgICAgICBpZiBuZXUgIT0gcmVzcC5nZXRfZGF0YShhc190ZXh0PVRydWUpOgogICAgICAgICAgICAgICAgcmVzcC5zZXRfZGF0YShuZXUpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzoKICAgICAgICBwcmludCgibG9nYmVyaWNodDoiLCB0eXBlKGV4YykuX19uYW1lX18sIGZsdXNoPVRydWUpCiAgICByZXR1cm4gcmVzcAoKCnRyeToKICAgIGltcG9ydCBwcmVwcGVyX2xvZyBhcyBfcGwKICAgIGFzc2VydCAiRGlhZ25vc2ViZXJpY2h0IiBpbiBfcGwuS0FSVEUgYW5kICJsb2diZXJpY2h0Qm94IiBpbiBfcGwuaW5fc2VpdGUoIjxodG1sPjxib2R5PjwvYm9keT48L2h0bWw+IiwgIi9waSIpCiAgICBpZiAiYXBwIiBpbiBnbG9iYWxzKCkgYW5kIG5vdCBhbnkoZ2V0YXR0cihyLCAicnVsZSIsICIiKSA9PSAiL2FwaS9sb2diZXJpY2h0IiBmb3IgciBpbiBhcHAudXJsX21hcC5pdGVyX3J1bGVzKCkpOgogICAgICAgIGFwcC5hZGRfdXJsX3J1bGUoIi9hcGkvbG9nYmVyaWNodCIsIGVuZHBvaW50PSJsb2diZXJpY2h0X2FwaSIsIHZpZXdfZnVuYz1fbG9nX2FwaSwgbWV0aG9kcz1bIkdFVCJdKQogICAgICAgIGFwcC5iZWZvcmVfcmVxdWVzdChfbG9nX2JlZm9yZSkKICAgICAgICBhcHAuYWZ0ZXJfcmVxdWVzdChfbG9nX2FmdGVyKQogICAgICAgIGlmIF9faW1wb3J0X18oIm9zIikuZW52aXJvbi5nZXQoIkxPR0JFUklDSFRfTk9fVEhSRUFEIikgIT0gIjEiOgogICAgICAgICAgICBfcGwuc3RhcnRlbihfU0RSX0JBU0UpCiAgICBwcmludCgibG9nYmVyaWNodCBha3RpdiIsIGZsdXNoPVRydWUpCmV4Y2VwdCBFeGNlcHRpb24gYXMgX2xvZ19lOgogICAgcHJpbnQoImxvZ2JlcmljaHQgRkVITEVSOiAlcyIgJSB0eXBlKF9sb2dfZSkuX19uYW1lX18sIGZsdXNoPVRydWUpCgojID09PT09IHB1c2hvdmVyS2FjaGVsOiBLYWNoZWwgUFVTSE9WRVIgYXVmIC9waS4gU3RhbmRhcmQgYXVzLiBTY2hsdWVzc2VsIG51ciBpbiBwdXNob3Zlci5jZmcgNjAwLiBLZWluIE1lc2guID09PT09CmltcG9ydCBvcyBhcyBfcHNoX29zCmltcG9ydCB0aHJlYWRpbmcgYXMgX3BzaF90aAo="}, "prepper_log": "IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoiIiJEaWFnbm9zZS1Mb2cuIE51ciBsZXNlbiwga2VpbmUgU3RpY2tzLCBrZWluIE1lc2gsIGtlaW5lIFNjaGx1ZXNzZWwuIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgcmUKaW1wb3J0IHNodXRpbAppbXBvcnQgc3FsaXRlMwppbXBvcnQgc3VicHJvY2VzcwppbXBvcnQgdGhyZWFkaW5nCmltcG9ydCB0aW1lCmZyb20gZGF0ZXRpbWUgaW1wb3J0IGRhdGV0aW1lCmZyb20gem9uZWluZm8gaW1wb3J0IFpvbmVJbmZvCgpEQl9OQU1FID0gImxvZ2JlcmljaHQuZGIiCktFRVBfUyA9IDMwICogODY0MDAKTUFYX0JZVEVTID0gOCAqIDEwMjQgKiAxMDI0ClRJQ0tfUyA9IDYwCkJFUkxJTiA9IFpvbmVJbmZvKCJFdXJvcGUvQmVybGluIikKX0lQID0gcmUuY29tcGlsZShyIlxiKD86XGR7MSwzfVwuKXszfVxkezEsM31cYiIpCl9TTiA9IHJlLmNvbXBpbGUociJcYig/PVswLTlBLUZhLWZdKltBLUZhLWZdKVswLTlBLUZhLWZdezgsfVxiIikKX0dFSEVJTSA9IHJlLmNvbXBpbGUociIoP2kpKHRva2VufHBhc3N3b3J0fHBhc3N3b3JkfHNlY3JldHxhcGlbXy1dP2tleSlccypbOj1dXHMqXFMrIikKCgpkZWYgYmVybGluKHRzKToKICAgIHJldHVybiBkYXRldGltZS5mcm9tdGltZXN0YW1wKGZsb2F0KHRzKSwgQkVSTElOKS5zdHJmdGltZSgiJVktJW0tJWQgJUg6JU06JVMiKQoKCmRlZiBrdWVyemVuKHRleHQsIG49MTgwKToKICAgIHJldHVybiAiICIuam9pbihzdHIodGV4dCBvciAiIikuc3BsaXQoKSlbOm5dCgoKZGVmIHNjaHdhZXJ6ZW4odGV4dCk6CiAgICB0ZXh0ID0gX0dFSEVJTS5zdWIociJcMT08ZW50ZmVybnQ+Iiwgc3RyKHRleHQgb3IgIiIpKQogICAgdGV4dCA9IF9JUC5zdWIoIjxpcD4iLCB0ZXh0KQogICAgdGV4dCA9IF9TTi5zdWIoIjxzbj4iLCB0ZXh0KQogICAgcmV0dXJuIGt1ZXJ6ZW4odGV4dCwgMjQwKQoKCmRlZiB0cmFjZWJhY2tfa3Vyeih0ZXh0KToKICAgIHplaWxlbiA9IFt6IGZvciB6IGluIHN0cih0ZXh0IG9yICIiKS5zcGxpdGxpbmVzKCkgaWYgei5zdHJpcCgpXQogICAgaWYgbm90IHplaWxlbjoKICAgICAgICByZXR1cm4gIiIKICAgIGlmIGxlbih6ZWlsZW4pID09IDE6CiAgICAgICAgcmV0dXJuIHNjaHdhZXJ6ZW4oemVpbGVuWzBdKQogICAgcmV0dXJuIHNjaHdhZXJ6ZW4oemVpbGVuWzBdICsgIiDigKYgIiArIHplaWxlblstMV0pCgoKZGVmIGNvbm5lY3QocGF0aCk6CiAgICBuZXUgPSBub3Qgb3MucGF0aC5leGlzdHMocGF0aCkKICAgIGNvbiA9IHNxbGl0ZTMuY29ubmVjdChwYXRoLCB0aW1lb3V0PTUpCiAgICBtb2RlID0gY29uLmV4ZWN1dGUoIlBSQUdNQSBqb3VybmFsX21vZGU9V0FMIikuZmV0Y2hvbmUoKQogICAgaWYgbW9kZSBpcyBOb25lIG9yIHN0cihtb2RlWzBdKS5sb3dlcigpICE9ICJ3YWwiOgogICAgICAgIGNvbi5jbG9zZSgpCiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCJ3YWwiKQogICAgY29uLmV4ZWN1dGUoIlBSQUdNQSBidXN5X3RpbWVvdXQ9NTAwMCIpCiAgICBjb24uZXhlY3V0ZSgiUFJBR01BIHN5bmNocm9ub3VzPU5PUk1BTCIpCiAgICBjb24uZXhlY3V0ZSgKICAgICAgICAiQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgZXJlaWduaXMgKCIKICAgICAgICAiaWQgSU5URUdFUiBQUklNQVJZIEtFWSwgdCBJTlRFR0VSIE5PVCBOVUxMLCBxdWVsbGUgVEVYVCwgYXJ0IFRFWFQsIGRhdWVyX21zIElOVEVHRVIsIHRleHQgVEVYVCwga29udGV4dCBURVhUKSIKICAgICkKICAgIGNvbi5leGVjdXRlKCJDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyBtZXJrIChrIFRFWFQgUFJJTUFSWSBLRVksIHYgVEVYVCwgdCBJTlRFR0VSKSIpCiAgICBjb24uY29tbWl0KCkKICAgIHRyeToKICAgICAgICBvcy5jaG1vZChwYXRoLCAwbzYwMCkKICAgICAgICBmb3IgZW5kdW5nIGluICgiLXdhbCIsICItc2htIik6CiAgICAgICAgICAgIG5lYmVuID0gcGF0aCArIGVuZHVuZwogICAgICAgICAgICBpZiBvcy5wYXRoLmV4aXN0cyhuZWJlbik6CiAgICAgICAgICAgICAgICBvcy5jaG1vZChuZWJlbiwgMG82MDApCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICBwYXNzCiAgICBpZiBuZXU6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIGNvbgoKCmRlZiBfbWVyayhjb24sIGtleSk6CiAgICByb3cgPSBjb24uZXhlY3V0ZSgiU0VMRUNUIHYsIHQgRlJPTSBtZXJrIFdIRVJFIGs9PyIsIChrZXksKSkuZmV0Y2hvbmUoKQogICAgcmV0dXJuIE5vbmUgaWYgcm93IGlzIE5vbmUgZWxzZSAocm93WzBdLCBpbnQocm93WzFdIG9yIDApKQoKCmRlZiBfc2V0emVuKGNvbiwga2V5LCB3ZXJ0LCBub3cpOgogICAgY29uLmV4ZWN1dGUoCiAgICAgICAgIklOU0VSVCBJTlRPIG1lcmsoaywgdiwgdCkgVkFMVUVTICg/LD8sPykgT04gQ09ORkxJQ1QoaykgRE8gVVBEQVRFIFNFVCB2PWV4Y2x1ZGVkLnYsIHQ9ZXhjbHVkZWQudCIsCiAgICAgICAgKGtleSwgd2VydCwgaW50KG5vdykpLAogICAgKQoKCmRlZiBhdWZyYWV1bWVuKGNvbiwgcGF0aCwgbm93KToKICAgIGNvbi5leGVjdXRlKCJERUxFVEUgRlJPTSBlcmVpZ25pcyBXSEVSRSB0IDwgPyIsIChpbnQobm93KSAtIEtFRVBfUywpKQogICAgY29uLmNvbW1pdCgpCiAgICB0cnk6CiAgICAgICAgZ3JvZXNzZSA9IG9zLnBhdGguZ2V0c2l6ZShwYXRoKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcmV0dXJuCiAgICBpZiBncm9lc3NlIDw9IE1BWF9CWVRFUzoKICAgICAgICByZXR1cm4KICAgIGdyZW56ZSA9IGNvbi5leGVjdXRlKCJTRUxFQ1QgdCBGUk9NIGVyZWlnbmlzIE9SREVSIEJZIHQgREVTQyBMSU1JVCAxIE9GRlNFVCA0MDAiKS5mZXRjaG9uZSgpCiAgICBpZiBncmVuemU6CiAgICAgICAgY29uLmV4ZWN1dGUoIkRFTEVURSBGUk9NIGVyZWlnbmlzIFdIRVJFIHQgPCA/IiwgKGdyZW56ZVswXSwpKQogICAgICAgIGNvbi5jb21taXQoKQoKCmRlZiBrb250ZXh0KCk6CiAgICB0ZWlsZSA9IFtdCiAgICB0cnk6CiAgICAgICAgdGVpbGUuYXBwZW5kKCJMb2FkICIgKyAiICIuam9pbihvcGVuKCIvcHJvYy9sb2FkYXZnIiwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpLnNwbGl0KClbOjNdKSkKICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgIHBhc3MKICAgIHRyeToKICAgICAgICBtZW0gPSB7fQogICAgICAgIGZvciBsaW5lIGluIG9wZW4oIi9wcm9jL21lbWluZm8iLCBlbmNvZGluZz0idXRmLTgiKToKICAgICAgICAgICAgaWYgbGluZS5zdGFydHN3aXRoKCgiTWVtQXZhaWxhYmxlOiIsICJNZW1Ub3RhbDoiKSk6CiAgICAgICAgICAgICAgICBtZW1bbGluZS5zcGxpdCgiOiIsIDEpWzBdXSA9IGxpbmUuc3BsaXQoKVsxXQogICAgICAgIGlmIG1lbToKICAgICAgICAgICAgdGVpbGUuYXBwZW5kKCJSQU0gJXMvJXMga0IiICUgKG1lbS5nZXQoIk1lbUF2YWlsYWJsZSIsICI/IiksIG1lbS5nZXQoIk1lbVRvdGFsIiwgIj8iKSkpCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICBwYXNzCiAgICB0cnk6CiAgICAgICAgcm9oID0gb3BlbigiL3N5cy9jbGFzcy90aGVybWFsL3RoZXJtYWxfem9uZTAvdGVtcCIsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKS5zdHJpcCgpCiAgICAgICAgdGVpbGUuYXBwZW5kKCJDUFUgJXMgQyIgJSAoaW50KHJvaCkgLyAxMDAwLjApKQogICAgZXhjZXB0IChPU0Vycm9yLCBWYWx1ZUVycm9yKToKICAgICAgICBwYXNzCiAgICBpZiBzaHV0aWwud2hpY2goInZjZ2VuY21kIik6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBvdXQgPSBzdWJwcm9jZXNzLnJ1bihbInZjZ2VuY21kIiwgImdldF90aHJvdHRsZWQiXSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PTIpCiAgICAgICAgICAgIHRlaWxlLmFwcGVuZChzY2h3YWVyemVuKG91dC5zdGRvdXQgb3IgInRocm90dGxlZCA/IikpCiAgICAgICAgZXhjZXB0IChPU0Vycm9yLCBzdWJwcm9jZXNzLlRpbWVvdXRFeHBpcmVkKToKICAgICAgICAgICAgcGFzcwogICAgaWYgc2h1dGlsLndoaWNoKCJwcyIpOgogICAgICAgIHRyeToKICAgICAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5ydW4oWyJwcyIsICItZW8iLCAiY29tbSxwY3B1IiwgIi0tc29ydD0tcGNwdSJdLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9MikKICAgICAgICAgICAgemVpbGVuID0gW3ouc3RyaXAoKSBmb3IgeiBpbiAob3V0LnN0ZG91dCBvciAiIikuc3BsaXRsaW5lcygpWzE6NF0gaWYgei5zdHJpcCgpXQogICAgICAgICAgICBpZiB6ZWlsZW46CiAgICAgICAgICAgICAgICB0ZWlsZS5hcHBlbmQoIlByb3plc3NlICIgKyAiOyAiLmpvaW4oemVpbGVuKSkKICAgICAgICBleGNlcHQgKE9TRXJyb3IsIHN1YnByb2Nlc3MuVGltZW91dEV4cGlyZWQpOgogICAgICAgICAgICBwYXNzCiAgICByZXR1cm4gc2Nod2FlcnplbigiIHwgIi5qb2luKHRlaWxlKSkKCgpkZWYgbm90aWVyZShiYXNlLCBxdWVsbGUsIGFydCwgdGV4dCwgZGF1ZXJfbXM9Tm9uZSwgbm93PU5vbmUsIGltbWVyPUZhbHNlKToKICAgIG5vdyA9IHRpbWUudGltZSgpIGlmIG5vdyBpcyBOb25lIGVsc2UgZmxvYXQobm93KQogICAgdGV4dCA9IHNjaHdhZXJ6ZW4odGV4dCkKICAgIGlmIG5vdCB0ZXh0OgogICAgICAgIHJldHVybiBGYWxzZQogICAgcGF0aCA9IG9zLnBhdGguam9pbihiYXNlLCBEQl9OQU1FKQogICAgb3MubWFrZWRpcnMoYmFzZSwgZXhpc3Rfb2s9VHJ1ZSkKICAgIGNvbiA9IGNvbm5lY3QocGF0aCkKICAgIHRyeToKICAgICAgICBrZXkgPSBxdWVsbGUgKyAifCIgKyBhcnQKICAgICAgICBhbHQgPSBfbWVyayhjb24sIGtleSkKICAgICAgICBpZiBub3QgaW1tZXIgYW5kIGFsdCBhbmQgYWx0WzBdID09IHRleHQgYW5kIG5vdyAtIGFsdFsxXSA8IDYwMDoKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgY29uLmV4ZWN1dGUoCiAgICAgICAgICAgICJJTlNFUlQgSU5UTyBlcmVpZ25pcyh0LCBxdWVsbGUsIGFydCwgZGF1ZXJfbXMsIHRleHQsIGtvbnRleHQpIFZBTFVFUyAoPyw/LD8sPyw/LD8pIiwKICAgICAgICAgICAgKGludChub3cpLCBrdWVyemVuKHF1ZWxsZSwgODApLCBrdWVyemVuKGFydCwgNDApLCBkYXVlcl9tcywgdGV4dCwga29udGV4dCgpKSwKICAgICAgICApCiAgICAgICAgX3NldHplbihjb24sIGtleSwgdGV4dCwgbm93KQogICAgICAgIGNvbi5jb21taXQoKQogICAgICAgIGF1ZnJhZXVtZW4oY29uLCBwYXRoLCBub3cpCiAgICAgICAgcmV0dXJuIFRydWUKICAgIGZpbmFsbHk6CiAgICAgICAgY29uLmNsb3NlKCkKCgpkZWYgX2pzb25fbGVzZW4ocGF0aCk6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKHBhdGgsIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGhhbmRsZToKICAgICAgICAgICAgZGF0YSA9IGpzb24ubG9hZChoYW5kbGUpCiAgICBleGNlcHQgKE9TRXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAgIHJldHVybiBOb25lCiAgICByZXR1cm4gZGF0YSBpZiBpc2luc3RhbmNlKGRhdGEsIGRpY3QpIGVsc2UgTm9uZQoKCmRlZiBfZmx1Z2Z1bmtfc3R1bmRlKGJhc2UsIG5vdyk6CiAgICBwZmFkID0gb3MucGF0aC5qb2luKGJhc2UsICJmbHVnZnVuay5kYiIpCiAgICBpZiBub3Qgb3MucGF0aC5pc2ZpbGUocGZhZCk6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIHRyeToKICAgICAgICBjb24gPSBzcWxpdGUzLmNvbm5lY3QocGZhZCwgdGltZW91dD0yKQogICAgICAgIHJvdyA9IGNvbi5leGVjdXRlKAogICAgICAgICAgICAiU0VMRUNUIENPVU5UKCopLCBBVkcoa29uZmlkZW56KSBGUk9NIHNwcnVjaCBXSEVSRSB0ID49ID8iLAogICAgICAgICAgICAoaW50KG5vdykgLSAzNjAwLCksCiAgICAgICAgKS5mZXRjaG9uZSgpCiAgICAgICAgY29uLmNsb3NlKCkKICAgIGV4Y2VwdCBzcWxpdGUzLkVycm9yOgogICAgICAgIHJldHVybiBOb25lCiAgICByZXR1cm4gaW50KHJvd1swXSBvciAwKSwgcm93WzFdCgoKZGVmIF9rZXJuZWwobm93KToKICAgIGlmIG5vdCBzaHV0aWwud2hpY2goImpvdXJuYWxjdGwiKToKICAgICAgICByZXR1cm4gW10KICAgIHRyeToKICAgICAgICBvdXQgPSBzdWJwcm9jZXNzLnJ1bigKICAgICAgICAgICAgWyJqb3VybmFsY3RsIiwgIi1rIiwgIi0tc2luY2UiLCAiMyBtaW4gYWdvIiwgIi1uIiwgIjMwIiwgIi0tbm8tcGFnZXIiLCAiLW8iLCAiY2F0Il0sCiAgICAgICAgICAgIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwgdGltZW91dD0zLAogICAgICAgICkKICAgIGV4Y2VwdCAoT1NFcnJvciwgc3VicHJvY2Vzcy5UaW1lb3V0RXhwaXJlZCk6CiAgICAgICAgcmV0dXJuIFtdCiAgICBmdW5kZSA9IFtdCiAgICBmb3IgemVpbGUgaW4gKG91dC5zdGRvdXQgb3IgIiIpLnNwbGl0bGluZXMoKToKICAgICAgICBuaWVkcmlnID0gemVpbGUubG93ZXIoKQogICAgICAgIGlmICJlcnJvciAtNzEiIGluIG5pZWRyaWcgb3IgImRpc2Nvbm5lY3QiIGluIG5pZWRyaWcgb3IgInVzYiIgaW4gbmllZHJpZyBhbmQgImVycm9yIiBpbiBuaWVkcmlnOgogICAgICAgICAgICBmdW5kZS5hcHBlbmQoc2Nod2Flcnplbih6ZWlsZSkpCiAgICByZXR1cm4gZnVuZGVbOjVdCgoKZGVmIHNhbW1lbG4oYmFzZSwgbm93PU5vbmUpOgogICAgIiIiRWluZSBSdW5kZSwgaG9lY2hzdGVucyBhbGxlIDYwIHMgdm9tIEZhZGVuLiBPZWZmbmV0IGtlaW5lbiBTdGljay4iIiIKICAgIG5vdyA9IHRpbWUudGltZSgpIGlmIG5vdyBpcyBOb25lIGVsc2UgZmxvYXQobm93KQogICAgc3RhbmQgPSBfanNvbl9sZXNlbihvcy5wYXRoLmpvaW4oYmFzZSwgInNkcl9zdGF0dXMuanNvbiIpKSBvciB7fQogICAgcGFhcmUgPSAoCiAgICAgICAgKCJzdGlja19oZWFsdGgiLCAiQWlyc3B5IDExRCIpLAogICAgICAgICgic3RpY2tfaGVhbHRoMiIsICJTdGljayAxIiksCiAgICAgICAgKCJzdGlja19oZWFsdGgzIiwgIlN0aWNrIDIiKSwKICAgICAgICAoInN0aWNrX2hlYWx0aDQiLCAiU3RpY2sgMyBGbHVnZnVuayIpLAogICAgKQogICAgZm9yIGtleSwgbmFtZSBpbiBwYWFyZToKICAgICAgICBib3ggPSBzdGFuZC5nZXQoa2V5KSBpZiBpc2luc3RhbmNlKHN0YW5kLmdldChrZXkpLCBkaWN0KSBlbHNlIE5vbmUKICAgICAgICBpZiBub3QgYm94OgogICAgICAgICAgICBub3RpZXJlKGJhc2UsIG5hbWUsICJzZHIiLCAia2VpbiBTdGFuZCIsIG5vdz1ub3cpCiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgdGV4dCA9IHNjaHdhZXJ6ZW4oYm94LmdldCgidHh0Iikgb3IgYm94LmdldCgibHZsIikgb3IgImxlZXIiKQogICAgICAgIGlmICJTdGljayAzIiBpbiB0ZXh0OgogICAgICAgICAgICB0ZXh0ID0gdGV4dC5yZXBsYWNlKCJTdGljayAzIMK3IEhvYmJ5IiwgIlN0aWNrIDMgRmx1Z2Z1bmsiKQogICAgICAgIG5vdGllcmUoYmFzZSwgbmFtZSwgInNkciIsICIlczogJXMiICUgKGJveC5nZXQoImx2bCIpIG9yICI/IiwgdGV4dCksIG5vdz1ub3cpCiAgICBmdW5rID0gX2pzb25fbGVzZW4ob3MucGF0aC5qb2luKGJhc2UsICJmbHVnZnVua19zdGF0dXMuanNvbiIpKSBvciB7fQogICAgaWYgZnVuazoKICAgICAgICBsYWdlID0gIkVtcGZhbmciIGlmIGZ1bmsuZ2V0KCJsYWV1ZnQiKSBlbHNlICJhdXMiCiAgICAgICAgaWYgZnVuay5nZXQoImZlaGxlciIpOgogICAgICAgICAgICBsYWdlID0gc2Nod2FlcnplbihmdW5rLmdldCgiZmVobGVyIikpCiAgICAgICAgbm90aWVyZShiYXNlLCAiU3RpY2sgMyBGbHVnZnVuayIsICJlbXBmYW5nIiwgbGFnZSwgbm93PW5vdykKICAgIHN0dW5kZSA9IF9mbHVnZnVua19zdHVuZGUoYmFzZSwgbm93KQogICAgaWYgc3R1bmRlIGlzIG5vdCBOb25lOgogICAgICAgIHphaGwsIGtvbmYgPSBzdHVuZGUKICAgICAgICBrb25mX3R4dCA9ICJvaG5lIFdlcnQiIGlmIGtvbmYgaXMgTm9uZSBlbHNlICgiJS4yZiIgJSBmbG9hdChrb25mKSkKICAgICAgICBub3RpZXJlKGJhc2UsICJTdGljayAzIEZsdWdmdW5rIiwgInNwcnVlY2hlIiwgIiVkIFNwcsO8Y2hlL2gsIEVya2VubnVuZyAlcyIgJSAoemFobCwga29uZl90eHQpLCBub3c9bm93LCBpbW1lcj1GYWxzZSkKICAgIGZvciB6ZWlsZSBpbiBfa2VybmVsKG5vdyk6CiAgICAgICAgbm90aWVyZShiYXNlLCAiS2VybmVsIiwgInVzYiIsIHplaWxlLCBub3c9bm93KQogICAgaWYgc2h1dGlsLndoaWNoKCJzeXN0ZW1jdGwiKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIG91dCA9IHN1YnByb2Nlc3MucnVuKAogICAgICAgICAgICAgICAgWyJzeXN0ZW1jdGwiLCAic2hvdyIsICItcCIsICJOUmVzdGFydHMiLCAiLS12YWx1ZSIsICJwcmVwcGVyLWRhc2hib2FyZC5zZXJ2aWNlIl0sCiAgICAgICAgICAgICAgICBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9MywKICAgICAgICAgICAgKQogICAgICAgICAgICB3ZXJ0ID0gKG91dC5zdGRvdXQgb3IgIiIpLnN0cmlwKCkgb3IgIjAiCiAgICAgICAgICAgIG5vdGllcmUoYmFzZSwgInByZXBwZXItZGFzaGJvYXJkIiwgIm5ldXN0YXJ0IiwgIk5SZXN0YXJ0cyAlcyIgJSB3ZXJ0LCBub3c9bm93KQogICAgICAgIGV4Y2VwdCAoT1NFcnJvciwgc3VicHJvY2Vzcy5UaW1lb3V0RXhwaXJlZCk6CiAgICAgICAgICAgIHBhc3MKICAgIHJldHVybiBUcnVlCgoKZGVmIF9sb29wKGJhc2UpOgogICAgd2hpbGUgVHJ1ZToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHNhbW1lbG4oYmFzZSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzoKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgbm90aWVyZShiYXNlLCAibG9nYmVyaWNodCIsICJmZWhsZXIiLCB0eXBlKGV4YykuX19uYW1lX18sIGltbWVyPUZhbHNlKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcGFzcwogICAgICAgIHRpbWUuc2xlZXAoVElDS19TKQoKCmRlZiBzdGFydGVuKGJhc2UpOgogICAgaWYgb3MuZW52aXJvbi5nZXQoIkxPR0JFUklDSFRfTk9fVEhSRUFEIikgPT0gIjEiOgogICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgZ2V0YXR0cihzdGFydGVuLCAiX2FuIiwgRmFsc2UpOgogICAgICAgIHJldHVybiBGYWxzZQogICAgc3RhcnRlbi5fYW4gPSBUcnVlCiAgICB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1fbG9vcCwgYXJncz0oYmFzZSwpLCBuYW1lPSJsb2diZXJpY2h0IiwgZGFlbW9uPVRydWUpLnN0YXJ0KCkKICAgIHJldHVybiBUcnVlCgoKZGVmIHNla3VuZGVuKHNwZWMpOgogICAgdGV4dCA9IHN0cihzcGVjIG9yICIyNGgiKS5zdHJpcCgpLmxvd2VyKCkKICAgIGVpbmhlaXQgPSB0ZXh0Wy0xOl0KICAgIHphaGwgPSB0ZXh0WzotMV0KICAgIGlmIG5vdCB6YWhsLmlzZGlnaXQoKSBvciBlaW5oZWl0IG5vdCBpbiAoImgiLCAiZCIpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IodGV4dCkKICAgIGZha3RvciA9IDM2MDAgaWYgZWluaGVpdCA9PSAiaCIgZWxzZSA4NjQwMAogICAgcmV0dXJuIG1heCgzNjAwLCBtaW4oS0VFUF9TLCBpbnQoemFobCkgKiBmYWt0b3IpKQoKCmRlZiBfbXVzdGVyKHJvd3MpOgogICAgc3R1bmRlbiA9IHt9CiAgICBmb3IgdHMsIF9xdWVsbGUsIF9hcnQsIF90ZXh0IGluIHJvd3M6CiAgICAgICAgc3R1bmRlID0gZGF0ZXRpbWUuZnJvbXRpbWVzdGFtcChpbnQodHMpLCBCRVJMSU4pLmhvdXIKICAgICAgICBzdHVuZGVuW3N0dW5kZV0gPSBzdHVuZGVuLmdldChzdHVuZGUsIDApICsgMQogICAgaWYgbm90IHN0dW5kZW46CiAgICAgICAgcmV0dXJuICJrZWluZSBIw6R1ZnVuZyIKICAgIHNwaXR6ZSA9IG1heChzdHVuZGVuLnZhbHVlcygpKQogICAgdHJlZmZlciA9IFsoIiUwMmQiICUgc3R1bmRlKSBmb3Igc3R1bmRlLCB6YWhsIGluIHNvcnRlZChzdHVuZGVuLml0ZW1zKCkpIGlmIHphaGwgPj0gc3BpdHplIGFuZCBzcGl0emUgPiAxXQogICAgaWYgbm90IHRyZWZmZXI6CiAgICAgICAgcmV0dXJuICJrZWluZSB3aWVkZXJrZWhyZW5kZSBTdHVuZGUiCiAgICByZXR1cm4gImjDpHVmaWcgdW0gIiArICIsICIuam9pbih0cmVmZmVyKSArICIgVWhyIgoKCmRlZiBiZXJpY2h0KGJhc2UsIHNwZWM9IjI0aCIsIG5vdz1Ob25lKToKICAgIG5vdyA9IHRpbWUudGltZSgpIGlmIG5vdyBpcyBOb25lIGVsc2UgZmxvYXQobm93KQogICAgZGF1ZXIgPSBzZWt1bmRlbihzcGVjKQogICAgcGF0aCA9IG9zLnBhdGguam9pbihiYXNlLCBEQl9OQU1FKQogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKHBhdGgpOgogICAgICAgIHJldHVybiAiRGlhZ25vc2ViZXJpY2h0ICVzXG5ub2NoIGtlaW5lIEVyZWlnbmlzc2VcbiIgJSBzcGVjCiAgICBjb24gPSBjb25uZWN0KHBhdGgpCiAgICB0cnk6CiAgICAgICAgcm93cyA9IGNvbi5leGVjdXRlKAogICAgICAgICAgICAiU0VMRUNUIHQsIHF1ZWxsZSwgYXJ0LCB0ZXh0LCBkYXVlcl9tcywga29udGV4dCBGUk9NIGVyZWlnbmlzIFdIRVJFIHQgPj0gPyBPUkRFUiBCWSB0IiwKICAgICAgICAgICAgKGludChub3cpIC0gZGF1ZXIsKSwKICAgICAgICApLmZldGNoYWxsKCkKICAgIGZpbmFsbHk6CiAgICAgICAgY29uLmNsb3NlKCkKICAgIHplaWxlbiA9IFsiRGlhZ25vc2ViZXJpY2h0ICVzIHNlaXQgJXMiICUgKHNwZWMsIGJlcmxpbihub3cgLSBkYXVlcikpLCAiIl0KICAgIGhhZXVmaWcgPSB7fQogICAgZm9yIF90LCBxdWVsbGUsIGFydCwgdGV4dCwgX2QsIF9rIGluIHJvd3M6CiAgICAgICAga2V5ID0gIiVzICVzICVzIiAlIChxdWVsbGUsIGFydCwgdGV4dCkKICAgICAgICBoYWV1ZmlnW2tleV0gPSBoYWV1ZmlnLmdldChrZXksIDApICsgMQogICAgemVpbGVuLmFwcGVuZCgiw5xiZXJzaWNodCIpCiAgICBpZiBub3QgaGFldWZpZzoKICAgICAgICB6ZWlsZW4uYXBwZW5kKCJrZWluZSBFcmVpZ25pc3NlIikKICAgIGZvciBrZXksIHphaGwgaW4gc29ydGVkKGhhZXVmaWcuaXRlbXMoKSwga2V5PWxhbWJkYSBwYWFyOiBwYWFyWzFdLCByZXZlcnNlPVRydWUpWzo0MF06CiAgICAgICAgemVpbGVuLmFwcGVuZCgiJWQgw5cgJXMiICUgKHphaGwsIGtleSkpCiAgICB6ZWlsZW4uYXBwZW5kKCIiKQogICAgemVpbGVuLmFwcGVuZCgiWmVpdGxlaXN0ZTogIiArIF9tdXN0ZXIoWyhyWzBdLCByWzFdLCByWzJdLCByWzNdKSBmb3IgciBpbiByb3dzXSkpCiAgICBmb3IgdHMsIHF1ZWxsZSwgYXJ0LCB0ZXh0LCBkYXVlcl9tcywga29udGV4dCBpbiByb3dzWy0yMDA6XToKICAgICAgICBleHRyYSA9ICIiIGlmIGRhdWVyX21zIGlzIE5vbmUgZWxzZSAiICVkIG1zIiAlIGludChkYXVlcl9tcykKICAgICAgICB6ZWlsZW4uYXBwZW5kKCIlcyAlcyAlcyVzICVzIiAlIChiZXJsaW4odHMpLCBxdWVsbGUsIGFydCwgZXh0cmEsIHRleHQpKQogICAgICAgIGlmIGtvbnRleHQ6CiAgICAgICAgICAgIHplaWxlbi5hcHBlbmQoIiAgIiArIGtvbnRleHQpCiAgICB6ZWlsZW4uYXBwZW5kKCIiKQogICAgemVpbGVuLmFwcGVuZCgiU0RSIikKICAgIGZvciBuYW1lIGluICgiQWlyc3B5IDExRCIsICJTdGljayAxIiwgIlN0aWNrIDIiLCAiU3RpY2sgMyBGbHVnZnVuayIpOgogICAgICAgIGVpZ2VuZSA9IFtyIGZvciByIGluIHJvd3MgaWYgclsxXSA9PSBuYW1lXQogICAgICAgIHplaWxlbi5hcHBlbmQobmFtZSArICI6ICIgKyAoKCIlZCBFcmVpZ25pc3NlIiAlIGxlbihlaWdlbmUpKSBpZiBlaWdlbmUgZWxzZSAia2VpbmUgRXJlaWduaXNzZSIpKQogICAgemVpbGVuLmFwcGVuZCgiIikKICAgIGlmIGhhZXVmaWc6CiAgICAgICAgdG9wID0gbWF4KGhhZXVmaWcuaXRlbXMoKSwga2V5PWxhbWJkYSBwYWFyOiBwYWFyWzFdKQogICAgICAgIHplaWxlbi5hcHBlbmQoImF1ZmbDpGxsaWdzdGUgVXJzYWNoZW46ICVzICglZCkiICUgKHRvcFswXSwgdG9wWzFdKSkKICAgIGVsc2U6CiAgICAgICAgemVpbGVuLmFwcGVuZCgiYXVmZsOkbGxpZ3N0ZSBVcnNhY2hlbjoga2VpbmUiKQogICAgemVpbGVuLmFwcGVuZCgiIikKICAgIHJldHVybiAiXG4iLmpvaW4oemVpbGVuKQoKCmRlZiBuYWNoX2FudHdvcnQocmVzcCwgYmFzZSwgcGZhZCwgc3RhdHVzLCBhbmZhbmcsIGJvZHk9IiIpOgogICAgZGF1ZXIgPSBpbnQoKHRpbWUudGltZSgpIC0gYW5mYW5nKSAqIDEwMDApCiAgICBpZiBwZmFkLnN0YXJ0c3dpdGgoIi9zdGF0aWMiKSBvciBwZmFkLnN0YXJ0c3dpdGgoIi9hcGkvbG9nYmVyaWNodCIpOgogICAgICAgIHJldHVybgogICAgaWYgc3RhdHVzID49IDUwMDoKICAgICAgICBub3RpZXJlKGJhc2UsIHBmYWQsICJodHRwIiwgIkhUVFAgJXMiICUgc3RhdHVzLCBkYXVlcl9tcz1kYXVlcikKICAgIGVsaWYgc3RhdHVzID49IDQwMDoKICAgICAgICBub3RpZXJlKGJhc2UsIHBmYWQsICJodHRwIiwgIkhUVFAgJXMiICUgc3RhdHVzLCBkYXVlcl9tcz1kYXVlcikKICAgIGVsaWYgZGF1ZXIgPj0gMzAwMDoKICAgICAgICBub3RpZXJlKGJhc2UsIHBmYWQsICJsYW5nc2FtIiwgIkFudHdvcnQgJWQgbXMiICUgZGF1ZXIsIGRhdWVyX21zPWRhdWVyKQogICAgaWYgYm9keSBhbmQgIlRyYWNlYmFjayIgaW4gYm9keVs6NDAwMF06CiAgICAgICAgbm90aWVyZShiYXNlLCBwZmFkLCAidHJhY2ViYWNrIiwgdHJhY2ViYWNrX2t1cnooYm9keSksIGRhdWVyX21zPWRhdWVyKQogICAgaWYgcGZhZC5zdGFydHN3aXRoKCIvYXBpIikgYW5kIGJvZHkgYW5kIGxlbihib2R5KSA8IDIwMDAwOgogICAgICAgIGlmIGJvZHkuc3RyaXAoKSBpbiAoInt9IiwgIltdIiwgIm51bGwiKToKICAgICAgICAgICAgbm90aWVyZShiYXNlLCBwZmFkLCAibGVlciIsICJsZWVyZSBBbnR3b3J0IiwgZGF1ZXJfbXM9ZGF1ZXIpCgoKS0FSVEUgPSAoCiAgICAnPGRpdiBjbGFzcz0iY2FyZCBmdWxsIiBpZD0ibG9nYmVyaWNodEJveCIgc3R5bGU9Im1hcmdpbi10b3A6MTJweDttYXgtd2lkdGg6MTAwJTttaW4td2lkdGg6MCI+JwogICAgJzxkaXYgc3R5bGU9ImZvbnQtd2VpZ2h0OjYwMCI+RGlhZ25vc2ViZXJpY2h0PC9kaXY+JwogICAgJzxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtmbGV4LXdyYXA6d3JhcDtnYXA6OHB4O21hcmdpbi10b3A6NnB4O2FsaWduLWl0ZW1zOmNlbnRlciI+JwogICAgJzxzZWxlY3QgaWQ9ImxiV2FobCI+JwogICAgJzxvcHRpb24+MWg8L29wdGlvbj48b3B0aW9uIHNlbGVjdGVkPjZoPC9vcHRpb24+PG9wdGlvbj4yNGg8L29wdGlvbj48b3B0aW9uPjNkPC9vcHRpb24+PG9wdGlvbj43ZDwvb3B0aW9uPicKICAgICc8L3NlbGVjdD4nCiAgICAnPGlucHV0IGlkPSJsYkVpZ2VuIiBwbGFjZWhvbGRlcj0iei4gQi4gMTJoIiBzdHlsZT0ibWF4LXdpZHRoOjhlbSI+JwogICAgJzxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0ibGJIb2wiPlplaWdlbjwvYnV0dG9uPicKICAgICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9ImxiS29wIj5Lb3BpZXJlbjwvYnV0dG9uPjwvZGl2PicKICAgICc8ZGl2IGlkPSJsYk1zZyIgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiM5NGEzYjg7bWluLWhlaWdodDoxLjJlbSI+PC9kaXY+JwogICAgJzx0ZXh0YXJlYSBpZD0ibGJUZXh0IiByZWFkb25seSBzdHlsZT0id2lkdGg6MTAwJTttaW4taGVpZ2h0OjEyZW07Ym94LXNpemluZzpib3JkZXItYm94O21hcmdpbi10b3A6NnB4Ij48L3RleHRhcmVhPicKICAgICc8L2Rpdj48c2NyaXB0IGlkPSJsb2diZXJpY2h0LWpzIj4oZnVuY3Rpb24oKXsnCiAgICAndmFyIHc9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoImxiV2FobCIpLGU9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoImxiRWlnZW4iKSx0PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJsYlRleHQiKSxtPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJsYk1zZyIpOycKICAgICdmdW5jdGlvbiB6ZWl0KCl7dmFyIHg9KGUmJmUudmFsdWV8fCIiKS50cmltKCk7cmV0dXJuIHh8fCh3P3cudmFsdWU6IjZoIik7fScKICAgICdmdW5jdGlvbiBob2woKXttLnRleHRDb250ZW50PSJsYWRlIOKApiI7ZmV0Y2goIi9hcGkvbG9nYmVyaWNodD96ZWl0cmF1bT0iK2VuY29kZVVSSUNvbXBvbmVudCh6ZWl0KCkpLHtjYWNoZToibm8tc3RvcmUifSknCiAgICAnLnRoZW4oZnVuY3Rpb24ocil7aWYoIXIub2spdGhyb3cgMDtyZXR1cm4gci5qc29uKCk7fSkudGhlbihmdW5jdGlvbihkKXt0LnZhbHVlPWQudGV4dHx8IiI7bS50ZXh0Q29udGVudD0iIjt9KScKICAgICcuY2F0Y2goZnVuY3Rpb24oKXttLnRleHRDb250ZW50PSJuaWNodCBsZXNiYXIiO30pO30nCiAgICAnZnVuY3Rpb24ga29wKCl7dmFyIHM9dC52YWx1ZXx8IiI7aWYobmF2aWdhdG9yLmNsaXBib2FyZCYmbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQpe25hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHMpLnRoZW4oZnVuY3Rpb24oKXttLnRleHRDb250ZW50PSJrb3BpZXJ0Ijt9LGZ1bmN0aW9uKCl7dC5mb2N1cygpO3Quc2VsZWN0KCk7bS50ZXh0Q29udGVudD0ibWFya2llcnQiO30pO30nCiAgICAnZWxzZXt0LmZvY3VzKCk7dC5zZWxlY3QoKTttLnRleHRDb250ZW50PSJtYXJraWVydCI7fX0nCiAgICAnZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoImxiSG9sIikuYWRkRXZlbnRMaXN0ZW5lcigiY2xpY2siLGhvbCk7JwogICAgJ2RvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJsYktvcCIpLmFkZEV2ZW50TGlzdGVuZXIoImNsaWNrIixrb3ApO2hvbCgpO30pKCk7PC9zY3JpcHQ+JwopCgoKZGVmIGluX3NlaXRlKGh0bWwsIHBmYWQpOgogICAgaWYgcGZhZCBub3QgaW4gKCIvcGkiLCAiL3N5c3RlbSIpOgogICAgICAgIHJldHVybiBodG1sCiAgICBpZiAnaWQ9ImxvZ2JlcmljaHRCb3giJyBpbiBodG1sOgogICAgICAgIHJldHVybiBodG1sCiAgICBqID0gaHRtbC5yZmluZCgiPC9ib2R5PiIpCiAgICByZXR1cm4gKGh0bWxbOmpdICsgS0FSVEUgKyBodG1sW2o6XSkgaWYgaiA+PSAwIGVsc2UgaHRtbCArIEtBUlRFCgoKZGVmIGxhbl9vayhpcCk6CiAgICBpZiBub3QgaXA6CiAgICAgICAgcmV0dXJuIFRydWUKICAgIGlwID0gc3RyKGlwKS5zcGxpdCgiJSIsIDEpWzBdCiAgICBpZiBpcC5zdGFydHN3aXRoKCI6OmZmZmY6Iik6CiAgICAgICAgaXAgPSBpcFs3Ol0KICAgIGltcG9ydCBpcGFkZHJlc3MKICAgIHRyeToKICAgICAgICBhZHJlc3NlID0gaXBhZGRyZXNzLmlwX2FkZHJlc3MoaXApCiAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHJldHVybiBib29sKGFkcmVzc2UuaXNfbG9vcGJhY2sgb3IgYWRyZXNzZS5pc19wcml2YXRlIG9yIGFkcmVzc2UuaXNfbGlua19sb2NhbCkKCgpkZWYgYXBpX3Jlc3BvbnNlKGJhc2UsIHplaXRyYXVtLCBpcCk6CiAgICBmcm9tIGZsYXNrIGltcG9ydCBhYm9ydCwganNvbmlmeQogICAgaWYgbm90IGxhbl9vayhpcCk6CiAgICAgICAgYWJvcnQoNDAzKQogICAgcmV0dXJuIGpzb25pZnkoeyJvayI6IFRydWUsICJ0ZXh0IjogYmVyaWNodChiYXNlLCB6ZWl0cmF1bSBvciAiNmgiKX0pCgoKZGVmIHNlbGZ0ZXN0KCk6CiAgICBpbXBvcnQgdGVtcGZpbGUKICAgIGFzc2VydCBzZWt1bmRlbigiNmgiKSA9PSA2ICogMzYwMCBhbmQgc2VrdW5kZW4oIjNkIikgPT0gMyAqIDg2NDAwCiAgICBhc3NlcnQgIjxpcD4iIGluIHNjaHdhZXJ6ZW4oInZvbiA4LjguOC44IHRva2VuPUFCQyIpCiAgICBhc3NlcnQgIjxzbj4iIGluIHNjaHdhZXJ6ZW4oIlNOIDI2MTAyNDAzIHVuZCBBQkNERUYxMiIpCiAgICBhc3NlcnQgInBhc3N3b3J0PTxlbnRmZXJudD4iIGluIHNjaHdhZXJ6ZW4oInBhc3N3b3J0PWdlaGVpbSIpCiAgICBrdXJ6ID0gdHJhY2ViYWNrX2t1cnooIlRyYWNlYmFjayBaZWlsZVxubWl0dGVuZHJpblxuVmFsdWVFcnJvcjogeCIpCiAgICBhc3NlcnQga3Vyei5zdGFydHN3aXRoKCJUcmFjZWJhY2siKSBhbmQga3Vyei5lbmRzd2l0aCgiVmFsdWVFcnJvcjogeCIpIGFuZCAibWl0dGVuZHJpbiIgbm90IGluIGt1cnoKICAgIGQgPSB0ZW1wZmlsZS5ta2R0ZW1wKHByZWZpeD0ibG9nYmVyaWNodC0iKQogICAgdHJ5OgogICAgICAgIGFzc2VydCBub3RpZXJlKGQsICJTdGljayAzIEZsdWdmdW5rIiwgImVtcGZhbmciLCAiYXVzIiwgbm93PTEwMDApCiAgICAgICAgYXNzZXJ0IG5vdCBub3RpZXJlKGQsICJTdGljayAzIEZsdWdmdW5rIiwgImVtcGZhbmciLCAiYXVzIiwgbm93PTEyMDApCiAgICAgICAgYXNzZXJ0IG5vdGllcmUoZCwgIi9hcGkveCIsICJsYW5nc2FtIiwgIkFudHdvcnQgNDAwMCBtcyIsIGRhdWVyX21zPTQwMDAsIG5vdz01MDAwKQogICAgICAgIHRleHQgPSBiZXJpY2h0KGQsICIyNGgiLCBub3c9NTAwMCArIDM2MDApCiAgICAgICAgYXNzZXJ0ICJTdGljayAzIEZsdWdmdW5rIiBpbiB0ZXh0IGFuZCAiYXVmZsOkbGxpZ3N0ZSBVcnNhY2hlbiIgaW4gdGV4dAogICAgICAgIGFzc2VydCAiOC44LjguOCIgbm90IGluIHRleHQKICAgICAgICBhdWYgPSBjb25uZWN0KG9zLnBhdGguam9pbihkLCBEQl9OQU1FKSkKICAgICAgICBhdWZyYWV1bWVuKGF1Ziwgb3MucGF0aC5qb2luKGQsIERCX05BTUUpLCAxMDAwICsgS0VFUF9TICsgMTApCiAgICAgICAgYXVmLmNsb3NlKCkKICAgICAgICByZXN0ID0gYmVyaWNodChkLCAiMjRoIiwgbm93PTEwMDAgKyBLRUVQX1MgKyAxMCkKICAgICAgICBhc3NlcnQgImtlaW5lIEVyZWlnbmlzc2UiIGluIHJlc3Qgb3IgIlN0aWNrIDMiIG5vdCBpbiByZXN0CiAgICAgICAgc2VpdGUgPSBpbl9zZWl0ZSgiPGh0bWw+PGJvZHk+YWx0PC9ib2R5PjwvaHRtbD4iLCAiL3BpIikKICAgICAgICBhc3NlcnQgImxvZ2JlcmljaHRCb3giIGluIHNlaXRlIGFuZCAiS29waWVyZW4iIGluIHNlaXRlCiAgICAgICAgYXNzZXJ0IGluX3NlaXRlKHNlaXRlLCAiL2Z1bmsiKSA9PSBzZWl0ZSBvciAibG9nYmVyaWNodEJveCIgbm90IGluIGluX3NlaXRlKCI8aHRtbD48Ym9keT48L2JvZHk+PC9odG1sPiIsICIvZnVuayIpCiAgICAgICAgYXNzZXJ0IG5vdCBsYW5fb2soIjguOC44LjgiKSBhbmQgbGFuX29rKCIxOTIuMTY4LjE3OC4xMCIpCiAgICBmaW5hbGx5OgogICAgICAgIHNodXRpbC5ybXRyZWUoZCwgaWdub3JlX2Vycm9ycz1UcnVlKQogICAgcmV0dXJuICJsb2diZXJpY2h0IG9rIgoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBpbXBvcnQgc3lzCiAgICBiYXNpcyA9IG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKQogICAgaWYgbGVuKHN5cy5hcmd2KSA+IDEgYW5kIHN5cy5hcmd2WzFdID09ICItLXNlbGZ0ZXN0IjoKICAgICAgICBwcmludChzZWxmdGVzdCgpKQogICAgZWxpZiBsZW4oc3lzLmFyZ3YpID4gMSBhbmQgc3lzLmFyZ3ZbMV0gPT0gImJlcmljaHQiOgogICAgICAgIHByaW50KGJlcmljaHQoYmFzaXMsIHN5cy5hcmd2WzJdIGlmIGxlbihzeXMuYXJndikgPiAyIGVsc2UgIjI0aCIpKQogICAgZWxzZToKICAgICAgICBwcmludChzZWxmdGVzdCgpKQo="}'''

if __name__ == "__main__":
    sys.exit(main(sys.argv))
