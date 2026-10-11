#!/bin/bash
set -euo pipefail
# sdHealth: SD-Karten-Ampel. root-Skript + stuendlicher Timer schreiben sd_health.json, Karte auf /pi, /api/sd_health, Banner bei Rot.
# Nur bei dashboard.py sha16 65974cb98fb84758. Nur lesen + 4-KB-Schreibprobe, sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdhealth
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sdHealth apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
UNIT_DIR="${SDH_UNIT_DIR:-/etc/systemd/system}"
SBIN="${SDH_SBIN:-/usr/local/sbin}"
SDJ="$DASH_DIR/sd_health.json"
EXPECT_PATCH="93cd3cc6537ae872b5bce9d22333089ba0bc51332cd23e9113ff702556cc077e"
EXPECT_ROOT="f494e08018d38a0eb52ba700d732771fb8a563424fbc458ce561726d96c3eccf"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-sd-health.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""sdHealth: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== sdHealth:"
EXPECT = "65974cb98fb84758"
NEED = ["# ===== sourceWatch:", "# ===== longArchive:", "def sw_sources", "def _sw_banner", "def _sw_fmt_age"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== sdHealth: SD-Karten-Ampel (liest sd_health.json vom root-Timer prepper-sd-health; nur Anzeige, keine Sendungen) =====
# Karte auf /pi, /api/sd_health, bei Rot im sourceWatch-Banner. Veraltet nach 3 h (gelb).
import os as _sdh_os
import json as _sdh_json
import time as _sdh_time
SDH_FILE = _sdh_os.path.join(_sdh_os.path.dirname(_sdh_os.path.abspath(__file__)), "sd_health.json")
SDH_STALE_S = 3 * 3600
_sdh_cache = {"m": None, "d": None}
_SDH_MAN = {"0x000003": "SanDisk", "0x00001b": "Samsung", "0x000041": "Kingston", "0x000074": "Transcend",
            "0x000027": "Phison", "0x00009c": "Lexar"}


def _sdh_load():
    try:
        m = _sdh_os.path.getmtime(SDH_FILE)
        if _sdh_cache["m"] != m:
            with open(SDH_FILE, "r", encoding="utf-8") as f:
                _sdh_cache["d"] = _sdh_json.load(f)
            _sdh_cache["m"] = m
        return _sdh_cache["d"]
    except Exception:
        return None


def sdh_view():
    d = _sdh_load()
    now = _sdh_time.time()
    if not isinstance(d, dict):
        return {"ok": False, "level": "yellow", "state": "alt", "reasons": ["noch keine Messung (sd_health.json fehlt)"], "age_s": None}
    v = dict(d)
    age = now - float(d.get("ts") or 0)
    v["age_s"] = int(age)
    reasons = list(d.get("reasons") or [])
    lvl = d.get("level") or "yellow"
    if age > SDH_STALE_S:
        reasons.append("Messung veraltet (%d h alt, Timer pruefen)" % (age // 3600))
        if lvl == "green":
            lvl = "yellow"
    v["level"] = lvl
    v["reasons"] = reasons
    v["state"] = {"green": "ok", "yellow": "alt", "red": "ausgefallen"}.get(lvl, "alt")
    c = d.get("card") or {}
    v["maker"] = _SDH_MAN.get(str(c.get("manfid") or "").lower(), c.get("manfid") or "?")
    return v


def _sdh_fmt(x, nd=1):
    return ("%.*f" % (nd, x)).replace(".", ",") if isinstance(x, (int, float)) else "–"


def _sdh_card(v):
    col = {"green": "#22c55e", "yellow": "#eab308", "red": "#ef4444"}.get(v.get("level"), "#64748b")
    txt = {"green": "Gesund", "yellow": "Beobachten", "red": "Fehler – Backup prüfen!"}.get(v.get("level"), "?")
    c = v.get("card") or {}
    t2 = v.get("tune2fs") or {}
    esc = lambda s: str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    rs = "".join("<li>%s</li>" % esc(r) for r in (v.get("reasons") or []))
    age = c.get("months")
    lines = [
        "%s %s (%s), hergestellt %s%s" % (esc(v.get("maker", "?")), esc(c.get("name") or "?"), esc(c.get("type") or "SD"),
                                         esc(c.get("date") or "?"), (" · ~%d Monate alt" % age) if isinstance(age, int) else ""),
        "Geschrieben gesamt %s TB · %s GB/Tag (%s) · seit Start %s GB" % (_sdh_fmt(v.get("written_tb"), 2), _sdh_fmt(v.get("gb_day")),
                                                                         esc(v.get("gb_day_src") or "–"), _sdh_fmt(v.get("boot_written_gb"))),
        "Kernel-Fehler 24 h: %s · Warnungen: %s · ext4-Fehler: %s · Schreibprobe: %s · %s" % (
            v.get("errors_24h", "–"), v.get("warn_24h", "–"), esc((v.get("ext4") or {}).get("errors_count") or "–"),
            "ok" if v.get("probe_ok") else ("FEHLER" if v.get("probe_ok") is False else "–"),
            "nur lesbar!" if (v.get("root") or {}).get("ro") else "beschreibbar"),
        "Errors behavior: %s · Mount count %s · %s" % (esc(t2.get("Errors behavior") or "–"), esc(t2.get("Mount count") or "–"),
                                                        esc(v.get("wear") or "Verschleiss nicht auslesbar (Consumer-SD)")),
        "Stand %s (%s)" % (esc((v.get("at") or "–")[:16]), ("vor %d min" % (v["age_s"] // 60)) if isinstance(v.get("age_s"), int) else "–"),
    ]
    return ('<div class="card sd-card" id="sdCard" style="margin-top:12px"><div class="title">💾 SD-Karte '
            '<span style="display:inline-block;width:12px;height:12px;border-radius:50%%;background:%s;vertical-align:middle"></span> '
            '<span style="color:%s">%s</span></div><div class="small" style="line-height:1.5">%s%s</div></div>'
            % (col, col, txt, "<br>".join(lines), ('<ul style="margin:4px 0 0 18px">%s</ul>' % rs) if rs else ""))


def _sdh_after(resp):
    try:
        from flask import request as _sdh_req
        if _sdh_req.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        i = body.rfind("</body>")
        if i < 0 or "sd-card" in body:
            return resp
        resp.set_data(body[:i] + _sdh_card(sdh_view()) + body[i:])
    except Exception as e:
        print("sdHealth /pi:", e, flush=True)
    return resp


def _sdh_api():
    from flask import jsonify as _sdh_jsonify
    return _sdh_jsonify(sdh_view())


if callable(globals().get("sw_sources")):
    _sdh_orig_sw_sources = sw_sources

    def sw_sources():
        d = _sdh_orig_sw_sources()
        try:
            v = sdh_view()
            age = v.get("age_s")
            d["sources"].append({"key": "sd", "name": "SD-Karte", "state": v["state"], "age_s": age,
                                 "age_txt": _sw_fmt_age(age) if age is not None else "–", "threshold_s": SDH_STALE_S,
                                 "threshold_txt": _sw_fmt_age(SDH_STALE_S), "fails": 0, "important": True,
                                 "why": "; ".join(v.get("reasons") or [])[:120], "time_source": "sd_health.json"})
            d["counts"][v["state"]] = d["counts"].get(v["state"], 0) + 1
            if v.get("level") == "red":
                d["important_down"].append("SD-Karte")
            d["sd"] = {"level": v.get("level"), "reasons": v.get("reasons")}
        except Exception as e:
            print("sdHealth sources:", e, flush=True)
        return d

if callable(globals().get("_sw_banner")):
    _sdh_orig_sw_banner = _sw_banner

    def _sw_banner(d):
        if "SD-Karte" not in (d.get("important_down") or []):
            return _sdh_orig_sw_banner(d)
        rest = dict(d)
        rest["important_down"] = [x for x in d["important_down"] if x != "SD-Karte"]
        rs = "; ".join((d.get("sd") or {}).get("reasons") or [])
        sd = ('<div class="src-banner sd-banner" style="background:#7f1d1d;color:#fff;padding:10px 14px;margin:0 0 10px;'
              'border-radius:8px;font-weight:600">⚠️ SD-Karte: %s – Backup prüfen, Karte bald tauschen</div>'
              % str(rs or "Fehler").replace("<", "&lt;")[:200])
        return sd + _sdh_orig_sw_banner(rest)

if "sdh_api" not in app.view_functions:
    app.add_url_rule("/api/sd_health", endpoint="sdh_api", view_func=_sdh_api, methods=["GET"])
app.after_request(_sdh_after)
print("sdHealth aktiv", flush=True)
# ===== /sdHealth =====

'''


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    if MARK in src:
        print("RESULT dashboard.py=schon sha16 %s" % h)
        return
    if h != EXPECT and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    miss = [a for a in NEED if a not in src]
    if miss:
        raise SystemExit("STOP: fehlt %s - nichts geaendert" % miss)
    if "/api/sd_health" in src:
        raise SystemExit("STOP: /api/sd_health gibt es schon - nichts geaendert")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s, nachher %s)" % (h, hashlib.sha256(new.encode()).hexdigest()[:16]))


if __name__ == "__main__":
    main()
PATCHPY_EOF
cat > "$W/prepper-sd-health.py" << 'ROOTPY_EOF'
#!/usr/bin/env python3
"""sdHealth: stuendliche SD-Karten-Pruefung (nur lesen + 4-KB-Schreibprobe). Schreibt sd_health.json atomar.
Laeuft als root ueber prepper-sd-health.timer. Aendert nichts an Karte/Dateisystem. Sendet nichts."""
import json
import os
import pwd
import re
import subprocess
import time
from datetime import datetime

DEV = os.environ.get("SDH_DEV", "mmcblk0")
SYS = os.environ.get("SDH_SYS", "/sys")
OUT = os.environ.get("SDH_OUT", "/home/fmg/prepper-dashboard/sd_health.json")
STATE_DIR = os.environ.get("SDH_STATE", "/var/lib/prepper-sd-health")
OWNER = os.environ.get("SDH_OWNER", "fmg")
GB_DAY_YELLOW = 20.0
VERSION = 1

# Kernel-Meldungen: nur Zeilen zu mmc/mmcblk0/EXT4/I/O
REL = re.compile(r"mmc\d|mmcblk|EXT4-fs|I/O error|blk_update_request|Buffer I/O", re.I)
NORMAL = re.compile(r"orphan cleanup on readonly fs|re-mounted|mounted filesystem|recovery complete|"
                    r"new (ultra )?high speed|new SD|new SDHC|new SDXC|mmcblk\d: mmc\d:|p\d p\d|"
                    r"quota mode|using .*(clock|mode)|ext4 filesystem being mounted|"
                    r"unmounting filesystem|Shutdown", re.I)
ERR = re.compile(r"I/O error|EXT4-fs error|EXT4-fs warning.*error|Buffer I/O|blk_update_request|critical medium|"
                 r"Remounting filesystem read-only|remount.*read-only|Journal has aborted|"
                 r"Aborting journal|Detected aborted journal|unable to read", re.I)
WARN = re.compile(r"timeout|timed out|CRC|error -\d+|card removed|reset|retry|Card stuck|"
                  r"Got data interrupt|status: 0x", re.I)


def rd(p, default=None):
    try:
        with open(p, "r") as f:
            return f.read().strip()
    except Exception:
        return default


def run(cmd, timeout=20):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except Exception as e:
        return 99, str(e)


def classify(lines):
    errs, warns = [], []
    for ln in lines:
        if not REL.search(ln) or NORMAL.search(ln):
            continue
        if ERR.search(ln):
            errs.append(ln[:200])
        elif WARN.search(ln):
            warns.append(ln[:200])
    return errs, warns


def kernel_lines(args):
    rc, out = run(["journalctl", "-k", "--no-pager", "-o", "short-iso"] + args, timeout=40)
    if rc != 0:
        return None
    return out.splitlines()


def root_info():
    src = opts = None
    for ln in (rd("/proc/mounts", "") or "").splitlines():
        p = ln.split()
        if len(p) >= 4 and p[1] == "/":
            src, opts = p[0], p[3]
    return src, opts


def tune2fs(src):
    d = {}
    if not src:
        return d
    rc, out = run(["tune2fs", "-l", src])
    if rc != 0:
        d["error"] = (out or "")[:120]
        return d
    for ln in out.splitlines():
        if ":" not in ln:
            continue
        k, v = ln.split(":", 1)
        k = k.strip()
        if k in ("Errors behavior", "Lifetime writes", "Filesystem created", "Mount count", "Maximum mount count",
                 "Last checked", "FS Error count", "First error time", "Last error time", "Filesystem state"):
            d[k] = v.strip()
    return d


def probe(dirpath):
    p = os.path.join(dirpath, "probe.tmp")
    try:
        data = os.urandom(4096)
        with open(p, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        with open(p, "rb") as f:
            back = f.read()
        os.unlink(p)
        return back == data, None
    except Exception as e:
        try:
            os.unlink(p)
        except Exception:
            pass
        return False, str(e)[:120]


def card_age(date_s):
    try:
        m, y = date_s.split("/")
        months = (datetime.now().year - int(y)) * 12 + datetime.now().month - int(m)
        return max(0, months)
    except Exception:
        return None


def main():
    now = time.time()
    os.makedirs(STATE_DIR, exist_ok=True)
    stp = os.path.join(STATE_DIR, "state.json")
    try:
        with open(stp) as f:
            st = json.load(f)
    except Exception:
        st = {}
    dev = os.path.join(SYS, "block", DEV)
    card = {k: rd(os.path.join(dev, "device", k)) for k in ("name", "manfid", "oemid", "date", "type", "serial")}
    card["months"] = card_age(card.get("date") or "")
    src, opts = root_info()
    if not src or not src.startswith("/dev/") or src == "/dev/root":
        rc, o = run(["findmnt", "-n", "-o", "SOURCE", "/"])
        if rc == 0 and o.strip().startswith("/dev/"):
            src = o.strip()
    part = os.path.basename(src or "")
    e4 = os.path.join(SYS, "fs", "ext4", part)
    ext4 = {"errors_count": rd(os.path.join(e4, "errors_count")), "first_error_time": rd(os.path.join(e4, "first_error_time")),
            "last_error_time": rd(os.path.join(e4, "last_error_time")), "lifetime_write_kbytes": rd(os.path.join(e4, "lifetime_write_kbytes"))}
    stat = (rd(os.path.join(dev, "stat"), "") or "").split()
    up = float((rd("/proc/uptime", "0") or "0").split()[0])
    wsect = int(stat[6]) if len(stat) > 6 else None
    kb = int(ext4["lifetime_write_kbytes"]) if (ext4["lifetime_write_kbytes"] or "").isdigit() else None
    # Schreibrate: 24 h aus lifetime_write_kbytes (bleibt ueber Neustarts), sonst Mittel seit Start
    samples = [s for s in st.get("samples", []) if now - s[0] < 2.2 * 86400]
    if kb is not None:
        samples.append([now, kb])
    gb_day, src_rate = None, None
    old = [s for s in samples if now - s[0] >= 20 * 3600]
    if kb is not None and old:
        s0 = old[-1]
        if kb >= s0[1]:
            gb_day = (kb - s0[1]) / 1024.0 ** 2 / ((now - s0[0]) / 86400.0)
            src_rate = "24 h"
    if gb_day is None and wsect is not None and up > 3600:
        gb_day = wsect * 512 / 1024.0 ** 3 / (up / 86400.0)
        src_rate = "seit Start"
    k24 = kernel_lines(["--since", "-24h"])
    kb0 = kernel_lines(["-b"])
    e24, w24 = classify(k24 or [])
    eb, wb = classify(kb0 or [])
    ro = bool(opts) and opts.split(",")[0] == "ro"
    pok, perr = probe(STATE_DIR)
    t2 = tune2fs(src)
    reasons_red, reasons_yel = [], []
    if e24 or eb:
        reasons_red.append("Kernel meldet I/O- oder EXT4-Fehler (%d in 24 h, %d seit Start)" % (len(e24), len(eb)))
    try:
        if int(ext4["errors_count"] or 0) > 0:
            reasons_red.append("ext4-Fehlerzaehler %s" % ext4["errors_count"])
    except Exception:
        pass
    if t2.get("FS Error count") and t2["FS Error count"] not in ("0",):
        reasons_red.append("tune2fs FS Error count %s" % t2["FS Error count"])
    if ro:
        reasons_red.append("Wurzel-Dateisystem nur lesbar eingehaengt")
    if not pok:
        reasons_red.append("Schreibprobe fehlgeschlagen%s" % ((": " + perr) if perr else ""))
    if w24 or wb:
        reasons_yel.append("mmc-Warnungen (Timeout/CRC/Reset): %d in 24 h" % len(w24 or wb))
    if gb_day is not None and gb_day > GB_DAY_YELLOW:
        reasons_yel.append("hohe Schreiblast %.1f GB/Tag" % gb_day)
    if k24 is None:
        reasons_yel.append("Kernel-Journal nicht lesbar")
    level = "red" if reasons_red else ("yellow" if reasons_yel else "green")
    out = {
        "ok": True, "version": VERSION, "ts": int(now), "at": datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
        "level": level, "reasons": reasons_red + reasons_yel, "card": card, "dev": DEV,
        "root": {"source": src, "options": opts, "ro": ro},
        "probe_ok": pok, "probe_error": perr, "ext4": ext4, "tune2fs": t2,
        "errors_24h": len(e24), "errors_boot": len(eb), "warn_24h": len(w24), "warn_boot": len(wb),
        "error_lines": (e24 or eb)[-5:], "warn_lines": (w24 or wb)[-5:], "journal_ok": k24 is not None,
        "written_tb": (round(kb / 1024.0 ** 3, 3) if kb is not None else None),
        "boot_written_gb": (round(wsect * 512 / 1024.0 ** 3, 1) if wsect is not None else None),
        "gb_day": (round(gb_day, 2) if gb_day is not None else None), "gb_day_src": src_rate,
        "uptime_s": int(up), "wear": "Verschleiss nicht auslesbar (Consumer-SD)",
    }
    st["samples"] = samples[-80:]
    tmp = stp + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, stp)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    try:
        pw = pwd.getpwnam(OWNER)
        os.chown(tmp, pw.pw_uid, pw.pw_gid)
    except Exception:
        pass
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)
    print("sdHealth %s: %s" % (level, "; ".join(out["reasons"]) or "keine Auffaelligkeiten"))


if __name__ == "__main__":
    main()
ROOTPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-sd-health.py"; S="$W/prepper-sd-health.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_ROOT  $S" | sha256sum -c - >/dev/null || { echo "STOP: root-Skript sha256 falsch"; exit 1; }
python3 -m py_compile "$P" "$S"
set +e
python3 - "$P" "$S" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
root = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
if not blk:
    raise SystemExit(4)
hit = False
for nm, code in (("Block", blk), ("root-Skript", root)):
    for node in ast.walk(ast.parse(code)):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            mods = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module or ""]
            for m in mods:
                if m.split(".")[0] in ("requests", "urllib", "socket", "http", "smtplib", "meshtastic"):
                    print(nm, "verbotener Import", m); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("update_all", "urlopen", "Popen", "system"):
                print(nm, "verbotener Aufruf", fn); hit = True
            if nm == "Block" and fn == "open" and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and any(c in str(node.args[1].value) for c in "wax+"):
                print("Schreib-open im Block"); hit = True
            if nm == "root-Skript" and fn == "run" and node.args and isinstance(node.args[0], (ast.List, ast.BinOp)):
                lst = node.args[0] if isinstance(node.args[0], ast.List) else node.args[0].left
                first = lst.elts[0].value if isinstance(lst, ast.List) and lst.elts and isinstance(lst.elts[0], ast.Constant) else None
                if first not in ("journalctl", "tune2fs", "findmnt"):
                    print("root-Skript: Befehl nicht erlaubt", first); hit = True
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
            print(nm, "data_store-Schreiben"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Netz, kein Senden; root-Skript ruft nur journalctl/tune2fs/findmnt, schreibt nur sd_health.json + eigenen Zustand)"

# ---------- 1) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error::SyntaxWarning -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /pi /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /energie=${PRE[/energie]}"

# ---------- 2) root-Skript + Timer ----------
cat > "$W/prepper-sd-health.service" << 'UNIT_EOF'
[Unit]
Description=Prepper SD-Karten-Pruefung (sdHealth, nur lesen + 4-KB-Schreibprobe)

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 SBIN_PLACEHOLDER/prepper-sd-health.py
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=120
UNIT_EOF
sed -i "s#SBIN_PLACEHOLDER#$SBIN#" "$W/prepper-sd-health.service"
cat > "$W/prepper-sd-health.timer" << 'UNIT_EOF'
[Unit]
Description=Prepper SD-Karten-Pruefung stuendlich (sdHealth)

[Timer]
OnBootSec=3min
OnCalendar=hourly
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
UNIT_EOF
NEWSYS=0
same=1
cmp -s "$S" "$SBIN/prepper-sd-health.py" || same=0
cmp -s "$W/prepper-sd-health.service" "$UNIT_DIR/prepper-sd-health.service" || same=0
cmp -s "$W/prepper-sd-health.timer" "$UNIT_DIR/prepper-sd-health.timer" || same=0
sudo -v
rbsys() {
  if [[ "$NEWSYS" -eq 1 ]]; then
    sudo systemctl disable --now prepper-sd-health.timer >/dev/null 2>&1 || true
    sudo rm -f "$UNIT_DIR/prepper-sd-health.timer" "$UNIT_DIR/prepper-sd-health.service" "$SBIN/prepper-sd-health.py"
    sudo systemctl daemon-reload || true
    echo "Timer + root-Skript wieder entfernt"
  fi
}
if [[ "$same" -eq 1 ]]; then
  echo "OK root-Skript + Timer schon installiert"
else
  [[ -e "$UNIT_DIR/prepper-sd-health.timer" || -e "$SBIN/prepper-sd-health.py" ]] || NEWSYS=1
  { sudo install -m 0755 -o root -g root "$S" "$SBIN/prepper-sd-health.py" &&
    sudo install -m 0644 -o root -g root "$W/prepper-sd-health.service" "$UNIT_DIR/prepper-sd-health.service" &&
    sudo install -m 0644 -o root -g root "$W/prepper-sd-health.timer" "$UNIT_DIR/prepper-sd-health.timer" &&
    sudo systemctl daemon-reload; } || { echo "ROLLBACK: Installation fehlgeschlagen"; rbsys; exit 1; }
  echo "OK root-Skript + Timer installiert (neu=$NEWSYS)"
fi
sudo systemctl enable --now prepper-sd-health.timer >/dev/null 2>&1 || { echo "ROLLBACK: Timer laesst sich nicht aktivieren"; rbsys; exit 1; }
T0=$(date +%s)
echo "Erste Messung laeuft ..."
sudo systemctl start prepper-sd-health.service || { echo "ROLLBACK: erste Messung fehlgeschlagen"; sudo journalctl -u prepper-sd-health --no-pager -n 8 2>/dev/null | cut -c1-150 || true; rbsys; exit 1; }
python3 - "$SDJ" "$T0" << 'PY' || { echo "ROLLBACK: sd_health.json fehlt oder ungueltig"; rbsys; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("ok") or int(d.get("ts") or 0) < int(sys.argv[2]) - 5:
    sys.exit(1)
c = d.get("card") or {}
t2 = d.get("tune2fs") or {}
print("Messung: Ampel %s - %s" % (d["level"], "; ".join(d.get("reasons") or []) or "keine Auffaelligkeiten"))
print("Karte: %s manfid %s, %s, Datum %s (~%s Monate)" % (c.get("name"), c.get("manfid"), c.get("type"), c.get("date"), c.get("months")))
print("Geschrieben: %s TB gesamt, %s GB/Tag (%s), seit Start %s GB" % (d.get("written_tb"), d.get("gb_day"), d.get("gb_day_src"), d.get("boot_written_gb")))
print("Kernel-Fehler 24h %s / seit Start %s, Warnungen 24h %s, ext4-Fehler %s, Schreibprobe %s, ro=%s, Journal lesbar %s" % (
    d.get("errors_24h"), d.get("errors_boot"), d.get("warn_24h"), (d.get("ext4") or {}).get("errors_count"), d.get("probe_ok"), (d.get("root") or {}).get("ro"), d.get("journal_ok")))
print("tune2fs: Errors behavior %s, Mount count %s, Lifetime writes %s" % (t2.get("Errors behavior"), t2.get("Mount count"), t2.get("Lifetime writes")))
for ln in (d.get("error_lines") or []) + (d.get("warn_lines") or []):
    print("  Kernel:", ln[:140])
PY
echo "Timer: $(systemctl list-timers prepper-sd-health.timer --no-pager 2>/dev/null | sed -n 2p | cut -c1-110)"

# ---------- 3) Dashboard ----------
if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK sdHealth-Block schon installiert - kein Neustart"
else
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-sdhealth-$TS" "$F"
    rbsys
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-sdhealth-$TS"
  }
  cp -a "$F" "$F.bak-sdhealth-$TS"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  "${CURL[@]}" "$B/api/sd_health" -o "$W/sd.json" || true
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("GET /api/sd_health: Ampel", d.get("level"), "Status", d.get("state"), "Alter", d.get("age_s"), "s")' "$W/sd.json" || { rb "/api/sd_health ungueltig"; exit 1; }
  "${CURL[@]}" "$B/api/sources" -o "$W/src.json" || true
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=[x for x in d["sources"] if x["key"]=="sd"]; print("sourceWatch-Zeile:", r[0]["name"], r[0]["state"], "| Banner:", ", ".join(d["important_down"]) or "keins")' "$W/src.json" || { rb "/api/sources ohne SD-Zeile"; exit 1; }
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    grep -q 'sd-card' "$W/pi.html" && echo "OK /pi zeigt Karte SD-Karte" || echo "WARN /pi 200, aber SD-Karte nicht eingefuegt"
    for m in src-card arch-card; do grep -q "$m" "$W/pi.html" && echo "OK $m weiterhin da" || echo "Hinweis: $m nicht gefunden"; done
  fi
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-sdhealth-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "OK guards sdHealth=$(grep -q '# ===== sdHealth:' "$F" && echo 1 || echo 0) sourceWatch=$(grep -q '# ===== sourceWatch:' "$F" && echo 1 || echo 0) firmsKeep=$(grep -q '# ===== firmsKeep:' "$F" && echo 1 || echo 0) longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) timer=$(systemctl is-enabled prepper-sd-health.timer 2>/dev/null || echo ?)"
[[ -f "$F.bak-sdhealth-$TS" ]] && echo "Backup: $F.bak-sdhealth-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG sdHealth=1"
