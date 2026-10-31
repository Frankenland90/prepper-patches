#!/bin/bash
set -eEuo pipefail
# commit52 hbProblem - Heartbeat Mesh 1 nur noch bei echtem Problem:
#  - der stuendliche 'HB HH:MM | Lage OK | ASA OK | SDR2 frei | Wetter ... | Netz ... | Hz' (60 s nach der Wettermeldung, hb.slot_sent) wird nicht mehr gesendet
#  - Meldung 'HB HH:MM STOERUNG: ...' nur bei Lage nicht OK, ASA nicht OK, SDR liefert keine Daten, Netzfrequenz ausserhalb 49,800-50,200 Hz, Uplink weg
#    (Problem muss 120 s anstehen), einmalig je Problem; 'HB HH:MM ENTWARNUNG: ... wieder OK' einmal nach 300 s ohne Problem
#  - Dedup wie echte Alarme: gleiches Problem hoechstens alle 6 h, zusammen hoechstens 3 Meldungen je Stunde; Probe nie; Kanal 0, nur Mesh 1 (.141), Schalter AUS = nichts
#  - Wetter- und Pegel-Meldungen unveraendert
#  dashboard.py: ein Block vor __main__ (keine geaenderte Zeile). lage_pages.py und prepper_sdr.py bleiben unveraendert.
# Aufruf: bash /tmp/apply-commit52.sh commit52 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 67d58079139cd373 (nach commit51) oder ab18872053f58871 (neu), lage_pages.py 1d33ae9fd78f53dc, prepper_sdr.py 0900bfe6ba67e657.
# Sicherung dashboard.py.bak-commit52-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Beim Einspielen wird nichts gesendet, Gain-Stufe 16 bleibt.
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
W=/tmp/commit52-apply
KEEP_LAST=3
NM=commit52
KNOWN_D16="67d58079139cd373"; KNOWN_D16N="ab18872053f58871"; KNOWN_D16_C50="2a3625a3325653b1"; KNOWN_D16_C49="1dc1eedcb0c91342"; KNOWN_D16_C48="334b60f2ed228831"
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
echo "=== commit52 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): hbProblem, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt"
EXPECT_PAL="45feaed48b77a616035112a3f48bd1eb80d364200d0f8a50946bb1c06f3c5f2a"
cat > "$W/patch.py" << 'MK_C52_PAL_EOF'
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
MK_C52_PAL_EOF
EXPECT_RAE="b7d764b8b89fbf4734073f365cbd4b1852f75e996e6c77767e7fe0211e72a97c"
cat > "$W/edits.py" << 'MK_C52_RAE_EOF'
# Stellen fuer hbProblem (commit52): Basis 67d58079139cd373 (Stand nach commit51); nur ein Block vor __main__, keine Aenderung an bestehenden Zeilen
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_C52_RAE_EOF
EXPECT_RAB="cb3353760a6dc93ed46ab35f9026b7abf7a9f449bdf6a3f389c87d96f1521f4b"
cat > "$W/blk.py" << 'MK_C52_RAB_EOF'
# ===== hbProblem: Heartbeat Mesh 1 nur noch bei echtem Problem - der stuendliche 'HB HH:MM | Lage OK | ASA OK | ...' nach der Wettermeldung entfaellt; Meldung einmalig je Problem (Lage nicht OK, ASA nicht OK, SDR liefert keine Daten, Netzfrequenz ausserhalb 49,800-50,200 Hz, Uplink weg) plus eine Entwarnung bei Rueckkehr; je Problem hoechstens alle 6 h, zusammen hoechstens 3 pro Stunde; Probe/Test nie; Wetter-/Pegel-Meldungen unveraendert (commit52) =====
import time as _hp_time

HP_ON_S = 120                     # Problem muss 120 s ununterbrochen anstehen (kein Fehlalarm bei kurzem Aussetzer)
HP_OFF_S = 300                    # Entwarnung erst nach 300 s ohne Problem
HP_SAME_S = 21600              # gleiches Problem hoechstens alle 6 h melden (wie echte Alarme)
HP_MAX_H = 3                      # hoechstens 3 Meldungen je Stunde (wie echte Alarme)
HP_TRY_S = 1800                # Bridge-Fehler: 30 min lang alle 60 s versuchen, dann verwerfen (Warten auf 3/h zaehlt nicht)
HP_RETRY_S = 60
HP_FREQ_FRESH_S = 120             # Netzfrequenz gilt als 'im Band', wenn der letzte Wert hoechstens 120 s alt ist
HP_KEYS = ("LAGE", "ASA", "SDR", "NETZ", "UPLINK")
HP_NAMES = {"LAGE": "Lage", "ASA": "ASA", "SDR": "SDR", "NETZ": "Netzfrequenz", "UPLINK": "Uplink"}
HP_ASA_OK = ("ASA_OK", "ASA_LERNT", "ASA_RUHT")   # RUHT = 5C wird gerade nicht ueberwacht, LERNT = Soll-Intervall wird gelernt: kein Problem
HP_MAX_LEN = 160
_HP = {"ok": False, "err": None, "orig": None, "n": 0, "last": None}


def _hp_state():
    st = _t4_load()
    hp = st.get("hp")
    if not isinstance(hp, dict):
        hp = {}
    for k, v in (("k", {}), ("q", []), ("sent", []), ("last", {})):
        if not isinstance(hp.get(k), type(v)):
            hp[k] = v
    st["hp"] = hp
    return hp


def _hp_probe(now):
    """Beobachtung je Problem -> {key: (True = Problem | False = in Ordnung | None = unbekannt, Text)}. Nur lesen."""
    out = {k: (None, "") for k in HP_KEYS}
    s = _T4.get("status") or {}
    if s:
        lv = s.get("level") or {}
        live = s.get("live")
        l = lv.get("lvl")
        if l in ("ok", "probe") or (l == "offline" and live == "SDR_OFFLINE"):        # Probe nie; SDR_OFFLINE meldet der SDR-Punkt
            out["LAGE"] = (False, "")
        elif l:
            out["LAGE"] = (True, "Lage %s" % str(lv.get("label") or l)[:40])
        if live == "SDR_OFFLINE":
            out["SDR"] = (True, "SDR liefert keine Daten")
        elif live:
            out["SDR"] = (False, "")
        asa = s.get("asa_status")
        if asa in HP_ASA_OK:
            out["ASA"] = (False, "")
        elif asa:
            out["ASA"] = (True, "ASA %s" % str(asa).replace("ASA_", "")[:24])
    fs = list(_T4.get("fs") or [])
    if fs:
        trig, dur, v = _lz_mgr.t4_freq_trigger(fs)
        fe = _lz_mgr.t4_freq_eval(fs, now)
        if trig and isinstance(v, (int, float)):
            out["NETZ"] = (True, ("Netzfrequenz %.3f Hz ausserhalb 49,800-50,200" % v).replace(".", ",", 1))
        elif fe.get("last") is not None and not fe.get("out") and now - (fe.get("last_t") or 0) <= HP_FREQ_FRESH_S:
            out["NETZ"] = (False, "")
    us = _t4_us()
    if isinstance(us, dict) and not us.get("stale"):
        cand, why = us.get("candidate") or us.get("current"), str(us.get("reason") or "")
        if cand == "unclear" and "Ausfall" in why:
            out["UPLINK"] = (True, "Uplink weg (keine Verbindung)")
        elif cand in ("telekom", "starlink"):
            out["UPLINK"] = (False, "")
    return out


def _hp_text(kind, parts, now):
    hm = _hp_time.strftime("%H:%M", _hp_time.localtime(now))
    if kind == "on":
        s = "HB %s STOERUNG: %s" % (hm, "; ".join(parts))
    else:
        s = "HB %s ENTWARNUNG: %s wieder OK" % (hm, ", ".join(parts))
    return s[:HP_MAX_LEN]


def _hp_eval(now):
    """Zustandswechsel je Problem (mit Wartezeit) -> neue Eintraege in der Warteschlange. Gibt die Wechsel zurueck."""
    hp = _hp_state()
    obs = _hp_probe(now)
    ch = {"on": [], "off": []}
    for key in HP_KEYS:
        bad, txt = obs[key]
        k = hp["k"].get(key)
        if not isinstance(k, dict):
            k = hp["k"][key] = {"bad": False, "cand": None, "cand_t": None, "since": None, "sent": False, "txt": ""}
        if bad is None or bool(bad) == bool(k["bad"]):
            k["cand"], k["cand_t"] = None, None
            if bad:
                k["txt"] = txt
            continue
        if k["cand"] is not bool(bad):
            k["cand"], k["cand_t"] = bool(bad), now
            if bad:
                k["txt"] = txt
            continue
        if now - int(k["cand_t"] or now) < (HP_ON_S if bad else HP_OFF_S):
            if bad:
                k["txt"] = txt
            continue
        k.update(bad=bool(bad), cand=None, cand_t=None, since=now)
        if bad:
            k.update(txt=txt, sent=False)
            last = hp["last"].get(key)
            if isinstance(last, (int, float)) and now - last < HP_SAME_S:
                _t4_say("hbProblem: %s - gleiches Problem schon vor %d min gemeldet (6 h), keine Meldung" % (txt, (now - last) // 60))
            else:
                ch["on"].append(key)
        else:
            dropped = False
            for e in hp["q"]:
                if e.get("kind") == "on" and key in e.get("keys", []):
                    e["keys"] = [x for x in e["keys"] if x != key]
                    e["parts"] = {x: y for x, y in (e.get("parts") or {}).items() if x != key}
                    dropped = True
            hp["q"] = [e for e in hp["q"] if e.get("keys")]
            if k.get("sent") and not dropped:
                ch["off"].append(key)
            k["sent"] = False
    if ch["on"]:
        hp["q"].append({"kind": "on", "keys": ch["on"], "parts": {x: hp["k"][x]["txt"] for x in ch["on"]}, "t": now, "next": now})
    if ch["off"]:
        hp["q"].append({"kind": "off", "keys": ch["off"], "parts": {x: HP_NAMES[x] for x in ch["off"]}, "t": now, "next": now})
    return ch


def _hp_send(now):
    hp = _hp_state()
    if not hp["q"]:
        return None
    e = hp["q"][0]
    if e.get("fail_t") and now - int(e["fail_t"]) > HP_TRY_S:
        hp["q"].pop(0)
        _t4_say("hbProblem: Meldung verworfen (30 min nicht zustellbar): %s" % ", ".join(e.get("keys") or []))
        return "drop"
    if now < int(e.get("next") or 0) or not _t4_boot_ok():
        return "wait"
    hp["sent"] = [t for t in hp["sent"] if isinstance(t, (int, float)) and now - t < 3600]
    if len(hp["sent"]) >= HP_MAX_H:
        e["next"] = now + HP_RETRY_S
        return "wait-3h"
    last = int((_T3S.get("last_send") or {}).get("m1") or 0)
    if now - last < T4_HB_GAP_S:
        return "wait-gap"
    base, path = _t4_paths()
    if _lz_mesh.dab_pending(_t4_alarms(now), base, path, now):
        return "wait-dab"
    text = _hp_text(e["kind"], [e["parts"][x] for x in e["keys"] if x in e["parts"]], now)
    r = _t4_send_m1(text, "teil4_hb")
    hb = {"t": now, "ok": r["ok"], "why": r.get("why"), "text": text}
    _T4["hb"]["last"] = hb
    _t4_load()["hb_last"] = hb
    if r["ok"]:
        hp["q"].pop(0)
        hp["sent"].append(now)
        if e["kind"] == "on":
            for x in e["keys"]:
                hp["last"][x] = now
                if isinstance(hp["k"].get(x), dict):
                    hp["k"][x]["sent"] = True
        _t4_say("hbProblem Mesh 1 gesendet:", text)
        return "sent"
    if r.get("why") == "Auto-Versand AUS (Schalter)" or str(r.get("why") or "").startswith("GESPERRT"):
        hp["q"].pop(0)
        _t4_say("hbProblem: nicht an Mesh 1 (%s): %s" % (r.get("why"), text))
        return "fail"
    e["next"] = now + HP_RETRY_S
    if not e.get("fail_t"):
        e["fail_t"] = now
        _t4_say("hbProblem: Mesh 1 nicht erreichbar (%s) - neuer Versuch alle %d s, hoechstens %d min: %s" % (r.get("why"), HP_RETRY_S, HP_TRY_S // 60, text))
    return "fail"


def _hp_tick(now):
    """Ersetzt teil4 _t4_hb_tick: kein stuendlicher Heartbeat mehr, nur Problem-/Entwarnungs-Meldungen."""
    if _T4["hb"].get("due"):
        _T4["hb"]["due"] = None                     # Wettermeldung plant weiter einen HB - er wird nicht mehr gesendet
    hp = _hp_state()
    before = repr((hp["k"], hp["q"], hp["sent"], hp["last"]))
    ch = _hp_eval(now)
    r = _hp_send(now)
    _HP.update(n=_HP["n"] + 1, last={"t": now, "r": r, "on": ch["on"], "off": ch["off"]})
    if repr((hp["k"], hp["q"], hp["sent"], hp["last"])) != before:
        _t4_save()
    return r


def _selftest_hbproblem():
    import tempfile
    d = tempfile.mkdtemp()
    p = _t4_os.path.join(d, "lagezentrum.db")
    clock = [1790000000]
    sent, host = [], {"m1": "192.168.178.141"}

    def tx(text, channel=0):
        sent.append((text, channel))
        return True
    fk = {"now": lambda: clock[0], "base": d, "path": p, "static": d, "us": {"current": "telekom", "candidate": "telekom", "reason": "x", "stale": False},
          "alarms": [], "live": "OK"}
    keep = {k: _T4.get(k) for k in ("fake", "st", "fs", "hb", "status", "status_t")}
    t3f0, ls0 = _T3S.get("fake"), dict(_T3S["last_send"])
    _T4.update(fake=fk, st=None, fs=_t4_col.deque(maxlen=240), hb={"due": None, "w_t": None, "slot": None, "next_try": 0, "last": None}, status=None, status_t=0)
    _T3S["fake"] = {"now": lambda: clock[0], "base": d, "path": p, "health": lambda nd: {"host": host["m1"], "connected": True, "queued": 0},
                    "tx": {"m1": tx, "m2": lambda t, c=0: (_ for _ in ()).throw(RuntimeError("Mesh 2 darf nie"))}, "alarms": []}
    _T3S["last_send"] = {"m1": 0, "m2": 0}

    def S(lvl="ok", label="OK", live="OK", asa="ASA_OK"):
        _T4["status"] = {"level": {"lvl": lvl, "label": label}, "live": live, "asa_status": asa}

    def run(sec, step=10):
        out = []
        for _ in range(0, sec, step):
            clock[0] += step
            for i in range(2):
                _T4["fs"].append((float(clock[0] - 5 * i), F[0]))
            out.append(_hp_tick(clock[0]))
        return out
    F = [50.0]
    try:
        _lz_dbm.migrate(p)
        _lz_dbm.migrate_t3(p)
        _lz_mesh.set_auto(d, True, "selftest", clock[0])
        s0 = _t4_status_calc(clock[0])
        assert set(_hp_probe(clock[0])) == set(HP_KEYS) and "level" in s0 and "asa_status" in s0 and "live" in s0
        # 1) alles in Ordnung, Wettermeldung plant HB: nichts gesendet, auch nicht nach Stunden
        S()
        _T4["hb"].update(due=clock[0] + 60, w_t=clock[0], slot="2026-10-17-15", next_try=0)
        run(4 * 3600, 60)
        assert sent == [] and _T4["hb"]["due"] is None, sent
        # 2) Probealarm (gelb) ist nie ein Problem
        S("probe", "PROBEALARM")
        run(1800, 30)
        assert sent == [], sent
        # 3) SDR liefert keine Daten: erst nach 120 s, einmal, kein zweites Mal; Lage-Offline nicht doppelt
        S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
        run(100)
        assert sent == [], sent
        run(60)
        assert len(sent) == 1 and sent[0][1] == 0 and "STOERUNG: SDR liefert keine Daten" in sent[0][0] and "Lage" not in sent[0][0], sent
        run(3600, 60)
        assert len(sent) == 1, sent
        # 4) Rueckkehr: Entwarnung erst nach 300 s, genau einmal
        S()
        run(240)
        assert len(sent) == 1
        run(120)
        assert len(sent) == 2 and "ENTWARNUNG: SDR wieder OK" in sent[1][0], sent
        run(3600, 60)
        assert len(sent) == 2
        # 5) Kurzer Aussetzer (< 120 s): nichts
        S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
        run(60)
        S()
        run(600, 30)
        assert len(sent) == 2, sent
        # 6) Gleiches Problem innerhalb 6 h erneut: keine Meldung, keine Entwarnung
        S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
        run(300)
        S()
        run(600)
        assert len(sent) == 2, sent
        # 7) Lage (Echtalarm), ASA unterbrochen, Netzfrequenz, Uplink weg: eine gemeinsame Meldung, <= 160 Zeichen, Kanal 0
        S("alarm", "ECHTALARM", "OK", "ASA_INTERRUPTED")
        F[0] = 49.70
        fk["us"] = {"current": "telekom", "candidate": "unclear", "reason": "keine Merkmale (Ausfall/Timeout)", "stale": False}
        run(200)
        assert len(sent) == 3 and all(x in sent[2][0] for x in ("Lage ECHTALARM", "ASA INTERRUPTED", "Netzfrequenz 49,700 Hz", "Uplink weg")) and len(sent[2][0]) <= HP_MAX_LEN, sent
        # 8) hoechstens 3 je Stunde: Entwarnung wartet, bis die Stunde um ist, und geht dann einmal
        S()
        F[0] = 50.0
        fk["us"] = {"current": "telekom", "candidate": "telekom", "reason": "x", "stale": False}
        _hp_state()["sent"] = [clock[0] - 100, clock[0] - 50, clock[0] - 10]
        run(400)
        assert len(sent) == 3 and _hp_state()["q"], sent
        run(3600, 60)
        assert len(sent) == 4 and sent[3][0].count("wieder OK") == 1 and "Lage" in sent[3][0] and "Uplink" in sent[3][0], sent
        # 9) Schalter AUS: nichts, Meldung verworfen; Bridge .140: nie
        _lz_mesh.set_auto(d, False, "selftest", clock[0])
        _hp_state()["last"] = {}
        S("pre", "VORALARM DSL-AUSFALL")
        run(300)
        assert len(sent) == 4 and not _hp_state()["q"], sent
        _lz_mesh.set_auto(d, True, "selftest", clock[0])
        S()
        run(600)
        host["m1"] = "192.168.178.140"
        _hp_state()["last"] = {}
        S("pre", "VORALARM DSL-AUSFALL")
        run(300)
        assert len(sent) == 4, sent
        # 10) Neustart mit anstehendem Problem: Zustand bleibt, keine zweite Meldung
        host["m1"] = "192.168.178.141"
        _T4["st"] = None
        _t4_load()
        run(600)
        assert len(sent) == 4, sent
        assert all(c == 0 and t.startswith("HB ") and "Probe" not in t and "TEST" not in t.upper() and len(t) <= HP_MAX_LEN for t, c in sent), sent
        _T4["status"] = None
        assert _hp_probe(clock[0])["LAGE"][0] is None
    finally:
        _T3S["fake"] = t3f0
        _T3S["last_send"] = ls0
        _T4.update(**keep)
    return ("hbProblem ok (kein stuendlicher Heartbeat mehr; Meldung nur bei Lage nicht OK, ASA nicht OK, SDR ohne Daten, Netzfrequenz ausserhalb Band, Uplink weg - "
            "nach %d s, einmalig je Problem + Entwarnung nach %d s, je Problem hoechstens alle 6 h, zusammen hoechstens %d/h, Probe nie, Kanal 0, Schalter AUS/.140 nie)"
            % (HP_ON_S, HP_OFF_S, HP_MAX_H))


try:
    if not _T4.get("ok") or not callable(globals().get("_t4_hb_tick")):
        raise RuntimeError("teil4 nicht aktiv (%s)" % (_T4.get("err") or "?"))
    if getattr(globals()["_t4_hb_tick"], "_hp", False):
        raise RuntimeError("schon aktiv")
    _HP["st"] = _selftest_hbproblem()
    _HP["orig"] = globals()["_t4_hb_tick"]
    _hp_tick._hp = True
    globals()["_t4_hb_tick"] = _hp_tick
    _HP["ok"] = True
    print("hbProblem aktiv: %s" % _HP["st"], flush=True)
except Exception as _hp_e:
    _HP["err"] = "%s: %s" % (type(_hp_e).__name__, str(_hp_e)[:300])
    print("hbProblem Selbsttest FEHLER (%s) - Heartbeat wie bisher" % _HP["err"], flush=True)
# ===== /hbProblem =====
MK_C52_RAB_EOF
EXPECT_RAG="4fd6db4db2a2333b70d067d6a39344e0a7c876097c4c18463b0b23c0689c1169"
cat > "$W/guard.py" << 'MK_C52_RAG_EOF'
"""Guard hbProblem (commit52). dashboard.py: genau ein Block vor __main__, keine geaenderten Zeilen.
  guard_hp.py revert NEU_VERZ ALT_VERZ BLOCK   -> ALT_VERZ/dashboard.py = NEU ohne Block (byte-genau)
  guard_hp.py check  ALT NEU BLOCK             -> Rueckbau = ALT, statische Regeln, Verhaltenstests mit eigener Teil-4-Attrappe (eigene Erwartungen)
  guard_hp.py mutate ALT NEU BLOCK             -> Mutationstest (jede Mutation muss check scheitern lassen)"""
import ast, collections, io, contextlib, json, os, re, shutil, subprocess, sys, tempfile, time

ANCH = '\n\nif __name__ == "__main__":\n'
M0, M1 = "# ===== hbProblem:", "# ===== /hbProblem ====="
OK_IMPORTS = {"time", "tempfile"}
FORBID = {"send_meshtastic", "send_dab_to_private_mesh", "send_nina_to_bayern", "dab_private_send", "_t3_tx", "_t3_m1_raw", "_t3_m2_raw", "requests", "urllib", "socket",
          "subprocess", "os", "open", "system", "popen", "Popen", "eval", "exec", "__import__", "Thread", "route", "app", "after_request", "maybe_mesh_weather",
          "maybe_mesh_frequenz", "maybe_mesh_pegel", "_t4_hb_text", "set_auto", "takeover_set", "_t4_pre_on", "_t4_event", "upsert_event"}
SELFTEST_ONLY = {"set_auto", "_t4_os", "tempfile", "migrate", "migrate_t3", "_t4_status_calc", "_t4_col"}
CONSTS = {"HP_ON_S": 120, "HP_OFF_S": 300, "HP_SAME_S": 21600, "HP_MAX_H": 3, "HP_TRY_S": 1800, "HP_RETRY_S": 60, "HP_FREQ_FRESH_S": 120,
          "HP_KEYS": ("LAGE", "ASA", "SDR", "NETZ", "UPLINK"), "HP_ASA_OK": ("ASA_OK", "ASA_LERNT", "ASA_RUHT"), "HP_MAX_LEN": 160}
NEED_SRC = {"_hp_tick": ['_T4["hb"]["due"] = None', "_t4_save()"],
            "_hp_send": ['r = _t4_send_m1(text, "teil4_hb")', "if len(hp[\"sent\"]) >= HP_MAX_H:", "if now - last < T4_HB_GAP_S:", "if _lz_mesh.dab_pending(_t4_alarms(now), base, path, now):",
                         "or not _t4_boot_ok():", 'r.get("why") == "Auto-Versand AUS (Schalter)" or str(r.get("why") or "").startswith("GESPERRT")', "hp[\"last\"][x] = now"],
            "_hp_eval": ["now - last < HP_SAME_S", "(HP_ON_S if bad else HP_OFF_S)", 'if k.get("sent") and not dropped:'],
            "_hp_probe": ['l in ("ok", "probe")', '(l == "offline" and live == "SDR_OFFLINE")', 'if live == "SDR_OFFLINE":', "asa in HP_ASA_OK", "_lz_mgr.t4_freq_trigger(fs)", 'cand == "unclear" and "Ausfall" in why', 'not us.get("stale")']}


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
    need = {"_hp_state", "_hp_probe", "_hp_text", "_hp_eval", "_hp_send", "_hp_tick", "_selftest_hbproblem"}
    if need - set(funcs):
        fail("Funktionen fehlen: %s" % sorted(need - set(funcs)))
    for node in ast.walk(t):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for m in ([a.name for a in node.names] if isinstance(node, ast.Import) else [node.module]):
                if m not in OK_IMPORTS:
                    fail("Import %s" % m)
        if isinstance(node, ast.Global):
            fail("global-Anweisung")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print":
            a0 = node.args[0] if node.args else None
            s = a0.left.value if isinstance(a0, ast.BinOp) and isinstance(a0.left, ast.Constant) else (a0.value if isinstance(a0, ast.Constant) else "")
            if not str(s).startswith("hbProblem"):
                fail("print ohne Praefix hbProblem: %r" % str(s)[:40])
    for fn, f in funcs.items():
        for node in ast.walk(f):
            nm = node.id if isinstance(node, ast.Name) else (node.attr if isinstance(node, ast.Attribute) else None)
            if nm is None:
                continue
            if nm in FORBID and not (fn == "_selftest_hbproblem" and nm in SELFTEST_ONLY):
                fail("verbotener Name %s in %s" % (nm, fn))
            if nm in SELFTEST_ONLY and fn != "_selftest_hbproblem":
                fail("%s ausserhalb des Selbsttests (%s)" % (nm, fn))
    rest = [n for n in t.body if not isinstance(n, ast.FunctionDef)]
    for n in rest:
        for node in ast.walk(n):
            nm = node.id if isinstance(node, ast.Name) else (node.attr if isinstance(node, ast.Attribute) else None)
            if nm in FORBID or nm in SELFTEST_ONLY - {"tempfile"}:
                fail("verbotener Name %s ausserhalb der Funktionen" % nm)
    C = consts(t)
    for k, v in CONSTS.items():
        if C.get(k) != v:
            fail("Konstante %s = %r (erwartet %r)" % (k, C.get(k), v))
    sends = [(fn, node) for fn, f in funcs.items() for node in ast.walk(f) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "_t4_send_m1"]
    if len(sends) != 1 or sends[0][0] != "_hp_send":
        fail("_t4_send_m1 nicht genau einmal (nur in _hp_send)")
    for fn, ss in NEED_SRC.items():
        src = ast.get_source_segment(B, funcs[fn])
        for s in ss:
            if src.count(s) != 1:
                fail("%s ohne %r" % (fn, s))
    nonst = "".join(ast.get_source_segment(B, f) for fn, f in funcs.items() if fn != "_selftest_hbproblem")
    strs = [n.value for fn, f in funcs.items() if fn != "_selftest_hbproblem" for n in ast.walk(f) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    for s in strs:
        if re.search(r"probe|test", s, re.I) and s not in ("probe",):
            fail("Text mit Probe/Test: %r" % s[:60])
    tx = ast.get_source_segment(B, funcs["_hp_text"])
    if tx.count('"HB %s STOERUNG: %s"') != 1 or tx.count('"HB %s ENTWARNUNG: %s wieder OK"') != 1 or "s[:HP_MAX_LEN]" not in tx:
        fail("Meldungstexte nicht wie vorgesehen")
    if B.count('globals()["_t4_hb_tick"] = _hp_tick') != 1 or "_t4_hb_tick =" in B.replace('globals()["_t4_hb_tick"] = _hp_tick', ""):
        fail("Umschalten _t4_hb_tick nicht genau einmal")
    i = B.index("\ntry:\n    if not _T4.get(\"ok\")")
    tr = B[i:]
    if not (tr.index("_selftest_hbproblem()") < tr.index('_HP["orig"] = globals()["_t4_hb_tick"]') < tr.index('globals()["_t4_hb_tick"] = _hp_tick') < tr.index('_HP["ok"] = True')) or "except Exception as _hp_e:" not in tr:
        fail("Reihenfolge Selbsttest -> Umschalten")
    if 'getattr(globals()["_t4_hb_tick"], "_hp", False)' not in tr:
        fail("Schutz gegen doppeltes Umschalten fehlt")
    return nonst


class Env:
    """Teil-4-Attrappe mit eigenem Mesh-1-Sendeweg (Schalter, Bridge-Host, Bridge-Fehler)."""
    F_LOW, F_HIGH = 49.8, 50.2

    def __init__(self):
        self.now = 1790000000
        self.sent, self.said, self.saved = [], [], None
        self.switch, self.host, self.bridge_ok, self.boot, self.dab = True, "192.168.178.141", True, True, False
        self.us = {"current": "telekom", "candidate": "telekom", "reason": "x", "stale": False}
        self.st = {}

    def trig(self, fs):
        sm = sorted(fs)
        run = []
        for t, v in reversed(sm):
            if v < self.F_LOW or v > self.F_HIGH:
                run.append((t, v))
            else:
                break
        if len(run) < 2:
            return False, 0, run[0][1] if run else None
        return run[0][0] - run[-1][0] > 3, int(run[0][0] - run[-1][0]), run[0][1]

    def feval(self, fs, now):
        sm = sorted(fs)
        if not sm:
            return {"last": None, "last_t": None, "out": False}
        return {"last": sm[-1][1], "last_t": sm[-1][0], "out": sm[-1][1] < self.F_LOW or sm[-1][1] > self.F_HIGH}

    def send(self, text, kind):
        assert kind == "teil4_hb"
        if not self.switch:
            return {"ok": False, "why": "Auto-Versand AUS (Schalter)"}
        if self.host != "192.168.178.141":
            return {"ok": False, "why": "GESPERRT: Bridge 5001 meldet Host %s" % self.host}
        if not self.bridge_ok:
            return {"ok": False, "why": "Bridge-Fehler"}
        self.sent.append((self.now, text))
        self.g["_T3S"]["last_send"]["m1"] = self.now
        return {"ok": True, "why": "gesendet"}

    def build(self, B):
        tt = ast.parse(B)
        body = [n for n in tt.body if not isinstance(n, ast.Try)]
        self.tryn = [n for n in tt.body if isinstance(n, ast.Try)]
        mgr = type("M", (), {})()
        mgr.t4_freq_trigger = self.trig
        mgr.t4_freq_eval = self.feval
        mesh = type("X", (), {})()
        mesh.dab_pending = lambda al, base, path, now: self.dab
        E = self

        def load():
            return E.st

        def save():
            E.saved = json.dumps(E.st)
        g = {"__name__": "hpguard", "_T4": {"ok": True, "hb": {"due": None, "w_t": None, "slot": None, "next_try": 0, "last": None}, "status": None, "fs": collections.deque(maxlen=240)},
             "_T3S": {"last_send": {"m1": 0, "m2": 0}}, "T4_HB_GAP_S": 60, "_t4_load": load, "_t4_save": save, "_t4_say": lambda *a: E.said.append(" ".join(str(x) for x in a)),
             "_t4_us": lambda: E.us, "_t4_boot_ok": lambda: E.boot, "_t4_paths": lambda: ("/nirgends", "/nirgends/x.db"), "_t4_alarms": lambda now=None: [],
             "_t4_send_m1": self.send, "_lz_mgr": mgr, "_lz_mesh": mesh}
        self.g = g
        exec(compile(ast.Module(body=body, type_ignores=[]), "blk", "exec"), g)
        return g

    def S(self, lvl="ok", label="OK", live="OK", asa="ASA_OK"):
        self.g["_T4"]["status"] = {"level": {"lvl": lvl, "label": label}, "live": live, "asa_status": asa}

    def run(self, sec, step=10, hz=50.0):
        r = []
        for _ in range(0, sec, step):
            self.now += step
            self.g["_T4"]["fs"].append((float(self.now - 4), hz))
            self.g["_T4"]["fs"].append((float(self.now), hz))
            r.append(self.g["_hp_tick"](self.now))
        return r


def behav(B):
    E = Env()
    g = E.build(B)
    tick = g["_hp_tick"]
    # A) alles gut: Wetter plant HB -> nie gesendet (24 h), due geloescht
    E.S()
    g["_T4"]["hb"].update(due=E.now + 60, w_t=E.now, slot="s", next_try=0)
    E.run(24 * 3600, 60)
    assert E.sent == [] and g["_T4"]["hb"]["due"] is None, ("A", E.sent)
    assert json.loads(E.saved)["hp"]["k"]["SDR"]["bad"] is False, "Zustand nicht gespeichert/JSON"
    # B) Probe nie; ASA lernt/ruht kein Problem; unbekannter Status (None) aendert nichts
    E.S("probe", "PROBEALARM", "OK", "ASA_LERNT")
    E.run(3600, 30)
    E.S("ok", "OK", "OK", "ASA_RUHT")
    E.run(600, 30)
    g["_T4"]["status"] = None
    E.us = None
    E.run(3600, 60)
    E.us = {"current": "telekom", "candidate": "telekom", "reason": "x", "stale": False}
    assert E.sent == [], ("B", E.sent)
    for i in range(20):
        g["_T4"]["fs"].append((float(E.now + i), 50.0))
    g["_T4"]["fs"].append((float(E.now + 25), 50.4))                      # ein einzelner Messwert ausserhalb: noch kein Problem
    for i in range(30):
        E.now += 10
        tick(E.now)
    assert E.sent == [], ("B2 Einzelwert", E.sent)
    E.run(600, 30)
    # C) SDR ohne Daten: nicht vor 120 s, dann genau 1 (Kanal-Text), nicht Lage doppelt; bleibt 2 h -> keine zweite
    E.S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
    E.run(110)
    assert E.sent == [], ("C1", E.sent)
    E.run(30)
    assert len(E.sent) == 1 and re.match(r"^HB \d\d:\d\d STOERUNG: SDR liefert keine Daten$", E.sent[0][1]), ("C2", E.sent)
    t_sdr = E.sent[0][0]
    E.run(7200, 60)
    assert len(E.sent) == 1, ("C3", E.sent)
    g["_T4"]["status"] = None                                              # Status unbekannt: weder Problem noch Entwarnung
    E.run(1200, 60)
    assert len(E.sent) == 1, ("C4 unbekannt", E.sent)
    E.S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
    E.run(60)
    # D) Rueckkehr: Entwarnung nicht vor 300 s, dann genau 1
    E.S()
    E.run(290)
    assert len(E.sent) == 1, ("D1", E.sent)
    E.run(30)
    assert len(E.sent) == 2 and re.match(r"^HB \d\d:\d\d ENTWARNUNG: SDR wieder OK$", E.sent[1][1]), ("D2", E.sent)
    E.run(3600, 60)
    assert len(E.sent) == 2
    # E) Flattern < 120 s: nichts; Rueckkehr kurz < 300 s mitten im Problem: keine Entwarnung
    for _ in range(5):
        E.S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
        E.run(100)
        E.S()
        E.run(100)
    assert len(E.sent) == 2, ("E", E.sent)
    # F) gleiches Problem innerhalb 6 h ab der ersten Meldung: keine Meldung und keine Entwarnung; nach 6 h wieder
    assert E.now - t_sdr < 6 * 3600
    E.S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
    E.run(600)
    E.S()
    E.run(600)
    assert len(E.sent) == 2, ("F1", E.sent)
    E.now = t_sdr + 6 * 3600 + 10
    E.S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
    E.run(200)
    assert len(E.sent) == 3 and "SDR liefert keine Daten" in E.sent[2][1], ("F2", E.sent)
    E.S()
    E.run(400)
    assert len(E.sent) == 4 and "ENTWARNUNG: SDR" in E.sent[3][1], ("F3", E.sent)
    # G) mehrere Probleme gleichzeitig -> eine Meldung (Lage, ASA, Netz, Uplink), <= 160 Zeichen
    E.S("alarm", "ECHTALARM", "OK", "ASA_INTERRUPTED")
    E.us = {"current": "telekom", "candidate": "unclear", "reason": "keine Merkmale (Ausfall/Timeout)", "stale": False}
    E.run(200, 10, 50.31)
    assert len(E.sent) == 5, ("G1", E.sent)
    m = E.sent[4][1]
    for s in ("STOERUNG", "Lage ECHTALARM", "ASA INTERRUPTED", "Netzfrequenz 50,310 Hz", "Uplink weg"):
        assert s in m, ("G2", s, m)
    assert len(m) <= 160 and "SDR" not in m
    # H) Rueckkehr: Lage/ASA zuerst, Netz/Uplink 2 min spaeter -> zwei Entwarnungen; zusammen hoechstens 3/h
    E.S()
    E.run(120, 10, 50.31)
    E.us = {"current": "starlink", "candidate": "starlink", "reason": "x", "stale": False}
    E.run(600, 10, 50.0)
    assert len(E.sent) == 5, ("H0 3/h: Entwarnungen muessen warten", E.sent[4:])
    E.run(3600, 10, 50.0)
    assert len(E.sent) == 7 and "Lage" in E.sent[5][1] and "ASA" in E.sent[5][1] and "Netzfrequenz" in E.sent[6][1] and "Uplink" in E.sent[6][1], ("H1", E.sent[4:])
    assert all("ENTWARNUNG" in x[1] for x in E.sent[5:7])
    for i in range(len(E.sent)):
        assert len([t for t, x in E.sent if 0 <= t - E.sent[i][0] < 3600]) <= 3, ("H2 mehr als 3/h", E.sent)
    # I) 3/h: viertes Problem in derselben Stunde wartet, geht nach Ablauf der Stunde (nicht verworfen)
    st = g["_hp_state"]()
    st["last"] = {}
    E.S("pre", "VORALARM DSL-AUSFALL")
    E.run(200)
    n_i = len(E.sent)
    hour = [t for t, x in E.sent if E.now - t < 3600]
    assert len(hour) <= 3, ("I1", E.sent)
    E.run(3600, 60)
    assert any("Lage VORALARM DSL-AUSFALL" in x for t, x in E.sent), ("I2", E.sent[-3:])
    for i in range(len(E.sent)):
        win = [t for t, x in E.sent if 0 <= t - E.sent[i][0] < 3600]
        assert len(win) <= 3, ("I3 mehr als 3/h", E.sent)
    E.S()
    E.run(600)
    n0 = len(E.sent)
    # J) Bridge-Fehler: alle 60 s neu, nach 30 min verworfen, danach keine Entwarnung
    st["last"] = {}
    E.bridge_ok = False
    E.S("alarm", "ECHTALARM")
    E.run(2400, 10)
    assert len(E.sent) == n0 and not g["_hp_state"]()["q"], ("J1", g["_hp_state"]()["q"])
    E.bridge_ok = True
    E.S()
    E.run(600)
    assert len(E.sent) == n0, ("J2", E.sent[n0:])
    # K) Schalter AUS / Host .140: nichts, verworfen, keine Entwarnung
    for sw, host in ((False, "192.168.178.141"), (True, "192.168.178.140")):
        st["last"] = {}
        E.switch, E.host = sw, host
        E.S("alarm", "ECHTALARM")
        E.run(300)
        E.switch, E.host = True, "192.168.178.141"
        E.S()
        E.run(600)
        assert len(E.sent) == n0, ("K", sw, host, E.sent[n0:])
    # L) Mesh-Abstand 60 s, DAB-Vorrang, Boot-Sperre: warten, nicht verwerfen
    st["last"] = {}
    E.dab, E.boot = True, False
    E.S("offline", "SDR_OFFLINE", "SDR_OFFLINE")
    E.run(600)
    assert len(E.sent) == n0, ("L1",)
    E.boot = True
    E.run(120)
    assert len(E.sent) == n0, ("L2 DAB-Vorrang",)
    E.dab = False
    g["_T3S"]["last_send"]["m1"] = E.now
    E.run(30)
    assert len(E.sent) == n0, ("L3 60-s-Abstand",)
    E.run(60)
    assert len(E.sent) == n0 + 1, ("L4", E.sent[n0:])
    # M) Neustart mit anstehendem Problem: Zustand aus der Datei, keine zweite Meldung
    E.st = json.loads(E.saved)
    E.run(1200)
    assert len(E.sent) == n0 + 1, ("M", E.sent[n0:])
    E.S()
    E.run(400)
    assert len(E.sent) == n0 + 2 and "ENTWARNUNG: SDR" in E.sent[-1][1], ("M2", E.sent[n0:])
    # N) Problem endet, bevor es gesendet ist (wartet auf 3/h): Eintrag faellt weg, keine Entwarnung
    st = g["_hp_state"]()
    st["last"] = {}
    st["sent"] = [E.now - 30, E.now - 20, E.now - 10]
    E.S("alarm", "ECHTALARM")
    E.run(200)
    E.S()
    E.run(400)
    E.run(3600, 60)
    assert len(E.sent) == n0 + 2, ("N", E.sent[n0:])
    # O) alle Texte: HB-Praefix, <= 160, nie Probe/Test
    for t, x in E.sent:
        assert x.startswith("HB ") and len(x) <= 160 and not re.search(r"probe|test", x, re.I), x
    # Q) langer Lage-Text: wird gekuerzt, die anderen Probleme bleiben in der Meldung
    E2 = Env()
    g2 = E2.build(B)
    E2.S("alarm", "X" * 300, "OK", "ASA_INTERRUPTED")
    E2.run(200)
    assert len(E2.sent) == 1 and "ASA INTERRUPTED" in E2.sent[0][1] and len(E2.sent[0][1]) <= 160, ("Q", E2.sent)
    # P) Umschalten: nur nach bestandenem Selbsttest; bei Fehler bleibt der alte HB (alles-oder-nichts); doppelt nie
    orig = lambda now: "alt"
    for ok in (True, False):
        g2 = E.build(B)
        g2["_t4_hb_tick"] = orig
        if ok:
            g2["_selftest_hbproblem"] = lambda: "attrappe ok"
        else:
            def bad():
                raise AssertionError("x")
            g2["_selftest_hbproblem"] = bad
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            exec(compile(ast.Module(body=E.tryn, type_ignores=[]), "blk", "exec"), g2)
        out = buf.getvalue()
        if ok:
            assert g2["_t4_hb_tick"] is g2["_hp_tick"] and g2["_HP"]["orig"] is orig and g2["_HP"]["ok"] and out.startswith("hbProblem aktiv: attrappe ok"), out
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                exec(compile(ast.Module(body=E.tryn, type_ignores=[]), "blk", "exec"), g2)
            assert g2["_t4_hb_tick"] is g2["_hp_tick"] and g2["_HP"]["orig"] is orig and "schon aktiv" in buf.getvalue(), buf.getvalue()
        else:
            assert g2["_t4_hb_tick"] is orig and not g2["_HP"]["ok"] and "hbProblem Selbsttest FEHLER" in out, out
    g3 = E.build(B)
    g3["_T4"]["ok"] = False
    g3["_t4_hb_tick"] = orig
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(ast.Module(body=E.tryn, type_ignores=[]), "blk", "exec"), g3)
    assert g3["_t4_hb_tick"] is orig
    return len(E.sent)


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
    if alt.count("def _t4_hb_tick(now):") != 1 or alt.count("        _t4_hb_tick(now)\n") != 1:
        fail("Basis: teil4 _t4_hb_tick nicht wie erwartet (Aufruf im Takt per Name)")
    try:
        n = behav(B)
    except AssertionError as e:
        fail("Verhalten: %s" % str(e)[:500])
    except Exception as e:
        fail("Verhalten (%s): %s" % (type(e).__name__, str(e)[:300]))
    print("Guard hbProblem ok: Rueckbau byte-genau = Basis; statisch (nur time, ein Sendeweg _t4_send_m1 'teil4_hb' nur in _hp_send, kein Mesh 2/Wetter/Pegel/Schalter, keine Probe-/Test-Texte, "
          "Umschalten nur nach Selbsttest); Verhalten mit eigener Teil-4-Attrappe: 24 h ohne Problem 0 Meldungen, Probe/ASA lernt/ruht/unbekannt 0, Problem nach 120 s genau 1, Entwarnung nach 300 s genau 1, "
          "Flattern 0, 6 h je Problem, mehrere Probleme in einer Meldung, hoechstens 3/h (wartet, verwirft nicht), Bridge-Fehler 30 min, Schalter AUS/.140 nichts, DAB-Vorrang/60 s Abstand/Boot-Sperre, "
          "Neustart ohne Doppel, alles-oder-nichts; %d Meldungen im Ablauf" % n)


MUTS = [
    ("HP_ON_S = 120 ", "HP_ON_S = 12 "), ("HP_OFF_S = 300 ", "HP_OFF_S = 30 "), ("HP_SAME_S = 21600", "HP_SAME_S = 600"), ("HP_MAX_H = 3 ", "HP_MAX_H = 4 "),
    ("HP_TRY_S = 1800", "HP_TRY_S = 180"), ('HP_ASA_OK = ("ASA_OK", "ASA_LERNT", "ASA_RUHT")', 'HP_ASA_OK = ("ASA_OK", "ASA_LERNT")'),
    ('        _T4["hb"]["due"] = None', '        pass'),
    ('if l in ("ok", "probe") or', 'if l in ("ok",) or'),
    ('(l == "offline" and live == "SDR_OFFLINE")', '(l == "offline")'),
    ('if live == "SDR_OFFLINE":\n            out["SDR"]', 'if live == "OFFLINE":\n            out["SDR"]'),
    ('elif asa:\n            out["ASA"]', 'elif asa is None:\n            out["ASA"]'),
    ("if trig and isinstance(v, (int, float)):", "if isinstance(v, (int, float)):"),
    ('cand == "unclear" and "Ausfall" in why', 'cand == "unclear"'),
    ('if isinstance(us, dict) and not us.get("stale"):', 'if isinstance(us, dict):'),
    ('elif cand in ("telekom", "starlink"):', 'elif cand in ("telekom",):'),
    ('if bad is None or bool(bad) == bool(k["bad"]):', 'if bool(bad) == bool(k["bad"]):'),
    ("(HP_ON_S if bad else HP_OFF_S)", "(HP_ON_S if bad else HP_ON_S)"),
    ("now - last < HP_SAME_S", "now - last < 0"),
    ('if k.get("sent") and not dropped:', 'if not dropped:'),
    ('            hp["q"] = [e for e in hp["q"] if e.get("keys")]\n', ''),
    ('if len(hp["sent"]) >= HP_MAX_H:', 'if len(hp["sent"]) > HP_MAX_H:'),
    ('if t := 0', 'x'),
    ('hp["sent"] = [t for t in hp["sent"] if isinstance(t, (int, float)) and now - t < 3600]', 'hp["sent"] = [t for t in hp["sent"] if isinstance(t, (int, float)) and now - t < 1800]'),
    ("if now - last < T4_HB_GAP_S:", "if now - last < 0:"),
    ('if _lz_mesh.dab_pending(_t4_alarms(now), base, path, now):\n        return "wait-dab"', 'if False:\n        return "wait-dab"'),
    ("if now < int(e.get(\"next\") or 0) or not _t4_boot_ok():", "if now < int(e.get(\"next\") or 0):"),
    ('if e.get("fail_t") and now - int(e["fail_t"]) > HP_TRY_S:', 'if now - int(e.get("t") or 0) > HP_TRY_S:'),
    ('        e["next"] = now + HP_RETRY_S\n        return "wait-3h"', '        hp["q"].pop(0)\n        return "wait-3h"'),
    ('                hp["last"][x] = now\n', ''),
    ('                    hp["k"][x]["sent"] = True\n', ''),
    ('if r.get("why") == "Auto-Versand AUS (Schalter)" or str(r.get("why") or "").startswith("GESPERRT"):\n        hp["q"].pop(0)', 'if r.get("why") == "Auto-Versand AUS (Schalter)" or str(r.get("why") or "").startswith("GESPERRT"):\n        pass'),
    ('    if not e.get("fail_t"):\n        e["fail_t"] = now\n', '    if True:\n        e["fail_t"] = now\n'),
    ('s = "HB %s STOERUNG: %s" % (hm, "; ".join(parts))', 's = "HB %s PROBE STOERUNG: %s" % (hm, "; ".join(parts))'),
    ("    return s[:HP_MAX_LEN]", "    return s"),
    ('r = _t4_send_m1(text, "teil4_hb")', 'r = _t4_send_m1(text, "teil4_hb_test")'),
    ('    if repr((hp["k"], hp["q"], hp["sent"], hp["last"])) != before:\n        _t4_save()', '    if False:\n        _t4_save()'),
    ('        hp["q"].append({"kind": "on", "keys": ch["on"], "parts": {x: hp["k"][x]["txt"] for x in ch["on"]}, "t": now, "next": now})',
     '        for x in ch["on"]:\n            hp["q"].append({"kind": "on", "keys": [x], "parts": {x: hp["k"][x]["txt"]}, "t": now, "next": now})'),
    ('    _HP["st"] = _selftest_hbproblem()\n', ''),
    ('    if getattr(globals()["_t4_hb_tick"], "_hp", False):\n        raise RuntimeError("schon aktiv")\n', ''),
    ('    _hp_tick._hp = True\n', ''),
    ("import time as _hp_time", "import time as _hp_time\nimport os as _hp_os"),
    ('_t4_say("hbProblem Mesh 1 gesendet:", text)', 'send_dab_to_private_mesh(text)'),
    ('out["LAGE"] = (True, "Lage %s" % str(lv.get("label") or l)[:40])', 'out["LAGE"] = (True, "Lage %s" % str(lv.get("label") or l))'),
]
MUTS = [m for m in MUTS if m[0] != "if t := 0"]


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
        cases.append(("Zeile ausserhalb", neu.replace("T4_HB_GAP_S = 60", "T4_HB_GAP_S = 6", 1), B))
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
    print("%s Mutationstest hbProblem: %d erkannt, %d uebersehen" % ("OK" if missed == 0 else "FEHLER", caught, missed))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    m = sys.argv[1]
    if m == "revert":
        neu = rd(os.path.join(sys.argv[2], "dashboard.py"))
        os.makedirs(sys.argv[3], exist_ok=True)
        open(os.path.join(sys.argv[3], "dashboard.py"), "w", encoding="utf-8").write(revert(neu, sys.argv[4]))
        print("Rueckbau hbProblem ok")
    elif m == "check":
        check(rd(sys.argv[2]), rd(sys.argv[3]), sys.argv[4])
    elif m == "mutate":
        mutate(*sys.argv[2:5])
MK_C52_RAG_EOF
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
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit51, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 - $([[ "$L16" == "$KNOWN_L16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
echo "Basis prepper_sdr.py sha16 $S16 - $([[ "$S16" == "$KNOWN_S16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C50" || "$D16" == "$KNOWN_D16_C49" || "$D16" == "$KNOWN_D16_C48" ]]; then
  WAS="nach commit48 (auch commit49, commit50 und commit51 fehlen)"; [[ "$D16" == "$KNOWN_D16_C49" ]] && WAS="nach commit49 (auch commit50 und commit51 fehlen)"; [[ "$D16" == "$KNOWN_D16_C50" ]] && WAS="nach commit50"
  echo "STOP: erst commit51 anwenden - dashboard.py ist noch der Stand $WAS (sha16 $D16), commit52 braucht $KNOWN_D16 (nach commit51) - nichts geaendert."
  exit 1
fi
if [[ "$SD" == UNBEKANNT ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16) - nichts geaendert."
  echo "      commit52 passt nur auf den Stand nach commit51. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
[[ "$L16" == "$KNOWN_L16" ]] || stop "lage_pages.py ist nicht der Stand nach commit51 ($L16 statt $KNOWN_L16)"
[[ "$S16" == "$KNOWN_S16" ]] || stop "prepper_sdr.py ist nicht der Stand nach commit51 ($S16 statt $KNOWN_S16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
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
  if [[ -n "${C52_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$C52_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$STATE" == neu ]]; then echo "OK Neustart-Sperre: commit52 ist schon installiert, es wird kein Neustart gebraucht"
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
python3 "$W/patch.py" hbProblem dsh "$F" "$W/work/dashboard.py" "$W/blk.py" "$W/edits.py" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer hbProblem nicht eindeutig"; }
[[ "$(s16 "$W/work/dashboard.py")" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $(s16 "$W/work/dashboard.py") statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(wc -l < "$W/work/dashboard.py") Zeilen; $(cat "$W/q.log"))"
python3 "$W/patch.py" hbProblem dsh "$W/work/dashboard.py" "$W/work/x1" "$W/blk.py" "$W/edits.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
rm -f "$W/work/x1"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/patch.py" "$W/edits.py" "$W/blk.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/blk.py" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: hbProblem im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "Guard: Stand ohne hbProblem ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" > "$W/g.log" 2>&1 || { grep -v "^hbProblem" "$W/g.log" | cut -c1-300; stop "Guard hbProblem meldet Verstoss"; }
grep "^Guard hbProblem" "$W/g.log" | cut -c1-900
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Karten-Skript hier statisch geprueft; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C52_SIM_NOMUT:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "Mutationstest hbProblem: eine Verfehlung wurde nicht erkannt"; }
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
t4st() { "${CURL[@]}" "$B/api/t4/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - - -"); sys.exit(0)
t = d.get("tick") or {}
print(int(bool(d.get("ok"))), int(t.get("n") or 0), int(bool(t.get("thread"))), str(((d.get("hb") or {}).get("last") or {}).get("text") or "-").replace(" ", "_")[:60])' 2>/dev/null || echo "FEHLER - - -"; }
read -r T4OK0 T4N0 T4TH0 HBL0 <<< "$(t4st)"
if [[ "$DRY" != 1 ]]; then [[ "$T4OK0" == 1 ]] || stop "teil4 nicht aktiv (/api/t4/status ok=$T4OK0) - commit52 braucht den teil4-Heartbeat"; fi
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
TLAT0=$(tmed "$B/api/t4/status")
echo "Zustand vorher: BR24 $BR_S0, Lage-Ampel (teil4) $T4L0, teil4 aktiv $T4OK0 (Takt $T4N0, Faden $T4TH0), letzter HB: $(echo "$HBL0" | tr '_' ' '), /api/t4/status Median ${TLAT0} s"
NEED=0; [[ "$STATE" == alt ]] && NEED=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED" == 0 ]]; then echo "  Zustand: hbProblem ist schon installiert - ein echter Lauf aendert an dashboard.py nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, teil4-Takt und Journal pruefen, eine sudo-Passwortabfrage. Beim Einspielen wird nichts gesendet; danach kein stuendlicher HB mehr."; fi
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "hbProblem|teil4|Traceback" | tail -6 | cut -c1-240
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
  echo "OK hbProblem schon installiert - kein Neustart, keine Aenderung an dashboard.py"
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
T4OK=0
for i in $(seq 1 30); do
  read -r T4OK1 T4N1 T4TH1 HBL1 <<< "$(t4st)"
  [[ "$T4OK1" == 1 && "$T4N1" -ge 3 ]] && { T4OK=1; break; }
  sleep 4
done
[[ "$T4OK" == 1 ]] || rbx "teil4 nach dem Neustart nicht aktiv oder Takt steht (ok $T4OK1, Takt $T4N1, Faden $T4TH1)"
sleep 6; read -r T4OK2 T4N2 T4TH2 HBL2 <<< "$(t4st)"
[[ "$T4N2" -gt "$T4N1" ]] || rbx "teil4-Takt laeuft nicht weiter ($T4N1 -> $T4N2)"
echo "OK teil4 aktiv, Takt laeuft ($T4N1 -> $T4N2 in 6 s, Faden $T4TH2) - Heartbeat-Pruefung jetzt hbProblem"
TLAT1=$(tmed "$B/api/t4/status")
echo "OK /api/t4/status Median ${TLAT1} s (vorher ${TLAT0} s)"
awk -v a="$TLAT0" -v b="$TLAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/api/t4/status ist deutlich langsamer geworden (${TLAT0} s -> ${TLAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200)"
GEM=$(grep -c "^# ===== hbProblem:" "$F" || true)
[[ "$GEM" == 1 ]] && echo "OK Marker hbProblem 1x" || rbx "dashboard.py hbProblem-Marker ${GEM}x"
read -r BR_S1 BR_H1 BR_G1 <<< "$(brst)"
T4L1=$(t4lv)
[[ "$BR_S1" != FEHLER && "$T4L1" != FEHLER ]] || rbx "/api/br24 oder /api/t4/status nicht lesbar ($BR_S1 / $T4L1)"
echo "OK Zustand nachher: BR24 $BR_S1 (vorher $BR_S0; Halt bis Bestaetigung: $BR_H1, Hinweis: $BR_G1), Lage-Ampel $T4L1 (vorher $T4L0)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep hbProblem"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "hbProblem aktiv: hbProblem ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'hbProblem aktiv: hbProblem ok' ($(echo "$JD" | grep -F hbProblem | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok' 'audioKern aktiv: audioKern ok' 'audioUi aktiv: audioUi ok' 'kartePop aktiv: kartePop ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'hbProblem Selbsttest FEHLER|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'hbProblem Selbsttest FEHLER|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein hbProblem-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
  echo "$JD" | grep -E '^hbProblem|^teil4 aktiv' | tail -3 | cut -c1-200 | sed 's/^/  Journal: /' || true
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Mesh-Regeln (echte Alarme 6 h Dublettenschutz, max 3/h), Gain-Waechter (Stufe 16), lage_pages.py, prepper_sdr.py und alle Dienste ausser prepper-dashboard unberuehrt"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
echo "  Heartbeat: stuendlicher HB aus; Meldung nur bei Problem (120 s), Entwarnung nach 300 s, 6 h je Problem, hoechstens 3/h; Wetter/Pegel unveraendert"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine $NM-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c hbProblem /home/fmg/prepper-dashboard/dashboard.py"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep hbProblem"
echo "  sudo journalctl -u prepper-dashboard --since -3h --no-pager | grep -c Heartbeat"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Beim Einspielen nichts gesendet (kein Mesh, kein Telegram, keine Alarme), keine Einstellung und keine Datenbank geaendert. Neue Docs-Version: bewusst nicht."
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
