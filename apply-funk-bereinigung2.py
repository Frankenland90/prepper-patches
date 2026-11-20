#!/usr/bin/env python3
# Funk-Bereinigung 2: sichtbare Reste von 433, QRM und Gain-Test.
# Pinneberg, APRS, Kalibrierung, DAB-Masten und die Gain-Leiter bleiben.
from __future__ import annotations
import base64, hashlib, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
BASIS = {
    "dashboard.py": "7d2f21fbe8f814f2",
    "prepper_sdr.py": "5d362b3bfd670ee4",
    "prepper_docs.py": "257cc5d9b64858e1",
    "lage_pages.py": "e9ea014b5a4ff121",
    "blackout_radar.py": "4ff38da718afed9d",
}
LAENGE = {
    "dashboard.py": 1388174,
    "prepper_sdr.py": 778668,
    "lage_pages.py": 230936,
    "blackout_radar.py": 84127,
}
PATCH = ("dashboard.py", "prepper_sdr.py")
GUARD = ("dashboard.py", "prepper_sdr.py", "prepper_docs.py", "lage_pages.py", "blackout_radar.py")


def load():
    raw = PAYLOAD_JSON
    return {name: [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw[name]] for name in PATCH}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fenster(now=None):
    from zoneinfo import ZoneInfo
    jetzt = now or datetime.now(ZoneInfo("Europe/Berlin"))
    m = jetzt.minute
    return 5 <= m <= 39, "Berlin Minute %02d" % m


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
    alt = sorted(path.parent.glob(path.name + ".bak-funkclean2-*"))
    bak = path.with_name(path.name + ".bak-funkclean2-" + stempel)
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
    tmp = path.with_name("." + path.name + ".tmp-funkclean2")
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
    paare = load()
    blobs = {}
    for name in GUARD:
        pfad = ordner / name
        if pfad.is_symlink() or not pfad.is_file():
            print("STOP: %s fehlt" % name)
            return 2
        data = pfad.read_bytes()
        blobs[name] = data
        print("%s sha16 %s bytes %d" % (name, sha(data)[:16], len(data)))
    try:
        ziel = {name: verwandle(blobs[name], paare[name]) for name in PATCH}
    except RuntimeError:
        print("STOP: Anker fehlt. Nichts geschrieben.")
        return 2
    falsch = False
    for name in GUARD:
        data = blobs[name]
        ist = sha(data)
        if name in ziel and data == ziel[name]:
            continue
        kopf = BASIS[name]
        if not ist.startswith(kopf) or (name in LAENGE and len(data) != LAENGE[name]):
            print("STOP: %s %s / %d ist nicht der Pi-Stand %s." % (name, ist[:16], len(data), kopf))
            falsch = True
    if falsch:
        print("STOP: Hash-Guard. Nichts geschrieben.")
        return 2
    try:
        compile(ziel["dashboard.py"], "dashboard.py", "exec")
        compile(ziel["prepper_sdr.py"], "prepper_sdr.py", "exec")
    except SyntaxError as exc:
        print("STOP: Syntax %s" % exc)
        return 2
    if b"Gain-Test (Tabelle)" in ziel["dashboard.py"] or b"QRM-/Rausch-Grundlinien" in ziel["dashboard.py"]:
        print("STOP: Gain-Test oder QRM-Knopf ist noch im Dashboard")
        return 2
    if b"Hobby (RDS, QRM, Kalibrierung, 433, APRS)" in ziel["prepper_sdr.py"] or b'"id": "n433"' in ziel["prepper_sdr.py"]:
        print("STOP: Rollen-Text oder 433-Chip ist noch im Planer")
        return 2
    if b"868,3 MHz" not in ziel["prepper_sdr.py"] or b"Pinneberg" not in ziel["dashboard.py"]:
        print("STOP: bleibender Eintrag fehlt")
        return 2
    for name in PATCH:
        print("%s endstand sha16 %s bytes %d" % (name, sha(ziel[name])[:16], len(ziel[name])))
    for name in ("prepper_docs.py", "lage_pages.py", "blackout_radar.py"):
        print("%s unveraendert sha16 %s bytes %d" % (name, sha(blobs[name])[:16], len(blobs[name])))
    frei, meldung = fenster(jetzt)
    print(meldung)
    if all(blobs[name] == ziel[name] for name in PATCH):
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        if not frei:
            print("Ein echtes Apply wuerde in dieser Minute ohne Aenderung abbrechen.")
        print("Pruefung nach dem Neustart: sichtbarer Text von /funk ohne script/style auf 433, QRM, Gain-Test.")
        return 0
    if not frei:
        print("STOP: Neustart nur Minute 05-39 Berlin. Nichts geschrieben.")
        return 2
    try:
        for name in PATCH:
            if blobs[name] != ziel[name]:
                sichern(ordner / name, blobs[name])
                schreiben(ordner / name, ziel[name])
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    print("geschrieben. prepper-sdr und prepper-dashboard neu starten.")
    if kein:
        print("Kein Neustart in dieser Pruefung.")
        return 0
    frei, meldung = fenster()
    print(meldung)
    if not frei:
        print("Dateien sind neu. Der Neustart bleibt aus, die Minute ist nicht mehr 05-39.")
        return 2
    subprocess = __import__("subprocess")
    subprocess.run(["systemctl", "restart", "prepper-sdr.service"], check=False)
    subprocess.run(["systemctl", "restart", "prepper-dashboard.service"], check=False)
    print("prepper-sdr und prepper-dashboard neu gestartet.")
    return 0


def selftest() -> int:
    assert BASIS["dashboard.py"] == "7d2f21fbe8f814f2" and LAENGE["dashboard.py"] == 1388174
    assert BASIS["prepper_sdr.py"] == "5d362b3bfd670ee4" and LAENGE["prepper_sdr.py"] == 778668
    assert BASIS["prepper_docs.py"] == "257cc5d9b64858e1"
    assert BASIS["lage_pages.py"] == "e9ea014b5a4ff121" and BASIS["blackout_radar.py"] == "4ff38da718afed9d"
    assert fenster(datetime(2026, 11, 20, 21, 12))[0]
    assert fenster(datetime(2026, 11, 20, 21, 5))[0] and fenster(datetime(2026, 11, 20, 21, 39))[0]
    assert not fenster(datetime(2026, 11, 20, 21, 4))[0] and not fenster(datetime(2026, 11, 20, 21, 40))[0]
    import tempfile
    ordner = Path(tempfile.mkdtemp(prefix="funkclean2-"))
    for name in GUARD:
        (ordner / name).write_bytes(b"falsch-" + name.encode())
    vorher = {name: (ordner / name).read_bytes() for name in GUARD}
    assert apply_dir(ordner, True, True, datetime(2026, 11, 20, 21, 12)) == 2
    assert vorher == {name: (ordner / name).read_bytes() for name in vorher}
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


PAYLOAD_JSON = {"dashboard.py": [{"old": "dmFyIHI9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7ci5jbGFzc05hbWU9J3BwLXJvdyc7ci5pZD0nc2RyUGlSb3cnO3IudGl0bGU9J1NEUi1QbGFuZXIgcHJlcHBlci1zZHI6IERpZW5zdCAnK2Quc2VydmljZSsocy5lcnI/JyDCtyAnK3MuZXJyOicnKSsnIMK3IDQzMyAnK2QubjQzM18xaCsnLzFoIMK3IEFQUlMgJytkLm5hcHJzXzFoKycvMWgnOwo=", "new": "dmFyIHI9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7ci5jbGFzc05hbWU9J3BwLXJvdyc7ci5pZD0nc2RyUGlSb3cnO3IudGl0bGU9J1NEUi1QbGFuZXIgcHJlcHBlci1zZHI6IERpZW5zdCAnK2Quc2VydmljZSsocy5lcnI/JyDCtyAnK3MuZXJyOicnKSsnIMK3IEFQUlMgJytkLm5hcHJzXzFoKycvMWgnOwo="}, {"old": "ICAgIG5hbWVzID0geyI0MzMiOiAiNDMzIiwgImFwcnMiOiAiQVBSUyIsICJiYyI6ICJVS1cvREFCIiwgImFzYSI6ICJBU0EgNUMiLCAibWV0ZW9yIjogIk1ldGVvciIsICJhY3QiOiAiQWt0aXZpdMOkdCIsICJub2lzZSI6ICJRUk0iLCAiY2FsIjogIkthbGlici4iLCAiZnJlaSI6ICJmcmVpIn0K", "new": "ICAgIG5hbWVzID0geyJhcHJzIjogIkFQUlMiLCAiYmMiOiAiVUtXL0RBQiIsICJhc2EiOiAiQVNBIDVDIiwgIm1ldGVvciI6ICJNZXRlb3IiLCAiY2FsIjogIkthbGlici4iLCAiZnJlaSI6ICJmcmVpIn0K"}, {"old": "ICAgICAgICBjcyA9IGRpY3QoKGssICJTMiIpIGZvciBrIGluICgiNDMzIiwgImFwcnMiLCAiYmMiLCAiYXNhIiwgIm1ldGVvciIsICJhY3QiLCAibm9pc2UiLCAiY2FsIikpCg==", "new": "ICAgICAgICBjcyA9IGRpY3QoKGssICJTMiIpIGZvciBrIGluICgiYXBycyIsICJiYyIsICJhc2EiLCAibWV0ZW9yIiwgImNhbCIpKQo="}, {"old": "ICAgICAgICBjcyA9IGRpY3QoKGssICJTMSIpIGZvciBrIGluICgiNDMzIiwgImFwcnMiLCAiYmMiLCAiYXNhIiwgIm1ldGVvciIsICJhY3QiLCAibm9pc2UiLCAiY2FsIikpCg==", "new": "ICAgICAgICBjcyA9IGRpY3QoKGssICJTMSIpIGZvciBrIGluICgiYXBycyIsICJiYyIsICJhc2EiLCAibWV0ZW9yIiwgImNhbCIpKQo="}, {"old": "ICAgICAgICBjcyA9IHsiYmMiOiAiUzEiLCAiYXNhIjogIlMxIiwgImNhbCI6ICJTMStTMiIsICI0MzMiOiAiUzIiLCAiYXBycyI6ICJTMiIsICJtZXRlb3IiOiAiUzIiLCAiYWN0IjogIlMyIiwgIm5vaXNlIjogIlMyIn0K", "new": "ICAgICAgICBjcyA9IHsiYmMiOiAiUzEiLCAiYXNhIjogIlMxIiwgImNhbCI6ICJTMStTMiIsICJhcHJzIjogIlMyIiwgIm1ldGVvciI6ICJTMiJ9Cg=="}, {"old": "ICAgICAgICAgICAgYSwgYiA9IHMuZ2V0KCI0MzMiKSBvciB7fSwgcy5nZXQoImFwcnMiKSBvciB7fQogICAgICAgICAgICByb3coImdlbGIiIGlmIHMuZ2V0KCJlcnJzIikgZWxzZSAib2siLCAiUyVzICVzIMK3IDQzMzogJXMgRGVrLi9TTlIgJXMgwrcgQVBSUzogJXMgUGFrZXRlIiAlICgKICAgICAgICAgICAgICAgIHMuZ2V0KCJubyIpLCBzLmdldCgic24iKSwgYS5nZXQoIm4iLCAi4oCTIiksIGEuZ2V0KCJzbnIiKSBpZiBhLmdldCgic25yIikgaXMgbm90IE5vbmUgZWxzZSAi4oCTIiwgYi5nZXQoIm4iLCAi4oCTIikpLAogICAgICAgICAgICAgICAgIjsgIi5qb2luKHMuZ2V0KCJlcnJzIikgb3IgW10pIG9yICJSYXVzY2hib2RlbiA0MzMgJXMgZEIsIEFQUlMgJXMgZEIiICUgKChzLmdldCgicHdyNDMzIikgb3Ige30pLmdldCgiZmxvb3IiKSwgKHMuZ2V0KCJwd3JhcHJzIikgb3Ige30pLmdldCgiZmxvb3IiKSkpCg==", "new": "ICAgICAgICAgICAgYiA9IHMuZ2V0KCJhcHJzIikgb3Ige30KICAgICAgICAgICAgcm93KCJnZWxiIiBpZiBzLmdldCgiZXJycyIpIGVsc2UgIm9rIiwgIlMlcyAlcyDCtyBBUFJTOiAlcyBQYWtldGUiICUgKAogICAgICAgICAgICAgICAgcy5nZXQoIm5vIiksIHMuZ2V0KCJzbiIpLCBiLmdldCgibiIsICLigJMiKSksCiAgICAgICAgICAgICAgICAiOyAiLmpvaW4ocy5nZXQoImVycnMiKSBvciBbXSkgb3IgIlJhdXNjaGJvZGVuIEFQUlMgJXMgZEIiICUgKChzLmdldCgicHdyYXBycyIpIG9yIHt9KS5nZXQoImZsb29yIiksKSkK"}, {"old": "Qi5zdGFydD1lbCgnYnV0dG9uJywnJywn8J+UjCBBbnRlbm5lbnRlc3Qgc3RhcnRlbicpO0Iuc3RhcnQudHlwZT0nYnV0dG9uJztCLnN0YXJ0Lm9uY2xpY2s9ZnVuY3Rpb24oKXtwb3N0KCdzdGFydCcsJ0FudGVubmVudGVzdCBzdGFydGVuPyBEZXIgbm9ybWFsZSBQbGFuIHBhdXNpZXJ0IGNhLiA1IE1pbnV0ZW4sIGJlaWRlIFN0aWNrcyB3ZXJkZW4gbmFjaGVpbmFuZGVyIG51ciBpbSBFbXBmYW5nIGdldGVzdGV0LicpO307CkIucmVsZWFybj1lbCgnYnV0dG9uJywnJywn4oa6IE5ldSBsZXJuZW4nKTtCLnJlbGVhcm4udHlwZT0nYnV0dG9uJztCLnJlbGVhcm4ub25jbGljaz1mdW5jdGlvbigpe3Bvc3QoJ3JlbGVhcm4nLCdRUk0tL1JhdXNjaC1HcnVuZGxpbmllbiBhcmNoaXZpZXJlbiB1bmQgamUgU3RpY2sgbmV1IGxlcm5lbj8gQmV3ZXJ0dW5nIGlzdCBkYW5hY2ggY2EuIDI0IGggZ3JhdSAobGVybnQpLicpO307CkIuYXBwbHk9ZWwoJ2J1dHRvbicsJycsJ+KGlCBFbXBmZWhsdW5nIMO8YmVybmVobWVuJyk7Qi5hcHBseS50eXBlPSdidXR0b24nO0IuYXBwbHkub25jbGljaz1mdW5jdGlvbigpe3Bvc3QoJ2FwcGx5JywnUm9sbGVuIGRlciBTdGlja3MgdGF1c2NoZW4gKHNkcl9jb25maWcuanNvbik/IHByZXBwZXItc2RyIHN0YXJ0ZXQgc2ljaCBkYWbDvHIga3VyeiBuZXUuJyk7fTsK", "new": "Qi5zdGFydD1lbCgnYnV0dG9uJywnJywn8J+UjCBBbnRlbm5lbnRlc3Qgc3RhcnRlbicpO0Iuc3RhcnQudHlwZT0nYnV0dG9uJztCLnN0YXJ0Lm9uY2xpY2s9ZnVuY3Rpb24oKXtwb3N0KCdzdGFydCcsJ0FudGVubmVudGVzdCBzdGFydGVuPyBEZXIgbm9ybWFsZSBQbGFuIHBhdXNpZXJ0IGNhLiA1IE1pbnV0ZW4sIGJlaWRlIFN0aWNrcyB3ZXJkZW4gbmFjaGVpbmFuZGVyIG51ciBpbSBFbXBmYW5nIGdldGVzdGV0LicpO307CkIuYXBwbHk9ZWwoJ2J1dHRvbicsJycsJ+KGlCBFbXBmZWhsdW5nIMO8YmVybmVobWVuJyk7Qi5hcHBseS50eXBlPSdidXR0b24nO0IuYXBwbHkub25jbGljaz1mdW5jdGlvbigpe3Bvc3QoJ2FwcGx5JywnUm9sbGVuIGRlciBTdGlja3MgdGF1c2NoZW4gKHNkcl9jb25maWcuanNvbik/IHByZXBwZXItc2RyIHN0YXJ0ZXQgc2ljaCBkYWbDvHIga3VyeiBuZXUuJyk7fTsK"}, {"old": "bXNnPWVsKCdzcGFuJywnc3RrLW1zZycpO2Jhci5hcHBlbmRDaGlsZChCLnN0YXJ0KTtiYXIuYXBwZW5kQ2hpbGQoQi5yZWxlYXJuKTtiYXIuYXBwZW5kQ2hpbGQoQi5hcHBseSk7YmFyLmFwcGVuZENoaWxkKG1zZyk7Yy5hcHBlbmRDaGlsZChiYXIpO3Nob3coKTt9CmZ1bmN0aW9uIHNob3coKXtpZighYmFyfHwhUylyZXR1cm47Qi5zdGFydC5kaXNhYmxlZD0hIVMucnVubmluZztCLmFwcGx5LnN0eWxlLmRpc3BsYXk9Uy5zd2FwJiYhUy5ydW5uaW5nPycnOidub25lJztCLnJlbGVhcm4uZGlzYWJsZWQ9ISFTLnJ1bm5pbmd8fCEhKFMucGVuZGluZ3x8e30pLnJlbGVhcm47Cg==", "new": "bXNnPWVsKCdzcGFuJywnc3RrLW1zZycpO2Jhci5hcHBlbmRDaGlsZChCLnN0YXJ0KTtiYXIuYXBwZW5kQ2hpbGQoQi5hcHBseSk7YmFyLmFwcGVuZENoaWxkKG1zZyk7Yy5hcHBlbmRDaGlsZChiYXIpO3Nob3coKTt9CmZ1bmN0aW9uIHNob3coKXtpZighYmFyfHwhUylyZXR1cm47Qi5zdGFydC5kaXNhYmxlZD0hIVMucnVubmluZztCLmFwcGx5LnN0eWxlLmRpc3BsYXk9Uy5zd2FwJiYhUy5ydW5uaW5nPycnOidub25lJzsK"}, {"old": "X0xHX1JPTEVfVFhUID0geyJiYyI6ICJSdW5kZnVuayBmZXN0IChVS1cvREFCKSIsICJyb3QiOiAiV2VjaHNlbGJldHJpZWIgKFFSTSwgNDMzLCBuYWNoIFNjaGFsdGVybikiLCAic2luZ2xlIjogIkVpbnplbGJldHJpZWIgKGVpbiBTdGljaykiLCAiNDMzIjogIjQzMyBNSHoiLCAiYXBycyI6ICJBUFJTIn0K", "new": "X0xHX1JPTEVfVFhUID0geyJiYyI6ICJSdW5kZnVuayBmZXN0IChVS1cvREFCKSIsICJyb3QiOiAiV2VjaHNlbGJldHJpZWIgKFJEUywgQVBSUywgbmFjaCBTY2hhbHRlcm4pIiwgInNpbmdsZSI6ICJFaW56ZWxiZXRyaWViIChlaW4gU3RpY2spIiwgImFwcnMiOiAiQVBSUyJ9Cg=="}, {"old": "dC5fYjEuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLGZ1bmN0aW9uKCl7dmFyIG9uPUQudGFrZW92ZXImJkQudGFrZW92ZXIub247cG9zdCgnL2FwaS90Mi9zdGljazInLHthY3Rpb246b24/J3p1cnVlY2snOidhbGFybSd9LG9uP25tKCdzMicsJ1N0aWNrIDInKSsnIHdpcmtsaWNoIHp1csO8Y2sgaW4gZGVuIEhvYmJ5LUJldHJpZWIgKFJEUywgUVJNLCA0MzMsIEFQUlMpP1xuXG41QyAoQVNBIERFKSB3aXJkIGRhbm4gbmljaHQgbWVociBlbXBmYW5nZW4uJzpubSgnczInLCdTdGljayAyJykrJyBqZXR6dCBmZXN0IGF1ZiA1QyAoQVNBIERFKSBzY2hhbHRlbj9cblxuWnVyw7xjayBudXIgw7xiZXIgZGllc2VuIEtub3BmLicsdC5fc3QpO30pOwo=", "new": "dC5fYjEuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLGZ1bmN0aW9uKCl7dmFyIG9uPUQudGFrZW92ZXImJkQudGFrZW92ZXIub247cG9zdCgnL2FwaS90Mi9zdGljazInLHthY3Rpb246b24/J3p1cnVlY2snOidhbGFybSd9LG9uP25tKCdzMicsJ1N0aWNrIDInKSsnIHdpcmtsaWNoIHp1csO8Y2sgaW4gZGVuIEhvYmJ5LUJldHJpZWIgKFJEUywgS2FsaWJyaWVydW5nLCBBUFJTKT9cblxuNUMgKEFTQSBERSkgd2lyZCBkYW5uIG5pY2h0IG1laHIgZW1wZmFuZ2VuLic6bm0oJ3MyJywnU3RpY2sgMicpKycgamV0enQgZmVzdCBhdWYgNUMgKEFTQSBERSkgc2NoYWx0ZW4/XG5cblp1csO8Y2sgbnVyIMO8YmVyIGRpZXNlbiBLbm9wZi4nLHQuX3N0KTt9KTsK"}, {"old": "ICAgICAgICAgICAgICAgICAiZGV2cyI6IGRldnMsICJjaGlwX3N0aWNrIjogeyJiYyI6IEFJUl9UQUdbIjExRCJdLCAiYXNhIjogQUlSX1RBR1siNUMiXSwgImNhbCI6IEFJUl9UQUdbImhvYmJ5Il0sICI0MzMiOiBBSVJfVEFHWyJob2JieSJdLCAiYXBycyI6IEFJUl9UQUdbImhvYmJ5Il0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAibWV0ZW9yIjogQUlSX1RBR1siaG9iYnkiXSwgImFjdCI6IEFJUl9UQUdbImhvYmJ5Il0sICJub2lzZSI6IEFJUl9UQUdbImhvYmJ5Il19fQo=", "new": "ICAgICAgICAgICAgICAgICAiZGV2cyI6IGRldnMsICJjaGlwX3N0aWNrIjogeyJiYyI6IEFJUl9UQUdbIjExRCJdLCAiYXNhIjogQUlSX1RBR1siNUMiXSwgImNhbCI6IEFJUl9UQUdbImhvYmJ5Il0sICJhcHJzIjogQUlSX1RBR1siaG9iYnkiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJtZXRlb3IiOiBBSVJfVEFHWyJob2JieSJdfX0K"}, {"old": "ZGVmIF9hdF9hZnRlcihyZXNwKToKICAgIHRyeToK", "new": "ZGVmIF9hdF9hZnRlcihyZXNwKToKICAgIHJldHVybiByZXNwCiAgICB0cnk6Cg=="}, {"old": "ICAgIGFzc2VydCB1WyJjaGlwX3N0aWNrIl1bImFwcnMiXSA9PSAiUzMiIGFuZCB1WyJjaGlwX3N0aWNrIl1bIjQzMyJdID09ICJTMiIgYW5kIHVbIm1vZGUiXS5lbmRzd2l0aCgiU3RpY2sgMiDCtyBIb2JieSwgU3RpY2sgMyDCtyBIb2JieSIpLCAodVsiY2hpcF9zdGljayJdLCB1WyJtb2RlIl0pCg==", "new": "ICAgIGFzc2VydCB1WyJjaGlwX3N0aWNrIl1bImFwcnMiXSA9PSAiUzMiIGFuZCAiNDMzIiBub3QgaW4gdVsiY2hpcF9zdGljayJdIGFuZCB1WyJtb2RlIl0uZW5kc3dpdGgoIlN0aWNrIDIgwrcgSG9iYnksIFN0aWNrIDMgwrcgSG9iYnkiKSwgKHVbImNoaXBfc3RpY2siXSwgdVsibW9kZSJdKQo="}, {"old": "ICAgIGFzc2VydCB1NFsiY2hpcF9zdGljayJdWyI0MzMiXSA9PSAiUzMiIGFuZCB1NFsiY2hpcF9zdGljayJdWyJhcHJzIl0gPT0gIlMzIgo=", "new": "ICAgIGFzc2VydCAiNDMzIiBub3QgaW4gdTRbImNoaXBfc3RpY2siXSBhbmQgdTRbImNoaXBfc3RpY2siXVsiYXBycyJdID09ICJTMyIK"}, {"old": "ICAgICI8c2NyaXB0IGlkPVwiZnVhLWpzXCI+KGZ1bmN0aW9uKCl7ZnVuY3Rpb24gZm9sZCgpe3ZhciBhZz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWdDYXJkJyksYXQ9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2F0Q2FyZCcpOyIKICAgICJpZighYWd8fCFhdClyZXR1cm47dmFyIGQ9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Z1QXRGb2xkJyk7aWYoIWQpe2Q9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGV0YWlscycpO2QuaWQ9J2Z1QXRGb2xkJzsiCiAgICAidmFyIHM9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3VtbWFyeScpO3MudGV4dENvbnRlbnQ9J0dhaW4tVGVzdCAoVGFiZWxsZSknO2QuYXBwZW5kQ2hpbGQocyk7YWcuYXBwZW5kQ2hpbGQoZCk7fSIKICAgICJpZihhdC5wYXJlbnROb2RlIT09ZCl7YXQuY2xhc3NMaXN0LnJlbW92ZSgnY2FyZCcpO2QuYXBwZW5kQ2hpbGQoYXQpO319d2luZG93LmZ1R2FpbkZvbGQ9Zm9sZDsiCiAgICAiZnVuY3Rpb24gcGFzcygpe3ZhciBzdD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3RpY2tUZXN0Q2FyZCcpO2lmKHN0KXN0LnJlbW92ZSgpO2ZvbGQoKTt9Igo=", "new": "ICAgICI8c2NyaXB0IGlkPVwiZnVhLWpzXCI+KGZ1bmN0aW9uKCl7IgogICAgImZ1bmN0aW9uIHBhc3MoKXt2YXIgc3Q9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0aWNrVGVzdENhcmQnKTtpZihzdClzdC5yZW1vdmUoKTt9Igo="}], "prepper_sdr.py": [{"old": "UFJFU0VUUyA9IFsKICAgIHsiaWQiOiAiNDMzIiwgImdyb3VwIjogIlNlbnNvcmVuIiwgImxhYmVsIjogIjQzMyw5MiBNSHogU2Vuc29yZW4gKHJ0bF80MzMpIiwgImtpbmQiOiAiaXNtNDMzIiwgImYiOiAiNDMzLjkyTSJ9LAogICAgeyJpZCI6ICI4NjgiLCAiZ3JvdXAiOiAiU2Vuc29yZW4iLCAibGFiZWwiOiAiODY4LDMgTUh6IFNlbnNvcmVuIChydGxfNDMzKSIsICJraW5kIjogInNyZDg2OCIsICJmIjogIjg2OC4zTSJ9LAo=", "new": "UFJFU0VUUyA9IFsKICAgIHsiaWQiOiAiODY4IiwgImdyb3VwIjogIlNlbnNvcmVuIiwgImxhYmVsIjogIjg2OCwzIE1IeiBTZW5zb3JlbiAocnRsXzQzMykiLCAia2luZCI6ICJzcmQ4NjgiLCAiZiI6ICI4NjguM00ifSwK"}, {"old": "ICAgIHsiaWQiOiAicG1yIiwgImxhYmVsIjogIlBNUjQ0NiA0NDYsMOKAkzQ0NiwyIE1IeiIsICJzaG9ydCI6ICJQTVIiLCAia2luZCI6ICJub2lzZXBtciIsICJsbyI6ICI0NDYuMDAwTSIsICJoaSI6ICI0NDYuMjAwTSIsICJiaW4iOiAiMWsiLCAiaSI6IDEsICJzIjogNn0sCiAgICB7ImlkIjogIm40MzMiLCAibGFiZWwiOiAiSVNNIDQzMywwNeKAkzQzNCw3OSBNSHoiLCAic2hvcnQiOiAiNDMzIiwgImtpbmQiOiAibm9pc2U0MzMiLCAibG8iOiAiNDMzLjA1ME0iLCAiaGkiOiAiNDM0Ljc5ME0iLCAiYmluIjogIjVrIiwgImkiOiAxLCAicyI6IDZ9LAogICAgeyJpZCI6ICJuODY4IiwgImxhYmVsIjogIlNSRCA4NjPigJM4NzAgTUh6IiwgInNob3J0IjogIjg2OCIsICJraW5kIjogIm5vaXNlODY4IiwgImxvIjogIjg2My4wMDBNIiwgImhpIjogIjg3MC4wMDBNIiwgImJpbiI6ICIxMGsiLCAiaSI6IDIsICJzIjogOH0sCg==", "new": "ICAgIHsiaWQiOiAicG1yIiwgImxhYmVsIjogIlBNUjQ0NiA0NDYsMOKAkzQ0NiwyIE1IeiIsICJzaG9ydCI6ICJQTVIiLCAia2luZCI6ICJub2lzZXBtciIsICJsbyI6ICI0NDYuMDAwTSIsICJoaSI6ICI0NDYuMjAwTSIsICJiaW4iOiAiMWsiLCAiaSI6IDEsICJzIjogNn0sCiAgICB7ImlkIjogIm44NjgiLCAibGFiZWwiOiAiU1JEIDg2M+KAkzg3MCBNSHoiLCAic2hvcnQiOiAiODY4IiwgImtpbmQiOiAibm9pc2U4NjgiLCAibG8iOiAiODYzLjAwME0iLCAiaGkiOiAiODcwLjAwME0iLCAiYmluIjogIjEwayIsICJpIjogMiwgInMiOiA4fSwK"}, {"old": "ICAgICAgICAgICAgICAgICAgInNsaWNlcyI6IHsiNDMzIjogc2VsZi5jZmdbInNsaWNlXzQzM19zIl0sICJhcHJzIjogc2VsZi5jZmdbInNsaWNlX2FwcnNfcyJdfSwK", "new": "ICAgICAgICAgICAgICAgICAgInNsaWNlcyI6IHsiYXBycyI6IGludChzZWxmLmNmZy5nZXQoInNsaWNlX2FwcnNfcyIpIG9yIDApICsgaW50KHNlbGYuY2ZnLmdldCgic2xpY2VfNDMzX3MiKSBvciAwKX0sCg=="}, {"old": "ICAgICAgICBzZWxmLmxvZygic2RyVGVpbDI6IFN0aWNrIDIgU04gJXMgenVydWVjayBpbSBIb2JieS1CZXRyaWViIChSRFMsIFFSTSwgS2FsaWJyaWVydW5nLCA0MzMsIEFQUlMpIiAlIGNmZ19zZXJpYWwoc2VsZi5jZmcpKQo=", "new": "ICAgICAgICBzZWxmLmxvZygic2RyVGVpbDI6IFN0aWNrIDIgU04gJXMgenVydWVjayBpbSBIb2JieS1CZXRyaWViIChSRFMsIEthbGlicmllcnVuZywgQVBSUykiICUgY2ZnX3NlcmlhbChzZWxmLmNmZykpCg=="}, {"old": "ICAgIG1vZGUgPSB7ImJjIjogIjExRCBmZXN0IiwgInJvdCI6ICgiQUxBUk0gNUMgKEFTQSBERSkiIGlmIGFsIGVsc2UgIkhvYmJ5IChSRFMsIFFSTSwgS2FsaWJyaWVydW5nLCA0MzMsIEFQUlMpIiksICJzaW5nbGUiOiAiRWluemVsYmV0cmllYiAoYWxsZXMgd2llIGZydWVoZXIpIn0uZ2V0KHNlbGYucm9sZSwgc3RyKHNlbGYucm9sZSkpCg==", "new": "ICAgIG1vZGUgPSB7ImJjIjogIjExRCBmZXN0IiwgInJvdCI6ICgiQUxBUk0gNUMgKEFTQSBERSkiIGlmIGFsIGVsc2UgIkhvYmJ5IChSRFMsIEthbGlicmllcnVuZywgQVBSUykiKSwgInNpbmdsZSI6ICJFaW56ZWxiZXRyaWViIChhbGxlcyB3aWUgZnJ1ZWhlcikifS5nZXQoc2VsZi5yb2xlLCBzdHIoc2VsZi5yb2xlKSkK"}, {"old": "ICAgICAgICAgICAgICAgIHJbInR4dCJdID0gIlN0aWNrIDIgU04gJXM6IEhvYmJ5L0JlcmVpdHNjaGFmdCAoUkRTIEJSMjQvQmF5ZXJuIDMvQmF5ZXJuIDEsIFFSTSwgS2FsaWJyaWVydW5nLCA0MzMsIEFQUlMpIiAlIGNmZ19zZXJpYWwody5jZmcpCg==", "new": "ICAgICAgICAgICAgICAgIHJbInR4dCJdID0gIlN0aWNrIDIgU04gJXM6IEhvYmJ5L0JlcmVpdHNjaGFmdCAoUkRTIEJSMjQvQmF5ZXJuIDMvQmF5ZXJuIDEsIEthbGlicmllcnVuZywgQVBSUykiICUgY2ZnX3NlcmlhbCh3LmNmZykK"}, {"old": "REVWX1JPTEVfVFhUID0geyIxMUQiOiAiZmVzdCAxMUQgKEJSIEJheWVybikiLCAiNUMiOiAiZmVzdCA1QyAoQVNBIERFLCBXYXJudW5nZW4pIMK3IFLDvGNrZmFsbCAxMEMiLCAiaG9iYnkiOiAiSG9iYnkgKFJEUywgUVJNLCBLYWxpYnJpZXJ1bmcsIDQzMywgQVBSUykiLCAiIjogImVya2FubnQsIG9obmUgUm9sbGUifQo=", "new": "REVWX1JPTEVfVFhUID0geyIxMUQiOiAiZmVzdCAxMUQgKEJSIEJheWVybikiLCAiNUMiOiAiZmVzdCA1QyAoQVNBIERFLCBXYXJudW5nZW4pIMK3IFLDvGNrZmFsbCAxMEMiLCAiaG9iYnkiOiAiSG9iYnkgKFJEUywgS2FsaWJyaWVydW5nLCBBUFJTKSIsICIiOiAiZXJrYW5udCwgb2huZSBSb2xsZSJ9Cg=="}]}


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
