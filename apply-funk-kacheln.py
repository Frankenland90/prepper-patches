#!/usr/bin/env python3
# Pinneberg-Kachel: langer Text bricht um und bleibt in der Spalte.
# prepper-sdr bleibt. Nur prepper-dashboard wird neu gestartet.
from __future__ import annotations
import base64, hashlib, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
BASIS = {
    "prepper_sdr.py": "99aeac19adae6a99",
    "lage_pages.py": "e9ea014b5a4ff121",
    "blackout_radar.py": "4ff38da718afed9d",
}
LAENGE = {
    "prepper_sdr.py": 778377,
    "lage_pages.py": 230936,
    "blackout_radar.py": 84127,
}
GUARD = ("dashboard.py", "prepper_sdr.py", "lage_pages.py", "blackout_radar.py")


def load():
    raw = PAYLOAD_JSON
    return [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw["dashboard.py"]]


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
    alt = sorted(path.parent.glob(path.name + ".bak-funkkachel-*"))
    bak = path.with_name(path.name + ".bak-funkkachel-" + stempel)
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
    tmp = path.with_name("." + path.name + ".tmp-funkkachel")
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
    falsch = False
    for name in ("prepper_sdr.py", "lage_pages.py", "blackout_radar.py"):
        ist = sha(blobs[name])
        if not ist.startswith(BASIS[name]) or len(blobs[name]) != LAENGE[name]:
            print("STOP: %s %s / %d ist nicht der Pi-Stand %s." % (name, ist[:16], len(blobs[name]), BASIS[name]))
            falsch = True
    if b"Gain-Test (Tabelle)" in blobs["dashboard.py"]:
        print("STOP: dashboard.py ist noch vor der Funk-Bereinigung 2. Nichts geschrieben.")
        falsch = True
    if falsch:
        print("STOP: Hash-Guard. Nichts geschrieben.")
        return 2
    try:
        ziel = verwandle(blobs["dashboard.py"], paare)
    except RuntimeError:
        print("STOP: Anker der Pinneberg-Kachel fehlt. Hash %s / %d. Nichts geschrieben." % (sha(blobs["dashboard.py"])[:16], len(blobs["dashboard.py"])))
        return 2
    try:
        compile(ziel, "dashboard.py", "exec")
    except SyntaxError as exc:
        print("STOP: Syntax %s" % exc)
        return 2
    if b"overflow-wrap:anywhere" not in ziel or b"word-break:break-all" not in ziel or b"minmax(0,1fr)" not in ziel:
        print("STOP: Umbruch fehlt")
        return 2
    print("dashboard.py endstand sha16 %s bytes %d" % (sha(ziel)[:16], len(ziel)))
    for name in ("prepper_sdr.py", "lage_pages.py", "blackout_radar.py"):
        print("%s unveraendert sha16 %s bytes %d" % (name, sha(blobs[name])[:16], len(blobs[name])))
    frei, meldung = fenster(jetzt)
    print(meldung)
    if blobs["dashboard.py"] == ziel:
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
        sichern(ordner / "dashboard.py", blobs["dashboard.py"])
        schreiben(ordner / "dashboard.py", ziel)
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    print("geschrieben. Nur prepper-dashboard neu starten. prepper-sdr bleibt.")
    if kein:
        print("Kein Neustart in dieser Pruefung.")
        return 0
    frei, meldung = fenster()
    print(meldung)
    if not frei:
        print("Datei ist neu. Der Neustart bleibt aus, die Minute ist nicht mehr 05-39.")
        return 2
    __import__("subprocess").run(["systemctl", "restart", "prepper-dashboard.service"], check=False)
    print("Nur prepper-dashboard.service neu gestartet.")
    return 0


def selftest() -> int:
    assert BASIS["prepper_sdr.py"] == "99aeac19adae6a99" and LAENGE["prepper_sdr.py"] == 778377
    assert BASIS["lage_pages.py"] == "e9ea014b5a4ff121" and BASIS["blackout_radar.py"] == "4ff38da718afed9d"
    assert fenster(datetime(2026, 11, 20, 22, 12))[0]
    assert fenster(datetime(2026, 11, 20, 22, 5))[0] and fenster(datetime(2026, 11, 20, 22, 39))[0]
    assert not fenster(datetime(2026, 11, 20, 22, 4))[0] and not fenster(datetime(2026, 11, 20, 22, 40))[0]
    import tempfile
    ordner = Path(tempfile.mkdtemp(prefix="funkkachel-"))
    for name in GUARD:
        (ordner / name).write_bytes(b"x")
    vorher = {name: (ordner / name).read_bytes() for name in GUARD}
    assert apply_dir(ordner, True, True, datetime(2026, 11, 20, 22, 12)) == 2
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


PAYLOAD_JSON = {"dashboard.py": [{"old": "X1BOX0NBUkQgPSAoJzxkaXYgY2xhc3M9ImNhcmQiIGlkPSJwaW5uZWJlcmdCb3giIHN0eWxlPSJtYXJnaW4tdG9wOjEycHgiPicK", "new": "X1BOX0NBUkQgPSAoJzxzdHlsZSBpZD0icG4tY3NzIj4uZ3JpZHtncmlkLXRlbXBsYXRlLWNvbHVtbnM6bWlubWF4KDAsMWZyKSBtaW5tYXgoMCwxZnIpfScKICAgICAgICAgICAgJy5ncmlkPi5jYXJke21pbi13aWR0aDowO21heC13aWR0aDoxMDAlfSNwaW5uZWJlcmdCb3h7bWF4LXdpZHRoOjEwMCU7bWluLXdpZHRoOjA7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaXppbmc6Ym9yZGVyLWJveH0nCiAgICAgICAgICAgICcjcG5TdGF0ZSwjcG5Nc2dze292ZXJmbG93LXdyYXA6YW55d2hlcmU7d29yZC1icmVhazpicmVhay1hbGw7bWF4LXdpZHRoOjEwMCU7b3ZlcmZsb3c6aGlkZGVufScKICAgICAgICAgICAgJyNwbk1zZ3N7bWF4LWhlaWdodDo4LjdlbX08L3N0eWxlPicKICAgICAgICAgICAgJzxkaXYgY2xhc3M9ImNhcmQgZnVsbCIgaWQ9InBpbm5lYmVyZ0JveCIgc3R5bGU9Im1hcmdpbi10b3A6MTJweCI+Jwo="}, {"old": "ICAgICAgICAgICAgJzxzY3JpcHQgaWQ9InBuLWpzIj4oZnVuY3Rpb24oKXt2YXIgcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgicG5TdGF0ZSIpO3ZhciBtPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJwbk1zZ3MiKTtpZighcylyZXR1cm47JwogICAgICAgICAgICAnZmV0Y2goIi9hcGkvcGlubmViZXJnIix7Y2FjaGU6Im5vLXN0b3JlIn0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpfSkudGhlbihmdW5jdGlvbihkKXsnCg==", "new": "ICAgICAgICAgICAgJzxzY3JpcHQgaWQ9InBuLWpzIj4oZnVuY3Rpb24oKXt2YXIgcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgicG5TdGF0ZSIpO3ZhciBtPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJwbk1zZ3MiKTtpZighcylyZXR1cm47JwogICAgICAgICAgICAnZnVuY3Rpb24ga3Vyeih0KXt0PVN0cmluZyh0fHwiIikucmVwbGFjZSgvXFxzKy9nLCIgIikudHJpbSgpO2lmKHQubGVuZ3RoPjQwMCl0PXQuc2xpY2UoMCwzOTkpKyLigKYiO3JldHVybiB0O30nCiAgICAgICAgICAgICdmZXRjaCgiL2FwaS9waW5uZWJlcmciLHtjYWNoZToibm8tc3RvcmUifSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCl9KS50aGVuKGZ1bmN0aW9uKGQpeycK"}, {"old": "ICAgICAgICAgICAgJ3MudGV4dENvbnRlbnQ9KGQmJmQudHh0KT9kLnR4dDoia2VpbiBFbXBmYW5nIjsnCiAgICAgICAgICAgICdpZihtKW0udGV4dENvbnRlbnQ9bXNncy5sZW5ndGg/bXNncy5tYXAoZnVuY3Rpb24oeCl7cmV0dXJuIFN0cmluZyh4LnRleHR8fCIiKTt9KS5zbGljZSgwLDUpLmpvaW4oIiDCtyAiKToiIjsnCg==", "new": "ICAgICAgICAgICAgJ3MudGV4dENvbnRlbnQ9a3VyeigoZCYmZC50eHQpP2QudHh0OiJrZWluIEVtcGZhbmciKTsnCiAgICAgICAgICAgICdpZihtKW0udGV4dENvbnRlbnQ9a3Vyeihtc2dzLmxlbmd0aD9tc2dzLm1hcChmdW5jdGlvbih4KXtyZXR1cm4gU3RyaW5nKHgudGV4dHx8IiIpO30pLnNsaWNlKDAsNSkuam9pbigiIMK3ICIpOiIiKTsnCg=="}]}


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
