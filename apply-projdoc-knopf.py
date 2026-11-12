#!/usr/bin/env python3
# Button Jetzt erzeugen in der Projektbeschreibung. Nur dashboard.py.
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
    tmp = path.with_name("." + path.name + ".tmp-pddoc")
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
    alt = sorted(path.parent.glob(path.name + ".bak-pddoc-*"))
    bak = path.with_name(path.name + ".bak-pddoc-" + stempel)
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
    if b"def _hbmesh_after" not in dash:
        print("STOP: HB-Schalter fehlt")
        return 2
    if b"def _pdd_api" in dash and all(dash.count(new) == 1 for _, new in pairs):
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
    if b"def _pdd_api" not in neu or b"Jetzt erzeugen" not in neu:
        print("STOP: Button unvollstaendig")
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
    print("geschrieben. Nur die Projektbeschreibungs-Stellen in dashboard.py.")
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
    assert b"# FREMD" in neu and b"def _pdd_api" in neu and b"Jetzt erzeugen" in neu
    assert basis_ok("ups_manager.py", b"x") is False
    assert fenster(datetime(2026, 11, 12, 12, 10))[0]
    assert not fenster(datetime(2026, 11, 12, 11, 50))[0]
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

PAYLOAD = [{"old": "aW1wb3J0IGh0bWwgYXMgX3BkX2h0bWwK", "new": "aW1wb3J0IGh0bWwgYXMgX3BkX2h0bWwKaW1wb3J0IHN5cyBhcyBfcGRfc3lzCmltcG9ydCB0aW1lIGFzIF9wZF90aW1lCg=="}, {"old": "ICAgICAgICAgICAnI3Byb2pEb2NCb3ggZGV0YWlsc3ttYXJnaW4tdG9wOjhweDtmb250LXNpemU6MTJweH0jcHJvakRvY0JveCBkZXRhaWxzIGF7Y29sb3I6IzYwYTVmYX08L3N0eWxlPicpCg==", "new": "ICAgICAgICAgICAnI3Byb2pEb2NCb3ggZGV0YWlsc3ttYXJnaW4tdG9wOjhweDtmb250LXNpemU6MTJweH0jcHJvakRvY0JveCBkZXRhaWxzIGF7Y29sb3I6IzYwYTVmYX0nCiAgICAgICAgICAgJyNwcm9qRG9jQm94IGJ1dHRvbi5wZC1idG57Ym9yZGVyOjA7Y3Vyc29yOnBvaW50ZXJ9I3Byb2pEb2NCb3ggYnV0dG9uLnBkLWJ0bjpkaXNhYmxlZHtvcGFjaXR5Oi41O2N1cnNvcjpkZWZhdWx0fTwvc3R5bGU+JykKICAgIF9wZF9idWlsZCA9ICgnPGRpdiBzdHlsZT0ibWFyZ2luLXRvcDo4cHgiPjxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0icGRCdWlsZCIgY2xhc3M9InBkLWJ0biI+SmV0enQgZXJ6ZXVnZW48L2J1dHRvbj4nCiAgICAgICAgICAgICAgICAgJzxzcGFuIGlkPSJwZEJ1aWxkTXNnIiBzdHlsZT0ibWFyZ2luLWxlZnQ6OHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiNmYmJmMjQiPjwvc3Bhbj48L2Rpdj4nKQo="}, {"old": "ICAgICAgICAgICAgICAgICAgICAgICc8ZGl2IGNsYXNzPSJzbWFsbCIgc3R5bGU9ImZvbnQtc2l6ZTouNzJyZW07Y29sb3I6Izk0YTNiOCI+Tm9jaCBrZWluZSBWZXJzaW9uIHZvcmhhbmRlbiAtIGF1ZiBkZW0gUGkgaW4gL2hvbWUvZm1nL3ByZXBwZXItZGFzaGJvYXJkOiBweXRob24zIHByZXBwZXJfZG9jcy5weTwvZGl2PjwvZGl2PicpCg==", "new": "ICAgICAgICAgICAgICAgICAgICAgICc8ZGl2IGNsYXNzPSJzbWFsbCIgc3R5bGU9ImZvbnQtc2l6ZTouNzJyZW07Y29sb3I6Izk0YTNiOCI+Tm9jaCBrZWluZSBWZXJzaW9uIHZvcmhhbmRlbjwvZGl2PiVzPC9kaXY+JyAlIF9wZF9idWlsZCkK"}, {"old": "ICAgICAgICAnPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHg7ZmxleC13cmFwOndyYXA7bWFyZ2luLXRvcDo4cHgiPiVzPC9kaXY+JXMnCiAgICAgICAgJzxkaXYgY2xhc3M9InNtYWxsIiBzdHlsZT0iZm9udC1zaXplOi43MnJlbTtjb2xvcjojOTRhM2I4O21hcmdpbi10b3A6NnB4Ij5OZXVlIFZlcnNpb246IGF1ZiBkZW0gUGkgcHl0aG9uMyBwcmVwcGVyX2RvY3MucHkgKE9yZG5lciAvaG9tZS9mbWcvcHJlcHBlci1kYXNoYm9hcmQpPC9kaXY+PC9kaXY+JwogICAgICAgICUgKHZlciwgdmVyLCBfcGRfZm10X3Zlcih2ZXIpLCBzaXplcywgdmVyLCAiIi5qb2luKHBhcnRzKSwgb2xkKSkK", "new": "ICAgICAgICAnPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHg7ZmxleC13cmFwOndyYXA7bWFyZ2luLXRvcDo4cHgiPiVzPC9kaXY+JXMlczwvZGl2PicKICAgICAgICAlICh2ZXIsIHZlciwgX3BkX2ZtdF92ZXIodmVyKSwgc2l6ZXMsIHZlciwgIiIuam9pbihwYXJ0cyksIG9sZCwgX3BkX2J1aWxkKSkK"}, {"old": "ICAgICAgICAgICJkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdET01Db250ZW50TG9hZGVkJyxtdik7d2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2xvYWQnLG12KTtzZXRUaW1lb3V0KG12LDkwMCk7c2V0VGltZW91dChtdiwyMDAwKTtzZXRUaW1lb3V0KG12LDQ1MDApO30pKCk7PC9zY3JpcHQ+IikK", "new": "ICAgICAgICAgICJkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdET01Db250ZW50TG9hZGVkJyxtdik7d2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2xvYWQnLG12KTtzZXRUaW1lb3V0KG12LDkwMCk7c2V0VGltZW91dChtdiwyMDAwKTtzZXRUaW1lb3V0KG12LDQ1MDApOyIKICAgICAgICAgICJ2YXIgYnRuPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwZEJ1aWxkJyksbXNnPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwZEJ1aWxkTXNnJyksc3RhcnRlZD1mYWxzZTsiCiAgICAgICAgICAiZnVuY3Rpb24gc2hvdyhkKXtpZighYnRuKXJldHVybjtidG4uZGlzYWJsZWQ9ISEoZCYmZC5ydW5uaW5nKTtpZihtc2cpbXNnLnRleHRDb250ZW50PShkJiZkLnJ1bm5pbmcpPydlcnpldWd0IOKApic6KChkJiZkLmVycik/U3RyaW5nKGQuZXJyKS5zbGljZSgwLDE2MCk6JycpO30iCiAgICAgICAgICAiZnVuY3Rpb24gcG9zdChhY3Qpe3JldHVybiBmZXRjaCgnL2FwaS9kb2NzL2J1aWxkJyx7bWV0aG9kOidQT1NUJyxjcmVkZW50aWFsczonc2FtZS1vcmlnaW4nLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJywnWC1Qcm9qLURvYyc6JzEnfSwiCiAgICAgICAgICAiYm9keTpKU09OLnN0cmluZ2lmeShhY3Q9PT0nc3RhcnQnP3thY3Rpb246J3N0YXJ0Jyxjb25maXJtOnRydWV9OnthY3Rpb246J3N0YXR1cyd9KX0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pO30iCiAgICAgICAgICAiZnVuY3Rpb24gcG9sbCgpe3NldFRpbWVvdXQoZnVuY3Rpb24oKXtwb3N0KCdzdGF0dXMnKS50aGVuKGZ1bmN0aW9uKGQpe3Nob3coZCk7aWYoZCYmZC5ydW5uaW5nKXBvbGwoKTtlbHNlIGlmKHN0YXJ0ZWQmJmQmJiFkLmVycilsb2NhdGlvbi5yZWxvYWQoKTt9KS5jYXRjaChmdW5jdGlvbigpe2lmKG1zZyltc2cudGV4dENvbnRlbnQ9J1N0YXR1cyBuaWNodCBsZXNiYXInO2J0bi5kaXNhYmxlZD1mYWxzZTt9KTt9LDIwMDApO30iCiAgICAgICAgICAiaWYoYnRuKXtidG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLGZ1bmN0aW9uKCl7c3RhcnRlZD10cnVlO2J0bi5kaXNhYmxlZD10cnVlO2lmKG1zZyltc2cudGV4dENvbnRlbnQ9J2VyemV1Z3Qg4oCmJztwb3N0KCdzdGFydCcpLnRoZW4oZnVuY3Rpb24oZCl7c2hvdyhkKTtpZihkJiZkLnJ1bm5pbmcpcG9sbCgpO2Vsc2UgaWYoZCYmIWQuZXJyKWxvY2F0aW9uLnJlbG9hZCgpO30pLmNhdGNoKGZ1bmN0aW9uKCl7aWYobXNnKW1zZy50ZXh0Q29udGVudD0nbmljaHQgZ2VzdGFydGV0JztidG4uZGlzYWJsZWQ9ZmFsc2U7fSk7fSk7IgogICAgICAgICAgInBvc3QoJ3N0YXR1cycpLnRoZW4oZnVuY3Rpb24oZCl7c2hvdyhkKTtpZihkJiZkLnJ1bm5pbmcpe3N0YXJ0ZWQ9dHJ1ZTtwb2xsKCk7fX0pLmNhdGNoKGZ1bmN0aW9uKCl7fSk7fSIKICAgICAgICAgICJ9KSgpOzwvc2NyaXB0PiIpCgoKX1BERCA9IHsicHJvYyI6IE5vbmUsICJ0MCI6IDAuMCwgImVyciI6IE5vbmUsICJjb2RlIjogTm9uZSwgInBvcGVuIjogTm9uZX0KX1BERF9MT0NLID0gX19pbXBvcnRfXygidGhyZWFkaW5nIikuTG9jaygpCl9QRERfVElNRU9VVCA9IDMwMAoKCmRlZiBfcGRkX3J1bm5pbmcobm93PU5vbmUpOgogICAgbm93ID0gX3BkX3RpbWUudGltZSgpIGlmIG5vdyBpcyBOb25lIGVsc2Ugbm93CiAgICBwID0gX1BERFsicHJvYyJdCiAgICBpZiBwIGlzIE5vbmU6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBwLnBvbGwoKSBpcyBOb25lOgogICAgICAgIGlmIG5vdyAtIF9QRERbInQwIl0gPiBfUEREX1RJTUVPVVQ6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHAua2lsbCgpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCiAgICAgICAgICAgIF9QRERbInByb2MiXSA9IE5vbmUKICAgICAgICAgICAgX1BERFsiY29kZSJdID0gLTEKICAgICAgICAgICAgX1BERFsiZXJyIl0gPSAiWmVpdHVlYmVyc2NocmVpdHVuZyIKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgcmV0dXJuIFRydWUKICAgIF9QRERbImNvZGUiXSA9IHAucmV0dXJuY29kZQogICAgX1BERFsicHJvYyJdID0gTm9uZQogICAgaWYgcC5yZXR1cm5jb2RlIG5vdCBpbiAoMCwgTm9uZSk6CiAgICAgICAgX1BERFsiZXJyIl0gPSAicHJlcHBlcl9kb2NzLnB5IEVuZGUgJXMiICUgcC5yZXR1cm5jb2RlCiAgICBlbHNlOgogICAgICAgIF9QRERbImVyciJdID0gTm9uZQogICAgcmV0dXJuIEZhbHNlCgoKZGVmIF9wZGRfc3RhdGUoKToKICAgIHdpdGggX1BERF9MT0NLOgogICAgICAgIHJ1bm5pbmcgPSBfcGRkX3J1bm5pbmcoKQogICAgICAgIGVyciwgY29kZSA9IF9QRERbImVyciJdLCBfUEREWyJjb2RlIl0KICAgIHZlciA9IE5vbmUKICAgIHRyeToKICAgICAgICBpdGVtcyA9IF9wZF9saXN0KCkKICAgICAgICB2ZXIgPSBpdGVtc1swXVsidmVyIl0gaWYgaXRlbXMgZWxzZSBOb25lCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKICAgIHJldHVybiB7InJ1bm5pbmciOiBydW5uaW5nLCAidHh0IjogImVyemV1Z3Qg4oCmIiBpZiBydW5uaW5nIGVsc2UgIiIsICJ2ZXIiOiB2ZXIsICJlcnIiOiBlcnIsICJjb2RlIjogY29kZX0KCgpkZWYgX3BkZF9zdGFydCgpOgogICAgd2l0aCBfUEREX0xPQ0s6CiAgICAgICAgaWYgX3BkZF9ydW5uaW5nKCk6CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgYmFzZSA9IF9TRFJfQkFTRQogICAgICAgIHNjcmlwdCA9IF9wZF9vcy5wYXRoLmpvaW4oYmFzZSwgInByZXBwZXJfZG9jcy5weSIpCiAgICAgICAgaWYgX3BkX29zLnBhdGguZGlybmFtZShfcGRfb3MucGF0aC5yZWFscGF0aChzY3JpcHQpKSAhPSBfcGRfb3MucGF0aC5yZWFscGF0aChiYXNlKSBvciBub3QgX3BkX29zLnBhdGguaXNmaWxlKHNjcmlwdCk6CiAgICAgICAgICAgIF9QRERbImVyciJdID0gInByZXBwZXJfZG9jcy5weSBmZWhsdCIKICAgICAgICAgICAgX1BERFsicHJvYyJdID0gTm9uZQogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBhcmd2ID0gW19wZF9zeXMuZXhlY3V0YWJsZSwgInByZXBwZXJfZG9jcy5weSJdCiAgICAgICAgcG9wZW4gPSBfUEREWyJwb3BlbiJdIG9yIF9faW1wb3J0X18oInN1YnByb2Nlc3MiKS5Qb3BlbgogICAgICAgIHRyeToKICAgICAgICAgICAgcHJvYyA9IHBvcGVuKGFyZ3YsIGN3ZD1iYXNlLCBzaGVsbD1GYWxzZSwgc3Rkb3V0PV9faW1wb3J0X18oInN1YnByb2Nlc3MiKS5ERVZOVUxMLCBzdGRlcnI9X19pbXBvcnRfXygic3VicHJvY2VzcyIpLkRFVk5VTEwpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICBfUEREWyJlcnIiXSA9IHR5cGUoZSkuX19uYW1lX18KICAgICAgICAgICAgX1BERFsicHJvYyJdID0gTm9uZQogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBfUERELnVwZGF0ZShwcm9jPXByb2MsIHQwPV9wZF90aW1lLnRpbWUoKSwgZXJyPU5vbmUsIGNvZGU9Tm9uZSkKICAgICAgICByZXR1cm4gVHJ1ZQoKCmRlZiBfcGRkX2FwaSgpOgogICAgZnJvbSBmbGFzayBpbXBvcnQganNvbmlmeSwgcmVxdWVzdAogICAgaWYgcmVxdWVzdC5tZXRob2QgIT0gIlBPU1QiOgogICAgICAgIHJldHVybiBqc29uaWZ5KHsib2siOiBGYWxzZSwgImVycm9yIjogIm51ciBQT1NUIn0pLCA0MDUKICAgIGlmIG5vdCByZXF1aXJlX3NhbWVfb3JpZ2luKHJlcXVlc3QsICJYLVByb2otRG9jIiwgVHJ1ZSk6CiAgICAgICAgcmV0dXJuIGpzb25pZnkoeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAibnVyIGxva2FsIn0pLCA0MDMKICAgIGJvZHkgPSByZXF1ZXN0LmdldF9qc29uKHNpbGVudD1UcnVlKSBvciB7fQogICAgaWYgYm9keS5nZXQoImFjdGlvbiIpID09ICJzdGFydCI6CiAgICAgICAgaWYgYm9keS5nZXQoImNvbmZpcm0iKSBpcyBub3QgVHJ1ZToKICAgICAgICAgICAgcmV0dXJuIGpzb25pZnkoeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAiY29uZmlybSJ9KSwgNDAwCiAgICAgICAgX3BkZF9zdGFydCgpCiAgICByZXR1cm4ganNvbmlmeSh7Im9rIjogVHJ1ZSwgKipfcGRkX3N0YXRlKCl9KQoKCmRlZiBfcGRkX3NlbGZ0ZXN0KCk6CiAgICBjYWxscyA9IFtdCgogICAgY2xhc3MgUHJvYzoKICAgICAgICBkZWYgX19pbml0X18oc2VsZik6CiAgICAgICAgICAgIHNlbGYucmV0dXJuY29kZSA9IE5vbmUKICAgICAgICAgICAgc2VsZi5kb25lID0gRmFsc2UKICAgICAgICAgICAgc2VsZi5raWxsZWQgPSBGYWxzZQoKICAgICAgICBkZWYgcG9sbChzZWxmKToKICAgICAgICAgICAgcmV0dXJuIE5vbmUgaWYgbm90IHNlbGYuZG9uZSBlbHNlIHNlbGYucmV0dXJuY29kZQoKICAgICAgICBkZWYga2lsbChzZWxmKToKICAgICAgICAgICAgc2VsZi5raWxsZWQgPSBUcnVlCiAgICAgICAgICAgIHNlbGYucmV0dXJuY29kZSA9IC05CiAgICAgICAgICAgIHNlbGYuZG9uZSA9IFRydWUKCiAgICBkZWYgcG9wZW4oYXJndiwgY3dkLCBzaGVsbD1GYWxzZSwgc3Rkb3V0PU5vbmUsIHN0ZGVycj1Ob25lKToKICAgICAgICBhc3NlcnQgc2hlbGwgaXMgRmFsc2UgYW5kIGFyZ3ZbLTFdID09ICJwcmVwcGVyX2RvY3MucHkiIGFuZCBjd2QgPT0gX1NEUl9CQVNFCiAgICAgICAgY2FsbHMuYXBwZW5kKGFyZ3YpCiAgICAgICAgcmV0dXJuIFByb2MoKQoKICAgIG9sZCA9IF9QREQuZ2V0KCJwb3BlbiIpCiAgICBfUERELnVwZGF0ZShwcm9jPU5vbmUsIGVycj1Ob25lLCBjb2RlPU5vbmUsIHBvcGVuPXBvcGVuKQogICAgdHJ5OgogICAgICAgIGlmIG5vdCBfcGRfb3MucGF0aC5pc2ZpbGUoX3BkX29zLnBhdGguam9pbihfU0RSX0JBU0UsICJwcmVwcGVyX2RvY3MucHkiKSk6CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgYXNzZXJ0IF9wZGRfc3RhcnQoKSBpcyBUcnVlIGFuZCBsZW4oY2FsbHMpID09IDEgYW5kIF9wZGRfc3RhdGUoKVsicnVubmluZyJdIGlzIFRydWUgYW5kIF9wZGRfc3RhdGUoKVsidHh0Il0gPT0gImVyemV1Z3Qg4oCmIgogICAgICAgIGFzc2VydCBfcGRkX3N0YXJ0KCkgaXMgVHJ1ZSBhbmQgbGVuKGNhbGxzKSA9PSAxCiAgICAgICAgX1BERFsidDAiXSA9IF9wZF90aW1lLnRpbWUoKSAtIF9QRERfVElNRU9VVCAtIDUKICAgICAgICBzdCA9IF9wZGRfc3RhdGUoKQogICAgICAgIGFzc2VydCBzdFsicnVubmluZyJdIGlzIEZhbHNlIGFuZCBzdFsiZXJyIl0gPT0gIlplaXR1ZWJlcnNjaHJlaXR1bmciIGFuZCBfUEREWyJwcm9jIl0gaXMgTm9uZQogICAgICAgIHByb2MgPSBQcm9jKCkKICAgICAgICBkZWYgcG9wZW4yKGFyZ3YsIGN3ZCwgc2hlbGw9RmFsc2UsIHN0ZG91dD1Ob25lLCBzdGRlcnI9Tm9uZSk6CiAgICAgICAgICAgIGNhbGxzLmFwcGVuZChhcmd2KQogICAgICAgICAgICByZXR1cm4gcHJvYwogICAgICAgIF9QRERbInBvcGVuIl0gPSBwb3BlbjIKICAgICAgICBfUEREWyJlcnIiXSA9IE5vbmUKICAgICAgICBhc3NlcnQgX3BkZF9zdGFydCgpIGlzIFRydWUKICAgICAgICBwcm9jLnJldHVybmNvZGUgPSAwCiAgICAgICAgcHJvYy5kb25lID0gVHJ1ZQogICAgICAgIGFzc2VydCBfcGRkX3N0YXRlKClbImVyciJdIGlzIE5vbmUgYW5kIF9wZGRfc3RhdGUoKVsicnVubmluZyJdIGlzIEZhbHNlCiAgICBmaW5hbGx5OgogICAgICAgIF9QREQudXBkYXRlKHByb2M9Tm9uZSwgZXJyPU5vbmUsIGNvZGU9Tm9uZSwgcG9wZW49b2xkLCB0MD0wLjApCiAgICByZXR1cm4gVHJ1ZQo="}, {"old": "ICAgICAgICBhc3NlcnQgJ2Rvd25sb2FkPSJQcm9qZWt0YmVzY2hyZWlidW5nIExhZ2UgUGkgdjIwMjYxMDI0LTE4MzAudHh0IicgaW4gaCBhbmQgImZtdD10eHQmYW1wO3Y9MjAyNjEwMjQtMTgzMCIgaW4gaCBhbmQgIsOEbHRlcmUgVmVyc2lvbmVuICgxKSIgaW4gaCBhbmQgIjxzY3JpcHQiIG5vdCBpbiBoCg==", "new": "ICAgICAgICBhc3NlcnQgJ2Rvd25sb2FkPSJQcm9qZWt0YmVzY2hyZWlidW5nIExhZ2UgUGkgdjIwMjYxMDI0LTE4MzAudHh0IicgaW4gaCBhbmQgImZtdD10eHQmYW1wO3Y9MjAyNjEwMjQtMTgzMCIgaW4gaCBhbmQgIsOEbHRlcmUgVmVyc2lvbmVuICgxKSIgaW4gaCBhbmQgIjxzY3JpcHQiIG5vdCBpbiBoCiAgICAgICAgYXNzZXJ0ICdpZD0icGRCdWlsZCInIGluIGggYW5kICJKZXR6dCBlcnpldWdlbiIgaW4gaCBhbmQgIk5ldWUgVmVyc2lvbjoiIG5vdCBpbiBoCg=="}, {"old": "ICAgICAgICBhc3NlcnQgImZldGNoKCIgbm90IGluIF9QRF9KUyBhbmQgIlhNTEh0dHBSZXF1ZXN0IiBub3QgaW4gX1BEX0pTIGFuZCAiaW5uZXJIVE1MIiBub3QgaW4gX1BEX0pTIGFuZCAiLmNsaWNrKCkiIG5vdCBpbiBfUERfSlMgYW5kICJsb2NhbFN0b3JhZ2UiIG5vdCBpbiBfUERfSlMK", "new": "ICAgICAgICBhc3NlcnQgX1BEX0pTLmNvdW50KCJmZXRjaCgiKSA9PSAxIGFuZCAiL2FwaS9kb2NzL2J1aWxkIiBpbiBfUERfSlMgYW5kICJYLVByb2otRG9jIiBpbiBfUERfSlMKICAgICAgICBhc3NlcnQgIlhNTEh0dHBSZXF1ZXN0IiBub3QgaW4gX1BEX0pTIGFuZCAiaW5uZXJIVE1MIiBub3QgaW4gX1BEX0pTIGFuZCAiLmNsaWNrKCkiIG5vdCBpbiBfUERfSlMgYW5kICJsb2NhbFN0b3JhZ2UiIG5vdCBpbiBfUERfSlMKICAgICAgICBhc3NlcnQgX3BkZF9zZWxmdGVzdCgpCg=="}, {"old": "ICAgIHJldHVybiAicHJvakRvYyBzZWxmdGVzdCBvayAoVmVyc2lvbnNsaXN0ZSwgUGZhZC1UcmF2ZXJzYWwgYWJnZXdpZXNlbiwgQ29udGVudC1EaXNwb3NpdGlvbiBtaXQgZmlsZW5hbWUqLCBLYWNoZWwgJ3BkLWNhcmQnIGhpbnRlciBkZXIgU2ljaGVydW5nIChKUyB2ZXJzZXR6dCBudXIgZGllIGVpZ2VuZSBLYWNoZWwpLCBudXIgbGVzZW4pIgo=", "new": "ICAgIHJldHVybiAicHJvakRvYyBzZWxmdGVzdCBvayAoVmVyc2lvbnNsaXN0ZSwgUGZhZC1UcmF2ZXJzYWwgYWJnZXdpZXNlbiwgQ29udGVudC1EaXNwb3NpdGlvbiBtaXQgZmlsZW5hbWUqLCBLYWNoZWwgbWl0IEpldHp0IGVyemV1Z2VuLCBQT1NUIG51ciBsb2thbCwga2VpbiBTaGVsbCkiCg=="}, {"old": "ICAgICAgICAgICAgYXBwLmFkZF91cmxfcnVsZShfcGRfciwgZW5kcG9pbnQ9X3BkX2VwLCB2aWV3X2Z1bmM9X3BkX2ZuLCBtZXRob2RzPVsiR0VUIl0pCg==", "new": "ICAgICAgICAgICAgYXBwLmFkZF91cmxfcnVsZShfcGRfciwgZW5kcG9pbnQ9X3BkX2VwLCB2aWV3X2Z1bmM9X3BkX2ZuLCBtZXRob2RzPVsiR0VUIl0pCiAgICBpZiAicGRkb2NfYnVpbGQiIG5vdCBpbiBhcHAudmlld19mdW5jdGlvbnM6CiAgICAgICAgYXBwLmFkZF91cmxfcnVsZSgiL2FwaS9kb2NzL2J1aWxkIiwgZW5kcG9pbnQ9InBkZG9jX2J1aWxkIiwgdmlld19mdW5jPV9wZGRfYXBpLCBtZXRob2RzPVsiUE9TVCJdKQo="}]

if __name__ == "__main__":
    sys.exit(main(sys.argv))
