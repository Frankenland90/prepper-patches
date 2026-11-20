#!/usr/bin/env python3
# Pinneberg-Empfangsfix: Journal, Zombies, Neustart, Stick 3 allein.
# Kein Mesh, keine Abschaltung, keine Firewall. Airspy, Stick 1 und Stick 2 bleiben.
from __future__ import annotations
import base64, hashlib, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
PI = {
    "dashboard.py": ("239bdf4d0f761325", 1392013),
    "blackout_radar.py": ("4ff38da718afed9d", 84127),
    "lage_pages.py": ("e9ea014b5a4ff121", 230936),
}
RX_BASIS = ("835b9697eda8aac5", 11286)
SDR_BASIS = ("9b2f565c65db2090", 775580)
PATCH = ("pinneberg_rx.py", "prepper_sdr.py")
CHECK = ("dashboard.py", "blackout_radar.py", "lage_pages.py")


def load():
    raw = PAYLOAD_JSON
    rx = (base64.b64decode(raw["rx"]["old"]), base64.b64decode(raw["rx"]["new"]))
    sdr = [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw["sdr"]]
    return rx, sdr


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fenster(now=None):
    from zoneinfo import ZoneInfo
    jetzt = now or datetime.now(ZoneInfo("Europe/Berlin"))
    m = jetzt.minute
    return (not (m >= 45 or m <= 4)), "Berlin Minute %02d" % m


def verwandle(data, pairs):
    if all(data.count(neu) == 1 and data.count(old) == 0 for old, neu in pairs):
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
    return neu_data


def sichern(path: Path, data: bytes):
    stempel = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S")
    alt = sorted(path.parent.glob(path.name + ".bak-pnfix-*"))
    bak = path.with_name(path.name + ".bak-pnfix-" + stempel)
    shutil.copy2(path, bak)
    if bak.read_bytes() != data:
        bak.unlink()
        raise RuntimeError("Sicherung weicht ab")
    for alt_pfad in alt[:-2]:
        try:
            alt_pfad.unlink()
        except OSError:
            pass


def schreiben(path: Path, data: bytes):
    mode = path.stat().st_mode & 0o777
    tmp = path.with_name("." + path.name + ".tmp-pnfix")
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


def apply_dir(ordner: Path, dry: bool, kein: bool, jetzt=None) -> int:
    rx_pair, sdr_pairs = load()
    falsch = False
    blobs = {}
    for name in list(PATCH) + list(CHECK):
        pfad = ordner / name
        if pfad.is_symlink() or not pfad.is_file():
            print("STOP: %s fehlt" % name)
            return 2
        data = pfad.read_bytes()
        blobs[name] = data
        ist = sha(data)
        print("%s sha16 %s bytes %d" % (name, ist[:16], len(data)))
        if name in PI:
            kopf, laenge = PI[name]
            if not ist.startswith(kopf) or len(data) != laenge:
                print("STOP: %s %s / %d ist nicht der Pi-Stand %s / %d" % (name, ist[:16], len(data), kopf, laenge))
                falsch = True
    if falsch:
        print("STOP: Hash-Guard. Nichts geschrieben.")
        return 2
    rx_old, rx_new = rx_pair
    rx = blobs["pinneberg_rx.py"]
    rx_ist = sha(rx)
    if rx == rx_new:
        rx_ziel = rx
    elif rx == rx_old:
        rx_ziel = rx_new
    else:
        print("STOP: pinneberg_rx.py %s / %d passt nicht zum Stufe-2-Stand %s / %d und ist nicht der neue Empfang. Nichts geschrieben." % (rx_ist[:16], len(rx), RX_BASIS[0], RX_BASIS[1]))
        return 2
    sdr_ist = sha(blobs["prepper_sdr.py"])
    if not sdr_ist.startswith(SDR_BASIS[0]) or len(blobs["prepper_sdr.py"]) != SDR_BASIS[1]:
        print("Hinweis: prepper_sdr.py ist %s / %d, der Stufe-2-Stand im Repo ist %s / %d. Der Anker wird trotzdem geprueft, der Hash allein stoppt nicht." % (sdr_ist[:16], len(blobs["prepper_sdr.py"]), SDR_BASIS[0], SDR_BASIS[1]))
    else:
        print("prepper_sdr.py entspricht dem Stufe-2-Stand %s / %d" % SDR_BASIS)
    try:
        sdr_ziel = verwandle(blobs["prepper_sdr.py"], sdr_pairs)
    except RuntimeError:
        print("STOP: Anker in prepper_sdr.py fehlt oder ist nicht eindeutig (Hobby-Startzeile, Anzeigetext, Start-Sperre). Hash %s / %d. Nichts geschrieben." % (sdr_ist[:16], len(blobs["prepper_sdr.py"])))
        return 2
    try:
        compile(rx_ziel, "pinneberg_rx.py", "exec")
        if b"class Planner" in sdr_ziel or b"def selftest" in sdr_ziel:
            compile(sdr_ziel, "prepper_sdr.py", "exec")
    except SyntaxError as exc:
        print("STOP: Syntax %s" % exc)
        return 2
    if b"def cycle(self, base)" not in rx_ziel or b"pinneberg:" not in rx_ziel or b"Pipeline beendet" not in rx_ziel:
        print("STOP: Waechter fehlt in pinneberg_rx.py")
        return 2
    if b"def _pn_start" not in sdr_ziel or b"kein zweites Programm" not in sdr_ziel:
        print("STOP: Stick-Sperre fehlt in prepper_sdr.py")
        return 2
    print("pinneberg_rx.py endstand sha16 %s bytes %d" % (sha(rx_ziel)[:16], len(rx_ziel)))
    print("prepper_sdr.py endstand sha16 %s bytes %d" % (sha(sdr_ziel)[:16], len(sdr_ziel)))
    for name in CHECK:
        print("%s unveraendert sha16 %s bytes %d" % (name, sha(blobs[name])[:16], len(blobs[name])))
    frei, meldung = fenster(jetzt)
    print(meldung)
    if rx == rx_ziel and blobs["prepper_sdr.py"] == sdr_ziel:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        if not frei:
            print("Ein echtes Apply wuerde in dieser Minute ohne Aenderung abbrechen.")
        print("Nach dem Einspielen: systemctl restart prepper-sdr.service")
        print("Pruefung: journalctl -u prepper-sdr.service -n 80 --no-pager | grep pinneberg")
        return 0
    if not frei:
        print("STOP: Neustart-Sperre Minute 45-59 und 00-04 Berlin. Nichts geschrieben.")
        return 2
    try:
        if rx != rx_ziel:
            sichern(ordner / "pinneberg_rx.py", rx)
            schreiben(ordner / "pinneberg_rx.py", rx_ziel)
        if blobs["prepper_sdr.py"] != sdr_ziel:
            sichern(ordner / "prepper_sdr.py", blobs["prepper_sdr.py"])
            schreiben(ordner / "prepper_sdr.py", sdr_ziel)
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    print("geschrieben. prepper-sdr muss neu starten, damit der Waechter laeuft. Dashboard, Mesh und Firewall bleiben.")
    if kein:
        print("Kein Neustart in dieser Pruefung. Danach, ausserhalb Minute 45-59 und 00-04: systemctl restart prepper-sdr.service")
        print("Pruefung: journalctl -u prepper-sdr.service -n 80 --no-pager | grep pinneberg")
        return 0
    frei, meldung = fenster()
    print(meldung)
    if not frei:
        print("STOP: Dateien sind neu, der Neustart bleibt in der Sperre aus.")
        return 2
    __import__("subprocess").run(["systemctl", "restart", "prepper-sdr.service"], check=False)
    print("Nur prepper-sdr.service neu gestartet.")
    print("Pruefung: journalctl -u prepper-sdr.service -n 80 --no-pager | grep pinneberg")
    return 0


def selftest() -> int:
    assert PI["dashboard.py"] == ("239bdf4d0f761325", 1392013)
    assert PI["blackout_radar.py"][0] == "4ff38da718afed9d" and PI["blackout_radar.py"][1] == 84127
    assert PI["lage_pages.py"][0] == "e9ea014b5a4ff121" and PI["lage_pages.py"][1] == 230936
    assert RX_BASIS == ("835b9697eda8aac5", 11286)
    assert SDR_BASIS == ("9b2f565c65db2090", 775580)
    assert fenster(datetime(2026, 11, 20, 19, 12))[0]
    assert not fenster(datetime(2026, 11, 20, 19, 45))[0]
    assert not fenster(datetime(2026, 11, 20, 19, 59))[0]
    assert not fenster(datetime(2026, 11, 20, 20, 0))[0]
    assert not fenster(datetime(2026, 11, 20, 20, 4))[0]
    assert fenster(datetime(2026, 11, 20, 20, 5))[0]
    rx_pair, sdr_pairs = load()
    assert rx_pair[1].count(rx_pair[0]) == 0
    assert b"stderr=subprocess.DEVNULL" in rx_pair[0]
    assert b"def cycle(self, base)" in rx_pair[1]
    assert b"subprocess.DEVNULL" not in rx_pair[1]
    import tempfile
    ordner = Path(tempfile.mkdtemp(prefix="pnfix-"))
    (ordner / "pinneberg_rx.py").write_bytes(rx_pair[0])
    sdr = b"\n".join(alt for alt, _neu in sdr_pairs)
    (ordner / "prepper_sdr.py").write_bytes(sdr)
    for name in CHECK:
        (ordner / name).write_bytes(b"falsch")
    vorher = {name: (ordner / name).read_bytes() for name in list(PATCH) + list(CHECK)}
    assert apply_dir(ordner, True, True, datetime(2026, 11, 20, 19, 12)) == 2
    assert vorher == {name: (ordner / name).read_bytes() for name in vorher}
    merk = dict(PI)
    try:
        for name in CHECK:
            teil = b"basis-" + name.encode() + b"-"
            blob = (teil * (merk[name][1] // len(teil) + 1))[:merk[name][1]]
            (ordner / name).write_bytes(blob)
            PI[name] = (sha(blob)[:16], len(blob))
        (ordner / "prepper_sdr.py").write_bytes(b"kein Anker")
        vorher = {name: (ordner / name).read_bytes() for name in list(PATCH) + list(CHECK)}
        assert apply_dir(ordner, False, True, datetime(2026, 11, 20, 19, 12)) == 2
        assert vorher == {name: (ordner / name).read_bytes() for name in vorher}
        (ordner / "prepper_sdr.py").write_bytes(sdr)
        assert apply_dir(ordner, True, True, datetime(2026, 11, 20, 19, 50)) == 0
        assert (ordner / "pinneberg_rx.py").read_bytes() == rx_pair[0]
        assert (ordner / "prepper_sdr.py").read_bytes() == sdr
        assert apply_dir(ordner, False, True, datetime(2026, 11, 20, 19, 46)) == 2
        assert (ordner / "pinneberg_rx.py").read_bytes() == rx_pair[0]
        assert apply_dir(ordner, False, True, datetime(2026, 11, 20, 19, 10)) == 0
        assert (ordner / "pinneberg_rx.py").read_bytes() == rx_pair[1]
        assert b"def _pn_start" in (ordner / "prepper_sdr.py").read_bytes()
        assert b"stderr=subprocess.DEVNULL" not in (ordner / "pinneberg_rx.py").read_bytes()
        assert list(ordner.glob("*.bak-pnfix-*"))
        for name in CHECK:
            assert (ordner / name).read_bytes().startswith(b"basis-")
        assert apply_dir(ordner, False, True, datetime(2026, 11, 20, 19, 10)) == 0
    finally:
        PI.clear()
        PI.update(merk)
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


PAYLOAD_JSON = {"rx": {"old": "IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoiIiJQaW5uZWJlcmcgU3R1ZmUgMjogUlRUWS1FbXBmYW5nIHBsYW5lbiwgZmlsdGVybiwgc3BlaWNoZXJuLiBLZWluIEdlcmFldCBpbiBkZW4gVGVzdHMuCgpLZXR0ZSwgd2VubiBkZXIgUHJvemVzcyBzaWUgd2lya2xpY2ggc3RhcnRldDogcnRsX2ZtIC1NIHVzYiwgZXR3YSAxIGtIeiB1bnRlciBkZXIKU3B5VmVydGVyLU1pdHRlLCAxMiBrUy9zLCBkYW5uIG1pbmltb2RlbSAtLXJ4IDUwIC0tYmF1ZG90LiBNYXJrIHVuZCBTcGFjZSB3ZXJkZW4KZ2V0YXVzY2h0LCB3ZW5uIGRpZSBlaW5lIExhZ2UgbnVyIE11ZWxsIGxpZWZlcnQuIEVzIHdpcmQga2VpbiBUZXN0IGF1c2dlbG9lc3QgdW5kCm5pY2h0cyBnZXNlbmRldC4gU2VyaWVubnVtbWVybiBzdGVoZW4gbmljaHQgaW4gZGllc2VyIERhdGVpLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzcWxpdGUzCmltcG9ydCB0aW1lCmZyb20gZGF0ZXRpbWUgaW1wb3J0IGRhdGV0aW1lCgp0cnk6CiAgICBmcm9tIHpvbmVpbmZvIGltcG9ydCBab25lSW5mbwpleGNlcHQgRXhjZXB0aW9uOgogICAgWm9uZUluZm8gPSBOb25lCgpSRl9OSUdIVCA9IDE0NzMwMApSRl9EQVkgPSA3NjQ2MDAwCkxPX0haID0gMTIwMDAwMDAwCkJFTE9XX0haID0gMTAwMApSQVRFID0gMTIwMDAKQkFVRCA9IDUwCk1BUktfSFogPSAxMjI1ClNQQUNFX0haID0gNzc1Ck5JR0hUX1NUQVJUID0gMTggKiA2MApOSUdIVF9FTkQgPSA2ICogNjAKREJfTkFNRSA9ICJsYWdlemVudHJ1bS5kYiIKCgpkZWYgX2htKHRleHQsIGRlZmF1bHQpOgogICAgdHJ5OgogICAgICAgIGgsIG0gPSBzdHIodGV4dCkuc3BsaXQoIjoiLCAxKQogICAgICAgIGdvdCA9IGludChoKSAqIDYwICsgaW50KG0pCiAgICBleGNlcHQgKFR5cGVFcnJvciwgVmFsdWVFcnJvciwgQXR0cmlidXRlRXJyb3IpOgogICAgICAgIHJldHVybiBkZWZhdWx0CiAgICByZXR1cm4gZ290IGlmIDAgPD0gZ290IDwgMjQgKiA2MCBlbHNlIGRlZmF1bHQKCgpkZWYgcGxhbihub3c9Tm9uZSwgY2ZnPU5vbmUpOgogICAgIiIiTmFjaHQgMTQ3LDMga0h6LCBUYWcgNzY0NiBrSHouIFplaXRlbiB1bmQgRnJlcXVlbnplbiBrb21tZW4gYXVzIGRlciBSb2xsZW5kYXRlaSwgc29uc3QgZGllIFZvcmdhYmVuLiIiIgogICAgY2ZnID0gY2ZnIG9yIHt9CiAgICBub3cgPSB0aW1lLnRpbWUoKSBpZiBub3cgaXMgTm9uZSBlbHNlIGZsb2F0KG5vdykKICAgIGlmIFpvbmVJbmZvIGlzIG5vdCBOb25lOgogICAgICAgIGR0ID0gZGF0ZXRpbWUuZnJvbXRpbWVzdGFtcChub3csIFpvbmVJbmZvKCJFdXJvcGUvQmVybGluIikpCiAgICBlbHNlOgogICAgICAgIGR0ID0gZGF0ZXRpbWUuZnJvbXRpbWVzdGFtcChub3cpCiAgICBtaW51dGUgPSBkdC5ob3VyICogNjAgKyBkdC5taW51dGUKICAgIHN0YXJ0ID0gX2htKGNmZy5nZXQoIm5pZ2h0X3N0YXJ0IiksIE5JR0hUX1NUQVJUKQogICAgZW5kID0gX2htKGNmZy5nZXQoIm5pZ2h0X2VuZCIpLCBOSUdIVF9FTkQpCiAgICBuaWdodCA9IG1pbnV0ZSA+PSBzdGFydCBvciBtaW51dGUgPCBlbmQgaWYgc3RhcnQgIT0gZW5kIGVsc2UgRmFsc2UKICAgIHJmID0gaW50KGNmZy5nZXQoInJmX25pZ2h0X2h6Iikgb3IgUkZfTklHSFQpIGlmIG5pZ2h0IGVsc2UgaW50KGNmZy5nZXQoInJmX2RheV9oeiIpIG9yIFJGX0RBWSkKICAgIGxvID0gaW50KGNmZy5nZXQoImxvX2h6Iikgb3IgTE9fSFopCiAgICBiZWxvdyA9IGludChjZmcuZ2V0KCJ0dW5lX2JlbG93X2h6Iikgb3IgQkVMT1dfSFopCiAgICByZXR1cm4geyJuaWdodCI6IG5pZ2h0LCAicmZfaHoiOiByZiwgImlmX2h6IjogbG8gKyByZiwgInR1bmVfaHoiOiBsbyArIHJmIC0gYmVsb3csCiAgICAgICAgICAgICJyYXRlIjogaW50KGNmZy5nZXQoInJhdGUiKSBvciBSQVRFKSwgImJhdWQiOiBpbnQoY2ZnLmdldCgiYmF1ZCIpIG9yIEJBVUQpLAogICAgICAgICAgICAibWFya19oeiI6IGludChjZmcuZ2V0KCJtYXJrX2h6Iikgb3IgTUFSS19IWiksICJzcGFjZV9oeiI6IGludChjZmcuZ2V0KCJzcGFjZV9oeiIpIG9yIFNQQUNFX0haKX0KCgpkZWYgc2VyaWFsX29rKHNlcmlhbCk6CiAgICAiIiJydGxfZm0gbmltbXQgZWluZSBrbGVpbmUgcmVpbmUgWmFobCBhbHMgR2VyYWV0ZWluZGV4LiBFaW5lIFNlcmllbm51bW1lciBibGVpYnQgZWluZSBaZWljaGVua2V0dGUuIiIiCiAgICBzID0gc3RyKHNlcmlhbCBvciAiIikuc3RyaXAoKQogICAgaWYgbGVuKHMpIDwgNCBvciBsZW4ocykgPiAzMiBvciBhbnkoYyBub3QgaW4gIjAxMjM0NTY3ODlBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWiIgZm9yIGMgaW4gcy51cHBlcigpKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGlmIHMuaXNkaWdpdCgpIGFuZCBpbnQocykgPCAzMjoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHJldHVybiBUcnVlCgoKZGVmIHJ0bF9hcmd2KHNlcmlhbCwgdHVuZV9oeiwgcmF0ZT1SQVRFKToKICAgIGlmIG5vdCBzZXJpYWxfb2soc2VyaWFsKToKICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCJzZXJpZW5udW1tZXIiKQogICAgaWYgaW50KHR1bmVfaHopIDwgMTAwMDAwMCBvciAiLVQiIGluIHN0cihzZXJpYWwpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoImFic3RpbW11bmciKQogICAgcmV0dXJuIFsicnRsX2ZtIiwgIi1kIiwgc3RyKHNlcmlhbCksICItZiIsIHN0cihpbnQodHVuZV9oeikpLCAiLU0iLCAidXNiIiwgIi1zIiwgc3RyKGludChyYXRlKSksICItciIsIHN0cihpbnQocmF0ZSkpXQoKCmRlZiBtaW5pbW9kZW1fYXJndihtYXJrPU1BUktfSFosIHNwYWNlPVNQQUNFX0haLCBiYXVkPUJBVUQpOgogICAgcmV0dXJuIFsibWluaW1vZGVtIiwgIi0tcngiLCBzdHIoaW50KGJhdWQpKSwgIi0tYmF1ZG90IiwgIi1NIiwgc3RyKGludChtYXJrKSksICItUyIsIHN0cihpbnQoc3BhY2UpKV0KCgpkZWYgcGxhdXNpYmxlKHRleHQsIGFtcGw9Tm9uZSk6CiAgICAiIiJSYXVzY2hlbiB3aWUgS1hRVlFRS1ZNWFFHS09RUVYgYmVpIGFtcGw9MCBibGVpYnQgZHJhdXNzZW4uIEtlaW4gQWxhcm0uIiIiCiAgICBpZiBhbXBsIGlzIG5vdCBOb25lOgogICAgICAgIHRyeToKICAgICAgICAgICAgaWYgZmxvYXQoYW1wbCkgPD0gMDoKICAgICAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgICAgIGV4Y2VwdCAoVHlwZUVycm9yLCBWYWx1ZUVycm9yKToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICB0ID0gIiAiLmpvaW4oIiIuam9pbihjaCBpZiBjaC5pc3ByaW50YWJsZSgpIGVsc2UgIiAiIGZvciBjaCBpbiBzdHIodGV4dCBvciAiIikpLnNwbGl0KCkpCiAgICBsZXR0ZXJzID0gW2MgZm9yIGMgaW4gdC51cHBlcigpIGlmICJBIiA8PSBjIDw9ICJaIl0KICAgIGlmIGxlbih0KSA8IDEyIG9yIGxlbihsZXR0ZXJzKSA8IDg6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICB2b3dlbHMgPSBzdW0oYyBpbiAiQUVJT1VZIiBmb3IgYyBpbiBsZXR0ZXJzKQogICAgcmFyZSA9IHN1bShjIGluICJRWFpKS1YiIGZvciBjIGluIGxldHRlcnMpCiAgICBzcGFjZXMgPSB0LmNvdW50KCIgIikKICAgIGRpZ2l0cyA9IHN1bShjLmlzZGlnaXQoKSBmb3IgYyBpbiB0KQogICAgaWYgc3BhY2VzID09IDAgYW5kIHJhcmUgPj0gNCBhbmQgdm93ZWxzIDw9IDMgYW5kIGRpZ2l0cyA8IDQ6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBzcGFjZXMgPT0gMCBhbmQgZGlnaXRzIDwgNCBhbmQgdm93ZWxzICogNSA8IGxlbihsZXR0ZXJzKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHJldHVybiBUcnVlCgoKZGVmIF9jb24ocGF0aCk6CiAgICBjb24gPSBzcWxpdGUzLmNvbm5lY3QocGF0aCwgdGltZW91dD01KQogICAgbW9kZSA9IGNvbi5leGVjdXRlKCJQUkFHTUEgam91cm5hbF9tb2RlPVdBTCIpLmZldGNob25lKCkKICAgIGlmIG1vZGUgaXMgTm9uZSBvciBzdHIobW9kZVswXSkubG93ZXIoKSAhPSAid2FsIjoKICAgICAgICBjb24uY2xvc2UoKQogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigid2FsIikKICAgIGNvbi5leGVjdXRlKCJQUkFHTUEgc3luY2hyb25vdXM9Tk9STUFMIikKICAgIGNvbi5leGVjdXRlKCJDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyBwaW5uZWJlcmdfbXNnICgiCiAgICAgICAgICAgICAgICAiaWQgSU5URUdFUiBQUklNQVJZIEtFWSBBVVRPSU5DUkVNRU5ULCB0cyBJTlRFR0VSIE5PVCBOVUxMLCByZl9oeiBJTlRFR0VSIE5PVCBOVUxMLCAiCiAgICAgICAgICAgICAgICAiaWZfaHogSU5URUdFUiBOT1QgTlVMTCwgdGV4dCBURVhUIE5PVCBOVUxMLCBxdWFsaXR5IFJFQUwpIikKICAgIHJldHVybiBjb24KCgpkZWYgc3RvcmUocGF0aCwgdHMsIHJmX2h6LCBpZl9oeiwgdGV4dCwgcXVhbGl0eT1Ob25lKToKICAgIGlmIG5vdCBwbGF1c2libGUodGV4dCwgcXVhbGl0eSk6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBjb24gPSBfY29uKHBhdGgpCiAgICB0cnk6CiAgICAgICAgY29uLmV4ZWN1dGUoIklOU0VSVCBJTlRPIHBpbm5lYmVyZ19tc2cgKHRzLCByZl9oeiwgaWZfaHosIHRleHQsIHF1YWxpdHkpIFZBTFVFUyAoPyw/LD8sPyw/KSIsCiAgICAgICAgICAgICAgICAgICAgKGludCh0cyksIGludChyZl9oeiksIGludChpZl9oeiksICIgIi5qb2luKHN0cih0ZXh0KS5zcGxpdCgpKVs6NDAwXSwgTm9uZSBpZiBxdWFsaXR5IGlzIE5vbmUgZWxzZSBmbG9hdChxdWFsaXR5KSkpCiAgICAgICAgY29uLmNvbW1pdCgpCiAgICBmaW5hbGx5OgogICAgICAgIGNvbi5jbG9zZSgpCiAgICByZXR1cm4gVHJ1ZQoKCmRlZiByZWNlbnQocGF0aCwgbGltaXQ9NSwgbm93PU5vbmUsIGZyZXNoX3M9OTAwKToKICAgICIiIkxldHp0ZSBwbGF1c2libGUgQmxvZWNrZS4gT2huZSBmcmlzY2hlbiBCbG9jazoga2VpbiBFbXBmYW5nLCBuaWUgZWluZSBXYXJudW5nLiIiIgogICAgdHJ5OgogICAgICAgIGNvbiA9IF9jb24ocGF0aCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIHsiZW1wZmFuZyI6IEZhbHNlLCAidHh0IjogImtlaW4gRW1wZmFuZyIsICJtZXNzYWdlcyI6IFtdfQogICAgdHJ5OgogICAgICAgIHJvd3MgPSBjb24uZXhlY3V0ZSgiU0VMRUNUIHRzLCByZl9oeiwgdGV4dCwgcXVhbGl0eSBGUk9NIHBpbm5lYmVyZ19tc2cgT1JERVIgQlkgaWQgREVTQyBMSU1JVCA/IiwgKGludChsaW1pdCksKSkuZmV0Y2hhbGwoKQogICAgZmluYWxseToKICAgICAgICBjb24uY2xvc2UoKQogICAgbm93ID0gdGltZS50aW1lKCkgaWYgbm93IGlzIE5vbmUgZWxzZSBmbG9hdChub3cpCiAgICBtZXNzYWdlcyA9IFt7InQiOiBpbnQoclswXSksICJyZl9oeiI6IGludChyWzFdKSwgInRleHQiOiByWzJdLCAicXVhbGl0eSI6IHJbM119IGZvciByIGluIHJvd3NdCiAgICBmcmVzaCA9IFttIGZvciBtIGluIG1lc3NhZ2VzIGlmIG5vdyAtIG1bInQiXSA8PSBmcmVzaF9zXQogICAgaWYgbm90IGZyZXNoOgogICAgICAgIHJldHVybiB7ImVtcGZhbmciOiBGYWxzZSwgInR4dCI6ICJrZWluIEVtcGZhbmciLCAibWVzc2FnZXMiOiBtZXNzYWdlc30KICAgIHJldHVybiB7ImVtcGZhbmciOiBUcnVlLCAidHh0IjogZnJlc2hbMF1bInRleHQiXSwgIm1lc3NhZ2VzIjogbWVzc2FnZXN9CgoKY2xhc3MgU2Vzc2lvbjoKICAgICIiIkVpbiBFbXBmYWVuZ2VyLiBUZXN0cyB1ZWJlcmdlYmVuIGVpbmUgQXR0cmFwcGUgdW5kIG9lZmZuZW4ga2VpbiBHZXJhZXQuIiIiCgogICAgZGVmIF9faW5pdF9fKHNlbGYpOgogICAgICAgIHNlbGYucHJvYyA9IE5vbmUKICAgICAgICBzZWxmLmludmVyc2lvbiA9IDAKICAgICAgICBzZWxmLmxhc3RfZ29vZCA9IDAKCiAgICBkZWYgYXJndihzZWxmLCBzZXJpYWwsIG5vdz1Ob25lLCBjZmc9Tm9uZSk6CiAgICAgICAgcCA9IHBsYW4obm93LCBjZmcpCiAgICAgICAgcnRsID0gcnRsX2FyZ3Yoc2VyaWFsLCBwWyJ0dW5lX2h6Il0sIHBbInJhdGUiXSkKICAgICAgICBtYXJrLCBzcGFjZSA9IChwWyJtYXJrX2h6Il0sIHBbInNwYWNlX2h6Il0pIGlmIHNlbGYuaW52ZXJzaW9uICUgMiA9PSAwIGVsc2UgKHBbInNwYWNlX2h6Il0sIHBbIm1hcmtfaHoiXSkKICAgICAgICBpZiAiLVQiIGluIHJ0bCBvciBhbnkoeCBpbiBydGwgZm9yIHggaW4gKCItVCIsICItLWJpYXMiKSk6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigiYmlhcyIpCiAgICAgICAgcmV0dXJuIHJ0bCwgbWluaW1vZGVtX2FyZ3YobWFyaywgc3BhY2UsIHBbImJhdWQiXSksIHAKCiAgICBkZWYgc3RhcnQoc2VsZiwgYmFzZSk6CiAgICAgICAgIiIiTnVyIGF1cyBkZW0gU0RSLUhhdXB0bGF1Zi4gT2VmZm5ldCBkZW4gU3RpY2sgdWViZXIgZGllIFNlcmllbm51bW1lciBhdXMgZGVtIFJlZ2lzdGVyLCBuaWUgdWViZXIgZGVuIEluZGV4LiIiIgogICAgICAgIGltcG9ydCB0aHJlYWRpbmcKICAgICAgICBpZiBzZWxmLnByb2MgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgICAgIHRyeToKICAgICAgICAgICAgaW1wb3J0IHBpbm5lYmVyZ19yb2xsZSBhcyByb2xsZQogICAgICAgICAgICBpbXBvcnQgcHJlcHBlcl9zZHIgYXMgcHMKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBkb2MgPSByb2xsZS5sb2FkKGJhc2UpIG9yIHt9CiAgICAgICAgaWYgbm90IChyb2xsZS5lbmdhZ2VkKGJhc2UpIGFuZCBpbnQoZG9jLmdldCgic3R1ZmUiKSBvciAwKSA+PSAyIGFuZCBkb2MuZ2V0KCJlbXBmYW5nIikgaXMgVHJ1ZSBhbmQgbm90IGRvYy5nZXQoImJpYXNfdGVlIikpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICByZWcgPSAocHMuYWlyX3JlZyhwcy5jb25maWcoYmFzZSkpIG9yIHt9KS5nZXQoImJ5X3JvbGUiKSBvciB7fQogICAgICAgIGVudHJ5ID0gcmVnLmdldCgiaG9iYnkyIikgaWYgaXNpbnN0YW5jZShyZWcuZ2V0KCJob2JieTIiKSwgZGljdCkgZWxzZSBOb25lCiAgICAgICAgc2VyaWFsID0gKGVudHJ5IG9yIHt9KS5nZXQoInNlcmlhbCIpCiAgICAgICAgaWYgbm90IHNlcmlhbF9vayhzZXJpYWwpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBpbXBvcnQgc3VicHJvY2VzcwogICAgICAgIGRlZiBzcGF3bihydGwsIG1tKToKICAgICAgICAgICAgc3JjID0gc3VicHJvY2Vzcy5Qb3BlbihydGwsIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgIG91dCA9IHN1YnByb2Nlc3MuUG9wZW4obW0sIHN0ZGluPXNyYy5zdGRvdXQsIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsIHRleHQ9VHJ1ZSkKICAgICAgICAgICAgaWYgc3JjLnN0ZG91dDoKICAgICAgICAgICAgICAgIHNyYy5zdGRvdXQuY2xvc2UoKQogICAgICAgICAgICBvdXQuX3J0bCA9IHNyYwogICAgICAgICAgICByZXR1cm4gb3V0CiAgICAgICAgaWYgbm90IHNlbGYuYm9vdChiYXNlLCBzcGF3bj1zcGF3biwgc2VyaWFsPXNlcmlhbCwgY2ZnPWRvYyk6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgICAgIHRocmVhZGluZy5UaHJlYWQodGFyZ2V0PXNlbGYuX3JlYWQsIGFyZ3M9KGJhc2UsIGRvYyksIGRhZW1vbj1UcnVlKS5zdGFydCgpCiAgICAgICAgcmV0dXJuIFRydWUKCiAgICBkZWYgX3JlYWQoc2VsZiwgYmFzZSwgY2ZnKToKICAgICAgICBwcm9jID0gc2VsZi5wcm9jCiAgICAgICAgaWYgcHJvYyBpcyBOb25lIG9yIHByb2Muc3Rkb3V0IGlzIE5vbmU6CiAgICAgICAgICAgIHJldHVybgogICAgICAgIHAgPSBwbGFuKGNmZz1jZmcpCiAgICAgICAgZGIgPSBvcy5wYXRoLmpvaW4oYmFzZSwgREJfTkFNRSkKICAgICAgICB0cnk6CiAgICAgICAgICAgIGZvciBsaW5lIGluIHByb2Muc3Rkb3V0OgogICAgICAgICAgICAgICAgaWYgc3RvcmUoZGIsIHRpbWUudGltZSgpLCBwWyJyZl9oeiJdLCBwWyJpZl9oeiJdLCBsaW5lLCBOb25lKToKICAgICAgICAgICAgICAgICAgICBzZWxmLmxhc3RfZ29vZCA9IHRpbWUudGltZSgpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwoKICAgIGRlZiBib290KHNlbGYsIGJhc2UsIHNwYXduPU5vbmUsIHNlcmlhbD1Ob25lLCBjZmc9Tm9uZSk6CiAgICAgICAgIiIiU3RhcnQgbnVyIG1pdCBhdXNkcnVlY2tsaWNoZW0gc3Bhd24uIERlciBQcm9kdWt0aXZzdGFydCB1ZWJlcmdpYnQgc3VicHJvY2Vzcy4iIiIKICAgICAgICBpZiBzcGF3biBpcyBOb25lIG9yIHNlbGYucHJvYyBpcyBub3QgTm9uZToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgaWYgbm90IHNlcmlhbF9vayhzZXJpYWwpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBydGwsIG1tLCBfcCA9IHNlbGYuYXJndihzZXJpYWwsIGNmZz1jZmcpCiAgICAgICAgc2VsZi5wcm9jID0gc3Bhd24ocnRsLCBtbSkKICAgICAgICByZXR1cm4gVHJ1ZQoKICAgIGRlZiBzdG9wKHNlbGYpOgogICAgICAgIHByb2MsIHNlbGYucHJvYyA9IHNlbGYucHJvYywgTm9uZQogICAgICAgIGlmIHByb2MgaXMgbm90IE5vbmUgYW5kIGhhc2F0dHIocHJvYywgInRlcm1pbmF0ZSIpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBwcm9jLnRlcm1pbmF0ZSgpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCgoKU0VTUyA9IFNlc3Npb24oKQoKCmRlZiBzZWxmdGVzdCgpOgogICAgb3MuZW52aXJvbi5wb3AoIlBJTk5FQkVSR19TRVJJQUwiLCBOb25lKQogICAgcCA9IHBsYW4oZGF0ZXRpbWUoMjAyNiwgMTEsIDEyLCAyMywgMCwgdHppbmZvPVpvbmVJbmZvKCJFdXJvcGUvQmVybGluIikpLnRpbWVzdGFtcCgpIGlmIFpvbmVJbmZvIGVsc2UgMV83MDBfMDAwXzAwMCkKICAgIGFzc2VydCBwWyJyZl9oeiJdID09IFJGX05JR0hUIGFuZCBwWyJpZl9oeiJdID09IExPX0haICsgUkZfTklHSFQgYW5kIHBbInR1bmVfaHoiXSA9PSBwWyJpZl9oeiJdIC0gQkVMT1dfSFoKICAgIGRheSA9IHBsYW4oZGF0ZXRpbWUoMjAyNiwgMTEsIDEyLCAxMiwgMCwgdHppbmZvPVpvbmVJbmZvKCJFdXJvcGUvQmVybGluIikpLnRpbWVzdGFtcCgpKQogICAgYXNzZXJ0IGRheVsibmlnaHQiXSBpcyBGYWxzZSBhbmQgZGF5WyJyZl9oeiJdID09IFJGX0RBWSBhbmQgZGF5WyJ0dW5lX2h6Il0gPT0gTE9fSFogKyBSRl9EQVkgLSAxMDAwCiAgICBhc3NlcnQgc2VyaWFsX29rKCI5MDAwMDAwMyIpIGFuZCBub3Qgc2VyaWFsX29rKCIyIikgYW5kIG5vdCBzZXJpYWxfb2soIiIpIGFuZCBub3Qgc2VyaWFsX29rKCItVCIpCiAgICBydGwsIG1tLCBwbGFuX2QgPSBTRVNTLmFyZ3YoIjkwMDAwMDAzIiwgZGF5WyJ0dW5lX2h6Il0gYW5kIGRhdGV0aW1lKDIwMjYsIDExLCAxMiwgMTIsIDAsIHR6aW5mbz1ab25lSW5mbygiRXVyb3BlL0JlcmxpbiIpKS50aW1lc3RhbXAoKSkKICAgIGFzc2VydCBydGxbOjRdID09IFsicnRsX2ZtIiwgIi1kIiwgIjkwMDAwMDAzIiwgIi1mIl0gYW5kIHJ0bFs0XSA9PSBzdHIoZGF5WyJ0dW5lX2h6Il0pIGFuZCAiLVQiIG5vdCBpbiBydGwKICAgIGFzc2VydCBtbVs6NF0gPT0gWyJtaW5pbW9kZW0iLCAiLS1yeCIsICI1MCIsICItLWJhdWRvdCJdIGFuZCAiMTIyNSIgaW4gbW0gYW5kICI3NzUiIGluIG1tCiAgICBhc3NlcnQgcGxhdXNpYmxlKCJLWFFWUVFLVk1YUUdLT1FRViIsIDApIGlzIEZhbHNlCiAgICBhc3NlcnQgcGxhdXNpYmxlKCJLWFFWUVFLVk1YUUdLT1FRViIsIE5vbmUpIGlzIEZhbHNlCiAgICBhc3NlcnQgcGxhdXNpYmxlKCJEREg0NyBQSU5ORUJFUkcgV0VUVEVSIE5PUkQgMTIiLCAzKSBpcyBUcnVlCiAgICBpbXBvcnQgdGVtcGZpbGUKICAgIGQgPSB0ZW1wZmlsZS5ta2R0ZW1wKHByZWZpeD0icG5yeC0iKQogICAgdHJ5OgogICAgICAgIGRiID0gb3MucGF0aC5qb2luKGQsIERCX05BTUUpCiAgICAgICAgYXNzZXJ0IHN0b3JlKGRiLCAxXzcwMF8wMDBfMDAwLCBSRl9OSUdIVCwgTE9fSFogKyBSRl9OSUdIVCwgIktYUVZRUUtWTVhRR0tPUVFWIiwgMCkgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgc3RvcmUoZGIsIDFfNzAwXzAwMF8xMDAsIFJGX05JR0hULCBMT19IWiArIFJGX05JR0hULCAiRERINDcgUElOTkVCRVJHIFdFVFRFUiBOT1JEIDEyIiwgMikgaXMgVHJ1ZQogICAgICAgIGdvdCA9IHJlY2VudChkYiwgbm93PTFfNzAwXzAwMF8yMDApCiAgICAgICAgYXNzZXJ0IGdvdFsiZW1wZmFuZyJdIGlzIFRydWUgYW5kICJQSU5ORUJFUkciIGluIGdvdFsidHh0Il0gYW5kIGdvdFsibWVzc2FnZXMiXVswXVsicmZfaHoiXSA9PSBSRl9OSUdIVAogICAgICAgIHN0YWxlID0gcmVjZW50KGRiLCBub3c9MV83MDBfMDAwXzIwMCArIDUwMDApCiAgICAgICAgYXNzZXJ0IHN0YWxlWyJlbXBmYW5nIl0gaXMgRmFsc2UgYW5kIHN0YWxlWyJ0eHQiXSA9PSAia2VpbiBFbXBmYW5nIgogICAgICAgIGNvbiA9IHNxbGl0ZTMuY29ubmVjdChkYikKICAgICAgICBhc3NlcnQgc3RyKGNvbi5leGVjdXRlKCJQUkFHTUEgam91cm5hbF9tb2RlIikuZmV0Y2hvbmUoKVswXSkubG93ZXIoKSA9PSAid2FsIgogICAgICAgIGNvbi5jbG9zZSgpCiAgICAgICAgY2FsbHMgPSBbXQogICAgICAgIHMgPSBTZXNzaW9uKCkKICAgICAgICBhc3NlcnQgcy5ib290KGQsIHNwYXduPWxhbWJkYSBhLCBiOiBjYWxscy5hcHBlbmQoKGEsIGIpKSBvciBvYmplY3QoKSwgc2VyaWFsPSIyIikgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgcy5ib290KGQsIHNwYXduPWxhbWJkYSBhLCBiOiBjYWxscy5hcHBlbmQoKGEsIGIpKSBvciBvYmplY3QoKSwgc2VyaWFsPSI5MDAwMDAwMyIpIGlzIFRydWUKICAgICAgICBhc3NlcnQgY2FsbHMgYW5kIGNhbGxzWzBdWzBdWzBdID09ICJydGxfZm0iIGFuZCAiLVQiIG5vdCBpbiBjYWxsc1swXVswXQogICAgICAgIGFzc2VydCBzLmJvb3QoZCwgc3Bhd249bGFtYmRhIGEsIGI6IGNhbGxzLmFwcGVuZCgoYSwgYikpIG9yIG9iamVjdCgpLCBzZXJpYWw9IjkwMDAwMDAzIikgaXMgRmFsc2UKICAgIGZpbmFsbHk6CiAgICAgICAgaW1wb3J0IHNodXRpbAogICAgICAgIHNodXRpbC5ybXRyZWUoZCwgaWdub3JlX2Vycm9ycz1UcnVlKQogICAgYXNzZXJ0IHBsYW5fZFsiYmF1ZCJdID09IDUwCiAgICByZXR1cm4gInBpbm5lYmVyZ0VtcGZhbmcgb2sgKDE0NywzIGtIeiBuYWNodHMsIDc2NDYga0h6IHRhZ3MsIDEga0h6IHVudGVyIGRlciBNaXR0ZSwgMTIga1MvcywgQmF1ZG90IDUwLCBSYXVzY2hlbiB2ZXJ3b3JmZW4sIFdBTCwga2VpbiBCaWFzLCBrZWluIEluZGV4KSIKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgcHJpbnQoc2VsZnRlc3QoKSkK", "new": "IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoiIiJQaW5uZWJlcmcgU3R1ZmUgMjogUlRUWS1FbXBmYW5nIHBsYW5lbiwgZmlsdGVybiwgc3BlaWNoZXJuLiBLZWluIEdlcmFldCBpbiBkZW4gVGVzdHMuCgpLZXR0ZSwgd2VubiBkZXIgUHJvemVzcyBzaWUgd2lya2xpY2ggc3RhcnRldDogcnRsX2ZtIC1NIHVzYiwgZXR3YSAxIGtIeiB1bnRlciBkZXIKU3B5VmVydGVyLU1pdHRlLCAxMiBrUy9zLCBkYW5uIG1pbmltb2RlbSAtLXJ4IDUwIC0tYmF1ZG90LiBNYXJrIHVuZCBTcGFjZSB3ZXJkZW4KZ2V0YXVzY2h0LCB3ZW5uIGRpZSBlaW5lIExhZ2UgbnVyIE11ZWxsIGxpZWZlcnQuIEVzIHdpcmQga2VpbiBUZXN0IGF1c2dlbG9lc3QgdW5kCm5pY2h0cyBnZXNlbmRldC4gU2VyaWVubnVtbWVybiBzdGVoZW4gbmljaHQgaW4gZGllc2VyIERhdGVpLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzcWxpdGUzCmltcG9ydCB0aW1lCmZyb20gZGF0ZXRpbWUgaW1wb3J0IGRhdGV0aW1lCgp0cnk6CiAgICBmcm9tIHpvbmVpbmZvIGltcG9ydCBab25lSW5mbwpleGNlcHQgRXhjZXB0aW9uOgogICAgWm9uZUluZm8gPSBOb25lCgpSRl9OSUdIVCA9IDE0NzMwMApSRl9EQVkgPSA3NjQ2MDAwCkxPX0haID0gMTIwMDAwMDAwCkJFTE9XX0haID0gMTAwMApSQVRFID0gMTIwMDAKQkFVRCA9IDUwCk1BUktfSFogPSAxMjI1ClNQQUNFX0haID0gNzc1Ck5JR0hUX1NUQVJUID0gMTggKiA2MApOSUdIVF9FTkQgPSA2ICogNjAKREJfTkFNRSA9ICJsYWdlemVudHJ1bS5kYiIKQkFDS09GRl9TID0gMzAKV0FJVF9TID0gNQpMT0dfR0FQX1MgPSAzMAoKCmRlZiBfaG0odGV4dCwgZGVmYXVsdCk6CiAgICB0cnk6CiAgICAgICAgaCwgbSA9IHN0cih0ZXh0KS5zcGxpdCgiOiIsIDEpCiAgICAgICAgZ290ID0gaW50KGgpICogNjAgKyBpbnQobSkKICAgIGV4Y2VwdCAoVHlwZUVycm9yLCBWYWx1ZUVycm9yLCBBdHRyaWJ1dGVFcnJvcik6CiAgICAgICAgcmV0dXJuIGRlZmF1bHQKICAgIHJldHVybiBnb3QgaWYgMCA8PSBnb3QgPCAyNCAqIDYwIGVsc2UgZGVmYXVsdAoKCmRlZiBwbGFuKG5vdz1Ob25lLCBjZmc9Tm9uZSk6CiAgICAiIiJOYWNodCAxNDcsMyBrSHosIFRhZyA3NjQ2IGtIei4gWmVpdGVuIHVuZCBGcmVxdWVuemVuIGtvbW1lbiBhdXMgZGVyIFJvbGxlbmRhdGVpLCBzb25zdCBkaWUgVm9yZ2FiZW4uIiIiCiAgICBjZmcgPSBjZmcgb3Ige30KICAgIG5vdyA9IHRpbWUudGltZSgpIGlmIG5vdyBpcyBOb25lIGVsc2UgZmxvYXQobm93KQogICAgaWYgWm9uZUluZm8gaXMgbm90IE5vbmU6CiAgICAgICAgZHQgPSBkYXRldGltZS5mcm9tdGltZXN0YW1wKG5vdywgWm9uZUluZm8oIkV1cm9wZS9CZXJsaW4iKSkKICAgIGVsc2U6CiAgICAgICAgZHQgPSBkYXRldGltZS5mcm9tdGltZXN0YW1wKG5vdykKICAgIG1pbnV0ZSA9IGR0LmhvdXIgKiA2MCArIGR0Lm1pbnV0ZQogICAgc3RhcnQgPSBfaG0oY2ZnLmdldCgibmlnaHRfc3RhcnQiKSwgTklHSFRfU1RBUlQpCiAgICBlbmQgPSBfaG0oY2ZnLmdldCgibmlnaHRfZW5kIiksIE5JR0hUX0VORCkKICAgIG5pZ2h0ID0gbWludXRlID49IHN0YXJ0IG9yIG1pbnV0ZSA8IGVuZCBpZiBzdGFydCAhPSBlbmQgZWxzZSBGYWxzZQogICAgcmYgPSBpbnQoY2ZnLmdldCgicmZfbmlnaHRfaHoiKSBvciBSRl9OSUdIVCkgaWYgbmlnaHQgZWxzZSBpbnQoY2ZnLmdldCgicmZfZGF5X2h6Iikgb3IgUkZfREFZKQogICAgbG8gPSBpbnQoY2ZnLmdldCgibG9faHoiKSBvciBMT19IWikKICAgIGJlbG93ID0gaW50KGNmZy5nZXQoInR1bmVfYmVsb3dfaHoiKSBvciBCRUxPV19IWikKICAgIHJldHVybiB7Im5pZ2h0IjogbmlnaHQsICJyZl9oeiI6IHJmLCAiaWZfaHoiOiBsbyArIHJmLCAidHVuZV9oeiI6IGxvICsgcmYgLSBiZWxvdywKICAgICAgICAgICAgInJhdGUiOiBpbnQoY2ZnLmdldCgicmF0ZSIpIG9yIFJBVEUpLCAiYmF1ZCI6IGludChjZmcuZ2V0KCJiYXVkIikgb3IgQkFVRCksCiAgICAgICAgICAgICJtYXJrX2h6IjogaW50KGNmZy5nZXQoIm1hcmtfaHoiKSBvciBNQVJLX0haKSwgInNwYWNlX2h6IjogaW50KGNmZy5nZXQoInNwYWNlX2h6Iikgb3IgU1BBQ0VfSFopfQoKCmRlZiBzZXJpYWxfb2soc2VyaWFsKToKICAgICIiInJ0bF9mbSBuaW1tdCBlaW5lIGtsZWluZSByZWluZSBaYWhsIGFscyBHZXJhZXRlaW5kZXguIEVpbmUgU2VyaWVubnVtbWVyIGJsZWlidCBlaW5lIFplaWNoZW5rZXR0ZS4iIiIKICAgIHMgPSBzdHIoc2VyaWFsIG9yICIiKS5zdHJpcCgpCiAgICBpZiBsZW4ocykgPCA0IG9yIGxlbihzKSA+IDMyIG9yIGFueShjIG5vdCBpbiAiMDEyMzQ1Njc4OUFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaIiBmb3IgYyBpbiBzLnVwcGVyKCkpOgogICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgcy5pc2RpZ2l0KCkgYW5kIGludChzKSA8IDMyOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuIFRydWUKCgpkZWYgcnRsX2FyZ3Yoc2VyaWFsLCB0dW5lX2h6LCByYXRlPVJBVEUpOgogICAgaWYgbm90IHNlcmlhbF9vayhzZXJpYWwpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoInNlcmllbm51bW1lciIpCiAgICBpZiBpbnQodHVuZV9oeikgPCAxMDAwMDAwIG9yICItVCIgaW4gc3RyKHNlcmlhbCk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigiYWJzdGltbXVuZyIpCiAgICByZXR1cm4gWyJydGxfZm0iLCAiLWQiLCBzdHIoc2VyaWFsKSwgIi1mIiwgc3RyKGludCh0dW5lX2h6KSksICItTSIsICJ1c2IiLCAiLXMiLCBzdHIoaW50KHJhdGUpKSwgIi1yIiwgc3RyKGludChyYXRlKSldCgoKZGVmIG1pbmltb2RlbV9hcmd2KG1hcms9TUFSS19IWiwgc3BhY2U9U1BBQ0VfSFosIGJhdWQ9QkFVRCk6CiAgICByZXR1cm4gWyJtaW5pbW9kZW0iLCAiLS1yeCIsIHN0cihpbnQoYmF1ZCkpLCAiLS1iYXVkb3QiLCAiLU0iLCBzdHIoaW50KG1hcmspKSwgIi1TIiwgc3RyKGludChzcGFjZSkpXQoKCmRlZiBwbGF1c2libGUodGV4dCwgYW1wbD1Ob25lKToKICAgICIiIlJhdXNjaGVuIHdpZSBLWFFWUVFLVk1YUUdLT1FRViBiZWkgYW1wbD0wIGJsZWlidCBkcmF1c3Nlbi4gS2VpbiBBbGFybS4iIiIKICAgIGlmIGFtcGwgaXMgbm90IE5vbmU6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBpZiBmbG9hdChhbXBsKSA8PSAwOgogICAgICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgZXhjZXB0IChUeXBlRXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgIHQgPSAiICIuam9pbigiIi5qb2luKGNoIGlmIGNoLmlzcHJpbnRhYmxlKCkgZWxzZSAiICIgZm9yIGNoIGluIHN0cih0ZXh0IG9yICIiKSkuc3BsaXQoKSkKICAgIGxldHRlcnMgPSBbYyBmb3IgYyBpbiB0LnVwcGVyKCkgaWYgIkEiIDw9IGMgPD0gIloiXQogICAgaWYgbGVuKHQpIDwgMTIgb3IgbGVuKGxldHRlcnMpIDwgODoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHZvd2VscyA9IHN1bShjIGluICJBRUlPVVkiIGZvciBjIGluIGxldHRlcnMpCiAgICByYXJlID0gc3VtKGMgaW4gIlFYWkpLViIgZm9yIGMgaW4gbGV0dGVycykKICAgIHNwYWNlcyA9IHQuY291bnQoIiAiKQogICAgZGlnaXRzID0gc3VtKGMuaXNkaWdpdCgpIGZvciBjIGluIHQpCiAgICBpZiBzcGFjZXMgPT0gMCBhbmQgcmFyZSA+PSA0IGFuZCB2b3dlbHMgPD0gMyBhbmQgZGlnaXRzIDwgNDoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGlmIHNwYWNlcyA9PSAwIGFuZCBkaWdpdHMgPCA0IGFuZCB2b3dlbHMgKiA1IDwgbGVuKGxldHRlcnMpOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuIFRydWUKCgpkZWYgX2NvbihwYXRoKToKICAgIGNvbiA9IHNxbGl0ZTMuY29ubmVjdChwYXRoLCB0aW1lb3V0PTUpCiAgICBtb2RlID0gY29uLmV4ZWN1dGUoIlBSQUdNQSBqb3VybmFsX21vZGU9V0FMIikuZmV0Y2hvbmUoKQogICAgaWYgbW9kZSBpcyBOb25lIG9yIHN0cihtb2RlWzBdKS5sb3dlcigpICE9ICJ3YWwiOgogICAgICAgIGNvbi5jbG9zZSgpCiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCJ3YWwiKQogICAgY29uLmV4ZWN1dGUoIlBSQUdNQSBzeW5jaHJvbm91cz1OT1JNQUwiKQogICAgY29uLmV4ZWN1dGUoIkNSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RTIHBpbm5lYmVyZ19tc2cgKCIKICAgICAgICAgICAgICAgICJpZCBJTlRFR0VSIFBSSU1BUlkgS0VZIEFVVE9JTkNSRU1FTlQsIHRzIElOVEVHRVIgTk9UIE5VTEwsIHJmX2h6IElOVEVHRVIgTk9UIE5VTEwsICIKICAgICAgICAgICAgICAgICJpZl9oeiBJTlRFR0VSIE5PVCBOVUxMLCB0ZXh0IFRFWFQgTk9UIE5VTEwsIHF1YWxpdHkgUkVBTCkiKQogICAgcmV0dXJuIGNvbgoKCmRlZiBzdG9yZShwYXRoLCB0cywgcmZfaHosIGlmX2h6LCB0ZXh0LCBxdWFsaXR5PU5vbmUpOgogICAgaWYgbm90IHBsYXVzaWJsZSh0ZXh0LCBxdWFsaXR5KToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGNvbiA9IF9jb24ocGF0aCkKICAgIHRyeToKICAgICAgICBjb24uZXhlY3V0ZSgiSU5TRVJUIElOVE8gcGlubmViZXJnX21zZyAodHMsIHJmX2h6LCBpZl9oeiwgdGV4dCwgcXVhbGl0eSkgVkFMVUVTICg/LD8sPyw/LD8pIiwKICAgICAgICAgICAgICAgICAgICAoaW50KHRzKSwgaW50KHJmX2h6KSwgaW50KGlmX2h6KSwgIiAiLmpvaW4oc3RyKHRleHQpLnNwbGl0KCkpWzo0MDBdLCBOb25lIGlmIHF1YWxpdHkgaXMgTm9uZSBlbHNlIGZsb2F0KHF1YWxpdHkpKSkKICAgICAgICBjb24uY29tbWl0KCkKICAgIGZpbmFsbHk6CiAgICAgICAgY29uLmNsb3NlKCkKICAgIHJldHVybiBUcnVlCgoKZGVmIHJlY2VudChwYXRoLCBsaW1pdD01LCBub3c9Tm9uZSwgZnJlc2hfcz05MDApOgogICAgIiIiTGV0enRlIHBsYXVzaWJsZSBCbG9lY2tlLiBPaG5lIGZyaXNjaGVuIEJsb2NrOiBrZWluIEVtcGZhbmcsIG5pZSBlaW5lIFdhcm51bmcuIiIiCiAgICB0cnk6CiAgICAgICAgY29uID0gX2NvbihwYXRoKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4geyJlbXBmYW5nIjogRmFsc2UsICJ0eHQiOiAia2VpbiBFbXBmYW5nIiwgIm1lc3NhZ2VzIjogW119CiAgICB0cnk6CiAgICAgICAgcm93cyA9IGNvbi5leGVjdXRlKCJTRUxFQ1QgdHMsIHJmX2h6LCB0ZXh0LCBxdWFsaXR5IEZST00gcGlubmViZXJnX21zZyBPUkRFUiBCWSBpZCBERVNDIExJTUlUID8iLCAoaW50KGxpbWl0KSwpKS5mZXRjaGFsbCgpCiAgICBmaW5hbGx5OgogICAgICAgIGNvbi5jbG9zZSgpCiAgICBub3cgPSB0aW1lLnRpbWUoKSBpZiBub3cgaXMgTm9uZSBlbHNlIGZsb2F0KG5vdykKICAgIG1lc3NhZ2VzID0gW3sidCI6IGludChyWzBdKSwgInJmX2h6IjogaW50KHJbMV0pLCAidGV4dCI6IHJbMl0sICJxdWFsaXR5IjogclszXX0gZm9yIHIgaW4gcm93c10KICAgIGZyZXNoID0gW20gZm9yIG0gaW4gbWVzc2FnZXMgaWYgbm93IC0gbVsidCJdIDw9IGZyZXNoX3NdCiAgICBpZiBub3QgZnJlc2g6CiAgICAgICAgcmV0dXJuIHsiZW1wZmFuZyI6IEZhbHNlLCAidHh0IjogImtlaW4gRW1wZmFuZyIsICJtZXNzYWdlcyI6IG1lc3NhZ2VzfQogICAgcmV0dXJuIHsiZW1wZmFuZyI6IFRydWUsICJ0eHQiOiBmcmVzaFswXVsidGV4dCJdLCAibWVzc2FnZXMiOiBtZXNzYWdlc30KCgpjbGFzcyBTZXNzaW9uOgogICAgIiIiRWluIEVtcGZhZW5nZXIuIFRlc3RzIHVlYmVyZ2ViZW4gZWluZSBBdHRyYXBwZSB1bmQgb2VmZm5lbiBrZWluIEdlcmFldC4iIiIKCiAgICBkZWYgX19pbml0X18oc2VsZik6CiAgICAgICAgc2VsZi5wcm9jID0gTm9uZQogICAgICAgIHNlbGYuaW52ZXJzaW9uID0gMAogICAgICAgIHNlbGYubGFzdF9nb29kID0gMAogICAgICAgIHNlbGYuX2hhbHQgPSBGYWxzZQogICAgICAgIHNlbGYuX3RocmVhZCA9IE5vbmUKICAgICAgICBzZWxmLl9sb2dfYXQgPSB7fQogICAgICAgIHNlbGYuc2Vlbl9mbiA9IE5vbmUKCiAgICBkZWYgYXJndihzZWxmLCBzZXJpYWwsIG5vdz1Ob25lLCBjZmc9Tm9uZSk6CiAgICAgICAgcCA9IHBsYW4obm93LCBjZmcpCiAgICAgICAgcnRsID0gcnRsX2FyZ3Yoc2VyaWFsLCBwWyJ0dW5lX2h6Il0sIHBbInJhdGUiXSkKICAgICAgICBtYXJrLCBzcGFjZSA9IChwWyJtYXJrX2h6Il0sIHBbInNwYWNlX2h6Il0pIGlmIHNlbGYuaW52ZXJzaW9uICUgMiA9PSAwIGVsc2UgKHBbInNwYWNlX2h6Il0sIHBbIm1hcmtfaHoiXSkKICAgICAgICBpZiAiLVQiIGluIHJ0bCBvciBhbnkoeCBpbiBydGwgZm9yIHggaW4gKCItVCIsICItLWJpYXMiKSk6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigiYmlhcyIpCiAgICAgICAgcmV0dXJuIHJ0bCwgbWluaW1vZGVtX2FyZ3YobWFyaywgc3BhY2UsIHBbImJhdWQiXSksIHAKCiAgICBkZWYgam91cm5hbChzZWxmLCB0ZXh0LCBub3c9Tm9uZSk6CiAgICAgICAgIiIiRWluZSBaZWlsZSBpbnMgSm91cm5hbCBkZXMgU0RSLURpZW5zdGVzLCBLZW5udW5nIHBpbm5lYmVyZywgaG9lY2hzdGVucyBhbGxlIDMwIHMgamUgQXJ0LiIiIgogICAgICAgIG5vdyA9IHRpbWUudGltZSgpIGlmIG5vdyBpcyBOb25lIGVsc2UgZmxvYXQobm93KQogICAgICAgIGtleSA9IHN0cih0ZXh0KS5zcGxpdCgiOiIsIDEpWzBdWzoyNF0KICAgICAgICBpZiBub3cgLSBzZWxmLl9sb2dfYXQuZ2V0KGtleSwgMC4wKSA8IExPR19HQVBfUzoKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgc2VsZi5fbG9nX2F0W2tleV0gPSBub3cKICAgICAgICBwcmludCgicGlubmViZXJnOiAlcyIgJSAiICIuam9pbihzdHIodGV4dCkuc3BsaXQoKSlbOjIwMF0sIGZsdXNoPVRydWUpCiAgICAgICAgcmV0dXJuIFRydWUKCiAgICBkZWYgc3RpY2tfZGEoc2VsZiwgc2VyaWFsLCBzZWVuKToKICAgICAgICAiIiJUcnVlLCB3ZW5uIGdlbmF1IGRpZXNlIFNlcmllbm51bW1lciBpbiBkZXIgVVNCLUxpc3RlIHN0ZWh0LiBFaW4gZmVobGVuZGVyIFN0aWNrIDIgemFlaGx0IG5pY2h0LiIiIgogICAgICAgIGlmIG5vdCBzZXJpYWxfb2soc2VyaWFsKToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgcmV0dXJuIGFueShpc2luc3RhbmNlKHgsIGRpY3QpIGFuZCBzdHIoeC5nZXQoInNlcmlhbCIpIG9yICIiKSA9PSBzdHIoc2VyaWFsKSBmb3IgeCBpbiAoc2VlbiBvciBbXSkpCgogICAgZGVmIG93bmVyKHNlbGYsIGJhc2UpOgogICAgICAgICIiIlNlcmllbm51bW1lciBhdXMgZGVtIFJlZ2lzdGVyIHVuZCBkaWUgUm9sbGVuZGF0ZWkuIE5vbmUsIHNvbGFuZ2UgRW1wZmFuZyBuaWNodCBmcmVpZ2VnZWJlbiBpc3QuIiIiCiAgICAgICAgdHJ5OgogICAgICAgICAgICBpbXBvcnQgcGlubmViZXJnX3JvbGxlIGFzIHJvbGxlCiAgICAgICAgICAgIGltcG9ydCBwcmVwcGVyX3NkciBhcyBwcwogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHJldHVybiBOb25lLCBOb25lCiAgICAgICAgZG9jID0gcm9sbGUubG9hZChiYXNlKSBvciB7fQogICAgICAgIGlmIG5vdCAocm9sbGUuZW5nYWdlZChiYXNlKSBhbmQgaW50KGRvYy5nZXQoInN0dWZlIikgb3IgMCkgPj0gMiBhbmQgZG9jLmdldCgiZW1wZmFuZyIpIGlzIFRydWUgYW5kIG5vdCBkb2MuZ2V0KCJiaWFzX3RlZSIpKToKICAgICAgICAgICAgcmV0dXJuIE5vbmUsIE5vbmUKICAgICAgICByZWcgPSAocHMuYWlyX3JlZyhwcy5jb25maWcoYmFzZSkpIG9yIHt9KS5nZXQoImJ5X3JvbGUiKSBvciB7fQogICAgICAgIGVudHJ5ID0gcmVnLmdldCgiaG9iYnkyIikgaWYgaXNpbnN0YW5jZShyZWcuZ2V0KCJob2JieTIiKSwgZGljdCkgZWxzZSBOb25lCiAgICAgICAgc2VyaWFsID0gKGVudHJ5IG9yIHt9KS5nZXQoInNlcmlhbCIpCiAgICAgICAgaWYgbm90IHNlcmlhbF9vayhzZXJpYWwpOgogICAgICAgICAgICByZXR1cm4gTm9uZSwgTm9uZQogICAgICAgIHJldHVybiBzdHIoc2VyaWFsKSwgZG9jCgogICAgZGVmIHByZXNlbnQoc2VsZiwgc2VyaWFsKToKICAgICAgICBpZiBzZWxmLnNlZW5fZm4gaXMgbm90IE5vbmU6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHNlZW4gPSBzZWxmLnNlZW5fZm4oKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgZWxzZToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgaW1wb3J0IHByZXBwZXJfc2RyIGFzIHBzCiAgICAgICAgICAgICAgICBzZWVuID0gcHMuc3RpY2tfaW5mbygoIjBiZGE6MjgzOCIsICIwYmRhOjI4MzIiKSkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgICAgIHJldHVybiBzZWxmLnN0aWNrX2RhKHNlcmlhbCwgc2VlbikKCiAgICBkZWYgcmVhcChzZWxmLCBwcm9jKToKICAgICAgICAiIiJydGxfZm0gdW5kIG1pbmltb2RlbSBlaW5zYW1tZWxuLCBhdWNoIHdlbm4gc2llIHNjaG9uIFpvbWJpZXMgc2luZC4iIiIKICAgICAgICBpZiBwcm9jIGlzIE5vbmU6CiAgICAgICAgICAgIHJldHVybgogICAgICAgIGZvciBwIGluIChwcm9jLCBnZXRhdHRyKHByb2MsICJfcnRsIiwgTm9uZSkpOgogICAgICAgICAgICBpZiBwIGlzIE5vbmU6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBpZiBoYXNhdHRyKHAsICJwb2xsIikgYW5kIHAucG9sbCgpIGlzIE5vbmUgYW5kIGhhc2F0dHIocCwgInRlcm1pbmF0ZSIpOgogICAgICAgICAgICAgICAgICAgIHAudGVybWluYXRlKCkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHBhc3MKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgaWYgaGFzYXR0cihwLCAid2FpdCIpOgogICAgICAgICAgICAgICAgICAgIHAud2FpdCh0aW1lb3V0PTIpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgaWYgaGFzYXR0cihwLCAia2lsbCIpOgogICAgICAgICAgICAgICAgICAgICAgICBwLmtpbGwoKQogICAgICAgICAgICAgICAgICAgIGlmIGhhc2F0dHIocCwgIndhaXQiKToKICAgICAgICAgICAgICAgICAgICAgICAgcC53YWl0KHRpbWVvdXQ9MikKICAgICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICAgICAgcGFzcwoKICAgIGRlZiBfZXJyKHNlbGYsIHN0cmVhbSwgbmFtZSk6CiAgICAgICAgaWYgc3RyZWFtIGlzIE5vbmU6CiAgICAgICAgICAgIHJldHVybgogICAgICAgIHRyeToKICAgICAgICAgICAgd2hpbGUgVHJ1ZToKICAgICAgICAgICAgICAgIHJhdyA9IHN0cmVhbS5yZWFkbGluZSgpCiAgICAgICAgICAgICAgICBpZiByYXcgaXMgTm9uZSBvciByYXcgPT0gIiIgb3IgcmF3ID09IGIiIjoKICAgICAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICAgICAgdGV4dCA9IHJhdy5kZWNvZGUoInV0Zi04IiwgInJlcGxhY2UiKSBpZiBpc2luc3RhbmNlKHJhdywgYnl0ZXMpIGVsc2Ugc3RyKHJhdykKICAgICAgICAgICAgICAgIHRleHQgPSB0ZXh0LnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIHRleHQ6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5qb3VybmFsKCIlczogJXMiICUgKG5hbWUsIHRleHQpKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHBhc3MKICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBzdHJlYW0uY2xvc2UoKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcGFzcwoKICAgIGRlZiBfc3Bhd24oc2VsZiwgcnRsLCBtbSk6CiAgICAgICAgaW1wb3J0IHN1YnByb2Nlc3MKICAgICAgICBpbXBvcnQgdGhyZWFkaW5nCiAgICAgICAgc3JjID0gc3VicHJvY2Vzcy5Qb3BlbihydGwsIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHN0ZGVycj1zdWJwcm9jZXNzLlBJUEUpCiAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5Qb3BlbihtbSwgc3RkaW49c3JjLnN0ZG91dCwgc3Rkb3V0PXN1YnByb2Nlc3MuUElQRSwgc3RkZXJyPXN1YnByb2Nlc3MuUElQRSwgdGV4dD1UcnVlKQogICAgICAgIGlmIHNyYy5zdGRvdXQ6CiAgICAgICAgICAgIHNyYy5zdGRvdXQuY2xvc2UoKQogICAgICAgIG91dC5fcnRsID0gc3JjCiAgICAgICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9c2VsZi5fZXJyLCBhcmdzPShzcmMuc3RkZXJyLCAicnRsX2ZtIiksIGRhZW1vbj1UcnVlKS5zdGFydCgpCiAgICAgICAgaWYgb3V0LnN0ZGVyciBpcyBub3QgTm9uZToKICAgICAgICAgICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9c2VsZi5fZXJyLCBhcmdzPShvdXQuc3RkZXJyLCAibWluaW1vZGVtIiksIGRhZW1vbj1UcnVlKS5zdGFydCgpCiAgICAgICAgcmV0dXJuIG91dAoKICAgIGRlZiBzdGFydChzZWxmLCBiYXNlKToKICAgICAgICAiIiJXYWVjaHRlcmZhZGVuLiBXYXJ0ZXQgYXVmIFN0aWNrIDMsIHN0YXJ0ZXQgbmV1LCBzYW1tZWx0IFpvbWJpZXMuIEtlaW4gSW5kZXgsIGtlaW4gendlaXRlciBTdGFydC4iIiIKICAgICAgICBpbXBvcnQgdGhyZWFkaW5nCiAgICAgICAgaWYgc2VsZi5fdGhyZWFkIGlzIG5vdCBOb25lOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBzZWxmLl9oYWx0ID0gRmFsc2UKICAgICAgICBzZWxmLl90aHJlYWQgPSB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1zZWxmLl9zdXBlcnZpc2UsIGFyZ3M9KGJhc2UsKSwgZGFlbW9uPVRydWUpCiAgICAgICAgc2VsZi5fdGhyZWFkLnN0YXJ0KCkKICAgICAgICByZXR1cm4gVHJ1ZQoKICAgIGRlZiBjeWNsZShzZWxmLCBiYXNlKToKICAgICAgICAiIiJFaW4gRHVyY2hsYXVmOiB3YXJ0ZW4sIHN0YXJ0ZW4sIGxlc2VuLCBlaW5zYW1tZWxuLiBEZXIgV2FlY2h0ZXIgcnVmdCBkYXMgaW4gZWluZXIgU2NobGVpZmUuIiIiCiAgICAgICAgc2VyaWFsLCBjZmcgPSBzZWxmLm93bmVyKGJhc2UpCiAgICAgICAgaWYgbm90IHNlcmlhbDoKICAgICAgICAgICAgcmV0dXJuICJhdXMiCiAgICAgICAgaWYgbm90IHNlbGYucHJlc2VudChzZXJpYWwpOgogICAgICAgICAgICBzZWxmLmpvdXJuYWwoIndhcnRlIGF1ZiBTdGljayAzIikKICAgICAgICAgICAgcmV0dXJuICJ3YXJ0ZSIKICAgICAgICB0cnk6CiAgICAgICAgICAgIGlmIHNlbGYucHJvYyBpcyBub3QgTm9uZToKICAgICAgICAgICAgICAgIHNlbGYucmVhcChzZWxmLnByb2MpCiAgICAgICAgICAgICAgICBzZWxmLnByb2MgPSBOb25lCiAgICAgICAgICAgIGlmIG5vdCBzZWxmLmJvb3QoYmFzZSwgc3Bhd249c2VsZi5fc3Bhd24sIHNlcmlhbD1zZXJpYWwsIGNmZz1jZmcpOgogICAgICAgICAgICAgICAgc2VsZi5qb3VybmFsKCJTdGFydCBuaWNodCBtb2VnbGljaCIpCiAgICAgICAgICAgICAgICByZXR1cm4gImZlaGxlciIKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzoKICAgICAgICAgICAgc2VsZi5qb3VybmFsKCJTdGFydCAlcyIgJSB0eXBlKGV4YykuX19uYW1lX18pCiAgICAgICAgICAgIHNlbGYucmVhcChzZWxmLnByb2MpCiAgICAgICAgICAgIHNlbGYucHJvYyA9IE5vbmUKICAgICAgICAgICAgcmV0dXJuICJmZWhsZXIiCiAgICAgICAgc2VsZi5fcmVhZChiYXNlLCBjZmcpCiAgICAgICAgc2VsZi5yZWFwKHNlbGYucHJvYykKICAgICAgICBzZWxmLnByb2MgPSBOb25lCiAgICAgICAgc2VsZi5qb3VybmFsKCJQaXBlbGluZSBiZWVuZGV0LCBuZXVlciBTdGFydCBpbiAlZCBzIiAlIEJBQ0tPRkZfUykKICAgICAgICByZXR1cm4gIm5ldSIKCiAgICBkZWYgX3N1cGVydmlzZShzZWxmLCBiYXNlKToKICAgICAgICB3aGlsZSBub3Qgc2VsZi5faGFsdDoKICAgICAgICAgICAgc3RhdGUgPSBzZWxmLmN5Y2xlKGJhc2UpCiAgICAgICAgICAgIGlmIHNlbGYuX2hhbHQ6CiAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICBzZWxmLl9wYXVzZShXQUlUX1MgaWYgc3RhdGUgaW4gKCJhdXMiLCAid2FydGUiKSBlbHNlIEJBQ0tPRkZfUykKCiAgICBkZWYgX3BhdXNlKHNlbGYsIHNlY29uZHMpOgogICAgICAgIGVuZCA9IHRpbWUudGltZSgpICsgZmxvYXQoc2Vjb25kcykKICAgICAgICB3aGlsZSBub3Qgc2VsZi5faGFsdCBhbmQgdGltZS50aW1lKCkgPCBlbmQ6CiAgICAgICAgICAgIHRpbWUuc2xlZXAobWluKDEuMCwgbWF4KDAuMCwgZW5kIC0gdGltZS50aW1lKCkpKSkKCiAgICBkZWYgX3JlYWQoc2VsZiwgYmFzZSwgY2ZnKToKICAgICAgICBwcm9jID0gc2VsZi5wcm9jCiAgICAgICAgaWYgcHJvYyBpcyBOb25lIG9yIHByb2Muc3Rkb3V0IGlzIE5vbmU6CiAgICAgICAgICAgIHJldHVybgogICAgICAgIHAgPSBwbGFuKGNmZz1jZmcpCiAgICAgICAgZGIgPSBvcy5wYXRoLmpvaW4oYmFzZSwgREJfTkFNRSkKICAgICAgICB0cnk6CiAgICAgICAgICAgIGZvciBsaW5lIGluIHByb2Muc3Rkb3V0OgogICAgICAgICAgICAgICAgaWYgc3RvcmUoZGIsIHRpbWUudGltZSgpLCBwWyJyZl9oeiJdLCBwWyJpZl9oeiJdLCBsaW5lLCBOb25lKToKICAgICAgICAgICAgICAgICAgICBzZWxmLmxhc3RfZ29vZCA9IHRpbWUudGltZSgpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwoKICAgIGRlZiBib290KHNlbGYsIGJhc2UsIHNwYXduPU5vbmUsIHNlcmlhbD1Ob25lLCBjZmc9Tm9uZSk6CiAgICAgICAgIiIiU3RhcnQgbnVyIG1pdCBhdXNkcnVlY2tsaWNoZW0gc3Bhd24uIERlciBQcm9kdWt0aXZzdGFydCB1ZWJlcmdpYnQgc3VicHJvY2Vzcy4iIiIKICAgICAgICBpZiBzcGF3biBpcyBOb25lIG9yIHNlbGYucHJvYyBpcyBub3QgTm9uZToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgaWYgbm90IHNlcmlhbF9vayhzZXJpYWwpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBydGwsIG1tLCBfcCA9IHNlbGYuYXJndihzZXJpYWwsIGNmZz1jZmcpCiAgICAgICAgc2VsZi5wcm9jID0gc3Bhd24ocnRsLCBtbSkKICAgICAgICByZXR1cm4gVHJ1ZQoKICAgIGRlZiBzdG9wKHNlbGYpOgogICAgICAgIHNlbGYuX2hhbHQgPSBUcnVlCiAgICAgICAgcHJvYywgc2VsZi5wcm9jID0gc2VsZi5wcm9jLCBOb25lCiAgICAgICAgc2VsZi5yZWFwKHByb2MpCgoKU0VTUyA9IFNlc3Npb24oKQoKCmRlZiBzZWxmdGVzdCgpOgogICAgb3MuZW52aXJvbi5wb3AoIlBJTk5FQkVSR19TRVJJQUwiLCBOb25lKQogICAgcCA9IHBsYW4oZGF0ZXRpbWUoMjAyNiwgMTEsIDEyLCAyMywgMCwgdHppbmZvPVpvbmVJbmZvKCJFdXJvcGUvQmVybGluIikpLnRpbWVzdGFtcCgpIGlmIFpvbmVJbmZvIGVsc2UgMV83MDBfMDAwXzAwMCkKICAgIGFzc2VydCBwWyJyZl9oeiJdID09IFJGX05JR0hUIGFuZCBwWyJpZl9oeiJdID09IExPX0haICsgUkZfTklHSFQgYW5kIHBbInR1bmVfaHoiXSA9PSBwWyJpZl9oeiJdIC0gQkVMT1dfSFoKICAgIGRheSA9IHBsYW4oZGF0ZXRpbWUoMjAyNiwgMTEsIDEyLCAxMiwgMCwgdHppbmZvPVpvbmVJbmZvKCJFdXJvcGUvQmVybGluIikpLnRpbWVzdGFtcCgpKQogICAgYXNzZXJ0IGRheVsibmlnaHQiXSBpcyBGYWxzZSBhbmQgZGF5WyJyZl9oeiJdID09IFJGX0RBWSBhbmQgZGF5WyJ0dW5lX2h6Il0gPT0gTE9fSFogKyBSRl9EQVkgLSAxMDAwCiAgICBhc3NlcnQgc2VyaWFsX29rKCI5MDAwMDAwMyIpIGFuZCBub3Qgc2VyaWFsX29rKCIyIikgYW5kIG5vdCBzZXJpYWxfb2soIiIpIGFuZCBub3Qgc2VyaWFsX29rKCItVCIpCiAgICBydGwsIG1tLCBwbGFuX2QgPSBTRVNTLmFyZ3YoIjkwMDAwMDAzIiwgZGF5WyJ0dW5lX2h6Il0gYW5kIGRhdGV0aW1lKDIwMjYsIDExLCAxMiwgMTIsIDAsIHR6aW5mbz1ab25lSW5mbygiRXVyb3BlL0JlcmxpbiIpKS50aW1lc3RhbXAoKSkKICAgIGFzc2VydCBydGxbOjRdID09IFsicnRsX2ZtIiwgIi1kIiwgIjkwMDAwMDAzIiwgIi1mIl0gYW5kIHJ0bFs0XSA9PSBzdHIoZGF5WyJ0dW5lX2h6Il0pIGFuZCAiLVQiIG5vdCBpbiBydGwKICAgIGFzc2VydCBtbVs6NF0gPT0gWyJtaW5pbW9kZW0iLCAiLS1yeCIsICI1MCIsICItLWJhdWRvdCJdIGFuZCAiMTIyNSIgaW4gbW0gYW5kICI3NzUiIGluIG1tCiAgICBhc3NlcnQgcGxhdXNpYmxlKCJLWFFWUVFLVk1YUUdLT1FRViIsIDApIGlzIEZhbHNlCiAgICBhc3NlcnQgcGxhdXNpYmxlKCJLWFFWUVFLVk1YUUdLT1FRViIsIE5vbmUpIGlzIEZhbHNlCiAgICBhc3NlcnQgcGxhdXNpYmxlKCJEREg0NyBQSU5ORUJFUkcgV0VUVEVSIE5PUkQgMTIiLCAzKSBpcyBUcnVlCiAgICBpbXBvcnQgdGVtcGZpbGUKICAgIGQgPSB0ZW1wZmlsZS5ta2R0ZW1wKHByZWZpeD0icG5yeC0iKQogICAgdHJ5OgogICAgICAgIGRiID0gb3MucGF0aC5qb2luKGQsIERCX05BTUUpCiAgICAgICAgYXNzZXJ0IHN0b3JlKGRiLCAxXzcwMF8wMDBfMDAwLCBSRl9OSUdIVCwgTE9fSFogKyBSRl9OSUdIVCwgIktYUVZRUUtWTVhRR0tPUVFWIiwgMCkgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgc3RvcmUoZGIsIDFfNzAwXzAwMF8xMDAsIFJGX05JR0hULCBMT19IWiArIFJGX05JR0hULCAiRERINDcgUElOTkVCRVJHIFdFVFRFUiBOT1JEIDEyIiwgMikgaXMgVHJ1ZQogICAgICAgIGdvdCA9IHJlY2VudChkYiwgbm93PTFfNzAwXzAwMF8yMDApCiAgICAgICAgYXNzZXJ0IGdvdFsiZW1wZmFuZyJdIGlzIFRydWUgYW5kICJQSU5ORUJFUkciIGluIGdvdFsidHh0Il0gYW5kIGdvdFsibWVzc2FnZXMiXVswXVsicmZfaHoiXSA9PSBSRl9OSUdIVAogICAgICAgIHN0YWxlID0gcmVjZW50KGRiLCBub3c9MV83MDBfMDAwXzIwMCArIDUwMDApCiAgICAgICAgYXNzZXJ0IHN0YWxlWyJlbXBmYW5nIl0gaXMgRmFsc2UgYW5kIHN0YWxlWyJ0eHQiXSA9PSAia2VpbiBFbXBmYW5nIgogICAgICAgIGNvbiA9IHNxbGl0ZTMuY29ubmVjdChkYikKICAgICAgICBhc3NlcnQgc3RyKGNvbi5leGVjdXRlKCJQUkFHTUEgam91cm5hbF9tb2RlIikuZmV0Y2hvbmUoKVswXSkubG93ZXIoKSA9PSAid2FsIgogICAgICAgIGNvbi5jbG9zZSgpCiAgICAgICAgY2FsbHMgPSBbXQogICAgICAgIHMgPSBTZXNzaW9uKCkKICAgICAgICBhc3NlcnQgcy5ib290KGQsIHNwYXduPWxhbWJkYSBhLCBiOiBjYWxscy5hcHBlbmQoKGEsIGIpKSBvciBvYmplY3QoKSwgc2VyaWFsPSIyIikgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgcy5ib290KGQsIHNwYXduPWxhbWJkYSBhLCBiOiBjYWxscy5hcHBlbmQoKGEsIGIpKSBvciBvYmplY3QoKSwgc2VyaWFsPSI5MDAwMDAwMyIpIGlzIFRydWUKICAgICAgICBhc3NlcnQgY2FsbHMgYW5kIGNhbGxzWzBdWzBdWzBdID09ICJydGxfZm0iIGFuZCAiLVQiIG5vdCBpbiBjYWxsc1swXVswXQogICAgICAgIGFzc2VydCBzLmJvb3QoZCwgc3Bhd249bGFtYmRhIGEsIGI6IGNhbGxzLmFwcGVuZCgoYSwgYikpIG9yIG9iamVjdCgpLCBzZXJpYWw9IjkwMDAwMDAzIikgaXMgRmFsc2UKICAgICAgICB3ID0gU2Vzc2lvbigpCiAgICAgICAgYXNzZXJ0IHcuc3RpY2tfZGEoIjkwMDAwMDAzIiwgW3sic2VyaWFsIjogIjkwMDAwMDAzIn1dKSBpcyBUcnVlCiAgICAgICAgYXNzZXJ0IHcuc3RpY2tfZGEoIjkwMDAwMDAzIiwgW3sic2VyaWFsIjogIjkwMDAwMDAxIn1dKSBpcyBGYWxzZQogICAgICAgIGFzc2VydCB3LnN0aWNrX2RhKCIyIiwgW3sic2VyaWFsIjogIjIifV0pIGlzIEZhbHNlCiAgICAgICAgY2xhc3MgX1A6CiAgICAgICAgICAgIGRlZiBfX2luaXRfXyhzZWxmKToKICAgICAgICAgICAgICAgIHNlbGYud2FpdGVkID0gMAogICAgICAgICAgICAgICAgc2VsZi5zdGRvdXQgPSBpdGVyKCgpKQogICAgICAgICAgICBkZWYgcG9sbChzZWxmKToKICAgICAgICAgICAgICAgIHJldHVybiAxCiAgICAgICAgICAgIGRlZiB3YWl0KHNlbGYsIHRpbWVvdXQ9Tm9uZSk6CiAgICAgICAgICAgICAgICBzZWxmLndhaXRlZCArPSAxCiAgICAgICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHJ0bCwgbW0gPSBfUCgpLCBfUCgpCiAgICAgICAgbW0uX3J0bCA9IHJ0bAogICAgICAgIHcucmVhcChtbSkKICAgICAgICBhc3NlcnQgcnRsLndhaXRlZCA+IDAgYW5kIG1tLndhaXRlZCA+IDAKICAgICAgICBhc3NlcnQgdy5qb3VybmFsKCJydGxfZm06IHVzYiBjbGFpbSBmYWlsZWQiLCBub3c9MTAwKSBpcyBUcnVlCiAgICAgICAgYXNzZXJ0IHcuam91cm5hbCgicnRsX2ZtOiB1c2IgY2xhaW0gZmFpbGVkIiwgbm93PTExMCkgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgdy5qb3VybmFsKCJQaXBlbGluZSBiZWVuZGV0LCBuZXVlciBTdGFydCBpbiAzMCBzIiwgbm93PTExMCkgaXMgVHJ1ZQogICAgICAgIGxpbmVzID0gW10KICAgICAgICB3LmpvdXJuYWwgPSBsYW1iZGEgdGV4dCwgbm93PU5vbmU6IGxpbmVzLmFwcGVuZCh0ZXh0KSBvciBUcnVlCiAgICAgICAgY2xhc3MgX1M6CiAgICAgICAgICAgIGRlZiBfX2luaXRfXyhzZWxmLCBkYXRhKToKICAgICAgICAgICAgICAgIHNlbGYuX2RhdGEgPSBsaXN0KGRhdGEpCiAgICAgICAgICAgIGRlZiByZWFkbGluZShzZWxmKToKICAgICAgICAgICAgICAgIHJldHVybiBzZWxmLl9kYXRhLnBvcCgwKSBpZiBzZWxmLl9kYXRhIGVsc2UgYiIiCiAgICAgICAgICAgIGRlZiBjbG9zZShzZWxmKToKICAgICAgICAgICAgICAgIHBhc3MKICAgICAgICB3Ll9lcnIoX1MoW2IidXNiIGNsYWltIGZhaWxlZFxuIiwgYiIiXSksICJydGxfZm0iKQogICAgICAgIGFzc2VydCBsaW5lcyBhbmQgbGluZXNbMF0uc3RhcnRzd2l0aCgicnRsX2ZtOiIpCiAgICAgICAgY2xhc3MgX1Q6CiAgICAgICAgICAgIGRlZiBfX2luaXRfXyhzZWxmLCBkYXRhKToKICAgICAgICAgICAgICAgIHNlbGYuX2RhdGEgPSBsaXN0KGRhdGEpCiAgICAgICAgICAgIGRlZiByZWFkbGluZShzZWxmKToKICAgICAgICAgICAgICAgIHJldHVybiBzZWxmLl9kYXRhLnBvcCgwKSBpZiBzZWxmLl9kYXRhIGVsc2UgIiIKICAgICAgICAgICAgZGVmIGNsb3NlKHNlbGYpOgogICAgICAgICAgICAgICAgcGFzcwogICAgICAgIHcuX2VycihfVChbIm1pbmltb2RlbToga2VpbmUgU3luY2hyb1xuIiwgIiJdKSwgIm1pbmltb2RlbSIpCiAgICAgICAgYXNzZXJ0IGFueSh4LnN0YXJ0c3dpdGgoIm1pbmltb2RlbToiKSBmb3IgeCBpbiBsaW5lcykKICAgICAgICB3Lm93bmVyID0gbGFtYmRhIGJhc2U6ICgiOTAwMDAwMDMiLCB7fSkKICAgICAgICB3LnByZXNlbnQgPSBsYW1iZGEgc2VyaWFsOiBGYWxzZQogICAgICAgIGFzc2VydCB3LmN5Y2xlKGQpID09ICJ3YXJ0ZSIKICAgICAgICB3LnByZXNlbnQgPSBsYW1iZGEgc2VyaWFsOiBUcnVlCiAgICAgICAgdy5fc3Bhd24gPSBsYW1iZGEgYSwgYjogX1AoKQogICAgICAgIGFzc2VydCB3LmN5Y2xlKGQpID09ICJuZXUiCiAgICAgICAgYXNzZXJ0IHcucHJvYyBpcyBOb25lCiAgICBmaW5hbGx5OgogICAgICAgIGltcG9ydCBzaHV0aWwKICAgICAgICBzaHV0aWwucm10cmVlKGQsIGlnbm9yZV9lcnJvcnM9VHJ1ZSkKICAgIGFzc2VydCBwbGFuX2RbImJhdWQiXSA9PSA1MAogICAgcmV0dXJuICJwaW5uZWJlcmdFbXBmYW5nIG9rICgxNDcsMyBrSHogbmFjaHRzLCA3NjQ2IGtIeiB0YWdzLCAxIGtIeiB1bnRlciBkZXIgTWl0dGUsIDEyIGtTL3MsIEJhdWRvdCA1MCwgUmF1c2NoZW4gdmVyd29yZmVuLCBXQUwsIGtlaW4gQmlhcywga2VpbiBJbmRleCkiCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHByaW50KHNlbGZ0ZXN0KCkpCg=="}, "sdr": [{"old": "ICAgICAgICAgICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9aC5sb29wMiwgZGFlbW9uPVRydWUpLnN0YXJ0KCkKICAgICAgICAgICAgc2VsZi5sb2coInNkclN0aWNrM2U6ICVzIFNOICVzIGFscyB6d2VpdGVyIEhvYmJ5LVN0aWNrIGdlc3RhcnRldCAoQVBSUyBmZXN0LCBSRFMgdmVyc2V0enQsIDEwQyBpbSBXZWNoc2VsLCBLYWxpYnJpZXJ1bmcgMDUgaDsgQXVmdGVpbHVuZyBtaXQgU3RpY2sgMiwgUsO8Y2tmYWxsIGF1dG9tYXRpc2NoKSIgJSAoZVsibmFtZSJdLCBlWyJzZXJpYWwiXSkpCg==", "new": "ICAgICAgICAgICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9aC5sb29wMiwgZGFlbW9uPVRydWUpLnN0YXJ0KCkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgX2hvbGQgPSBfcG4uZW5nYWdlZChzZWxmLmJhc2UpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBfaG9sZCA9IEZhbHNlCiAgICAgICAgICAgIF90eHQgPSAiUGlubmViZXJnLUVtcGZhbmcsIEhvYmJ5IHVuZCBBUFJTIGF1cyIgaWYgX2hvbGQgZWxzZSAiQVBSUyBmZXN0LCBSRFMgdmVyc2V0enQsIDEwQyBpbSBXZWNoc2VsLCBLYWxpYnJpZXJ1bmcgMDUgaDsgQXVmdGVpbHVuZyBtaXQgU3RpY2sgMiwgUsO8Y2tmYWxsIGF1dG9tYXRpc2NoIgogICAgICAgICAgICBzZWxmLmxvZygic2RyU3RpY2szZTogJXMgU04gJXMgYWxzIHp3ZWl0ZXIgSG9iYnktU3RpY2sgZ2VzdGFydGV0ICglcykiICUgKGVbIm5hbWUiXSwgZVsic2VyaWFsIl0sIF90eHQpKQo="}, {"old": "ICAgICAgICBpZiBlOgogICAgICAgICAgICB0ICs9ICI7ICVzIEhvYmJ5IDIgKEFQUlMgZmVzdCwgUkRTIHZlcnNldHp0LCAxMEMgaW0gV2VjaHNlbCkiICUgZVsibmFtZSJdCg==", "new": "ICAgICAgICBpZiBlOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBfaG9sZCA9IF9wbi5lbmdhZ2VkKGdldGF0dHIocGwsICJiYXNlIiwgTm9uZSkpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBfaG9sZCA9IEZhbHNlCiAgICAgICAgICAgIF90eHQgPSAiUGlubmViZXJnLUVtcGZhbmcsIEhvYmJ5IHVuZCBBUFJTIGF1cyIgaWYgX2hvbGQgZWxzZSAiQVBSUyBmZXN0LCBSRFMgdmVyc2V0enQsIDEwQyBpbSBXZWNoc2VsIgogICAgICAgICAgICB0ICs9ICI7ICVzIEhvYmJ5IDIgKCVzKSIgJSAoZVsibmFtZSJdLCBfdHh0KQo="}, {"old": "ICAgICAgICBhc3NlcnQgaDQuYmNfcXVldWUoKSA9PSBbXSBhbmQgaDQuY2FsX2R1ZSh0aW1lLnRpbWUoKSkgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgIkVtcGZhbmcgbmljaHQgZ2VzdGFydGV0IiBpbiBfczNlX21vZGVfc2Z4KGg0KSBhbmQgIlFSTS9NZXRlb3IgdW52ZXJhZW5kZXJ0IiBpbiBfczNlX21vZGVfc2Z4KGgpCg==", "new": "ICAgICAgICBhc3NlcnQgaDQuYmNfcXVldWUoKSA9PSBbXSBhbmQgaDQuY2FsX2R1ZSh0aW1lLnRpbWUoKSkgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgIlBpbm5lYmVyZy1FbXBmYW5nIiBpbiBhaXIyX3QyX3R4dChtKQogICAgICAgIF9vcGVuZWQgPSBbXQogICAgICAgIF9vbGRfc3RhcnQgPSBfcG5fb3JpZ19zdGFydAogICAgICAgIGRlZiBfcG5fYm9vbShzZWxmLCB3aGF0KToKICAgICAgICAgICAgX29wZW5lZC5hcHBlbmQod2hhdCkKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCJnZW9lZmZuZXQiKQogICAgICAgIGdsb2JhbHMoKVsiX3BuX29yaWdfc3RhcnQiXSA9IF9wbl9ib29tCiAgICAgICAgdHJ5OgogICAgICAgICAgICBoNC5zdGFydCgiYXBycyIpCiAgICAgICAgICAgIGFzc2VydCBub3QgX29wZW5lZCBhbmQgaDQuYWN0aXZlID09ICJpZGxlIgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBoLnN0YXJ0KCI0MzMiKQogICAgICAgICAgICBleGNlcHQgUnVudGltZUVycm9yIGFzIGV4OgogICAgICAgICAgICAgICAgYXNzZXJ0ICJnZW9lZmZuZXQiIGluIHN0cihleCkKICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICBnbG9iYWxzKClbIl9wbl9vcmlnX3N0YXJ0Il0gPSBfb2xkX3N0YXJ0CiAgICAgICAgYXNzZXJ0IF9vcGVuZWQgPT0gWyI0MzMiXQogICAgICAgIGFzc2VydCAiRW1wZmFuZyBuaWNodCBnZXN0YXJ0ZXQiIGluIF9zM2VfbW9kZV9zZngoaDQpIGFuZCAiUVJNL01ldGVvciB1bnZlcmFlbmRlcnQiIGluIF9zM2VfbW9kZV9zZngoaCkK"}, {"old": "UGxhbm5lci5jYWxfZHVlID0gX3BuX2NhbF9kdWUKCg==", "new": "UGxhbm5lci5jYWxfZHVlID0gX3BuX2NhbF9kdWUKX3BuX29yaWdfc3RhcnQgPSBQbGFubmVyLnN0YXJ0CgoKZGVmIF9wbl9zdGFydChzZWxmLCB3aGF0KToKICAgICIiIlN0aWNrIDMgZ2Vob2VydCBkZW0gUGlubmViZXJnLUVtcGZhbmcuIEtlaW4gendlaXRlcyBQcm9ncmFtbSBhdWYgZGVyc2VsYmVuIFNlcmllbm51bW1lci4iIiIKICAgIHRyeToKICAgICAgICBpZiBfczNlX2lzX2gyKHNlbGYpIGFuZCBfcG4uZW5nYWdlZChnZXRhdHRyKHNlbGYsICJiYXNlIiwgTm9uZSkpOgogICAgICAgICAgICBub3cgPSB0aW1lLnRpbWUoKQogICAgICAgICAgICBpZiBub3cgLSBnZXRhdHRyKHNlbGYsICJfcG5faG9sZF9sb2ciLCAwKSA+PSAzMDoKICAgICAgICAgICAgICAgIHNlbGYuX3BuX2hvbGRfbG9nID0gbm93CiAgICAgICAgICAgICAgICBzZWxmLmxvZygicGlubmViZXJnOiBTdGljayAzIGJsZWlidCBiZWltIEVtcGZhbmcsIGtlaW4gendlaXRlcyBQcm9ncmFtbSIpCiAgICAgICAgICAgIHNlbGYuYWN0aXZlID0gImlkbGUiCiAgICAgICAgICAgIHJldHVybgogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleDoKICAgICAgICBwcmludCgicGlubmViZXJnOiBTdGFydC1TcGVycmUiLCB0eXBlKGV4KS5fX25hbWVfXywgZmx1c2g9VHJ1ZSkKICAgIHJldHVybiBfcG5fb3JpZ19zdGFydChzZWxmLCB3aGF0KQoKClBsYW5uZXIuc3RhcnQgPSBfcG5fc3RhcnQKCg=="}]}


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
