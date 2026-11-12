#!/usr/bin/env python3
# ntfy-Kachel vor die Sicherung. Ersetzt nur den Kachel-Block in dashboard.py.
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
    tmp = path.with_name("." + path.name + ".tmp-ntfy2")
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
    alt = sorted(path.parent.glob(path.name + ".bak-ntfy2-*"))
    bak = path.with_name(path.name + ".bak-ntfy2-" + stempel)
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
    if dash.count(old) != 1 or dash.count(new) != 0 or b'id="ntfyOn"' in dash:
        print("STOP: dashboard.py Kachel-Block unbekannt")
        return 2
    neu = dash.replace(old, new, 1)
    if neu.replace(new, b"", 1) != dash.replace(old, b"", 1):
        print("STOP: dashboard.py wuerde ausserhalb der Kachel geaendert")
        return 2
    if b'_rq.path != "/pi"' not in neu or b'id="backupBox"' not in new:
        print("STOP: neue Kachel unvollstaendig")
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
    print("geschrieben. Nur der Kachel-Block in dashboard.py.")
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
    assert b"/system" in old and b'id="ntfyOn"' in new and b"_nty_place" in new
    blob = b"VOR\n" + old + b"NACH\n# FREMD\n"
    neu = blob.replace(old, new, 1)
    assert blob.replace(old, b"", 1) == neu.replace(new, b"", 1)
    assert b"# FREMD" in neu and b'id="ntfyTest"' in neu and b'method:"POST"' in neu
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

PAYLOAD = {"old": "X05UWV9DQVJEID0gKCc8ZGl2IGNsYXNzPSJjYXJkIiBpZD0ibnRmeUJveCIgc3R5bGU9Im1hcmdpbi10b3A6MTJweCI+JwogICAgICAgICAgICAgJzxkaXYgc3R5bGU9ImZvbnQtd2VpZ2h0OjYwMCI+bnRmeTwvZGl2PicKICAgICAgICAgICAgICc8ZGl2IGlkPSJudGZ5U3RhdGUiIHN0eWxlPSJmb250LXNpemU6MTNweDtjb2xvcjojY2JkNWUxIj53aXJkIGdlbGVzZW4g4oCmPC9kaXY+JwogICAgICAgICAgICAgJzxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiM5NGEzYjg7bWFyZ2luLXRvcDo0cHgiPlN0YW5kYXJkIGF1cy4gS2VpbiBNZXNoLjwvZGl2PjwvZGl2PicKICAgICAgICAgICAgICc8c2NyaXB0IGlkPSJudGZ5LWpzIj4oZnVuY3Rpb24oKXt2YXIgcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgibnRmeVN0YXRlIik7aWYoIXMpcmV0dXJuOycKICAgICAgICAgICAgICdmdW5jdGlvbiByb3coYyl7cmV0dXJuICJudGZ5ICIrKGMuZW5hYmxlZD09IjEiPyJhbiI6ImF1cyIpKyIgwrcgIisoYy5zZXJ2ZXJ8fCIiKSsiIMK3IFRoZW1hICIrKGMudG9waWN8fCLigJQiKTt9JwogICAgICAgICAgICAgJ2ZldGNoKCIvYXBpL250ZnkiLHtjYWNoZToibm8tc3RvcmUifSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCl9KS50aGVuKGZ1bmN0aW9uKGQpe3MudGV4dENvbnRlbnQ9cm93KChkJiZkLmNmZyl8fHt9KTt9KScKICAgICAgICAgICAgICcuY2F0Y2goZnVuY3Rpb24oKXtzLnRleHRDb250ZW50PSJudGZ5IG5pY2h0IGxlc2JhciI7fSk7fSkoKTs8L3NjcmlwdD4nKQoKCmRlZiBfbnR5X2FmdGVyKHJlc3ApOgogICAgdHJ5OgogICAgICAgIGZyb20gZmxhc2sgaW1wb3J0IHJlcXVlc3QgYXMgX3JxCiAgICAgICAgaWYgX3JxLnBhdGggbm90IGluICgiL3N5c3RlbSIsICIvdW13ZWx0Iikgb3IgcmVzcC5zdGF0dXNfY29kZSAhPSAyMDAgb3IgcmVzcC5kaXJlY3RfcGFzc3Rocm91Z2g6CiAgICAgICAgICAgIHJldHVybiByZXNwCiAgICAgICAgaWYgKHJlc3AubWltZXR5cGUgb3IgIiIpICE9ICJ0ZXh0L2h0bWwiOgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIGJvZHkgPSByZXNwLmdldF9kYXRhKGFzX3RleHQ9VHJ1ZSkKICAgICAgICBpZiAnaWQ9Im50ZnlCb3giJyBpbiBib2R5OgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIGogPSBib2R5LnJmaW5kKCI8L2JvZHk+IikKICAgICAgICByZXNwLnNldF9kYXRhKChib2R5WzpqXSArIF9OVFlfQ0FSRCArIGJvZHlbajpdKSBpZiBqID49IDAgZWxzZSAoYm9keSArIF9OVFlfQ0FSRCkpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgcHJpbnQoIm50ZnlQdXNoOiIsIHR5cGUoZSkuX19uYW1lX18sIGZsdXNoPVRydWUpCiAgICByZXR1cm4gcmVzcAoKCnRyeToKICAgIGFzc2VydCBfbnR5LnNlbGZ0ZXN0KCkuc3RhcnRzd2l0aCgibnRmeVB1c2ggb2siKQo=", "new": "X05UWV9DQVJEID0gKAogICAgJzxkaXYgY2xhc3M9ImNhcmQiIGlkPSJudGZ5Qm94IiBzdHlsZT0ibWFyZ2luLXRvcDoxNnB4Ij4nCiAgICAnPGRpdiBjbGFzcz0idGl0bGUiIHN0eWxlPSJmb250LXNpemU6MTVweDtmb250LXdlaWdodDo2MDA7bWFyZ2luOjAgMCA2cHgiPm50Znk8L2Rpdj4nCiAgICAnPGRpdiBpZD0ibnRmeU1zZyIgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiNmYmJmMjQ7bWluLWhlaWdodDoxLjJlbSI+PC9kaXY+JwogICAgJzxsYWJlbCBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHg7YWxpZ24taXRlbXM6Y2VudGVyO21hcmdpbjo2cHggMCI+PGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0ibnRmeU9uIj4gSGF1cHRzY2hhbHRlcjwvbGFiZWw+JwogICAgJzxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtmbGV4LXdyYXA6d3JhcDtnYXA6OHB4O21hcmdpbjo2cHggMCI+JwogICAgJzxpbnB1dCBpZD0ibnRmeVNlcnZlciIgdHlwZT0idGV4dCIgaW5wdXRtb2RlPSJ1cmwiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSIgcGxhY2Vob2xkZXI9Imh0dHBzOi8vbnRmeS5zaCIgc3R5bGU9ImZsZXg6MTttaW4td2lkdGg6MTJyZW07cGFkZGluZzo2cHggOHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgIzMzNDE1NTtiYWNrZ3JvdW5kOiMwZjE3MmE7Y29sb3I6I2UyZThmMDtmb250LXNpemU6Ljg1cmVtIj4nCiAgICAnPGlucHV0IGlkPSJudGZ5VG9waWMiIHR5cGU9InRleHQiIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSIgcGxhY2Vob2xkZXI9IlRoZW1hIiBzdHlsZT0iZmxleDoxO21pbi13aWR0aDo4cmVtO3BhZGRpbmc6NnB4IDhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkICMzMzQxNTU7YmFja2dyb3VuZDojMGYxNzJhO2NvbG9yOiNlMmU4ZjA7Zm9udC1zaXplOi44NXJlbSI+JwogICAgJzwvZGl2PicKICAgICc8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7ZmxleC13cmFwOndyYXA7Z2FwOjhweCAxNHB4O21hcmdpbjo2cHggMDtmb250LXNpemU6MTNweCI+JwogICAgJzxsYWJlbD48aW5wdXQgdHlwZT0iY2hlY2tib3giIGlkPSJudGZ5RHdkIj4gRFdELVdhcm51bmdlbjwvbGFiZWw+JwogICAgJzxsYWJlbD48aW5wdXQgdHlwZT0iY2hlY2tib3giIGlkPSJudGZ5VXN2Ij4gVVNWLUFra3ViZXRyaWViPC9sYWJlbD4nCiAgICAnPGxhYmVsPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9Im50ZnlQaW4iPiBQaW5uZWJlcmctTWVsZHVuZzwvbGFiZWw+JwogICAgJzxsYWJlbD48aW5wdXQgdHlwZT0iY2hlY2tib3giIGlkPSJudGZ5RGllbnN0Ij4gRGllbnN0LUF1c2ZhbGw8L2xhYmVsPicKICAgICc8L2Rpdj4nCiAgICAnPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHg7ZmxleC13cmFwOndyYXA7bWFyZ2luLXRvcDo4cHgiPicKICAgICc8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9Im50ZnlTYXZlIiBzdHlsZT0icGFkZGluZzo2cHggMTJweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MDtiYWNrZ3JvdW5kOiMyNTYzZWI7Y29sb3I6I2ZmZjtmb250LXNpemU6Ljg1cmVtIj5TcGVpY2hlcm48L2J1dHRvbj4nCiAgICAnPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJudGZ5VGVzdCIgc3R5bGU9InBhZGRpbmc6NnB4IDEycHg7Ym9yZGVyLXJhZGl1czo4cHg7Ym9yZGVyOjFweCBzb2xpZCAjNDc1NTY5O2JhY2tncm91bmQ6dHJhbnNwYXJlbnQ7Y29sb3I6I2NiZDVlMTtmb250LXNpemU6Ljg1cmVtIj5UZXN0PC9idXR0b24+JwogICAgJzwvZGl2PicKICAgICc8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjojOTRhM2I4O21hcmdpbi10b3A6NnB4Ij5TdGFuZGFyZCBhdXMuIEFic3RhbmQgZ2VnZW4gV2llZGVyaG9sdW5nLiBLZWluIE1lc2guPC9kaXY+PC9kaXY+JwogICAgJzxzY3JpcHQgaWQ9Im50ZnktanMiPihmdW5jdGlvbigpe3ZhciBCPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJudGZ5Qm94Iik7aWYoIUIpcmV0dXJuOycKICAgICdmdW5jdGlvbiBnKGkpe3JldHVybiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpKTt9ZnVuY3Rpb24gbXNnKHQpe3ZhciBtPWcoIm50ZnlNc2ciKTtpZihtKW0udGV4dENvbnRlbnQ9dHx8IiI7fScKICAgICdmdW5jdGlvbiBiaXQodil7cmV0dXJuIHY9PSIxInx8dj09PXRydWV8fHY9PSJ0cnVlIjt9JwogICAgJ2Z1bmN0aW9uIGZpbGwoYyl7Yz1jfHx7fTtnKCJudGZ5T24iKS5jaGVja2VkPWJpdChjLmVuYWJsZWQpO2coIm50ZnlTZXJ2ZXIiKS52YWx1ZT1jLnNlcnZlcnx8Imh0dHBzOi8vbnRmeS5zaCI7ZygibnRmeVRvcGljIikudmFsdWU9Yy50b3BpY3x8IiI7JwogICAgJ2coIm50ZnlEd2QiKS5jaGVja2VkPWJpdChjLnNyY19kd2QpO2coIm50ZnlVc3YiKS5jaGVja2VkPWJpdChjLnNyY191c3YpO2coIm50ZnlQaW4iKS5jaGVja2VkPWJpdChjLnNyY19waW5uZWJlcmcpO2coIm50ZnlEaWVuc3QiKS5jaGVja2VkPWJpdChjLnNyY19kaWVuc3QpO30nCiAgICAnZnVuY3Rpb24gYm9keSh0ZXN0KXtyZXR1cm4ge2VuYWJsZWQ6ZygibnRmeU9uIikuY2hlY2tlZD8iMSI6IjAiLHNlcnZlcjooZygibnRmeVNlcnZlciIpLnZhbHVlfHwiIikudHJpbSgpLHRvcGljOihnKCJudGZ5VG9waWMiKS52YWx1ZXx8IiIpLnRyaW0oKSwnCiAgICAnc3JjX2R3ZDpnKCJudGZ5RHdkIikuY2hlY2tlZD8iMSI6IjAiLHNyY191c3Y6ZygibnRmeVVzdiIpLmNoZWNrZWQ/IjEiOiIwIixzcmNfcGlubmViZXJnOmcoIm50ZnlQaW4iKS5jaGVja2VkPyIxIjoiMCIsc3JjX2RpZW5zdDpnKCJudGZ5RGllbnN0IikuY2hlY2tlZD8iMSI6IjAiLHRlc3Q6ISF0ZXN0fTt9JwogICAgJ2Z1bmN0aW9uIHNlbmQodGVzdCl7bXNnKHRlc3Q/IlRlc3Qgd2lyZCBnZXNlbmRldCDigKYiOiJzcGVpY2hlcmUg4oCmIik7cmV0dXJuIGZldGNoKCIvYXBpL250ZnkiLHttZXRob2Q6IlBPU1QiLGhlYWRlcnM6eyJDb250ZW50LVR5cGUiOiJhcHBsaWNhdGlvbi9qc29uIn0sYm9keTpKU09OLnN0cmluZ2lmeShib2R5KHRlc3QpKX0pJwogICAgJy50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKS50aGVuKGZ1bmN0aW9uKGQpe3JldHVybiB7b2s6ci5vayxkOmR9O30pO30pLnRoZW4oZnVuY3Rpb24oeCl7aWYoeC5kJiZ4LmQuY2ZnKWZpbGwoeC5kLmNmZyk7JwogICAgJ21zZyh4Lm9rPyh0ZXN0PyhiaXQoKHguZC5jZmd8fHt9KS5lbmFibGVkKT8iVGVzdCBhbmdlc3Rvc3NlbiI6IkhhdXB0c2NoYWx0ZXIgYXVzLCBrZWluIFRlc3QiKToiZ2VzcGVpY2hlcnQiKToibmljaHQgZ2VzcGVpY2hlcnQiKTt9KS5jYXRjaChmdW5jdGlvbigpe21zZygiVmVyYmluZHVuZyBmZWhsZ2VzY2hsYWdlbiIpO30pO30nCiAgICAnZnVuY3Rpb24gbXYoKXt0cnl7dmFyIGI9ZygiYmFja3VwQm94Iik7aWYoYiYmYi5wYXJlbnROb2RlJiZiLnByZXZpb3VzRWxlbWVudFNpYmxpbmchPT1CKXtiLnBhcmVudE5vZGUuaW5zZXJ0QmVmb3JlKEIsYik7fScKICAgICdkb2N1bWVudC5ib2R5LnNldEF0dHJpYnV0ZSgiZGF0YS1udGZ5LW9ydCIsKGcoImJhY2t1cEJveCIpJiZCLm5leHRFbGVtZW50U2libGluZz09PWcoImJhY2t1cEJveCIpKT8idm9yLXNpY2hlcnVuZyI6Im9obmUtc2ljaGVydW5nIik7fWNhdGNoKGUpe319JwogICAgJ2coIm50ZnlTYXZlIikuYWRkRXZlbnRMaXN0ZW5lcigiY2xpY2siLGZ1bmN0aW9uKCl7c2VuZChmYWxzZSk7fSk7ZygibnRmeVRlc3QiKS5hZGRFdmVudExpc3RlbmVyKCJjbGljayIsZnVuY3Rpb24oKXtzZW5kKHRydWUpO30pOycKICAgICdmZXRjaCgiL2FwaS9udGZ5Iix7Y2FjaGU6Im5vLXN0b3JlIn0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pLnRoZW4oZnVuY3Rpb24oZCl7ZmlsbCgoZCYmZC5jZmcpfHx7fSk7fSkuY2F0Y2goZnVuY3Rpb24oKXttc2coIm50ZnkgbmljaHQgbGVzYmFyIik7fSk7JwogICAgJ2RvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoIkRPTUNvbnRlbnRMb2FkZWQiLG12KTt3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigibG9hZCIsbXYpO3NldFRpbWVvdXQobXYsMTEwMCk7c2V0VGltZW91dChtdiwyNjAwKTtzZXRUaW1lb3V0KG12LDUyMDApO30pKCk7PC9zY3JpcHQ+JykKCgpkZWYgX250eV9wbGFjZShib2R5LCB0aWxlKToKICAgICIiIkthY2hlbCBkaXJla3Qgdm9yICNiYWNrdXBCb3guIE9obmUgZGllc2VuIEJsb2NrIGtlaW4gQW5oYWVuZ2VuIGFucyBTZWl0ZW5lbmRlLiIiIgogICAgYmxrID0gTm9uZQogICAgdHJ5OgogICAgICAgIGJsayA9IGdsb2JhbHMoKVsiX3BwMl9ibG9jayJdKGJvZHkpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIGJsayA9IE5vbmUKICAgIGlmIG5vdCBibGs6CiAgICAgICAgcmV0dXJuIGJvZHkKICAgIHJldHVybiBib2R5WzpibGtbMF1dICsgdGlsZSArIGJvZHlbYmxrWzBdOl0KCgpkZWYgX250eV9hZnRlcihyZXNwKToKICAgIHRyeToKICAgICAgICBmcm9tIGZsYXNrIGltcG9ydCByZXF1ZXN0IGFzIF9ycQogICAgICAgIGlmIF9ycS5wYXRoICE9ICIvcGkiIG9yIHJlc3Auc3RhdHVzX2NvZGUgIT0gMjAwIG9yIHJlc3AuZGlyZWN0X3Bhc3N0aHJvdWdoOgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIGlmIChyZXNwLm1pbWV0eXBlIG9yICIiKSAhPSAidGV4dC9odG1sIjoKICAgICAgICAgICAgcmV0dXJuIHJlc3AKICAgICAgICBib2R5ID0gcmVzcC5nZXRfZGF0YShhc190ZXh0PVRydWUpCiAgICAgICAgaWYgJ2lkPSJudGZ5Qm94IicgaW4gYm9keSBvciAnaWQ9ImJhY2t1cEJveCInIG5vdCBpbiBib2R5OgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIHJlc3Auc2V0X2RhdGEoX250eV9wbGFjZShib2R5LCBfTlRZX0NBUkQpKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIHByaW50KCJudGZ5UHVzaDoiLCB0eXBlKGUpLl9fbmFtZV9fLCBmbHVzaD1UcnVlKQogICAgcmV0dXJuIHJlc3AKCgp0cnk6CiAgICBhc3NlcnQgX250eS5zZWxmdGVzdCgpLnN0YXJ0c3dpdGgoIm50ZnlQdXNoIG9rIikKICAgIF9udHlfcHJvYmUgPSAnPGJvZHk+PGRpdiBjbGFzcz0iY2FyZCIgaWQ9ImF1ZGlvQm94Ij48L2Rpdj48ZGl2IGNsYXNzPSJjYXJkIiBpZD0iYmFja3VwQm94Ij48ZGl2Png8L2Rpdj48L2Rpdj48ZGl2IGlkPSJwcm9qRG9jQm94IiBjbGFzcz0icGQtY2FyZCI+UDwvZGl2PjwvYm9keT4nCiAgICBfbnR5X291dCA9IF9udHlfcGxhY2UoX250eV9wcm9iZSwgJzxkaXYgY2xhc3M9ImNhcmQiIGlkPSJudGZ5Qm94Ij48L2Rpdj4nKQogICAgYXNzZXJ0IF9udHlfb3V0LmZpbmQoImF1ZGlvQm94IikgPCBfbnR5X291dC5maW5kKCJudGZ5Qm94IikgPCBfbnR5X291dC5maW5kKCJiYWNrdXBCb3giKSA8IF9udHlfb3V0LmZpbmQoInByb2pEb2NCb3giKQogICAgYXNzZXJ0IF9udHlfcGxhY2UoIjxib2R5Pm9obmU8L2JvZHk+IiwgIjxkaXYgaWQ9XCJudGZ5Qm94XCI+IikgPT0gIjxib2R5Pm9obmU8L2JvZHk+IgogICAgYXNzZXJ0ICdpZD0ibnRmeU9uIicgaW4gX05UWV9DQVJEIGFuZCAnaWQ9Im50ZnlTZXJ2ZXIiJyBpbiBfTlRZX0NBUkQgYW5kICdpZD0ibnRmeVRvcGljIicgaW4gX05UWV9DQVJECiAgICBhc3NlcnQgJ2lkPSJudGZ5RHdkIicgaW4gX05UWV9DQVJEIGFuZCAnaWQ9Im50ZnlVc3YiJyBpbiBfTlRZX0NBUkQgYW5kICdpZD0ibnRmeVBpbiInIGluIF9OVFlfQ0FSRCBhbmQgJ2lkPSJudGZ5RGllbnN0IicgaW4gX05UWV9DQVJECiAgICBhc3NlcnQgJ2lkPSJudGZ5VGVzdCInIGluIF9OVFlfQ0FSRCBhbmQgJ21ldGhvZDoiUE9TVCInIGluIF9OVFlfQ0FSRCBhbmQgJyIvYXBpL250ZnkiJyBpbiBfTlRZX0NBUkQK"}

if __name__ == "__main__":
    sys.exit(main(sys.argv))
