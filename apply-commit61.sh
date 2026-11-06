#!/bin/bash
# shellcheck disable=SC2015
set -eEuo pipefail
# funkFlach (commit61): Seiten /funk und /karte flach und kurz wie /umwelt (commit53) und die uebrigen Seiten (commit60) - NUR ANZEIGE, sendet nichts:
#  - keine Kachel in der Kachel (Schalter/Knoepfe zaehlen nicht); Umbruch statt Abschneiden; lange Hinweise kurz; Sicherheitshinweise gekuerzt behalten; Datentexte bleiben
#  - /funk: sichtbare Stick-Seriennummern ausgeblendet (Rollen bleiben); /karte: Pruef-Tabelle untereinander (kein Querscrollen)
#  - beide Seiten bauen vieles im Browser neu: kleines Text-Skript (kein Abruf, kein Klick, kein Senden) plus CSS; fehlt eine Stelle, bleibt sie wie bisher
#  dashboard.py: ein Block vor __main__ (after_request als letzter Schritt, nur fertiges HTML dieser Seiten); prepper_docs.py: 3 Textstellen (Beschreibung).
#  Danach einmal python3 prepper_docs.py (neue Version der Projektbeschreibung in docs/).
# Aufruf: bash /tmp/apply-commit61.sh commit61 [dry-run]   (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein Neustart)
# Basis streng (sha16, Zielstand commit60): dashboard.py b4b727de851587c7, prepper_docs.py 1bf7c89d85e36169; Ziel dashboard.py 41ba14c8280af0d5, prepper_docs.py 6a9d8708e8d0cceb.
#  Unveraendert und vorausgesetzt (commit59/60): prepper_sdr.py b879ab56f4ac4736, sdr_manager.py 5a26efff608bf541, database.py 2754d0bdddca9400. Stand vor commit60 -> STOP (erst commit60).
# Neustart: nur prepper-dashboard, Sperre HH:55-HH:04 (Start ab HH:50 gesperrt). Datenbank, prepper-sdr, Mesh-Bruecken bleiben unberuehrt.
# Fehler -> Rollback: beide Dateien aus DATEI.bak-commit61-ZEIT, docs/ wie vorher, prepper-dashboard erneut neu gestartet.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
W=/tmp/commit61-apply
NM=commit61
MK=funkFlach
SIM=0; [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && SIM=1
if [[ "$SIM" == 1 ]]; then DASH_DIR="${C61_SIM_DIR:-$DASH_DIR}"; W="${C61_SIM_W:-$W}"; fi
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
KEEP_LAST=3
FILES=(dashboard.py prepper_docs.py)
declare -A ALT=([dashboard.py]=b4b727de851587c7 [prepper_docs.py]=1bf7c89d85e36169)
declare -A NEU=([dashboard.py]=41ba14c8280af0d5 [prepper_docs.py]=6a9d8708e8d0cceb)
declare -A KEEP60=([prepper_sdr.py]=b879ab56f4ac4736 [sdr_manager.py]=5a26efff608bf541 [database.py]=2754d0bdddca9400 [lage_pages.py]=a9740c629a41806c [ups_manager.py]=ef0b9e3d4bf42003 [prepper_evlog.py]=8bffd396972b60fa)
# Stand vor commit60 (Zielstand commit59) - dann erst commit60
declare -A PRE60=([dashboard.py]=2d0412bbbecc25b3 [prepper_docs.py]=2e1e23726611b2ec)
DOCS="$DASH_DIR/docs"
PHASE=vorher
FINISHED=0
RESTARTED=0
GEN_RAN=0
STOPPED=0
RB_DONE=0
INST=()
ERRLN=""; ERRCMD=""
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
stop() { STOPPED=1; echo "STOP: $1 - nichts geaendert"; exit 1; }
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then stop "Dashboard-Port unklar ($PORT)"; fi
if [[ "$PORT" == "8080" ]]; then stop "Port 8080 ist kiwix-serve, nicht das Dashboard"; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
for t in python3 sha256sum curl flock cp mv cmp stat date timeout nice; do command -v "$t" >/dev/null 2>&1 || stop "Werkzeug $t fehlt"; done
s16() { sha256sum "$1" | cut -c1-16; }
on_exit() {
  local ec=$?
  if [[ $ec -ne 0 && $FINISHED -eq 0 ]]; then
    if [[ "$PHASE" == vorher ]]; then
      [[ -n "$ERRLN" && "$STOPPED" == 0 ]] && echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - es wurde noch nichts geaendert"
    elif [[ "$PHASE" == installiert && "$RB_DONE" == 0 ]]; then
      echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile ${ERRLN:-?}, Befehl: $(echo "${ERRCMD:-?}" | cut -c1-160) - Rollback"
      rb "unerwarteter Fehler" || true
    fi
  fi
}
trap on_exit EXIT
echo "=== $MK apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): /funk und /karte flach und kurz (nur Anzeige), Dashboard-Port $PORT ==="
umask 022
mkdir -p "$(dirname "$W")"
exec 9>"$W.lock"
flock -n 9 || stop "ein anderer $NM-Lauf ist aktiv (Sperre $W.lock)"
rm -rf "$W" && mkdir -p "$W/neu" "$W/alt" "$W/x" "$W/html" && chmod 700 "$W"
EXPECT_EDT="ab6bab6fb46f2e64a12a3fcc9f257086f28643e6a946c82f1f80cd74a912f88e"
cat > "$W/edits.py" << 'MK_EDT_EOF'
# commit61 funkFlach - Textstellen in prepper_docs.py (je genau einmal; idempotent)
NAME = "funkFlach"
DOCS = [
    ("danach seitenFlach (60): uebrige Seiten flach und kurz (nur Anzeige).",
     "danach seitenFlach (60): uebrige Seiten flach und kurz (nur Anzeige); funkFlach (61): /funk und /karte ebenso."),
    ("after_request als letzter Schritt (commit60) |\n",
     "after_request als letzter Schritt (commit60) |\n"
     "| funkFlach | /funk und /karte flach und kurz: CSS plus kleines Text-Skript (kuerzt Texte nach jedem Neuaufbau, kein Abruf, kein Klick), Seriennummern auf /funk ausgeblendet, Karte ohne Querscrollen (commit61) |\n"),
    ("- Seit seitenFlach (commit60) ",
     "- Seit funkFlach (commit61) auch /funk und /karte: Geraete-Chips, Krisen-Zeile und Steuer-Rahmen ohne eigene Kachel, Watchdog- und Steuerzeilen umbrechen statt abschneiden, "
     "lange Hinweise kurz (Gain-Automatik: nie bei Alarm, bei Fehlern Stufe 16; Antennentest aendert den Standard-Gain nie). Beide Seiten bauen vieles im Browser alle paar Sekunden neu, "
     "darum kuerzt ein kleines Skript die bekannten Texte nach jedem Neuaufbau (nur Text, kein Abruf, kein Klick, kein Senden); fehlt eine Stelle, bleibt sie wie bisher. "
     "Sichtbare Stick-Seriennummern auf /funk werden ausgeblendet (Rollen und Kanaele bleiben). Auf /karte steht die Pruef-Tabelle untereinander (kein Querscrollen) und Legende und Quellen sind drei kurze Zeilen.\n- Seit seitenFlach (commit60) "),
]
MK_EDT_EOF
EXPECT_PPK="f292eb15e6108bfa1428fcb46614643c37bc9e03f59ea9dd59b3c090338f7553"
cat > "$W/patch.py" << 'MK_PPK_EOF'
#!/usr/bin/env python3
"""patch60.py SRC DST EDITS BLK - baut dashboard.py (Block vor __main__) und prepper_docs.py (Textstellen) fuer commit61.
Idempotent: Zielstand -> unveraendert. Jede Stelle genau einmal, sonst Exit 2."""
import os, sys
src, dst, ed, blk = sys.argv[1:5]
g = {}; exec(compile(open(ed, encoding="utf-8").read(), ed, "exec"), g)
B = open(blk, encoding="utf-8").read()
NM = g["NAME"]
A = '\n\nif __name__ == "__main__":\n'
def die(m):
    print("FEHLER " + m); sys.exit(2)
d = open(os.path.join(src, "dashboard.py"), encoding="utf-8").read()
mk = "# ===== %s (commit61)" % NM
if mk in d:
    if d.count(B) != 1: die("dashboard.py: %s vorhanden, aber nicht wortgleich" % NM)
    nd = "dashboard.py schon drin"
else:
    if d.count(A) != 1: die("dashboard.py: __main__-Stelle %dx" % d.count(A))
    if NM in d: die("dashboard.py: Name %s schon anderweitig vorhanden" % NM)
    d = d.replace(A, "\n\n" + B + A); nd = "dashboard.py Block eingefuegt"
p = open(os.path.join(src, "prepper_docs.py"), encoding="utf-8").read()
n = 0
for old, new in g["DOCS"]:
    if p.count(new) == 1 and (old not in new or p.count(old) == 1) and (old in new or p.count(old) == 0):
        continue
    if p.count(old) != 1: die("prepper_docs.py: Stelle %dx: %r" % (p.count(old), old[:60]))
    p = p.replace(old, new); n += 1
for fn, tx in (("dashboard.py", d), ("prepper_docs.py", p)):
    t = os.path.join(dst, fn) + ".tmp"
    with open(t, "w", encoding="utf-8") as f: f.write(tx)
    os.replace(t, os.path.join(dst, fn))
print("%s; prepper_docs.py %d/%d Textstellen" % (nd, n, len(g["DOCS"])))
MK_PPK_EOF
EXPECT_BLK="f633caec4274e7b86ae595131dbd08fc3b34399ee3b18733ce86ef3d0b2975c8"
cat > "$W/blk.py" << 'MK_BLK_EOF'
# ===== funkFlach (commit61): Seiten /funk und /karte aufgeraeumt - nur Anzeige =====
# Wie seitenFlach (commit60): keine Kachel in der Kachel (Schalter/Knoepfe zaehlen nicht), Umbruch statt Abschneiden (Zeilen zum Aufklappen bleiben), lange Erklaertexte kurz, Sicherheitshinweise bleiben.
# Beide Seiten bauen vieles erst im Browser (Abrufe alle paar Sekunden): darum ein kleines Skript, das nur Texte kuerzt (nach jedem Neuaufbau, vor dem Zeichnen),
# und ein CSS-Block. Kein Abruf, kein Klick, kein Senden, keine Schalter-Aenderung; fehlt eine Stelle, bleibt sie wie bisher.
# Sichtbare Seriennummern auf /funk werden ausgeblendet (Rollen bleiben). Karte: Tabelle oben untereinander statt breiter als der Bildschirm.
import re as _ff_re

_FF_PAGES = ("/funk", "/karte")
_FF_CSS = {
    "/funk": (".su-chip{background:transparent!important;border:0!important;border-top:1px solid #1e293b!important;border-radius:0!important;padding:6px 2px!important}"
              ".sl-krise{border:0!important;border-left:4px solid currentColor!important;border-radius:0!important;padding:4px 8px!important}"
              "fieldset{border:0!important;border-top:1px solid #334155!important;border-radius:0!important;padding:6px 0 0!important}"
              ".wd-r,.wd-s{height:auto!important;white-space:normal!important;overflow:visible!important;align-items:flex-start!important}"
              ".wd-r>span:last-child{overflow:visible!important;text-overflow:clip!important;overflow-wrap:anywhere}"),
    "/karte": (".kv-tick,.kv-tick tbody,.kv-tick tr,.kv-tick th,.kv-tick td{display:block!important;width:auto!important}"
               ".kv-tick tr{border-bottom:1px solid #334155;padding:3px 0}"
               ".kv-tick th,.kv-tick td{border-bottom:0!important;padding:1px 4px!important;white-space:normal!important;overflow-wrap:anywhere}"),
}
# Regeln fuer das Skript: (Seite, CSS-Auswahl, Art, Muster (JS = Python), Ersatz)
#  t = in jedem Textknoten ersetzen (Auszeichnung bleibt), e = ganzer Text passt -> ersetzen, c = ganzer Text passt -> fester Text, h = ganzer Text passt -> feste kurze Zeilen
_FF_RULES = [
    ("/funk", "body", "t", r" ?\(SN [0-9A-F]{6,20}\)", ""),
    ("/funk", "body", "t", r"SN [0-9A-F]{6,20} · ", ""),
    ("/funk", "body", "t", r" · SN [0-9A-F]{6,20}", ""),
    ("/funk", ".wd-r", "t", r"10C-Prüfung alle [0-9]+ h: ", "10C "),
    ("/funk", ".wd-r", "t", r"\(zuletzt RDS ", "("),
    ("/funk", ".sl-s2", "t", r" · Stick [0-9] · [A-Za-z0-9]+ Korrektur 0 ppm", ""),
    ("/funk", ".fu-kv .v", "t", r" · 10C-Prüfung verschoben: (.+?) misst gerade selbst mit welle-cli", " · 10C verschoben ($1 misst selbst)"),
    ("/funk", "div.small", "h", r"^LAN = Bridge/TCP/systemd \(bisherige Ampel\) · Funk = Telemetrie",
     "<b>LAN</b> = Bridge/TCP · <b>Funk</b> = Telemetrie + Ping · <b>Stuck</b> = Wert hängt · <b>Stumm</b> = keine Antwort"),
    ("/funk", ".fu-note", "c", r"^BER: welle-cli liefert keine Bitfehlerrate", "BER = FIC-Fehlerrate (welle-cli liefert keine BER)"),
    ("/funk", ".wd-s", "e", r"^Automatik (an|aus|AUS) · USB-Neuverbindung ab ([0-9]+) min · Pi-Neustart ab ([0-9]+) min \(max 1/h, Stopp nach ([0-9]+)\)$",
     "Automatik $1 · USB ab $2 min · Pi ab $3 min (max 1/h)"),
    ("/funk", ".sl-krise", "e", r"^((?:(?!Airspy|Stick [0-9]).)*?)(?: · (?:Airspy R2 · 11D|Stick [0-9] · [A-Za-z0-9]+) ok){2,}$", "$1 · alle Empfänger ok"),
    ("/funk", ".ag-n", "h", r"^Wechsel nur bei klarem Vorteil über mehrere Messungen und nie bei Alarm",
     "<div>Wechsel nur bei klarem Vorteil, nie bei Alarm/ASA/PTY 31/Meteor</div><div>max 2 Wechsel in 48 h · bei Fehlern Stufe 16 · Auto nur gemessen</div>"),
    ("/funk", ".at-n", "c", r"^Nur Airspy 11D; der Test selbst ändert den Standard-Gain nie", "Test ändert den Standard-Gain nie · Abbruch bei Alarm/ASA/Sperre"),
    ("/funk", "#stickTestCard > .title", "c", r"^Antennentest – im Geräte-Register-Betrieb aus \(Vergleichstest folgt\)", "Antennentest – im Register-Betrieb aus (Vergleich folgt)"),
    ("/karte", "#kvLeg > div", "h", r"^Legende \([0-9]+ Masten mit Position gezeichnet\): ",
     "<div><b>Legende</b> · Linie = Mast in letzter TII-Prüfung · 11D hellblau, 5C rot, 10C orange</div>"
     "<div>● grau = nie empfangen · ● blau = schon empfangen · pulsierend = Überreichweite</div>"
     "<div>Klick auf Mast/Linie = Popup · rot = Gefahrenzone · ▲ = Straßensperre</div>"),
    ("/karte", "#kvLeg > div", "c", r"^welle-cli liefert je Mast keinen Pegel", "Linienstärke = Schätzung aus SNR · Positionen ca. 0,1–1 km genau · nur Anzeige"),
    ("/karte", "#kvInfo", "c", r"^Offline-Kacheln fehlen – prepper-tiles-teil4\.sh ausführen$", "Kacheln fehlen (prepper-tiles-teil4.sh)"),
]
_FF_JS = r"""(function(){if(window.__ffl)return;window.__ffl=1;var R=__R__;
var SK={SCRIPT:1,STYLE:1,TEXTAREA:1,OPTION:1,SELECT:1,INPUT:1};
function tn(el,re,rp){var w=document.createTreeWalker(el,4,null),n;while((n=w.nextNode())){var p=n.parentNode;if(!p||SK[p.nodeName])continue;var v=n.nodeValue,x=v.replace(re,rp);if(x!==v)n.nodeValue=x;}}
function run(){for(var i=0;i<R.length;i++){var r=R[i];try{var L=document.querySelectorAll(r[0]);for(var j=0;j<L.length;j++){var el=L[j];
if(r[1]==='t'){tn(el,new RegExp(r[2],'g'),r[3]);continue;}var t=el.textContent.replace(/\s+/g,' ').trim(),re=new RegExp(r[2]);if(!re.test(t))continue;
if(r[1]==='h')el.innerHTML=r[3];else if(r[1]==='c')el.textContent=r[3];else{var x=t.replace(re,r[3]);if(x!==t)el.textContent=x;}}}catch(e){}}}
run();var mo=new MutationObserver(function(){run();mo.takeRecords();});mo.observe(document.body,{childList:true,subtree:true,characterData:true});})();"""
_FF = {"hits": {}, "n": 0, "err": None, "selftest": None}


def _ff_js(path):
    import json as _j
    rs = [[s, k, p, r] for pg, s, k, p, r in _FF_RULES if pg == path]
    return _FF_JS.replace("__R__", _j.dumps(rs, ensure_ascii=False).replace("</", "<\\/"))


def _ff_apply(path, body):
    hits = {}
    if path not in _FF_PAGES or 'id="ff-css"' in body:
        return body, hits
    css = '<style id="ff-css">%s</style>' % _FF_CSS.get(path, "")
    j = body.find("</head>")
    if j >= 0:
        body = body[:j] + css + body[j:]
    else:
        body = css + body
    js = '<script id="ff-js">%s</script>' % _ff_js(path)
    k = body.rfind("</body>")
    body = (body[:k] + js + body[k:]) if k >= 0 else (body + js)
    hits["css"] = 1
    hits["js"] = 1
    hits["rules"] = sum(1 for pg, *_ in _FF_RULES if pg == path)
    return body, hits


def _ff_after(resp):
    try:
        from flask import request as rq
        if rq.path not in _FF_PAGES or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        nb, h = _ff_apply(rq.path, body)
        if nb != body:
            resp.set_data(nb)
            _FF["hits"] = h
        _FF["n"] += 1
    except Exception as e:
        _FF["err"] = str(e)[:160]
    return resp


def _ff_selftest():
    def js2py(rp):
        return _ff_re.sub(r"\$([0-9])", r"\\\1", rp)
    def one(pg, sel, txt):
        for p, s, k, pat, rp in _FF_RULES:
            if p == pg and s == sel and k in ("e", "c", "h") and _ff_re.search(pat, txt):
                return rp if k in ("c", "h") else _ff_re.sub(pat, js2py(rp), txt, count=1)
        return txt
    def tx(pg, sel, txt):
        for p, s, k, pat, rp in _FF_RULES:
            if p == pg and s == sel and k == "t":
                txt = _ff_re.sub(pat, js2py(rp), txt)
        return txt
    assert tx("/funk", "body", "SN 0000ABCD · fest 11D (BR Bayern)") == "fest 11D (BR Bayern)"
    assert tx("/funk", "body", "Hobby · 433 fest · SN 0000ABCD") == "Hobby · 433 fest" and tx("/funk", "body", "läuft auf Stick 2 (SN 0000ABCD)") == "läuft auf Stick 2"
    assert tx("/funk", "body", "SNR 10,0 dB · RSSI –") == "SNR 10,0 dB · RSSI –"                       # SNR bleibt
    assert tx("/funk", ".wd-r", "RDS ok · nur Beobachtung · 10C-Prüfung alle 6 h: Sync 19:37") == "RDS ok · nur Beobachtung · 10C Sync 19:37"
    k1 = "Keine Warnung im Rundfunk · Funkumfeld nicht messbar · Airspy R2 · 11D ok · Stick 1 · 5C ok · Stick 2 · Hobby ok · Stick 3 · Hobby ok"
    assert one("/funk", ".sl-krise", k1) == "Keine Warnung im Rundfunk · Funkumfeld nicht messbar · alle Empfänger ok", one("/funk", ".sl-krise", k1)
    k2 = "Keine Warnung · Airspy R2 · 11D ok · Stick 1 · 5C fehlt · Stick 2 · Hobby ok · Stick 3 · Hobby ok"
    assert one("/funk", ".sl-krise", k2) == k2                                                           # ein Geraet nicht ok -> unveraendert
    assert one("/funk", ".wd-s", "Automatik an · USB-Neuverbindung ab 45 min · Pi-Neustart ab 60 min (max 1/h, Stopp nach 3)") == "Automatik an · USB ab 45 min · Pi ab 60 min (max 1/h)"
    assert tx("/funk", ".sl-s2", "🔌 Geräte: Airspy R2 · 11D fest · Stick 2 · Hobby Korrektur 0 ppm · Stick 3 · Hobby Korrektur 2 ppm") == "🔌 Geräte: Airspy R2 · 11D fest · Stick 3 · Hobby Korrektur 2 ppm"
    assert one("/karte", "#kvInfo", "Offline-Kacheln (2026-10-17) · TII alle 5 s") == "Offline-Kacheln (2026-10-17) · TII alle 5 s"
    for p, s, k, pat, rp in _FF_RULES:                                                                   # neue Texte kurz, nie wieder passend (keine Schleife)
        for line in _ff_re.sub(r"</?div>", "\n", rp).split("\n"):
            line = _ff_re.sub(r"<[^>]+>", "", line)
            assert len(line) < 90, line
        if k in ("c", "h"):
            assert not _ff_re.search(pat, _ff_re.sub(r"<[^>]+>", "", rp)), rp
    js = _ff_js("/funk") + _ff_js("/karte")
    for bad in ("fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", ".click(", "submit", "location", "eval(", "localStorage", "/api/"):
        assert bad not in js, bad
    b, h = _ff_apply("/karte", "<html><head></head><body>x</body></html>")
    assert b.count('id="ff-css"') == 1 and b.count('id="ff-js"') == 1 and h.get("css") == 1
    b2, h2 = _ff_apply("/karte", b)
    assert b2 == b and not h2 and _ff_apply("/pi", "<head></head>")[0] == "<head></head>"
    return "funkFlach ok (/funk und /karte, %d Regeln, Seriennummern ausgeblendet, Umbruch statt Abschneiden, Karte ohne Querscrollen, andere Seiten unberuehrt)" % len(_FF_RULES)


try:
    _FF["selftest"] = _ff_selftest()
    if "app" in globals() and not any(getattr(f, "__name__", "") == "_ff_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request_funcs.setdefault(None, []).insert(0, _ff_after)   # als letzter Schritt (Flask ruft in umgekehrter Reihenfolge)
    print("funkFlach aktiv: %s" % _FF["selftest"], flush=True)
except Exception as _ff_e:
    _FF["selftest"] = "FEHLER %s" % _ff_e
    print("funkFlach FEHLER: %s - Seiten wie bisher" % _ff_e, flush=True)
# ===== /funkFlach =====
MK_BLK_EOF
EXPECT_GRD="33b8484422dd1242024dd02be505d2a01bfd751b696598182eee3f8f244d35a1"
cat > "$W/guard.py" << 'MK_GRD_EOF'
#!/usr/bin/env python3
"""guard61.py check ALT NEU EDITS BLK | mutate ALT NEU EDITS BLK
Pruefprogramm commit61 funkFlach: nur der Block vor __main__ (dashboard.py) und die 3 Textstellen (prepper_docs.py),
Block nur Anzeige (kein Senden, kein Netz, kein Prozess, keine Route, keine Datei), Sicherheitshinweise bleiben, keine Seriennummern."""
import ast, re, sys

A = '\n\nif __name__ == "__main__":\n'
SAFE = ["Nur Empfang", "nie ins Mesh", "KATASTROPHE", "Rot nur bei amtlicher Warnung", "sendet nichts"]
BAD_NAMES = {"subprocess", "socket", "requests", "urllib", "http", "os", "shutil", "sqlite3", "smtplib", "telegram", "threading", "open", "exec", "eval",
             "__import__", "compile", "send", "mesh_send", "post"}
PAGES_OK = {"/funk", "/karte"}
# Pflichtinhalt kurzer Ersatztexte (Sicherheitshinweise gekuerzt behalten)
NEED = {".ag-n": ["nie bei Alarm", "Stufe 16"], ".at-n": ["Standard-Gain nie", "Abbruch bei Alarm"], "#kvLeg > div": []}
JS_BAD = ["fetch", "XMLHttpRequest", "sendBeacon", "WebSocket", ".click", "submit", "location", "eval", "localStorage", "sessionStorage", "/api/", "import(", "Function(", "setInterval", "setTimeout", "cookie", "open("]


def chk(alt_d, neu_d, alt_p, neu_p, docs, blk):
    err = []
    if neu_d.count(blk) != 1:
        err.append("Block nicht genau einmal in dashboard.py")
    elif neu_d.replace("\n\n" + blk + A, A, 1) != alt_d:
        err.append("dashboard.py: Aenderung ausserhalb des Blocks oder Block nicht direkt vor __main__")
    q = neu_p
    for old, new in docs[::-1]:
        if q.count(new) != 1:
            err.append("prepper_docs.py: Textstelle nicht genau einmal: %r" % new[:50]); break
        q = q.replace(new, old, 1)
    if q != alt_p:
        err.append("prepper_docs.py: Aenderung ausserhalb der 3 Textstellen")
    try:
        t = ast.parse(blk)
    except SyntaxError as e:
        return err + ["Block Syntax: %s" % e]
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            mods = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module or ""]
            if any(m not in ("re", "json") for m in mods) and not (isinstance(n, ast.ImportFrom) and n.module == "flask" and [a.name for a in n.names] == ["request"]):
                err.append("Block importiert %s" % mods)
        if isinstance(n, ast.Name) and n.id in BAD_NAMES:
            err.append("Block nutzt %s" % n.id)
        if isinstance(n, ast.Attribute) and n.attr in ("route", "add_url_rule", "before_request", "system", "popen", "send", "post", "write_text", "write", "teardown_request"):
            err.append("Block nutzt .%s" % n.attr)
        if isinstance(n, (ast.Global, ast.Nonlocal)):
            err.append("Block aendert globale Namen")
    top = [n for n in t.body]
    for n in top:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and not n.name.startswith("_ff_"):
            err.append("Block definiert %s" % n.name)
        if isinstance(n, ast.Assign):
            for tg in n.targets:
                if not (isinstance(tg, ast.Name) and tg.id.startswith("_FF")):
                    err.append("Block weist %s zu" % ast.dump(tg)[:40])
    g = {"__name__": "guard61"}
    try:
        exec(compile(blk, "blk", "exec"), g)
    except Exception as e:
        return err + ["Block laeuft nicht: %s" % e]
    st = str(g.get("_FF", {}).get("selftest"))
    if not st.startswith("funkFlach ok"):
        err.append("Selbsttest: %s" % st[:120])
    pages = set(g.get("_FF_PAGES", ()))
    if pages != PAGES_OK:
        err.append("Seitenliste %s" % sorted(pages ^ PAGES_OK))
    for r in g.get("_FF_RULES", []):
        if len(r) != 5:
            err.append("Regel falsch aufgebaut"); continue
        pg, sel, kind, pat, new = r
        if pg not in PAGES_OK:
            err.append("Regel fuer Seite %s" % pg)
        if kind not in ("t", "e", "c", "h"):
            err.append("Regelart %s" % kind)
        if sel == "body" and (kind != "t" or new != "" or "SN" not in pat):
            err.append("Regel auf ganzer Seite darf nur Seriennummern entfernen")
        for k, need in NEED.items():
            if sel == k:
                for w in need:
                    if w not in new:
                        err.append("Sicherheitshinweis %r fehlt (%s)" % (w, sel))
        if re.search(r"(?i)<script|<iframe|<img|<a |\bon[a-z]+=|javascript:|fetch\(|/api/", new):
            err.append("Regel setzt Skript/Abruf ein (%s)" % sel)
        if re.search(r"<(?!/?(?:b|div)>)", new):
            err.append("Regel setzt andere Auszeichnung als <b>/<div> ein (%s)" % sel)
    try:
        js = g["_ff_js"]("/funk") + g["_ff_js"]("/karte")
    except Exception as e:
        js = ""; err.append("Skript nicht baubar: %s" % e)
    for w in JS_BAD:
        if w in js:
            err.append("Skript enthaelt %s" % w)
    for k in g.get("_FF_CSS", {}):
        if k not in PAGES_OK:
            err.append("CSS fuer Seite %s" % k)
    txt = blk + "".join(n for _, n in docs)
    if re.search(r"\b[0-9A-F]{16}\b|\b[0-9]{8}\b", txt.replace("20261024-2231", "")):
        err.append("Block/Doku enthaelt eine Seriennummer-artige Zahl")
    if re.search(r"(?i)secret|token|passw|api[_-]?key", blk):
        err.append("Block nennt Geheimnisse")
    return err


def load(d, f):
    return open("%s/%s" % (d, f), encoding="utf-8").read()


def main():
    cmd, alt, neu, ed, bf = sys.argv[1:6]
    g = {}; exec(compile(open(ed, encoding="utf-8").read(), ed, "exec"), g)
    docs = g["DOCS"]; blk = open(bf, encoding="utf-8").read()
    ad, nd, ap, np_ = load(alt, "dashboard.py"), load(neu, "dashboard.py"), load(alt, "prepper_docs.py"), load(neu, "prepper_docs.py")
    if cmd == "check":
        e = chk(ad, nd, ap, np_, docs, blk)
        if e:
            print("\n".join("VERSTOSS " + x for x in e)); sys.exit(1)
        print("Guard funkFlach ok: dashboard.py nur Block vor __main__ (%d Zeilen), prepper_docs.py nur %d Textstellen, Block nur Anzeige (kein Senden/Netz/Prozess/Route/Datei), Sicherheitshinweise bleiben, keine Seriennummern"
              % (blk.count("\n"), len(docs)))
        return
    M = []
    def mb(a, b):
        return blk.replace(a, b, 1) if a in blk else None
    def nd_(b):
        return nd.replace(blk, b, 1)
    mut = [
        ("Block importiert subprocess", {"b": mb("import re as _ff_re\n", "import re as _ff_re\nimport subprocess as _ff_sp\n")}),
        ("Block mit neuer Route", {"b": mb("def _ff_after(resp):", "@app.route('/x')\ndef _ff_x():\n    return ''\n\n\ndef _ff_after(resp):")}),
        ("Stufe 16 aus Gain-Hinweis entfernt", {"b": mb("bei Fehlern Stufe 16 · Auto nur gemessen", "Auto nur gemessen")}),
        ("Standard-Gain-Hinweis entfernt", {"b": mb('"Test ändert den Standard-Gain nie · Abbruch bei Alarm/ASA/Sperre"', '"Antennentest"')}),
        ("Seite /pi ergaenzt", {"b": mb('_FF_PAGES = ("/funk", "/karte")', '_FF_PAGES = ("/funk", "/karte", "/pi")')}),
        ("Seriennummer im Block", {"b": mb("# ===== /funkFlach =====", "# 87654321\n# ===== /funkFlach =====")}),
        ("Selbsttest kaputt", {"b": mb('    assert tx("/funk", "body", "SNR 10,0', '    assert 0 and tx("/funk", "body", "SNR 10,0')}),
        ("Regel setzt Skript ein", {"b": mb('"Kacheln fehlen (prepper-tiles-teil4.sh)"', '"<script>x</script>Kacheln fehlen"')}),
        ("Skript mit Abruf", {"b": mb("run();var mo=", "fetch('/x');run();var mo=")}),
        ("Skript klickt", {"b": mb("if(x!==t)el.textContent=x;", "if(x!==t)el.textContent=x;el.click();")}),
        ("Seitenweite Regel ersetzt Text", {"b": mb('("/funk", "body", "t", r" · SN [0-9A-F]{6,20}", "")', '("/funk", "body", "t", r" · SN [0-9A-F]{6,20}", " x")')}),
        ("CSS fuer /umwelt", {"b": mb('    "/karte": (".kv-tick,', '    "/umwelt": "x{}",\n    "/karte": (".kv-tick,')}),
        ("Block schreibt Datei", {"b": mb("        _FF[\"n\"] += 1\n", "        _FF[\"n\"] += 1\n        open('/tmp/x', 'w')\n")}),
        ("andere Zeile in dashboard.py geaendert", {"d": nd.replace("\n", "\n#x\n", 1)}),
        ("Block nicht vor __main__", {"d": nd.replace("\n\n" + blk + A, A, 1).replace("\n", "\n\n" + blk + "\n", 1)}),
        ("Zusatzaenderung prepper_docs.py", {"p": np_.replace("GEN_VERSION = \"3\"", "GEN_VERSION = \"4\"", 1)}),
        ("Docs-Textstelle fehlt", {"p": np_.replace(docs[1][1], docs[1][0], 1)}),
    ]
    bad = 0
    for name, m in mut:
        b = m.get("b", blk)
        if b is None:
            print("FEHLER Mutation %s: Ankerstelle fehlt" % name); bad += 1; continue
        d2 = m.get("d", nd_(b) if "b" in m else nd); p2 = m.get("p", np_)
        e = chk(ad, d2, ap, p2, docs, b)
        print(("erkannt  " if e else "UEBERSEHEN ") + name + (": " + e[0][:80] if e else ""))
        bad += 0 if e else 1
    print("Mutationstest funkFlach: %d/%d erkannt" % (len(mut) - bad, len(mut)))
    sys.exit(1 if bad else 0)


main()
MK_GRD_EOF
for x in "$EXPECT_EDT $W/edits.py" "$EXPECT_PPK $W/patch.py" "$EXPECT_BLK $W/blk.py" "$EXPECT_GRD $W/guard.py"; do
  read -r xs xf <<< "$x"; echo "$xs  $xf" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$xf") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Stellen, Patcher, Block, Pruefprogramm)"
# ---------- 1) Basis ----------
for f in "${FILES[@]}" "${!KEEP60[@]}"; do [[ -f "$DASH_DIR/$f" ]] || stop "$f fehlt im Projektordner $DASH_DIR"; done
P59=""
for f in "${!PRE60[@]}"; do [[ "$(s16 "$DASH_DIR/$f")" == "${PRE60[$f]}" ]] && P59+="$f "; done
if [[ -n "$P59" ]]; then
  echo "STOP: erst commit60 einspielen - ${P59}ist noch der Stand vor commit60 (Zielstand commit59). commit61 baut auf commit60 auf - nichts geaendert."
  exit 1
fi
NA=0; NN=0; ODD=""
for f in "${FILES[@]}"; do
  h=$(s16 "$DASH_DIR/$f")
  if [[ "$h" == "${ALT[$f]}" ]]; then NA=$((NA + 1)); elif [[ "$h" == "${NEU[$f]}" ]]; then NN=$((NN + 1)); else ODD+="$f=$h (erwartet ${ALT[$f]} oder ${NEU[$f]}) "; fi
done
[[ -z "$ODD" ]] || stop "Stand weicht ab: ${ODD}- erwartet Zielstand commit60 oder schon commit61. Bitte diese Ausgabe an Grok schicken"
KODD=""
for f in "${!KEEP60[@]}"; do h=$(s16 "$DASH_DIR/$f"); [[ "$h" == "${KEEP60[$f]}" ]] || KODD+="$f=$h (erwartet ${KEEP60[$f]}) "; done
[[ -z "$KODD" ]] || stop "Stand weicht ab: ${KODD}- commit61 braucht den Zielstand commit60. Bitte diese Ausgabe an Grok schicken"
if [[ "$NA" == 2 ]]; then STATE=alt; echo "OK Basis: Zielstand commit60 (dashboard.py ${ALT[dashboard.py]}, prepper_docs.py ${ALT[prepper_docs.py]}; prepper_sdr.py, sdr_manager.py, database.py, lage_pages.py, ups_manager.py, prepper_evlog.py wie commit59)"
elif [[ "$NN" == 2 ]]; then STATE=neu; echo "OK $NM ist schon installiert (beide Dateien im Zielstand)"
else
  echo "STOP: Mischstand (eine Datei commit60, eine commit61) - nichts geaendert."
  for f in "${FILES[@]}"; do LBX=$({ ls -1t "$DASH_DIR/$f.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LBX" ]] && echo "      Sicherung vorhanden: $(basename "$LBX") ($(s16 "$LBX"))"; done
  echo "      Ein abgebrochener Lauf? Bitte diese Ausgabe an Grok schicken (nichts von Hand kopieren)."
  STOPPED=1; exit 1
fi
[[ -w "$DASH_DIR" ]] || stop "Projektordner nicht beschreibbar"
for f in "${FILES[@]}"; do [[ -w "$DASH_DIR/$f" ]] || stop "$f ist nicht beschreibbar"; done
"$VPY" -c "import sys; assert sys.version_info >= (3, 9)" 2>/dev/null || stop "Python der venv ($VPY) ist aelter als 3.9 oder nicht startbar"
# ---------- 2) Sandbox (Kopien in $W) ----------
for f in "${FILES[@]}"; do cp "$DASH_DIR/$f" "$W/alt/"; done
python3 "$W/patch.py" "$W/alt" "$W/neu" "$W/edits.py" "$W/blk.py" > "$W/p.log" 2>&1 || { cat "$W/p.log"; stop "Textstellen nicht eindeutig"; }
if [[ "$STATE" == alt ]]; then
  for f in "${FILES[@]}"; do h=$(s16 "$W/neu/$f"); [[ "$h" == "${NEU[$f]}" ]] || stop "Ergebnis $f $h statt ${NEU[$f]} (Zielstand nicht erreicht)"; done
  echo "OK Ergebnis wie erwartet: dashboard.py ${NEU[dashboard.py]}, prepper_docs.py ${NEU[prepper_docs.py]} ($(cat "$W/p.log"))"
  python3 "$W/patch.py" "$W/neu" "$W/x" "$W/edits.py" "$W/blk.py" > /dev/null 2>&1 && cmp -s "$W/neu/dashboard.py" "$W/x/dashboard.py" && cmp -s "$W/neu/prepper_docs.py" "$W/x/prepper_docs.py" || stop "nicht idempotent (zweite Anwendung aendert eine Datei)"
  echo "OK idempotent (zweite Anwendung aendert nichts)"
  for py in "$SPY" "$VPY"; do
    for x in "$W"/neu/*.py "$W"/*.py; do
      "$py" -W error -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
    done
  done
  echo "OK py_compile ohne Warnung ($SPY und $VPY; ohne __pycache__)"
  nice -n 10 python3 "$W/guard.py" check "$W/alt" "$W/neu" "$W/edits.py" "$W/blk.py" > "$W/g.log" 2>&1 || { grep -v "^$MK aktiv" "$W/g.log" | cut -c1-200; stop "Guard $MK meldet Verstoss"; }
  echo "OK $(grep '^Guard' "$W/g.log" | cut -c1-260)"
  MUTS=1; [[ -n "${C61_SIM_NOMUT:-}" && "$SIM" == 1 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen"; }
  if [[ "$MUTS" == 1 ]]; then
    nice -n 10 python3 "$W/guard.py" mutate "$W/alt" "$W/neu" "$W/edits.py" "$W/blk.py" > "$W/gm.log" 2>&1 || { grep -E "UEBERSEHEN|FEHLER" "$W/gm.log" | cut -c1-120; stop "Mutationstest $MK: eine Verfehlung wurde nicht erkannt"; }
    echo "OK $(grep -E '^Mutationstest' "$W/gm.log")"
  fi
fi
for py in "$SPY" "$VPY"; do
  ( cd "$W" && PYTHONDONTWRITEBYTECODE=1 timeout 60 "$py" "$W/blk.py" ) > "$W/st.log" 2>&1 || true
  grep -q "^$MK aktiv: $MK ok" "$W/st.log" || { cut -c1-200 "$W/st.log"; stop "Selbsttest $MK mit $py fehlgeschlagen"; }
done
echo "OK Selbsttest Block (Sandbox, System- und venv-Python): $(grep "^$MK aktiv" "$W/st.log" | head -1 | cut -c1-180)"
# ---------- 3) Zustand vorher (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep "${C61_RETRY_S:-6}"; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte /lokale-energie)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status /api/usv /api/docs/list)
SFP=(/funk /karte)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
# Probe mit den echten Seiten (nur Lesen): Block in der Sandbox auf das HTML von jetzt anwenden
pnm() { local p="$1"; [[ "$p" == / ]] && echo start || echo "${p#/}"; }
for p in "${SFP[@]}"; do "${CURL[@]}" "$B$p" -o "$W/html/$(pnm "$p").html" || true; done
PROBE=$(cd "$W" && PYTHONDONTWRITEBYTECODE=1 timeout 120 nice -n 10 python3 - "$W/blk.py" "$W/html" "$STATE" "${SFP[@]}" << 'PY' 2>&1
import os, re, sys
bf, hd, state = sys.argv[1:4]
import contextlib, io
g = {"__name__": "probe"}
with contextlib.redirect_stdout(io.StringIO()):
    exec(compile(open(bf, encoding="utf-8").read(), bf, "exec"), g)
def bal(html):
    t = re.sub(r"(?is)<(script|style)\b[^>]*>.*?</\1>", "", html)
    return len(re.findall(r"<div\b", t)) - t.count("</div>")
tot, out, bad = 0, [], []
for p in sys.argv[4:]:
    fn = os.path.join(hd, ("start" if p == "/" else p[1:]) + ".html")
    try:
        s = open(fn, encoding="utf-8", errors="replace").read()
    except Exception:
        s = ""
    if not s:
        out.append("%s=leer" % p); continue
    if state == "neu":
        out.append("%s=%s" % (p, "aktiv" if 'id="ff-css"' in s else "OHNE")); bad += [p] if 'id="ff-css"' not in s else []; continue
    n, h = g["_ff_apply"](p, s)
    k = sum(v for v in h.values() if v > 0); tot += k
    if 'id="ff-css"' not in n or 'id="ff-js"' not in n or abs(bal(n)) > abs(bal(s)):
        bad.append(p)
    out.append("%s=%d" % (p, k))
print(" ".join(out)); print("SUMME %d %s" % (tot, ",".join(bad) or "-"))
PY
) || true
echo "Probe mit den Seiten von jetzt (Sandbox, Textstellen je Seite): $(echo "$PROBE" | head -1 | cut -c1-300)"
PBAD=$(echo "$PROBE" | sed -n 's/^SUMME [0-9]* //p')
[[ "$PBAD" == "-" ]] || stop "Probe: auf ${PBAD:-?} waere die Kachel-Struktur schlechter als vorher (oder Probe nicht lesbar: $(echo "$PROBE" | tail -1 | cut -c1-120))"
for u in prepper-dashboard; do a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a)" || stop "Dienst $u ist nicht aktiv ($a)"; }; done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A ACT0 AET0
for u in $SVCS; do ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f b; for f in "$DASH_DIR"/*.py; do b=$(basename "$f"); [[ " ${FILES[*]} " == *" $b "* ]] || echo "$b $(s16 "$f")"; done; }
others > "$W/others0.txt"
docls() { { ls -1 "$DOCS" 2>/dev/null || true; } | sha256sum | cut -c1-16; }
DOCS_LS0=$(docls)
docsj() { "${CURL[@]}" "$B/api/docs/list" 2>/dev/null | python3 -c '
import sys, json
try:
    j = json.load(sys.stdin)
    print("ok=%s current=%s n=%d" % (j.get("ok"), j.get("current"), len(j.get("versions") or [])))
except Exception:
    print("unlesbar")
' 2>/dev/null || echo "unlesbar"; }
DOCSJ0=$(docsj)
echo "Projektbeschreibung vorher: $DOCSJ0"
if [[ "$STATE" == neu ]]; then
  MISS=""; for p in "${SFP[@]}"; do grep -q 'id="ff-css"' "$W/html/$(pnm "$p").html" 2>/dev/null || MISS+="$p "; done
  if [[ -z "$MISS" ]]; then FINISHED=1; echo "OK $MK laeuft schon auf allen ${#SFP[@]} Seiten - nichts geaendert, kein Neustart"; echo "COMMIT $COMMIT_ARG funkflach=1 fertig (schon installiert, nichts geaendert)"; exit 0; fi
  stop "$NM ist installiert, aber auf ${MISS}nicht aktiv (Dashboard noch nicht neu gestartet?). Bitte diese Ausgabe an Grok schicken"
fi
# ---- Neustart-Sperre HH:55-HH:04 (Berlin), geprueft jetzt und fuer die naechsten 300 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C61_FAKE_HM:-}" && "$SIM" == 1 ]]; then hm="$C61_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 300)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04, Vorlauf 5 min) - frei ab HH:05"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - Sperre HH:55-HH:04 (mit 5 min Vorlauf: Start ab HH:50 gesperrt) - prepper-dashboard wird jetzt nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04, auch in 5 min ($1)"; fi; }
rscheck "Vorpruefung"
if [[ "$DRY" == 1 ]]; then
  FINISHED=1
  echo "TROCKENLAUF fertig - nichts installiert, kein Neustart, nichts nach docs/ geschrieben, nichts gesendet."
  echo "  Ein echter Lauf wuerde: dashboard.py und prepper_docs.py ersetzen (Sicherungen DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, ${#PAGES[@]} Seiten und ${#APIS[@]} APIs pruefen, einmal python3 prepper_docs.py (neue Version in docs/); eine sudo-Passwortabfrage."
  echo "COMMIT $COMMIT_ARG funkflach=dry fertig"
  exit 0
fi
sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart und das Lesen des Journals erforderlich"
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
# ---------- 4) Installieren + Neustart ----------
trap '' INT
waitd() { local i; for i in $(seq 1 80); do sleep "${C61_WAIT_S:-3}"; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done; return 1; }
rb() {
  set +e +o pipefail
  trap - ERR
  RB_DONE=1
  echo "ROLLBACK: $1"
  local x f bn dok=1
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung - von Hand: cp -a $x.bak-$NM-$TS $x"; }; done
  if [[ "$GEN_RAN" == 1 && -d "$W/docs0" ]]; then
    for f in "$DOCS"/*; do [[ -e "$f" ]] || continue; bn=$(basename "$f"); [[ -e "$W/docs0/$bn" ]] || rm -f -- "$f" || dok=0; done
    for f in "$W/docs0"/*; do [[ -e "$f" ]] || continue; bn=$(basename "$f"); [[ -e "$DOCS/$bn" ]] || cp -p "$f" "$DOCS/$bn" || dok=0; done
    [[ "$dok" == 1 && "$(docls)" == "$DOCS_LS0" ]] && echo "  docs/ wie vorher (neue Versionsdateien entfernt)" || echo "  WARNUNG docs/ nicht sicher wie vorher - Vorher-Kopie liegt in $W/docs0"
  fi
  if [[ "$RESTARTED" == 1 ]]; then sudo systemctl restart prepper-dashboard.service 9>&-; waitd; fi
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
  echo "  Datenbank, prepper-sdr und Mesh-Bruecken wurden nicht veraendert; beim Einspielen wurde nichts gesendet"
}
rbx() { rb "$1"; exit 1; }
rscheck "unmittelbar vor dem Ersetzen"
PHASE=installiert
T0D=$(date +%s)
for f in "${FILES[@]}"; do
  x="$DASH_DIR/$f"
  cp -a "$x" "$x.bak-$NM-$TS"
  cmp -s "$x" "$x.bak-$NM-$TS" || rbx "Sicherung $f ungleich Original"
  { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
done
echo "OK Sicherungen *.bak-$NM-$TS (behalten: letzte $KEEP_LAST)"
for f in prepper_docs.py dashboard.py; do
  x="$DASH_DIR/$f"
  INST+=("$x")
  cp "$W/neu/$f" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rbx "$f installieren"; }
  [[ "$(s16 "$x")" == "${NEU[$f]}" ]] || rbx "$f nach dem Kopieren falsch ($(s16 "$x"))"
done
echo "OK dashboard.py und prepper_docs.py atomar ersetzt"
RESTARTED=1
echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) ..."
sudo systemctl restart prepper-dashboard.service 9>&-
waitd || rbx "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"
echo "OK prepper-dashboard aktiv, HTTP 200"
# ---------- 5) Pruefung ----------
for p in "${PAGES[@]}" "${APIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rbx "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs antworten wie vorher ($(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
MISS=""; for p in "${SFP[@]}"; do "${CURL[@]}" "$B$p" -o "$W/h1.html" || true; grep -q 'id="ff-css"' "$W/h1.html" || MISS+="$p "; done
[[ -z "$MISS" ]] || rbx "$MK auf ${MISS}nicht aktiv"
for p in / /pi /umwelt /funk433 /mesh; do "${CURL[@]}" "$B$p" -o "$W/h1.html" || true; grep -q 'id="ff-css"' "$W/h1.html" && rbx "$MK greift auf $p (darf es nicht)"; done
MISS2=""; for p in / /pi /funk433 /mesh; do "${CURL[@]}" "$B$p" -o "$W/h1.html" || true; grep -q 'id="sf-css"' "$W/h1.html" || MISS2+="$p "; done
[[ -z "$MISS2" ]] || rbx "seitenFlach (commit60) fehlt nach commit61 auf ${MISS2}"
echo "OK $MK aktiv auf /funk und /karte; andere Seiten ohne ff-css; seitenFlach weiter aktiv"
"${CURL[@]}" "$B/funk" -o "$W/funk1.html" || true
python3 - "$W/funk1.html" << 'PY' || rbx "/funk: funkFlach-JS/CSS fehlt oder Seriennummer-Regel fehlt"
import sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
assert 'id="ff-js"' in s and 'id="ff-css"' in s
assert "SN [0-9A-F]" in s
PY
echo "OK /funk: funkFlach-CSS/JS eingebettet (Seriennummern-Regel vorhanden)"
"${CURL[@]}" "$B/karte" -o "$W/karte1.html" || true
grep -q 'id="ff-js"' "$W/karte1.html" || rbx "/karte: ff-js fehlt"
echo "OK /karte: funkFlach-CSS/JS eingebettet"
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -n 20000 -o cat || true)
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then echo "HINWEIS Journal nicht lesbar - Journal-Pruefung uebersprungen"
else
  E2=$(echo "$JD" | grep -c -E "Traceback|Selbsttest FEHLER|$MK FEHLER" || true)
  [[ "${E2:-0}" == 0 ]] || rbx "$E2 Zeile(n) mit Traceback/FEHLER im Journal prepper-dashboard seit dem Neustart"
  echo "$JD" | grep -q "^$MK aktiv: $MK ok" || rbx "Journal: Zeile '$MK aktiv: $MK ok' fehlt"
  echo "OK Journal prepper-dashboard seit dem Neustart ohne Traceback; $(echo "$JD" | grep "^$MK aktiv" | tail -1 | cut -c1-120)"
fi
# ---- Projektbeschreibung neu erzeugen (einmal; liest nur, schreibt nur docs/) ----
CHK=$(cd "$DASH_DIR" && PRDOCS_OUT="$W/chk-out" timeout 120 nice -n 10 python3 "$DASH_DIR/prepper_docs.py" --check --no-live 2>&1) || rbx "python3 prepper_docs.py --check --no-live schlaegt fehl: $(echo "$CHK" | tail -2 | tr '\n' ' ' | cut -c1-200)"
echo "$CHK" | grep -q "Trockenlauf (--check): nichts geschrieben" || rbx "prepper_docs.py --check meldet den Trockenlauf nicht"
mkdir -p "$DOCS"; rm -rf "$W/docs0"; cp -a "$DOCS" "$W/docs0" || rbx "Vorher-Kopie von docs/ nicht moeglich"
GEN_RAN=1
GOUT=$(cd "$DASH_DIR" && timeout 600 nice -n 10 python3 "$DASH_DIR/prepper_docs.py" 2>&1) || { echo "$GOUT" | tail -5 | sed 's/^/   | /'; rbx "python3 prepper_docs.py (Erzeugen) schlaegt fehl"; }
NEWV=$(echo "$GOUT" | sed -n 's/^OK Version v\([0-9-]*\):.*/\1/p' | head -1)
if [[ -n "$NEWV" ]]; then echo "OK neue Projektbeschreibung v$NEWV in docs/ erzeugt"
elif echo "$GOUT" | grep -q "UNVERAENDERT"; then echo "OK Projektbeschreibung UNVERAENDERT (Stand schon erzeugt)"
else echo "$GOUT" | tail -5 | sed 's/^/   | /'; rbx "python3 prepper_docs.py meldet weder eine neue Version noch UNVERAENDERT"; fi
DOCSJ1=$(docsj); CUR=$(echo "$DOCSJ1" | sed -n 's/.*current=\([0-9-]*\).*/\1/p')
[[ -n "$CUR" ]] || rbx "/api/docs/list zeigt keine Version ($DOCSJ1)"
if [[ -n "$NEWV" ]]; then [[ "$CUR" == "$NEWV" ]] || rbx "/api/docs/list zeigt nicht die neue Version (current=$CUR, erwartet $NEWV)"; fi
"${CURL[@]}" "$B/api/docs/download?fmt=txt&v=$CUR" -o "$W/doc.txt" || true
grep -q "funkFlach (commit61)" "$W/doc.txt" || rbx "Projektbeschreibung v$CUR enthaelt den Abschnitt funkFlach nicht"
echo "OK /api/docs/list: $DOCSJ1; Download v$CUR enthaelt funkFlach"
others > "$W/others1.txt"; cmp -s "$W/others0.txt" "$W/others1.txt" || rbx "andere Programmdateien haben sich veraendert"
for u in $SVCS; do
  [[ "$u" == prepper-dashboard ]] && continue
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]}, jetzt $a)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard neu gestartet; prepper-sdr und Mesh-Bruecken unveraendert"
echo "OK Datenbank, prepper-sdr, Sende- und Alarmregeln unberuehrt; nichts gesendet"
PHASE=fertig
FINISHED=1
echo "Rueckweg von Hand (nur bei Bedarf):"
echo "  cd $DASH_DIR && cp -a dashboard.py.bak-$NM-$TS dashboard.py && cp -a prepper_docs.py.bak-$NM-$TS prepper_docs.py && sudo systemctl restart prepper-dashboard"
echo "COMMIT $COMMIT_ARG funkflach=1 fertig dashboard=${NEU[dashboard.py]} prepper_docs=${NEU[prepper_docs.py]} docs=v$CUR dauer=$(( $(date +%s) - T0D ))s"
