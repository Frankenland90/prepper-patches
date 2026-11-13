#!/usr/bin/env python3
# Entwarnung: kein Fehlalarm beim Start, OB nach OL zuverlaessig, Journal ohne Schluessel.
# Basis: Stand nach apply-usv-ugdsl-akku (PR 22). Kein pip, kein apt.
from __future__ import annotations
import base64, hashlib, json, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
DATEIEN = ("dashboard.py", "pushover_push.py")
PSH = ("25ec22d43a152a9160499f9b7fd962c2e9689329116a50b08f24f22b1a4de413", 11299)
MARKER = b"_PSH_ARM"

def load():
    raw = PAYLOAD if isinstance(PAYLOAD, dict) else json.loads(PAYLOAD)
    return {name: [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw[name]] for name in DATEIEN}

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def basis_ok(name, data: bytes) -> bool:
    if b"KG-DSL" in data:
        return False
    if name == "pushover_push.py":
        return sha(data) == PSH[0] and len(data) == PSH[1]
    if name == "dashboard.py":
        return b"_psh_usv_kante" in data and b"UG-DSL" in data and MARKER not in data
    return False

def fenster(now=None):
    from zoneinfo import ZoneInfo
    jetzt = now or datetime.now(ZoneInfo("Europe/Berlin"))
    m = jetzt.minute
    return (not (m >= 45 or m <= 4)), "Berlin Minute %02d" % m

def schreiben(path: Path, data: bytes):
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    tmp = path.with_name("." + path.name + ".tmp-ent")
    if tmp.exists():
        raise RuntimeError("temporaere Datei existiert")
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

def sichern(path: Path, data: bytes):
    stempel = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S")
    alt = sorted(path.parent.glob(path.name + ".bak-ent-*"))
    bak = path.with_name(path.name + ".bak-ent-" + stempel)
    shutil.copy2(path, bak)
    if bak.read_bytes() != data:
        bak.unlink()
        raise RuntimeError("Sicherung weicht ab")
    for alt_pfad in alt[:-2]:
        try:
            alt_pfad.unlink()
        except OSError:
            pass

def verwandle(data, pairs):
    if MARKER in data and all(data.count(neu) == 1 for _, neu in pairs):
        return data
    neu_data = data
    for old, neu in pairs:
        if neu_data.count(neu) == 1 and neu_data.count(old) == 0:
            continue
        if neu_data.count(old) != 1 or neu_data.count(neu) != 0:
            raise RuntimeError("Stelle")
        vor = neu_data
        neu_data = neu_data.replace(old, neu, 1)
        if neu_data.replace(neu, b"", 1) != vor.replace(old, b"", 1):
            raise RuntimeError("ausserhalb")
    if MARKER not in neu_data and b"edge=edge" not in neu_data and b"edge=" not in neu_data:
        raise RuntimeError("Marker")
    return neu_data

def apply_dir(ordner: Path, dry: bool, kein: bool) -> int:
    paare = load()
    for name in DATEIEN:
        pfad = ordner / name
        if pfad.is_symlink() or not pfad.is_file():
            print("STOP: %s fehlt" % name)
            return 2
    blobs = {name: (ordner / name).read_bytes() for name in DATEIEN}
    for name, data in blobs.items():
        print("%s sha16 %s" % (name, sha(data)[:16]))
    ziel = {}
    for name in DATEIEN:
        try:
            ziel[name] = verwandle(blobs[name], paare[name])
        except RuntimeError:
            print("STOP: %s Stelle unbekannt" % name)
            return 2
    if all(ziel[name] == blobs[name] for name in DATEIEN):
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    for name in DATEIEN:
        if ziel[name] == blobs[name]:
            continue
        if not basis_ok(name, blobs[name]):
            print("STOP: %s %s ist nicht die Basis" % (name, sha(blobs[name])[:16]))
            return 2
    for name in DATEIEN:
        try:
            compile(ziel[name], name, "exec")
        except SyntaxError as exc:
            print("STOP: Syntax %s %s" % (name, exc.lineno))
            return 2
    if b"usv_eg" not in ziel["dashboard.py"] or b"KG-DSL" in ziel["dashboard.py"]:
        print("STOP: Name oder Schluesselquelle veraendert")
        return 2
    frei, meldung = fenster()
    print(meldung)
    if not frei and not dry:
        print("STOP: Neustart-Sperre Minute 45-59 und 00-04 Berlin. Nichts geschrieben.")
        return 2
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        return 0
    try:
        for name in DATEIEN:
            if ziel[name] == blobs[name]:
                continue
            sichern(ordner / name, blobs[name])
            schreiben(ordner / name, ziel[name])
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    print("geschrieben. Entwarnung nur nach Akkubetrieb in diesem Lauf. Journal ohne Schluessel.")
    if kein:
        print("Kein Neustart in dieser Pruefung.")
        return 0
    frei, meldung = fenster()
    print(meldung)
    if not frei:
        print("STOP: Datei ist neu, der Neustart bleibt in der Sperre aus.")
        return 2
    import subprocess
    subprocess.run(["systemctl", "restart", "prepper-dashboard.service"], check=False)
    print("Nur prepper-dashboard neu gestartet.")
    return 0

def selftest() -> int:
    assert fenster(datetime(2026, 11, 12, 12, 12))[0]
    assert not fenster(datetime(2026, 11, 12, 12, 45))[0]
    assert not fenster(datetime(2026, 11, 12, 12, 0))[0] and not fenster(datetime(2026, 11, 12, 12, 4))[0]
    assert basis_ok("pushover_push.py", b"x") is False
    assert basis_ok("dashboard.py", b"KG-DSL _psh_usv_kante UG-DSL") is False
    import tempfile
    ordner = Path(tempfile.mkdtemp(prefix="ent-apply-"))
    for name in DATEIEN:
        (ordner / name).write_bytes(b"UNBERUEHRT")
    vorher = {name: (ordner / name).read_bytes() for name in DATEIEN}
    assert apply_dir(ordner, False, True) == 2
    assert {name: (ordner / name).read_bytes() for name in DATEIEN} == vorher
    print("selftest ok")
    return 0

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

PAYLOAD = {"dashboard.py":[{"old":"X1BTSF9CQVRUID0geyJzcGl0eiI6IE5vbmUsICJlZyI6IE5vbmV9CgoKZGVmIF9wc2hfdXN2X2thbnRlKHNuYXApOgogICAgIiIiT0wgbmFjaCBPQiB1bmQgenVydWVjay4gS2VpbiBTdGFuZCBiZWltIFN0YXJ0LCBrZWluZSBNZWxkdW5nIGJlaSB2ZXJhbHRldGVuIFdlcnRlbi4iIiIKICAgIG91dCA9IFtdCiAgICBpZiBub3QgaXNpbnN0YW5jZShzbmFwLCBkaWN0KToKICAgICAgICByZXR1cm4gb3V0CiAgICBlZyA9IHNuYXAuZ2V0KCJlZyIpIGlmIGlzaW5zdGFuY2Uoc25hcC5nZXQoImVnIiksIGRpY3QpIGVsc2Uge30KICAgIGZvciBrZXksIG1vZGUsIG5hbWUgaW4gKCgic3BpdHoiLCBzbmFwLmdldCgibW9kZSIpLCAiU3BpdHpib2RlbiIpLCAoImVnIiwgZWcuZ2V0KCJtb2RlIiksICJVRy1EU0wiKSk6CiAgICAgICAgb24gPSBtb2RlIGluICgiQUtLVSIsICJBS0tVX1BSVUVGIikKICAgICAgICBvZmYgPSBtb2RlID09ICJORVRaIgogICAgICAgIHByZXYgPSBfUFNIX0JBVFQuZ2V0KGtleSkKICAgICAgICBpZiBwcmV2IGlzIE5vbmU6CiAgICAgICAgICAgIGlmIG9uIG9yIG9mZjoKICAgICAgICAgICAgICAgIF9QU0hfQkFUVFtrZXldID0gYm9vbChvbikKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiAobm90IHByZXYpIGFuZCBvbjoKICAgICAgICAgICAgb3V0LmFwcGVuZCgoInVzdl9lZyIgaWYga2V5ID09ICJlZyIgZWxzZSAidXN2X3NwaXR6IiwgIlVTViAlcyBBa2t1YmV0cmllYiIgJSBuYW1lKSkKICAgICAgICAgICAgX1BTSF9CQVRUW2tleV0gPSBUcnVlCiAgICAgICAgZWxpZiBwcmV2IGFuZCBvZmY6CiAgICAgICAgICAgIG91dC5hcHBlbmQoKCJ1c3ZfZWdfa2xhciIgaWYga2V5ID09ICJlZyIgZWxzZSAidXN2X3NwaXR6X2tsYXIiLCAiVVNWICVzIHdpZWRlciBhbSBOZXR6IiAlIG5hbWUpKQogICAgICAgICAgICBfUFNIX0JBVFRba2V5XSA9IEZhbHNlCiAgICByZXR1cm4gb3V0Cgo=","new":"X1BTSF9CQVRUID0geyJzcGl0eiI6IE5vbmUsICJlZyI6IE5vbmV9Cl9QU0hfQVJNID0geyJzcGl0eiI6IEZhbHNlLCAiZWciOiBGYWxzZX0KX1BTSF9FREdFID0gKCJ1c3ZfZWciLCAidXN2X3NwaXR6IiwgInVzdl9lZ19rbGFyIiwgInVzdl9zcGl0el9rbGFyIikKCgpkZWYgX3BzaF91c3ZfbGl2ZShtb2RlLCBzdGF0dXMsIHN0YWxlKToKICAgICIiIlRydWUgPSBBa2t1LCBGYWxzZSA9IE5ldHosIE5vbmUgPSBub2NoIGtlaW4gYmVsYXN0YmFyZXIgU3RhbmQuIHN0YXR1cyBPTCBnaWx0IGF1Y2ggb2huZSBNb2R1cyBORVRaLiIiIgogICAgdG9rcyA9IFt0IGZvciB0IGluIHN0cihzdGF0dXMgb3IgIiIpLnJlcGxhY2UoJyInLCAiICIpLnNwbGl0KCkgaWYgdF0KICAgIGlmIG1vZGUgaW4gKCJBS0tVIiwgIkFLS1VfUFJVRUYiKSBvciAoIk9CIiBpbiB0b2tzIGFuZCAiT0wiIG5vdCBpbiB0b2tzKToKICAgICAgICByZXR1cm4gVHJ1ZQogICAgaWYgbW9kZSBpbiAoIlZFUkFMVEVUIiwgIktFSU5FX0RBVEVOIiwgIldBUlRFIiwgIk5JQ0hUX1ZFUkJVTkRFTiIsICJVTkJFS0FOTlQiKSBvciBzdGFsZSBpcyBUcnVlOgogICAgICAgIHJldHVybiBOb25lCiAgICBpZiBtb2RlID09ICJORVRaIiBvciAoIk9MIiBpbiB0b2tzIGFuZCAiT0IiIG5vdCBpbiB0b2tzKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHJldHVybiBOb25lCgoKZGVmIF9wc2hfdXN2X2ZpbGVfb24oZXZlbnRzKToKICAgICIiIkxldHp0ZXMgU3BpdHpib2Rlbi1FcmVpZ25pcyBhdXMgdXN2X3N0YXRlLmpzb24uIE5vbmUsIHdlbm4gZGFyYXVzIGtlaW4gQWtrdS1TdGFuZCBmb2xndC4iIiIKICAgIGlmIG5vdCBpc2luc3RhbmNlKGV2ZW50cywgbGlzdCk6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIGZvciBlIGluIHJldmVyc2VkKGV2ZW50cyk6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UoZSwgZGljdCk6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgZXYgPSBlLmdldCgiZXYiKQogICAgICAgIGlmIGV2IGluICgiTkVUWkFVU0ZBTEwiLCAiQUtLVV9TVEFSVCIpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgIGlmIGV2IGluICgiTkVUWl9aVVJVRUNLIiwgIlNFTEJTVFRFU1QiKToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICByZXR1cm4gTm9uZQoKCmRlZiBfcHNoX3Vzdl9rYW50ZShzbmFwLCBldmVudHM9Tm9uZSk6CiAgICAiIiJPTCBuYWNoIE9CIHVuZCB6dXJ1ZWNrLiBEZXIgZXJzdGUgYmVsYXN0YmFyZSBTdGFuZCwgYXVjaCBhdXMgdXN2X3N0YXRlLmpzb24sIGxvZXN0IG5pY2h0cyBhdXMuIiIiCiAgICBvdXQgPSBbXQogICAgaWYgbm90IGlzaW5zdGFuY2Uoc25hcCwgZGljdCk6CiAgICAgICAgcmV0dXJuIG91dAogICAgZWcgPSBzbmFwLmdldCgiZWciKSBpZiBpc2luc3RhbmNlKHNuYXAuZ2V0KCJlZyIpLCBkaWN0KSBlbHNlIHt9CiAgICByZW1lbWJlcmVkID0gX3BzaF91c3ZfZmlsZV9vbihldmVudHMpCiAgICByb3dzID0gKAogICAgICAgICgic3BpdHoiLCBzbmFwLmdldCgibW9kZSIpLCBzbmFwLmdldCgic3RhdHVzIiksIHNuYXAuZ2V0KCJzdGFsZSIpLCAiU3BpdHpib2RlbiIsIHJlbWVtYmVyZWQpLAogICAgICAgICgiZWciLCBlZy5nZXQoIm1vZGUiKSwgZWcuZ2V0KCJzdGF0dXMiKSwgZWcuZ2V0KCJzdGFsZSIpLCAiVUctRFNMIiwgTm9uZSksCiAgICApCiAgICBmb3Iga2V5LCBtb2RlLCBzdGF0dXMsIHN0YWxlLCBuYW1lLCBmcm9tX2ZpbGUgaW4gcm93czoKICAgICAgICBsaXZlID0gX3BzaF91c3ZfbGl2ZShtb2RlLCBzdGF0dXMsIHN0YWxlKQogICAgICAgIHByZXYgPSBfUFNIX0JBVFQuZ2V0KGtleSkKICAgICAgICBpZiBwcmV2IGlzIE5vbmU6CiAgICAgICAgICAgIGlmIGxpdmUgaXMgTm9uZSBhbmQgZnJvbV9maWxlIGlzIG5vdCBOb25lOgogICAgICAgICAgICAgICAgbGl2ZSA9IGZyb21fZmlsZQogICAgICAgICAgICBpZiBsaXZlIGlzIG5vdCBOb25lOgogICAgICAgICAgICAgICAgX1BTSF9CQVRUW2tleV0gPSBib29sKGxpdmUpCiAgICAgICAgICAgICAgICBfUFNIX0FSTVtrZXldID0gRmFsc2UKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBsaXZlIGlzIE5vbmU6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgc3JjID0gInVzdl9lZyIgaWYga2V5ID09ICJlZyIgZWxzZSAidXN2X3NwaXR6IgogICAgICAgIGlmIChub3QgcHJldikgYW5kIGxpdmU6CiAgICAgICAgICAgIG91dC5hcHBlbmQoKHNyYywgIlVTViAlcyBBa2t1YmV0cmllYiIgJSBuYW1lKSkKICAgICAgICAgICAgX1BTSF9CQVRUW2tleV0gPSBUcnVlCiAgICAgICAgICAgIF9QU0hfQVJNW2tleV0gPSBUcnVlCiAgICAgICAgZWxpZiBwcmV2IGFuZCBub3QgbGl2ZToKICAgICAgICAgICAgX1BTSF9CQVRUW2tleV0gPSBGYWxzZQogICAgICAgICAgICBpZiBfUFNIX0FSTS5nZXQoa2V5KToKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQoKHNyYyArICJfa2xhciIsICJVU1YgJXMgd2llZGVyIGFtIE5ldHoiICUgbmFtZSkpCiAgICAgICAgICAgICAgICBfUFNIX0FSTVtrZXldID0gRmFsc2UKICAgIHJldHVybiBvdXQKCgpkZWYgX3BzaF9lbWl0KHNyYywgdGV4dCk6CiAgICAiIiJFaW4gVmVyc3VjaCwgZWluIEVyZ2VibmlzLiBLZWluZSBTY2hsdWVzc2VsIGlucyBKb3VybmFsLiIiIgogICAgcHJpbnQoInB1c2hvdmVyS2FjaGVsOiBWZXJzdWNoICVzIiAlIHRleHQsIGZsdXNoPVRydWUpCiAgICBvayA9IF9QU0gucHVzaChzcmMsIHRleHQsIGVkZ2U9c3JjIGluIF9QU0hfRURHRSkKICAgIGlmIG5vdCBvazoKICAgICAgICBwcmludCgicHVzaG92ZXJLYWNoZWw6IG5pY2h0IGdlc2VuZGV0IChTcGVycmUpICVzIiAlIHRleHQsIGZsdXNoPVRydWUpCiAgICAgICAgcmV0dXJuCiAgICBiZWZvcmUgPSBfUFNILmVycm9ycwogICAgX1BTSC5mbHVzaCgpCiAgICBpZiBfUFNILmVycm9ycyA9PSBiZWZvcmU6CiAgICAgICAgcHJpbnQoInB1c2hvdmVyS2FjaGVsOiBnZXNlbmRldCAlcyIgJSB0ZXh0LCBmbHVzaD1UcnVlKQogICAgZWxzZToKICAgICAgICBwcmludCgicHVzaG92ZXJLYWNoZWw6IFZlcnNhbmQgZmVobGdlc2NobGFnZW4gJXMiICUgdGV4dCwgZmx1c2g9VHJ1ZSkKCg=="}, {"old":"ICAgICAgICAgICAgaWYgbWdyOgogICAgICAgICAgICAgICAgb3V0LmV4dGVuZChfcHNoX3Vzdl9rYW50ZShtZ3Iuc25hcHNob3QoKSkpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoK","new":"ICAgICAgICAgICAgaWYgbWdyOgogICAgICAgICAgICAgICAgZXZlbnRzID0gTm9uZQogICAgICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgIGV2ZW50cyA9IG1nci5jYWxjLnMuZ2V0KCJldmVudHMiKQogICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgICAgICBldmVudHMgPSBOb25lCiAgICAgICAgICAgICAgICBvdXQuZXh0ZW5kKF9wc2hfdXN2X2thbnRlKG1nci5zbmFwc2hvdCgpLCBldmVudHMpKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246Cg=="}, {"old":"ICAgICAgICAgICAgZm9yIHNyYywgdGV4dCBpbiBfcHNoX3NhbXBsZSgpOgogICAgICAgICAgICAgICAgX1BTSC5wdXNoKHNyYywgdGV4dCkKICAgICAgICAgICAgX1BTSC5mbHVzaCgpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoK","new":"ICAgICAgICAgICAgZm9yIHNyYywgdGV4dCBpbiBfcHNoX3NhbXBsZSgpOgogICAgICAgICAgICAgICAgX3BzaF9lbWl0KHNyYywgdGV4dCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgo="}, {"old":"ICAgIGFzc2VydCBfcHNoLnNlbGZ0ZXN0KCkuc3RhcnRzd2l0aCgicHVzaG92ZXJLYWNoZWwgb2siKQogICAgX1BTSF9CQVRUWyJzcGl0eiJdLCBfUFNIX0JBVFRbImVnIl0gPSBGYWxzZSwgRmFsc2UKICAgIGFzc2VydCBfcHNoX3Vzdl9rYW50ZSh7Im1vZGUiOiAiQUtLVV9QUlVFRiIsICJlZyI6IHsibW9kZSI6ICJORVRaIn19KSA9PSBbKCJ1c3Zfc3BpdHoiLCAiVVNWIFNwaXR6Ym9kZW4gQWtrdWJldHJpZWIiKV0KICAgIGFzc2VydCBfcHNoX3Vzdl9rYW50ZSh7Im1vZGUiOiAiTkVUWiIsICJlZyI6IHsibW9kZSI6ICJBS0tVIn19KSA9PSBbKCJ1c3Zfc3BpdHpfa2xhciIsICJVU1YgU3BpdHpib2RlbiB3aWVkZXIgYW0gTmV0eiIpLCAoInVzdl9lZyIsICJVU1YgVUctRFNMIEFra3ViZXRyaWViIildCiAgICBhc3NlcnQgX3BzaF91c3Zfa2FudGUoeyJtb2RlIjogIk5FVFoiLCAiZWciOiB7Im1vZGUiOiAiTkVUWiJ9fSkgPT0gWygidXN2X2VnX2tsYXIiLCAiVVNWIFVHLURTTCB3aWVkZXIgYW0gTmV0eiIpXQogICAgX1BTSF9CQVRUWyJzcGl0eiJdID0gX1BTSF9CQVRUWyJlZyJdID0gTm9uZQogICAgYXNzZXJ0IF9wc2hfdXN2X2thbnRlKHsibW9kZSI6ICJBS0tVIiwgImVnIjogeyJtb2RlIjogIkFLS1UifX0pID09IFtdCiAgICBfcHNoX3Byb2JlID0gJzxib2R5PjxkaXYgY2xhc3M9ImNhcmQiIGlkPSJhdWRpb0JveCI+PC9kaXY+PGRpdiBjbGFzcz0iY2FyZCIgaWQ9ImJhY2t1cEJveCI+PGRpdj54PC9kaXY+PC9kaXY+PGRpdiBpZD0icHJvakRvY0JveCIgY2xhc3M9InBkLWNhcmQiPlA8L2Rpdj48L2JvZHk+Jwo=","new":"ICAgIGFzc2VydCBfcHNoLnNlbGZ0ZXN0KCkuc3RhcnRzd2l0aCgicHVzaG92ZXJLYWNoZWwgb2siKQogICAgX1BTSF9CQVRUWyJzcGl0eiJdID0gX1BTSF9CQVRUWyJlZyJdID0gTm9uZQogICAgX1BTSF9BUk1bInNwaXR6Il0gPSBfUFNIX0FSTVsiZWciXSA9IEZhbHNlCiAgICBhc3NlcnQgX3BzaF91c3Zfa2FudGUoeyJtb2RlIjogIk5FVFoiLCAic3RhdHVzIjogIk9MIiwgImVnIjogeyJtb2RlIjogIk5FVFoiLCAic3RhdHVzIjogIk9MIn19KSA9PSBbXQogICAgYXNzZXJ0IF9wc2hfdXN2X2thbnRlKHsibW9kZSI6ICJBS0tVIiwgInN0YXR1cyI6ICJPQiIsICJlZyI6IHsibW9kZSI6ICJBS0tVIiwgInN0YXR1cyI6ICJPQiBESVNDSFJHIn19KSA9PSBbKCJ1c3Zfc3BpdHoiLCAiVVNWIFNwaXR6Ym9kZW4gQWtrdWJldHJpZWIiKSwgKCJ1c3ZfZWciLCAiVVNWIFVHLURTTCBBa2t1YmV0cmllYiIpXQogICAgYXNzZXJ0IF9wc2hfdXN2X2thbnRlKHsibW9kZSI6ICJORVRaIiwgInN0YXR1cyI6ICJPTCIsICJlZyI6IHsibW9kZSI6IE5vbmUsICJzdGF0dXMiOiAiT0wiLCAic3RhbGUiOiBGYWxzZX19KSA9PSBbKCJ1c3Zfc3BpdHpfa2xhciIsICJVU1YgU3BpdHpib2RlbiB3aWVkZXIgYW0gTmV0eiIpLCAoInVzdl9lZ19rbGFyIiwgIlVTViBVRy1EU0wgd2llZGVyIGFtIE5ldHoiKV0KICAgIF9QU0hfQkFUVFsic3BpdHoiXSA9IF9QU0hfQkFUVFsiZWciXSA9IE5vbmUKICAgIF9QU0hfQVJNWyJzcGl0eiJdID0gX1BTSF9BUk1bImVnIl0gPSBGYWxzZQogICAgYXNzZXJ0IF9wc2hfdXN2X2thbnRlKHsibW9kZSI6ICJORVRaIiwgInN0YXR1cyI6ICJPTCIsICJlZyI6IHsibW9kZSI6ICJORVRaIiwgInN0YXR1cyI6ICJPTCJ9fSwgW3siZXYiOiAiTkVUWkFVU0ZBTEwifV0pID09IFtdCiAgICBfcHNoX3Byb2JlID0gJzxib2R5PjxkaXYgY2xhc3M9ImNhcmQiIGlkPSJhdWRpb0JveCI+PC9kaXY+PGRpdiBjbGFzcz0iY2FyZCIgaWQ9ImJhY2t1cEJveCI+PGRpdj54PC9kaXY+PC9kaXY+PGRpdiBpZD0icHJvakRvY0JveCIgY2xhc3M9InBkLWNhcmQiPlA8L2Rpdj48L2JvZHk+Jwo="}],"pushover_push.py":[{"old":"CmRlZiBjb25zaWRlcihkYl9wYXRoLCBjZmcsIHNyYywgdGV4dCwgbm93PU5vbmUpOgogICAgIiIiVHJ1ZSwgd2VubiBlaW5lIE1lbGR1bmcgcmF1cyBkYXJmLiBBdXMsIG9obmUgU2NobHVlc3NlbCBvZGVyIGdsZWljaGVyIFRleHQ6IG5laW4uIiIiCg==","new":"CmRlZiBjb25zaWRlcihkYl9wYXRoLCBjZmcsIHNyYywgdGV4dCwgbm93PU5vbmUsIGVkZ2U9RmFsc2UpOgogICAgIiIiVHJ1ZSwgd2VubiBlaW5lIE1lbGR1bmcgcmF1cyBkYXJmLiBBdXMsIG9obmUgU2NobHVlc3NlbCBvZGVyIGdsZWljaGVyIFRleHQ6IG5laW4uIiIiCg=="}, {"old":"ICAgICAgICB0cywgcHJldiA9ICgwLCAiIikgaWYgcm93IGlzIE5vbmUgZWxzZSAoaW50KHJvd1swXSBvciAwKSwgcm93WzFdIG9yICIiKQogICAgICAgIGlmIHNyYyAhPSAidGVzdCIgYW5kIChzaWcgPT0gcHJldiBvciBub3cgLSB0cyA8IGludChjZmdbImdhcF9zIl0pKToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgY29uLmV4ZWN1dGUoCg==","new":"ICAgICAgICB0cywgcHJldiA9ICgwLCAiIikgaWYgcm93IGlzIE5vbmUgZWxzZSAoaW50KHJvd1swXSBvciAwKSwgcm93WzFdIG9yICIiKQogICAgICAgIGlmIHNyYyAhPSAidGVzdCI6CiAgICAgICAgICAgICMgS2FudGUgKEFra3UvRW50d2FybnVuZyk6IGRpZSBadXN0YW5kc21hc2NoaW5lIHZlcmhpbmRlcnQgV2llZGVyaG9sdW5nZW4uCiAgICAgICAgICAgICMgRGllIEFic3RhbmRzc3BlcnJlIGRhcmYgZWluZSBuZXVlIEVudHdhcm51bmcgbmljaHQgc2NobHVja2VuLgogICAgICAgICAgICBpZiBlZGdlOgogICAgICAgICAgICAgICAgaWYgc2lnID09IHByZXYgYW5kIG5vdyAtIHRzIDwgMTU6CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgICAgIGVsaWYgc2lnID09IHByZXYgb3Igbm93IC0gdHMgPCBpbnQoY2ZnWyJnYXBfcyJdKToKICAgICAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgICAgIGNvbi5leGVjdXRlKAo="}, {"old":"CiAgICBkZWYgcHVzaChzZWxmLCBzcmMsIHRleHQsIG5vdz1Ob25lKToKICAgICAgICBjZmcgPSBsb2FkX2NmZyhzZWxmLmNmZ19wYXRoKQogICAgICAgIGlmIG5vdCBjb25zaWRlcihzZWxmLmRiX3BhdGgsIGNmZywgc3JjLCB0ZXh0LCBub3cpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UK","new":"CiAgICBkZWYgcHVzaChzZWxmLCBzcmMsIHRleHQsIG5vdz1Ob25lLCBlZGdlPUZhbHNlKToKICAgICAgICBjZmcgPSBsb2FkX2NmZyhzZWxmLmNmZ19wYXRoKQogICAgICAgIGlmIG5vdCBjb25zaWRlcihzZWxmLmRiX3BhdGgsIGNmZywgc3JjLCB0ZXh0LCBub3csIGVkZ2U9ZWRnZSk6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQo="}]}

if __name__ == "__main__":
    sys.exit(main(sys.argv))
