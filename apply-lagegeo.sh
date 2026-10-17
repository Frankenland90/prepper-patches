#!/bin/bash
set -euo pipefail
# lageGeo (auf lageDB): echte NINA-Warngebiete von warnung.bund.de/api31/warnings/<id>.geojson fuer aktive Warnungen,
# abgerufen im vorhandenen NINA-Abruf (requests wie fetch_nina, Timeout 8 s), Cache je Warnung in lagezentrum.db, keepLast, Kreis als Rueckfall,
# Vereinfachung Douglas-Peucker ab 100 m; /api/sdr/live: SDR2-Zustand klar (Rolle/Betrieb/Stick-Pruefung getrennt).
# Neustart nur prepper-dashboard. Sendet nichts, kein Mesh, keine neuen Sockets/Server/Faeden.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
MOD="$DASH_DIR/lagegeo.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/lagegeo-apply
KEEP_LAST=3
KNOWN_DASH16="9ddd99b1008373c1"  # live nach lageDB (17660 Zeilen)
DAB_WAIT_S="${DAB_WAIT_S:-300}"  # Rauchtest wartet so lange auf ber/Mast aus einer DAB-Pruefung (nur Hinweis, kein Rollback)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== lageGeo apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/mt"
EXPECT_BLK="203bcafe989cbaeb947b5d61ea045d05304178c1cd9ae3caafeea70964489841"
cat > "$W/lg_dash_block.py" << 'LGDASH_EOF'
# ===== lageGeo: echte NINA-Warngebiete (warnung.bund.de/api31/warnings/<id>.geojson) fuer aktive Warnungen, im vorhandenen NINA-Abruf (requests wie fetch_nina, Timeout 8 s), Cache je Warnung in lagezentrum.db (geo_cache + events.geojson), keepLast, Kreis als Rueckfall, Douglas-Peucker ab 100 m; dazu /api/sdr/live: SDR2-Zustand klar (Rolle 'rot' = Wechselbetrieb, 'idle' = bereit, Stick-Pruefung grau = keine Stoerung); kein Faden, kein Server, sendet nichts =====
import time as _lg_time, threading as _lg_thr
_LG_ROUND_S = 120      # hoechstens alle 2 min eine Abrufrunde (im Faden, der fetch_nina ausfuehrt)
_LG_MAX_N = 3          # hoechstens 3 Polygone je Runde
_LG_BUDGET_S = 20      # Zeitbudget je Runde
_LG_UA = {"User-Agent": "KaeswasserLage/1.0"}  # wie fetch_nina
_LG = {"t": 0, "t_clean": 0, "ok": 0, "fail": 0, "last": None, "err": None, "selftest": None}
_LG_LOCK = _lg_thr.Lock()
try:
    import lagegeo as _lg_mod
    if not _lg_mod.migrate(_LZ_PATH):
        print("lageGeo: Tabelle geo_cache nicht angelegt (%s)" % _lg_mod.last_error(), flush=True)
except Exception as _lg_e0:
    _lg_mod = None
    _LG["err"] = "Modul: %s" % str(_lg_e0)[:120]
    print("lageGeo Modul:", _lg_e0, flush=True)


def _lg_ids(warnings, now):
    """Nur aktive Warnungen: nicht 'Cancel', nicht abgelaufen."""
    out = []
    for w in warnings or []:
        try:
            if not isinstance(w, dict) or not w.get("id") or w.get("msgType") == "Cancel":
                continue
            exp = _lz_mgr._iso_ts(w.get("expires")) if (_lz_mgr is not None and w.get("expires")) else None
            if exp and exp < now:
                continue
            out.append(str(w["id"]))
        except Exception:
            continue
    return list(dict.fromkeys(out))


def _lg_fetch_one(wid):
    """-> (geojson, None) oder (None, Fehlertext). Gleicher Weg wie fetch_nina: requests.get, Timeout, User-Agent."""
    u = _lg_mod.url(wid)
    if not u:
        return None, "ID ungueltig"
    r = requests.get(u, timeout=8, headers=_LG_UA)
    if r.status_code != 200:
        return None, "HTTP %d" % r.status_code
    if len(r.content or b"") > _lg_mod.MAX_RAW:
        return None, "Antwort zu gross (%d Bytes)" % len(r.content)
    return r.json(), None


def _lg_round(warnings, now=None, fetch=None):
    if _lg_mod is None or not isinstance(warnings, list):
        return None
    now = int(now or _lg_time.time())
    if now - _LG["t"] < _LG_ROUND_S or not _LG_LOCK.acquire(False):
        return None
    res = {"ok": 0, "fail": 0, "ids": 0}
    try:
        _LG["t"] = now
        ids = _lg_ids(warnings, now)
        res["ids"] = len(ids)
        t0 = _lg_time.time()
        for wid in _lg_mod.due(ids, now, _LZ_PATH, _LG_MAX_N):
            if _lg_time.time() - t0 > _LG_BUDGET_S:
                break
            try:
                doc, err = (fetch or _lg_fetch_one)(wid)
            except Exception as e:
                doc, err = None, "Abruf: %s" % str(e)[:100]
            if doc is not None:
                feat, info = _lg_mod.parse(doc, wid, now)
                if feat:
                    n = _lg_mod.store_ok(wid, feat, info, now, _LZ_PATH)
                    res["ok"] += 1
                    print("lageGeo: %s Polygon %d->%d Punkte, %d m, %d Bytes, %s Ereignis(se)" % (wid, info["pts_in"], info["pts"], info["tol_m"], info["bytes"], n), flush=True)
                    continue
                err = info
            _lg_mod.store_fail(wid, err, now, _LZ_PATH)
            res["fail"] += 1
            print("lageGeo: %s kein Polygon (%s) - Kreis bleibt bzw. letzter Stand" % (wid, err), flush=True)
        if now - _LG["t_clean"] > 3600:
            _LG["t_clean"] = now
            _lg_mod.cleanup(now, _LZ_PATH)
        _LG.update(ok=_LG["ok"] + res["ok"], fail=_LG["fail"] + res["fail"], last=now, err=None)
    except Exception as e:
        _LG["err"] = str(e)[:160]
        print("lageGeo Runde:", e, flush=True)
    finally:
        _LG_LOCK.release()
    return res


_lg_orig_fetch_nina = fetch_nina


def fetch_nina():
    r = _lg_orig_fetch_nina()
    try:
        _lg_round(r)
    except Exception as e:
        print("lageGeo nach NINA:", e, flush=True)
    return r


def _lg_wrap_mgr():
    """events_from_nina: Kreis -> Polygon aus Cache; map_geojson: gleiche Warnung nur einmal (Gebiete zusammengefasst), aufgehobene NINA-Meldungen nicht als Zone, + Kennzahlen."""
    if _lz_mgr is None or _lg_mod is None:
        return False
    orig_ev, orig_map = _lz_mgr.events_from_nina, _lz_mgr.map_geojson

    def events_from_nina(nina, now=None):
        evs = orig_ev(nina, now)
        try:
            ids = [str(e.get("ext_id")).split(":")[1] for e in evs if str(e.get("ext_id") or "").startswith("NINA:")]
            geo = _lg_mod.geo_for(ids, _LZ_PATH) if ids else {}
            return [_lg_mod.apply_to_event(e, geo) for e in evs] if geo else evs
        except Exception as ex:
            print("lageGeo Ereignisse:", ex, flush=True)
            return evs

    def map_geojson(base, path=None, now=None):
        m = orig_map(base, path, now)
        try:
            feats, seen = [], {}
            for f in m.get("features") or []:
                pr = f.get("properties") or {}
                if pr.get("kind") == "hazard" and pr.get("source") == "NINA" and pr.get("severity") == "info":
                    continue  # aufgehobene NINA-Meldung (Cancel) ist keine Gefahrenzone
                w = pr.get("warn_id") if pr.get("lagegeo") else None
                if w:
                    if w in seen:
                        if pr.get("area") and pr.get("area") not in seen[w]["properties"]["areas"]:
                            seen[w]["properties"]["areas"].append(pr.get("area"))
                        continue
                    pr["areas"] = [pr.get("area")] if pr.get("area") else []
                    seen[w] = f
                feats.append(f)
            m["features"] = feats
            m["lagegeo"] = dict(_lg_mod.stats(path or _LZ_PATH), round_t=_LG["last"], round_err=_LG["err"], selftest=_LG["selftest"])
        except Exception as ex:
            print("lageGeo Karte:", ex, flush=True)
        return m

    events_from_nina.lagegeo = map_geojson.lagegeo = True
    if not getattr(orig_ev, "lagegeo", False):
        _lz_mgr.events_from_nina = events_from_nina
    if not getattr(orig_map, "lagegeo", False):
        _lz_mgr.map_geojson = map_geojson
    return True


_LG_ROLE_TXT = {"bc": "Rundfunk fest (UKW/DAB)", "rot": "Wechselbetrieb (QRM, 433, nach Schaltern)", "single": "Einzelbetrieb (ein Stick)", "433": "433 MHz", "aprs": "APRS"}
_LG_HEALTH_TXT = {"ok": "Stick ok", "grau": "Stick wird geprüft", "gelb": "Stick auffällig", "rot": "Stick gestört"}


def _lg_sdr_fields(st):
    """SDR1/SDR2 lesbar: Rolle-ID bleibt (sdrN_role), Klartext dazu; sdr2_status = Betriebszustand, sdr2_health = Stick-Pruefung getrennt."""
    st = st if isinstance(st, dict) else {}
    out = {}
    du = st.get("dual") if isinstance(st.get("dual"), dict) else {}
    s2c = st.get("stick2") if isinstance(st.get("stick2"), dict) else {}
    s2 = st.get("s2") if isinstance(st.get("s2"), dict) else {}
    r1 = du.get("role1") or st.get("role")
    r2 = du.get("role2") or s2c.get("role")
    out["sdr1_role_txt"] = _LG_ROLE_TXT.get(r1, r1)
    out["sdr2_role_txt"] = _LG_ROLE_TXT.get(r2, r2) if s2c else None
    names = globals().get("_SDR_NAMES") or {}
    h = st.get("stick_health2") if isinstance(st.get("stick_health2"), dict) else (s2.get("stick_health") if isinstance(s2.get("stick_health"), dict) else {})
    lvl = h.get("lvl")
    out["sdr2_health"] = {"lvl": lvl, "txt": h.get("txt") or _LG_HEALTH_TXT.get(lvl), "why": h.get("why")} if h else None
    if not s2c:
        state, lv = "nicht eingerichtet", "aus"
    elif s2c.get("enabled") is False:
        state, lv = "aus (abgeschaltet)", "aus"
    elif s2c.get("present") is False:
        state, lv = "fehlt (nicht angeschlossen)", "rot"
    elif s2.get("err"):
        state, lv = "Fehler: %s" % str(s2.get("err"))[:80], "rot"
    else:
        a = str(s2.get("active") or "")
        if a in ("", "idle"):
            state, lv = "bereit (Pause)", "gruen"
        elif a == "nostick":
            state, lv = "kein Stick", "rot"
        else:
            k = a.split(":")[0]
            state, lv = "aktiv: %s" % (names.get(a) or names.get(k) or a), "gruen"
        if lvl in ("gelb", "rot"):
            lv = lvl
        elif lvl == "grau" and lv == "gruen":
            lv = "grau"
    out["sdr2_status"] = state + ((" · " + out["sdr2_health"]["txt"]) if out["sdr2_health"] and out["sdr2_health"].get("txt") else "")
    out["sdr2_lvl"] = lv  # gruen/grau/gelb/rot/aus - grau = wird geprueft, keine Stoerung
    return out


def _lg_wrap_live():
    if _lz_mgr is None or getattr(_lz_mgr.live, "lagegeo", False):
        return False
    orig = _lz_mgr.live

    def live(base, path=None, br=None, extra=None, now=None):
        d = orig(base, path, br, extra, now)
        try:
            d.update(_lg_sdr_fields(_lz_mgr._load(_lz_os.path.join(base, "sdr_status.json"), {}) or {}))
        except Exception as ex:
            print("lageGeo SDR-Felder:", ex, flush=True)
        return d

    live.lagegeo = True
    _lz_mgr.live = live
    return True


def _lg_selftest():
    import tempfile, os as _o, json as _j
    assert _lg_mod is not None and _lz_mgr is not None and _lz_dbm is not None
    global _LZ_PATH
    keep_path, keep_t = _LZ_PATH, _LG["t"]
    d = tempfile.mkdtemp(prefix="lagegeo-")
    _LZ_PATH = _o.path.join(d, "t.db")
    try:
        now = int(_lg_time.time())
        poly = {"type": "FeatureCollection", "features": [{"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [[[11.0, 49.4], [11.1, 49.4], [11.1, 49.5], [11.0, 49.5], [11.0, 49.4]]]}}]}
        nina = [{"city": "Nürnberg", "title": "Gefahr", "id": "mow.SELF-1", "msgType": "Alert"}, {"city": "Fürth Stadt", "title": "Gefahr", "id": "mow.SELF-1", "msgType": "Alert"},
                {"city": "LK Fürth", "title": "Weg", "id": "mow.SELF-2", "msgType": "Alert"}, {"city": "LK Fürth", "title": "aufgehoben", "id": "mow.SELF-3", "msgType": "Cancel"}]
        for e in _lz_mgr.events_from_nina(nina, now):
            _lz_dbm.upsert_event(e, _LZ_PATH)
        _LG["t"] = 0
        r = _lg_round(nina, now, fetch=lambda w: (poly, None) if w == "mow.SELF-1" else (None, "HTTP 404"))
        assert r == {"ok": 1, "fail": 1, "ids": 2}, r
        ev = {e["ext_id"]: e for e in _lz_dbm.active_events(now, _LZ_PATH)}
        assert _j.loads(ev["NINA:mow.SELF-1:Fürth Stadt"]["geojson"])["properties"]["lagegeo"] and _j.loads(ev["NINA:mow.SELF-2:LK Fürth"]["geojson"])["properties"]["approx"]
        up = _lz_mgr.events_from_nina(nina, now)  # spaeterer Abgleich darf das Polygon nicht durch den Kreis ersetzen
        assert _j.loads([e for e in up if e["ext_id"] == "NINA:mow.SELF-1:Nürnberg"][0]["geojson"])["geometry"]["type"] == "Polygon"
        m = _lz_mgr.map_geojson(d, _LZ_PATH, now)
        hz = [f for f in m["features"] if f["properties"].get("kind") == "hazard"]
        assert len(hz) == 2 and [f for f in hz if f["properties"].get("lagegeo")][0]["properties"]["areas"] == ["Nürnberg", "Fürth Stadt"], hz
        assert m["lagegeo"]["poly"] == 1 and m["lagegeo"]["fail"] == 1
        assert _lg_fetch_one("../boese") == (None, "ID ungueltig")
        f2 = _lg_sdr_fields({"dual": {"role1": "bc", "role2": "rot"}, "stick2": {"role": "rot", "enabled": True, "present": True}, "s2": {"active": "idle"}, "stick_health2": {"lvl": "grau", "txt": "Stick wird geprueft"}})
        assert f2["sdr2_lvl"] == "grau" and f2["sdr2_status"].startswith("bereit (Pause)") and f2["sdr2_role_txt"].startswith("Wechselbetrieb") and f2["sdr1_role_txt"].startswith("Rundfunk"), f2
        assert _lg_sdr_fields({"stick2": {"present": False}})["sdr2_lvl"] == "rot" and _lg_sdr_fields({})["sdr2_status"] == "nicht eingerichtet"
        return "lageGeo selftest ok"
    finally:
        _LZ_PATH, _LG["t"] = keep_path, keep_t
        _LG.update(ok=0, fail=0, last=None)


try:
    _lg_wrap_mgr()
    _lg_wrap_live()
    try:
        _LG["selftest"] = _lg_selftest()
    except Exception as _lg_e1:
        _LG["selftest"] = "lageGeo selftest FEHLER: %s" % _lg_e1
    print("lageGeo aktiv: %s · %s" % (_LG["selftest"], _LG["err"] or "Modul ok"), flush=True)
except Exception as _lg_e2:
    print("lageGeo:", _lg_e2, flush=True)
# ===== /lageGeo =====
LGDASH_EOF
EXPECT_PATCH="0ca3021fb1eb2e78a00ccbf43f6bae89ec0af5a86e05cebfc0774f258ab05022"
cat > "$W/patch-lg.py" << 'LGPATCH_EOF'
"""lageGeo: Block in dashboard.py direkt nach /lageDB einsetzen oder ersetzen (idempotent).
Aufruf: patch-lg.py QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== lageGeo:", "# ===== /lageGeo =====\n"
ANCHOR = "# ===== /lageDB =====\n"
bad = [n.strip()[:40] for n in ("# ===== lageDB:", "_LZ_PATH = ", "def _lz_ctx():", "def fetch_nina():", "import requests", "# ===== dabHist:", "\nif __name__ == \"__main__\":\n") if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("lageGeo-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
if not bad and s.index(ANCHOR) > s.index("\nif __name__ == \"__main__\":\n"):
    bad.append("/lageDB steht nach __main__")
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: lageGeo-Block steht nicht direkt nach /lageDB"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
LGPATCH_EOF
EXPECT_GUARD="01f869e5429189dbc348000649612827eb61db3b918e96c2361461f6b7e4f993"
cat > "$W/guard_lg.py" << 'LGGUARD_EOF'
"""lageGeo AST-Guard. Aufruf: guard_lg.py DASH_ALT DASH_NEU lagegeo.py -> 0 ok, 1 Verstoss.
Einziger neuer Netzzugriff: requests.get (wie fetch_nina) auf https://warnung.bund.de/api31/warnings/<id>.geojson.
Keine Sendestelle, kein shell=True, keine Sockets/Server/Prozesse/Faeden, keine neuen Routen/after_request."""
import ast
import sys

RISKY = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "send_nina_to_bayern", "sendText", "sendData", "TCPInterface",
         "urlopen", "socket", "create_connection", "bind", "listen", "serve_forever", "HTTPServer", "make_server", "system", "Popen", "run", "call",
         "check_output", "check_call", "execv", "spawn", "fork", "Thread", "Timer", "start_new_thread", "add_url_rule", "after_request", "before_request", "post", "put")
NETMOD = {"requests", "urllib", "http", "socket", "subprocess", "_rq", "_req", "os"}


def info(src):
    t = ast.parse(src)
    imp, calls, shell, attrs, strs, defs = set(), [], 0, [], [], []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False):
            shell += 1
        if isinstance(n, ast.Call):
            f = n.func
            calls.append(f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
            if isinstance(f, ast.Attribute):
                attrs.append(((f.value.id if isinstance(f.value, ast.Name) else "?"), f.attr))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and ("://" in n.value):
            strs.append(n.value)
        if isinstance(n, ast.FunctionDef):
            defs.append(n.name)
    return imp, calls, shell, attrs, strs, defs


rd = lambda f: open(f, encoding="utf-8").read()
d0, d1, mod = rd(sys.argv[1]), rd(sys.argv[2]), rd(sys.argv[3])
A, Z = "# ===== lageGeo:", "# ===== /lageGeo ====="
inst = A in d0
blk = d1[d1.index(A):d1.index(Z)]
err = []
bi, bc, bs, _, bstr, bdef = info(d0)
ni, nc, ns, _, nstr, ndef = info(d1)
li, lc, ls, la, lstr, ldef = info(blk)
if ni - bi - {"lagegeo", "time", "threading", "tempfile", "os", "json"}:
    err.append("Dashboard: Importe neu %s" % (ni - bi))
if ns != bs or ls:
    err.append("Dashboard: shell=True neu")
for nm in RISKY:
    if nc.count(nm) != bc.count(nm) or nm in lc:
        err.append("Dashboard: Aufruf %s neu/im Block (%d->%d)" % (nm, bc.count(nm), nc.count(nm)))
net = [x for x in la if x[0] in NETMOD and x != ("os", "path") and x[0] != "_o"]
if net != [("requests", "get")]:
    err.append("Block: genau ein requests.get erwartet, gefunden %s" % net)
if lstr:
    err.append("Block: Adressen im Code %s (Adresse nur aus lagegeo.url)" % lstr)
if [c for c in lc if c.startswith(("send", "maybe_mesh", "mesh_"))]:
    err.append("Block: Sendeaufruf")
if ndef.count("fetch_nina") != bdef.count("fetch_nina") + (0 if inst else 1) or "_lg_orig_fetch_nina()" not in blk:
    err.append("Block: fetch_nina genau einmal umhuellt (Original wird aufgerufen) erwartet")
for w in ("<script", "POST", "meshtastic", "subprocess", "Thread(", "socket"):
    if w in blk:
        err.append("Block enthaelt %s" % w)
mi, mc, ms, ma, mstr, _ = info(mod)
if mi - {"json", "math", "re", "time", "database", "os", "tempfile"}:
    err.append("lagegeo.py: Importe %s" % (mi - {"json", "math", "re", "time", "database", "os", "tempfile"}))
if ms or [x for x in ma if x[0] in NETMOD - {"os"}] or [c for c in mc if c in RISKY or c.startswith(("send", "maybe_mesh"))]:
    err.append("lagegeo.py: Netz-/Prozess-/Sendeaufruf")
if mstr != ["https://warnung.bund.de/api31/warnings/%s.geojson"]:
    err.append("lagegeo.py: Adressen %s" % mstr)
for w in ("meshtastic", "subprocess", "urllib", "requests", "socket"):
    if w in mod:
        err.append("lagegeo.py enthaelt %s" % w)
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard lageGeo: einziger neuer Netzzugriff requests.get (wie fetch_nina, Timeout 8 s) auf warnung.bund.de/api31/warnings/<id>.geojson, "
      "keine Sendestelle/Mesh, kein shell=True, keine Sockets/Server/Prozesse/Faeden, keine neuen Routen/after_request; lagegeo.py ohne Netz")
LGGUARD_EOF
EXPECT_LC="ce93e3ddcf0b05d63c62c93a67f29e114bfe5bc488c22c1c2ae372329e852e36"
cat > "$W/layout_check.py" << 'LGLC_EOF'
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
LGLC_EOF
EXPECT_BT="5e6a8c69114b5c9a5f3f236881957bff47e11e839a07f3aab189b3d13041f071"
cat > "$W/blocktest_lg.py" << 'LGBT_EOF'
"""lageGeo Probelauf ohne Dashboard und ohne Netz: blocktest_lg.py LAGEDB_BLOCK LAGEGEO_BLOCK MODULDIR
requests wird durch eine Attrappe ersetzt (liefert ein Polygon bzw. HTTP 503)."""
import json, os, shutil, sys, tempfile, time
bdb, blg, mdir = sys.argv[1:4]
tmp = tempfile.mkdtemp(prefix="lgbt-")
sys.path.insert(0, mdir)
from flask import Flask, jsonify
app = Flask("lgbt")
calls = []


class R:
    def __init__(self, code, doc):
        self.status_code = code
        self.content = json.dumps(doc).encode()

    def json(self):
        return json.loads(self.content)


class FakeRequests:
    @staticmethod
    def get(url, timeout=None, headers=None):
        calls.append((url, timeout, (headers or {}).get("User-Agent")))
        if "mow.BT-OK" in url:
            ring = [[11.0 + 0.1 * (i % 2), 49.4 + 0.0001 * i] for i in range(500)]
            ring.append(ring[0])
            return R(200, {"type": "FeatureCollection", "features": [{"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [[[11.0, 49.4], [11.2, 49.4], [11.2, 49.5], [11.0, 49.5], [11.0, 49.4]]]}}]})
        return R(503, {})


nina = [{"city": "Nürnberg", "title": "Gefahr Test", "id": "mow.BT-OK", "msgType": "Alert"}, {"city": "LK Fürth", "title": "Gefahr B", "id": "mow.BT-FAIL", "msgType": "Alert"}]
g = {"__name__": "lgbt", "app": app, "jsonify": jsonify, "_SDR_BASE": tmp, "requests": FakeRequests,
     "data_store": {"nina": {"value": nina}}, "_br24_state": lambda: {"state": "gruen"}, "fetch_nina": lambda: list(nina)}
for b in (bdb, blg):
    with open(b, encoding="utf-8") as f:
        code = f.read()
    exec(compile(code, b, "exec"), g)
assert g["_LZ"]["selftest"] == "lageDB selftest ok", g["_LZ"]
assert g["_LG"]["selftest"] == "lageGeo selftest ok", g["_LG"]
c = app.test_client()
L = c.get("/api/sdr/live").get_json()  # Abgleich legt NINA-Ereignisse (Kreise) an
assert "sdr2_lvl" in L and "sdr1_role_txt" in L and L["sdr2_status"] == "nicht eingerichtet", L
r = g["fetch_nina"]()            # vorhandener NINA-Weg -> Polygonrunde
assert r == nina and len(calls) == 2 and all(u.startswith("https://warnung.bund.de/api31/warnings/") and u.endswith(".geojson") and t == 8 and ua == "KaeswasserLage/1.0" for u, t, ua in calls), calls
g["fetch_nina"]()                # gleich danach: Runde gesperrt (2 min), kein Abruf
assert len(calls) == 2, calls
m = c.get("/api/sdr/map").get_json()
hz = {f["properties"].get("headline"): f for f in m["features"] if f["properties"].get("kind") == "hazard"}
assert hz["Gefahr Test"]["geometry"]["type"] == "Polygon" and hz["Gefahr Test"]["properties"]["lagegeo"], hz
assert hz["Gefahr B"]["geometry"]["type"] == "Point" and hz["Gefahr B"]["properties"]["radius_m"], hz
assert m["lagegeo"]["poly"] == 1 and m["lagegeo"]["fail"] == 1 and m["lagegeo"]["selftest"] == "lageGeo selftest ok", m["lagegeo"]
g["_LZ"]["sync"].last = 0
c.get("/api/sdr/live")           # erneuter Abgleich ersetzt das Polygon nicht durch den Kreis
m2 = c.get("/api/sdr/map").get_json()
assert [f for f in m2["features"] if f["properties"].get("headline") == "Gefahr Test"][0]["geometry"]["type"] == "Polygon"
g["_LG"]["t"] = 0
g["_LZ_PATH"] = tmp              # kaputte DB: nichts darf abstuerzen
assert g["fetch_nina"]() == nina and c.get("/api/sdr/map").status_code == 200
print("OK lageGeo-Probelauf: Abruf nur ueber requests.get (Timeout 8 s, User-Agent wie NINA), 1 Polygon + 1 Kreis-Rueckfall, Sperrzeit wirkt, Polygon bleibt nach Abgleich, kaputte DB ohne Absturz; Karte %d Bytes" % len(json.dumps(m2)))
shutil.rmtree(tmp, ignore_errors=True)
LGBT_EOF
EXPECT_MOD="3788481354f4765624a2197d86c749e1622e5dc363bfdb73a88550e2d712211b"
cat > "$W/lagegeo.py" << 'LGMOD_EOF'
"""lagegeo.py - echte Warngebiete (Polygone) fuer lagezentrum.db (Kaeswasser Lage Monitor, lageGeo).

Kein Netzwerk in diesem Modul: der Abruf der offiziellen Warngebiete (API_URL, warnung.bund.de api31) passiert im
Dashboard ueber denselben HTTP-Weg wie fetch_nina (Timeout, User-Agent). Hier nur:
- Pruefen/Zusammenfassen der GeoJSON-Antwort zu EINER Feature mit (Multi)Polygon
- Vereinfachen (Douglas-Peucker in Metern, Start 100 m, gross -> groeber bis MAX_BYTES)
- Cache je Warnungs-ID in Tabelle geo_cache (letzter guter Stand bleibt bei Fehlern = keepLast),
  Rueckstellung bei Fehlern (5 min verdoppelnd bis 6 h), Auffrischen nach REFRESH_S
- Schreiben in events.geojson aller Ereignisse 'NINA:<id>:*' (ext_id) - sonst bleibt der Kreis (Fallback)
Jede Funktion faengt Fehler ab.
"""
import json
import math
import re
import time

try:
    import database as _db
except Exception:
    _db = None

API_URL = "https://warnung.bund.de/api31/warnings/%s.geojson"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,199}$")
TOL_M = (100, 250, 500, 1000, 2500)   # Vereinfachung in Metern, erste Stufe 100 m
MAX_BYTES = 40000                      # je Warngebiet nach Vereinfachung
MAX_RAW = 3000000                      # Antwort groesser -> verwerfen
REFRESH_S = 3 * 3600                   # gutes Polygon so lange nicht neu holen
BACKOFF_S = (300, 21600)               # Fehler: 5 min, verdoppelnd, max 6 h
KEEP_UNUSED_S = 7 * 86400
_last_err = [None]


def _log(*a):
    _last_err[0] = " ".join(str(x) for x in a)[:200]
    print("lageGeo:", *a, flush=True)


def last_error():
    return _last_err[0]


def url(warn_id):
    """Feste API-Adresse; nur unbedenkliche IDs (kein Pfad, keine Abfrage)."""
    w = str(warn_id or "")
    return API_URL % w if ID_RE.match(w) and ".." not in w else None


# ---------------------------------------------------------------- Geometrie
def _dp(pts, tol):
    """Douglas-Peucker iterativ auf [(x,y)] in Metern; Endpunkte bleiben."""
    n = len(pts)
    if n < 3:
        return list(pts)
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = pts[a]
        bx, by = pts[b]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        dmax, imax = -1.0, -1
        for i in range(a + 1, b):
            px, py = pts[i]
            if L2 == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
                d = math.hypot(px - ax - t * dx, py - ay - t * dy)
            if d > dmax:
                dmax, imax = d, i
        if imax > 0 and dmax > tol:
            keep[imax] = True
            stack.append((a, imax))
            stack.append((imax, b))
    return [p for p, k in zip(pts, keep) if k]


def _ring_ok(r):
    return isinstance(r, list) and len(r) >= 4 and all(isinstance(p, (list, tuple)) and len(p) >= 2 and isinstance(p[0], (int, float)) and isinstance(p[1], (int, float))
                                                       and -180 <= p[0] <= 180 and -90 <= p[1] <= 90 for p in r)


def _simplify_ring(ring, tol, lat0, lon0):
    k = math.cos(math.radians(lat0)) * 111320.0
    xy = [((p[0] - lon0) * k, (p[1] - lat0) * 110540.0) for p in ring]
    if xy[0] != xy[-1]:
        xy.append(xy[0])
        ring = list(ring) + [ring[0]]
    # geschlossener Ring: am entferntesten Punkt teilen, beide Haelften vereinfachen
    far = max(range(len(xy)), key=lambda i: (xy[i][0] - xy[0][0]) ** 2 + (xy[i][1] - xy[0][1]) ** 2)
    if far == 0:
        return None
    out_xy = _dp(xy[:far + 1], tol) + _dp(xy[far:], tol)[1:]
    res = [[round(x / k + lon0, 5), round(y / 110540.0 + lat0, 5)] for x, y in out_xy]
    if res[0] != res[-1]:
        res.append(res[0])
    return res if len(res) >= 4 else None


def _polys(geom):
    """-> Liste Polygone (je Liste von Ringen) aus Polygon/MultiPolygon/GeometryCollection."""
    out = []
    if not isinstance(geom, dict):
        return out
    t = geom.get("type")
    if t == "Polygon":
        out.append(geom.get("coordinates") or [])
    elif t == "MultiPolygon":
        out.extend(geom.get("coordinates") or [])
    elif t == "GeometryCollection":
        for g in geom.get("geometries") or []:
            out.extend(_polys(g))
    return [p for p in out if isinstance(p, list) and p and _ring_ok(p[0])]


def parse(doc, warn_id=None, now=None):
    """GeoJSON (FeatureCollection/Feature/Geometrie) -> (feature_dict, info) oder (None, grund)."""
    try:
        now = int(now or time.time())
        if isinstance(doc, dict) and doc.get("type") == "FeatureCollection":
            geoms = [f.get("geometry") for f in doc.get("features") or [] if isinstance(f, dict)]
        elif isinstance(doc, dict) and doc.get("type") == "Feature":
            geoms = [doc.get("geometry")]
        else:
            geoms = [doc]
        polys = []
        for g in geoms:
            polys.extend(_polys(g))
        if not polys:
            return None, "keine Flaeche im GeoJSON"
        pts_in = sum(len(r) for p in polys for r in p)
        allp = [pt for p in polys for pt in p[0]]
        lon0 = sum(p[0] for p in allp) / len(allp)
        lat0 = sum(p[1] for p in allp) / len(allp)
        for tol in TOL_M:
            out = []
            for p in polys:
                outer = _simplify_ring(p[0], tol, lat0, lon0)
                if not outer:
                    continue
                holes = [h for h in (_simplify_ring(r, tol, lat0, lon0) for r in p[1:] if _ring_ok(r)) if h]
                out.append([outer] + holes)
            if not out:
                return None, "Flaeche nach Vereinfachung leer"
            geom = {"type": "Polygon", "coordinates": out[0]} if len(out) == 1 else {"type": "MultiPolygon", "coordinates": out}
            xs = [pt[0] for p in out for pt in p[0]]
            ys = [pt[1] for p in out for pt in p[0]]
            pts_out = sum(len(r) for p in out for r in p)
            feat = {"type": "Feature", "geometry": geom,
                    "properties": {"lagegeo": True, "approx": False, "warn_id": warn_id, "src": "warnung.bund.de", "fetched": now, "tol_m": tol,
                                   "pts_in": pts_in, "pts": pts_out, "center": [round((min(xs) + max(xs)) / 2, 5), round((min(ys) + max(ys)) / 2, 5)],
                                   "bbox": [min(xs), min(ys), max(xs), max(ys)]}}
            s = json.dumps(feat, ensure_ascii=False, separators=(",", ":"))
            if len(s.encode("utf-8")) <= MAX_BYTES:
                return feat, {"tol_m": tol, "pts_in": pts_in, "pts": pts_out, "bytes": len(s.encode("utf-8"))}
        return None, "Flaeche auch bei %d m groesser als %d Bytes" % (TOL_M[-1], MAX_BYTES)
    except Exception as e:
        return None, "GeoJSON nicht lesbar: %s" % str(e)[:80]


# ---------------------------------------------------------------- Cache (Tabelle geo_cache in lagezentrum.db)
_migrated = set()


def migrate(path=None):
    if _db is None:
        return False
    try:
        path = path or _db.DB_PATH
        _db.migrate(path)
        con = _db.connect(path)
        try:
            with con:
                con.execute("CREATE TABLE IF NOT EXISTS geo_cache (warn_id TEXT PRIMARY KEY, geojson TEXT, fetched INTEGER, tried INTEGER, ok INTEGER, "
                            "err TEXT, fails INTEGER DEFAULT 0, next_try INTEGER, pts_in INTEGER, pts INTEGER, bytes INTEGER, used INTEGER)")
        finally:
            con.close()
        _migrated.add(path)
        return True
    except Exception as e:
        _log("Migration:", e)
        return False


def _con(path):
    path = path or _db.DB_PATH
    if path not in _migrated:
        migrate(path)
    return _db.connect(path)


def due(ids, now=None, path=None, max_n=3):
    """IDs, die jetzt geholt werden sollen (unbekannt, alt, oder Rueckstellung abgelaufen), hoechstens max_n."""
    now = int(now or time.time())
    out = []
    try:
        ids = [i for i in dict.fromkeys(str(x) for x in ids or []) if url(i)]
        if not ids or _db is None:
            return []
        con = _con(path)
        try:
            rows = {r["warn_id"]: r for r in con.execute("SELECT * FROM geo_cache WHERE warn_id IN (%s)" % ",".join("?" * len(ids)), ids)}
            with con:
                con.executemany("UPDATE geo_cache SET used=? WHERE warn_id=?", [(now, i) for i in rows])
        finally:
            con.close()
        for i in ids:
            r = rows.get(i)
            if r is None:
                out.append(i)
            elif (r["next_try"] or 0) <= now and not (r["ok"] and r["geojson"] and now - (r["fetched"] or 0) < REFRESH_S):
                out.append(i)
        return out[:max_n]
    except Exception as e:
        _log("due:", e)
        return []


def store_ok(warn_id, feat, info, now=None, path=None):
    now = int(now or time.time())
    try:
        s = json.dumps(feat, ensure_ascii=False, separators=(",", ":"))
        con = _con(path)
        try:
            with con:
                con.execute("INSERT INTO geo_cache(warn_id, geojson, fetched, tried, ok, err, fails, next_try, pts_in, pts, bytes, used) VALUES(?,?,?,?,1,NULL,0,?,?,?,?,?) "
                            "ON CONFLICT(warn_id) DO UPDATE SET geojson=excluded.geojson, fetched=excluded.fetched, tried=excluded.tried, ok=1, err=NULL, fails=0, "
                            "next_try=excluded.next_try, pts_in=excluded.pts_in, pts=excluded.pts, bytes=excluded.bytes, used=excluded.used",
                            (warn_id, s, now, now, now + REFRESH_S, info.get("pts_in"), info.get("pts"), info.get("bytes"), now))
                pre = "NINA:%s:" % warn_id
                n = 0
                for r in con.execute("SELECT ext_id, geojson FROM events WHERE substr(ext_id, 1, ?)=?", (len(pre), pre)).fetchall():
                    e = apply_to_event({"ext_id": r["ext_id"], "geojson": r["geojson"]}, {warn_id: s})
                    n += con.execute("UPDATE events SET geojson=?, lon=?, lat=? WHERE ext_id=?", (e["geojson"], e.get("lon"), e.get("lat"), r["ext_id"])).rowcount
        finally:
            con.close()
        return n
    except Exception as e:
        _log("speichern:", e)
        return None


def store_fail(warn_id, err, now=None, path=None):
    """Fehler merken, letzten guten Stand behalten (keepLast), Rueckstellung verdoppeln."""
    now = int(now or time.time())
    try:
        con = _con(path)
        try:
            r = con.execute("SELECT fails FROM geo_cache WHERE warn_id=?", (warn_id,)).fetchone()
            fails = (r["fails"] or 0) + 1 if r else 1
            nxt = now + min(BACKOFF_S[1], BACKOFF_S[0] * 2 ** min(fails - 1, 10))
            with con:
                con.execute("INSERT INTO geo_cache(warn_id, tried, ok, err, fails, next_try, used) VALUES(?,?,0,?,?,?,?) "
                            "ON CONFLICT(warn_id) DO UPDATE SET tried=excluded.tried, ok=0, err=excluded.err, fails=excluded.fails, next_try=excluded.next_try, used=excluded.used",
                            (warn_id, now, str(err)[:160], fails, nxt, now))
        finally:
            con.close()
        return nxt
    except Exception as e:
        _log("Fehler merken:", e)
        return None


def geo_for(ids, path=None):
    """{warn_id: Feature-JSON} fuer IDs mit (letztem) gutem Polygon."""
    try:
        ids = [str(i) for i in dict.fromkeys(ids or []) if i]
        if not ids or _db is None:
            return {}
        con = _con(path)
        try:
            return {r["warn_id"]: r["geojson"] for r in con.execute("SELECT warn_id, geojson FROM geo_cache WHERE geojson IS NOT NULL AND warn_id IN (%s)" % ",".join("?" * len(ids)), ids)}
        finally:
            con.close()
    except Exception as e:
        _log("lesen:", e)
        return {}


def stats(path=None):
    try:
        con = _con(path)
        try:
            r = con.execute("SELECT COUNT(*) n, SUM(geojson IS NOT NULL) poly, SUM(ok=0) fail, MAX(fetched) last_ok, MAX(tried) last_try, SUM(bytes) bytes FROM geo_cache").fetchone()
            e = con.execute("SELECT warn_id, err FROM geo_cache WHERE ok=0 ORDER BY tried DESC LIMIT 1").fetchone()
        finally:
            con.close()
        return {"n": r["n"], "poly": r["poly"] or 0, "fail": r["fail"] or 0, "last_ok": r["last_ok"], "last_try": r["last_try"], "bytes": r["bytes"] or 0,
                "last_err": ("%s: %s" % (e["warn_id"], e["err"])) if e else None}
    except Exception as ex:
        return {"error": str(ex)[:120]}


def cleanup(now=None, path=None):
    now = int(now or time.time())
    try:
        con = _con(path)
        try:
            with con:
                return con.execute("DELETE FROM geo_cache WHERE COALESCE(used, tried, 0) < ?", (now - KEEP_UNUSED_S,)).rowcount
        finally:
            con.close()
    except Exception as e:
        _log("aufraeumen:", e)
        return None


def apply_to_event(ev, geo):
    """NINA-Ereignis (aus sdr_manager.events_from_nina): Kreis durch echtes Polygon ersetzen, falls im Cache."""
    try:
        wid = str(ev.get("ext_id") or "").split(":")[1] if str(ev.get("ext_id") or "").startswith("NINA:") else None
        s = geo.get(wid) if wid and isinstance(geo, dict) else None
        if not s:
            return ev
        f = json.loads(s)
        try:
            old = json.loads(ev["geojson"]) if ev.get("geojson") else {}
        except Exception:
            old = {}
        f["properties"]["area"] = (old.get("properties") or {}).get("area") or ev.get("area")
        c = f["properties"].get("center") or [None, None]
        return dict(ev, geojson=json.dumps(f, ensure_ascii=False, separators=(",", ":")), lon=c[0], lat=c[1])
    except Exception as e:
        _log("Ereignis:", e)
        return ev


def selftest():
    import os
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "g.db")
    now = int(time.time())
    # Kreis mit 2000 Punkten (~5 km Radius um Nuernberg) -> stark vereinfacht
    ring = [[round(11.0767 + 0.07 * math.cos(2 * math.pi * i / 2000), 6), round(49.4521 + 0.045 * math.sin(2 * math.pi * i / 2000), 6)] for i in range(2000)]
    ring.append(ring[0])
    hole = [[11.07, 49.45], [11.08, 49.45], [11.08, 49.455], [11.07, 49.455], [11.07, 49.45]]
    fc = {"type": "FeatureCollection", "features": [{"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [ring, hole]}, "properties": {}},
                                                    {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [[[10.9, 49.4], [10.91, 49.4], [10.91, 49.41], [10.9, 49.4]]]}}]}
    f, info = parse(fc, "mow.TEST-1", now)
    assert f and f["geometry"]["type"] == "MultiPolygon" and info["pts"] < 200 and info["pts_in"] > 2000 and info["tol_m"] == 100, info
    assert all(r[0] == r[-1] and len(r) >= 4 for poly in f["geometry"]["coordinates"] for r in poly)
    assert parse({"type": "Point", "coordinates": [1, 2]})[0] is None and parse("kaputt")[0] is None
    assert parse({"type": "Polygon", "coordinates": [[[500, 1], [2, 2], [3, 3], [500, 1]]]})[0] is None
    assert url("mow.DE-BY-N-W001-20261017-000") and url("../x") is None and url("a/b") is None and url("x?y") is None
    _db.upsert_event({"source": "NINA", "ext_id": "NINA:mow.TEST-1:Nürnberg", "headline": "h", "expires": now + 3600,
                      "geojson": json.dumps({"type": "Feature", "geometry": {"type": "Point", "coordinates": [11.07, 49.45]}, "properties": {"radius_m": 9000, "approx": True, "area": "Nürnberg"}})}, p)
    assert due(["mow.TEST-1", "bad/id"], now, p) == ["mow.TEST-1"]
    assert store_ok("mow.TEST-1", f, info, now, p) == 1
    ev = _db.active_events(now, p)[0]
    assert json.loads(ev["geojson"])["properties"]["lagegeo"] and json.loads(ev["geojson"])["properties"]["area"] == "Nürnberg" and abs(ev["lat"] - 49.45) < 0.1
    assert due(["mow.TEST-1"], now + 60, p) == []
    assert store_fail("mow.TEST-1", "HTTP 503", now + REFRESH_S + 1, p) == now + REFRESH_S + 1 + 300
    assert "mow.TEST-1" in geo_for(["mow.TEST-1"], p)  # keepLast: Polygon bleibt trotz Fehler
    assert due(["mow.TEST-1"], now + REFRESH_S + 100, p) == [] and due(["mow.TEST-1"], now + REFRESH_S + 400, p) == ["mow.TEST-1"]
    store_fail("mow.TEST-1", "HTTP 503", now + REFRESH_S + 400, p)
    assert stats(p)["fail"] == 1 and stats(p)["poly"] == 1
    e2 = apply_to_event({"ext_id": "NINA:mow.TEST-1:Fürth Stadt", "geojson": json.dumps({"properties": {"area": "Fürth Stadt"}})}, geo_for(["mow.TEST-1"], p))
    assert json.loads(e2["geojson"])["properties"]["area"] == "Fürth Stadt" and json.loads(e2["geojson"])["geometry"]["type"] == "MultiPolygon"
    assert apply_to_event({"ext_id": "DH:5C:x"}, {}) == {"ext_id": "DH:5C:x"}
    assert cleanup(now + KEEP_UNUSED_S + 10 ** 6, p) == 1
    return "lagegeo selftest ok"


if __name__ == "__main__":
    print(selftest())
LGMOD_EOF
P="$W/patch-lg.py"; LB="$W/lg_dash_block.py"; SG="$W/guard_lg.py"; LC="$W/layout_check.py"; BT="$W/blocktest_lg.py"; LM="$W/lagegeo.py"
for x in "$EXPECT_BLK $LB" "$EXPECT_PATCH $P" "$EXPECT_GUARD $SG" "$EXPECT_LC $LC" "$EXPECT_BT $BT" "$EXPECT_MOD $LM"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis (an Guards erkannt, lageDB Pflicht) ----------
[[ -f "$F" ]] || { echo "STOP: dashboard.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16)
if [[ " $KNOWN_DASH16 " == *" $D16 "* ]]; then echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, bekannt: live nach lageDB)"; else echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen) weicht ab von $KNOWN_DASH16 - Erkennung ueber Guards"; fi
grep -q "# ===== lageDB:" "$F" && grep -q "# ===== /lageDB =====" "$F" || { echo "STOP: lageDB-Guard fehlt in dashboard.py (sha16 $D16) - erst apply-lagedb.sh, nichts geaendert"; exit 1; }
for m in database.py sdr_manager.py mesh_router.py; do
  [[ -f "$DASH_DIR/$m" ]] && grep -q "Kaeswasser Lage Monitor, Teil 1" "$DASH_DIR/$m" || { echo "STOP: lageDB-Modul $m fehlt/fremd - nichts geaendert"; exit 1; }
  cp "$DASH_DIR/$m" "$W/mt/$m"
done
if [[ -f "$MOD" ]] && ! grep -q "Kaeswasser Lage Monitor, lageGeo" "$MOD"; then echo "STOP: $MOD gibt es schon (fremde Datei, sha16 $(sha256sum "$MOD" | cut -c1-16)) - nichts geaendert"; exit 1; fi
python3 "$P" "$F" "$W/work/dashboard.py" "$LB" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
cp "$LM" "$W/work/lagegeo.py"; cp "$LM" "$W/mt/lagegeo.py"
echo "OK Basis erkannt: Guard lageDB (Block + Module database/sdr_manager/mesh_router), Anker /lageDB genau 1x, fetch_nina vorhanden; Dashboard $(cat "$W/p1.log")"
# ---------- 2) Trockenlauf ----------
python3 "$P" "$W/work/dashboard.py" "$W/work/d2.py" "$LB" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: Dashboard nicht idempotent"; exit 1; }
rm -f "$W/work/d2.py"
for py in python3 "$VPY"; do "$py" -W error -m py_compile "$W/work/lagegeo.py" || { echo "STOP: py_compile lagegeo ($py) - nichts geaendert"; exit 1; }; done
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile dashboard - nichts geaendert"; exit 1; }
for py in python3 "$VPY"; do
  (cd "$W/mt" && "$py" -W error lagegeo.py > "$W/mt.log" 2>&1) && grep -q "lagegeo selftest ok" "$W/mt.log" || { grep -v '^lagezentrum.db:' "$W/mt.log" | tail -8; echo "STOP: Selbsttest lagegeo ($py) - nichts geaendert"; exit 1; }
done
echo "OK Modul-Selbsttest lagegeo (Temp-DB, Vereinfachung, Cache, keepLast, Rueckstellung) mit python3 und $VPY"
python3 - "$F" "$W/lzblk.py" << 'XB'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = s.index("# ===== lageDB:"); b = s.index("# ===== /lageDB =====\n") + len("# ===== /lageDB =====\n")
open(sys.argv[2], "w", encoding="utf-8").write(s[a:b])
XB
(cd "$W" && "$VPY" -W error "$BT" "$W/lzblk.py" "$LB" "$W/mt" > "$W/bt.log" 2>&1) || { grep -v '^lagezentrum.db:' "$W/bt.log" | tail -8; echo "STOP: Block-Probelauf - nichts geaendert"; exit 1; }
grep '^OK lageGeo' "$W/bt.log"
# ---------- 3) AST-Guard ----------
python3 "$SG" "$F" "$W/work/dashboard.py" "$W/work/lagegeo.py" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung, keine JS-Aenderung (Block ohne <script>)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 4) Installieren ----------
RESTARTED=0
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/lagegeo.py" "$MOD"; then
  echo "OK lageGeo schon installiert - kein Neustart"
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  MOD_NEW=0; [[ -f "$MOD" ]] || MOD_NEW=1
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -15 | cut -c1-200 || true
    [[ -f "$F.bak-lagegeo-$TS" ]] && cp -a "$F.bak-lagegeo-$TS" "$F.rb" && mv -f "$F.rb" "$F"
    if [[ "$MOD_NEW" == 1 ]]; then rm -f "$MOD"; elif [[ -f "$MOD.bak-lagegeo-$TS" ]]; then cp -a "$MOD.bak-lagegeo-$TS" "$MOD.rb" && mv -f "$MOD.rb" "$MOD"; fi
    rm -f "$DASH_DIR/__pycache__"/lagegeo.* 2>/dev/null || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    cmp -s "$F" "$F.bak-lagegeo-$TS" && echo "  dashboard.py = Sicherung ($(sha256sum "$F" | cut -c1-16))" || echo "  WARNUNG dashboard.py ungleich Sicherung"
    echo "  Tabelle geo_cache in lagezentrum.db bleibt (wird ohne lageGeo nicht benutzt)"
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true)"
  }
  for x in "$F" "$MOD"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-lagegeo-$TS"
    { ls -1t "$x.bak-lagegeo-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  cp "$W/work/lagegeo.py" "$MOD.new" && chmod 644 "$MOD.new" && mv -f "$MOD.new" "$MOD" || { rb "installieren lagegeo"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-lagegeo-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-dashboard (prepper-sdr laeuft weiter) - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
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
  echo "Hinweis: node fehlt - JS-Pruefung uebersprungen (lageGeo aendert kein JS)"
fi
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
"${CURL[@]}" "$B/api/sdr/map" -o "$W/map.json" || true
python3 - "$W/live.json" "$W/map.json" << 'APIPY' || rbx "/api/sdr/live oder /api/sdr/map unvollstaendig"
import json, os, sys
d = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2]))
for k in ("status", "ber", "active_mast", "history", "sdr1_role", "sdr2_role", "sdr2_status", "sdr2_lvl", "sdr2_health", "sdr1_role_txt", "sdr2_role_txt"):
    assert k in d, k
assert d["status"] in ("SDR_OFFLINE", "OK", "PROBEALARM", "ECHTALARM"), d["status"]
assert (d.get("db") or {}).get("selftest") == "lageDB selftest ok"
g = m.get("lagegeo") or {}
assert m.get("type") == "FeatureCollection" and g.get("selftest") == "lageGeo selftest ok" and "error" not in g, g
assert sum(1 for f in m["features"] if f["properties"].get("kind") == "transmitter") >= 6
size = os.path.getsize(sys.argv[2])
assert size < 600000, size
hz = [f for f in m["features"] if f["properties"].get("kind") == "hazard"]
print("  /api/sdr/live: status %s, SDR1 %s (%s), SDR2 %s (%s) · %s [%s], ber %s, Mast %s" % (d["status"], d["sdr1_role"], d["sdr1_role_txt"], d["sdr2_role"], d["sdr2_role_txt"],
      d["sdr2_status"], d["sdr2_lvl"], d["ber"], d["active_mast"]))
print("  /api/sdr/map: %d Bytes, %d Gefahrenzonen (%d echte Flaechen, %d Kreise); geo_cache %s" % (size, len(hz), sum(1 for f in hz if f["properties"].get("lagegeo")),
      sum(1 for f in hz if f["geometry"]["type"] == "Point"), json.dumps({k: g.get(k) for k in ("n", "poly", "fail", "bytes", "last_err")}, ensure_ascii=False)))
APIPY
c=$(code -X POST "$B/api/sdr/map"); [[ "$c" == 405 ]] && echo "OK POST /api/sdr/map abgelehnt (405)" || rbx "POST /api/sdr/map nicht abgelehnt ($c)"
echo "Pruefe ber/Mast aus DAB-Pruefung (bis $DAB_WAIT_S s, nur Hinweis) ..."
t_end=$(( $(date +%s) + DAB_WAIT_S )); dab=""
while :; do
  dab=$("${CURL[@]}" "$B/api/sdr/live" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('ber') is not None and d.get('active_mast'):
    print('ber %s, Mast %s, Kanaele %s' % (d['ber'], d['active_mast'], ', '.join('%s SNR %s' % (t.get('channel'), t.get('snr')) for t in d.get('telemetry') or [])))
" 2>/dev/null || true)
  [[ -n "$dab" || $(date +%s) -ge $t_end ]] && break
  sleep 15
done
[[ -n "$dab" ]] && echo "OK DAB-Werte gefuellt: $dab" || echo "WARNUNG: nach $DAB_WAIT_S s noch keine ber/Mast - naechste DAB-Pruefung 11D/5C abwarten (kein Rollback)"
# ---------- 6) Abschluss ----------
c=$(code_r "$B/api/sdr/ui"); [[ "$c" == 200 ]] || rbx "/api/sdr/ui nach Test $c"
echo "OK /api/sdr/ui = 200 nach Test"
echo "OK guards lageGeo=$(grep -c '# ===== lageGeo:' "$F" || true) lageDB=$(grep -c '# ===== lageDB:' "$F" || true) dabHist=$(grep -c '# ===== dabHist:' "$F" || true) stickTestFix=$(grep -c '# ===== stickTestFix:' "$F" || true) stickTest=$(grep -c '# ===== stickTest:' "$F" || true) lageTest=$(grep -c '# ===== lageTest:' "$F" || true) sdrDual=$(grep -c '# ===== sdrDual:' "$F" || true) lageMesh1=$(grep -c '# ===== lageMesh1:' "$F" || true) sdrLage=$(grep -c '# ===== sdrLage:' "$F" || true) sdrUi=$(grep -c '# ===== sdrUi:' "$F" || true) br24Warn2=$(grep -c '# ===== br24Warn2:' "$F" || true)"
[[ -f "$F.bak-lagegeo-$TS" ]] && echo "Backups: *.bak-lagegeo-$TS (dashboard.py$([[ -f "$MOD.bak-lagegeo-$TS" ]] && printf ', lagegeo.py')), behalten: letzte $KEEP_LAST"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; lagegeo.py sha16 $(sha256sum "$MOD" | cut -c1-16), $(wc -l < "$MOD") Zeilen"
echo "Hinweis: Polygone werden nach jedem NINA-Abruf geholt (hoechstens 3 je 2 min, nur aktive Warnungen); ohne Warnungen im Gebiet bleibt die Karte bei den Sendern."
echo "COMMIT $COMMIT_ARG lageGeo=1"
