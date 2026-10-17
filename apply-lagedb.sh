#!/bin/bash
set -euo pipefail
# lageDB: Lagezentrum-Datenbank lagezentrum.db ZUSAETZLICH zu den JSON-Dateien (Module database.py, sdr_manager.py, mesh_router.py),
# /api/sdr/live + /api/sdr/map im Dashboard, DAB-Empfangsguete (SNR, FIC-Fehlerrate, Stick-SN) in prepper-sdr.
# Neustart nur prepper-sdr und prepper-dashboard. Sendet nichts, kein Mesh, keine neuen Sockets/Server/Faeden.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
DB="$DASH_DIR/lagezentrum.db"
MODS=(database.py sdr_manager.py mesh_router.py)
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/lagedb-apply
KEEP_LAST=3
KNOWN_DASH16="fb898475f114cfe9 a4d24af37b669908"  # live nach dabHist / Repo-Stand (mit diskTiles)
KNOWN_MOD16="589d3cf5d0c577e1"                    # Repo-Stand (nach dabHist + Watchdog)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== lageDB apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx" "$W/mt"
EXPECT_DBLK="945005f89062b68058bfe07b2336e8082afd50d7f7f0661141d8ad63ecf1259f"
cat > "$W/lz_dash_block.py" << 'LZDASH_EOF'
# ===== lageDB: Lagezentrum-Datenbank lagezentrum.db ZUSAETZLICH zu den JSON-Dateien (Module database.py, sdr_manager.py, mesh_router.py); /api/sdr/live + /api/sdr/map; Abgleich rate-begrenzt am Anfrage-Ende (kein Faden, kein Socket); sendet nichts =====
import sys as _lz_sys, time as _lz_time, threading as _lz_thr, os as _lz_os
_LZ_PATH = _lz_os.path.join(_SDR_BASE, "lagezentrum.db")
_LZ_LOCK = _lz_thr.Lock()     # nicht blockierend: laeuft schon ein Abgleich, wird uebersprungen
_LZ_AFTER_S = 30              # Abgleich aus beliebigen Anfragen hoechstens alle 30 s
_LZ_API_S = 5                 # aus /api/sdr/live und /api/sdr/map hoechstens alle 5 s
_LZ = {"sync": None, "err": None, "selftest": None, "t_after": 0}
try:
    if _SDR_BASE not in _lz_sys.path:
        _lz_sys.path.insert(0, _SDR_BASE)
    import database as _lz_dbm
    import sdr_manager as _lz_mgr
    import mesh_router as _lz_mesh  # nur Dublettenhilfen; an keinen Sendeweg angeschlossen (Teil 2)
    _lz_dbm.migrate(_LZ_PATH)
    _LZ["sync"] = _lz_mgr.Sync(_SDR_BASE, _LZ_PATH)
except Exception as _lz_e0:
    _lz_dbm = _lz_mgr = _lz_mesh = None
    _LZ["err"] = "Module: %s" % str(_lz_e0)[:120]
    print("lageDB Module:", _lz_e0, flush=True)


def _lz_ctx():
    """Vorhandene Live-Daten des Dashboards (nur lesen): NINA-Liste, BR24/ASA-Zustand, Netzfrequenz, Uplink."""
    ctx = {}
    try:
        ds = globals().get("data_store") or {}
        nv = (ds.get("nina") or {}).get("value") if isinstance(ds.get("nina"), dict) else None
        ctx["nina"] = nv if isinstance(nv, list) else None
        fq = ds.get("frequenz") if isinstance(ds.get("frequenz"), dict) else {}
        ctx["netz"] = {"frequenz": fq.get("value"), "frequenz_status": fq.get("status"), "uplink": ds.get("uplink_path"), "uplink_isp": ds.get("uplink_isp")}
    except Exception as e:
        print("lageDB data_store:", e, flush=True)
    try:
        um = globals().get("_uld_mod")
        if um is not None and hasattr(um, "public_state"):
            us = um.public_state() or {}
            ctx.setdefault("netz", {}).update(uplink=us.get("current") or ctx.get("netz", {}).get("uplink"), uplink_text=us.get("text"), uplink_stale=us.get("stale"))
    except Exception as e:
        print("lageDB Uplink:", e, flush=True)
    try:
        fn = globals().get("_br24_state")
        ctx["br24"] = fn() if callable(fn) else None
    except Exception as e:
        ctx["br24"] = None
        print("lageDB BR24:", e, flush=True)
    return ctx


def _lz_sync(min_s, ctx=None):
    """-> ctx (fuer die API weiterverwendbar). Nie Ausnahme, nie warten."""
    if _LZ["sync"] is None:
        return ctx
    if not _LZ_LOCK.acquire(False):
        return ctx
    try:
        if _lz_time.time() - (_LZ["sync"].last or 0) < min_s:
            return ctx
        ctx = ctx if ctx is not None else _lz_ctx()
        _LZ["sync"].tick(ctx, min_s=min_s)
    except Exception as e:
        _LZ["err"] = "Abgleich: %s" % str(e)[:120]
        print("lageDB Abgleich:", e, flush=True)
    finally:
        _LZ_LOCK.release()
    return ctx


def _lz_after(resp):
    try:
        now = _lz_time.time()
        if now - _LZ["t_after"] >= _LZ_AFTER_S:
            _LZ["t_after"] = now
            _lz_sync(_LZ_AFTER_S)
    except Exception as e:
        print("lageDB after_request:", e, flush=True)
    return resp


def _lz_api_live():
    try:
        ctx = _lz_ctx()
        _lz_sync(_LZ_API_S, ctx)
        if _lz_mgr is None:
            return jsonify({"status": "SDR_OFFLINE", "ber": None, "active_mast": None, "history": [], "sdr1_role": None, "sdr2_role": None, "sdr2_status": None, "error": _LZ["err"]})
        st = _LZ["sync"].stat if _LZ["sync"] else {}
        extra = {"netz": ctx.get("netz"), "db": {"path": _LZ_PATH, "counts": _lz_dbm.counts(_LZ_PATH), "sync_t": st.get("t"), "sync_err": st.get("err"),
                                                  "db_err": _lz_dbm.last_error(), "selftest": _LZ["selftest"]}}
        return jsonify(_lz_mgr.live(_SDR_BASE, _LZ_PATH, ctx.get("br24"), extra))
    except Exception as e:
        print("lageDB /api/sdr/live:", e, flush=True)
        return jsonify({"status": "SDR_OFFLINE", "ber": None, "active_mast": None, "history": [], "sdr1_role": None, "sdr2_role": None, "sdr2_status": None, "error": str(e)[:120]})


def _lz_api_map():
    try:
        _lz_sync(_LZ_API_S)
        if _lz_mgr is None:
            return jsonify({"type": "FeatureCollection", "features": [], "error": _LZ["err"]})
        return jsonify(_lz_mgr.map_geojson(_SDR_BASE, _LZ_PATH))
    except Exception as e:
        print("lageDB /api/sdr/map:", e, flush=True)
        return jsonify({"type": "FeatureCollection", "features": [], "error": str(e)[:120]})


def _lz_selftest():
    import tempfile
    assert _lz_dbm is not None and _lz_mgr is not None and _lz_mesh is not None
    d = tempfile.mkdtemp(prefix="lagedb-")
    tp = _lz_os.path.join(d, "t.db")
    assert _lz_dbm.migrate(tp) and _lz_dbm.migrate(tp)
    assert _lz_dbm.upsert_event({"source": "NINA", "ext_id": "x", "headline": "h", "expires": int(_lz_time.time()) + 60}, tp)
    assert _lz_mesh.remember("a", 0, path=tp) is False and _lz_mesh.is_duplicate(" A ", 0, path=tp) is True
    s = _lz_mgr.Sync(d, tp)
    s.tick({"nina": None, "br24": None}, force=True)
    assert s.stat["err"] is None, s.stat
    m = _lz_mgr.map_geojson(d, tp)
    assert m["type"] == "FeatureCollection" and len(m["features"]) >= len(_lz_mgr.TRANSMITTERS)
    assert _lz_mgr.live(d, tp)["status"] == "SDR_OFFLINE"  # ohne sdr_status.json kein Lebenszeichen
    return "lageDB selftest ok"


try:
    try:
        _LZ["selftest"] = _lz_selftest()
    except Exception as _lz_e1:
        _LZ["selftest"] = "lageDB selftest FEHLER: %s" % _lz_e1
    for _lz_rule, _lz_ep, _lz_fn in (("/api/sdr/live", "lz_sdr_live", _lz_api_live), ("/api/sdr/map", "lz_sdr_map", _lz_api_map)):
        if _lz_ep not in app.view_functions and not any(r.rule == _lz_rule for r in app.url_map.iter_rules()):
            app.add_url_rule(_lz_rule, endpoint=_lz_ep, view_func=_lz_fn, methods=["GET"])
    if _LZ["sync"] is not None:
        app.after_request(_lz_after)
    print("lageDB aktiv: %s · %s · %s" % (_LZ_PATH, _LZ["selftest"], _LZ["err"] or "Module ok"), flush=True)
except Exception as _lz_e2:
    print("lageDB:", _lz_e2, flush=True)
# ===== /lageDB =====
LZDASH_EOF
EXPECT_SBLK="6453adbd3271fb187d977e702b7e4f1e9b9a959442c511aea2f862f58ba8b186"
cat > "$W/lz_sdr_block.py" << 'LZSDR_EOF'
# ===== lageDB: DAB-Empfangsguete je Pruefblock (SNR, FIC-CRC-Fehler, Fehlerrate als BER-Ersatz, Stick-SN) in broadcast_state.json dab[ch].demod fuer lagezentrum.db; nur Empfang, nur lesen der welle-cli-Werte =====
# FIC-Fehlerrate = numcrcerrors / (Laufzeit_s * 125), DAB Mode I: 12 FIB je 96-ms-Rahmen = 125 FIB/s. Naeherung, keine echte Bitfehlerrate.
# welle-cli zaehlt numcrcerrors seit Programmstart; Laufzeit = jetzt - Start des Pruefblocks (Planner.since). Im Dauerbetrieb (Vorwahl)
# wird die Differenz zum letzten Abruf genommen. RSSI liefert welle-cli nicht -> bleibt leer.
LZDB_FIB_PER_S = 125.0
_lzdb_orig_on_dab = StateBC.on_dab
_lzdb_orig_sub_done = Planner.sub_done


def lzdb_demod(mux, now, since=None, sn=None, prev=None):
    """-> dict t/snr/fic_err/secs/fic_rate/sn/fcorr oder None. prev = vorheriger Schnappschuss (gleicher Kanal)."""
    try:
        dm = (mux or {}).get("demodulator") if isinstance(mux, dict) else None
        if not isinstance(dm, dict):
            return None
        snr = dm.get("snr")
        fic = dm.get("fic") if isinstance(dm.get("fic"), dict) else {}
        err = fic.get("numcrcerrors")
        err = int(err) if isinstance(err, (int, float)) and not isinstance(err, bool) and err >= 0 else None
        now = float(now or time.time())
        secs, d_err = None, err
        if isinstance(since, (int, float)) and 0 < now - since < 86400:
            secs = now - since
        elif isinstance(prev, dict) and isinstance(prev.get("fic_err"), int) and err is not None and err >= prev["fic_err"] \
                and isinstance(prev.get("t"), (int, float)) and 0 < now - prev["t"] < 600:
            secs, d_err = now - prev["t"], err - prev["fic_err"]
        rate = round(min(1.0, d_err / (secs * LZDB_FIB_PER_S)), 6) if (secs and secs >= 1 and d_err is not None) else None
        fc = dm.get("frequencycorrection")
        return {"t": int(now), "snr": round(float(snr), 2) if isinstance(snr, (int, float)) and not isinstance(snr, bool) else None,
                "fic_err": err, "secs": round(secs, 1) if secs else None, "fic_rate": rate, "sn": str(sn) if sn else None,
                "fcorr": int(fc) if isinstance(fc, (int, float)) and not isinstance(fc, bool) else None}
    except Exception as ex:
        print("lageDB demod:", ex, flush=True)
        return None


def _lzdb_on_dab(self, ch, mux, now=None):
    r = _lzdb_orig_on_dab(self, ch, mux, now)
    try:
        if isinstance(r, dict):
            ctx = getattr(self, "_lzdb_ctx", None) or {}
            prev = getattr(self, "_lzdb_prev", {}).get(str(ch))
            dm = lzdb_demod(mux, now, ctx.get("since"), ctx.get("sn"), prev)
            if dm:
                r["demod"] = dm
                if not hasattr(self, "_lzdb_prev"):
                    self._lzdb_prev = {}
                self._lzdb_prev[str(ch)] = dm
                self.dirty = True
    except Exception as ex:
        print("lageDB on_dab:", ex, flush=True)
    return r


def _lzdb_sub_done(self, sp, now):
    try:
        self.sbc._lzdb_ctx = {"since": getattr(self, "since", None), "sn": getattr(self, "dev_sn", None)}
    except Exception:
        pass
    try:
        return _lzdb_orig_sub_done(self, sp, now)
    finally:
        try:
            self.sbc._lzdb_ctx = None
        except Exception:
            pass


StateBC.on_dab = _lzdb_on_dab
Planner.sub_done = _lzdb_sub_done


def selftest_lagedb():
    m = {"demodulator": {"snr": 12.5, "frequencycorrection": -310, "fic": {"numcrcerrors": 25}}}
    a = lzdb_demod(m, 1100, since=1000, sn="19348831")
    assert a["snr"] == 12.5 and a["fic_err"] == 25 and a["secs"] == 100 and abs(a["fic_rate"] - 0.002) < 1e-9 and a["sn"] == "19348831", a
    b = lzdb_demod({"demodulator": {"snr": 9, "fic": {"numcrcerrors": 50}}}, 1130, prev=a)
    assert b["secs"] == 30 and abs(b["fic_rate"] - 25 / 3750.0) < 1e-6, b
    assert lzdb_demod({}, 1) is None and lzdb_demod(None, 1) is None and lzdb_demod({"demodulator": {"fic": {"numcrcerrors": -1}}}, 5)["fic_rate"] is None
    import tempfile
    bx = StateBC(tempfile.mkdtemp())
    bx._lzdb_ctx = {"since": 1000, "sn": "72055505"}
    r = bx.on_dab("11D", {"ensemble": {"label": {"label": "BR Bayern"}}, "services": [], "demodulator": m["demodulator"]}, now=1060)
    assert r["demod"]["sn"] == "72055505" and bx.d["dab"]["11D"]["demod"]["secs"] == 60
    print("selftest lageDB ok (SNR, FIC-Rate, Stick-SN)", flush=True)
# ===== /lageDB =====
LZSDR_EOF
EXPECT_PATCH="61745a5ea4f54860743837e1ca997c3ef4b79d25c7eb43c1565d34e895680c8e"
cat > "$W/patch-lz.py" << 'LZPATCH_EOF'
"""lageDB: Block in dashboard.py bzw. prepper_sdr.py einsetzen oder ersetzen (idempotent).
Aufruf: patch-lz.py dash|sdr QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
kind, src, dst, blkf = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== lageDB:", "# ===== /lageDB =====\n"
ANCHOR = "# ===== /dabHist =====\n"
NEED = {"dash": ("_SDR_BASE = ", "def _br24_state():", "def _sdr_load(name, default):", "app = Flask(__name__)", "# ===== sdrUi:", "# ===== br24Warn2:",
                 "# ===== stickTestFix:", "# ===== dabHist:", "\nif __name__ == \"__main__\":\n"),
        "sdr": ("class StateBC:", "class Planner:", "    def on_dab(self, ch, mux, now=None):", "    def sub_done(self, sp, now):",
                "# ===== stickTestFix:", "# ===== dabHist:", "def selftest_dabhist():", "        selftest_dabhist()\n")}[kind]
bad = [n.strip()[:40] for n in NEED if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if kind == "sdr" and s.count("        selftest_dabhist()\n") != 1:
    bad.append("selftest_dabhist() x%d" % s.count("        selftest_dabhist()\n"))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("lageDB-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: lageDB-Block steht nicht direkt nach /dabHist"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
if kind == "sdr" and "        selftest_lagedb()\n" not in s2:
    s2 = s2.replace("        selftest_dabhist()\n", "        selftest_dabhist()\n        selftest_lagedb()\n", 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
LZPATCH_EOF
EXPECT_GUARD="7c89b2c1735e5741f93adba8473323aadd9ac146fa8502000be650a0f8cfa0da"
cat > "$W/guard_lz.py" << 'LZGUARD_EOF'
"""lageDB AST-Guard. Aufruf: guard_lz.py DASH_ALT DASH_NEU SDR_ALT SDR_NEU MODUL... -> 0 ok, 1 Verstoss.
Keine Mesh-Sendestelle, kein shell=True, keine neuen Sockets/Server/Prozesse/Fäden; Dashboard: genau 1 neue
add_url_rule-Stelle (GET /api/sdr/live + /api/sdr/map) und 1 after_request (rate-begrenzter Abgleich, statt Faden)."""
import ast
import sys

RISKY = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "send_nina_to_bayern", "sendText", "sendData", "TCPInterface",
         "urlopen", "socket", "create_connection", "bind", "listen", "serve_forever", "HTTPServer", "make_server", "system", "Popen", "run", "call",
         "check_output", "check_call", "execv", "spawn", "fork", "Thread", "Timer", "start_new_thread")
NETMOD = {"requests", "urllib", "http", "socket", "subprocess", "_rq", "_req"}


def info(src):
    t = ast.parse(src)
    imp, calls, shell, attrs = set(), [], 0, []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False):
            shell += 1
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            calls.append(nm)
            if isinstance(f, ast.Attribute):
                attrs.append(((f.value.id if isinstance(f.value, ast.Name) else "?"), f.attr))
    return imp, calls, shell, attrs


def blk(src, a="# ===== lageDB:", z="# ===== /lageDB ====="):
    return src[src.index(a):src.index(z)] if a in src else ""


rd = lambda f: open(f, encoding="utf-8").read()
d0, d1, s0, s1 = rd(sys.argv[1]), rd(sys.argv[2]), rd(sys.argv[3]), rd(sys.argv[4])
mods = sys.argv[5:]
err = []
inst_d, inst_s = "# ===== lageDB:" in d0, "# ===== lageDB:" in s0
# --- Dashboard
bi, bc, bs, _ = info(d0)
ni, nc, ns, _ = info(d1)
if ni - bi - {"database", "sdr_manager", "mesh_router", "sys", "time", "threading", "os", "tempfile"}:
    err.append("Dashboard: Importe neu %s" % (ni - bi))
if ns != bs:
    err.append("Dashboard: shell=True neu")
b = blk(d1)
B = blk(d0)
bbi, bbc, bbs, _ = info(b)
obc = info(B)[1] if B else []
for nm in RISKY:
    if nc.count(nm) - bc.count(nm) != bbc.count(nm) - obc.count(nm) or bbc.count(nm):
        err.append("Dashboard: Aufruf %s im lageDB-Block/neu (%d->%d)" % (nm, bc.count(nm), nc.count(nm)))
if [c for c in bbc if c.startswith(("send", "maybe_mesh", "_mesh", "mesh_send"))]:
    err.append("Dashboard-Block: Sendeaufruf")
if bbc.count("add_url_rule") != 1 or bbc.count("after_request") != 1:
    err.append("Dashboard-Block: genau 1 add_url_rule-Stelle und 1 after_request erwartet")
if nc.count("add_url_rule") - bc.count("add_url_rule") != (0 if inst_d else 1) or nc.count("after_request") - bc.count("after_request") != (0 if inst_d else 1):
    err.append("Dashboard: unerwartete Zahl Routen/after_request")
for w in ("<script", "fetch(", "POST", "XMLHttpRequest", "meshtastic", "subprocess", "requests."):
    if w in b:
        err.append("Dashboard-Block enthaelt %s" % w)
if '"/api/sdr/live"' not in b or '"/api/sdr/map"' not in b or 'methods=["GET"]' not in b:
    err.append("Dashboard-Block: Routen /api/sdr/live + /api/sdr/map nur GET erwartet")
# --- prepper_sdr
bi, bc, bs, _ = info(s0)
ni, nc, ns, _ = info(s1)
if ni - bi - {"tempfile"}:
    err.append("prepper_sdr: Importe neu %s" % (ni - bi))
if ns != bs:
    err.append("prepper_sdr: shell=True neu")
sb = blk(s1)
sbc = info(sb)[1]
for nm in RISKY + ("connect",):
    if nm in sbc:
        err.append("prepper_sdr-Block ruft %s" % nm)
    if nc.count(nm) != bc.count(nm):
        err.append("prepper_sdr: Aufrufe %s geaendert (%d->%d)" % (nm, bc.count(nm), nc.count(nm)))
for w in ("mesh", "rtl_tcp", "rtl_sdr", "\"-T\"", "transmit", "Popen", "open("):
    if w in sb.lower() if w == "mesh" else w in sb:
        err.append("prepper_sdr-Block enthaelt %s" % w)
for nm_, src_ in (("Dashboard-Block", b), ("prepper_sdr-Block", sb)):
    if [x for x in info(src_)[3] if x[0] in NETMOD]:
        err.append("%s: Netz-/Prozessaufruf %s" % (nm_, [x for x in info(src_)[3] if x[0] in NETMOD]))
# --- Module
OKI = {"hashlib", "json", "os", "re", "time", "sqlite3", "tempfile", "datetime", "database"}
for m in mods:
    src = rd(m)
    mi, mc, ms, ma = info(src)
    if mi - OKI:
        err.append("%s: Importe %s" % (m, mi - OKI))
    if ms:
        err.append("%s: shell=" % m)
    for nm in RISKY:
        if nm in mc:
            err.append("%s: ruft %s" % (m, nm))
    if [x for x in ma if x[0] in NETMOD]:
        err.append("%s: Netz-/Prozessaufruf" % m)
    for base, at in ma:
        if at == "connect" and base != "sqlite3":
            err.append("%s: connect auf %s" % (m, base))
    if [c for c in mc if c.startswith(("send", "maybe_mesh"))]:
        err.append("%s: Sendeaufruf" % m)
    for w in ("meshtastic", "subprocess", "urllib", "requests", "socket"):
        if w in src:
            err.append("%s enthaelt %s" % (m, w))
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard lageDB: keine Sendestelle/Mesh-Aufrufe, kein shell=True, keine neuen Sockets/Server/Prozesse/Faeden (Abgleich per after_request, rate-begrenzt 30 s, statt Faden); "
      "Dashboard: 1 add_url_rule-Stelle (GET /api/sdr/live, /api/sdr/map) + 1 after_request; prepper_sdr: nur Werte aus mux.json; Module nur sqlite3/json/os/re/time/hashlib")
LZGUARD_EOF
EXPECT_LC="ce93e3ddcf0b05d63c62c93a67f29e114bfe5bc488c22c1c2ae372329e852e36"
cat > "$W/layout_check.py" << 'LZLC_EOF'
"""Raster-Pruefung /funk: layout_check.py SEITE.html [VORHER.html] -> 0 ok, 1 Fehler.
Haupt-Raster = div.grid mit den meisten Kacheln. Kachel = div.card, nicht in einer anderen Kachel.
Pflicht: #stickTestCard genau einmal, direktes Kind des Rasters und letztes div darin; keine Kachel ausserhalb, die es vorher nicht schon gab."""
import sys
from html.parser import HTMLParser


class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.nodes = [], []

    def handle_starttag(self, tag, attrs):
        if tag != "div":
            return
        a = dict(attrs)
        n = {"i": len(self.nodes), "cls": (a.get("class") or "").split(), "id": a.get("id") or "", "par": self.stack[-1] if self.stack else None, "kids": [], "txt": ""}
        if n["par"] is not None:
            self.nodes[n["par"]]["kids"].append(n["i"])
        self.nodes.append(n)
        self.stack.append(n["i"])

    def handle_endtag(self, tag):
        if tag == "div" and self.stack:
            self.stack.pop()

    def handle_data(self, d):
        if self.stack and len(self.nodes[self.stack[-1]]["txt"]) < 40:
            self.nodes[self.stack[-1]]["txt"] += d.strip()


def analyse(fn):
    p = P()
    p.feed(open(fn, encoding="utf-8", errors="replace").read())
    N = p.nodes

    def anc(i):
        j = N[i]["par"]
        while j is not None:
            yield j
            j = N[j]["par"]
    tiles = [n["i"] for n in N if "card" in n["cls"] and not any("card" in N[j]["cls"] for j in anc(n["i"]))]
    grids = [n["i"] for n in N if "grid" in n["cls"]]
    if not grids:
        return None, tiles, N, []
    g = max(grids, key=lambda x: sum(1 for t in tiles if x in anc(t)))
    out = [t for t in tiles if g not in anc(t)]
    return g, tiles, N, out


def sig(N, i):
    return N[i]["id"] or ("%s:%s" % (".".join(N[i]["cls"]), N[i]["txt"][:30]))


g, tiles, N, out = analyse(sys.argv[1])
err = []
if g is None:
    err.append("kein Kachel-Raster gefunden")
else:
    st = [n["i"] for n in N if n["id"] == "stickTestCard"]
    if len(st) != 1:
        err.append("#stickTestCard %d-mal" % len(st))
    else:
        s = st[0]
        if N[s]["par"] != g:
            err.append("#stickTestCard nicht direkt im Raster")
        elif N[g]["kids"][-1] != s:
            err.append("#stickTestCard nicht letzte Kachel (danach: %s)" % sig(N, N[g]["kids"][-1]))
    before = set()
    if len(sys.argv) > 2:
        g0, t0, N0, out0 = analyse(sys.argv[2])
        before = set(sig(N0, i) for i in out0)
    new_out = [sig(N, i) for i in out if N[i]["id"] != "stickTestCard" and sig(N, i) not in before]
    if new_out:
        err.append("Kacheln ausserhalb des Rasters (neu): " + ", ".join(new_out))
    print("Raster: %d Kacheln im Raster, ausserhalb (schon vorher/Absicht): %s" % (sum(1 for t in tiles if t not in out), ", ".join(sig(N, i) for i in out if N[i]["id"] != "stickTestCard") or "keine"))
if err:
    print("FEHLER Raster /funk: " + "; ".join(err)); raise SystemExit(1)
print("OK /funk: Antennentest letzte Kachel im Raster, keine Kachel neu ausserhalb")
LZLC_EOF
EXPECT_BT="4352b03bb0ab0f6700619a3ff85e2d793ffe104091845f46f208c2eac330d98c"
cat > "$W/blocktest.py" << 'LZBT_EOF'
"""lageDB Probelauf des Dashboard-Blocks ohne Dashboard: blocktest.py BLOCK MODULDIR [LIVEDIR]
Kopiert sdr_status.json/broadcast_state.json/sdr_dabhist.json (nur lesen) in ein Temp-Verzeichnis, DB nur dort."""
import json, os, shutil, sys, tempfile, time
blk, mdir = sys.argv[1], sys.argv[2]
live = sys.argv[3] if len(sys.argv) > 3 else None
tmp = tempfile.mkdtemp(prefix="lzbt-")
for n in ("sdr_status.json", "broadcast_state.json", "sdr_dabhist.json"):
    if live and os.path.isfile(os.path.join(live, n)):
        shutil.copy(os.path.join(live, n), tmp)
sys.path.insert(0, mdir)
from flask import Flask, jsonify
app = Flask("lzbt")
g = {"__name__": "lzbt", "app": app, "jsonify": jsonify, "_SDR_BASE": tmp,
     "data_store": {"nina": {"value": [{"city": "Nürnberg", "title": "Probewarnung Warntag", "id": "t1", "msgType": "Alert"}]}, "frequenz": {"value": 50.01}, "uplink_path": "landline"},
     "_br24_state": lambda: {"state": "gruen", "asa_row": {"state": "gruen", "l1": "ASA DE · DAB 5C · keine Warnung"}}}
try:
    with open(os.path.join(tmp, "sdr_status.json"), encoding="utf-8") as f:
        st = json.load(f)
except Exception:
    st = {}
st.update(t=int(time.time()), pid=os.getpid())
with open(os.path.join(tmp, "sdr_status.json"), "w", encoding="utf-8") as f:
    json.dump(st, f)
with open(blk, encoding="utf-8") as f:
    code = f.read()
exec(compile(code, blk, "exec"), g)
assert g["_LZ"]["selftest"] == "lageDB selftest ok", g["_LZ"]
c = app.test_client()
r = c.get("/api/sdr/live"); d = r.get_json()
assert r.status_code == 200 and d["status"] == "PROBEALARM" and d["watchdog"]["age_s"] <= 15, d
for k in ("status", "ber", "active_mast", "history", "sdr1_role", "sdr2_role", "sdr2_status"):
    assert k in d, k
r = c.get("/api/sdr/map"); m = r.get_json()
assert r.status_code == 200 and m["type"] == "FeatureCollection" and sum(1 for f in m["features"] if f["properties"]["kind"] == "transmitter") >= 6, m
assert c.post("/api/sdr/live").status_code == 405
c.get("/")  # after_request-Pfad (404-Seite) darf nicht stoeren
g["_LZ_PATH"] = tmp  # Verzeichnis statt Datei -> DB-Fehler, Seite muss trotzdem antworten
g["_LZ"]["sync"].path = tmp
g["_LZ"]["sync"].last = 0
r = c.get("/api/sdr/live"); assert r.status_code == 200 and r.get_json()["status"] == "SDR_OFFLINE", r.get_json()
r = c.get("/api/sdr/map"); assert r.status_code == 200
print("OK Block-Probelauf: /api/sdr/live=%s (%s), /api/sdr/map %d Objekte, POST 405, kaputte DB -> SDR_OFFLINE ohne Absturz" % (d["status"], d.get("reason") or "-", len(m["features"])))
shutil.rmtree(tmp, ignore_errors=True)
LZBT_EOF
EXPECT_M1="06dcbe99055e518f4dae397439e85c310376801335f34870fab59e2957df879f"
cat > "$W/database.py" << 'LZDB_EOF'
"""database.py - SQLite-Lagezentrum (lagezentrum.db) ZUSAETZLICH zu den JSON-Dateien.

Kaeswasser Lage Monitor, Teil 1. Nur Ablage/Abfrage, keine Netzwerkzugriffe, keine Sendewege.
- WAL-Modus, busy_timeout, eine Verbindung je Aufruf (thread-sicher ohne geteilte Verbindung)
- Schema-Migration idempotent (CREATE IF NOT EXISTS + fehlende Spalten per ALTER TABLE ADD COLUMN)
- jede Funktion faengt Fehler ab und liefert einen sicheren Standardwert (Seiten duerfen nie abstuerzen)

Tabellen:
  events     Lage-Ereignisse (NINA/MoWaS, DAB, ASA, BR24) - ext_id eindeutig (Upsert)
  mesh_log   md5-Hash gesehener Mesh-Texte je Kanal (nur Dublettenpruefung, kein Senden)
  telemetry  DAB-Empfangswerte je Stick/Kanal; 'ber' = FIC-CRC-Fehlerrate als Ersatz fuer die
             Bitfehlerrate (welle-cli liefert keine BER): numcrcerrors / (Messdauer_s * 125 FIB/s, DAB Mode I).
             kind 'dab' = echte Messung, kind 'hb' = Lebenszeichen aus sdr_status.json (Watchdog).
"""
import os
import sqlite3
import time

DB_PATH = "/home/fmg/prepper-dashboard/lagezentrum.db"
SCHEMA_VERSION = 1
TIMEOUT_S = 10.0

KEEP_MESH_S = 24 * 3600
KEEP_TELEMETRY_S = 48 * 3600

_TABLES = {
    "events": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("source", "TEXT NOT NULL"),          # NINA | DAB | ASA | BR24
        ("type", "TEXT"),                      # z. B. Alert/Update/Cancel, dls, ann, warn
        ("severity", "TEXT"),                  # info | warn | alarm | probe | unknown
        ("headline", "TEXT"),
        ("text", "TEXT"),
        ("lat", "REAL"),
        ("lon", "REAL"),
        ("geojson", "TEXT"),
        ("sent_at", "INTEGER"),
        ("created", "INTEGER"),
        ("updated", "INTEGER"),
        ("expires", "INTEGER"),
        ("is_test", "INTEGER DEFAULT 0"),      # eigene TEST-Knopf-Meldungen -> zaehlen nie
        ("ext_id", "TEXT"),
    ],
    "mesh_log": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("hash", "TEXT NOT NULL"),
        ("channel", "TEXT"),
        ("created", "INTEGER"),
    ],
    "telemetry": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("ts", "INTEGER NOT NULL"),
        ("kind", "TEXT DEFAULT 'dab'"),        # dab | hb
        ("serial", "TEXT"),
        ("channel", "TEXT"),                   # 11D | 5C (hb: Rolle/aktiv)
        ("snr", "REAL"),
        ("ber", "REAL"),                       # FIC-CRC-Fehlerrate (siehe oben)
        ("fic_err", "INTEGER"),
        ("secs", "REAL"),
        ("ensemble", "TEXT"),
        ("mast", "TEXT"),                      # Ensemble + Kanal, z. B. "Bayern · 11D"
        ("rssi", "REAL"),                      # nur wenn verfuegbar (welle-cli: nein)
        ("src_t", "INTEGER"),                  # Zeitstempel der Quelle (Dedup)
    ],
}
_INDEXES = (
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_events_ext ON events(ext_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_upd ON events(updated)",
    "CREATE INDEX IF NOT EXISTS ix_events_exp ON events(expires)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_hash ON mesh_log(hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_created ON mesh_log(created)",
    "CREATE INDEX IF NOT EXISTS ix_tel_ts ON telemetry(ts)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_tel_src ON telemetry(kind, serial, channel, src_t)",
)
_migrated = set()
_last_err = [None]


def _log(*a):
    _last_err[0] = " ".join(str(x) for x in a)[:200]
    print("lagezentrum.db:", *a, flush=True)


def last_error():
    return _last_err[0]


def connect(path=None):
    """Neue Verbindung (je Aufruf). WAL, busy_timeout, Row-Zugriff per Name."""
    con = sqlite3.connect(path or DB_PATH, timeout=TIMEOUT_S)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    return con


def migrate(path=None):
    """Schema anlegen/ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        con = connect(path)
        try:
            with con:
                con.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
                for tb, cols in _TABLES.items():
                    con.execute("CREATE TABLE IF NOT EXISTS %s (%s)" % (tb, ", ".join("%s %s" % c for c in cols)))
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ.replace("PRIMARY KEY AUTOINCREMENT", "").replace("NOT NULL", "")))
                for sql in _INDEXES:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_version', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (str(SCHEMA_VERSION),))
        finally:
            con.close()
        _migrated.add(path)
        return True
    except Exception as e:
        _log("Migration:", e)
        return False


def _ensure(path):
    path = path or DB_PATH
    if path not in _migrated:
        migrate(path)
    return path


def upsert_event(ev, path=None):
    """Ereignis anlegen oder (gleiche ext_id) aktualisieren. -> True/False"""
    path = _ensure(path)
    try:
        now = int(time.time())
        row = {k: ev.get(k) for k in ("source", "type", "severity", "headline", "text", "lat", "lon", "geojson", "sent_at", "created", "updated", "expires", "is_test", "ext_id")}
        if not row["ext_id"] or not row["source"]:
            return False
        row["created"] = int(row["created"] or now)
        row["updated"] = int(row["updated"] or row["created"])
        row["is_test"] = 1 if row["is_test"] else 0
        for k in ("headline", "text"):
            if row[k] is not None:
                row[k] = str(row[k])[:2000]
        con = connect(path)
        try:
            with con:
                con.execute(
                    "INSERT INTO events(source,type,severity,headline,text,lat,lon,geojson,sent_at,created,updated,expires,is_test,ext_id) "
                    "VALUES(:source,:type,:severity,:headline,:text,:lat,:lon,:geojson,:sent_at,:created,:updated,:expires,:is_test,:ext_id) "
                    "ON CONFLICT(ext_id) DO UPDATE SET updated=MAX(COALESCE(events.updated,0), COALESCE(excluded.updated,0)), "
                    "expires=CASE WHEN excluded.expires IS NULL THEN events.expires ELSE MAX(COALESCE(events.expires,0), excluded.expires) END, "
                    "severity=COALESCE(excluded.severity, events.severity), text=COALESCE(excluded.text, events.text), "
                    "headline=COALESCE(excluded.headline, events.headline), type=COALESCE(excluded.type, events.type), "
                    "lat=COALESCE(excluded.lat, events.lat), lon=COALESCE(excluded.lon, events.lon), geojson=COALESCE(excluded.geojson, events.geojson)", row)
        finally:
            con.close()
        return True
    except Exception as e:
        _log("Ereignis:", e)
        return False


def insert_telemetry(t, path=None):
    """Telemetrie-Zeile (gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    path = _ensure(path)
    try:
        row = {k: t.get(k) for k in ("ts", "kind", "serial", "channel", "snr", "ber", "fic_err", "secs", "ensemble", "mast", "rssi", "src_t")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        row["kind"] = row["kind"] or "dab"
        row["src_t"] = int(row["src_t"] if isinstance(row["src_t"], (int, float)) else row["ts"])
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,snr,ber,fic_err,secs,ensemble,mast,rssi,src_t) "
                                  "VALUES(:ts,:kind,:serial,:channel,:snr,:ber,:fic_err,:secs,:ensemble,:mast,:rssi,:src_t)", row)
                return cur.rowcount > 0
        finally:
            con.close()
    except Exception as e:
        _log("Telemetrie:", e)
        return False


def mesh_seen(hash_hex, channel=None, path=None, now=None):
    """Hash merken; True wenn er schon bekannt war (Dublette). Fehler -> None (Aufrufer entscheidet)."""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_log(hash, channel, created) VALUES(?,?,?)", (str(hash_hex), channel, int(now or time.time())))
                return cur.rowcount == 0
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_known(hash_hex, path=None):
    """Nur pruefen, nicht merken. -> True/False/None(Fehler)"""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return con.execute("SELECT 1 FROM mesh_log WHERE hash=?", (str(hash_hex),)).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def _rows(sql, args=(), path=None):
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return [dict(r) for r in con.execute(sql, args).fetchall()]
        finally:
            con.close()
    except Exception as e:
        _log("Abfrage:", e)
        return []


def recent_events(n=10, path=None, include_test=False):
    return _rows("SELECT * FROM events %s ORDER BY COALESCE(updated, created) DESC, id DESC LIMIT ?" % ("" if include_test else "WHERE COALESCE(is_test,0)=0"),
                 (int(n),), path)


def active_events(now=None, path=None, since_s=None):
    now = int(now or time.time())
    q = "SELECT * FROM events WHERE COALESCE(is_test,0)=0 AND (expires IS NULL OR expires >= ?)"
    a = [now]
    if since_s:
        q += " AND COALESCE(updated, created) >= ?"
        a.append(now - int(since_s))
    return _rows(q + " ORDER BY COALESCE(updated, created) DESC LIMIT 500", tuple(a), path)


def newest_telemetry(kind=None, path=None):
    r = _rows("SELECT * FROM telemetry %s ORDER BY ts DESC, id DESC LIMIT 1" % ("WHERE kind=?" if kind else ""), (kind,) if kind else (), path)
    return r[0] if r else None


def telemetry_latest_per_channel(path=None):
    return _rows("SELECT t.* FROM telemetry t JOIN (SELECT channel, MAX(ts) m FROM telemetry WHERE kind='dab' GROUP BY channel) x "
                 "ON t.channel=x.channel AND t.ts=x.m WHERE t.kind='dab' ORDER BY t.ts DESC", (), path)


def cleanup(now=None, path=None):
    """Abgelaufene Ereignisse, mesh_log > 24 h, Telemetrie > 48 h loeschen. -> {tabelle: anzahl}"""
    path = _ensure(path)
    now = int(now or time.time())
    out = {}
    try:
        con = connect(path)
        try:
            with con:
                out["events"] = con.execute("DELETE FROM events WHERE expires IS NOT NULL AND expires < ?", (now,)).rowcount
                out["mesh_log"] = con.execute("DELETE FROM mesh_log WHERE created < ?", (now - KEEP_MESH_S,)).rowcount
                out["telemetry"] = con.execute("DELETE FROM telemetry WHERE ts < ?", (now - KEEP_TELEMETRY_S,)).rowcount
        finally:
            con.close()
    except Exception as e:
        _log("Aufraeumen:", e)
    return out


def counts(path=None):
    out = {}
    for tb in _TABLES:
        r = _rows("SELECT COUNT(*) n FROM %s" % tb, (), path)
        out[tb] = r[0]["n"] if r else None
    return out


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "t.db")
    assert migrate(p) and migrate(p)  # idempotent
    con = connect(p)
    assert con.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    con.close()
    now = int(time.time())
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a", "expires": now + 60, "created": now - 10}, p)
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a2", "expires": now + 120, "updated": now}, p)
    ev = recent_events(5, p)
    assert len(ev) == 1 and ev[0]["headline"] == "a2" and ev[0]["expires"] == now + 120 and ev[0]["created"] == now - 10, ev
    assert upsert_event({"source": "BR24", "ext_id": "old", "expires": now - 5}, p)
    assert upsert_event({"source": "BR24", "ext_id": "t", "is_test": True}, p) and len(recent_events(9, p)) == 2
    assert insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert not insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert insert_telemetry({"ts": now - 3 * 86400, "serial": "1", "channel": "5C", "src_t": now - 3 * 86400}, p)
    assert newest_telemetry(path=p)["snr"] == 12.5 and telemetry_latest_per_channel(p)[0]["channel"] == "11D"
    assert mesh_seen("h", "0", p, now - 2 * 86400) is False and mesh_seen("h", "0", p) is True and mesh_known("zz", p) is False
    c = cleanup(now, p)
    assert c == {"events": 1, "mesh_log": 1, "telemetry": 1}, c
    assert counts(p) == {"events": 2, "mesh_log": 0, "telemetry": 1}, counts(p)
    assert recent_events(5, "/proc/nicht/schreibbar/x.db") == []  # Fehler -> leer, kein Absturz
    return "database selftest ok"


if __name__ == "__main__":
    print(selftest())
LZDB_EOF
EXPECT_M2="c9a152a99d769e6869fa73fdd4832e2bb5427e0e02acb1e17a399ca93303303e"
cat > "$W/sdr_manager.py" << 'LZMGR_EOF'
"""sdr_manager.py - Lagezentrum-Logik fuer SDR/DAB/NINA (Kaeswasser Lage Monitor, Teil 1).

Liest nur vorhandene Zustandsdateien/Daten (sdr_status.json, broadcast_state.json, sdr_dabhist.json,
NINA-Liste und BR24-Zustand aus dem Dashboard) und fuellt lagezentrum.db ZUSAETZLICH. Kein Netzwerk,
keine Sendewege, keine Prozesse. Jede Funktion faengt Fehler ab.

Status /api/sdr/live:
  SDR_OFFLINE  neueste Telemetrie aelter als WATCHDOG_S (15 s). Weil prepper-sdr DAB nur im Wechsel
               (11D/5C, je Pruefblock) misst und sdr_status.json nur bei Aenderung bzw. alle 60 s schreibt,
               gibt es keinen echten 15-s-Takt. Darum schreibt jede Synchronisierung (hoechstens alle
               HB_MIN_S = 10 s) eine Lebenszeichen-Zeile (kind 'hb'), aber NUR wenn sdr_status.json
               hoechstens STATUS_MAX_AGE_S (90 s) alt ist und der prepper-sdr-Prozess (pid) lebt.
  ECHTALARM    aktive ASA-DE-Warnung (DAB 5C), deren Text NICHT ausdruecklich Probe/Test sagt
  PROBEALARM   nur wenn ASA- oder MoWaS/NINA-Text ausdruecklich Probe/Test/Warntag sagt
  OK           sonst. Eigene TEST-Knopf-Meldungen ("TEST ... keine echte Warnung") zaehlen nie.
"""
import hashlib
import json
import os
import re
import time

try:
    import database as db
except Exception:
    db = None

WATCHDOG_S = 15
HB_MIN_S = 10
STATUS_MAX_AGE_S = 90
ASA_ACTIVE_S = 2 * 3600        # ASA-Warnung gilt so lange nach letztem Empfang als aktiv
PROBE_RE = re.compile(r"\b(probe\w*|test\w*|warntag|uebungs?\w*|übung\w*)\b", re.I)
OWN_TEST_RE = re.compile(r"^\s*TEST\b.*keine echte Warnung", re.I | re.S)

# Oeffentlich bekannte DAB+-Senderstandorte fuer 11D (BR "Bayern", 222,064 MHz) und 5C (Bundesmux "DR Deutschland",
# 178,352 MHz) im Empfangsgebiet Kalchreuth/Nuernberg (Heimatposition aus sdr_status.json "home" 49,557/11,133).
# Quellen: BR, Frequenzen und Empfang (PDF) https://www.br.de/unternehmen/inhalt/technik/download-frequenzen-pdf-102~attachment.pdf ;
# BR, Deutschlandweite Sendernetze https://www.br.de/unternehmen/inhalt/technik/digitalradio-dab-sendernetz-bundesweit-100.html ;
# https://www.digitalradio-in-deutschland.de/bayern/ und /belegung-deutschland/ (ERP) ;
# https://mobile.sender-tabelle.de/result.php?inputLand=D&inputRegion=bay&mode=d (ERP, TII).
# Koordinaten: Wikipedia-Artikel der Senderstandorte, gerundet (Genauigkeit etwa 1 km) - nur zur Kartenanzeige.
TRANSMITTERS = [
    {"id": "nbg-schweinau", "name": "Nürnberg (Fernmeldeturm Schweinau)", "lat": 49.4283, "lon": 11.0403, "channels": ["11D", "5C"], "erp_kw": {"11D": 10, "5C": 10}},
    {"id": "dillberg", "name": "Dillberg (bei Neumarkt i.d.OPf.)", "lat": 49.3239, "lon": 11.3831, "channels": ["11D", "5C"], "erp_kw": {"11D": 10, "5C": 10}},
    {"id": "ochsenkopf", "name": "Ochsenkopf (Fichtelgebirge)", "lat": 50.0306, "lon": 11.8083, "channels": ["11D", "5C"], "erp_kw": {"11D": 10}},
    {"id": "bamberg-geisberg", "name": "Bamberg (Geisberg)", "lat": 49.8660, "lon": 10.8440, "channels": ["11D", "5C"], "erp_kw": {"5C": 10}},
    {"id": "buettelberg", "name": "Büttelberg (Frankenhöhe)", "lat": 49.4070, "lon": 10.4030, "channels": ["11D", "5C"], "erp_kw": {"5C": 10}},
    {"id": "hesselberg", "name": "Hesselberg (Wassertrüdingen)", "lat": 49.0692, "lon": 10.5303, "channels": ["11D"], "erp_kw": {"11D": 10}},
]

# NINA-Abfragegebiete aus dashboard.fetch_nina() -> ungefaehre Mittelpunkte (Kreisstadt/Kreismitte), Radius grob.
NINA_AREAS = {
    "Nürnberg": (49.4521, 11.0767, 9000),
    "Fürth Stadt": (49.4771, 10.9887, 5000),
    "Erlangen Stadt": (49.5897, 11.0040, 6000),
    "LK Erlangen-Höchstadt": (49.6500, 10.8700, 15000),
    "LK Nürnberger Land": (49.5100, 11.4000, 18000),
    "LK Fürth": (49.4200, 10.8500, 13000),
    "LK Forchheim": (49.7200, 11.1000, 18000),
}


def _load(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if v is not None else default
    except Exception:
        return default


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _pid_alive(pid):
    try:
        return isinstance(pid, int) and pid > 1 and os.path.exists("/proc/%d" % pid)
    except Exception:
        return False


def _iso_ts(s):
    """NINA-Zeit '2026-10-17T08:00:00+02:00' -> Unix-Sekunden oder None."""
    try:
        from datetime import datetime
        return int(datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp())
    except Exception:
        return None


def is_own_test(text):
    return bool(OWN_TEST_RE.search(str(text or "")))


def is_probe(text):
    return bool(PROBE_RE.search(str(text or "")))


# ---------------------------------------------------------------- Telemetrie
def telemetry_rows(base, now=None):
    """Echte DAB-Messwerte aus broadcast_state.json (dab[ch].demod, von prepper-sdr guard lageDB) + Lebenszeichen."""
    now = int(now or time.time())
    out = []
    try:
        bs = _load(os.path.join(base, "broadcast_state.json"), {}) or {}
        for ch, d in ((bs.get("dab") or {}) if isinstance(bs.get("dab"), dict) else {}).items():
            dm = d.get("demod") if isinstance(d, dict) else None
            if not isinstance(dm, dict) or not isinstance(dm.get("t"), (int, float)):
                continue
            ens = str(d.get("ensemble") or "").strip()[:40] or None
            out.append({"ts": int(dm["t"]), "kind": "dab", "serial": str(dm.get("sn") or "?"), "channel": str(ch), "snr": _num(dm.get("snr")),
                        "ber": _num(dm.get("fic_rate")), "fic_err": dm.get("fic_err") if isinstance(dm.get("fic_err"), int) else None,
                        "secs": _num(dm.get("secs")), "ensemble": ens, "mast": ("%s · %s" % (ens, ch)) if ens else str(ch),
                        "rssi": _num(dm.get("rssi")), "src_t": int(dm["t"])})
    except Exception as e:
        print("sdr_manager Telemetrie:", e, flush=True)
    return out


def heartbeat_row(status, now=None):
    """Lebenszeichen aus sdr_status.json, nur wenn frisch und Prozess lebt. -> Zeile oder None"""
    now = int(now or time.time())
    st = status if isinstance(status, dict) else {}
    t = st.get("t")
    if not isinstance(t, (int, float)) or now - t > STATUS_MAX_AGE_S or t - now > 60:
        return None
    if "pid" in st and not _pid_alive(st.get("pid")):
        return None
    return {"ts": now, "kind": "hb", "serial": str(st.get("sn") or st.get("serial") or "?"), "channel": str(st.get("active") or "")[:20] or None,
            "src_t": now}


# ---------------------------------------------------------------- Ereignisse
def events_from_dabhist(dh, now=None):
    """sdr_dabhist.json -> Ereignisse: nur BR24 (11D), ASA DE (5C), Ansagen und als Warnung markierte Texte."""
    now = int(now or time.time())
    out = []
    ev = (dh or {}).get("ev") if isinstance(dh, dict) else None
    for x in (ev or [])[-400:]:
        try:
            if not isinstance(x, dict) or not isinstance(x.get("t"), (int, float)):
                continue
            ch, src, text = str(x.get("ch") or ""), str(x.get("src") or ""), str(x.get("text") or "")
            asa = ch == "5C" and src.upper().startswith("ASA")
            br = ch == "11D" and src.upper().startswith("BR24")
            if not (asa or br or x.get("k") == "ann" or x.get("warn")):
                continue
            source = "ASA" if asa else ("BR24" if br else "DAB")
            warn = bool(x.get("warn")) or x.get("k") == "ann"
            last = int(x.get("last") or x["t"])
            sev = ("probe" if is_probe(text) else "warn") if warn else "info"
            out.append({"source": source, "type": x.get("k") or "dls", "severity": sev, "headline": ("%s: %s" % (src, text))[:160], "text": text,
                        "sent_at": int(x["t"]), "created": int(x["t"]), "updated": last, "expires": last + (48 if warn else 24) * 3600,
                        "is_test": is_own_test(text), "ext_id": "DH:%s:%s:%d" % (ch, hashlib.md5(("%s|%s" % (src, text)).encode("utf-8")).hexdigest()[:12], int(x["t"]))})
        except Exception as e:
            print("sdr_manager DAB-Verlauf:", e, flush=True)
    return out


def events_from_nina(nina, now=None):
    """NINA-Liste aus data_store['nina']['value'] -> Ereignisse (MoWaS/NINA), Ort = ungefaehrer Gebietsmittelpunkt."""
    now = int(now or time.time())
    out = []
    for w in (nina or [])[:50] if isinstance(nina, list) else []:
        try:
            if not isinstance(w, dict) or not w.get("title"):
                continue
            title, city = str(w.get("title")), str(w.get("city") or "")
            wid = str(w.get("id") or hashlib.md5(title.encode("utf-8")).hexdigest()[:16])
            sent = _iso_ts(w.get("sent"))
            exp = _iso_ts(w.get("expires"))
            mt = str(w.get("msgType") or "") or None
            sev = "probe" if is_probe(title) else ("info" if mt == "Cancel" else "warn")
            lat, lon, rad = NINA_AREAS.get(city, (None, None, None))
            geo = json.dumps({"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
                              "properties": {"radius_m": rad, "approx": True, "area": city}}, ensure_ascii=False) if lat is not None else None
            out.append({"source": "NINA", "type": mt, "severity": sev, "headline": title[:160], "text": ("%s (%s)" % (title, city)) if city else title,
                        "lat": lat, "lon": lon, "geojson": geo, "sent_at": sent, "created": sent or now, "updated": now,
                        "expires": exp if exp else now + 6 * 3600, "is_test": is_own_test(title), "ext_id": "NINA:%s:%s" % (wid, city)})
        except Exception as e:
            print("sdr_manager NINA:", e, flush=True)
    return out


def events_from_br24(br, now=None):
    """Aktueller BR24-Zustand (/api/br24): nur bei rot ein Ereignis (gleicher Text = gleiche ext_id)."""
    now = int(now or time.time())
    try:
        if not isinstance(br, dict) or br.get("state") != "rot":
            return []
        why = br.get("why") if isinstance(br.get("why"), dict) else {}
        text = str(why.get("text") or br.get("text") or "").strip()
        if not text:
            return []
        t = int(why.get("t") or br.get("last_rx") or now)
        src = "ASA" if str(why.get("src") or "").startswith("ASA") else "BR24"
        return [{"source": src, "type": "warn", "severity": "probe" if is_probe(text) else "warn", "headline": text[:160], "text": text,
                 "sent_at": t, "created": t, "updated": now, "expires": now + 2 * 3600, "is_test": is_own_test(text),
                 "ext_id": "%s:%s" % (src, hashlib.md5(text.encode("utf-8")).hexdigest()[:16])}]
    except Exception as e:
        print("sdr_manager BR24:", e, flush=True)
        return []


# ---------------------------------------------------------------- Synchronisierung
class Sync:
    """Leichte, rate-begrenzte Synchronisierung im Dashboard-Prozess (kein Faden, kein Netz)."""

    def __init__(self, base, path=None):
        self.base = base
        self.path = path or os.path.join(base, "lagezentrum.db")
        self.last = 0
        self.last_hb = 0
        self.last_dh = (None, 0)
        self.last_clean = 0
        self.last_nina_sig = None
        self.stat = {"n": 0, "err": None, "t": None, "added": {}}

    def tick(self, ctx=None, now=None, min_s=5, force=False):
        now = int(now or time.time())
        if db is None:
            self.stat["err"] = "database.py fehlt"
            return self.stat
        if not force and now - self.last < min_s:
            return self.stat
        self.last = now
        ctx = ctx or {}
        add = {"telemetry": 0, "events": 0, "hb": 0}
        try:
            for r in telemetry_rows(self.base, now):
                add["telemetry"] += 1 if db.insert_telemetry(r, self.path) else 0
            st = _load(os.path.join(self.base, "sdr_status.json"), {}) or {}
            if now - self.last_hb >= HB_MIN_S:
                hb = heartbeat_row(st, now)
                if hb and db.insert_telemetry(hb, self.path):
                    add["hb"] += 1
                    self.last_hb = now
            fdh = os.path.join(self.base, "sdr_dabhist.json")
            try:
                mt = os.path.getmtime(fdh)
            except Exception:
                mt = None
            if mt and (mt != self.last_dh[0] or now - self.last_dh[1] > 600):
                self.last_dh = (mt, now)
                for e in events_from_dabhist(_load(fdh, {}), now):
                    add["events"] += 1 if db.upsert_event(e, self.path) else 0
            nina = ctx.get("nina")
            sig = json.dumps(nina, sort_keys=True, default=str)[:4000] if nina is not None else None
            if nina is not None and (sig != self.last_nina_sig or now % 600 < min_s):
                self.last_nina_sig = sig
                for e in events_from_nina(nina, now):
                    add["events"] += 1 if db.upsert_event(e, self.path) else 0
            for e in events_from_br24(ctx.get("br24"), now):
                add["events"] += 1 if db.upsert_event(e, self.path) else 0
            if now - self.last_clean >= 600:
                self.last_clean = now
                self.stat["cleanup"] = db.cleanup(now, self.path)
            self.stat.update(n=self.stat["n"] + 1, err=None, t=now, added=add)
        except Exception as e:
            self.stat["err"] = str(e)[:160]
            print("sdr_manager Sync:", e, flush=True)
        return self.stat


# ---------------------------------------------------------------- API-Daten
def classify(active, br=None, now=None):
    """-> (status, grund). active = aktive Ereignisse aus der DB (ohne eigene Tests)."""
    now = int(now or time.time())
    real, probe = [], []
    for e in active or []:
        if e.get("is_test") or is_own_test(e.get("text")):
            continue
        src, sev = e.get("source"), e.get("severity")
        recent = now - int(e.get("updated") or e.get("created") or 0) <= ASA_ACTIVE_S
        if src == "ASA" and sev in ("warn", "alarm", "probe") and recent:
            (probe if (sev == "probe" or is_probe(e.get("text"))) else real).append(e)
        elif src == "NINA" and (sev == "probe" or is_probe(e.get("text") or e.get("headline"))):
            probe.append(e)
    try:
        a = (br or {}).get("asa_row") if isinstance(br, dict) else None
        tx = str(a.get("l1") or "") if isinstance(a, dict) else ""
        if tx and not is_own_test(tx):
            if a.get("state") == "rot":
                (probe if is_probe(tx) else real).append({"source": "ASA", "headline": tx})
            elif "Probewarnung/Test" in tx:
                probe.append({"source": "ASA", "headline": tx})
    except Exception:
        pass
    if real:
        return "ECHTALARM", (real[0].get("headline") or "ASA-Warnung")[:160]
    if probe:
        return "PROBEALARM", (probe[0].get("headline") or "Probe")[:160]
    return "OK", None


def live(base, path=None, br=None, extra=None, now=None):
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    out = {"status": "SDR_OFFLINE", "ber": None, "active_mast": None, "history": [], "sdr1_role": None, "sdr2_role": None, "sdr2_status": None}
    try:
        st = _load(os.path.join(base, "sdr_status.json"), {}) or {}
        du = st.get("dual") if isinstance(st.get("dual"), dict) else {}
        s2 = st.get("stick2") if isinstance(st.get("stick2"), dict) else {}
        out["sdr1_role"] = du.get("role1") or st.get("role")
        out["sdr2_role"] = du.get("role2") or s2.get("role")
        if not s2:
            out["sdr2_status"] = "nicht eingerichtet"
        elif not s2.get("present", True):
            out["sdr2_status"] = "fehlt"
        else:
            h2 = (st.get("stick_health2") or {}).get("lvl") if isinstance(st.get("stick_health2"), dict) else None
            out["sdr2_status"] = "%s · %s" % ((st.get("s2") or {}).get("active") or "?", h2 or "?") if isinstance(st.get("s2"), dict) else (h2 or "?")
        if db is None:
            out["error"] = "database.py fehlt"
            return out
        nt = db.newest_telemetry(path=path)
        age = (now - int(nt["ts"])) if nt else None
        out["watchdog"] = {"newest_ts": nt["ts"] if nt else None, "newest_kind": nt["kind"] if nt else None, "age_s": age, "limit_s": WATCHDOG_S,
                           "status_age_s": (now - int(st["t"])) if isinstance(st.get("t"), (int, float)) else None,
                           "note": "Lebenszeichen je Abruf (alle %d s) solange sdr_status.json <= %d s alt und prepper-sdr laeuft; DAB-Messwerte nur je Pruefblock" % (HB_MIN_S, STATUS_MAX_AGE_S)}
        dab = db.telemetry_latest_per_channel(path)
        if dab:
            n = dab[0]
            out["ber"] = n.get("ber")
            out["active_mast"] = n.get("mast")
            out["telemetry"] = [{k: x.get(k) for k in ("ts", "channel", "serial", "snr", "ber", "fic_err", "secs", "mast", "rssi")} for x in dab]
        out["history"] = [{k: e.get(k) for k in ("source", "type", "severity", "headline", "created", "updated", "expires", "lat", "lon")}
                          for e in db.recent_events(10, path)]
        if age is None or age > WATCHDOG_S:
            out["status"] = "SDR_OFFLINE"
        else:
            out["status"], why = classify(db.active_events(now, path), br, now)
            if why:
                out["reason"] = why
        if isinstance(extra, dict):
            out.update({k: v for k, v in extra.items() if k not in out})
    except Exception as e:
        out["error"] = str(e)[:160]
        print("sdr_manager live:", e, flush=True)
    return out


def map_geojson(base, path=None, now=None):
    """Leaflet-taugliche FeatureCollection: Senderstandorte (kind transmitter) + Gefahrenzonen aktiver Ereignisse (kind hazard)."""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    feats = []
    for t in TRANSMITTERS:
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [t["lon"], t["lat"]]},
                      "properties": {"kind": "transmitter", "id": t["id"], "name": t["name"], "channels": t["channels"], "erp_kw": t["erp_kw"], "approx": True}})
    try:
        st = _load(os.path.join(base, "sdr_status.json"), {}) or {}
        h = st.get("home")
        if isinstance(h, list) and len(h) == 2 and all(isinstance(x, (int, float)) for x in h):
            feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [h[1], h[0]]}, "properties": {"kind": "home", "name": "Empfänger"}})
        for e in (db.active_events(now, path) if db is not None else []):
            g = None
            try:
                g = json.loads(e["geojson"]) if e.get("geojson") else None
            except Exception:
                g = None
            props = {"kind": "hazard", "source": e.get("source"), "severity": e.get("severity"), "headline": e.get("headline"), "updated": e.get("updated"), "expires": e.get("expires")}
            if isinstance(g, dict) and g.get("type") == "Feature" and isinstance(g.get("geometry"), dict):
                g = dict(g, properties=dict(g.get("properties") or {}, **props))
                feats.append(g)
            elif isinstance(e.get("lat"), (int, float)) and isinstance(e.get("lon"), (int, float)):
                feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [e["lon"], e["lat"]]}, "properties": props})
    except Exception as ex:
        print("sdr_manager Karte:", ex, flush=True)
    return {"type": "FeatureCollection", "features": feats}


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    now = int(time.time())
    with open(os.path.join(d, "sdr_status.json"), "w") as f:
        json.dump({"t": now - 5, "pid": os.getpid(), "sn": "19348831", "active": "rds:0", "home": [49.557, 11.133],
                   "dual": {"role1": "bc", "role2": "rot"}, "stick2": {"present": True, "role": "rot"}, "s2": {"active": "idle"}, "stick_health2": {"lvl": "ok"}}, f)
    with open(os.path.join(d, "broadcast_state.json"), "w") as f:
        json.dump({"dab": {"11D": {"ensemble": "Bayern", "demod": {"t": now - 100, "snr": 14.2, "fic_err": 3, "secs": 50, "fic_rate": 0.00048, "sn": "19348831"}},
                           "5C": {"ensemble": "DR Deutschland"}}}, f)
    with open(os.path.join(d, "sdr_dabhist.json"), "w") as f:
        json.dump({"ev": [{"id": 1, "t": now - 50, "last": now - 20, "n": 3, "ch": "5C", "src": "ASA DE", "text": "Probealarm: Test der Warnsysteme", "warn": True, "k": "dls"},
                          {"id": 2, "t": now - 40, "last": now - 40, "n": 1, "ch": "11D", "src": "Bayern 3", "text": "Musik", "warn": False, "k": "dls"},
                          {"id": 3, "t": now - 30, "last": now - 30, "n": 1, "ch": "5C", "src": "ASA DE", "text": "TEST ASA DE (DAB 5C) · keine echte Warnung · x", "warn": True, "k": "dls"}]}, f)
    s = Sync(d)
    st = s.tick({"nina": [{"city": "Nürnberg", "title": "Warntag: Probewarnung", "id": "mow.1", "msgType": "Alert", "sent": "2026-10-17T08:00:00+02:00"}],
                "br24": {"state": "gruen"}}, now, force=True)
    assert st["err"] is None and st["added"]["telemetry"] == 1 and st["added"]["hb"] == 1 and st["added"]["events"] == 3, st
    L = live(d, now=now)
    assert L["status"] == "PROBEALARM" and abs(L["ber"] - 0.00048) < 1e-9 and L["active_mast"] == "Bayern · 11D", L
    assert L["sdr1_role"] == "bc" and L["sdr2_role"] == "rot" and L["sdr2_status"] == "idle · ok" and len(L["history"]) == 2, L
    db.upsert_event({"source": "ASA", "ext_id": "real", "severity": "warn", "headline": "Gefahr: Fenster schließen", "text": "Gefahr", "updated": now, "expires": now + 3600}, s.path)
    assert live(d, now=now)["status"] == "ECHTALARM"
    assert live(d, now=now + WATCHDOG_S + 1)["status"] == "SDR_OFFLINE"
    s.tick({}, now + 20)
    assert live(d, now=now + 20)["status"] == "ECHTALARM"  # Lebenszeichen erneuert
    m = map_geojson(d, now=now)
    kinds = [f["properties"]["kind"] for f in m["features"]]
    assert kinds.count("transmitter") == len(TRANSMITTERS) and "home" in kinds and "hazard" in kinds, kinds
    hz = [f for f in m["features"] if f["properties"]["kind"] == "hazard" and f["properties"]["source"] == "NINA"]
    assert hz and hz[0]["properties"]["radius_m"] == 9000
    assert classify([{"source": "ASA", "severity": "warn", "text": "TEST BR24-Warnkette · keine echte Warnung", "updated": now}], None, now)[0] == "OK"
    assert classify([], {"asa_row": {"state": "rot", "l1": "ASA DE · DAB 5C ⚠ Warnung: „Gefahr“"}}, now)[0] == "ECHTALARM"
    assert classify([], {"asa_row": {"state": "grau", "l1": "ASA DE · DAB 5C · Probewarnung/Test: „x“"}}, now)[0] == "PROBEALARM"
    b = events_from_br24({"state": "rot", "why": {"text": "Unwetter", "t": now, "src": "BR24 11D"}}, now)
    assert b and b[0]["source"] == "BR24" and b[0]["severity"] == "warn"
    assert events_from_br24({"state": "grau", "test": True, "why": {"text": "Test"}}, now) == []
    assert heartbeat_row({"t": now - 200}, now) is None and heartbeat_row({"t": now, "pid": 999999999}, now) is None
    assert live("/nicht/da", path=os.path.join(d, "x.db"), now=now)["status"] == "SDR_OFFLINE"
    return "sdr_manager selftest ok"


if __name__ == "__main__":
    print(selftest())
LZMGR_EOF
EXPECT_M3="33f376517dfd968da0de7686eb1727da92d1ce16f78cb080ac395ab91a315038"
cat > "$W/mesh_router.py" << 'LZMR_EOF'
"""mesh_router.py - NUR Dublettenpruefung fuer Mesh-Texte (Kaeswasser Lage Monitor, Teil 1).

Dieses Modul sendet NICHTS und spricht kein Mesh-Geraet an. Es berechnet nur md5-Hashes normalisierter
Texte je Kanal und merkt sie in lagezentrum.db (Tabelle mesh_log, 24 h). Ob und wie ein Sendeweg das
benutzt, entscheidet der Sendeweg selbst (Teil 2, nur nach Freigabe).
"""
import hashlib
import re

try:
    import database as _db
except Exception:  # Modul fehlt -> Hilfen liefern None, nie Absturz
    _db = None

_WS = re.compile(r"\s+")
_NUM = re.compile(r"\d+(?:[.,]\d+)?")


def normalize(text, ignore_numbers=False):
    """Kleinbuchstaben, Leerraum zusammengefasst; optional Zahlen neutralisiert (Messwert-Schwankung egal)."""
    t = _WS.sub(" ", str(text or "")).strip().lower()
    return _NUM.sub("#", t) if ignore_numbers else t


def msg_hash(text, channel=None, ignore_numbers=False):
    """md5 ueber Kanal + normalisierten Text (hex)."""
    raw = "%s|%s" % ("" if channel is None else str(channel), normalize(text, ignore_numbers))
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def is_duplicate(text, channel=None, ignore_numbers=False, path=None):
    """Nur pruefen (nicht merken). -> True/False, None bei Fehler/ohne DB."""
    if _db is None:
        return None
    return _db.mesh_known(msg_hash(text, channel, ignore_numbers), path)


def remember(text, channel=None, ignore_numbers=False, path=None):
    """Merken. -> True wenn schon bekannt war (Dublette), False wenn neu, None bei Fehler."""
    if _db is None:
        return None
    return _db.mesh_seen(msg_hash(text, channel, ignore_numbers), None if channel is None else str(channel), path)


def selftest():
    import os
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "m.db")
    assert normalize("  Hallo\n Welt ") == "hallo welt"
    assert msg_hash("Pegel 1,2 m", 0, True) == msg_hash("pegel 3,4 m", 0, True)
    assert msg_hash("a", 0) != msg_hash("a", 1)
    assert is_duplicate("x", 0, path=p) is False
    assert remember("x", 0, path=p) is False and remember(" X ", 0, path=p) is True and is_duplicate("x", 0, path=p) is True
    return "mesh_router selftest ok"


if __name__ == "__main__":
    print(selftest())
LZMR_EOF
P="$W/patch-lz.py"; DBK="$W/lz_dash_block.py"; SBK="$W/lz_sdr_block.py"; SG="$W/guard_lz.py"; LC="$W/layout_check.py"; BT="$W/blocktest.py"
for x in "$EXPECT_DBLK $DBK" "$EXPECT_SBLK $SBK" "$EXPECT_PATCH $P" "$EXPECT_GUARD $SG" "$EXPECT_LC $LC" "$EXPECT_BT $BT" "$EXPECT_M1 $W/database.py" "$EXPECT_M2 $W/sdr_manager.py" "$EXPECT_M3 $W/mesh_router.py"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis (an Guards erkannt) ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
kn() { case " $2 " in *" $1 "*) echo bekannt;; *) echo "neu, Erkennung ueber Guards";; esac; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_DASH16")), prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $(kn "$S16" "$KNOWN_MOD16"))"
python3 "$P" dash "$F" "$W/work/dashboard.py" "$DBK" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
python3 "$P" sdr "$M" "$W/work/prepper_sdr.py" "$SBK" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
for m in "${MODS[@]}"; do
  if [[ -f "$DASH_DIR/$m" ]] && ! grep -q "Kaeswasser Lage Monitor, Teil 1" "$DASH_DIR/$m"; then echo "STOP: $DASH_DIR/$m gibt es schon (fremde Datei, sha16 $(sha256sum "$DASH_DIR/$m" | cut -c1-16)) - nichts geaendert"; exit 1; fi
  cp "$W/$m" "$W/work/$m"
done
echo "OK Basis erkannt: Guards dabHist + stickTestFix (beide), sdrUi + br24Warn2 (Dashboard), Anker /dabHist je genau 1x; Dashboard $(cat "$W/p1.log"), prepper_sdr $(cat "$W/p2.log")"
SDR_ACT=$(systemctl is-active prepper-sdr 2>/dev/null || true)
[[ "$SDR_ACT" == active ]] || { echo "STOP: prepper-sdr ist nicht aktiv ($SDR_ACT) - erst Dienst pruefen, nichts geaendert"; exit 1; }
# ---------- 2) Trockenlauf ----------
python3 "$P" dash "$W/work/dashboard.py" "$W/work/d2.py" "$DBK" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: Dashboard nicht idempotent"; exit 1; }
python3 "$P" sdr "$W/work/prepper_sdr.py" "$W/work/s2.py" "$SBK" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/s2.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
rm -f "$W/work/d2.py" "$W/work/s2.py"
for py in "$SPY" "$VPY"; do
  for x in prepper_sdr.py "${MODS[@]}"; do "$py" -W error -m py_compile "$W/work/$x" || { echo "STOP: py_compile $x ($py) - nichts geaendert"; exit 1; }; done
done
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile dashboard - nichts geaendert"; exit 1; }
"$VPY" -c "import sqlite3,sys; v=tuple(int(x) for x in sqlite3.sqlite_version.split('.')); sys.exit(0 if v>=(3,24) else 1)" || { echo "STOP: SQLite zu alt (Upsert braucht 3.24) - nichts geaendert"; exit 1; }
cp "$W/work/database.py" "$W/work/sdr_manager.py" "$W/work/mesh_router.py" "$W/mt/"
for py in "$SPY" "$VPY"; do
  for x in "${MODS[@]}"; do
    (cd "$W/mt" && "$py" -W error "$x" > "$W/mt.log" 2>&1) || { grep -v '^lagezentrum.db:' "$W/mt.log" | tail -8; echo "STOP: Selbsttest $x ($py) - nichts geaendert"; exit 1; }
    grep -q "selftest ok" "$W/mt.log" || { echo "STOP: Selbsttest $x ohne ok"; exit 1; }
  done
done
echo "OK Modul-Selbsttests (Temp-DB) mit $SPY und $VPY: database, sdr_manager, mesh_router"
"$VPY" -W error "$BT" "$DBK" "$W/mt" "$DASH_DIR" > "$W/bt.log" 2>&1 || { grep -v '^lagezentrum.db:' "$W/bt.log" | tail -8; echo "STOP: Block-Probelauf - nichts geaendert"; exit 1; }
grep '^OK Block' "$W/bt.log"
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  grep -q "selftest lageDB ok" "$W/selftest.log" && grep -q "selftest dabHist ok" "$W/selftest.log" || { echo "STOP: Selbsttest lageDB/dabHist fehlt ($py)"; exit 1; }
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY: $(grep 'selftest lageDB ok' "$W/selftest.log")"
# ---------- 3) AST-Guard ----------
python3 "$SG" "$F" "$W/work/dashboard.py" "$M" "$W/work/prepper_sdr.py" "$W/work/database.py" "$W/work/sdr_manager.py" "$W/work/mesh_router.py" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons), keine JS-Aenderung (Block ohne <script>)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys,time
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 4) Installieren ----------
RESTARTED=0
same=1
cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/prepper_sdr.py" "$M" || same=0
for m in "${MODS[@]}"; do cmp -s "$W/work/$m" "$DASH_DIR/$m" || same=0; done
if [[ "$same" == 1 ]]; then
  echo "OK lageDB schon installiert - kein Neustart"
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  DB_NEW=0; [[ -e "$DB" ]] || DB_NEW=1
  declare -A NEWMOD
  for m in "${MODS[@]}"; do [[ -f "$DASH_DIR/$m" ]] && NEWMOD[$m]=0 || NEWMOD[$m]=1; done
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -15 | cut -c1-200 || true
    sudo systemctl stop prepper-sdr.service || true
    for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json"; do
      [[ -f "$x.bak-lagedb-$TS" ]] && cp -a "$x.bak-lagedb-$TS" "$x.rb" && mv -f "$x.rb" "$x"
    done
    for m in "${MODS[@]}"; do
      if [[ "${NEWMOD[$m]}" == 1 ]]; then rm -f "$DASH_DIR/$m"; elif [[ -f "$DASH_DIR/$m.bak-lagedb-$TS" ]]; then cp -a "$DASH_DIR/$m.bak-lagedb-$TS" "$DASH_DIR/$m.rb" && mv -f "$DASH_DIR/$m.rb" "$DASH_DIR/$m"; fi
    done
    rm -rf "$DASH_DIR/__pycache__"/database.* "$DASH_DIR/__pycache__"/sdr_manager.* "$DASH_DIR/__pycache__"/mesh_router.* 2>/dev/null || true
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    if [[ "$DB_NEW" == 1 ]]; then for x in "$DB" "$DB-wal" "$DB-shm"; do [[ -e "$x" ]] && mv -f "$x" "$x.rb-$TS"; done; echo "  neue lagezentrum.db beiseite gelegt: lagezentrum.db.rb-$TS"; fi
    for x in "$F" "$M"; do cmp -s "$x" "$x.bak-lagedb-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true)"
  }
  for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json" "${MODS[@]/#/$DASH_DIR/}"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-lagedb-$TS"
    { ls -1t "$x.bak-lagedb-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  sudo systemctl stop prepper-sdr.service
  for m in "${MODS[@]}"; do
    cp "$W/work/$m" "$DASH_DIR/$m.new" && chmod 644 "$DASH_DIR/$m.new" && mv -f "$DASH_DIR/$m.new" "$DASH_DIR/$m" || { rb "installieren $m"; exit 1; }
  done
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-lagedb-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-lagedb-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-sdr und prepper-dashboard - warte auf HTTP und SDR-Status (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  ok=0; for i in $(seq 1 60); do systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && { ok=1; break; }; sleep 2; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr schreibt keinen frischen Status"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 5) Rauchtest ----------
fail=0
for p in "${PAGES[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite antwortet schlechter als vorher"
for p in /api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map; do c=$(code_r "$B$p"); printf '  HTTP %s = %s\n' "$p" "$c"; [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" || true
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" || true
python3 "$LC" "$W/funk.html" "$W/funk0.html" || rbx "Raster /funk fehlerhaft"
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] || rbx "/pi Sicherung veraendert ($R0/$R1)"
if command -v node >/dev/null 2>&1; then
  jsfail() {
    rm -rf "$W/js" && python3 - "$1" "$W/js" << 'JSX'
import re, sys, os
os.makedirs(sys.argv[2], exist_ok=True)
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for i, m in enumerate(re.finditer(r"<script([^>]*)>(.*?)</script>", s, re.S | re.I)):
    a = m.group(1).lower()
    if "src=" in a or ("type=" in a and not re.search(r"type=.(text/javascript|module|application/javascript)", a)):
        continue
    open(os.path.join(sys.argv[2], "s%02d.js" % i), "w", encoding="utf-8").write(m.group(2))
JSX
    local n=0 j; for j in "$W"/js/*.js; do [[ -f "$j" ]] || continue; node --check "$j" 2>/dev/null || n=$((n + 1)); done; echo "$n $(ls "$W"/js/*.js 2>/dev/null | wc -l)"
  }
  J0=$(jsfail "$W/funk0.html"); J1=$(jsfail "$W/funk.html")
  [[ "${J1%% *}" -le "${J0%% *}" ]] || rbx "node --check /funk: ${J1%% *} fehlerhafte Skripte (vorher ${J0%% *})"
  echo "OK node --check /funk: ${J1#* } Skripte, fehlerhaft ${J1%% *} (vorher ${J0%% *})"
else
  echo "Hinweis: node fehlt - JS-Pruefung uebersprungen (lageDB aendert kein JS)"
fi
sleep 2
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
"${CURL[@]}" "$B/api/sdr/map" -o "$W/map.json" || true
python3 - "$W/live.json" "$W/map.json" << 'APIPY' || rbx "/api/sdr/live oder /api/sdr/map unvollstaendig"
import json, sys
d = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2]))
for k in ("status", "ber", "active_mast", "history", "sdr1_role", "sdr2_role", "sdr2_status"):
    assert k in d, k
assert d["status"] in ("SDR_OFFLINE", "OK", "PROBEALARM", "ECHTALARM"), d["status"]
db = d.get("db") or {}
assert db.get("selftest") == "lageDB selftest ok", db.get("selftest")
assert m.get("type") == "FeatureCollection" and sum(1 for f in m["features"] if f["properties"].get("kind") == "transmitter") >= 6
w = d.get("watchdog") or {}
print("  /api/sdr/live: status %s%s, ber %s, Mast %s, SDR1 %s, SDR2 %s (%s), Verlauf %d, Watchdog Alter %s s (Status-Datei %s s)" % (
    d["status"], (" (%s)" % d["reason"][:60]) if d.get("reason") else "", d["ber"], d["active_mast"], d["sdr1_role"], d["sdr2_role"], d["sdr2_status"], len(d["history"]),
    w.get("age_s"), w.get("status_age_s")))
print("  DB: %s" % json.dumps(db.get("counts"), ensure_ascii=False))
print("  /api/sdr/map: %d Objekte (%d Sender, %d Gefahrenzonen)" % (len(m["features"]), sum(1 for f in m["features"] if f["properties"].get("kind") == "transmitter"),
      sum(1 for f in m["features"] if f["properties"].get("kind") == "hazard")))
if d["status"] == "SDR_OFFLINE":
    print("  WARNUNG: SDR_OFFLINE direkt nach Neustart - Watchdog-Info oben pruefen (kein Rollback, nur Anzeige)")
APIPY
[[ -f "$DB" ]] || rbx "lagezentrum.db fehlt"
c=$(code -X POST "$B/api/sdr/live"); [[ "$c" == 405 ]] && echo "OK POST /api/sdr/live abgelehnt (405)" || rbx "POST /api/sdr/live nicht abgelehnt ($c)"
# ---------- 6) Abschluss ----------
c=$(code_r "$B/api/sdr/ui"); [[ "$c" == 200 ]] || rbx "/api/sdr/ui nach Test $c"
echo "OK /api/sdr/ui = 200 nach Test, JSON-Dateien unveraendert weiter in Gebrauch (DB nur zusaetzlich)"
echo "OK guards lageDB(dash)=$(grep -c '# ===== lageDB:' "$F" || true) lageDB(sdr)=$(grep -c '# ===== lageDB:' "$M" || true) dabHist(dash)=$(grep -c '# ===== dabHist:' "$F" || true) dabHist(sdr)=$(grep -c '# ===== dabHist:' "$M" || true) stickTestFix(dash)=$(grep -c '# ===== stickTestFix:' "$F" || true) stickTestFix(sdr)=$(grep -c '# ===== stickTestFix:' "$M" || true) stickTest(dash)=$(grep -c '# ===== stickTest:' "$F" || true) lageTest=$(grep -c '# ===== lageTest:' "$F" || true) sdrDual=$(grep -c '# ===== sdrDual:' "$F" || true) lageMesh1=$(grep -c '# ===== lageMesh1:' "$F" || true) sdrLage=$(grep -c '# ===== sdrLage:' "$F" || true) sdrUi=$(grep -c '# ===== sdrUi:' "$F" || true) br24Warn2=$(grep -c '# ===== br24Warn2:' "$F" || true)"
[[ -f "$F.bak-lagedb-$TS" ]] && echo "Backups: *.bak-lagedb-$TS (dashboard.py, prepper_sdr.py, sdr_lage.json, sdr_config.json$(for m in "${MODS[@]}"; do [[ -f "$DASH_DIR/$m.bak-lagedb-$TS" ]] && printf ', %s' "$m"; done)), behalten: letzte $KEEP_LAST"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; prepper_sdr.py sha16 $(sha256sum "$M" | cut -c1-16), $(wc -l < "$M") Zeilen"
for m in "${MODS[@]}"; do echo "$m sha16 $(sha256sum "$DASH_DIR/$m" | cut -c1-16), $(wc -l < "$DASH_DIR/$m") Zeilen"; done
echo "Hinweis: SNR/FIC-Werte (ber) kommen mit der naechsten DAB-Pruefung 11D/5C; Watchdog-Lebenszeichen je Abruf (alle 10 s) solange prepper-sdr laeuft."
echo "COMMIT $COMMIT_ARG lageDB=1"
