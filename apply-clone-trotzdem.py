#!/usr/bin/env python3
# cloneForce: Knopf "Trotzdem klonen" nur bei echtem Alarm, nur nach confirm().
# Schreibt nur dashboard.py. Kein pip, kein apt, kein Klon-Lauf.
# Basis dashboard.py sha16 473b8c25469c5392 (Stand nach Piper). lage_pages.py wird nicht geaendert.
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
DASH16 = "473b8c25469c5392"

def load():
    raw = PAYLOAD if isinstance(PAYLOAD, list) else json.loads(PAYLOAD)
    return [(base64.b64decode(x["old"]), base64.b64decode(x["new"])) for x in raw]

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def dash_ok(data: bytes) -> bool:
    return sha(data).startswith(DASH16)

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
    tmp = path.with_name("." + path.name + ".tmp-clone")
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
    alt = sorted(path.parent.glob(path.name + ".bak-clone-*"))
    bak = path.with_name(path.name + ".bak-clone-" + stempel)
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
    if not dash_ok(dash) or b"stimmePiper" not in dash:
        print("STOP: dashboard.py ist nicht der Stand nach Piper, sha16 %s, erwartet %s" % (sha(dash)[:16], DASH16))
        return 2
    if b"cloneForce" in dash and all(dash.count(neu) == 1 for _, neu in pairs):
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
    if b"cloneForce" not in neu or b"dt2CloneForce" not in neu or b"override_alarm" not in neu:
        print("STOP: cloneForce unvollstaendig")
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
    print("geschrieben. Nur cloneForce in dashboard.py. Andere Sperren bleiben.")
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
    blob = b"# FREMD-CLONE\n"
    for old, new in pairs:
        blob += old
    neu = blob
    for old, new in pairs:
        assert neu.count(old) == 1
        neu = neu.replace(old, new, 1)
    assert b"# FREMD-CLONE" in neu and neu.count(b"cloneForce") == 1 and b"dt2CloneForce" in neu
    assert fenster(datetime(2026, 11, 12, 12, 10))[0] and fenster(datetime(2026, 11, 12, 12, 5))[0]
    assert not fenster(datetime(2026, 11, 12, 12, 45))[0]
    assert not fenster(datetime(2026, 11, 12, 12, 59))[0]
    assert not fenster(datetime(2026, 11, 12, 12, 0))[0]
    assert not fenster(datetime(2026, 11, 12, 12, 4))[0]
    assert dash_ok(b"x" * 80) is False
    assert basis_ok("lage_pages.py", b"LAGE") is False
    import tempfile
    ordner = Path(tempfile.mkdtemp(prefix="clone-apply-"))
    namen = ["ntfy_push.py"] + list(FIXED) + list(PREFIX) + ["dashboard.py"]
    for name in namen:
        (ordner / name).write_bytes(b"UNBERUEHRT-" + name.encode())
    vorher = {name: (ordner / name).read_bytes() for name in namen}
    rc = apply_dir(ordner, False, True)
    assert rc == 2
    assert {name: (ordner / name).read_bytes() for name in namen} == vorher
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

PAYLOAD = [{"old": "ZGVmIF9kdF9jbG9uZV9ibG9jayhjcz1Ob25lKToKICAgICIiIlNwZXJyZ3J1ZW5kZSBmdWVyIGRlbiBLbm9wZiAoU2NyaXB0IHBydWVmdCBzZWxic3Qgbm9jaCBlaW5tYWwgYWxzIHJvb3QpLiIiIgogICAg", "new": "ZGVmIF9kdF9jbG9uZV9ibG9jayhjcz1Ob25lLCBvdmVycmlkZV9hbGFybT1GYWxzZSk6CiAgICAiIiJTcGVycmdydWVuZGUgZnVlciBkZW4gS25vcGYuIG92ZXJyaWRlX2FsYXJtIHVlYmVyZ2VodCBudXIgZGVuIGVjaHRlbiBBbGFybS4iIiIKICAgIA=="}, {"old": "ICAgICAgICBpZiBpc2luc3RhbmNlKGcsIGRpY3QpIGFuZCBnLmdldCgiYWxhcm0iKSBpcyBUcnVlIGFuZCBfZHRfdGltZS50aW1lKCkgLSBmbG9hdChnLmdldCgidCIpIG9yIDApIDw9IDkwMDoK", "new": "ICAgICAgICBpZiAobm90IG92ZXJyaWRlX2FsYXJtKSBhbmQgaXNpbnN0YW5jZShnLCBkaWN0KSBhbmQgZy5nZXQoImFsYXJtIikgaXMgVHJ1ZSBhbmQgX2R0X3RpbWUudGltZSgpIC0gZmxvYXQoZy5nZXQoInQiKSBvciAwKSA8PSA5MDA6Cg=="}, {"old": "ICAgICAgICAgICAgYm9keSA9IHt9CiAgICAgICAgY3MgPSBfZHRfY2xvbmVfc3RhdHVzKCkKICAgICAgICBpZiBjc1siYmxvY2siXToK", "new": "ICAgICAgICAgICAgYm9keSA9IHt9CiAgICAgICAgY3MgPSBfZHRfY2xvbmVfc3RhdHVzKCkKICAgICAgICAjID09PT09IGNsb25lRm9yY2U6IG51ciBkaWUgQWxhcm0tU3BlcnJlLCB1bmQgbnVyIHdlbm4gZGVyIEF1ZnJ1ZiBkYXMgRmxhZyBzZXR6dC4gPT09PT0KICAgICAgICBvdmVycmlkZSA9IGlzaW5zdGFuY2UoYm9keSwgZGljdCkgYW5kIGJvZHkuZ2V0KCJvdmVycmlkZV9hbGFybSIsIGJvZHkuZ2V0KCJmb3JjZSIpKSBpbiAoMSwgIjEiLCBUcnVlKQogICAgICAgIHRyb3R6ID0gRmFsc2UKICAgICAgICBpZiBvdmVycmlkZToKICAgICAgICAgICAgdm9yaGVyID0gbGlzdChjcy5nZXQoImJsb2NrIikgb3IgW10pCiAgICAgICAgICAgIGNzWyJibG9jayJdID0gX2R0X2Nsb25lX2Jsb2NrKGNzLCBvdmVycmlkZV9hbGFybT1UcnVlKQogICAgICAgICAgICB0cm90eiA9IGFueShiID09ICJlY2h0ZXIgQWxhcm0gaW0gTGFnZXplbnRydW0iIGZvciBiIGluIHZvcmhlcikgYW5kIG5vdCBhbnkoYiA9PSAiZWNodGVyIEFsYXJtIGltIExhZ2V6ZW50cnVtIiBmb3IgYiBpbiBjc1siYmxvY2siXSkKICAgICAgICAgICAgaWYgdHJvdHo6CiAgICAgICAgICAgICAgICBwcmludCgiZGlza1RpbGVzMjogS2xvbi1PdmVycmlkZSBBbGFybSBhbmdlZm9yZGVydCIsIGZsdXNoPVRydWUpCiAgICAgICAgaWYgY3NbImJsb2NrIl06Cg=="}, {"old": "ICAgICAgICBwcmludCgiZGlza1RpbGVzMjogS2xvbi1TdGFydCAlczogJXMiICUgKCJvayIgaWYgb2sgZWxzZSAiRkVITEVSIiwgdHh0KSwgZmx1c2g9VHJ1ZSkK", "new": "ICAgICAgICBwcmludCgiZGlza1RpbGVzMjogS2xvbi1TdGFydCAlcyVzOiAlcyIgJSAoIm9rIiBpZiBvayBlbHNlICJGRUhMRVIiLCAiIHRyb3R6IEFsYXJtIiBpZiB0cm90eiBlbHNlICIiLCB0eHQpLCBmbHVzaD1UcnVlKQo="}, {"old": "JXM8ZGl2IGNsYXNzPSJkdDItYnRucyI+PGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJkdDJDbG9uZSIlcz5KZXR6dCB2b24gU1NEIGF1ZiBTRCBrbG9uZW48L2J1dHRvbj48c3BhbiBpZD0iY2xvbmVNc2ciIGNsYXNzPSJkdDItbXNnIj48L3NwYW4+PC9kaXY+JwogICAgICAgICAgICAgICAn", "new": "JXM8ZGl2IGNsYXNzPSJkdDItYnRucyI+PGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJkdDJDbG9uZSIlcz5KZXR6dCB2b24gU1NEIGF1ZiBTRCBrbG9uZW48L2J1dHRvbj4lczxzcGFuIGlkPSJjbG9uZU1zZyIgY2xhc3M9ImR0Mi1tc2ciPjwvc3Bhbj48L2Rpdj4nCiAgICAgICAgICAgICAgICc="}, {"old": "ICAgICAgICAgICAgICAgICAgIiBkaXNhYmxlZCIgaWYgYmwgZWxzZSAiIiwgbGVuKGhpc3QpLCBocm93cyBvciAnPGRpdiBjbGFzcz0icHAtZm9vdCI+4oCTPC9kaXY+JywK", "new": "ICAgICAgICAgICAgICAgICAgIiBkaXNhYmxlZCIgaWYgYmwgZWxzZSAiIiwKICAgICAgICAgICAgICAgICAgJzxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iZHQyQ2xvbmVGb3JjZSI+VHJvdHpkZW0ga2xvbmVuPC9idXR0b24+JyBpZiBhbnkoYiA9PSAiZWNodGVyIEFsYXJtIGltIExhZ2V6ZW50cnVtIiBmb3IgYiBpbiBibCkgZWxzZSAiIiwKICAgICAgICAgICAgICAgICAgbGVuKGhpc3QpLCBocm93cyBvciAnPGRpdiBjbGFzcz0icHAtZm9vdCI+4oCTPC9kaXY+JywK"}, {"old": "I3NkRmFsbGJhY2sgI2R0MkNsb25lW2Rpc2FibGVkXXtiYWNrZ3JvdW5kOiMzMzQxNTU7Y29sb3I6Izk0YTNiOH0KLmR0Mi1tc2d7Zm9udC1zaXplOjEycHg=", "new": "I3NkRmFsbGJhY2sgI2R0MkNsb25lW2Rpc2FibGVkXXtiYWNrZ3JvdW5kOiMzMzQxNTU7Y29sb3I6Izk0YTNiOH0KI3NkRmFsbGJhY2sgI2R0MkNsb25lRm9yY2V7YmFja2dyb3VuZDojN2YxZDFkfQouZHQyLW1zZ3tmb250LXNpemU6MTJweA=="}, {"old": "ZnVuY3Rpb24gc3RhcnQodG9rKXt2YXIgbz17bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkodG9rP3t0b2tlbjp0b2t9Ont9KX07Cg==", "new": "ZnVuY3Rpb24gc3RhcnQodG9rLGZvcmNlKXt2YXIgYm9keT10b2s/e3Rva2VuOnRva306e307aWYoZm9yY2UpYm9keS5vdmVycmlkZV9hbGFybT0xO3ZhciBvPXttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX07Cg=="}, {"old": "fSkuY2F0Y2goZnVuY3Rpb24oKXtjLmRpc2FibGVkPWZhbHNlO21zZygnRmVobGVyIGJlaW0gU3RhcnQnKTt9KTt9KTt9CnZhciBhPSQoJ2R0MkFjaycpOwo=", "new": "fSkuY2F0Y2goZnVuY3Rpb24oKXtjLmRpc2FibGVkPWZhbHNlO21zZygnRmVobGVyIGJlaW0gU3RhcnQnKTt9KTt9KTt9CnZhciBmPSQoJ2R0MkNsb25lRm9yY2UnKTsKaWYoZil7Zi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsZnVuY3Rpb24oKXsKaWYoIWNvbmZpcm0oJ1Ryb3R6ZGVtIGtsb25lbj8gRGVyIEtsb24gZGF1ZXJ0IGV0d2EgMzMgbWluIHVuZCBlcnpldWd0IGhvaGUgSS9PLUxhc3Qgd8OkaHJlbmQgZWluZXMgZWNodGVuIEFsYXJtcy4nKSlyZXR1cm47CmYuZGlzYWJsZWQ9dHJ1ZTttc2coJ3Byw7xmZSDigKYnKTsKc3RhcnQobnVsbCx0cnVlKS50aGVuKGZ1bmN0aW9uKGopewppZihqLm5lZWRfY29uZmlybSYmai50b2tlbil7aWYoIWNvbmZpcm0oai50ZXh0fHwnV2lya2xpY2ggc3RhcnRlbj8nKSl7Zi5kaXNhYmxlZD1mYWxzZTttc2coJ2FiZ2Vicm9jaGVuJyk7cmV0dXJuO30KbXNnKCdzdGFydGUg4oCmJyk7cmV0dXJuIHN0YXJ0KGoudG9rZW4sdHJ1ZSkudGhlbihmdW5jdGlvbihrKXtpZihrLm9rKXttc2coJ2dlc3RhcnRldCcpO3NldFRpbWVvdXQocG9sbCwxNTAwKTt9ZWxzZXtmLmRpc2FibGVkPWZhbHNlO21zZygoay53aHl8fFsnbmljaHQgZ2VzdGFydGV0J10pLmpvaW4oJzsgJykpO319KTt9CmYuZGlzYWJsZWQ9ZmFsc2U7bXNnKChqLndoeXx8WyduaWNodCBtw7ZnbGljaCddKS5qb2luKCc7ICcpKTsKfSkuY2F0Y2goZnVuY3Rpb24oKXtmLmRpc2FibGVkPWZhbHNlO21zZygnRmVobGVyIGJlaW0gU3RhcnQnKTt9KTt9KTt9CnZhciBhPSQoJ2R0MkFjaycpOwo="}, {"old": "ICAgICAgICBhc3NlcnQgIm1ldGhvZDonUE9TVCciIGluIF9EVF9KUyBhbmQgInRva2VuIiBpbiBfRFRfSlMgYW5kIF9EVF9KUy5jb3VudCgiY29uZmlybSgiKSA9PSAyCg==", "new": "ICAgICAgICBhc3NlcnQgIm1ldGhvZDonUE9TVCciIGluIF9EVF9KUyBhbmQgInRva2VuIiBpbiBfRFRfSlMgYW5kICJvdmVycmlkZV9hbGFybSIgaW4gX0RUX0pTIGFuZCBfRFRfSlMuY291bnQoImNvbmZpcm0oIikgPT0gNAogICAgICAgIHJlYWxfbG9hZCA9IGdbIl9kdF9sb2FkIl0KICAgICAgICByZWFsX3RrID0gZ1siX2R0X3Rha2VvdmVyIl0KICAgICAgICBnYXRlID0geyJhbGFybSI6IFRydWUsICJ0IjogX2R0X3RpbWUudGltZSgpfQogICAgICAgIGRlZiBsb2FkX2dhdGUocGF0aCwgZGZsdCk6CiAgICAgICAgICAgIGlmIHN0cihwYXRoKS5lbmRzd2l0aCgic2RyX3dkX2dhdGUuanNvbiIpOgogICAgICAgICAgICAgICAgcmV0dXJuIGdhdGUKICAgICAgICAgICAgcmV0dXJuIHJlYWxfbG9hZChwYXRoLCBkZmx0KQogICAgICAgIGdbIl9kdF9sb2FkIl0gPSBsb2FkX2dhdGUKICAgICAgICBnWyJfZHRfdGFrZW92ZXIiXSA9IGxhbWJkYSBwYXRoOiAoImF1cyIsICIiKQogICAgICAgIF9EVFsiZGlzayJdID0gZGljdChfRFRbImRpc2siXSwga2luZD0iU1NEIiwgc3JjPSIvZGV2L3NkYTIiKQogICAgICAgIHdpdGggb3Blbih0ZiwgInciKSBhcyBmOgogICAgICAgICAgICBmLndyaXRlKCd7Im9uIjogZmFsc2V9JykKICAgICAgICB0cnk6CiAgICAgICAgICAgIGFzc2VydCBfZHRfY2xvbmVfYmxvY2soKSA9PSBbImVjaHRlciBBbGFybSBpbSBMYWdlemVudHJ1bSJdCiAgICAgICAgICAgIGFzc2VydCBfZHRfY2xvbmVfYmxvY2sob3ZlcnJpZGVfYWxhcm09VHJ1ZSkgPT0gW10KICAgICAgICAgICAgcnVuID0geyJzdGF0ZSI6ICJydW5uaW5nIn0KICAgICAgICAgICAgYXNzZXJ0ICJLbG9uIGzDpHVmdCBnZXJhZGUiIGluIF9kdF9jbG9uZV9ibG9jayhydW4sIG92ZXJyaWRlX2FsYXJtPVRydWUpIGFuZCAiQWxhcm0iIG5vdCBpbiAiICIuam9pbihfZHRfY2xvbmVfYmxvY2socnVuLCBvdmVycmlkZV9hbGFybT1UcnVlKSkKICAgICAgICAgICAgc2F2ZWRfc3lzID0gX0RUWyJmYWtlIl1bInN5cyJdCiAgICAgICAgICAgIF9EVFsiZmFrZSJdWyJzeXMiXSA9IF9kdF9vcy5wYXRoLmpvaW4odG1wLCAibm9zZCIpCiAgICAgICAgICAgIGJsb2NrZWQgPSBfZHRfY2xvbmVfYmxvY2sob3ZlcnJpZGVfYWxhcm09VHJ1ZSkKICAgICAgICAgICAgYXNzZXJ0IGFueSgiU0QtS2FydGUgZmVobHQiIGluIGIgZm9yIGIgaW4gYmxvY2tlZCkgYW5kIG5vdCBhbnkoYiA9PSAiZWNodGVyIEFsYXJtIGltIExhZ2V6ZW50cnVtIiBmb3IgYiBpbiBibG9ja2VkKSwgYmxvY2tlZAogICAgICAgICAgICBfRFRbImZha2UiXVsic3lzIl0gPSBzYXZlZF9zeXMKICAgICAgICAgICAgYWxhcm1faHRtbCA9IF9kdF9jYXJkcygpCiAgICAgICAgICAgIGFzc2VydCAnaWQ9ImR0MkNsb25lRm9yY2UiJyBpbiBhbGFybV9odG1sIGFuZCAiVHJvdHpkZW0ga2xvbmVuIiBpbiBhbGFybV9odG1sIGFuZCAnaWQ9ImR0MkNsb25lIiBkaXNhYmxlZCcgaW4gYWxhcm1faHRtbAogICAgICAgICAgICBnYXRlWyJhbGFybSJdID0gRmFsc2UKICAgICAgICAgICAgcXVpZXQgPSBfZHRfY2FyZHMoKQogICAgICAgICAgICBhc3NlcnQgJ2lkPSJkdDJDbG9uZUZvcmNlIicgbm90IGluIHF1aWV0IGFuZCAnaWQ9ImR0MkNsb25lIiBkaXNhYmxlZCcgbm90IGluIHF1aWV0LCBxdWlldFtxdWlldC5maW5kKCJkdDJDbG9uZSIpLTMwOnF1aWV0LmZpbmQoImR0MkNsb25lIikrMTIwXQogICAgICAgICAgICBnYXRlWyJhbGFybSJdID0gVHJ1ZQogICAgICAgICAgICBzdGFydGVkID0gW10KICAgICAgICAgICAgY2xhc3MgX0Zha2VDbG9uZToKICAgICAgICAgICAgICAgIGRlZiBfX2luaXRfXyhzZWxmLCAqYSwgKiprKToKICAgICAgICAgICAgICAgICAgICBzdGFydGVkLmFwcGVuZChsaXN0KGFbMF0pIGlmIGEgZWxzZSBbXSkKICAgICAgICAgICAgICAgICAgICBzZWxmLnJldHVybmNvZGUgPSAwCiAgICAgICAgICAgICAgICBkZWYgY29tbXVuaWNhdGUoc2VsZiwgdGltZW91dD1Ob25lKToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gKCJnZXN0YXJ0ZXQiLCBOb25lKQogICAgICAgICAgICBvbGRfcG9wZW4gPSBfZHRfc3ViLlBvcGVuCiAgICAgICAgICAgIF9kdF9zdWIuUG9wZW4gPSBfRmFrZUNsb25lCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHdpdGggYXBwLnRlc3RfcmVxdWVzdF9jb250ZXh0KCIvYXBpL2Nsb25lL3N0YXJ0IiwgbWV0aG9kPSJQT1NUIiwgZGF0YT0ie30iLCBjb250ZW50X3R5cGU9ImFwcGxpY2F0aW9uL2pzb24iKToKICAgICAgICAgICAgICAgICAgICBibG9ja2VkX3IgPSBfZHRfYXBpX2Nsb25lKCkuZ2V0X2pzb24oKQogICAgICAgICAgICAgICAgYXNzZXJ0IGJsb2NrZWRfclsib2siXSBpcyBGYWxzZSBhbmQgYW55KCJBbGFybSIgaW4gdyBmb3IgdyBpbiBibG9ja2VkX3JbIndoeSJdKSBhbmQgbm90IHN0YXJ0ZWQKICAgICAgICAgICAgICAgIHdpdGggYXBwLnRlc3RfcmVxdWVzdF9jb250ZXh0KCIvYXBpL2Nsb25lL3N0YXJ0IiwgbWV0aG9kPSJQT1NUIiwgZGF0YT0neyJvdmVycmlkZV9hbGFybSI6MX0nLCBjb250ZW50X3R5cGU9ImFwcGxpY2F0aW9uL2pzb24iKToKICAgICAgICAgICAgICAgICAgICBhc2sgPSBfZHRfYXBpX2Nsb25lKCkuZ2V0X2pzb24oKQogICAgICAgICAgICAgICAgYXNzZXJ0IGFzay5nZXQoIm5lZWRfY29uZmlybSIpIGFuZCBhc2suZ2V0KCJ0b2tlbiIpIGFuZCBub3Qgc3RhcnRlZAogICAgICAgICAgICAgICAgd2l0aCBhcHAudGVzdF9yZXF1ZXN0X2NvbnRleHQoIi9hcGkvY2xvbmUvc3RhcnQiLCBtZXRob2Q9IlBPU1QiLCBkYXRhPV9kdF9qc29uLmR1bXBzKHsib3ZlcnJpZGVfYWxhcm0iOiAxLCAidG9rZW4iOiBhc2tbInRva2VuIl19KSwgY29udGVudF90eXBlPSJhcHBsaWNhdGlvbi9qc29uIik6CiAgICAgICAgICAgICAgICAgICAgZ28gPSBfZHRfYXBpX2Nsb25lKCkuZ2V0X2pzb24oKQogICAgICAgICAgICAgICAgYXNzZXJ0IGdvWyJvayJdIGlzIFRydWUgYW5kIHN0YXJ0ZWQgYW5kIHN0YXJ0ZWRbMF1bOjNdID09IFsic3VkbyIsICItbiIsIGdbIkNMT05FX1NDUklQVCJdXQogICAgICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICAgICAgX2R0X3N1Yi5Qb3BlbiA9IG9sZF9wb3BlbgogICAgICAgIGZpbmFsbHk6CiAgICAgICAgICAgIGdbIl9kdF9sb2FkIl0gPSByZWFsX2xvYWQKICAgICAgICAgICAgZ1siX2R0X3Rha2VvdmVyIl0gPSByZWFsX3RrCg=="}]

if __name__ == "__main__":
    sys.exit(main(sys.argv))
