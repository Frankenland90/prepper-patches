#!/bin/bash
# shellcheck disable=SC2015
set -eEuo pipefail
# seitenFlach (commit60): die uebrigen Seiten flach und kurz wie /umwelt (commit53) - NUR ANZEIGE, sendet nichts:
#  Seiten /, /pi, /funk433, /aprs, /meteor, /rundfunk, /energie, /lokale-energie, /dabhist, /mesh (/funk und /karte folgen mit commit61).
#  - keine Kachel in der Kachel (Bedienelemente zaehlen nicht); /pi: Internet-Kachel richtig geschlossen, Systemstatus/Dienste/Watchdog/SSD/SD wieder eigene Kacheln
#  - lange Erklaertexte auf eine kurze Zeile; Sicherheitshinweise gekuerzt behalten; Datentexte (Warnungen, Ereignisse) bleiben vollstaendig
#  - /pi unten unveraendert: Audio, Sicherung (vorletzte), Projektbeschreibung (letzte Kachel)
#  dashboard.py: ein Block vor __main__ (after_request als letzter Schritt, nur fertiges HTML dieser Seiten); prepper_docs.py: 3 Textstellen (Beschreibung).
#  Danach einmal python3 prepper_docs.py (neue Version der Projektbeschreibung in docs/).
# Aufruf: bash /tmp/apply-commit60.sh commit60 [dry-run]   (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein Neustart)
# Basis streng (sha16, Zielstand commit59): dashboard.py 2d0412bbbecc25b3, prepper_docs.py 2e1e23726611b2ec; Ziel dashboard.py b4b727de851587c7, prepper_docs.py 1bf7c89d85e36169.
#  Unveraendert und vorausgesetzt (commit59): prepper_sdr.py b879ab56f4ac4736, sdr_manager.py 5a26efff608bf541, database.py 2754d0bdddca9400. Stand vor commit59 -> STOP (erst commit59).
# Neustart: nur prepper-dashboard, Sperre HH:55-HH:04 (Start ab HH:50 gesperrt). Datenbank, prepper-sdr, Mesh-Bruecken bleiben unberuehrt.
# Fehler -> Rollback: beide Dateien aus DATEI.bak-commit60-ZEIT, docs/ wie vorher, prepper-dashboard erneut neu gestartet.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
W=/tmp/commit60-apply
NM=commit60
MK=seitenFlach
SIM=0; [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && SIM=1
if [[ "$SIM" == 1 ]]; then DASH_DIR="${C60_SIM_DIR:-$DASH_DIR}"; W="${C60_SIM_W:-$W}"; fi
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
KEEP_LAST=3
FILES=(dashboard.py prepper_docs.py)
declare -A ALT=([dashboard.py]=2d0412bbbecc25b3 [prepper_docs.py]=2e1e23726611b2ec)
declare -A NEU=([dashboard.py]=b4b727de851587c7 [prepper_docs.py]=1bf7c89d85e36169)
declare -A KEEP59=([prepper_sdr.py]=b879ab56f4ac4736 [sdr_manager.py]=5a26efff608bf541 [database.py]=2754d0bdddca9400 [lage_pages.py]=a9740c629a41806c [ups_manager.py]=ef0b9e3d4bf42003 [prepper_evlog.py]=8bffd396972b60fa)
# Stand vor commit59 (Zielstand commit58) - dann erst commit59
declare -A PRE59=([dashboard.py]=7d494c1a21e50e96 [prepper_docs.py]=43032d218135e329 [prepper_sdr.py]=264ef34996e17753 [sdr_manager.py]=6dd122356d8f3ae1 [database.py]=e7a7ef192c522480)
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
echo "=== $MK apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): uebrige Seiten flach und kurz (nur Anzeige), Dashboard-Port $PORT ==="
umask 022
mkdir -p "$(dirname "$W")"
exec 9>"$W.lock"
flock -n 9 || stop "ein anderer $NM-Lauf ist aktiv (Sperre $W.lock)"
rm -rf "$W" && mkdir -p "$W/neu" "$W/alt" "$W/x" "$W/html" && chmod 700 "$W"
EXPECT_EDT="b50e1b99a628efe90637642f4f34ba80290b9551b11a8712613c0a769362f06e"
cat > "$W/edits.py" << 'MK_EDT_EOF'
# commit60 seitenFlach - Textstellen in prepper_docs.py (je genau einmal; idempotent)
NAME = "seitenFlach"
DOCS = [
    ("Selbsttests mit neutralen Platzhaltern. Hier nachgetragen",
     "Selbsttests mit neutralen Platzhaltern; danach seitenFlach (60): uebrige Seiten flach und kurz (nur Anzeige). Hier nachgetragen"),
    ("| usvShutdown | Anzeige der Abschaltung durch upsmon (20 % oder 5 min, killpower); loest selbst nie etwas aus (commit57) |\n",
     "| usvShutdown | Anzeige der Abschaltung durch upsmon (20 % oder 5 min, killpower); loest selbst nie etwas aus (commit57) |\n"
     "| seitenFlach | Seiten /, /pi, /funk433, /aprs, /meteor, /rundfunk, /energie, /lokale-energie, /dabhist, /mesh flach und kurz: nur die fertige HTML-Antwort, after_request als letzter Schritt (commit60) |\n"),
    ("- Seit umweltFlach (commit53): ",
     "- Seit seitenFlach (commit60) gilt dasselbe fuer die uebrigen Seiten (/, /pi, /funk433, /aprs, /meteor, /rundfunk, /energie, /lokale-energie, /dabhist, /mesh): keine Kachel in der Kachel "
     "(Bedienelemente zaehlen nicht), lange Erklaertexte auf eine kurze Zeile, Sicherheitshinweise gekuerzt behalten (Nur Empfang, KATASTROPHE immer 100 %, Test nie ins Mesh, Rot nur bei amtlicher Warnung). "
     "Auf /pi schliesst die Internet-Kachel jetzt richtig, Systemstatus, Dienste, Watchdog, SSD und SD sind wieder eigene Kacheln; Reihenfolge unten bleibt Audio, Sicherung, Projektbeschreibung. "
     "Auf der Lage-Seite ist die Umschlag-Kachel um NINA/BR24 und die leere Mesh-Waechter-Kachel weg. Arbeitet nur auf dem fertigen HTML (Textstellen exakt); fehlt eine Stelle, bleibt sie wie bisher. "
     "Datentexte (Warnungen, Ereignisse, BR24-Empfangszeile) bleiben vollstaendig.\n- Seit umweltFlach (commit53): "),
]
MK_EDT_EOF
EXPECT_PPK="68a616d74568772bbb05a291294e6cec2af8837322ba78cf5daac56dd7e374c2"
cat > "$W/patch.py" << 'MK_PPK_EOF'
#!/usr/bin/env python3
"""patch60.py SRC DST EDITS BLK - baut dashboard.py (Block vor __main__) und prepper_docs.py (Textstellen) fuer commit60.
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
mk = "# ===== %s (commit60)" % NM
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
EXPECT_BLK="982dfee9b26e2640940e141db88423515b980470a0245c760d5dce8e7595dcb4"
cat > "$W/blk.py" << 'MK_BLK_EOF'
# ===== seitenFlach (commit60): Seiten /, /pi, /funk433, /aprs, /meteor, /rundfunk, /energie, /lokale-energie, /dabhist, /mesh aufgeraeumt - nur Anzeige =====
# Wie /umwelt (commit53): keine Kachel in der Kachel, lange Erklaertexte gekuerzt (Sicherheitshinweise kurz behalten), fehlende </div> geschlossen.
# Arbeitet nur auf der fertigen HTML-Antwort der genannten Seiten (after_request, Textstellen exakt bzw. eng umrissen); Funktionen, APIs, Senden und Daten bleiben unveraendert.
# Fehlt eine Stelle (andere Daten, anderer Stand), bleibt sie wie bisher - nie Fehler, nie leere Seite.
import re as _sf_re

_SF_PAGES = ("/", "/pi", "/funk433", "/aprs", "/meteor", "/rundfunk", "/energie", "/lokale-energie", "/dabhist", "/mesh")
_SF_CSS = {
    "/energie": ".metal-item{background:transparent!important;border-radius:0!important;padding:8px 0!important;border-top:1px solid #1e293b}",
    "/dabhist": (".fu-ev{background:transparent!important;border-top:0!important;border-right:0!important;border-radius:0!important;"
                 "border-bottom:1px solid #1e293b!important;margin:0!important;padding:8px 0 8px 10px!important}"),
    "/mesh": "#log{background:transparent!important;border:0!important;border-top:1px solid #2a3b55!important;border-radius:0!important;padding:8px 0!important}",
}
# (Seite, Art s=Text/r=Muster, alt, neu)
_SF_RULES = [
    # Lage: Umschlag-Kachel um NINA/BR24 ist keine Kachel mehr; ueberzaehliges <div> vor "Ruecknahme Mesh"/"Mesh gesendet" entfernt
    ("/", "r", r'<div class="card full">(\s*)(<div class="card full">\s*<div class="title">NINA Warnungen</div>)', r'<div style="display:contents">\1\2'),
    ("/", "r", r'<div style="color:#94a3b8">(?=\s*<div style="color:#94a3b8">(?:Rücknahme Mesh|Mesh gesendet))', ""),
    # Lage: leere Kachel (nur Skripte fuer den Mesh-Waechter, ohne sichtbaren Inhalt) ausgeblendet - Skripte laufen weiter
    ("/", "r", r'<div class="card full" style="padding:10px;text-align:center">(\s*<script>\s*async function refreshMeshWatch\(\))', r'<div style="display:none">\1'),
    # System: Internet-Kachel - nicht geschlossenes <div> (Systemstatus, Dienste, Watchdog, SSD und SD hingen darin)
    ("/pi", "s", '<div class="small">Starlink = Ausfallschutz (ASN/ISP) · Download nur periodisch / manuell\n',
     '<div class="small">Starlink = Ausfallschutz · Download periodisch / manuell</div>\n'),
    ("/pi", "s", "'letzter Fehler '+when(d.last_error.t)+': '+(d.last_error.msg||'').slice(0,80)",
     "'letzter Fehler '+when(d.last_error.t)+': '+(d.last_error.msg||'').split(':')[0].slice(0,40)"),
    ("/pi", "r", r'(<div style="font-size:0\.82rem;line-height:1\.35;overflow-wrap:anywhere"><span style="color:#[0-9a-f]{3,6}">●</span> [^<]*?) · (10C-Prüfung alle [^<]*)</div>',
     r'\1</div><div class="small" style="margin-left:14px;color:#94a3b8;overflow-wrap:anywhere">\2</div>'),
    ("/pi", "r", r'>Automatik (an|AUS) · gelb ([0-9.]+) min · Neustart ([0-9.]+) min · USB ([0-9.]+) min \(max [0-9.]+\) · Pi-Neustart ([0-9.]+) min, max 1 je [0-9.]+ min, Stopp nach [0-9.]+ ohne Erfolg · Hilfsprogramm ([^<]{0,20})<',
     r'>Automatik \1 · gelb \2 · Neustart \3 · USB \4 · Pi \5 min · Hilfsprogramm \6<'),
    ("/pi", "s", '<div class="aui-note">KATASTROPHE (echter Alarm) spielt immer mit 100 %, auch stumm und nachts, danach zur&uuml;ck auf den Regler. Stumm gilt nur f&uuml;r INFO/WARNUNG und endet nach 8 h von selbst. Test: Gong + kurze Ansage mit Regler-Pegel, nie ins Mesh, h&ouml;chstens alle 10 s.</div>',
     '<div class="aui-note">KATASTROPHE immer 100 % (auch stumm/nachts) · Stumm nur INFO/WARNUNG, max 8 h</div><div class="aui-note">Test: Gong + Ansage, nie ins Mesh, max alle 10 s</div>'),
    ("/pi", "r", r' · Dateiname: [^<]{1,120}</div>', "</div>"),
    ("/pi", "r", r'>Neue Version: auf dem Pi python3 prepper_docs\.py \(Ordner [^<]{1,160}\)</div>', ">Neue Version: python3 prepper_docs.py im Projektordner</div>"),
    # 433 MHz / KFZ
    ("/funk433", "s", "'Grün < 10 min · Gelb < 1 h · Grau älter. Nur ISM-Sensoren (Wetter, Thermometer); fremde Sensoren der Nachbarn erscheinen ebenfalls. Liste 14 Tage.'",
     "'Grün < 10 min · Gelb < 1 h · Grau älter · auch Nachbar-Sensoren · 14 Tage'"),
    ("/funk433", "s", "'Volle IDs 30 Tage, danach nur Modell + Zeit; eigene (kfz_own.json) dauerhaft. Zeit dd.mm.yyyy HH:MM:SS Europe/Berlin, S1/S2 = Stratum laut chrony, ungenau = nicht synchron.'",
     "'IDs 30 Tage, danach nur Modell · eigene dauerhaft · ungenau = Uhr nicht synchron'"),
    # APRS (Hinweis Nur Empfang bleibt)
    ("/aprs", "s", "'Noch keine APRS-Pakete. 144,800 MHz läuft im Wechsel mit 433 MHz (je 5 min); mit der Stab-/Discone-Antenne im Freien sind 20-80 km üblich.'",
     "'Noch keine APRS-Pakete (144,800 MHz)'"),
    ("/aprs", "s", "'Öffentlicher Amateurfunk (APRS). Nur Empfang – das Dashboard sendet nichts. Entfernung ab Heimatposition '",
     "'Nur Empfang – sendet nichts · Entfernung ab '"),
    # Meteor
    ("/meteor", "s", '<div class="fu-note">Während eines Überflugs hat Meteor Vorrang vor 433/APRS (137,9 MHz LRPT). Gute Bilder brauchen eine V-Dipol- oder QFH-Antenne im Freien. Betriebsart und Schalter: auf der Funk-Seite.</div>',
     '<div class="fu-note">Überflug hat Vorrang vor 433/APRS · Antenne V-Dipol/QFH im Freien</div>'),
    ("/meteor", "s", "Keine Vorhersage – noch keine Bahndaten. Der Planer holt sie, sobald Internet da ist, und rechnet danach offline weiter.",
     "Keine Vorhersage – Bahndaten kommen mit Internet"),
    # Rundfunk: Hinweis-Kachel auf eine Zeile
    ("/rundfunk", "s", "'Hinweis: TA ist nur ein Kennzeichen „Verkehrsdurchsage läuft“ im Audio. Der gesprochene Inhalt wird nicht als Text gesendet – hier steht nur, was der Sender zur selben Zeit als RadioText (RT) bzw. DAB-DLS schickt. Nur BR24-Texte und ASA DE (5C), andere Sender ausgeblendet; TA wird nicht markiert. Rot nur bei amtlicher Warnung (starker Begriff, 2 mittlere oder mittel + Verhaltensanweisung; RadioText erst wenn vollstaendig/stabil), Entwarnung beendet, Probewarnung = grau Test. Empfang nur in den kurzen Rundfunk-Blöcken bzw. bei Preset-Auswahl.'",
     "'Nur BR24 und ASA DE · Rot nur bei amtlicher Warnung · Probe = grau · TA ohne Text'"),
    # DAB-Meldungen
    ("/dabhist", "s", " · Rückfallkanal, Hobby-Prüfung alle 6 h</span>", "</span>"),
    ("/dabhist", "r", r'bekannte Masten ([0-9]+) von ([0-9]+) empfangen · unbekannte Kennungen ([0-9]+) angezeigt \([0-9]+ werden gesammelt\) · aktualisiert (vor [^<]{1,20})</div>',
     r'Masten \1/\2 empfangen · unbekannt \3 · \4</div>'),
    ("/dabhist", "r", r'>Herkunft der Masten: ([0-9]+) amtlich \(fmlist\.org\), ([0-9]+) nicht amtlich, ([0-9]+) nur beobachtet/unbekannt · Namen vor TII-Codes, amtliche Quellen vor MASTS_DB</div>',
     r'>Masten: \1 amtlich · \2 nicht amtlich · \3 beobachtet</div>'),
    ("/dabhist", "s", ">Herkunft der Koordinaten (nur Anzeige, ändert nichts an amtlich/nicht amtlich): ", ">Koordinaten: "),
    ("/dabhist", "r", r'<div class="fu-note">Programm-Infos \(Titel, Sendungstexte\) werden nicht mehr gespeichert, nur gezählt \(bisher ([0-9]+) verworfen\)\. BR24-Nachrichten, ASA und Warnungen bleiben\. Neueste 500 · Archiv: archive/dabhist/ und archive/techlog/</div>',
     r'<div class="fu-note">Programm-Infos nur gezählt (\1) · Warnungen bleiben · neueste 500</div>'),
]
_SF = {"hits": {}, "n": 0, "err": None, "selftest": None}


def _sf_apply(path, body):
    """-> (neuer Text, Treffer je Regel). Nie werfen."""
    hits = {}
    if path not in _SF_PAGES or 'id="sf-css"' in body:
        return body, hits
    for i, (pg, kind, old, new) in enumerate(_SF_RULES):
        if pg != path:
            continue
        try:
            if kind == "s":
                n = body.count(old)
                if n:
                    body = body.replace(old, new)
            else:
                body, n = _sf_re.subn(old, new, body)
            hits[i] = n
        except Exception:
            hits[i] = -1
    css = '<style id="sf-css">%s</style>' % _SF_CSS.get(path, "")
    j = body.find("</head>")
    if j < 0:
        j = body.rfind("</body>")
    if j >= 0:
        body = body[:j] + css + body[j:]
    return body, hits


def _sf_after(resp):
    try:
        from flask import request as rq
        if rq.path not in _SF_PAGES or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        nb, hits = _sf_apply(rq.path, body)
        if nb != body:
            resp.set_data(nb)
        _SF["hits"][rq.path] = hits
        _SF["n"] += 1
    except Exception as e:
        _SF["err"] = str(e)[:160]
    return resp


def _sf_selftest():
    a = '<div class="grid">\n  <div class="card full">\n    \n  <div class="card full">\n    <div class="title">NINA Warnungen</div>\n    <div class="small">\n      <div style="color:#94a3b8">\n      <div style="color:#94a3b8">Rücknahme Mesh · <b>x</b></div>\n      \n      <div style="color:#94a3b8">Mesh gesendet · <b>y</b></div>\n    </div>\n  </div>\n</div>\n</div><head></head>'
    b, h = _sf_apply("/", a.replace("<head></head>", "") + "</head>")
    assert b.count('<div class="card full">') == 1 and '<div style="display:contents">' in b and b.count("<div") == b.count("</div>"), b
    assert sorted(h.values()) == [0, 1, 1] and _sf_apply("/", b)[0] == b and 'id="sf-css"' in b                           # zweimal = einmal
    p = ('<div class="card"><div class="small">Starlink = Ausfallschutz (ASN/ISP) · Download nur periodisch / manuell\n<div><button>x</button></div>\n</div>'
         '<div style="font-size:0.82rem;line-height:1.35;overflow-wrap:anywhere"><span style="color:#22c55e">●</span> Stick 2 · Hobby: RDS ok (zuletzt RDS Bayern 1 18:58) · nur Beobachtung · 10C-Prüfung alle 6 h: Sync 18:57 (SNR 10.0) · von Stick 2 · Hobby</div>'
         '<div class="small" style="color:#94a3b8;overflow-wrap:anywhere">Automatik an · gelb 10 min · Neustart 30 min · USB 45 min (max 2) · Pi-Neustart 60 min, max 1 je 60 min, Stopp nach 3 ohne Erfolg · Hilfsprogramm bereit</div>'
         '<div class="small">erzeugt 24.10.2026 22:31 (Berlin) · TXT 192 KB · Markdown 146 KB · Dateiname: Projektbeschreibung Lage Pi v20261024-2231.txt</div>'
         '<div class="small">Neue Version: auf dem Pi python3 prepper_docs.py (Ordner /home/fmg/prepper-dashboard)</div></head>')
    q, h = _sf_apply("/pi", p)
    assert q.count("<div") + 0 == q.count("</div>") and "Automatik an · gelb 10 · Neustart 30 · USB 45 · Pi 60 min · Hilfsprogramm bereit<" in q, q
    assert ">10C-Prüfung alle 6 h: Sync 18:57 (SNR 10.0) · von Stick 2 · Hobby</div>" in q and "nur Beobachtung</div>" in q and "Dateiname" not in q and "/home/fmg" not in q, q
    for pg, kind, old, new in _SF_RULES:                                      # neue Texte kurz; Sicherheitshinweise bleiben
        if kind == "s" and "+" not in new:
            assert len(_sf_re.sub(r"<[^>]+>|&[a-z]+;", "", new)) < 90 or "</div><div" in new, new
    t = " ".join(n for _, _, _, n in _SF_RULES)
    assert "Nur Empfang – sendet nichts" in t and "nie ins Mesh" in t and "KATASTROPHE immer 100 %" in t and "Rot nur bei amtlicher Warnung" in t
    assert _sf_apply("/funk", "<head></head>x")[0] == "<head></head>x" and _sf_apply("/umwelt", "x")[0] == "x"         # andere Seiten unberuehrt
    return "seitenFlach ok (10 Seiten, %d Textstellen, Kachel in Kachel aufgeloest, lange Texte gekuerzt, Sicherheitshinweise kurz behalten, andere Seiten unberuehrt)" % len(_SF_RULES)


try:
    _SF["selftest"] = _sf_selftest()
    if "app" in globals() and not any(getattr(f, "__name__", "") == "_sf_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request_funcs.setdefault(None, []).insert(0, _sf_after)   # Flask ruft in umgekehrter Reihenfolge: so als letzter, nach allen anderen Einfuegungen
    print("seitenFlach aktiv: %s" % _SF["selftest"], flush=True)
except Exception as _sf_e:
    _SF["selftest"] = "FEHLER %s" % _sf_e
    print("seitenFlach FEHLER: %s - Seiten wie bisher" % _sf_e, flush=True)
# ===== /seitenFlach =====
MK_BLK_EOF
EXPECT_GRD="690970d81efe2845ebe2fb0719f51f06912d26f9fdf7b874a87bd9f608236207"
cat > "$W/guard.py" << 'MK_GRD_EOF'
#!/usr/bin/env python3
"""guard60.py check ALT NEU EDITS BLK | mutate ALT NEU EDITS BLK
Pruefprogramm commit60 seitenFlach: nur der Block vor __main__ (dashboard.py) und die 3 Textstellen (prepper_docs.py),
Block nur Anzeige (kein Senden, kein Netz, kein Prozess, keine Route, keine Datei), Sicherheitshinweise bleiben, keine Seriennummern."""
import ast, re, sys

A = '\n\nif __name__ == "__main__":\n'
SAFE = ["Nur Empfang", "nie ins Mesh", "KATASTROPHE", "Rot nur bei amtlicher Warnung", "sendet nichts"]
BAD_NAMES = {"subprocess", "socket", "requests", "urllib", "http", "os", "shutil", "sqlite3", "smtplib", "telegram", "threading", "open", "exec", "eval",
             "__import__", "compile", "send", "mesh_send", "post"}
PAGES_OK = {"/", "/pi", "/funk433", "/aprs", "/meteor", "/rundfunk", "/energie", "/lokale-energie", "/dabhist", "/mesh"}


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
            if any(m not in ("re",) for m in mods) and not (isinstance(n, ast.ImportFrom) and n.module == "flask" and [a.name for a in n.names] == ["request"]):
                err.append("Block importiert %s" % mods)
        if isinstance(n, ast.Name) and n.id in BAD_NAMES:
            err.append("Block nutzt %s" % n.id)
        if isinstance(n, ast.Attribute) and n.attr in ("route", "add_url_rule", "before_request", "system", "popen", "send", "post", "write_text", "write", "teardown_request"):
            err.append("Block nutzt .%s" % n.attr)
        if isinstance(n, (ast.Global, ast.Nonlocal)):
            err.append("Block aendert globale Namen")
    top = [n for n in t.body]
    for n in top:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and not n.name.startswith("_sf_"):
            err.append("Block definiert %s" % n.name)
        if isinstance(n, ast.Assign):
            for tg in n.targets:
                if not (isinstance(tg, ast.Name) and tg.id.startswith("_SF")):
                    err.append("Block weist %s zu" % ast.dump(tg)[:40])
    g = {"__name__": "guard60"}
    try:
        exec(compile(blk, "blk", "exec"), g)
    except Exception as e:
        return err + ["Block laeuft nicht: %s" % e]
    st = str(g.get("_SF", {}).get("selftest"))
    if not st.startswith("seitenFlach ok"):
        err.append("Selbsttest: %s" % st[:120])
    pages = set(g.get("_SF_PAGES", ()))
    if pages != PAGES_OK:
        err.append("Seitenliste %s" % sorted(pages ^ PAGES_OK))
    for pg, kind, old, new in g.get("_SF_RULES", []):
        if pg not in PAGES_OK:
            err.append("Regel fuer Seite %s" % pg)
        for s in SAFE:
            if s in old and s not in new:
                err.append("Sicherheitshinweis %r entfernt (%s)" % (s, pg))
        if re.search(r"(?i)<script|onclick|onerror|javascript:|fetch\(|/api/", new):
            err.append("Regel setzt Skript/Abruf ein (%s)" % pg)
    for k in g.get("_SF_CSS", {}):
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
        print("Guard seitenFlach ok: dashboard.py nur Block vor __main__ (%d Zeilen), prepper_docs.py nur %d Textstellen, Block nur Anzeige (kein Senden/Netz/Prozess/Route/Datei), Sicherheitshinweise bleiben, keine Seriennummern"
              % (blk.count("\n"), len(docs)))
        return
    M = []
    def mb(a, b):
        return blk.replace(a, b, 1) if a in blk else None
    def nd_(b):
        return nd.replace(blk, b, 1)
    mut = [
        ("Block importiert subprocess", {"b": mb("import re as _sf_re\n", "import re as _sf_re\nimport subprocess as _sf_sp\n")}),
        ("Block mit neuer Route", {"b": mb("def _sf_after(resp):", "@app.route('/x')\ndef _sf_x():\n    return ''\n\n\ndef _sf_after(resp):")}),
        ("Sicherheitshinweis Nur Empfang entfernt", {"b": mb("'Nur Empfang – sendet nichts · Entfernung ab '", "'Entfernung ab '")}),
        ("nie ins Mesh entfernt", {"b": mb("Test: Gong + Ansage, nie ins Mesh, max alle 10 s", "Test: Gong + Ansage, max alle 10 s")}),
        ("Seite /funk ergaenzt", {"b": mb('_SF_PAGES = ("/", ', '_SF_PAGES = ("/funk", "/", ')}),
        ("Seriennummer im Block", {"b": mb("# ===== /seitenFlach =====", "# 87654321\n# ===== /seitenFlach =====")}),
        ("Selbsttest kaputt", {"b": mb('assert _sf_apply("/funk", ', 'assert 0 and _sf_apply("/funk", ')}),
        ("Regel setzt Skript ein", {"b": mb("r'Masten \\1/\\2 empfangen", "r'<script>x</script>Masten \\1/\\2 empfangen")}),
        ("CSS fuer /umwelt", {"b": mb('    "/mesh": "#log{', '    "/umwelt": "x{}",\n    "/mesh": "#log{')}),
        ("Block schreibt Datei", {"b": mb("        _SF[\"n\"] += 1\n", "        _SF[\"n\"] += 1\n        open('/tmp/x', 'w')\n")}),
        ("andere Zeile in dashboard.py geaendert", {"d": nd.replace("\n", "\n#x\n", 1)}),
        ("Block nicht vor __main__", {"d": ad.replace(A, A + "    pass\n", 1)[:0] + nd.replace("\n\n" + blk + A, A, 1).replace("\n", "\n\n" + blk + "\n", 1)}),
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
    print("Mutationstest seitenFlach: %d/%d erkannt" % (len(mut) - bad, len(mut)))
    sys.exit(1 if bad else 0)


main()
MK_GRD_EOF
for x in "$EXPECT_EDT $W/edits.py" "$EXPECT_PPK $W/patch.py" "$EXPECT_BLK $W/blk.py" "$EXPECT_GRD $W/guard.py"; do
  read -r xs xf <<< "$x"; echo "$xs  $xf" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$xf") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Stellen, Patcher, Block, Pruefprogramm)"
# ---------- 1) Basis ----------
for f in "${FILES[@]}" "${!KEEP59[@]}"; do [[ -f "$DASH_DIR/$f" ]] || stop "$f fehlt im Projektordner $DASH_DIR"; done
P59=""
for f in "${!PRE59[@]}"; do [[ "$(s16 "$DASH_DIR/$f")" == "${PRE59[$f]}" ]] && P59+="$f "; done
if [[ -n "$P59" ]]; then
  echo "STOP: erst commit59 einspielen - ${P59}ist noch der Stand vor commit59 (Zielstand commit58). commit60 baut auf commit59 auf - nichts geaendert."
  exit 1
fi
NA=0; NN=0; ODD=""
for f in "${FILES[@]}"; do
  h=$(s16 "$DASH_DIR/$f")
  if [[ "$h" == "${ALT[$f]}" ]]; then NA=$((NA + 1)); elif [[ "$h" == "${NEU[$f]}" ]]; then NN=$((NN + 1)); else ODD+="$f=$h (erwartet ${ALT[$f]} oder ${NEU[$f]}) "; fi
done
[[ -z "$ODD" ]] || stop "Stand weicht ab: ${ODD}- erwartet Zielstand commit59 oder schon commit60. Bitte diese Ausgabe an Grok schicken"
KODD=""
for f in "${!KEEP59[@]}"; do h=$(s16 "$DASH_DIR/$f"); [[ "$h" == "${KEEP59[$f]}" ]] || KODD+="$f=$h (erwartet ${KEEP59[$f]}) "; done
[[ -z "$KODD" ]] || stop "Stand weicht ab: ${KODD}- commit60 braucht den Zielstand commit59. Bitte diese Ausgabe an Grok schicken"
if [[ "$NA" == 2 ]]; then STATE=alt; echo "OK Basis: Zielstand commit59 (dashboard.py ${ALT[dashboard.py]}, prepper_docs.py ${ALT[prepper_docs.py]}; prepper_sdr.py, sdr_manager.py, database.py, lage_pages.py, ups_manager.py, prepper_evlog.py wie commit59)"
elif [[ "$NN" == 2 ]]; then STATE=neu; echo "OK $NM ist schon installiert (beide Dateien im Zielstand)"
else
  echo "STOP: Mischstand (eine Datei commit59, eine commit60) - nichts geaendert."
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
  MUTS=1; [[ -n "${C60_SIM_NOMUT:-}" && "$SIM" == 1 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen"; }
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
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep "${C60_RETRY_S:-6}"; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte /lokale-energie)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status /api/usv /api/docs/list)
SFP=(/ /pi /funk433 /aprs /meteor /rundfunk /energie /lokale-energie /dabhist /mesh)
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
        out.append("%s=%s" % (p, "aktiv" if 'id="sf-css"' in s else "OHNE")); bad += [p] if 'id="sf-css"' not in s else []; continue
    n, h = g["_sf_apply"](p, s)
    k = sum(v for v in h.values() if v > 0); tot += k
    d0 = len(re.findall(r"<div\b", s)) - s.count("</div>"); d1 = len(re.findall(r"<div\b", n)) - n.count("</div>")
    if abs(d1) > abs(d0):
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
  MISS=""; for p in "${SFP[@]}"; do grep -q 'id="sf-css"' "$W/html/$(pnm "$p").html" 2>/dev/null || MISS+="$p "; done
  if [[ -z "$MISS" ]]; then FINISHED=1; echo "OK $MK laeuft schon auf allen ${#SFP[@]} Seiten - nichts geaendert, kein Neustart"; echo "COMMIT $COMMIT_ARG seitenflach=1 fertig (schon installiert, nichts geaendert)"; exit 0; fi
  stop "$NM ist installiert, aber auf ${MISS}nicht aktiv (Dashboard noch nicht neu gestartet?). Bitte diese Ausgabe an Grok schicken"
fi
# ---- Neustart-Sperre HH:55-HH:04 (Berlin), geprueft jetzt und fuer die naechsten 300 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C60_FAKE_HM:-}" && "$SIM" == 1 ]]; then hm="$C60_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
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
  echo "COMMIT $COMMIT_ARG seitenflach=dry fertig"
  exit 0
fi
sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart und das Lesen des Journals erforderlich"
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
# ---------- 4) Installieren + Neustart ----------
trap '' INT
waitd() { local i; for i in $(seq 1 80); do sleep "${C60_WAIT_S:-3}"; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done; return 1; }
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
MISS=""; for p in "${SFP[@]}"; do "${CURL[@]}" "$B$p" -o "$W/h1.html" || true; grep -q 'id="sf-css"' "$W/h1.html" || MISS+="$p "; done
[[ -z "$MISS" ]] || rbx "$MK auf ${MISS}nicht aktiv"
for p in /funk /karte /umwelt; do "${CURL[@]}" "$B$p" -o "$W/h1.html" || true; grep -q 'id="sf-css"' "$W/h1.html" && rbx "$MK greift auf $p (darf es nicht)"; done
echo "OK $MK aktiv auf ${#SFP[@]} Seiten, /funk, /karte und /umwelt unberuehrt"
"${CURL[@]}" "$B/pi" -o "$W/pi1.html" || true
python3 - "$W/pi1.html" << 'PY' || rbx "/pi: Reihenfolge unten nicht Audio, Sicherung, Projektbeschreibung (letzte Kachel)"
import re, sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
a, b, c = s.find('id="audioBox"'), s.find('id="backupBox"'), s.find('id="projDocBox"')
assert 0 <= a < b < c, (a, b, c)
assert not re.search(r'class="(?:card|pd-card)\b', s[s.find(">", c) + 1:]), "Kachel nach Projektbeschreibung"
PY
echo "OK /pi: Audio, Sicherung (vorletzte), Projektbeschreibung (letzte Kachel)"
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
grep -q "seitenFlach (commit60)" "$W/doc.txt" || rbx "Projektbeschreibung v$CUR enthaelt den Abschnitt seitenFlach nicht"
echo "OK /api/docs/list: $DOCSJ1; Download v$CUR enthaelt seitenFlach"
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
echo "COMMIT $COMMIT_ARG seitenflach=1 fertig dashboard=${NEU[dashboard.py]} prepper_docs=${NEU[prepper_docs.py]} docs=v$CUR dauer=$(( $(date +%s) - T0D ))s"
