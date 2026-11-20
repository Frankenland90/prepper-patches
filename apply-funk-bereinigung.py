#!/usr/bin/env python3
# Funk-Bereinigung: 433, QRM, Gewitter, Aktivitaet, Netz-Freigabe, Gain-Tabelle.
# Pinneberg, ASA, UKW/DAB, Dach-GPS, Airspy bleiben. Kein Mesh, keine Abschaltung, keine Firewall.
from __future__ import annotations
import base64, hashlib, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
BASIS = {
    "dashboard.py": "51425216aaeeb836",
    "prepper_sdr.py": "e21a0a644a3fc6e3",
    "lage_pages.py": "e9ea014b5a4ff121",
    "blackout_radar.py": "4ff38da718afed9d",
}
LAENGE = {
    "prepper_sdr.py": 777297,
    "lage_pages.py": 230936,
    "blackout_radar.py": 84127,
}
PATCH = ("dashboard.py", "prepper_sdr.py", "prepper_docs.py")
GUARD = ("dashboard.py", "prepper_sdr.py", "lage_pages.py", "blackout_radar.py")
SMOKE_PAGES = ["/", "/funk", "/pi", "/umwelt", "/aprs", "/meteor", "/rundfunk", "/energie", "/dabhist", "/mesh", "/karte"]
SMOKE_APIS = ["/api/sdr/ui", "/api/sdr/wd", "/api/br24", "/api/sdr/sticktest", "/api/sdr/live", "/api/sdr/map",
              "/api/broadcast/events", "/api/t2/status", "/api/t3/status", "/api/t4/status", "/api/t4/map",
              "/api/t4/tii", "/api/meteor", "/api/sdr/status"]


def load():
    raw = PAYLOAD_JSON
    return {name: [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw[name]] for name in PATCH}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def minute(now=None):
    from zoneinfo import ZoneInfo
    jetzt = now or datetime.now(ZoneInfo("Europe/Berlin"))
    return jetzt.minute


def fenster(now=None):
    m = minute(now)
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
    alt = sorted(path.parent.glob(path.name + ".bak-funkclean-*"))
    bak = path.with_name(path.name + ".bak-funkclean-" + stempel)
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
    tmp = path.with_name("." + path.name + ".tmp-funkclean")
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
    namen = list(PATCH) + ["lage_pages.py", "blackout_radar.py"]
    for name in namen:
        pfad = ordner / name
        if name == "prepper_docs.py" and (pfad.is_symlink() or not pfad.is_file()):
            print("Hinweis: prepper_docs.py fehlt, Rauchtest-Liste bleibt.")
            continue
        if pfad.is_symlink() or not pfad.is_file():
            print("STOP: %s fehlt" % name)
            return 2
        data = pfad.read_bytes()
        blobs[name] = data
        print("%s sha16 %s bytes %d" % (name, sha(data)[:16], len(data)))
    ziel = {}
    for name in ("dashboard.py", "prepper_sdr.py"):
        try:
            ziel[name] = verwandle(blobs[name], paare[name])
        except RuntimeError:
            print("STOP: Anker in %s fehlt. Nichts geschrieben." % name)
            return 2
    if "prepper_docs.py" in blobs:
        try:
            ziel["prepper_docs.py"] = verwandle(blobs["prepper_docs.py"], paare["prepper_docs.py"])
        except RuntimeError:
            print("Hinweis: Rauchtest-Anker in prepper_docs.py fehlt, die Liste bleibt.")
            ziel["prepper_docs.py"] = blobs["prepper_docs.py"]
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
    if b'("/funk433"' in ziel["dashboard.py"] or b'("/api/funk433"' in ziel["dashboard.py"] or b"nur 433" in ziel["dashboard.py"] or b"Stick freigeben" in ziel["dashboard.py"]:
        print("STOP: 433 oder Freigabe ist noch in dashboard.py")
        return 2
    if b"def _fc_noise" not in ziel["prepper_sdr.py"] or b"noise_enable" not in ziel["prepper_sdr.py"]:
        print("STOP: Planer-Sperre fehlt")
        return 2
    if b"Pinneberg" not in ziel["dashboard.py"] or b"Dach-GPS" not in ziel["dashboard.py"]:
        print("STOP: bleibende Kachel fehlt")
        return 2
    for name, data in ziel.items():
        print("%s endstand sha16 %s bytes %d" % (name, sha(data)[:16], len(data)))
    for name in ("lage_pages.py", "blackout_radar.py"):
        print("%s unveraendert sha16 %s bytes %d" % (name, sha(blobs[name])[:16], len(blobs[name])))
    print("Rauchtest-Soll: %d Seiten, %d APIs, ohne /funk433" % (len(SMOKE_PAGES), len(SMOKE_APIS)))
    frei, meldung = fenster(jetzt)
    print(meldung)
    if all(blobs.get(name) == data for name, data in ziel.items()):
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        if not frei:
            print("Ein echtes Apply wuerde in dieser Minute ohne Aenderung abbrechen.")
        return 0
    if not frei:
        print("STOP: Neustart nur Minute 05-39 Berlin. Nichts geschrieben.")
        return 2
    try:
        for name, data in ziel.items():
            if blobs.get(name) != data:
                sichern(ordner / name, blobs[name])
                schreiben(ordner / name, data)
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    print("geschrieben. prepper-sdr und prepper-dashboard neu starten. Mesh und Firewall bleiben.")
    if kein:
        print("Kein Neustart in dieser Pruefung.")
        print("Pruefung: curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/funk")
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
    print("Pruefung: curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/funk")
    return 0


def selftest() -> int:
    assert BASIS["dashboard.py"] == "51425216aaeeb836"
    assert BASIS["prepper_sdr.py"] == "e21a0a644a3fc6e3" and LAENGE["prepper_sdr.py"] == 777297
    assert BASIS["lage_pages.py"] == "e9ea014b5a4ff121" and LAENGE["lage_pages.py"] == 230936
    assert BASIS["blackout_radar.py"] == "4ff38da718afed9d" and LAENGE["blackout_radar.py"] == 84127
    assert fenster(datetime(2026, 11, 20, 21, 12))[0]
    assert fenster(datetime(2026, 11, 20, 21, 5))[0]
    assert fenster(datetime(2026, 11, 20, 21, 39))[0]
    assert not fenster(datetime(2026, 11, 20, 21, 4))[0]
    assert not fenster(datetime(2026, 11, 20, 21, 40))[0]
    assert not fenster(datetime(2026, 11, 20, 21, 45))[0]
    assert "/funk433" not in SMOKE_PAGES and "/api/funk433" not in SMOKE_APIS
    assert len(SMOKE_PAGES) == 11 and len(SMOKE_APIS) == 14
    import tempfile
    paare = load()
    ordner = Path(tempfile.mkdtemp(prefix="funkclean-"))
    (ordner / "dashboard.py").write_bytes(b"falsch")
    (ordner / "prepper_sdr.py").write_bytes(paare["prepper_sdr.py"][0][0])
    (ordner / "prepper_docs.py").write_bytes(b"docs")
    (ordner / "lage_pages.py").write_bytes(b"lage")
    (ordner / "blackout_radar.py").write_bytes(b"radar")
    vorher = {name: (ordner / name).read_bytes() for name in list(PATCH) + ["lage_pages.py", "blackout_radar.py"]}
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


PAYLOAD_JSON = {"dashboard.py": [{"old": "ICAgIGlmIG1vZGUgbm90IGluIF9zZHJfbW9kLk1PREVTOgogICAgICAgIHJldHVybiBqc29uaWZ5KHsib2siOiBGYWxzZSwgImVycm9yIjogIm1vZGUgbXVzcyBhdXRvLzQzMy9hcHJzL3RjcC9vZmYgc2VpbiJ9KSwgNDAwCg==", "new": "ICAgIGlmIG1vZGUgaW4gKCI0MzMiLCAidGNwIikgb3IgbW9kZSBub3QgaW4gX3Nkcl9tb2QuTU9ERVMgb3IgbW9kZSBub3QgaW4gKCJhdXRvIiwgImFwcnMiLCAib2ZmIiwgInByZXNldCIpOgogICAgICAgIHJldHVybiBqc29uaWZ5KHsib2siOiBGYWxzZSwgImVycm9yIjogIm1vZGUgbXVzcyBhdXRvL2FwcnMvb2ZmL3ByZXNldCBzZWluIn0pLCA0MDAK"}, {"old": "W1snYXV0bycsJ0F1dG9tYXRpayddLFsnNDMzJywnbnVyIDQzMyddLFsnYXBycycsJ251ciBBUFJTJ10sWyd0Y3AnLCdOZXR6IDYwIG1pbiddLFsnb2ZmJywnYXVzJ11dLmZvckVhY2goZnVuY3Rpb24oYil7dmFyIHg9c2RyRWwoJ2J1dHRvbicsJ3Nkci1idG4nKyhjdXI9PT1iWzBdPycgb24nOicnKSxiWzFdKTt4LnR5cGU9J2J1dHRvbic7Cg==", "new": "W1snYXV0bycsJ0F1dG9tYXRpayddLFsnYXBycycsJ251ciBBUFJTJ10sWydvZmYnLCdhdXMnXV0uZm9yRWFjaChmdW5jdGlvbihiKXt2YXIgeD1zZHJFbCgnYnV0dG9uJywnc2RyLWJ0bicrKGN1cj09PWJbMF0/JyBvbic6JycpLGJbMV0pO3gudHlwZT0nYnV0dG9uJzsK"}, {"old": "ICAgICAgICAgICAgJzxkaXYgY2xhc3M9InNkcnN1YiIgc3R5bGU9Im1hcmdpbjo0cHggMCAxMHB4Ij48YSBocmVmPSIvZnVuazQzMyI+8J+ToSA0MzMgTUh6PC9hPjxhIGhyZWY9Ii9hcHJzIj7wn5O7IEFQUlM8L2E+PGEgaHJlZj0iL2Z1bmsiPuKGqSBGdW5rPC9hPjxhIGhyZWY9Ii9waSI+U3lzdGVtPC9hPjwvZGl2PicK", "new": "ICAgICAgICAgICAgJzxkaXYgY2xhc3M9InNkcnN1YiIgc3R5bGU9Im1hcmdpbjo0cHggMCAxMHB4Ij48YSBocmVmPSIvYXBycyI+8J+TuyBBUFJTPC9hPjxhIGhyZWY9Ii9mdW5rIj7ihqkgRnVuazwvYT48YSBocmVmPSIvcGkiPlN5c3RlbTwvYT48L2Rpdj4nCg=="}, {"old": "bG4oYywn4pePICcrbC50eHQsbC5jb2wpOwpsbihjLCfwn5OhIDQzMyBNSHo6ICcrZC5uNDMzXzFoKycgU2Vuc29yZW4vMWggwrcgbGV0enRlcyAnK3NkckFnbyhkLmxhc3RfNDMzX3Qsbm93KSsnIOKAuicsbnVsbCwnL2Z1bms0MzMnKTsKKGQudGVtcHN8fFtdKS5zbGljZSgwLDIpLmZvckVhY2goZnVuY3Rpb24odCl7bG4oYywnwrcgJyt0Lm1vZGVsKyh0LmNoIT09dW5kZWZpbmVkJiZ0LmNoIT09bnVsbD8nIEsnK3QuY2g6JycpKyc6ICcrc2RyTih0LmMpKycgwrBDJysodC5oIT09dW5kZWZpbmVkJiZ0LmghPT1udWxsPycgwrcgJyt0LmgrJyAlJzonJyksJyM5NGEzYjgnKTt9KTsK", "new": "bG4oYywn4pePICcrbC50eHQsbC5jb2wpOwooZC50ZW1wc3x8W10pLnNsaWNlKDAsMikuZm9yRWFjaChmdW5jdGlvbih0KXtsbihjLCfCtyAnK3QubW9kZWwrKHQuY2ghPT11bmRlZmluZWQmJnQuY2ghPT1udWxsPycgSycrdC5jaDonJykrJzogJytzZHJOKHQuYykrJyDCsEMnKyh0LmghPT11bmRlZmluZWQmJnQuaCE9PW51bGw/JyDCtyAnK3QuaCsnICUnOicnKSwnIzk0YTNiOCcpO30pOwo="}, {"old": "c2RyQnRucyhjLGQscG9sbCk7CnZhciByYj1zZHJFbCgnYnV0dG9uJywnc2RyLWJ0bicsJ1N0aWNrIGZyZWlnZWJlbicpOwpyYi50eXBlPSdidXR0b24nOwpyYi5vbmNsaWNrPWZ1bmN0aW9uKCl7aWYoIWNvbmZpcm0oJ1N0aWNrIGpldHp0IGZyZWlnZWJlbj8nKSlyZXR1cm47cmIuZGlzYWJsZWQ9dHJ1ZTtmZXRjaCgnL2FwaS9zZHIvcmVsZWFzZScse21ldGhvZDonUE9TVCd9KS50aGVuKHI9PnIuanNvbigpKS50aGVuKGo9PnthbGVydChqLm9rPydGcmVpZ2FiZSBhbmdlZm9yZGVydCc6J0ZlaGxlcjogJytqLmVycm9yKTtyYi5kaXNhYmxlZD1mYWxzZTt9KTt9OwpjLmFwcGVuZENoaWxkKHJiKTt9Cg==", "new": "c2RyQnRucyhjLGQscG9sbCk7fQo="}, {"old": "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAoIi9hcGkvc2RyL21vZGUiLCAic2RyX21vZGUiLCBfc2RyX2FwaV9tb2RlLCBbIlBPU1QiXSksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgKCIvYXBpL2Z1bms0MzMiLCAic2RyX2FwaTQzMyIsIF9zZHJfYXBpXzQzMywgWyJHRVQiXSksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgKCIvYXBpL2FwcnMiLCAic2RyX2FwaWFwcnMiLCBfc2RyX2FwaV9hcHJzLCBbIkdFVCJdKSwK", "new": "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAoIi9hcGkvc2RyL21vZGUiLCAic2RyX21vZGUiLCBfc2RyX2FwaV9tb2RlLCBbIlBPU1QiXSksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgKCIvYXBpL2FwcnMiLCAic2RyX2FwaWFwcnMiLCBfc2RyX2FwaV9hcHJzLCBbIkdFVCJdKSwK"}, {"old": "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAoIi9hcGkvYXBycyIsICJzZHJfYXBpYXBycyIsIF9zZHJfYXBpX2FwcnMsIFsiR0VUIl0pLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICgiL2Z1bms0MzMiLCAic2RyX3BhZ2U0MzMiLCBfc2RyX3BhZ2VfNDMzLCBbIkdFVCJdKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAoIi9hcHJzIiwgInNkcl9wYWdlYXBycyIsIF9zZHJfcGFnZV9hcHJzLCBbIkdFVCJdKSk6Cg==", "new": "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAoIi9hcGkvYXBycyIsICJzZHJfYXBpYXBycyIsIF9zZHJfYXBpX2FwcnMsIFsiR0VUIl0pLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICgiL2FwcnMiLCAic2RyX3BhZ2VhcHJzIiwgX3Nkcl9wYWdlX2FwcnMsIFsiR0VUIl0pKToK"}, {"old": "ICAgICAgICBpZiBwdGggaW4gKCIvdW13ZWx0IiwgIi9mdW5rNDMzIikgYW5kIHJlc3Auc3RhdHVzX2NvZGUgPT0gMjAwIGFuZCBub3QgcmVzcC5kaXJlY3RfcGFzc3Rocm91Z2ggXAo=", "new": "ICAgICAgICBpZiBwdGggPT0gIi91bXdlbHQiIGFuZCByZXNwLnN0YXR1c19jb2RlID09IDIwMCBhbmQgbm90IHJlc3AuZGlyZWN0X3Bhc3N0aHJvdWdoIFwK"}, {"old": "X1NEUlVJX05BTUVTID0gWygiNDMzIiwgIjQzMyw5MiBNSHoiKSwgKCJhcHJzIiwgIkFQUlMiKSwgKCJiYyIsICJVS1cvREFCIiksICgiYXNhIiwgIkFTQSA1QyIpLCAoIm1ldGVvciIsICJNZXRlb3IiKSwKICAgICAgICAgICAgICAgICgiYWN0IiwgIkFrdGl2aXTDpHQiKSwgKCJub2lzZSIsICJRUk0tTWVzc3VuZyIpLCAoImdwcyIsICJEYWNoLUdQUyIpLCAoImNhbCIsICJLYWxpYnJpZXJ1bmciKV0KX1NEUlVJX01PREVTID0gWygiYXV0byIsICJBdXRvbWF0aWsiLCAiWmVpdHNjaGVpYmVuIDQzMy9BUFJTIChtaXQgU3RpY2sgMyDCtyBIb2JieTogNDMzIHVuZCBBUFJTIGdldHJlbm50IGZlc3QpLCBkYXp1IFJ1bmRmdW5rLCBRUk0tTWVzc3VuZywgTWV0ZW9yIHVuZCBLYWxpYnJpZXJ1bmcgbmFjaCBQbGFuIiksCiAgICAgICAgICAgICAgICAoIjQzMyIsICJudXIgNDMzIiwgIm51ciA0MzMsOTIgTUh6IFNlbnNvcmVuIGF1ZiBkZW0gSG9iYnktU3RpY2sgMiwgYWxsZXMgYW5kZXJlIGRvcnQgcGF1c2llcnQgKFN0aWNrIDMgwrcgSG9iYnkgYmxlaWJ0IGluIGRlciBBdXRvbWF0aWspIiksCiAgICAgICAgICAgICAgICAoImFwcnMiLCAibnVyIEFQUlMiLCAibnVyIEFQUlMgMTQ0LDgwMCBNSHogYXVmIGRlbSBIb2JieS1TdGljayAyLCBhbGxlcyBhbmRlcmUgZG9ydCBwYXVzaWVydCAoU3RpY2sgMyDCtyBIb2JieSBibGVpYnQgaW4gZGVyIEF1dG9tYXRpaykiKSwKICAgICAgICAgICAgICAgICgidGNwIiwgIk5ldHogNjAgbWluIiwgIlN0aWNrIDYwIG1pbiBhbHMgcnRsX3RjcCBmcmVpZ2VnZWJlbiwgZGFuYWNoIHp1csO8Y2sgenUgQXV0b21hdGlrIiksCg==", "new": "X1NEUlVJX05BTUVTID0gWygiYXBycyIsICJBUFJTIiksICgiYmMiLCAiVUtXL0RBQiIpLCAoImFzYSIsICJBU0EgNUMiKSwgKCJtZXRlb3IiLCAiTWV0ZW9yIiksCiAgICAgICAgICAgICAgICAoImdwcyIsICJEYWNoLUdQUyIpLCAoImNhbCIsICJLYWxpYnJpZXJ1bmciKV0KX1NEUlVJX01PREVTID0gWygiYXV0byIsICJBdXRvbWF0aWsiLCAiQVBSUywgUnVuZGZ1bmssIE1ldGVvciB1bmQgS2FsaWJyaWVydW5nIG5hY2ggUGxhbiIpLAogICAgICAgICAgICAgICAgKCJhcHJzIiwgIm51ciBBUFJTIiwgIm51ciBBUFJTIDE0NCw4MDAgTUh6IGF1ZiBkZW0gSG9iYnktU3RpY2sgMiwgYWxsZXMgYW5kZXJlIGRvcnQgcGF1c2llcnQgKFN0aWNrIDMgYmxlaWJ0IGJlaSBQaW5uZWJlcmcpIiksCg=="}, {"old": "ICAgIGRlZiBtayhrLCBzdGF0ZSwgbHZsLCBsYXN0PU5vbmUsIG54dD1Ob25lLCBpbmZvPSIiLCB0aXA9IiIpOgogICAgICAgIGZba10gPSB7ImsiOiBrLCAibmFtZSI6IGRpY3QoX1NEUlVJX05BTUVTKVtrXSwgInN0YXRlIjogc3RhdGUsICJsdmwiOiBsdmwsICJsYXN0IjogbGFzdCwgImFnZSI6IF9zZHJ1aV9hZ2Uobm93LCBsYXN0KSwK", "new": "ICAgIGRlZiBtayhrLCBzdGF0ZSwgbHZsLCBsYXN0PU5vbmUsIG54dD1Ob25lLCBpbmZvPSIiLCB0aXA9IiIpOgogICAgICAgIGlmIGsgbm90IGluIGRpY3QoX1NEUlVJX05BTUVTKToKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgZltrXSA9IHsiayI6IGssICJuYW1lIjogZGljdChfU0RSVUlfTkFNRVMpW2tdLCAic3RhdGUiOiBzdGF0ZSwgImx2bCI6IGx2bCwgImxhc3QiOiBsYXN0LCAiYWdlIjogX3NkcnVpX2FnZShub3csIGxhc3QpLAo="}, {"old": "ICAgICAgICAgICAgInRlbXBzIjogdGVtcHMsICJrZnoiOiBrZnosICJwcmVzZXRzIjogZC5nZXQoInByZXNldHMiKSBvciBbXSwgInByZXNldF9taW51dGVzIjogZC5nZXQoInByZXNldF9taW51dGVzIikgb3IgWzMwLCA2MCwgMTIwXSwK", "new": "ICAgICAgICAgICAgInRlbXBzIjogdGVtcHMsICJrZnoiOiBrZnosICJwcmVzZXRzIjogW3AgZm9yIHAgaW4gKGQuZ2V0KCJwcmVzZXRzIikgb3IgW10pIGlmIHAuZ2V0KCJpZCIpICE9ICI0MzMiIGFuZCBwLmdldCgia2luZCIpICE9ICJpc200MzMiXSwgInByZXNldF9taW51dGVzIjogZC5nZXQoInByZXNldF9taW51dGVzIikgb3IgWzMwLCA2MCwgMTIwXSwK"}, {"old": "dmFyIFI9ZWwoJ2RpdicsJ3N1LXJvd3MnKTsKdmFyIHQ9KEQudGVtcHN8fFtdKS5zbGljZSgwLDQpLm1hcChmdW5jdGlvbihzKXtyZXR1cm4gKHMubW9kZWx8fCc/JykucmVwbGFjZSgvLS4qLywnJykrJyAnK24xKHMuYykrJyDCsEMnKyhzLmghPT1udWxsJiZzLmghPT11bmRlZmluZWQ/JyAnK3MuaCsnICUnOicnKTt9KS5qb2luKCcgwrcgJyk7CnJvdyhSLEYoJzQzMycpLmx2bCwn8J+MoSA0MzM6JywodHx8J2tlaW5lIFNlbnNvcmVuJykrKEQua2Z6Pycgwrcg8J+alyAnK0Qua2Z6KycgS0ZaLVJlaWZlbic6JycpLChELnRlbXBzfHxbXSkubWFwKGZ1bmN0aW9uKHMpe3JldHVybiBzLm1vZGVsKycgJytzLmlkKyc6ICcrbjEocy5jKSsnIMKwQyc7fSkuam9pbignXG4nKSsoRC5rZno/J1xuS0ZaLVJlaWZlbnNlbnNvcmVuIChUUE1TKSBhdXNnZWJsZW5kZXQsIHNpZWhlIDQzMy1TZWl0ZSc6JycpLCcvZnVuazQzMycpOwp2YXIgbG09RC5sYXN0X21zZztyb3coUixGKCdhcHJzJykubHZsLCfwn5O7IEFQUlM6JyxGKCdhcHJzJykuaW5mbysoRC5hcHJzX2Zhcj8nIMK3IHdlaXRlc3QgJytELmFwcnNfZmFyKycgJytuMShELmFwcnNfZmFyX2ttKSsnIGttJzonJyksbG0/KCdsZXR6dGUgTmFjaHJpY2h0ICcrbG0uZnJvbSsn4oaSJytsbS50bysnOiAnK2xtLnRleHQpOicnLCcvYXBycycpOwo=", "new": "dmFyIFI9ZWwoJ2RpdicsJ3N1LXJvd3MnKTsKdmFyIGxtPUQubGFzdF9tc2c7cm93KFIsRignYXBycycpLmx2bCwn8J+TuyBBUFJTOicsRignYXBycycpLmluZm8rKEQuYXByc19mYXI/JyDCtyB3ZWl0ZXN0ICcrRC5hcHJzX2ZhcisnICcrbjEoRC5hcHJzX2Zhcl9rbSkrJyBrbSc6JycpLGxtPygnbGV0enRlIE5hY2hyaWNodCAnK2xtLmZyb20rJ+KGkicrbG0udG8rJzogJytsbS50ZXh0KTonJywnL2FwcnMnKTsK"}, {"old": "dmFyIGJjPUYoJ2JjJykscnI9cm93KFIsYmMubHZsLCfwn5O7IFJ1bmRmdW5rOicsYmMuaW5mbysnIMK3ICcrYWdvKGJjLmFnZSkrKGJjLm5leHQ/JyDCtyBuw6RjaHN0ICcraG0oYmMubmV4dCk6JycpLGJjLnRpcCwnL3J1bmRmdW5rJyk7cnIuZGF0YXNldC5zdT0ncmYnOwp2YXIgbno9RC5ub2lzZXx8e30scT1ELnFybXx8e30sdGg9RC50aHVuZGVyfHx7fTt2YXIgbnpsPUYoJ25vaXNlJykubHZsOwp2YXIgcXQ9bnouc3RhbGU/KCdub2NoIGtlaW5lIGFrdHVlbGxlIE1lc3N1bmcgwrcgJysobnoudHh0fHwnJykpOih7Z3J1ZW46J3J1aGlnJyxnZWxiOidlcmjDtmh0Jyxyb3Q6J3N0YXJrJyxncmF1OidsZXJudCd9W3EubHZsXXx8cS5sdmx8fCfigJMnKSsnIMK3ICcrbnoub2tfbisnLycrbnoubisnIELDpG5kZXIgb2sgwrcgJythZ28obnouYWdlKSsobnoucGF1c2VkPycgwrcgcGF1c2llcnQnOicnKSsobnoucGFydD8nIMK3ICcrbnoucGFydDonJyk7CnJvdyhSLG56LnN0YWxlP256bDoobnoucGFydD8nZ2VsYic6KHEubHZsPT09J2dyYXUnPydsZXJudCc6bHZsT2YocS5sdmwpKSksJ+OAsCBTdMO2cmVyL1FSTTonLHF0LChuei5iYW5kc3x8W10pLm1hcChmdW5jdGlvbihiKXtyZXR1cm4gYi5zaG9ydCsnOiAnKyhiLm9rPydvayc6KGIud2h5fHwnRmVobGVyJykpKyhiLnQ/JyDCtyAnK2htKGIudCk6JycpO30pLmpvaW4oJ1xuJykrKG56Lm5leHQ/J1xubsOkY2hzdGUgTWVzc3VuZyAnK2htKG56Lm5leHQpOicnKSk7CnZhciB0bD1uei5zdGFsZT8oJ25pY2h0IG1lc3NiYXIgwrcgJysobnoudHh0fHwnJykpOih0aC5zcmM9PT0nbGVybnQnfHx0aC5sdmw9PT0nZ3JhdSc/J2xlcm50IEdydW5kbGluaWUnOih7Z3J1ZW46J2tlaW4gR2V3aXR0ZXInLGdlbGI6J0JsaXR6ZSBtw7ZnbGljaCcscm90OidHZXdpdHRlciBuYWgnfVt0aC5sdmxdfHx0aC5sdmx8fCfigJMnKSk7CnJvdyhSLG56LnN0YWxlP256bDoodGguc3JjPT09J2xlcm50J3x8dGgubHZsPT09J2dyYXUnPydsZXJudCc6bHZsT2YodGgubHZsKSksJ+KaoSBHZXdpdHRlcjonLHRsLHRoLndoeXx8JycpOwp2YXIgZz1GKCdncHMnKTtyb3coUixnLmx2bCwn8J+bsCBEYWNoLUdQUzonLChnLmluZm98fCfigJMnKSsnIMK3ICcrYWdvKGcuYWdlKSxnLnRpcCwnL3Vtd2VsdCcpOwo=", "new": "dmFyIGJjPUYoJ2JjJykscnI9cm93KFIsYmMubHZsLCfwn5O7IFJ1bmRmdW5rOicsYmMuaW5mbysnIMK3ICcrYWdvKGJjLmFnZSkrKGJjLm5leHQ/JyDCtyBuw6RjaHN0ICcraG0oYmMubmV4dCk6JycpLGJjLnRpcCwnL3J1bmRmdW5rJyk7cnIuZGF0YXNldC5zdT0ncmYnOwp2YXIgZz1GKCdncHMnKTtyb3coUixnLmx2bCwn8J+bsCBEYWNoLUdQUzonLChnLmluZm98fCfigJMnKSsnIMK3ICcrYWdvKGcuYWdlKSxnLnRpcCwnL3Vtd2VsdCcpOwo="}, {"old": "ZnMuYXBwZW5kQ2hpbGQobXNnKTtjLmFwcGVuZENoaWxkKGZzKTtpZih3aW5kb3cuc2RyTGFnZSl3aW5kb3cuc2RyTGFnZShjLEQpOwp2YXIgcmI9ZWwoJ2J1dHRvbicsJ3N1LWJkJywnU3RpY2sgZnJlaWdlYmVuJyk7CnJiLnR5cGU9J2J1dHRvbic7CnJiLnN0eWxlLm1hcmdpblRvcD0nOHB4JzsKcmIub25jbGljaz1mdW5jdGlvbigpe2lmKCFjb25maXJtKCdTdGljayBqZXR6dCBmcmVpZ2ViZW4/JykpcmV0dXJuO3JiLmRpc2FibGVkPXRydWU7cmIudGV4dENvbnRlbnQ9J+KApic7CmZldGNoKCcvYXBpL3Nkci9yZWxlYXNlJyx7bWV0aG9kOidQT1NUJ30pLnRoZW4ocj0+ci5qc29uKCkpLnRoZW4oaj0+e2FsZXJ0KGoub2s/J0ZyZWlnYWJlIGFuZ2Vmb3JkZXJ0JzonRmVobGVyJyk7cmIuZGlzYWJsZWQ9ZmFsc2U7cmIudGV4dENvbnRlbnQ9J1N0aWNrIGZyZWlnZWJlbic7fSk7fTsKYy5hcHBlbmRDaGlsZChyYik7dGljaygpO30KZnVuY3Rpb24gdGljaygpe3ZhciB4PWRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyNzZHJVaUNhcmQgLnN1LWNkJyk7Zm9yKHZhciBpPTA7aTx4Lmxlbmd0aDtpKyspe3ZhciByPXBhcnNlSW50KHhbaV0uZGF0YXNldC51bnRpbCwxMCktbm93KCk7aWYocjw9MCl7eFtpXS50ZXh0Q29udGVudD0nIMK3IGFiZ2VsYXVmZW4nO2NvbnRpbnVlO312YXIgbW09TWF0aC5mbG9vcihyLzYwKSxzcz1yJTYwO3hbaV0udGV4dENvbnRlbnQ9JyDCtyBub2NoICcrbW0rJzonKyhzczwxMD8nMCc6JycpK3NzKycgKGJpcyAnK2htKHBhcnNlSW50KHhbaV0uZGF0YXNldC51bnRpbCwxMCkpKycpJzt9fQo=", "new": "ZnMuYXBwZW5kQ2hpbGQobXNnKTtjLmFwcGVuZENoaWxkKGZzKTtpZih3aW5kb3cuc2RyTGFnZSl3aW5kb3cuc2RyTGFnZShjLEQpOwp0aWNrKCk7fQpmdW5jdGlvbiB0aWNrKCl7dmFyIHg9ZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnI3NkclVpQ2FyZCAuc3UtY2QnKTtmb3IodmFyIGk9MDtpPHgubGVuZ3RoO2krKyl7dmFyIHI9cGFyc2VJbnQoeFtpXS5kYXRhc2V0LnVudGlsLDEwKS1ub3coKTtpZihyPD0wKXt4W2ldLnRleHRDb250ZW50PScgwrcgYWJnZWxhdWZlbic7Y29udGludWU7fXZhciBtbT1NYXRoLmZsb29yKHIvNjApLHNzPXIlNjA7eFtpXS50ZXh0Q29udGVudD0nIMK3IG5vY2ggJyttbSsnOicrKHNzPDEwPycwJzonJykrc3MrJyAoYmlzICcraG0ocGFyc2VJbnQoeFtpXS5kYXRhc2V0LnVudGlsLDEwKSkrJyknO319Cg=="}, {"old": "ICAgIGFzc2VydCBmWyJub2lzZSJdWyJsdmwiXSA9PSAicm90IiBhbmQgbmRbInN0YWxlIl0gYW5kICJ6dSB3ZW5pZyBTd2VlcHMiIGluIG5kWyJ0eHQiXSBhbmQgInZvciA5IGgiIGluIG5kWyJ0eHQiXSwgKGZbIm5vaXNlIl0sIG5kKQogICAgYXNzZXJ0IGZbIjQzMyJdWyJsdmwiXSA9PSAib2siIGFuZCAiMiBLRloiIGluIGZbIjQzMyJdWyJpbmZvIl0sIGZbIjQzMyJdCg==", "new": "ICAgIGFzc2VydCBuZFsic3RhbGUiXSBhbmQgInp1IHdlbmlnIFN3ZWVwcyIgaW4gbmRbInR4dCJdIGFuZCAidm9yIDkgaCIgaW4gbmRbInR4dCJdLCBuZAogICAgYXNzZXJ0ICI0MzMiIG5vdCBpbiBmIGFuZCAibm9pc2UiIG5vdCBpbiBmIGFuZCAiYWN0IiBub3QgaW4gZgo="}, {"old": "ICAgIGFzc2VydCBmMlsiYmMiXVsic3RhdGUiXSA9PSAiQU4iIGFuZCBmMlsiNDMzIl1bInN0YXRlIl0gPT0gIkFVUyIgYW5kIGYyWyJub2lzZSJdWyJsdmwiXSA9PSAiYXVzIiwgZjIKICAgIGIzID0gZGljdChiYXNlLCBtb2RlPXsibW9kZSI6ICI0MzMifSkK", "new": "ICAgIGFzc2VydCBmMlsiYmMiXVsic3RhdGUiXSA9PSAiQU4iIGFuZCAiNDMzIiBub3QgaW4gZjIgYW5kICJub2lzZSIgbm90IGluIGYyLCBmMgogICAgYjMgPSBkaWN0KGJhc2UsIG1vZGU9eyJtb2RlIjogImFwcnMifSkK"}, {"old": "ICAgIGFzc2VydCBmM1siNDMzIl1bInN0YXRlIl0gPT0gIkFOIiBhbmQgZjNbImFwcnMiXVsic3RhdGUiXSA9PSAiQVVTIgo=", "new": "ICAgIGFzc2VydCBmM1siYXBycyJdWyJzdGF0ZSJdID09ICJBTiIgYW5kIGYzWyJiYyJdWyJzdGF0ZSJdID09ICJBVVMiCg=="}, {"old": "ICAgIGFzc2VydCBmNFsibm9pc2UiXVsibHZsIl0gPT0gImdlbGIiIGFuZCAiMSBCw6RuZGVyIEZlaGxlciAoVUtXKTogenUgd2VuaWcgU3dlZXBzIiBpbiBmNFsibm9pc2UiXVsiaW5mbyJdLCBmNFsibm9pc2UiXQo=", "new": "ICAgIGFzc2VydCAibm9pc2UiIG5vdCBpbiBmNCBhbmQgbmRbInN0YWxlIl0K"}, {"old": "X1NMX1NSQyA9ICgiNDMzIiwgImFwcnMiLCAiYmMiLCAiYXNhIiwgIm1ldGVvciIsICJhY3QiLCAibm9pc2UiLCAiY2FsIikKX1NMX1BST0ZJTEVTID0gWygibm9ybWFsIiwgIk5vcm1hbCIsICJhbGxlcyBpbSBXZWNoc2VsIHdpZSBiaXNoZXIiKSwgKCJ3YXJuIiwgIldhcm5sYWdlIiwgIlJ1bmRmdW5rLVdhcm51bmdlbiBCUjI0ICsgQVNBIHVuZCBRUk0genVlcnN0LCBSZXN0IHNlbHRlbiIpLAogICAgICAgICAgICAgICAgKCJmdW5rIiwgIkZ1bmtsYWdlIiwgIkFQUlMsIDIgbSB1bmQgUE1SIHp1ZXJzdCIpLCAoInJ1aGUiLCAiUnVoZSIsICJudXIgS2FsaWJyaWVydW5nIChEYWNoLUdQUyBsw6R1ZnQgw7xiZXIgZ3BzZCkiKV0KX1NMX05BTUVTID0geyI0MzMiOiAiNDMzIiwgImFwcnMiOiAiQVBSUyIsICJiYyI6ICJVS1cvREFCIiwgImFzYSI6ICJBU0EgNUMiLCAibWV0ZW9yIjogIk1ldGVvciIsICJhY3QiOiAiQWt0aXZpdMOkdCIsICJub2lzZSI6ICJRUk0iLCAiY2FsIjogIkthbGlici4iLCAiZnJlaSI6ICJmcmVpIn0K", "new": "X1NMX1NSQyA9ICgiYXBycyIsICJiYyIsICJhc2EiLCAibWV0ZW9yIiwgImNhbCIpCl9TTF9QUk9GSUxFUyA9IFsoIm5vcm1hbCIsICJOb3JtYWwiLCAiQVBSUywgUnVuZGZ1bmsgdW5kIE1ldGVvciBpbSBXZWNoc2VsIiksICgid2FybiIsICJXYXJubGFnZSIsICJSdW5kZnVuay1XYXJudW5nZW4gQlIyNCB1bmQgQVNBIHp1ZXJzdCIpLAogICAgICAgICAgICAgICAgKCJmdW5rIiwgIkZ1bmtsYWdlIiwgIkFQUlMgenVlcnN0IiksICgicnVoZSIsICJSdWhlIiwgIm51ciBLYWxpYnJpZXJ1bmcgKERhY2gtR1BTIGzDpHVmdCDDvGJlciBncHNkKSIpXQpfU0xfTkFNRVMgPSB7ImFwcnMiOiAiQVBSUyIsICJiYyI6ICJVS1cvREFCIiwgImFzYSI6ICJBU0EgNUMiLCAibWV0ZW9yIjogIk1ldGVvciIsICJjYWwiOiAiS2FsaWJyLiIsICJmcmVpIjogImZyZWkifQo="}, {"old": "ICAgICAgICAgICAgJzxkaXYgY2xhc3M9InNkcnN1YiIgc3R5bGU9Im1hcmdpbjo0cHggMCAxMHB4Ij48YSBocmVmPSIvZnVuazQzMyI+8J+ToSA0MzMgTUh6PC9hPiA8YSBocmVmPSIvYXBycyI+8J+TuyBBUFJTPC9hPiA8YSBocmVmPSIvcnVuZGZ1bmsiPvCfk7sgUnVuZGZ1bms8L2E+IDxhIGhyZWY9Ii9mdW5rIj7ihqkgRnVuazwvYT48L2Rpdj4lczwvZGl2PjwvYm9keT48L2h0bWw+JykgJSAoCg==", "new": "ICAgICAgICAgICAgJzxkaXYgY2xhc3M9InNkcnN1YiIgc3R5bGU9Im1hcmdpbjo0cHggMCAxMHB4Ij48YSBocmVmPSIvYXBycyI+8J+TuyBBUFJTPC9hPiA8YSBocmVmPSIvcnVuZGZ1bmsiPvCfk7sgUnVuZGZ1bms8L2E+IDxhIGhyZWY9Ii9mdW5rIj7ihqkgRnVuazwvYT48L2Rpdj4lczwvZGl2PjwvYm9keT48L2h0bWw+JykgJSAoCg=="}, {"old": "LyogLS0tLSBTdGV1ZXJ1bmcgKGVpbmdla2xhcHB0KTogU3RpY2stMi1BbGFybSwgQXV0by1WZXJzYW5kLCBMYWdlLVByb2ZpbCwgQmV0cmllYnNhcnQsIEVpbnplbGVtcGZhbmcsIFN0aWNrIGZyZWlnZWJlbiAtLS0tICovCg==", "new": "LyogLS0tLSBTdGV1ZXJ1bmcgKGVpbmdla2xhcHB0KTogU3RpY2stMi1BbGFybSwgQXV0by1WZXJzYW5kLCBMYWdlLVByb2ZpbCwgQmV0cmllYnNhcnQsIEVpbnplbGVtcGZhbmcgLS0tLSAqLwo="}, {"old": "dmFyIFNMT1RTPVtbJ3MyJywnU3RpY2sgMiBcdTIwMTMgQWxhcm0gNUMgKEFTQSBERSknXSxbJ2FzJywnQXV0by1WZXJzYW5kIGVjaHRlciBBbGFybWUgYW4gTWVzaCAxJ10sWydwcm9mJywnTGFnZS1Qcm9maWwnXSxbJ21vZGUnLCdCZXRyaWVic2FydCddLFsnbWFuJyxudWxsXSxbJ3JlbCcsJ1N0aWNrIGZyZWlnZWJlbiddXTsK", "new": "dmFyIFNMT1RTPVtbJ3MyJywnU3RpY2sgMiBcdTIwMTMgQWxhcm0gNUMgKEFTQSBERSknXSxbJ2FzJywnQXV0by1WZXJzYW5kIGVjaHRlciBBbGFybWUgYW4gTWVzaCAxJ10sWydwcm9mJywnTGFnZS1Qcm9maWwnXSxbJ21vZGUnLCdCZXRyaWVic2FydCddLFsnbWFuJyxudWxsXV07Cg=="}, {"old": "dmFyIGZzPWMucXVlcnlTZWxlY3RvcignOnNjb3BlPmZpZWxkc2V0Jyk7aWYoZnMpcHV0KCdtYW4nLFtmc10pOwp2YXIgYnM9Yy5xdWVyeVNlbGVjdG9yQWxsKCc6c2NvcGU+YnV0dG9uLnN1LWJkJyk7aWYoYnMubGVuZ3RoKXB1dCgncmVsJyxbYnNbYnMubGVuZ3RoLTFdXSk7CnZhciBjaD1jLnF1ZXJ5U2VsZWN0b3JBbGwoJy5zdS1jaGlwJyk7Zm9yKHZhciBpPTA7aTxjaC5sZW5ndGg7aSsrKXt2YXIgaz1jaFtpXS5kYXRhc2V0Lms7Y2hbaV0uc2V0QXR0cmlidXRlKCdyb2xlJywnYnV0dG9uJyk7Y2hbaV0uc2V0QXR0cmlidXRlKCdhcmlhLWV4cGFuZGVkJyxPUEVOW2tdPyd0cnVlJzonZmFsc2UnKTtpZihPUEVOW2tdKWNoaXBPcGVuKGNoW2ldLHRydWUpO30K", "new": "dmFyIGZzPWMucXVlcnlTZWxlY3RvcignOnNjb3BlPmZpZWxkc2V0Jyk7aWYoZnMpcHV0KCdtYW4nLFtmc10pOwp2YXIgY2g9Yy5xdWVyeVNlbGVjdG9yQWxsKCcuc3UtY2hpcCcpO2Zvcih2YXIgaT0wO2k8Y2gubGVuZ3RoO2krKyl7dmFyIGs9Y2hbaV0uZGF0YXNldC5rO2NoW2ldLnNldEF0dHJpYnV0ZSgncm9sZScsJ2J1dHRvbicpO2NoW2ldLnNldEF0dHJpYnV0ZSgnYXJpYS1leHBhbmRlZCcsT1BFTltrXT8ndHJ1ZSc6J2ZhbHNlJyk7aWYoT1BFTltrXSljaGlwT3BlbihjaFtpXSx0cnVlKTt9Cg=="}, {"old": "ZGVmIF9hZ19hZnRlcihyZXNwKToKICAgIHRyeToK", "new": "ZGVmIF9hZ19hZnRlcihyZXNwKToKICAgIHJldHVybiByZXNwCiAgICB0cnk6Cg=="}, {"old": "X1NGX1BBR0VTID0gKCIvIiwgIi9waSIsICIvZnVuazQzMyIsICIvYXBycyIsICIvbWV0ZW9yIiwgIi9ydW5kZnVuayIsICIvZW5lcmdpZSIsICIvbG9rYWxlLWVuZXJnaWUiLCAiL2RhYmhpc3QiLCAiL21lc2giKQo=", "new": "X1NGX1BBR0VTID0gKCIvIiwgIi9waSIsICIvYXBycyIsICIvbWV0ZW9yIiwgIi9ydW5kZnVuayIsICIvZW5lcmdpZSIsICIvbG9rYWxlLWVuZXJnaWUiLCAiL2RhYmhpc3QiLCAiL21lc2giKQo="}, {"old": "ICAgICgiL3BpIiwgInIiLCByJz5OZXVlIFZlcnNpb246IGF1ZiBkZW0gUGkgcHl0aG9uMyBwcmVwcGVyX2RvY3NcLnB5IFwoT3JkbmVyIFtePF17MSwxNjB9XCk8L2Rpdj4nLCAiPk5ldWUgVmVyc2lvbjogcHl0aG9uMyBwcmVwcGVyX2RvY3MucHkgaW0gUHJvamVrdG9yZG5lcjwvZGl2PiIpLAogICAgIyA0MzMgTUh6IC8gS0ZaCiAgICAoIi9mdW5rNDMzIiwgInMiLCAiJ0dyw7xuIDwgMTAgbWluIMK3IEdlbGIgPCAxIGggwrcgR3JhdSDDpGx0ZXIuIE51ciBJU00tU2Vuc29yZW4gKFdldHRlciwgVGhlcm1vbWV0ZXIpOyBmcmVtZGUgU2Vuc29yZW4gZGVyIE5hY2hiYXJuIGVyc2NoZWluZW4gZWJlbmZhbGxzLiBMaXN0ZSAxNCBUYWdlLiciLAogICAgICInR3LDvG4gPCAxMCBtaW4gwrcgR2VsYiA8IDEgaCDCtyBHcmF1IMOkbHRlciDCtyBhdWNoIE5hY2hiYXItU2Vuc29yZW4gwrcgMTQgVGFnZSciKSwKICAgICgiL2Z1bms0MzMiLCAicyIsICInVm9sbGUgSURzIDMwIFRhZ2UsIGRhbmFjaCBudXIgTW9kZWxsICsgWmVpdDsgZWlnZW5lIChrZnpfb3duLmpzb24pIGRhdWVyaGFmdC4gWmVpdCBkZC5tbS55eXl5IEhIOk1NOlNTIEV1cm9wZS9CZXJsaW4sIFMxL1MyID0gU3RyYXR1bSBsYXV0IGNocm9ueSwgdW5nZW5hdSA9IG5pY2h0IHN5bmNocm9uLiciLAogICAgICInSURzIDMwIFRhZ2UsIGRhbmFjaCBudXIgTW9kZWxsIMK3IGVpZ2VuZSBkYXVlcmhhZnQgwrcgdW5nZW5hdSA9IFVociBuaWNodCBzeW5jaHJvbiciKSwKICAgICMgQVBSUyAoSGlud2VpcyBOdXIgRW1wZmFuZyBibGVpYnQpCg==", "new": "ICAgICgiL3BpIiwgInIiLCByJz5OZXVlIFZlcnNpb246IGF1ZiBkZW0gUGkgcHl0aG9uMyBwcmVwcGVyX2RvY3NcLnB5IFwoT3JkbmVyIFtePF17MSwxNjB9XCk8L2Rpdj4nLCAiPk5ldWUgVmVyc2lvbjogcHl0aG9uMyBwcmVwcGVyX2RvY3MucHkgaW0gUHJvamVrdG9yZG5lcjwvZGl2PiIpLAogICAgIyBBUFJTIChIaW53ZWlzIE51ciBFbXBmYW5nIGJsZWlidCkK"}], "prepper_sdr.py": [{"old": "ICAgICAgICBpZiBkLmdldCgicHJlc2V0IikgaW4gUFJFU0VUX0lEUyBhbmQgaXNpbnN0YW5jZSh1LCAoaW50LCBmbG9hdCkpIGFuZCB1ID4gdGltZS50aW1lKCk6Cg==", "new": "ICAgICAgICBpZiBkLmdldCgicHJlc2V0IikgaW4gUFJFU0VUX0lEUyBhbmQgZC5nZXQoInByZXNldCIpICE9ICI0MzMiIGFuZCBpc2luc3RhbmNlKHUsIChpbnQsIGZsb2F0KSkgYW5kIHUgPiB0aW1lLnRpbWUoKToK"}, {"old": "ICAgIG0gPSBkLmdldCgibW9kZSIpIGlmIGQuZ2V0KCJtb2RlIikgaW4gTU9ERVMgZWxzZSAiYXV0byIKICAgIHVudGlsID0gZC5nZXQoInVudGlsIikK", "new": "ICAgIG0gPSBkLmdldCgibW9kZSIpIGlmIGQuZ2V0KCJtb2RlIikgaW4gTU9ERVMgZWxzZSAiYXV0byIKICAgIGlmIG0gaW4gKCI0MzMiLCAidGNwIik6CiAgICAgICAgbSA9ICJhdXRvIgogICAgdW50aWwgPSBkLmdldCgidW50aWwiKQo="}, {"old": "ICAgIGlmIG1vZGUgbm90IGluIE1PREVTOgo=", "new": "ICAgIGlmIG1vZGUgaW4gKCI0MzMiLCAidGNwIikgb3IgbW9kZSBub3QgaW4gTU9ERVM6Cg=="}, {"old": "UGxhbm5lci5zdGFydCA9IF9wbl9zdGFydAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6Cg==", "new": "UGxhbm5lci5zdGFydCA9IF9wbl9zdGFydAoKX2ZjX29yaWdfbGFnZSA9IFBsYW5uZXIubGFnZV9hcHBseQpfZmNfb3JpZ193YW50ID0gUGxhbm5lci53YW50Cl9mY19vcmlnX25vaXNlID0gUGxhbm5lci5ub2lzZV9xdWV1ZQpfZmNfb3JpZ19hY3QgPSBQbGFubmVyLmFjdF9xdWV1ZQoKCmRlZiBfZmNfbGFnZShzZWxmKToKICAgIHIgPSBfZmNfb3JpZ19sYWdlKHNlbGYpCiAgICB0cnk6CiAgICAgICAgaWYgaXNpbnN0YW5jZShnZXRhdHRyKHNlbGYsICJjZmciLCBOb25lKSwgZGljdCk6CiAgICAgICAgICAgIHNlbGYuY2ZnWyJub2lzZV9lbmFibGUiXSA9IEZhbHNlCiAgICAgICAgICAgIHNlbGYuY2ZnWyJhdXRvIl0gPSBbeCBmb3IgeCBpbiAoc2VsZi5jZmcuZ2V0KCJhdXRvIikgb3IgW10pIGlmIHggIT0gIjQzMyJdCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4OgogICAgICAgIHByaW50KCJmdW5rQmVyZWluaWd1bmcgbGFnZToiLCB0eXBlKGV4KS5fX25hbWVfXywgZmx1c2g9VHJ1ZSkKICAgIHJldHVybiByCgoKZGVmIF9mY193YW50KHNlbGYsIG1vZGUsIG5vdyk6CiAgICBtID0gbW9kZQogICAgaWYgaXNpbnN0YW5jZShtb2RlLCBkaWN0KSBhbmQgbW9kZS5nZXQoIm1vZGUiKSBpbiAoIjQzMyIsICJ0Y3AiKToKICAgICAgICBtID0gZGljdChtb2RlKQogICAgICAgIG1bIm1vZGUiXSA9ICJhdXRvIgogICAgaWYgaXNpbnN0YW5jZShtLCBkaWN0KSBhbmQgbS5nZXQoIm1vZGUiKSA9PSAicHJlc2V0IjoKICAgICAgICBwcyA9IHByZXNldChtLmdldCgicHJlc2V0IikpIG9yIHt9CiAgICAgICAgaWYgcHMuZ2V0KCJpZCIpID09ICI0MzMiIG9yIHBzLmdldCgia2luZCIpID09ICJpc200MzMiOgogICAgICAgICAgICBtID0gZGljdChtKQogICAgICAgICAgICBtWyJtb2RlIl0gPSAiYXV0byIKICAgIHcgPSBfZmNfb3JpZ193YW50KHNlbGYsIG0sIG5vdykKICAgIGlmIHcgaW4gKCI0MzMiLCAidGNwIikgb3IgKGlzaW5zdGFuY2Uodywgc3RyKSBhbmQgdy5zdGFydHN3aXRoKCJuejoiKSk6CiAgICAgICAgcmV0dXJuICJhcHJzIiBpZiAiYXBycyIgaW4gKHNlbGYuY2ZnLmdldCgiYXV0byIpIG9yIFtdKSBlbHNlICJpZGxlIgogICAgcmV0dXJuIHcKCgpkZWYgX2ZjX25vaXNlKHNlbGYpOgogICAgcmV0dXJuIFtdCgoKZGVmIF9mY19hY3Qoc2VsZik6CiAgICByZXR1cm4gW10KCgpQbGFubmVyLmxhZ2VfYXBwbHkgPSBfZmNfbGFnZQpQbGFubmVyLndhbnQgPSBfZmNfd2FudApQbGFubmVyLm5vaXNlX3F1ZXVlID0gX2ZjX25vaXNlClBsYW5uZXIuYWN0X3F1ZXVlID0gX2ZjX2FjdAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6Cg=="}], "prepper_docs.py": [{"old": "U01PS0VfUEFHRVMgPSBbIi8iLCAiL2Z1bmsiLCAiL3BpIiwgIi91bXdlbHQiLCAiL2Z1bms0MzMiLCAiL2FwcnMiLCAiL21ldGVvciIsICIvcnVuZGZ1bmsiLCAiL2VuZXJnaWUiLCAiL2RhYmhpc3QiLCAiL21lc2giLCAiL2thcnRlIl0K", "new": "U01PS0VfUEFHRVMgPSBbIi8iLCAiL2Z1bmsiLCAiL3BpIiwgIi91bXdlbHQiLCAiL2FwcnMiLCAiL21ldGVvciIsICIvcnVuZGZ1bmsiLCAiL2VuZXJnaWUiLCAiL2RhYmhpc3QiLCAiL21lc2giLCAiL2thcnRlIl0K"}, {"old": "ICAgICAgICAgICAgICAiL21lZGl6aW4iLCAiL2Z1bms0MzMiLCAiL2FwcnMiLCAiL21ldGVvciIsICIvcnVuZGZ1bmsiLCAiL2RhYmhpc3QiLCAiL3Vtd2VsdDIiXQo=", "new": "ICAgICAgICAgICAgICAiL21lZGl6aW4iLCAiL2FwcnMiLCAiL21ldGVvciIsICIvcnVuZGZ1bmsiLCAiL2RhYmhpc3QiLCAiL3Vtd2VsdDIiXQo="}]}


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
