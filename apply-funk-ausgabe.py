#!/usr/bin/env python3
# funkAuf: die fertige /funk-Antwort filtern. Nur dieser Block in dashboard.py.
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
    raw = PAYLOAD if isinstance(PAYLOAD, dict) else json.loads(PAYLOAD)
    return base64.b64decode(raw["old"]), base64.b64decode(raw["new"])

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
    tmp = path.with_name("." + path.name + ".tmp-funk2")
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
    alt = sorted(path.parent.glob(path.name + ".bak-funk2-*"))
    bak = path.with_name(path.name + ".bak-funk2-" + stempel)
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
    old, new = load()
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
    if dash.count(new) == 1 and dash.count(old) == 0:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    if dash.count(old) != 1 or dash.count(new) != 0:
        print("STOP: dashboard.py funkAuf-Block unbekannt")
        return 2
    neu = dash.replace(old, new, 1)
    if neu.replace(new, b"", 1) != dash.replace(old, b"", 1):
        print("STOP: dashboard.py wuerde ausserhalb des Blocks geaendert")
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
    print("geschrieben. Nur der funkAuf-Block in dashboard.py.")
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
    old, new = load()
    blob = b"VOR\n# FREMD\n" + old + b"\nNACH\n"
    neu = blob.replace(old, new, 1)
    assert b"# FREMD" in neu and b"def _fua_after" in neu and old not in neu
    assert basis_ok("ups_manager.py", b"x") is False
    assert fenster(datetime(2026, 11, 12, 12, 10))[0]
    assert not fenster(datetime(2026, 11, 12, 9, 50))[0]
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

PAYLOAD = {"old": "IyA9PT09PSBmdW5rQXVmOiAvZnVuayBudXIgQW56ZWlnZS4gR2V3aXR0ZXItWmVpbGUgdW5kIEdld2l0dGVyIGltIEZ1bmt1bWZlbGQgd2VnLCBNZXRlb3ItU2NoYWx0ZXIgd2VnLCBTdGljayAzIHplaWd0IFBpbm5lYmVyZywgZG9wcGVsdGUgQWlyc3B5L1N0aWNrLTEtQmFsa2VuIHdlZywgR2FpbiBpbiBlaW5lciBLYXJ0ZSwgQW50ZW5uZW50ZXN0IHdlZy4gPT09PT0KaW1wb3J0IGpzb24gYXMgX2Z1X2pzb24KaW1wb3J0IG9zIGFzIF9mdV9vcwoKCmRlZiBfZnVfcGluX3R4dCgpOgogICAgdHJ5OgogICAgICAgIGltcG9ydCBwaW5uZWJlcmdfcnggYXMgX3J4CiAgICAgICAgcGF0aCA9IF9mdV9vcy5wYXRoLmpvaW4oX1NEUl9CQVNFLCBfcnguREJfTkFNRSkKICAgICAgICBpZiBub3QgX2Z1X29zLnBhdGguaXNmaWxlKHBhdGgpOgogICAgICAgICAgICByZXR1cm4gImtlaW4gRW1wZmFuZyIKICAgICAgICBib3ggPSBfcngucmVjZW50KHBhdGgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHJldHVybiAia2VpbiBFbXBmYW5nIgogICAgaWYgbm90IGJveC5nZXQoImVtcGZhbmciKToKICAgICAgICByZXR1cm4gImtlaW4gRW1wZmFuZyIKICAgIHJldHVybiAiICIuam9pbihzdHIoYm94LmdldCgidHh0Iikgb3IgIiIpLnNwbGl0KCkpWzoxNjBdIG9yICJrZWluIEVtcGZhbmciCgoKX0ZVX0ZJWCA9IHIiIiI8c2NyaXB0IGlkPSJmdS1maXgiPihmdW5jdGlvbigpewp2YXIgUE49J1Bpbm5lYmVyZzogJysoKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmdS1waW4nKXx8e30pLnRleHRDb250ZW50fHwna2VpbiBFbXBmYW5nJyk7CnRyeXtQTj0nUGlubmViZXJnOiAnKyhKU09OLnBhcnNlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmdS1waW4nKS50ZXh0Q29udGVudCkudHh0fHwna2VpbiBFbXBmYW5nJyk7fWNhdGNoKGUpe30KZnVuY3Rpb24gcGluU2VnKHQpe3Q9U3RyaW5nKHR8fCcnKTt0PXQucmVwbGFjZSgvXHMqwrdccypHZXdpdHRlciBuYWgvZywnJykucmVwbGFjZSgvR2V3aXR0ZXIgbmFoXHMqwrdccyovZywnJyk7CnQ9dC5yZXBsYWNlKC9ccyrCt1xzKlN0aWNrIDNccyrCt1xzKkhvYmJ5Oltcc1xTXSokLywnIMK3ICcrUE4pO3JldHVybiB0LnNwbGl0KCdRUk0vTWV0ZW9yJykuam9pbignUVJNJyk7fQpmdW5jdGlvbiBmb2xkKCl7dmFyIGFnPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhZ0NhcmQnKSxhdD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXRDYXJkJyk7aWYoIWFnfHwhYXQpcmV0dXJuOwp2YXIgZD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnVBdEZvbGQnKTtpZighZCl7ZD1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkZXRhaWxzJyk7ZC5pZD0nZnVBdEZvbGQnO3ZhciBzPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3N1bW1hcnknKTtzLnRleHRDb250ZW50PSdHYWluLVRlc3QgKFRhYmVsbGUpJztkLmFwcGVuZENoaWxkKHMpO2FnLmFwcGVuZENoaWxkKGQpO30KaWYoYXQucGFyZW50Tm9kZSE9PWQpe2F0LmNsYXNzTGlzdC5yZW1vdmUoJ2NhcmQnKTtkLmFwcGVuZENoaWxkKGF0KTt9fQp3aW5kb3cuZnVHYWluRm9sZD1mb2xkOwpmdW5jdGlvbiBwYXNzKCl7dmFyIHVpPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZHJVaUNhcmQnKTsKaWYodWkpe3ZhciByb3dzPXVpLnF1ZXJ5U2VsZWN0b3JBbGwoJy5zdS1yb3cnKTtmb3IodmFyIGk9MDtpPHJvd3MubGVuZ3RoO2krKyl7dmFyIGs9cm93c1tpXS5xdWVyeVNlbGVjdG9yKCcuc3UtaycpO2lmKGsmJi9HZXdpdHRlci8udGVzdChrLnRleHRDb250ZW50fHwnJykpcm93c1tpXS5yZW1vdmUoKTt9CnZhciBjaGlwcz11aS5xdWVyeVNlbGVjdG9yQWxsKCcuc3UtY2hpcCcpO2Zvcih2YXIgaj0wO2o8Y2hpcHMubGVuZ3RoO2orKyl7aWYoY2hpcHNbal0uZGF0YXNldC5rPT09J21ldGVvcicpY2hpcHNbal0ucmVtb3ZlKCk7fQp2YXIgbGJzPVtdLnNsaWNlLmNhbGwodWkucXVlcnlTZWxlY3RvckFsbCgnLnNkLWxiJykpO2xicy5mb3JFYWNoKGZ1bmN0aW9uKGxiKXt2YXIgdHg9bGIudGV4dENvbnRlbnR8fCcnO2lmKCEvQWlyc3B5fGZlc3QgMTFEfFN0aWNrIDF8ZmVzdCA1Qy8udGVzdCh0eCkpcmV0dXJuO3ZhciBuPWxiLm5leHRFbGVtZW50U2libGluZztsYi5yZW1vdmUoKTt3aGlsZShuJiYobi5jbGFzc0xpc3QuY29udGFpbnMoJ3NsLWJhcicpfHxuLmNsYXNzTGlzdC5jb250YWlucygnc2wtYmwnKSkpe3ZhciBueD1uLm5leHRFbGVtZW50U2libGluZztuLnJlbW92ZSgpO249bng7fX0pOwp2YXIga3I9dWkucXVlcnlTZWxlY3RvcignLnNsLWtyaXNlJyk7aWYoa3ImJmtyLmZpcnN0Q2hpbGQmJmtyLmZpcnN0Q2hpbGQubm9kZVR5cGU9PT0zKWtyLmZpcnN0Q2hpbGQubm9kZVZhbHVlPXBpblNlZyhrci5maXJzdENoaWxkLm5vZGVWYWx1ZSk7CnZhciBzbT1rciYma3IucXVlcnlTZWxlY3Rvcignc21hbGwnKTtpZihzbSYmL1N0aWNrIDMvLnRlc3Qoc20udGV4dENvbnRlbnR8fCcnKSYmL0hvYmJ5fFJEU3xnZXByLy50ZXN0KHNtLnRleHRDb250ZW50fHwnJykpc20udGV4dENvbnRlbnQ9UE47CnZhciBzMj11aS5xdWVyeVNlbGVjdG9yKCcuc2wtczInKTtpZihzMilzMi50ZXh0Q29udGVudD1waW5TZWcoczIudGV4dENvbnRlbnQpLnJlcGxhY2UoL1xzKsK3XHMqU3RpY2sgM1xzKsK3XHMqW0EtWmEtejAtOV0rXHMrS29ycmVrdHVyXHMqWystXT9cZCtccypwcG0vLCcgwrcgJytQTik7fQp2YXIgYm94PWRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyNmdUxhZ2UgLmZ1LWt2Jyk7aWYoYm94KXt2YXIga3M9Ym94LnF1ZXJ5U2VsZWN0b3JBbGwoJy5rJyk7Zm9yKHZhciBhPTA7YTxrcy5sZW5ndGg7YSsrKXt2YXIga2V5PWtzW2FdLHZhbD1rZXkubmV4dEVsZW1lbnRTaWJsaW5nLGt0PWtleS50ZXh0Q29udGVudHx8JycsdnQ9dmFsP3ZhbC50ZXh0Q29udGVudHx8Jyc6Jyc7CmlmKC9eTGFzdFxzK1N0aWNrIDMvLnRlc3Qoa3QpfHwoL15TdGljayAzLy50ZXN0KGt0KSYmL0hvYmJ5fFBpbm5lYmVyZy1FbXBmYW5nfFJEU3xnZXByLy50ZXN0KGt0KycgJyt2dCkpKXtrZXkudGV4dENvbnRlbnQ9J1Bpbm5lYmVyZyc7aWYodmFsKXZhbC50ZXh0Q29udGVudD1QTjt9fX0KdmFyIHdkPWRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN3ZEJveCAud2QtciBzcGFuOmxhc3QtY2hpbGQnKTtmb3IodmFyIGI9MDtiPHdkLmxlbmd0aDtiKyspe3ZhciB3PXdkW2JdLnRleHRDb250ZW50fHwnJztpZigvU3RpY2sgMy8udGVzdCh3KSYmL1JEU3xIb2JieXx2b24gU3RpY2svLnRlc3Qodykpd2RbYl0udGV4dENvbnRlbnQ9UE47fQp2YXIgc3Q9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0aWNrVGVzdENhcmQnKTtpZihzdClzdC5yZW1vdmUoKTtmb2xkKCk7fQpzZXRUaW1lb3V0KHBhc3MsNDAwKTtzZXRJbnRlcnZhbChwYXNzLDcwMCk7Cn0pKCk7PC9zY3JpcHQ+IiIiCgoKZGVmIF9mdV9hZnRlcihyZXNwKToKICAgIHRyeToKICAgICAgICBmcm9tIGZsYXNrIGltcG9ydCByZXF1ZXN0IGFzIF9ycQogICAgICAgIGlmIF9ycS5wYXRoICE9ICIvZnVuayIgb3IgcmVzcC5zdGF0dXNfY29kZSAhPSAyMDAgb3IgcmVzcC5kaXJlY3RfcGFzc3Rocm91Z2g6CiAgICAgICAgICAgIHJldHVybiByZXNwCiAgICAgICAgaWYgKHJlc3AubWltZXR5cGUgb3IgIiIpICE9ICJ0ZXh0L2h0bWwiIG9yICdpZD0iZnUtZml4IicgaW4gcmVzcC5nZXRfZGF0YShhc190ZXh0PVRydWUpOgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIGJvZHkgPSByZXNwLmdldF9kYXRhKGFzX3RleHQ9VHJ1ZSkKICAgICAgICBibG9iID0gJzxzY3JpcHQgdHlwZT0iYXBwbGljYXRpb24vanNvbiIgaWQ9ImZ1LXBpbiI+JXM8L3NjcmlwdD4nICUgX2Z1X2pzb24uZHVtcHMoeyJ0eHQiOiBfZnVfcGluX3R4dCgpfSkucmVwbGFjZSgiPCIsICJcXHUwMDNjIikKICAgICAgICBqID0gYm9keS5yZmluZCgiPC9ib2R5PiIpCiAgICAgICAgcmVzcC5zZXRfZGF0YSgoYm9keVs6al0gKyBibG9iICsgX0ZVX0ZJWCArIGJvZHlbajpdKSBpZiBqID49IDAgZWxzZSAoYm9keSArIGJsb2IgKyBfRlVfRklYKSkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBwcmludCgiZnVua0F1ZjoiLCB0eXBlKGUpLl9fbmFtZV9fLCBmbHVzaD1UcnVlKQogICAgcmV0dXJuIHJlc3AKCgp0cnk6CiAgICBhc3NlcnQgX2Z1X3Bpbl90eHQoKQogICAgYXNzZXJ0ICJHZXdpdHRlciIgaW4gX0ZVX0ZJWCBhbmQgImRhdGFzZXQuaz09PSdtZXRlb3InIiBpbiBfRlVfRklYIGFuZCAiUVJNL01ldGVvciIgaW4gX0ZVX0ZJWAogICAgYXNzZXJ0ICJzdGlja1Rlc3RDYXJkIiBpbiBfRlVfRklYIGFuZCAiZnVHYWluRm9sZCIgaW4gX0ZVX0ZJWCBhbmQgInNkLWxiIiBpbiBfRlVfRklYIGFuZCAid2RCb3giIGluIF9GVV9GSVgKICAgIGFzc2VydCAiaW5uZXJIVE1MIiBub3QgaW4gX0ZVX0ZJWCBhbmQgIi9hcGkvbWVzaCIgbm90IGluIF9GVV9GSVgKICAgIGlmICJhcHAiIGluIGdsb2JhbHMoKSBhbmQgbm90IGFueShnZXRhdHRyKGYsICJfX25hbWVfXyIsICIiKSA9PSAiX2Z1X2FmdGVyIiBmb3IgZiBpbiBhcHAuYWZ0ZXJfcmVxdWVzdF9mdW5jcy5nZXQoTm9uZSwgW10pKToKICAgICAgICBhcHAuYWZ0ZXJfcmVxdWVzdF9mdW5jcy5zZXRkZWZhdWx0KE5vbmUsIFtdKS5pbnNlcnQoMCwgX2Z1X2FmdGVyKQogICAgcHJpbnQoImZ1bmtBdWYgYWt0aXYiLCBmbHVzaD1UcnVlKQpleGNlcHQgRXhjZXB0aW9uIGFzIF9mdV9lOgogICAgcHJpbnQoImZ1bmtBdWYgRkVITEVSOiAlcyIgJSB0eXBlKF9mdV9lKS5fX25hbWVfXywgZmx1c2g9VHJ1ZSkKIyA9PT09PSAvZnVua0F1ZiA9PT09PQo=", "new": "IyA9PT09PSBmdW5rQXVmOiBsZXR6dGUgU3RlbGxlIGZ1ZXIgL2Z1bmsuIERpZSBTZWl0ZSBpc3QgZGFubiBzY2hvbiBmZXJ0aWcuID09PT09CmltcG9ydCBvcyBhcyBfZnVhX29zCmltcG9ydCByZSBhcyBfZnVhX3JlCgpfRlVBX0pTID0gKAogICAgIjxzY3JpcHQgaWQ9XCJmdWEtanNcIj4oZnVuY3Rpb24oKXtmdW5jdGlvbiBmb2xkKCl7dmFyIGFnPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhZ0NhcmQnKSxhdD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXRDYXJkJyk7IgogICAgImlmKCFhZ3x8IWF0KXJldHVybjt2YXIgZD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZnVBdEZvbGQnKTtpZighZCl7ZD1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkZXRhaWxzJyk7ZC5pZD0nZnVBdEZvbGQnOyIKICAgICJ2YXIgcz1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdW1tYXJ5Jyk7cy50ZXh0Q29udGVudD0nR2Fpbi1UZXN0IChUYWJlbGxlKSc7ZC5hcHBlbmRDaGlsZChzKTthZy5hcHBlbmRDaGlsZChkKTt9IgogICAgImlmKGF0LnBhcmVudE5vZGUhPT1kKXthdC5jbGFzc0xpc3QucmVtb3ZlKCdjYXJkJyk7ZC5hcHBlbmRDaGlsZChhdCk7fX13aW5kb3cuZnVHYWluRm9sZD1mb2xkOyIKICAgICJmdW5jdGlvbiBwYXNzKCl7dmFyIHN0PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdGlja1Rlc3RDYXJkJyk7aWYoc3Qpc3QucmVtb3ZlKCk7Zm9sZCgpO30iCiAgICAic2V0VGltZW91dChwYXNzLDMwMCk7c2V0SW50ZXJ2YWwocGFzcywxMDAwKTt9KSgpOzwvc2NyaXB0PiIKKQoKCmRlZiBfZnVhX3BpbigpOgogICAgdHJ5OgogICAgICAgIGltcG9ydCBwaW5uZWJlcmdfcnggYXMgX3J4CiAgICAgICAgcGF0aCA9IF9mdWFfb3MucGF0aC5qb2luKF9TRFJfQkFTRSwgX3J4LkRCX05BTUUpCiAgICAgICAgaWYgbm90IF9mdWFfb3MucGF0aC5pc2ZpbGUocGF0aCk6CiAgICAgICAgICAgIHJldHVybiAia2VpbiBFbXBmYW5nIgogICAgICAgIGJveCA9IF9yeC5yZWNlbnQocGF0aCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuICJrZWluIEVtcGZhbmciCiAgICBpZiBub3QgYm94LmdldCgiZW1wZmFuZyIpOgogICAgICAgIHJldHVybiAia2VpbiBFbXBmYW5nIgogICAgcmV0dXJuICIgIi5qb2luKHN0cihib3guZ2V0KCJ0eHQiKSBvciAiIikuc3BsaXQoKSlbOjE2MF0gb3IgImtlaW4gRW1wZmFuZyIKCgpkZWYgX2Z1YV9waHJhc2UodGV4dCwgcGluKToKICAgIHRleHQgPSB0ZXh0LnJlcGxhY2UoIlFSTS9NZXRlb3IiLCAiUVJNIikKICAgIHRleHQgPSBfZnVhX3JlLnN1YihyIlN0aWNrIDMgwrcgSG9iYnk6W15cIlxcPF17MCwzMDB9IiwgcGluLCB0ZXh0KQogICAgdGV4dCA9IHRleHQucmVwbGFjZSgiU3RpY2sgMyDCtyBIb2JieSIsICJQaW5uZWJlcmciKQogICAgdGV4dCA9IHRleHQucmVwbGFjZSgiIMK3IEdld2l0dGVyIG5haCIsICIiKS5yZXBsYWNlKCJHZXdpdHRlciBuYWggwrcgIiwgIiIpCiAgICByZXR1cm4gdGV4dAoKCmRlZiBfZnVhX2h0bWwoYm9keSwgcGluKToKICAgIGJvZHkgPSBfZnVhX3JlLnN1YihyInZhciB0bD1uelwuc3RhbGVcP1woJ25pY2h0IG1lc3NiYXIuKj8n4pqhIEdld2l0dGVyOicsdGwsdGhcLndoeVx8XHwnJ1wpOyIsICIiLCBib2R5LCBjb3VudD0xLCBmbGFncz1fZnVhX3JlLlMpCiAgICBib2R5ID0gX2Z1YV9yZS5zdWIociJ2YXIgdD1OXC50aHVuZGVyXHxcfFx7XH0sdGw9dFwubHZsXHxcfCdncmF1JztsblwoYywn4pqhIEdld2l0dGVyLUhpbndlaXM6Lio/XCk7IiwgIiIsIGJvZHksIGNvdW50PTEsIGZsYWdzPV9mdWFfcmUuUykKICAgIGJvZHkgPSBib2R5LnJlcGxhY2UoCiAgICAgICAgIihELmZ1bmNzfHxbXSkuZm9yRWFjaChmdW5jdGlvbihmKXt2YXIgeD1lbCgnZGl2Jywnc3UtY2hpcCcpOyIsCiAgICAgICAgIihELmZ1bmNzfHxbXSkuZm9yRWFjaChmdW5jdGlvbihmKXtpZihmLms9PT0nbWV0ZW9yJylyZXR1cm47dmFyIHg9ZWwoJ2RpdicsJ3N1LWNoaXAnKTsiLAogICAgICAgIDEpCiAgICBib2R5ID0gX2Z1YV9yZS5zdWIoCiAgICAgICAgciJ2YXIgbDE9ZWxcKCdkaXYnLCdzZC1sYiAnLio/Y1wuaW5zZXJ0QmVmb3JlXChiYlxbMVxdLHJlZlwpO1x9IiwKICAgICAgICAiaWYoYjEpe3ZhciBsZ0E9YjEubmV4dEVsZW1lbnRTaWJsaW5nO2IxLnJlbW92ZSgpO2lmKGxnQSYmbGdBLmNsYXNzTGlzdCYmbGdBLmNsYXNzTGlzdC5jb250YWlucygnc2wtYmwnKSlsZ0EucmVtb3ZlKCk7fSIsCiAgICAgICAgYm9keSwgY291bnQ9MSwgZmxhZ3M9X2Z1YV9yZS5TKQogICAgYm9keSA9IGJvZHkucmVwbGFjZSgKICAgICAgICAiKyhVLnBwbTMhPT11bmRlZmluZWQmJlUucHBtMyE9PW51bGw/JyDCtyAnKyhVLmxibDN8fCdTdGljayAzJykrJyBLb3JyZWt0dXIgJysoVS5wcG0zPjA/JysnOicnKStVLnBwbTMrJyBwcG0nOicnKSIsCiAgICAgICAgIiIpCiAgICBvbGRfczQgPSAoInZhciBzND1zZC5zNHx8e307aWYoczQubmFtZSl7a3YoYm94LHM0Lm5hbWUsKHM0LmFic2VudD8nbmljaHQgYW5nZXNjaGxvc3NlbiDigJMga2VpbmUgQWt0aW9uJzooczQubW9kZXx8czQuc3RhdGV8fCfigJMnKSkrKHM0LnNuPycgwrcgU04gJytzNC5zbjonJyksczQuYWJzZW50PycjOTRhM2I4JzonI2NiZDVlMScpOyIKICAgICAgICAgICAgICAidmFyIGM0PXM0LmNwdXx8e30sZzQ9czQuZ2F0ZXx8bnVsbDtpZighczQuYWJzZW50JiYoYzQucGN0IT1udWxsfHxnNCkpa3YoYm94LCdMYXN0ICcrKHM0LmRldl9uYW1lfHwnU3RpY2sgMycpLChjNC5wY3QhPW51bGw/J0NQVSAnK24oYzQucGN0LDApKycgJSBlaW5lcyBLZXJucyAoNSBtaW4gXFx1MDBkOCAnK24oYzQuYXZnLDApKycgJSknOicnKSsoZzQ/KGM0LnBjdCE9bnVsbD8nIMK3ICc6JycpK2c0LndoYXQrJyB2ZXJzY2hvYmVuOiAnK2c0LndoeTonJyksJyM5NGEzYjgnKTt9IikKICAgIGJvZHkgPSBib2R5LnJlcGxhY2Uob2xkX3M0LCAidmFyIHM0PXNkLnM0fHx7fTtpZihzNC5uYW1lKXtrdihib3gsJ1Bpbm5lYmVyZycsJyVzJywnI2NiZDVlMScpO30iICUgcGluLCAxKQogICAgYm9keSA9IF9mdWFfcGhyYXNlKGJvZHksIHBpbikKICAgIGlmICdpZD0iZnVhLWpzIicgbm90IGluIGJvZHk6CiAgICAgICAgaiA9IGJvZHkucmZpbmQoIjwvYm9keT4iKQogICAgICAgIGJvZHkgPSAoYm9keVs6al0gKyBfRlVBX0pTICsgYm9keVtqOl0pIGlmIGogPj0gMCBlbHNlIChib2R5ICsgX0ZVQV9KUykKICAgIHJldHVybiBib2R5CgoKZGVmIF9mdWFfYWZ0ZXIocmVzcCk6CiAgICB0cnk6CiAgICAgICAgZnJvbSBmbGFzayBpbXBvcnQgcmVxdWVzdCBhcyBfcnEKICAgICAgICBwYXRoID0gX3JxLnBhdGggb3IgIiIKICAgICAgICBpZiByZXNwLnN0YXR1c19jb2RlICE9IDIwMCBvciByZXNwLmRpcmVjdF9wYXNzdGhyb3VnaCBvciByZXNwLmhlYWRlcnMuZ2V0KCJDb250ZW50LUVuY29kaW5nIik6CiAgICAgICAgICAgIHJldHVybiByZXNwCiAgICAgICAga2luZCA9IHJlc3AubWltZXR5cGUgb3IgIiIKICAgICAgICBpZiBwYXRoID09ICIvZnVuayIgYW5kIGtpbmQgPT0gInRleHQvaHRtbCI6CiAgICAgICAgICAgIHJlc3Auc2V0X2RhdGEoX2Z1YV9odG1sKHJlc3AuZ2V0X2RhdGEoYXNfdGV4dD1UcnVlKSwgIlBpbm5lYmVyZzogIiArIF9mdWFfcGluKCkpKQogICAgICAgIGVsaWYgcGF0aCBpbiAoIi9hcGkvc2RyL3VpIiwgIi9hcGkvc2RyL3dkIiwgIi9hcGkvdDIvc3RhdHVzIiwgIi9hcGkvdDQvc3RhdHVzIikgYW5kICJqc29uIiBpbiBraW5kOgogICAgICAgICAgICByYXcgPSByZXNwLmdldF9kYXRhKGFzX3RleHQ9VHJ1ZSkKICAgICAgICAgICAgaWYgIlN0aWNrIDMgwrcgSG9iYnkiIGluIHJhdyBvciAiUVJNL01ldGVvciIgaW4gcmF3IG9yICJHZXdpdHRlciBuYWgiIGluIHJhdzoKICAgICAgICAgICAgICAgIHJlc3Auc2V0X2RhdGEoX2Z1YV9waHJhc2UocmF3LCAiUGlubmViZXJnOiAiICsgX2Z1YV9waW4oKSkpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgcHJpbnQoImZ1bmtBdWY6IiwgdHlwZShlKS5fX25hbWVfXywgZmx1c2g9VHJ1ZSkKICAgIHJldHVybiByZXNwCgoKdHJ5OgogICAgYXNzZXJ0ICJHZXdpdHRlciIgbm90IGluIF9GVUFfSlMgYW5kICJTdGljayAzIMK3IEhvYmJ5IiBub3QgaW4gX0ZVQV9KUwogICAgcHJvYmUgPSAidm9yIFN0aWNrIDMgwrcgSG9iYnk6IFJEUyBvayDCtyBudXIgQmVvYmFjaHR1bmcgUVJNL01ldGVvciIKICAgIGFzc2VydCBfZnVhX3BocmFzZShwcm9iZSwgIlBpbm5lYmVyZzoga2VpbiBFbXBmYW5nIikgPT0gInZvciBQaW5uZWJlcmc6IGtlaW4gRW1wZmFuZyIKICAgIGlmICJhcHAiIGluIGdsb2JhbHMoKSBhbmQgbm90IGFueShnZXRhdHRyKGYsICJfX25hbWVfXyIsICIiKSA9PSAiX2Z1YV9hZnRlciIgZm9yIGYgaW4gYXBwLmFmdGVyX3JlcXVlc3RfZnVuY3MuZ2V0KE5vbmUsIFtdKSk6CiAgICAgICAgYXBwLmFmdGVyX3JlcXVlc3RfZnVuY3Muc2V0ZGVmYXVsdChOb25lLCBbXSkuaW5zZXJ0KDAsIF9mdWFfYWZ0ZXIpCiAgICBwcmludCgiZnVua0F1ZiBha3RpdiIsIGZsdXNoPVRydWUpCmV4Y2VwdCBFeGNlcHRpb24gYXMgX2Z1YV9lOgogICAgcHJpbnQoImZ1bmtBdWYgRkVITEVSOiAlcyIgJSB0eXBlKF9mdWFfZSkuX19uYW1lX18sIGZsdXNoPVRydWUpCiMgPT09PT0gL2Z1bmtBdWYgPT09PT0K"}

if __name__ == "__main__":
    sys.exit(main(sys.argv))
