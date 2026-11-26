# -*- coding: utf-8 -*-
import argparse, base64, hashlib, json, os, re, secrets, shutil, subprocess, sys, tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

FEST = {
    "dashboard.py": ("f3ee3b89bbd79aa9", 1390250),
    "flugfunk.py": ("43875791cf44f989", 89919),
    "prepper_sdr.py": ("6989a5dbc9523a37", 793370),
    "prepper_log.py": ("f089377b322789e3", 17593),
    "pushover_push.py": ("3916f7d880b13569", 12237),
}
FC_FEST = "72cddd22584af1efb1fe360424dfb981eddb641938e8f819842d4a893b706760"
FC_SHA16 = "2d4554deef01c959"
FC_BYTES = 98995
SOLL = {
    "FC_DASH_SHA16": "f3ee3b89bbd79aa9",
    "FC_DASH_BYTES": "1390250",
    "FC_PUSH_SHA16": "3916f7d880b13569",
    "FC_PUSH_BYTES": "12237",
}
FULL = Path("/home/fmg/fullcheck.sh")
ALT = """  if [[ "$HTTP_BODY" == *'"metar_aktuell": true'* && "$HTTP_BODY" == *'"qnh"'* && "$HTTP_BODY" == *'"sicht"'* ]]; then ok "Wetterfelder" "QNH Wind Sicht Piste Kategorie"
  else warn "Wetterfelder" "METAR unvollstaendig" "aviationweather oder NOAA"; fi
  if [[ "$HTTP_BODY" == *'"quelle"'* ]]; then ok "ADS-B-Quelle" "Feeder nur gelesen"
  else fail "ADS-B-Quelle" "fehlt" "tar1090 aircraft.json"; fi
  if [[ "$HTTP_BODY" != *'look one lima'* && "$HTTP_BODY" != *'125355'* ]]; then ok "Erkennung" "kein Unsinn"
  else fail "Erkennung" "Unsinn sichtbar" "Confidence-Filter"; fi
  if [[ "$HTTP_BODY" == *'"zahl"'* ]]; then ok "Kanalzaehler" "Spruch je Kanal"
  else fail "Kanalzaehler" "fehlt" "Zuordnung"; fi
"""
NEU = """  http_get "$BASEURL/api/flugfunk" 8
  if [[ "$HTTP_CODE" == 200 && "$HTTP_BODY" == *'"qnh":'* && "$HTTP_BODY" != *'"qnh": ""'* && "$HTTP_BODY" != *'"qnh":null'* && "$HTTP_BODY" != *'"sicht": ""'* ]]; then ok "Wetterfelder" "QNH Wind Sicht Kategorie"
  else warn "Wetterfelder" "METAR unvollstaendig" "aviationweather oder NOAA"; fi
  if [[ "$HTTP_CODE" == 200 && "$HTTP_BODY" == *'"punkte":'* && "$HTTP_BODY" != *'keine ADS-B-Ziele'* ]]; then ok "ADS-B-Quelle" "punkte vorhanden, aktiv nur bei Funkspruch"
  else fail "ADS-B-Quelle" "keine punkte" "tar1090 nur lesen"; fi
  if [[ "$HTTP_BODY" != *'look one lima'* && "$HTTP_BODY" != *'125355'* ]]; then ok "Erkennung" "kein Unsinn"
  else fail "Erkennung" "Unsinn sichtbar" "Confidence-Filter"; fi
  if [[ "$HTTP_BODY" == *'"zahl":'* ]]; then ok "Kanalzaehler" "Spruch je Kanal"
  else fail "Kanalzaehler" "fehlt" "Zuordnung"; fi
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

def soll_setzen(text):
    for name, wert in SOLL.items():
        muster = r"(\$\{%s:-)[^}\n]+" % name
        if not re.search(muster, text):
            raise RuntimeError(name)
        text, n = re.subn(muster, r"\g<1>" + wert, text, count=1)
        if n != 1:
            raise RuntimeError(name)
    return text

def fullcheck_neu(text):
    if "elDBYTES" in text:
        raise RuntimeError("elif")
    if "flugfunk-7b: API" in text and 'FC_VERSION="2.7"' in text:
        return text
    if 'FC_VERSION="2.6"' not in text and 'FC_VERSION="2.7"' not in text:
        raise RuntimeError("version")
    neu = text.replace('FC_VERSION="2.6"', 'FC_VERSION="2.7"', 1)
    if ALT not in neu:
        raise RuntimeError("anker")
    neu = neu.replace(ALT, NEU, 1)
    neu = soll_setzen(neu)
    if "flugfunk-7b: API" not in neu:
        neu = neu.replace("  # flugfunk-7: Mount", "  # flugfunk-7b: API zuerst, dann Mount\n  # flugfunk-7: Mount", 1)
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

def icecast_dateien(ordner):
    geheim = secrets.token_hex(18)
    basis = Path(ordner)
    (basis / "bin").mkdir(exist_ok=True)
    schreiben(basis / "icecast-flugfunk.pw", geheim + "\n", "flugfunk7b", 0o600)
    xml = (
        "<icecast><hostname>127.0.0.1</hostname>"
        "<listen-socket><port>8000</port><bind-address>127.0.0.1</bind-address></listen-socket>"
        "<authentication><source-password>%s</source-password><relay-password>%s</relay-password>"
        "<admin-user>admin</admin-user><admin-password>%s</admin-password></authentication>"
        "<mount><mount-name>/flugfunk</mount-name></mount>"
        "<paths><logdir>/var/log/icecast2</logdir><webroot>/usr/share/icecast2/web</webroot>"
        "<adminroot>/usr/share/icecast2/admin</adminroot></paths></icecast>\n"
    ) % (geheim, geheim, geheim)
    schreiben(basis / "icecast-flugfunk.xml", xml, "flugfunk7b", 0o600)
    unit = """[Unit]
Description=Prepper Icecast Flugfunk
After=network.target

[Service]
Type=simple
User=icecast2
Group=icecast
ExecStart=/usr/bin/icecast2 -c /etc/icecast2/flugfunk.xml
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
"""
    schreiben(basis / "prepper-icecast.service", unit, "flugfunk7b", 0o644)
    skript = """#!/bin/sh
BASE="$1"
PW=$(cat "$BASE/icecast-flugfunk.pw")
LIVE=$(ls -1t "$BASE"/flugfunk-audio/live/live_*.mp3 2>/dev/null | head -n 1)
if [ -z "$LIVE" ]; then exit 0; fi
exec ffmpeg -loglevel error -re -i "$LIVE" -c copy -f mp3 "icecast://source:${PW}@127.0.0.1:8000/flugfunk"
"""
    schreiben(basis / "bin" / "flugfunk-icecast.sh", skript, "flugfunk7b", 0o700)
    print("Icecast-Unit prepper-icecast.service, User icecast2, Bind 127.0.0.1, Mount /flugfunk. Passwort nicht angezeigt.")
    return geheim

def unit_install(ordner):
    basis = Path(ordner)
    befehle = [
        ["sudo", "-n", "install", "-o", "icecast2", "-g", "icecast", "-m", "640", str(basis / "icecast-flugfunk.xml"), "/etc/icecast2/flugfunk.xml"],
        ["sudo", "-n", "cp", str(basis / "prepper-icecast.service"), "/etc/systemd/system/prepper-icecast.service"],
        ["sudo", "-n", "systemctl", "daemon-reload"],
        ["sudo", "-n", "systemctl", "enable", "--now", "prepper-icecast.service"],
    ]
    if str(ordner) != "/home/fmg/prepper-dashboard":
        print("Testordner, kein systemctl fuer Icecast")
        return
    for cmd in befehle:
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print("STOP Icecast-Unit, Befehl erneut: " + " ".join(cmd))
            return
    print("prepper-icecast.service aktiv, kein Eingriff in die Firewall")

def apply_dir(ordner, dry, kein, jetzt=None, hashcheck=True, fullcheck_hash=None, full_pfad=None):
    print("aktiv:false ist korrekt, solange kein Luftfahrzeug gerade auf dem gehoerten Kanal spricht.")
    print("rtl_airband blieb nur etwa 2 Minuten, weil jede Frequenzgruppe den Prozess neu startete. Dieselbe Gruppe bleibt jetzt 10 Minuten, die Live-Datei traegt die Berliner Stunde.")
    print("prepper-sdr, prepper-dashboard und prepper-icecast muessen neu starten. Ein Pi-Neustart wird nicht ausgefuehrt.")
    ordner = Path(ordner)
    roh = laden()
    ziel = {}
    paare = {"flugfunk.py": roh["flugfunk"], "prepper_sdr.py": roh["sdr"]}
    for name, fest in FEST.items():
        pfad = ordner / name
        if not pfad.is_file():
            if not hashcheck and name in ("dashboard.py", "prepper_log.py", "pushover_push.py"):
                continue
            print("STOP: %s fehlt" % pfad)
            return 2
        data = pfad.read_bytes()
        print("%s sha16 %s bytes %d" % (name, sha(data)[:16], len(data)))
        if hashcheck and (not sha(data).startswith(fest[0]) or len(data) != fest[1]):
            print("STOP: %s ist nicht der Stand nach flugfunk-7" % name)
            print("Live-Hash sha256 %s" % sha(data))
            return 2
        neu = data
        if name in paare:
            try:
                for paar in paare[name]:
                    neu = tausch(neu, base64.b64decode(paar["old"]), base64.b64decode(paar["new"]))
            except RuntimeError:
                print("STOP: Stelle in %s unbekannt. Nichts geschrieben." % name)
                return 2
            if hashcheck:
                try:
                    compile(neu, name, "exec")
                except SyntaxError:
                    print("STOP: %s kompiliert nicht. Nichts geschrieben." % name)
                    return 2
        ziel[name] = (pfad, data, neu)
        if neu != data:
            print("%s endstand sha16 %s bytes %d" % (name, sha(neu)[:16], len(neu)))
    fc_pfad = Path(full_pfad) if full_pfad else FULL
    if not fc_pfad.is_file():
        print("STOP: fullcheck.sh fehlt")
        return 2
    fc_alt = fc_pfad.read_bytes()
    print("fullcheck.sh sha16 %s bytes %d" % (sha(fc_alt)[:16], len(fc_alt)))
    print("fullcheck.sh sha256 %s" % sha(fc_alt))
    if hashcheck and sha(fc_alt) != FC_FEST:
        print("STOP: fullcheck ist nicht 2d4554de plus die Sollwerte f3ee3b89bbd79aa9/1390250")
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
    gleich = all(alt == neu for _p, alt, neu in ziel.values()) and fc_alt.decode("utf-8") == fc
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
    for pfad, alt, neu in ziel.values():
        if alt != neu:
            sichern(pfad, alt, "flugfunk7b")
            schreiben(pfad, neu, "flugfunk7b")
    sichern(fc_pfad, fc_alt, "flugfunk7b")
    schreiben(fc_pfad, fc.encode(), "flugfunk7b")
    icecast_dateien(ordner)
    print("geschrieben. dashboard.py, prepper_log.py und pushover_push.py unveraendert.")
    if kein:
        print("kein Neustart. prepper-sdr, prepper-dashboard und prepper-icecast spaeter starten.")
        return 0
    if str(ordner) != "/home/fmg/prepper-dashboard":
        print("Testordner, kein systemctl")
        return 0
    unit_install(ordner)
    for dienst in ("prepper-dashboard.service", "prepper-sdr.service"):
        subprocess.run(["systemctl", "restart", dienst], check=False)
        print("Neustart %s" % dienst)
    return 0

FIX = """#!/bin/bash
# fullcheck.sh Basis flugfunk-7
FC_VERSION="2.6"
DASH_SHA16="${FC_DASH_SHA16:-57df9398bd5813bc}"
DASH_BYTES="${FC_DASH_BYTES:-1390064}"
PUSH_SHA16="${FC_PUSH_SHA16:-3916f7d880b13569}"
PUSH_BYTES="${FC_PUSH_BYTES:-12237}"
ok() { :; }
warn() { :; }
fail() { :; }
info() { :; }
APP="${APP:-/home/fmg/prepper-dashboard}"
MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo Pi)
if [[ "$DSH" == "$DASH_SHA16" ]]; then ok "dashboard.py sha16" "$DSH"
elif [[ "$DSH" == "alt" ]]; then ok "alt" "x"
else warn "dashboard.py sha16" "$DSH" "Soll"; fi
""" + ALT + """
  # flugfunk-7: Mount, Last, kein Hinweis bei gewolltem Rueckfall. Nur lesen.
  if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8000/flugfunk; then ok "Icecast /flugfunk" "Mount"
  elif ! command -v icecast2 >/dev/null 2>&1; then info "Icecast /flugfunk" "Paketschritt offen"
  else warn "Icecast /flugfunk" "Mount fehlt" "icecast2 -c icecast-flugfunk.xml"; fi
  # --- SDR-Watchdog (Datenlage der Sticks, nur lesen)
"""

def selftest():
    assert FEST["dashboard.py"] == ("f3ee3b89bbd79aa9", 1390250)
    assert FEST["flugfunk.py"][0] == "43875791cf44f989"
    assert FC_FEST == "72cddd22584af1efb1fe360424dfb981eddb641938e8f819842d4a893b706760"
    assert FC_SHA16 == "2d4554deef01c959" and FC_BYTES == 98995
    roh = laden()
    ordner = Path(tempfile.mkdtemp(prefix="flugfunk7b-"))
    try:
        for name, key in (("flugfunk.py", "flugfunk"), ("prepper_sdr.py", "sdr")):
            daten = b""
            for paar in roh[key]:
                daten += base64.b64decode(paar["old"]) + b"\n"
            (ordner / name).write_bytes(daten)
        fp = ordner / "fullcheck.sh"
        fp.write_text(FIX)
        vorher = fp.read_bytes()
        assert apply_dir(ordner, True, True, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp) == 0
        assert fp.read_bytes() == vorher
        von = datetime(2026, 11, 26, 20, 4, tzinfo=ZoneInfo("Europe/Berlin"))
        assert apply_dir(ordner, False, False, jetzt=von, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp) == 2
        assert fp.read_bytes() == vorher
        innen = datetime(2026, 11, 26, 20, 10, tzinfo=ZoneInfo("Europe/Berlin"))
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
        assert rc == 0, rc
        neu = fp.read_text()
        assert 'FC_VERSION="2.7"' in neu and "elDBYTES" not in neu and "punkte vorhanden" in neu and "Kanalzaehler" in neu
        assert "f3ee3b89bbd79aa9" in neu and "1390250" in neu
        assert bash_n(neu)[0]
        assert b"empfang_halten" in (ordner / "flugfunk.py").read_bytes()
        assert b"squelch" in (ordner / "prepper_sdr.py").read_bytes()
        unit = (ordner / "prepper-icecast.service").read_text()
        assert "User=icecast2" in unit and "127.0.0.1" in (ordner / "icecast-flugfunk.xml").read_text()
        pw = (ordner / "icecast-flugfunk.pw").read_text().strip()
        assert pw and pw not in text and oct((ordner / "icecast-flugfunk.pw").stat().st_mode & 0o777) == "0o600"
    finally:
        shutil.rmtree(ordner, ignore_errors=True)
    return "flugfunk-7b ok"

PAYLOAD_TEXT = "{\"flugfunk\": [{\"old\": \"RFdFTExfUyA9IDIwCg==\", \"new\": \"RFdFTExfUyA9IDIwCkhBTFRFX1MgPSA2MDAK\"}, {\"old\": \"ICAgICc8L2Rpdj48c2NyaXB0IGlkPSJmbHVnZnVuay1qcyI+JyArIF9KUyArICc8L3NjcmlwdD4nCikKCgo=\", \"new\": \"ICAgICc8L2Rpdj48c2NyaXB0IGlkPSJmbHVnZnVuay1qcyI+JyArIF9KUyArICc8L3NjcmlwdD4nCikKCgpkZWYgYmVybGluX3N0dW5kZShqZXR6dD1Ob25lKToKICAgIGZyb20gZGF0ZXRpbWUgaW1wb3J0IGRhdGV0aW1lCiAgICBmcm9tIHpvbmVpbmZvIGltcG9ydCBab25lSW5mbwogICAgamV0enQgPSBkYXRldGltZS5ub3coWm9uZUluZm8oIkV1cm9wZS9CZXJsaW4iKSkgaWYgamV0enQgaXMgTm9uZSBlbHNlIGpldHp0LmFzdGltZXpvbmUoWm9uZUluZm8oIkV1cm9wZS9CZXJsaW4iKSkKICAgIHJldHVybiBqZXR6dC5zdHJmdGltZSgiJVklbSVkXyVIIikKCgpkZWYgZW1wZmFuZ19oYWx0ZW4obGVidCwgZ2xlaWNoZSwgc3R1bmRlX2dsZWljaCwgc2VpdCwgamV0enQsIGhhbHRlPUhBTFRFX1MpOgogICAgIiIiR2xlaWNoZXIgS2FuYWwgdW5kIGdsZWljaGUgU3R1bmRlOiBydGxfYWlyYmFuZCBuaWNodCBuZXUgc3RhcnRlbi4iIiIKICAgIHRyeToKICAgICAgICByZXR1cm4gYm9vbChsZWJ0IGFuZCBnbGVpY2hlIGFuZCBzdHVuZGVfZ2xlaWNoIGFuZCBqZXR6dCAtIGZsb2F0KHNlaXQpIDwgZmxvYXQoaGFsdGUpKQogICAgZXhjZXB0IChUeXBlRXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAgIHJldHVybiBGYWxzZQoKCg==\"}, {\"old\": \"ICAgICAgICAgICAgemVpbGVuLmFwcGVuZCgnICAgICAgZmlsZW5hbWVfdGVtcGxhdGUgPSAibGl2ZSI7JykK\", \"new\": \"ICAgICAgICAgICAgemVpbGVuLmFwcGVuZCgnICAgICAgZmlsZW5hbWVfdGVtcGxhdGUgPSAibGl2ZV8lWSVtJWRfJUgubXAzIjsnKQo=\"}, {\"old\": \"ICAgIHNhdHogPSAiU3RpY2sgMyDCtyBGbHVnZnVuazogJXMiICUga29wZgo=\", \"new\": \"ICAgIHNhdHogPSBrb3BmIGlmIHN0cihrb3BmKS5zdGFydHN3aXRoKCgiRmx1Z2Z1bmsiLCAiU3RpY2sgMyIpKSBlbHNlICJTdGljayAzIMK3IEZsdWdmdW5rOiAlcyIgJSBrb3BmCg==\"}, {\"old\": \"ICAgICAgICAgICAgaWYgbWV0YXIgYW5kIG1ldGFyLmdldCgiYWt0dWVsbCIpOgo=\", \"new\": \"ICAgICAgICAgICAgaWYgbWV0YXIgYW5kIChtZXRhci5nZXQoImFrdHVlbGwiKSBvciBtZXRhci5nZXQoInFuaF9ocGEiKSk6Cg==\"}, {\"old\": \"ICAgICAgICAgICAgICAgICAgICAibWV0YXIiOiBUcnVlLCAibWV0YXJfdCI6IG1ldGFyLmdldCgidCIpLAo=\", \"new\": \"ICAgICAgICAgICAgICAgICAgICAia2F0ZWdvcmllIjogIlZGUiIgaWYgdmZyKG1ldGFyLmdldCgic2ljaHQiKSwgbWV0YXIuZ2V0KCJ3b2xrZW4iKSkgZWxzZSAiSUZSIiwKICAgICAgICAgICAgICAgICAgICAibWV0YXIiOiBib29sKG1ldGFyLmdldCgiYWt0dWVsbCIpKSwgIm1ldGFyX3QiOiBtZXRhci5nZXQoInQiKSwK\"}, {\"old\": \"ICAgICAgICBwbGFuID0gcmVpaGVuZm9sZ2UobGlzdGUpCg==\", \"new\": \"ICAgICAgICBwbGFuID0gcmVpaGVuZm9sZ2UobGlzdGUpCiAgICAgICAgamV0enQgPSB0aW1lLnRpbWUoKQogICAgICAgIHN0dW5kZSA9IGJlcmxpbl9zdHVuZGUoKQogICAgICAgIGxlYnQgPSBzZWxmLnByb2MgaXMgbm90IE5vbmUgYW5kIGdldGF0dHIoc2VsZi5wcm9jLCAicG9sbCIsIGxhbWJkYTogMSkoKSBpcyBOb25lCiAgICAgICAgaWYgZW1wZmFuZ19oYWx0ZW4obGVidCwgVHJ1ZSwgZ2V0YXR0cihzZWxmLCAiX3N0dW5kZSIsIE5vbmUpID09IHN0dW5kZSwgZ2V0YXR0cihzZWxmLCAiX3NlaXQiLCAwKSwgamV0enQpIGFuZCBkd2VsbCBpcyBOb25lOgogICAgICAgICAgICBzZWxmLnN0b3Aud2FpdChEV0VMTF9TKQogICAgICAgICAgICBzdGF0dXNfc2NocmVpYmVuKGJhc2UsIHsKICAgICAgICAgICAgICAgICJsYWV1ZnQiOiBUcnVlLCAiZmVobGVyIjogTm9uZSwgImZyZXFfaHoiOiAoZ2V0YXR0cihzZWxmLCAiX2dydXBwZSIsIGxpc3RlWzBdKSBvciBsaXN0ZVswXSlbMF1bMF0sCiAgICAgICAgICAgICAgICAic3RlbGxlIjogImxpdmUiLCAidCI6IGludChqZXR6dCksCiAgICAgICAgICAgIH0pCiAgICAgICAgICAgIHNlbGYuZWluc2FtbWVsbihiYXNlLCBnZXRhdHRyKHNlbGYsICJfZ3J1cHBlIiwgbGlzdGVbMF0pLCB0aW1lLnRpbWUoKSwgc3RhYmlsPUZhbHNlKQogICAgICAgICAgICByZXR1cm4gImhhbHRlIgo=\"}, {\"old\": \"ICAgICAgICBzZWxmLmluZGV4ICs9IDEK\", \"new\": \"ICAgICAgICBzZWxmLmluZGV4ICs9IDEKICAgICAgICBzZWxmLl9zZWl0LCBzZWxmLl9zdHVuZGUsIHNlbGYuX2dydXBwZSA9IGpldHp0LCBzdHVuZGUsIGdydXBwZQo=\"}, {\"old\": \"ICAgICAgICBpZiBzcGF3biBpcyBOb25lOgo=\", \"new\": \"ICAgICAgICBpZiBzcGF3biBpcyBOb25lOgogICAgICAgICAgICB1bWdlYnVuZyA9IG9zLmVudmlyb24uY29weSgpCiAgICAgICAgICAgIHVtZ2VidW5nWyJUWiJdID0gIkV1cm9wZS9CZXJsaW4iCg==\"}, {\"old\": \"ICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLlBJUEUsIHN0YXJ0X25ld19zZXNzaW9uPVRydWUsCg==\", \"new\": \"ICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLlBJUEUsIHN0YXJ0X25ld19zZXNzaW9uPVRydWUsCiAgICAgICAgICAgICAgICBlbnY9dW1nZWJ1bmcsCg==\"}, {\"old\": \"ICAgIGFzc2VydCBrYW5hbF92b24oMTI4ODI1MTAwKSA9PSAxMjg4MjUwMDAK\", \"new\": \"ICAgIGFzc2VydCBrYW5hbF92b24oMTI4ODI1MTAwKSA9PSAxMjg4MjUwMDAKICAgIGFzc2VydCBlbXBmYW5nX2hhbHRlbihUcnVlLCBUcnVlLCBUcnVlLCAxMDAwLCAxMjAwKSBhbmQgbm90IGVtcGZhbmdfaGFsdGVuKFRydWUsIFRydWUsIEZhbHNlLCAxMDAwLCAxMjAwKQo=\"}], \"sdr\": [{\"old\": \"ICAgICAgICByZXR1cm4gYm9vbChpIGFuZCBpLmdldCgidG8iKSBhbmQgaS5nZXQoImZiX29rIikgaXMgVHJ1ZSBhbmQgbm93IC0gKGkuZ2V0KCJmYl90Iikgb3IgMCkgPD0gV0RfRVZJRF9TKQo=\", \"new\": \"ICAgICAgICBmcmlzY2ggPSBib29sKGkgYW5kIGkuZ2V0KCJmYl9vayIpIGlzIFRydWUgYW5kIG5vdyAtIChpLmdldCgiZmJfdCIpIG9yIDApIDw9IFdEX0VWSURfUykKICAgICAgICByZXR1cm4gYm9vbChmcmlzY2ggYW5kIChpLmdldCgidG8iKSBvciBzdHIoaS5nZXQoImNoIikgb3IgIiIpLnVwcGVyKCkgPT0gIjVDIikpCg==\"}, {\"old\": \"ICAgIGxldHp0ZSwgYXJ0ID0gc3RhYmlsX2xldHp0ZShwbCwgbm93KQo=\", \"new\": \"ICAgIGxldHp0ZSwgYXJ0ID0gc3RhYmlsX2xldHp0ZShwbCwgbm93KQogICAgaWYgYXJ0ID09ICJzcXVlbGNoIjoKICAgICAgICByZXR1cm4gTm9uZQo=\"}, {\"old\": \"UGxhbm5lci5zdGFydCA9IF9mZjdfc3RhcnQKCg==\", \"new\": \"UGxhbm5lci5zdGFydCA9IF9mZjdfc3RhcnQKCl9mZjdiX29yaWdfZGFiID0gUGxhbm5lci5kYWJfbGlzdApfZmY3Yl9vcmlnX2JjID0gUGxhbm5lci5iY19xdWV1ZQoKCmRlZiBfZmY3Yl9kYWJfbGlzdChzZWxmKToKICAgIHYgPSBfZmY3Yl9vcmlnX2RhYihzZWxmKQogICAgdHJ5OgogICAgICAgIGEgPSBfYWlyX3BsKHNlbGYpCiAgICAgICAgaWYgYSBhbmQgYS5nZXQoInJvbGUiKSA9PSAiNUMiIGFuZCAiMTBDIiBub3QgaW4gW3N0cih4KSBmb3IgeCBpbiB2XToKICAgICAgICAgICAgdiA9IGxpc3QodikgKyBbIjEwQyJdCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKICAgIHJldHVybiB2CgoKZGVmIF9mZjdiX2JjX3F1ZXVlKHNlbGYpOgogICAgIiIiU3RpY2sgbWl0IFJvbGxlIDVDOiAxMEMgaXN0IGRlciBIYXVwdGthbmFsLCBzb2JhbGQgMTBDIFN5bmMgaGF0IHVuZCA1QyBuaWNodC4iIiIKICAgIHEgPSBfZmY3Yl9vcmlnX2JjKHNlbGYpCiAgICB0cnk6CiAgICAgICAgYSA9IF9haXJfcGwoc2VsZikKICAgICAgICBpZiBub3QgYSBvciBhLmdldCgicm9sZSIpICE9ICI1QyI6CiAgICAgICAgICAgIHJldHVybiBxCiAgICAgICAgZGFiID0gKHNlbGYuc2JjLmQuZ2V0KCJkYWIiKSBvciB7fSkgaWYgZ2V0YXR0cihzZWxmLCAic2JjIiwgTm9uZSkgZWxzZSB7fQogICAgICAgIGlmIChkYWIuZ2V0KCIxMEMiKSBvciB7fSkuZ2V0KCJyeCIpIGlzIFRydWUgYW5kIChkYWIuZ2V0KCI1QyIpIG9yIHt9KS5nZXQoInJ4IikgaXMgbm90IFRydWU6CiAgICAgICAgICAgIGxzdCA9IFtzdHIoeCkgZm9yIHggaW4gc2VsZi5kYWJfbGlzdCgpXQogICAgICAgICAgICBpZiAiMTBDIiBpbiBsc3Q6CiAgICAgICAgICAgICAgICByZXR1cm4gWygiZGFiOiVkIiAlIGxzdC5pbmRleCgiMTBDIiksIGZsb2F0KHNlbGYuY2ZnLmdldCgiZGFiX3MiKSBvciA2MCkpXQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4gcQogICAgcmV0dXJuIHEKCgpQbGFubmVyLmRhYl9saXN0ID0gX2ZmN2JfZGFiX2xpc3QKUGxhbm5lci5iY19xdWV1ZSA9IF9mZjdiX2JjX3F1ZXVlCgo=\"}]}"

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
