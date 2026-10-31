#!/bin/bash
set -eEuo pipefail
# commit51 kartePop - Karte /karte (nur Anzeige, Daten/MASTS_DB unveraendert):
#  - gleiche Strecke mehrerer Kanaele (z. B. Schweinau 11D/5C/10C, Bamberg-Geisberg) 4 px parallel versetzt - ohne Plugin, ohne CDN, offline, neu bei Zoom
#  - Klick auf Mast ODER Linie: Popup mit Name, Bundesland (OSM je Mastkoordinate), Entfernung ab Kalchreuth, Hoehe Standort + Antenne, MainID/SubID, SNR-Verlauf 24 h (15-min-Mittel)
#  - 'Fernempfang' ab 150 km nur als Text (pulsiert nicht); pulsieren weiter nur 'Ueberreichweite verifiziert' (TII empfangen und Distanz > Funkhorizont, Formel unveraendert)
#  - unbekannte TII mit SubID eines bekannten Senders (z. B. 02/03, 06/03, 09/03, 13/03 wie Schweinau 12/03): Hinweis 'moeglicher Dekodierfehler', NICHT eingetragen
#  - neue Route GET /api/karte/hist?ch=5C&tii=12/03 (nur lesen aus reception_log, mode=ro, 0,5 s Zeitlimit, 60 s Cache, ohne Seriennummer); Abruf nur beim Oeffnen eines Popups
#  dashboard.py: ein Block vor __main__ (keine geaenderte Zeile). lage_pages.py und prepper_sdr.py bleiben unveraendert.
# Aufruf: bash /tmp/apply-commit51.sh commit51 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 2a3625a3325653b1 (nach commit50) oder 67d58079139cd373 (neu), lage_pages.py 1d33ae9fd78f53dc, prepper_sdr.py 0900bfe6ba67e657.
# Sicherung dashboard.py.bak-commit51-ZEIT (letzte 3). Keine Datenbank-Aenderung (nur lesend). Nur prepper-dashboard wird neu gestartet. Sendet nichts, Gain-Stufe 16 bleibt.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
FL="$DASH_DIR/lage_pages.py"
FS="$DASH_DIR/prepper_sdr.py"
VENV="$DASH_DIR/venv"
VPY="$VENV/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/commit51-apply
KEEP_LAST=3
NM=commit51
KNOWN_D16="2a3625a3325653b1"; KNOWN_D16N="67d58079139cd373"; KNOWN_D16_C49="1dc1eedcb0c91342"; KNOWN_D16_C48="334b60f2ed228831"; KNOWN_D16_C47="74ac7bfd0eebd4e0"
KNOWN_L16="1d33ae9fd78f53dc"; KNOWN_S16="0900bfe6ba67e657"
PHASE=vorher
STATE=unbekannt
ERRLN=""; ERRCMD=""
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
trap 'ec=$?; if [[ $ec -ne 0 && -n "$ERRLN" ]]; then echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE$([[ "$PHASE" == vorher ]] && echo " - es wurde nichts geaendert")"; fi' EXIT
stop() { echo "STOP: $1 - nichts geaendert"; exit 1; }
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then stop "Dashboard-Port unklar ($PORT)"; fi
if [[ "$PORT" == "8080" ]]; then stop "Port 8080 ist kiwix-serve, nicht das Dashboard"; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== commit51 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): kartePop, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt"
EXPECT_PAL="45feaed48b77a616035112a3f48bd1eb80d364200d0f8a50946bb1c06f3c5f2a"
cat > "$W/patch.py" << 'MK_C51_PAL_EOF'
"""Patcher speedAsync (generisch wie relStop). Aufruf: patch-pw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis/teilweise gepatcht. Schreibt nur ZIEL (nie QUELLE)."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E = g["%s_EDITS" % kind.upper()]
ANCH = g.get("%s_ANCHOR" % kind.upper())
s = open(src, encoding="utf-8").read()
B = None
if blk != "-":
    B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
name = {"dsh": "dashboard.py", "fh": "funk_health.py", "hw": "mesh_hang_watchdog.py", "pd": "prepper_docs.py"}[kind]
new_in = [s.count(n) >= 1 for o, n in E]
blk_in = (B is None) or (s.count(B) == 1)
if all(new_in) and blk_in:
    rest = s.replace(B, "", 1) if B else s
    ok = all(rest.count(n) == 1 for o, n in E) and (B is None or s.count(B.splitlines()[0]) == 1)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
if any(new_in) or (B is not None and B.splitlines()[0] in s):
    print("%s: %s teilweise vorhanden (%d von %d Stellen%s)" % (name, label, sum(new_in), len(E), ", Block da" if B and B.splitlines()[0] in s else "")); raise SystemExit(2)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if B is not None:
    if s.count(ANCH) != 1:
        print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
    i = s.index(ANCH)
    s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen%s %s" % (name, len(E), (" + Block" if B else ""), label))
MK_C51_PAL_EOF
EXPECT_RAE="6040441642f9e703cc808cfaf3c1ae25f553c6f9e3716dcf844fdff444998711"
cat > "$W/edits.py" << 'MK_C51_RAE_EOF'
# Stellen fuer kartePop (commit51): Basis 2a3625a3325653b1 (Stand nach commit50); nur ein Block vor __main__, keine Aenderung an bestehenden Zeilen
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_C51_RAE_EOF
EXPECT_RAB="923ac546ed57a119d36fa9e76847a24d20e7aff596dd537c77fc8e7e51dd227f"
cat > "$W/blk.py" << 'MK_C51_RAB_EOF'
# ===== kartePop: Karte /karte - gleiche Strecke mehrerer Kanaele 4 px parallel versetzt (ohne Plugin, offline, neu bei Zoom), Klick auf Mast ODER Linie = Popup (Name, Bundesland, Entfernung ab Kalchreuth, Hoehe Standort + Antenne, MainID/SubID, SNR-Verlauf 24 h in 15-min-Mitteln), 'Fernempfang' ab 150 km nur als Text, 'Ueberreichweite verifiziert' nur bei empfangener TII (Horizontformel unveraendert), unbekannte TII mit SubID eines bekannten Senders: Hinweis moeglicher Dekodierfehler; Route GET /api/karte/hist (nur lesen, 0,5 s, 60 s Cache); MASTS_DB und prepper_sdr.py unveraendert; sendet nichts =====
import json as _kp_json
import math as _kp_math
import re as _kp_re
import sqlite3 as _kp_sql
import threading as _kp_thr
import time as _kp_time

KP_OFF_PX = 4                      # Abstand paralleler Linien gleicher Strecke (F1)
KP_FERN_KM = 150                   # 'Fernempfang' ab dieser Entfernung, nur Text, pulsiert nicht (F4)
KP_HIST_S = 86400                  # SNR-Verlauf: 24 h (F5)
KP_BUCKET_S = 900                  # 15-min-Mittel (F5)
KP_CACHE_S = 60                    # Zwischenspeicher je Kanal/TII
KP_CACHE_MAX = 32                  # hoechstens 32 Eintraege im Zwischenspeicher
KP_DB_TIMEOUT_S = 0.5              # Lesezugriff: Sperr-Wartezeit und Gesamtzeit je Abfrage
KP_PROG_N = 2000                   # Zeitpruefung alle 2000 SQLite-Schritte
KP_CH = ("11D", "5C", "10C")
KP_TII_RE = _kp_re.compile(r"^([0-9]{2})/?([0-9]{2})$")
KP_SQL_PTS = ("SELECT (timestamp / 900) * 900 AS b, AVG(snr), COUNT(*) FROM reception_log WHERE channel = ? AND tii = ? AND timestamp >= ? AND timestamp <= ? "
              "GROUP BY b ORDER BY b LIMIT 100")
KP_SQL_N60 = "SELECT COUNT(*) FROM reception_log WHERE channel = ? AND tii = ? AND timestamp >= ?"
KP_LAND_SRC = "OpenStreetMap Nominatim (reverse, zoom 5) je Mastkoordinate, Abruf 31.10.2026; Daten (c) OpenStreetMap-Mitwirkende, ODbL"
KP_LAND = (
    (47.5081, 9.78, 'Österreich (Vorarlberg)'),
    (47.5486, 10.5703, 'Bayern'),
    (47.5534, 10.3171, 'Bayern'),
    (47.5861, 11.1031, 'Bayern'),
    (47.6069, 11.3161, 'Bayern'),
    (47.6308, 12.2433, 'Österreich (Tirol)'),
    (47.6672, 12.5257, 'Bayern'),
    (47.7034, 12.0122, 'Bayern'),
    (47.723, 13.009, 'Österreich (Salzburg)'),
    (47.7259, 11.7386, 'Bayern'),
    (47.75, 11.5744, 'Bayern'),
    (47.8011, 11.0246, 'Bayern'),
    (47.8218, 9.3992, 'Baden-Württemberg'),
    (47.8588, 12.6122, 'Bayern'),
    (47.883, 10.642, 'Bayern'),
    (48.0421, 10.2192, 'Bayern'),
    (48.0688, 12.2081, 'Bayern'),
    (48.132, 11.2241, 'Bayern'),
    (48.1546, 8.6591, 'Baden-Württemberg'),
    (48.17, 10.5979, 'Bayern'),
    (48.1744, 11.5536, 'Bayern'),
    (48.1746, 12.0762, 'Bayern'),
    (48.1878, 11.6276, 'Bayern'),
    (48.2406, 12.6867, 'Bayern'),
    (48.25, 11.752, 'Bayern'),
    (48.3059, 8.9923, 'Baden-Württemberg'),
    (48.3588, 13.2016, 'Bayern'),
    (48.3594, 10.8858, 'Bayern'),
    (48.382, 9.9487, 'Baden-Württemberg'),
    (48.4053, 12.886, 'Bayern'),
    (48.4485, 12.3558, 'Bayern'),
    (48.4597, 10.6819, 'Bayern'),
    (48.4956, 9.2317, 'Baden-Württemberg'),
    (48.5306, 11.4819, 'Bayern'),
    (48.5432, 11.4313, 'Bayern'),
    (48.5655, 13.4335, 'Bayern'),
    (48.5693, 12.1127, 'Bayern'),
    (48.6083, 11.8028, 'Bayern'),
    (48.6108, 8.2018, 'Baden-Württemberg'),
    (48.618, 9.7854, 'Baden-Württemberg'),
    (48.6301, 12.4977, 'Bayern'),
    (48.685, 13.658, 'Bayern'),
    (48.7528, 8.2023, 'Baden-Württemberg'),
    (48.7606, 12.3349, 'Bayern'),
    (48.7636, 9.2058, 'Baden-Württemberg'),
    (48.766, 10.5072, 'Bayern'),
    (48.7855, 10.6682, 'Bayern'),
    (48.817, 13.2176, 'Bayern'),
    (48.8608, 10.1374, 'Baden-Württemberg'),
    (48.865, 14.2839, 'Tschechien'),
    (48.8781, 12.9937, 'Bayern'),
    (48.9012, 11.1617, 'Bayern'),
    (48.903, 11.8695, 'Bayern'),
    (48.9209, 8.6887, 'Baden-Württemberg'),
    (48.9275, 13.0279, 'Bayern'),
    (48.9464, 11.4287, 'Bayern'),
    (48.9464, 11.4288, 'Bayern'),
    (48.9576, 10.9014, 'Bayern'),
    (49.0369, 9.5503, 'Baden-Württemberg'),
    (49.0397, 12.1716, 'Bayern'),
    (49.0438, 11.0107, 'Bayern'),
    (49.0451, 11.0875, 'Bayern'),
    (49.0682, 10.5257, 'Bayern'),
    (49.0692, 10.5303, 'Bayern'),
    (49.0858, 12.7523, 'Bayern'),
    (49.1117, 9.251, 'Baden-Württemberg'),
    (49.2491, 12.891, 'Bayern'),
    (49.2801, 8.1227, 'Rheinland-Pfalz'),
    (49.3264, 11.3819, 'Bayern'),
    (49.3361, 12.6378, 'Bayern'),
    (49.3856, 10.2244, 'Bayern'),
    (49.4028, 8.7306, 'Baden-Württemberg'),
    (49.4125, 7.7406, 'Rheinland-Pfalz'),
    (49.4146, 10.378, 'Bayern'),
    (49.4181, 11.8792, 'Bayern'),
    (49.4264, 11.0378, 'Bayern'),
    (49.5074, 9.7824, 'Baden-Württemberg'),
    (49.5082, 12.5766, 'Bayern'),
    (49.5088, 12.0048, 'Bayern'),
    (49.5125, 11.5931, 'Bayern'),
    (49.5181, 11.46, 'Bayern'),
    (49.5398, 8.8036, 'Hessen'),
    (49.5603, 12.2611, 'Bayern'),
    (49.6025, 14.6711, 'Tschechien'),
    (49.6838, 9.2723, 'Bayern'),
    (49.7183, 12.1583, 'Bayern'),
    (49.738, 11.1809, 'Bayern'),
    (49.7543, 11.5594, 'Bayern'),
    (49.7567, 9.523, 'Baden-Württemberg'),
    (49.7805, 9.9063, 'Bayern'),
    (49.7949, 10.6109, 'Bayern'),
    (49.8132, 10.1332, 'Bayern'),
    (49.8239, 9.1107, 'Bayern'),
    (49.8269, 7.8338, 'Rheinland-Pfalz'),
    (49.8578, 10.1639, 'Bayern'),
    (49.8893, 11.062, 'Bayern'),
    (49.9075, 12.1389, 'Bayern'),
    (49.9239, 9.5819, 'Bayern'),
    (49.9328, 9.2408, 'Bayern'),
    (50.0189, 10.5994, 'Bayern'),
    (50.0226, 8.2771, 'Hessen'),
    (50.0311, 11.8139, 'Bayern'),
    (50.033, 10.3029, 'Bayern'),
    (50.0451, 14.3916, 'Tschechien'),
    (50.0572, 9.674, 'Bayern'),
    (50.0786, 9.11, 'Bayern'),
    (50.1004, 11.4698, 'Bayern'),
    (50.1088, 10.7359, 'Bayern'),
    (50.1093, 8.1334, 'Hessen'),
    (50.1353, 8.6546, 'Hessen'),
    (50.1362, 9.9317, 'Bayern'),
    (50.1498, 9.6674, 'Bayern'),
    (50.2093, 9.2103, 'Hessen'),
    (50.2137, 11.3323, 'Bayern'),
    (50.2321, 8.4573, 'Hessen'),
    (50.2531, 10.9848, 'Bayern'),
    (50.3236, 11.9289, 'Bayern'),
    (50.3683, 11.6378, 'Bayern'),
    (50.3694, 9.9805, 'Bayern'),
    (50.4005, 12.3503, 'Sachsen'),
    (50.4268, 11.6135, 'Thüringen'),
    (50.4269, 10.215, 'Bayern'),
    (50.4468, 11.0044, 'Thüringen'),
    (50.495, 11.3678, 'Bayern'),
    (50.604, 9.6766, 'Hessen'),
    (50.6124, 10.745, 'Thüringen'),
    (50.6508, 8.5803, 'Hessen'),
    (50.6718, 14.2289, 'Tschechien'),
    (50.7183, 12.5472, 'Sachsen'),
    (50.7737, 11.1828, 'Thüringen'),
    (50.7999, 12.9657, 'Sachsen'),
    (50.7999, 12.9658, 'Sachsen'),
    (50.8514, 10.4653, 'Thüringen'),
    (50.9154, 11.6011, 'Thüringen'),
    (50.9169, 13.3429, 'Sachsen'),
    (50.9184, 12.076, 'Thüringen'),
    (50.9511, 8.5321, 'Hessen'),
    (50.959, 11.0229, 'Thüringen'),
    (51.0138, 11.2586, 'Thüringen'),
    (51.0401, 13.8388, 'Sachsen'),
    (51.2073, 9.8477, 'Hessen'),
    (51.2373, 11.8815, 'Sachsen-Anhalt'),
    (51.304, 13.0096, 'Sachsen'),
    (51.3141, 9.3459, 'Hessen'),
    (51.3167, 12.4482, 'Sachsen'),
    (51.4118, 11.0762, 'Thüringen'),
    (51.5829, 9.956, 'Niedersachsen'),
    (51.5955, 11.9573, 'Sachsen-Anhalt'),
    (51.8002, 10.6144, 'Sachsen-Anhalt'),
)
_KP = {"lock": _kp_thr.Lock(), "cache": {}, "hits": 0, "miss": 0, "err": None}


def _kp_norm(ch, tii):
    """Kanal nur 11D/5C/10C, TII nur MM/SS oder MMSS -> (ch, 'MM/SS') oder None."""
    ch = str(ch or "")
    if ch not in KP_CH:
        return None
    m = KP_TII_RE.match(str(tii or "").strip())
    return (ch, "%s/%s" % (m.group(1), m.group(2))) if m else None


def _kp_land(lat, lon):
    """Bundesland/Staat zur naechsten Mastkoordinate (hoechstens 3 km), sonst '–' (gleiche Regel wie kpLand im Seitenskript)."""
    try:
        lat, lon = float(lat), float(lon)
    except Exception:
        return "–"
    c = _kp_cos(lat)
    best, bd = None, 1e9
    for la, lo, nm in KP_LAND:
        dy, dx = la - lat, (lo - lon) * c
        d = dy * dy + dx * dx
        if d < bd:
            best, bd = nm, d
    return best if best is not None and bd < 0.000729 else "–"


def _kp_cos(lat):
    return _kp_math.cos(lat * _kp_math.pi / 180)


def _kp_hist(path, ch, tii, now=None, budget=None):
    """SNR-Verlauf aus reception_log (nur lesen): 24 h in 15-min-Mitteln + Sichtungen 24 h/60 Tage. Wirft nie."""
    now = int(_kp_time.time() if now is None else now)
    budget = KP_DB_TIMEOUT_S if budget is None else budget
    t0 = now - KP_HIST_S
    out = {"ok": False, "ch": ch, "tii": tii, "from": t0, "to": now, "bucket_s": KP_BUCKET_S, "pts": [], "n24": 0, "n60": 0, "t": now,
           "note": "SNR des Kanals bei Sichtung dieser TII (15-min-Mittel), kein Pegel je Mast"}
    con = None
    try:
        uri = "file:%s?mode=ro" % str(path).replace("%", "%25").replace("?", "%3f").replace("#", "%23")
        con = _kp_sql.connect(uri, uri=True, timeout=KP_DB_TIMEOUT_S, check_same_thread=False)
        dl = _kp_time.monotonic() + budget
        con.set_progress_handler(lambda: 1 if _kp_time.monotonic() > dl else 0, KP_PROG_N)
        pts, n24 = [], 0
        for b, avg, cnt in con.execute(KP_SQL_PTS, (ch, tii, t0, now)).fetchall():
            n24 += int(cnt or 0)
            if avg is not None:
                pts.append([int(b), round(float(avg), 1)])
        n60 = con.execute(KP_SQL_N60, (ch, tii, now - 60 * 86400)).fetchone()[0]
        out.update(ok=True, pts=pts, n24=n24, n60=int(n60 or 0))
    except Exception as e:
        msg = str(e)
        out["err"] = "Zeitlimit %.1f s" % budget if "interrupt" in msg else "Datenbank nicht lesbar (%s)" % type(e).__name__
    finally:
        if con is not None:
            try:
                con.close()
            except Exception:
                pass
    return out


def _kp_get(path, ch, tii, now=None):
    """Mit Zwischenspeicher: je (Datei, Kanal, TII) hoechstens alle 60 s eine Abfrage, hoechstens 32 Eintraege."""
    now = _kp_time.time() if now is None else now
    key = (str(path), ch, tii)
    with _KP["lock"]:
        e = _KP["cache"].get(key)
        if e and 0 <= now - e[0] < KP_CACHE_S:
            _KP["hits"] += 1
            return e[1]
    v = _kp_hist(path, ch, tii, int(now))
    with _KP["lock"]:
        _KP["miss"] += 1
        c = _KP["cache"]
        c[key] = (now, v)
        while len(c) > KP_CACHE_MAX:
            del c[min(c, key=lambda k: c[k][0])]
    return v


def _kp_api():
    from flask import jsonify, request as _kp_rq
    a = _kp_norm(_kp_rq.args.get("ch"), _kp_rq.args.get("tii"))
    if a is None:
        r = jsonify({"ok": False, "err": "ch (11D/5C/10C) und tii (MM/SS) noetig"})
        r.status_code = 400
    else:
        try:
            r = jsonify(_kp_get(globals()["_t4_paths"]()[1], a[0], a[1]))
        except Exception as e:
            r = jsonify({"ok": False, "err": "nicht lesbar (%s)" % type(e).__name__})
    r.headers["Cache-Control"] = "no-store"
    return r


KP_JS_HELP = r"""/* kartePop */
var KPO=@@OFF@@,KPF=@@FERN@@,KPL=@@KPL@@,KPR={'11D':0,'5C':1,'10C':2},HS={};
function kpLand(m){if(!m||typeof m.lat!=='number'||typeof m.lon!=='number')return '–';var b=null,bd=1e9,c=Math.cos(m.lat*Math.PI/180);
for(var i=0;i<KPL.length;i++){var dy=KPL[i][0]-m.lat,dx=(KPL[i][1]-m.lon)*c,d=dy*dy+dx*dx;if(d<bd){bd=d;b=KPL[i];}}return (b&&bd<0.000729)?b[2]:'–';}
function kpRank(k){var c=k.slice(k.lastIndexOf('|')+1);return (c in KPR)?KPR[c]:9;}
function kpOff(a,b,o){if(!o)return [a,b];var p0=map.latLngToLayerPoint(a),p1=map.latLngToLayerPoint(b),dx=p1.x-p0.x,dy=p1.y-p0.y,l=Math.sqrt(dx*dx+dy*dy);if(!(l>=1))return [a,b];
var nx=-dy/l*o,ny=dx/l*o;return [map.layerPointToLatLng(L.point(p0.x+nx,p0.y+ny)),map.layerPointToLatLng(L.point(p1.x+nx,p1.y+ny))];}
function kpShift(){if(!map||!V||!V.home)return;var h=V.home,g={},z=map.getZoom();
for(var key in LL){var s=key.slice(0,key.lastIndexOf('|'));(g[s]=g[s]||[]).push(key);}
for(var s in g){var mk=ML[s];if(!mk)continue;var ks=g[s].sort(function(a,b){return kpRank(a)-kpRank(b);}),ml=mk.getLatLng(),n=ks.length;
for(var i=0;i<n;i++){var o=(i-(n-1)/2)*KPO,sig=z+'|'+o+'|'+ml.lat+'|'+ml.lng+'|'+h.lat+'|'+h.lon,ln=LL[ks[i]],lo=LO[ks[i]];if(ln._kps===sig)continue;
var ll=kpOff([h.lat,h.lon],[ml.lat,ml.lng],o);ln.setLatLngs(ll);if(lo)lo.setLatLngs(ll);ln._kps=sig;}}}
function kpOpen(k){var q=ML[k];if(q&&q.openPopup)q.openPopup();}
function kpHist(ch,tii,col){var e=HS[ch+'|'+tii],d=e&&e.d;if(!d)return '<br><span class="kp-h" style="opacity:.75">SNR-Verlauf 24 h: lädt …</span>';
if(!d.ok)return '<br><span class="kp-h" style="opacity:.75">SNR-Verlauf 24 h: nicht lesbar'+(d.err?' ('+esc(d.err)+')':'')+'</span>';
var P=d.pts||[];if(!P.length)return '<br><span class="kp-h" style="opacity:.75">SNR-Verlauf 24 h: keine Sichtung ('+Number(d.n60||0)+'× in 60 Tagen)</span>';
var t0=Number(d.from),t1=Number(d.to),W=160,H=36,mx=25,mn=1e9,mv=-1e9,seg=[],cur=[],lt=null;if(!(t1>t0))t1=t0+1;
for(var i=0;i<P.length;i++){var v=Number(P[i][1]);if(v>mx)mx=v;if(v<mn)mn=v;if(v>mv)mv=v;}
for(var i=0;i<P.length;i++){var t=Number(P[i][0]),v=Number(P[i][1]),x=Math.max(0,Math.min(W,(t-t0)/(t1-t0)*W)),y=H-2-Math.max(0,v)/mx*(H-4);
if(lt!==null&&t-lt>Number(d.bucket_s)*1.5){seg.push(cur);cur=[];}cur.push(x.toFixed(1)+','+y.toFixed(1));lt=t;}seg.push(cur);
var s='<svg class="kp-svg" width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'" style="display:block;background:#0b1220;border-radius:4px;margin-top:2px">';
for(var j=0;j<seg.length;j++){var q=seg[j];if(q.length===1){var xy=q[0].split(',');s+='<circle cx="'+xy[0]+'" cy="'+xy[1]+'" r="1.6" fill="'+col+'"/>';}else s+='<polyline points="'+q.join(' ')+'" fill="none" stroke="'+col+'" stroke-width="1.5"/>';}
return '<br><span class="kp-h">SNR-Verlauf 24 h (15-min-Mittel): '+n(mn,1)+'–'+n(mv,1)+' dB · '+Number(d.n24||0)+'× in 24 h, '+Number(d.n60||0)+'× in 60 Tagen</span>'+s+'</svg>';}
function kpRe(mk){if(mk&&mk._m){var p=pop(mk._m);if(mk._p!==p){mk._p=p;mk.setPopupContent(p);}}}
function kpLoad(mk){var m=mk._m;if(!m||!m.ch)return;for(var i=0;i<m.ch.length;i++){(function(c){var key=c.ch+'|'+c.tii_txt,e=HS[key];if(e&&(e.busy||(e.d&&Date.now()-e.t<60000)))return;
HS[key]={t:0,busy:1,d:e&&e.d};fetch('/api/karte/hist?ch='+encodeURIComponent(c.ch)+'&tii='+encodeURIComponent(c.tii_txt),{credentials:'same-origin',cache:'no-store'}).then(function(r){return r.json();})
.then(function(j){HS[key]={t:Date.now(),d:j||{ok:false}};kpRe(mk);}).catch(function(){HS[key]={t:Date.now(),d:{ok:false,err:'Abruf fehlgeschlagen'}};kpRe(mk);});})(m.ch[i]);}}
function kpDec(u){if(!u||!V||!V.masts)return '';var sub=String(u.tii_txt||'').slice(3,5),b=null,bc='';if(sub.length!==2)return '';
for(var i=0;i<V.masts.length;i++){var m=V.masts[i],cs=m.ch||[];for(var j=0;j<cs.length;j++){var c=cs[j];
if(c.ch===u.ch&&String(c.tii_txt).slice(3,5)===sub&&c.tii_txt!==u.tii_txt&&(!b||(m.dist_km!=null&&(b.dist_km==null||m.dist_km<b.dist_km)))){b=m;bc=c.tii_txt;}}}
return b?' <span style="color:#fbbf24">– möglicher Dekodierfehler (SubID '+esc(sub)+' wie '+esc(b.name)+' '+esc(bc)+')</span>':'';}
"""

KP_JS_EDITS = [
    ("var LO={},UNK=false,FAIL=0;\n", "var LO={},UNK=false,FAIL=0;\n@@HELP@@"),
    ("map.on('popupclose',function(){if(HC){map.removeLayer(HC);HC=null;}OPEN=null;});",
     "map.on('popupclose',function(){if(HC){map.removeLayer(HC);HC=null;}OPEN=null;});map.on('zoomend',kpShift);"),
    ("mk.on('popupopen',function(){OPEN=k;if(mk._m)horizon(mk._m);});", "mk.on('popupopen',function(){OPEN=k;if(mk._m){horizon(mk._m);kpLoad(mk);}});"),
    ("if(!ln){lo=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:false,pane:'kvOut',color:OUTC,weight:w+3,opacity:.7,lineCap:'round'}).addTo(map);LO[key]=lo;"
     "ln=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:false}).addTo(map);LL[key]=ln;",
     "if(!ln){lo=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:true,bubblingMouseEvents:false,pane:'kvOut',color:OUTC,weight:w+3,opacity:.7,lineCap:'round'}).addTo(map);"
     "lo.on('click',function(){kpOpen(k);});LO[key]=lo;ln=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:true,bubblingMouseEvents:false}).addTo(map);"
     "ln.on('click',function(){kpOpen(k);});LL[key]=ln;"),
    ("map.removeLayer(ML[k]);delete ML[k];}}\nlegend();}", "map.removeLayer(ML[k]);delete ML[k];}}\nkpShift();legend();}"),
    ("r+='<br>Distanz '+n(m.dist_km,1)+' km · Funkhorizont D ", "r+='<br>Bundesland '+esc(kpLand(m))+'<br>Entfernung von Kalchreuth '+n(m.dist_km,1)+' km · Funkhorizont D "),
    ("(m.dist_km>m.D_km?' · <b style=\"color:#f97316\">Überreichweite</b> (Distanz > D)':' · innerhalb D'):'');",
     "(m.dist_km>m.D_km?(m.overreach?' · <b style=\"color:#f97316\">Überreichweite verifiziert</b> (TII empfangen, Distanz > D)':' · jenseits D (Überreichweite erst, wenn die TII empfangen wird)')"
     ":' · innerhalb D'):'')+((m.ever&&m.dist_km!=null&&m.dist_km>=KPF)?' · <b>Fernempfang</b> (≥ '+KPF+' km, pulsiert nicht)':'');"),
    ("r+='<br>Höhe '+", "r+='<br>Höhe Standort + Antenne '+"),
    ("'</b> TII '+esc((m.name||'unbekannt')+' · '+c.tii_txt)+': '",
     "'</b> TII '+esc((m.name||'unbekannt')+' · '+c.tii_txt)+' (MainID '+esc(String(c.tii_txt).slice(0,2))+', SubID '+esc(String(c.tii_txt).slice(3,5))+'): '"),
    ("(c.q!=null?' · Signal ≈ '+Math.round(c.q*100)+' %':'');}", "(c.q!=null?' · Signal ≈ '+Math.round(c.q*100)+' %':'');r+=kpHist(c.ch,c.tii_txt,CC[c.ch]||GREY);}"),
    ("kein RSSI je Mast (welle-cli liefert keinen Pegel je Sender) – Signal = Schaetzung aus SNR/TII<br>",
     "kein RSSI je Mast (welle-cli liefert keinen Pegel je Sender) – Signal = Schaetzung aus SNR/TII<br>SNR-Verlauf = SNR des Kanals bei Sichtung dieser TII (15-min-Mittel), kein Pegel je Mast"
     "<br>Bundesland: OpenStreetMap (Nominatim) zur Mastkoordinate<br>"),
    ("pulsierend = Überreichweite (Distanz > Funkhorizont D)",
     "pulsierend = Überreichweite verifiziert (TII empfangen und Distanz > Funkhorizont D) · Fernempfang (schon empfangen, ≥ '+KPF+' km) nur als Text im Popup, pulsiert nicht"
     " · gleiche Strecke mehrerer Kanäle '+KPO+' px parallel versetzt · Klick auf Mast oder Linie = Popup mit SNR-Verlauf 24 h"),
    ("', Fehler '+n(u.last_err,0)+')';}", "', Fehler '+n(u.last_err,0)+')'+kpDec(u);}"),
]


def _kp_js(js):
    """Karten-JS ergaenzen: alle Stellen genau einmal, sonst unveraendert + Fehler (alles oder nichts); schon ergaenzt -> unveraendert."""
    if "/* kartePop */" in js:
        return js
    for i, (o, n) in enumerate(KP_JS_EDITS):
        if js.count(o) != 1:
            raise ValueError("Karten-JS: Stelle %d nicht genau einmal (%d)" % (i + 1, js.count(o)))
    kpl = _kp_json.dumps([[la, lo, nm] for la, lo, nm in KP_LAND], ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    help_ = KP_JS_HELP.replace("@@OFF@@", str(KP_OFF_PX)).replace("@@FERN@@", str(KP_FERN_KM)).replace("@@KPL@@", kpl)
    for o, n in KP_JS_EDITS:
        js = js.replace(o, n.replace("@@HELP@@", help_), 1)
    return js


def _selftest_kartepop():
    import tempfile
    assert _kp_norm("5C", "12/03") == ("5C", "12/03") and _kp_norm("5C", "1203") == ("5C", "12/03") and _kp_norm("11D", " 05/14 ") == ("11D", "05/14")
    for bad in (("5D", "12/03"), ("5C", "1/03"), ("5C", "12/03;"), ("5C", "ab/cd"), (None, None), ("5C", "12/034")):
        assert _kp_norm(*bad) is None, bad
    assert _kp_land(48.94642, 11.42878) == "Bayern" and _kp_land(50.23214, 8.45732) == "Hessen" and _kp_land(48.3951, 9.9787) in ("Baden-Württemberg", "–")
    assert _kp_land(0, 0) == "–" and _kp_land("x", 1) == "–" and len(KP_LAND) >= 100
    with tempfile.TemporaryDirectory() as d:
        p = d + "/lz.db"
        now = 1793500000
        w = _kp_sql.connect(p)
        w.execute("CREATE TABLE reception_log (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, channel TEXT NOT NULL, tii TEXT, snr REAL, errors REAL, sync INTEGER, fic_rate REAL, sn TEXT)")
        w.execute("CREATE INDEX ix_rl_ch_tii ON reception_log(channel, tii, timestamp)")
        b0 = (now // 900) * 900
        rows = [(b0 + 10, "5C", "12/03", 10.0), (b0 + 20, "5C", "12/03", 14.0), (b0 - 3 * 3600 + 5, "5C", "12/03", 8.0), (b0 - 30 * 3600, "5C", "12/03", 3.0),
                (b0 + 30, "5C", "17/03", 1.0), (b0 + 40, "11D", "12/03", 20.0), (b0 - 7200 + 1, "5C", "12/03", None)]
        w.executemany("INSERT INTO reception_log(timestamp, channel, tii, snr, sync, sn) VALUES(?,?,?,?,1,'X')", rows)
        w.commit()
        w.close()
        h = _kp_hist(p, "5C", "12/03", now)
        assert h["ok"] and h["pts"] == [[b0 - 3 * 3600, 8.0], [b0, 12.0]] and h["n24"] == 4 and h["n60"] == 5 and "sn" not in h and "X" not in _kp_json.dumps(h), h
        assert _kp_hist(p, "5C", "02/03", now)["pts"] == [] and _kp_hist(p, "5C", "02/03", now)["ok"]
        m = _kp_hist(d + "/fehlt.db", "5C", "12/03", now)
        assert not m["ok"] and m["err"].startswith("Datenbank nicht lesbar") and d not in m["err"]
        _KP["cache"].clear()
        a1 = _kp_get(p, "5C", "12/03", now)
        assert _kp_get(p, "5C", "12/03", now + 59) is a1 and _kp_get(p, "5C", "12/03", now + 61) is not a1
        for i in range(KP_CACHE_MAX + 5):
            _kp_get(p, "5C", "%02d/01" % i, now + 100 + i)
        assert len(_KP["cache"]) == KP_CACHE_MAX
        _KP["cache"].clear()
        w = _kp_sql.connect(p)
        w.executemany("INSERT INTO reception_log(timestamp, channel, tii, snr, sync) VALUES(?,?,?,?,1)", [(b0 - i, "5C", "12/03", 5.0) for i in range(3000)])
        w.commit()
        w.close()
        t = _kp_hist(p, "5C", "12/03", now, budget=-1)
        assert not t["ok"] and t["err"].startswith("Zeitlimit"), t
    assert "sn" not in _kp_re.findall(r"[a-z_]+", KP_SQL_PTS + KP_SQL_N60) and "SELECT *" not in KP_SQL_PTS + KP_SQL_N60
    js = _kp_js(globals()["_KV_JS"])
    assert js.count("/* kartePop */") == 1 and _kp_js(js) == js and "map.on('zoomend',kpShift)" in js and "kpShift();legend();}" in js and "kpLoad(mk)" in js
    assert js.count("interactive:true,bubblingMouseEvents:false") == 2 and "interactive:false}).addTo(map);LL[key]" not in js and "Überreichweite verifiziert" in js and "kpDec(u)" in js
    assert js.count("fetch(") == 3 and "/api/karte/hist?ch=" in js and "method:'POST'" not in js and "innerHTML" not in js.replace("lg.innerHTML", "")
    for o, n in KP_JS_EDITS:
        assert o not in js or o in n, o[:40]
    try:
        _kp_js(js.replace("/* kartePop */", ""))
        raise AssertionError("doppelt ergaenzt")
    except ValueError:
        pass
    return ("kartePop ok (Linien %d px parallel bei gleichem Mast, neu bei Zoom; Klick auf Linie = Mast-Popup; Bundesland %d Koordinaten OSM; Fernempfang ab %d km nur Text; "
            "/api/karte/hist nur lesen, %.1f s, Cache %d s/%d; 24 h in 15-min-Mitteln)" % (KP_OFF_PX, len(KP_LAND), KP_FERN_KM, KP_DB_TIMEOUT_S, KP_CACHE_S, KP_CACHE_MAX))


try:
    _KP_ST = _selftest_kartepop()
    _KV_JS = _kp_js(_KV_JS)
    if "kp_hist" not in app.view_functions:
        app.add_url_rule("/api/karte/hist", endpoint="kp_hist", view_func=_kp_api, methods=["GET"])
    print("kartePop aktiv: %s" % _KP_ST, flush=True)
except Exception as _kp_e:
    print("kartePop Selbsttest FEHLER (%s: %s) - Karte wie bisher" % (type(_kp_e).__name__, str(_kp_e)[:300]), flush=True)
# ===== /kartePop =====
MK_C51_RAB_EOF
EXPECT_RAG="71664d06047a428a579478a2c8d7e6d0010cf264ca35854788e8cedc52bc1a05"
cat > "$W/guard.py" << 'MK_C51_RAG_EOF'
"""Guard kartePop (commit51). dashboard.py: genau ein Block vor __main__, keine geaenderten Zeilen.
  guard_kp.py revert NEU_VERZ ALT_VERZ BLOCK   -> ALT_VERZ/dashboard.py = NEU ohne Block (byte-genau)
  guard_kp.py check  ALT NEU BLOCK             -> Rueckbau = ALT, statische Regeln, Verhaltenstests mit Flask + SQLite (eigene Erwartungen),
                                                  Karten-Skript mit node und Leaflet-Attrappe (falls node da; sonst nur statisch - Mutationen werden trotzdem erkannt)
  guard_kp.py mutate ALT NEU BLOCK             -> Mutationstest (jede Mutation muss check scheitern lassen)
Braucht flask im ausfuehrenden Python (venv). GUARD_NO_NODE=1 schaltet den node-Test ab."""
import ast, io, contextlib, json, os, re, shutil, sqlite3, subprocess, sys, tempfile, time

ANCH = '\n\nif __name__ == "__main__":\n'
M0, M1 = "# ===== kartePop:", "# ===== /kartePop ====="
OK_IMPORTS = {"json", "math", "re", "sqlite3", "threading", "time", "flask", "tempfile"}
FORBID = {"send_meshtastic", "send_dab_to_private_mesh", "send_nina_to_bayern", "_t4_send_m1", "_lz_mesh", "requests", "urllib", "socket", "subprocess", "os", "open",
          "system", "popen", "Popen", "eval", "exec", "__import__", "Thread", "route", "after_request", "before_request", "_lz_mgr", "MASTS_DB", "WD_MF", "kv_status"}
CONSTS = {"KP_OFF_PX": 4, "KP_FERN_KM": 150, "KP_HIST_S": 86400, "KP_BUCKET_S": 900, "KP_CACHE_S": 60, "KP_CACHE_MAX": 32, "KP_DB_TIMEOUT_S": 0.5, "KP_CH": ("11D", "5C", "10C")}
JS_NEED = ["map.on('zoomend',kpShift);", "kpShift();legend();}", "kpLoad(mk);", "lo.on('click',function(){kpOpen(k);});", "ln.on('click',function(){kpOpen(k);});",
           "var o=(i-(n-1)/2)*KPO", "fetch('/api/karte/hist?ch='+encodeURIComponent(c.ch)+'&tii='+encodeURIComponent(c.tii_txt),{credentials:'same-origin',cache:'no-store'})",
           "Date.now()-e.t<60000", "m.overreach?", "(m.ever&&m.dist_km!=null&&m.dist_km>=KPF)", "Bundesland '+esc(kpLand(m))", "'+kpDec(u);}", "r+=kpHist(c.ch,c.tii_txt,CC[c.ch]||GREY);}",
           "bd<0.000729", "map.latLngToLayerPoint(a)", "map.layerPointToLatLng(L.point(p0.x+nx,p0.y+ny))", "if(ln._kps===sig)continue;", "if(lo)lo.setLatLngs(ll);",
           "var nx=-dy/l*o,ny=dx/l*o;", "function kpRank(k){var c=k.slice(k.lastIndexOf('|')+1);return (c in KPR)?KPR[c]:9;}", "function kpOpen(k){var q=ML[k];if(q&&q.openPopup)q.openPopup();}",
           "if(e&&(e.busy||(e.d&&Date.now()-e.t<60000)))return;", "(d.err?' ('+esc(d.err)+')':'')", "(MainID '+esc(String(c.tii_txt).slice(0,2))+', SubID '+esc(String(c.tii_txt).slice(3,5))+')",
           "c.ch===u.ch&&String(c.tii_txt).slice(3,5)===sub&&c.tii_txt!==u.tii_txt", "wie '+esc(b.name)+' '+esc(bc)+')", "if(lt!==null&&t-lt>Number(d.bucket_s)*1.5){seg.push(cur);cur=[];}",
           "if(v>mx)mx=v;if(v<mn)mn=v;", "<br>Höhe Standort + Antenne '+", "<br>Entfernung von Kalchreuth '+n(m.dist_km,1)+' km"]
JS_BAD = ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "localStorage", "sessionStorage", "eval(", "Function(", "XMLHttpRequest", "/api/mesh", "send",
          "method:", "http://", "https://", "sendBeacon", "setInterval"]
KEEP = ["setInterval(load,5000)", "removeLayer", "setStyle", "kv-pulse", "popupopen", "popupclose", "Schaetzung aus SNR/TII", "/api/t4/tii", "kein RSSI je Mast", "function kvW(snr)",
        "createPane('kvOut')", "pane:'kvOut'", "weight:w+3,opacity:.7", "kv-pulse-o", '<details id="kvUnk"', "function tick()", "cls(mk,m.overreach)", "cls(ln,m.overreach)"]


def rd(p):
    return open(p, encoding="utf-8").read()


def blk_text(bp):
    return rd(bp).rstrip("\n") + "\n"


def revert(neu, bp):
    B = blk_text(bp)
    assert neu.count(M0) == 1 and neu.count(M1) == 1, "Marker nicht genau einmal"
    assert neu.count("\n\n" + B.rstrip("\n") + ANCH) == 1, "Block nicht genau einmal unmittelbar vor __main__"
    return neu.replace("\n\n" + B.rstrip("\n") + ANCH, ANCH, 1)


def fail(m):
    print("VERSTOSS:", m)
    sys.exit(1)


def consts(t):
    out = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
            try:
                out[n.targets[0].id] = ast.literal_eval(n.value)
            except Exception:
                pass
    return out


def static(B):
    t = ast.parse(B)
    funcs = {n.name: n for n in t.body if isinstance(n, ast.FunctionDef)}
    for node in ast.walk(t):
        if isinstance(node, ast.Name) and node.id in FORBID:
            fail("verbotener Name %s" % node.id)
        if isinstance(node, ast.Attribute) and node.attr in FORBID:
            fail("verbotenes Attribut .%s" % node.attr)
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for m in ([a.name for a in node.names] if isinstance(node, ast.Import) else [node.module]):
                if m not in OK_IMPORTS:
                    fail("Import %s" % m)
        if isinstance(node, ast.Global):
            fail("global-Anweisung")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print":
            a0 = node.args[0] if node.args else None
            s = a0.left.value if isinstance(a0, ast.BinOp) and isinstance(a0.left, ast.Constant) else (a0.value if isinstance(a0, ast.Constant) else "")
            if not str(s).startswith("kartePop"):
                fail("print ohne Praefix kartePop: %r" % str(s)[:40])
    need = {"_kp_norm", "_kp_land", "_kp_cos", "_kp_hist", "_kp_get", "_kp_api", "_kp_js", "_selftest_kartepop"}
    if need - set(funcs):
        fail("Funktionen fehlen: %s" % sorted(need - set(funcs)))
    C = consts(t)
    for k, v in CONSTS.items():
        if C.get(k) != v:
            fail("Konstante %s = %r (erwartet %r)" % (k, C.get(k), v))
    for k in ("KP_SQL_PTS", "KP_SQL_N60"):
        q = C.get(k) or ""
        if not q.startswith("SELECT ") or re.search(r"\b(INSERT|UPDATE|DELETE|DROP|CREATE|ATTACH|PRAGMA|REPLACE)\b", q, re.I) or re.search(r"\bsn\b|SELECT\s+\*|,\s*\*|COUNT\(\*\)\s*,\s*\*", q) or "reception_log" not in q:
            fail("SQL %s nicht nur lesend/zu breit" % k)
    if "LIMIT 100" not in C.get("KP_SQL_PTS", "") or "GROUP BY b" not in C.get("KP_SQL_PTS", "") or "(timestamp / 900) * 900" not in C.get("KP_SQL_PTS", ""):
        fail("SQL Verlauf ohne 15-min-Gruppen/LIMIT")
    land = C.get("KP_LAND")
    if not isinstance(land, tuple) or len(land) < 100 or not all(isinstance(x, tuple) and len(x) == 3 and isinstance(x[2], str) for x in land):
        fail("KP_LAND fehlt/ungueltig")
    for fn, f in funcs.items():
        for node in ast.walk(f):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("execute", "executemany", "executescript"):
                if fn == "_selftest_kartepop":
                    continue
                a0 = node.args[0] if node.args else None
                if node.func.attr != "execute" or not (isinstance(a0, ast.Name) and a0.id in ("KP_SQL_PTS", "KP_SQL_N60")):
                    fail("SQL ausserhalb der festen Lese-Abfragen in %s" % fn)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "commit" and fn != "_selftest_kartepop":
                fail("commit ausserhalb des Selbsttests")
    hs = ast.get_source_segment(B, funcs["_kp_hist"])
    for s in ('uri = "file:%s?mode=ro"', "uri=True, timeout=KP_DB_TIMEOUT_S", "con.set_progress_handler(lambda: 1 if _kp_time.monotonic() > dl else 0, KP_PROG_N)", "budget = KP_DB_TIMEOUT_S if budget is None else budget",
              "con.close()", '"Datenbank nicht lesbar (%s)" % type(e).__name__'):
        if hs.count(s) != 1:
            fail("_kp_hist ohne %r" % s)
    gs = ast.get_source_segment(B, funcs["_kp_get"])
    for s in ("0 <= now - e[0] < KP_CACHE_S", "while len(c) > KP_CACHE_MAX:", 'with _KP["lock"]:'):
        if s not in gs:
            fail("_kp_get ohne %r" % s)
    js_all = (C.get("KP_JS_HELP") or "") + "".join(n for o, n in (C.get("KP_JS_EDITS") or []))
    if not js_all or len(C.get("KP_JS_EDITS") or []) != 13:
        fail("Skript-Stellen fehlen (13 erwartet)")
    for s in JS_NEED:
        if js_all.count(s) != 1:
            fail("Karten-Skript ohne %r" % s[:60])
    for s in JS_BAD:
        if s in js_all:
            fail("Karten-Skript enthaelt %r" % s)
    if js_all.count("fetch(") != 1:
        fail("Karten-Skript: genau ein neuer Abruf erlaubt")
    if B.count("app.") != 2 or B.count('app.add_url_rule("/api/karte/hist", endpoint="kp_hist", view_func=_kp_api, methods=["GET"])') != 1:
        fail("Route nicht genau einmal nur GET /api/karte/hist")
    tr = B[B.index("\ntry:\n    _KP_ST = _selftest_kartepop()"):]
    if tr.index("_selftest_kartepop()") > tr.index("_KV_JS = _kp_js(_KV_JS)") or tr.index("_KV_JS = _kp_js(_KV_JS)") > tr.index("add_url_rule") or "except Exception as _kp_e:" not in tr:
        fail("Reihenfolge Selbsttest -> Skript -> Route")


def kv_orig(alt):
    t = ast.parse(alt)
    for n in t.body:
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "_KV_JS":
            return ast.literal_eval(n.value)
    raise AssertionError("_KV_JS im Dashboard nicht gefunden")


def mk_env(kvjs, B, path):
    from flask import Flask
    app = Flask("kpguard")
    g = {"__name__": "kpguard", "app": app, "_KV_JS": kvjs, "_t4_paths": lambda: ("/nirgends", path)}
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(B, "blk", "exec"), g)
    return app, g, buf.getvalue()


def mkdb(p, rows):
    w = sqlite3.connect(p)
    w.execute("CREATE TABLE IF NOT EXISTS reception_log (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, channel TEXT NOT NULL, tii TEXT, snr REAL, errors REAL, sync INTEGER, fic_rate REAL, sn TEXT)")
    w.execute("CREATE INDEX IF NOT EXISTS ix_rl_ch_tii ON reception_log(channel, tii, timestamp)")
    w.executemany("INSERT INTO reception_log(timestamp, channel, tii, snr, sync, sn) VALUES(?,?,?,?,1,'SN-GEHEIM-4711')", rows)
    w.commit()
    w.close()


def behav(alt, B):
    kv0 = kv_orig(alt)
    d = tempfile.mkdtemp()
    try:
        p = os.path.join(d, "lagezentrum.db")
        b0 = (int(time.time()) // 900) * 900
        now = b0 + 300                      # feste Uhr (Attrappe): unabhaengig davon, wann im 15-min-Raster der Test laeuft
        rows = [(b0 + 1, "5C", "12/03", 6.0), (b0 + 2, "5C", "12/03", 9.0), (b0 - 900 + 3, "5C", "12/03", 4.5), (b0 - 5 * 3600, "5C", "12/03", None),
                (now - 86400 - 50, "5C", "12/03", 30.0), (now - 40 * 86400, "5C", "12/03", 1.0), (now - 70 * 86400, "5C", "12/03", 1.0), (b0 + 5, "5C", "17/03", 22.0), (b0 + 6, "11D", "12/03", 15.0)]
        mkdb(p, rows)
        app, g, out = mk_env(kv0, B, p)
        g["_kp_time"] = type("T", (), {"time": staticmethod(lambda: float(now)), "monotonic": staticmethod(time.monotonic)})
        assert "kartePop aktiv: kartePop ok" in out and "FEHLER" not in out, out[:300]
        js = g["_KV_JS"]
        assert js != kv0 and js.count("/* kartePop */") == 1, "Karten-Skript nicht ergaenzt"
        for k in KEEP:
            assert k in js, "vorhandene Karten-Funktion verloren: " + k
        assert "{interactive:false}).addTo(map);LL[key]=ln;" not in js and "Überreichweite</b> (Distanz > D)" not in js and "r+='<br>Distanz '" not in js, "alte Stellen noch da"
        assert js.count("var KPO=4,KPF=150,KPL=[[") == 1 and '"Hessen"' in js and '"Bayern"' in js and "Tschechien" in js
        c = app.test_client()
        r = c.get("/api/karte/hist?ch=5C&tii=12/03")
        j = r.get_json()
        assert r.status_code == 200 and j["ok"] and r.headers.get("Cache-Control") == "no-store", (r.status_code, j)
        assert j["pts"] == [[b0 - 900, 4.5], [b0, 7.5]], ("Punkte", j["pts"])
        assert j["n24"] == 4 and j["n60"] == 6 and j["bucket_s"] == 900 and j["to"] - j["from"] == 86400 and j["tii"] == "12/03" and j["ch"] == "5C", j
        assert "SN-GEHEIM" not in r.get_data(as_text=True), "Seriennummer in der Antwort"
        assert c.get("/api/karte/hist?ch=5C&tii=1203").get_json()["pts"] == j["pts"]
        for q in ("ch=5C", "tii=12/03", "ch=5D&tii=12/03", "ch=5C&tii=12-03", "ch=5C&tii=12/3", "ch=5C&tii=12/03%27", "ch=5C&tii=1203x", "ch=&tii="):
            rr = c.get("/api/karte/hist?" + q)
            assert rr.status_code == 400 and rr.get_json()["ok"] is False, q
        assert c.post("/api/karte/hist?ch=5C&tii=12/03").status_code == 405 and c.delete("/api/karte/hist?ch=5C&tii=12/03").status_code == 405
        mkdb(p, [(b0 + 50, "5C", "12/03", 30.0)])
        assert c.get("/api/karte/hist?ch=5C&tii=12/03").get_json()["pts"] == j["pts"], "Cache 60 s wirkt nicht"
        for k in list(g["_KP"]["cache"]):
            t0, v = g["_KP"]["cache"][k]
            g["_KP"]["cache"][k] = (t0 - 61, v)
        assert c.get("/api/karte/hist?ch=5C&tii=12/03").get_json()["pts"][-1] == [b0, 15.0], "nach 60 s nicht neu gelesen"
        for i in range(40):
            c.get("/api/karte/hist?ch=11D&tii=%02d/01" % i)
        assert len(g["_KP"]["cache"]) == 32, "Cache nicht auf 32 begrenzt"
        assert c.get("/api/karte/hist?ch=11D&tii=12/03").get_json()["pts"] == [[b0, 15.0]]
        g["_KP"]["cache"].clear()
        mkdb(p, [(b0 - i, "10C", "07/01", 5.0) for i in range(4000)])
        g["KP_DB_TIMEOUT_S"] = -1.0
        jt = c.get("/api/karte/hist?ch=10C&tii=07/01").get_json()
        assert jt["ok"] is False and jt["err"].startswith("Zeitlimit"), ("Zeitlimit", jt)
        g["KP_DB_TIMEOUT_S"] = 0.5
        g["_KP"]["cache"].clear()
        assert c.get("/api/karte/hist?ch=10C&tii=07/01").get_json()["ok"]
        g["_t4_paths"] = lambda: ("/x", os.path.join(d, "fehlt", "x.db"))
        g["_KP"]["cache"].clear()
        jm = c.get("/api/karte/hist?ch=5C&tii=12/03").get_json()
        assert jm["ok"] is False and "fehlt" not in jm["err"] and d not in json.dumps(jm), jm
        assert not os.path.exists(os.path.join(d, "fehlt")), "Lesezugriff legt Dateien an"
        g["_t4_paths"] = lambda: ("/x", p)
        with sqlite3.connect(p) as w:
            n0 = w.execute("SELECT COUNT(*) FROM reception_log").fetchone()[0]
        g["_KP"]["cache"].clear()
        c.get("/api/karte/hist?ch=5C&tii=12/03")
        with sqlite3.connect(p) as w:
            assert w.execute("SELECT COUNT(*) FROM reception_log").fetchone()[0] == n0, "Datenbank veraendert"
        assert g["_kp_land"](50.23214, 8.45732) == "Hessen" and g["_kp_land"](49.42639, 11.03778) == "Bayern" and g["_kp_land"](47.5081, 9.78) == "Österreich (Vorarlberg)"
        assert g["_kp_land"](52.52, 13.40) == "–", "Bundesland ohne Koordinate in 3 km"
        # alles oder nichts: fehlt eine Stelle, bleibt die Karte wie bisher (keine Route)
        app2, g2, out2 = mk_env(kv0.replace("map.on('popupclose',", "map.on('popupclose' ,"), B, p)
        assert "kartePop Selbsttest FEHLER" in out2 and g2["_KV_JS"] == kv0.replace("map.on('popupclose',", "map.on('popupclose' ,") and "kp_hist" not in app2.view_functions, out2[:200]
        return js
    finally:
        shutil.rmtree(d, ignore_errors=True)


NODE_TEST = r"""
const JS=require('fs').readFileSync(process.argv[2],'utf8');const V=JSON.parse(require('fs').readFileSync(process.argv[3],'utf8'));const HJ=JSON.parse(require('fs').readFileSync(process.argv[4],'utf8'));
const log={fetch:[],lines:[],markers:[],mapon:{}};let Z=8;const K=()=>100*Math.pow(2,Z-8);
function ll(a){return Array.isArray(a)?{lat:a[0],lng:a[1]}:{lat:a.lat,lng:(a.lng!==undefined?a.lng:a.lon)};}
const map={getZoom:()=>Z,on:(e,f)=>{(log.mapon[e]=log.mapon[e]||[]).push(f);},setView(){return map;},createPane(){},getPane:()=>({style:{}}),removeLayer(){},
 latLngToLayerPoint:a=>{a=ll(a);return {x:a.lng*K(),y:-a.lat*K()};},layerPointToLatLng:p=>({lat:-p.y/K(),lng:p.x/K()})};
function Ly(t,a,o){this.t=t;this.a=a;this.o=o||{};this.h={};this.nset=0;}
Ly.prototype.addTo=function(){return this;};Ly.prototype.setStyle=function(s){Object.assign(this.o,s);return this;};Ly.prototype.on=function(e,f){(this.h[e]=this.h[e]||[]).push(f);return this;};
Ly.prototype.setLatLngs=function(a){this.a=a;this.nset++;return this;};Ly.prototype.bindPopup=function(){return this;};Ly.prototype.setPopupContent=function(p){this.content=p;return this;};
Ly.prototype.openPopup=function(){this.opened=(this.opened||0)+1;(this.h.popupopen||[]).forEach(f=>f());return this;};Ly.prototype.setLatLng=function(a){this.a=a;return this;};
Ly.prototype.getLatLng=function(){return ll(this.a);};Ly.prototype.bringToFront=function(){};Ly.prototype.setRadius=function(){};Ly.prototype.clearLayers=function(){};
const L={map:()=>map,tileLayer:()=>new Ly('tile'),layerGroup:()=>new Ly('lg'),circle:(a,o)=>new Ly('circle',a,o),point:(x,y)=>({x:x,y:y}),divIcon:()=>({}),marker:a=>new Ly('m',a),geoJSON:()=>new Ly('g'),
 polyline:(a,o)=>{const l=new Ly('line',a,o);log.lines.push(l);return l;},circleMarker:(a,o)=>{const m=new Ly('cm',a,o);log.markers.push(m);return m;}};
const els={};function el(id,t){els[id]={id:id,textContent:t||'',_h:'',addEventListener(){},set innerHTML(v){this._h=v;},get innerHTML(){return this._h;}};return els[id];}
el('kv-tiles','{"have":false}');el('kvInfo');el('kvLeg');el('kv-data',JSON.stringify(V));el('kv-zones','null');
const doc={getElementById:i=>els[i]||null};const tick=()=>new Promise(r=>setImmediate(r));
async function fetchF(u,o){log.fetch.push(u);if(u.indexOf('/api/karte/hist')===0)return {json:async()=>HJ[u.indexOf('5C')>0?'5C':'x']||HJ.x};throw new Error('offline');}
(async()=>{
 new Function('document','L','fetch','setInterval','window',JS)(doc,L,fetchF,()=>1,{});
 const R={};const mk=id=>log.markers.find(m=>m.content&&m.content.indexOf(id)>=0);
 const pts=l=>[map.latLngToLayerPoint(l.a[0]),map.latLngToLayerPoint(l.a[1])];
 const off=(l,ref)=>{const p=pts(l),r=pts(ref),dx=r[1].x-r[0].x,dy=r[1].y-r[0].y,len=Math.hypot(dx,dy);return Math.round(((p[0].x-r[0].x)*(-dy)+(p[0].y-r[0].y)*dx)/len*100)/100;};
 const lines=log.lines.filter(l=>!l.o.pane),outl=log.lines.filter(l=>l.o.pane==='kvOut');R.nlines=lines.length;R.nout=outl.length;
 const home=[V.home.lat,V.home.lon];const ref=m=>({a:[home,[m.lat,m.lon]]});
 const byM=(m)=>lines.filter(l=>{const a=l.a[1];const q=ll(a);return Math.abs(q.lat-m.lat)<0.05&&Math.abs(q.lng-m.lon)<0.05;});
 R.off={};V.masts.forEach(m=>{R.off[m.id]=byM(m).map(l=>[l.o.color,off(l,ref(m))]);});
 R.outsame=outl.every((o,i)=>JSON.stringify(o.a)===JSON.stringify(lines[i].a));
 R.inter=log.lines.every(l=>l.o.interactive===true&&l.o.bubblingMouseEvents===false&&(l.h.click||[]).length===1);
 Z=10;(log.mapon.zoomend||[]).forEach(f=>f());R.off10={};V.masts.forEach(m=>{R.off10[m.id]=byM(m).map(l=>off(l,ref(m)));});
 const n0=lines.map(l=>l.nset);(log.mapon.zoomend||[]).forEach(f=>f());R.resetAgain=lines.some((l,i)=>l.nset!==n0[i]);
 const sw=mk('Nürnberg (Schweinau)');const f0=log.fetch.length;const red=lines.find(l=>l.o.color==='#ef4444'&&byM(V.masts[0]).indexOf(l)>=0);
 red.h.click[0]();R.opened=sw.opened||0;await tick();await tick();await tick();await tick();R.fetch1=log.fetch.slice(f0);R.pop=sw.content;
 sw.openPopup();await tick();await tick();R.fetch2=log.fetch.length-f0-R.fetch1.length;
 R.feld=mk('Großer Feldberg').content;R.far=mk('Fernmast').content;R.over=mk('Übermast').content;R.never=mk('Niemast').content;R.leg=els.kvLeg.innerHTML;R.mapon=Object.keys(log.mapon);
 console.log(JSON.stringify(R));
})().catch(e=>{console.log('NODEFEHLER '+e.stack);process.exit(1);});
"""


def node_test(js):
    nd = shutil.which("node") or shutil.which("nodejs")
    if not nd or os.environ.get("GUARD_NO_NODE"):
        return "Karten-Skript statisch (node fehlt)"
    now = int(time.time())

    def ch(c, tii, act=True, ever=True):
        return {"ch": c, "tii": tii.replace("/", ""), "tii_txt": tii, "active": act, "ever": ever, "n": 5, "last_t": now, "snr": 12.0, "fic_rate": 0, "last_err": 1, "best_err": 1,
                "last_km": 1, "q": 0.8, "max_run": 3, "stable": True, "seen_unconfirmed": False}

    def m(i, name, lat, lon, chs, dist, D, ever=True, over=False):
        return {"id": i, "name": name, "lat": lat, "lon": lon, "ch": chs, "dist_km": dist, "D_km": D, "ever": ever, "active": any(c["active"] for c in chs), "overreach": over,
                "h_m": 578, "site_m": 318, "ant_m": 260, "erp_kw": 10, "geo_src": "T"}
    V = {"home": {"lat": 49.55782283, "lon": 11.15501383, "name": "Kalchreuth", "h_m": 431.7}, "active_s": 150, "ever_run": 2, "legend": "x", "note": "n", "src": "s", "ch": {},
         "masts": [m("nbg", "Nürnberg (Schweinau)", 49.42639, 11.03778, [ch("10C", "07/01"), ch("11D", "05/14"), ch("5C", "12/03")], 16.9, 184.7),
                   m("bam", "Bamberg (Geisberg)", 49.8893, 11.062, [ch("5C", "12/11"), ch("11D", "08/18")], 37.5, 190),
                   m("gel", "Gelbelsee", 48.94642, 11.42872, [ch("11D", "01/05"), ch("5C", "12/04", act=False)], 70.8, 190.2),
                   m("feld", "Großer Feldberg (Taunus)", 50.23214, 8.45732, [ch("5C", "17/03")], 207.3, 213.7),
                   m("far", "Fernmast <b>x</b>", 51.0, 9.0, [ch("5C", "17/09", act=False)], 160.0, 200.0),
                   m("ovr", "Übermast", 51.5, 9.5, [ch("5C", "17/04")], 220.0, 200.0, over=True),
                   m("nev", "Niemast", 51.6, 9.6, [ch("5C", "17/06", act=False, ever=False)], 230.0, 200.0, ever=False)],
         "nopos": [], "unknown": [{"ch": "5C", "tii_txt": "02/03", "n": 3, "last_t": now, "last_err": 2}, {"ch": "5C", "tii_txt": "13/03", "n": 3, "last_t": now, "last_err": 2},
                                  {"ch": "11D", "tii_txt": "99/77", "n": 1, "last_t": now, "last_err": 2}, {"ch": "5C", "tii_txt": "11/09", "n": 1, "last_t": now, "last_err": 2}]}
    b0 = (now // 900) * 900
    HJ = {"5C": {"ok": True, "from": now - 86400, "to": now, "bucket_s": 900, "pts": [[b0 - 7200, 9.5], [b0 - 6300, 10.5], [b0, 13.0]], "n24": 7, "n60": 40},
          "x": {"ok": False, "err": "<img src=x onerror=1>"}}
    d = tempfile.mkdtemp()
    try:
        for n_, v in (("t.js", NODE_TEST), ("a.js", js), ("v.json", json.dumps(V)), ("h.json", json.dumps(HJ))):
            open(os.path.join(d, n_), "w", encoding="utf-8").write(v)
        o = subprocess.run([nd] + [os.path.join(d, x) for x in ("t.js", "a.js", "v.json", "h.json")], capture_output=True, text=True, timeout=60)
        assert o.returncode == 0 and o.stdout.strip().startswith("{"), (o.stdout + o.stderr)[-400:]
        R = json.loads(o.stdout.strip().splitlines()[-1])
    finally:
        shutil.rmtree(d, ignore_errors=True)
    off = R["off"]
    assert sorted(off["nbg"]) == sorted([["#7dd3fc", -4], ["#ef4444", 0], ["#f97316", 4]]), ("Versatz Schweinau 11D/5C/10C -4/0/+4", off["nbg"])
    assert sorted(off["bam"]) == sorted([["#7dd3fc", -2], ["#ef4444", 2]]), ("Versatz Bamberg +-2", off["bam"])
    assert off["gel"] == [["#7dd3fc", 0]] and off["feld"] == [["#ef4444", 0]], ("Einzel-Linie ohne Versatz", off["gel"], off["feld"])
    assert sorted(R["off10"]["nbg"]) == [-4, 0, 4] and sorted(R["off10"]["bam"]) == [-2, 2], ("nach Zoom neu (Pixel bleiben 4)", R["off10"])
    assert R["outsame"] and R["nout"] == R["nlines"] and R["inter"], ("Rand-Linie gleich versetzt / klickbar", R["outsame"], R["inter"])
    assert not R["resetAgain"], "unnoetiges Neusetzen ohne Zoomwechsel"
    assert "zoomend" in R["mapon"], R["mapon"]
    assert R["opened"] == 1, "Klick auf Linie oeffnet das Mast-Popup nicht"
    exp = sorted(["/api/karte/hist?ch=10C&tii=07%2F01", "/api/karte/hist?ch=11D&tii=05%2F14", "/api/karte/hist?ch=5C&tii=12%2F03"])
    assert sorted(R["fetch1"]) == exp and R["fetch2"] == 0, ("Abruf nur bei popupopen, je Kanal einmal, 60 s gemerkt", R["fetch1"], R["fetch2"])
    p = R["pop"]
    for s in ("Bundesland Bayern", "Entfernung von Kalchreuth 16,9 km", "Höhe Standort + Antenne 578 m ü. NN (318 m + Antenne 260 m)", "(MainID 12, SubID 03)", "(MainID 05, SubID 14)",
              "SNR-Verlauf 24 h (15-min-Mittel): 9,5–13,0 dB · 7× in 24 h, 40× in 60 Tagen", "<svg", 'stroke="#ef4444"', "&lt;img src=x onerror=1&gt;", "innerhalb D"):
        assert s in p, ("Popup ohne " + s, p[:600])
    assert "<img" not in p and "Fernempfang" not in p and "Überreichweite" not in p
    f = R["feld"]
    assert "Bundesland Hessen" in f and "Fernempfang</b> (≥ 150 km, pulsiert nicht)" in f and "innerhalb D" in f and "Überreichweite" not in f, f[:500]
    assert "Fernempfang" in R["far"] and "Fernmast &lt;b&gt;x&lt;/b&gt;" in R["far"] and "Bundesland –" in R["far"], R["far"][:300]
    assert "Überreichweite verifiziert</b> (TII empfangen, Distanz > D)" in R["over"] and "Fernempfang" in R["over"]
    assert "jenseits D (Überreichweite erst, wenn die TII empfangen wird)" in R["never"] and "Fernempfang" not in R["never"] and "verifiziert" not in R["never"]
    lg = R["leg"]
    assert lg.count("möglicher Dekodierfehler (SubID 03 wie Nürnberg (Schweinau) 12/03)") == 2 and "99/77 (1×" in lg and "11/09 (1×" in lg, lg[-900:]
    assert lg.count("Dekodierfehler") == 2 + ("SubID 09 wie" in lg), "Hinweis bei fremder SubID"
    assert "pulsierend = Überreichweite verifiziert" in lg and "Fernempfang (schon empfangen, ≥ 150 km)" in lg and "4 px parallel versetzt" in lg
    return "Karten-Skript mit node: Versatz -4/0/+4 bzw. +-2 px (Rand gleich), neu bei Zoom, Linie klickbar -> Mast-Popup, Verlauf nur bei popupopen (3 Abrufe, 60 s gemerkt), Popup-Felder/Escape, Fernempfang/verifiziert/jenseits D, Dekodier-Hinweis"


def check(alt, neu, bp):
    B = blk_text(bp)
    try:
        r = revert(neu, bp)
    except AssertionError as e:
        fail(str(e))
    if r != alt:
        fail("Rueckbau != Basis (Aenderung ausserhalb des Blocks)")
    if not B.startswith(M0) or not B.rstrip("\n").endswith(M1):
        fail("Block beginnt/endet nicht mit Marker")
    try:
        compile(B, "blk", "exec")
    except SyntaxError as e:
        fail("Syntax %s" % e)
    static(B)
    try:
        js = behav(alt, B)
        nt = node_test(js)
    except AssertionError as e:
        fail("Verhalten: %s" % str(e)[:400])
    except Exception as e:
        fail("Verhalten (%s): %s" % (type(e).__name__, str(e)[:300]))
    print("Guard kartePop ok: Rueckbau byte-genau = Basis; statisch (nur json/math/re/sqlite3/threading/time/flask, kein Prozess/Netz/Mesh/Datei, SQL nur zwei feste SELECT ohne sn, mode=ro, "
          "0,5 s, Cache 60 s/32, genau eine Route GET /api/karte/hist, Skript ohne innerHTML/POST); Verhalten mit Flask+SQLite: 15-min-Mittel 24 h nach eigener Erwartung, n24/n60, 400 bei falschen Werten, "
          "405 bei POST/DELETE, Cache 60 s und 32 Eintraege, Zeitlimit, fehlende DB ohne Pfad, DB unveraendert, keine Seriennummer, alles-oder-nichts; %s" % nt)


MUTS = [
    ("KP_OFF_PX = 4 ", "KP_OFF_PX = 6 "), ("KP_FERN_KM = 150 ", "KP_FERN_KM = 100 "), ("KP_CACHE_S = 60 ", "KP_CACHE_S = 600 "), ("KP_DB_TIMEOUT_S = 0.5 ", "KP_DB_TIMEOUT_S = 5 "),
    ("KP_CACHE_MAX = 32 ", "KP_CACHE_MAX = 3200 "), ("KP_BUCKET_S = 900 ", "KP_BUCKET_S = 3600 "),
    ("GROUP BY b ORDER BY b LIMIT 100", "GROUP BY b ORDER BY b"), ("SELECT (timestamp / 900) * 900 AS b, AVG(snr), COUNT(*)", "SELECT (timestamp / 900) * 900 AS b, AVG(snr), COUNT(*), sn"),
    ("AND timestamp >= ? AND timestamp <= ? ", "AND timestamp <= ? AND timestamp >= 0 + ? "), ('uri = "file:%s?mode=ro"', 'uri = "file:%s?mode=rw"'),
    ("        con.set_progress_handler(lambda: 1 if _kp_time.monotonic() > dl else 0, KP_PROG_N)\n", ""),
    ("            if avg is not None:\n", "            if True:\n"), ("        out.update(ok=True, pts=pts, n24=n24, n60=int(n60 or 0))", "        out.update(ok=True, pts=pts, n24=len(pts), n60=int(n60 or 0))"),
    ('"Datenbank nicht lesbar (%s)" % type(e).__name__', '"Datenbank nicht lesbar (%s)" % msg'),
    ("        if e and 0 <= now - e[0] < KP_CACHE_S:", "        if e:"), ("        while len(c) > KP_CACHE_MAX:", "        while len(c) > 10 * KP_CACHE_MAX:"),
    ('    if ch not in KP_CH:\n        return None\n', ''), ('KP_TII_RE = _kp_re.compile(r"^([0-9]{2})/?([0-9]{2})$")', 'KP_TII_RE = _kp_re.compile(r"^([0-9]{2})/?([0-9]{2})")'),
    ("        r.status_code = 400\n", ""), ('    r.headers["Cache-Control"] = "no-store"\n', ''),
    ('methods=["GET"])', 'methods=["GET", "POST"])'), ("    _KV_JS = _kp_js(_KV_JS)\n", "    pass\n"),
    ("var o=(i-(n-1)/2)*KPO", "var o=i*KPO"), ("map.on('zoomend',kpShift);", ""), ("kpShift();legend();}", "legend();}"), ("if(lo)lo.setLatLngs(ll);", ""),
    ("var nx=-dy/l*o,ny=dx/l*o;", "var nx=dx/l*o,ny=dy/l*o;"), ("function kpRank(k){var c=k.slice(k.lastIndexOf('|')+1);return (c in KPR)?KPR[c]:9;}", "function kpRank(k){return 0;}"),
    ("if(ln._kps===sig)continue;", ""), ("{interactive:true,bubblingMouseEvents:false}).addTo(map);", "{interactive:false}).addTo(map);"),
    ("ln.on('click',function(){kpOpen(k);});", ""), ("function kpOpen(k){var q=ML[k];if(q&&q.openPopup)q.openPopup();}", "function kpOpen(k){}"),
    ("horizon(mk._m);kpLoad(mk);", "horizon(mk._m);"), ("Date.now()-e.t<60000", "Date.now()-e.t<0"), ("if(e&&(e.busy||", "if(e&&(false||"),
    ("Bundesland '+esc(kpLand(m))", "Bundesland '+kpLand(m)"), ("return (b&&bd<0.000729)?b[2]:'–';", "return b?b[2]:'–';"),
    ("(d.err?' ('+esc(d.err)+')':'')", "(d.err?' ('+d.err+')':'')"), ("(m.ever&&m.dist_km!=null&&m.dist_km>=KPF)", "(m.dist_km!=null&&m.dist_km>=KPF)"),
    ("(m.overreach?' · <b style=", "(true?' · <b style="), ("r+=kpHist(c.ch,c.tii_txt,CC[c.ch]||GREY);}", "}"), ("(MainID '+esc(String(c.tii_txt).slice(0,2))", "(MainID '+esc(String(c.tii_txt).slice(3,5))"),
    ("'+kpDec(u);}", "';}"), ("c.ch===u.ch&&String(c.tii_txt).slice(3,5)===sub", "String(c.tii_txt).slice(3,5)===sub"), ("esc(b.name)", "b.name"),
    ("if(lt!==null&&t-lt>Number(d.bucket_s)*1.5){seg.push(cur);cur=[];}", ""), ("if(v>mx)mx=v;if(v<mn)mn=v;", "if(v<mn)mn=v;"),
    ("<br>Höhe Standort + Antenne '+", "<br>Höhe '+"), ("Entfernung von Kalchreuth '+n(m.dist_km,1)", "Entfernung von Kalchreuth '+n(m.D_km,1)"),
    ("encodeURIComponent(c.tii_txt),{credentials:'same-origin',cache:'no-store'})", "encodeURIComponent(c.tii_txt),{credentials:'same-origin',cache:'no-store',method:'POST'})"),
    ("    if \"/* kartePop */\" in js:\n        return js\n", ""),
    ("            raise ValueError(\"Karten-JS: Stelle %d nicht genau einmal (%d)\" % (i + 1, js.count(o)))", "            continue"),
    ("import time as _kp_time\n", "import time as _kp_time\nimport os as _kp_os\n"), ("    (49.4264, 11.0378, 'Bayern'),\n", "    (49.4264, 11.0378, 'Hessen'),\n"),
]


def mutate(altp, neup, bp):
    alt, B = rd(altp), blk_text(bp)
    me = os.path.abspath(__file__)
    d = tempfile.mkdtemp()
    caught = missed = 0
    try:
        def run(n_txt, b_txt):
            open(os.path.join(d, "n.py"), "w", encoding="utf-8").write(n_txt)
            open(os.path.join(d, "b.py"), "w", encoding="utf-8").write(b_txt)
            o = subprocess.run([sys.executable, me, "check", altp, os.path.join(d, "n.py"), os.path.join(d, "b.py")], capture_output=True, text=True, timeout=300)
            return o.returncode != 0, ((o.stdout + o.stderr).strip().splitlines() or [""])[-1:]
        bad, msg = run(rd(neup), B)
        if bad:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        cases = []
        for a, b in MUTS:
            if B.count(a) < 1:
                print("UEBERSEHEN (Mutation passt nicht): %r" % a[:70]); missed += 1; continue
            Bm = B.replace(a, b, 1)
            cases.append(("blk " + a[:50], alt.replace(ANCH, "\n\n" + Bm.rstrip("\n") + ANCH, 1), Bm))
        neu = rd(neup)
        cases.append(("Zeile ausserhalb", neu.replace("T4_SAY_MAX = 600", "T4_SAY_MAX = 601", 1), B))
        cases.append(("Block doppelt", neu.replace(ANCH, "\n\n" + B.rstrip("\n") + ANCH, 1), B))
        for name, n_txt, b_txt in cases:
            bad, msg = run(n_txt, b_txt)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest kartePop: %d erkannt, %d uebersehen%s" % ("OK" if missed == 0 else "FEHLER", caught, missed, " (ohne node)" if os.environ.get("GUARD_NO_NODE") or not shutil.which("node") else ""))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    m = sys.argv[1]
    if m == "revert":
        neu = rd(os.path.join(sys.argv[2], "dashboard.py"))
        os.makedirs(sys.argv[3], exist_ok=True)
        open(os.path.join(sys.argv[3], "dashboard.py"), "w", encoding="utf-8").write(revert(neu, sys.argv[4]))
        print("Rueckbau kartePop ok")
    elif m == "check":
        check(rd(sys.argv[2]), rd(sys.argv[3]), sys.argv[4])
    elif m == "mutate":
        mutate(*sys.argv[2:5])
MK_C51_RAG_EOF
EMB="patch.py:$EXPECT_PAL edits.py:$EXPECT_RAE blk.py:$EXPECT_RAB guard.py:$EXPECT_RAG"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (4: Patcher, Stellen, Block, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
for x in "$F" "$FL" "$FS"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS")
SD=UNBEKANNT; [[ "$D16" == "$KNOWN_D16" ]] && SD=alt; [[ "$D16" == "$KNOWN_D16N" ]] && SD=neu
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit50, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 - $([[ "$L16" == "$KNOWN_L16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
echo "Basis prepper_sdr.py sha16 $S16 - $([[ "$S16" == "$KNOWN_S16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C49" || "$D16" == "$KNOWN_D16_C48" || "$D16" == "$KNOWN_D16_C47" ]]; then
  WAS="nach commit47 (auch commit48 und commit49 fehlen)"; [[ "$D16" == "$KNOWN_D16_C48" ]] && WAS="nach commit48 (auch commit49 fehlt)"; [[ "$D16" == "$KNOWN_D16_C49" ]] && WAS="nach commit49"
  echo "STOP: erst commit50 anwenden - dashboard.py ist noch der Stand $WAS (sha16 $D16), commit51 braucht $KNOWN_D16 (nach commit50) - nichts geaendert."
  exit 1
fi
if [[ "$SD" == UNBEKANNT ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16) - nichts geaendert."
  echo "      commit51 passt nur auf den Stand nach commit50. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
[[ "$L16" == "$KNOWN_L16" ]] || stop "lage_pages.py ist nicht der Stand nach commit50 ($L16 statt $KNOWN_L16)"
[[ "$S16" == "$KNOWN_S16" ]] || stop "prepper_sdr.py ist nicht der Stand nach commit50 ($S16 statt $KNOWN_S16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug/jinja2 nicht"
# ---- perfWsgi muss laufen (waitress, 8 Arbeitsfaeden) ----
wsst() { "${CURL[@]}" "$B/api/perfwsgi/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("server"), d.get("workers"))' 2>/dev/null || echo "? ?"; }
PCSV=$(wsst)
if [[ "$PCSV" == "waitress 8" ]]; then echo "OK perfWsgi laeuft (waitress, 8 Arbeitsfaeden)"
elif [[ "$DRY" == 1 ]]; then echo "HINWEIS perfWsgi-Status nicht lesbar ($PCSV) - im Trockenlauf unerheblich"
else stop "perfWsgi-Status $PCSV statt 'waitress 8' - Dashboard laeuft nicht wie erwartet"; fi
# ---- Neustart-Sperre HH:55-HH:04 (Berlin); geprueft jetzt, vor dem Ersetzen und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C51_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$C51_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$STATE" == neu ]]; then echo "OK Neustart-Sperre: commit51 ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - zwischen HH:55 und HH:04 wird prepper-dashboard nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04 ($1)"; fi; }
rscheck "Vorpruefung"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher; auch lage_pages.py und prepper_sdr.py)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$W/patch.py" kartePop dsh "$F" "$W/work/dashboard.py" "$W/blk.py" "$W/edits.py" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer kartePop nicht eindeutig"; }
[[ "$(s16 "$W/work/dashboard.py")" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $(s16 "$W/work/dashboard.py") statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(wc -l < "$W/work/dashboard.py") Zeilen; $(cat "$W/q.log"))"
python3 "$W/patch.py" kartePop dsh "$W/work/dashboard.py" "$W/work/x1" "$W/blk.py" "$W/edits.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
rm -f "$W/work/x1"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/patch.py" "$W/edits.py" "$W/blk.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/blk.py" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: kartePop im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "Guard: Stand ohne kartePop ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" > "$W/g.log" 2>&1 || { grep -v "^kartePop" "$W/g.log" | cut -c1-300; stop "Guard kartePop meldet Verstoss"; }
grep "^Guard kartePop" "$W/g.log" | cut -c1-900
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Karten-Skript hier statisch geprueft; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C51_SIM_NOMUT:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "Mutationstest kartePop: eine Verfehlung wurde nicht erkannt"; }
[[ "$MUTS" == 0 ]] || grep -E "^OK Mutationstest" "$W/gm.log" | cut -c1-200
# ---------- 3) Zustand vorher (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local i; for i in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/karte" -o "$W/k0.html" || true
K0=$(grep -c 'id="kv-js"' "$W/k0.html" || true)
if [[ "$DRY" != 1 ]]; then [[ "$K0" -ge 1 ]] || stop "/karte liefert das Karten-Skript nicht (${K0}x kv-js) - Dashboard in Ordnung?"; fi
pcode() { code -X POST "$@"; }
brst() { "${CURL[@]}" "$B/api/br24" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
print(d.get("state"), bool(d.get("geo_hold")), (d.get("geo_hint") or {}).get("lvl") or "-")' 2>/dev/null || echo "FEHLER"; }
t4lv() { "${CURL[@]}" "$B/api/t4/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
print(((d.get("level") or {}).get("label") or "?").replace(" ", "_"))' 2>/dev/null || echo "FEHLER"; }
read -r BR_S0 BR_H0 BR_G0 <<< "$(brst)"
T4L0=$(t4lv)
KLAT0=$(tmed "$B/karte"); TLAT0=$(tmed "$B/api/t4/tii")
echo "Zustand vorher: BR24 $BR_S0, Lage-Ampel (teil4) $T4L0, /karte Median ${KLAT0} s, /api/t4/tii Median ${TLAT0} s; kartePop auf /karte: $(grep -c 'kartePop' "$W/k0.html" || true)x"
NEED=0; [[ "$STATE" == alt ]] && NEED=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED" == 0 ]]; then echo "  Zustand: kartePop ist schon installiert - ein echter Lauf aendert an dashboard.py nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, /karte und /api/karte/hist pruefen, eine sudo-Passwortabfrage. Keine Einstellung, keine Datenbank wird geaendert."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
if [[ "$NEED" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
INST=()
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "kartePop|kartevec|Traceback" | tail -6 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  echo "  Datenbank, lage_pages.py, prepper_sdr.py und Mesh-Regeln wurden nicht veraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED" == 0 ]]; then
  echo "OK kartePop schon installiert - kein Neustart, keine Aenderung an dashboard.py"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen"
  cp -a "$F" "$F.bak-$NM-$TS"
  { ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  INST+=("$F")
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-$NM-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-$NM-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst; prepper-sdr bleibt laufen) - warte auf HTTP 200 (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
fi
PHASE=Pruefung
# ---------- 5) Pruefung ----------
for p in "${PAGES[@]}" "${APIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rbx "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs antworten wie vorher (alle $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
kst() { python3 -c 'import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"<script id=\"kv-js\">(.*?)</script>", h, re.S)
j = m.group(1) if m else ""
print(h.count("id=\"kv-js\""), j.count("/* kartePop */"), int("map.on(\x27zoomend\x27,kpShift)" in j), int("/api/karte/hist?ch=" in j), int("interactive:true,bubblingMouseEvents:false" in j), int("Überreichweite verifiziert" in j), int("möglicher Dekodierfehler" in j), int("\"Bayern\"" in j and "\"Hessen\"" in j), j.count("fetch("))' "$1" 2>/dev/null || echo "FEHLER"; }
KOK=0
for i in $(seq 1 10); do
  "${CURL[@]}" "$B/karte" -o "$W/k1.html" || true
  read -r K_N K_KP K_ZOOM K_HIST K_CLICK K_VER K_DEC K_LAND K_FETCH <<< "$(kst "$W/k1.html")"
  [[ "$K_N" == 1 && "$K_KP" == 1 && "$K_ZOOM" == 1 && "$K_HIST" == 1 && "$K_CLICK" == 1 && "$K_VER" == 1 && "$K_DEC" == 1 && "$K_LAND" == 1 && "$K_FETCH" == 3 ]] && { KOK=1; break; }
  sleep 3
done
[[ "$KOK" == 1 ]] || rbx "/karte: Karten-Skript nicht wie erwartet (kv-js ${K_N}x, kartePop ${K_KP}x, Zoom $K_ZOOM, Verlauf $K_HIST, Linie klickbar $K_CLICK, verifiziert $K_VER, Dekodier-Hinweis $K_DEC, Bundesland $K_LAND, Abrufe $K_FETCH)"
echo "OK /karte: kartePop 1x im Karten-Skript (Versatz neu bei Zoom, Linien klickbar, Verlauf nur bei Popup, Ueberreichweite verifiziert, Fernempfang-Text, Dekodier-Hinweis, Bundesland-Tabelle; 3 Abrufe)"
hj() { "${CURL[@]}" "$@" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
print(d.get("ok"), (d.get("to") or 0) - (d.get("from") or 0), d.get("bucket_s"), len(d.get("pts") or []), d.get("n24"), d.get("n60"), str(d.get("err") or "-").replace(" ", "_"))' 2>/dev/null || echo "FEHLER"; }
ch1=$(code "$B/api/karte/hist?ch=5C&tii=12/03")
read -r H_OK H_SPAN H_BK H_NP H_N24 H_N60 H_ERR <<< "$(hj "$B/api/karte/hist?ch=5C&tii=12/03")"
[[ "$ch1" == 200 && "$H_SPAN" == 86400 && "$H_BK" == 900 ]] || rbx "/api/karte/hist antwortet nicht wie erwartet (HTTP $ch1, Zeitraum $H_SPAN s, Raster $H_BK s, ok $H_OK, Fehler $H_ERR)"
[[ "$H_OK" == True ]] || echo "HINWEIS /api/karte/hist: Datenbank gerade nicht lesbar ($H_ERR) - Karte zeigt dann 'SNR-Verlauf nicht lesbar', sonst unveraendert"
ch2=$(code "$B/api/karte/hist?ch=5C&tii=x"); ch3=$(code "$B/api/karte/hist?ch=99&tii=12/03"); ch4=$(pcode -H "Origin: http://evil.example" "$B/api/karte/hist?ch=5C&tii=12/03")
[[ "$ch2" == 400 && "$ch3" == 400 ]] || rbx "/api/karte/hist ohne Pruefung der Werte (HTTP $ch2/$ch3, erwartet 400)"
[[ "$ch4" == 403 || "$ch4" == 405 ]] || rbx "/api/karte/hist nimmt POST an (HTTP $ch4)"
HLAT=$(tmed "$B/api/karte/hist?ch=5C&tii=12/03")
echo "OK /api/karte/hist (nur GET, nur lesen): 5C 12/03 -> ok $H_OK, 24 h in 15-min-Mitteln, $H_NP Punkte, $H_N24 Sichtungen 24 h, $H_N60 in 60 Tagen; falsche Werte -> 400/400, POST -> $ch4; Median ${HLAT} s (60 s Cache)"
KLAT1=$(tmed "$B/karte"); TLAT1=$(tmed "$B/api/t4/tii")
echo "OK /karte Median ${KLAT1} s (vorher ${KLAT0} s), /api/t4/tii Median ${TLAT1} s (vorher ${TLAT0} s)"
awk -v a="$KLAT0" -v b="$KLAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/karte ist deutlich langsamer geworden (${KLAT0} s -> ${KLAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200)"
GEM=$(grep -c "^# ===== kartePop:" "$F" || true)
[[ "$GEM" == 1 ]] && echo "OK Marker kartePop 1x" || rbx "dashboard.py kartePop-Marker ${GEM}x"
read -r BR_S1 BR_H1 BR_G1 <<< "$(brst)"
T4L1=$(t4lv)
[[ "$BR_S1" != FEHLER && "$T4L1" != FEHLER ]] || rbx "/api/br24 oder /api/t4/status nicht lesbar ($BR_S1 / $T4L1)"
echo "OK Zustand nachher: BR24 $BR_S1 (vorher $BR_S0; Halt bis Bestaetigung: $BR_H1, Hinweis: $BR_G1), Lage-Ampel $T4L1 (vorher $T4L0)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep kartePop"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "kartePop aktiv: kartePop ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'kartePop aktiv: kartePop ok' ($(echo "$JD" | grep -F kartePop | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok' 'audioKern aktiv: audioKern ok' 'audioUi aktiv: audioUi ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'kartePop Selbsttest FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'kartePop Selbsttest FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein kartePop-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
  echo "$JD" | grep -E '^kartePop|^kartevec' | tail -3 | cut -c1-200 | sed 's/^/  Journal: /' || true
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)"); prepper-sdr laeuft unveraendert weiter"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"), darunter lage_pages.py und prepper_sdr.py)" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Mesh-Regeln (echte Alarme 6 h Dublettenschutz, max 3/h), Gain-Waechter (Stufe 16), lage_pages.py, prepper_sdr.py und alle Dienste ausser prepper-dashboard unberuehrt"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
echo "  Bundesland-Tabelle: OpenStreetMap Nominatim je Mastkoordinate (Abruf 31.10.2026); MASTS_DB/prepper_sdr.py unveraendert"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine $NM-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c kartePop /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/karte | grep -c kartePop"
echo "  curl -s http://127.0.0.1:5000/api/karte/hist?ch=5C&tii=12/03"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep kartePop"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme), keine Einstellung und keine Datenbank geaendert. Neue Docs-Version: bewusst nicht."
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
