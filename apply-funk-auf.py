#!/usr/bin/env python3
# Funk-Anzeige. Drei Stellen in dashboard.py. prepper-sdr bleibt.
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
    tmp = path.with_name("." + path.name + ".tmp-funk")
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
    alt = sorted(path.parent.glob(path.name + ".bak-funk-*"))
    bak = path.with_name(path.name + ".bak-funk-" + stempel)
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
    if all(dash.count(new) == 1 and dash.count(old) == 0 for old, new in pairs):
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    neu = dash
    for old, new in pairs:
        if neu.count(old) != 1 or b'id="fu-fix"' in dash and old.startswith(b"# ===== /ntfyPush"):
            print("STOP: dashboard.py Stelle unbekannt")
            return 2
        if neu.count(old) != 1 or neu.count(new) != 0:
            print("STOP: dashboard.py Stelle unbekannt")
            return 2
        vor = neu
        neu = neu.replace(old, new, 1)
        if neu.replace(new, b"", 1) != vor.replace(old, b"", 1):
            print("STOP: dashboard.py wuerde ausserhalb der Stelle geaendert")
            return 2
    if b'id="fu-fix"' not in neu or b"fuGainFold" not in neu:
        print("STOP: neue Anzeige unvollstaendig")
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
    print("geschrieben. Nur drei Stellen in dashboard.py. prepper-sdr bleibt.")
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
        assert old not in new and b"Gewitter" in pairs[2][1]
        blob += old + b"\n"
    blob += b"NACH\n"
    neu = blob
    for old, new in pairs:
        neu = neu.replace(old, new, 1)
    assert b"# FREMD" in neu and b'id="fu-fix"' in neu and b"dataset.k==='meteor'" in neu
    assert basis_ok("ups_manager.py", b"x") is False
    assert fenster(datetime(2026, 11, 12, 12, 10))[0]
    assert not fenster(datetime(2026, 11, 12, 9, 59))[0]
    assert not fenster(datetime(2026, 11, 12, 0, 4))[0]
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

PAYLOAD = [{"old": "dmFyIGF0PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhdENhcmQnKTtpZihhdCYmYXQucGFyZW50Tm9kZSYmYXQucHJldmlvdXNTaWJsaW5nIT09Yyl7YXQucGFyZW50Tm9kZS5pbnNlcnRCZWZvcmUoYyxhdCk7fQo=", "new": "dmFyIGF0PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhdENhcmQnKTtpZihhdCYmYXQucGFyZW50Tm9kZSYmIWMuY29udGFpbnMoYXQpJiZhdC5wcmV2aW91c1NpYmxpbmchPT1jKXthdC5wYXJlbnROb2RlLmluc2VydEJlZm9yZShjLGF0KTt9Cg=="}, {"old": "Yy5hcHBlbmRDaGlsZChlbCgnZGl2JywnYWctbicsJ1dlY2hzZWwgbnVyIGJlaSBrbGFyZW0gVm9ydGVpbCBcdTAwZmNiZXIgbWVocmVyZSBNZXNzdW5nZW4gdW5kIG5pZSBiZWkgQWxhcm0sIEFTQS1XYXJudW5nLCBQVFkgMzEsIEFudGVubmVudGVzdCBvZGVyIE1ldGVvci1BdWZuYWhtZSAoZWluIFdlY2hzZWwgc3RhcnRldCB3ZWxsZS1jbGkgbmV1KS4gTWVociBhbHMgMiBXZWNoc2VsIGluIDQ4IGggb2RlciBzY2hsZWNodGVyZXIgRW1wZmFuZyBuYWNoIGVpbmVtIFdlY2hzZWwgc3BlcnJlbiBkZW4gYmVzdGVuIGZlc3RlbiBXZXJ0LCBiaXMgRHUgaGllciB3aWVkZXIgQXV0byBlaW5zY2hhbHRlc3QuIEJlaSBGZWhsZXJuIGdpbHQgU3R1ZmUgMTYuIEF1dG8gKHdlbGxlLUFHQykgd2lyZCBudXIgZ2VtZXNzZW4sIG5pZSBhdXRvbWF0aXNjaCBnZXdcdTAwZTRobHQuJykpO30K", "new": "Yy5hcHBlbmRDaGlsZChlbCgnZGl2JywnYWctbicsJ1dlY2hzZWwgbnVyIGJlaSBrbGFyZW0gVm9ydGVpbCBcdTAwZmNiZXIgbWVocmVyZSBNZXNzdW5nZW4gdW5kIG5pZSBiZWkgQWxhcm0sIEFTQS1XYXJudW5nLCBQVFkgMzEsIEFudGVubmVudGVzdCBvZGVyIE1ldGVvci1BdWZuYWhtZSAoZWluIFdlY2hzZWwgc3RhcnRldCB3ZWxsZS1jbGkgbmV1KS4gTWVociBhbHMgMiBXZWNoc2VsIGluIDQ4IGggb2RlciBzY2hsZWNodGVyZXIgRW1wZmFuZyBuYWNoIGVpbmVtIFdlY2hzZWwgc3BlcnJlbiBkZW4gYmVzdGVuIGZlc3RlbiBXZXJ0LCBiaXMgRHUgaGllciB3aWVkZXIgQXV0byBlaW5zY2hhbHRlc3QuIEJlaSBGZWhsZXJuIGdpbHQgU3R1ZmUgMTYuIEF1dG8gKHdlbGxlLUFHQykgd2lyZCBudXIgZ2VtZXNzZW4sIG5pZSBhdXRvbWF0aXNjaCBnZXdcdTAwZTRobHQuJykpO2lmKHdpbmRvdy5mdUdhaW5Gb2xkKXdpbmRvdy5mdUdhaW5Gb2xkKCk7fQo="}, {"old": "IyA9PT09PSAvbnRmeVB1c2ggPT09PT0KCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgo=", "new": "IyA9PT09PSAvbnRmeVB1c2ggPT09PT0KCiMgPT09PT0gZnVua0F1ZjogL2Z1bmsgbnVyIEFuemVpZ2UuIEdld2l0dGVyLVplaWxlIHVuZCBHZXdpdHRlciBpbSBGdW5rdW1mZWxkIHdlZywgTWV0ZW9yLVNjaGFsdGVyIHdlZywgU3RpY2sgMyB6ZWlndCBQaW5uZWJlcmcsIGRvcHBlbHRlIEFpcnNweS9TdGljay0xLUJhbGtlbiB3ZWcsIEdhaW4gaW4gZWluZXIgS2FydGUsIEFudGVubmVudGVzdCB3ZWcuID09PT09CmltcG9ydCBqc29uIGFzIF9mdV9qc29uCmltcG9ydCBvcyBhcyBfZnVfb3MKCgpkZWYgX2Z1X3Bpbl90eHQoKToKICAgIHRyeToKICAgICAgICBpbXBvcnQgcGlubmViZXJnX3J4IGFzIF9yeAogICAgICAgIHBhdGggPSBfZnVfb3MucGF0aC5qb2luKF9TRFJfQkFTRSwgX3J4LkRCX05BTUUpCiAgICAgICAgaWYgbm90IF9mdV9vcy5wYXRoLmlzZmlsZShwYXRoKToKICAgICAgICAgICAgcmV0dXJuICJrZWluIEVtcGZhbmciCiAgICAgICAgYm94ID0gX3J4LnJlY2VudChwYXRoKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4gImtlaW4gRW1wZmFuZyIKICAgIGlmIG5vdCBib3guZ2V0KCJlbXBmYW5nIik6CiAgICAgICAgcmV0dXJuICJrZWluIEVtcGZhbmciCiAgICByZXR1cm4gIiAiLmpvaW4oc3RyKGJveC5nZXQoInR4dCIpIG9yICIiKS5zcGxpdCgpKVs6MTYwXSBvciAia2VpbiBFbXBmYW5nIgoKCl9GVV9GSVggPSByIiIiPHNjcmlwdCBpZD0iZnUtZml4Ij4oZnVuY3Rpb24oKXsKdmFyIFBOPSdQaW5uZWJlcmc6ICcrKChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnUtcGluJyl8fHt9KS50ZXh0Q29udGVudHx8J2tlaW4gRW1wZmFuZycpOwp0cnl7UE49J1Bpbm5lYmVyZzogJysoSlNPTi5wYXJzZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnUtcGluJykudGV4dENvbnRlbnQpLnR4dHx8J2tlaW4gRW1wZmFuZycpO31jYXRjaChlKXt9CmZ1bmN0aW9uIHBpblNlZyh0KXt0PVN0cmluZyh0fHwnJyk7dD10LnJlcGxhY2UoL1xzKsK3XHMqR2V3aXR0ZXIgbmFoL2csJycpLnJlcGxhY2UoL0dld2l0dGVyIG5haFxzKsK3XHMqL2csJycpOwp0PXQucmVwbGFjZSgvXHMqwrdccypTdGljayAzXHMqwrdccypIb2JieTpbXHNcU10qJC8sJyDCtyAnK1BOKTtyZXR1cm4gdC5zcGxpdCgnUVJNL01ldGVvcicpLmpvaW4oJ1FSTScpO30KZnVuY3Rpb24gZm9sZCgpe3ZhciBhZz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWdDYXJkJyksYXQ9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2F0Q2FyZCcpO2lmKCFhZ3x8IWF0KXJldHVybjsKdmFyIGQ9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Z1QXRGb2xkJyk7aWYoIWQpe2Q9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGV0YWlscycpO2QuaWQ9J2Z1QXRGb2xkJzt2YXIgcz1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdW1tYXJ5Jyk7cy50ZXh0Q29udGVudD0nR2Fpbi1UZXN0IChUYWJlbGxlKSc7ZC5hcHBlbmRDaGlsZChzKTthZy5hcHBlbmRDaGlsZChkKTt9CmlmKGF0LnBhcmVudE5vZGUhPT1kKXthdC5jbGFzc0xpc3QucmVtb3ZlKCdjYXJkJyk7ZC5hcHBlbmRDaGlsZChhdCk7fX0Kd2luZG93LmZ1R2FpbkZvbGQ9Zm9sZDsKZnVuY3Rpb24gcGFzcygpe3ZhciB1aT1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2RyVWlDYXJkJyk7CmlmKHVpKXt2YXIgcm93cz11aS5xdWVyeVNlbGVjdG9yQWxsKCcuc3Utcm93Jyk7Zm9yKHZhciBpPTA7aTxyb3dzLmxlbmd0aDtpKyspe3ZhciBrPXJvd3NbaV0ucXVlcnlTZWxlY3RvcignLnN1LWsnKTtpZihrJiYvR2V3aXR0ZXIvLnRlc3Qoay50ZXh0Q29udGVudHx8JycpKXJvd3NbaV0ucmVtb3ZlKCk7fQp2YXIgY2hpcHM9dWkucXVlcnlTZWxlY3RvckFsbCgnLnN1LWNoaXAnKTtmb3IodmFyIGo9MDtqPGNoaXBzLmxlbmd0aDtqKyspe2lmKGNoaXBzW2pdLmRhdGFzZXQuaz09PSdtZXRlb3InKWNoaXBzW2pdLnJlbW92ZSgpO30KdmFyIGxicz1bXS5zbGljZS5jYWxsKHVpLnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZC1sYicpKTtsYnMuZm9yRWFjaChmdW5jdGlvbihsYil7dmFyIHR4PWxiLnRleHRDb250ZW50fHwnJztpZighL0FpcnNweXxmZXN0IDExRHxTdGljayAxfGZlc3QgNUMvLnRlc3QodHgpKXJldHVybjt2YXIgbj1sYi5uZXh0RWxlbWVudFNpYmxpbmc7bGIucmVtb3ZlKCk7d2hpbGUobiYmKG4uY2xhc3NMaXN0LmNvbnRhaW5zKCdzbC1iYXInKXx8bi5jbGFzc0xpc3QuY29udGFpbnMoJ3NsLWJsJykpKXt2YXIgbng9bi5uZXh0RWxlbWVudFNpYmxpbmc7bi5yZW1vdmUoKTtuPW54O319KTsKdmFyIGtyPXVpLnF1ZXJ5U2VsZWN0b3IoJy5zbC1rcmlzZScpO2lmKGtyJiZrci5maXJzdENoaWxkJiZrci5maXJzdENoaWxkLm5vZGVUeXBlPT09Mylrci5maXJzdENoaWxkLm5vZGVWYWx1ZT1waW5TZWcoa3IuZmlyc3RDaGlsZC5ub2RlVmFsdWUpOwp2YXIgc209a3ImJmtyLnF1ZXJ5U2VsZWN0b3IoJ3NtYWxsJyk7aWYoc20mJi9TdGljayAzLy50ZXN0KHNtLnRleHRDb250ZW50fHwnJykmJi9Ib2JieXxSRFN8Z2Vwci8udGVzdChzbS50ZXh0Q29udGVudHx8JycpKXNtLnRleHRDb250ZW50PVBOOwp2YXIgczI9dWkucXVlcnlTZWxlY3RvcignLnNsLXMyJyk7aWYoczIpczIudGV4dENvbnRlbnQ9cGluU2VnKHMyLnRleHRDb250ZW50KS5yZXBsYWNlKC9ccyrCt1xzKlN0aWNrIDNccyrCt1xzKltBLVphLXowLTldK1xzK0tvcnJla3R1clxzKlsrLV0/XGQrXHMqcHBtLywnIMK3ICcrUE4pO30KdmFyIGJveD1kb2N1bWVudC5xdWVyeVNlbGVjdG9yKCcjZnVMYWdlIC5mdS1rdicpO2lmKGJveCl7dmFyIGtzPWJveC5xdWVyeVNlbGVjdG9yQWxsKCcuaycpO2Zvcih2YXIgYT0wO2E8a3MubGVuZ3RoO2ErKyl7dmFyIGtleT1rc1thXSx2YWw9a2V5Lm5leHRFbGVtZW50U2libGluZyxrdD1rZXkudGV4dENvbnRlbnR8fCcnLHZ0PXZhbD92YWwudGV4dENvbnRlbnR8fCcnOicnOwppZigvXkxhc3RccytTdGljayAzLy50ZXN0KGt0KXx8KC9eU3RpY2sgMy8udGVzdChrdCkmJi9Ib2JieXxQaW5uZWJlcmctRW1wZmFuZ3xSRFN8Z2Vwci8udGVzdChrdCsnICcrdnQpKSl7a2V5LnRleHRDb250ZW50PSdQaW5uZWJlcmcnO2lmKHZhbCl2YWwudGV4dENvbnRlbnQ9UE47fX19CnZhciB3ZD1kb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcjd2RCb3ggLndkLXIgc3BhbjpsYXN0LWNoaWxkJyk7Zm9yKHZhciBiPTA7Yjx3ZC5sZW5ndGg7YisrKXt2YXIgdz13ZFtiXS50ZXh0Q29udGVudHx8Jyc7aWYoL1N0aWNrIDMvLnRlc3QodykmJi9SRFN8SG9iYnl8dm9uIFN0aWNrLy50ZXN0KHcpKXdkW2JdLnRleHRDb250ZW50PVBOO30KdmFyIHN0PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdGlja1Rlc3RDYXJkJyk7aWYoc3Qpc3QucmVtb3ZlKCk7Zm9sZCgpO30Kc2V0VGltZW91dChwYXNzLDQwMCk7c2V0SW50ZXJ2YWwocGFzcyw3MDApOwp9KSgpOzwvc2NyaXB0PiIiIgoKCmRlZiBfZnVfYWZ0ZXIocmVzcCk6CiAgICB0cnk6CiAgICAgICAgZnJvbSBmbGFzayBpbXBvcnQgcmVxdWVzdCBhcyBfcnEKICAgICAgICBpZiBfcnEucGF0aCAhPSAiL2Z1bmsiIG9yIHJlc3Auc3RhdHVzX2NvZGUgIT0gMjAwIG9yIHJlc3AuZGlyZWN0X3Bhc3N0aHJvdWdoOgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIGlmIChyZXNwLm1pbWV0eXBlIG9yICIiKSAhPSAidGV4dC9odG1sIiBvciAnaWQ9ImZ1LWZpeCInIGluIHJlc3AuZ2V0X2RhdGEoYXNfdGV4dD1UcnVlKToKICAgICAgICAgICAgcmV0dXJuIHJlc3AKICAgICAgICBib2R5ID0gcmVzcC5nZXRfZGF0YShhc190ZXh0PVRydWUpCiAgICAgICAgYmxvYiA9ICc8c2NyaXB0IHR5cGU9ImFwcGxpY2F0aW9uL2pzb24iIGlkPSJmdS1waW4iPiVzPC9zY3JpcHQ+JyAlIF9mdV9qc29uLmR1bXBzKHsidHh0IjogX2Z1X3Bpbl90eHQoKX0pLnJlcGxhY2UoIjwiLCAiXFx1MDAzYyIpCiAgICAgICAgaiA9IGJvZHkucmZpbmQoIjwvYm9keT4iKQogICAgICAgIHJlc3Auc2V0X2RhdGEoKGJvZHlbOmpdICsgYmxvYiArIF9GVV9GSVggKyBib2R5W2o6XSkgaWYgaiA+PSAwIGVsc2UgKGJvZHkgKyBibG9iICsgX0ZVX0ZJWCkpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgcHJpbnQoImZ1bmtBdWY6IiwgdHlwZShlKS5fX25hbWVfXywgZmx1c2g9VHJ1ZSkKICAgIHJldHVybiByZXNwCgoKdHJ5OgogICAgYXNzZXJ0IF9mdV9waW5fdHh0KCkKICAgIGFzc2VydCAiR2V3aXR0ZXIiIGluIF9GVV9GSVggYW5kICJkYXRhc2V0Lms9PT0nbWV0ZW9yJyIgaW4gX0ZVX0ZJWCBhbmQgIlFSTS9NZXRlb3IiIGluIF9GVV9GSVgKICAgIGFzc2VydCAic3RpY2tUZXN0Q2FyZCIgaW4gX0ZVX0ZJWCBhbmQgImZ1R2FpbkZvbGQiIGluIF9GVV9GSVggYW5kICJzZC1sYiIgaW4gX0ZVX0ZJWCBhbmQgIndkQm94IiBpbiBfRlVfRklYCiAgICBhc3NlcnQgImlubmVySFRNTCIgbm90IGluIF9GVV9GSVggYW5kICIvYXBpL21lc2giIG5vdCBpbiBfRlVfRklYCiAgICBpZiAiYXBwIiBpbiBnbG9iYWxzKCkgYW5kIG5vdCBhbnkoZ2V0YXR0cihmLCAiX19uYW1lX18iLCAiIikgPT0gIl9mdV9hZnRlciIgZm9yIGYgaW4gYXBwLmFmdGVyX3JlcXVlc3RfZnVuY3MuZ2V0KE5vbmUsIFtdKSk6CiAgICAgICAgYXBwLmFmdGVyX3JlcXVlc3RfZnVuY3Muc2V0ZGVmYXVsdChOb25lLCBbXSkuaW5zZXJ0KDAsIF9mdV9hZnRlcikKICAgIHByaW50KCJmdW5rQXVmIGFrdGl2IiwgZmx1c2g9VHJ1ZSkKZXhjZXB0IEV4Y2VwdGlvbiBhcyBfZnVfZToKICAgIHByaW50KCJmdW5rQXVmIEZFSExFUjogJXMiICUgdHlwZShfZnVfZSkuX19uYW1lX18sIGZsdXNoPVRydWUpCiMgPT09PT0gL2Z1bmtBdWYgPT09PT0KCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgo="}]

if __name__ == "__main__":
    sys.exit(main(sys.argv))
