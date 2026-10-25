#!/bin/bash
set -eEuo pipefail
# modDead (commit32): MOD-08 toter Code: entfernt nur, was statisch (Name, Zeichenketten, andere Dateien) und dynamisch (globals()/getattr-Namen, aufgerufene Funktionen) nirgends gebraucht wird: 18 Funktionen/Vorfassungen, 7 Waisenvariablen; ergaenzt 14 fehlende Ende-Marker (# ===== /Name =====); kleiner Selbsttest-Block. Kein neues Verhalten, Routen-Tabelle identisch. Nur dashboard.py, AST-Gleichheit bis auf die entfernten Knoten.
# Aufruf: bash /tmp/apply-moddead.sh commit32 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 9cb49ceab0243cc4 (Stand nach mapUi commit31b) oder modDead schon drin (ee4ea3123eb561c4); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-moddead-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/moddead-apply
KEEP_LAST=3
KNOWN_D16="9cb49ceab0243cc4"      # dashboard.py vor modDead (Basis: Stand nach mapUi commit31b)
KNOWN_D16N="ee4ea3123eb561c4"             # dashboard.py nach modDead (Ziel)
PHASE=vorher
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
echo "=== modDead apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Toter Code raus, Ende-Marker, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="0403ec8b66b2edb4195ff6b314a4dcce3445708f80975bcc7ea6170f918bf75b"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher modDead. Aufruf: patch-md.py NAME dsh QUELLE ZIEL BLOCK EDITS. Zustand je Stelle: 'old' (Basis) oder 'new' (schon gepatcht).
Idempotent: schon gepatcht -> Ziel = Quelle. Exit 0 ok, 2 unbekannte Basis/teilweise gepatcht. Schreibt nur ZIEL (nie QUELLE)."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E = g["%s_EDITS" % kind.upper()]
ANCH = g.get("%s_ANCHOR" % kind.upper())
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
name = "dashboard.py"
head = B.splitlines()[0]
n_old = sum(1 for o, n in E if s.count(o) == 1)
n_blk = s.count(head)
if n_old == len(E) and n_blk == 0:
    pass  # Basis
elif n_old == 0 and n_blk == 1 and s.count(B) == 1:
    # schon gepatcht: keine alte Stelle mehr da, Block genau einmal; Zielstellen muessen vorhanden sein
    rest = s.replace(B, "", 1)
    ok = all(rest.count(n) == 1 for o, n in E if n.strip()) and all(o.count("\n") >= 0 for o, n in E)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
else:
    print("%s: %s teilweise vorhanden oder Basis unbekannt (%d von %d alten Stellen, Block %dx)" % (name, label, n_old, len(E), n_blk)); raise SystemExit(2)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if s.count(ANCH) != 1:
    print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
i = s.index(ANCH)
s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen + Block %s" % (name, len(E), label))
MK_PAL_EOF
EXPECT_RAE="534ca695cb89e0a2c506f6ef86a6cb33aa1d4d83d661ec98b9fd6f90ba3c2c75"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer modDead (commit32): Basis 9cb49ceab0243cc4 (Stand nach mapUi commit31b). Entfernt nur Totes (siehe Beleg), ergaenzt fehlende Ende-Marker.
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    ('def scanner_mode_get():\n    import subprocess\n    ow = subprocess.getoutput("systemctl is-active openwebrx").strip()\n    r4 = subprocess.getoutput("systemctl is-active rtl433").strip()\n    if r4 == "active":\n        return "sensor"\n    return "scanner"\n\ndef scanner_mode_set(mode):\n    import subprocess\n    if mode == "sensor":\n        subprocess.call(["sudo", "systemctl", "stop", "openwebrx"])\n        subprocess.call(["sudo", "systemctl", "start", "rtl433"])\n    else:\n        subprocess.call(["sudo", "systemctl", "stop", "rtl433"])\n        subprocess.call(["sudo", "systemctl", "start", "openwebrx"])\n    return scanner_mode_get()\n\ndef scanner_rtl_tail(n=25):',
     'def scanner_rtl_tail(n=25):'),
    ('def _mesh_closewait(host, port=4403):\n    import subprocess\n    n = 0\n    try:\n        out = subprocess.check_output(["ss", "-tn"], text=True, timeout=3)\n        needle = "%s:%s" % (host, port)\n        for line in out.splitlines():\n            if "CLOSE-WAIT" in line and needle in line:\n                n += 1\n    except Exception:\n        pass\n    return n\n\ndef fetch_mesh_link(host, name, svc=None):',
     'def fetch_mesh_link(host, name, svc=None):'),
    ('def lng_util_color(pct):  # lngColorFlip: hohe Ausspeisung = gruen\n    if pct is None:\n        return "#94a3b8"\n    if pct < 50:\n        return "#ef4444"   # niedrige Ausspeisung\n    if pct < 80:\n        return "#eab308"\n    return "#22c55e"       # nahe Kapazitaet\n\n\ndef _fnum(x):',
     'def _fnum(x):'),
    ('def freq_stage(hz):\n    if hz is None:\n        return None, "#6b7280", "Keine Quelle"\n    try:\n        v = float(hz)\n    except Exception:\n        return None, "#6b7280", "Keine Quelle"\n    if 49.95 <= v <= 50.05:\n        return "normal", "#22c55e", "Normal"\n    if (49.80 <= v < 49.95) or (50.05 < v <= 50.20):\n        return "abweichung", "#eab308", "Abweichung"\n    if v < 49.20:\n        return "lastabwurf", "#b91c1c", "Lastabwurf-Naehe"\n    return "kritisch", "#ef4444", "Kritisch"\n\ndef maybe_mesh_frequenz(hz, force=False):',
     'def maybe_mesh_frequenz(hz, force=False):'),
    ('last_pegel_cm = {}\nlast_pegel_mesh_status = {"ok": None, "at": None, "auto": None, "manual": None}',
     'last_pegel_mesh_status = {"ok": None, "at": None, "auto": None, "manual": None}'),
    ('def set_nina_bayern_auto(enabled):\n    import json as _json\n    with open(NINA_BAYERN_CFG, "w") as f:\n        _json.dump({"enabled": bool(enabled)}, f)\n\ndef send_nina_to_bayern(text):',
     'def send_nina_to_bayern(text):'),
    ('mesh_send_lock = threading.Lock()\nMESH_WATCH_TX = "/home/fmg/prepper-dashboard/mesh_watch_tx.json"',
     'MESH_WATCH_TX = "/home/fmg/prepper-dashboard/mesh_watch_tx.json"'),
    ('def _om_weather(lat, lon):\n    """Open-Meteo: temp, max, min, code, precip_prob."""\n    try:\n        url = (\n            "https://api.open-meteo.com/v1/forecast"\n            f"?latitude={lat}&longitude={lon}"\n            "&current=temperature_2m,weather_code"\n            "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max"\n            "&timezone=Europe/Berlin&forecast_days=1"\n        )\n        d = requests.get(url, timeout=10).json()\n        cur = d.get("current") or {}\n        daily = d.get("daily") or {}\n        code = cur.get("weather_code")\n        icon = weather_icon(code) if "weather_icon" in dir() else "·"\n        temp = cur.get("temperature_2m")\n        tmax = (daily.get("temperature_2m_max") or [None])[0]\n        tmin = (daily.get("temperature_2m_min") or [None])[0]\n        rain = (daily.get("precipitation_probability_max") or [None])[0]\n        return {\n            "temp": None if temp is None else round(temp),\n            "max": None if tmax is None else round(tmax),\n            "min": None if tmin is None else round(tmin),\n            "rain": None if rain is None else int(rain),\n            "icon": icon,\n        }\n    except Exception as e:\n        print("OM-Wetter:", e)\n        return {}\n\ndef build_mesh_weather_text():',
     'def build_mesh_weather_text():'),
    ('def note_mesh_tx(which):\n    """which: local | bayern | both"""\n    import json as _j, time as _t\n    path = "/home/fmg/prepper-dashboard/mesh_watch_tx.json"\n    try:\n        d = _j.load(open(path))\n    except Exception:\n        d = {}\n    now = _t.time()\n    if which in ("local", "both"):\n        d["local"] = now\n    if which in ("bayern", "both"):\n        d["bayern"] = now\n    try:\n        _j.dump(d, open(path, "w"))\n    except Exception as e:\n        print("watch tx:", e, flush=True)\n\ndef _bridge_up(port):',
     'def _bridge_up(port):'),
    ('PAGE_SCANNER = ""\n\nPAGE_DECODER = ""\n\n\n\n@app.route("/scanner")',
     '@app.route("/scanner")'),
    ('def _keep_apply_ts(slot, ts):\n    if isinstance(slot, dict) and ts:\n        slot["updated"] = ts\n    return slot\n\ndef _keep_untag_slot(slot):',
     'def _keep_untag_slot(slot):'),
    ('def _sdh_fmt(x, nd=1):\n    return ("%.*f" % (nd, x)).replace(".", ",") if isinstance(x, (int, float)) else "–"\n\n\ndef _sdh_card(v):\n    col = {"green": "#22c55e", "yellow": "#eab308", "red": "#ef4444"}.get(v.get("level"), "#64748b")\n    txt = {"green": "Gesund", "yellow": "Beobachten", "red": "Fehler – Backup prüfen!"}.get(v.get("level"), "?")\n    c = v.get("card") or {}\n    t2 = v.get("tune2fs") or {}\n    esc = lambda s: str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")\n    rs = "".join("<li>%s</li>" % esc(r) for r in (v.get("reasons") or []))\n    age = c.get("months")\n    lines = [\n        "%s %s (%s), hergestellt %s%s" % (esc(v.get("maker", "?")), esc(c.get("name") or "?"), esc(c.get("type") or "SD"),\n                                         esc(c.get("date") or "?"), (" · ~%d Monate alt" % age) if isinstance(age, int) else ""),\n        "Geschrieben gesamt %s TB · %s GB/Tag (%s) · seit Start %s GB" % (_sdh_fmt(v.get("written_tb"), 2), _sdh_fmt(v.get("gb_day")),\n                                                                         esc(v.get("gb_day_src") or "–"), _sdh_fmt(v.get("boot_written_gb"))),\n        "Kernel-Fehler 24 h: %s · Warnungen: %s · ext4-Fehler: %s · Schreibprobe: %s · %s" % (\n            v.get("errors_24h", "–"), v.get("warn_24h", "–"), esc((v.get("ext4") or {}).get("errors_count") or "–"),\n            "ok" if v.get("probe_ok") else ("FEHLER" if v.get("probe_ok") is False else "–"),\n            "nur lesbar!" if (v.get("root") or {}).get("ro") else "beschreibbar"),\n        "Errors behavior: %s · Mount count %s · %s" % (esc(t2.get("Errors behavior") or "–"), esc(t2.get("Mount count") or "–"),\n                                                        esc(v.get("wear") or "Verschleiss nicht auslesbar (Consumer-SD)")),\n        "Stand %s (%s)" % (esc((v.get("at") or "–")[:16]), ("vor %d min" % (v["age_s"] // 60)) if isinstance(v.get("age_s"), int) else "–"),\n    ]\n    return (\'<div class="card sd-card" id="sdCard" style="margin-top:12px"><div class="title">💾 SD-Karte \'\n            \'<span style="display:inline-block;width:12px;height:12px;border-radius:50%%;background:%s;vertical-align:middle"></span> \'\n            \'<span style="color:%s">%s</span></div><div class="small" style="line-height:1.5">%s%s</div></div>\'\n            % (col, col, txt, "<br>".join(lines), (\'<ul style="margin:4px 0 0 18px">%s</ul>\' % rs) if rs else ""))\n\n\ndef _sdh_after(resp):',
     'def _sdh_after(resp):'),
    ('_PP_SHORT = {"Netzfrequenz": "Frequenz", "Internet/Ping": "Internet", "DWD-Warnungen": "DWD", "Stromausfälle": "Stromausf.",\n             "Waldbrand-Index": "WBI", "Weltraumwetter": "Space", "Metalle/Krypto": "Metalle", "Gasspeicher": "Gas",\n             "Strompreis": "Strom", "Netzlast": "Last", "Strommix": "Mix", "SD-Karte": "SD-Karte"}\n_PP_COL = {"ok": "#22c55e", "alt": "#eab308", "ausgefallen": "#ef4444", "unbekannt": "#64748b"}\n_PP_CAND = {',
     '_PP_CAND = {'),
    ('def _pp_age(a):\n    if a is None:\n        return "–"\n    a = max(0, int(a))\n    if a < 90:\n        return "%ds" % a\n    if a < 3600:\n        return "%dm" % (a // 60)\n    if a < 48 * 3600:\n        return "%dh" % (a // 3600)\n    return "%dT" % (a // 86400)\n\n\ndef _pp_esc(s):',
     'def _pp_esc(s):'),
    ('def _pp_rowhtml(name, val, state, tip="", extra=""):\n    c = _PP_COL.get(state, "#64748b")\n    return (\'<div class="pp-row" title="%s"><span class="pp-dot" style="background:%s"></span>\'\n            \'<span class="pp-name">%s</span><span class="pp-val">%s</span>%s</div>\'\n            % (_pp_esc(tip), c, _pp_esc(name), _pp_esc(val), extra))\n\n\ndef _sw_card(d):\n    rows = []\n    for r in d["sources"]:\n        st = r["state"]\n        nm = _PP_SHORT.get(r["name"], r["name"])\n        tip = "%s: %s · Alter %s · Schwelle %s%s" % (r["name"], st, r["age_txt"], r["threshold_txt"], (" · " + r["why"]) if r.get("why") else "")\n        extra = "" if st == "ok" else \'<span class="pp-sub">&gt;%s</span>\' % _pp_esc(_pp_age(r["threshold_s"]))\n        rows.append(_pp_rowhtml(nm, _pp_age(r["age_s"]) if r.get("age_s") is not None else "–", st, tip, extra))\n    c = d["counts"]\n    p = d.get("ping24")\n    pl = ("Ping 24h %s/%s/%s ms" % (p["min"], p["avg"], p["max"])).replace(".", ",") if p else "Ping 24h –"\n    if p and "offline_pct" in p:\n        pl += (" · offline %s %%" % p["offline_pct"]).replace(".", ",")\n    return (\'<div class="card src-card pp-card" id="srcCard"><div class="title">📡 Datenquellen \'\n            \'<span class="pp-sub">%d ok · %d alt · %d aus · %s</span></div><div class="pp-grid">%s</div>\'\n            \'<div class="pp-foot">%s · alt = gehalten/überfällig · aus = &gt;2× Schwelle</div></div>\'\n            % (c.get("ok", 0), c.get("alt", 0), c.get("ausgefallen", 0), d["at"][11:16], "".join(rows), _pp_esc(pl)))\n\n\ndef _pp_kv(k, v, tip=""):',
     'def _pp_kv(k, v, tip=""):'),
    ('def _sdh_card(v):\n    lvl = v.get("level")\n    st = {"green": "ok", "yellow": "alt", "red": "ausgefallen"}.get(lvl, "unbekannt")\n    txt = {"green": "gesund", "yellow": "beobachten", "red": "Fehler – Backup prüfen!"}.get(lvl, "?")\n    c = v.get("card") or {}\n    t2 = v.get("tune2fs") or {}\n    f = lambda x, n=1: ("%.*f" % (n, x)).replace(".", ",") if isinstance(x, (int, float)) else "–"\n    mon = c.get("months")\n    rows = [\n        _pp_kv("Karte", "%s %s · %s%s" % (v.get("maker", "?"), c.get("name") or "?", c.get("date") or "?", (" (~%d Mon.)" % mon) if isinstance(mon, int) else "")),\n        _pp_kv("Geschrieben", "%s TB · %s GB/Tag" % (f(v.get("written_tb"), 2), f(v.get("gb_day"))), "GB/Tag aus %s" % (v.get("gb_day_src") or "–")),\n        _pp_kv("Fehler 24h", "Kernel %s · Warn %s · ext4 %s" % (v.get("errors_24h", "–"), v.get("warn_24h", "–"), (v.get("ext4") or {}).get("errors_count") or "–")),\n        _pp_kv("Schreibprobe", ("ok" if v.get("probe_ok") else ("FEHLER" if v.get("probe_ok") is False else "–")) + (" · nur lesbar!" if (v.get("root") or {}).get("ro") else "")),\n        _pp_kv("ext4", "%s · Mounts %s" % (t2.get("Errors behavior") or "–", t2.get("Mount count") or "–"), "Errors behavior / Mount count"),\n    ]\n    rs = "".join(\'<div class="pp-warn">%s</div>\' % _pp_esc(r) for r in (v.get("reasons") or []))\n    age = v.get("age_s")\n    return (\'<div class="card sd-card pp-card" id="sdCard"><div class="title">💾 SD-Karte \'\n            \'<span class="pp-dot" style="background:%s;display:inline-block;vertical-align:middle"></span> \'\n            \'<span class="pp-sub">%s</span></div>%s%s<div class="pp-foot">%s · Stand %s (%s)</div></div>\'\n            % (_PP_COL.get(st), _pp_esc(txt), "".join(rows), rs, _pp_esc(v.get("wear") or "Verschleiss nicht auslesbar (Consumer-SD)"),\n               _pp_esc((v.get("at") or "–")[11:16]), _pp_age(age) if isinstance(age, int) else "–"))\n\n\ndef _pp_arch_card(a):',
     'def _pp_arch_card(a):'),
    ('def _sdrui_hm(t):\n    try:\n        return _sdrui_t.strftime("%H:%M", _sdrui_t.localtime(float(t))) if t else None\n    except Exception:\n        return None\n\n\ndef _sdrui_next_cal(now, hour):',
     'def _sdrui_next_cal(now, hour):'),
    ('def _fu_num(x, d=1):\n    return ("%.*f" % (d, x)).replace(".", ",") if isinstance(x, (int, float)) else "–"\n\n\n# ---------- Klarnamen fuer DAB-Sender: "Bamberg (Geisberg) · 08/18", unbekannt -> "unbekannt · 00/18" (nur Anzeige) ----------',
     '# ---------- Klarnamen fuer DAB-Sender: "Bamberg (Geisberg) · 08/18", unbekannt -> "unbekannt · 00/18" (nur Anzeige) ----------'),
    ('def _wd_base():\n    try:\n        return _t4_paths()[0]\n    except Exception:\n        return _wd_os.path.dirname(_wd_os.path.abspath(__file__))\n\n\ndef _wd_st(now=None):',
     'def _wd_st(now=None):'),
    ('_PD_STEM = "Projektbeschreibung Lage Pi v"\n_PD_VER_RE = _pd_re.compile(r"^[0-9]{8}-[0-9]{4}$")',
     '_PD_VER_RE = _pd_re.compile(r"^[0-9]{8}-[0-9]{4}$")'),
    ('# ===== /sdrUi =====\n# ===== sdrLage: Quellen-Schalter AN/AUTO/AUS, Lage-Profile, Zeitanteile, Krisenzeile, Stick-Zustand (nur Empfang, sendet nichts) =====',
     '# ===== /sdrUi =====\n# ===== /sdrQrmFix =====\n# ===== sdrLage: Quellen-Schalter AN/AUTO/AUS, Lage-Profile, Zeitanteile, Krisenzeile, Stick-Zustand (nur Empfang, sendet nichts) ====='),
    ('    print("sdrAir Anzeige FEHLER:", _air_e, flush=True)\n# ===== sdrWd2: /funk Daten-Watchdog-Kasten ruhig - jede Zeile genau eine Zeile (Kurztext mit Auslassung, voller Text als Tooltip, per Tipp aufklappbar), Kopfzeile immer da (feste Zeilenzahl); nur Anzeige, sendet nichts =====',
     '    print("sdrAir Anzeige FEHLER:", _air_e, flush=True)\n# ===== /sdrAir =====\n# ===== sdrWd2: /funk Daten-Watchdog-Kasten ruhig - jede Zeile genau eine Zeile (Kurztext mit Auslassung, voller Text als Tooltip, per Tipp aufklappbar), Kopfzeile immer da (feste Zeilenzahl); nur Anzeige, sendet nichts ====='),
    ('    print("dabSql Anzeige FEHLER (Verlauf wie bisher):", _dq_e, flush=True)\n\n# ===== airTest: Anzeige - Karte Gain-Test auf /funk (Knopf Start/Abbruch mit Rueckfrage, Tabelle je Stufe, Empfehlung nur als Anzeige) und /api/sdr/airtest (GET Zustand, POST start|stop nur von der Funk-Seite im Heimnetz); schreibt nur die Anforderungsdatei, aendert nie eine Einstellung, sendet nichts =====',
     '    print("dabSql Anzeige FEHLER (Verlauf wie bisher):", _dq_e, flush=True)\n# ===== /dabSql =====\n\n# ===== airTest: Anzeige - Karte Gain-Test auf /funk (Knopf Start/Abbruch mit Rueckfrage, Tabelle je Stufe, Empfehlung nur als Anzeige) und /api/sdr/airtest (GET Zustand, POST start|stop nur von der Funk-Seite im Heimnetz); schreibt nur die Anforderungsdatei, aendert nie eine Einstellung, sendet nichts ====='),
    ('    print("airTest Anzeige FEHLER (Funk-Seite wie bisher):", _at_e, flush=True)\n\n# ===== sdrRest: Anzeige - dabSql-Karte auf /dabhist zeigt die Herkunft der Koordinaten (Label Position: Wikipedia/OSM/Frank/Kopie wie 11D/helmuthzeitler.com, amtlich/nicht amtlich bleibt) und bei unsynchroner Pi-Uhr eine Hinweiszeile; Geraetenamen (Name · Rolle) in Tooltips der Empfaenger-Chips und in den Texten der Alarm-/Voralarm-Knoepfe; nur Anzeige, sendet und schaltet nichts =====',
     '    print("airTest Anzeige FEHLER (Funk-Seite wie bisher):", _at_e, flush=True)\n# ===== /airTest =====\n\n# ===== sdrRest: Anzeige - dabSql-Karte auf /dabhist zeigt die Herkunft der Koordinaten (Label Position: Wikipedia/OSM/Frank/Kopie wie 11D/helmuthzeitler.com, amtlich/nicht amtlich bleibt) und bei unsynchroner Pi-Uhr eine Hinweiszeile; Geraetenamen (Name · Rolle) in Tooltips der Empfaenger-Chips und in den Texten der Alarm-/Voralarm-Knoepfe; nur Anzeige, sendet und schaltet nichts ====='),
    ('    print("sdrRest Anzeige FEHLER (Karte wie bisher):", _rs_e, flush=True)\n\n# ===== sdrRest2: Anzeige - dabSql-Karte: Kanal 10C \'nicht geprueft\' (gelb) statt \'offline\', solange der Hobby-Stick belegt ist; Uhr-Hinweis \'Uhr ungeprueft\' als eigene Zeile (aus dem API-Feld clock.state); nur Anzeige =====',
     '    print("sdrRest Anzeige FEHLER (Karte wie bisher):", _rs_e, flush=True)\n# ===== /sdrRest =====\n\n# ===== sdrRest2: Anzeige - dabSql-Karte: Kanal 10C \'nicht geprueft\' (gelb) statt \'offline\', solange der Hobby-Stick belegt ist; Uhr-Hinweis \'Uhr ungeprueft\' als eigene Zeile (aus dem API-Feld clock.state); nur Anzeige ====='),
    ('    print("sdrRest2 Anzeige FEHLER (Karte wie bisher):", _rs2_e, flush=True)\n\n# ===== sdrStick3: Anzeige - Hobby-Eintrag \'Stick 3 · Hobby\' (Register-Feld tag) in der Geraete-Zeile und in der Funk-Lage; Werks-SN-Stick bleibt \'erkannt, ohne Rolle\'; nur Anzeige =====',
     '    print("sdrRest2 Anzeige FEHLER (Karte wie bisher):", _rs2_e, flush=True)\n# ===== /sdrRest2 =====\n\n# ===== sdrStick3: Anzeige - Hobby-Eintrag \'Stick 3 · Hobby\' (Register-Feld tag) in der Geraete-Zeile und in der Funk-Lage; Werks-SN-Stick bleibt \'erkannt, ohne Rolle\'; nur Anzeige ====='),
    ('    print("sdrStick3 Anzeige FEHLER (Geraete-Zeile wie bisher):", _s3_e, flush=True)\n\n# ===== projDoc: Projektbeschreibung Lage Pi - Kachel ganz unten auf /pi (UNTER der Sicherung), Download der Dateien aus docs/ (nur TXT/MD mit Versionsnamen), GET /api/docs/list, /api/docs/download, /api/docs/routes; nur lesen, sendet und schaltet nichts =====',
     '    print("sdrStick3 Anzeige FEHLER (Geraete-Zeile wie bisher):", _s3_e, flush=True)\n# ===== /sdrStick3 =====\n\n# ===== projDoc: Projektbeschreibung Lage Pi - Kachel ganz unten auf /pi (UNTER der Sicherung), Download der Dateien aus docs/ (nur TXT/MD mit Versionsnamen), GET /api/docs/list, /api/docs/download, /api/docs/routes; nur lesen, sendet und schaltet nichts ====='),
    ('    print("autoGain Anzeige FEHLER (Funk-Seite wie bisher):", _ag_e, flush=True)\n\n# ===== sdrStick3e: Anzeige - \'Stick 3 · Hobby\' (Register-Rolle hobby2) wie die anderen Geraete: Funk-Lage-Zeile + Last (JS-Zeilen oben), Lage-Kachel (Stick-Zeile, Marke S3 an APRS/433, Korrektur-ppm), Geraete-Zeile, Lage-Text, 10C-Quelle, Watchdog-Zeile ueber wd_status; nur Anzeige =====',
     '    print("autoGain Anzeige FEHLER (Funk-Seite wie bisher):", _ag_e, flush=True)\n# ===== /autoGain =====\n\n# ===== sdrStick3e: Anzeige - \'Stick 3 · Hobby\' (Register-Rolle hobby2) wie die anderen Geraete: Funk-Lage-Zeile + Last (JS-Zeilen oben), Lage-Kachel (Stick-Zeile, Marke S3 an APRS/433, Korrektur-ppm), Geraete-Zeile, Lage-Text, 10C-Quelle, Watchdog-Zeile ueber wd_status; nur Anzeige ====='),
    ('    print("sdrStick3e Anzeige FEHLER (Anzeige wie bisher):", _s3e_e, flush=True)\n\n# ===== relHygiene: Zugriffsprotokoll auf Fehler begrenzt (Journal ruhiger), Chart.js lokal unter /static/vendor/chart-4.4.1.min.js mit ruhigem Fallback (REL-04, REL-09); nur Protokoll/Anzeige, keine Alarm-, Sende- oder Abruflogik =====',
     '    print("sdrStick3e Anzeige FEHLER (Anzeige wie bisher):", _s3e_e, flush=True)\n# ===== /sdrStick3e =====\n\n# ===== relHygiene: Zugriffsprotokoll auf Fehler begrenzt (Journal ruhiger), Chart.js lokal unter /static/vendor/chart-4.4.1.min.js mit ruhigem Fallback (REL-04, REL-09); nur Protokoll/Anzeige, keine Alarm-, Sende- oder Abruflogik ====='),
    ('    print("relHygiene FEHLER (Verhalten wie bisher):", _rh_e, flush=True)\n\n# ===== perfKeep: keepLast schreibt keep-last.json nur noch bei Aenderung, /pi nimmt den Ping aus dem Zwischenspeicher (nur Geschwindigkeit; keine Anzeige-, Alarm-, Sende- oder Abruflogik) =====',
     '    print("relHygiene FEHLER (Verhalten wie bisher):", _rh_e, flush=True)\n# ===== /relHygiene =====\n\n# ===== perfKeep: keepLast schreibt keep-last.json nur noch bei Aenderung, /pi nimmt den Ping aus dem Zwischenspeicher (nur Geschwindigkeit; keine Anzeige-, Alarm-, Sende- oder Abruflogik) ====='),
    ('    print("perfKeep Selbsttest FEHLER:", _pk_e, flush=True)\n\n# ===== sameOrigin: zentrale Herkunftspruefung fuer alle Aendern-Anfragen (POST usw.), SEC-05/MOD-09; keine Sende-, Alarm- oder Abruflogik, keine Anzeige =====',
     '    print("perfKeep Selbsttest FEHLER:", _pk_e, flush=True)\n# ===== /perfKeep =====\n\n# ===== sameOrigin: zentrale Herkunftspruefung fuer alle Aendern-Anfragen (POST usw.), SEC-05/MOD-09; keine Sende-, Alarm- oder Abruflogik, keine Anzeige ====='),
    ('    print("sameOrigin Selbsttest FEHLER (Schutz NICHT aktiv):", _so_e, flush=True)\n\n# ===== alarmFaden: NINA und DWD aus dem 15-Minuten-Sammelzyklus gelöst - eigener Faden mit eigenem Intervall (PERF-02); Mesh-Weiterleitung, Dedup und Anzeige bleiben wie bisher =====',
     '    print("sameOrigin Selbsttest FEHLER (Schutz NICHT aktiv):", _so_e, flush=True)\n# ===== /sameOrigin =====\n\n# ===== alarmFaden: NINA und DWD aus dem 15-Minuten-Sammelzyklus gelöst - eigener Faden mit eigenem Intervall (PERF-02); Mesh-Weiterleitung, Dedup und Anzeige bleiben wie bisher ====='),
    ('    print("alarmFaden Selbsttest FEHLER (Sammelzyklus ruft NINA/DWD wie bisher selbst ab):", _al_e, flush=True)\n\n# ===== relWatch: Aufseher fuer die Alarm-Faeden (REL-02) und Prozess-Waechter fuer systemd (REL-01) - meldet im Status und im Journal; kontrollierter Neustart nur wenn der Webserver nach dem ersten Voll-Update 3 min lang nicht antwortet (hoechstens 3 je Stunde, Schleifenbremse); sendet nichts nach aussen =====',
     '    print("alarmFaden Selbsttest FEHLER (Sammelzyklus ruft NINA/DWD wie bisher selbst ab):", _al_e, flush=True)\n# ===== /alarmFaden =====\n\n# ===== relWatch: Aufseher fuer die Alarm-Faeden (REL-02) und Prozess-Waechter fuer systemd (REL-01) - meldet im Status und im Journal; kontrollierter Neustart nur wenn der Webserver nach dem ersten Voll-Update 3 min lang nicht antwortet (hoechstens 3 je Stunde, Schleifenbremse); sendet nichts nach aussen ====='),
    ('    print("relWatch Selbsttest FEHLER (Aufseher bleibt aus, systemd-Herzschlag laeuft weiter):", _rw_e, flush=True)\n\n# ===== dbVis: SQLite-Zustand auf /pi - eine Zeile in der Datenquellen-Kachel (direkt nach der GPS-Zeile): HEALTHY (WAL-Mode) / WARNUNG / FEHLER mit Grund. Liest nur Zwischenspeicher: das quick_check-Ergebnis der DB-Wartung (relDb, im Speicher bzw. lagezentrum.db.maint.json) und den echten journal_mode (eine schreibgeschuetzte Abfrage je 5 min). Nie ein quick_check in der Seite; sendet nichts =====',
     '    print("relWatch Selbsttest FEHLER (Aufseher bleibt aus, systemd-Herzschlag laeuft weiter):", _rw_e, flush=True)\n# ===== /relWatch =====\n\n# ===== dbVis: SQLite-Zustand auf /pi - eine Zeile in der Datenquellen-Kachel (direkt nach der GPS-Zeile): HEALTHY (WAL-Mode) / WARNUNG / FEHLER mit Grund. Liest nur Zwischenspeicher: das quick_check-Ergebnis der DB-Wartung (relDb, im Speicher bzw. lagezentrum.db.maint.json) und den echten journal_mode (eine schreibgeschuetzte Abfrage je 5 min). Nie ein quick_check in der Seite; sendet nichts ====='),
]
MK_RAE_EOF
EXPECT_RAB="459f62fb118a420d6fda330179cf2ef9ad8b6419e9124a74ee29c526e9cf1485"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== modDead: toter Code und doppelte Definitionen entfernt (MOD-08), fehlende Ende-Marker ergaenzt =====
# Reine Aufraeum-Schicht, kein neues Verhalten. Entfernt wurden nur Funktionen/Variablen, die statisch (Name, Zeichenketten, andere Dateien) und
# dynamisch (globals()/getattr-Namen) nirgends benutzt werden, sowie frueher ueberschriebene Erstdefinitionen. Beleg je Eintrag: DOCS_TEXT.md.
# Bewusst behalten: _mesh_port_ok (mesh_session.py umhuellt sie per getattr), _ws_score/_ws_selftest (Spiegelkopie von prepper_sdr.py).
_MD_GONE = ("_mesh_closewait", "freq_stage", "last_pegel_cm", "mesh_send_lock", "_om_weather", "_keep_apply_ts", "_sdh_fmt", "_sdh_card",
            "_PP_SHORT", "_PP_COL", "_pp_age", "_pp_rowhtml", "_sw_card", "_sdrui_hm", "_fu_num", "_wd_base", "_PD_STEM", "PAGE_SCANNER", "PAGE_DECODER")
_MD_KEPT = ("scanner_mode_get", "scanner_mode_set", "lng_util_color", "set_nina_bayern_auto", "note_mesh_tx", "_mesh_port_ok", "_ws_score", "_ws_selftest")


def _selftest_moddead():
    g = globals()
    back = [n for n in _MD_GONE if n in g]
    assert not back, "entfernte Namen wieder da: %s" % ", ".join(back)
    fehlt = [n for n in _MD_KEPT if not callable(g.get(n))]
    assert not fehlt, "benoetigte Funktionen fehlen: %s" % ", ".join(fehlt)
    assert lng_util_color(None) == "#94a3b8" and lng_util_color(10) == "#ef4444" and lng_util_color(60) == "#eab308" and lng_util_color(90) == "#22c55e"
    assert "systemctl" not in repr(scanner_mode_get.__code__.co_consts) + repr(scanner_mode_set.__code__.co_consts), "alte scanner_mode_*-Fassung mit systemctl aktiv"
    return "modDead ok (%d Namen entfernt, %d Funktionen mit erhaltener Spaetfassung geprueft)" % (len(_MD_GONE), len(_MD_KEPT))


try:
    _MD_ST = _selftest_moddead()
    print("modDead aktiv: %s" % _MD_ST, flush=True)
except Exception as _md_e:
    print("modDead Selbsttest FEHLER (%s)" % _md_e, flush=True)
# ===== /modDead =====
MK_RAB_EOF
EXPECT_RAG="0ac4befd93512af22f6edfac94f0c19bcb07323509b0b255c8425d412b12529f"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-Guard modDead (nur dashboard.py: Entfernen von Totem + Ende-Marker + kleiner Block). Aufruf:
  guard_md.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne modDead (Rueckbau, byte-genau)
  guard_md.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln (AST-Gleichheit bis auf die entfernten Knoten, Referenzfreiheit, Marker, Aufbau der Stellen, Block)
  RH_ALT=ALT_VERZ guard_md.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest
Laeuft ohne node (reine Python-Pruefung)."""
import ast
import contextlib
import io
import os
import re
import shutil
import sys
import tempfile
import tokenize

# Erwartete Entfernungen (Name, Art) - Reihenfolge egal, als Menge verglichen
SPEC = [('scanner_mode_get', 'def'), ('scanner_mode_set', 'def'), ('_mesh_closewait', 'def'), ('lng_util_color', 'def'), ('freq_stage', 'def'), ('last_pegel_cm', 'var'), ('set_nina_bayern_auto', 'def'), ('mesh_send_lock', 'var'), ('_om_weather', 'def'), ('note_mesh_tx', 'def'), ('PAGE_SCANNER', 'var'), ('PAGE_DECODER', 'var'), ('_keep_apply_ts', 'def'), ('_sdh_fmt', 'def'), ('_sdh_card', 'def'), ('_PP_SHORT', 'var'), ('_PP_COL', 'var'), ('_pp_age', 'def'), ('_pp_rowhtml', 'def'), ('_sw_card', 'def'), ('_sdh_card', 'def'), ('_sdrui_hm', 'def'), ('_fu_num', 'def'), ('_wd_base', 'def'), ('_PD_STEM', 'var')]
GONE = ("_mesh_closewait", "freq_stage", "last_pegel_cm", "mesh_send_lock", "_om_weather", "_keep_apply_ts", "_sdh_fmt", "_sdh_card",
        "_PP_SHORT", "_PP_COL", "_pp_age", "_pp_rowhtml", "_sw_card", "_sdrui_hm", "_fu_num", "_wd_base", "_PD_STEM", "PAGE_SCANNER", "PAGE_DECODER")
KEPT = ("scanner_mode_get", "scanner_mode_set", "lng_util_color", "set_nina_bayern_auto", "note_mesh_tx", "_mesh_port_ok", "_ws_score", "_ws_selftest")
MARK_RE = re.compile(r"# ===== (/)?([A-Za-z0-9_\-]+)(:.*)? =====\s*$")
FORBID = ("subprocess", "requests", "urlopen", "socket", "sudo", "systemctl.run", "open(", "os.system", "Popen", "send_meshtastic", "eval(", "exec(", "__import__")


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block modDead nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in reversed(edits):
        assert s.count(n) == 1, "Stelle modDead nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def kind_name(n):
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
        return (n.name, "def")
    if isinstance(n, ast.ClassDef):
        return (n.name, "class")
    if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
        return (n.targets[0].id, "var")
    return None


def split_block(new, blk):
    B = rd(blk).rstrip("\n")
    assert new.count(B) == 1, "Block modDead nicht genau einmal"
    i = new.index(B)
    bs = new.count("\n", 0, i) + 1
    be = bs + B.count("\n")
    return bs, be


def check_block_text(B):
    t = ast.parse(B)
    names = []
    for n in t.body:
        k = kind_name(n)
        if k:
            names.append(k)
        elif isinstance(n, ast.Try) and "_selftest_moddead()" in ast.unparse(n):
            names.append(("#try", "try"))
        else:
            raise AssertionError("Block enthaelt unerlaubten Knoten %s" % type(n).__name__)
    assert names == [("_MD_GONE", "var"), ("_MD_KEPT", "var"), ("_selftest_moddead", "def"), ("#try", "try")], names
    vals = {n.targets[0].id: ast.literal_eval(n.value) for n in t.body if isinstance(n, ast.Assign)}
    assert tuple(vals["_MD_GONE"]) == GONE, "_MD_GONE im Block weicht von der Erwartung ab"
    assert tuple(vals["_MD_KEPT"]) == KEPT, "_MD_KEPT im Block weicht von der Erwartung ab"
    for w in FORBID:
        assert w not in B, "Block enthaelt verbotenes Wort: " + w
    for x in ast.walk(t):
        if isinstance(x, ast.Call) and isinstance(x.func, ast.Name) and x.func.id in ("eval", "exec", "open", "__import__", "compile"):
            raise AssertionError("Block ruft " + x.func.id)
    first = B.splitlines()[0]
    assert first.startswith("# ===== modDead:") and B.rstrip().splitlines()[-1] == "# ===== /modDead =====", "Block ohne Marker"


def run_block(B, extra, drop=()):
    """Block in einem Sandbox-Namensraum ausfuehren; liefert die ausgegebene Zeile."""
    def cb(x=None):
        return "#94a3b8" if x is None else ("#ef4444" if x < 50 else ("#eab308" if x < 80 else "#22c55e"))

    def mk(sc):
        def f(*a, **k):
            return None
        f.__code__ = f.__code__.replace(co_consts=f.__code__.co_consts + (sc,)) if sc else f.__code__
        return f
    g = {"__name__": "x", "__file__": "dashboard.py", "lng_util_color": cb}
    for n in ("scanner_mode_get", "scanner_mode_set", "set_nina_bayern_auto", "note_mesh_tx", "_mesh_port_ok", "_ws_score", "_ws_selftest"):
        g[n] = mk(None)
    g.update(extra)
    for d in drop:
        g.pop(d, None)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(B, "blk", "exec"), g)
    return buf.getvalue()


def behav(blk):
    B = rd(blk)
    ok = run_block(B, {})
    assert "modDead aktiv: modDead ok" in ok and "FEHLER" not in ok, "Block-Selbsttest laeuft im sauberen Namensraum nicht durch: " + ok[:120]
    bad = run_block(B, {"freq_stage": 1})
    assert "FEHLER" in bad and "aktiv" not in bad, "Selbsttest erkennt einen wieder vorhandenen entfernten Namen nicht"
    bad = run_block(B, {}, drop=("note_mesh_tx",))
    assert "FEHLER" in bad, "Selbsttest erkennt eine fehlende erhaltene Funktion nicht"
    bad = run_block(B, {"scanner_mode_get": (lambda: None)})
    # (lambda hat kein systemctl in den Konstanten -> bleibt ok; der Test unten prueft die alte Fassung)

    def old_sm():
        return "systemctl is-active x"
    bad = run_block(B, {"scanner_mode_get": old_sm})
    assert "FEHLER" in bad, "Selbsttest erkennt die alte scanner_mode_*-Fassung mit systemctl nicht"
    return 4


def words_outside_block(new, bs, be):
    L = new.split("\n")
    txt = "\n".join(L[:bs - 1] + L[be:])
    toks = set()
    for tok in tokenize.generate_tokens(io.StringIO(txt).readline):
        if tok.type == tokenize.NAME:
            toks.add(tok.string)
        elif tok.type == tokenize.STRING or tok.type == getattr(tokenize, "FSTRING_MIDDLE", -1):
            toks |= set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", tok.string))
    return toks


def static(alt, new, blk, edits):
    n = 0
    bs, be = split_block(new, blk)
    B = rd(blk).rstrip("\n")
    check_block_text(B)
    assert new.count("\n\n" + B + "\n\nif __name__ == \"__main__\":\n") == 1, "Block nicht direkt vor dem __main__-Block"
    n += 2
    ta, tn = ast.parse(alt), ast.parse(new)
    A = list(ta.body)
    N = [x for x in tn.body if not (bs <= x.lineno <= be)]
    blocknodes = [x for x in tn.body if bs <= x.lineno <= be]
    assert len(blocknodes) == 4, "Block hat %d Knoten" % len(blocknodes)
    n += 1
    i = j = 0
    removed = []
    while i < len(A):
        if j < len(N) and ast.dump(A[i]) == ast.dump(N[j]):
            i += 1
            j += 1
        else:
            k = kind_name(A[i])
            assert k is not None, "Zeile %d: entfernter Knoten ist weder Funktion noch einfache Variable (%s)" % (A[i].lineno, type(A[i]).__name__)
            assert not getattr(A[i], "decorator_list", None), "entfernte Funktion %s traegt einen Dekorator" % k[0]
            removed.append(k)
            i += 1
    assert j == len(N), "neuer Stand hat Knoten, die im alten Stand fehlen oder veraendert sind (ab Knoten %d, Zeile %d)" % (j, N[j].lineno if j < len(N) else -1)
    assert sorted(removed) == sorted(SPEC), "entfernte Knoten weichen von der Erwartung ab: %s" % (sorted(set(removed) ^ set(SPEC)) or "Haeufigkeit")
    n += 2
    # Zielknoten fuer KEPT: im neuen Stand noch vorhanden
    present = {kind_name(x)[0] for x in N if kind_name(x)}
    for k in KEPT:
        assert k in present, "erhaltene Funktion fehlt im neuen Stand: " + k
    n += 1
    # Referenzfreiheit der entfernten Namen (Code und Zeichenketten ausserhalb des Blocks)
    w = words_outside_block(new, bs, be)
    for g_ in GONE:
        assert g_ not in w, "entfernter Name %s wird im Programm noch erwaehnt" % g_
    n += 1
    # Aufbau der Stellen: entweder reine Entfernung (new = Ende von old) oder genau eine eingefuegte Ende-Marker-Zeile
    got = []
    nmark = 0
    for o, nw in edits:
        if o.endswith(nw) and len(o) > len(nw):
            pre = o[:len(o) - len(nw)]
            tp = ast.parse(pre)
            for x in tp.body:
                k = kind_name(x)
                assert k is not None
                got.append(k)
            assert all(not c.lstrip().startswith("#") or True for c in pre.split("\n"))
        else:
            ol, nl = o.split("\n"), nw.split("\n")
            assert len(nl) == len(ol) + 1, "Stelle ist weder Entfernung noch Marker-Einfuegung: " + o.strip().splitlines()[0][:60]
            ins = [x for x in range(len(nl)) if nl[:x] + nl[x + 1:] == ol]
            assert ins and MARK_RE.match(nl[ins[0]]) and MARK_RE.match(nl[ins[0]]).group(1) == "/", "eingefuegte Zeile ist kein Ende-Marker"
            nmark += 1
    assert sorted(got) == sorted(SPEC), "Entfernungs-Stellen weichen von der Erwartung ab"
    n += 2
    # Marker: jede Start-Zeile hat genau ein Ende danach; Anzahl der Start-Zeilen unveraendert
    def marks(s):
        st, en = [], {}
        for ix, l in enumerate(s.split("\n")):
            m = MARK_RE.match(l)
            if m:
                if m.group(1):
                    assert m.group(2) not in en, "doppelter Ende-Marker " + m.group(2)
                    en[m.group(2)] = ix
                else:
                    st.append((ix, m.group(2)))
        return st, en
    sa, ea = marks(alt)
    sn, en_ = marks(new)
    assert [x[1] for x in sa] + ["modDead"] == [x[1] for x in sn], "Start-Marker veraendert"
    for ix, nm in sn:
        assert nm in en_ and en_[nm] > ix, "Start-Marker ohne Ende: " + nm
    assert len(en_) - len(ea) == nmark + 1, "Anzahl neuer Ende-Marker passt nicht (%d statt %d)" % (len(en_) - len(ea), nmark + 1)
    n += 3
    # Zeilenzahl: nur kleiner
    assert new.count("\n") < alt.count("\n"), "Programm ist nicht kuerzer geworden"
    n += 1
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_MD_NOSTATIC") == "1" else static(alt, new, blk, edits)
    if os.environ.get("RH_MD_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(blk)
    print("OK guard modDead: %d Pruefungen, 0 fehlerhaft" % n)
    return n


def _insert_before(s, anchor, text):
    assert s.count(anchor) == 1, anchor[:40]
    return s.replace(anchor, text + anchor, 1)


def _first_def(s, name):
    m = re.search(r"^def %s\(.*?(?=^\S)" % re.escape(name), s, re.M | re.S)
    assert m, name
    return m


def _mut_list(new, B):
    """(Name, neu_text, block_text, norev) - alle muessen von check() abgelehnt werden."""
    L = []
    pre = new[:new.index(B)]
    post = new[new.index(B):]

    def rep(s, a, b, cnt=1):
        assert s.count(a) == cnt, "%s: %d" % (a[:50], s.count(a))
        return s.replace(a, b, 1)
    # --- AST: zusaetzlich etwas Lebendes entfernt / Totes wieder da / Lebendes veraendert
    m = _first_def(pre, "fetch_mesh_link")
    L.append(("D1 lebende Funktion fetch_mesh_link zusaetzlich entfernt", pre[:m.start()] + pre[m.end():] + post, B, 1))
    m = _first_def(pre, "api_scanner_mode")
    dec = '@app.route("/api/scanner_mode", methods=["GET", "POST"])\n'
    assert pre[:m.start()].endswith(dec)
    L.append(("D2 Route (Dekorator) api_scanner_mode zusaetzlich entfernt", pre[:m.start() - len(dec)] + pre[m.end():] + post, B, 1))
    L.append(("D3 entfernte Funktion freq_stage wieder da", rep(pre, "\ndef maybe_mesh_frequenz(hz, force=False):", "\ndef freq_stage(hz):\n    return None\n\n\ndef maybe_mesh_frequenz(hz, force=False):") + post, B, 1))
    L.append(("D4 entfernte Variable PAGE_SCANNER wieder da", rep(pre, "\n\n\n@app.route(\"/scanner\")", "\n\n\nPAGE_SCANNER = \"\"\n\n\n@app.route(\"/scanner\")") + post, B, 1))
    L.append(("D5 Konstante in lebendem Code geaendert", rep(pre, "last_nina_received = None  # wann aktuelle Warnung zuerst gesehen", "last_nina_received = 0  # wann aktuelle Warnung zuerst gesehen") + post, B, 1))
    L.append(("D6 Leerzeichen/Formatierung im Code geaendert (nur Text)", rep(pre, "def _fnum(x):\n", "def _fnum(x): \n") + post, B, 0))
    L.append(("D7 Kommentar zusaetzlich eingefuegt", rep(pre, "def _fnum(x):\n", "# zusaetzlicher Kommentar\ndef _fnum(x):\n") + post, B, 0))
    L.append(("D8 Verweis auf entfernten Namen in einer Zeichenkette", rep(pre, "def _fnum(x):\n", "_MD_X = 'freq_stage'\ndef _fnum(x):\n") + post, B, 1))
    L.append(("D9 Verweis auf entfernten Namen im Code", rep(pre, "def _fnum(x):\n", "_MD_Y = _wd_base\ndef _fnum(x):\n") + post, B, 1))
    L.append(("D10 erhaltene Funktion note_mesh_tx entfernt", pre[:_first_def(pre, "note_mesh_tx").start()] + pre[_first_def(pre, "note_mesh_tx").end():] + post, B, 1))
    # --- Marker
    L.append(("K1 ein Ende-Marker fehlt", rep(pre, "# ===== /perfKeep =====\n", "") + post, B, 1))
    L.append(("K2 doppelter Ende-Marker", rep(pre, "# ===== /perfKeep =====\n", "# ===== /perfKeep =====\n# ===== /perfKeep =====\n") + post, B, 1))
    L.append(("K3 Ende-Marker vor dem Start", rep(rep(pre, "# ===== /perfKeep =====\n", ""), "# ===== perfKeep:", "# ===== /perfKeep =====\n# ===== perfKeep:") + post, B, 1))
    L.append(("K4 Start-Marker umbenannt", rep(pre, "# ===== sameOrigin:", "# ===== sameOrigin2:") + post, B, 1))
    # --- Block
    for nm, a, b in (("B1 Block ohne Pruefung auf entfernte Namen", "    assert not back, \"entfernte Namen wieder da: %s\" % \", \".join(back)\n", ""),
                     ("B2 Block ohne Pruefung auf fehlende Funktionen", "    assert not fehlt, \"benoetigte Funktionen fehlen: %s\" % \", \".join(fehlt)\n", ""),
                     ("B3 Block ohne systemctl-Pruefung", "    assert \"systemctl\" not in repr(scanner_mode_get.__code__.co_consts) + repr(scanner_mode_set.__code__.co_consts), \"alte scanner_mode_*-Fassung mit systemctl aktiv\"\n", ""),
                     ("B4 Block mit subprocess", "def _selftest_moddead():\n", "import subprocess\n\n\ndef _selftest_moddead():\n"),
                     ("B5 Block ruft open", "    g = globals()\n", "    g = globals()\n    open('/tmp/x')\n"),
                     ("B6 Liste GONE verkuerzt", "\"_wd_base\", \"_PD_STEM\", ", ""),
                     ("B7 Selbsttest wirft nie (try/except schluckt Meldung)", "    print(\"modDead Selbsttest FEHLER (%s)\" % _md_e, flush=True)\n", "    pass\n"),
                     ("B8 Block ohne Ende-Marker", "# ===== /modDead =====", "")):
        assert B.count(a) == 1, nm
        nb = B.replace(a, b)
        L.append((nm, pre + nb + post[len(B):], nb, 1))
    # --- Stellen mutiert (Rueckbau muss scheitern; norev=0)
    return L


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    B = rd(blk).rstrip("\n")
    bad = []
    done = 0
    muts = _mut_list(base_new, B)
    # zusaetzliche Mutationen an den Stellen (EDITS): werden ueber veraenderte Edit-Dateien geprueft
    edits, anch = load_edits(ep)
    for name, mnew, mblk, norev in muts:
        w = tempfile.mkdtemp(prefix="md-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(mnew)
            bf = os.path.join(w, "blk.py")
            with open(bf, "w", encoding="utf-8") as f:
                f.write(mblk if mblk.endswith("\n") else mblk + "\n")
            if norev:
                os.environ["RH_MD_NOREV"] = "1"
            else:
                os.environ.pop("RH_MD_NOREV", None)
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    check(altdir, nd, bf, ep)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            os.environ.pop("RH_MD_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)
    # Stellen-Mutationen (Edit-Dateien im Speicher veraendert, neuer Stand unveraendert)
    def edmut(name, fn):
        nonlocal done
        e2 = fn([tuple(x) for x in edits])
        w = tempfile.mkdtemp(prefix="md-mut-")
        try:
            ef = os.path.join(w, "edits.py")
            with open(ef, "w", encoding="utf-8") as f:
                f.write("DSH_ANCHOR = %r\nDSH_EDITS = %r\n" % (anch, e2))
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new)
            os.environ.pop("RH_MD_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, blk, ef)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            shutil.rmtree(w, ignore_errors=True)
    edmut("E1 eine Entfernungs-Stelle fehlt", lambda e: e[1:])
    edmut("E2 eine Marker-Stelle fehlt", lambda e: e[:-1])
    edmut("E3 Stelle verkuerzt (Rueckbau ungenau)", lambda e: [(e[0][0][:-10] + "X", e[0][1])] + e[1:] if False else [(e[0][0], e[0][1] + "# x\n")] + e[1:])
    edmut("E4 Marker-Stelle ohne Marker (new == old)", lambda e: e[:-1] + [(e[-1][0], e[-1][0])])
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation modDead: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a[0] == "revert":
            revert(*a[1:5])
        elif a[0] == "check":
            check(*a[1:5])
        elif a[0] == "mutate":
            sys.exit(mutate(*a[1:4]))
        else:
            print(__doc__)
            sys.exit(2)
    except AssertionError as e:
        print("guard modDead FEHLER: %s" % e)
        sys.exit(1)
MK_RAG_EOF
PPK="$W/patch.py"; RED="$W/edits.py"; RBK="$W/blk.py"; RGD="$W/guard.py"
for x in "$EXPECT_PAL $PPK" "$EXPECT_RAE $RED" "$EXPECT_RAB $RBK" "$EXPECT_RAG $RGD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Patcher, Stellen, Block, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach mapUi commit31b" "$KNOWN_D16N" "modDead schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      modDead passt nur auf den Stand Stand nach mapUi commit31b (dashboard.py 9cb49ceab0243cc4). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi kartevec; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"

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
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" modDead dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer modDead nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" modDead dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: modDead im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne modDead ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard modDead meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" nice -n 10 "$VPY" "$RGD" mutate "$W/neu" "$RBK" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^aequivalent|^OK" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local i; for i in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
pcode() { code -X POST "$@"; }
PILAT0=$(tmed "$B/pi")
echo "Zustand vorher: /pi antwortet im Median in ${PILAT0} s"
# ---- modDead: Fingerabdruck der Seiten vorher (nur Lesen; Ziffern maskiert, Leerraum zusammengefasst) ----
fp() { "${CURL[@]}" -L --max-redirs 5 "$1" 2>/dev/null | python3 -c "import sys,re,hashlib; t=sys.stdin.read(); t=re.sub(r'[0-9]+(?:\.[0-9]+)?','#',t); t=re.sub(r'\s+',' ',t); print(hashlib.sha256(t.encode()).hexdigest()[:12], len(t))" 2>/dev/null || echo "-"; }
declare -A FP0
for p in "${PAGES[@]}"; do FP0[$p]=$(fp "$B$p"); done
echo "Zustand vorher: Seiten-Fingerabdruck von ${#PAGES[@]} Seiten gemerkt (Vergleich nach dem Neustart, nur als Hinweis)"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: modDead ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-moddead-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG moddead=dry fertig"
  exit 0
fi
if [[ "$NEED_D" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "modDead|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-moddead-$TS" ]] && cp -a "$F.bak-moddead-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-moddead-$TS" ]] && { cmp -s "$F" "$F.bak-moddead-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK modDead schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-moddead-$TS"
  { ls -1t "$F.bak-moddead-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-moddead-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-moddead-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'modDead aktiv' im Journal ..."
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
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); P1=$(grep -o 'Projektbeschreibung' "$W/pi.html" | wc -l || true)
[[ "$R1" -ge 1 && "$P1" -ge 1 ]] || rbx "/pi liefert Sicherung/Projektbeschreibung nicht mehr (doPrepperRestore ${R1}x, Projektbeschreibung ${P1}x)"
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; modDead aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- modDead: Seiten nachher wie vorher (Fingerabdruck, nur Hinweis - Live-Daten duerfen abweichen), Marker modDead je genau einmal ----
SAME=0; DIFFP=""
for p in "${PAGES[@]}"; do
  f1=$(fp "$B$p")
  if [[ "$f1" == "${FP0[$p]}" ]]; then SAME=$((SAME+1)); else f1b=$(fp "$B$p"); [[ "$f1b" == "${FP0[$p]}" ]] && SAME=$((SAME+1)) || DIFFP="$DIFFP $p"; fi
done
if [[ -z "$DIFFP" ]]; then echo "OK Seiten-Fingerabdruck: alle ${#PAGES[@]} Seiten identisch zu vorher (Ziffern maskiert)"
else echo "HINWEIS Seiten-Fingerabdruck weicht ab bei:$DIFFP (${SAME} von ${#PAGES[@]} identisch) - Live-Daten (Zeiten, Zaehler, Werte) koennen sich zwischen den Abrufen aendern; modDead aendert keine Seite. Bei Zweifel: Rueckweg unten."; fi
n=$(grep -c '^def \(_mesh_closewait\|freq_stage\|_om_weather\|_keep_apply_ts\|_sdh_fmt\|_sdh_card\|_pp_age\|_pp_rowhtml\|_sw_card\|_sdrui_hm\|_fu_num\|_wd_base\)(' "$F" || true)
[[ "${n:-0}" == 0 ]] && echo "OK die entfernten Funktionen sind aus dashboard.py verschwunden (0 Treffer), Zeilen jetzt $(wc -l < "$F")" || rbx "entfernte Funktionen noch in dashboard.py ($n Treffer)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E modDead"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "modDead aktiv: modDead ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'modDead aktiv: modDead ok' ($(echo "$JD" | grep -F modDead | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein modDead-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)")"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"))" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi kartevec modDead; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-moddead-$TS" ]] && echo "Backup: dashboard.py.bak-moddead-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-moddead-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine moddead-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c 'modDead' /home/fmg/prepper-dashboard/dashboard.py"
echo "  wc -l /home/fmg/prepper-dashboard/dashboard.py"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep modDead"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG moddead=1 fertig"
