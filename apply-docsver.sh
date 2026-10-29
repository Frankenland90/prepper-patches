#!/bin/bash
# shellcheck disable=SC2015
set -eEuo pipefail
# docsVer (commit38): prepper_docs.py (Generator der Projektbeschreibung) auf Generator-Version 2: Text "Stratum Offset (ntplib)" an 3 Stellen durch den chrony-Zeit-Offset ersetzt (clockOff commit35), neu: ninaFix (NINA-Zertifikatskette) und hideTexts, Marker-/Routen-/Dateizeilen, Docs-Version (GEN_VERSION 1 -> 2)
# Aufruf: bash /tmp/apply-docsver.sh commit38 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): prepper_docs.py 609f0a7f00ab586b (Stand vor docsVer) oder docsVer schon drin (41f34abc4cabeb5a); sonst STOP, nichts geaendert.
# Aendert NUR prepper_docs.py (Sicherung prepper_docs.py.bak-docsver-ZEIT, letzte 3). dashboard.py (bb94f52af6e03c3b), Datenbank, docs/ und alle Dienste bleiben unberuehrt. Sendet nichts (kein Mesh, kein Telegram, keine Alarme).
# Neustart: nur prepper-dashboard und NUR falls das Dashboard prepper_docs.py zur Laufzeit laedt (import); sonst keiner (der Generator ist ein eigenes Kommando: python3 prepper_docs.py). Sperre HH:55-HH:04.
# Die neue Beschreibung erzeugt dieses Skript NICHT (kein Schreiben nach docs/): danach einmal  cd /home/fmg/prepper-dashboard && python3 prepper_docs.py
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
W=/tmp/docsver-apply
# Nur fuer Simulationen auf einem Testport (nie 5000): anderer Projektordner, Arbeitsordner, Uhrzeit
if [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then
  DASH_DIR="${DOCSVER_SIM_DIR:-$DASH_DIR}"; W="${DOCSVER_SIM_W:-$W}"
fi
F="$DASH_DIR/prepper_docs.py"
D="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
KEEP_LAST=3
KNOWN_P16="609f0a7f00ab586b"      # prepper_docs.py vor docsVer (Generator-Version 1)
KNOWN_P16N="41f34abc4cabeb5a"     # prepper_docs.py nach docsVer (Generator-Version 2, Ziel)
KNOWN_D16="bb94f52af6e03c3b"   # dashboard.py (Stand nach hideTexts commit37) - wird nicht veraendert
PHASE=vorher
FINISHED=0
RESTARTED=0
ERRLN=""; ERRCMD=""
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
STOPPED=0
stop() { STOPPED=1; echo "STOP: $1 - nichts geaendert"; exit 1; }
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then stop "Dashboard-Port unklar ($PORT)"; fi
if [[ "$PORT" == "8080" ]]; then stop "Port 8080 ist kiwix-serve, nicht das Dashboard"; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
for t in python3 sha256sum curl flock cp mv diff cmp stat date mktemp; do command -v "$t" >/dev/null 2>&1 || stop "Werkzeug $t fehlt"; done
s16() { sha256sum "$1" | cut -c1-16; }
on_exit() {
  local ec=$?
  if [[ $ec -ne 0 && $FINISHED -eq 0 ]]; then
    if [[ "$PHASE" == vorher ]]; then
      [[ -n "$ERRLN" && "$STOPPED" == 0 ]] && echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE - es wurde noch nichts geaendert"
    elif [[ "$PHASE" == installiert ]]; then
      echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile ${ERRLN:-?}, Befehl: $(echo "${ERRCMD:-?}" | cut -c1-160) - Phase: $PHASE - Rollback"
      rb_quiet || true
    fi
  fi
}
trap on_exit EXIT
echo "=== docsVer apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): prepper_docs.py Generator-Version 2 (Zeit-Offset aus chrony, ninaFix, hideTexts), Dashboard-Port $PORT ==="
mkdir -p "$(dirname "$W")"
exec 9>"$W.lock"
flock -n 9 || stop "ein anderer docsVer-Lauf ist aktiv (Sperre $W.lock)"
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/stub"
EXPECT_PPK="e3edcf05de9af700c6900b6a64ad725e661ecb201629d55208d756d51053d7dc"
cat > "$W/patch.py" << 'MK_PPK_EOF'
"""Patcher docsVer. Aufruf: patch_dv.py QUELLE ZIEL EDITS. Idempotent: schon gepatcht -> Ziel = Quelle (Exit 0).
Exit 0 ok, 2 unbekannte Basis oder teilweise gepatcht. Schreibt nur ZIEL (nie QUELLE), Bytes unveraendert ausser den Stellen (newline='')."""
import sys
src, dst, edp = sys.argv[1:4]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E = g["PD_EDITS"]
with open(src, encoding="utf-8", newline="") as f:
    s = f.read()
new_in = [s.count(n) >= 1 for o, n in E]
if all(new_in):
    if not all(s.count(n) == 1 for o, n in E):
        print("prepper_docs.py: docsVer teilweise/anders vorhanden (Stelle mehrfach)"); raise SystemExit(2)
    open(dst, "w", encoding="utf-8", newline="").write(s)
    print("prepper_docs.py: docsVer schon drin"); raise SystemExit(0)
if any(new_in):
    print("prepper_docs.py: docsVer teilweise vorhanden (%d von %d Stellen)" % (sum(new_in), len(E))); raise SystemExit(2)
for i, (o, n) in enumerate(E, 1):
    if s.count(o) != 1:
        print("prepper_docs.py: Stelle %d nicht eindeutig (%d): %s" % (i, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
open(dst, "w", encoding="utf-8", newline="").write(s)
print("prepper_docs.py: %d Stellen docsVer" % len(E))
MK_PPK_EOF
EXPECT_EDT="f9c060156f5616b39ba94004e3971502714ca7a65d1a4fa2f822ccd2615f01b8"
cat > "$W/edits.py" << 'MK_EDT_EOF'
# Stellen fuer docsVer (commit38): prepper_docs.py, Basis sha16 609f0a7f00ab586b (Generator-Version 1)
# Jede Stelle: (alt, neu). alt muss genau einmal in der Basis stehen, neu genau einmal im Ergebnis.
PD_EDITS = [
    # 1) Zeile ~138 (Zeit): Stratum Offset (ntplib) -> Zeit-Offset aus chrony (Text aus /workspace/clockoff/DOCS_TEXT.md)
    ('Die Lage-Seite zeigt "Stratum Offset"; der Health-Check prueft "chrony tracking OK".',
     'Die Lage-Seite zeigt die Kachel "Zeit-Offset" aus chrony (chronyc -c tracking, Feld System time; positiv = Systemuhr geht nach, negativ = geht vor; unter 0,1 ms in Mikrosekunden) mit Stratum und Referenz, Cache 60 s; faellt chronyc aus, zeigt sie den ntplib-Wert mit Hinweis "(ntplib)". Der Health-Check prueft "chrony tracking OK".'),
    # 2) Zeile ~278 (Kopf der Lage-Seite)
    ('- Uhrzeit, "Stratum Offset" (Zeitabweichung zum Stratum-1-Server, ntplib, STRATUM_IP aus config.py).',
     '- Uhrzeit, "Zeit-Offset" (System time laut chronyc -c tracking, dazu Stratum und Referenz; Rueckfall: einzelne ntplib-Abfrage gegen STRATUM_IP aus config.py, gekennzeichnet "(ntplib)"; JSON: /api/clock-off).'),
    # 3) Zeile ~603 (Quellentabelle)
    ('| Stratum-1 (NTP) | ntplib | Offset | Kopf der Lage-Seite |',
     '| Stratum-1 (NTP) | chrony (chronyc -c tracking), Rueckfall ntplib | Zeit-Offset, Stratum, Referenz | Kopf der Lage-Seite |'),
    # 4) Kachel NINA WARNUNGEN: ninaFix + hideTexts
    ('NINA-Warngebiete als Polygone aus lagegeo.py (fuer /karte).',
     'NINA-Warngebiete als Polygone aus lagegeo.py (fuer /karte). Abruf und Zertifikatskette (Patch ninaFix, commit36): normal mit voller Pruefung; sendet warnung.bund.de die Zwischenstelle nicht mit, folgt ein zweiter Versuch mit einer gepinnten Zwischenstelle (certs/sectigo-e36.pem), nie verify=False; Zustand: /api/nina-cert. Seit hideTexts (commit37) steht "Zertifikatskette: ..." in der Kachel nur noch bei einem echten Fehler (Kette nicht pruefbar) oder wenn die gepinnte Zwischenstelle in weniger als 90 Tagen ablaeuft; die Nutzung des Rueckfalls allein ist harmlos und wird nicht angezeigt.'),
    # 5) Kachel BR24 WARNUNGEN: Rollen-Beschreibung nicht mehr angezeigt (hideTexts)
    ('mit Zeitangaben, Hinweis zu den Sticks, Knopf',
     'mit Zeitangaben, Knopf'),
    ('Warn-Score (stark/mittel/Anweisung, Entwarnung, Test); nur Empfang.\n',
     'Warn-Score (stark/mittel/Anweisung, Entwarnung, Test); nur Empfang. Die frueher unter den Zeilen stehende Beschreibung der Stick-Rollen (Feld bc_note aus /api/br24) zeigt die Kachel seit hideTexts (commit37) nicht mehr; das Feld bleibt in der API.\n'),
    # 6) Quelle NINA (Kapitel Daten/Alarm)
    ('aktive Warnungen mit Schweregrad (Minor bis Extreme), Entwarnungen (msgType Cancel oder Titel "Entwarnung") nur 2 h grau; abgelaufene Meldungen verschwinden.',
     'aktive Warnungen mit Schweregrad (Minor bis Extreme), Entwarnungen (msgType Cancel oder Titel "Entwarnung") nur 2 h grau; abgelaufene Meldungen verschwinden. Zertifikatskette des Servers: siehe "NINA und die Zertifikatskette" (ninaFix) im Kapitel Betrieb und Diagnose.'),
    # 7) Quellentabelle NINA
    ('| NINA/MoWaS (warnung.bund.de) | requests im Voll-Update (15 min) |',
     '| NINA/MoWaS (warnung.bund.de) | requests im Voll-Update (15 min), bei fehlender Zwischenstelle der Kette zweiter Versuch mit gepinntem Zertifikat (ninaFix) |'),
    # 8) Dateiliste: gepinnte Zwischenstelle
    ('| static/vendor/chart-4.4.1.min.js | Chart.js 4.4.1 (MIT-Lizenz, unveraendert aus dem npm-Paket), wird vom Dashboard lokal ausgeliefert (Patch relHygiene, commit19) |',
     '| static/vendor/chart-4.4.1.min.js | Chart.js 4.4.1 (MIT-Lizenz, unveraendert aus dem npm-Paket), wird vom Dashboard lokal ausgeliefert (Patch relHygiene, commit19) |\n| certs/sectigo-e36.pem | gepinnte Zwischenstelle "Sectigo Public Server Authentication CA DV E36" fuer die NINA-Abrufe (oeffentliches Zertifikat, kein Schluessel; Patch ninaFix, commit36): wird nur vom Rueckfall genutzt, die SHA-256 des DER steht fest im Programm, gueltig bis 21.03.2036 |'),
    # 9) Routentabelle: /api/clock-off und /api/nina-cert
    ('| /static/vendor/chart-4.4.1.min.js | GET | Chart.js 4.4.1 lokal (Patch relHygiene)',
     '| /api/clock-off | GET | Zeit-Offset fuer die Lage-Kachel (Patch clockOff, commit35): System time aus chronyc -c tracking mit Vorzeichen (positiv = Systemuhr geht nach), Stratum, Referenz; Rueckfall ntplib; Cache 60 s; nur lesen |\n| /api/nina-cert | GET | Zustand der NINA-Zertifikatskette (Patch ninaFix, commit36): Modus normal/rueckfall/fehler/unbekannt, Zaehler der normalen und der Rueckfall-Abrufe, Zustand der gepinnten Zwischenstelle und Tage bis zum Ablauf; nur lesen, keine Schluessel |\n| /static/vendor/chart-4.4.1.min.js | GET | Chart.js 4.4.1 lokal (Patch relHygiene)'),
    # 10) Patch-Reihenfolge
    ('Nur relHygiene setzt eine Schicht mit Marker in dashboard.py.',
     'Nur relHygiene setzt eine Schicht mit Marker in dashboard.py. Juengere Schichten dieser Beschreibung: clockOff (commit35: Kachel "Zeit-Offset" aus chrony), ninaFix (commit36: NINA-Zertifikatskette mit gepinntem Rueckfall) und hideTexts (commit37: zwei Anzeigetexte ausgeblendet); mit docsVer (commit38) wurde nur diese Datei prepper_docs.py angepasst (Generator-Version 2).'),
    # 11) Marker-Tabelle
    ('\n\n- Dateien ausserhalb der Schichten-Marker',
     '\n| clockOff | Kachel "Zeit-Offset" (Lage-Seite) zeigt den chrony-Wert (System time, positiv = Systemuhr geht nach) statt einer einzelnen ntplib-Abfrage; Rueckfall ntplib mit Hinweis "(ntplib)"; /api/clock-off (commit35) |\n| ninaFix | NINA-Abrufe bei unvollstaendiger Zertifikatskette des Servers: zweiter Versuch mit gepinnter Zwischenstelle certs/sectigo-e36.pem, nie verify=False; /api/nina-cert; Journalzeilen "ninaFix: ..." (commit36) |\n| hideTexts | Lage-Seite ohne den Rueckfall-Hinweis "Zertifikatskette ..." (Fehler und Ablaufwarnung bleiben) und ohne die Stick-Rollen-Beschreibung in der BR24-Kachel; nur Anzeige, Daten und API unveraendert (commit37) |\n\n- Dateien ausserhalb der Schichten-Marker'),
    # 12) Fehlersuche
    ('- Uhr falsch: chrony und Stratum-1 pruefen;',
     '- NINA ohne Daten oder Hinweis "Zertifikatskette" in der Kachel: /api/nina-cert ansehen (mode normal oder rueckfall = in Ordnung, fehler = Kette nicht pruefbar, Journal: journalctl -u prepper-dashboard | grep ninaFix).\n- Uhr falsch: chrony und Stratum-1 pruefen;'),
    # 13) Betrieb: neuer Unterabschnitt vor dem Kapitel "Aktueller Stand"
    ('\n\n# Aktueller Stand und offene Punkte',
     '\n\n### NINA und die Zertifikatskette (ninaFix commit36, hideTexts commit37)\n\n'
     '- Ausgangslage: Der NINA-Server (warnung.bund.de, ueber ein CDN) sendete ab dem 26.10.2026 zeitweise nur sein Serverzertifikat, nicht die Zwischenstelle "Sectigo Public Server Authentication CA DV E36". Browser laden sie nach, Python (requests) nicht: "unable to get local issuer certificate".\n'
     '- Ablauf im Dashboard: erst der normale Abruf mit voller Pruefung. Nur bei genau diesem Kettenfehler und nur fuer warnung.bund.de folgt ein zweiter Versuch mit einem Bundle aus den Systemzertifikaten (sonst certifi) plus der gepinnten Zwischenstelle certs/sectigo-e36.pem (SHA-256 des DER fest im Programm, gueltig bis 21.03.2036). verify=False gibt es nirgends. Sendet der Server die volle Kette, greift der normale Abruf und der Rueckfall bleibt ungenutzt.\n'
     '- Anzeigen: /api/nina-cert (nur GET) zeigt den Zustand (Modus normal, rueckfall, fehler oder unbekannt). Seit hideTexts zeigt die Kachel "NINA WARNUNGEN" den Hinweis "Zertifikatskette: ..." nur bei einem echten Fehler oder bei weniger als 90 Tagen bis zum Ablauf der gepinnten Zwischenstelle; die reine Nutzung des Rueckfalls steht nur in /api/nina-cert und im Journal ("ninaFix: ...", je Art hoechstens alle 6 h).\n'
     '- Ebenfalls seit hideTexts: Die Beschreibung der Stick-Rollen (Feld bc_note in /api/br24) erscheint nicht mehr in der BR24-Kachel der Lage-Seite; Daten und Rollen-Logik sind unveraendert.\n\n'
     '# Aktueller Stand und offene Punkte'),
    # 14) Stand der Entwicklung
    ('\n\n## Funktioniert (Stand der Erzeugung)',
     '\n- Danach (Branch-Commits 35 bis 38): clockOff (Zeit-Offset aus chrony), ninaFix (NINA-Zertifikatskette), hideTexts (zwei Anzeigetexte aus) und docsVer (diese Beschreibung, Generator-Version 2). Weitere Schichten dieser Zeit stehen im automatischen Abschnitt "Marker" und, soweit hier nicht beschrieben, im Nachtrag am Ende.\n\n## Funktioniert (Stand der Erzeugung)'),
    # 15) Offene Punkte
    ('- Echtzeituhr (zum Beispiel DS3231), TFT-Display',
     '- NINA-Zertifikatskette (ninaFix, commit36): /api/nina-cert zeigt, ob NINA normal (volle Kette vom Server) oder ueber den Rueckfall abgerufen wird (Zaehler je Art); die gepinnte Zwischenstelle laeuft am 21.03.2036 ab (Hinweis 90 Tage vorher).\n- Echtzeituhr (zum Beispiel DS3231), TFT-Display'),
    # 16) Generator-Version (Docs-Version)
    ('GEN_VERSION = "1"', 'GEN_VERSION = "2"'),
]
PD_ANCHOR = None
MK_EDT_EOF
EXPECT_GRD="e137ce51861be188c7ea0138ad7b697a9a619c2fe0023c21558dd64a87e619a5"
cat > "$W/guard.py" << 'MK_GRD_EOF'
"""AST-/Verhaltens-Guard docsVer (nur prepper_docs.py). Aufruf:
  guard_dv.py revert NEU_VERZ ALT_VERZ EDITS     -> ALT_VERZ/prepper_docs.py = NEU ohne docsVer (Rueckbau, byte-genau)
  guard_dv.py check  ALT_VERZ NEU_VERZ EDITS     -> statische Regeln (AST gleich bis auf CORE-Text und GEN_VERSION, Tabellen, Marken, Pflicht-/Verbotstexte, keine Secrets)
  guard_dv.py gen    ALT_VERZ NEU_VERZ PROJEKT TMP -> beide Generatoren im Sandkasten (--check/--no-live, dann Schreiblauf, dann Wiederholung = UNVERAENDERT), Vergleich der Pruefberichte
  guard_dv.py mutate NEU_VERZ ALT_VERZ EDITS      -> Mutationstest (jede Verfehlung muss erkannt werden)
Nur lesend ausser TMP; kein Netz, keine Dienste, kein Port."""
import ast
import os
import re
import shutil
import subprocess
import sys

NAME = "prepper_docs.py"
REQUIRED = ["Zeit-Offset", "chronyc -c tracking", "positiv = Systemuhr geht nach", '"(ntplib)"', "/api/clock-off", "/api/nina-cert", "ninaFix", "hideTexts",
            "certs/sectigo-e36.pem", "nie verify=False", "bc_note", "docsVer"]
FORBIDDEN_ANY = ["Stratum Offset"]
SECRET_RE = re.compile(r"(?i)(passwor[dt]\s*[:=]|token\s*[:=]|api[_-]?key\s*[:=]|secret\s*[:=]|BEGIN [A-Z ]*PRIVATE KEY|Bearer\s+[A-Za-z0-9._-]{12,}|EIA)")
IP_RE = re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")


def rd(p):
    with open(p, encoding="utf-8", newline="") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["PD_EDITS"]


def revert_text(s, edits):
    for o, n in reversed(edits):
        assert s.count(n) == 1, "Stelle docsVer nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, ep):
    edits = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, NAME)), edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, NAME), "w", encoding="utf-8", newline="") as f:
        f.write(s)
    print("Rueckbau ok: %d Stellen zurueck" % len(edits))


def _split(text):
    """AST mit neutralisiertem CORE-Text und GEN_VERSION; liefert (dump, core, gen)."""
    t = ast.parse(text)
    core = gen = None
    for node in t.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            nm = node.targets[0].id
            if nm == "CORE":
                assert isinstance(node.value, ast.Constant) and isinstance(node.value.value, str), "CORE ist kein Text"
                core = node.value.value
                node.value = ast.Constant(value="@CORE@")
            elif nm == "GEN_VERSION":
                assert isinstance(node.value, ast.Constant) and isinstance(node.value.value, str), "GEN_VERSION ist kein Text"
                gen = node.value.value
                node.value = ast.Constant(value="@GEN@")
    assert core is not None and gen is not None, "CORE oder GEN_VERSION fehlt"
    return ast.dump(t, include_attributes=False), core, gen


def _blocks_bad(core):
    """Zahl der Tabellenbloecke (zusammenhaengende Zeilen mit '|' am Anfang), deren Zeilen nicht gleich viele '|' haben."""
    bad = 0
    cur = []
    for ln in core.split("\n") + [""]:
        if ln.startswith("|"):
            cur.append(ln.count("|"))
        else:
            if cur and len(set(cur)) > 1:
                bad += 1
            cur = []
    return bad


def check_text(old, new, edits):
    """Liste der Verstoesse (leer = ok)."""
    P = []
    try:
        d0, c0, g0 = _split(old)
    except Exception as e:
        return ["Basis nicht lesbar: %s" % e]
    try:
        d1, c1, g1 = _split(new)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    except Exception as e:
        return ["Ergebnis nicht lesbar: %s" % e]
    if d0 != d1:
        P.append("AST weicht ausserhalb von CORE/GEN_VERSION ab (Programmcode veraendert)")
    if g0 != "1" or g1 != "2":
        P.append("GEN_VERSION: Basis %r -> Ergebnis %r (erwartet '1' -> '2')" % (g0, g1))
    m0 = sorted(re.findall(r"@@[^@\n]+@@", c0)); m1 = sorted(re.findall(r"@@[^@\n]+@@", c1))
    if m0 != m1:
        P.append("@@-Marken des Textkerns veraendert (%d -> %d)" % (len(m0), len(m1)))
    if "'''" in c1 or "\\'\\'\\'" in c1:
        P.append("Dreifach-Apostroph im Textkern")
    for f in FORBIDDEN_ANY:
        if f in c1:
            P.append("verbotener alter Text noch drin: %r (%dx)" % (f, c1.count(f)))
    for r in REQUIRED:
        if r not in c1 + "\n" + new[:0]:
            P.append("Pflichttext fehlt: %r" % r)
    if _blocks_bad(c1) > _blocks_bad(c0):
        P.append("Tabelle mit ungleicher Spaltenzahl (neu %d, Basis %d)" % (_blocks_bad(c1), _blocks_bad(c0)))
    import difflib
    added = [l[1:] for l in difflib.unified_diff(c0.split("\n"), c1.split("\n"), n=0, lineterm="") if l.startswith("+") and not l.startswith("+++")]
    at = "\n".join(added)
    if SECRET_RE.search(at):
        P.append("neuer Text enthaelt Secret-aehnliches/verbotenes Thema: %r" % SECRET_RE.search(at).group(0))
    nip = set(IP_RE.findall(at)) - set(IP_RE.findall(c0))
    if nip:
        P.append("neue IP-Adressen im Text: %s" % sorted(nip))
    removed = [l[1:] for l in difflib.unified_diff(c0.split("\n"), c1.split("\n"), n=0, lineterm="") if l.startswith("-") and not l.startswith("---")]
    nna = sorted(set(ch for l in added if re.search(r"[^\x00-\x7f]", l) and not any(l[:30] == r[:30] for r in removed) for ch in re.findall(r"[^\x00-\x7f]", l)))
    if nna:
        P.append("neue Zeile mit Nicht-ASCII-Zeichen: %s" % nna)
    dl = c1.count("\n") - c0.count("\n")
    if not 12 <= dl <= 40:
        P.append("Zeilenzuwachs des Textkerns %+d ausserhalb 12..40" % dl)
    # Stellen: jede neue Stelle genau einmal, jede alte Stelle (soweit nicht Teil der neuen) nicht mehr da
    full = new
    for i, (o, n) in enumerate(edits, 1):
        if full.count(n) != 1:
            P.append("Stelle %d nicht genau einmal im Ergebnis (%d)" % (i, full.count(n)))
    if old.count("\n") + dl != new.count("\n"):
        P.append("Zeilenzahl passt nicht zum Zuwachs des Textkerns (Aenderung ausserhalb CORE?)")
    return P


def check(altdir, newdir, ep):
    edits = load_edits(ep)
    old, new = rd(os.path.join(altdir, NAME)), rd(os.path.join(newdir, NAME))
    P = check_text(old, new, edits)
    if P:
        print("\n".join("VERSTOSS: " + p for p in P)); return 1
    # Rueckbau byte-genau
    if revert_text(new, edits) != old:
        print("VERSTOSS: Rueckbau ergibt nicht die Basis"); return 1
    print("check ok: AST ausser CORE/GEN_VERSION gleich, GEN_VERSION 1 -> 2, %d Pflichttexte, kein 'Stratum Offset', Tabellen ok, keine Secrets/neuen IPs, Rueckbau byte-genau" % len(REQUIRED))
    return 0


def _run_gen(script, proj, out, args, env_extra=None):
    env = dict(os.environ)
    env.update({"PRDOCS_BASE": proj, "PRDOCS_OUT": out, "PRDOCS_SYSTEMCTL": os.path.join(proj, "_stub_systemctl"), "PRDOCS_SBIN": os.path.join(proj, "_sbin"),
                "PRDOCS_SUDOERS": os.path.join(proj, "_sudoers"), "PRDOCS_UNITDIR": os.path.join(proj, "_units"), "PRDOCS_PORT": "9"})
    if env_extra:
        env.update(env_extra)
    r = subprocess.run([sys.executable, script] + args, cwd=proj, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=180)
    return r.returncode, r.stdout


def _nums(rep, key):
    m = re.search(re.escape(key) + r".*?(\d+) als Nachtrag", rep)
    return int(m.group(1)) if m else None


def gen(altdir, newdir, proj, tmp):
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    sp = os.path.join(tmp, "proj")
    os.makedirs(sp)
    for nm in sorted(os.listdir(proj)):      # nur Programmdateien der obersten Ebene (kein config.py, keine Daten, keine Sicherungen); Groesse begrenzt
        pp = os.path.join(proj, nm)
        if nm in ("prepper_docs.py", "config.py") or ".bak" in nm or not (nm.endswith(".py") or nm.endswith(".sh")):
            continue
        if os.path.isfile(pp) and not os.path.islink(pp) and os.path.getsize(pp) <= 8 * 1024 * 1024:
            shutil.copy(pp, os.path.join(sp, nm))
    for d in ("_sbin", "_sudoers", "_units"):
        os.makedirs(os.path.join(sp, d), exist_ok=True)
    st = os.path.join(sp, "_stub_systemctl")
    with open(st, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(st, 0o755)
    res = {}
    for tag, d in (("alt", altdir), ("neu", newdir)):
        sc = os.path.join(tmp, "gen_%s.py" % tag)
        shutil.copy(os.path.join(d, NAME), sc)
        out = os.path.join(tmp, "out_" + tag)
        rc, rep = _run_gen(sc, sp, out, ["--check", "--no-live"])
        if rc != 0:
            print("VERSTOSS: Generator %s --check meldet Exit %d:\n%s" % (tag, rc, rep[-600:])); return 1
        if os.path.exists(out) and os.listdir(out):
            print("VERSTOSS: --check hat in %s geschrieben" % out); return 1
        rc, rep2 = _run_gen(sc, sp, out, ["--no-live"])
        if rc != 0 or "OK Version" not in rep2:
            print("VERSTOSS: Generator %s Schreiblauf Exit %d:\n%s" % (tag, rc, rep2[-600:])); return 1
        files = sorted(os.listdir(out))
        if len(files) != 2 or not all(x.startswith("Projektbeschreibung Lage Pi v") for x in files):
            print("VERSTOSS: Generator %s erzeugt unerwartete Dateien: %s" % (tag, files)); return 1
        rc, rep3 = _run_gen(sc, sp, out, ["--no-live"])
        if rc != 0 or "UNVERAENDERT" not in rep3 or len(os.listdir(out)) != 2:
            print("VERSTOSS: Generator %s: zweiter Lauf ist nicht 'UNVERAENDERT' (nicht idempotent):\n%s" % (tag, rep3[-400:])); return 1
        txt = rd(os.path.join(out, [x for x in files if x.endswith(".txt")][0]))
        res[tag] = (rep, txt)
    ra, ta = res["alt"]; rn, tn = res["neu"]
    P = []
    if "Stratum Offset" in tn:
        P.append("neue Beschreibung enthaelt noch 'Stratum Offset' (%dx)" % tn.count("Stratum Offset"))
    if ta.count("Stratum Offset") != 2 + 0 and ta.count("Stratum Offset") < 1:
        P.append("Gegenprobe: alte Beschreibung enthaelt 'Stratum Offset' nicht (Test sinnlos)")
    for need in ("Zeit-Offset", "chronyc -c tracking", "/api/nina-cert", "NINA und die Zertifikatskette", "hideTexts", "Generator 2"):
        if need not in tn:
            P.append("neue Beschreibung ohne %r" % need)
    if "Generator 1" not in ta or "Generator 2" in ta:
        P.append("alte Beschreibung: Generator-Version nicht 1")
    for key in ("Routen (ast)", "Patch-Schichten (Marker)"):
        a, n = _nums(ra, key), _nums(rn, key)
        if a is None or n is None or n > a:
            P.append("%s: Nachtrag alt %s -> neu %s (darf nicht steigen)" % (key, a, n))
    na = int(re.search(r"Hinweise der Sammler: (\d+)", ra).group(1)); nn = int(re.search(r"Hinweise der Sammler: (\d+)", rn).group(1))
    if nn > na:
        P.append("Hinweise der Sammler gestiegen (%d -> %d)" % (na, nn))
    sa = re.search(r"Schwaerzungen: (\d+)", ra).group(1); sn = re.search(r"Schwaerzungen: (\d+)", rn).group(1)
    if sa != sn:
        P.append("Schwaerzungen unterschiedlich (%s -> %s)" % (sa, sn))
    ha = [l for l in ta.split("\n") if re.match(r"^\d+\. [A-Z]", l)]; hn = [l for l in tn.split("\n") if re.match(r"^\d+\. [A-Z]", l)]
    if ha != hn:
        P.append("Kapitelliste unterschiedlich")
    if SECRET_RE.search("\n".join(set(tn.split("\n")) - set(ta.split("\n")))):
        P.append("neue Zeilen in der Beschreibung enthalten Secret-aehnliches")
    if P:
        print("\n".join("VERSTOSS: " + p for p in P)); return 1
    ch = re.search(r"Routen \(ast\): (\d+) geprueft, (\d+) im Text, (\d+) als Nachtrag", rn)
    print("gen ok: beide Generatoren laufen im Sandkasten (--check schreibt nichts, Schreiblauf 2 Dateien, zweiter Lauf UNVERAENDERT); neu: Routen-Nachtrag %s -> %s, Marker-Nachtrag %s -> %s, TXT %d -> %d Zeilen, kein 'Stratum Offset'" %
          (_nums(ra, "Routen (ast)"), _nums(rn, "Routen (ast)"), _nums(ra, "Patch-Schichten (Marker)"), _nums(rn, "Patch-Schichten (Marker)"), ta.count("\n"), tn.count("\n")))
    return 0


def mutants(new, old, edits):
    """(Name, mutierter Text) - jede Verfehlung muss check_text melden."""
    M = []
    o0, n0 = edits[0]
    M.append(("Stelle 1 zurueck (alter Stratum-Offset-Text)", new.replace(n0, o0, 1)))
    o1, n1 = edits[1]
    M.append(("Stelle 2 zurueck", new.replace(n1, o1, 1)))
    o2, n2 = edits[2]
    M.append(("Stelle 3 zurueck", new.replace(n2, o2, 1)))
    M.append(("GEN_VERSION nicht erhoeht", new.replace('GEN_VERSION = "2"', 'GEN_VERSION = "1"', 1)))
    M.append(("GEN_VERSION 3", new.replace('GEN_VERSION = "2"', 'GEN_VERSION = "3"', 1)))
    M.append(("Code geaendert: WIDTH", new.replace("WIDTH = 100", "WIDTH = 101", 1)))
    M.append(("Code geaendert: KEEP_DEFAULT", new.replace("KEEP_DEFAULT = 10", "KEEP_DEFAULT = 1", 1)))
    M.append(("Code geaendert: Rotation (Schreiben/Loeschen)", new.replace("os.unlink(os.path.join(DOCS, nm))", "os.unlink(os.path.join(BASE, nm))", 1)))
    M.append(("zusaetzlicher Import smtplib", new.replace("import urllib.request\n", "import urllib.request\nimport smtplib\n", 1)))
    M.append(("zusaetzlicher Netzaufruf", new.replace("def cell(x):", "def _x():\n    urllib.request.urlopen('http://example.org')\n\n\ndef cell(x):", 1)))
    M.append(("@@AUTO-Marke entfernt", new.replace("@@AUTO meta@@", "", 1)))
    M.append(("Syntaxfehler", new.replace("def cell(x):", "def cell(x:", 1)))
    M.append(("Pflichttext entfernt (ninaFix-Abschnitt)", new.replace("### NINA und die Zertifikatskette (ninaFix commit36, hideTexts commit37)", "### NINA", 1)))
    M.append(("hideTexts-Markerzeile entfernt", new.replace("| hideTexts | Lage-Seite", "| hideTextsX | Lage-Seite", 1).replace("hideTexts", "hideT", 4)))
    M.append(("Tabellenzeile mit zusaetzlicher Spalte", new.replace("| ninaFix | NINA-Abrufe bei", "| ninaFix | extra | NINA-Abrufe bei", 1)))
    def inj(t):
        return new.replace("# Zweck, Zielgruppe, Leitprinzipien", t + "\n\n# Zweck, Zielgruppe, Leitprinzipien", 1)
    M.append(("Secret im Text (eingefuegt)", inj("- Zugang: password=geheim123")))
    M.append(("Bearer-Token im Text (eingefuegt)", inj("- Kopf: Bearer abcdefghijklmnop123")))
    M.append(("neue IP im Text (eingefuegt)", inj("- Knoten 10.20.30.40")))
    M.append(("Dreifach-Apostroph im Text (eingefuegt)", inj("- x " + "'" * 3 + " y")))
    M.append(("Umlaut im neuen Text (eingefuegt)", inj("- Gr\u00fcn")))
    M.append(("Tabelle ungleiche Spalten (eingefuegt)", inj("| a | b |\n| c |")))
    M.append(("EIA-Thema erwaehnt (eingefuegt)", inj("- EIA Schluessel")))
    M.append(("Stratum Offset wieder da (eingefuegt)", inj('- "Stratum Offset" Kachel')))
    M.append(("neue @@-Marke (eingefuegt)", inj("@@AUTO neu@@")))
    M.append(("Stelle 14 doppelt", new.replace("\n\n## Funktioniert (Stand der Erzeugung)", edits[13][1].split("\n\n## Funktioniert")[0] + "\n\n## Funktioniert (Stand der Erzeugung)", 1)))
    M.append(("Zeilenzuwachs zu gross", new.replace("\n\n## Funktioniert (Stand der Erzeugung)", "\n" + "\n".join("- Fuellzeile %d" % i for i in range(40)) + "\n\n## Funktioniert (Stand der Erzeugung)", 1)))
    M.append(("Zeile ausserhalb CORE (Kommentar)", new.replace("KEEP_DEFAULT = 10", "KEEP_DEFAULT = 10  # x", 1) .replace("# x", "")  + "\n# nachtrag\n"))
    return M


def mutate(newdir, altdir, ep):
    edits = load_edits(ep)
    old, new = rd(os.path.join(altdir, NAME)), rd(os.path.join(newdir, NAME))
    assert check_text(old, new, edits) == [], check_text(old, new, edits)
    bad = 0
    ms = mutants(new, old, edits)
    for name, t in ms:
        if t == new:
            print("FEHLER Mutation %r aendert nichts (Testfehler)" % name); bad += 1; continue
        P = check_text(old, t, edits)
        if P:
            print("OK erkannt: %-52s -> %s" % (name, P[0][:90]))
        else:
            print("UEBERSEHEN: %s" % name); bad += 1
    # Gegenprobe: byte-gleich bleibt ok
    if check_text(old, new, edits):
        print("FEHLER Gegenprobe"); bad += 1
    print("Mutationstest: %d Mutationen, %d nicht erkannt" % (len(ms), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "revert":
        revert(*sys.argv[2:5])
    elif cmd == "check":
        sys.exit(check(*sys.argv[2:5]))
    elif cmd == "gen":
        sys.exit(gen(*sys.argv[2:6]))
    elif cmd == "mutate":
        sys.exit(mutate(*sys.argv[2:5]))
    else:
        print("unbekannt"); sys.exit(64)
MK_GRD_EOF
PPK="$W/patch.py"; EDT="$W/edits.py"; GRD="$W/guard.py"
for x in "$EXPECT_PPK $PPK" "$EXPECT_EDT $EDT" "$EXPECT_GRD $GRD"; do
  read -r xs xf <<< "$x"; echo "$xs  $xf" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$xf") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Patcher, Stellen, Pruefprogramm)"
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "prepper_docs.py fehlt im Projektordner $DASH_DIR"
[[ -f "$D" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
P16=$(s16 "$F"); DS16=$(s16 "$D")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis prepper_docs.py sha16 $P16 ($(wc -l < "$F") Zeilen, $(lbl "$P16" "$KNOWN_P16" "Generator-Version 1, vor docsVer" "$KNOWN_P16N" "docsVer schon drin"))"
if [[ "$P16" != "$KNOWN_P16" && "$P16" != "$KNOWN_P16N" ]]; then
  echo "STOP: prepper_docs.py weicht vom erwarteten Stand ab (sha16 $P16, erwartet $KNOWN_P16 oder $KNOWN_P16N) - nichts geaendert."
  echo "      docsVer passt nur auf die Generator-Version 1 (prepper_docs.py $KNOWN_P16). Lokale Aenderung oder ein anderer Docs-Stand? Bitte diese Ausgabe an Grok schicken."
  python3 "$PPK" "$F" "$W/work/x.py" "$EDT" 2>&1 | sed 's/^/      Befund: /' || true
  exit 1
fi
if [[ "$DS16" == "$KNOWN_D16" ]]; then echo "OK dashboard.py sha16 $DS16 (wie erwartet, Stand nach hideTexts commit37)"
else echo "HINWEIS dashboard.py sha16 $DS16 weicht von $KNOWN_D16 ab - docsVer aendert dashboard.py nicht und liest es nur als Quelle der automatischen Abschnitte; der Patch laeuft weiter"; fi
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder prepper_docs.py ist nicht beschreibbar"
"$VPY" -c "import sys; assert sys.version_info >= (3, 9)" 2>/dev/null || stop "Python der venv ($VPY) ist aelter als 3.9 oder nicht startbar"
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
DOCS_LS0=$({ ls -1 "$DASH_DIR/docs" 2>/dev/null || true; } | sha256sum | cut -c1-16)
# ---- Laedt das Dashboard prepper_docs.py zur Laufzeit? (import in einer Programmdatei) ----
LOADERS=$({ grep -lE '^[[:space:]]*(import[[:space:]]+prepper_docs|from[[:space:]]+prepper_docs[[:space:]]+import)|importlib[^#]*prepper_docs|__import__\([^)]*prepper_docs|(Popen|check_output|check_call|subprocess\.run|os\.system)[^#]*prepper_docs' "$DASH_DIR"/*.py 2>/dev/null || true; } | { grep -v "/prepper_docs.py$" || true; } | { grep -v "\.bak" || true; })
NEED_RESTART=0
if [[ -z "$LOADERS" ]]; then
  echo "OK prepper_docs.py wird von keiner Programmdatei im Projektordner geladen oder gestartet (kein import, kein Unterprozess): der Generator laeuft nur als eigenes Kommando - kein Neustart noetig"
elif [[ "$(echo "$LOADERS" | tr '\n' ' ' | sed 's/ $//')" == "$D" ]]; then
  NEED_RESTART=1; echo "HINWEIS dashboard.py laedt prepper_docs.py zur Laufzeit - nach dem Austausch wird prepper-dashboard neu gestartet (Sperre HH:55-HH:04)"
else
  stop "prepper_docs.py wird von $(echo "$LOADERS" | xargs -n1 basename | tr '\n' ' ')geladen (nicht nur vom Dashboard) - der Umfang des Neustarts ist unklar"
fi
UNITS=$({ grep -l "prepper_docs" /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null || true; } | xargs -r -n1 basename | tr '\n' ' ')
[[ -n "$UNITS" ]] && echo "INFO systemd-Einheiten, die prepper_docs.py nennen: $UNITS(eigener Prozess je Lauf, nimmt die neue Datei beim naechsten Start)" || echo "INFO keine systemd-Einheit nennt prepper_docs.py (Aufruf von Hand)"
# ---- Neustart-Fenster (nur relevant, wenn ein Neustart noetig ist): gesperrt HH:55-HH:04 jeder Stunde ----
hmmin() { local hm; if [[ -n "${DOCSVER_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$DOCSVER_FAKE_HM"; echo $(( 10#${hm##*:} )); else echo $(( 10#$(date +%M) )); fi; }
inwin() { local m; m=$(hmmin); (( m >= 55 || m < 5 )); }
wxcheck() {
  [[ "$NEED_RESTART" == 1 ]] || return 0
  if inwin; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Fenster: jetzt (Minute $(hmmin)) waere ein echter Lauf gesperrt (HH:55-HH:04); der Trockenlauf aendert nichts"
    else stop "Neustart-Fenster: Minute $(hmmin) der Stunde liegt in HH:55-HH:04 - ein Neustart jetzt koennte die Wetter-Slot-Meldung verzoegern. Bitte ab HH:05 neu starten"; fi
  else echo "OK Neustart-Fenster: Minute $(hmmin) liegt ausserhalb HH:55-HH:04"; fi
}
wxcheck
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" "$F" "$W/work/prepper_docs.py" "$EDT" > "$W/q.log" || { cat "$W/q.log"; stop "prepper_docs.py: Stelle fuer docsVer nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/prepper_docs.py")
[[ "$ND16" == "$KNOWN_P16N" ]] || stop "Ergebnis prepper_docs.py $ND16 statt $KNOWN_P16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: prepper_docs.py $ND16 ($(wc -l < "$W/work/prepper_docs.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" "$W/work/prepper_docs.py" "$W/work/x.py" "$EDT" > /dev/null && cmp -s "$W/work/prepper_docs.py" "$W/work/x.py" || stop "prepper_docs.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/prepper_docs.py" "$PPK" "$EDT" "$GRD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (prepper_docs.py, Patcher, Stellen, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/prepper_docs.py" "$W/neu/prepper_docs.py"
nice -n 10 "$VPY" "$GRD" revert "$W/neu" "$W/alt" "$EDT" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: docsVer im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/prepper_docs.py")" == "$KNOWN_P16" ]] || stop "Guard: Stand ohne docsVer ist nicht die bekannte Basis ($(s16 "$W/alt/prepper_docs.py") statt $KNOWN_P16)"
nice -n 10 "$VPY" "$GRD" check "$W/alt" "$W/neu" "$EDT" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "Guard docsVer meldet Verstoss"; }
cat "$W/g.log"
mkdir -p "$W/proj"; cp "$D" "$W/proj/dashboard.py"
nice -n 10 "$VPY" "$GRD" gen "$W/alt" "$W/neu" "$W/proj" "$W/gen" > "$W/gg.log" 2>&1 || { cat "$W/gg.log"; stop "Generator-Probe im Sandkasten meldet Verstoss"; }
cat "$W/gg.log"
nice -n 10 "$VPY" "$GRD" mutate "$W/neu" "$W/alt" "$EDT" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "Guard-Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^Mutationstest" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c _; for _ in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep "${DOCSVER_RETRY_S:-6}"; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local _; for _ in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
DOCAPIS=(/api/docs/list /api/docs/routes)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}" "${DOCAPIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}" "${DOCAPIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
docsj() { "${CURL[@]}" "$B/api/docs/list" 2>/dev/null | python3 -c '
import sys, json
try:
    j = json.load(sys.stdin)
    print("ok=%s current=%s n=%d" % (j.get("ok"), j.get("current"), len(j.get("versions") or [])))
except Exception:
    print("unlesbar")
' 2>/dev/null || echo "unlesbar"; }
DOCSJ0=$(docsj)
echo "Zustand vorher: /api/docs/list: $DOCSJ0; docs/-Ordner Listen-Hash $DOCS_LS0"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
PILAT0=$(tmed "$B/pi")
echo "Zustand vorher: /pi antwortet im Median in ${PILAT0} s"
NEED_P=0; cmp -s "$W/work/prepper_docs.py" "$F" || NEED_P=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet, nichts nach docs/ geschrieben."
  if [[ "$NEED_P" == 0 ]]; then echo "  Zustand: docsVer ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: prepper_docs.py ersetzen (Sicherung prepper_docs.py.bak-docsver-ZEIT, letzte $KEEP_LAST), $([[ "$NEED_RESTART" == 1 ]] && echo "prepper-dashboard neu starten (eine sudo-Passwortabfrage)" || echo "keinen Dienst neu starten"), dann die 26 Seiten/APIs und die Docs-Endpunkte pruefen."; fi
  echo "COMMIT $COMMIT_ARG docsver=dry fertig"
  FINISHED=1
  exit 0
fi
# ---------- 4) Installieren ----------
BK="$F.bak-docsver-$TS"
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
rb_quiet() {
  local ok=0
  if [[ -f "$BK" ]]; then
    if cp -p "$BK" "$F.docsver-rb.$$" && mv -f "$F.docsver-rb.$$" "$F"; then ok=1; fi
  fi
  if [[ "$ok" == 1 && "$(s16 "$F")" == "$KNOWN_P16" ]]; then echo "OK Rollback: prepper_docs.py wieder sha16 $KNOWN_P16 (aus $(basename "$BK"))"
  else echo "FEHLER Rollback: prepper_docs.py ist NICHT sicher zurueckgesetzt - von Hand: cp -p $BK $F"; fi
  if [[ "$RESTARTED" == 1 ]]; then
    sudo -n systemctl restart prepper-dashboard 2>/dev/null || sudo systemctl restart prepper-dashboard || echo "FEHLER: Neustart nach Rollback fehlgeschlagen - von Hand: sudo systemctl restart prepper-dashboard"
    for _ in $(seq 1 40); do [[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] && break; sleep "${DOCSVER_RETRY_S:-3}"; done
    echo "Dashboard nach Rollback neu gestartet: $(systemctl is-active prepper-dashboard 2>/dev/null || true)"
  fi
  PHASE=zurueckgerollt
}
rb() { echo "FEHLER: $1"; rb_quiet; echo "STOP: $1 - prepper_docs.py wurde zurueckgerollt (sha16 $(s16 "$F"))"; FINISHED=1; exit 1; }
if [[ "$NEED_RESTART" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards erforderlich"; fi
wxcheck
T0D=$(date +%s)
if [[ "$NEED_P" == 1 ]]; then
  cp -p "$F" "$BK" || stop "Sicherung $BK nicht moeglich"
  cmp -s "$F" "$BK" || stop "Sicherung $BK ungleich Original"
  PHASE=installiert
  cp "$W/work/prepper_docs.py" "$F.docsver-new.$$"
  chmod --reference="$F" "$F.docsver-new.$$" 2>/dev/null || chmod 644 "$F.docsver-new.$$"
  [[ "$(s16 "$F.docsver-new.$$")" == "$KNOWN_P16N" ]] || { rm -f "$F.docsver-new.$$"; rb "temporaere Datei hat falsche Pruefsumme"; }
  mv -f "$F.docsver-new.$$" "$F"
  echo "OK prepper_docs.py ersetzt (atomar per mv), Sicherung: $(basename "$BK")"
  ALL=$({ ls -1 "$F.bak-docsver-"* 2>/dev/null || true; } | sort)
  NB=$(echo "$ALL" | grep -c . || true)
  if [[ "${NB:-0}" -gt "$KEEP_LAST" ]]; then
    echo "$ALL" | head -n $(( NB - KEEP_LAST )) | while IFS= read -r old; do rm -f -- "$old" && echo "Rotation: $(basename "$old") entfernt (keepLast $KEEP_LAST)"; done
  fi
else
  echo "OK docsVer ist schon installiert - keine Aenderung, keine neue Sicherung"
fi
# ---------- 5) Pruefung ----------
[[ "$(s16 "$F")" == "$KNOWN_P16N" ]] || rb "prepper_docs.py nach dem Schreiben nicht sha16 $KNOWN_P16N"
for py in "$SPY" "$VPY"; do
  "$py" -W error -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$F" 2>"$W/pyc2.log" || { cat "$W/pyc2.log"; rb "installierte Datei laesst sich mit $py nicht uebersetzen"; }
done
echo "OK installierte Datei uebersetzt (System- und venv-Python, ohne __pycache__ zu schreiben)"
if [[ "$NEED_RESTART" == 1 && "$NEED_P" == 1 ]]; then
  echo "Neustart prepper-dashboard (nur dieser Dienst) ..."
  sudo systemctl restart prepper-dashboard || rb "Neustart prepper-dashboard fehlgeschlagen"
  RESTARTED=1
  for _ in $(seq 1 40); do [[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] && [[ "$(code "$B/api/time")" == 200 ]] && break; sleep "${DOCSVER_RETRY_S:-3}"; done
  [[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] || rb "prepper-dashboard laeuft nach dem Neustart nicht"
fi
CHK=$(cd "$DASH_DIR" && PRDOCS_OUT="$W/chk-out" timeout 120 nice -n 10 python3 "$F" --check --no-live 2>&1) || rb "python3 prepper_docs.py --check --no-live schlaegt fehl: $(echo "$CHK" | tail -2 | tr '\n' ' ' | cut -c1-200)"
echo "$CHK" | grep -q "Trockenlauf (--check): nichts geschrieben" || rb "--check meldet den Trockenlauf nicht"
echo "$CHK" | grep -E "^(Routen \(ast\)|Patch-Schichten \(Marker\)|Nachtrag-Abschnitte|Hinweise der Sammler)" | sed 's/^/   | /' | cut -c1-160
echo "OK python3 prepper_docs.py --check --no-live laeuft mit der neuen Datei (nur lesend, nichts geschrieben)"
for p in "${PAGES[@]}" "${APIS[@]}" "${DOCAPIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rb "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs (zusammen $(( ${#PAGES[@]} + ${#APIS[@]} ))) sowie ${#DOCAPIS[@]} Docs-Endpunkte antworten wie vorher ($(for p in "${PAGES[@]}" "${APIS[@]}" "${DOCAPIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
DOCSJ1=$(docsj)
[[ "$DOCSJ1" == "$DOCSJ0" ]] && echo "OK /api/docs/list wie vorher ($DOCSJ1)" || rb "/api/docs/list vorher '$DOCSJ0', nachher '$DOCSJ1'"
CUR=$(echo "$DOCSJ1" | sed -n 's/.*current=\([0-9-]*\).*/\1/p')
if [[ -n "$CUR" ]]; then
  c=$(code_r "$B/api/docs/download?fmt=txt&v=$CUR")
  [[ "$c" == 200 ]] && echo "OK /api/docs/download (txt, v$CUR) -> 200" || rb "/api/docs/download v$CUR liefert $c"
else echo "INFO keine Version in docs/ (noch keine Beschreibung erzeugt) - Download-Pruefung entfaellt"; fi
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); P1=$(grep -o 'Projektbeschreibung' "$W/pi.html" | wc -l || true)
[[ "$R1" -ge 1 && "$P1" -ge 1 ]] || rb "/pi liefert Sicherung/Projektbeschreibung nicht mehr (doPrepperRestore ${R1}x, Projektbeschreibung ${P1}x)"
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand kann sich zwischendurch geaendert haben; docsVer aendert die Kachel nicht"
[[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] || rb "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rb "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
# ---------- 6) Journal (nur nach Neustart) ----------
if [[ "$RESTARTED" == 1 ]]; then
  JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
  if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then echo "HINWEIS Journal prepper-dashboard nicht lesbar - Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E 'Traceback|FEHLER'"
  else
    E3=$(echo "$JD" | grep -c -E 'Traceback|Selbsttest FEHLER' || true)
    [[ "${E3:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/Selbsttest-Fehler" || rb "Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/Selbsttest FEHLER"
  fi
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED" == 1 ]]; then [[ "$a" == active ]] || rb "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rb "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- $([[ "$RESTARTED" == 1 ]] && echo "nur prepper-dashboard wurde neu gestartet" || echo "kein Dienst wurde neu gestartet")"
[[ "$(s16 "$D")" == "$DS16" ]] && echo "OK dashboard.py unveraendert (sha16 $DS16)" || rb "dashboard.py hat sich geaendert (vorher $DS16, jetzt $(s16 "$D"))"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"))" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
DOCS_LS1=$({ ls -1 "$DASH_DIR/docs" 2>/dev/null || true; } | sha256sum | cut -c1-16)
[[ "$DOCS_LS0" == "$DOCS_LS1" ]] && echo "OK Ordner docs/ unveraendert (docsVer erzeugt keine neue Beschreibung)" || echo "HINWEIS Ordner docs/ hat sich waehrend des Laufs geaendert (Listen-Hash $DOCS_LS0 -> $DOCS_LS1) - nicht durch diesen Patch"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter und alle Dienste unberuehrt"
[[ -f "$BK" ]] && echo "Backup: $(basename "$BK") (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  prepper_docs.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-docsver-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -p $LB $F" || echo "Rueckweg: keine docsver-Sicherung vorhanden (prepper_docs.py nicht geaendert)"
echo "Naechster Schritt (von Hand, erzeugt die neue Beschreibung mit Generator-Version 2 in docs/):"
echo "  cd /home/fmg/prepper-dashboard && python3 prepper_docs.py"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c Zeit-Offset /home/fmg/prepper-dashboard/prepper_docs.py"
echo "  grep -c Stratum.Offset /home/fmg/prepper-dashboard/prepper_docs.py"
echo "  grep GEN_VERSION /home/fmg/prepper-dashboard/prepper_docs.py"
echo "  cd /home/fmg/prepper-dashboard && python3 prepper_docs.py --check --no-live"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: Generator-Version 2 (GEN_VERSION), die Datei in docs/ entsteht beim naechsten Lauf des Generators."
FINISHED=1
echo "COMMIT $COMMIT_ARG docsver=1 fertig"
