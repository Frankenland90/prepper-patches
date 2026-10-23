#!/bin/bash
set -euo pipefail
# sysBoot: Start ohne Warten + Watchdog/Health ruhiger + SSD/SD-Kacheln + Clone v2 + meshClean + Journal dauerhaft.
#  P1 bootStart: Dashboard lauscht sofort (erstes Voll-Update im Hintergrund, Seiten zeigen 'Dashboard startet'), threaded=True,
#     lageDB-Abgleich aus dem Anfragepfad, langsame Anfragen > 3 s ins Journal, /api/sysboot/status;
#     watchdog.py: 15 s Zeitlimit, Neustart erst nach 3 Fehlschlaegen in Folge, nie in den ersten 10 min nach Start, Nachpruefung bis 6 min;
#     health_check.py: wartet, bis das Dashboard 10 min laeuft; Dashboard-Einheit Wants/After network-online.target.
#  P2 diskTiles2: /pi 'SSD · Master' (Boot-Ampel, Reihenfolge, SMART auch -d sat, Temp, Stunden, Verschleiss, Belegung, Schreiblast mit SSD-Grenzen,
#     Fehler, Alter letzter Clone, Quittieren) + 'SD · Fallback' (Clone-Knopf mit zweiter Bestaetigung am Server, Fortschritt + ETA, Ergebnis); Sicherung bleibt letzte Kachel.
#  Clone v2 (/usr/local/bin/prepper-clone-ssd-to-sd): nur auf Knopfdruck, Sperren, sqlite-Sicherung, Fortschritt, Fehler-Verlauf. KEIN automatischer Klon.
#  P3 meshClean: mesh-ping-reply* archivieren, bleibt maskiert, mesh_hang_watchdog ping_svc None. Journal: Storage=persistent, SystemMaxUse=200M.
# Sendet nichts ins Mesh. Neustart nur prepper-dashboard und systemd-journald.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
WDF="$DASH_DIR/watchdog.py"
HCF="$DASH_DIR/health_check.py"
MHF="$DASH_DIR/mesh_hang_watchdog.py"
LZ="$DASH_DIR/lagezentrum.db"
CLONE="/usr/local/bin/prepper-clone-ssd-to-sd"
DDROP="/etc/systemd/system/prepper-dashboard.service.d/zz-sysboot.conf"
JDROP="/etc/systemd/journald.conf.d/zz-prepper-persist.conf"
SMRULE="/etc/sudoers.d/zz-prepper-sysboot-smart"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sysboot-apply
KEEP_LAST=3
KNOWN_D16="1c0b6b2db92f802f"     # dashboard.py vor sysBoot
KNOWN_D16N="eb4ce30b1f550f1d"     # dashboard.py nach sysBoot
KNOWN_WD16="bcdd177b7f8b2232"    # watchdog.py vor sysBoot (funkHarden3)
KNOWN_WD16N="dd03e22d59732e61"
KNOWN_HC16="ac975b99c20a70bd"    # health_check.py vor sysBoot
KNOWN_HC16N="cc3949f1896ebbf3"
KNOWN_MH16="ccc2e2faddb8b53b"    # mesh_hang_watchdog.py vor sysBoot
KNOWN_MH16N="1afa8becde24bc89"
KNOWN_CL16N="dab07956cec4c37c"   # prepper-clone-ssd-to-sd v2
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== sysBoot apply (Start ohne Warten, Watchdog 3x/15 s/10 min Schutz, SSD-/SD-Kacheln, Clone v2 nur auf Knopfdruck, meshClean, Journal dauerhaft), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/src"
EXPECT_PF="25fee5096263682e66a04c115f6d72b2e724baed91cc768e208d49ceed9d689f"
cat > "$W/src/patch-sysboot.py" << 'SBP_EOF'
#!/usr/bin/env python3
"""sysBoot Patcher fuer dashboard.py: patch-sysboot.py BASIS ZIEL BLOCKDIR  (schreibt ZIEL; rc 0 ok, 3 = Stelle fehlt)."""
import ast
import os
import sys

M_MAIN = "# ===== sysBoot: Start ohne Warten"
M_DISK0 = "# ===== diskTiles: SSD-Master mit SMART + SD-Fallback mit Historie =====\n"
M_DISK1 = "# ===== /diskTiles =====\n"
M_DISK2 = "# ===== diskTiles2 (sysBoot):"


def one(s, a, b, what):
    n = s.count(a)
    if n != 1:
        raise SystemExit("STELLE %s: %d Treffer (erwartet 1)" % (what, n))
    return s.replace(a, b)


def main(src, dst, bdir):
    s = open(src, encoding="utf-8").read()
    rd = lambda n: open(os.path.join(bdir, n), encoding="utf-8").read()
    if M_MAIN in s and M_DISK2 in s and "# ===== sysBoot lzKick:" in s:
        open(dst, "w", encoding="utf-8").write(s)
        print("sysBoot schon drin")
        return 0
    if M_MAIN in s or M_DISK2 in s or "# ===== sysBoot lzKick:" in s:
        raise SystemExit("STELLE: sysBoot nur teilweise vorhanden")
    # 1) lageDB: Abgleich aus dem Anfragepfad
    s = one(s, "\n\ndef _lz_after(resp):\n", rd("sb_lz_block.py") + "\n\ndef _lz_after(resp):\n", "lz_after")
    s = one(s, "            _lz_sync(_LZ_AFTER_S)\n", "            _lz_kick(_LZ_AFTER_S)  # sysBoot\n", "lz_after_sync")
    s = one(s, "        _lz_sync(_LZ_API_S, ctx)\n", "        _lz_kick(_LZ_API_S, ctx)  # sysBoot\n", "lz_api_live")
    s = one(s, "        _lz_sync(_LZ_API_S)\n", "        _lz_kick(_LZ_API_S)  # sysBoot\n", "lz_api_map")
    s = one(s, "        ctx = _lz_ctx()\n        _lz_sync(5, ctx)\n        br = ctx.get(\"br24\")\n",
            "        ctx = _lz_ctx()\n        _lz_kick(5, ctx)  # sysBoot\n        br = ctx.get(\"br24\")\n", "t4_status")
    # 2) diskTiles -> diskTiles2
    i = s.find(M_DISK0)
    j = s.find(M_DISK1, i)
    if i < 0 or j < 0 or s.count(M_DISK0) != 1 or s.count(M_DISK1) != 1:
        raise SystemExit("STELLE diskTiles: Block nicht eindeutig")
    old = s[i:j + len(M_DISK1)]
    for k in ("def _dt_cards():", "def _dt_after(resp):", 'app.after_request(_dt_after)', 'SD-Karte · Fallback'):
        if k not in old:
            raise SystemExit("STELLE diskTiles: %s fehlt" % k)
    s = s[:i] + rd("sb_disk_block.py") + s[j + len(M_DISK1):]
    # 3) Systemstatus-Kachel: Boot-Zeile
    s = one(s, "    <div>Festplatte</div>\n    <div><b>{% if sys.disk is defined and sys.disk is not none %}{{ sys.disk }} %{% else %}–{% endif %}</b></div>\n",
            "    <div>Festplatte</div>\n    <div><b>{% if sys.disk is defined and sys.disk is not none %}{{ sys.disk }} %{% else %}–{% endif %}</b></div>\n"
            "    <div>Boot</div>\n    <div><b style=\"color:{{ sb_boot.color if sb_boot is defined and sb_boot else '#94a3b8' }}\">"
            "{{ sb_boot.txt if sb_boot is defined and sb_boot else '–' }}</b></div>\n", "PAGE_PI Festplatte")
    s = one(s, '    ctx["backups"] = list_prepper_backups()\n',
            '    try:\n        ctx["sb_boot"] = globals()["_dt_boot_ctx"]()  # sysBoot: Boot SSD gruen / SD gelb\n    except Exception:\n        ctx["sb_boot"] = None\n'
            '    ctx["backups"] = list_prepper_backups()\n', "page_pi ctx")
    # 4) Start ohne Warten
    s = one(s, '\nif __name__ == "__main__":\n    # sourceWatch final\n', "\n" + rd("sb_main_block.py") + 'if __name__ == "__main__":\n    # sourceWatch final\n', "main_anchor")
    s = one(s, "    update_all()  # einmal beim Start\n    threading.Thread(target=background_loop, daemon=True).start()\n"
               "    threading.Thread(target=weather_mesh_loop, daemon=True).start()\n    threading.Thread(target=freq_loop, daemon=True).start()\n",
            "    _sb_start_updates()  # sysBoot: Server lauscht sofort; erstes Voll-Update, dann background/weather_mesh/freq im Hintergrund\n", "main_update_all")
    s = one(s, '    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False)\n',
            '    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False, threaded=True)  # sysBoot\n', "app_run")
    ast.parse(s)
    open(dst, "w", encoding="utf-8").write(s)
    print("sysBoot eingefuegt (lzKick 4 Stellen, diskTiles2, Boot-Zeile Systemstatus, Start ohne Warten, threaded)")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
SBP_EOF
EXPECT_BL="547fa2c15d460621008595b9c9bd6d4448ddb83d487cd48a7d61115653486775"
cat > "$W/src/sb_lz_block.py" << 'SBL_EOF'


# ===== sysBoot lzKick: lageDB-Abgleich nicht mehr in der Anfrage (Watchdog-GET / wartete sonst auf DB-Sperren bis 10 s), eigener Faden; ausserhalb von Anfragen wie bisher direkt =====
import threading as _lzk_thr
_LZK = {"ev": _lzk_thr.Event(), "min": _LZ_AFTER_S, "th": None, "n": 0, "t": 0.0, "err": None}


def _lzk_loop():
    while True:
        try:
            _LZK["ev"].wait(_LZ_AFTER_S)
            _LZK["ev"].clear()
            m = _LZK["min"]
            _LZK["min"] = _LZ_AFTER_S
            _lz_sync(m)
            _LZK["n"] += 1
            _LZK["t"] = _lz_time.time()
        except Exception as e:
            _LZK["err"] = str(e)[:120]
            print("lzKick:", e, flush=True)
            _lz_time.sleep(5)


def _lz_kick(min_s, ctx=None):
    """In einer Anfrage: Abgleich im Hintergrund anstossen (nie warten). Sonst (Faeden, Selbsttests): direkt wie bisher."""
    try:
        from flask import has_request_context as _lzk_hrc
        inreq = _lzk_hrc()
    except Exception:
        inreq = False
    if not inreq:
        return _lz_sync(min_s, ctx)
    try:
        if _LZK["th"] is None:
            _LZK["th"] = _lzk_thr.Thread(target=_lzk_loop, name="lzKick", daemon=True)
            _LZK["th"].start()
        _LZK["min"] = min(_LZK["min"], min_s)
        _LZK["ev"].set()
    except Exception as e:
        print("lzKick anstossen:", e, flush=True)
    return ctx
# ===== /sysBoot lzKick =====
SBL_EOF
EXPECT_BD="43fac05b47b7c3bd90fb5ada89bfb1d90fe4989194815a3e905ceae666cfa174"
cat > "$W/src/sb_disk_block.py" << 'SBD_EOF'
# ===== diskTiles2 (sysBoot): /pi 'SSD · Master' (Boot-Ampel SSD gruen/SD gelb + Boot-Reihenfolge, SMART -H (auch -d sat), Temp, Stunden, Verschleiss, Belegung, Schreiblast mit SSD-Grenzen, ext4/Kernel-Fehler, Alter letzter Clone, 'Quittieren & neu pruefen') + 'SD · Fallback' (Clone-Knopf mit zweiter Bestaetigung am Server, echter Fortschritt % + ETA, letztes Ergebnis inkl. Fehler, Sperren); Laufwerk dynamisch; SMART/Boot im Hintergrund (Seite wartet nie auf smartctl); Sicherung bleibt letzte Kachel; sendet nichts =====
import os as _dt_os, json as _dt_json, time as _dt_time, subprocess as _dt_sub, re as _dt_re, threading as _dt_thr, secrets as _dt_secrets
from datetime import datetime

CLONE_STATUS = "/home/fmg/prepper-dashboard/clone_status.json"
CLONE_SCRIPT = "/usr/local/bin/prepper-clone-ssd-to-sd"
CLONE_HIST = "/home/fmg/prepper-dashboard/clone_history.json"
_DT_BASE = _dt_os.path.dirname(_dt_os.path.abspath(__file__))
DT_SD_DEV = "mmcblk0"
DT_WRITE_Y, DT_WRITE_R = 80.0, 200.0          # GB/Tag: SSD-Grenzen (gelb / rot)
DT_TEMP_Y, DT_TEMP_R = 60, 70                 # °C
DT_DF_Y, DT_DF_R = 80, 90                     # % belegt
DT_CLONE_Y, DT_CLONE_R = 7 * 86400, 30 * 86400
DT_REFRESH_S = 600
DT_STALE_RUN_S = 3 * 3600
DT_TOKEN_S = 90
DT_COL = {"g": "#22c55e", "y": "#eab308", "r": "#ef4444", "n": "#64748b"}
_DT = {"disk": None, "disk_t": 0, "smart": None, "smart_t": 0, "boot": None, "boot_t": 0, "th": None, "lk": _dt_thr.Lock(), "tok": {}, "err": None,
       "fake": None}
_DT_BOOT_NAMES = {"1": "SD", "2": "Netz", "3": "RPIboot", "4": "USB", "5": "BCM-USB", "6": "NVMe", "7": "HTTP", "e": "Stopp", "f": "Neustart"}


def _fmt_date(iso):
    if not iso or iso == "?":
        return "–"
    try:
        clean = str(iso).split("+")[0].split("Z")[0]
        dt = datetime.fromisoformat(clean)
        return dt.strftime("%d.%m.%Y %H:%M")
    except Exception:
        return "–"


def _dt_iso_ts(iso):
    try:
        return datetime.fromisoformat(str(iso)).timestamp()
    except Exception:
        try:
            return _dt_time.mktime(datetime.fromisoformat(str(iso).split("+")[0]).timetuple())
        except Exception:
            return None


def _dt_esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _dt_num(x, nd=1):
    return ("%.*f" % (nd, x)).replace(".", ",") if isinstance(x, (int, float)) else "–"


def _dt_cmd(args, timeout=10):
    f = _DT.get("fake") or {}
    if "cmd" in f:
        return f["cmd"](args)
    try:
        p = _dt_sub.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout or "", p.stderr or ""
    except Exception as e:
        return 127, "", str(e)[:120]


def _dt_read(path, dflt=None):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except Exception:
        return dflt


def _dt_load(path, dflt):
    try:
        with open(path, encoding="utf-8") as f:
            return _dt_json.load(f)
    except Exception:
        return dflt


def _dt_takeover(path):
    """sdr_takeover.json robust wie prepper-sdr: fehlt = aus; nur "on": true (bool) = an; unlesbar (z. B. gerade geschrieben) -> 2. Versuch, dann 'unklar'.
    -> (zustand 'an'|'aus'|'unklar', seit-Text)"""
    if not _dt_os.path.exists(path):
        return "aus", ""
    for i in range(2):
        try:
            with open(path, encoding="utf-8") as f:
                d = _dt_json.load(f)
            if not isinstance(d, dict):
                return "aus", ""
            if d.get("on") is not True:
                return "aus", ""
            since = d.get("since")
            st = ""
            if isinstance(since, (int, float)) and since > 0:
                st = _dt_time.strftime("%d.%m. %H:%M", _dt_time.localtime(since))
            return "an", st
        except Exception:
            _dt_time.sleep(0.3)
    return "unklar", ""


def _dt_sys(p):
    return _dt_os.path.join((_DT.get("fake") or {}).get("sys", "/sys"), p)


# ---------------------------------------------------------------- Laufwerke / Boot (Hintergrund, zwischengespeichert)
def _dt_disk_info():
    """Root-Laufwerk dynamisch: findmnt / -> Partition -> Disk (lsblk PKNAME) -> Art SSD/SD/NVMe, Modell, Groesse, Anschluss."""
    d = {"src": None, "disk": None, "kind": "?", "model": None, "size": None, "tran": None, "boot_src": None}
    rc, out, _ = _dt_cmd(["findmnt", "-n", "-o", "SOURCE", "/"])
    src = out.strip().splitlines()[0].strip() if rc == 0 and out.strip() else ""
    d["src"] = src or None
    rc, out, _ = _dt_cmd(["findmnt", "-n", "-o", "SOURCE", "/boot/firmware"])
    d["boot_src"] = out.strip() or None if rc == 0 else None
    disk = None
    if src.startswith("/dev/"):
        rc, out, _ = _dt_cmd(["lsblk", "-no", "PKNAME", src])
        disk = out.strip().splitlines()[0].strip() if rc == 0 and out.strip() else None
        if not disk:
            m = _dt_re.match(r"^/dev/((?:mmcblk|nvme)\d+(?:n\d+)?)p\d+$", src) or _dt_re.match(r"^/dev/(sd[a-z]+)\d+$", src)
            disk = m.group(1) if m else None
    d["disk"] = disk
    if disk:
        rc, out, _ = _dt_cmd(["lsblk", "-J", "-b", "-d", "-o", "NAME,TRAN,MODEL,SIZE,ROTA", "/dev/" + disk])
        try:
            bd = (_dt_json.loads(out).get("blockdevices") or [{}])[0] if rc == 0 else {}
        except Exception:
            bd = {}
        d["model"] = (bd.get("model") or "").strip() or None
        d["tran"] = bd.get("tran")
        try:
            d["size"] = int(bd.get("size")) if bd.get("size") is not None else int(_dt_read(_dt_sys("block/%s/size" % disk), "0").strip()) * 512
        except Exception:
            d["size"] = None
        rota = str(bd.get("rota")).lower() in ("1", "true")
        d["kind"] = "SD" if disk.startswith("mmcblk") else ("NVMe" if disk.startswith("nvme") else ("HDD" if rota else "SSD"))
    return d


def _dt_boot_order():
    rc, out, _ = _dt_cmd(["vcgencmd", "bootloader_config"])
    m = _dt_re.search(r"^BOOT_ORDER=(0x[0-9a-fA-F]+)", out or "", _dt_re.M) if rc == 0 else None
    if not m:
        return {"raw": None, "txt": "unbekannt", "sd_after_usb": None}
    raw = m.group(1).lower()
    seq = [_DT_BOOT_NAMES.get(c, c) for c in reversed(raw[2:])]
    txt = " → ".join(seq)
    sd_ok = "USB" in seq and "SD" in seq and seq.index("USB") < seq.index("SD")
    return {"raw": raw, "txt": txt, "seq": seq, "sd_after_usb": sd_ok}


def _dt_smart_parse(out):
    r = {"health": None, "attrs": {}}
    m = _dt_re.search(r"self-assessment test result:\s*(\S+)", out) or _dt_re.search(r"SMART Health Status:\s*(\S+)", out)
    if m:
        r["health"] = m.group(1).upper().rstrip("!")
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 10 and p[0].isdigit():
            r["attrs"][p[1]] = {"value": p[3], "raw": p[9]}
    a = r["attrs"]

    def raw(*names):
        for n in names:
            if n in a:
                mm = _dt_re.match(r"^-?\d+", a[n]["raw"])
                if mm:
                    return int(mm.group(0))
        return None

    def val(*names):
        for n in names:
            if n in a and a[n]["value"].isdigit():
                return int(a[n]["value"])
        return None
    r["temp"] = raw("Temperature_Celsius", "Airflow_Temperature_Cel", "Temperature_Internal")
    r["hours"] = raw("Power_On_Hours")
    r["cycles"] = raw("Power_Cycle_Count")
    r["wear"] = val("Wear_Leveling_Count", "Percent_Lifetime_Remain", "SSD_Life_Left", "Media_Wearout_Indicator", "Remaining_Lifetime_Perc")
    r["reserve"] = val("Available_Reservd_Space")
    r["realloc"] = raw("Reallocated_Sector_Ct")
    r["pending"] = raw("Current_Pending_Sector")
    return r


def _dt_smart(dev):
    """sudo -n smartctl: erst -H -A, dann -d sat (USB-SATA-Bruecke ASM1153), zuletzt -A wie bisher."""
    last = "nicht lesbar"
    for args in (["-H", "-A", dev], ["-d", "sat", "-H", "-A", dev], ["-A", dev]):
        rc, out, err = _dt_cmd(["sudo", "-n", "smartctl"] + args, 20)
        if out and ("SMART" in out or "ID#" in out):
            r = _dt_smart_parse(out)
            if r["health"] or r["attrs"]:
                r["args"] = " ".join(args[:-1]) or "-A"
                r["ok"] = True
                return r
        last = (err or out or "rc %d" % rc).strip().splitlines()[-1][:100] if (err or out) else "rc %d" % rc
    return {"ok": False, "why": last, "health": None, "attrs": {}}


def _dt_refresh(force=False):
    now = _dt_time.time()
    if not _DT["lk"].acquire(False):
        return
    try:
        if force or now - _DT["disk_t"] >= DT_REFRESH_S or _DT["disk"] is None:
            try:
                _DT["disk"] = _dt_disk_info()
            except Exception as e:
                _DT["err"] = "Laufwerk: %s" % str(e)[:100]
            _DT["disk_t"] = now
        if force or now - _DT["smart_t"] >= DT_REFRESH_S or _DT["smart"] is None:
            dk = (_DT.get("disk") or {}).get("disk")
            try:
                _DT["smart"] = _dt_smart("/dev/" + dk) if dk and not dk.startswith("mmcblk") else {"ok": False, "why": "kein SATA/NVMe-Laufwerk", "attrs": {}}
            except Exception as e:
                _DT["smart"] = {"ok": False, "why": str(e)[:100], "attrs": {}}
            _DT["smart_t"] = now
        if force or now - _DT["boot_t"] >= 3600 or _DT["boot"] is None:
            try:
                _DT["boot"] = _dt_boot_order()
            except Exception as e:
                _DT["boot"] = {"raw": None, "txt": "unbekannt (%s)" % str(e)[:60], "sd_after_usb": None}
            _DT["boot_t"] = now
    finally:
        _DT["lk"].release()


def _dt_loop():
    _dt_time.sleep(3)
    while True:
        try:
            _dt_refresh()
        except Exception as e:
            print("diskTiles2 Hintergrund:", e, flush=True)
        _dt_time.sleep(60)


def _dt_ensure_thread():
    if _DT["th"] is None and not _DT.get("fake"):
        _DT["th"] = _dt_thr.Thread(target=_dt_loop, name="diskTiles2", daemon=True)
        _DT["th"].start()


# ---------------------------------------------------------------- SD-Karte / Clone
def _dt_sd_info():
    base = _dt_sys("block/%s" % DT_SD_DEV)
    if not _dt_os.path.isdir(base):
        return {"present": False}
    try:
        size = int((_dt_read(_dt_os.path.join(base, "size"), "0") or "0").strip()) * 512
    except Exception:
        size = None
    parts = {}
    for n in (1, 2):
        pn = "%sp%d" % (DT_SD_DEV, n)
        s = _dt_read(_dt_os.path.join(base, pn, "size"))
        parts[pn] = int(s.strip()) * 512 if s and s.strip().isdigit() else None
    mounts = {}
    for ln in (_dt_read((_DT.get("fake") or {}).get("mounts", "/proc/mounts"), "") or "").splitlines():
        p = ln.split()
        if len(p) >= 2 and p[0].startswith("/dev/%sp" % DT_SD_DEV):
            mounts.setdefault(p[0][5:], []).append(p[1].replace("\\040", " "))
    return {"present": True, "size": size, "parts": parts, "mounts": mounts}


def _dt_history():
    h = _dt_load(CLONE_HIST, [])
    return [x for x in h if isinstance(x, dict)] if isinstance(h, list) else []


def _dt_pid_alive(pid):
    try:
        return isinstance(pid, int) and pid > 0 and _dt_os.path.isdir("/proc/%d" % pid)
    except Exception:
        return False


def _dt_avg_dur(hist):
    ds = []
    for x in hist:
        if x.get("ok") is not True:
            continue
        if isinstance(x.get("duration_s"), (int, float)):
            ds.append(float(x["duration_s"]))
        else:
            m = _dt_re.match(r"^(\d+)m (\d+)s$", str(x.get("duration") or ""))
            if m:
                ds.append(int(m.group(1)) * 60 + int(m.group(2)))
    ds = ds[:5]
    return sum(ds) / len(ds) if ds else None


def _dt_clone_status():
    """clone_status.json + Erkennung haengender Laeufe + ETA. Alte (v1) Statusdateien bleiben lesbar."""
    cs = _dt_load(CLONE_STATUS, {"state": "idle", "progress": 0})
    cs = dict(cs) if isinstance(cs, dict) else {"state": "idle", "progress": 0}
    hist = _dt_history()
    now = _dt_time.time()
    if cs.get("state") == "running":
        st_t = _dt_iso_ts(cs.get("started"))
        el = (now - st_t) if st_t else None
        cs["elapsed_s"] = int(el) if el is not None else None
        dead = (cs.get("pid") and not _dt_pid_alive(cs.get("pid"))) or (not cs.get("pid") and el is not None and el > DT_STALE_RUN_S)
        if dead:
            cs["state"], cs["ok"], cs["stale"] = "error", False, True
            cs["why"] = "abgebrochen (Prozess weg)" if cs.get("pid") else "haengt seit %d h (kein Abschluss)" % int(el // 3600)
        elif not isinstance(cs.get("eta_s"), (int, float)):
            avg = _dt_avg_dur(hist)
            cs["eta_s"] = int(max(30, avg - el)) if avg and el is not None else None
    try:
        cs["progress"] = max(0, min(100, int(cs.get("progress") or 0)))
    except Exception:
        cs["progress"] = 0
    cs["history"] = hist[:10]
    last_ok = next((x for x in hist if x.get("ok") is True), None)
    t_ok = _dt_iso_ts(last_ok.get("finished")) if last_ok else None
    cs["last_ok_age_s"] = int(now - t_ok) if t_ok else None
    cs["block"] = _dt_clone_block(cs)
    return cs


def _dt_clone_block(cs=None):
    """Sperrgruende fuer den Knopf (Script prueft selbst noch einmal als root)."""
    why = []
    try:
        dk = _DT.get("disk") or {}
        if dk.get("kind") == "SD" or "mmcblk" in str(dk.get("src") or ""):
            why.append("System läuft von der SD-Karte – Klon SSD→SD nicht möglich")
        elif not dk.get("src"):
            why.append("Root-Laufwerk noch nicht erkannt")
        sd = _dt_sd_info()
        if not sd.get("present"):
            why.append("SD-Karte fehlt")
        elif not all((sd.get("parts") or {}).values()):
            why.append("SD-Partitionen fehlen")
        base = globals().get("_SDR_BASE") or _DT_BASE
        tk, tks = _dt_takeover(_dt_os.path.join(base, "sdr_takeover.json"))
        if tk == "an":
            why.append("Stick-2-Übernahme 5C aktiv%s (erst auf /funk zurücksetzen)" % ((" seit " + tks) if tks else ""))
        elif tk == "unklar":
            why.append("sdr_takeover.json unlesbar – Übernahme-Zustand unklar")
        g = _dt_load(_dt_os.path.join(base, "sdr_wd_gate.json"), {})
        if isinstance(g, dict) and g.get("alarm") is True and _dt_time.time() - float(g.get("t") or 0) <= 900:
            why.append("echter Alarm im Lagezentrum")
        if cs is not None and cs.get("state") == "running":
            why.append("Klon läuft gerade")
    except Exception as e:
        why.append("Prüfung fehlgeschlagen: %s" % str(e)[:80])
    return why


def _dt_start_clone():
    """-> (ok, text). Script selbst ueber sudo -n (Regel prepper-clone); v2 loest sich per systemd-run vom Dashboard."""
    try:
        p = _dt_sub.Popen(["sudo", "-n", CLONE_SCRIPT], stdout=_dt_sub.PIPE, stderr=_dt_sub.STDOUT, start_new_session=True, text=True)
        try:
            out, _ = p.communicate(timeout=25)
        except _dt_sub.TimeoutExpired:
            return True, "gestartet (läuft im Vordergrund)"
        out = (out or "").strip().splitlines()
        if p.returncode == 0:
            return True, (out[-1] if out else "gestartet")[:160]
        if p.returncode == 10:
            return False, (out[-1] if out else "gesperrt")[:200]
        return False, ("nicht gestartet (rc %d): %s" % (p.returncode, out[-1] if out else ""))[:200]
    except Exception as e:
        return False, "nicht gestartet: %s" % str(e)[:120]


def _dt_api_clone():
    """POST /api/clone/start: 1. Aufruf ohne token -> Rueckfrage + token (90 s); 2. Aufruf mit token -> Start."""
    from flask import jsonify, request
    try:
        try:
            body = request.get_json(silent=True) or {}
        except Exception:
            body = {}
        cs = _dt_clone_status()
        if cs["block"]:
            return jsonify({"ok": False, "why": cs["block"], "status": cs})
        now = _dt_time.time()
        for k in [k for k, v in _DT["tok"].items() if v < now]:
            _DT["tok"].pop(k, None)
        tok = str(body.get("token") or "") if isinstance(body, dict) else ""
        if not tok:
            t = _dt_secrets.token_hex(8)
            _DT["tok"] = {t: now + DT_TOKEN_S}
            sd = _dt_sd_info()
            return jsonify({"ok": False, "need_confirm": True, "token": t, "expires_s": DT_TOKEN_S,
                            "text": "Zweite Bestätigung: Die SD-Karte (%s GB) wird komplett gelöscht und neu von der SSD beschrieben. "
                                    "Dauer etwa %s min. Während des Klons gibt es keine SD-Rückfallebene. Jetzt starten?"
                                    % (_dt_num((sd.get("size") or 0) / 1e9), int(round((_dt_avg_dur(cs["history"]) or 1900) / 60)))})
        if tok not in _DT["tok"]:
            return jsonify({"ok": False, "why": ["Bestätigung abgelaufen – bitte noch einmal"]})
        _DT["tok"].pop(tok, None)
        ok, txt = _dt_start_clone()
        print("diskTiles2: Klon-Start %s: %s" % ("ok" if ok else "FEHLER", txt), flush=True)
        _dt_time.sleep(1.5)
        return jsonify({"ok": ok, "text": txt, "why": [] if ok else [txt], "status": _dt_clone_status()})
    except Exception as e:
        return jsonify({"ok": False, "why": ["Fehler: %s" % str(e)[:120]]})


def _dt_api_status():
    from flask import jsonify
    try:
        _dt_ensure_thread()
        return jsonify(_dt_clone_status())
    except Exception as e:
        return jsonify({"state": "unbekannt", "progress": 0, "error": str(e)[:120]})


def _dt_api_disk():
    from flask import jsonify
    try:
        _dt_ensure_thread()
        return jsonify(_dt_ssd_view())
    except Exception as e:
        return jsonify({"error": str(e)[:120]})


# ---------------------------------------------------------------- Ampeln
def _dt_worst(*cs):
    order = {"n": 0, "g": 1, "y": 2, "r": 3}
    return max(cs, key=lambda c: order.get(c, 0)) if cs else "n"


def _dt_age_txt(s):
    if s is None:
        return "–"
    s = int(s)
    if s < 3600:
        return "vor %d min" % max(1, s // 60)
    if s < 2 * 86400:
        return "vor %d h" % (s // 3600)
    return "vor %d Tagen" % (s // 86400)


def _dt_clone_age_col(age):
    if age is None:
        return "r"
    return "r" if age >= DT_CLONE_R else ("y" if age >= DT_CLONE_Y else "g")


def _dt_sdh():
    try:
        fn = globals().get("sdh_view")
        return fn() if callable(fn) else {}
    except Exception:
        return {}


def _dt_ssd_view():
    _dt_ensure_thread()
    dk = _DT.get("disk") or {}
    sm = _DT.get("smart") or {}
    bo = _DT.get("boot") or {}
    v = _dt_sdh() or {}
    rows, cols = [], []
    # Boot
    if not dk.get("src"):
        bcol, btxt = "n", "wird gelesen …"
    elif dk.get("kind") == "SD":
        bcol, btxt = "y", "SD-Karte (Rückfall!)"
    elif dk.get("kind") in (None, "?"):
        bcol, btxt = "n", "Laufwerk unbekannt (%s)" % (dk.get("src") or "?")
    else:
        bcol, btxt = "g", "%s (Master)" % (dk.get("kind") or "SSD")
    cols.append(bcol)
    rows.append(("Boot", btxt, bcol, "Root %s, /boot/firmware %s" % (dk.get("src") or "?", dk.get("boot_src") or "?")))
    if bo.get("raw"):
        ocol = "y" if bo.get("sd_after_usb") is False else "g"
        cols.append(ocol)
        rows.append(("Reihenfolge", bo.get("txt") or "?", ocol, "BOOT_ORDER %s%s" % (bo.get("raw"), " - SD steht nicht hinter USB: kein automatischer Rückfall" if ocol == "y" else " - Rückfall auf SD automatisch")))
    else:
        rows.append(("Reihenfolge", "unbekannt", "n", "vcgencmd bootloader_config nicht lesbar"))
    size = dk.get("size")
    rows.append(("Laufwerk", "%s · %s GB · %s" % (dk.get("model") or "?", _dt_num(size / 1e9, 0) if size else "?", (dk.get("tran") or "?").upper()), "n",
                 "%s %s, Root %s" % (dk.get("model") or "?", dk.get("disk") or "?", dk.get("src") or "?")))
    # SMART
    if sm.get("ok"):
        h = sm.get("health")
        hcol = "g" if h in ("PASSED", "OK") else ("r" if h else "y")
        t = sm.get("temp")
        tcol = "n" if t is None else ("r" if t >= DT_TEMP_R else ("y" if t >= DT_TEMP_Y else "g"))
        cols += [hcol, tcol]
        rows.append(("SMART", "%s · %s · %s h" % (h or "Health nicht lesbar", ("%d °C" % t) if t is not None else "Temp –",
                                                   sm.get("hours") if sm.get("hours") is not None else "–"), _dt_worst(hcol, tcol),
                     "smartctl %s" % sm.get("args", "")))
        wear = sm.get("wear")
        rl, pd = sm.get("realloc"), sm.get("pending")
        wcol = "n" if wear is None else ("r" if wear <= 10 else ("y" if wear <= 30 else "g"))
        rcol = "y" if (rl or 0) > 0 or (pd or 0) > 0 else "g"
        cols += [wcol, rcol]
        rows.append(("Verschleiß", "Rest %s · Realloc %s%s" % (("%d %%" % wear) if wear is not None else "–", "–" if rl is None else rl,
                                                              (" · Pending %s" % pd) if pd else ""),
                     _dt_worst(wcol, rcol), "Rest %s, Reserve %s, Realloc %s, Pending %s (Normwerte Wear_Leveling_Count/Percent_Lifetime_Remain, Available_Reservd_Space)" % (
                         ("%d %%" % wear) if wear is not None else "–", ("%d %%" % sm["reserve"]) if sm.get("reserve") is not None else "–",
                         "–" if rl is None else rl, "–" if pd is None else pd)))
    else:
        cols.append("y" if _DT.get("smart") is not None else "n")
        rows.append(("SMART", "nicht lesbar (%s)" % (sm.get("why") or "wird gelesen …") if _DT.get("smart") is not None else "wird gelesen …",
                     "y" if _DT.get("smart") is not None else "n", ""))
    # Belegung
    try:
        import shutil as _dt_shutil
        du = _dt_shutil.disk_usage("/")
        pct = du.used * 100.0 / du.total if du.total else 0
        dcol = "r" if pct >= DT_DF_R else ("y" if pct >= DT_DF_Y else "g")
        cols.append(dcol)
        rows.append(("Belegung", "%d %% · frei %s von %s GB" % (round(pct), _dt_num(du.free / 1e9, 0), _dt_num(du.total / 1e9, 0)), dcol, "gelb ab %d %%, rot ab %d %%" % (DT_DF_Y, DT_DF_R)))
    except Exception:
        pass
    # Schreiblast / Fehler aus sd_health.json (root-Timer prepper-sd-health)
    gbd = v.get("gb_day")
    wcol = "n" if not isinstance(gbd, (int, float)) else ("r" if gbd >= DT_WRITE_R else ("y" if gbd >= DT_WRITE_Y else "g"))
    cols.append(wcol)
    rows.append(("Schreiblast", "%s GB/Tag · ges. %s TB" % (_dt_num(gbd), _dt_num(v.get("written_tb"), 2)), wcol,
                 "SSD-Grenzen gelb ab %d, rot ab %d GB/Tag" % (DT_WRITE_Y, DT_WRITE_R)))
    e24, w24 = v.get("errors_24h"), v.get("warn_24h")
    eack = v.get("ext4_errors_since_ack")
    probe = v.get("probe_ok")
    ro = (v.get("root") or {}).get("ro")
    ecol = "n" if not v.get("ts") else ("r" if (e24 or 0) > 0 or (eack or 0) > 0 or probe is False or ro else ("y" if (w24 or 0) > 0 else "g"))
    cols.append(ecol)
    rows.append(("Fehler", "%sKernel %s · Warn %s · ext4 %s · Probe %s" % (
        "NUR LESBAR · " if ro else "", "–" if e24 is None else e24, "–" if w24 is None else w24, "–" if eack is None else eack,
        "ok" if probe else ("FEHLER" if probe is False else "–")), ecol, "Kernel-Fehler/Warnungen der letzten 24 h, ext4-Fehler seit der letzten Quittung, Schreib-Probe"))
    age = v.get("age_s")
    scol = "y" if isinstance(age, int) and age > 3 * 3600 else ("n" if age is None else "g")
    if scol == "y":
        cols.append("y")
    # Clone-Alter
    cs = _dt_clone_status()
    ccol = _dt_clone_age_col(cs.get("last_ok_age_s"))
    cols.append(ccol)
    last = (cs.get("history") or [{}])[0] if cs.get("history") else {}
    rows.append(("Letzter Clone", ("%s · %s" % (_dt_age_txt(cs.get("last_ok_age_s")), "OK" if last.get("ok") else ("danach FEHLER" if last else "")))
                 if cs.get("last_ok_age_s") is not None else ("noch keiner OK" + (" · FEHLER" if last else "")), ccol,
                 "gelb ab 7 Tagen, rot ab 30 Tagen"))
    lvl = _dt_worst(*cols) if cols else "n"
    return {"lvl": lvl, "rows": rows, "disk": dk, "smart": {k: sm.get(k) for k in ("ok", "health", "temp", "hours", "wear", "reserve", "realloc", "pending", "args", "why")},
            "boot": bo, "sdh_at": v.get("at"), "sdh_age_s": age, "ack_at": v.get("ack_at"), "smart_t": _DT.get("smart_t")}


def _dt_boot_ctx():
    """Fuer die Systemstatus-Kachel: Boot SSD gruen / SD gelb."""
    try:
        _dt_ensure_thread()
        dk = _DT.get("disk") or {}
        bo = _DT.get("boot") or {}
        if not dk.get("src"):
            return {"txt": "wird gelesen …", "color": DT_COL["n"]}
        if dk.get("kind") == "SD":
            return {"txt": "SD-Karte (Rückfall)", "color": DT_COL["y"]}
        if dk.get("kind") in (None, "?"):
            return {"txt": "unbekannt (%s)" % (dk.get("src") or "?"), "color": DT_COL["n"]}
        return {"txt": "%s (Master)" % (dk.get("kind") or "SSD"), "color": DT_COL["g"]}
    except Exception:
        return {"txt": "–", "color": DT_COL["n"]}


# ---------------------------------------------------------------- Kacheln
def _dt_row(k, v, c="n", tip=""):
    dot = '<span class="pp-dot" style="background:%s"></span>' % DT_COL.get(c, DT_COL["n"]) if c != "n" else '<span class="pp-dot" style="background:transparent"></span>'
    return ('<div class="pp-kv dt2-kv" title="%s"><span class="dt2-k">%s</span><span class="pp-val dt2-val">%s<span class="dt2-t">%s</span></span></div>'
            % (_dt_esc(("%s: %s" % (k, v)) + ((" – " + tip) if tip else "")), _dt_esc(k), dot, _dt_esc(v)))


def _dt_cards():
    ssd = _dt_ssd_view()
    cs = _dt_clone_status()
    sd = _dt_sd_info()
    txt = {"g": "gesund", "y": "beobachten", "r": "Fehler – Backup prüfen!", "n": "wird gelesen …"}[ssd["lvl"]]
    rows = "".join(_dt_row(*r) for r in ssd["rows"])
    foot = "Prüfung %s (%s) · SMART %s" % (_dt_esc((ssd.get("sdh_at") or "–")[11:16] or "–"), _dt_age_txt(ssd.get("sdh_age_s")),
                                          _dt_age_txt(_dt_time.time() - ssd["smart_t"]) if ssd.get("smart_t") else "–")
    if ssd.get("ack_at"):
        foot += " · quittiert %s" % _dt_esc(ssd["ack_at"])
    ssd_html = ('<div class="card pp-card" id="ssdCard"><div class="title">💾 SSD · Master <span class="pp-dot" style="background:%s;display:inline-block;vertical-align:middle"></span> '
                '<span class="pp-sub">%s</span></div>%s<div class="pp-foot">%s</div>'
                '<div class="dt2-btns"><button type="button" id="dt2Ack">Quittieren &amp; neu prüfen</button><span id="dt2AckMsg" class="dt2-msg"></span></div></div>'
                % (DT_COL[ssd["lvl"]], _dt_esc(txt), rows, foot))
    # SD-Fallback
    hist = cs.get("history") or []
    last = hist[0] if hist else None
    if not sd.get("present"):
        sd_line = ("Karte", "fehlt", "r", "")
    else:
        pr = sd.get("parts") or {}
        mt = sd.get("mounts") or {}
        mtxt = ", ".join(sorted(set(m for v in mt.values() for m in v))) or "nicht eingehängt"
        sd_line = ("Karte", "%s GB · p1 %s · p2 %s · %s" % (_dt_num((sd.get("size") or 0) / 1e9), "ok" if pr.get(DT_SD_DEV + "p1") else "fehlt",
                                                         "ok" if pr.get(DT_SD_DEV + "p2") else "fehlt", mtxt), "g" if all(pr.values()) else "r",
                   "eingehängt: %s (Automount wird beim Klon ausgehängt)" % mtxt)
    st = cs.get("state")
    prog = int(cs.get("progress") or 0)
    if st == "running":
        scol, stxt = "y", "läuft · %d %%%s" % (prog, (" · noch ~%d min" % max(1, round(cs["eta_s"] / 60))) if isinstance(cs.get("eta_s"), (int, float)) else "")
    elif st == "done" and cs.get("ok") is True:
        scol, stxt = "g", "fertig · ohne Fehler"
    elif st == "error" or cs.get("ok") is False:
        scol, stxt = "r", "Fehler%s" % ((" · " + str(cs.get("why"))) if cs.get("why") else "")
    else:
        scol, stxt = "n", "bereit"
    if last:
        lres = ("OK · %s · %s" % (_fmt_date(last.get("finished")), last.get("duration") or "–")) if last.get("ok") else \
               ("FEHLER · %s · %s%s" % (_fmt_date(last.get("finished") or last.get("started")), last.get("step") or "?", (" – " + str(last.get("why"))) if last.get("why") else ""))
        lcol = "g" if last.get("ok") else "r"
    else:
        lres, lcol = "noch kein Klon", "n"
    acol = _dt_clone_age_col(cs.get("last_ok_age_s"))
    hdr = _dt_worst(acol, lcol if lcol != "n" else "g", "r" if not sd.get("present") else "g")
    bl = cs.get("block") or []
    hrows = "".join('<div class="pp-row dt2-h" title="%s"><span class="pp-dot" style="background:%s"></span><span class="pp-name">%s · %s</span><span class="pp-sub">%s</span></div>'
                    % (_dt_esc(str(h.get("why") or "")), DT_COL["g" if h.get("ok") else "r"], _dt_esc(_fmt_date(h.get("finished") or h.get("started"))),
                       _dt_esc(h.get("duration") or "–"), _dt_esc("OK" if h.get("ok") else ("Fehler: %s" % (h.get("step") or "?"))))
                    for h in hist[:5])
    data = {"state": st, "progress": prog, "block": bl}
    sd_html = ('<div class="card pp-card" id="sdFallback"><div class="title">🗂️ SD · Fallback <span class="pp-dot" style="background:%s;display:inline-block;vertical-align:middle"></span> '
               '<span class="pp-sub">%s</span></div>%s%s%s'
               '<div class="dt2-bar"><div id="cloneBar" style="width:%d%%;background:%s"></div></div>'
               '<div class="pp-foot" id="cloneStep">%s</div>'
               '%s<div class="dt2-btns"><button type="button" id="dt2Clone"%s>Jetzt von SSD auf SD klonen</button><span id="cloneMsg" class="dt2-msg"></span></div>'
               '<div class="pp-foot" style="margin-top:6px">Letzte Klone (%d gespeichert, nur auf Knopfdruck):</div>%s'
               '<script type="application/json" id="dt2Data">%s</script></div>'
               % (DT_COL[hdr], _dt_esc({"g": "bereit", "y": "beobachten", "r": "prüfen", "n": "–"}[hdr]), _dt_row(*sd_line),
                  _dt_row("Klon", stxt, scol, str(cs.get("why") or "")), _dt_row("Letztes Ergebnis", lres, lcol, str((last or {}).get("why") or "")),
                  prog, DT_COL[scol if scol != "n" else "g"], _dt_esc(str(cs.get("step") or "")) if st == "running" else "&nbsp;",
                  "".join('<div class="pp-warn">gesperrt: %s</div>' % _dt_esc(b) for b in bl if "läuft gerade" not in b),
                  " disabled" if bl else "", len(hist), hrows or '<div class="pp-foot">–</div>',
                  _dt_json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")))
    return ssd_html + sd_html + _DT_CSS + _DT_JS


_DT_CSS = """<style id="dt2-style">
#ssdCard .dt2-val,#sdFallback .dt2-val{display:flex;align-items:center;gap:5px;justify-content:flex-end;min-width:0;flex:1 1 auto}
.dt2-k{flex:none;margin-right:6px}
.dt2-val .pp-dot{flex:none}
.dt2-t{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.dt2-bar{background:#0f172a;border-radius:4px;height:10px;margin:6px 0 2px;overflow:hidden}
.dt2-bar>div{height:100%;transition:width .4s}
.dt2-btns{display:flex;align-items:center;gap:8px;margin-top:8px;flex-wrap:nowrap;min-width:0}
.dt2-btns button{padding:4px 10px;border-radius:8px;border:0;background:#2563eb;color:#fff;font-size:12px;flex:none}
.dt2-btns button[disabled]{background:#334155;color:#94a3b8}
#sdFallback #dt2Clone{background:#ea580c}
#sdFallback #dt2Clone[disabled]{background:#334155;color:#94a3b8}
.dt2-msg{font-size:12px;opacity:.8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
</style>"""

_DT_JS = """<script id="dt2-js">
(function(){
function $(i){return document.getElementById(i);}
function msg(t){var m=$('cloneMsg');if(m)m.textContent=t;}
function poll(){fetch('/api/clone/status',{cache:'no-store'}).then(function(r){return r.json();}).then(function(s){
var p=s.progress||0,b=$('cloneBar'),st=$('cloneStep');if(b)b.style.width=p+'%';
if(s.state==='running'){var e=(typeof s.eta_s==='number')?(' · noch ~'+Math.max(1,Math.round(s.eta_s/60))+' min'):'';
msg('läuft … '+p+' %'+e);if(st)st.textContent=s.step||'';setTimeout(poll,3000);}else{location.reload();}
}).catch(function(){setTimeout(poll,6000);});}
function start(tok){var o={method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(tok?{token:tok}:{})};
return fetch('/api/clone/start',o).then(function(r){return r.json();});}
var c=$('dt2Clone');
if(c){c.addEventListener('click',function(){
if(!confirm('SSD → SD klonen? Die SD-Karte wird komplett überschrieben!'))return;
c.disabled=true;msg('prüfe …');
start(null).then(function(j){
if(j.need_confirm&&j.token){if(!confirm(j.text||'Wirklich starten?')){c.disabled=false;msg('abgebrochen');return;}
msg('starte …');return start(j.token).then(function(k){if(k.ok){msg('gestartet');setTimeout(poll,1500);}else{c.disabled=false;msg((k.why||['nicht gestartet']).join('; '));}});}
c.disabled=false;msg((j.why||['nicht möglich']).join('; '));
}).catch(function(){c.disabled=false;msg('Fehler beim Start');});});}
var a=$('dt2Ack');
if(a){a.addEventListener('click',function(){var m=$('dt2AckMsg');a.disabled=true;if(m)m.textContent='quittiere …';
fetch('/api/sd_health/ack',{method:'POST'}).then(function(r){return r.json();}).then(function(j){
if(!j.ok){a.disabled=false;if(m)m.textContent=j.error||'Fehler';return;}
var n=0,t0=Math.floor(Date.now()/1000)-2;if(m)m.textContent='Prüfung läuft …';
(function w(){fetch('/api/sd_health',{cache:'no-store'}).then(function(r){return r.json();}).then(function(v){
if((v.ts||0)>=t0&&(v.ack_ts||0)>=j.ack_ts){location.reload();return;}
if(++n>40){a.disabled=false;if(m)m.textContent='keine neue Prüfung (Timer prepper-sd-health.path?)';return;}setTimeout(w,3000);
}).catch(function(){setTimeout(w,3000);});})();
}).catch(function(){a.disabled=false;if(m)m.textContent='Fehler';});});}
try{var d=JSON.parse(($('dt2Data')||{}).textContent||'{}');if(d.state==='running')setTimeout(poll,2000);}catch(e){}
})();
</script>"""


def _dt_after(resp):
    try:
        from flask import request
        if request.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="ssdCard"' in body:
            return resp
        i = body.rfind("</body>")
        if i > 0:
            resp.set_data(body[:i] + _dt_cards() + body[i:])
    except Exception as e:
        print("diskTiles2:", e, flush=True)
    return resp


# sd_health.json kommt vom (unveraenderten) root-Timer prepper-sd-health: dessen SD-Grenze fuer Schreiblast gilt nicht fuer die SSD.
if callable(globals().get("sdh_view")) and not getattr(globals().get("sdh_view"), "_dt2", False):
    _dt_orig_sdh_view = sdh_view

    def sdh_view():
        v = _dt_orig_sdh_view()
        try:
            rd = str(v.get("root_disk") or v.get("dev") or (v.get("root") or {}).get("source") or "")
            if v.get("ts") and rd and "mmcblk" not in rd:
                rs = list(v.get("reasons") or [])
                wr = [r for r in rs if str(r).lower().startswith("hohe schreiblast")]
                rest = [r for r in rs if r not in wr]
                g = v.get("gb_day")
                if isinstance(g, (int, float)) and g >= DT_WRITE_Y:
                    rest.append("Schreiblast %s GB/Tag (SSD-Grenze %d)" % (_dt_num(g), DT_WRITE_Y))
                v["reasons"] = rest
                if wr and not rest and v.get("level") == "yellow":
                    v["level"], v["state"] = "green", "ok"
                elif rest and v.get("level") == "green":
                    v["level"], v["state"] = "yellow", "alt"
                if "Consumer-SD" in str(v.get("wear") or ""):
                    v["wear"] = "SSD: Verschleiss siehe SMART"
        except Exception as e:
            print("diskTiles2 sdh_view:", e, flush=True)
        return v
    sdh_view._dt2 = True


def _dt_selftest():
    import tempfile
    old = dict(_DT)
    g = globals()
    old_paths = (g["CLONE_STATUS"], g["CLONE_HIST"])
    tmp = tempfile.mkdtemp(prefix="dt2-")
    try:
        smart_out = ("SMART overall-health self-assessment test result: PASSED\n"
                     "ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE\n"
                     "  5 Reallocated_Sector_Ct   0x0032   100   100   000    Old_age   Always       -       0\n"
                     "  9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       1234\n"
                     "168 SATA_Phy_Error_Count    0x0032   100   100   000    Old_age   Always       -       0\n"
                     "177 Wear_Leveling_Count     0x0032   097   097   000    Old_age   Always       -       31\n"
                     "194 Temperature_Celsius     0x0022   062   052   000    Old_age   Always       -       38 (Min/Max 20/48)\n")
        calls = []

        def cmd(a):
            calls.append(list(a))
            if a[:2] == ["findmnt", "-n"]:
                return 0, ("/dev/sda2\n" if a[-1] == "/" else "/dev/sda1\n"), ""
            if a[:3] == ["lsblk", "-no", "PKNAME"]:
                return 0, "sda\n", ""
            if a[0] == "lsblk":
                return 0, '{"blockdevices":[{"name":"sda","tran":"usb","model":"INTENSO SSD","size":256060514304,"rota":false}]}', ""
            if a[0] == "vcgencmd":
                return 0, "BOOT_UART=0\nBOOT_ORDER=0xf14\n", ""
            if a[:3] == ["sudo", "-n", "smartctl"]:
                if "-d" not in a:
                    return 2, "", "Read Device Identity failed: scsi error unsupported field"
                return 0, smart_out, ""
            return 1, "", "?"
        sysd = _dt_os.path.join(tmp, "sys")
        for p in ("block/mmcblk0/mmcblk0p1", "block/mmcblk0/mmcblk0p2"):
            _dt_os.makedirs(_dt_os.path.join(sysd, p))
        open(_dt_os.path.join(sysd, "block/mmcblk0/size"), "w").write("%d\n" % (119.2e9 // 512))
        open(_dt_os.path.join(sysd, "block/mmcblk0/mmcblk0p1/size"), "w").write("1048576\n")
        open(_dt_os.path.join(sysd, "block/mmcblk0/mmcblk0p2/size"), "w").write("%d\n" % (118.7e9 // 512))
        mnt = _dt_os.path.join(tmp, "mounts")
        open(mnt, "w").write("/dev/sda2 / ext4 rw 0 0\n/dev/mmcblk0p1 /media/fmg/bootfs vfat rw 0 0\n")
        _DT.update(fake={"cmd": cmd, "sys": sysd, "mounts": mnt}, disk=None, smart=None, boot=None, disk_t=0, smart_t=0, boot_t=0, tok={})
        g["CLONE_STATUS"], g["CLONE_HIST"] = _dt_os.path.join(tmp, "cs.json"), _dt_os.path.join(tmp, "ch.json")
        _dt_refresh(force=True)
        assert _DT["disk"]["kind"] == "SSD" and _DT["disk"]["disk"] == "sda" and _DT["disk"]["model"] == "INTENSO SSD", _DT["disk"]
        assert _DT["boot"]["txt"] == "USB → SD → Neustart" and _DT["boot"]["sd_after_usb"] is True, _DT["boot"]
        sm = _DT["smart"]
        assert sm["ok"] and sm["health"] == "PASSED" and sm["temp"] == 38 and sm["hours"] == 1234 and sm["wear"] == 97 and sm["args"] == "-d sat -H -A", sm
        assert _dt_boot_ctx()["color"] == DT_COL["g"]
        now = _dt_time.time()
        iso = lambda t: datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")
        _dt_json.dump([{"started": iso(now - 9 * 86400 - 1900), "finished": iso(now - 9 * 86400), "duration": "31m 40s", "ok": True}], open(g["CLONE_HIST"], "w"))
        cs = _dt_clone_status()
        assert _dt_clone_age_col(cs["last_ok_age_s"]) == "y" and _dt_clone_age_col(31 * 86400) == "r" and _dt_clone_age_col(3600) == "g" and _dt_clone_age_col(None) == "r"
        _dt_json.dump({"state": "running", "progress": 40, "started": iso(now - 600), "pid": 999999}, open(g["CLONE_STATUS"], "w"))
        cs = _dt_clone_status()
        assert cs["state"] == "error" and cs.get("stale") and "Prozess weg" in cs["why"], cs
        _dt_json.dump({"state": "running", "progress": 40, "started": iso(now - 600), "pid": _dt_os.getpid()}, open(g["CLONE_STATUS"], "w"))
        cs = _dt_clone_status()
        assert cs["state"] == "running" and 1200 <= cs["eta_s"] <= 1400 and "Klon läuft gerade" in cs["block"], cs
        _dt_json.dump({"state": "done", "progress": 100, "ok": True}, open(g["CLONE_STATUS"], "w"))
        assert _dt_clone_block(_dt_clone_status()) == [] or all("Übernahme" in b or "Alarm" in b for b in _dt_clone_block(_dt_clone_status()))
        tf = _dt_os.path.join(tmp, "to.json")
        assert _dt_takeover(tf) == ("aus", "")
        for raw, want in (('{"on": true, "since": 1792300000}', "an"), ('{"on": "true"}', "aus"), ('{"on": 1}', "aus"), ('[true]', "aus"), ('{"on": tr', "unklar")):
            with open(tf, "w") as f:
                f.write(raw)
            assert _dt_takeover(tf)[0] == want, (raw, _dt_takeover(tf))
        assert _dt_takeover(tf.replace("to.json", "x")) == ("aus", "")
        html = _dt_cards()
        assert 'id="ssdCard"' in html and 'id="sdFallback"' in html and "SSD · Master" in html and "SD · Fallback" in html and "SD-Karte · Fallback" not in html
        assert "Quittieren &amp; neu prüfen" in html and "/api/sd_health/ack" in html and "USB → SD → Neustart" in html and "PASSED" in html
        assert "/media/fmg/bootfs" in html and "dt2Data" in html
        # Root auf SD -> gelb + Sperre
        _DT.update(disk=dict(_DT["disk"], kind="SD", src="/dev/mmcblk0p2"))
        assert _dt_boot_ctx()["color"] == DT_COL["y"] and any("SD-Karte" in b for b in _dt_clone_block())
        assert _dt_boot_order()["raw"] == "0xf14"
        # sdh_view: SSD-Grenze statt SD-Grenze
        v = {"ts": now, "level": "yellow", "reasons": ["hohe Schreiblast 34.8 GB/Tag"], "root_disk": "sda", "gb_day": 34.8, "wear": "Verschleiss nicht auslesbar (Consumer-SD)"}
        g2 = {"_dt_orig_sdh_view": lambda: dict(v)}
        f = type(sdh_view)(sdh_view.__code__, dict(globals(), **g2))
        r = f()
        assert r["level"] == "green" and r["reasons"] == [] and "SMART" in r["wear"], r
        g2 = {"_dt_orig_sdh_view": lambda: dict(v, gb_day=95.0, level="green", reasons=[])}
        r = type(sdh_view)(sdh_view.__code__, dict(globals(), **g2))()
        assert r["level"] == "yellow" and "SSD-Grenze" in r["reasons"][0], r
        assert "method:'POST'" in _DT_JS and "token" in _DT_JS and _DT_JS.count("confirm(") == 2
        return "diskTiles2 selftest ok (Übernahme robust gelesen, Root dynamisch sda/SSD, BOOT_ORDER 0xf14 = USB → SD → Neustart, SMART -d sat PASSED 38 °C, Clone-Alter gelb 7 d/rot 30 d, haengender Lauf erkannt, ETA aus Verlauf, SD-Boot gelb + gesperrt, SSD-Schreibgrenze, zweite Bestaetigung)"
    finally:
        _DT.clear()
        _DT.update(old)
        g["CLONE_STATUS"], g["CLONE_HIST"] = old_paths
        import shutil as _dt_sh
        _dt_sh.rmtree(tmp, ignore_errors=True)


try:
    _DT["selftest"] = _dt_selftest()
except Exception as _dt_e:
    _DT["selftest"] = "diskTiles2 selftest FEHLER: %s" % _dt_e
try:
    for _dt_rule, _dt_ep, _dt_fn, _dt_m in (("/api/clone/start", "clone_start", _dt_api_clone, ["POST"]), ("/api/clone/status", "clone_status", _dt_api_status, ["GET"]),
                                            ("/api/sysboot/disk", "sysboot_disk", _dt_api_disk, ["GET"])):
        if _dt_ep not in app.view_functions:
            app.add_url_rule(_dt_rule, _dt_ep, _dt_fn, methods=_dt_m)
except Exception as e:
    print("diskTiles2 routes:", e, flush=True)
app.after_request(_dt_after)
print("diskTiles2 aktiv: %s" % _DT["selftest"], flush=True)
# ===== /diskTiles =====
SBD_EOF
EXPECT_BM="25274d8c5ea93f427709b02e7fb326894ed8eb27769f8ff03713e76c2b338d3f"
cat > "$W/src/sb_main_block.py" << 'SBM_EOF'
# ===== sysBoot: Start ohne Warten (Server lauscht sofort, erstes Voll-Update + Mesh-Wetter/Frequenz-Faeden danach im Hintergrund, Hinweis 'laedt' auf den Seiten), threaded=True, langsame Anfragen > 3 s ins Journal, /api/sysboot/status; sendet nichts =====
import time as _sb_time
import threading as _sb_thr

_SB = {"t0": _sb_time.time(), "loading": True, "first_s": None, "first_err": None, "first_done_t": None, "slow": [], "n_slow": 0, "selftest": None}
SB_SLOW_S = 3.0


def _sb_first_update():
    """Erstes Voll-Update im Hintergrund, danach dieselben Faeden in derselben Reihenfolge wie vorher."""
    t0 = _sb_time.time()
    try:
        update_all()
    except Exception as e:
        _SB["first_err"] = str(e)[:160]
        print("sysBoot erstes Voll-Update:", e, flush=True)
    _SB["first_s"] = round(_sb_time.time() - t0, 1)
    _SB["first_done_t"] = _sb_time.time()
    _SB["loading"] = False
    print("sysBoot: erstes Voll-Update fertig nach %.1f s (Server lief schon)" % _SB["first_s"], flush=True)
    for fn in ("weather_mesh_loop", "freq_loop"):
        try:
            f = globals().get(fn)
            if callable(f):
                _sb_thr.Thread(target=f, daemon=True, name=fn).start()
        except Exception as e:
            print("sysBoot Faden %s:" % fn, e, flush=True)
    background_loop()


def _sb_start_updates():
    try:
        _sb_thr.Thread(target=_sb_first_update, daemon=True, name="sysBootFirst").start()
    except Exception as e:
        print("sysBoot Start im Hintergrund nicht moeglich, wie bisher:", e, flush=True)
        _SB["loading"] = False
        update_all()
        threading.Thread(target=background_loop, daemon=True).start()
        threading.Thread(target=weather_mesh_loop, daemon=True).start()
        threading.Thread(target=freq_loop, daemon=True).start()


_SB_BANNER = ('<div id="sbLoading" style="position:sticky;top:0;z-index:999;background:#1e3a8a;color:#e0e7ff;padding:6px 12px;'
              'font-size:13px;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'
              '⏳ Dashboard startet – erste Daten werden geladen (seit %d s), Seite lädt gleich neu</div>'
              '<script>setTimeout(function(){location.reload();},20000);</script>')


def _sb_loading_after(resp):
    try:
        if not _SB["loading"]:
            return resp
        from flask import request as _sb_req
        if _sb_req.method != "GET" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="sbLoading"' in body:
            return resp
        m = _sb_re_body.search(body)
        ins = _SB_BANNER % int(_sb_time.time() - _SB["t0"])
        if m:
            body = body[:m.end()] + ins + body[m.end():]
        resp.set_data(body)
    except Exception as e:
        print("sysBoot Hinweis:", e, flush=True)
    return resp


import re as _sb_re
_sb_re_body = _sb_re.compile(r"<body[^>]*>", _sb_re.I)


class _SbTiming:
    """WSGI-Huelle: misst jede Anfrage inkl. aller after_request-Haken bis zum Ende der Antwort."""

    def __init__(self, inner):
        self.inner = inner

    def __call__(self, environ, start_response):
        t0 = _sb_time.monotonic()
        try:
            res = self.inner(environ, start_response)
        except Exception:
            _sb_note(environ, t0, "Fehler")
            raise
        return _SbIter(res, environ, t0)


class _SbIter:
    def __init__(self, res, env, t0):
        self.res, self.env, self.t0 = res, env, t0

    def __iter__(self):
        return iter(self.res)

    def close(self):
        try:
            c = getattr(self.res, "close", None)
            if callable(c):
                c()
        finally:
            _sb_note(self.env, self.t0)


def _sb_note(env, t0, extra=""):
    try:
        dt = _sb_time.monotonic() - t0
        if dt < SB_SLOW_S:
            return
        path = str(env.get("PATH_INFO") or "")[:80]
        meth = str(env.get("REQUEST_METHOD") or "")[:8]
        _SB["n_slow"] += 1
        _SB["slow"] = (_SB["slow"] + [{"t": int(_sb_time.time()), "m": meth, "p": path, "ms": int(dt * 1000), "x": extra}])[-20:]
        if not _SB.get("quiet"):
            print("sysBoot langsame Anfrage: %s %s %d ms%s%s" % (meth, path, int(dt * 1000), " (Start laeuft)" if _SB["loading"] else "", (" " + extra) if extra else ""), flush=True)
    except Exception:
        pass


def _sb_api_status():
    from flask import jsonify
    try:
        lz = globals().get("_LZK") or {}
        return jsonify({"loading": _SB["loading"], "up_s": int(_sb_time.time() - _SB["t0"]), "first_update_s": _SB["first_s"], "first_err": _SB["first_err"],
                        "slow_n": _SB["n_slow"], "slow": _SB["slow"][-10:], "threaded": True, "lz_kick": {"n": lz.get("n"), "t": int(lz.get("t") or 0), "err": lz.get("err")},
                        "selftest": _SB["selftest"], "pages_wrapped": _SB.get("wrapped")})
    except Exception as e:
        return jsonify({"error": str(e)[:120]})


_SB_LOADING_PAGE = ('<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
                    '<title>Dashboard startet</title><style>body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,system-ui,sans-serif;margin:0;padding:24px}'
                    '.c{max-width:520px;margin:40px auto;background:#111827;border:1px solid #334155;border-radius:14px;padding:18px}a{color:#93c5fd}</style></head>'
                    '<body><div class="c" id="sbLoading"><h2 style="margin-top:0">⏳ Dashboard startet</h2><p>Die ersten Daten werden gerade geladen (seit %d s). '
                    'Diese Seite lädt sich alle 10 s neu und erscheint, sobald die Daten da sind.</p><p><a href="/">Übersicht</a> · <a href="/pi">Pi</a></p></div>'
                    '<script>setTimeout(function(){location.reload();},10000);</script></body></html>')


def _sb_wrap_view(fn):
    import functools

    @functools.wraps(fn)
    def _w(*a, **kw):
        if not _SB["loading"]:
            return fn(*a, **kw)
        try:
            return fn(*a, **kw)
        except Exception as e:
            if not _SB.get("quiet"):
                print("sysBoot: Seite vor dem ersten Voll-Update nicht darstellbar (%s) -> Ladehinweis" % str(e)[:100], flush=True)
            from flask import Response as _sb_Resp
            return _sb_Resp(_SB_LOADING_PAGE % int(_sb_time.time() - _SB["t0"]), status=200, mimetype="text/html", headers={"Cache-Control": "no-store"})
    _w._sb_wrapped = True
    return _w


def _sb_wrap_pages():
    """Nur HTML-Seiten (GET, nicht /api/, nicht /static): Fehler NUR waehrend des Starts -> Ladehinweis statt 500. Danach unveraendert."""
    n = 0
    for rule in list(app.url_map.iter_rules()):
        try:
            r = str(rule.rule)
            if "GET" not in (rule.methods or ()) or r.startswith("/api/") or r.startswith("/static") or "." in r.rsplit("/", 1)[-1]:
                continue
            f = app.view_functions.get(rule.endpoint)
            if f is None or getattr(f, "_sb_wrapped", False):
                continue
            app.view_functions[rule.endpoint] = _sb_wrap_view(f)
            n += 1
        except Exception as e:
            print("sysBoot wrap %s:" % rule, e, flush=True)
    return n


def _sb_selftest():
    _SB["quiet"] = True
    try:
        return _sb_selftest_run()
    finally:
        _SB["quiet"] = False


def _sb_selftest_run():

    class R:
        def __init__(s):
            s.closed = False

        def __iter__(s):
            return iter([b"x"])

        def close(s):
            s.closed = True
    r = R()
    h = _SbTiming(lambda e, sr: r)
    it = h({"PATH_INFO": "/t", "REQUEST_METHOD": "GET"}, None)
    assert list(it) == [b"x"]
    n0 = _SB["n_slow"]
    it.close()
    assert r.closed and _SB["n_slow"] == n0
    old = _SB["slow"][:], _SB["n_slow"]
    _sb_note({"PATH_INFO": "/slow", "REQUEST_METHOD": "GET"}, _sb_time.monotonic() - 4)
    assert _SB["n_slow"] == n0 + 1 and _SB["slow"][-1]["p"] == "/slow"
    _SB["slow"], _SB["n_slow"] = old
    assert "%d" in _SB_BANNER and _sb_re_body.search('<body class="x">')
    assert callable(globals().get("update_all")) and callable(globals().get("background_loop"))
    lz = globals().get("_lz_kick")
    assert callable(lz), "lzKick fehlt"
    def boom():
        raise KeyError("nina")
    w = _sb_wrap_view(boom)
    l0 = _SB["loading"]
    try:
        _SB["loading"] = True
        rr = w()
        assert rr.status_code == 200 and "Dashboard startet" in rr.get_data(as_text=True)
        _SB["loading"] = False
        try:
            w()
            raise AssertionError("nach dem Start muss der Fehler wie bisher durchgehen")
        except KeyError:
            pass
    finally:
        _SB["loading"] = l0
    return "sysBoot selftest ok (WSGI-Zeitmessung inkl. Haken, langsam > 3 s ins Journal, Hinweis 'laedt', Ladeseite nur beim Start, lzKick vorhanden)"


try:
    _SB["selftest"] = _sb_selftest()
except Exception as _sb_e:
    _SB["selftest"] = "sysBoot selftest FEHLER: %s" % _sb_e
try:
    if "sysboot_status" not in app.view_functions:
        app.add_url_rule("/api/sysboot/status", "sysboot_status", _sb_api_status, methods=["GET"])
    if not any(getattr(f, "__name__", "") == "_sb_loading_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_sb_loading_after)
    _SB["wrapped"] = _sb_wrap_pages()
    if not isinstance(app.wsgi_app, _SbTiming):
        app.wsgi_app = _SbTiming(app.wsgi_app)
    print("sysBoot aktiv (%s Seiten mit Ladehinweis): %s" % (_SB.get("wrapped"), _SB["selftest"]), flush=True)
except Exception as _sb_e2:
    print("sysBoot FEHLER:", _sb_e2, flush=True)
# ===== /sysBoot =====


SBM_EOF
EXPECT_GD="470f29bb90a73736e111a549ccf375d7c0e77bf7d477bc2ccda8a3cd9a2c968b"
cat > "$W/src/guard_sb.py" << 'SBG_EOF'
#!/usr/bin/env python3
"""sysBoot AST-Guard: guard_sb.py dash ALT NEU | py ALT NEU  (rc 0 = ok)."""
import ast
import re
import sys

D0 = "# ===== diskTiles: SSD-Master mit SMART + SD-Fallback mit Historie =====\n"
D1 = "# ===== /diskTiles =====\n"


def tops(src):
    names = set()
    for n in ast.parse(src).body:
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(n.name)
        elif isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    names.add(t.id)
    return names


def routes(src):
    return sorted(set(re.findall(r'@app\.route\(\s*"([^"]+)"', src)))


def main_block(src):
    tree = ast.parse(src)
    last = None
    for n in tree.body:
        if isinstance(n, ast.If) and "__main__" in ast.dump(n.test):
            last = n
    return last


def dash(a, b):
    err = []
    sa, sb = open(a, encoding="utf-8").read(), open(b, encoding="utf-8").read()
    i, j = sa.find(D0), sa.find(D1)
    olddisk = tops(sa[i:j + len(D1)]) if 0 <= i < j else set()
    if i < 0 and "# ===== diskTiles2 (sysBoot):" not in sa:
        err.append("Basis ohne diskTiles-Block")
    miss = sorted((tops(sa) - olddisk) - tops(sb))
    if miss:
        err.append("fehlende Namen: %s" % ", ".join(miss[:12]))
    missd = sorted(n for n in olddisk - tops(sb) if not n.startswith("_dt_") and n not in ("DT_HIST_KEEP",))
    if missd:
        err.append("diskTiles-Namen weg: %s" % ", ".join(missd[:12]))
    mr = sorted(set(routes(sa)) - set(routes(sb)))
    if mr:
        err.append("fehlende Routen: %s" % ", ".join(mr))
    for m, n in (("# ===== sysBoot: Start ohne Warten", 1), ("# ===== /sysBoot =====", 1), ("# ===== sysBoot lzKick:", 1), ("# ===== /sysBoot lzKick =====", 1),
                 ("# ===== diskTiles2 (sysBoot):", 1), (D1, 1), ("app.after_request(_dt_after)", 1), ("def _dt_cards():", 1), ("def _sb_selftest():", 1),
                 ("app.after_request(_sb_loading_after)", 1), ("app.wsgi_app = _SbTiming(app.wsgi_app)", 1), (">SD-Karte · Fallback<", 0)):
        c = sb.count(m)
        if c != n:
            err.append("Marke %r %dx (erwartet %d)" % (m[:50], c, n))
    for m in ("_lz_sync(_LZ_AFTER_S)\n", "_lz_sync(_LZ_API_S, ctx)\n", "_lz_sync(_LZ_API_S)\n", "        _lz_sync(5, ctx)\n        br = ctx"):
        if m in sb:
            err.append("lageDB-Abgleich noch im Anfragepfad: %r" % m.strip())
    if sb.count("_lz_sync(30)") != sa.count("_lz_sync(30)"):
        err.append("_t2d_tick-Abgleich veraendert")
    mb = main_block(sb)
    if mb is None:
        err.append("kein __main__")
    else:
        seg = ast.get_source_segment(sb, mb) or ""
        if re.search(r"^\s*update_all\(\)", seg, re.M):
            err.append("update_all() noch synchron in __main__")
        if "_sb_start_updates()" not in seg:
            err.append("_sb_start_updates() fehlt in __main__")
        if "threaded=True" not in seg or seg.count("app.run(") != 1:
            err.append("app.run ohne threaded=True")
        for k in ("load_", "sourceWatch"):
            if (k in (ast.get_source_segment(sa, main_block(sa)) or "")) and k not in seg:
                err.append("__main__ ohne %s" % k)
    # Reihenfolge: sysBoot-Block nach allen Routen (damit _sb_wrap_pages alle Seiten sieht)
    p = sb.find("# ===== sysBoot: Start ohne Warten")
    late = [r for r in re.finditer(r"^@app\.route\(", sb, re.M) if r.start() > p]
    if late:
        err.append("%d Routen nach dem sysBoot-Block" % len(late))
    if "sb_boot" not in sb or '<div>Boot</div>' not in sb:
        err.append("Boot-Zeile Systemstatus fehlt")
    return err, "dashboard: %d Namen, %d Routen erhalten, diskTiles2 ersetzt alten Block, lageDB-Abgleich aus 4 Anfragestellen raus, __main__ ohne synchrones update_all, threaded=True" % (len(tops(sa) - olddisk), len(routes(sa)))


def py(a, b):
    sa, sb = open(a, encoding="utf-8").read(), open(b, encoding="utf-8").read()
    miss = sorted(n for n in tops(sa) - tops(sb))
    err = ["fehlende Namen: %s" % ", ".join(miss)] if miss else []
    return err, "%s: %d Namen erhalten" % (b.rsplit("/", 1)[-1], len(tops(sa)))


if __name__ == "__main__":
    try:
        e, ok = {"dash": dash, "py": py}[sys.argv[1]](sys.argv[2], sys.argv[3])
    except Exception as x:
        e, ok = ["Guard-Fehler: %s" % x], ""
    if e:
        print("GUARD FEHLER: " + " | ".join(e))
        sys.exit(1)
    print("GUARD ok " + ok)
SBG_EOF
EXPECT_CK="878e1e16549707e6004e5a09d7375986913f2f9f3fcad23ad9445d81a300ee15"
cat > "$W/src/sbcheck.py" << 'SBC_EOF'
#!/usr/bin/env python3
"""sysBoot Rauchtest-Pruefer: sbcheck.py pi HTML | disk JSON | clone JSON | status JSON | journald | smartrule FILE USER SMARTCTL  (rc 0 = ok)."""
import json
import re
import sys


def _rd(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def pi(p):
    s = _rd(p)
    pos = {}
    for k in ("ssdCard", "sdFallback", "backupBox", "archCard", "wdPiBox"):
        m = re.search(r'id="%s"' % k, s)
        pos[k] = m.start() if m else -1
    err = []
    if pos["ssdCard"] < 0 or pos["sdFallback"] < 0:
        err.append("SSD-/SD-Kachel fehlt")
    if ">SD-Karte · Fallback<" in s:
        err.append("alte Kachel SD-Karte noch da")
    if "SSD · Master" not in s or "SD · Fallback" not in s:
        err.append("Kacheltitel fehlen")
    if pos["backupBox"] < 0:
        err.append("Sicherung fehlt")
    elif any(v > pos["backupBox"] for k, v in pos.items() if k != "backupBox"):
        err.append("Sicherung nicht letzte Kachel")
    if "Quittieren" not in s[pos["ssdCard"]:pos["sdFallback"]] if pos["ssdCard"] >= 0 < pos["sdFallback"] else True:
        err.append("Quittieren nicht in der SSD-Kachel")
    if "<div>Boot</div>" not in s:
        err.append("Boot-Zeile Systemstatus fehlt")
    if err:
        print("FEHLER /pi: " + "; ".join(err))
        return 1
    print("/pi: SSD · Master + SD · Fallback da, alte SD-Karte-Kachel weg, Quittieren in SSD-Kachel, Boot-Zeile im Systemstatus, Sicherung letzte Kachel")
    return 0


def disk(p):
    d = json.loads(_rd(p))
    rows = {r[0]: r for r in d.get("rows") or []}
    need = ("Boot", "Laufwerk", "SMART", "Belegung", "Schreiblast", "Fehler", "Letzter Clone")
    miss = [k for k in need if k not in rows]
    if miss:
        print("FEHLER /api/sysboot/disk ohne %s" % ", ".join(miss))
        return 1
    dk = d.get("disk") or {}
    print("SSD-Kachel: Root %s (%s %s) · Boot %s · SMART %s · Clone %s" % (dk.get("src"), dk.get("kind"), dk.get("model") or "", rows["Boot"][1], rows["SMART"][1], rows["Letzter Clone"][1]))
    return 0


def clone(p):
    d = json.loads(_rd(p))
    if "state" not in d or "block" not in d:
        print("FEHLER /api/clone/status ohne state/block")
        return 1
    print("Clone-Status: %s, Fortschritt %s %%, Sperren: %s" % (d.get("state"), d.get("progress"), "; ".join(d.get("block") or []) or "keine"))
    return 0


def status(p):
    d = json.loads(_rd(p))
    st = str(d.get("selftest") or "")
    if "selftest ok" not in st or d.get("threaded") is not True:
        print("FEHLER /api/sysboot/status: %s" % st[:160])
        return 1
    print("sysBoot: %s · laedt=%s · erstes Voll-Update %s s · langsame Anfragen %s" % (st[:120], d.get("loading"), d.get("first_update_s"), d.get("slow_n")))
    return 0


def smartrule(f, user, sm):
    s = _rd(f)
    lines = [l for l in s.splitlines() if l.strip() and not l.startswith("#")]
    if len(lines) != 1 or not lines[0].startswith("%s ALL=(root) NOPASSWD: " % user):
        print("FEHLER Regel: genau eine Zeile fuer %s erwartet" % user)
        return 1
    cmds = [c.strip() for c in lines[0].split("NOPASSWD:", 1)[1].split(",")]
    for c in cmds:
        if not c.startswith(sm + " ") or "*" in c or "ALL" in c:
            print("FEHLER Regel zu weit: %s" % c)
            return 1
    print("Regel nur %s mit festen Argumenten (%d Varianten)" % (sm, len(cmds)))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        f = {"pi": pi, "disk": disk, "clone": clone, "status": status, "smartrule": smartrule}[a[0]]
        sys.exit(f(*a[1:]))
    except SystemExit:
        raise
    except Exception as e:
        print("FEHLER %s: %s" % (a[:1], str(e)[:160]))
        sys.exit(1)
SBC_EOF
EXPECT_MS="c178cc772b62d223d12584a1b850cb56e0ca04179a03739e8683979332237e8e"
cat > "$W/src/sbmesh.py" << 'SBX_EOF'
#!/usr/bin/env python3
"""sysBoot meshClean: mesh-ping-reply* (alte Ping-Antwort-Dienste, Ping laeuft laengst in mesh_bridge.py) archivieren + maskiert lassen.

  sbmesh.py plan DASH            nur anzeigen, nichts aendern (rc 0)
  sbmesh.py apply DASH ATTIC MAN archivieren (Unit-Dateien + Skripte + .bak), deaktivieren, maskieren; Manifest MAN fuer den Rueckweg
  sbmesh.py rollback MAN         Rueckweg nach Manifest
  sbmesh.py selftest             mit Fake-Wurzel + Fake-systemctl
Aktive Einheiten werden NIE angefasst. Skripte, die woanders noch erwaehnt werden, bleiben liegen. Sendet nichts ins Mesh, startet nichts.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

UNITS = ("mesh-ping-reply.service", "mesh-ping-reply-2.service", "mesh-ping-reply-bayern.service")
SCRIPTS = ("mesh_ping_reply.py", "mesh_ping_reply2.py", "mesh_ping_reply_bayern.py")
ROOT = os.environ.get("SB_ROOT", "")
SYSTEMCTL = os.environ.get("SB_SYSTEMCTL", "systemctl")
UNIT_DIRS = ("/etc/systemd/system", "/lib/systemd/system", "/usr/lib/systemd/system")


def _w(p, t):
    with open(p, "w") as f:
        f.write(t)


def _rd(p):
    with open(p) as f:
        return f.read()


def _j(p):
    with open(p) as f:
        return json.load(f)


def R(p):
    return ROOT + p if ROOT else p


def sc(*a):
    try:
        p = subprocess.run([SYSTEMCTL] + list(a), capture_output=True, text=True, timeout=60)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as e:
        return 99, "", str(e)[:120]


def show(u):
    rc, out, err = sc("show", "-p", "LoadState", "-p", "ActiveState", "-p", "UnitFileState", "-p", "FragmentPath", u)
    d = {}
    for ln in out.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            d[k] = v
    return d


def dpkg_owned(p):
    try:
        if ROOT:
            return False
        return subprocess.run(["dpkg", "-S", p], capture_output=True, timeout=20).returncode == 0
    except Exception:
        return False


def referenced(dash, name):
    """Wird das Skript (Modulname) noch irgendwo erwaehnt? -> Liste Fundstellen."""
    mod = name[:-3]
    rx = re.compile(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(mod))
    hits = []
    cands = glob.glob(os.path.join(dash, "*.py")) + glob.glob(os.path.join(dash, "*.sh"))
    for d in UNIT_DIRS:
        cands += glob.glob(R(d) + "/*.service") + glob.glob(R(d) + "/*.timer")
    for f in cands:
        b = os.path.basename(f)
        if b.startswith("mesh_ping_reply") or b.startswith("mesh-ping-reply") or ".bak" in b:
            continue
        try:
            if os.path.islink(f) and os.readlink(f) == "/dev/null":
                continue
            with open(f, encoding="utf-8", errors="replace") as fh:
                if rx.search(fh.read()):
                    hits.append(b)
        except Exception:
            pass
    try:
        if not ROOT:
            for u in ("", "-u root"):
                p = subprocess.run(("crontab -l " + u).split(), capture_output=True, text=True, timeout=10)
                if rx.search(p.stdout or ""):
                    hits.append("crontab" + (" root" if u else ""))
    except Exception:
        pass
    return hits


def plan(dash):
    acts, notes = [], []
    for u in UNITS:
        s = show(u)
        ls, as_, uf, fp = s.get("LoadState", "?"), s.get("ActiveState", "?"), s.get("UnitFileState", ""), s.get("FragmentPath", "")
        if as_ in ("active", "activating", "reloading", "deactivating"):
            notes.append("%s ist %s - bleibt unangetastet (bitte selbst pruefen)" % (u, as_))
            continue
        files = []
        for d in UNIT_DIRS:
            p = R(d) + "/" + u
            if os.path.isfile(p) and not os.path.islink(p):
                files.append(p)
        dd = R("/etc/systemd/system") + "/" + u + ".d"
        if os.path.isdir(dd) and not os.path.islink(dd):
            files.append(dd)
        if ls == "not-found" and not files:
            notes.append("%s: nicht vorhanden" % u)
            continue
        for f in files:
            if dpkg_owned(f):
                notes.append("%s gehoert zu einem Paket - bleibt" % f)
                continue
            acts.append({"k": "unit_file", "u": u, "src": f})
        acts.append({"k": "unit", "u": u, "was_masked": ls == "masked" or uf == "masked", "was_enabled": uf in ("enabled", "enabled-runtime"), "load": ls, "active": as_})
    for n in SCRIPTS:
        p = os.path.join(dash, n)
        if os.path.isfile(p):
            h = referenced(dash, n)
            if h:
                notes.append("%s wird noch erwaehnt (%s) - bleibt liegen" % (n, ", ".join(sorted(set(h))[:4])))
            else:
                acts.append({"k": "file", "src": p})
    for g in ("mesh_ping_reply*.py.bak*", "mesh_ping_reply*.bak*", "mesh-ping-reply*.service*", "mesh_ping_reply*.service*"):
        for p in sorted(glob.glob(os.path.join(dash, g))):
            if os.path.isfile(p) and not any(a.get("src") == p for a in acts):
                acts.append({"k": "file", "src": p})
    return acts, notes


def describe(acts, notes):
    out = []
    for a in acts:
        if a["k"] == "unit":
            out.append("%s: %s, %s -> deaktivieren + maskiert" % (a["u"], "schon maskiert" if a["was_masked"] else ("aktiviert" if a["was_enabled"] else a["load"]), a["active"]))
        else:
            out.append("archivieren %s" % a["src"].replace(ROOT, ""))
    return out + ["HINWEIS " + n for n in notes]


def _own(path, ref):
    try:
        st = os.stat(ref)
        for dp, dn, fn in os.walk(path):
            os.chown(dp, st.st_uid, st.st_gid)
            for f in fn:
                os.lchown(os.path.join(dp, f), st.st_uid, st.st_gid)
    except Exception:
        pass


def apply(dash, attic, man):
    acts, notes = plan(dash)
    done = []
    os.makedirs(attic, exist_ok=True)

    def save():
        tmp = man + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"attic": attic, "done": done}, f, indent=1)
        os.replace(tmp, man)
    save()
    for a in [a for a in acts if a["k"] == "unit"]:
        sc("disable", a["u"])
        done.append({"k": "disabled", "u": a["u"], "was_enabled": a["was_enabled"]})
        save()
    for a in acts:
        if a["k"] in ("unit_file", "file"):
            sub = "units" if a["k"] == "unit_file" else "files"
            dst = os.path.join(attic, sub, a["src"].replace(ROOT, "").lstrip("/").replace("/", "__"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(a["src"], dst)
            done.append({"k": "moved", "src": a["src"], "dst": dst})
            save()
    sc("daemon-reload")
    for a in [a for a in acts if a["k"] == "unit"]:
        if not a["was_masked"]:
            rc, o, e = sc("mask", a["u"])
            if rc != 0:
                raise SystemExit("mask %s: %s" % (a["u"], e[:160]))
            done.append({"k": "masked", "u": a["u"]})
            save()
    sc("daemon-reload")
    _own(attic, dash)
    with open(os.path.join(attic, "README.txt"), "w") as f:
        f.write("sysBoot meshClean: alte mesh-ping-reply Dienste/Skripte archiviert (Ping laeuft in mesh_bridge.py). Einheiten bleiben maskiert.\n"
                + "\n".join("%s -> %s" % (d["src"].replace(ROOT, ""), d["dst"]) for d in done if d["k"] == "moved") + "\n")
    _own(attic, dash)
    bad = [u for u in UNITS if show(u).get("ActiveState") == "active"]
    print("meshClean: %d Dateien archiviert, %d Einheiten neu maskiert, %d schon maskiert%s" % (
        sum(1 for d in done if d["k"] == "moved"), sum(1 for d in done if d["k"] == "masked"),
        sum(1 for a in acts if a["k"] == "unit" and a["was_masked"]), ("; HINWEIS " + "; ".join(notes)) if notes else ""))
    return 1 if bad else 0


def rollback(man):
    try:
        d = _j(man)
    except Exception as e:
        print("meshClean Rueckweg: kein Manifest (%s) - nichts zu tun" % e)
        return 0
    for x in reversed(d.get("done") or []):
        try:
            if x["k"] == "masked":
                sc("unmask", x["u"])
            elif x["k"] == "moved" and os.path.exists(x["dst"]) and not os.path.exists(x["src"]):
                os.makedirs(os.path.dirname(x["src"]), exist_ok=True)
                shutil.move(x["dst"], x["src"])
        except Exception as e:
            print("meshClean Rueckweg %s: %s" % (x, e))
    sc("daemon-reload")
    for x in d.get("done") or []:
        if x["k"] == "disabled" and x.get("was_enabled"):
            sc("enable", x["u"])
    print("meshClean Rueckweg: alter Stand wiederhergestellt (%d Schritte)" % len(d.get("done") or []))
    return 0


def selftest():
    global ROOT, SYSTEMCTL
    t = tempfile.mkdtemp(prefix="sbmesh-")
    old = ROOT, SYSTEMCTL
    try:
        ROOT = t + "/r"
        dash = t + "/dash"
        for d in ("/etc/systemd/system", "/lib/systemd/system"):
            os.makedirs(ROOT + d)
        os.makedirs(dash)
        st = t + "/state.json"
        _w(st, json.dumps({"mesh-ping-reply.service": {"LoadState": "masked", "ActiveState": "inactive", "UnitFileState": "masked", "FragmentPath": "/dev/null"},
                   "mesh-ping-reply-2.service": {"LoadState": "loaded", "ActiveState": "inactive", "UnitFileState": "enabled", "FragmentPath": "/etc/systemd/system/mesh-ping-reply-2.service"},
                   "mesh-ping-reply-bayern.service": {"LoadState": "loaded", "ActiveState": "active", "UnitFileState": "enabled", "FragmentPath": "/etc/systemd/system/mesh-ping-reply-bayern.service"}}))
        fake = t + "/systemctl"
        with open(fake, "w") as f:
            f.write("""#!%s
import json,sys
st=json.load(open(%r)); a=sys.argv[1:]; open(%r,"a").write(" ".join(a)+"\\n")
if a[0]=="show":
    u=a[-1]; print("\\n".join("%%s=%%s"%%kv for kv in st.get(u,{"LoadState":"not-found","ActiveState":"inactive","UnitFileState":"","FragmentPath":""}).items()))
elif a[0]=="mask": st[a[1]].update(LoadState="masked",UnitFileState="masked")
elif a[0]=="unmask": st[a[1]].update(LoadState="loaded",UnitFileState="disabled")
elif a[0]=="disable" and st.get(a[1],{}).get("UnitFileState")=="enabled": st[a[1]]["UnitFileState"]="disabled"
elif a[0]=="enable": st[a[1]]["UnitFileState"]="enabled"
json.dump(st,open(%r,"w"))
""" % (sys.executable, st, t + "/calls.log", st))
        os.chmod(fake, 0o755)
        SYSTEMCTL = fake
        for u in ("mesh-ping-reply-2.service", "mesh-ping-reply-bayern.service"):
            _w(ROOT + "/etc/systemd/system/" + u, "[Service]\nExecStart=/usr/bin/python3 /x/%s\n" % u)
        for n in SCRIPTS + ("mesh_ping_reply.py.bak-1", "mesh-ping-reply.service.bak"):
            _w(os.path.join(dash, n), "# alt\n")
        _w(os.path.join(dash, "mesh_bridge.py"), "import os\n# kein Bezug\n")
        _w(os.path.join(dash, "funk.sh"), "python3 mesh_ping_reply_bayern.py\n")
        acts, notes = plan(dash)
        txt = describe(acts, notes)
        assert any("bayern.service ist active" in n for n in notes), notes
        assert any("mesh_ping_reply_bayern.py wird noch erwaehnt" in n for n in notes), notes
        assert not any(a.get("u") == "mesh-ping-reply-bayern.service" for a in acts)
        before = sorted(os.listdir(dash)), sorted(os.listdir(ROOT + "/etc/systemd/system"))
        rc = apply(dash, t + "/attic", t + "/man.json")
        assert rc == 1  # bayern bleibt aktiv -> Hinweis-rc
        s = _j(st)
        assert s["mesh-ping-reply-2.service"]["LoadState"] == "masked" and s["mesh-ping-reply.service"]["LoadState"] == "masked"
        assert s["mesh-ping-reply-bayern.service"]["ActiveState"] == "active" and s["mesh-ping-reply-bayern.service"]["UnitFileState"] == "enabled"
        assert sorted(os.listdir(dash)) == ["funk.sh", "mesh_bridge.py", "mesh_ping_reply_bayern.py"], os.listdir(dash)
        assert not os.path.exists(ROOT + "/etc/systemd/system/mesh-ping-reply-2.service")
        assert os.path.exists(ROOT + "/etc/systemd/system/mesh-ping-reply-bayern.service")
        assert len(os.listdir(t + "/attic/files")) == 4 and len(os.listdir(t + "/attic/units")) == 1
        calls = _rd(t + "/calls.log")
        assert "start" not in calls and "restart" not in calls
        rollback(t + "/man.json")
        assert (sorted(os.listdir(dash)), sorted(os.listdir(ROOT + "/etc/systemd/system"))) == before
        s = _j(st)
        assert s["mesh-ping-reply-2.service"]["UnitFileState"] == "enabled" and s["mesh-ping-reply.service"]["LoadState"] == "masked"
        a2, n2 = plan(dash)
        print("meshClean selftest ok (schon maskierte bleibt maskiert, aktive Einheit + noch erwaehntes Skript bleiben, .bak archiviert, kein start/restart, Rueckweg vollstaendig)")
        return 0
    finally:
        ROOT, SYSTEMCTL = old
        shutil.rmtree(t, ignore_errors=True)


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a[:1] == ["selftest"]:
            sys.exit(selftest())
        if a[:1] == ["plan"] and len(a) == 2:
            ac, no = plan(a[1])
            print("\n".join(describe(ac, no)) or "meshClean: nichts zu tun")
            sys.exit(0)
        if a[:1] == ["apply"] and len(a) == 4:
            sys.exit(apply(a[1], a[2], a[3]))
        if a[:1] == ["rollback"] and len(a) == 2:
            sys.exit(rollback(a[1]))
    except SystemExit:
        raise
    except Exception as e:
        print("meshClean FEHLER: %s" % e)
        sys.exit(2)
    print(__doc__)
    sys.exit(64)
SBX_EOF
EXPECT_WD="dd03e22d59732e613009638c034917752b24625330206c78c05207617821b3aa"
cat > "$W/src/watchdog.py" << 'SBW_EOF'
#!/usr/bin/env python3
# ===== funkHarden3 watchdog: Port aus config.py, OK 1x/h, atomar =====
# ===== sysBoot watchdog: 15 s Zeitlimit, Neustart erst nach 3 Fehlschlaegen in Folge, nie in den ersten 10 min nach Start, Nachpruefung bis 6 min =====
"""Schlanker Watchdog: Dienst + GET / -> optional Restart (Cooldown 30 min).  # funkHarden3 # sysBoot

funkHarden3: Port aus config.py (8080 = kiwix -> 5000), OK nur 1x pro Stunde und bei
Zustandswechsel im Log, Log kuerzen und Cooldown-Datei atomar. Neustart wie bisher.
sysBoot: GET / mit 15 s Zeitlimit (vorher 5 s), Antwortzeit im Log; Neustart erst nach 3 Fehlschlaegen
in Folge (Timer alle 5 min -> etwa 10-15 min echter Ausfall), nie solange der Dienst juenger als 10 min ist
(Start laeuft), nach dem Neustart Nachpruefung alle 20 s bis 6 min. Cooldown 30 min bleibt.
"""
import os
import re
import sys
import time
import json
import subprocess
import urllib.request
from pathlib import Path
from datetime import datetime

BASE = Path("/home/fmg/prepper-dashboard")
FLAG = BASE / "last_dashboard_restart.txt"
LOG = BASE / "watchdog.log"
STATE = BASE / "watchdog_state.json"
COOLDOWN_MIN = 30
OK_LOG_EVERY = 3600
DEFAULT_PORT = 5000
HTTP_TIMEOUT_S = 15          # sysBoot
FAILS_NEEDED = 3             # sysBoot: Fehlschlaege in Folge bis Neustart
START_GRACE_S = 600          # sysBoot: Dienst juenger -> kein Neustart
RECHECK_MAX_S = 360          # sysBoot: Nachpruefung nach Neustart
RECHECK_EVERY_S = 20
UNIT = "prepper-dashboard"


def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def _atomic_write(path, text):
    path = Path(path)
    tmp = path.with_name(".%s.tmp-%d" % (path.name, os.getpid()))
    try:
        with open(tmp, "w") as f:
            f.write(text)
            f.flush()
            try:
                os.fsync(f.fileno())
            except Exception:
                pass
        os.replace(tmp, path)
    finally:
        try:
            if tmp.exists():
                tmp.unlink()
        except Exception:
            pass


def dash_port():
    """PORT aus config.py; fehlt/kaputt/8080 -> 5000."""
    try:
        txt = (BASE / "config.py").read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^PORT\s*=\s*(\d+)", txt, re.M)
        if m:
            p = int(m.group(1))
            if p != 8080 and 0 < p < 65536:
                return p
    except Exception:
        pass
    return DEFAULT_PORT


def log(msg):
    line = f"[{now_str()}] {msg}"
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
        lines = LOG.read_text().splitlines()
        if len(lines) > 400:
            _atomic_write(LOG, "\n".join(lines[-300:]) + "\n")
    except Exception:
        pass


def _load_state():
    try:
        d = json.loads(STATE.read_text())
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _save_state(d):
    try:
        _atomic_write(STATE, json.dumps(d))
    except Exception:
        pass


def active():
    try:
        p = subprocess.run(
            ["systemctl", "is-active", UNIT],
            capture_output=True, text=True, timeout=20,
        )
        return p.returncode == 0 and p.stdout.strip() == "active"
    except Exception:
        return False


def service_age_s():
    """Sekunden seit dem letzten Start der Einheit (ActiveEnterTimestampMonotonic gegen /proc/uptime); None = unbekannt."""
    try:
        p = subprocess.run(["systemctl", "show", "-p", "ActiveEnterTimestampMonotonic", "--value", UNIT],
                           capture_output=True, text=True, timeout=20)
        us = int((p.stdout or "").strip() or "0")
        if us <= 0:
            return None
        with open("/proc/uptime") as f:
            up = float(f.read().split()[0])
        return max(0.0, up - us / 1e6)
    except Exception:
        return None


def own_budget_s():
    """Wie lange darf diese Einheit laufen? (eigene .service aus /proc/self/cgroup, TimeoutStartUSec; unbekannt/infinity -> RECHECK_MAX_S+60) # sysBoot"""
    try:
        unit = None
        with open("/proc/self/cgroup") as f:
            for ln in f:
                for part in reversed(ln.strip().split(":")[-1].split("/")):
                    if part.endswith(".service"):
                        unit = part
                        break
                if unit:
                    break
        if not unit or not re.match(r"^[A-Za-z0-9@_.:-]+$", unit):
            return RECHECK_MAX_S + 60
        p = subprocess.run(["systemctl", "show", "-p", "TimeoutStartUSec", "--value", unit], capture_output=True, text=True, timeout=10)
        v = (p.stdout or "").strip()
        if not v or v == "infinity":
            return RECHECK_MAX_S + 60
        tot = 0.0
        for n, u in re.findall(r"(\d+(?:\.\d+)?)\s*(min|ms|us|s|h)?", v):
            tot += float(n) * {"h": 3600, "min": 60, "s": 1, "ms": 0.001, "us": 1e-6}.get(u or "s", 1)
        return tot if tot > 0 else RECHECK_MAX_S + 60
    except Exception:
        return RECHECK_MAX_S + 60


def http_root():
    """(ok, Sekunden, Fehlertext)."""
    t0 = time.monotonic()
    try:
        r = urllib.request.urlopen("http://127.0.0.1:%d/" % dash_port(), timeout=HTTP_TIMEOUT_S)
        ok = r.status == 200
        return ok, time.monotonic() - t0, "" if ok else "HTTP %s" % r.status
    except Exception as e:
        return False, time.monotonic() - t0, str(e)[:80]


def can_restart():
    try:
        if not FLAG.exists():
            return True
        return (time.time() - FLAG.stat().st_mtime) >= COOLDOWN_MIN * 60
    except Exception:
        return True


def decide(ok_svc, ok_http, age, st, cooldown_ok):
    """Reine Entscheidung (testbar): -> (aktion, neuer_zustand). aktion: ok | wait | start | cooldown | restart."""
    st = dict(st)
    if ok_svc and ok_http:
        st["state"], st["fails"] = "ok", 0
        return "ok", st
    st["state"] = "fail"
    st["fails"] = int(st.get("fails") or 0) + 1
    if ok_svc and age is not None and age < START_GRACE_S:
        return "start", st
    if st["fails"] < FAILS_NEEDED:
        return "wait", st
    if not cooldown_ok:
        return "cooldown", st
    return "restart", st


def main():
    ok_svc = active()
    ok_http, dt, err = http_root()
    st = _load_state()
    prev = st.get("state")
    now = time.time()
    age = service_age_s()
    act, st = decide(ok_svc, ok_http, age, st, can_restart())
    if act == "ok":
        if prev != "ok" or now - float(st.get("ok_logged") or 0) >= OK_LOG_EVERY:
            log("OK service+http %.1f s" % dt + (" (wieder ok)" if prev not in (None, "ok") else ""))
            st["ok_logged"] = now
        _save_state(st)
        return 0
    _save_state(st)
    base = f"FAIL service={ok_svc} http={ok_http} ({dt:.1f} s{', ' + err if err else ''}) Fehlschlag {st['fails']}/{FAILS_NEEDED}"
    if act == "start":
        log(base + f" - Dienst erst {int(age)} s alt (Start laeuft), kein Neustart")
        return 1
    if act == "wait":
        log(base + " - noch kein Neustart")
        return 1
    if act == "cooldown":
        log(base + f" - Cooldown {COOLDOWN_MIN} min, kein Restart")
        return 1
    log(base + " - Restart prepper-dashboard")
    try:
        subprocess.run(["sudo", "systemctl", "restart", UNIT], check=False, timeout=120)
    except Exception as e:
        log(f"Restart Fehler: {e}")
    _atomic_write(FLAG, now_str())
    t0 = time.monotonic()
    ok2 = False
    rmax = max(40, min(RECHECK_MAX_S, own_budget_s() - 30))  # sysBoot: nie laenger als die Einheit darf
    while time.monotonic() - t0 < rmax:
        time.sleep(RECHECK_EVERY_S)
        if active() and http_root()[0]:
            ok2 = True
            break
    log(f"nach Restart recovered={ok2} nach {int(time.monotonic() - t0)} s")
    st = _load_state()
    if ok2:
        st["state"], st["fails"] = "ok", 0
        st["ok_logged"] = time.time()
        _save_state(st)
    return 0 if ok2 else 1


def selftest():
    """Nur lesen: zeigt Port/Zustand, kein Log, kein Restart."""
    ok, dt, err = http_root()
    age = service_age_s()
    print("watchdog funkHarden3+sysBoot port=%d svc=%s http=%s (%.1f s%s) alter=%s cooldown_frei=%s fails=%s" % (
        dash_port(), active(), ok, dt, (", " + err) if err else "", "%d s" % age if age is not None else "?", can_restart(),
        _load_state().get("fails", 0)))
    return 0


def selftest_fake():
    """Entscheidungslogik mit Fakes (nichts wird geprueft oder neu gestartet)."""
    st = {}
    a, st = decide(True, False, 9000, st, True)
    assert a == "wait" and st["fails"] == 1
    a, st = decide(True, False, 9000, st, True)
    assert a == "wait" and st["fails"] == 2
    a, st2 = decide(True, False, 9000, st, False)
    assert a == "cooldown"
    a, st = decide(True, False, 9000, st, True)
    assert a == "restart" and st["fails"] == 3
    a, st = decide(True, True, 9000, st, True)
    assert a == "ok" and st["fails"] == 0
    a, st = decide(True, False, 120, {"fails": 5}, True)
    assert a == "start"
    a, st = decide(False, False, None, {"fails": 2}, True)
    assert a == "restart"
    a, st = decide(True, False, None, {"fails": 0}, True)
    assert a == "wait"
    print("watchdog sysBoot selftest ok (3 Fehlschlaege in Folge, Startschutz 10 min, Cooldown, ok setzt zurueck)")
    return 0


if __name__ == "__main__":
    if "--selftest-fake" in sys.argv[1:]:
        raise SystemExit(selftest_fake())
    if "--selftest" in sys.argv[1:]:
        raise SystemExit(selftest())
    raise SystemExit(main())
SBW_EOF
EXPECT_HC="cc3949f1896ebbf36737c19d31e8e3ad2c4e764da7aca57cedafa0b901fa5c3f"
cat > "$W/src/health_check.py" << 'SBH_EOF'
#!/usr/bin/env python3
"""Health Report → health_status.json (nie systemctl restart). /* health3h */ /* sysBoot */

sysBoot: laeuft der Dienst prepper-dashboard noch keine 10 min (z. B. direkt nach dem Booten), wartet der Check,
bis er 10 min alt ist (nur so lange, wie die eigene Einheit erlaubt); reicht das nicht, bleibt der letzte Bericht stehen
(kein falsches PROBLEM 12/27). Seiten mit 15 s Zeitlimit, Fehlschlaege einmal nach 20 s nachgeprueft."""
import json
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
OUT = BASE / "health_status.json"
LOG = BASE / "health_check.log"
# Nav-Seiten (ohne API / Scanner / Decoder)
PAGES = [
    "/",
    "/energie",
    "/lokale-energie",
    "/speicher",
    "/umwelt",
    "/luft",
    "/pegel",
    "/adsb",
    "/zuhause",
    "/mesh",
    "/mesh2",
    "/news",
    "/funk",
    "/pi",
    "/medizin",
]

DASH_MIN_AGE_S = 600       # sysBoot
PAGE_TIMEOUT_S = 15        # sysBoot (vorher 8 s)
RETRY_PAUSE_S = 20         # sysBoot


def dash_age_s():
    """Sekunden seit Start von prepper-dashboard (None = unbekannt/inaktiv). # sysBoot"""
    try:
        p = subprocess.run(["systemctl", "show", "-p", "ActiveEnterTimestampMonotonic", "-p", "ActiveState", "prepper-dashboard"],
                           capture_output=True, text=True, timeout=20)
        kv = dict(x.split("=", 1) for x in (p.stdout or "").splitlines() if "=" in x)
        if kv.get("ActiveState") != "active":
            return None
        us = int(kv.get("ActiveEnterTimestampMonotonic") or "0")
        if us <= 0:
            return None
        with open("/proc/uptime") as f:
            return max(0.0, float(f.read().split()[0]) - us / 1e6)
    except Exception:
        return None


def own_budget_s():
    """Wie lange darf diese Einheit laufen? (TimeoutStartUSec von prepper-health.service; infinity/unbekannt -> 900 s) # sysBoot"""
    try:
        p = subprocess.run(["systemctl", "show", "-p", "TimeoutStartUSec", "--value", "prepper-health.service"],
                           capture_output=True, text=True, timeout=20)
        v = (p.stdout or "").strip()
        if not v or v == "infinity" or v == "0":
            return 900.0
        tot = 0.0
        for n, u in re.findall(r"(\d+(?:\.\d+)?)\s*(min|ms|us|h|s)", v):
            tot += float(n) * {"h": 3600, "min": 60, "s": 1, "ms": 0.001, "us": 1e-6}[u]
        return tot if tot > 0 else 900.0
    except Exception:
        return 900.0


def wait_plan(age, budget):
    """-> (warten_s, ausfuehren). age None = Dienst nicht aktiv -> sofort pruefen (Fehler sind dann echt). # sysBoot"""
    if age is None or age >= DASH_MIN_AGE_S:
        return 0.0, True
    need = DASH_MIN_AGE_S - age + 5
    if need <= budget - 90:
        return need, True
    return 0.0, False


def fetch_page(p):
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:5000{p}", timeout=PAGE_TIMEOUT_S)
        return r.status
    except Exception:
        return 0


def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")

def log(msg):
    line = f"[{now_str()}] {msg}"
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
        lines = LOG.read_text().splitlines()
        if len(lines) > 500:
            LOG.write_text("\n".join(lines[-350:]) + "\n")
    except Exception:
        pass

def run(cmd, timeout=40):
    try:
        p = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as e:
        return 1, "", str(e)

def item(id_, ok, msg):
    return {"id": id_, "ok": bool(ok), "msg": str(msg)[:120]}

def mesh_host():
    try:
        ns = {}
        exec(open(BASE / "config.py").read(), ns)
        return ns.get("MESHTASTIC_HOST", "192.168.178.141")
    except Exception:
        return "192.168.178.141"

def main():
    items = []
    try:
        age = dash_age_s()
        w, go = wait_plan(age, own_budget_s())
        if not go:
            log("uebersprungen: Dashboard erst %d s alt, Einheit darf nicht lange genug warten - letzter Bericht bleibt" % int(age or 0))
            return 0
        if w > 0:
            log("warte %d s: Dashboard erst %d s alt (Start laeuft)" % (int(w), int(age or 0)))
            time.sleep(w)
    except Exception as e:
        log(f"Startpruefung: {e}")
    try:
        rc, _, err = run(
            f"cd {BASE} && ./venv/bin/python -m py_compile dashboard.py"
        )
        items.append(
            item("compile", rc == 0, "Syntax OK" if rc == 0 else (err or "FAIL")[:80])
        )

        for svc in ("prepper-dashboard", "kiwix", "chrony"):
            rc, out, _ = run(f"systemctl is-active {svc}")
            items.append(item(f"svc_{svc}", rc == 0 and out == "active", out or "inactive"))

        codes = {p: fetch_page(p) for p in PAGES}
        bad = [p for p in PAGES if codes[p] != 200]
        if bad:
            time.sleep(RETRY_PAUSE_S)
            for p in bad:
                codes[p] = fetch_page(p)
            log("Seiten nachgeprueft: %d/%d jetzt ok" % (sum(1 for p in bad if codes[p] == 200), len(bad)))
        for p in PAGES:
            code = codes[p]
            items.append(item(f"page_{p}", code == 200, str(code)))

        try:
            code = urllib.request.urlopen("http://127.0.0.1:8080/", timeout=4).status
            k_ok = code == 200
        except Exception:
            k_ok, code = False, 0
        items.append(item("kiwix", k_ok, str(code)))

        host = mesh_host()
        rc, _, _ = run(f"nc -z -w2 {host} 4403")
        items.append(item("mesh", rc == 0, f"{host}:4403"))

        rc, out, _ = run("df -P / | awk 'NR==2{print $5}'")
        try:
            pct = int(out.replace("%", ""))
            items.append(item("disk", pct < 90, f"{pct} % belegt"))
        except Exception:
            items.append(item("disk", False, out or "n/a"))

        rc, out, _ = run("awk '/MemAvailable/{printf \"%d\", $2}' /proc/meminfo")
        try:
            avail_mb = int(out) // 1024
            items.append(item("ram", avail_mb >= 100, f"{avail_mb} MB frei"))
        except Exception:
            items.append(item("ram", False, "n/a"))

        rc, out, _ = run("vcgencmd measure_temp 2>/dev/null | tr -d \"temp='C\"")
        try:
            temp = float(out)
            items.append(item("temp", temp < 80, f"{temp:.1f} °C"))
        except Exception:
            items.append(item("temp", True, "n/a"))

        rc, out, _ = run("vcgencmd get_throttled 2>/dev/null")
        th_ok = "0x0" in out.replace(" ", "")
        items.append(item("throttle", th_ok or rc != 0, out or "n/a"))

        rc, out, _ = run("chronyc tracking 2>/dev/null | head -6")
        items.append(item("chrony", rc == 0 and bool(out), "tracking OK" if out else "fail"))

        rc, out, _ = run(
            "apt list --upgradable 2>/dev/null | grep -vc '^Auflistung' || true"
        )
        try:
            n = int(out.strip().splitlines()[-1])
        except Exception:
            n = -1
        items.append(item("apt", n == 0, f"{n} Updates" if n >= 0 else "n/a"))

    except Exception as e:
        log(f"ERROR {e}")
        items.append(item("internal", False, str(e)[:80]))

    critical = [i for i in items if i["id"] != "apt"]
    ok = all(i["ok"] for i in critical)
    data = {
        "ok": ok,
        "score": sum(1 for i in items if i["ok"]),
        "max": len(items),
        "at": now_str(),
        "items": items,
    }
    try:
        tmp = OUT.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        tmp.replace(OUT)
    except Exception as e:
        log(f"write JSON fail: {e}")
    log(f"done ok={ok} score={data['score']}/{data['max']}")
    return 0

def selftest_fake():
    """Warte-Logik mit Fakes (nichts wird geprueft). # sysBoot"""
    assert wait_plan(None, 900) == (0.0, True)
    assert wait_plan(700, 900) == (0.0, True)
    w, go = wait_plan(30, 900)
    assert go and 570 <= w <= 580
    assert wait_plan(30, 90) == (0.0, False)
    assert wait_plan(550, 160) == (55, True)
    print("health_check sysBoot selftest ok (wartet bis Dashboard 10 min alt, sonst letzter Bericht bleibt)")
    return 0


if __name__ == "__main__":
    if "--selftest-fake" in sys.argv[1:]:
        raise SystemExit(selftest_fake())
    raise SystemExit(main())
SBH_EOF
EXPECT_MH="1afa8becde24bc89b6173ebbcde9acae1e7ec319133ed15a78ed3566c7b3ec6f"
cat > "$W/src/mesh_hang_watchdog.py" << 'SBY_EOF'
#!/usr/bin/env python3
"""Mesh Hang Watchdog: stuck Telemetrie + Reply-Stumm → Status JSON, optional Restart. # meshHang # meshHangRetry # meshHangCooldownOk"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
STATUS_FILE = BASE / "mesh_hang_status.json"
COOLDOWN_FILE = BASE / "mesh_hang_watchdog_cooldown.json"
LOG_FILE = BASE / "mesh_hang_watchdog.log"
AUTORESTART_FLAG = BASE / "secrets" / "mesh_hang_autorestart"

STUCK_ACTION_SEC = 2700  # 45 min
COOLDOWN_SEC = 2 * 3600  # 2h nach mehreren Retries / Normalpause
COOLDOWN_RETRY_SEC = 25 * 60  # 25 min Zweitversuch solange noch stuck
MAX_QUICK_RETRIES = 4  # Versuche 1..4 im Stuck-Episode: 25-Min-Abstand; danach wieder 2h
# meshHangRetry

MESHES = {
    "m1": {
        "chutil": "mesh1_chutil.json",
        "bridge_svc": "mesh-bridge.service",
        "ping_svc": None,  # sysBoot meshClean: Ping laeuft in mesh_bridge.py, mesh-ping-reply maskiert + archiviert
        "name": "Mesh1",
    },
    "m2": {
        "chutil": "mesh2_chutil.json",
        "bridge_svc": "mesh-bridge-bayern.service",
        "ping_svc": None,  # mesh2OneSession: Ping laeuft in der Bridge
        "name": "Mesh2",
    },
}


def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def log(msg: str) -> None:
    line = f"{now_str()} {msg}"
    print(line, flush=True)
    try:
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _load_json(path: Path, default):
    try:
        data = json.loads(path.read_text() or "")
        return data if data is not None else default
    except Exception:
        return default


def _save_json(path: Path, data) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
    tmp.replace(path)


def _cooldown_entry(mesh_key: str) -> tuple[float, int]:
    """Return (last_restart_ts, attempt_count). Legacy float → n=1."""
    d = _load_json(COOLDOWN_FILE, {})
    if not isinstance(d, dict):
        return 0.0, 0
    v = d.get(mesh_key)
    if v is None:
        return 0.0, 0
    if isinstance(v, dict):
        try:
            ts = float(v.get("ts") or 0)
        except Exception:
            ts = 0.0
        try:
            n = int(v.get("n") or 0)
        except Exception:
            n = 0
        return ts, n
    try:
        return float(v), 1
    except Exception:
        return 0.0, 0


def _cooldown_need_sec(attempt_n: int) -> int:
    # n = already completed restarts in this stuck episode
    if 1 <= attempt_n < MAX_QUICK_RETRIES:
        return COOLDOWN_RETRY_SEC
    if attempt_n >= MAX_QUICK_RETRIES:
        return COOLDOWN_SEC
    return 0


def _cooldown_ok(mesh_key: str) -> bool:
    last, n = _cooldown_entry(mesh_key)
    if not last:
        return True
    need = _cooldown_need_sec(n) or COOLDOWN_RETRY_SEC
    return (time.time() - last) >= need


def _cooldown_remaining_sec(mesh_key: str) -> int:
    last, n = _cooldown_entry(mesh_key)
    if not last:
        return 0
    need = _cooldown_need_sec(n) or COOLDOWN_RETRY_SEC
    return max(0, int(need - (time.time() - last)))


def _mark_cooldown(mesh_key: str) -> None:
    d = _load_json(COOLDOWN_FILE, {})
    if not isinstance(d, dict):
        d = {}
    _last, n = _cooldown_entry(mesh_key)
    d[mesh_key] = {"ts": time.time(), "n": n + 1}
    _save_json(COOLDOWN_FILE, d)


def _clear_cooldown_episode(mesh_key: str) -> None:
    d = _load_json(COOLDOWN_FILE, {})
    if not isinstance(d, dict) or mesh_key not in d:
        return
    d.pop(mesh_key, None)
    _save_json(COOLDOWN_FILE, d)


def _autorestart_enabled() -> bool:
    if os.environ.get("MESH_HANG_WATCHDOG") == "1" and AUTORESTART_FLAG.exists():
        return True
    return AUTORESTART_FLAG.exists()


def _systemctl_restart(units: list[str], dry_run: bool) -> list[str]:
    done = []
    for u in units:
        if dry_run:
            log(f"DRY-RUN would restart {u}")
            done.append(u)
            continue
        try:
            # Prefer passwordless sudo (Pi polkit/sudoers); fall back to plain systemctl
            r = subprocess.run(
                ["sudo", "-n", "systemctl", "restart", u],
                capture_output=True,
                text=True,
                timeout=60,
            )
            if r.returncode != 0:
                r = subprocess.run(
                    ["systemctl", "restart", u],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
            if r.returncode == 0:
                log(f"restarted {u}")
                done.append(u)
            else:
                log(f"FAIL restart {u}: {r.stderr or r.stdout}")
        except Exception as e:
            log(f"FAIL restart {u}: {e}")
    return done


def evaluate_one(mesh_key: str, cfg: dict) -> dict:
    import mesh_chutil
    import mesh_reply_watch

    hist = mesh_chutil.load_hist(BASE / cfg["chutil"])
    stuck = mesh_chutil.detect_stuck(hist)
    tele = mesh_chutil.tele_health(hist)
    reply = mesh_reply_watch.status(mesh_key, stale_sec=3600)

    stuck_sec = int(stuck.get("sec") or 0) if stuck else 0
    reply_state = reply.get("state") or "unbekannt"
    silent = bool(reply.get("silent"))

    recommend_restart = False
    reason = None
    # Telemetrie-Hang allein reicht (Chart-Flatline); Reply-Stumm verstärkt nur die Reason
    if stuck and stuck_sec >= STUCK_ACTION_SEC:
        recommend_restart = True
        reason = f"stuck {stuck_sec}s (>= {STUCK_ACTION_SEC})"
        if silent or reply_state == "stumm":
            reason += f" + reply {reply_state}" + (" silent" if silent else "")
        elif reply_state == "unbekannt":
            reason += " + reply unbekannt"

    return {
        "mesh": mesh_key,
        "name": cfg["name"],
        "tele_state": tele.get("state"),
        "tele_color": tele.get("color"),
        "stuck": stuck,
        "stuck_sec": stuck_sec if stuck else None,
        "reply": reply,
        "recommend_restart": recommend_restart,
        "reason": reason,
        "bridge_svc": cfg["bridge_svc"],
        "ping_svc": cfg["ping_svc"],
    }


def run(dry_run: bool = True, enable_restart: bool = False) -> dict:
    results = {}
    actions = []
    allow = enable_restart or _autorestart_enabled()
    # Env MESH_HANG_WATCHDOG=1 alone is not enough — need flag file OR --enable-restart
    # Spec: Autorestart OFF unless secrets/mesh_hang_autorestart exists
    allow_restart = AUTORESTART_FLAG.exists() if not enable_restart else True
    if enable_restart:
        allow_restart = True
    else:
        allow_restart = AUTORESTART_FLAG.exists()

    for key, cfg in MESHES.items():
        try:
            info = evaluate_one(key, cfg)
        except Exception as e:
            info = {
                "mesh": key,
                "name": cfg["name"],
                "error": str(e),
                "recommend_restart": False,
            }
            log(f"{key} evaluate error: {e}")
        results[key] = info

        if not info.get("recommend_restart"):
            # Episode vorbei → Zähler zurück, nächster Hang startet frisch
            _clear_cooldown_episode(key)
        elif info.get("recommend_restart"):
            log(f"{key}: EMPFEHLUNG Restart — {info.get('reason')}")
            _last, n_done = _cooldown_entry(key)
            info["restart_attempts"] = n_done
            if allow_restart and not dry_run:
                if not _cooldown_ok(key):
                    rem = _cooldown_remaining_sec(key)
                    need = _cooldown_need_sec(n_done) or COOLDOWN_RETRY_SEC
                    log(
                        f"{key}: cooldown aktiv — kein Restart "
                        f"(Versuch {n_done}, Pause {need // 60} min, frei in {rem // 60} min)"
                    )
                    info["action"] = "cooldown"
                    info["cooldown_remaining_sec"] = rem
                    info["cooldown_need_sec"] = need
                else:
                    units = [cfg["bridge_svc"]]
                    # ping reply if unit exists
                    if cfg.get("ping_svc"):  # mesh2OneSession
                        units.append(cfg["ping_svc"])
                    done = _systemctl_restart(units, dry_run=False)
                    # meshHangCooldownOk: Cooldown/Zähler nur bei mind. einem echten Restart
                    if done:
                        _mark_cooldown(key)
                        _last2, n2 = _cooldown_entry(key)
                        log(f"{key}: Restart ausgeführt (Versuch {n2}): {', '.join(done)}")
                        info["action"] = "restarted"
                        info["restarted"] = done
                        info["restart_attempts"] = n2
                        actions.append({"mesh": key, "units": done, "attempt": n2})
                    else:
                        log(f"{key}: Restart fehlgeschlagen — kein Cooldown, Versuch bleibt")
                        info["action"] = "restart_failed"
                        info["restarted"] = []
                        info["restart_attempts"] = n_done
            elif allow_restart and dry_run:
                log(f"{key}: DRY-RUN Restart {cfg['bridge_svc']}" + (f" + {cfg['ping_svc']}" if cfg.get("ping_svc") else ""))  # sysBoot meshClean
                info["action"] = "dry-run"
            else:
                info["action"] = "detect-only"
                log(f"{key}: detect-only (kein Autorestart-Flag)")

    out = {
        "at": now_str(),
        "ts": time.time(),
        "dry_run": dry_run,
        "autorestart_enabled": allow_restart,
        "flag": str(AUTORESTART_FLAG),
        "meshes": results,
        "actions": actions,
    }
    _save_json(STATUS_FILE, out)
    log(f"status written {STATUS_FILE} autorestart={allow_restart}")
    return out


def main():
    ap = argparse.ArgumentParser(description="Mesh Hang Watchdog # meshHang")
    ap.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Nur loggen, keine Restarts (Status wird trotzdem geschrieben)",
    )
    ap.add_argument(
        "--apply",
        action="store_true",
        help="Restarts ausführen wenn Flag/enable gesetzt",
    )
    ap.add_argument(
        "--enable-restart",
        action="store_true",
        help="Restarts erlauben auch ohne Flag-Datei (vorsichtig)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Cooldown ignorieren (sofortiger Restart-Versuch bei Empfohlen)",
    )
    args = ap.parse_args()
    if args.force:
        # Cooldown-Episoden leeren → nächster --apply startet sofort
        d = _load_json(COOLDOWN_FILE, {})
        if isinstance(d, dict) and d:
            _save_json(COOLDOWN_FILE, {})
            log("cooldown geleert (--force)")
    dry = True
    if args.apply and not args.dry_run:
        dry = False
    if args.dry_run:
        dry = True
    # Default when run from timer: detect-only write status (dry regarding restarts)
    # Timer should call without --apply → dry_run path for restarts
    if not args.apply:
        dry = True
    run(dry_run=dry, enable_restart=args.enable_restart)


# ===== funkHarden2 hangwatch: maskierte/abgeschaltete Dienste nie neu starten =====
_fh2_orig_systemctl_restart = _systemctl_restart


def _fh2_unit_state(u: str):
    """(ok, info): ok=False bei masked/not-found/disabled. Abfragefehler -> wie bisher erlauben."""
    try:
        r = subprocess.run(["systemctl", "show", "-p", "LoadState", "-p", "UnitFileState", u],
                           capture_output=True, text=True, timeout=10)
        kv = {}
        for line in (r.stdout or "").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip()
        load = kv.get("LoadState", "")
        ufs = kv.get("UnitFileState", "")
        if load in ("masked", "not-found") or ufs in ("masked", "masked-runtime", "disabled"):
            return False, "%s/%s" % (load or "?", ufs or "?")
        return True, "%s/%s" % (load or "?", ufs or "?")
    except Exception as e:
        return True, "unbekannt (%s)" % e


def _systemctl_restart(units: list[str], dry_run: bool) -> list[str]:  # funkHarden2
    keep = []
    for u in units:
        ok, info = _fh2_unit_state(u)
        if ok:
            keep.append(u)
        else:
            log(f"skip {u}: {info} (funkHarden2: nicht neu starten)")
    if not keep:
        return []
    return _fh2_orig_systemctl_restart(keep, dry_run)
# ===== /funkHarden2 hangwatch =====



if __name__ == "__main__":
    main()
SBY_EOF
EXPECT_CL="dab07956cec4c37c69c8f3f2f63b46192d16be552e1fdeba7745bb4f72b72536"
cat > "$W/src/prepper-clone-ssd-to-sd" << 'SBK_EOF'
#!/usr/bin/python3
"""prepper-clone-ssd-to-sd v2 (sysBoot): Klon SSD (Master) -> SD-Karte (Rueckfall), nur auf Knopfdruck, nie automatisch.

Aufruf (root, ueber die vorhandene sudo-Regel prepper-clone):
  prepper-clone-ssd-to-sd               startet den Klon losgeloest vom Dashboard (systemd-run, Einheit prepper-clone) und kehrt sofort zurueck
  prepper-clone-ssd-to-sd --foreground  Klon im Vordergrund (so laeuft er in der Einheit prepper-clone)
  prepper-clone-ssd-to-sd --check       nur Sperren pruefen, nichts aendern (JSON auf stdout, rc 0 = Klon waere erlaubt, 10 = gesperrt)
  prepper-clone-ssd-to-sd --selftest    Selbsttest mit Fake-Befehlen in einem Temp-Verzeichnis (kein root, nichts Echtes)
Sperren: Root nicht auf SSD (z. B. von SD gebootet), /dev/mmcblk0 oder Partitionen fehlen, Ziel eingehaengt als / oder /boot/firmware,
  Stick-2-Uebernahme (sdr_takeover.json on) oder echter Alarm (sdr_wd_gate.json alarm, frisch <= 15 min), zweiter Lauf (flock), zu wenig Platz.
Ablauf: sqlite-Sicherung lagezentrum.db (vor dem Formatieren) -> Automount (/media/fmg/bootfs) aushaengen -> mkfs -> rsync /boot/firmware und /
  (--info=progress2: echter Fortschritt + ETA; ohne /dev /proc /sys /tmp /run /mnt /media, Swap-Dateien, Journal, live lagezentrum.db/-wal/-shm)
  -> gesicherte lagezentrum.db hinein -> cmdline.txt PARTUUID + fstab -> sync/aushaengen.
Jeder Fehler (auch Abbruch per Signal): clone_status.json state=error + Schritt + Grund, Verlauf ok:false. Verlauf: letzte 10 Laeufe inkl. Fehler.
Haengender Lauf (Prozess weg, Status running) wird beim naechsten Start als Fehler nachgetragen. Sendet nichts.
"""
import fcntl
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time

V = 2
DASH = "/home/fmg/prepper-dashboard"
CFG = {
    "dash": DASH,
    "status": DASH + "/clone_status.json",
    "log": DASH + "/clone.log",
    "hist": DASH + "/clone_history.json",
    "takeover": DASH + "/sdr_takeover.json",
    "gate": DASH + "/sdr_wd_gate.json",
    "db": DASH + "/lagezentrum.db",
    "lock": "/run/prepper-clone.lock",
    "stage": "/var/tmp/prepper-clone",
    "dst_dev": "/dev/mmcblk0",
    "dst_boot": "/dev/mmcblk0p1",
    "dst_root": "/dev/mmcblk0p2",
    "src_boot": "/boot/firmware",
    "src_root": "/",
    "mnt_boot": "/mnt/sd-boot",
    "mnt_root": "/mnt/sd-root",
    "proc": "/proc",
    "sysblock": "/sys/block",
    "unit": "prepper-clone",
    "self": "/usr/local/bin/prepper-clone-ssd-to-sd",
}
HIST_KEEP = 10
LOG_KEEP = 400
GATE_FRESH_S = 15 * 60
RSYNC_OK = (0, 24)          # 24 = Dateien waehrend des Laufs verschwunden (laufendes System) -> ok
P_DB, P_MKFS, P_MOUNT, P_BOOT0, P_BOOT1, P_ROOT0, P_ROOT1 = 2, 4, 5, 5, 8, 8, 95


class CloneError(Exception):
    def __init__(self, step, why):
        Exception.__init__(self, "%s: %s" % (step, why))
        self.step, self.why = step, why


def _now_iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t or time.time()))[:-2] + ":" + time.strftime("%z", time.localtime(t or time.time()))[-2:]


def _dur(s):
    s = int(max(0, s))
    return "%dm %ds" % (s // 60, s % 60)


class Clone:
    def __init__(self, cfg=None, run=None, popen=None, now=None, euid=None, sleep=None):
        self.c = dict(CFG)
        self.c.update(cfg or {})
        self.run_cmd = run or self._run
        self.popen = popen or subprocess.Popen
        self.now = now or time.time
        self.euid = os.geteuid() if euid is None else euid
        self.sleep = sleep or time.sleep
        self.st = {}
        self.t0 = None
        self.last_w = 0.0
        self.mounted = []

    # ---------- Hilfen ----------
    @staticmethod
    def _run(args, timeout=600):
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or ""), (p.stderr or "")

    def _owner(self):
        try:
            s = os.stat(self.c["dash"])
            return s.st_uid, s.st_gid
        except Exception:
            return None

    def _write_json(self, path, obj):
        tmp = "%s.tmp-%d" % (path, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(obj, f, ensure_ascii=False, indent=1)
                f.flush()
                try:
                    os.fsync(f.fileno())
                except Exception:
                    pass
            ow = self._owner()
            if ow and self.euid == 0:
                try:
                    os.chown(tmp, ow[0], ow[1])
                except Exception:
                    pass
            os.chmod(tmp, 0o644)
            os.replace(tmp, path)
        finally:
            try:
                if os.path.exists(tmp):
                    os.unlink(tmp)
            except Exception:
                pass

    def _load(self, path, dflt):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return dflt

    def takeover(self):
        """Wie prepper-sdr: fehlt = aus, nur "on": true = an; unlesbar -> 2. Versuch, dann 'unklar' (Klon gesperrt)."""
        fn = self.c["takeover"]
        if not os.path.exists(fn):
            return "aus"
        for i in range(2):
            try:
                with open(fn, encoding="utf-8") as f:
                    d = json.load(f)
                return "an" if isinstance(d, dict) and d.get("on") is True else "aus"
            except Exception:
                time.sleep(0.3)
        return "unklar"

    def log(self, msg):
        try:
            line = "[%s] %s" % (time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(self.now())), str(msg)[:400])
            try:
                with open(self.c["log"], encoding="utf-8", errors="replace") as f:
                    old = f.read().splitlines()
            except Exception:
                old = []
            old.append(line)
            txt = "\n".join(old[-LOG_KEEP:]) + "\n"
            tmp = self.c["log"] + ".tmp-%d" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(txt)
            ow = self._owner()
            if ow and self.euid == 0:
                try:
                    os.chown(tmp, ow[0], ow[1])
                except Exception:
                    pass
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.c["log"])
        except Exception:
            pass

    def status(self, force=False, **kw):
        self.st.update(kw)
        t = self.now()
        if force or t - self.last_w >= 3:
            self.last_w = t
            try:
                self._write_json(self.c["status"], self.st)
            except Exception as e:
                self.log("Status schreiben: %s" % e)

    def hist_add(self, entry):
        try:
            h = self._load(self.c["hist"], [])
            h = [x for x in h if isinstance(x, dict)] if isinstance(h, list) else []
            h.insert(0, entry)
            self._write_json(self.c["hist"], h[:HIST_KEEP])
        except Exception as e:
            self.log("Verlauf schreiben: %s" % e)

    def avg_duration(self):
        try:
            h = self._load(self.c["hist"], [])
            ds = [float(x.get("duration_s")) for x in h if isinstance(x, dict) and x.get("ok") is True and isinstance(x.get("duration_s"), (int, float))]
            if not ds:
                for x in h:
                    m = re.match(r"^(\d+)m (\d+)s$", str((x or {}).get("duration") or "")) if isinstance(x, dict) and x.get("ok") is True else None
                    if m:
                        ds.append(int(m.group(1)) * 60 + int(m.group(2)))
            return sum(ds[:5]) / len(ds[:5]) if ds else None
        except Exception:
            return None

    def pid_alive(self, pid):
        try:
            return isinstance(pid, int) and pid > 0 and os.path.isdir(os.path.join(self.c["proc"], str(pid)))
        except Exception:
            return False

    # ---------- Sperren ----------
    def mount_source(self, target):
        rc, out, _ = self.run_cmd(["findmnt", "-n", "-o", "SOURCE", target], 20)
        return out.strip().splitlines()[0].strip() if rc == 0 and out.strip() else ""

    def mounts_of(self, dev):
        rc, out, _ = self.run_cmd(["findmnt", "-rn", "-o", "TARGET", "-S", dev], 20)
        return [x.strip() for x in out.splitlines() if x.strip()] if rc == 0 else []

    def blk_size(self, part):
        try:
            name = os.path.basename(part)
            disk = re.sub(r"p\d+$", "", name)
            with open(os.path.join(self.c["sysblock"], disk, name, "size")) as f:
                return int(f.read().strip()) * 512
        except Exception:
            return None

    def used_bytes(self, path):
        try:
            s = os.statvfs(path)
            return (s.f_blocks - s.f_bfree) * s.f_frsize
        except Exception:
            return None

    def checks(self):
        """-> Liste der Sperrgruende (leer = Klon erlaubt)."""
        why = []
        try:
            if self.euid != 0:
                why.append("nicht als root gestartet")
            root = self.mount_source(self.c["src_root"])
            dname = os.path.basename(self.c["dst_dev"])
            if not root:
                why.append("Root-Laufwerk nicht erkennbar")
            elif "mmcblk" in root or root.startswith(self.c["dst_dev"]):
                why.append("System laeuft von der SD-Karte (%s) - Klon SSD->SD wuerde die laufende Karte loeschen" % root)
            boot = self.mount_source(self.c["src_boot"])
            if boot and (dname in boot or "mmcblk" in boot):
                why.append("/boot/firmware liegt auf der SD-Karte (%s)" % boot)
            if not os.path.exists(os.path.join(self.c["sysblock"], dname)):
                why.append("SD-Karte %s fehlt" % self.c["dst_dev"])
            else:
                for p in (self.c["dst_boot"], self.c["dst_root"]):
                    if self.blk_size(p) is None:
                        why.append("Partition %s fehlt" % p)
                for p in (self.c["dst_boot"], self.c["dst_root"]):
                    for m in self.mounts_of(p):
                        if m in ("/", "/boot/firmware", "/boot"):
                            why.append("%s ist als %s eingehaengt" % (p, m))
                size = self.blk_size(self.c["dst_root"])
                used = self.used_bytes(self.c["src_root"])
                if size and used and used * 1.05 > size:
                    why.append("zu wenig Platz auf der SD (%d GB belegt, Ziel %d GB)" % (used // 10 ** 9, size // 10 ** 9))
            tk = self.takeover()
            if tk == "an":
                why.append("Stick-2-Uebernahme 5C aktiv (erst auf /funk zuruecksetzen)")
            elif tk == "unklar":
                why.append("sdr_takeover.json unlesbar - Uebernahme-Zustand unklar")
            g = self._load(self.c["gate"], {})
            if isinstance(g, dict) and g.get("alarm") is True and self.now() - float(g.get("t") or 0) <= GATE_FRESH_S:
                why.append("echter Alarm im Lagezentrum (%s)" % str(g.get("why") or "")[:60])
        except Exception as e:
            why.append("Pruefung fehlgeschlagen: %s" % str(e)[:120])
        return why

    # ---------- Schritte ----------
    def umount_all(self, step):
        for p in (self.c["dst_boot"], self.c["dst_root"]):
            for _ in range(3):
                ms = self.mounts_of(p)
                if not ms:
                    break
                for m in ms:
                    if m in ("/", "/boot/firmware", "/boot"):
                        raise CloneError(step, "%s ist als %s eingehaengt" % (p, m))
                    rc, _, err = self.run_cmd(["umount", m], 60)
                    self.log("aushaengen %s (%s): rc %d %s" % (m, p, rc, err.strip()[:120]))
                self.sleep(1)
            if self.mounts_of(p):
                raise CloneError(step, "%s laesst sich nicht aushaengen (%s)" % (p, ",".join(self.mounts_of(p))))

    def must(self, step, args, timeout=600):
        rc, out, err = self.run_cmd(args, timeout)
        if rc != 0:
            raise CloneError(step, "%s rc %d: %s" % (os.path.basename(args[0]), rc, (err or out).strip()[-200:]))
        return out

    def db_backup(self):
        step = "Sicherung lagezentrum.db"
        self.status(force=True, progress=P_DB - 1, step=step)
        os.makedirs(self.c["stage"], exist_ok=True)
        dst = os.path.join(self.c["stage"], "lagezentrum.db")
        for x in (dst, dst + "-wal", dst + "-shm", dst + "-journal"):
            try:
                os.unlink(x)
            except FileNotFoundError:
                pass
        if not os.path.exists(self.c["db"]):
            self.log("lagezentrum.db fehlt - keine Sicherung noetig")
            return None
        try:
            s = sqlite3.connect("file:%s?mode=ro" % self.c["db"], uri=True, timeout=30)
            d = sqlite3.connect(dst)
            try:
                s.backup(d)
                ok = d.execute("PRAGMA quick_check").fetchone()[0]
            finally:
                d.close()
                s.close()
        except Exception as e:
            raise CloneError(step, str(e)[:160])
        if ok != "ok":
            raise CloneError(step, "quick_check %s" % ok)
        self.log("lagezentrum.db gesichert (%d KB, quick_check ok)" % (os.path.getsize(dst) // 1024))
        return dst

    def swap_files(self):
        out = []
        try:
            with open(os.path.join(self.c["proc"], "swaps")) as f:
                for ln in f.read().splitlines()[1:]:
                    parts = ln.split()
                    if not parts:
                        continue
                    if len(parts) > 1 and parts[1] == "file":
                        out.append(parts[0])
                    m = re.match(r"^/dev/(loop\d+)$", parts[0])
                    if m:
                        try:
                            with open(os.path.join(self.c["sysblock"], m.group(1), "loop", "backing_file")) as g:
                                bf = g.read().strip()
                            if bf.startswith("/"):
                                out.append(bf.replace(" (deleted)", ""))
                        except Exception:
                            pass
        except Exception:
            pass
        for p in ("/swapfile", "/var/swap"):
            if os.path.isfile(p) and p not in out:
                out.append(p)
        return out

    def excludes(self):
        db = self.c["db"]
        ex = ["/dev/*", "/proc/*", "/sys/*", "/tmp/*", "/run/*", "/mnt/*", "/media/*", "/lost+found", "/boot/firmware/*",
              "/var/tmp/prepper-clone", "/var/log/journal/*", "/var/cache/apt/archives/*.deb",
              db, db + "-wal", db + "-shm", db + "-journal"]
        ex += self.swap_files()
        return ex

    def rsync(self, step, src, dst, p0, p1, extra=None):
        args = ["rsync", "-aAX", "--delete", "--info=progress2", "--no-inc-recursive"] + list(extra or []) + [src.rstrip("/") + "/", dst.rstrip("/") + "/"]
        self.status(force=True, progress=p0, step=step, eta_s=self.eta(None, p0))
        self.log("%s: %s" % (step, " ".join(args[:6]) + " ..."))
        p = self.popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        buf = b""
        tail = []
        rx = re.compile(r"^\s*[\d,.]+\s+(\d{1,3})%\s+(\S+)\s+(\d+):(\d{2}):(\d{2})")
        while True:
            ch = p.stdout.read(4096)
            if not ch:
                break
            buf += ch
            parts = re.split(rb"[\r\n]", buf)
            buf = parts.pop()
            for raw in parts:
                ln = raw.decode("utf-8", "replace")
                m = rx.match(ln)
                if m:
                    pct = min(100, int(m.group(1)))
                    eta = int(m.group(3)) * 3600 + int(m.group(4)) * 60 + int(m.group(5))
                    prog = p0 + (p1 - p0) * pct / 100.0
                    self.status(progress=int(prog), step="%s %d %%" % (step, pct), rate=m.group(2), eta_s=self.eta(eta if pct < 100 else 0, prog))
                elif ln.strip():
                    tail.append(ln.strip()[:200])
                    tail = tail[-20:]
        rc = p.wait()
        for ln in tail[-8:]:
            self.log("  rsync: %s" % ln)
        if rc not in RSYNC_OK:
            raise CloneError(step, "rsync rc %d: %s" % (rc, (tail[-1] if tail else "")[:160]))
        self.status(force=True, progress=p1, step=step + " fertig", rate=None)

    def eta(self, rsync_eta, prog):
        """Rest-Sekunden: im Root-Schritt rsync-ETA + Rest, sonst Mittel der letzten Laeufe minus bisher."""
        try:
            el = self.now() - (self.t0 or self.now())
            if rsync_eta is not None and prog >= P_ROOT0:
                return int(rsync_eta + 30)
            avg = self.avg_duration()
            if avg:
                return int(max(30, avg - el))
            return None
        except Exception:
            return None

    def finish_sd(self, db_copy):
        step = "Bootdateien SD anpassen"
        self.status(force=True, progress=96, step=step, eta_s=30)
        if db_copy:
            rel = self.c["db"].lstrip("/")
            tgt = os.path.join(self.c["mnt_root"], rel)
            os.makedirs(os.path.dirname(tgt), exist_ok=True)
            try:
                st = os.stat(self.c["db"])
            except Exception:
                st = None
            with open(db_copy, "rb") as a, open(tgt + ".tmp", "wb") as b:
                while True:
                    blk = a.read(1 << 20)
                    if not blk:
                        break
                    b.write(blk)
            if st is not None:
                try:
                    os.chown(tgt + ".tmp", st.st_uid, st.st_gid)
                    os.chmod(tgt + ".tmp", st.st_mode & 0o777)
                except Exception:
                    pass
            os.replace(tgt + ".tmp", tgt)
            self.log("lagezentrum.db (Sicherung) auf SD gelegt")
        pu = self.must(step, ["blkid", "-s", "PARTUUID", "-o", "value", self.c["dst_root"]], 30).strip()
        bu = self.must(step, ["blkid", "-s", "UUID", "-o", "value", self.c["dst_boot"]], 30).strip()
        ru = self.must(step, ["blkid", "-s", "UUID", "-o", "value", self.c["dst_root"]], 30).strip()
        if not (pu and bu and ru):
            raise CloneError(step, "PARTUUID/UUID der SD nicht lesbar")
        cl = os.path.join(self.c["mnt_boot"], "cmdline.txt")
        try:
            with open(cl, encoding="utf-8") as f:
                txt = f.read()
        except Exception as e:
            raise CloneError(step, "cmdline.txt fehlt auf der SD (%s)" % e)
        new, n = re.subn(r"root=\S+", "root=PARTUUID=%s" % pu, txt, count=1)
        if n != 1:
            raise CloneError(step, "cmdline.txt ohne root=")
        with open(cl + ".tmp", "w", encoding="utf-8") as f:
            f.write(new)
        os.replace(cl + ".tmp", cl)
        fst = os.path.join(self.c["mnt_root"], "etc", "fstab")
        os.makedirs(os.path.dirname(fst), exist_ok=True)
        with open(fst + ".tmp", "w", encoding="utf-8") as f:
            f.write("proc            /proc           proc    defaults          0       0\n"
                    "UUID=%s  /boot/firmware  vfat    defaults          0       2\n"
                    "UUID=%s  /               ext4    defaults,noatime  0       1\n" % (bu, ru))
        os.replace(fst + ".tmp", fst)
        for d in ("dev", "proc", "sys", "tmp", "run", "mnt", "media", "boot/firmware"):
            try:
                os.makedirs(os.path.join(self.c["mnt_root"], d), exist_ok=True)
            except Exception:
                pass
        try:
            os.chmod(os.path.join(self.c["mnt_root"], "tmp"), 0o1777)
        except Exception:
            pass
        self.log("cmdline.txt root=PARTUUID=%s, fstab (boot %s, root %s)" % (pu, bu, ru))

    def cleanup(self):
        for m in reversed(self.mounted):
            try:
                self.run_cmd(["sync"], 300)
                self.run_cmd(["umount", m], 120)
            except Exception:
                pass
        self.mounted = []
        for m in (self.c["mnt_boot"], self.c["mnt_root"]):
            try:
                os.rmdir(m)
            except Exception:
                pass

    # ---------- Haupt ----------
    def stale_fix(self):
        old = self._load(self.c["status"], {})
        if isinstance(old, dict) and old.get("state") == "running" and not self.pid_alive(old.get("pid")):
            why = "abgebrochen (Prozess weg)" if old.get("pid") else "abgebrochen (alter Lauf ohne Abschluss)"
            self.hist_add({"started": old.get("started"), "finished": None, "duration": None, "ok": False, "why": why,
                           "step": old.get("step"), "v": V})
            self.log("alter Lauf ohne Abschluss nachgetragen: %s (Schritt %s)" % (why, old.get("step")))
            old.update(state="error", ok=False, why=why)
            try:
                self._write_json(self.c["status"], old)
            except Exception:
                pass

    def refuse(self, why):
        self.log("Klon abgelehnt: %s" % "; ".join(why))
        old = self._load(self.c["status"], {})
        old = old if isinstance(old, dict) else {}
        if old.get("state") != "running":
            old["last_refused"] = {"t": int(self.now()), "why": why[:5]}
            try:
                self._write_json(self.c["status"], old)
            except Exception:
                pass

    def run(self):
        lk = None
        try:
            lk = open(self.c["lock"], "w")
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.log("Klon laeuft schon (Sperre %s belegt) - nichts gestartet" % self.c["lock"])
            return 3
        try:
            self.stale_fix()
            why = self.checks()
            if why:
                self.refuse(why)
                return 10
            return self._clone()
        finally:
            try:
                lk.close()
            except Exception:
                pass

    def _clone(self):
        self.t0 = self.now()
        start = _now_iso(self.t0)
        self.st = {"state": "running", "progress": 1, "started": start, "pid": os.getpid(), "v": V, "step": "Start", "eta_s": self.eta(None, 1), "ok": None}
        self.status(force=True)
        self.log("Klon v%d gestartet (SSD -> SD %s)" % (V, self.c["dst_dev"]))
        step = "Start"
        try:
            db_copy = self.db_backup()
            step = "Automount aushaengen"
            self.status(force=True, progress=P_DB, step=step)
            self.umount_all(step)
            step = "SD formatieren"
            self.status(force=True, progress=P_DB + 1, step=step)
            self.must(step, ["mkfs.vfat", "-F", "32", "-n", "bootfs", self.c["dst_boot"]], 300)
            self.umount_all(step)
            self.must(step, ["mkfs.ext4", "-F", "-q", "-L", "rootfs", self.c["dst_root"]], 900)
            step = "SD einhaengen"
            self.status(force=True, progress=P_MKFS, step=step)
            self.umount_all(step)
            for d, m in ((self.c["dst_boot"], self.c["mnt_boot"]), (self.c["dst_root"], self.c["mnt_root"])):
                os.makedirs(m, exist_ok=True)
                self.must(step, ["mount", d, m], 120)
                self.mounted.append(m)
            step = "Kopie /boot/firmware"
            self.rsync(step, self.c["src_boot"], self.c["mnt_boot"], P_BOOT0, P_BOOT1)
            step = "Kopie System"
            ex = []
            for x in self.excludes():
                ex += ["--exclude", x]
            self.rsync(step, self.c["src_root"], self.c["mnt_root"], P_ROOT0, P_ROOT1, ["-H", "--numeric-ids"] + ex)
            step = "Bootdateien SD anpassen"
            self.finish_sd(db_copy)
            step = "Abschluss"
            self.status(force=True, progress=98, step="sync + aushaengen", eta_s=20)
            self.must(step, ["sync"], 900)
            for m in reversed(self.mounted):
                self.must(step, ["umount", m], 300)
            self.mounted = []
            for m in (self.c["mnt_boot"], self.c["mnt_root"]):
                try:
                    os.rmdir(m)
                except Exception:
                    pass
            t1 = self.now()
            d = t1 - self.t0
            self.st.update(state="done", progress=100, finished=_now_iso(t1), duration_s=int(d), duration=_dur(d), ok=True, step="fertig", eta_s=0, why=None)
            self.status(force=True)
            self.hist_add({"started": start, "finished": _now_iso(t1), "duration": _dur(d), "duration_s": int(d), "ok": True, "v": V})
            self.log("Clone OK %s (%s)" % (time.strftime("%a %d. %b %H:%M:%S", time.localtime(t1)), _dur(d)))
            return 0
        except BaseException as e:
            if isinstance(e, CloneError):
                stp, why = e.step, e.why
            elif isinstance(e, KeyboardInterrupt):
                stp, why = step, "abgebrochen (Signal)"
            else:
                stp, why = step, "%s: %s" % (type(e).__name__, str(e)[:160])
            self.cleanup()
            t1 = self.now()
            d = t1 - self.t0
            self.st.update(state="error", finished=_now_iso(t1), duration_s=int(d), duration=_dur(d), ok=False, step=stp, why=why, eta_s=None)
            self.status(force=True)
            self.hist_add({"started": start, "finished": _now_iso(t1), "duration": _dur(d), "duration_s": int(d), "ok": False, "step": stp, "why": why[:160], "v": V})
            self.log("Clone FEHLER im Schritt %s: %s" % (stp, why))
            return 1


def _sig(*_):
    raise KeyboardInterrupt()


def detach(c):
    """Klon in eigener Einheit (prepper-clone) starten - ueberlebt Dashboard-Neustarts."""
    why = c.checks()
    if why:
        try:
            lk = open(c.c["lock"], "w")
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
            c.refuse(why)
            lk.close()
        except OSError:
            pass
        print("gesperrt: " + "; ".join(why))
        return 10
    if not os.path.exists("/usr/bin/systemd-run") and not os.path.exists("/bin/systemd-run"):
        return c.run()
    rc, out, err = c.run_cmd(["systemd-run", "--unit", c.c["unit"], "--collect", "--quiet", "--description",
                              "Prepper Klon SSD -> SD (sysBoot)", "--setenv=PREPPER_CLONE_DETACHED=1",
                              "/usr/bin/python3", c.c["self"], "--foreground"], 60)
    if rc != 0:
        c.log("systemd-run rc %d: %s" % (rc, (err or out).strip()[:200]))
        print("nicht gestartet: %s" % (err or out).strip()[:200])
        return 3
    print("gestartet (Einheit %s)" % c.c["unit"])
    return 0


# ---------------------------------------------------------------- Selbsttest (Fake-Befehle, Temp-Verzeichnis)
def selftest():
    import shutil
    import tempfile
    base = tempfile.mkdtemp(prefix="clone-st-")
    try:
        dash = os.path.join(base, "dash")
        sysb = os.path.join(base, "sys")
        prc = os.path.join(base, "proc")
        for d in (dash, prc, os.path.join(sysb, "mmcblk0", "mmcblk0p1"), os.path.join(sysb, "mmcblk0", "mmcblk0p2"), os.path.join(sysb, "loop0", "loop")):
            os.makedirs(d, exist_ok=True)
        open(os.path.join(sysb, "mmcblk0", "mmcblk0p1", "size"), "w").write("1048576\n")
        open(os.path.join(sysb, "mmcblk0", "mmcblk0p2", "size"), "w").write("%d\n" % (118 * 10 ** 9 // 512))
        open(os.path.join(sysb, "loop0", "loop", "backing_file"), "w").write("/var/swap.img\n")
        open(os.path.join(prc, "swaps"), "w").write("Filename Type Size Used Priority\n/dev/zram0 partition 2 0 100\n/dev/loop0 partition 2 0 -2\n")
        db = os.path.join(dash, "lagezentrum.db")
        con = sqlite3.connect(db)
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("create table t(x)")
        con.execute("insert into t values (42)")
        con.commit()
        mb, mr = os.path.join(base, "mnt", "b"), os.path.join(base, "mnt", "r")
        cfg = {"dash": dash, "status": dash + "/clone_status.json", "log": dash + "/clone.log", "hist": dash + "/clone_history.json",
               "takeover": dash + "/sdr_takeover.json", "gate": dash + "/sdr_wd_gate.json", "db": db, "lock": base + "/lock",
               "stage": base + "/stage", "sysblock": sysb, "proc": prc, "mnt_boot": mb, "mnt_root": mr, "src_root": "/", "src_boot": "/boot/firmware"}
        json.dump([{"started": "2026-10-16T17:42:17+02:00", "finished": "2026-10-16T18:14:08+02:00", "duration": "31m 51s", "ok": True}], open(cfg["hist"], "w"))
        state = {"root": "/dev/sda2", "boot": "/dev/sda1", "mounts": {"/dev/mmcblk0p1": ["/media/fmg/bootfs"]}, "calls": [], "fail": None, "rsync_rc": 0}

        def run(args, timeout=600):
            state["calls"].append(list(args))
            a0 = args[0]
            if state["fail"] and a0 == state["fail"]:
                return 1, "", "kaputt (Test)"
            if a0 == "findmnt" and args[1] == "-n":
                return 0, (state["root"] if args[-1] == "/" else state["boot"]) + "\n", ""
            if a0 == "findmnt":
                return 0, "\n".join(state["mounts"].get(args[-1], [])), ""
            if a0 == "umount":
                for k, v in state["mounts"].items():
                    if args[1] in v:
                        v.remove(args[1])
                return 0, "", ""
            if a0 == "mount":
                os.makedirs(args[2], exist_ok=True)
                if args[2] == mb:
                    open(os.path.join(mb, "cmdline.txt"), "w").write("console=serial0,115200 root=PARTUUID=aaaa-02 rootfstype=ext4 fsck.repair=yes rootwait\n")
                return 0, "", ""
            if a0 == "blkid":
                return 0, {"PARTUUID": "c0ffee-02", "UUID": "1234-ABCD" if args[-1].endswith("p1") else "5555-6666"}[args[2]] + "\n", ""
            return 0, "", ""

        class FakeP:
            def __init__(self, args, **kw):
                state["calls"].append(list(args))
                if "-H" in args:
                    state["root_args"] = list(args)
                txt = "\r      1,000   1%    1.00MB/s    0:30:00 (xfr#1, to-chk=9/10)\r  500,000,000  50%   20.00MB/s    0:15:00 (xfr#5, to-chk=5/10)\r" \
                      "1,000,000,000 100%   20.00MB/s    0:31:00 (xfr#10, to-chk=0/10)\nrsync warning: some files vanished\n"
                import io
                self.stdout = io.BytesIO(txt.encode())
                self.rc = state["rsync_rc"]

            def wait(self):
                return self.rc

        clock = [1792600000.0]

        def now():
            clock[0] += 1.0
            return clock[0]

        mk = lambda: Clone(cfg, run=run, popen=FakeP, now=now, euid=0, sleep=lambda s: None)
        # 1) alles gut
        c = mk()
        assert c.checks() == [], c.checks()
        assert c.run() == 0
        st = json.load(open(cfg["status"]))
        assert st["state"] == "done" and st["ok"] is True and st["progress"] == 100, st
        h = json.load(open(cfg["hist"]))
        assert h[0]["ok"] is True and len(h) == 2
        cl = open(os.path.join(mb, "cmdline.txt")).read()
        assert "root=PARTUUID=c0ffee-02 " in cl and cl.count("root=") == 1
        assert "UUID=5555-6666  /" in open(os.path.join(mr, "etc", "fstab")).read()
        r = state["root_args"]
        for x in (db, db + "-wal", db + "-shm", "/var/swap.img", "/proc/*", "/media/*", "/boot/firmware/*"):
            assert x in r, x
        assert "/boot" not in r
        cp = os.path.join(mr, db.lstrip("/"))
        assert sqlite3.connect(cp).execute("select x from t").fetchone()[0] == 42
        assert ["umount", "/media/fmg/bootfs"] in state["calls"]
        mk_i = [i for i, x in enumerate(state["calls"]) if x[0] == "mkfs.vfat"][0]
        um_i = [i for i, x in enumerate(state["calls"]) if x == ["umount", "/media/fmg/bootfs"]][0]
        assert um_i < mk_i
        # 2) Sperren
        state["root"] = "/dev/mmcblk0p2"
        assert any("SD-Karte" in w for w in mk().checks())
        n_calls = len(state["calls"])
        assert mk().run() == 10 and not any(x[0].startswith("mkfs") for x in state["calls"][n_calls:])
        assert json.load(open(cfg["status"]))["last_refused"]["why"]
        state["root"] = "/dev/sda2"
        json.dump({"on": True, "since": 1}, open(cfg["takeover"], "w"))
        assert any("Uebernahme" in w for w in mk().checks())
        for raw, want in (('{"on": "true"}', None), ('{"on": false}', None), ('[1]', None), ('{"on": tr', "unlesbar")):
            with open(cfg["takeover"], "w") as f:
                f.write(raw)
            w = [x for x in mk().checks() if "Uebernahme" in x or "unlesbar" in x]
            assert (w == []) if want is None else any(want in x for x in w), (raw, w)
        os.unlink(cfg["takeover"])
        json.dump({"t": clock[0], "alarm": True, "why": "NINA"}, open(cfg["gate"], "w"))
        assert any("Alarm" in w for w in mk().checks())
        json.dump({"t": clock[0] - 3600, "alarm": True, "why": "alt"}, open(cfg["gate"], "w"))
        assert mk().checks() == []
        shutil.rmtree(os.path.join(sysb, "mmcblk0"))
        assert any("fehlt" in w for w in mk().checks())
        os.makedirs(os.path.join(sysb, "mmcblk0", "mmcblk0p1"))
        os.makedirs(os.path.join(sysb, "mmcblk0", "mmcblk0p2"))
        open(os.path.join(sysb, "mmcblk0", "mmcblk0p1", "size"), "w").write("1048576\n")
        open(os.path.join(sysb, "mmcblk0", "mmcblk0p2", "size"), "w").write("%d\n" % (118 * 10 ** 9 // 512))
        assert Clone(cfg, run=run, popen=FakeP, now=now, euid=1000).checks()
        # 3) Sperre belegt
        lk = open(cfg["lock"], "w")
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert mk().run() == 3
        lk.close()
        # 4) Fehler -> state error + Verlauf ok:false, Aufraeumen
        state["fail"] = "mkfs.ext4"
        assert mk().run() == 1
        st = json.load(open(cfg["status"]))
        assert st["state"] == "error" and st["ok"] is False and st["step"] == "SD formatieren" and "kaputt" in st["why"], st
        assert json.load(open(cfg["hist"]))[0]["ok"] is False
        state["fail"] = None
        state["rsync_rc"] = 23
        assert mk().run() == 1 and json.load(open(cfg["status"]))["step"] == "Kopie /boot/firmware"
        state["rsync_rc"] = 24
        assert mk().run() == 0
        # 5) haengender Lauf wird nachgetragen
        json.dump({"state": "running", "progress": 40, "pid": 999999, "step": "Kopie System", "started": "x"}, open(cfg["status"], "w"))
        n = len(json.load(open(cfg["hist"])))
        mk().stale_fix()
        h = json.load(open(cfg["hist"]))
        assert h[0]["ok"] is False and "Prozess weg" in h[0]["why"] and len(h) == min(10, n + 1)
        # 6) Verlauf hoechstens 10
        for _ in range(12):
            mk().hist_add({"ok": True, "duration_s": 1800})
        assert len(json.load(open(cfg["hist"]))) == 10
        # 7) ETA / Fortschritt aus rsync
        c = mk()
        c.t0 = now()
        assert c.eta(900, 50) == 930 and c.eta(None, 3) and c.eta(None, 3) > 1000
        con.close()
        print("clone v2 selftest ok (Sperren SD-Boot/SD fehlt/Uebernahme (robust: nur on=true, kaputt=gesperrt)/Alarm frisch/kein root/Sperre belegt, Automount vor mkfs aus, "
              "DB-Sicherung statt live db/wal/shm, Swap ausgenommen, rsync-Fortschritt+ETA, Fehler -> state error + Verlauf ok:false, rsync 24 ok/23 Fehler, "
              "haengender Lauf nachgetragen, Verlauf max 10, cmdline PARTUUID + fstab)")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    c = Clone()
    if argv == ["--check"]:
        why = c.checks()
        print(json.dumps({"ok": not why, "why": why, "v": V}, ensure_ascii=False))
        return 0 if not why else 10
    if c.euid != 0:
        print("nur als root (sudo)", file=sys.stderr)
        return 8
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGHUP, _sig)
    if argv == ["--foreground"] or os.environ.get("PREPPER_CLONE_DETACHED") == "1":
        return c.run()
    if argv:
        print("Aufruf: prepper-clone-ssd-to-sd [--foreground|--check|--selftest]", file=sys.stderr)
        return 2
    return detach(c)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(1)
SBK_EOF
PF="$W/src/patch-sysboot.py"; BL="$W/src/sb_lz_block.py"; BD="$W/src/sb_disk_block.py"; BM="$W/src/sb_main_block.py"
GD="$W/src/guard_sb.py"; CK="$W/src/sbcheck.py"; MS="$W/src/sbmesh.py"
NWD="$W/src/watchdog.py"; NHC="$W/src/health_check.py"; NMH="$W/src/mesh_hang_watchdog.py"; NCL="$W/src/prepper-clone-ssd-to-sd"
for x in "$EXPECT_PF $PF" "$EXPECT_BL $BL" "$EXPECT_BD $BD" "$EXPECT_BM $BM" "$EXPECT_GD $GD" "$EXPECT_CK $CK" "$EXPECT_MS $MS" "$EXPECT_WD $NWD" "$EXPECT_HC $NHC" "$EXPECT_MH $NMH" "$EXPECT_CL $NCL"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
for x in "$F" "$WDF" "$HCF" "$MHF"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
D16=$(s16 "$F"); WD16=$(s16 "$WDF"); HC16=$(s16 "$HCF"); MH16=$(s16 "$MHF")
basis() { # $1 Name $2 ist $3 alt $4 neu
  if [[ "$2" == "$3" ]]; then echo "Basis $1 sha16 $2 bekannt (vor sysBoot)"; elif [[ "$2" == "$4" ]]; then echo "Basis $1 sha16 $2 bekannt (sysBoot schon drin)";
  else echo "STOP: $1 sha16 $2 unbekannt (erwartet $3 oder $4) - nichts geaendert"; exit 1; fi
}
basis dashboard.py "$D16" "$KNOWN_D16" "$KNOWN_D16N"; echo "   $(wc -l < "$F") Zeilen"
basis watchdog.py "$WD16" "$KNOWN_WD16" "$KNOWN_WD16N"
basis health_check.py "$HC16" "$KNOWN_HC16" "$KNOWN_HC16N"
basis mesh_hang_watchdog.py "$MH16" "$KNOWN_MH16" "$KNOWN_MH16N"
SDHS=""; for c in "$DASH_DIR/prepper-sd-health.py" /usr/local/bin/prepper-sd-health.py /usr/local/sbin/prepper-sd-health.py /usr/local/bin/prepper-sd-health /usr/local/sbin/prepper-sd-health; do [[ -f "$c" ]] && SDHS="$SDHS $c=$(s16 "$c")"; done
echo "prepper-sd-health:${SDHS:- nicht gefunden} - bleibt unveraendert (neue SSD-Kachel haengt nicht davon ab, nutzt nur sd_health.json falls vorhanden)"
CL_OLD16=$([[ -f "$CLONE" ]] && s16 "$CLONE" || echo fehlt)
echo "Clone-Skript $CLONE vorher: sha16 $CL_OLD16$([[ "$CL_OLD16" == "$KNOWN_CL16N" ]] && echo ' (v2 schon drin)' || echo ' -> wird v2')"
a=$(systemctl is-active prepper-dashboard 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: prepper-dashboard ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
# Klon laeuft? -> nichts anfassen
if systemctl is-active --quiet prepper-clone 2>/dev/null; then echo "STOP: Klon laeuft gerade (Einheit prepper-clone) - bitte danach erneut, nichts geaendert"; exit 1; fi
if pgrep -f "prepper-clone-ssd-to-sd" >/dev/null 2>&1; then echo "STOP: Klon-Prozess laeuft gerade - bitte danach erneut, nichts geaendert"; exit 1; fi
if [[ -f "$DASH_DIR/clone_status.json" ]]; then
  CR=$(python3 -c "
import json,os,sys
try:
    d=json.load(open(sys.argv[1]))
    p=int(d.get('pid') or 0)
    print('running' if d.get('state')=='running' and p>0 and os.path.exists('/proc/%d'%p) else 'no')
except Exception:
    print('no')" "$DASH_DIR/clone_status.json")
  [[ "$CR" == running ]] && { echo "STOP: clone_status.json meldet laufenden Klon - nichts geaendert"; exit 1; }
fi
DU=$(systemctl show -p User --value prepper-dashboard 2>/dev/null || true); [[ -z "$DU" ]] && DU=root
if ! [[ "$DU" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "STOP: Benutzer von prepper-dashboard unklar ($DU) - nichts geaendert"; exit 1; fi
echo "prepper-dashboard laeuft als $DU"
asu() { if [[ "$(id -un)" == "$DU" ]]; then setsid -w "$@" < /dev/null; else sudo -n -u "$DU" setsid -w "$@" < /dev/null; fi; }
miss=""; for t in rsync mkfs.vfat mkfs.ext4 systemd-run blkid findmnt lsblk; do command -v "$t" >/dev/null 2>&1 || [[ -x "/usr/sbin/$t" || -x "/sbin/$t" ]] || miss="$miss $t"; done
[[ -z "$miss" ]] && echo "OK Klon-Werkzeuge vorhanden (rsync, mkfs.vfat, mkfs.ext4, systemd-run, blkid, findmnt, lsblk)" || echo "HINWEIS Klon-Werkzeuge fehlen:$miss (Klon meldet dann einen klaren Fehler; nichts automatisch installiert)"
SM=$(command -v smartctl 2>/dev/null || true); [[ -z "$SM" && -x /usr/sbin/smartctl ]] && SM=/usr/sbin/smartctl
[[ -n "$SM" ]] && echo "smartctl: $SM ($("$SM" --version 2>/dev/null | head -1 | cut -c1-60))" || echo "HINWEIS smartctl fehlt (Paket smartmontools) - SMART-Zeile zeigt 'nicht lesbar', sonst alles normal"
ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null || true); RDISK=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | head -1 || true)
[[ -z "$RDISK" && "$(lsblk -dno TYPE "$ROOTSRC" 2>/dev/null || true)" == disk ]] && RDISK=$(basename "$ROOTSRC")
echo "Root $ROOTSRC (Laufwerk ${RDISK:-?}), /boot/firmware $(findmnt -n -o SOURCE /boot/firmware 2>/dev/null || echo ?), BOOT_ORDER $(vcgencmd bootloader_config 2>/dev/null | sed -n 's/^BOOT_ORDER=//p' | head -1 || true)"
echo "sudo wird gebraucht (Regeln pruefen, spaeter einspielen):"
sudo -v || { echo "STOP: sudo nicht verfuegbar - nichts geaendert"; exit 1; }
# ---------- 2) Trockenlauf ----------
python3 "$PF" "$F" "$W/work/dashboard.py" "$W/src" > "$W/p0.log" 2>&1 || { cat "$W/p0.log"; echo "STOP: dashboard.py Stellen nicht gefunden - nichts geaendert"; exit 1; }
python3 "$PF" "$W/work/dashboard.py" "$W/work/x.py" "$W/src" >/dev/null 2>&1 && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || { echo "STOP: Patcher nicht idempotent - nichts geaendert"; exit 1; }
rm -f "$W/work/x.py"
cp "$NWD" "$NHC" "$NMH" "$W/work/"
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] && echo "OK $(cat "$W/p0.log") -> dashboard.py sha16 $ND16 wie erwartet ($(wc -l < "$W/work/dashboard.py") Zeilen)" || { echo "STOP: Ergebnis dashboard.py sha16 $ND16 statt $KNOWN_D16N - nichts geaendert"; exit 1; }
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/watchdog.py" "$W/work/health_check.py" "$W/work/mesh_hang_watchdog.py" "$MS"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
  "$py" -W error -c "import sys; compile(open(sys.argv[1]).read(), 'clone', 'exec')" "$NCL" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: Clone-Skript ($py) - nichts geaendert"; exit 1; }
done
echo "OK py_compile ohne Warnung (beide Pythons): dashboard, watchdog, health_check, mesh_hang_watchdog, Clone v2, meshClean"
python3 "$GD" dash "$F" "$W/work/dashboard.py" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard dashboard - nichts geaendert"; exit 1; }
echo "OK $(cat "$W/g.log")"
for k in "watchdog.py $WDF" "health_check.py $HCF" "mesh_hang_watchdog.py $MHF"; do set -- $k
  python3 "$GD" py "$2" "$W/work/$1" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard $1 - nichts geaendert"; exit 1; }
  echo "OK $(cat "$W/g.log")"
done
grep -q '"ping_svc": None,  # sysBoot meshClean' "$W/work/mesh_hang_watchdog.py" || { echo "STOP: mesh_hang_watchdog ping_svc - nichts geaendert"; exit 1; }
for py in "$SPY" "$VPY"; do
  (cd "$W" && "$py" -W error "$W/work/watchdog.py" --selftest-fake > "$W/st.log" 2>&1) || { cat "$W/st.log"; echo "STOP: Selbsttest watchdog ($py) - nichts geaendert"; exit 1; }; S1=$(tail -1 "$W/st.log")
  (cd "$W" && "$py" -W error "$W/work/health_check.py" --selftest-fake > "$W/st.log" 2>&1) || { cat "$W/st.log"; echo "STOP: Selbsttest health_check ($py) - nichts geaendert"; exit 1; }; S2=$(tail -1 "$W/st.log")
  (cd "$W" && "$py" "$NCL" --selftest > "$W/st.log" 2>&1) || { tail -8 "$W/st.log"; echo "STOP: Selbsttest Clone v2 ($py) - nichts geaendert"; exit 1; }; S3=$(tail -1 "$W/st.log")
  (cd "$W" && "$py" -W error "$MS" selftest > "$W/st.log" 2>&1) || { tail -8 "$W/st.log"; echo "STOP: Selbsttest meshClean ($py) - nichts geaendert"; exit 1; }; S4=$(tail -1 "$W/st.log")
done
echo "OK Selbsttests mit Fakes (beide Pythons; nichts neu gestartet, nichts geklont, nichts gesendet):"
echo "   $S1"; echo "   $S2"; echo "   $(echo "$S3" | cut -c1-260)"; echo "   $S4"
if command -v node >/dev/null 2>&1; then
  python3 - "$W/work/dashboard.py" "$W" << 'JSPY' || { echo "STOP: JavaScript fehlerhaft - nichts geaendert"; exit 1; }
import ast, re, subprocess, sys
want = ("_DT_JS", "_SB_BANNER", "_SB_LOADING_PAGE")
n_ok = 0
for n in ast.parse(open(sys.argv[1], encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in want and isinstance(n.value, ast.Constant):
        v = "\n;\n".join(re.findall(r"<script[^>]*>(.*?)</script>", n.value.value, re.S))
        f = "%s/%s.js" % (sys.argv[2], n.targets[0].id)
        open(f, "w", encoding="utf-8").write(v)
        if not v.strip() or subprocess.run(["node", "--check", f]).returncode:
            raise SystemExit(1)
        n_ok += 1
if n_ok != len(want):
    raise SystemExit("JS-Bloecke %d/%d" % (n_ok, len(want)))
JSPY
  echo "OK JavaScript (Clone-Knopf, Ladehinweis) syntaktisch geprueft (node)"
fi
python3 "$MS" plan "$DASH_DIR" > "$W/mp.log" 2>&1 || { cat "$W/mp.log"; echo "STOP: meshClean-Plan - nichts geaendert"; exit 1; }
echo "meshClean Plan:"; sed 's/^/   /' "$W/mp.log"
printf '# sysBoot: Dashboard erst nach dem Netz starten (Erst-Update braucht Netz); Start selbst wartet nicht mehr\n[Unit]\nWants=network-online.target\nAfter=network-online.target\n' > "$W/ddrop"
printf '# sysBoot: Journal dauerhaft (nach Neustart noch lesbar), hoechstens 200 MB\n[Journal]\nStorage=persistent\nSystemMaxUse=200M\n' > "$W/jdrop"
# Watchdog-Einheit: darf sie 6 min nachpruefen?
WDU=""; for u in $(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -E 'watchdog|prepper' || true); do
  [[ "$u" == mesh-hang* || "$u" == *@* ]] && continue
  if systemctl cat "$u" 2>/dev/null | grep -E '^ExecStart=' | grep -qE "[/ ]watchdog\.py( |$)"; then WDU="$u"; break; fi
done
WDDROP=""; WDT=""
if [[ -n "$WDU" ]]; then
  WDT=$(systemctl show -p TimeoutStartUSec --value "$WDU" 2>/dev/null || true)
  WDS=$(python3 -c "
import re,sys
v=sys.argv[1].strip()
if not v or v=='infinity': print(99999); raise SystemExit
t=0.0
for n,u in re.findall(r'(\d+(?:\.\d+)?)\s*(min|ms|us|s|h)?', v): t+=float(n)*{'h':3600,'min':60,'s':1,'ms':0.001,'us':1e-6}.get(u or 's',1)
print(int(t))" "$WDT")
  echo "Watchdog-Einheit $WDU: TimeoutStartSec $WDT"
  if [[ "$WDS" -lt 420 ]] || [[ -f "/etc/systemd/system/$WDU.d/zz-sysboot.conf" ]]; then
    WDDROP="/etc/systemd/system/$WDU.d/zz-sysboot.conf"
    printf '# sysBoot: watchdog.py prueft nach einem Neustart bis 6 min nach - Einheit darf 8 min laufen\n[Service]\nTimeoutStartSec=8min\n' > "$W/wddrop"
  fi
else
  echo "HINWEIS Einheit mit $DASH_DIR/watchdog.py nicht gefunden (Cron?) - watchdog.py begrenzt die Nachpruefung selbst"
fi
HCT=$(systemctl show -p TimeoutStartUSec --value prepper-health.service 2>/dev/null || true)
echo "prepper-health.service TimeoutStartSec ${HCT:-?} (health_check wartet nur so lange, wie die Einheit darf; sonst bleibt der letzte Bericht)"
SMNEED=0
if [[ -n "$SM" && -n "$RDISK" && "$DU" != root ]]; then
  if sudo -n -l -U "$DU" "$SM" -d sat -H -A "/dev/$RDISK" >/dev/null 2>&1 && sudo -n -l -U "$DU" "$SM" -H -A "/dev/$RDISK" >/dev/null 2>&1; then
    echo "OK smartctl -H -A / -d sat -H -A fuer $DU schon erlaubt (vorhandene Regel)"
  else
    SMNEED=1
    printf '# sysBoot: Dashboard (%s) darf SMART lesen (nur Lesen, feste Argumente), sonst nichts\n%s ALL=(root) NOPASSWD: %s -H -A /dev/sd[a-z], %s -d sat -H -A /dev/sd[a-z], %s -A /dev/sd[a-z], %s -H -A /dev/nvme[0-9]n[0-9], %s -A /dev/nvme[0-9]n[0-9]\n' \
      "$DU" "$DU" "$SM" "$SM" "$SM" "$SM" "$SM" > "$W/smrule"
    python3 "$CK" smartrule "$W/smrule" "$DU" "$SM" > "$W/ck.log" 2>&1 || { cat "$W/ck.log"; echo "STOP: smartctl-Regel falsch - nichts geaendert"; exit 1; }
    visudo -cf "$W/smrule" > "$W/vis.log" 2>&1 || { cat "$W/vis.log"; echo "STOP: visudo -cf lehnt die smartctl-Regel ab - nichts geaendert"; exit 1; }
    echo "OK smartctl-Regel vorbereitet (visudo -cf): $(cat "$W/ck.log")"
  fi
fi
echo "OK Trockenlauf idempotent"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status /api/clone/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert) ----------
trap '' INT
sudo -v
same_sys() { sudo -n cmp -s "$1" "$2" 2>/dev/null; }
U_SAME=1
for x in dashboard.py:"$F" watchdog.py:"$WDF" health_check.py:"$HCF" mesh_hang_watchdog.py:"$MHF"; do n=${x%%:*}; f=${x#*:}; cmp -s "$W/work/$n" "$f" || U_SAME=0; done
same_sys "$NCL" "$CLONE" && [[ "$(stat -c '%U:%G %a' "$CLONE" 2>/dev/null)" == "root:root 755" ]] || U_SAME=0
same_sys "$W/ddrop" "$DDROP" || U_SAME=0
same_sys "$W/jdrop" "$JDROP" || U_SAME=0
[[ -z "$WDDROP" ]] || same_sys "$W/wddrop" "$WDDROP" || U_SAME=0
[[ "$SMNEED" == 0 ]] || U_SAME=0
grep -q "^archivieren" "$W/mp.log" && U_SAME=0
grep -E -- "-> deaktivieren" "$W/mp.log" | grep -qv "schon maskiert" && U_SAME=0
RESTARTED=0; MC_DONE=0
SYSF=("$CLONE" "$DDROP" "$JDROP" "$SMRULE"); [[ -n "$WDDROP" ]] && SYSF+=("$WDDROP")
declare -A HAD
if [[ "$U_SAME" == 1 ]]; then
  echo "OK sysBoot schon installiert (4 Dateien, Clone v2, Drop-ins, meshClean) - kein Neustart"
  T0=$(date +%s)
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  mkdir -p "$W/old"
  for s in "${SYSF[@]}"; do k=$(echo "$s" | tr '/' '_'); if sudo -n test -e "$s"; then sudo -n cat "$s" > "$W/old/$k"; HAD[$s]="$(sudo -n stat -c '%a' "$s")"; else HAD[$s]=""; fi; done
  JRESTART=0
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sysBoot|diskTiles2|Traceback" | tail -6 | cut -c1-200 || true
    for x in "$F" "$WDF" "$HCF" "$MHF"; do [[ -f "$x.bak-sysboot-$TS" ]] && cp -a "$x.bak-sysboot-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    for s in "${SYSF[@]}"; do k=$(echo "$s" | tr '/' '_')
      if [[ -n "${HAD[$s]}" ]]; then sudo install -o root -g root -m "${HAD[$s]}" "$W/old/$k" "$s.rb" && sudo mv -f "$s.rb" "$s" || true; else sudo rm -f "$s" || true; fi
    done
    if [[ "$MC_DONE" == 1 ]]; then
      sudo "$SPY" "$MS" rollback "$W/mesh-manifest.json" || true
      AD="$DASH_DIR/attic/mesh-ping-reply-sysboot-$TS"
      sudo rm -f "$AD/README.txt" "$AD/manifest.json" 2>/dev/null || true
      sudo find "$AD" -depth -type d -empty -delete 2>/dev/null || true
    fi
    sudo systemctl daemon-reload || true
    [[ "$JRESTART" == 1 ]] && { sudo systemctl restart systemd-journald || true; }
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 120); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "$F" "$WDF" "$HCF" "$MHF"; do cmp -s "$x" "$x.bak-sysboot-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Clone-Skript: $(sudo -n test -f "$CLONE" && s16 "$CLONE" || echo fehlt) (vorher $CL_OLD16)"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "$F" "$WDF" "$HCF" "$MHF"; do
    cp -a "$x" "$x.bak-sysboot-$TS"
    { ls -1t "$x.bak-sysboot-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$CLONE" ]]; then
    sudo -n cat "$CLONE" > "$DASH_DIR/prepper-clone-ssd-to-sd.bak-sysboot-$TS"
    { ls -1t "$DASH_DIR/prepper-clone-ssd-to-sd.bak-sysboot-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sysboot-$TS" \
      || { rm -f "$LZ.bak-sysboot-$TS"; for x in "$F" "$WDF" "$HCF" "$MHF"; do rm -f "$x.bak-sysboot-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sysboot-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  # Clone v2
  sudo install -o root -g root -m 0755 "$NCL" "$CLONE.new" && sudo mv -f "$CLONE.new" "$CLONE" || { rb "Clone-Skript installieren"; exit 1; }
  [[ "$(stat -c '%U:%G %a' "$CLONE")" == "root:root 755" ]] && same_sys "$NCL" "$CLONE" || { rb "Clone-Skript Rechte/Inhalt"; exit 1; }
  echo "OK Clone v2 eingespielt ($(s16 "$CLONE"), root:root 0755)"
  if [[ "$DU" != root ]]; then
    if sudo -n -l -U "$DU" "$CLONE" >/dev/null 2>&1; then
      rc=0; out=$(asu sudo -n "$CLONE" --check 2>&1) || rc=$?
      if [[ "$rc" == 0 || "$rc" == 10 ]] && [[ "$out" == *'"v": 2'* ]]; then
        echo "OK sudo-Regel deckt $CLONE fuer $DU (ohne Passwort, ohne Terminal geprueft): Klon jetzt $([[ "$rc" == 0 ]] && echo erlaubt || echo "gesperrt - $(echo "$out" | python3 -c 'import json,sys; print("; ".join(json.load(sys.stdin)["why"]))' 2>/dev/null | cut -c1-200)")"
      else
        echo "HINWEIS sudo -n $CLONE --check als $DU: rc $rc ($(echo "$out" | head -1 | cut -c1-160)) - Aufruf ohne Argumente (Knopf) ist laut sudo -l erlaubt"
      fi
    else
      echo "WARNUNG: sudo-Regel erlaubt $DU NICHT $CLONE ohne Passwort - der Klon-Knopf meldet dann 'nicht gestartet'. Regel ansehen: sudo cat /etc/sudoers.d/prepper-clone"
    fi
  fi
  # smartctl-Regel
  if [[ "$SMNEED" == 1 ]]; then
    sudo install -o root -g root -m 0440 "$W/smrule" "$SMRULE.tmp" && sudo visudo -cf "$SMRULE.tmp" > "$W/vis.log" 2>&1 && sudo mv -f "$SMRULE.tmp" "$SMRULE" && sudo visudo -c > "$W/vis2.log" 2>&1 \
      || { cat "$W/vis.log" "$W/vis2.log" 2>/dev/null; sudo rm -f "$SMRULE.tmp"; rb "smartctl-Regel"; exit 1; }
    rc=0; out=$(asu sudo -n "$SM" -d sat -H -A "/dev/$RDISK" 2>&1) || rc=$?
    if [[ "$out" == sudo:* ]]; then echo "WARNUNG smartctl-Regel wirkt nicht ($(echo "$out" | head -1 | cut -c1-120)) - Regel wieder entfernt, SMART bleibt 'nicht lesbar'"; sudo rm -f "$SMRULE"
    else echo "OK smartctl-Regel $SMRULE (0440, visudo -c gueltig), echter Aufruf als $DU ohne Terminal: rc $rc, $(echo "$out" | grep -m1 -E 'overall-health|SMART Health Status' | cut -c1-80 || echo 'Ausgabe ohne Health-Zeile')"; fi
  fi
  # Drop-ins
  sudo mkdir -p "$(dirname "$DDROP")" "$(dirname "$JDROP")"
  sudo install -o root -g root -m 0644 "$W/ddrop" "$DDROP" || { rb "Drop-in Dashboard"; exit 1; }
  if [[ -n "$WDDROP" ]]; then sudo mkdir -p "$(dirname "$WDDROP")" && sudo install -o root -g root -m 0644 "$W/wddrop" "$WDDROP" || { rb "Drop-in Watchdog"; exit 1; }; fi
  if ! same_sys "$W/jdrop" "$JDROP"; then
    sudo install -o root -g root -m 0644 "$W/jdrop" "$JDROP" || { rb "Drop-in journald"; exit 1; }
    JRESTART=1
  fi
  sudo systemctl daemon-reload
  if [[ "$JRESTART" == 1 ]]; then
    sudo systemctl restart systemd-journald || { rb "systemd-journald Neustart"; exit 1; }
    sleep 2; sudo journalctl --flush >/dev/null 2>&1 || true
  fi
  # meshClean
  sudo "$SPY" "$MS" apply "$DASH_DIR" "$DASH_DIR/attic/mesh-ping-reply-sysboot-$TS" "$W/mesh-manifest.json" > "$W/mc.log" 2>&1 && MC_DONE=1 || { rc=$?; MC_DONE=1; if [[ "$rc" == 1 ]]; then echo "HINWEIS $(cat "$W/mc.log")"; else cat "$W/mc.log"; rb "meshClean"; exit 1; fi; }
  echo "OK $(tail -1 "$W/mc.log")"
  sudo -n test -f "$W/mesh-manifest.json" && sudo -n cp "$W/mesh-manifest.json" "$DASH_DIR/attic/mesh-ping-reply-sysboot-$TS/manifest.json" 2>/dev/null || true
  rmdir "$DASH_DIR/attic/mesh-ping-reply-sysboot-$TS" 2>/dev/null || true
  # Dateien im Dashboard-Ordner
  for k in "dashboard.py $F" "watchdog.py $WDF" "health_check.py $HCF" "mesh_hang_watchdog.py $MHF"; do set -- $k
    cp "$W/work/$1" "$2.new" && chmod --reference="$2.bak-sysboot-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  echo "Neustart prepper-dashboard (nur dieser Dienst) - Server muss jetzt sofort antworten ..."
  TR=$(date +%s)
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 60); do sleep 2; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht innerhalb 120 s"; exit 1; }
  echo "OK HTTP / = 200 nach $(( $(date +%s) - TR )) s (vorher wartete der Start auf das erste Voll-Update, ca. 5 min)"
  echo "warte auf das erste Voll-Update im Hintergrund (max 12 min; Seiten zeigen solange 'Dashboard startet') ..."
  ld=0; for i in $(seq 1 144); do "${CURL[@]}" "$B/api/sysboot/status" -o "$W/sbs.json" || true; grep -q '"loading":false' "$W/sbs.json" 2>/dev/null && { ld=1; break; }; (( i % 12 == 0 )) && echo "   ... laedt noch ($(( $(date +%s) - TR )) s)"; sleep 5; done
  [[ "$ld" == 1 ]] && echo "OK erstes Voll-Update fertig nach $(( $(date +%s) - TR )) s, Server lief die ganze Zeit" || echo "HINWEIS erstes Voll-Update nach 12 min noch nicht fertig (Netz?) - Rauchtest laeuft trotzdem"
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist "/dabhist?ch=11D" /karte /api/sysboot/status /api/sysboot/disk /api/clone/status /api/sdr/live /api/t4/status; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
c=$(code -X POST -H 'Content-Type: application/json' -d '{"token":"x"}' "$B/api/clone/start"); [[ "$c" == 200 ]] || rbx "/api/clone/start antwortet $c"
"${CURL[@]}" -X POST -H 'Content-Type: application/json' -d '{"token":"x"}' "$B/api/clone/start" -o "$W/cs.json" || true
grep -q '"ok":false' "$W/cs.json" && echo "OK /api/clone/start mit falscher Bestaetigung startet nichts" || rbx "/api/clone/start ohne gueltige Bestaetigung nicht abgelehnt"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$CK" pi "$W/pi.html" > "$W/ck.log" 2>&1 && echo "OK $(cat "$W/ck.log")" || { cat "$W/ck.log"; rbx "/pi Kacheln"; }
"${CURL[@]}" "$B/api/sysboot/disk" -o "$W/disk.json" || true
python3 "$CK" disk "$W/disk.json" > "$W/ck.log" 2>&1 && echo "OK $(cat "$W/ck.log")" || { cat "$W/ck.log"; rbx "/api/sysboot/disk"; }
"${CURL[@]}" "$B/api/clone/status" -o "$W/clone.json" || true
python3 "$CK" clone "$W/clone.json" > "$W/ck.log" 2>&1 && echo "OK $(cat "$W/ck.log")" || { cat "$W/ck.log"; rbx "/api/clone/status"; }
"${CURL[@]}" "$B/api/sysboot/status" -o "$W/sbs.json" || true
python3 "$CK" status "$W/sbs.json" > "$W/ck.log" 2>&1 && echo "OK $(cat "$W/ck.log")" || { cat "$W/ck.log"; rbx "/api/sysboot/status"; }
sleep 2
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(sysBoot|diskTiles2) (aktiv|FEHLER)|sysBoot: erstes" | tail -8 || true)
if [[ "$JD" == *"FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2 | cut -c1-200)"; fi
if [[ "$RESTARTED" == 1 ]]; then
  [[ "$JD" == *"sysBoot aktiv"*"selftest ok"* ]] || rbx "Dashboard meldet sysBoot nicht (Journal)"
  [[ "$JD" == *"diskTiles2 aktiv: diskTiles2 selftest ok"* ]] || rbx "Dashboard meldet diskTiles2 nicht (Journal)"
  echo "OK Journal Dashboard: $(echo "$JD" | grep 'sysBoot aktiv' | tail -1 | cut -c1-220)"
  echo "OK Journal Dashboard: $(echo "$JD" | grep 'diskTiles2 aktiv' | tail -1 | cut -c1-220)"
  E2=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sysBoot FEHLER|diskTiles2 FEHLER" || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback" || rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"
fi
SL=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c "sysBoot langsame Anfrage" || true)
echo "langsame Anfragen (> 3 s) seit Start: ${SL:-0} (journalctl -u prepper-dashboard | grep 'langsame Anfrage')"
(cd "$DASH_DIR" && timeout 40 python3 "$WDF" --selftest 2>&1 | tail -1 | cut -c1-200) || true
systemctl show -p After prepper-dashboard 2>/dev/null | grep -q network-online.target && echo "OK prepper-dashboard After/Wants network-online.target" || rbx "Drop-in network-online wirkt nicht"
JS=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^(Storage|SystemMaxUse)=' | tail -2 | tr '\n' ' ' || true)
sudo -n test -d /var/log/journal && echo "OK Journal dauerhaft: $JS, /var/log/journal da, $(journalctl --disk-usage 2>/dev/null | tail -1 | cut -c1-80)" || rbx "Journal nicht dauerhaft (/var/log/journal fehlt)"
for u in mesh-ping-reply.service mesh-ping-reply-2.service mesh-ping-reply-bayern.service; do echo "  $u: $(systemctl show -p LoadState -p ActiveState --value "$u" 2>/dev/null | tr '\n' ' ')"; done
echo "OK guards sysBoot(dash)=$(grep -c '# ===== sysBoot: Start ohne Warten' "$F" || true) lzKick=$(grep -c '# ===== sysBoot lzKick:' "$F" || true) diskTiles2=$(grep -c '# ===== diskTiles2 (sysBoot):' "$F" || true) threaded=$(grep -c 'threaded=True)  # sysBoot' "$F" || true) watchdog=$(grep -c '# ===== sysBoot watchdog:' "$WDF" || true) health=$(grep -c 'sysBoot' "$HCF" || true) meshClean=$(grep -c 'sysBoot meshClean' "$MHF" || true)"
[[ -f "$F.bak-sysboot-$TS" ]] && echo "Backups: *.bak-sysboot-$TS (dashboard.py, watchdog.py, health_check.py, mesh_hang_watchdog.py, prepper-clone-ssd-to-sd, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$WDF" "$HCF" "$MHF" "$CLONE"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
for x in "$DDROP" "$JDROP" "$WDDROP" "$SMRULE"; do [[ -n "$x" ]] && sudo -n test -f "$x" && echo "  $x da"; done
TK=$(python3 -c "
import json,os,sys,time
f=sys.argv[1]
if not os.path.exists(f): print('aus'); raise SystemExit
try:
    d=json.load(open(f))
except Exception:
    print('unklar'); raise SystemExit
if isinstance(d,dict) and d.get('on') is True:
    s=d.get('since'); print('AN' + (time.strftime(' seit %d.%m. %H:%M', time.localtime(s)) if isinstance(s,(int,float)) and s>0 else ''))
else:
    print('aus')" "$DASH_DIR/sdr_takeover.json" 2>/dev/null || echo "unklar")
[[ "$TK" == AN* ]] && echo "HINWEIS Stick-2-Uebernahme ist noch ${TK} - Klon bleibt gesperrt, bis sie auf /funk zurueckgesetzt ist"
[[ "$TK" == unklar ]] && echo "HINWEIS sdr_takeover.json unlesbar - Klon bleibt gesperrt, bis die Datei wieder gueltig ist (Knopf auf /funk)"
echo "Rueckweg: die .bak-sysboot-$TS zurueckkopieren, Clone-Skript aus $DASH_DIR/prepper-clone-ssd-to-sd.bak-sysboot-$TS (sudo install -m 0755), Drop-ins loeschen, sudo systemctl daemon-reload, sudo systemctl restart prepper-dashboard"
echo "COMMIT $COMMIT_ARG sysboot=1 fertig"
