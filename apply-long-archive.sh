#!/bin/bash
set -euo pipefail
# longArchive: Langzeitarchiv. Neues Modul archive_store.py + kleiner Install-Block in dashboard.py.
# Liest alle 15 min data_store + Statusdateien (keine Abrufe, kein Netz), puffert, schreibt stuendlich
# nach archive/ (JSONL je Monat und Reihe). Rohdaten 90 Tage, danach Tageswerte min/max/mittel/n dauerhaft.
# Ereignislisten dedupliziert. Unter 5 GB frei: Schreiben pausiert. Startwerte aus den 14-Tage-Historien.
# Nur bei dashboard.py sha16 06dc3e030bef9329. Sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/archive_store.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/longarchive
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== longArchive apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="6e22c009bd3d133e6fb9880210db777c3d6c598537dc4295923ec514d3a57a88"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-long-archive.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""longArchive: archive_store.py anlegen + Install-Block in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== longArchive:"
EXPECT = "06dc3e030bef9329"   # dashboard.py nach priceAllTime
ANCHORS = ["# ===== priceAllTime:", "# ===== pegelTrend:", "# ===== funkHarden3:"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== longArchive: Langzeitarchiv (archive_store.py, nur lesen, keine Abrufe, keine Sendungen) =====
# Sammel-Thread alle 15 min liest data_store + Statusdateien, puffert, schreibt stuendlich nach archive/.
# Rohdaten 90 Tage, danach Tageswerte dauerhaft. /api/archive/status, /api/archive/<reihe>?days=N, Karte auf /pi.
import os as _arch_os
_arch = None
try:
    import archive_store as _arch_mod
    _arch, _arch_res = _arch_mod.install(app, _arch_os.path.dirname(_arch_os.path.abspath(__file__)),
                                         lambda: globals().get("data_store"), lambda n: globals().get(n),
                                         __name__ == "__main__")
except Exception as _arch_e:
    _arch_res = {"error": str(_arch_e)}
print("longArchive aktiv:", _arch_res, flush=True)
# ===== /longArchive =====

'''
MODULE = r'''#!/usr/bin/env python3
"""longArchive: Langzeitarchiv fuer das Prepper-Dashboard (nur lesen aus data_store/Statusdateien).

archive/YYYY-MM/<reihe>.jsonl    Rohpunkte {"t": epoch, "v": {feld: zahl}} (90 Tage)
archive/daily/<reihe>.jsonl      Tageswerte {"d": "YYYY-MM-DD", "f": {feld: [min, max, mittel, n]}} (dauerhaft)
archive/events/<liste>.jsonl     Ereignisse {"t": epoch, "id": ..., "d": {...}} (dauerhaft, dedupliziert)
archive/state.json               Fortschritt (atomar)
Kein Netz, keine Sendungen, schreibt nur unter archive/.
"""
import atexit
import hashlib
import json
import math
import os
import re
import shutil
import threading
import time
from datetime import datetime, date, timedelta

VERSION = 1
SAMPLE_S = 900
FLUSH_S = 3600
RAW_DAYS = 90
MIN_FREE = 5 * 1024 ** 3
HEARTBEAT_S = 3600
MAX_FIELDS = 40
MAX_BUF = 20000
SEEN_KEEP = 1500

# data_store-Schluessel -> Reihe (fehlende Schluessel werden uebersprungen)
SLOT_SERIES = ["kraftstoff", "rohoel", "strom", "load", "mix", "frequenz", "freq", "gas", "lng", "lng_term",
               "pegel", "luft", "odl", "wbi", "wetter", "spaceweather", "space", "metalle", "adsb", "internet",
               "ping", "ping2", "download", "download_mbps", "netprobe", "system", "health", "mesh_ping", "mesh_ping2",
               "firms"]
# Statusdateien mit Punktlisten -> Reihe (Startwerte + laufend neue Punkte, dedupliziert nach Zeit)
FILE_SERIES = {"diesel": ("fuel_history.json", "diesel"), "brent": ("oil_history.json", "oil"),
               "outage": ("outage_history.json", None), "wbi_hist": ("wbi_history.json", None),
               "firms_hist": ("firms_history.json", None), "strom_hist": ("strom_history.json", None),
               "adsb_hist": ("adsb_history.json", None), "chutil1": ("mesh1_chutil.json", None),
               "chutil2": ("mesh2_chutil.json", None)}
# Deques nur im Speicher (Zeit oft nur HH:MM)
DEQUE_SERIES = {"freq_hist": "freq_history", "ping_hist": "ping_history"}
# Ereignislisten: data_store-Schluessel -> Filter fuer Listen-Schluessel (None = alle Listen)
EVENT_SLOTS = {"nina": None, "dwd": None, "stromausfall": None, "adsb": re.compile(r"emerg|squawk|alert|notfall", re.I)}
EVENT_FILES = {"adsb_emerg": "adsb_emerg_hist.json"}
SKIP_KEYS = {"pct", "y_min", "y_max", "warn", "lat", "lon", "port", "pid", "_keepLastTs", "ts", "time", "epoch"}
STR_STATE = ("phase", "state", "path", "mode", "conn_type", "uplink", "active", "status")
NUM_RE = re.compile(r"^\s*-?\d+(?:[.,]\d+)?\s*$")
T_RE = re.compile(r"^\s*(\d{1,2})\.(\d{1,2})\.?\s*(\d{4})?(?:[ T,]+(\d{1,2}):(\d{2}))?\s*$")
HM_RE = re.compile(r"^\s*(\d{1,2}):(\d{2})\s*$")
EV_KEYS = ("id", "identifier", "title", "headline", "event", "severity", "level", "area", "regionName", "start",
           "onset", "end", "expires", "sent", "hex", "squawk", "flight", "callsign", "desc", "description", "type",
           "name", "ort", "plz", "status", "count", "t", "time")


def _num(x):
    if isinstance(x, bool) or x is None:
        return None
    if isinstance(x, (int, float)):
        return float(x) if math.isfinite(float(x)) else None
    if isinstance(x, str) and NUM_RE.match(x) and len(x) < 24:
        try:
            return float(x.replace(",", "."))
        except Exception:
            return None
    return None


def extract(v, out=None, prefix="", depth=0):
    """Zahlen aus dict/list (Tiefe <= 1, Listen nur mit id/name-Eintraegen)."""
    if out is None:
        out = {}
    if len(out) >= MAX_FIELDS:
        return out
    n = _num(v)
    if n is not None:
        out[(prefix or "v").rstrip(".")] = round(n, 4)
        return out
    if isinstance(v, dict):
        for k in sorted(v.keys(), key=str)[:200]:
            if len(out) >= MAX_FIELDS:
                break
            ks = str(k)
            if ks in SKIP_KEYS or ks.startswith("_"):
                continue
            x = v[k]
            if isinstance(x, (dict, list)):
                if depth < 1:
                    extract(x, out, prefix + ks + ".", depth + 1)
                continue
            n = _num(x)
            if n is not None:
                out[prefix + ks] = round(n, 4)
    elif isinstance(v, list) and depth <= 1:
        for it in v[:12]:
            if not isinstance(it, dict):
                continue
            ident = it.get("id") or it.get("name") or it.get("station")
            if ident is None:
                continue
            ident = re.sub(r"[^A-Za-z0-9_-]+", "_", str(ident))[:24]
            for k, x in it.items():
                if len(out) >= MAX_FIELDS:
                    break
                if str(k) in SKIP_KEYS or str(k) in ("id", "name", "station") or str(k).startswith("_") or isinstance(x, (dict, list)):
                    continue
                nx = _num(x)
                if nx is not None:
                    out["%s%s.%s" % (prefix, ident, k)] = round(nx, 4)
    return out


def parse_points(items, now=None):
    """[(epoch, {feld: zahl})] aus Liste von {ts|t|time.., felder}; Jahr fuer DD.MM rueckwaerts ab heute."""
    now = now or datetime.now()
    rows = []
    for it in items or []:
        if not isinstance(it, dict):
            continue
        ep = None
        for k in ("ts", "epoch", "time_s"):
            n = _num(it.get(k))
            if n and n > 1e9:
                ep = n / 1000.0 if n > 1e12 else n
                break
        tstr = None
        if ep is None:
            for k in ("t", "time", "at", "date", "x", "datum"):
                if isinstance(it.get(k), str):
                    tstr = it.get(k)
                    break
            if tstr is None:
                continue
        vals = {}
        for k, x in it.items():
            if k in ("ts", "epoch", "time_s", "t", "time", "at", "date", "x", "datum") or str(k).startswith("_"):
                continue
            if isinstance(x, dict):
                for k2, x2 in x.items():
                    n2 = _num(x2)
                    if n2 is not None and len(vals) < MAX_FIELDS:
                        vals["%s.%s" % (k, k2)] = round(n2, 4)
                continue
            n = _num(x)
            if n is not None and len(vals) < MAX_FIELDS:
                vals[str(k)] = round(n, 4)
        if vals:
            rows.append([ep, tstr, vals])
    year = now.year
    nxt = None
    for r in reversed(rows):
        if r[0] is not None:
            nxt = None
            continue
        s = r[1].strip()
        try:
            iso = None
            try:
                iso = datetime.fromisoformat(s.replace("Z", ""))
            except Exception:
                iso = None
            if iso is not None and len(s) >= 10:
                r[0] = iso.timestamp()
                continue
            m = T_RE.match(s)
            if m:
                d, mo = int(m.group(1)), int(m.group(2))
                if m.group(3):
                    year = int(m.group(3))
                elif nxt is None:
                    if date(year, mo, d) > now.date() + timedelta(days=30):
                        year -= 1
                elif (mo, d) > nxt:
                    year -= 1
                nxt = (mo, d)
                r[0] = datetime(year, mo, d, int(m.group(4) or 0), int(m.group(5) or 0)).timestamp()
                continue
            m = HM_RE.match(s)
            if m:
                t = now.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=0, microsecond=0)
                if t > now + timedelta(minutes=5):
                    t -= timedelta(days=1)
                r[0] = t.timestamp()
        except Exception:
            r[0] = None
    return [(float(r[0]), r[2]) for r in rows if r[0] is not None]


def _evid(it):
    for k in ("id", "identifier", "hex"):
        if it.get(k) not in (None, ""):
            base = "%s|%s|%s" % (it.get(k), it.get("sent") or it.get("start") or it.get("onset") or "", it.get("squawk") or "")
            return hashlib.sha1(base.encode("utf-8", "replace")).hexdigest()[:16]
    sub = {k: it.get(k) for k in EV_KEYS if isinstance(it.get(k), (str, int, float)) and not isinstance(it.get(k), bool)}
    if not sub:
        return None
    return hashlib.sha1(json.dumps(sub, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]


def _evdata(it):
    d = {}
    for k in EV_KEYS:
        x = it.get(k)
        if isinstance(x, str):
            d[k] = x[:300]
        elif isinstance(x, (int, float)) and not isinstance(x, bool):
            d[k] = x
    return d


def _event_lists(v, filt, depth=0):
    out = []
    if isinstance(v, list):
        if filt is None or depth == 0:
            out.extend(x for x in v[:200] if isinstance(x, dict))
        return out
    if isinstance(v, dict) and depth < 2:
        for k, x in v.items():
            if isinstance(x, list):
                if filt is None or filt.search(str(k)):
                    out.extend(y for y in x[:200] if isinstance(y, dict))
            elif isinstance(x, dict):
                out.extend(_event_lists(x, filt, depth + 1))
    return out


class Archive:
    def __init__(self, base, get_store, get_global):
        self.base = os.path.realpath(base)
        self.dir = os.path.join(self.base, "archive")
        self.get_store = get_store
        self.get_global = get_global
        self.lk = threading.RLock()
        self.buf = {}
        self.ebuf = {}
        self.st = {"version": VERSION, "last": {}, "sig": {}, "seen": {}, "rolled": {}, "strstate": {},
                   "written": 0, "written_since": time.time(), "dropped": 0}
        self.skipped = {}
        self.paused = False
        self.last_flush = time.time()
        self.last_roll_day = None
        self.status_cache = None
        self.status_at = 0
        self.errors = []
        self.started = False
        os.makedirs(self.dir, exist_ok=True)
        self._load_state()

    # ---------- Dateien ----------
    def _p(self, *parts):
        p = os.path.realpath(os.path.join(self.dir, *parts))
        if not p.startswith(self.dir + os.sep):
            raise ValueError("Pfad ausserhalb archive/: %s" % p)
        return p

    def _load_state(self):
        try:
            with open(self._p("state.json"), "r", encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, dict) and d.get("version") == VERSION:
                for k, v in d.items():
                    self.st[k] = v
        except FileNotFoundError:
            pass
        except Exception as e:
            self._err("state lesen: %s" % e)

    def _save_state(self):
        p = self._p("state.json")
        tmp = "%s.tmp.%d" % (p, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.st, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, p)

    def _append(self, path, lines):
        if not lines:
            return 0
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = "".join(json.dumps(x, ensure_ascii=False, separators=(",", ":")) + "\n" for x in lines)
        with open(path, "a", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        return len(data.encode("utf-8"))

    def _err(self, msg):
        self.errors = (self.errors + ["%s %s" % (time.strftime("%d.%m %H:%M"), msg[:160])])[-10:]
        print("longArchive:", msg[:200], flush=True)

    @staticmethod
    def read_jsonl(path):
        out = []
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        out.append(json.loads(line))
                    except Exception:
                        continue
        except FileNotFoundError:
            pass
        return out

    def free_bytes(self):
        try:
            return shutil.disk_usage(self.dir).free
        except Exception:
            return None

    # ---------- Erfassen ----------
    def _add(self, series, t, vals):
        if not vals:
            return
        with self.lk:
            b = self.buf.setdefault(series, [])
            if sum(len(x) for x in self.buf.values()) >= MAX_BUF:
                self.st["dropped"] = int(self.st.get("dropped") or 0) + 1
                return
            b.append({"t": int(t), "v": vals})

    def _event(self, name, it, t=None):
        eid = _evid(it)
        if not eid:
            return
        with self.lk:
            seen = self.st["seen"].setdefault(name, [])
            if eid in seen:
                return
            seen.append(eid)
            if len(seen) > SEEN_KEEP:
                del seen[: len(seen) - SEEN_KEEP]
            self.ebuf.setdefault(name, []).append({"t": int(t or time.time()), "id": eid, "d": _evdata(it)})

    def sample_files(self):
        base = self.base
        for series, (fn, key) in FILE_SERIES.items():
            p = os.path.join(base, fn)
            try:
                if not os.path.exists(p):
                    continue
                with open(p, "r", encoding="utf-8") as f:
                    d = json.load(f)
                lists = []
                if isinstance(d, list):
                    lists = [d]
                elif isinstance(d, dict):
                    if key and isinstance(d.get(key), list):
                        lists = [d[key]]
                    else:
                        lists = [x for x in d.values() if isinstance(x, list) and x and isinstance(x[0], dict)][:1]
                pts = []
                for li in lists:
                    pts.extend(parse_points(li))
                if not pts:
                    self.skipped[series] = self.skipped.get(series, 0) + 1
                    continue
                last = float(self.st["last"].get(series) or 0)
                new = sorted((t, v) for t, v in pts if t > last)
                for t, v in new:
                    self._add(series, t, v)
                if new:
                    self.st["last"][series] = new[-1][0]
            except Exception as e:
                self.skipped[series] = self.skipped.get(series, 0) + 1
                self._err("%s: %s" % (fn, e))
        for name, fn in EVENT_FILES.items():
            p = os.path.join(base, fn)
            try:
                if not os.path.exists(p):
                    continue
                with open(p, "r", encoding="utf-8") as f:
                    d = json.load(f)
                items = d if isinstance(d, list) else _event_lists(d, None)
                for it in items[-500:]:
                    pts = parse_points([it])
                    self._event(name, it, pts[0][0] if pts else None)
            except Exception as e:
                self._err("%s: %s" % (fn, e))
        p = os.path.join(base, "uplink_state.json")
        try:
            if os.path.exists(p):
                with open(p, "r", encoding="utf-8") as f:
                    d = json.load(f)
                if isinstance(d, dict):
                    self._strstate("uplink_file", {k: d.get(k) for k in STR_STATE if isinstance(d.get(k), (str, bool))})
        except Exception as e:
            self._err("uplink_state: %s" % e)

    def _strstate(self, name, cur):
        if not cur:
            return
        sig = json.dumps(cur, sort_keys=True, ensure_ascii=False)
        with self.lk:
            prev = self.st["strstate"].get(name)
            if prev != sig:
                self.st["strstate"][name] = sig
                d = dict(cur)
                d["vorher"] = prev
                self.ebuf.setdefault("wechsel_" + name, []).append(
                    {"t": int(time.time()), "id": hashlib.sha1((sig + str(time.time())).encode()).hexdigest()[:16], "d": d})

    def sample_store(self):
        ds = self.get_store()
        if not isinstance(ds, dict):
            return
        now = time.time()
        for key in SLOT_SERIES:
            if key not in ds:
                continue
            slot = ds.get(key)
            try:
                upd = None
                val = slot
                if isinstance(slot, dict) and "value" in slot:
                    upd = slot.get("updated")
                    val = slot.get("value")
                if key == "internet" and isinstance(slot, dict):
                    vals = {"online": 1.0 if slot.get("value") else 0.0}
                else:
                    vals = extract(val)
                if not vals:
                    self.skipped[key] = self.skipped.get(key, 0) + 1
                    continue
                sig = hashlib.sha1(json.dumps(vals, sort_keys=True).encode()).hexdigest()[:12]
                prev = self.st["sig"].get(key) or {}
                if upd is not None and str(upd) == prev.get("u") and sig == prev.get("s"):
                    continue
                if sig == prev.get("s") and now - float(prev.get("t") or 0) < HEARTBEAT_S:
                    continue
                self._add(key, now, vals)
                self.st["sig"][key] = {"s": sig, "u": str(upd) if upd is not None else None, "t": now}
            except Exception as e:
                self.skipped[key] = self.skipped.get(key, 0) + 1
                self._err("%s: %s" % (key, e))
        for name, glob in DEQUE_SERIES.items():
            try:
                dq = self.get_global(glob)
                if not dq:
                    continue
                pts = parse_points(list(dq)[-200:])
                last = float(self.st["last"].get(name) or 0)
                new = sorted((t, v) for t, v in pts if t > last + 30)
                for t, v in new:
                    self._add(name, t, v)
                if new:
                    self.st["last"][name] = new[-1][0]
            except Exception as e:
                self._err("%s: %s" % (name, e))
        for key, filt in EVENT_SLOTS.items():
            slot = ds.get(key)
            if slot is None:
                continue
            try:
                val = slot.get("value") if isinstance(slot, dict) and "value" in slot else slot
                for it in _event_lists(val, filt):
                    self._event(key, it)
            except Exception as e:
                self._err("event %s: %s" % (key, e))
        try:
            up = {k: ds.get(k) for k in ("conn_type", "uplink_path", "uplink_isp") if isinstance(ds.get(k), str)}
            inet = ds.get("internet")
            if isinstance(inet, dict) and "value" in inet:
                up["online"] = bool(inet.get("value"))
            self._strstate("uplink", up)
        except Exception as e:
            self._err("uplink: %s" % e)

    # ---------- Schreiben ----------
    def flush(self, force=False):
        with self.lk:
            free = self.free_bytes()
            self.paused = free is not None and free < MIN_FREE
            if self.paused:
                self._err("Schreiben pausiert: nur %.1f GB frei" % (free / 1024 ** 3))
                return 0
            buf, self.buf = self.buf, {}
            ebuf, self.ebuf = self.ebuf, {}
            n = 0
            try:
                for series, lines in buf.items():
                    bymonth = {}
                    for ln in lines:
                        bymonth.setdefault(datetime.fromtimestamp(ln["t"]).strftime("%Y-%m"), []).append(ln)
                    for mon, ls in bymonth.items():
                        n += self._append(self._p(mon, series + ".jsonl"), ls)
                for name, lines in ebuf.items():
                    n += self._append(self._p("events", name + ".jsonl"), lines)
                self.st["written"] = int(self.st.get("written") or 0) + n
                self._save_state()
            except Exception as e:
                self._err("flush: %s" % e)
            self.last_flush = time.time()
            return n

    # ---------- Tageswerte + Aufraeumen ----------
    def months(self):
        try:
            return sorted(d for d in os.listdir(self.dir) if re.match(r"^\d{4}-\d{2}$", d))
        except Exception:
            return []

    def rollup(self, today=None):
        today = today or date.today()
        with self.lk:
            agg = {}
            for mon in self.months():
                for fn in os.listdir(self._p(mon)):
                    if not fn.endswith(".jsonl"):
                        continue
                    series = fn[:-6]
                    last = self.st["rolled"].get(series) or ""
                    for ln in self.read_jsonl(self._p(mon, fn)):
                        try:
                            d = datetime.fromtimestamp(int(ln["t"])).date()
                        except Exception:
                            continue
                        ds = d.isoformat()
                        if d >= today or ds <= last:
                            continue
                        day = agg.setdefault(series, {}).setdefault(ds, {})
                        for k, x in (ln.get("v") or {}).items():
                            if not isinstance(x, (int, float)):
                                continue
                            a = day.get(k)
                            if a is None:
                                day[k] = [x, x, x, 1]
                            else:
                                a[0] = min(a[0], x)
                                a[1] = max(a[1], x)
                                a[2] += x
                                a[3] += 1
            n = 0
            for series, days in agg.items():
                lines = []
                for ds in sorted(days):
                    f = {k: [round(a[0], 4), round(a[1], 4), round(a[2] / a[3], 4), a[3]] for k, a in days[ds].items()}
                    lines.append({"d": ds, "f": f})
                n += self._append(self._p("daily", series + ".jsonl"), lines)
                if lines:
                    self.st["rolled"][series] = lines[-1]["d"]
            if agg:
                self.st["written"] = int(self.st.get("written") or 0) + n
                self._save_state()
            return sum(len(v) for v in agg.values())

    def compact(self, today=None):
        today = today or date.today()
        cut = today - timedelta(days=RAW_DAYS)
        removed = []
        with self.lk:
            for mon in self.months():
                y, m = int(mon[:4]), int(mon[5:])
                end = (date(y + (m == 12), m % 12 + 1, 1) - timedelta(days=1))
                if end >= cut:
                    continue
                ok = True
                for fn in os.listdir(self._p(mon)):
                    if not fn.endswith(".jsonl"):
                        continue
                    have = set(x.get("d") for x in self.read_jsonl(self._p("daily", fn)))
                    need = set()
                    for ln in self.read_jsonl(self._p(mon, fn)):
                        try:
                            need.add(datetime.fromtimestamp(int(ln["t"])).date().isoformat())
                        except Exception:
                            pass
                    if not need <= have:
                        ok = False
                        self._err("Aufraeumen %s/%s: Tageswerte fehlen (%d) - bleibt" % (mon, fn, len(need - have)))
                        break
                if ok:
                    shutil.rmtree(self._p(mon))
                    removed.append(mon)
            if removed:
                self._err("Rohdaten geloescht (Tageswerte geprueft): %s" % ",".join(removed))
        return removed

    # ---------- Lesen ----------
    def _file_info(self, path):
        pts = 0
        first = last = None
        for ln in self.read_jsonl(path):
            t = ln.get("t")
            if t is None and ln.get("d"):
                try:
                    t = datetime.fromisoformat(ln["d"]).timestamp()
                except Exception:
                    t = None
            if t is None:
                continue
            pts += 1
            first = t if first is None or t < first else first
            last = t if last is None or t > last else last
        return pts, first, last

    def status(self, refresh=False):
        if self.status_cache and not refresh:
            return self.status_cache
        with self.lk:
            ser = {}
            total = 0
            raw_bytes = 0
            for mon in self.months():
                for fn in os.listdir(self._p(mon)):
                    if not fn.endswith(".jsonl"):
                        continue
                    p = self._p(mon, fn)
                    sz = os.path.getsize(p)
                    raw_bytes += sz
                    pts, a, b = self._file_info(p)
                    s = ser.setdefault(fn[:-6], {"points": 0, "first": None, "last": None, "bytes": 0, "daily": 0})
                    s["points"] += pts
                    s["bytes"] += sz
                    s["first"] = a if s["first"] is None or (a and a < s["first"]) else s["first"]
                    s["last"] = b if s["last"] is None or (b and b > s["last"]) else s["last"]
            daily_bytes = 0
            for sub in ("daily", "events"):
                try:
                    names = os.listdir(self._p(sub))
                except Exception:
                    names = []
                for fn in names:
                    if not fn.endswith(".jsonl"):
                        continue
                    p = self._p(sub, fn)
                    sz = os.path.getsize(p)
                    daily_bytes += sz
                    if sub == "daily":
                        pts, a, b = self._file_info(p)
                        s = ser.setdefault(fn[:-6], {"points": 0, "first": None, "last": None, "bytes": 0, "daily": 0})
                        s["daily"] = pts
                        s["bytes"] += sz
                        if a and (s["first"] is None or a < s["first"]):
                            s["first"] = a
            for k, b in self.buf.items():
                ser.setdefault(k, {"points": 0, "first": None, "last": None, "bytes": 0, "daily": 0})["buffered"] = len(b)
            ev = {}
            try:
                for fn in os.listdir(self._p("events")):
                    if fn.endswith(".jsonl"):
                        ev[fn[:-6]] = len(self.read_jsonl(self._p("events", fn)))
            except Exception:
                pass
            for k, b in self.ebuf.items():
                ev[k] = ev.get(k, 0) + len(b)
            for s in ser.values():
                total += s["points"]
                for k in ("first", "last"):
                    s[k + "_txt"] = datetime.fromtimestamp(s[k]).strftime("%d.%m.%Y %H:%M") if s[k] else None
            free = self.free_bytes()
            span = max(1.0, (time.time() - float(self.st.get("written_since") or time.time())) / 86400.0)
            per_day = float(self.st.get("written") or 0) / span if span >= 0.5 else None
            est = self.estimate(free, raw_bytes, daily_bytes, ser)
            self.status_cache = {
                "ok": True, "version": VERSION, "series": len(ser), "points": total, "events": ev,
                "bytes": raw_bytes + daily_bytes, "raw_bytes": raw_bytes, "daily_bytes": daily_bytes,
                "free_bytes": free, "min_free_bytes": MIN_FREE, "paused": self.paused,
                "buffered": sum(len(x) for x in self.buf.values()), "dropped": self.st.get("dropped", 0),
                "skipped": self.skipped, "errors": self.errors[-5:], "last_flush": int(self.last_flush),
                "written_per_day": per_day, "estimate": est, "detail": ser, "raw_days": RAW_DAYS,
            }
            self.status_at = time.time()
            return self.status_cache

    def estimate(self, free, raw_bytes, daily_bytes, ser):
        """Bytes/Tag nur aus Live-Punkten seit Archivstart (ohne Startwerte), Jahre bis zur 5-GB-Grenze."""
        try:
            t0 = float(self.st.get("live_since") or time.time())
            span_s = time.time() - t0
            if span_s < 2 * 3600:
                return {"note": "Schaetzung nach 2 h Laufzeit", "live_hours": round(span_s / 3600.0, 2)}
            cut = max(time.time() - 3 * 86400, t0)
            recent = 0
            fields = {}
            for mon in self.months()[-2:]:
                for fn in os.listdir(self._p(mon)):
                    if not fn.endswith(".jsonl"):
                        continue
                    for ln in self.read_jsonl(self._p(mon, fn)):
                        if ln.get("t", 0) >= cut:
                            recent += len(json.dumps(ln, ensure_ascii=False, separators=(",", ":"))) + 1
                            fields[fn] = max(fields.get(fn, 0), len(ln.get("v") or {}))
            span = (time.time() - cut) / 86400.0
            raw_day = recent / span
            daily_day = sum(26 + f * 40 for f in fields.values())
            raw_steady = raw_day * RAW_DAYS
            per_year = daily_day * 365 + 256 * 1024
            if free is None:
                return {"raw_bytes_day": int(raw_day), "daily_bytes_day": int(daily_day)}
            room = free - MIN_FREE - max(0.0, raw_steady - raw_bytes)
            years = room / per_year if per_year > 0 else None
            return {"raw_bytes_day": int(raw_day), "raw_steady_bytes": int(raw_steady), "daily_bytes_day": int(daily_day),
                    "bytes_year_after_90d": int(per_year), "years_until_guard": (round(years, 1) if years is not None else None),
                    "live_hours": round(span_s / 3600.0, 1)}
        except Exception as e:
            return {"error": str(e)}

    def series_points(self, series, days=7):
        if not re.match(r"^[A-Za-z0-9_.-]{1,64}$", series or ""):
            return None
        days = max(1, min(3650, int(days)))
        cut = time.time() - days * 86400
        out = {"series": series, "days": days, "raw": [], "daily": []}
        with self.lk:
            for mon in self.months():
                p = self._p(mon, series + ".jsonl")
                if os.path.exists(p):
                    out["raw"].extend(x for x in self.read_jsonl(p) if x.get("t", 0) >= cut)
            out["raw"].extend(x for x in self.buf.get(series, []) if x.get("t", 0) >= cut)
            if days > 7:
                cd = date.fromtimestamp(cut).isoformat()
                out["daily"] = [x for x in self.read_jsonl(self._p("daily", series + ".jsonl")) if x.get("d", "") >= cd]
        out["raw"] = out["raw"][-20000:]
        out["daily"] = out["daily"][-4000:]
        return out

    # ---------- Ablauf ----------
    def tick(self):
        try:
            self.sample_files()
            self.sample_store()
        except Exception as e:
            self._err("tick: %s" % e)
        now = time.time()
        if now - self.last_flush >= FLUSH_S or sum(len(x) for x in self.buf.values()) > MAX_BUF // 2:
            self.flush()
        try:
            self.status(refresh=True)
        except Exception as e:
            self._err("status: %s" % e)
        today = date.today()
        if self.last_roll_day != today and datetime.now().hour >= 3:
            self.flush()
            try:
                self.rollup(today)
                self.compact(today)
            except Exception as e:
                self._err("Tageswerte/Aufraeumen: %s" % e)
            self.last_roll_day = today

    def run(self, first_delay=90):
        with self.lk:
            if not self.st.get("live_since"):
                self.st["live_since"] = time.time() + 120
        try:
            self.sample_files()
            self.flush(force=True)
            self.status(refresh=True)
        except Exception as e:
            self._err("Start: %s" % e)
        time.sleep(first_delay)
        while True:
            self.tick()
            time.sleep(SAMPLE_S)

    def start(self):
        if self.started:
            return False
        self.started = True
        atexit.register(self.flush)
        try:
            import signal
            if threading.current_thread() is threading.main_thread() and signal.getsignal(signal.SIGTERM) in (signal.SIG_DFL, None):
                def _term(signum, frame):
                    try:
                        self.flush()
                    finally:
                        signal.signal(signal.SIGTERM, signal.SIG_DFL)
                        os.kill(os.getpid(), signal.SIGTERM)
                signal.signal(signal.SIGTERM, _term)
        except Exception as e:
            self._err("SIGTERM-Haken: %s" % e)
        threading.Thread(target=self.run, name="longArchive", daemon=True).start()
        return True


PI_CARD = ('<div class="card arch-card" id="archCard" style="margin-top:12px">'
           '<div class="title">🗄️ Archiv</div><div class="small" style="line-height:1.5">%s</div></div>')


def _fmt_b(n):
    if n is None:
        return "–"
    for unit, div in (("GB", 1024 ** 3), ("MB", 1024 ** 2), ("KB", 1024)):
        if n >= div:
            return ("%.1f %s" % (n / div, unit)).replace(".", ",")
    return "%d B" % n


def pi_card_html(a):
    s = a.status()
    est = s.get("estimate") or {}
    yrs = est.get("years_until_guard")
    if isinstance(yrs, (int, float)):
        mb = (est.get("bytes_year_after_90d") or 0) / 1024.0 ** 2
        if yrs > 100:
            yl = "reicht für weit über 100 Jahre (~%s MB/Jahr)" % ("%.1f" % mb).replace(".", ",")
        else:
            yl = "reicht für ~%s Jahre" % (("%d" % yrs) if yrs >= 10 else ("%.1f" % yrs).replace(".", ","))
    else:
        yl = "Schätzung nach 2 h Laufzeit"
    ev = sum((s.get("events") or {}).values())
    lines = ["%d Reihen · %s Punkte · %d Ereignisse · %s" % (s.get("series", 0), "{:,}".format(s.get("points", 0)).replace(",", "."), ev, _fmt_b(s.get("bytes"))),
             "frei %s · %s · Rohdaten %d Tage, danach Tageswerte" % (_fmt_b(s.get("free_bytes")), yl, RAW_DAYS),
             ("<span style=\"color:#ef4444\">Schreiben pausiert (unter 5 GB frei)</span>" if s.get("paused") else "Status ok")]
    return PI_CARD % "<br>".join(lines)


def install(app, base, get_store, get_global, start_thread):
    """Routen + /pi-Karte registrieren, Sammel-Thread starten (nur im Dashboard-Prozess)."""
    from flask import jsonify, request
    a = Archive(base, get_store, get_global)
    res = {"routes": [], "thread": False}
    if "arch_status" not in app.view_functions:
        def arch_status():
            return jsonify(a.status())
        app.add_url_rule("/api/archive/status", endpoint="arch_status", view_func=arch_status, methods=["GET"])
        res["routes"].append("status")
    if "arch_series" not in app.view_functions:
        def arch_series(series):
            try:
                days = int(request.args.get("days", "7"))
            except Exception:
                days = 7
            d = a.series_points(series, days)
            if d is None:
                return jsonify({"ok": False, "error": "Reihe ungueltig"}), 400
            d["ok"] = True
            return jsonify(d)
        app.add_url_rule("/api/archive/<series>", endpoint="arch_series", view_func=arch_series, methods=["GET"])
        res["routes"].append("series")

    def arch_pi_card(resp):
        try:
            if request.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
                return resp
            if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
                return resp
            body = resp.get_data(as_text=True)
            i = body.rfind("</body>")
            if i < 0 or "arch-card" in body:
                return resp
            resp.set_data(body[:i] + pi_card_html(a) + body[i:])
        except Exception as e:
            a._err("pi-Karte: %s" % e)
        return resp
    app.after_request(arch_pi_card)
    if start_thread:
        res["thread"] = a.start()
    return a, res
'''


def main():
    d = Path(sys.argv[1])
    f = d / "dashboard.py"
    m = d / "archive_store.py"
    nosha = "--nosha" in sys.argv[2:]
    if m.exists() and m.read_text(encoding="utf-8") != MODULE:
        raise SystemExit("STOP: archive_store.py existiert mit anderem Inhalt - nichts geaendert")
    ast.parse(MODULE)
    compile(MODULE, str(m), "exec")
    src = f.read_text(encoding="utf-8")
    if MARK in src:
        if not m.exists():
            m.write_text(MODULE, encoding="utf-8")
            print("RESULT archive_store.py=neu dashboard.py=schon")
        else:
            print("RESULT dashboard.py=schon archive_store.py=schon")
        return
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    if h != EXPECT and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    miss = [a for a in ANCHORS if a not in src]
    if miss:
        raise SystemExit("STOP: Anker fehlt %s - nichts geaendert" % miss)
    if "archive_store" in src or "/api/archive" in src:
        raise SystemExit("STOP: Archiv schon im Text - nichts geaendert")
    names = set()
    for n in ast.parse(src).body:
        if isinstance(n, ast.Assign):
            names.update(t.id for t in n.targets if isinstance(t, ast.Name))
    if "app" not in names:
        raise SystemExit("STOP: app fehlt - nichts geaendert")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    m.write_text(MODULE, encoding="utf-8")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s) archive_store.py=neu (%d Zeilen)" % (h, MODULE.count(chr(10))))


if __name__ == "__main__":
    main()
PATCHPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-long-archive.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
parts = {}
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("BLOCK", "MODULE"):
        parts[n.targets[0].id] = n.value.value
if set(parts) != {"BLOCK", "MODULE"}:
    raise SystemExit(4)
hit = False
BAD_MOD = ("requests", "urllib", "socket", "http", "subprocess", "smtplib", "ftplib", "meshtastic")
for nm, code in parts.items():
    tree = ast.parse(code)
    funcs = {}
    for fn in ast.walk(tree):
        if isinstance(fn, ast.FunctionDef):
            for x in ast.walk(fn):
                funcs.setdefault(id(x), fn.name)
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            mods = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module or ""]
            for mm in mods:
                if mm.split(".")[0] in BAD_MOD:
                    print(nm, "verbotener Import", mm); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if fn.startswith(("send", "maybe_mesh", "fetch")) or fn in ("update_all", "TCPInterface", "urlopen", "Popen", "system", "remove", "unlink", "rmdir"):
                print(nm, "verbotener Aufruf", fn, "Zeile", node.lineno); hit = True
            if fn == "rmtree" and funcs.get(id(node)) != "compact":
                print(nm, "rmtree ausserhalb compact"); hit = True
            if fn == "open" and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and any(c in str(node.args[1].value) for c in "wax+"):
                if funcs.get(id(node)) not in ("_append", "_save_state"):
                    print(nm, "Schreib-open ausserhalb _append/_save_state Zeile", node.lineno); hit = True
        if isinstance(node, (ast.Assign, ast.AugAssign)):
            tg = node.targets if isinstance(node, ast.Assign) else [node.target]
            for t in tg:
                if isinstance(t, ast.Name) and t.id == "data_store":
                    print(nm, "data_store-Zuweisung"); hit = True
                if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name) and t.value.id == "data_store":
                    print(nm, "data_store-Schreiben"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Netz, kein Senden, kein Abruf, kein data_store, Schreiben nur in archive/)"

# ---------- 1) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
[[ -f "$M" ]] && cp -a "$M" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
for x in dashboard.py archive_store.py; do
  cmp -s "$W/work/$x" "$W/work1/$x" || { echo "STOP: nicht idempotent ($x) - nichts geaendert"; exit 1; }
  "$VPY" -W error::SyntaxWarning -m py_compile "$W/work/$x" || { echo "STOP: py_compile $x - nichts geaendert"; exit 1; }
done
grep -q '# ===== longArchive:' "$W/work/dashboard.py" || { echo "STOP: Marker fehlt im Trockenlauf"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /pi /energie /funk; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /energie=${PRE[/energie]} /funk=${PRE[/funk]}"
FREE=$(df -B1 --output=avail "$DASH_DIR" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
echo "frei auf der Karte: $((FREE / 1024 / 1024 / 1024)) GB (Archiv pausiert unter 5 GB)"

if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/archive_store.py" "$M" 2>/dev/null; then
  echo "OK longArchive schon installiert - kein Neustart"
else
  sudo -v
  NEWMOD=0; [[ -f "$M" ]] || NEWMOD=1
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-archive-$TS" "$F"
    [[ "$NEWMOD" -eq 1 ]] && rm -f "$M"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")); Ordner archive/ bleibt, Backup $F.bak-archive-$TS"
  }
  cp -a "$F" "$F.bak-archive-$TS"
  cp "$W/work/archive_store.py" "$M"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" "$M" || { rb "py_compile"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; 5 min Ruhezeit, sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  ok=0
  for i in $(seq 1 50); do
    "${CURL[@]}" "$B/api/archive/status" -o "$W/st.json" || true
    if python3 - "$W/st.json" << 'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("ok") is True and int(d.get("series") or 0) > 0 else 1)
PY
    then ok=1; break; fi
    sleep 3
  done
  [[ "$ok" -eq 1 ]] || { cat "$W/st.json" 2>/dev/null | head -c 400; echo; rb "/api/archive/status ohne Reihen"; exit 1; }
  python3 - "$W/st.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
mb = (d.get("bytes") or 0) / 1024.0 / 1024.0
gb = (d.get("free_bytes") or 0) / 1024.0 ** 3
print("Archiv: %d Reihen, %d Punkte, %.2f MB, frei %.1f GB, pausiert=%s" % (d.get("series"), d.get("points"), mb, gb, d.get("paused")))
print("Ereignisse:", ", ".join("%s=%s" % kv for kv in sorted((d.get("events") or {}).items())) or "-")
top = sorted((d.get("detail") or {}).items(), key=lambda kv: -kv[1].get("points", 0))[:8]
print("Reihen:", ", ".join("%s %d ab %s" % (k, v.get("points", 0), (v.get("first_txt") or "-")[:10]) for k, v in top))
sk = d.get("skipped") or {}
print("uebersprungen:", ", ".join("%s=%s" % kv for kv in sorted(sk.items())) or "keine")
for e in (d.get("errors") or [])[:3]:
    print("Hinweis:", e[:140])
PY
  dc=$(code "$B/api/archive/diesel?days=3")
  echo "GET /api/archive/diesel?days=3 = $dc"
  [[ "$dc" == "200" ]] || { rb "/api/archive/diesel antwortet nicht"; exit 1; }
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    if grep -q 'arch-card' "$W/pi.html"; then
      echo "OK /pi zeigt Archiv-Karte:"; sed -e 's/<br>/ | /g' -e 's/<[^>]*>/ /g' "$W/pi.html" | grep -o '[0-9]* Reihen.*Status ok\|[0-9]* Reihen.*pausiert[^|]*' | head -1 | cut -c1-200 || true
    else
      echo "WARN /pi 200, aber Archiv-Karte nicht eingefuegt (Archiv laeuft trotzdem)"
    fi
  fi
fi
fail=0
for p in / /pi /energie /funk; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  if [[ -f "$F.bak-archive-$TS" ]]; then rb "Seite antwortet schlechter als vorher"; fi
  exit 1
fi
echo "OK guards longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) priceAllTime=$(grep -q '# ===== priceAllTime:' "$F" && echo 1 || echo 0) pegelTrend=$(grep -q '# ===== pegelTrend:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-archive-$TS" ]] && echo "Backup: $F.bak-archive-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), archive_store.py $(sha256sum "$M" | cut -c1-16)"
echo "Hinweis: Wachstums-Schaetzung erscheint nach 2 h unter /api/archive/status und auf /pi"
echo "COMMIT $COMMIT_ARG longArchive=1"
