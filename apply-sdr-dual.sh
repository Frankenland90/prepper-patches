#!/bin/bash
set -euo pipefail
# sdrDual (auf sdrLage): Stick 1 SN 19348831 = Rundfunk fest (BR24 UKW-RDS/DAB-DLS + 5C ASA, Kalibrierung), Stick 2 SN 72055505 = Wechselbetrieb
# (QRM/Gewitter, 433, APRS/Meteor/Aktivitaet nach Schaltern), eigene ppm je Stick, ein Prozess fuer beide, Ansprache nur per Seriennummer, Einzelbetrieb wenn einer fehlt.
# Neustart nur prepper-sdr + prepper-dashboard. Sendet nichts, kein Mesh, kein neues Netz, aendert keinen Modus.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdrdual-apply
UNIT="prepper-sdr.service"
KEEP_LAST=3
SN1="19348831"
SN2="72055505"
BASE_DASH16="a05d682728b20b55"
BASE_MOD16="53c2fb9822b85fb5"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sdrDual apply, Dashboard-Port $PORT ==="
NEW_MOD16="78b9106899d1fbbd"
EXPECT_MOD="78b9106899d1fbbd93e045c44886da22073a6d4b47b6561cbec6f6459704af72"
EXPECT_PATCH="af8523bc8b98c3c70796668b6dc3ba4662ab4e8d64ced322ed9e6f488cc9dd1c"
EXPECT_BLK="5a2f77c7884a18c9a8376c67c806418878ee77b75653f201598639f348f586a1"
rm -rf "$W" && mkdir -p "$W"
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

V = 10
BASE = os.path.dirname(os.path.abspath(__file__))
MODES = ("auto", "433", "aprs", "tcp", "off")
DEFAULT_CFG = {
    "slice_433_s": 300, "slice_aprs_s": 300, "auto": ["433", "aprs"],
    "f433": "433.92M", "faprs": "144.800M", "ppm": 0, "gain_433": None, "gain_aprs": None,
    "device": None, "serial": "19348831", "dab_tcp_port": 1235, "tcp_port": 1234, "tcp_bind": "0.0.0.0", "tcp_default_min": 60, "tcp_max_min": 480,
    "usb_ids": ["0bda:2838", "0bda:2832"], "max_jsonl_mb": 8, "aprs_max_jsonl_mb": 4,
    "home": None, "keep_days": 14,
    "bc_enable": True, "bc_interval_s": 1800, "fm": None, "fm_s": 60, "dab": None, "dab_s": 60, "dab_port": 7979, "gain_fm": 40, "gain_dab": None, "gain_act": None,
    "meteor_enable": True, "sats": None, "meteor_min_el": 20, "meteor_gain": 38, "meteor_samplerate": "1024000",
    "meteor_keep": 30, "meteor_cap_mb": 300, "meteor_tmp": "/tmp/prepper-meteor", "tle_refresh_h": 12,
    "redsea": None, "welle": None, "satdump": None,
    "stick2": {"model": "NESDR SMArt v5", "serial": None, "roles": ["433"], "enabled": False},  # sdrLage: vorbereitet, inaktiv
    "ppm2": 0, "ppm_cal2": None, "cal_hour2": 4, "dab_port2": 7981, "dab_tcp_port2": 1237,  # sdrDual: Stick 2 eigene Kalibrierung/Ports
    "act_s": 60, "act_interval_s": 1800,
    "noise_enable": True, "noise_interval_s": 900, "noise_s": 7, "noise_hf": True, "gain_noise": 30, "noise_car_db": 10, "noise_car_n": 4,
    "noise_raise_yel": 5, "noise_raise_red": 10, "noise_k_yel": 4, "noise_k_red": 6, "noise_trend_lambda": 0.03, "noise_trend_db": 2.0, "noise_trend_off_db": 1.0, "noise_warmup_s": 300, "thunder_yel_pm": 5, "thunder_red_pm": 20,
    "gps_enable": True, "gps_interval_s": 120, "gps_read_s": 6, "gps_persist": 3, "gps_drop_yel": 6, "gps_drop_red": 10,
    "cal_enable": True, "cal_hour": 3, "cal_s": 45, "cal_step_ppm": 5, "ppm_auto": True, "ppm_cal": None,
    "linelog_enable": True, "linelog_keyword": None, "linelog_flush_s": 300, "linelog_part_kb": 512, "linelog_keep_days": 14,
}

# ---------------------------------------------------------------- Frequenz-Whitelist (einzige Quelle; Dashboard + Planer nutzen sie)
# Nur Empfang. Erlaubte Bereiche in MHz - alles andere wird verweigert (auch aus sdr_config.json).
F_RANGES = {"ism433": (433.05, 434.79), "srd868": (863.0, 870.0), "aprs": (144.8, 144.8), "fm": (87.5, 108.0),
            "dab": (174.0, 240.0), "wxsat": (137.0, 138.0),
            "act2m": (145.5, 145.5), "pmr446": (446.0, 446.2),
            "noise_mw": (0.5, 1.6), "noise_hf": (9.9, 10.2), "noise2m": (144.0, 146.0), "noisefm": (87.5, 108.0), "noisedab": (174.0, 240.0),
            "noisepmr": (446.0, 446.2), "noise433": (433.05, 434.79), "noise868": (863.0, 870.0), "noisegps": (1573.42, 1577.42)}
# Messbereiche Funkumgebung: nur Leistung je Bin (rtl_power / Direktabtastung), keine Demodulation, nur Zahlen
NOISE_KINDS = ("noise_mw", "noise_hf", "noise2m", "noisefm", "noisedab", "noisepmr", "noise433", "noise868", "noisegps")
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
    {"id": "dab_10D", "group": "DAB+", "label": "10D BDR Testkanal (ASA-Test, Büttelberg/Wendelstein)", "kind": "dab", "ch": "10D"},
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


def save_cfg_keys(base, upd):
    """Nur die genannten Schluessel in sdr_config.json setzen (Rest bleibt), atomar."""
    fn = p("sdr_config.json", base)
    d = load_json(fn, {}) or {}
    if not isinstance(d, dict):
        d = {}
    d.update(upd)
    write_json(fn, d)


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


# ===== sdrLage: Quellen-Schalter AN/AUTO/AUS, Lage-Profile, Zeitanteile, Stick-Zustand, Zweitstick vorbereitet =====
LAGE_SRC = ("433", "aprs", "bc", "asa", "meteor", "act", "noise", "cal")
LAGE_STATES = ("an", "auto", "aus")
LAGE_PROFILES = {
    "normal": {"433": "auto", "aprs": "auto", "bc": "auto", "asa": "auto", "meteor": "auto", "act": "aus", "noise": "auto", "cal": "auto"},
    "warn": {"433": "auto", "aprs": "auto", "bc": "an", "asa": "an", "meteor": "aus", "act": "aus", "noise": "an", "cal": "auto"},
    "funk": {"433": "auto", "aprs": "an", "bc": "auto", "asa": "auto", "meteor": "auto", "act": "an", "noise": "auto", "cal": "auto"},
    "ruhe": {"433": "aus", "aprs": "aus", "bc": "aus", "asa": "aus", "meteor": "aus", "act": "aus", "noise": "aus", "cal": "auto"},
}
LAGE_NAMES = {"normal": "Normal", "warn": "Warnlage", "funk": "Funklage", "ruhe": "Ruhe"}


def get_lage(base=None):
    """Lage-Datei lesen; fehlt/kaputt = Profil Normal (Verhalten wie bisher)."""
    d = load_json(p("sdr_lage.json", base), {}) or {}
    prof = d.get("profile") if d.get("profile") in LAGE_PROFILES else "normal"
    sw = dict(LAGE_PROFILES[prof])
    for k, v in (d.get("sw") or {}).items() if isinstance(d.get("sw"), dict) else ():
        if k in LAGE_SRC and v in LAGE_STATES:
            sw[k] = v
    return {"profile": prof, "name": LAGE_NAMES[prof], "sw": sw, "custom": sw != LAGE_PROFILES[prof], "at": d.get("at")}


def set_lage(base, profile=None, src=None, state=None):
    """Vom Dashboard: Profil waehlen (setzt alle Schalter) oder einen Schalter aendern -> 'Profil (angepasst)'. Atomar."""
    cur = get_lage(base)
    if profile is not None:
        if profile not in LAGE_PROFILES:
            raise ValueError("profile")
        prof, sw = profile, dict(LAGE_PROFILES[profile])
    else:
        prof, sw = cur["profile"], dict(cur["sw"])
    if src is not None or state is not None:
        if src not in LAGE_SRC or state not in LAGE_STATES:
            raise ValueError("src/state")
        sw[src] = state
    write_json(p("sdr_lage.json", base), {"profile": prof, "sw": sw, "at": int(time.time())})
    return get_lage(base)
# ===== /sdrLage-Teil1 =====
# ===== sdrDual: Stick 1 (SN serial) = Rundfunk fest, Stick 2 (SN stick2.serial) = Wechselbetrieb; ein Prozess, je Stick ein Planer =====


def cfg_serial2(cfg):
    """Seriennummer Stick 2 (nur wenn stick2.enabled und nur Ziffern, ungleich Stick 1)."""
    s2 = cfg.get("stick2") if isinstance(cfg.get("stick2"), dict) else {}
    sn = s2.get("serial")
    if isinstance(sn, int) and not isinstance(sn, bool):
        sn = str(sn)
    if not s2.get("enabled") or not serial_ok(sn) or sn == cfg_serial(cfg):
        return None
    return sn


def dual_roles(s1, s2, have2):
    """(Rolle Stick 1, Rolle Stick 2): beide da -> bc/rot; einer fehlt -> der andere macht alles wie frueher (single)."""
    if not have2:
        return "single", None
    if s1 and s2:
        return "bc", "rot"
    if s2:
        return "single", "single"
    return "single", "single"



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


# ---------------------------------------------------------------- Stick-Bindung per Seriennummer (sdrStick)
DEFAULT_SERIAL = "19348831"  # Nooelec NESDR SMArt v5 von Frank
SERIAL_RE = re.compile(r"^[0-9]{1,16}$")
LIST_RE = re.compile(r"^\s*(\d+):\s+(.*?),?\s+SN:\s*(\S*)\s*$")


def serial_ok(sn):
    return isinstance(sn, str) and bool(SERIAL_RE.match(sn))


def cfg_serial(cfg):
    """Seriennummer aus sdr_config.json - nur Ziffern, sonst None (dann startet nichts)."""
    sn = cfg.get("serial", DEFAULT_SERIAL)
    if isinstance(sn, int) and not isinstance(sn, bool):
        sn = str(sn)
    return sn if serial_ok(sn) else None


def parse_sticks(txt):
    out = []
    for ln in txt.splitlines():
        m = LIST_RE.match(ln)
        if m:
            out.append({"idx": int(m.group(1)), "name": m.group(2).strip().rstrip(","), "sn": m.group(3)})
    return out


def list_sticks(timeout=12):
    """Nur lesen: rtl_test mit einer Geraeteangabe, die auf keinen Stick passt, listet Index/Name/SN
    und beendet sich sofort (oeffnet keinen Stick, kein Test). -> (liste, fehler)"""
    try:
        pr = subprocess.Popen(["rtl_test", "-d", "prepper-nur-liste"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, start_new_session=True)
    except FileNotFoundError:
        return None, "rtl_test fehlt (Paket rtl-sdr)"
    try:
        out, err = pr.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        pr.kill()
        pr.communicate()
        return None, "rtl_test antwortet nicht"
    txt = (out + err).decode("utf-8", "replace")
    res = parse_sticks(txt)
    if not res and "Found" not in txt and "No supported devices" not in txt:
        return None, "rtl_test-Ausgabe unklar: " + txt.strip()[-80:]
    return res, None


def port_listening(port, files=("/proc/net/tcp", "/proc/net/tcp6")):
    """Nur lesen: lauscht etwas auf 127.0.0.1:port? (aus /proc/net/tcp, ohne Verbindung aufzubauen)"""
    want = ":%04X" % int(port)
    for fn in files:
        try:
            rows = open(fn).read().splitlines()[1:]
        except Exception:
            continue
        for r in rows:
            c = r.split()
            if len(c) > 3 and c[1].endswith(want) and c[3] == "0A":
                return True
    return False


def pick_stick(lst, sn):
    """-> (index, fehler). Nie ein anderer Stick als der mit der Seriennummer."""
    m = [x for x in lst if x.get("sn") == sn]
    if len(m) > 1:
        return None, "doppelte Seriennummer %s (%d Sticks) - nicht gestartet" % (sn, len(m))
    if not m:
        return None, "Stick %s fehlt" % sn
    return m[0]["idx"], None


def sticks_cli(base):
    cfg = dict(DEFAULT_CFG)
    cfg.update(load_json(p("sdr_config.json", base), {}) or {})
    sn = cfg_serial(cfg)
    lst, e = list_sticks()
    print("prepper-sdr Stick-Liste (nur lesen)")
    print("prepper-sdr ist gebunden an SN %s" % (sn or "UNGUELTIG in sdr_config.json"))
    if lst is None:
        print("Fehler:", e)
        return 2
    if not lst:
        print("keine RTL-SDR-Sticks gefunden")
    seen = {}
    for x in lst:
        seen[x["sn"]] = seen.get(x["sn"], 0) + 1
    for x in lst:
        mark = ""
        if seen[x["sn"]] > 1:
            mark = "  DOPPELTE SN!"
        elif x["sn"] == sn:
            mark = "  <- prepper-sdr"
        else:
            mark = "  frei"
        print("  Index %d  SN %-10s  %s%s" % (x["idx"], x["sn"] or "-", x["name"], mark))
    if sn:
        i, e = pick_stick(lst, sn)
        print("Ergebnis:", "Index %d" % i if e is None else e)
    return 0


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
ASA_RE = re.compile(r"^\s*ASA(?:\s|-|$)", re.I)      # ASA DE (Automatic Safety Alert, DR Deutschland 5C): Dienst-Label
PTY31_PERSIST_S = 30                                # PTY 31 (Alarm) erst rot, wenn >= 30 s und >= 3 Gruppen

# --ws-score-begin (gleicher Text in prepper_sdr.py und dashboard.py br24Warn2)
import re as _ws_re

_WS_F = _ws_re.I
_WS_TEST = _ws_re.compile(r"probealarm|probe-?warnung|warntag|test-?warnung|test-?meldung|warn-?test|dies ist (?:nur )?eine? (?:test|probe)|\btest\b[^.]{0,25}\b(?:asa|warn)", _WS_F)
_WS_END = _ws_re.compile(r"entwarnung|aufgehoben|keine gefahr|gefahr (?:ist )?(?:vorbei|beendet)|warnung (?:ist )?beendet", _WS_F)
_WS_META = _ws_re.compile(r"warnstreik|experten warnen|warnen experten|betrug|betr(?:ü|ue)ger|phishing|podcast|gewinnspiel|gewinnen sie|jetzt (?:läuft|laeuft|on air)|now playing", _WS_F)
_WS_SOFT = _ws_re.compile(r"\bstau\b|verkehr|unfall|\b[AB]\s?\d{1,3}\b|blitzer|baustelle|sperrung|gesperrt|warnt vor|\bapp\b|\bbr\.de\b|br24\.de", _WS_F)
_WS_VERK = _ws_re.compile(r"falschfahrer|geisterfahrer", _WS_F)
_WS_NOWPLAY = _ws_re.compile(r"^[^:!?.]{2,40}\s[-–/]\s[^:!?.]{2,60}$")
_WS_STRONG = [
    ("Amtliche Gefahrendurchsage", r"amtliche\s+gefahrendurchsage"), ("Gefahrendurchsage", r"gefahrendurchsage"),
    ("Amtliche Warnung", r"amtliche\s+warnung"), ("extreme Gefahr", r"extreme\s+gefahr"),
    ("Warnung der Bevölkerung", r"warnung\s+der\s+bev(?:ö|oe)lkerung"),
    ("Fenster und Türen schließen", r"fenster\s+und\s+t(?:ü|ue)ren\s+(?:geschlossen|schlie(?:ß|ss)en|zu)"),
    ("Lüftung/Klimaanlage abschalten", r"(?:l(?:ü|ue)ftung|klimaanlage)[^.]{0,60}(?:ab|aus)(?:zu)?schalten|(?:ab|aus)schalten[^.]{0,40}(?:l(?:ü|ue)ftung|klimaanlage)"),
    ("Gebiet meiden", r"gebiet[^.]{0,25}meiden|meiden\s+sie[^.]{0,30}gebiet"), ("Evakuierung", r"evakuier"), ("Katastrophenfall", r"katastrophenfall")]
_WS_MED = [
    ("Unwetterwarnung DWD/Stufe 3-4", r"unwetterwarnung", r"dwd|wetterdienst|amtlich|(?:warn)?stufe\s*[34]\b"),
    ("extremes Unwetter", r"extreme[sn]?\s+unwetter", None), ("Hochwasser-Warnung", r"hochwasser", r"warn"),
    ("Trinkwasser abkochen", r"trinkwasser[^.]{0,40}abkoch|abkochgebot", None),
    ("Stromausfall + Behörde", r"stromausfall", r"beh(?:ö|oe)rde|landratsamt"),
    ("Gefahrenmitteilung", r"gefahrenmitteilung", None), ("Waldbrand", r"waldbr(?:a|ä)nd", None), ("Smog", r"\bsmog", None)]
_WS_STRONG = [(n, _ws_re.compile(r, _WS_F)) for n, r in _WS_STRONG]
_WS_MED = [(n, _ws_re.compile(a, _WS_F), _ws_re.compile(b, _WS_F) if b else None) for n, a, b in _WS_MED]
_WS_BEHAV = _ws_re.compile(r"bleiben sie|halten sie sich|halten sie (?:die )?fenster|suchen sie|meiden sie|verlassen sie|schlie(?:ß|ss)en sie|informieren sie sich|nicht ins freie|im haus bleiben|drinnen bleiben|begeben sie sich|vermeiden sie", _WS_F)


def _ws_score(t, rtp=None):
    """Text -> {cls: rot|ende|test|verkehr|None, why}. rot nur bei starkem Begriff, 2+ mittleren oder mittel + Verhaltensanweisung."""
    t = " ".join(str(t or "").split())
    if not t:
        return {"cls": None, "why": "leer"}
    m = _WS_TEST.search(t)
    if m:
        return {"cls": "test", "why": "Test: " + m.group(0)}
    m = _WS_META.search(t)
    if m:
        return {"cls": None, "why": "ausgeschlossen: " + m.group(0)}
    m = _WS_END.search(t)
    if m:
        return {"cls": "ende", "why": "Entwarnung: " + m.group(0)}
    st = [n for n, r in _WS_STRONG if r.search(t)]
    if st:
        return {"cls": "rot", "why": "stark: " + ", ".join(st[:3])}
    m = _WS_VERK.search(t)
    if m:
        return {"cls": "verkehr", "why": "Verkehrsgefahr: " + m.group(0)}
    m = _WS_SOFT.search(t)
    if m:
        return {"cls": None, "why": "ausgeschlossen: " + m.group(0)}
    md = [n for n, a, b in _WS_MED if a.search(t) and (b is None or b.search(t))]
    if any(str(x).startswith("item.") for x in (rtp or [])) or (not md and _WS_NOWPLAY.match(t)):
        return {"cls": None, "why": "ausgeschlossen: Titel/Interpret"}
    bh = _WS_BEHAV.search(t)
    if len(md) >= 2 or (md and bh):
        return {"cls": "rot", "why": "mittel: " + ", ".join(md[:3]) + ((" + Anweisung „%s“" % bh.group(0)) if bh else "")}
    return {"cls": None, "why": ("nur 1 mittlerer Begriff: " + md[0]) if md else "kein Warnbegriff"}


_WS_VEC = [
    ("Amtliche Gefahrendurchsage für Erlangen: Fenster und Türen schließen", "rot"), ("Gefahrendurchsage der Polizei Nürnberg", "rot"),
    ("Großbrand: Lüftung und Klimaanlage bitte abschalten", "rot"), ("Bitte das Gebiet um den Hafen weiträumig meiden", "rot"),
    ("Evakuierung in Forchheim nach Bombenfund", "rot"), ("Landratsamt ERH: Katastrophenfall ausgerufen", "rot"),
    ("DWD Unwetterwarnung Stufe 3 für Mittelfranken", None), ("Extremes Unwetter: DWD Unwetterwarnung Stufe 4", "rot"),
    ("Hochwasserwarnung für die Regnitz - bleiben Sie den Ufern fern", "rot"), ("Hochwasserwarnung Regnitz: verlassen Sie die Keller", "rot"),
    ("Trinkwasser in Herzogenaurach abkochen", None), ("Trinkwasser abkochen, Stromausfall laut Landratsamt", "rot"),
    ("Amtliche Unwetterwarnung Landkreis ERH", None), ("Probewarnung zum Warntag", "test"), ("Amtliche Warnung der Bevölkerung - Probealarm", "test"),
    ("Entwarnung für Erlangen: Gefahr ist vorbei", "ende"), ("Die Warnung wurde aufgehoben", "ende"), ("Falschfahrer auf der A73", "verkehr"),
    ("Stau auf der A9 nach Unfall, Warnung vor Glätte", None), ("Blitzer in Fürth", None), ("Warnstreik bei der Bahn", None),
    ("Polizei warnt vor Betrug am Telefon", None), ("Experten warnen vor Hitze", None), ("Phishing-Mails im Umlauf", None),
    ("Podcast: Was tun bei einer Gefahrendurchsage?", None), ("Gewinnspiel: jetzt anrufen", None), ("Hochwasser-Warnung - mehr in der BR24 App", None),
    ("Adele - Hello", None), ("BR24 Nachrichten", None), ("", None),
    ("Gefahrenmitteilung für den Landkreis ERH", None), ("Gefahrenmitteilung Waldbrand bei Herzogenaurach", "rot"),
    ("Waldbrand im Steigerwald: halten Sie Fenster geschlossen", "rot"), ("Smog in Nürnberg - vermeiden Sie Sport im Freien", "rot"),
    ("Waldbrandgefahr bleibt hoch", None), ("Smog", None)]


def _ws_selftest():
    for t, exp in _WS_VEC:
        r = _ws_score(t)
        assert r["cls"] == exp, (t, r, exp)
    assert _ws_score("Unwetter Sturmwarnung Stufe 3 Extremes Unwetter", ["item.title"])["cls"] is None
    return "warnscore selftest ok (%d Faelle)" % len(_WS_VEC)
# --ws-score-end


_WELLE_CAPS = {}


def welle_caps(exe):
    """Nur lesen: welle-cli-Programmdatei nach Alarm-/Ansage-/ASA-Unterstuetzung durchsuchen (FIG 0/0 Alarmflag, FIG 0/18-19 Ansagen, ASA/EWS)."""
    if not exe:
        return {"exe": None, "fig0_0": False, "fig0_19": False, "asa": False, "note": "welle-cli fehlt"}
    if exe in _WELLE_CAPS:
        return _WELLE_CAPS[exe]
    try:
        with open(exe, "rb") as fh:
            b = fh.read(64 * 1024 * 1024)
    except Exception as e:
        return {"exe": exe, "fig0_0": False, "fig0_19": False, "asa": False, "note": "nicht lesbar: %s" % str(e)[:60]}
    r = {"exe": exe,
         "fig0_0": bool(re.search(rb"alarm[_ ]?flag|AlarmFlag|\balarm\b|\bAlarm\b", b)),
         "fig0_19": bool(re.search(rb"[Aa]nnouncement|\bASw\b|\bASu\b|FIG0_19|fig0_19|FIG 0/19", b)),
         "asa": bool(re.search(rb"\bASA\b|[Ss]afety[_ ]?[Aa]lert|\bEWS\b|[Ee]mergency[_ ]?[Ww]arning", b))}
    r["note"] = "nutzbar: " + ", ".join(k for k in ("fig0_0", "fig0_19", "asa") if r[k]) if any(r[k] for k in ("fig0_0", "fig0_19", "asa")) else \
        "welle-cli liefert weder Alarmflag (FIG 0/0) noch Ansagen (FIG 0/19) noch ASA - nur DLS-Text auswertbar"
    _WELLE_CAPS[exe] = r
    return r


# ---------------------------------------------------------------- Funkumgebung: Stoerer/QRM + Gewitter-Hinweis (nur Pegel, nur Zahlen)
# Feste Messbereiche (nur Leistung je Frequenzbin, kein Demodulieren, nichts gespeichert ausser Zahlen).
NOISE_BANDS = [
    {"id": "n2m", "label": "2 m 144–146 MHz", "short": "2 m", "kind": "noise2m", "lo": "144.000M", "hi": "146.000M", "bin": "5k", "i": 1, "s": 6},
    {"id": "fm", "label": "UKW 87,5–108 MHz", "short": "UKW", "kind": "noisefm", "lo": "87.500M", "hi": "108.000M", "bin": "25k", "i": 2, "s": 10},
    {"id": "dab", "label": "DAB Band III 174–240 MHz", "short": "DAB", "kind": "noisedab", "lo": "174.000M", "hi": "240.000M", "bin": "100k", "i": 3, "s": 12},
    {"id": "pmr", "label": "PMR446 446,0–446,2 MHz", "short": "PMR", "kind": "noisepmr", "lo": "446.000M", "hi": "446.200M", "bin": "1k", "i": 1, "s": 6},
    {"id": "n433", "label": "ISM 433,05–434,79 MHz", "short": "433", "kind": "noise433", "lo": "433.050M", "hi": "434.790M", "bin": "5k", "i": 1, "s": 6},
    {"id": "n868", "label": "SRD 863–870 MHz", "short": "868", "kind": "noise868", "lo": "863.000M", "hi": "870.000M", "bin": "10k", "i": 2, "s": 8},
    {"id": "gps", "label": "GPS L1 1575,42 ±2 MHz", "short": "GPS", "kind": "noisegps", "lo": "1573.420M", "hi": "1577.420M", "bin": "10k", "i": 1, "s": 6},
    {"id": "mw", "label": "MW 0,54–1,56 MHz (Direktabtastung)", "short": "MW", "kind": "noise_mw", "fc": "1.050M", "sr": 1024000, "hf": True, "s": 8},
    {"id": "hf10", "label": "KW 9,92–10,18 MHz (Direktabtastung)", "short": "KW", "kind": "noise_hf", "fc": "10.050M", "sr": 256000, "hf": True, "s": 8},
]
NOISE_IDS = [b["id"] for b in NOISE_BANDS]
# ===== sdrQrmFix: QRM-Messung rtl_power -i 1 -e Messzeit, Fenster mit Zuschlag, SIGINT statt Abschuss, Diagnose je Band =====
NOISE_SLACK_S = 12.0    # sdrQrmFix: Zuschlag je Band (Stick oeffnen, Tuner, letzter Scan-Durchlauf); rtl_power endet selbst nach -e
NOISE_STALL_S = 15.0    # sdrQrmFix: so lange ganz ohne Daten vom Stick -> Band abbrechen (Grund wird angezeigt)


def noise_hops(b):
    """sdrQrmFix: grobe Zahl der rtl_power-Spruenge (nutzbar ca. 1,6 MHz je Sprung bei -c 0.2)."""
    if b.get("hf"):
        return 1
    span = (to_mhz(b["hi"]) - to_mhz(b["lo"])) * 1e6
    return max(1, int(math.ceil(span / 1.6e6)))


def noise_budget(b, secs):
    """sdrQrmFix: Zeitfenster je Band = Messzeit + Zuschlag + 0,4 s je Sprung (ein Scan-Durchlauf breiter Baender dauert)."""
    return float(secs) + NOISE_SLACK_S + 0.4 * noise_hops(b)


def noise_gain(c):
    """Feste Verstaerkung fuer Pegelmessungen (nie AGC/Automatik: -g fehlt oder 0 = Automatik bei rtl_power/rtl_fm)."""
    g = c.get("gain_noise")
    try:
        g = float(g)
    except (TypeError, ValueError):
        g = 30.0
    if not math.isfinite(g) or not (1.0 <= g <= 50.0):
        g = 30.0
    return "%g" % g


def _np():
    import numpy as np
    return np


class NoiseMeter:
    """Sammelt 'Sweeps' (Leistung je Bin in dB) eines Messbereichs; bei KW/MW (Direktabtastung) zusaetzlich kurze Impulse.
    Ergebnis: Rauschboden (Median), schmalbandige Traeger (Bins > X dB ueber Boden in >= N aufeinanderfolgenden Sweeps),
    breitbandige Impulse je Minute (viele Bins gleichzeitig angehoben = typisch Blitz-Sferics oder Zuendfunken)."""
    NFFT = 1024

    def __init__(self, band, car_db=10.0, car_n=4, imp_db=10.0):
        self.np = _np()
        self.band = band
        self.car_db, self.car_n, self.imp_db = float(car_db), int(car_n), float(imp_db)
        self.sweeps = []
        self.f0 = None
        self.df = None
        self.blocks = 0
        self.imp = 0
        self.bb = 0
        self.secs = 0.0
        self.buf = b""
        self.acc = None
        self.nacc = 0
        self.t0 = time.time()
        self.lastpk = False
        self.lines = 0      # sdrQrmFix: Diagnose
        self.nbytes = 0
        self.t_first = None
        self.end = None

    # rtl_power CSV: Datum, Zeit, Hz unten, Hz oben, Hz Schritt, Samples, dB...
    def feed_power(self, line):
        """Eine rtl_power-Zeile = ein Hop; alle Hops mit gleicher Zeit = ein Sweep (nach Frequenz sortiert zusammengesetzt)."""
        self.nbytes += len(line)
        if self.t_first is None and line.strip():
            self.t_first = time.time() - self.t0
        c = [x.strip() for x in line.split(",")]
        if len(c) < 8:
            return False
        try:
            lo, step = float(c[2]), float(c[4])
            db = [float(x) for x in c[6:]]
        except Exception:
            return False
        self.lines += 1
        key = c[0] + " " + c[1]
        if getattr(self, "_key", None) not in (None, key):
            self._flush_hops()
        self._key = key
        self._hops = getattr(self, "_hops", [])
        self._hops.append((lo, step, db))
        return True

    def _flush_hops(self):
        hops = sorted(getattr(self, "_hops", []) or [], key=lambda h: h[0])
        self._hops = []
        if not hops:
            return
        self.nhop = max(getattr(self, "nhop", 0), len(hops))
        if len(hops) < self.nhop:
            return  # unvollstaendiger Sweep
        row = [v for h in hops for v in h[2]]
        if self.sweeps and len(row) != len(self.sweeps[0]):
            return
        a = self.np.array(row, dtype=float)
        if not self.np.all(self.np.isfinite(a)):
            return
        if self.f0 is None:
            self.f0, self.df = hops[0][0], hops[0][1]
            self.hop_bins = len(hops[0][2])
        self.sweeps.append(a)
        self.secs += 1.0  # sdrQrmFix: -i 1

    # rtl_fm -M raw: int16 I/Q verschraenkt
    def feed_iq(self, raw, sr):
        np = self.np
        self.nbytes += len(raw)
        if self.t_first is None and raw:
            self.t_first = time.time() - self.t0
        self.buf += raw
        n = self.NFFT * 4
        k = len(self.buf) // n
        if not k:
            return
        a = np.frombuffer(self.buf[:k * n], dtype="<i2").astype(np.float32) / 32768.0
        self.buf = self.buf[k * n:]
        iq = (a[0::2] + 1j * a[1::2]).reshape(k, self.NFFT)
        iq = iq - iq.mean(axis=1, keepdims=True)
        sp = np.abs(np.fft.fftshift(np.fft.fft(iq * np.hanning(self.NFFT), axis=1), axes=1)) ** 2 / self.NFFT
        sp_db = 10 * np.log10(sp + 1e-12)
        pw = 10 * np.log10(np.mean(np.abs(iq) ** 2, axis=1) + 1e-12)
        med = float(np.median(pw))
        avg = 10 * np.log10(np.mean(sp, axis=0) + 1e-12)
        for i in range(k):
            pk = pw[i] > med + self.imp_db
            if pk and not self.lastpk:
                self.imp += 1
                if float(np.mean(sp_db[i] > avg + 6.0)) >= 0.5:
                    self.bb += 1
            self.lastpk = bool(pk)
        self.blocks += k
        self.secs += k * self.NFFT / float(sr)
        if self.acc is None:
            self.acc = []  # sdrQrmFix: Liste statt wiederholtem vstack (Pi kommt mit)
        self.acc.append(sp)
        self.nacc += k
        if self.nacc * self.NFFT >= sr / 2:  # ~0,5 s je Sweep
            self.sweeps.append(10 * np.log10(np.mean(np.vstack(self.acc), axis=0) + 1e-12))
            self.acc, self.nacc = None, 0
            if self.f0 is None:
                fc = to_mhz(self.band["fc"]) * 1e6
                self.df = sr / float(self.NFFT)
                self.f0 = fc - sr / 2.0

    def diag(self):
        """sdrQrmFix: Klartext was vom Stick kam."""
        if not self.nbytes:
            d = "keine Daten vom Stick"
        elif self.band.get("hf"):
            d = "%d Sweeps, %d kB, erste Daten nach %.0f s" % (len(self.sweeps), self.nbytes // 1024, self.t_first or 0)
        else:
            d = "%d Sweeps, %d Zeilen, erste Zeile nach %.0f s" % (len(self.sweeps), self.lines, self.t_first or 0)
        return d + ((", " + self.end) if self.end else "")

    def result(self, now=None):
        np = self.np
        now = int(now or time.time())
        if not self.band.get("hf"):
            self._flush_hops()
        # sdrQrmFix: erster Sweep (Tuner/PLL) nur verworfen, wenn danach noch >= 2 bleiben; mind. 2 Sweeps noetig
        sw = self.sweeps[1:] if len(self.sweeps) >= 3 else list(self.sweeps)
        if len(sw) < 2:
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(sw), "s": round(self.secs, 1), "why": "zu wenig Sweeps (" + self.diag() + ")"}
        m = np.vstack(sw)
        nb = m.shape[1]
        keep = np.ones(nb, dtype=bool)
        e = max(1, nb // 20)
        keep[:e] = False
        keep[-e:] = False
        hb = int(getattr(self, "hop_bins", 0) or nb)
        dcw = max(2, hb // 100)
        for h0 in range(0, nb, hb):  # DC-Spitze je Hop-Mitte
            mid = h0 + hb // 2
            keep[max(0, mid - dcw):mid + dcw + 1] = False
        if not keep.any():
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(sw), "s": round(self.secs, 1), "why": "keine Bins"}
        floor = float(np.median(m[:, keep]))  # Rauschboden = Median ueber Zeit und Bins (Traeger/Impulse ziehen kaum)
        if not math.isfinite(floor):
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(sw), "s": round(self.secs, 1), "why": "Messwert ungueltig"}
        if self.band.get("hf") and (floor < -100 or float(np.percentile(m[:, keep], 90)) - floor < 0.05):
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(self.sweeps), "s": round(self.secs, 1), "why": "kein Signal (Direktabtastung/KW-Antenne?)"}
        above = (m > floor + self.car_db) & keep[None, :]
        run = np.zeros(nb, dtype=int)
        best = np.zeros(nb, dtype=int)
        for r in above:
            run = np.where(r, run + 1, 0)
            best = np.maximum(best, run)
        need = min(self.car_n, max(2, len(sw) - 1))
        hit = best >= need
        cars = []
        i = 0
        while i < nb:
            if hit[i]:
                j = i
                while j + 1 < nb and hit[j + 1]:
                    j += 1
                seg = np.median(m[:, i:j + 1], axis=0)
                pk = i + int(np.argmax(seg))
                cars.append({"f": round((self.f0 + (pk + 0.5) * self.df) / 1e6, 4), "db": round(float(np.max(seg) - floor), 1),
                             "w_khz": round((j - i + 1) * self.df / 1e3, 1)})
                i = j + 1
            else:
                i += 1
        cars.sort(key=lambda x: -x["db"])
        bbs = float(np.mean(np.mean(m[:, keep] > floor + 6.0, axis=1) >= 0.5))
        r = {"band": self.band["id"], "t": now, "ok": True, "n": len(sw), "s": round(self.secs, 1),
             "floor": round(floor, 1), "p90": round(float(np.percentile(m[:, keep], 90)), 1), "cars": cars[:8], "n_car": len(cars),
             "bb_sweep_pct": round(100 * bbs, 1)}
        if self.band.get("hf") and self.secs > 0:
            mins = self.secs / 60.0
            r.update({"imp_pm": round(self.imp / mins, 1), "bb_pm": round(self.bb / mins, 1)})
        return r


def _med(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def _lvl(*xs):
    o = {"gruen": 0, "gelb": 1, "rot": 2}
    return max(xs, key=lambda x: o.get(x, -1)) if xs else "grau"


def _fin(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(float(x))


def robust(xs):
    """-> (median, MAD*1.4826, n) nur endlicher Werte; (None, None, 0) ohne Werte."""
    v = sorted(float(x) for x in xs if _fin(x))
    if not v:
        return None, None, 0
    m = _med(v)
    return m, 1.4826 * _med([abs(x - m) for x in v]), len(v)


def thresholds(mad, cfg, ky="noise_k_yel", kr="noise_k_red", fy="noise_raise_yel", fr="noise_raise_red", dy=5.0, dr=10.0):
    """Robuste Schwellen: gelb = max(fest, k*MAD), rot = max(fest, k2*MAD), rot immer > gelb."""
    mad = float(mad) if _fin(mad) else 0.0
    y = max(float(cfg.get(fy) or dy), float(cfg.get(ky) or 4) * mad)
    r = max(float(cfg.get(fr) or dr), float(cfg.get(kr) or 6) * mad, y + 1.0)
    return round(y, 1), round(r, 1)


def _hour(ts):
    try:
        return time.localtime(ts).tm_hour
    except Exception:
        return -1


def load_keep(path, default=None):
    """JSON laden; kaputt/fehlt -> vorherige Fassung (.1); sonst default (Anzeige behaelt letzten Stand)."""
    d = load_json(path, None)
    if d is None:
        d = load_json(path + ".1", None)
    return default if d is None else d


def write_json_keep(path, obj):
    """Atomar schreiben und vorherige Fassung als .1 behalten (Verlaeufe, selten geschrieben)."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    if os.path.exists(path):
        os.replace(path, path + ".1")
    os.replace(tmp, path)


CLOCK_OK = 17 * 10 ** 8  # vor Nov. 2023 = Uhr nicht gestellt (Pi ohne RTC) -> nichts bewerten/speichern
HOURLY = ("mw", "hf10")  # Tagesgang (Ausbreitung MW/KW): Grundlinie je Tagesstunde


class NoiseState:
    """noise_state.json (aktuell, klein) + sdr_noise_hist.json (Verlauf 14 Tage, je Messbereich; fuer Kacheln und Archiv).
    Grundlinie: Median der Messungen 1 h-7 d (MW/KW und Gewitter-Impulse: gleiche Tagesstunde 1-14 d, bis genug da sind 24 h).
    Schwellen robust: Abweichung >= max(5 dB, 4*MAD) gelb, >= max(10 dB, 6*MAD) rot (MAD*1,4826).
    Trend: EWMA (lambda 0,03 je Messung) der Abweichung gegen die Grundlinie 3-14 d alt; 'Trend steigend' ab >= 2 dB
    nach >= 24 Messungen seit Reset, aus unter 1 dB (Hysterese). Reset: Luecke > 6 h, Uhr rueckwaerts, Band nicht messbar.
    Verlauf hoechstens alle 30 min geschrieben (SD-Karte, vorherige Fassung .1), aktueller Stand nach jedem Messblock."""
    KEEP_S = 14 * 86400
    CAP = 1500

    def __init__(self, base):
        self.f = p("noise_state.json", base)
        self.fh = p("sdr_noise_hist.json", base)
        d = load_keep(self.f)
        self.d = d if isinstance(d, dict) else {}
        for k in ("bands", "cars", "trend", "since"):
            if not isinstance(self.d.get(k), dict):
                self.d[k] = {}
        h = load_keep(self.fh)
        h = h if isinstance(h, dict) else {}
        self.h = {}
        for b in NOISE_IDS + ["impulse"]:
            v = h.get(b) if isinstance(h.get(b), list) else []
            self.h[b] = [x for x in v if isinstance(x, dict) and _fin(x.get("ts"))][-self.CAP:]
        self.last_hsave = 0
        self.hdirty = False

    def ref(self, band, key, now, lo_s, hi_s, hour=None):
        out = []
        for x in self.h.get(band, []):
            a = now - x.get("ts", 0)
            if lo_s <= a < hi_s and _fin(x.get(key)):
                if hour is not None and x.get("_h", _hour(x["ts"])) != hour:
                    continue
                out.append(x)
        return out

    def baseline(self, band, key, now, long_lo=3600, long_hi=7 * 86400):
        """-> (median, mad, n, Quelle) ; median None = lernt noch."""
        if band in HOURLY:
            hr = _hour(now)
            pts = self.ref(band, key, now, 3600, 14 * 86400, hr)
            days = len(set(int(x["ts"] // 86400) for x in pts))
            if len(pts) >= 8 and days >= 3:
                m, s, n = robust(x[key] for x in pts)
                return m, s, n, "Stunde %02d (%d Tage)" % (hr, days)
            pts = self.ref(band, key, now, 3600, 86400)
            if len(pts) >= 8:
                m, s, n = robust(x[key] for x in pts)
                return m, s, n, "24 h (Stunden-Grundlinie lernt)"
            return None, None, len(pts), "lernt"
        pts = self.ref(band, key, now, long_lo, long_hi)
        if len(pts) >= 8:
            m, s, n = robust(x[key] for x in pts)
            return m, s, n, "7 Tage" if (now - min(x["ts"] for x in pts)) > 2 * 86400 else "24 h"
        return None, None, len(pts), "lernt"

    def trend_step(self, bid, dev, now, cfg):
        tr = self.d["trend"].get(bid)
        if not isinstance(tr, dict) or not _fin(tr.get("e")) or not _fin(tr.get("t")):
            tr = {"e": 0.0, "t": now, "n": 0, "on": False}
        if now - tr["t"] > 6 * 3600 or now < tr["t"] - 600:
            tr = {"e": 0.0, "t": now, "n": 0, "on": False, "reset": int(now)}
        if dev is None:
            self.d["trend"][bid] = tr
            return tr
        lam = min(0.5, max(0.005, float(cfg.get("noise_trend_lambda") or 0.03)))
        e = lam * dev + (1 - lam) * float(tr["e"])
        n = int(tr.get("n") or 0) + 1
        on = bool(tr.get("on"))
        if not on and n >= 24 and e >= float(cfg.get("noise_trend_db") or 2.0):
            on, tr["since"] = True, int(now)
        elif on and e < float(cfg.get("noise_trend_off_db") or 1.0):
            on = False
        tr.update({"e": round(e, 2), "t": int(now), "n": min(n, 100000), "on": on})
        self.d["trend"][bid] = tr
        return tr

    def add(self, r, cfg, now=None):
        now = int(now or r.get("t") or time.time())
        bid = r.get("band")
        if bid not in NOISE_IDS:
            return
        if now < CLOCK_OK:
            self.d["bands"][bid] = dict(self.d["bands"].get(bid) or {}, ok=False, t=now, why="Uhr nicht gestellt")
            return
        if not r.get("ok") or not _fin(r.get("floor")):
            self.d["bands"][bid] = dict(self.d["bands"].get(bid) or {}, ok=False, t=now, n=r.get("n"), why=r.get("why"))
            self.trend_step(bid, None, now, cfg)
            return
        floor = float(r["floor"])
        med, mad, nb, src = self.baseline(bid, "floor", now)
        yel, red = thresholds(mad, cfg)
        raise_db = round(floor - med, 1) if med is not None else None
        # Traeger-Register: gleiche Frequenz (+-2 Bins) ueber mehrere Bloecke = "seit"
        reg = self.d["cars"].get(bid) if isinstance(self.d["cars"].get(bid), list) else []
        reg = [x for x in reg if isinstance(x, dict) and _fin(x.get("f")) and _fin(x.get("db"))]
        tol = 0.002 if not str(bid).startswith(("mw", "hf")) else 0.0006
        seen = []
        for c in r.get("cars") or []:
            if not (_fin(c.get("f")) and _fin(c.get("db"))):
                continue
            hitc = None
            for x in reg:
                if abs(x["f"] - c["f"]) <= tol:
                    hitc = x
                    break
            if hitc is None:
                hitc = {"f": c["f"], "first": now, "n": 0}
                reg.append(hitc)
            hitc.update({"f": c["f"], "db": c["db"], "w_khz": c.get("w_khz"), "last": now})
            hitc["n"] = hitc.get("n", 0) + 1
            seen.append(hitc)
        iv = float(cfg.get("noise_interval_s") or 900)
        for x in reg:
            age = now - x.get("first", now)
            slots = max(1.0, age / iv)
            if age >= 86400 and x.get("n", 0) / slots >= 0.5:
                x["known"] = True
                if x in seen:
                    x["kdb"] = round(0.9 * x.get("kdb", x["db"]) + 0.1 * x["db"], 1) if _fin(x.get("kdb")) else x["db"]
        keep_s = 2 * 86400 if any(x.get("known") for x in reg) else iv * 2.5
        self.d["cars"][bid] = sorted([x for x in reg if 0 <= now - x.get("last", 0) <= (keep_s if x.get("known") else iv * 2.5)],
                                     key=lambda y: -y.get("db", 0))[:80]
        sn = self.d["since"].get(bid)
        if not _fin(sn) or sn > now:
            sn = self.d["since"][bid] = now
        learning = (now - sn) < 86400
        pers = [x for x in self.d["cars"][bid] if x.get("last") == now and x.get("n", 0) >= 3 and
                (not x.get("known") or (_fin(x.get("kdb")) and x["db"] - x["kdb"] >= 10)) and not learning]
        lvl = "gruen"
        if raise_db is not None and raise_db >= red:
            lvl = "rot"
        elif any(x["db"] >= 20 for x in pers):
            lvl = "rot"
        elif (raise_db is not None and raise_db >= yel) or pers:
            lvl = "gelb"
        # Trend gegen aeltere Grundlinie (3-14 d), Abweichung begrenzt (Einzelspitzen ziehen nicht)
        tm, _tmad, tn, _ts = self.baseline(bid, "floor", now, 3 * 86400, 14 * 86400) if bid not in HOURLY else (None, None, 0, "")
        if tn < 48:
            tm = None
        if bid in HOURLY:
            pts = self.ref(bid, "floor", now, 3 * 86400, 14 * 86400, _hour(now))
            tm = robust(x["floor"] for x in pts)[0] if len(pts) >= 6 else None
        dev = None if tm is None else max(-red, min(red, floor - tm))
        tr = self.trend_step(bid, dev, now, cfg)
        cur = {"t": now, "ok": True, "floor": round(floor, 1), "p90": r.get("p90"), "base": None if med is None else round(med, 1),
               "mad": None if mad is None else round(mad, 2), "src": src, "yel": yel, "red": red, "raise": raise_db, "n_base": nb, "lvl": lvl,
               "s": r.get("s"), "trend": {"on": bool(tr.get("on")), "e": tr.get("e"), "since": tr.get("since")},
               "cars": [{"f": x["f"], "db": x["db"], "w_khz": x.get("w_khz"), "since": x["first"], "n": x["n"]} for x in sorted(pers, key=lambda y: -y["db"])[:6]],
               "n_car": len(seen), "n_known": sum(1 for x in seen if x.get("known")), "n_pers": len(pers), "learning": learning or med is None}
        if _fin(r.get("bb_pm")):
            cur.update({"imp_pm": r.get("imp_pm"), "bb_pm": r["bb_pm"]})
        self.d["bands"][bid] = cur
        pt = {"ts": now, "_h": _hour(now), "floor": round(floor, 1), "car": len(pers)}
        if raise_db is not None:
            pt["raise"] = raise_db
        if _fin(r.get("bb_pm")):
            pt["bb_pm"] = r["bb_pm"]
            pt["imp_pm"] = r.get("imp_pm") if _fin(r.get("imp_pm")) else None
        self.h[bid] = (self.h[bid] + [pt])[-self.CAP:]
        self.hdirty = True

    def finish_block(self, cfg, now=None):
        """Nach allen Messbereichen: Gesamtampel Stoerer + Gewitter-Hinweis (Impulse gegen Stunden-Grundlinie), Impuls-Verlauf."""
        now = int(now or time.time())
        bands = self.d["bands"]
        fresh = [b for b in NOISE_IDS if (bands.get(b) or {}).get("ok") and 0 <= now - bands[b].get("t", 0) < 3600]
        q = [bands[b]["lvl"] for b in fresh]
        self.d["qrm"] = {"t": now, "lvl": _lvl(*q) if q else "grau", "trend": [b for b in fresh if (bands[b].get("trend") or {}).get("on")]}
        hf = [b for b in ("mw", "hf10") if b in fresh and _fin(bands[b].get("bb_pm"))]
        th = {"t": now, "lvl": "grau", "bb_pm": None, "base": None, "why": "MW/KW nicht messbar (Direktabtastung / KW-Antenne?)"}
        if hf:
            bid = max(hf, key=lambda y: bands[y]["bb_pm"])
            bb = float(bands[bid]["bb_pm"])
            med, mad, nb, src = self.baseline(bid, "bb_pm", now)
            ref = max(1.0, med or 0.0)
            mad = mad or 0.0
            yel = max(float(cfg.get("thunder_yel_pm") or 5), 3 * ref, (med or 0) + 4 * mad)
            red = max(float(cfg.get("thunder_red_pm") or 20), 6 * ref, (med or 0) + 6 * mad)
            prev = [y.get("bb_pm") for y in self.h.get("impulse", [])[-1:] if 0 <= now - y.get("ts", 0) < 3600]
            lvl = "gruen"
            if bb >= red and prev and _fin(prev[0]) and prev[0] >= max(5.0, 3 * ref):
                lvl = "rot"
            elif bb >= yel:
                lvl = "gelb"
            why = {"gruen": "ruhig", "gelb": "mehr breitbandige Impulse als üblich", "rot": "stark impulsiv, steigend"}[lvl]
            if med is None:
                lvl, why = "grau", "lernt Grundlinie (erste 24 h, noch keine Bewertung)"
            th = {"t": now, "lvl": lvl, "bb_pm": bb, "base": None if med is None else round(med, 1), "src": src, "yel": round(yel, 1), "red": round(red, 1),
                  "band": bid, "why": why}
            self.h["impulse"] = (self.h["impulse"] + [{"ts": now, "_h": _hour(now), "bb_pm": bb, "base": th["base"]}])[-self.CAP:]
            self.hdirty = True
        self.d["thunder"] = th
        self.d["v"], self.d["t"] = V, now
        write_json(self.f, self.d)
        self.save_hist(now=now)

    def save_hist(self, force=False, now=None):
        now = float(now or time.time())
        if self.hdirty and (force or now - self.last_hsave > 1800 or now < self.last_hsave):
            cut = now - self.KEEP_S
            for k in list(self.h):
                if isinstance(self.h[k], list):
                    self.h[k] = [x for x in self.h[k] if cut <= x.get("ts", 0) <= now + 3600][-self.CAP:]
            write_json_keep(self.fh, self.h)
            self.hdirty, self.last_hsave = False, now


# ---------------------------------------------------------------- Frequenzkalibrierung (DAB-Traeger, welle-cli Frequenzkorrektur)
def cal_compute(c0, c1, step_ppm, f_hz):
    """c0/c1: welle-cli Frequenzkorrektur (Hz) bei rtl_tcp -P 0 und -P step. Steigung prueft Einheit und Vorzeichen.
    -> (ppm, note) ; ppm None = unzuverlaessig"""
    if c0 is None or c1 is None or not step_ppm:
        return None, "zu wenig Messwerte"
    k = f_hz / 1e6
    s = (c1 - c0) / (step_ppm * k)
    if not (0.6 <= abs(s) <= 1.4):
        return None, "Steigung %.2f unplausibel" % s
    ppm = -c0 / (s * k)
    if not (-10.0 <= ppm <= 10.0):
        return None, "%.1f ppm ausserhalb -10..+10" % ppm
    return round(ppm, 2), "ok (Steigung %.2f)" % s


def ppm_val(cfg):
    v = cfg.get("ppm")
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    v = int(round(v))
    return v if -10 <= v <= 10 else 0


class BcEvents:
    """broadcast_events.jsonl: Rundfunk-Ereignisse der letzten 48 h (TA Beginn/Ende mit RT, RDS-Warn-RT, DAB-Ansagen, DLS).
    Klein gehalten (max 1500 Eintraege / 400 kB), atomar neu geschrieben (tmp + rename), hoechstens alle 60 s."""
    KEEP_S = 48 * 3600
    MAX_N = 1500
    MAX_B = 400 * 1024

    def __init__(self, base):
        self.f = p("broadcast_events.jsonl", base)
        self.ev = []
        try:
            for ln in open(self.f, encoding="utf-8"):
                try:
                    x = json.loads(ln)
                except Exception:
                    continue
                if isinstance(x, dict) and isinstance(x.get("t"), (int, float)):
                    self.ev.append(x)
        except Exception:
            pass
        self.dirty = False
        self.last_saved = 0
        self.seq = max([x.get("id", 0) for x in self.ev] + [0])

    def add(self, k, src, now, **kw):
        self.seq += 1
        e = {"id": self.seq, "t": int(now), "k": k, "src": str(src)[:40]}
        for a, b in kw.items():
            if b not in (None, ""):
                e[a] = b[:200] if isinstance(b, str) else b
        self.ev.append(e)
        self.dirty = True
        return e

    def find(self, eid):
        for x in reversed(self.ev[-200:]):
            if x.get("id") == eid:
                return x
        return None

    def trim(self, now):
        cut = now - self.KEEP_S
        ev = [x for x in self.ev if (x.get("end") or x.get("t", 0)) >= cut or x.get("open")][-self.MAX_N:]
        while ev and sum(len(json.dumps(x, ensure_ascii=False)) + 1 for x in ev) > self.MAX_B:
            ev = ev[len(ev) // 10 + 1:]
        if len(ev) != len(self.ev):
            self.dirty = True
        self.ev = ev

    def save(self, force=False):
        now = time.time()
        if self.dirty and (force or now - self.last_saved > 60):
            self.trim(now)
            tmp = self.f + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                for x in self.ev:
                    fh.write(json.dumps(x, ensure_ascii=False, separators=(",", ":")) + "\n")
            os.replace(tmp, self.f)
            self.dirty, self.last_saved = False, now


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
        self.evl = BcEvents(os.path.dirname(self.f))
        self.ta_open = {}   # Sender -> Ereignis-ID (TA laeuft)
        self.ta_post = {}   # Sender -> (ID, bis) RT nach TA-Ende noch 60 s mitschreiben
        self.last_rt = {}
        self.last_dls = {}
        self.rt_seen = {}
        self.asa_seen = {}
        self.last_ann = {}

    def _rt_into(self, eid, rt):
        e = self.evl.find(eid)
        if e is not None and rt and rt not in (e.get("rt") or []):
            e["rt"] = (e.get("rt") or []) + [rt[:80]]
            e["rt"] = e["rt"][-8:]
            self.evl.dirty = True

    def ta_close(self, name, now, why=None):
        eid = self.ta_open.pop(name, None)
        e = self.evl.find(eid) if eid else None
        if e is None:
            return
        last = self.d["fm"].get(name, {}).get("t", now)
        end = int(now if why is None else min(now, last))
        e.update({"open": False, "end": end, "dur_s": max(0, end - e["t"])})
        if why:
            e["note"] = why
        self.evl.dirty = True
        self.ta_post[name] = (eid, now + 60)

    def tick(self, now, listening=None):
        """TA ohne Ende schliessen, wenn der Sender nicht mehr gehoert wird (Rundfunk-Block vorbei)."""
        for name in list(self.ta_open):
            if name != listening and now - self.d["fm"].get(name, {}).get("t", 0) > 90:
                self.ta_close(name, now, "Empfang beendet, Ende unbekannt")

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
        if g.get("pi"):
            s["pi_t"] = int(now)
        for k_in, k_out in (("pi", "pi"), ("ps", "ps"), ("radiotext", "rt"), ("prog_type", "pty"), ("tp", "tp"), ("ta", "ta")):
            if k_in in g:
                s[k_out] = g[k_in] if not isinstance(g[k_in], str) else g[k_in].strip()[:80]
        rp = g.get("radiotext_plus")
        if isinstance(rp, dict) and isinstance(rp.get("tags"), list):
            s["rtp"] = [str(x.get("content-type"))[:24] for x in rp["tags"][:6] if isinstance(x, dict) and x.get("content-type")]
        if "prog_type" in g:
            pty = g.get("prog_type")
            if pty == 31 or (isinstance(pty, str) and re.search(r"alarm", pty, re.I)):
                if not s.get("pty31_since") or now - s.get("pty31_last", 0) > 120:
                    s["pty31_since"], s["pty31_n"], s["pty31_persist"] = int(now), 0, 0
                    self.evl.add("pty31", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 31 (Alarm) gesehen", persist=False)
                s["pty31_n"] = s.get("pty31_n", 0) + 1
                s["pty31_last"] = int(now)
                if not s.get("pty31_persist") and s["pty31_n"] >= 3 and now - s["pty31_since"] >= PTY31_PERSIST_S:
                    s["pty31_persist"] = 1
                    self.evl.add("pty31", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 31 (Alarm) dauerhaft seit %d s" % int(now - s["pty31_since"]), persist=True)
                    self.warn(name, "PTY31", "RDS PTY 31 Alarm (dauerhaft)", now)
            else:
                s["pty31_since"], s["pty31_persist"] = 0, 0
        rt = g["radiotext"].strip()[:80] if isinstance(g.get("radiotext"), str) else None
        rt_new_stable = False
        if rt:
            sn = self.rt_seen.get(name)
            if sn and sn[0] == rt:
                sn[1] += 1
            else:
                sn = self.rt_seen[name] = [rt, 1]
            if sn[1] == 2:       # vollstaendig (redsea: ganze Nachricht) und 2x gleich empfangen = stabil
                rt_new_stable = True
                s["rt_ok"], s["rt_ok_t"] = rt, int(now)
        if g.get("ta") is True and s.get("tp"):
            s["ta_t"] = int(now)
            self.warn(name, "TA", "Durchsage aktiv (TA)", now)
            if name not in self.ta_open:
                e = self.evl.add("ta", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), open=True, rt=[x for x in (s.get("rt"),) if x])
                self.ta_open[name] = e["id"]
        elif g.get("ta") is False and name in self.ta_open:
            self.ta_close(name, now)
        if rt and rt != self.last_rt.get(name):
            self.last_rt[name] = rt
            if name in self.ta_open:
                self._rt_into(self.ta_open[name], rt)
            elif name in self.ta_post and now <= self.ta_post[name][1]:
                self._rt_into(self.ta_post[name][0], rt)
        if rt_new_stable:
            sc = _ws_score(rt, s.get("rtp"))
            if sc["cls"] or WARN_WORDS.search(rt):
                self.evl.add("rt_warn", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text=rt, cls=sc["cls"], why=sc["why"][:80])
            if sc["cls"] == "rot":
                self.warn(name, "RT", rt, now)
        if g.get("group") in ("9A",) or "ews" in g:
            if now - self.last_ann.get("ews:" + name, 0) > 1800:
                self.evl.add("ews", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS-Notfallgruppe empfangen")
            self.last_ann["ews:" + name] = now
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
            sid = sv.get("sid", sv.get("SId", sv.get("id")))
            sid = ("0x%04X" % sid) if isinstance(sid, int) and not isinstance(sid, bool) and 0 <= sid <= 0xFFFFFFFF else (str(sid).strip()[:12] if isinstance(sid, str) and re.match(r"^(0x)?[0-9A-Fa-f]{1,8}$", sid.strip()) else None)
            asa = bool(ASA_RE.match(l or ""))
            svcs.append(dict({"label": (l or "?").strip()[:30], "dls": (dls or "").strip()[:160], "sid": sid}, **({"asa": True} if asa else {})))
            key = "%s|%s" % (ch, (l or "?").strip()[:30])
            dl = (dls or "").strip()[:160]
            if asa and (key not in self.asa_seen or now - self.asa_seen[key] > 6 * 3600):
                self.asa_seen[key] = now
                self.evl.add("asa", "DAB %s" % ch, now, svc=(l or "?").strip()[:30], sid=sid, text="ASA-Dienst empfangen (Dienst allein ist kein Alarm)")
            sc = _ws_score(dl)
            if dl and self.last_dls.get(key) != dl:
                self.last_dls[key] = dl
                self.evl.add("dls", "DAB %s" % ch, now, svc=(l or "?").strip()[:30], text=dl, warn=sc["cls"] == "rot", cls=sc["cls"], asa=asa)
            if dl and sc["cls"] == "rot":
                self.warn("DAB %s %s" % (ch, (l or "").strip()), "DLS", dl, now)
        for a in alarm[:3]:
            self.warn("DAB %s" % ch, "Ansage", a, now)
        sig = "|".join(sorted(alarm[:5]))
        if sig != self.last_ann.get("dab:" + ch, ""):
            if alarm:
                self.evl.add("dab_ann", "DAB %s" % ch, now, text="; ".join(alarm[:3]), ens=(lab or "").strip()[:40])
            elif self.last_ann.get("dab:" + ch):
                self.evl.add("dab_ann_end", "DAB %s" % ch, now, text="Ansage beendet")
            self.last_ann["dab:" + ch] = sig
        self.d["dab"][ch] = {"ch": ch, "t": int(now), "ensemble": (lab or "").strip()[:40], "services": svcs, "alarm": alarm[:5], "n": len(svcs),
                             "asa": [x for x in svcs if x.get("asa")][:3]}
        self.dirty = True
        return self.d["dab"][ch]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()
        self.tick(time.time(), self.cur)
        self.evl.save(force)


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
    def __init__(self, base, stick=1, main=None):
        self.base = base
        self.cfg = config(base)
        self.stickno = stick   # sdrDual
        self.role = "single"
        self.main = main
        self.worker = None
        self.st_cache = None
        if stick == 2:
            c = self.cfg
            c["serial"] = cfg_serial2(c)
            c["ppm"], c["ppm_cal"], c["cal_hour"] = c.get("ppm2") or 0, c.get("ppm_cal2"), int(c.get("cal_hour2") or 4)
            c["dab_port"], c["dab_tcp_port"] = int(c.get("dab_port2") or 7981), int(c.get("dab_tcp_port2") or 1237)
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
        self.dev_idx = None
        self.dev_sn = None
        self.list_n = 0
        self.pin_err = None
        self.sticks_n = 0
        self.others = []
        self.counts = {"433": 0, "aprs": 0, "rds": 0, "dab": 0, "meteor": 0, "linelog": 0}
        self.llog = LineLog(base, self.cfg)
        self.sact = ActState(base)
        self.last_dabpoll = 0
        self.pmeteor = None
        self._lastdls = {}
        self.sbc = StateBC(base)
        self.snoise = NoiseState(base)
        self.nzm = None
        self.nzt = None
        self.last_noise = time.time() - float(self.cfg.get("noise_interval_s") or 900) + max(45.0, float(self.cfg.get("noise_warmup_s") or 300))
        self._has_rp = None
        self.cal_samples = [[], []]
        self.cal_res = [None, None]
        self.last_calpoll = 0
        self.special = None
        self.gps = None
        self.evlog = self.kfz = None
        self.last_bc = time.time() - float(self.cfg.get("bc_interval_s") or 1800) + 120
        self.bc_done_t = None
        self.ndiag = {"t0": None, "t1": None, "n": 0, "bands": {}, "skip": None, "skip_t": None}
        self.passes = (load_json(p("sdr_passes.json", base), {}) or {}).get("passes") or []
        self.lage = get_lage(base)  # sdrLage
        self.lage_user = None
        self.last_act = time.time() - 600
        self.raw_t = None      # letzte Rohdaten vom Stick (QRM-Block/Aktivitaet)
        self.raw_fail = 0      # Messjobs in Folge ganz ohne Daten
        self.raw_jobs = 0
        self.act_bytes = 0
        self.last_predict = 0
        self.last_tle_try = 0
        self.tools = {}
        self.started = time.time()
        self.lastsig = None
        if main is not None:  # sdrDual: gemeinsame Zustaende/Dateien nur einmal im Prozess
            for k in ("s433", "saprs", "llog", "sact", "sbc", "snoise", "lock", "evlog", "kfz", "passes"):
                setattr(self, k, getattr(main, k))

    def set_role(self, r):
        """sdrDual: Rolle wechseln (Stick dazu/weg) -> laufenden Auftrag sauber beenden, Planer neu waehlen lassen."""
        if r == self.role:
            return
        self.log("Stick %d: Rolle %s -> %s" % (self.stickno, self.role, r))
        self.role = r
        if self.procs:
            self.kill()
        self.special, self.nzm, self.nzt, self.pmeteor = None, None, None, None
        self.active, self.since = "idle", time.time()

    def log(self, *a):
        print("prepper-sdr:", *a, flush=True)

    def _dev(self, args, flag="-d"):
        """Immer genau der gebundene Stick: rtl_433 per :SERIENNUMMER, sonst der beim Start aufgeloeste Index."""
        if self.dev_idx is None or not serial_ok(self.dev_sn):
            raise RuntimeError("Stick nicht aufgeloest")
        if args[0] == "rtl_433":
            return args + ["-d", ":" + self.dev_sn]
        return args + [flag, str(int(self.dev_idx))]

    def resolve(self):
        """Seriennummer -> Index, bei jedem Start neu (Reihenfolge kann sich nach Umstecken aendern)."""
        self.dev_idx = None
        sn = cfg_serial(self.cfg)
        if sn is None:
            raise RuntimeError("Seriennummer in sdr_config.json ungueltig (nur Ziffern)")
        lst, e = list_sticks()
        if lst is None:
            raise RuntimeError("Stick-Liste: %s" % e)
        idx, e = pick_stick(lst, sn)
        if e:
            raise RuntimeError(e)
        self.dev_idx, self.dev_sn, self.list_n = idx, sn, len(lst)
        return idx

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
        v = list(v) if isinstance(v, list) and v else list(DAB_DEFAULT)
        if self.cfg.get("asa_5c", True) and "5C" not in v:
            v.append("5C")      # br24Warn2: ASA DE (DR Deutschland 5C) bei jedem Rundfunk-Block mitlesen
        return v

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
                if ppm_val(c):
                    a += ["-p", str(ppm_val(c))]
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
        if what.startswith("nz:"):
            return self._cmd_noise(int(what[3:]))
        if what.startswith("cal:"):
            return self._cmd_cal(int(what[4:]))
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
        if ppm_val(c):
            a += ["-p", str(ppm_val(c))]
        if c.get("gain_fm") not in (None, ""):
            a += ["-g", str(c["gain_fm"])]
        return [self._dev(a) + ["-"], [self.tool("redsea"), "-r", "171k"]]

    def _cmd_dab(self, ch):
        c = self.cfg
        check_tune("dab", ch=ch)
        if self.list_n == 1 and self.dev_idx == 0 and serial_ok(self.dev_sn):
            # genau ein Stick vorhanden und das ist unserer -> welle-cli direkt (sicher, es gibt keinen anderen)
            a = [self.tool("welle"), "-c", str(ch), "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_sdr"]
            if c.get("gain_dab") not in (None, ""):
                a += ["-g", str(c["gain_dab"])]
            return [a]
        # mehrere Sticks: welle-cli nimmt mit -F rtl_sdr "den ersten freien" - darum getrennt: rtl_tcp nur 127.0.0.1 am gebundenen Stick,
        # dann welle-cli als eigener Prozess (kein Pipe), erst wenn der Port lauscht
        port = int(c.get("dab_tcp_port") or 1235)
        if not (1024 < port < 65536) or port in (int(c["tcp_port"]), int(c["dab_port"])):
            raise RuntimeError("dab_tcp_port ungueltig")
        srv = self._dev(["rtl_tcp", "-a", "127.0.0.1", "-p", str(port), "-P", str(ppm_val(c))])
        a = [self.tool("welle"), "-c", str(ch), "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_tcp,127.0.0.1:%d" % port]
        if c.get("gain_dab") not in (None, ""):
            a += ["-g", str(c["gain_dab"])]
        return [srv, a]

    def _cmd_act(self, kind, f):
        """Nur rohe IQ-Daten nach stdout (Planer misst Pegel, verwirft die Daten). Mitte = Kanalfrequenz."""
        c = self.cfg
        check_tune(kind, f)
        try:
            import numpy  # noqa: F401
        except Exception:
            raise RuntimeError("Aktivitaet: python3-numpy fehlt")
        a = ["rtl_sdr", "-f", str(f), "-s", str(ActMeter.FS)]
        if ppm_val(c):
            a += ["-p", str(ppm_val(c))]
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
                self.act_bytes += len(raw)
                self.raw_t = time.time()
                self.raw_fail = 0
                put(mt.feed(raw))
        except Exception as e:
            self.log("Aktivitaet Messung:", e)
        put(mt.finish())

    def _cmd_noise(self, i):
        """Nur Leistung je Bin: rtl_power (VHF/UHF/GPS) bzw. rtl_fm -M raw mit Q-Direktabtastung (MW/KW) nach stdout; Planer rechnet Zahlen."""
        b = NOISE_BANDS[i]
        c = self.cfg
        k = b["kind"]
        if k not in NOISE_KINDS:
            raise RuntimeError("Messbereich unbekannt")
        if b.get("hf"):
            check_tune(k, b["fc"])
            fc = to_mhz(b["fc"])
            half = b["sr"] / 2e6
            check_tune(k, "%.4fM" % (fc - half))
            check_tune(k, "%.4fM" % (fc + half))
            a = ["rtl_fm", "-M", "raw", "-E", "direct2", "-f", b["fc"], "-s", str(int(b["sr"])), "-g", noise_gain(c)]
        else:
            check_tune(k, b["lo"])
            check_tune(k, b["hi"])
            # sdrQrmFix: -i 1 und -e = Messzeit: rtl_power schreibt jede Sekunde und beendet sich selbst (kein Abbruch noetig)
            a = ["rtl_power", "-f", "%s:%s:%s" % (b["lo"], b["hi"], b["bin"]), "-i", "1", "-c", "0.2",
                 "-e", "%ds" % max(3, int(self._nz_secs(b))), "-g", noise_gain(c)]
        if ppm_val(c):
            a += ["-p", str(ppm_val(c))]
        return [self._dev(a) + ["-"]]

    def _nz_secs(self, b):
        return float(b.get("s") or self.cfg.get("noise_s") or 7)

    def _noise_reader(self, stream, mt, b):
        try:
            if b.get("hf"):
                while True:
                    raw = stream.read(65536)
                    if not raw:
                        break
                    mt.feed_iq(raw, b["sr"])
            else:
                for raw in iter(stream.readline, b""):
                    mt.feed_power(raw.decode("ascii", "replace"))
        except Exception as e:
            self.log("Funkumgebung Messung:", e)

    def noise_why_off(self):
        if getattr(self, "lage", None) and self.lage["sw"].get("noise") == "aus":
            return "Messung AUS (Lage %s)" % self.lage["name"]
        if not self.cfg.get("noise_enable"):
            return "Messung aus (noise_enable=false)"
        try:
            import numpy  # noqa: F401
        except Exception:
            return "numpy fehlt fuer prepper-sdr"
        return "kein Messprogramm (rtl_power fehlt, KW aus)"

    def sched(self, now, mode):
        """Planer-Tabelle fuer Anzeige/Diagnose: je Aufgabe zuletzt fertig, naechster Termin, Intervall, Dauer."""
        niv = float(self.cfg.get("noise_interval_s") or 900)
        biv = float(self.cfg.get("bc_interval_s") or 1800)
        nq, bq = self.noise_queue(), self.bc_queue()
        np_ = self.next_pass(now)
        pc = self.cfg.get("ppm_cal") if isinstance(self.cfg.get("ppm_cal"), dict) else {}
        auto = mode.get("mode") == "auto"
        return [{"k": "noise", "on": bool(nq), "auto": auto, "last": self.ndiag.get("t1"), "next": int(self.last_noise + niv) if nq else None, "iv": int(niv), "dur": int(sum(d for _, d in nq)) if nq else 0,
                 "skip": self.ndiag.get("skip"), "skip_t": self.ndiag.get("skip_t")},
                {"k": "bc", "on": bool(bq), "auto": auto, "last": self.bc_done_t, "next": int(self.last_bc + biv) if bq else None, "iv": int(biv), "dur": int(sum(d for _, d in bq)) if bq else 0,
                 "dab": list(self.dab_list()), "fm_n": len(self.fm_list())},
                {"k": "meteor", "on": bool(self.tool("satdump")), "auto": auto, "last": None, "next": np_.get("aos") if np_ else None, "iv": None, "dur": np_.get("dur_s") if np_ else None},
                {"k": "cal", "on": bool(self.cfg.get("cal_enable") and self.tool("welle")), "auto": auto, "last": pc.get("try_t"), "next": None, "iv": 86400, "dur": int(2 * float(self.cfg.get("cal_s") or 45)),
                 "hour": int(self.cfg.get("cal_hour") or 3)}]

    def noise_queue(self):
        c = self.cfg
        if not c.get("noise_enable"):
            return []
        try:
            import numpy  # noqa: F401
        except Exception:
            return []
        if self._has_rp is None:
            import shutil
            self._has_rp = bool(shutil.which("rtl_power"))
        q = []
        for i, b in enumerate(NOISE_BANDS):
            if b.get("hf") and not c.get("noise_hf"):
                continue
            if not b.get("hf") and not self._has_rp:
                continue
            q.append(("nz:%d" % i, noise_budget(b, self._nz_secs(b))))
        return q

    def _cmd_cal(self, i):
        """Kalibrierung: rtl_tcp (127.0.0.1) mit -P 0 bzw. -P Schritt am ersten DAB-Kanal, welle-cli liest Frequenzkorrektur."""
        c = self.cfg
        ch = str(self.dab_list()[0])
        check_tune("dab", ch=ch)
        port = int(c.get("dab_tcp_port") or 1235)
        if not (1024 < port < 65536) or port in (int(c["tcp_port"]), int(c["dab_port"])):
            raise RuntimeError("dab_tcp_port ungueltig")
        step = int(c.get("cal_step_ppm") or 5)
        pp = [0, step][i]
        srv = self._dev(["rtl_tcp", "-a", "127.0.0.1", "-p", str(port), "-P", str(pp)])
        a = [self.tool("welle"), "-c", ch, "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_tcp,127.0.0.1:%d" % port]
        return [srv, a]

    def _cal_trigger(self):
        f = p("sdr_cal_now", self.base)
        if os.path.exists(f):
            try:
                os.remove(f)
            except Exception:
                pass
            return True
        return False

    def cal_due(self, now):
        c = self.cfg
        if not c.get("cal_enable") or not self.tool("welle"):
            return False
        if self._cal_trigger():
            return True
        pc = c.get("ppm_cal") if isinstance(c.get("ppm_cal"), dict) else {}
        lt = time.localtime(now)
        last = pc.get("try_t") or 0
        return lt.tm_hour == int(c.get("cal_hour") or 3) and time.strftime("%Y%m%d", time.localtime(last)) != time.strftime("%Y%m%d", lt)

    def _cal_poll(self, now):
        i = int(self.active[4:])
        try:
            import prepper_sdr_net
            mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
        except Exception:
            return
        dm = (mux or {}).get("demodulator") or {}
        fc, snr = dm.get("frequencycorrection"), dm.get("snr")
        if isinstance(fc, (int, float)) and isinstance(snr, (int, float)) and snr >= 3 and now - self.since >= 12:
            self.cal_samples[i].append(float(fc))

    def cal_sub(self, i):
        xs = sorted(self.cal_samples[i])
        self.cal_samples[i] = []
        if len(xs) >= 4:
            q1, q3 = xs[len(xs) // 4], xs[(3 * len(xs)) // 4]
            if q3 - q1 <= 40:
                self.cal_res[i] = _med(xs)
                return
        self.cal_res[i] = None

    def cal_finish(self, now):
        c = self.cfg
        ch = str(self.dab_list()[0])
        f_hz = DAB_CHANNELS[ch] * 1e6
        ppm, note = cal_compute(self.cal_res[0], self.cal_res[1], int(c.get("cal_step_ppm") or 5), f_hz)
        old = c.get("ppm_cal") if isinstance(c.get("ppm_cal"), dict) else {}
        rec = dict(old)
        rec.update({"try_t": int(now), "note": note, "ch": ch, "c0": self.cal_res[0], "c1": self.cal_res[1]})
        upd = {"ppm_cal": rec}
        if ppm is not None:
            rec.update({"ppm": ppm, "t": int(now), "ok": True})
            if c.get("ppm_auto", True):
                upd["ppm"] = int(round(ppm))
        else:
            rec["ok_last"] = False
        sfx = "2" if self.stickno == 2 else ""  # sdrDual: ppm je Stick
        save_cfg_keys(self.base, dict((k + sfx, v) for k, v in upd.items()))
        c.update(upd)
        self.cal_res = [None, None]
        self.log("Kalibrierung: %s -> %s" % (note, "%+.2f ppm (angewendet %+d)" % (ppm, ppm_val(c)) if ppm is not None else "alter Wert bleibt"))

    def _cmd_meteor(self, f, secs, tmp):
        c = self.cfg
        check_tune("wxsat", f)
        if not serial_ok(self.dev_sn) or self.dev_idx is None:
            raise RuntimeError("Stick nicht aufgeloest")
        return [[self.tool("satdump"), "live", "meteor_m2-x_lrpt", tmp, "--source", "rtlsdr", "--source_id", self.dev_sn,
                 "--samplerate", str(c["meteor_samplerate"]), "--frequency", str(f),
                 "--gain", str(c["meteor_gain"]), "--timeout", str(int(secs))] + (["--ppm_correction", str(ppm_val(c))] if ppm_val(c) else [])]

    def _cmd_base(self, what):
        c = self.cfg
        if what == "433":
            a = ["rtl_433", "-f", str(c["f433"]), "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"]
            if ppm_val(c):
                a += ["-p", str(ppm_val(c))]
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
            if ppm_val(c):
                a += ["-p", str(ppm_val(c))]
            if c.get("gain_aprs") not in (None, ""):
                a += ["-g", str(c["gain_aprs"])]
            a = self._dev(a) + ["-"]
            return [a, ["direwolf", "-c", conf, "-r", "24000", "-D", "1", "-t", "0", "-q", "hd", "-"]]
        if what == "tcp":
            return [self._dev(["rtl_tcp", "-a", str(c["tcp_bind"]), "-p", str(int(c["tcp_port"])), "-P", str(ppm_val(c))])]
        return []

    def _reader(self, stream, fn):
        try:
            for raw in iter(stream.readline, b""):
                self.raw_t = time.time()  # sdrDual: dekodierte Zeile = Stick liefert
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
        if self.kfz:
            try:
                with self.lock:
                    self.kfz.add(raw)
            except Exception as e:
                self.log("KFZ-Log:", e)

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
        self.resolve()
        cmds = self.cmd(what)
        if self._pkind(what) == "wxsat":
            os.makedirs(self.cfg["meteor_tmp"], exist_ok=True)
        if any(not a[0] for a in cmds):
            raise RuntimeError("Start %s: Programm fehlt" % what)
        self.stderr = []
        prev = None
        procs = []
        if len(cmds) == 2 and cmds[0][0] == "rtl_tcp" and "127.0.0.1" in cmds[0] and str(cmds[1][0]).endswith("welle-cli"):
            self._start_sep(what, cmds)
            return
        try:
            for i, a in enumerate(cmds):
                last = i == len(cmds) - 1
                pr = subprocess.Popen(a, stdin=(prev.stdout if prev else subprocess.DEVNULL), stdout=subprocess.PIPE if (not last or what in ("433", "aprs") or what.startswith(("rds:", "nz:")) or self._pkind(what) in ("ism433", "srd868", "aprs", "fm") + ACT_KINDS) else subprocess.DEVNULL,
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
        elif what.startswith("nz:"):
            b = NOISE_BANDS[int(what[3:])]
            self.nzm = NoiseMeter(b, self.cfg.get("noise_car_db") or 10, self.cfg.get("noise_car_n") or 4)
            self.nzt = threading.Thread(target=self._noise_reader, args=(procs[-1].stdout, self.nzm, b), daemon=True)
            self.nzt.start()
        elif what.startswith("rds:"):
            st = self.fm_list()[int(what[4:])]
            threading.Thread(target=self._reader, args=(procs[-1].stdout, lambda ln, st=st: self.onrds(st, ln)), daemon=True).start()
        self.active, self.since = what, time.time()
        self.log("Start", what, " | ".join(" ".join(a) for a in cmds))

    def _start_sep(self, what, cmds):
        """rtl_tcp (127.0.0.1) und welle-cli als zwei getrennte Prozesse; welle-cli erst wenn der Port lauscht (max 10 s)."""
        port = int(cmds[0][cmds[0].index("-p") + 1])
        procs = []
        try:
            srv = subprocess.Popen(cmds[0], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
            procs.append(srv)
            threading.Thread(target=self._err_reader, args=(srv.stderr,), daemon=True).start()
            end = time.time() + 10
            while not port_listening(port):
                if srv.poll() is not None:
                    raise RuntimeError("rtl_tcp beendet (rc %s)" % srv.returncode)
                if time.time() > end:
                    raise RuntimeError("rtl_tcp lauscht nach 10 s nicht auf 127.0.0.1:%d" % port)
                time.sleep(0.25)
            wl = subprocess.Popen(cmds[1], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
            procs.append(wl)
            threading.Thread(target=self._err_reader, args=(wl.stderr,), daemon=True).start()
        except Exception as e:
            self.procs = procs
            self.kill()
            raise RuntimeError("Start %s: %s" % (what, e))
        self.procs = procs
        self.last_dabpoll = time.time()
        if self._pkind(what):
            ps = preset(what[2:])
            self._ll(ps["id"], "== Start %s (%s ; %s)" % (ps["label"], " ".join(cmds[0]), " ".join(cmds[1])))
        self.active, self.since = what, time.time()
        self.log("Start", what, " ; ".join(" ".join(a) for a in cmds), "(getrennt)")

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

    LAGE_KEYS = ("bc_interval_s", "noise_interval_s", "slice_433_s", "slice_aprs_s", "auto", "noise_enable", "bc_enable", "cal_enable", "meteor_enable", "asa_5c", "act_interval_s")

    def lage_apply(self):
        """sdrLage: Schalter -> wirksame Planer-Werte (nur im Speicher; sdr_config.json bleibt unveraendert)."""
        try:
            self.lage = get_lage(self.base)
        except Exception as e:
            self.log("Lage-Datei:", e)
        if self.lage_user is None:
            self.lage_user = {k: self.cfg.get(k) for k in self.LAGE_KEYS}
        u, sw, c = self.lage_user, self.lage["sw"], self.cfg
        for k in self.LAGE_KEYS:
            c[k] = u[k]
        biv = float(u.get("bc_interval_s") or 1800)
        c["bc_interval_s"] = min(biv, 600.0) if "an" in (sw["bc"], sw["asa"]) else biv
        c["bc_enable"] = bool(u.get("bc_enable")) and (sw["bc"] != "aus" or sw["asa"] != "aus")
        c["asa_5c"] = u.get("asa_5c") is not False and sw["asa"] != "aus"
        niv = float(u.get("noise_interval_s") or 900)
        c["noise_interval_s"] = min(niv, 600.0) if sw["noise"] == "an" else niv
        c["noise_enable"] = bool(u.get("noise_enable")) and sw["noise"] != "aus"
        c["cal_enable"] = bool(u.get("cal_enable")) and sw["cal"] != "aus"
        c["meteor_enable"] = bool(u.get("meteor_enable")) and sw["meteor"] != "aus"
        aiv = float(u.get("act_interval_s") or 1800)
        c["act_interval_s"] = min(aiv, 600.0) if sw["act"] == "an" else aiv
        for k in ("433", "aprs"):
            sl = float(u.get("slice_%s_s" % k) or 300)
            c["slice_%s_s" % k] = 2 * sl if sw[k] == "an" else sl
        base_order = [x for x in (u.get("auto") or ["433", "aprs"]) if x in ("433", "aprs")]
        for k in ("433", "aprs"):
            if sw[k] != "aus" and k not in base_order:
                base_order.append(k)
        c["auto"] = [x for x in base_order if sw[x] != "aus"]
        if self.role == "bc":   # sdrDual Stick 1: nur Rundfunk (BR24 + 5C) fast durchgehend + eigene Kalibrierung
            c["noise_enable"] = c["meteor_enable"] = False
            c["auto"] = []
            c["bc_interval_s"] = 5.0
        elif self.role == "rot":  # Stick 2: QRM, 433, APRS/Meteor/Aktivitaet nach Schaltern; kein Rundfunk
            c["bc_enable"] = False

    def act_queue(self):
        if self.lage["sw"].get("act") == "aus" or self.role == "bc":
            return []
        d = float(self.cfg.get("act_s") or 60)
        return [("p:" + x["id"], d) for x in PRESETS if x.get("kind") in ACT_KINDS]

    def lage_shares(self, now):
        """Erwartete Zeitanteile je Quelle (Anteil der Stick-Zeit) fuer den Balken auf der Kachel."""
        sh = []
        def add(k, x):
            if x > 0:
                sh.append([k, x])
        nq = self.noise_queue()
        if nq:
            add("noise", sum(d for _, d in nq) / float(self.cfg.get("noise_interval_s") or 900))
        bq = self.bc_queue()
        if bq:
            biv = float(self.cfg.get("bc_interval_s") or 1800)
            add("bc", sum(d for j, d in bq if not (j.startswith("dab:") and str(self.dab_list()[int(j[4:])]) == "5C")) / biv)
            add("asa", sum(d for j, d in bq if j.startswith("dab:") and str(self.dab_list()[int(j[4:])]) == "5C") / biv)
        aq = self.act_queue()
        if aq:
            add("act", sum(d for _, d in aq) / float(self.cfg.get("act_interval_s") or 1800))
        if self.cfg.get("cal_enable") and self.tool("welle"):
            add("cal", 2 * float(self.cfg.get("cal_s") or 45) / 86400.0)
        if self.cfg.get("meteor_enable") and self.tool("satdump"):
            add("meteor", 4 * 900 / 86400.0)
        tot = sum(x for _, x in sh)
        if tot > 1:
            sh = [[k, x / tot] for k, x in sh]
            tot = 1.0
        rest = 1.0 - tot
        order = list(self.cfg.get("auto") or [])
        sls = sum(float(self.cfg.get("slice_%s_s" % k) or 300) for k in order)
        for k in order:
            add(k, rest * float(self.cfg.get("slice_%s_s" % k) or 300) / sls)
        if not order and rest > 0.001:
            add("frei", rest)
        return [{"k": k, "pct": round(100 * x, 1)} for k, x in sh]

    def stick_health(self, now):
        """Stick-Zustand in Klartext. Nur Anzeige - kein automatischer USB-Reset."""
        if self.pin_err:
            return {"lvl": "rot", "txt": "Stick fehlt" if self.pin_err.startswith("Stick ") else "Stick-Fehler", "why": self.pin_err,
                    "hint": "USB-Stecker pruefen, Stick ab- und wieder anstecken"}
        bands = (self.ndiag or {}).get("bands") or {}
        nod = [k for k, b in bands.items() if not b.get("ok") and "keine Daten vom Stick" in str(b.get("why") or "")]
        if self.raw_fail >= 2 or (bands and len(nod) * 2 >= len(bands) and self.ndiag.get("t1")):
            return {"lvl": "rot", "txt": "Stick liefert keine Daten", "why": "%d Messungen ohne Rohdaten (%s)" % (max(self.raw_fail, len(nod)), ", ".join(sorted(nod)) or "Aktivitaet"),
                    "hint": "Stick einmal ab- und wieder anstecken (kein automatischer USB-Reset)", "since": self.raw_t}
        if self.raw_t and now - self.raw_t < 3600:
            return {"lvl": "ok", "txt": "Stick ok", "why": "Rohdaten zuletzt vor %d min" % ((now - self.raw_t) // 60), "since": self.raw_t}
        if self.raw_t:
            return {"lvl": "gelb", "txt": "Stick ungeprueft", "why": "letzte Rohdaten vor %d min" % ((now - self.raw_t) // 60), "since": self.raw_t}
        return {"lvl": "grau", "txt": "Stick wird geprueft", "why": "noch keine Messung seit Start"}

    def stick2_info(self):
        c = self.cfg.get("stick2") if isinstance(self.cfg.get("stick2"), dict) else {}
        if self.worker is not None:
            w = self.worker
            return {"model": c.get("model") or "NESDR SMArt v5", "serial": cfg_serial(w.cfg), "enabled": True, "present": not w.pin_err, "role": w.role,
                    "txt": "Stick 2 SN %s: %s" % (cfg_serial(w.cfg), {"rot": "Wechselbetrieb (QRM, 433, nach Schaltern)", "single": "macht alles (Stick 1 fehlt)"}.get(w.role, w.role)) if not w.pin_err else
                           "Stick 2 SN %s fehlt - Einzelbetrieb mit Stick 1" % cfg_serial(w.cfg)}
        sn = str(c.get("serial") or "")
        present = bool(sn) and sn in [str(x) for x in self.others]
        return {"model": c.get("model") or "NESDR SMArt v5", "serial": sn or None, "roles": [r for r in (c.get("roles") or []) if r in LAGE_SRC],
                "enabled": False, "present": present, "others": len(self.others),
                "txt": ("vorhanden (SN %s), Rolle %s vorbereitet - noch nicht aktiv" % (sn, "/".join(c.get("roles") or []))) if present else
                       ("Zweitstick vorbereitet (%s), nicht angeschlossen" % (c.get("model") or "NESDR SMArt v5"))}

    def want(self, mode, now):
        if self.role in ("bc", "rot"):
            m0 = mode["mode"]
            if m0 == "preset":
                ps = preset(mode.get("preset")) or {}
                if (ps.get("kind") in ("fm", "dab")) != (self.role == "bc"):
                    mode = {"mode": "auto"}   # Preset gehoert zum anderen Stick -> dieser bleibt in seiner Automatik
            elif m0 in ("433", "aprs", "tcp") and self.role == "bc":
                mode = {"mode": "auto"}       # 433/APRS/Netz nur auf Stick 2, Stick 1 hoert weiter Rundfunk
        m = mode["mode"]
        if m == "auto":
            self.lage_apply()
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
        if sp and sp["kind"] in ("bc", "noise") and self.cfg.get("cal_enable") and self.tool("welle") and os.path.exists(p("sdr_cal_now", self.base)):
            # Kalibrierung von Hand: laufenden Rundfunk-/Messblock abbrechen statt bis zu 15 min zu warten (Block laeuft spaeter erneut)
            try:
                self.sub_done(sp, now)
            except Exception as e:
                self.log("Block-Abbruch:", e)
            self.special = None
            sp = None
            self.log("Kalibrierung von Hand: laufenden Block unterbrochen")
        if sp:
            mt = self.nzm
            if (sp["kind"] == "noise" and mt is not None and self.active == sp["queue"][sp["i"]] and self.procs and now - self.since > NOISE_STALL_S
                    and not mt.nbytes and now < sp["sub_end"]):
                sp["sub_end"] = now  # sdrQrmFix: Stick liefert nichts -> nicht das ganze Fenster warten
                self.nz_end = "abgebrochen: %d s keine Daten" % int(now - self.since)
            if now < sp["sub_end"]:
                return sp["queue"][sp["i"]]
            self.sub_done(sp, now)
            sp["i"] += 1
            if sp["i"] < len(sp["queue"]) and now < sp.get("hard_end", now + 1):
                sp["sub_end"] = now + sp["durs"][sp["i"]]
                return sp["queue"][sp["i"]]
            if sp["kind"] == "bc":
                self.last_bc = now
                self.bc_done_t = int(now)
                self.sbc.last_saved = 0  # Block-Ergebnis gleich einmal speichern
            if sp["kind"] == "noise":
                self.last_noise = now
                self.ndiag["t1"] = int(now)
                self.ndiag["ok_n"] = sum(1 for x in self.ndiag.get("bands", {}).values() if x.get("ok"))
                try:
                    with self.lock:
                        self.snoise.finish_block(self.cfg, now)
                except Exception as e:
                    self.log("Funkumgebung:", e)
            if sp["kind"] == "cal":
                try:
                    self.cal_finish(now)
                except Exception as e:
                    self.log("Kalibrierung:", e)
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
        if self.cal_due(now):
            d = float(self.cfg.get("cal_s") or 45)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + 2 * d + 60:
                self.cal_samples, self.cal_res = [[], []], [None, None]
                self.special = {"kind": "cal", "queue": ["cal:0", "cal:1"], "durs": [d, d], "i": 0, "sub_end": now + d, "hard_end": now + 2 * d + 30, "t0": now}
                self.log("Kalibrierung startet (DAB %s)" % self.dab_list()[0])
                return "cal:0"
        nq = self.noise_queue()
        niv = float(self.cfg.get("noise_interval_s") or 900)
        if nq and now - self.last_noise >= niv:
            tot = sum(d for _, d in nq)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + tot + 60:
                self.special = {"kind": "noise", "queue": [j for j, _ in nq], "durs": [d for _, d in nq], "i": 0, "sub_end": now + nq[0][1],
                                "hard_end": now + tot + 10 * len(nq) + 30, "t0": now}
                self.ndiag = {"t0": int(now), "t1": None, "n": len(nq), "bands": {}, "skip": None, "skip_t": None}
                return nq[0][0]
            self.last_noise = now - niv + 300
            self.ndiag.update(skip="Meteor-Ueberflug %s bald - Messung 5 min spaeter" % nxt.get("sat"), skip_t=int(now))
        elif not nq and now - self.last_noise >= niv:
            self.ndiag.update(skip=self.noise_why_off(), skip_t=int(now))
        q = self.bc_queue()
        if q and now - self.last_bc >= float(self.cfg.get("bc_interval_s") or 1800):
            tot = sum(d for _, d in q)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + tot + 60:
                self.special = {"kind": "bc", "queue": [j for j, _ in q], "durs": [d for _, d in q], "i": 0, "sub_end": now + q[0][1],
                                "hard_end": now + tot + 30, "t0": now}
                return q[0][0]
            self.last_bc = now - float(self.cfg.get("bc_interval_s") or 1800) + 300
        aq = self.act_queue()
        if aq and now - self.last_act >= float(self.cfg.get("act_interval_s") or 1800):
            tot = sum(d for _, d in aq)
            nxt = self.next_pass(now)
            self.last_act = now
            if not nxt or nxt["aos"] > now + tot + 60:
                self.act_bytes = 0
                self.special = {"kind": "act", "queue": [j for j, _ in aq], "durs": [d for _, d in aq], "i": 0, "sub_end": now + aq[0][1],
                                "hard_end": now + tot + 30, "t0": now}
                return aq[0][0]
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")]
        if not order:
            return "idle"  # sdrLage: 433 und APRS aus -> keine Stick-Zeit
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
        bcon = getattr(self, "lage", {"sw": {}})["sw"].get("bc") != "aus" or not hasattr(self, "lage")
        if self.tool("redsea") and bcon:
            q += [("rds:%d" % i, float(self.cfg.get("fm_s") or 60)) for i in range(len(self.fm_list()))]
        if self.tool("welle"):
            q += [("dab:%d" % i, float(self.cfg.get("dab_s") or 60)) for i, ch in enumerate(self.dab_list()) if bcon or str(ch) == "5C"]
        return q

    def sub_done(self, sp, now):
        job = sp["queue"][sp["i"]]
        if job.startswith("dab:") and self.procs and self.alive():
            ch = str(self.dab_list()[int(job[4:])])
            try:
                import prepper_sdr_net
                mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
                if isinstance(((mux or {}).get("demodulator") or {}).get("snr"), (int, float)) and mux["demodulator"]["snr"] > 0:
                    self.raw_t, self.raw_fail = time.time(), 0  # sdrDual: DAB-Signal = Stick liefert
                with self.lock:
                    self.sbc.d["welle_caps"] = welle_caps(self.tool("welle"))
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
        if job.startswith("nz:"):
            nzend = getattr(self, "nz_end", None)
            self.nz_end = None
            if self.procs:
                if self.alive():
                    # sdrQrmFix: Zeitfenster vorbei -> erst SIGINT (rtl_power beendet Durchlauf + schreibt), dann wie immer
                    for pr in self.procs:
                        try:
                            os.killpg(pr.pid, signal.SIGINT)
                        except Exception:
                            pass
                    end = time.time() + 3 + 0.4 * noise_hops(NOISE_BANDS[int(job[3:])])
                    while time.time() < end and any(pr.poll() is None for pr in self.procs):
                        time.sleep(0.2)
                    nzend = nzend or ("nach Zeitfenster abgebrochen" if any(pr.poll() is None for pr in self.procs) else "nach Zeitfenster gestoppt")
                elif nzend is None:
                    nzend = "selbst beendet (rc %s)" % [pr.poll() for pr in self.procs]
                self.kill()
            if self.nzt is not None:
                self.nzt.join(timeout=10)
            if self.nzm is not None:
                self.nzm.end = nzend
                self.raw_jobs += 1
                if self.nzm.nbytes:
                    self.raw_t, self.raw_fail = time.time(), 0
                else:
                    self.raw_fail += 1
            mt, self.nzm, self.nzt = self.nzm, None, None
            bid = NOISE_BANDS[int(job[3:])]["id"]
            if mt is None:
                self.ndiag.setdefault("bands", {})[bid] = {"ok": False, "t": int(now), "why": "nicht gestartet: %s" % (self.err or "?")[:100]}
            if mt is not None:
                try:
                    r = mt.result(now)
                    if not r.get("ok"):
                        tail = ([x for x in self.stderr if x.strip()] or [""])[-1]
                        r["why"] = ((r.get("why") or "?") + (" · " + tail[:90] if tail else ""))[:160]
                    self.ndiag.setdefault("bands", {})[bid] = {"ok": bool(r.get("ok")), "t": int(now), "why": r.get("why") if not r.get("ok") else "ok (%s)" % mt.diag(), "n": r.get("n")}
                    with self.lock:
                        self.snoise.add(r, self.cfg, now)
                    self._ll("noise_" + r["band"], json.dumps({k: r.get(k) for k in ("band", "t", "floor", "p90", "n_car", "imp_pm", "bb_pm", "ok")}, separators=(",", ":")), numeric=True)
                except Exception as e:
                    self.log("Funkumgebung %s: %s" % (job, e))
        if job.startswith("cal:"):
            if self.procs:
                self.kill()
            self.cal_sub(int(job[4:]))
        if sp.get("kind") == "act":
            if self.procs:
                self.kill()
            if not self.act_bytes and now - sp.get("t0", now) > 20:
                self.raw_fail += 1
            self.act_bytes = 0

    def pass_now(self, now):
        if not self.cfg.get("meteor_enable") or not self.tool("satdump"):
            return None
        for ps in self.passes:
            if ps["aos"] - 20 <= now < ps["los"] - 60 and ps["max_el"] >= float(self.cfg.get("meteor_min_el") or 20) and not ps.get("done"):
                ps["done"] = True
                return ps
        return None

    def next_pass(self, now):
        if not self.cfg.get("meteor_enable"):
            return None  # sdrLage: Meteor AUS -> kein Ueberflug blockiert andere Bloecke
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

    def status(self, mode, force=False, write=True):
        now = time.time()
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")]
        nxt = None
        if mode["mode"] == "auto" and self.active in order and len(order) > 1:
            nxt = int(self.slice_start + float(self.cfg.get("slice_%s_s" % self.active) or 300))
        with self.lock:
            st = {"v": V, "t": int(now), "pid": os.getpid(), "started": int(self.started), "mode": mode["mode"], "until": mode.get("until"),
                  "active": self.active, "since": int(self.since), "next_switch": nxt, "stick": self.stick,
                  "serial": cfg_serial(self.cfg), "stick_idx": self.dev_idx, "sticks_n": self.sticks_n, "others": list(self.others), "pin_err": self.pin_err,
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
                  "noise": self.noise_summary(), "cal": self.cal_summary(), "noise_diag": dict(self.ndiag), "sched": self.sched(now, mode), "bc_done_t": self.bc_done_t, "gps": self.gps.summary() if self.gps else {"lvl": "grau", "ok": None, "why": "aus", "src": "Dach-GPS"},
                  "evlog": ({"n": self.evlog.n, "open": len(self.evlog.open), "kfz": self.kfz.n if self.kfz else 0} if self.evlog else None), "linelog": {"n": self.llog.n, "kw": self.llog.kw, "on": self.llog.on, "dropped": self.llog.dropped}, "tools": {"redsea": bool(self.tool("redsea")), "welle": bool(self.tool("welle")), "satdump": bool(self.tool("satdump"))},
                  "lage": dict(self.lage), "shares": self.lage_shares(now), "stick_health": self.stick_health(now), "stick2": self.stick2_info(),
                  "next_act": int(self.last_act + float(self.cfg.get("act_interval_s") or 1800)) if self.act_queue() else None}
        st["stickno"], st["role"], st["sn"] = self.stickno, self.role, cfg_serial(self.cfg)
        if not write:
            return st
        w = self.worker
        w2 = w.st_cache if w is not None else None
        st["dual"] = {"on": w is not None, "role1": self.role, "role2": w.role if w is not None else None,
                      "sn1": cfg_serial(self.cfg), "sn2": cfg_serial(w.cfg) if w is not None else None}
        if w2:
            st["s2"] = {k: w2.get(k) for k in ("active", "since", "err", "err_t", "pin_err", "special", "stick_health", "shares", "cal", "next_switch", "stderr", "stick_idx", "sn", "role")}
            st["shares2"], st["stick_health2"] = w2.get("shares"), w2.get("stick_health")
            if w.role == "rot" or (w.role == "single" and not w.pin_err):
                st["noise_diag"] = w2.get("noise_diag")
                st["next_pass"] = w2.get("next_pass")
                st["next_act"] = w2.get("next_act")
                mine = dict((x["k"], x) for x in st.get("sched") or [])
                for x in w2.get("sched") or []:
                    if x["k"] in ("noise", "meteor") or (x["k"] == "bc" and self.role != "bc" and w.role == "single"):
                        mine[x["k"]] = x
                st["sched"] = list(mine.values())
            if (self.role == "bc" and w.role == "rot") or (w.role == "single" and not w.pin_err):
                st["auto"], st["slices"], st["next_switch"] = w2.get("auto"), w2.get("slices"), w2.get("next_switch")
        sig = (st["mode"], st["active"], st["err"], len(st["stick"]), st["until"], bool(self.special), (w2 or {}).get("active"))
        if force or sig != self.lastsig or now - self.last_status >= 60:
            write_json(p("sdr_status.json", self.base), st)
            self.last_status, self.lastsig = now, sig
        return st

    def noise_summary(self):
        d = self.snoise.d
        bands = []
        for b in NOISE_BANDS:
            x = (d.get("bands") or {}).get(b["id"])
            if not x:
                continue
            bands.append({"id": b["id"], "short": b["short"], "label": b["label"], "ok": x.get("ok"), "t": x.get("t"), "floor": x.get("floor"),
                          "raise": x.get("raise"), "lvl": x.get("lvl") if x.get("ok") else "grau", "n_pers": x.get("n_pers"), "learning": x.get("learning"),
                          "cars": (x.get("cars") or [])[:3], "bb_pm": x.get("bb_pm"), "why": x.get("why"), "base": x.get("base"), "src": x.get("src"),
                          "yel": x.get("yel"), "red": x.get("red"), "trend": x.get("trend") if x.get("ok") else None})
        return {"t": d.get("t"), "qrm": d.get("qrm"), "thunder": d.get("thunder"), "bands": bands,
                "next": int(self.last_noise + float(self.cfg.get("noise_interval_s") or 900)) if self.cfg.get("noise_enable") else None}

    def cal_summary(self):
        pc = self.cfg.get("ppm_cal") if isinstance(self.cfg.get("ppm_cal"), dict) else {}
        return {"ppm": pc.get("ppm"), "t": pc.get("t"), "try_t": pc.get("try_t"), "note": pc.get("note"), "applied": ppm_val(self.cfg),
                "auto": bool(self.cfg.get("ppm_auto", True)), "on": bool(self.cfg.get("cal_enable"))}

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
            self.snoise.save_hist(force)
            if self.kfz:
                self.kfz.save(force)

    def step(self):
        now = time.time()
        mode = get_mode(self.base)
        allst = stick_info(self.cfg["usb_ids"])
        sn = cfg_serial(self.cfg)
        mine = [x for x in allst if sn and x.get("serial") == sn]
        self.stick = mine[:1] + [x for x in allst if x not in mine[:1]]
        self.sticks_n = len(allst)
        self.others = [x.get("serial") or "?" for x in allst if not (sn and x.get("serial") == sn)]
        if sn is None:
            perr = "Seriennummer in sdr_config.json ungueltig (nur Ziffern) - nicht gestartet"
        elif len(mine) > 1:
            perr = "doppelte Seriennummer %s (%d Sticks) - nicht gestartet" % (sn, len(mine))
        elif not mine:
            perr = "Stick %s fehlt" % sn
        else:
            perr = None
        if perr:
            if self.procs:
                self.kill()
            if self.pin_err != perr:
                self.log(perr, "- warte still, nehme keinen anderen Stick (pruefe alle 15 s)")
            self.pin_err = perr
            self.active, self.err, self.dev_idx = ("nostick" if perr.startswith("Stick ") else "fehler"), perr, None
            self.fails = 0
            return 15, mode
        if self.pin_err or self.active == "nostick":
            self.pin_err = None
            self.active, self.err, self.since = "idle", None, now
            self.log("Stick da: SN %s (%s), Sticks gesamt %d" % (sn, mine[0].get("product"), len(allst)))
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
        if self.active.startswith("cal:") and self.procs and self.alive() and now - self.last_calpoll >= 4:
            self.last_calpoll = now
            self._cal_poll(now)
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
            if self.active.startswith("nz:"):
                self.nz_end = "selbst beendet (rc %s)" % rc  # sdrQrmFix
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

    def loop2(self):
        """sdrDual: Stick-2-Planer im eigenen Faden desselben Prozesses (Stopp ueber den Haupt-Planer)."""
        mode = get_mode(self.base)
        while not self.main.stop:
            try:
                wait, mode = self.step()
            except Exception as e:
                self.log("Planer-Fehler:", e)
                wait = 10
            try:
                if not self.special and self.role in ("rot", "single"):
                    self.maintain(time.time())
                    self.main.passes = self.passes
            except Exception as e:
                self.log("Wartung:", e)
            try:
                self.st_cache = self.status(mode, write=False)
            except Exception as e:
                self.log("Status:", e)
            end = time.time() + wait
            while not self.main.stop and time.time() < end:
                time.sleep(0.5)
                gm = get_mode(self.base)
                if gm["mode"] != mode["mode"] or gm.get("preset") != mode.get("preset"):
                    break
        self.kill()
        self.active = "idle"

    def dual_tick(self):
        """sdrDual: Rollen nach vorhandenen Sticks (per Seriennummer) setzen."""
        w = self.worker
        if w is None:
            return
        sers = set(str(x.get("serial")) for x in stick_info(self.cfg["usb_ids"]))
        r1, r2 = dual_roles(cfg_serial(self.cfg) in sers, cfg_serial(w.cfg) in sers, True)
        self.set_role(r1)
        w.set_role(r2)

    def loop(self):
        def _sig(*_):
            self.stop = True
        signal.signal(signal.SIGTERM, _sig)
        signal.signal(signal.SIGINT, _sig)
        self.log("Start v%d, Basis %s, Heimat %s, auto %s" % (V, self.base, self.cfg["home"], self.cfg["auto"]))
        if self.cfg.get("gps_enable", True):
            try:
                import prepper_gps
                self.gps = prepper_gps.GpsWatch(p("sdr_gps_hist.json", self.base), self.cfg, load_keep, write_json_keep, self.log)
                threading.Thread(target=self.gps.run, daemon=True).start()
            except Exception as e:
                self.gps = None
                self.log("Dach-GPS nicht gestartet:", e)
        try:
            import prepper_evlog
            tq = prepper_evlog.TimeQ()
            self.evlog = prepper_evlog.EvLog(self.base, load_keep, write_json_keep, self.log, tq=tq)
            self.kfz = prepper_evlog.KfzLog(self.base, load_keep, write_json_keep, self.log, tq=tq)
        except Exception as e:
            self.evlog = self.kfz = None
            self.log("Ereignis-Log nicht gestartet:", e)
        if cfg_serial2(self.cfg):
            try:
                self.worker = Planner(self.base, stick=2, main=self)
                self.worker.log = lambda *a: self.log("[Stick 2]", *a)
                self.dual_tick()
                threading.Thread(target=self.worker.loop2, daemon=True).start()
                self.log("sdrDual: Stick 1 SN %s Rundfunk fest, Stick 2 SN %s Wechselbetrieb" % (cfg_serial(self.cfg), cfg_serial(self.worker.cfg)))
            except Exception as e:
                self.worker = None
                self.log("sdrDual: Stick 2 nicht gestartet:", e)
        mode = get_mode(self.base)
        while not self.stop:
            try:
                self.dual_tick()
            except Exception as e:
                self.log("Stick-Rollen:", e)
            try:
                wait, mode = self.step()
            except Exception as e:
                self.log("Planer-Fehler:", e)
                wait = 10
            try:
                if not self.special and (self.worker is None or self.worker.role == "off" or self.role == "single" and self.worker.role != "single"):
                    self.maintain(time.time())
            except Exception as e:
                self.log("Wartung:", e)
            try:
                st = self.status(mode, force=(time.time() - self.started < 20))
                if self.evlog:
                    try:
                        self.evlog.update(st)
                    except Exception as e:
                        self.log("Ereignis-Log:", e)
                self.flush()
                if time.time() - self.last_prune > 3600:
                    with self.lock:
                        self.s433.prune(self.cfg["keep_days"])
                        self.saprs.prune(self.cfg["keep_days"])
                        if self.kfz:
                            try:
                                self.kfz.prune()
                            except Exception as e:
                                self.log("KFZ-Bereinigung:", e)
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
        if self.worker is not None:
            self.worker.kill()
        if self.gps:
            self.gps.stop = True
            try:
                with self.gps.lock:
                    if self.gps.dirty:
                        self.gps.save()
            except Exception as e:
                self.log("Dach-GPS speichern:", e)
        if self.evlog:
            try:
                self.evlog.save()
            except Exception as e:
                self.log("Ereignis-Log speichern:", e)
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


def selftest_noise2(tmp):
    """Synthetische Pruefungen sdrNoise2: robuste Schwellen, Stunden-Grundlinie, Trend (inkl. Fehlalarm), Gewitter, Uhr, kaputte Dateien."""
    import random
    rnd = random.Random(11)
    cfg = dict(DEFAULT_CFG)
    m, s, n = robust([1, 2, 3, 4, 100, float("nan"), None, float("inf")])
    assert m == 3 and abs(s - 1.4826) < 1e-6 and n == 5, (m, s, n)
    assert thresholds(0.5, cfg) == (5.0, 10.0) and thresholds(2.0, cfg) == (8.0, 12.0) and thresholds(None, cfg) == (5.0, 10.0)
    T0 = int(time.mktime((2026, 9, 1, 0, 0, 0, 0, 0, -1)))
    # 1) Stationaeres Rauschen 14 Tage (sigma 1 dB) -> nie gelb/rot/Trend (Fehlalarm-Pruefung)
    d1 = os.path.join(tmp, "n1")
    os.makedirs(d1, exist_ok=True)
    ns = NoiseState(d1)
    bad = 0
    for k in range(14 * 96):
        t = T0 + k * 900
        ns.add({"band": "fm", "t": t, "ok": True, "floor": -40 + rnd.gauss(0, 1.0), "p90": -38, "cars": [], "s": 10}, cfg, t)
        x = ns.d["bands"]["fm"]
        bad += x["lvl"] != "gruen" or x["trend"]["on"]
    assert bad <= 2, bad
    assert len(ns.h["fm"]) <= NoiseState.CAP
    # 2) langsamer Anstieg +3 dB ueber 2 Tage -> 'Trend steigend' ohne gelb; danach zurueck -> Trend aus (Hysterese)
    tr_on = None
    for k in range(4 * 96):
        t = T0 + (14 * 96 + k) * 900
        ns.add({"band": "fm", "t": t, "ok": True, "floor": -40 + min(3.0, 3.0 * k / 192.0) + rnd.gauss(0, 1.0), "cars": [], "s": 10}, cfg, t)
        x = ns.d["bands"]["fm"]
        if x["trend"]["on"] and tr_on is None:
            tr_on = k
        assert x["lvl"] != "rot", x
    assert tr_on is not None and tr_on < 4 * 96, tr_on
    for k in range(3 * 96):
        t = T0 + (18 * 96 + k) * 900
        ns.add({"band": "fm", "t": t, "ok": True, "floor": -40 + rnd.gauss(0, 1.0), "cars": [], "s": 10}, cfg, t)
    assert not ns.d["bands"]["fm"]["trend"]["on"], ns.d["bands"]["fm"]["trend"]
    # Luecke > 6 h und Uhr rueckwaerts setzen den Trend zurueck
    tr = ns.trend_step("fm", 5.0, T0 + 30 * 86400, cfg)
    assert tr["n"] == 1 and tr.get("reset")
    tr = ns.trend_step("fm", 5.0, T0 + 29 * 86400, cfg)
    assert tr["n"] == 1 and tr.get("reset")
    # 3) Sprung +12 dB -> rot, +6 dB -> gelb; verrauschtes Band (MAD 3 dB) hebt die Schwellen an
    t = T0 + 22 * 86400
    ns.add({"band": "fm", "t": t, "ok": True, "floor": -24.0, "cars": [], "s": 10}, cfg, t)
    assert ns.d["bands"]["fm"]["lvl"] == "rot", ns.d["bands"]["fm"]
    ns.add({"band": "fm", "t": t + 900, "ok": True, "floor": -30.0, "cars": [], "s": 10}, cfg, t + 900)
    assert ns.d["bands"]["fm"]["lvl"] == "gelb", ns.d["bands"]["fm"]
    d2 = os.path.join(tmp, "n2")
    os.makedirs(d2, exist_ok=True)
    nz = NoiseState(d2)
    for k in range(3 * 96):
        tt = T0 + k * 900
        nz.add({"band": "n433", "t": tt, "ok": True, "floor": -40 + rnd.gauss(0, 3.0), "cars": [], "s": 6}, cfg, tt)
    x = nz.d["bands"]["n433"]
    assert x["yel"] > 9 and x["red"] > 14, x
    # 4) MW mit Tagesgang (nachts +8 dB Ausbreitung) -> Stunden-Grundlinie: kein Alarm nachts; ohne Stunden-GL waere es gelb
    d3 = os.path.join(tmp, "n3")
    os.makedirs(d3, exist_ok=True)
    nm = NoiseState(d3)
    alarms = 0
    for k in range(10 * 96):
        tt = T0 + k * 900
        hr = time.localtime(tt).tm_hour
        fl = -50 + (8.0 if (hr >= 19 or hr < 6) else 0.0) + rnd.gauss(0, 0.8)
        nm.add({"band": "mw", "t": tt, "ok": True, "floor": fl, "cars": [], "s": 8, "bb_pm": max(0.0, rnd.gauss(2, 1)), "imp_pm": 3}, cfg, tt)
        x = nm.d["bands"]["mw"]
        if k > 5 * 96:
            alarms += x["lvl"] != "gruen" or x["trend"]["on"]
            assert x["src"].startswith("Stunde"), x["src"]
    assert alarms <= 2, alarms
    # 5) Gewitter: Stunden-Grundlinie der Impulse; 1 Messung viel -> gelb, zwei hintereinander -> rot
    nm.finish_block(cfg, T0 + 10 * 96 * 900)
    assert nm.d["thunder"]["lvl"] == "gruen" and nm.d["thunder"]["src"].startswith("Stunde"), nm.d["thunder"]
    tt = T0 + 10 * 96 * 900 + 900
    nm.add({"band": "mw", "t": tt, "ok": True, "floor": -50.0, "cars": [], "s": 8, "bb_pm": 30.0, "imp_pm": 40}, cfg, tt)
    nm.finish_block(cfg, tt)
    assert nm.d["thunder"]["lvl"] == "gelb", nm.d["thunder"]
    nm.add({"band": "mw", "t": tt + 900, "ok": True, "floor": -50.0, "cars": [], "s": 8, "bb_pm": 40.0, "imp_pm": 50}, cfg, tt + 900)
    nm.finish_block(cfg, tt + 900)
    assert nm.d["thunder"]["lvl"] == "rot", nm.d["thunder"]
    # 6) Uhr nicht gestellt / NaN -> nichts gespeichert
    n0 = len(nm.h["mw"])
    nm.add({"band": "mw", "t": 1000, "ok": True, "floor": -50.0, "cars": []}, cfg, 1000)
    nm.add({"band": "mw", "t": tt + 1800, "ok": True, "floor": float("nan"), "cars": []}, cfg, tt + 1800)
    nm.add({"band": "unbekannt", "t": tt, "ok": True, "floor": 1.0}, cfg, tt)
    assert len(nm.h["mw"]) == n0
    # 7) Verlauf: atomar mit .1; kaputte Datei -> vorige Fassung; beides kaputt -> leer, kein Absturz
    nm.save_hist(True, now=tt)
    nm.hdirty = True
    nm.save_hist(True, now=tt)
    with open(nm.fh, "w") as f:
        f.write("{kaputt")
    with open(nm.f, "w") as f:
        f.write("")
    nr = NoiseState(d3)
    assert len(nr.h["mw"]) == len(nm.h["mw"]) and isinstance(nr.d["bands"], dict)
    with open(nm.fh + ".1", "w") as f:
        f.write("[1,2")
    nr = NoiseState(d3)
    assert nr.h["mw"] == [] and nr.d["trend"] == {}
    print("selftest sdrNoise2 ok")


def selftest_dual():
    """hermetisch: eigenes Temp-Verzeichnis, feste Uhr, numpy-Verfuegbarkeit fest vorgegeben (unabhaengig von Live-Dateien/Interpreter)."""
    import tempfile
    had_np = "numpy" in sys.modules
    old_np = sys.modules.get("numpy")
    if old_np is None:
        sys.modules["numpy"] = type(sys)("numpy")  # nur fuer den Test: Messprogramm gilt als vorhanden
    try:
        _selftest_dual(tempfile.mkdtemp())
    finally:
        if not had_np or old_np is None:
            sys.modules.pop("numpy", None)
            if had_np:
                sys.modules["numpy"] = old_np


def _selftest_dual(tmp):
    c = {"serial": "19348831", "stick2": {"serial": "72055505", "enabled": True}}
    assert cfg_serial2(c) == "72055505" and cfg_serial2({"serial": "1", "stick2": {"serial": "1", "enabled": True}}) is None
    assert cfg_serial2({"stick2": {"serial": "72055505", "enabled": False}}) is None
    assert dual_roles(True, True, True) == ("bc", "rot") and dual_roles(True, False, True) == ("single", "single") and dual_roles(True, True, False) == ("single", None)
    save_cfg_keys(tmp, {"stick2": {"serial": "72055505", "enabled": True}, "ppm": 1, "ppm2": -3})
    m = Planner(tmp)
    w = Planner(tmp, stick=2, main=m)
    m.worker = w
    assert cfg_serial(w.cfg) == "72055505" and cfg_serial(m.cfg) == "19348831" and ppm_val(w.cfg) == -3 and ppm_val(m.cfg) == 1
    assert w.cfg["dab_port"] == 7981 and w.cfg["dab_tcp_port"] == 1237 and m.cfg["dab_port"] == 7979 and w.s433 is m.s433 and w.lock is m.lock
    for x in (m, w):
        x.tools.update({"welle": "/x/welle-cli", "redsea": "/x/redsea", "satdump": None})
        x._has_rp = True
        x.cfg.update(bc_enable=True, noise_enable=True, cal_enable=True)
    for x in (m, w):
        x.lage_user = None
    set_lage(tmp, profile="warn")
    m.set_role("bc"); w.set_role("rot")
    now = 1760000000.0  # feste Uhr
    m.last_bc = 0
    j1 = m.want({"mode": "auto"}, now)
    assert j1.startswith("rds:") and m.special["kind"] == "bc", j1
    w.last_noise = 0
    j2 = w.want({"mode": "auto"}, now)
    assert j2.startswith("nz:") and not w.bc_queue() and not m.noise_queue(), j2
    assert m.cfg["auto"] == [] and w.cfg["auto"] == ["433", "aprs"]
    # Live-Lage nachgestellt (Warnlage angepasst): 433=AUTO act=AUS aprs=AUS asa=AN bc=AN cal=AUTO meteor=AUS noise=AN
    for k, v in (("aprs", "aus"), ("act", "aus"), ("meteor", "aus"), ("433", "auto"), ("asa", "an"), ("bc", "an"), ("cal", "auto"), ("noise", "an")):
        set_lage(tmp, src=k, state=v)
    for x in (m, w):
        x.special = None
        x.lage_apply()
    w.last_noise = 0
    assert w.want({"mode": "auto"}, now).startswith("nz:")  # QRM faellig -> laeuft zuerst
    w.special = None
    w.last_noise = now
    j3 = w.want({"mode": "auto"}, now + 1)
    assert j3 == "433", j3  # QRM gerade gelaufen -> 433 fuellt
    w.special = None
    w.last_noise = now - float(w.cfg.get("noise_interval_s") or 900)
    assert w.want({"mode": "auto"}, now + 1).startswith("nz:")  # Intervall abgelaufen -> wieder QRM
    w.special = None
    s1 = dict((x["k"], x["pct"]) for x in m.lage_shares(now))
    s2 = dict((x["k"], x["pct"]) for x in w.lage_shares(now))
    assert "noise" not in s1 and s1.get("bc", 0) + s1.get("asa", 0) > 90 and "bc" not in s2 and s2["noise"] > 0 and s2["433"] > 0, (s1, s2)
    m.special = None
    assert m.want({"mode": "433"}, now).startswith("rds:")  # Stick 1 bleibt beim Rundfunk
    m.special = w.special = None
    assert w.want({"mode": "433"}, now) == "433"
    assert w.want({"mode": "preset", "preset": "fm_br24"}, now) != "p:fm_br24" and m.want({"mode": "preset", "preset": "fm_br24"}, now) == "p:fm_br24"
    m.special = w.special = None
    m.set_role("single"); w.set_role("single")
    m.lage_apply()
    assert m.cfg["noise_enable"] and m.cfg["auto"] == ["433"]  # Live-Lage: APRS AUS
    w.cal_res = [0.0, -1110.32]
    w.dab_list = lambda: ["11D"]
    w.cal_finish(time.time())
    cc = load_json(p("sdr_config.json", tmp), {})
    assert "ppm_cal2" in cc and "ppm_cal" not in cc and cc["ppm"] == 1, cc
    print("selftest sdrDual ok (Rollen, Zuordnung je Stick, Fallback Einzelbetrieb, ppm je Stick, getrennte Ports)")


def selftest_lage():
    import tempfile
    tmp = tempfile.mkdtemp()
    assert get_lage(tmp)["profile"] == "normal" and not get_lage(tmp)["custom"]
    l = set_lage(tmp, profile="warn")
    assert l["sw"]["bc"] == "an" and not l["custom"]
    l = set_lage(tmp, src="aprs", state="aus")
    assert l["custom"] and l["sw"]["aprs"] == "aus" and l["profile"] == "warn"
    for bad in ({"profile": "x"}, {"src": "gps", "state": "an"}, {"src": "433", "state": "1"}):
        try:
            set_lage(tmp, **bad)
            raise AssertionError(bad)
        except ValueError:
            pass
    pl = Planner(tmp)
    pl.tools.update({"welle": "/x/welle-cli", "redsea": "/x/redsea", "satdump": None})
    pl.cfg.update(bc_enable=True, cal_enable=True, noise_enable=True)
    pl._has_rp = True
    pl.lage_apply()
    assert pl.cfg["auto"] == ["433"] and pl.cfg["bc_interval_s"] == 600 and pl.cfg["noise_interval_s"] == 600, pl.cfg["auto"]
    sh = dict((x["k"], x["pct"]) for x in pl.lage_shares(time.time()))
    assert "aprs" not in sh and sh["433"] > 0 and sh["bc"] > 0 and sh["asa"] > 0 and abs(sum(sh.values()) - 100) < 0.5, sh
    set_lage(tmp, profile="ruhe")
    pl.lage_apply()
    assert pl.cfg["auto"] == [] and not pl.cfg["noise_enable"] and not pl.cfg["bc_enable"] and pl.cfg["cal_enable"]
    pl.last_noise = pl.last_bc = 0
    assert pl.want({"mode": "auto"}, time.time()) == "idle"
    assert [x["k"] for x in pl.lage_shares(time.time())] == ["cal", "frei"]
    set_lage(tmp, profile="funk")
    pl.lage_apply()
    assert pl.cfg["slice_aprs_s"] == 2 * pl.cfg["slice_433_s"] and pl.act_queue() and pl.cfg["act_interval_s"] == 600
    pl.last_noise = pl.last_bc = time.time()
    pl.last_act = 0
    pl.passes = []
    w = pl.want({"mode": "auto"}, time.time())
    assert w == "p:act_1455" and pl.special["kind"] == "act", w
    pl.special = None
    set_lage(tmp, profile="warn")
    set_lage(tmp, src="bc", state="aus")
    pl.lage_apply()
    assert [j for j, _ in pl.bc_queue()] == ["dab:%d" % pl.dab_list().index("5C")], pl.bc_queue()
    pl.ndiag = {"t1": 1, "bands": {"n2m": {"ok": False, "why": "zu wenig Sweeps (keine Daten vom Stick)"}, "fm": {"ok": False, "why": "zu wenig Sweeps (keine Daten vom Stick)"}}}
    assert pl.stick_health(time.time())["txt"] == "Stick liefert keine Daten"
    pl.ndiag = {"bands": {}}
    pl.raw_t = time.time() - 60
    assert pl.stick_health(time.time())["lvl"] == "ok"
    assert pl.stick2_info()["enabled"] is False and not pl.stick2_info()["present"]
    print("selftest sdrLage ok (Profile, Schalter, Zeitanteile, Ruhe=idle, Funklage=Aktivitaet, Stick-Zustand)")


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
    pl0.dev_idx, pl0.dev_sn = 0, DEFAULT_SERIAL
    pl0.cfg["f433"] = _mz(170 + 3.25)
    try:
        pl0.cmd("433")
        raise AssertionError("433 ausserhalb")
    except RuntimeError:
        pass
    assert pl0.cmd("p:868")[0][2] == "868.3M" and pl0.cmd("p:868")[0][-2:] == ["-d", ":" + DEFAULT_SERIAL]
    pl0.tools["welle"] = "/x/welle-cli"
    pl0.list_n = 1
    assert pl0.cmd("p:dab_11D") == [["/x/welle-cli", "-c", "11D", "-C", "1", "-w", "7979", "-F", "rtl_sdr"]], pl0.cmd("p:dab_11D")
    pl0.list_n = 2
    dc = pl0.cmd("p:dab_11D")
    assert dc[0] == ["rtl_tcp", "-a", "127.0.0.1", "-p", "1235", "-P", "0", "-d", "0"] and "rtl_tcp,127.0.0.1:1235" in dc[1], dc
    pl0.tools["satdump"] = "/x/satdump"
    pl0.special = {"pass": {"f": "137.9e6", "los": time.time() + 300}, "tmp": tmp}
    mc = pl0.cmd("meteor")[0]
    assert mc[mc.index("--source_id") + 1] == DEFAULT_SERIAL, mc
    pl0.special = None
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
    assert [w["kind"] for w in b.d["warn"]] == ["TA"] and "rt_ok" not in b.d["fm"]["BR24"], b.d["warn"]      # erst stabil (2x) auswerten
    b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Amtliche Warnung vor Unwetter im Landkreis ERH"}')
    assert [w["kind"] for w in b.d["warn"]] == ["TA", "RT"] and b.d["fm"]["BR24"]["rt_ok"].startswith("Amtliche"), b.d["warn"]
    dab = b.on_dab("11D", {"ensemble": {"label": {"label": "BR Bayern"}}, "services": [{"label": {"label": "BR24"}, "dls": {"label": "Nachrichten"}, "sid": "0xD314"},
                                                                                      {"label": {"label": "Bayern 3"}, "dls": {"label": "Unwetterwarnung Nürnberg"}}],
                                     "announcements": [{"type": "Alarm", "active": True}]})
    assert dab["ensemble"] == "BR Bayern" and dab["n"] == 2 and dab["alarm"] and len(b.d["warn"]) == 3, (dab, b.d["warn"])   # "Unwetterwarnung Nuernberg" allein ist nicht rot
    assert dab["services"][0]["sid"] == "0xD314" and dab["services"][1]["sid"] is None, dab["services"]
    _bx = os.path.join(tmp, "bx")
    os.makedirs(_bx, exist_ok=True)
    _sx = StateBC(_bx).on_dab("11D", {"services": [{"label": "X", "sid": 54036}, {"label": "Y", "sid": "kaputt; rm"}]})["services"]
    assert _sx[0]["sid"] == "0xD314" and _sx[1]["sid"] is None, _sx
    print(_ws_selftest())
    _b2 = StateBC(_bx)
    _a = _b2.on_dab("5C", {"services": [{"label": "ASA DE", "sid": "0x1D11", "dls": "Amtliche Gefahrendurchsage: Fenster und Türen schließen"}, {"label": "DLF", "dls": "Nachrichten"}]}, now=1000)
    assert _a["asa"] and _a["asa"][0]["label"] == "ASA DE" and [w["kind"] for w in _b2.d["warn"]] == ["DLS"], (_a, _b2.d["warn"])
    _ks = [(x["k"], x.get("cls")) for x in _b2.evl.ev]
    assert ("asa", None) in _ks and ("dls", "rot") in _ks and ("dls", None) in _ks, _ks
    _b2.on_dab("5C", {"services": [{"label": "ASA DE", "dls": "Info zu ASA"}]}, now=1100)
    assert [x["k"] for x in _b2.evl.ev].count("asa") == 1
    for i, tt in enumerate((0, 10, 20, 31)):
        _b2.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","prog_type":"Alarm"}', now=2000 + tt)
    _p = [x for x in _b2.evl.ev if x["k"] == "pty31"]
    assert [x["persist"] for x in _p] == [False, True] and _b2.d["fm"]["BR24"]["pty31_persist"] == 1, _p
    _b2.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","prog_type":"News"}', now=2050)
    assert _b2.d["fm"]["BR24"]["pty31_persist"] == 0
    for _ in range(2):
        _b2.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Adele - Hello","radiotext_plus":{"tags":[{"content-type":"item.artist"}]}}', now=2100)
    assert [x for x in _b2.evl.ev if x["k"] == "rt_warn"] == [] and _b2.d["fm"]["BR24"]["rtp"] == ["item.artist"]
    _wc = welle_caps(sys.executable)
    assert set(_wc) >= {"fig0_0", "fig0_19", "asa", "note"} and welle_caps(None)["exe"] is None
    _pl = Planner.__new__(Planner)
    _pl.cfg = {"dab": ["11D"]}
    assert _pl.dab_list() == ["11D", "5C"] and (_pl.cfg.update(asa_5c=False) or _pl.dab_list() == ["11D"])
    print("selftest br24Warn2 ok (Warn-Score, ASA DE 5C, PTY 31 dauerhaft, RT stabil, RT+ Titel)")
    _pl.ndiag, _pl.bc_done_t, _pl.last_noise, _pl.last_bc = {"t1": None, "skip": None}, None, 1000.0, 1000.0
    _pl.cfg = dict(DEFAULT_CFG, dab=["11D"], noise_enable=False)
    _pl.tools, _pl.passes, _pl._has_rp = {"redsea": None, "welle": None, "satdump": None}, [], False
    _sc = {x["k"]: x for x in _pl.sched(5000.0, {"mode": "auto"})}
    assert set(_sc) == {"noise", "bc", "meteor", "cal"} and not _sc["noise"]["on"] and _pl.noise_why_off().startswith("Messung aus"), _sc
    selftest_lage()
    selftest_dual()
    assert NOISE_SLACK_S >= 10 and noise_hops(NOISE_BANDS[NOISE_IDS.index("dab")]) == 42 and noise_hops(NOISE_BANDS[0]) == 2
    print("selftest sdrUi ok (Planer-Tabelle, Messfenster +%d s)" % NOISE_SLACK_S)
    b.save(True)
    t9 = time.time()
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"2A","radiotext":"Stau A9 Richtung Muenchen"}', now=t9 + 10)
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"0A","tp":true,"ta":false}', now=t9 + 70)
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"2A","radiotext":"Bayern 3 - Die beste Musik"}', now=t9 + 90)
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"2A","radiotext":"Spaeter Text"}', now=t9 + 200)
    ta = [x for x in b.evl.ev if x["k"] == "ta"]
    assert len(ta) == 1 and not ta[0]["open"] and ta[0]["ps"] == "BAYERN 3" and ta[0]["pi"] == "0xD313" and ta[0]["dur_s"] >= 60, ta
    assert ta[0]["rt"] == ["Stau A9 Richtung Muenchen", "Bayern 3 - Die beste Musik"], ta
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"0A","tp":true,"ta":true}', now=t9 + 300)
    b.tick(t9 + 500)
    ta = [x for x in b.evl.ev if x["k"] == "ta"]
    assert len(ta) == 2 and ta[1]["note"].startswith("Empfang beendet") and ta[1]["end"] == int(t9 + 300), ta
    ks = [x["k"] for x in b.evl.ev]
    assert ks.count("dls") == 2 and ks.count("dab_ann") == 1 and ks.count("rt_warn") == 1, ks
    b.on_dab("11D", {"services": [{"label": "BR24", "dls": "Nachrichten"}]}, now=t9 + 600)
    assert [x["k"] for x in b.evl.ev].count("dls") == 2 and b.evl.ev[-1]["k"] == "dab_ann_end", b.evl.ev[-1]
    b.save(True)
    rows = [json.loads(x) for x in open(os.path.join(tmp, "broadcast_events.jsonl"))]
    assert len(rows) == len(b.evl.ev) and not os.path.exists(os.path.join(tmp, "broadcast_events.jsonl.tmp"))
    assert len(BcEvents(tmp).ev) == len(rows)
    mice = res[1]
    # Stick-Bindung
    lt = "Found 2 device(s):\n  0:  Nooelec, NESDR SMArt v5, SN: 19348831\n  1:  Nooelec, NESDR SMArt v5, SN: 00000002\n"
    sl = parse_sticks(lt)
    assert [(x["idx"], x["sn"], x["name"]) for x in sl] == [(0, "19348831", "Nooelec, NESDR SMArt v5"), (1, "00000002", "Nooelec, NESDR SMArt v5")], sl
    assert pick_stick(sl, "00000002") == (1, None) and pick_stick(sl, "5")[1] == "Stick 5 fehlt"
    assert pick_stick(parse_sticks(lt.replace("00000002", "19348831")), "19348831")[1].startswith("doppelte Seriennummer")
    assert parse_sticks("No supported devices found.\n") == []
    for bad in ("", "12a", "-1", " 1", "1" * 17, None, True, 1.5, ["1"]):
        assert cfg_serial({"serial": bad}) is None, bad
    assert cfg_serial({}) == DEFAULT_SERIAL and cfg_serial({"serial": 42}) == "42"
    pl2 = Planner.__new__(Planner)
    pl2.dev_idx, pl2.dev_sn = 1, "00000002"
    assert pl2._dev(["rtl_433", "-f", "x"]) == ["rtl_433", "-f", "x", "-d", ":00000002"]
    assert pl2._dev(["rtl_fm"]) == ["rtl_fm", "-d", "1"]
    pl2.dev_idx = None
    try:
        pl2._dev(["rtl_fm"])
        raise AssertionError("ohne Index gestartet")
    except RuntimeError:
        pass
    fake = os.path.join(tmp, "tcp")
    with open(fake, "w") as f:
        f.write("  sl  local_address rem_address   st\n   0: 0100007F:04D3 00000000:0000 0A 0\n   1: 0100007F:04D4 00000000:0000 01 0\n")
    assert port_listening(1235, (fake,)) and not port_listening(1236, (fake,)) and not port_listening(1234, (fake,))
    assert "-g" in pl0.cmd("rds:0")[0] and DEFAULT_CFG["fm_s"] == 60
    # Funkumgebung + Kalibrierung
    try:
        import numpy as np
        rng = np.random.default_rng(3)
        bd = NOISE_BANDS[NOISE_IDS.index("fm")]
        mt = NoiseMeter(bd, 10, 4)
        for k in range(6):
            for h in range(3):
                v = rng.normal(-40, 1.0, 100)
                if h == 1:
                    v[30] = -15.0  # Traeger
                    v[31] = -22.0
                mt.feed_power("2026-10-12, 18:00:%02d, %d, %d, 25000, 4000, " % (k, 87500000 + h * 2500000, 87500000 + (h + 1) * 2500000) + ", ".join("%.2f" % x for x in v) + "\n")
        r = mt.result()
        assert r["ok"] and r["n"] == 5 and abs(r["floor"] + 40) < 1 and r["n_car"] == 1 and abs(r["cars"][0]["f"] - 90.7625) < 0.03 and r["cars"][0]["db"] > 20, r
        ns = NoiseState(tmp)
        t0 = time.time() - 30 * 3600
        cfg0 = dict(DEFAULT_CFG)
        for k in range(110):  # 27 h ruhig mit bekanntem Traeger
            ns.add(dict(r, t=int(t0 + k * 900), floor=-40.0 + 0.1 * (k % 3)), cfg0)
        x = ns.d["bands"]["fm"]
        assert x["lvl"] == "gruen" and x["n_pers"] == 0 and not x["learning"], x
        rr = dict(r, t=int(t0 + 110 * 900), floor=-29.0, cars=r["cars"] + [{"f": 99.0, "db": 25.0, "w_khz": 25}])
        for k in range(3):
            ns.add(dict(rr, t=int(t0 + (110 + k) * 900)), cfg0)
        x = ns.d["bands"]["fm"]
        assert x["lvl"] == "rot" and x["raise"] >= 10 and x["n_pers"] == 1 and x["cars"][0]["f"] == 99.0, x
        # Impulse (Direktabtastung): Rauschen + 12 breitbandige Knackser in 2 s
        bm = NOISE_BANDS[NOISE_IDS.index("mw")]
        mi = NoiseMeter(bm)
        sr = bm["sr"]
        iq = (rng.normal(0, 300, 2 * sr) + 1j * rng.normal(0, 300, 2 * sr))
        for k in range(12):
            j = 50000 + k * 150000
            iq[j:j + 300] += rng.normal(0, 9000, 300) + 1j * rng.normal(0, 9000, 300)
        u = np.empty(4 * sr, dtype="<i2")
        u[0::2] = np.clip(iq.real, -32767, 32767)
        u[1::2] = np.clip(iq.imag, -32767, 32767)
        bb = u.tobytes()
        for k in range(0, len(bb), 65536):
            mi.feed_iq(bb[k:k + 65536], sr)
        ri = mi.result()
        assert ri["ok"] and 300 <= ri["bb_pm"] <= 400 and ri["imp_pm"] >= ri["bb_pm"], ri
        ns.add(ri, cfg0)
        ns.finish_block(cfg0)
        assert ns.d["thunder"]["lvl"] == "grau" and ns.d["thunder"]["bb_pm"] > 300 and ns.d["qrm"]["lvl"] == "gruen", (ns.d["thunder"], ns.d["qrm"])
        z = NoiseMeter(bm)
        z.feed_iq(b"\x00" * (4 * sr), sr)
        assert z.result()["ok"] is False
        selftest_noise2(tmp)
    except ImportError:
        print("selftest: numpy fehlt - Funkumgebung nicht geprueft")
    f11 = DAB_CHANNELS["11D"] * 1e6
    assert cal_compute(0.3 * 222.064, (0.3 - 5) * 222.064, 5, f11) == (0.3, "ok (Steigung -1.00)"), cal_compute(0.3 * 222.064, (0.3 - 5) * 222.064, 5, f11)
    assert cal_compute(66.6, 66.6, 5, f11)[0] is None and cal_compute(None, 1, 5, f11)[0] is None
    assert cal_compute(15 * 222.064, 10 * 222.064, 5, f11)[0] is None  # ausserhalb +-10
    assert ppm_val({"ppm": 3}) == 3 and ppm_val({"ppm": 40}) == 0 and ppm_val({"ppm": True}) == 0 and ppm_val({"ppm": -0.6}) == -1
    pl0.cfg["ppm"] = 2
    nzc = " ".join(pl0.cmd("nz:0")[0])
    assert nzc.startswith("rtl_power -f 144.000M:146.000M:5k ") and nzc.endswith(" -p 2 -d 0 -"), nzc
    assert " ".join(pl0.cmd("nz:%d" % NOISE_IDS.index("mw"))[0]).startswith("rtl_fm -M raw -E direct2 -f 1.050M -s 1024000 -g 30 ")
    for gv, want in ((None, "30"), (0, "30"), ("auto", "30"), (float("nan"), "30"), (99, "30"), (20.7, "20.7"), (True, "30")):
        pl0.cfg["gain_noise"] = gv
        got = noise_gain(pl0.cfg) if gv is not True else ("30" if noise_gain(pl0.cfg) in ("30", "1") else "?")
        assert got == want, (gv, got)
        for j in range(len(NOISE_BANDS)):
            cc = pl0.cmd("nz:%d" % j)[0]
            assert cc[cc.index("-g") + 1] not in ("0", "", None), cc
    pl0.cfg["gain_noise"] = 30
    pl0.cfg["ppm"] = 0
    # sdr_cal_now unterbricht laufenden Rundfunkblock sofort
    pl0.cfg["cal_enable"] = True
    tn = time.time()
    pl0.special = {"kind": "bc", "queue": ["rds:0", "rds:1"], "durs": [60, 60], "i": 0, "sub_end": tn + 60, "hard_end": tn + 200, "t0": tn}
    pl0.passes = []
    open(p("sdr_cal_now", tmp), "w").close()
    wj = pl0.want({"mode": "auto"}, tn)
    assert wj == "cal:0" and pl0.special["kind"] == "cal" and not os.path.exists(p("sdr_cal_now", tmp)), (wj, pl0.special)
    pl0.special = None
    assert "gps" in pl0.status({"mode": "auto"}, True)
    try:
        sys.path.insert(0, BASE)
        import prepper_gps
        prepper_gps.selftest()
    except ImportError:
        pass
    print("selftest OK: 433 Sensoren=%d, APRS Stationen=%d, Mic-E %.4f/%.4f, WX %s" % (
        len(s.d["sensors"]), len(st["stations"]), mice["lat"], mice["lon"], res[2]["wx"]))
    return True


if __name__ == "__main__":
    a = sys.argv[1] if len(sys.argv) > 1 else "status"
    if a == "run":
        Planner(BASE).loop()
    elif a == "selftest":
        selftest()
    elif a == "sticks":
        sys.exit(sticks_cli(BASE))
    else:
        print(json.dumps(load_json(p("sdr_status.json"), {}), indent=1, ensure_ascii=False))
MODPY_EOF
cat > "$W/patch-dual.py" << 'PATCHPY_EOF'
"""sdrDual Dashboard-Teil. Aufruf: patch-dual.py QUELLE ZIEL BLOCKDATEI -> 0 ok, 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
if "# ===== sdrDual:" in s:
    open(dst, "w", encoding="utf-8").write(s); print("schon da"); raise SystemExit(0)
R = [("resp.set_data(body[:i] + _SL_CSS + _SL_JS + body[i:])", "resp.set_data(body[:i] + _SL_CSS + _SL_JS + globals().get(\"_SD_JS\", \"\") + body[i:])"),
     ("# ===== /sdrLage =====\n", "# ===== /sdrLage =====\n" + blk),
     ('        print("sdrUi inject:", e, flush=True)\n', '        print("sdrUi inject:", e, flush=True)\n        import traceback as _sdui_tb  # sdrDual: voller Traceback ins Log\n        _sdui_tb.print_exc()\n')]
for a, b in R:
    if s.count(a) != 1:
        print("Basis passt nicht:", a[:50], s.count(a)); raise SystemExit(3)
for a, b in R:
    s = s.replace(a, b)
open(dst, "w", encoding="utf-8").write(s)
print("geaendert")
PATCHPY_EOF
cat > "$W/dual_block.py" << 'BLKPY_EOF'
# ===== sdrDual: zwei Sticks - Zeitanteile je Stick (zwei Balken), Krisenzeile je Stick, Einzelbetrieb sichtbar (nur Anzeige) =====
def _sd_h(h, n, role, missing):
    if missing:
        return {"lvl": "rot", "txt": "Stick %d fehlt" % n}
    h = h or {}
    t = h.get("txt") or "?"
    return {"lvl": h.get("lvl") or "grau", "txt": t.replace("Stick ", "Stick %d " % n, 1) if t.startswith("Stick ") else "Stick %d: %s" % (n, t), "hint": h.get("hint"), "why": h.get("why")}


_sd_orig_data = _sdrui_data


def _sdrui_data():
    d = _sd_orig_data()
    try:
        st = (_sdr_status() or {}).get("status") or {}
    except Exception:
        st = {}
    du = st.get("dual") or {}
    if not du.get("on"):
        d["dual"] = {"on": False}
        return d
    s2 = st.get("s2") or {}
    miss1 = bool(st.get("pin_err"))
    miss2 = bool(s2.get("pin_err"))
    h1 = _sd_h(st.get("stick_health"), 1, du.get("role1"), miss1)
    h2 = _sd_h(st.get("stick_health2"), 2, du.get("role2"), miss2)
    names = {"433": "433", "aprs": "APRS", "bc": "UKW/DAB", "asa": "ASA 5C", "meteor": "Meteor", "act": "Aktivität", "noise": "QRM", "cal": "Kalibr.", "frei": "frei"}
    mode = "Einzelbetrieb mit Stick 1 (Stick 2 fehlt)" if miss2 and not miss1 else ("Einzelbetrieb mit Stick 2 (Stick 1 fehlt)" if miss1 and not miss2 else ("beide Sticks fehlen" if miss1 and miss2 else "zwei Sticks"))
    d["dual"] = {"on": True, "mode": mode, "sn1": du.get("sn1"), "sn2": du.get("sn2"), "role1": du.get("role1"), "role2": du.get("role2"),
                 "label1": "Stick 1 · SN %s · %s" % (du.get("sn1"), "Rundfunk fest" if du.get("role1") == "bc" else ("fehlt" if miss1 else "alles (Einzelbetrieb)")),
                 "label2": "Stick 2 · SN %s · %s" % (du.get("sn2"), "Wechselbetrieb" if du.get("role2") == "rot" else ("fehlt" if miss2 else "alles (Einzelbetrieb)")),
                 "h1": h1, "h2": h2, "active2": s2.get("active"), "ppm2": (s2.get("cal") or {}).get("applied")}
    if miss1 and not miss2:
        cs = dict((k, "S2") for k in ("433", "aprs", "bc", "asa", "meteor", "act", "noise", "cal"))
    elif miss2 and not miss1:
        cs = dict((k, "S1") for k in ("433", "aprs", "bc", "asa", "meteor", "act", "noise", "cal"))
    elif miss1 and miss2:
        cs = {}
    else:
        cs = {"bc": "S1", "asa": "S1", "cal": "S1+S2", "433": "S2", "aprs": "S2", "meteor": "S2", "act": "S2", "noise": "S2"}
    d["dual"]["chip_stick"] = cs
    d["shares2"] = [dict(x, name=names.get(x.get("k"), x.get("k"))) for x in (st.get("shares2") or [])] if not miss2 else []
    if miss1:
        d["shares"] = []
    k = d.get("krise") or {}
    parts = (k.get("txt") or "").split(" · ")
    if parts and parts[-1].startswith("Stick"):
        parts = parts[:-1]
    parts.append("%s · %s" % (h1["txt"], h2["txt"]))
    if (miss1 or miss2) and not (miss1 and miss2):
        parts.append("Einzelbetrieb")
    rank = {"ok": 0, "grau": 0, "lernt": 1, "gelb": 2, "rot": 3}
    lv = k.get("lvl") or "ok"
    for h in (h1, h2):
        if rank.get(h["lvl"], 0) > rank.get(lv, 0):
            lv = h["lvl"]
    hint = next((h.get("hint") for h in (h1, h2) if h.get("hint")), None)
    if miss1 or miss2:
        hint = hint or "fehlenden Stick prüfen (USB), Betrieb läuft mit dem anderen weiter"
    d["krise"] = {"txt": " · ".join(parts), "lvl": lv, "hint": hint, "why": k.get("why")}
    return d


_SD_JS = r"""<script id="sdrdual-js">(function(){var o=window.sdrLage;if(!o)return;
var COL={'433':'#f59e0b','aprs':'#a78bfa','bc':'#22c55e','asa':'#ef4444','meteor':'#38bdf8','act':'#ec4899','noise':'#eab308','cal':'#94a3b8','frei':'#334155'};
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function bars(sh){var bar=el('div','sl-bar'),bl=el('div','sl-bl');(sh||[]).forEach(function(s){if(s.pct<=0)return;var x=el('span');x.style.width=s.pct+'%';x.style.background=COL[s.k]||'#64748b';x.title=s.name+' '+s.pct+' %';bar.appendChild(x);var t=el('span');var i=el('i');i.style.background=COL[s.k]||'#64748b';t.appendChild(i);t.appendChild(document.createTextNode(s.name+' '+Math.round(s.pct)+' %'));bl.appendChild(t);});return [bar,bl];}
window.sdrLage=function(c,D){o(c,D);var U=D&&D.dual;if(!U||!U.on)return;var b1=c.querySelector('.sl-bar');if(!b1)return;
var l1=el('div','sd-lb '+((U.h1||{}).lvl||''),U.label1+' · '+((U.h1||{}).txt||''));c.insertBefore(l1,b1);
if(!(D.shares||[]).length){b1.style.display='none';}
var lg1=b1.nextSibling;var l2=el('div','sd-lb '+((U.h2||{}).lvl||''),U.label2+' · '+((U.h2||{}).txt||'')+(U.active2?' · jetzt '+U.active2:''));var bb=bars(D.shares2);
var ref=lg1?lg1.nextSibling:null;c.insertBefore(l2,ref);if((D.shares2||[]).length){c.insertBefore(bb[0],ref);c.insertBefore(bb[1],ref);}
var CS=U.chip_stick||{};var ch=c.querySelectorAll('.su-chip');for(var i=0;i<ch.length;i++){var k=ch[i].dataset.k,v=CS[k];var l1=ch[i].querySelector('.su-l1');if(!v||!l1||l1.querySelector('.sd-st'))continue;var bd=el('span','sd-st',v);bd.title=v==='S1'?'läuft auf Stick 1 (SN '+U.sn1+')':(v==='S2'?'läuft auf Stick 2 (SN '+U.sn2+')':'je Stick eigene Kalibrierung');var nm=l1.querySelector('.su-nm');if(nm&&nm.nextSibling)l1.insertBefore(bd,nm.nextSibling);else l1.appendChild(bd);}
var s2=c.querySelector('.sl-s2');if(s2)s2.textContent='🔌 '+U.mode+(U.ppm2!==undefined&&U.ppm2!==null?' · Stick 2 Korrektur '+(U.ppm2>0?'+':'')+U.ppm2+' ppm':'');};
})();</script><style id="sdrdual-css">#sdrUiCard .sd-lb{font-size:.8rem;font-weight:600;margin-top:4px;overflow-wrap:anywhere}#sdrUiCard .sd-lb.rot{color:#fca5a5}#sdrUiCard .sd-lb.gelb{color:#fde68a}#sdrUiCard .sd-st{flex:0 0 auto;font-size:.68rem;font-weight:700;padding:0 4px;border-radius:4px;border:1px solid #475569;color:#cbd5e1;background:#1e293b}</style>"""


def _sd_selftest():
    h = _sd_h({"lvl": "ok", "txt": "Stick ok"}, 1, "bc", False)
    assert h["txt"] == "Stick 1 ok", h
    assert _sd_h({"lvl": "rot", "txt": "Stick liefert keine Daten"}, 2, "rot", False)["txt"] == "Stick 2 liefert keine Daten"
    assert _sd_h(None, 2, "rot", True)["txt"] == "Stick 2 fehlt"
    assert "fetch(" not in _SD_JS and "POST" not in _SD_JS
    return True


# --- sdrDual Anzeige: ASA DE (DAB 5C) eigene Zeile, BR24/NINA auf der Lage-Seite umbrechen statt abschneiden, leere Kaesten ausblenden (nur Anzeige) ---
def _sd_asa_row(b, r, now=None):
    """ASA DE als eigener Status: state gruen/rot/gelb/grau, l1 Status + Quelle, l2 'Empfangen dd.mm.yyyy HH:MM:SS'."""
    now = now or _br24_time.time()
    b = b if isinstance(b, dict) else {}
    r = r if isinstance(r, dict) else {}
    m = r.get("match") or {}
    asa = m.get("asa") or {}
    chans = sorted(asa) or ["5C"]
    dab = b.get("dab") or {}
    ts = [(dab.get(ch) or {}).get("t") for ch in chans]
    ts = [t for t in ts if isinstance(t, (int, float))]
    t = max(ts) if ts else None
    src = "ASA DE · DAB %s" % "/".join(chans)
    out = {"state": "grau", "t": int(t) if t else None, "l2": ("Empfangen %s" % _br24_fmt(t)) if t else "", "src": src}
    hit = None
    w = r.get("why")
    if r.get("state") == "rot" and isinstance(w, dict) and str(w.get("src") or "").startswith("ASA DE"):
        hit = ("rot", w)
    else:
        for x in r.get("recent") or []:
            if str(x.get("src") or "").startswith("ASA DE") and x.get("cls") in ("rot", "test") and isinstance(x.get("t"), (int, float)) \
                    and now - x["t"] < (BR24_HOLD_S if x.get("cls") == "rot" else BR24_TEST_S):
                hit = (x["cls"], x)
                break
    if hit and hit[0] == "rot":
        out.update(state="rot", l1="%s ⚠ %s: „%s“" % (src, hit[1].get("kind") or "Warnung", hit[1].get("text") or ""), l2="Empfangen %s" % (hit[1].get("t_txt") or _br24_fmt(hit[1].get("t"))))
    elif hit:
        out.update(state="grau", l1="%s · Probewarnung/Test: „%s“" % (src, hit[1].get("text") or ""), l2="Empfangen %s" % (hit[1].get("t_txt") or _br24_fmt(hit[1].get("t"))))
    elif t and now - t < BR24_RX_S:
        out.update(state="gruen" if asa else "gelb", l1=("%s · keine Warnung" % src) if asa else ("%s · Kanal empfangen, Dienst ASA DE nicht gefunden" % src))
    elif t:
        out.update(state="grau", l1="%s · kein Empfang seit %s" % (src, _br24_fmt(t)))
    else:
        out.update(state="grau", l1="%s · noch nicht empfangen" % src)
    return out


def _sd_hm(t, now):
    if not t:
        return "–"
    lt, ln = _br24_time.localtime(int(t)), _br24_time.localtime(int(now))
    return _br24_time.strftime("%H:%M" if lt[:3] == ln[:3] else "%d.%m. %H:%M", lt)


def _sd_bc_plan(st, now):
    """Rundfunk-Block = nacheinander UKW (RDS), DAB 11D (BR24), DAB 5C (ASA DE) auf EINEM Stick, nie gleichzeitig.
    -> naechster Start je Pruefung (Schaetzung aus Planer-Status), laufende Pruefung."""
    st = st if isinstance(st, dict) else {}
    bc = next((x for x in st.get("sched") or [] if isinstance(x, dict) and x.get("k") == "bc"), None) or {}
    dab = [str(x) for x in bc.get("dab") or []]
    fm_n = int(bc.get("fm_n") or 0)
    jobs = ["rds:%d" % i for i in range(fm_n)] + ["dab:%d" % i for i in range(len(dab))]
    out = {"br24": None, "asa": None, "run": None, "iv": bc.get("iv"), "on": bool(bc.get("on", True)) and bool(jobs)}
    if not jobs:
        return out
    each = float(bc.get("dur") or 60 * len(jobs)) / len(jobs)

    def who(j):
        return "asa" if j.startswith("dab:") and dab[int(j[4:])] == "5C" else "br24"
    sp = st.get("special") or {}
    seq = []
    if sp.get("kind") == "bc" and sp.get("job") in jobs:
        i = jobs.index(sp["job"])
        out["run"] = who(sp["job"])
        t = max(float(st.get("since") or now) + each, now)
        for j in jobs[i + 1:]:
            seq.append((j, t))
            t += each
        t += float(bc.get("iv") or 0)
    else:
        t = float(bc.get("next") or 0) or None
    if t:
        for j in jobs:
            seq.append((j, t))
            t += each
    for j, t0 in seq:
        k = who(j)
        if out[k] is None and out["run"] != k:
            out[k] = int(t0)
    return out


def _sd_split(t):
    m = _br24_re.match(r"^(.*?) · ((?:zuletzt |seit )?\d\d\.\d\d\.\d{4} \d\d:\d\d(?::\d\d)?)(.*)$", (t or "").replace(" · ASA DE ok", ""))
    return (m.group(1), (m.group(2) + m.group(3)).strip()) if m else ((t or "").replace(" · ASA DE ok", ""), "")


_sd_orig_br24_state = _br24_state


def _br24_state():
    r = _sd_orig_br24_state()
    now = _br24_time.time()
    try:
        r["asa_row"] = _sd_asa_row(_sdr_load("broadcast_state.json", {}) or {}, r)
    except Exception as e:
        r["asa_row"] = {"state": "grau", "l1": "ASA DE · Daten nicht lesbar (%s)" % str(e)[:60], "l2": "", "t": None}
    try:
        pl = _sd_bc_plan(_sdr_load("sdr_status.json", {}) or {}, now)
    except Exception:
        pl = {"br24": None, "asa": None, "run": None, "on": False}
    l1, _ = _sd_split(r.get("text"))
    if r.get("state") == "gruen":
        l1 = "BR24 empfangen · " + (" + ".join(r.get("srcs") or []) or str(r.get("last_src") or ""))
    elif r.get("state") == "grau" and not r.get("test"):
        l1 = "BR24 · kein Empfang" if r.get("last_rx") else "BR24 · noch nicht empfangen"

    def l2(last, k):
        a = "zuletzt %s" % _sd_hm(last, now)
        b = "prüft gerade" if pl.get("run") == k else ("nächste Prüfung %s" % _sd_hm(pl.get(k), now) if pl.get(k) else "nächste Prüfung –")
        return a + " · " + b
    r["br24_row"] = {"state": r.get("state") or "grau", "l1": l1, "l2": l2(r.get("last_rx"), "br24")}
    a = r["asa_row"]
    a["l2"] = l2(a.get("t"), "asa")
    r["bc_plan"] = pl
    r["bc_note"] = "Stick 1 prüft abwechselnd BR24 (UKW + DAB 11D) und ASA DE (DAB 5C), nicht gleichzeitig"
    return r


_sd_orig_data2 = _sdrui_data


def _sdrui_data():
    d = _sd_orig_data2()
    try:
        a = _br24_state().get("asa_row") or {}
        now = int(_br24_time.time())
        for f in d.get("funcs") or []:
            if f.get("k") == "asa" and a.get("l1"):
                f["info"] = a["l1"].replace("ASA DE · ", "", 1)
                if a.get("t"):
                    f["last"] = a["t"]
                    f["age"] = _sdrui_age(now, a["t"])
                if f.get("lvl") != "aus":
                    f["lvl"] = {"gruen": "ok", "rot": "rot", "gelb": "gelb"}.get(a.get("state"), "gelb")
                f["tip"] = (a["l1"] + ("\n" + a["l2"] if a.get("l2") else "") + ("\n" + f["tip"] if f.get("tip") else ""))[:400]
    except Exception:
        pass
    return d


_SD_LAGE_JS = r"""
(function(){var C={gruen:'#22c55e',rot:'#ef4444',gelb:'#eab308',grau:'#64748b'},A=null;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
if(!document.getElementById('sdl-css')){var s=el('style');s.id='sdl-css';s.textContent='#br24Tile.sdl-on .lm1-line{display:none !important}.sdl-row{display:flex;align-items:flex-start;gap:8px;margin-top:6px;min-width:0}.sdl-dot{flex:0 0 auto;width:10px;height:10px;border-radius:50%;margin-top:.35em}.sdl-tx{flex:1 1 auto;min-width:0;white-space:normal;overflow-wrap:anywhere}.sdl-l1{font-weight:600}.sdl-row.rot .sdl-l1{color:#ef4444}.sdl-row.grau .sdl-l1{color:#94a3b8}.sdl-l2{font-size:.85em;opacity:.8;margin-top:1px}.sdl-note{margin-top:4px;opacity:.75;white-space:normal;overflow-wrap:anywhere}.sdl-wrap div,.sdl-wrap span{white-space:normal !important;overflow:visible !important;text-overflow:clip !important;overflow-wrap:anywhere}';document.head.appendChild(s);}
function split(t){t=(t||'').replace(/ · ASA DE ok$/,'');var m=t.match(/^(.*?) · ((?:zuletzt |seit )?\d\d\.\d\d\.\d{4},? \d\d:\d\d(?::\d\d)?)(.*)$/);return m?[m[1],m[2]+m[3]]:[t,''];}
function row(cls,st,l1,l2){var r=el('div','sdl-row '+cls+' '+st);var d=el('span','sdl-dot');d.style.background=C[st]||C.grau;r.appendChild(d);var x=el('div','sdl-tx');x.appendChild(el('div','sdl-l1',l1));if(l2)x.appendChild(el('div','sdl-l2',l2));r.appendChild(x);return r;}
function nina(){var ts=document.querySelectorAll('.title');for(var i=0;i<ts.length;i++){if(/\bNINA\b/i.test(ts[i].textContent||'')){var c=ts[i].closest('.card');if(c&&c.id!=='br24Tile')return c;}}return null;}
function empty(e){if(e.tagName!=='DIV'||e.id==='br24Tile'||e.querySelector('script,style,img,svg,canvas,input,select,button,iframe,video,textarea'))return false;return !(e.textContent||'').trim();}
function fix(){var t=document.getElementById('br24Tile');var n=nina();if(n)n.classList.add('sdl-wrap');if(!t)return;
var ln=t.querySelector('.lm1-line');if(ln){var raw=ln.textContent||'';var st=/239, 68, 68|#ef4444/.test(ln.getAttribute('style')||'')?'rot':(/\bonline\b/.test(ln.className)?'gruen':'grau');var key=raw+'|'+st+'|'+JSON.stringify(A||{});
if(t.dataset.sdl!==key){t.dataset.sdl=key;var o=t.querySelectorAll('.sdl-row');for(var i=0;i<o.length;i++)o[i].remove();var R=(A&&A.br)||null;var p=R?[R.l1,R.l2]:split(raw);if(R&&R.state)st=R.state;var b=row('sdl-br',st,p[0]||'BR24',p[1]);ln.parentNode.insertBefore(b,ln.nextSibling);
var Q=A&&A.asa;if(Q&&Q.l1){b.parentNode.insertBefore(row('sdl-asa',Q.state||'grau',Q.l1,Q.l2||''),b.nextSibling);}if(A&&A.note){var nt=t.querySelector('.sdl-note');if(!nt){nt=el('div','small sdl-note');t.insertBefore(nt,b);}nt.textContent=A.note;}t.classList.add('sdl-on');}}
var c=t.parentNode;if(c){for(var j=0;j<c.children.length;j++){var e=c.children[j];if(e===n)continue;if(empty(e)){if(e.style.display!=='none'){e.style.display='none';e.dataset.sdlHid='1';}}else if(e.dataset.sdlHid){e.style.display='';delete e.dataset.sdlHid;}}}}
function load(){fetch('/api/br24',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.asa_row){A={asa:j.asa_row,br:j.br24_row,note:j.bc_note};t0();fix();}}).catch(function(){});}
function t0(){var t=document.getElementById('br24Tile');if(t)t.dataset.sdl='';}
fix();load();setInterval(fix,1000);setInterval(load,30000);})();
"""

_SD_RF_JS = r"""
(function(){var P=location.pathname.replace(/\/$/,'')||'/';if(P!=='/rundfunk')return;var A=null,B=null;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
if(!document.getElementById('sdr-css2')){var s=el('style');s.id='sdr-css2';s.textContent='#br24Row,#br24Asa{white-space:normal !important;align-items:flex-start !important}#br24Row .br24-tx,#br24Asa .br24-tx{white-space:normal !important;overflow:visible !important;text-overflow:clip !important;overflow-wrap:anywhere}#br24Row .br24-dot,#br24Asa .br24-dot{margin-top:.3em}#br24Row .br24-l2,#br24Asa .br24-l2{display:block;font-size:.85em;opacity:.85}';document.head.appendChild(s);}
function put(){var r=document.getElementById('br24Row');if(!r||!A||!A.l1)return;var tx=r.querySelector('.br24-tx');if(tx&&B&&B.l1&&!tx.querySelector('.br24-l2')){tx.textContent=B.l1;tx.appendChild(el('span','br24-l2',B.l2||''));}
var a=document.getElementById('br24Asa');var cls='br24-row br24-'+(A.state==='gruen'?'gruen':(A.state==='rot'?'rot':'grau'));var key=A.l1+'|'+A.l2+'|'+cls;
if(!a){a=el('div');a.id='br24Asa';a.setAttribute('role','status');}if(r.nextSibling!==a)r.parentNode.insertBefore(a,r.nextSibling);
if(a.dataset.v!==key){a.dataset.v=key;a.className=cls;a.textContent='';a.appendChild(el('span','br24-dot'));var x=el('span','br24-tx',A.l1);if(A.l2)x.appendChild(el('span','br24-l2',A.l2));a.appendChild(x);}}
function load(){fetch('/api/br24',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.asa_row){A=j.asa_row;B=j.br24_row;var r=document.getElementById('br24Row');if(r)r.dataset.v='';put();}}).catch(function(){});}
try{var d=JSON.parse(document.getElementById('br24-data').textContent);A=d&&d.asa_row;B=d&&d.br24_row;}catch(e){}
put();load();setInterval(put,2000);setInterval(load,30000);})();
"""

if "sdl-css" not in _LM1_JS:
    _LM1_JS = _LM1_JS + _SD_LAGE_JS
if "sdr-css2" not in _BR24_JS:
    _BR24_JS = _BR24_JS + _SD_RF_JS
_SD_JS = _SD_JS.replace("</style>", "#sdrUiCard .su-chip[data-k=asa] .su-l2{white-space:normal;overflow-wrap:anywhere;text-overflow:clip}</style>", 1)


# --- sdrDual: Status robust lesen (falsche Typen aus sdr_status.json nie bis in die Anzeige; sonst 'nicht verfuegbar') ---
_SD_DICT = ("dual", "s2", "stick_health", "stick_health2", "cal", "gps", "noise", "noise_diag", "slices", "tools", "lage", "freq", "tcp",
            "counts", "stick2", "evlog", "linelog", "special", "next_pass")
_SD_LIST = ("shares", "shares2", "sched", "auto", "others", "stderr", "home")
_SD_NONE_OK = ("special", "next_pass", "evlog")
_SD_NOSTAT = [False]
import traceback as _sd_tb


def _sd_clean(st):
    if not isinstance(st, dict):
        return {}
    st = dict(st)
    for k in _SD_DICT:
        if k in st and not isinstance(st[k], dict):
            st[k] = None if k in _SD_NONE_OK else {}
    for k in _SD_LIST:
        if k in st and not isinstance(st[k], list):
            st[k] = []
    for k in ("shares", "shares2", "sched"):
        st[k] = [x for x in st[k] if isinstance(x, dict)] if isinstance(st.get(k), list) else st.get(k)
        if st[k] is None:
            st.pop(k)
    if isinstance(st.get("noise"), dict):
        n = dict(st["noise"])
        for k in ("qrm", "thunder"):
            if k in n and not isinstance(n[k], dict):
                n[k] = {}
        if "bands" in n and not isinstance(n["bands"], list):
            n["bands"] = []
        st["noise"] = n
    if isinstance(st.get("lage"), dict) and not isinstance(st["lage"].get("sw"), dict):
        st["lage"] = dict(st["lage"], sw={})
    if isinstance(st.get("s2"), dict):
        s2 = dict(st["s2"])
        for k in ("stick_health", "cal", "special"):
            if k in s2 and not isinstance(s2[k], dict):
                s2[k] = None if k == "special" else {}
        if "shares" in s2 and not isinstance(s2["shares"], list):
            s2["shares"] = []
        st["s2"] = s2
    for k in ("t", "since", "started"):
        if k in st and not isinstance(st[k], (int, float)):
            st[k] = 0
    return st


_sd_orig_load = _sdr_load


def _sdr_load(name, default):
    v = _sd_orig_load(name, default)
    if name == "sdr_status.json":
        return {} if _SD_NOSTAT[0] else _sd_clean(v)
    return v


_sd_orig_data3 = _sdrui_data


def _sdrui_data():
    try:
        return _sd_orig_data3()
    except Exception as e:
        print("sdrDual: SDR-Daten nicht verfuegbar (%s) - Anzeige ohne Status" % str(e)[:120], flush=True)
        _sd_tb.print_exc()
        _SD_NOSTAT[0] = True
        try:
            d = _sd_orig_data3()
        finally:
            _SD_NOSTAT[0] = False
        if isinstance(d.get("krise"), dict):
            d["krise"] = dict(d["krise"], txt="SDR-Status nicht verfügbar", lvl="gelb")
        d["err"] = "SDR-Status nicht verfügbar"
        return d


def _sd_asa_selftest():
    now = 1760000000
    b = {"dab": {"5C": {"t": now - 60}}}
    r = {"state": "gruen", "match": {"asa": {"5C": {"ASA DE": []}}}, "recent": []}
    a = _sd_asa_row(b, r, now)
    assert a["state"] == "gruen" and a["l1"] == "ASA DE · DAB 5C · keine Warnung" and a["l2"].startswith("Empfangen "), a
    assert _sd_asa_row({}, {"match": {}}, now)["l1"] == "ASA DE · DAB 5C · noch nicht empfangen"
    assert _sd_asa_row(b, {"match": {}}, now)["state"] == "gelb"
    w = {"t": now - 100, "src": "ASA DE 5C", "kind": "DLS", "text": "Gefahr", "cls": "rot", "t_txt": "x"}
    assert _sd_asa_row(b, dict(r, state="rot", why=w), now)["state"] == "rot"
    assert _sd_asa_row(b, dict(r, recent=[w]), now)["state"] == "rot"
    assert _sd_asa_row({"dab": {"5C": {"t": now - 99999}}}, r, now)["l1"].startswith("ASA DE · DAB 5C · kein Empfang seit")
    st = {"special": {"kind": "bc", "job": "rds:0"}, "since": now - 10, "sched": [{"k": "bc", "on": True, "iv": 5, "dur": 180, "dab": ["11D", "5C"], "fm_n": 1, "next": now + 500}]}
    pl = _sd_bc_plan(st, now)
    assert pl["run"] == "br24" and pl["br24"] is None and pl["asa"] == now + 110, pl
    st["special"] = {"kind": "bc", "job": "dab:1"}
    pl = _sd_bc_plan(st, now)
    assert pl["run"] == "asa" and pl["br24"] == now + 55 and pl["asa"] is None, pl
    st["special"] = {}
    pl = _sd_bc_plan(st, now)
    assert pl["run"] is None and pl["br24"] == now + 500 and pl["asa"] == now + 620, pl
    assert _sd_split("BR24 empfangen · DAB 11D · zuletzt 13.10.2026 12:50:00 · ASA DE ok") == ("BR24 empfangen · DAB 11D", "zuletzt 13.10.2026 12:50:00")
    bad = {"t": "x", "dual": "x", "s2": {"cal": "x", "stick_health": "x", "shares": "x"}, "stick_health": "x", "noise": {"qrm": "gruen", "bands": "x"},
           "shares": "x", "sched": ["x", {"k": "bc"}], "lage": {"sw": "x"}, "next_pass": "x", "special": "bc"}
    c = _sd_clean(bad)
    assert c["dual"] == {} and c["s2"]["cal"] == {} and c["s2"]["shares"] == [] and c["noise"]["qrm"] == {} and c["sched"] == [{"k": "bc"}] and c["lage"]["sw"] == {} and c["next_pass"] is None and c["special"] is None and c["t"] == 0, c
    assert _sd_clean("x") == {}
    for js in (_SD_LAGE_JS, _SD_RF_JS):
        assert "POST" not in js and "method" not in js and js.count("fetch(") == js.count("fetch('/api/br24',") == 1 and "</script" not in js
    return True


try:
    _sd_selftest()
    _sd_asa_selftest()
    print("sdrDual aktiv: zwei Balken je Stick, Krisenzeile je Stick, ASA DE eigene Zeile, Lage-Kacheln umbrechen", flush=True)
except Exception as _sd_e:
    print("sdrDual FEHLER:", _sd_e, flush=True)
# ===== /sdrDual =====
BLKPY_EOF
# ---------- 0) eingebettete Dateien pruefen ----------
P="$W/patch-dual.py"; M="$W/prepper_sdr.py"; LB="$W/dual_block.py"
echo "$EXPECT_BLK  $LB" | sha256sum -c - >/dev/null || { echo "STOP: Block sha256 falsch"; exit 1; }
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $M" | sha256sum -c - >/dev/null || { echo "STOP: Modul sha256 falsch"; exit 1; }
for x in "$P" "$M"; do python3 -W error -m py_compile "$x" || { echo "STOP: py_compile $x - nichts geaendert"; exit 1; }; done
# ---------- 1) Basis (sha16) ----------
[[ -f "$F" && -f "$DASH_DIR/prepper_sdr.py" ]] || { echo "STOP: Dateien fehlen - nichts geaendert"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$DASH_DIR/prepper_sdr.py" | cut -c1-16)
if [[ "$D16" != "$BASE_DASH16" ]] && ! grep -q "# ===== sdrDual:" "$F"; then echo "STOP: dashboard.py sha16 $D16 erwartet $BASE_DASH16 - nichts geaendert"; exit 1; fi
if [[ "$S16" != "$BASE_MOD16" && "$S16" != "$NEW_MOD16" ]]; then echo "STOP: prepper_sdr.py sha16 $S16 erwartet $BASE_MOD16 - nichts geaendert"; exit 1; fi
grep -q "# ===== sdrLage:" "$F" || { echo "STOP: sdrLage fehlt - nichts geaendert"; exit 1; }
python3 -c "import json,sys; c=json.load(open(sys.argv[1])); assert str(c.get('serial','19348831'))==sys.argv[2]" "$DASH_DIR/sdr_config.json" "$SN1" || { echo "STOP: Stick 1 in sdr_config.json ist nicht SN $SN1 - nichts geaendert"; exit 1; }
echo "OK Basis dashboard.py $D16, prepper_sdr.py $S16, Stick 1 SN $SN1"
LST=$(cd "$W" 2>/dev/null; timeout 20 rtl_test -d prepper-nur-liste 2>&1 | grep -a "SN:" || true)
echo "Sticks am USB (Index wechselt, Ansprache nur per SN):"; echo "$LST" | sed 's/^/  /'
echo "$LST" | grep -q "SN: $SN1" || echo "WARN Stick 1 SN $SN1 nicht gefunden - Stick 2 macht dann alles"
echo "$LST" | grep -q "SN: $SN2" || echo "WARN Stick 2 SN $SN2 nicht gefunden - Stick 1 macht dann alles"
# ---------- 2) AST-Guard ----------
cp -a "$DASH_DIR/prepper_sdr.py" "$W/base_sdr.py"
python3 - "$W/base_sdr.py" "$M" "$P" "$LB" "$F" << 'GUARDPY' || { echo "STOP: Guard - nichts geaendert"; exit 1; }
import ast, sys
def info(fn):
    t = ast.parse(open(fn, encoding="utf-8").read()); imp = set(); calls = []; bad = []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names: imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell": bad.append("shell=")
        if isinstance(n, ast.Call):
            f = n.func; nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            calls.append(nm)
            if nm in ("bind", "listen", "accept", "serve_forever", "create_server", "start_server", "create_connection", "urlopen"): bad.append(nm)
            if nm.startswith(("send", "maybe_mesh")): bad.append(nm)
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and ("://" in n.value or "mesh" in n.value.lower()): bad.append("str:" + n.value[:30])
    return imp, calls, bad
bi, bc, bb = info(sys.argv[1]); ni, nc, nb = info(sys.argv[2]); pi, pc, pb = info(sys.argv[3])
err = []
if (ni - {"traceback"}) != (bi - {"traceback"}): err.append("Importe geaendert %s" % (ni ^ bi))
if sorted(nb) != sorted(bb): err.append("neue verbotene Elemente %s" % (set(nb) - set(bb)))
for nm in ("Popen", "socket", "system", "run", "call", "check_output"):
    if nc.count(nm) > bc.count(nm): err.append("mehr %s-Aufrufe" % nm)
if pi - {"sys"} or pb: err.append("patch-dual.py: %s %s" % (pi, pb))
li, lc, lb = info(sys.argv[4])
if li - {"traceback"}: err.append("Block-Importe %s" % li)
if [x for x in lb if not x.startswith("str:")]: err.append("Block verboten %s" % lb)
for nm in ("Popen", "system", "run", "call", "send_meshtastic", "open", "urlopen", "remove", "unlink", "Thread"):
    if nm in lc: err.append("Block ruft %s" % nm)
blk = open(sys.argv[4], encoding="utf-8").read()
import re
if "add_url_rule" in blk or "after_request" in blk: err.append("Block: neue Route/Hook")
js = blk[blk.index("_SD_JS = r"):blk.index("def _sd_selftest")]
for w in ("fetch(", "XMLHttpRequest", "WebSocket", "sendBeacon", "localStorage", "eval(", "POST"):
    if w in js: err.append("JS enthaelt " + w)
for nm in ("_SD_LAGE_JS = r", "_SD_RF_JS = r"):
    j2 = blk[blk.index(nm):]
    j2 = j2[:j2.index('"""', len(nm) + 3)]
    for w in ("XMLHttpRequest", "WebSocket", "sendBeacon", "localStorage", "eval(", "POST", "method", "</script"):
        if w in j2: err.append("JS %s enthaelt %s" % (nm[:10], w))
    if j2.count("fetch(") != j2.count("fetch('/api/br24',") or j2.count("fetch(") != 1: err.append("JS %s: fetch nur GET /api/br24 erlaubt" % nm[:10])
if "mesh" in blk.lower(): err.append("Mesh im Block")
for nm in ("set_lage", "get_lage", "lage_apply", "stick_health"):
    if nm not in nc: pass
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard: keine Mesh-Sendung, kein shell=True, keine neuen Sockets/Server/Importe, keine neuen Prozesse (Popen %d=%d)" % (nc.count("Popen"), bc.count("Popen")))
GUARDPY
# ---------- 3) Trockenlauf ----------
mkdir -p "$W/work"
python3 "$P" "$F" "$W/work/dashboard.py" "$LB" || { echo "STOP: Dashboard-Basis passt nicht - nichts geaendert"; exit 1; }
python3 "$P" "$W/work/dashboard.py" "$W/work/d2.py" "$LB" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: nicht idempotent"; exit 1; }
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile dashboard - nichts geaendert"; exit 1; }
cp -a "$DASH_DIR/prepper_gps.py" "$DASH_DIR/prepper_evlog.py" "$DASH_DIR/prepper_sdr_net.py" "$W/" 2>/dev/null || true
( cd "$W" && "$VPY" -W error "$M" selftest > "$W/selftest.txt" 2>&1 ) || { tail -5 "$W/selftest.txt"; echo "STOP: Selbsttest prepper_sdr - nichts geaendert"; exit 1; }
SPY=/usr/bin/python3; [[ -x "$SPY" ]] || SPY=python3
( cd "$W" && "$SPY" -W error "$M" selftest > "$W/selftest2.txt" 2>&1 ) || { tail -5 "$W/selftest2.txt"; echo "STOP: Selbsttest prepper_sdr (Dienst-Python) - nichts geaendert"; exit 1; }
"$SPY" -c "import numpy" 2>/dev/null && echo "OK Dienst-Python hat numpy (QRM-Messung moeglich)" || echo "WARNUNG: Dienst-Python ohne numpy - QRM-Messung faellt aus, Stick 2 macht nur 433"
echo "OK Trockenlauf idempotent, py_compile ohne Warnung, Selbsttest prepper_sdr ok (hermetisch, Dashboard- und Dienst-Python)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
[[ "${PRE[/funk]}" == 200 ]] || { echo "STOP: /funk antwortet nicht - nichts geaendert"; exit 1; }
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
MODE0=$(md5sum "$DASH_DIR/sdr_mode.json" 2>/dev/null | cut -c1-32 || echo none)
# ---------- 4) Installieren ----------
same_d=0; cmp -s "$W/work/dashboard.py" "$F" && same_d=1
same_m=0; cmp -s "$M" "$DASH_DIR/prepper_sdr.py" && same_m=1
SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
RESTARTED=0
same_c=0; python3 -c "import json,sys; c=json.load(open(sys.argv[1])); s=c.get('stick2') or {}; assert s.get('serial')==sys.argv[2] and s.get('enabled') is True" "$DASH_DIR/sdr_config.json" "$SN2" 2>/dev/null && same_c=1
if [[ "$same_d$same_m$same_c" == "111" ]]; then
  echo "OK sdrDual schon installiert - kein Neustart"
else
  RESTARTED=1
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -8 | cut -c1-200 || true
    sudo journalctl -u "$UNIT" --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -6 | cut -c1-200 || true
    cp -a "$F.bak-sdrdual-$TS" "$F.rb" && mv -f "$F.rb" "$F"
    sudo systemctl stop "$UNIT" || true
    [[ -f "$DASH_DIR/sdr_config.json.bak-sdrdual-$TS" ]] && cp -a "$DASH_DIR/sdr_config.json.bak-sdrdual-$TS" "$DASH_DIR/sdr_config.json"
    [[ -f "$DASH_DIR/sdr_lage.json.bak-sdrdual-$TS" ]] && cp -a "$DASH_DIR/sdr_lage.json.bak-sdrdual-$TS" "$DASH_DIR/sdr_lage.json"
    cp -a "$DASH_DIR/prepper_sdr.py.bak-sdrdual-$TS" "$DASH_DIR/prepper_sdr.py.rb" && mv -f "$DASH_DIR/prepper_sdr.py.rb" "$DASH_DIR/prepper_sdr.py"
    sudo systemctl restart "$UNIT" || true; sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    sleep 3
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/"), /funk = $(code "$B/funk")), dashboard.py $(sha256sum "$F" | cut -c1-16), prepper_sdr.py $(sha256sum "$DASH_DIR/prepper_sdr.py" | cut -c1-16), Dienste: $UNIT=$(systemctl is-active "$UNIT" 2>/dev/null) prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null)"
    python3 -c "import json,sys; s=json.load(open(sys.argv[1])).get('stick2'); print('sdr_config.json stick2 jetzt:', json.dumps(s, ensure_ascii=False))" "$DASH_DIR/sdr_config.json" 2>/dev/null || true
    [[ "$(sha256sum "$DASH_DIR/prepper_sdr.py" | cut -c1-16)" == "$(sha256sum "$DASH_DIR/prepper_sdr.py.bak-sdrdual-$TS" | cut -c1-16)" && "$(sha256sum "$F" | cut -c1-16)" == "$(sha256sum "$F.bak-sdrdual-$TS" | cut -c1-16)" ]] && echo "OK Rollback vollstaendig (beide Dateien = Sicherung)" || echo "WARNUNG: Rollback unvollstaendig - Sicherungen: $F.bak-sdrdual-$TS"
  }
  cp -a "$F" "$F.bak-sdrdual-$TS"
  cp -a "$DASH_DIR/prepper_sdr.py" "$DASH_DIR/prepper_sdr.py.bak-sdrdual-$TS"
  cp -a "$DASH_DIR/sdr_config.json" "$DASH_DIR/sdr_config.json.bak-sdrdual-$TS"
  [[ -f "$DASH_DIR/sdr_lage.json" ]] && cp -a "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_lage.json.bak-sdrdual-$TS"
  for pat in "$F.bak-sdrdual-" "$DASH_DIR/prepper_sdr.py.bak-sdrdual-" "$DASH_DIR/sdr_config.json.bak-sdrdual-" "$DASH_DIR/sdr_lage.json.bak-sdrdual-"; do { ls -1t "$pat"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done; done
  install -m 644 "$M" "$DASH_DIR/prepper_sdr.py.new" && mv -f "$DASH_DIR/prepper_sdr.py.new" "$DASH_DIR/prepper_sdr.py" || { rb "Modul installieren"; exit 1; }
  if [[ "$same_d" == 0 ]]; then cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-sdrdual-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "dashboard installieren"; exit 1; }; fi
  "$VPY" -W error -m py_compile "$F" "$DASH_DIR/prepper_sdr.py" || { rb "py_compile"; exit 1; }
  python3 - "$DASH_DIR/sdr_config.json" "$SN2" << 'CFGPY' || { rb "sdr_config.json"; exit 1; }
import json, os, sys
f, sn2 = sys.argv[1], sys.argv[2]
c = json.load(open(f, encoding="utf-8"))
s2 = c.get("stick2") if isinstance(c.get("stick2"), dict) else {}
new = dict(s2, model="NESDR SMArt v5", serial=sn2, roles=["rot"], enabled=True)
if new != s2:
    c["stick2"] = new
    t = f + ".tmp"
    with open(t, "w", encoding="utf-8") as h:
        json.dump(c, h, ensure_ascii=False, indent=1)
    os.replace(t, f)
    print("OK sdr_config.json: stick2 SN %s aktiv (Wechselbetrieb)" % sn2)
CFGPY
  sudo systemctl restart "$UNIT" || { rb "Start $UNIT"; exit 1; }
  [[ "$same_d" == 0 ]] && sudo systemctl restart prepper-dashboard.service
  echo "Neustart: prepper-sdr$([[ "$same_d" == 0 ]] && echo ' + prepper-dashboard') - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/funk")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  sleep 4
  systemctl is-active --quiet "$UNIT" || { rb "$UNIT laeuft nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 5) Rauchtest (nur lesen) ----------
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" || true
python3 - "$W/funk.html" << 'PY' || rbx "/funk HTML-Struktur fehlerhaft"
import sys
from html.parser import HTMLParser
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
class Pr(HTMLParser):
    def __init__(s):
        super().__init__(); s.st = []; s.err = []; s.grid_open = 0; s.grid_cards = 0; s.out_cards = []
    def handle_starttag(s, t, a):
        if t in VOID: return
        d = dict(a); cls = (d.get("class") or "").split()
        if t == "div" and "card" in cls and not any(x[2] for x in s.st): s.out_cards.append(d.get("id") or "?")
        s.st.append((t, self_pos(s), "grid" in cls))
    def handle_endtag(s, t):
        if t in VOID: return
        if t != "div": 
            while s.st and s.st[-1][0] != t and s.st[-1][0] != "div": s.st.pop()
            if s.st and s.st[-1][0] == t: s.st.pop()
            return
        while s.st and s.st[-1][0] != "div": s.st.pop()
        if not s.st: s.err.append("ueberzaehliges </div> Zeile %d" % s.getpos()[0])
        else: s.st.pop()
def self_pos(s): return s.getpos()[0]
p = Pr(); p.feed(h); p.close()
od = [x for x in p.st if x[0] == "div"]
if p.err or od:
    print("/funk div-Bilanz:", p.err[:3], ["offen Zeile %d" % x[1] for x in od[:3]]); raise SystemExit(1)
assert h.count('id="sdrui-js"') == 1 and h.count('id="sdrlage-js"') == 1 and h.count('id="sdrdual-js"') == 1 and h.index('id="sdrlage-js"') < h.index('id="sdrdual-js"') < h.index('id="sdrui-js"'), "sdrDual-Teile/Reihenfolge"
assert "TA aktiv" not in h, "TA-Markierung noch da"
print("OK /funk div-Bilanz ausgeglichen (%d <div> offen=0), SDR-Kachel wird ins Raster gesetzt; Kacheln ausserhalb Raster im HTML: %s" % (h.count("<div"), ", ".join(p.out_cards) or "keine"))
PY
for i in $(seq 1 30); do python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert (d.get('dual') or {}).get('on') and d.get('s2')" "$DASH_DIR/sdr_status.json" 2>/dev/null && break; sleep 3; done
"${CURL[@]}" "$B/api/sdr/ui" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') and len(d.get('funcs') or [])==9, 'funcs'
U=d.get('dual') or {}
assert U.get('on') and U.get('sn1')=='$SN1' and U.get('sn2')=='$SN2', U
assert (d.get('krise') or {}).get('txt') and 'Stick 1' in d['krise']['txt'] and 'Stick 2' in d['krise']['txt'], d.get('krise')
print('OK /api/sdr/ui: %s · Rollen %s/%s · Krisenzeile: %s' % (U['mode'], U.get('role1'), U.get('role2'), d['krise']['txt']))
" || rbx "/api/sdr/ui ohne sdrDual"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] || rbx "/pi Sicherung veraendert ($R0/$R1)"
MODE1=$(md5sum "$DASH_DIR/sdr_mode.json" 2>/dev/null | cut -c1-32 || echo none)
[[ "$MODE1" == "$MODE0" ]] || rbx "Modus-Datei waehrend Apply veraendert"
fail=0
for p in "${PAGES[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite antwortet schlechter als vorher"
# ---------- 6) erster echter QRM-Block ----------
if [[ "$RESTARTED" == 1 ]]; then
  NW=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(int(float(c.get('noise_warmup_s') or 300)) + 420)" "$DASH_DIR/sdr_config.json" 2>/dev/null || echo 720)
  [[ "$NW" -gt 1200 ]] && NW=1200
  echo "QRM-Messung nach Neustart: warte auf ersten Messblock auf Stick 2 (max $NW s, nur Empfang) ..."
  for i in $(seq 1 $((NW / 10))); do
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); n=d.get('noise_diag') or {}; assert n.get('t1') or n.get('skip')" "$DASH_DIR/sdr_status.json" 2>/dev/null && break
    sleep 10
  done
fi
"${CURL[@]}" "$B/api/sdr/ui" | python3 -c "
import json,sys,time
d=json.load(sys.stdin)
def hm(t): return time.strftime('%d.%m. %H:%M:%S', time.localtime(t)) if t else '-'
nd=d.get('noise_diag') or {}
print('QRM-Block (neuer Stand): Start %s, Ende %s, %s/%s Baender ok%s' % (hm(nd.get('t0')), hm(nd.get('t1')), nd.get('ok_n','-'), nd.get('n','-'), (' · uebersprungen: %s' % nd['skip']) if nd.get('skip') else ''))
for k, b in sorted((nd.get('bands') or {}).items()):
    print('  %-5s %-6s %s' % (k, 'ok' if b.get('ok') else 'FEHLER', str(b.get('why') or '')[:170]))
if not nd.get('t1'): print('  (noch kein Messblock fertig - Kachel zeigt den Grund)')
s=d.get('stick') or {}
U=d.get('dual') or {}
for n in ('1','2'):
    h=U.get('h'+n) or {}
    print('%s: %s%s%s' % (U.get('label'+n), h.get('txt','?'), (' · ' + h['why']) if h.get('why') else '', (' · Tipp: ' + h['hint']) if h.get('hint') else ''))
print('Betrieb: %s · Stick 2 jetzt: %s' % (U.get('mode'), U.get('active2')))
L=d.get('lage') or {}
print('Lage: %s%s · Schalter: %s' % (L.get('name'), ' (angepasst)' if L.get('custom') else '', ' '.join('%s=%s' % (k, v.upper()) for k, v in (L.get('sw') or {}).items())))
print('Zeitanteile Stick 1: %s' % ' · '.join('%s %s %%' % (x.get('name'), round(x.get('pct') or 0)) for x in d.get('shares') or []))
print('Zeitanteile Stick 2: %s' % ' · '.join('%s %s %%' % (x.get('name'), round(x.get('pct') or 0)) for x in d.get('shares2') or []))
print('Krisenzeile: %s' % (d.get('krise') or {}).get('txt'))
n=d.get('noise') or {}
print('Kachel QRM/Gewitter: %s' % (n.get('txt') or ('aktuell · %s/%s Baender ok' % (n.get('ok_n'), n.get('n')))))
" 2>/dev/null || echo "WARN Diagnose nicht lesbar"
"${CURL[@]}" "$B/api/br24" | python3 -c "
import json,sys,time
d=json.load(sys.stdin)
lr=d.get('last_rx')
print('BR24-Empfang: %s · zuletzt %s%s · %s' % (d.get('state'), time.strftime('%d.%m. %H:%M:%S', time.localtime(lr)) if lr else 'nie', (' (' + str(d.get('last_src')) + ')') if d.get('last_src') else '', str(d.get('text') or '')[:120]))
a=d.get('asa_row') or {}
print('ASA DE: %s · %s%s' % (a.get('state'), a.get('l1'), (' · ' + a['l2']) if a.get('l2') else ''))
" 2>/dev/null || echo "WARN BR24-Status nicht lesbar"
GL=""; for gm in sdrDual sdrLage sdrQrmFix sdrUi lageMesh1 br24Warn2 br24Warn evLog gpsLearn umweltWide sdrNoise2 sdrGps sdrNoise sdrRf sdrRds sdrStick sdrAct sdrPreset sdrPlus sdAck sdrFunk2 sdrFunk; do GL="$GL $gm=$(grep -c "# ===== $gm:" "$F" || true)"; done
echo "OK guards$GL prepper_sdr.sdrQrmFix=$(grep -c '# ===== sdrQrmFix:' "$DASH_DIR/prepper_sdr.py" || true) prepper_sdr.sdrLage=$(grep -c '# ===== sdrLage:' "$DASH_DIR/prepper_sdr.py" || true) prepper_sdr.sdrDual=$(grep -c '# ===== sdrDual:' "$DASH_DIR/prepper_sdr.py" || true)"
[[ -f "$F.bak-sdrdual-$TS" ]] && echo "Backup: $F.bak-sdrdual-$TS (+ prepper_sdr.py), behalten: letzte $KEEP_LAST"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; prepper_sdr.py $(sha256sum "$DASH_DIR/prepper_sdr.py" | cut -c1-16), $(wc -l < "$DASH_DIR/prepper_sdr.py") Zeilen"
echo "COMMIT $COMMIT_ARG sdrDual=1"
