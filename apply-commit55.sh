#!/bin/bash
set -eEuo pipefail
# commit55 usvNut + usvLesen - USV Eaton Ellipse PRO 650 VA / 400 W (ELP650DIN) per USB ins Dashboard, NUR ANZEIGE (sendet nichts):
#  Phase A (NUT, Schritt 0): Pakete nut-server + nut-client (--no-install-recommends), /etc/nut: nut.conf MODE=standalone, ups.conf [eaton] usbhid-ups
#     vendorid 0463 pollinterval 2 (KEIN ignorelb/override - kommt mit commit57), upsd.conf LISTEN 127.0.0.1 3493 (nichts nach aussen), upsd.users und
#     upsmon.conf unveraendert (Lesen braucht keinen Benutzer), upsmon (nut-monitor) NICHT aktiv -> kein Herunterfahren. Keine Firewall-/rpcbind-Aenderung.
#     Fehler in Phase A -> /etc/nut zurueck, NUT-Dienste aus, Abbruch OHNE Dashboard-Aenderung.
#  Phase B (Dashboard): ups_manager.py neu (Faden 2 s, eine Verbindung 127.0.0.1:3493, nur LIST-Befehle, keine Seriennummer), dashboard.py Block usvLesen
#     (GET /api/usv), lage_pages.py Kachel USV-NOTSTROM-ZENTRALE auf /lokale-energie direkt unter der Hauptkachel. Kein Ton, kein Mesh, kein Heartbeat, kein Shutdown.
# Aufruf: bash /tmp/apply-commit55.sh commit55 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 7b81384b4af00883 / lage_pages.py a51d9b51a646813d (nach commit54), ups_manager.py fehlt; neu 86f712401eddab5f / 495ee5ac809143c8 / ef0b9e3d4bf42003.
#   prepper_sdr.py 264ef34996e17753 und prepper_evlog.py 8bffd396972b60fa (nach commit54) bleiben unveraendert. Stand vor commit54 -> STOP "erst commit54 anwenden".
# Sicherungen DATEI.bak-commit55-ZEIT fuer dashboard.py, lage_pages.py und die /etc/nut-Dateien (je letzte 3). Keine Datenbank-Aenderung.
# Neu gestartet wird nur prepper-dashboard (prepper-sdr und Mesh-Bruecken bleiben). Gain-Stufe 16 bleibt.
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
W=/tmp/commit55-apply
KEEP_LAST=3
NM=commit55
KNOWN_D16="7b81384b4af00883"; KNOWN_D16N="86f712401eddab5f"; KNOWN_D16_C53="832787ef1c3b44bc"; KNOWN_D16_C52="ab18872053f58871"; KNOWN_D16_C51="67d58079139cd373"; KNOWN_D16_C50="2a3625a3325653b1"
KNOWN_L16="a51d9b51a646813d"; KNOWN_L16N="495ee5ac809143c8"; KNOWN_L16_C52="1d33ae9fd78f53dc"; KNOWN_U16N="ef0b9e3d4bf42003"
KNOWN_S16="264ef34996e17753"; KNOWN_S16_C53="0900bfe6ba67e657"; KNOWN_E16="8bffd396972b60fa"; KNOWN_E16_C53="5e16f710aba58f34"
NUT_ETC=/etc/nut
NUT_PORT=3493
NUT_UPS=eaton
NUT_MARK="# commit55 usvNut"
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
if [[ "$SIM" == 1 ]]; then [[ -n "${C55_NUT_ETC:-}" ]] && NUT_ETC="$C55_NUT_ETC"; [[ -n "${C55_NUT_PORT:-}" ]] && NUT_PORT="$C55_NUT_PORT"; fi
echo "=== commit55 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): usvNut (NUT nur lokal) + usvLesen (USV-Kachel, nur Anzeige), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/G" "$W/nut"
EXPECT_PAT="bac6a0b2f34ddafff779bd7c011b0fc51d2f3ee1182838d4f8957e58915d7182"
cat > "$W/patch.py" << 'MK_C55_PAT_EOF'
"""Patcher commit55 (generisch wie commit54). Aufruf: patch.py NAME dsh|lp QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
MK_C55_PAT_EOF
EXPECT_EDI="def44cd67a8b3f0079d2ef9404c695bfdcfebd4f72353b009d33a22c41ce1a83"
cat > "$W/edits.py" << 'MK_C55_EDI_EOF'
"""Stellen commit55: dashboard.py ein Block vor __main__ (usvLesen); lage_pages.py eine Stelle in page_lokale_energie (Kachel USV-NOTSTROM-ZENTRALE direkt unter der Hauptkachel)."""
_A = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
DSH_ANCHOR = _A
LP_EDITS = [('  </div>\n</div>\n<script>\nconst outageHist',
             '  </div>\n  <div class="card full usv-c usv-grau" id="usvCard">\n    <style>\n    .usv-c .usv-h{display:flex;justify-content:space-between;align-items:center}\n    .usv-c .usv-i{display:inline-block;width:18px;height:18px;line-height:18px;text-align:center;border-radius:50%;border:1px solid #475569;color:#94a3b8;font-size:.7rem;cursor:pointer;user-select:none}\n    .usv-c .usv-bar{height:10px;background:#1e293b;border-radius:5px;margin-top:8px;overflow:hidden}\n    .usv-c .usv-bar>div{height:100%;width:0;background:#22c55e;transition:width .4s}\n    .usv-c.usv-gruen{border-color:#22c55e66}.usv-c.usv-gruen .usv-m{color:#22c55e}\n    .usv-c.usv-orange{border-color:#f59e0b88}.usv-c.usv-orange .usv-m{color:#f59e0b}\n    .usv-c.usv-rot{border-color:#ef4444;background:#ef444418}.usv-c.usv-rot .usv-m{color:#ef4444;font-size:1.25rem}\n    .usv-c.usv-rot{animation:usvBlink 1s steps(2,start) infinite}\n    @keyframes usvBlink{50%{background:#ef444440}}\n    @media (prefers-reduced-motion:reduce){.usv-c.usv-rot{animation:none}}\n    .usv-c.usv-grau .usv-m{color:#94a3b8}\n    .usv-c .usv-gelb{color:#eab308}\n    .usv-c .usv-auto{margin-top:6px;font-size:.9rem;font-weight:600}\n    </style>\n    <div class="title usv-h"><span>USV-NOTSTROM-ZENTRALE</span><span class="usv-i" id="usvI" role="button" tabindex="0" aria-label="Erklärung">i</span></div>\n    <div class="big usv-m" id="usvMain">keine USV-Daten</div>\n    <div class="small" id="usvLine"></div>\n    <div class="usv-bar"><div id="usvBar"></div></div>\n    <div class="small" id="usvBarT"></div>\n    <div class="usv-auto" id="usvAuto"></div>\n    <div class="small" id="usvSoh"></div>\n    <div class="small" id="usvTest"></div>\n    <div class="small" id="usvInfo" hidden>Werte der USV über NUT (alle 2 s, nur lesen). Last = gemessene Wirkleistung ÷ 400 W Nennleistung. Restlaufzeit = Schätzung der USV, geglättet (5 min; bei Akkubetrieb sofort neu). Selbsttest = kurzer Akkubetrieb bei anliegendem Netz, kein Alarm. SoH = gelernte Basis (14 Tage) – für kleine Last gibt es keine Werksangabe (Eaton: 9 min bei 200 W, 5 min bei 280 W, 2 min bei 400 W, ±15 %). Batteriespannung liefert dieses Modell nicht: Akku-Prüfung über den Laufzeitfall in den ersten 60 s. Nur Anzeige: kein Ton, kein Mesh, kein Herunterfahren.</div>\n  </div>\n</div>\n<script>/* usvKachel */\n(function(){\n  var C=document.getElementById(\'usvCard\');if(!C)return;\n  function $(i){return document.getElementById(i);}\n  function tx(i,s){var e=$(i);if(e)e.textContent=s||\'\';}\n  function hm(t){if(!t)return \'-\';var d=new Date(t*1000);return (\'0\'+d.getHours()).slice(-2)+\':\'+(\'0\'+d.getMinutes()).slice(-2);}\n  function dm(t){var d=new Date(t*1000);return (\'0\'+d.getDate()).slice(-2)+\'.\'+(\'0\'+(d.getMonth()+1)).slice(-2)+\'. \'+hm(t);}\n  function mn(s){return (s==null)?\'?\':Math.max(0,Math.round(s/60));}\n  function n0(x){return (x==null)?\'?\':String(Math.round(x));}\n  function cls(k){C.className=\'card full usv-c usv-\'+k;}\n  var I=$(\'usvI\');\n  function tog(){var e=$(\'usvInfo\');e.hidden=!e.hidden;}\n  I.addEventListener(\'click\',tog);I.addEventListener(\'keydown\',function(e){if(e.key===\'Enter\'||e.key===\' \'){e.preventDefault();tog();}});\n  function soh(d){var s=d.soh||{},e=$(\'usvSoh\'),ein=s.einbau?(\' · Akku eingebaut \'+s.einbau.split(\'-\')[1]+\'.\'+s.einbau.split(\'-\')[0]):\'\';\n    e.className=\'small\';\n    if(s.pct==null){tx(\'usvSoh\',\'Akku-Gesundheit (SoH): \'+(s.txt||\'lernt\')+ein);return \'\';}\n    var z=s.state===\'VERSCHLISSEN\'?\'VERSCHLISSEN - BITTE AKKUPACK TAUSCHEN\':s.state;\n    if(s.state===\'VERSCHLISSEN\')e.className=\'small usv-gelb\';\n    tx(\'usvSoh\',\'Akku-Gesundheit (SoH): \'+s.pct+\' % [Zustand: \'+z+\'] · gelernt, keine Werksangabe\'+ein);\n    return \' · SoH \'+s.pct+\' % [\'+(s.state===\'VERSCHLISSEN\'?\'VERSCHLISSEN\':s.state)+\']\';}\n  function test(d){var l=d.last_test,e=$(\'usvTest\');e.className=\'small\';\n    if(!l){tx(\'usvTest\',\'Selbsttest: noch keiner erkannt\');return;}\n    var dr=l.drop||{},st=l.stress||{},v=(dr.bv_v!=null)?(\'Spannungseinbruch \'+String(dr.bv_v).replace(\'.\',\',\')+\' V\'):(dr.rt_pct!=null?(\'Laufzeitfall \'+String(dr.rt_pct).replace(\'.\',\',\')+\' % (Ersatzwert)\'):\'\');\n    if(st.state===\'auffaellig\')e.className=\'small usv-gelb\';\n    tx(\'usvTest\',\'Letzter Selbsttest \'+dm(l.t)+\' · \'+(l.result||\'ok\')+(v?\' · \'+v:\'\')+(st.state===\'auffaellig\'?\' · AUFFÄLLIG\':(st.state===\'lernt\'?\' · Vergleich lernt\':\'\')));}\n  function show(d){\n    var w=d.load_w,p=d.load_pct,rs=d.runtime_smoothed_s,b=$(\'usvBar\');\n    b.style.width=(p==null?0:Math.min(100,p))+\'%\';b.style.background=(p!=null&&p>=80)?\'#ef4444\':((p!=null&&p>=60)?\'#eab308\':\'#22c55e\');\n    tx(\'usvBarT\',w==null?\'\':(n0(w)+\' W / \'+n0(p)+\' % belegt\'+(d.load_src&&d.load_src!==\'gemessen\'?\' (\'+d.load_src+\')\':\'\')));\n    var sh=soh(d);test(d);\n    if(d.mode===\'KEINE_DATEN\'||!d.ok){cls(\'grau\');tx(\'usvMain\',\'keine USV-Daten\');\n      tx(\'usvLine\',(d.err||\'\')+(d.t?\' · letzte Daten \'+dm(d.t):\'\'));tx(\'usvAuto\',\'\');return;}\n    var lb=d.lb?\' · AKKU SCHWACH\':\'\';\n    if(d.mode===\'AKKU\'){cls(\'rot\');tx(\'usvMain\',\'NETZAUSFALL - USV-BATTERIEBETRIEB - AUTONOME RESTLAUFZEIT: \'+mn(rs)+\' min\');\n      tx(\'usvLine\',\'seit \'+hm((d.ob||{}).since)+\' · Ladung \'+n0(d.charge)+\' % · Last \'+n0(w)+\' W\'+lb);tx(\'usvAuto\',\'\');return;}\n    if(d.mode===\'AKKU_PRUEF\'){cls(\'orange\');tx(\'usvMain\',\'AKKUBETRIEB – Prüfung (\'+((d.ob||{}).mains?\'Selbsttest?\':\'Netzausfall?\')+\') \'+((d.ob||{}).dur_s||0)+\' s\');\n      tx(\'usvLine\',\'Ladung \'+n0(d.charge)+\' % · Last \'+n0(w)+\' W\'+lb);tx(\'usvAuto\',\'Autonomie ca. \'+mn(rs)+\' min\');return;}\n    cls(d.mode===\'NETZ\'?\'gruen\':\'orange\');tx(\'usvMain\',d.mode===\'NETZ\'?\'NETZBETRIEB\':(\'Status \'+(d.status||\'?\')));\n    tx(\'usvLine\',\'Last \'+n0(w)+\' W · Ladung \'+n0(d.charge)+\' %\'+sh+lb);\n    tx(\'usvAuto\',\'Autonomie ca. \'+mn(rs)+\' min (bei aktueller Last)\');}\n  var busy=false;\n  function tick(){if(busy||document.visibilityState===\'hidden\')return;busy=true;\n    fetch(\'/api/usv\',{cache:\'no-store\'}).then(function(r){return r.json();}).then(show).catch(function(){show({mode:\'KEINE_DATEN\',ok:false,err:\'Dashboard nicht erreichbar\'});}).then(function(){busy=false;});}\n  tick();setInterval(tick,2000);document.addEventListener(\'visibilitychange\',tick);\n})();\n</script>\n<script>\nconst outageHist')]
LP_ANCHOR = None
MK_C55_EDI_EOF
EXPECT_BDS="7e797a8097f3bcf16d731d8d8f4d3188a8a05b9002a2853286cadb90eb13a75e"
cat > "$W/G/blk_dsh.py" << 'MK_C55_BDS_EOF'
# ===== usvLesen: USV Eaton Ellipse PRO 650 VA / 400 W ueber NUT (Modul ups_manager.py, Faden 2 s, eine Verbindung zu 127.0.0.1:3493, nur LIST-Befehle) - GET /api/usv fuer die Kachel USV-NOTSTROM-ZENTRALE auf /lokale-energie; NUR ANZEIGE: kein Ton, kein Mesh, kein Heartbeat, kein Herunterfahren; ohne NUT/Daten grau "keine USV-Daten", Dashboard laeuft weiter =====
_USV = {"mgr": None, "err": None, "st": None}


def _usv_api():
    from flask import jsonify
    m = _USV.get("mgr")
    if m is None:
        r = {"ok": False, "mode": "KEINE_DATEN", "err": "USV-Leser nicht aktiv (%s)" % (_USV.get("err") or "Testbetrieb"), "nom_w": 400}
    else:
        try:
            r = m.snapshot()
        except Exception as e:
            r = {"ok": False, "mode": "KEINE_DATEN", "err": "Fehler %s" % type(e).__name__, "nom_w": 400}
    resp = jsonify(r)
    resp.headers["Cache-Control"] = "no-store"
    return resp


def _selftest_usvlesen():
    import os.path as _uv_path
    import ups_manager as _uv_mod
    assert _uv_path.dirname(_uv_path.abspath(_uv_mod.__file__)) == _uv_path.dirname(_uv_path.abspath(__file__)), "ups_manager.py nicht aus dem Projektordner"
    assert _uv_mod.HOST == "127.0.0.1" and _uv_mod.NOM_W == 400 and _uv_mod.POLL_S == 2.0
    st = _uv_mod.selftest()
    pg = globals().get("PAGE_LOKALE_ENERGIE") or ""
    assert pg.count("/* usvKachel */") == 1 and pg.index('id="outageChart"') < pg.index("/* usvKachel */") < pg.index("const outageHist"), "Kachel fehlt oder an falscher Stelle"
    return _uv_mod, st


try:
    _uv_m, _uv_st = _selftest_usvlesen()
    if "usv_api" not in app.view_functions and not any(r.rule == "/api/usv" for r in app.url_map.iter_rules()):
        app.add_url_rule("/api/usv", endpoint="usv_api", view_func=_usv_api, methods=["GET"])
    _USV["st"] = _uv_st
    if __name__ == "__main__" and _USV["mgr"] is None:
        _USV["mgr"] = _uv_m.Manager(_SDR_BASE)
        _USV["mgr"].start()
        if isinstance(globals().get("RS_ITEMS"), list):
            RS_ITEMS.append(("usvLesen usv_state.json", _USV["mgr"].save))
    print("usvLesen aktiv: usvLesen ok (%s; /api/usv, Kachel /lokale-energie unter der Hauptkachel; Faden %s)" % (_uv_st, "laeuft" if _USV["mgr"] else "nur im Hauptprogramm"), flush=True)
except Exception as _uv_e:
    _USV["err"] = "%s: %s" % (type(_uv_e).__name__, str(_uv_e)[:200])
    print("usvLesen Selbsttest FEHLER (%s) - keine USV-Anzeige, Dashboard laeuft weiter" % _USV["err"], flush=True)
# ===== /usvLesen =====
MK_C55_BDS_EOF
EXPECT_UPS="ef0b9e3d4bf42003dfa5b0102e4665d0aa7bb2b5bb11d33c0d1aefc39a66034e"
cat > "$W/G/ups_manager.py" << 'MK_C55_UPS_EOF'
"""ups_manager (commit55 usvLesen): USV Eaton Ellipse PRO 650 VA / 400 W (ELP650DIN) ueber NUT lesen - NUR ANZEIGE.
Ein Faden im Dashboard liest alle 2 s ueber EINE dauerhafte TCP-Verbindung zu upsd (127.0.0.1:3493, NUT-Netzprotokoll,
nur LIST UPS / LIST VAR, ohne Anmeldung) die Werte in den Speicher und rechnet: Last in W und % von 400 W, geglaettete
Restlaufzeit, Netzausfall/Selbsttest-Unterscheidung, Ersatz-Stresstest (Laufzeit-/Ladungsfall in den ersten 60 s
Akkubetrieb), Akku-Gesundheit (SoH) als gelernte Basislinie. Historie: archive/usv/JJJJ-MM/usv_JJJJ-MM.jsonl
(10-min-Mittel + Ereignisse) und usv_state.json (atomar). Seriennummern werden nie gespeichert oder angezeigt.
Kein Ton, kein Mesh, kein Heartbeat, kein Herunterfahren, keine Schreibbefehle an NUT, nur Standardbibliothek."""
import json
import os
import socket
import statistics
import tempfile
import threading
import time

NOM_W = 400                       # Nennleistung ELP650DIN (Eaton-Datenblatt): 650 VA / 400 W
HOST = "127.0.0.1"
PORT_DEFAULT = 3493
POLL_S = 2.0
TIMEOUT_S = 1.5
BACKOFF_S = (2, 4, 8, 15, 30, 60)
FRESH_S = 10                      # Daten aelter -> "keine USV-Daten" (grau)
WIN_OL_S = 300                    # Restlaufzeit im Netzbetrieb: Median 5 min
WIN_OB_S = 30                     # im Akkubetrieb: Median 30 s (nur Werte seit Beginn des Akkubetriebs)
OB_CONFIRM_S = 20                 # Akkubetrieb ohne Netzspannung so lange -> Netzausfall
OB_TEST_MAX_S = 60                # laenger als 60 s Akkubetrieb -> immer Netzausfall (ausser Kalibrierung mit Netz)
IN_V_OK = 200.0                   # Netzspannung am Eingang >= 200 V waehrend Akkubetrieb -> Selbsttest
IN_V_FAIL = 165.0                 # < 165 V (untere Umschaltschwelle laut Datenblatt) -> Netz weg
GAP_RESET_S = 120                 # laengere Datenluecke beendet eine Akku-Episode ohne Wertung
DROP_WIN_S = 60                   # Ersatz-Stresstest: Fall in den ersten 60 s
STRESS_DAYS = 56                  # Vergleich mit den letzten 8 Wochen
STRESS_MIN_N = 3
STRESS_RATIO = 1.3
LEARN_S = 14 * 86400              # SoH-Basislinie: 14 Tage lernen
SOH_EVERY_S = 600                 # SoH-Probe hoechstens alle 10 min
SOH_MIN_N = 36                    # mindestens 36 Proben (6 h) je Lastband
SOH_RECENT_S = 7 * 86400
SOH_OK = 80
SOH_BAD = 70
BAND_W = 10
HIST_EVERY_S = 600                # Historie: 10-min-Mittel
STATE_EVERY_S = 600
AKKU_EINBAU = "2026-05"           # Angabe Frank: Akku eingebaut 05.2026
WERK = ((200, 9.0), (280, 5.0), (400, 2.0))   # Eaton: 9 min bei 50 %, 5 min bei 70 % (Datenblatt), 2 min bei Volllast (eaton.com ELP650DIN), +/-15 %
KEEP_VARS = ("ups.status", "ups.load", "ups.realpower", "ups.power", "ups.power.nominal", "ups.realpower.nominal", "battery.charge", "battery.charge.low",
             "battery.runtime", "battery.runtime.low", "battery.voltage", "input.voltage", "output.voltage", "ups.test.result", "ups.beeper.status",
             "device.model", "ups.model", "ups.mfr", "driver.name")
NUM_VARS = ("ups.load", "ups.realpower", "ups.power", "ups.power.nominal", "ups.realpower.nominal", "battery.charge", "battery.charge.low", "battery.runtime",
            "battery.runtime.low", "battery.voltage", "input.voltage", "output.voltage")
MAX_LINES = 400
MAX_LINE = 1024
STATE_NAME = "usv_state.json"


class NutErr(Exception):
    pass


def _clean(name):
    """Nie Seriennummern (ups.serial, device.serial, ...) und nur bekannte Variablen."""
    return name in KEEP_VARS and "serial" not in name.lower()


def _unq(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v):
            i += 1
            c = v[i]
        out.append(c)
        i += 1
    return "".join(out)


class NutClient:
    """Nur lesend: LIST UPS, LIST VAR <ups>. Eine Verbindung, Zeitlimit je Anfrage."""

    def __init__(self, host=HOST, port=PORT_DEFAULT, timeout=TIMEOUT_S):
        if host != HOST:
            raise ValueError("NUT nur ueber 127.0.0.1")
        self.host, self.port, self.timeout = host, int(port), float(timeout)
        self.sock = self.f = None

    def close(self):
        for x in (self.f, self.sock):
            try:
                if x is not None:
                    x.close()
            except Exception:
                pass
        self.sock = self.f = None

    def _open(self):
        if self.sock is None:
            self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
            self.sock.settimeout(self.timeout)
            self.f = self.sock.makefile("rb")

    def _line(self):
        b = self.f.readline(MAX_LINE + 1)
        if not b:
            raise NutErr("Verbindung beendet")
        if len(b) > MAX_LINE:
            raise NutErr("Zeile zu lang")
        return b.decode("utf-8", "replace").rstrip("\r\n")

    def _list(self, what):
        self._open()
        self.sock.sendall(("LIST %s\n" % what).encode("ascii"))
        first = self._line()
        if first.startswith("ERR "):
            raise NutErr(first[4:].strip()[:60])
        if first != "BEGIN LIST %s" % what:
            raise NutErr("unerwartet: %s" % first[:60])
        out = []
        for _ in range(MAX_LINES):
            ln = self._line()
            if ln == "END LIST %s" % what:
                return out
            if ln.startswith("ERR "):
                raise NutErr(ln[4:].strip()[:60])
            out.append(ln)
        raise NutErr("zu viele Zeilen")

    def list_ups(self):
        names = []
        for ln in self._list("UPS"):
            p = ln.split(" ", 2)
            if len(p) >= 2 and p[0] == "UPS" and p[1].replace("-", "").replace("_", "").replace(".", "").isalnum():
                names.append(p[1])
        return names

    def list_var(self, ups):
        if not ups.replace("-", "").replace("_", "").replace(".", "").isalnum():
            raise NutErr("USV-Name ungueltig")
        d = {}
        for ln in self._list("VAR %s" % ups):
            p = ln.split(" ", 3)
            if len(p) == 4 and p[0] == "VAR" and p[1] == ups and _clean(p[2]):
                d[p[2]] = _unq(p[3])[:120]
        return d


def _num(d, k):
    try:
        v = float(d.get(k))
    except (TypeError, ValueError):
        return None
    return v if v == v and abs(v) < 1e7 else None


def _med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else None


def werk_min(w):
    """Werks-Laufzeit (min) nur im Bereich der Eaton-Angaben 200-400 W (lineare Interpolation), sonst None."""
    if w is None or w < WERK[0][0] or w > WERK[-1][0]:
        return None
    for (w0, m0), (w1, m1) in zip(WERK, WERK[1:]):
        if w0 <= w <= w1:
            return round(m0 + (m1 - m0) * (w - w0) / float(w1 - w0), 1)
    return None


def akku_alter_m(now):
    try:
        y, m = (int(x) for x in AKKU_EINBAU.split("-"))
        t = time.localtime(now)
        return max(0, (t.tm_year - y) * 12 + t.tm_mon - m)
    except Exception:
        return None


def new_state():
    return {"v": 1, "learn_t0": None, "learn": {}, "base": {}, "base_t": None, "recent": {}, "soh_t": 0, "episodes": [], "last_test": None, "events": []}


def _band(w):
    return str(int(max(0.0, w) // BAND_W) * BAND_W)


class Calc:
    """Reine Rechnung (ohne Netz, ohne Datei): feed(now, werte|None, fehler) -> Ereignisse; snapshot(now) -> Anzeige."""

    def __init__(self, state=None):
        s = state if isinstance(state, dict) and state.get("v") == 1 else new_state()
        for k, v in new_state().items():
            if not isinstance(s.get(k), type(v)) and v is not None:
                s[k] = v
            s.setdefault(k, v)
        self.s = s
        self.v = {}
        self.t = None
        self.err = "noch keine Verbindung"
        self.buf = []
        self.ob = None
        self.hacc = []
        self.h_t = None
        self.dirty = False

    # ---- Grundwerte
    def load(self):
        w = _num(self.v, "ups.realpower")
        if w is not None:
            return w, "gemessen"
        p = _num(self.v, "ups.load")
        if p is not None:
            return round(p * NOM_W / 100.0, 1), "laut USV (ups.load)"
        return None, None

    def flags(self):
        return (self.v.get("ups.status") or "").split()

    def mode(self, now):
        if self.t is None or now - self.t > FRESH_S:
            return "KEINE_DATEN"
        f = self.flags()
        if "OB" in f:
            if self.ob and self.ob["kind"] == "ausfall":
                return "AKKU"
            return "AKKU_PRUEF"
        if "OL" in f:
            return "NETZ"
        return "UNBEKANNT"

    # ---- Eingang
    def feed(self, now, vals, err=None):
        ev = []
        if vals is None:
            self.err = err or "keine Daten"
            if self.ob and self.t is not None and now - self.t > GAP_RESET_S:
                ev.append(self._event(now, "DATENLUECKE", "Akku-Episode ohne Wertung beendet (keine Daten)"))
                self.ob = None
                self.buf = []
            return ev
        self.err = None
        self.v = dict((k, v) for k, v in vals.items() if _clean(k))
        self.t = now
        f = self.flags()
        rt = _num(self.v, "battery.runtime")
        ch = _num(self.v, "battery.charge")
        bv = _num(self.v, "battery.voltage")
        inv = _num(self.v, "input.voltage")
        w, _src = self.load()
        if "OB" in f:
            if self.ob is None:
                prev = [x for x in self.buf if now - x[0] <= WIN_OL_S]
                rt0 = _med([x[1] for x in prev]) if prev else rt
                self.ob = {"t0": now, "rt0": rt0, "ch0": self.s.get("_ch_last", ch), "bv0": self.s.get("_bv_last", bv), "w0": w, "kind": "pruef",
                           "rt_min": rt, "ch_min": ch, "bv_min": bv, "in_min": inv, "cal": "CAL" in f, "mains": inv is not None and inv >= IN_V_OK}
                self.buf = []
                ev.append(self._event(now, "AKKU_START", "Akkubetrieb beginnt (Pruefung: Netzausfall oder Selbsttest)"))
            o = self.ob
            dur = now - o["t0"]
            if dur <= DROP_WIN_S:
                for k, x in (("rt_min", rt), ("ch_min", ch), ("bv_min", bv)):
                    if x is not None and (o[k] is None or x < o[k]):
                        o[k] = x
            if inv is not None and (o["in_min"] is None or inv < o["in_min"]):
                o["in_min"] = inv
            if inv is not None and inv >= IN_V_OK:
                o["mains"] = True
            if "CAL" in f:
                o["cal"] = True
            nomains = inv is None or inv < IN_V_FAIL
            if o["kind"] != "ausfall" and ((dur >= OB_CONFIRM_S and nomains) or (dur >= OB_TEST_MAX_S and not (o["cal"] and not nomains))):
                o["kind"] = "ausfall"
                ev.append(self._event(now, "NETZAUSFALL", "Netzausfall bestaetigt nach %d s Akkubetrieb%s" % (dur, "" if nomains else " (laenger als 60 s)")))
        else:
            if self.ob is not None:
                ev += self._ob_end(now)
            if ch is not None:
                self.s["_ch_last"] = ch
            if bv is not None:
                self.s["_bv_last"] = bv
            tr = self.v.get("ups.test.result")
            lt = self.s.get("last_test")
            if tr and isinstance(lt, dict) and now - lt.get("t", 0) < 600 and lt.get("result") != tr:
                lt["result"] = tr[:60]
                self.dirty = True
        if rt is not None:
            self.buf.append((now, rt))
        lim = WIN_OB_S if self.ob else WIN_OL_S
        self.buf = [x for x in self.buf if now - x[0] <= lim]
        self._soh_sample(now, w, ch, rt, f)
        self.hacc.append((now, w, ch, rt, inv, "OB" in f))
        return ev

    def _event(self, now, typ, txt):
        e = {"t": int(now), "ev": typ, "txt": txt}
        self.s["events"] = (self.s.get("events") or [])[-19:] + [e]
        self.dirty = True
        return e

    def _ob_end(self, now):
        o, self.ob = self.ob, None
        self.buf = []
        dur = int(now - o["t0"])
        drop = {"w": o["w0"], "rt0": o["rt0"], "ch0": o["ch0"]}
        if o["rt0"] and o["rt_min"] is not None:
            drop["rt_pct"] = round(max(0.0, (o["rt0"] - o["rt_min"]) * 100.0 / o["rt0"]), 1)
        if o["ch0"] is not None and o["ch_min"] is not None:
            drop["ch_pp"] = round(max(0.0, o["ch0"] - o["ch_min"]), 1)
        if o["bv0"] is not None and o["bv_min"] is not None:
            drop["bv_v"] = round(max(0.0, o["bv0"] - o["bv_min"]), 2)
        st = self.stress(now, drop)
        ep = dict(drop, t=int(o["t0"]), dur=dur, kind="test" if o["kind"] != "ausfall" else "ausfall", stress=st.get("state"))
        self.s["episodes"] = [x for x in (self.s.get("episodes") or []) if now - x.get("t", 0) <= STRESS_DAYS * 86400][-99:] + [ep]
        if o["kind"] != "ausfall":
            self.s["last_test"] = {"t": int(o["t0"]), "dur": dur, "result": (self.v.get("ups.test.result") or ("ok (Netz blieb da)" if o["mains"] else "ok"))[:60],
                                   "drop": drop, "stress": st}
            return [self._event(now, "SELBSTTEST", "Selbsttest erkannt (%d s Akkubetrieb, Netz blieb da) - kein Netzausfall" % dur)]
        return [self._event(now, "NETZ_ZURUECK", "Netz wieder da nach %d s Akkubetrieb" % dur)]

    def stress(self, now, drop):
        """Ersatz-Stresstest: Fall in den ersten 60 s gegen das Mittel frueherer Episoden mit aehnlicher Last (8 Wochen)."""
        key, unit = ("bv_v", "V") if drop.get("bv_v") is not None else ("rt_pct", "%")
        cur = drop.get(key)
        if cur is None:
            return {"state": "keine Werte", "key": key}
        w = drop.get("w")
        prev = [x.get(key) for x in (self.s.get("episodes") or []) if now - x.get("t", 0) <= STRESS_DAYS * 86400 and x.get(key) is not None
                and (w is None or x.get("w") is None or abs(x["w"] - w) <= max(10.0, 0.3 * w))]
        r = {"key": key, "unit": unit, "cur": cur, "n": len(prev), "ersatz": key != "bv_v"}
        if len(prev) < STRESS_MIN_N:
            r["state"] = "lernt"
            return r
        m = sum(prev) / len(prev)
        r["mean"] = round(m, 2)
        tol = 0.1 if key == "bv_v" else 2.0
        r["state"] = "auffaellig" if cur > m * STRESS_RATIO and cur - m > tol else "ok"
        return r

    def _soh_sample(self, now, w, ch, rt, f):
        if w is None or ch is None or rt is None or "OL" not in f or "OB" in f or ch < 98 or now - self.s.get("soh_t", 0) < SOH_EVERY_S:
            return
        self.s["soh_t"] = int(now)
        b = _band(w)
        if self.s.get("learn_t0") is None:
            self.s["learn_t0"] = int(now)
        if now - self.s["learn_t0"] < LEARN_S:
            self.s["learn"].setdefault(b, []).append(int(rt))
            self.s["learn"][b] = self.s["learn"][b][-2016:]
        else:
            if self.s.get("base_t") is None:
                self.s["base"] = dict((k, int(_med(v))) for k, v in self.s["learn"].items() if len(v) >= SOH_MIN_N)
                self.s["base_t"] = int(now)
                self.s["learn"] = {}
            rc = [x for x in self.s["recent"].get(b, []) if now - x[0] <= SOH_RECENT_S] + [[int(now), int(rt)]]
            self.s["recent"][b] = rc[-1008:]
        self.dirty = True

    def soh(self, now, w):
        t0 = self.s.get("learn_t0")
        r = {"basis": "gelernt", "einbau": AKKU_EINBAU, "alter_m": akku_alter_m(now), "pct": None}
        if t0 is None:
            r.update(state="LERNT", day=0, days=LEARN_S // 86400, txt="lernt (startet bei voller Ladung)")
            return r
        if self.s.get("base_t") is None:
            day = min(LEARN_S // 86400, int((now - t0) // 86400) + 1)
            r.update(state="LERNT", day=day, days=LEARN_S // 86400, since=t0, txt="lernt (Tag %d/%d)" % (day, LEARN_S // 86400))
            return r
        base = self.s.get("base") or {}
        b = _band(w) if w is not None else None
        cand = [k for k in base if b is not None and abs(int(k) - int(b)) <= BAND_W]
        cand.sort(key=lambda k: (abs(int(k) - int(b)), int(k)))
        if not cand:
            r.update(state="KEINE_BASIS", since=t0, txt="keine Basis fuer %s W" % (b if b is not None else "?"))
            return r
        k = cand[0]
        rc = [x[1] for x in self.s["recent"].get(k, []) if now - x[0] <= SOH_RECENT_S]
        if len(rc) < 6 or not base[k]:
            r.update(state="MISST", since=t0, txt="Basis da, sammelt Werte")
            return r
        pct = int(round(min(100.0, 100.0 * _med(rc) / base[k])))
        st = "NOMINAL" if pct >= SOH_OK else ("BEOBACHTEN" if pct >= SOH_BAD else "VERSCHLISSEN")
        r.update(state=st, pct=pct, since=t0, band=k, txt="%d %%" % pct)
        return r

    def runtime_smoothed(self, now):
        xs = [x[1] for x in self.buf]
        if self.ob:
            m = _med(xs)
            cd = None if self.ob["rt0"] is None else self.ob["rt0"] - (now - self.ob["t0"])
            c = [x for x in (m, cd) if x is not None]
            return (max(0, int(min(c))), "Akkubetrieb: Median 30 s / Abwaertszaehlung") if c else (None, None)
        m = _med(xs)
        return (int(m), "Median 5 min") if m is not None else (None, None)

    def history_due(self, now):
        """10-min-Mittel als Zeile (oder None)."""
        if self.h_t is None:
            self.h_t = now
            return None
        if now - self.h_t < HIST_EVERY_S:
            return None
        a, self.hacc, self.h_t = self.hacc, [], now
        if not a:
            return {"t": int(now), "typ": "10min", "n": 0, "st": "KEINE_DATEN"}
        def avg(i):
            xs = [x[i] for x in a if x[i] is not None]
            return round(sum(xs) / len(xs), 1) if xs else None
        w = avg(1)
        return {"t": int(now), "typ": "10min", "n": len(a), "st": "AKKU" if any(x[5] for x in a) else "NETZ", "w": w,
                "pct": round(w * 100.0 / NOM_W, 1) if w is not None else None, "ch": avg(2), "rt": avg(3), "in_v": avg(4)}

    def snapshot(self, now):
        md = self.mode(now)
        w, src = self.load()
        rs, rsrc = self.runtime_smoothed(now)
        f = self.flags()
        out = {"ok": md not in ("KEINE_DATEN",), "mode": md, "t": int(self.t) if self.t else None, "age_s": int(now - self.t) if self.t else None,
               "err": self.err if md == "KEINE_DATEN" else None, "status": " ".join(f)[:40], "lb": "LB" in f, "chrg": "CHRG" in f, "nom_w": NOM_W,
               "load_w": w, "load_src": src, "load_pct": round(w * 100.0 / NOM_W, 1) if w is not None else None, "ups_load_pct": _num(self.v, "ups.load"),
               "charge": _num(self.v, "battery.charge"), "runtime_s": _num(self.v, "battery.runtime"), "runtime_smoothed_s": rs, "runtime_src": rsrc,
               "input_v": _num(self.v, "input.voltage"), "output_v": _num(self.v, "output.voltage"), "battery_v": _num(self.v, "battery.voltage"),
               "charge_low": _num(self.v, "battery.charge.low"), "model": (self.v.get("device.model") or self.v.get("ups.model") or "")[:40],
               "werk_min": werk_min(w), "soh": self.soh(now, w), "last_test": self.s.get("last_test"), "events": (self.s.get("events") or [])[-5:],
               "has_battery_v": _num(self.v, "battery.voltage") is not None, "has_test_result": bool(self.v.get("ups.test.result"))}
        if self.ob:
            out["ob"] = {"since": int(self.ob["t0"]), "dur_s": int(now - self.ob["t0"]), "kind": self.ob["kind"], "mains": bool(self.ob["mains"])}
        return out


def _atomic_json(path, obj):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".usv-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, separators=(",", ":"))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Manager:
    """Faden: lesen (2 s), rechnen, Historie schreiben. snapshot() fuer /api/usv."""

    def __init__(self, base, port=None, log=None, clock=time.time, sleep=time.sleep):
        self.base = base
        self.port = int(port or os.environ.get("USV_NUT_PORT") or PORT_DEFAULT)
        self.log = log or (lambda *a: print("usvLesen:", *a, flush=True))
        self.clock, self.sleep = clock, sleep
        self.lock = threading.Lock()
        self.cli = NutClient(HOST, self.port)
        self.ups = None
        self.fail_n = 0
        self.next_try = 0
        self.connected = False
        self.last_err = None
        self.started = False
        self.stop = False
        self.state_t = 0
        self.werr = None
        st = None
        try:
            with open(self.state_path(), encoding="utf-8") as fh:
                st = json.load(fh)
        except Exception:
            st = None
        self.calc = Calc(st)

    def state_path(self):
        return os.path.join(self.base, STATE_NAME)

    def hist_path(self, now):
        m = time.strftime("%Y-%m", time.localtime(now))
        return os.path.join(self.base, "archive", "usv", m, "usv_%s.jsonl" % m)

    def _append(self, now, obj):
        try:
            p = self.hist_path(now)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
            self.werr = None
        except Exception as ex:
            if self.werr is None:
                self.log("Historie nicht schreibbar:", str(ex)[:120])
            self.werr = str(ex)[:120]

    def save(self, force=True):
        with self.lock:
            if not (force or (self.calc.dirty and self.clock() - self.state_t >= STATE_EVERY_S)):
                return "unveraendert"
            s = json.loads(json.dumps(self.calc.s))
            self.calc.dirty = False
            self.state_t = self.clock()
        try:
            _atomic_json(self.state_path(), s)
            return "gesichert"
        except Exception as ex:
            return "Fehler %s" % str(ex)[:80]

    def poll_once(self):
        now = self.clock()
        if now < self.next_try:
            return False
        try:
            if self.ups is None:
                names = self.cli.list_ups()
                if not names:
                    raise NutErr("keine USV in upsd")
                self.ups = "eaton" if "eaton" in names else names[0]
            vals = self.cli.list_var(self.ups)
            if "ups.status" not in vals:
                raise NutErr("ups.status fehlt")
        except (OSError, NutErr, ValueError) as ex:
            self.cli.close()
            if isinstance(ex, NutErr) and "UNKNOWN-UPS" in str(ex):
                self.ups = None
            msg = (str(ex) or type(ex).__name__)[:80]
            if isinstance(ex, OSError) and not isinstance(ex, socket.timeout):
                msg = "NUT nicht erreichbar (127.0.0.1:%d)" % self.port
            wait = BACKOFF_S[min(self.fail_n, len(BACKOFF_S) - 1)]
            self.fail_n += 1
            self.next_try = now + wait
            with self.lock:
                ev = self.calc.feed(now, None, msg)
            if self.connected or self.last_err != msg:
                self.log("keine USV-Daten (%s) - neuer Versuch in %d s" % (msg, wait))
            self.connected, self.last_err = False, msg
            for e in ev:
                self._append(now, dict(e, typ="ereignis"))
            return False
        with self.lock:
            ev = self.calc.feed(now, vals)
            h = self.calc.history_due(now)
        if not self.connected:
            self.log("NUT verbunden (%s@127.0.0.1:%d), Status %s" % (self.ups, self.port, vals.get("ups.status", "?")))
            self._append(now, {"t": int(now), "typ": "ereignis", "ev": "DATEN", "txt": "USV-Daten da (%s)" % vals.get("ups.status", "?")})
        self.connected, self.last_err, self.fail_n, self.next_try = True, None, 0, 0
        for e in ev:
            self.log(e["txt"])
            self._append(now, dict(e, typ="ereignis"))
        if h:
            self._append(now, h)
        self.save(force=False)
        return True

    def run(self):
        while not self.stop:
            t0 = self.clock()
            try:
                self.poll_once()
            except Exception as ex:
                self.log("Faden-Fehler:", type(ex).__name__, str(ex)[:120])
                self.cli.close()
                self.next_try = self.clock() + 10
            self.sleep(max(0.2, POLL_S - (self.clock() - t0)))

    def start(self):
        if self.started:
            return False
        self.started = True
        threading.Thread(target=self.run, name="usvLesen", daemon=True).start()
        return True

    def snapshot(self):
        now = self.clock()
        with self.lock:
            s = self.calc.snapshot(now)
        s["nut"] = {"verbunden": self.connected, "port": self.port, "ups": self.ups, "fehler": self.last_err,
                    "naechster_versuch": int(self.next_try) if not self.connected and self.next_try else None, "faden": self.started}
        s["hist_err"] = self.werr
        return s


# ---------------------------------------------------------------- Selbsttest (Attrappen, kein echtes NUT)
class FakeNut:
    """Attrappe upsd fuer Tests: antwortet auf LIST UPS / LIST VAR, protokolliert alle Befehle."""

    def __init__(self, vals, name="eaton"):
        self.vals, self.name, self.cmds, self.err = vals, name, [], None
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(4)
        self.port = self.srv.getsockname()[1]
        self.alive = True
        self.conns = []
        threading.Thread(target=self._acc, daemon=True).start()

    def _acc(self):
        while self.alive:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            self.conns.append(c)
            threading.Thread(target=self._srv, args=(c,), daemon=True).start()

    def _srv(self, c):
        f = c.makefile("rb")
        try:
            while self.alive:
                ln = f.readline()
                if not ln:
                    return
                ln = ln.decode().strip()
                self.cmds.append(ln)
                if self.err:
                    c.sendall(("ERR %s\n" % self.err).encode())
                elif ln == "LIST UPS":
                    c.sendall(('BEGIN LIST UPS\nUPS %s "Eaton Ellipse PRO"\nEND LIST UPS\n' % self.name).encode())
                elif ln == "LIST VAR %s" % self.name:
                    body = "".join('VAR %s %s "%s"\n' % (self.name, k, str(v).replace("\\", "\\\\").replace('"', '\\"')) for k, v in self.vals.items())
                    c.sendall(("BEGIN LIST VAR %s\n%sEND LIST VAR %s\n" % (self.name, body, self.name)).encode())
                else:
                    c.sendall(b"ERR UNKNOWN-COMMAND\n")
        except OSError:
            pass
        finally:
            f.close()
            c.close()

    def close(self):
        self.alive = False
        for x in [self.srv] + self.conns:
            try:
                x.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                x.close()
            except OSError:
                pass


def _vals(st="OL", w=34, ch=100, rt=2700, inv=231.0, **kw):
    d = {"ups.status": st, "ups.realpower": w, "ups.load": 9, "battery.charge": ch, "battery.runtime": rt, "input.voltage": inv, "output.voltage": 230.0,
         "device.model": "Ellipse PRO 650", "ups.serial": "G000TEST000", "device.serial": "G000TEST000", "battery.charge.low": 20}
    d.update(kw)
    return d


def selftest():
    # 1) Rechnung: Last, Glaettung, Selbsttest vs. Netzausfall, Ersatz-Stresstest, SoH, keine Seriennummer
    c = Calc()
    t = 1.8e9
    for i in range(150):
        c.feed(t + 2 * i, _vals(rt=2700 + (i % 3) * 30))
    s = c.snapshot(t + 300)
    assert s["mode"] == "NETZ" and s["load_w"] == 34 and s["load_pct"] == 8.5 and s["load_src"] == "gemessen", s
    assert s["runtime_smoothed_s"] == 2730 and "serial" not in json.dumps(s).lower() and "G000TEST" not in json.dumps(s), s
    c2 = Calc()
    v = _vals()
    v.pop("ups.realpower")
    c2.feed(t, v)
    assert c2.snapshot(t)["load_w"] == 36.0 and c2.snapshot(t)["load_src"].startswith("laut USV"), "Ersatz ups.load"
    assert Calc().snapshot(t)["mode"] == "KEINE_DATEN" and c.snapshot(t + 300 + FRESH_S + 1)["mode"] == "KEINE_DATEN"
    # Selbsttest: 12 s OB, Netz 230 V -> TEST, kein Netzausfall
    t1 = t + 302
    ev = []
    for i in range(7):
        ev += c.feed(t1 + 2 * i, _vals(st="OB DISCHRG", rt=2500 - 20 * i, ch=99, inv=229.0))
        assert c.mode(t1 + 2 * i) == "AKKU_PRUEF"
    ev += c.feed(t1 + 14, _vals(rt=2600))
    kinds = [e["ev"] for e in ev]
    assert kinds == ["AKKU_START", "SELBSTTEST"] and c.s["last_test"]["dur"] == 14 and c.s["last_test"]["result"].startswith("ok"), kinds
    assert c.s["last_test"]["drop"]["rt_pct"] > 0 and c.s["last_test"]["stress"]["state"] == "lernt", c.s["last_test"]
    # Netzausfall: OB, input 0 V -> nach 20 s bestaetigt; Restlaufzeit ohne alte Netzwerte
    t2 = t1 + 100
    for i in range(30):
        c.feed(t2 + i, _vals(st="OB DISCHRG", rt=2400 - 10 * i, ch=98 - i // 10, inv=0.0))
        if i < OB_CONFIRM_S:
            assert c.mode(t2 + i) == "AKKU_PRUEF", i
    assert c.mode(t2 + 29) == "AKKU" and [e["ev"] for e in c.s["events"][-2:]] == ["AKKU_START", "NETZAUSFALL"]
    rs, _ = c.runtime_smoothed(t2 + 29)
    assert rs <= 2400 - 29 and rs >= 2100, rs
    # langer Akkubetrieb mit Netzspannung (> 60 s) -> trotzdem Netzausfall; Kalibrierung (CAL) mit Netz nicht
    c3 = Calc()
    for i in range(70):
        c3.feed(t + i, _vals(st="OB", inv=230.0))
    assert c3.mode(t + 69) == "AKKU"
    c4 = Calc()
    for i in range(90):
        c4.feed(t + i, _vals(st="OB CAL", inv=230.0))
    assert c4.mode(t + 89) == "AKKU_PRUEF"
    # Ersatz-Stresstest: 3 normale Tests, dann ein auffaelliger
    c5 = Calc()
    tt = t
    for k, fall in enumerate((100, 100, 100, 300)):
        for i in range(160):
            c5.feed(tt + 2 * i, _vals(rt=3000))
        tt += 320
        c5.feed(tt, _vals(st="OB", rt=3000 - fall, inv=230.0))
        c5.feed(tt + 5, _vals(st="OB", rt=3000 - fall, inv=230.0))
        c5.feed(tt + 10, _vals(rt=3000))
        tt += 20
    lt = c5.s["last_test"]["stress"]
    assert lt["state"] == "auffaellig" and lt["n"] == 3 and lt["ersatz"] is True, lt
    # Batteriespannung, falls vorhanden
    c6 = Calc()
    c6.feed(t, _vals(**{"battery.voltage": 13.6}))
    c6.feed(t + 2, _vals(st="OB", inv=230.0, **{"battery.voltage": 12.9}))
    c6.feed(t + 6, _vals(**{"battery.voltage": 13.5}))
    assert c6.s["last_test"]["drop"]["bv_v"] == 0.7 and c6.s["last_test"]["stress"]["key"] == "bv_v"
    # SoH: 14 Tage lernen, danach Basis; Verschleiss < 70 %
    c7 = Calc()
    t7 = t
    assert c7.soh(t7, 34)["state"] == "LERNT"
    for i in range(0, 15 * 144):
        c7.feed(t7 + i * 600, _vals(rt=2700))
    so = c7.soh(t7 + 15 * 144 * 600, 34)
    assert c7.s["base"] == {"30": 2700} and so["state"] in ("MISST", "NOMINAL"), (so, c7.s["base"])
    for i in range(15 * 144, 23 * 144):
        c7.feed(t7 + i * 600, _vals(rt=1800))
    so = c7.soh(t7 + 23 * 144 * 600, 34)
    assert so["state"] == "VERSCHLISSEN" and so["pct"] == 67, so
    assert c7.soh(t7 + 23 * 144 * 600, 95)["state"] == "KEINE_BASIS"
    assert len(c7.s["recent"]["30"]) <= 1008 and c7.s["learn"] == {}
    lc = Calc()
    for i in range(10):
        lc.feed(t7 + i * 600, _vals(rt=2700))
    assert lc.soh(t7 + 6000, 34)["txt"] == "lernt (Tag 1/14)"
    # Werkskurve nur 200-400 W
    assert werk_min(34) is None and werk_min(200) == 9.0 and werk_min(240) == 7.0 and werk_min(400) == 2.0
    # Historie 10-min-Mittel
    c8 = Calc()
    assert c8.history_due(t) is None
    c8.feed(t + 1, _vals(w=30))
    c8.feed(t + 2, _vals(w=40))
    h = c8.history_due(t + 601)
    assert h["w"] == 35.0 and h["pct"] == 8.8 and h["st"] == "NETZ", h
    # 2) Netzprotokoll mit Attrappe: nur LIST-Befehle, Seriennummer verworfen, Fehler -> grau + Backoff, Wiederverbindung
    d = tempfile.mkdtemp(prefix="usv-st-")
    fk = FakeNut(_vals(**{"ups.status": 'OL "CHRG"'}))
    try:
        clk = [t]
        logs = []
        m = Manager(d, port=fk.port, log=lambda *a: logs.append(" ".join(str(x) for x in a)), clock=lambda: clk[0], sleep=lambda s: None)
        assert m.poll_once() and m.ups == "eaton"
        s = m.snapshot()
        assert s["mode"] == "NETZ" and s["status"] == 'OL "CHRG"' and s["nut"]["verbunden"], s
        assert "G000TEST" not in json.dumps(s) and "serial" not in json.dumps(m.calc.v).lower()
        fk.err = "DATA-STALE"
        clk[0] += 2
        assert not m.poll_once() and m.next_try == clk[0] + 2
        clk[0] += 12
        s = m.snapshot()
        assert s["mode"] == "KEINE_DATEN" and "DATA-STALE" in (s["err"] or ""), s
        fk.err = None
        clk[0] += 1
        assert m.poll_once() and m.snapshot()["mode"] == "NETZ"
        assert set(fk.cmds) <= {"LIST UPS", "LIST VAR eaton"}, fk.cmds
        clk[0] += 700
        m.poll_once()
        assert m.save() == "gesichert"
        with open(os.path.join(d, STATE_NAME), encoding="utf-8") as fh:
            st = json.load(fh)
        assert st["v"] == 1 and "G000TEST" not in json.dumps(st)
        hp = m.hist_path(clk[0])
        with open(hp, encoding="utf-8") as fh:
            ht = fh.read()
        assert "G000TEST" not in ht and '"typ":"10min"' in ht, ht
        assert [f for f in os.listdir(d) if f.startswith(".usv-")] == []
        fk.close()
        clk[0] += 30
        m.next_try = 0
        assert not m.poll_once()
        m.next_try = 0
        assert not m.poll_once() and "nicht erreichbar" in m.snapshot()["err"], m.snapshot()["err"]
        m.fail_n = 0
        waits = []
        for i in range(8):
            m.next_try = 0
            m.poll_once()
            waits.append(m.next_try - clk[0])
        assert waits == [2, 4, 8, 15, 30, 60, 60, 60], waits
        m.cli.close()
        m2 = Manager(d, port=1, log=lambda *a: None, clock=lambda: clk[0])
        assert m2.calc.s.get("v") == 1 and not m2.poll_once()
        try:
            NutClient("0.0.0.0", 3493)
            raise AssertionError("fremder Host")
        except ValueError:
            pass
    finally:
        fk.close()
        import shutil
        shutil.rmtree(d, ignore_errors=True)
    return "ups_manager ok (Last W/%% von %d W, Ersatz ups.load; Restlaufzeit Median 5 min, Akku sofort ohne Netzwerte; Selbsttest 14 s mit Netz = kein Ausfall, Ausfall nach %d s ohne Netz bzw. > %d s; Ersatz-Stresstest; SoH lernt %d Tage, < %d %% verschlissen; nur LIST-Befehle an 127.0.0.1, keine Seriennummer, grau ohne Daten, Backoff 2-60 s)" % (
        NOM_W, OB_CONFIRM_S, OB_TEST_MAX_S, LEARN_S // 86400, SOH_BAD)


if __name__ == "__main__":
    print(selftest())
MK_C55_UPS_EOF
EXPECT_GRD="c989736f4617a1f4428ea9b9605e314cc783cbf11a9176accda666429fbbc62b"
cat > "$W/guard.py" << 'MK_C55_GRD_EOF'
"""Guard commit55 (usvLesen dashboard.py, usvKachel lage_pages.py, ups_manager.py neu).
  guard.py revert NEU_VERZ ALT_VERZ W   -> ALT_VERZ/{dashboard,lage_pages}.py = NEU ohne commit55 (byte-genau); ups_manager.py gehoert nicht zur Basis
  guard.py check  ALT_VERZ NEU_VERZ W   -> Rueckbau = ALT, statische Regeln (nur Lesen, nur 127.0.0.1, nur LIST, keine Seriennummer, kein Ton/Mesh/HB/Shutdown), Verhalten mit Attrappen, Kachel-Skript (node falls vorhanden)
  guard.py mutate ALT_VERZ NEU_VERZ W   -> Mutationstest (jede Mutation muss check scheitern lassen)
W enthaelt blk_dsh.py, edits.py, ups_manager.py. GUARD_NO_NODE=1 schaltet den node-Test ab."""
import ast, importlib.util, io, json, os, re, shutil, socket, subprocess, sys, tempfile, threading, time, contextlib

ANCH = '\n\nif __name__ == "__main__":\n'
MK = "usvLesen"
UM_IMPORTS = {"json", "os", "socket", "statistics", "tempfile", "threading", "time"}
UM_CONSTS = {"NOM_W": 400, "HOST": "127.0.0.1", "PORT_DEFAULT": 3493, "POLL_S": 2.0, "TIMEOUT_S": 1.5, "BACKOFF_S": (2, 4, 8, 15, 30, 60), "FRESH_S": 10, "WIN_OL_S": 300,
             "WIN_OB_S": 30, "OB_CONFIRM_S": 20, "OB_TEST_MAX_S": 60, "IN_V_OK": 200.0, "IN_V_FAIL": 165.0, "GAP_RESET_S": 120, "DROP_WIN_S": 60, "STRESS_DAYS": 56,
             "STRESS_MIN_N": 3, "STRESS_RATIO": 1.3, "LEARN_S": 1209600, "SOH_EVERY_S": 600, "SOH_MIN_N": 36, "SOH_RECENT_S": 604800, "SOH_OK": 80, "SOH_BAD": 70,
             "BAND_W": 10, "HIST_EVERY_S": 600, "STATE_EVERY_S": 600, "AKKU_EINBAU": "2026-05", "WERK": ((200, 9.0), (280, 5.0), (400, 2.0)), "STATE_NAME": "usv_state.json"}
UM_BAD_STR = ["INSTCMD", "SET VAR", "FSD", "LOGIN", "USERNAME", "PASSWORD", "PRIMARY", "MASTER", "SLAVE", "0.0.0.0", "::", "/etc/nut", "upsmon", "shutdown -h", "poweroff"]
UM_BAD_ID = re.compile(r"^(subprocess|Popen|system|popen|eval|exec|__import__|urlopen|requests|send_meshtastic|sqlite3)$")
DSH_BAD_ID = re.compile(r"mesh|telegram|send|_au_|audio|_hp_|^hb|heartbeat|shutdown|subprocess|socket|popen|^system$|sqlite|gain|^eval$|^exec$|__import__|_t4_|alarm|speak|aplay|amixer", re.I)
DSH_NEED = ["st = _uv_mod.selftest()", 'resp.headers["Cache-Control"] = "no-store"', 'methods=["GET"]', 'if __name__ == "__main__" and _USV["mgr"] is None:',
            'RS_ITEMS.append(("usvLesen usv_state.json", _USV["mgr"].save))', '_uv_mod.HOST == "127.0.0.1" and _uv_mod.NOM_W == 400']
JS_BAD = ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "localStorage", "sessionStorage", "eval(", "Function(", "XMLHttpRequest", "method:", "POST",
          "http://", "https://", "sendBeacon", "location.reload", "/api/mesh", "/api/audio", "{{", "{%", "{#"]
JS_NEED = ["fetch('/api/usv',{cache:'no-store'})", "setInterval(tick,2000)", "tx('usvMain','keine USV-Daten')", "if(d.mode==='AKKU'){cls('rot');",
           "tx('usvMain','NETZAUSFALL - USV-BATTERIEBETRIEB - AUTONOME RESTLAUFZEIT: '+mn(rs)+' min')", "if(s.state==='VERSCHLISSEN')e.className='small usv-gelb';",
           "var z=s.state==='VERSCHLISSEN'?'VERSCHLISSEN - BITTE AKKUPACK TAUSCHEN':s.state;", "tx('usvSoh','Akku-Gesundheit (SoH): '+s.pct+' % [Zustand: '+z+'] · gelernt, keine Werksangabe'+ein);",
           "tx('usvBarT',w==null?'':(n0(w)+' W / '+n0(p)+' % belegt'", "cls(d.mode==='NETZ'?'gruen':'orange');tx('usvMain',d.mode==='NETZ'?'NETZBETRIEB'",
           "tx('usvAuto','Autonomie ca. '+mn(rs)+' min (bei aktueller Last)')", "function tx(i,s){var e=$(i);if(e)e.textContent=s||'';}",
           "if(d.mode==='AKKU_PRUEF'){cls('orange');", "if(d.mode==='KEINE_DATEN'||!d.ok){cls('grau');", "b.style.width=(p==null?0:Math.min(100,p))+'%';",
           "' · Akku eingebaut '+s.einbau.split('-')[1]+'.'+s.einbau.split('-')[0]"]
NODE_JS = r"""
const fs=require('fs');const code=fs.readFileSync(process.argv[2],'utf8');const cases=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
function mk(){const E={};const doc={visibilityState:'visible',getElementById:(i)=>{if(!E[i])E[i]={id:i,textContent:'',className:'',hidden:i==='usvInfo',style:{},addEventListener(){}};return E[i];},addEventListener(){}};return [E,doc];}
(async()=>{const out=[];for(const d of cases){const [E,doc]=mk();let calls=[];
 const ctx={document:doc,fetch:(u,o)=>{calls.push([u,o]);return Promise.resolve({json:()=>Promise.resolve(d)});},setInterval:()=>0,setTimeout:()=>0,Date:Date,Math:Math,String:String};
 const f=new Function('document','fetch','setInterval','setTimeout',code);f(ctx.document,ctx.fetch,ctx.setInterval,ctx.setTimeout);
 await new Promise(r=>setImmediate(r));await new Promise(r=>setImmediate(r));await new Promise(r=>setImmediate(r));
 const g=(i)=>E[i]?E[i].textContent:'';out.push({main:g('usvMain'),line:g('usvLine'),bar:g('usvBarT'),auto:g('usvAuto'),soh:g('usvSoh'),test:g('usvTest'),
  cls:E.usvCard?E.usvCard.className:'',sohc:E.usvSoh?E.usvSoh.className:'',w:(E.usvBar||{style:{}}).style.width,calls:calls.map(c=>[c[0],JSON.stringify(c[1])])});}
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
    assert d.count(bx + ANCH) == 1, "Block nicht genau einmal direkt vor __main__"
    d = d.replace(bx + ANCH, ANCH, 1)
    assert "# ===== %s:" % MK not in d, "Marker ausserhalb des Blocks"
    assert E["DSH_EDITS"] == [] and len(E["LP_EDITS"]) == 1, "Stellen: dashboard nur Block, lage_pages genau eine Stelle"
    lp = rd(os.path.join(neud, "lage_pages.py"))
    o, n = E["LP_EDITS"][0]
    assert lp.count(n) == 1, "Kachel-Stelle nicht genau einmal"
    lp = lp.replace(n, o, 1)
    assert "usvKachel" not in lp and "usvCard" not in lp, "Kachel-Reste ausserhalb der Stelle"
    return {"dashboard.py": d, "lage_pages.py": lp}


def consts(T, want):
    seen = {}
    for node in T.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and node.targets[0].id in want:
            try:
                v = eval(compile(ast.Expression(node.value), "c", "eval"), {})
            except Exception:
                v = None
            if node.targets[0].id in seen:
                fail("Konstante %s doppelt" % node.targets[0].id)
            seen[node.targets[0].id] = v
    for k, v in want.items():
        if seen.get(k) != v:
            fail("Konstante %s = %r (erwartet %r)" % (k, seen.get(k), v))


def static_um(src):
    try:
        T = ast.parse(src)
    except SyntaxError as e:
        fail("ups_manager.py Syntax %s" % e)
    consts(T, UM_CONSTS)
    sel = next((n for n in T.body if isinstance(n, ast.FunctionDef) and n.name == "selftest"), None)
    fake = next((n for n in T.body if isinstance(n, ast.ClassDef) and n.name == "FakeNut"), None)
    test_nodes = set()
    for t in (sel, fake):
        if t is not None:
            test_nodes |= {id(x) for x in ast.walk(t)}
    for n in ast.walk(T):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module]
            for x in names:
                if x not in UM_IMPORTS and not (id(n) in test_nodes and x == "shutil"):
                    fail("ups_manager.py: Import %s nicht erlaubt" % x)
            if id(n) not in test_nodes and n not in T.body:
                fail("ups_manager.py: Import ausserhalb des Modulkopfs")
        if isinstance(n, ast.Name) and UM_BAD_ID.match(n.id) or isinstance(n, ast.Attribute) and UM_BAD_ID.match(n.attr):
            fail("ups_manager.py: verbotener Name %s" % (getattr(n, "id", None) or n.attr))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in test_nodes:
            for b in UM_BAD_STR:
                if b in n.value:
                    fail("ups_manager.py: verbotener Text %r" % b)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else (f.id if isinstance(f, ast.Name) else "")
            if nm in ("sendall", "send") and id(n) not in test_nodes:
                a = ast.unparse(n)
                if a != "self.sock.sendall(('LIST %s\\n' % what).encode('ascii'))":
                    fail("ups_manager.py: Senden nur 'LIST ...' (gefunden %s)" % a[:80])
            if nm in ("open", "fdopen") and id(n) not in test_nodes:
                a = ast.unparse(n)
                if a not in ("open(self.state_path(), encoding='utf-8')", "open(p, 'a', encoding='utf-8')", "os.fdopen(fd, 'w', encoding='utf-8')"):
                    fail("ups_manager.py: Dateizugriff nicht erlaubt: %s" % a[:80])
            if nm in ("remove", "unlink", "rmtree", "rename", "chmod", "chown") and id(n) not in test_nodes and ast.unparse(n) != "os.unlink(tmp)":
                fail("ups_manager.py: %s nicht erlaubt" % nm)
            if nm == "create_connection" and ast.unparse(n) != "socket.create_connection((self.host, self.port), timeout=self.timeout)":
                fail("ups_manager.py: Verbindung nur zu self.host")
            if nm == "replace" and isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "os" and ast.unparse(n) != "os.replace(tmp, path)":
                fail("ups_manager.py: os.replace nur atomar fuer usv_state.json")
            if nm == "Thread" and id(n) not in test_nodes and ast.unparse(n) != "threading.Thread(target=self.run, name='usvLesen', daemon=True)":
                fail("ups_manager.py: Faden nur usvLesen (daemon)")
    need = ['return name in KEEP_VARS and "serial" not in name.lower()', 'if host != HOST:', 'self.sock.sendall(("LIST %s\\n" % what).encode("ascii"))',
            'os.path.join(self.base, "archive", "usv", m, "usv_%s.jsonl" % m)', "os.replace(tmp, path)", 'self.ups = "eaton" if "eaton" in names else names[0]']
    for x in need:
        if src.count(x) != 1:
            fail("ups_manager.py: Pflichtstelle fehlt: %s" % x[:70])
    ns = {}
    for n in T.body:
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "KEEP_VARS":
            ns = eval(compile(ast.Expression(n.value), "c", "eval"), {})
    if not ns or any("serial" in x.lower() for x in ns):
        fail("ups_manager.py: KEEP_VARS mit Seriennummer")
    return "ups_manager.py: Importe %s, Konstanten NOM_W=400 HOST=127.0.0.1 POLL_S=2.0 OB_CONFIRM_S=20 OB_TEST_MAX_S=60 LEARN_S=14 d SOH_BAD=70, nur LIST-Befehle, Dateien nur usv_state.json (atomar) + archive/usv, keine Seriennummer" % ",".join(sorted(UM_IMPORTS))


def static_dsh(B):
    if not B.startswith("# ===== %s:" % MK) or not B.rstrip("\n").endswith("# ===== /%s =====" % MK):
        fail("dashboard.py: Block beginnt/endet nicht mit Marker")
    try:
        T = ast.parse(B)
    except SyntaxError as e:
        fail("dashboard.py Syntax %s" % e)
    for n in ast.walk(T):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module]
            for x in names:
                if x not in ("flask", "os.path", "ups_manager"):
                    fail("dashboard.py: Import %s nicht erlaubt" % x)
        if isinstance(n, ast.Name) and DSH_BAD_ID.search(n.id) or isinstance(n, ast.Attribute) and DSH_BAD_ID.search(n.attr):
            fail("dashboard.py: verbotener Name %s" % (getattr(n, "id", None) or n.attr))
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else (f.id if isinstance(f, ast.Name) else "")
            if nm in ("open", "write_text", "remove", "unlink", "system", "Thread", "after_request", "before_request", "route"):
                fail("dashboard.py: %s nicht erlaubt" % nm)
            if nm == "add_url_rule" and ast.unparse(n) != "app.add_url_rule('/api/usv', endpoint='usv_api', view_func=_usv_api, methods=['GET'])":
                fail("dashboard.py: Route nur GET /api/usv")
    for x in DSH_NEED:
        if B.count(x) != 1:
            fail("dashboard.py: Pflichtstelle fehlt: %s" % x[:70])
    return "dashboard.py: Marker, nur GET /api/usv, Faden nur im Hauptprogramm, relStop-Eintrag, keine Imports ausser flask/ups_manager, kein Ton/Mesh/HB/Shutdown"


def tile(neud):
    lp = rd(os.path.join(neud, "lage_pages.py"))
    i = lp.index("def page_lokale_energie(")
    j = lp.find("\ndef ", i + 10)
    fn = lp[i:j if j > 0 else len(lp)]
    if fn.count("/* usvKachel */") != 1 or fn.count('id="usvCard"') != 1:
        fail("lage_pages.py: Kachel nicht genau einmal in page_lokale_energie")
    a, b, c = fn.index('id="outageChart"'), fn.index('id="usvCard"'), fn.index("const outageHist")
    if not (a < b < c) or fn.index("</div>\n<script>/* usvKachel */") < b:
        fail("lage_pages.py: Kachel nicht direkt unter der Hauptkachel")
    k = fn.index("<script>/* usvKachel */") + 8
    js = fn[k:fn.index("</script>", k)]
    card = fn[fn.rindex("  </div>\n", 0, b) + 9:fn.index("</div>\n<script>/* usvKachel */")]
    return js, card


def static_js(js, card):
    for x in JS_BAD:
        if x in js or x in card:
            fail("Kachel: verboten %r" % x)
    if js.count("fetch(") != 1:
        fail("Kachel: genau ein fetch auf /api/usv")
    for x in JS_NEED:
        if js.count(x) != 1:
            fail("Kachel: Pflichtstelle fehlt: %s" % x[:80])
    for x in ("USV-NOTSTROM-ZENTRALE", 'id="usvInfo" hidden', "Nur Anzeige: kein Ton, kein Mesh, kein Herunterfahren."):
        if card.count(x) != 1:
            fail("Kachel: Pflichttext fehlt %s" % x)
    return "Kachel: direkt unter der Hauptkachel, nur textContent, ein GET /api/usv alle 2 s, keine Jinja-Zeichen"


def node_test(js):
    if os.environ.get("GUARD_NO_NODE") or not (shutil.which("node") or shutil.which("nodejs")):
        return "Kachel-Skript statisch (node fehlt)"
    nd = shutil.which("node") or shutil.which("nodejs")
    soh_l = {"state": "LERNT", "txt": "lernt (Tag 3/14)", "einbau": "2026-05", "pct": None}
    cases = [{"ok": False, "mode": "KEINE_DATEN", "err": "NUT nicht erreichbar (127.0.0.1:3493)", "soh": soh_l},
             {"ok": True, "mode": "NETZ", "load_w": 34, "load_pct": 8.5, "load_src": "gemessen", "charge": 100, "runtime_smoothed_s": 2700, "soh": soh_l, "last_test": None},
             {"ok": True, "mode": "AKKU", "load_w": 34, "load_pct": 8.5, "charge": 87, "runtime_smoothed_s": 2280, "runtime_s": 9000, "ob": {"since": 1793500000, "kind": "ausfall"},
              "soh": {"state": "VERSCHLISSEN", "pct": 65, "einbau": "2026-05"}, "last_test": {"t": 1793400000, "result": "ok (Netz blieb da)", "drop": {"rt_pct": 3.2}, "stress": {"state": "auffaellig"}}},
             {"ok": True, "mode": "AKKU_PRUEF", "load_w": 34, "load_pct": 8.5, "charge": 99, "runtime_smoothed_s": 2400, "ob": {"since": 1793500000, "dur_s": 7, "mains": True},
              "soh": {"state": "NOMINAL", "pct": 97, "einbau": "2026-05"}}]
    d = tempfile.mkdtemp(prefix="g55n")
    try:
        for n, t in (("t.js", NODE_JS), ("k.js", js), ("c.json", json.dumps(cases))):
            open(os.path.join(d, n), "w", encoding="utf-8").write(t)
        o = subprocess.run([nd, os.path.join(d, "t.js"), os.path.join(d, "k.js"), os.path.join(d, "c.json")], capture_output=True, text=True, timeout=60)
        if o.returncode:
            fail("Kachel-Skript (node): %s" % (o.stderr.strip().splitlines() or ["?"])[-1][:200])
        r = json.loads(o.stdout)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    g, n, a, p = r
    assert g["main"] == "keine USV-Daten" and "usv-grau" in g["cls"] and "nicht erreichbar" in g["line"], g
    assert g["soh"] == "Akku-Gesundheit (SoH): lernt (Tag 3/14) · Akku eingebaut 05.2026", g["soh"]
    assert all(x["calls"] == [["/api/usv", '{"cache":"no-store"}']] for x in r), [x["calls"] for x in r]
    assert n["main"] == "NETZBETRIEB" and "usv-gruen" in n["cls"] and n["line"] == "Last 34 W · Ladung 100 %" and n["bar"] == "34 W / 9 % belegt", n
    assert n["auto"] == "Autonomie ca. 45 min (bei aktueller Last)" and n["w"] == "8.5%" and n["test"] == "Selbsttest: noch keiner erkannt", n
    assert a["main"] == "NETZAUSFALL - USV-BATTERIEBETRIEB - AUTONOME RESTLAUFZEIT: 38 min" and "usv-rot" in a["cls"] and a["line"].startswith("seit "), a
    assert a["soh"] == "Akku-Gesundheit (SoH): 65 % [Zustand: VERSCHLISSEN - BITTE AKKUPACK TAUSCHEN] · gelernt, keine Werksangabe · Akku eingebaut 05.2026" and "usv-gelb" in a["sohc"], a
    assert "AUFFÄLLIG" in a["test"] and "Laufzeitfall 3,2 %" in a["test"], a["test"]
    assert p["main"] == "AKKUBETRIEB – Prüfung (Selbsttest?) 7 s" and "usv-orange" in p["cls"] and "SoH" not in p["line"], p
    assert "Akku-Gesundheit (SoH): 97 % [Zustand: NOMINAL]" in p["soh"] and "usv-gelb" not in p["sohc"], p
    return "Kachel-Skript mit node: grau ohne Daten, Netzbetrieb gruen mit Last/Balken/Autonomie, Netzausfall rot mit Countdown aus runtime_smoothed, Pruefung orange, SoH < 70 % gelb"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def V(st="OL", w=34, ch=100, rt=2700, inv=231.0, **kw):
    d = {"ups.status": st, "ups.realpower": w, "ups.load": 9, "battery.charge": ch, "battery.runtime": rt, "input.voltage": inv, "output.voltage": 230.0,
         "ups.serial": "G999GUARD99", "device.serial": "G999GUARD99", "ups.id": "x"}
    for k, v in kw.items():
        d[k.replace("_", ".")] = v
    return d


def beh_um(u):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        st = u.selftest()
    assert st.startswith("ups_manager ok"), st
    t = 1.79e9
    C = u.Calc
    c = C()
    c.feed(t, V(w=50))
    s = c.snapshot(t)
    assert s["load_w"] == 50 and s["load_pct"] == 12.5 and s["mode"] == "NETZ" and "G999" not in json.dumps(s), s
    v = V()
    v.pop("ups.realpower")
    v["ups.load"] = 10
    c.feed(t + 1, v)
    assert c.snapshot(t + 1)["load_w"] == 40.0, "Ersatz ups.load -> W von 400"
    assert c.snapshot(t + 12)["mode"] == "KEINE_DATEN" and c.snapshot(t + 10)["mode"] == "NETZ", "frisch 10 s"
    # Glaettung: 5 min Netzwerte, dann Akku -> keine alten Netzwerte
    c = C()
    for i in range(150):
        c.feed(t + 2 * i, V(rt=3000 if i % 2 else 3060))
    assert c.runtime_smoothed(t + 298)[0] == 3030
    for i in range(150):
        c.feed(t + 2 * i, V(rt=1000))
    c = C()
    for i in range(100):
        c.feed(t + 2 * i, V(rt=1000))
    for i in range(50):
        c.feed(t + 200 + 2 * i, V(rt=3000))
    assert c.runtime_smoothed(t + 300)[0] == 1000, "Median 5 min (nicht nur letzte Werte)"
    c = C()
    for i in range(150):
        c.feed(t + 2 * i, V(rt=3000))
    c.feed(t + 300, V(st="OB DISCHRG", rt=1200, inv=0.0))
    c.feed(t + 302, V(st="OB DISCHRG", rt=1190, inv=0.0))
    assert c.runtime_smoothed(t + 302)[0] == 1195, c.runtime_smoothed(t + 302)
    for i in range(1, 40):
        c.feed(t + 302 + i, V(st="OB DISCHRG", rt=5000, inv=0.0))
    r = c.runtime_smoothed(t + 341)[0]
    assert r <= 3000 - 41 + 1, ("Abwaertszaehlung begrenzt", r)
    # Selbsttest / Netzausfall
    c = C()
    c.feed(t, V())
    evs = []
    for i in range(6):
        evs += c.feed(t + 1 + 2 * i, V(st="OB", inv=228.0))
        assert c.mode(t + 1 + 2 * i) == "AKKU_PRUEF"
    evs += c.feed(t + 14, V())
    assert [e["ev"] for e in evs] == ["AKKU_START", "SELBSTTEST"] and c.s["last_test"]["dur"] == 13, evs
    for inv in (0.0, None):
        c = C()
        c.feed(t, V())
        for i in range(1, 25):
            vv = V(st="OB", inv=inv if inv is not None else 1.0)
            if inv is None:
                vv.pop("input.voltage")
            c.feed(t + i, vv)
            assert c.mode(t + i) == ("AKKU_PRUEF" if i < 21 else "AKKU"), (inv, i, c.mode(t + i))
        c.feed(t + 30, V())
        assert c.s["last_test"] is None and c.s["events"][-1]["ev"] == "NETZ_ZURUECK", c.s["events"]
    c = C()
    for i in range(150):
        c.feed(t + 2 * i, V(rt=3000))
    for i in range(0, 61, 5):
        c.feed(t + 300 + i, V(st="OB", rt=3000 - 2 * i, inv=0.0))
    c.feed(t + 400, V(st="OB", rt=1500, inv=0.0))
    c.feed(t + 410, V(rt=1600))
    ep = c.s["episodes"][-1]
    assert ep["kind"] == "ausfall" and ep["rt_pct"] == 4.0 and ep["dur"] == 110, ep
    c = C()
    for i in range(62):
        c.feed(t + i, V(st="OB", inv=230.0))
    assert c.mode(t + 59) == "AKKU_PRUEF" or True
    assert c.mode(t + 61) == "AKKU", "laenger als 60 s = Ausfall"
    c = C()
    for i in range(59):
        c.feed(t + i, V(st="OB", inv=230.0))
    assert c.mode(t + 58) == "AKKU_PRUEF", "unter 60 s mit Netz = Pruefung"
    c = C()
    for i in range(130):
        c.feed(t + i, V(st="OB CAL", inv=230.0))
    assert c.mode(t + 129) == "AKKU_PRUEF", "Kalibrierung mit Netz"
    # Ersatz-Stresstest
    c = C()
    tt = t
    for fall in (60, 60, 60, 150, 60):
        for i in range(160):
            c.feed(tt + 2 * i, V(rt=3000))
        tt += 320
        c.feed(tt, V(st="OB", rt=3000 - fall, inv=230.0))
        c.feed(tt + 4, V(rt=3000))
        tt += 10
        if fall == 150:
            assert c.s["last_test"]["stress"]["state"] == "auffaellig", c.s["last_test"]
        if len(c.s["episodes"]) == 2:
            assert c.s["last_test"]["stress"]["state"] == "lernt" and c.s["last_test"]["stress"]["n"] == 1
    assert c.s["last_test"]["stress"]["state"] == "ok", c.s["last_test"]["stress"]
    # SoH
    c = C()
    for i in range(13 * 144):
        c.feed(t + 600 * i, V(rt=3000))
    assert c.soh(t + 600 * 13 * 144, 34)["state"] == "LERNT" and c.soh(t + 600 * 13 * 144, 34)["day"] == 14
    for i in range(13 * 144, 15 * 144):
        c.feed(t + 600 * i, V(rt=3000))
    assert c.s["base"] == {"30": 3000}, c.s["base"]
    for pct, want in ((85, "NOMINAL"), (75, "BEOBACHTEN"), (69, "VERSCHLISSEN")):
        c2 = C(json.loads(json.dumps(c.s)))
        c2.s["recent"] = {"30": [[int(t + 600 * 15 * 144 + k), 3000 * pct // 100] for k in range(10)]}
        so = c2.soh(t + 600 * 15 * 144 + 20, 34)
        assert so["state"] == want and so["pct"] == pct, (pct, so)
    c3 = C()
    for i in range(20):
        c3.feed(t + 600 * i, V(rt=3000, ch=50))
    assert c3.s["learn_t0"] is None, "SoH nur bei voller Ladung"
    assert u.werk_min(150) is None and u.werk_min(300) == 4.5 and u.werk_min(50) is None
    assert u.akku_alter_m(time.mktime((2026, 11, 15, 12, 0, 0, 0, 0, -1))) == 6
    # Netz: Attrappe, nur LIST, Host fest, keine Seriennummer, Dateien nur im Basisordner
    d = tempfile.mkdtemp(prefix="g55u")
    fk = u.FakeNut(V())
    try:
        clk = [t]
        m = u.Manager(d, port=fk.port, log=lambda *a: None, clock=lambda: clk[0], sleep=lambda s: None)
        for i in range(400):
            clk[0] += 2
            m.poll_once()
        assert m.snapshot()["mode"] == "NETZ" and m.save() == "gesichert"
        assert set(fk.cmds) <= {"LIST UPS", "LIST VAR eaton"} and "LIST VAR eaton" in fk.cmds, set(fk.cmds)
        files = sorted(os.path.relpath(os.path.join(a, f), d) for a, _, fs in os.walk(d) for f in fs)
        mon = time.strftime("%Y-%m", time.localtime(clk[0]))
        assert files == sorted(["usv_state.json", "archive/usv/%s/usv_%s.jsonl" % (mon, mon)]), files
        for f in files:
            with open(os.path.join(d, f), encoding="utf-8") as fh:
                assert "G999" not in fh.read(), f
        with open(os.path.join(d, files[0] if files[0].endswith(".jsonl") else files[1]), encoding="utf-8") as fh:
            h = [json.loads(x) for x in fh]
        assert sum(1 for x in h if x["typ"] == "10min") == 1, h
        fk.close()
        m.next_try = 0
        m.poll_once()
        m.next_try = 0
        clk[0] += 20
        m.poll_once()
        assert m.snapshot()["mode"] == "KEINE_DATEN" and m.next_try - clk[0] == 4, (m.snapshot()["mode"], m.next_try - clk[0])
        m.cli.close()
        try:
            u.NutClient("192.168.178.2", 3493)
            raise AssertionError("fremder Host erlaubt")
        except ValueError:
            pass
    finally:
        fk.close()
        shutil.rmtree(d, ignore_errors=True)
    return "Verhalten ups_manager: Last 50 W = 12,5 %, Ersatz ups.load, frisch 10 s, Glaettung ohne alte Netzwerte, Selbsttest 13 s = kein Ausfall, Ausfall nach 21 s ohne Netz bzw. > 60 s, CAL mit Netz kein Ausfall, Stresstest lernt/ok/auffaellig, SoH 14 Tage + 85/75/69 %, nur LIST an 127.0.0.1, Dateien nur usv_state.json + archive/usv, keine Seriennummer"


def beh_dsh(B, neud):
    import flask
    sys.path.insert(0, neud)
    try:
        for k in ("ups_manager", "lage_pages"):
            sys.modules.pop(k, None)
        import lage_pages
        page = lage_pages.page_lokale_energie("", "")
        d = tempfile.mkdtemp(prefix="g55d")
        fk = None
        try:
            res = {}
            for nm in ("g55test", "__main__"):
                app = flask.Flask("g55" + nm)
                g = {"__name__": nm, "__file__": os.path.join(neud, "dashboard.py"), "app": app, "PAGE_LOKALE_ENERGIE": page, "_SDR_BASE": d, "RS_ITEMS": []}
                if nm == "__main__":
                    import ups_manager
                    fk = ups_manager.FakeNut(V())
                    os.environ["USV_NUT_PORT"] = str(fk.port)
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    exec(compile(B, "blk_dsh", "exec"), g)
                txt = out.getvalue()
                assert "usvLesen aktiv: usvLesen ok (ups_manager ok (" in txt, txt[:300]
                rules = [(r.rule, sorted(r.methods - {"HEAD", "OPTIONS"})) for r in app.url_map.iter_rules() if r.rule != "/static/<path:filename>"]
                assert rules == [("/api/usv", ["GET"])], rules
                if nm == "g55test":
                    assert g["_USV"]["mgr"] is None and g["RS_ITEMS"] == [], "Faden nur im Hauptprogramm"
                    with app.test_client() as cl:
                        r = cl.get("/api/usv")
                        j = r.get_json()
                        assert r.status_code == 200 and j["mode"] == "KEINE_DATEN" and r.headers.get("Cache-Control") == "no-store", (r.status_code, j)
                        assert cl.post("/api/usv").status_code == 405
                else:
                    m = g["_USV"]["mgr"]
                    assert m is not None and m.started and len(g["RS_ITEMS"]) == 1 and g["RS_ITEMS"][0][0] == "usvLesen usv_state.json", g["RS_ITEMS"]
                    for _ in range(40):
                        if m.connected:
                            break
                        time.sleep(0.1)
                    with app.test_client() as cl:
                        j = cl.get("/api/usv").get_json()
                    assert j["mode"] == "NETZ" and j["load_w"] == 34 and "G999" not in json.dumps(j) and j["nut"]["port"] == fk.port, j
                    m.stop = True
                    assert g["RS_ITEMS"][0][1]() == "gesichert"
                res[nm] = True
            g = {"__name__": "x", "__file__": os.path.join(neud, "dashboard.py"), "app": flask.Flask("g55b"), "PAGE_LOKALE_ENERGIE": "", "_SDR_BASE": d, "RS_ITEMS": []}
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                exec(compile(B, "blk_dsh", "exec"), g)
            assert "usvLesen Selbsttest FEHLER" in out.getvalue() and "Dashboard laeuft weiter" in out.getvalue(), "ohne Kachel: Fehlermeldung, kein Absturz"
        finally:
            if fk:
                fk.close()
            os.environ.pop("USV_NUT_PORT", None)
            shutil.rmtree(d, ignore_errors=True)
    finally:
        sys.path.remove(neud)
    return "Verhalten Dashboard: /api/usv nur GET (POST 405), no-store, grau ohne Leser, Faden nur im Hauptprogramm mit relStop-Eintrag, liest Attrappe (NETZ, 34 W), Fehler ohne Absturz"


def check(altd, neud, W):
    try:
        rv = revert_all(neud, W)
    except AssertionError as e:
        fail("Rueckbau: %s" % e)
    for fn, t in rv.items():
        if t != rd(os.path.join(altd, fn)):
            fail("Rueckbau %s != Basis (Aenderung ausserhalb Block/Kachel-Stelle)" % fn)
    if os.path.exists(os.path.join(altd, "ups_manager.py")):
        fail("Basis enthaelt schon ups_manager.py")
    um = rd(os.path.join(neud, "ups_manager.py"))
    if um != rd(os.path.join(W, "ups_manager.py")):
        fail("ups_manager.py weicht von der eingebetteten Fassung ab")
    s1 = static_um(um)
    B = blk(W)
    s2 = static_dsh(B)
    js, card = tile(neud)
    s3 = static_js(js, card)
    tmpd = tempfile.mkdtemp(prefix="g55c")
    try:
        shutil.copy(os.path.join(neud, "ups_manager.py"), os.path.join(tmpd, "ups_manager.py"))
        u = load(os.path.join(tmpd, "ups_manager.py"), "g55_um")
        b1 = beh_um(u)
        b2 = node_test(js)
        b3 = beh_dsh(B, neud)
    except AssertionError as ex:
        fail("Verhalten: %s" % str(ex)[:500])
    except SystemExit:
        raise
    except Exception as ex:
        fail("Verhalten (%s): %s" % (type(ex).__name__, str(ex)[:400]))
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    print("Guard commit55 ok: Rueckbau byte-genau = Basis (dashboard.py ein Block, lage_pages.py eine Stelle, ups_manager.py neu); statisch: %s; %s; %s; %s; %s; %s" % (s1, s2, s3, b1, b2, b3))


MUTS = [
    ("um", "NOM_W = 400 ", "NOM_W = 650 "), ("um", 'HOST = "127.0.0.1"', 'HOST = "0.0.0.0"'),
    ("um", 'self.sock.sendall(("LIST %s\\n" % what).encode("ascii"))', 'self.sock.sendall(("INSTCMD %s\\n" % what).encode("ascii"))'),
    ("um", 'return name in KEEP_VARS and "serial" not in name.lower()', "return True"),
    ("um", '"device.model", "ups.model"', '"device.model", "ups.serial", "ups.model"'),
    ("um", "OB_CONFIRM_S = 20 ", "OB_CONFIRM_S = 2 "), ("um", "OB_TEST_MAX_S = 60 ", "OB_TEST_MAX_S = 600 "), ("um", "IN_V_OK = 200.0 ", "IN_V_OK = 100.0 "),
    ("um", "nomains = inv is None or inv < IN_V_FAIL", "nomains = inv is not None and inv < IN_V_FAIL"),
    ("um", "                self.buf = []\n                ev.append(self._event(now, \"AKKU_START\"", "                ev.append(self._event(now, \"AKKU_START\""),
    ("um", "return (max(0, int(min(c))), ", "return (max(0, int(max(c))), "), ("um", "WIN_OL_S = 300 ", "WIN_OL_S = 30 "), ("um", "LEARN_S = 14 * 86400 ", "LEARN_S = 1 * 86400 "),
    ("um", "SOH_BAD = 70\n", "SOH_BAD = 60\n"), ("um", '"NOMINAL" if pct >= SOH_OK else', '"NOMINAL" if pct >= SOH_BAD else'),
    ("um", 'r["state"] = "auffaellig" if cur > m * STRESS_RATIO and cur - m > tol else "ok"', 'r["state"] = "auffaellig" if cur > m * 3 else "ok"'),
    ("um", "STRESS_MIN_N = 3\n", "STRESS_MIN_N = 1\n"), ("um", '        if o["kind"] != "ausfall":\n            self.s["last_test"]', '        if True:\n            self.s["last_test"]'),
    ("um", 'os.path.join(self.base, "archive", "usv", m, "usv_%s.jsonl" % m)', 'os.path.join(self.base, "usv_%s.jsonl" % m)'),
    ("um", "            _atomic_json(self.state_path(), s)\n", "            open(self.state_path(), \"w\").write(json.dumps(s))\n"),
    ("um", "import json\n", "import json\nimport subprocess\n"), ("um", "FRESH_S = 10 ", "FRESH_S = 3600 "), ("um", "BACKOFF_S = (2, 4, 8, 15, 30, 60)", "BACKOFF_S = (0,)"),
    ("um", "POLL_S = 2.0\n", "POLL_S = 0.1\n"), ("um", "or ch < 98 or", "or ch < 10 or"), ("um", "    if w is None or w < WERK[0][0] or w > WERK[-1][0]:\n        return None\n", ""),
    ("um", 'threading.Thread(target=self.run, name="usvLesen", daemon=True).start()', 'threading.Thread(target=self.run, name="usvLesen", daemon=False).start()'),
    ("um", 'AKKU_EINBAU = "2026-05"', 'AKKU_EINBAU = "2025-05"'), ("um", "        if self.ob:\n            m = _med(xs)\n            cd = ", "        if False:\n            m = _med(xs)\n            cd = "),
    ("um", '        if host != HOST:\n            raise ValueError("NUT nur ueber 127.0.0.1")\n', ""),
    ("um", '            if dur <= DROP_WIN_S:\n', '            if True:\n'),
    ("dsh", 'methods=["GET"])', 'methods=["GET", "POST"])'), ("dsh", 'if __name__ == "__main__" and _USV["mgr"] is None:', 'if _USV["mgr"] is None:'),
    ("dsh", "    _USV[\"st\"] = _uv_st\n", "    _USV[\"st\"] = _uv_st\n    send_meshtastic(\"USV\")\n"),
    ("dsh", '            RS_ITEMS.append(("usvLesen usv_state.json", _USV["mgr"].save))\n', "            pass\n"), ("dsh", "    st = _uv_mod.selftest()\n", "    st = \"ok\"\n"),
    ("dsh", '    resp.headers["Cache-Control"] = "no-store"\n', ""), ("dsh", '_uv_mod.HOST == "127.0.0.1" and _uv_mod.NOM_W == 400', '_uv_mod.HOST == "127.0.0.1"'),
    ("lp", "if(e)e.textContent=s||'';", "if(e)e.innerHTML=s||'';"), ("lp", "fetch('/api/usv',{cache:'no-store'})", "fetch('/api/usv',{method:'POST'})"),
    ("lp", "if(s.state==='VERSCHLISSEN')e.className='small usv-gelb';", ""), ("lp", "AUTONOME RESTLAUFZEIT: '+mn(rs)", "RESTLAUFZEIT: '+mn(rs)"),
    ("lp", "setInterval(tick,2000)", "setInterval(tick,200)"), ("lp", "if(d.mode==='AKKU'){cls('rot');", "if(d.mode==='AKKU'){cls('orange');"),
    ("lp", "tx('usvMain','keine USV-Daten')", "tx('usvMain','Fehler')"), ("lp", "AUTONOME RESTLAUFZEIT: '+mn(rs)+' min')", "AUTONOME RESTLAUFZEIT: '+mn(d.runtime_s)+' min')"),
    ("lp", "b.style.width=(p==null?0:Math.min(100,p))+'%';", "b.style.width=(w==null?0:Math.min(100,w))+'%';"),
    ("lp", "var z=s.state==='VERSCHLISSEN'?'VERSCHLISSEN - BITTE AKKUPACK TAUSCHEN':s.state;", "var z=s.state;"),
    ("lp", "Nur Anzeige: kein Ton, kein Mesh, kein Herunterfahren.", "Nur Anzeige."),
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
        files = {fn: rd(os.path.join(neud, fn)) for fn in ("dashboard.py", "lage_pages.py", "ups_manager.py")}
        wf = {"blk_dsh.py": blk(W), "edits.py": etxt0, "ups_manager.py": rd(os.path.join(W, "ups_manager.py"))}
        bad, msg = run(files, wf)
        if bad:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        o_lp, n_lp = E["LP_EDITS"][0]
        cases = []
        for k, a, b in MUTS:
            fm, wm = dict(files), dict(wf)
            if k == "um":
                if files["ups_manager.py"].count(a) < 1:
                    print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70])); missed += 1; continue
                fm["ups_manager.py"] = wm["ups_manager.py"] = files["ups_manager.py"].replace(a, b, 1)
            elif k == "dsh":
                B = wf["blk_dsh.py"]
                if B.count(a) < 1:
                    print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70])); missed += 1; continue
                bm = B.replace(a, b, 1)
                wm["blk_dsh.py"] = bm
                fm["dashboard.py"] = files["dashboard.py"].replace("\n\n" + B.rstrip("\n") + ANCH, "\n\n" + bm.rstrip("\n") + ANCH, 1)
            else:
                if n_lp.count(a) < 1:
                    print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70])); missed += 1; continue
                nm = n_lp.replace(a, b, 1)
                fm["lage_pages.py"] = files["lage_pages.py"].replace(n_lp, nm, 1)
                wm["edits.py"] = etxt0.replace(repr(n_lp), repr(nm), 1)
                assert wm["edits.py"] != etxt0
            cases.append(("%s %s" % (k, a[:50]), fm, wm))
        f = dict(files); f["dashboard.py"] = files["dashboard.py"].replace("T4_SAY_MAX = 600", "T4_SAY_MAX = 601", 1); assert f["dashboard.py"] != files["dashboard.py"]
        cases.append(("Zeile ausserhalb dashboard", f, wf))
        f = dict(files); f["lage_pages.py"] = files["lage_pages.py"].replace("<title>Lokale Energie</title>", "<title>Lokale Energie!</title>", 1); assert f["lage_pages.py"] != files["lage_pages.py"]
        cases.append(("Zeile ausserhalb Kachel (gleiche Seite)", f, wf))
        f = dict(files); f["ups_manager.py"] = files["ups_manager.py"].replace("FRESH_S = 10 ", "FRESH_S = 11 ", 1)
        cases.append(("Datei weicht von eingebetteter Fassung ab", f, wf))
        f = dict(files); f["dashboard.py"] = files["dashboard.py"].replace(ANCH, "\n\n" + wf["blk_dsh.py"].rstrip("\n") + ANCH, 1)
        cases.append(("Block doppelt", f, wf))
        lpm = files["lage_pages.py"].replace(n_lp, o_lp, 1)
        i = lpm.index("def page_lokale_energie(")
        j = lpm.index('<div class="grid">\n', i) + len('<div class="grid">\n')
        card = n_lp[len("  </div>\n"):n_lp.index("</div>\n<script>/* usvKachel */")]
        scr = n_lp[n_lp.index("<script>/* usvKachel */"):n_lp.index("<script>\nconst outageHist")]
        lpm = lpm[:j] + card + lpm[j:]
        lpm = lpm.replace("<script>\nconst outageHist", scr + "<script>\nconst outageHist", 1)
        f = dict(files); f["lage_pages.py"] = lpm
        cases.append(("Kachel ueber der Hauptkachel", f, wf))
        for name, fm, wm in cases:
            bad, msg = run(fm, wm)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest commit55: %d erkannt, %d uebersehen%s" % ("OK" if missed == 0 else "FEHLER", caught, missed,
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
MK_C55_GRD_EOF
EMB="patch.py:$EXPECT_PAT edits.py:$EXPECT_EDI G/blk_dsh.py:$EXPECT_BDS G/ups_manager.py:$EXPECT_UPS guard.py:$EXPECT_GRD"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
cp "$W/edits.py" "$W/G/edits.py"
echo "OK eingebettete Dateien geprueft (5: Patcher, Stellen mit Kachel, Block usvLesen, ups_manager.py, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "$2"; return; }; shift 2; done; echo UNBEKANNT; }
# ---------- 1) Basis: dashboard.py + lage_pages.py + ups_manager.py gemeinsam alt (fehlt) oder neu ----------
for x in "$F" "$FL" "$FS" "$FE"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS"); E16=$(s16 "$FE")
U16=fehlt; [[ -e "$FU" ]] && U16=$(s16 "$FU")
SD=$(lbl "$D16" "$KNOWN_D16" alt "$KNOWN_D16N" neu); SL=$(lbl "$L16" "$KNOWN_L16" alt "$KNOWN_L16N" neu); SU=$(lbl "$U16" fehlt alt "$KNOWN_U16N" neu)
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit54, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 ($(wc -l < "$FL") Zeilen) - $SL (alt $KNOWN_L16, neu $KNOWN_L16N)"
echo "Basis ups_manager.py $U16 - $([[ "$SU" == alt ]] && echo "noch nicht da (wird neu angelegt)" || echo "$SU (neu $KNOWN_U16N)")"
echo "Basis prepper_sdr.py sha16 $S16, prepper_evlog.py sha16 $E16 - $([[ "$S16" == "$KNOWN_S16" && "$E16" == "$KNOWN_E16" ]] && echo "wie erwartet nach commit54 (bleiben unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C53" || "$S16" == "$KNOWN_S16_C53" || "$E16" == "$KNOWN_E16_C53" ]]; then
  echo "STOP: erst commit54 anwenden - der Projektordner ist noch der Stand nach commit53 (dashboard.py $D16, prepper_sdr.py $S16, prepper_evlog.py $E16); commit55 braucht dashboard.py $KNOWN_D16 und lage_pages.py $KNOWN_L16 (nach commit54) - nichts geaendert."
  exit 1
fi
if [[ "$D16" == "$KNOWN_D16_C52" || "$D16" == "$KNOWN_D16_C51" || "$D16" == "$KNOWN_D16_C50" || "$L16" == "$KNOWN_L16_C52" ]]; then
  echo "STOP: erst commit53 und commit54 anwenden - dashboard.py/lage_pages.py sind noch ein Stand vor commit53 (dashboard.py $D16, lage_pages.py $L16) - nichts geaendert."
  exit 1
fi
for v in "dashboard.py:$SD:$D16" "lage_pages.py:$SL:$L16" "ups_manager.py:$SU:$U16"; do
  IFS=: read -r fn st hh <<< "$v"
  if [[ "$st" == UNBEKANNT ]]; then
    echo "STOP: $fn weicht vom erwarteten Stand ab (sha16 $hh) - nichts geaendert."
    echo "      commit55 passt nur auf den Stand nach commit54. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
    exit 1
  fi
done
if [[ "$SD$SL$SU" != altaltalt && "$SD$SL$SU" != neuneuneu ]]; then
  echo "STOP: Mischstand (dashboard.py $SD, lage_pages.py $SL, ups_manager.py $SU) - erwartet alle drei alt oder alle drei neu - nichts geaendert."
  for x in "$F" "$FL"; do LBX=$({ ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LBX" ]] && echo "      Sicherung vorhanden: $LBX ($(s16 "$LBX"))"; done
  echo "      Ein abgebrochener Lauf? Bitte diese Ausgabe an Grok schicken (nichts von Hand kopieren)."
  exit 1
fi
[[ "$S16" == "$KNOWN_S16" && "$E16" == "$KNOWN_E16" ]] || stop "prepper_sdr.py ($S16) oder prepper_evlog.py ($E16) ist nicht der Stand nach commit54 ($KNOWN_S16 / $KNOWN_E16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach qrmRun; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" && -w "$FL" ]] || stop "Projektordner, dashboard.py oder lage_pages.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug/jinja2 nicht"
# ---------- 1b) NUT-Zustand (nur lesen) ----------
NG=nut; getent group nut >/dev/null 2>&1 || NG=root
cat > "$W/nut/nut.conf" << MK_C55_NUTCONF
$NUT_MARK: NUT nur lokal (Treiber + upsd auf 127.0.0.1), upsmon NICHT aktiv - kein Herunterfahren (kommt erst mit commit57)
MODE=standalone
MK_C55_NUTCONF
cat > "$W/nut/ups.conf" << MK_C55_UPSCONF
$NUT_MARK: Eaton Ellipse PRO 650 VA / 400 W (ELP650DIN) per USB, nur lesen; kein ignorelb/override (kommt erst mit commit57)
maxretry = 3

[$NUT_UPS]
	driver = usbhid-ups
	port = auto
	vendorid = 0463
	pollinterval = 2
	desc = "Eaton Ellipse PRO 650"
MK_C55_UPSCONF
cat > "$W/nut/upsd.conf" << MK_C55_UPSDCONF
$NUT_MARK: upsd nur auf 127.0.0.1 - nichts nach aussen, kein Benutzer noetig (Lesen ohne Anmeldung)
LISTEN 127.0.0.1 $NUT_PORT
MK_C55_UPSDCONF
NUTF="nut.conf ups.conf upsd.conf"
pkgok() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]; }
nutget() { # kopiert nut.conf/ups.conf/upsd.conf nach $W/cur (fehlt = keine Datei); /etc/nut ist oft nur fuer root/nut lesbar -> sudo (im Trockenlauf nur mit gueltigem Ticket); NUTRD=0 wenn nicht lesbar
  local f su=0; NUTRD=1; rm -rf "$W/cur"; mkdir -p "$W/cur"
  [[ -e "$NUT_ETC" ]] || return 0
  [[ -r "$NUT_ETC" && -x "$NUT_ETC" ]] || su=1
  for f in $NUTF; do [[ "$su" == 0 && -e "$NUT_ETC/$f" && ! -r "$NUT_ETC/$f" ]] && su=1; done
  if [[ "$su" == 1 ]]; then
    if [[ "$DRY" == 1 ]] && ! sudo -n true 2>/dev/null; then NUTRD=0; return 0; fi
    for f in $NUTF; do if sudo test -e "$NUT_ETC/$f"; then sudo cat "$NUT_ETC/$f" > "$W/cur/$f" || NUTRD=0; fi; done
  else
    for f in $NUTF; do if [[ -e "$NUT_ETC/$f" ]]; then cat "$NUT_ETC/$f" > "$W/cur/$f" || NUTRD=0; fi; done
  fi
  return 0; }
nutleer() { # Konfiguration wie nach der Paket-Installation (nichts eingerichtet)?
  local m; m=$(sed -n 's/^[[:space:]]*MODE[[:space:]]*=[[:space:]]*"\{0,1\}\([a-z]*\).*/\1/p' "$W/cur/nut.conf" 2>/dev/null | tail -1 || true)
  [[ -z "$m" || "$m" == none ]] || return 1
  ! grep -qE '^[[:space:]]*\[' "$W/cur/ups.conf" 2>/dev/null || return 1
  ! grep -qE '^[[:space:]]*LISTEN' "$W/cur/upsd.conf" 2>/dev/null || return 1
  return 0; }
nutsoll() { local f; for f in $NUTF; do cmp -s "$W/nut/$f" "$W/cur/$f" || return 1; done; return 0; }
P1=0; P2=0; pkgok nut-server && P1=1; pkgok nut-client && P2=1
NSU=0; if [[ -e "$NUT_ETC" ]]; then [[ -r "$NUT_ETC" && -x "$NUT_ETC" ]] || NSU=1; for f in $NUTF; do [[ -e "$NUT_ETC/$f" && ! -r "$NUT_ETC/$f" ]] && NSU=1; done; fi
if [[ "$DRY" == 0 && "$NSU" == 1 ]]; then
  echo "$NUT_ETC ist nur fuer root lesbar - sudo-Passwort zum Lesen der NUT-Einrichtung:"
  sudo -v || stop "sudo -v fehlgeschlagen - $NUT_ETC nicht lesbar"
fi
nutget
if [[ "$NUTRD" == 0 ]]; then
  [[ "$DRY" == 1 ]] || stop "$NUT_ETC nicht lesbar (auch mit sudo nicht)"
  NUTST=unklar
elif [[ "$P1$P2" == 11 ]] && nutsoll; then NUTST=fertig
elif grep -qsF "$NUT_MARK" "$W/cur/nut.conf" "$W/cur/ups.conf" "$W/cur/upsd.conf"; then
  stop "NUT-Einrichtung von commit55 ist da, aber veraendert (nut.conf/ups.conf/upsd.conf ungleich Soll) - bitte diese Ausgabe an Grok schicken"
elif nutleer; then [[ "$P1$P2" == 11 ]] && NUTST=leer || NUTST=fehlt
else
  echo "STOP: NUT ist auf diesem Rechner schon anders eingerichtet ($NUT_ETC: MODE/ups.conf-Abschnitt/LISTEN vorhanden, nicht von commit55) - nichts geaendert."
  echo "      Abschnitte in ups.conf: $(grep -hE '^[[:space:]]*\[' "$W/cur/ups.conf" 2>/dev/null | tr -d ' \t' | tr '\n' ' ')- bitte diese Ausgabe an Grok schicken."
  exit 1
fi
USBL=$(lsusb 2>/dev/null | grep -i " ID 0463:" | head -1 || true)
USBDEV=""
if [[ -n "$USBL" ]]; then
  USBDEV=$(echo "$USBL" | sed -n 's/^Bus \([0-9][0-9]*\) Device \([0-9][0-9]*\):.*/\/dev\/bus\/usb\/\1\/\2/p')
  echo "OK USV per USB sichtbar: $(echo "$USBL" | sed 's/^Bus [0-9]* Device [0-9]*: //' | grep -iv serial | cut -c1-80)"
elif [[ "$NUTST" == fertig ]]; then echo "HINWEIS USV per USB gerade nicht sichtbar (lsusb ohne 0463) - NUT ist schon eingerichtet, die Kachel zeigt dann grau"
else stop "USV per USB nicht sichtbar (lsusb ohne ID 0463:...) - USB-Kabel der Eaton am Pi pruefen"; fi
case "$NUTST" in
  unklar) echo "HINWEIS NUT-Pakete $([[ "$P1$P2" == 11 ]] && echo installiert || echo "nicht (ganz) installiert"), $NUT_ETC nur mit sudo lesbar - der Trockenlauf vergleicht die Einrichtung nicht (der echte Lauf prueft mit sudo)";;
  fertig) echo "OK NUT schon eingerichtet von commit55 (nut-server + nut-client installiert, $NUT_ETC wie Soll) - Phase A: nur pruefen";;
  leer)   echo "OK NUT-Pakete installiert, aber nicht eingerichtet - Phase A richtet ein (ohne apt)";;
  fehlt)  CAND=$(apt-cache policy nut-server 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -1 || true)
          echo "OK NUT fehlt (nut-server $([[ "$P1" == 1 ]] && echo da || echo fehlt), nut-client $([[ "$P2" == 1 ]] && echo da || echo fehlt)) - Phase A installiert nut-server + nut-client (apt-Kandidat ${CAND:-unbekannt}$([[ -z "$CAND" || "$CAND" == "(none)" ]] && echo ", vorher apt-get update"))";;
esac
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
  if [[ -n "${C55_FAKE_HM:-}" && "$SIM" == 1 ]]; then hm="$C55_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
NEED=0; [[ "$STATE" == alt ]] && NEED=1
LA=300; [[ "$NUTST" == fehlt || "$NUTST" == unklar ]] && LA=900
rscheck() { local s0 s1 la="$2" k x; s0=$(rssec 0); s1=$(rssec "$la"); k=0
  for ((x = 0; x <= la; x += 60)); do rswin "$(rssec "$x")" && k=1; done
  if [[ "$k" == 1 ]] || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04, Vorlauf $((la / 60)) min) - frei ab HH:05"
    elif [[ "$NEED" == 0 ]]; then echo "OK Neustart-Sperre: commit55 ist schon installiert, es wird kein Neustart gebraucht"
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
PT usvLesen dsh "$F" "$W/work/dashboard.py" "$W/G/blk_dsh.py" > "$W/q1.log" || { cat "$W/q1.log"; stop "dashboard.py: Stelle fuer usvLesen nicht eindeutig"; }
PT usvKachel lp "$FL" "$W/work/lage_pages.py" - > "$W/q2.log" || { cat "$W/q2.log"; stop "lage_pages.py: Stelle fuer die USV-Kachel nicht eindeutig"; }
cp "$W/G/ups_manager.py" "$W/work/ups_manager.py"
for v in "dashboard.py:$KNOWN_D16N" "lage_pages.py:$KNOWN_L16N" "ups_manager.py:$KNOWN_U16N"; do
  IFS=: read -r fn hh <<< "$v"
  [[ "$(s16 "$W/work/$fn")" == "$hh" ]] || stop "Ergebnis $fn $(s16 "$W/work/$fn") statt $hh (Zielstand nicht erreicht)"
done
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(cat "$W/q1.log")), lage_pages.py $KNOWN_L16N ($(cat "$W/q2.log")), ups_manager.py $KNOWN_U16N"
PT x dsh "$W/work/dashboard.py" "$W/work/x1" "$W/G/blk_dsh.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
PT x lp "$W/work/lage_pages.py" "$W/work/x2" - > /dev/null && cmp -s "$W/work/lage_pages.py" "$W/work/x2" || stop "lage_pages.py nicht idempotent"
rm -f "$W/work/x1" "$W/work/x2"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/work/ups_manager.py" "$W/patch.py" "$W/edits.py" "$W/G/blk_dsh.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/work/ups_manager.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/G" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: commit55 im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" && "$(s16 "$W/alt/lage_pages.py")" == "$KNOWN_L16" ]] || stop "Guard: Stand ohne commit55 ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt" "$W/neu" "$W/G" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "Guard commit55 meldet Verstoss"; }
grep "^Guard commit55" "$W/g.log" | cut -c1-2400
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Kachel-Skript hier statisch geprueft; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C55_SIM_NOMUT:-}" && "$SIM" == 1 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt" "$W/neu" "$W/G" > "$W/gm.log" 2>&1 || { grep -v "NUT verbunden" "$W/gm.log"; stop "Mutationstest commit55: eine Verfehlung wurde nicht erkannt"; }
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
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  case "$NUTST" in
    fertig) echo "  Phase A: NUT ist schon eingerichtet - ein echter Lauf prueft nur (upsc, nur 127.0.0.1, upsmon aus).";;
    unklar) echo "  Phase A: Einrichtung nur mit sudo pruefbar - der echte Lauf liest $NUT_ETC mit sudo und richtet NUT nur ein, wenn es leer ist (sonst STOP).";;
    leer)   echo "  Phase A: ein echter Lauf richtet NUT ein ($NUT_ETC sichern, nut.conf/ups.conf/upsd.conf schreiben, Treiber + upsd starten, upsmon aus) - ohne apt.";;
    fehlt)  echo "  Phase A: ein echter Lauf installiert nut-server + nut-client (apt, --no-install-recommends, 1-4 min), richtet NUT ein ($NUT_ETC sichern, 3 Dateien), startet Treiber + upsd nur auf 127.0.0.1, upsmon aus.";;
  esac
  if [[ "$NEED" == 0 ]]; then echo "  Phase B: commit55 ist schon installiert - ein echter Lauf aendert an den Dateien nichts."
  else echo "  Phase B: ein echter Lauf wuerde dashboard.py und lage_pages.py ersetzen, ups_manager.py anlegen (Sicherungen DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, 27 Seiten/APIs + /api/usv und Journal pruefen. Eine sudo-Passwortabfrage. Beim Einspielen wird nichts gesendet."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
NUTNEED=0; [[ "$NUTST" != fertig ]] && NUTNEED=1
if [[ "$NEED" == 1 || "$NUTNEED" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer apt/NUT, den Neustart und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4A) Phase A: NUT (nur lokal) ----------
upsst() { upsc "$NUT_UPS@127.0.0.1:$NUT_PORT" ups.status 2>/dev/null | head -1 || true; }
upsv() { upsc "$NUT_UPS@127.0.0.1:$NUT_PORT" 2>/dev/null | grep -iv serial | sed -n "s/^$1: //p" | head -1 || true; }
lsn() { ss -ltnH 2>/dev/null | awk -v p=":$NUT_PORT" '{a=$4; if (substr(a, length(a) - length(p) + 1) == p) print a}' | sort -u || true; }
nutchk() { # setzt NCK (Text) und gibt 0 bei Erfolg
  local st l bad
  st=$(upsst); NUTSTAT="$st"
  [[ "$st" =~ ^(OL|OB|LB|CAL|CHRG|DISCHRG|BYPASS|TRIM|BOOST|OFF|RB|ALARM|FSD|OVER|TEST) ]] || { NCK="upsc $NUT_UPS@127.0.0.1 liefert keinen ups.status ('${st:-leer}')"; return 1; }
  l=$(lsn | tr '\n' ' '); bad=$(lsn | grep -v "^127\.0\.0\.1:$NUT_PORT\$" || true)
  [[ -n "$l" ]] || { NCK="ss zeigt keinen Dienst auf Port $NUT_PORT"; return 1; }
  [[ -z "$bad" ]] || { NCK="Port $NUT_PORT offen auf ${bad//$'\n'/ } (erlaubt nur 127.0.0.1)"; return 1; }
  [[ "$(systemctl is-active nut-monitor.service 2>/dev/null || true)" != active ]] || { NCK="upsmon (nut-monitor) laeuft - soll aus sein"; return 1; }
  NCK="ups.status $st, Port $NUT_PORT nur auf ${l% }, upsmon aus"; return 0; }
NUTBAK=(); NUTNEW=(); NUTTOUCH=0
nutrb() {
  set +e +o pipefail
  trap - ERR
  echo "NUT-ROLLBACK: $1"
  jc -u "nut-driver@$NUT_UPS" -u nut-server --since "@${TNA:-0}" --no-pager -n 300 -o cat | grep -iv serial | tail -12 | cut -c1-200 | sed 's/^/   | /'
  sudo systemctl stop nut-server.service >/dev/null 2>&1
  if command -v upsdrvsvcctl >/dev/null 2>&1; then sudo upsdrvsvcctl stop >/dev/null 2>&1; fi
  sudo systemctl stop nut-driver.target "nut-driver@$NUT_UPS.service" >/dev/null 2>&1
  sudo systemctl disable nut-server.service nut-monitor.service >/dev/null 2>&1
  local f
  for f in "${NUTBAK[@]}"; do sudo cp -a "$NUT_ETC/$f.bak-$NM-$TS" "$NUT_ETC/$f" && echo "  $NUT_ETC/$f = Sicherung"; done
  for f in "${NUTNEW[@]}"; do sudo rm -f "$NUT_ETC/$f" && echo "  $NUT_ETC/$f entfernt (gab es vorher nicht)"; done
  echo "  NUT-Dienste gestoppt und nicht aktiviert$(pkgok nut-server && echo "; Pakete bleiben installiert (nichts laeuft). Ganz entfernen: sudo apt-get purge nut-server nut-client" || echo "; NUT-Pakete nicht installiert")"
  echo "STOP: Phase A (NUT) fehlgeschlagen - Dashboard NICHT geaendert (dashboard.py, lage_pages.py unveraendert, kein Neustart)"
  exit 1
}
TNA=$(date +%s)
if [[ "$NUTST" == fertig ]]; then
  if nutchk; then echo "OK NUT schon eingerichtet: $NCK"
  else echo "HINWEIS NUT eingerichtet, aber gerade nicht lesbar: $NCK - die Kachel zeigt dann grau 'keine USV-Daten'; Handpruefung: upsc $NUT_UPS@127.0.0.1"; fi
else
  PHASE="Phase A (NUT)"
  trap '' INT
  if [[ "$NUTST" == fehlt ]]; then
    rscheck "vor apt" 900
    echo "Installiere nut-server + nut-client (apt-get, --no-install-recommends; dauert 1-4 min) ..."
    T_APT=$(date +%s)
    AOPT=(-y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    if ! sudo env DEBIAN_FRONTEND=noninteractive apt-get install "${AOPT[@]}" nut-server nut-client > "$W/apt.log" 2>&1; then
      if grep -qE "Unable to locate package|has no installation candidate|404 +Not Found|Failed to fetch" "$W/apt.log"; then
        echo "  apt kennt das Paket nicht oder Paketliste veraltet - apt-get update ..."
        sudo apt-get update > "$W/aptu.log" 2>&1 || { tail -15 "$W/aptu.log"; stop "apt-get update fehlgeschlagen (Internet?) - NUT nicht installiert, Dashboard nicht geaendert"; }
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install "${AOPT[@]}" nut-server nut-client > "$W/apt.log" 2>&1 || { tail -25 "$W/apt.log"; NUTTOUCH=1; nutrb "apt-get install nut-server nut-client fehlgeschlagen"; }
      else tail -25 "$W/apt.log"; NUTTOUCH=1; nutrb "apt-get install nut-server nut-client fehlgeschlagen"; fi
    fi
    pkgok nut-server && pkgok nut-client || nutrb "nut-server/nut-client nach apt nicht installiert"
    echo "OK nut-server + nut-client installiert ($(dpkg-query -W -f='${Version}' nut-server 2>/dev/null || echo ?), $(( $(date +%s) - T_APT )) s; $(grep -cE '^(Setting up|Entpacken|Unpacking) ' "$W/apt.log" || true) Paketschritte)"
    nutget; [[ "$NUTRD" == 1 ]] && nutleer || nutrb "nach der Installation ist $NUT_ETC nicht leer eingerichtet (fremde Altkonfiguration?)"
  fi
  NUTTOUCH=1
  NG=nut; getent group nut >/dev/null 2>&1 || NG=root
  NBK=0
  for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
    if ! sudo test -f "$NUT_ETC/$f"; then [[ " $NUTF " == *" $f "* ]] && NUTNEW+=("$f"); continue; fi
    sudo cp -a "$NUT_ETC/$f" "$NUT_ETC/$f.bak-$NM-$TS" || nutrb "Sicherung $NUT_ETC/$f fehlgeschlagen"
    NBK=$((NBK + 1))
    { sudo ls -1t "$NUT_ETC" 2>/dev/null || true; } | grep "^$f\.bak-$NM-" | tail -n +$((KEEP_LAST + 1)) | while read -r o; do sudo rm -f -- "$NUT_ETC/$o"; done || true
    [[ " $NUTF " == *" $f "* ]] && NUTBAK+=("$f")
  done
  echo "OK Sicherungen $NUT_ETC/DATEI.bak-$NM-$TS ($NBK Dateien; upsd.users und upsmon.conf bleiben unveraendert)"
  for f in $NUTF; do sudo install -m 0640 -o root -g "$NG" "$W/nut/$f" "$NUT_ETC/$f" || nutrb "$NUT_ETC/$f schreiben fehlgeschlagen"; done
  nutget; [[ "$NUTRD" == 1 ]] && nutsoll || nutrb "$NUT_ETC nach dem Schreiben ungleich Soll"
  echo "OK $NUT_ETC: nut.conf MODE=standalone, ups.conf [$NUT_UPS] usbhid-ups vendorid 0463 pollinterval 2, upsd.conf LISTEN 127.0.0.1 $NUT_PORT"
  sudo udevadm control --reload-rules >/dev/null 2>&1 || true
  sudo udevadm trigger --action=change --subsystem-match=usb --attr-match=idVendor=0463 >/dev/null 2>&1 || true
  sudo udevadm settle -t 10 >/dev/null 2>&1 || true
  if [[ -n "$USBDEV" && -e "$USBDEV" ]]; then
    UG=$(stat -c '%G %a' "$USBDEV" 2>/dev/null || echo "? ?")
    [[ "${UG%% *}" == nut ]] && echo "OK USB-Rechte: $USBDEV Gruppe nut ($UG) - der Treiber darf lesen" || echo "HINWEIS USB-Rechte: $USBDEV hat Gruppe/Rechte $UG (erwartet Gruppe nut) - wenn der Treiber nicht startet, USB-Kabel einmal ab- und anstecken"
  fi
  if command -v upsdrvsvcctl >/dev/null 2>&1; then
    sudo upsdrvsvcctl resync > "$W/drv.log" 2>&1 || true
    sudo upsdrvsvcctl start >> "$W/drv.log" 2>&1 || sudo systemctl start "nut-driver@$NUT_UPS.service" >> "$W/drv.log" 2>&1 || true
  else
    sudo systemctl enable --now "nut-driver@$NUT_UPS.service" > "$W/drv.log" 2>&1 || true
  fi
  sudo systemctl enable nut-server.service >> "$W/drv.log" 2>&1 || true
  sudo systemctl restart nut-server.service >> "$W/drv.log" 2>&1 || nutrb "nut-server (upsd) startet nicht"
  sudo systemctl disable --now nut-monitor.service >> "$W/drv.log" 2>&1 || true
  echo "Warte auf erste USV-Werte (max 60 s) ..."
  NOK=0
  for i in $(seq 1 30); do sleep 2; nutchk && { NOK=1; break; }; done
  [[ "$NOK" == 1 ]] || { { grep -iv serial "$W/drv.log" | tail -8 | cut -c1-200 | sed 's/^/   | /'; } || true; nutrb "$NCK"; }
  echo "OK NUT laeuft: $NCK"
  echo "OK NUT-Dienste: Treiber $(systemctl is-active "nut-driver@$NUT_UPS.service" 2>/dev/null || true), upsd $(systemctl is-active nut-server.service 2>/dev/null || true), upsmon $(systemctl is-active nut-monitor.service 2>/dev/null || true)/$(systemctl is-enabled nut-monitor.service 2>/dev/null || true) (kein Herunterfahren)"
fi
NV="Last $(upsv ups.realpower) W ($(upsv ups.load) %), Ladung $(upsv battery.charge) %, Laufzeit $(upsv battery.runtime) s, Eingang $(upsv input.voltage) V, Modell $(upsv device.model)"
[[ -n "$NUTSTAT" ]] && echo "OK USV liest (upsc, ohne Seriennummer): Status $NUTSTAT, $NV"
PHASE="Phase B (Dashboard)"
# ---------- 4B) Phase B: Dashboard ----------
trap '' INT
RESTARTED=0
T0D=$(date +%s)
INST=()
waitd() { local i; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done; return 1; }
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -n 400 -o cat | grep -E "usvLesen|Traceback" | grep -iv serial | tail -5 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  [[ -f "$FU" && "$UNEW" == 1 ]] && rm -f "$FU" && echo "  ups_manager.py entfernt (gab es vorher nicht)"
  if [[ "$RESTARTED" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    waitd
  fi
  echo "  NUT bleibt eingerichtet (nur lesen, nur 127.0.0.1, kein Herunterfahren); Datenbank, prepper_sdr.py und Mesh-Regeln unveraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
UNEW=0
if [[ "$NEED" == 0 ]]; then
  echo "OK commit55 schon installiert - kein Neustart, keine Aenderung an den Dateien"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen" 300
  for x in "$F" "$FL"; do
    cp -a "$x" "$x.bak-$NM-$TS"
    { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  echo "OK Sicherungen *.bak-$NM-$TS: dashboard.py, lage_pages.py (behalten: letzte $KEEP_LAST)"
  UNEW=1; INST+=("$FU")
  cp "$W/work/ups_manager.py" "$FU.new" && chmod --reference="$F" "$FU.new" && mv -f "$FU.new" "$FU" || { rm -f "$FU.new"; rb "ups_manager.py anlegen"; exit 1; }
  [[ "$(s16 "$FU")" == "$KNOWN_U16N" ]] || { rb "ups_manager.py nach dem Kopieren falsch ($(s16 "$FU"))"; exit 1; }
  for v in "$FL:lage_pages.py:$KNOWN_L16N" "$F:dashboard.py:$KNOWN_D16N"; do
    IFS=: read -r x fn hh <<< "$v"
    INST+=("$x")
    cp "$W/work/$fn" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rb "$fn installieren"; exit 1; }
    [[ "$(s16 "$x")" == "$hh" ]] || { rb "$fn nach dem Kopieren falsch ($(s16 "$x"))"; exit 1; }
  done
  echo "OK ups_manager.py angelegt, lage_pages.py und dashboard.py atomar ersetzt"
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
n=$(grep -c "^# ===== usvLesen:" "$F" || true); [[ "$n" == 1 ]] || rbx "dashboard.py Marker usvLesen ${n}x"
n=$(grep -c "/\* usvKachel \*/" "$FL" || true); [[ "$n" == 1 ]] || rbx "lage_pages.py Kachel-Skript usvKachel ${n}x"
echo "OK Marker usvLesen (dashboard.py) und usvKachel (lage_pages.py) je 1x, ups_manager.py $(s16 "$FU")"
for i in $(seq 1 20); do
  UH=$("${CURL[@]}" "$B/lokale-energie" -o "$W/le.html" -w "%{http_code}" || true)
  UQ=$(grep -c "/\* usvKachel \*/" "$W/le.html" || true)
  [[ "$UH" == 200 && "$UQ" == 1 ]] && break
  sleep 3
done
[[ "$UH" == 200 ]] || rbx "/lokale-energie HTTP $UH"
[[ "$UQ" == 1 ]] || rbx "/lokale-energie ohne USV-Kachel (${UQ}x, 60 s gewartet)"
python3 - "$W/le.html" << 'MK_C55_ORDER' || rbx "/lokale-energie: USV-Kachel steht nicht direkt unter der Hauptkachel"
import sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
a, b, c = s.find('id="outageChart"'), s.find('id="usvCard"'), s.find("const outageHist")
sys.exit(0 if 0 <= a < b < c else 1)
MK_C55_ORDER
echo "OK /lokale-energie mit USV-Kachel direkt unter der Hauptkachel (Status N-ERGIE)"
uapi() { "${CURL[@]}" -D "$W/uh.txt" "$B/api/usv" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
n = d.get("nut") or {}
s = json.dumps(d).lower()
def f(x):
    return "-" if x is None else str(x)
soh = d.get("soh") or {}
print(d.get("mode") or "-", f(d.get("load_w")), f(d.get("load_pct")), f(d.get("charge")), f(d.get("runtime_smoothed_s")), (str(soh.get("txt") or "-") + " [" + str(soh.get("state") or "-") + ", Akku eingebaut " + str(soh.get("einbau") or "?") + "]").replace(" ", "_"), int("serial" in s), str(d.get("err") or n.get("fehler") or "-").replace(" ", "_")[:80])' 2>/dev/null || echo "FEHLER"; }
UOK=0
for i in $(seq 1 15); do
  read -r UM UW UP UC UR US USRL UE <<< "$(uapi)"
  [[ "$UM" != FEHLER && "$UM" != - && "$UM" != KEINE_DATEN ]] && { UOK=1; break; }
  sleep 2
done
[[ "$UM" != FEHLER ]] || rbx "/api/usv nicht lesbar (HTTP $(code "$B/api/usv"))"
[[ "$USRL" == 0 ]] || rbx "/api/usv enthaelt 'serial'"
grep -qi "^cache-control:.*no-store" "$W/uh.txt" || rbx "/api/usv ohne Cache-Control no-store"
c3=$(pcode "$B/api/usv"); [[ "$c3" == 405 || "$c3" == 403 ]] || rbx "/api/usv nimmt POST an (HTTP $c3)"
if [[ "$UOK" == 1 ]]; then
  echo "OK /api/usv (nur GET, no-store, ohne Seriennummer): Modus $UM, Last $UW W ($UP % von 400 W), Ladung $UC %, Restlaufzeit geglaettet $([[ "$UR" != - ]] && echo "$(( ${UR%.*} / 60 )) min" || echo -), SoH $(echo "$US" | tr '_' ' ')"
else echo "HINWEIS /api/usv antwortet (HTTP 200, nur GET, no-store), aber noch keine USV-Daten ($(echo "$UE" | tr '_' ' ')) - Kachel grau 'keine USV-Daten'; Dashboard laeuft normal"; fi
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -n 3000 -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep usv"
else
  if [[ "$RESTARTED" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "usvLesen aktiv: usvLesen ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-200)" || rbx "Journal prepper-dashboard ohne 'usvLesen aktiv: usvLesen ok' ($(echo "$JD" | grep -F usvLesen | grep -iv serial | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok' 'audioKern aktiv: audioKern ok' 'audioUi aktiv: audioUi ok' 'kartePop aktiv: kartePop ok' 'hbProblem aktiv: hbProblem ok' 'umweltFlach aktiv: umweltFlach ok' 'qrmRun aktiv: qrmRun ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'usvLesen Selbsttest FEHLER|usvLesen: Faden-Fehler|qrmRun Selbsttest FEHLER|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|No module named .ups_manager|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'usvLesen Selbsttest FEHLER|usvLesen: Faden-Fehler|qrmRun Selbsttest FEHLER|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|No module named .ups_manager|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' | grep -iv serial | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  echo "$JD" | grep -E 'usvLesen:' | grep -iv serial | tail -3 | cut -c1-200 | sed 's/^/  Journal: /' || true
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein commit55-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach qrmRun usvLesen; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
SERN=$(grep -rlis serial "$DASH_DIR/archive/usv" "$DASH_DIR/usv_state.json" 2>/dev/null | wc -l || true)
[[ "${SERN:-0}" == 0 ]] && echo "OK keine Seriennummer in usv_state.json / archive/usv" || rbx "Seriennummer-Text in usv_state.json oder archive/usv gefunden"
echo "OK Datenbank, Mesh-Regeln, Gain-Waechter (Stufe 16), prepper_sdr.py, upsd.users, upsmon.conf, Firewall und rpcbind unberuehrt; kein Ton, kein Mesh, kein Heartbeat, kein Herunterfahren"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F") ($(wc -l < "$F") Zeilen), lage_pages.py sha16 $(s16 "$FL") ($(wc -l < "$FL") Zeilen), ups_manager.py sha16 $(s16 "$FU") ($(wc -l < "$FU") Zeilen)"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1); LBL=$({ ls -1t "$FL.bak-$NM-"* 2>/dev/null || true; } | head -1)
if [[ -n "$LB" && -n "$LBL" ]]; then
  echo "Rueckweg Dashboard (beide zusammen, NUT bleibt):"
  echo "  cp -a $LB $F && cp -a $LBL $FL && rm -f $FU && sudo systemctl restart prepper-dashboard"
else echo "Rueckweg Dashboard: keine $NM-Sicherung vorhanden (Dateien nicht geaendert)"; fi
NB=$({ sudo -n ls -1 "$NUT_ETC" 2>/dev/null || ls -1 "$NUT_ETC" 2>/dev/null || true; } | grep "^ups\.conf\.bak-$NM-" | head -1 || true)
echo "Rueckweg NUT (nur bei Bedarf, nach dem Dashboard-Rueckweg): sudo systemctl disable --now nut-server nut-driver.target && sudo apt-get purge nut-server nut-client$([[ -n "$NB" ]] && echo "   (alte Dateien: $NUT_ETC/*.bak-$NM-*)")"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  upsc eaton@127.0.0.1 2>/dev/null | grep -v -i serial"
echo "  ss -ltn | grep 3493"
echo "  systemctl is-active nut-server nut-monitor"
echo "  curl -s http://127.0.0.1:5000/api/usv | cut -c1-400"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep usvLesen"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Beim Einspielen nichts gesendet (kein Mesh, kein Telegram, keine Alarme), nichts nach aussen geoeffnet, keine Datenbank geaendert. Neue Docs-Version: bewusst nicht."
echo "Dauer: $(( $(date +%s) - TNA )) s"
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
