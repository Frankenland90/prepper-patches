#!/usr/bin/env python3
# Schalter HB ins Mesh 1. Drei Stellen in dashboard.py.
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
    tmp = path.with_name("." + path.name + ".tmp-hb")
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
    alt = sorted(path.parent.glob(path.name + ".bak-hb-*"))
    bak = path.with_name(path.name + ".bak-hb-" + stempel)
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
    if b"def _fua_after" not in dash:
        print("STOP: funkAuf-Ausgabe fehlt")
        return 2
    if b"def _hbmesh_after" in dash and all(dash.count(new) == 1 for _, new in pairs):
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
    if b"def _hbmesh_after" not in neu or b"HB ins Mesh 1" not in neu:
        print("STOP: Schalter unvollstaendig")
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
    print("geschrieben. Nur die HB-Stellen in dashboard.py.")
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
    assert b"# FREMD" in neu and b"def _hbmesh_after" in neu and b"HB ins Mesh 1" in neu
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

PAYLOAD = [{"old": "ICAgIGlmIGhiLmdldCgic2xvdCIpID09IHN0LmdldCgiaGJfc2xvdF9zZW50Iikgb3Igbm93IC0gaGJbIndfdCJdID4gVDRfSEJfR0lWRVVQX1M6CiAgICAgICAgaGJbImR1ZSJdID0gTm9uZQo=", "new": "ICAgIGlmIGhiLmdldCgic2xvdCIpID09IHN0LmdldCgiaGJfc2xvdF9zZW50Iikgb3Igbm93IC0gaGJbIndfdCJdID4gVDRfSEJfR0lWRVVQX1M6CiAgICAgICAgaGJbImR1ZSJdID0gTm9uZQogICAgICAgIHJldHVybiAic2tpcCIKICAgIF9oYm1lc2hfZm4gPSBnbG9iYWxzKCkuZ2V0KCJfaGJtZXNoX2VuYWJsZWQiKQogICAgaWYgY2FsbGFibGUoX2hibWVzaF9mbikgYW5kIG5vdCBfaGJtZXNoX2ZuKCk6CiAgICAgICAgc3RbImhiX3Nsb3Rfc2VudCJdID0gaGJbInNsb3QiXQogICAgICAgIGhiWyJkdWUiXSA9IE5vbmUKICAgICAgICBfdDRfc2F2ZSgpCg=="}, {"old": "ICAgIGlmIG5vdCBocFsicSJdOgogICAgICAgIHJldHVybiBOb25lCg==", "new": "ICAgIGlmIG5vdCBocFsicSJdOgogICAgICAgIHJldHVybiBOb25lCiAgICBfaGJtZXNoX2ZuID0gZ2xvYmFscygpLmdldCgiX2hibWVzaF9lbmFibGVkIikKICAgIGlmIGNhbGxhYmxlKF9oYm1lc2hfZm4pIGFuZCBub3QgX2hibWVzaF9mbigpOgogICAgICAgIHdoaWxlIGhwWyJxIl06CiAgICAgICAgICAgIGUgPSBocFsicSJdLnBvcCgwKQogICAgICAgICAgICBpZiBlLmdldCgia2luZCIpID09ICJvbiI6CiAgICAgICAgICAgICAgICBmb3IgeCBpbiBlLmdldCgia2V5cyIpIG9yIFtdOgogICAgICAgICAgICAgICAgICAgIGhwWyJsYXN0Il1beF0gPSBub3cKICAgICAgICAgICAgICAgICAgICBpZiBpc2luc3RhbmNlKGhwWyJrIl0uZ2V0KHgpLCBkaWN0KToKICAgICAgICAgICAgICAgICAgICAgICAgaHBbImsiXVt4XVsic2VudCJdID0gVHJ1ZQogICAgICAgIHJldHVybiAic2tpcCIK"}, {"old": "IyA9PT09PSAvZnVua0F1ZiA9PT09PQoK", "new": "IyA9PT09PSAvZnVua0F1ZiA9PT09PQoKIyA9PT09PSBoYk1lc2g6IFNjaGFsdGVyIEhCIGlucyBNZXNoIDEuIFN0YW5kYXJkIGF1cy4gTnVyIFRleHRlIG1pdCBIQi4gPT09PT0KaW1wb3J0IG9zIGFzIF9oYm1fb3MKaW1wb3J0IHNxbGl0ZTMgYXMgX2hibV9zcWwKCl9IQk1fQ0FSRCA9ICgKICAgICc8ZGl2IGNsYXNzPSJjYXJkIiBpZD0iaGJNZXNoQm94IiBzdHlsZT0ibWFyZ2luLXRvcDoxNnB4Ij4nCiAgICAnPGxhYmVsIHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjhweDthbGlnbi1pdGVtczpjZW50ZXIiPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImhiTWVzaE9uIj4gSEIgaW5zIE1lc2ggMTwvbGFiZWw+JwogICAgJzxkaXYgaWQ9ImhiTWVzaE1zZyIgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiNmYmJmMjQ7bWluLWhlaWdodDoxLjJlbSI+PC9kaXY+JwogICAgJzxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiM5NGEzYjgiPlN0YW5kYXJkIGF1cy4gTnVyIE1lbGR1bmdlbiBtaXQgSEIuIEFsYXJtZSwgV2V0dGVyIHVuZCBQZWdlbCBibGVpYmVuLjwvZGl2PjwvZGl2PicKICAgICc8c2NyaXB0IGlkPSJoYm1lc2gtanMiPihmdW5jdGlvbigpe3ZhciBiPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJoYk1lc2hPbiIpO2lmKCFiKXJldHVybjsnCiAgICAnZnVuY3Rpb24gbXNnKHQpe3ZhciBtPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJoYk1lc2hNc2ciKTtpZihtKW0udGV4dENvbnRlbnQ9dHx8IiI7fScKICAgICdmZXRjaCgiL2FwaS9oYm1lc2giLHtjYWNoZToibm8tc3RvcmUifSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSkudGhlbihmdW5jdGlvbihkKXtiLmNoZWNrZWQ9ISEoZCYmZC5lbmFibGVkKTt9KS5jYXRjaChmdW5jdGlvbigpe21zZygibmljaHQgbGVzYmFyIik7fSk7JwogICAgJ2IuYWRkRXZlbnRMaXN0ZW5lcigiY2hhbmdlIixmdW5jdGlvbigpe21zZygic3BlaWNoZXJlIOKApiIpO2ZldGNoKCIvYXBpL2hibWVzaCIse21ldGhvZDoiUE9TVCIsaGVhZGVyczp7IkNvbnRlbnQtVHlwZSI6ImFwcGxpY2F0aW9uL2pzb24ifSxib2R5OkpTT04uc3RyaW5naWZ5KHtlbmFibGVkOmIuY2hlY2tlZD8iMSI6IjAifSl9KScKICAgICcudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSkudGhlbihmdW5jdGlvbihkKXtpZihkKWIuY2hlY2tlZD0hIWQuZW5hYmxlZDttc2coYi5jaGVja2VkPyJhbiI6ImF1cyIpO30pLmNhdGNoKGZ1bmN0aW9uKCl7bXNnKCJuaWNodCBnZXNwZWljaGVydCIpO30pO30pO30pKCk7PC9zY3JpcHQ+JwopCgoKZGVmIF9oYm1lc2hfZGIoKToKICAgIHRyeToKICAgICAgICBiYXNlLCBwYXRoID0gX3Q0X3BhdGhzKCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgYmFzZSwgcGF0aCA9IF9TRFJfQkFTRSwgIiIKICAgIHJldHVybiBwYXRoIG9yIF9oYm1fb3MucGF0aC5qb2luKGJhc2UsICJsYWdlemVudHJ1bS5kYiIpCgoKZGVmIF9oYm1lc2hfY29uKHBhdGgpOgogICAgY29uID0gX2hibV9zcWwuY29ubmVjdChwYXRoLCB0aW1lb3V0PTUpCiAgICBtb2RlID0gY29uLmV4ZWN1dGUoIlBSQUdNQSBqb3VybmFsX21vZGU9V0FMIikuZmV0Y2hvbmUoKQogICAgaWYgbW9kZSBpcyBOb25lIG9yIHN0cihtb2RlWzBdKS5sb3dlcigpICE9ICJ3YWwiOgogICAgICAgIGNvbi5jbG9zZSgpCiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCJ3YWwiKQogICAgY29uLmV4ZWN1dGUoIlBSQUdNQSBzeW5jaHJvbm91cz1OT1JNQUwiKQogICAgY29uLmV4ZWN1dGUoIkNSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RTIGhiX21lc2ggKGsgVEVYVCBQUklNQVJZIEtFWSwgdiBURVhUKSIpCiAgICByZXR1cm4gY29uCgoKZGVmIF9oYm1lc2hfZW5hYmxlZCgpOgogICAgcGF0aCA9IF9oYm1lc2hfZGIoKQogICAgaWYgbm90IF9oYm1fb3MucGF0aC5pc2ZpbGUocGF0aCk6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICB0cnk6CiAgICAgICAgY29uID0gX2hibWVzaF9jb24ocGF0aCkKICAgICAgICByb3cgPSBjb24uZXhlY3V0ZSgiU0VMRUNUIHYgRlJPTSBoYl9tZXNoIFdIRVJFIGs9J2VuYWJsZWQnIikuZmV0Y2hvbmUoKQogICAgICAgIGNvbi5jbG9zZSgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuIGJvb2wocm93IGFuZCBzdHIocm93WzBdKSA9PSAiMSIpCgoKZGVmIF9oYm1lc2hfc2F2ZShvbik6CiAgICBwYXRoID0gX2hibWVzaF9kYigpCiAgICBjb24gPSBfaGJtZXNoX2NvbihwYXRoKQogICAgdHJ5OgogICAgICAgIGNvbi5leGVjdXRlKCJJTlNFUlQgSU5UTyBoYl9tZXNoIChrLCB2KSBWQUxVRVMgKCdlbmFibGVkJywgPykgT04gQ09ORkxJQ1QoaykgRE8gVVBEQVRFIFNFVCB2PWV4Y2x1ZGVkLnYiLCAoIjEiIGlmIG9uIGVsc2UgIjAiLCkpCiAgICAgICAgY29uLmNvbW1pdCgpCiAgICBmaW5hbGx5OgogICAgICAgIGNvbi5jbG9zZSgpCiAgICByZXR1cm4gX2hibWVzaF9lbmFibGVkKCkKCgpkZWYgX2hibWVzaF9hcGkoKToKICAgIGZyb20gZmxhc2sgaW1wb3J0IGpzb25pZnksIHJlcXVlc3QKICAgIGlmIHJlcXVlc3QubWV0aG9kID09ICJQT1NUIjoKICAgICAgICBib2R5ID0gcmVxdWVzdC5nZXRfanNvbihzaWxlbnQ9VHJ1ZSkgb3Ige30KICAgICAgICBvbiA9IGJvZHkuZ2V0KCJlbmFibGVkIikgaW4gKCIxIiwgInRydWUiLCAiVHJ1ZSIsIFRydWUsIDEpCiAgICAgICAgcmV0dXJuIGpzb25pZnkoeyJvayI6IFRydWUsICJlbmFibGVkIjogYm9vbChfaGJtZXNoX3NhdmUob24pKX0pCiAgICByZXR1cm4ganNvbmlmeSh7Im9rIjogVHJ1ZSwgImVuYWJsZWQiOiBib29sKF9oYm1lc2hfZW5hYmxlZCgpKX0pCgoKZGVmIF9oYm1lc2hfcGxhY2UoYm9keSk6CiAgICBpZiAnaWQ9ImhiTWVzaEJveCInIGluIGJvZHk6CiAgICAgICAgcmV0dXJuIGJvZHkKICAgIGogPSBib2R5LmZpbmQoJ2lkPSJudGZ5Qm94IicpCiAgICBpZiBqID49IDA6CiAgICAgICAgayA9IGJvZHkucmZpbmQoIjxkaXYiLCAwLCBqKQogICAgICAgIGlmIGsgPj0gMDoKICAgICAgICAgICAgcmV0dXJuIGJvZHlbOmtdICsgX0hCTV9DQVJEICsgYm9keVtrOl0KICAgIGcgPSBib2R5LmZpbmQoJzxkaXYgY2xhc3M9ImdyaWQiIGlkPSJ1bXdHcmlkIj4nKQogICAgaWYgZyA+PSAwOgogICAgICAgIGVuZCA9IGcgKyBsZW4oJzxkaXYgY2xhc3M9ImdyaWQiIGlkPSJ1bXdHcmlkIj4nKQogICAgICAgIHJldHVybiBib2R5WzplbmRdICsgX0hCTV9DQVJEICsgYm9keVtlbmQ6XQogICAgcmV0dXJuIGJvZHkKCgpkZWYgX2hibWVzaF9hZnRlcihyZXNwKToKICAgIHRyeToKICAgICAgICBmcm9tIGZsYXNrIGltcG9ydCByZXF1ZXN0IGFzIF9ycQogICAgICAgIGlmIF9ycS5wYXRoIG5vdCBpbiAoIi9waSIsICIvc3lzdGVtIikgb3IgcmVzcC5zdGF0dXNfY29kZSAhPSAyMDAgb3IgcmVzcC5kaXJlY3RfcGFzc3Rocm91Z2g6CiAgICAgICAgICAgIHJldHVybiByZXNwCiAgICAgICAgaWYgKHJlc3AubWltZXR5cGUgb3IgIiIpICE9ICJ0ZXh0L2h0bWwiOgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIHJlc3Auc2V0X2RhdGEoX2hibWVzaF9wbGFjZShyZXNwLmdldF9kYXRhKGFzX3RleHQ9VHJ1ZSkpKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIHByaW50KCJoYk1lc2g6IiwgdHlwZShlKS5fX25hbWVfXywgZmx1c2g9VHJ1ZSkKICAgIHJldHVybiByZXNwCgoKZGVmIF9oYm1lc2hfc2VsZnRlc3QoKToKICAgIGltcG9ydCBzaHV0aWwKICAgIGltcG9ydCB0ZW1wZmlsZQogICAgZCA9IHRlbXBmaWxlLm1rZHRlbXAocHJlZml4PSJoYm1lc2gtIikKICAgIHAgPSBfaGJtX29zLnBhdGguam9pbihkLCAibGFnZXplbnRydW0uZGIiKQogICAga2VlcCA9IChfVDQuZ2V0KCJmYWtlIiksIF9UNC5nZXQoInN0IiksIGRpY3QoX1Q0LmdldCgiaGIiKSBvciB7fSksIGdsb2JhbHMoKS5nZXQoIl90NF9zZW5kX20xIikpCiAgICBzZW50ID0gW10KCiAgICBkZWYgYm9vbSh0ZXh0LCBraW5kKToKICAgICAgICBzZW50LmFwcGVuZCgodGV4dCwga2luZCkpCiAgICAgICAgcmV0dXJuIHsib2siOiBUcnVlfQogICAgdHJ5OgogICAgICAgIF9UNFsiZmFrZSJdID0geyJiYXNlIjogZCwgInBhdGgiOiBwfQogICAgICAgIF9UNFsic3QiXSA9IE5vbmUKICAgICAgICBfdDRfbG9hZCgpCiAgICAgICAgX1Q0WyJoYiJdID0geyJkdWUiOiAxLCAid190IjogOTAsICJzbG90IjogInNsb3QtMSIsICJuZXh0X3RyeSI6IDAsICJsYXN0IjogTm9uZX0KICAgICAgICBhc3NlcnQgX2hibWVzaF9lbmFibGVkKCkgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgX2hibWVzaF9zYXZlKFRydWUpIGlzIFRydWUgYW5kIF9oYm1lc2hfZW5hYmxlZCgpIGlzIFRydWUKICAgICAgICBjb24gPSBfaGJtX3NxbC5jb25uZWN0KHApCiAgICAgICAgYXNzZXJ0IHN0cihjb24uZXhlY3V0ZSgiUFJBR01BIGpvdXJuYWxfbW9kZSIpLmZldGNob25lKClbMF0pLmxvd2VyKCkgPT0gIndhbCIKICAgICAgICBjb24uY2xvc2UoKQogICAgICAgIF9oYm1lc2hfc2F2ZShGYWxzZSkKICAgICAgICBocCA9IF9ocF9zdGF0ZSgpCiAgICAgICAgaHBbImsiXVsiU0RSIl0gPSB7ImJhZCI6IFRydWUsICJzZW50IjogRmFsc2UsICJ0eHQiOiAiU0RSIiwgImNhbmQiOiBOb25lLCAiY2FuZF90IjogTm9uZSwgInNpbmNlIjogMX0KICAgICAgICBocFsicSJdID0gW3sia2luZCI6ICJvbiIsICJrZXlzIjogWyJTRFIiXSwgInBhcnRzIjogeyJTRFIiOiAiU0RSIGxpZWZlcnQga2VpbmUgRGF0ZW4ifSwgInQiOiAxLCAibmV4dCI6IDF9XQogICAgICAgIGdsb2JhbHMoKVsiX3Q0X3NlbmRfbTEiXSA9IGJvb20KICAgICAgICBhc3NlcnQgX2hwX3NlbmQoNTApID09ICJza2lwIiBhbmQgc2VudCA9PSBbXSBhbmQgaHBbInEiXSA9PSBbXSBhbmQgaHBbImsiXVsiU0RSIl1bInNlbnQiXSBpcyBUcnVlCiAgICAgICAgX2hibWVzaF9zYXZlKFRydWUpCiAgICAgICAgYXNzZXJ0IF9ocF9zZW5kKDYwKSBpcyBOb25lIGFuZCBzZW50ID09IFtdCiAgICAgICAgX2hibWVzaF9zYXZlKEZhbHNlKQogICAgICAgIGFzc2VydCBfSFBbIm9yaWciXSgxMDApID09ICJza2lwIiBhbmQgX3Q0X2xvYWQoKVsiaGJfc2xvdF9zZW50Il0gPT0gInNsb3QtMSIgYW5kIHNlbnQgPT0gW10KICAgICAgICBwYWdlID0gJzxkaXYgY2xhc3M9ImdyaWQiIGlkPSJ1bXdHcmlkIj48ZGl2IGNsYXNzPSJjYXJkIj5EV0Q8L2Rpdj48L2Rpdj48ZGl2IGNsYXNzPSJjYXJkIiBpZD0ibnRmeUJveCI+bjwvZGl2PicKICAgICAgICBvdXQgPSBfaGJtZXNoX3BsYWNlKHBhZ2UpCiAgICAgICAgYXNzZXJ0IG91dC5maW5kKCdpZD0iaGJNZXNoQm94IicpIDwgb3V0LmZpbmQoJ2lkPSJudGZ5Qm94IicpIGFuZCBvdXQuY291bnQoJ2lkPSJoYk1lc2hCb3giJykgPT0gMQogICAgICAgIGdyaWQgPSBfaGJtZXNoX3BsYWNlKCc8ZGl2IGNsYXNzPSJncmlkIiBpZD0idW13R3JpZCI+PGRpdiBjbGFzcz0iY2FyZCI+RFdEPC9kaXY+PC9kaXY+JykKICAgICAgICBhc3NlcnQgZ3JpZC5maW5kKCdpZD0idW13R3JpZCI+JykgPCBncmlkLmZpbmQoJ2lkPSJoYk1lc2hCb3giJykgPCBncmlkLmZpbmQoIkRXRCIpCiAgICAgICAgYXNzZXJ0IF9oYm1lc2hfcGxhY2UoIjxib2R5Pm9obmU8L2JvZHk+IikgPT0gIjxib2R5Pm9obmU8L2JvZHk+IgogICAgZmluYWxseToKICAgICAgICBfVDRbImZha2UiXSwgX1Q0WyJzdCJdLCBfVDRbImhiIl0gPSBrZWVwWzBdLCBrZWVwWzFdLCBrZWVwWzJdCiAgICAgICAgZ2xvYmFscygpWyJfdDRfc2VuZF9tMSJdID0ga2VlcFszXQogICAgICAgIHNodXRpbC5ybXRyZWUoZCwgaWdub3JlX2Vycm9ycz1UcnVlKQogICAgcmV0dXJuICJoYk1lc2ggb2sgKGF1cywgV0FMLCBTbG90IGVybGVkaWd0LCBrZWluZSBOYWNoaG9sLUZsdXQsIEthY2hlbCB2b3IgbnRmeSkiCgoKdHJ5OgogICAgYXNzZXJ0IF9oYm1lc2hfc2VsZnRlc3QoKS5zdGFydHN3aXRoKCJoYk1lc2ggb2siKQogICAgaWYgImFwcCIgaW4gZ2xvYmFscygpIGFuZCBub3QgYW55KGdldGF0dHIociwgInJ1bGUiLCAiIikgPT0gIi9hcGkvaGJtZXNoIiBmb3IgciBpbiBhcHAudXJsX21hcC5pdGVyX3J1bGVzKCkpOgogICAgICAgIGFwcC5hZGRfdXJsX3J1bGUoIi9hcGkvaGJtZXNoIiwgZW5kcG9pbnQ9ImhibWVzaF9hcGkiLCB2aWV3X2Z1bmM9X2hibWVzaF9hcGksIG1ldGhvZHM9WyJHRVQiLCAiUE9TVCJdKQogICAgaWYgImFwcCIgaW4gZ2xvYmFscygpIGFuZCBub3QgYW55KGdldGF0dHIoZiwgIl9fbmFtZV9fIiwgIiIpID09ICJfaGJtZXNoX2FmdGVyIiBmb3IgZiBpbiBhcHAuYWZ0ZXJfcmVxdWVzdF9mdW5jcy5nZXQoTm9uZSwgW10pKToKICAgICAgICBhcHAuYWZ0ZXJfcmVxdWVzdF9mdW5jcy5zZXRkZWZhdWx0KE5vbmUsIFtdKS5pbnNlcnQoMCwgX2hibWVzaF9hZnRlcikKICAgIHByaW50KCJoYk1lc2ggYWt0aXYiLCBmbHVzaD1UcnVlKQpleGNlcHQgRXhjZXB0aW9uIGFzIF9oYm1fZToKICAgIHByaW50KCJoYk1lc2ggRkVITEVSOiAlcyIgJSB0eXBlKF9oYm1fZSkuX19uYW1lX18sIGZsdXNoPVRydWUpCiMgPT09PT0gL2hiTWVzaCA9PT09PQoK"}]

if __name__ == "__main__":
    sys.exit(main(sys.argv))
