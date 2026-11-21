#!/usr/bin/env python3
# Muellkalender: neuer ICS-Export des Landkreises ERH fuer Kaeswasser.
# Nur zuhause.py. Nur prepper-dashboard neu starten.
from __future__ import annotations
import base64, hashlib, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
ALT_URL = b"https://www.erlangen-hoechstadt.de/komx/surface/dfxabfallics/GetAbfallIcs"
NEU_URL = b"https://www.erlangen-hoechstadt.de/output/options.php?ModID=48&call=ical&pois=4237.2597&alarm=0"


def load():
    raw = PAYLOAD_JSON
    return [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw]


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
    alt = sorted(path.parent.glob(path.name + ".bak-muell-*"))
    bak = path.with_name(path.name + ".bak-muell-" + stempel)
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
    tmp = path.with_name("." + path.name + ".tmp-muell")
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
    pfad = ordner / "zuhause.py"
    if pfad.is_symlink() or not pfad.is_file():
        print("STOP: zuhause.py fehlt")
        return 2
    data = pfad.read_bytes()
    print("zuhause.py sha16 %s bytes %d" % (sha(data)[:16], len(data)))
    if ALT_URL not in data and NEU_URL in data and b"biotonne" in data and b"pois=4237.2597" in data:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    if data.count(ALT_URL) != 1:
        print("STOP: die alte ICS-Adresse steht nicht genau einmal in zuhause.py. Nichts geschrieben.")
        return 2
    try:
        ziel = verwandle(data, paare)
    except RuntimeError:
        print("STOP: Anker in zuhause.py fehlt. Nichts geschrieben.")
        return 2
    try:
        compile(ziel, "zuhause.py", "exec")
    except SyntaxError as exc:
        print("STOP: Syntax %s" % exc)
        return 2
    if NEU_URL not in ziel or b"biotonne" not in ziel or ALT_URL in ziel:
        print("STOP: neuer Kalender fehlt")
        return 2
    ns = {}
    exec(compile(ziel, "zuhause.py", "exec"), ns)
    assert ns["_classify"]("Biotonne") is None
    assert ns["_classify"]("Restmuelltonne") == "rest" or ns["_classify"]("Restmülltonne") == "rest"
    print("zuhause.py endstand sha16 %s bytes %d" % (sha(ziel)[:16], len(ziel)))
    frei, meldung = fenster(jetzt)
    print(meldung)
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        return 0
    try:
        sichern(pfad, data)
        schreiben(pfad, ziel)
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    print("geschrieben. Nur prepper-dashboard, SDR und Mesh bleiben.")
    if kein or not frei:
        print("Kein Neustart. Fenster fuer den Neustart ist Minute 05-39 Berlin.")
        return 0
    __import__("subprocess").run(["systemctl", "restart", "prepper-dashboard.service"], check=False)
    print("Nur prepper-dashboard.service neu gestartet.")
    return 0


def selftest() -> int:
    assert fenster(datetime(2026, 11, 20, 22, 12))[0]
    assert fenster(datetime(2026, 11, 20, 22, 5))[0] and fenster(datetime(2026, 11, 20, 22, 39))[0]
    assert not fenster(datetime(2026, 11, 20, 22, 4))[0]
    assert not fenster(datetime(2026, 11, 20, 22, 40))[0]
    assert not fenster(datetime(2026, 11, 20, 22, 0))[0]
    import tempfile
    ordner = Path(tempfile.mkdtemp(prefix="muell-"))
    (ordner / "zuhause.py").write_bytes(b"keine adresse")
    assert apply_dir(ordner, True, True, datetime(2026, 11, 20, 22, 12)) == 2
    assert (ordner / "zuhause.py").read_bytes() == b"keine adresse"
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


PAYLOAD_JSON = [{"old": "aW1wb3J0IHRpbWUKaW1wb3J0IHVybGxpYi5wYXJzZQppbXBvcnQgdXJsbGliLnJlcXVlc3QK", "new": "aW1wb3J0IHRpbWUKaW1wb3J0IHVybGxpYi5yZXF1ZXN0Cg=="}, {"old": "SUNTX1VSTCA9ICJodHRwczovL3d3dy5lcmxhbmdlbi1ob2VjaHN0YWR0LmRlL2tvbXgvc3VyZmFjZS9kZnhhYmZhbGxpY3MvR2V0QWJmYWxsSWNzIgo=", "new": "SUNTX1VSTCA9ICJodHRwczovL3d3dy5lcmxhbmdlbi1ob2VjaHN0YWR0LmRlL291dHB1dC9vcHRpb25zLnBocD9Nb2RJRD00OCZjYWxsPWljYWwmcG9pcz00MjM3LjI1OTcmYWxhcm09MCIK"}, {"old": "U1RSQVNTRSA9ICJLw6Rzd2Fzc2VyIiAgIyBMYW5ka3JlaXMtT3J0c3RlaWw7IEFkcmVzc2UgPSBLw6Rzd2Fzc2Vyc3RyYXNzZQo=", "new": "U1RSQVNTRSA9ICJLw6Rzd2Fzc2VyIiAgIyBMYW5ka3JlaXMtT3J0c3RlaWwsIHBvaXMgNDIzNy4yNTk3OyBBZHJlc3NlID0gS8Okc3dhc3NlcnN0cmFzc2UK"}, {"old": "ICAgIGlmICJnYXJ0ZW5hYmZhbGwiIGluIHMgb3IgInByb2JsZW1hYmZhbGwiIGluIHM6Cg==", "new": "ICAgIGlmICJnYXJ0ZW5hYmZhbGwiIGluIHMgb3IgInByb2JsZW1hYmZhbGwiIGluIHMgb3IgImJpb3Rvbm5lIiBpbiBzIG9yICJiaW9tdWVsbCIgaW4gcyBvciAiYmlvbcO8bGwiIGluIHM6Cg=="}, {"old": "ICAgIGlmICJyZXN0bcO8bGwiIGluIHMgb3IgInJlc3RtdWVsbCIgaW4gcyBvciAicmVzdG3DvGxsdG9ubmUiIGluIHMgb3IgImJpb3Rvbm5lIiBpbiBzOgo=", "new": "ICAgIGlmICJyZXN0bcO8bGwiIGluIHMgb3IgInJlc3RtdWVsbCIgaW4gcyBvciAicmVzdG3DvGxsdG9ubmUiIGluIHM6Cg=="}, {"old": "ICAgIHRvZGF5ID0gZGF0ZS50b2RheSgpCiAgICB5ZWFycyA9IFt0b2RheS55ZWFyXQogICAgaWYgdG9kYXkubW9udGggPj0gMTE6CiAgICAgICAgeWVhcnMuYXBwZW5kKHRvZGF5LnllYXIgKyAxKQoKICAgIGFsbF9ldiA9IFtdCg==", "new": "ICAgIHRvZGF5ID0gZGF0ZS50b2RheSgpCiAgICBhbGxfZXYgPSBbXQo="}, {"old": "ICAgICAgICBmb3IgeSBpbiB5ZWFyczoKICAgICAgICAgICAgcSA9IHVybGxpYi5wYXJzZS51cmxlbmNvZGUoCiAgICAgICAgICAgICAgICB7Im9ydCI6IE9SVCwgInN0cmFzc2UiOiBTVFJBU1NFLCAiYWJmYWxsYXJ0IjogIkFsbGUiLCAiamFociI6IHl9CiAgICAgICAgICAgICkKICAgICAgICAgICAgdGV4dCA9IF9odHRwX2dldChmIntJQ1NfVVJMfT97cX0iKQogICAgICAgICAgICBhbGxfZXYuZXh0ZW5kKF9wYXJzZV9pY3ModGV4dCkpCg==", "new": "ICAgICAgICBhbGxfZXYuZXh0ZW5kKF9wYXJzZV9pY3MoX2h0dHBfZ2V0KElDU19VUkwpKSkK"}]


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
