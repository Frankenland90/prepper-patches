#!/bin/bash
set -eEuo pipefail
# mapUi (commit31b): Kartenseite /karte: Linien 4-6 px nach SNR mit dunklem Rand (eigene Ebene unter allen Linien), 'Unbekannte TII-Traeger anzeigen (N)' einklappbar (Zustand bleibt beim Neuzeichnen), kompakter Status-Ticker (11D Bayern / 5C Bund bzw. 10C Rueckfall / Statistik). Nur Frontend-JS/CSS in dashboard.py (_KV_JS, CSS in _kv_karte, kleiner Selbsttest-Block), Backend/Daten/Routen unveraendert.
# Aufruf: bash /tmp/apply-mapui.sh commit31b [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 3a933125227fb89b (Stand nach dbVis commit31) oder mapUi schon drin (9cb49ceab0243cc4); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-mapui-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/mapui-apply
KEEP_LAST=3
KNOWN_D16="3a933125227fb89b"      # dashboard.py vor mapUi (Basis: Stand nach dbVis commit31)
KNOWN_D16N="9cb49ceab0243cc4"             # dashboard.py nach mapUi (Ziel)
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
echo "=== mapUi apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Karte: Linien, Details, Ticker, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="51f8b96962b1041a1659f0b574c4ca0525afe1b7cf7c5096dcca5ab4d8ea9a7d"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher mapUi. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
MK_PAL_EOF
EXPECT_RAE="57bdc003d3a97ff03956d02a96749377914bcadb2226975696c8653dc477c08b"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer mapUi (commit31b): nur Seite /karte (kartevec: _KV_JS und das CSS in _kv_karte), Basis 3a933125227fb89b (Stand nach dbVis commit31)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    ('.t4-tri{color:#f97316;font-size:20px;line-height:22px;text-align:center;text-shadow:0 0 3px #000}\n</style></head><body>\n<div class="kv-h">',
     '.t4-tri{color:#f97316;font-size:20px;line-height:22px;text-align:center;text-shadow:0 0 3px #000}\n.kv-pulse-o{animation:kvpo 1.4s ease-in-out infinite}\n@keyframes kvpo{0%{stroke-width:6px}50%{stroke-width:13px}100%{stroke-width:6px}}\n.kv-tick{border-collapse:collapse;width:100%;margin-bottom:6px}.kv-tick th,.kv-tick td{padding:3px 8px;border-bottom:1px solid #334155;text-align:left;vertical-align:top;font-weight:400}.kv-tick th{white-space:nowrap;font-weight:700;width:1%}\n#kvUnk summary{cursor:pointer;color:#94a3b8}\n</style></head><body>\n<div class="kv-h">'),
    ("var CC={'11D':'#7dd3fc','5C':'#ef4444','10C':'#f97316'},GREY='#94a3b8',BLUE='#3b82f6';\nfunction cls(l,on){var e=l&&l.getElement?l.getElement():(l&&l._path);if(!e)return;if(on){if(e.classList)e.classList.add('kv-pulse');}else if(e.classList)e.classList.remove('kv-pulse');}",
     "var CC={'11D':'#7dd3fc','5C':'#ef4444','10C':'#f97316'},GREY='#94a3b8',BLUE='#3b82f6',OUTC='#0b1220';\nfunction cls(l,on,c){c=c||'kv-pulse';var e=l&&l.getElement?l.getElement():(l&&l._path);if(!e)return;if(on){if(e.classList)e.classList.add(c);}else if(e.classList)e.classList.remove(c);}\n/* mapUi: Linienbreite 4..6 px nach SNR des Kanals (0..25 dB geklemmt, ungueltig/ohne SNR = 4 px); reine Funktion, Rand = Breite + 3 */\nfunction kvW(snr){var s=+snr;if(!(s>=0))s=0;if(s>25)s=25;return Math.round((4+2*s/25)*10)/10;}\nvar LO={},UNK=false,FAIL=0;"),
    ('draw();zones();}\nfunction pop(m)',
     'draw();zones();legend();}\nfunction pop(m)'),
    ("function load(){fetch('/api/t4/tii',{credentials:'same-origin',cache:'no-store'}).then(function(r){return r.json();}).then(function(j){if(j&&j.masts){V=j;draw();}}).catch(function(){});}",
     "function load(){fetch('/api/t4/tii',{credentials:'same-origin',cache:'no-store'}).then(function(r){return r.json();}).then(function(j){if(j&&j.masts){V=j;FAIL=0;draw();}else{FAIL++;legend();}}).catch(function(){FAIL++;legend();});}"),
    ('.setView([h.lat,h.lon],8);\nvar blank=',
     ".setView([h.lat,h.lon],8);map.createPane('kvOut');map.getPane('kvOut').style.zIndex=399;\nvar blank="),
    ('ZL=L.layerGroup().addTo(map);\n',
     "ZL=L.layerGroup().addTo(map);var lgx=document.getElementById('kvLeg');if(lgx)lgx.addEventListener('toggle',function(e){var t=e.target;if(t&&t.id==='kvUnk')UNK=!!t.open;},true);\n"),
    ("var q=c.q==null?0.15:Math.max(0.15,c.q),ln=LL[key];\nif(!ln){ln=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:false}).addTo(map);LL[key]=ln;if(mk.bringToFront)mk.bringToFront();}\nln.setStyle({color:CC[c.ch]||'#7dd3fc',weight:1+6*q,opacity:.3+.65*q});cls(ln,m.overreach);}})(ms[i]);}",
     "var q=c.q==null?0.15:Math.max(0.15,c.q),ln=LL[key],lo=LO[key],w=kvW(c.snr);\nif(!ln){lo=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:false,pane:'kvOut',color:OUTC,weight:w+3,opacity:.7,lineCap:'round'}).addTo(map);LO[key]=lo;ln=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:false}).addTo(map);LL[key]=ln;if(mk.bringToFront)mk.bringToFront();}\nif(lo){lo.setStyle({weight:w+3});cls(lo,m.overreach,'kv-pulse-o');}\nln.setStyle({color:CC[c.ch]||'#7dd3fc',weight:w,opacity:.75+.25*q});cls(ln,m.overreach);}})(ms[i]);}"),
    ('for(var k in LL){if(!lk[k]){map.removeLayer(LL[k]);delete LL[k];}}',
     'for(var k in LL){if(!lk[k]){map.removeLayer(LL[k]);delete LL[k];if(LO[k]){map.removeLayer(LO[k]);delete LO[k];}}}\nfor(var k in LO){if(!LL[k]){map.removeLayer(LO[k]);delete LO[k];}}'),
    ('function legend(){var lg=document.getElementById(\'kvLeg\');if(!lg||!V)return;var x=\'\',c11=(V.ch||{})[\'11D\']||{},na=0,ne=0;\nfor(var i=0;i<(V.masts||[]).length;i++){if(V.masts[i].active)na++;if(V.masts[i].ever)ne++;}\nvar kvn=function(cc,t){var a=(V.masts||[]).concat(V.nopos||[]);for(var i=0;i<a.length;i++){var cs=a[i].ch||[];for(var k=0;k<cs.length;k++){if(cs[k].ch===cc&&cs[k].tii_txt===t)return (a[i].name||\'unbekannt\')+\' · \'+t;}}return \'unbekannt · \'+t;};\nfor(var ch in (V.ch||{})){var c=V.ch[ch];if(!c.fig_t&&ch!==\'11D\')continue;x+=\'<div><b style="color:\'+(CC[ch]||GREY)+\'">\'+esc(ch)+\'</b>: \'+(c.stick_ok?\'\':\'<b style="color:#f97316">\'+esc(c.stick_why)+\'</b> · \')+\'letzte TII-Prüfung \'+(c.fig_t?ft(c.fig_t)+\' (vor \'+age(c.age_s)+\')\':\'–\')+(c.fresh?\'\':\' · älter als \'+V.active_s+\' s – keine Linie\')+\' · SNR \'+n(c.snr,1)+\' dB · TII \'+esc((c.tii||[]).map(function(t){return kvn(ch,t);}).join(\', \')||\'–\')+\'</div>\';}\nx+=\'<div>\'+na+\' Masten aktiv · \'+ne+\' schon empfangen · \'+(V.masts||[]).length+\' mit Position gezeichnet</div>\';\n',
     '/* mapUi: Status-Ticker als Tabelle mit drei Zeilen. Definitionen (nur aus den Daten von /api/t4/tii, nichts erfunden):\n   aktive Masten je Kanal = Masten, deren Kanal-Eintrag aktiv ist (letzte frische TII-Pruefung <= active_s, Stick laeuft, schon bestaetigt empfangen); ohne Position: schon empfangen und in der letzten frischen Pruefung des Kanals.\n   Namen aus MASTS_DB/Mastliste; Kennungen der letzten Pruefung ausserhalb der Liste als \'unbekannt - MM/SS\', noch nicht bestaetigte Masten als \'unbestaetigt\'.\n   X = Masten (Standorte) mit mindestens einem aktiven Kanal; Y = Sender (Standort x Kanal) schon empfangen (ever); Z = Sender (Standort x Kanal) in der Mastliste registriert (MASTS_DB + Teil 4).\n   Zweite Zeile: 5C Bund; faellt 5C aus (ohne frische Pruefung/Sync) und 10C hat frische Daten, heisst sie \'10C Lokal (Rueckfall)\'. Ohne Daten: \'keine Daten\'. */\nfunction tick(){var CH=(V&&V.ch)||{},al=((V&&V.masts)||[]).concat((V&&V.nopos)||[]);\nfunction row(cc,lab){var c=CH[cc]||{},th=\'<th style="color:\'+(CC[cc]||GREY)+\'">\'+esc(lab)+\'</th>\',why=(c.stick_ok===false&&c.stick_why)?\' · <b style="color:#f97316">\'+esc(c.stick_why)+\'</b>\':\'\';\nif(!c.fig_t)return \'<tr>\'+th+\'<td colspan="3">keine Daten\'+why+\'</td></tr>\';\nvar live=!!(c.fresh&&c.stick_ok),tl=c.tii||[],nm=[],un=[],kn={};\nfor(var i=0;i<al.length;i++){var cs=al[i].ch||[];for(var k=0;k<cs.length;k++){var q=cs[k];if(q.ch!==cc)continue;kn[q.tii_txt]=1;\nvar on=live&&(typeof al[i].lat===\'number\'?!!q.active:(!!q.ever&&tl.indexOf(q.tii_txt)>=0));\nif(on)nm.push(al[i].name||(\'unbekannt · \'+q.tii_txt));else if(live&&tl.indexOf(q.tii_txt)>=0)un.push((al[i].name||\'unbekannt\')+\' (\'+q.tii_txt+\')\');}}\nif(live)for(var j=0;j<tl.length;j++){if(!kn[tl[j]])un.push(\'unbekannt · \'+tl[j]);}\nreturn \'<tr>\'+th+\'<td>letzte Prüfung \'+ft(c.fig_t)+\' (vor \'+age(c.age_s)+\')\'+(c.fresh?\'\':\' · <span style="color:#fbbf24">älter als \'+esc(V&&V.active_s)+\' s – keine Linie</span>\')+why+\'</td><td>SNR \'+(c.snr==null?\'keine Daten\':n(c.snr,1)+\' dB\')+\'</td><td>Aktive Masten: \'+(nm.length?esc(nm.join(\', \')):\'keine\')+(un.length?\' <span style="opacity:.7">· unbestätigt: \'+esc(un.join(\', \'))+\'</span>\':\'\')+\'</td></tr>\';}\nvar c5=CH[\'5C\']||{},c10=CH[\'10C\']||{},fb=!!(!(c5.fresh&&c5.stick_ok)&&c10.fig_t&&c10.fresh&&c10.stick_ok),X=0,Y=0,Z=0;\nfor(var i=0;i<al.length;i++){if(al[i].active)X++;var cs=al[i].ch||[];for(var k=0;k<cs.length;k++){Z++;if(cs[k].ever)Y++;}}\nvar st=al.length?(X+\' Masten aktiv | \'+Y+\' Sender empfangen | \'+Z+\' in DB registriert\'):\'keine Daten\';\nreturn (FAIL>=3?\'<div style="color:#f97316">keine aktuellen Daten (Abruf schlägt fehl) – Anzeige kann veraltet sein</div>\':\'\')+\'<table class="kv-tick" id="kvTick">\'+row(\'11D\',\'11D Bayern\')+(fb?row(\'10C\',\'10C Lokal (Rückfall)\'):row(\'5C\',\'5C Bund\'))+\'<tr><th>Statistik</th><td colspan="3">\'+st+\'</td></tr></table>\';}\nfunction legend(){var lg=document.getElementById(\'kvLeg\');if(!lg)return;if(!V){var x0=tick();if(lg._x!==x0){lg._x=x0;lg.innerHTML=x0;}return;}var x=tick();\n'),
    ('x+=\'<div style="margin-top:4px"><b>Legende</b>: Linie = Mast in der letzten TII-Prüfung (≤ \'+V.active_s+\' s, Stick läuft) · Stärke/Deckkraft: <b>\'+esc(V.legend)+\'</b> (SNR 0–25 dB, je Mast abgeschwächt nach TII-Fehler) · ',
     'x+=\'<div style="margin-top:4px"><b>Legende</b> (\'+(V.masts||[]).length+\' Masten mit Position gezeichnet): Linie = Mast in der letzten TII-Prüfung (≤ \'+V.active_s+\' s, Stick läuft) · Breite 4–6 px nach SNR (0–25 dB) mit dunklem Rand, Deckkraft: <b>\'+esc(V.legend)+\'</b> (je Mast abgeschwächt nach TII-Fehler) · '),
    ('var uk=V.unknown||[];if(uk.length){x+=\'<div style="margin-top:4px"><b>TII nicht in MASTS_DB – nie gezeichnet</b>: \';for(var i=0;i<uk.length;i++){var u=uk[i];x+=(i?\' · \':\'\')+esc(u.ch)+\' unbekannt · \'+esc(u.tii_txt)+\' (\'+u.n+\'×, zuletzt \'+ft(u.last_t)+\', Fehler \'+n(u.last_err,0)+\')\';}x+=\'</div>\';}',
     'var uk=V.unknown||[];if(uk.length){x+=\'<details id="kvUnk"\'+(UNK?\' open\':\'\')+\' style="margin-top:4px"><summary>Unbekannte TII-Träger anzeigen (\'+uk.length+\')</summary><div><b>TII nicht in MASTS_DB – nie gezeichnet</b>: \';for(var i=0;i<uk.length;i++){var u=uk[i];x+=(i?\' · \':\'\')+esc(u.ch)+\' unbekannt · \'+esc(u.tii_txt)+\' (\'+u.n+\'×, zuletzt \'+ft(u.last_t)+\', Fehler \'+n(u.last_err,0)+\')\';}x+=\'</div></details>\';}'),
]
MK_RAE_EOF
EXPECT_RAB="d641037b24f20cbb80993bfd5cafb876b1085220dd7aa0853705233df0c12cc6"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== mapUi: Karte /karte - dickere Linien (4-6 px nach SNR) mit dunklem Rand, 'Unbekannte TII-Traeger' einklappbar, Status-Ticker (11D Bayern / 5C Bund bzw. 10C Rueckfall / Statistik); nur Frontend-JS/CSS der Karte (Stellen in _KV_JS und _kv_karte), Backend/Daten unveraendert; nur Lesen, sendet nichts =====
def _selftest_mapui():
    """Struktur des Karten-JS (kein Browser noetig): Rand-Linien-Ebene, Breitenfunktion, einklappbare Details mit gemerktem Zustand, Ticker."""
    js = _KV_JS
    for k in ("function kvW(snr)", "Math.round((4+2*s/25)*10)/10", "createPane('kvOut')", "zIndex=399", "pane:'kvOut'", "weight:w+3,opacity:.7", "kv-pulse-o",
              "delete LO[k]", '<details id="kvUnk"', "(UNK?' open':'')", "Unbekannte TII-Träger anzeigen (", "</summary>", "</details>", "addEventListener('toggle'",
              "function tick()", '<table class="kv-tick"', "11D Bayern", "5C Bund", "10C Lokal (Rückfall)", "Statistik", "in DB registriert", "keine Daten"):
        assert k in js, "Karten-JS ohne " + k
    assert js.count("<details") == 1 and js.count("</details>") == 1 and js.count("<summary>") == 1 and js.count("function tick()") == 1
    for k in ("setInterval(load,5000)", "removeLayer", "setStyle", "kv-pulse", "popupopen", "popupclose", "/api/t4/tii"):
        assert k in js, "Karten-JS ohne " + k
    assert "method:'POST'" not in js and "/send" not in js and "eval(" not in js
    assert js.count("fetch(") == 2 and js.count("innerHTML") == 2
    return "mapUi ok (Linien 4-6 px nach SNR mit dunklem Rand in eigener Ebene, Unbekannte TII-Traeger einklappbar, Status-Ticker 3 Zeilen)"


try:
    _MU_ST = _selftest_mapui()
    print("mapUi aktiv: %s" % _MU_ST, flush=True)
except Exception as _mu_e:
    print("mapUi Selbsttest FEHLER (%s)" % _mu_e, flush=True)
# ===== /mapUi =====
MK_RAB_EOF
EXPECT_RAG="73dbbc11b6930bfe7353736a815384faf4da6b330887435d134ef08f6523e1ae"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-/JS-Guard mapUi (nur dashboard.py: Stellen in _KV_JS und im CSS von _kv_karte + ein kleiner Block). Aufruf:
  guard_mu.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne mapUi (Rueckbau, byte-genau)
  guard_mu.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + JS-Strukturtests (immer, auch ohne node) + Ausfuehrung im node (nur wenn vorhanden)
  RH_ALT=ALT_VERZ guard_mu.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest
Auf der Pi gibt es kein node: die Struktur-/Rechentests (js_static, kvW-Uebersetzung) laufen immer; die Ausfuehrung im node nur wenn node da ist und RH_NO_NODE nicht 1 ist."""
import ast
import contextlib
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

ALLOWED_CHANGED = ("_KV_JS", "_kv_karte")
ALLOWED_PREFIX = ("_MU", "_mu_", "_selftest_mapui")


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block mapUi nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle mapUi nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def top_name(n):
    if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
        return n.name
    if isinstance(n, ast.Assign):
        return ",".join(t.id for t in n.targets if isinstance(t, ast.Name)) or "#assign"
    if isinstance(n, ast.Try):
        return "_MUG" if "_selftest_mapui()" in ast.unparse(n) else "#try"
    return "#" + type(n).__name__


def top_ok_new(nm):
    return nm == "_MUG" or nm.startswith(ALLOWED_PREFIX)


def get_js_css(src):
    t = ast.parse(src)
    js = css = None
    for n in t.body:
        if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id == "_KV_JS" for x in n.targets):
            js = n.value.value
        if isinstance(n, ast.FunctionDef) and n.name == "_kv_karte":
            for c in ast.walk(n):
                if isinstance(c, ast.Constant) and isinstance(c.value, str) and "<style>" in c.value:
                    css = c.value
    assert js and css, "_KV_JS oder CSS in _kv_karte nicht gefunden"
    return js, css


# ---------------- reine Funktion kvW: Uebersetzung aus dem JS-Text nach Python (ohne JavaScript-Maschine) ----------------
def kvw_py(js):
    m = re.search(r"function kvW\(snr\)\{([^{}]*)\}", js)
    assert m, "function kvW fehlt"
    stm = [x for x in m.group(1).split(";") if x != ""]
    lines = ["def f(snr):"]
    for s in stm:
        if s == "var s=+snr":
            lines.append("    s=_num(snr)")
        elif re.fullmatch(r"if\(!\(s>=0\)\)s=\d+", s):
            lines.append("    if not (s>=0): s=" + s.rsplit("=", 1)[1])
        elif re.fullmatch(r"if\(s>\d+\)s=\d+", s):
            lines.append("    if s>%s: s=%s" % (re.match(r"if\(s>(\d+)\)", s).group(1), s.rsplit("=", 1)[1]))
        elif re.fullmatch(r"return Math\.round\(\(\d+\+\d+\*s/\d+\)\*\d+\)/\d+", s):
            lines.append("    return " + s[len("return "):].replace("Math.round(", "_round("))
        else:
            raise AssertionError("kvW: unerlaubte Anweisung: " + s)

    def _num(v):
        if v is None:
            return 0.0
        if isinstance(v, bool):
            return float(v)
        if isinstance(v, str):
            try:
                return float(v)
            except Exception:
                return float("nan")
        return float(v)
    g = {"_num": _num, "_round": lambda x: float(math.floor(x + 0.5))}
    exec("\n".join(lines), g)
    return g["f"]


def kvw_table(f):
    for v, exp in ((None, 4.0), (-5, 4.0), (float("nan"), 4.0), ("abc", 4.0), (0, 4.0), (12.5, 5.0), (25, 6.0), (40, 6.0), (1e9, 6.0), (18.2, 5.5), (6.25, 4.5)):
        r = f(v)
        assert abs(r - exp) < 1e-9, "kvW(%r) = %r statt %r" % (v, r, exp)
    prev = 0
    for i in range(0, 61):
        r = f(i / 2.0)
        assert 4.0 <= r <= 6.0 and r >= prev, "kvW nicht monoton/in 4..6: %s -> %s" % (i / 2.0, r)
        prev = r


def balanced(js):
    """Klammern/Strings ausserhalb von Zeichenketten, Kommentaren und der einen Regex-Literal-Stelle muessen ausgeglichen sein."""
    s = js.replace("/[&<>\"]/g", "0")
    st, i, n = [], 0, len(s)
    pair = {")": "(", "]": "[", "}": "{"}
    while i < n:
        c = s[i]
        if c in "'\"":
            q = c
            i += 1
            while i < n and s[i] != q:
                assert s[i] != "\n", "Zeichenkette ueber Zeilenende bei %d" % i
                i += 2 if s[i] == "\\" else 1
            assert i < n, "Zeichenkette nicht geschlossen"
        elif c == "/" and s[i:i + 2] == "/*":
            j = s.index("*/", i + 2)
            i = j + 1
        elif c in "([{":
            st.append(c)
        elif c in ")]}":
            assert st and st.pop() == pair[c], "Klammer %s bei %d passt nicht" % (c, i)
        i += 1
    assert not st, "Klammern nicht geschlossen: %s" % st


def js_static(js, css):
    n = 0
    balanced(js)
    n += 1
    for k in ("function kvW(snr)", "createPane('kvOut')", "zIndex=399", "pane:'kvOut'", "color:OUTC", "weight:w+3", "opacity:.7", "lineCap:'round'", "interactive:false", "lo.setStyle({weight:w+3})",
              "cls(lo,m.overreach,'kv-pulse-o')", "LO[key]=lo", "delete LO[k]", "map.removeLayer(LO[k])", "OUTC='#0b1220'", "w=kvW(c.snr)", "weight:w,opacity:.75+.25*q",
              "function cls(l,on,c){c=c||'kv-pulse';", "{pulse}".replace("{pulse}", "kv-pulse")):
        assert k in js, "Karten-JS ohne " + k
    assert js.count("pane:'kvOut'") == 1 and js.count("L.polyline(") == 2 and js.count("zIndex=399") == 1, "genau zwei Linien (Rand + Hauptlinie), Rand in eigener Ebene"
    mo = re.search(r"\{interactive:false,pane:'kvOut',color:OUTC,weight:w\+3,opacity:\.7,lineCap:'round'\}", js)
    assert mo, "Rand-Linie: nicht interaktiv, dunkel, weight+3, opacity .7"
    assert "{interactive:false}).addTo(map);LL[key]=ln" in js, "Hauptlinie bleibt nicht interaktiv"
    assert js.index("lo=L.polyline(") < js.index("ln=L.polyline("), "Rand-Linie wird vor der Hauptlinie angelegt"
    # Aufraeumen: Rand-Linien verschwinden mit ihrer Hauptlinie und als Waisen (auch ohne node pruefbar)
    for k in ("for(var k in LL){if(!lk[k]){map.removeLayer(LL[k]);delete LL[k];if(LO[k]){map.removeLayer(LO[k]);delete LO[k];}}}", "for(var k in LO){if(!LL[k]){map.removeLayer(LO[k]);delete LO[k];}}",
              "fb=!!(!(c5.fresh&&c5.stick_ok)&&c10.fig_t&&c10.fresh&&c10.stick_ok)"):
        assert js.count(k) == 1, "Karten-JS: Aufraeum-/Rueckfallregel fehlt oder doppelt: " + k[:60]
    # Kernstellen der Logik (auch ohne node pruefbar): Neuzeichnen, Namen, Zaehlung X/Y/Z, Keine-Daten-Faelle, Ausfallzaehler
    for k in ("if(!ln){lo=L.polyline(", "if(on)nm.push(al[i].name||('unbekannt \u00b7 '+q.tii_txt))", "if(live)for(var j=0;j<tl.length;j++){if(!kn[tl[j]])un.push('unbekannt \u00b7 '+tl[j]);}",
              "if(al[i].active)X++;", "Z++;if(cs[k].ever)Y++;", "if(!c.fig_t)return '<tr>'+th+'<td colspan=\"3\">keine Daten'+why+'</td></tr>';",
              "(c.snr==null?'keine Daten':n(c.snr,1)+' dB')", ".catch(function(){FAIL++;legend();})", "V=j;FAIL=0;draw();"):
        assert js.count(k) == 1, "Karten-JS: Kernstelle fehlt oder doppelt: " + k[:70]
    # Farblogik der Hauptlinie unveraendert
    assert "color:CC[c.ch]||'#7dd3fc'" in js and "var CC={'11D':'#7dd3fc','5C':'#ef4444','10C':'#f97316'}" in js, "Farblogik 11D/5C/10C veraendert"
    f = kvw_py(js)
    kvw_table(f)
    n += 1
    # Details: Reihenfolge und Struktur
    m = re.search(r"x\+='<details id=\"kvUnk\"'\+\(UNK\?' open':''\)\+' style=\"margin-top:4px\"><summary>Unbekannte TII-Träger anzeigen \('\+uk\.length\+'\)</summary><div><b>TII nicht in MASTS_DB – nie gezeichnet</b>: ';(.*?)x\+='</div></details>';", js, re.S)
    assert m, "Details-Struktur (details/summary/div) nicht wie vorgesehen"
    body = m.group(1)
    for k in ("esc(u.ch)", "esc(u.tii_txt)", "u.n", "ft(u.last_t)", "n(u.last_err,0)", "zuletzt ", "Fehler "):
        assert k in body, "Inhalt der unbekannten TII-Traeger verkuerzt: " + k
    assert js.count("<details") == 1 and js.count("</details>") == 1 and js.count("<summary>") == 1 and js.count("</summary>") == 1
    assert "addEventListener('toggle',function(e){var t=e.target;if(t&&t.id==='kvUnk')UNK=!!t.open;},true)" in js, "Zustand offen/zu wird nicht gemerkt"
    assert "var LO={},UNK=false,FAIL=0;" in js, "Anfangszustand zu (UNK=false)"
    n += 1
    # Ticker: Tabelle, drei Zeilen, Ausfall
    assert js.count("function tick()") == 1 and js.count("function row(cc,lab)") == 1
    tk = js[js.index("function tick()"):js.index("function legend()")]
    assert tk.count("<table") == 1 and tk.count("</table>") == 1 and tk.count("<tr><th>Statistik</th>") == 1 and tk.count("row('") == 3, "Ticker: Tabelle mit drei Zeilen (11D, 5C/10C, Statistik)"
    for k in ("11D Bayern", "5C Bund", "10C Lokal (Rückfall)", "Statistik", " Masten aktiv | ", " Sender empfangen | ", " in DB registriert", "keine Daten", "unbekannt · ", "al[i].name"):
        assert k in tk, "Ticker ohne " + k
    for k in ("if(!V){var x0=tick();", "draw();zones();legend();}", "FAIL++;legend();", "FAIL>=3"):
        assert k in js, "Ausfall-Anzeige ohne " + k
    # Kommentar mit Definition von X/Y/Z
    assert "X = Masten (Standorte)" in js and "Y = Sender" in js and "Z = Sender" in js, "Definition von X/Y/Z fehlt im Code"
    n += 1
    # bestehendes Verhalten
    for k in ("setInterval(load,5000)", "setInterval(loadZ,30000)", "removeLayer", "setStyle", "popupopen", "popupclose", "/api/t4/tii", "/api/t4/map", "Schaetzung aus SNR/TII", "kein RSSI je Mast", "bringToFront"):
        assert k in js, "Karten-JS verliert " + k
    assert js.count("fetch(") == 2 and js.count("innerHTML") == 2 and "method:'POST'" not in js and "eval(" not in js and "/send" not in js and "XMLHttp" not in js, "Karten-JS: neue Netz-/Schreibzugriffe"
    for k in (".kv-pulse-o{animation:kvpo 1.4s ease-in-out infinite}", "@keyframes kvpo{0%{stroke-width:6px}50%{stroke-width:13px}100%{stroke-width:6px}}", ".kv-tick{", "#kvUnk summary{"):
        assert k in css, "CSS ohne " + k
    assert "@keyframes kvp{0%{stroke-opacity:1;stroke-width:3px}50%{stroke-opacity:.25;stroke-width:10px}100%{stroke-opacity:1;stroke-width:3px}}" in css, "bestehende Pulsanimation veraendert"
    n += 1
    return n


def static(alt, new, blk):
    n = 0
    ta, tn = ast.parse(alt), ast.parse(new)
    da = {ast.dump(x): top_name(x) for x in ta.body}
    dn = {ast.dump(x): top_name(x) for x in tn.body}
    gone = sorted(set(da[k] for k in da if k not in dn))
    assert set(gone) <= set(ALLOWED_CHANGED), "mapUi aendert/entfernt bestehende Stellen ausser _KV_JS/_kv_karte: %s" % gone
    names_new = {top_name(x) for x in tn.body}
    assert set(gone) <= names_new, "geaenderte Stelle fehlt im Zielstand"
    added = sorted(set(dn[k] for k in dn if k not in da and not top_ok_new(dn[k]) and dn[k] not in ALLOWED_CHANGED))
    assert not added, "mapUi fuegt ausserhalb des Blocks hinzu: %s" % added
    n += 1
    bt = rd(blk)
    for forb in ("requests", "urlopen", "subprocess", "os.system", "Popen", "socket", "sqlite3", "open(", "app.route", "add_url_rule", "after_request", "telegram", "systemctl", "send_meshtastic", "Thread", "sleep("):
        assert forb not in bt, "Block enthaelt %s" % forb
    assert not [c for c in ast.walk(ast.parse(bt)) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id in ("eval", "exec", "open", "__import__", "compile")], "Block ruft eval/exec/open"
    n += 1
    js, css = get_js_css(new)
    n += js_static(js, css)
    return n


# ---------------- Ausfuehrung im node (nur wenn vorhanden) ----------------
NODE_HARNESS = r"""
var fs=require('fs');var src=fs.readFileSync(process.argv[2],'utf8');var FAILS=0;
function ok(c,m){if(!c){console.log('FAIL '+m);FAILS++;}}
function mkEl(id){return {id:id,style:{},_l:{},textContent:'',_html:'',set innerHTML(v){this._html=v;},get innerHTML(){return this._html;},addEventListener:function(t,f,c){(this._l[t]=this._l[t]||[]).push([f,c]);}};}
function mkData(o){var d={home:{lat:49.5,lon:11.1,name:'H',h_m:400},active_s:150,legend:'Schaetzung aus SNR/TII',note:'n',src:'s',ever_run:2,
 masts:[{id:'a',name:'Bamberg',lat:49.8,lon:10.8,ever:true,active:true,overreach:false,dist_km:50,D_km:60,ch:[{ch:'11D',tii_txt:'08/18',active:true,ever:true,q:0.6,snr:18.2,last_t:1,n:3}]},
        {id:'b',name:'Nuernberg',lat:49.4,lon:11.0,ever:true,active:true,overreach:false,ch:[{ch:'5C',tii_txt:'05/14',active:true,ever:true,q:0.4,snr:3,n:5}]},
        {id:'c',name:'Hersbruck',lat:49.5,lon:11.4,ever:false,active:false,overreach:false,ch:[{ch:'10C',tii_txt:'01/02',active:false,ever:false,q:null,snr:null,n:0}]}],
 nopos:[{name:'Amberg',ever:true,active:true,ch:[{ch:'11D',tii_txt:'07/01',ever:true,n:1}]}],
 unknown:[{ch:'11D',tii_txt:'00/18',n:4,last_t:100,last_err:200,max_run:1}],
 ch:{'11D':{fig_t:1790000000,age_s:30,fresh:true,stick_ok:true,snr:18.2,tii:['08/18','07/01','00/18']},'5C':{fig_t:1790000000,age_s:40,fresh:true,stick_ok:true,snr:3,tii:['05/14']},'10C':{fig_t:null,fresh:false,stick_ok:true}}};
 for(var k in (o||{}))d[k]=o[k];return d;}
var DATA=mkData();var els={};
['kv-tiles','kv-data','kv-zones','kvInfo','kvLeg','kvmap'].forEach(function(i){els[i]=mkEl(i);});
els['kv-data'].textContent=process.argv[3]==='nodata'?'null':JSON.stringify(DATA);els['kv-zones'].textContent='null';els['kv-tiles'].textContent='{}';
global.document={getElementById:function(i){return els[i]||null;}};
var layers=[];function Layer(kind,opt){this.kind=kind;this.opt=opt||{};this.live=false;this.el={classList:{s:{},add:function(c){this.s[c]=1;},remove:function(c){delete this.s[c];}}};layers.push(this);}
Layer.prototype.addTo=function(m){this.live=true;m._l.push(this);this.pane=this.opt.pane||'overlay';return this;};
Layer.prototype.setStyle=function(o){for(var k in o)this.opt[k]=o[k];return this;};Layer.prototype.getElement=function(){return this.el;};
['bindPopup','setLatLng','setPopupContent','bringToFront','setRadius','on'].forEach(function(f){Layer.prototype[f]=function(){return this;};});
var panes={},MAP=null;
function Map(){this._l=[];MAP=this;}Map.prototype.setView=function(){return this;};Map.prototype.createPane=function(n){panes[n]={style:{}};};Map.prototype.getPane=function(n){return panes[n];};
Map.prototype.removeLayer=function(l){l.live=false;this._l=this._l.filter(function(x){return x!==l;});};Map.prototype.on=function(){};
global.L={map:function(){return new Map();},tileLayer:function(){return new Layer('tile');},layerGroup:function(){var g=new Layer('group');g.clearLayers=function(){};return g;},circleMarker:function(a,o){return new Layer('cm',o);},polyline:function(a,o){return new Layer('pl',o);},circle:function(a,o){return new Layer('c',o);},marker:function(){return new Layer('m');},geoJSON:function(){return new Layer('g');},divIcon:function(){return {};}};
var FETCH={},TIMERS=[];
function P(v){if(v&&v.__p)return v;return {__p:1,then:function(f){var r;try{r=f(v);}catch(e){return {__p:1,then:function(){return this;},catch:function(g){g(e);return P(undefined);}};}return P(r);},catch:function(){return this;}};}
global.fetch=function(u){var v=FETCH[u];if(v==='FAIL')return {__p:1,then:function(){return this;},catch:function(g){g(new Error('x'));return P(undefined);}};return P({json:function(){return P(v);}});};
global.setInterval=function(f,t){TIMERS.push([f,t]);};
eval(src);
function pls(){return layers.filter(function(l){return l.kind==='pl'&&l.live;});}
function outl(){return pls().filter(function(l){return l.opt.pane==='kvOut';});}
function mains(){return pls().filter(function(l){return l.opt.pane!=='kvOut';});}
function refresh(d){FETCH['/api/t4/tii']=d;TIMERS.filter(function(t){return t[1]===5000;})[0][0]();}
function lg(){return els.kvLeg.innerHTML;}
var nod=process.argv[3]==='nodata';
if(!nod){
 ok(panes.kvOut&&panes.kvOut.style.zIndex===399,'Ebene kvOut zIndex 399');
 ok(pls().length===4,'4 Linien (2 aktive Kanaele x Rand+Haupt), ist '+pls().length);
 var o=outl(),m=mains();ok(o.length===2&&m.length===2,'je aktivem Mast Rand und Hauptlinie');
 m.forEach(function(l){ok(l.opt.weight>=4&&l.opt.weight<=6,'Breite 4..6: '+l.opt.weight);ok(l.opt.opacity>=.75&&l.opt.opacity<=1,'Deckkraft '+l.opt.opacity);ok(l.opt.interactive===false,'Hauptlinie nicht interaktiv');});
 o.forEach(function(l){ok(l.opt.color==='#0b1220','Randfarbe dunkel');ok(l.opt.opacity===.7,'Rand-Deckkraft .7');ok(l.opt.interactive===false,'Rand nicht interaktiv');ok(l.pane==='kvOut','Rand in kvOut');});
 var w11=m.filter(function(l){return l.opt.color==='#7dd3fc';})[0],w5c=m.filter(function(l){return l.opt.color==='#ef4444';})[0];
 ok(!!w11&&!!w5c,'Farben 11D hellblau / 5C rot bleiben');
 ok(w11&&w11.opt.weight===5.5&&w5c&&w5c.opt.weight===4.2,'Breite nach SNR 18,2 dB -> 5,5 / 3 dB -> 4,2: '+(w11&&w11.opt.weight)+'/'+(w5c&&w5c.opt.weight));
 o.forEach(function(l){var mm=m.filter(function(x){return x.opt.color===(l.opt.weight===x.opt.weight+3?x.opt.color:'');})[0];ok(!!mm,'Rand = Breite+3 ('+l.opt.weight+')');});
 // Aufraeumen/Leaks: mehrfach gleiche Daten
 for(var i=0;i<6;i++)refresh(mkData());
 ok(pls().length===4&&MAP._l.filter(function(l){return l.kind==='pl';}).length===4,'keine Dubletten bei Refresh: '+pls().length);
 // Linie faellt weg: Rand und Haupt weg
 var d2=mkData();d2.masts[0].ch[0].active=false;d2.masts[0].active=false;refresh(d2);
 ok(pls().length===2&&outl().length===1&&mains().length===1,'Rand verschwindet mit der Linie: '+pls().length);
 refresh(mkData({masts:[]}));ok(pls().length===0&&layers.filter(function(l){return l.kind==='pl'&&l.live;}).length===0&&MAP._l.filter(function(l){return l.kind==='pl';}).length===0,'keine verwaisten Layer ohne aktive Linien');
 refresh(mkData());ok(pls().length===4,'Linien kommen zurueck');
 // Puls
 var d3=mkData();d3.masts[0].overreach=true;refresh(d3);
 var pm=mains().filter(function(l){return l.opt.color==='#7dd3fc';})[0],po=outl().filter(function(l){return l.opt.weight===pm.opt.weight+3;})[0];
 ok(pm.el.classList.s['kv-pulse']===1&&po&&po.el.classList.s['kv-pulse-o']===1,'Ueberreichweite: Haupt und Rand pulsieren');
 refresh(mkData());ok(!pm.el.classList.s['kv-pulse']&&!po.el.classList.s['kv-pulse-o'],'Puls endet auf beiden');
 // Details
 var h=lg();ok(h.indexOf('<details id="kvUnk" style=')>=0&&h.indexOf('<details id="kvUnk" open')<0,'Details standardmaessig zu');
 ok(/<details id="kvUnk"[^>]*><summary>Unbekannte TII-Träger anzeigen \(1\)<\/summary><div>/.test(h)&&h.slice(h.indexOf('<details'),h.indexOf('</details>')).indexOf('nie gezeichnet')>0&&h.slice(h.indexOf('<details'),h.indexOf('</details>')).indexOf('00/18')>0&&h.split('<details').length===2&&h.split('</details>').length===2,'Details/Summary-Struktur, Inhalt komplett');
 var tl=els.kvLeg._l.toggle;ok(tl&&tl.length===1&&tl[0][1]===true,'toggle-Abhoerer (capture)');
 tl[0][0]({target:{id:'andere',open:true}});refresh(mkData());ok(lg().indexOf('<details id="kvUnk" open')<0,'fremdes toggle aendert nichts');
 tl[0][0]({target:{id:'kvUnk',open:true}});refresh(mkData());ok(lg().indexOf('<details id="kvUnk" open')>=0,'offen bleibt beim Neuzeichnen');
 var d4=mkData();d4.unknown.push({ch:'5C',tii_txt:'09/09',n:1,last_t:1,last_err:1,max_run:1});refresh(d4);ok(lg().indexOf('<details id="kvUnk" open')>=0&&lg().indexOf('anzeigen (2)')>=0,'offen bleibt auch bei geaendertem Inhalt (N=2)');
 tl[0][0]({target:{id:'kvUnk',open:false}});refresh(d4);ok(lg().indexOf('<details id="kvUnk" open')<0,'zu bleibt zu');
 var d5=mkData({unknown:[]});refresh(d5);ok(lg().indexOf('<details')<0,'ohne Unbekannte keine Details');
 // Ticker
 refresh(mkData());h=lg();var tb=h.slice(h.indexOf('<table'),h.indexOf('</table>')+8);
 ok(tb.split('<tr>').length===4&&tb.split('</tr>').length===4,'Ticker: genau drei Zeilen');
 ok(tb.indexOf('11D Bayern')>0&&tb.indexOf('5C Bund')>tb.indexOf('11D Bayern')&&tb.indexOf('Statistik')>tb.indexOf('5C Bund'),'Ticker-Reihenfolge');
 ok(/Aktive Masten: Bamberg, Amberg/.test(tb)&&/Aktive Masten: Nuernberg/.test(tb),'Namen statt Kennungen: '+tb.slice(0,700));
 ok(tb.indexOf('unbekannt · 00/18')>0,'unbekannte Kennung als ID gezeigt');
 ok(/3 Masten aktiv \| 3 Sender empfangen \| 4 in DB registriert/.test(tb),'Statistik X|Y|Z: '+(tb.match(/Statistik.*?<\/td>/)||[''])[0]);
 ok(!/NaN|undefined|null|Infinity/.test(lg()),'kein NaN/undefined/null in der Anzeige');
 // Rueckfall 10C
 var d6=mkData();d6.ch['5C']={fig_t:1,age_s:9999,fresh:false,stick_ok:true,snr:null,tii:[]};d6.ch['10C']={fig_t:1790000000,age_s:20,fresh:true,stick_ok:true,snr:12,tii:['01/02']};d6.masts[2].ch[0].ever=true;d6.masts[2].ch[0].active=true;d6.masts[2].active=true;refresh(d6);
 ok(lg().indexOf('10C Lokal (Rückfall)')>0&&lg().indexOf('5C Bund')<0&&/Aktive Masten: Hersbruck/.test(lg()),'Rueckfall 10C benennt die Zeile');
 refresh(mkData());ok(lg().indexOf('5C Bund')>0&&lg().indexOf('10C Lokal')<0,'zurueck auf 5C Bund');
 var d8=mkData();d8.ch['10C']={fig_t:1790000000,age_s:20,fresh:true,stick_ok:true,snr:12,tii:['01/02']};refresh(d8);ok(lg().indexOf('5C Bund')>0&&lg().indexOf('10C Lokal')<0,'5C frisch: keine Rueckfall-Zeile, auch wenn 10C frisch ist');
 var d9=mkData();d9.ch['5C'].stick_ok=false;d9.ch['5C'].stick_why='Stick 2 fehlt';d9.ch['10C']={fig_t:1790000000,age_s:20,fresh:true,stick_ok:true,snr:12,tii:['01/02']};refresh(d9);ok(lg().indexOf('10C Lokal (Rückfall)')>0,'5C Stick ausgefallen und 10C frisch: Rueckfall-Zeile');
 // Kanal ohne Pruefung / Stick ausgefallen / veraltet
 var d7=mkData();d7.ch['11D']={fig_t:1790000000,age_s:900,fresh:false,stick_ok:false,stick_why:'Stick offline',snr:null,tii:['08/18']};refresh(d7);
 ok(/älter als 150 s – keine Linie/.test(lg())&&/Stick offline/.test(lg())&&/SNR keine Daten/.test(lg())&&/Aktive Masten: keine/.test(lg())&&!/NaN|undefined|null/.test(lg()),'veraltet/Stick aus: klare Anzeige');
 // Abruf schlaegt fehl
 FETCH['/api/t4/tii']='FAIL';for(var i=0;i<3;i++)TIMERS.filter(function(t){return t[1]===5000;})[0][0]();ok(/Abruf schlägt fehl/.test(lg()),'Warnzeile nach 3 Fehlschlaegen');
 refresh(mkData());ok(!/Abruf schlägt fehl/.test(lg()),'Warnzeile verschwindet bei Erfolg');
 // Backend meldet Fehler (ok:false, leere Listen)
 refresh({ok:false,error:'x',masts:[],nopos:[],unknown:[],ch:{}});var tb2=lg().slice(lg().indexOf('<table'),lg().indexOf('</table>')+8);ok(/11D Bayern<\/th><td colspan="3">keine Daten/.test(tb2)&&/5C Bund<\/th><td colspan="3">keine Daten/.test(tb2)&&/Statistik<\/th><td colspan="3">keine Daten/.test(tb2)&&!/NaN|undefined|null/.test(tb2),'Backend-Fehler: Ticker zeigt keine Daten');
}else{
 var h=lg();ok(h.indexOf('11D Bayern</th><td colspan="3">keine Daten')>0&&h.indexOf('5C Bund</th><td colspan="3">keine Daten')>0&&h.indexOf('Statistik</th><td colspan="3">keine Daten')>0&&!/NaN|undefined|null/.test(h)&&h.split('<tr>').length===4,'ohne Daten (V=null): Ticker zeigt keine Daten');
 ok(layers.filter(function(l){return l.kind==='pl';}).length===0,'ohne Daten keine Linien');
}
if(FAILS){process.exit(1);}console.log('node ok');
"""


def js_node(js):
    nodeb = None if os.environ.get("RH_NO_NODE") == "1" else shutil.which("node")
    if not nodeb:
        print("   Hinweis: node nicht vorhanden - Karten-JS wurde statisch (Struktur, Rechentest kvW) geprueft, nicht ausgefuehrt")
        return 0
    d = tempfile.mkdtemp(prefix="mu-node-")
    try:
        fj, fh = os.path.join(d, "kv.js"), os.path.join(d, "h.js")
        with open(fj, "w", encoding="utf-8") as f:
            f.write(js)
        with open(fh, "w", encoding="utf-8") as f:
            f.write(NODE_HARNESS)
        n = 0
        r = subprocess.run([nodeb, "--check", fj], capture_output=True, timeout=60)
        assert r.returncode == 0, "Karten-JS Syntax (node --check): %s" % (r.stdout + r.stderr)[:300]
        n += 1
        for mode in ("daten", "nodata"):
            r = subprocess.run([nodeb, fh, fj, mode], capture_output=True, timeout=120)
            assert r.returncode == 0 and b"node ok" in r.stdout, "Karten-JS im node (%s): %s" % (mode, (r.stdout + r.stderr)[:600].decode("utf-8", "replace"))
            n += 1
        # Rechentest kvW: node gegen die Uebersetzung
        f = kvw_py(js)
        grid = [None, -5, 0, 3, 6.25, 12.5, 18.2, 25, 40]
        prog = "var s=require('fs').readFileSync(%s,'utf8');var m=/function kvW\\(snr\\)\\{[^}]*\\}/.exec(s)[0];eval(m);console.log(JSON.stringify([null,-5,0,3,6.25,12.5,18.2,25,40,'abc',NaN].map(kvW)))" % json.dumps(fj)
        r = subprocess.run([nodeb, "-e", prog], capture_output=True, timeout=60)
        got = json.loads(r.stdout.decode())
        exp = [f(v) for v in grid + ["abc", float("nan")]]
        assert got == exp, "kvW node %s != Uebersetzung %s" % (got, exp)
        n += 1
        return n
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run_block(blk, js):
    ns = {"__name__": "mu_sandbox", "_KV_JS": js}
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(rd(blk), "mu_block", "exec"), ns)
    return ns, out.getvalue()


def behav(alt, new, blk):
    n = 0
    js, css = get_js_css(new)
    ns, out = run_block(blk, js)
    assert "mapUi aktiv: mapUi ok" in out, "Block-Selbsttest meldet nicht ok: %s" % out[:300]
    n += 1
    ns2, out2 = run_block(blk, js.replace("function kvW(snr)", "function kvX(snr)"))
    assert "mapUi Selbsttest FEHLER" in out2 and "mapUi aktiv" not in out2, "Selbsttest erkennt fehlende Breitenfunktion nicht"
    n += 1
    for bad in (js + "\nvar z={method:'POST'};", js + "\neval('1');", js.replace("<details", "<detail")):
        ns3, out3 = run_block(blk, bad)
        assert "mapUi Selbsttest FEHLER" in out3 and "mapUi aktiv" not in out3, "Selbsttest erkennt unzulaessiges Karten-JS nicht"
    n += 1
    n += js_node(js)
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_MU_NOSTATIC") == "1" else static(alt, new, blk)
    if os.environ.get("RH_MU_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    assert rd(blk).rstrip("\n") in new
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk)
    print("OK guard mapUi: %d Pruefungen, 0 fehlerhaft" % n)
    return n


# (Name, Zielzeichenfolge, Ersatz, norev)  - Ziel muss im neuen dashboard.py genau einmal vorkommen
MUT = [
    ("M1 Breite 3..5", "return Math.round((4+2*s/25)*10)/10", "return Math.round((3+2*s/25)*10)/10", 1),
    ("M2 Breite 4..8", "return Math.round((4+2*s/25)*10)/10", "return Math.round((4+4*s/25)*10)/10", 1),
    ("M3 obere Klemme fehlt", "if(s>25)s=25;", "", 1),
    ("M4 NaN nicht behandelt", "if(!(s>=0))s=0;", "", 1),
    ("M5 Klemme bei 20", "if(s>25)s=25;", "if(s>20)s=20;", 1),
    ("M6 Rand nur +2", "weight:w+3,opacity:.7", "weight:w+2,opacity:.7", 1),
    ("M7 Rand Deckkraft .3", "weight:w+3,opacity:.7", "weight:w+3,opacity:.3", 1),
    ("M8 Rand nicht dunkel", "pane:'kvOut',color:OUTC", "pane:'kvOut',color:'#7dd3fc'", 1),
    ("M9 Rand ohne eigene Ebene", "interactive:false,pane:'kvOut',color:OUTC", "interactive:false,color:OUTC", 1),
    ("M10 Ebene ueber den Linien", "zIndex=399", "zIndex=401", 1),
    ("M11 Rand-Aufraeumen fehlt komplett", "for(var k in LL){if(!lk[k]){map.removeLayer(LL[k]);delete LL[k];if(LO[k]){map.removeLayer(LO[k]);delete LO[k];}}}\nfor(var k in LO){if(!LL[k]){map.removeLayer(LO[k]);delete LO[k];}}", "for(var k in LL){if(!lk[k]){map.removeLayer(LL[k]);delete LL[k];}}", 1),
    ("M13 Linien bei jedem Zeichnen neu", "if(!ln){lo=L.polyline(", "if(true){lo=L.polyline(", 1),
    ("M14 Rand-Breite nicht nachgefuehrt", "if(lo){lo.setStyle({weight:w+3});", "if(lo){", 1),
    ("M15 Rand pulsiert nicht", "cls(lo,m.overreach,'kv-pulse-o');", "", 1),
    ("M16 Rand interaktiv", "{interactive:false,pane:'kvOut'", "{interactive:true,pane:'kvOut'", 1),
    ("M17 Hauptlinie interaktiv", "{interactive:false}).addTo(map);LL[key]=ln", "{interactive:true}).addTo(map);LL[key]=ln", 1),
    ("M18 Farbe 11D geaendert", "var CC={'11D':'#7dd3fc'", "var CC={'11D':'#60a5fa'", 1),
    ("M19 Hauptlinie zu blass", "opacity:.75+.25*q", "opacity:.3+.65*q", 1),
    ("M20 Zustand offen vergessen", "(UNK?' open':'')", "''", 1),
    ("M21 Details standardmaessig offen", "'<details id=\"kvUnk\"'+(UNK", "'<details id=\"kvUnk\" open'+(UNK", 1),
    ("M22 Abhoerer ohne Capture", "if(t&&t.id==='kvUnk')UNK=!!t.open;},true)", "if(t&&t.id==='kvUnk')UNK=!!t.open;},false)", 1),
    ("M23 Zustand von jedem toggle", "if(t&&t.id==='kvUnk')UNK=!!t.open;", "UNK=!!t.open;", 1),
    ("M24 Summary-Text anders", "Unbekannte TII-Träger anzeigen (", "Unbekannte Träger (", 1),
    ("M25 Anzahl fehlt", "anzeigen ('+uk.length+')</summary>", "anzeigen ()</summary>", 1),
    ("M26 Inhalt gekuerzt (Fehler)", "', Fehler '+n(u.last_err,0)+')'", "')'", 1),
    ("M27 Details nicht geschlossen", "x+='</div></details>';", "x+='</div>';", 1),
    ("M28 Statistik-Zeile fehlt", "<tr><th>Statistik</th><td colspan=\"3\">'+st+'</td></tr>", "", 1),
    ("M29 11D-Zeile umbenannt", "row('11D','11D Bayern')", "row('11D','11D')", 1),
    ("M30 5C-Zeile umbenannt", "row('5C','5C Bund')", "row('5C','5C')", 1),
    ("M31 Rueckfall nie", "fb=!!(!(c5.fresh&&c5.stick_ok)&&c10.fig_t&&c10.fresh&&c10.stick_ok)", "fb=false", 1),
    ("M32 Rueckfall immer bei 10C-Daten", "fb=!!(!(c5.fresh&&c5.stick_ok)&&c10.fig_t&&c10.fresh&&c10.stick_ok)", "fb=!!(c10.fig_t&&c10.fresh&&c10.stick_ok)", 1),
    ("M33 Kennung statt Name", "if(on)nm.push(al[i].name||('unbekannt · '+q.tii_txt))", "if(on)nm.push(q.tii_txt)", 1),
    ("M34 unbekannte Kennung fehlt", "if(live)for(var j=0;j<tl.length;j++){if(!kn[tl[j]])un.push('unbekannt · '+tl[j]);}", "", 1),
    ("M35 X zaehlt alle Masten", "if(al[i].active)X++;", "X++;", 1),
    ("M36 Y und Z vertauscht", "Z++;if(cs[k].ever)Y++;", "Y++;if(cs[k].ever)Z++;", 1),
    ("M37 ohne Daten (V=null) leer", "if(!V){var x0=tick();if(lg._x!==x0){lg._x=x0;lg.innerHTML=x0;}return;}", "if(!V)return;", 1),
    ("M38 init ohne legend", "draw();zones();legend();}", "draw();zones();}", 1),
    ("M39 Kanal ohne Pruefung leer", "if(!c.fig_t)return '<tr>'+th+'<td colspan=\"3\">keine Daten'+why+'</td></tr>';", "", 1),
    ("M40 SNR ohne Daten-Text", "(c.snr==null?'keine Daten':n(c.snr,1)+' dB')", "(Number(c.snr).toFixed(1)+' dB')", 1),
    ("M41 Warnzeile fehlt", "(FAIL>=3?'<div style=\"color:#f97316\">keine aktuellen Daten (Abruf schlägt fehl) – Anzeige kann veraltet sein</div>':'')+", "", 1),
    ("M42 Fehlschlag zaehlt nicht", ".catch(function(){FAIL++;legend();})", ".catch(function(){})", 1),
    ("M43 Erfolg setzt FAIL nicht zurueck", "V=j;FAIL=0;draw();", "V=j;draw();", 1),
    ("M44 CSS Pulsrand fehlt", ".kv-pulse-o{animation:kvpo 1.4s ease-in-out infinite}", "", 1),
    ("M45 bestehende Pulsanimation geaendert", "@keyframes kvp{0%{stroke-opacity:1;stroke-width:3px}", "@keyframes kvp{0%{stroke-opacity:1;stroke-width:5px}", 1),
    ("M46 neuer Netzzugriff", "function tick(){var CH=(V&&V.ch)||{}", "function tick(){fetch('/x');var CH=(V&&V.ch)||{}", 1),
    ("M47 innerHTML zusaetzlich", "function tick(){var CH=(V&&V.ch)||{}", "function tick(){document.body.innerHTML='';var CH=(V&&V.ch)||{}", 1),
    ("M48 Definition X/Y/Z fehlt", "X = Masten (Standorte)", "X = Zahl", 1),
    ("M49 Farblogik 5C geaendert", "'5C':'#ef4444','10C':'#f97316'};", "'5C':'#dc2626','10C':'#f97316'};", 1) if False else ("M49 Hauptlinie Farbe", "color:CC[c.ch]||'#7dd3fc',weight:w", "color:'#ffffff',weight:w", 1),
    ("M50 stille Zusatzaenderung: Menue-Meldung", 'print("kartevec Menue:", e, flush=True)', 'print("kartevec Menu:", e, flush=True)', 1),
    ("M51 Block ohne Pruefung der Breitenfunktion", "\"function kvW(snr)\", ", "", 0),
    ("M52 Block erlaubt POST", "assert \"method:'POST'\" not in js and \"/send\" not in js and \"eval(\" not in js", "assert True", 0),
]


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    bad = []
    done = 0
    for name, a, b, norev in MUT:
        w = tempfile.mkdtemp(prefix="mu-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            B = rd(blk).rstrip("\n")
            if a in B and not norev:
                assert base_new.count(B) == 1
                mnew = base_new.replace(B, B.replace(a, b))
                bt = rd(blk).replace(a, b)
            else:
                bi = base_new.index(B)
                pre = base_new[:bi]
                assert pre.count(a) == 1, "%s: Stelle nicht eindeutig (%d)" % (name, pre.count(a))
                mnew = pre.replace(a, b) + base_new[bi:]
                bt = rd(blk)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(mnew)
            if norev:
                os.environ["RH_MU_NOREV"] = "1"
            else:
                os.environ.pop("RH_MU_NOREV", None)
            bf = os.path.join(w, "blk.py")
            with open(bf, "w", encoding="utf-8") as f:
                f.write(bt)
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
            os.environ.pop("RH_MU_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation mapUi: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
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
        print("guard mapUi FEHLER: %s" % e)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach dbVis commit31" "$KNOWN_D16N" "mapUi schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      mapUi passt nur auf den Stand Stand nach dbVis commit31 (dashboard.py 3a933125227fb89b). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis kartevec; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
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
python3 "$PPK" mapUi dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer mapUi nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" mapUi dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: mapUi im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne mapUi ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard mapUi meldet Verstoss"; }
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

NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: mapUi ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-mapui-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG mapui=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "mapUi|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-mapui-$TS" ]] && cp -a "$F.bak-mapui-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-mapui-$TS" ]] && { cmp -s "$F" "$F.bak-mapui-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK mapUi schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-mapui-$TS"
  { ls -1t "$F.bak-mapui-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-mapui-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-mapui-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'mapUi aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; mapUi aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- mapUi: /karte liefert das neue Karten-JS (nur Lesen), /pi-Kachelreihenfolge unveraendert ----
"${CURL[@]}" "$B/karte" -o "$W/karte.html" || true
MUK=$(python3 - "$W/karte.html" "$W/pi0.html" "$W/pi.html" << 'PYV'
import sys
k = open(sys.argv[1], encoding="utf-8", errors="replace").read()
p0 = open(sys.argv[2], encoding="utf-8", errors="replace").read()
p1 = open(sys.argv[3], encoding="utf-8", errors="replace").read()
need = ("function kvW(snr)", "createPane('kvOut')", "pane:'kvOut'", "<details id=\"kvUnk\"", "Unbekannte TII-Träger anzeigen", "function tick()", ".kv-tick{", "11D Bayern", "5C Bund", "setInterval(load,5000)")
miss = [x for x in need if x not in k]
if miss:
    print("FEHLT %s" % miss); sys.exit(0)
if k.count('id="kv-js"') != 1 or k.count("function kvW(") != 1:
    print("DOPPELT"); sys.exit(0)
toks = ("doPrepperRestore", "Projektbeschreibung", "srcCard")
sig = lambda t: [x for x in sorted(toks, key=lambda x: t.find(x) if x in t else 10**9) if x in t]
if sig(p0) != sig(p1):
    print("REIHENFOLGE /pi %s -> %s" % (sig(p0), sig(p1))); sys.exit(0)
print("OK")
PYV
)
[[ "$MUK" == OK ]] && echo "OK /karte liefert Linien-Rand/Breite nach SNR, einklappbare Unbekannte TII-Traeger und Status-Ticker (je genau einmal); /pi-Kachelreihenfolge unveraendert" || rbx "/karte-Pruefung mapUi fehlgeschlagen: $MUK"
KT=$(code "$B/api/t4/tii"); [[ "$KT" == 200 ]] && echo "OK /api/t4/tii unveraendert 200 (Backend/Daten nicht angefasst)" || rbx "/api/t4/tii antwortet $KT"
echo "HINWEIS: die Darstellung im Browser (Linienbreite, Rand, Ticker) wird hier nicht per Screenshot geprueft - bitte /karte einmal ansehen (Strg+F5 fuer frisches JS)."
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E mapUi"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "mapUi aktiv: mapUi ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'mapUi aktiv: mapUi ok' ($(echo "$JD" | grep -F mapUi | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'kartevec aktiv:'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein mapUi-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis kartevec mapUi; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-mapui-$TS" ]] && echo "Backup: dashboard.py.bak-mapui-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-mapui-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine mapui-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s http://127.0.0.1:5000/karte | grep -c kvOut"
echo "  curl -s http://127.0.0.1:5000/karte | grep -o 'Unbekannte TII-Träger anzeigen'"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep mapUi"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG mapui=1 fertig"
