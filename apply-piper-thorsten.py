#!/usr/bin/env python3
# Piper Thorsten high. Nur dashboard.py. Kein pip, kein apt.
from __future__ import annotations
import base64, hashlib, json, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
NTFY = ("b535f9f2c404626de89bd0637595354840084255179500ec272a0caecd48e452", 5831)
FIXED = {
    "prepper_sdr.py": "9b2f565c65db2090bd819fe84fe8dd7d6ca2e68d23acf29ff9934ad7d867ea62",
    "pinneberg_rolle.py": "2fb1af4ccd333e6596721fd641cdf84f86e6d3b8014fe95386e1aa77cf23f49d",
    "pinneberg_rx.py": "835b9697eda8aac521823e6e4becf655782cdda412f7c2147f36183d2b621b96",
}
PREFIX = {
    "ups_manager.py": ("6658f0ef31f060f4", 64197),
    "lage_pages.py": ("f593e87b9dd8c46a", 216599),
    "prepper_docs.py": ("eaaf54b50c03b92d", None),
}

def load():
    raw = PAYLOAD if isinstance(PAYLOAD, list) else json.loads(PAYLOAD)
    return [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw]

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def dash_ok(data: bytes) -> bool:
    return sha(data).startswith("0990ee18077c94b9")

def basis_ok(name, data: bytes) -> bool:
    if name == "ntfy_push.py":
        return sha(data) == NTFY[0] and len(data) == NTFY[1]
    if name in FIXED:
        return sha(data) == FIXED[name]
    head, size = PREFIX[name]
    if not sha(data).startswith(head):
        return False
    return size is None or len(data) == size

def fenster(now=None):
    from zoneinfo import ZoneInfo
    jetzt = now or datetime.now(ZoneInfo("Europe/Berlin"))
    m = jetzt.minute
    return (not (m >= 45 or m <= 4)), "Berlin Minute %02d" % m

def schreiben(path: Path, data: bytes):
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    tmp = path.with_name("." + path.name + ".tmp-piper")
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
    alt = sorted(path.parent.glob(path.name + ".bak-piper-*"))
    bak = path.with_name(path.name + ".bak-piper-" + stempel)
    shutil.copy2(path, bak)
    if bak.read_bytes() != data:
        bak.unlink()
        raise RuntimeError("Sicherung weicht ab")
    for alt_pfad in alt[:-2]:
        try:
            alt_pfad.unlink()
        except OSError:
            pass

def apply_dir(ordner: Path, dry: bool, kein: bool) -> int:
    pairs = load()
    namen = ["ntfy_push.py"] + list(FIXED) + list(PREFIX) + ["dashboard.py"]
    for name in namen:
        pfad = ordner / name
        if pfad.is_symlink() or not pfad.is_file():
            print("STOP: %s fehlt" % name)
            return 2
    blobs = {name: (ordner / name).read_bytes() for name in namen}
    for name in ["ntfy_push.py"] + list(FIXED) + list(PREFIX):
        if not basis_ok(name, blobs[name]):
            print("STOP: %s %s ist nicht die Basis" % (name, sha(blobs[name])[:16]))
            return 2
    dash = blobs["dashboard.py"]
    if not dash_ok(dash) or b"def _pdd_api" not in dash:
        print("STOP: dashboard.py ist nicht der Stand nach dem Projekt-Knopf")
        return 2
    if b"stimmePiper" in dash and all(dash.count(new) == 1 for _, new in pairs):
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    neu = dash
    for old, new in pairs:
        if neu.count(old) != 1 or neu.count(new) != 0:
            print("STOP: dashboard.py Stelle unbekannt")
            return 2
        vor = neu
        neu = neu.replace(old, new, 1)
        if neu.replace(new, b"", 1) != vor.replace(old, b"", 1):
            print("STOP: dashboard.py wuerde ausserhalb der Stelle geaendert")
            return 2
    if b"stimmePiper" not in neu or b"AU_PIPER" not in neu:
        print("STOP: Piper-Stelle unvollstaendig")
        return 2
    try:
        compile(neu, "dashboard.py", "exec")
    except SyntaxError as exc:
        print("STOP: Syntax %s" % exc.lineno)
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
        sichern(ordner / "dashboard.py", dash)
        schreiben(ordner / "dashboard.py", neu)
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    for name in ["ntfy_push.py"] + list(FIXED) + list(PREFIX):
        if (ordner / name).read_bytes() != blobs[name]:
            print("STOP: %s wurde angefasst" % name)
            return 3
    print("geschrieben. Nur die Stimm-Stellen in dashboard.py. aplay-Geraete unveraendert.")
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
    pairs = load()
    blob = b"VOR\n# FREMD\n"
    for old, new in pairs:
        blob += old
    neu = blob
    for old, new in pairs:
        neu = neu.replace(old, new, 1)
    assert b"# FREMD" in neu and b"stimmePiper" in neu and b"plughw" not in neu.split(b"stimmePiper")[0][-20:]
    assert basis_ok("ups_manager.py", b"x") is False
    assert fenster(datetime(2026, 11, 12, 12, 10))[0]
    assert not fenster(datetime(2026, 11, 12, 11, 50))[0]
    assert dash_ok(b"x" * 100) is False
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

PAYLOAD = [{"old": "VDRfS0lMTF9DT01NID0gKCJhcGxheSIsICJlc3BlYWstbmciLCAiZXNwZWFrIiwgIm1icm9sYSIpICAjIEtpbGwtU3dpdGNoOiBnZW5hdSBkaWVzZSBOYW1lbiwgbnVyIGVpZ2VuZXIgQmVudXR6ZXIgKG1icm9sYSBpc3QgS2luZCB2b24gZXNwZWFrLW5nKQo=", "new": "VDRfS0lMTF9DT01NID0gKCJhcGxheSIsICJlc3BlYWstbmciLCAiZXNwZWFrIiwgIm1icm9sYSIsICJwaXBlciIpICAjIEtpbGwtU3dpdGNoOiBnZW5hdSBkaWVzZSBOYW1lbiwgbnVyIGVpZ2VuZXIgQmVudXR6ZXIgKG1icm9sYSBpc3QgS2luZCB2b24gZXNwZWFrLW5nLCBwaXBlciBlaWdlbmVzIEtpbmQpCg=="}, {"old": "QVVfTUJST0xBX0RCID0gIi91c3Ivc2hhcmUvbWJyb2xhL2RlNy9kZTciCg==", "new": "QVVfTUJST0xBX0RCID0gIi91c3Ivc2hhcmUvbWJyb2xhL2RlNy9kZTciCiMgPT09PT0gc3RpbW1lUGlwZXI6IFRob3JzdGVuIGhpZ2gsIG51ciBsb2thbGUgRGF0ZWllbi4gS2VpbiBOZXR6LCBrZWluIHBpcC4gYXBsYXktR2VyYWV0ZSBibGVpYmVuLiA9PT09PQpBVV9QSVBFUiA9ICIvaG9tZS9mbWcvcGlwZXIvYmluL3BpcGVyIgpBVV9QSVBFUl9NT0RFTCA9ICIvaG9tZS9mbWcvcGlwZXIvZGVfREUtdGhvcnN0ZW4taGlnaC5vbm54IgpBVV9QSVBFUl9DRkcgPSBBVV9QSVBFUl9NT0RFTCArICIuanNvbiIK"}, {"old": "ZGVmIF9hdV9zcGF3bihhcmd2LCBlbnY9Tm9uZSk6CiAgICBpZiBub3QgYXJndiBvciAoYXJndlswXSBub3QgaW4gQVVfRVhFWzE6XSBhbmQgYXJndlswXSBub3QgaW4gQVVfU0FZX0VYRSk6Cg==", "new": "ZGVmIF9hdV9zcGF3bihhcmd2LCBlbnY9Tm9uZSwgc3RkaW5fdGV4dD1Ob25lKToKICAgIGlmIG5vdCBhcmd2IG9yIChhcmd2WzBdIG5vdCBpbiBBVV9FWEVbMTpdIGFuZCBhcmd2WzBdIG5vdCBpbiBBVV9TQVlfRVhFIGFuZCBhcmd2WzBdICE9IEFVX1BJUEVSKToK"}, {"old": "ICAgICAgICBleGUgPSBfYXVfd2hpY2goYXJndlswXSkK", "new": "ICAgICAgICBleGUgPSBhcmd2WzBdIGlmIGFyZ3ZbMF0gPT0gQVVfUElQRVIgYW5kIF9hdV9leGlzdHMoYXJndlswXSkgZWxzZSBfYXVfd2hpY2goYXJndlswXSkK"}, {"old": "ICAgICAgICBwID0gX2F1X3NwLlBvcGVuKFtleGVdICsgbGlzdChhcmd2WzE6XSksIHN0ZGluPV9hdV9zcC5ERVZOVUxMLCBzdGRvdXQ9X2F1X3NwLkRFVk5VTEwsIHN0ZGVycj1fYXVfc3AuUElQRSwgZW52PWUpCg==", "new": "ICAgICAgICBwID0gX2F1X3NwLlBvcGVuKFtleGVdICsgbGlzdChhcmd2WzE6XSksIHN0ZGluPV9hdV9zcC5QSVBFIGlmIHN0ZGluX3RleHQgaXMgbm90IE5vbmUgZWxzZSBfYXVfc3AuREVWTlVMTCwKICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1fYXVfc3AuREVWTlVMTCwgc3RkZXJyPV9hdV9zcC5QSVBFLCBlbnY9ZSkKICAgICAgICBpZiBzdGRpbl90ZXh0IGlzIG5vdCBOb25lOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBwLnN0ZGluLndyaXRlKHN0cihzdGRpbl90ZXh0KS5lbmNvZGUoInV0Zi04IikpCiAgICAgICAgICAgICAgICBwLnN0ZGluLmNsb3NlKCkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHBhc3MK"}, {"old": "ICAgICAgICAgICAgaWYgY29tbSA9PSAibWJyb2xhIiBhbmQgX2F1X29zLnN0YXQoIi9wcm9jLyVzIiAlIGQpLnN0X3VpZCA9PSBtZToK", "new": "ICAgICAgICAgICAgaWYgY29tbSBpbiAoIm1icm9sYSIsICJwaXBlciIpIGFuZCBfYXVfb3Muc3RhdCgiL3Byb2MvJXMiICUgZCkuc3RfdWlkID09IG1lOgo="}, {"old": "ICAgICAgICBfQVVbIm1iX2NhY2hlIl0gPSAobm93LCBvaykKICAgIHJldHVybiBvawoKCg==", "new": "ICAgICAgICBfQVVbIm1iX2NhY2hlIl0gPSAobm93LCBvaykKICAgIHJldHVybiBvawoKCmRlZiBfYXVfcGlwZXJfcmVhZHkoKToKICAgICIiIkxva2FsZSBCaW5hcnkgdW5kIGJlaWRlIE1vZGVsbGRhdGVpZW4uIEtlaW4gYXB0LCBrZWluIE5ldHouIiIiCiAgICBub3cgPSBfYXVfdGltZS50aW1lKCkKICAgIGlmIG5vdCBfQVUuZ2V0KCJmYWtlIik6CiAgICAgICAgYyA9IF9BVS5nZXQoInBpcGVyX2NhY2hlIikKICAgICAgICBpZiBpc2luc3RhbmNlKGMsIHR1cGxlKSBhbmQgbm93IC0gY1swXSA8IDMwOgogICAgICAgICAgICByZXR1cm4gY1sxXQogICAgb2sgPSBfYXVfZXhpc3RzKEFVX1BJUEVSKSBhbmQgX2F1X2V4aXN0cyhBVV9QSVBFUl9NT0RFTCkgYW5kIF9hdV9leGlzdHMoQVVfUElQRVJfQ0ZHKQogICAgaWYgbm90IF9BVS5nZXQoImZha2UiKToKICAgICAgICBfQVVbInBpcGVyX2NhY2hlIl0gPSAobm93LCBvaykKICAgIHJldHVybiBvawoKCg=="}, {"old": "ICAgICIiIlJlaWhlbmZvbGdlLiBtYi1kZTcgbnVyIG1pdCBCaW5hcnkgdW5kIERhdGVpOyBkYW5hY2ggZXNwZWFrLW5nIC12IGRlLCBkYW5hY2ggZXNwZWFrIC12IGRlLiIiIgo=", "new": "ICAgICIiIlJlaWhlbmZvbGdlIG5hY2ggUGlwZXIuIG1iLWRlNyBudXIgbWl0IEJpbmFyeSB1bmQgRGF0ZWk7IGRhbmFjaCBlc3BlYWstbmcgLXYgZGUsIGRhbmFjaCBlc3BlYWsgLXYgZGUuIiIiCg=="}, {"old": "ZGVmIF9hdV92b2ljZV9sYWJlbCgpOgo=", "new": "ZGVmIF9hdV92b2ljZV9sYWJlbCgpOgogICAgaWYgX2F1X3BpcGVyX3JlYWR5KCk6CiAgICAgICAgcmV0dXJuICJTdGltbWUgcGlwZXIgdGhvcnN0ZW4taGlnaCIK"}, {"old": "ICAgIHJldHVybiAiU3RpbW1lIGZlaGx0IgoKCg==", "new": "ICAgIHJldHVybiAiU3RpbW1lIGZlaGx0IgoKCmRlZiBfYXVfc3ludGhfd2FpdChwLCBsaW0sIGFib3J0ZWQpOgogICAgaWYgcCBpcyBOb25lOgogICAgICAgIHJldHVybiBGYWxzZSwgIlByb2dyYW1tIGZlaGx0IgogICAgZW5kID0gX2F1X3RpbWUudGltZSgpICsgbGltCiAgICB3aGlsZSBwLnBvbGwoKSBpcyBOb25lOgogICAgICAgIGlmIGFib3J0ZWQoKToKICAgICAgICAgICAgX2F1X2tpbGxfY3VyKCkKICAgICAgICAgICAgcmV0dXJuIEZhbHNlLCAiYWJnZWJyb2NoZW4iCiAgICAgICAgaWYgX2F1X3RpbWUudGltZSgpID4gZW5kOgogICAgICAgICAgICBfYXVfa2lsbF9jdXIoKQogICAgICAgICAgICByZXR1cm4gRmFsc2UsICJaZWl0bGltaXQgJWQgcyIgJSBsaW0KICAgICAgICBfYXVfdGltZS5zbGVlcCgwLjA1KQogICAgaWYgcC5wb2xsKCkgPT0gMDoKICAgICAgICByZXR1cm4gVHJ1ZSwgIm9rIgogICAgZXJyID0gIiIKICAgIHRyeToKICAgICAgICBlcnIgPSAocC5zdGRlcnIucmVhZCgpIG9yIGIiIikuZGVjb2RlKCJ1dGYtOCIsICJyZXBsYWNlIikgaWYgZ2V0YXR0cihwLCAic3RkZXJyIiwgTm9uZSkgZWxzZSAiIgogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gRmFsc2UsICJyYyAlcyVzIiAlIChwLnBvbGwoKSwgKCIgIiArICIgIi5qb2luKGVyci5zcGxpdCgpKVs6NjBdKSBpZiBlcnIgZWxzZSAiIikKCgo="}, {"old": "ICAgICIiIlNjaHJlaWJ0IHdhdi4gLT4gKG9rLCBzdGltbWUsIGdydW5kKS4gQWJicnVjaCBzcHJpY2h0IG5pY2h0IHdlaXRlci4gS2VpbiBOZXR6LiIiIgo=", "new": "ICAgICIiIlNjaHJlaWJ0IHdhdi4gUGlwZXIsIHNvbnN0IG1iLWRlNywgc29uc3QgZXNwZWFrLW5nIC12IGRlLiBBYmJydWNoIHNwcmljaHQgbmljaHQgd2VpdGVyLiBLZWluIE5ldHouIiIiCg=="}, {"old": "ICAgIGxhc3QsIHZvaWNlID0gIm5pY2h0IHZlcnN1Y2h0IiwgImRlIgo=", "new": "ICAgIGxhc3QsIHZvaWNlID0gIm5pY2h0IHZlcnN1Y2h0IiwgImRlIgogICAgaWYgX2F1X3BpcGVyX3JlYWR5KCk6CiAgICAgICAgdm9pY2UgPSAicGlwZXIiCiAgICAgICAgaWYgYWJvcnRlZCgpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UsIHZvaWNlLCAiYWJnZWJyb2NoZW4iCiAgICAgICAgdHJ5OgogICAgICAgICAgICBpZiBfYXVfb3MucGF0aC5pc2ZpbGUod2F2KToKICAgICAgICAgICAgICAgIF9hdV9vcy5yZW1vdmUod2F2KQogICAgICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgICAgICBwYXNzCiAgICAgICAgbGltID0gQVVfTElNSVRbInNheSJdCiAgICAgICAgZmwgPSAoX0FVLmdldCgiZmFrZSIpIG9yIHt9KS5nZXQoInNheV9saW1pdCIpCiAgICAgICAgaWYgaXNpbnN0YW5jZShmbCwgKGludCwgZmxvYXQpKSBhbmQgZmwgPiAwOgogICAgICAgICAgICBsaW0gPSBmbAogICAgICAgIG9rLCB3aHkgPSBfYXVfc3ludGhfd2FpdChfYXVfc3Bhd24oW0FVX1BJUEVSLCAiLS1tb2RlbCIsIEFVX1BJUEVSX01PREVMLCAiLS1vdXRwdXRfZmlsZSIsIHdhdl0sIHN0ZGluX3RleHQ9dGV4dCksIGxpbSwgYWJvcnRlZCkKICAgICAgICBpZiB3aHkgPT0gImFiZ2Vicm9jaGVuIiBvciBhYm9ydGVkKCk6CiAgICAgICAgICAgIHJldHVybiBGYWxzZSwgdm9pY2UsICJhYmdlYnJvY2hlbiIKICAgICAgICBpZiBvayBhbmQgX2F1X3dhdl9vayh3YXYpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZSwgdm9pY2UsICJvayIKICAgICAgICBsYXN0ID0gd2h5IGlmIG5vdCBvayBlbHNlICJEYXRlaSB6dSBrbGVpbiIK"}, {"old": "ICAgICAgICAgICAgICAgICJzdGltbWUiOiB7ImlkIjogQVVfVk9JQ0VfTUIgaWYgX2F1X21icm9sYV9yZWFkeSgpIGVsc2UgImRlIiwgImJlcmVpdCI6IF9hdV9tYnJvbGFfcmVhZHkoKSwgInRleHQiOiBfYXVfdm9pY2VfbGFiZWwoKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgInBha2V0IjogIm1icm9sYSArIG1icm9sYS1kZTcsIG5pY2h0IHZvbiBkaWVzZW0gUGF0Y2ggaW5zdGFsbGllcnQifSwK", "new": "ICAgICAgICAgICAgICAgICJzdGltbWUiOiB7ImlkIjogInBpcGVyIiBpZiBfYXVfcGlwZXJfcmVhZHkoKSBlbHNlIChBVV9WT0lDRV9NQiBpZiBfYXVfbWJyb2xhX3JlYWR5KCkgZWxzZSAiZGUiKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgImJlcmVpdCI6IF9hdV9waXBlcl9yZWFkeSgpIG9yIF9hdV9tYnJvbGFfcmVhZHkoKSwgInRleHQiOiBfYXVfdm9pY2VfbGFiZWwoKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgInBha2V0IjogInBpcGVyIHRob3JzdGVuLWhpZ2ggbG9rYWwsIHNvbnN0IG1icm9sYS1kZTcsIG5pY2h0IHZvbiBkaWVzZW0gUGF0Y2ggaW5zdGFsbGllcnQifSwK"}, {"old": "ICAgICAgICAgICAgICAgICAgICAgICAgICJpc2ZpbGUiOiBsYW1iZGEgcDogRmFsc2UgaWYgcCA9PSBBVV9NQlJPTEFfREIgZWxzZSBfYXVfb3MucGF0aC5pc2ZpbGUocCl9LCBkZXZfb2s9Tm9uZSwK", "new": "ICAgICAgICAgICAgICAgICAgICAgICAgICJpc2ZpbGUiOiBsYW1iZGEgcDogRmFsc2UgaWYgcCBpbiAoQVVfTUJST0xBX0RCLCBBVV9QSVBFUiwgQVVfUElQRVJfTU9ERUwsIEFVX1BJUEVSX0NGRykgZWxzZSBfYXVfb3MucGF0aC5pc2ZpbGUocCl9LCBkZXZfb2s9Tm9uZSwK"}, {"old": "ICAgICAgICAgICAgYXNzZXJ0ICJtYnJvbGEiIGluIFQ0X0tJTExfQ09NTSBhbmQgImVzcGVhayIgaW4gVDRfS0lMTF9DT01NIGFuZCAiX2F1X3N5bnRoIiBpbiBfdDRfY2FzY2FkZS5fX2NvZGVfXy5jb19jb25zdHMK", "new": "ICAgICAgICAgICAgYXNzZXJ0ICJtYnJvbGEiIGluIFQ0X0tJTExfQ09NTSBhbmQgImVzcGVhayIgaW4gVDRfS0lMTF9DT01NIGFuZCAicGlwZXIiIGluIFQ0X0tJTExfQ09NTSBhbmQgIl9hdV9zeW50aCIgaW4gX3Q0X2Nhc2NhZGUuX19jb2RlX18uY29fY29uc3RzCiAgICAgICAgICAgIGRlZiBwc3Bhd24oYXJndiwgZW52KToKICAgICAgICAgICAgICAgIHZvaWNlcy5hcHBlbmQobGlzdChhcmd2KSkKICAgICAgICAgICAgICAgIGlmICItLW91dHB1dF9maWxlIiBpbiBhcmd2OgogICAgICAgICAgICAgICAgICAgIGkgPSBhcmd2LmluZGV4KCItLW91dHB1dF9maWxlIikKICAgICAgICAgICAgICAgICAgICBkYXRhID0gYiIiIGlmIF9BVVsiZmFrZSJdLmdldCgidm1vZGUiKSA9PSAicGlwZXIta2xlaW4iIGVsc2UgKGIiUiIgKiAxMjAwKQogICAgICAgICAgICAgICAgICAgIGlmIF9BVVsiZmFrZSJdLmdldCgidm1vZGUiKSAhPSAicGlwZXItcmMiOgogICAgICAgICAgICAgICAgICAgICAgICB3aXRoIG9wZW4oYXJndltpICsgMV0sICJ3YiIpIGFzIGZoOgogICAgICAgICAgICAgICAgICAgICAgICAgICAgZmgud3JpdGUoZGF0YSkKICAgICAgICAgICAgICAgICAgICByZXR1cm4gX0F1RmFrZVAoMSBpZiBfQVVbImZha2UiXS5nZXQoInZtb2RlIikgPT0gInBpcGVyLXJjIiBlbHNlIDAsIGIiZmFpbCIgaWYgX0FVWyJmYWtlIl0uZ2V0KCJ2bW9kZSIpID09ICJwaXBlci1yYyIgZWxzZSBiIiIpCiAgICAgICAgICAgICAgICByZXR1cm4gdnNwYXduKGFyZ3YsIGVudikKICAgICAgICAgICAgX0FVWyJmYWtlIl1bInNwYXduIl0gPSBwc3Bhd24KICAgICAgICAgICAgX0FVWyJmYWtlIl1bImlzZmlsZSJdID0gbGFtYmRhIHA6IHAgaW4gKEFVX1BJUEVSLCBBVV9QSVBFUl9NT0RFTCwgQVVfUElQRVJfQ0ZHKSBvciAocCA9PSBBVV9NQlJPTEFfREIgYW5kIF9BVVsiZmFrZSJdLmdldCgibWIiKSBpcyBUcnVlKQogICAgICAgICAgICBfQVVbImZha2UiXVsibWIiXSA9IFRydWUKICAgICAgICAgICAgX0FVWyJmYWtlIl1bInZtb2RlIl0gPSAiIgogICAgICAgICAgICBfQVVbImFib3J0Il0gPSBGYWxzZQogICAgICAgICAgICBkZWwgdm9pY2VzWzpdCiAgICAgICAgICAgIG9rLCB2b2ljZSwgd2h5ID0gX2F1X3N5bnRoKHR3LCAiUHJvYmUiLCAiODAiKQogICAgICAgICAgICBhc3NlcnQgb2sgYW5kIHZvaWNlID09ICJwaXBlciIgYW5kIGxlbih2b2ljZXMpID09IDEgYW5kIHZvaWNlc1swXVswXSA9PSBBVV9QSVBFUiBhbmQgIi0tbW9kZWwiIGluIHZvaWNlc1swXSBhbmQgImh0dHAiIG5vdCBpbiAiICIuam9pbih2b2ljZXNbMF0pLCB2b2ljZXMKICAgICAgICAgICAgZGVsIHZvaWNlc1s6XQogICAgICAgICAgICBfQVVbImZha2UiXVsidm1vZGUiXSA9ICJwaXBlci1yYyIKICAgICAgICAgICAgX0FVWyJmYWtlIl1bImJpbnMiXSA9IHsibWJyb2xhIiwgImVzcGVhay1uZyIsICJlc3BlYWsiLCAiYXBsYXkifQogICAgICAgICAgICBvaywgdm9pY2UsIHdoeSA9IF9hdV9zeW50aCh0dywgIlByb2JlIiwgIjEwMCIpCiAgICAgICAgICAgIGFzc2VydCBvayBhbmQgdm9pY2UgPT0gIm1iLWRlNyIgYW5kIHZvaWNlc1swXVswXSA9PSBBVV9QSVBFUiBhbmQgYW55KGFbMjozXSA9PSBbIm1iLWRlNyJdIGZvciBhIGluIHZvaWNlc1sxOl0pLCAodm9pY2UsIHdoeSwgW2FbOjNdIGZvciBhIGluIHZvaWNlc10pCiAgICAgICAgICAgIGRlbCB2b2ljZXNbOl0KICAgICAgICAgICAgX0FVWyJmYWtlIl1bIm1iIl0gPSBGYWxzZQogICAgICAgICAgICBfQVVbImZha2UiXVsiYmlucyJdID0geyJlc3BlYWstbmciLCAiZXNwZWFrIiwgImFwbGF5In0KICAgICAgICAgICAgb2ssIHZvaWNlLCB3aHkgPSBfYXVfc3ludGgodHcsICJQcm9iZSIsICIxMDAiKQogICAgICAgICAgICBhc3NlcnQgb2sgYW5kIHZvaWNlID09ICJkZSIgYW5kIHZvaWNlc1swXVswXSA9PSBBVV9QSVBFUiBhbmQgWyJlc3BlYWstbmciLCAiLXYiLCAiZGUiLCAiLXMiLCAiMTQwIiwgIi1hIiwgIjEwMCIsICItdyJdIGluIFthWzo4XSBmb3IgYSBpbiB2b2ljZXNdLCAodm9pY2UsIHdoeSwgW2FbOjNdIGZvciBhIGluIHZvaWNlc10pCg=="}, {"old": "ICAgIHJldHVybiAiYXVkaW9LZXJuIG9rIChUb2VuZSBrbGljay9nb25nL3JhdXNjaCBkZXRlcm1pbmlzdGlzY2g7IFN0dWZlbiBLQVRBU1RST1BIRT5XQVJOVU5HPklORk8sIEtBVEFTVFJPUEhFIGltbWVyIDEwMCAlJSBkYW5uIEJlbnV0emVyd2VydCwgV2FlY2h0ZXIgJWQgczsgSU5GTy9XQVJOVU5HIFN0YW5kYXJkIEFVUywgTmFjaHRydWhlIDIyLTA3LCBzdHVtbSBtYXggJWQgaCwgNiBoIER1YmxldHRlbnNjaHV0eiwgQnVkZ2V0IElORk8gJWQvaCBXQVJOVU5HICVkL2g7IEF1c2dhYmV3ZWcgcHVsc2U+ZGVmYXVsdD5wbHVnaHcgbWl0IFplaXRsaW1pdDsgU3RpbW1lIG1iLWRlNyBudXIgbWl0IGxva2FsZXIgRGF0ZWksIHNvbnN0IGVzcGVhay1uZyAtdiBkZSwgc29uc3QgZXNwZWFrIC12IGRlOyBnZW9SZWxldmFuei1IYWx0IG9obmUgVG9uOyBUZXN0IG5pZSBNZXNoKSIgJSAoCg==", "new": "ICAgIHJldHVybiAiYXVkaW9LZXJuIG9rIChUb2VuZSBrbGljay9nb25nL3JhdXNjaCBkZXRlcm1pbmlzdGlzY2g7IFN0dWZlbiBLQVRBU1RST1BIRT5XQVJOVU5HPklORk8sIEtBVEFTVFJPUEhFIGltbWVyIDEwMCAlJSBkYW5uIEJlbnV0emVyd2VydCwgV2FlY2h0ZXIgJWQgczsgSU5GTy9XQVJOVU5HIFN0YW5kYXJkIEFVUywgTmFjaHRydWhlIDIyLTA3LCBzdHVtbSBtYXggJWQgaCwgNiBoIER1YmxldHRlbnNjaHV0eiwgQnVkZ2V0IElORk8gJWQvaCBXQVJOVU5HICVkL2g7IEF1c2dhYmV3ZWcgcHVsc2U+ZGVmYXVsdD5wbHVnaHcgbWl0IFplaXRsaW1pdDsgU3RpbW1lIHBpcGVyIHRob3JzdGVuLWhpZ2gsIHNvbnN0IG1iLWRlNywgc29uc3QgZXNwZWFrLW5nIC12IGRlOyBnZW9SZWxldmFuei1IYWx0IG9obmUgVG9uOyBUZXN0IG5pZSBNZXNoKSIgJSAoCg=="}, {"old": "ICAgICAgICAgICAgJ0Fuc2FnZTogbWItZGU3LCB3ZW5uIE1CUk9MQSBsb2thbCBkYSBpc3QsIHNvbnN0IGRpZSBiaXNoZXJpZ2UgZXNwZWFrLVN0aW1tZS48L2Rpdj4nCg==", "new": "ICAgICAgICAgICAgJ0Fuc2FnZTogdGhvcnN0ZW4taGlnaCwgc29uc3QgbWItZGU3LCBzb25zdCBlc3BlYWsuPC9kaXY+Jwo="}]

if __name__ == "__main__":
    sys.exit(main(sys.argv))
