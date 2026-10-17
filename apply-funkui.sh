#!/bin/bash
set -euo pipefail
# funkUI (Teil 2 von 2 der Funk-Seiten-Ueberarbeitung): /funk neu geordnet (Mesh-Kacheln unveraendert, Funk-Lage = Sticks & Alarm-Automatik + SDR-Status,
# Empfaenger, Steuerung eingeklappt mit Bestaetigung fuer Stick-2-5C/Lage/Betriebsart, Meteor-Kachel nur wenn an oder Bilder da, Historie umbrechend,
# Antennentest zuletzt eingeklappt), /dabhist als Karten mit 44-px-Filtern (Programm-Infos aus), /meteor als Karten-Galerie mit Vorschaubildern.
# sdr_manager.py: SNR/FIC-Grenzwert-Ereignisse aus vorhandenen Messungen (Grenzen in sdr_config.json einstellbar, sonst Standard),
# Technik-Verlauf (sdrLog) in die Ereignis-Historie, und kein kurzes falsches SDR_OFFLINE mehr bei DB-Sperre (Lebenszeichen aus Speicher).
# Klarnamen: DAB-Sender ueberall mit Namen vor dem TII-Code (z. B. Bamberg (Geisberg) · 08/18), Codes ausserhalb MASTS_DB als unbekannt · MM/SS
# (Funk-Lage, Historie, /dabhist, Karten-Popups).
# Aendert sdr_manager.py und dashboard.py; prepper_sdr.py, database.py, mesh_router.py, lagegeo.py bleiben unveraendert.
# Neustart nur prepper-dashboard. Alle Schalt-Knoepfe laufen ueber die bestehenden Wege (Bestaetigung, same-origin, Kopfzeile, LAN-Pruefung). Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/funkui-apply
KEEP_LAST=3
KNOWN_D16="95e74a7b2fd00e4d"     # dashboard.py nach sqlC
KNOWN_D16N="ccccd6476c2ab2e4"     # dashboard.py nach funkUI (Ziel)
KNOWN_SM16="682045d52602f371"    # sdr_manager.py nach sqlC
KNOWN_SM16N="4cbc77c70193bacd"    # sdr_manager.py nach funkUI (Ziel)
KNOWN_SDR16="0fc4850dd84ff76e"   # prepper_sdr.py nach sqlC
KNOWN_SDR16L="786f2c925f0e88a7"   # prepper_sdr.py nach sdrLog
KNOWN_DB16="431077d36822a090"    # database.py (bleibt unveraendert)
KNOWN_MR16="c5ffda3907b0dd51"    # mesh_router.py (bleibt unveraendert)
KNOWN_LG16="3788481354f47656"    # lagegeo.py (bleibt unveraendert)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== funkUI apply (/funk Funk-Lage + Steuerung, /dabhist Karten, /meteor Galerie, Grenzwerte, Lebenszeichen bei DB-Sperre), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_PF="24ca150b11f4c77b5d34085330c7cc64c90e5795e498cde56fb0f2562ae906ef"
cat > "$W/patch-fu.py" << 'FUP_EOF'
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
name = {"sm": "sdr_manager", "sdr": "prepper_sdr", "dash": "dashboard"}[kind]
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
FUP_EOF
EXPECT_ED="804ab9ca2a5499776a5ac407d1ad023ed26ea4cb3d90e78270eecef337731999"
cat > "$W/fu_edits.py" << 'FUE_EOF'
# funkUI: Stellen (alt, neu) je Datei. Jede alte Stelle muss genau einmal vorkommen.
SM_EDITS = [
('''            for r in telemetry_rows(self.base, now):
                add["telemetry"] += 1 if db.insert_telemetry(r, self.path) else 0
''', '''            _fu_new = []
            for r in telemetry_rows(self.base, now):
                if db.insert_telemetry(r, self.path):
                    add["telemetry"] += 1
                    _fu_new.append(r)
            add["events"] += fu_sync(self, _fu_new, now)   # funkUI: SNR/FIC-Grenzen + Technik-Verlauf
'''),
('''                hb = heartbeat_row(st, now)
                if hb and db.insert_telemetry(hb, self.path):
                    add["hb"] += 1
                    self.last_hb = now
''', '''                hb = heartbeat_row(st, now)
                _fu_ok = bool(hb) and db.insert_telemetry(hb, self.path)
                fu_hb_note(hb, _fu_ok, now)   # funkUI: Lebenszeichen auch im Speicher (DB gesperrt -> kein falsches SDR_OFFLINE)
                if _fu_ok:
                    add["hb"] += 1
                    self.last_hb = now
'''),
('''        nt = db.newest_telemetry(path=path)
        age = (now - int(nt["ts"])) if nt else None
''', '''        _fu_e0 = db.last_error() if hasattr(db, "last_error") else None
        nt = db.newest_telemetry(path=path)
        age = (now - int(nt["ts"])) if nt else None
        _fu_rd = hasattr(db, "last_error") and db.last_error() is not _fu_e0   # funkUI: Lesefehler (gesperrt) erkannt
'''),
('''        if age is None or age > WATCHDOG_S:
            out["status"] = "SDR_OFFLINE"
        else:
            out["status"], why = classify(db.active_events(now, path), br, now)
''', '''        _fu_mem = fu_live_mem(st, now, age, _fu_rd)   # funkUI
        if _fu_mem:
            out["watchdog"].update(src="speicher", note_mem=_fu_mem)
        if (age is None or age > WATCHDOG_S) and not _fu_mem:
            out["status"] = "SDR_OFFLINE"
        else:
            out["status"], why = classify(fu_active(now, path), br, now)
'''),
('''            if src == "VORALARM":
                c = "#f97316"
''', '''            if src == "VORALARM" or src == "SDR":   # funkUI: Stick-2-Uebernahme/Rueckfall orange
                c = "#f97316"
'''),
('''    print(selftest_sqlc())
''', '''    print(selftest_sqlc())
    print(selftest_funkui())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
DASH_EDITS = [   # funkUI: Karte - Klarname vor TII-Code im Popup und in der Liste unbekannter Kennungen
("""'</b> TII '+esc(c.tii_txt)+': '""", """'</b> TII '+esc((m.name||'unbekannt')+' · '+c.tii_txt)+': '"""),
("""x+=(i?' · ':'')+esc(u.ch)+' '+esc(u.tii_txt)+' ('""", """x+=(i?' · ':'')+esc(u.ch)+' unbekannt · '+esc(u.tii_txt)+' ('"""),
("""for(var ch in (V.ch||{})){var c=V.ch[ch];if(!c.fig_t&&ch!=='11D')continue;""",
 """var kvn=function(cc,t){var a=(V.masts||[]).concat(V.nopos||[]);for(var i=0;i<a.length;i++){var cs=a[i].ch||[];for(var k=0;k<cs.length;k++){if(cs[k].ch===cc&&cs[k].tii_txt===t)return (a[i].name||'unbekannt')+' · '+t;}}return 'unbekannt · '+t;};
for(var ch in (V.ch||{})){var c=V.ch[ch];if(!c.fig_t&&ch!=='11D')continue;"""),
("""dB · TII '+esc((c.tii||[]).join(', ')||'–')+'</div>';}""", """dB · TII '+esc((c.tii||[]).map(function(t){return kvn(ch,t);}).join(', ')||'–')+'</div>';}"""),
]
DASH_ANCHOR = "# ===== /sqlC =====\n"
FUE_EOF
EXPECT_BSM="641e0fcf095c95a2ef6f7e002eb7900f328906c9874ba7df947c7b20c268a609"
cat > "$W/fu_sm_block.py" << 'FUS_EOF'
# ===== funkUI: Lebenszeichen auch im Speicher (eigener DB-Schreibfehler/Sperre -> kein falsches SDR_OFFLINE, solange sdr_status frisch und prepper-sdr lebt), SNR/FIC-Grenzwert-Ereignisse aus der vorhandenen Telemetrie (Grenzen in sdr_config.json, Standard wenn fehlt), Technik-Verlauf sdr_techlog.json -> Ereignisse; nur lesen + eigene DB-Zeilen, sendet nichts =====
FU_LIVE_GRACE_S = 120        # so lange nach dem letzten sicheren Lebenszeichen gilt prepper-sdr bei DB-Sperre noch als lebendig
FU_ACT_KEEP_S = 600          # aktive Ereignisse aus dem Speicher, wenn die DB gerade nicht lesbar ist
FU_THR_DEFAULTS = {"tech_snr_low_db": 5.0, "tech_snr_ok_db": 7.0, "tech_fic_bad": 0.10, "tech_fic_ok": 0.03, "tech_thr_n": 2}
FU_THR_HELP = {"tech_snr_low_db": "SNR niedrig unter (dB)", "tech_snr_ok_db": "SNR wieder gut ab (dB)", "tech_fic_bad": "FIC-Fehlerrate schlecht ueber (0,10 = 10 %)",
               "tech_fic_ok": "FIC-Fehlerrate wieder gut unter (0,03 = 3 %)", "tech_thr_n": "so viele Messungen in Folge"}
_FU_LIVE = {"alive_t": None, "hb_ok_t": None, "hb_fail_t": None, "act": None, "act_t": None}
_FU = {"cfg": None, "cfg_k": None, "thr": None, "tl_mt": None}


def fu_hb_note(hb, ok, now):
    """Aus Sync.tick: Lebenszeichen berechnet (hb) und ob es in die DB kam (ok)."""
    if hb:
        _FU_LIVE["alive_t"] = int(now)
        if ok:
            _FU_LIVE["hb_ok_t"] = int(now)
        else:
            _FU_LIVE["hb_fail_t"] = int(now)


def fu_live_mem(st, now, age, rd_err):
    """-> Grund-Text, wenn trotz fehlender/alter DB-Telemetrie lebendig (nur bei DB-Problem), sonst None."""
    if age is not None and age <= WATCHDOG_S:
        return None
    ft, okt = _FU_LIVE["hb_fail_t"], _FU_LIVE["hb_ok_t"]
    trouble = bool(rd_err) or (ft is not None and now - ft <= FU_LIVE_GRACE_S and (okt is None or ft >= okt))
    if not trouble:
        return None
    if heartbeat_row(st, now) is not None:
        return "Lebenszeichen aus dem Speicher: DB gerade gesperrt/nicht lesbar, sdr_status frisch, prepper-sdr lebt"
    at = _FU_LIVE["alive_t"]
    pid = st.get("pid") if isinstance(st, dict) else None
    if at is not None and now - at <= FU_LIVE_GRACE_S and not (isinstance(pid, int) and not _pid_alive(pid)):
        return "Lebenszeichen aus dem Speicher: DB gerade gesperrt, letztes sicheres Lebenszeichen vor %d s" % (now - at)
    return None


def fu_active(now, path):
    """Aktive Ereignisse; ist die DB gerade nicht lesbar, die zuletzt gelesenen (hoechstens 10 min alt)."""
    e0 = db.last_error() if hasattr(db, "last_error") else None
    a = db.active_events(now, path)
    if not hasattr(db, "last_error") or db.last_error() is e0:
        _FU_LIVE["act"], _FU_LIVE["act_t"] = a, now
        return a
    if _FU_LIVE["act"] is not None and now - (_FU_LIVE["act_t"] or 0) <= FU_ACT_KEEP_S:
        return _FU_LIVE["act"]
    return a


def fu_thr_cfg(base):
    """Grenzen aus sdr_config.json (tech_*), fehlende/ungueltige = Standard. Nach mtime/Groesse zwischengespeichert."""
    fn = os.path.join(base, "sdr_config.json")
    try:
        s = os.stat(fn)
        k = (s.st_mtime_ns, s.st_size, s.st_ino)
    except Exception:
        k = None
    if _FU["cfg"] is not None and _FU["cfg_k"] == k:
        return _FU["cfg"]
    d = _load_json(fn, {}) if k else {}
    d = d if isinstance(d, dict) else {}
    out, src = {}, {}
    for key, dv in FU_THR_DEFAULTS.items():
        v = d.get(key)
        ok = isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0
        out[key] = (int(v) if key == "tech_thr_n" else float(v)) if ok else dv
        src[key] = "sdr_config.json" if ok else "Standard"
    out["tech_thr_n"] = max(1, min(10, int(out["tech_thr_n"])))
    if out["tech_snr_ok_db"] < out["tech_snr_low_db"]:
        out["tech_snr_ok_db"] = out["tech_snr_low_db"]
    if out["tech_fic_ok"] > out["tech_fic_bad"]:
        out["tech_fic_ok"] = out["tech_fic_bad"]
    out["src"] = src
    _FU["cfg"], _FU["cfg_k"] = out, k
    return out


def fu_thr_text(c):
    f = lambda x: ("%g" % x).replace(".", ",")
    return "SNR niedrig unter %s dB (gut ab %s dB) · FIC-Fehlerrate schlecht über %s %% (gut unter %s %%) · je %d Messungen in Folge" % (
        f(c["tech_snr_low_db"]), f(c["tech_snr_ok_db"]), f(c["tech_fic_bad"] * 100), f(c["tech_fic_ok"] * 100), c["tech_thr_n"])


def fu_thr_eval(rows, st, c):
    """Neue DAB-Messungen -> Ereignisse bei Grenzwechsel (mit Hysterese, je N Messungen in Folge). st wird fortgeschrieben."""
    out = []
    n = c["tech_thr_n"]
    for r in sorted(rows or [], key=lambda x: x.get("ts") or 0):
        ch = str(r.get("channel") or "?")
        for k, v, bad, good, txt in (("snr", r.get("snr"), lambda x: x < c["tech_snr_low_db"], lambda x: x >= c["tech_snr_ok_db"], "SNR"),
                                     ("fic", r.get("ber"), lambda x: x > c["tech_fic_bad"], lambda x: x < c["tech_fic_ok"], "FIC-Fehlerrate")):
            if not isinstance(v, (int, float)):
                continue
            s = st.setdefault("%s|%s" % (ch, k), {"lvl": None, "cand": None, "n": 0})
            now_l = "bad" if bad(v) else ("ok" if good(v) else None)
            if now_l is None:
                s["cand"], s["n"] = None, 0
                continue
            if s["lvl"] is None:
                s["lvl"] = "ok"                      # Start: als gut annehmen, schlecht erst nach N Messungen melden
            if now_l == s["lvl"]:
                s["cand"], s["n"] = None, 0
                continue
            s["n"] = s["n"] + 1 if s["cand"] == now_l else 1
            s["cand"] = now_l
            if s["n"] < n:
                continue
            s["lvl"], s["cand"], s["n"] = now_l, None, 0
            ts = int(r.get("ts") or time.time())
            if k == "snr":
                val = ("%.1f dB" % v).replace(".", ",")
                head = ("DAB %s SNR niedrig: %s (Grenze %s dB)" if now_l == "bad" else "DAB %s SNR wieder gut: %s (ab %s dB)") % (
                    ch, val, ("%g" % (c["tech_snr_low_db"] if now_l == "bad" else c["tech_snr_ok_db"])).replace(".", ","))
            else:
                val = ("%.1f %%" % (v * 100)).replace(".", ",")
                head = ("DAB %s FIC-Fehlerrate hoch: %s (Grenze %s %%)" if now_l == "bad" else "DAB %s FIC-Fehlerrate wieder gut: %s (unter %s %%)") % (
                    ch, val, ("%g" % ((c["tech_fic_bad"] if now_l == "bad" else c["tech_fic_ok"]) * 100)).replace(".", ","))
            if r.get("mast"):
                head += " · %s" % r["mast"]
            out.append({"source": "DAB", "type": "%s_%s" % (k, now_l), "severity": "info", "headline": head[:160], "text": head,
                        "created": ts, "updated": ts, "expires": ts + 24 * 3600, "ext_id": "TH:%s:%s:%s:%d" % (ch, k, now_l, ts)})
    return out


FU_TL_SRC = {"stick": "SDR", "meteor": "METEOR"}


def events_from_techlog(d, now=None):
    """sdr_techlog.json (prepper-sdr sdrLog) -> Ereignisse (Quelle DAB / SDR / METEOR, nur Info, nie Alarm). FIG 0/9 + Label kommen schon aus Teil 2."""
    now = int(now or time.time())
    out = []
    for x in ((d or {}).get("ev") or [])[-200:] if isinstance(d, dict) else []:
        try:
            if not isinstance(x, dict) or not isinstance(x.get("t"), (int, float)) or x.get("ref"):
                continue
            if x.get("k") == "mast_new" and "erstmals" in str(x.get("text") or ""):
                continue                              # erstmals gesehene Masten meldet Teil 2 schon als TII-Ereignis; bleibt im Technik-Verlauf
            t = int(x["t"])
            out.append({"source": FU_TL_SRC.get(x.get("cat"), "DAB"), "type": str(x.get("k") or "tech")[:20], "severity": "info",
                        "headline": str(x.get("text") or "")[:160], "text": x.get("text"), "created": t, "updated": t, "expires": t + 24 * 3600,
                        "ext_id": "TL:%s:%s:%d" % (x.get("id"), x.get("k"), t)})
        except Exception as e:
            print("sdr_manager Technik-Verlauf:", e, flush=True)
    return out


def fu_sync(sy, new_rows, now):
    """Aus Sync.tick: Grenzwert-Ereignisse aus neuen Messungen + Technik-Verlauf. -> Anzahl neuer Ereignisse."""
    n = 0
    try:
        c = fu_thr_cfg(sy.base)
        if _FU["thr"] is None:
            r = db.state_get("funkui_thr", sy.path) if hasattr(db, "state_get") else {"ok": False}
            try:
                _FU["thr"] = json.loads(r["text"]) if r.get("ok") else {}
            except Exception:
                _FU["thr"] = {}
        if new_rows:
            before = json.dumps(_FU["thr"], sort_keys=True)
            for e in fu_thr_eval(new_rows, _FU["thr"], c):
                n += 1 if db.upsert_event(e, sy.path) else 0
            if json.dumps(_FU["thr"], sort_keys=True) != before and hasattr(db, "state_put"):
                db.state_put("funkui_thr", json.dumps(_FU["thr"]), now, sy.path, writer="dashboard")
        fn = os.path.join(sy.base, "sdr_techlog.json")
        try:
            mt = os.path.getmtime(fn)
        except Exception:
            mt = None
        if mt and mt != _FU["tl_mt"]:
            ok = True
            for e in events_from_techlog(_load_json(fn, {}), now):
                if db.upsert_event(e, sy.path):
                    n += 1
                elif db.last_error():
                    ok = False
            if ok:
                _FU["tl_mt"] = mt
    except Exception as e:
        print("sdr_manager funkUI:", e, flush=True)
    return n


def selftest_funkui():
    import tempfile
    d = tempfile.mkdtemp(prefix="lzfu-")
    p = os.path.join(d, "lagezentrum.db")
    assert db.migrate(p)
    now = int(time.time())
    _FU_LIVE.update(alive_t=None, hb_ok_t=None, hb_fail_t=None, act=None, act_t=None)
    fs = os.path.join(d, "sdr_status.json")
    with open(fs, "w") as f:
        json.dump({"t": now, "pid": os.getpid()}, f)
    # 1) Lebenszeichen: ohne DB-Problem wie bisher (keine Telemetrie = offline)
    assert live(d, p, now=now)["status"] == "SDR_OFFLINE"
    # eigener DB-Schreibfehler (gesperrt) -> nicht offline, Quelle Speicher
    fu_hb_note({"ts": now}, False, now)
    r = live(d, p, now=now)
    assert r["status"] != "SDR_OFFLINE" and r["watchdog"]["src"] == "speicher" and "Speicher" in r["watchdog"]["note_mem"], r
    # Status-Datei alt (Notkopie), aber letztes sicheres Lebenszeichen < 120 s -> lebt
    with open(fs, "w") as f:
        json.dump({"t": now - 400, "pid": os.getpid()}, f)
    assert live(d, p, now=now + 60)["status"] != "SDR_OFFLINE"
    assert live(d, p, now=now + FU_LIVE_GRACE_S + 5)["status"] == "SDR_OFFLINE"        # zu lange: ehrlich offline
    # prepper-sdr tot (pid weg) -> sofort offline, auch bei DB-Sperre
    with open(fs, "w") as f:
        json.dump({"t": now, "pid": 999999999}, f)
    assert live(d, p, now=now + 5)["status"] == "SDR_OFFLINE"
    # Schreiben wieder ok -> wieder normale DB-Pruefung
    with open(fs, "w") as f:
        json.dump({"t": now, "pid": os.getpid()}, f)
    fu_hb_note({"ts": now + 10}, True, now + 10)
    assert live(d, p, now=now + 30)["status"] == "SDR_OFFLINE" and "src" not in live(d, p, now=now + 30)["watchdog"]
    # echte Sperre: Schreib-Transaktion offen -> Sync.tick schreibt kein hb, live bleibt lebendig (DB lesbar, WAL)
    _FU_LIVE.update(alive_t=None, hb_ok_t=None, hb_fail_t=None)
    import sqlite3
    old_to = db.TIMEOUT_S
    lk = sqlite3.connect(p, timeout=1)
    try:
        db.TIMEOUT_S = 0.3
        lk.execute("BEGIN IMMEDIATE")
        lk.execute("INSERT INTO telemetry(ts, kind, serial, channel, src_t) VALUES(1, 'x', 'x', 'x', 1)")
        sy = Sync(d, p)
        sy.last_clean = 10 ** 12
        sy.tick({}, now=now + 40, min_s=0, force=True)
        assert _FU_LIVE["hb_fail_t"] == now + 40 and db.newest_telemetry(path=p) is None
        r = live(d, p, now=now + 41)
        assert r["status"] != "SDR_OFFLINE" and r["watchdog"]["src"] == "speicher", r
    finally:
        lk.rollback()
        lk.close()
        db.TIMEOUT_S = old_to
    sy.tick({}, now=now + 60, min_s=0, force=True)
    assert _FU_LIVE["hb_ok_t"] == now + 60 and live(d, p, now=now + 61)["status"] == "OK"
    # aktive Ereignisse bei Lesefehler aus dem Speicher (echter ASA-Alarm bleibt sichtbar)
    assert db.upsert_event({"source": "ASA", "ext_id": "fu1", "severity": "warn", "headline": "Gefahr", "text": "Gefahr", "updated": now, "expires": now + 3600}, p)
    assert live(d, p, now=now + 62)["status"] == "ECHTALARM"
    real = db.active_events
    try:
        def broken(*a, **k):
            db._log("Abfrage:", "database is locked")
            return []
        db.active_events = broken
        assert fu_active(now + 63, p) and fu_active(now + 63 + FU_ACT_KEEP_S + 5, p) == []
    finally:
        db.active_events = real
    # 2) SNR/FIC-Grenzen: Standard, Konfiguration, Hysterese, N in Folge
    c = fu_thr_cfg(d)
    assert c["tech_snr_low_db"] == 5.0 and c["tech_fic_bad"] == 0.10 and c["src"]["tech_thr_n"] == "Standard", c
    st = {}
    row = lambda ts, snr, ber: {"ts": ts, "channel": "11D", "snr": snr, "ber": ber, "mast": "Bayern · 11D"}
    assert fu_thr_eval([row(1, 4.0, 0.01)], st, c) == []                       # 1 Messung schlecht: noch nichts
    ev = fu_thr_eval([row(2, 3.5, 0.2)], st, c)
    assert [e["type"] for e in ev] == ["snr_bad"] and "SNR niedrig: 3,5 dB" in ev[0]["headline"] and ev[0]["severity"] == "info", ev
    ev = fu_thr_eval([row(3, 6.0, 0.05), row(4, 6.5, 0.05)], st, c)            # 6 dB / 5 %: Hysterese-Band (weder schlecht noch gut)
    assert ev == [], ev
    ev = fu_thr_eval([row(5, 8.0, 0.2), row(6, 9.0, 0.3)], st, c)
    assert [e["type"] for e in ev] == ["snr_ok", "fic_bad"], ev
    assert any("FIC-Fehlerrate hoch: 30,0 %" in e["headline"] for e in ev)
    with open(os.path.join(d, "sdr_config.json"), "w") as f:
        json.dump({"tech_snr_low_db": 8, "tech_thr_n": 1, "tech_fic_ok": 0.5}, f)
    c2 = fu_thr_cfg(d)
    assert c2["tech_snr_low_db"] == 8.0 and c2["tech_snr_ok_db"] == 8.0 and c2["tech_thr_n"] == 1 and c2["tech_fic_ok"] == 0.10 and c2["src"]["tech_snr_low_db"] == "sdr_config.json"
    assert "SNR niedrig unter 8 dB" in fu_thr_text(c2)
    os.remove(os.path.join(d, "sdr_config.json"))
    # 3) Technik-Verlauf -> Ereignisse (Teil-2-Kopien ausgelassen), Sync schreibt Grenzwert-Ereignisse + Zustand
    tl = {"ev": [{"id": 1, "t": now, "k": "sync_lost", "cat": "tech", "text": "DAB 5C Sync verloren"},
                 {"id": 2, "t": now, "k": "takeover_on", "cat": "stick", "text": "Stick 2 Übernahme"},
                 {"id": 3, "t": now, "k": "fig09", "cat": "tech", "text": "x", "ref": "T2:1"}, {"id": 4, "t": now, "k": "meteor", "cat": "meteor", "text": "M"},
                 {"id": 5, "t": now, "k": "mast_new", "cat": "tech", "text": "DAB 11D Mast erstmals: X"}]}
    ev = events_from_techlog(tl, now)
    assert [(e["source"], e["type"]) for e in ev] == [("DAB", "sync_lost"), ("SDR", "takeover_on"), ("METEOR", "meteor")], ev
    with open(os.path.join(d, "sdr_techlog.json"), "w") as f:
        json.dump(tl, f)
    with open(os.path.join(d, "broadcast_state.json"), "w") as f:
        json.dump({"dab": {"11D": {"ensemble": "Bayern", "demod": {"t": now + 100, "snr": 2.0, "fic_rate": 0.01, "sn": "1"}}}}, f)
    _FU.update(thr=None, tl_mt=None)
    sy = Sync(d, p)
    sy.last_clean = 10 ** 12
    sy.tick({}, now=now + 100, min_s=0, force=True)
    with open(os.path.join(d, "broadcast_state.json"), "w") as f:
        json.dump({"dab": {"11D": {"ensemble": "Bayern", "demod": {"t": now + 130, "snr": 2.5, "fic_rate": 0.01, "sn": "1"}}}}, f)
    sy.tick({}, now=now + 130, min_s=0, force=True)
    hs = [e["headline"] for e in db.recent_events(20, p)]
    assert any(h.startswith("DAB 11D SNR niedrig: 2,5 dB") for h in hs) and "Stick 2 Übernahme" in hs and "DAB 5C Sync verloren" in hs, hs
    assert json.loads(db.state_get("funkui_thr", p)["text"])["11D|snr"]["lvl"] == "bad"
    _FU["thr"] = None                                                              # Neustart: Zustand aus der DB, kein Doppel
    with open(os.path.join(d, "broadcast_state.json"), "w") as f:
        json.dump({"dab": {"11D": {"ensemble": "Bayern", "demod": {"t": now + 160, "snr": 2.0, "fic_rate": 0.01, "sn": "1"}}}}, f)
    sy.tick({}, now=now + 160, min_s=0, force=True)
    assert sum(1 for e in db.recent_events(30, p) if "SNR niedrig" in (e["headline"] or "")) == 1
    h = t4_history(p, 10)
    assert any(x["src"] == "SDR" and x["color"] == "#f97316" for x in h), h
    _FU_LIVE.update(alive_t=None, hb_ok_t=None, hb_fail_t=None, act=None, act_t=None)
    _FU.update(cfg=None, cfg_k=None, thr=None, tl_mt=None)
    return "sdr_manager selftest funkUI ok (DB-Sperre -> Lebenszeichen aus Speicher statt SDR_OFFLINE, prepper-sdr tot/zu alt -> ehrlich offline, aktive Alarme aus Speicher, SNR/FIC-Grenzen mit Hysterese + N in Folge, sdr_config-Grenzen, Technik-Verlauf -> Ereignisse ohne Doppel)"
FUS_EOF
EXPECT_BDA="08f044cfae4390b5ab970fd9ac7cec69faa773ff75cb097db2a7b3580f26a83d"
cat > "$W/fu_dash_block.py" << 'FUD_EOF'
# ===== funkUI: /funk Funk-Lage + Steuerung + Meteor-Kachel, /dabhist Karten + Technik, /meteor Galerie mit Vorschaubildern; nur Anzeige, sendet nichts =====
import os as _fu_os, re as _fu_re, time as _fu_time, json as _fu_json, html as _fu_html
_FU = {"err": None, "selftest": None}
_FU_CAT = {"warn": ("Warnungen/ASA", "#ef4444", "warn", "WARNUNG"), "tech": ("Technik", "#60a5fa", "tech", "TECHNIK"),
           "stick": ("Stick 2", "#f97316", "stick", "STICK 2"), "rx": ("Empfang", "#eab308", "rx", "EMPFANG"),
           "prog": ("Programm-Infos", "#64748b", "aus", "PROGRAMM")}
_FU_CAT_DEF = ("warn", "tech", "stick", "rx")              # Programm-Infos standardmaessig aus
_FU_ASA_RE = _fu_re.compile(r"\bASA\b", _fu_re.I)
_FU_RX_TYPES = ("snr_bad", "snr_ok", "fic_bad", "fic_ok")
_FU_WD = ("Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag")

_FU_CSS = r"""#t2Tile,#t4Sdr{display:none!important}
#fuLage,#fuSteuer,#fuMeteor,#sdrUiCard,#t4Hist,#stickTestCard{grid-column:1/-1;min-width:0;max-width:100%;box-sizing:border-box}
.fu-hd{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px;min-width:0}
.fu-hd .title{margin:0!important}
.fu-pill{display:inline-block;flex:0 0 auto;font-size:.72rem;font-weight:700;letter-spacing:.04em;line-height:1.2;padding:3px 9px;border-radius:999px;border:1px solid #475569;white-space:nowrap;color:#94a3b8;background:#1e293b}
.fu-pill.ok{color:#22c55e;background:#052e1a;border-color:#166534}
.fu-pill.info,.fu-pill.tech{color:#60a5fa;background:#0b1e3a;border-color:#1e40af}
.fu-pill.probe,.fu-pill.gelb,.fu-pill.lernt,.fu-pill.rx{color:#eab308;background:#3a2a05;border-color:#a16207}
.fu-pill.pre,.fu-pill.offline,.fu-pill.stick{color:#fb923c;background:#3b1a06;border-color:#c2410c}
.fu-pill.alarm,.fu-pill.rot,.fu-pill.warn{color:#f87171;background:#3f1d1d;border-color:#7f1d1d}
.fu-pill.blink{animation:fu-blink 1s infinite}
@keyframes fu-blink{0%,49%{opacity:1}50%,100%{opacity:.4}}
.fu-sum{font-size:1rem;line-height:1.35;margin:2px 0 8px;overflow-wrap:anywhere}
.fu-kv{display:grid;grid-template-columns:minmax(86px,32%) minmax(0,1fr);gap:5px 10px;font-size:.9rem;line-height:1.35}
.fu-kv .k{color:#94a3b8}
.fu-kv .v{min-width:0;overflow-wrap:anywhere}
.fu-note{font-size:.8rem;color:#64748b;margin-top:8px;overflow-wrap:anywhere;line-height:1.35}
.fu-btn,#fuSteuer .su-go,#fuSteuer .su-back,#fuSteuer button.su-bd{display:flex;align-items:center;justify-content:center;width:100%;min-height:44px;margin:10px 0 0;padding:10px 14px;border-radius:10px;font-size:1rem;font-weight:600;line-height:1.2;border:1px solid #334155;background:#1e3a5f;color:#93c5fd;cursor:pointer;-webkit-tap-highlight-color:transparent;touch-action:manipulation;transition:transform .06s,filter .06s;box-sizing:border-box;text-align:center;opacity:1;font-family:inherit}
.fu-btn.danger{background:#3f1d1d;color:#fca5a5;border-color:#7f1d1d}
.fu-btn.neutral,#fuSteuer button.su-bd,#fuSteuer .su-back{background:transparent;color:#e2e8f0;border-color:#475569}
.fu-btn:active,#fuSteuer button:active,#sdrUiCard button:active,#stickTestCard button:active{transform:scale(.97);filter:brightness(1.3)}
.fu-btn:disabled,#fuSteuer button:disabled,#stickTestCard button:disabled{opacity:.45!important;cursor:default;transform:none;filter:none}
.fu-btn.busy{opacity:.7;pointer-events:none}
.fu-res{font-size:.85rem;min-height:1.1em;margin-top:6px;overflow-wrap:anywhere;color:#cbd5e1}
.fu-res.ok{color:#4ade80}.fu-res.err{color:#fca5a5}
.fu-link{display:flex;align-items:center;justify-content:space-between;gap:8px;min-height:44px;padding:0 2px;margin-top:8px;border-top:1px solid #334155;color:#93c5fd!important;text-decoration:none!important;font-size:.95rem;-webkit-tap-highlight-color:transparent}
.fu-link:after{content:"\203A";font-size:1.5rem;line-height:1;color:#64748b}
.fu-link:active{background:#0f172a}
.fu-link+.fu-link{margin-top:0}
details.fu-dt>summary{list-style:none;display:flex;align-items:center;gap:8px;min-height:44px;cursor:pointer;-webkit-tap-highlight-color:transparent}
details.fu-dt>summary::-webkit-details-marker{display:none}
details.fu-dt>summary .title{margin:0!important;flex:0 0 auto}
details.fu-dt>summary .fu-ss{flex:1 1 auto;min-width:0;font-size:.82rem;color:#94a3b8;overflow-wrap:anywhere}
details.fu-dt>summary:after,.fu-coll>.title:after{content:"\25BE";flex:0 0 auto;margin-left:auto;font-size:1.1rem;color:#94a3b8;transition:transform .15s}
details.fu-dt[open]>summary:after,.fu-coll:not(.fu-closed)>.title:after{transform:rotate(180deg)}
.fu-sec{border-top:1px solid #334155;padding:10px 0 6px;margin-top:4px}
.fu-st{font-size:.72rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.06em;margin-bottom:2px}
.fu-hint{font-size:.8rem;color:#94a3b8;margin-top:4px;overflow-wrap:anywhere}
#fuSteuer .sl-prof{display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin:6px 0 0!important}
#fuSteuer .sl-prof .sl-pn{grid-column:1/-1;font-size:.82rem;color:#94a3b8;opacity:1}
#fuSteuer .sl-prof .sl-pn:first-child{display:none}
#fuSteuer .sl-prof button,#fuSteuer .su-seg button,#stickTestCard .stk-bar button,#sdrUiCard .sl-sw button{font-family:inherit}
#fuSteuer .sl-prof button,#fuSteuer .su-seg button{min-height:44px;font-size:.95rem!important;padding:6px 8px!important;border-radius:10px!important;border:1px solid #475569!important;background:#1e293b;color:#e2e8f0;cursor:pointer;-webkit-tap-highlight-color:transparent;touch-action:manipulation;overflow-wrap:anywhere}
#fuSteuer .sl-prof button.on,#fuSteuer .su-seg button.on{background:#0369a1!important;border-color:#0ea5e9!important;color:#fff;font-weight:700}
#fuSteuer .su-seg{display:grid!important;grid-template-columns:repeat(auto-fit,minmax(96px,1fr));gap:8px;border:0!important;width:auto!important;max-width:100%;margin:6px 0 0!important;overflow:visible!important}
#fuSteuer .su-help{font-size:.82rem;color:#94a3b8;margin:6px 0 0}
#fuSteuer fieldset{border:1px solid #334155;border-radius:10px;padding:8px 10px 10px;margin:0;min-width:0}
#fuSteuer legend{font-size:.82rem;color:#94a3b8;padding:0 4px}
#fuSteuer .su-man{display:grid!important;grid-template-columns:minmax(0,1fr) 104px;gap:8px}
#fuSteuer .su-man select{min-height:44px;font-size:1rem;background:#0f172a;color:#e2e8f0;border:1px solid #475569;border-radius:10px;width:100%;min-width:0;padding:0 8px;box-sizing:border-box}
#fuSteuer .su-man .su-go{grid-column:1/-1;margin:0}
#fuSteuer .su-act{display:block!important;margin-top:8px;font-size:.9rem;overflow-wrap:anywhere}
#fuSteuer .su-act b{color:#7dd3fc}
#fuSteuer .su-msg{font-size:.85rem;color:#cbd5e1;margin-top:6px;min-height:1em;overflow-wrap:anywhere}
#sdrUiCard .su-head{white-space:normal!important;flex-wrap:wrap;overflow:visible!important}
#sdrUiCard .su-head .su-tt{font-size:.75rem!important;color:#94a3b8;text-transform:uppercase;letter-spacing:.06em;font-weight:400!important}
#sdrUiCard .su-head .su-st{white-space:normal!important;overflow:visible!important;font-size:.85rem}
#sdrUiCard .su-chips{grid-template-columns:repeat(auto-fill,minmax(148px,1fr))!important;gap:8px!important}
#sdrUiCard .su-chip{cursor:pointer!important;padding:8px!important;border-radius:10px!important;-webkit-tap-highlight-color:transparent}
#sdrUiCard .su-chip.fu-open{border-color:#64748b}
#sdrUiCard .su-chip .su-l1{white-space:normal!important;flex-wrap:wrap!important;row-gap:4px;overflow:visible!important}
#sdrUiCard .su-chip .su-nm{flex:1 1 auto!important;min-width:0!important;white-space:normal!important;overflow:visible!important;text-overflow:clip!important;overflow-wrap:anywhere}
#sdrUiCard .su-chip .su-l2{white-space:normal!important;overflow:visible!important}
#sdrUiCard .fu-cd{white-space:pre-line;font-size:.8rem;color:#cbd5e1;margin-top:6px;padding-top:6px;border-top:1px dashed #334155;overflow-wrap:anywhere;cursor:default}
#sdrUiCard .sl-sw{display:grid!important;grid-template-columns:repeat(3,minmax(0,1fr));width:100%!important;max-width:100%!important;margin-top:8px!important;border-radius:8px!important}
#sdrUiCard .sl-sw button{min-height:44px;font-size:.78rem!important;padding:0 2px!important;-webkit-tap-highlight-color:transparent;touch-action:manipulation}
#sdrUiCard .su-i{display:none!important}
#sdrUiCard .su-rows{gap:2px!important}
#sdrUiCard .su-row{white-space:normal!important;overflow:visible!important;align-items:flex-start!important;flex-wrap:nowrap;min-height:30px;padding:4px 0;border-top:1px solid #1e293b}
#sdrUiCard .su-row .su-dot{margin-top:.3em}
#sdrUiCard .su-row .su-v{white-space:normal!important;overflow:visible!important;text-overflow:clip!important;overflow-wrap:anywhere;min-width:0}
#sdrUiCard .su-row a.su-v{color:#93c5fd!important;text-decoration:none}
#sdrUiCard .su-row a.su-v:after{content:" \203A";color:#64748b}
#sdrUiCard .fu-more{flex:0 0 auto;margin:-8px -6px -8px auto;min-width:44px;min-height:44px;background:transparent;border:0;color:#94a3b8;font-size:1rem;cursor:pointer}
#sdrUiCard .fu-rd{flex-basis:100%;white-space:pre-line;font-size:.8rem;color:#cbd5e1;padding:2px 0 4px 16px;overflow-wrap:anywhere}
#sdrUiCard .su-row.fu-ropen{flex-wrap:wrap}
#t4Hist .t4-l{white-space:normal!important;overflow:visible!important;text-overflow:clip!important;overflow-wrap:anywhere;border-left:3px solid currentColor;padding:2px 0 2px 8px;margin-top:6px!important;line-height:1.35;font-size:.85rem}
.fu-coll>.title{display:flex!important;align-items:center;gap:8px;min-height:44px;margin:-8px 0 0!important;cursor:pointer;-webkit-tap-highlight-color:transparent}
#stickTestCard.fu-closed>*:not(.title):not(.fu-csum){display:none!important}
#stickTestCard:not(.fu-closed)>.fu-csum{display:none}
.fu-csum{font-size:.85rem;color:#94a3b8;overflow-wrap:anywhere}
#stickTestCard .stk-bar{gap:8px!important}
#stickTestCard .stk-bar button{min-height:44px;font-size:.95rem!important;padding:0 14px!important;border-radius:10px!important;flex:1 1 140px}
#fuMeteor .fu-mimg{display:block;margin:4px 0 8px;border-radius:10px;overflow:hidden;background:#0f172a;-webkit-tap-highlight-color:transparent}
#fuMeteor .fu-mimg img{display:block;width:100%;height:auto;max-height:360px;object-fit:cover}"""
_FU_JS = r"""(function(){
var D4=null,D2=null,DM=null,OPEN={},ROPEN={},SIG='',MSIG='',OBS=null,HOBS=null,BUSY=0;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined&&x!==null)e.textContent=x;return e;}
function J(id){try{return JSON.parse(document.getElementById(id).textContent);}catch(e){return null;}}
function strip(s){return String(s||'').replace(/^[^0-9A-Za-z\u00c4\u00d6\u00dc\u00e4\u00f6\u00fc\u00df(+]+/,'').trim();}
function p2(x){return (x<10?'0':'')+x;}
function fmt(t){if(!t)return '\u2013';var d=new Date(t*1000);return p2(d.getDate())+'.'+p2(d.getMonth()+1)+'. '+p2(d.getHours())+':'+p2(d.getMinutes());}
function hm(t){var d=new Date(t*1000);return p2(d.getHours())+':'+p2(d.getMinutes());}
function n(v,d){return (v===null||v===undefined)?'\u2013':Number(v).toFixed(d).replace('.',',');}
/* ---- Klarnamen: Name · MM/SS aus MASTS_DB (/api/t2/status masts), sonst unbekannt · MM/SS ---- */
var TRE=/(\s*)([^:;]*?) ?MainID (\d{2}) \/ SubID (\d{2})(?: \(([^()]*)\))?/g;
function mname(ch,code){var ms=(D2&&D2.masts)||{},m=ms[ch||'11D']||{},t=m.tii||[];for(var i=0;i<t.length;i++){if(t[i]&&p2(t[i].main)+'/'+p2(t[i].sub)===code)return t[i].mast||null;}return null;}
function tlab(ch,code,fb){return (mname(ch,code)||fb||'unbekannt')+' \u00b7 '+code;}
function tfix(s,ch){s=String(s==null?'':s);if(s.indexOf('MainID')<0&&s.indexOf('TII-Wechsel')<0&&s.indexOf('TII erstmals')<0)return s;try{var m0=/\bDAB (\w+)/.exec(s);ch=ch||(m0?m0[1]:'11D');
var w=/^(.*?\bDAB (\w+) TII(?:-Wechsel| erstmals): )(.*?)(?: -> (.*?))?(?: \((.*)\))?$/.exec(s);
if(w){var par={};(w[5]||'').split('; ').forEach(function(sg){var m=/^([^:;]*?) ?MainID (\d{2}) \/ SubID (\d{2})(?: \(([^()]*)\))?$/.exec(sg.trim());if(m&&m[1].trim()&&(m[4]||'').indexOf('nicht in MASTS_DB')<0)par[m[2]+'/'+m[3]]=m[1].trim();});
var lst=function(x){var cs=x.split(',').map(function(c){return c.trim();}).filter(Boolean);if(!cs.length||!cs.every(function(c){return /^\d{2}\/\d{2}$/.test(c);}))return x;return cs.map(function(c){return tlab(w[2],c,par[c]);}).join(', ');};
return w[1]+lst(w[3])+(w[4]!==undefined?' -> '+lst(w[4]):'');}
return s.replace(TRE,function(a,sp,nm,x,y,pp){var fb=(pp||'').indexOf('nicht in MASTS_DB')>=0?null:(nm.trim()||null);return sp+tlab(ch,x+'/'+y,fb);});}catch(e){return s;}}
function tfixNode(root){if(!root||!document.createTreeWalker)return;var tw=document.createTreeWalker(root,4,null),x,a=[];while((x=tw.nextNode()))if(/MainID|TII-Wechsel|TII erstmals/.test(x.nodeValue))a.push(x);
for(var i=0;i<a.length;i++){var v=tfix(a[i].nodeValue,null);if(v!==a[i].nodeValue)a[i].nodeValue=v;}}
function tele(x){x=x||{};return 'RSSI '+(x.rssi==null?'\u2013':n(x.rssi,1)+' dBm')+' \u00b7 BER (FIC) '+n(x.fic_rate,4)+' \u00b7 SNR '+n(x.snr,1)+' dB'+(x.age_s!=null?' \u00b7 vor '+(x.age_s<120?x.age_s+' s':Math.round(x.age_s/60)+' min'):'');}
function pill(cls,txt,blink){return el('span','fu-pill '+cls+(blink?' blink':''),txt);}
function head(card,title,pl){var h=card.querySelector(':scope>.fu-hd');if(!h){h=el('div','fu-hd');h.appendChild(el('div','title',title));card.insertBefore(h,card.firstChild);}
var o=h.querySelector('.fu-pill');if(o)o.remove();if(pl)h.appendChild(pl);return h;}
function kv(box,k,v,col,bold){box.appendChild(el('div','k',k));var x=el('div','v',v);if(col)x.style.color=col;if(bold)x.style.fontWeight='600';box.appendChild(x);return x;}
function link(box,href,txt){var a=el('a','fu-link',txt);a.href=href;box.appendChild(a);return a;}
function grid(){var a=document.getElementById('sdrUiCard')||document.getElementById('t4Hist')||document.getElementById('stickTestCard');return a?a.parentNode:null;}
function place(c){var g=grid();if(g&&c.parentNode!==g){var s=document.getElementById('stickTestCard');if(s&&s.parentNode===g)g.insertBefore(c,s);else g.appendChild(c);}}
/* Reihenfolge: Funk-Lage, Empfaenger, Steuerung, Meteor, (verborgene Alt-Kacheln), Historie, Antennentest. Die Alt-Kacheln haengen sich selbst hintereinander (t2Tile > t4Sdr > t4Hist). */
var SEQ=['fuLage','sdrUiCard','fuSteuer','fuMeteor','t2Tile','t4Sdr','t4Hist'];
function order(){var g=grid();if(!g)return;var i,prev=null;
var all=SEQ.map(function(k){var e=document.getElementById(k);return e&&e.parentNode===g?e:null;}).filter(Boolean);if(!all.length)return;
var first=all[0];for(i=1;i<all.length;i++)if(all[i].compareDocumentPosition(first)&4)first=all[i];
if(all[0]!==first)g.insertBefore(all[0],first);prev=all[0];for(i=1;i<all.length;i++){after(all[i],prev);prev=all[i];}}
function card(id){var c=document.getElementById(id);if(!c){c=el('div','card full');c.id=id;}return c;}
function before(c,ref){if(ref&&ref.parentNode&&(c.parentNode!==ref.parentNode||c.nextSibling!==ref))ref.parentNode.insertBefore(c,ref);}
function after(c,ref){if(ref&&ref.parentNode&&(c.parentNode!==ref.parentNode||ref.nextSibling!==c))ref.parentNode.insertBefore(c,ref.nextSibling);}
/* ---- Proxy-Knoepfe: Klick an den bestehenden Knopf (gleiche Bestaetigung, gleiche Kopfzeilen, gleicher Weg) ---- */
function proxy(box,key){var b=box.querySelector('button[data-fu="'+key+'"]');if(!b){b=el('button','fu-btn');b.type='button';b.dataset.fu=key;
b.addEventListener('click',function(){var o=orig(key);if(o&&!o.disabled)o.click();});box.appendChild(b);var r=el('div','fu-res');r.dataset.fu=key;box.appendChild(r);}return b;}
function orig(key){var t=document.getElementById(key==='fr'?'t4Sdr':'t2Tile');if(!t)return null;return key==='b1'?t._b1:(key==='b2'?t._b2:t._b);}
function syncProxy(key,danger){var b=document.querySelector('button[data-fu="'+key+'"]');if(!b)return;var o=orig(key);var r=b.nextSibling;
if(!o){b.style.display='none';return;}var tx=strip(o.textContent);if(b.textContent!==tx)b.textContent=tx;var hid=o.style.display==='none'||!tx;b.style.display=hid?'none':'';
b.disabled=!!o.disabled;b.classList.toggle('danger',!!danger);var t=document.getElementById(key==='fr'?'t4Sdr':'t2Tile');var st=t&&t._st?t._st.textContent:'';
b.classList.toggle('busy',st==='\u2026');if(r&&r.classList.contains('fu-res')){if(r.textContent!==st)r.textContent=st;r.className='fu-res'+(/^erledigt/.test(st)?' ok':(/^nicht erledigt/.test(st)?' err':''));if(hid&&key!=='b2'&&key!=='b1')r.textContent='';}}
/* ---- Funk-Lage (Sticks & Alarm-Automatik + SDR-Status zusammen) ---- */
var LV={ok:['ok','OK'],probe:['probe','PROBE'],alarm:['alarm','ALARM'],pre:['pre','VORALARM'],offline:['offline','OFFLINE']};
function lage(){var c=card('fuLage');place(c);
if(!D4&&!D2){if(!c.firstChild){head(c,'Funk-Lage',pill('aus','\u2026'));}return;}
var sig=JSON.stringify([D4&&D4.level,D4&&D4.sdr,D4&&D4.pre,D4&&D4.release,D4&&D4.tr,D2&&D2.takeover,D2&&D2.roles,D2&&D2.asa,D2&&(D2.fig||{})['11D'],D2&&D2.autosend,D2&&D2.alarms]);
if(sig!==SIG||!c.querySelector('.fu-kv')){SIG=sig;var lv=(D4&&D4.level)||{},m=LV[lv.lvl]||['aus',lv.label||'?'];
head(c,'Funk-Lage',pill(m[0],m[1],lv.blink));var s=c.querySelector('.fu-sum');if(!s){s=el('div','fu-sum');c.appendChild(s);}s.textContent=(lv.label||'')+(lv.why?' \u2013 '+lv.why:'');
var old=c.querySelector('.fu-kv');var box=el('div','fu-kv');
var sd=(D4&&D4.sdr)||{},s1=sd.s1||{},s2=sd.s2||{},to=(D2&&D2.takeover)||{},r=(D2&&D2.roles)||{},a=(D2&&D2.asa)||{},f=((D2&&D2.fig)||{})['11D']||{},as=(D2&&D2.autosend)||{},pre=(D4&&D4.pre)||{},rl=(D4&&D4.release)||{},tr=(D4&&D4.tr)||null;
kv(box,'Stick 1',(s1.sn?'SN '+s1.sn+' \u00b7 ':'')+((r.s1||{}).mode||'')+(s1.state?' \u00b7 '+s1.state:'')+(s1.f_mhz?' \u00b7 '+n(s1.f_mhz,3)+' MHz':''),null,true);
kv(box,'Empfang 1',tele(s1),'#cbd5e1');
var ti=(f.tii||[]).map(function(x){var c=p2(x.main)+'/'+p2(x.sub);return (x.mast&&!mname('11D',c))?tfix(x.mast,'11D'):tlab('11D',c,null);}).join(', ');
kv(box,'11D',(f.ens||'\u2013')+(f.ecc?' \u00b7 ECC '+f.ecc:'')+(f.lto!=null?' \u00b7 LTO '+(f.lto>=0?'+':'')+f.lto+' h':'')+' \u00b7 TII '+(ti||'\u2013')+(f.t?' \u00b7 '+fmt(f.t):''),'#cbd5e1');
kv(box,'Stick 2',to.on?('ALARM \u2013 fest auf 5C seit '+fmt(to.since)+' ('+(to.src||'?')+((to.why_txt||to.why)?': '+(to.why_txt||to.why):'')+')'):((s2.sn?'SN '+s2.sn+' \u00b7 ':'')+(s2.state||'')+(((r.s2||{}).mode)?' \u00b7 '+r.s2.mode:'')+(to.end_t?' \u00b7 \u00dcbernahme aus seit '+fmt(to.end_t):'')),
 to.on?(s2.fb?'#fb923c':'#f87171'):'#4ade80',true);
if(to.on||s2.takeover)kv(box,'Empfang 2',tele(s2)+(s2.fb?' \u00b7 5C ohne Sync, R\u00fcckfall 10C, 5C-Versuch alle '+Math.round((s2.retry_s||600)/60)+' min':''),s2.fb?'#fb923c':'#cbd5e1');
kv(box,'ASA-Dienst',(a.status||'\u2013')+(a.text?' \u00b7 '+a.text:''),a.status==='ASA_INTERRUPTED'?'#f87171':null);
kv(box,'Vor-Alarm',pre.on?('VORALARM '+(pre.kinds||[]).join('+')+' seit '+fmt(pre.since)+': '+(pre.why||'')):'kein Vor-Alarm (DSL/Netzfrequenz)',pre.on?'#fb923c':null);
if(pre.on)kv(box,'Freigabe',(rl.ok?'m\u00f6glich':'gesperrt')+' \u2013 '+(rl.why||''),rl.ok?'#4ade80':'#fdba74');
kv(box,'Auto-Versand','Mesh 1 '+(as.on?'AN':'AUS')+(as.hour_n!=null?' \u00b7 letzte Stunde '+as.hour_n+'/'+as.limit_h:'')+((as.recent&&as.recent[0])?' \u00b7 zuletzt '+fmt(as.recent[0].last_try)+' '+(as.recent[0].ok===1?'ok':'FEHLER'):''),as.on?'#4ade80':null);
var real=((D2&&D2.alarms)||[]).filter(function(x){return x.real;});kv(box,'Alarm',real.length?('Echter Alarm: '+real[0].src+' \u2013 '+real[0].text):'kein echter Alarm',real.length?'#f87171':null,!!real.length);
if(tr)kv(box,'Datenquelle',tr.line||'',tr.ok?'#94a3b8':'#fdba74');
if(old)c.replaceChild(box,old);else c.appendChild(box);
var nt=c.querySelector('.fu-note');if(!nt){nt=el('div','fu-note');box.parentNode.insertBefore(nt,box.nextSibling);}nt.textContent=sd.ber_note||'';nt.style.display=sd.ber_note?'':'none';
var pb=c.querySelector('.fu-pbox');if(!pb){pb=el('div','fu-pbox');c.appendChild(pb);proxy(pb,'fr');link(c,'/karte','Karte: Masten, Funkhorizont, Gefahrenzonen');link(c,'/dabhist','DAB-Meldungen und Technik-Verlauf');}}
syncProxy('fr',false);}
/* ---- Steuerung (eingeklappt): Stick-2-Alarm, Auto-Versand, Lage-Profil, Betriebsart, Einzelempfang, Stick freigeben ---- */
var SLOTS=[['s2','Stick 2 \u2013 Alarm 5C (ASA DE)'],['as','Auto-Versand echter Alarme an Mesh 1'],['prof','Lage-Profil'],['mode','Betriebsart'],['man',null],['rel','Stick freigeben']];
function steuer(){var c=card('fuSteuer');place(c);
var d=c.querySelector('details');if(!d){d=el('details','fu-dt');var sm=el('summary');sm.appendChild(el('span','title','Steuerung'));sm.appendChild(el('span','fu-ss',''));d.appendChild(sm);
SLOTS.forEach(function(s){var x=el('div','fu-sec');x.dataset.slot=s[0];if(s[1])x.appendChild(el('div','fu-st',s[1]));var b=el('div','fu-sb');x.appendChild(b);d.appendChild(x);});c.appendChild(d);
proxy(d.querySelector('[data-slot=s2] .fu-sb'),'b1');proxy(d.querySelector('[data-slot=as] .fu-sb'),'b2');
d.querySelector('[data-slot=s2]').appendChild(el('div','fu-hint','R\u00fcckgabe nur \u00fcber diesen Knopf; jede Umschaltung wird vorher best\u00e4tigt.'));}
var to=(D2&&D2.takeover)||{};syncProxy('b1',!to.on);syncProxy('b2',false);
var pr=d.querySelector('[data-slot=prof] .sl-prof button.on'),mo=d.querySelector('[data-slot=mode] .su-seg button.on');
var ss=(to.on?'Stick 2 ALARM 5C \u00b7 ':'')+'Lage '+(pr?pr.textContent:'\u2013')+' \u00b7 '+(mo?mo.textContent:'Einzelempfang/\u2013');var se=d.querySelector('.fu-ss');if(se.textContent!==ss)se.textContent=ss;
var cd=c.querySelectorAll('.su-cd');for(var i=0;i<cd.length;i++){var r=parseInt(cd[i].dataset.until,10)-Math.round(Date.now()/1000);cd[i].textContent=r<=0?' \u00b7 abgelaufen':' \u00b7 noch '+Math.floor(r/60)+':'+p2(r%60)+' (bis '+hm(parseInt(cd[i].dataset.until,10))+')';}}
function slot(k){var c=document.getElementById('fuSteuer');return c?c.querySelector('[data-slot='+k+'] .fu-sb'):null;}
function put(k,nodes){var s=slot(k);if(!s||!nodes.length)return;s.textContent='';nodes.forEach(function(x){s.appendChild(x);});}
/* ---- Empfaenger-Kachel (sdrUi) nach jedem Neuaufbau: Bedienteile in die Steuerung, Details zum Antippen statt Tooltip ---- */
function deco(){var c=document.getElementById('sdrUiCard');if(!c||!c.firstChild)return;if(OBS)OBS.disconnect();try{steuer();
var tt=c.querySelector('.su-head .su-tt');if(tt&&tt.textContent!=='Empf\u00e4nger')tt.textContent='Empf\u00e4nger';
var p=c.querySelector(':scope>.sl-prof');if(p)put('prof',[p]);
var sg=c.querySelector(':scope>.su-seg'),hp=c.querySelector(':scope>.su-help');if(sg)put('mode',hp?[sg,hp]:[sg]);
var fs=c.querySelector(':scope>fieldset');if(fs)put('man',[fs]);
var bs=c.querySelectorAll(':scope>button.su-bd');if(bs.length)put('rel',[bs[bs.length-1]]);
var ch=c.querySelectorAll('.su-chip');for(var i=0;i<ch.length;i++){var k=ch[i].dataset.k;ch[i].setAttribute('role','button');ch[i].setAttribute('aria-expanded',OPEN[k]?'true':'false');if(OPEN[k])chipOpen(ch[i],true);}
rows(c);}finally{watch();}}
function rows(c){var rs=c.querySelectorAll('.su-row');for(var i=0;i<rs.length;i++){var r=rs[i];var t=r.getAttribute('title')||r.dataset.fuTip||'';if(r.getAttribute('title')){r.dataset.fuTip=t;r.removeAttribute('title');}
if(t&&!r.querySelector('.fu-more')){var b=el('button','fu-more','\u25BE');b.type='button';b.setAttribute('aria-label','Details');r.appendChild(b);}
var key=(r.querySelector('.su-k')||{}).textContent||'';if(ROPEN[key]&&!r.querySelector('.fu-rd')){r.classList.add('fu-ropen');r.appendChild(el('div','fu-rd',r.dataset.fuTip||''));}}}
function chipOpen(x,on){var d=x.querySelector('.fu-cd');if(on){if(!d){d=el('div','fu-cd',x.getAttribute('title')||'');x.appendChild(d);}x.classList.add('fu-open');}else{if(d)d.remove();x.classList.remove('fu-open');}x.setAttribute('aria-expanded',on?'true':'false');}
function watch(){var c=document.getElementById('sdrUiCard');if(!c||!window.MutationObserver)return;if(!OBS)OBS=new MutationObserver(function(){deco();});OBS.observe(c,{childList:true});}
/* ---- Ereignis-Historie: umbrechen, Titel ohne Symbol, Verweis auf /dabhist ---- */
function hist(){var h=document.getElementById('t4Hist');if(!h)return;var t=h.querySelector(':scope>.title');if(t){var s=strip(t.textContent);if(t.textContent!==s)t.textContent=s;}
if(!h.querySelector('.fu-link'))link(h,'/dabhist','Alle DAB-Meldungen und Technik-Ereignisse');else h.appendChild(h.querySelector('.fu-link'));
hfix(h);if(!HOBS&&window.MutationObserver){HOBS=new MutationObserver(function(){var x=document.getElementById('t4Hist');HOBS.disconnect();try{hfix(x);}finally{if(x)HOBS.observe(x,{childList:true,subtree:true});}});HOBS.observe(h,{childList:true,subtree:true});}}
/* Historie-Zeilen: ohne Tooltip, Klarnamen vor TII-Code; laeuft auch direkt nach jedem Neuaufbau der Alt-Kachel (MutationObserver, vor dem Zeichnen) */
function hfix(h){if(!h)return;var ls=h.querySelectorAll('.t4-l');for(var i=0;i<ls.length;i++)if(ls[i].title)ls[i].removeAttribute('title');tfixNode(h);}
/* ---- Antennentest: letzte Kachel, eingeklappt ---- */
var STK_OPEN=false;
function stk(){var s=document.getElementById('stickTestCard');if(!s)return;var t=s.querySelector(':scope>.title');if(!t)return;var x=strip(t.textContent);if(t.textContent!==x)t.textContent=x;
if(!s.classList.contains('fu-coll')){s.classList.add('fu-coll');s.classList.toggle('fu-closed',!STK_OPEN);t.setAttribute('role','button');}
var su=s.querySelector(':scope>.fu-csum');if(!su){su=el('div','fu-csum');t.parentNode.insertBefore(su,t.nextSibling);}var r=s.querySelector('.stk-row');var tx=r?r.textContent.replace(/\s+/g,' ').trim():'';
if(su.textContent!==tx)su.textContent=tx;}
/* ---- Meteor (nur wenn eingeschaltet oder Bilder da) ---- */
function meteor(){var c=document.getElementById('fuMeteor');var M=DM;var show=!!(M&&(M.on||(M.images||[]).length));
if(!show){if(c)c.remove();return;}c=card('fuMeteor');place(c);
var sig=JSON.stringify([M.on,M.active,M.tools,M.sgp4,(M.images||[])[0],(M.passes||[]).slice(0,3),(M.hist||[])[0],M.tle_t]);if(sig===MSIG&&c.firstChild)return;MSIG=sig;c.textContent='';
var tl=M.tools||{},ready=!!tl.satdump&&M.sgp4!==false&&(M.passes||[]).length>0;
var pl=M.active?pill('ok','EMPFANG L\u00c4UFT',true):(!M.on?pill('aus','AUS'):(ready?pill('ok','BEREIT'):pill('gelb','NICHT BEREIT')));head(c,'Meteor-M Wettersatellit',pl);
var im=(M.images||[])[0];if(im){var a=el('a','fu-mimg');a.href='/meteor/img/'+encodeURIComponent(im.f);var g=document.createElement('img');g.src='/meteor/thumb/'+encodeURIComponent(im.f);g.loading='lazy';g.alt='letztes Meteor-Bild';a.appendChild(g);c.appendChild(a);}
var box=el('div','fu-kv');var h=(M.hist||[])[0];
if(h)kv(box,'Letzter \u00dcberflug',fmt(h.aos||h.t)+' \u00b7 '+String(h.sat||'?').replace('METEOR-','')+(h.max_el?' \u00b7 '+Math.round(h.max_el)+'\u00b0':'')+' \u00b7 '+((h.images||[]).length?(h.images.length+' Bild(er)'):(h.note||'keine Bilder')),(h.images||[]).length?null:'#fdba74');
var ps=(M.passes||[]).slice(0,3);kv(box,'N\u00e4chste',ps.length?ps.map(function(x){return fmt(x.aos)+' \u00b7 '+String(x.sat||'').replace('METEOR-','')+' \u00b7 '+Math.round(x.max_el)+'\u00b0 \u00b7 '+Math.round((x.los-x.aos)/60)+' min';}).join('\n'):'keine Vorhersage');
box.lastChild.style.whiteSpace='pre-line';
if(!ready||!M.on)kv(box,'Bereitschaft',(M.on?'Schalter an':'Schalter AUS')+' \u00b7 satdump '+(tl.satdump?'ja':'fehlt')+' \u00b7 Bahnrechnung '+(M.sgp4===false?'fehlt':'ja')+' \u00b7 Bahndaten '+(M.tle_t?'vom '+fmt(M.tle_t):'fehlen'),'#fdba74');
c.appendChild(box);link(c,'/meteor','Galerie, \u00dcberfl\u00fcge und Aufnahmen');}
/* ---- Bestaetigung fuer Lage-Profil und Betriebsart (vor dem bestehenden Klick; AN/AUTO/AUS ohne) ---- */
document.addEventListener('click',function(ev){var b=ev.target&&ev.target.closest?ev.target.closest('button'):null;if(!b)return;var q=null,lb=strip(b.textContent);
if(b.closest('.sl-prof')&&!b.classList.contains('on'))q='Lage-Profil \u201e'+lb+'\u201c einstellen?\n\n'+(b.title||'')+'\n\nDer Planer verteilt die Stick-Zeit danach neu (in ca. 2 s).';
else if(b.closest('.su-seg')&&!b.classList.contains('on'))q='Betriebsart \u201e'+lb+'\u201c einstellen?\n\n'+(b.title||'');
else if(b.classList.contains('su-go'))q='Einzelempfang starten?\n\nDie Automatik pausiert bis zum Ablauf.';
else if(b.classList.contains('su-back'))q='Zur\u00fcck zur Automatik?';
if(q&&!window.confirm(q)){ev.stopPropagation();ev.preventDefault();}},true);
document.addEventListener('click',function(ev){var t=ev.target;if(!t||!t.closest)return;
var mb=t.closest('#sdrUiCard .fu-more');if(mb){var r=mb.closest('.su-row'),k=(r.querySelector('.su-k')||{}).textContent||'';ROPEN[k]=!ROPEN[k];var d=r.querySelector('.fu-rd');if(d){d.remove();r.classList.remove('fu-ropen');}if(ROPEN[k]){r.classList.add('fu-ropen');r.appendChild(el('div','fu-rd',r.dataset.fuTip||''));}return;}
var x=t.closest('#sdrUiCard .su-chip');if(x&&!t.closest('button')&&!t.closest('.fu-cd')){var k2=x.dataset.k;OPEN[k2]=!OPEN[k2];chipOpen(x,OPEN[k2]);return;}
var st=t.closest('#stickTestCard>.title');if(st){STK_OPEN=!STK_OPEN;st.parentNode.classList.toggle('fu-closed',!STK_OPEN);}});
document.addEventListener('touchstart',function(){},{passive:true});
function load4(){fetch('/api/t4/status',{credentials:'same-origin'}).then(function(r){return r.json();}).then(function(j){if(j&&j.level){D4=j;lage();}}).catch(function(){});}
function load2(){fetch('/api/t2/status',{credentials:'same-origin'}).then(function(r){return r.json();}).then(function(j){if(j&&j.ok){D2=j;lage();}}).catch(function(){});}
function loadM(){fetch('/api/meteor',{credentials:'same-origin'}).then(function(r){return r.json();}).then(function(j){if(j&&j.images){DM=j;meteor();}}).catch(function(){});}
function tick(){try{if(!D4)D4=J('t4-data');if(!D2)D2=J('t2-data');lage();steuer();deco();meteor();order();hist();stk();}catch(e){if(window.console)console.log('funkUI',e);}}
D4=J('t4-data');D2=J('t2-data');var m0=J('fu-meteor');if(m0&&m0.images)DM=m0;
tick();setTimeout(tick,300);setInterval(tick,1000);setInterval(load4,12000);setInterval(load2,20000);setInterval(loadM,60000);
})();"""
_FU_PAGE_CSS = r""".fu-wrap{max-width:900px;margin:0 auto;padding:0 12px 24px;box-sizing:border-box}
.fu-wrap .card{min-width:0;max-width:100%;box-sizing:border-box;overflow-wrap:anywhere;margin-bottom:12px}
.fu-back{display:flex;align-items:center;gap:6px;min-height:44px;color:#93c5fd;text-decoration:none;font-size:.95rem}
.fu-chips{display:flex;flex-wrap:wrap;gap:8px;margin:6px 0 4px}
.fu-chip{display:inline-flex;align-items:center;gap:6px;min-height:44px;padding:0 14px;border-radius:999px;border:1px solid #475569;color:#cbd5e1;text-decoration:none;font-size:.9rem;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
.fu-chip:active{filter:brightness(1.3);transform:scale(.97)}
.fu-chip i{display:inline-block;width:10px;height:10px;border-radius:50%;background:currentColor}
.fu-chip.on{background:#0f2a44;border-color:#0ea5e9;color:#fff;font-weight:600}
.fu-chip.off{opacity:.65}
.fu-chip b{font-weight:400;color:#94a3b8;font-size:.8rem}
.fu-day{font-size:.75rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.06em;margin:14px 2px 6px}
.fu-ev{background:#0f172a;border:1px solid #1e293b;border-left:4px solid #64748b;border-radius:10px;padding:8px 10px;margin:0 0 8px;min-width:0}
.fu-ev.c-warn{border-left-color:#ef4444}.fu-ev.c-asa{border-left-color:#ef4444}.fu-ev.c-tech{border-left-color:#60a5fa}.fu-ev.c-stick{border-left-color:#f97316}.fu-ev.c-rx{border-left-color:#eab308}.fu-ev.c-prog{border-left-color:#64748b}.fu-ev.c-meteor{border-left-color:#38bdf8}
.fu-evh{display:flex;flex-wrap:wrap;align-items:center;gap:6px;font-size:.8rem;color:#94a3b8}
.fu-evt{font-variant-numeric:tabular-nums;color:#cbd5e1}
.fu-chn{border:1px solid #334155;border-radius:6px;padding:0 6px;font-size:.75rem}
.fu-cnt{margin-left:auto;color:#cbd5e1}
.fu-evx{margin-top:4px;font-size:.95rem;line-height:1.4;overflow-wrap:anywhere;white-space:normal;color:#e2e8f0}
.fu-ev.c-warn .fu-evx,.fu-ev.c-asa .fu-evx{color:#fecaca}
.fu-evs{margin-top:3px;font-size:.78rem;color:#64748b;overflow-wrap:anywhere}
.fu-empty{color:#94a3b8;padding:10px 2px}
.fu-thumbs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-top:6px}
@media (min-width:700px){.fu-thumbs{grid-template-columns:repeat(3,minmax(0,1fr))}}
.fu-th{display:block;text-decoration:none;color:#cbd5e1;background:#0f172a;border:1px solid #1e293b;border-radius:10px;overflow:hidden;-webkit-tap-highlight-color:transparent}
.fu-th:active{filter:brightness(1.3)}
.fu-th img{display:block;width:100%;aspect-ratio:1/1;object-fit:cover;background:#111827}
.fu-th span{display:block;padding:4px 6px;font-size:.75rem;overflow-wrap:anywhere}
.fu-grp{margin-top:12px}
.fu-grp:first-of-type{margin-top:4px}
.fu-gh{font-size:.85rem;color:#cbd5e1;font-weight:600}
.fu-pass{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:2px 10px;padding:8px 0;border-top:1px solid #1e293b;font-size:.9rem}
.fu-pass:first-of-type{border-top:0}
.fu-pass .a{font-weight:600}.fu-pass .b{color:#94a3b8;text-align:right}.fu-pass .c{grid-column:1/-1;color:#94a3b8;font-size:.82rem}""" + "\n" + _FU_CSS.split("\n", 1)[1]


def _fu_e(x):
    return _fu_html.escape(str(x if x is not None else ""))


def _fu_tm(t, f="%d.%m. %H:%M"):
    return _fu_time.strftime(f, _fu_time.localtime(t)) if isinstance(t, (int, float)) and t > 0 else "–"


def _fu_num(x, d=1):
    return ("%.*f" % (d, x)).replace(".", ",") if isinstance(x, (int, float)) else "–"


# ---------- Klarnamen fuer DAB-Sender: "Bamberg (Geisberg) · 08/18", unbekannt -> "unbekannt · 00/18" (nur Anzeige) ----------
_FU_TII_RE = _fu_re.compile(r"(?P<sp>\s*)(?P<n>[^:;]*?) ?MainID (?P<a>\d{2}) / SubID (?P<b>\d{2})(?: \((?P<p>[^()]*)\))?")
_FU_TW_RE = _fu_re.compile(r"^(?P<h>.*?\bDAB (?P<ch>\w+) TII(?:-Wechsel| erstmals): )(?P<o>.*?)(?: -> (?P<c>.*?))?(?: \((?P<p>.*)\))?$")
_FU_CODE_RE = _fu_re.compile(r"^\d{2}/\d{2}$")


def _fu_mast_map(bc):
    """{(Kanal, "MM/SS"): Mastname} aus MASTS_DB (von prepper-sdr in broadcast_state t2.masts)."""
    out = {}
    try:
        ms = ((bc or {}).get("t2") or {}).get("masts") if isinstance(bc, dict) else None
        for ch, m in (ms or {}).items() if isinstance(ms, dict) else ():
            for t in (m or {}).get("tii") or [] if isinstance(m, dict) else []:
                if isinstance(t, dict) and isinstance(t.get("main"), int) and isinstance(t.get("sub"), int) and t.get("mast"):
                    out[(str(ch), "%02d/%02d" % (t["main"], t["sub"]))] = str(t["mast"])
    except Exception as e:
        print("funkUI Mastnamen:", e, flush=True)
    return out


def _fu_tii_label(mm, ch, code, fallback=None):
    nm = mm.get((ch or "11D", code)) or fallback
    return "%s · %s" % (nm or "unbekannt", code)


def _fu_tii_fix(text, ch, mm):
    """TII-Kennungen in Meldungstexten mit Klarnamen: Name · MM/SS (Codes ausserhalb MASTS_DB: unbekannt · MM/SS)."""
    try:
        s = str(text if text is not None else "")
        if "MainID" not in s and "TII-Wechsel" not in s and "TII erstmals" not in s:
            return text
        m0 = _fu_re.search(r"\bDAB (\w+)", s)
        ch = ch or (m0.group(1) if m0 else "11D")
        w = _FU_TW_RE.match(s)
        if w:
            par = {}
            for seg in (w.group("p") or "").split("; "):
                m = _FU_TII_RE.fullmatch(seg.strip())
                if m and m.group("n").strip() and "nicht in MASTS_DB" not in (m.group("p") or ""):
                    par["%s/%s" % (m.group("a"), m.group("b"))] = m.group("n").strip()

            def lst(x):
                cs = [c.strip() for c in x.split(",") if c.strip()]
                if not cs or not all(_FU_CODE_RE.match(c) for c in cs):
                    return x
                return ", ".join(_fu_tii_label(mm, w.group("ch"), c, par.get(c)) for c in cs)
            return w.group("h") + lst(w.group("o")) + ((" -> " + lst(w.group("c"))) if w.group("c") is not None else "")

        def one(m):
            code = "%s/%s" % (m.group("a"), m.group("b"))
            nm = m.group("n")
            fb = None if "nicht in MASTS_DB" in (m.group("p") or "") else (nm.strip() or None)
            return m.group("sp") + _fu_tii_label(mm, ch, code, fb)
        return _FU_TII_RE.sub(one, s)
    except Exception as e:
        print("funkUI Klarname:", e, flush=True)
        return text


# ---------- Meteor: Zusatzangaben (Schalter, Werkzeuge, Vorschaubilder) ----------
_fu_orig_sdrp_meteor = _sdrp_meteor


def _fu_meteor_extra(d):
    cfg = _sdr_load("sdr_config.json", {}) or {}
    st = _sdr_load("sdr_status.json", {}) or {}
    sw = "auto"
    try:
        if _sdr_mod is not None and hasattr(_sdr_mod, "get_lage"):
            sw = (_sdr_mod.get_lage(_SDR_BASE).get("sw") or {}).get("meteor") or "auto"
    except Exception:
        pass
    s2 = st.get("s2") if isinstance(st.get("s2"), dict) else {}
    tools = st.get("tools") if isinstance(st.get("tools"), dict) else {}
    th = set()
    try:
        td = _fu_os.path.join(_SDR_BASE, "meteor", "thumbs")
        th = {f for f in _fu_os.listdir(td) if f.endswith(".jpg")} if _fu_os.path.isdir(td) else set()
    except Exception:
        pass
    on = cfg.get("meteor_enable", True) is not False and sw != "aus"
    return {"on": bool(on), "sw": sw, "active": str(st.get("active") or "") == "meteor" or str(s2.get("active") or "") == "meteor",
            "tools": {"satdump": tools.get("satdump")}, "min_el": cfg.get("meteor_min_el") or 20,
            "thumbs": [x["f"] for x in (d.get("images") or []) if _fu_os.path.splitext(x["f"])[0] + ".jpg" in th]}


def _sdrp_meteor():
    d = _fu_orig_sdrp_meteor()
    try:
        d.update(_fu_meteor_extra(d))
    except Exception as e:
        d["fu_err"] = str(e)[:100]
    return d


def _fu_thumb(name):
    """GET /meteor/thumb/<name>: Vorschaubild (480 px) aus meteor/thumbs, sonst das Originalbild."""
    from flask import send_from_directory, abort
    if not _SDRP_IMG_RE.match(name or ""):
        abort(404)
    d = _fu_os.path.join(_SDR_BASE, "meteor")
    t = _fu_os.path.splitext(name)[0] + ".jpg"
    if _fu_os.path.isfile(_fu_os.path.join(d, "thumbs", t)):
        d, name = _fu_os.path.join(d, "thumbs"), t
    try:
        return send_from_directory(d, name, max_age=86400)
    except TypeError:
        return send_from_directory(d, name)


# ---------- gemeinsamer Seitenrahmen ----------
def _fu_shell(title, body, sub=""):
    nav = globals().get("NAV_UNIFY") or ""
    nav = nav if isinstance(nav, str) and "{{" not in nav and "{%" not in nav else ""
    css = globals().get("BASE_STYLE") or ""
    css = css if isinstance(css, str) and "{{" not in css and "{%" not in css else ""
    return ('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">'
            '<title>%s</title><style>%s%s%s</style></head><body>%s<div class="sdr-wrap fu-wrap"><div class="header"><div class="brand">Käswasser Lage Monitor</div>%s</div>'
            '<a class="fu-back" href="/funk">‹ Funk</a>%s%s</div><script>document.addEventListener("touchstart",function(){},{passive:true});</script></body></html>') % (
        _fu_e(title), css, globals().get("_SDR_CSS") or "", _FU_PAGE_CSS, nav, _fu_e(title), sub, body)


# ---------- /dabhist: Karten statt Tabelle; Warnungen/ASA, Technik, Stick 2, Empfang, Programm-Infos ----------
def _fu_dh_items(dh, tl, bc, dbev):
    out, refs = [], set()
    for x in (tl or {}).get("ev") or [] if isinstance(tl, dict) else []:
        if not isinstance(x, dict) or not isinstance(x.get("t"), (int, float)):
            continue
        if x.get("ref"):
            refs.add(str(x["ref"]))
        cat = x.get("cat") if x.get("cat") in ("tech", "stick", "meteor") else "tech"
        out.append({"t": x["t"], "c": "tech" if cat == "meteor" else cat, "cls": cat, "ch": x.get("ch"), "text": x.get("text"),
                    "lvl": x.get("lvl"), "src": "Meteor" if cat == "meteor" else ("Stick 2" if cat == "stick" else "Technik")})
    t2 = (bc or {}).get("t2") if isinstance(bc, dict) else None
    for x in ((t2 or {}).get("ev") or []) if isinstance(t2, dict) else []:
        if isinstance(x, dict) and isinstance(x.get("t"), (int, float)) and str(x.get("id")) not in refs:
            out.append({"t": x["t"], "c": "tech", "cls": "tech", "ch": x.get("ch"), "text": x.get("text"), "src": "DAB-Kennung"})
    for x in (dh or {}).get("ev") or [] if isinstance(dh, dict) else []:
        if not isinstance(x, dict) or not isinstance(x.get("t"), (int, float)):
            continue
        asa = bool(_FU_ASA_RE.search(str(x.get("src") or "")))
        warn = bool(x.get("warn")) or str(x.get("kind") or "") in ("ann", "warn")
        c = "warn" if (warn or asa) else "prog"
        out.append({"t": x["t"], "last": x.get("last"), "n": int(x.get("n") or 1), "c": c, "cls": ("asa" if asa and not warn else c),
                    "ch": x.get("ch"), "text": x.get("text"), "src": x.get("src"), "warn": warn})
    for r in dbev or []:
        if isinstance(r, dict) and r.get("type") in _FU_RX_TYPES:
            t = r.get("created") or r.get("updated")
            if isinstance(t, (int, float)):
                m = _fu_re.search(r"DAB (\w+)", str(r.get("headline") or ""))
                out.append({"t": t, "c": "rx", "cls": "rx", "ch": m.group(1) if m else None, "text": r.get("headline"),
                            "src": "Grenzwert", "lvl": "ok" if str(r.get("type")).endswith("_ok") else "gelb"})
    mm = _fu_mast_map(bc)
    for x in out:
        x["text"] = _fu_tii_fix(x.get("text"), x.get("ch"), mm)   # Klarnamen vor TII-Code
    out.sort(key=lambda x: -x["t"])
    return out


def _fu_dh_load():
    dh = _sdr_load("sdr_dabhist.json", {}) or {}
    tl = _sdr_load("sdr_techlog.json", {}) or {}
    bc = _sdr_load("broadcast_state.json", {}) or {}
    dbev = []
    try:
        if _lz_dbm is not None:
            dbev = [r for r in _lz_dbm.recent_events(1000, _LZ_PATH) if r.get("source") == "DAB" and r.get("type") in _FU_RX_TYPES]
    except Exception as e:
        print("funkUI /dabhist DB:", e, flush=True)
    return dh, tl, bc, dbev


def _fu_thr_line():
    try:
        if _lz_mgr is not None and hasattr(_lz_mgr, "fu_thr_cfg"):
            c = _lz_mgr.fu_thr_cfg(_SDR_BASE)
            own = sorted(k for k, v in (c.get("src") or {}).items() if v != "Standard") if isinstance(c.get("src"), dict) else []
            return "%s · %s" % (_lz_mgr.fu_thr_text(c), ("eigene Werte aus sdr_config.json: " + ", ".join(own)) if own else
                                "Standardwerte, einstellbar in sdr_config.json (tech_snr_low_db, tech_snr_ok_db, tech_fic_bad, tech_fic_ok, tech_thr_n)")
    except Exception as e:
        return "Grenzwerte nicht lesbar (%s)" % str(e)[:60]
    return "Grenzwerte: sdr_manager ohne funkUI"


def _fu_dh_html(items, cats, ch, skip, thr, now=None):
    e = _fu_e
    now = now or _fu_time.time()
    cnt = {k: 0 for k in _FU_CAT}
    for x in items:
        if not ch or x.get("ch") == ch:
            cnt[x["c"]] += 1
    rows = [x for x in items if x["c"] in cats and (not ch or x.get("ch") == ch)][:500]

    def q(c2, ch2):
        a = []
        if set(c2) != set(_FU_CAT_DEF):
            a.append("c=" + (",".join(k for k in _FU_CAT if k in c2) or "none"))
        if ch2:
            a.append("ch=" + ch2)
        return "/dabhist" + ("?" + "&".join(a) if a else "")
    chips = []
    for k, (nm, col, _p, _l) in _FU_CAT.items():
        on = k in cats
        c2 = [x for x in cats if x != k] if on else list(cats) + [k]
        chips.append('<a class="fu-chip %s" href="%s" style="color:%s" aria-pressed="%s"><i></i><span style="color:#e2e8f0">%s</span><b>%d</b></a>' % (
            "on" if on else "off", e(q(c2, ch)), col, "true" if on else "false", e(nm), cnt[k]))
    chs = "".join('<a class="fu-chip %s" href="%s">%s</a>' % ("on" if k == ch else "", e(q(cats, k)), e(v))
                  for k, v in (("", "alle Kanäle"), ("11D", "11D BR24"), ("5C", "5C ASA DE")))
    cards, day = [], None
    for x in rows:
        d = _fu_tm(x["t"], "%Y-%m-%d")
        if d != day:
            day = d
            lt = _fu_time.localtime(x["t"])
            cards.append('<div class="fu-day">%s, %s</div>' % (_FU_WD[lt.tm_wday], _fu_tm(x["t"], "%d.%m.%Y")))
        nm, col, pc, pl = _FU_CAT[x["c"]]
        if x["cls"] == "asa":
            pc, pl = "info", "ASA"
        elif x["cls"] == "meteor":
            pc, pl = "info", "METEOR"
        elif x["c"] in ("tech", "rx", "stick") and x.get("lvl") == "ok":
            pc = "ok"
        n = int(x.get("n") or 1)
        sub = [str(x.get("src") or "")]
        if n > 1 and x.get("last") and x.get("last") != x["t"]:
            sub.append("bis %s" % _fu_tm(x["last"], "%d.%m. %H:%M:%S"))
        cards.append('<div class="fu-ev c-%s"><div class="fu-evh"><span class="fu-evt">%s</span>%s<span class="fu-pill %s">%s</span>%s</div>'
                     '<div class="fu-evx">%s</div><div class="fu-evs">%s</div></div>' % (
                         e(x["cls"]), e(_fu_tm(x["t"], "%H:%M:%S")), ('<span class="fu-chn">%s</span>' % e(x["ch"])) if x.get("ch") else "",
                         pc, e(pl), ('<span class="fu-cnt">×%d</span>' % n) if n > 1 else "", e(x.get("text") or "–"),
                         e(" · ".join(s for s in sub if s))))
    sk = skip if isinstance(skip, dict) else {}
    skn = sum(int(v) for v in sk.values() if isinstance(v, (int, float)))
    head = ('<div class="card"><div class="fu-hd"><div class="title">DAB-Meldungen und Technik</div><span class="fu-pill">%d</span></div>'
            '<div class="fu-chips" role="group" aria-label="Arten">%s</div><div class="fu-chips" role="group" aria-label="Kanal">%s</div>'
            '<div class="fu-note">Programm-Infos (Titel, Sendungstexte) werden nicht mehr gespeichert, nur gezählt%s. BR24-Nachrichten, ASA und Warnungen bleiben. '
            'Neueste 500 · Archiv: archive/dabhist/ und archive/techlog/</div>'
            '<details class="fu-dt"><summary><span class="fu-ss">Grenzwerte für Empfangs-Meldungen</span></summary><div class="fu-note">%s</div></details></div>') % (
        len(rows), "".join(chips), chs, (" (bisher %d verworfen)" % skn) if skn else "", e(thr))
    return head + ('<div class="card">%s</div>' % "".join(cards) if cards else '<div class="card"><div class="fu-empty">keine Einträge für diese Auswahl</div></div>')


def _fu_dh_page():
    from flask import request as rq
    try:
        ca = rq.args.get("c")
        cats = [k for k in (ca or "").split(",") if k in _FU_CAT] if ca is not None else list(_FU_CAT_DEF)
        ch = (rq.args.get("ch") or "").upper()
        ch = ch if ch in _DH_CH else ""
        dh, tl, bc, dbev = _fu_dh_load()
        body = _fu_dh_html(_fu_dh_items(dh, tl, bc, dbev), cats, ch, (dh or {}).get("skip") if isinstance(dh, dict) else {}, _fu_thr_line())
    except Exception as ex:
        print("funkUI /dabhist:", ex, flush=True)
        body = '<div class="card"><div class="title">DAB-Meldungen</div><div class="fu-empty">Verlauf gerade nicht lesbar</div></div>'
    return _fu_shell("DAB-Meldungen", body)


# ---------- /meteor: Bereitschaft, Ueberfluege, Bilder je Ueberflug (Vorschaubild, Antippen = Original) ----------
def _fu_meteor_html(d, now=None):
    e = _fu_e
    now = now or _fu_time.time()
    tl = d.get("tools") or {}
    ps = d.get("passes") or []
    ready = bool(tl.get("satdump")) and d.get("sgp4") is not False and bool(ps)
    if d.get("active"):
        pl = '<span class="fu-pill ok blink">EMPFANG LÄUFT</span>'
    elif not d.get("on"):
        pl = '<span class="fu-pill aus">AUS</span>'
    else:
        pl = '<span class="fu-pill %s">%s</span>' % (("ok", "BEREIT") if ready else ("gelb", "NICHT BEREIT"))
    tle = d.get("tle_t")
    tle_txt = ("vom %s (%d Tage alt)" % (_fu_tm(tle), int((now - tle) / 86400))) if isinstance(tle, (int, float)) else "fehlen"
    kv = [("Lage-Schalter", {"an": "AN", "auto": "AUTO", "aus": "AUS"}.get(d.get("sw"), str(d.get("sw") or "AUTO")) + ("" if d.get("on") else " · Meteor aus"), None),
          ("satdump", "installiert" if tl.get("satdump") else ("fehlt – keine Aufnahme (sudo apt install satdump)" if tl.get("satdump") is False else "unbekannt"),
           None if tl.get("satdump") else "#fdba74"),
          ("Bahnrechnung", "sgp4 fehlt – keine Vorhersage" if d.get("sgp4") is False else "sgp4 da", "#fdba74" if d.get("sgp4") is False else None),
          ("Bahndaten", tle_txt, None if isinstance(tle, (int, float)) and now - tle < 7 * 86400 else "#fdba74"),
          ("Mindesthöhe", "%s° über dem Horizont" % d.get("min_el", 20), None)]
    kvh = "".join('<div class="k">%s</div><div class="v"%s>%s</div>' % (e(k), (' style="color:%s"' % c) if c else "", e(v)) for k, v, c in kv)
    out = ['<div class="card"><div class="fu-hd"><div class="title">Meteor-M Wettersatellit</div>%s</div><div class="fu-kv">%s</div>'
           '<div class="fu-note">Während eines Überflugs hat Meteor Vorrang vor 433/APRS (137,9 MHz LRPT). Gute Bilder brauchen eine V-Dipol- oder QFH-Antenne im Freien. '
           'Betriebsart und Schalter: auf der Funk-Seite.</div></div>' % (pl, kvh)]
    if ps:
        rows = "".join('<div class="fu-pass"><div class="a">%s–%s</div><div class="b">%d°</div><div class="c">%s · %s · %d min%s</div></div>' % (
            e(_fu_tm(p.get("aos"))), e(_fu_tm(p.get("los"), "%H:%M")), int(round(p.get("max_el") or 0)), e(p.get("sat") or "?"), e(p.get("dir") or ""),
            int(round(((p.get("los") or 0) - (p.get("aos") or 0)) / 60)), (" · höchster Punkt %s" % _fu_tm(p.get("max_t"), "%H:%M")) if p.get("max_t") else "")
            for p in ps[:12] if isinstance(p, dict))
    else:
        rows = '<div class="fu-empty">Keine Vorhersage – noch keine Bahndaten. Der Planer holt sie, sobald Internet da ist, und rechnet danach offline weiter.</div>'
    out.append('<div class="card"><div class="title">Nächste Überflüge</div>%s</div>' % rows)
    imgs = d.get("images") or []
    grp = []
    for x in imgs:
        k = "_".join(x["f"].split("_")[:2])
        if not grp or grp[-1][0] != k:
            grp.append((k, []))
        grp[-1][1].append(x)
    if imgs:
        gh = []
        for k, xs in grp:
            ts, sat = (k.split("_") + ["?"])[:2]
            try:
                t = _fu_time.mktime(_fu_time.strptime(ts, "%Y%m%d-%H%M"))
            except Exception:
                t = None
            th = "".join('<a class="fu-th" href="/meteor/img/%s"><img loading="lazy" src="/meteor/thumb/%s" alt="%s"><span>%s · %d kB</span></a>' % (
                e(x["f"]), e(x["f"]), e(x["f"]), e(_fu_os.path.splitext(x["f"])[0].split("_", 2)[-1]), int(x.get("kb") or 0)) for x in xs)
            gh.append('<div class="fu-grp"><div class="fu-gh">%s · %s · %d Bild(er)</div><div class="fu-thumbs">%s</div></div>' % (
                e(_fu_tm(t) if t else ts), e(sat), len(xs), th))
        nth = len(d.get("thumbs") or [])
        out.append('<div class="card"><div class="fu-hd"><div class="title">Bilder</div><span class="fu-pill">%d</span></div>%s'
                   '<div class="fu-note">Antippen öffnet das Originalbild. Vorschaubilder: %d von %d (werden beim Speichern erzeugt). Aufbewahrt: höchstens 60 Bilder / 300 MB.</div></div>' % (
                       len(imgs), "".join(gh), nth, len(imgs)))
    else:
        out.append('<div class="card"><div class="title">Bilder</div><div class="fu-empty">Noch keine Bilder.</div></div>')
    hs = d.get("hist") or []
    if hs:
        hr = "".join('<div class="fu-pass"><div class="a">%s</div><div class="b">%s</div><div class="c">%s%s</div></div>' % (
            e(_fu_tm(h.get("aos") or h.get("t"))), ("%d°" % round(h["max_el"])) if isinstance(h.get("max_el"), (int, float)) else "",
            e(h.get("sat") or "?"), e(" · %d Bild(er)" % len(h["images"]) if h.get("images") else " · " + str(h.get("note") or "keine Bilder"))) for h in hs if isinstance(h, dict))
        out.append('<div class="card"><div class="title">Letzte Aufnahmen</div>%s</div>' % hr)
    return "".join(out)


def _fu_meteor_page():
    try:
        body = _fu_meteor_html(_sdrp_meteor())
    except Exception as ex:
        print("funkUI /meteor:", ex, flush=True)
        body = '<div class="card"><div class="title">Meteor-M</div><div class="fu-empty">Daten gerade nicht lesbar</div></div>'
    return _fu_shell("Meteor-M Wettersatellit", body)


# ---------- /funk: CSS + JS + Meteor-Startdaten einhaengen ----------
def _fu_funk_data():
    try:
        d = _sdrp_meteor()
        return {"on": d.get("on"), "active": d.get("active"), "tools": d.get("tools"), "sgp4": d.get("sgp4"), "tle_t": d.get("tle_t"),
                "images": (d.get("images") or [])[:1], "passes": (d.get("passes") or [])[:3], "hist": (d.get("hist") or [])[:1]}
    except Exception as e:
        print("funkUI Meteor-Daten:", e, flush=True)
        return {}


def _fu_after(resp):
    try:
        from flask import request as rq
        if rq.path != "/funk" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="funkui-js"' in body:
            return resp
        j = body.rfind("</body>")
        if j >= 0:
            dj = _fu_json.dumps(_fu_funk_data(), ensure_ascii=False).replace("<", "\\u003c")
            resp.set_data(body[:j] + '<style id="funkui-css">' + _FU_CSS + '</style><script type="application/json" id="fu-meteor">' + dj +
                          '</script><script id="funkui-js">' + _FU_JS + '</script>' + body[j:])
    except Exception as e:
        print("funkUI /funk:", e, flush=True)
    return resp


def _fu_selftest():
    now = 1760000000
    dh = {"ev": [{"t": now - 300, "last": now - 100, "n": 3, "ch": "11D", "src": "BR24", "text": "Nachrichten: Unfall A3", "kind": "dls"},
                 {"t": now - 200, "ch": "5C", "src": "ASA DE", "text": "Probealarm", "kind": "dls"},
                 {"t": now - 50, "ch": "11D", "src": "BR24", "text": "Warnung Hochwasser", "warn": True}], "skip": {"11D": 12, "5C": 3}}
    tl = {"ev": [{"id": 1, "t": now - 400, "k": "sync_lost", "cat": "tech", "lvl": "gelb", "ch": "11D", "text": "DAB 11D Sync verloren"},
                 {"id": 2, "t": now - 150, "k": "takeover_on", "cat": "stick", "lvl": "rot", "ch": "5C", "text": "Stick 2 Übernahme"},
                 {"id": 3, "t": now - 120, "k": "fig09", "cat": "tech", "ch": "11D", "text": "FIG 0/9", "ref": "T2:11D:fig09:1"},
                 {"id": 4, "t": now - 110, "k": "meteor", "cat": "meteor", "text": "Meteor 2 Bilder"}]}
    bc = {"t2": {"ev": [{"id": "T2:11D:fig09:1", "t": now - 120, "ch": "11D", "k": "fig09", "text": "FIG 0/9"},
                        {"id": "T2:11D:label:2", "t": now - 90, "ch": "11D", "k": "label", "text": "Label neu"}]}}
    db = [{"source": "DAB", "type": "snr_bad", "headline": "DAB 11D SNR niedrig: 4,0 dB", "created": now - 60},
          {"source": "DAB", "type": "x", "headline": "egal", "created": now}]
    mmb = {"t2": {"masts": {"11D": {"tii": [{"main": 8, "sub": 18, "mast": "Bamberg (Geisberg)"}, {"main": 5, "sub": 14, "mast": "Nürnberg (Fernmeldeturm Schweinau)"}]}}}}
    mm = _fu_mast_map(mmb)
    assert _fu_tii_fix("DAB 11D Mast erstmals: Bamberg (Geisberg) MainID 08 / SubID 18 (BR Bayern)", "11D", mm) == "DAB 11D Mast erstmals: Bamberg (Geisberg) · 08/18"
    assert _fu_tii_fix("DAB 11D Mast weg: MainID 00 / SubID 18 (nicht in MASTS_DB)", None, mm) == "DAB 11D Mast weg: unbekannt · 00/18"
    assert _fu_tii_fix("DAB 11D TII-Wechsel: 08/18 -> 08/18, 05/14, 07/09 (Bamberg (Geisberg) MainID 08 / SubID 18 (BR Bayern); X MainID 05 / SubID 14 (BR Bayern); "
                       "MainID 07 / SubID 09 (nicht in MASTS_DB))", "11D", mm) == \
        "DAB 11D TII-Wechsel: Bamberg (Geisberg) · 08/18 -> Bamberg (Geisberg) · 08/18, Nürnberg (Fernmeldeturm Schweinau) · 05/14, unbekannt · 07/09"
    assert _fu_tii_fix("DAB 11D TII-Wechsel: 08/18 -> 07/02 (Amberg (Hirschau/Rotbühl) MainID 07 / SubID 02 (BR Bayern))", "11D", {}) == \
        "DAB 11D TII-Wechsel: unbekannt · 08/18 -> Amberg (Hirschau/Rotbühl) · 07/02"
    assert _fu_tii_fix("DAB 11D TII erstmals: 00/18, 08/18 (MainID 00 / SubID 18 (nicht in MASTS_DB); Bamberg (Geisberg) MainID 08 / SubID 18 (BR Bayern))", "11D", mm) == \
        "DAB 11D TII erstmals: unbekannt · 00/18, Bamberg (Geisberg) · 08/18"
    assert _fu_tii_fix("BR Bayern MainID 07 / SubID 02", "11D", {}) == "BR Bayern · 07/02" and _fu_tii_fix("Sync verloren 17/10", "11D", mm) == "Sync verloren 17/10"
    assert _fu_tii_fix("17.10. 23:20 DAB · DAB 11D TII erstmals: 08/18 (Bamberg (Geisberg) MainID 08 / SubID 18 (BR Bayern))", None, mm) == "17.10. 23:20 DAB · DAB 11D TII erstmals: Bamberg (Geisberg) · 08/18"
    assert _fu_tii_fix(None, None, mm) is None and _fu_mast_map({"t2": "x"}) == {}
    it = _fu_dh_items(dh, tl, bc, db)
    cs = [x["c"] for x in it]
    assert cs.count("prog") == 1 and cs.count("warn") == 2 and cs.count("rx") == 1 and cs.count("stick") == 1, cs
    assert [x["text"] for x in it].count("FIG 0/9") == 1 and any(x["text"] == "Label neu" for x in it)      # FIG nicht doppelt
    assert it == sorted(it, key=lambda x: -x["t"]) and any(x["cls"] == "asa" for x in it) and any(x["cls"] == "meteor" and x["c"] == "tech" for x in it)
    h = _fu_dh_html(it, list(_FU_CAT_DEF), "", dh["skip"], "Grenzen", now)
    assert "Unfall" not in h and "Probealarm" in h and "Hochwasser" in h and "15 verworfen" in h and "<table" not in h, h[:300]
    assert 'href="/dabhist?c=warn,tech,stick,rx,prog"' in h and "×" not in h
    h2 = _fu_dh_html(it, list(_FU_CAT), "11D", {}, "G", now)
    assert "Unfall" in h2 and "×3" in h2 and "bis " in h2 and "Probealarm" not in h2 and "Stick 2 Übernahme" not in h2
    assert "<script" not in _fu_dh_html([{"t": now, "c": "warn", "cls": "warn", "text": "<script>x</script>", "ch": "11D"}], ["warn"], "", {}, "", now)
    m = {"on": True, "active": False, "tools": {"satdump": True}, "sgp4": True, "tle_t": now - 86400, "min_el": 20, "sw": "auto",
         "passes": [{"aos": now + 600, "los": now + 1200, "max_el": 41.4, "sat": "METEOR-M2 3", "dir": "N→S", "max_t": now + 900}],
         "images": [{"f": "20251009-0812_M23_rgb_msu_mr.jpg", "kb": 300}, {"f": "20251009-0812_M23_ir.png", "kb": 200}, {"f": "20251008-1912_M24_rgb.jpg", "kb": 100}],
         "hist": [{"aos": now - 3600, "sat": "METEOR-M2 3", "max_el": 30, "images": ["a"]}], "thumbs": ["20251009-0812_M23_ir.png"]}
    mh = _fu_meteor_html(m, now)
    assert "BEREIT" in mh and mh.count('class="fu-grp"') == 2 and "/meteor/thumb/20251009-0812_M23_ir.png" in mh and 'href="/meteor/img/20251008-1912_M24_rgb.jpg"' in mh
    assert "Vorschaubilder: 1 von 3" in mh and "41°" in mh and "<table" not in mh
    assert "AUS" in _fu_meteor_html(dict(m, on=False, images=[], passes=[]), now) and "NICHT BEREIT" in _fu_meteor_html(dict(m, passes=[]), now)
    for k in ("/api/t4/status", "/api/t2/status", "/api/meteor", "stopPropagation", "MutationObserver", "window.confirm"):
        assert k in _FU_JS, k
    assert "method:" not in _FU_JS and "XMLHttpRequest" not in _FU_JS and "localStorage" not in _FU_JS        # eigene JS sendet nichts; Knoepfe rufen nur die bestehenden Knoepfe
    assert _FU_JS.count("fetch(") == 3 and _FU_JS.count(".click()") == 1 and "#t2Tile,#t4Sdr{display:none" in _FU_CSS
    assert _SDRP_IMG_RE.match("20251009-0812_M23_ir.png") and not _SDRP_IMG_RE.match("../x.jpg")
    return "funkUI selftest ok (dabhist Kategorien/Kanal/Dubletten/Escape, Meteor Gruppen/Vorschau/Bereitschaft, JS nur lesen)"


try:
    try:
        _FU["selftest"] = _fu_selftest()
    except Exception as _fu_e1:
        _FU["selftest"] = "funkUI selftest FEHLER: %s" % _fu_e1
    if "app" in globals() and str(_FU["selftest"]).startswith("funkUI selftest ok"):
        if "dh_page" in app.view_functions:
            app.view_functions["dh_page"] = _fu_dh_page
        else:
            app.add_url_rule("/dabhist", endpoint="dh_page", view_func=_fu_dh_page, methods=["GET"])
        if "sdrp_meteor" in app.view_functions:
            app.view_functions["sdrp_meteor"] = _fu_meteor_page
        if "fu_meteor_thumb" not in app.view_functions:
            app.add_url_rule("/meteor/thumb/<name>", endpoint="fu_meteor_thumb", view_func=_fu_thumb, methods=["GET"])
        if not any(getattr(f, "__name__", "") == "_fu_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_fu_after)
        print("funkUI aktiv: /funk Funk-Lage + Steuerung + Meteor, /dabhist Karten, /meteor Galerie; %s; %s" % (_FU["selftest"], _fu_thr_line()), flush=True)
    else:
        print("funkUI FEHLER: %s" % _FU["selftest"], flush=True)
except Exception as _fu_e2:
    _FU["err"] = str(_fu_e2)[:160]
    print("funkUI FEHLER:", _fu_e2, flush=True)
# ===== /funkUI =====
FUD_EOF
EXPECT_G="22bb9aff0f1ca99fc4df54c5ce948d493c09de8525162c426c44043d567f07b5"
cat > "$W/guard_fu.py" << 'FUG_EOF'
"""AST-Guard fuer sdrLog / funkUI. Aufruf: guard_fu.py NAME EDITS  ART ALT NEU BLOCK ...  (ART = sm | sdr | dash) -> 0 ok, 1 Verstoss.
Ruecktausch (Block weg, Stellen zurueck) muss Byte fuer Byte die Basis ergeben (schon eingespielt: nur Struktur).
Neue Bloecke/Stellen: keine Prozesse, kein Netz, kein shell, keine Sendewege, keine neuen Faeden.
dashboard: nur GET-Routen /meteor/thumb/<name> (neu) und /dabhist (Ersatz), sonst nur Ansichten ersetzt; prepper_sdr: nur PIL fuer Vorschaubilder."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
label = sys.argv[1]
g = {}
exec(compile(rd(sys.argv[2]), "edits", "exec"), g)
OKMOD = {"sm": {"os", "time", "json", "tempfile", "sqlite3"}, "dash": {"os", "re", "time", "json", "html", "flask"},
         "sdr": {"os", "time", "json", "re", "tempfile", "PIL"}}
ROUTES = {"/meteor/thumb/<name>", "/dabhist"}
err, new_code = [], []
a = sys.argv[3:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    done = old == new and B.splitlines()[0] in old
    if new.count(B) != 1:
        err.append("%s: Block %s fehlt oder doppelt" % (kind, label))
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1) if kind != "dash" else new.replace(B, "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block %s" % (kind, len(E), label))
    new_code.append((kind, "Block", B))
    for o, n in E:
        ol = set(o.splitlines())
        new_code.append((kind, "Stelle", "\n".join(x for x in n.splitlines() if x not in ol)))
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover_auto", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode")
for kind, what, code in new_code:
    name = "%s %s" % (kind, what)
    if what != "Block":
        low = code.lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread"):
            if k in low:
                err.append("%s: %s" % (name, k))
        continue
    try:
        t = ast.parse(code)
    except SyntaxError as e:
        err.append("%s: Syntax %s" % (name, e)); continue
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                full = getattr(n, "module", None) or x.name
                mod = full.split(".")[0]
                if mod not in OKMOD[kind]:
                    err.append("%s: Import %s" % (name, mod))
                if mod == "flask" and x.name not in ("request", "send_from_directory", "abort"):
                    err.append("%s: flask.%s" % (name, x.name))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s: shell" % name)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if nm == "add_url_rule" and kind == "dash":
                kw = {k.arg: k.value for k in n.keywords}
                rule = getattr(n.args[0], "value", None) if n.args else None
                meth = kw.get("methods")
                if rule not in ROUTES or not (isinstance(meth, ast.List) and [getattr(x, "value", None) for x in meth.elts] == ["GET"]):
                    err.append("%s: Route %s" % (name, rule))
                continue
            if nm == "send_from_directory" and kind == "dash":
                continue
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer") \
                    or base in ("subprocess", "requests", "socket", "multiprocessing"):
                err.append("%s: Aufruf %s" % (name, nm))
        if kind == "dash" and isinstance(n, ast.Subscript) and isinstance(n.value, ast.Attribute) and n.value.attr == "view_functions" and isinstance(n.ctx, ast.Store):
            k = getattr(n.slice, "value", None)
            if k not in ("dh_page", "sdrp_meteor"):
                err.append("%s: Ansicht %s ersetzt" % (name, k))
    if kind == "dash":
        jsv = [n.value.value for n in t.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "_FU_JS" and isinstance(n.value, ast.Constant)]
        if len(jsv) != 1:
            err.append("%s: _FU_JS fehlt" % name)
        for js in ("method:", "XMLHttpRequest", "sendBeacon", "WebSocket", "localStorage"):
            if any(js in v for v in jsv):
                err.append("%s: JavaScript %s" % (name, js))
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard %s: nur die vorgesehenen Stellen + Block %s%s; keine Prozesse, kein Netz, kein shell, keine Faeden, keine Sendewege%s" % (
    label, label, " (schon eingespielt)" if all(rd(a[i + 1]) == rd(a[i + 2]) for i in range(0, len(a), 4)) else "",
    "; Dashboard nur GET /meteor/thumb + Ansichten /dabhist und /meteor ersetzt, eigene JS ohne POST" if "dash" in a[0::4] else "; prepper_sdr nur PIL fuer Vorschaubilder"))
FUG_EOF
EXPECT_CK="3a6213106b1d299dbce29f237b13cdcb255661460a7d12f15c5d6455bc06cc87"
cat > "$W/sqlccheck.py" << 'FUC_EOF'
"""sqlC Pruef-/Anzeigehilfe (nur lesen). Modi: counts DB | statusfresh DIR T0 | live F | dbok F | t4 F | observe DIR SEK | audit DIR"""
import json
import os
import sqlite3
import sys
import time

KEYS = (("sdr_status.json", "sdr_status"), ("broadcast_state.json", "broadcast_state"))


def ft(t):
    try:
        return time.strftime("%H:%M:%S", time.localtime(int(t)))
    except Exception:
        return "–"


def ro(p):
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
    c.execute("PRAGMA busy_timeout=10000")
    return c


def row(p, key):
    try:
        c = ro(p)
    except Exception:
        return None
    try:
        if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='state'").fetchone():
            return None
        return c.execute("SELECT ts, src_t, json, n FROM state WHERE key=?", (key,)).fetchone()
    finally:
        c.close()


def snap(base):
    p = os.path.join(base, "lagezentrum.db")
    out = {}
    for name, key in KEYS:
        r = row(p, key)
        f = os.path.join(base, name)
        out[name] = {"db_t": float(r[1] or r[0]) if r else None, "db_n": r[3] if r else None, "json_mt": os.path.getmtime(f) if os.path.exists(f) else None}
    w = row(p, "sqlb_writer")
    out["writer"] = json.loads(w[2]) if w else {}
    out["writer_t"] = float(w[1] or w[0]) if w else None
    return out


a = sys.argv[1]
now = time.time()
if a == "counts":
    c = ro(sys.argv[2])
    try:
        q = lambda s, *x: c.execute(s, x).fetchone()[0]
        st = q("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='state'")
        print("events %d (aktiv %d), telemetry %d, state %s" % (q("SELECT COUNT(*) FROM events"), q("SELECT COUNT(*) FROM events WHERE expires IS NULL OR expires >= ?", int(now)),
              q("SELECT COUNT(*) FROM telemetry"), ("%d Zeilen" % q("SELECT COUNT(*) FROM state")) if st else "fehlt"))
    finally:
        c.close()
elif a == "statusfresh":
    base, t0 = sys.argv[2], float(sys.argv[3])
    best = 0
    r = row(os.path.join(base, "lagezentrum.db"), "sdr_status")
    try:
        best = max(best, float(json.loads(r[2]).get("t") or 0)) if r else best
    except Exception:
        pass
    try:
        best = max(best, float(json.load(open(os.path.join(base, "sdr_status.json"))).get("t") or 0))
    except Exception:
        pass
    sys.exit(0 if best >= t0 else 1)
elif a == "live":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    assert t.get("line", "").startswith("Datenquelle:") and t.get("mode") in ("db", "dual", "json") and "mirror_age_s" in t and "fallback" in t, t
    w = t.get("writer") or {}
    print("/api/sdr/live Transport: Betriebsart %s, %s; Ersatz aktiv %s, JSON-Notkopie vor %s s; Schreibfaden ok %s, Fehler %s, verworfen %s, JSON-Schreibvorgaenge %s" % (
        t["mode"], t["line"], "ja" if t.get("fallback") else "nein", t.get("mirror_age_s"), w.get("ok"), w.get("err"), w.get("drop"), w.get("json_n")))
elif a == "dbok":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    bad = {k: v.get("why") for k, v in (t.get("items") or {}).items() if v.get("src") != "db"}
    assert t.get("mode") == "db" and not bad and not t.get("fallback") and t.get("ok"), "Betriebsart %s, nicht aus DB %s, Ersatz %s (%s)" % (t.get("mode"), bad, t.get("fallback"), t.get("line"))
    print("DB-primaer aktiv: beide aus der DB, kein JSON-Ersatz")
elif a == "t4":
    d = json.load(open(sys.argv[2]))
    t = d.get("tr") or {}
    assert t.get("line", "").startswith("Datenquelle:"), d.get("tr")
    print("/api/t4/status SDR-Status-Kachel: %s" % t["line"])
elif a == "observe":
    base, secs = sys.argv[2], int(sys.argv[3])
    s0 = snap(base)
    print("  Beobachtung %d s (nur lesen): Zeit | Status DB-Alter | Status JSON-Alter | Rundfunk DB-Alter | Rundfunk JSON-Alter | Ersatz" % secs)
    ok, n, chg = True, 0, {k: 0 for k, _ in KEYS}
    last = {k: s0[k]["json_mt"] for k, _ in KEYS}
    end = time.time() + secs
    while True:
        s = snap(base)
        t = time.time()
        ag = lambda v: ("%d s" % (t - v)) if v else "–"
        fb = (s["writer"] or {}).get("fallback")
        print("  %s | %s | %s | %s | %s | %s" % (ft(t), ag(s["sdr_status.json"]["db_t"]), ag(s["sdr_status.json"]["json_mt"]), ag(s["broadcast_state.json"]["db_t"]),
                                              ag(s["broadcast_state.json"]["json_mt"]), "JA" if fb else "nein"), flush=True)
        for k, _ in KEYS:
            if s[k]["json_mt"] != last[k]:
                chg[k] += 1
                last[k] = s[k]["json_mt"]
        if not s["sdr_status.json"]["db_t"] or t - s["sdr_status.json"]["db_t"] > 90:
            ok = False
        n += 1
        if time.time() >= end:
            break
        time.sleep(min(30, max(1, end - time.time())))
    s = snap(base)
    fb = (s["writer"] or {}).get("fallback")
    db_n = (s["sdr_status.json"]["db_n"] or 0) - (s0["sdr_status.json"]["db_n"] or 0)
    print("  Ergebnis: Status %d mal in die DB geschrieben, JSON-Dateien geaendert: sdr_status.json %dx, broadcast_state.json %dx (Notkopie alle 10 min), Ersatz %s" % (
        db_n, chg["sdr_status.json"], chg["broadcast_state.json"], "AKTIV" if fb else "aus"))
    good = ok and not fb and db_n >= 1 and chg["sdr_status.json"] <= 1
    print("  %s" % ("OK DB frisch, JSON-Notkopie altert, Ersatz aus" if good else "WARNUNG: DB nicht durchgehend frisch oder JSON wird laufend geschrieben (Ersatz/Anforderung?)"))
    sys.exit(0 if good else 1)
elif a == "audit":
    base = sys.argv[2]
    own = {"dashboard.py", "sdr_manager.py", "prepper_sdr.py", "database.py"}
    skip_d = {"venv", ".git", "__pycache__", "node_modules", ".cache", "archive", "mesh_inbox", "mesh_inbox_bayern", ".local", ".npm", ".mozilla", ".config"}
    hits = []
    roots = [os.path.dirname(base.rstrip("/")) or base, "/etc/systemd/system", "/etc/cron.d"]
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            dn[:] = [x for x in dn if x not in skip_d and not x.startswith("sqlb-") and dp.count(os.sep) - root.count(os.sep) < 4]
            for f in fn:
                if ".bak" in f or f.endswith((".json", ".jsonl", ".log", ".db", ".db-wal", ".db-shm", ".tmp", ".pyc", ".jpg", ".png", ".1")) or (dp.rstrip("/") == base.rstrip("/") and f in own):
                    continue
                fp = os.path.join(dp, f)
                try:
                    if os.path.getsize(fp) > 5 * 1024 * 1024:
                        continue
                    s = open(fp, encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                if "sdr_status.json" in s or "broadcast_state.json" in s:
                    hits.append(fp)
    pat = [h for h in hits if os.path.basename(h) in own or "/src/" in h or os.path.basename(h).startswith(("apply-", "patch-", "guard_", "edits", "sql", "kv", "tii", "body", "head", "build")) or "-apply" in h or "/sbx" in h]
    oth = [h for h in hits if h not in pat]
    if not oth:
        print("  keine weiteren Leser von sdr_status.json/broadcast_state.json gefunden (ausser dashboard.py, sdr_manager.py, prepper_sdr.py - alle auf DB zuerst umgestellt)")
    for h in oth[:30]:
        print("  liest/nennt JSON direkt (bekommt die Notkopie, max. 10 min alt; laufend nur im Ersatzfall): %s" % h)
    if pat:
        print("  dazu %d alte Patch-/Pruefskripte bzw. Kopien (nur beim Einspielen benutzt, unkritisch), z. B. %s" % (len(pat), ", ".join(os.path.basename(x) for x in pat[:4])))
FUC_EOF
EXPECT_FC="d570fbd0611aa288a86ac193f77a931efc373d5b1a2ce779416b2a06c9d446ba"
cat > "$W/fucheck.py" << 'FUF_EOF'
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
FUF_EOF
PF="$W/patch-fu.py"; ED="$W/fu_edits.py"; BSM="$W/fu_sm_block.py"; BDA="$W/fu_dash_block.py"; SG="$W/guard_fu.py"; CK="$W/sqlccheck.py"; FC="$W/fucheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_ED $ED" "$EXPECT_BSM $BSM" "$EXPECT_BDA $BDA" "$EXPECT_G $SG" "$EXPECT_CK $CK" "$EXPECT_FC $FC"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ -n "${4:-}" && "$1" == "$4" ]] && echo "bekannt ($5)" || echo "neu, Erkennung ueber Stellen/Guards"; }; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sqlC" "$KNOWN_D16N" "funkUI schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sqlC" "$KNOWN_SM16N" "funkUI schon drin"))"
echo "prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sqlC" "$KNOWN_SDR16L" "sdrLog")) - bleibt unveraendert"
echo "database.py sha16 $DB16 ($(wc -l < "$DBF") Zeilen, $(kn "$DB16" "$KNOWN_DB16" "sqlC")) - bleibt unveraendert"
echo "mesh_router.py sha16 $MR16 ($(wc -l < "$MR") Zeilen, $(kn "$MR16" "$KNOWN_MR16" "Teil 3")) - bleibt unveraendert"
echo "lagegeo.py sha16 $LG16 ($(kn "$LG16" "$KNOWN_LG16" "lageGeo")) - bleibt unveraendert"
grep -q '# ===== sqlC:' "$F" || { echo "STOP: sqlC fehlt in dashboard.py - bitte zuerst apply-sqlc.sh, nichts geaendert"; exit 1; }
grep -q 'def selftest_sqlc' "$SMF" || { echo "STOP: sqlC fehlt in sdr_manager.py - nichts geaendert"; exit 1; }
grep -q '# ===== sqlC:' "$M" || { echo "STOP: sqlC fehlt in prepper_sdr.py - nichts geaendert"; exit 1; }
grep -q 'def state_get' "$DBF" || { echo "STOP: database.py ohne state_get - nichts geaendert"; exit 1; }
python3 "$PF" funkUI sm "$SMF" "$W/work/sdr_manager.py" "$BSM" "$ED" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: sdr_manager.py unbekannte Basis (sha16 $SM16) - nichts geaendert"; exit 1; }
python3 "$PF" funkUI dash "$F" "$W/work/dashboard.py" "$BDA" "$ED" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
NS16=$(s16 "$W/work/sdr_manager.py"); ND16=$(s16 "$W/work/dashboard.py")
echo "OK Basis erkannt: $(cat "$W/p1.log"); $(cat "$W/p2.log")"
echo "   Ergebnis sdr_manager.py sha16 $NS16 ($([[ "$NS16" == "$KNOWN_SM16N" ]] && echo "wie erwartet" || echo "abweichend von $KNOWN_SM16N - Guards entscheiden")), dashboard.py sha16 $ND16 ($([[ "$ND16" == "$KNOWN_D16N" ]] && echo "wie erwartet" || echo "abweichend von $KNOWN_D16N - Guards entscheiden"))"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
for k in "sm sdr_manager $BSM" "dash dashboard $BDA"; do set -- $k
  python3 "$PF" funkUI "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$ED" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/sdr_manager.py" "$W/work/dashboard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
[[ -f "$LG" ]] && cp "$LG" "$W/sbx/"
cp "$DBF" "$MR" "$M" "$W/work/sdr_manager.py" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 240 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlA ok" "sdr_manager selftest sqlB ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && timeout 300 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr mit neuem sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Test-DB mit echter Schreibsperre, Fake-Prozesse, nichts gesendet):"
  echo "   $(grep -F 'selftest funkUI ok' "$W/smt.log" | cut -c1-260)"
done
python3 "$SG" funkUI "$ED" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" dash "$F" "$W/work/dashboard.py" "$BDA" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
if command -v node >/dev/null 2>&1; then
  python3 - "$W/work/dashboard.py" "$W" << 'JSPY' || { echo "STOP: JavaScript fehlerhaft - nichts geaendert"; exit 1; }
import ast, subprocess, sys
n_ok = 0
for n in ast.parse(open(sys.argv[1], encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("_T2D_JS", "_T4_JS", "_FU_JS") and isinstance(n.value, ast.Constant):
        f = "%s/%s.js" % (sys.argv[2], n.targets[0].id)
        open(f, "w", encoding="utf-8").write(n.value.value)
        if subprocess.run(["node", "--check", f]).returncode:
            raise SystemExit(1)
        n_ok += 1
if n_ok != 3:
    raise SystemExit("JS-Bloecke %d/3" % n_ok)
JSPY
  echo "OK JavaScript (Funk-Lage/Steuerung, Sticks, SDR-Status) syntaktisch geprueft (node)"
fi
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
ALL=("$SMF" "$F")
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/sdr_manager.py" "$SMF"; then
  echo "OK funkUI schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "funkUI|Traceback" | tail -6 | cut -c1-200 || true
    for x in "${ALL[@]}"; do [[ -f "$x.bak-funkui-$TS" ]] && cp -a "$x.bak-funkui-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-funkui-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Sicherung lagezentrum.db von vorher: $LZ.bak-funkui-$TS (nicht zurueckgespielt; funkUI fuegt nur Ereignisse + Zustand funkui_thr hinzu)"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-funkui-$TS"
    { ls -1t "$x.bak-funkui-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-funkui-$TS" \
      || { rm -f "$LZ.bak-funkui-$TS"; for x in "${ALL[@]}"; do rm -f "$x.bak-funkui-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-funkui-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-funkui-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart nur prepper-dashboard - warte auf HTTP (max 240 s; prepper-sdr laeuft weiter; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /dabhist "/dabhist?ch=11D" "/dabhist?c=warn,tech,stick,rx,prog" /meteor /api/meteor /api/sdr/live /api/t2/status /api/t4/status /api/br24; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
grep -q "L\[6\].textContent=tr?(tr.line||'')" "$W/funk.html" && echo "OK /funk: SDR-Status-Daten (Zeile Datenquelle) weiter vorhanden" || rbx "/funk ohne Zeile Datenquelle"
python3 "$FC" funk "$W/funk.html" "$W" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/funk ohne funkUI"; }
"${CURL[@]}" "$B/dabhist" -o "$W/dh.html" || true
python3 "$FC" dabhist "$W/dh.html" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/dabhist alt"; }
"${CURL[@]}" "$B/meteor" -o "$W/mt.html" || true
python3 "$FC" meteor "$W/mt.html" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/meteor alt"; }
IMG=$(python3 "$FC" thumb "$DASH_DIR" 2>/dev/null || true)
if [[ -n "$IMG" ]]; then
  c=$(code_r "$B/meteor/thumb/$IMG"); [[ "$c" == 200 ]] || rbx "/meteor/thumb antwortet $c"
  c=$(code_r "$B/meteor/img/$IMG"); [[ "$c" == 200 ]] || rbx "/meteor/img antwortet $c"
  echo "OK /meteor/thumb + /meteor/img = 200 ($IMG)"
else
  c=$(code "$B/meteor/thumb/20000101-0000_X_y.jpg"); [[ "$c" == 404 ]] && echo "OK /meteor/thumb vorhanden (noch keine Bilder, Test-Name = 404)" || rbx "/meteor/thumb antwortet $c"
fi
c=$(code "$B/meteor/thumb/..%2Fsdr_config.json"); [[ "$c" == 404 ]] && echo "OK /meteor/thumb nimmt nur Bildnamen (Pfad = 404)" || rbx "/meteor/thumb Pfadpruefung ($c)"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
L1=$(python3 -c "
import sys; s=open(sys.argv[1],encoding='utf-8',errors='replace').read(); i=s.rfind('doPrepperRestore'); print('ja' if i>=0 and s.find('class=\"tile', i) < 0 and s.find('class=\"card', i) < 0 else 'nein')" "$W/pi.html" 2>/dev/null || echo nein)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x), letzte Kachel: $L1" || rbx "/pi Sicherung veraendert ($R0/$R1)"
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(funkUI|sqlC|sqlB|sqlA|kartevec) (aktiv|FEHLER)" | tail -10 || true)
if [[ "$JD" == *"FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2)"; fi
if [[ "$JD" == *"funkUI aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'funkUI aktiv' | tail -1 | cut -c1-400)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet funkUI nicht (Journal)"; fi
[[ "$JD" == *"sqlC aktiv"* || "$RESTARTED" == 0 ]] && echo "OK Journal Dashboard: sqlC weiter aktiv" || rbx "Dashboard meldet sqlC nicht mehr"
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
python3 "$CK" live "$W/live.json" > "$W/live.log" 2>&1 && echo "OK $(cat "$W/live.log")" || { cat "$W/live.log"; rbx "/api/sdr/live ohne Transport-Anzeige"; }
python3 "$FC" live "$W/live.json" || true
"${CURL[@]}" "$B/api/t4/status" -o "$W/t4.json" || true
python3 "$CK" t4 "$W/t4.json" > "$W/t4.log" 2>&1 && echo "OK $(cat "$W/t4.log")" || { cat "$W/t4.log"; rbx "/api/t4/status ohne Datenquelle"; }
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|funkUI FEHLER|funkUI /|sqlC FEHLER|sdr_manager funkUI|sdr_manager Technik-Verlauf" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/funkUI-Fehler" || rbx "$E Traceback/funkUI-Fehlerzeilen im Journal Dashboard"
for x in "$M:$SDR16" "$DBF:$DB16" "$MR:$MR16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
echo "Grenzwerte fuer Empfangs-Meldungen (SNR/FIC): $(cd "$DASH_DIR" && python3 -c "
import sdr_manager as m; c=m.fu_thr_cfg('.'); print(m.fu_thr_text(c)+' | Quelle: '+', '.join('%s=%s' % (k, v) for k, v in sorted(c['src'].items())))" 2>&1 | tail -1 | cut -c1-400)"
echo "OK guards funkUI(dash)=$(grep -c '# ===== funkUI:' "$F" || true) funkUI(sdr_manager)=$(grep -c 'def selftest_funkui' "$SMF" || true) sqlC(dash)=$(grep -c '# ===== sqlC:' "$F" || true) sqlB(dash)=$(grep -c '# ===== sqlB:' "$F" || true) sqlC(sdr_manager)=$(grep -c 'def selftest_sqlc' "$SMF" || true) sqlC(sdr)=$(grep -c '# ===== sqlC:' "$M" || true) sdrLog(sdr)=$(grep -c '# ===== sdrLog:' "$M" || true)"
[[ -f "$F.bak-funkui-$TS" ]] && echo "Backups: *.bak-funkui-$TS (sdr_manager.py, dashboard.py, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: beide .bak-funkui-$TS zurueckkopieren, dann sudo systemctl restart prepper-dashboard"
echo "COMMIT $COMMIT_ARG funkui=1 fertig"
