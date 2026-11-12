#!/usr/bin/env python3
# ntfy-Kachel. Aendert nur dashboard.py an einer Stelle und legt ntfy_push.py an.
from __future__ import annotations
import base64, hashlib, json, os, shutil, sys
from datetime import datetime
from pathlib import Path

DASH = Path("/home/fmg/prepper-dashboard")
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
    old = base64.b64decode(raw["old"]).decode("utf-8")
    new = base64.b64decode(raw["new"]).decode("utf-8")
    ntfy = base64.b64decode(raw["ntfy"])
    return old, new, ntfy

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def basis_ok(name, data: bytes) -> bool:
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
    tmp = path.with_name("." + path.name + ".tmp-ntfy")
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
    alt = sorted(path.parent.glob(path.name + ".bak-ntfy-*"))
    bak = path.with_name(path.name + ".bak-ntfy-" + stempel)
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
    old, new, ntfy = load()
    namen = list(FIXED) + list(PREFIX) + ["dashboard.py"]
    for name in namen:
        pfad = ordner / name
        if pfad.is_symlink() or not pfad.is_file():
            print("STOP: %s fehlt" % name)
            return 2
    blobs = {name: (ordner/name).read_bytes() for name in namen}
    for name in list(FIXED) + list(PREFIX):
        if not basis_ok(name, blobs[name]):
            print("STOP: %s %s ist nicht die Basis nach Pinneberg" % (name, sha(blobs[name])[:16]))
            return 2
    dash = blobs["dashboard.py"]
    if dash.count(new.encode()) == 1 and (ordner/"ntfy_push.py").is_file() and (ordner/"ntfy_push.py").read_bytes() == ntfy:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    if dash.count(old.encode()) != 1 or b'id="ntfyBox"' in dash:
        print("STOP: dashboard.py Pinneberg-Anschluss unbekannt")
        return 2
    neu = dash.replace(old.encode(), new.encode(), 1)
    if neu.replace(new.encode(), b"", 1) != dash.replace(old.encode(), b"", 1):
        print("STOP: dashboard.py wuerde ausserhalb der ntfy-Stelle geaendert")
        return 2
    try:
        compile(neu, "dashboard.py", "exec")
        compile(ntfy, "ntfy_push.py", "exec")
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
        sichern(ordner/"dashboard.py", dash)
        schreiben(ordner/"dashboard.py", neu)
        schreiben(ordner/"ntfy_push.py", ntfy)
    except (OSError, RuntimeError) as exc:
        print("STOP beim Schreiben: %s" % exc)
        return 3
    for name in list(FIXED) + list(PREFIX):
        if (ordner/name).read_bytes() != blobs[name]:
            print("STOP: %s wurde angefasst" % name)
            return 3
    print("geschrieben. Nur dashboard.py und ntfy_push.py.")
    if kein:
        print("Kein Neustart in dieser Pruefung.")
        return 0
    frei, meldung = fenster()
    print(meldung)
    if not frei:
        print("STOP: Dateien sind neu, der Neustart bleibt in der Sperre aus.")
        return 2
    import subprocess
    subprocess.run(["systemctl", "restart", "prepper-dashboard.service"], check=False)
    print("Nur prepper-dashboard neu gestartet.")
    return 0

def selftest() -> int:
    old, new, ntfy = load()
    blob = ("VOR\n" + old + "NACH\n# FREMD\n").encode()
    neu = blob.replace(old.encode(), new.encode(), 1)
    assert blob.replace(old.encode(), b"", 1) == neu.replace(new.encode(), b"", 1)
    assert b"# FREMD" in neu and b'id="ntfyBox"' in neu
    assert basis_ok("ups_manager.py", b"x") is False
    assert fenster(datetime(2026, 11, 12, 12, 10))[0]
    assert not fenster(datetime(2026, 11, 12, 9, 59))[0]
    assert not fenster(datetime(2026, 11, 12, 0, 4))[0]
    compile(ntfy, "ntfy_push.py", "exec")
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

PAYLOAD = {"old": "IyA9PT09PSAvcGlubmViZXJnUm9sbGUgPT09PT0KCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgo=", "new": "IyA9PT09PSAvcGlubmViZXJnUm9sbGUgPT09PT0KCiMgPT09PT0gbnRmeVB1c2g6IEthY2hlbCBhdWYgL3N5c3RlbS4gU3RhbmRhcmQgYXVzLiBWZXJzYW5kIGltIEhpbnRlcmdydW5kLCBrZWluIE1lc2guID09PT09CmltcG9ydCBvcyBhcyBfbnR5X29zCmltcG9ydCB0aHJlYWRpbmcgYXMgX250eV90aAppbXBvcnQgdGltZSBhcyBfbnR5X3RpbWUKaW1wb3J0IG50ZnlfcHVzaCBhcyBfbnR5CgpfTlRZID0gX250eS5IdWIoX250eV9vcy5wYXRoLmpvaW4oX1NEUl9CQVNFLCBfbnR5LkRCX05BTUUpKQoKCmRlZiBfbnR5X2FwaSgpOgogICAgZnJvbSBmbGFzayBpbXBvcnQganNvbmlmeSwgcmVxdWVzdAogICAgcGF0aCA9IF9OVFkucGF0aAogICAgaWYgcmVxdWVzdC5tZXRob2QgPT0gIlBPU1QiOgogICAgICAgIGJvZHkgPSByZXF1ZXN0LmdldF9qc29uKHNpbGVudD1UcnVlKSBvciB7fQogICAgICAgIGNmZyA9IF9udHkuc2F2ZShwYXRoLCBib2R5KQogICAgICAgIGlmIGJvZHkuZ2V0KCJ0ZXN0IikgYW5kIGNmZy5nZXQoImVuYWJsZWQiKSA9PSAiMSI6CiAgICAgICAgICAgIF9OVFkucHVzaCgidGVzdCIsICJUZXN0IHZvbSBMYWdlLURhc2hib2FyZCIpCiAgICAgICAgICAgIF9udHlfdGguVGhyZWFkKHRhcmdldD1fTlRZLmZsdXNoLCBkYWVtb249VHJ1ZSkuc3RhcnQoKQogICAgICAgIHJldHVybiBqc29uaWZ5KHsib2siOiBUcnVlLCAiY2ZnIjogY2ZnfSkKICAgIHJldHVybiBqc29uaWZ5KHsib2siOiBUcnVlLCAiY2ZnIjogX250eS5sb2FkKHBhdGgpfSkKCgpkZWYgX250eV9zYW1wbGUoKToKICAgIG91dCA9IFtdCiAgICBjZmcgPSBfbnR5LmxvYWQoX05UWS5wYXRoKQogICAgaWYgY2ZnLmdldCgiZW5hYmxlZCIpICE9ICIxIjoKICAgICAgICByZXR1cm4gb3V0CiAgICBpZiBjZmcuZ2V0KCJzcmNfZHdkIikgPT0gIjEiOgogICAgICAgIHRyeToKICAgICAgICAgICAgdyA9IGRhdGFfc3RvcmUuZ2V0KCJkd2Rfd2FybiIpIG9yIHt9CiAgICAgICAgICAgIGl0ZW1zID0gdy5nZXQoIml0ZW1zIikgaWYgaXNpbnN0YW5jZSh3LCBkaWN0KSBlbHNlIE5vbmUKICAgICAgICAgICAgaWYgaXRlbXM6CiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKCgiZHdkIiwgc3RyKGl0ZW1zWzBdLmdldCgiZXZlbnQiKSBvciBpdGVtc1swXS5nZXQoIm5hbWUiKSBvciAiRFdEIilbOjEyMF0pKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHBhc3MKICAgIGlmIGNmZy5nZXQoInNyY191c3YiKSA9PSAiMSI6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBtZ3IgPSAoX1VTViBvciB7fSkuZ2V0KCJtZ3IiKQogICAgICAgICAgICBpZiBtZ3IgYW5kIG1nci5zbmFwc2hvdCgpLmdldCgibW9kZSIpID09ICJBS0tVIjoKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQoKCJ1c3YiLCAiVVNWIEFra3ViZXRyaWViIikpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwogICAgaWYgY2ZnLmdldCgic3JjX3Bpbm5lYmVyZyIpID09ICIxIjoKICAgICAgICB0cnk6CiAgICAgICAgICAgIGltcG9ydCBwaW5uZWJlcmdfcnggYXMgX3J4CiAgICAgICAgICAgIGJveCA9IF9yeC5yZWNlbnQoX250eV9vcy5wYXRoLmpvaW4oX1NEUl9CQVNFLCBfcnguREJfTkFNRSkpCiAgICAgICAgICAgIGlmIGJveC5nZXQoImVtcGZhbmciKToKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQoKCJwaW5uZWJlcmciLCBzdHIoYm94LmdldCgidHh0Iikgb3IgIiIpWzoxMjBdKSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCiAgICBpZiBjZmcuZ2V0KCJzcmNfZGllbnN0IikgPT0gIjEiOgogICAgICAgIHRyeToKICAgICAgICAgICAgaW1wb3J0IHN1YnByb2Nlc3MKICAgICAgICAgICAgYmFkID0gW10KICAgICAgICAgICAgZm9yIHVuaXQgaW4gKCJwcmVwcGVyLWRhc2hib2FyZCIsICJwcmVwcGVyLXNkciIpOgogICAgICAgICAgICAgICAgciA9IHN1YnByb2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgImlzLWFjdGl2ZSIsIHVuaXRdLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9MikKICAgICAgICAgICAgICAgIGlmIChyLnN0ZG91dCBvciAiIikuc3RyaXAoKSBub3QgaW4gKCJhY3RpdmUiLCAiIik6CiAgICAgICAgICAgICAgICAgICAgYmFkLmFwcGVuZCh1bml0KQogICAgICAgICAgICBpZiBiYWQ6CiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKCgiZGllbnN0IiwgIkRpZW5zdCBhdXNnZWZhbGxlbjogIiArICIsICIuam9pbihiYWQpKSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCiAgICByZXR1cm4gb3V0CgoKZGVmIF9udHlfbG9vcCgpOgogICAgd2hpbGUgVHJ1ZToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGZvciBzcmMsIHRleHQgaW4gX250eV9zYW1wbGUoKToKICAgICAgICAgICAgICAgIF9OVFkucHVzaChzcmMsIHRleHQpCiAgICAgICAgICAgIF9OVFkuZmx1c2goKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHBhc3MKICAgICAgICBfbnR5X3RpbWUuc2xlZXAoMjApCgoKX05UWV9DQVJEID0gKCc8ZGl2IGNsYXNzPSJjYXJkIiBpZD0ibnRmeUJveCIgc3R5bGU9Im1hcmdpbi10b3A6MTJweCI+JwogICAgICAgICAgICAgJzxkaXYgc3R5bGU9ImZvbnQtd2VpZ2h0OjYwMCI+bnRmeTwvZGl2PicKICAgICAgICAgICAgICc8ZGl2IGlkPSJudGZ5U3RhdGUiIHN0eWxlPSJmb250LXNpemU6MTNweDtjb2xvcjojY2JkNWUxIj53aXJkIGdlbGVzZW4g4oCmPC9kaXY+JwogICAgICAgICAgICAgJzxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiM5NGEzYjg7bWFyZ2luLXRvcDo0cHgiPlN0YW5kYXJkIGF1cy4gS2VpbiBNZXNoLjwvZGl2PjwvZGl2PicKICAgICAgICAgICAgICc8c2NyaXB0IGlkPSJudGZ5LWpzIj4oZnVuY3Rpb24oKXt2YXIgcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgibnRmeVN0YXRlIik7aWYoIXMpcmV0dXJuOycKICAgICAgICAgICAgICdmdW5jdGlvbiByb3coYyl7cmV0dXJuICJudGZ5ICIrKGMuZW5hYmxlZD09IjEiPyJhbiI6ImF1cyIpKyIgwrcgIisoYy5zZXJ2ZXJ8fCIiKSsiIMK3IFRoZW1hICIrKGMudG9waWN8fCLigJQiKTt9JwogICAgICAgICAgICAgJ2ZldGNoKCIvYXBpL250ZnkiLHtjYWNoZToibm8tc3RvcmUifSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCl9KS50aGVuKGZ1bmN0aW9uKGQpe3MudGV4dENvbnRlbnQ9cm93KChkJiZkLmNmZyl8fHt9KTt9KScKICAgICAgICAgICAgICcuY2F0Y2goZnVuY3Rpb24oKXtzLnRleHRDb250ZW50PSJudGZ5IG5pY2h0IGxlc2JhciI7fSk7fSkoKTs8L3NjcmlwdD4nKQoKCmRlZiBfbnR5X2FmdGVyKHJlc3ApOgogICAgdHJ5OgogICAgICAgIGZyb20gZmxhc2sgaW1wb3J0IHJlcXVlc3QgYXMgX3JxCiAgICAgICAgaWYgX3JxLnBhdGggbm90IGluICgiL3N5c3RlbSIsICIvdW13ZWx0Iikgb3IgcmVzcC5zdGF0dXNfY29kZSAhPSAyMDAgb3IgcmVzcC5kaXJlY3RfcGFzc3Rocm91Z2g6CiAgICAgICAgICAgIHJldHVybiByZXNwCiAgICAgICAgaWYgKHJlc3AubWltZXR5cGUgb3IgIiIpICE9ICJ0ZXh0L2h0bWwiOgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIGJvZHkgPSByZXNwLmdldF9kYXRhKGFzX3RleHQ9VHJ1ZSkKICAgICAgICBpZiAnaWQ9Im50ZnlCb3giJyBpbiBib2R5OgogICAgICAgICAgICByZXR1cm4gcmVzcAogICAgICAgIGogPSBib2R5LnJmaW5kKCI8L2JvZHk+IikKICAgICAgICByZXNwLnNldF9kYXRhKChib2R5WzpqXSArIF9OVFlfQ0FSRCArIGJvZHlbajpdKSBpZiBqID49IDAgZWxzZSAoYm9keSArIF9OVFlfQ0FSRCkpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgcHJpbnQoIm50ZnlQdXNoOiIsIHR5cGUoZSkuX19uYW1lX18sIGZsdXNoPVRydWUpCiAgICByZXR1cm4gcmVzcAoKCnRyeToKICAgIGFzc2VydCBfbnR5LnNlbGZ0ZXN0KCkuc3RhcnRzd2l0aCgibnRmeVB1c2ggb2siKQogICAgaWYgImFwcCIgaW4gZ2xvYmFscygpIGFuZCBub3QgYW55KGdldGF0dHIociwgInJ1bGUiLCAiIikgPT0gIi9hcGkvbnRmeSIgZm9yIHIgaW4gYXBwLnVybF9tYXAuaXRlcl9ydWxlcygpKToKICAgICAgICBhcHAuYWRkX3VybF9ydWxlKCIvYXBpL250ZnkiLCBlbmRwb2ludD0ibnRmeV9hcGkiLCB2aWV3X2Z1bmM9X250eV9hcGksIG1ldGhvZHM9WyJHRVQiLCAiUE9TVCJdKQogICAgaWYgImFwcCIgaW4gZ2xvYmFscygpIGFuZCBub3QgYW55KGdldGF0dHIoZiwgIl9fbmFtZV9fIiwgIiIpID09ICJfbnR5X2FmdGVyIiBmb3IgZiBpbiBhcHAuYWZ0ZXJfcmVxdWVzdF9mdW5jcy5nZXQoTm9uZSwgW10pKToKICAgICAgICBhcHAuYWZ0ZXJfcmVxdWVzdF9mdW5jcy5zZXRkZWZhdWx0KE5vbmUsIFtdKS5pbnNlcnQoMCwgX250eV9hZnRlcikKICAgIGlmIF9udHlfb3MuZW52aXJvbi5nZXQoIk5URllfTk9fVEhSRUFEIikgIT0gIjEiOgogICAgICAgIF9udHlfdGguVGhyZWFkKHRhcmdldD1fbnR5X2xvb3AsIG5hbWU9Im50ZnlQdXNoIiwgZGFlbW9uPVRydWUpLnN0YXJ0KCkKICAgIHByaW50KCJudGZ5UHVzaCBha3RpdiIsIGZsdXNoPVRydWUpCmV4Y2VwdCBFeGNlcHRpb24gYXMgX250eV9lOgogICAgcHJpbnQoIm50ZnlQdXNoIEZFSExFUjogJXMiICUgdHlwZShfbnR5X2UpLl9fbmFtZV9fLCBmbHVzaD1UcnVlKQojID09PT09IC9udGZ5UHVzaCA9PT09PQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6Cg==", "ntfy": "IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoiIiJudGZ5LUthY2hlbC4gU3RhbmRhcmQgYXVzLiBWZXJzYW5kIGltIEhpbnRlcmdydW5kLCBUZXN0cyBvaG5lIE5ldHouIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3FsaXRlMwppbXBvcnQgdGhyZWFkaW5nCmltcG9ydCB0aW1lCmltcG9ydCB1cmxsaWIucGFyc2UKaW1wb3J0IHVybGxpYi5yZXF1ZXN0CgpEQl9OQU1FID0gImxhZ2V6ZW50cnVtLmRiIgpTT1VSQ0VTID0gKCJkd2QiLCAidXN2IiwgInBpbm5lYmVyZyIsICJkaWVuc3QiKQpERUZBVUxUUyA9IHsKICAgICJlbmFibGVkIjogIjAiLCAic2VydmVyIjogImh0dHBzOi8vbnRmeS5zaCIsICJ0b3BpYyI6ICIiLCAiZ2FwX3MiOiAiMzAwIiwKICAgICJzcmNfZHdkIjogIjAiLCAic3JjX3VzdiI6ICIwIiwgInNyY19waW5uZWJlcmciOiAiMCIsICJzcmNfZGllbnN0IjogIjAiLAp9CgoKZGVmIF9jb24ocGF0aCk6CiAgICBjb24gPSBzcWxpdGUzLmNvbm5lY3QocGF0aCwgdGltZW91dD01KQogICAgbW9kZSA9IGNvbi5leGVjdXRlKCJQUkFHTUEgam91cm5hbF9tb2RlPVdBTCIpLmZldGNob25lKCkKICAgIGlmIG1vZGUgaXMgTm9uZSBvciBzdHIobW9kZVswXSkubG93ZXIoKSAhPSAid2FsIjoKICAgICAgICBjb24uY2xvc2UoKQogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigid2FsIikKICAgIGNvbi5leGVjdXRlKCJQUkFHTUEgc3luY2hyb25vdXM9Tk9STUFMIikKICAgIGNvbi5leGVjdXRlKCJDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyBudGZ5X2NmZyAoayBURVhUIFBSSU1BUlkgS0VZLCB2IFRFWFQpIikKICAgIGNvbi5leGVjdXRlKCJDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyBudGZ5X3NlbnQgKHNyYyBURVhUIFBSSU1BUlkgS0VZLCB0cyBJTlRFR0VSLCBzaWcgVEVYVCkiKQogICAgcmV0dXJuIGNvbgoKCmRlZiBsb2FkKHBhdGgpOgogICAgY2ZnID0gZGljdChERUZBVUxUUykKICAgIHRyeToKICAgICAgICBjb24gPSBfY29uKHBhdGgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHJldHVybiBjZmcKICAgIHRyeToKICAgICAgICBmb3IgaywgdiBpbiBjb24uZXhlY3V0ZSgiU0VMRUNUIGssIHYgRlJPTSBudGZ5X2NmZyIpOgogICAgICAgICAgICBpZiBrIGluIGNmZyBhbmQgdiBpcyBub3QgTm9uZToKICAgICAgICAgICAgICAgIGNmZ1trXSA9IHN0cih2KVs6MjAwXQogICAgZmluYWxseToKICAgICAgICBjb24uY2xvc2UoKQogICAgcmV0dXJuIGNmZwoKCmRlZiBzYXZlKHBhdGgsIGNmZyk6CiAgICBjbGVhbiA9IGRpY3QoREVGQVVMVFMpCiAgICBmb3IgayBpbiBERUZBVUxUUzoKICAgICAgICBpZiBrIGluIGNmZyBhbmQgY2ZnW2tdIGlzIG5vdCBOb25lOgogICAgICAgICAgICBjbGVhbltrXSA9IHN0cihjZmdba10pWzoyMDBdCiAgICBpZiBjbGVhblsic2VydmVyIl0gYW5kIG5vdCBjbGVhblsic2VydmVyIl0uc3RhcnRzd2l0aCgiaHR0cHM6Ly8iKToKICAgICAgICBjbGVhblsic2VydmVyIl0gPSBERUZBVUxUU1sic2VydmVyIl0KICAgIHRyeToKICAgICAgICBjbGVhblsiZ2FwX3MiXSA9IHN0cihtYXgoMzAsIG1pbig4NjQwMCwgaW50KGNsZWFuWyJnYXBfcyJdKSkpKQogICAgZXhjZXB0IChUeXBlRXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAgIGNsZWFuWyJnYXBfcyJdID0gREVGQVVMVFNbImdhcF9zIl0KICAgIGZvciBrIGluICgiZW5hYmxlZCIsKSArIHR1cGxlKCJzcmNfIiArIHMgZm9yIHMgaW4gU09VUkNFUyk6CiAgICAgICAgY2xlYW5ba10gPSAiMSIgaWYgY2xlYW5ba10gaW4gKCIxIiwgInRydWUiLCAiVHJ1ZSIsIFRydWUpIGVsc2UgIjAiCiAgICBjb24gPSBfY29uKHBhdGgpCiAgICB0cnk6CiAgICAgICAgZm9yIGssIHYgaW4gY2xlYW4uaXRlbXMoKToKICAgICAgICAgICAgY29uLmV4ZWN1dGUoIklOU0VSVCBJTlRPIG50ZnlfY2ZnIChrLCB2KSBWQUxVRVMgKD8sID8pIE9OIENPTkZMSUNUKGspIERPIFVQREFURSBTRVQgdj1leGNsdWRlZC52IiwgKGssIHYpKQogICAgICAgIGNvbi5jb21taXQoKQogICAgZmluYWxseToKICAgICAgICBjb24uY2xvc2UoKQogICAgcmV0dXJuIGNsZWFuCgoKZGVmIF9sYXN0KGNvbiwgc3JjKToKICAgIHJvdyA9IGNvbi5leGVjdXRlKCJTRUxFQ1QgdHMsIHNpZyBGUk9NIG50Znlfc2VudCBXSEVSRSBzcmM9PyIsIChzcmMsKSkuZmV0Y2hvbmUoKQogICAgcmV0dXJuICgwLCAiIikgaWYgcm93IGlzIE5vbmUgZWxzZSAoaW50KHJvd1swXSBvciAwKSwgcm93WzFdIG9yICIiKQoKCmRlZiBjb25zaWRlcihwYXRoLCBzcmMsIHRleHQsIG5vdz1Ob25lKToKICAgICIiIlRydWUsIHdlbm4gZWluZSBNZWxkdW5nIHJhdXMgZGFyZi4gU2NoYWx0ZXIgYXVzIG9kZXIgZ2xlaWNoZXIgVGV4dDogbmVpbi4iIiIKICAgIG5vdyA9IHRpbWUudGltZSgpIGlmIG5vdyBpcyBOb25lIGVsc2UgZmxvYXQobm93KQogICAgY2ZnID0gbG9hZChwYXRoKQogICAgaWYgY2ZnWyJlbmFibGVkIl0gIT0gIjEiOgogICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgc3JjICE9ICJ0ZXN0IiBhbmQgY2ZnLmdldCgic3JjXyIgKyBzcmMpICE9ICIxIjoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGlmIG5vdCBjZmdbInRvcGljIl06CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBzaWcgPSAiICIuam9pbihzdHIodGV4dCBvciAiIikuc3BsaXQoKSlbOjE4MF0KICAgIGlmIG5vdCBzaWc6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBjb24gPSBfY29uKHBhdGgpCiAgICB0cnk6CiAgICAgICAgdHMsIHByZXYgPSBfbGFzdChjb24sIHNyYykKICAgICAgICBpZiBzcmMgIT0gInRlc3QiIGFuZCAoc2lnID09IHByZXYgb3Igbm93IC0gdHMgPCBpbnQoY2ZnWyJnYXBfcyJdKSk6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgICAgIGNvbi5leGVjdXRlKCJJTlNFUlQgSU5UTyBudGZ5X3NlbnQgKHNyYywgdHMsIHNpZykgVkFMVUVTICg/LD8sPykgT04gQ09ORkxJQ1Qoc3JjKSBETyBVUERBVEUgU0VUIHRzPWV4Y2x1ZGVkLnRzLCBzaWc9ZXhjbHVkZWQuc2lnIiwKICAgICAgICAgICAgICAgICAgICAoc3JjLCBpbnQobm93KSwgc2lnKSkKICAgICAgICBjb24uY29tbWl0KCkKICAgIGZpbmFsbHk6CiAgICAgICAgY29uLmNsb3NlKCkKICAgIHJldHVybiBUcnVlCgoKZGVmIHBvc3Qoc2VydmVyLCB0b3BpYywgdGV4dCwgdGltZW91dD0zLCBvcGVuZXI9Tm9uZSk6CiAgICBvcGVuZXIgPSBvcGVuZXIgb3IgdXJsbGliLnJlcXVlc3QudXJsb3BlbgogICAgdXJsID0gc2VydmVyLnJzdHJpcCgiLyIpICsgIi8iICsgdXJsbGliLnBhcnNlLnF1b3RlKHN0cih0b3BpYyksIHNhZmU9IiIpCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KHVybCwgZGF0YT1zdHIodGV4dClbOjE4MF0uZW5jb2RlKCJ1dGYtOCIpLCBtZXRob2Q9IlBPU1QiKQogICAgb3BlbmVyKHJlcSwgdGltZW91dD10aW1lb3V0KS5yZWFkKDY0KQoKCmNsYXNzIEh1YjoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBwYXRoLCBvcGVuZXI9Tm9uZSk6CiAgICAgICAgc2VsZi5wYXRoID0gcGF0aAogICAgICAgIHNlbGYub3BlbmVyID0gb3BlbmVyCiAgICAgICAgc2VsZi5xID0gW10KICAgICAgICBzZWxmLmxvY2sgPSB0aHJlYWRpbmcuTG9jaygpCiAgICAgICAgc2VsZi5lcnJvcnMgPSAwCgogICAgZGVmIHB1c2goc2VsZiwgc3JjLCB0ZXh0LCBub3c9Tm9uZSk6CiAgICAgICAgaWYgbm90IGNvbnNpZGVyKHNlbGYucGF0aCwgc3JjLCB0ZXh0LCBub3cpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgc2VsZi5xLmFwcGVuZCgoc3JjLCAiICIuam9pbihzdHIodGV4dCkuc3BsaXQoKSlbOjE4MF0pKQogICAgICAgIHJldHVybiBUcnVlCgogICAgZGVmIGZsdXNoKHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5sb2NrOgogICAgICAgICAgICBiYXRjaCwgc2VsZi5xID0gc2VsZi5xLCBbXQogICAgICAgIGNmZyA9IGxvYWQoc2VsZi5wYXRoKQogICAgICAgIGZvciBfc3JjLCB0ZXh0IGluIGJhdGNoOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBwb3N0KGNmZ1sic2VydmVyIl0sIGNmZ1sidG9waWMiXSwgdGV4dCwgb3BlbmVyPXNlbGYub3BlbmVyKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgc2VsZi5lcnJvcnMgKz0gMQoKCmRlZiBzZWxmdGVzdCgpOgogICAgaW1wb3J0IHRlbXBmaWxlCiAgICBkID0gdGVtcGZpbGUubWtkdGVtcChwcmVmaXg9Im50ZnktIikKICAgIHRyeToKICAgICAgICBkYiA9IG9zLnBhdGguam9pbihkLCBEQl9OQU1FKQogICAgICAgIGNmZyA9IGxvYWQoZGIpCiAgICAgICAgYXNzZXJ0IGNmZ1siZW5hYmxlZCJdID09ICIwIiBhbmQgY2ZnWyJzZXJ2ZXIiXSA9PSAiaHR0cHM6Ly9udGZ5LnNoIgogICAgICAgIGFzc2VydCBjb25zaWRlcihkYiwgImR3ZCIsICJTdHVybSIpIGlzIEZhbHNlCiAgICAgICAgc2F2ZShkYiwgeyJlbmFibGVkIjogIjEiLCAidG9waWMiOiAibGFnZSIsICJzcmNfZHdkIjogIjEiLCAiZ2FwX3MiOiAiMzAwIiwgInNlcnZlciI6ICJodHRwOi8vYm9lc2UifSkKICAgICAgICBhc3NlcnQgbG9hZChkYilbInNlcnZlciJdID09ICJodHRwczovL250Znkuc2giCiAgICAgICAgYXNzZXJ0IGNvbnNpZGVyKGRiLCAiZHdkIiwgIlN0dXJtIiwgMTAwMCkgaXMgVHJ1ZQogICAgICAgIGFzc2VydCBjb25zaWRlcihkYiwgImR3ZCIsICJTdHVybSIsIDEwMDEpIGlzIEZhbHNlCiAgICAgICAgYXNzZXJ0IGNvbnNpZGVyKGRiLCAiZHdkIiwgIkhhZ2VsIiwgMTIwMCkgaXMgRmFsc2UKICAgICAgICBhc3NlcnQgY29uc2lkZXIoZGIsICJkd2QiLCAiSGFnZWwiLCAxNDAwKSBpcyBUcnVlCiAgICAgICAgYXNzZXJ0IGNvbnNpZGVyKGRiLCAidXN2IiwgIkFra3UiLCAxNDAwKSBpcyBGYWxzZQogICAgICAgIHNlbnQgPSBbXQogICAgICAgIGh1YiA9IEh1YihkYiwgb3BlbmVyPWxhbWJkYSByZXEsIHRpbWVvdXQ9Mzogc2VudC5hcHBlbmQoKHJlcS5mdWxsX3VybCwgdGltZW91dCkpIG9yIF9GYWtlKCkpCiAgICAgICAgYXNzZXJ0IGh1Yi5wdXNoKCJ0ZXN0IiwgInBpbmciLCAyMDAwKSBpcyBUcnVlCiAgICAgICAgaHViLmZsdXNoKCkKICAgICAgICBhc3NlcnQgc2VudCBhbmQgc2VudFswXVswXS5lbmRzd2l0aCgiL2xhZ2UiKSBhbmQgc2VudFswXVsxXSA9PSAzIGFuZCBodWIuZXJyb3JzID09IDAKICAgICAgICBodWIub3BlbmVyID0gbGFtYmRhIHJlcSwgdGltZW91dD0zOiAoXyBmb3IgXyBpbiAoKSkudGhyb3coT1NFcnJvcigib2ZmbGluZSIpKQogICAgICAgIGFzc2VydCBodWIucHVzaCgidGVzdCIsICJub2NobWFsIiwgMjAwMSkgaXMgVHJ1ZQogICAgICAgIGh1Yi5mbHVzaCgpCiAgICAgICAgYXNzZXJ0IGh1Yi5lcnJvcnMgPT0gMQogICAgICAgIGNvbiA9IHNxbGl0ZTMuY29ubmVjdChkYikKICAgICAgICBhc3NlcnQgc3RyKGNvbi5leGVjdXRlKCJQUkFHTUEgam91cm5hbF9tb2RlIikuZmV0Y2hvbmUoKVswXSkubG93ZXIoKSA9PSAid2FsIgogICAgICAgIGNvbi5jbG9zZSgpCiAgICBmaW5hbGx5OgogICAgICAgIGltcG9ydCBzaHV0aWwKICAgICAgICBzaHV0aWwucm10cmVlKGQsIGlnbm9yZV9lcnJvcnM9VHJ1ZSkKICAgIHJldHVybiAibnRmeVB1c2ggb2sgKGF1cywgV0FMLCBBYnN0YW5kLCBrZWluIGh0dHAtU2VydmVyLCBOZXR6ZmVobGVyIGJsZWlidCBpbSBaYWVobGVyKSIKCgpjbGFzcyBfRmFrZToKICAgIGRlZiByZWFkKHNlbGYsIG4pOgogICAgICAgIHJldHVybiBiIm9rIgoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBwcmludChzZWxmdGVzdCgpKQo="}

if __name__ == "__main__":
    sys.exit(main(sys.argv))
