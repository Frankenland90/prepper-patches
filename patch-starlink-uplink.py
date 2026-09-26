#!/usr/bin/env python3
"""Starlink via ASN/ISP (nicht Speed) + Download last_download-Fix. Idempotent (# starlinkUplink)."""
from pathlib import Path
import shutil
import sys
from datetime import datetime

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

MARKER = "# starlinkUplink"
if MARKER in src:
    print("already patched (starlinkUplink) — nichts geändert.")
    sys.exit(0)

if "def fetch_public_ip(" not in src:
    raise SystemExit("STOP: def fetch_public_ip() fehlt")
if "Verbindungstyp: Offline / Starlink / VDSL (über Speed)" not in src:
    raise SystemExit("STOP: Speed-Heuristik-Anker fehlt")

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
bak = PATH.with_name(f"dashboard.py.bak-starlink-{stamp}")
shutil.copy2(PATH, bak)
print(f"Backup: {bak}")


def must_replace(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"STOP {label}: Anker {n}x gefunden (erwartet 1). Backup bleibt: {bak}")
    return text.replace(old, new, 1)


OLD_DL = '''def fetch_download_mbps():
    """Kurzer Download-Test, Ergebnis in Mbit/s."""
    try:
        url = "https://speed.cloudflare.com/__down?bytes=2000000"  # 2 MB
        t0 = time.time()
        r = requests.get(url, timeout=12, stream=True)
        total = 0
        for chunk in r.iter_content(chunk_size=65536):
            total += len(chunk)
        dt = time.time() - t0
        if dt < 0.05:
            return None
        mbps = (total * 8) / (dt * 1_000_000)
        return round(mbps, 1)
    except Exception as e:
        print("Speed-Test Fehler:", e)
        return None'''

NEW_DL = '''def fetch_download_mbps():
    """Kurzer Download-Test, Ergebnis in Mbit/s. # starlinkUplink"""
    global last_download
    try:
        url = "https://speed.cloudflare.com/__down?bytes=2000000"  # 2 MB
        t0 = time.time()
        r = requests.get(url, timeout=12, stream=True)
        total = 0
        for chunk in r.iter_content(chunk_size=65536):
            total += len(chunk)
        dt = time.time() - t0
        if dt < 0.05:
            return None
        mbps = round((total * 8) / (dt * 1_000_000), 1)
        try:
            last_download = {"mbps": mbps, "at": now_str()}
        except Exception:
            last_download = {"mbps": mbps, "at": None}
        return mbps
    except Exception as e:
        print("Speed-Test Fehler:", e)
        return None'''

src = must_replace(src, OLD_DL, NEW_DL, "fetch_download_mbps")

OLD_IP = '''def fetch_public_ip():
    try:
        return requests.get("https://api.ipify.org", timeout=5).text.strip()
    except:
        return None'''

NEW_IP = '''def fetch_public_ip():
    try:
        return requests.get("https://api.ipify.org", timeout=5).text.strip()
    except:
        return None


def classify_uplink(public_ip, ping_ms=None):
    """Pfad: Festnetz vs Starlink-Ausfallschutz via ASN/ISP (nicht Speed). # starlinkUplink"""
    if not public_ip:
        return {
            "conn_type": "Offline",
            "conn_icon": "🔴",
            "path": "offline",
            "isp": None,
            "org": None,
            "as": None,
            "hint": None,
        }
    isp = org = asn = ""
    try:
        r = requests.get(
            "http://ip-api.com/json/%s?fields=status,message,isp,org,as,query" % public_ip,
            timeout=4,
        )
        if r.status_code == 200:
            d = r.json() or {}
            if d.get("status") == "success" or d.get("isp") or d.get("as"):
                isp = str(d.get("isp") or "")
                org = str(d.get("org") or "")
                asn = str(d.get("as") or "")
    except Exception as e:
        print("uplink classify:", e)
    blob = (" ".join([isp, org, asn])).lower()
    as_num = ""
    for part in asn.replace(",", " ").split():
        if part.upper().startswith("AS") and part[2:].isdigit():
            as_num = part.upper()
            break
    is_starlink = (
        as_num == "AS14593"
        or "starlink" in blob
        or "spacex" in blob
    )
    if is_starlink:
        return {
            "conn_type": "Starlink · Ausfallschutz",
            "conn_icon": "🛰️",
            "path": "starlink",
            "isp": isp or "Starlink",
            "org": org or None,
            "as": asn or "AS14593",
            "hint": "Ausfallschutz aktiv",
        }
    label = None
    for key, nice in (
        ("telekom", "Festnetz · Telekom"),
        ("vodafone", "Festnetz · Vodafone"),
        ("o2", "Festnetz · O2"),
        ("1&1", "Festnetz · 1&1"),
        ("1und1", "Festnetz · 1&1"),
        ("unitymedia", "Festnetz · Vodafone"),
        ("congstar", "Festnetz · Congstar"),
        ("deutsche telekom", "Festnetz · Telekom"),
    ):
        if key in blob:
            label = nice
            break
    if not label and isp:
        label = ("Festnetz · " + isp)[:32]
    if not label:
        label = "Festnetz"
    hint = None
    try:
        if ping_ms is not None and float(ping_ms) >= 40:
            hint = "hohe Latenz — Pfad prüfen"
    except Exception:
        pass
    return {
        "conn_type": label,
        "conn_icon": "🔌",
        "path": "landline",
        "isp": isp or None,
        "org": org or None,
        "as": asn or None,
        "hint": hint,
    }
'''

src = must_replace(src, OLD_IP, NEW_IP, "fetch_public_ip+classify")

OLD_CONN = '''    # Verbindungstyp: Offline / Starlink / VDSL (über Speed)
    download_mbps = fetch_download_mbps() if internet_ok else None
    if not internet_ok:
        conn_type, conn_icon = "Offline", "🔴"
    elif download_mbps is not None and download_mbps >= 75:
        conn_type, conn_icon = "Starlink", "🛰️"
    else:
        conn_type, conn_icon = "VDSL / DSL", "🔌"'''

NEW_CONN = '''    # Verbindungstyp: Offline / Starlink-Ausfallschutz / Festnetz (ASN/ISP) # starlinkUplink
    download_mbps = fetch_download_mbps() if internet_ok else None
    if not internet_ok:
        _up = {"conn_type": "Offline", "conn_icon": "🔴", "path": "offline", "isp": None, "org": None, "as": None, "hint": None}
    else:
        _up = classify_uplink(public_ip, ping)
    conn_type, conn_icon = _up["conn_type"], _up["conn_icon"]
    uplink_path, uplink_isp, uplink_as = _up.get("path"), _up.get("isp"), _up.get("as")
    uplink_hint = _up.get("hint")'''

src = must_replace(src, OLD_CONN, NEW_CONN, "update_all conn_type")

OLD_DS_CONN = '''        "conn_type": conn_type,
        "conn_icon": conn_icon,
        "download_mbps": download_mbps,'''

NEW_DS_CONN = '''        "conn_type": conn_type,
        "conn_icon": conn_icon,
        "uplink_path": uplink_path,
        "uplink_isp": uplink_isp,
        "uplink_as": uplink_as,
        "uplink_hint": uplink_hint,
        "download_mbps": download_mbps,
        "download": download_mbps,
        "download_at": (last_download.get("at") if isinstance(last_download, dict) else None),'''

src = must_replace(src, OLD_DS_CONN, NEW_DS_CONN, "data_store uplink fields")

OLD_DUP = '''        "download": fetch_download_mbps() if "fetch_download_mbps" in dir() else None,'''
if OLD_DUP in src:
    src = must_replace(
        src,
        OLD_DUP,
        '''        # download already set from download_mbps (starlinkUplink)
''',
        "remove duplicate download fetch",
    )

OLD_PI = '''    conn_type, conn_icon = "Internet", "🌐"
    try:
        if public_ip:
            r = requests.get(
                "http://ip-api.com/json/%s?fields=isp,org,as" % public_ip,
                timeout=4,
            )
            if r.status_code == 200:
                d = r.json()
                isp = ((d.get("isp") or "") + " " + (d.get("org") or "")).lower()
                if "starlink" in isp or "spacex" in isp:
                    conn_type, conn_icon = "Starlink", "🛰️"
                elif any(x in isp for x in ("telekom", "vodafone", "o2", "1&1", "unitymedia", "congstar")):
                    conn_type, conn_icon = "VDSL / DSL", "📡"
                elif d.get("isp"):
                    conn_type = str(d.get("isp"))[:28]
    except Exception:
        pass'''

NEW_PI = '''    # Einheitliche Pfad-Erkennung (ASN/ISP) # starlinkUplink
    if not online:
        _up = {"conn_type": "Offline", "conn_icon": "🔴", "path": "offline", "isp": None, "as": None, "hint": None}
    else:
        _up = classify_uplink(public_ip, ping)
    conn_type, conn_icon = _up["conn_type"], _up["conn_icon"]
    if _up.get("path") == "landline" and data_store.get("uplink_path") == "starlink":
        conn_type = data_store.get("conn_type") or conn_type
        conn_icon = data_store.get("conn_icon") or conn_icon'''

src = must_replace(src, OLD_PI, NEW_PI, "/pi classify")

OLD_API = '''@app.route("/api/download_test")
def api_download_test():
    global last_download
    mbps = fetch_download_mbps()
    data_store["download"] = mbps
    data_store["download_at"] = last_download.get("at") if isinstance(last_download, dict) else now_str()
    return jsonify({
        "ok": mbps is not None,
        "mbps": mbps,
        "at": data_store.get("download_at"),
    })'''

NEW_API = '''@app.route("/api/download_test")
def api_download_test():
    global last_download
    mbps = fetch_download_mbps()  # schreibt last_download # starlinkUplink
    data_store["download"] = mbps
    data_store["download_mbps"] = mbps
    at = None
    if isinstance(last_download, dict):
        at = last_download.get("at")
    if not at:
        at = now_str()
        last_download = {"mbps": mbps, "at": at}
    data_store["download_at"] = at
    return jsonify({
        "ok": mbps is not None,
        "mbps": mbps,
        "at": at,
    })'''

src = must_replace(src, OLD_API, NEW_API, "api_download_test")

OLD_HINT = "Starlink → andere IP + oft höhere Latenz · Download nur periodisch gemessen"
NEW_HINT = "Starlink = Ausfallschutz (ASN/ISP) · Download nur periodisch / manuell"
if OLD_HINT in src:
    src = src.replace(OLD_HINT, NEW_HINT)
else:
    print("WARN: Hinweistext-Anker nicht gefunden — UI-Hinweis unverändert")

PATH.write_text(src, encoding="utf-8")
print("OK patched starlinkUplink")
print("  classify_uplink defs:", src.count("def classify_uplink"))
print("  marker count:", src.count(MARKER))
