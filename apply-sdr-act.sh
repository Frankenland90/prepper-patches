#!/bin/bash
set -euo pipefail
# sdrAct: zwei Presets der Art "Aktivitaet" (nur Kanalpegel gegen Rauschen, kein Demodulieren, keine Aufnahme, kein Inhalt):
# 145,500 MHz (2 m Anruf) und 446,03125 MHz (PMR446 Kanal 3), nur bei manueller Auswahl. Je Minute Belegung %, Spitze dBFS,
# Anzahl Aussendungen -> activity_state.json + archive/linelog (nur Zahlen). Kachel-Zeile "Aktivitaet: ...". Meteor-Labels M2 3/4.
# Nur bei dashboard.py sha16 17498540a84ff136 (sdrPreset). Neustart nur prepper-sdr + prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdr5-apply
UNIT="prepper-sdr.service"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sdrAct apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="5b6ab7af7a5511b62e3ec1117d2cc64a11078ae028a07b73d49f3e885631c860"
EXPECT_MOD="c077c8fb04889be4688af880b0b3f136cd59520f1be5c8eb97e2775b71fca930"
EXPECT_NET="1ffc61d0268fd874e5ff0b5f9a85274875c73a31051b5eb7b067092a90ac2336"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-sdr-act.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""sdrAct: Block vor __main__ in dashboard.py (Aktivitaets-Zeile auf der Funk-SDR-Kachel, /api/sdr/activity). Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== sdrAct:"
EXPECT = "17498540a84ff136"
NEED = ["# ===== sdrPreset:", "# ===== /sdrPreset =====", "def _sdrq_api_preset", "# ===== sdrPlus:", "# ===== /sdrPlus =====", "# ===== sdrFunk2:", "# ===== sdrFunk:", "def _sdr_status():", "sdrBtns(c,d,poll);",
        "'auto':'Automatik'};", "var t=(SDRN[a]||", "app = Flask("]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== sdrAct: Aktivitaets-Zeile (nur Pegel/Belegung, kein Inhalt) auf der Funk-SDR-Kachel + /api/sdr/activity; nur Empfang =====
_sdra_prev_status = _sdr_status


def _sdra_summary():
    st = _sdr_load("activity_state.json", {}) or {}
    now = _sdr_time.time()
    out = []
    names = {}
    if _sdr_mod is not None:
        for x in getattr(_sdr_mod, "PRESETS", []):
            if x.get("kind") in getattr(_sdr_mod, "ACT_KINDS", ()):
                names[x["id"]] = x.get("short") or x["id"]
    for pid, short in names.items():
        ser = [r for r in ((st.get("series") or {}).get(pid) or []) if isinstance(r, dict)]
        last = ser[-1] if ser else None
        hour = [r for r in ser if last and last.get("t", 0) - r.get("t", 0) < 3600 and r.get("s", 0) >= 20]
        occ = round(sum(r.get("occ_pct") or 0 for r in hour) / len(hour), 1) if hour else None
        out.append({"id": pid, "short": short, "occ_pct": occ, "tx": sum(r.get("tx") or 0 for r in hour) if hour else None,
                    "peak_dbfs": max((r.get("peak_dbfs") for r in hour if r.get("peak_dbfs") is not None), default=None),
                    "last_t": last.get("t") if last else None, "min": len(hour), "age_s": int(now - last["t"]) if last else None})
    return out


def _sdr_status():
    d = _sdra_prev_status()
    try:
        d["act"] = _sdra_summary()
    except Exception as e:
        d["act_err"] = str(e)[:100]
    return d


def _sdra_api():
    from flask import jsonify
    st = _sdr_load("activity_state.json", {}) or {}
    ser = {k: v[-180:] for k, v in (st.get("series") or {}).items() if isinstance(v, list)}
    return jsonify({"ok": True, "summary": _sdra_summary(), "series": ser})


_SDRA_LINE = r"""(function(){var A=d.act||[];if(!A.length)return;var parts=A.map(function(x){return x.short+' '+(x.occ_pct===null||x.occ_pct===undefined?'–':String(x.occ_pct).replace('.',',')+'%');});
var tip=A.map(function(x){return x.short+': '+(x.min||0)+' Messminuten (letzte Std. der Messung), '+(x.tx===null?'–':x.tx)+' Aussendungen, Spitze '+(x.peak_dbfs===null?'–':x.peak_dbfs+' dBFS')+(x.last_t?', zuletzt '+sdrHM(x.last_t):'');}).join(' | ');
var el=ln(c,'📶 Aktivität: '+parts.join(' · '),'#94a3b8');el.title=tip+' – nur Pegel, kein Inhalt; Messung nur bei Auswahl';})();"""


def _sdra_patch_js():
    global _SDR_TILE_JS
    k = "sdrBtns(c,d,poll);"
    t = _SDR_TILE_JS
    if t.count(k) == 1 and "Aktivität: " not in t:
        t = t.replace(k, _SDRA_LINE + k)
    _SDR_TILE_JS = t
    return t.count("Aktivität: ")


try:
    _sdra_ok = _sdra_patch_js()
    if "sdra_api" not in app.view_functions and not any(r.rule == "/api/sdr/activity" for r in app.url_map.iter_rules()):
        app.add_url_rule("/api/sdr/activity", endpoint="sdra_api", view_func=_sdra_api, methods=["GET"])
    print("sdrAct aktiv: Kachel=%s" % _sdra_ok, flush=True)
except Exception as _sdr_e:
    print("sdrAct:", _sdr_e, flush=True)
# ===== /sdrAct =====
'''


def h16(s):
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    h = h16(src)
    if MARK in src:
        print("RESULT dashboard.py=schon sha16 %s" % h)
        return
    st = "sha16 ok" if h == EXPECT else None
    if st is None and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    miss = [a for a in NEED if a not in src]
    if miss:
        raise SystemExit("STOP: fehlt %s - nichts geaendert" % miss)
    if "/api/sdr/activity" in src or "def _sdra_" in src:
        raise SystemExit("STOP: sdrAct-Teile gibt es schon - nichts geaendert")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (%s; sha16 vorher %s, nachher %s)" % (st or "nosha", h, h16(new)))


if __name__ == "__main__":
    main()
PATCHPY_EOF
cat > "$W/prepper_sdr.py" << 'MODPY_EOF'
#!/usr/bin/env python3
"""prepper_sdr: SDR-Planer fuer den RTL-SDR-Stick (nur Empfang, sendet nichts - weder Funk noch Mesh).

Ein Programm besitzt den Stick und teilt ihn zeitlich auf:
  433  = rtl_433 auf 433,92 MHz (ISM-Sensoren) -> rtl433.jsonl + funk433_state.json
  aprs = rtl_fm 144,800 MHz | direwolf (APRS, Amateurfunk) -> aprs.jsonl + aprs_state.json
  tcp  = rtl_tcp Port 1234 fuer SDR-Apps im LAN (Decoder pausiert, endet automatisch)
  bc   = alle 30 min kurzer Rundfunk-Block: UKW-RDS (rtl_fm | redsea: PS/Radiotext/TA) + DAB+ (welle-cli: DLS/Ansagen)
  meteor = Wettersatellit Meteor-M LRPT 137,9 MHz (satdump) bei Ueberfluegen >= 20 Grad, hat dann Vorrang
Nur Empfang: Rundfunk + Wettersatellit + ISM + Amateurfunk.
Betriebsart steht in sdr_mode.json (schreibt das Dashboard). Status: sdr_status.json.
Fehlt der Stick, wartet der Planer ruhig (kein Neustart-Karussell). Nur ISM/Amateurfunk, keine Pager-/BOS-Dekodierung.
Aufruf: prepper_sdr.py run | selftest | status
"""
import json
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time

V = 4
BASE = os.path.dirname(os.path.abspath(__file__))
MODES = ("auto", "433", "aprs", "tcp", "off")
DEFAULT_CFG = {
    "slice_433_s": 300, "slice_aprs_s": 300, "auto": ["433", "aprs"],
    "f433": "433.92M", "faprs": "144.800M", "ppm": 0, "gain_433": None, "gain_aprs": None,
    "device": None, "tcp_port": 1234, "tcp_bind": "0.0.0.0", "tcp_default_min": 60, "tcp_max_min": 480,
    "usb_ids": ["0bda:2838", "0bda:2832"], "max_jsonl_mb": 8, "aprs_max_jsonl_mb": 4,
    "home": None, "keep_days": 14,
    "bc_enable": True, "bc_interval_s": 1800, "fm": None, "fm_s": 25, "dab": None, "dab_s": 60, "dab_port": 7979, "gain_fm": None, "gain_dab": None, "gain_act": None,
    "meteor_enable": True, "sats": None, "meteor_min_el": 20, "meteor_gain": 38, "meteor_samplerate": "1024000",
    "meteor_keep": 30, "meteor_cap_mb": 300, "meteor_tmp": "/tmp/prepper-meteor", "tle_refresh_h": 12,
    "redsea": None, "welle": None, "satdump": None,
    "linelog_enable": True, "linelog_keyword": None, "linelog_flush_s": 300, "linelog_part_kb": 512, "linelog_keep_days": 14,
}

# ---------------------------------------------------------------- Frequenz-Whitelist (einzige Quelle; Dashboard + Planer nutzen sie)
# Nur Empfang. Erlaubte Bereiche in MHz - alles andere wird verweigert (auch aus sdr_config.json).
F_RANGES = {"ism433": (433.05, 434.79), "srd868": (863.0, 870.0), "aprs": (144.8, 144.8), "fm": (87.5, 108.0),
            "dab": (174.0, 240.0), "wxsat": (137.0, 138.0),
            "act2m": (145.5, 145.5), "pmr446": (446.0, 446.2)}
# nur Aktivitaetsmessung (Kanalleistung gegen Rauschen) - kein Demodulieren, keine Aufnahme, kein Inhalt
ACT_KINDS = ("act2m", "pmr446")
# DAB Band III Kanaltabelle (Mittenfrequenz MHz) - DAB nur ueber Kanalnamen
DAB_CHANNELS = {"5A": 174.928, "5B": 176.640, "5C": 178.352, "5D": 180.064, "6A": 181.936, "6B": 183.648, "6C": 185.360, "6D": 187.072,
                "7A": 188.928, "7B": 190.640, "7C": 192.352, "7D": 194.064, "8A": 195.936, "8B": 197.648, "8C": 199.360, "8D": 201.072,
                "9A": 202.928, "9B": 204.640, "9C": 206.352, "9D": 208.064, "10A": 209.936, "10B": 211.648, "10C": 213.360, "10D": 215.072,
                "11A": 216.928, "11B": 218.640, "11C": 220.352, "11D": 222.064, "12A": 223.936, "12B": 225.648, "12C": 227.360, "12D": 229.072,
                "13A": 230.784, "13B": 232.496, "13C": 234.208, "13D": 235.776, "13E": 237.488, "13F": 239.200}
# Feste Auswahl fuer die Funk-Kachel (Preset-ID -> Empfang). Keine freie Frequenz.
PRESETS = [
    {"id": "433", "group": "Sensoren", "label": "433,92 MHz Sensoren (rtl_433)", "kind": "ism433", "f": "433.92M"},
    {"id": "868", "group": "Sensoren", "label": "868,3 MHz Sensoren (rtl_433)", "kind": "srd868", "f": "868.3M"},
    {"id": "aprs", "group": "Amateurfunk", "label": "APRS 144,800 MHz (direwolf)", "kind": "aprs", "f": "144.800M"},
    {"id": "fm_br24", "group": "UKW-RDS", "label": "BR24 102,0", "kind": "fm", "f": "102.0M", "name": "BR24"},
    {"id": "fm_b3", "group": "UKW-RDS", "label": "Bayern 3 97,9", "kind": "fm", "f": "97.9M", "name": "Bayern 3"},
    {"id": "fm_b1", "group": "UKW-RDS", "label": "Bayern 1 88,9", "kind": "fm", "f": "88.9M", "name": "Bayern 1"},
    {"id": "fm_b2", "group": "UKW-RDS", "label": "Bayern 2 92,3", "kind": "fm", "f": "92.3M", "name": "Bayern 2"},
    {"id": "fm_brk", "group": "UKW-RDS", "label": "BR-Klassik 87,6", "kind": "fm", "f": "87.6M", "name": "BR-Klassik"},
    {"id": "fm_gong", "group": "UKW-RDS", "label": "Gong 97,1 (Nürnberg)", "kind": "fm", "f": "97.1M", "name": "Gong 97,1"},
    {"id": "fm_chari", "group": "UKW-RDS", "label": "Charivari 98,6 (Nürnberg)", "kind": "fm", "f": "98.6M", "name": "Charivari"},
    {"id": "fm_n1", "group": "UKW-RDS", "label": "Hit Radio N1 92,9 (Nürnberg)", "kind": "fm", "f": "92.9M", "name": "Hit Radio N1"},
    {"id": "fm_980", "group": "UKW-RDS", "label": "UKW 98,0 MHz", "kind": "fm", "f": "98.000M", "name": "UKW 98,0"},
    {"id": "dab_11D", "group": "DAB+", "label": "11D BR Bayern", "kind": "dab", "ch": "11D"},
    {"id": "dab_8C", "group": "DAB+", "label": "8C BR Mittelfranken", "kind": "dab", "ch": "8C"},
    {"id": "dab_10C", "group": "DAB+", "label": "10C Nürnberg lokal", "kind": "dab", "ch": "10C"},
    {"id": "dab_5C", "group": "DAB+", "label": "5C DR Deutschland", "kind": "dab", "ch": "5C"},
    {"id": "dab_5D", "group": "DAB+", "label": "5D Antenne DE", "kind": "dab", "ch": "5D"},
    {"id": "met_1379", "group": "Wettersatellit", "label": "Meteor-M2 3/4 · 137,9 MHz (satdump)", "kind": "wxsat", "f": "137.9e6"},
    {"id": "met_1371", "group": "Wettersatellit", "label": "Meteor-M2 3/4 · 137,1 MHz Ersatzfrequenz (satdump)", "kind": "wxsat", "f": "137.1e6"},
    {"id": "act_1455", "group": "Aktivität (nur Pegel)", "label": "2 m Anruf 145,500 – nur Aktivität", "kind": "act2m", "f": "145.500M", "short": "145,500"},
    {"id": "act_pmr3", "group": "Aktivität (nur Pegel)", "label": "PMR446 Kanal 3 446,03125 – nur Aktivität", "kind": "pmr446", "f": "446.03125M", "short": "PMR3"},
]
PRESET_IDS = tuple(x["id"] for x in PRESETS)
PRESET_MINUTES = (30, 60, 120)


def preset(pid):
    for x in PRESETS:
        if x["id"] == pid:
            return x
    return None


def to_mhz(v):
    """'433.92M' / '137.9e6' / Zahl (Hz oder MHz) -> MHz (float) oder None."""
    try:
        if isinstance(v, (int, float)):
            x = float(v)
        else:
            t = str(v).strip()
            if t.endswith("M"):
                return float(t[:-1])
            if t.endswith("k"):
                return float(t[:-1]) / 1000.0
            x = float(t)
        return x / 1e6 if x > 10000 else x
    except Exception:
        return None


def tune_ok(kind, f=None, ch=None):
    """True nur wenn die Frequenz im erlaubten Bereich der Art liegt (DAB nur per Kanaltabelle)."""
    if kind == "dab":
        mhz = DAB_CHANNELS.get(str(ch))
        lo, hi = F_RANGES["dab"]
        return mhz is not None and lo <= mhz <= hi
    if kind not in F_RANGES:
        return False
    mhz = to_mhz(f)
    if mhz is None:
        return False
    lo, hi = F_RANGES[kind]
    if kind == "aprs":
        return abs(mhz - 144.8) < 1e-6
    if kind == "act2m":
        return abs(mhz - 145.5) < 1e-6
    return lo <= mhz <= hi


def check_tune(kind, f=None, ch=None):
    if not tune_ok(kind, f, ch):
        raise RuntimeError("Frequenz verweigert: %s %s" % (kind, f if ch is None else ch))

HOME_FALLBACK = (49.56, 11.13)


# ---------------------------------------------------------------- Dateien
def p(name, base=None):
    return os.path.join(base or BASE, name)


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def config(base=None):
    c = dict(DEFAULT_CFG)
    u = load_json(p("sdr_config.json", base), {}) or {}
    if isinstance(u, dict):
        for k, v in u.items():
            if k in c:
                c[k] = v
    if not c.get("home"):
        c["home"] = list(home_from_config(base))
    return c


def home_from_config(base=None):
    try:
        txt = open(p("config.py", base), encoding="utf-8").read()
        la = re.search(r"^WEATHER_LAT\s*=\s*([0-9.+-]+)", txt, re.M)
        lo = re.search(r"^WEATHER_LON\s*=\s*([0-9.+-]+)", txt, re.M)
        if la and lo:
            a, b = float(la.group(1)), float(lo.group(1))
            if 47 < a < 56 and 5 < b < 16:
                return (a, b)
    except Exception:
        pass
    return HOME_FALLBACK


def get_mode(base=None):
    d = load_json(p("sdr_mode.json", base), {}) or {}
    if d.get("mode") == "preset":
        u = d.get("until")
        if d.get("preset") in PRESET_IDS and isinstance(u, (int, float)) and u > time.time():
            return {"mode": "preset", "preset": d["preset"], "until": u, "at": d.get("at")}
        return {"mode": "auto", "until": None, "at": d.get("at")}
    m = d.get("mode") if d.get("mode") in MODES else "auto"
    until = d.get("until")
    if m == "tcp" and (not isinstance(until, (int, float)) or until <= time.time()):
        m = "auto"
    if m in ("433", "aprs") and isinstance(until, (int, float)) and until <= time.time():
        m = "auto"
    return {"mode": m, "until": until if m != "auto" else None, "at": d.get("at")}


def set_mode(base, mode, minutes=None):
    """Vom Dashboard: Betriebsart setzen (nur Datei schreiben; der Planer reagiert in ~2 s)."""
    if mode not in MODES:
        raise ValueError("mode")
    c = config(base)
    until = None
    if mode == "tcp":
        mins = minutes if isinstance(minutes, (int, float)) and minutes > 0 else c["tcp_default_min"]
        until = int(time.time() + 60 * min(float(mins), float(c["tcp_max_min"])))
    elif mode in ("433", "aprs") and isinstance(minutes, (int, float)) and minutes > 0:
        until = int(time.time() + 60 * min(float(minutes), 1440.0))
    write_json(p("sdr_mode.json", base), {"mode": mode, "until": until, "at": int(time.time())})
    return get_mode(base)


def set_preset(base, pid, minutes):
    """Vom Dashboard: festes Preset fuer 30/60/120 min, danach Automatik. Nur IDs aus PRESETS."""
    if not isinstance(pid, str) or pid not in PRESET_IDS:
        raise ValueError("preset")
    if isinstance(minutes, bool) or not isinstance(minutes, int) or minutes not in PRESET_MINUTES:
        raise ValueError("minutes")
    write_json(p("sdr_mode.json", base), {"mode": "preset", "preset": pid, "until": int(time.time() + 60 * minutes), "at": int(time.time())})
    return get_mode(base)


def stick_info(ids):
    """USB-Stick per sysfs suchen (ohne Programmstart)."""
    root = os.environ.get("SDR_SYSFS_USB", "/sys/bus/usb/devices")
    out = []
    try:
        names = sorted(os.listdir(root))
    except Exception:
        return out
    for n in names:
        d = os.path.join(root, n)
        try:
            vid = open(os.path.join(d, "idVendor")).read().strip()
            pid = open(os.path.join(d, "idProduct")).read().strip()
        except Exception:
            continue
        if "%s:%s" % (vid, pid) in ids:
            info = {"usb": "%s:%s" % (vid, pid), "bus": n}
            for k in ("manufacturer", "product", "serial"):
                try:
                    info[k] = open(os.path.join(d, k)).read().strip()
                except Exception:
                    pass
            out.append(info)
    return out


def rotate(path, max_mb):
    try:
        if os.path.getsize(path) > max_mb * 1024 * 1024:
            os.replace(path, path + ".1")
    except Exception:
        pass


# ---------------------------------------------------------------- Geo
def dist_km(a, b, c, d):
    r = 6371.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def bearing(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    dl = math.radians(d - b)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


# ---------------------------------------------------------------- rtl_433
KEEP433 = ("model", "id", "channel", "subtype", "battery_ok", "temperature_C", "temperature_F", "humidity", "pressure_hPa",
           "wind_avg_km_h", "wind_max_km_h", "wind_avg_m_s", "wind_max_m_s", "wind_dir_deg", "rain_mm", "rain_rate_mm_h",
           "uv", "light_lux", "moisture", "button", "state", "event", "code", "rssi", "snr", "noise", "freq", "protocol")


def parse_433(line):
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None
    if not isinstance(d, dict) or not d.get("model"):
        return None
    t = d.get("time")
    try:
        t = float(t)
    except Exception:
        t = time.time()
    if "temperature_C" not in d and isinstance(d.get("temperature_F"), (int, float)):
        d["temperature_C"] = round((d["temperature_F"] - 32) / 1.8, 1)
    if "wind_avg_km_h" not in d and isinstance(d.get("wind_avg_m_s"), (int, float)):
        d["wind_avg_km_h"] = round(d["wind_avg_m_s"] * 3.6, 1)
    if "wind_max_km_h" not in d and isinstance(d.get("wind_max_m_s"), (int, float)):
        d["wind_max_km_h"] = round(d["wind_max_m_s"] * 3.6, 1)
    rec = {k: d[k] for k in KEEP433 if k in d and isinstance(d[k], (int, float, str))}
    rec["t"] = int(t)
    key = "%s|%s|%s" % (d.get("model"), d.get("id", ""), d.get("channel", ""))
    return key, rec, d


class State433:
    def __init__(self, base):
        self.base = base
        self.f = p("funk433_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "sensors": {}, "n": 0}
        self.d.setdefault("sensors", {})
        self.dirty = False
        self.last_saved = 0
        self.recent = {}

    def add(self, line, now=None):
        r = parse_433(line)
        if not r:
            return None
        key, rec, raw = r
        now = now or time.time()
        sig = json.dumps({k: v for k, v in raw.items() if k not in ("time", "rssi", "snr", "noise", "freq", "mic", "mod")}, sort_keys=True)
        if self.recent.get(key) == sig and now - self.recent.get(key + "#t", 0) < 3:
            return None  # Wiederholung desselben Telegramms (Sensoren senden 2-6x)
        self.recent[key], self.recent[key + "#t"] = sig, now
        s = self.d["sensors"].get(key) or {"first": rec["t"], "n": 0}
        s.update(rec)
        s["n"] = s.get("n", 0) + 1
        s["key"] = key
        self.d["sensors"][key] = s
        self.d["n"] = self.d.get("n", 0) + 1
        self.d["last_t"] = rec["t"]
        self.dirty = True
        return raw

    def prune(self, keep_days):
        cut = time.time() - keep_days * 86400
        for k in [k for k, v in self.d["sensors"].items() if (v.get("t") or 0) < cut]:
            del self.d["sensors"][k]
        if len(self.d["sensors"]) > 300:
            for k, _ in sorted(self.d["sensors"].items(), key=lambda kv: kv[1].get("t") or 0)[:len(self.d["sensors"]) - 300]:
                del self.d["sensors"][k]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


# ---------------------------------------------------------------- APRS
RE_DW = re.compile(r"^\[[0-9A-Za-z.]{1,8}\]\s*([A-Za-z0-9-]{1,9})>([^:\s]+):(.*)$")
RE_TNC2 = re.compile(r"^([A-Za-z0-9-]{1,9})>([^:\s]+):(.*)$")
RE_UNC = re.compile(r"^(\d{2})([0-9 ]{2}\.[0-9 ]{2})([NS])(.)(\d{3})([0-9 ]{2}\.[0-9 ]{2})([EW])(.)")
RE_WX = re.compile(r"([cstgrpPhbL])(-?\d{1,5}|\.{2,5}|\s{2,5})")


def _num(s):
    try:
        return float(s)
    except Exception:
        return None


def _unc(m):
    la = int(m.group(1)) + float(m.group(2).replace(" ", "0")) / 60.0
    lo = int(m.group(5)) + float(m.group(6).replace(" ", "0")) / 60.0
    if m.group(3) == "S":
        la = -la
    if m.group(7) == "W":
        lo = -lo
    return la, lo, m.group(4) + m.group(8)


def _b91(s):
    v = 0
    for ch in s:
        v = v * 91 + (ord(ch) - 33)
    return v


def _compressed(s):
    if len(s) < 13:
        return None
    t = s[0]
    if not (t in "/\\" or "A" <= t <= "Z" or "a" <= t <= "j"):
        return None
    body = s[1:9]
    if any(not (33 <= ord(c) <= 124) for c in body):
        return None
    la = 90.0 - _b91(body[:4]) / 380926.0
    lo = -180.0 + _b91(body[4:8]) / 190463.0
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return la, lo, t + s[9], s[13:]


def _mice(dest, info):
    d = dest.split("-")[0]
    if len(d) != 6 or len(info) < 9:
        return None
    dig = ""
    for c in d:
        if "0" <= c <= "9":
            dig += c
        elif "A" <= c <= "J":
            dig += chr(ord(c) - 17)
        elif "P" <= c <= "Y":
            dig += chr(ord(c) - 32)
        elif c in "KLZ":
            dig += "0"
        else:
            return None
    la = int(dig[0:2]) + (int(dig[2:4]) + int(dig[4:6]) / 100.0) / 60.0
    if not ("P" <= d[3] <= "Z"):
        la = -la
    off = 100 if "P" <= d[4] <= "Z" else 0
    west = "P" <= d[5] <= "Z"
    deg = ord(info[1]) - 28 + off
    if 180 <= deg <= 189:
        deg -= 80
    elif 190 <= deg <= 199:
        deg -= 190
    mi = ord(info[2]) - 28
    if mi >= 60:
        mi -= 60
    hu = ord(info[3]) - 28
    lo = deg + (mi + hu / 100.0) / 60.0
    if west:
        lo = -lo
    sp = (ord(info[4]) - 28) * 10 + (ord(info[5]) - 28) // 10
    dc = (ord(info[5]) - 28) % 10 * 100 + (ord(info[6]) - 28)
    if sp >= 800:
        sp -= 800
    if dc >= 400:
        dc -= 400
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return la, lo, info[8] + info[7], round(sp * 1.852), dc, info[9:]


def _wx(s):
    w = {}
    m = re.match(r"^(\d{3}|\.{3}|\s{3})/(\d{3}|\.{3}|\s{3})", s)
    if m:
        if _num(m.group(1)) is not None:
            w["wind_dir"] = int(m.group(1))
        if _num(m.group(2)) is not None:
            w["wind_kmh"] = round(int(m.group(2)) * 1.609, 1)
        s = s[7:]
    for k, v in RE_WX.findall(s[:60]):
        x = _num(v)
        if x is None:
            continue
        if k == "c" and "wind_dir" not in w:
            w["wind_dir"] = int(x)
        elif k == "s" and "wind_kmh" not in w:
            w["wind_kmh"] = round(x * 1.609, 1)
        elif k == "g":
            w["gust_kmh"] = round(x * 1.609, 1)
        elif k == "t":
            w["temp_c"] = round((x - 32) / 1.8, 1)
        elif k == "r":
            w["rain_1h_mm"] = round(x * 0.254, 1)
        elif k == "p":
            w["rain_24h_mm"] = round(x * 0.254, 1)
        elif k == "P":
            w["rain_mid_mm"] = round(x * 0.254, 1)
        elif k == "h":
            w["hum"] = 100 if int(x) == 0 else int(x)
        elif k == "b":
            w["hpa"] = round(x / 10.0, 1)
    return w if ("temp_c" in w or "hpa" in w or "hum" in w) else None


def parse_aprs(line, depth=0):
    """TNC2-Zeile (direwolf) -> dict oder None. Nur Lesen/Dekodieren."""
    line = line.rstrip("\r\n")
    m = RE_DW.match(line) if line.startswith("[") else RE_TNC2.match(line)
    if not m:
        return None
    src, path, info = m.group(1).upper(), m.group(2), m.group(3)
    parts = path.split(",")
    dest = parts[0]
    via = [x for x in parts[1:] if not x.startswith(("q", "TCPIP"))]
    r = {"src": src, "dest": dest, "path": ",".join(via), "direct": not any("*" in x for x in via), "raw": line[:300]}
    if not info:
        return None
    dti = info[0]
    try:
        if dti == "}" and depth < 2:
            inner = parse_aprs(info[1:], depth + 1)
            if inner:
                inner["third"] = src
                return inner
            return None
        if dti in "!=/@":
            s = info[1:]
            if dti in "/@":
                s = s[7:]
            mm = RE_UNC.match(s)
            if mm:
                la, lo, sym = _unc(mm)
                rest = s[19:]
            else:
                c = _compressed(s)
                if not c:
                    r["type"] = "other"
                    return r
                la, lo, sym, rest = c
            r.update({"type": "pos", "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "comment": rest.strip()[:120]})
            if sym[1:] == "_":
                w = _wx(rest)
                if w:
                    r["type"], r["wx"] = "wx", w
                    r["comment"] = ""
            else:
                cs = re.match(r"^(\d{3})/(\d{3})", rest)
                if cs:
                    r["course"], r["speed_kmh"] = int(cs.group(1)), round(int(cs.group(2)) * 1.852)
            alt = re.search(r"/A=(-?\d{6})", rest)
            if alt:
                r["alt_m"] = round(int(alt.group(1)) * 0.3048)
            return r
        if dti in "`'\x1c\x1d":
            mc = _mice(dest, info)
            if mc:
                la, lo, sym, sp, dc, rest = mc
                r.update({"type": "pos", "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "speed_kmh": sp, "course": dc,
                          "comment": re.sub(r"[\x00-\x1f]", "", rest).strip()[:120], "mice": True})
                return r
        if dti == "_":
            w = _wx(info[9:])
            if w:
                r.update({"type": "wx", "wx": w})
                return r
        if dti == ":" and len(info) >= 11 and info[10] == ":":
            to = info[1:10].strip().upper()
            txt = info[11:]
            mid = None
            if "{" in txt:
                txt, mid = txt.rsplit("{", 1)
            if re.match(r"^(ack|rej)[A-Za-z0-9]{1,5}$", txt):
                r.update({"type": "ack", "to": to})
                return r
            kind = "bulletin" if to.startswith(("BLN", "NWS")) else ("telemetry" if txt.startswith(("PARM.", "UNIT.", "EQNS.", "BITS.")) else "msg")
            r.update({"type": kind, "to": to, "text": txt[:200], "msgid": (mid or "")[:5] or None})
            return r
        if dti == ";" and len(info) > 18:
            name, live = info[1:10].strip(), info[10] == "*"
            s = info[18:]
            mm = RE_UNC.match(s)
            if mm:
                la, lo, sym = _unc(mm)
                rest = s[19:]
            else:
                c = _compressed(s)
                if not c:
                    return None
                la, lo, sym, rest = c
            r.update({"type": "obj", "name": name, "live": live, "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "comment": rest.strip()[:120]})
            return r
        if dti == ">":
            r.update({"type": "status", "text": info[1:120]})
            return r
        if dti == "T":
            r["type"] = "telemetry"
            return r
    except Exception:
        return None
    r["type"] = "other"
    return r


class StateAPRS:
    def __init__(self, base, home):
        self.base = base
        self.home = home
        self.f = p("aprs_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "stations": {}, "msgs": [], "n": 0}
        self.d.setdefault("stations", {})
        self.d.setdefault("msgs", [])
        self.dirty = False
        self.last_saved = 0

    def add(self, line, now=None):
        r = parse_aprs(line)
        if not r or r.get("type") in ("ack",):
            return None
        now = int(now or time.time())
        r["t"] = now
        key = r.get("name") if r.get("type") == "obj" else r["src"]
        s = self.d["stations"].get(key) or {"call": key, "first": now, "n": 0}
        s["n"] = s.get("n", 0) + 1
        s["t"] = now
        s["path"] = r.get("path")
        s["direct"] = r.get("direct")
        if r.get("type") == "obj":
            s["obj"] = True
            s["by"] = r["src"]
        if "lat" in r:
            s.update({"lat": r["lat"], "lon": r["lon"], "sym": r.get("sym"), "pos_t": now})
            s["dist_km"] = round(dist_km(self.home[0], self.home[1], r["lat"], r["lon"]), 1)
            s["brg"] = round(bearing(self.home[0], self.home[1], r["lat"], r["lon"]))
            for k in ("speed_kmh", "course", "alt_m"):
                if k in r:
                    s[k] = r[k]
                else:
                    s.pop(k, None)
        if r.get("comment"):
            s["comment"] = r["comment"]
        if r.get("type") == "status":
            s["status"] = r.get("text")
        if r.get("wx"):
            s["wx"] = r["wx"]
            s["wx_t"] = now
        if r.get("type") in ("msg", "bulletin") and not any(
                x.get("from") == r["src"] and x.get("to") == r.get("to") and x.get("text") == r.get("text") and now - (x.get("t") or 0) < 1800
                for x in self.d["msgs"][-30:]):
            self.d["msgs"].append({"t": now, "from": r["src"], "to": r.get("to"), "text": r.get("text"), "kind": r["type"]})
            self.d["msgs"] = self.d["msgs"][-150:]
        s["last_type"] = r.get("type")
        self.d["stations"][key] = s
        self.d["n"] = self.d.get("n", 0) + 1
        self.d["last_t"] = now
        self.dirty = True
        return r

    def prune(self, keep_days):
        cut = time.time() - keep_days * 86400
        for k in [k for k, v in self.d["stations"].items() if (v.get("t") or 0) < cut]:
            del self.d["stations"][k]
        if len(self.d["stations"]) > 600:
            for k, _ in sorted(self.d["stations"].items(), key=lambda kv: kv[1].get("t") or 0)[:len(self.d["stations"]) - 600]:
                del self.d["stations"][k]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"], self.d["home"] = V, int(time.time()), list(self.home)
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


DIREWOLF_CONF = """# prepper-sdr: nur Empfang (kein PTT, keine Audioausgabe, kein IGate, keine Baken)
ADEVICE null null
ACHANNELS 1
CHANNEL 0
MYCALL N0CALL
MODEM 1200
AGWPORT 0
KISSPORT 0
"""


# ---------------------------------------------------------------- Rundfunk (UKW-RDS / DAB+) - nur Warn-/Verkehrskennungen + Texte
FM_DEFAULT = [{"name": "BR24", "f": "102.0M"}, {"name": "Bayern 3", "f": "97.9M"}, {"name": "Bayern 1", "f": "88.9M"}]
DAB_DEFAULT = ["11D"]
WARN_WORDS = re.compile(r"warn|unwetter|gefahr|katastroph|evaku|sirene|alarm|hochwasser|stromausfall|bevoelkerung|bevölkerung|amtliche", re.I)


class StateBC:
    """broadcast_state.json: je UKW-Sender PS/RT/TA/TP, je DAB-Kanal Ensemble/DLS/Ansagen, Warnliste."""

    def __init__(self, base):
        self.f = p("broadcast_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "fm": {}, "dab": {}, "warn": []}
        for k, v in (("fm", {}), ("dab", {}), ("warn", [])):
            self.d.setdefault(k, v)
        self.dirty = False
        self.last_saved = 0
        self.cur = None

    def warn(self, src, kind, text, now):
        w = self.d["warn"]
        for x in w[-20:]:
            same = x.get("text") == text or (kind == "TA" and now - x.get("last", 0) < 1800)
            if x.get("src") == src and x.get("kind") == kind and same and now - x.get("t", 0) < 6 * 3600:
                x["last"] = int(now)
                return
        w.append({"t": int(now), "last": int(now), "src": src, "kind": kind, "text": (text or "")[:160]})
        cut = now - 48 * 3600
        self.d["warn"] = [x for x in w if x.get("last", x.get("t", 0)) >= cut][-60:]

    def on_rds(self, name, freq, line, now=None):
        line = line.strip()
        if not line.startswith("{"):
            return None
        try:
            g = json.loads(line)
        except Exception:
            return None
        now = now or time.time()
        s = self.d["fm"].get(name) or {"name": name, "f": freq}
        s.update({"f": freq, "t": int(now)})
        s["groups"] = s.get("groups", 0) + 1
        for k_in, k_out in (("pi", "pi"), ("ps", "ps"), ("radiotext", "rt"), ("prog_type", "pty"), ("tp", "tp"), ("ta", "ta")):
            if k_in in g:
                s[k_out] = g[k_in] if not isinstance(g[k_in], str) else g[k_in].strip()[:80]
        if g.get("ta") is True and s.get("tp"):
            s["ta_t"] = int(now)
            self.warn(name, "TA", "Durchsage aktiv (TA)", now)
        if isinstance(g.get("radiotext"), str) and WARN_WORDS.search(g["radiotext"]):
            self.warn(name, "RT", g["radiotext"].strip(), now)
        if g.get("group") in ("9A",) or "ews" in g:
            self.warn(name, "EWS", "RDS-Notfallgruppe empfangen", now)
        self.d["fm"][name] = s
        self.dirty = True
        return s

    def on_dab(self, ch, mux, now=None):
        now = now or time.time()
        if not isinstance(mux, dict):
            return None
        ens = mux.get("ensemble") or {}
        lab = ens.get("label") if isinstance(ens.get("label"), str) else (ens.get("label") or {}).get("label")
        svcs, alarm = [], []

        def walk(o, path):
            if isinstance(o, dict):
                for k, v in o.items():
                    kl = str(k).lower()
                    if ("announc" in kl or "alarm" in kl or kl in ("asu", "asw")) and v not in (None, False, 0, "", [], {}):
                        alarm.append("%s%s=%s" % (path, k, json.dumps(v, ensure_ascii=False)[:80]))
                    walk(v, path + str(k) + ".")
            elif isinstance(o, list):
                for x in o[:80]:
                    walk(x, path)
        walk(mux, "")
        for sv in (mux.get("services") or [])[:40]:
            if not isinstance(sv, dict):
                continue
            l = sv.get("label")
            l = l if isinstance(l, str) else (l or {}).get("label")
            dls = sv.get("dls")
            dls = dls if isinstance(dls, str) else (dls or {}).get("label")
            svcs.append({"label": (l or "?").strip()[:30], "dls": (dls or "").strip()[:160]})
            if dls and WARN_WORDS.search(dls):
                self.warn("DAB %s %s" % (ch, (l or "").strip()), "DLS", dls.strip(), now)
        for a in alarm[:3]:
            self.warn("DAB %s" % ch, "Ansage", a, now)
        self.d["dab"][ch] = {"ch": ch, "t": int(now), "ensemble": (lab or "").strip()[:40], "services": svcs, "alarm": alarm[:5], "n": len(svcs)}
        self.dirty = True
        return self.d["dab"][ch]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


# ---------------------------------------------------------------- Wettersatelliten (Meteor-M LRPT) - Bahnvorhersage
SATS_DEFAULT = [{"name": "METEOR-M2 3", "norad": 57166, "f": "137.9e6"}, {"name": "METEOR-M2 4", "norad": 59051, "f": "137.9e6"}]


def _gmst(jd_ut1):
    t = (jd_ut1 - 2451545.0) / 36525.0
    g = 67310.54841 + (876600.0 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t ** 3
    return math.radians((g % 86400.0) / 240.0)


def _obs_ecef(lat, lon, h_km=0.35):
    a, f = 6378.137, 1 / 298.257223563
    e2 = f * (2 - f)
    la, lo = math.radians(lat), math.radians(lon)
    n = a / math.sqrt(1 - e2 * math.sin(la) ** 2)
    return ((n + h_km) * math.cos(la) * math.cos(lo), (n + h_km) * math.cos(la) * math.sin(lo), (n * (1 - e2) + h_km) * math.sin(la))


def look(sat, t, lat, lon):
    """-> (Elevation, Azimut) in Grad zum Zeitpunkt t (Unix) oder None. sgp4 TEME -> ECEF (GMST-Drehung)."""
    jd = t / 86400.0 + 2440587.5
    jd0 = math.floor(jd - 0.5) + 0.5
    e, r, _v = sat.sgp4(jd0, jd - jd0)
    if e != 0:
        return None
    g = _gmst(jd)
    x = r[0] * math.cos(g) + r[1] * math.sin(g)
    y = -r[0] * math.sin(g) + r[1] * math.cos(g)
    z = r[2]
    ox, oy, oz = _obs_ecef(lat, lon)
    dx, dy, dz = x - ox, y - oy, z - oz
    la, lo = math.radians(lat), math.radians(lon)
    east = -math.sin(lo) * dx + math.cos(lo) * dy
    north = -math.sin(la) * math.cos(lo) * dx - math.sin(la) * math.sin(lo) * dy + math.cos(la) * dz
    up = math.cos(la) * math.cos(lo) * dx + math.cos(la) * math.sin(lo) * dy + math.sin(la) * dz
    rng = math.sqrt(east ** 2 + north ** 2 + up ** 2)
    return math.degrees(math.asin(up / rng)), (math.degrees(math.atan2(east, north)) + 360) % 360


def predict(tles, lat, lon, start, hours=36, min_el=20.0, horizon=8.0):
    """Ueberfluege mit Max-Elevation >= min_el. tles: [{name,norad,f,l1,l2}]."""
    try:
        from sgp4.api import Satrec
    except Exception:
        lib = os.path.join(BASE, "sdr_lib")  # Ersatz ohne Debian-Paket: reines Python-sgp4 (vom Patch, sha256-geprueft)
        if os.path.isdir(os.path.join(lib, "sgp4")) and lib not in sys.path:
            sys.path.append(lib)
        try:
            from sgp4.api import Satrec
        except Exception:
            return None
    out = []
    for s in tles:
        try:
            sat = Satrec.twoline2rv(s["l1"], s["l2"])
        except Exception:
            continue
        t, end, step = start, start + hours * 3600, 30
        inpass, aos, best, best_t, aos_az = False, None, -90, None, None
        while t <= end:
            la = look(sat, t, lat, lon)
            el = la[0] if la else -90
            if el >= horizon and not inpass:
                inpass, aos, best, best_t, aos_az = True, t, el, t, la[1]
            elif inpass and el >= horizon:
                if el > best:
                    best, best_t = el, t
            elif inpass:
                if best >= min_el:
                    out.append({"sat": s["name"], "norad": s["norad"], "f": s["f"], "aos": int(aos), "los": int(t), "max_el": round(best, 1),
                                "max_t": int(best_t), "dur_s": int(t - aos), "dir": "N→S" if aos_az is not None and (aos_az < 90 or aos_az > 270) else "S→N"})
                inpass = False
            t += step
    out.sort(key=lambda x: x["aos"])
    # Ueberschneidungen: hoeheren Ueberflug behalten
    res = []
    for x in out:
        if res and x["aos"] < res[-1]["los"]:
            if x["max_el"] > res[-1]["max_el"]:
                res[-1] = x
            continue
        res.append(x)
    return res


# ---------------------------------------------------------------- Planer
class ActMeter:
    """Aktivitaet eines Kanals aus rohen IQ-Daten (rtl_sdr, Mitte = Kanalfrequenz): Leistung im Kanal (+-6 kHz,
    ohne DC-Spitze) gegen Rauschboden (20-%-Quantil ausserhalb). Nichts wird demoduliert oder gespeichert.
    Ergebnis je Minute: Belegung %, Spitze dBFS, Anzahl Aussendungen, Rauschboden dBFS."""
    FS = 240000
    N = 1024

    def __init__(self, on_db=6.0, off_db=3.0):
        import numpy as np
        self.np = np
        self.win = np.hanning(self.N).astype(np.float32)
        self.wpow = float((self.win ** 2).sum())
        f = np.fft.fftfreq(self.N, 1.0 / self.FS)
        af = np.abs(f)
        self.ch = (af <= 6000) & (af >= 600)
        self.ref = (af >= 20000) & (af <= 100000)
        self.on_db, self.off_db = on_db, off_db
        self.rest = b""
        self.on = False
        self.on_blocks = 0
        self.m0 = None
        self._reset(None)

    def _reset(self, t):
        self.m0 = t
        self.nb = 0
        self.nb_on = 0
        self.peak = None
        self.tx = 0
        self.noise = []

    def _record(self):
        if not self.nb:
            return None
        nz = sorted(self.noise)
        return {"t": int(self.m0), "s": round(self.nb * self.N * 16 / self.FS), "occ_pct": round(100.0 * self.nb_on / self.nb, 1),
                "peak_dbfs": round(self.peak, 1) if self.peak is not None else None, "tx": self.tx,
                "noise_dbfs": round(nz[len(nz) // 2], 1) if nz else None}

    def feed(self, raw, now=None):
        """raw: u8 IQ. -> Liste fertiger Minuten-Datensaetze."""
        np = self.np
        now = now or time.time()
        if self.m0 is None:
            self._reset(now - now % 60)
        out = []
        data = self.rest + raw
        blk = self.N * 2 * 16  # 16 FFTs je Messblock (~68 ms)
        nfull = len(data) // blk
        self.rest = data[nfull * blk:]
        for i in range(nfull):
            if now - self.m0 >= 60:
                r = self._record()
                if r:
                    out.append(r)
                self._reset(now - now % 60)
            a = np.frombuffer(data[i * blk:(i + 1) * blk], dtype=np.uint8).astype(np.float32)
            a = (a - 127.4) / 127.5
            z = (a[0::2] + 1j * a[1::2]).reshape(16, self.N)
            psd = (np.abs(np.fft.fft(z * self.win, axis=1)) ** 2).mean(axis=0) / (self.N * self.wpow)
            pch = float(psd[self.ch].sum())
            nref = float(np.quantile(psd[self.ref], 0.2)) * int(self.ch.sum())
            snr = 10 * math.log10(max(pch, 1e-20) / max(nref, 1e-20))
            dbfs = 10 * math.log10(max(pch, 1e-20))
            self.noise.append(10 * math.log10(max(nref, 1e-20)))
            if len(self.noise) > 2000:
                self.noise = self.noise[::2]
            self.nb += 1
            if self.on:
                if snr < self.off_db:
                    self.on = False
            elif snr > self.on_db:
                self.on = True
                self.on_blocks = 0
            if self.peak is None or dbfs > self.peak:
                self.peak = dbfs
            if self.on:
                self.nb_on += 1
                self.on_blocks += 1
                if self.on_blocks == 4:  # erst ab ~0,3 s als Aussendung zaehlen
                    self.tx += 1
        return out

    def finish(self):
        r = self._record()
        self._reset(None)
        return [r] if r and r["s"] >= 20 else []


class ActState:
    """Minutenwerte (nur Zahlen) je Aktivitaets-Preset, 3 Tage, sparsam gespeichert (activity_state.json)."""

    def __init__(self, base):
        self.f = p("activity_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "series": {}}
        self.d.setdefault("series", {})
        self.dirty = False
        self.last_saved = 0

    def add(self, pid, rec):
        s = self.d["series"].setdefault(pid, [])
        s.append(rec)
        cut = time.time() - 3 * 86400
        self.d["series"][pid] = [x for x in s if x.get("t", 0) >= cut][-4320:]
        self.dirty = True

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 300):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


class LineLog:
    """Zeilen-Logger (prepper_linelog-Art) im Planer: Decoder-Ausgabe des gewaehlten Presets mit Zeitstempel,
    optional nur Zeilen mit festem Stichwort (sdr_config.json linelog_keyword), gepuffert und atomar
    (tmp + fsync + os.replace) nach archive/linelog/<preset>_<JJJJMMTT>[_n].jsonl. Kein Port, kein Netz."""

    def __init__(self, base, cfg):
        self.dir = os.path.join(base, "archive", "linelog")
        kw = cfg.get("linelog_keyword")
        self.kw = str(kw).lower() if isinstance(kw, str) and kw.strip() else None
        self.on = bool(cfg.get("linelog_enable", True))
        self.flush_s = max(30.0, float(cfg.get("linelog_flush_s") or 300))
        self.part = max(32, int(cfg.get("linelog_part_kb") or 512)) * 1024
        self.keep = max(1, int(cfg.get("linelog_keep_days") or 14))
        self.buf = []
        self.lock = threading.Lock()
        self.last = time.time()
        self.n = 0
        self.dropped = 0

    def add(self, pid, text, now=None, numeric=False):
        if not self.on or pid not in PRESET_IDS:
            return False
        t = (text or "").strip()
        if not t or (self.kw and not numeric and self.kw not in t.lower()):
            return False
        with self.lock:
            if len(self.buf) >= 5000:
                self.buf.pop(0)
                self.dropped += 1
            self.buf.append({"t": round(now or time.time(), 1), "preset": pid, "line": t[:600]})
            self.n += 1
        return True

    def _target(self, pid, day, size_add):
        i = 1
        while True:
            name = "%s_%s%s.jsonl" % (pid, day, "" if i == 1 else "_%d" % i)
            fn = os.path.join(self.dir, name)
            if not os.path.exists(fn) or os.path.getsize(fn) + size_add <= self.part or i >= 50:
                return fn
            i += 1

    def flush(self, force=False):
        if not force and time.time() - self.last < self.flush_s:
            return 0
        self.last = time.time()
        with self.lock:
            buf, self.buf = self.buf, []
        if not buf:
            return 0
        os.makedirs(self.dir, exist_ok=True)
        groups = {}
        for r in buf:
            groups.setdefault((r["preset"], time.strftime("%Y%m%d", time.localtime(r["t"]))), []).append(r)
        for (pid, day), rows in groups.items():
            data = "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in rows).encode("utf-8")
            fn = self._target(pid, day, len(data))
            old = b""
            if os.path.exists(fn):
                with open(fn, "rb") as f:
                    old = f.read()
            tmp = fn + ".tmp"
            with open(tmp, "wb") as f:
                f.write(old + data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, fn)
        self.prune()
        return len(buf)

    def prune(self):
        cut = time.time() - self.keep * 86400
        try:
            for name in os.listdir(self.dir):
                fn = os.path.join(self.dir, name)
                if name.endswith((".jsonl", ".tmp")) and os.path.getmtime(fn) < cut:
                    os.remove(fn)
        except Exception:
            pass


class Planner:
    def __init__(self, base):
        self.base = base
        self.cfg = config(base)
        self.s433 = State433(base)
        self.saprs = StateAPRS(base, tuple(self.cfg["home"]))
        self.procs = []
        self.active = "idle"
        self.since = time.time()
        self.slice_start = time.time()
        self.auto_idx = 0
        self.fails = 0
        self.retry_at = 0
        self.err = None
        self.err_t = None
        self.stderr = []
        self.stop = False
        self.lock = threading.Lock()
        self.last_status = 0
        self.last_prune = 0
        self.stick = []
        self.counts = {"433": 0, "aprs": 0, "rds": 0, "dab": 0, "meteor": 0, "linelog": 0}
        self.llog = LineLog(base, self.cfg)
        self.sact = ActState(base)
        self.last_dabpoll = 0
        self.pmeteor = None
        self._lastdls = {}
        self.sbc = StateBC(base)
        self.special = None
        self.last_bc = time.time() - float(self.cfg.get("bc_interval_s") or 1800) + 120
        self.passes = (load_json(p("sdr_passes.json", base), {}) or {}).get("passes") or []
        self.last_predict = 0
        self.last_tle_try = 0
        self.tools = {}
        self.started = time.time()
        self.lastsig = None

    def log(self, *a):
        print("prepper-sdr:", *a, flush=True)

    def _dev(self, args, flag="-d"):
        if self.cfg.get("device") not in (None, ""):
            args += [flag, str(self.cfg["device"])]
        return args

    def tool(self, name):
        if name not in self.tools:
            import shutil
            exe = {"redsea": "redsea", "welle": "welle-cli", "satdump": "satdump"}[name]
            cand = self.cfg.get(name) or shutil.which(exe) or ("/usr/local/bin/" + exe if os.path.exists("/usr/local/bin/" + exe) else None)
            ok = cand and os.path.basename(str(cand)) == exe and os.path.isfile(cand) and os.access(cand, os.X_OK)
            self.tools[name] = cand if ok else None
        return self.tools[name]

    def fm_list(self):
        v = self.cfg.get("fm")
        return v if isinstance(v, list) and v else FM_DEFAULT

    def dab_list(self):
        v = self.cfg.get("dab")
        return v if isinstance(v, list) and v else DAB_DEFAULT

    def sat_list(self):
        v = self.cfg.get("sats")
        return v if isinstance(v, list) and v else SATS_DEFAULT

    def cmd(self, what):
        c = self.cfg
        if what.startswith("p:"):
            ps = preset(what[2:])
            if ps is None:
                raise RuntimeError("Preset unbekannt: %s" % what)
            k = ps["kind"]
            check_tune(k, ps.get("f"), ps.get("ch"))
            if k in ("ism433", "srd868"):
                a = ["rtl_433", "-f", ps["f"], "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"]
                if k == "srd868":
                    a += ["-s", "1024k"]
                if c.get("ppm"):
                    a += ["-p", str(int(c["ppm"]))]
                if c.get("gain_433") not in (None, ""):
                    a += ["-g", str(c["gain_433"])]
                return [self._dev(a)]
            if k == "aprs":
                return self.cmd("aprs")
            if k == "fm":
                return self._cmd_rds(ps["f"])
            if k == "dab":
                return self._cmd_dab(ps["ch"])
            if k in ACT_KINDS:
                return self._cmd_act(k, ps["f"])
            if k == "wxsat":
                m = get_mode(self.base)
                secs = max(60, int((m.get("until") or time.time() + 1800) - time.time()))
                return self._cmd_meteor(ps["f"], secs, c["meteor_tmp"])
            raise RuntimeError("Preset-Art unbekannt")
        if what.startswith("rds:"):
            st = self.fm_list()[int(what[4:])]
            return self._cmd_rds(st["f"])
        if what.startswith("dab:"):
            return self._cmd_dab(str(self.dab_list()[int(what[4:])]))
        if what == "meteor":
            sp = self.special or {}
            ps = sp.get("pass") or {}
            secs = max(60, int(ps.get("los", time.time() + 600) - time.time()))
            return self._cmd_meteor(ps.get("f") or "137.9e6", secs, sp.get("tmp") or c["meteor_tmp"])
        if what == "433":
            check_tune("ism433", c["f433"])
        if what == "aprs":
            check_tune("aprs", c["faprs"])
        return self._cmd_base(what)

    def _cmd_rds(self, f):
        c = self.cfg
        check_tune("fm", f)
        a = ["rtl_fm", "-M", "fm", "-l", "0", "-A", "std", "-s", "171k", "-F", "9", "-f", str(f)]
        if c.get("ppm"):
            a += ["-p", str(int(c["ppm"]))]
        if c.get("gain_fm") not in (None, ""):
            a += ["-g", str(c["gain_fm"])]
        return [self._dev(a) + ["-"], [self.tool("redsea"), "-r", "171k"]]

    def _cmd_dab(self, ch):
        c = self.cfg
        check_tune("dab", ch=ch)
        a = [self.tool("welle"), "-c", str(ch), "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_sdr"]
        if c.get("gain_dab") not in (None, ""):
            a += ["-g", str(c["gain_dab"])]
        return [a]

    def _cmd_act(self, kind, f):
        """Nur rohe IQ-Daten nach stdout (Planer misst Pegel, verwirft die Daten). Mitte = Kanalfrequenz."""
        c = self.cfg
        check_tune(kind, f)
        try:
            import numpy  # noqa: F401
        except Exception:
            raise RuntimeError("Aktivitaet: python3-numpy fehlt")
        a = ["rtl_sdr", "-f", str(f), "-s", str(ActMeter.FS)]
        if c.get("ppm"):
            a += ["-p", str(int(c["ppm"]))]
        if c.get("gain_act") not in (None, ""):
            a += ["-g", str(c["gain_act"])]
        return [self._dev(a) + ["-"]]

    def _act_reader(self, stream, pid):
        try:
            mt = ActMeter()
        except Exception as e:
            self.log("Aktivitaet:", e)
            return
        def put(recs):
            for r in recs:
                with self.lock:
                    self.sact.add(pid, r)
                self._ll(pid, json.dumps(dict(r, preset=pid), separators=(",", ":")), numeric=True)
        try:
            while True:
                raw = stream.read(122880)
                if not raw:
                    break
                put(mt.feed(raw))
        except Exception as e:
            self.log("Aktivitaet Messung:", e)
        put(mt.finish())

    def _cmd_meteor(self, f, secs, tmp):
        c = self.cfg
        check_tune("wxsat", f)
        return [[self.tool("satdump"), "live", "meteor_m2-x_lrpt", tmp, "--source", "rtlsdr",
                 "--samplerate", str(c["meteor_samplerate"]), "--frequency", str(f),
                 "--gain", str(c["meteor_gain"]), "--timeout", str(int(secs))]]

    def _cmd_base(self, what):
        c = self.cfg
        if what == "433":
            a = ["rtl_433", "-f", str(c["f433"]), "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"]
            if c.get("ppm"):
                a += ["-p", str(int(c["ppm"]))]
            if c.get("gain_433") not in (None, ""):
                a += ["-g", str(c["gain_433"])]
            return [self._dev(a)]
        if what == "aprs":
            conf = p("sdr_direwolf.conf", self.base)
            try:
                if open(conf).read() != DIREWOLF_CONF:
                    raise ValueError
            except Exception:
                with open(conf, "w") as f:
                    f.write(DIREWOLF_CONF)
            a = ["rtl_fm", "-f", str(c["faprs"]), "-s", "24000"]
            if c.get("ppm"):
                a += ["-p", str(int(c["ppm"]))]
            if c.get("gain_aprs") not in (None, ""):
                a += ["-g", str(c["gain_aprs"])]
            a = self._dev(a) + ["-"]
            return [a, ["direwolf", "-c", conf, "-r", "24000", "-D", "1", "-t", "0", "-q", "hd", "-"]]
        if what == "tcp":
            return [self._dev(["rtl_tcp", "-a", str(c["tcp_bind"]), "-p", str(int(c["tcp_port"]))])]
        return []

    def _reader(self, stream, fn):
        try:
            for raw in iter(stream.readline, b""):
                try:
                    fn(raw.decode("utf-8", "replace"))
                except Exception as e:
                    self.log("Zeile:", e)
        except Exception:
            pass

    def _err_reader(self, stream):
        try:
            for raw in iter(stream.readline, b""):
                s = raw.decode("utf-8", "replace").strip()
                if s:
                    with self.lock:
                        self.stderr = (self.stderr + [s[:160]])[-8:]
        except Exception:
            pass

    def on433(self, line):
        with self.lock:
            raw = self.s433.add(line)
            if raw is None:
                return
            self.counts["433"] += 1
        fn = p("rtl433.jsonl", self.base)
        rotate(fn, self.cfg["max_jsonl_mb"])
        with open(fn, "a", encoding="utf-8") as f:
            f.write(json.dumps(raw, ensure_ascii=False, separators=(",", ":")) + "\n")

    def onaprs(self, line):
        with self.lock:
            r = self.saprs.add(line)
            if r is None:
                return
            self.counts["aprs"] += 1
        fn = p("aprs.jsonl", self.base)
        rotate(fn, self.cfg["aprs_max_jsonl_mb"])
        r = {k: v for k, v in r.items() if k != "raw"} | {"raw": r.get("raw", "")[:200]}
        with open(fn, "a", encoding="utf-8") as f:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")

    def onrds(self, st, line):
        with self.lock:
            if self.sbc.on_rds(st["name"], st["f"], line):
                self.counts["rds"] += 1

    def start(self, what):
        cmds = self.cmd(what)
        if self._pkind(what) == "wxsat":
            os.makedirs(self.cfg["meteor_tmp"], exist_ok=True)
        if any(not a[0] for a in cmds):
            raise RuntimeError("Start %s: Programm fehlt" % what)
        self.stderr = []
        prev = None
        procs = []
        try:
            for i, a in enumerate(cmds):
                last = i == len(cmds) - 1
                pr = subprocess.Popen(a, stdin=(prev.stdout if prev else subprocess.DEVNULL), stdout=subprocess.PIPE if (not last or what in ("433", "aprs") or what.startswith("rds:") or self._pkind(what) in ("ism433", "srd868", "aprs", "fm") + ACT_KINDS) else subprocess.DEVNULL,
                                      stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
                if prev is not None:
                    prev.stdout.close()
                procs.append(pr)
                threading.Thread(target=self._err_reader, args=(pr.stderr,), daemon=True).start()
                prev = pr
        except Exception as e:
            self.procs = procs
            self.kill()
            raise RuntimeError("Start %s: %s" % (cmds[len(procs)][0] if len(procs) < len(cmds) else what, e))
        self.procs = procs
        pk = self._pkind(what)
        if pk:
            pid = what[2:]
            ps = preset(pid)
            if pk in ("ism433", "srd868"):
                fn = lambda ln, pid=pid: (self.on433(ln), self._ll(pid, ln))
            elif pk == "aprs":
                fn = lambda ln, pid=pid: (self.onaprs(ln), self._ll(pid, ln))
            elif pk == "fm":
                st = {"name": ps["name"], "f": ps["f"]}
                fn = lambda ln, pid=pid, st=st: (self.onrds(st, ln), self._ll(pid, ln))
            else:
                fn = None
            if pk in ACT_KINDS:
                threading.Thread(target=self._act_reader, args=(procs[-1].stdout, pid), daemon=True).start()
            if fn:
                threading.Thread(target=self._reader, args=(procs[-1].stdout, fn), daemon=True).start()
            if pk == "wxsat":
                self.pmeteor = {"pass": {"sat": "manuell " + ps["f"].replace("e6", " MHz"), "aos": time.time(), "f": ps["f"], "tag": "man" + pid[-4:]}, "tmp": self.cfg["meteor_tmp"], "pid": pid}
            self.last_dabpoll = time.time()
            self._ll(pid, "== Start %s (%s)" % (ps["label"], " | ".join(" ".join(a) for a in cmds)))
        elif what == "433":
            threading.Thread(target=self._reader, args=(procs[-1].stdout, self.on433), daemon=True).start()
        elif what == "aprs":
            threading.Thread(target=self._reader, args=(procs[-1].stdout, self.onaprs), daemon=True).start()
        elif what.startswith("rds:"):
            st = self.fm_list()[int(what[4:])]
            threading.Thread(target=self._reader, args=(procs[-1].stdout, lambda ln, st=st: self.onrds(st, ln)), daemon=True).start()
        self.active, self.since = what, time.time()
        self.log("Start", what, " | ".join(" ".join(a) for a in cmds))

    def _pkind(self, what):
        ps = preset(what[2:]) if isinstance(what, str) and what.startswith("p:") else None
        return ps["kind"] if ps else None

    def _ll(self, pid, line, numeric=False):
        if self.llog.add(pid, line, numeric=numeric):
            with self.lock:
                self.counts["linelog"] += 1

    def kill(self):
        for pr in self.procs:
            try:
                os.killpg(pr.pid, signal.SIGTERM)
            except Exception:
                pass
        end = time.time() + 4
        for pr in self.procs:
            try:
                pr.wait(timeout=max(0.1, end - time.time()))
            except Exception:
                try:
                    os.killpg(pr.pid, signal.SIGKILL)
                    pr.wait(timeout=2)
                except Exception:
                    pass
        had = bool(self.procs)
        self.procs = []
        if had:
            time.sleep(1.0)  # USB freigeben lassen

    def alive(self):
        return bool(self.procs) and all(pr.poll() is None for pr in self.procs)

    def want(self, mode, now):
        m = mode["mode"]
        if m == "off":
            return "idle"
        if m in ("433", "aprs", "tcp"):
            return m
        if m == "preset":
            if self.special:
                try:
                    self.sub_done(self.special, now)
                finally:
                    self.special = None
            return "p:" + mode["preset"]
        sp = self.special
        if sp:
            if now < sp["sub_end"]:
                return sp["queue"][sp["i"]]
            self.sub_done(sp, now)
            sp["i"] += 1
            if sp["i"] < len(sp["queue"]) and now < sp.get("hard_end", now + 1):
                sp["sub_end"] = now + sp["durs"][sp["i"]]
                return sp["queue"][sp["i"]]
            if sp["kind"] == "bc":
                self.last_bc = now
                self.sbc.last_saved = 0  # Block-Ergebnis gleich einmal speichern
            self.special = None
        ps = self.pass_now(now)
        if ps:
            tmp = self.cfg["meteor_tmp"]
            self._clean_tmp(tmp)
            os.makedirs(tmp, exist_ok=True)
            self.special = {"kind": "meteor", "queue": ["meteor"], "durs": [ps["los"] - now + 300], "i": 0, "sub_end": ps["los"] + 300,
                            "pass": ps, "tmp": tmp, "t0": now}
            self.log("Meteor-Ueberflug %s max %s Grad bis %s" % (ps["sat"], ps["max_el"], time.strftime("%H:%M", time.localtime(ps["los"]))))
            return "meteor"
        q = self.bc_queue()
        if q and now - self.last_bc >= float(self.cfg.get("bc_interval_s") or 1800):
            tot = sum(d for _, d in q)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + tot + 60:
                self.special = {"kind": "bc", "queue": [j for j, _ in q], "durs": [d for _, d in q], "i": 0, "sub_end": now + q[0][1],
                                "hard_end": now + tot + 30, "t0": now}
                return q[0][0]
            self.last_bc = now - float(self.cfg.get("bc_interval_s") or 1800) + 300
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")] or ["433"]
        if self.active not in order:
            self.auto_idx = self.auto_idx % len(order)
            return order[self.auto_idx]
        sl = float(self.cfg.get("slice_%s_s" % self.active) or 300)
        if len(order) > 1 and now - self.slice_start >= sl:
            self.auto_idx = (order.index(self.active) + 1) % len(order)
            return order[self.auto_idx]
        return self.active

    def bc_queue(self):
        if not self.cfg.get("bc_enable"):
            return []
        q = []
        if self.tool("redsea"):
            q += [("rds:%d" % i, float(self.cfg.get("fm_s") or 25)) for i in range(len(self.fm_list()))]
        if self.tool("welle"):
            q += [("dab:%d" % i, float(self.cfg.get("dab_s") or 60)) for i in range(len(self.dab_list()))]
        return q

    def sub_done(self, sp, now):
        job = sp["queue"][sp["i"]]
        if job.startswith("dab:") and self.procs and self.alive():
            ch = str(self.dab_list()[int(job[4:])])
            try:
                import prepper_sdr_net
                mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
                with self.lock:
                    if self.sbc.on_dab(ch, mux, now):
                        self.counts["dab"] += 1
            except Exception as e:
                self.log("DAB %s: kein Status (%s)" % (ch, e))
                with self.lock:
                    self.sbc.d["dab"].setdefault(ch, {"ch": ch})["err"] = str(e)[:100]
                    self.sbc.d["dab"][ch]["err_t"] = int(now)
                    self.sbc.dirty = True
        if job == "meteor":
            if self.procs:
                self.kill()
            self.collect_meteor(sp)

    def pass_now(self, now):
        if not self.cfg.get("meteor_enable") or not self.tool("satdump"):
            return None
        for ps in self.passes:
            if ps["aos"] - 20 <= now < ps["los"] - 60 and ps["max_el"] >= float(self.cfg.get("meteor_min_el") or 20) and not ps.get("done"):
                ps["done"] = True
                return ps
        return None

    def next_pass(self, now):
        for ps in self.passes:
            if ps["los"] > now and ps["max_el"] >= float(self.cfg.get("meteor_min_el") or 20):
                return ps
        return None

    def maintain(self, now):
        """TLE holen (wenn online, alle 12 h), Ueberfluege vorhersagen (stuendlich). Ohne Netz: Cache."""
        if not self.cfg.get("meteor_enable"):
            return
        fn = p("sdr_tle.json", self.base)
        cache = load_json(fn, {}) or {}
        age = now - (cache.get("t") or 0)
        if age > float(self.cfg.get("tle_refresh_h") or 12) * 3600 and now - self.last_tle_try > 1800:
            self.last_tle_try = now
            try:
                import prepper_sdr_net
                got = []
                for s in self.sat_list():
                    name, l1, l2 = prepper_sdr_net.fetch_tle(s["norad"])
                    got.append({"name": s["name"], "norad": int(s["norad"]), "f": s["f"], "l1": l1, "l2": l2})
                cache = {"t": int(now), "tles": got, "src": "celestrak"}
                write_json(fn, cache)
                self.last_predict = 0
                self.log("TLE aktualisiert:", ", ".join(x["name"] for x in got))
            except Exception as e:
                self.log("TLE nicht geholt (offline?), nutze Cache vom %s: %s" % (time.strftime("%d.%m. %H:%M", time.localtime(cache.get("t") or 0)) if cache.get("t") else "-", e))
        if cache.get("tles") and now - self.last_predict > 3600:
            done = {(x["sat"], x["aos"]) for x in self.passes if x.get("done")}
            ps = predict(cache["tles"], self.saprs.home[0], self.saprs.home[1], now - 900, 36, float(self.cfg.get("meteor_min_el") or 20))
            if ps is not None:
                for x in ps:
                    if (x["sat"], x["aos"]) in done:
                        x["done"] = True
                self.passes = ps
                write_json(p("sdr_passes.json", self.base), {"t": int(now), "tle_t": cache.get("t"), "passes": ps, "min_el": self.cfg.get("meteor_min_el")})
            self.last_predict = now

    def _clean_tmp(self, tmp):
        import shutil
        if tmp.startswith("/tmp/prepper-meteor") and os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)

    def collect_meteor(self, sp):
        """Bilder aus dem satdump-Ausgabeordner (tmpfs) als JPEG nach meteor/ uebernehmen, alte loeschen."""
        ps = sp.get("pass") or {}
        tmp = sp.get("tmp") or ""
        dst = p("meteor", self.base)
        os.makedirs(dst, exist_ok=True)
        pngs = []
        for root, _d, files in os.walk(tmp):
            for fn in files:
                if fn.lower().endswith((".png", ".jpg")):
                    pngs.append(os.path.join(root, fn))
        def score(x):
            n = os.path.basename(x).lower()
            return (0 if "221" in n else 1 if "rgb" in n or "natural" in n else 2 if "msu" in n else 3, -os.path.getsize(x))
        pick = sorted(pngs, key=score)[:3]
        stamp = time.strftime("%Y%m%d-%H%M", time.localtime(ps.get("aos") or time.time()))
        sat = re.sub(r"[^A-Za-z0-9]+", "", ps.get("tag") or (ps.get("sat") or "meteor").replace("METEOR-", ""))[-8:]
        saved = []
        for src in pick:
            base = re.sub(r"[^A-Za-z0-9_-]+", "_", os.path.splitext(os.path.basename(src))[0])[:40]
            out = os.path.join(dst, "%s_%s_%s.jpg" % (stamp, sat, base))
            try:
                from PIL import Image
                im = Image.open(src)
                im = im.convert("RGB")
                if im.width > 1600:
                    im = im.resize((1600, int(im.height * 1600 / im.width)))
                im.save(out + ".tmp", "JPEG", quality=85)
                os.replace(out + ".tmp", out)
            except Exception:
                out = out[:-4] + ".png"
                with open(src, "rb") as a, open(out + ".tmp", "wb") as b:
                    b.write(a.read())
                os.replace(out + ".tmp", out)
            saved.append(os.path.basename(out))
        self._clean_tmp(tmp)
        self._prune_meteor(dst)
        st = load_json(p("meteor_state.json", self.base), {}) or {}
        hist = st.get("passes") or []
        hist.append({"t": int(time.time()), "sat": ps.get("sat"), "aos": ps.get("aos"), "los": ps.get("los"), "max_el": ps.get("max_el"),
                     "images": saved, "note": None if saved else "keine Bilder (Signal zu schwach / Antenne?)",
                     "err": (self.stderr[-1] if self.stderr else None)})
        st["passes"] = hist[-60:]
        st["v"] = V
        write_json(p("meteor_state.json", self.base), st)
        with self.lock:
            self.counts["meteor"] += len(saved)
        self.log("Meteor: %d Bild(er) gespeichert" % len(saved))

    def _prune_meteor(self, dst):
        keep = int(self.cfg.get("meteor_keep") or 30)
        cap = float(self.cfg.get("meteor_cap_mb") or 300) * 1024 * 1024
        files = sorted((os.path.join(dst, f) for f in os.listdir(dst) if f.endswith((".jpg", ".png"))), key=os.path.getmtime, reverse=True)
        tot = 0
        for i, f in enumerate(files):
            tot += os.path.getsize(f)
            if i >= keep or tot > cap:
                os.remove(f)

    def status(self, mode, force=False):
        now = time.time()
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")]
        nxt = None
        if mode["mode"] == "auto" and self.active in order and len(order) > 1:
            nxt = int(self.slice_start + float(self.cfg.get("slice_%s_s" % self.active) or 300))
        with self.lock:
            st = {"v": V, "t": int(now), "pid": os.getpid(), "started": int(self.started), "mode": mode["mode"], "until": mode.get("until"),
                  "active": self.active, "since": int(self.since), "next_switch": nxt, "stick": self.stick,
                  "err": self.err, "err_t": self.err_t, "fails": self.fails, "retry_at": int(self.retry_at) if self.retry_at > now else None,
                  "stderr": self.stderr[-3:], "counts": dict(self.counts), "last_433_t": self.s433.d.get("last_t"),
                  "last_aprs_t": self.saprs.d.get("last_t"), "sensors": len(self.s433.d["sensors"]), "stations": len(self.saprs.d["stations"]),
                  "tcp": {"port": int(self.cfg["tcp_port"]), "bind": self.cfg["tcp_bind"]}, "auto": order,
                  "slices": {"433": self.cfg["slice_433_s"], "aprs": self.cfg["slice_aprs_s"]},
                  "freq": {"433": self.cfg["f433"], "aprs": self.cfg["faprs"]}, "home": list(self.saprs.home),
                  "special": ({"kind": self.special["kind"], "job": self.special["queue"][self.special["i"]], "until": int(self.special["sub_end"])} if self.special else None),
                  "next_bc": int(self.last_bc + float(self.cfg.get("bc_interval_s") or 1800)) if self.bc_queue() else None,
                  "next_pass": self.next_pass(now), "sgp4": predict([], 0, 0, now) is not None,
                  "preset": mode.get("preset"), "preset_label": (preset(mode.get("preset")) or {}).get("label"),
                  "linelog": {"n": self.llog.n, "kw": self.llog.kw, "on": self.llog.on, "dropped": self.llog.dropped}, "tools": {"redsea": bool(self.tool("redsea")), "welle": bool(self.tool("welle")), "satdump": bool(self.tool("satdump"))}}
        sig = (st["mode"], st["active"], st["err"], len(st["stick"]), st["until"], bool(self.special))
        if force or sig != self.lastsig or now - self.last_status >= 60:
            write_json(p("sdr_status.json", self.base), st)
            self.last_status, self.lastsig = now, sig
        return st

    def flush(self, force=False):
        try:
            self.llog.flush(force)
        except Exception as e:
            self.log("Zeilen-Log:", e)
        with self.lock:
            self.s433.save(force)
            self.saprs.save(force)
            self.sbc.save(force)
            self.sact.save(force)

    def step(self):
        now = time.time()
        mode = get_mode(self.base)
        self.stick = stick_info(self.cfg["usb_ids"])
        if not self.stick:
            if self.procs:
                self.kill()
            if self.active != "nostick":
                self.log("kein RTL-SDR-Stick gefunden - warte (pruefe alle 15 s)")
            self.active, self.err = "nostick", "kein Stick"
            self.fails = 0
            return 15, mode
        if self.active == "nostick":
            self.active, self.err, self.since = "idle", None, now
            self.log("Stick da:", self.stick[0].get("product"), self.stick[0].get("serial"))
        if self._pkind(self.active) == "dab" and self.procs and self.alive() and now - self.last_dabpoll >= 30:
            self.last_dabpoll = now
            ps = preset(self.active[2:])
            try:
                import prepper_sdr_net
                mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
                with self.lock:
                    r = self.sbc.on_dab(ps["ch"], mux, now)
                for sv in (r or {}).get("services") or []:
                    if sv.get("dls") and sv["dls"] != self._lastdls.get(sv["label"]):
                        self._lastdls[sv["label"]] = sv["dls"]
                        self._ll(ps["id"], "%s: %s" % (sv["label"], sv["dls"]))
                for a in (r or {}).get("alarm") or []:
                    self._ll(ps["id"], "Ansage: " + a)
            except Exception as e:
                self._ll(ps["id"], "== DAB-Status nicht lesbar: %s" % e)
        w = self.want(mode, now)
        if self.pmeteor and (w != self.active or not self.alive()):
            pid = (self.pmeteor.get("pid") or "")
            if self.procs and w != self.active:
                self.kill()
            if not self.alive():
                rc = [pr.poll() for pr in self.procs]
                self.kill()
                pm, self.pmeteor = self.pmeteor, None
                self.collect_meteor(pm)
                self._ll(pid, "== Ende Meteor-Aufnahme (rc %s)" % rc)
                if rc and all(x == 0 for x in rc):
                    self.active, self.since = "idle", now
                    return 2, mode
        if self.procs and not self.alive() and self.special and self.active in self.special["queue"]:
            sp = self.special
            rc = [pr.poll() for pr in self.procs]
            with self.lock:
                tail = self.stderr[-1] if self.stderr else ""
            if sp["kind"] == "bc":
                self.err, self.err_t = "%s beendet (rc %s): %s" % (self.active, rc, tail), int(now)
                self.log(self.err)
            self.kill()
            sp["sub_end"] = now  # naechster Teil / Ende
            self.active = "idle"
            return 1, mode
        if self.procs and not self.alive():
            rc = [pr.poll() for pr in self.procs]
            ran = now - self.since
            self.kill()
            self.fails = 1 if ran > 120 else self.fails + 1
            back = min(300, 10 * 2 ** (self.fails - 1))
            self.retry_at = now + back
            with self.lock:
                tail = self.stderr[-1] if self.stderr else ""
            self.err, self.err_t = "%s beendet (rc %s) nach %d s: %s" % (self.active, rc, ran, tail), int(now)
            self.log(self.err, "- neuer Versuch in %d s" % back)
            self.active = "fehler"
            return 2, mode
        if w == "idle":
            if self.procs:
                self.kill()
            self.active, self.since = "idle", now if self.active != "idle" else self.since
            return 2, mode
        if self.active == "fehler" and self.special and w in self.special["queue"]:
            self.retry_at = 0
        if w != self.active or not self.procs:
            if now < self.retry_at and w == getattr(self, "_last_try", None):
                return 2, mode
            if self.procs:
                self.kill()
            self._last_try = w
            try:
                self.start(w)
                self.slice_start = time.time()
                if self.err and self.err.startswith("Start"):
                    self.err = None
            except Exception as e:
                self.fails += 1
                back = min(300, 10 * 2 ** (self.fails - 1))
                self.retry_at = now + back
                self.err, self.err_t = str(e)[:200], int(now)
                self.active = "fehler"
                self.log(self.err, "- neuer Versuch in %d s" % back)
        elif self.fails and now - self.since > 120:
            self.fails, self.err = 0, None
        return 2, mode

    def loop(self):
        def _sig(*_):
            self.stop = True
        signal.signal(signal.SIGTERM, _sig)
        signal.signal(signal.SIGINT, _sig)
        self.log("Start v%d, Basis %s, Heimat %s, auto %s" % (V, self.base, self.cfg["home"], self.cfg["auto"]))
        mode = get_mode(self.base)
        while not self.stop:
            try:
                wait, mode = self.step()
            except Exception as e:
                self.log("Planer-Fehler:", e)
                wait = 10
            try:
                if not self.special:
                    self.maintain(time.time())
            except Exception as e:
                self.log("Wartung:", e)
            try:
                self.status(mode, force=(time.time() - self.started < 20))
                self.flush()
                if time.time() - self.last_prune > 3600:
                    with self.lock:
                        self.s433.prune(self.cfg["keep_days"])
                        self.saprs.prune(self.cfg["keep_days"])
                    self.last_prune = time.time()
            except Exception as e:
                self.log("Speichern:", e)
            end = time.time() + wait
            while not self.stop and time.time() < end:
                time.sleep(0.5)
                gm = get_mode(self.base)
                if gm["mode"] != mode["mode"] or gm.get("preset") != mode.get("preset"):
                    break
        self.kill()
        self.active = "idle"
        self.flush(True)
        self.status(mode, True)
        self.log("Ende")


# ---------------------------------------------------------------- Selbsttest (ohne Stick)
SAMPLES_433 = [
    '{"time":"1760270000","model":"Nexus-TH","id":177,"channel":1,"battery_ok":1,"temperature_C":12.3,"humidity":71,"rssi":-7.1,"snr":21.4,"noise":-28.5}',
    '{"time":"1760270000","model":"Nexus-TH","id":177,"channel":1,"battery_ok":1,"temperature_C":12.3,"humidity":71,"rssi":-7.0,"snr":21.0,"noise":-28.5}',
    '{"time":"1760270031","model":"Fineoffset-WH24","id":44,"temperature_C":10.9,"humidity":88,"wind_dir_deg":225,"wind_avg_m_s":2.1,"wind_max_m_s":4.4,"rain_mm":12.6,"uv":3,"light_lux":5540.0}',
    '{"time":"1760270040","model":"Acurite-Tower","id":9876,"channel":"A","temperature_F":50.0,"humidity":60}',
    'kein json', '{"kaputt":',
]
SAMPLES_APRS = [
    "[0.4] DB0NU>APNU19,WIDE2-1:!4927.37N/01105.36E#PHG5130 Digi Nuernberg",
    "[0.3] DL1ABC-9>493S33,DB0NU*,WIDE2:`'#t\x1e\x1cv>/Fahrt",
    "[0L] DO2XYZ-13>APRS,WIDE1-1:@121215z4933.33N/01107.88E_225/004g009t050r000p012P012h88b10132WX Kalchreuth",
    "[0.1] DL2BBB>APRS,WIDE2-2::DL1ABC-9 :Hallo, QRV?{42",
    "[0.1] DL1ABC-9>APRS::DL2BBB   :ack42",
    "[0.2] DK0XX>APOT30,WIDE2-1:=/5L!!<*e7>7P[Kompr",
    "[0.2] DB0XYZ>APRS:;LEOSAT   *121200z4930.00N/01100.00E`Objekt",
    "[0.2] DL3QQ>APRS:>Status Text",
    "audio level = 34(10/9)   [NONE]   ||||||___",
    "[0.2] DB0ABC>APRS:}DL9XX>APRS,TCPIP,DB0ABC*:!4950.00N/01110.00E-drittes",
]


def selftest():
    import tempfile
    tmp = tempfile.mkdtemp(prefix="sdrtest")
    s = State433(tmp)
    got = [s.add(x) for x in SAMPLES_433]
    assert got[0] and got[1] is None and got[2] and got[3] and got[4] is None and got[5] is None, got
    w = s.d["sensors"]["Fineoffset-WH24|44|"]
    assert w["wind_avg_km_h"] == 7.6 and w["rain_mm"] == 12.6, w
    assert s.d["sensors"]["Acurite-Tower|9876|A"]["temperature_C"] == 10.0
    s.save(True)
    a = StateAPRS(tmp, HOME_FALLBACK)
    res = [parse_aprs(x) for x in SAMPLES_APRS]
    assert res[0]["type"] == "pos" and abs(res[0]["lat"] - 49.45617) < 1e-3 and abs(res[0]["lon"] - 11.08933) < 1e-3, res[0]
    assert res[1]["type"] == "pos" and res[1].get("mice") and not res[1]["direct"] and abs(res[1]["lat"] - 49.5555) < 1e-3 and abs(res[1]["lon"] - 11.1313) < 1e-3 and res[1]["speed_kmh"] == 37, res[1]
    assert res[2]["type"] == "wx" and res[2]["wx"]["temp_c"] == 10.0 and res[2]["wx"]["hpa"] == 1013.2 and res[2]["wx"]["hum"] == 88, res[2]
    assert res[3]["type"] == "msg" and res[3]["to"] == "DL1ABC-9" and res[3]["text"] == "Hallo, QRV?" and res[3]["msgid"] == "42", res[3]
    assert res[4]["type"] == "ack"
    assert res[5]["type"] == "pos" and -90 < res[5]["lat"] < 90, res[5]
    assert res[6]["type"] == "obj" and res[6]["name"] == "LEOSAT", res[6]
    assert res[7]["type"] == "status"
    assert res[8] is None
    assert res[9]["src"] == "DL9XX" and res[9]["third"] == "DB0ABC", res[9]
    for x in SAMPLES_APRS:
        a.add(x)
    a.save(True)
    st = load_json(p("aprs_state.json", tmp))
    assert st["stations"]["DB0NU"]["dist_km"] < 20 and len(st["msgs"]) == 1, st["stations"]["DB0NU"]
    # Whitelist (Testfrequenzen ausserhalb werden berechnet, damit keine verbotenen Literale im Code stehen)
    def _mz(x):
        return "%.3fM" % x
    assert tune_ok("ism433", "433.92M") and tune_ok("srd868", "868.3M") and tune_ok("aprs", "144.800M") and not tune_ok("aprs", _mz(144.8 + 0.025))
    assert tune_ok("fm", "87.5M") and tune_ok("fm", "108.0M") and not tune_ok("fm", _mz(108 + 0.1)) and not tune_ok("fm", _mz(170 + 3.2))
    assert tune_ok("dab", ch="11D") and not tune_ok("dab", ch="L1") and tune_ok("wxsat", "137.1e6") and not tune_ok("wxsat", _mz(138 + 0.5))
    assert not tune_ok("ism433", _mz(430 + 3)) and not tune_ok("bos", _mz(170 + 2)) and not tune_ok("fm", "abc")
    for x in PRESETS:
        assert tune_ok(x["kind"], x.get("f"), x.get("ch")), x
    assert len(set(PRESET_IDS)) == len(PRESET_IDS)
    for bad in (("433", 45), ("x", 30), (None, 30), ("433", "30"), ("433", True), (_mz(170 + 3.2), 30)):
        try:
            set_preset(tmp, *bad)
            raise AssertionError(bad)
        except ValueError:
            pass
    assert set_preset(tmp, "fm_b3", 30)["preset"] == "fm_b3" and get_mode(tmp)["mode"] == "preset"
    write_json(p("sdr_mode.json", tmp), {"mode": "preset", "preset": "fm_b3", "until": int(time.time()) - 1})
    assert get_mode(tmp)["mode"] == "auto"
    write_json(p("sdr_mode.json", tmp), {"mode": "preset", "preset": "evil", "until": int(time.time()) + 600})
    assert get_mode(tmp)["mode"] == "auto"
    pl0 = Planner(tmp)
    pl0.cfg["f433"] = _mz(170 + 3.25)
    try:
        pl0.cmd("433")
        raise AssertionError("433 ausserhalb")
    except RuntimeError:
        pass
    assert pl0.cmd("p:868")[0][2] == "868.3M"
    # Zeilen-Log
    ll = LineLog(tmp, {"linelog_keyword": "warn", "linelog_flush_s": 30})
    assert ll.add("fm_b3", "Amtliche Warnung") and not ll.add("fm_b3", "Musik") and not ll.add("evil", "warn")
    ll.flush(True)
    ll.add("fm_b3", "Unwetterwarnung 2")
    ll.flush(True)
    fl = os.listdir(os.path.join(tmp, "archive", "linelog"))
    assert len(fl) == 1 and fl[0].startswith("fm_b3_"), fl
    rows = [json.loads(x) for x in open(os.path.join(tmp, "archive", "linelog", fl[0]))]
    assert [r["line"] for r in rows] == ["Amtliche Warnung", "Unwetterwarnung 2"], rows
    # Aktivitaet: synthetisch 2 Aussendungen je ~15 s in einer Minute, sonst Rauschen
    try:
        import numpy as np
        mt = ActMeter()
        rng = np.random.default_rng(1)
        t0 = 60 * 3000 * 10000
        recs = []
        sec = 240000
        tt = np.arange(sec) / 240000.0
        tone = 0.25 * np.exp(2j * np.pi * 2500 * tt)
        for i in range(62):
            iq = (rng.normal(0, 0.02, sec) + 1j * rng.normal(0, 0.02, sec))
            if 5 <= i < 20 or 35 <= i < 50:
                iq = iq + tone
            u = np.empty(2 * sec, dtype=np.uint8)
            u[0::2] = np.clip(np.round(iq.real * 127.5 + 127.4), 0, 255)
            u[1::2] = np.clip(np.round(iq.imag * 127.5 + 127.4), 0, 255)
            recs += mt.feed(u.tobytes(), now=t0 + i)
        assert len(recs) == 1 and recs[0]["tx"] == 2 and 45 <= recs[0]["occ_pct"] <= 55 and -16 < recs[0]["peak_dbfs"] < -8, recs
        assert set(recs[0]) == {"t", "s", "occ_pct", "peak_dbfs", "tx", "noise_dbfs"}
    except ImportError:
        print("selftest: numpy fehlt - Aktivitaet nicht geprueft")
    assert tune_ok("act2m", "145.500M") and not tune_ok("act2m", _mz(145.5 + 0.0125)) and not tune_ok("fm", "145.500M")
    assert tune_ok("pmr446", "446.03125M") and not tune_ok("pmr446", _mz(446 + 0.3)) and not tune_ok("act2m", "446.03125M")
    b = StateBC(tmp)
    assert b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","tp":true,"ta":false,"ps":"BR24    "}')["ps"] == "BR24"
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"0A","tp":true,"ta":true,"ps":"BAYERN 3"}')
    b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Amtliche Warnung vor Unwetter im Landkreis ERH"}')
    assert [w["kind"] for w in b.d["warn"]] == ["TA", "RT"], b.d["warn"]
    dab = b.on_dab("11D", {"ensemble": {"label": {"label": "BR Bayern"}}, "services": [{"label": {"label": "BR24"}, "dls": {"label": "Nachrichten"}},
                                                                                      {"label": {"label": "Bayern 3"}, "dls": {"label": "Unwetterwarnung Nürnberg"}}],
                                     "announcements": [{"type": "Alarm", "active": True}]})
    assert dab["ensemble"] == "BR Bayern" and dab["n"] == 2 and dab["alarm"] and len(b.d["warn"]) == 4, (dab, b.d["warn"])
    b.save(True)
    mice = res[1]
    print("selftest OK: 433 Sensoren=%d, APRS Stationen=%d, Mic-E %.4f/%.4f, WX %s" % (
        len(s.d["sensors"]), len(st["stations"]), mice["lat"], mice["lon"], res[2]["wx"]))
    return True


if __name__ == "__main__":
    a = sys.argv[1] if len(sys.argv) > 1 else "status"
    if a == "run":
        Planner(BASE).loop()
    elif a == "selftest":
        selftest()
    else:
        print(json.dumps(load_json(p("sdr_status.json"), {}), indent=1, ensure_ascii=False))
MODPY_EOF
cat > "$W/prepper_sdr_net.py" << 'NETPY_EOF'
#!/usr/bin/env python3
"""prepper_sdr_net: einzige Netzzugriffe des SDR-Planers (nur lesen):
- Bahndaten (TLE) der Wettersatelliten von celestrak.org (fester Host, nur wenn online; Cache fuer offline)
- Status-JSON von welle-cli auf 127.0.0.1 (lokal, DAB+-Texte)
Sendet nichts - kein Mesh, kein Funk."""
import json
import re
import urllib.request

CELESTRAK = "https://celestrak.org/NORAD/elements/gp.php?CATNR=%d&FORMAT=tle"
RE_L1 = re.compile(r"^1 (\d{5})[A-Z ]")
RE_L2 = re.compile(r"^2 (\d{5}) ")


def fetch_tle(catnr, timeout=15):
    """-> (name, line1, line2) oder Exception. Nur celestrak.org, Ergebnis wird geprueft."""
    catnr = int(catnr)
    req = urllib.request.Request(CELESTRAK % catnr, headers={"User-Agent": "prepper-sdr/1 (Wetterbilder)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        txt = r.read(4096).decode("ascii", "replace")
    lines = [x.rstrip() for x in txt.splitlines() if x.strip()]
    if len(lines) < 3:
        raise ValueError("TLE leer: %s" % txt[:60])
    name, l1, l2 = lines[0].strip(), lines[1], lines[2]
    m1, m2 = RE_L1.match(l1), RE_L2.match(l2)
    if not (m1 and m2 and int(m1.group(1)) == catnr and int(m2.group(1)) == catnr and len(l1) >= 68 and len(l2) >= 68):
        raise ValueError("TLE ungueltig")
    return name, l1, l2


def fetch_welle(port, timeout=4):
    """mux.json von welle-cli (nur 127.0.0.1)."""
    port = int(port)
    with urllib.request.urlopen("http://127.0.0.1:%d/mux.json" % port, timeout=timeout) as r:
        return json.loads(r.read(2000000).decode("utf-8", "replace"))
NETPY_EOF

# ---------- 0) Bytes + AST-Guards + Selbsttest ----------
P="$W/patch-sdr-act.py"; M="$W/prepper_sdr.py"; N="$W/prepper_sdr_net.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $M" | sha256sum -c - >/dev/null || { echo "STOP: Modul sha256 falsch"; exit 1; }
echo "$EXPECT_NET  $N" | sha256sum -c - >/dev/null || { echo "STOP: Netzmodul sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
for x in "$M" "$N"; do python3 -W error::SyntaxWarning -m py_compile "$x" || { echo "STOP: py_compile $x - nichts geaendert"; exit 1; }; done
set +e
python3 - "$P" "$M" "$N" << 'GUARDPY'
import ast, pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
NET = ("requests", "urllib", "socket", "socketserver", "http", "meshtastic", "subprocess", "asyncio", "ssl")
RANGES = {"ism433": (433.05, 434.79), "srd868": (863.0, 870.0), "aprs": (144.8, 144.8), "fm": (87.5, 108.0), "dab": (174.0, 240.0), "wxsat": (137.0, 138.0),
          "act2m": (145.5, 145.5), "pmr446": (446.0, 446.2)}
def fname(f):
    return f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
def in_ranges(mhz):
    return any(lo - 1e-9 <= mhz <= hi + 1e-9 for lo, hi in RANGES.values())
FRE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(M|MHz|e6)\s*$")
def bad_common(code, who):
    h = False
    low = code.lower()
    for bad in ("multimon", "pocsag", "rpitx", "hackrf_transfer", "sendiq", "ptt gpio", "ptt /dev", "igserver", "pbeacon", "serve_forever", "socketserver"):
        if bad in low:
            print(who, "verboten:", bad); h = True
    if "FLEX" in code:
        print(who, "verboten: FLEX"); h = True
    tree = ast.parse(code)
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if "173." in node.value:
                print(who, "verboten: 173.x"); h = True
            m = FRE.match(node.value)
            if m and not in_ranges(float(m.group(1))):
                print(who, "Frequenz ausserhalb Whitelist:", node.value); h = True
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
            v = float(node.value)
            if 1e7 <= v <= 3e9 and not in_ranges(v / 1e6):
                print(who, "Zahl wie Frequenz ausserhalb Whitelist:", v); h = True
            if 173.0 <= v < 174.0:
                print(who, "verboten: 173.x"); h = True
        if isinstance(node, ast.keyword) and node.arg == "shell":
            print(who, "shell="); h = True
        if isinstance(node, ast.Call) and fname(node.func) in ("bind", "listen", "accept", "serve_forever", "create_server", "start_server"):
            print(who, "Server-Aufruf", fname(node.func)); h = True
    return h, tree
h, btree = bad_common(blk, "Block")
hit |= h
for node in ast.walk(btree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in NET:
                print("Block: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        fn = fname(node.func)
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("open", "update_all", "urlopen", "Popen", "system", "call", "run", "remove", "unlink", "rmtree", "write_json", "write_text", "set_mode"):
            print("Block: verbotener Aufruf", fn); hit = True
for bad in ("mesh", "Mesh", "<input", "'input'", '"input"', "freq", "frequency", "range(", "POST", "request"):
    if bad in blk:
        print("Block enthaelt", bad); hit = True
mod = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
h, tree = bad_common(mod, "Modul")
hit |= h
ALLOWED = {"rtl_433", "rtl_fm", "rtl_tcp", "direwolf", "rtl_sdr"}
TOOLS = {"redsea", "welle", "satdump"}
owner = {}
consts = {}
for fn_node in ast.walk(tree):
    if isinstance(fn_node, ast.FunctionDef):
        for sub in ast.walk(fn_node):
            owner[id(sub)] = fn_node.name
for n in tree.body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("F_RANGES", "DAB_CHANNELS", "PRESETS"):
        consts[n.targets[0].id] = ast.literal_eval(n.value)
if consts.get("F_RANGES") != RANGES:
    print("Modul: F_RANGES veraendert"); hit = True
for k, v in (consts.get("DAB_CHANNELS") or {}).items():
    if not (174.0 <= v <= 240.0):
        print("Modul: DAB-Kanal ausserhalb Band III", k); hit = True
for x in consts.get("PRESETS") or [print("Modul: PRESETS fehlt")]:
    k = x.get("kind")
    if k == "dab":
        ok = x.get("ch") in (consts.get("DAB_CHANNELS") or {})
    else:
        m = FRE.match(str(x.get("f")))
        lo, hi = RANGES.get(k, (1, 0))
        ok = bool(m) and lo - 1e-9 <= float(m.group(1)) <= hi + 1e-9
    if not ok:
        print("Modul: Preset ausserhalb", x); hit = True
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in ("requests", "urllib", "socket", "socketserver", "http", "meshtastic", "asyncio", "ssl"):
                print("Modul: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        fn = fname(node.func)
        where = owner.get(id(node))
        if fn == "rmtree" and where == "_clean_tmp":
            pass
        elif fn == "remove" and where in ("_prune_meteor", "prune"):
            pass
        elif fn.startswith(("send", "maybe_mesh")) or fn in ("system", "popen", "call", "check_output", "check_call", "run", "rmtree", "unlink", "remove", "execv", "execvp"):
            print("Modul: verbotener Aufruf", fn, "in", where); hit = True
        if fn == "tool" and not (node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value in TOOLS):
            print("Modul: tool() mit", ast.dump(node.args[0]) if node.args else "-"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "rtl_sdr":
        if owner.get(id(node)) != "_cmd_act":
            print("Modul: rtl_sdr ausserhalb _cmd_act"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and isinstance(node.elts[0].value, str):
        v = node.elts[0].value
        if v.startswith(("rtl", "direwolf", "rpitx", "hackrf", "sendiq", "tx", "multimon", "redsea", "welle", "satdump")) and v not in ALLOWED:
            print("Modul: Programm", v); hit = True
ca = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_cmd_act"]
if ca and not any(isinstance(c, ast.List) and c.elts and isinstance(c.elts[-1], ast.Constant) and c.elts[-1].value == "-" for c in ast.walk(ca[0])):
    print("Modul: rtl_sdr nicht nur nach stdout"); hit = True
ar = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in ("_act_reader", "feed", "_record")]
for fdef in ar:
    for c in ast.walk(fdef):
        if isinstance(c, ast.Call) and fname(c.func) in ("open", "write", "write_json", "wavfile", "save"):
            print("Modul: Aktivitaet schreibt Rohdaten?", fname(c.func)); hit = True
for fnn in ("_cmd_rds", "_cmd_dab", "_cmd_meteor", "_cmd_act"):
    body = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == fnn]
    if not body or not any(isinstance(c, ast.Call) and fname(c.func) == "check_tune" for c in ast.walk(body[0])):
        print("Modul: %s ohne check_tune" % fnn); hit = True
net = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
h, ntree = bad_common(net, "Netz")
hit |= h
URLS = {"https://celestrak.org/NORAD/elements/gp.php?CATNR=%d&FORMAT=tle", "http://127.0.0.1:%d/mux.json"}
for node in ast.walk(ntree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            m = (getattr(node, "module", None) or a.name)
            if m not in ("json", "re", "urllib.request"):
                print("Netz: Import", m); hit = True
    if isinstance(node, ast.Constant) and isinstance(node.value, str) and "://" in node.value and node.value not in URLS:
        print("Netz: URL", node.value); hit = True
    if isinstance(node, ast.Call) and fname(node.func) not in ("Request", "urlopen", "read", "decode", "splitlines", "strip", "rstrip", "match", "int", "len", "ValueError", "group", "loads", "compile"):
        print("Netz: Aufruf", fname(node.func)); hit = True
    if isinstance(node, ast.keyword) and node.arg == "data":
        print("Netz: data= (POST)"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
python3 "$M" selftest > "$W/selftest.txt" 2>&1 || { cat "$W/selftest.txt"; echo "STOP: Selbsttest - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (Frequenz-Whitelist, kein multimon/POCSAG/FLEX/173.x, kein shell=, keine Server, kein Mesh) + Selbsttest"

# ---------- 1) Voraussetzungen (nur lesen) ----------
[[ -f "$DASH_DIR/prepper_sdr.py" ]] && grep -q 'prepper_sdr: SDR-Planer' "$DASH_DIR/prepper_sdr.py" || { echo "STOP: prepper_sdr.py (sdrFunk) fehlt - nichts geaendert"; exit 1; }
VLINE=$(grep -m1 '^V = ' "$DASH_DIR/prepper_sdr.py" || true)
[[ "$VLINE" == "V = 3" || "$VLINE" == "V = 4" ]] || { echo "STOP: prepper_sdr.py ist nicht v3 (sdrPreset) sondern '$VLINE' - nichts geaendert"; exit 1; }
systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "STOP: $UNIT fehlt - nichts geaendert"; exit 1; }
SDR_WAS=$(systemctl is-active "$UNIT" 2>/dev/null || true)
echo "prepper-sdr vorher: $SDR_WAS"
# apt-Hilfen: Ausgabe erst einsammeln, dann pruefen (kein 'grep -q' in einer Pipe unter pipefail - SIGPIPE macht sonst falsch-negativ)
have() { local o; o=$(LC_ALL=C dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true); [[ "$o" == "install ok installed" ]]; }
cand() { local o; o=$(LC_ALL=C apt-cache policy "$1" 2>/dev/null || true); [[ "$o" =~ Candidate:\ [0-9] ]]; }
MISS=()
for pb in rtl-433:rtl_433 direwolf:direwolf welle.io:welle-cli satdump:satdump; do command -v "${pb#*:}" >/dev/null 2>&1 || have "${pb%%:*}" || MISS+=("${pb%%:*}"); done
/usr/bin/python3 -c "import sgp4.api" 2>/dev/null || have python3-sgp4 || MISS+=(python3-sgp4)
/usr/bin/python3 -c "import PIL" 2>/dev/null || have python3-pil || MISS+=(python3-pil)
/usr/bin/python3 -c "import numpy" 2>/dev/null || have python3-numpy || MISS+=(python3-numpy)
command -v rtl_sdr >/dev/null 2>&1 || have rtl-sdr || MISS+=(rtl-sdr)
if [[ ${#MISS[@]} -gt 0 ]]; then
  sudo -v
  sudo env LC_ALL=C apt-get update -qq || echo "WARN apt-get update fehlgeschlagen (offline?)"
  for p in "${MISS[@]}"; do
    if cand "$p"; then
      # shellcheck disable=SC2024
      sudo env LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$p" >> "$W/apt.txt" 2>&1 || true
      have "$p" && echo "  installiert: $p" || echo "WARN $p nicht installierbar"
    else
      echo "WARN Paket $p ohne Kandidat"
    fi
  done
fi
echo "numpy=$(/usr/bin/python3 -c 'import numpy' 2>/dev/null && echo 1 || echo 0) rtl_sdr=$(command -v rtl_sdr >/dev/null 2>&1 && echo 1 || echo 0) (fuer Aktivitaet)"
echo "Programme: rtl_433=$(command -v rtl_433 >/dev/null && echo 1 || echo 0) welle-cli=$(command -v welle-cli >/dev/null && echo 1 || echo 0) satdump=$(command -v satdump >/dev/null && echo 1 || echo 0) redsea=$( { [[ -x /usr/local/bin/redsea ]] || command -v redsea >/dev/null; } && echo 1 || echo 0)"
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"

# ---------- 2) Trockenlauf ----------
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
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /funk433 /aprs /meteor /energie)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
[[ "${PRE[/funk]}" == "200" ]] || { echo "STOP: /funk antwortet nicht (${PRE[/funk]}) - nichts geaendert"; exit 1; }
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
A0=$(grep -o "sda-js\|sdh-" "$W/pi0.html" | wc -l || true)

# ---------- 3) Installieren + Neustart (nur prepper-sdr + prepper-dashboard) ----------
same_dash=0; cmp -s "$W/work/dashboard.py" "$F" && same_dash=1
same_mod=0; cmp -s "$M" "$DASH_DIR/prepper_sdr.py" && same_mod=1
same_net=0; cmp -s "$N" "$DASH_DIR/prepper_sdr_net.py" 2>/dev/null && same_net=1
if [[ "$same_dash$same_mod$same_net" == "111" && "$SDR_WAS" == active ]]; then
  echo "OK sdrAct schon installiert - kein Neustart"
else
  sudo -v
  MODE_BAK="$W/sdr_mode.json.orig"; HAD_MODE=0
  [[ -f "$DASH_DIR/sdr_mode.json" ]] && cp -a "$DASH_DIR/sdr_mode.json" "$MODE_BAK" && HAD_MODE=1
  restore_mode() { if [[ "$HAD_MODE" == 1 ]]; then cp -a "$MODE_BAK" "$DASH_DIR/sdr_mode.json.tmp" && mv -f "$DASH_DIR/sdr_mode.json.tmp" "$DASH_DIR/sdr_mode.json"; else rm -f "$DASH_DIR/sdr_mode.json"; fi; }
  rb() {
    echo "ROLLBACK: $1"
    echo "--- Dashboard-Log (letzte Zeilen) ---"
    sudo journalctl -u prepper-dashboard --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | tail -12 | cut -c1-200 || true
    echo "--- prepper-sdr-Log ---"
    sudo journalctl -u "$UNIT" --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | tail -6 | cut -c1-200 || true
    cp -a "$F.bak-sdr5-$TS" "$F"
    [[ -f "$DASH_DIR/prepper_sdr.py.bak-sdr5-$TS" ]] && cp -a "$DASH_DIR/prepper_sdr.py.bak-sdr5-$TS" "$DASH_DIR/prepper_sdr.py"
    [[ -f "$DASH_DIR/prepper_sdr_net.py.bak-sdr5-$TS" ]] && cp -a "$DASH_DIR/prepper_sdr_net.py.bak-sdr5-$TS" "$DASH_DIR/prepper_sdr_net.py"
    restore_mode
    sudo systemctl restart "$UNIT" 2>/dev/null || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/"), prepper-sdr $(systemctl is-active "$UNIT" 2>/dev/null || true)), Backup $F.bak-sdr5-$TS"
  }
  cp -a "$F" "$F.bak-sdr5-$TS"
  [[ "$same_mod" == 0 ]] && cp -a "$DASH_DIR/prepper_sdr.py" "$DASH_DIR/prepper_sdr.py.bak-sdr5-$TS"
  [[ "$same_net" == 0 && -f "$DASH_DIR/prepper_sdr_net.py" ]] && cp -a "$DASH_DIR/prepper_sdr_net.py" "$DASH_DIR/prepper_sdr_net.py.bak-sdr5-$TS"
  install -m 644 "$N" "$DASH_DIR/prepper_sdr_net.py.new" && mv -f "$DASH_DIR/prepper_sdr_net.py.new" "$DASH_DIR/prepper_sdr_net.py" || { rb "Netzmodul installieren"; exit 1; }
  install -m 644 "$M" "$DASH_DIR/prepper_sdr.py.new" && mv -f "$DASH_DIR/prepper_sdr.py.new" "$DASH_DIR/prepper_sdr.py" || { rb "Modul installieren"; exit 1; }
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl restart "$UNIT" || { rb "Start $UNIT"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard + prepper-sdr neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  for i in $(seq 1 20); do [[ "$(code "$B/funk")" == "200" && "$(code "$B/api/sdr/status")" == "200" ]] && break; sleep 3; done
  for i in $(seq 1 40); do python3 -c "import json,sys; assert json.load(open(sys.argv[1])).get('v')==4" "$DASH_DIR/sdr_status.json" 2>/dev/null && break; sleep 2; done
  systemctl is-active --quiet "$UNIT" || { rb "$UNIT laeuft nicht"; exit 1; }
  sc=$("${CURL[@]}" "$B/api/sdr/status" -o "$W/s0.json" -w "%{http_code}" || true)
  [[ "$sc" == "200" ]] || { rb "/api/sdr/status antwortet nicht ($sc)"; exit 1; }
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); s=d.get('status') or {}; assert d.get('module') and s.get('v')==4 and d['service']=='läuft' and len(d.get('presets') or [])==21 and len(d.get('act') or [])==2 and 'linelog' in s and 'bc' in d and 'meteor' in d, d" "$W/s0.json" || { rb "/api/sdr/status ungueltig (Planer v4 / Presets / Aktivitaet fehlen)"; exit 1; }
  python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') and len(d['summary'])==2" < <("${CURL[@]}" "$B/api/sdr/activity") || { rb "/api/sdr/activity ungueltig"; exit 1; }
  echo "OK prepper-sdr v4 laeuft, 21 Presets (2 Aktivitaet, UKW 98,0), /api/sdr/activity"
  # API darf nur Preset-IDs annehmen
  post() { "${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' --data "$1" "$B/api/sdr/preset" || true; }
  bad=0
  for body in '{"id":"bogus","minutes":30}' '{"id":"act_1455","minutes":30,"f":"145.525M"}' '{"id":"act_pmr9","minutes":30}' '{"f":"433.92M","minutes":30}' '{"id":"433","minutes":45}' '{"id":"433","minutes":"30"}' '{"id":"433","minutes":30,"f":"145.5M"}' '{"id":["433"],"minutes":30}' 'kein json'; do
    c=$(post "$body"); [[ "$c" == "400" ]] || { echo "  falsch angenommen ($c): $body"; bad=1; }
  done
  [[ "$bad" == 0 ]] || { rb "/api/sdr/preset nimmt mehr als Preset-IDs an"; exit 1; }
  echo "OK /api/sdr/preset lehnt freie Frequenzen/ungueltige Werte ab (9x 400)"
  c=$(post '{"id":"433","minutes":30}')
  [[ "$c" == "200" ]] || { restore_mode; rb "/api/sdr/preset gueltiges Preset abgelehnt ($c)"; exit 1; }
  pa=""; for i in $(seq 1 15); do sleep 2; pa=$("${CURL[@]}" "$B/api/sdr/status" | python3 -c "import json,sys; print((json.load(sys.stdin).get('status') or {}).get('active'))" 2>/dev/null || true); [[ "$pa" == "p:433" ]] && break; done
  restore_mode
  [[ "$pa" == "p:433" ]] || { rb "Planer uebernimmt Preset nicht (aktiv $pa)"; exit 1; }
  echo "OK Preset 433 vom Planer uebernommen, Betriebsart danach wiederhergestellt"
  fc=$("${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" -w "%{http_code}" || true)
  [[ "$fc" == "200" ]] || { rb "/funk antwortet nicht ($fc)"; exit 1; }
  python3 - "$W/funk.html" << 'PY' || { rb "/funk: Kachel ohne Preset-Auswahl"; exit 1; }
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
assert h.count('id="sdrCard"') == 1 and 'id="sdr-js"' in h, "Kachel fehlt"
assert "w.id='sdrPreset'" in h and "/api/sdr/preset" in h and "Rundfunk: " in h and "Meteor: " in h and "Aktivität: " in h, "Auswahl/Zeilen fehlen"
assert "<input" not in h[h.find('id="sdr-js"'):], "Eingabefeld in der Kachel"
PY
  echo "OK /funk SDR-Kachel mit Aktivitaets-Zeile + Preset-Auswahl (kein Eingabefeld)"
  "${CURL[@]}" -L --max-redirs 5 "$B/" -o "$W/lage.html" || true
  if grep -q -e 'id="sdr-js"' -e 'id="sdrCard"' "$W/lage.html"; then rb "Lage-Seite hat ploetzlich die SDR-Kachel"; exit 1; fi
  for pg in /funk433 /aprs /meteor; do
    pc=$(code_r "$B$pg")
    [[ "$pc" == "200" ]] || { rb "$pg fehlerhaft ($pc)"; exit 1; }
  done
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] && grep -q 'id="sdr-pi-js"' "$W/pi.html" || { rb "/pi ohne SDR-Zeile ($pc)"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); A1=$(grep -o "sda-js\|sdh-" "$W/pi.html" | wc -l || true)
    [[ "$R1" == "$R0" && "$A1" == "$A0" ]] || { rb "/pi veraendert (Sicherung $R0/$R1, SD-Kachel $A0/$A1)"; exit 1; }
  fi
  echo "OK Lage ohne Kachel, /funk433 /aprs /meteor ok, /pi unveraendert"
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'sdrPreset' -e 'sdrAct' | tail -3 || true
fi
fail=0
for p in "${PAGES[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-sdr5-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
"${CURL[@]}" "$B/api/sdr/status" | python3 -c "
import json,sys
d=json.load(sys.stdin); s=d.get('status') or {}
print('SDR Dienst %s · aktiv %s · Modus %s · Zeilen-Log %s · Programme %s' % (d.get('service'), s.get('active'), (d.get('mode') or {}).get('mode'), s.get('linelog'), s.get('tools')))
print('SDR Fehler: %s' % (s.get('err') or 'keiner'))
" 2>/dev/null || echo "WARN Status nicht lesbar"
echo "OK guards sdrAct=$(grep -q '# ===== sdrAct:' "$F" && echo 1 || echo 0) sdrPreset=$(grep -q '# ===== sdrPreset:' "$F" && echo 1 || echo 0) sdrPlus=$(grep -q '# ===== sdrPlus:' "$F" && echo 1 || echo 0) sdAck=$(grep -q '# ===== sdAck:' "$F" && echo 1 || echo 0) sdrFunk2=$(grep -q '# ===== sdrFunk2:' "$F" && echo 1 || echo 0) sdrFunk=$(grep -q '# ===== sdrFunk:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-sdr5-$TS" ]] && echo "Backup: $F.bak-sdr5-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG sdrAct=1"
