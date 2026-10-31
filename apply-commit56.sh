#!/bin/bash
set -eEuo pipefail
# commit56 usvAlarm - USV-Netzausfall hoerbar + ins Mesh (baut auf commit55 auf; NUT bleibt wie es ist, upsmon bleibt aus):
#  - bestaetigter Netzausfall (20 s ohne Netz bzw. > 60 s Akku): EINMAL Gong + Ansage ueber audioKern, auch nachts und bei ausgeschaltetem WARNUNG-Schalter,
#    mit der Regler-Lautstaerke (nie 100 %, kein amixer); Stumm (Audio-Kachel, max 8 h) gilt. Bei 5 min Restlaufzeit eine zweite Ansage. Netz zurueck: kurzer Ton.
#  - Selbsttest (Akku mit Netz < 60 s): nie Ton, nie Mesh.
#  - Mesh: neuer hbProblem-Punkt STROM (bestaetigter Ausfall; 120 s Wartezeit, 6 h gleiches Problem, max 3/h) + Entwarnung nach 5 min Netz. Kein direktes Senden.
#  - Probegong: POST /api/audio/test art pegel (Gong + Pegeltest-Ansage, sofort 202, 10 s Sperre, nie Mesh); Knopf "Audio-Pegel testen" auf /pi nutzt pegel.
#  - USV-Kachel (/lokale-energie): Zeile letzte Ansage + Mesh-Zustand; /api/usv mit Feld alarm.
# Aufruf: bash /tmp/apply-commit56.sh commit56 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 86f712401eddab5f / lage_pages.py 495ee5ac809143c8 / ups_manager.py ef0b9e3d4bf42003 (nach commit55); neu 35fbc0604b09c0dd / 92a37e6326f0900d (ups_manager.py bleibt).
#   prepper_sdr.py 264ef34996e17753 und prepper_evlog.py 8bffd396972b60fa bleiben unveraendert. Stand vor commit55 -> STOP "erst commit55 anwenden".
# Sicherungen DATEI.bak-commit56-ZEIT fuer dashboard.py und lage_pages.py (je letzte 3). Keine Datenbank-Aenderung, keine NUT-Aenderung.
# Neu gestartet wird nur prepper-dashboard (prepper-sdr und Mesh-Bruecken bleiben). Gain-Stufe 16 bleibt. Beim Einspielen wird nichts gesendet und nichts abgespielt.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
FL="$DASH_DIR/lage_pages.py"
FU="$DASH_DIR/ups_manager.py"
FS="$DASH_DIR/prepper_sdr.py"
FE="$DASH_DIR/prepper_evlog.py"
VENV="$DASH_DIR/venv"
VPY="$VENV/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/commit56-apply
KEEP_LAST=3
NM=commit56
KNOWN_D16="86f712401eddab5f"; KNOWN_D16N="35fbc0604b09c0dd"; KNOWN_D16_C54="7b81384b4af00883"; KNOWN_D16_C53="832787ef1c3b44bc"
KNOWN_L16="495ee5ac809143c8"; KNOWN_L16N="92a37e6326f0900d"; KNOWN_L16_C54="a51d9b51a646813d"; KNOWN_U16="ef0b9e3d4bf42003"
KNOWN_S16="264ef34996e17753"; KNOWN_E16="8bffd396972b60fa"
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
SIM=0; [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && SIM=1
echo "=== commit56 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): usvAlarm (Ansage + Mesh-Punkt STROM bei Netzausfall, Probegong pegel), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/G"
EXPECT_PAT="83f4ff984ec710b401b6e95015cdbe9b51aadd139fdd5c05782899c2b5a0bfaa"
cat > "$W/patch.py" << 'MK_C56_PAT_EOF'
"""Patcher commit56 (generisch wie commit55). Aufruf: patch.py NAME dsh|lp QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
name = {"dsh": "dashboard.py", "lp": "lage_pages.py"}[kind]
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
MK_C56_PAT_EOF
EXPECT_EDI="a8969089c083a9a6c87ad2a3c5d27b3ecc1e24f029c46c369d9138525c6ba207"
cat > "$W/edits.py" << 'MK_C56_EDI_EOF'
"""Stellen commit56: dashboard.py ein Block vor __main__ (usvAlarm, nach usvLesen); lage_pages.py vier Stellen in der USV-Kachel (Zeile usvAlarm, Info-Text)."""
_A = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
DSH_ANCHOR = _A
LP_EDITS = [('    <div class="small" id="usvTest"></div>\n', '    <div class="small" id="usvTest"></div>\n    <div class="small" id="usvAlarm"></div>\n'), ('Nur Anzeige: kein Ton, kein Mesh, kein Herunterfahren.</div>', 'Netzausfall (bestätigt nach 20 s ohne Netz bzw. nach 60 s): einmal Gong + Ansage, auch nachts, mit Regler-Lautstärke (Stumm gilt); bei 5 min Restlaufzeit eine zweite Ansage; bei Netzrückkehr ein kurzer Ton. Mesh: Punkt STROM über hbProblem (nach 120 s, höchstens alle 6 h, Entwarnung nach 5 min Netz). Selbsttest: nie Ton, nie Mesh. Kein Herunterfahren.</div>'), ('  function show(d){\n', "  function alarm(d){var a=d.alarm||{};tx('usvAlarm',a.txt?String(a.txt).slice(0,200):'');}\n  function show(d){\n"), ('    var sh=soh(d);test(d);\n', '    var sh=soh(d);test(d);alarm(d);\n')]
LP_ANCHOR = None
MK_C56_EDI_EOF
EXPECT_BDS="fd584aadab3302d6dd4f4aca56d33a189ce757853748a766bbea69ec23a59271"
cat > "$W/G/blk_dsh.py" << 'MK_C56_BDS_EOF'
# ===== usvAlarm: USV-Netzausfall (usvLesen) -> einmal Gong + Ansage ueber audioKern bei bestaetigtem Ausfall (20 s ohne Netz bzw. > 60 s), auch nachts und ohne WARNUNG-Schalter, Regler-Lautstaerke (nie 100 %, kein amixer), Stumm wird beachtet; zweite Ansage bei 5 min Restlaufzeit; kurzer Ton bei Netzrueckkehr; Selbsttest nie; Mesh ueber hbProblem-Punkt STROM (120 s, 6 h, max 3/h, Entwarnung); Probegong art pegel (POST /api/audio/test, Knopf auf /pi); /api/usv mit Zeile alarm =====
import threading as _usva_th
import time as _usva_time

USVA_TXT_AUSFALL = "Achtung. Primärer Netzausfall detektiert. Das Lagezentrum läuft ab jetzt auf ununterbrochener Notstromversorgung."
USVA_TXT_LOW = "Achtung. Die Notstromversorgung reicht nur noch etwa fünf Minuten."
USVA_TXT_PEGEL = "Akustischer Pegeltest erfolgreich abgeschlossen. Die Audio-Schilder des Lagezentrums sind vollständig einsatzbereit."
USVA_TXT_RUECK = "Netz wieder da"
USVA_LOW_S = 300                 # zweite Ansage bei <= 5 min Restlaufzeit (runtime_smoothed)
USVA_POLL_S = 2.0
USVA_EXP_S = 1800
_USVA = {"ok": False, "err": None, "started": False, "active": None, "ann": None, "low": None, "last": [], "orig_out": None, "orig_probe": None, "orig_api": None,
         "mesh": False, "fake_snap": None, "n": 0}


def _usva_hm(t):
    return _usva_time.strftime("%H:%M", _usva_time.localtime(int(t)))


def _usva_snap():
    f = _USVA.get("fake_snap")
    if callable(f):
        return f()
    m = (globals().get("_USV") or {}).get("mgr")
    return m.snapshot() if m is not None else None


def _usva_note(now, art, why):
    _USVA["last"] = ([{"t": int(now), "art": art, "why": str(why)[:60]}] + _USVA["last"])[:6]


def _usva_offer(art, text, now, nur_ton=False, note=True):
    """In die audioKern-Warteschlange (Stufe WARNUNG, Quelle USV): ohne Schalter/Nachtruhe/Budget, aber Stumm gilt. -> (ok, Grund)"""
    if not _AU.get("started"):
        r = (False, "Audio-Faden laeuft nicht")
    elif _au_muted(_au_cfg(), now):
        r = (False, "stumm (Audio-Kachel)")
    else:
        with _AU_LOCK:
            ok, why = _au_offer("WARNUNG", "USV", "%s-%d" % (art, int(now)), text, now, force=True)
            if ok:
                it = _AU["q"][-1]
                it.update(test=False, nur_ton=bool(nur_ton), exp=now + USVA_EXP_S)
        r = (ok, why)
    if note:
        _usva_note(now, art, r[1])
        _au_log("USV %s: %s" % (art, r[1]))
    return r


def _usva_out(it):
    """Ersetzt audioKern _au_out nur fuer USV-Toene ohne Ansage (Netzrueckkehr): Klick, keine Sprache, keine Lautstaerke-Aenderung."""
    if not it.get("nur_ton"):
        return _USVA["orig_out"](it)
    steps = []
    with _AU_LOCK:
        _AU.update(cur=it, abort=False)
    try:
        tone = (_AU["tones"].get("klick") or {}).get("path")
        if tone:
            ok, d = _au_play(tone, AU_LIMIT["ton"])
            steps.append("Ton %s" % (d if ok else "Fehler (%s)" % d))
        else:
            steps.append("Ton fehlt")
    except Exception as e:
        steps.append("Fehler %s" % type(e).__name__)
    finally:
        now = _usva_time.time()
        with _AU_LOCK:
            _AU["n"][it["lvl"]] += 1
            _AU["last"] = ([{"t": int(now), "lvl": it["lvl"], "src": it["src"], "text": it["text"][:90], "steps": steps, "abort": _AU["abort"], "test": False}] + _AU["last"])[:10]
            _AU.update(cur=None, proc=None, abort=False)
        _au_log("%s %s (nur Ton): %s" % (it["lvl"], it["src"], " · ".join(steps)))
    return steps


def _usva_step(d, now, offer=None):
    """Zustand der USV-Ansagen. d = /api/usv-Inhalt. -> Liste der Aktionen (art, ok)."""
    offer = offer or _usva_offer
    out = []
    if not isinstance(d, dict):
        return out
    ob = d.get("ob") if isinstance(d.get("ob"), dict) else None
    md = d.get("mode")
    if ob and ob.get("kind") == "ausfall" and md == "AKKU":
        sid = int(ob.get("since") or 0)
        if _USVA["ann"] != sid:
            _USVA.update(ann=sid, active=sid)
            out.append(("ausfall", offer("ausfall", USVA_TXT_AUSFALL, now)[0]))
        rs = d.get("runtime_smoothed_s")
        if isinstance(rs, (int, float)) and rs <= USVA_LOW_S and _USVA["low"] != sid:
            _USVA["low"] = sid
            out.append(("5min", offer("5min", USVA_TXT_LOW, now)[0]))
    elif _USVA["active"] is not None and md == "NETZ" and not ob:
        _USVA["active"] = None
        out.append(("rueckkehr", offer("rueckkehr", USVA_TXT_RUECK, now, True)[0]))
    return out


def _usva_strom(d):
    """hbProblem-Punkt STROM: (True, Text) nur bei bestaetigtem Netzausfall; (False, '') bei Netzbetrieb; sonst (None, '') - Pruefung/Selbsttest nie."""
    if not isinstance(d, dict):
        return (None, "")
    ob = d.get("ob") if isinstance(d.get("ob"), dict) else None
    if d.get("mode") == "AKKU" and ob and ob.get("kind") == "ausfall":
        rs = d.get("runtime_smoothed_s")
        return (True, "Netzausfall seit %s, USV ca. %s min" % (_usva_hm(ob.get("since") or 0), int(rs // 60) if isinstance(rs, (int, float)) else "?"))
    if d.get("mode") == "NETZ" and not ob:
        return (False, "")
    return (None, "")


def _usva_probe(now):
    out = _USVA["orig_probe"](now)
    try:
        out["STROM"] = _usva_strom(_usva_snap())
    except Exception:
        out["STROM"] = (None, "")
    return out


def _usva_mesh_txt():
    if not _USVA["mesh"]:
        return "Mesh: aus (hbProblem nicht aktiv)"
    try:
        hp = _hp_state()
        k = hp["k"].get("STROM") or {}
        last = hp["last"].get("STROM")
        if any(e.get("kind") == "on" and "STROM" in (e.get("keys") or []) for e in hp["q"]):
            return "Mesh: STROM wartet auf Versand"
        if k.get("bad") and k.get("sent"):
            return "Mesh: STROM gemeldet %s" % _usva_hm(last or 0)
        if k.get("cand") is True:
            return "Mesh: STROM prueft (120 s)"
        if any(e.get("kind") == "off" and "STROM" in (e.get("keys") or []) for e in hp["q"]):
            return "Mesh: Entwarnung wartet auf Versand"
        return "Mesh: bereit (STROM)" + (", zuletzt %s" % _usva_hm(last) if isinstance(last, (int, float)) else "")
    except Exception as e:
        return "Mesh: Status nicht lesbar (%s)" % type(e).__name__


def _usva_info():
    la = _USVA["last"][0] if _USVA["last"] else None
    a = ("Ansage %s %s: %s" % ({"ausfall": "Netzausfall", "5min": "5 min", "rueckkehr": "Netz zurueck (Ton)"}.get(la["art"], la["art"]), _usva_hm(la["t"]), la["why"])
         if la else "Ansage: bereit")
    return {"txt": "%s · %s" % (a, _usva_mesh_txt()), "last": list(_USVA["last"]), "faden": _USVA["started"]}


def _usva_api():
    from flask import jsonify
    resp = _USVA["orig_api"]()
    try:
        d = resp.get_json()
        if isinstance(d, dict):
            d["alarm"] = _usva_info()
            resp = jsonify(d)
    except Exception as e:
        print("usvAlarm /api/usv:", type(e).__name__, flush=True)
    resp.headers["Cache-Control"] = "no-store"
    return resp


def _usva_worker():
    while True:
        try:
            _usva_step(_usva_snap(), _usva_time.time())
            _USVA["n"] += 1
        except Exception as e:
            _USVA["err"] = "%s: %s" % (type(e).__name__, str(e)[:120])
            print("usvAlarm: Faden-Fehler:", _USVA["err"], flush=True)
            _usva_time.sleep(10)
        _usva_time.sleep(USVA_POLL_S)


def _selftest_usvalarm():
    keep = {k: (list(v) if isinstance(v, list) else v) for k, v in _USVA.items()}
    rec = []

    def off(art, text, now, nur_ton=False):
        rec.append((art, text, bool(nur_ton)))
        return (True, "ok")
    try:
        t0 = 1793450000
        net = {"mode": "NETZ", "ok": True}
        pr = {"mode": "AKKU_PRUEF", "ok": True, "ob": {"since": t0, "kind": "pruef", "mains": True}, "runtime_smoothed_s": 900}
        au = {"mode": "AKKU", "ok": True, "ob": {"since": t0, "kind": "ausfall", "mains": False}, "runtime_smoothed_s": 900}
        _USVA.update(active=None, ann=None, low=None, last=[])
        # Selbsttest: OB mit Netz, zurueck auf NETZ -> nie Ton
        assert _usva_step(pr, t0 + 5, off) == [] and _usva_step(net, t0 + 14, off) == [] and rec == []
        assert _usva_strom(pr) == (None, "") and _usva_strom(net) == (False, "") and _usva_strom({"mode": "KEINE_DATEN"}) == (None, "")
        # Ausfall bestaetigt: genau eine Ansage, auch spaeter nicht noch einmal
        assert _usva_step(au, t0 + 21, off) == [("ausfall", True)] and rec[-1] == ("ausfall", USVA_TXT_AUSFALL, False)
        assert _usva_step(dict(au, runtime_smoothed_s=600), t0 + 60, off) == [] and len(rec) == 1
        s = _usva_strom(dict(au, runtime_smoothed_s=2280))
        assert s[0] is True and "Netzausfall seit %s, USV ca. 38 min" % _usva_hm(t0) == s[1], s
        # 5 min Restlaufzeit: genau eine zweite Ansage
        assert _usva_step(dict(au, runtime_smoothed_s=300), t0 + 600, off) == [("5min", True)] and _usva_step(dict(au, runtime_smoothed_s=200), t0 + 700, off) == []
        assert rec[-1] == ("5min", USVA_TXT_LOW, False) and len(rec) == 2
        # Rueckkehr: kurzer Ton (ohne Ansage), einmal
        assert _usva_step(net, t0 + 800, off) == [("rueckkehr", True)] and rec[-1] == ("rueckkehr", USVA_TXT_RUECK, True) and _usva_step(net, t0 + 900, off) == []
        # neuer Ausfall = neue Ansage; Rueckkehr nur nach bestaetigtem Ausfall
        au2 = dict(au, ob={"since": t0 + 5000, "kind": "ausfall", "mains": False})
        assert _usva_step(au2, t0 + 5021, off) == [("ausfall", True)] and len(rec) == 4
        _USVA.update(active=None)
        assert _usva_step(net, t0 + 6000, off) == [] and _usva_step(None, t0, off) == []
        # Angebot an audioKern: WARNUNG/USV, kein Test, Stumm gilt, Nachtruhe/Schalter nicht
        with _AU_LOCK:                   # laufender Ausgabe-Faden darf den Probe-Eintrag nie sehen
            kq, ks, kst, kfk = list(_AU["q"]), dict(_AU["seen"]), _AU["started"], _AU.get("fake")
            try:
                _AU.update(q=[], started=True)
                lt = list(_usva_time.localtime())
                night = _usva_time.mktime(tuple(lt[:3] + [23, 30, 0] + lt[6:8] + [-1]))
                assert _au_night(night)
                muted = _au_muted(_au_cfg(), night)
                ok, why = _usva_offer("ausfall", USVA_TXT_AUSFALL, night, note=False)
                if muted:
                    assert not ok and "stumm" in why, why
                else:
                    it = _AU["q"][-1]
                    assert ok and len(_AU["q"]) == 1 and it["lvl"] == "WARNUNG" and it["src"] == "USV" and it["test"] is False and not it["nur_ton"], it
                    assert it["text"] == USVA_TXT_AUSFALL and it["exp"] == night + USVA_EXP_S
                ok, why = _usva_offer("rueckkehr", USVA_TXT_RUECK, night, True, note=False)
                assert muted or (ok and _AU["q"][-1]["nur_ton"] is True)
                _AU.update(q=[], started=False)
                assert _usva_offer("ausfall", "x", night, note=False) == (False, "Audio-Faden laeuft nicht")
                # nur Ton: Klick ueber _au_play, keine Sprache, keine Lautstaerke
                calls = []
                kp, kv = globals()["_au_play"], _AU["tones"]
                try:
                    globals()["_au_play"] = lambda path, limit: (calls.append((path, limit)), (True, "probe"))[1]
                    _AU["tones"] = {"klick": {"path": "/probe/klick.wav"}}
                    kl, kn, kqu = list(_AU["last"]), dict(_AU["n"]), _AU.get("quiet")
                    _AU["quiet"] = True
                    st = _usva_out({"lvl": "WARNUNG", "src": "USV", "text": USVA_TXT_RUECK, "nur_ton": True})
                    assert st == ["Ton probe"] and calls == [("/probe/klick.wav", AU_LIMIT["ton"])], (st, calls)
                    assert _AU["last"][0]["src"] == "USV" and _AU["cur"] is None
                    _AU["last"], _AU["n"], _AU["quiet"] = kl, kn, kqu
                finally:
                    globals()["_au_play"], _AU["tones"] = kp, kv
            finally:
                _AU.update(q=kq, seen=ks, started=kst, fake=kfk)
        # Probegong und Knopf
        assert AU_TEST_TXT.get("pegel") == ("WARNUNG", USVA_TXT_PEGEL) and "art:'pegel'" in _AUI_JS and "art:'warnung'" not in _AUI_JS
        # Anzeige
        _USVA["last"] = [{"t": t0, "art": "ausfall", "why": "ok"}]
        assert _usva_info()["txt"].startswith("Ansage Netzausfall %s: ok · Mesh: " % _usva_hm(t0))
        for bad in ("amixer", "_au_vol(", "_t4_send", "send_m1", "shutdown", "upsmon"):
            assert bad not in USVA_TXT_AUSFALL + USVA_TXT_LOW + USVA_TXT_PEGEL
    finally:
        _USVA.clear()
        _USVA.update(keep)
    return ("usvAlarm ok (Netzausfall: eine Ansage nach Bestaetigung, auch nachts, Regler-Lautstaerke, Stumm gilt; 5 min: eine zweite Ansage; Rueckkehr: nur Ton; Selbsttest nie; "
            "Mesh-Punkt STROM ueber hbProblem; Probegong art pegel)")


def _usva_install():
    g = globals()
    if not _AU.get("aktiv"):
        raise RuntimeError("audioKern nicht aktiv")
    if not isinstance(g.get("_USV"), dict) or not callable(g.get("_usv_api")):
        raise RuntimeError("usvLesen fehlt")
    AU_TEST_TXT["pegel"] = ("WARNUNG", USVA_TXT_PEGEL)
    g["AUI_TEST_ART"] = "pegel"
    g["_AUI_JS"] = g["_AUI_JS"].replace("art:'warnung'", "art:'pegel'").replace("Test laeuft (Gong + Ansage mit Regler-Pegel, nicht ins Mesh)",
                                                                             "Pegeltest laeuft (Gong + Ansage mit Regler-Pegel, nicht ins Mesh)")
    if not getattr(g["_au_out"], "_usva", False):
        _USVA["orig_out"] = g["_au_out"]
        _usva_out._usva = True
        g["_au_out"] = _usva_out
    if _HP.get("ok") and not getattr(g["_hp_probe"], "_usva", False):
        _USVA["orig_probe"] = g["_hp_probe"]
        _usva_probe._usva = True
        g["_hp_probe"] = _usva_probe
        if "STROM" not in g["HP_KEYS"]:
            g["HP_KEYS"] = tuple(g["HP_KEYS"]) + ("STROM",)
        HP_NAMES["STROM"] = "Netzstrom"
    _USVA["mesh"] = getattr(g["_hp_probe"], "_usva", False)
    vf = app.view_functions.get("usv_api")
    if vf is None:
        raise RuntimeError("/api/usv fehlt")
    if not getattr(vf, "_usva", False):
        _USVA["orig_api"] = vf
        _usva_api._usva = True
        app.view_functions["usv_api"] = _usva_api


try:
    _usva_install()
    _USVA["st"] = _selftest_usvalarm()
    _USVA["ok"] = True
    if __name__ == "__main__" and not _USVA["started"]:
        _USVA["started"] = True
        _usva_th.Thread(target=_usva_worker, name="usvAlarm", daemon=True).start()
    print("usvAlarm aktiv: %s; Mesh STROM %s; Faden %s" % (_USVA["st"], "an" if _USVA["mesh"] else "AUS (hbProblem nicht aktiv)", "laeuft" if _USVA["started"] else "nur im Hauptprogramm"), flush=True)
except Exception as _usva_e:
    _USVA["err"] = "%s: %s" % (type(_usva_e).__name__, str(_usva_e)[:200])
    print("usvAlarm Selbsttest FEHLER (%s) - keine USV-Ansage, Dashboard laeuft weiter" % _USVA["err"], flush=True)
# ===== /usvAlarm =====
MK_C56_BDS_EOF
EXPECT_GRD="a86b351d63d7d65df6ebc09b03dca48c3ad01fe7aa9ec8b22105c0f8239aae14"
cat > "$W/guard.py" << 'MK_C56_GRD_EOF'
"""Guard commit56 (usvAlarm dashboard.py, Zeile usvAlarm + Info-Text in der USV-Kachel lage_pages.py).
  guard.py revert NEU_VERZ ALT_VERZ W   -> ALT_VERZ/{dashboard,lage_pages}.py = NEU ohne commit56 (byte-genau)
  guard.py check  ALT_VERZ NEU_VERZ W   -> Rueckbau = ALT, statische Regeln, Verhalten mit echten audioKern-/hbProblem-Funktionen (aus dashboard.py) und Attrappen, Kachel (node falls vorhanden)
  guard.py mutate ALT_VERZ NEU_VERZ W   -> Mutationstest (jede Mutation muss check scheitern lassen)
W enthaelt blk_dsh.py, edits.py. GUARD_NO_NODE=1 schaltet den node-Test ab."""
import ast, contextlib, io, json, os, re, shutil, subprocess, sys, tempfile, threading, time

ANCH = '\n\nif __name__ == "__main__":\n'
MK = "usvAlarm"
PREV_MK = "# ===== /usvLesen =====\n"
CONSTS = {"USVA_TXT_AUSFALL": "Achtung. Primärer Netzausfall detektiert. Das Lagezentrum läuft ab jetzt auf ununterbrochener Notstromversorgung.",
          "USVA_TXT_LOW": "Achtung. Die Notstromversorgung reicht nur noch etwa fünf Minuten.",
          "USVA_TXT_PEGEL": "Akustischer Pegeltest erfolgreich abgeschlossen. Die Audio-Schilder des Lagezentrums sind vollständig einsatzbereit.",
          "USVA_LOW_S": 300, "USVA_POLL_S": 2.0, "USVA_EXP_S": 1800}
BAD_ID = re.compile(r"^(subprocess|Popen|system|popen|eval|exec|__import__|urlopen|requests|socket|sqlite3|open|_au_vol|_t4_vol|_t4_send_m1|_t4_send|send_meshtastic|_hp_send|_t4_cascade|_au_t4_cascade|_au_spawn|_au_kill_cur)$")
BAD_STR = ["amixer", "upsmon", "shutdown", "poweroff", "KATASTROPHE", "100 %", "INSTCMD", "SET VAR", "FSD", "/etc/nut"]
NEED = ['_au_offer("WARNUNG", "USV", "%s-%d" % (art, int(now)), text, now, force=True)', 'it.update(test=False, nur_ton=bool(nur_ton), exp=now + USVA_EXP_S)',
        'elif _au_muted(_au_cfg(), now):', 'if __name__ == "__main__" and not _USVA["started"]:', 'app.view_functions["usv_api"] = _usva_api', 'HP_NAMES["STROM"] = "Netzstrom"',
        'AU_TEST_TXT["pegel"] = ("WARNUNG", USVA_TXT_PEGEL)', '_USVA["st"] = _selftest_usvalarm()', 'resp.headers["Cache-Control"] = "no-store"']
JS_NEED = ["  function alarm(d){var a=d.alarm||{};tx('usvAlarm',a.txt?String(a.txt).slice(0,200):'');}\n", "    var sh=soh(d);test(d);alarm(d);\n", '    <div class="small" id="usvAlarm"></div>\n']
AU_NAMES = ["AU_PRIO", "AU_EXPIRE_S", "AU_TXT_MAX", "AU_BUDGET_H", "AU_DEDUP_S", "AU_NIGHT", "AU_MUTE_MAX_H", "AU_QMAX", "AU_TEST_GAP_S", "AU_LIMIT", "AU_TEST_TXT", "AU_VOL_DEFAULT",
            "_AUI_JS", "HP_KEYS", "HP_NAMES", "HP_ON_S", "HP_OFF_S", "HP_SAME_S", "HP_MAX_LEN", "_au_muted", "_au_night", "_au_clean", "_au_offer", "_au_pick", "_au_api_test", "_hp_eval", "_hp_text"]
NODE_JS = r"""
const fs=require('fs');const code=fs.readFileSync(process.argv[2],'utf8');const cases=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
(async()=>{const out=[];for(const d of cases){const E={};const doc={visibilityState:'visible',getElementById:(i)=>{if(!E[i])E[i]={id:i,textContent:'',className:'',hidden:i==='usvInfo',style:{},addEventListener(){}};return E[i];},addEventListener(){}};
 const f=new Function('document','fetch','setInterval','setTimeout',code);f(doc,(u,o)=>Promise.resolve({json:()=>Promise.resolve(d)}),()=>0,()=>0);
 for(let k=0;k<4;k++)await new Promise(r=>setImmediate(r));
 out.push({alarm:E.usvAlarm?E.usvAlarm.textContent:'',main:E.usvMain?E.usvMain.textContent:''});}
 process.stdout.write(JSON.stringify(out));})();
"""


def rd(p):
    return open(p, encoding="utf-8").read()


def fail(m):
    print("VERSTOSS:", m)
    sys.exit(1)


def edits(W):
    g = {}
    exec(compile(rd(os.path.join(W, "edits.py")), "edits", "exec"), g)
    return g


def blk(W):
    return rd(os.path.join(W, "blk_dsh.py")).rstrip("\n") + "\n"


def revert_all(neud, W):
    E = edits(W)
    B = blk(W)
    d = rd(os.path.join(neud, "dashboard.py"))
    bx = "\n\n" + B.rstrip("\n")
    assert d.count(PREV_MK.rstrip("\n") + bx + ANCH) == 1, "Block nicht genau einmal direkt nach usvLesen vor __main__"
    d = d.replace(bx + ANCH, ANCH, 1)
    assert "# ===== %s:" % MK not in d and "_usva_" not in d and "USVA_" not in d, "Reste ausserhalb des Blocks"
    assert E["DSH_EDITS"] == [] and len(E["LP_EDITS"]) == 4, "Stellen: dashboard nur Block, lage_pages genau vier Stellen"
    lp = rd(os.path.join(neud, "lage_pages.py"))
    for o, n in E["LP_EDITS"]:
        assert lp.count(n) == 1, "Kachel-Stelle nicht genau einmal: %s" % n[:60]
        lp = lp.replace(n, o, 1)
    assert "usvAlarm" not in lp and "alarm(d)" not in lp, "Kachel-Reste ausserhalb der Stellen"
    return {"dashboard.py": d, "lage_pages.py": lp}


def static_dsh(B):
    if not B.startswith("# ===== %s:" % MK) or not B.rstrip("\n").endswith("# ===== /%s =====" % MK):
        fail("Block beginnt/endet nicht mit Marker")
    try:
        T = ast.parse(B)
    except SyntaxError as e:
        fail("Syntax %s" % e)
    seen = {}
    st_nodes = set()
    for n in T.body:
        if isinstance(n, ast.FunctionDef) and n.name == "_selftest_usvalarm":
            st_nodes = {id(x) for x in ast.walk(n)}
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in CONSTS:
            seen[n.targets[0].id] = ast.literal_eval(n.value)
    for k, v in CONSTS.items():
        if seen.get(k) != v:
            fail("Konstante %s = %r (erwartet %r)" % (k, seen.get(k), v))
    for n in ast.walk(T):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module]
            for x in names:
                if x not in ("threading", "time", "flask"):
                    fail("Import %s nicht erlaubt" % x)
        if isinstance(n, ast.Name) and BAD_ID.match(n.id) or isinstance(n, ast.Attribute) and BAD_ID.match(n.attr):
            fail("verbotener Name %s" % (getattr(n, "id", None) or n.attr))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in st_nodes:
            for b in BAD_STR:
                if b in n.value:
                    fail("verbotener Text %r" % b)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else (f.id if isinstance(f, ast.Name) else "")
            if nm in ("add_url_rule", "route", "after_request", "before_request", "write", "remove", "unlink"):
                fail("%s nicht erlaubt" % nm)
            if nm == "Thread" and ast.unparse(n) != "_usva_th.Thread(target=_usva_worker, name='usvAlarm', daemon=True)":
                fail("Faden nur usvAlarm (daemon)")
            if nm == "_au_offer":
                a = ast.unparse(n)
                if not a.startswith("_au_offer('WARNUNG', 'USV',"):
                    fail("audioKern nur Stufe WARNUNG/Quelle USV: %s" % a[:80])
    for x in NEED:
        if B.count(x) != 1:
            fail("Pflichtstelle fehlt: %s" % x[:80])
    return "dashboard.py: Marker, Konstanten (Ansagetexte, 300 s, 2 s), audioKern nur WARNUNG/USV, kein amixer/Lautstaerke, kein Mesh-Senden direkt (nur hbProblem), keine neue Route, Faden nur im Hauptprogramm"


def extract(neud):
    src = rd(os.path.join(neud, "dashboard.py"))
    T = ast.parse(src)
    parts = {}
    for n in T.body:
        nm = n.name if isinstance(n, ast.FunctionDef) else (n.targets[0].id if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) else None)
        if nm in AU_NAMES and nm not in parts:
            parts[nm] = ast.get_source_segment(src, n)
    miss = [x for x in AU_NAMES if x not in parts]
    if miss:
        fail("Basis-Funktionen fehlen in dashboard.py: %s" % miss)
    return "\n\n".join(parts[x] for x in AU_NAMES) + "\n"


class Snap:
    def __init__(self):
        self.d = {"mode": "KEINE_DATEN", "ok": False}

    def snapshot(self):
        return dict(self.d)


def env(neud, name, cfg, flask):
    app = flask.Flask("g56" + name)
    snap = Snap()
    hp = {"k": {}, "q": [], "sent": [], "last": {}}
    played, out_orig = [], []
    g = {"__name__": name, "_au_time": time, "_hp_time": time, "app": app, "_AU_LOCK": threading.RLock()}
    g["_AU_CV"] = threading.Condition(g["_AU_LOCK"])
    g["_AU"] = {"aktiv": True, "started": True, "q": [], "cur": None, "abort": False, "proc": None, "last": [], "sent": [], "seen": {}, "test_t": 0, "drop": {},
                "n": {"KATASTROPHE": 0, "WARNUNG": 0, "INFO": 0, "TEST": 0}, "tones": {"klick": {"path": "/g/klick.wav"}, "gong": {"path": "/g/gong.wav"}}, "quiet": True}
    g["_HP"] = {"ok": True}
    g["_USV"] = {"mgr": snap}
    exec(compile(extract(neud), "basis", "exec"), g)
    g.update(_au_cfg=lambda path=None: dict(cfg), _au_log=lambda *a: None, _au_kill_cur=lambda: None, _t4_say=lambda *a: None, _hp_state=lambda: hp,
             _au_play=lambda path, limit: (played.append((path, limit)), (True, "dev"))[1], _au_out=lambda it: out_orig.append(it))

    def usv_api():
        r = flask.jsonify(snap.snapshot())
        r.headers["Cache-Control"] = "no-store"
        return r
    g["_usv_api"] = usv_api
    app.add_url_rule("/api/usv", endpoint="usv_api", view_func=usv_api, methods=["GET"])
    app.add_url_rule("/api/audio/test", endpoint="au_test", view_func=lambda: g["_au_api_test"](), methods=["POST"])
    hp0 = g["_hp_probe"] = lambda now: {k: (None, "") for k in g["HP_KEYS"]}
    return g, snap, hp, played, out_orig, hp0


def beh(B, neud):
    import flask
    t0 = time.mktime(time.localtime()[:3] + (23, 10, 0, 0, 0, -1))      # nachts
    cfg = {"info": False, "warn": False, "vol": 55, "mute_until": 0}
    res = []
    for name in ("g56test", "__main__"):
        g, snap, hp, played, out_orig, hp0 = env(neud, name, cfg, flask)
        if name == "__main__":
            g["_usva_th"] = None                     # Faden nicht wirklich starten: Ersatz zaehlt
        o = io.StringIO()
        with contextlib.redirect_stdout(o):
            try:
                exec(compile(B.replace("_usva_th.Thread(target=_usva_worker, name=\"usvAlarm\", daemon=True).start()", "_USVA.update(thr=1)") if name == "__main__" else B, "blk", "exec"), g)
            except Exception as e:
                raise AssertionError("Block wirft %s: %s" % (type(e).__name__, e))
        txt = o.getvalue()
        assert "usvAlarm aktiv: usvAlarm ok (" in txt and "Mesh STROM an" in txt, txt[:400]
        U = g["_USVA"]
        assert U["ok"] and U["started"] == (name == "__main__") and (U.get("thr") == 1) == (name == "__main__"), "Faden nur im Hauptprogramm"
        rules = sorted(r.rule for r in g["app"].url_map.iter_rules() if r.rule != "/static/<path:filename>")
        assert rules == ["/api/audio/test", "/api/usv"], rules
        res.append(name)
    AU, U = g["_AU"], g["_USVA"]
    step = g["_usva_step"]
    net = {"mode": "NETZ", "ok": True}
    pr = {"mode": "AKKU_PRUEF", "ok": True, "ob": {"since": t0, "kind": "pruef", "mains": True, "dur_s": 8}, "runtime_smoothed_s": 900}
    au = {"mode": "AKKU", "ok": True, "ob": {"since": t0, "kind": "ausfall", "mains": False, "dur_s": 25}, "runtime_smoothed_s": 960}
    # Selbsttest: nie Ton, nie Mesh
    for d, tt in ((net, t0), (pr, t0 + 5), (pr, t0 + 50), (net, t0 + 60)):
        snap.d = d
        step(d, tt)
        g["_hp_eval"](tt)
    assert AU["q"] == [] and hp["q"] == [] and not U["last"], ("Selbsttest", AU["q"], hp["q"])
    # Ausfall nachts, Schalter WARNUNG aus, Budget voll -> trotzdem genau eine Ansage
    AU["sent"] = [(t0 - 10, "WARNUNG")] * 9
    snap.d = au
    assert step(au, t0 + 21) == [("ausfall", True)], U["last"]
    assert len(AU["q"]) == 1 and AU["q"][0]["text"] == CONSTS["USVA_TXT_AUSFALL"] and AU["q"][0]["lvl"] == "WARNUNG" and AU["q"][0]["test"] is False, AU["q"]
    for k in range(10):
        step(dict(au, runtime_smoothed_s=900 - k), t0 + 30 + 2 * k)
    assert len(AU["q"]) == 1, "nur einmal je Ausfall"
    it = g["_au_pick"](t0 + 40)
    assert it and it["src"] == "USV"
    g["_au_out"](it)
    assert out_orig and out_orig[-1]["text"] == CONSTS["USVA_TXT_AUSFALL"] and played == [], "Ansage ueber audioKern-Ausgabe (Gong + Sprache), nicht nur Ton"
    # Mesh STROM: nach 120 s bestaetigt -> eine Meldung; Text
    for tt in range(int(t0) + 21, int(t0) + 21 + 125, 2):
        g["_hp_eval"](tt)
    on = [e for e in hp["q"] if e["kind"] == "on"]
    assert len(on) == 1 and on[0]["keys"] == ["STROM"] and on[0]["parts"]["STROM"].startswith("Netzausfall seit %s, USV ca. " % time.strftime("%H:%M", time.localtime(t0))), hp["q"]
    assert g["_hp_text"]("on", [on[0]["parts"]["STROM"]], t0).startswith("HB "), "Text"
    hp["q"] = []
    hp["k"]["STROM"]["sent"] = True
    hp["last"]["STROM"] = t0 + 150
    # 5 min
    assert step(dict(au, runtime_smoothed_s=301), t0 + 600) == []
    assert step(dict(au, runtime_smoothed_s=300), t0 + 602) == [("5min", True)] and AU["q"][-1]["text"] == CONSTS["USVA_TXT_LOW"]
    assert step(dict(au, runtime_smoothed_s=120), t0 + 700) == []
    AU["q"] = []
    # Rueckkehr: nur Ton (klick), Entwarnung nach 5 min
    snap.d = net
    assert step(net, t0 + 800) == [("rueckkehr", True)] and AU["q"][-1]["nur_ton"] is True
    it = g["_au_pick"](t0 + 801)
    n0 = len(out_orig)
    g["_au_out"](it)
    assert played == [("/g/klick.wav", 8)] and len(out_orig) == n0, ("nur Ton", played)
    assert step(net, t0 + 900) == []
    for tt in range(int(t0) + 800, int(t0) + 800 + 310, 5):
        g["_hp_eval"](tt)
    off = [e for e in hp["q"] if e["kind"] == "off"]
    assert len(off) == 1 and off[0]["parts"] == {"STROM": "Netzstrom"}, hp["q"]
    # Stumm gilt
    cfg["mute_until"] = int(time.time()) + 3600
    au2 = dict(au, ob=dict(au["ob"], since=t0 + 5000))
    AU["q"] = []
    r = step(au2, time.time())
    assert r == [("ausfall", False)] and AU["q"] == [] and "stumm" in U["last"][0]["why"], (r, U["last"])
    cfg["mute_until"] = 0
    # Probegong: art pegel 202 sofort, 10 s Sperre, Test-Eintrag (nie Mesh), Knopf
    AU["q"], AU["test_t"] = [], 0
    with g["app"].test_client() as cl:
        t1 = time.time()
        r1 = cl.post("/api/audio/test", json={"art": "pegel"})
        dt = time.time() - t1
        r2 = cl.post("/api/audio/test", json={"art": "pegel"})
        j = cl.get("/api/usv")
    assert r1.status_code == 202 and r1.get_json()["mesh"] is False and dt < 0.5 and r2.status_code == 429, (r1.status_code, r2.status_code, dt)
    assert AU["q"][-1]["text"] == CONSTS["USVA_TXT_PEGEL"] and AU["q"][-1]["test"] is True and AU["q"][-1]["lvl"] == "WARNUNG", AU["q"]
    assert "art:'pegel'" in g["_AUI_JS"] and "art:'warnung'" not in g["_AUI_JS"] and g["AUI_TEST_ART"] == "pegel"
    jj = j.get_json()
    assert j.headers.get("Cache-Control") == "no-store" and isinstance(jj.get("alarm"), dict) and jj["alarm"]["txt"].startswith("Ansage ") and " · Mesh: " in jj["alarm"]["txt"], jj
    assert hp0 is not g["_hp_probe"] and "STROM" in g["HP_KEYS"] and g["HP_KEYS"][:5] == ("LAGE", "ASA", "SDR", "NETZ", "UPLINK")
    # ohne audioKern: Fehlermeldung, kein Absturz
    g2, *_ = env(neud, "x", cfg, flask)
    g2["_AU"]["aktiv"] = False
    o = io.StringIO()
    with contextlib.redirect_stdout(o):
        exec(compile(B, "blk", "exec"), g2)
    assert "usvAlarm Selbsttest FEHLER" in o.getvalue() and "Dashboard laeuft weiter" in o.getvalue()
    return ("Verhalten (echte audioKern-/hbProblem-Funktionen): Selbsttest still, Netzausfall nachts trotz WARNUNG aus und Budget voll genau eine Ansage (Gong + Sprache ueber audioKern), "
            "STROM ins Mesh erst nach 120 s mit Text, 5 min eine zweite Ansage, Rueckkehr nur Klick, Entwarnung nach 5 min, Stumm gilt, pegel 202 sofort + 10 s Sperre + Knopf, /api/usv mit alarm + no-store, Faden nur im Hauptprogramm")


def tile(neud):
    lp = rd(os.path.join(neud, "lage_pages.py"))
    i = lp.index("def page_lokale_energie(")
    j = lp.find("\ndef ", i + 10)
    fn = lp[i:j if j > 0 else len(lp)]
    for x in JS_NEED:
        if fn.count(x) != 1:
            fail("Kachel: Pflichtstelle fehlt %s" % x.strip()[:60])
    if fn.count("innerHTML") or fn.count("Nur Anzeige: kein Ton"):
        fail("Kachel: innerHTML oder alter Info-Text")
    if "Selbsttest: nie Ton, nie Mesh. Kein Herunterfahren.</div>" not in fn:
        fail("Kachel: Info-Text fehlt")
    k = fn.index("<script>/* usvKachel */") + 8
    return fn[k:fn.index("</script>", k)]


def node_test(js):
    nd = shutil.which("node") or shutil.which("nodejs")
    if os.environ.get("GUARD_NO_NODE") or not nd:
        return "Kachel statisch (node fehlt)"
    cases = [{"ok": True, "mode": "NETZ", "alarm": {"txt": "Ansage: bereit · Mesh: bereit (STROM)"}}, {"ok": False, "mode": "KEINE_DATEN"},
             {"ok": True, "mode": "AKKU", "ob": {"since": 1793500000, "kind": "ausfall"}, "runtime_smoothed_s": 900, "alarm": {"txt": "<b>x</b>" + "y" * 300}}]
    d = tempfile.mkdtemp(prefix="g56n")
    try:
        for n, t in (("t.js", NODE_JS), ("k.js", js), ("c.json", json.dumps(cases))):
            open(os.path.join(d, n), "w", encoding="utf-8").write(t)
        o = subprocess.run([nd, os.path.join(d, "t.js"), os.path.join(d, "k.js"), os.path.join(d, "c.json")], capture_output=True, text=True, timeout=60)
        if o.returncode:
            fail("Kachel-Skript (node): %s" % (o.stderr.strip().splitlines() or ["?"])[-1][:200])
        r = json.loads(o.stdout)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    assert r[0]["alarm"] == "Ansage: bereit · Mesh: bereit (STROM)" and r[1]["alarm"] == "" and r[2]["alarm"] == ("<b>x</b>" + "y" * 300)[:200], r
    return "Kachel mit node: Zeile Ansage/Mesh als Text (max 200 Zeichen), leer ohne Daten"


def check(altd, neud, W):
    try:
        rv = revert_all(neud, W)
    except AssertionError as e:
        fail("Rueckbau: %s" % e)
    for fn, t in rv.items():
        if t != rd(os.path.join(altd, fn)):
            fail("Rueckbau %s != Basis (Aenderung ausserhalb Block/Kachel-Stellen)" % fn)
    B = blk(W)
    s1 = static_dsh(B)
    js = tile(neud)
    try:
        b1 = beh(B, neud)
        b2 = node_test(js)
    except AssertionError as ex:
        fail("Verhalten: %s" % str(ex)[:600])
    except SystemExit:
        raise
    except Exception as ex:
        fail("Verhalten (%s): %s" % (type(ex).__name__, str(ex)[:400]))
    print("Guard commit56 ok: Rueckbau byte-genau = Basis (dashboard.py ein Block nach usvLesen, lage_pages.py vier Stellen); %s; %s; %s" % (s1, b1, b2))


MUTS = [
    ("dsh", 'USVA_LOW_S = 300 ', 'USVA_LOW_S = 60 '),
    ("dsh", 'ok, why = _au_offer("WARNUNG", "USV", "%s-%d" % (art, int(now)), text, now, force=True)', 'ok, why = _au_offer("WARNUNG", "USV", "%s-%d" % (art, int(now)), text, now)'),
    ("dsh", 'ok, why = _au_offer("WARNUNG", "USV", "%s-%d" % (art, int(now)), text, now, force=True)', 'ok, why = _au_offer("KATASTROPHE", "USV", "%s-%d" % (art, int(now)), text, now, force=True)'),
    ("dsh", "it.update(test=False, nur_ton=bool(nur_ton), exp=now + USVA_EXP_S)", "it.update(nur_ton=bool(nur_ton), exp=now + USVA_EXP_S)"),
    ("dsh", "    elif _au_muted(_au_cfg(), now):\n        r = (False, \"stumm (Audio-Kachel)\")\n", ""),
    ("dsh", 'if ob and ob.get("kind") == "ausfall" and md == "AKKU":', 'if ob and md in ("AKKU", "AKKU_PRUEF"):'),
    ("dsh", "        if _USVA[\"ann\"] != sid:\n", "        if True:\n"),
    ("dsh", 'if isinstance(rs, (int, float)) and rs <= USVA_LOW_S and _USVA["low"] != sid:', 'if isinstance(rs, (int, float)) and rs <= USVA_LOW_S:'),
    ("dsh", 'out.append(("rueckkehr", offer("rueckkehr", USVA_TXT_RUECK, now, True)[0]))', 'out.append(("rueckkehr", offer("rueckkehr", USVA_TXT_RUECK, now)[0]))'),
    ("dsh", '    elif _USVA["active"] is not None and md == "NETZ" and not ob:\n        _USVA["active"] = None\n', '    elif md == "NETZ" and not ob and _USVA["active"] is not False:\n        _USVA["active"] = None\n'),
    ("dsh", 'if d.get("mode") == "AKKU" and ob and ob.get("kind") == "ausfall":', 'if d.get("mode") in ("AKKU", "AKKU_PRUEF") and ob:'),
    ("dsh", '            g["HP_KEYS"] = tuple(g["HP_KEYS"]) + ("STROM",)\n', '            pass\n'),
    ("dsh", '    if not it.get("nur_ton"):\n        return _USVA["orig_out"](it)\n', '    if False:\n        return _USVA["orig_out"](it)\n'),
    ("dsh", 'tone = (_AU["tones"].get("klick") or {}).get("path")', 'tone = (_AU["tones"].get("gong") or {}).get("path")'),
    ("dsh", 'AU_TEST_TXT["pegel"] = ("WARNUNG", USVA_TXT_PEGEL)', 'AU_TEST_TXT["pegel"] = ("INFO", USVA_TXT_PEGEL)'),
    ("dsh", '.replace("art:\'warnung\'", "art:\'pegel\'")', ''),
    ("dsh", 'if __name__ == "__main__" and not _USVA["started"]:', 'if not _USVA["started"]:'),
    ("dsh", '            d["alarm"] = _usva_info()\n', '            pass\n'),
    ("dsh", '    resp.headers["Cache-Control"] = "no-store"\n    return resp\n\n\ndef _usva_worker', '    return resp\n\n\ndef _usva_worker'),
    ("dsh", "ununterbrochener Notstromversorgung.", "unterbrechungsfreier Notstromversorgung."),
    ("dsh", '    if not _AU.get("started"):\n        r = (False, "Audio-Faden laeuft nicht")\n    elif', '    if'),
    ("dsh", "import time as _usva_time\n", "import time as _usva_time\nimport subprocess\n"),
    ("dsh", '    _USVA["st"] = _selftest_usvalarm()\n', '    _USVA["st"] = "usvAlarm ok ()"\n    _au_vol(100)\n'),
    ("lp", "tx('usvAlarm',a.txt?String(a.txt).slice(0,200):'')", "var e=$('usvAlarm');if(e)e.innerHTML=a.txt||''"),
    ("lp", "    var sh=soh(d);test(d);alarm(d);\n", "    var sh=soh(d);test(d);\n"),
    ("lp", "Selbsttest: nie Ton, nie Mesh. Kein Herunterfahren.", "Selbsttest: nie Ton."),
]


def mutate(altd, neud, W):
    me = os.path.abspath(__file__)
    d = tempfile.mkdtemp()
    caught = missed = 0
    E = edits(W)
    etxt0 = rd(os.path.join(W, "edits.py"))
    try:
        def run(files, wfiles):
            nd, wd = os.path.join(d, "n"), os.path.join(d, "w")
            for x in (nd, wd):
                shutil.rmtree(x, ignore_errors=True)
                os.makedirs(x)
            for fn, t in files.items():
                open(os.path.join(nd, fn), "w", encoding="utf-8").write(t)
            for fn, t in wfiles.items():
                open(os.path.join(wd, fn), "w", encoding="utf-8").write(t)
            o = subprocess.run([sys.executable, me, "check", altd, nd, wd], capture_output=True, text=True, timeout=900)
            return o.returncode != 0, [x[:160] for x in ((o.stdout + o.stderr).strip().splitlines() or [""])[-1:]]
        files = {fn: rd(os.path.join(neud, fn)) for fn in ("dashboard.py", "lage_pages.py")}
        wf = {"blk_dsh.py": blk(W), "edits.py": etxt0}
        bad, msg = run(files, wf)
        if bad:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        cases = []
        for k, a, b in MUTS:
            fm, wm = dict(files), dict(wf)
            if k == "dsh":
                B = wf["blk_dsh.py"]
                if B.count(a) < 1:
                    print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70])); missed += 1; continue
                bm = B.replace(a, b, 1)
                wm["blk_dsh.py"] = bm
                fm["dashboard.py"] = files["dashboard.py"].replace("\n\n" + B.rstrip("\n") + ANCH, "\n\n" + bm.rstrip("\n") + ANCH, 1)
            else:
                hit = [i for i, (o, n) in enumerate(E["LP_EDITS"]) if a in n]
                if not hit:
                    print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70])); missed += 1; continue
                o, n = E["LP_EDITS"][hit[0]]
                nm = n.replace(a, b, 1)
                fm["lage_pages.py"] = files["lage_pages.py"].replace(n, nm, 1)
                wm["edits.py"] = etxt0.replace(repr(n)[1:-1], repr(nm)[1:-1], 1)
                assert wm["edits.py"] != etxt0, a
            cases.append(("%s %s" % (k, a[:50]), fm, wm))
        f = dict(files); f["dashboard.py"] = files["dashboard.py"].replace("T4_SAY_MAX = 600", "T4_SAY_MAX = 601", 1); assert f["dashboard.py"] != files["dashboard.py"]
        cases.append(("Zeile ausserhalb dashboard", f, wf))
        f = dict(files); f["lage_pages.py"] = files["lage_pages.py"].replace("<title>Lokale Energie</title>", "<title>Lokale Energie!</title>", 1); assert f["lage_pages.py"] != files["lage_pages.py"]
        cases.append(("Zeile ausserhalb Kachel", f, wf))
        f = dict(files); f["dashboard.py"] = files["dashboard.py"].replace('AU_TEST_GAP_S = 10\n', 'AU_TEST_GAP_S = 0\n', 1); assert f["dashboard.py"] != files["dashboard.py"]
        cases.append(("audioKern Testsperre 0 (ausserhalb)", f, wf))
        f = dict(files); f["dashboard.py"] = files["dashboard.py"].replace(ANCH, "\n\n" + wf["blk_dsh.py"].rstrip("\n") + ANCH, 1)
        cases.append(("Block doppelt", f, wf))
        for name, fm, wm in cases:
            bad, msg = run(fm, wm)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest commit56: %d erkannt, %d uebersehen%s" % ("OK" if missed == 0 else "FEHLER", caught, missed,
          " (ohne node)" if os.environ.get("GUARD_NO_NODE") or not (shutil.which("node") or shutil.which("nodejs")) else " (mit node)"))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    md = sys.argv[1]
    if md == "revert":
        os.makedirs(sys.argv[3], exist_ok=True)
        for fn, t in revert_all(sys.argv[2], sys.argv[4]).items():
            open(os.path.join(sys.argv[3], fn), "w", encoding="utf-8").write(t)
    elif md == "check":
        check(*sys.argv[2:5])
    elif md == "mutate":
        mutate(*sys.argv[2:5])
MK_C56_GRD_EOF
EMB="patch.py:$EXPECT_PAT edits.py:$EXPECT_EDI G/blk_dsh.py:$EXPECT_BDS guard.py:$EXPECT_GRD"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
cp "$W/edits.py" "$W/G/edits.py"
echo "OK eingebettete Dateien geprueft (4: Patcher, Kachel-Stellen, Block usvAlarm, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "$2"; return; }; shift 2; done; echo UNBEKANNT; }
# ---------- 1) Basis: dashboard.py + lage_pages.py gemeinsam alt oder neu; ups_manager.py wie nach commit55 ----------
for x in "$F" "$FL" "$FS" "$FE"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS"); E16=$(s16 "$FE")
U16=fehlt; [[ -e "$FU" ]] && U16=$(s16 "$FU")
SD=$(lbl "$D16" "$KNOWN_D16" alt "$KNOWN_D16N" neu); SL=$(lbl "$L16" "$KNOWN_L16" alt "$KNOWN_L16N" neu)
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit55, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 ($(wc -l < "$FL") Zeilen) - $SL (alt $KNOWN_L16, neu $KNOWN_L16N)"
echo "Basis ups_manager.py $U16 - $([[ "$U16" == "$KNOWN_U16" ]] && echo "wie nach commit55 (bleibt unveraendert)" || echo "ABWEICHUNG (erwartet $KNOWN_U16)")"
echo "Basis prepper_sdr.py sha16 $S16, prepper_evlog.py sha16 $E16 - $([[ "$S16" == "$KNOWN_S16" && "$E16" == "$KNOWN_E16" ]] && echo "wie erwartet (bleiben unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C54" || "$L16" == "$KNOWN_L16_C54" || "$U16" == fehlt ]]; then
  echo "STOP: erst commit55 anwenden - der Projektordner ist noch der Stand nach commit54 (dashboard.py $D16, lage_pages.py $L16, ups_manager.py $U16); commit56 braucht dashboard.py $KNOWN_D16, lage_pages.py $KNOWN_L16 und ups_manager.py $KNOWN_U16 (nach commit55) - nichts geaendert."
  exit 1
fi
if [[ "$D16" == "$KNOWN_D16_C53" ]]; then
  echo "STOP: erst commit54 und commit55 anwenden - dashboard.py ist noch der Stand nach commit53 ($D16) - nichts geaendert."
  exit 1
fi
for v in "dashboard.py:$SD:$D16" "lage_pages.py:$SL:$L16"; do
  IFS=: read -r fn st hh <<< "$v"
  if [[ "$st" == UNBEKANNT ]]; then
    echo "STOP: $fn weicht vom erwarteten Stand ab (sha16 $hh) - nichts geaendert."
    echo "      commit56 passt nur auf den Stand nach commit55. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
    exit 1
  fi
done
if [[ "$SD$SL" != altalt && "$SD$SL" != neuneu ]]; then
  echo "STOP: Mischstand (dashboard.py $SD, lage_pages.py $SL) - erwartet beide alt oder beide neu - nichts geaendert."
  for x in "$F" "$FL"; do LBX=$({ ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LBX" ]] && echo "      Sicherung vorhanden: $LBX ($(s16 "$LBX"))"; done
  echo "      Ein abgebrochener Lauf? Bitte diese Ausgabe an Grok schicken (nichts von Hand kopieren)."
  exit 1
fi
[[ "$U16" == "$KNOWN_U16" ]] || stop "ups_manager.py ($U16) ist nicht der Stand nach commit55 ($KNOWN_U16)"
[[ "$S16" == "$KNOWN_S16" && "$E16" == "$KNOWN_E16" ]] || stop "prepper_sdr.py ($S16) oder prepper_evlog.py ($E16) ist nicht der erwartete Stand ($KNOWN_S16 / $KNOWN_E16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach qrmRun usvLesen; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" && -w "$FL" ]] || stop "Projektordner, dashboard.py oder lage_pages.py ist nicht beschreibbar"
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
# ---- Neustart-Sperre HH:55-HH:04 (Berlin); Vorlauf 15 min mit apt, sonst 5 min ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C56_FAKE_HM:-}" && "$SIM" == 1 ]]; then hm="$C56_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
NEED=0; [[ "$STATE" == alt ]] && NEED=1
LA=300
rscheck() { local s0 s1 la="$2" k x; s0=$(rssec 0); s1=$(rssec "$la"); k=0
  for ((x = 0; x <= la; x += 60)); do rswin "$(rssec "$x")" && k=1; done
  if [[ "$k" == 1 ]] || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04, Vorlauf $((la / 60)) min) - frei ab HH:05"
    elif [[ "$NEED" == 0 ]]; then echo "OK Neustart-Sperre: commit56 ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - Sperre HH:55-HH:04, dieser Lauf braucht bis zu $((la / 60)) min (Start also bis HH:$(printf '%02d' $(( 55 - la / 60 ))) Uhr) - bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04, auch in $((la / 60)) min ($1)"; fi; }
rscheck "Vorpruefung" "$LA"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" || "$f" == "$FL" || "$f" == "$FU" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher; auch prepper_sdr.py)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
PT() { python3 "$W/patch.py" "$1" "$2" "$3" "$4" "$5" "$W/edits.py"; }
PT usvAlarm dsh "$F" "$W/work/dashboard.py" "$W/G/blk_dsh.py" > "$W/q1.log" || { cat "$W/q1.log"; stop "dashboard.py: Stelle fuer usvAlarm nicht eindeutig"; }
PT usvAlarm lp "$FL" "$W/work/lage_pages.py" - > "$W/q2.log" || { cat "$W/q2.log"; stop "lage_pages.py: Stellen fuer die USV-Kachel nicht eindeutig"; }
for v in "dashboard.py:$KNOWN_D16N" "lage_pages.py:$KNOWN_L16N"; do
  IFS=: read -r fn hh <<< "$v"
  [[ "$(s16 "$W/work/$fn")" == "$hh" ]] || stop "Ergebnis $fn $(s16 "$W/work/$fn") statt $hh (Zielstand nicht erreicht)"
done
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(cat "$W/q1.log")), lage_pages.py $KNOWN_L16N ($(cat "$W/q2.log"))"
PT x dsh "$W/work/dashboard.py" "$W/work/x1" "$W/G/blk_dsh.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
PT x lp "$W/work/lage_pages.py" "$W/work/x2" - > /dev/null && cmp -s "$W/work/lage_pages.py" "$W/work/x2" || stop "lage_pages.py nicht idempotent"
rm -f "$W/work/x1" "$W/work/x2"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/patch.py" "$W/edits.py" "$W/G/blk_dsh.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/G" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: commit56 im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" && "$(s16 "$W/alt/lage_pages.py")" == "$KNOWN_L16" ]] || stop "Guard: Stand ohne commit56 ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt" "$W/neu" "$W/G" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "Guard commit56 meldet Verstoss"; }
grep "^Guard commit56" "$W/g.log" | cut -c1-2400
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Kachel-Skript hier statisch geprueft; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C56_SIM_NOMUT:-}" && "$SIM" == 1 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt" "$W/neu" "$W/G" > "$W/gm.log" 2>&1 || { cat "$W/gm.log"; stop "Mutationstest commit56: eine Verfehlung wurde nicht erkannt"; }
[[ "$MUTS" == 0 ]] || grep -E "^OK Mutationstest" "$W/gm.log"
# ---------- 3) Zustand vorher (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local i; for i in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte /lokale-energie)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
UAPI0=$(code "$B/api/usv")
t4st() { "${CURL[@]}" "$B/api/t4/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - - -"); sys.exit(0)
t = d.get("tick") or {}
print(int(bool(d.get("ok"))), int(t.get("n") or 0), int(bool(t.get("thread"))), str(((d.get("hb") or {}).get("last") or {}).get("text") or "-").replace(" ", "_")[:60])' 2>/dev/null || echo "FEHLER - - -"; }
read -r T4OK0 T4N0 T4TH0 HBL0 <<< "$(t4st)"
if [[ "$DRY" != 1 ]]; then [[ "$T4OK0" == 1 ]] || stop "teil4 nicht aktiv (/api/t4/status ok=$T4OK0) - Dashboard nicht im erwarteten Zustand"; fi
pcode() { code -X POST "$@"; }
TLAT0=$(tmed "$B/api/t4/status")
echo "Zustand vorher: teil4 aktiv $T4OK0 (Takt $T4N0), /api/t4/status Median ${TLAT0} s, /api/usv HTTP $UAPI0"
aust() { "${CURL[@]}" "$B/api/audio/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - -"); sys.exit(0)
t = d.get("tools") or {}
c = d.get("cfg") or {}
print(int(bool(d.get("aktiv") and d.get("faden"))), ",".join(sorted(k for k, v in t.items() if not v)) or "-", c.get("vol", "?"))' 2>/dev/null || echo "FEHLER - -"; }
read -r AUOK0 AUMISS0 AUVOL0 <<< "$(aust)"
echo "audioKern vorher: Ausgabe $([[ "$AUOK0" == 1 ]] && echo aktiv || echo "NICHT aktiv ($AUOK0)"), fehlende Programme ${AUMISS0}, Regler ${AUVOL0} %"
[[ "$DRY" == 1 || "$AUOK0" == 1 ]] || stop "audioKern-Ausgabe laeuft nicht (/api/audio/status) - ohne sie keine Ansage"
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet, nichts abgespielt."
  if [[ "$NEED" == 0 ]]; then echo "  commit56 ist schon installiert - ein echter Lauf aendert an den Dateien nichts."
  else echo "  Ein echter Lauf wuerde dashboard.py und lage_pages.py ersetzen (Sicherungen DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, 27 Seiten/APIs + /api/usv + /pi pruefen. Eine sudo-Passwortabfrage. Beim Einspielen wird nichts gesendet und nichts abgespielt."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
if [[ "$NEED" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung, keine NUT-Aenderung (upsmon bleibt aus)"
PHASE="Dashboard"
# ---------- 4) Dashboard ----------
trap '' INT
RESTARTED=0
TNA=$(date +%s)
T0D=$(date +%s)
INST=()
waitd() { local i; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done; return 1; }
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -n 400 -o cat | grep -E "usvAlarm|Traceback" | tail -5 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  if [[ "$RESTARTED" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    waitd
  fi
  echo "  NUT, ups_manager.py, Datenbank, prepper_sdr.py und Mesh-Regeln unveraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED" == 0 ]]; then
  echo "OK commit56 schon installiert - kein Neustart, keine Aenderung an den Dateien"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen" 300
  for x in "$F" "$FL"; do
    cp -a "$x" "$x.bak-$NM-$TS"
    { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  echo "OK Sicherungen *.bak-$NM-$TS: dashboard.py, lage_pages.py (behalten: letzte $KEEP_LAST)"
  for v in "$FL:lage_pages.py:$KNOWN_L16N" "$F:dashboard.py:$KNOWN_D16N"; do
    IFS=: read -r x fn hh <<< "$v"
    INST+=("$x")
    cp "$W/work/$fn" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rb "$fn installieren"; exit 1; }
    [[ "$(s16 "$x")" == "$hh" ]] || { rb "$fn nach dem Kopieren falsch ($(s16 "$x"))"; exit 1; }
  done
  echo "OK lage_pages.py und dashboard.py atomar ersetzt"
  RESTARTED=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard - warte auf HTTP 200 (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  waitd || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
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
echo "OK teil4 aktiv, Takt laeuft ($T4N1 -> $T4N2 in 6 s)"
TLAT1=$(tmed "$B/api/t4/status")
echo "OK /api/t4/status Median ${TLAT1} s (vorher ${TLAT0} s)"
awk -v a="$TLAT0" -v b="$TLAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/api/t4/status ist deutlich langsamer geworden (${TLAT0} s -> ${TLAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200)"
n=$(grep -c "^# ===== usvAlarm:" "$F" || true); [[ "$n" == 1 ]] || rbx "dashboard.py Marker usvAlarm ${n}x"
n=$(grep -c 'id="usvAlarm"' "$FL" || true); [[ "$n" == 1 ]] || rbx "lage_pages.py Zeile usvAlarm ${n}x"
echo "OK Marker usvAlarm (dashboard.py) und Kachel-Zeile usvAlarm (lage_pages.py) je 1x; ups_manager.py $(s16 "$FU") unveraendert"
for i in $(seq 1 20); do
  UH=$("${CURL[@]}" "$B/lokale-energie" -o "$W/le.html" -w "%{http_code}" || true)
  UQ=$(grep -c 'id="usvAlarm"' "$W/le.html" || true)
  [[ "$UH" == 200 && "$UQ" == 1 ]] && break
  sleep 3
done
[[ "$UH" == 200 && "$UQ" == 1 ]] || rbx "/lokale-energie HTTP $UH, Zeile usvAlarm ${UQ}x"
PH=$("${CURL[@]}" "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
[[ "$PH" == 200 ]] && grep -qF "art:'pegel'" "$W/pi.html" && grep -qF "Audio-Pegel testen" "$W/pi.html" && ! grep -qF "art:'warnung'" "$W/pi.html" || rbx "/pi: Knopf 'Audio-Pegel testen' sendet nicht art pegel (HTTP $PH)"
echo "OK /lokale-energie mit Zeile Ansage/Mesh, /pi Knopf 'Audio-Pegel testen' -> art pegel"
uapi() { "${CURL[@]}" -D "$W/uh.txt" "$B/api/usv" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - -"); sys.exit(0)
a = d.get("alarm") or {}
print(d.get("mode") or "-", int("serial" in json.dumps(d).lower()), str(a.get("txt") or "-").replace(" ", "_")[:200])' 2>/dev/null || echo "FEHLER - -"; }
for i in $(seq 1 10); do read -r UM USRL UAL <<< "$(uapi)"; [[ "$UAL" != - && "$UM" != FEHLER ]] && break; sleep 2; done
[[ "$UM" != FEHLER ]] || rbx "/api/usv nicht lesbar (HTTP $(code "$B/api/usv"))"
[[ "$UAL" != - ]] || rbx "/api/usv ohne Feld alarm"
[[ "$USRL" == 0 ]] || rbx "/api/usv enthaelt 'serial'"
grep -qi "^cache-control:.*no-store" "$W/uh.txt" || rbx "/api/usv ohne Cache-Control no-store"
echo "OK /api/usv (Modus $UM): $(echo "$UAL" | tr '_' ' ')"
c4=$(pcode -H "Content-Type: application/json" --data '{"art":"keine"}' "$B/api/audio/test")
[[ "$c4" == 400 ]] || rbx "POST /api/audio/test mit unbekannter Art -> HTTP $c4 (erwartet 400)"
c5=$(pcode -H "Origin: http://evil.example" -H "Content-Type: application/json" --data '{"art":"pegel"}' "$B/api/audio/test")
[[ "$c5" == 403 ]] || rbx "POST /api/audio/test mit fremdem Origin -> HTTP $c5 (erwartet 403)"
echo "OK /api/audio/test: unbekannte Art 400, fremder Origin 403 (kein Ton beim Einspielen; Probegong nur per Knopf)"
read -r AUOK1 AUMISS1 AUVOL1 <<< "$(aust)"
[[ "$AUOK1" == 1 ]] || rbx "audioKern-Ausgabe nach dem Neustart nicht aktiv"
[[ "$AUVOL1" == "$AUVOL0" ]] || rbx "Regler-Lautstaerke veraendert ($AUVOL0 -> $AUVOL1)"
echo "OK audioKern aktiv, Regler ${AUVOL1} % unveraendert$([[ "$AUMISS1" != - ]] && echo ", HINWEIS fehlende Programme: $AUMISS1")"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -n 3000 -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep usvAlarm"
else
  if [[ "$RESTARTED" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "usvAlarm aktiv: usvAlarm ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-260)" || rbx "Journal prepper-dashboard ohne 'usvAlarm aktiv: usvAlarm ok' ($(echo "$JD" | grep -F usvAlarm | tail -1 | cut -c1-200))"
    echo "$JA" | grep -qF "Mesh STROM an" || rbx "usvAlarm ohne Mesh-Punkt STROM (hbProblem nicht aktiv?)"
    echo "$JA" | grep -qF "Faden laeuft" || rbx "usvAlarm-Faden laeuft nicht"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok' 'audioKern aktiv: audioKern ok' 'audioUi aktiv: audioUi ok' 'kartePop aktiv: kartePop ok' 'hbProblem aktiv: hbProblem ok' 'umweltFlach aktiv: umweltFlach ok' 'qrmRun aktiv: qrmRun ok' 'usvLesen aktiv: usvLesen ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'usvAlarm Selbsttest FEHLER|usvAlarm: Faden-Fehler|usvAlarm /api/usv:|usvLesen: Faden-Fehler|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|usvLesen Selbsttest FEHLER|qrmRun Selbsttest FEHLER|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|No module named .ups_manager|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'usvAlarm Selbsttest FEHLER|usvAlarm: Faden-Fehler|usvAlarm /api/usv:|usvLesen: Faden-Fehler|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|usvLesen Selbsttest FEHLER|qrmRun Selbsttest FEHLER|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|No module named .ups_manager|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E4=$(echo "$JD" | grep -c -E 'audioKern: WARNUNG USV|audioKern: USV ' || true)
  [[ "${E4:-0}" == 0 ]] && echo "OK beim Einspielen keine USV-Ansage (Netzbetrieb)" || echo "HINWEIS $E4 USV-Ansage(n) seit Neustart - laeuft die USV gerade auf Akku? $(echo "$JD" | grep -E 'audioKern: (WARNUNG )?USV' | tail -1 | cut -c1-160)"
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein commit56-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED" == 1 ]]; then [[ "$a" == active ]] || rbx "$u laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- neu gestartet: $([[ "$RESTARTED" == 1 ]] && echo "nur prepper-dashboard" || echo "keiner"); prepper-sdr und Mesh-Bruecken unveraendert"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"), darunter prepper_sdr.py)" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach qrmRun usvLesen usvAlarm; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, NUT (upsmon aus), ups_manager.py, Mesh-Regeln, Gain-Waechter (Stufe 16), prepper_sdr.py, Firewall und rpcbind unberuehrt; beim Einspielen nichts gesendet, nichts abgespielt, Lautstaerke nicht veraendert"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F") ($(wc -l < "$F") Zeilen), lage_pages.py sha16 $(s16 "$FL") ($(wc -l < "$FL") Zeilen), ups_manager.py sha16 $(s16 "$FU") (unveraendert)"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1); LBL=$({ ls -1t "$FL.bak-$NM-"* 2>/dev/null || true; } | head -1)
if [[ -n "$LB" && -n "$LBL" ]]; then
  echo "Rueckweg (beide zusammen):"
  echo "  cp -a $LB $F && cp -a $LBL $FL && sudo systemctl restart prepper-dashboard"
else echo "Rueckweg: keine $NM-Sicherung vorhanden (Dateien nicht geaendert)"; fi
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s http://127.0.0.1:5000/api/usv | grep -o alarm.*"
echo "  curl -s http://127.0.0.1:5000/api/audio/status | cut -c1-300"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep usvAlarm"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Probegong: auf /pi in der Audio-Kachel 'Audio-Pegel testen' druecken (Gong + Pegeltest-Ansage mit Regler-Pegel, nie Mesh, hoechstens alle 10 s)."
echo "Beim Einspielen nichts gesendet (kein Mesh, kein Telegram, keine Alarme), nichts abgespielt, nichts nach aussen geoeffnet, keine Datenbank geaendert. Neue Docs-Version: bewusst nicht."
echo "Dauer: $(( $(date +%s) - TNA )) s"
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
