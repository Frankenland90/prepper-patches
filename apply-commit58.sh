#!/bin/bash
# shellcheck disable=SC2015
set -eEuo pipefail
# dokuStand (commit58): Projektbeschreibung Lage Pi auf den Stand commit39-57 (Generator-Version 3): nur Text in prepper_docs.py (CORE, 5 neue FILE_ROLES, GEN_VERSION 2 -> 3) - USV (NUT, Kachel, Ansage, Abschaltung), Audio-Kachel, Ortsbezug, Karten-Popup, Heartbeat nur bei Problem, /umwelt flach, QRM, Leistungs-Schichten
# Aufruf: bash /tmp/apply-commit58.sh commit58 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein Neustart, nichts nach docs/)
# Basis streng (sha16): Zielstand commit57 (dashboard.py 7d494c1a21e50e96, lage_pages.py a9740c629a41806c, ups_manager.py ef0b9e3d4bf42003, prepper_sdr.py 264ef34996e17753, prepper_evlog.py 8bffd396972b60fa) und prepper_docs.py 41f34abc4cabeb5a (docsVer) oder schon 43032d218135e329; sonst STOP, nichts geaendert.
# Aendert NUR prepper_docs.py (Sicherung prepper_docs.py.bak-commit58-ZEIT, letzte 3) und erzeugt danach EINMAL die neue Beschreibung in docs/ (python3 prepper_docs.py; liest nur, GET-Abrufe am eigenen Dashboard). Datenbank, andere Programmdateien und Dienste bleiben unberuehrt. Sendet nichts (kein Mesh, kein Telegram, keine Alarme).
# Neustart: keiner (prepper_docs.py wird vom Dashboard nicht geladen; geprueft). Falls doch: nur prepper-dashboard, Sperre HH:55-HH:04.
# Rollback bei Fehler: prepper_docs.py aus der Sicherung und docs/ wie vorher (neue Versionsdateien entfernt, rotierte zurueck).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
W=/tmp/commit58-apply
# Nur fuer Simulationen auf einem Testport (nie 5000): anderer Projektordner, Arbeitsordner, Uhrzeit
if [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then
  DASH_DIR="${C58_SIM_DIR:-$DASH_DIR}"; W="${C58_SIM_W:-$W}"
fi
F="$DASH_DIR/prepper_docs.py"
D="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
KEEP_LAST=3
KNOWN_P16="41f34abc4cabeb5a"      # prepper_docs.py vor dokuStand (Generator-Version 2, docsVer commit38)
KNOWN_P16N="43032d218135e329"     # prepper_docs.py nach dokuStand (Generator-Version 3, Ziel)
KNOWN_D16="7d494c1a21e50e96"   # dashboard.py Zielstand commit57 - wird nicht veraendert
KNOWN_D16_56="35fbc0604b09c0dd" # dashboard.py Zielstand commit56 (dann erst commit57)
declare -A BASE57=([lage_pages.py]=a9740c629a41806c [ups_manager.py]=ef0b9e3d4bf42003 [prepper_sdr.py]=264ef34996e17753 [prepper_evlog.py]=8bffd396972b60fa)
DOCS="$DASH_DIR/docs"
GEN_RAN=0
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
echo "=== dokuStand apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Projektbeschreibung auf Stand commit57 (prepper_docs.py Generator-Version 3), Dashboard-Port $PORT ==="
mkdir -p "$(dirname "$W")"
exec 9>"$W.lock"
flock -n 9 || stop "ein anderer commit58-Lauf ist aktiv (Sperre $W.lock)"
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/stub"
EXPECT_PPK="0989f7fe3a6af85df006a97385c05853523f29ad862cd1dc86c58618b8d46c98"
cat > "$W/patch.py" << 'MK_PPK_EOF'
"""Patcher dokuStand. Aufruf: patch_dv.py QUELLE ZIEL EDITS. Idempotent: schon gepatcht -> Ziel = Quelle (Exit 0).
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
        print("prepper_docs.py: dokuStand teilweise/anders vorhanden (Stelle mehrfach)"); raise SystemExit(2)
    open(dst, "w", encoding="utf-8", newline="").write(s)
    print("prepper_docs.py: dokuStand schon drin"); raise SystemExit(0)
if any(new_in):
    print("prepper_docs.py: dokuStand teilweise vorhanden (%d von %d Stellen)" % (sum(new_in), len(E))); raise SystemExit(2)
for i, (o, n) in enumerate(E, 1):
    if s.count(o) != 1:
        print("prepper_docs.py: Stelle %d nicht eindeutig (%d): %s" % (i, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
open(dst, "w", encoding="utf-8", newline="").write(s)
print("prepper_docs.py: %d Stellen dokuStand" % len(E))
MK_PPK_EOF
EXPECT_EDT="e4b519aa0833b4589549eea9b6660119ba380562c0c5ba6a23bc3aabaa5eff86"
cat > "$W/edits.py" << 'MK_EDT_EOF'
# Stellen fuer dokuStand (commit58): prepper_docs.py, Basis sha16 41f34abc4cabeb5a (Generator-Version 2, docsVer commit38)
# Jede Stelle: (alt, neu). alt genau einmal in der Basis, neu genau einmal im Ergebnis. Nur Textkern (CORE), FILE_ROLES (nur neue Eintraege) und GEN_VERSION.
# Keine Seriennummern, keine Secrets; die vorhandenen Stick-Zeilen bleiben in diesem Patch unberuehrt.
PD_EDITS = [
    # 1) Kurzfassung: Umfang dashboard.py
    ('(dashboard.py, rund 23000 Zeilen), das ueber',
     '(dashboard.py, rund 25000 Zeilen; die Seitenvorlagen liegen seit pagesSplit in lage_pages.py), das ueber'),
    # 2) Modultabelle: neue Module
    ('| prepper_docs.py | Dieser Generator',
     '| lage_pages.py | Seitenvorlagen (nur Text: PAGE1-4, PAGE_ADSB, PAGE_SPEICHER, PAGE_UMWELT2, PAGE_PI, PAGE_MESH, PAGE_NEWS, PAGE_LUFT, PAGE_LOKALE_ENERGIE, PAGE_PEGEL; pagesSplit1-3, pegelSplit), darin auch die USV-Kachel #usvCard; dashboard.py importiert sie unter den alten Namen |\n'
     '| ups_manager.py | USV Eaton Ellipse PRO 650 VA / 400 W ueber NUT lesen (usvLesen commit55): ein Faden alle 2 s, eine Verbindung zu 127.0.0.1:3493, nur LIST-Befehle, nie ein Befehl an die USV, keine Seriennummer |\n'
     '| lage_clock.py, lage_disk.py | Uhr-Plausibilitaet (REL-06) bzw. Stufenplan bei knappem Speicher (REL-05; nur melden, loescht nie) |\n'
     '| lage_xml.py | gehaertetes Parsen externer XML-Feeds (Apotheken-Notdienst, News-RSS): defusedxml, hoechstens 2 MiB (secXml, secXmlDash) |\n'
     '| prepper_docs.py | Dieser Generator'),
    # 3) Dienste: Webserver und USV-Dienste
    ('- Systemeigene Units, die auf dem Pi',
     '- Webserver: seit perfWsgi (commit45) laeuft das Dashboard unter waitress (ein Prozess, 8 Arbeitsfaeden, kein Zugriffsprotokoll; fehlt waitress, startet es wie frueher mit Werkzeug). relWatch meldet den systemd-Herzschlag ab dem ersten Takt, relStop (commit39) sichert beim Beenden (SIGTERM) einmal die gedrosselt gespeicherten Zustaende.\n'
     '- USV (usvNut/usvLesen commit55, usvShutdown commit57): NUT 2.8.1 lokal im Modus standalone mit den Units nut-driver@eaton (USB), nut-server (upsd nur auf 127.0.0.1:3493) und nut-monitor (upsmon, seit commit57 aktiv). Konfiguration in /etc/nut (640 root:nut); das Zugangswort fuer upsmon wird auf dem Pi zufaellig erzeugt und nie ausgegeben. Nichts davon ist aus dem Netz erreichbar.\n'
     '- Systemeigene Units, die auf dem Pi'),
    # 4) Seitenkapitel: Rauchtest-Hinweis
    ('(26 Pruefungen, alle muessen HTTP 200 liefern; Liste im API-Katalog unten).',
     '(26 Pruefungen, alle muessen HTTP 200 liefern; Liste im API-Katalog unten). Die USV-Patches (ab commit55) pruefen zusaetzlich /lokale-energie und /api/usv.'),
    # 5) /lokale-energie: USV-Kachel
    ('Bei neuem Ausfall in der Naehe: Mesh-Meldung (Auto, mit Cooldown).',
     'Bei neuem Ausfall in der Naehe: Mesh-Meldung (Auto, mit Cooldown).\n'
     '- "USV-NOTSTROM-ZENTRALE" (#usvCard, eigene Kachel unter der N-ERGIE-Kachel; usvLesen commit55, usvAlarm commit56, usvShutdown commit57): Betrieb NETZ oder AKKU, Ladung, Last in W und in % von 400 W, Restlaufzeit (Schaetzung der USV, 5 min geglaettet, im Akkubetrieb sofort), Akku-Zustand SoH (lernt 14 Tage, Akku eingebaut 05.2026), letzter Selbsttest (ein Selbsttest der USV wird erkannt und loest nichts aus), Zeile Alarm (Ansage und Mesh bereit) und Zeile "Abschaltung bei 20 % oder 5 min · upsmon aktiv" (gelb, wenn upsmon fehlt oder die Schwellen abweichen). Ohne NUT oder Daten grau "keine USV-Daten", das Dashboard laeuft weiter. Erklaerung hinter "i". Daten: /api/usv, Verlauf archive/usv, Zustand usv_state.json; nie Seriennummern.'),
    # 6) /umwelt flach
    ('- "Waldbrand"-Kacheln und weitere Kacheln',
     '- Seit umweltFlach (commit53): Reihenfolge DWD, Wetter, Waldbrand, Stoersender/QRM, Gewitter, ODL, Sonne; eine Rahmenebene, Umbruch statt Abschneiden, Erklaerungen hinter "i"; Gewitter in Ruhe eine Zeile; Ereignisse 5 plus "mehr"; Abruf alle 120 s nur bei sichtbarem Tab. QRM (qrmRun/qrmLage commit54): veraltete Werte grau "veraltet" statt rot, "QRM steht" mit Grund und naechstem Versuch; eine QRM-Pause endet nach hoechstens 6 h.\n'
     '- "Waldbrand"-Kacheln und weitere Kacheln'),
    # 6b) /funk: Banner Mesh-Problem
    ('(funkHarden, mesh_session.py).',
     '(funkHarden, mesh_session.py). Bei einem Session-Fehler heisst der Banner "Mesh-Problem" (mesh2OneSession).'),
    # 7) /karte
    ('serverseitig gibt es nur das Geruest (/karte/res/<path> liefert Dateien).',
     'serverseitig gibt es nur das Geruest (/karte/res/<path> liefert Dateien).\n'
     '- mapUi und kartePop (commit51): Linien 4-6 px nach SNR, gleiche Strecke mehrerer Kanaele parallel versetzt; Klick auf Mast oder Linie = Popup (Name, Bundesland, Entfernung ab Kalchreuth, Hoehe, MainID/SubID, SNR-Verlauf 24 h aus GET /api/karte/hist, 60 s Cache). "Fernempfang" ab 150 km nur als Text, "Ueberreichweite verifiziert" nur bei empfangener TII.'),
    # 8) /pi: Audio-Kachel ueber der Sicherung
    ('- "SICHERUNG" (#backupBox)',
     '- "Audio / Lautsprecher" (#audioBox, audioUi commit50; direkt ueber der Sicherung): Lautsprecher am 3,5-mm-Ausgang (audioKern commit49). Schalter INFO und WARNUNG (anfangs AUS), Lautstaerke-Regler 0-100 % (bleibt gespeichert, audio_cfg.json), Stumm hoechstens 8 h, Nachtruhe 22-07 Uhr, Testknopf und Knopf "Audio-Pegel testen" (Probegong, usvAlarm commit56, 10 s Sperre). Ein Test geht nie ins Mesh.\n'
     '- "SICHERUNG" (#backupBox)'),
    # 9) API-Katalog: neue Endpunkte
    ('| /static/vendor/chart-4.4.1.min.js | GET |',
     '| /api/audio/status, /api/audio/cfg, /api/audio/test | GET/POST | Audio-Kachel (audioKern/audioUi): Zustand lesen; POST Schalter/Lautstaerke/Stumm setzen bzw. Test (art pegel = Probegong); nur von der eigenen Seite (sameOrigin), sendet nie ins Mesh |\n'
     '| /api/geo/status | GET | Zustand der Ortsbezug-Bewertung der Warntexte (geoRelevanz); nur lesen |\n'
     '| /api/karte/hist | GET | SNR-Verlauf 24 h (15-min-Mittel) fuer das Karten-Popup (kartePop); nur lesen, 60 s Cache |\n'
     '| /api/usv | GET | USV-Werte fuer #usvCard (usvLesen) mit den Feldern alarm (usvAlarm) und shutdown (usvShutdown); nur lesen, keine Seriennummer |\n'
     '| /api/perfwsgi/status, /api/perf03cache/status, /api/speedasync/status | GET | Zustand der Leistungs-Schichten perfWsgi, perf03Cache und speedAsync; nur lesen |\n'
     '| /x, /y | (nur Selbsttest) | Attrappen im Selbsttest der Schicht meshPost auf einer eigenen Test-App; im laufenden Dashboard nie registriert |\n'
     '| /static/vendor/chart-4.4.1.min.js | GET |'),
    # 10) Speedtest-Zeile
    ('| /api/speedtest, /api/speedtest/history, /api/download_test | GET/POST | Ookla-Speedtest starten/lesen, Verlauf; aelterer Download-Test |',
     '| /api/speedtest, /api/speedtest/history, /api/download_test | GET/POST | Ookla-Speedtest starten/lesen, Verlauf; aelterer Download-Test; seit speedAsync (commit47) antworten Start und Download-Test sofort mit HTTP 202, die Messung laeuft im Hintergrund |'),
    # 11) Alarmregeln: Ortsbezug, Lautsprecher, USV
    ('- Alarmweg Hobby/Stick 2: keiner mehr',
     '- Ortsbezug (geoRelevanz, commit48): BR24/ASA-Warntexte werden nach Ort bewertet. Ausland ohne DE-Bezug = INFO (grau); Ausland mit DE-Folgen (Strahlung, Pandemie ...) oder Text ohne Ort und ohne amtlichen Begriff = WARNUNG (nur Anzeige); Ort in Bayern/Franken/DE mit amtlichem Begriff = rot wie bisher; Ort ohne amtlichen Begriff = rot nur als Anzeige (kein Mesh, kein Ton), bis NINA, ASA oder DWD binnen 30 min bestaetigen. Ortsliste geo_relevanz.json (editierbar, eingebauter Rueckfall).\n'
     '- Lautsprecher (audioKern, commit49): Warteschlange KATASTROPHE > WARNUNG > INFO. KATASTROPHE = Echtalarm (teil4) mit 100 %, danach wieder der eingestellte Wert; INFO und WARNUNG anfangs AUS; Nachtruhe 22-07 Uhr ausser KATASTROPHE; Stumm hoechstens 8 h; eigene Toene ueber aplay mit Zeitlimit. Der Lautsprecher sendet nichts.\n'
     '- USV-Netzausfall (usvAlarm, commit56): nach bestaetigtem Ausfall (20 s ohne Netz) einmal Gong und Ansage, auch nachts, mit der Regler-Lautstaerke (Stumm gilt); bei 5 min Restlaufzeit eine zweite Ansage; bei Netzrueckkehr nur ein kurzer Ton. Ein Selbsttest der USV loest nie aus. Mesh nur ueber den Heartbeat-Punkt STROM (Kapitel 8).\n'
     '- Abschaltung (usvShutdown, commit57): upsmon (primary) faehrt den Pi bei 20 % Ladung oder 5 min Restlaufzeit herunter (die Low-Battery-Meldung der USV selbst wird ignoriert, Schwellen per override). Danach schaltet die USV den Ausgang nach 20 s ab (killpower) und bei Netzrueckkehr nach 30 s wieder ein; der Pi startet neu. Das Dashboard zeigt das nur an und loest nie etwas aus; es gibt keine Mesh-Meldung vor dem Herunterfahren.\n'
     '- Alarmweg Hobby/Stick 2: keiner mehr'),
    # 12) Mesh: Heartbeat nur bei Problem
    ('- Echtalarme (ASA/NINA/BR24-Notfall) zusaetzlich ueber mesh_router.py',
     '- Heartbeat Mesh 1 (hbProblem, commit52): der stuendliche "HB HH:MM / Lage OK / ..." nach der Wettermeldung entfaellt. Gemeldet wird nur ein echtes Problem (Lage nicht OK, ASA nicht OK, SDR ohne Daten, Netzfrequenz ausserhalb 49,800-50,200 Hz, Uplink weg; seit usvAlarm auch STROM = USV im Akkubetrieb), einmal je Problem nach 120 s plus eine Entwarnung; je Problem hoechstens alle 6 h, zusammen hoechstens 3 je Stunde; Probe und Test nie.\n'
     '- Echtalarme (ASA/NINA/BR24-Notfall) zusaetzlich ueber mesh_router.py'),
    # 13) Reihenfolge der Patches
    ('angepasst (Generator-Version 2).',
     'angepasst (Generator-Version 2).\n\n'
     '- Danach (commit39 bis 58): relStop (39), asyncMini (40), pagesSplit1-3 und pegelSplit (41-44, Seitenvorlagen nach lage_pages.py), perfWsgi (45, waitress), perf03Cache (46), speedAsync (47), geoRelevanz (48), audioKern (49), audioUi (50), kartePop (51), hbProblem (52), umweltFlach (53), qrmLage/evlFix/qrmRun (54), usvNut/usvLesen (55), usvAlarm (56), usvShutdown (57) und dokuStand (58, nur diese Datei, Generator-Version 3). Hier nachgetragen sind ausserdem aeltere Schichten ohne eigenen Abschnitt: relWatch, perfKeep, sameOrigin, alarmFaden, dbVis, mapUi, modDead, secXmlDash, wxSlot.'),
    # 14) Schichten-Tabelle
    ('\n\n- Dateien ausserhalb der Schichten-Marker (Module)',
     '\n| relWatch | systemd-Herzschlag (WATCHDOG=1) ab dem ersten Takt, nur unter systemd mit WatchdogSec (REL-01) |\n'
     '| perfKeep | keep-last.json nur bei Aenderung schreiben, /pi nimmt den Ping aus dem Zwischenspeicher |\n'
     '| sameOrigin | zentrale Herkunftspruefung aller aendernden Anfragen (POST usw.); fremde Herkunft = HTTP 403 (SEC-05) |\n'
     '| alarmFaden | NINA und DWD in eigenem Faden mit eigenem Intervall statt im 15-min-Zyklus (PERF-02) |\n'
     '| dbVis | Zeile SQLite-Zustand in der Datenquellen-Kachel auf /pi: HEALTHY (WAL-Mode), WARNUNG oder FEHLER |\n'
     '| mapUi | /karte: Linienbreite nach SNR, unbekannte TII-Traeger einklappbar, Status-Ticker |\n'
     '| modDead | toter Code und doppelte Definitionen entfernt (MOD-08) |\n'
     '| secXmlDash | Apotheken-Notdienst und News ueber lage_xml.fetch_root (defusedxml, 2 MiB) |\n'
     '| wxSlot | Wetter-Slot wird nachgeholt (3-h-Takt), Ergebnis je Slot in /api/sysboot/status |\n'
     '| relStop | Speichern beim Beenden (SIGTERM), REL-10 (commit39) |\n'
     '| asyncMini | Lage-Seite ohne verwaisten Skriptblock (commit40) |\n'
     '| pagesSplit1, pagesSplit2, pagesSplit3, pegelSplit | Seitenvorlagen byte-genau nach lage_pages.py verschoben; Routen unveraendert (commit41-44) |\n'
     '| perfWsgi | waitress statt Werkzeug-Entwicklungsserver, 8 Arbeitsfaeden (PERF-01, commit45) |\n'
     '| perf03Cache | /api/frequenz aus dem Zwischenspeicher (hoechstens 60 s), /pegel Stale-While-Revalidate (commit46) |\n'
     '| speedAsync | Speedtest und Download-Test im Hintergrund, Antwort HTTP 202 (commit47) |\n'
     '| geoRelevanz | Ortsbezug der BR24/ASA-Warntexte (INFO/WARNUNG/rot), Bestaetigung binnen 30 min, geo_relevanz.json, /api/geo/status (commit48) |\n'
     '| audioKern | Lautsprecher-Warteschlange KATASTROPHE > WARNUNG > INFO, Nachtruhe, Stumm, audio_cfg.json, /api/audio/* (commit49) |\n'
     '| audioUi | Audio-Kachel #audioBox auf /pi ueber der Sicherung (commit50) |\n'
     '| kartePop | Karten-Popup fuer Mast und Linie, parallele Linien, /api/karte/hist (commit51) |\n'
     '| hbProblem | Heartbeat Mesh 1 nur bei echtem Problem plus Entwarnung (commit52) |\n'
     '| umweltFlach | /umwelt flach, feste Reihenfolge, Abruf nur bei sichtbarem Tab (commit53) |\n'
     '| qrmRun | Anzeige QRM-Planer-Zustand: veraltet grau, "QRM steht" mit Grund (commit54) |\n'
     '| qrmLage (prepper_sdr.py) | QRM-Pause laeuft nach hoechstens 6 h ab, Waechter "QRM steht" ab 1 h ohne Messung (commit54) |\n'
     '| evlFix (prepper_evlog.py) | Ereignis-Log verwirft Ereignisse mit unplausiblem Start (Uhrsprung), Altersgrenze (commit54) |\n'
     '| usvLesen | USV ueber NUT lesen (ups_manager.py), Kachel #usvCard auf /lokale-energie, /api/usv (commit55) |\n'
     '| usvAlarm | Netzausfall: Gong und Ansage, zweite Ansage bei 5 min, Mesh-Punkt STROM, Knopf "Audio-Pegel testen" (commit56) |\n'
     '| usvShutdown | Anzeige der Abschaltung durch upsmon (20 % oder 5 min, killpower); loest selbst nie etwas aus (commit57) |\n'
     '\n- Dateien ausserhalb der Schichten-Marker (Module)'),
    # 15) Zuordnungstabelle
    ('| Logs, Schreiblast, lokale Chart.js |',
     '| Seitenvorlagen | lage_pages.py, dashboard.py | pagesSplit1-3, pegelSplit | @@FI lage_pages.py@@ |\n'
     '| USV: Anzeige, Ansage, Abschaltung | ups_manager.py, dashboard.py, lage_pages.py | usvLesen, usvAlarm, usvShutdown | @@FI ups_manager.py@@ |\n'
     '| Lautsprecher, Ortsbezug, Heartbeat | dashboard.py | audioKern, audioUi, geoRelevanz, hbProblem | @@FI dashboard.py@@ |\n'
     '| Logs, Schreiblast, lokale Chart.js |'),
    # 16) Entscheidungen
    ('| Projektbeschreibung | Kachel ganz unten auf /pi',
     '| USV und Abschaltung (Okt. 2026) | NUT nur lokal; upsmon faehrt den Pi bei 20 % oder 5 min herunter, die USV schaltet danach ab und bei Netz wieder ein; keine Mesh-Meldung vor dem Herunterfahren; das Dashboard zeigt nur an |\n'
     '| Heartbeat nur bei Problem | kein stuendlicher HB mehr; Meldung je Problem plus Entwarnung (hbProblem) |\n'
     '| Lautsprecher | INFO und WARNUNG anfangs aus, Nachtruhe 22-07 Uhr, Stumm hoechstens 8 h, Tests nie ins Mesh |\n'
     '| Projektbeschreibung | Kachel ganz unten auf /pi'),
    # 17) Diagnose (nur lesend)
    ('curl -sI http://127.0.0.1:5000/static/vendor/chart-4.4.1.min.js',
     'curl -sI http://127.0.0.1:5000/static/vendor/chart-4.4.1.min.js\n'
     'systemctl is-active nut-driver@eaton nut-server nut-monitor\n'
     'upsc eaton ups.status\n'
     'curl -s http://127.0.0.1:5000/api/usv'),
    # 18) Fehlersuche
    ('- Uhr falsch: chrony und Stratum-1 pruefen',
     '- USV-Kachel grau "keine USV-Daten": die drei NUT-Units pruefen (siehe oben). upsc nur mit einzelnen Variablen aufrufen (die volle Ausgabe enthaelt die Seriennummer, nicht weitergeben). Nie upsmon -c fsd oder upscmd zum Testen: das schaltet Pi bzw. USV wirklich ab.\n'
     '- Uhr falsch: chrony und Stratum-1 pruefen'),
    # 19) Stand
    ('\n\n## Funktioniert (Stand der Erzeugung)',
     '\n- Danach (commit39 bis 58, Liste in Kapitel 11): Leistung (waitress, Zwischenspeicher, Seitenvorlagen in lage_pages.py), Ortsbezug der Warntexte, Lautsprecher, Karten-Popup, Heartbeat nur bei Problem, /umwelt flach, QRM-Anzeige, USV mit Ansage und automatischer Abschaltung; dokuStand (commit58) bringt diese Beschreibung auf diesen Stand (Generator-Version 3).\n\n'
     '## Funktioniert (Stand der Erzeugung)'),
    # 20) Offene Punkte
    ('- Echtzeituhr (zum Beispiel DS3231)',
     '- USV (commit55-57): die SoH-Basis lernt die ersten 14 Tage. Ein echter Abschalttest (Netzstecker ziehen) steht aus und geschieht nur mit Frank vor Ort, nie per Befehl.\n'
     '- Lautsprecher: Pegel mit "Audio-Pegel testen" einstellen; INFO/WARNUNG bei Bedarf bewusst einschalten.\n'
     '- Echtzeituhr (zum Beispiel DS3231)'),
    # 21) Glossar
    ('| Rauchtest | 26 Pruefungen',
     '| USV / NUT / upsmon | unterbrechungsfreie Stromversorgung / Network UPS Tools / Waechter, der bei Akku-Ende herunterfaehrt |\n'
     '| SoH / killpower | State of Health (Akku-Zustand) / Merker, nach dem die USV nach dem Herunterfahren abschaltet |\n'
     '| Rauchtest | 26 Pruefungen'),
    # 22) FILE_ROLES (nur neue Eintraege)
    ('    "prepper_docs.py": "Generator dieser',
     '    "lage_pages.py": "Seitenvorlagen (nur Text), von dashboard.py importiert",\n'
     '    "ups_manager.py": "USV ueber NUT lesen (nur LIST, nur Anzeige)",\n'
     '    "lage_clock.py": "Uhr-Plausibilitaet (REL-06)",\n'
     '    "lage_disk.py": "Stufenplan knapper Speicher (REL-05, nur melden)",\n'
     '    "lage_xml.py": "gehaertetes XML-Parsen der Feeds",\n'
     '    "prepper_docs.py": "Generator dieser'),
    # 23) Generator-Version
    ('GEN_VERSION = "2"', 'GEN_VERSION = "3"'),
]
PD_ANCHOR = None
MK_EDT_EOF
EXPECT_GRD="a06895494a32456dec385d1cfa9b2b56b5836016bc57974f418416e4b58ae026"
cat > "$W/guard.py" << 'MK_GRD_EOF'
"""AST-/Verhaltens-Guard dokuStand commit58 (nur prepper_docs.py). Aufruf:
  guard58.py revert NEU_VERZ ALT_VERZ EDITS     -> ALT_VERZ/prepper_docs.py = NEU ohne dokuStand (Rueckbau, byte-genau)
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
MARKERS = ["relWatch", "perfKeep", "sameOrigin", "alarmFaden", "dbVis", "mapUi", "modDead", "secXmlDash", "wxSlot", "relStop", "asyncMini", "pagesSplit1", "pagesSplit2",
           "pagesSplit3", "pegelSplit", "perfWsgi", "perf03Cache", "speedAsync", "geoRelevanz", "audioKern", "audioUi", "kartePop", "hbProblem", "umweltFlach", "qrmRun",
           "qrmLage", "evlFix", "usvLesen", "usvAlarm", "usvShutdown"]
REQUIRED = ["| " + m + " |" for m in MARKERS if not m.startswith("pagesSplit") and m not in ("pegelSplit", "qrmLage", "evlFix")] + [
            "| pagesSplit1, pagesSplit2, pagesSplit3, pegelSplit |", "| qrmLage (prepper_sdr.py) |", "| evlFix (prepper_evlog.py) |",
            "USV-NOTSTROM-ZENTRALE", "#usvCard", "#audioBox", "/api/usv", "/api/audio/status, /api/audio/cfg, /api/audio/test", "/api/karte/hist", "/api/geo/status",
            "/api/perfwsgi/status, /api/perf03cache/status, /api/speedasync/status", "NUT 2.8.1", "nut-driver@eaton", "nut-server", "nut-monitor", "Akku eingebaut 05.2026",
            "Abschaltung bei 20 % oder 5 min", "killpower", "Audio-Pegel testen", "Mesh-Problem", "| lage_pages.py |", "| ups_manager.py |", "| lage_xml.py |",
            "lage_clock.py, lage_disk.py", "rund 25000 Zeilen", "dokuStand", "Generator-Version 3", "Heartbeat Mesh 1 (hbProblem", "Nachtruhe 22-07", "STROM",
            "Ein Selbsttest der USV loest nie aus", "keine Mesh-Meldung vor dem Herunterfahren", "nie per Befehl", "upsc eaton ups.status",
            "Zeile \"Abschaltung bei 20 % oder 5 min \u00b7 upsmon aktiv\""]
FORBIDDEN_ANY = ["rund 23000 Zeilen", "@127.0.0.1"]
SN_RE = re.compile(r"(?i)(\b\d{8,}\b|ups\.serial|device\.serial|\bSN\b|serial(nummer)?\s*[:=])")
NEW_ROLES = {"lage_pages.py", "ups_manager.py", "lage_clock.py", "lage_disk.py", "lage_xml.py"}
NEW_FI = {"@@FI lage_pages.py@@", "@@FI ups_manager.py@@", "@@FI dashboard.py@@"}
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
        assert s.count(n) == 1, "Stelle dokuStand nicht genau einmal: " + n.strip().splitlines()[0][:70]
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
    roles = None
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
            elif nm == "FILE_ROLES":
                assert isinstance(node.value, ast.Dict), "FILE_ROLES ist kein dict"
                roles = {}
                for k, v in zip(node.value.keys, node.value.values):
                    assert isinstance(k, ast.Constant) and isinstance(k.value, str) and isinstance(v, ast.Constant) and isinstance(v.value, str), "FILE_ROLES: nur Text-Eintraege"
                    roles[k.value] = v.value
                node.value = ast.Constant(value="@ROLES@")
    assert core is not None and gen is not None and roles is not None, "CORE, GEN_VERSION oder FILE_ROLES fehlt"
    _split.roles = roles
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
        P.append("AST weicht ausserhalb von CORE/GEN_VERSION/FILE_ROLES ab (Programmcode veraendert)")
    if g0 != "2" or g1 != "3":
        P.append("GEN_VERSION: Basis %r -> Ergebnis %r (erwartet '2' -> '3')" % (g0, g1))
    _split(old); r0 = dict(_split.roles); _split(new); r1 = dict(_split.roles)
    if any(r1.get(k) != v for k, v in r0.items()):
        P.append("FILE_ROLES: vorhandener Eintrag geaendert oder entfernt")
    if set(r1) - set(r0) != NEW_ROLES:
        P.append("FILE_ROLES: neue Eintraege %s statt %s" % (sorted(set(r1) - set(r0)), sorted(NEW_ROLES)))
    if SECRET_RE.search(" ".join(r1.values())) or SN_RE.search(" ".join(r1.values())):
        P.append("FILE_ROLES: Secret-/Seriennummer-aehnlicher Text")
    m0 = re.findall(r"@@[^@\n]+@@", c0); m1 = re.findall(r"@@[^@\n]+@@", c1)
    from collections import Counter
    d_m = Counter(m1); d_m.subtract(Counter(m0))
    if any(v < 0 for v in d_m.values()) or sorted(k for k, v in d_m.items() if v > 0) != sorted(NEW_FI) or any(v > 1 for v in d_m.values()):
        P.append("@@-Marken des Textkerns veraendert (%d -> %d, neu %s)" % (len(m0), len(m1), sorted(k for k, v in d_m.items() if v)))
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
    nna = sorted(set(ch for l in added if re.search(r"[^\x00-\x7f\u00b7]", l) and not any(l[:30] == r[:30] for r in removed) for ch in re.findall(r"[^\x00-\x7f\u00b7]", l)))
    if nna:
        P.append("neue Zeile mit Nicht-ASCII-Zeichen: %s" % nna)
    sn = SN_RE.search(at)
    if sn:
        P.append("neuer Text enthaelt Seriennummer-aehnliches (%d Zeichen, Wert nicht ausgegeben)" % len(sn.group(0)))
    if sorted(re.findall(r"\b\d{8,}\b", c0)) != sorted(re.findall(r"\b\d{8,}\b", c1)):
        P.append("lange Zahlen (z. B. Seriennummern) im Textkern veraendert - nicht Teil von commit58")
    dl = c1.count("\n") - c0.count("\n")
    if not 55 <= dl <= 75:
        P.append("Zeilenzuwachs des Textkerns %+d ausserhalb 55..75" % dl)
    # Stellen: jede neue Stelle genau einmal, jede alte Stelle (soweit nicht Teil der neuen) nicht mehr da
    full = new
    for i, (o, n) in enumerate(edits, 1):
        if full.count(n) != 1:
            P.append("Stelle %d nicht genau einmal im Ergebnis (%d)" % (i, full.count(n)))
    if old.count("\n") + dl + len(NEW_ROLES) != new.count("\n"):
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
    print("check ok: AST ausser CORE/GEN_VERSION/FILE_ROLES gleich, GEN_VERSION 2 -> 3, 5 neue FILE_ROLES, %d Pflichttexte, Tabellen ok, keine Secrets/IPs/Seriennummern neu, Rueckbau byte-genau" % len(REQUIRED))
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
    for need in ("USV-NOTSTROM-ZENTRALE", "#audioBox", "/api/usv", "hbProblem", "Generator 3", "lage_pages.py", "ups_manager.py"):
        if need not in tn:
            P.append("neue Beschreibung ohne %r" % need)
    if "Generator 2" not in ta or "Generator 3" in ta:
        P.append("alte Beschreibung: Generator-Version nicht 2")
    if "Akku eingebaut 05.2026" in ta or "Akku eingebaut 05.2026" not in tn:
        P.append("Gegenprobe: alte Beschreibung kennt die USV schon (Test sinnlos)")
    for key in ("Routen (ast)", "Patch-Schichten (Marker)", "Programmdateien"):
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
    if [l for l in ha if "NACHTRAG" not in l.upper()] != [l for l in hn if "NACHTRAG" not in l.upper()] or len(hn) > len(ha):
        P.append("Kapitelliste unterschiedlich")
    nl = "\n".join(set(tn.split("\n")) - set(ta.split("\n")))
    if SECRET_RE.search(nl):
        P.append("neue Zeilen in der Beschreibung enthalten Secret-aehnliches")
    neu8 = sorted(x for x in set(re.findall(r"\b\d{8,}\b", tn)) - set(re.findall(r"\b\d{8,}\b", ta)) if not re.match(r"^20\d{6}$", x))
    if neu8:
        P.append("neue Beschreibung enthaelt neue lange Zahlen (Seriennummer?): %d" % len(neu8))
    if P:
        print("\n".join("VERSTOSS: " + p for p in P)); return 1
    ch = re.search(r"Routen \(ast\): (\d+) geprueft, (\d+) im Text, (\d+) als Nachtrag", rn)
    print("gen ok: beide Generatoren laufen im Sandkasten (--check schreibt nichts, Schreiblauf 2 Dateien, zweiter Lauf UNVERAENDERT); neu: Routen-Nachtrag %s -> %s, Marker-Nachtrag %s -> %s, TXT %d -> %d Zeilen" %
          (_nums(ra, "Routen (ast)"), _nums(rn, "Routen (ast)"), _nums(ra, "Patch-Schichten (Marker)"), _nums(rn, "Patch-Schichten (Marker)"), ta.count("\n"), tn.count("\n")))
    return 0


def mutants(new, old, edits):
    """(Name, mutierter Text) - jede Verfehlung muss check_text melden."""
    M = []
    for k in (0, 5, 9, 15, 23):
        o, n = edits[k]
        M.append(("Stelle %d zurueck" % (k + 1), new.replace(n, o, 1)))
    M.append(("GEN_VERSION nicht erhoeht", new.replace('GEN_VERSION = "3"', 'GEN_VERSION = "2"', 1)))
    M.append(("GEN_VERSION 4", new.replace('GEN_VERSION = "3"', 'GEN_VERSION = "4"', 1)))
    M.append(("Code geaendert: WIDTH", new.replace("WIDTH = 100", "WIDTH = 101", 1)))
    M.append(("Code geaendert: KEEP_DEFAULT", new.replace("KEEP_DEFAULT = 10", "KEEP_DEFAULT = 1", 1)))
    M.append(("Code geaendert: Rotation (Schreiben/Loeschen)", new.replace("os.unlink(os.path.join(DOCS, nm))", "os.unlink(os.path.join(BASE, nm))", 1)))
    M.append(("zusaetzlicher Import smtplib", new.replace("import urllib.request\n", "import urllib.request\nimport smtplib\n", 1)))
    M.append(("zusaetzlicher Netzaufruf", new.replace("def cell(x):", "def _x():\n    urllib.request.urlopen('http://example.org')\n\n\ndef cell(x):", 1)))
    M.append(("FILE_ROLES: alter Eintrag geaendert", new.replace('"smoke.sh": "Rauchtest-Skript (liest nur)"', '"smoke.sh": "Rauchtest"', 1)))
    M.append(("FILE_ROLES: alter Eintrag entfernt", new.replace('    "smoke.sh": "Rauchtest-Skript (liest nur)",\n', '', 1)))
    M.append(("FILE_ROLES: fremder neuer Eintrag", new.replace('    "lage_xml.py": "gehaertetes XML-Parsen der Feeds",\n', '    "lage_xml.py": "gehaertetes XML-Parsen der Feeds",\n    "x.py": "x",\n', 1)))
    M.append(("FILE_ROLES: Wert ist Ausdruck", new.replace('"lage_xml.py": "gehaertetes XML-Parsen der Feeds"', '"lage_xml.py": "geh" + "aertet"', 1)))
    M.append(("FILE_ROLES: Seriennummer", new.replace('"ups_manager.py": "USV ueber NUT lesen (nur LIST, nur Anzeige)"', '"ups_manager.py": "USV SN 12345678"', 1)))
    M.append(("@@AUTO-Marke entfernt", new.replace("@@AUTO meta@@", "", 1)))
    M.append(("@@FI-Marke fremd", new.replace("@@FI ups_manager.py@@", "@@FI config.py@@", 1)))
    M.append(("Syntaxfehler", new.replace("def cell(x):", "def cell(x:", 1)))
    M.append(("Pflichttext entfernt (USV-Kachel)", new.replace('"USV-NOTSTROM-ZENTRALE" (#usvCard', '"USV" (#usvCard', 1)))
    M.append(("Marker-Zeile entfernt (evlFix)", new.replace("| evlFix (prepper_evlog.py) |", "| evlFx (prepper_evlog.py) |", 1)))
    M.append(("Tabellenzeile mit zusaetzlicher Spalte", new.replace("| hbProblem | Heartbeat Mesh 1 nur", "| hbProblem | x | Heartbeat Mesh 1 nur", 1)))
    def inj(t):
        return new.replace("# Zweck, Zielgruppe, Leitprinzipien", t + "\n\n# Zweck, Zielgruppe, Leitprinzipien", 1)
    M.append(("Secret im Text (eingefuegt)", inj("- Zugang: password=geheim123")))
    M.append(("Bearer-Token im Text (eingefuegt)", inj("- Kopf: Bearer abcdefghijklmnop123")))
    M.append(("neue IP im Text (eingefuegt)", inj("- Knoten 10.20.30.40")))
    M.append(("Seriennummer 8 Ziffern (eingefuegt)", inj("- Stick 2 hat 12345678")))
    M.append(("Seriennummer ups.serial (eingefuegt)", inj("- upsc eaton ups.serial")))
    M.append(("Kuerzel SN (eingefuegt)", inj("- USV SN P41C")))
    mm = re.search(r"\b(\d{7})(\d)\b", new[new.index("CORE = "):])
    M.append(("vorhandene lange Zahl im Text geaendert", new.replace(mm.group(0), mm.group(1) + str((int(mm.group(2)) + 1) % 10), 1)))
    M.append(("Dreifach-Apostroph im Text (eingefuegt)", inj("- x " + "'" * 3 + " y")))
    M.append(("Umlaut im neuen Text (eingefuegt)", inj("- Gr\u00fcn")))
    M.append(("Tabelle ungleiche Spalten (eingefuegt)", inj("| a | b |\n| c |")))
    M.append(("EIA-Thema erwaehnt (eingefuegt)", inj("- EIA Schluessel")))
    M.append(("alter Umfang wieder da (eingefuegt)", inj("- rund 23000 Zeilen")))
    M.append(("E-Mail-artige NUT-Adresse (eingefuegt)", inj("- upsc eaton@127.0.0.1")))
    M.append(("neue @@-Marke (eingefuegt)", inj("@@AUTO neu@@")))
    M.append(("Stelle 21 doppelt", inj(edits[20][1])))
    M.append(("Zeilenzuwachs zu gross", new.replace("\n\n## Funktioniert (Stand der Erzeugung)", "\n" + "\n".join("- Fuellzeile %d" % i for i in range(40)) + "\n\n## Funktioniert (Stand der Erzeugung)", 1)))
    M.append(("Zeile ausserhalb CORE (Kommentar)", new + "\n# nachtrag\n"))
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
echo "Basis prepper_docs.py sha16 $P16 ($(wc -l < "$F") Zeilen, $(lbl "$P16" "$KNOWN_P16" "Generator-Version 2, vor dokuStand" "$KNOWN_P16N" "dokuStand schon drin"))"
if [[ "$P16" != "$KNOWN_P16" && "$P16" != "$KNOWN_P16N" ]]; then
  echo "STOP: prepper_docs.py weicht vom erwarteten Stand ab (sha16 $P16, erwartet $KNOWN_P16 oder $KNOWN_P16N) - nichts geaendert."
  echo "      dokuStand passt nur auf die Generator-Version 2 (prepper_docs.py $KNOWN_P16). Lokale Aenderung oder ein anderer Docs-Stand? Bitte diese Ausgabe an Grok schicken."
  python3 "$PPK" "$F" "$W/work/x.py" "$EDT" 2>&1 | sed 's/^/      Befund: /' || true
  exit 1
fi
if [[ "$DS16" == "$KNOWN_D16_56" ]]; then stop "dashboard.py ist der Stand von commit56 ($DS16) - bitte erst commit57 einspielen, dann commit58"; fi
[[ "$DS16" == "$KNOWN_D16" ]] || stop "dashboard.py sha16 $DS16 ist nicht der Zielstand commit57 ($KNOWN_D16) - die Beschreibung passt nur zu commit57"
for bf in lage_pages.py ups_manager.py prepper_sdr.py prepper_evlog.py; do
  [[ -f "$DASH_DIR/$bf" ]] || stop "$bf fehlt im Projektordner (Basis commit57 erwartet)"
  b16=$(s16 "$DASH_DIR/$bf"); [[ "$b16" == "${BASE57[$bf]}" ]] || stop "$bf sha16 $b16 ist nicht der Zielstand commit57 (${BASE57[$bf]})"
done
echo "OK Basis commit57: dashboard.py $DS16, lage_pages.py, ups_manager.py, prepper_sdr.py, prepper_evlog.py wie erwartet"
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
docls() { { ls -1 "$DOCS" 2>/dev/null || true; } | sha256sum | cut -c1-16; }
DOCS_LS0=$(docls)
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
hmmin() { local hm; if [[ -n "${C58_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$C58_FAKE_HM"; echo $(( 10#${hm##*:} )); else echo $(( 10#$(date +%M) )); fi; }
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
python3 "$PPK" "$F" "$W/work/prepper_docs.py" "$EDT" > "$W/q.log" || { cat "$W/q.log"; stop "prepper_docs.py: Stelle fuer dokuStand nicht eindeutig (Datei vom Standard abweichend)"; }
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
nice -n 10 "$VPY" "$GRD" revert "$W/neu" "$W/alt" "$EDT" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: dokuStand im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/prepper_docs.py")" == "$KNOWN_P16" ]] || stop "Guard: Stand ohne dokuStand ist nicht die bekannte Basis ($(s16 "$W/alt/prepper_docs.py") statt $KNOWN_P16)"
nice -n 10 "$VPY" "$GRD" check "$W/alt" "$W/neu" "$EDT" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "Guard dokuStand meldet Verstoss"; }
cat "$W/g.log"
nice -n 10 "$VPY" "$GRD" gen "$W/alt" "$W/neu" "$DASH_DIR" "$W/gen" > "$W/gg.log" 2>&1 || { cat "$W/gg.log"; stop "Generator-Probe im Sandkasten meldet Verstoss"; }
cat "$W/gg.log"
nice -n 10 "$VPY" "$GRD" mutate "$W/neu" "$W/alt" "$EDT" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "Guard-Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^Mutationstest" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c _; for _ in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep "${C58_RETRY_S:-6}"; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local _; for _ in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte /lokale-energie)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status /api/usv)
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
  if [[ "$NEED_P" == 0 ]]; then echo "  Zustand: dokuStand ist schon installiert - ein echter Lauf aendert die Datei nicht und erzeugt nur dann eine neue Version, wenn sich der Stand geaendert hat."
  else echo "  Ein echter Lauf wuerde: prepper_docs.py ersetzen (Sicherung prepper_docs.py.bak-commit58-ZEIT, letzte $KEEP_LAST), $([[ "$NEED_RESTART" == 1 ]] && echo "prepper-dashboard neu starten (eine sudo-Passwortabfrage)" || echo "keinen Dienst neu starten"), einmal python3 prepper_docs.py ausfuehren (neue Version in docs/) und die ${#PAGES[@]} Seiten, ${#APIS[@]} APIs und die Docs-Endpunkte pruefen."; fi
  echo "COMMIT $COMMIT_ARG dokustand=dry fertig"
  FINISHED=1
  exit 0
fi
# ---------- 4) Installieren ----------
BK="$F.bak-commit58-$TS"
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
rb_quiet() {
  local ok=0
  if [[ -f "$BK" ]]; then
    if cp -p "$BK" "$F.c58-rb.$$" && mv -f "$F.c58-rb.$$" "$F"; then ok=1; fi
  fi
  if [[ "$ok" == 1 && "$(s16 "$F")" == "$KNOWN_P16" ]]; then echo "OK Rollback: prepper_docs.py wieder sha16 $KNOWN_P16 (aus $(basename "$BK"))"
  else echo "FEHLER Rollback: prepper_docs.py ist NICHT sicher zurueckgesetzt - von Hand: cp -p $BK $F"; fi
  if [[ "$GEN_RAN" == 1 && -d "$W/docs0" ]]; then
    local f bn dok=1
    for f in "$DOCS"/*; do [[ -e "$f" ]] || continue; bn=$(basename "$f"); [[ -e "$W/docs0/$bn" ]] || rm -f -- "$f" || dok=0; done
    for f in "$W/docs0"/*; do [[ -e "$f" ]] || continue; bn=$(basename "$f"); [[ -e "$DOCS/$bn" ]] || cp -p "$f" "$DOCS/$bn" || dok=0; done
    if [[ "$dok" == 1 && "$(docls)" == "$DOCS_LS0" ]]; then echo "OK Rollback: docs/ wie vorher (neue Versionsdateien entfernt)"; else echo "FEHLER Rollback: docs/ nicht sicher wie vorher - Vorher-Kopie liegt in $W/docs0"; fi
  fi
  if [[ "$RESTARTED" == 1 ]]; then
    sudo -n systemctl restart prepper-dashboard 2>/dev/null || sudo systemctl restart prepper-dashboard || echo "FEHLER: Neustart nach Rollback fehlgeschlagen - von Hand: sudo systemctl restart prepper-dashboard"
    for _ in $(seq 1 40); do [[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] && break; sleep "${C58_RETRY_S:-3}"; done
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
  cp "$W/work/prepper_docs.py" "$F.c58-new.$$"
  chmod --reference="$F" "$F.c58-new.$$" 2>/dev/null || chmod 644 "$F.c58-new.$$"
  [[ "$(s16 "$F.c58-new.$$")" == "$KNOWN_P16N" ]] || { rm -f "$F.c58-new.$$"; rb "temporaere Datei hat falsche Pruefsumme"; }
  mv -f "$F.c58-new.$$" "$F"
  echo "OK prepper_docs.py ersetzt (atomar per mv), Sicherung: $(basename "$BK")"
  ALL=$({ ls -1 "$F.bak-commit58-"* 2>/dev/null || true; } | sort)
  NB=$(echo "$ALL" | grep -c . || true)
  if [[ "${NB:-0}" -gt "$KEEP_LAST" ]]; then
    echo "$ALL" | head -n $(( NB - KEEP_LAST )) | while IFS= read -r old; do rm -f -- "$old" && echo "Rotation: $(basename "$old") entfernt (keepLast $KEEP_LAST)"; done
  fi
else
  echo "OK dokuStand ist schon installiert - keine Aenderung an prepper_docs.py, keine neue Sicherung"
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
  for _ in $(seq 1 40); do [[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] && [[ "$(code "$B/api/time")" == 200 ]] && break; sleep "${C58_RETRY_S:-3}"; done
  [[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] || rb "prepper-dashboard laeuft nach dem Neustart nicht"
fi
CHK=$(cd "$DASH_DIR" && PRDOCS_OUT="$W/chk-out" timeout 120 nice -n 10 python3 "$F" --check --no-live 2>&1) || rb "python3 prepper_docs.py --check --no-live schlaegt fehl: $(echo "$CHK" | tail -2 | tr '\n' ' ' | cut -c1-200)"
echo "$CHK" | grep -q "Trockenlauf (--check): nichts geschrieben" || rb "--check meldet den Trockenlauf nicht"
{ echo "$CHK" | grep -E "^(Routen \(ast\)|Patch-Schichten \(Marker\)|Nachtrag-Abschnitte|Hinweise der Sammler)" || true; } | sed 's/^/   | /' | cut -c1-160
echo "OK python3 prepper_docs.py --check --no-live laeuft mit der neuen Datei (nur lesend, nichts geschrieben)"
for p in "${PAGES[@]}" "${APIS[@]}" "${DOCAPIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rb "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs (zusammen $(( ${#PAGES[@]} + ${#APIS[@]} ))) sowie ${#DOCAPIS[@]} Docs-Endpunkte antworten wie vorher ($(for p in "${PAGES[@]}" "${APIS[@]}" "${DOCAPIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
# ---- Neue Beschreibung erzeugen (einmal; liest nur, schreibt nur docs/) ----
CUR0=$(echo "$DOCSJ0" | sed -n 's/.*current=\([0-9-]*\).*/\1/p')
HAVE3=0
if [[ "$NEED_P" == 0 && -n "$CUR0" ]]; then
  "${CURL[@]}" "$B/api/docs/download?fmt=txt&v=$CUR0" -o "$W/doc0.txt" || true
  grep -q "Generator 3" "$W/doc0.txt" 2>/dev/null && HAVE3=1
fi
if [[ "$HAVE3" == 1 ]]; then
  GOUT="UNVERAENDERT: aktuelle Version v$CUR0 ist schon mit Generator 3 erzeugt (Wiederholung) - nicht neu erzeugt"
  echo "OK $GOUT"
else
mkdir -p "$DOCS"; rm -rf "$W/docs0"; cp -a "$DOCS" "$W/docs0" || rb "Vorher-Kopie von docs/ nicht moeglich"
GEN_RAN=1
GOUT=$(cd "$DASH_DIR" && timeout 600 nice -n 10 python3 "$F" 2>&1) || { echo "$GOUT" | tail -5 | sed 's/^/   | /'; rb "python3 prepper_docs.py (Erzeugen) schlaegt fehl"; }
fi
{ echo "$GOUT" | grep -E "^(Routen \(|Kachel-|Programmdateien|Patch-Schichten \(Marker\)|Schwaerzungen|Nachtrag-Abschnitte|Hinweise der Sammler)" || true; } | sed 's/^/   | /' | cut -c1-160
NEWV=$(echo "$GOUT" | sed -n 's/^OK Version v\([0-9-]*\):.*/\1/p' | head -1)
if [[ -n "$NEWV" ]]; then echo "OK neue Beschreibung v$NEWV in docs/ erzeugt (Generator 3)"
elif echo "$GOUT" | grep -q "UNVERAENDERT"; then echo "OK Beschreibung UNVERAENDERT (Stand schon erzeugt) - keine neue Version"
else echo "$GOUT" | tail -5 | sed 's/^/   | /'; rb "python3 prepper_docs.py meldet weder eine neue Version noch UNVERAENDERT"; fi
NNACH=$(echo "$GOUT" | sed -n 's/^Nachtrag-Abschnitte: \([0-9]*\).*/\1/p' | head -1)
DOCSJ1=$(docsj)
CUR=$(echo "$DOCSJ1" | sed -n 's/.*current=\([0-9-]*\).*/\1/p')
if [[ -n "$NEWV" ]]; then [[ "$CUR" == "$NEWV" ]] || rb "/api/docs/list zeigt nicht die neue Version (current=$CUR, erwartet $NEWV)"; fi
[[ -n "$CUR" ]] || rb "/api/docs/list zeigt keine Version ($DOCSJ1)"
c=$(code_r "$B/api/docs/download?fmt=txt&v=$CUR")
[[ "$c" == 200 ]] || rb "/api/docs/download v$CUR liefert $c"
"${CURL[@]}" "$B/api/docs/download?fmt=txt&v=$CUR" -o "$W/doc.txt" || true
grep -q "Generator 3" "$W/doc.txt" && grep -q "USV-NOTSTROM-ZENTRALE" "$W/doc.txt" || rb "heruntergeladene Beschreibung v$CUR ist nicht Generator 3 mit USV-Abschnitt"
echo "OK /api/docs/list: $DOCSJ1; Download v$CUR (txt) -> 200, Generator 3, USV-Abschnitt vorhanden; Nachtrag-Abschnitte: ${NNACH:-?}"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); P1=$(grep -o 'Projektbeschreibung' "$W/pi.html" | wc -l || true)
[[ "$R1" -ge 1 && "$P1" -ge 1 ]] || rb "/pi liefert Sicherung/Projektbeschreibung nicht mehr (doPrepperRestore ${R1}x, Projektbeschreibung ${P1}x)"
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand kann sich zwischendurch geaendert haben; dokuStand aendert die Kachel nicht"
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
echo "OK docs/: $(ls -1 "$DOCS" 2>/dev/null | grep -c . || true) Dateien (je Version TXT + MD, Standard behaelt 10 Versionen)"
echo "OK Datenbank, Sende- und Alarmregeln und alle Dienste unberuehrt"
[[ -f "$BK" ]] && echo "Backup: $(basename "$BK") (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  prepper_docs.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-commit58-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -p $LB $F" || echo "Rueckweg: keine commit58-Sicherung vorhanden (prepper_docs.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep GEN_VERSION /home/fmg/prepper-dashboard/prepper_docs.py"
echo "  curl -s http://127.0.0.1:$PORT/api/docs/list"
echo "In der Kachel PROJEKTBESCHREIBUNG LAGE PI (ganz unten auf /pi) steht jetzt die Version v$CUR. Nichts gesendet (kein Mesh, kein Telegram, keine Alarme)."
FINISHED=1
echo "COMMIT $COMMIT_ARG dokustand=1 fertig docs=v$CUR prepper_docs=$(s16 "$F")"
