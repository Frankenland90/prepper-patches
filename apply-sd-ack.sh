#!/bin/bash
set -euo pipefail
# sdAck: SD-Pruefung v2 - zaehlt nur Kernel-Fehler des Wurzel-Datentraegers (findmnt / -> Disk; spaeter auch SSD sda),
# andere Geraete (USB-Kartenleser beim Klonen) nur als graue Info; Knopf "Quittieren & neu pruefen" auf /pi
# (Dashboard schreibt nur sd_health_ack.json, prepper-sd-health.path startet die Pruefung - kein sudo fuer das Dashboard).
# Nur bei dashboard.py sha16 18daef1da37a85b5. Sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdack-apply
UNIT_DIR="${SDH_UNIT_DIR:-/etc/systemd/system}"
SBIN="${SDH_SBIN:-/usr/local/sbin}"
SCRIPT="$SBIN/prepper-sd-health.py"
ACKF="$DASH_DIR/sd_health_ack.json"
OUTF="$DASH_DIR/sd_health.json"
V1_SHA="f494e08018d38a0eb52ba700d732771fb8a563424fbc458ce561726d96c3eccf"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sdAck apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="4cbf9c0fedc1e76293f9ead7f9cb61d9f9e1cb8a54c8e4c19f91c0843f35dcb3"
EXPECT_MOD="b6b8a5f786c2f5cb9162117a45daaeaf1560fbe68948bbf900b202f4a96f77e8"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-sd-ack.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""sdAck: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== sdAck:"
EXPECT = "18daef1da37a85b5"
NEED = ["# ===== sdHealth:", "def sdh_view", "# ===== sdrFunk2:", "app = Flask("]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== sdAck: SD-/Datentraeger-Karte auf /pi - "Quittieren & neu pruefen" (schreibt nur sd_health_ack.json; prepper-sd-health.path startet die Pruefung), Info-Zeile andere Geraete; sendet nichts =====
import os as _sda_os
import json as _sda_json
import time as _sda_time

_SDA_ACK = _sda_os.path.join(_sda_os.path.dirname(_sda_os.path.abspath(__file__)), "sd_health_ack.json")
_sda_last = {"t": 0}


def _sda_api_ack():
    from flask import jsonify
    now = _sda_time.time()
    if now - _sda_last["t"] < 20:
        return jsonify({"ok": False, "error": "bitte 20 s warten", "ack_ts": int(_sda_last["t"])}), 429
    with open(_SDA_ACK, "w", encoding="utf-8") as f:
        f.write(_sda_json.dumps({"ts": int(now), "at": _sda_time.strftime("%d.%m.%Y %H:%M:%S", _sda_time.localtime(now)), "by": "dashboard"}))
    _sda_last["t"] = now
    print("sdAck: quittiert, Pruefung angestossen", flush=True)
    return jsonify({"ok": True, "ack_ts": int(now)})


_SDA_JS = """<script id="sda-js">
(function(){function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function go(){var c=document.getElementById('sdCard');var d;try{d=JSON.parse(document.getElementById('sdaData').textContent);}catch(e){return;}
if(!c||document.getElementById('sdaBox'))return;var b=el('div','');b.id='sdaBox';b.style.cssText='margin-top:6px;font-size:.72rem;color:#94a3b8';
var o=(d.other_24h||0),ob=(d.other_boot||0);
if(o||ob){var l=el('div','','USB/andere: '+Math.max(o,ob)+(d.other_disks&&d.other_disks.length?' ('+d.other_disks.join(', ')+')':'')+' · zählt nicht');l.style.color='#64748b';l.title=(d.other_lines||[]).join('\\n');b.appendChild(l);}
var r=el('div','','Datenträger '+(d.root_disk||'?')+(d.ack_at?' · quittiert '+d.ack_at:''));r.style.color='#64748b';b.appendChild(r);
var k=el('button','','✔ Quittieren & neu prüfen');k.type='button';k.style.cssText='margin-top:6px;background:#1e293b;color:#cbd5e1;border:1px solid #334155;border-radius:8px;padding:4px 9px;font-size:.72rem;cursor:pointer';
var s=el('span','');s.style.marginLeft='8px';
k.onclick=function(){if(!confirm('Bisherige Fehlermeldungen quittieren und Datenträger jetzt neu prüfen?'))return;k.disabled=true;s.textContent='prüfe …';var t0=d.ts||0;
fetch('/api/sd_health/ack',{method:'POST'}).then(function(x){return x.json();}).then(function(j){if(!j.ok){s.textContent=j.error||'Fehler';k.disabled=false;return;}var n=0;
(function p(){fetch('/api/sd_health').then(function(x){return x.json();}).then(function(v){if((v.ts||0)>t0&&(v.ack_ts||0)>=j.ack_ts){location.reload();return;}
if(++n<25)setTimeout(p,3000);else{s.textContent='keine neue Messung – Dienst prüfen';k.disabled=false;}}).catch(function(){if(++n<25)setTimeout(p,3000);});})();}).catch(function(){s.textContent='Fehler';k.disabled=false;});};
b.appendChild(k);b.appendChild(s);var f=c.querySelector('.pp-foot');if(f)c.insertBefore(b,f);else c.appendChild(b);}
document.addEventListener('DOMContentLoaded',go);setTimeout(go,900);setTimeout(go,2500);})();
</script>"""


def _sda_after(resp):
    try:
        from flask import request as _sda_req
        if _sda_req.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="sda-js"' in body:
            return resp
        v = sdh_view() if callable(globals().get("sdh_view")) else {}
        d = {k: v.get(k) for k in ("ts", "root_disk", "ack_ts", "ack_at", "other_24h", "other_boot", "other_disks", "other_lines")}
        blk = ('<script type="application/json" id="sdaData">%s</script>' % _sda_json.dumps(d, ensure_ascii=False).replace("<", "\\u003c")) + _SDA_JS
        j = body.rfind("</body>")
        body = (body[:j] + blk + body[j:]) if j >= 0 else (body + blk)
        resp.set_data(body)
    except Exception as e:
        print("sdAck /pi:", e, flush=True)
    return resp


try:
    if "sda_ack" not in app.view_functions:
        app.add_url_rule("/api/sd_health/ack", endpoint="sda_ack", view_func=_sda_api_ack, methods=["POST"])
except Exception as _sda_e:
    print("sdAck Route:", _sda_e, flush=True)
app.after_request(_sda_after)
print("sdAck aktiv", flush=True)
# ===== /sdAck =====
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
    if "/api/sd_health/ack" in src or 'id="sda-js"' in src:
        raise SystemExit("STOP: sdAck-Teile gibt es schon - nichts geaendert")
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
cat > "$W/prepper-sd-health.py" << 'MODPY_EOF'
#!/usr/bin/env python3
"""sdHealth: stuendliche SD-Karten-Pruefung (nur lesen + 4-KB-Schreibprobe). Schreibt sd_health.json atomar.
Laeuft als root ueber prepper-sd-health.timer (+ .path: Quittieren im Dashboard startet sofort eine Pruefung).
v2: Wurzel-Datentraeger automatisch (findmnt / -> Eltern-Disk, auch SSD sda), nur dessen Kernel-Fehler zaehlen;
andere Geraete (USB-Leser beim Klonen) nur als Info. Fehler vor der Quittierung (sd_health_ack.json) zaehlen nicht. Aendert nichts an Karte/Dateisystem. Sendet nichts."""
import json
import os
import pwd
import re
import subprocess
import time
from datetime import datetime

DEV_ENV = os.environ.get("SDH_DEV", "")
ACK = os.environ.get("SDH_ACK", "/home/fmg/prepper-dashboard/sd_health_ack.json")
SYS = os.environ.get("SDH_SYS", "/sys")
OUT = os.environ.get("SDH_OUT", "/home/fmg/prepper-dashboard/sd_health.json")
STATE_DIR = os.environ.get("SDH_STATE", "/var/lib/prepper-sd-health")
OWNER = os.environ.get("SDH_OWNER", "fmg")
GB_DAY_YELLOW = 20.0
VERSION = 2
RE_DEVTOK = re.compile(r"\b(mmcblk\d+(?:p\d+)?|mmc\d+|sd[a-z]{1,2}\d*|nvme\d+n\d+(?:p\d+)?|nvme\d+|vd[a-z]\d*)\b")
RE_SCSI = re.compile(r"\bsd \d+:\d+:\d+:\d+:")

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


def disk_of(tok):
    """Partition/Host-Name -> Disk-Name (mmcblk0p2->mmcblk0, mmc0->mmcblk0, sda1->sda, nvme0n1p2->nvme0n1)."""
    m = re.match(r"^(mmcblk\d+)(?:p\d+)?$", tok)
    if m:
        return m.group(1)
    m = re.match(r"^mmc(\d+)$", tok)
    if m:
        return "mmcblk" + m.group(1)
    m = re.match(r"^(nvme\d+n\d+)(?:p\d+)?$", tok)
    if m:
        return m.group(1)
    m = re.match(r"^nvme(\d+)$", tok)
    if m:
        return "nvme%sn1" % m.group(1)
    m = re.match(r"^((?:sd|vd)[a-z]{1,2}?)\d*$", tok)
    if m:
        return m.group(1)
    return tok


def line_disks(ln):
    return {disk_of(t) for t in RE_DEVTOK.findall(ln)}


def line_ts(ln):
    try:
        t = ln.split(" ", 1)[0]
        return datetime.strptime(t[:19], "%Y-%m-%dT%H:%M:%S").timestamp() if len(t) >= 19 and t[4] == "-" else None
    except Exception:
        return None


def classify(lines, disk=None, since=0):
    """-> (Fehler, Warnungen) des Wurzel-Datentraegers, (Fehler, Warnungen) anderer Geraete."""
    errs, warns, oerrs, owarns = [], [], [], []
    for ln in lines:
        if not REL.search(ln) or NORMAL.search(ln):
            continue
        if since:
            t = line_ts(ln)
            if t is not None and t < since:
                continue
        ds = line_disks(ln)
        if RE_SCSI.search(ln) and not ds:
            ds = {"scsi"}
        mine = (not ds) or disk is None or disk in ds
        if ERR.search(ln):
            (errs if mine else oerrs).append(ln[:200])
        elif WARN.search(ln):
            (warns if mine else owarns).append(ln[:200])
    return errs, warns, oerrs, owarns


def root_disk(src, sysdir=None):
    """Eltern-Disk der Wurzel-Partition ueber sysfs (mmcblk0p2 -> mmcblk0, sda2 -> sda)."""
    sysdir = sysdir or SYS
    part = os.path.basename(src or "")
    if not part:
        return None
    p = os.path.join(sysdir, "class", "block", part)
    try:
        real = os.path.realpath(p)
        if os.path.exists(os.path.join(real, "partition")):
            return os.path.basename(os.path.dirname(real))
        if os.path.isdir(real):
            return part
    except Exception:
        pass
    return disk_of(part)


def read_ack(now):
    try:
        with open(ACK, "r") as f:
            v = json.load(f)
        t = float(v.get("ts") if isinstance(v, dict) else v)
        if 1.5e9 < t <= now + 60:
            return min(t, now)
    except Exception:
        pass
    return 0


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
    src, opts = root_info()
    rc, o = run(["findmnt", "-n", "-o", "SOURCE", "/"])
    if rc == 0 and o.strip().startswith("/dev/"):
        src = o.strip()
    DEV = DEV_ENV or root_disk(src) or "mmcblk0"
    dev = os.path.join(SYS, "block", DEV)
    card = {k: rd(os.path.join(dev, "device", k)) for k in ("name", "manfid", "oemid", "date", "type", "serial", "model", "vendor")}
    card["months"] = card_age(card.get("date") or "")
    card["kind"] = "sd" if DEV.startswith("mmcblk") else ("nvme" if DEV.startswith("nvme") else "usb/sata")
    ack = read_ack(now)
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
    e24, w24, o24, ow24 = classify(k24 or [], DEV, ack)
    eb, wb, ob, owb = classify(kb0 or [], DEV, ack)
    # ext4-Zaehler: Quittierung setzt die Basis (Zaehler selbst bleibt im Dateisystem)
    try:
        e4n = int(ext4["errors_count"] or 0)
    except Exception:
        e4n = 0
    if ack and st.get("ack_ts") != ack:
        st["ack_ts"] = ack
        st["ack_ext4"] = e4n
        st["ack_t2"] = None
    base_e4 = (st.get("ack_ext4") or 0) if ack else 0
    ro = bool(opts) and opts.split(",")[0] == "ro"
    pok, perr = probe(STATE_DIR)
    t2 = tune2fs(src)
    try:
        t2n = int(t2.get("FS Error count") or 0)
    except Exception:
        t2n = 0
    if ack and st.get("ack_t2") is None:
        st["ack_t2"] = t2n
    base_t2 = (st.get("ack_t2") or 0) if ack else 0
    reasons_red, reasons_yel = [], []
    if e24 or eb:
        reasons_red.append("Kernel meldet I/O- oder EXT4-Fehler auf %s (%d in 24 h, %d seit Start)" % (DEV, len(e24), len(eb)))
    try:
        if e4n > base_e4:
            reasons_red.append("ext4-Fehlerzaehler %s%s" % (e4n, (" (seit Quittierung +%d)" % (e4n - base_e4)) if base_e4 else ""))
    except Exception:
        pass
    if t2n > base_t2:
        reasons_red.append("tune2fs FS Error count %s" % t2n)
    if ro:
        reasons_red.append("Wurzel-Dateisystem nur lesbar eingehaengt")
    if not pok:
        reasons_red.append("Schreibprobe fehlgeschlagen%s" % ((": " + perr) if perr else ""))
    if w24 or wb:
        reasons_yel.append("Warnungen %s (Timeout/CRC/Reset): %d in 24 h" % (DEV, len(w24 or wb)))
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
        "root_disk": DEV, "ack_ts": int(ack) if ack else None,
        "ack_at": datetime.fromtimestamp(ack).strftime("%d.%m.%Y %H:%M") if ack else None,
        "ext4_errors_since_ack": (e4n - base_e4) if ack else None,
        "other_24h": len(o24), "other_boot": len(ob), "other_warn_24h": len(ow24),
        "other_disks": sorted({d for ln in (o24 + ob + ow24) for d in line_disks(ln)} - {DEV})[:6],
        "other_lines": (o24 or ob)[-3:],
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
MODPY_EOF

# ---------- 0) Bytes + AST-Guards ----------
P="$W/patch-sd-ack.py"; S="$W/prepper-sd-health.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $S" | sha256sum -c - >/dev/null || { echo "STOP: Pruefskript sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
python3 -W error::SyntaxWarning -m py_compile "$S" || { echo "STOP: Pruefskript py_compile - nichts geaendert"; exit 1; }
set +e
python3 - "$P" "$S" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
nopen = 0
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in ("requests", "urllib", "socket", "http", "meshtastic", "subprocess"):
                print("Block: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        f = node.func
        fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("update_all", "urlopen", "Popen", "system", "run", "call", "remove", "unlink"):
            print("Block: verbotener Aufruf", fn); hit = True
        if fn == "open":
            nopen += 1
            if not (node.args and isinstance(node.args[0], ast.Name) and node.args[0].id == "_SDA_ACK"):
                print("Block: open auf anderes Ziel"); hit = True
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
        print("Block: data_store-Schreiben"); hit = True
if nopen != 1:
    print("Block: open-Anzahl", nopen); hit = True
mod = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
for node in ast.walk(ast.parse(mod)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in ("requests", "urllib", "socket", "http", "meshtastic"):
                print("Skript: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        for kw in node.keywords:
            if kw.arg == "shell":
                print("Skript: shell="); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and isinstance(node.elts[0].value, str):
        v = node.elts[0].value
        if v in ("rm", "mkfs", "fsck", "dd", "e2fsck", "tune2fs -O", "systemctl", "sudo", "mount", "umount"):
            print("Skript: Programm", v); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Mesh, Dashboard schreibt nur sd_health_ack.json, Skript nur lesen)"

# ---------- 1) Voraussetzungen ----------
[[ -f "$UNIT_DIR/prepper-sd-health.service" && -f "$SCRIPT" ]] || { echo "STOP: sdHealth (8802e514) nicht installiert - nichts geaendert"; exit 1; }
CUR_SHA=$(sha256sum "$SCRIPT" | cut -d' ' -f1)
if [[ "$CUR_SHA" != "$V1_SHA" && "$CUR_SHA" != "$EXPECT_MOD" ]]; then echo "STOP: $SCRIPT unbekannter Stand ($CUR_SHA) - nichts geaendert"; exit 1; fi
RSRC=$(findmnt -n -o SOURCE / 2>/dev/null || true)
RDISK=$(lsblk -no PKNAME "$RSRC" 2>/dev/null | head -1 || true)
echo "Wurzel: ${RSRC:-?} -> Datentraeger ${RDISK:-?}"

# ---------- 2) Trockenlauf (Dashboard + Pruefskript in Testverzeichnis als root) ----------
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
sudo -v
mkdir -p "$W/dry/state"
# shellcheck disable=SC2024
sudo env SDH_OUT="$W/dry/sd_health.json" SDH_STATE="$W/dry/state" SDH_OWNER="$(id -un)" SDH_ACK="$ACKF" python3 "$S" > "$W/dry/out.txt" 2>&1 || { cat "$W/dry/out.txt"; echo "STOP: Pruefskript v2 Testlauf - nichts geaendert"; exit 1; }
python3 - "$W/dry/sd_health.json" "${RDISK:-}" << 'PY' || { echo "STOP: Testlauf-Ergebnis ungueltig - nichts geaendert"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("version") == 2 and d.get("root_disk"), d
if sys.argv[2]:
    assert d["root_disk"] == sys.argv[2], (d["root_disk"], sys.argv[2])
print("Testlauf v2: Stufe %s · Datentraeger %s · Kernel-Fehler 24h %s · andere Geraete %s %s" % (d["level"], d["root_disk"], d["errors_24h"], d["other_24h"], d.get("other_disks")))
for r in d.get("reasons") or []:
    print("  Grund:", r)
PY
echo "OK Trockenlauf idempotent + Pruefskript v2 laeuft"
cat > "$W/prepper-sd-health.path" << UNIT_EOF
[Unit]
Description=Prepper SD-Pruefung sofort nach Quittieren im Dashboard (sdAck)

[Path]
PathChanged=$ACKF
Unit=prepper-sd-health.service
TriggerLimitIntervalSec=60
TriggerLimitBurst=5

[Install]
WantedBy=paths.target
UNIT_EOF
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /pi /funk /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /funk=${PRE[/funk]} /energie=${PRE[/energie]}"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l)

same=1
cmp -s "$W/work/dashboard.py" "$F" || same=0
cmp -s "$S" "$SCRIPT" || same=0
cmp -s "$W/prepper-sd-health.path" "$UNIT_DIR/prepper-sd-health.path" 2>/dev/null || same=0
systemctl is-active --quiet prepper-sd-health.path 2>/dev/null || same=0
if [[ "$same" == 1 ]]; then
  echo "OK sdAck schon installiert - kein Neustart"
else
  NEW_PATH=0; [[ -f "$UNIT_DIR/prepper-sd-health.path" ]] || NEW_PATH=1
  rb() {
    echo "ROLLBACK: $1"
    if [[ "$NEW_PATH" == 1 ]]; then sudo systemctl disable --now prepper-sd-health.path >/dev/null 2>&1 || true; sudo rm -f "$UNIT_DIR/prepper-sd-health.path"; fi
    sudo install -m 0755 -o root -g root "$W/script.bak" "$SCRIPT" || true
    sudo systemctl daemon-reload || true
    cp -a "$F.bak-sdack-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    sudo systemctl start prepper-sd-health.service 2>/dev/null || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-sdack-$TS"
  }
  cp -a "$F" "$F.bak-sdack-$TS"
  cp "$SCRIPT" "$W/script.bak"
  sudo cp -a "$SCRIPT" "$SCRIPT.bak-sdack-$TS"
  sudo install -m 0755 -o root -g root "$S" "$SCRIPT" || { rb "Skript installieren"; exit 1; }
  sudo install -m 0644 -o root -g root "$W/prepper-sd-health.path" "$UNIT_DIR/prepper-sd-health.path" || { rb "Path-Unit"; exit 1; }
  sudo systemctl daemon-reload
  sudo systemctl enable --now prepper-sd-health.path >/dev/null 2>&1 || { rb "Path-Unit aktivieren"; exit 1; }
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  ac=$(code "$B/api/sd_health/ack")
  [[ "$ac" == "405" ]] || { rb "/api/sd_health/ack fehlt ($ac)"; exit 1; }
  echo "OK /api/sd_health/ack vorhanden (nur POST)"
  # Ausloeser pruefen ohne zu quittieren: Ack-Datei mit gleichem Inhalt neu schreiben
  T0=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('ts',0))" "$OUTF" 2>/dev/null || echo 0)
  if [[ -f "$ACKF" ]]; then cp "$ACKF" "$W/ack.same"; cat "$W/ack.same" > "$ACKF"; else echo '{}' > "$ACKF"; fi
  T1=$T0
  for i in $(seq 1 30); do sleep 2; T1=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('ts',0))" "$OUTF" 2>/dev/null || echo 0); [[ "$T1" != "$T0" ]] && break; done
  [[ "$T1" != "$T0" ]] || { rb "Path-Unit startet die Pruefung nicht"; exit 1; }
  echo "OK Pruefung per Path-Unit ausgeloest (ohne Quittierung)"
  python3 - "$OUTF" << 'PY' || { rb "sd_health.json v2 ungueltig"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("version") == 2 and d.get("root_disk")
print("SD-Pruefung: Stufe %s · Datentraeger %s · Kernel-Fehler 24h %s / seit Start %s · andere Geraete %s %s" % (
    d["level"], d["root_disk"], d["errors_24h"], d["errors_boot"], max(d["other_24h"], d["other_boot"]), d.get("other_disks") or ""))
for r in d.get("reasons") or []:
    print("  Grund:", r)
if d["errors_24h"] or d["errors_boot"]:
    print("WARN echte Fehler auf dem Wurzel-Datentraeger - bitte ansehen:")
    for x in d.get("error_lines") or []:
        print("   ", x[:150])
elif d["level"] == "green":
    print("OK gruen - sda-/USB-Fehler zaehlen nicht mehr")
else:
    print("WARN Stufe %s aus anderem Grund (siehe Gruende)" % d["level"])
PY
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] && grep -q 'id="sda-js"' "$W/pi.html" && grep -q 'id="sdCard"' "$W/pi.html" || { rb "/pi ohne Quittier-Knopf"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l)
    [[ "$R1" == "$R0" ]] || { rb "/pi Sicherung veraendert"; exit 1; }
    echo "OK /pi mit Quittier-Knopf (Sicherung unveraendert, doPrepperRestore $R1)"
  fi
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'sdAck' | tail -2 || true
fi
fail=0
for p in / /pi /funk /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-sdack-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "Path-Unit: $(systemctl is-active prepper-sd-health.path 2>/dev/null || true) · Timer: $(systemctl is-active prepper-sd-health.timer 2>/dev/null || true)"
echo "OK guards sdAck=$(grep -q '# ===== sdAck:' "$F" && echo 1 || echo 0) sdHealth=$(grep -q '# ===== sdHealth:' "$F" && echo 1 || echo 0) sdrFunk2=$(grep -q '# ===== sdrFunk2:' "$F" && echo 1 || echo 0) piPolish2=$(grep -q '# ===== piPolish2:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-sdack-$TS" ]] && echo "Backup: $F.bak-sdack-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG sdAck=1"
