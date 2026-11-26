# -*- coding: utf-8 -*-
import argparse, base64, hashlib, json, os, secrets, shutil, subprocess, sys, tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

FEST = {
    "dashboard.py": ("bd5efb5b00eb43b4", 1391222),
    "flugfunk.py": ("12514204980036ce", 94515),
    "prepper_sdr.py": ("17ee0ae046d25be9", 794528),
    "prepper_log.py": ("fd79a1c81de167f0", 17791),
}
FC_FEST = "cba457864eb1c32f5f4a7063a71c68c7256b8d7466d8f47ba6c767598fb009a8"
FC_BYTES = 99339
FULL = Path("/home/fmg/fullcheck.sh")
ICE_ALT = """  if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8000/flugfunk; then ok "Icecast /flugfunk" "Mount live"
  elif systemctl is-active --quiet prepper-icecast && ! find "$APP/flugfunk-audio/live" -name 'live*.mp3' -mmin -5 2>/dev/null | grep -q .; then warn "Icecast /flugfunk" "laeuft, keine Live-Datei seit 5 min" "rtl_airband"
  else info "Icecast /flugfunk" "Mount noch nicht, Datei frisch oder Dienst aus"; fi
"""
ICE_NEU = """  CODE="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8000/flugfunk || true)"
  if [[ "$CODE" == "200" ]]; then ok "Icecast /flugfunk" "Mount live"
  elif systemctl is-active --quiet prepper-icecast; then warn "Icecast /flugfunk" "HTTP $CODE" "Mount 404 bei laufendem Icecast"
  else info "Icecast /flugfunk" "Dienst nicht aktiv"; fi
"""
SUDO_BLOCK = """sudo install -o icecast2 -g icecast -m 640 /home/fmg/prepper-dashboard/icecast-flugfunk.xml /etc/icecast2/flugfunk.xml
sudo systemctl restart prepper-icecast.service
"""

def sha(data):
    return hashlib.sha256(data).hexdigest()

def fenster(jetzt):
    jetzt = jetzt.astimezone(ZoneInfo("Europe/Berlin"))
    return 5 <= jetzt.minute <= 39, "Berlin %s Minute %02d" % (jetzt.strftime("%H:%M"), jetzt.minute)

def laden():
    return json.loads(PAYLOAD_TEXT)

def tausch(data, old, new):
    if new in data:
        return data
    if data.count(old) != 1:
        raise RuntimeError("stelle")
    return data.replace(old, new, 1)

def fullcheck_neu(text):
    if "elDBYTES" in text:
        raise RuntimeError("elif")
    if "HTTP $CODE" in text and 'FC_VERSION="2.9"' in text:
        return text
    if 'FC_VERSION="2.8"' not in text and 'FC_VERSION="2.7"' not in text:
        raise RuntimeError("version")
    if ICE_ALT not in text:
        raise RuntimeError("anker")
    neu = text.replace('FC_VERSION="2.8"', 'FC_VERSION="2.9"', 1).replace('FC_VERSION="2.7"', 'FC_VERSION="2.9"', 1)
    neu = neu.replace(ICE_ALT, ICE_NEU, 1)
    for name, wert in (("FC_DASH_SHA16", "bd5efb5b00eb43b4"), ("FC_DASH_BYTES", "1391222")):
        import re
        muster = r"(\$\{%s:-)[^}\n]+" % name
        if not re.search(muster, neu):
            raise RuntimeError(name)
        neu, n = re.subn(muster, r"\g<1>" + wert, neu, count=1)
        if n != 1:
            raise RuntimeError(name)
    if "elDBYTES" in neu:
        raise RuntimeError("elif")
    return neu

def bash_n(text):
    tmp = Path(tempfile.mkstemp(prefix="fullcheck-", suffix=".sh")[1])
    try:
        tmp.write_text(text)
        r = subprocess.run(["bash", "-n", str(tmp)], capture_output=True, text=True)
        return r.returncode == 0, (r.stderr or "").strip()
    finally:
        tmp.unlink(missing_ok=True)

def sichern(path, data, ende):
    path = Path(path)
    stempel = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S")
    alt = sorted(path.parent.glob(path.name + ".bak-" + ende + "-*"))
    bak = Path(str(path) + ".bak-" + ende + "-" + stempel)
    shutil.copy2(path, bak)
    if bak.read_bytes() != data:
        bak.unlink()
        raise RuntimeError("Sicherung")
    for alt_pfad in alt[:-2]:
        alt_pfad.unlink(missing_ok=True)

def schreiben(path, data, ende, mode=None):
    path = Path(path)
    recht = mode if mode is not None else (path.stat().st_mode & 0o777 if path.exists() else 0o644)
    tmp = path.with_name("." + path.name + ".tmp-" + ende)
    if tmp.exists():
        raise RuntimeError("temporaer")
    roh = data if isinstance(data, bytes) else data.encode()
    try:
        with open(tmp, "wb") as handle:
            handle.write(roh)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, recht)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)

def icecast_xml(ordner):
    geheim = secrets.token_hex(18)
    basis = Path(ordner)
    schreiben(basis / "icecast-flugfunk.pw", geheim + "\n", "flugfunk7d", 0o600)
    xml = (
        "<icecast><hostname>127.0.0.1</hostname>"
        "<listen-socket><port>8000</port><bind-address>127.0.0.1</bind-address></listen-socket>"
        "<limits><source-timeout>60</source-timeout></limits>"
        "<authentication><source-password>%s</source-password><relay-password>%s</relay-password>"
        "<admin-user>admin</admin-user><admin-password>%s</admin-password></authentication>"
        "<mount><mount-name>/flugfunk</mount-name><public>0</public></mount>"
        "<paths><logdir>/var/log/icecast2</logdir><webroot>/usr/share/icecast2/web</webroot>"
        "<adminroot>/usr/share/icecast2/admin</adminroot></paths></icecast>\n"
    ) % (geheim, geheim, geheim)
    schreiben(basis / "icecast-flugfunk.xml", xml, "flugfunk7d", 0o600)
    print("source-timeout 60. Neues Passwort nur in der Datei, nicht angezeigt. Gruppe icecast.")
    return geheim

def unit_install(ordner):
    if str(ordner) != "/home/fmg/prepper-dashboard":
        print("Testordner, kein sudo")
        return
    cmd = ["sudo", "-n", "install", "-o", "icecast2", "-g", "icecast", "-m", "640",
           str(Path(ordner) / "icecast-flugfunk.xml"), "/etc/icecast2/flugfunk.xml"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    r2 = subprocess.run(["sudo", "-n", "systemctl", "restart", "prepper-icecast.service"], capture_output=True, text=True) if r.returncode == 0 else r
    if r.returncode != 0 or r2.returncode != 0:
        print("sudo -n fehlgeschlagen. Kompletter Block, Gruppe icecast:")
        print(SUDO_BLOCK)
        return
    print("prepper-icecast neu gestartet. Keine Firewall.")

def apply_dir(ordner, dry, kein, jetzt=None, hashcheck=True, fullcheck_hash=None, full_pfad=None):
    print("In Funkpausen sendet der Relay ein stilles MP3-Frame. Tot oder Mount nicht 200: Kette neu.")
    print("prepper-sdr, prepper-dashboard und prepper-icecast muessen neu starten. Ein Pi-Neustart wird nicht ausgefuehrt.")
    ordner = Path(ordner)
    roh = laden()
    ziel = {}
    for name, fest in FEST.items():
        pfad = ordner / name
        if not pfad.is_file():
            if not hashcheck and name != "flugfunk.py":
                continue
            print("STOP: %s fehlt" % pfad)
            return 2
        data = pfad.read_bytes()
        print("%s sha16 %s bytes %d" % (name, sha(data)[:16], len(data)))
        if hashcheck and (not sha(data).startswith(fest[0]) or len(data) != fest[1]):
            print("STOP: %s ist nicht der Stand nach flugfunk-7c" % name)
            print("Live-Hash sha256 %s" % sha(data))
            return 2
        neu = data
        if name == "flugfunk.py":
            try:
                for paar in roh["flugfunk"]:
                    neu = tausch(neu, base64.b64decode(paar["old"]), base64.b64decode(paar["new"]))
            except RuntimeError:
                print("STOP: Stelle in flugfunk.py unbekannt. Nichts geschrieben.")
                return 2
            if hashcheck:
                try:
                    compile(neu, name, "exec")
                except SyntaxError:
                    print("STOP: flugfunk.py kompiliert nicht. Nichts geschrieben.")
                    return 2
        ziel[name] = (pfad, data, neu)
        if neu != data:
            print("%s endstand sha16 %s bytes %d" % (name, sha(neu)[:16], len(neu)))
    fc_pfad = Path(full_pfad) if full_pfad else FULL
    if not fc_pfad.is_file():
        print("STOP: fullcheck.sh fehlt")
        return 2
    fc_alt = fc_pfad.read_bytes()
    print("fullcheck.sh sha256 %s bytes %d" % (sha(fc_alt), len(fc_alt)))
    if hashcheck and (sha(fc_alt) != FC_FEST or len(fc_alt) != FC_BYTES):
        print("STOP: fullcheck ist nicht der Stand nach flugfunk-7c")
        print("Live-Hash sha256 %s" % sha(fc_alt))
        return 2
    if fullcheck_hash != sha(fc_alt):
        print("STOP: fullcheck bestaetigen mit --fullcheck-hash %s" % sha(fc_alt))
        return 2
    try:
        fc = fullcheck_neu(fc_alt.decode("utf-8"))
    except RuntimeError as exc:
        print("STOP: fullcheck-Anker %s. Nichts geschrieben." % exc)
        return 2
    ok_bash, fehler = bash_n(fc)
    if not ok_bash:
        print("STOP: bash -n. Rollback, nichts geschrieben. %s" % fehler)
        return 2
    print("fullcheck.sh endstand sha16 %s bytes %d, bash -n gruen" % (sha(fc.encode())[:16], len(fc.encode())))
    ff = ziel.get("flugfunk.py")
    gleich = (not ff or ff[1] == ff[2]) and fc_alt.decode("utf-8") == fc
    if gleich:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    frei, meldung = fenster(jetzt or datetime.now().astimezone())
    print(meldung)
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        return 0
    if not frei:
        print("STOP: Neustart nur Minute 05-39 Berlin. Nichts geschrieben.")
        return 2
    if ff and ff[1] != ff[2]:
        sichern(ff[0], ff[1], "flugfunk7d")
        schreiben(ff[0], ff[2], "flugfunk7d")
    sichern(fc_pfad, fc_alt, "flugfunk7d")
    schreiben(fc_pfad, fc.encode(), "flugfunk7d")
    icecast_xml(ordner)
    print("geschrieben. dashboard.py, prepper_sdr.py und prepper_log.py unveraendert.")
    if kein:
        print("kein Neustart. Block mit Gruppe icecast:")
        print(SUDO_BLOCK)
        return 0
    unit_install(ordner)
    if str(ordner) != "/home/fmg/prepper-dashboard":
        print("Testordner, kein systemctl")
        return 0
    for dienst in ("prepper-sdr.service", "prepper-dashboard.service"):
        subprocess.run(["systemctl", "restart", dienst], check=False)
        print("Neustart %s" % dienst)
    return 0

FIX = """#!/bin/bash
FC_VERSION="2.8"
DASH_SHA16="${FC_DASH_SHA16:-aaaaaaaaaaaaaaaa}"
DASH_BYTES="${FC_DASH_BYTES:-1}"
ok() { :; }
warn() { :; }
info() { :; }
if [[ "$DSH" == "$DASH_SHA16" ]]; then ok "a" "$DSH"
elif [[ "$DSH" == "alt" ]]; then ok "alt" "x"
else warn "a" "$DSH" "Soll"; fi
""" + ICE_ALT

def selftest():
    assert FEST["flugfunk.py"] == ("12514204980036ce", 94515)
    assert FEST["dashboard.py"] == ("bd5efb5b00eb43b4", 1391222)
    assert FC_FEST.startswith("cba45786") and FC_BYTES == 99339
    assert "Group=icecast" not in SUDO_BLOCK or "-g icecast " in SUDO_BLOCK
    roh = laden()
    ordner = Path(tempfile.mkdtemp(prefix="flugfunk7d-"))
    try:
        daten = b"".join(base64.b64decode(p["old"]) + b"\n" for p in roh["flugfunk"])
        (ordner / "flugfunk.py").write_bytes(daten)
        fp = ordner / "fullcheck.sh"
        fp.write_text(FIX)
        vorher = fp.read_bytes()
        assert apply_dir(ordner, True, True, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp) == 0
        assert fp.read_bytes() == vorher
        von = datetime(2026, 11, 26, 21, 4, tzinfo=ZoneInfo("Europe/Berlin"))
        assert apply_dir(ordner, False, False, jetzt=von, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp) == 2
        innen = datetime(2026, 11, 26, 21, 10, tzinfo=ZoneInfo("Europe/Berlin"))
        protokoll = tempfile.NamedTemporaryFile("w+", delete=False)
        alt = sys.stdout
        try:
            sys.stdout = protokoll
            rc = apply_dir(ordner, False, True, jetzt=innen, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp)
            protokoll.flush()
            text = Path(protokoll.name).read_text()
        finally:
            sys.stdout = alt
            os.unlink(protokoll.name)
        assert rc == 0
        neu = fp.read_text()
        assert 'FC_VERSION="2.9"' in neu and "http_code" in neu and "HTTP $CODE" in neu and "elDBYTES" not in neu
        assert "bd5efb5b00eb43b4" in neu and "1391222" in neu and bash_n(neu)[0]
        ff = (ordner / "flugfunk.py").read_text()
        assert "select.select" in ff and "bytes.fromhex" in ff and "icecast://source:${" not in ff
        xml = (ordner / "icecast-flugfunk.xml").read_text()
        pw = (ordner / "icecast-flugfunk.pw").read_text().strip()
        assert "<source-timeout>60</source-timeout>" in xml and pw and pw not in text and pw not in ff
        assert oct((ordner / "icecast-flugfunk.pw").stat().st_mode & 0o777) == "0o600"
    finally:
        shutil.rmtree(ordner, ignore_errors=True)
    return "flugfunk-7d ok"

PAYLOAD_TEXT = "{\"flugfunk\": [{\"old\": \"ICAgICAgICBzb2NrLmNsb3NlKCkKCgo=\", \"new\": \"ICAgICAgICBzb2NrLmNsb3NlKCkKCgojIEVpbiBNUEVHMS1MYXllcjMtRnJhbWUsIDMyIGtiaXQvcywgNDQsMSBrSHosIG1vbm8sIFN0aWxsZS4gSGFlbHQgZGVuIEljZWNhc3QtU29ja2V0IGluIEZ1bmtwYXVzZW4gb2ZmZW4uCl9TVElMTEVfTVAzID0gImZmZmIxMGM0MDAwM2MwMDAwMWE0MDAwMDAwMjAwMDAwMzQ4MDAwMDAwNDRjNDE0ZDQ1MzMyZTMxMzAzMDU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTUiCg==\"}, {\"old\": \"ICAgICJpbXBvcnQgb3Msc3lzLGJhc2U2NCxzb2NrZXRcbiIK\", \"new\": \"ICAgICJpbXBvcnQgb3Msc3lzLGJhc2U2NCxzb2NrZXQsc2VsZWN0XG4iCg==\"}, {\"old\": \"ICAgICJwdz1vcGVuKG9zLmVudmlyb25bJ0ZMVUdGVU5LX1BXX0ZJTEUnXSxlbmNvZGluZz0ndXRmLTgnKS5yZWFkKCkuc3RyaXAoKVxuIgo=\", \"new\": \"ICAgICJwdz1vcGVuKG9zLmVudmlyb25bJ0ZMVUdGVU5LX1BXX0ZJTEUnXSxlbmNvZGluZz0ndXRmLTgnKS5yZWFkKCkuc3RyaXAoKVxuIgogICAgInN0aWxsZT1ieXRlcy5mcm9taGV4KCciICsgX1NUSUxMRV9NUDMgKyAiJylcbiIK\"}, {\"old\": \"ICAgICJidWY9YicnXG4iCg==\", \"new\": \"ICAgICJzLnNldHRpbWVvdXQoNSlcbiIKICAgICJhbnQ9YicnXG4iCiAgICAid2hpbGUgYidcXHJcXG5cXHJcXG4nIG5vdCBpbiBhbnQgYW5kIGxlbihhbnQpPDIwNDg6XG4iCiAgICAiIHRlaWw9cy5yZWN2KDI1NilcbiIKICAgICIgaWYgbm90IHRlaWw6IGJyZWFrXG4iCiAgICAiIGFudCs9dGVpbFxuIgogICAgImlmIGInMjAwJyBub3QgaW4gYW50LnNwbGl0KGInXFxyXFxuJywxKVswXTpcbiIKICAgICIgc3lzLmV4aXQoMilcbiIKICAgICJzLnNldHRpbWVvdXQoTm9uZSlcbiIK\"}, {\"old\": \"ICAgICIgYj1zeXMuc3RkaW4uYnVmZmVyLnJlYWQoNDA5NilcbiIKICAgICIgaWYgbm90IGI6IGJyZWFrXG4iCiAgICAiIHMuc2VuZGFsbChiKVxuIgo=\", \"new\": \"ICAgICIgYmVyZWl0LF8sXz1zZWxlY3Quc2VsZWN0KFtzeXMuc3RkaW4uYnVmZmVyXSxbXSxbXSwxLjApXG4iCiAgICAiIGlmIGJlcmVpdDpcbiIKICAgICIgIGJsb2NrPXN5cy5zdGRpbi5idWZmZXIucmVhZCg0MDk2KVxuIgogICAgIiAgaWYgbm90IGJsb2NrOiBicmVha1xuIgogICAgIiAgcy5zZW5kYWxsKGJsb2NrKVxuIgogICAgIiBlbHNlOlxuIgogICAgIiAgdHJ5OiBzLnNlbmRhbGwoc3RpbGxlKVxuIgogICAgIiAgZXhjZXB0IE9TRXJyb3I6IHN5cy5leGl0KDMpXG4iCg==\"}, {\"old\": \"ZGVmIGljZWNhc3Rfc2ljaGVyKGJhc2UpOgogICAgIiIiWnVicmluZ2VyIGVyc3Qgd2VubiBJY2VjYXN0IGFudHdvcnRldC4gUGFzc3dvcnQgbnVyIGF1cyBkZXIgRGF0ZWksIG5pZSBpbiBhcmd2LiIiIgogICAgcHcgPSBvcy5wYXRoLmpvaW4oYmFzZSwgImljZWNhc3QtZmx1Z2Z1bmsucHciKQogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKHB3KSBvciBub3QgX3BvcnRfYXVmKCIxMjcuMC4wLjEiLCA4MDAwKToKICAgICAgICByZXR1cm4KICAgIGRhdGVpID0gbGl2ZV9tcDMoYmFzZSkKICAgIGlmIG5vdCBkYXRlaSBvciBub3Qgc2h1dGlsLndoaWNoKCJmZm1wZWciKSBvciBub3Qgc2h1dGlsLndoaWNoKCJ0YWlsIik6CiAgICAgICAgcmV0dXJuCiAgICBwaWRfcGZhZCA9IG9zLnBhdGguam9pbihiYXNlLCAiZmx1Z2Z1bmstaWNlY2FzdC5waWQiKQogICAgbWVya19wZmFkID0gb3MucGF0aC5qb2luKGJhc2UsICJmbHVnZnVuay1pY2VjYXN0LmRhdGVpIikK\", \"new\": \"ZGVmIF9tb3VudF9vaygpOgogICAgIiIiTnVyIGRpZSBTdGF0dXN6ZWlsZS4gS2VpbiBTdHJlYW0tRG93bmxvYWQuIiIiCiAgICBpbXBvcnQgc29ja2V0Cg==\"}, {\"old\": \"ICAgICAgICBwaWQgPSBpbnQob3BlbihwaWRfcGZhZCwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpLnN0cmlwKCkpCiAgICAgICAgbWVyayA9IG9wZW4obWVya19wZmFkLCBlbmNvZGluZz0idXRmLTgiKS5yZWFkKCkuc3RyaXAoKQo=\", \"new\": \"ICAgICAgICBzb2NrID0gc29ja2V0LmNyZWF0ZV9jb25uZWN0aW9uKCgiMTI3LjAuMC4xIiwgODAwMCksIDEpCiAgICAgICAgc29jay5zZXR0aW1lb3V0KDIpCiAgICAgICAgc29jay5zZW5kYWxsKGIiSEVBRCAvZmx1Z2Z1bmsgSFRUUC8xLjBcclxuSG9zdDogMTI3LjAuMC4xXHJcbkNvbm5lY3Rpb246IGNsb3NlXHJcblxyXG4iKQogICAgICAgIHplaWxlID0gYiIiCiAgICAgICAgd2hpbGUgYiJcbiIgbm90IGluIHplaWxlIGFuZCBsZW4oemVpbGUpIDwgODA6CiAgICAgICAgICAgIHRlaWwgPSBzb2NrLnJlY3YoNDApCiAgICAgICAgICAgIGlmIG5vdCB0ZWlsOgogICAgICAgICAgICAgICAgYnJlYWsKICAgICAgICAgICAgemVpbGUgKz0gdGVpbAogICAgICAgIHNvY2suY2xvc2UoKQogICAgICAgIHJldHVybiBiIjIwMCIgaW4gemVpbGVbOjI0XQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcmV0dXJuIEZhbHNlCgoKZGVmIF9pY2Vfc3RhbmQoYmFzZSk6CiAgICB0cnk6CiAgICAgICAgdGVpbGUgPSBvcGVuKG9zLnBhdGguam9pbihiYXNlLCAiZmx1Z2Z1bmstaWNlY2FzdC5waWQiKSwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpLnNwbGl0KCkKICAgICAgICBwaWRzID0gW2ludCh4KSBmb3IgeCBpbiB0ZWlsZVs6M11dCiAgICAgICAgZGF0ZWkgPSB0ZWlsZVszXSBpZiBsZW4odGVpbGUpID4gMyBlbHNlICIiCiAgICAgICAgc2VpdCA9IGZsb2F0KHRlaWxlWzRdKSBpZiBsZW4odGVpbGUpID4gNCBlbHNlIDAuMAogICAgICAgIHJldHVybiBwaWRzLCBkYXRlaSwgc2VpdAo=\"}, {\"old\": \"ICAgICAgICBwaWQsIG1lcmsgPSAwLCAiIgogICAgaWYgcGlkIGFuZCBtZXJrID09IGRhdGVpOgo=\", \"new\": \"ICAgICAgICByZXR1cm4gW10sICIiLCAwLjAKCgpkZWYgX3BpZF9sZWJ0KHBpZCk6CiAgICB0cnk6CiAgICAgICAgb3Mua2lsbChpbnQocGlkKSwgMCkKICAgICAgICByZXR1cm4gVHJ1ZQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcmV0dXJuIEZhbHNlCgoKZGVmIF9pY2VfYXVzKHBpZHMpOgogICAgZm9yIHBpZCBpbiBwaWRzOgo=\"}, {\"old\": \"ICAgICAgICAgICAgb3Mua2lsbChwaWQsIDApCiAgICAgICAgICAgIHJldHVybgo=\", \"new\": \"ICAgICAgICAgICAgb3Mua2lsbChpbnQocGlkKSwgMTUpCg==\"}, {\"old\": \"ICAgIGlmIHBpZDoKICAgICAgICB0cnk6CiAgICAgICAgICAgIG9zLmtpbGwocGlkLCAxNSkKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcGFzcwogICAgdGFpbCA9IHN1YnByb2Nlc3MuUG9wZW4oWyJ0YWlsIiwgIi1GIiwgIi1jIiwgIiswIiwgZGF0ZWldLCBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGFydF9uZXdfc2Vzc2lvbj1UcnVlKQogICAgZmYgPSBzdWJwcm9jZXNzLlBvcGVuKAogICAgICAgIFsiZmZtcGVnIiwgIi1sb2dsZXZlbCIsICJlcnJvciIsICItZmZsYWdzIiwgIm5vYnVmZmVyIiwgIi1mIiwgIm1wMyIsICItaSIsICJwaXBlOjAiLAogICAgICAgICAiLWMiLCAiY29weSIsICItZiIsICJtcDMiLCAicGlwZToxIl0sCiAgICAgICAgc3RkaW49dGFpbC5zdGRvdXQsIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsCiAgICApCiAgICBpZiB0YWlsLnN0ZG91dDoKICAgICAgICB0YWlsLnN0ZG91dC5jbG9zZSgpCg==\", \"new\": \"CgpkZWYgaWNlY2FzdF9zaWNoZXIoYmFzZSk6CiAgICAiIiJTdGlsbGUgaW4gUGF1c2VuLCBOZXVzdGFydCB3ZW5uIGRlciBSZWxheSB0b3QgaXN0IG9kZXIgZGVyIE1vdW50IG5pY2h0IDIwMCBsaWVmZXJ0LiIiIgogICAgcHcgPSBvcy5wYXRoLmpvaW4oYmFzZSwgImljZWNhc3QtZmx1Z2Z1bmsucHciKQogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKHB3KSBvciBub3QgX3BvcnRfYXVmKCIxMjcuMC4wLjEiLCA4MDAwKSBvciBub3Qgc2h1dGlsLndoaWNoKCJmZm1wZWciKToKICAgICAgICByZXR1cm4KICAgIGRhdGVpID0gbGl2ZV9tcDMoYmFzZSkgb3IgIiIKICAgIHBpZHMsIG1lcmssIHNlaXQgPSBfaWNlX3N0YW5kKGJhc2UpCiAgICByZWxheV9sZWJ0ID0gYm9vbChwaWRzKSBhbmQgX3BpZF9sZWJ0KHBpZHNbMF0pCiAgICBpZiByZWxheV9sZWJ0IGFuZCBtZXJrID09IGRhdGVpIGFuZCAodGltZS50aW1lKCkgLSBzZWl0IDwgOCBvciBfbW91bnRfb2soKSk6CiAgICAgICAgcmV0dXJuCiAgICBfaWNlX2F1cyhwaWRzKQogICAgaWYgZGF0ZWkgYW5kIHNodXRpbC53aGljaCgidGFpbCIpOgogICAgICAgIHRhaWwgPSBzdWJwcm9jZXNzLlBvcGVuKAogICAgICAgICAgICBbInRhaWwiLCAiLUYiLCAiLWMiLCAiKzAiLCBkYXRlaV0sCiAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0YXJ0X25ld19zZXNzaW9uPVRydWUsCiAgICAgICAgKQogICAgICAgIGZmID0gc3VicHJvY2Vzcy5Qb3BlbigKICAgICAgICAgICAgWyJmZm1wZWciLCAiLWxvZ2xldmVsIiwgImVycm9yIiwgIi1mZmxhZ3MiLCAibm9idWZmZXIiLCAiLWYiLCAibXAzIiwgIi1pIiwgInBpcGU6MCIsCiAgICAgICAgICAgICAiLWMiLCAiY29weSIsICItZiIsICJtcDMiLCAicGlwZToxIl0sCiAgICAgICAgICAgIHN0ZGluPXRhaWwuc3Rkb3V0LCBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLAogICAgICAgICkKICAgICAgICBpZiB0YWlsLnN0ZG91dDoKICAgICAgICAgICAgdGFpbC5zdGRvdXQuY2xvc2UoKQogICAgICAgIHF1ZWxsZSA9IGZmLnN0ZG91dAogICAgICAgIHRhaWxfcGlkLCBmZl9waWQgPSB0YWlsLnBpZCwgZmYucGlkCiAgICBlbHNlOgogICAgICAgIHF1ZWxsZSA9IHN1YnByb2Nlc3MuREVWTlVMTAogICAgICAgIHRhaWxfcGlkLCBmZl9waWQgPSAwLCAwCiAgICAgICAgZmYgPSBOb25lCg==\"}, {\"old\": \"ICAgICAgICBzdGRpbj1mZi5zdGRvdXQsIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsCg==\", \"new\": \"ICAgICAgICBzdGRpbj1xdWVsbGUsIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsCg==\"}, {\"old\": \"ICAgIGlmIGZmLnN0ZG91dDoK\", \"new\": \"ICAgIGlmIGZmIGlzIG5vdCBOb25lIGFuZCBmZi5zdGRvdXQ6Cg==\"}, {\"old\": \"ICAgICAgICB3aXRoIG9wZW4ocGlkX3BmYWQsICJ3IiwgZW5jb2Rpbmc9InV0Zi04IikgYXMgaGFuZGxlOgogICAgICAgICAgICBoYW5kbGUud3JpdGUoc3RyKHJlbGF5LnBpZCkpCiAgICAgICAgd2l0aCBvcGVuKG1lcmtfcGZhZCwgInciLCBlbmNvZGluZz0idXRmLTgiKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIGhhbmRsZS53cml0ZShkYXRlaSkK\", \"new\": \"ICAgICAgICB3aXRoIG9wZW4ob3MucGF0aC5qb2luKGJhc2UsICJmbHVnZnVuay1pY2VjYXN0LnBpZCIpLCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGhhbmRsZToKICAgICAgICAgICAgaGFuZGxlLndyaXRlKCIlcyAlcyAlcyAlcyAlLjBmXG4iICUgKHJlbGF5LnBpZCwgdGFpbF9waWQsIGZmX3BpZCwgZGF0ZWksIHRpbWUudGltZSgpKSkK\"}, {\"old\": \"ICAgIGFzc2VydCAiaWNlY2FzdDovL3NvdXJjZToiIG5vdCBpbiBfSUNFX1JFTEFZCg==\", \"new\": \"ICAgIGFzc2VydCAiaWNlY2FzdDovL3NvdXJjZToiIG5vdCBpbiBfSUNFX1JFTEFZIGFuZCAic2VsZWN0LnNlbGVjdCIgaW4gX0lDRV9SRUxBWSBhbmQgIjIwMCIgaW4gX0lDRV9SRUxBWQogICAgYXNzZXJ0IGxlbihieXRlcy5mcm9taGV4KF9TVElMTEVfTVAzKSkgPT0gMTA0Cg==\"}]}"

def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--ordner", default="/home/fmg/prepper-dashboard")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--kein-neustart", action="store_true")
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--fullcheck-hash", default=FC_FEST)
    args = p.parse_args(argv)
    if args.selftest:
        print(selftest())
        return 0
    return apply_dir(args.ordner, args.dry_run, args.kein_neustart, fullcheck_hash=args.fullcheck_hash or None)

if __name__ == "__main__":
    raise SystemExit(main())
