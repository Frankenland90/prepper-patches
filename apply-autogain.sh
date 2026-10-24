#!/bin/bash
set -eEuo pipefail
# autoGain (commit16): Gain-Automatik fuer den Airspy 11D + Kachelbreite auf /funk.
#  - prepper_sdr.py: Engine (Messung etwa taeglich im Nachtfenster und nach anhaltend schlechtem Empfang, Score mit FIC am staerksten, Wechsel nur bei klarem Vorteil ueber mehrere Messungen, nie bei Alarm/ASA/PTY 31/Antennentest/Meteor,
#    Flip-Flop-Sperre: mehr als 2 Wechsel in 48 h oder schlechterer Empfang nach Wechsel = bester fester Wert, Rueckfall bei Fehlern = Stufe 16). Gain-Test 2 (14/16/17/18 + Auto). Auto (welle-cli -g -1) ist eine Software-AGC und wird nur gemessen, nie gewaehlt.
#  - sdr_manager.py: Datenschicht (Score, Entscheidung, Anzeige). dashboard.py: Karte "Gain-Automatik" auf /funk (Auto/Fest, Verlauf, Grund des letzten Wechsels), /api/sdr/autogain, Kachelbreite auf /funk (Raster minmax(0,1fr)).
#  - prepper_docs.py: Beschreibung (Gain-Automatik, welle-cli-Befund, Kachelbreite), neue Version in docs/.
# Basis streng (sha16): Stand nach meshPost (dashboard f5b5cd5059b8ff0d) + sdrFall (prepper_sdr f709b303d33a61c5, sdr_manager 002f6c5cad4bc1cb) oder autoGain schon drin. Steht der Pi noch auf projDoc: Stopp mit Hinweis (zuerst meshPost).
# Aendert den Gain bei der Installation NICHT (er bleibt, wie er ist; Pruefung vorher/nachher). Neustart: prepper-sdr, danach prepper-dashboard (kein Reboot). Sendet nichts (kein Mesh, kein Telegram, keine Alarme); keine Secrets gelesen ausser der Zeile PORT = n.
# Sicherungen: letzte 3 (dashboard.py, prepper_sdr.py, sdr_manager.py, prepper_docs.py) + SQLite-Sicherung lagezentrum.db. Bei jedem Stopp steht der Grund in der Ausgabe.
COMMIT_ARG="${1:-unbekannt}"
unset PRDOCS_NOW PRDOCS_SYSTEMCTL PRDOCS_SBIN PRDOCS_SUDOERS PRDOCS_UNITDIR PRDOCS_BASE PRDOCS_OUT PRDOCS_PORT
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
PD="$DASH_DIR/prepper_docs.py"
DOCS="$DASH_DIR/docs"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
CF="$DASH_DIR/sdr_config.json"
AGS="$DASH_DIR/sdr_autogain.json"
AGQ="$DASH_DIR/sdr_autogain_req.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
HDST="/usr/local/sbin/prepper-sdr-wdhelper"
SYSUSB="${SDR_SYSFS_USB:-/sys/bus/usb/devices}"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/autogain-apply
KEEP_LAST=3
KNOWN_D16="f5b5cd5059b8ff0d"      # dashboard.py nach meshPost (Basis)
KNOWN_D16N="a06678b5d7441631"             # dashboard.py nach autoGain (Ziel)
KNOWN_D16PD="d383771a011d82cd"    # dashboard.py nach projDoc (meshPost fehlt -> Hinweis)
KNOWN_PD16="8967b0166de7df9d"     # prepper_docs.py nach meshPost (Basis)
KNOWN_PD16A="3584d11bc2c365a3"    # prepper_docs.py der ersten meshPost-Fassung (auch Basis)
KNOWN_PD16N="a3c385a5ca1b263e"           # prepper_docs.py nach autoGain (Ziel)
KNOWN_PD16PD="f0d04208dd9b1d20"   # prepper_docs.py nach projDoc (meshPost fehlt -> Hinweis)
KNOWN_SDR16="f709b303d33a61c5"    # prepper_sdr.py nach sdrFall (Basis)
KNOWN_SDR16N="76f2157ae2769224"         # prepper_sdr.py nach autoGain (Ziel)
KNOWN_SM16="002f6c5cad4bc1cb"     # sdr_manager.py (Basis)
KNOWN_SM16N="18fad95addf2be3f"           # sdr_manager.py nach autoGain (Ziel)
KNOWN_HL16="01c19375256b05bc"     # Hilfsprogramm nach sdrAir (bleibt unveraendert)
KNOWN_DB16="431077d36822a090"     # database.py (bleibt)
KNOWN_MR16="c5ffda3907b0dd51"     # mesh_router.py (bleibt)
KNOWN_LG16="3788481354f47656"     # lagegeo.py (bleibt)
KNOWN_CF16="476d8ad4b930c558"     # sdr_config.json (bleibt; nur Hinweis)
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
echo "=== autoGain apply (Gain-Automatik Airspy 11D, Gain-Test 2, Kachelbreite /funk, Beschreibung neue Version), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx" "$W/dsbx" "$W/alt"

EXPECT_PF="dd875ef5406a3155d7996f49701e46eebf189a38b39e3dcdaa1401f25c3ab7a4"
cat > "$W/patch-fu.py" << 'AIP_EOF'
"""Patcher fuer sdrLog/funkUI. Aufruf: patch-fu.py NAME ART QUELLE ZIEL BLOCK EDITS   (ART = sm | sdr | dash). Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E, ANCH = g["%s_EDITS" % kind.upper()], g["%s_ANCHOR" % kind.upper()]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
MARK = B.splitlines()[0]
name = {"sm": "sdr_manager", "sdr": "prepper_sdr", "dash": "dashboard", "dsh": "dashboard"}[kind]   # dsh = Dashboard-Block vor dem Hauptteil (nicht eingerueckt)
if MARK in s:
    rest = s.replace(B, "", 1)
    ok = s.count(B) == 1 and all(rest.count(n) == 1 for o, n in E)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if s.count(ANCH) != 1:
    print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
if kind == "dash":
    i = s.index(ANCH) + len(ANCH)
    s = s[:i] + B + s[i:]
else:
    i = s.index(ANCH)
    s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen + Block %s" % (name, len(E), label))
AIP_EOF
EXPECT_AE="313a88b56fc8b6307a34150a1aa444e57145c686a98a006ef4936dd8617aa9cf"
cat > "$W/ag_edits.py" << 'AE_EOF'
# autoGain: Stellen (alt, neu) auf dem meshPost-/sdrFall-Stand (dashboard f5b5cd5059b8ff0d, prepper_sdr f709b303d33a61c5, sdr_manager 002f6c5cad4bc1cb). Jede alte Stelle genau einmal.
SM_EDITS = [
    ("    print(selftest_sdrrest2())\n", "    print(selftest_sdrrest2())\n    print(selftest_autogain())\n"),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SDR_EDITS = [
    # Beschriftung des Pruefblocks: Auto (-1) statt "Airspy-Stufe -1"
    ('"db": "Airspy-Stufe %d (Gain-Test)" % g,', '"db": "%s (Gain-Test)" % ("Airspy-Auto (welle-AGC)" if g == -1 else "Airspy-Stufe %d" % g),'),
    # Zeitlimit-Text je Profil (Gain-Test 2 und Tagesmessung haben eigene Limits)
    ('why = "Zeitlimit %d min erreicht" % (AT_LIMIT_S // 60)', 'why = "Zeitlimit %d min erreicht" % max(1, int(run["deadline"] - int(run.get("t0") or now)) // 60)'),
    # Dienst: Automatik einschalten (nur im Dauerbetrieb, nie in den Selbsttests)
    ('        globals().get("_SH_START", lambda b: None)(BASE)   # sdrHalt: Waechter-Faden (wirft nie)\n',
     '        globals().get("_SH_START", lambda b: None)(BASE)   # sdrHalt: Waechter-Faden (wirft nie)\n        globals().get("_AG_START", lambda b: None)(BASE)   # autoGain: Gain-Automatik (wirft nie)\n'),
    ('        selftest_sdrfall()\n    elif a in ("stick-test"', '        selftest_sdrfall()\n        print(selftest_autogain(), flush=True)\n    elif a in ("stick-test"'),
]
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
AE_EOF
EXPECT_ASM="af66af7e40912fe8e6e0171ff4d3fb98e7c82978f35d3e795d0810bd8793205b"
cat > "$W/ag_sm_block.py" << 'ASM_EOF'
# ===== autoGain: Datenschicht Gain-Automatik Airspy 11D - Score (FIC-Fehler am staerksten), Sitzungen/Entscheidung/Flip-Flop-Regeln als reine Funktionen, Anzeige-Zustand fuer /funk (ag_view), Anforderungen (Auto/fest/messen, Gain-Test mit Profil) nur als Dateien; liest nur, aendert nie selbst eine Einstellung, sendet nichts =====
AG_FILE = "sdr_autogain.json"
AG_REQ = "sdr_autogain_req.json"
AG_GRID = (12, 14, 16, 17, 18, 19)      # Stufen, zwischen denen die Automatik waehlt (Messdaten: 12, 14, 16, 17, 18, 19)
AG_DAY_N = 5                            # Stufen je Tagesmessung (aktuelle + Nachbarn im Raster)
AG_DAY_ROUNDS = 3                       # Runden je Tagesmessung (5 Stufen x 3 = 15 Pruefbloecke, ca. 15-20 min)
AG_T2_LEVELS = (14, 16, 17, 18, -1)     # zweiter Gain-Test: -1 = Auto (welle-cli -g -1 = Software-AGC)
AG_T2_ROUNDS = 5
AG_W_FIC = 6.0                          # Score-Abzug je Prozent FIC-Fehler (am staerksten gewichtet)
AG_FIC_CAP = 12.0
AG_W_SNR = 1.5                          # Abzug je dB SNR unter AG_SNR_REF
AG_SNR_REF = 12.0
AG_SNR_CAP = 10.0
AG_MIN_N = 2                            # Messungen je Stufe und Sitzung, damit die Stufe zaehlt
AG_SESS_N = 3                           # Entscheidung aus den letzten 3 Sitzungen
AG_MARGIN = 6.0                         # klarer Vorteil: Score-Punkte
AG_SYNC_MIN = 80.0                      # Sync-Quote (%) mindestens fuer eine Zielstufe
AG_MAX_CHANGES = 2                      # mehr als 2 Wechsel in 48 h -> Sperre
AG_FLIP_S = 48 * 3600
AG_MIN_GAP_S = 6 * 3600                 # Mindestabstand zwischen zwei Wechseln
AG_POST_MIN_N = 12                      # Pruefungen nach einem Wechsel, ab denen verglichen wird
AG_POST_OK_N = 36
AG_PRE_MIN_N = 12
AG_WORSE = 10.0                         # schlechter nach Wechsel: Score-Punkte
AG_WORSE_SYNC = 15.0
AG_BAD_SCORE = 60.0                     # anhaltend schlechter Empfang: Score unter 60 ueber 3 h mit mindestens 24 Pruefungen
AG_BAD_H = 3
AG_BAD_N = 24
AG_STALE_S = 300                        # prepper-sdr meldet sich nicht (Zustandsdatei aelter)
AG_REQ_STALE_S = 120


def ag_lbl(g):
    if g == -1:
        return "Auto (welle-AGC)"
    if g == "agc":
        return "Auto (Notstufe der Gain-Leiter)"
    return "Stufe %s" % g


def ag_score(sync, snr, fic_pct):
    """Score 0..100 je Pruefung: kein Sync = 0; FIC-Fehler zaehlt am staerksten (6 Punkte je %, bis 12 %), SNR unter 12 dB 1,5 Punkte je dB (bis 10 dB)."""
    if not sync:
        return 0.0
    s = 100.0
    if isinstance(fic_pct, (int, float)) and not isinstance(fic_pct, bool):
        s -= AG_W_FIC * min(max(float(fic_pct), 0.0), AG_FIC_CAP)
    else:
        s -= 20.0
    if isinstance(snr, (int, float)) and not isinstance(snr, bool):
        s -= AG_W_SNR * min(max(AG_SNR_REF - float(snr), 0.0), AG_SNR_CAP)
    else:
        s -= 10.0
    return round(max(s, 0.0), 2)


def _agn(x):
    return float(x) if isinstance(x, (int, float)) and not isinstance(x, bool) else None


def _agmean(v):
    v = [x for x in v if x is not None]
    return round(sum(v) / len(v), 2) if v else None


def ag_stats(samples):
    """Je Stufe (Schluessel als Text, -1 = Auto): n, Sync, Score (Mittel ueber alle Messungen, ohne Sync = 0), FIC %, SNR dB (nur mit Sync)."""
    by = {}
    for x in samples or []:
        if isinstance(x, dict) and isinstance(x.get("g"), int) and not isinstance(x.get("g"), bool):
            by.setdefault(x["g"], []).append(x)
    out = {}
    for g, sm in sorted(by.items()):
        sy = [x for x in sm if x.get("sync")]
        fc = [None if _agn(x.get("fic")) is None else _agn(x.get("fic")) * 100.0 for x in sy]
        sn = [_agn(x.get("snr")) for x in sy]
        sc = [ag_score(bool(x.get("sync")), _agn(x.get("snr")), None if _agn(x.get("fic")) is None else _agn(x.get("fic")) * 100.0) for x in sm]
        hw = [_agn(x.get("hw")) for x in sm if _agn(x.get("hw")) is not None]
        row = {"n": len(sm), "sync_n": len(sy), "sync_pct": round(100.0 * len(sy) / len(sm), 1), "score": _agmean(sc), "fic": _agmean(fc), "snr": _agmean(sn)}
        if hw:
            row["hw_min"], row["hw_max"] = round(min(hw), 1), round(max(hw), 1)
        out[str(g)] = row
    return out


def ag_session(run, now=None):
    """Sitzungs-Zusammenfassung aus einem beendeten Gain-Test-Lauf (sdr_airtest.json)."""
    if not isinstance(run, dict):
        return None
    sm = [x for x in run.get("samples") or [] if isinstance(x, dict)]
    df = run.get("default") if isinstance(run.get("default"), dict) else {}
    return {"id": run.get("id"), "t": int(run.get("t_end") or now or time.time()), "t0": run.get("t0"), "profile": str(run.get("profile") or "t1"), "cur": df.get("cur"), "n": len(sm), "levels": ag_stats(sm)}


def _ag_lv(s, g):
    r = ((s or {}).get("levels") or {}).get(str(g))
    return r if isinstance(r, dict) and (r.get("n") or 0) >= AG_MIN_N and isinstance(r.get("score"), (int, float)) else None


def ag_levels_for(cur):
    """Stufen der Tagesmessung: die aktuelle Stufe und die naechsten Nachbarn im Raster (insgesamt AG_DAY_N)."""
    g = list(AG_GRID)
    if cur in g:
        i = g.index(cur)
        lo = max(0, min(i - 2, len(g) - AG_DAY_N))
        return g[lo:lo + AG_DAY_N]
    ref = cur if isinstance(cur, int) and not isinstance(cur, bool) and 0 <= cur <= 21 else 16
    near = sorted(g, key=lambda x: (abs(x - ref), x))[:AG_DAY_N - 1]
    return sorted(set(near) | ({ref} if isinstance(cur, int) else set()))


def ag_best_fixed(sessions, cur):
    """Bester fester Wert aus allen Sitzungen: hoechster mittlerer Score einer Stufe, die in mindestens 2 Sitzungen gueltig gemessen wurde und Sync >= 80 % hatte (Auto/-1 nie). Sonst die aktuelle Stufe (bzw. 16)."""
    best, bs = None, None
    ss = [s for s in sessions or [] if isinstance(s, dict)][-6:]
    lv = set()
    for s in ss:
        for k in (s.get("levels") or {}):
            try:
                if int(k) >= 0:
                    lv.add(int(k))
            except Exception:
                pass
    for g in sorted(lv):
        rs = [_ag_lv(s, g) for s in ss]
        rs = [r for r in rs if r]
        if len(rs) < 2 or _agmean([r.get("sync_pct") for r in rs]) < AG_SYNC_MIN:
            continue
        m = _agmean([r["score"] for r in rs])
        if bs is None or m > bs + 1e-9 or (abs(m - bs) <= 1e-9 and g == cur):
            best, bs = g, m
    if best is None:
        return cur if isinstance(cur, int) and not isinstance(cur, bool) else 16
    return best


def ag_decide(sessions, cur, now, changes, last_change_t=None):
    """Entscheidung aus den letzten AG_SESS_N Sitzungen. -> {"action": none|switch|lock, "to", "why", "cand"}.
    Wechsel nur bei klarem Vorteil: Zielstufe in mindestens 2 Sitzungen gemeinsam mit der aktuellen gemessen, in mindestens 2 davon um >= 6 Punkte besser, im Mittel >= 6 Punkte, Sync >= 80 %, neueste Sitzung widerspricht nicht.
    Mehr als 2 Wechsel in 48 h: keine weiteren Wechsel, Sperre mit bestem festem Wert."""
    out = {"action": "none", "to": None, "why": "", "cand": None}
    try:
        if not (isinstance(cur, int) and not isinstance(cur, bool)):
            out["why"] = "Notstufe der Gain-Leiter aktiv (%s) - keine Entscheidung" % ag_lbl(cur)
            return out
        ss = sorted([s for s in sessions or [] if isinstance(s, dict) and isinstance(s.get("t"), (int, float))], key=lambda s: s["t"])[-AG_SESS_N:]
        if len([s for s in ss if _ag_lv(s, cur)]) < 2:
            out["why"] = "zu wenig Messungen: mindestens 2 Sitzungen mit Stufe %s noetig (jetzt %d)" % (cur, len([s for s in ss if _ag_lv(s, cur)]))
            return out
        lv = set()
        for s in ss:
            for k in (s.get("levels") or {}):
                try:
                    if int(k) >= 0 and int(k) != cur:
                        lv.add(int(k))
                except Exception:
                    pass
        cands = []
        for g in sorted(lv):
            pr = [(s, _ag_lv(s, g), _ag_lv(s, cur)) for s in ss]
            pr = [(s, a, b) for s, a, b in pr if a and b]
            if len(pr) < 2:
                continue
            d = [a["score"] - b["score"] for s, a, b in pr]
            wins = len([x for x in d if x >= AG_MARGIN])
            md = round(sum(d) / len(d), 2)
            sy = _agmean([a.get("sync_pct") for s, a, b in pr])
            ok = wins >= 2 and md >= AG_MARGIN and d[-1] >= 0 and sy is not None and sy >= AG_SYNC_MIN
            cands.append({"g": g, "d": md, "wins": wins, "n": len(pr), "sync": sy, "ok": ok})
        okc = sorted([c for c in cands if c["ok"]], key=lambda c: (-c["d"], abs(c["g"] - cur)))
        if not okc:
            top = sorted(cands, key=lambda c: -c["d"])[:1]
            out["why"] = "kein klarer Vorteil (Stufe %s bleibt)%s" % (cur, (" - bester Kandidat Stufe %s: im Mittel %+.1f Punkte, %d von %d Sitzungen vorn" % (top[0]["g"], top[0]["d"], top[0]["wins"], top[0]["n"])) if top else "")
            return out
        c = okc[0]
        out["cand"] = c
        if isinstance(last_change_t, (int, float)) and now - last_change_t < AG_MIN_GAP_S:
            out["why"] = "Vorteil fuer Stufe %s erkannt, aber letzter Wechsel erst vor %d min (Mindestabstand %d h)" % (c["g"], (now - last_change_t) // 60, AG_MIN_GAP_S // 3600)
            return out
        n48 = len([t for t in changes or [] if isinstance(t, (int, float)) and 0 <= now - t <= AG_FLIP_S])
        if n48 >= AG_MAX_CHANGES:
            fx = ag_best_fixed(ss if len(ss) >= 2 else sessions, cur)
            out.update(action="lock", to=fx, why="mehr als %d Wechsel in 48 h (%d bisher, ein weiterer waere Stufe %s statt %s) - bester fester Wert Stufe %s" % (AG_MAX_CHANGES, n48, c["g"], cur, fx))
            return out
        out.update(action="switch", to=c["g"], why="Stufe %s im Mittel %+.1f Score-Punkte besser als Stufe %s (%d von %d Sitzungen mit Vorteil >= %d, Sync %s %%)" % (c["g"], c["d"], cur, c["wins"], c["n"], int(AG_MARGIN), c["sync"]))
    except Exception as e:
        out.update(action="none", to=None, why="Entscheidung nicht moeglich: %s" % str(e)[:80])
    return out


def ag_rows(base, t0, t1, windows=None):
    """Pruefungen 11D aus reception_log (je Zeitstempel eine): [(t, sync, snr, fic_pct)], ohne Testfenster (+-90 s). Nur lesen, wirft nie."""
    try:
        p = os.path.join(base, "lagezentrum.db")
        if db is None or not os.path.isfile(p):
            return []
        con = db.connect(p)
        try:
            if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='reception_log'").fetchone():
                return []
            rows = con.execute("SELECT timestamp, MAX(sync), AVG(snr), AVG(fic_rate) FROM reception_log WHERE channel='11D' AND timestamp>=? AND timestamp<? GROUP BY timestamp ORDER BY timestamp", (int(t0), int(t1))).fetchall()
        finally:
            con.close()
        win = [(float(a) - 90, float(b) + 90) for a, b in (windows or []) if isinstance(a, (int, float)) and isinstance(b, (int, float))]
        out = []
        for r in rows:
            if any(a <= r[0] <= b for a, b in win):
                continue
            out.append((int(r[0]), bool(r[1]), _agn(r[2]), None if _agn(r[3]) is None else _agn(r[3]) * 100.0))
        return out
    except Exception:
        return []


def ag_rows_score(rows):
    """Mittel ueber Pruefungen: n, Sync %, Score, FIC %, SNR dB. Keine Pruefung = None."""
    try:
        if not rows:
            return None
        sy = [r for r in rows if r[1]]
        return {"n": len(rows), "sync_pct": round(100.0 * len(sy) / len(rows), 1), "score": _agmean([ag_score(r[1], r[2], r[3]) for r in rows]),
                "fic": _agmean([r[3] for r in sy]), "snr": _agmean([r[2] for r in sy])}
    except Exception:
        return None


def ag_post_check(pre, post):
    """Empfang nach einem Wechsel gegen vorher: 'watch' (zu wenig Pruefungen), 'worse' oder 'ok'."""
    if not isinstance(post, dict) or (post.get("n") or 0) < AG_POST_MIN_N or post.get("score") is None:
        return "watch"
    if isinstance(pre, dict) and (pre.get("n") or 0) >= AG_PRE_MIN_N and pre.get("score") is not None:
        if post["score"] < pre["score"] - AG_WORSE or (post.get("sync_pct") or 0) < (pre.get("sync_pct") or 0) - AG_WORSE_SYNC:
            return "worse"
    elif post["score"] < 50.0:
        return "worse"
    return "ok" if (post.get("n") or 0) >= AG_POST_OK_N else "watch"


def ag_bad(rows):
    """Anhaltend schlechter Empfang: genug Pruefungen in den letzten 3 h und Score darunter."""
    r = ag_rows_score(rows)
    return bool(r and r["n"] >= AG_BAD_N and r["score"] is not None and r["score"] < AG_BAD_SCORE)


def ag_req_put(base, cmd, by="dashboard", now=None):
    """Anforderung auto | fest | measure fuer prepper-sdr als Datei (atomar). Aendert nichts selbst."""
    now = int(now or time.time())
    if cmd not in ("auto", "fest", "measure"):
        return {"ok": False, "error": "ungueltig"}
    fn = os.path.join(base, AG_REQ)
    tmp = fn + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps({"v": 1, "cmd": cmd, "t": now, "by": str(by)[:20]}, separators=(",", ":")))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, fn)
    return {"ok": True, "cmd": cmd, "t": now}


def at_req_put2(base, cmd, profile=None, by="dashboard", now=None):
    """Gain-Test start|stop wie at_req_put, mit Profil t2 (14/16/17/18 + Auto) oder t1 (12/19/21)."""
    now = int(now or time.time())
    if cmd not in ("start", "stop") or profile not in (None, "t1", "t2"):
        return {"ok": False, "error": "ungueltig"}
    fn = os.path.join(base, AT_REQ)
    tmp = fn + ".tmp"
    d = {"v": 1, "cmd": cmd, "t": now, "by": str(by)[:20]}
    if profile:
        d["profile"] = profile
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(d, separators=(",", ":")))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, fn)
    return {"ok": True, "cmd": cmd, "profile": profile, "t": now}


_ag_orig_at_view = at_view


def at_view(base, now=None):
    """wie bisher, dazu je Stufe Score und Beschriftung (Auto = -1) und eine Empfehlung nach Score (nur Anzeige)."""
    v = _ag_orig_at_view(base, now)
    try:
        d = at_load(base)
        sm = [x for x in d.get("samples") or [] if isinstance(x, dict)]
        st = ag_stats(sm)
        lv = [g for g in (d.get("levels") or v.get("levels") or []) if isinstance(g, int) and not isinstance(g, bool)]
        v["profile"] = str(d.get("profile") or "t1")
        v["score_rows"] = [dict({"g": g, "label": ag_lbl(g)}, **(st.get(str(g)) or {"n": 0, "sync_n": 0, "sync_pct": None, "score": None, "fic": None, "snr": None})) for g in lv]
        ok = [r for r in v["score_rows"] if r.get("n", 0) >= AT_MIN_N and r.get("score") is not None and (r.get("sync_pct") or 0) >= AT_SYNC_OK]
        if sm and ok and len([r for r in v["score_rows"] if r.get("n", 0) >= AT_MIN_N]) == len(v["score_rows"]):
            fx = [r for r in ok if r["g"] >= 0]
            top = sorted(ok, key=lambda r: (-r["score"], r["g"]))[0]
            topf = sorted(fx, key=lambda r: (-r["score"], r["g"]))[0] if fx else None
            txt = "Beste Stufe nach Score: %s (Score %s, Sync %s %%, FIC-Fehler %s %%, SNR %s dB)." % (top["label"], top["score"], top["sync_pct"], top["fic"], top["snr"])
            if top["g"] == -1 and topf:
                txt += " Auto wird nur angezeigt und nie automatisch übernommen; beste feste Stufe: %d (Score %s)." % (topf["g"], topf["score"])
            v["rec_score"] = {"level": top["g"], "fixed": topf["g"] if topf else None, "txt": txt}
        else:
            v["rec_score"] = None
    except Exception as e:
        v["score_rows"], v["rec_score"] = [], None
        v["ag_error"] = str(e)[:80]
    return v


def _ag_cur_from_state(base):
    """Aktuelle Stufe laut Gain-Leiter (broadcast_state.json dabgain, Airspy-Eintrag), nur lesen."""
    try:
        st = _load(os.path.join(base, "broadcast_state.json"), {}) or {}
        for sn, x in (st.get("dabgain") or {}).items():
            if isinstance(x, dict) and x.get("air"):
                return x.get("cur")
    except Exception:
        pass
    return None


def ag_view(base, now=None):
    """Zustand fuer /funk und /api/sdr/autogain: Modus, aktuelle Stufe, Grund des letzten Wechsels, Verlauf, Sperre, Tabelle ueber die letzten Sitzungen. Nur lesen, wirft nie."""
    now = int(now or time.time())
    out = {"ok": True, "t": now, "mode": "auto", "locked": False, "lock": None, "cur": None, "cur_txt": "unbekannt", "last_change": None, "history": [], "sessions": 0, "table": [], "cand": None,
           "next_txt": None, "msg": None, "stale": True, "engine": False, "txt": "Gain-Automatik: noch kein Zustand (prepper-sdr schreibt ihn nach dem Start)", "post": None, "changes_48h": 0}
    try:
        d = _load(os.path.join(base, AG_FILE), None)
        cur = _ag_cur_from_state(base)
        if not isinstance(d, dict):
            if cur is not None:
                out["cur"], out["cur_txt"] = cur, ag_lbl(cur)
            return out
        cur = d.get("cur") if d.get("cur") is not None else cur
        mode = "fest" if d.get("mode") == "fest" else "auto"
        lk = d.get("lock") if isinstance(d.get("lock"), dict) else None
        hist = [h for h in d.get("history") or [] if isinstance(h, dict)]
        ss = [s for s in d.get("sessions") or [] if isinstance(s, dict)]
        out.update(mode=mode, locked=bool(lk), lock=lk, cur=cur, cur_txt=ag_lbl(cur) if cur is not None else "unbekannt", history=list(reversed(hist[-10:])), sessions=len(ss),
                   last_change=(list(reversed([h for h in hist if h.get("kind") in ("auto", "lock", "revert", "manual", "ladder", "fehler")]))[:1] or [None])[0], msg=d.get("msg"),
                   post=d.get("post"), engine=True, stale=(now - int(d.get("t_upd") or 0) > AG_STALE_S), next_txt=d.get("next_txt"),
                   changes_48h=len([t for t in d.get("changes") or [] if isinstance(t, (int, float)) and 0 <= now - t <= AG_FLIP_S]))
        last = [s for s in sorted(ss, key=lambda s: s.get("t") or 0)][-AG_SESS_N:]
        lv = sorted({int(k) for s in last for k in (s.get("levels") or {}) if str(k).lstrip("-").isdigit()})
        for g in lv:
            rs = [_ag_lv(s, g) for s in last]
            rs = [r for r in rs if r]
            if rs:
                out["table"].append({"g": g, "label": ag_lbl(g), "sessions": len(rs), "score": _agmean([r["score"] for r in rs]), "sync_pct": _agmean([r.get("sync_pct") for r in rs]),
                                     "fic": _agmean([r.get("fic") for r in rs]), "snr": _agmean([r.get("snr") for r in rs]), "now": g == cur})
        dec = ag_decide(ss, cur, now, d.get("changes") or [], (d.get("changes") or [None])[-1] if d.get("changes") else None)
        out["cand"] = {"to": dec.get("to"), "action": dec.get("action"), "txt": dec.get("why")}
        if out["stale"]:
            out["txt"] = "Gain-Automatik: prepper-sdr meldet sich seit %d min nicht (%s laut letztem Stand)" % (max(0, (now - int(d.get("t_upd") or 0)) // 60), out["cur_txt"])
        elif lk:
            out["txt"] = "Gain-Automatik GESPERRT: fester Wert %s – %s. Auto bleibt aus, bis Du es hier wieder aktivierst." % (ag_lbl(lk.get("fixed")), lk.get("why") or "?")
        elif mode == "fest":
            out["txt"] = "Gain fest auf %s (Auto aus, manuell)." % out["cur_txt"]
        else:
            out["txt"] = "Gain-Automatik an: aktuell %s" % out["cur_txt"]
    except Exception as e:
        out.update(ok=False, error=str(e)[:120], txt="Gain-Automatik: Zustand nicht lesbar")
    return out


def selftest_autogain():
    import tempfile
    d = tempfile.mkdtemp(prefix="autogain-sm-")
    now = 1790000000
    # --- Score: FIC am staerksten, ohne Sync 0
    assert ag_score(False, 14.0, 0.0) == 0.0 and ag_score(True, 14.0, 0.0) == 100.0 and ag_score(True, 12.0, 1.0) == 94.0
    assert ag_score(True, 9.0, 1.96) > ag_score(True, 13.9, 5.07), (ag_score(True, 9.0, 1.96), ag_score(True, 13.9, 5.07))   # Messwerte: Stufe 12 (FIC 1,96 %) schlaegt Stufe 16 (FIC 5,07 %)
    assert ag_score(True, 14.0, 3.0) > ag_score(True, 8.0, 3.0)
    assert ag_score(True, None, None) == 70.0 and ag_score(True, 0.0, 99.0) == 100.0 - 72.0 - 15.0 and ag_score(True, "x", True) == 70.0
    # --- Statistik je Stufe, Auto = -1 mit Hardware-Stufe
    sm = []
    for i, (g, sy, snr, fic, hw) in enumerate([(14, 1, 12.0, 0.01, None), (14, 1, 12.0, 0.01, None), (-1, 1, 10.0, 0.02, 11.0), (-1, 1, 10.0, 0.02, 15.0), (16, 0, None, None, None), (16, 1, 14.0, 0.05, None)]):
        sm.append({"i": i, "g": g, "sync": bool(sy), "snr": snr, "fic": fic, "hw": hw})
    st = ag_stats(sm)
    assert st["14"]["score"] == 94.0 and st["14"]["fic"] == 1.0 and st["-1"]["hw_min"] == 11.0 and st["-1"]["hw_max"] == 15.0 and st["16"]["sync_pct"] == 50.0 and st["16"]["score"] == 35.0, st
    assert ag_lbl(-1) == "Auto (welle-AGC)" and ag_lbl(16) == "Stufe 16" and ag_lbl("agc").startswith("Auto (Notstufe")
    assert ag_levels_for(16) == [12, 14, 16, 17, 18] and ag_levels_for(12) == [12, 14, 16, 17, 18] and ag_levels_for(19) == [14, 16, 17, 18, 19] and 9 in ag_levels_for(9) and len(ag_levels_for(9)) == 5 and len(ag_levels_for("agc")) == 4 and 16 in ag_levels_for("agc")

    def sess(t, **sc):
        return {"t": t, "id": t, "profile": "day", "cur": 16, "levels": {str(g): {"n": 3, "sync_n": 3, "sync_pct": 100.0, "score": s, "fic": 1.0, "snr": 12.0} for g, s in sc.items()}}
    S = lambda *a: [sess(now + 86400 * i, **x) for i, x in enumerate(a)]
    # --- Entscheidung: klarer Vorteil ueber mehrere Sitzungen, sonst bleibt es
    r = ag_decide(S({"16": 70, "14": 85}), 16, now + 90000, [])
    assert r["action"] == "none" and "zu wenig Messungen" in r["why"], r                               # nur 1 Sitzung
    r = ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16, now + 200000, [])
    assert r["action"] == "switch" and r["to"] == 14 and "besser als Stufe 16" in r["why"], r
    r = ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 72}), 16, now + 200000, [])
    assert r["action"] == "none" and "kein klarer Vorteil" in r["why"], r                               # nur 1 von 2 Sitzungen deutlich
    r = ag_decide(S({"16": 70, "14": 85}, {"16": 80, "14": 78}), 16, now + 200000, [])
    assert r["action"] == "none", r                                                                      # neueste Sitzung widerspricht
    r = ag_decide(S({"16": 70, "17": 72}, {"16": 71, "17": 73}), 16, now + 200000, [])
    assert r["action"] == "none", r                                                                      # kein klarer Vorteil (< 6 Punkte)
    r = ag_decide(S({"16": 70, "14": 85, "-1": 99}, {"16": 71, "14": 84, "-1": 99}), 16, now + 200000, [])
    assert r["action"] == "switch" and r["to"] == 14, r                                                  # Auto (-1) wird nie gewaehlt
    lo = S({"16": 70, "14": 85}, {"16": 71, "14": 84}); lo[0]["levels"]["14"]["sync_pct"] = 60.0; lo[1]["levels"]["14"]["sync_pct"] = 60.0
    assert ag_decide(lo, 16, now + 200000, [])["action"] == "none"                                       # Sync < 80 % -> nie Ziel
    r = ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16, now + 200000, [], now + 200000 - 3600)
    assert r["action"] == "none" and "Mindestabstand" in r["why"], r
    r = ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), "agc", now + 200000, [])
    assert r["action"] == "none" and "Notstufe" in r["why"]
    # --- Flip-Flop: mehr als 2 Wechsel in 48 h -> Sperre mit bestem festem Wert
    ch = [now + 200000 - 3600 * 30, now + 200000 - 3600 * 20]
    r = ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16, now + 200000, ch)
    assert r["action"] == "lock" and r["to"] == 14 and "mehr als 2 Wechsel in 48 h" in r["why"], r
    r = ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16, now + 200000, [now + 200000 - 3600 * 60, now + 200000 - 3600 * 50])
    assert r["action"] == "switch", r                                                                     # Wechsel aelter als 48 h zaehlen nicht
    assert ag_best_fixed(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16) == 14 and ag_best_fixed(S({"16": 70, "14": 85}), 16) == 16 and ag_best_fixed([], "agc") == 16
    assert ag_best_fixed(S({"16": 70, "-1": 99}, {"16": 71, "-1": 99}), 16) == 16                         # Auto nie 'fester Wert'
    # --- Empfang nach Wechsel
    pre = {"n": 40, "score": 75.0, "sync_pct": 99.0}
    assert ag_post_check(pre, {"n": 5, "score": 10.0, "sync_pct": 0.0}) == "watch"
    assert ag_post_check(pre, {"n": 12, "score": 60.0, "sync_pct": 99.0}) == "worse" and ag_post_check(pre, {"n": 12, "score": 74.0, "sync_pct": 70.0}) == "worse"
    assert ag_post_check(pre, {"n": 20, "score": 80.0, "sync_pct": 99.0}) == "watch" and ag_post_check(pre, {"n": 40, "score": 80.0, "sync_pct": 99.0}) == "ok"
    assert ag_post_check(None, {"n": 12, "score": 40.0, "sync_pct": 99.0}) == "worse" and ag_post_check({"n": 3, "score": 99.0}, {"n": 40, "score": 55.0, "sync_pct": 99.0}) == "ok"
    assert ag_bad([(now + i, True, 12.0, 15.0) for i in range(30)]) is True and ag_bad([(now + i, True, 12.0, 1.0) for i in range(30)]) is False and ag_bad([(now, False, None, None)] * 5) is False and ag_bad([]) is False
    # --- Anforderungen nur als Datei
    assert ag_req_put(d, "auto", "dashboard", now)["ok"] and _load(os.path.join(d, AG_REQ))["cmd"] == "auto" and ag_req_put(d, "reboot")["ok"] is False and ag_req_put(d, "fest; rm")["ok"] is False
    assert at_req_put2(d, "start", "t2", "dashboard", now)["ok"] and _load(os.path.join(d, AT_REQ)) == {"v": 1, "cmd": "start", "t": now, "by": "dashboard", "profile": "t2"}
    assert at_req_put2(d, "start", "xx")["ok"] is False and at_req_put2(d, "stop", None, "dashboard", now + 1)["ok"] and "profile" not in _load(os.path.join(d, AT_REQ)) and not os.path.exists(os.path.join(d, AG_REQ + ".tmp"))
    # --- Sitzung aus Testlauf + Anzeige
    run = {"id": now, "t0": now, "t_end": now + 900, "profile": "t2", "default": {"cur": 16}, "samples": [dict(x, g=x["g"]) for x in sm]}
    ssn = ag_session(run)
    assert ssn["profile"] == "t2" and ssn["cur"] == 16 and ssn["n"] == 6 and ssn["levels"]["14"]["n"] == 2 and ag_session(None) is None
    v = ag_view(d, now)
    assert v["ok"] and v["engine"] is False and v["mode"] == "auto" and "noch kein Zustand" in v["txt"], v
    open(os.path.join(d, "broadcast_state.json"), "w").write(json.dumps({"dabgain": {"X": {"air": 1, "cur": 17}}}))
    assert ag_view(d, now)["cur"] == 17 and ag_view(d, now)["cur_txt"] == "Stufe 17"
    stt = {"v": 1, "mode": "auto", "cur": 14, "lock": None, "sessions": S({"16": 70, "14": 85}, {"16": 71, "14": 84}), "history": [{"t": now, "kind": "auto", "from": 16, "to": 14, "why": "Test"}], "changes": [now - 3600], "t_upd": now, "next_txt": "nächste Messung in der Nacht", "msg": None, "post": None}
    stt["sessions"][0]["t"], stt["sessions"][1]["t"] = now - 200000, now - 100000
    open(os.path.join(d, AG_FILE), "w").write(json.dumps(stt))
    v = ag_view(d, now + 10)
    assert v["ok"] and v["engine"] and not v["stale"] and v["cur"] == 14 and v["last_change"]["to"] == 14 and v["changes_48h"] == 1 and v["sessions"] == 2 and "Gain-Automatik an" in v["txt"] and "nächste Messung" in (v.get("next_txt") or ""), v
    assert [r["g"] for r in v["table"]] == [14, 16] and v["table"][0]["now"] is True and v["cand"]["action"] in ("none", "switch"), v["table"]
    stt["lock"] = {"t": now, "kind": "flipflop", "why": "mehr als 2 Wechsel in 48 h", "fixed": 14}
    open(os.path.join(d, AG_FILE), "w").write(json.dumps(stt))
    v = ag_view(d, now + 10)
    assert v["locked"] and "GESPERRT" in v["txt"] and "Stufe 14" in v["txt"] and "aktivierst" in v["txt"], v["txt"]
    stt["lock"], stt["mode"] = None, "fest"
    open(os.path.join(d, AG_FILE), "w").write(json.dumps(stt))
    assert "fest auf Stufe 14" in ag_view(d, now + 10)["txt"]
    assert ag_view(d, now + AG_STALE_S + 100)["stale"] is True and "meldet sich seit" in ag_view(d, now + AG_STALE_S + 100)["txt"]
    open(os.path.join(d, AG_FILE), "w").write("{kaputt")
    assert ag_view(d, now)["ok"] is True and ag_view("/nonexistent/x", now)["ok"] is True
    # --- Gain-Test-Anzeige mit Score und Auto
    pl = [g for _ in range(5) for g in AG_T2_LEVELS]
    smp = []
    for i, g in enumerate(pl):
        smp.append({"i": i, "g": g, "t": now + 60 * i, "sync": True, "snr": {14: 11.0, 16: 13.9, 17: 14.0, 18: 14.2, -1: 12.0}[g], "fic": {14: 0.01, 16: 0.0507, 17: 0.03, 18: 0.04, -1: 0.02}[g], "hw": 12.0 if g == -1 else None})
    open(os.path.join(d, AT_FILE), "w").write(json.dumps({"state": "done", "profile": "t2", "t0": now, "t_end": now + 1500, "t_upd": now + 1500, "default": {"cur": 16}, "levels": list(AG_T2_LEVELS), "plan": pl, "samples": smp, "windows": [[now, now + 1500]]}))
    v = at_view(d, now + 1600)
    rr = {r["g"]: r for r in v["score_rows"]}
    assert v["profile"] == "t2" and [r["label"] for r in v["score_rows"]] == ["Stufe 14", "Stufe 16", "Stufe 17", "Stufe 18", "Auto (welle-AGC)"] and rr[-1]["hw_max"] == 12.0, v["score_rows"]
    assert rr[14]["score"] > rr[16]["score"] and v["rec_score"]["level"] == 14 and v["rec_score"]["fixed"] == 14 and "Beste Stufe nach Score: Stufe 14" in v["rec_score"]["txt"], v["rec_score"]
    assert v["rec"] is not None and v["state"] == "done"                                                    # alte Felder bleiben
    smp2 = [dict(x, snr=14.0, fic=0.0 if x["g"] == -1 else 0.05) for x in smp]
    open(os.path.join(d, AT_FILE), "w").write(json.dumps({"state": "done", "profile": "t2", "levels": list(AG_T2_LEVELS), "plan": pl, "samples": smp2, "default": {"cur": 16}}))
    r2 = at_view(d, now + 1600)["rec_score"]
    assert r2["level"] == -1 and r2["fixed"] in (14, 16, 17, 18) and "nie automatisch übernommen" in r2["txt"], r2          # Auto vorn: nur Anzeige
    open(os.path.join(d, AT_FILE), "w").write(json.dumps({"state": "done", "levels": list(AG_T2_LEVELS), "plan": pl, "samples": smp2[:6], "default": {"cur": 16}}))
    assert at_view(d, now)["rec_score"] is None                                                             # zu wenig Messungen je Stufe
    open(os.path.join(d, AT_FILE), "w").write("{kaputt")
    assert at_view(d, now)["ok"] is True
    return "sdr_manager selftest autoGain ok (Score mit FIC am staerksten, Sitzungen, Entscheidung nur bei klarem Vorteil ueber mehrere Sitzungen, Auto nie gewaehlt, Flip-Flop-Sperre >2 Wechsel/48 h, Empfang nach Wechsel, Anforderungen nur als Datei, Anzeige-Zustand kaputt/alt/gesperrt wirft nie, Gain-Test-Tabelle mit Score und Auto)"
ASM_EOF
EXPECT_ASD="ad9670d24ee084ac78d8289c034ebe1caebe676630c3cd0ae46284c108f6c2da"
cat > "$W/ag_sdr_block.py" << 'ASD_EOF'
# ===== autoGain: Gain-Automatik Airspy 11D - misst taeglich (Nachtfenster) und nach anhaltend schlechtem Empfang mit der airTest-Maschine (Profile day/t2, nur Pruefbloecke der 11D, Standard-Gain gilt zwischendurch), waehlt die beste feste Stufe nur bei klarem Vorteil ueber mehrere Sitzungen, wechselt nur ohne Alarm/ASA/PTY 31/Antennentest/Meteor, sperrt bei mehr als 2 Wechseln in 48 h oder schlechterem Empfang nach einem Wechsel (bis Frank Auto wieder einschaltet), Rueckfall bei Fehlern Stufe 16; Auto (welle-AGC) wird nur gemessen und angezeigt, nie automatisch gewaehlt =====
AG_FILE = "sdr_autogain.json"
AG_REQ = "sdr_autogain_req.json"
AG_TICK_S = 20                      # Takt der Automatik (Planer-Schritte laufen oefter)
AG_CHECK_S = 300                    # Empfangspruefungen (schlechter Empfang, Empfang nach Wechsel) alle 5 min
AG_RETRY_S = 1800                   # nach abgelehnter/abgebrochener Messung fruehestens nach 30 min neu
AG_NIGHT = (1, 5)                   # Nachtfenster der Tagesmessung (lokale Stunden 1:00-4:59)
AG_DAILY_S = 24 * 3600
AG_ANYTIME_S = 36 * 3600            # ohne Nachtfenster spaetestens nach 36 h
AG_BAD_GAP_S = 6 * 3600             # Messung nach schlechtem Empfang fruehestens 6 h nach der letzten
AG_PEND_MAX_S = 6 * 3600            # Wechsel-Entscheidung, die so lange nicht freigegeben wird, verfaellt
AG_ERR_MAX = 3                      # Fehler in Folge -> Sperre + Rueckfall Stufe 16
AG_HIST_N = 30
AG_SESS_KEEP = 20
AG_DAY_ROUNDS = 3
AG_T2_LEVELS = (14, 16, 17, 18, -1)
AG_T2_ROUNDS = 5
AG_LIMITS = {"t1": 40 * 60, "t2": 70 * 60, "day": 45 * 60}
AG_FALLBACK = 16
_AG = {"on": False, "boot": False, "profile": None, "levels": None, "req_t": 0.0, "t_next": 0.0, "t_chk": 0.0, "err_n": 0, "err_t": 0.0, "st": None, "mgr": None, "msg_t": 0.0}
AIR2_SOAPY_GAIN[-1] = -1            # Auto: welle-cli -g -1 (auch ueber SoapySDR = Software-AGC)
_ag_orig_air_gain_state = _air_gain_state
_ag_orig_at_tick = _at_tick
_ag_orig_at_finish = _at_finish
_ag_orig_at_req_take = _at_req_take
_ag_orig_at_record = _at_record


def _ag_err(what, e):
    if time.time() - _AG["err_t"] > 300:
        _AG["err_t"] = time.time()
        print("autoGain %s: %s" % (what, e), flush=True)


def _ag_lbl(g):
    return "Auto (welle-AGC)" if g == -1 else ("Auto (Notstufe der Gain-Leiter)" if g == "agc" else "Stufe %s" % g)


def _air_gain_state(self):
    """wie bisher, dazu jede ganze Stufe 0..21 als gueltiger Standard-Gain (die Automatik waehlt 12..19); Gain-Leiter bei Sync-Verlust bleibt: Stufe ausserhalb der Leiter -> Stufe 16 -> weiter wie bisher."""
    st = _dg_state(self)
    cur = st.get("cur")
    if st.get("air") and cur not in AIR_LADDER and isinstance(cur, int) and not isinstance(cur, bool) and 0 <= cur <= 21:
        return st
    return _ag_orig_air_gain_state(self)


def _ag_m():
    """sdr_manager.py (Datenschicht der Automatik); fehlt sie, bleibt die Automatik aus."""
    if _AG["mgr"] is None:
        import sdr_manager as _m
        for k in ("ag_decide", "ag_stats", "ag_session", "ag_rows", "ag_rows_score", "ag_post_check", "ag_bad", "ag_levels_for", "ag_best_fixed"):
            if not hasattr(_m, k):
                raise RuntimeError("sdr_manager.py ohne autoGain")
        _AG["mgr"] = _m
    return _AG["mgr"]


def _ag_new(now):
    return {"v": 1, "mode": "auto", "cur": None, "cur_seen": None, "lock": None, "sessions": [], "history": [], "changes": [], "post": None, "pending": None, "last_session_t": None,
            "started": int(now), "windows": [], "msg": None, "next_txt": None, "t_upd": 0, "retry_t": 0, "fault": False}


def _ag_load(base, now):
    """Zustand lesen -> (Zustand, Fehlertext oder None). Fehlt die Datei: neuer Zustand. Unlesbar: neuer Zustand + Fehlertext (-> Rueckfall Stufe 16)."""
    fn = p(AG_FILE, base)
    if not os.path.exists(fn):
        return _ag_new(now), None
    try:
        with open(fn, encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict) or d.get("v") != 1:
            raise ValueError("Format")
        st = _ag_new(now)
        st.update(d)
        for k in ("sessions", "history", "changes", "windows"):
            if not isinstance(st.get(k), list):
                raise ValueError(k)
        if st.get("mode") not in ("auto", "fest"):
            st["mode"] = "fest"
        return st, None
    except Exception as e:
        return _ag_new(now), "Zustandsdatei unlesbar (%s)" % str(e)[:60]


def _ag_save(base, st, now):
    st["t_upd"] = int(now)
    fn = p(AG_FILE, base)
    tmp = fn + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(st, ensure_ascii=False, separators=(",", ":")))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, fn)


def _ag_hist(st, now, kind, frm, to, why):
    st["history"] = (list(st.get("history") or []) + [{"t": int(now), "kind": kind, "from": frm, "to": to, "why": str(why)[:240]}])[-AG_HIST_N:]


def _ag_msg(st, now, txt):
    st["msg"] = {"t": int(now), "txt": str(txt)[:300]}


def _ag_blocked(pl, now):
    """Grund, warum jetzt kein Gain-Wechsel/keine Messung stattfinden darf (Alarm, ASA-Warnung, PTY 31, Antennentest, Meteor, Uebernahme, USB-Neuverbindung, laufende Messung), sonst None. Pruef-Fehler = gesperrt."""
    try:
        if _AT["run"] is not None or _at_chk_live(now):
            return "Gain-Test/Messung läuft"
        b = _wd_block(pl, now, cfg_serial(pl.cfg), None)
        if b:
            return b
        if _WD.get("busy"):
            return "USB-Neuverbindung läuft"
        return None
    except Exception as e:
        return "Sperr-Prüfung fehlgeschlagen (%s)" % str(e)[:60]


def _ag_set_gain(pl, st, new, now, kind, why, count):
    """Standard-Gain der Gain-Leiter setzen (wirkt mit dem naechsten Pruefblock = welle-cli-Neustart mit -g neu). count: zaehlt fuer die Flip-Flop-Regel (nur Wechsel der Automatik)."""
    gs = _air_gain_state(pl)
    old = gs.get("cur")
    if old == new:
        st["cur"] = st["cur_seen"] = new
        return False
    gs.update(cur=new, ok=None, ok_t=None, fail_n=0, tried=[], t_change=int(now))
    st["cur"] = st["cur_seen"] = new
    _ag_hist(st, now, kind, old, new, why)
    if count:
        st["changes"] = (list(st.get("changes") or []) + [int(now)])[-10:]
    pl.log("autoGain: Gain %s -> %s (%s): %s - wirkt mit dem naechsten 11D-Pruefblock (welle-cli startet neu)" % (_ag_lbl(old), _ag_lbl(new), kind, why))
    return True


def _ag_lock(st, now, kind, why, fixed):
    st["lock"] = {"t": int(now), "kind": kind, "why": str(why)[:240], "fixed": fixed}
    st["pending"] = {"to": fixed, "kind": "lock" if kind == "flipflop" else "revert", "why": str(why)[:240], "t": int(now)}


def _ag_fault(pl, now, why):
    """Fehler in der Logik: Automatik aus, fester Wert Stufe 16 (Rueckfall), bis Frank Auto wieder einschaltet."""
    st = _AG["st"] if isinstance(_AG["st"], dict) else _ag_new(now)
    _AG["st"] = st
    st["mode"], st["fault"] = "fest", True
    _ag_lock(st, now, "fehler", "Fehler in der Gain-Logik (%s) - Rueckfall auf Stufe %d" % (str(why)[:100], AG_FALLBACK), AG_FALLBACK)
    _ag_hist(st, now, "fehler", st.get("cur"), AG_FALLBACK, st["lock"]["why"])
    _AG["err_n"] = 0
    pl.log("autoGain: %s" % st["lock"]["why"])
    try:
        _ag_save(pl.base, st, now)
    except Exception as e:
        _ag_err("speichern", e)


def _ag_start(pl, now):
    """Gain-Test/Messung starten (ersetzt airTest-Start): Profil t1 (12/19/21 wie bisher), t2 (14/16/17/18 + Auto, je 5 Runden) oder day (Tagesmessung: aktuelle Stufe + Nachbarn, je 3 Runden). Der gespeicherte Standard-Gain bleibt unveraendert."""
    prof, lv = _AG["profile"] or "t1", _AG["levels"]
    _AG["profile"] = _AG["levels"] = None
    if prof == "day":
        levels, rounds = tuple(int(g) for g in (lv or (AG_FALLBACK,))), AG_DAY_ROUNDS
    elif prof == "t2":
        levels, rounds = AG_T2_LEVELS, AG_T2_ROUNDS
    else:
        prof, levels, rounds = "t1", AT_LEVELS, AT_ROUNDS
    limit = AG_LIMITS[prof] if prof != "t1" else AT_LIMIT_S
    d0 = _at_load(pl.base)
    why = _at_refuse(pl, now)
    if why:
        d0["msg"] = {"t": int(now), "txt": "Start abgelehnt: %s" % why}
        _at_save(pl.base, d0, now)
        pl.log("airTest: Start abgelehnt - %s" % why)
        return False
    gs = _air_gain_state(pl)
    plan = [g for _ in range(rounds) for g in levels]
    run = {"v": 1, "state": "running", "id": int(now), "t0": int(now), "t_end": None, "deadline": int(now + limit), "levels": list(levels), "rounds": rounds, "profile": prof,
           "plan": plan, "i": 0, "tries": 0, "default": {"cur": gs.get("cur"), "ok": gs.get("ok"), "fail_n": gs.get("fail_n"), "tried": list(gs.get("tried") or [])},
           "samples": [], "why": None, "msg": None, "windows": list(d0.get("windows") or [])[-4:]}
    _AT["run"] = run
    _at_save(pl.base, run, now)
    pl.log("airTest: gestartet (%s) - Airspy 11D, Stufen %s wechselnd je %d Runden (%d Messungen à ca. 60 s), gespeicherter Standard-Gain %s bleibt unveraendert, Zeitlimit %d min" % (
        {"t1": "Gain-Test 1", "t2": "Gain-Test 2", "day": "Tagesmessung der Gain-Automatik"}[prof], "/".join("Auto" if g == -1 else str(g) for g in levels), rounds, len(plan), _ag_lbl(run["default"]["cur"]), limit // 60))
    return True


_at_start = _ag_start


def _at_req_take(base, now):
    """wie bisher; bei 'start' merkt sich das Profil (t1/t2) aus der Anforderungsdatei fuer den Start."""
    cmd = _ag_orig_at_req_take(base, now)
    if cmd == "start":
        d = load_json(p(AT_REQ, base), None)
        pr = d.get("profile") if isinstance(d, dict) else None
        _AG["profile"], _AG["levels"] = (pr if pr in ("t1", "t2") else None), None
    return cmd


def _at_record(pl, chk, ran, now):
    """wie bisher; bei Auto (-1) zusaetzlich die von welle-cli gemeldete Hardware-Stufe der Messung."""
    run = _AT["run"]
    n0 = len(run.get("samples") or []) if isinstance(run, dict) else 0
    _ag_orig_at_record(pl, chk, ran, now)
    try:
        run = _AT["run"]
        if isinstance(run, dict) and chk.get("g") == -1 and len(run.get("samples") or []) > n0:
            dm = ((pl.sbc.d.get("dab") or {}).get("11D") or {}).get("demod")
            hw = dm.get("hw_gain") if isinstance(dm, dict) else None
            if isinstance(hw, (int, float)) and not isinstance(hw, bool):
                run["samples"][-1]["hw"] = round(float(hw), 1)
                _at_save(pl.base, run, now)
    except Exception as ex:
        _ag_err("Auto-Stufe", ex)


def _ag_on_finish(pl, run, state, why, now):
    """Beendete Messung: Fenster merken (nicht in die Empfangsstatistik), Sitzung speichern, bei Auto ohne Sperre entscheiden."""
    if not _AG["on"] or not isinstance(_AG["st"], dict):
        return
    st, prof = _AG["st"], str(run.get("profile") or "t1")
    st["windows"] = (list(st.get("windows") or []) + [[run.get("t0"), int(now)]])[-30:]
    if state == "done" and prof in ("t2", "day"):
        m = _ag_m()
        s = m.ag_session(run, now)
        if s and s.get("n"):
            st["sessions"] = (list(st.get("sessions") or []) + [s])[-AG_SESS_KEEP:]
            st["last_session_t"] = int(now)
            pl.log("autoGain: Sitzung gespeichert (%s, %d Messungen)" % (prof, s["n"]))
            if st.get("mode") == "auto" and not st.get("lock") and not st.get("fault"):
                dec = m.ag_decide(st["sessions"], _air_gain_state(pl).get("cur"), now, st.get("changes") or [], (st.get("changes") or [None])[-1])
                _ag_msg(st, now, "Entscheidung: " + dec["why"])
                pl.log("autoGain: Entscheidung %s - %s" % (dec["action"], dec["why"]))
                if dec["action"] == "switch":
                    st["pending"] = {"to": dec["to"], "kind": "auto", "why": dec["why"], "t": int(now)}
                elif dec["action"] == "lock":
                    _ag_lock(st, now, "flipflop", dec["why"], dec["to"])
                    _ag_hist(st, now, "lock", st.get("cur"), dec["to"], dec["why"])
            else:
                _ag_msg(st, now, "Messung gespeichert (Auto aus oder gesperrt: keine Entscheidung)")
    elif state == "aborted" and prof == "day":
        st["retry_t"] = int(now + AG_RETRY_S)
        _ag_msg(st, now, "Tagesmessung abgebrochen: %s - neuer Versuch fruehestens in %d min" % (why or "?", AG_RETRY_S // 60))
    elif state == "done":
        _ag_msg(st, now, "Gain-Test fertig (%d Messungen) - Anzeige, keine Aenderung" % len(run.get("samples") or []))
    _ag_save(pl.base, st, now)


def _at_finish(pl, run, state, why, now):
    _ag_orig_at_finish(pl, run, state, why, now)
    try:
        _ag_on_finish(pl, run, state, why, now)
    except Exception as ex:
        _ag_err("Sitzung", ex)
        _AG["err_n"] += 1


def _ag_session_start(pl, st, now, reason):
    m = _ag_m()
    cur = _air_gain_state(pl).get("cur")
    _AG["profile"], _AG["levels"] = "day", m.ag_levels_for(cur)
    ok = _at_start(pl, now)
    if ok:
        _ag_msg(st, now, "Tagesmessung gestartet (%s): Stufen %s" % (reason, "/".join(str(g) for g in (_AT["run"] or {}).get("levels") or [])))
    else:
        mm = (_at_load(pl.base).get("msg") or {}).get("txt") or "abgelehnt"
        st["retry_t"] = int(now + AG_RETRY_S)
        _ag_msg(st, now, "Tagesmessung nicht gestartet (%s): %s - neuer Versuch fruehestens in %d min" % (reason, mm, AG_RETRY_S // 60))
    return ok


def _ag_due(pl, st, now, m):
    """Grund fuer eine Messung jetzt oder None. Nur bei Auto ohne Sperre, ohne offene Entscheidung, nicht kurz nach einem Wechsel."""
    if st.get("mode") != "auto" or st.get("lock") or st.get("fault") or st.get("pending") or _AT["run"] is not None or now < float(st.get("retry_t") or 0):
        return None
    po = st.get("post")
    if isinstance(po, dict) and po.get("status") == "watch" and now - po.get("t", 0) < 6 * 3600:
        return None
    last = st.get("last_session_t")
    ref = last if isinstance(last, (int, float)) else st.get("started", now)
    night = AG_NIGHT[0] <= time.localtime(now).tm_hour < AG_NIGHT[1]
    age = now - ref
    if last is None and night and age >= 3600:
        return "erste Messung im Nachtfenster"
    if last is not None and age >= AG_DAILY_S and night:
        return "täglich im Nachtfenster"
    if age >= AG_ANYTIME_S:
        return "seit über 36 h keine Messung"
    if age >= AG_BAD_GAP_S:
        rows = m.ag_rows(pl.base, now - 3 * 3600, now + 1, st.get("windows"))
        if m.ag_bad(rows):
            sc = m.ag_rows_score(rows)
            return "anhaltend schlechter Empfang (Score %s über 3 h, %d Prüfungen)" % (sc["score"], sc["n"])
    return None


def _ag_next_txt(st, now):
    if st.get("lock") or st.get("mode") != "auto" or st.get("fault"):
        return None
    pd = st.get("pending")
    if isinstance(pd, dict):
        return "Wechsel auf %s wartet auf Freigabe (kein Alarm/ASA/PTY 31/Antennentest/Meteor)" % _ag_lbl(pd.get("to"))
    if _AT["run"] is not None:
        return "Messung läuft"
    last = st.get("last_session_t")
    ref = last if isinstance(last, (int, float)) else st.get("started", now)
    return "nächste Messung im Nachtfenster %02d–%02d Uhr (frühestens %s)" % (AG_NIGHT[0], AG_NIGHT[1], time.strftime("%d.%m. %H:%M", time.localtime(ref + (AG_DAILY_S if last else 3600))))


def _ag_req(pl, st, now):
    d = load_json(p(AG_REQ, pl.base), None)
    if not isinstance(d, dict):
        return False
    t = d.get("t")
    if not isinstance(t, (int, float)) or isinstance(t, bool) or t <= _AG["req_t"]:
        return False
    _AG["req_t"] = float(t)
    cmd = d.get("cmd")
    if now - t > AG_REQ_STALE_S_AG or cmd not in ("auto", "fest", "measure"):
        return False
    cur = _air_gain_state(pl).get("cur")
    if cmd == "auto":
        st.update(mode="auto", lock=None, pending=None, fault=False, changes=[], retry_t=0)
        if isinstance(st.get("post"), dict) and st["post"].get("status") == "watch":
            st["post"]["status"] = "ok"
        _AG["err_n"] = 0
        _ag_hist(st, now, "manual", cur, cur, "Auto wieder aktiviert (Knopf auf /funk) - Sperre und Wechsel-Zaehler zurueckgesetzt")
        _ag_msg(st, now, "Auto aktiviert (Knopf)")
        pl.log("autoGain: Auto aktiviert (Knopf) - Sperre aufgehoben, Gain %s" % _ag_lbl(cur))
    elif cmd == "fest":
        st.update(mode="fest", pending=None)
        _ag_hist(st, now, "manual", cur, cur, "Auto aus (Knopf auf /funk) - Gain bleibt fest auf %s" % _ag_lbl(cur))
        _ag_msg(st, now, "Auto aus (Knopf), Gain fest")
        pl.log("autoGain: Auto aus (Knopf) - Gain fest %s" % _ag_lbl(cur))
    else:
        _ag_session_start(pl, st, now, "Knopf Jetzt messen")
    return True


AG_REQ_STALE_S_AG = 120


def _ag_apply_pending(pl, st, now):
    pd = st.get("pending")
    if not isinstance(pd, dict):
        return False
    if pd.get("kind") == "auto" and now - pd.get("t", now) > AG_PEND_MAX_S:
        st["pending"] = None
        _ag_msg(st, now, "Wechsel auf %s verfallen (nicht freigegeben, Entscheidung veraltet)" % _ag_lbl(pd.get("to")))
        return True
    b = _ag_blocked(pl, now)
    if b:
        if now - _AG["msg_t"] > 600:
            _AG["msg_t"] = now
            _ag_msg(st, now, "Wechsel auf %s wartet: %s" % (_ag_lbl(pd.get("to")), b))
            pl.log("autoGain: Wechsel auf %s wartet - %s" % (_ag_lbl(pd.get("to")), b))
        return False
    kind, to = pd.get("kind"), pd.get("to")
    st["pending"] = None
    if not (isinstance(to, int) and not isinstance(to, bool) and 0 <= to <= 21):
        return True
    cur = _air_gain_state(pl).get("cur")
    if _ag_set_gain(pl, st, to, now, {"auto": "auto", "lock": "lock", "revert": "revert"}.get(kind, "auto"), pd.get("why") or "", kind == "auto"):
        if kind == "auto":
            try:
                m = _ag_m()
                pre = m.ag_rows_score(m.ag_rows(pl.base, now - 24 * 3600, now, st.get("windows")))
            except Exception as ex:
                pre = None
                _ag_err("Vorher-Empfang", ex)
            st["post"] = {"t": int(now), "from": cur, "to": to, "pre": pre, "post": None, "status": "watch"}
        _ag_msg(st, now, "Gain %s -> %s: %s" % (_ag_lbl(cur), _ag_lbl(to), pd.get("why") or ""))
    return True


def _ag_post(pl, st, now, m):
    """Empfang nach einem Wechsel gegen vorher; schlechter -> zurueck auf den alten Wert und Sperre."""
    po = st.get("post")
    if not (isinstance(po, dict) and po.get("status") == "watch") or st.get("pending"):
        return False
    sc = m.ag_rows_score(m.ag_rows(pl.base, po["t"] + 600, now + 1, st.get("windows")))
    po["post"] = sc
    res = m.ag_post_check(po.get("pre"), sc)
    if res == "worse":
        po["status"] = "worse"
        why = "schlechterer Empfang nach dem Wechsel auf %s: Score %s statt %s (%d Prüfungen), Sync %s %% statt %s %% - zurück auf %s" % (
            _ag_lbl(po.get("to")), sc.get("score"), (po.get("pre") or {}).get("score"), sc.get("n"), sc.get("sync_pct"), (po.get("pre") or {}).get("sync_pct"), _ag_lbl(po.get("from")))
        _ag_lock(st, now, "worse", why, po.get("from"))
        _ag_hist(st, now, "lock", po.get("to"), po.get("from"), why)
        _ag_msg(st, now, "GESPERRT: " + why)
        pl.log("autoGain: %s" % why)
        return True
    if res == "ok":
        po["status"] = "ok"
        _ag_msg(st, now, "Empfang nach dem Wechsel auf %s geprueft: Score %s (vorher %s) - ok" % (_ag_lbl(po.get("to")), sc.get("score"), (po.get("pre") or {}).get("score")))
        pl.log("autoGain: Empfang nach Wechsel auf %s ok (Score %s, vorher %s)" % (_ag_lbl(po.get("to")), sc.get("score"), (po.get("pre") or {}).get("score")))
        return True
    return True


def _ag_run(pl, now):
    if not _AG["boot"]:
        _AG["boot"] = True
        st, err = _ag_load(pl.base, now)
        _AG["st"] = st
        d = load_json(p(AG_REQ, pl.base), None)
        if isinstance(d, dict) and isinstance(d.get("t"), (int, float)) and not isinstance(d.get("t"), bool):
            _AG["req_t"] = max(_AG["req_t"], float(d["t"]))          # Altlast aus der Anforderungsdatei nie ausfuehren
        gs0 = _air_gain_state(pl)
        if isinstance(st.get("cur"), int) and st["cur"] != gs0.get("cur") and not err:
            _ag_hist(st, now, "ladder", st["cur"], gs0.get("cur"), "nach dem Dienststart steht der Gain auf %s (zuletzt gespeichert: %s)" % (_ag_lbl(gs0.get("cur")), _ag_lbl(st["cur"])))
        st["cur"] = st["cur_seen"] = gs0.get("cur")
        if err:
            _ag_fault(pl, now, err)
        else:
            pl.log("autoGain: bereit - Modus %s%s, Gain %s, %d Sitzungen gespeichert; Messung taeglich im Nachtfenster %02d-%02d Uhr und nach anhaltend schlechtem Empfang, Wechsel nur bei klarem Vorteil, Sperre bei mehr als 2 Wechseln in 48 h oder schlechterem Empfang nach Wechsel, Rueckfall Stufe %d" % (
                st["mode"], " (gesperrt)" if st.get("lock") else "", _ag_lbl(st["cur"]), len(st["sessions"]), AG_NIGHT[0], AG_NIGHT[1], AG_FALLBACK))
        _ag_save(pl.base, st, now)
    st = _AG["st"]
    gs = _air_gain_state(pl)
    if st.get("cur_seen") is None:
        st["cur"] = st["cur_seen"] = gs.get("cur")
    elif gs.get("cur") != st["cur_seen"]:
        _ag_hist(st, now, "ladder", st["cur_seen"], gs.get("cur"), "Gain-Leiter: kein Sync auf %s - naechste Stufe" % _ag_lbl(st["cur_seen"]))
        pl.log("autoGain: Gain-Leiter hat von %s auf %s gewechselt (kein Sync)" % (_ag_lbl(st["cur_seen"]), _ag_lbl(gs.get("cur"))))
        st["cur"] = st["cur_seen"] = gs.get("cur")
    dirty = _ag_req(pl, st, now)
    dirty = _ag_apply_pending(pl, st, now) or dirty
    if now - _AG["t_chk"] >= AG_CHECK_S:
        _AG["t_chk"] = now
        m = _ag_m()
        dirty = _ag_post(pl, st, now, m) or dirty
        why = _ag_due(pl, st, now, m)
        if why:
            _ag_session_start(pl, st, now, why)
            dirty = True
    nt = _ag_next_txt(st, now)
    if nt != st.get("next_txt"):
        st["next_txt"], dirty = nt, True
    if dirty or now - int(st.get("t_upd") or 0) >= 60:
        _ag_save(pl.base, st, now)


def _ag_tick(pl, now):
    if not _AG["on"] or not _at_is_air(pl):
        return
    a = _air_pl(pl)
    if not a or a.get("role") != "11D" or now < _AG["t_next"]:
        return
    _AG["t_next"] = now + AG_TICK_S
    try:
        _ag_run(pl, now)
        _AG["err_n"] = 0
    except Exception as ex:
        _AG["err_n"] += 1
        _ag_err("Tick", ex)
        if _AG["err_n"] >= AG_ERR_MAX:
            _ag_fault(pl, now, ex)


def _at_tick(pl, now):
    _ag_orig_at_tick(pl, now)
    try:
        _ag_tick(pl, now)
    except Exception as ex:
        _ag_err("Tick (aussen)", ex)


def _AG_START(base):
    _AG["on"] = True
    print("autoGain: Automatik aktiv (Zustand %s)" % p(AG_FILE, base), flush=True)


def selftest_autogain():
    import tempfile
    import sdr_manager as M
    tmp = tempfile.mkdtemp(prefix="autogain-sdr-")
    d0 = time.localtime(time.time() + 3 * 86400)                                                        # Testzeit liegt vor der echten Uhr nie zurueck (deadline-Pruefung nutzt die echte Uhr)
    d1 = time.localtime(time.time() + 4 * 86400)
    t_day = time.mktime((d0.tm_year, d0.tm_mon, d0.tm_mday, 14, 10, 0, 0, 0, -1))
    t_night = time.mktime((d1.tm_year, d1.tm_mon, d1.tm_mday, 2, 10, 0, 0, 0, -1))
    logs = []

    class _Sbc:
        def __init__(self):
            self.d = {"fm": {}, "warn": [], "dab": {}}

    class _Pl:
        def __init__(self):
            self.base = tmp
            self.cfg = {"dev_kind": "airspy", "air_fe": "airspy", "air_gain": None, "serial": "44A42E4F2A5B1C83"}
            self.sbc = _Sbc()
            self.lock = threading.Lock()
            self.dev_sn = "TESTAIR"
            self.st_pause = False
            self.pmeteor = None
            self.since = t_night
            self.air = {"on": True, "role": "11D"}

        def log(self, *a):
            logs.append(" ".join(str(x) for x in a))

        def dab_list(self):
            return ["11D"]

    pl = _Pl()
    G = globals()
    sv_at = {k: _AT[k] for k in _AT}
    sv_ag = {k: _AG[k] for k in _AG}
    sv_wd = {k: _WD.get(k) for k in ("d", "base", "busy")}
    keep = {k: G[k] for k in ("_at_orig_cmd_dab", "_at_orig_sub_done", "_at_orig_wd_check", "_at_orig_dabgain_step", "_wd_block", "_air_pl")}
    base_cmd = [["/usr/bin/welle-cli", "-c", "11D", "-C", "1", "-w", "7979", "-F", "airspy", "-g", "16"]]
    blk = [None]
    try:
        G["_air_pl"] = lambda x: x.__dict__.get("air") if x.__dict__.get("air", {}).get("on") else None
        _AT.update(run=None, chk=None, boot=False, req_t=0.0, dropped=0)
        _AG.update(on=True, boot=False, profile=None, levels=None, req_t=0.0, t_next=0.0, t_chk=0.0, err_n=0, st=None, mgr=None, msg_t=0.0)
        _WD["d"], _WD["base"], _WD["busy"] = _wd_new(), tmp, None
        _WD["d"]["sticks"]["44A42E4F2A5B1C83"] = {"last_ok": t_night - 30, "inc": None}
        G["_at_orig_cmd_dab"] = lambda self, ch: [list(base_cmd[0])]
        G["_at_orig_wd_check"] = lambda pl_, src, ok, now, ch=None, why=None: "orig"
        G["_at_orig_dabgain_step"] = lambda st, sync, now, ch: ("step", sync)
        G["_wd_block"] = lambda pl_, now, sn, act=None: blk[0]
        gs = _air_gain_state(pl)
        assert gs["cur"] == 16
        assert AG_DAY_ROUNDS == M.AG_DAY_ROUNDS and AG_T2_LEVELS == M.AG_T2_LEVELS and AG_T2_ROUNDS == M.AG_T2_ROUNDS and AG_FILE == M.AG_FILE and AG_REQ == M.AG_REQ and AG_FALLBACK == 16 and AIR2_SOAPY_GAIN[-1] == -1
        gs["cur"] = 17
        assert _air_gain_state(pl)["cur"] == 17 and _air_gain_state(pl) is gs                           # ganze Stufen gelten jetzt (vorher: Reset auf 16)
        gs["cur"] = 99
        assert _air_gain_state(pl)["cur"] == 16                                                          # ausserhalb 0..21: wie bisher zurueck auf Standard
        gs = _air_gain_state(pl)
        gs["cur"] = "agc"
        assert _air_gain_state(pl)["cur"] == "agc"
        gs["cur"] = 16
        lad = dict(gs, cur=17, fail_n=DABGAIN_FAIL_N - 1)
        assert keep["_at_orig_dabgain_step"](lad, False, 5, "11D") == ("Airspy-Stufe 17", "Airspy-Stufe %s" % AIR_LADDER[0]) and lad["cur"] == 16     # Sync-Verlust auf einer Automatik-Stufe: Leiter beginnt wieder bei 16
        # --- 1) Automatik aus (nicht im Dienst): _at_tick tut nichts zusaetzlich
        _AG["on"] = False
        _at_tick(pl, t_day)
        assert _AG["st"] is None and not os.path.exists(p(AG_FILE, tmp))
        _AG["on"] = True

        def block(sync, g_expect=None, snr=12.0, fic=0.01, ran=60.0, hw=None):
            r = _at_cmd_dab(pl, "11D")
            g = int(r[0][r[0].index("-g") + 1])
            t = time.time()
            pl.since = t - ran
            pl.sbc.d["dab"]["11D"] = {"demod": {"t": int(t), "sync": sync, "snr": snr if sync else None, "fic_rate": fic if sync else None, "ens_id": "0x10a5" if sync else None, "hw_gain": hw}}
            _at_sub_done(pl, {"queue": ["dab:0"], "i": 0}, t)
            return g

        def run_session(score_by_level, now_, hw=None):
            """komplette Messung: je Stufe feste Werte; gibt die Stufenfolge zurueck."""
            seq = []
            while _AT["run"] is not None and _AT["run"]["i"] < len(_AT["run"]["plan"]):
                g = _AT["run"]["plan"][_AT["run"]["i"]]
                fic, snr = score_by_level[g]
                seq.append(block(True, snr=snr, fic=fic, hw=(hw if g == -1 else None)))
            _AG["t_next"] = now_ + 100000                                                                # Beenden ohne gleichzeitigen Automatik-Takt
            _at_tick(pl, now_)                                                                           # Lauf fertig -> Beenden
            return seq

        G["_at_orig_sub_done"] = lambda self, sp, now: None

        def tk(now):
            """Ein Automatik-Takt zur Zeit now (Stick-Daten frisch, Takt-Sperren zurueckgesetzt)."""
            _WD["d"]["sticks"]["44A42E4F2A5B1C83"] = {"last_ok": now - 30, "inc": None}
            _AG.update(t_chk=0.0, t_next=0.0, msg_t=0.0)
            _ag_tick(pl, now)

        def fresh(now):
            _WD["d"]["sticks"]["44A42E4F2A5B1C83"] = {"last_ok": now - 30, "inc": None}
        # --- 2) Boot: neuer Zustand, Modus auto, keine Messung am Tag, erste Messung im Nachtfenster
        tk(t_day)
        st = _AG["st"]
        assert st and st["mode"] == "auto" and st["cur"] == 16 and not st["lock"] and os.path.exists(p(AG_FILE, tmp)) and any("autoGain: bereit" in x for x in logs), (st, logs)
        _AG["t_chk"] = 0.0
        _AG["t_next"] = 0.0
        tk(t_day + 4000)
        assert _AT["run"] is None, "am Tag keine erste Messung"
        assert "Nachtfenster" in (_load_json_ag(tmp) or {}).get("next_txt", ""), _load_json_ag(tmp)
        _AG.update(t_chk=0.0, t_next=0.0)
        blk[0] = "echter Alarm im Lagezentrum"
        tk(t_night + 3600)
        assert _AT["run"] is None and "Tagesmessung nicht gestartet" in _AG["st"]["msg"]["txt"] and "echter Alarm" in _AG["st"]["msg"]["txt"] and _AG["st"]["retry_t"] > t_night, _AG["st"]["msg"]   # Alarm: keine Messung, Wiederholung spaeter
        blk[0] = None
        tk(t_night + 3700)
        assert _AT["run"] is None, "Wartezeit nach abgelehnter Messung"
        tk(t_night + 3600 + AG_RETRY_S + 10)
        run = _AT["run"]
        assert run and run["profile"] == "day" and run["levels"] == [12, 14, 16, 17, 18] and len(run["plan"]) == 15 and run["plan"][:5] == [12, 14, 16, 17, 18] and run["default"]["cur"] == 16, run
        assert any("Tagesmessung der Gain-Automatik" in x for x in logs)
        # --- 3) Messung 1: Stufe 14 klar besser (FIC am staerksten), Stufe 16 Standard
        SC = {12: (0.012, 9.5), 14: (0.008, 11.5), 16: (0.05, 13.9), 17: (0.04, 14.0), 18: (0.06, 14.2)}
        seq = run_session(SC, t_night + 6000)
        assert seq[:5] == [12, 14, 16, 17, 18] and _AT["run"] is None and gs["cur"] == 16
        st = _AG["st"]
        assert len(st["sessions"]) == 1 and st["last_session_t"] and st["sessions"][0]["profile"] == "day" and st["sessions"][0]["levels"]["14"]["n"] == 3 and not st["pending"], st["sessions"]
        assert "zu wenig Messungen" in st["msg"]["txt"], st["msg"]                                     # eine Sitzung: keine Entscheidung
        assert gs["cur"] == 16, "Standard-Gain nach Messung unveraendert"
        # --- 4) zweite Sitzung (Gain-Test 2 per Knopf, mit Auto): jetzt klarer Vorteil ueber mehrere Sitzungen -> Wechsel wartet bei Sperre
        open(p(AT_REQ, tmp), "w").write(json.dumps({"v": 1, "cmd": "start", "profile": "t2", "t": t_night + 7000}))
        fresh(t_night + 7001)
        _at_tick(pl, t_night + 7001)
        run = _AT["run"]
        assert run and run["profile"] == "t2" and run["levels"] == [14, 16, 17, 18, -1] and len(run["plan"]) == 25 and run["deadline"] - run["t0"] == 70 * 60, run
        SC2 = dict(SC)
        SC2[-1] = (0.02, 12.0)
        seq = run_session(SC2, t_night + 9000, hw=13.0)
        assert -1 in seq and _AT["run"] is None and gs["cur"] == 16
        st = _AG["st"]
        s2 = st["sessions"][-1]
        assert s2["profile"] == "t2" and s2["levels"]["-1"]["hw_min"] == 13.0 and "14" in s2["levels"], s2
        assert "-g" in _at_cmd_dab(pl, "11D")[0] and _at_cmd_dab(pl, "11D") == base_cmd, "ohne Messung unveraendert"
        assert st["pending"] and st["pending"]["to"] == 14 and st["pending"]["kind"] == "auto" and "besser als Stufe 16" in st["pending"]["why"], st["pending"]
        blk[0] = "RDS-Alarm PTY 31 (Test)"
        tk(t_night + 9100)
        assert gs["cur"] == 16 and _AG["st"]["pending"] and "PTY 31" in _AG["st"]["msg"]["txt"], "PTY 31 sperrt den Wechsel"
        for reason in ("ASA-Warnung/Ansage auf 5C (letzte 2 h)", "Antennentest läuft", "Meteor-Aufnahme läuft", "echter Alarm im Lagezentrum", "Sperr-Prüfung fehlgeschlagen (x)"):
            blk[0] = reason
            tk(t_night + 9200)
            assert gs["cur"] == 16 and _AG["st"]["pending"], reason
        blk[0] = None
        tk(t_night + 9300)
        st = _AG["st"]
        assert gs["cur"] == 14 and st["cur"] == 14 and not st["pending"] and st["changes"] == [int(t_night + 9300)] and st["history"][-1]["kind"] == "auto" and st["history"][-1]["to"] == 14, st["history"]
        assert st["post"]["status"] == "watch" and st["post"]["from"] == 16 and st["post"]["to"] == 14 and gs["fail_n"] == 0 and gs["ok"] is None
        cmd = _at_cmd_dab(pl, "11D")
        assert cmd == base_cmd, "Kommandozeile kommt aus der Gain-Leiter (hier gefakt)"
        # --- 5) Empfang nach Wechsel schlechter -> zurueck auf 16 und Sperre
        db_path = p("lagezentrum.db", tmp)
        M.dq_migrate(db_path)
        con = M.db.connect(db_path)
        try:
            with con:
                for i in range(40):                                                                   # vorher (24 h bis Wechsel): gut
                    con.execute("INSERT INTO reception_log(timestamp, channel, tii, snr, errors, sync, fic_rate) VALUES(?,?,?,?,NULL,1,?)", (int(t_night + 9300 - 3600 - i * 600), "11D", "08/18", 13.0, 0.01))
                for i in range(15):                                                                   # nachher: schlecht
                    con.execute("INSERT INTO reception_log(timestamp, channel, tii, snr, errors, sync, fic_rate) VALUES(?,?,?,?,NULL,1,?)", (int(t_night + 9300 + 700 + i * 120), "11D", "08/18", 7.0, 0.09))
        finally:
            con.close()
        tk(t_night + 9300 + 700 + 15 * 120 + 5)
        st = _AG["st"]
        assert st["post"]["status"] == "worse" and st["lock"] and st["lock"]["kind"] == "worse" and st["lock"]["fixed"] == 16 and st["pending"] and st["pending"]["to"] == 16, (st["post"], st["lock"])
        blk[0] = "Meteor-Aufnahme läuft"
        tk(t_night + 12000)
        assert gs["cur"] == 14, "auch die Rueckkehr wartet bei Sperre"
        blk[0] = None
        tk(t_night + 12100)
        st = _AG["st"]
        assert gs["cur"] == 16 and st["cur"] == 16 and not st["pending"] and st["history"][-1]["kind"] == "revert" and len(st["changes"]) == 1, st["history"]
        assert "schlechterer Empfang nach dem Wechsel auf Stufe 14" in st["lock"]["why"], st["lock"]
        v = M.ag_view(tmp, t_night + 12150)
        assert v["locked"] and "GESPERRT" in v["txt"] and "Stufe 16" in v["txt"] and v["last_change"]["kind"] == "revert", v
        # --- 6) gesperrt: keine Messung, keine Entscheidung; Knopf 'Auto' hebt Sperre auf (Wechsel-Zaehler zurueck)
        tk(t_night + 3 * 86400)
        assert _AT["run"] is None, "gesperrt: keine Tagesmessung"
        open(p(AG_REQ, tmp), "w").write(json.dumps({"v": 1, "cmd": "auto", "t": t_night + 3 * 86400 + 5}))
        tk(t_night + 3 * 86400 + 6)
        st = _AG["st"]
        assert st["mode"] == "auto" and st["lock"] is None and st["changes"] == [] and st["history"][-1]["kind"] == "manual" and "Auto wieder aktiviert" in st["history"][-1]["why"], st["history"][-1]
        open(p(AG_REQ, tmp), "w").write(json.dumps({"v": 1, "cmd": "measure", "t": t_night + 3 * 86400 + 8}))
        fresh(t_night + 3 * 86400 + 9)
        tk(t_night + 3 * 86400 + 9)
        run = _AT["run"]
        assert run and run["profile"] == "day" and "Knopf Jetzt messen" in _AG["st"]["msg"]["txt"], _AG["st"]["msg"]
        _at_finish(pl, dict(run), "aborted", "Test-Abbruch", t_night + 3 * 86400 + 20)
        assert _AT["run"] is None and _AG["st"]["retry_t"] > t_night + 3 * 86400 and "abgebrochen" in _AG["st"]["msg"]["txt"] and len(_AG["st"]["windows"]) >= 1
        _AG["st"]["retry_t"] = 0
        # alte/gleiche Anforderung nie zweimal, veraltete nie
        open(p(AG_REQ, tmp), "w").write(json.dumps({"v": 1, "cmd": "fest", "t": t_night + 3 * 86400 + 5}))
        tk(t_night + 3 * 86400 + 30)
        assert _AG["st"]["mode"] == "auto"
        open(p(AG_REQ, tmp), "w").write(json.dumps({"v": 1, "cmd": "fest", "t": t_night + 3 * 86400 - 500}))
        tk(t_night + 3 * 86400 + 40)
        assert _AG["st"]["mode"] == "auto"
        open(p(AG_REQ, tmp), "w").write(json.dumps({"v": 1, "cmd": "fest", "t": t_night + 3 * 86400 + 100}))
        tk(t_night + 3 * 86400 + 110)
        assert _AG["st"]["mode"] == "fest" and gs["cur"] == 16 and _AG["st"]["history"][-1]["kind"] == "manual"
        _AG.update(t_chk=0.0, t_next=0.0, st=_AG["st"])
        _AG["st"]["pending"] = {"to": 14, "kind": "auto", "why": "x", "t": t_night}
        open(p(AG_REQ, tmp), "w").write(json.dumps({"v": 1, "cmd": "fest", "t": t_night + 3 * 86400 + 200}))
        tk(t_night + 3 * 86400 + 210)
        assert gs["cur"] == 16 and _AG["st"]["pending"] is None, "Knopf fest verwirft offene Entscheidung"
        # --- 7) Flip-Flop: 2 Wechsel in 48 h -> dritter wird zur Sperre mit bestem festem Wert
        now7 = t_night + 5 * 86400
        _AG["st"].update(mode="auto", lock=None, pending=None, changes=[int(now7 - 30 * 3600), int(now7 - 20 * 3600)], post=None, last_session_t=int(now7 - 3600), retry_t=0)
        gs["cur"] = 16
        _AG["st"]["cur"] = _AG["st"]["cur_seen"] = 16
        _AG["st"]["sessions"] = [{"t": now7 - 2 * 86400, "profile": "day", "cur": 16, "n": 15, "levels": {"16": {"n": 3, "sync_pct": 100.0, "score": 70.0}, "14": {"n": 3, "sync_pct": 100.0, "score": 86.0}}},
                                 {"t": now7 - 86400, "profile": "day", "cur": 16, "n": 15, "levels": {"16": {"n": 3, "sync_pct": 100.0, "score": 71.0}, "14": {"n": 3, "sync_pct": 100.0, "score": 85.0}}}]
        run = {"id": now7, "t0": now7 - 900, "profile": "day", "default": {"cur": 16}, "samples": [{"i": i, "g": g, "sync": True, "snr": 12.0, "fic": 0.05 if g == 16 else 0.01} for i, g in enumerate([14, 16] * 3)]}
        _at_finish(pl, dict(run, state="done"), "done", "", now7)
        st = _AG["st"]
        assert st["lock"] and st["lock"]["kind"] == "flipflop" and st["lock"]["fixed"] == 14 and "mehr als 2 Wechsel in 48 h" in st["lock"]["why"] and st["pending"]["to"] == 14 and st["pending"]["kind"] == "lock", (st["lock"], st["pending"])
        tk(now7 + 60)
        st = _AG["st"]
        assert gs["cur"] == 14 and st["history"][-1]["kind"] == "lock" and len(st["changes"]) == 2 and st["post"] is None, st["history"][-1]
        # --- 8) Gain-Leiter bei Sync-Verlust wird beobachtet (nicht als Wechsel der Automatik gezaehlt)
        gs.update(cur=12, ok=None)
        tk(now7 + 120)
        st = _AG["st"]
        assert st["cur"] == 12 and st["history"][-1]["kind"] == "ladder" and len(st["changes"]) == 2, st["history"][-1]
        # --- 9) Fehler in Folge -> Rueckfall Stufe 16 + Sperre
        _AG["st"]["lock"] = None
        _AG["st"]["mode"] = "auto"
        _AG["mgr"] = None
        gs["cur"] = 18
        _AG["st"]["cur"] = _AG["st"]["cur_seen"] = 18
        orig_m = _ag_m
        _AG["err_t"] = time.time()
        G["_ag_m"] = lambda: (_ for _ in ()).throw(RuntimeError("sdr_manager kaputt"))
        try:
            for i in range(AG_ERR_MAX):
                tk(now7 + 200 + i)
        finally:
            G["_ag_m"] = orig_m
        st = _AG["st"]
        assert st["fault"] and st["mode"] == "fest" and st["lock"]["kind"] == "fehler" and st["lock"]["fixed"] == 16 and st["pending"]["to"] == 16, (st["lock"], st["pending"])
        tk(now7 + 300)
        assert gs["cur"] == 16 and _AG["st"]["history"][-1]["kind"] == "revert" and _AG["st"]["fault"], _AG["st"]["history"][-1]
        # --- 10) kaputte Zustandsdatei beim Start -> Rueckfall Stufe 16 + Sperre
        _AG.update(on=True, boot=False, st=None, t_chk=0.0, t_next=0.0, err_n=0)
        gs["cur"] = 18
        open(p(AG_FILE, tmp), "w").write("{kaputt")
        tk(now7 + 400)
        st = _AG["st"]
        assert st["fault"] and st["lock"]["kind"] == "fehler" and "unlesbar" in st["lock"]["why"] and st["pending"] is None and gs["cur"] == 16, (st["lock"], st["pending"])      # ohne Sperre sofort zurueck auf 16
        tk(now7 + 420)
        assert gs["cur"] == 16 and json.load(open(p(AG_FILE, tmp), encoding="utf-8"))["lock"]["kind"] == "fehler"
        # --- 11) Tagesmessung nur bei Auto, ohne Sperre; schlechter Empfang loest frueher aus
        _AG.update(on=True, boot=False, st=None, t_chk=0.0, t_next=0.0, err_n=0)
        os.remove(p(AG_FILE, tmp))
        tk(t_day + 10 * 86400)
        st = _AG["st"]
        st.update(last_session_t=int(t_day + 10 * 86400 - 8 * 3600), retry_t=0, windows=[], sessions=[])
        m = _ag_m()
        assert _ag_due(pl, st, t_day + 10 * 86400, m) is None, "8 h nach der letzten Messung, Empfang gut"
        con = M.db.connect(db_path)
        try:
            with con:
                for i in range(30):
                    con.execute("INSERT INTO reception_log(timestamp, channel, tii, snr, errors, sync, fic_rate) VALUES(?,?,?,?,NULL,?,?)", (int(t_day + 10 * 86400 - 60 * i - 100), "11D", None, None, 0, None))
        finally:
            con.close()
        r = _ag_due(pl, st, t_day + 10 * 86400, m)
        assert r and "schlechter Empfang" in r, r
        st["mode"] = "fest"
        assert _ag_due(pl, st, t_day + 10 * 86400, m) is None
        st.update(mode="auto", lock={"t": 1, "kind": "worse", "why": "x", "fixed": 16})
        assert _ag_due(pl, st, t_day + 10 * 86400, m) is None
        st.update(lock=None, last_session_t=int(t_day + 10 * 86400 - 25 * 3600))
        assert _ag_due(pl, st, t_day + 10 * 86400, m) is not None                                     # (schlechter Empfang) auch hier
        st["windows"] = [[t_day + 10 * 86400 - 3 * 3600, t_day + 10 * 86400 + 5]]                       # Testfenster zaehlen nicht als Empfang
        assert M.ag_bad(M.ag_rows(tmp, t_day + 10 * 86400 - 3 * 3600, t_day + 10 * 86400 + 1, st["windows"])) is False
        assert _ag_due(pl, st, t_day + 10 * 86400, m) is None, "ohne Nachtfenster erst nach 36 h"
        st["last_session_t"] = int(t_day + 10 * 86400 - 37 * 3600)
        assert "36 h" in _ag_due(pl, st, t_day + 10 * 86400, m)
        st["last_session_t"] = int(t_night + 10 * 86400 - 25 * 3600)
        assert "Nachtfenster" in _ag_due(pl, st, t_night + 10 * 86400, m)
        st["pending"] = {"to": 14, "kind": "auto", "why": "x", "t": 1}
        assert _ag_due(pl, st, t_night + 10 * 86400, m) is None
        st["pending"], st["post"] = None, {"t": int(t_night + 10 * 86400 - 3600), "status": "watch"}
        assert _ag_due(pl, st, t_night + 10 * 86400, m) is None, "nicht waehrend der Beobachtung nach einem Wechsel"
        # --- 12) Pruefung der echten Sperr-Funktion (Alarm/ASA/PTY 31/Antennentest/Meteor) fuer den Wechsel
        G["_wd_block"] = keep["_wd_block"]
        pl.st_pause = False
        assert _ag_blocked(pl, t_night) is None, _ag_blocked(pl, t_night)
        pl.st_pause = True
        assert "Antennentest" in _ag_blocked(pl, t_night)
        pl.st_pause = False
        pl.pmeteor = object()
        assert "Meteor" in _ag_blocked(pl, t_night)
        pl.pmeteor = None
        pl.sbc.d["fm"] = {"x": {"pty31_persist": True, "pty31_last": t_night - 10, "name": "BR"}}
        assert "PTY 31" in _ag_blocked(pl, t_night)
        pl.sbc.d["fm"] = {}
        pl.sbc.d["warn"] = [{"src": "DAB 5C", "kind": "Ansage", "t": t_night - 100}]
        assert "ASA" in _ag_blocked(pl, t_night)
        pl.sbc.d["warn"] = []
        open(p(WD_GATE, tmp), "w").write(json.dumps({"alarm": True, "t": t_night}))
        assert "Alarm" in _ag_blocked(pl, t_night)
        os.remove(p(WD_GATE, tmp))
        _WD["busy"] = "X"
        assert _ag_blocked(pl, t_night)
        _WD["busy"] = None
        _AT["run"] = {"state": "running"}
        assert "läuft" in _ag_blocked(pl, t_night)
        _AT["run"] = None
        assert Planner.step in (globals().get("_at_step"), globals().get("_sh_step")) and _at_tick is not _ag_orig_at_tick and _at_start is _ag_start
    finally:
        for k, v in keep.items():
            G[k] = v
        _AT.clear()
        _AT.update(sv_at)
        _AG.clear()
        _AG.update(sv_ag)
        for k, v in sv_wd.items():
            _WD[k] = v
    return "selftest autoGain ok (Score/Entscheidung nur bei klarem Vorteil ueber mehrere Sitzungen, Tagesmessung nur im Nachtfenster oder nach anhaltend schlechtem Empfang, Gain-Test 2 mit Auto nur gemessen, Wechsel nur ohne Alarm/ASA/PTY 31/Antennentest/Meteor, Sperre bei mehr als 2 Wechseln in 48 h und bei schlechterem Empfang nach Wechsel, Auto-Knopf hebt auf, Fehler und kaputte Zustandsdatei -> Stufe 16)"


def _load_json_ag(base):
    try:
        with open(p(AG_FILE, base), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None
ASD_EOF
EXPECT_ADH="d760729007f6b50b6bb0aba91dcdb1560fad7f944a829e97fb2708cd14421408"
cat > "$W/ag_dash_block.py" << 'ADH_EOF'
# ===== autoGain: Anzeige - Karte Gain-Automatik auf /funk (aktueller Gain, Auto/Fest-Schalter mit Rueckfrage, Grund des letzten Wechsels, Verlauf, Messtabelle mit Score, Knoepfe Jetzt messen und Gain-Test 2 mit Auto) und /api/sdr/autogain (GET Zustand, POST auto|fest|measure nur von der Funk-Seite im Heimnetz); Gain-Test-Karte um Score/Auto erweitert; Kachelbreite auf /funk repariert (Raster mit minmax(0,1fr), Tabelle der Gain-Test-Karte umbrechend); schreibt nur Anforderungsdateien, sendet nichts =====
_AGD = {"t": 0.0, "v": None, "selftest": None}
_AG_CSS = """.grid{grid-template-columns:minmax(0,1fr)}
@media(min-width:900px){.grid{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}}
.grid>*{min-width:0;max-width:100%}
#atCard,#agCard{overflow-x:auto}
#atCard table th,#atCard table td{white-space:normal;overflow-wrap:normal;padding:3px 4px;font-size:.78rem}
#agCard .ag-s{font-size:.9rem;margin:4px 0 8px;color:#e2e8f0;line-height:1.35;overflow-wrap:anywhere}
#agCard .ag-s.ag-gesperrt{color:#fca5a5}
#agCard .ag-s.ag-fest{color:#fcd34d}
#agCard .ag-kv{display:grid;grid-template-columns:minmax(86px,34%) minmax(0,1fr);gap:4px 10px;font-size:.88rem;line-height:1.35;margin:4px 0}
#agCard .ag-kv>div:nth-child(odd){color:#94a3b8}
#agCard .ag-kv>div{overflow-wrap:anywhere}
#agCard .ag-sw{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin:10px 0 4px}
#agCard button{border-radius:8px;padding:10px 12px;font-size:.95rem;border:1px solid #334155;background:#1e293b;color:#cbd5e1;min-width:0}
#agCard button.ag-on{background:#1e3a5f;color:#93c5fd;border-color:#3b82f6;font-weight:600}
#agCard button.ag-wide{width:100%;margin-top:8px;background:#1e3a5f;color:#93c5fd}
#agCard button:disabled{opacity:.5}
#agCard table{border-collapse:collapse;width:100%;margin:8px 0;font-size:.85rem;font-variant-numeric:tabular-nums}
#agCard th,#agCard td{padding:3px 5px;text-align:right;border-bottom:1px solid #1e293b}
#agCard th:first-child,#agCard td:first-child{text-align:left}
#agCard tr.ag-now td{color:#86efac;font-weight:600}
#agCard .ag-h{font-size:.82rem;color:#cbd5e1;margin:3px 0;line-height:1.3;overflow-wrap:anywhere}
#agCard .ag-h span{color:#94a3b8}
#agCard .ag-n{font-size:.78rem;color:#94a3b8;margin-top:6px;line-height:1.35}
#agCard .ag-t{font-size:.8rem;color:#94a3b8;margin:8px 0 2px}"""
_AG_JS = r"""(function(){var V=null,BUSY=0,MSG='';try{V=JSON.parse(document.getElementById('ag-data').textContent);}catch(e){V=null;}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function fn(x,d){return (typeof x==='number')?x.toFixed(d).replace('.',','):'\u2013';}
function p2(n){return (n<10?'0':'')+n;}
function ft(t){if(!t)return '\u2013';var d=new Date(t*1000);return p2(d.getDate())+'.'+p2(d.getMonth()+1)+'. '+p2(d.getHours())+':'+p2(d.getMinutes());}
function lbl(g){return g===-1?'Auto (welle-AGC)':(g==='agc'?'Auto (Notstufe)':(g===null||g===undefined?'\u2013':'Stufe '+g));}
var KIND={auto:'Automatik',lock:'Sperre',revert:'zur\u00fcck',manual:'Knopf',ladder:'Gain-Leiter',fehler:'Fehler'};
function kv(box,k,v){box.appendChild(el('div',null,k));box.appendChild(el('div',null,v));}
function card(){var c=document.getElementById('agCard');
if(!c){var a=document.getElementById('sdrUiCard')||document.getElementById('fuLage');if(!a||!a.parentNode)return;c=el('div','card');c.id='agCard';a.parentNode.insertBefore(c,a.nextSibling);}
var at=document.getElementById('atCard');if(at&&at.parentNode&&at.previousSibling!==c){at.parentNode.insertBefore(c,at);}
if(!V)return;var sig=JSON.stringify([V,MSG,BUSY]);if(c.dataset.sig===sig)return;c.dataset.sig=sig;c.textContent='';
var mode=V.locked?'gesperrt':(V.mode==='fest'?'fest':'auto'),T=V.test||{};
c.appendChild(el('div','title','\u2699\ufe0f Gain-Automatik \u00b7 '+(V.dev||'Airspy 11D')));
c.appendChild(el('div','ag-s ag-'+mode,V.txt||''));
var b=el('div','ag-kv');kv(b,'Aktueller Gain',V.cur_txt||'\u2013');kv(b,'Modus',mode==='gesperrt'?'gesperrt (fest '+lbl(V.lock&&V.lock.fixed)+')':(mode==='fest'?'fest (Auto aus)':'Auto'));
var lc=V.last_change;kv(b,'Letzter Wechsel',lc?(ft(lc.t)+' \u00b7 '+(KIND[lc.kind]||lc.kind)+': '+(lc.from!==lc.to?lbl(lc.from)+' \u2192 '+lbl(lc.to)+' \u2013 ':'')+(lc.why||'')):'noch keiner');
kv(b,'Wechsel in 48 h',(V.changes_48h||0)+' (mehr als 2 sperren)');
if(V.next_txt)kv(b,'N\u00e4chste Messung',V.next_txt);
if(T.running)kv(b,'Messung l\u00e4uft',(T.i||0)+' von '+(T.total||'?')+' Pr\u00fcfbl\u00f6cken ('+(T.profile==='t2'?'Gain-Test 2':(T.profile==='day'?'Tagesmessung':'Gain-Test 1'))+')');
if(V.post&&V.post.status==='watch')kv(b,'Nach Wechsel','Empfang wird mit dem Stand davor verglichen\u2026');
c.appendChild(b);
var sw=el('div','ag-sw');
[['auto','Auto'],['fest','Fest']].forEach(function(o){var on=(o[0]==='auto')?(mode==='auto'):(mode!=='auto');var x=el('button',on?'ag-on':'',o[1]+(o[0]==='fest'&&mode==='gesperrt'?' (gesperrt)':''));x.type='button';x.disabled=!!BUSY;
x.addEventListener('click',function(){if(on)return;if(o[0]==='auto')post('/api/sdr/autogain',{action:'auto'},'Gain-Automatik wieder einschalten? '+(V.locked?'Die Sperre wird aufgehoben und der Wechsel-Z\u00e4hler zur\u00fcckgesetzt. ':'')+'Es wird nur nachts oder nach anhaltend schlechtem Empfang gemessen und nur bei klarem Vorteil gewechselt.','Auto angefordert.');
else post('/api/sdr/autogain',{action:'fest'},'Automatik ausschalten? Der Gain bleibt fest auf '+(V.cur_txt||'dem aktuellen Wert')+'.','Fest angefordert.');});sw.appendChild(x);});
c.appendChild(sw);
var m=el('button','ag-wide','Jetzt messen (Tagesmessung, ca. 15\u201320 min)');m.type='button';m.disabled=!!BUSY||!!T.running;
m.addEventListener('click',function(){post('/api/sdr/autogain',{action:'measure'},'Jetzt messen? Die Stufen '+(V.day_levels||[]).join('/')+' werden je 3 Runden gepr\u00fcft (ca. 15\u201320 Minuten). Der Gain bleibt gespeichert; gewechselt wird nur bei klarem Vorteil \u00fcber mehrere Messungen.','Messung angefordert.');});c.appendChild(m);
var t2=el('button','ag-wide','Gain-Test 2 starten (14/16/17/18/Auto, ca. 30\u201335 min)');t2.type='button';t2.disabled=!!BUSY||!!T.running;
t2.addEventListener('click',function(){post('/api/sdr/airtest',{action:'start',profile:'t2'},'Gain-Test 2 starten? Stufen 14/16/17/18 und Auto (welle-AGC), je 5 Runden, ca. 30\u201335 Minuten. Der Gain bleibt gespeichert; Auto wird nur gemessen, nie automatisch gew\u00e4hlt. Bei Alarm/Sperre bricht der Test ab.','Gain-Test 2 angefordert.');});c.appendChild(t2);
if(MSG)c.appendChild(el('div','ag-n',MSG));
else if(V.msg&&V.msg.txt)c.appendChild(el('div','ag-n',ft(V.msg.t)+' \u00b7 '+V.msg.txt));
if((V.table||[]).length){c.appendChild(el('div','ag-t','Messungen (Mittel der letzten '+Math.min(V.sessions||0,3)+' Sitzungen, Score 0\u2013100, FIC-Fehler am st\u00e4rksten gewichtet)'));
var t=el('table'),h=el('tr');['Stufe','Score','Sync','FIC','SNR'].forEach(function(x){h.appendChild(el('th',null,x));});t.appendChild(h);
V.table.forEach(function(r){var tr=el('tr',r.now?'ag-now':'');[(r.now?'\u25b6 ':'')+(r.g===-1?'Auto':r.g),fn(r.score,1),r.sync_pct===null||r.sync_pct===undefined?'\u2013':fn(r.sync_pct,0)+' %',fn(r.fic,2)+' %',fn(r.snr,1)+' dB'].forEach(function(x){tr.appendChild(el('td',null,x));});t.appendChild(tr);});c.appendChild(t);}
if((V.history||[]).length){c.appendChild(el('div','ag-t','Verlauf'));V.history.slice(0,6).forEach(function(h){var d=el('div','ag-h');d.appendChild(el('span',null,ft(h.t)+' \u00b7 '+(KIND[h.kind]||h.kind)+': '));d.appendChild(document.createTextNode((h.from!==h.to?lbl(h.from)+' \u2192 '+lbl(h.to)+' \u2013 ':'')+(h.why||'')));c.appendChild(d);});}
c.appendChild(el('div','ag-n','Wechsel nur bei klarem Vorteil \u00fcber mehrere Messungen und nie bei Alarm, ASA-Warnung, PTY 31, Antennentest oder Meteor-Aufnahme (ein Wechsel startet welle-cli neu). Mehr als 2 Wechsel in 48 h oder schlechterer Empfang nach einem Wechsel sperren den besten festen Wert, bis Du hier wieder Auto einschaltest. Bei Fehlern gilt Stufe 16. Auto (welle-AGC) wird nur gemessen, nie automatisch gew\u00e4hlt.'));}
function post(url,body,ask,okmsg){if(BUSY)return;if(!window.confirm(ask))return;BUSY=1;MSG='\u2026';card();body.confirm=true;
fetch(url,{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-T2':'1'},body:JSON.stringify(body)})
.then(function(r){return r.json();}).then(function(j){MSG=j.ok?okmsg+' prepper-sdr setzt es mit dem n\u00e4chsten Takt (bis ca. 1 min) um.':('nicht erledigt: '+(j.error||'Fehler'));})
.catch(function(){MSG='nicht erledigt: Netzfehler';}).then(function(){BUSY=0;setTimeout(load,3000);load();setTimeout(function(){if(!BUSY){MSG='';card();}},25000);});}
function load(){fetch('/api/sdr/autogain',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.ok!==undefined){V=j;card();}}).catch(function(){});}
function loop(){load();setTimeout(loop,(V&&V.test&&V.test.running)?5000:30000);}
try{card();}catch(e){}setInterval(function(){try{card();}catch(e){}},1000);setTimeout(loop,(V&&V.test&&V.test.running)?5000:30000);})();"""
_AT_JS_SUBS = (
    ("'\\ud83d\\udcf6 Gain-Test \\u00b7 '+(V.dev||'Airspy 11D')", "'\\ud83d\\udcf6 Gain-Test'+(V.profile==='t2'?' 2':'')+(V.profile==='day'?' (Tagesmessung)':'')+' \\u00b7 '+(V.dev||'Airspy 11D')"),
    ("'Gain-Test starten (ca. 15\\u201320 min)'", "'Gain-Test 1 starten (12/19/21, ca. 15\\u201320 min)'"),
    ("['Stufe','Messungen','Sync','SNR \\u00d8 (min)','FIC-Fehler \\u00d8 (max)']", "['Stufe','Messungen','Sync','SNR \\u00d8 (min)','FIC-Fehler \\u00d8 (max)','Score']"),
    ("V.rows.forEach(function(r){row(t,[(V.rec&&V.rec.level===r.g?'\\u2605 ':'')+r.g,", "var SR={},RL=V.rec_score?V.rec_score.level:(V.rec?V.rec.level:null);(V.score_rows||[]).forEach(function(s){SR[s.g]=s;});V.rows.forEach(function(r){row(t,[(RL===r.g?'\\u2605 ':'')+(r.g===-1?'Auto':r.g),"),
    ("fn(r.fic_mean,2)+' % ('+fn(r.fic_max,2)+')'],(V.rec&&V.rec.level===r.g)?'at-rec':'');", "fn(r.fic_mean,2)+' % ('+fn(r.fic_max,2)+')',fn((SR[r.g]||{}).score,1)],(RL===r.g)?'at-rec':'');"),
    ("fn(V.ref.fic_mean,2)+' %'],'at-ref');", "fn(V.ref.fic_mean,2)+' %','\\u2013'],'at-ref');"),
    ("if(V.rec)c.appendChild(el('div','at-r',V.rec.txt));", "if(V.rec_score)c.appendChild(el('div','at-r',V.rec_score.txt));else if(V.rec)c.appendChild(el('div','at-r',V.rec.txt));"),
    ("'Nur Airspy 11D, nur auf Knopfdruck; Standard-Gain wird nie ge\\u00e4ndert; Abbruch bei Alarm/ASA/Sperre, Neustart oder Zeitlimit.'", "'Nur Airspy 11D; der Test selbst \\u00e4ndert den Standard-Gain nie (nur die Gain-Automatik oben, nur ohne Sperre); Abbruch bei Alarm/ASA/Sperre, Neustart oder Zeitlimit.'"),
)


def _ag_view_now():
    now = _t4_time.time()
    if _AGD["v"] is not None and now - _AGD["t"] < 5:
        return _AGD["v"]
    v = {"ok": False, "txt": "Gain-Automatik: nicht verfuegbar", "table": [], "history": [], "mode": "auto", "locked": False}
    try:
        if _lz_mgr is None or not hasattr(_lz_mgr, "ag_view"):
            raise RuntimeError("sdr_manager.py ohne autoGain")
        v = _lz_mgr.ag_view(_SDR_BASE, int(now))
        v["dev"] = _dq_dev("11D") or "Airspy 11D"
        a = _lz_mgr.at_view(_SDR_BASE, int(now))
        v["test"] = {"running": bool(a.get("running")), "profile": a.get("profile"), "i": a.get("i"), "total": a.get("total"), "state": a.get("state")}
        v["day_levels"] = _lz_mgr.ag_levels_for(v.get("cur"))
    except Exception as e:
        v = dict(v, error=str(e)[:120])
        print("autoGain Anzeige:", e, flush=True)
    _AGD.update(t=now, v=v)
    return v


def _ag_api():
    from flask import jsonify, request as rq
    try:
        if rq.method != "POST":
            return jsonify(_ag_view_now())
        err, j = _t2d_check(rq)
        if err:
            return jsonify({"ok": False, "error": err}), j
        act = j.get("action")
        if act not in ("auto", "fest", "measure"):
            return jsonify({"ok": False, "error": "ungueltig"}), 400
        with _T2D_LOCK:
            r = _lz_mgr.ag_req_put(_SDR_BASE, act, "dashboard")
        _AGD["t"] = 0.0
        print("autoGain: Knopf -> %s angefordert (prepper-sdr entscheidet: Sperren, Rueckfall Stufe 16)" % act, flush=True)
        return jsonify(r)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


def _ag_airtest_api():
    """wie /api/sdr/airtest bisher; zusaetzlich profile t1|t2 beim Start (Gain-Test 2 = 14/16/17/18 + Auto)."""
    from flask import jsonify, request as rq
    try:
        if rq.method != "POST":
            return jsonify(_at_view_now())
        err, j = _t2d_check(rq)
        if err:
            return jsonify({"ok": False, "error": err}), j
        act, pr = j.get("action"), j.get("profile")
        if act not in ("start", "stop") or pr not in (None, "t1", "t2"):
            return jsonify({"ok": False, "error": "ungueltig"}), 400
        with _T2D_LOCK:
            r = _lz_mgr.at_req_put2(_SDR_BASE, act, pr if act == "start" else None, "dashboard")
        _ATD["t"] = 0.0
        _AGD["t"] = 0.0
        print("airTest: Knopf -> %s%s angefordert (prepper-sdr entscheidet: Sperren/Zeitlimit/Rueckfall auf Standard-Gain)" % (act, (" " + pr) if pr else ""), flush=True)
        return jsonify(r)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


def _ag_after(resp):
    try:
        from flask import request as rq
        if rq.path != "/funk" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        j = body.rfind("</body>")
        if 'id="ag-js"' in body or j < 0:
            return resp
        dj = json.dumps(_ag_view_now(), ensure_ascii=False).replace("<", "\\u003c")
        resp.set_data(body[:j] + '<style id="ag-css">' + _AG_CSS + '</style><script type="application/json" id="ag-data">' + dj + '</script><script id="ag-js">' + _AG_JS + '</script>' + body[j:])
    except Exception as e:
        print("autoGain Seite:", e, flush=True)
    return resp


def _selftest_autogain_dash():
    for k in ("/api/sdr/autogain", "/api/sdr/airtest", "agCard", "sdrUiCard", "X-T2", "window.confirm", "textContent", "Gain-Test 2", "Jetzt messen"):
        assert k in _AG_JS, k
    assert _AG_JS.count("fetch(") == 2 and "innerHTML" not in _AG_JS and "eval(" not in _AG_JS and "localStorage" not in _AG_JS and ".click()" not in _AG_JS and "insertAdjacentHTML" not in _AG_JS
    assert _AG_JS.count("window.confirm(") == 1 and _AG_JS.count("post('/api/sdr/") == 4
    for k in ("minmax(0,1fr)", ".grid>*{min-width:0", "#atCard table th,#atCard table td{white-space:normal"):
        assert k in _AG_CSS, k
    global _AT_JS
    js = _AT_JS
    for a, b in _AT_JS_SUBS:
        assert js.count(a) == 1, a[:60]
        js = js.replace(a, b)
    assert "Standard-Gain wird nie ge" not in js and "innerHTML" not in js and js.count("fetch(") == 2
    _AT_JS = js
    v0 = _AGD["v"]
    try:
        _AGD["v"], _AGD["t"] = {"ok": True, "txt": "x", "table": [], "history": [], "mode": "auto", "locked": False, "dev": "Airspy R2 · 11D"}, _t4_time.time()
        dj = json.dumps(_ag_view_now(), ensure_ascii=False).replace("<", "\\u003c")
        assert "Airspy R2 · 11D" in dj and "<" not in dj
    finally:
        _AGD["v"], _AGD["t"] = v0, 0.0
    return "autoGain Anzeige ok (Karte Gain-Automatik auf /funk: aktueller Gain, Auto/Fest mit Rueckfrage, Grund des letzten Wechsels, Verlauf, Score-Tabelle, Jetzt messen, Gain-Test 2; /api/sdr/autogain GET/POST nur von der Funk-Seite im Heimnetz; Gain-Test-Karte mit Score und Auto; /funk-Raster mit minmax(0,1fr) gegen zu breite Kacheln)"


try:
    _AGD["selftest"] = _selftest_autogain_dash()
    if "autogain_api" not in app.view_functions:
        app.add_url_rule("/api/sdr/autogain", endpoint="autogain_api", view_func=_ag_api, methods=["GET", "POST"])
    if app.view_functions.get("airtest_api") is not _ag_airtest_api:
        app.view_functions["airtest_api"] = _ag_airtest_api
    if not any(getattr(f, "__name__", "") == "_ag_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_ag_after)
    print("autoGain aktiv: %s" % _AGD["selftest"], flush=True)
except Exception as _ag_e:
    print("autoGain Anzeige FEHLER (Funk-Seite wie bisher):", _ag_e, flush=True)
ADH_EOF
EXPECT_AGD="c408dabd7352c2a5d68bcbc9caa93f65f6e0a8950fa114df982790408fd01f2b"
cat > "$W/guard_autogain.py" << 'AGD_EOF'
"""AST-Guard autoGain.
Aufruf:  guard_autogain.py check ALTDIR NEUDIR BLKDIR EDITS   -> 0 ok, 1 Verstoss
         guard_autogain.py mutate NEUDIR BLKDIR EDITS         -> Mutationstest: jede eingebaute Verfehlung MUSS erkannt werden (0 = alle erkannt)
ALTDIR/NEUDIR enthalten dashboard.py, prepper_sdr.py, sdr_manager.py (+ database.py/config.py fuer die Eigenschaftspruefung); BLKDIR enthaelt ag_sm_block.py, ag_sdr_block.py, ag_dash_block.py.
Regeln:
 1. Rueckbau (Block weg, Stellen zurueck) ergibt die Basis Byte fuer Byte; Stellen sind genau die erwarteten.
 2. Gain-Wechsel nur in _ag_set_gain, nur aufgerufen von _ag_apply_pending, und dort erst NACH _ag_blocked (Alarm, ASA, PTY 31, Antennentest, Meteor, Messung, USB) mit Rueckkehr bei Sperre; Pruef-Fehler = gesperrt.
 3. Keine Umhuellung von Planner.step/_cmd_dab/sub_done, dabgain_step, wd_check, _wd_block; keine Netz-/Prozess-/Mesh-/Sende-Bezeichner; Dateien nur ueber die erlaubten Funktionen.
 4. Rueckfall bei Fehlern = Stufe 16 und Sperre; Engine nur ueber _AG_START im Dauerbetrieb.
 5. Datenschicht: Auto (-1) wird nie Ziel, mehr als 2 Wechsel in 48 h sperren, FIC am staerksten gewichtet, Entscheidung nur ueber mehrere Sitzungen (Eigenschaftspruefung am echten Modul).
 6. Dashboard: POST nur nach _t2d_check, nur ag_req_put/at_req_put2 unter _T2D_LOCK, feste Wertelisten, kein Netz/Datei, JS ohne innerHTML/eval.
Zusaetzlich laufen die Selbsttests der Bloecke im Apply (beide Pythons)."""
import ast
import importlib.util
import os
import re
import shutil
import sys
import tempfile

EXPECTED = {
    "SM_EDITS": [("    print(selftest_sdrrest2())\n", "    print(selftest_sdrrest2())\n    print(selftest_autogain())\n")],
    "SDR_EDITS": [
        ('"db": "Airspy-Stufe %d (Gain-Test)" % g,', '"db": "%s (Gain-Test)" % ("Airspy-Auto (welle-AGC)" if g == -1 else "Airspy-Stufe %d" % g),'),
        ('why = "Zeitlimit %d min erreicht" % (AT_LIMIT_S // 60)', 'why = "Zeitlimit %d min erreicht" % max(1, int(run["deadline"] - int(run.get("t0") or now)) // 60)'),
        ('        globals().get("_SH_START", lambda b: None)(BASE)   # sdrHalt: Waechter-Faden (wirft nie)\n',
         '        globals().get("_SH_START", lambda b: None)(BASE)   # sdrHalt: Waechter-Faden (wirft nie)\n        globals().get("_AG_START", lambda b: None)(BASE)   # autoGain: Gain-Automatik (wirft nie)\n'),
        ('        selftest_sdrfall()\n    elif a in ("stick-test"', '        selftest_sdrfall()\n        print(selftest_autogain(), flush=True)\n    elif a in ("stick-test"'),
    ],
    "DSH_EDITS": [],
}
ANCH = '\n\nif __name__ == "__main__":\n'
NET = ("subprocess", "popen", "socket", "requests", "urlopen", "urllib", "smtplib", "paramiko", "fork", "spawn", "execv", "kill", "sudo", "systemctl", "reboot", "chmod", "chown", "mesh", "telegram",
       "send", "outbox", "pickle", "base64", "environ", "getenv", "system", "secret", "import_module", "shutil", "sqlite", "tempfile_x")
EXACT_BAD = {"eval", "exec", "compile", "__import__"}
SDR_FUNCS = {"_ag_err", "_ag_lbl", "_air_gain_state", "_ag_m", "_ag_new", "_ag_load", "_ag_save", "_ag_hist", "_ag_msg", "_ag_blocked", "_ag_set_gain", "_ag_lock", "_ag_fault", "_ag_start",
             "_at_req_take", "_at_record", "_ag_on_finish", "_at_finish", "_ag_session_start", "_ag_due", "_ag_next_txt", "_ag_req", "_ag_apply_pending", "_ag_post", "_ag_run", "_ag_tick",
             "_at_tick", "_AG_START", "selftest_autogain", "_load_json_ag"}
SDR_ASSIGNS = {"AG_FILE", "AG_REQ", "AG_TICK_S", "AG_CHECK_S", "AG_RETRY_S", "AG_NIGHT", "AG_DAILY_S", "AG_ANYTIME_S", "AG_BAD_GAP_S", "AG_PEND_MAX_S", "AG_ERR_MAX", "AG_HIST_N", "AG_SESS_KEEP",
               "AG_DAY_ROUNDS", "AG_T2_LEVELS", "AG_T2_ROUNDS", "AG_LIMITS", "AG_FALLBACK", "_AG", "_ag_orig_air_gain_state", "_ag_orig_at_tick", "_ag_orig_at_finish", "_ag_orig_at_req_take",
               "_ag_orig_at_record", "_at_start", "AG_REQ_STALE_S_AG"}
OPEN_OK = {"_ag_load", "_ag_save", "selftest_autogain", "_load_json_ag"}
SM_FUNCS = {"ag_lbl", "ag_score", "_agn", "_agmean", "ag_stats", "ag_session", "_ag_lv", "ag_levels_for", "ag_best_fixed", "ag_decide", "ag_rows", "ag_rows_score", "ag_post_check", "ag_bad",
            "ag_req_put", "at_req_put2", "at_view", "_ag_cur_from_state", "ag_view", "selftest_autogain"}
DASH_FUNCS = {"_ag_view_now", "_ag_api", "_ag_airtest_api", "_ag_after", "_selftest_autogain_dash"}
DASH_ASSIGNS = {"_AGD", "_AG_CSS", "_AG_JS", "_AT_JS_SUBS"}
LZ_OK = {"ag_view", "at_view", "ag_levels_for", "ag_req_put", "at_req_put2"}


def _ids(t, ex_funcs=()):
    ids = set()
    for n in ast.walk(t):
        if isinstance(n, ast.FunctionDef) and n.name in ex_funcs:
            continue
        if isinstance(n, ast.Name):
            ids.add(n.id.lower())
        elif isinstance(n, ast.Attribute):
            ids.add(n.attr.lower())
        elif isinstance(n, (ast.FunctionDef, ast.alias)):
            ids.add(n.name.lower())
        elif isinstance(n, ast.ImportFrom) and n.module:
            ids.add(n.module.lower())
        elif isinstance(n, ast.arg):
            ids.add(n.arg.lower())
    return ids


def _funcs(t):
    return {f.name: f for f in t.body if isinstance(f, ast.FunctionDef)}


def _enclosing(t):
    m = {}
    for f in ast.walk(t):
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                m.setdefault(id(x), f.name)
    return m


def _net(t, tag):
    err = []
    ids = _ids(t)
    for w in NET:
        hit = sorted(c for c in ids if w in c)
        if hit:
            err.append("%s: verbotener Bezeichner '%s' (%s)" % (tag, w, ",".join(hit[:3])))
    for w in EXACT_BAD & ids:
        err.append("%s: verbotener Aufruf %s" % (tag, w))
    return err


def _top(t, funcs, assigns, tag, tries=0, allow_sub=False):
    err = []
    names = {x.name for x in t.body if isinstance(x, ast.FunctionDef)}
    if names != funcs:
        err.append("%s: Funktionen +%s -%s" % (tag, sorted(names - funcs), sorted(funcs - names)))
    nt = 0
    for n in t.body:
        if isinstance(n, ast.Assign):
            tg = n.targets[0]
            nm = tg.id if isinstance(tg, ast.Name) else (ast.unparse(tg) if allow_sub and isinstance(tg, ast.Subscript) else ast.unparse(tg))
            if nm not in assigns and not (allow_sub and nm == "AIR2_SOAPY_GAIN[-1]"):
                err.append("%s: Zuweisung auf Ebene 0: %s" % (tag, nm))
        elif isinstance(n, ast.FunctionDef):
            if n.decorator_list:
                err.append("%s: Dekorator an %s" % (tag, n.name))
        elif isinstance(n, ast.Try):
            nt += 1
        else:
            err.append("%s: Anweisung auf Ebene 0: %s" % (tag, type(n).__name__))
    if nt != tries:
        err.append("%s: %d Registrierungs-try statt %d" % (tag, nt, tries))
    return err


def _const(t, name):
    for n in t.body:
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == name:
            try:
                return ast.literal_eval(n.value)
            except Exception:
                return None
    return None


def _calls(node, name):
    out = []
    for n in ast.walk(node):
        if isinstance(n, ast.Call):
            f = n.func
            if (isinstance(f, ast.Name) and f.id == name) or (isinstance(f, ast.Attribute) and f.attr == name):
                out.append(n)
    return out


def check_sdr(B):
    err = []
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        return ["prepper_sdr-Block: Syntax %s" % e]
    tag = "prepper_sdr-Block"
    err += _net(t, tag)
    err += _top(t, SDR_FUNCS, SDR_ASSIGNS, tag, 0, True)
    en = _enclosing(t)
    F = _funcs(t)
    if _const(t, "AG_FALLBACK") != 16:
        err.append("%s: AG_FALLBACK ist nicht 16" % tag)
    if _const(t, "AG_ERR_MAX") != 3:
        err.append("%s: AG_ERR_MAX ist nicht 3" % tag)
    for n in ast.walk(t):
        fn = en.get(id(n), "?")
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            mods = [x.name for x in n.names] if isinstance(n, ast.Import) else [n.module]
            if not all(m in ("tempfile", "threading", "sdr_manager") for m in mods):
                err.append("%s: Import %s in %s" % (tag, mods, fn))
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if nm == "open" and fn not in OPEN_OK:
                err.append("%s: open() in %s" % (tag, fn))
            if nm in ("remove", "unlink", "rmtree", "rename") and fn != "selftest_autogain":
                err.append("%s: %s() in %s" % (tag, nm, fn))
            if nm in ("replace", "fsync") and isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "os" and fn != "_ag_save":
                err.append("%s: os.%s in %s" % (tag, nm, fn))
            if nm == "update" and any(k.arg == "cur" for k in n.keywords) and fn not in ("_ag_set_gain", "selftest_autogain"):
                err.append("%s: Gain-Zustand (cur=) in %s gesetzt" % (tag, fn))
            if nm == "_ag_set_gain" and fn not in ("_ag_apply_pending", "selftest_autogain", "_ag_set_gain"):
                err.append("%s: _ag_set_gain aufgerufen aus %s" % (tag, fn))
        if isinstance(n, ast.Assign):
            for tg in n.targets:
                if isinstance(tg, ast.Attribute) and isinstance(tg.value, ast.Name) and tg.value.id == "Planner":
                    err.append("%s: Planner.%s ueberschrieben (in %s)" % (tag, tg.attr, fn))
                if isinstance(tg, ast.Name) and tg.id in ("dabgain_step", "wd_check", "_wd_block", "sub_done", "step") and fn == "?":
                    err.append("%s: %s ueberschrieben" % (tag, tg.id))
                if isinstance(tg, ast.Subscript) and isinstance(tg.value, ast.Name) and tg.value.id in ("gs", "gs0") and ast.unparse(tg.slice) in ("'cur'", "\"cur\"") and fn != "selftest_autogain":
                    err.append("%s: Gain-Zustand gs['cur'] in %s gesetzt" % (tag, fn))
                if isinstance(tg, ast.Subscript) and isinstance(tg.value, ast.Name) and tg.value.id == "G" and fn != "selftest_autogain":
                    err.append("%s: globals-Zuweisung ausserhalb des Selbsttests (%s)" % (tag, fn))
                if isinstance(tg, ast.Subscript) and ast.unparse(tg) in ("_AG['on']", '_AG["on"]') and isinstance(n.value, ast.Constant) and n.value.value is True and fn not in ("_AG_START", "selftest_autogain"):
                    err.append("%s: Automatik eingeschaltet in %s" % (tag, fn))
    # Gain-Wechsel nur nach der Sperrpruefung
    ap = F.get("_ag_apply_pending")
    if ap is None:
        err.append("%s: _ag_apply_pending fehlt" % tag)
    else:
        cb = [c.lineno for c in _calls(ap, "_ag_blocked")]
        cs = [c.lineno for c in _calls(ap, "_ag_set_gain")]
        if len(cb) != 1 or len(cs) != 1 or not cb[0] < cs[0]:
            err.append("%s: _ag_set_gain nicht genau einmal NACH _ag_blocked in _ag_apply_pending" % tag)
        else:
            okif = False
            for n in ast.walk(ap):
                if isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == "b" and cb[0] < n.lineno < cs[0] and any(isinstance(x, ast.Return) for x in n.body):
                    okif = True
            if not okif:
                err.append("%s: keine Rueckkehr bei Sperre zwischen _ag_blocked und _ag_set_gain" % tag)
    bl = F.get("_ag_blocked")
    if bl is None:
        err.append("%s: _ag_blocked fehlt" % tag)
    else:
        ids = _ids(bl)
        for need in ("_wd_block", "_at_chk_live", "_at", "_wd", "cfg_serial"):
            if need not in ids:
                err.append("%s: _ag_blocked prueft %s nicht" % (tag, need))
        okx = False
        for n in ast.walk(bl):
            if isinstance(n, ast.ExceptHandler):
                for r in ast.walk(n):
                    if isinstance(r, ast.Return) and r.value is not None and not (isinstance(r.value, ast.Constant) and r.value.value is None):
                        okx = True
        if not okx:
            err.append("%s: Pruef-Fehler in _ag_blocked ist nicht gesperrt" % tag)
    st = F.get("_ag_start")
    if st is None or not _calls(st, "_at_refuse"):
        err.append("%s: _ag_start ohne _at_refuse" % tag)
    else:
        ln = [n.lineno for n in ast.walk(st) if isinstance(n, ast.Assign) and any(isinstance(x, ast.Subscript) and ast.unparse(x) in ("_AT['run']", '_AT["run"]') for x in n.targets)]
        if not ln or not min(_c.lineno for _c in _calls(st, "_at_refuse")) < min(ln):
            err.append("%s: Messung startet vor _at_refuse" % tag)
    fa = F.get("_ag_fault")
    if fa is None or not _calls(fa, "_ag_lock") or "ag_fallback" not in _ids(fa):
        err.append("%s: _ag_fault sperrt nicht auf AG_FALLBACK" % tag)
    lk = F.get("_ag_lock")
    if lk is None or "pending" not in ast.unparse(lk):
        err.append("%s: _ag_lock setzt keine Rueckkehr (pending)" % tag)
    tk = F.get("_ag_tick")
    if tk is None or not _calls(tk, "_ag_fault") or "ag_err_max" not in _ids(tk) or "_ag_run" not in _ids(tk):
        err.append("%s: _ag_tick ohne Fehlerzaehler/Rueckfall" % tag)
    stt = F.get("selftest_autogain")
    if stt is None:
        err.append("%s: Selbsttest fehlt" % tag)
    else:
        s = ast.unparse(stt)
        for w in ("flipflop", "worse", "fehler", "unlesbar", "Nachtfenster"):
            if w not in s:
                err.append("%s: Selbsttest deckt '%s' nicht ab" % (tag, w))
        for w in ("PTY 31", "ASA", "Antennentest", "Meteor", "Alarm"):
            if "'%s' in _ag_blocked(" % w not in s:
                err.append("%s: Selbsttest prueft die echte Sperre '%s' nicht" % (tag, w))
    if not B.splitlines()[0].startswith("# ===== autoGain:"):
        err.append("%s: Marker fehlt" % tag)
    return err


def check_dash(B):
    err = []
    tag = "Dashboard-Block"
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        return ["Dashboard-Block: Syntax %s" % e]
    err += _net(t, tag)
    if "open" in _ids(t):
        err.append("%s: open()" % tag)
    err += _top(t, DASH_FUNCS, DASH_ASSIGNS, tag, 1)
    en = _enclosing(t)
    F = _funcs(t)
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            mods = [x.name for x in n.names] if isinstance(n, ast.Import) else [n.module]
            if mods != ["flask"]:
                err.append("%s: Import %s" % (tag, mods))
        if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "_lz_mgr" and n.attr not in LZ_OK:
            err.append("%s: _lz_mgr.%s nicht erlaubt" % (tag, n.attr))
    for fname, put, vals in (("_ag_api", "ag_req_put", "('auto', 'fest', 'measure')"), ("_ag_airtest_api", "at_req_put2", "('start', 'stop')")):
        f = F.get(fname)
        if f is None:
            err.append("%s: %s fehlt" % (tag, fname)); continue
        cc = [c.lineno for c in _calls(f, "_t2d_check")]
        pc = [c for c in _calls(f, put)]
        if len(cc) != 1 or len(pc) != 1 or not cc[0] < pc[0].lineno:
            err.append("%s: %s: %s nicht genau einmal NACH _t2d_check" % (tag, fname, put))
            continue
        if vals not in ast.unparse(f):
            err.append("%s: %s: Wertepruefung %s fehlt" % (tag, fname, vals))
        inw = False
        for w in ast.walk(f):
            if isinstance(w, ast.With) and "_T2D_LOCK" in ast.unparse(w.items[0]) and any(x is pc[0] for x in ast.walk(w)):
                inw = True
        if not inw:
            err.append("%s: %s: %s nicht unter _T2D_LOCK" % (tag, fname, put))
        if not any(isinstance(x, ast.Compare) and "rq.method" in ast.unparse(x) for x in ast.walk(f)):
            err.append("%s: %s: keine Methodenpruefung" % (tag, fname))
    if "airtest_api" not in B or B.count("app.view_functions[\"airtest_api\"] = _ag_airtest_api") != 1:
        err.append("%s: airtest_api nicht genau einmal neu gebunden" % tag)
    if B.count("app.add_url_rule(") != 1 or '"/api/sdr/autogain"' not in B or 'methods=["GET", "POST"]' not in B:
        err.append("%s: Route /api/sdr/autogain nicht genau einmal mit GET+POST" % tag)
    if B.count("app.after_request(_ag_after)") != 1:
        err.append("%s: after_request nicht genau einmal" % tag)
    af = F.get("_ag_after")
    if af is None or 'rq.path != "/funk"' not in ast.unparse(af).replace("'", '"'):
        err.append("%s: _ag_after nicht auf /funk begrenzt" % tag)
    g = {}
    m = re.search(r'^_AG_JS = r"""(.*?)"""$', B, re.S | re.M)
    js = m.group(1) if m else ""
    if not js:
        err.append("%s: _AG_JS fehlt" % tag)
    else:
        for bad in ("innerHTML", "eval(", "localStorage", ".click()", "insertAdjacentHTML", "document.write", "outerHTML", "new Function", "XMLHttpRequest", "WebSocket", "sendBeacon"):
            if bad in js:
                err.append("%s: JS enthaelt %s" % (tag, bad))
        if js.count("fetch(") != 2 or js.count("window.confirm(") != 1 or js.count("X-T2") != 1 or js.count("method:'POST'") != 1 or js.count("post('/api/sdr/") != 4:
            err.append("%s: JS: fetch/confirm/POST-Zahl falsch" % tag)
        if "confirm:true" in js.replace(" ", "") or "body.confirm=true" not in js:
            err.append("%s: JS: confirm nur ueber post() nach window.confirm" % tag)
    css = re.search(r'^_AG_CSS = """(.*?)"""$', B, re.S | re.M)
    if not css or "minmax(0,1fr)" not in css.group(1) or ".grid>*{min-width:0" not in css.group(1):
        err.append("%s: Kachelbreiten-Regel (minmax(0,1fr)/min-width:0) fehlt" % tag)
    if not B.splitlines()[0].startswith("# ===== autoGain:"):
        err.append("%s: Marker fehlt" % tag)
    return err


def _load_mod(path, deps_from):
    d = tempfile.mkdtemp(prefix="agg-")
    try:
        for f in os.listdir(deps_from):
            if f.endswith(".py") and f not in ("sdr_manager.py", "prepper_sdr.py", "dashboard.py"):
                shutil.copy(os.path.join(deps_from, f), d)
        shutil.copy(path, os.path.join(d, "sdr_manager.py"))
        sys.path.insert(0, d)
        sys.modules.pop("sdr_manager", None)
        try:
            spec = importlib.util.spec_from_file_location("sdr_manager", os.path.join(d, "sdr_manager.py"))
            mod = importlib.util.module_from_spec(spec)
            sys.modules["sdr_manager"] = mod
            spec.loader.exec_module(mod)
            return mod, d
        finally:
            sys.path.remove(d)
    except Exception as e:
        shutil.rmtree(d, ignore_errors=True)
        raise e


def props(M):
    """Eigenschaften der Datenschicht am echten Modul."""
    err = []
    lv = lambda **sc: {str(k): {"n": 3, "sync_n": 3, "sync_pct": 100.0, "score": float(v), "fic": 1.0, "snr": 12.0} for k, v in sc.items()}
    S = lambda *a: [{"t": 1790000000 + 86400 * i, "id": i, "profile": "day", "cur": 16, "levels": lv(**x)} for i, x in enumerate(a)]
    if not (M.AG_W_FIC > 2 * M.AG_W_SNR and M.AG_W_FIC >= 5):
        err.append("Datenschicht: FIC nicht am staerksten gewichtet")
    if not (M.ag_score(True, 12.0, 3.0) < M.ag_score(True, 9.0, 2.0)):
        err.append("Datenschicht: Score: 1 % FIC-Fehler zaehlt weniger als 3 dB SNR")
    if M.AG_MAX_CHANGES != 2 or M.AG_FLIP_S != 48 * 3600:
        err.append("Datenschicht: Flip-Flop-Grenze nicht 2 Wechsel in 48 h")
    if M.AG_SESS_N < 3 or M.AG_MIN_N < 2 or M.AG_MARGIN < 5:
        err.append("Datenschicht: Entscheidung nicht ueber mehrere Sitzungen mit klarem Abstand")
    now = 1790000000 + 86400 * 5
    r = M.ag_decide(S({"16": 70, "14": 85}), 16, now, [])
    if r["action"] != "none":
        err.append("Datenschicht: Wechsel nach nur 1 Sitzung")
    r = M.ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 72}), 16, now, [])
    if r["action"] != "none":
        err.append("Datenschicht: Wechsel ohne klaren Vorteil in mehreren Sitzungen")
    r = M.ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16, now, [])
    if not (r["action"] == "switch" and r["to"] == 14):
        err.append("Datenschicht: klarer Vorteil wird nicht erkannt")
    r = M.ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 73}, {"16": 70, "14": 72}), 16, now, [])
    if r["action"] != "none":
        err.append("Datenschicht: Wechsel bei Vorteil in nur 1 von 3 Sitzungen")
    r = M.ag_decide(S({"16": 70, "-1": 99, "14": 85}, {"16": 71, "-1": 99, "14": 84}), 16, now, [])
    if r["action"] == "switch" and r["to"] < 0 or r.get("to") == -1:
        err.append("Datenschicht: Auto (-1) wurde Ziel")
    r = M.ag_decide(S({"16": 70, "-1": 99}, {"16": 71, "-1": 99}), 16, now, [])
    if r["action"] != "none":
        err.append("Datenschicht: nur Auto besser: Wechsel auf Auto")
    if M.ag_best_fixed(S({"16": 60, "-1": 99, "14": 70}, {"16": 61, "-1": 99, "14": 71}), 16) < 0:
        err.append("Datenschicht: bester fester Wert = Auto")
    ch = [now - 3600, now - 7200 - 3600 * 8]
    r = M.ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16, now, ch)
    if r["action"] != "lock" or r["to"] is None or r["to"] < 0:
        err.append("Datenschicht: mehr als 2 Wechsel in 48 h sperren nicht")
    r = M.ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), 16, now, [now - 3 * 3600], now - 3 * 3600)
    if r["action"] != "none":
        err.append("Datenschicht: Mindestabstand zwischen Wechseln fehlt")
    r = M.ag_decide(S({"16": 70, "14": 85}, {"16": 71, "14": 84}), "agc", now, [])
    if r["action"] != "none":
        err.append("Datenschicht: Entscheidung trotz Notstufe der Gain-Leiter")
    if M.ag_post_check({"n": 40, "score": 90.0, "sync_pct": 100.0}, {"n": 20, "score": 50.0, "sync_pct": 100.0}) != "worse":
        err.append("Datenschicht: schlechterer Empfang nach Wechsel nicht erkannt")
    if M.ag_post_check({"n": 40, "score": 90.0, "sync_pct": 100.0}, {"n": 3, "score": 10.0, "sync_pct": 0.0}) != "watch":
        err.append("Datenschicht: Vergleich mit zu wenig Pruefungen")
    for x in (None, "x", 5, {}, {"levels": 3}):
        try:
            M.ag_session(x)
            M.ag_levels_for(x)
            M.ag_rows_score(x)
        except Exception as e:
            err.append("Datenschicht: wirft bei Muellwerten: %s" % e)
    d = tempfile.mkdtemp(prefix="agv-")
    try:
        open(os.path.join(d, M.AG_FILE), "w").write("{kaputt")
        v = M.ag_view(d)
        if not isinstance(v, dict) or "ok" not in v:
            err.append("Datenschicht: ag_view bei kaputter Datei")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return err


def check_sm(B, path=None, deps=None):
    err = []
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        return ["sdr_manager-Block: Syntax %s" % e]
    tag = "sdr_manager-Block"
    err += _net(t, tag)
    en = _enclosing(t)
    names = {x.name for x in t.body if isinstance(x, ast.FunctionDef)}
    if names != SM_FUNCS:
        err.append("%s: Funktionen +%s -%s" % (tag, sorted(names - SM_FUNCS), sorted(SM_FUNCS - names)))
    for n in t.body:
        if isinstance(n, (ast.Expr, ast.Import, ast.ImportFrom, ast.Try, ast.With, ast.For, ast.If)):
            err.append("%s: Anweisung auf Ebene 0: %s" % (tag, type(n).__name__))
    for n in ast.walk(t):
        fn = en.get(id(n), "?")
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if nm == "open" and fn not in ("ag_req_put", "at_req_put2", "selftest_autogain"):
                err.append("%s: open() in %s" % (tag, fn))
            if nm in ("remove", "unlink", "rmtree", "rename") and fn != "selftest_autogain":
                err.append("%s: %s() in %s" % (tag, nm, fn))
            if nm == "execute" and fn not in ("ag_rows", "selftest_autogain"):
                err.append("%s: SQL in %s" % (tag, fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and re.search(r"\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|REPLACE)\b", n.value) and fn not in ("selftest_autogain",):
            err.append("%s: SQL-Schreibzugriff in %s" % (tag, fn))
    if not B.splitlines()[0].startswith("# ===== autoGain:"):
        err.append("%s: Marker fehlt" % tag)
    if path and not err:
        try:
            mod, d = _load_mod(path, deps)
            try:
                err += props(mod)
            finally:
                shutil.rmtree(d, ignore_errors=True)
        except Exception as e:
            err.append("sdr_manager: laedt/Eigenschaften scheitern: %s" % e)
    return err


def _revert(new, blk, edits, anchor_kind):
    B = blk.rstrip("\n") + "\n"
    i = new.find("\n\n" + B.rstrip("\n"))
    if i < 0 or new.count(B.rstrip("\n")) != 1:
        return None
    s = new[:i] + new[i + 2 + len(B.rstrip("\n")):]
    for o, n in edits:
        if s.count(n) != 1:
            return None
        s = s.replace(n, o, 1)
    return s


def revert_dir(src, blkdir, edp, out):
    """Stand im Ordner SRC -> Basis in OUT: Dateien mit Block autoGain werden zurueckgebaut (Block weg, Stellen zurueck), die anderen unveraendert kopiert. Fehler -> Liste."""
    err = []
    g = {}
    exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
    os.makedirs(out, exist_ok=True)
    for f, bf, ek in (("sdr_manager.py", "ag_sm_block.py", "SM_EDITS"), ("prepper_sdr.py", "ag_sdr_block.py", "SDR_EDITS"), ("dashboard.py", "ag_dash_block.py", "DSH_EDITS")):
        s = open(os.path.join(src, f), encoding="utf-8").read()
        blk = open(os.path.join(blkdir, bf), encoding="utf-8").read()
        if blk.splitlines()[0] in s:
            r = _revert(s, blk, g[ek], f)
            if r is None:
                err.append("%s: Block autoGain nicht sauber entfernbar" % f)
                continue
            s = r
        with open(os.path.join(out, f), "w", encoding="utf-8") as fo:
            fo.write(s)
    return err


def check(alt, neu, blkdir, edp):
    err = []
    g = {}
    exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
    for k, v in EXPECTED.items():
        if [tuple(x) for x in g[k]] != [tuple(x) for x in v]:
            err.append("Stellen %s weichen von den erwarteten ab" % k)
    for a in ("SM_ANCHOR", "SDR_ANCHOR", "DSH_ANCHOR"):
        if g[a] != ANCH:
            err.append("%s weicht ab" % a)
    blks = {k: open(os.path.join(blkdir, f), encoding="utf-8").read() for k, f in (("sm", "ag_sm_block.py"), ("sdr", "ag_sdr_block.py"), ("dsh", "ag_dash_block.py"))}
    for k, fname, ek in (("sm", "sdr_manager.py", "SM_EDITS"), ("sdr", "prepper_sdr.py", "SDR_EDITS"), ("dsh", "dashboard.py", "DSH_EDITS")):
        a = open(os.path.join(alt, fname), encoding="utf-8").read()
        n = open(os.path.join(neu, fname), encoding="utf-8").read()
        r = _revert(n, blks[k], g[ek], k)
        if r is None or r != a:
            err.append("%s: anders geaendert als nur durch Block autoGain + Stellen (Rueckbau ergibt nicht die Basis)" % fname)
        for m in re.findall(r"^# ===== ([A-Za-z0-9]+):", n, re.M)[-1:]:
            pass
    err += check_sm(blks["sm"], os.path.join(neu, "sdr_manager.py"), neu)
    err += check_sdr(blks["sdr"])
    err += check_dash(blks["dsh"])
    return err, {k: len(v.splitlines()) for k, v in blks.items()}


def mutants():
    """(Name, Art, alt, neu) - alt muss im Block genau einmal vorkommen."""
    return [
        ("Sperrpruefung vor Wechsel entfernt", "sdr", "    b = _ag_blocked(pl, now)\n    if b:", "    b = None\n    if b:"),
        ("keine Rueckkehr bei Sperre", "sdr", "            pl.log(\"autoGain: Wechsel auf %s wartet - %s\" % (_ag_lbl(pd.get(\"to\")), b))\n        return False", "            pl.log(\"autoGain: Wechsel auf %s wartet - %s\" % (_ag_lbl(pd.get(\"to\")), b))\n        pass"),
        ("Wechsel aus dem Takt", "sdr", "    _AG[\"t_next\"] = now + AG_TICK_S\n", "    _AG[\"t_next\"] = now + AG_TICK_S\n    _ag_set_gain(pl, _AG['st'], 12, now, 'x', 'x', True)\n"),
        ("Gain-Zustand direkt gesetzt", "sdr", "    st = _AG[\"st\"]\n    gs = _air_gain_state(pl)\n", "    st = _AG[\"st\"]\n    gs = _air_gain_state(pl)\n    gs.update(cur=12)\n"),
        ("Planner.step umhuellt", "sdr", "_at_start = _ag_start\n", "_at_start = _ag_start\nPlanner.step = _ag_tick\n"),
        ("dabgain_step umhuellt", "sdr", "_at_start = _ag_start\n", "_at_start = _ag_start\ndabgain_step = _ag_tick\n"),
        ("Sperr-Pruefung ohne _wd_block", "sdr", "        b = _wd_block(pl, now, cfg_serial(pl.cfg), None)\n        if b:\n            return b\n        if _WD.get(\"busy\"):\n            return \"USB-Neuverbindung läuft\"\n        return None\n    except", "        if _WD.get(\"busy\"):\n            return \"USB-Neuverbindung läuft\"\n        return None\n    except"),
        ("Pruef-Fehler nicht gesperrt", "sdr", "        return \"Sperr-Prüfung fehlgeschlagen (%s)\" % str(e)[:60]", "        return None"),
        ("laufende Messung nicht gesperrt", "sdr", "        if _AT[\"run\"] is not None or _at_chk_live(now):\n            return \"Gain-Test/Messung läuft\"\n", ""),
        ("Rueckfall nicht 16", "sdr", "AG_FALLBACK = 16\n", "AG_FALLBACK = 14\n"),
        ("Fehlerzaehler 10", "sdr", "AG_ERR_MAX = 3 ", "AG_ERR_MAX = 10 "),
        ("Fault ohne Sperre", "sdr", "    _ag_lock(st, now, \"fehler\", \"Fehler in der Gain-Logik (%s) - Rueckfall auf Stufe %d\" % (str(why)[:100], AG_FALLBACK), AG_FALLBACK)\n", "    st[\"lock\"] = None\n"),
        ("Lock ohne Rueckkehr", "sdr", "    st[\"pending\"] = {\"to\": fixed, \"kind\": \"lock\" if kind == \"flipflop\" else \"revert\", \"why\": str(why)[:240], \"t\": int(now)}\n", ""),
        ("Automatik am Modulende an", "sdr", "def _AG_START(base):\n", "_AG[\"on\"] = True\n\n\ndef _AG_START(base):\n"),
        ("Automatik im Tick an", "sdr", "    if not _AG[\"on\"] or not _at_is_air(pl):\n        return\n    a = _air_pl(pl)", "    _AG[\"on\"] = True\n    if not _AG[\"on\"] or not _at_is_air(pl):\n        return\n    a = _air_pl(pl)"),
        ("Start ohne _at_refuse", "sdr", "    why = _at_refuse(pl, now)\n    if why:\n        d0[\"msg\"]", "    why = None\n    if why:\n        d0[\"msg\"]"),
        ("subprocess", "sdr", "def _ag_err(what, e):\n", "def _ag_err(what, e):\n    import subprocess\n"),
        ("os.system", "sdr", "def _ag_err(what, e):\n", "def _ag_err(what, e):\n    os.system('x')\n"),
        ("Mesh-Versand", "sdr", "def _ag_err(what, e):\n", "def _ag_err(what, e):\n    send_meshtastic('x')\n"),
        ("open ausserhalb", "sdr", "def _ag_err(what, e):\n", "def _ag_err(what, e):\n    open('/tmp/x', 'w')\n"),
        ("fremde Funktion", "sdr", "def _ag_err(what, e):\n", "def helper():\n    return 1\n\n\ndef _ag_err(what, e):\n"),
        ("Ebene-0-Aufruf", "sdr", "def _ag_err(what, e):\n", "print('x')\n\n\ndef _ag_err(what, e):\n"),
        ("Selbsttest ohne echte PTY-31-Sperre", "sdr", "        assert \"PTY 31\" in _ag_blocked(pl, t_night)\n", ""),
        ("Marker", "sdr", "# ===== autoGain: Gain-Automatik", "# ===== autoGainX: Gain-Automatik"),
        ("FIC nicht am staerksten", "sm", "AG_W_FIC = 6.0 ", "AG_W_FIC = 1.0 "),
        ("3 Wechsel erlaubt", "sm", "AG_MAX_CHANGES = 2 ", "AG_MAX_CHANGES = 3 "),
        ("Flip-Flop-Fenster 4 h", "sm", "AG_FLIP_S = 48 * 3600", "AG_FLIP_S = 4 * 3600"),
        ("Auto wird Ziel", "sm", "                    if int(k) >= 0 and int(k) != cur:", "                    if int(k) != cur:"),
        ("bester fester Wert Auto", "sm", "                if int(k) >= 0:\n                    lv.add(int(k))", "                lv.add(int(k))"),
        ("Vorteil nur in 1 Sitzung", "sm", "ok = wins >= 2 and md >= AG_MARGIN", "ok = wins >= 1 and md >= AG_MARGIN"),
        ("Vorteil nur 1 Punkt", "sm", "AG_MARGIN = 6.0 ", "AG_MARGIN = 1.0 "),
        ("Sperre ohne Pruefung", "sm", "        if n48 >= AG_MAX_CHANGES:", "        if n48 >= 99:"),
        ("kein Mindestabstand", "sm", "        if isinstance(last_change_t, (int, float)) and now - last_change_t < AG_MIN_GAP_S:", "        if False:"),
        ("schlechter nach Wechsel nie erkannt", "sm", "        if post[\"score\"] < pre[\"score\"] - AG_WORSE", "        if False and post[\"score\"] < pre[\"score\"] - AG_WORSE"),
        ("SQL schreiben", "sm", "def ag_rows(base, t0, t1, windows=None):\n", "def ag_rows(base, t0, t1, windows=None):\n    x = 'DELETE FROM reception_log'\n"),
        ("sm subprocess", "sm", "def ag_lbl(g):\n", "def ag_lbl(g):\n    import subprocess\n"),
        ("sm open ausserhalb", "sm", "def ag_lbl(g):\n", "def ag_lbl(g):\n    open('/tmp/x', 'w')\n"),
        ("Dash ohne _t2d_check", "dsh", "        err, j = _t2d_check(rq)\n        if err:\n            return jsonify({\"ok\": False, \"error\": err}), j\n        act = j.get(\"action\")\n        if act not in (\"auto\", \"fest\", \"measure\"):", "        j = rq.get_json(silent=True) or {}\n        act = j.get(\"action\")\n        if act not in (\"auto\", \"fest\", \"measure\"):"),
        ("Dash ohne Lock", "dsh", "        with _T2D_LOCK:\n            r = _lz_mgr.ag_req_put(_SDR_BASE, act, \"dashboard\")", "        if True:\n            r = _lz_mgr.ag_req_put(_SDR_BASE, act, \"dashboard\")"),
        ("Dash Wertepruefung weg", "dsh", "        if act not in (\"auto\", \"fest\", \"measure\"):", "        if False:"),
        ("Dash GET schreibt", "dsh", "        if rq.method != \"POST\":\n            return jsonify(_ag_view_now())", "        if False:\n            return jsonify(_ag_view_now())"),
        ("Dash fremde lz-Funktion", "dsh", "        r = _lz_mgr.ag_req_put(_SDR_BASE, act, \"dashboard\")", "        r = _lz_mgr.takeover_set(_SDR_BASE, True, 'x', 'x', 'x')"),
        ("Dash innerHTML", "dsh", "c.textContent='';", "c.innerHTML='';"),
        ("Dash eval", "dsh", "function p2(n)", "var q=eval('1');function p2(n)"),
        ("Dash weiteres fetch", "dsh", "function load(){fetch('/api/sdr/autogain'", "function load(){fetch('/x');fetch('/api/sdr/autogain'"),
        ("Dash confirm ohne Rueckfrage", "dsh", "if(!window.confirm(ask))return;", ""),
        ("Dash Raster-Regel weg", "dsh", ".grid>*{min-width:0;max-width:100%}", ".grid>*{max-width:100%}"),
        ("Dash requests", "dsh", "def _ag_view_now():\n", "def _ag_view_now():\n    import requests\n"),
        ("Dash open", "dsh", "def _ag_view_now():\n", "def _ag_view_now():\n    open('/tmp/x')\n"),
        ("Dash Route POST-only", "dsh", "methods=[\"GET\", \"POST\"]", "methods=[\"GET\"]"),
        ("Dash ohne /funk-Begrenzung", "dsh", "        if rq.path != \"/funk\" or resp.status_code != 200", "        if resp.status_code != 200"),
    ]


def mutate(neu, blkdir, edp):
    blks = {k: open(os.path.join(blkdir, f), encoding="utf-8").read().rstrip("\n") + "\n" for k, f in (("sm", "ag_sm_block.py"), ("sdr", "ag_sdr_block.py"), ("dsh", "ag_dash_block.py"))}
    e0, _ = check(neu, neu, blkdir, edp) if False else (None, None)
    smp = os.path.join(neu, "sdr_manager.py")
    base_err = check_sm(blks["sm"], smp, neu) + check_sdr(blks["sdr"]) + check_dash(blks["dsh"])
    if base_err:
        print("Mutationstest: Ausgangsbloecke schon beanstandet: %s" % base_err[:3]); return 1
    miss, n = [], 0
    newsm = open(smp, encoding="utf-8").read()
    for name, kind, o, nw in mutants():
        B = blks[kind]
        if B.count(o) != 1:
            print("Mutation %s: Fundstelle %d-mal (muss genau 1 sein)" % (name, B.count(o))); return 1
        M = B.replace(o, nw, 1)
        try:
            ast.parse(M)
        except SyntaxError as e:
            print("Mutation %s: eigener Syntaxfehler %s" % (name, e)); return 1
        n += 1
        if kind == "sdr":
            hit = check_sdr(M)
        elif kind == "dsh":
            hit = check_dash(M)
        else:
            d = tempfile.mkdtemp(prefix="aggm-")
            try:
                src = newsm.replace(blks["sm"].rstrip("\n"), M.rstrip("\n"), 1)
                if src == newsm:
                    print("Mutation %s: Block nicht gefunden" % name); return 1
                p = os.path.join(d, "sdr_manager.py")
                open(p, "w", encoding="utf-8").write(src)
                hit = check_sm(M, p, neu)
            finally:
                shutil.rmtree(d, ignore_errors=True)
        if not hit:
            miss.append(name)
    g = {}
    exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
    for k in ("SM_EDITS", "SDR_EDITS"):
        for i in range(len(g[k])):
            for how in ("entfernt", "geaendert"):
                n += 1
                E = [x for j, x in enumerate(g[k]) if j != i] if how == "entfernt" else [(o, nw + "# x\n") if j == i else (o, nw) for j, (o, nw) in enumerate(g[k])]
                if [tuple(x) for x in E] == [tuple(x) for x in EXPECTED[k]]:
                    miss.append("Stelle %s[%d] %s" % (k, i, how))
    n += 1
    if [tuple(x) for x in g["DSH_EDITS"] + [("a", "b")]] == [tuple(x) for x in EXPECTED["DSH_EDITS"]]:
        miss.append("zusaetzliche Dashboard-Stelle")
    if miss:
        print("Mutationstest FEHLER: nicht erkannt: %s" % ", ".join(miss)); return 1
    print("OK AST-Guard autoGain: Mutationstest %d/%d Verfehlungen erkannt (Sperrpruefung vor Gain-Wechsel, Rueckkehr bei Sperre, Planner-/dabgain-Umhuellung, Netz/Datei/Prozess/Mesh, Rueckfall 16, Automatik nur im Dienst, Auto nie Ziel, Flip-Flop, Mindestabstand, SQL nur lesen, Dashboard-POST-Regeln, JS, Kachelbreite, Stellen)" % (n, n))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 5 and a[0] == "check":
        e, nl = check(a[1], a[2], a[3], a[4])
        if e:
            print("AST-Guard autoGain VERSTOSS:\n  " + "\n  ".join(e)); raise SystemExit(1)
        print("OK AST-Guard autoGain: Rueckbau = Basis (Byte fuer Byte, 3 Dateien), Bloecke %d/%d/%d Zeilen (sdr_manager/prepper_sdr/Dashboard), Gain-Wechsel nur nach Sperrpruefung, keine Umhuellung der Planer-Funktionen, kein Netz/Mesh/Prozess, Rueckfall Stufe 16, Auto nie Ziel, Flip-Flop-Eigenschaften am echten Modul" % (nl["sm"], nl["sdr"], nl["dsh"]))
        raise SystemExit(0)
    if len(a) == 5 and a[0] == "revert":
        e = revert_dir(a[1], a[2], a[3], a[4])
        if e:
            print("Rueckbau autoGain FEHLER:\n  " + "\n  ".join(e)); raise SystemExit(1)
        print("Rueckbau autoGain ok (Basis fuer den AST-Guard)"); raise SystemExit(0)
    if len(a) == 4 and a[0] == "mutate":
        raise SystemExit(mutate(a[1], a[2], a[3]))
    print("Aufruf: check ALT NEU BLK EDITS | mutate NEU BLK EDITS | revert SRC BLK EDITS OUT"); raise SystemExit(2)
AGD_EOF
EXPECT_AGC="1baeab375f8e0cd399a83c5019abd2887d672811ba8ad0d2432cb728730f6393"
cat > "$W/agcheck.py" << 'AGC_EOF'
#!/usr/bin/env python3
"""agcheck.py - Pruefungen fuer den Patch autoGain (nur lesen). Aufrufe:
  page FUNK.html                    /funk: Gain-Automatik-Karte (CSS/Daten/Skript), Raster minmax(0,1fr), Knoepfe
  api JSON                          /api/sdr/autogain: Felder, Modus, Verlauf
  atpage FUNK.html                  /funk: Karte Gain-Test (airTest) mit Gain-Test 1/2, Rueckfrage, neuer Text zum Standard-Gain
  at JSON                           /api/sdr/airtest: profile + score_rows
  state DIR                         sdr_autogain.json lesbar, v 1, Felder
  engine DIR T0 [ERWARTET_GAIN]     prepper-sdr hat den Zustand seit T0 geschrieben, kein Fehler, Gain wie erwartet
  gain DIR                          aktuelle Gain-Stufe des Airspy laut broadcast_state.json (nur Ausgabe)
  journal DATEI                     Journal prepper-sdr: autoGain-Zeilen, kein Traceback/Fehler
  tamper                            Selbsttest dieses Programms (erkennt kaputte Eingaben)"""
import json
import os
import re
import sys
import time

OK_MODES = ("auto", "fest")


def die(msg):
    print("FEHLER " + msg)
    sys.exit(1)


def jload(fn):
    try:
        with open(fn, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        die("%s nicht lesbar: %s" % (fn, str(e)[:80]))


def chk_page(txt):
    for k, m in (('id="ag-css"', "CSS-Block ag-css fehlt"), ('id="ag-data"', "Daten-Block ag-data fehlt"), ('id="ag-js"', "Skript ag-js fehlt"), ("minmax(0,1fr)", "Raster ohne minmax(0,1fr) (Kachelbreite)"),
                 ("Gain-Automatik", "Text Gain-Automatik fehlt"), ("Gain-Test 2 starten", "Knopf Gain-Test 2 fehlt"), ("Jetzt messen", "Knopf Jetzt messen fehlt"), ("agCard", "Karte agCard fehlt"),
                 ("/api/sdr/autogain", "Aufruf /api/sdr/autogain fehlt"), ("window.confirm", "Rueckfrage fehlt")):
        if k not in txt:
            die(m)
    if txt.count('id="ag-js"') != 1 or txt.count('id="ag-css"') != 1 or txt.count('id="ag-data"') != 1:
        die("autoGain-Bloecke doppelt eingefuegt")
    m = re.search(r'<script type="application/json" id="ag-data">(.*?)</script>', txt, re.S)
    try:
        d = json.loads(m.group(1))
    except Exception as e:
        die("ag-data ist kein JSON: %s" % str(e)[:60])
    if d.get("mode") not in OK_MODES or "cur_txt" not in d or "history" not in d:
        die("ag-data ohne mode/cur_txt/history")
    print("/funk: Karte Gain-Automatik (CSS, Daten, Skript je 1x), Raster minmax(0,1fr), Knoepfe Jetzt messen und Gain-Test 2, Rueckfrage; Modus %s, %s" % (d["mode"], d.get("cur_txt")))


def chk_atpage(txt):
    for k in ('id="airtest-js"', 'id="at-data"', 'id="airtest-css"'):
        if txt.count(k) != 1:
            die("airTest-Block %s %dx statt 1x" % (k, txt.count(k)))
    m = re.search(r'id="at-data">(.*?)</script>', txt, re.S)
    try:
        d = json.loads(m.group(1))
    except Exception as e:
        die("at-data kein JSON: %s" % str(e)[:60])
    js = txt[txt.index('id="airtest-js"'):]
    for k, msg in (("/api/sdr/airtest", "Aufruf /api/sdr/airtest fehlt"), ("window.confirm", "Rueckfrage fehlt"), ("Gain-Test 1 starten", "Knopf Gain-Test 1 fehlt"), ("der Test selbst", "Hinweis zum Standard-Gain fehlt"), ("Score", "Spalte Score fehlt")):
        if k not in js:
            die("Gain-Test-Karte: " + msg)
    if "Standard-Gain wird nie ge" in js:
        die("Gain-Test-Karte nennt noch die alte Aussage 'Standard-Gain wird nie geaendert' (stimmt mit der Gain-Automatik nicht mehr)")
    if d.get("ok") is not True:
        die("at-data ok nicht true")
    print("/funk: Karte Gain-Test (Daten ok, Gain-Test 1 und 2, Score-Spalte, Rueckfrage, Hinweis: der Test selbst aendert den Standard-Gain nie)")


def chk_api(d):
    if not isinstance(d, dict) or d.get("ok") is not True:
        die("api: ok nicht true (%s)" % (str(d.get("error"))[:60] if isinstance(d, dict) else type(d).__name__))
    for k in ("mode", "locked", "cur", "cur_txt", "history", "table", "txt", "engine", "stale", "changes_48h", "sessions"):
        if k not in d:
            die("api: Feld %s fehlt" % k)
    if d["mode"] not in OK_MODES or not isinstance(d["history"], list) or not isinstance(d["table"], list):
        die("api: Modus/Verlauf/Tabelle ungueltig")
    print("/api/sdr/autogain: Modus %s%s, %s, %d Sitzungen, %d Wechsel in 48 h, Engine %s" % (d["mode"], " (gesperrt)" if d["locked"] else "", d["cur_txt"], d["sessions"], d["changes_48h"], "ja" if d["engine"] else "noch nicht"))


def chk_at(d):
    if not isinstance(d, dict) or "profile" not in d or "score_rows" not in d:
        die("airtest-API ohne profile/score_rows")
    if not isinstance(d["score_rows"], list):
        die("airtest-API: score_rows keine Liste")
    print("/api/sdr/airtest: profile %s, %d Score-Zeilen (Gain-Test 1/2 und Auto werden unterstuetzt)" % (d.get("profile"), len(d["score_rows"])))


def chk_state(dirn, quiet=False):
    d = jload(os.path.join(dirn, "sdr_autogain.json"))
    if not isinstance(d, dict) or d.get("v") != 1 or d.get("mode") not in OK_MODES:
        die("sdr_autogain.json: Format (v/mode)")
    for k, t in (("history", list), ("sessions", list), ("changes", list)):
        if not isinstance(d.get(k), t):
            die("sdr_autogain.json: %s fehlt/falsch" % k)
    if not quiet:
        print("sdr_autogain.json: v1, Modus %s, Stufe %s, %d Sitzungen, %d Verlaufseintraege, Sperre %s, Fehler %s" % (d["mode"], d.get("cur"), len(d["sessions"]), len(d["history"]), "ja" if d.get("lock") else "nein", "ja" if d.get("fault") else "nein"))
    return d


def air_gain(dirn):
    st = jload(os.path.join(dirn, "broadcast_state.json"))
    for sn, x in ((st or {}).get("dabgain") or {}).items():
        if isinstance(x, dict) and x.get("air"):
            return x.get("cur")
    return None


def chk_engine(dirn, t0, want):
    d = chk_state(dirn, True)
    if float(d.get("t_upd") or 0) < t0:
        die("prepper-sdr hat sdr_autogain.json seit dem Start nicht geschrieben (t_upd %s < %s)" % (d.get("t_upd"), t0))
    if d.get("fault"):
        die("Gain-Automatik meldet einen Fehler (fault): %s" % (d.get("msg"),))
    g = air_gain(dirn)
    if want is not None and str(g) != str(want):
        die("Gain nach dem Start %s statt %s - die Installation darf den Gain nicht aendern" % (g, want))
    if want is not None and str(d.get("cur")) != str(want):
        die("Zustand meldet Stufe %s statt %s" % (d.get("cur"), want))
    print("Engine: Zustand seit dem Start geschrieben (vor %d s), kein Fehler, Modus %s%s, Stufe %s (Gain unveraendert)" % (int(time.time() - float(d["t_upd"])), d["mode"], " (gesperrt)" if d.get("lock") else "", g))


def chk_journal(txt):
    if "autoGain: Automatik aktiv" not in txt:
        die("Journal ohne 'autoGain: Automatik aktiv'")
    if "autoGain: bereit - Modus" not in txt:
        die("Journal ohne 'autoGain: bereit - Modus'")
    bad = [ln for ln in txt.splitlines() if re.search(r"Traceback|autoGain (Tick|Zustand|speichern|Fehler|FEHLER)|autoGain: (FEHLER|Fehler)", ln)]
    if bad:
        die("Journal mit Fehlerzeilen: %s" % bad[0][:160])
    print("Journal prepper-sdr: autoGain aktiv und bereit, keine Fehlerzeilen")


def tamper():
    import tempfile
    good_data = {"ok": True, "mode": "auto", "locked": False, "cur": 16, "cur_txt": "Stufe 16", "history": [], "table": [], "txt": "x", "engine": True, "stale": False, "changes_48h": 0, "sessions": 0}
    page = '<style id="ag-css">minmax(0,1fr)</style><script type="application/json" id="ag-data">%s</script><script id="ag-js">agCard Gain-Automatik Jetzt messen Gain-Test 2 starten /api/sdr/autogain window.confirm</script>' % json.dumps(good_data)
    cases = []

    def expect_fail(name, fn, *a):
        import io
        import contextlib
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                fn(*a)
        except SystemExit as e:
            if e.code == 1 and buf.getvalue().startswith("FEHLER"):
                cases.append(name)
                return
        die("Selbsttest: %s wurde nicht erkannt" % name)

    import io
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()):
        chk_page(page)
        chk_api(good_data)
        chk_at({"profile": None, "score_rows": []})
    expect_fail("Seite ohne Raster-Fix", chk_page, page.replace("minmax(0,1fr)", "1fr"))
    expect_fail("Seite ohne Knopf Gain-Test 2", chk_page, page.replace("Gain-Test 2 starten", "x"))
    expect_fail("Seite mit doppeltem Skript", chk_page, page + page)
    expect_fail("Seite mit kaputtem Daten-JSON", chk_page, page.replace('"mode": "auto"', '"mode": auto'))
    atp = '<style id="airtest-css">x</style><script type="application/json" id="at-data">{"ok": true}</script><script id="airtest-js">/api/sdr/airtest window.confirm Gain-Test 1 starten der Test selbst Score</script>'
    with contextlib.redirect_stdout(io.StringIO()):
        chk_atpage(atp)
    expect_fail("Gain-Test-Karte ohne Gain-Test 1", chk_atpage, atp.replace("Gain-Test 1 starten", "Gain-Test starten"))
    expect_fail("Gain-Test-Karte mit alter Aussage", chk_atpage, atp.replace("Score", "Score Standard-Gain wird nie geaendert"))
    expect_fail("Gain-Test-Karte doppelt", chk_atpage, atp + atp)
    expect_fail("API ohne ok", chk_api, dict(good_data, ok=False))
    expect_fail("API mit falschem Modus", chk_api, dict(good_data, mode="aus"))
    expect_fail("API ohne Verlauf", chk_api, {k: v for k, v in good_data.items() if k != "history"})
    expect_fail("airtest ohne score_rows", chk_at, {"profile": "t2"})
    expect_fail("Journal ohne bereit", chk_journal, "autoGain: Automatik aktiv (Zustand x)")
    expect_fail("Journal mit Traceback", chk_journal, "autoGain: Automatik aktiv\nautoGain: bereit - Modus auto\nTraceback (most recent call last):")
    d = tempfile.mkdtemp(prefix="agck-")
    now = time.time()
    st = {"v": 1, "mode": "auto", "cur": 16, "history": [], "sessions": [], "changes": [], "t_upd": now, "fault": False}
    json.dump(st, open(os.path.join(d, "sdr_autogain.json"), "w"))
    json.dump({"dabgain": {"X": {"air": True, "cur": 16}}}, open(os.path.join(d, "broadcast_state.json"), "w"))
    with contextlib.redirect_stdout(io.StringIO()):
        chk_state(d)
        chk_engine(d, now - 5, 16)
    expect_fail("Engine: Gain geaendert", chk_engine, d, now - 5, 17)
    expect_fail("Engine: Zustand zu alt", chk_engine, d, now + 100, 16)
    json.dump(dict(st, fault=True), open(os.path.join(d, "sdr_autogain.json"), "w"))
    expect_fail("Engine: fault", chk_engine, d, now - 5, 16)
    json.dump(dict(st, v=2), open(os.path.join(d, "sdr_autogain.json"), "w"))
    expect_fail("Zustand v2", chk_state, d)
    open(os.path.join(d, "sdr_autogain.json"), "w").write("{kaputt")
    expect_fail("Zustand kein JSON", chk_state, d)
    print("agcheck Selbsttest ok: %d Fehlerfaelle werden erkannt (%s)" % (len(cases), "; ".join(cases[:4]) + " ..."))


def main(a):
    if len(a) < 1:
        print(__doc__)
        return 2
    m = a[0]
    if m == "page":
        chk_page(open(a[1], encoding="utf-8", errors="replace").read())
    elif m == "api":
        chk_api(jload(a[1]))
    elif m == "atpage":
        chk_atpage(open(a[1], encoding="utf-8", errors="replace").read())
    elif m == "at":
        chk_at(jload(a[1]))
    elif m == "state":
        chk_state(a[1])
    elif m == "engine":
        chk_engine(a[1], float(a[2]), a[3] if len(a) > 3 and a[3] not in ("?", "None", "") else None)
    elif m == "gain":
        print(air_gain(a[1]))
    elif m == "journal":
        chk_journal(open(a[1], encoding="utf-8", errors="replace").read())
    elif m == "tamper":
        tamper()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
AGC_EOF
EXPECT_APC="e263d2221c2c3525dd742176dfd7e65793b78b4685efa5de597858932e4b4777"
cat > "$W/pdcheck.py" << 'APC_EOF'
"""Pruefungen projDoc (nur lesen). Aufruf: pdcheck.py MODUS ARGS ...
  pi HTML DOCSDIR            /pi: Kachel Projektbeschreibung Lage Pi nach der Sicherung, ganz unten, Version = neueste Datei, Sicherung unveraendert (doPrepperRestore-Zaehler gibt der Aufrufer)
  list JSON DOCSDIR          /api/docs/list = Verzeichnis docs/
  dl HDR BODY DOCSDIR VER FMT   Download: Kopfzeilen (Content-Disposition mit filename* + ASCII-Rueckfall), Inhalt = Datei
  routes JSON PFAD...        /api/docs/routes enthaelt alle Pfade
  docs DOCSDIR               Dateien: je Version TXT+MD, Namensmuster, Kopf der TXT mit gleicher Version, Kapitel, keine Schluessel/Passwoerter
  blocktest DASHBOARD BLOCK WORKDIR  Block projDoc in einer Flask-Sandbox (eigene App, Temp-Ordner, nichts gesendet): Selbsttest, Routen, Kachel hinter Sicherung, Download, Pfad-Traversal
  tamper                     Selbsttest der Pruefungen (muss Fehler erkennen)"""
import json
import os
import re
import sys
from urllib.parse import quote

STEM = "Projektbeschreibung Lage Pi v"
FRE = re.compile(r"^Projektbeschreibung Lage Pi v([0-9]{8}-[0-9]{4})\.(txt|md)$")
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()


def versions(d):
    out = {}
    for nm in os.listdir(d):
        m = FRE.match(nm)
        if m and os.path.isfile(os.path.join(d, nm)) and not os.path.islink(os.path.join(d, nm)):
            out.setdefault(m.group(1), {})[m.group(2)] = nm
    return out


def newest(d):
    v = versions(d)
    ok = sorted((k for k in v if "txt" in v[k]), reverse=True)
    assert ok, "keine Version in %s" % d
    return ok[0], v


SECRET = re.compile(r"(?i)(ghp_[A-Za-z0-9]{20,}|github_pat_|-----BEGIN [A-Z ]*PRIVATE|AKIA[0-9A-Z]{12,}|xox[bap]-[0-9A-Za-z-]{10,}|[0-9]{8,10}:[A-Za-z0-9_-]{30,}|(?:api[_-]?key|token|passwort|password|secret)\s*[:=]\s*[\"']?[A-Za-z0-9_\-/+=]{8,})")


def pi(html, d):
    s = rd(html)
    ver, _ = newest(d)
    b, p = s.find('id="backupBox"'), s.find('id="projDocBox"')
    w = s.find('id="wdPiBox"')
    assert w < 0 or w < b, "/pi: Watchdog-Kachel nicht mehr vor der Sicherung"
    assert s.count('id="projDocBox"') == 1, "/pi: Kachel projDocBox %dx statt 1x" % s.count('id="projDocBox"')
    assert s.count('id="backupBox"') == 1 and 0 <= b < p, "/pi: Sicherung fehlt oder Kachel nicht hinter der Sicherung"
    assert 'data-ver="%s"' % ver in s[p:p + 300], "/pi: Kachel zeigt nicht die neueste Version %s" % ver
    assert "Projektbeschreibung Lage Pi" in s[p:p + 400] and ("Version v%s" % ver) in s[p:p + 900], "/pi: Titel oder sichtbare Version fehlen"
    assert ("fmt=txt&amp;v=%s" % ver) in s[p:] and ('download="%s%s.txt"' % (STEM, ver)) in s[p:], "/pi: TXT-Download-Knopf mit Versionsnamen fehlt"
    tail = s[b + 10:]
    cards = [m.start() for m in re.finditer(r'class="(?:card|tile)', tail)]
    assert not cards, "/pi: nach der Sicherung steht noch eine card/tile (%d)" % len(cards)
    last = max((m.start() for m in re.finditer(r'class="(?:card|tile|pd-card)', s)), default=-1)
    assert last >= p and s.find('class="pd-card"', last) == last, "/pi: Kachel ist nicht die letzte Kachel"
    assert "pd-js" in s and s.count("projDocBox") >= 2
    print("/pi: Kachel Projektbeschreibung Lage Pi ganz unten (hinter der Sicherung, Klasse pd-card), Version v%s, TXT-Knopf %s%s.txt" % (ver, STEM, ver))


def lst(js, d):
    j = json.load(open(js, encoding="utf-8"))
    ver, v = newest(d)
    assert j.get("ok") is True and j.get("current") == ver, "/api/docs/list: current %s statt %s" % (j.get("current"), ver)
    vs = [x["ver"] for x in j["versions"]]
    assert vs == sorted(vs, reverse=True) and set(vs) == set(k for k in v if v[k]), "/api/docs/list: Versionen %s != Ordner %s" % (vs, sorted(v))
    for x in j["versions"]:
        for f in ("txt", "md"):
            if x.get(f):
                assert os.path.getsize(os.path.join(d, x[f])) == x["size_" + f], "/api/docs/list: Groesse %s" % x[f]
    print("/api/docs/list: aktuell v%s, %d Versionen (= Ordner docs/)" % (ver, len(vs)))


def dl(hdr, body, d, ver, fmt):
    h = rd(hdr)
    st = re.search(r"HTTP/[0-9.]+ ([0-9]+)", h).group(1)
    assert st == "200", "Download HTTP %s" % st
    if ver in ("", "latest"):
        ver = newest(d)[0]
    nm = "%s%s.%s" % (STEM, ver, fmt)
    cd = re.search(r"(?im)^content-disposition:\s*(.*?)\r?$", h)
    assert cd, "Content-Disposition fehlt"
    cd = cd.group(1)
    assert cd.startswith("attachment;"), cd
    assert 'filename="%s"' % nm in cd, "ASCII-Dateiname fehlt/falsch: %s" % cd
    assert "filename*=UTF-8''%s" % quote(nm, safe="") in cd, "filename* (RFC 5987) fehlt/falsch: %s" % cd
    ct = re.search(r"(?im)^content-type:\s*(.*?)\r?$", h).group(1).lower()
    assert ct.startswith({"txt": "text/plain", "md": "text/markdown"}[fmt]) and "utf-8" in ct, ct
    assert "nosniff" in h.lower() and "no-store" in h.lower()
    a = open(body, "rb").read()
    b = open(os.path.join(d, nm), "rb").read()
    assert a == b and len(a) > 1000, "Download-Inhalt != Datei %s" % nm
    print("Download %s: HTTP 200, %s, Content-Disposition mit filename* + ASCII-Rueckfall, %d Bytes = Datei in docs/" % (fmt.upper(), ct, len(a)))


def routes(js, *paths):
    j = json.load(open(js, encoding="utf-8"))
    assert j.get("ok") and j.get("n", 0) > 50, "routes: %s" % str(j)[:100]
    have = set(r["rule"] for r in j["routes"])
    miss = [p for p in paths if p not in have]
    assert not miss, "/api/docs/routes: fehlen %s" % miss
    print("/api/docs/routes: %d Routen, alle %d geforderten Pfade da" % (j["n"], len(paths)))


def docs(d):
    ver, v = newest(d)
    for k, e in v.items():
        assert "txt" in e and "md" in e, "Version %s: TXT und MD muessen beide da sein (%s)" % (k, sorted(e))
    t = rd(os.path.join(d, v[ver]["txt"]))
    m = rd(os.path.join(d, v[ver]["md"]))
    head = "\n".join(t.splitlines()[:10])
    assert "PROJEKTBESCHREIBUNG LAGE PI" in head and ("Version: v" + ver) in head, "TXT-Kopf ohne Titel/Version %s" % ver
    mh = "\n".join(m.splitlines()[:8])
    assert mh.startswith("# Projektbeschreibung Lage Pi") and ("v" + ver) in mh, "MD-Kopf ohne Titel/Version %s" % ver
    chap = re.findall(r"(?m)^={20,}\n([0-9]{1,2})\. [A-ZÄÖÜ]", t)
    assert "INHALTSVERZEICHNIS" in "\n".join(t.splitlines()[:12]), "TXT ohne Inhaltsverzeichnis im Kopf"
    assert len(chap) >= 18, "Kapitel: %d" % len(chap)
    for nm, tx in (("TXT", t), ("MD", m)):
        mm = SECRET.search(tx)
        assert not mm, "%s: moegliches Geheimnis: %s" % (nm, mm.group(0)[:30])
    print("docs/: neueste v%s, TXT %d Bytes / MD %d Bytes, %d Kapitel, %d Versionen, kein Schluessel-Muster" % (ver, len(t.encode()), len(m.encode()), len(chap), len(v)))


def tamper():
    import tempfile
    t = tempfile.mkdtemp()
    nm = lambda e: os.path.join(t, "%s20261024-1830.%s" % (STEM, e))
    open(nm("txt"), "w").write("PROJEKTBESCHREIBUNG LAGE PI\nVersion: v20261024-1830\nINHALTSVERZEICHNIS\n" + "".join("=" * 30 + "\n%d. KAPITEL\n" % i for i in range(1, 19)) + "x" * 2000)
    open(nm("md"), "w").write("# Projektbeschreibung Lage Pi\n\n- Version: **v20261024-1830**\n")
    docs(t)
    open(nm("txt"), "a").write("\ntoken: ABCDEF1234567890\n")
    try:
        docs(t)
    except AssertionError:
        pass
    else:
        raise SystemExit("Selbsttest: Geheimnis nicht erkannt")
    good = '<div class="card" id="backupBox"><div>doPrepperRestore</div></div><div id="projDocBox" class="pd-card" data-ver="20261024-1830"><div class="title">Projektbeschreibung Lage Pi</div><div>Version v20261024-1830</div><a href="/api/docs/download?fmt=txt&amp;v=20261024-1830" download="Projektbeschreibung Lage Pi v20261024-1830.txt">x</a></div><script id="pd-js">projDocBox</script>'
    open(nm("txt"), "w").write("PROJEKTBESCHREIBUNG LAGE PI\nVersion: v20261024-1830\nINHALTSVERZEICHNIS\n" + "".join("=" * 30 + "\n%d. KAPITEL\n" % i for i in range(1, 19)) + "x" * 2000)
    for name, h in (("ok", good), ("Kachel vor Sicherung", good.replace('id="backupBox"', 'id="xx"')), ("card danach", good.replace("<script id=\"pd-js\">", "<div class=\"card\">y</div><script id=\"pd-js\">")),
                    ("alte Version", good.replace('data-ver="20261024-1830"', 'data-ver="20250101-0000"')), ("kein Download", good.replace("fmt=txt", "fmt=md"))):
        f = os.path.join(t, "pi.html")
        open(f, "w").write(h)
        try:
            pi(f, t)
            r = "ok"
        except AssertionError:
            r = "fehler"
        assert (r == "ok") == (name == "ok"), "Selbsttest pi: %s -> %s" % (name, r)
    print("OK pdcheck Selbsttest: Geheimnis, Kachel vor Sicherung, card danach, falsche Version, fehlender Download werden erkannt")


def blocktest(dash, blk, work):
    """Fuehrt den Block in einer eigenen Flask-App aus (Python mit Flask noetig). Nimmt aus dashboard.py nur _PP2_TOK/_PP2_START/_pp2_block (Quelltext per AST)."""
    import ast
    import tempfile
    from flask import Flask
    src = rd(dash)
    t = ast.parse(src)
    seg = ["import re as _pp2_re"]
    for n in t.body:
        if isinstance(n, ast.Assign) and any(getattr(x, "id", "") in ("_PP2_TOK", "_PP2_START") for x in n.targets):
            seg.append(ast.get_source_segment(src, n))
        if isinstance(n, ast.FunctionDef) and n.name == "_pp2_block":
            seg.append(ast.get_source_segment(src, n))
    assert len(seg) == 4, "piPolish2-Hilfen nicht gefunden (%d)" % len(seg)
    d = tempfile.mkdtemp(prefix="pd-blocktest-", dir=work)
    app = Flask("pdtest")
    page = '<html><body><div class="card" id="wdPiBox">w</div><div class="card" id="backupBox" style="margin-top:16px"><div class="title">Sicherung</div><div><div>doPrepperRestore</div></div></div><script>1</script></body></html>'

    @app.route("/pi")
    def _pi():
        return page
    g = {"app": app, "__file__": os.path.join(d, "dashboard.py"), "__name__": "pdtest"}
    exec(compile("\n".join(seg), "pp2", "exec"), g)
    os.makedirs(os.path.join(d, "docs"))
    mk = lambda n, c: open(os.path.join(d, "docs", n), "wb").write(c)
    mk(STEM + "20261024-1830.txt", b"T" * 3000)
    mk(STEM + "20261024-1830.md", b"M" * 2000)
    mk(STEM + "20261001-0900.txt", b"o" * 500)
    mk("passwoerter.txt", b"x")
    exec(compile(rd(blk), "block", "exec"), g)
    c = app.test_client()
    r = c.get("/api/docs/list")
    j = r.get_json()
    assert r.status_code == 200 and j["current"] == "20261024-1830" and [v["ver"] for v in j["versions"]] == ["20261024-1830", "20261001-0900"], j
    r = c.get("/api/docs/download?fmt=txt")
    assert r.status_code == 200 and r.data == b"T" * 3000, r.status_code
    cd = r.headers["Content-Disposition"]
    assert 'filename="Projektbeschreibung Lage Pi v20261024-1830.txt"' in cd and "filename*=UTF-8''Projektbeschreibung%20Lage%20Pi%20v20261024-1830.txt" in cd, cd
    assert c.get("/api/docs/download?fmt=txt&v=20261001-0900").data == b"o" * 500
    assert c.get("/api/docs/download?fmt=md&v=20261001-0900").status_code == 404
    for q in ("v=../../etc/passwd", "v=20261024-1830/../../x", "v=..%2f..%2fetc%2fpasswd", "fmt=exe", "fmt=txt/../x", "v=" + "9" * 300, "fmt=txt&v=passwoerter"):
        rr = c.get("/api/docs/download?" + q)
        assert rr.status_code in (400, 404) and b"root:" not in rr.data and len(rr.data) < 100, (q, rr.status_code)
    assert c.post("/api/docs/list").status_code == 405 and c.post("/api/docs/download").status_code == 405
    r = c.get("/api/docs/routes")
    rj = r.get_json()
    assert rj["ok"] and {"/pi", "/api/docs/list", "/api/docs/download", "/api/docs/routes"} <= set(x["rule"] for x in rj["routes"])
    r = c.get("/pi")
    h = r.get_data(as_text=True)
    b, p = h.find('id="backupBox"'), h.find('id="projDocBox"')
    assert 0 < b < p and h.count("doPrepperRestore") == 1 and h.count('id="projDocBox"') == 1, (b, p)
    assert 'class="card' not in h[b + 10:] and "Version v20261024-1830" in h and "<script id=\"pd-js\">" in h
    assert c.get("/pi").get_data(as_text=True) == h, "nicht deterministisch"
    open(os.path.join(work, "pi_blocktest.html"), "w", encoding="utf-8").write(h)
    pi(os.path.join(work, "pi_blocktest.html"), os.path.join(d, "docs"))
    import shutil
    shutil.rmtree(d, ignore_errors=True)
    print("OK Block projDoc in Flask-Sandbox: Selbsttest, 3 GET-Routen (POST = 405), Kachel hinter der Sicherung, Download mit Content-Disposition, 7 Pfad-Traversal-Versuche abgewiesen")


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        {"pi": lambda: pi(*a[1:3]), "list": lambda: lst(*a[1:3]), "dl": lambda: dl(*a[1:6]), "routes": lambda: routes(*a[1:]), "docs": lambda: docs(a[1]), "blocktest": lambda: blocktest(*a[1:4]), "tamper": tamper}[a[0]]()
    except AssertionError as e:
        print("pdcheck FEHLER: %s" % e); raise SystemExit(1)
    except KeyError:
        print(__doc__); raise SystemExit(2)
APC_EOF
EXPECT_APD="a3c385a5ca1b263e1a1c4580dfe3a1cc7bb50b8f383d8eabaa222a60ad972886"
cat > "$W/prepper_docs.py" << 'APD_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""prepper_docs.py - erzeugt die "Projektbeschreibung Lage Pi" (TXT = Hauptformat, Markdown) im Ordner docs/ neben diesem Skript.

Aufruf (auf dem Pi, Ordner /home/fmg/prepper-dashboard):
    python3 prepper_docs.py                 neue Version YYYYMMDD-HHMM (Berlin-Zeit) erzeugen, TXT + MD schreiben, alte Versionen rotieren (keepLast 10)
    python3 prepper_docs.py --check         nur erzeugen und pruefen, nichts schreiben (Trockenlauf, Pruefbericht)
    python3 prepper_docs.py --force         auch dann neue Version, wenn sich gegenueber der neuesten Version nichts geaendert hat
    python3 prepper_docs.py --no-live       keine HTTP-Abfragen an das laufende Dashboard (Routen/Kacheln dann nur statisch aus dashboard.py)
    python3 prepper_docs.py --keep N        N Versionen behalten (Standard 10, Minimum 3)
Die Kachel auf /pi (ganz unten, unter der Sicherung) zeigt immer die neueste Version in docs/ und bietet den Download an.

Aufbau: statischer Textkern (CORE, von Hand geschrieben, Abschnitte mit @@AUTO name@@-Marken) + automatisch ermittelte Abschnitte
(Routen vom laufenden Dashboard bzw. per AST aus dashboard.py, Dateien mit sha16/Zeilen, Patch-Schichten (Marker "# ===== name:"), systemd-Units,
Datenbank-Tabellen, Hilfsprogramme, Patch-Stand). Danach Validierung: alles Gefundene (Routen, Kachel-Ueberschriften, Kachel-IDs, Units, Dateien,
Marker) muss im redaktionellen Text vorkommen, sonst wird es automatisch als Nachtrag angehaengt; Sensibles wird geschwaerzt.
Nur lesend: kein Schreiben ausser docs/, keine Secrets (config.py, secrets/ werden nie gelesen ausser der Zeile PORT = n), nichts wird gesendet.
Nur Standardbibliothek. Python >= 3.9."""
import ast
import datetime
import hashlib
import html as _html
import json
import os
import platform
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import urllib.request

BASE = os.environ.get("PRDOCS_BASE") or os.path.dirname(os.path.abspath(__file__))
DOCS = os.environ.get("PRDOCS_OUT") or os.path.join(BASE, "docs")
STEM = "Projektbeschreibung Lage Pi v"
KEEP_DEFAULT = 10
GEN_VERSION = "1"
SYSTEMCTL = os.environ.get("PRDOCS_SYSTEMCTL") or "systemctl"
SBIN_DIRS = [x for x in (os.environ.get("PRDOCS_SBIN") or "/usr/local/sbin:/usr/local/bin").split(":") if x]
SUDOERS_DIR = os.environ.get("PRDOCS_SUDOERS") or "/etc/sudoers.d"
UNIT_DIR = os.environ.get("PRDOCS_UNITDIR") or "/etc/systemd/system"
WIDTH = 100
NOTES = []            # Hinweise/Fehler der Sammler (landen im Pruefbericht, nie als Abbruch)
SMOKE_PAGES = ["/", "/funk", "/pi", "/umwelt", "/funk433", "/aprs", "/meteor", "/rundfunk", "/energie", "/dabhist", "/mesh", "/karte"]
SMOKE_APIS = ["/api/sdr/ui", "/api/sdr/wd", "/api/br24", "/api/sdr/sticktest", "/api/sdr/live", "/api/sdr/map", "/api/broadcast/events", "/api/t2/status",
              "/api/t3/status", "/api/t4/status", "/api/t4/map", "/api/t4/tii", "/api/meteor", "/api/sdr/status"]
LIVE_PAGES = ["/", "/energie", "/lokale-energie", "/speicher", "/umwelt", "/luft", "/pegel", "/adsb", "/zuhause", "/mesh", "/mesh2", "/news", "/funk", "/karte", "/pi",
              "/medizin", "/funk433", "/aprs", "/meteor", "/rundfunk", "/dabhist", "/umwelt2"]
IP_OK = {"127.0.0.1", "0.0.0.0", "192.168.178.15", "1.1.1.1", "9.9.9.9", "8.8.8.8"}
UNIT_RE = re.compile(r"(prepper|mesh|sdr|gpsd|chrony|kiwix|openwebrx|rtl|welle|tar1090|readsb|dump1090|direwolf|mosquitto|lagezentrum|watchdog|health|backup|clone|dashboard|aprs|meteor|satdump|ntp|timesyncd|ssh)", re.I)

# ----------------------------------------------------------------------------------------------------------------------------------------------
CORE = r'''
# Kurzfassung fuer KIs und neue Entwickler

## Was ist das hier?

Dies ist die Projektbeschreibung "Lage Pi" des Prepper-Dashboards ("Kaeswasser Lage Monitor") von Frank. Das System laeuft auf einem Raspberry Pi 4 mit dem Hostnamen BND-Prepper (Linux-Benutzer fmg, Projektordner /home/fmg/prepper-dashboard). Es ist ein privates Lagebild fuer Haus, Familie und Region (Kalchreuth/Schnaittach bei Nuernberg, Mittelfranken): Warnungen (NINA/MoWaS, DWD, DAB+/UKW-Rundfunk, ASA), Energie- und Versorgungslage, Pegel, Luft, Funkempfang per SDR und Meshtastic-Funknetze. Ein Flask-Webserver liefert die Seiten, mehrere kleine systemd-Dienste und Python-Module liefern die Daten.

Zweck dieser Datei: Eine andere KI oder ein neuer Entwickler soll das Projekt allein aus diesem Text verstehen und weiterentwickeln koennen, ohne Rueckfragen an Frank. Die Datei wird auf dem Pi automatisch erzeugt (python3 prepper_docs.py) und enthaelt neben dem redaktionellen Text automatisch ermittelte Abschnitte (Routen, Dateien mit sha16 und Zeilenzahl, Units, Datenbank, Patch-Schichten), damit sie zum Stand der laufenden Dateien passt.

## In 12 Saetzen

- Das Dashboard ist ein einziges grosses Flask-Programm (dashboard.py, rund 23000 Zeilen), das ueber viele nachtraeglich eingefuegte Patch-Schichten ("# ===== name: ... =====") gewachsen ist. Es gibt keinen Build-Schritt, keine Frontend-Frameworks; HTML/JS steckt in Python-Strings und wird von after_request-Hooks erweitert.
- Daten kommen aus oeffentlichen Quellen (Abrufe in Hintergrundfaeden), aus lokalen Diensten (chrony, gpsd, tar1090, Kiwix, Meshtastic-Bridges) und aus dem SDR-Dienst prepper-sdr.
- prepper-sdr ist der einzige Dienst, der die USB-SDR-Geraete besitzt. Er empfaengt nur (nie Senden ueber Funk) und schreibt Zustand in lagezentrum.db (SQLite) und Notkopie-JSON-Dateien.
- Das Dashboard und alle Hilfsmodule sind "nur lesen/anzeigen", ausser an klar benannten, einzelnen Sendestellen (Mesh-Knoepfe, Mesh-Auto-Meldungen). Alles andere sendet nichts.
- Automatische Mesh-Meldungen echter Alarme gehen nur an Mesh 1, nie bei Probe/Test, je Alarm einmal, gleicher Inhalt nicht innerhalb 6 Stunden, hoechstens 3 pro Stunde; der Schalter mesh_auto.json ist ein Kill-Switch (fehlt/kaputt = aus).
- Aenderungen am Pi werden nur als "apply-Patch" ausgeliefert: ein Shell-Skript mit sha16-Basispruefung, Trockenlauf, Idempotenz, Backups (keepLast 3), AST-Wache, py_compile mit beiden Pythons, Selbsttests, minimalem Neustart (nur das Dashboard), Rauchtest (26 Pruefungen) und automatischem Rollback.
- Frank arbeitet ohne Git-Klon: Patches kommen per curl -o /tmp/... aus dem OEFFENTLICHEN Repo Frankenland90/prepper-patches (festgenagelter Commit) auf den Pi und werden mit sha256 geprueft (Kapitel 12).
- Das Arbeits-Repo Frankenland90/kaeswasser-lage-monitor (Branch kaeswasser-lage-monitor) ist PRIVAT: der Roh-Link liefert ohne Token HTTP 404; der Pi greift nie darauf zu.
- Sicherheit zuerst: keine Secrets in dieser Datei, keine Sendewege ohne Freigabe, kein Pi-Neustart durch Patches, rechtlich nur Empfang erlaubter Dienste (Rundfunk, ISM, Amateurfunk, Wettersatellit).
- Der Stand der Weiterentwicklung steht in Kapitel 16, die Regeln fuer Weiterentwickler in Kapitel 17.
- Unbekanntes ist in dieser Datei ausdruecklich als "nicht dokumentiert/zu pruefen" markiert und nicht geraten.
- Die Version steht im Dateinamen: Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt (Berlin-Zeit), identisch zur Kachel auf /pi.

## Leseanleitung

- Neu im Projekt: Kapitel 1 bis 4, dann 13 bis 15 und 17.
- Eine Seite oder Kachel aendern: Kapitel 5 (Seitenkatalog), 4 (Architektur) und die Tabelle "Patch-Schichten" in Kapitel 11.
- SDR/Funk: Kapitel 6 und 7. Alarmierung/Mesh: Kapitel 7 und 8.
- Ein Patch ausliefern: Kapitel 11 und 12.
- Automatische Abschnitte erkennt man an der Zeile "automatisch erzeugt" bzw. an Tabellen mit Hashes; sie gelten fuer den Zeitpunkt der Erzeugung (Kopf der Datei).

## Kopfdaten dieser Ausgabe

@@AUTO meta@@

## Die zehn goldenen Regeln

- (1) Nie Secrets lesen, ausgeben oder in Dateien/Chat schreiben (config.py-Werte, secrets/, Schluessel, Passwoerter, Tokens, sudo-Passwort).
- (2) Nichts senden, was nicht ausdruecklich freigegeben ist: kein Mesh, keine Alarme in Tests, Simulationen und Rauchtests.
- (3) Bestehende Logik nicht kaputt machen: neue Funktionen als zusaetzliche Patch-Schicht, alles in try/except, Seiten duerfen nie abstuerzen.
- (4) Alte apply-Skripte der Vergangenheit bleiben unveraendert (sie sind historisch und pruefen sha16 des damaligen Stands).
- (5) Jede Auslieferung: sha16-Basispruefung, Trockenlauf, Idempotenz, keepLast 3, atomar schreiben, AST-Wache, py_compile mit /usr/bin/python3 und venv, Selbsttests, Rauchtest, Rollback.
- (6) Nur das Dashboard neu starten (prepper-dashboard). Kein Neustart von prepper-sdr oder des Pi durch Patches; kein USB-Reset aus Patches.
- (7) Keine PIN-Sperre auf den Mesh-Sende-Knoepfen (Entscheidung von Frank); stattdessen Bestaetigungsdialog und Sende-Schutz.
- (8) Sticks/SDR: nur Empfang. Nur Bereiche, die rechtlich zulaessig sind (Rundfunk, Wettersatellit, ISM, Amateurfunk-APRS). Keine Pager-/BOS-Dekodierung.
- (9) Kein Git-Klon beim Betreiber: Patches per curl -o /tmp/... aus prepper-patches (festgenagelter Commit) holen, mit sha256 pruefen (Kapitel 12).
- (10) Nichts erfinden: was nicht belegt ist, als "nicht dokumentiert/zu pruefen" kennzeichnen.

# Zweck, Zielgruppe, Leitprinzipien

## Zweck

- Ein einziges, ruhiges, handytaugliches Lagebild fuer den Haushalt: "Ist etwas los, das mich betrifft?" - Warnlage (Behoerden und Rundfunk), Strom/Netz, Wasser/Pegel, Luft/Brand, Wetter/Strahlung, Funk/Mesh-Zustand.
- Unabhaengigkeit vom Internet soweit moeglich: lokale Quellen (DAB+/UKW-Rundfunk-Warnungen per SDR, Meshtastic-LoRa-Funk, Offline-Wikipedia Kiwix, ADS-B, Zeit per Stratum-1/GPS) ergaenzen die Internetquellen (NINA, DWD, energy-charts, GIE, BfS, ...).
- Eigene, nachvollziehbare Alarmlogik mit Schutz gegen Fehlalarme: Probe/Test-Meldungen werden erkannt und nie als echter Alarm weitergegeben.
- Kein Dienstleistungsprodukt: das System ist ein privates Hobby-/Vorsorgeprojekt, kein amtliches Warnsystem. Die Anzeige ist Orientierung, keine Garantie.

## Zielgruppe

- Betreiber und Nutzer: Frank (Haushalt Kalchreuth, Landkreis Erlangen-Hoechstadt ERH). Bedienung vorwiegend am Handy; die Seiten sind schmal/kompakt gebaut.
- Entwickler/KI-Assistenten, die Patches schreiben: sie arbeiten ohne direkten Zugriff auf den Pi, mit Sandbox-Simulation und Lieferung per GitHub-Patchrepo (Kapitel 11/12).
- Nicht Zielgruppe: oeffentliche Nutzer. Das Dashboard ist nur im Heimnetz (LAN) gedacht und nicht fuer das offene Internet gehaertet.

## Leitprinzipien

- Empfangen statt senden: SDR sendet nie. Mesh-Sendungen nur an eindeutig benannten Stellen (Kapitel 8).
- Anzeige darf nie abstuerzen: jede Funktion faengt Fehler ab und liefert einen sicheren Standardwert; fehlende Quelle = "–" oder "Keine Quelle", nie ein Fehler 500.
- Datenquellen ehrlich kennzeichnen: BER gibt es bei welle-cli nicht (angezeigt wird die FIC-Fehlerrate als Ersatz); Platzhalter und Schaetzungen sind als solche beschriftet.
- Kleine, geschichtete, rueckrollbare Aenderungen statt grosser Umbauten: neue Funktion = neue Patch-Schicht + Selbsttest + Rauchtest.
- Ruhe statt Alarmismus: Entprellung, Dedup, Vorlaufzeiten (zum Beispiel 5 Minuten Mesh-Ruhe nach Dashboard-Start, 6 Stunden Dedup, max. 3 Auto-Meldungen je Stunde).
- Dauerhaft lauffaehig: der Pi startet ohne Warten, Hintergrundfaeden uebernehmen Abrufe; Watchdogs ueberwachen die Daten (nicht nur Prozesse).

# Hardware und Netz

## Rechner

- Raspberry Pi 4 (aarch64) mit Hostname BND-Prepper, Betriebssystem Debian 13 "trixie" (Stand Bestandsaufnahme 12.10.2026: Kernel 6.18.x), Linux-Benutzer fmg. RAM-Ausbau und genaues Gehaeuse/Kuehlung: nicht dokumentiert/zu pruefen (die Kachel "Systemstatus" zeigt CPU, RAM, Temperatur, Uptime live).
- Master-Laufwerk: SSD (Boot-Laufwerk; smartctl wird laut Code auch mit -d sat aufgerufen, also USB-SATA-Adapter moeglich; Kachel "SSD · Master" auf /pi mit SMART, Temperatur, Betriebsstunden, Schreiblast, Fehlerzaehlern und Boot-Reihenfolge). SSD-Hersteller/Groesse werden live aus smartctl gelesen und sind hier nicht festgeschrieben.
- Fallback: SD-Karte (Kachel "SD · Fallback"). Die SD wird nur auf Knopfdruck von der SSD geklont (Programm /usr/local/bin/prepper-clone-ssd-to-sd, Dashboard-Seite zeigt "Jetzt von SSD auf SD klonen" mit Sperre, wenn keine Karte steckt). Es gibt keinen automatischen Klon (Entscheidung Frank).
- Boot-Ampel: SSD gruen / SD gelb. Die Boot-Reihenfolge wird nur angezeigt (read-only). Die Kachel "SD-Gesundheit" liest sd_health.json, das der root-Timer prepper-sd-health schreibt; "Quittieren & neu pruefen" schreibt nur sd_health_ack.json.
- Persistentes Journal (200 MB) ist eingerichtet (Entscheidung 23.10.2026), damit Fehler nach einem Neustart nachvollziehbar bleiben.
- Echtzeituhr (RTC, z. B. DS3231), Anzeigen wie ein TFT-Display ohne WLAN: nicht dokumentiert/zu pruefen.
- Zeit: Der Pi nutzt chrony. Als Stratum-1-Quelle dient der separate Server raspberrypi2 im LAN (192.168.178.15, chrony mit GPS + PPS von gpsd). Die Lage-Seite zeigt "Stratum Offset"; der Health-Check prueft "chrony tracking OK".

## SDR-Empfaenger (nur Empfang)

Die USB-SDR-Geraete gehoeren ausschliesslich dem Dienst prepper-sdr. Rollen sind seit 23.10.2026 fest nach Seriennummer vergeben (Geraete-Register in sdr_config.json, Schluessel devs):

| Anzeigename | Geraet | USB-ID | Seriennummer | Rolle |
|---|---|---|---|---|
| Airspy R2 · 11D | Airspy R2 | 1d50:60a1 | 637862DC2E8092D7 | fest DAB 11D (BR Bayern, 222,064 MHz), BR24-Warnungen; welle-cli mit -F airspy, Port 7979, Gain-Leiter |
| Stick 1 · 5C | Nooelec NESDR SMArt v5 (RTL2832U) | 0bda:2838 | 19348831 | fest DAB 5C (178,352 MHz, 1. Bundesmux, ASA DE = amtliche Warnungen), Rueckfall 10C (Lokal Nuernberg, 213,360 MHz) |
| Stick 2 · Hobby | Nooelec NESDR SMArt v5 | 0bda:2838 | 72055505 | Hobby: UKW-RDS (BR24, Bayern 3, Bayern 1 im Wechsel), 10C-Pruefung alle 6 h, QRM-Messung, Kalibrierung, 433 MHz, APRS; nur Beobachtung, kein Eingriff durch Watchdog/Neustart |
| Stick 3 · Hobby | Realtek RTL2838UHIDIR (Werks-SN 00000001) | 0bda:2838 | 26102403 (geplant/neu per rtl_eeprom) | zweiter Hobby-Stick, nur Register/Anzeige/Journal, kein Planer, wird von prepper-sdr nie geoeffnet (Stand: Patch sdrStick3/sdrStick3c, Umsetzung siehe Kapitel 16) |

- Der Spyverter bleibt vorerst draussen (Entscheidung 23.10.2026). Ein Splitter wird nicht verwendet.
- Die frueher geplante Uebernahme von Stick 2 auf 5C bei Vor-Alarm ist entfallen (Patch sdrAir): Stick 1 hoert 5C fest, der Airspy 11D fest.
- USB-Portzuordnung (welcher Stick an welchem Pi-Port steckt): nicht dokumentiert/zu pruefen; prepper-sdr bindet die Sticks ausschliesslich ueber die Seriennummer, nicht ueber den Port. Nach dem Umstecken wird der Stick-Index beim naechsten regulaeren Start neu aufgeloest.
- Der Pi sendet ueber SDR nichts. Rechtlich erlaubt sind nur Empfang von Rundfunk (UKW, DAB+), Wettersatellit (Meteor-M LRPT), ISM (433/868 MHz) und Amateurfunk-APRS. Keine Pager-/BOS-Dekodierung (multimon-ng/POCSAG bewusst ausgeschlossen).

## Antennen

- Dachantenne: AE-Skyscan Mag 1300 auf dem Dachfirst, gehoert ausschliesslich zum Airspy R2 (ohne Splitter) fuer DAB 11D.
- Antennen der Nooelec-Sticks (Typ, Standort, Kabel) sowie Meteor-/APRS-/433-Antennen: nicht dokumentiert/zu pruefen. Das Antennentest-Programm (Kachel "Antennentest" auf /funk) misst nur und gibt Empfehlungen.
- Dach-GPS-Empfaenger haengt am Stratum-1-Server (nicht am Pi BND-Prepper); der Pi liest ihn nur ueber gpsd (192.168.178.15:2947).

## Meshtastic-Knoten (LoRa-Funknetze)

- Mesh 1 = Knoten "Kalchreuth G2" (Meshtastic TCP-API Port 4403; die Adresse steht in mesh_rules.py bzw. mesh_rules.json und wird hier bewusst nicht genannt). Hauptweg fuer manuelle Knoepfe und automatische Alarmmeldungen. Kanal 0 (LongFast) ist der Standardkanal fuer die Sendungen; in Anweisungen von Frank bedeutet "Mesh-Kanal 1" Mesh 1.
- Mesh 2 = Knoten "Bayern G2" (Firmware 2.7.26, Stand 10.10.2026; Adresse siehe mesh_rules.py, hier nicht genannt). Bekommt automatisch nur NINA (Routing Teil 3; der NINA-Auto-Weg fuer Mesh 2 ist ueber den Schalter nina_bayern_auto.json zusaetzlich freizugeben, Standard AUS). DAB+-Meldungen duerfen diese Adresse nie ansprechen. MQTT ist am Knoten aus (Ursache frueherer 4-Minuten-Abbrueche); ein optionales lokales Mosquitto fuer Mesh 2 ist eingeplant, aber aus.
- Je Knoten haelt genau EINE Bridge die TCP-Session (mesh_bridge.py fuer Mesh 1, Port 127.0.0.1:5001; mesh_bridge_bayern.py fuer Mesh 2, Port 127.0.0.1:5002). Ein zweiter Client wuerde die Bridge aus der Session werfen; deshalb oeffnet das Dashboard nie selbst eine Verbindung (mesh_session.py prueft nur per ss -tnp).
- Auto-Antworten auf "ping"/"test": mesh_ping_reply.py (Mesh 1), mesh_ping_reply2.py und mesh_ping_reply_bayern.py (Mesh 2); Station-Label in den Antworten ist "Station Kalchreuth".
- Ob der Knoten WLAN-/LAN-Verbindung oder andere Anbindung hat und die genauen Standorte: nicht dokumentiert/zu pruefen.

## Netz und Hilfsserver

- Heimnetz mit Fritz-Box (privater Adressraum). Als feste Adresse wird hier nur 192.168.178.15 genannt (Stratum-1/GPS/ADS-B-Server raspberrypi2); die Adressen der Mesh-Knoten und der Kiwix-Seite stehen im Code (mesh_rules.py, Kachel-Links) und werden in dieser Datei bewusst nicht genannt. Alle anderen Adressen werden in dieser Datei geschwaerzt.
- Internetpfade: Telekom (Festnetz) und Starlink als Ausfallschutz; die Erkennung (uplink_detect.py) wertet Hop 2, Rueckwaerts-DNS, Starlink-Schuessel (Standardadresse der Starlink-Schnittstelle) und ASN aus; mindestens 2 uebereinstimmende Merkmale, sonst "Pfad unklar".
- Weitere lokale Dienste: Kiwix (Offline-Wikipedia, Port 8080, Seite /medizin), ADS-B-Feeder mit tar1090/readsb auf dem Stratum-1-Server 192.168.178.15 (Quelle der Seite /adsb: /tar1090/data/aircraft.json und stats.json), gpsd (Stratum-1-Server), optional OpenWebRX (nicht festgeschrieben).

# Software-Architektur

## Ueberblick

```
Internet-Quellen --(requests, Hintergrundfaeden)--> dashboard.py (Flask, data_store im Speicher + JSON-Dateien)
                                                          |  ^                      |
 lokale Dienste (chrony, gpsd, tar1090, kiwix) -----------+  |                      +--> Browser (Handy/PC im LAN)
 Meshtastic-Bridges (127.0.0.1:5001/5002)  <--- Sendestellen -+                      |
 SDR-Geraete --> prepper_sdr.py (Dienst prepper-sdr) --> lagezentrum.db (SQLite, Tabelle state u. a.) + JSON-Notkopie
                                                          |
                         sdr_manager.py / database.py / mesh_router.py / lagegeo.py (Module im Dashboard-Prozess)
```

- Ein Rechner, ein Projektordner: /home/fmg/prepper-dashboard. Alles Wesentliche liegt dort flach (Python-Module, JSON-Zustandsdateien, lagezentrum.db, static/, archive/, docs/, backups/).
- Python 3.13.x. Zwei Interpreter muessen den Code uebersetzen koennen: /usr/bin/python3 und das venv (Ordner venv im Projektordner, venv/bin/python). Jeder Patch prueft py_compile mit beiden.
- Flask (Web), requests (Abrufe), ntplib (Stratum-Abfrage), sqlite3 (Standardbibliothek); SDR-Werkzeuge ausserhalb von Python: rtl_433, rtl_fm, redsea, direwolf, welle-cli, rtl_tcp, rtl_power, satdump, soapy/airspy-Pakete.
- Konfiguration steht in config.py (Rechte 600; enthaelt API-Schluessel, Koordinaten, Intervalle, Mesh-Hosts, Pegelstationen). Inhalte werden nie ausgegeben oder kopiert; der Generator liest daraus ausschliesslich die Zeile PORT.
- Das Dashboard lauscht auf dem Port aus config.py (PORT; Standard 5000). Neustart: sudo systemctl restart prepper-dashboard (nur diesen Dienst, nie den ganzen Pi).

## Das Dashboard-Monolith-Muster

- dashboard.py ist ueber viele Monate in Schichten gewachsen. Jede Schicht beginnt mit einem Marker-Kommentar der Form "# ===== name: Beschreibung =====" und steht vor dem Block if __name__ == "__main__": am Dateiende. Neue Funktionen werden nie in alten Code hineineditiert, sondern als neue Schicht angehaengt; kleine Ersetzungen alter Textstellen sind die Ausnahme und werden mit eindeutigen Ankern und AST-Wache abgesichert.
- Seiten sind Python-Strings (PAGE1 ... PAGE4, PAGE_ENERGIE, PAGE_LUFT, PAGE_ADSB, ...) und werden per render_template_string mit data_store gerendert. Viele Kacheln werden nachtraeglich per after_request-Hooks in das ausgelieferte HTML eingefuegt. Wichtig: Flask fuehrt after_request-Funktionen in UMGEKEHRTER Listenreihenfolge aus (die zuletzt registrierte zuerst); eine neue Schicht, die nach einer anderen laufen soll, muss deshalb an der passenden Listenposition eingefuegt werden.
- Routen: normale @app.route-Dekoratoren, dazu add_url_rule in Schleifen (zum Beispiel die SDR-APIs). Deshalb kann man die Routenliste nicht nur per Textsuche finden; der Generator nimmt die laufende Routenliste (/api/docs/routes) und gleicht per AST ab.
- Kachel = HTML-Block mit class="card" (oder Seiten-eigene Klassen) und meist einer id wie fooCard/fooBox/fooTile; JavaScript aktualisiert Kacheln per fetch auf die /api/...-Endpunkte.
- Jede Schicht hat Kennzeichnungs-Kommentare der Form /* name */ im HTML/JS, damit Patches ihren eigenen Code wiederfinden (Idempotenz).
- Hintergrundfaeden: Voll-Update alle UPDATE_INTERVAL (15 Minuten, Anzeige "Update in n min"), schnelle Frequenzabfrage alle FREQ_INTERVAL, Mesh-Wetter-/Frequenz-Faeden, Uplink-Erkennung alle 60 s, Retention-Faden der Datenbank alle 10 min. Seit sysBoot lauscht der Server sofort; das erste Voll-Update laeuft danach im Hintergrund ("laed"-Hinweis auf der Startseite).
- Fehlerphilosophie: jede Abfrage mit Timeout, jede Funktion mit try/except und sicherem Standardwert; fehlende Quelle = "–"/"Keine Quelle"; Ruecksprung auf zuletzt guten Wert wird gekennzeichnet.

## Module (Python-Dateien im Projektordner)

Die vollstaendige, automatisch ermittelte Dateiliste mit sha16 und Zeilenzahl steht im Abschnitt 4.5 (Dateien im Projektordner); hier die Rollen:

| Datei | Rolle |
|---|---|
| dashboard.py | Flask-Monolith: alle Seiten, APIs, Abrufe, Patch-Schichten (Marker) |
| config.py | Konfiguration/Schluessel (Rechte 600, nie lesen/ausgeben) |
| prepper_sdr.py | SDR-Dienst: besitzt alle Sticks/den Airspy, Planer je Geraet, Decoder, Watchdog, schreibt Zustand |
| sdr_manager.py | Lagezentrum-Logik im Dashboard: sdr_status/broadcast_state in die DB, Status SDR_OFFLINE/OK/PROBEALARM/ECHTALARM, Lebenszeichen 'hb' |
| database.py | SQLite-Zugriff lagezentrum.db: Schema, Migration, Retention; jede Funktion faengt Fehler ab |
| mesh_router.py | Dublettenpruefung der Mesh-Texte (md5, 24 h) und automatischer Versand echter Alarme an Mesh 1 (Kill-Switch mesh_auto.json) |
| lagegeo.py | Warngebiete (GeoJSON-Polygone) der NINA-Warnungen vereinfachen und cachen (Tabelle geo_cache) |
| prepper_sdr_net.py | einzige Netzzugriffe des SDR-Planers: Bahndaten (celestrak.org) und lokales welle-cli-JSON |
| prepper_evlog.py | Ereignis-Log fuer Stoersender/QRM, Gewitter, Dach-GPS, Trend und KFZ-Sensoren (nur Auswerten) |
| prepper_gps.py | Dach-GPS aus gpsd des Stratum-1-Servers lesen (nur lesen), GPS/GLONASS getrennt bewerten |
| mesh_bridge.py, mesh_bridge_bayern.py | je eine TCP-Session zum Mesh-Knoten, Queue, Pong, Inbox (Dienste mesh-bridge, mesh-bridge-bayern) |
| mesh_ping_reply.py, mesh_ping_reply2.py, mesh_ping_reply_bayern.py | Auto-Antwort auf ping/test (Dienste mesh-ping-reply, mesh-ping-reply-2) |
| mesh_rules.py | Regeln (mesh_rules.json): Hosts, Cooldown (20 s), welche Meldungsart auf welchen Knoten darf |
| mesh_chutil.py | Kanalauslastung (DeviceMetrics) je Knoten sammeln/lesen, Schwellen 25 % gelb / 40 % rot, Verlauf (mesh1_chutil.json, mesh2_chutil.json) |
| mesh_hang_watchdog.py (+ Units mesh-hang-watchdog.service/.timer) | Hang-Erkennung der Mesh-Verbindungen, Status mesh_hang_status.json, optionaler Neustart per Freigabe-Datei |
| mesh_reply_watch.py | letzte Ping/Test-Antwort (last_rx/last_tx) je Mesh in mesh1_reply.json/mesh2_reply.json |
| mesh_node_label.py | Knoten-Namen/Labels fuer Mesh-Meldungen (nicht naeher dokumentiert) |
| mesh_session.py, mesh_inbox_util.py | TCP-Sessions pruefen (ss -tnp) bzw. Inbox-Hilfen; oeffnen keine eigene Verbindung |
| funk_health.py, funk_page.py | Funk-Seite: Mesh-Status, Kanalauslastung Mesh 1/2, Seitenaufbau |
| nina_calm.py | NINA-Kachel/Mesh ruhig halten: Ablauf, Entwarnung 2 h, jede Meldungs-ID hoechstens einmal an Mesh |
| luft.py | Luftlage: FIRMS (Braende), Sensor.community (Feinstaub), Wind (Open-Meteo) |
| zuhause.py | Seite Zuhause: Abfall ERH, Apotheken-Notdienst, Tierkliniken, Notrufe |
| tiles_sources.py | Datenquellen-Liste der Kachel "Datenquellen" auf /pi |
| archive_store.py | Langzeitarchiv unter archive/ (nur lesen aus data_store, schreibt nur archive/) |
| speedtest_run.py | Ookla-Speedtest (alle 3 h zu :41 plus manuell), Ergebnis je Uplink |
| uplink_detect.py | Telekom/Starlink erkennen (alle 60 s) |
| watchdog.py | schlanker Dashboard-Watchdog: Dienst + GET / -> optional Neustart (Cooldown 30 min) |
| health_check.py | 12-h-Health-Report -> health_status.json (nie systemctl restart) |
| prepper_docs.py | Dieser Generator: erzeugt die Projektbeschreibung (TXT+MD) in docs/ |
| patch-mesh-hang-bridges.py, patch-mesh-traceroute-bridge.py, patch-mesh-traceroute-remove.py, patch-mesh-traceroute-remove-guard.py | aeltere Patcher-Skripte der Mesh-Familie (Hang-Erkennung in den Bridges; Traceroute-Funktion eingebaut und wieder entfernt); historisch, nicht erneut ausfuehren |
| tools/backup.sh | Backup-Skript fuer die Sicherung (Kachel "Sicherung") |

## Dienste (systemd) und Zeitsteuerung

- prepper-dashboard (Flask-Dashboard; einziger Dienst, den Patches neu starten), prepper-sdr (SDR-Dienst; nie durch Patches neu gestartet), mesh-bridge und mesh-bridge-bayern (Mesh-Sessions), mesh-ping-reply und mesh-ping-reply-2, kiwix (Offline-Wikipedia), chrony (Zeit), prepper-sd-health (.timer/.path, root, schreibt sd_health.json), mesh-hang-watchdog (.service/.timer), Watchdog- und Health-Timer des Dashboards, optional Speedtest-/Backup-Timer. Welche Units auf dem Pi wirklich existieren und laufen, ermittelt der Generator selbst (systemctl list-units/list-unit-files, nur lesend) und listet sie im Abschnitt 4.6.
- Systemeigene Units, die auf dem Pi ebenfalls auftauchen koennen (nicht Teil des Projekts): ssh.service, chrony.service (Zeit), systemd-timesyncd.service (nur Debian-Standard, nicht die Zeitquelle des Projekts), dpkg-db-backup.service/.timer (Debian-Paketdatenbank-Sicherung).
- Zeitplan der Hintergrundlogik (Auszug): Voll-Update alle 15 min; Speedtest alle 3 h (01:41, 04:41, ...); Rundfunk-Block von prepper-sdr alle 30 min (UKW-RDS und DAB+, Messzeiten fm_s/dab_s in sdr_config.json); Health-Check automatisch 09:00 und 21:00 (zusaetzlich Watchdog alle 5 min); Mesh-Wetter 0/3/6/9/12/15/18/21 Uhr; Datenbank-Aufraeumen alle 10 min; JSON-Notkopie von sdr_status/broadcast_state alle 10 min.

## Dateien im Projektordner (automatisch)

@@AUTO files@@

## Units und Hilfsprogramme (automatisch)

@@AUTO units@@

@@AUTO unitstate@@

@@AUTO external@@

## Verzeichnisse (automatisch)

@@AUTO dirs@@

# Seiten und Kacheln (seitenweise)

Das Hauptmenue hat 16 Eintraege (Reihenfolge): Lage (/), Energie, Lokale Energie, Speicher, Umwelt, Luft, Pegel, ADSB, Zuhause, Mesh 1, Mesh 2, News, Funk, Karte, System (= /pi), Medizin. Alle Seiten sind GET-Seiten ohne Anmeldung (nur Heimnetz). Zusaetzlich gibt es Seiten ausserhalb des Menues: /funk433, /aprs, /meteor, /rundfunk, /dabhist (Unterseiten der Funk-SDR-Kachel), /umwelt2 (aeltere Luft/Pegel-Seite) sowie die Weiterleitungen /scanner und /decoder (auf /), den Alias /lokal (= Lokale Energie) und /system (= /umwelt). Die Rauchtest-Liste jedes apply-Skripts prueft 12 Seiten und 14 APIs (26 Pruefungen, alle muessen HTTP 200 liefern; Liste im API-Katalog unten).

Die automatische Tabelle der Seiten mit Vorlage und Kachel-Ueberschriften folgt am Ende dieses Kapitels. Ein Kachel-Eintrag bedeutet: Titel, Zweck, Quelle, Besonderheit.

## / Lage (Startseite, "Seite 1 von 4")

- Kopf "KAESWASSER LAGE MONITOR" mit "Seite 1 von 4 · Update in n min" (Voll-Update alle 15 min) und die Menueleiste.
- Lage-Ampel (Patch teil4): gruen = OK, gelb = Probealarm, rot blinkend = Echtalarm, orange blinkend = SDR_OFFLINE (und Vor-Alarm), darunter eine Grund-Zeile ("Warnungen vorhanden", naechste Voll-Bewertung) und der SDR-Status (zum Beispiel "Status: SDR_OFFLINE - keine frische Telemetrie von prepper-sdr (Watchdog 15 s)"). Quelle: sdr_manager.py (Status aus lagezentrum.db).
- Uhrzeit, "Stratum Offset" (Zeitabweichung zum Stratum-1-Server, ntplib, STRATUM_IP aus config.py).
- Kachel "INTERNET": Haus/Welt/DE-Punkte, ONLINE/Stabil, Pfad Telekom/Starlink/unklar (uplink_detect.py), Latenz.
- Kachel "NETZFREQUENZ": Netzfrequenz in Hz (Quelle Netzfrequenzmessung; Nominal 50,000 Hz), "Keine Quelle" bei Ausfall; Mesh-Sendung bei Stufen siehe Kapitel 8.
- Kachel "NINA WARNUNGEN": aktive Warnungen fuer die Region (NINA/MoWaS; ninaCalm: abgelaufene weg, Entwarnung grau 2 h), je Meldung Status "Empfangen · Zeit", "Rücknahme Mesh", "Mesh gesendet"; Knopf "An Mesh 1 senden" (nur bei Klick, mit Bestaetigung; Patch lageMesh1). NINA-Warngebiete als Polygone aus lagegeo.py (fuer /karte).
- Kachel "BR24 WARNUNGEN" (#br24Tile; direkt unter NINA, Patch lageMesh1/br24Warn2): Zeilen "BR24 empfangen · DAB 11D + UKW 102,0" und "ASA DE · DAB 5C · keine Warnung" mit Zeitangaben, Hinweis zu den Sticks, Knopf "An Mesh 1 senden"; Warn-Score (stark/mittel/Anweisung, Entwarnung, Test); nur Empfang.

## /energie Energie

- "STROMPREIS AKTUELL": Day-Ahead-Strompreis (energy-charts, Fraunhofer ISE) mit Verlauf (strom_history.json).
- "ROHOEL": Brent in Euro (Quelle EuroOilWatch), 14-Tage-Verlauf (oil_history.json), Hoch/Tief seit Aufzeichnung (priceAllTime, price_alltime.json).
- "DIESEL REGIONAL": Dieselpreis regional (Tankerkoenig-API, Station aus config.py ELO_STATION_ID), Verlauf fuel_history.json.
- "NETZLAST DEUTSCHLAND": Last in GW und Differenz (energy-charts).
- "ERZEUGUNGSMISCHUNG (DE)": Anteile Wind/Solar/Gas/Kohle usw. (energy-charts).
- "EDELMETALLE & KRYPTO": Gold/Silber, Bitcoin, Ethereum (Metall-/Krypto-Quelle), Verlauf price_history.json.

## /lokale-energie Lokale Energie (Alias /lokal)

- "Lokale Energie · N-ERGIE" / "Strom N-ERGIE · Mittelfranken": Kachel "Status" mit offenen Ausfaellen in Mittelfranken (Kalchreuth/Schnaittach hervorgehoben), 14-Tage-Verlauf (outage_history.json), Quelle Stoerungsauskunft/N-ERGIE. Bei neuem Ausfall in der Naehe: Mesh-Meldung (Auto, mit Cooldown).

## /speicher Speicher

- Kopf "Gas- & LNG-Speicher"; Kacheln "Gasspeicher Deutschland" (GIE AGSI, Fuellstand, Trend), "LNG-Speicher Deutschland" und "LNG Ausspeise-Auslastung (Terminals)" (GIE ALSI). API-Schluessel API_KEY_GIE in config.py.

## /umwelt Umwelt ("Seite 3 von 4", Alias /system)

- "WETTER KALCHREUTH (90562)": aktuelle Temperatur, Sonnenstunden, 5-Tage-Vorhersage (Open-Meteo).
- "DWD WARNUNGEN": Warnungen fuer Kalchreuth, Forst, Erlangen, Kreis ERH, Schnaittach nach Stufe; Mesh-Status (analog NINA, bei Aenderung/Entwarnung).
- "DWD WBI · Waldbrand": Waldbrandgefahrenindex Station Nuernberg (3668), Stufe 1-5, kurzer Verlauf (dwd_wbi_status.json).
- "Wetter an Mesh": manueller Knopf und Auto-Sendung 0/3/6/9/12/15/18/21 Uhr an Mesh 1 (Status "A ·" = Auto, "M ·" = manuell).
- "SONNENAKTIVITAET": Kp-Index, 24-h-Maximum, G/R/S-Skalen (NOAA SWPC); Knopf "Sonnenaktivitaet an Mesh senden".
- "STRAHLUNG (ODL) · UMGEBUNG": BfS-Ortsdosisleistung Nuernberg, Lauf a.d. Pegnitz, Graefenberg, Mittelwert; Ampel gruen <= 0,25 µSv/h, gelb <= 0,60, darueber rot (Orientierung); Auto-Mesh bei Ampelwechsel, Knopf "ODL an Mesh senden".
- "STOERSENDER / QRM" (SDR, prepper-sdr): Rauschboden je Band (GPS/GLONASS ueber Dach-GPS, 2 m, UKW, DAB, PMR, 433, 868, MW, KW) gegen 7-Tage-Grundlinie (Median + MAD; gelb ab max(5 dB, 4xMAD), rot ab max(10 dB, 6xMAD)), Trend, neue Dauertraeger, 24 h/14 Tage-Kurve; nur Leistungsmessung, kein Inhalt. Zeilen "GPS"/"GLO" lernen zunaechst die Grundlinie ("lernt", grau).
- "EREIGNISSE (letzte 10)": Ereignis-Log der QRM-/GPS-Zustaende (prepper_evlog.py, Ring sdr_events.json + archive/evlog).
- "GEWITTER-HINWEIS": grober Hinweis aus breitbandigem Rauschen (nur Orientierung, kein Blitzortungsdienst).
- "Waldbrand"-Kacheln und weitere Kacheln sind auf voller Breite (Patch umweltWide, nur CSS/Klasse).

## /luft Luft

- "LAGE LUFT": Zusammenfassung; "FEINSTAUB": Sensor.community-Feinstaubsensoren der Umgebung mit Wind (Open-Meteo, Forecast); "BRAENDE FIRMS": NASA-FIRMS-Hotspots in der Naehe (firms_history.json, laedt beim Start); "MESH 1": Sendestatus Luft (Mesh 1; Feinstaub gelb/rot bzw. Entwarnung, Brand neu/weg; Knopf manuell, Auto bei Aenderung). Module: luft.py.

## /pegel Pegel

- "Schnaittach · 24228009" und "Lauf / Pegnitz · 24224008": Wasserstand (cm), 3-h-Trend (Patch pegelTrend, aus GKD-Rohwerten), Hochwasser-Meldestufen als Linien (config.py PEGEL_STATIONS), Quelle Gewaesserkundlicher Dienst Bayern (GKD).
- "Pegel an Mesh senden": manuell (M) und automatisch (A, Mesh-Wetter + 60 s) an Mesh 1.

## /adsb ADSB

- "Lokaler ADS-B Feeder" (tar1090/readsb auf 192.168.178.15: aktuelle Flugzeuge und Statistik), "Verlauf 14 Tage · Erkennung" (adsb_history.json), "Militaer (tar1090 dbFlags)", "Squawk / Notlage" (7500/7600/7700), "Sonder-Squawks (DE)", "Karten & Verlauf" (Links zu tar1090-Karte und Graphen). Nur Anzeige, nichts wird gesendet.

## /zuhause Zuhause

- "Muellabfuhr" (Abfallkalender Landkreis ERH, Kaeswasser), "Apotheken-Notdienst" (BLAK, naechste Notdienstapotheken), "Tierkliniken", "Notrufe & Wichtige Nummern" (Notrufnummern und wichtige Kontakte). Modul zuhause.py; Daten werden gecacht.

## /mesh Mesh 1 und /mesh2 Mesh 2

- "Verlauf · Kalchreuth G2" (Mesh 1) bzw. "Verlauf · Bayern G2" (Mesh 2): empfangene und gesendete Mesh-Texte (Inbox je Knoten, mesh_inbox*.json), Zaehler, Status.
- "Senden": Textfeld und Knopf (An Mesh 1/2 senden) fuer manuelle Nachrichten; Bestaetigung, Sende-Schutz funkHarden2, Cooldown 20 s (mesh_rules.json). Keine PIN-Sperre (Entscheidung Frank).
- Hold/Resume-APIs (/api/mesh_hold, /api/mesh_resume, /api/mesh2_hold, /api/mesh2_resume) pausieren bzw. setzen die Bridge-Verbindung fort (Wartung).

## /news News

- "Polizei Mittelfranken" (Pressemeldungen), "Deutschlandfunk", "Tagesschau", "NZZ · Blick von aussen" (RSS-Feeds; Knopf aktualisieren: /api/news_refresh). Nur Anzeige.

## /funk Funk (Funk-Lage und SDR-Steuerung)

Die groesste Seite (Patches funkUI, sdrUi, sdrAir/sdrAir2, sdrWd/sdrWd2, airTest, stickTest u. v. m.). Kacheln und Bereiche von oben nach unten:

- Banner "Mesh-Verbindungen OK · je eine TCP-Session" (funkHarden, mesh_session.py).
- "MESH-STATUS" je Knoten (Mesh 1, Mesh 2): LAN/Funk/TCP/Dienst, CLOSE-WAIT, Node-DB, lastHeard, Ping RX/Antwort, TX gesamt.
- "KANALAUSLASTUNG · MESH 1" und "Kanalauslastung · Mesh 2" (Air-TX, Mittel/Spitze 24 h/7 d, Telemetrie).
- "FUNK-LAGE": Gesamtstatus (OK/OFFLINE/Warnung), je Geraet eine Zeile mit Anzeigename "Name · Rolle" (zum Beispiel "Airspy R2 · 11D", "Stick 1 · 5C", "Stick 2 · Hobby", Stick 3), Ebene (REGIONAL-EBENE 11D, BUNDES-EBENE 5C), RSSI, BER (FIC) als Ersatzwert, SNR, Ensemble, ECC, LTO, TII/Mast, Alter der Daten; "ASA-Dienst" (ASA_INTERRUPTED: Dienst seit n s nicht empfangen, Soll 37 s, Grenze 55 s), "Vor-Alarm" (DSL/Netzfrequenz), "Auto-Versand Mesh 1 AN/AUS, letzte Stunde n/3", "Alarm", "Datenquelle" (DB primaer, JSON Notkopie).
- "Daten-Watchdog": Ampel und je Geraet eine ruhige Zeile; Stufen und Aktionen siehe Kapitel 6; "Pi-Neustarts heute".
- Links "Karte: Masten, Funkhorizont, Gefahrenzonen" (-> /karte) und "DAB-Meldungen und Technik-Verlauf" (-> /dabhist).
- Kachel "EMPFAENGER" (Funk-SDR-Kachel #sdrCard bzw. #sdrUiCard): Zeilen 433,92 MHz, APRS, UKW/DAB, ASA 5C, Meteor, Aktivitaet, QRM-Messung, Dach-GPS, Kalibrierung mit je AN/AUTO/AUS-Schalter (Quellen-Schalter, sdrLage), Status "läuft/nächst/vor n min", Lage-Profil, Zeitanteile je Geraet, Krisenzeile, Zeile "Geräte" (Register inkl. "erkannt, ohne Rolle"), Einzelempfang-Presets (sdrPreset, 30/60/120 min, Whitelist aus prepper_sdr.PRESETS), "Rundfunk", "BR24 (DAB 11D)", "ASA DE (DAB 5C)", "Stoerer/QRM", "Gewitter", "Dach-GPS".
- "STEUERUNG": Lage-Profil (zum Beispiel "Warnlage (angepasst)"), Modus Automatik; Kachel "Gain-Automatik" (#agCard, Patch autoGain: aktueller Gain, Schalter Auto/Fest mit Rueckfrage, Grund des letzten Wechsels, Verlauf, Messtabelle mit Score, Knoepfe "Jetzt messen" und "Gain-Test 2 starten") direkt vor der Kachel "Gain-Test" (airTest: Gain-Test 1 = Stufen 12/19/21, Gain-Test 2 = 14/16/17/18 plus Auto, je 5 Runden; ein Test aendert selbst keinen Gain), Kachel "Antennentest - im Geraete-Register-Betrieb" (#stickTestCard; stickTest: Stick-Zuordnungstest, Grundlinien neu lernen, Rollen-Tausch nur auf Befehl) ganz unten im Raster.
- Kachelbreite (Patch autoGain): Auf dem iPhone waren alle Kacheln nach "Mesh-Status" zu breit. Ursache: Das Kachel-Raster (.grid, display:grid) hatte nur eine automatische Spalte; die nicht umbrechende Tabelle der Gain-Test-Kachel (white-space:nowrap) machte die Spalte und damit alle Kacheln im Raster breiter als den Bildschirm (544 statt 366 px bei 390 px). Mesh-Status liegt ausserhalb des Rasters und blieb schmal. Behebung: Raster mit minmax(0,1fr) (zwei Spalten ab 900 px), min-width:0 an den Kacheln, Tabelle der Gain-Test-Kachel umbrechend. Geprueft per DOM-Test bei 390 und 430 px (alle Kacheln gleich breit, Seite nicht breiter als der Bildschirm).
- "EREIGNIS-HISTORIE (LETZTE 10)": Ereignisse aus NINA, BR24, DAB, SDR (Watchdog, Vorfaelle, Uebernahmen).
- Meteor-Kachel und die Unterseiten-Links (433 MHz, APRS, Rundfunk, Meteor).

## /funk433 Funk 433 MHz

- "SDR-Empfaenger (Nooelec NESDR SMArt v5)" (Kopf der SDR-Seiten, #sdrHead), "433-MHz-Sensoren" (rtl_433-Telegramme, ISM, Zaehler, letztes Telegramm), "KFZ-Sensoren (TPMS)" (letzte 10, Sichtungen/Sensoren heute; IDs in voller Laenge, fremde nach 30 Tagen entfernt; nur Beobachtung). Daten: rtl433.jsonl, funk433_state.json, sdr_kfz.json.

## /aprs APRS

- "APRS-Stationen", "APRS-Wetterstationen", "APRS-Nachrichten & Bulletins": APRS auf 144,800 MHz (rtl_fm | direwolf), nur Empfang, Daten aprs.jsonl/aprs_state.json.

## /meteor Meteor-M

- "Meteor-M Wettersatellit" (Meteor-M LRPT 137,9 MHz, satdump; Empfang bei Ueberfluegen >= 20 Grad hat Vorrang), "Naechste Ueberfluege" (TLE von celestrak.org, im Cache auch offline), "Bilder" (Galerie mit Vorschaubildern /meteor/thumb/<name>, Original /meteor/img/<name>).

## /rundfunk Rundfunk

- Hinweis "TA ist nur ein Kennzeichen 'Verkehrsdurchsage laeuft' im Audio" (kein Text), "Ereignisse letzte 48 h" (TA, Ansagen, DLS-Texte, Warn-Score; /api/broadcast/events), "UKW-Sender (RDS)" (PS, Radiotext, PI, TA, PTY), "DAB+-Dienste" (welle-cli: Ensembles, Dienste, DLS). Nur BR24-Texte (+ ASA DE) werden als Warntexte bewertet (Patch br24Warn2).

## /dabhist DAB-Meldungen

- "DAB-Empfang · Masten (Datenbank)" (dqCard, dabSql: Kanaele aktiv/offline/nicht geprueft, bekannte/unbekannte Masten, Herkunft der Koordinaten), "DAB-Meldungen und Technik" (Verlauf aller DAB-Textmeldungen und Ansagen von 11D und 5C, gleiche Folgemeldung nur zuletzt/Anzahl; Technik-Verlauf: Sync verloren/wieder da, Ensemble-ID-Wechsel, Mast gesehen/weg, FIG 0/9), Tageskarten.

## /karte Karte

- Eigene Seite (kartevec, nach Funk im Menue, Raster 4x4): Leaflet-Karte (lokal unter static/leaflet, Kartenkacheln werden nicht aus dem Internet gebraucht, soweit konfiguriert; sonst: nicht dokumentiert/zu pruefen) mit DAB-Masten, Funkhorizont, Gefahrenzonen (NINA-Polygone aus lagegeo.py) und TII-Vektorlinien je Mast (alle 5 s: /api/t4/tii, tii_seen). Die Kacheln sind rein JavaScript; serverseitig gibt es nur das Geruest (/karte/res/<path> liefert Dateien).

## /medizin Medizin ("Seite 4 von 4")

- "WikiMed offline · Vollbild oeffnen": Kiwix (Offline-Wikipedia/Medizin) eingebettet per iframe (Port 8080; Link "Vollbild oeffnen"). Ist der Dienst kiwix aus, bleibt die Seite leer.

## /pi System (Pi und Internet, Menue "System")

Von oben nach unten (die Reihenfolge ist durch Patch piPolish/piPolish2 und projDoc festgelegt; "Sicherung" ist bis zum Patch projDoc die letzte Kachel, danach kommt als allerletzte Kachel die Projektbeschreibung):

- "HEALTH CHECK": Gesamtampel (zum Beispiel OK 19/19), Pruefungen compile, svc_*, page_*, kiwix, mesh, disk, ram, temp, throttle, chrony, apt; Auto 09:00/21:00, Watchdog 5 min. Quelle health_status.json (health_check.py).
- "DATENQUELLEN": je Quelle Name, Herkunft und Zeit des letzten Abrufs (gruen ok, gelb 1-4 Fehler, rot 5+); Knopf "Update manuell" (/api/sources/update). Liste aus tiles_sources.py.
- "INTERNET": Verbindung (Telekom/Starlink/unklar), Ping 8.8.8.8, oeffentliche IP (nur Anzeige), Latenz.
- "SPEEDTEST (OOKLA)" (Box #stBox im Internet-Kachel): Ergebnisse je Uplink, Diagramm 14 Tage (Telekom/Starlink, gestrichelt = Upload), Starlink-Wechsel gesamt, Knopf "Speedtest jetzt" (/api/speedtest). Fester Server Nuernberg, alle 3 h.
- "SYSTEMSTATUS (PREPPER-PI)": CPU, RAM, Temperatur, Uptime, Festplatte, Boot-Laufwerk.
- "DIENSTE": Mesh (G2) und Kiwix mit Erreichbarkeit.
- "SDR-DATEN-WATCHDOG" (#wdPiBox): Ampel je Geraet (Airspy R2 · 11D, Stick 1 · 5C, Stick 2 · Hobby nur Beobachtung), Stufen: gelb ab 10 min, Neustart von welle-cli/rtl_tcp des Sticks ab 30 min, USB-Neuverbindung ab 45 min (max 2), Pi-Neustart ab 60 min (max 1 je 60 min, Stopp nach 3 ohne Erfolg). Patches duerfen diese Aktionen nie ausloesen.
- "SSD · MASTER" (#ssdCard; Titel zeigt zusaetzlich den Zustand, zum Beispiel "Fehler - Backup pruefen!"): Boot-Ampel, Boot-Reihenfolge, Laufwerk, SMART, Belegung, Schreiblast, Fehler (Kernel/ext4), letzter Klon, Knopf "Quittieren & neu pruefen".
- "SD · FALLBACK": Karte vorhanden, Klon bereit, letztes Ergebnis, Knopf "Jetzt von SSD auf SD klonen" (gesperrt ohne Karte; Hintergrundjob /api/clone/start, /api/clone/status), Liste der letzten Klone (nur auf Knopfdruck).
- "ARCHIV" (#archCard): Zustand des Langzeitarchivs (Reihen, Punkte, Ereignisse, Groesse, frei, Reichweite; Rohdaten 90 Tage, danach Tageswerte) aus archive_store.py.
- "SICHERUNG" (#backupBox): Sicherung der Projektdateien/DB (tools/backup.sh), Liste der 5 neuesten, Knopf "Sicherung jetzt" und Wiederherstellung (doPrepperRestore). Muss unveraendert bleiben; die Kachel steht vor der Projektbeschreibung.
- "PROJEKTBESCHREIBUNG LAGE PI" (#projDocBox, Patch projDoc; allerletzte Kachel): Version "vJJJJMMTT-HHMM", Erzeugungszeit (Berlin), Groesse, Knopf "TXT herunterladen" (Dateiname "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt"), Markdown-Download, Liste aelterer Versionen, Hinweis "Neue Version: auf dem Pi python3 prepper_docs.py".

## /umwelt2 (aelter, nicht im Menue)

- "Luftqualitaet · Erlangen" und "Pegel · Pegnitz und Umgebung": aeltere kombinierte Seite; wird weiter ausgeliefert, damit alte Links gehen.

## API-Katalog (alle Endpunkte, redaktionell)

Wichtig vorab (Stand nach Patch meshPost): Diese Endpunkte SENDEN an das Mesh, und zwar ausschliesslich per POST von der eigenen Seite: /api/mesh_send, /api/mesh2_send, /api/mesh_test, /api/lage_mesh1/send sowie die fuenf Knopf-Wege /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather (vor meshPost waren diese fuenf GET und sendeten beim blossen Aufruf, mit force=True). Seit meshPost sendet ein GET auf diese Wege nie: er liefert eine Vorschau (HTTP 200, JSON mit ok=false, sent=false, preview=true und dem Text, den der Knopf senden wuerde; nur aus dem Zwischenspeicher, beim Wetter mit gepufferter Open-Meteo-Abfrage) bzw. bei /api/mesh_test HTTP 405 mit Allow: POST. Ein POST wird nur angenommen, wenn er von der eigenen Seite kommt (Origin/Referer = eigene Adresse, Sec-Fetch-Site nicht fremd, Kopf X-Mesh-Post: 1, Inhaltstyp JSON), sonst HTTP 403 ohne Senden; kein PIN. /api/mesh_freq ist seit lageMesh1 abgeschaltet (HTTP 410). Auch mit diesem Schutz gilt: Tests, Rauchtests, Simulationen, Monitoring, Crawler und Link-Pruefer duerfen diese Wege nie per POST aufrufen. Weitere Schalter: /api/nina_bayern_auto (POST schaltet den NINA-Auto-Weg fuer Mesh 2) und /api/t2/autosend (POST schaltet den Auto-Versand echter Alarme). Der Rauchtest ruft nur die 14 lesenden APIs unten auf; die Vorschau-Wege ruft er nicht auf (/api/meshpost/status zeigt stattdessen nur lesend, ob alle sechs Wege geschuetzt sind).

Die 26 Rauchtest-Pruefungen: 12 Seiten (/, /funk, /pi, /umwelt, /funk433, /aprs, /meteor, /rundfunk, /energie, /dabhist, /mesh, /karte) und 14 APIs (/api/sdr/ui, /api/sdr/wd, /api/br24, /api/sdr/sticktest, /api/sdr/live, /api/sdr/map, /api/broadcast/events, /api/t2/status, /api/t3/status, /api/t4/status, /api/t4/map, /api/t4/tii, /api/meteor, /api/sdr/status). Alle muessen HTTP 200 liefern; jeder Patch fuegt eigene Pruefungen hinzu (zum Beispiel die Reihenfolge der Kacheln auf /pi).

| Pfad | Methode | Zweck |
|---|---|---|
| /api/sdr/ui | GET | Daten der SDR-Kachel /funk (Chips, Modus, Schalter, Presets, Zeitanteile) |
| /api/sdr/wd | GET | Daten-Watchdog je Geraet (Stufe, ohne Empfang seit, USB-Resets, Pi-Neustarts) |
| /api/sdr/live | GET | Lagezentrum-Status (SDR_OFFLINE/OK/PROBEALARM/ECHTALARM) und Telemetrie je Geraet |
| /api/sdr/lage | POST | Lage-Profil und Quellen-Schalter AN/AUTO/AUS setzen (schreibt nur Konfigurationsdatei); Lesen ueber /api/sdr/ui |
| /api/sdr/status | GET | rohes sdr_status (aus der DB, JSON als Ersatz) |
| /api/sdr/map | GET | Masten, Funkhorizont, Gefahrenzonen fuer /karte |
| /api/sdr/mode, /api/sdr/preset, /api/sdr/presets, /api/sdr/release | POST/GET | Betriebsart setzen (schreibt sdr_mode.json), Preset waehlen (nur Whitelist), Presets lesen, Stick freigeben (Datei sdr_release_req); schreiben nur Anforderungsdateien, senden nichts |
| /api/sdr/activity, /api/sdr/noise, /api/sdr/evlog | GET | Aktivitaet, Stoer-/Rauschwerte (QRM, Gewitter, GPS), Ereignis-Log |
| /api/sdr/airtest | GET/POST | Gain-Test Airspy 11D (Status lesen bzw. Start/Abbruch anfordern, nur Empfang); POST start optional mit profile t1 (12/19/21) oder t2 (14/16/17/18 + Auto); GET enthaelt seit autoGain je Stufe den Score |
| /api/sdr/autogain | GET/POST | Gain-Automatik Airspy 11D (Patch autoGain): GET Zustand (Modus, aktueller Gain, Grund des letzten Wechsels, Verlauf, Sperre, Messtabelle); POST action auto, fest oder measure schreibt nur die Anforderungsdatei sdr_autogain_req.json (nur von der Funk-Seite im Heimnetz, mit Bestaetigung); prepper-sdr entscheidet |
| /api/sdr/sticktest | GET/POST | Antennentest/Stick-Zuordnungstest (Status; Start, Neu lernen, Rollen-Tausch nur auf Befehl) |
| /api/br24 | GET | BR24-/ASA-Warnstand (Warn-Score, Text, Zeit) fuer Lage-Seite und Funk |
| /api/broadcast, /api/broadcast/events | GET | Rundfunkzustand (UKW/DAB) und Ereignisse der letzten 48 h |
| /api/aprs, /api/funk433, /api/meteor | GET | APRS-Stationen, 433-MHz-Sensoren, Meteor-Zustand/Ueberfluege/Bilder |
| /api/kfz/own | POST | eigenen KFZ-Sensor markieren (nur von der eigenen Seite: Origin/Referer + Header X-Evl, maximal 512 Byte) |
| /api/dabsql/status | GET | DAB-Datenbankzusammenfassung (Kanaele, Masten, Herkunft der Koordinaten) |
| /api/t2/status, /api/t3/status, /api/t4/status | GET | Teil-2/3/4-Status (Alarmuebernahme historisch, Routing, Lage-Ampel/SDR-Kacheln) |
| /api/t4/map, /api/t4/tii | GET | Kartendaten bzw. TII-Vektorlinien je Mast (alle 5 s) |
| /api/t2/stick2, /api/t4/sdr2 | POST | historische Stick-2-Uebernahme-Schalter; seit sdrAir ohne Wirkung auf Sticks (Register entscheidet) |
| /api/t2/autosend | POST | Schalter "Auto-Versand echter Alarme an Mesh 1" AN/AUS (mit Rueckfrage; Kill-Switch mesh_auto.json) |
| /api/lage_mesh1, /api/lage_mesh1/send | GET/POST | Lage-Seite: Knopf "An Mesh 1 senden" (GET Status; POST sendet NINA/BR24 nur bei Klick mit Bestaetigung) |
| /api/mesh_send, /api/mesh2_send | POST | manuelle Textnachricht an Mesh 1 bzw. 2 (Seiten /mesh, /mesh2) |
| /api/mesh_hold, /api/mesh_resume, /api/mesh2_hold, /api/mesh2_resume | POST | Bridge-Verbindung pausieren/fortsetzen (Wartung) |
| /api/mesh_inbox | GET | letzte Mesh-Nachrichten (src=local oder bayern) |
| /api/mesh_watch | GET | Bridge-Zustand, Alter der Inbox, letzter Versand je Knoten |
| /api/mesh_test | POST (GET = 405) | manueller NINA-Test an beide G2 (sendet "NINA Test" auf Kanal 0); nur POST von der eigenen Seite (meshPost), hoechstens 1x pro Minute (funkHarden2) |
| /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather | POST (GET = Vorschau) | Knoepfe "Wetter/ODL/Pegel/Luft/Sonnenaktivitaet an Mesh senden": POST von der eigenen Seite sendet (bestehende Logik, force=True); GET zeigt nur den Text und sendet nichts (Patch meshPost) |
| /api/mesh_freq | GET (HTTP 410) | Knopf Netzfrequenz an Mesh: seit lageMesh1 abgeschaltet, sendet nie |
| /api/meshpost/status | GET | nur lesen: Pfad, Methoden und Schutz-Zustand der sechs Sende-Wege, Zaehler (GET-Vorschauen, abgelehnte/angenommene POST) seit Start (Patch meshPost) |
| /api/nina_bayern_auto | GET/POST | Zustand/Schalter (nina_bayern_auto.json, Standard AUS) des automatischen NINA-Wegs fuer Mesh 2 |
| /api/funk/atomic, /api/funk/harden, /api/funk/chutil, /api/funk/mesh_session | GET | Funk-Seite: atomare Dateien, Sende-Schutz-Status, Kanalauslastung, Mesh-Sessions |
| /api/frequenz, /api/ping, /api/time, /api/uplink | GET | Netzfrequenz live, letzter Ping, Serverzeit, Uplink-Erkennung |
| /api/speedtest, /api/speedtest/history, /api/download_test | GET/POST | Ookla-Speedtest starten/lesen, Verlauf; aelterer Download-Test |
| /api/news_refresh (GET), /api/sources/update (POST) | GET/POST | News bzw. alle Quellen manuell neu abrufen (nur Abrufe, keine Sendung) |
| /api/archive/status, /api/archive/<series> | GET | Langzeitarchiv: Status und Reihen |
| /api/sd_health, /api/sd_health/ack | GET/POST | SD-/Laufwerk-Ampel lesen bzw. quittieren (schreibt sd_health_ack.json) |
| /api/sysboot/status, /api/sysboot/disk | GET | Boot-/Laufwerk-Zustand (SSD/SD, SMART) |
| /api/clone/start, /api/clone/status | POST/GET | SD-Klon auf Knopfdruck starten bzw. Stand lesen |
| /api/backup, /api/backup/restore | POST | Sicherung jetzt bzw. Wiederherstellung (Kachel Sicherung) |
| /api/scanner_mode | GET/POST | veralteter Scanner-Modus (Weiterleitung /scanner, /decoder auf /) |
| /api/docs/list, /api/docs/download, /api/docs/routes | GET | Projektbeschreibung (Patch projDoc): Versionsliste, Download (fmt=txt|md, v=JJJJMMTT-HHMM), Routenliste fuer den Generator; nur Lesen aus docs/ |

## Automatische Seitenkarte

@@AUTO pagemap@@

## Kachel-IDs im HTML/JS (automatisch)

@@AUTO ids@@

# SDR-Subsystem (prepper-sdr)

## Grundprinzip

- prepper_sdr.py ist ein eigener Dienst (prepper-sdr; Aufruf run | selftest | status). Er besitzt alle SDR-Geraete, teilt die Zeit auf und ist der einzige Prozess, der Sticks oeffnet. Das Dashboard liest nur: Zustand kommt ueber lagezentrum.db (Tabelle state, Schluessel zum Beispiel sdr_status, broadcast_state) und JSON-Notkopien (sdr_status.json, broadcast_state.json, sdr_dabhist.json, sdr_events.json, sdr_kfz.json, sdr_techlog.json, sdr_wd.json u. a.).
- Betriebsart und Schalter: sdr_mode.json (schreibt das Dashboard), sdr_config.json (Geraete-Register devs, Rollen, Messzeiten, Schalter wie dabsql, devs_on, air_fe), Anforderungsdateien fuer Antennentest/Gain-Test/Gain-Automatik (sdr_req_*, sdr_airtest_req.json, sdr_autogain_req.json). Das Dashboard schreibt nur diese kleinen Anforderungen, nie Steuerbefehle direkt an die Geraete.
- Nur Empfang: Rundfunk (UKW-RDS, DAB+), Wettersatellit (Meteor-M LRPT 137,9 MHz), ISM (433,92 und 868,3 MHz) und Amateurfunk-APRS (144,800 MHz). Fehlt ein Stick, wartet der Planer ruhig (kein Neustart-Karussell).
- Ein Planer je Geraet in einem Prozess (Patch sdrDual): Airspy fest 11D, Stick 1 fest 5C, Stick 2 Hobby. Die Zuordnung steht im Geraete-Register (sdrAir) und wird ueber die Seriennummer aufgeloest, nicht ueber Port oder Index.

## Planer und Betriebsarten

- Bloecke: 433 (rtl_433 -> rtl433.jsonl + funk433_state.json), aprs (rtl_fm | direwolf -> aprs.jsonl + aprs_state.json), tcp (rtl_tcp Port 1234 fuer SDR-Apps im LAN, Decoder pausiert, endet automatisch), bc (Rundfunk-Block alle 30 min: UKW-RDS ueber rtl_fm | redsea mit PS/Radiotext/TA/PTY und DAB+ ueber welle-cli mit DLS/Ansagen), meteor (satdump bei Ueberfluegen >= 20 Grad, hat dann Vorrang).
- Presets (Einzelempfang, Whitelist PRESETS in prepper_sdr.py, nie freie Eingabe): 433, 868, APRS, UKW-Sender (BR24 102,0; Bayern 3 97,9; Bayern 1 88,9; Bayern 2 92,3; BR-Klassik 87,6; Gong 97,1; Charivari 98,6; Hit Radio N1 92,9; UKW 98,0), DAB-Kanaele (zum Beispiel 10D BDR-Testkanal fuer ASA-Tests). Dauer 30/60/120 min, danach zurueck zur Automatik.
- Quellen-Schalter AN (laeuft fest) / AUTO (nach Plan) / AUS (pausiert) je Quelle; Lage-Profile ("Warnlage (angepasst)" u. a.) verschieben die Zeitanteile (Patch sdrLage).
- Rundfunk-Rotation des Hobby-Sticks: UKW-RDS BR24 / Bayern 3 / Bayern 1 im Wechsel; alle 6 Stunden zusaetzlich eine 10C-Pruefung (Lokal Nuernberg, 213,360 MHz); dazu QRM-Messung (rtl_power, alle 15 min, Fenster mit Zuschlag, SIGINT statt Abschuss), Kalibrierung (ppm je Stick), 433 und APRS.

## DAB+ Empfang

- 11D (222,064 MHz, Ensemble BR Bayern, ECC 0xe0, LTO +2 h): Airspy R2 mit welle-cli -F airspy, Port 7979. Der Gain wird ueber eine Gain-Leiter (feste Stufen) gefuehrt; Ein Gain-Test veraendert den Standard-Gain nie (airTest: Gain-Test 1 = Stufen 12/19/21, Gain-Test 2 = 14/16/17/18 plus Auto, je 5 Runden, nur auf Anforderung, endet immer mit dem Standard-Gain). Den Standard-Gain aendert nur die Gain-Automatik (Patch autoGain, siehe unten) oder die Gain-Leiter bei Sync-Verlust.
- 5C (178,352 MHz, 1. Bundesmux, DR Deutschland): Stick 1 fest. Dient der ASA-DE-Warnung (Automatic Safety Alert). Rueckfall 10C (Lokal Nuernberg), solange 5C nach 2 Pruefungen keinen Sync hat; 5C wird alle 10 min erneut versucht und bei Sync wieder gewaehlt (sdrTeil4, jetzt vom Geraete-Register gefuehrt; Rueckfall-Meldung nur vom 5C-Planer, Entprellung 60 s, je Richtung hoechstens 1 Ereignis je Stunde: sdrFall).
- DAB ueber rtl_tcp mit fester Verstaerkung statt der Software-AGC von welle-cli (dabGain), Sync zaehlt nur bei echtem Ensemble (dabFix), bekannte Rundfunktraeger werden nicht als Stoerer gewertet.
- Empfangsguete: welle-cli liefert keine Bitfehlerrate. Angezeigt wird deshalb die FIC-Fehlerrate (FIC-CRC-Fehler / (Messdauer x 125 FIB/s, DAB Mode I)) als "BER (FIC)"-Ersatz, dazu SNR, Sync, Ensemble, TII. Das steht auch an den Kacheln, damit niemand eine echte BER annimmt.
- Masten/TII: dabSql schreibt jede Pruefung in reception_log, masts und channel_status (lagezentrum.db; Mastenliste aus T4_MASTS importiert, unbekannte TII werden automatisch angelegt, Koordinatenherkunft pos_src als Label: Wikipedia/OSM/Frank/Kopie); Uhr-Schutz: Aufraeumen und Offline-Rechnung nur bei plausibler synchroner Uhr (sdrRest/sdrRest2). Kanal 10C zeigt "nicht geprueft" statt "offline", solange der Hobby-Stick belegt ist.
- Verlauf aller DAB-Textmeldungen und Ansagen (dabHist): gleiche Folgemeldung nur zuletzt/Anzahl; Ring sdr_dabhist.json und Archiv archive/dabhist/JJJJ-MM/*.jsonl. Technik-Verlauf (sdrLog): sdr_techlog.json + archive/techlog.
- UKW-RDS: Notfall ("RDS Notfall") nur bei echten Kennzeichen (rdsNotfall): PTY 31 (Alarm), Gruppe 9A (EWS, mindestens 3 mal in 60 s, nicht als ODA belegt) oder Warnwoerter im RadioText; PTY 30 (Alarmtest) gilt nur als Test; TA, PTY Finance und 1A-EWS-Kennungen allein sind kein Notfall.

### Gain-Automatik fuer den Airspy 11D (Patch autoGain, commit16)

- Quelltext-Pruefung welle-cli (welle.io, master): Option -g <gain> mit -1 = Automatik. Beim Airspy ruft welle-cli dann setAgc(true) auf: das ist eine Software-AGC in welle-cli (CAirspy), keine Hardware-AGC des Airspy. Sie stellt die lineare Verstaerkungsstufe (0 bis 21, Start 10) alle 10 Frames um 1 nach: Spitzenamplitude ueber 0,2 = eine Stufe runter, unter 0,02 = eine Stufe hoch. Ohne -g gilt dasselbe wie -1. Die Gain-Leiter kennt "agc" bereits als letzte Notstufe. Die Automatik waehlt Auto (-1) nie selbst; Auto wird nur im Gain-Test 2 mitgemessen (mit der von welle-cli gemeldeten Hardware-Stufe) und angezeigt.
- Messung: etwa taeglich im Nachtfenster 01:00 bis 04:59 (spaetestens nach 36 h ohne Messung) und nach anhaltend schlechtem Empfang (Score unter 60 ueber 3 Stunden bei mindestens 24 Pruefungen, hoechstens alle 6 Stunden). Eine Tagesmessung prueft die aktuelle Stufe und ihre Nachbarn aus dem Raster 12/14/16/17/18/19 (5 Stufen, je 3 Runden, ca. 15 bis 20 Minuten) mit der airTest-Maschine: nur Pruefbloecke der 11D (je ca. 60 s), der gespeicherte Standard-Gain bleibt unveraendert.
- Score (0 bis 100): ohne Sync 0; sonst 100 minus 6 Punkte je Prozent FIC-Fehler (am staerksten gewichtet, begrenzt auf 12 %) minus 1,5 Punkte je dB SNR unter 12 dB (begrenzt auf 10 dB). Messwerte: Stufe 12 (FIC 1,96 %, SNR 9,0) schlaegt Stufe 16 im Betrieb (FIC 5,07 %, SNR 13,9); dass Stufe 16 schon Uebersteuerung streift, ist unbewiesen und wird nur ueber den Score geprueft.
- Entscheidung nur bei klarem Vorteil ueber mehrere Messungen: aus den letzten 3 Sitzungen; die Zielstufe muss in mindestens 2 Sitzungen zusammen mit der aktuellen Stufe gueltig gemessen sein (mindestens 2 Messungen je Stufe), in mindestens 2 davon um mindestens 6 Score-Punkte besser sein, im Mittel mindestens 6 Punkte, mit Sync mindestens 80 %, und die neueste Sitzung darf nicht widersprechen. Mindestabstand zwischen zwei Wechseln 6 Stunden.
- Gain-Wechsel nie bei Alarm, ASA-Warnung/Ansage auf 5C, RDS-Alarm PTY 31, Antennentest, Meteor-Aufnahme, Alarm-Uebernahme, USB-Neuverbindung oder laufender Messung (dieselben Sperren wie der Daten-Watchdog); ein Pruef-Fehler zaehlt als gesperrt. Ein Wechsel wartet, bis die Sperre weg ist (verfaellt nach 6 Stunden), und wird mit dem naechsten 11D-Pruefblock wirksam: welle-cli startet dabei mit dem neuen -g neu.
- Nach einem Wechsel wird der Empfang (reception_log, ohne Testfenster) mit dem Stand der 24 Stunden davor verglichen: schlechter (Score um mehr als 10 Punkte oder Sync um mehr als 15 Prozentpunkte) = zurueck auf den alten Wert und Sperre.
- Flip-Flop-Schutz: Wuerde ein dritter Wechsel innerhalb von 48 Stunden anstehen (mehr als 2 Wechsel in 48 h), oder wird der Empfang nach einem Wechsel schlechter, sperrt die Automatik den besten festen Wert (Sperre, Modus Auto bleibt angezeigt als "gesperrt"). Die Sperre gilt, bis Frank auf /funk wieder Auto einschaltet (Knopf hebt die Sperre auf und setzt den Wechsel-Zaehler zurueck).
- Fehler: drei Fehler in Folge in der Logik oder eine unlesbare Zustandsdatei = Automatik aus, Sperre, Rueckfall auf Stufe 16 (Gain 16 gilt auch ohne diese Datei als Standard).
- Dateien: sdr_autogain.json (Zustand, atomar geschrieben: Modus auto/fest, aktuelle Stufe, Sitzungen, Verlauf, Wechselzeiten, Sperre, offene Entscheidung), sdr_autogain_req.json (Anforderung des Dashboards: auto, fest, measure). Das Dashboard schreibt nur die Anforderung; die Automatik laeuft ausschliesslich im Dienst prepper-sdr (Tick alle 20 s im Planer-Schritt, keine neue Programmschnittstelle, kein neuer Faden, kein sudo-Recht, nichts ans Mesh).
- Wirkung auf Gain-Leiter und Watchdog: Standard-Gain kann jetzt jede ganze Stufe 0 bis 21 sein (vorher nur 16/12/19/9/21/agc); verliert die Automatik-Stufe den Sync, laeuft die Leiter wie bisher (zuerst 16, dann 12, 19, 9, 21, agc) und der Verlauf vermerkt "Gain-Leiter".

## Daten-Watchdog (je Geraet)

- Misst die Zeit seit dem letzten ECHTEN Empfang (DAB-Sync mit Ensemble, RDS-Gruppen). Stufe 1 ab 10 min gelb (Gain-Leiter laeuft weiter), Stufe 2 ab 30 min Neustart von welle-cli und rtl_tcp dieses Sticks, Stufe 3 ab 45 min USB-Neuverbindung nur dieses Sticks (per Seriennummer, USB-ID 0bda:2838, root-Hilfsprogramm, maximal 2 je Vorfall), Stufe 4 ab 60 min Pi-Neustart (maximal 1 je Stunde; nach 3 erfolglosen keine weiteren: Stick/Antenne pruefen).
- Stufen 2-4 laufen nie bei Alarm, ASA-Warnung, PTY 31, Antennentest, Meteor und analogen Sperren. Das Hobby-Geraet wird nur beobachtet (kein Neustart/USB/Pi-Neustart) und zaehlt nicht in die Gesamtstufe (sdrAir2). Zustand: lagezentrum.db (state sdr_wd) + sdr_wd.json (ueberlebt Neustart); Schwellen und Schalter in sdr_config.json.
- Planer-Waechter sdrHalt: haengt ein Planer-Faden (kein Planer-Schritt seit 10 min) und ist keine Sperre aktiv, laesst der Dienst sich per sd_notify (WATCHDOG=trigger) kontrolliert neu starten; hoechstens 3 je Stunde, nie in Sperren, mit Protokollzeile; ohne systemd-Watchdog keine Aktion. Dazu stuendliche Pruefung des root-Hilfsprogramms (nur check). Das ist der EINZIGE Selbstneustart von prepper-sdr.
- Stick-Index und Seriennummern werden im Lauf nur lesend geprueft (sysfs, kein Stick geoeffnet, Stick 3 nie); bei Abweichung Journalzeile und frische Aufloesung beim naechsten regulaeren Start (sdrRest2).

## Stoerer, Gewitter, GPS, Ereignisse

- QRM/Stoersender (sdrNoise/sdrNoise2): Rauschboden je Band gegen 7-Tage-Grundlinie (Median + MAD, MW/KW je Tagesstunde); gelb ab max(5 dB, 4xMAD), rot ab max(10 dB, 6xMAD); langsamer Anstieg als Trend; neue Dauertraeger; Gewitter-Hinweis aus breitbandigem Rauschen. Nur Leistungsmessung, kein Inhalt, keine Peilung; eigene Geraete (Netzteile, Pi, LED) stoeren oft selbst.
- Dach-GPS (prepper_gps.py, gpsLearn): TCP-Client zu 192.168.178.15:2947, sendet nur das feste ?WATCH, liest einige Sekunden TPV/SKY; GPS (gnssid 0) und GLONASS (gnssid 6) getrennt, Signalstaerke je Hoehenband gegen die 7-Tage-Grundlinie; gelb/rot wie QRM oder bei Fix-Verlust; Anlernphase "lernt (noch ~n h)".
- Ereignis-Log (prepper_evlog.py, evLog): Ereignis oeffnet, wenn ein Band/System nicht mehr gruen ist, schliesst bei gruen; Luecken < 5 min werden zusammengefasst. KFZ-Sensoren (TPMS aus dem rtl_433-Strom): Ring sdr_kfz.json, Archiv archive/evlog/*/kfz.jsonl.
- welle-cli-Faehigkeiten: prepper-sdr durchsucht das Programm nur lesend nach Alarmflag (FIG 0/0), Ansagen (FIG 0/18-19) und ASA/EWS; Ergebnis: welle-cli liefert weder Alarmflag noch Ansagen noch ASA als Datenfeld, nur den DLS-Text ist auswertbar. Deshalb basiert die ASA-Erkennung auf dem Dienst-Label "ASA" im Ensemble 5C (ASA_RE) und dem Text.

# Alarmlogik und Lage-Ampel

## Warnquellen

- NINA/MoWaS (warnung.bund.de, Region Nuernberg/ERH; Anzeige per ninaCalm): aktive Warnungen mit Schweregrad (Minor bis Extreme), Entwarnungen (msgType Cancel oder Titel "Entwarnung") nur 2 h grau; abgelaufene Meldungen verschwinden.
- DWD-Warnungen (Kalchreuth, Forst, Erlangen, Kreis ERH, Schnaittach) und DWD-Waldbrandindex (Station Nuernberg).
- BR24 ueber DAB 11D und UKW 102,0 (Rundfunktexte, Warn-Score stark/mittel/Anweisung, Entwarnung, Test, Ausschluesse; Patch br24Warn2) sowie ASA DE ueber DAB 5C (Dienst-Label ASA; der Dienst allein ist kein Alarm).
- RDS-Notfall (PTY 31, Gruppe 9A EWS, Warnwoerter): nur bei echten Kennzeichen, PTY 30 nur Test.
- Weitere Lagequellen (ohne Bezug zu mesh_router.py; eigene Mesh-Meldungen siehe Kapitel 8): Netzfrequenz, Stromausfall, Pegel, Luft/Brand (FIRMS), ODL-Strahlung, Weltraumwetter, ADS-B-Notlagen (nur Anzeige).

## Status des Lagezentrums (sdr_manager.py, /api/sdr/live, /api/sdr/lage)

- SDR_OFFLINE: neueste Telemetrie aelter als WATCHDOG_S (15 s). Da prepper-sdr DAB nur im Wechsel misst und sdr_status.json nur bei Aenderung oder alle 60 s schreibt, gibt es keinen echten 15-s-Takt: jede Synchronisierung (hoechstens alle 10 s) schreibt eine Lebenszeichen-Zeile (kind 'hb'), aber NUR wenn sdr_status.json hoechstens 90 s alt ist und der prepper-sdr-Prozess lebt (Patch funkUI: Lebenszeichen auch im Speicher, damit eine DB-Sperre kein falsches SDR_OFFLINE erzeugt).
- ECHTALARM: aktive ASA-DE-Warnung (DAB 5C), deren Text nicht ausdruecklich Probe/Test sagt. PROBEALARM: nur wenn ASA- oder MoWaS/NINA-Text ausdruecklich Probe/Test/Warntag sagt. OK: sonst. Eigene TEST-Knopf-Meldungen ("TEST ... keine echte Warnung") zaehlen nie.
- Lage-Ampel (teil4) auf der Lage-Seite und /funk: gruen OK, gelb Probealarm, rot blinkend Echtalarm, orange blinkend SDR_OFFLINE; Vor-Alarm (DSL/Netzfrequenz) wird als Hinweis gezeigt. "LAGE: AUFFAELLIG" erscheint bei vorhandenen Warnungen.
- Vor-Alarm: Ausloesung ueber Netzfrequenz/DSL-Auffaelligkeit; seit sdrAir schaltet der Vor-Alarm nichts mehr um (keine Stick-Uebernahme mehr), er wird nur angezeigt.

## Regeln fuer Alarme (verbindlich, von Frank freigegeben)

- Probe-/Test-Alarme gehen NIE ans Mesh (Probealarm, Test/Uebung/Warntag im Text, eigene TEST-Meldungen, RDS PTY 30).
- Echte Alarme (ASA-Echtalarm, NINA, echter BR24-Notfall) werden automatisch an Mesh 1 gesendet, wenn der Schalter mesh_auto.json AN ist (Kill-Switch; fehlt oder kaputt = AUS). Der aktuelle Schaltzustand steht im Funk-Bereich "Auto-Versand Mesh 1 AN/AUS" und ist nicht in dieser Datei festgeschrieben.
- Eine Meldung je Alarm (Tabelle mesh_auto), gleicher Inhalt nicht innerhalb von 6 Stunden (Dedup), hoechstens 3 Auto-Meldungen je Stunde; jeder Versuch wird in mesh_log protokolliert (Hash, Kanal auto0, Quelle, Text, Ergebnis).
- Die einzige Sendestelle im Modul mesh_router.py ist _tx(); gesendet wird nur ueber die uebergebene Funktion send_fn (im Dashboard dieselbe send_meshtastic wie der Knopf "An Mesh 1 senden", Bridge 127.0.0.1:5001). Das Modul oeffnet keine eigene Verbindung.
- Nach dem Start des Dashboards gelten 5 Minuten Ruhe (Patch meshBootQuiet): in dieser Zeit keine Auto-Mesh-Sendungen.
- Tests, Simulationen, Patches und Rauchtests senden und loesen NICHTS aus (kein Mesh, kein Telegram, keine Alarme).
- Es gibt keine PIN-Sperre auf den Sende-Knoepfen (Entscheidung Frank); Schutz durch Bestaetigungsdialog, Sende-Schutz (funkHarden2), Cooldown 20 s und Dedup.
- Alarmweg Hobby/Stick 2: keiner mehr; die fruehere Stick-2-Uebernahme (Patch teil2) ist durch sdrAir entfallen.

# Mesh (Meshtastic) und Sendewege

## Sendestellen im Dashboard (einzige Orte, an denen etwas gesendet wird)

| Funktion | Ziel | Ausloeser |
|---|---|---|
| send_meshtastic(text, channel=0) | Mesh 1 (Bridge 127.0.0.1:5001, Knoten .141) | Knopf, Auto-Meldungen (Wetter, Luft, ODL, Pegel, Frequenz, Sonne, DWD, NINA), mesh_router._tx (Echtalarme) |
| send_meshtastic_to(text, host), send_chunks_bayern(chunks) | Mesh 2 (Bridge 127.0.0.1:5002, Knoten .140) | NINA automatisch, sonst nur manuelle Knoepfe |
| send_dab_to_private_mesh(text, channel=0) | nur Mesh 1 (.141) | DAB+/BR24/ASA-Meldungen; darf Mesh 2 (.140) nie ansprechen |
| mesh_ping_reply*.py | gleicher Knoten | Auto-Antwort auf "ping"/"test" |

- Knoepfe und Aufrufwege (Patch meshPost): Die Knoepfe Wetter, ODL, Pegel, Luft, Sonnenaktivitaet und NINA-Test senden per POST (fetch mit Herkunftspruefung: Header X-Mesh-Post: 1, Inhaltstyp JSON, gleiche Herkunft); ein GET auf dieselben Adressen liefert nur die Vorschau (NINA-Test: 405) und sendet nichts. Die Sende-Logik dahinter (Dublettenpruefung, hoechstens 3 pro Stunde bei echten Alarmen, Kanal 0, Sende-Schutz funkHarden2) ist unveraendert; Probe- und Testalarme gehen nie ins Mesh.
- Routing (Patch teil3, mesh_rules.json, Standardregeln): NINA ist fuer beide Knoten automatisch erlaubt (fuer Mesh 2 entscheidet zusaetzlich der Schalter nina_bayern_auto.json, nach Patch/Neustart Standard AUS, Zustand ueber /api/nina_bayern_auto pruefen); Wetter, Luft, FIRMS, ODL, Sonne, Pegel, Frequenz gehen automatisch nur an Mesh 1 und sind fuer Mesh 2 nur manuell erlaubt; "ping" (Auto-Antwort) beide. Ohne mesh_rules.json gelten diese Standardwerte; eine kaputte Datei faellt auf die Standardwerte zurueck. Cooldown zwischen Sendungen 20 s.
- Kanal: automatische Sendungen und Knoepfe nutzen Kanal 0 (LongFast) von Mesh 1. Bei Frank bedeutet "Mesh-Kanal 1" den Knoten Mesh 1; die Kanalnummer 0 ist der Funkkanal-Index. Falls sich das aendert, steht es in mesh_rules/send-Funktionen; genaue Funkkanal-Konfiguration der Knoten: nicht dokumentiert/zu pruefen.
- Alle Mesh-Sendungen laufen durch Sende-Schutz (funkHarden2), Dublettenpruefung (mesh_log, md5 je Kanal, 24 h; Patch lageDB/mesh_router Teil 1) und werden protokolliert.
- Boot-Ruhe: 5 Minuten nach Dashboard-Start keine Auto-Mesh-Sendungen (meshBootQuiet, Datei mesh_boot_quiet.json).
- NINA-Mesh (ninaCalm): jede Meldungs-ID hoechstens einmal (Warnung, Update, Entwarnung); Verschwinden/Ablaufen sendet nichts; eine wieder auftauchende ID wird nicht erneut gesendet; gesendete IDs stehen 7 Tage in nina_mesh_sent.json; Erststart ohne Datei: alles im Feed gilt als schon gesendet. NINA Bayern (mesh2_nina_seen.txt, nina_bayern_auto.json) ist der Mesh-2-Pfad.
- Auto-Meldungen mit eigener Logik: Wetter und Pegel alle 3 h (0/3/6/9/12/15/18/21 Uhr, Pegel 60 s spaeter), Netzfrequenz nach Stufen (Stufe 1 nur Entwarnung, Meldung ab hoeherer Stufe), Stromausfall, DWD und DWD-WBI bei Aenderung/Entwarnung, Luft/FIRMS bei Aenderung (Feinstaub gelb/rot, Brand neu/weg), ODL bei Ampelwechsel, Weltraumwetter. Status je Art in *_status.json (nina_mesh_status.json, dwd_mesh_status.json, mesh_weather_status.json, ...).
- Echtalarme (ASA/NINA/BR24-Notfall) zusaetzlich ueber mesh_router.py mit den Regeln aus Kapitel 7 (Dedup 6 h, max. 3/h, Kill-Switch).

## Bridges und Sessions

- Je Knoten eine Bridge (Dienste mesh-bridge und mesh-bridge-bayern): genau EINE TCP-Session zum Knoten, interne Queue, Pong auf Ping, Inbox (mesh_inbox*.json). Die Bridge schreibt Node-DB, lastHeard und ch_util selbst (funkHarden). Ein zweiter Client wuerde die Bridge aus der Session werfen.
- Das Dashboard prueft Sessions nur mit ss -tnp/systemctl show (mesh_session.py, Ergebnis 20 s gecacht) und oeffnet nie selbst eine Verbindung, solange eine Session besteht.
- Hang-Watchdog (mesh_hang_watchdog.py, Units mesh-hang-watchdog.service + .timer): erkennt "stuck" Telemetrie (gleicher Wert zu lange) und "stumme" Antworten (Ping empfangen, keine Antwort; Daten aus mesh_chutil.py und mesh_reply_watch.py) und schreibt mesh_hang_status.json. Aktion erst nach 45 min stuck (STUCK_ACTION_SEC); ein automatischer Neustart der betroffenen Bridge/des Dienstes passiert nur, wenn die Freigabe-Datei mesh_hang_autorestart (im Ordner secrets/) existiert; danach Cooldown 2 h (bei Zweitversuchen 25 min, bis zu 4 schnelle Wiederholungen je stuck-Episode). Ergebnis sichtbar im Banner der Funk-Seite und in mesh_hang_watchdog.log.
- Auto-Antworten (mesh-ping-reply, mesh-ping-reply-2): antworten auf ping/test im selben Kanal; Text wird in mesh_bridge.py on_receive gebaut ("von !nodeid", Stationsname "Station Kalchreuth").
- Mesh 2: MQTT am Knoten aus; ein optionales lokales Mosquitto fuer Mesh 2 ist moeglich, aber derzeit aus.

## Was nie passiert

- Keine automatische Sendung bei Probe/Test; keine Sendung durch Tests/Simulationen/Rauchtests/Patches; keine Sendung ueber SDR; keine PIN-Sperre (Entscheidung Frank); der Messenger Telegram kommt im Code nicht vor (das Wort steht nur in 'Telegramme' der 433-MHz-Anzeige).

# Datenfluesse (Quellen -> Verarbeitung -> Anzeige/Speicher)

| Quelle | Weg | Verarbeitung | Anzeige / Speicher |
|---|---|---|---|
| NINA/MoWaS (warnung.bund.de) | requests im Voll-Update (15 min) | ninaCalm (Ablauf, Entwarnung), lagegeo (Polygone) | Kachel NINA WARNUNGEN, /karte; events + geo_cache in lagezentrum.db; Mesh bei neuer ID |
| DWD Warnungen/WBI | Voll-Update | Filter auf Kalchreuth/Forst/Erlangen/ERH/Schnaittach | /umwelt; dwd_*status.json; Mesh bei Aenderung |
| Open-Meteo (Wetter, Wind) | Voll-Update | Vorhersage 5 Tage, Sonne | /umwelt, /luft; Mesh-Wetter alle 3 h |
| BfS ODL | Voll-Update | Ampel (0,25 / 0,60 µSv/h) | /umwelt; Mesh bei Ampelwechsel |
| NOAA SWPC | Voll-Update | Kp, G/R/S | /umwelt; Mesh manuell/Auto |
| energy-charts (Preis, Last, Mix) | Voll-Update | Reihen | /energie; strom_history.json, archive/ |
| EuroOilWatch (Brent), Tankerkoenig (Diesel), Metall-/Krypto-Quelle | Voll-Update | Hoch/Tief seit Aufzeichnung | /energie; oil_history.json, fuel_history.json, price_*.json |
| GIE AGSI/ALSI | Voll-Update (API-Schluessel in config.py) | Fuellstand | /speicher |
| GKD Bayern (Pegel) | Voll-Update | 3-h-Trend | /pegel; Mesh Pegel |
| Stoerungsauskunft/N-ERGIE | Voll-Update | Ausfaelle Mittelfranken | /lokale-energie; outage_history.json; Mesh |
| FIRMS, Sensor.community | luft.py | Naehe, Schwellen | /luft; firms_history.json; Mesh |
| RSS-Feeds | /api/news_refresh bzw. Update | Liste | /news |
| Netzfrequenz-Quelle | FREQ_INTERVAL | Stufen | Lage-Kachel; Mesh nach Stufen |
| Stratum-1 (NTP) | ntplib | Offset | Kopf der Lage-Seite |
| tar1090 (192.168.178.15) | HTTP JSON | Statistik, Squawk, Militaer | /adsb; adsb_history.json |
| gpsd (192.168.178.15:2947) | prepper_gps.py (nur lesen) | GPS/GLONASS-Bewertung | Kachel STOERSENDER/QRM, sdr_noise_hist |
| SDR-Geraete | prepper_sdr.py (Planer, Decoder) | Block-Ergebnisse, Watchdog | lagezentrum.db (state), JSON-Notkopie, archive/ |
| lagezentrum.db | Dashboard (sdr_manager) | Status SDR_OFFLINE/OK/PROBEALARM/ECHTALARM | Lage-Ampel, /funk, /rundfunk, /dabhist, /karte |
| Mesh-Knoten | Bridges | Inbox, Node-DB | /mesh, /mesh2, /funk |
| Systemzustand (systemctl, smartctl, df) | Dashboard (nur lesend, lokale Befehle) | Boot/SMART/Belegung | /pi |

- Voll-Update: ein Hintergrundfaden alle UPDATE_INTERVAL (15 min) ruft alle Internetquellen nacheinander ab (mit Timeout), schreibt data_store (Speicher) und die JSON-Zustandsdateien. Jede Kachel hat einen Zeitstempel "Aktualisiert/Abruf". Ausfall einer Quelle zeigt "–"/"Keine Quelle", der letzte gute Wert bleibt, wo sinnvoll, gekennzeichnet.
- Langzeitarchiv (archive_store.py): archive/JJJJ-MM/<reihe>.jsonl Rohpunkte 90 Tage, archive/daily/<reihe>.jsonl Tageswerte (dauerhaft), archive/events/<liste>.jsonl Ereignisse (dauerhaft, dedupliziert), archive/state.json (atomar). Kein Netz, keine Sendungen, schreibt nur unter archive/.
- DB primaer (sqlC): sdr_status und broadcast_state kommen aus lagezentrum.db, die JSON-Dateien sind im Normalbetrieb nur Notkopie (alle 10 min) bzw. Ersatz, wenn die DB fehlt/gesperrt ist; selbstheilend.
- Einfluss der Anzeige auf Sendungen: ausschliesslich ueber die Sendestellen aus Kapitel 8; die Anzeige selbst sendet nie.

# Datenbank und Zustandsdateien

## Datenbank lagezentrum.db (SQLite, WAL)

- Eine Verbindung je Aufruf (thread-sicher), WAL, busy_timeout; Schema-Migration idempotent (CREATE IF NOT EXISTS, fehlende Spalten per ALTER TABLE). Jede Funktion in database.py faengt Fehler ab. Aufraeum-Faden (sqlA, database.start_retention, einmal je Prozess, erster Lauf nach 30 s, dann alle 10 min): Ereignisse 7 Tage nach Ablauf, Empfangs-/Telemetriedaten nach den Fristen in database.py; dabSql-Daten nach 60 Tagen (nur bei plausibler Uhr).
- Backup: jede Auslieferung sichert zusaetzlich die DB per sqlite3 .backup (konsistent, auch im laufenden Betrieb).
- Tabellen und Spalten (automatisch aus dem Schema, nur lesend) und Zeilenzahlen:

@@AUTO db@@

@@AUTO dbcounts@@

- Rolle der Tabellen: events (Lageereignisse NINA/MoWaS, DAB, ASA, BR24; ext_id eindeutig, Upsert, is_test), mesh_log (md5 gesehener/gesendeter Mesh-Texte je Kanal, auch Auto-Versuche), mesh_auto (Echtalarm je akey), mesh_queue (Warteschlange), telemetry (DAB-Empfangswerte je Stick/Kanal; kind dab/hb), reception_log/masts/channel_status/tii_seen/tii_seen_meta (dabSql, TII), geo_cache (Warngebiete), asa_rx, state (Schluessel-Wert-Transport), meta.

## Zustandsdateien (JSON/JSONL im Projektordner, Auszug)

- sdr_status.json, broadcast_state.json, sdr_dabhist.json, sdr_events.json, sdr_kfz.json, sdr_techlog.json, sdr_wd.json, sdr_wd_gate.json, sdr_lage.json, sdr_takeover.json, sdr_airtest.json, sdr_autogain.json, sdr_noise_hist.json, noise_state.json, funk433_state.json, rtl433.jsonl, aprs*.json, broadcast_events.jsonl, teil4_state.json: SDR/Funk.
- nina_*.json/txt, dwd_*status.json, mesh_*.json, mesh_rules.json, mesh_auto.json (Kill-Switch), mesh_boot_quiet.json: Warn- und Mesh-Zustand.
- strom/oil/fuel/price/outage/adsb/firms *_history.json, ping_stats.json, speedtest.json: Verlaeufe.
- health_status.json, health_check.log, last_dashboard_restart.txt, sd_health.json (root-Timer), keep-last.json: Betrieb.
- Alle Zustandsdateien werden atomar geschrieben (tmp + fsync + os.replace; Patch funkHarden3). Sie sind Laufzeitdaten und gehoeren nicht ins Git-Repo (.gitignore).

# Patch-Auslieferung und Qualitaetssicherung

## Grundregeln

- Keine direkte Bearbeitung der Live-Dateien durch Entwickler. Jede Aenderung kommt als apply-Skript (apply-NAME.sh) mit einer Commit-Nummer (zum Beispiel "commit13"): bash /tmp/apply-NAME.sh commitN. Das Skript enthaelt die geaenderten Dateien eingebettet (oder per Patcher) und weiss, auf welchem Dateistand es aufsetzt.
- Der Standard jedes apply-Skripts (verbindlich):
  - Basispruefung: sha16 (erste 16 Hex-Zeichen von sha256) jeder Zieldatei muss dem erwarteten Stand entsprechen, sonst Abbruch VOR jeder Aenderung (0 Backups). Idempotente Neuanwendung (Zielstand schon da) wird erkannt ("UNVERAENDERT").
  - Trockenlauf (--dry-run): zeigt, was passieren wuerde, ohne zu schreiben.
  - Backups: Zeitstempel-Kopien der Zieldateien (*.bak-NAME-JJJJMMTT-HHMMSS), keepLast 3 je Name, plus SQLite-Backup von lagezentrum.db (sqlite3 .backup).
  - Atomares Schreiben (Datei.tmp, fsync, os.replace), Rechte der Datei bleiben erhalten.
  - AST-Wache: ein Programm vergleicht den Syntaxbaum des neuen Stands mit dem alten; neue Schichten duerfen nur erlaubte Konstrukte enthalten (keine subprocess/os.system/socket/Threads/Sendeaufrufe ohne Freigabe). Die Wache wird mit Mutationstests geprueft (absichtlich verbotener Code muss abgelehnt werden).
  - py_compile mit /usr/bin/python3 und dem venv-Python; Selbsttests der neuen Schicht.
  - Minimaler Neustart: nur prepper-dashboard; prepper-sdr und Pi werden nie von Patches neu gestartet (Ausnahme: ausdrueckliche Freigabe fuer einen konkreten Patch).
  - Rauchtest nach dem Neustart: 26 Pruefungen (12 Seiten + 14 APIs, alle HTTP 200) plus patchspezifische Pruefungen (zum Beispiel DOM-Reihenfolge auf /pi). Es wird dabei nichts gesendet/ausgeloest.
  - Rollback: bei jedem Fehler stellt das Skript Dateien (und Dienststand) aus den Backups wieder her und beendet mit Fehlercode.
  - Ausgabe: Wachen-Ergebnisse, sha16 und Zeilenzahlen aller geaenderten Dateien, Zeile "COMMIT commitN ...".
  - Manipulationstest (Tamper): ein veraenderter eingebetteter oder installierter Stand fuehrt zum Abbruch vor jeder Aenderung.
- Alte apply-Skripte bleiben unveraendert und wirken nur auf den damaligen Stand. Neue Patches duerfen alte Pruefungen nicht kaputt machen (siehe /pi: "Sicherung letzte Kachel").
- Simulation: vor der Lieferung laeuft jeder Patch in einer Sandbox (Kopie der Projektdateien, eigener Port, Stubs fuer systemctl/sudo/Netz, kein Zugriff auf echte Geraete, nichts wird gesendet), inklusive Rollback- und Tamper-Szenarien.

## Reihenfolge der Patches (Auszug, juengste zuletzt; Stand siehe Kapitel 16)

- Vorgaenger-Bloecke (2026): ninaCalm, uplinkDetect, funkHarden/2/3, pegelTrend, priceAllTime, longArchive, sdHealth, piPolish/2, speedTest/speedTile, sdrFunk ... sdrPlus ... (SDR-Familie), lageDB, lageGeo, teil2/3/4 (modularer Umbau, 17.10.), sysBoot/diskTiles2 (SSD/SD, 23.10.), sqlA/B/C, sdrAir/sdrAir2/sdrWd/dabSql (23./24.10.), airTest, sdrRest/sdrRest2, sdrHalt, sdrStick3, sdrFall, projDoc (diese Datei). Einzelne Patches sind unten in der Tabelle der Schichten erklaert; den echten Verlauf (Backups *.bak-NAME) liefert der automatische Abschnitt "Patch-Historie".

## Patch-Schichten (Marker "# ===== name: ... =====") und ihr Zweck

| Schicht | Zweck (kurz) |
|---|---|
| ninaCalm | NINA-Anzeige beruhigen, Mesh je Meldungs-ID einmal (nina_calm.py) |
| meshBootQuiet | 5 min nach Dashboard-Start keine Auto-Mesh-Sendungen |
| uplinkDetect | Telekom/Starlink erkennen (Lage-Kachel Internet, /pi, /api/uplink) |
| funkHarden2 | Sende-Schutz im Dashboard |
| funkHarden3 | Status-/Verlaufsdateien atomar schreiben |
| pegelTrend | 3-h-Trend je Pegel aus GKD-Rohwerten |
| priceAllTime | Hoechst/Tiefst seit Aufzeichnung fuer Diesel und Brent |
| longArchive | Langzeitarchiv (archive_store.py), nur lesen |
| firmsKeep | Waldbrand-Historie beim Start laden |
| sourceWatch | Quellen-Ueberwachung (ausgelagert nach tiles_sources.py) |
| sourcesManual | manuelles Voll-Update (Knopf auf /pi) |
| sdHealth | SD-Karten-Ampel aus sd_health.json |
| piPolish | einheitliche kompakte Karten auf /pi, Sicherung zuletzt |
| piPolish2 | Sicherung (#backupBox) als letzte Karte, nur 5 neueste Sicherungen |
| speedTest | Ookla-Speedtest je Uplink |
| speedTile | Speedtest-Box im Internet-Tile (Diagramm 14 Tage) |
| sdrFunk | SDR-Planer-Seiten /funk433 und /aprs, Lage-Kachel |
| sdrFunk2 | SDR-Kachel unten auf /funk, kompakt |
| sdAck | "Quittieren & neu pruefen" der SD-/Laufwerk-Karte |
| sdrPlus | Rundfunk-Warntexte (UKW-RDS, DAB+) + Meteor-M LRPT |
| sdrPreset | feste Empfangs-Presets (Whitelist, 30/60/120 min) |
| sdrAct | Aktivitaets-Zeile (nur Pegel/Belegung) |
| sdrStick | Kachel zeigt gebundenen Stick (Seriennummer) und Anzahl |
| sdrRds | Rundfunk-Zeile zaehlt UKW-Sender mit PI, letzter guter Stand mit Alter |
| sdrRf | Seite /rundfunk und /api/broadcast/events |
| sdrNoise | Kacheln Stoersender/QRM und Gewitter-Hinweis, Kalibrierung |
| sdrGps | Dach-GPS (gpsd) in der Kachel Stoersender/QRM |
| sdrNoise2 | robuste Schwellen (Median + MAD), Stundengrundlinie, Trend |
| umweltWide | /umwelt alle Kacheln volle Breite |
| gpsLearn | GPS/GLO getrennt: lernt/keine Daten/bewertet |
| evLog | Ereignis-Log QRM/Gewitter/GPS/Trend + KFZ-Sensoren |
| br24Warn2 | nur BR24-Texte (+ ASA DE), Warn-Score |
| lageMesh1 | Lage-Seite: BR24-Kachel unter NINA, Knopf "An Mesh 1 senden" |
| sdrQrmFix | SDR-Kachel im Raster, Handy ohne Ueberlauf, QRM-Messung |
| sdrUi | SDR-Kachel /funk neu (Status-Chips, Modus, Einzelempfang) |
| sdrLage | Quellen-Schalter AN/AUTO/AUS, Lage-Profile, Zeitanteile |
| sdrDual | zwei Sticks: Zeitanteile je Stick, Einzelbetrieb |
| stickTest | Kachel Antennentest, Stick-Zuordnungstest |
| stickTestFix | Antennentest als letzte Kachel im Raster |
| dabHist | BR24 (11D) und ASA DE (5C) als Zeilen in der SDR-Kachel; DAB-Verlauf |
| lageDB | Lagezentrum-Datenbank lagezentrum.db zusaetzlich zu JSON |
| sysBoot | Start ohne Warten (Server lauscht sofort), lzKick, Boot-Disk-Kacheln |
| lageGeo | echte NINA-Warngebiete (Polygone) |
| rdsNotfall | RDS-Notfall nur bei bestaetigter 9A-Notfallgruppe/PTY 31 |
| teil2 | Teil 2 von 4: (fruehere) Stick-2-Uebernahme 5C bei Echtalarm (durch sdrAir abgeloest) |
| teil3 | Meshtastic-Routing und Priorisierung (Mesh 2 nur NINA) |
| teil4 | Teil 4 von 4: Lage-Ampel mit Grund-Zeile, SDR-Status, Vor-Alarm |
| diskTiles2 | /pi "SSD · Master" und "SD · Fallback" (Boot-Ampel, SMART, Klon) |
| kartevec | /karte als eigene Seite, TII-Vektorlinien |
| sqlA | Aufraeum-Faden der Datenbank |
| sqlB | Dashboard liest sdr_status/broadcast_state zuerst aus der DB |
| sqlC | DB primaer, JSON nur Notkopie |
| funkUI | /funk Funk-Lage und Steuerung, /dabhist, /meteor-Galerie |
| sdrAir | Geraete-Register (Airspy 11D, Stick 1 5C, Stick 2 Hobby) |
| sdrAir2 | Anzeigenamen "Name · Rolle" auf allen Seiten |
| sdrWd | Daten-Watchdog je Stick (Anzeige/Dienst) |
| sdrWd2 | Watchdog-Kasten ruhig, je Zeile eine Zeile |
| dabSql | DAB/TII-Datenschicht in der DB, /api/dabsql/status |
| airTest | Gain-Test Airspy 11D (seit autoGain mit Profilen Gain-Test 1/2 und Auto) |
| autoGain | Gain-Automatik Airspy 11D (Messung, Score, Wechsel nur bei klarem Vorteil, Flip-Flop-Sperre, Rueckfall Stufe 16), Kachel auf /funk, /api/sdr/autogain, Kachelbreite auf /funk repariert (commit16) |
| sdrRest | Herkunft der Koordinaten, Uhr-Schutz |
| sdrRest2 | Kanal 10C "nicht geprueft", Uhr-Hinweise, Stick-Pruefung |
| sdrStick3 | Stick 3 als zweiter Hobby-Stick im Register |
| sdrFall | Rueckfall-10C-Meldung nur vom 5C-Planer |
| sdrHalt | Planer-Waechter (kontrollierter Dienst-Neustart bei Haengen) |
| sdrTeil2 | prepper-sdr Teil 2 (Stick 1 fest 11D; Stick 2 Hobby/Bereitschaft) |
| sdrTeil4 | prepper-sdr Teil 4 (Rueckfall 10C, jetzt vom Register gefuehrt) |
| sdrLog | Technik-Verlauf sdr_techlog.json |
| dabFix | DAB-Empfangsguete richtig lesen, bekannte Rundfunktraeger nicht als Stoerer |
| dabGain | DAB ueber rtl_tcp mit fester Verstaerkung |
| projDoc | Projektbeschreibung: Kachel #projDocBox ganz unten auf /pi, /api/docs/list, /api/docs/download, /api/docs/routes |
| meshPost | GET sendet nie ins Mesh: /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather, /api/mesh_test nur noch per POST von der eigenen Seite (Herkunftspruefung, Kopf X-Mesh-Post), GET = Vorschau bzw. 405; 6 Aufruferstellen im Dashboard-JavaScript umgestellt; /api/meshpost/status (commit14) |

- Dateien ausserhalb der Schichten-Marker (Module) haben eigene Kennzeichen /* name */ im Code, zum Beispiel chutilFunk, meshHangFunk, mesh2OneSession in funk_health.py/mesh_session.py, zuhausePage/zuhauseJinjaFix/zuhauseCacheFix/zuhausePolizeiPI/apoZuhause in zuhause.py.
- Der automatische Abschnitt "Marker" unten listet die tatsaechlich gefundenen Schichten je Datei mit Zeilennummer.

@@AUTO markers@@

@@AUTO history@@

# GitHub-Dateistruktur und Austausch zwischen Pi und GitHub

## Zwei Repos mit verschiedenen Aufgaben

| Repo | Sichtbarkeit | Zweck | Zugriff |
|---|---|---|---|
| Frankenland90/prepper-patches | oeffentlich (Roh-Link ohne Token: HTTP 200) | Auslieferung: apply-NAME.sh, patch-*.py, *.zb64, Hilfsmodule, mesh-hang-watchdog.service/.timer, README.md | Pi holt per curl, immer ueber einen festgenagelten Commit |
| Frankenland90/kaeswasser-lage-monitor | PRIVAT (Roh-Link ohne Token: HTTP 404) | Kopie/Arbeitsstand von /home/fmg/prepper-dashboard (Quellcode, Doku in docs/) | nur ueber das GitHub-Konnektor-Tool/der KI mit Frank-Freigabe; der Pi greift nie darauf zu |

- Wichtig: prepper-patches ist oeffentlich. Dort darf NIE ein Schluessel, Passwort, Token, config.py-Inhalt oder secrets/-Inhalt liegen. Alles, was fuer den Pi bestimmt ist, ist dort lesbar fuer jeden.
- Branches im privaten Repo: kaeswasser-lage-monitor (EINZIGER Arbeitsbranch; hier wird gearbeitet und gepusht), main (Ursprung), krisenfunk-erweiterung (aelterer Stand; Repo-Aufraeumen dort steht auf Eis, siehe Kapitel 16). Gepusht wird nur auf kaeswasser-lage-monitor. Kein Klon beim Betreiber, kein git auf dem Pi.
- Beobachtung am 24.10.2026 (nur Dateinamen gelesen, keine Inhalte): Das Wurzelverzeichnis des Branches kaeswasser-lage-monitor enthaelt neben dem Quellcode noch Laufzeitdateien (json/jsonl/log, *.bak-*-Sicherungen) und einen Ordner secrets/ sowie config.py. Das Aufraeumen (.gitignore, secrets/ und config.py mit API-Schluesseln entfernen) steht auf Eis. Folge: das Repo privat lassen, keine Dateien aus secrets/ oder config.py kopieren, anzeigen oder in oeffentliche Repos legen; vor einer Veroeffentlichung muss erst aufgeraeumt werden.

## Dateistruktur im Repo kaeswasser-lage-monitor (Branch kaeswasser-lage-monitor)

- Wurzel = Spiegel von /home/fmg/prepper-dashboard. Quellcode: dashboard.py, prepper_sdr.py, sdr_manager.py, database.py, mesh_router.py, lagegeo.py, mesh_rules.py, mesh_session.py, mesh_bridge.py, mesh_bridge_bayern.py, mesh_ping_reply*.py, mesh_chutil.py, mesh_hang_watchdog.py, mesh_reply_watch.py, mesh_node_label.py, nina_calm.py, luft.py, zuhause.py, funk_health.py, funk_page.py, health_check.py, watchdog.py, speedtest_run.py, uplink_detect.py, tiles_sources.py, archive_store.py, prepper_gps.py, prepper_evlog.py, prepper_sdr_net.py, prepper_docs.py (neu), smoke.sh, .gitignore.
- Unterordner: tools/ (backup.sh, restore.sh, prepper-clone-ssd-to-sd, ookla/), systemd/sysboot/ (Dateien des Patches sysBoot; Inhalt nicht naeher dokumentiert), static/ (Leaflet u. a.), sdr_lib/, docs/ (diese Projektbeschreibung, Dateien "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt/.md").
- Nicht ins Repo gehoeren (soll per .gitignore ausgeschlossen sein): config.py (Schluessel), secrets/, lagezentrum.db, Laufzeit-JSONs, Logs, archive/, backups/, __pycache__/, *.bak-*.
- Die Zuordnung Funktion -> Datei -> Marker (mit aktuellem sha16 und Zeilenzahl jeder Datei) steht in der folgenden Tabelle; sie wird beim Erzeugen aus den Live-Dateien befuellt.

| Funktion / Feature | Datei(en) | Marker / Kennzeichen | Stand (sha16 · Zeilen) |
|---|---|---|---|
| Lage-Seite, Lage-Ampel, Vor-Alarm | dashboard.py, sdr_manager.py | teil4, lageMesh1, funkUI | @@FI dashboard.py;sdr_manager.py@@ |
| NINA ruhig/Mesh je ID | nina_calm.py, dashboard.py | ninaCalm | @@FI nina_calm.py@@ |
| NINA-Warngebiete (Polygone) | lagegeo.py, dashboard.py | lageGeo | @@FI lagegeo.py@@ |
| Mesh-Routing/Regeln | mesh_rules.py, dashboard.py | teil3 (mesh_rules.json) | @@FI mesh_rules.py@@ |
| Auto-Echtalarm an Mesh 1 | mesh_router.py | (Modul; Schalter mesh_auto.json) | @@FI mesh_router.py@@ |
| Mesh-Bridges und Sessions | mesh_bridge.py, mesh_bridge_bayern.py, mesh_session.py | funkHarden, mesh2OneSession | @@FI mesh_bridge.py;mesh_bridge_bayern.py;mesh_session.py@@ |
| Mesh-Hang-Watchdog | mesh_hang_watchdog.py, mesh_chutil.py, mesh_reply_watch.py | meshHang | @@FI mesh_hang_watchdog.py;mesh_chutil.py;mesh_reply_watch.py@@ |
| Sende-Schutz, atomare Dateien | dashboard.py | funkHarden2, funkHarden3 | @@FI dashboard.py@@ |
| Datenbank | database.py, sdr_manager.py, dashboard.py, prepper_sdr.py | lageDB, sqlA, sqlB, sqlC, dabSql | @@FI database.py;sdr_manager.py@@ |
| SDR-Dienst (Planer, Register, DAB, RDS) | prepper_sdr.py | sdrLage, sdrDual, sdrAir, sdrAir2, sdrTeil2, sdrTeil4, dabGain, dabFix, rdsNotfall | @@FI prepper_sdr.py@@ |
| Daten-Watchdog, Planer-Waechter | prepper_sdr.py, dashboard.py | sdrWd, sdrWd2, sdrHalt, sdrRest, sdrRest2 | @@FI prepper_sdr.py@@ |
| Gain-Test, Gain-Automatik, Antennentest | prepper_sdr.py, dashboard.py, sdr_manager.py | airTest, autoGain, stickTest, stickTestFix | @@FI prepper_sdr.py;sdr_manager.py@@ |
| Funk-Seite und Unterseiten | dashboard.py, funk_page.py, funk_health.py | funkUI, sdrUi, sdrFunk, sdrRf, dabHist, sdrPlus | @@FI funk_page.py;funk_health.py@@ |
| BR24/ASA-Warnlogik | dashboard.py, prepper_sdr.py | br24Warn2, rdsNotfall | @@FI dashboard.py@@ |
| QRM, Gewitter, Dach-GPS, Ereignisse | prepper_gps.py, prepper_evlog.py, dashboard.py | sdrNoise, sdrNoise2, sdrGps, gpsLearn, evLog | @@FI prepper_gps.py;prepper_evlog.py@@ |
| Karte | dashboard.py | kartevec | @@FI dashboard.py@@ |
| /pi: SSD/SD, Sicherung, Archiv | dashboard.py, tools/backup.sh, archive_store.py | diskTiles2, sysBoot, sdHealth, sdAck, piPolish, piPolish2, longArchive | @@FI archive_store.py;tools/backup.sh@@ |
| Speedtest, Uplink | speedtest_run.py, uplink_detect.py, dashboard.py | speedTest, speedTile, uplinkDetect | @@FI speedtest_run.py;uplink_detect.py@@ |
| Luft, Zuhause | luft.py, zuhause.py | zuhausePage, apoZuhause | @@FI luft.py;zuhause.py@@ |
| Health, Watchdog | health_check.py, watchdog.py | health3h | @@FI health_check.py;watchdog.py@@ |
| Projektbeschreibung (diese Datei) | prepper_docs.py, dashboard.py | projDoc, meshPost | @@FI prepper_docs.py;dashboard.py@@ |

## Weg 1: GitHub -> Pi (Patch holen und anwenden)

Der Pi holt Patches nur aus dem oeffentlichen Repo prepper-patches und nur ueber einen festgenagelten Commit (40 Hex-Zeichen), damit der Inhalt nicht nachtraeglich veraendert werden kann. Frank bekommt drei einzelne Textzeilen (je eine Chat-Nachricht, reiner Text ohne Nummerierung oder Etiketten, sonst meldet bash "Kommando nicht gefunden"):

```
curl -o /tmp/apply-NAME.sh https://raw.githubusercontent.com/Frankenland90/prepper-patches/<COMMIT-SHA-40>/apply-NAME.sh
echo <SHA256-64>  /tmp/apply-NAME.sh | sha256sum -c
bash /tmp/apply-NAME.sh commitN
```

- Zwischen dem sha256 und dem Dateinamen stehen zwei Leerzeichen. Die zweite Zeile muss "OK" ausgeben; sonst nicht ausfuehren. Das Argument commitN (zum Beispiel commit13) wird nur in die Ausgabe/das Protokoll uebernommen. Den Trockenlauf macht das Skript selbst: es patcht zuerst Kopien, prueft sie (AST-Wache, py_compile mit beiden Pythons, Selbsttests, Idempotenz) und schreibt erst danach die Live-Dateien.
- Das Skript prueft sha16 aller Zieldateien, legt Backups an, patcht, kompiliert, startet nur das Dashboard neu, fuehrt den Rauchtest aus und rollt bei Fehlern zurueck. Am Ende steht eine Zeile "COMMIT commitN ..." mit den neuen sha16/Zeilenzahlen.
- Die Kette ist bewusst ohne git-Klon: Lesen = curl, Pruefen = sha256sum, Ausfuehren = bash. Roh-Links des PRIVATEN Repos liefern ohne Token 404 und gehen deshalb nicht.
- Kleine Textdateien (zum Beispiel eine Unit-Datei) koennen alternativ per Copy & Paste eingefuegt werden (cat > datei << 'EOF' ... EOF) und danach mit sha256sum -c gegen den genannten Wert geprueft werden.

## Weg 2: Pi -> GitHub (Stand sichern)

- Der Pi pusht nie selbst (kein git, kein Token). Nach einer erfolgreichen Anwendung uebertraegt die KI mit Frank-Freigabe dieselben Dateien, die das Skript eingebettet hatte (sha-geprueft), als Commit auf den Branch kaeswasser-lage-monitor des privaten Repos. Die Commit-Nachricht nennt Patch, Commit des Patch-Repos und die Ziel-sha16, zum Beispiel "sdrFall (prepper-patches 461ab753): ...". So bleibt Repo = Pi nachweisbar.
- Abgleich Pi gegen Repo ohne Klon: auf dem Pi sha16 bilden und mit der Angabe im Commit/Patch-Ausgabe vergleichen:

```
cd /home/fmg/prepper-dashboard
sha256sum dashboard.py prepper_sdr.py sdr_manager.py database.py mesh_router.py lagegeo.py | cut -c1-16
wc -l dashboard.py prepper_sdr.py sdr_manager.py
```

- Dateien, die nur auf dem Pi existieren (zum Beispiel die Projektbeschreibung, die auf dem Pi erzeugt wird), kommen per Copy & Paste in den Chat (cat docs/DATEI | ... bzw. Download ueber die Kachel auf /pi) oder werden von der KI aus dem Patch-Stand rekonstruiert. Grosse Dateien (dashboard.py > 1 MB) werden nie gepastet, sondern ueber den Patch-Weg synchron gehalten.
- Die Projektbeschreibung selbst: Pi erzeugt sie (python3 prepper_docs.py -> /home/fmg/prepper-dashboard/docs/); das Repo-Exemplar im Ordner docs/ des Branches wird bei jeder Auslieferung mitgepusht und stammt aus dem Repo-Stand (Auto-Abschnitte koennen sich vom Pi-Exemplar unterscheiden, massgeblich fuer den Pi ist das Pi-Exemplar).

## Weg 3: Dokumentation neu erzeugen und verteilen

- Auf dem Pi: cd /home/fmg/prepper-dashboard && python3 prepper_docs.py (neue Version, nur wenn sich Text oder Live-Stand geaendert haben; --force erzwingt eine neue Version; --check prueft nur; --keep N behaelt N Versionen, Standard 10).
- Danach zeigt die Kachel auf /pi die neueste Version; der Download-Knopf liefert "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt". Markdown-Version daneben.
- Fuer die Weitergabe an eine andere KI: TXT herunterladen (oder auf dem Pi mit cat anzeigen und kopieren) und der KI geben; sie braucht dann keine Rueckfragen.

# Entscheidungen und bekannte Einschraenkungen

## Entscheidungen (von Frank getroffen oder bestaetigt)

| Entscheidung | Inhalt |
|---|---|
| Keine PIN auf Sende-Knoepfen | Mesh-Knoepfe sind nicht PIN-geschuetzt; Schutz durch Bestaetigung, Sende-Schutz, Cooldown, Dedup |
| Kein Git-Klon | Dateien per curl -o /tmp/... holen, sha256 pruefen, bash ausfuehren; Repo privat, Pi greift nicht darauf zu |
| Einziger Arbeitsbranch | kaeswasser-lage-monitor im privaten Repo Frankenland90/kaeswasser-lage-monitor |
| Auslieferung ueber prepper-patches | oeffentliches Repo, festgenagelter Commit, drei Einzeiler fuer Frank |
| Rollen der SDR-Geraete fest (23.10.2026) | Airspy R2 = 11D, Stick 1 = 5C (Rueckfall 10C), Stick 2 = Hobby (nur Beobachtung); Stick-2-Uebernahme entfallen; Spyverter draussen; kein Splitter |
| Auto-Mesh nur fuer echte Alarme an Mesh 1 | 6 h Dedup, max. 3/h, Kill-Switch mesh_auto.json; Probe/Test nie |
| Mesh 2 nur NINA automatisch | NINA-Auto-Weg fuer Mesh 2 nur bei Schalter nina_bayern_auto.json = AN (Standard AUS); DAB+ darf .140 nie ansprechen; Mesh 2 hat MQTT aus; optional lokales Mosquitto fuer Mesh 2 (aus) |
| DB primaer, JSON als Notkopie | lagezentrum.db haelt sdr_status/broadcast_state; JSON nur Ersatz alle 10 min |
| SSD Master / SD Fallback | SD-Klon nur auf Knopfdruck, kein automatischer Klon |
| Persistentes Journal 200 MB | seit 23.10.2026 |
| Watchdog-Stufen | Pi-Neustart nur durch den Daten-Watchdog (60 min ohne Empfang, max 1/h, Stopp nach 3); Patches loesen nie einen Neustart aus |
| sdrHalt | einziger kontrollierter Selbstneustart von prepper-sdr (Planer haengt >= 10 min, nie in Sperren, max 3/h) |
| Anzeige-Namen | alle Seiten benutzen "Name · Rolle" aus dem Geraete-Register ("Airspy R2 · 11D", "Stick 1 · 5C", "Stick 2 · Hobby", "Stick 3 · Hobby") statt Platznummern |
| Projektbeschreibung | Kachel ganz unten auf /pi unter der Sicherung; Version = Zeitstempel (Berlin); Download nur aus docs/ |

## Technische Entwurfsentscheidungen

- Monolith statt Microservices: ein Prozess ist auf dem Pi robuster zu betreiben; Aufteilung nur dort, wo ein Dienst Hardware besitzt (prepper-sdr) oder eine Verbindung exklusiv halten muss (Mesh-Bridges).
- Schichtweises Patchen mit Markern statt Refactoring: jede Auslieferung ist klein, pruefbar und rueckrollbar; der Preis ist eine sehr grosse Datei.
- Strings statt Vorlagendateien: Seiten sind Python-Strings; deshalb gibt es keine getrennte Frontend-Pipeline. Wiedererkennung ueber Kommentar-Marker /* name */.
- HTML-Injektion per after_request: erlaubt Erweiterung ohne Eingriff in alte Seitenstrings; Reihenfolge beachten (Flask fuehrt die Hooks umgekehrt aus).
- Ehrliche Anzeige statt schoener Zahlen: fehlende Werte "–", Ersatzwerte benannt, Alter der Daten sichtbar, "lernt" statt falscher Ampel.
- Probe-/Test-Erkennung konservativ: lieber ein echter Alarm wird nicht automatisch weitergegeben (manuell per Knopf immer moeglich) als ein Probealarm ans Mesh.
- Ein Stick gehoert einem Planer: keine zwei Programme gleichzeitig auf einem Stick; Planer sperren sich zeitlich.
- Alle Zustandsdateien atomar; Datenbank im WAL-Modus; jede Funktion mit try/except.

## Bekannte Einschraenkungen

- welle-cli liefert keine Bitfehlerrate, keinen Alarmflag (FIG 0/0), keine Ansagen (FIG 0/19) und kein ASA-Datenfeld: Warnerkennung nutzt DLS-Text und das Dienst-Label "ASA" im Ensemble 5C; BER wird durch die FIC-Fehlerrate ersetzt.
- Der Rundfunk-Block misst DAB nur im Wechsel; daher gibt es keinen echten 15-s-Takt der Telemetrie (Lebenszeichen 'hb', Watchdog 15 s).
- ASA-Dienst: wenn der Dienst laenger als 55 s nicht empfangen wird, zeigt die Funk-Seite ASA_INTERRUPTED (Soll 37 s).
- Hobby-Stick: nur Beobachtung; ohne Sync auf 10C wird "nicht geprueft" statt "offline" gezeigt.
- Dach-GPS haengt am Stratum-1-Server; faellt der gpsd aus, zeigt die Zeile "nicht erreichbar" (grau) und die QRM-Bewertung der GPS-Zeilen lernt neu.
- Grundlinien (QRM, GPS) brauchen mehrere Tage Lernzeit ("lernt"); in dieser Zeit keine Alarmfarbe.
- Netzfrequenzquelle, Strompreise, Krypto etc. sind Internetdienste Dritter; Ausfall = "Keine Quelle".
- Kein Login, keine Verschluesselung (HTTP im LAN). Nicht aus dem Internet erreichbar machen.
- Die Kachel-Reihenfolge auf /pi haengt an JavaScript/Hooks; Aenderungen an der Seite muessen die Checks "Sicherung letzte Kachel" und "/pi: Sicherung unveraendert (11x)" der bisherigen Patches beachten (die neue Projektbeschreibung nutzt deshalb die Klasse pd-card statt card).
- /karte und /medizin brauchen JavaScript bzw. den Dienst kiwix; ohne diese erscheinen leere Seiten.
- Uhr: ohne NTP-Sync pausieren Aufraeum- und Offline-Rechnung der DAB-Datenbank (Uhr-Schutz).
- Mesh: Funkreichweite/Knotenanzahl sind nicht garantiert; "gesendet" heisst "an den Knoten uebergeben", nicht "bei jemandem angekommen".

# Nicht-Ziele

- Kein Senden ueber SDR (Funk). Kein Mesh-Versand aus Tests/Simulationen/Smoke.
- Keine Pager-/BOS-/Behoerdenfunk-Dekodierung (rechtlich ausgeschlossen); nur Rundfunk, Wettersatellit, ISM, APRS.
- Kein offizielles Warnsystem, keine Garantie, kein Ersatz fuer Sirenen/Warn-Apps.
- Kein Zugriff aus dem Internet, keine Nutzerverwaltung, keine Cloud, keine Telemetrie an Dritte.
- Kein automatischer SD-Klon, kein automatischer Pi-Neustart durch Patches.
- Kein MQTT-Betrieb (hoechstens optionales lokales Mosquitto fuer Mesh 2, derzeit aus).
- Keine PIN auf den Sende-Knoepfen (Frank hat sich dagegen entschieden).
- Kein Git auf dem Pi, kein Klon.
- Kein Veroeffentlichen von Schluesseln, Konfiguration oder Betreiberdaten.

# Betrieb und Diagnose (nur lesend)

## Haeufige Prueffragen (ohne Aenderungen am System)

```
systemctl is-active prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern kiwix chrony
journalctl -u prepper-dashboard -n 80 --no-pager
journalctl -u prepper-sdr -n 80 --no-pager
curl -s http://127.0.0.1:5000/api/sdr/live
curl -s http://127.0.0.1:5000/api/sdr/wd
curl -s http://127.0.0.1:5000/api/docs/list
ls -l /home/fmg/prepper-dashboard/docs
cd /home/fmg/prepper-dashboard && python3 prepper_docs.py --check
```

- Der Port steht in config.py (PORT; Standard 5000). Werte aus config.py nie ausgeben.
- Der Neustart des Dashboards (sudo systemctl restart prepper-dashboard) braucht das sudo-Passwort des Betreibers; dieses wird nie im Chat genannt. Normalerweise macht das der Patch selbst.
- Dashboard-Antwort "laedt": nach einem Neustart dauert das erste Voll-Update etwa 1-2 Minuten; die Seiten sind sofort erreichbar.
- Rauchtest (smoke.sh im Projektordner) ruft die Seiten/APIs ab, sendet nichts.

## Fehlersuche (Faustregeln)

- Lage-Ampel orange blinkend = SDR_OFFLINE: prepper-sdr laeuft nicht oder schreibt nicht (Funk-Seite "Datenquelle"/Daten-Watchdog ansehen, journalctl -u prepper-sdr).
- "ASA_INTERRUPTED": 5C-Dienst nicht empfangen; Antenne/Empfang des Sticks 1 pruefen, Rueckfall 10C beobachten.
- 11D ohne Empfang: Airspy/Antenne/Gain; Kachel "Gain-Automatik" auf /funk ansehen (aktueller Gain, Grund des letzten Wechsels, Sperre); bei Sperre erst die Ursache klaeren, dann Auto wieder einschalten; Gain-Test-Kachel zeigt die Messwerte je Stufe.
- Mesh "Dienst aus"/"TCP zu": Bridge-Dienst und Knoten-Erreichbarkeit pruefen; Hang-Watchdog-Banner auf /funk.
- Kachel zeigt "–": Quelle ausgefallen (Datenquellen-Kachel auf /pi zeigt die Fehlerzaehler) oder noch nicht abgerufen.
- Uhr falsch: chrony und Stratum-1 pruefen; DAB-Datenbank pausiert dann das Aufraeumen.
- Nach jeder Aenderung: Rauchtest und /pi ansehen (Reihenfolge der Kacheln).

## Wiederherstellung

- Jeder Patch legt Backups an (*.bak-NAME-JJJJMMTT-HHMMSS, keepLast 3) plus ein SQLite-Backup. Die Sicherung auf /pi (tools/backup.sh) sichert Projektdateien/DB; Wiederherstellung ueber die Kachel "Sicherung" (doPrepperRestore) oder per Hand aus den Backups.
- Bei Boot-Problemen: SD-Fallback (geklont auf Knopfdruck) nutzen; Boot-Reihenfolge im Kachel "SSD · Master" ansehen.

# Aktueller Stand und offene Punkte

## Stand der Entwicklung (Auszug, Berlin-Zeit der Branch-Commits)

- Die juengste Patch-Familie rund um SDR (23./24.10.2026): sdrAir (Geraete-Register, feste Rollen), sdrAir2 (Anzeigenamen, Hobby nur Beobachtung; Branch-Commit 02:00), dabSql (Datenbankschicht fuer DAB/TII; 08:30), airTest (Gain-Test; 09:35), sdrHalt (Planer-Waechter; 10:10), sdrRest (Koordinaten-Herkunft, Uhr-Schutz; 12:06), sdrRest2 (USB-Stand nur lesend, 10C "nicht geprueft"; 13:21), sdrStick3 (Stick 3 im Register; 15:00), sdrFall (Rueckfall-10C-Meldung nur vom 5C-Planer; 17:21 am 24.10.2026), autoGain (Gain-Automatik und Kachelbreite auf /funk; commit16).
- Basisstand dieser Beschreibung = Stand nach sdrFall, projDoc, meshPost und autoGain. Die genauen sha16 und Zeilenzahlen aller Dateien stehen im Abschnitt "Dateien im Projektordner" (Kapitel 4) und in der Tabelle in Kapitel 12.
- Danach kam der Patch projDoc (Kachel + Generator prepper_docs.py + Ordner docs/; commit13) und als juengster Schritt der Patch meshPost (commit14): GET auf die Sende-Wege Wetter/ODL/Pegel/Luft/Sonnenaktivitaet/NINA-Test sendet nie mehr; Senden nur per POST von der eigenen Seite. Beide aendern nur dashboard.py (meshPost zusaetzlich prepper_docs.py und die docs-Version).
- Parallel in Arbeit: sdrStick3c (Stick 3 bekommt die eindeutige Seriennummer 26102403 per rtl_eeprom; danach einmal neu einstecken). Dieser Patch aendert keine Programmdateien dieses Standes; projDoc ist davon unabhaengig.

## Funktioniert (Stand der Erzeugung)

- Alle 26 Rauchtest-Pruefungen (12 Seiten + 14 APIs) im Standardlauf; /pi mit Sicherung als letzter Standard-Kachel, darunter die Projektbeschreibung.
- Warnlage (NINA, DWD, BR24/ASA), Lage-Ampel, Funk-Seite mit Geraete-Register, Daten-Watchdog, Mesh-Anzeige, Energie-/Pegel-/Luft-/ADS-B-Seiten, Zuhause, News.
- Mesh-Auto-Meldungen nach den Regeln aus Kapitel 7/8; der Zustand des Echtalarm-Schalters steht live auf /funk.

## Offene Punkte (priorisiert nach Dringlichkeit, nicht nach Reihenfolge der Umsetzung)

- sdrStick3c: Seriennummer fuer Stick 3 (26102403) per rtl_eeprom schreiben und Stick umstecken (geplant, in Arbeit).
- Gain-Automatik (autoGain): bis zum Einspielen blieb der Gain fest auf Stufe 16; danach waehlt die Automatik nur nach eigenen Messungen. Die Messwerte der Gain-Tests (12: Sync 100 %, SNR 9,0, FIC 1,96 %; 19: Sync 60 %, FIC 54 %; 21: kein Sync; Stufe 16 im Betrieb: 99 %, 13,9 dB, FIC 5,07 %) sind erste Anhaltspunkte; Gain-Test 2 (14/16/17/18 plus Auto) und mehrere Tagesmessungen stehen aus. Beobachten: Verlauf und Sperre in der Kachel "Gain-Automatik".
- chronyc-Ausgaben (tracking/sources) des Stratum-1-Servers und des Pi: nicht dokumentiert/zu pruefen (Ausgaben stehen aus).
- 11D laeuft dauerhaft ueber welle-cli (Airspy, Port 7979): Langzeitverhalten (CPU-Last, Stabilitaet ueber Tage) beobachten; dazu gibt es noch keine dokumentierte Auswertung.
- Echtzeituhr (zum Beispiel DS3231), TFT-Display ohne WLAN, USB-Portzuordnung, Antennen der Sticks: nicht dokumentiert/zu pruefen.
- Zustand des Schalters mesh_auto.json (Auto-Versand echter Alarme an Mesh 1) pruefen: Funk-Seite "Auto-Versand Mesh 1".
- Repo-Aufraeumen: .gitignore-Bereinigung sowie Entfernung von secrets/ und config.py (API-Schluessel) auf dem Branch krisenfunk-erweiterung steht AUF EIS (nichts anfassen, bis Frank es freigibt). Bis dahin: Repo privat lassen und keine Schluesseldateien kopieren/ausgeben.
- Ochsenkopf-Feinabstimmung (Empfang der dortigen Sender stabilisieren): steht AUF EIS (nichts anfassen, bis Frank es freigibt).
- Optional: lokales Mosquitto fuer Mesh 2 (derzeit aus; MQTT am Knoten ebenfalls aus).
- Dokumentationspflege: die Projektbeschreibung wird bei jeder Auslieferung neu erzeugt (python3 prepper_docs.py); der redaktionelle Text (Kern im Skript) muss bei neuen Kacheln/Diensten ergaenzt werden, sonst erscheinen sie im Nachtrag am Ende.

## Wie sich dieses Dokument aktuell haelt

- prepper_docs.py liest beim Lauf die echten Dateien (Routen vom laufenden Dashboard, Dateien mit sha16/Zeilen, Marker, Units, Datenbank) und gleicht sie mit dem redaktionellen Text ab. Was im Code oder System vorhanden, aber im Text nicht beschrieben ist, wird automatisch im Kapitel "Nachtrag" angehaengt (und im Pruefbericht unten gezaehlt). Ein leerer Nachtrag heisst: alles Gefundene ist redaktionell beschrieben.
- Der redaktionelle Kern liegt im Skript prepper_docs.py (Variable CORE). Aenderungen am Text = Aenderung am Skript = neue Auslieferung.

# Regeln fuer KIs und Entwickler, die hier weiterarbeiten

## Checkliste fuer jede Aenderung

- 1. Lies Kapitel 1, 4, 5 und 11. Pruefe, ob die Aenderung bestehende Logik beruehrt; falls ja, kleinste moegliche Aenderung mit eindeutigem Anker.
- 2. Neue Funktion = neue Schicht "# ===== name: Beschreibung =====" vor if __name__ == "__main__":. Alles in try/except. Keine Netzwerk-/Sende-/Prozess-Aufrufe ohne ausdrueckliche Freigabe.
- 3. Neue Kachel: eigene id (zum Beispiel fooBox), Titel im Stil der anderen, Aktualisierung per fetch auf einen GET-Endpunkt; Handy-Layout pruefen; Eintrag in diese Beschreibung (Kern) ergaenzen.
- 4. Auf /pi: die Kachel "Sicherung" muss unveraendert bleiben (Reihenfolge, doPrepperRestore-Zaehler, #backupBox); nach ihr steht nur die Projektbeschreibung. Neue Kacheln gehoeren VOR die Sicherung.
- 5. after_request-Hooks laufen in umgekehrter Reihenfolge: neue Hooks an die richtige Listenposition setzen.
- 6. Baue das apply-Skript nach dem Standard (Kapitel 11): sha16-Basis, Trockenlauf, Idempotenz, keepLast 3, atomar, AST-Wache (mutationsgetestet), py_compile mit beiden Pythons, Selbsttests, Neustart nur Dashboard, Rauchtest 26 + eigene Pruefungen, Rollback, Tamper-Test.
- 7. Teste in einer Sandbox mit Stubs (systemctl/sudo/Netz), eigenem Port und OHNE Prozesse anderer Arbeitsstroeme zu beenden (kein pkill -f auf fremde Namen). Keine Sendungen, keine echten Geraete.
- 8. Lies keine Secrets (config.py-Werte, secrets/, Schluessel, Passwoerter, Tokens, sudo-Passwort) und schreibe keine in Dateien, Chat oder Patches (prepper-patches ist oeffentlich!).
- 9. Liefere an Frank nur reine Textzeilen (curl -o /tmp/..., echo SHA  datei | sha256sum -c, bash ...), je Zeile eine Nachricht, ohne Nummerierung.
- 10. Pushe auf das private Repo nur auf den Branch kaeswasser-lage-monitor und nur mit Freigabe; Commit-Nachricht mit Patch-Name, prepper-patches-Commit und sha16.

## Stolpersteine (aus der Praxis)

- Sende-Endpunkte (seit Patch meshPost nur per POST): /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather und /api/mesh_test senden nur noch per POST von der eigenen Seite (Origin/Referer, Kopf X-Mesh-Post: 1, JSON). Ein GET darauf sendet nie (Vorschau bzw. 405). Vor meshPost (Stand projDoc und davor) sendeten die fuenf Knopf-Wege beim blossen GET-Aufruf (force=True); wer eine aeltere Version dieser Beschreibung oder einen alten Link/Lesezeichen/Skript kennt, die diese URLs per GET holen: das sendet nicht mehr und liefert nur noch die Vorschau. Nie per POST in Tests, Rauchtests, Crawlern oder Monitoring aufrufen; auch /api/mesh_send, /api/mesh2_send und /api/lage_mesh1/send senden. Neue Sende-Knoepfe immer als POST mit Herkunftspruefung bauen, nie als GET.
- Flask fuehrt after_request-Funktionen in umgekehrter Reihenfolge aus.
- piPolish2 haelt #backupBox per Seiten-JavaScript als letzte ".card"; Elemente nach der Sicherung duerfen nicht class="card" haben, sonst verschiebt das Skript die Sicherung.
- Mesh-Sessions: nie selbst eine zweite TCP-Verbindung zu einem Knoten oeffnen.
- Sticks: nie zwei Programme auf einen Stick; Stick 3 wird von prepper-sdr nie geoeffnet.
- Gain des Airspy 11D: nur die Gain-Automatik (autoGain, nur ohne Alarm/ASA/PTY 31/Antennentest/Meteor) und die Gain-Leiter bei Sync-Verlust duerfen ihn aendern; Tests (airTest) nie. Bei einer Sperre der Automatik (Kachel "Gain-Automatik") erst die Ursache klaeren, dann Auto auf /funk wieder einschalten.
- Probealarm-Texte nie als echte Alarme behandeln; im Zweifel nicht automatisch senden.
- Simulationen: Dashboard-Sims warten auf das erste Voll-Update (bis ca. 2 Minuten); /medizin laedt in der Sim nicht (kiwix).
- Alte apply-Skripte nie aendern; ihre Pruefungen gelten dem damaligen Stand.
- Dateinamen mit Umlauten/Leerzeichen (Projektbeschreibung ...) immer in Anfuehrungszeichen bzw. ueber die API/Kachel ausliefern.

## Frank-Format fuer Befehle

- Reiner Text, keine Markdown-Codebloecke im Chat, eine Zeile je Nachricht, keine Nummern/Labels. Reihenfolge: curl -o, sha256sum -c, bash.

# Anhang

## Glossar

| Begriff | Bedeutung |
|---|---|
| NINA / MoWaS | Warn-App/Warnsystem des Bundes (Modulares Warnsystem) |
| DWD / WBI | Deutscher Wetterdienst / Waldbrandgefahrenindex |
| BR24 | Nachrichten-/Informationsprogramm des BR, hier ueber DAB 11D und UKW 102,0 |
| ASA DE | Automatic Safety Alert, Warndienst im 1. Bundesmux (DR Deutschland, DAB 5C) |
| DAB+ / DLS / FIC / FIG | digitaler Hoerfunk / Dynamic Label (Text) / Fast Information Channel / Fast Information Group |
| TII | Transmitter Identification Information (Senderkennung, Mast-Zuordnung) |
| ECC / LTO | Extended Country Code / Local Time Offset |
| RDS / PI / PS / PTY / TA / EWS | Radio Data System / Programmkennung / Sendername / Programmtyp / Verkehrsdurchsage-Kennzeichen / Emergency Warning System (Gruppe 9A) |
| ODL | Ortsdosisleistung (BfS) |
| FIRMS | NASA-Feuerdaten (Hotspots) |
| GKD | Gewaesserkundlicher Dienst Bayern (Pegel) |
| LRPT | Low Rate Picture Transmission (Meteor-M) |
| QRM | Stoerungen im Funkempfang |
| MAD | Median Absolute Deviation (robuste Streuung) |
| TPMS | Reifendruck-Sensoren (433 MHz) |
| ISM | Industrial, Scientific, Medical (433/868 MHz) |
| APRS | Amateurfunk-Positions-/Wetterdaten (144,800 MHz) |
| LongFast | Standard-Funkprofil von Meshtastic |
| sha16 | die ersten 16 Zeichen des sha256 einer Datei (Stand-Kennung) |
| Schicht / Marker | Patch-Block "# ===== name: ... =====" im Code |
| Rauchtest | 26 Pruefungen (12 Seiten + 14 APIs) nach jedem Patch |

## Pruefbericht dieser Ausgabe (automatisch)

Abgleich des redaktionellen Textes mit dem Code und dem laufenden System. Was fehlt, steht im Kapitel "Nachtrag" am Ende.

@@VALIDATION@@

Stand-Hash (nur stabile Teile; aendert sich, wenn Text, Routen, Dateien, Marker oder Units sich aendern): @@STANDHASH@@
'''
# ----------------------------------------------------------------------------------------------------------------------------------------------

FILE_ROLES = {
    "dashboard.py": "Flask-Monolith: alle Seiten, APIs, Abrufe, Patch-Schichten",
    "prepper_sdr.py": "SDR-Dienst prepper-sdr: Planer, Geraete-Register, DAB/RDS/433/APRS/Meteor, Watchdog, Planer-Waechter",
    "sdr_manager.py": "Lagezentrum-Logik: SDR-Status, DB-Abgleich, Lebenszeichen",
    "database.py": "SQLite-Zugriff lagezentrum.db: Schema, Migration, Retention",
    "mesh_router.py": "Mesh-Dublettenpruefung + automatischer Versand echter Alarme an Mesh 1 (Kill-Switch)",
    "lagegeo.py": "NINA-Warngebiete (GeoJSON) vereinfachen und cachen",
    "mesh_rules.py": "Mesh-Routing-Regeln (mesh_rules.json): Hosts, Cooldown, Art je Knoten",
    "mesh_session.py": "Mesh-Sessions pruefen (genau eine TCP-Session je Knoten)",
    "mesh_bridge.py": "Bridge Mesh 1: eine TCP-Session, Queue, Pong, Inbox",
    "mesh_bridge_bayern.py": "Bridge Mesh 2: eine TCP-Session, Queue, Pong, Inbox",
    "mesh_ping_reply.py": "Auto-Antwort auf ping/test (Mesh 1)",
    "mesh_ping_reply2.py": "Auto-Antwort auf ping/test (Mesh 2)",
    "mesh_ping_reply_bayern.py": "Auto-Antwort auf ping/test (Mesh 2, Bayern)",
    "mesh_inbox_util.py": "Hilfen fuer die Mesh-Inbox",
    "mesh_chutil.py": "Kanalauslastung (DeviceMetrics) sammeln/lesen",
    "mesh_hang_watchdog.py": "Hang-Erkennung der Mesh-Verbindungen, optionaler Neustart",
    "mesh_reply_watch.py": "letzte Ping/Test-Antwort je Mesh",
    "mesh_node_label.py": "Knoten-Labels fuer Mesh-Meldungen",
    "nina_calm.py": "NINA-Kachel/Mesh ruhig halten (jede ID hoechstens einmal)",
    "luft.py": "Luftlage: FIRMS, Sensor.community, Wind",
    "zuhause.py": "Seite Zuhause: Abfall, Apotheken-Notdienst, Tierkliniken, Notrufe",
    "funk_health.py": "Funk-Seite: Mesh-Status und Kanalauslastung",
    "funk_page.py": "Funk-Seite: Seitenaufbau",
    "health_check.py": "Health-Report health_status.json (nie Neustart)",
    "watchdog.py": "schlanker Dashboard-Watchdog mit Cooldown",
    "speedtest_run.py": "Ookla-Speedtest (alle 3 h, manuell)",
    "uplink_detect.py": "Telekom/Starlink-Erkennung",
    "tiles_sources.py": "Datenquellen-Liste fuer /pi",
    "archive_store.py": "Langzeitarchiv unter archive/",
    "prepper_gps.py": "Dach-GPS (gpsd) nur lesen, GPS/GLONASS bewerten",
    "prepper_evlog.py": "Ereignis-Log QRM/Gewitter/GPS und KFZ-Sensoren",
    "prepper_sdr_net.py": "Netzzugriffe des SDR-Planers (TLE, welle-cli lokal)",
    "prepper_docs.py": "Generator dieser Projektbeschreibung (TXT+MD in docs/)",
    "smoke.sh": "Rauchtest-Skript (liest nur)",
    "config.py": "Konfiguration/Schluessel (Rechte 600; nie lesen/ausgeben)",
    "lagezentrum.db": "SQLite-Datenbank des Lagezentrums",
    "sdr_config.json": "Geraete-Register und SDR-Einstellungen",
    "mesh_rules.json": "Mesh-Routing-Regeln (Datei zu mesh_rules.py)",
    "mesh_auto.json": "Kill-Switch fuer den Auto-Versand echter Alarme (fehlt/kaputt = AUS)",
    "archive/": "Langzeitarchiv: Rohpunkte 90 Tage, Tageswerte, Ereignisse; dabhist/techlog/evlog",
    "docs/": "Projektbeschreibung Lage Pi (TXT + Markdown, Versionsdateien)",
    "mesh_inbox/": "Inbox-Dateien Mesh 1",
    "mesh_inbox_bayern/": "Inbox-Dateien Mesh 2",
    "static/": "statische Dateien (Leaflet-Karte, Bilder)",
    "tools/": "backup.sh, restore.sh, prepper-clone-ssd-to-sd, ookla/",
    "backups/": "Sicherungen der Sicherung-Kachel (tools/backup.sh); nicht ins Repo",
    "secrets/": "Schluessel und Freigabe-Dateien: Inhalt nie lesen oder ausgeben",
    "sdr_lib/": "SDR-Hilfsbibliothek (nicht naeher dokumentiert)",
    "systemd/": "Unit-Dateien (Patch sysBoot; nicht naeher dokumentiert)",
    "sdr_status.json": "SDR-Zustand (Notkopie; primaer lagezentrum.db)",
    "broadcast_state.json": "Rundfunkzustand UKW/DAB (Notkopie)",
    "sdr_dabhist.json": "Ring der DAB-Textmeldungen",
    "sdr_events.json": "Ereignis-Ring QRM/Gewitter/GPS",
    "sdr_kfz.json": "KFZ-Sensoren (TPMS) Ring",
    "sdr_techlog.json": "Technik-Verlauf (Sync, Ensemble, Masten)",
    "sdr_wd.json": "Daten-Watchdog-Zustand (ueberlebt Neustart)",
    "sdr_mode.json": "Betriebsart des SDR-Planers (schreibt das Dashboard)",
    "health_status.json": "Health-Check-Ergebnis",
    "mesh_boot_quiet.json": "Boot-Ruhe fuer Auto-Mesh",
    "nina_mesh_sent.json": "gesendete NINA-IDs (7 Tage)",
    "speedtest.json": "Ergebnisse des Ookla-Speedtests",
    "keep-last.json": "letzte gute Datenstaende der Quellen",
}


def note(msg):
    NOTES.append(str(msg)[:300])


def rd(p, binary=False, limit=40 * 1024 * 1024):
    with open(p, "rb" if binary else "r", **({} if binary else {"encoding": "utf-8", "errors": "replace"})) as f:
        return f.read(limit)


def sha16(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for ch in iter(lambda: f.read(1 << 20), b""):
            h.update(ch)
    return h.hexdigest()[:16]


def nlines(p):
    n = 0
    with open(p, "rb") as f:
        for ch in iter(lambda: f.read(1 << 20), b""):
            n += ch.count(b"\n")
    return n


def now_berlin():
    fixed = os.environ.get("PRDOCS_NOW")
    if fixed:
        return datetime.datetime.strptime(fixed, "%Y%m%d-%H%M")
    try:
        from zoneinfo import ZoneInfo
        return datetime.datetime.now(ZoneInfo("Europe/Berlin")).replace(tzinfo=None)
    except Exception:
        return datetime.datetime.now()


def run(cmd, timeout=20):
    for versuch in (1, 2):                      # ein Fehlschlag (Timeout, Prozess nicht startbar) wird einmal wiederholt: ein kurzer Aussetzer darf die Beschreibung nicht veraendern
        try:
            r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, universal_newlines=True)
            return r.returncode, r.stdout
        except Exception as e:
            if versuch == 2:
                note("%s: %s" % (" ".join(cmd[:3]), e))
    return 99, ""


def cell(x):
    return re.sub(r"\s+", " ", str(x if x is not None else "")).replace("|", "/").strip()


def table(head, rows):
    out = ["| " + " | ".join(cell(h) for h in head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    for r in rows:
        out.append("| " + " | ".join(cell(c) for c in r) + " |")
    return "\n".join(out)


def port():
    p = os.environ.get("PRDOCS_PORT")
    if p and p.isdigit():
        return int(p)
    try:                                              # nur die Zeile PORT = n (wie die apply-Skripte), sonst nichts aus config.py
        with open(os.path.join(BASE, "config.py"), encoding="utf-8", errors="replace") as f:
            for ln in f:
                m = re.match(r"\s*PORT\s*=\s*([0-9]{2,5})\b", ln)
                if m:
                    return int(m.group(1))
    except Exception:
        pass
    return 5000


def http_get(path, timeout=8, maxb=3 * 1024 * 1024):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port(), path), timeout=timeout) as r:
            return r.status, r.read(maxb).decode("utf-8", "replace")
    except Exception as e:
        return 0, str(e)[:120]


# ---------------------------------------------------------------- Sammler ----------------------------------------------------------------
def collect_ast_routes(src):
    """Routen aus dashboard.py ohne Import: @app.route, app.add_url_rule (Literale, Tupel-Schleifen, einfache Namen)."""
    out = {}
    try:
        t = ast.parse(src)
    except Exception as e:
        note("AST dashboard.py: %s" % e)
        return out
    consts = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str):
            for x in n.targets:
                if isinstance(x, ast.Name):
                    consts[x.id] = n.value.value
    parents = {}
    for n in ast.walk(t):
        for c in ast.iter_child_nodes(n):
            parents[id(c)] = n

    def meth(call):
        for k in call.keywords:
            if k.arg == "methods":
                try:
                    return sorted(str(x) for x in ast.literal_eval(k.value))
                except Exception:
                    return ["?"]
        return ["GET"]

    def add(rule, m, fn, how):
        if isinstance(rule, str) and rule.startswith("/"):
            out.setdefault(rule, {"methods": set(), "fn": fn, "how": how})["methods"].update(m)

    for n in ast.walk(t):
        if isinstance(n, ast.FunctionDef):
            for d in n.decorator_list:
                if isinstance(d, ast.Call) and getattr(d.func, "attr", "") == "route" and d.args and isinstance(d.args[0], ast.Constant):
                    add(d.args[0].value, meth(d), n.name, "route")
        if isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "add_url_rule" and n.args:
            a0 = n.args[0]
            fn = ""
            for k in n.keywords:
                if k.arg == "view_func":
                    fn = ast.unparse(k.value)[:60]
            if isinstance(a0, ast.Constant):
                add(a0.value, meth(n), fn, "add_url_rule")
            elif isinstance(a0, ast.Name):
                if a0.id in consts:
                    add(consts[a0.id], meth(n), fn, "add_url_rule")
                    continue
                p = parents.get(id(n))
                while p is not None and not isinstance(p, ast.For):
                    p = parents.get(id(p))
                if p is not None and isinstance(p.target, ast.Tuple) and isinstance(p.iter, (ast.Tuple, ast.List)):
                    names = [e.id if isinstance(e, ast.Name) else None for e in p.target.elts]
                    if a0.id in names:
                        k = names.index(a0.id)
                        for el in p.iter.elts:
                            if isinstance(el, (ast.Tuple, ast.List)) and len(el.elts) > k:
                                v = el.elts[k]
                                m = ["GET"]
                                if "_m" in names or any(x and x.endswith("m") and x != a0.id for x in names):
                                    for j, nm in enumerate(names):
                                        if nm and j != k and j < len(el.elts) and isinstance(el.elts[j], (ast.List, ast.Tuple)):
                                            try:
                                                m = sorted(ast.literal_eval(el.elts[j]))
                                            except Exception:
                                                pass
                                if isinstance(v, ast.Constant):
                                    add(v.value, m, ast.unparse(el.elts[2])[:60] if len(el.elts) > 2 else "", "add_url_rule(Schleife)")
                                elif isinstance(v, ast.Name) and v.id in consts:
                                    add(consts[v.id], m, "", "add_url_rule(Schleife)")
    return out


def collect_routes(dash_src, live=True):
    """Liste (pfad, methoden, endpunkt, quelle). Live: /api/docs/routes des laufenden Dashboards (authoritativ), sonst AST."""
    ast_r = collect_ast_routes(dash_src) if dash_src else {}
    rows, src = [], "ast"
    if live:
        st, body = http_get("/api/docs/routes")
        if st == 200:
            try:
                d = json.loads(body)
                rows = [(r["rule"], ",".join(r.get("methods") or []), r.get("endpoint", ""), "live") for r in d.get("routes", [])]
                src = "live"
            except Exception as e:
                note("Routen live: %s" % e)
        else:
            note("Routen live nicht erreichbar (%s) - nur statisch aus dashboard.py" % str(body)[:80])
    if not rows:
        rows = [(k, ",".join(sorted(v["methods"])), v["fn"], v["how"]) for k, v in sorted(ast_r.items())]
    live_set = {r[0] for r in rows}
    miss = sorted(set(ast_r) - live_set) if src == "live" else []
    return rows, ast_r, src, miss


def page_templates(src):
    """Seiten-Vorlagen PAGE*: Name, Zeilen, statische Kachel-Ueberschriften; Zuordnung Route -> Vorlage per AST (Name im Funktionskoerper)."""
    res, rmap = {}, {}
    try:
        t = ast.parse(src)
        L = src.split("\n")
        for n in t.body:
            if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and re.match(r"PAGE[A-Z0-9_]*$", x.id) for x in n.targets):
                seg = "\n".join(L[n.lineno - 1:n.end_lineno])
                nm = [x.id for x in n.targets if isinstance(x, ast.Name)][0]
                tt = [clean_title(x) for x in re.findall(r'<div class="title"[^>]*>(.*?)</div>', seg, re.S)] + [clean_title(x) for x in re.findall(r"<h[12][^>]*>(.*?)</h[12]>", seg, re.S)]
                res[nm] = {"line": n.lineno, "end": n.end_lineno, "titles": [x for x in tt if x]}
        for n in ast.walk(t):
            if isinstance(n, ast.FunctionDef):
                paths = [d.args[0].value for d in n.decorator_list if isinstance(d, ast.Call) and getattr(d.func, "attr", "") == "route" and d.args and isinstance(d.args[0], ast.Constant)]
                names = {x.id for x in ast.walk(n) if isinstance(x, ast.Name) and x.id in res}
                for pth in paths:
                    rmap.setdefault(pth, set()).update(names)
    except Exception as e:
        note("PAGE-Vorlagen: %s" % e)
    return res, rmap


def clean_title(x):
    x = _html.unescape(re.sub(r"<[^>]+>", " ", x))
    x = re.sub(r"\{\{.*?\}\}|\{%.*?%\}", " ", x)
    x = re.sub(r"\s+", " ", x).strip()
    return x if len(x) >= 3 else ""


_TR = {"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"}
_STATUSW = {"ok", "fehler", "pruefen", "warnung", "gelb", "rot", "gruen", "aus", "an"}


def tr(x):
    x = x.lower()
    for k, v in _TR.items():
        x = x.replace(k, v)
    return x


def alnum(x):
    return " ".join(re.sub(r"[^0-9a-z ]+", " ", tr(x)).split())


def norm_key(x):
    w = []
    for t in alnum(x).split():
        if t in _STATUSW and w:
            break
        w.append(t)
    return " ".join(w[:3])


def live_pages():
    """Server-seitig gerenderte Kachel-Ueberschriften der Seiten (nur GET der festen Seitenliste, wie der Rauchtest)."""
    out = {}
    for p in LIVE_PAGES:
        st, body = http_get(p, timeout=25)
        if st != 200:
            out[p] = None
            continue
        tit = [clean_title(x) for x in re.findall(r'<div class="title"[^>]*>(.*?)</div>', body, re.S)]
        ids = sorted(set(re.findall(r'\bid="([A-Za-z0-9_]+(?:Card|Box|Tile))"', body)))
        out[p] = {"titles": [x for x in tit if x], "ids": ids}
    return out


def static_ids(src):
    ids = set(re.findall(r"""id=\\?["']([A-Za-z][A-Za-z0-9]{3,}(?:Card|Box|Tile|Tile2))\\?["']""", src))
    ids |= set(re.findall(r"""\.id\s*=\s*['"]([A-Za-z][A-Za-z0-9]{3,}(?:Card|Box|Tile))['"]""", src))
    return sorted(ids)


MARK_RE = re.compile(r"^# ===== ([A-Za-z0-9_ ()]+?)(?:: (.*?))?(?: =====)?\s*$")


def collect_markers(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, ln in enumerate(f, 1):
                if ln.startswith("# ===== ") and not ln.startswith("# ===== /"):
                    m = MARK_RE.match(ln.rstrip("\n"))
                    if m:
                        out.append((i, m.group(1).strip(), (m.group(2) or "").strip()))
    except Exception as e:
        note("Marker %s: %s" % (os.path.basename(path), e))
    return out


def project_files():
    rows = []
    try:
        for nm in sorted(os.listdir(BASE)):
            p = os.path.join(BASE, nm)
            if not os.path.isfile(p) or os.path.islink(p):
                continue
            if ".bak" in nm or nm.startswith(".") or nm.endswith((".pyc", ".swp", ".tmp")):
                continue
            rows.append(nm)
    except Exception as e:
        note("Dateiliste: %s" % e)
    return rows


def py_head(p):
    try:
        t = ast.parse(rd(p, limit=4 * 1024 * 1024))
        d = ast.get_docstring(t)
        if d:
            return re.sub(r"\s+", " ", d.strip().splitlines()[0])[:140]
        with open(p, encoding="utf-8", errors="replace") as f:
            for _ in range(6):
                ln = f.readline().strip()
                if ln.startswith("#") and not ln.startswith("#!"):
                    return ln.lstrip("# ").strip()[:140]
    except Exception:
        pass
    return ""


def collect_units():
    """systemd-Units (nur lesend): relevante Namen, Beschreibung, Zustand; Auszug aus show (kein Environment, keine Argumente)."""
    units = {}
    rc, out = run([SYSTEMCTL, "list-unit-files", "--no-legend", "--no-pager", "--type=service,timer,path,socket"])
    if rc == 0:
        for ln in out.splitlines():
            f = ln.split()
            if len(f) >= 2 and UNIT_RE.search(f[0]) and "@" not in f[0]:
                units[f[0]] = {"file": f[1]}
    else:
        note("systemctl list-unit-files nicht lesbar (rc %s)" % rc)
    rc, out = run([SYSTEMCTL, "list-units", "--all", "--no-legend", "--no-pager", "--plain", "--type=service,timer,path,socket"])
    if rc == 0:
        for ln in out.splitlines():
            f = ln.split(None, 4)
            if len(f) >= 4 and UNIT_RE.search(f[0]) and "@" not in f[0]:
                u = units.setdefault(f[0], {"file": "-"})
                u.update({"load": f[1], "active": f[2], "sub": f[3], "desc": f[4].strip() if len(f) > 4 else ""})
    try:                                              # Units mit Verweis auf den Projektordner (auch ohne passenden Namen)
        for nm in os.listdir(UNIT_DIR):
            if nm.endswith((".service", ".timer", ".path", ".socket")) and nm not in units:
                try:
                    if BASE in rd(os.path.join(UNIT_DIR, nm), limit=65536):
                        units[nm] = {"file": "fragment"}
                except Exception:
                    pass
    except Exception as e:
        note("Unit-Ordner: %s" % e)
    for nm, u in sorted(units.items()):
        rc, out = run([SYSTEMCTL, "show", nm, "-p", "Description", "-p", "ExecStart", "-p", "User", "-p", "Restart", "-p", "WatchdogUSec", "-p", "WorkingDirectory", "-p", "FragmentPath", "-p", "DropInPaths", "-p", "Triggers", "-p", "OnCalendar"], timeout=10)
        if rc != 0:
            continue
        for ln in out.splitlines():
            k, _, v = ln.partition("=")
            if k == "ExecStart":
                m = re.search(r"path=(\S+)", v)
                a = re.search(r"argv\[\]=(.*?)(?: ;|$)", v)
                prog = m.group(1) if m else ""
                scr = ""
                if a:
                    for tok in a.group(1).split():
                        if re.search(r"\.(py|sh)$", tok):
                            scr = os.path.basename(tok)
                            break
                u["exec"] = (os.path.basename(prog) + (" " + scr if scr else "")).strip()
            elif k in ("Description", "User", "Restart", "WorkingDirectory", "FragmentPath", "DropInPaths", "Triggers"):
                u[k.lower()] = v.strip()
            elif k == "WatchdogUSec":
                u["wd"] = v.strip()
    # nur installierte Units (Unit-Datei oder Fragment im Projektordner): transiente Units (z. B. von sudo/systemd-run) und "not-found"-Verweise kommen und gehen zwischen zwei Laeufen
    return {nm: u for nm, u in units.items() if u.get("file") not in (None, "-") or u.get("fragmentpath")}


def collect_timers():
    rc, out = run([SYSTEMCTL, "list-timers", "--all", "--no-legend", "--no-pager"])
    rows = []
    if rc == 0:
        for ln in out.splitlines():
            m = re.search(r"(\S+\.timer)\s+(\S+\.service)", ln)
            if m and UNIT_RE.search(m.group(1)):
                rows.append((m.group(1), m.group(2)))
    return sorted(set(rows))                    # list-timers sortiert nach der naechsten Ausloesung: die Reihenfolge wechselt im Betrieb, der Inhalt nicht


def collect_external():
    rows = []
    for d in SBIN_DIRS:
        try:
            for nm in sorted(os.listdir(d)):
                if nm.startswith(("prepper", "mesh", "sdr")):
                    p = os.path.join(d, nm)
                    if os.path.isfile(p) and not os.path.islink(p):
                        rows.append((p, sha16(p), nlines(p)))
        except Exception:
            pass
    sud = []
    try:
        for nm in sorted(os.listdir(SUDOERS_DIR)):
            if re.search(r"prepper|mesh|sdr", nm):
                sud.append(nm)
    except Exception as e:
        note("sudoers.d nicht lesbar (nur Namen gebraucht, ok ohne Rechte): %s" % str(e)[:60])
    return rows, sud


def collect_db():
    """Tabellen und Spalten (stabil) + Zeilenzahlen (fluechtig) der SQLite-Datenbank; nur lesend (mode=ro), keine Inhalte."""
    p = os.path.join(BASE, "lagezentrum.db")
    out = {}
    if not os.path.exists(p):
        note("lagezentrum.db nicht vorhanden")
        return out
    try:
        c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=3)
        try:
            for (nm,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"):
                cols = [r[1] for r in c.execute('PRAGMA table_info("%s")' % nm.replace('"', ""))]
                try:
                    n = c.execute('SELECT count(*) FROM "%s"' % nm.replace('"', "")).fetchone()[0]
                except Exception:
                    n = None
                out[nm] = (cols, n)
        finally:
            c.close()
    except Exception as e:
        note("lagezentrum.db: %s" % str(e)[:100])
    return out


def collect_patch_history():
    """Patch-Staende aus den Sicherungsdateien *.bak-NAME-JJJJMMTT-HHMMSS (keepLast 3 je Datei -> nur die neueren Patches sichtbar)."""
    seen = {}
    try:
        for nm in os.listdir(BASE):
            m = re.match(r"^(.+?)\.bak-([A-Za-z0-9_]+)-([0-9]{8})-([0-9]{6})$", nm)
            if m:
                k = m.group(2)
                v = (m.group(3), m.group(4))
                e = seen.setdefault(k, {"files": set(), "last": v})
                e["files"].add(m.group(1))
                e["last"] = max(e["last"], v)
    except Exception as e:
        note("Sicherungsdateien: %s" % e)
    return seen


# ------------------------------------------------------------------ Markup ------------------------------------------------------------------
def parse(text):
    """Mini-Markup -> Bloecke. '# '/'## '/'### ' Ueberschriften, '- ' Aufzaehlung ('  - ' zweite Ebene), '|'-Tabellen, ``` Code, Leerzeile trennt Absaetze."""
    B, L, i = [], text.split("\n"), 0
    while i < len(L):
        ln = L[i]
        if ln.startswith("```"):
            j, code = i + 1, []
            while j < len(L) and not L[j].startswith("```"):
                code.append(L[j]); j += 1
            B.append(("code", code)); i = j + 1; continue
        m = re.match(r"^(#{1,3}) (.*)$", ln)
        if m:
            B.append(("h%d" % len(m.group(1)), m.group(2).strip())); i += 1; continue
        if ln.startswith("|"):
            rows = []
            while i < len(L) and L[i].startswith("|"):
                cells = [c.strip() for c in L[i].strip().strip("|").split("|")]
                if not all(re.match(r"^:?-{2,}:?$", c) for c in cells):
                    rows.append(cells)
                i += 1
            B.append(("table", rows)); continue
        if re.match(r"^ {0,2}- ", ln):
            items = []
            while i < len(L) and (re.match(r"^ {0,4}- ", L[i]) or (L[i].startswith("  ") and L[i].strip() and items)):
                if re.match(r"^ {0,4}- ", L[i]):
                    lvl = 1 if L[i].startswith("  ") else 0
                    items.append([lvl, L[i].strip()[2:].strip()])
                else:
                    items[-1][1] += " " + L[i].strip()
                i += 1
            B.append(("ul", items)); continue
        if not ln.strip():
            i += 1; continue
        para = [ln.strip()]
        i += 1
        while i < len(L) and L[i].strip() and not re.match(r"^(#{1,3} |\||```|\s{0,2}- )", L[i]):
            para.append(L[i].strip()); i += 1
        B.append(("p", " ".join(para)))
    return B


def render_txt(B):
    out, h1, h2 = [], 0, 0
    for kind, v in B:
        if kind == "h1":
            h1 += 1; h2 = 0
            out += ["", "=" * WIDTH, "%d. %s" % (h1, v.upper()), "=" * WIDTH]
        elif kind == "h2":
            h2 += 1
            t = "%d.%d %s" % (h1, h2, v)
            out += ["", t, "-" * min(len(t), WIDTH)]
        elif kind == "h3":
            out += ["", "-- %s --" % v]
        elif kind == "p":
            out += [""] + textwrap.wrap(v.replace("`", ""), WIDTH, break_long_words=False, break_on_hyphens=False)
        elif kind == "ul":
            out.append("")
            for lvl, s in v:
                ind = "  " * lvl
                out += textwrap.wrap(s.replace("`", ""), WIDTH, initial_indent=ind + "- ", subsequent_indent=ind + "  ", break_long_words=False, break_on_hyphens=False)
        elif kind == "code":
            out += [""] + ["    " + c for c in v]
        elif kind == "table":
            rows = [[x.replace("`", "") for x in r] for r in v]
            nc = max(len(r) for r in rows)
            rows = [r + [""] * (nc - len(r)) for r in rows]
            w = [min(max(len(r[c]) for r in rows), 34) for c in range(nc)]
            w = [max(x, 4) for x in w]
            w[-1] = min(max(len(r[-1]) for r in rows), max(30, 112 - sum(w[:-1]) - 3 * (nc - 1)))
            if nc == 1:
                w[0] = min(max(len(r[0]) for r in rows), WIDTH)
            out.append("")
            for k, r in enumerate(rows):
                cells = [textwrap.wrap(r[c], w[c], break_long_words=True, break_on_hyphens=False) or [""] for c in range(nc)]
                for ln in range(max(len(x) for x in cells)):
                    out.append(" | ".join((cells[c][ln] if ln < len(cells[c]) else "").ljust(w[c]) for c in range(nc)).rstrip())
                if k == 0:
                    out.append("-+-".join("-" * w[c] for c in range(nc)))
    return "\n".join(out).strip("\n") + "\n"


def render_md(B):
    out, h1, h2 = [], 0, 0
    for kind, v in B:
        if kind == "h1":
            h1 += 1; h2 = 0
            out += ["", "# %d. %s" % (h1, v)]
        elif kind == "h2":
            h2 += 1
            out += ["", "## %d.%d %s" % (h1, h2, v)]
        elif kind == "h3":
            out += ["", "### %s" % v]
        elif kind == "p":
            out += ["", v]
        elif kind == "ul":
            out.append("")
            out += ["%s- %s" % ("  " * lvl, s) for lvl, s in v]
        elif kind == "code":
            out += ["", "```"] + v + ["```"]
        elif kind == "table":
            rows = v
            nc = max(len(r) for r in rows)
            rows = [[cell(c) for c in r] + [""] * (nc - len(r)) for r in rows]
            out.append("")
            out.append("| " + " | ".join(rows[0]) + " |")
            out.append("|" + "|".join("---" for _ in range(nc)) + "|")
            for r in rows[1:]:
                out.append("| " + " | ".join(r) + " |")
    return "\n".join(out).strip("\n") + "\n"


def toc(B):
    out, h1, h2 = [], 0, 0
    for kind, v in B:
        if kind == "h1":
            h1 += 1; h2 = 0
            out.append("%d. %s" % (h1, v))
        elif kind == "h2":
            h2 += 1
            out.append("   %d.%d %s" % (h1, h2, v))
    return out


# --------------------------------------------------------------- Auto-Abschnitte ---------------------------------------------------------------
class Ctx:
    pass


def build_ctx(live=True):
    c = Ctx()
    c.dash_path = os.path.join(BASE, "dashboard.py")
    c.dash_src = rd(c.dash_path) if os.path.exists(c.dash_path) else ""
    if not c.dash_src:
        note("dashboard.py nicht lesbar")
    c.routes, c.ast_routes, c.route_src, c.route_miss = collect_routes(c.dash_src, live)
    c.pages, c.rmap = page_templates(c.dash_src)
    c.live = live_pages() if (live and c.route_src == "live") else {}
    c.ids = static_ids(c.dash_src)
    c.files = project_files()
    c.units = collect_units()
    c.timers = collect_timers()
    c.ext, c.sudo = collect_external()
    c.db = collect_db()
    c.hist = collect_patch_history()
    c.markers = {}
    for nm in ("dashboard.py", "prepper_sdr.py", "sdr_manager.py", "database.py", "mesh_router.py", "lagegeo.py"):
        p = os.path.join(BASE, nm)
        if os.path.exists(p):
            c.markers[nm] = collect_markers(p)
    return c


def a_meta(c, ver, ts):
    host = socket.gethostname()
    return "\n".join(["- Version: v%s (Format JJJJMMTT-HHMM, Berlin-Zeit; identisch in Dateiname, Kachel und diesem Kopf)" % ver,
                      "- Erzeugt: %s (Berlin) von prepper_docs.py (Generator %s) auf dem Host %s, Python %s, %s" % (ts.strftime("%d.%m.%Y %H:%M"), GEN_VERSION, host, platform.python_version(), platform.platform()),
                      "- Routenquelle: %s%s" % ("laufendes Dashboard (/api/docs/routes, authoritativ) + AST-Abgleich" if c.route_src == "live" else "NUR statisch (AST aus dashboard.py) - Dashboard nicht erreichbar oder ohne projDoc",
                                              ("; im Code, aber nicht live registriert: %s" % ", ".join(c.route_miss[:12])) if c.route_miss else ""),
                      "- Diese Datei wird vollautomatisch aus Textkern + Live-Daten erzeugt; Nummern/Hashes/Listen in den Abschnitten 'automatisch' gelten fuer den Zeitpunkt der Erzeugung."])


def route_kind(path, methods):
    if path.startswith("/api/"):
        return "API" + (" (schreibend: POST)" if "POST" in methods else "")
    if "<" in path:
        return "Datei/Bild"
    return "Seite"


def a_routes(c):
    rows = []
    for path, meth, ep, how in sorted(c.routes):
        smoke = "ja" if (path in SMOKE_PAGES or path in SMOKE_APIS) else ""
        rows.append((path, meth, ep, route_kind(path, meth), smoke))
    t = table(["Pfad", "Methoden", "Endpunkt/Funktion", "Art", "Rauchtest"], rows)
    n_api = sum(1 for r in rows if r[3].startswith("API"))
    return "%d Routen (%d Seiten/Dateien, %d APIs); 'Rauchtest = ja' = Teil der 26 Pruefungen jedes apply-Skripts (12 Seiten + 14 APIs, muessen HTTP 200 liefern).\n\n%s" % (len(rows), len(rows) - n_api, n_api, t)


def a_page_map(c):
    rows = []
    for path in sorted(set(r[0] for r in c.routes if "<" not in r[0] and not r[0].startswith("/api/"))):
        tpl = sorted(c.rmap.get(path, []))
        tit = []
        for tp in tpl:
            tit += c.pages.get(tp, {}).get("titles", [])
        lv = c.live.get(path) or {}
        rows.append((path, ", ".join(tpl) or "(Seite wird in einem Patch-Block erzeugt)", "; ".join(dict.fromkeys(tit))[:300] or "-", "; ".join(dict.fromkeys(lv.get("titles", [])))[:300] or "-"))
    return table(["Seite", "Vorlage im Code", "Kachel-Ueberschriften statisch (Vorlage)", "serverseitig beim Lauf gerendert"], rows) + \
        "\n\nHinweis: Viele Kacheln entstehen erst im Browser (JavaScript, z. B. /funk) oder werden von Patch-Bloecken eingefuegt; die redaktionelle Beschreibung der Seiten steht in Kapitel 5."


def a_files(c):
    rows, data = [], []
    for nm in c.files:
        p = os.path.join(BASE, nm)
        if nm == "config.py":
            rows.append((nm, "-", "-", FILE_ROLES.get(nm, "Konfiguration"), "enthaelt Schluessel: Inhalt nie in Beschreibungen/Chats; Hash bewusst nicht aufgefuehrt"))
        elif nm.endswith((".py", ".sh")):
            try:
                rows.append((nm, nlines(p), sha16(p), FILE_ROLES.get(nm) or py_head(p) or "(nicht dokumentiert)", ""))
            except Exception as e:
                note("Datei %s: %s" % (nm, e))
        elif nm.endswith(".db"):
            rows.append((nm, "-", "-", FILE_ROLES.get(nm, "Datenbank"), "Laufzeitdaten, nie ins Repo"))
        else:
            r = FILE_ROLES.get(nm)
            data.append("%s (%s)" % (nm, r) if r else nm)
    out = table(["Datei", "Zeilen", "sha16", "Aufgabe", "Anmerkung"], rows)
    if data:
        out += "\n\nLaufzeit-/Datendateien im Projektordner (Inhalt nicht Teil der Beschreibung; Rotationskopien wie *.json.1 inklusive): " + "; ".join(data) + "."
    return out


def a_dirs(c):
    rows = []
    try:
        for nm in sorted(os.listdir(BASE)):
            p = os.path.join(BASE, nm)
            if os.path.isdir(p) and not os.path.islink(p) and nm not in ("__pycache__", "venv", ".git"):
                try:
                    n = len(os.listdir(p))
                except Exception:
                    n = "?"
                rows.append((nm + "/", n, FILE_ROLES.get(nm + "/", "(nicht dokumentiert)")))
    except Exception as e:
        note("Unterordner: %s" % e)
    return table(["Ordner", "Eintraege", "Aufgabe"], rows)


def a_markers(c):
    parts = []
    for nm, mk in c.markers.items():
        if not mk:
            continue
        parts.append("### %s (%d Schichten)" % (nm, len(mk)))
        parts.append(table(["Zeile", "Schicht/Patch", "Beschreibung (Kopfkommentar, gekuerzt)"], [(i, n, (d[:260] + "...") if len(d) > 260 else d) for i, n, d in mk]))
    return "\n\n".join(parts)


def a_units(c):
    rows = []
    for nm, u in sorted(c.units.items()):
        rows.append((nm, u.get("file", "-"), u.get("description") or u.get("desc") or "", u.get("exec", ""), u.get("user", ""), u.get("restart", ""), u.get("wd", "")))
    t = table(["Unit", "Zustand der Datei", "Beschreibung", "Programm", "User", "Restart", "WatchdogUSec"], rows)
    tm = table(["Timer", "startet"], c.timers) if c.timers else "Keine passenden Timer gefunden (oder systemctl list-timers nicht lesbar)."
    drop = []
    for nm, u in sorted(c.units.items()):
        if u.get("dropinpaths"):
            drop.append((nm, os.path.basename(os.path.dirname(u["dropinpaths"].split()[0])) + "/" + ", ".join(os.path.basename(x) for x in u["dropinpaths"].split())))
    dt = ("\n\nDrop-ins:\n\n" + table(["Unit", "Drop-in"], drop)) if drop else ""
    return "%d relevante Units (Namensfilter prepper|mesh|sdr|gpsd|chrony|kiwix|... oder Verweis auf den Projektordner):\n\n%s\n\nTimer:\n\n%s%s" % (len(c.units), t, tm, dt)


def a_unit_state(c):
    rows = [(nm, u.get("load", "-"), u.get("active", "-"), u.get("sub", "-")) for nm, u in sorted(c.units.items())]
    return table(["Unit", "load", "active", "sub"], rows) if rows else "keine Daten"


def a_db(c):
    if not c.db:
        return "lagezentrum.db nicht lesbar oder nicht vorhanden (siehe Pruefbericht)."
    return table(["Tabelle", "Spalten"], [(k, ", ".join(v[0])) for k, v in sorted(c.db.items())])


def a_db_counts(c):
    return table(["Tabelle", "Zeilen (Zeitpunkt der Erzeugung)"], [(k, v[1]) for k, v in sorted(c.db.items())]) if c.db else "keine Daten"


def a_external(c):
    rows = [(p, n, h) for p, h, n in c.ext]
    t = table(["Pfad", "Zeilen", "sha16"], rows) if rows else "Keine Hilfsprogramme gefunden (Pfade pruefen)."
    s = ("\n\nsudoers.d-Dateien mit Bezug (nur Namen): " + ", ".join(c.sudo)) if c.sudo else "\n\nsudoers.d: keine passenden Dateinamen sichtbar (Verzeichnis nur mit Rechten lesbar) - Regeln stehen laut Patch-Skripten in /etc/sudoers.d/zz-prepper-sdr-wd."
    return t + s


def a_hist(c):
    if not c.hist:
        return "Keine Sicherungsdateien *.bak-NAME-JJJJMMTT-HHMMSS gefunden."
    rows = []
    for k, v in sorted(c.hist.items(), key=lambda kv: kv[1]["last"], reverse=True):
        d, t = v["last"]
        rows.append((k, "%s.%s.%s %s:%s" % (d[6:8], d[4:6], d[0:4], t[0:2], t[2:4]), ", ".join(sorted(v["files"]))))
    return table(["Patch (Name im Sicherungsnamen)", "zuletzt angewendet", "Dateien mit Sicherung"], rows[:40])


def a_ids(c):
    return ", ".join(c.ids) if c.ids else "-"


AUTO = {"routes": a_routes, "pagemap": a_page_map, "files": a_files, "dirs": a_dirs, "markers": a_markers, "units": a_units, "unitstate": a_unit_state,
        "db": a_db, "dbcounts": a_db_counts, "external": a_external, "history": a_hist, "ids": a_ids}
VOLATILE = {"unitstate", "dbcounts", "history", "dirs"}      # aendern sich im Betrieb: zaehlen nicht fuer "neue Version noetig"


# ------------------------------------------------------------------ Validierung ------------------------------------------------------------------
def redact(text):
    """Schwaerzt Auffaelliges: unbekannte IPv4, Schluessel-/Token-Zuweisungen, lange Hex-/Base64-Ketten, E-Mail-Adressen. Gibt (text, funde)."""
    funde = []

    def ip(m):
        if m.group(0) in IP_OK or m.group(0).startswith(("127.", "224.", "0.")):
            return m.group(0)
        funde.append("IP " + m.group(0))
        return "<IP>"
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", ip, text)

    def kv(m):
        funde.append("Zuweisung " + m.group(1))
        return m.group(1) + m.group(2) + "<entfernt>"
    text = re.sub(r"(?i)\b(api[_-]?key|apikey|token|passwort|password|passwd|secret|bearer)(\s*[:=]\s*)(?!<)[^\s,;|]{6,}", kv, text)

    def longs(m):
        funde.append("lange Kette " + m.group(0)[:8] + "...")
        return "<entfernt>"
    text = re.sub(r"\b[A-Fa-f0-9]{33,}\b|\b(?=[A-Za-z0-9+/]*\d)(?=[A-Za-z0-9+/]*[A-Z])(?=[A-Za-z0-9+/]*[a-z])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/])", longs, text)

    def mail(m):
        funde.append("E-Mail")
        return "<E-Mail>"
    text = re.sub(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b", mail, text)
    text = re.sub(r"(https?://[^\s\"'<>)]+)\?[^\s\"'<>)]*", lambda m: (funde.append("URL-Parameter " + m.group(1)[:30]) or m.group(1) + "?<entfernt>") if re.search(r"(?i)(key|token|secret|pass)", m.group(0)) else m.group(0), text)
    return text, funde


def covered(core_low, key):
    return key and key in core_low


def validate(c, core_text):
    """Abgleich Code/Live gegen den redaktionellen Text. -> (nachtrag_markup, bericht_zeilen)."""
    low = re.sub(r"\s+", " ", core_text.lower())
    low_n = alnum(core_text)
    rep, nach = [], []
    miss_r = []
    for path, meth, ep, how in c.routes:
        base = path.split("<")[0].rstrip("/") or "/"
        if path in ("/", ) or base == "/":
            continue
        if path.lower() not in low and base.lower() not in low:
            miss_r.append((path, meth, ep))
    rep.append("Routen (%s): %d geprueft, %d im Text, %d als Nachtrag" % (c.route_src, len(c.routes), len(c.routes) - len(miss_r), len(miss_r)))
    if miss_r:
        nach.append("### Routen ohne redaktionelle Beschreibung\n\n" + table(["Pfad", "Methoden", "Endpunkt"], miss_r))
    miss_s = [p for p in SMOKE_PAGES + SMOKE_APIS if p != "/" and p.lower() not in low]
    rep.append("Rauchtest-Liste (12 Seiten + 14 APIs): %d fehlen im Text" % len(miss_s))
    if miss_s:
        nach.append("### Rauchtest-Pfade ohne Beschreibung\n\n" + "\n".join("- " + p for p in miss_s))
    titles = {}
    for tp, v in c.pages.items():
        for t in v["titles"]:
            titles.setdefault(norm_key(t), (t, "Vorlage " + tp))
    for pth, v in c.live.items():
        for t in (v or {}).get("titles", []):
            titles.setdefault(norm_key(t), (t, "Seite " + pth))
    miss_t = [(t, w) for k, (t, w) in titles.items() if k and k not in low_n]
    rep.append("Kachel-Ueberschriften (Vorlagen %d + live %d Seiten): %d geprueft, %d als Nachtrag" % (len(c.pages), len([1 for v in c.live.values() if v]), len(titles), len(miss_t)))
    if miss_t:
        nach.append("### Kacheln ohne redaktionelle Beschreibung\n\n" + table(["Ueberschrift", "gefunden in"], miss_t))
    allids = set(c.ids)
    for v in c.live.values():
        allids |= set((v or {}).get("ids", []))
    miss_i = sorted(i for i in allids if i.lower() not in low)
    rep.append("Kachel-/Box-IDs (HTML/JS): %d geprueft, %d als Nachtrag" % (len(allids), len(miss_i)))
    if miss_i:
        nach.append("### Kachel-IDs ohne redaktionelle Beschreibung\n\n" + ", ".join(miss_i))
    miss_u = sorted(n for n in c.units if n.lower() not in low and n.rsplit(".", 1)[0].lower() not in low)
    rep.append("systemd-Units: %d gefunden, %d als Nachtrag" % (len(c.units), len(miss_u)))
    if miss_u:
        nach.append("### Units ohne redaktionelle Beschreibung\n\n" + table(["Unit", "Beschreibung", "Programm"], [(n, c.units[n].get("description") or c.units[n].get("desc") or "", c.units[n].get("exec", "")) for n in miss_u]))
    pyf = [f for f in c.files if f.endswith((".py", ".sh")) and f != "config.py"]
    miss_f = [f for f in pyf if f.lower() not in low]
    rep.append("Programmdateien (.py/.sh) im Projektordner: %d gefunden, %d als Nachtrag" % (len(pyf), len(miss_f)))
    if miss_f:
        nach.append("### Dateien ohne redaktionelle Beschreibung\n\n" + table(["Datei", "Kopfzeile"], [(f, py_head(os.path.join(BASE, f)) or "(nicht dokumentiert)") for f in miss_f]))
    mk_all = {}
    for nm, mk in c.markers.items():
        for i, n, d in mk:
            mk_all.setdefault(n.split(" ")[0].lower(), (nm, n, d))
    miss_m = [(a, b, d[:160]) for k, (a, b, d) in mk_all.items() if k not in low]
    rep.append("Patch-Schichten (Marker): %d geprueft, %d als Nachtrag" % (len(mk_all), len(miss_m)))
    if miss_m:
        nach.append("### Patch-Schichten ohne redaktionelle Beschreibung\n\n" + table(["Datei", "Schicht", "Kopfkommentar"], miss_m))
    miss_x = [p for p, h, n in c.ext if os.path.basename(p).lower() not in low]
    rep.append("Hilfsprogramme ausserhalb des Projektordners: %d gefunden, %d als Nachtrag" % (len(c.ext), len(miss_x)))
    if miss_x:
        nach.append("### Hilfsprogramme ohne redaktionelle Beschreibung\n\n" + "\n".join("- " + p for p in miss_x))
    return "\n\n".join(nach), rep


STABLE_DUMP = []      # (Name, Text) der Teile, die in den Stand-Hash eingehen (nur fuer --dump-stable, Diagnose)


def assemble(c, ver, ts, with_nachtrag=True):
    """-> (Bloecke, Hash der stabilen Teile, Bericht, Nachtrag-Anzahl, Schwaerzungen)."""
    parts_stable, parts_all, named = [], [], []

    def sub(m):
        nm = m.group(1)
        try:
            body = AUTO[nm](c) if nm != "meta" else a_meta(c, ver, ts)
        except Exception as e:
            note("Auto-Abschnitt %s: %s" % (nm, e))
            body = "(Abschnitt %s konnte nicht erzeugt werden: %s)" % (nm, str(e)[:100])
        parts_all.append(body)
        if nm not in VOLATILE and nm != "meta":
            parts_stable.append(body)
            named.append((nm, body))
        return body
    core_only = re.sub(r"@@AUTO (\w+)@@", "", CORE)
    text = re.sub(r"@@AUTO (\w+)@@", sub, CORE)

    def fi(m):
        out = []
        for nm in m.group(1).split(";"):
            nm = nm.strip()
            try:
                p = os.path.join(BASE, nm)
                out.append("%s %s/%d" % (nm, sha16(p), nlines(p)) if os.path.isfile(p) and nm != "config.py" else "%s (nicht gefunden)" % nm)
            except Exception as e:
                out.append("%s (Fehler)" % nm)
        r = " ; ".join(out)
        parts_stable.append(r)
        named.append(("FI", r))
        return r
    text = re.sub(r"@@FI ([^@]+)@@", fi, text)
    nach, rep = validate(c, core_only)
    nn = 0
    if nach and with_nachtrag:
        nn = nach.count("### ")
        text += "\n\n# Nachtrag (automatisch erkannt, noch nicht redaktionell beschrieben)\n\nDie folgenden Funde stehen im Code bzw. auf dem laufenden System, sind aber im redaktionellen Text noch nicht beschrieben. Sie sind vollstaendig (aus den Quellen ermittelt), nur ohne Erlaeuterung.\n\n" + nach
    bericht = "\n".join("- " + x for x in rep)
    text = text.replace("@@VALIDATION@@", bericht)
    text, funde = redact(text)
    B = parse(text)
    stable = hashlib.sha256((re.sub(r"@@AUTO \w+@@", "", CORE) + "\n".join(parts_stable) + nach).encode("utf-8")).hexdigest()
    STABLE_DUMP[:] = named + [("Nachtrag", nach)]
    return B, stable, rep, nn, funde


def version_files(d):
    out = {}
    try:
        for nm in os.listdir(d):
            m = re.match(r"^" + re.escape(STEM) + r"([0-9]{8}-[0-9]{4})\.(txt|md)$", nm)
            if m:
                out.setdefault(m.group(1), []).append(nm)
    except Exception:
        pass
    return out


def atomic_write(path, data):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".pd-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


def main(argv):
    keep = KEEP_DEFAULT
    force = "--force" in argv
    check = "--check" in argv
    live = "--no-live" not in argv
    if "--keep" in argv:
        try:
            keep = max(3, int(argv[argv.index("--keep") + 1]))
        except Exception:
            print("--keep braucht eine Zahl"); return 2
    dump = None
    if "--dump-stable" in argv:
        try:
            dump = argv[argv.index("--dump-stable") + 1]
        except Exception:
            print("--dump-stable braucht einen Dateinamen"); return 2
    ts = now_berlin()
    ver = ts.strftime("%Y%m%d-%H%M")
    c = build_ctx(live)
    B, stable, rep, nn, funde = assemble(c, ver, ts)
    if dump:                                    # Diagnose: die in den Stand-Hash eingehenden Teile (geschwaerzt), damit zwei Laeufe verglichen werden koennen
        try:
            atomic_write(dump, redact("\n".join("##### %s\n%s" % (n, b) for n, b in STABLE_DUMP) + "\n")[0].encode("utf-8"))
        except Exception as e:
            print("--dump-stable: %s" % e)
    # Hash der stabilen Teile (ohne Version/Zeit) -> keine neue Version bei unveraendertem Stand
    marker = "Stand-Hash: " + stable[:16]
    last = None
    vf = version_files(DOCS)
    if vf:
        lv = sorted(vf)[-1]
        try:
            lt = rd(os.path.join(DOCS, STEM + lv + ".txt"))
            m = re.search(r"Stand-Hash: ([0-9a-f]{16})", lt)
            last = (lv, m.group(1) if m else None)
        except Exception:
            last = None
    B = [b for b in B]
    toc_lines = toc(B)
    head_txt = ["=" * WIDTH, "PROJEKTBESCHREIBUNG LAGE PI", "=" * WIDTH,
                "Version: v%s (erzeugt %s Uhr, Berlin-Zeit)" % (ver, ts.strftime("%d.%m.%Y %H:%M")),
                "Dateiname: %s%s.txt (Hauptformat; gleicher Inhalt als .md)" % (STEM, ver),
                "Gegenstand: Prepper-Dashboard \"Kaeswasser Lage Monitor\" auf dem Raspberry Pi 4 \"BND-Prepper\" - Projektdokumentation fuer Frank, KIs und neue Entwickler",
                "Erzeugt von: prepper_docs.py (statischer Textkern + automatische Abschnitte aus dem Ist-Stand des Pi, danach Pruefabgleich); Version = JJJJMMTT-HHMM",
                "", "INHALTSVERZEICHNIS", "-" * 18] + toc_lines + [""]
    head_md = ["# Projektbeschreibung Lage Pi", "",
               "- Version: **v%s** (erzeugt %s Uhr, Berlin-Zeit)" % (ver, ts.strftime("%d.%m.%Y %H:%M")),
               "- Dateiname: `%s%s.md` (gleicher Inhalt wie die .txt, die TXT ist das Hauptformat)" % (STEM, ver),
               "- Gegenstand: Prepper-Dashboard \"Kaeswasser Lage Monitor\" auf dem Raspberry Pi 4 \"BND-Prepper\" - Projektdokumentation fuer Frank, KIs und neue Entwickler",
               "- Erzeugt von: `prepper_docs.py` (statischer Textkern + automatische Abschnitte aus dem Ist-Stand, danach Pruefabgleich)", "",
               "## Inhaltsverzeichnis", ""] + ["%s- %s" % ("  " if x.startswith("   ") else "", x.strip()) for x in toc_lines] + [""]
    txt = "\n".join(head_txt) + render_txt(B).replace("@@STANDHASH@@", marker)
    md = "\n".join(head_md) + render_md(B).replace("@@STANDHASH@@", marker)
    rep_txt = ["Pruefbericht prepper_docs.py v%s" % ver] + rep + ["Schwaerzungen: %d%s" % (len(funde), (" (" + "; ".join(funde[:6]) + ")") if funde else "")] + \
              ["Nachtrag-Abschnitte: %d" % nn] + ["Hinweise der Sammler: %d" % len(NOTES)] + ["  - " + x for x in NOTES[:20]]
    print("\n".join(rep_txt))
    print("Groesse TXT %d B, MD %d B, %d Zeilen TXT; Kapitel: %s" % (len(txt.encode()), len(md.encode()), txt.count("\n"), "; ".join(x for x in toc_lines if not x.startswith(" "))))
    if check:
        print("Trockenlauf (--check): nichts geschrieben")
        return 0
    if last and last[1] == stable[:16] and not force:
        print("UNVERAENDERT: Stand-Hash %s wie in v%s - keine neue Version (--force erzwingt eine)" % (last[1], last[0]))
        return 0
    try:
        os.makedirs(DOCS, exist_ok=True)
        for fmt, data in (("txt", txt), ("md", md)):
            atomic_write(os.path.join(DOCS, "%s%s.%s" % (STEM, ver, fmt)), data.encode("utf-8"))
    except Exception as e:
        print("FEHLER beim Schreiben: %s" % e)
        return 1
    vf = version_files(DOCS)
    for old in sorted(vf)[:-keep]:                      # Rotation: nur Dateien mit genau diesem Namensmuster, aeltere als die letzten N Versionen
        for nm in vf[old]:
            try:
                os.unlink(os.path.join(DOCS, nm))
                print("Rotation: %s entfernt (keepLast %d)" % (nm, keep))
            except Exception as e:
                print("Rotation: %s nicht entfernt (%s)" % (nm, e))
    print("OK Version v%s: %s%s.txt (%d B), %s%s.md (%d B) in %s" % (ver, STEM, ver, len(txt.encode()), STEM, ver, len(md.encode()), DOCS))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
APD_EOF
EXPECT_AC="18e60b32ea5f0d61a7f7f992e500699693731f734370ed3e411781ca840c66dc"
cat > "$W/aircheck.py" << 'AIC_EOF'
"""sdrAir Pruefungen fuer apply-sdrair.sh (nur lesen, ausser 'cfg' = sdr_config.json Geraete-Register schreiben, atomar).
airspy SYSFS | fe WELLE | cfg DIR AIRSN FE | status DIR T0 | funk HTML | ui JSON | t2 JSON | port N"""
import json
import os
import re
import subprocess
import sys
import time

AIR = ("1d50", "60a1")
RTL = (("0bda", "2838"), ("0bda", "2832"))
S1, S2 = "19348831", "72055505"


def rd(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def norm(s):
    s = (s or "").strip().upper()
    for pre in ("AIRSPY SN:", "0X"):
        if s.startswith(pre):
            s = s[len(pre):].strip()
    return s


def newest(d, name, key):
    """sqlC: Stand liegt primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
    best = {}
    try:
        import sqlite3
        c = sqlite3.connect("file:%s?mode=ro" % os.path.join(d, "lagezentrum.db"), uri=True, timeout=10)
        try:
            r = c.execute("SELECT json FROM state WHERE key=?", (key,)).fetchone()
            best = json.loads(r[0]) if r else {}
        finally:
            c.close()
    except Exception:
        best = {}
    try:
        j = json.load(open(os.path.join(d, name), encoding="utf-8"))
        if float(j.get("t") or 0) > float(best.get("t") or 0) or not best:
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def scan(root):
    air, rtl = [], []
    for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        p = os.path.join(root, d)
        v, i = rd(os.path.join(p, "idVendor")).lower(), rd(os.path.join(p, "idProduct")).lower()
        if (v, i) == AIR:
            air.append((d, norm(rd(os.path.join(p, "serial")))))
        elif (v, i) in RTL:
            rtl.append((d, rd(os.path.join(p, "serial"))))
    return air, rtl


def main(a):
    m = a[0]
    if m == "airspy":
        air, rtl = scan(a[1])
        info = "RTL: %s" % (", ".join("%s SN %s" % x for x in rtl) or "keiner")
        if not air:
            print("kein Airspy (USB 1d50:60a1) gefunden · %s" % info); return 2
        if len(air) > 1:
            print("mehrere Airspy gefunden (%s) - Rolle 11D nicht eindeutig · %s" % (", ".join("%s SN %s" % x for x in air), info)); return 3
        sn = air[0][1]
        if not re.fullmatch(r"[0-9A-F]{16}", sn):
            print("Airspy-Seriennummer unlesbar (%r) · %s" % (sn, info)); return 4
        print(sn)
        print("Airspy SN %s an %s · %s" % (sn, air[0][0], info), file=sys.stderr)
        return 0
    if m == "fe":
        w = a[1]
        try:
            l = subprocess.run(["ldd", w], capture_output=True, text=True, timeout=20).stdout
        except Exception as e:
            print("ldd %s: %s" % (w, e)); return 1
        if "libairspy" in l:
            print("airspy"); return 0
        if "libSoapySDR" in l:
            try:
                s = subprocess.run(["SoapySDRUtil", "--info"], capture_output=True, text=True, timeout=30)
                t = (s.stdout + s.stderr).lower()
            except Exception as e:
                print("welle-cli mit SoapySDR, aber SoapySDRUtil fehlt (%s) - Airspy-Modul nicht pruefbar" % e); return 1
            if "airspy" in t:
                print("soapy"); return 0
            print("welle-cli mit SoapySDR, aber kein SoapySDR-Airspy-Modul (soapysdr-module-airspy)"); return 1
        print("welle-cli ohne Airspy-Unterstuetzung (weder libairspy noch SoapySDR gelinkt)"); return 1
    if m == "cfg":
        d, sn, fe = a[1], a[2], a[3]
        assert re.fullmatch(r"[0-9A-F]{16}", sn) and fe in ("airspy", "soapy")
        p = os.path.join(d, "sdr_config.json")
        c = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
        devs = [{"name": "Airspy R2", "kind": "airspy", "usb": "1d50:60a1", "serial": sn, "role": "11D"},
                {"name": "Stick 1", "kind": "rtl", "usb": "0bda:2838", "serial": S1, "role": "5C", "ppm_sfx": ""},
                {"name": "Stick 2", "kind": "rtl", "usb": "0bda:2838", "serial": S2, "role": "hobby", "ppm_sfx": "2"}]
        old = [{k: x.get(k) for k in ("name", "kind", "usb", "serial", "role", "ppm_sfx") if k in x} for x in c.get("devs") or [] if isinstance(x, dict)]
        keep = [x for x in old if x.get("serial") not in (sn, S1, S2)]       # spaeter eingetragene Geraete (3. Stick) bleiben
        new = devs + keep
        if c.get("devs_on") is True and c.get("air_fe") == fe and old == new:
            print("unveraendert (devs_on, %d Geraete, air_fe %s)" % (len(new), fe)); return 0
        c.update(devs_on=True, devs=new, air_fe=fe)
        t = p + ".sdrair-tmp"
        with open(t, "w", encoding="utf-8") as f:
            json.dump(c, f, ensure_ascii=False, indent=1)
            f.flush(); os.fsync(f.fileno())
        if os.path.exists(p):
            st = os.stat(p)
            try:
                os.chown(t, st.st_uid, st.st_gid)
            except OSError:
                pass
            os.chmod(t, st.st_mode & 0o777)
        os.replace(t, p)
        print("geschrieben: devs_on, Airspy R2 %s = 11D, Stick 1 %s = 5C, Stick 2 %s = Hobby%s, air_fe %s" % (sn, S1, S2, (", %d weitere behalten" % len(keep)) if keep else "", fe)); return 0
    if m == "status":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        if not st:
            print("kein SDR-Status (DB/JSON)"); return 1
        if float(st.get("t") or 0) < t0:
            print("Status noch alt"); return 1
        du = st.get("dual") or {}
        if not du.get("reg"):
            print("Status ohne Geraete-Register (dual.reg)"); return 1
        dv = {x.get("role"): x for x in st.get("devs") or [] if isinstance(x, dict)}
        a1 = dv.get("11D") or {}
        dev = st.get("dev") or {}
        dm = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {}).get("demod") or {}
        m11 = dm.get("sn") == a1.get("serial") and float(dm.get("t") or 0) >= t0          # 11D-Messung nach dem Neustart vom Airspy
        ran = m11 or str(st.get("active") or "").startswith("dab")
        if not a1.get("present") or a1.get("state") != "aktiv" or not ran:
            print("Airspy 11D nicht aktiv (angesteckt %s, %s, jetzt %s, 11D-Messung %s SN %s, Fehler %s)" % (a1.get("present"), a1.get("state"), st.get("active"), dm.get("t"), dm.get("sn"), str(st.get("err") or st.get("pin_err") or "")[:120])); return 1
        cpu = (dev.get("cpu") or {})
        print("11D vom Airspy: %s · Geraete: %s · Airspy %s · welle-cli CPU %s" % ("Sync %s, SNR %s, %s" % (dm.get("sync"), dm.get("snr"), dm.get("gain_db")) if m11 else "laeuft (noch keine Messung)",", ".join("%s=%s(%s)" % (x.get("name"), x.get("role") or "ohne Rolle", x.get("state")) for x in st.get("devs") or []),
                                                          dev.get("fe"), ("%s %% (5 min Mittel %s %%)" % (cpu.get("pct"), cpu.get("avg"))) if cpu else "noch nicht gemessen"))
        return 0
    if m == "funk":
        h = rd(a[1])
        for k in ("var AIR=", "erkannt, ohne Rolle", "s2s.style.display=(D2&&D2.air)"):
            if k not in h:
                print("/funk ohne sdrAir-Anzeige (%s)" % k); return 1
        print("/funk mit sdrAir-Anzeige (Geraetenamen, ohne Rolle, kein Uebernahme-Knopf)"); return 0
    if m == "ui":
        u = (json.load(open(a[1], encoding="utf-8")).get("dual") or {})
        if not u.get("reg") or "Airspy" not in str(u.get("label1")):
            print("/api/sdr/ui ohne Geraete-Register (%s)" % str(u)[:160]); return 1
        print("/api/sdr/ui: %s · %s" % (u.get("label1"), u.get("mode"))); return 0
    if m == "t2":
        t = json.load(open(a[1], encoding="utf-8"))
        if not t.get("air") or (t.get("takeover") or {}).get("on"):
            print("/api/t2/status: air=%s Uebernahme an=%s" % (t.get("air"), (t.get("takeover") or {}).get("on"))); return 1
        print("/api/t2/status: Geraete-Register an, Uebernahme aus (%s)" % ((t.get("takeover") or {}).get("off_by") or "war aus")); return 0
    if m == "port":
        n = int(a[1])
        s = rd("/proc/net/tcp") + "\n" + rd("/proc/net/tcp6")
        if any(len(x.split()) > 3 and x.split()[1].endswith(":%04X" % n) and x.split()[3] == "0A" for x in s.splitlines()):
            print("Port %d lauscht" % n); return 0
        print("Port %d lauscht nicht" % n); return 1
    print(__doc__); return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AIC_EOF
EXPECT_AC2="8e93c983cca56d6a4149db1210c42fd9fb262be0ba597e707c49fb3b55e29c20"
cat > "$W/air2check.py" << 'AC2_EOF'
"""sdrAir2 Pruefungen fuer apply-sdrair2.sh (nur lesen). proof DIR T0 | api JSON | state DIR | hobby DIR"""
import json
import os
import re
import sys
import time

hm = lambda t: time.strftime("%d.%m. %H:%M:%S", time.localtime(t)) if isinstance(t, (int, float)) else "–"


def newest(d, name, key):
    """sqlC: Stand primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
    best = {}
    try:
        import sqlite3
        c = sqlite3.connect("file:%s?mode=ro" % os.path.join(d, "lagezentrum.db"), uri=True, timeout=10)
        try:
            r = c.execute("SELECT json FROM state WHERE key=?", (key,)).fetchone()
            best = json.loads(r[0]) if r else {}
        finally:
            c.close()
    except Exception:
        best = {}
    try:
        j = json.load(open(os.path.join(d, name), encoding="utf-8"))
        if not best or float(j.get("t") or 0) > float(best.get("t") or 0):
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def devs(d):
    try:
        c = json.load(open(os.path.join(d, "sdr_config.json"), encoding="utf-8"))
    except Exception:
        return {}
    return {str(x.get("serial") or "").upper(): x for x in c.get("devs") or [] if isinstance(x, dict) and c.get("devs_on") is True}


def main(a):
    m = a[0]
    if m == "proof":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        a1 = next((x for x in st.get("devs") or [] if isinstance(x, dict) and x.get("role") == "11D"), {})
        sn = str(a1.get("serial") or "")
        e = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {})
        dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
        dev = st.get("dev") or {}
        cpu = dev.get("cpu") or {}
        ok = bool(sn) and e.get("rx") is True and float(e.get("t") or 0) >= t0 and dm.get("sn") == sn and float(dm.get("t") or 0) >= t0
        if not ok:
            print("11D-Sync vom Airspy noch nicht nachgewiesen (Airspy SN %s, 11D Empfang %s um %s, Messung von SN %s um %s, seit Start %s)" % (
                sn or "?", e.get("rx"), hm(e.get("t")), dm.get("sn"), hm(dm.get("t")), hm(t0)))
            return 1
        print("11D-Sync vom Airspy nachgewiesen: Empfang %s, SNR %s, FIC-Fehlerrate %s · %s · welle-cli CPU %s" % (
            hm(e.get("t")), dm.get("snr"), dm.get("fic_rate"), dev.get("fe") or "?", cpu.get("txt") or "noch nicht gemessen"))
        return 0
    if m == "api":
        w = json.load(open(a[1], encoding="utf-8"))
        ss = w.get("sticks") or []
        assert w.get("lvl") in ("ok", "gelb", "rot", "grau") and ss, str(w)[:200]
        assert all(s.get("name") for s in ss), "Geraet ohne Namen: %s" % [s.get("sn") for s in ss if not s.get("name")]
        reg = any(s.get("role") for s in ss)
        assert reg, "keine Rollen in /api/sdr/wd (sdr_manager alt?)"
        assert w.get("txt") != "alle Sticks mit echtem Empfang", "alte Sammelzeile"
        hb = [s for s in ss if s.get("watch")]
        assert all(s.get("role") == "hobby" for s in hb) and (not hb or isinstance(w.get("hobby"), dict)), "Hobby-Zeile fehlt"
        if w["lvl"] == "ok":
            assert not [s for s in ss if not s.get("watch") and not s.get("absent") and s.get("lvl") != "ok"], "Gesamt ok trotz ungepruefter Geraete"
        print("/api/sdr/wd (sdrAir2): %s · %s · %s" % (w["lvl"], (w.get("short") or w.get("txt") or "")[:140], " | ".join(
            "%s %s%s" % (s["name"], s.get("lvl"), " (Hobby, nur Beobachtung)" if s.get("watch") else "") for s in ss)))
        return 0
    if m in ("state", "hobby"):
        d = a[1]
        f = os.path.join(d, "sdr_wd.json")
        if not os.path.exists(f):
            print("sdr_wd.json: noch nicht vorhanden"); return 0 if m == "state" else 1
        w = json.load(open(f, encoding="utf-8"))
        dv = devs(d)
        out, bad = [], []
        for sn, v in sorted((w.get("sticks") or {}).items()):
            x = dv.get(sn.upper()) or {}
            nm = "%s%s" % (x.get("name") or "Gerät ohne Rolle", " (Hobby)" if x.get("role") == "hobby" else "")
            i = v.get("inc")
            if not i:
                out.append("%s SN %s ok" % (nm, sn))
            else:
                out.append("%s SN %s Vorfall %s seit %s%s" % (nm, sn, i.get("ch") or "?", hm(i.get("since")), (", nur Beobachtung" if x.get("role") == "hobby" else
                                                                                                                 ", Neustart %s, USB %s" % (i.get("restart_n", 0), i.get("usb_n", 0)))))
                if x.get("role") == "hobby" and (i.get("ch") != "RDS" or i.get("restart_n") or i.get("usb_n")):
                    bad.append(sn)
        if m == "hobby":
            if bad:
                print("Hobby-Vorfall alter Art noch offen: %s" % ", ".join(bad)); return 1
            print("Hobby: kein alter Vorfall offen (%s)" % "; ".join(o for o in out if "(Hobby)" in o)); return 0
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(w.get("reboots") or []), w.get("reboot_fail_n") or 0))
        return 0
    if m == "namestest":                               # Pruefung der Pruefung: echte HB-Beispieltexte duerfen nicht anschlagen, echte Platz-Namen schon
        return names_selftest()
    if m == "names":                                   # names DIR: gespeicherte Seiten/APIs (p_*.html / p_*.json) auf alte Platz-Namen pruefen
        return names_check(a[1])
    print("unbekannt"); return 2


SLOT_RE = re.compile(r"(\bSDR ?[123]\b|\bStick [1-9]\b(?! · (?:11D|5C|Hobby|ohne Rolle)\b))")
NAME_KEYS = ("name", "model", "dev_name", "name1", "name2", "name3", "names", "1", "2", "3", "label_plain")
SKIP_KEYS = ("hist", "ev", "events", "fig", "log", "techlog", "boot_msgs", "last_inc", "inc", "msgs", "err")
TS_RE = re.compile(r"^(\d\d\.\d\d\.( \d\d:\d\d)?|\d\d:\d\d)\b")
HB_RE = re.compile(r"\bHB \d\d:\d\d\b")                # schon gesendete Heartbeat-Texte ('HB 06:02 | Lage OK | ASA OK | SDR2 5C | ...'): Verlauf, keine Live-Anzeige


def _walk(o, path, out):
    if isinstance(o, dict):
        for k, v in o.items():
            k = str(k)
            if k in SKIP_KEYS:
                continue
            if k in NAME_KEYS and isinstance(v, str):
                continue
            _walk(v, path + "." + k, out)
    elif isinstance(o, list):
        for i, v in enumerate(o[:200]):
            _walk(v, "%s[%d]" % (path, i), out)
    elif isinstance(o, str) and SLOT_RE.search(o) and not TS_RE.match(o) and not HB_RE.search(o):
        out.append("%s = %s" % (path, o[:160]))


def names_check(d):
    import glob
    import html as H
    bad = []
    n = 0
    for f in sorted(glob.glob(os.path.join(d, "p_*"))):
        n += 1
        s = open(f, encoding="utf-8", errors="replace").read()
        b = os.path.basename(f)
        if b.endswith(".json"):
            try:
                j = json.loads(s)
            except Exception:
                bad.append("%s: kein JSON" % b)
                continue
            out = []
            _walk(j, "", out)
            bad += ["%s %s" % (b, x) for x in out]
            continue
        s = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", s)
        for t in (H.unescape(x).strip() for x in re.sub(r"(?s)<[^>]+>", "\n", s).split("\n")):
            if not t or TS_RE.match(t) or HB_RE.search(t) or not SLOT_RE.search(t):
                continue
            if "dabhist" in b and not re.fullmatch(r"(Stick [1-9]|SDR ?[123])", t):
                continue                               # /dabhist: Meldungs-Texte sind Verlauf; nur Quell-Etiketten pruefen
            bad.append("%s: %s" % (b, t[:160]))
    if not n:
        print("keine Seiten gespeichert"); return 1
    if bad:
        print("alte Platz-Namen (Stick N/SDR N ohne Rolle) in %d Stellen: %s" % (len(bad), " | ".join(bad[:12]))); return 1
    print("Anzeige-Namen: %d Seiten/APIs ohne alte Platz-Namen (Stick N / SDR N nur als 'Name · Rolle'; Verlauf ausgenommen)" % n)
    return 0


def names_selftest():
    import tempfile
    hb = "HB 06:02 | Lage OK | ASA OK | SDR2 5C | Wetter 12°C 8/15° Sonne 2.1h | Uplink Telekom | 50.01 Hz"
    hb2 = "HB 03:02 | Lage OK | ASA OK | SDR2 frei | Wetter 9°C"
    d = tempfile.mkdtemp(prefix="names-")
    w = lambda n, t: open(os.path.join(d, n), "w", encoding="utf-8").write(t)
    w("p_x_mesh.html", "<html><body><div class='m'>%s</div><div>%s</div><p>Stick 1 · 5C fest</p><p>Stick 2 · Hobby</p></body></html>" % (hb, hb2))
    w("p_x_api_t4_status.json", json.dumps({"hb": {"last": {"text": hb2, "t": 1}, "n": 3}, "sdr": {"s1": {"name": "Airspy R2 · 11D"}, "s2": {"name": "Stick 1 · 5C"}}}))
    if names_check(d) != 0:
        print("Namens-Pruefung schlaegt bei gesendeten HB-Texten an"); return 1
    for n, t in (("p_x_mesh.html", "<html><body><p>Lage: SDR 2 auf 5C gekapert</p></body></html>"), ("p_x_api_t4_status.json", json.dumps({"s2": {"state": "Stick 2 wartet"}}))):
        d2 = tempfile.mkdtemp(prefix="names-")
        open(os.path.join(d2, n), "w", encoding="utf-8").write(t)
        if names_check(d2) == 0:
            print("Namens-Pruefung uebersieht Platz-Namen in %s" % n); return 1
    print("OK Namens-Pruefung getestet: gesendete HB-Texte (SDR2 5C / SDR2 frei) in /mesh und .hb.last.text zaehlen nicht, Live-Platz-Namen schon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AC2_EOF
EXPECT_ACK="885f6401a7cd359a08624c090f05675e1239ea36b956b01158be60015a97026f"
cat > "$W/atcheck.py" << 'ACK_EOF'
"""Pruefhilfe airTest (nur lesen). atcheck.py api JSON_DATEI | page HTML_DATEI | state DASH_DIR"""
import json
import os
import re
import sys

STATES = ("idle", "running", "done", "aborted", "unklar")


def main(a):
    m = a[0] if a else ""
    if m == "api":
        try:
            j = json.load(open(a[1], encoding="utf-8"))
        except Exception as e:
            print("kein JSON: %s" % e); return 1
        if not (isinstance(j, dict) and j.get("ok") is True and j.get("state") in STATES and j.get("levels") == [12, 19, 21] and j.get("rounds") == 5 and j.get("txt") and isinstance(j.get("rows"), list)
                and j.get("limit_min") == 40 and j.get("dev")):
            print("/api/sdr/airtest unvollstaendig: %s" % json.dumps(j, ensure_ascii=False)[:240]); return 1
        if j.get("running"):
            print("HINWEIS: ein Gain-Test laeuft gerade (state running) - nicht vom Apply gestartet")
        print("/api/sdr/airtest: %s (Geraet %s, Stufen 12/19/21, je 5 Runden, Zeitlimit 40 min)" % (j["txt"], j["dev"])); return 0
    if m == "page":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        if s.count('id="airtest-js"') != 1 or s.count('id="at-data"') != 1 or s.count('id="airtest-css"') != 1:
            print("/funk: airTest-Bloecke js %dx, daten %dx, css %dx" % (s.count('id="airtest-js"'), s.count('id="at-data"'), s.count('id="airtest-css"'))); return 1
        mm = re.search(r'id="at-data">(.*?)</script>', s, re.S)
        try:
            j = json.loads(mm.group(1))
        except Exception as e:
            print("/funk: at-data kein JSON: %s" % e); return 1
        js = s[s.index('id="airtest-js"'):]
        for k in ("/api/sdr/airtest", "window.confirm", "Gain-Test starten", "Standard-Gain wird nie"):
            if k not in js:
                print("/funk: JS ohne %s" % k); return 1
        if j.get("ok") is not True or j.get("state") not in STATES:
            print("/funk: at-data unvollstaendig"); return 1
        print("/funk: Karte Gain-Test (Daten state %s, Knopf mit Rueckfrage, Standard-Gain bleibt)" % j["state"]); return 0
    if m == "state":
        p = os.path.join(a[1], "sdr_airtest.json")
        if not os.path.isfile(p):
            print("sdr_airtest.json noch nicht da (noch nie ein Test - normal)"); return 0
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as e:
            print("sdr_airtest.json kaputt: %s" % e); return 1
        if not isinstance(d, dict) or d.get("state") not in STATES:
            print("sdr_airtest.json: state %r" % (d.get("state") if isinstance(d, dict) else d)); return 1
        print("sdr_airtest.json: state %s, %d Messungen" % (d["state"], len(d.get("samples") or []))); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
ACK_EOF
EXPECT_FC="d570fbd0611aa288a86ac193f77a931efc373d5b1a2ce779416b2a06c9d446ba"
cat > "$W/fucheck.py" << 'WDF_EOF'
"""Pruefhilfen sdrLog/funkUI (nur lesen). fucheck.py funk|dabhist|meteor DATEI [W] | thumb BASIS | live DATEI | techlog BASIS | pil"""
import json, os, re, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="funkui-js"', 'id="funkui-css"', 'id="fu-meteor"', "#t2Tile,#t4Sdr{display:none", 'id="t4-data"', 'id="t2-data"', 'id="sdrui-data"', 'id="stickTestCard"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="funkui-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "funkui.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    import shutil
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: JavaScript fehlerhaft")
    print("/funk: Funk-Lage, Steuerung, Meteor-Kachel eingehaengt (1x), alte Kacheln Sticks/SDR-Status verborgen, Antennentest vorhanden")
elif a == "dabhist":
    s = rd(sys.argv[2])
    assert "fu-chips" in s and "<table" not in s and "Programm-Infos" in s and "Grenzwerte" in s, "/dabhist ohne Karten/Filter"
    print("/dabhist: Karten, 44-px-Filter (Programm-Infos aus), %d Eintraege angezeigt" % s.count('class="fu-ev '))
elif a == "meteor":
    s = rd(sys.argv[2])
    assert "fu-wrap" in s and "Überflüge" in s and "<table" not in s, "/meteor ohne neue Seite"
    print("/meteor: Karten-Seite, %d Bilder, %d Vorschau-Verweise" % (s.count('class="fu-th"'), s.count("/meteor/thumb/")))
elif a == "thumb":
    d = os.path.join(sys.argv[2], "meteor")
    r = re.compile(r"^[0-9]{8}-[0-9]{4}_[A-Za-z0-9]{1,8}_[A-Za-z0-9_-]{1,40}\.(jpg|png)$")
    fs = sorted((f for f in os.listdir(d) if r.match(f)), reverse=True) if os.path.isdir(d) else []
    print(fs[0] if fs else "")
elif a == "live":
    d = json.load(open(sys.argv[2]))
    w = d.get("watchdog") or {}
    print("/api/sdr/live: Status %s, Lebenszeichen %s%s" % (d.get("status"), w.get("src") or "DB", (" (%s)" % w.get("note_mem")) if w.get("note_mem") else ""))
elif a == "techlog":
    try:
        d = json.load(open(os.path.join(sys.argv[2], "sdr_techlog.json")))
        ev = d.get("ev") or []
        print("sdr_techlog.json: %d Eintraege%s" % (len(ev), (", zuletzt %s: %s" % (time.strftime("%d.%m. %H:%M", time.localtime(ev[-1]["t"])), str(ev[-1].get("text"))[:120])) if ev else ""))
    except FileNotFoundError:
        print("sdr_techlog.json: noch nicht vorhanden (entsteht beim ersten Technik-Ereignis)")
elif a == "pil":
    for py in sys.argv[2:]:
        r = subprocess.run([py, "-c", "import PIL; print(PIL.__version__)"], capture_output=True, text=True)
        print("  %s: PIL %s" % (py, r.stdout.strip() if r.returncode == 0 else "fehlt (Vorschaubilder aus, Seite zeigt Originale)"))
WDF_EOF
EXPECT_WC="5641abe55b10e371b440b0ff9b2a590041113b29ab490d3c8951264d0469d3bc"
cat > "$W/wdcheck.py" << 'WDK_EOF'
"""Pruefhilfen sdrWd (nur lesen). wdcheck.py helper DATEI | funk DATEI W | pi DATEI | api DATEI | state BASIS | sudoers DATEI NUTZER HELFER | masts DATEI N11 N5C N10C | tii DATEI | cfg BASIS | br24 DATEI"""
import ast, json, os, re, shutil, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "helper":
    s = rd(sys.argv[2])
    t = ast.parse(s)
    assert s.startswith("#!/usr/bin/python3 -I\n"), "Shebang"
    mods = {x.name.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.Import) for x in n.names} | {n.module.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.ImportFrom)}
    assert mods <= {"fcntl", "json", "os", "re", "stat", "subprocess", "sys", "syslog", "time", "tempfile"}, mods
    calls = [n for n in ast.walk(t) if isinstance(n, ast.Call)]
    nm = lambda f: f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
    bad = [nm(c.func) for c in calls if nm(c.func) in ("system", "popen", "Popen", "execv", "execvp", "check_output", "call", "spawn", "fork", "eval", "exec")]
    assert not bad, bad
    assert s.count("subprocess.run") == 1 and s.count("(run or subprocess.run)([sc, \"reboot\"]") == 1, "nur systemctl reboot"
    body = s.split('"""', 2)[2]
    for k in ("uhubctl", "unbind", "power/control", "bind_ports"):
        assert k not in body, k
    assert 'VIDPID = ("0bda", "2838")' in s and 'SN_RE = re.compile(r"^[0-9]{8}$")' in s and '== "09"' in s and "USBDEVFS_RESET = 0x5514" in s
    assert 'AIR_VIDPID = ("1d50", "60a1")' in s and 'AIR_SN_RE = re.compile(r"^[0-9A-F]{16}$")' in s
    print("Hilfsprogramm: nur 0bda:2838 mit 8-stelliger bzw. Airspy 1d50:60a1 mit 16-stelliger Hex-Seriennummer (keine Hubs/Interfaces), einziger Prozess systemctl reboot (gesperrt: 1 je 55 min, 6 je 24 h), kein uhubctl/Portstrom/unbind")
elif a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="sdrwd-js"', 'id="sdrwd-css"', 'id="wd-data"', 'id="funkui-js"', 'id="dh-js"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "sdrwd.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: sdrWd-JavaScript fehlerhaft")
    w = json.loads(re.search(r'<script type="application/json" id="wd-data">(.*?)</script>', s, re.S).group(1))
    assert "function rel(t)" in s and "x.title=full(r)" in s, "/funk: Empfaenger-Zeilen alt"
    print("/funk: Daten-Watchdog in Funk-Lage (%s: %s), Empfänger-Zeilen einzeilig, JS geprüft" % (w.get("lvl"), (w.get("short") or w.get("txt") or "")[:90]))
elif a == "pi":
    s = rd(sys.argv[2])
    i, j = s.find('id="wdPiBox"'), s.find('id="backupBox"')
    assert s.count('id="wdPiBox"') == 1 and 0 <= i < j, "/pi: Watchdog-Kachel fehlt oder nicht vor Sicherung"
    k = s.rfind("doPrepperRestore")
    last = k < 0 or (s.find('class="tile', max(k, j)) < 0 and s.find('class="card', j + 10) < 0)
    assert last, "/pi: Sicherung nicht mehr letzte Kachel"
    m = re.search(r'Pi-Neustarts heute: [0-9]+ · zuletzt [^<]*', s)
    print("/pi: Watchdog-Kachel vor Sicherung, Sicherung letzte Kachel; %s" % (m.group(0) if m else "?"))
elif a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and "reboot_line" in d, d
    print("/api/sdr/wd: %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:100], d.get("reboot_line")))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden (entsteht mit der ersten Prüfung)")
    else:
        d = json.load(open(f))
        st = d.get("sticks") or {}
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join("Stick %s SN %s %s" % (v.get("n"), k, ("Vorfall seit %s" % time.strftime("%d.%m. %H:%M", time.localtime(v["inc"]["since"]))) if v.get("inc") else "ok")
                                                                                     for k, v in sorted(st.items())) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "sudoers":
    f, u, h = sys.argv[2:5]
    s = rd(f)
    exp = "%s ALL=(root) NOPASSWD: %s check, %s usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], %s usb-reset-air %s, %s reboot\n" % (u, h, h, h, "[0-9A-F]" * 16, h)
    lines = [x for x in s.splitlines(True) if not x.startswith("#")]
    assert lines == [exp], (lines, exp)
    print("sudoers: genau eine Regel fuer %s: %s check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot" % (u, h))
elif a == "masts":
    d = json.load(open(sys.argv[2]))
    ms = d.get("masts") or {}
    want = dict(zip(("11D", "5C", "10C"), map(int, sys.argv[3:6])))
    got = {ch: len((ms.get(ch) or {}).get("tii") or []) for ch in want}
    if got != want:
        raise SystemExit("MASTS_DB noch nicht gemeldet: %s statt %s" % (got, want))
    nm = {}
    for ch, m in ms.items():
        for x in (m or {}).get("tii") or []:
            nm["%s %02d/%02d" % (ch, x["main"], x["sub"])] = x.get("mast")
    assert nm.get("11D 08/18") == nm.get("5C 12/11") == "Bamberg (Geisberg)" and nm.get("10C 07/01") == nm.get("11D 05/14") == "Nürnberg (Schweinau)", nm
    print("/api/t2/status MASTS_DB: 11D %(11D)d, 5C %(5C)d, 10C %(10C)d Sender (Namen je Standort gleich, z. B. 08/18 = 12/11 = Bamberg (Geisberg))" % got)
elif a == "tii":
    d = json.load(open(sys.argv[2]))
    assert d.get("ok") is not False and isinstance(d.get("masts"), list), str(d)[:200]
    n = {}
    for m in d["masts"]:
        for c in m.get("ch") or []:
            n[c.get("ch")] = n.get(c.get("ch"), 0) + 1
    print("/api/t4/tii Karte: %d Standorte mit Position, %d ohne; Kennungen je Kanal %s" % (len(d["masts"]), len(d.get("nopos") or []), ", ".join("%s %d" % kv for kv in sorted(n.items()))))
elif a == "cfg":
    D = {"wd_enable": True, "wd_yellow_min": 10, "wd_restart_min": 30, "wd_usb_min": 45, "wd_reboot_min": 60, "wd_reboot_min_interval_min": 60, "wd_reboot_max_fail": 3, "wd_usb_max": 2}
    try:
        c = json.load(open(os.path.join(sys.argv[2], "sdr_config.json")))
    except Exception:
        c = {}
    out = []
    for k, v in D.items():
        x = c.get(k, v) if isinstance(c, dict) else v
        out.append("%s=%s%s" % (k, ("an" if x else "aus") if k == "wd_enable" else x, "" if not isinstance(c, dict) or k not in c else " (gesetzt)"))
    print(" ".join(out))
elif a == "br24":
    d = json.load(open(sys.argv[2]))
    t = str(d.get("bc_note") or "")
    assert "abwechselnd" not in t and "Stick 1" in t, t
    print("/api/br24 Hinweis: %s" % t[:160])
WDK_EOF
EXPECT_WC2="fb2b6f1de50294433e16c3d52fd9f20ac4771bfd55bed95782a61a16cc09432f"
cat > "$W/wdcheck2.py" << 'WDK2_EOF'
"""Pruefhilfen sdrWd2 (nur lesen). wdcheck2.py api DATEI | state BASIS | dashok DASHBOARD BLOCK | funk HTML"""
import json, os, re, sys, time
a = sys.argv[1]
hm = lambda t: time.strftime("%d.%m. %H:%M", time.localtime(t)) if isinstance(t, (int, float)) else "–"
if a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and isinstance(d.get("sticks"), list), str(d)[:200]
    for s in d["sticks"]:
        assert all(k in s for k in ("short", "pre", "to")), "Stick %s ohne sdrWd2-Felder (short/pre/to): sdr_manager alt?" % s.get("n")
    print("/api/sdr/wd (sdrWd2): %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:110], " | ".join(
        "Stick %s %s%s%s" % (s.get("n"), s.get("lvl"), " Übernahme" if s.get("to") else "", " vor Start" if s.get("pre") else "") for s in d["sticks"])))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden"); raise SystemExit(0)
    d = json.load(open(f))
    out = []
    for sn, v in sorted((d.get("sticks") or {}).items()):
        i = v.get("inc")
        if not i:
            out.append("Stick %s SN %s ok" % (v.get("n"), sn)); continue
        out.append("Stick %s SN %s Vorfall %s seit %s%s%s, Eskalation ab %s, Neustart %s, USB %s%s" % (
            v.get("n"), sn, i.get("ch") or "?", hm(i.get("since")), " (vor Start)" if i.get("pre") else "", " Übernahme" if i.get("to") else "", hm(i.get("t0")),
            i.get("restart_n", 0), i.get("usb_n", 0), (" · 10C %s" % ("ok " + hm(i.get("fb_ok_t")) if i.get("fb_ok") else "ohne Sync")) if i.get("fb_t") else ""))
    print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "dashok":
    s = open(sys.argv[2], encoding="utf-8").read()
    def lit(name):
        i = s.index(name + ' = r"""') + len(name + ' = r"""')
        return s[i:s.index('"""', i)]
    g = {"_WD_CSS": lit("_WD_CSS"), "_WD_JS": lit("_WD_JS")}
    exec(compile(open(sys.argv[3], encoding="utf-8").read(), "wd2_dash_block", "exec"), g)
    assert g["_wd2_dash_ok"](), "sdrWd2-Anzeige fehlt in _WD_CSS/_WD_JS"
    assert s.count("# ===== sdrWd2:") == 1 and s.index("# ===== sdrWd2:") < s.index("# ===== sdrWd:"), "Block-Reihenfolge"
    print("dashboard.py sdrWd2: Watchdog-Zeilen einzeilig (CSS), Kopfzeile immer, Tooltip/aufklappbar (JS), kein POST")
elif a == "funk":
    s = open(sys.argv[2], encoding="utf-8", errors="replace").read()
    css = re.search(r'<style id="sdrwd-css">(.*?)</style>', s, re.S).group(1)
    js = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S).group(1)
    assert "/* sdrWd2: Watchdog-Zeilen einzeilig */" in css and "height:1.35em;white-space:nowrap" in css and "function fx(r,k,t)" in js, "/funk: Watchdog-Zeilen alt"
    print("/funk: Watchdog-Zeilen einzeilig (feste Höhe, Kurztext mit …, voller Text per Tipp)")
WDK2_EOF
PF="$W/patch-fu.py"; RED="$W/ag_edits.py"; RSM="$W/ag_sm_block.py"; RSD="$W/ag_sdr_block.py"; RDH="$W/ag_dash_block.py"; RGD="$W/guard_autogain.py"; AGC="$W/agcheck.py"; PCK="$W/pdcheck.py"; RPD="$W/prepper_docs.py"
AC="$W/aircheck.py"; AC2="$W/air2check.py"; ACK="$W/atcheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"
for x in "$EXPECT_PF $PF" "$EXPECT_AE $RED" "$EXPECT_ASM $RSM" "$EXPECT_ASD $RSD" "$EXPECT_ADH $RDH" "$EXPECT_AGD $RGD" "$EXPECT_AGC $AGC" "$EXPECT_APC $PCK" "$EXPECT_APD $RPD" "$EXPECT_AC $AC" "$EXPECT_AC2 $AC2" "$EXPECT_ACK $ACK" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
for x in "$F" "$PD" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); PD0=$(s16 "$PD"); SM16=$(s16 "$SMF"); SDR16=$(s16 "$M"); DB16=$(s16 "$DBF"); MR16=$(s16 "$MR")
LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt ); CF16=$( [[ -f "$CF" ]] && s16 "$CF" || echo fehlt )
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "meshPost, Basis" "$KNOWN_D16N" "autoGain schon drin" "$KNOWN_D16PD" "nur projDoc - meshPost fehlt"))"
echo "Basis prepper_docs.py sha16 $PD0 ($(wc -l < "$PD") Zeilen, $(lbl "$PD0" "$KNOWN_PD16" "meshPost, Basis" "$KNOWN_PD16A" "meshPost erste Fassung, Basis" "$KNOWN_PD16N" "autoGain schon drin" "$KNOWN_PD16PD" "nur projDoc - meshPost fehlt"))"
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(lbl "$SDR16" "$KNOWN_SDR16" "sdrFall, Basis" "$KNOWN_SDR16N" "autoGain schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(lbl "$SM16" "$KNOWN_SM16" "Basis" "$KNOWN_SM16N" "autoGain schon drin"))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
if [[ "$D16" == "$KNOWN_D16PD" || "$PD0" == "$KNOWN_PD16PD" ]] || ! grep -q '# ===== meshPost:' "$F"; then
  echo "STOP: meshPost ist auf diesem Pi noch nicht installiert (dashboard.py sha16 $D16, prepper_docs.py sha16 $PD0 = Stand projDoc bzw. ohne Block meshPost) - nichts geaendert."
  echo "      autoGain baut auf dem Stand nach meshPost auf. Zuerst: bash /tmp/apply-meshpost.sh commit14 (danach dieses Skript erneut)."
  exit 1
fi
bad=""
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 = meshPost oder $KNOWN_D16N = autoGain);"
[[ "$PD0" == "$KNOWN_PD16" || "$PD0" == "$KNOWN_PD16A" || "$PD0" == "$KNOWN_PD16N" ]] || bad="$bad prepper_docs.py (sha16 $PD0, erwartet $KNOWN_PD16 = meshPost oder $KNOWN_PD16N = autoGain);"
[[ "$SDR16" == "$KNOWN_SDR16" || "$SDR16" == "$KNOWN_SDR16N" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16 = sdrFall oder $KNOWN_SDR16N = autoGain);"
[[ "$SM16" == "$KNOWN_SM16" || "$SM16" == "$KNOWN_SM16N" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16 oder $KNOWN_SM16N = autoGain);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      autoGain passt nur auf den Stand nach meshPost und sdrFall (dashboard $KNOWN_D16, prepper_docs $KNOWN_PD16, prepper_sdr $KNOWN_SDR16, sdr_manager $KNOWN_SM16) - nichts geaendert. Lokale Aenderungen oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = meshPost + sdrFall (bzw. autoGain schon drin), alle sha16 bekannt"
if [[ "$CF16" == "$KNOWN_CF16" ]]; then echo "OK sdr_config.json sha16 $CF16 (bleibt)"
else echo "HINWEIS sdr_config.json sha16 $CF16 statt $KNOWN_CF16 (andere Arbeitsschritte koennen die Konfiguration angepasst haben, z. B. Stick 3) - autoGain fasst die Datei nicht an"; fi
grep -q '# ===== sdrFall:' "$M" || stop "sdrFall fehlt in prepper_sdr.py (Basis)"
grep -q '# ===== airTest:' "$M" && grep -q '# ===== sdrHalt:' "$M" && grep -q '# ===== airTest:' "$SMF" && grep -q '# ===== airTest:' "$F" || stop "airTest/sdrHalt fehlt (Basis)"
grep -q '# ===== sdrRest2:' "$M" && grep -q '# ===== sdrRest2:' "$SMF" && grep -q '# ===== sdrStick3:' "$M" || stop "sdrRest2/sdrStick3 fehlt (Basis)"
grep -q '# ===== projDoc:' "$F" && grep -q '# ===== piPolish2:' "$F" || stop "projDoc/piPolish2 fehlt im Dashboard (Basis)"
[[ -x "$HDST" ]] || stop "Hilfsprogramm $HDST fehlt oder nicht ausfuehrbar"
HL16=$(s16 "$HDST")
[[ "$HL16" == "$KNOWN_HL16" ]] || stop "Hilfsprogramm sha16 $HL16 statt $KNOWN_HL16 (sdrAir)"
echo "OK Hilfsprogramm $HDST sha16 $HL16 (sdrAir, bleibt)"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || stop "Dienst $u ist nicht aktiv ($a)"
done
SDR_AET0=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
DASH_AET0=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
AIRSN=$(python3 "$AC" airspy "$SYSUSB" 2>"$W/air.log") || { echo "$AIRSN"; cat "$W/air.log"; stop "Airspy nicht eindeutig gefunden (Stick eingesteckt?)"; }
[[ "$AIRSN" =~ ^[0-9A-F]{16}$ ]] || stop "Airspy-Seriennummer unklar ($AIRSN)"
echo "OK $(cat "$W/air.log")"
GAIN0=$(python3 "$AGC" gain "$DASH_DIR" 2>/dev/null || echo "?")
echo "Gain des Airspy vor der Installation (laut broadcast_state.json): Stufe $GAIN0 - wird durch die Installation nicht veraendert"
# ---------- 1b) sudo-Regel pruefen (nur lesen/check, ohne gemerktes Passwort) ----------
SU=$(systemctl show -p User --value prepper-sdr 2>/dev/null || true); [[ -z "$SU" ]] && SU=root
if ! [[ "$SU" =~ ^[a-z_][a-z0-9_-]*$ ]]; then stop "Benutzer von prepper-sdr unklar ($SU)"; fi
asu() { if [[ "$(id -un)" == "$SU" ]]; then setsid -w "$@" < /dev/null; else sudo -n -u "$SU" setsid -w "$@" < /dev/null; fi; }
slist() { if [[ "$(id -un)" == "$SU" ]]; then sudo -n -l "$@"; else sudo -n -l -U "$SU" "$@"; fi; }
WD_SUDO_ERR=""; WD_SUDO_OK=""
wd_sudo_verify() {
  local c out rc
  for c in "check" "usb-reset 19348831" "usb-reset-air $AIRSN" "reboot"; do
    rc=0; slist "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?
    [[ "$rc" == 0 ]] || { WD_SUDO_ERR="sudo -l: $HDST $c fuer $SU nicht erlaubt (rc $rc: $(head -c 200 "$W/sl.log" | tr '\n' ' '))"; return 1; }
  done
  rc=0; out=$(asu sudo -k -n "$HDST" check 2>&1) || rc=$?
  [[ "$rc" == 0 && "$out" == *"bereit (uid 0)"* ]] || { WD_SUDO_ERR="$SU kann $HDST check nicht ohne Passwort und ohne Terminal ausfuehren (rc $rc: $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200))"; return 1; }
  rc=0; asu sudo -k -n true > /dev/null 2>&1 || rc=$?
  slist > "$W/slall.log" 2>&1 || true
  if [[ "$rc" == 0 ]] && grep -qE 'NOPASSWD: *ALL *$' "$W/slall.log"; then
    WD_SUDO_OK="$HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot ohne Passwort geprueft (sudo -k, ohne Terminal); Hinweis: $SU hat laut sudo -l NOPASSWD: ALL - Gegenprobe entfaellt"; return 0
  fi
  for c in "selftest" "usb-reset 1234" "usb-reset 19348831 x" "usb-reset ../x" "usb-reset-air 1234" "usb-reset-air ${AIRSN,,}" "usb-reset-air $AIRSN x" "usb-reset-air ../x"; do
    rc=0; out=$(asu sudo -k -n "$HDST" $c 2>&1) || rc=$?
    [[ "$rc" != 0 && "$out" == sudo:* ]] || { WD_SUDO_ERR="sudo erlaubt zu viel ohne Passwort: $HDST $c (rc $rc)"; return 1; }
  done
  WD_SUDO_OK="nur $HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex gross> | reboot ohne Passwort (sudo -k, ohne Terminal wie im Dienst), andere Aufrufe verlangen Passwort; allgemeines sudo verlangt Passwort"
}
if [[ "$SU" != root ]]; then
  wd_sudo_verify || stop "sudo-Regel: $WD_SUDO_ERR"
  echo "OK sudo-Regel fuer $SU: $WD_SUDO_OK"
fi
# ---------- 2) Trockenlauf (alles auf Kopien in $W; nichts installiert, nichts gesendet) ----------
cp "$M" "$W/work/prepper_sdr.base.cur"; cp "$SMF" "$W/work/sdr_manager.base.cur"; cp "$F" "$W/work/dashboard.base.cur"
python3 "$PF" autoGain sdr "$M" "$W/work/prepper_sdr.py" "$RSD" "$RED" > "$W/q_sdr.log" || { cat "$W/q_sdr.log"; stop "prepper_sdr.py: Stelle fuer die autoGain-Stufe nicht eindeutig (Datei vom Standard abweichend)"; }
python3 "$PF" autoGain sm "$SMF" "$W/work/sdr_manager.py" "$RSM" "$RED" > "$W/q_sm.log" || { cat "$W/q_sm.log"; stop "sdr_manager.py: Stelle fuer die autoGain-Stufe nicht eindeutig (Datei vom Standard abweichend)"; }
python3 "$PF" autoGain dsh "$F" "$W/work/dashboard.py" "$RDH" "$RED" > "$W/q_dsh.log" || { cat "$W/q_dsh.log"; stop "dashboard.py: Stelle fuer die autoGain-Stufe nicht eindeutig (Datei vom Standard abweichend)"; }
NP16=$(s16 "$W/work/prepper_sdr.py"); NS16=$(s16 "$W/work/sdr_manager.py"); ND16=$(s16 "$W/work/dashboard.py"); NPD16=$(s16 "$RPD")
[[ "$NP16" == "$KNOWN_SDR16N" && "$NS16" == "$KNOWN_SM16N" && "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis prepper_sdr.py $NP16 / sdr_manager.py $NS16 / dashboard.py $ND16 statt $KNOWN_SDR16N / $KNOWN_SM16N / $KNOWN_D16N (Zielstand nicht erreicht)"
[[ "$NPD16" == "$KNOWN_PD16N" ]] || stop "eingebettete prepper_docs.py sha16 $NPD16 statt $KNOWN_PD16N"
echo "OK Ergebnis wie erwartet: prepper_sdr.py $NP16 ($(wc -l < "$W/work/prepper_sdr.py") Zeilen, $(cat "$W/q_sdr.log")), sdr_manager.py $NS16 ($(wc -l < "$W/work/sdr_manager.py") Zeilen, $(cat "$W/q_sm.log")), dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q_dsh.log")), prepper_docs.py $NPD16 ($(wc -l < "$RPD") Zeilen)"
python3 "$PF" autoGain sdr "$W/work/prepper_sdr.py" "$W/work/x1.py" "$RSD" "$RED" > /dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/x1.py" || stop "prepper_sdr.py nicht idempotent (zweite Anwendung aendert die Datei)"
python3 "$PF" autoGain sm "$W/work/sdr_manager.py" "$W/work/x2.py" "$RSM" "$RED" > /dev/null && cmp -s "$W/work/sdr_manager.py" "$W/work/x2.py" || stop "sdr_manager.py nicht idempotent (zweite Anwendung aendert die Datei)"
python3 "$PF" autoGain dsh "$W/work/dashboard.py" "$W/work/x3.py" "$RDH" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x3.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x1.py" "$W/work/x2.py" "$W/work/x3.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/work/dashboard.py" "$RPD" "$RGD" "$AGC" "$PCK" "$RED" "$RSM" "$RSD" "$RDH"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (3 Programmdateien, prepper_docs.py, Bloecke, Pruefprogramme; $SPY und $VPY)"
# Sandbox: Kopie der Programmdateien (ohne config.py), neue Dateien darin; Selbsttests und Guard laufen nur hier
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$LG" ]] && cp "$LG" "$W/sbx/"
cp "$DBF" "$MR" "$W/sbx/"
cp "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/work/dashboard.py" "$W/sbx/"
python3 "$AGC" tamper > "$W/pt0.log" 2>&1 || { tail -5 "$W/pt0.log"; stop "Pruefprogramm agcheck: Selbsttest meldet Fehler"; }
tail -1 "$W/pt0.log" | cut -c1-200
python3 "$PCK" tamper > "$W/pt1.log" 2>&1 || { tail -5 "$W/pt1.log"; stop "Pruefprogramm pdcheck: Selbsttest meldet Fehler"; }
tail -1 "$W/pt1.log" | cut -c1-200
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/autogain-selftest timeout 300 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; stop "Selbsttest sdr_manager ($py) fehlgeschlagen"; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok" "sdr_manager selftest sdrWd ok" "sdr_manager selftest sdrWd2 ok" "sdr_manager selftest sdrAir ok" "sdr_manager selftest sdrAir2 ok" "sdr_manager selftest dabSql ok" "sdr_manager selftest airTest ok" "sdr_manager selftest sdrRest ok" "sdr_manager selftest sdrRest2 ok" "sdr_manager selftest autoGain ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; stop "Selbsttest sdr_manager ohne Zeile '$k' ($py)"; }
  done
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/autogain-selftest timeout 600 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; stop "Selbsttest prepper_sdr ($py) fehlgeschlagen"; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok" "selftest sdrWd2 ok" "selftest sdrAir ok" "selftest sdrAir2 ok" "selftest sdrFall ok" "selftest dabSql ok" "selftest airTest ok" "selftest sdrHalt ok" "selftest sdrRest ok" "selftest sdrRest2 ok" "selftest sdrStick3 ok" "selftest autoGain ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; stop "Selbsttest prepper_sdr ohne Zeile '$k' ($py)"; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum, Fake-Hilfsprogramm; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet)"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest autoGain ok' "$W/sdrt.log" | tail -1 | cut -c1-420)"
done
# AST-Guard: Rueckbau (Block weg, Stellen zurueck) muss die bekannte Basis ergeben; dann Regeln + Mutationstest
python3 "$RGD" revert "$DASH_DIR" "$W" "$RED" "$W/alt" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: Block autoGain im Pi-Stand nicht sauber entfernbar (Stand weicht ab)"; }
mkdir -p "$W/blk"; cp "$RSM" "$RSD" "$RDH" "$W/blk/"
[[ "$(s16 "$W/alt/prepper_sdr.py")" == "$KNOWN_SDR16" && "$(s16 "$W/alt/sdr_manager.py")" == "$KNOWN_SM16" && "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne autoGain ist nicht die bekannte Basis ($(s16 "$W/alt/prepper_sdr.py")/$(s16 "$W/alt/sdr_manager.py")/$(s16 "$W/alt/dashboard.py"))"
GPY="$VPY"
python3 "$RGD" check "$W/alt" "$W/sbx" "$W/blk" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard autoGain meldet Verstoss"; }
cat "$W/g.log"
python3 "$RGD" mutate "$W/sbx" "$W/blk" "$RED" > "$W/gm.log" 2>&1 || { tail -5 "$W/gm.log"; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt"; }
tail -1 "$W/gm.log" | cut -c1-260
# Generator in der Sandbox: Kopie der Programmdateien (ohne config.py), Ausgabe nach $W/sbxdocs, kein Zugriff auf das laufende Dashboard (Port 1), nichts gesendet
for x in "$DASH_DIR"/*.py; do [[ "$(basename "$x")" == config.py ]] && continue; cp "$x" "$W/dsbx/"; done
cp "$W/work/dashboard.py" "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/dsbx/"; cp "$RPD" "$W/dsbx/prepper_docs.py"
PRDOCS_BASE="$W/dsbx" PRDOCS_OUT="$W/sbxdocs" PRDOCS_PORT=1 python3 "$W/dsbx/prepper_docs.py" --dump-stable "$W/st1.txt" > "$W/gen0.log" 2>&1 || { tail -12 "$W/gen0.log"; stop "Generator prepper_docs.py in der Sandbox meldet einen Fehler"; }
python3 "$PCK" docs "$W/sbxdocs" > "$W/gen1.log" 2>&1 || { cat "$W/gen1.log"; stop "Sandbox-Version der Projektbeschreibung fehlerhaft"; }
echo "OK Generator-Probelauf in der Sandbox: $(cat "$W/gen1.log")"
SBT=$(ls -1 "$W/sbxdocs"/*.txt | tail -1)
for k in "Gain-Automatik" "/api/sdr/autogain" "sdr_autogain.json" "Software-AGC" "Kachelbreite"; do
  grep -qF "$k" "$SBT" || stop "Sandbox-Version der Beschreibung enthaelt '$k' nicht (neuer Text fehlt)"
done
! grep -qF "Standard-Gain wird nie von Tests veraendert (airTest: Stufen 12/19/21 je 5 Runden, nur auf Anforderung" "$SBT" || stop "Sandbox-Version der Beschreibung enthaelt noch die alte Aussage 'Standard-Gain wird nie veraendert'"
echo "OK Sandbox-Version beschreibt die Gain-Automatik, den welle-cli-Befund (Software-AGC), /api/sdr/autogain und die Kachelbreite"
PRDOCS_BASE="$W/dsbx" PRDOCS_OUT="$W/sbxdocs" PRDOCS_PORT=1 python3 "$W/dsbx/prepper_docs.py" --dump-stable "$W/st2.txt" > "$W/gen2.log" 2>&1 || true
if grep -q "UNVERAENDERT" "$W/gen2.log"; then echo "OK Generator idempotent (zweiter Lauf: UNVERAENDERT, keine neue Version)"
else
  echo "Generator-Lauf 2 meldet nicht UNVERAENDERT. Unterschied der in den Stand-Hash eingehenden Teile (Lauf 1 -> Lauf 2, geschwaerzt, erste 40 Zeilen):"
  diff -u "$W/st1.txt" "$W/st2.txt" 2>&1 | head -40 | cut -c1-220 | sed 's/^/   | /' || true
  grep -E "^(OK Version|UNVERAENDERT|FEHLER)" "$W/gen2.log" | cut -c1-200 | sed 's/^/   | Lauf 2: /' || true
  stop "Generator nicht idempotent"
fi
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
[[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"
echo "Watchdog vorher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-360)"
AGS0=0; [[ -f "$AGS" ]] && AGS0=1
AGQ0=0; [[ -f "$AGQ" ]] && AGQ0=1
ATREQ0=0; [[ -f "$DASH_DIR/sdr_airtest_req.json" ]] && ATREQ0=1
# welche Dateien muessen ersetzt werden
NEED_SDR=0; NEED_SM=0; NEED_D=0; NEED_P=0
cmp -s "$W/work/prepper_sdr.py" "$M" || NEED_SDR=1
cmp -s "$W/work/sdr_manager.py" "$SMF" || NEED_SM=1
cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
cmp -s "$RPD" "$PD" || NEED_P=1
[[ "$NEED_SDR$NEED_SM$NEED_D$NEED_P" == 0000 ]] || { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart der Dienste erforderlich"; }
# SQLite-Sicherung (nur lesend gelesen, Kopie ueber die Backup-Schnittstelle) - vor jeder Aenderung
LZB=""
if [[ -f "$LZ" && "$NEED_SDR$NEED_SM$NEED_D$NEED_P" != 0000 ]]; then
  LZB="$LZ.bak-autogain-$TS"
  python3 - "$LZ" "$LZB" << 'PYE' || { rm -f "$LZB"; stop "SQLite-Sicherung lagezentrum.db fehlgeschlagen"; }
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=20)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
n = dst.execute("PRAGMA integrity_check").fetchone()[0]
assert n == "ok", n
dst.close(); src.close()
PYE
  { ls -1t "$LZ.bak-autogain-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  echo "OK SQLite-Sicherung $(basename "$LZB") ($(wc -c < "$LZB") Bytes, integrity_check ok), behalten: letzte $KEEP_LAST"
fi
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert) ----------
trap '' INT
PHASE=Installation
RESTARTED_SDR=0; RESTARTED_D=0
ls -1 "$DOCS" 2>/dev/null | sort > "$W/docs0.txt" || true
DOCS_EXISTED=0; [[ -d "$DOCS" ]] && DOCS_EXISTED=1
ALL=("$F" "$PD" "$SMF" "$M")
T0S=$(date +%s); T0D=$T0S
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  sudo journalctl -u prepper-sdr --since "@${T0S:-0}" --no-pager -o cat 2>/dev/null | grep -E "autoGain|Traceback" | tail -4 | cut -c1-200
  sudo journalctl -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat 2>/dev/null | grep -E "autoGain|Traceback" | tail -4 | cut -c1-200
  for x in "${ALL[@]}"; do [[ -f "$x.bak-autogain-$TS" ]] && cp -a "$x.bak-autogain-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
  if [[ -d "$DOCS" ]]; then
    ls -1 "$DOCS" | sort > "$W/docs1.txt"
    comm -13 "$W/docs0.txt" "$W/docs1.txt" | grep -E '^Projektbeschreibung Lage Pi v[0-9]{8}-[0-9]{4}\.(txt|md)$' | while read -r o; do rm -f -- "$DOCS/$o"; done
    [[ "$DOCS_EXISTED" == 0 ]] && rmdir "$DOCS" 2>/dev/null
  fi
  [[ "$AGS0" == 0 ]] && rm -f "$AGS" "$AGS.tmp"
  [[ "$AGQ0" == 0 ]] && rm -f "$AGQ"
  if [[ "$RESTARTED_SDR" == 1 ]]; then
    sudo systemctl restart prepper-sdr.service
    for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && break; done
  fi
  if [[ "$RESTARTED_D" == 1 || "$RESTARTED_SDR" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  for x in "${ALL[@]}"; do [[ -f "$x.bak-autogain-$TS" ]] || continue; cmp -s "$x" "$x.bak-autogain-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
  echo "  SQLite-Sicherung (nicht zurueckgespielt, Datenbank wurde nicht veraendert): ${LZB:-keine}"
  echo "alter Stand (meshPost + sdrFall) wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/"), Gain laut broadcast_state.json: $(python3 "$AGC" gain "$DASH_DIR" 2>/dev/null)"
}
rbx() { if [[ "$RESTARTED_SDR" == 1 || "$RESTARTED_D" == 1 || "$NEED_P" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_SDR$NEED_SM$NEED_D$NEED_P" == 0000 ]]; then
  echo "OK autoGain schon installiert (prepper_sdr.py, sdr_manager.py, dashboard.py, prepper_docs.py) - kein Neustart, keine Aenderung der Programme"
  T0S=$(( $(date +%s) - 86400 )); T0D=$T0S
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true); [[ -n "$TB" ]] && T0S=$(date -d "$TB" +%s 2>/dev/null || echo "$T0S")
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-autogain-$TS"
    { ls -1t "$x.bak-autogain-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  mkdir -p "$DOCS" || { rb "docs/ nicht anlegbar"; exit 1; }
  inst() { cp "$1" "$2.new" && chmod --reference="$2.bak-autogain-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $(basename "$2")"; exit 1; }; }
  [[ "$NEED_P" == 1 ]] && inst "$RPD" "$PD"
  [[ "$NEED_SM" == 1 ]] && inst "$W/work/sdr_manager.py" "$SMF"
  [[ "$NEED_SDR" == 1 ]] && inst "$W/work/prepper_sdr.py" "$M"
  [[ "$NEED_D" == 1 ]] && inst "$W/work/dashboard.py" "$F"
  echo "OK Dateien atomar ersetzt (Sicherungen *.bak-autogain-$TS, behalten: letzte $KEEP_LAST)"
  if [[ "$NEED_SDR" == 1 || "$NEED_SM" == 1 ]]; then
    RESTARTED_SDR=1
    T0S=$(date +%s)
    echo "Neustart prepper-sdr - warte auf frischen SDR-Status (max 240 s), 11D-Sync vom Airspy (max 300 s) und den Zustand der Gain-Automatik (sendet nichts, aendert den Gain nicht) ..."
    sudo systemctl restart prepper-sdr.service
    ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$AC" status "$DASH_DIR" "$T0S" > "$W/ast.log" 2>&1 && { ok=1; break; }; done
    [[ "$ok" == 1 ]] || { cat "$W/ast.log"; rb "prepper-sdr: Airspy 11D laeuft nach dem Neustart nicht ($(head -c 200 "$W/ast.log"))"; exit 1; }
    pok=0; for i in $(seq 1 120); do python3 "$AC" port 7979 > "$W/port.log" 2>&1 && { pok=1; break; }; sleep 1; done
    [[ "$pok" == 1 ]] && echo "OK welle-cli (Airspy) $(cat "$W/port.log")" || { rb "Port 7979 (welle-cli Airspy) lauscht nicht"; exit 1; }
    sok=0; for i in $(seq 1 100); do python3 "$AC2" proof "$DASH_DIR" "$T0S" > "$W/proof.log" 2>&1 && { sok=1; break; }; sleep 3; done
    [[ "$sok" == 1 ]] && echo "OK $(cut -c1-460 "$W/proof.log")" || { cat "$W/proof.log"; rb "11D-Sync vom Airspy nach 300 s nicht nachgewiesen"; exit 1; }
    eok=0; for i in $(seq 1 40); do python3 "$AGC" engine "$DASH_DIR" "$T0S" "$GAIN0" > "$W/eng.log" 2>&1 && { eok=1; break; }; sleep 3; done
    [[ "$eok" == 1 ]] && echo "OK $(cat "$W/eng.log")" || { cat "$W/eng.log"; rb "Gain-Automatik: Zustand nicht geschrieben, Fehler oder Gain geaendert"; exit 1; }
    SDR_AET=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  fi
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard - warte auf HTTP 200 (max 240 s) und die Zeile 'autoGain aktiv' im Journal ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
fi
PHASE=Pruefung
# Nach dem Neustart zeigt das Dashboard erst eine Startseite ("Dashboard startet"), bis das erste Voll-Update da ist (bis ca. 2 min); die Beschreibung soll ein fertig gestartetes Dashboard sehen
rdy=0
for i in $(seq 1 40); do
  ok2=1; for p in /umwelt /energie /; do "${CURL[@]}" "$B$p" -o "$W/pg.html" || true; grep -q "<title>Dashboard startet" "$W/pg.html" && ok2=0; done
  [[ "$ok2" == 1 ]] && { rdy=1; break; }
  [[ "$RESTARTED_D" == 1 ]] || { rdy=1; break; }
  sleep 5
done
[[ "$rdy" == 1 ]] && echo "OK Dashboard fertig gestartet (erstes Voll-Update da)" || echo "HINWEIS Dashboard zeigt nach 200 s noch die Startseite - die Version wird trotzdem erzeugt (Kachel-Ueberschriften live teilweise leer)"
# ---------- 4) Version der Beschreibung erzeugen ----------
(cd "$DASH_DIR" && PRDOCS_BASE="$DASH_DIR" PRDOCS_OUT="$DOCS" PRDOCS_PORT="$PORT" "$SPY" "$PD" > "$W/gen.log" 2>&1) || { tail -15 "$W/gen.log"; rbx "prepper_docs.py meldet einen Fehler"; }
grep -E "^(OK Version|UNVERAENDERT)" "$W/gen.log" | cut -c1-260
VER_LINE=$(grep -E "^OK Version|^UNVERAENDERT" "$W/gen.log" | tail -1 || true)
[[ -n "$VER_LINE" ]] || { tail -10 "$W/gen.log"; rbx "prepper_docs.py: weder neue Version noch UNVERAENDERT gemeldet"; }
python3 "$PCK" docs "$DOCS" > "$W/pd.log" 2>&1 && echo "OK $(cat "$W/pd.log")" || { cat "$W/pd.log"; rbx "docs/: Projektbeschreibung unvollstaendig oder mit Schluessel-Muster"; }
sed -n '/^Pruefbericht/,/^Nachtrag-Abschnitte/p' "$W/gen.log" | cut -c1-200 | sed 's/^/   /'
NACH=$(grep -E "^Nachtrag-Abschnitte:" "$W/gen.log" | tail -1 | grep -oE "[0-9]+" || echo "?")
[[ "$NACH" == 0 ]] && echo "OK Beschreibung ohne Nachtrag (alles Gefundene ist redaktionell beschrieben)" || echo "HINWEIS Beschreibung enthaelt $NACH Nachtrag-Abschnitt(e) (nur Hinweis; Details im Kapitel Nachtrag der neuen Version)"
# ---------- 5) Rauchtest (nur GET auf lesende Seiten/APIs) ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist /karte /api/sdr/wd /api/sdr/ui /api/t2/status /api/t4/status /api/t4/tii /api/br24 /api/docs/list /api/sdr/autogain /api/sdr/airtest; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
python3 "$AGC" page "$W/funk.html" > "$W/ag1.log" 2>&1 && echo "OK $(cat "$W/ag1.log")" || { cat "$W/ag1.log"; rbx "/funk ohne Karte Gain-Automatik oder ohne Kachelbreiten-Korrektur"; }
python3 "$FC" funk "$W/funk.html" "$W" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/funk ohne funkUI"; }
python3 "$WC" funk "$W/funk.html" "$W" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne Daten-Watchdog"; }
python3 "$WC2" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk Watchdog-Zeilen"; }
python3 "$AC" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne sdrAir-Anzeige"; }
python3 "$AGC" atpage "$W/funk.html" > "$W/atp.log" 2>&1 && echo "OK $(cat "$W/atp.log")" || { cat "$W/atp.log"; rbx "/funk ohne airTest-Karte"; }
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x doPrepperRestore wie vorher)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$WC" pi "$W/pi.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/pi Watchdog-Kachel"; }
python3 "$PCK" pi "$W/pi.html" "$DOCS" > "$W/pi.log" 2>&1 && echo "OK $(cat "$W/pi.log")" || { cat "$W/pi.log"; rbx "/pi: Kachel Projektbeschreibung Lage Pi"; }
aok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/autogain" -o "$W/ag.json" || true; python3 "$AGC" api "$W/ag.json" > "$W/ag2.log" 2>&1 && { aok=1; break; }; sleep 6; done
[[ "$aok" == 1 ]] && echo "OK $(cat "$W/ag2.log")" || { cat "$W/ag2.log"; rbx "/api/sdr/autogain"; }
tok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/airtest" -o "$W/atapi.json" || true; python3 "$AGC" at "$W/atapi.json" > "$W/at2.log" 2>&1 && python3 "$ACK" api "$W/atapi.json" > "$W/ata.log" 2>&1 && { tok=1; break; }; sleep 6; done
[[ "$tok" == 1 ]] && echo "OK $(cat "$W/at2.log"); $(cut -c1-200 "$W/ata.log")" || { cat "$W/at2.log" "$W/ata.log" 2>/dev/null; rbx "/api/sdr/airtest"; }
python3 "$ACK" state "$DASH_DIR" > "$W/ats.log" 2>&1 && echo "OK $(cat "$W/ats.log")" || { cat "$W/ats.log"; rbx "sdr_airtest.json kaputt"; }
uok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/ui" -o "$W/ui.json" || true; python3 "$AC" ui "$W/ui.json" > "$W/wc.log" 2>&1 && { uok=1; break; }; sleep 6; done
[[ "$uok" == 1 ]] && echo "OK $(cut -c1-300 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/ui ohne Geraete-Register"; }
wok=0; for i in $(seq 1 30); do "${CURL[@]}" "$B/api/sdr/wd" -o "$W/wd.json" || true; python3 "$AC2" api "$W/wd.json" > "$W/wc.log" 2>&1 && { wok=1; break; }; sleep 6; done
[[ "$wok" == 1 ]] && echo "OK $(cut -c1-400 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/wd ohne sdrAir2-Zusammenfassung (Namen/Hobby/wird geprueft)"; }
# POST ohne Funk-Seiten-Herkunft muss abgelehnt werden und darf nichts anfordern
for u in /api/sdr/autogain /api/sdr/airtest; do
  c1=$(curl -s --connect-timeout 3 --max-time 20 -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"action":"measure","confirm":true}' "$B$u" || true)
  c2=$(curl -s --connect-timeout 3 --max-time 20 -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -H "X-T2: 1" -H "Origin: http://fremd.example" -d '{"action":"measure","confirm":true}' "$B$u" || true)
  [[ "$c1" == 403 && "$c2" == 403 ]] && echo "OK POST $u ohne Funk-Seiten-Herkunft (403) und mit fremder Herkunft (403) abgelehnt - nichts angefordert" || rbx "POST $u ohne/mit fremder Herkunft nicht abgelehnt ($c1/$c2)"
done
[[ ! -f "$AGQ" || "$AGQ0" == 1 ]] && echo "OK keine Anforderungsdatei sdr_autogain_req.json durch den Rauchtest" || rbx "sdr_autogain_req.json durch Rauchtest entstanden"
[[ ! -f "$DASH_DIR/sdr_airtest_req.json" || "$ATREQ0" == 1 ]] && echo "OK keine Test-Anforderung sdr_airtest_req.json durch den Rauchtest" || rbx "sdr_airtest_req.json durch Rauchtest entstanden"
"${CURL[@]}" "$B/api/docs/list" -o "$W/dl_list.json" || true
python3 "$PCK" list "$W/dl_list.json" "$DOCS" > "$W/pl.log" 2>&1 && echo "OK $(cat "$W/pl.log")" || { cat "$W/pl.log"; rbx "/api/docs/list"; }
for fmt in txt md; do
  for v in "" "$(python3 -c "import json;print(json.load(open('$W/dl_list.json'))['current'])")"; do
    curl -s --connect-timeout 3 --max-time 40 -D "$W/dl.hdr" -o "$W/dl.body" "$B/api/docs/download?fmt=$fmt&v=$v" || true
    python3 "$PCK" dl "$W/dl.hdr" "$W/dl.body" "$DOCS" "$v" "$fmt" > "$W/pdl.log" 2>&1 && echo "OK $(cat "$W/pdl.log")$([[ -z "$v" ]] && echo " (ohne Versionsangabe = neueste)")" || { cat "$W/pdl.log"; rbx "/api/docs/download fmt=$fmt v=$v"; }
  done
done
"${CURL[@]}" "$B/api/docs/routes" -o "$W/dr.json" || true
python3 "$PCK" routes "$W/dr.json" "${PAGES[@]}" "${APIS[@]}" /api/docs/list /api/docs/download /api/docs/routes /api/meshpost/status /api/sdr/autogain /api/sdr/airtest > "$W/pr.log" 2>&1 && echo "OK $(cat "$W/pr.log")" || { cat "$W/pr.log"; rbx "/api/docs/routes"; }
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
# ---------- 6) Journale ----------
JP=$(sudo journalctl -u prepper-sdr --since "@$T0S" --no-pager -o cat 2>/dev/null || true)
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
R1='Traceback|autoGain (Tick|Zustand|speichern|Fehler|FEHLER)|autoGain: (FEHLER|Fehler)|airTest (Tick|Befehl|Messung|Fehler|Standard-Gain pruefen|speichern|Anzeige)|sdrHalt( Start:|: (Waechter|Sperrgrund merken|Hilfsprogramm-Pruefung:|Neustart-Zaehler|Planer-Faden))|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:'
E1=$(echo "$JP" | grep -c -E "$R1" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/autoGain-/airTest-/sdrWd-Fehler" || { echo "$JP" | grep -E "$R1" | head -5 | cut -c1-240; rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"; }
if [[ "$RESTARTED_SDR" == 1 ]]; then
  echo "$JP" > "$W/jp.txt"
  python3 "$AGC" journal "$W/jp.txt" > "$W/agj.log" 2>&1 && echo "OK $(cat "$W/agj.log")" || { cat "$W/agj.log"; rbx "prepper-sdr meldet die Gain-Automatik nicht bereit"; }
  echo "   $(echo "$JP" | grep -F 'autoGain: bereit' | tail -1 | cut -c1-330)"
  JB=$(echo "$JP" | grep -F "airTest: bereit" | tail -1 || true)
  [[ -n "$JB" ]] && echo "OK Journal prepper-sdr: $(echo "$JB" | cut -c1-200)" || rbx "prepper-sdr meldet airTest nicht (bereit)"
  JH=$(echo "$JP" | grep -F "sdrHalt: bereit" | tail -1 || true)
  [[ -n "$JH" && "$JH" == *"systemd-Watchdog aktiv"* ]] && echo "OK Journal prepper-sdr: $(echo "$JH" | cut -c1-300)" || rbx "prepper-sdr meldet sdrHalt nicht bereit mit systemd-Watchdog ($JH)"
  AET2=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ "$AET2" == "$SDR_AET" ]] && echo "OK prepper-sdr seit dem Neustart nicht vom Watchdog beendet (Start $AET2)" || rbx "prepper-sdr wurde nach dem Neustart erneut gestartet (Start $SDR_AET -> $AET2)"
else
  SDR_AET1=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ "$SDR_AET1" == "$SDR_AET0" ]] && echo "OK prepper-sdr nicht neu gestartet (Start $SDR_AET1)" || rbx "prepper-sdr wurde neu gestartet ($SDR_AET0 -> $SDR_AET1)"
fi
if [[ "$RESTARTED_D" == 1 ]]; then
  JA=$(echo "$JD" | grep -F "autoGain aktiv: autoGain Anzeige ok" | tail -1 || true)
  [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-230)" || rbx "Journal prepper-dashboard ohne 'autoGain aktiv: autoGain Anzeige ok'"
fi
R2='Traceback|autoGain Anzeige FEHLER|autoGain (Anzeige|Seite):|projDoc (FEHLER|Liste:|Download:|/pi:)|airTest (Anzeige(:| FEHLER)|Seite:)|sdrWd FEHLER|funkUI FEHLER|sdr_manager sdrWd'
E2=$(echo "$JD" | grep -c -E "$R2" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/autoGain-Fehler" || { echo "$JD" | grep -E "$R2" | head -5 | cut -c1-240; rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"; }
# ---------- 7) Zustand nachher ----------
TENG=$T0S; [[ "$RESTARTED_SDR" == 1 ]] || TENG=$(( $(date +%s) - 180 ))
python3 "$AGC" engine "$DASH_DIR" "$TENG" "$GAIN0" > "$W/eng2.log" 2>&1 && echo "OK $(cat "$W/eng2.log")" || { cat "$W/eng2.log"; rbx "Gain-Automatik nach der Pruefung: Zustand/Fehler/Gain"; }
python3 "$AGC" state "$DASH_DIR" > "$W/ags.log" 2>&1 && echo "OK $(cat "$W/ags.log")" || { cat "$W/ags.log"; rbx "sdr_autogain.json kaputt"; }
GAIN1=$(python3 "$AGC" gain "$DASH_DIR" 2>/dev/null || echo "?")
[[ "$GAIN1" == "$GAIN0" ]] && echo "OK Gain des Airspy unveraendert: Stufe $GAIN1 (vorher $GAIN0)" || rbx "Gain hat sich geaendert (vorher $GAIN0, nachher $GAIN1)"
python3 "$AC2" proof "$DASH_DIR" 0 > "$W/proof.log" 2>&1 && echo "Geraete nachher: $(cut -c1-460 "$W/proof.log")" || echo "HINWEIS Geraete nachher: $(cut -c1-300 "$W/proof.log")"
echo "Watchdog nachher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-400)"
for x in "$DBF:$DB16" "$MR:$MR16" "$HDST:$HL16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ ! -f "$CF" || "$(s16 "$CF")" == "$CF16" ]] && echo "OK sdr_config.json unveraendert ($CF16)" || rbx "sdr_config.json hat sich veraendert"
echo "OK guards autoGain(sdr)=$(grep -c '# ===== autoGain:' "$M" || true) autoGain(sm)=$(grep -c '# ===== autoGain:' "$SMF" || true) autoGain(dash)=$(grep -c '# ===== autoGain:' "$F" || true) meshPost(dash)=$(grep -c '# ===== meshPost:' "$F" || true) projDoc=$(grep -c '# ===== projDoc:' "$F" || true) sdrFall(sdr)=$(grep -c '# ===== sdrFall:' "$M" || true) airTest(sdr)=$(grep -c '# ===== airTest:' "$M" || true) sdrHalt(sdr)=$(grep -c '# ===== sdrHalt:' "$M" || true)"
[[ -f "$F.bak-autogain-$TS" ]] && echo "Backups: *.bak-autogain-$TS (dashboard.py, prepper_docs.py, sdr_manager.py, prepper_sdr.py), SQLite: ${LZB:+$(basename "$LZB")}, behalten: letzte $KEEP_LAST"
for x in "$F" "$PD" "$SMF" "$M" "$DBF" "$MR" "$LG" "$CF" "$HDST"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
VNEW=$(python3 -c "import json;print(json.load(open('$W/dl_list.json'))['current'])")
echo "docs/ (neueste Version v$VNEW; aeltere Versionen bleiben):"
for x in "$DOCS/Projektbeschreibung Lage Pi v$VNEW.txt" "$DOCS/Projektbeschreibung Lage Pi v$VNEW.md"; do echo "  $(basename "$x") sha256 $(sha256sum "$x" | cut -d' ' -f1), $(wc -c < "$x") Bytes, $(wc -l < "$x") Zeilen"; done
if [[ -f "$F.bak-autogain-$TS" ]]; then echo "Rueckweg: dashboard.py, prepper_docs.py, sdr_manager.py, prepper_sdr.py aus *.bak-autogain-$TS zurueckkopieren, dann sudo systemctl restart prepper-sdr und danach sudo systemctl restart prepper-dashboard (sdr_autogain.json darf bleiben, der alte Stand ignoriert sie)"
else LB=$({ ls -1t "$F.bak-autogain-"* 2>/dev/null || true; } | head -1); [[ -n "$LB" ]] && echo "Rueckweg (neueste autoGain-Sicherung: $(basename "$LB")): alle vier Dateien zurueckkopieren, dann prepper-sdr und danach prepper-dashboard neu starten" || echo "Rueckweg: keine autoGain-Sicherung vorhanden (nichts geaendert)"; fi
echo "Neue Version spaeter: cd $DASH_DIR && python3 prepper_docs.py (erzeugt nur bei geaendertem Stand eine neue Version, --force erzwingt, behaelt die letzten 10)"
echo "Gain-Automatik: Modus Auto an; Gain bleibt Stufe $GAIN1, bis nach den ersten Messungen (taeglich im Nachtfenster 01-05 Uhr, spaetestens nach 36 h, oder nach anhaltend schlechtem Empfang) ein klarer Vorteil ueber mehrere Sitzungen gemessen ist; Auto (welle-cli -g -1) ist Software-AGC und wird nur gemessen. Kachel Gain-Automatik auf /funk: Auto/Fest, Verlauf, Gain-Test 2 starten. Nichts gesendet (kein Mesh, kein Telegram, keine Alarme)."
echo "COMMIT $COMMIT_ARG autogain=1 fertig"
