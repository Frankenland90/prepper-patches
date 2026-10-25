#!/bin/bash
set -eEuo pipefail
# relHygiene (commit19b, ersetzt commit19: der Guard prueft das Ersatz-JS jetzt auch ohne node statisch - auf der Pi gibt es kein node): Audit REL-04 (ruhigere, begrenzte Protokolle) und REL-09 (Chart.js lokal statt CDN). Sendet nichts (kein Mesh, kein Telegram, keine Alarme), aendert keine Alarm-, Sende- oder Abruflogik.
#  REL-04: (1) dashboard.py: Zugriffsprotokoll des Werkzeug-Servers gefiltert - erfolgreiche Anfragen (2xx/3xx) entfallen im Journal, Fehler bleiben (5xx immer, 4xx hoechstens 60 je Minute); alle anderen Meldungen unveraendert.
#   (2) mesh_hang_watchdog.py: Protokoll mesh_hang_watchdog.log wird ab 1 MB im Programm rotiert (.1 bis .3), ohne logrotate und ohne root; Verhalten des Watchdogs sonst unveraendert.
#   (3) tools/schreiblast.py: kleines Hilfsprogramm, misst NUR LESEND und nur auf Aufruf die Schreiblast (nichts laeuft dauerhaft).
#   Journal: das vorhandene Limit (Drop-in aus sysBoot) wird nur gelesen und gemeldet, nichts angelegt. logrotate wird nur geprueft und nie installiert.
#  REL-09: Chart.js 4.4.1 (npm-Paket, sha256 geprueft) wird vom Dashboard selbst ausgeliefert: static/vendor/chart-4.4.1.min.js unter /static/vendor/chart-4.4.1.min.js (Cache 1 Jahr, ETag).
#   Alle 7 CDN-Stellen (dashboard.py 6 Seiten + 1 dynamischer Lader, funk_health.py 1) zeigen auf die lokale Adresse, an derselben Stelle (Ladereihenfolge unveraendert). Fehlt die Datei oder stimmt die Pruefsumme nicht, liefert
#   dieselbe Adresse einen Ersatz: die Seiten zeigen "Diagramm nicht verfuegbar" statt eines JavaScript-Fehlers; alles andere laeuft weiter. Kein neuer Abruf nach aussen.
#  prepper_docs.py: beschreibt Log-Richtlinie, lokale Chart.js und die Sicherung nach relBackup/relBackup2; neue Version in docs/.
# Basis streng (sha16): dashboard eb3ac3f73280bd47, prepper_docs 2d23d96499583ce2, funk_health f89deb0cb9a6ff21, mesh_hang_watchdog 1afa8becde24bc89 (oder relHygiene schon drin); prepper_sdr/sdr_manager/database/mesh_router/lagegeo werden nicht angefasst (nur Vorher/Nachher-Vergleich; Abweichung von der Erwartung nur Hinweis, weil parallele Patches sie aendern duerfen). Sonst STOP.
# Neustart: nur prepper-dashboard (und nur wenn dashboard.py/funk_health.py geaendert werden). prepper-sdr, mesh-bridge und Timer werden nicht angefasst. Sicherungen *.bak-relhygiene-ZEIT: letzte 3 je Datei. Keine Datenbank-Aenderung (daher keine SQLite-Sicherung).
# Aufruf: bash /tmp/apply-relhygiene2.sh commit19b [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
unset PRDOCS_NOW PRDOCS_SYSTEMCTL PRDOCS_SBIN PRDOCS_SUDOERS PRDOCS_UNITDIR PRDOCS_BASE PRDOCS_OUT PRDOCS_PORT
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
PD="$DASH_DIR/prepper_docs.py"
FH="$DASH_DIR/funk_health.py"
HW="$DASH_DIR/mesh_hang_watchdog.py"
DOCS="$DASH_DIR/docs"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
CF="$DASH_DIR/sdr_config.json"
CH="$DASH_DIR/static/vendor/chart-4.4.1.min.js"
SL="$DASH_DIR/tools/schreiblast.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/relhygiene-apply
KEEP_LAST=3
KNOWN_D16="eb3ac3f73280bd47"      # dashboard.py vor relHygiene (Basis)
KNOWN_D16N="cdd62e7136267498"             # dashboard.py nach relHygiene (Ziel)
KNOWN_PD16="2d23d96499583ce2"     # prepper_docs.py vor relHygiene
KNOWN_PD16N="609f0a7f00ab586b"           # prepper_docs.py nach relHygiene
KNOWN_FH16="f89deb0cb9a6ff21"     # funk_health.py vor relHygiene
KNOWN_FH16N="f1b16a5f9bc7317c"           # funk_health.py nach relHygiene
KNOWN_HW16="1afa8becde24bc89"     # mesh_hang_watchdog.py vor relHygiene
KNOWN_HW16N="1518dbd9931c5e96"           # mesh_hang_watchdog.py nach relHygiene
KNOWN_SDR16="8b887c795e64b87f"    # prepper_sdr.py (bleibt)
KNOWN_SM16="6dd122356d8f3ae1"     # sdr_manager.py (bleibt)
KNOWN_DB16="431077d36822a090"     # database.py (bleibt)
KNOWN_MR16="c5ffda3907b0dd51"     # mesh_router.py (bleibt)
KNOWN_LG16="3788481354f47656"     # lagegeo.py (bleibt)
KNOWN_CF16="9de9b81fae2b8a8e"     # sdr_config.json (nur Hinweis; aendert sich im Betrieb)
CH_SHA="74401d738dd3e03ee5dfb3b6841210fe2c4ead8a960c4011ca4ba0b78a9fd8f3"
CH_SIZE=205125
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
echo "=== relHygiene apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Protokolle ruhiger und begrenzt (REL-04), Chart.js lokal mit ruhigem Fallback (REL-09), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu/tools" "$W/neu/static/vendor" "$W/dsbx" "$W/alt" "$W/pg"
EXPECT_PRH="bc37ec67240ce51cbab67eb3087794f9d3e703fe0d9c2b64b608b471f08efe21"
cat > "$W/patch-rh.py" << 'RH_PRH_EOF'
"""Patcher relHygiene. Aufruf: patch-rh.py NAME ART QUELLE ZIEL BLOCK|- EDITS   (ART = dsh | fh | hw | pd). Idempotent: schon gepatcht -> Ziel = Quelle.
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
RH_PRH_EOF
EXPECT_RED="fd46e1188ea742fcee1de905d18f625b62cc05d97280b2ccf640c4bcf4e2ebf5"
cat > "$W/edits_all.py" << 'RH_RED_EOF'
# relHygiene: Stellen (alt, neu). Jede alte Stelle genau einmal. Nur Skript-Adresse von Chart.js (gleiche Stelle, gleiche Reihenfolge) bzw. Protokoll-Rotation.
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
_C4 = '<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>'
_C0 = '<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>'
_L = '<script src="/static/vendor/chart-4.4.1.min.js"></script>'
DSH_EDITS = [
    ("<title>Lage</title>\n" + _C4, "<title>Lage</title>\n" + _L),
    ("<title>Energie</title>\n" + _C4, "<title>Energie</title>\n" + _L),
    ("<title>Lokale Energie</title>\n" + _C4, "<title>Lokale Energie</title>\n" + _L),
    ("<title>Käswasser · Luft</title>\n" + _C4, "<title>Käswasser · Luft</title>\n" + _L),
    ("</div>\n\n" + _C0 + "\n<script>\n(function(){\n  const labels = {{ adsb.hist_t", "</div>\n\n" + _L + "\n<script>\n(function(){\n  const labels = {{ adsb.hist_t"),
    ("</style>\n" + _C0 + '\n</head><body>\n""" + NAV_UNIFY', "</style>\n" + _L + '\n</head><body>\n""" + NAV_UNIFY'),
    ("s.src='https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js';", "s.src='/static/vendor/chart-4.4.1.min.js';"),
]
FH_ANCHOR = None
FH_EDITS = [
    ('<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>\n<script>\nfunction mk(', '<script src="/static/vendor/chart-4.4.1.min.js"></script>\n<script>\nfunction mk('),
]
HW_ANCHOR = None
HW_EDITS = [
    ('''def log(msg: str) -> None:
    line = f"{now_str()} {msg}"
    print(line, flush=True)
    try:
        with LOG_FILE.open("a", encoding="utf-8") as f:''',
     '''LOG_MAX_BYTES = 1024 * 1024  # relHygiene (REL-04): Protokoll hoechstens 1 MB je Datei, dazu 3 Vorgaenger (.1 bis .3)
LOG_KEEP = 3


def _rotate_log() -> None:
    """relHygiene: Datei groesser als LOG_MAX_BYTES -> .2 nach .3, .1 nach .2, Datei nach .1 (os.replace, atomar). Jeder Fehler wird verschluckt: das Protokoll darf den Lauf nie stoeren."""
    try:
        if LOG_FILE.stat().st_size <= LOG_MAX_BYTES:
            return
        for i in range(LOG_KEEP, 1, -1):
            older = LOG_FILE.with_name(LOG_FILE.name + "." + str(i - 1))
            if older.exists():
                os.replace(older, LOG_FILE.with_name(LOG_FILE.name + "." + str(i)))
        os.replace(LOG_FILE, LOG_FILE.with_name(LOG_FILE.name + ".1"))
    except Exception:
        pass


def log(msg: str) -> None:
    line = f"{now_str()} {msg}"
    print(line, flush=True)
    _rotate_log()
    try:
        with LOG_FILE.open("a", encoding="utf-8") as f:'''),
]
RH_RED_EOF
EXPECT_RED2="2833620b8d4d9a4d41638ceda4c04f1b8f0e3b267984541086c1ee082ca5ee12"
cat > "$W/edits_docs.py" << 'RH_RED2_EOF'
# relHygiene: Dokumentations-Aenderungen an prepper_docs.py (woertlich, jede alte Stelle genau einmal; erzeugt von mk/gen_edits_docs.py)
PD_ANCHOR = None
PD_EDITS = [
    ('| tools/backup.sh | Backup-Skript fuer die Sicherung (Kachel "Sicherung") |',
     '| tools/backup.sh, tools/restore.sh | Sicherung und Wiederherstellung (Kachel "Sicherung"; Patches relBackup commit18 und relBackup2 commit18b): Archive ohne venv, __pycache__, *.zim, *.bak-* und backups/ (rund 142 MB statt 170-180 MB), Datenbank konsistent per sqlite3-Backup, Rechte 600 (Ordner 700); die Wiederherstellung verschiebt venv, *.zim, *.bak-* und backups/ beim Verzeichnistausch per mv in den neuen Ordner statt per Hardlink zu kopieren |\n| tools/schreiblast.py | Schreiblast-Messung (Patch relHygiene, commit19): nur lesend und nur auf Aufruf; zeigt Prozesse, wachsende Dateien, Protokolldateien, Journal-Menge je Dienst und das Schreiben auf den Datentraeger |\n| static/vendor/chart-4.4.1.min.js | Chart.js 4.4.1 (MIT-Lizenz, unveraendert aus dem npm-Paket), wird vom Dashboard lokal ausgeliefert (Patch relHygiene, commit19) |'),
    ('| mesh_hang_watchdog.py (+ Units mesh-hang-watchdog.service/.timer) | Hang-Erkennung der Mesh-Verbindungen, Status mesh_hang_status.json, optionaler Neustart per Freigabe-Datei |',
     '| mesh_hang_watchdog.py (+ Units mesh-hang-watchdog.service/.timer) | Hang-Erkennung der Mesh-Verbindungen, Status mesh_hang_status.json, optionaler Neustart per Freigabe-Datei; schreibt mesh_hang_watchdog.log mit Obergrenze (1 MB, 3 Vorgaenger; relHygiene) |'),
    ('- "SICHERUNG" (#backupBox): Sicherung der Projektdateien/DB (tools/backup.sh), Liste der 5 neuesten, Knopf "Sicherung jetzt" und Wiederherstellung (doPrepperRestore). Muss unveraendert bleiben; die Kachel steht vor der Projektbeschreibung.',
     '- "SICHERUNG" (#backupBox): Sicherung der Projektdateien/DB (tools/backup.sh), Liste der 5 neuesten, Knopf "Sicherung jetzt" und Wiederherstellung (doPrepperRestore). Muss unveraendert bleiben; die Kachel steht vor der Projektbeschreibung. Seit relBackup/relBackup2 sind die Archive kleiner (rund 142 MB, ohne venv, __pycache__, *.zim, *.bak-*, backups/); Knopf und Ablauf der Kachel sind unveraendert, Details im Kapitel Betrieb (Sicherung und Wiederherstellung).'),
    ('| /api/docs/list, /api/docs/download, /api/docs/routes | GET | Projektbeschreibung (Patch projDoc): Versionsliste, Download (fmt=txt|md, v=JJJJMMTT-HHMM), Routenliste fuer den Generator; nur Lesen aus docs/ |',
     '| /api/docs/list, /api/docs/download, /api/docs/routes | GET | Projektbeschreibung (Patch projDoc): Versionsliste, Download (fmt=txt|md, v=JJJJMMTT-HHMM), Routenliste fuer den Generator; nur Lesen aus docs/ |\n| /static/vendor/chart-4.4.1.min.js | GET | Chart.js 4.4.1 lokal (Patch relHygiene): feste Adresse, Cache-Header ein Jahr (immutable, ETag), vor dem Ausliefern auf Groesse und sha256 geprueft; fehlt die Datei oder stimmt die Pruefsumme nicht, liefert die Adresse einen kleinen Ersatz ohne Cache, der die Seiten ohne JavaScript-Fehler weiterlaufen laesst ("Diagramm nicht verfuegbar") |'),
    ('\n## Patch-Schichten (Marker',
     '\n- Danach: relBackup (commit18, erste Fassung wurde vom Trockenlauf zurueckgerollt), relBackup2 (commit18b: Wiederherstellung per mv statt Hardlink; nur tools/restore.sh) und relHygiene (commit19: Log-Politik und lokale Chart.js; Audit REL-04 und REL-09). Nur relHygiene setzt eine Schicht mit Marker in dashboard.py.\n\n## Patch-Schichten (Marker'),
    ('| sdrStick3e | Stick 3 als zweiter Hobby-Stick mit eigenem Planer (APRS fest, RDS versetzt, 10C im Wechsel, Rueckfall, Lastschutz), voll auf /funk |',
     '| sdrStick3e | Stick 3 als zweiter Hobby-Stick mit eigenem Planer (APRS fest, RDS versetzt, 10C im Wechsel, Rueckfall, Lastschutz), voll auf /funk |\n| relHygiene | Log-Politik und lokale Chart.js (commit19): Zugriffsprotokoll des Werkzeug-Servers ohne 2xx/3xx (4xx hoechstens 60 je Minute, 5xx immer), Chart.js 4.4.1 lokal unter /static/vendor/chart-4.4.1.min.js mit ruhigem Fallback statt JavaScript-Fehler, alle CDN-Adressen ersetzt; mesh_hang_watchdog.log rotiert (1 MB, 3 Vorgaenger); Schreiblast-Messung tools/schreiblast.py |'),
    ('    "tools/": "backup.sh, restore.sh, prepper-clone-ssd-to-sd, ookla/",',
     '    "tools/": "backup.sh, restore.sh, schreiblast.py, prepper-clone-ssd-to-sd, ookla/",'),
    ('    "static/": "statische Dateien (Leaflet-Karte, Bilder)",',
     '    "static/": "statische Dateien (Leaflet-Karte, Bilder, vendor/chart-4.4.1.min.js)",'),
    ('    "mesh_hang_watchdog.py": "Hang-Erkennung der Mesh-Verbindungen, optionaler Neustart",',
     '    "mesh_hang_watchdog.py": "Hang-Erkennung der Mesh-Verbindungen, optionaler Neustart, Protokoll mit Obergrenze (1 MB, 3 Vorgaenger)",'),
    ('| /pi: SSD/SD, Sicherung, Archiv | dashboard.py, tools/backup.sh, archive_store.py | diskTiles2, sysBoot, sdHealth, sdAck, piPolish, piPolish2, longArchive | @@FI archive_store.py;tools/backup.sh@@ |',
     '| /pi: SSD/SD, Sicherung, Archiv | dashboard.py, tools/backup.sh, tools/restore.sh, archive_store.py | diskTiles2, sysBoot, sdHealth, sdAck, piPolish, piPolish2, longArchive (Sicherung: relBackup, relBackup2) | @@FI archive_store.py;tools/backup.sh;tools/restore.sh@@ |'),
    ('| Projektbeschreibung (diese Datei) | prepper_docs.py, dashboard.py | projDoc, meshPost | @@FI prepper_docs.py;dashboard.py@@ |',
     '| Projektbeschreibung (diese Datei) | prepper_docs.py, dashboard.py | projDoc, meshPost | @@FI prepper_docs.py;dashboard.py@@ |\n| Logs, Schreiblast, lokale Chart.js | dashboard.py, mesh_hang_watchdog.py, funk_health.py, tools/schreiblast.py | relHygiene | @@FI mesh_hang_watchdog.py;funk_health.py;tools/schreiblast.py@@ |'),
    ('- Unterordner: tools/ (backup.sh, restore.sh, prepper-clone-ssd-to-sd, ookla/), systemd/sysboot/ (Dateien des Patches sysBoot; Inhalt nicht naeher dokumentiert), static/ (Leaflet u. a.), sdr_lib/, docs/ (diese Projektbeschreibung, Dateien "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt/.md").',
     '- Unterordner: tools/ (backup.sh, restore.sh, schreiblast.py, prepper-clone-ssd-to-sd, ookla/), systemd/sysboot/ (Dateien des Patches sysBoot; Inhalt nicht naeher dokumentiert), static/ (Leaflet, vendor/chart-4.4.1.min.js u. a.), sdr_lib/, docs/ (diese Projektbeschreibung, Dateien "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt/.md").'),
    ('- Alle Zustandsdateien atomar; Datenbank im WAL-Modus; jede Funktion mit try/except.',
     '- Alle Zustandsdateien atomar; Datenbank im WAL-Modus; jede Funktion mit try/except.\n- Oberflaeche ohne Internet-Zwang: Bibliotheken liegen lokal in static/ (Leaflet, seit relHygiene auch Chart.js 4.4.1 mit fester Version und Pruefsumme); keine Skripte von fremden Servern.\n- Protokolle: erfolgreiche Zugriffe werden nicht protokolliert, Fehler schon; jede vom Projekt geschriebene Logdatei hat eine Obergrenze (Zeilen oder Groesse). Die Journal-Obergrenze (200 MB) stammt aus sysBoot und bleibt.'),
    ('- 10. Pushe auf das private Repo nur auf den Branch kaeswasser-lage-monitor und nur mit Freigabe; Commit-Nachricht mit Patch-Name, prepper-patches-Commit und sha16.',
     '- 10. Pushe auf das private Repo nur auf den Branch kaeswasser-lage-monitor und nur mit Freigabe; Commit-Nachricht mit Patch-Name, prepper-patches-Commit und sha16.\n- 11. Keine externen Skript- oder Stil-Adressen (CDN) einbinden: Chart.js nur ueber /static/vendor/chart-4.4.1.min.js; neue Dateien, die laufend schreiben, brauchen eine Obergrenze (Groesse oder Zeilen) und duerfen das Zugriffsprotokoll nicht umgehen.'),
    ('cd /home/fmg/prepper-dashboard && python3 prepper_docs.py --check\n```',
     'cd /home/fmg/prepper-dashboard && python3 prepper_docs.py --check\npython3 /home/fmg/prepper-dashboard/tools/schreiblast.py 20\ncurl -sI http://127.0.0.1:5000/static/vendor/chart-4.4.1.min.js\n```'),
    ('- Rauchtest (smoke.sh im Projektordner) ruft die Seiten/APIs ab, sendet nichts.',
     '- Rauchtest (smoke.sh im Projektordner) ruft die Seiten/APIs ab, sendet nichts.\n- Journal zu laut oder Platte beschaeftigt: python3 /home/fmg/prepper-dashboard/tools/schreiblast.py 20 (nur lesend; mit sudo-Ticket PRSL_SUDO=1 vorangestellt zeigt es auch die Journal-Zeilen je Dienst). Das Zugriffsprotokoll enthaelt seit relHygiene nur noch Fehler (4xx/5xx).'),
    ('- Bei Boot-Problemen: SD-Fallback (geklont auf Knopfdruck) nutzen; Boot-Reihenfolge im Kachel "SSD · Master" ansehen.',
     '- Bei Boot-Problemen: SD-Fallback (geklont auf Knopfdruck) nutzen; Boot-Reihenfolge im Kachel "SSD · Master" ansehen.\n\n### Sicherung und Wiederherstellung (relBackup commit18, relBackup2 commit18b)\n\n- tools/backup.sh legt je Sicherung ein tgz in /home/fmg/prepper-backups an (Rechte 600, Ordner 700) mit Pruefsumme in der JSON-Begleitdatei. Ausgeschlossen sind venv, __pycache__, backups, *.zim, *.bak-* und die laufende Datenbank samt -wal/-shm; die Datenbank kommt als konsistente Kopie per sqlite3-Backup (quick_check) ins Archiv. Ergebnis: rund 142 MB statt 170-180 MB. tar-Meldung "Datei beim Packen geaendert" (Exit 1) ist eine Warnung, Exit 2 oder hoeher ein Fehler.\n- tools/restore.sh --dry-run prueft nur lesend: Archiv-Pruefsumme, Eintraege, Code mit System- und venv-Python uebersetzbar, Datenbank quick_check, Wege zum Abkoppeln/Stoppen/Neustarten, Geraet und Schreibrecht fuer den Tausch. Die echte Wiederherstellung (Aufruf aus dem Dashboard-Knopf unveraendert: restore.sh ID) koppelt sich vom Dashboard ab, sichert den Ist-Zustand, stoppt den Dienst, tauscht den Projektordner per mv, startet neu, prueft die Gesundheit und faellt sonst zurueck.\n- venv, *.zim, *.bak-* und backups/ gehoeren nicht ins Archiv: sie werden beim Verzeichnistausch per mv (Umbenennen im selben Dateisystem) in den neuen Ordner verschoben und bei einem Rueckfall zurueckgeschoben. Die erste Fassung (commit18) kopierte sie per Hardlink; das scheiterte, weil in der venv root-eigene Dateien liegen (Rest ~ip eines abgebrochenen sudo-pip-Upgrades) und fs.protected_hardlinks=1 Hardlinks auf fremde Dateien verbietet. Beim mv spielen Eigentuemer und Rechte im Inneren der venv keine Rolle. Die root-eigenen Reste koennen bei Gelegenheit per sudo entfernt werden (Pruefen mit: find /home/fmg/prepper-dashboard/venv ! -user fmg | head); das geschieht nicht automatisch.\n- Der Dashboard-Knopf "Sicherung jetzt" und "Wiederherstellen" ist unveraendert; Sicherungen duerfen nicht groesser oder riskanter werden als die bisherigen.\n\n### Logs und Schreiblast (relHygiene commit19, Audit REL-04)\n\n- Wo geschrieben wird: die Dienste (prepper-dashboard, prepper-sdr, mesh-bridge, mesh-bridge-bayern) schreiben per print/stderr ins systemd-Journal (persistent, hoechstens 200 MB per Drop-in zz-prepper-persist.conf aus sysBoot; weitere Journal-Einstellungen sind nicht noetig). Eigene Dateien im Projektordner: mesh_hang_watchdog.log (neu mit Obergrenze), health_check.log (hoechstens 500 Zeilen) und watchdog.log (hoechstens 400 Zeilen), rtl433.jsonl (8 MB) und aprs.jsonl (4 MB) mit je einer Vorgaengerdatei (.1), JSON-Zustaende atomar ueberschrieben, clone.log nur beim manuellen Klonen.\n- Zugriffsprotokoll: der Werkzeug-Server schrieb je Seiten- und API-Aufruf eine Zeile ins Journal (bei mehreren offenen Seiten und dem TFT sehr viele; im Ernstfall verdraengt das Rauschen die wichtigen Meldungen). Seit relHygiene filtert das Dashboard diese Zeilen: erfolgreiche Anfragen (2xx/3xx) entfallen, Fehler bleiben (5xx immer, 4xx hoechstens 60 je Minute, mit Zaehler der unterdrueckten Zeilen). Alle anderen Meldungen (Print-Ausgaben der Schichten, Warnungen, Tracebacks, Start) laufen unveraendert; Alarm-, Sende- und Abruflogik sind nicht beteiligt. Zeilen, die nicht wie eine Zugriffszeile aussehen, werden nie verworfen.\n- mesh_hang_watchdog.log: der Watchdog (Timer alle 10 min) rotiert das Protokoll beim Schreiben selbst: ueber 1 MB wird die Datei zu .1, .1 zu .2, .2 zu .3 (das aelteste faellt weg). Dafuer ist kein logrotate und kein root noetig; die Meldungen stehen zusaetzlich im Journal.\n- Schreiblast messen (nur lesend, nur auf Aufruf, nichts laeuft dauerhaft): python3 /home/fmg/prepper-dashboard/tools/schreiblast.py [Sekunden]. Es zeigt das Schreiben auf den Datentraeger im Messfenster, die Prozesse mit den meisten Schreibzugriffen (/proc/PID/io, nur eigene), wachsende Dateien, Protokolldateien mit Hinweis ab 5 MB, den Journal-Plattenbedarf und die Journal-Zeilen je Dienst der letzten 10 Minuten (mit sudo-Ticket und PRSL_SUDO=1 vorangestellt). Die Tagesbilanz der SSD/SD zeigt zusaetzlich die Kachel auf /pi.\n- Nicht geaendert: Alarmverhalten, Journal-Einstellungen, systemd-Einheiten, logrotate.\n\n### Diagramme: Chart.js lokal (relHygiene commit19, Audit REL-09)\n\n- Alle Seiten mit Diagrammen (/, /energie, /lokale-energie, /adsb, /pegel, /luft, /funk und die Speedtest-Kachel auf /pi) laden Chart.js 4.4.1 (MIT-Lizenz, Datei dist/chart.umd.js aus dem npm-Paket, 205125 Bytes, sha16 74401d738dd3e03e; die volle sha256 steht im Code des Dashboards, Schicht relHygiene) vom Dashboard selbst: Adresse /static/vendor/chart-4.4.1.min.js, Datei static/vendor/chart-4.4.1.min.js im Projektordner. Es gibt keinen Abruf von cdn.jsdelivr.net mehr. Die Seiten /adsb und /pegel und die Funk-Seite luden bisher ohne Versionsangabe die jeweils neueste Fassung; jetzt gilt ueberall die feste Version 4.4.1.\n- Das Dashboard prueft die Datei (Groesse, sha256) und liefert sie mit Cache-Header (ein Jahr, immutable, ETag) aus. Fehlt sie oder stimmt die Pruefsumme nicht, liefert dieselbe Adresse einen kleinen Ersatz (no-store): die Seiten laufen ohne JavaScript-Fehler weiter und zeigen statt des Diagramms "Diagramm nicht verfuegbar (Chart.js lokal nicht gefunden)"; im Journal steht dann die Zeile "relHygiene: lokale Chart.js fehlt/ungueltig".\n- Die Skript-Zeilen stehen an derselben Stelle der Seiten wie vorher (Ladereihenfolge unveraendert). Die Datei liegt in static/ und ist damit Teil der Sicherung. Neue Seiten mit Diagrammen binden dieselbe Adresse ein.'),
    ('- Die juengste Patch-Familie rund um SDR (23./24.10.2026): sdrAir (Geraete-Register, feste Rollen), sdrAir2 (Anzeigenamen, Hobby nur Beobachtung; Branch-Commit 02:00), dabSql (Datenbankschicht fuer DAB/TII; 08:30), airTest (Gain-Test; 09:35), sdrHalt (Planer-Waechter; 10:10), sdrRest (Koordinaten-Herkunft, Uhr-Schutz; 12:06), sdrRest2 (USB-Stand nur lesend, 10C "nicht geprueft"; 13:21), sdrStick3 (Stick 3 im Register; 15:00), sdrFall (Rueckfall-10C-Meldung nur vom 5C-Planer; 17:21 am 24.10.2026), autoGain (Gain-Automatik und Kachelbreite auf /funk; commit16), sdrStick3e (Stick 3 als zweiter Hobby-Stick mit eigenem Planer; commit17).',
     '- Die juengste Patch-Familie rund um SDR (23./24.10.2026): sdrAir (Geraete-Register, feste Rollen), sdrAir2 (Anzeigenamen, Hobby nur Beobachtung; Branch-Commit 02:00), dabSql (Datenbankschicht fuer DAB/TII; 08:30), airTest (Gain-Test; 09:35), sdrHalt (Planer-Waechter; 10:10), sdrRest (Koordinaten-Herkunft, Uhr-Schutz; 12:06), sdrRest2 (USB-Stand nur lesend, 10C "nicht geprueft"; 13:21), sdrStick3 (Stick 3 im Register; 15:00), sdrFall (Rueckfall-10C-Meldung nur vom 5C-Planer; 17:21 am 24.10.2026), autoGain (Gain-Automatik und Kachelbreite auf /funk; commit16), sdrStick3e (Stick 3 als zweiter Hobby-Stick mit eigenem Planer; commit17). Danach Sicherung und Betrieb: relBackup (commit18), relBackup2 (commit18b, Wiederherstellung per mv) und relHygiene (commit19, Log-Politik und lokale Chart.js).'),
    ('- Basisstand dieser Beschreibung = Stand nach sdrFall, projDoc, meshPost, autoGain und sdrStick3e. Die genauen sha16 und Zeilenzahlen aller Dateien stehen im Abschnitt "Dateien im Projektordner" (Kapitel 4) und in der Tabelle in Kapitel 12.',
     '- Basisstand dieser Beschreibung = Stand nach sdrFall, projDoc, meshPost, autoGain, sdrStick3e, relBackup2 und relHygiene. Die genauen sha16 und Zeilenzahlen aller Dateien stehen im Abschnitt "Dateien im Projektordner" (Kapitel 4) und in der Tabelle in Kapitel 12.'),
    ('- Stick 3 als zweiter Hobby-Stick (sdrStick3e, commit17): echter Planer (Register-Rolle hobby2, Planer-Platz 4, welle-cli-Ports 7985/1241) neben Stick 2. Beobachten: Zeile "Stick 3 · Hobby" und "Last Stick 3" in der Funk-Lage, Watchdog-Zeile, Journalzeilen "sdrStick3e:". Offen: Wirkung der Aufteilung ueber mehrere Tage (Messdichte RDS, 10C im Wechsel), CPU-Verlauf von Stick 3 neben welle-cli am Airspy.',
     '- Stick 3 als zweiter Hobby-Stick (sdrStick3e, commit17): echter Planer (Register-Rolle hobby2, Planer-Platz 4, welle-cli-Ports 7985/1241) neben Stick 2. Beobachten: Zeile "Stick 3 · Hobby" und "Last Stick 3" in der Funk-Lage, Watchdog-Zeile, Journalzeilen "sdrStick3e:". Offen: Wirkung der Aufteilung ueber mehrere Tage (Messdichte RDS, 10C im Wechsel), CPU-Verlauf von Stick 3 neben welle-cli am Airspy.\n- Log-Politik und lokale Chart.js (relHygiene, commit19): beobachten, ob das Journal des Dashboards ruhiger wird (python3 tools/schreiblast.py 20, Zeilen je Dienst) und ob alle Diagramm-Seiten ohne Internet Diagramme zeigen (Pi vom Netz trennen und /energie, /luft, /pegel, /adsb, /funk ansehen). Offen aus dem Audit: Pruefung der restlichen Logdateien auf dem Pi ueber mehrere Tage (Wachstum der Protokolldateien).'),
]
RH_RED2_EOF
EXPECT_RDH="52e8a981b234383aeef32c0be2687d44f854343935a610d28086a5b5336ba061"
cat > "$W/blk_dash.py" << 'RH_RDH_EOF'
# ===== relHygiene: Zugriffsprotokoll auf Fehler begrenzt (Journal ruhiger), Chart.js lokal unter /static/vendor/chart-4.4.1.min.js mit ruhigem Fallback (REL-04, REL-09); nur Protokoll/Anzeige, keine Alarm-, Sende- oder Abruflogik =====
import hashlib as _rh_hashlib
import logging as _rh_logging
import os as _rh_os
import re as _rh_re
import threading as _rh_th
import time as _rh_time
from flask import Response as _rh_Response, request as _rh_request

_RH_CHART_URL = "/static/vendor/chart-4.4.1.min.js"
_RH_CHART_FILE = "chart-4.4.1.min.js"
_RH_CHART_SHA = "74401d738dd3e03ee5dfb3b6841210fe2c4ead8a960c4011ca4ba0b78a9fd8f3"   # chart.js 4.4.1 dist/chart.umd.js aus dem npm-Paket (MIT); gleiche Version wie die bisherigen CDN-Aufrufe
_RH_CHART_SIZE = 205125
_RH_CHART_BASE = _rh_os.path.dirname(_rh_os.path.abspath(__file__))
# Ersatz, wenn die lokale Datei fehlt oder nicht stimmt: Chart-Aufrufe der Seiten laufen ohne JavaScript-Fehler weiter und zeigen statt des Diagramms einen ruhigen Hinweis
_RH_CHART_FALLBACK = r"""/* relHygiene: Chart.js lokal nicht verfuegbar - ruhiger Ersatz, die Seite laeuft ohne JavaScript-Fehler weiter */
(function(){
if(window.Chart&&!window.Chart.__rhStub){return;}
function note(cv){try{var p=cv&&cv.parentNode;if(!p||p.getAttribute('data-rh-note')){return;}p.setAttribute('data-rh-note','1');
var d=document.createElement('div');d.className='small';d.setAttribute('data-rh-note-text','1');d.style.cssText='color:#94a3b8;font-size:0.8rem;padding:8px 0';
d.textContent='Diagramm nicht verf\u00fcgbar (Chart.js lokal nicht gefunden).';cv.style.display='none';p.appendChild(d);}catch(e){}}
function C(ctx,cfg){this.config=cfg||{};this.data=(cfg&&cfg.data)||{labels:[],datasets:[]};this.options=(cfg&&cfg.options)||{};this.canvas=(ctx&&ctx.canvas)||null;note(this.canvas);}
C.prototype.update=C.prototype.destroy=C.prototype.resize=C.prototype.render=C.prototype.stop=C.prototype.reset=C.prototype.clear=function(){return this;};
C.__rhStub=true;C.version='fehlt';C.register=function(){};C.defaults={};C.getChart=function(){return null;};
window.Chart=C;
})();
"""
_RH_CH = {"sig": None, "data": None, "why": "nicht geprueft", "lock": _rh_th.Lock(), "warn": 0.0}


def _rh_chart_path():
    return _rh_os.path.join(_RH_CHART_BASE, "static", "vendor", _RH_CHART_FILE)


def _rh_chart_load(path=None):
    """Liest die lokale Chart.js-Datei, prueft Groesse und sha256; Rueckgabe (Bytes oder None, Grund). Ergebnis wird je Datei-Signatur gemerkt (kein Lesen je Anfrage)."""
    p = path or _rh_chart_path()
    try:
        st = _rh_os.stat(p)
        sig = (p, st.st_mtime_ns, st.st_size)
    except OSError:
        sig = (p, None, None)
    with _RH_CH["lock"]:
        if _RH_CH["sig"] == sig:
            return _RH_CH["data"], _RH_CH["why"]
        data, why = None, "Datei fehlt"
        if sig[1] is not None:
            try:
                with open(p, "rb") as f:
                    raw = f.read(_RH_CHART_SIZE + 1024)
                if len(raw) != _RH_CHART_SIZE:
                    why = "Groesse %d statt %d" % (len(raw), _RH_CHART_SIZE)
                elif _rh_hashlib.sha256(raw).hexdigest() != _RH_CHART_SHA:
                    why = "Pruefsumme stimmt nicht"
                else:
                    data, why = raw, "ok"
            except OSError as e:
                why = "nicht lesbar (%s)" % e.__class__.__name__
        _RH_CH.update(sig=sig, data=data, why=why)
        return data, why


def _rh_chart_view():
    data, why = _rh_chart_load()
    if data is None:
        now = _rh_time.monotonic()
        if now - _RH_CH["warn"] > 600:
            _RH_CH["warn"] = now
            print("relHygiene: lokale Chart.js fehlt/ungueltig (%s) - Seiten zeigen den ruhigen Hinweis statt der Diagramme: %s" % (why, _rh_chart_path()), flush=True)
        r = _rh_Response(_RH_CHART_FALLBACK, mimetype="application/javascript")
        r.headers["Cache-Control"] = "no-store"
        r.headers["X-Content-Type-Options"] = "nosniff"
        r.headers["X-RH-Chart"] = "fehlt"
        return r
    etag = '"%s"' % _RH_CHART_SHA[:32]
    if _rh_request.headers.get("If-None-Match") == etag:
        r = _rh_Response(status=304)
    else:
        r = _rh_Response(data, mimetype="application/javascript")
    r.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    r.headers["ETag"] = etag
    r.headers["X-Content-Type-Options"] = "nosniff"
    r.headers["X-RH-Chart"] = "4.4.1"
    return r


# Zugriffsprotokoll des Werkzeug-Servers (eine Zeile je Anfrage ins Journal): erfolgreiche Anfragen (2xx/3xx) entfallen, Fehler (5xx immer, 4xx hoechstens 60 je Minute) bleiben.
# Andere Meldungen (Warnungen, Fehler, Starttext) und alles, was nicht wie eine Zugriffszeile aussieht, laufen unveraendert durch.
_RH_ACC_RE = _rh_re.compile(r'"[A-Z]+ [^"]* HTTP/[0-9.]+" ([0-9]{3}) ')
_RH_ANSI_RE = _rh_re.compile(r"\x1b\[[0-9;]*m")        # Farbcodes (nur bei Terminalausgabe)


class _RhAccessFilter(_rh_logging.Filter):
    def __init__(self, per_min=60, clock=None):
        _rh_logging.Filter.__init__(self)
        self.per_min = per_min
        self.clock = clock or _rh_time.monotonic
        self.lock = _rh_th.Lock()
        self.t0 = None
        self.n = 0
        self.sup = 0
        self.stat = {"verworfen": 0, "behalten": 0, "gedrosselt": 0}

    def filter(self, record):
        try:
            m = _RH_ACC_RE.search(_RH_ANSI_RE.sub("", record.getMessage()))
            if not m:
                return True
            code = int(m.group(1))
            with self.lock:
                if code < 400:
                    self.stat["verworfen"] += 1
                    return False
                if code >= 500:
                    self.stat["behalten"] += 1
                    return True
                now = self.clock()
                sup = 0
                if self.t0 is None or now - self.t0 >= 60:
                    sup, self.t0, self.n, self.sup = self.sup, now, 0, 0
                if self.n >= self.per_min:
                    self.sup += 1
                    self.stat["gedrosselt"] += 1
                    return False
                self.n += 1
                self.stat["behalten"] += 1
            if sup:
                record.msg = record.getMessage().rstrip("\n") + "  [relHygiene: %d weitere 4xx-Zeilen der letzten Minute unterdrueckt]" % sup
                record.args = ()
            return True
        except Exception:
            return True


def _selftest_relhygiene():
    import logging
    t = [0.0]
    flt = _RhAccessFilter(per_min=3, clock=lambda: t[0])

    def rec(msg, *a):
        return logging.LogRecord("werkzeug", logging.INFO, "x", 1, msg, a, None)
    ok = lambda code, p="/x": flt.filter(rec('127.0.0.1 - - [25/Oct/2026 08:00:00] "GET %s HTTP/1.1" %s -', p, code))
    assert ok(200) is False and ok(302) is False and ok(304) is False and ok(200, "/api/sdr/ui") is False, "2xx/3xx muessen entfallen"
    assert ok(500) is True and ok(503) is True and ok(404) is True, "Fehler muessen bleiben"
    assert flt.filter(rec("Traceback (most recent call last): 200 OK")) is True and flt.filter(rec(" * Running on all addresses")) is True
    assert flt.filter(rec('x - - [t] "BAD" 200 -')) is True, "Zeile ohne Anfrage-Muster muss durchlaufen"
    assert flt.filter(rec('127.0.0.1 - - [t] \x1b[1m"GET / HTTP/1.1"\x1b[0m \x1b[32m200\x1b[0m -')) is False, "Zugriffszeile mit Farbcodes (200) muss entfallen"
    assert flt.filter(rec('127.0.0.1 - - [t] \x1b[1m"GET / HTTP/1.1"\x1b[0m \x1b[31m500\x1b[0m -')) is True, "Zugriffszeile mit Farbcodes (500) muss bleiben"
    assert ok(404) is True and ok(404) is True and ok(404) is False and ok(404) is False and ok(500) is True, "4xx: hoechstens per_min je Minute, 5xx nie gedrosselt"
    t[0] = 61.0
    r = rec('127.0.0.1 - - [t] "GET /y HTTP/1.1" 404 -')
    assert flt.filter(r) is True and "2 weitere 4xx-Zeilen" in r.getMessage(), "unterdrueckte Zeilen muessen gezaehlt werden"
    assert "window.Chart" in _RH_CHART_FALLBACK and "</script" not in _RH_CHART_FALLBACK
    data, why = _rh_chart_load()
    if data is not None:
        chart = "Chart.js 4.4.1 lokal ok (%d Bytes, sha256 %s...)" % (len(data), _RH_CHART_SHA[:12])
    else:
        chart = "Chart.js lokal NICHT verfuegbar (%s) - Seiten zeigen den ruhigen Hinweis statt der Diagramme" % why
    return "relHygiene ok (Zugriffsprotokoll: 2xx/3xx entfallen, 4xx hoechstens 60/min, 5xx immer; %s)" % chart


try:
    _rh_wl = _rh_logging.getLogger("werkzeug")
    if not any(getattr(f, "_rh_access", False) for f in _rh_wl.filters):
        _rh_af = _RhAccessFilter()
        _rh_af._rh_access = True
        _rh_wl.addFilter(_rh_af)
    if "rh_chart_js" not in app.view_functions:
        app.add_url_rule(_RH_CHART_URL, endpoint="rh_chart_js", view_func=_rh_chart_view, methods=["GET"])
    print("relHygiene aktiv: %s" % _selftest_relhygiene(), flush=True)
except Exception as _rh_e:
    print("relHygiene FEHLER (Verhalten wie bisher):", _rh_e, flush=True)
RH_RDH_EOF
EXPECT_RGD="910d47f8baebbbb9e5b5091dc515dcc944ee869aacc4d81ff81664212d09f562"
cat > "$W/guard_relhygiene.py" << 'RH_RGD_EOF'
#!/usr/bin/env python3
"""AST-Guard relHygiene (nur lesen/Sandbox). Aufruf:
  guard_relhygiene.py revert NEWDIR OUTDIR EDITS_ALL EDITS_DOCS BLK     Rueckbau: Block weg, Stellen zurueck -> OUTDIR/{dashboard,funk_health,mesh_hang_watchdog,prepper_docs}.py (Aufrufer prueft sha16 gegen die Basis)
  guard_relhygiene.py check ALTDIR NEWDIR BLK EDITS_ALL                 statische Regeln + Verhalten (Flask-Sandbox, nichts gesendet, kein Netz ausser 127.0.0.1 mit freiem Port)
  guard_relhygiene.py mutate NEWDIR BLK EDITS_ALL                       Mutationstest: jede Verfehlung muss von check erkannt werden
NEWDIR enthaelt dashboard.py, funk_health.py, mesh_hang_watchdog.py, tools/schreiblast.py, static/vendor/chart-4.4.1.min.js (+ ggf. weitere Dateien)."""
import ast
import hashlib
import io
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading

CHART_SHA = "74401d738dd3e03ee5dfb3b6841210fe2c4ead8a960c4011ca4ba0b78a9fd8f3"
CHART_URL = "/static/vendor/chart-4.4.1.min.js"
CHART_FILE = "chart-4.4.1.min.js"
ANCH = '\n\nif __name__ == "__main__":\n'
rd = lambda p: open(p, encoding="utf-8").read()


def edits(path):
    g = {}
    exec(compile(rd(path), path, "exec"), g)
    return g


def revert(newdir, out, eall, edocs, blk):
    A, D = edits(eall), edits(edocs)
    B = rd(blk).rstrip("\n") + "\n"
    os.makedirs(out, exist_ok=True)
    for name, E, blkx in (("dashboard.py", A["DSH_EDITS"], B), ("funk_health.py", A["FH_EDITS"], None), ("mesh_hang_watchdog.py", A["HW_EDITS"], None), ("prepper_docs.py", D["PD_EDITS"], None)):
        s = rd(os.path.join(newdir, name))
        if blkx:
            assert s.count(blkx) == 1 and s.count(blkx.splitlines()[0]) == 1, "%s: Block relHygiene nicht genau einmal" % name
            s = s.replace("\n\n" + blkx.rstrip("\n"), "", 1)
            assert blkx.splitlines()[0] not in s, "%s: Block nicht sauber entfernbar" % name
        for o, n in E:
            assert s.count(n) == 1, "%s: neue Stelle nicht genau einmal: %s" % (name, n[:60])
            s = s.replace(n, o, 1)
        open(os.path.join(out, name), "w", encoding="utf-8").write(s)
    print("Rueckbau ok: Block weg, %d+%d+%d+%d Stellen zurueck" % (len(A["DSH_EDITS"]), len(A["FH_EDITS"]), len(A["HW_EDITS"]), len(D["PD_EDITS"])))


def norm_tree(src, drop_from=None):
    """ast.dump mit allen Chart.js-Adressen als gleicher Platzhalter; optional ohne die Block-Knoten (ab Zeilennummer)."""
    t = ast.parse(src)
    if drop_from is not None:
        t.body = [n for n in t.body if not (getattr(n, "lineno", 0) >= drop_from[0] and getattr(n, "end_lineno", 0) <= drop_from[1])]
    for n in ast.walk(t):
        if isinstance(n, ast.Constant) and isinstance(n.value, str):
            v = n.value
            for u in ("https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js", "https://cdn.jsdelivr.net/npm/chart.js", CHART_URL):
                v = v.replace(u, "@@CHART@@")
            n.value = v
    return ast.dump(t)


def static_checks(alt, new, blk, eall):
    n = 0
    A = edits(eall)
    nd, od = rd(os.path.join(new, "dashboard.py")), rd(os.path.join(alt, "dashboard.py"))
    B = rd(blk).rstrip("\n") + "\n"
    # S1: Gesamt-Datei = Basis + 7 Stellen + Block (Zeilen vor dem Anker gleich viele, Block steht vor dem Hauptteil)
    assert nd.count(B.rstrip("\n")) == 1 and nd.count(ANCH) == 1, "Block/Anker nicht genau einmal"
    i = nd.index(B.rstrip("\n"))
    assert nd[i + len(B.rstrip("\n")):].startswith(ANCH), "Block steht nicht unmittelbar vor dem Hauptteil"
    assert nd[:i].rstrip("\n").count("\n") == od[:od.index(ANCH)].rstrip("\n").count("\n"), "Zeilenzahl vor dem Block weicht ab (Seiten-Ladereihenfolge verschoben?)"
    n += 1
    # S2: AST ohne Block == AST der Basis (Chart-Adressen normalisiert)
    bl0 = nd[:i].count("\n") + 1
    bl1 = bl0 + B.rstrip("\n").count("\n")
    assert norm_tree(nd, (bl0, bl1)) == norm_tree(od), "AST ausserhalb des Blocks weicht von der Basis ab"
    n += 1
    # S3: keine externe Chart.js-/CDN-Adresse mehr; lokale Adresse an 7 Stellen (6 Seiten-Tags + 1 dynamischer Lader)
    for fn in ("dashboard.py", "funk_health.py"):
        s = rd(os.path.join(new, fn))
        for bad in ("jsdelivr", "unpkg", "cdnjs", "chart.js@", "npm/chart", "cdn."):
            assert bad not in s, "%s enthaelt noch '%s'" % (fn, bad)
    assert rd(os.path.join(new, "dashboard.py")).count(CHART_URL) >= 7 + 1, "lokale Adresse in dashboard.py zu selten"
    assert nd.count('<script src="%s"></script>' % CHART_URL) == 6 and nd.count("s.src='%s';" % CHART_URL) == 1
    fh = rd(os.path.join(new, "funk_health.py"))
    assert fh.count('<script src="%s"></script>' % CHART_URL) == 1
    n += 1
    # S4: Block-AST: nur erlaubte Importe, keine Netz-/Prozess-/Schreib-/exec-Aufrufe, keine fremden Adressen, keine Alarm-/Sendebegriffe
    t = ast.parse(B)
    allowed = {"hashlib", "logging", "os", "re", "threading", "time", "flask"}
    for x in ast.walk(t):
        if isinstance(x, ast.Import):
            for a in x.names:
                assert a.name.split(".")[0] in allowed, "Import %s im Block nicht erlaubt" % a.name
        if isinstance(x, ast.ImportFrom):
            assert (x.module or "").split(".")[0] in allowed, "Import aus %s im Block nicht erlaubt" % x.module
        if isinstance(x, ast.Call):
            f = x.func
            nm = (f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
            assert nm not in ("system", "popen", "Popen", "run", "call", "check_output", "urlopen", "connect", "send", "sendall", "remove", "unlink", "rename", "write", "writelines", "mkdir", "makedirs", "rmtree", "chmod"), "Aufruf %s im Block nicht erlaubt" % nm
            assert not (isinstance(f, ast.Name) and nm in ("exec", "eval", "compile", "__import__")), "Aufruf %s im Block nicht erlaubt" % nm
            assert not (isinstance(f, ast.Attribute) and nm == "replace" and getattr(f.value, "id", "") == "_rh_os"), "os.replace im Block nicht erlaubt"
            if nm == "open":
                assert len(x.args) == 2 and isinstance(x.args[1], ast.Constant) and x.args[1].value == "rb", "open im Block nur lesend ('rb')"
        if isinstance(x, ast.Constant) and isinstance(x.value, str):
            assert "http://" not in x.value and "https://" not in x.value, "externe Adresse im Block: %s" % x.value[:40]
        if isinstance(x, (ast.Name, ast.Attribute)):
            idn = (x.id if isinstance(x, ast.Name) else x.attr).lower()
            for w in ("mesh", "telegram", "send", "alarm", "subprocess", "socket", "requests", "urllib", "gain", "sdr_"):
                assert w not in idn, "Bezeichner %s im Block (Alarm/Sende/Netz-Bezug)" % idn
    rules = [x for x in ast.walk(t) if isinstance(x, ast.Call) and getattr(x.func, "attr", "") == "add_url_rule"]
    assert len(rules) == 1 and any(k.arg == "methods" and ast.literal_eval(k.value) == ["GET"] for k in rules[0].keywords), "genau eine GET-Route erwartet"
    n += 1
    # S5: Block-Marker + Selbsttest
    assert B.startswith("# ===== relHygiene:") and "_selftest_relhygiene" in B
    n += 1
    # S6: mesh_hang_watchdog.py: AST ausser log/_rotate_log/Konstanten gleich; funk_health.py: AST gleich (Adresse normalisiert)
    nw, ow = rd(os.path.join(new, "mesh_hang_watchdog.py")), rd(os.path.join(alt, "mesh_hang_watchdog.py"))
    tn, to = ast.parse(nw), ast.parse(ow)
    skip = {"log", "_rotate_log"}

    def keep(nodes):
        out = []
        for z in nodes:
            if isinstance(z, ast.FunctionDef) and z.name in skip:
                continue
            if isinstance(z, ast.Assign) and any(getattr(q, "id", "") in ("LOG_MAX_BYTES", "LOG_KEEP") for q in z.targets):
                continue
            out.append(ast.dump(z))
        return out
    assert keep(tn.body) == keep(to.body), "mesh_hang_watchdog.py: AST ausser log/_rotate_log/Konstanten weicht ab"
    n += 1
    assert norm_tree(rd(os.path.join(new, "funk_health.py"))) == norm_tree(rd(os.path.join(alt, "funk_health.py"))), "funk_health.py: AST weicht ab"
    n += 1
    # S7: tools/schreiblast.py: keine Schreibzugriffe, nur journalctl als Fremdprogramm
    sp = os.path.join(new, "tools", "schreiblast.py")
    ts = ast.parse(rd(sp))
    for x in ast.walk(ts):
        if isinstance(x, ast.Call):
            f = x.func
            nm = (f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
            assert nm not in ("system", "popen", "Popen", "remove", "unlink", "rename", "write", "writelines", "mkdir", "makedirs", "rmtree", "chmod", "chown", "kill", "exec", "eval", "urlopen", "connect", "send", "sendall"), "schreiblast.py: Aufruf %s nicht erlaubt" % nm
            assert not (isinstance(f, ast.Attribute) and nm == "replace" and getattr(f.value, "id", "") in ("os", "shutil")), "schreiblast.py: os.replace nicht erlaubt"
            if nm == "open":
                a1 = x.args[1] if len(x.args) > 1 else None
                assert a1 is None or (isinstance(a1, ast.Constant) and a1.value in ("r", "rb")), "schreiblast.py: open nur lesend"
            if nm == "run":
                lst = x.args[0]
                assert isinstance(lst, ast.BinOp), "schreiblast.py: subprocess.run Argumente unerwartet"
    src = rd(sp)
    assert src.count("subprocess.run(") == 1 and '["journalctl", "--no-pager", "-q"]' in src and '["sudo", "-n"]' in src, "schreiblast.py: nur journalctl (optional mit sudo -n) erlaubt"
    assert "http://" not in src and "https://" not in src
    n += 1
    # S8: Chart.js-Datei ist die geprueft feste Datei
    cd = open(os.path.join(new, "static", "vendor", CHART_FILE), "rb").read()
    assert hashlib.sha256(cd).hexdigest() == CHART_SHA and len(cd) == 205125 and b"Chart.js v4.4.1" in cd[:200], "static/vendor/chart-4.4.1.min.js falsch"
    assert max(cd) < 128, "Chart.js-Datei nicht reines ASCII"
    n += 1
    return n


def load_block(newdir, blk, base_for_file):
    """Fuehrt den Block in einer eigenen Flask-App aus; __file__ liegt in base_for_file (dort static/vendor)."""
    from flask import Flask
    app = Flask("rhtest", static_folder=os.path.join(base_for_file, "static"))
    g = {"app": app, "__file__": os.path.join(base_for_file, "dashboard.py"), "__name__": "rhtest"}
    wl0 = logging.getLogger("werkzeug")
    for f0 in list(wl0.filters):
        if getattr(f0, "_rh_access", False):
            wl0.removeFilter(f0)
    buf = io.StringIO()
    old = sys.stdout
    sys.stdout = buf
    try:
        exec(compile(rd(blk), "blk", "exec"), g)
    finally:
        sys.stdout = old
    return app, g, buf.getvalue()


def behav(newdir, blk):
    n = 0
    tmp = tempfile.mkdtemp(prefix="rh-guard-")
    try:
        vend = os.path.join(tmp, "static", "vendor")
        os.makedirs(vend)
        os.makedirs(os.path.join(tmp, "static", "leaflet"))
        open(os.path.join(tmp, "static", "leaflet", "x.txt"), "w").write("leaflet-ok")
        good = open(os.path.join(newdir, "static", "vendor", CHART_FILE), "rb").read()
        fp = os.path.join(vend, CHART_FILE)
        tick = [1700000000 * 10 ** 9]
        app, g, out = load_block(newdir, blk, tmp)       # Datei fehlt beim Laden
        assert "relHygiene aktiv: relHygiene ok" in out and "NICHT verfuegbar" in out, "Selbsttest/Meldung bei fehlender Datei: %s" % out[:200]
        n += 1
        c = app.test_client()
        r = c.get(CHART_URL)
        assert r.status_code == 200 and "javascript" in r.headers["Content-Type"] and "no-store" in r.headers["Cache-Control"] and r.headers.get("X-RH-Chart") == "fehlt", "Fallback-Antwort bei fehlender Datei"
        stub = r.data
        assert b"window.Chart=C" in stub and b"note(this.canvas)" in stub and b"</script" not in stub, "Fallback-Inhalt"
        assert "no-store" in r.headers["Cache-Control"] and "ETag" not in r.headers
        n += 1
        open(fp, "wb").write(good)                       # Datei erscheint -> neue Signatur -> echte Datei
        r = c.get(CHART_URL)
        assert r.status_code == 200 and hashlib.sha256(r.data).hexdigest() == CHART_SHA, "echte Datei wird nicht ausgeliefert"
        h = r.headers
        assert h["Cache-Control"] == "public, max-age=31536000, immutable" and h["ETag"] == '"%s"' % CHART_SHA[:32] and h["X-Content-Type-Options"] == "nosniff", "Header der echten Datei: %s" % dict(h)
        assert h["Content-Type"].startswith("application/javascript") and h.get("X-RH-Chart") == "4.4.1", "Content-Type/Kennung"
        n += 1
        r2 = c.get(CHART_URL, headers={"If-None-Match": h["ETag"]})
        assert r2.status_code == 304 and r2.data == b"" and "immutable" in r2.headers["Cache-Control"], "ETag/304"
        assert c.get(CHART_URL, headers={"If-None-Match": '"falsch"'}).status_code == 200
        assert c.head(CHART_URL).status_code == 200 and c.post(CHART_URL).status_code == 405
        n += 1
        assert c.get("/static/leaflet/x.txt").data == b"leaflet-ok", "andere statische Dateien muessen weiter gehen"
        n += 1
        for name, mod in (("ein Byte geaendert", lambda b: b[:100] + bytes([b[100] ^ 1]) + b[101:]), ("abgeschnitten", lambda b: b[:-5]), ("leer", lambda b: b""), ("verlaengert", lambda b: b + b"\n")):
            open(fp, "wb").write(mod(good))
            tick[0] += 10 ** 9
            os.utime(fp, ns=(tick[0], tick[0]))
            r = c.get(CHART_URL)
            assert r.headers.get("X-RH-Chart") == "fehlt" and b"window.Chart=C" in r.data and "no-store" in r.headers["Cache-Control"], "veraenderte Datei (%s) wird nicht abgefangen" % name
            if name in ("abgeschnitten", "verlaengert", "leer"):
                assert g["_RH_CH"]["why"].startswith("Groesse"), "Groessenpruefung (%s): %s" % (name, g["_RH_CH"]["why"])
            else:
                assert g["_RH_CH"]["why"].startswith("Pruefsumme"), "Pruefsummenpruefung: %s" % g["_RH_CH"]["why"]
        os.remove(fp)
        os.mkdir(fp)                                      # Verzeichnis statt Datei
        assert c.get(CHART_URL).headers.get("X-RH-Chart") == "fehlt"
        os.rmdir(fp)
        open(fp, "wb").write(good)
        assert hashlib.sha256(c.get(CHART_URL).data).hexdigest() == CHART_SHA
        n += 1
        # Zugriffsprotokoll end-to-end: echter Werkzeug-Server auf freiem Port, Mitschnitt des Loggers
        from werkzeug.serving import make_server
        app, g, _o = load_block(newdir, blk, tmp)        # frische App (Routen vor der ersten Anfrage)

        @app.route("/ok")
        def _ok():
            return "ok"

        @app.route("/boom")
        def _boom():
            raise RuntimeError("absichtlich")
        app.config["PROPAGATE_EXCEPTIONS"] = False
        app.logger.disabled = True
        stream = io.StringIO()
        h = logging.StreamHandler(stream)
        wl = logging.getLogger("werkzeug")
        wl.addHandler(h)
        wl.setLevel(logging.INFO)
        srv = make_server("127.0.0.1", 0, app, threaded=True)
        th = threading.Thread(target=srv.serve_forever, daemon=True)
        th.start()
        import urllib.request
        import urllib.error
        port = srv.server_port
        for p in ("/ok", "/ok", CHART_URL, "/nope", "/boom", "/static/leaflet/x.txt"):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, p), timeout=10).read()
            except urllib.error.HTTPError:
                pass
        srv.shutdown()
        th.join(5)
        wl.removeHandler(h)
        txt = re.sub(r"\x1b\[[0-9;]*m", "", stream.getvalue())
        assert '" 200 ' not in txt and '" 304 ' not in txt, "2xx-Zugriffszeilen stehen noch im Protokoll: %s" % txt[:200]
        assert '"GET /nope HTTP/1.1" 404' in txt and '"GET /boom HTTP/1.1" 500' in txt, "Fehlerzeilen fehlen: %s" % txt[:300]
        assert "relHygiene" not in txt
        n += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # Filter direkt: Drosselung 4xx, 5xx nie, Fehlerfall -> durchlassen
    app2, g2, _ = load_block(newdir, blk, tempfile.mkdtemp(prefix="rh-guard-"))
    F = g2["_RhAccessFilter"]
    t = [0.0]
    f = F(clock=lambda: t[0])                          # Standardwert (60/min) wird geprueft
    mk = lambda code: logging.LogRecord("werkzeug", logging.INFO, "x", 1, '127.0.0.1 - - [t] "GET /a HTTP/1.1" %s -', (code,), None)
    kept4 = sum(1 for _ in range(100) if f.filter(mk(404)))
    kept5 = sum(1 for _ in range(100) if f.filter(mk(500)))
    assert kept4 == 60 and kept5 == 100, "Drosselung 4xx=60/min bzw. 5xx nie: %d/%d" % (kept4, kept5)
    t[0] = 120.0
    r = mk(404)
    assert f.filter(r) is True and "40 weitere 4xx-Zeilen" in r.getMessage()
    bad = logging.LogRecord("werkzeug", logging.INFO, "x", 1, "%d %d", ("a",), None)      # getMessage() wirft
    assert f.filter(bad) is True, "Fehler im Filter muss durchlassen"
    assert f.filter(logging.LogRecord("werkzeug", logging.WARNING, "x", 1, "Warnung: 200 Verbindungen", (), None)) is True
    n += 1
    # Fallback-JS im echten JavaScript (node): kein Fehler, Hinweis genau einmal, update/destroy gehen
    js = g2["_RH_CHART_FALLBACK"]
    js_static(js)                                      # immer, auch ohne node (auf der Pi gibt es kein node)
    n += 1
    nodeb = None if os.environ.get("RH_NO_NODE") == "1" else shutil.which("node")
    if nodeb:
        harness = """
var made=[];function el(t){var e={tag:t,children:[],style:{},attrs:{},setAttribute:function(k,v){this.attrs[k]=v;},getAttribute:function(k){return this.attrs[k]||null;},appendChild:function(c){this.children.push(c);return c;}};return e;}
global.window={};global.document={createElement:el};
var parent=el('div');var cv=el('canvas');cv.parentNode=parent;
%s
var c=new window.Chart({canvas:cv},{type:'line',data:{labels:[1],datasets:[{data:[1]}]},options:{}});
c.data.datasets[0].data=[2];c.update();c.update('none');c.resize();c.destroy();
new window.Chart({canvas:cv},{});new window.Chart(null,{});new window.Chart();
if(parent.children.length!==1||!/Diagramm nicht verf/.test(parent.children[0].textContent)||cv.style.display!=='none')throw new Error('Hinweis falsch '+parent.children.length);
window.Chart.register({});if(window.Chart.getChart(cv)!==null)throw new Error('getChart');
var R=function(){};window.Chart=R;eval(%s);if(window.Chart!==R)throw new Error('echtes Chart ueberschrieben');
console.log('node ok');
""" % (js, repr(js))
        r = subprocess.run([nodeb, "-e", harness], capture_output=True, timeout=60)
        assert r.returncode == 0 and b"node ok" in r.stdout, "Fallback-JS im node: %s" % (r.stdout + r.stderr)[:300]
        n += 1
    else:
        print("   Hinweis: node nicht vorhanden - Ersatz-JS wurde statisch (Struktur) geprueft, nicht ausgefuehrt")
    # Rotation im Hang-Watchdog
    n += behav_hw(newdir)
    n += behav_sl(newdir)
    return n


def js_static(js):
    """Struktur des Ersatz-JS ohne JavaScript-Maschine pruefen (umgebungsunabhaengig, gleiches Ergebnis mit und ohne node)."""
    lines = js.split("\n")
    assert js.count("(function(){") == 1 and js.rstrip().endswith("})();"), "Ersatz-JS: genau eine selbststartende Funktion"
    i = js.index("(function(){\n") + len("(function(){\n")
    assert js[i:].startswith("if(window.Chart&&!window.Chart.__rhStub){return;}\n"), "Ersatz-JS: echtes Chart.js darf nie ueberschrieben werden (erste Anweisung)"
    assert js.count("window.Chart=C;") == 1 and js.rstrip().endswith("window.Chart=C;\n})();"), "Ersatz-JS: window.Chart=C als letzte Anweisung"
    m = re.search(r"\n((?:C\.prototype\.\w+=)+)function\(\)\{return this;\};\n", js)
    assert m, "Ersatz-JS: Methoden-Kette (update/destroy/...) fehlt"
    names = set(re.findall(r"C\.prototype\.(\w+)=", m.group(1)))
    need = {"update", "destroy", "resize", "render", "stop", "reset", "clear"}
    assert names == need, "Ersatz-JS: Methoden %s statt %s" % (sorted(names), sorted(need))
    assert "C.__rhStub=true;" in js and "C.register=function(){};" in js and "C.defaults={};" in js and "C.getChart=function(){return null;};" in js, "Ersatz-JS: statische Mitglieder (__rhStub/register/defaults/getChart)"
    cm = re.search(r"function C\(ctx,cfg\)\{(.*?)\}\n", js)
    assert cm and "this.config=cfg||{};" in cm.group(1) and "this.data=" in cm.group(1) and "this.options=" in cm.group(1) and "this.canvas=(ctx&&ctx.canvas)||null;note(this.canvas);" in cm.group(1), "Ersatz-JS: Konstruktor (config/data/options/canvas, Hinweis)"
    nm = re.search(r"function note\(cv\)\{try\{(.*?)\}catch\(e\)\{\}\}\n", js, re.S)
    assert nm, "Ersatz-JS: note() muss in try/catch liegen"
    nb = nm.group(1)
    for k in ("data-rh-note", "Diagramm nicht verf", "cv.style.display='none';", "p.appendChild(d);", "document.createElement('div')"):
        assert k in nb, "Ersatz-JS: note() ohne " + k
    assert nb.count("if(!p||p.getAttribute('data-rh-note')){return;}p.setAttribute('data-rh-note','1');") == 1, "Ersatz-JS: Hinweis genau einmal je Elternelement"
    assert js.count("function C(") == 1 and js.count("function note(") == 1 and "eval(" not in js and "XMLHttpRequest" not in js and "fetch(" not in js and "import(" not in js and "http" not in js.replace("/* relHygiene", ""), "Ersatz-JS: keine weiteren Funktionen, keine Netzzugriffe"


def behav_hw(newdir):
    import importlib.util
    d = tempfile.mkdtemp(prefix="rh-hw-")
    try:
        spec = importlib.util.spec_from_file_location("rh_hw_mod", os.path.join(newdir, "mesh_hang_watchdog.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        from pathlib import Path
        assert m.LOG_MAX_BYTES == 1024 * 1024 and m.LOG_KEEP == 3, "Vorgabe: 1 MB je Datei, 3 Vorgaenger"
        m.LOG_FILE = Path(d) / "mesh_hang_watchdog.log"
        out = sys.stdout
        sys.stdout = io.StringIO()
        try:
            m.log("erste Zeile")
            assert m.LOG_FILE.read_text().strip().endswith("erste Zeile") and not (Path(d) / "mesh_hang_watchdog.log.1").exists()
            for gen in range(1, 6):                        # fuenfmal ueber die Grenze: .1 .2 .3, nie .4
                m.LOG_FILE.write_bytes(("G%d " % gen).encode() + b"x" * (m.LOG_MAX_BYTES + 10))
                m.log("nach Rotation %d" % gen)
                assert m.LOG_FILE.stat().st_size < 200, "Datei nach Rotation nicht klein"
            fs = sorted(x.name for x in Path(d).iterdir())
            assert fs == ["mesh_hang_watchdog.log", "mesh_hang_watchdog.log.1", "mesh_hang_watchdog.log.2", "mesh_hang_watchdog.log.3"], fs
            assert (Path(d) / "mesh_hang_watchdog.log.1").read_bytes().startswith(b"G5 ") and (Path(d) / "mesh_hang_watchdog.log.2").read_bytes().startswith(b"G4 ") and (Path(d) / "mesh_hang_watchdog.log.3").read_bytes().startswith(b"G3 "), "Reihenfolge der Vorgaenger"
            m.LOG_FILE.write_bytes(b"y" * m.LOG_MAX_BYTES)                 # genau an der Grenze: keine Rotation
            m.log("grenze")
            assert not (Path(d) / "mesh_hang_watchdog.log.4").exists() and m.LOG_FILE.stat().st_size > m.LOG_MAX_BYTES - 1
            real = os.replace
            m.os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("simuliert"))   # Rotation scheitert: Log darf den Lauf nie stoeren
            try:
                m.LOG_FILE.write_bytes(b"z" * (m.LOG_MAX_BYTES + 5))
                m.log("trotz Fehler")
            finally:
                m.os.replace = real
            assert m.LOG_FILE.read_bytes().endswith(b"trotz Fehler\n")
            m.LOG_FILE = Path(d) / "nicht" / "da" / "x.log"                 # Ordner fehlt: kein Fehler
            m.log("ohne Ordner")
        finally:
            sys.stdout = out
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return 1


def behav_sl(newdir):
    d = tempfile.mkdtemp(prefix="rh-sl-")
    try:
        open(os.path.join(d, "a.log"), "w").write("x" * 10)
        open(os.path.join(d, "big.log"), "wb").write(b"x" * (6 * 1024 * 1024))
        open(os.path.join(d, "z.json"), "w").write("{}")
        before = sorted((x, os.path.getsize(os.path.join(d, x)), os.path.getmtime(os.path.join(d, x))) for x in os.listdir(d))
        env = dict(os.environ, PRSL_DIR=d)
        r = subprocess.run([sys.executable, os.path.join(newdir, "tools", "schreiblast.py"), "1"], capture_output=True, timeout=120, env=env)
        o = r.stdout.decode()
        assert r.returncode == 0 and "=== Schreiblast (nur lesend" in o and "Prozesse mit den meisten Schreibzugriffen" in o and "Protokoll-Dateien" in o and "Journal:" in o, "schreiblast.py Ausgabe: %s %s" % (o[:200], r.stderr[:200])
        assert "big.log" in o and "gross, Rotation pruefen" in o and "a.log" in o, "Protokoll-Hinweis ab 5 MB"
        after = sorted((x, os.path.getsize(os.path.join(d, x)), os.path.getmtime(os.path.join(d, x))) for x in os.listdir(d))
        assert before == after, "schreiblast.py hat Dateien veraendert"
        r = subprocess.run([sys.executable, os.path.join(newdir, "tools", "schreiblast.py"), "0"], capture_output=True, timeout=30, env=env)
        assert r.returncode == 2 and b"Aufruf" in r.stdout
        r = subprocess.run([sys.executable, os.path.join(newdir, "tools", "schreiblast.py"), "abc"], capture_output=True, timeout=30, env=env)
        assert r.returncode == 2
        env2 = dict(env, PRSL_DIR=os.path.join(d, "gibtsnicht"))
        r = subprocess.run([sys.executable, os.path.join(newdir, "tools", "schreiblast.py"), "1"], capture_output=True, timeout=120, env=env2)
        assert r.returncode == 0, "fehlender Ordner darf nicht abstuerzen: %s" % r.stderr[:200]
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return 1


def check(alt, new, blk, eall):
    n = static_checks(alt, new, blk, eall)
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()):
        n += behav(new, blk)
    print("OK guard relHygiene: %d Pruefungen, 0 fehlerhaft" % n)
    return n


MUT = [
    # (Name, Datei im NEWDIR oder 'BLK', alt, neu)
    ("M01 2xx nicht mehr verworfen", "BLK", "if code < 400:", "if code < 0:"),
    ("M02 5xx gedrosselt", "BLK", "if code >= 500:", "if code >= 5000:"),
    ("M03 4xx ungedrosselt", "BLK", "def __init__(self, per_min=60, clock=None):", "def __init__(self, per_min=60000, clock=None):"),
    ("M04 Filter wirft bei Fehler weg", "BLK", "        except Exception:\n            return True\n\n\ndef _selftest", "        except Exception:\n            return False\n\n\ndef _selftest"),
    ("M05 Nicht-Zugriffszeilen verworfen", "BLK", "            if not m:\n                return True", "            if not m:\n                return False"),
    ("M06 Farbcodes nicht entfernt", "BLK", '_RH_ACC_RE.search(_RH_ANSI_RE.sub("", record.getMessage()))', "_RH_ACC_RE.search(record.getMessage())"),
    ("M07 Filter nicht eingehaengt", "BLK", "        _rh_wl.addFilter(_rh_af)", "        pass"),
    ("M08 Pruefsumme nicht geprueft", "BLK", "elif _rh_hashlib.sha256(raw).hexdigest() != _RH_CHART_SHA:", "elif False:"),
    ("M09 Groesse nicht geprueft", "BLK", "if len(raw) != _RH_CHART_SIZE:", "if False:"),
    ("M10 falsche Soll-Groesse", "BLK", "_RH_CHART_SIZE = 205125", "_RH_CHART_SIZE = 205126"),
    ("M11 falsche Soll-Pruefsumme", "BLK", '_RH_CHART_SHA = "74401d73', '_RH_CHART_SHA = "74401d72'),
    ("M12 Cache ohne immutable", "BLK", "public, max-age=31536000, immutable", "public, max-age=31536000"),
    ("M13 Fallback mit Cache", "BLK", 'r.headers["Cache-Control"] = "no-store"', 'r.headers["Cache-Control"] = "public, max-age=3600"'),
    ("M14 kein nosniff", "BLK", '    r.headers["X-Content-Type-Options"] = "nosniff"\n    r.headers["X-RH-Chart"] = "4.4.1"', '    r.headers["X-RH-Chart"] = "4.4.1"'),
    ("M15 ETag/304 fehlt", "BLK", 'if _rh_request.headers.get("If-None-Match") == etag:', "if False:"),
    ("M16 Route auch per POST", "BLK", 'methods=["GET"]', 'methods=["GET", "POST"]'),
    ("M17 falscher Dateipfad", "BLK", '"static", "vendor", _RH_CHART_FILE', '"static", "vendors", _RH_CHART_FILE'),
    ("M18 falscher Content-Type", "BLK", '_rh_Response(data, mimetype="application/javascript")', '_rh_Response(data, mimetype="text/plain")'),
    ("M19 Fallback liefert Daten statt Ersatz", "BLK", "    if data is None:\n        now =", "    if data is not None:\n        now ="),
    ("M20 Ersatz ohne window.Chart", "BLK", "window.Chart=C;\n})();", "\n})();"),
    ("M21 Ersatz ohne Hinweis", "BLK", "this.canvas=(ctx&&ctx.canvas)||null;note(this.canvas);}", "this.canvas=(ctx&&ctx.canvas)||null;}"),
    ("M22 Ersatz ohne update", "BLK", "C.prototype.update=C.prototype.destroy=", "C.prototype.destroy="),
    ("M23 Ersatz ueberschreibt echtes Chart", "BLK", "if(window.Chart&&!window.Chart.__rhStub){return;}", ""),
    ("M24 externe Adresse im Block", "BLK", '_RH_CHART_URL = "/static/vendor/chart-4.4.1.min.js"', '_RH_CHART_URL = "/static/vendor/chart-4.4.1.min.js"\n_RH_X = "https://cdn.jsdelivr.net/npm/chart.js"'),
    ("M25 subprocess im Block", "BLK", "import hashlib as _rh_hashlib", "import hashlib as _rh_hashlib\nimport subprocess as _rh_sp"),
    ("M26 Schreibzugriff im Block", "BLK", 'with open(p, "rb") as f:', 'with open(p, "wb") as f:'),
    ("M27 Seite behaelt CDN-Adresse", "dashboard.py", '<title>Energie</title>\n<script src="/static/vendor/chart-4.4.1.min.js"></script>', '<title>Energie</title>\n<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>'),
    ("M28 dynamischer Lader mit CDN", "dashboard.py", "s.src='/static/vendor/chart-4.4.1.min.js';", "s.src='https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js';"),
    ("M29 Funk-Seite behaelt CDN", "funk_health.py", '<script src="/static/vendor/chart-4.4.1.min.js"></script>', '<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>'),
    ("M30 Ladereihenfolge: Tag hinter <style>", "dashboard.py", '<title>Lage</title>\n<script src="/static/vendor/chart-4.4.1.min.js"></script>\n<style>', '<title>Lage</title>\n<style>\n<script src="/static/vendor/chart-4.4.1.min.js"></script>'),
    ("M31 Seite ohne lokales Skript", "dashboard.py", '<title>Lokale Energie</title>\n<script src="/static/vendor/chart-4.4.1.min.js"></script>\n', "<title>Lokale Energie</title>\n"),
    ("M32 stille Zusatzaenderung in dashboard.py", "dashboard.py", "use_reloader=False, threaded=True)  # sysBoot", "use_reloader=True, threaded=True)  # sysBoot"),
    ("M33 Rotation: nie rotiert", "mesh_hang_watchdog.py", "if LOG_FILE.stat().st_size <= LOG_MAX_BYTES:\n            return", "if True:\n            return"),
    ("M34 Rotation: immer rotiert", "mesh_hang_watchdog.py", "if LOG_FILE.stat().st_size <= LOG_MAX_BYTES:\n            return", "if False:\n            return"),
    ("M35 Rotation: Vorgaenger nicht verschoben", "mesh_hang_watchdog.py", "os.replace(older, LOG_FILE.with_name(LOG_FILE.name + \".\" + str(i)))", "pass"),
    ("M36 Rotation: zu viele Vorgaenger", "mesh_hang_watchdog.py", "LOG_KEEP = 3", "LOG_KEEP = 4"),
    ("M37 Rotation: Fehler nicht verschluckt", "mesh_hang_watchdog.py", "        os.replace(LOG_FILE, LOG_FILE.with_name(LOG_FILE.name + \".1\"))\n    except Exception:\n        pass", "        os.replace(LOG_FILE, LOG_FILE.with_name(LOG_FILE.name + \".1\"))\n    except FileNotFoundError:\n        pass"),
    ("M38 Rotation: Grenze 100 MB", "mesh_hang_watchdog.py", "LOG_MAX_BYTES = 1024 * 1024", "LOG_MAX_BYTES = 100 * 1024 * 1024"),
    ("M39 Rotation vor dem Print statt vor Anhaengen weg", "mesh_hang_watchdog.py", "    print(line, flush=True)\n    _rotate_log()\n", "    print(line, flush=True)\n"),
    ("M40 schreiblast schreibt", "tools/schreiblast.py", 'with open(p, "r", encoding="utf-8", errors="replace") as f:', 'with open(p, "w", encoding="utf-8", errors="replace") as f:'),
    ("M41 schreiblast startet systemctl", "tools/schreiblast.py", '["journalctl", "--no-pager", "-q"]', '["systemctl", "--no-pager", "-q"]'),
    ("M42 schreiblast ohne Grenzhinweis", "tools/schreiblast.py", "<- gross, Rotation pruefen", "<- ok"),
    ("M43 Chart.js-Datei veraendert", "static/vendor/chart-4.4.1.min.js", "Chart.js v4.4.1", "Chart.js v4.4.2"),
    ("M44 Ersatz ohne resize", "BLK", "C.prototype.resize=", ""),
    ("M45 Ersatz getChart liefert Objekt", "BLK", "C.getChart=function(){return null;};", "C.getChart=function(){return {};};"),
    ("M46 Ersatz ohne register", "BLK", "C.register=function(){};", ""),
    ("M47 Ersatz: Hinweis mehrfach", "BLK", "if(!p||p.getAttribute('data-rh-note')){return;}", "if(!p){return;}"),
    ("M48 Ersatz: note ohne try", "BLK", "function note(cv){try{var p=", "function note(cv){{var p="),
    ("M49 Ersatz blendet Canvas nicht aus", "BLK", "cv.style.display='none';", ""),
    ("M50 Ersatz mit Netzzugriff", "BLK", "window.Chart=C;\n})();", "fetch('/x');window.Chart=C;\n})();"),
    ("M51 Ersatz ohne options", "BLK", "this.options=(cfg&&cfg.options)||{};", ""),
]


def mutate(newdir, blk, eall):
    bad = []
    done = 0
    for name, tgt, a, b in MUT:
        w = tempfile.mkdtemp(prefix="rh-mut-")
        try:
            nd = os.path.join(w, "new")
            shutil.copytree(newdir, nd)
            bk = os.path.join(w, "blk.py")
            shutil.copy(blk, bk)
            alt = os.path.join(w, "alt")
            # alte Dateien aus dem Rueckbau der unveraenderten neuen Dateien
            path = bk if tgt == "BLK" else os.path.join(nd, tgt)
            s = open(path, encoding="utf-8").read()
            assert s.count(a) == 1, "%s: Stelle nicht eindeutig (%d)" % (name, s.count(a))
            s = s.replace(a, b, 1)
            open(path, "w", encoding="utf-8").write(s)
            if tgt == "BLK":
                # der Block steckt auch in dashboard.py: dort denselben Mutanten setzen (der Block wird auch dort geprueft)
                dd = os.path.join(nd, "dashboard.py")
                ds = open(dd, encoding="utf-8").read()
                B0 = rd(blk).rstrip("\n")
                assert ds.count(B0) == 1
                ds = ds.replace(B0, s.rstrip("\n"), 1)
                open(dd, "w", encoding="utf-8").write(ds)
            os.makedirs(alt)
            for fn in ("dashboard.py", "funk_health.py", "mesh_hang_watchdog.py"):
                shutil.copy(os.path.join(ALT_DIR, fn), os.path.join(alt, fn))
            try:
                check(alt, nd, bk, eall)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except (AssertionError, SyntaxError, Exception) as e:
                print("erkannt %s: %s" % (name, str(e).replace("\n", " ")[:90]))
            done += 1
        finally:
            shutil.rmtree(w, ignore_errors=True)
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation relHygiene: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
    return 0


ALT_DIR = None

if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a[0] == "revert":
            revert(*a[1:6])
        elif a[0] == "check":
            check(*a[1:5])
        elif a[0] == "mutate":
            ALT_DIR = os.environ["RH_ALT"]
            sys.exit(mutate(*a[1:4]))
        else:
            print(__doc__)
            sys.exit(2)
    except AssertionError as e:
        print("guard relHygiene FEHLER: %s" % e)
        sys.exit(1)
RH_RGD_EOF
EXPECT_RHC="94ac840dd1ef393eab7a107d744cb84ddc5198f29ef18338653bc0c67205b720"
cat > "$W/rhcheck.py" << 'RH_RHC_EOF'
#!/usr/bin/env python3
"""rhcheck.py (relHygiene): reine Lese-/Pruefhilfe fuer das Apply-Skript (schreibt nichts ausser auf der Standardausgabe).
Modi:
  page HTML [dyn|none]       Seite bindet die lokale Chart.js ein (dyn: dynamischer Lader; none: nur keine externe Adresse), keine externe Chart.js-/CDN-Adresse
  js HDR BODY                lokale Chart.js: HTTP 200, sha256 der Bytes, Cache-/Typ-Kopfzeilen
  js304 HDR                  bedingte Anfrage mit If-None-Match -> 304 mit ETag
  jsfb HDR BODY              Ersatzantwort (Datei fehlt): 200, no-store, window.Chart, X-RH-Chart fehlt
  journal FILE [PFAD]        Journal-Auszug seit dem Start: keine 2xx/3xx-Zugriffszeilen, Fehlerzeile fuer PFAD (404) sichtbar
  inventory DIR              Protokoll-Dateien, logrotate, Journal-Einstellungen, Plattenfuellstand (nur lesend)
  tamper                     Selbsttest dieser Pruefungen mit absichtlich falschen Eingaben"""
import glob
import hashlib
import os
import re
import shutil
import sys
import tempfile

SHA = "74401d738dd3e03ee5dfb3b6841210fe2c4ead8a960c4011ca4ba0b78a9fd8f3"
SIZE = 205125
URL = "/static/vendor/chart-4.4.1.min.js"
BAD = ("jsdelivr", "unpkg", "cdnjs", "chart.js@", "npm/chart", "cdn.")
ACC = re.compile(r'"[A-Z]+ [^"]* HTTP/[0-9.]+" ([0-9]{3}) ')
ANSI = re.compile(r"\x1b\[[0-9;]*m")
rd = lambda p: open(p, encoding="utf-8", errors="replace").read()


def page(html, dyn=False):
    s = rd(html)
    for b in BAD:
        assert b not in s, "Seite enthaelt noch eine externe Chart.js-/CDN-Adresse (%s)" % b
    if dyn == "none":
        print("Seite: keine externe Chart.js-/CDN-Adresse")
        return
    n = s.count('<script src="%s"></script>' % URL)
    d = s.count("s.src='%s';" % URL)
    if dyn:
        assert d == 1, "dynamischer Lader mit lokaler Adresse fehlt (%dx)" % d
    else:
        assert n == 1, "lokales Chart.js-Skript %dx statt 1x" % n
    i = s.find(URL)
    assert 0 < i, "lokale Adresse fehlt"
    print("Seite: lokale Chart.js eingebunden (%s), keine externe Adresse" % ("dynamischer Lader" if dyn else "ein Skript-Tag"))


def hdr(path):
    h = rd(path)
    blocks = [b for b in re.split(r"\r?\n\r?\n", h) if b.strip()]
    b = blocks[-1] if blocks else h
    status = int(re.match(r"HTTP/[0-9.]+ ([0-9]+)", b.strip()).group(1))
    hd = {}
    for ln in b.splitlines()[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            hd[k.strip().lower()] = v.strip()
    return status, hd


def js(h, body):
    st, hd = hdr(h)
    assert st == 200, "Chart.js-Adresse: HTTP %s" % st
    raw = open(body, "rb").read()
    assert len(raw) == SIZE and hashlib.sha256(raw).hexdigest() == SHA, "Chart.js-Antwort: %d Bytes, sha256 %s statt %d / %s" % (len(raw), hashlib.sha256(raw).hexdigest()[:16], SIZE, SHA[:16])
    assert hd.get("cache-control") == "public, max-age=31536000, immutable", "Cache-Control: %s" % hd.get("cache-control")
    assert hd.get("etag") == '"%s"' % SHA[:32], "ETag: %s" % hd.get("etag")
    assert hd.get("x-rh-chart") == "4.4.1" and hd.get("x-content-type-options") == "nosniff", "Kennung/nosniff fehlen"
    assert "javascript" in hd.get("content-type", ""), "Content-Type: %s" % hd.get("content-type")
    print("Chart.js lokal: HTTP 200, %d Bytes, sha256 %s...%s stimmt, Cache-Control public/1 Jahr/immutable, ETag, nosniff" % (len(raw), SHA[:16], SHA[-8:]))


def js304(h):
    st, hd = hdr(h)
    assert st == 304 and hd.get("etag") == '"%s"' % SHA[:32], "bedingte Anfrage: HTTP %s statt 304" % st
    print("Chart.js lokal: bedingte Anfrage (If-None-Match) -> HTTP 304")


def jsfb(h, body):
    st, hd = hdr(h)
    raw = open(body, "rb").read()
    assert st == 200 and hd.get("x-rh-chart") == "fehlt" and "no-store" in hd.get("cache-control", "") and b"window.Chart" in raw, "Ersatzantwort unvollstaendig (HTTP %s)" % st
    print("Chart.js lokal fehlt: Ersatzantwort HTTP 200, no-store, ruhiger Hinweis statt JavaScript-Fehler")


def journal(path, probe=None):
    ls = [ANSI.sub("", x) for x in rd(path).splitlines()]
    idx = [i for i, x in enumerate(ls) if "relHygiene aktiv:" in x]
    assert idx, "Journal: Zeile 'relHygiene aktiv:' fehlt (Dashboard nicht neu gestartet oder Block nicht aktiv)"
    seg = ls[idx[-1]:]
    acc = [(int(m.group(1)), x) for x in seg for m in [ACC.search(x)] if m]
    ok = [x for c, x in acc if c < 400]
    assert not ok, "Journal seit Neustart: %d Zugriffszeilen mit 2xx/3xx, z. B. %s" % (len(ok), ok[0][:120])
    if probe:
        assert any(c == 404 and (" " + probe + " ") in x for c, x in acc), "Journal: Fehlerzeile 404 fuer %s fehlt (4xx sollen sichtbar bleiben)" % probe
    print("Journal seit Neustart: %d Zeilen, 0 Zugriffszeilen 2xx/3xx, %d Fehlerzeilen 4xx/5xx%s" % (len(seg) - 1, len(acc), (", 404 fuer %s sichtbar" % probe) if probe else ""))


def jval(p):
    try:
        return rd(p)
    except OSError:
        return ""


def inventory(d):
    kb = lambda n: ("%.1f KB" % (n / 1024.0)) if n < 1048576 else ("%.1f MB" % (n / 1048576.0))
    rows = []
    for sub in ("", "archive", "docs", "tools"):
        for p in glob.glob(os.path.join(d, sub, "*")):
            if os.path.isfile(p) and re.search(r"(\.log(\.[0-9]+)?|\.err|\.out|\.jsonl(\.[0-9]+)?)$", p):
                rows.append((os.path.getsize(p), os.path.relpath(p, d)))
    rows.sort(reverse=True)
    big = [r for r in rows if r[0] > 5 * 1048576]
    print("Protokoll-Dateien im Projektordner: %d, davon ueber 5 MB: %d%s" % (len(rows), len(big), ("  <- " + ", ".join("%s %s" % (n, kb(s)) for s, n in big)) if big else ""))
    for s, n in rows[:6]:
        print("   %-34s %10s" % (n, kb(s)))
    lr = shutil.which("logrotate") or ("/usr/sbin/logrotate" if os.path.exists("/usr/sbin/logrotate") else "")
    print("logrotate: %s" % ("installiert (%s); wird nicht benoetigt und nicht veraendert" % lr if lr else "NICHT installiert - wird NICHT nachinstalliert; die neue Rotation des Hang-Watchdog-Protokolls laeuft im Programm selbst (ohne logrotate); rtl433/aprs/health_check/watchdog begrenzen sich bereits selbst"))
    keys = {}
    for p in ["/etc/systemd/journald.conf"] + sorted(glob.glob("/etc/systemd/journald.conf.d/*.conf")) + sorted(glob.glob("/usr/lib/systemd/journald.conf.d/*.conf")):
        for ln in jval(p).splitlines():
            m = re.match(r"^\s*(Storage|SystemMaxUse|SystemMaxFileSize|SystemKeepFree|RuntimeMaxUse)\s*=\s*(\S+)", ln)
            if m:
                keys[m.group(1)] = (m.group(2), os.path.basename(p))
    if "SystemMaxUse" in keys:
        print("Journal-Begrenzung vorhanden: " + ", ".join("%s=%s (%s)" % (k, v[0], v[1]) for k, v in sorted(keys.items())) + " - kein Drop-in noetig, nichts geaendert")
    else:
        print("HINWEIS Journal: keine SystemMaxUse-Begrenzung gefunden (Standard: bis 10 Prozent des Dateisystems, hoechstens 4 GB). Nichts geaendert. Wer begrenzen will, legt ein Drop-in an: Datei /etc/systemd/journald.conf.d/zz-prepper-log.conf mit den Zeilen [Journal] und SystemMaxUse=200M und startet systemd-journald neu")
    st = os.statvfs(d)
    print("Datentraeger des Projektordners: %d Prozent belegt, frei %s" % (round(100.0 * (st.f_blocks - st.f_bfree) / max(1, st.f_blocks - st.f_bfree + st.f_bavail)), kb(st.f_bavail * st.f_frsize)))


def tamper():
    d = tempfile.mkdtemp(prefix="rhc-")
    n = 0
    try:
        def w(name, data, mode="w"):
            p = os.path.join(d, name)
            open(p, mode).write(data)
            return p
        good = '<head><script src="%s"></script></head>' % URL
        page(w("a.html", good))
        page(w("a.html", good), "none")
        n += 1
        try:
            page(w("c.html", good + "unpkg"), "none")
        except AssertionError:
            n += 1
        else:
            raise SystemExit("page none: unpkg nicht erkannt")
        for name, html, dyn in (("cdn", good + '<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>', False), ("fehlt", "<head></head>", False), ("doppelt", good * 2, False), ("dynfehlt", good, True), ("dyncdn", "s.src='%s';" % URL + "jsdelivr", True)):
            try:
                page(w(name + ".html", html), dyn)
            except AssertionError:
                n += 1
            else:
                raise SystemExit("page: %s nicht erkannt" % name)
        raw = b"x" * 10
        okh = "HTTP/1.1 200 OK\r\nContent-Type: application/javascript; charset=utf-8\r\nCache-Control: public, max-age=31536000, immutable\r\nETag: \"%s\"\r\nX-Content-Type-Options: nosniff\r\nX-RH-Chart: 4.4.1\r\n\r\n" % SHA[:32]
        try:
            js(w("h.txt", okh), w("b.bin", raw, "wb"))
        except AssertionError:
            n += 1
        else:
            raise SystemExit("js: falsche Bytes nicht erkannt")
        for name, h in (("cache", okh.replace("immutable", "")), ("etag", okh.replace(SHA[:32], "0" * 32)), ("status", okh.replace("200 OK", "404 Not Found")), ("kennung", okh.replace("4.4.1", "x"))):
            real = None
            try:
                st, hd = hdr(w("h2.txt", h))
                assert st == 200 and hd.get("cache-control") == "public, max-age=31536000, immutable" and hd.get("etag") == '"%s"' % SHA[:32] and hd.get("x-rh-chart") == "4.4.1"
            except AssertionError:
                n += 1
            else:
                raise SystemExit("hdr: %s nicht erkannt" % name)
        st, hd = hdr(w("h3.txt", "HTTP/1.1 304 NOT MODIFIED\r\nETag: \"%s\"\r\n\r\n" % SHA[:32]))
        assert st == 304
        js304(w("h3.txt", "HTTP/1.1 304 NOT MODIFIED\r\nETag: \"%s\"\r\n\r\n" % SHA[:32]))
        n += 1
        try:
            js304(w("h4.txt", "HTTP/1.1 200 OK\r\n\r\n"))
        except AssertionError:
            n += 1
        else:
            raise SystemExit("js304: 200 nicht erkannt")
        jsfb(w("h5.txt", "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nX-RH-Chart: fehlt\r\n\r\n"), w("b5.bin", b"window.Chart=C;", "wb"))
        n += 1
        try:
            jsfb(w("h6.txt", "HTTP/1.1 200 OK\r\nCache-Control: public\r\nX-RH-Chart: fehlt\r\n\r\n"), w("b5.bin", b"window.Chart=C;", "wb"))
        except AssertionError:
            n += 1
        else:
            raise SystemExit("jsfb: Cache nicht erkannt")
        jr = 'alt 127.0.0.1 "GET / HTTP/1.1" 200 -\nrelHygiene aktiv: x\nWerkzeug start\n127.0.0.1 - - [t] "GET /nix HTTP/1.1" 404 -\n127.0.0.1 - - [t] \x1b[1m"GET /x HTTP/1.1"\x1b[0m \x1b[31m404\x1b[0m -\n'
        journal(w("j1.txt", jr), "/nix")
        n += 1
        for name, t, pr in (("200", jr + '127.0.0.1 - - [t] "GET /api/x HTTP/1.1" 200 -\n', "/nix"), ("302", jr + '127.0.0.1 - - [t] "GET /a HTTP/1.1" 302 -\n', "/nix"), ("kein404", jr, "/anders"), ("ohnemarke", "x\n", None), ("304farbig", jr + '127.0.0.1 - - [t] \x1b[1m"GET /a HTTP/1.1"\x1b[0m \x1b[36m304\x1b[0m -\n', None)):
            try:
                journal(w("j2.txt", t), pr)
            except AssertionError:
                n += 1
            else:
                raise SystemExit("journal: %s nicht erkannt" % name)
        os.makedirs(os.path.join(d, "arch"))
        w("a.log", "x")
        w("big.log", "y" * (6 * 1048576))
        buf = os.popen("python3 %s inventory %s" % (os.path.abspath(__file__), d)).read()
        assert "big.log" in buf and "ueber 5 MB: 1" in buf and "logrotate:" in buf and "Journal" in buf, buf
        n += 1
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("rhcheck Selbsttest ok: %d Pruefungen, falsche Eingaben werden erkannt" % n)


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a and a[0] == "page":
            page(a[1], ("dyn" if a[2] == "dyn" else ("none" if a[2] == "none" else False)) if len(a) > 2 else False)
        elif a and a[0] == "js":
            js(a[1], a[2])
        elif a and a[0] == "js304":
            js304(a[1])
        elif a and a[0] == "jsfb":
            jsfb(a[1], a[2])
        elif a and a[0] == "journal":
            journal(a[1], a[2] if len(a) > 2 else None)
        elif a and a[0] == "inventory":
            inventory(a[1])
        elif a and a[0] == "tamper":
            tamper()
        else:
            print(__doc__)
            sys.exit(2)
    except AssertionError as e:
        print("rhcheck FEHLER: %s" % e)
        sys.exit(1)
RH_RHC_EOF
EXPECT_PCK="e263d2221c2c3525dd742176dfd7e65793b78b4685efa5de597858932e4b4777"
cat > "$W/pdcheck.py" << 'RH_PCK_EOF'
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
RH_PCK_EOF
EXPECT_RSL="6764f2f313a6a52ea35cdd2529333e6c6406314b634bceab625f7548b6da06d4"
cat > "$W/schreiblast.py" << 'RH_RSL_EOF'
#!/usr/bin/env python3
"""schreiblast.py (relHygiene, REL-04): zeigt NUR LESEND, welche Prozesse, Dateien und Journal-Eintraege auf dem Pi am meisten schreiben.
Aufruf: python3 /home/fmg/prepper-dashboard/tools/schreiblast.py [Sekunden]      (Standard 20, erlaubt 1 bis 300)
Nichts wird geaendert, nichts gesendet, nichts dauerhaft gestartet; Messung = zweimal /proc, /sys und Datei-Groessen lesen mit Pause dazwischen.
Prozess-Zahlen (/proc/PID/io) gibt es nur fuer eigene Prozesse (fmg) bzw. mit root; fremde werden gezaehlt, nicht angezeigt.
Journal lesen kann fmg nur mit Rechten (Gruppe systemd-journal/adm); sonst mit PRSL_SUDO=1 (nutzt sudo -n, braucht ein gueltiges sudo-Ticket) oder per Hand mit sudo.
Ausgabe enthaelt nur Dateinamen, Groessen und Zaehler (keine Inhalte, keine Befehlszeilen)."""
import glob
import os
import re
import subprocess
import sys
import time

BASE = os.environ.get("PRSL_DIR", "/home/fmg/prepper-dashboard")
UNITS = ("prepper-dashboard", "prepper-sdr", "mesh-bridge", "mesh-bridge-bayern", "mesh-hang-watchdog", "prepper-sd-health")
LOGLIKE = re.compile(r"(\.log(\.[0-9]+)?|\.err|\.out|\.jsonl(\.[0-9]+)?)$")
WARN_LOG = 5 * 1024 * 1024


def kb(n):
    return "%.1f KB" % (n / 1024.0) if n < 1048576 else "%.1f MB" % (n / 1048576.0)


def rd(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read(1 << 20)


def procs():
    """pid -> (name, write_bytes) fuer lesbare Prozesse; zweite Rueckgabe: Anzahl nicht lesbarer."""
    out, bad = {}, 0
    for d in glob.glob("/proc/[0-9]*"):
        pid = d.rsplit("/", 1)[1]
        try:
            io = rd(d + "/io")
            wb = int(re.search(r"^write_bytes:\s*([0-9]+)", io, re.M).group(1))
            name = rd(d + "/comm").strip()
            if name.startswith("python"):
                try:
                    parts = open(d + "/cmdline", "rb").read(4096).split(b"\0")
                    scr = [x.decode("utf-8", "replace") for x in parts[1:4] if x.endswith(b".py")]
                    if scr:
                        name = "python " + os.path.basename(scr[0])
                except OSError:
                    pass
            out[pid] = (name, wb)
        except (OSError, AttributeError, ValueError):
            bad += 1
    return out, bad


def disk():
    """Datentraeger der Wurzel: (Name, geschriebene Sektoren) aus /proc/diskstats, Zuordnung ueber major:minor aus mountinfo."""
    try:
        mm = None
        for ln in rd("/proc/self/mountinfo").splitlines():
            f = ln.split()
            if len(f) > 4 and f[4] == "/":
                mm = f[2]
        if not mm:
            return None
        for ln in rd("/proc/diskstats").splitlines():
            f = ln.split()
            if len(f) > 9 and "%s:%s" % (f[0], f[1]) == mm:
                return f[2], int(f[9])
    except (OSError, ValueError):
        pass
    return None


def files():
    """Datei -> (Groesse, mtime) im Projektordner (eine Ebene) plus archive/ und docs/ (eine Ebene)."""
    out = {}
    for sub in ("", "archive", "docs", "tools", "static/vendor"):
        d = os.path.join(BASE, sub)
        try:
            for e in os.scandir(d):
                try:
                    if e.is_file(follow_symlinks=False):
                        st = e.stat(follow_symlinks=False)
                        out[os.path.join(sub, e.name)] = (st.st_size, st.st_mtime)
                except OSError:
                    pass
        except OSError:
            pass
    return out


def jr(args):
    pre = ["sudo", "-n"] if os.environ.get("PRSL_SUDO") == "1" else []
    try:
        r = subprocess.run(pre + ["journalctl", "--no-pager", "-q"] + args, capture_output=True, timeout=90)
        txt = r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")
        if r.returncode != 0 or "insufficient permissions" in txt or "Hint: You are currently not seeing" in txt:
            return None, txt.strip()[:120]
        return r.stdout.decode("utf-8", "replace"), ""
    except (OSError, subprocess.SubprocessError) as e:
        return None, e.__class__.__name__


def journal_cap():
    keys = {}
    paths = ["/etc/systemd/journald.conf"] + sorted(glob.glob("/etc/systemd/journald.conf.d/*.conf")) + sorted(glob.glob("/usr/lib/systemd/journald.conf.d/*.conf"))
    for p in paths:
        try:
            for ln in rd(p).splitlines():
                m = re.match(r"^\s*(Storage|SystemMaxUse|SystemMaxFileSize|SystemKeepFree|RateLimitIntervalSec|RateLimitBurst)\s*=\s*(\S+)", ln)
                if m:
                    keys[m.group(1)] = (m.group(2), os.path.basename(p))
        except OSError:
            pass
    return keys


def main():
    try:
        secs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
        if not 1 <= secs <= 300:
            raise ValueError
    except ValueError:
        print("Aufruf: schreiblast.py [Sekunden 1-300]")
        return 2
    print("=== Schreiblast (nur lesend, Messfenster %d s, %s) ===" % (secs, time.strftime("%d.%m.%Y %H:%M:%S")))
    try:
        print("Last (1/5/15 min): %s" % " ".join(rd("/proc/loadavg").split()[:3]))
    except OSError:
        pass
    p0, bad0 = procs()
    d0 = disk()
    f0 = files()
    t0 = time.time()
    time.sleep(secs)
    p1, bad1 = procs()
    d1 = disk()
    f1 = files()
    dt = max(1.0, time.time() - t0)
    if d0 and d1 and d0[0] == d1[0]:
        w = (d1[1] - d0[1]) * 512
        print("Datentraeger %s (Wurzel): %s im Fenster = %s/min = rund %.1f GB/Tag bei gleichbleibender Last (Hochrechnung, nur Anhaltspunkt)" % (d0[0], kb(w), kb(w * 60 / dt), w / dt * 86400 / 1e9))
    else:
        print("Datentraeger: nicht ermittelbar")
    rows = []
    for pid, (name, wb) in p1.items():
        if pid in p0:
            rows.append((wb - p0[pid][1], name, pid, wb))
    rows.sort(reverse=True)
    print("Prozesse mit den meisten Schreibzugriffen im Fenster (lesbar: %d, nicht lesbar/fremd: %d):" % (len(p1), bad1))
    shown = 0
    for dlt, name, pid, wb in rows[:8]:
        if dlt <= 0 and shown >= 3:
            break
        print("  %-28s PID %-7s %10s/min   seit Start gesamt %s" % (name[:28], pid, kb(dlt * 60 / dt), kb(wb)))
        shown += 1
    if not rows:
        print("  (keine lesbaren Prozesse)")
    gr = []
    for n, (sz, mt) in f1.items():
        if n in f0:
            gr.append((sz - f0[n][0], n, sz))
    gr.sort(reverse=True)
    print("Dateien im Projektordner mit Wachstum im Fenster:")
    k = 0
    for g, n, sz in gr[:6]:
        if g > 0:
            print("  %-40s +%s (%s)" % (n[:40], kb(g), kb(sz)))
            k += 1
    chg = [n for n in f1 if n in f0 and f1[n][1] != f0[n][1] and f1[n][0] <= f0[n][0]]
    if not k:
        print("  keine Datei ist gewachsen%s" % ((" (neu geschrieben, gleiche oder kleinere Groesse: %s)" % ", ".join(sorted(chg)[:6])) if chg else ""))
    elif chg:
        print("  zusaetzlich neu geschrieben ohne Wachstum: %s" % ", ".join(sorted(chg)[:6]))
    logs = sorted(((sz, n) for n, (sz, mt) in f1.items() if LOGLIKE.search(n)), reverse=True)
    print("Protokoll-Dateien (*.log, *.log.N, *.err, *.jsonl; Grenze fuer Hinweis %s):" % kb(WARN_LOG))
    for sz, n in logs[:10]:
        print("  %-40s %10s%s" % (n[:40], kb(sz), "   <- gross, Rotation pruefen" if sz > WARN_LOG else ""))
    if not logs:
        print("  (keine)")
    big = sorted(((sz, n) for n, (sz, mt) in f1.items()), reverse=True)[:5]
    print("Groesste Dateien: " + ", ".join("%s %s" % (n, kb(sz)) for sz, n in big))
    print("Journal:")
    out, why = jr(["--disk-usage"])
    print("  %s" % (out.strip().replace("\n", " ") if out else "Plattenbedarf nicht lesbar (%s) - mit sudo: journalctl --disk-usage" % (why or "keine Rechte")))
    cap = journal_cap()
    if cap:
        print("  Einstellungen: " + ", ".join("%s=%s (%s)" % (k2, v[0], v[1]) for k2, v in sorted(cap.items())))
    else:
        print("  keine Journal-Einstellungen gesetzt (Standard: bis 10 %% des Dateisystems, hoechstens 4 GB)")
    for u in UNITS:
        out, why = jr(["-u", u, "--since", "-10min", "-o", "cat"])
        if out is None:
            print("  %-22s nicht lesbar (%s) - mit sudo: sudo journalctl -u %s --since -10min --no-pager | wc -l" % (u, why or "keine Rechte", u))
            continue
        lines = [x for x in out.splitlines() if x.strip()]
        acc = sum(1 for x in lines if re.search(r'"[A-Z]+ [^"]* HTTP/[0-9.]+" [0-9]{3} ', x))
        print("  %-22s %6d Zeilen in 10 min (davon Zugriffszeilen %d)" % (u, len(lines), acc))
    print("Hinweis: Tagesbilanz der SSD/SD zeigt zusaetzlich die Kachel auf /pi (sd_health.json). Dieses Programm laeuft nur auf Aufruf.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
RH_RSL_EOF
EXPECT_CHB="e41c66978e469d6e9c74d84ca7a04ab9fec9614a3d372c260fcc0176b90d49fb"
cat > "$W/chart.b64" << 'RH_CHB_EOF'
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
AwA=
RH_CHB_EOF
PRH="$W/patch-rh.py"; RED="$W/edits_all.py"; RED2="$W/edits_docs.py"; RDH="$W/blk_dash.py"; RGD="$W/guard_relhygiene.py"; RHC="$W/rhcheck.py"; PCK="$W/pdcheck.py"; RSL="$W/schreiblast.py"; CHB="$W/chart.b64"
for x in "$EXPECT_PRH $PRH" "$EXPECT_RED $RED" "$EXPECT_RED2 $RED2" "$EXPECT_RDH $RDH" "$EXPECT_RGD $RGD" "$EXPECT_RHC $RHC" "$EXPECT_PCK $PCK" "$EXPECT_RSL $RSL" "$EXPECT_CHB $CHB"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
base64 -d "$CHB" 2>/dev/null | gunzip -c > "$W/chart.js" 2>/dev/null || stop "eingebettete Chart.js laesst sich nicht entpacken (Skript beschaedigt - bitte neu laden)"
[[ "$(sha256sum "$W/chart.js" | cut -d' ' -f1)" == "$CH_SHA" && "$(wc -c < "$W/chart.js")" == "$CH_SIZE" ]] || stop "entpackte Chart.js: sha256/Groesse stimmt nicht (erwartet $CH_SHA, $CH_SIZE Bytes) - Skript beschaedigt"
echo "OK eingebettete Dateien und Chart.js 4.4.1 (${CH_SIZE} Bytes, sha256 ${CH_SHA:0:16}...) geprueft"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
for x in "$F" "$PD" "$FH" "$HW" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); PD0=$(s16 "$PD"); FH16=$(s16 "$FH"); HW16=$(s16 "$HW"); SM16=$(s16 "$SMF"); SDR16=$(s16 "$M"); DB16=$(s16 "$DBF"); MR16=$(s16 "$MR")
LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt ); CF16=$( [[ -f "$CF" ]] && s16 "$CF" || echo fehlt )
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Basis" "$KNOWN_D16N" "relHygiene schon drin"))"
echo "Basis prepper_docs.py sha16 $PD0 ($(wc -l < "$PD") Zeilen, $(lbl "$PD0" "$KNOWN_PD16" "Basis" "$KNOWN_PD16N" "relHygiene schon drin"))"
echo "Basis funk_health.py sha16 $FH16 ($(wc -l < "$FH") Zeilen, $(lbl "$FH16" "$KNOWN_FH16" "Basis" "$KNOWN_FH16N" "relHygiene schon drin"))"
echo "Basis mesh_hang_watchdog.py sha16 $HW16 ($(wc -l < "$HW") Zeilen, $(lbl "$HW16" "$KNOWN_HW16" "Basis" "$KNOWN_HW16N" "relHygiene schon drin"))"
echo "prepper_sdr.py sha16 $SDR16, sdr_manager.py sha16 $SM16, database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert (Vergleich vorher/nachher)"
bad=""
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N);"
[[ "$PD0" == "$KNOWN_PD16" || "$PD0" == "$KNOWN_PD16N" ]] || bad="$bad prepper_docs.py (sha16 $PD0, erwartet $KNOWN_PD16 oder $KNOWN_PD16N);"
[[ "$FH16" == "$KNOWN_FH16" || "$FH16" == "$KNOWN_FH16N" ]] || bad="$bad funk_health.py (sha16 $FH16, erwartet $KNOWN_FH16 oder $KNOWN_FH16N);"
[[ "$HW16" == "$KNOWN_HW16" || "$HW16" == "$KNOWN_HW16N" ]] || bad="$bad mesh_hang_watchdog.py (sha16 $HW16, erwartet $KNOWN_HW16 oder $KNOWN_HW16N);"
# Dateien, die dieser Patch nicht anfasst (andere Patches duerfen sie inzwischen geaendert haben): nur Hinweis, vorher/nachher-Vergleich unten
for x in "prepper_sdr.py:$SDR16:$KNOWN_SDR16" "sdr_manager.py:$SM16:$KNOWN_SM16" "database.py:$DB16:$KNOWN_DB16" "mesh_router.py:$MR16:$KNOWN_MR16" "lagegeo.py:$LG16:$KNOWN_LG16"; do
  IFS=: read -r xn xh xk <<< "$x"
  [[ "$xh" == "$xk" || "$xh" == fehlt ]] || echo "HINWEIS $xn sha16 $xh statt $xk (anderer Patch-Stand; relHygiene fasst die Datei nicht an, vorher/nachher-Vergleich folgt)"
done
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      relHygiene passt nur auf den Stand nach sdrStick3e/relBackup2 (dashboard $KNOWN_D16, prepper_docs $KNOWN_PD16, funk_health $KNOWN_FH16, mesh_hang_watchdog $KNOWN_HW16) - nichts geaendert. Lokale Aenderungen oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis der vier zu aendernden Dateien = erwarteter Stand (bzw. relHygiene schon drin)"
if [[ "$CF16" == "$KNOWN_CF16" ]]; then echo "OK sdr_config.json sha16 $CF16 (wie erwartet, wird nicht angefasst)"; else echo "HINWEIS sdr_config.json sha16 $CF16 statt $KNOWN_CF16 (die Datei aendert sich im Betrieb) - wird nicht angefasst"; fi
grep -q '# ===== sdrStick3e:' "$F" && grep -q '# ===== projDoc:' "$F" && grep -q '# ===== piPolish2:' "$F" || stop "sdrStick3e/projDoc/piPolish2 fehlt im Dashboard (Basis)"
[[ -w "$DASH_DIR" ]] || stop "Projektordner $DASH_DIR ist nicht beschreibbar"
for d in static static/vendor tools docs; do [[ ! -e "$DASH_DIR/$d" || -w "$DASH_DIR/$d" ]] || stop "Ordner $DASH_DIR/$d ist nicht beschreibbar (Eigentuemer?)"; done
for x in "$F" "$PD" "$FH" "$HW"; do [[ -w "$x" ]] || stop "$(basename "$x") ist nicht beschreibbar"; done
if [[ -e "$CH" ]]; then [[ "$(sha256sum "$CH" | cut -d' ' -f1)" == "$CH_SHA" ]] || stop "$CH existiert mit anderem Inhalt (wird nicht ueberschrieben)"; fi
if [[ -e "$SL" ]]; then [[ "$(sha256sum "$SL" | cut -d' ' -f1)" == "$EXPECT_RSL" ]] || stop "$SL existiert mit anderem Inhalt (wird nicht ueberschrieben)"; fi
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht (fuer den Guard-Test)"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
# ---------- 1b) Ist-Zustand Protokolle (nur lesend) ----------
echo "--- Ist-Zustand Protokolle (nur lesend, nichts geaendert):"
python3 "$RHC" inventory "$DASH_DIR" 2>&1 | sed 's/^/   /' || true
echo "   mesh-hang-watchdog.timer: $(systemctl is-active mesh-hang-watchdog.timer 2>/dev/null || true) (der Watchdog laeuft als kurzer Lauf je Timer-Takt; die neue Rotation gilt ab dem naechsten Lauf)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W; nichts installiert, nichts gesendet) ----------
python3 "$PRH" relHygiene dsh "$F" "$W/work/dashboard.py" "$RDH" "$RED" > "$W/q_dsh.log" || { cat "$W/q_dsh.log"; stop "dashboard.py: Stelle fuer relHygiene nicht eindeutig (Datei vom Standard abweichend)"; }
python3 "$PRH" relHygiene fh "$FH" "$W/work/funk_health.py" - "$RED" > "$W/q_fh.log" || { cat "$W/q_fh.log"; stop "funk_health.py: Stelle fuer relHygiene nicht eindeutig (Datei vom Standard abweichend)"; }
python3 "$PRH" relHygiene hw "$HW" "$W/work/mesh_hang_watchdog.py" - "$RED" > "$W/q_hw.log" || { cat "$W/q_hw.log"; stop "mesh_hang_watchdog.py: Stelle fuer relHygiene nicht eindeutig (Datei vom Standard abweichend)"; }
python3 "$PRH" relHygiene pd "$PD" "$W/work/prepper_docs.py" - "$RED2" > "$W/q_pd.log" || { cat "$W/q_pd.log"; stop "prepper_docs.py: Stelle fuer relHygiene nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py"); NFH16=$(s16 "$W/work/funk_health.py"); NHW16=$(s16 "$W/work/mesh_hang_watchdog.py"); NPD16=$(s16 "$W/work/prepper_docs.py")
[[ "$ND16" == "$KNOWN_D16N" && "$NFH16" == "$KNOWN_FH16N" && "$NHW16" == "$KNOWN_HW16N" && "$NPD16" == "$KNOWN_PD16N" ]] || stop "Ergebnis dashboard.py $ND16 / funk_health.py $NFH16 / mesh_hang_watchdog.py $NHW16 / prepper_docs.py $NPD16 statt $KNOWN_D16N / $KNOWN_FH16N / $KNOWN_HW16N / $KNOWN_PD16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q_dsh.log")), funk_health.py $NFH16 ($(cat "$W/q_fh.log")), mesh_hang_watchdog.py $NHW16 ($(cat "$W/q_hw.log")), prepper_docs.py $NPD16 ($(cat "$W/q_pd.log"))"
for k in "dsh:dashboard.py:$RDH:$RED" "fh:funk_health.py:-:$RED" "hw:mesh_hang_watchdog.py:-:$RED" "pd:prepper_docs.py:-:$RED2"; do
  IFS=: read -r kd kn kb ke <<< "$k"
  python3 "$PRH" relHygiene "$kd" "$W/work/$kn" "$W/work/x.py" "$kb" "$ke" > /dev/null && cmp -s "$W/work/$kn" "$W/work/x.py" || stop "$kn nicht idempotent (zweite Anwendung aendert die Datei)"
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/funk_health.py" "$W/work/mesh_hang_watchdog.py" "$W/work/prepper_docs.py" "$RSL" "$PRH" "$RED" "$RED2" "$RDH" "$RGD" "$RHC" "$PCK"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (4 Programmdateien, schreiblast.py, Bloecke, Pruefprogramme; $SPY und $VPY)"
# Sandbox: neue Dateien in $W/neu; Selbsttests und Guard laufen nur dort
cp "$W/work/dashboard.py" "$W/work/funk_health.py" "$W/work/mesh_hang_watchdog.py" "$W/work/prepper_docs.py" "$W/neu/"
cp "$RSL" "$W/neu/tools/schreiblast.py"; cp "$W/chart.js" "$W/neu/static/vendor/chart-4.4.1.min.js"
python3 "$RHC" tamper > "$W/pt0.log" 2>&1 || { tail -5 "$W/pt0.log"; stop "Pruefprogramm rhcheck: Selbsttest meldet Fehler"; }
tail -1 "$W/pt0.log" | cut -c1-200
python3 "$PCK" tamper > "$W/pt1.log" 2>&1 || { tail -5 "$W/pt1.log"; stop "Pruefprogramm pdcheck: Selbsttest meldet Fehler"; }
tail -1 "$W/pt1.log" | cut -c1-200
# AST-Guard: Rueckbau (Block weg, Stellen zurueck) muss die bekannte Basis ergeben; dann Regeln, Verhalten in der Flask-Sandbox und Mutationstest
"$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RED" "$RED2" "$RDH" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: relHygiene im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" && "$(s16 "$W/alt/funk_health.py")" == "$KNOWN_FH16" && "$(s16 "$W/alt/mesh_hang_watchdog.py")" == "$KNOWN_HW16" && "$(s16 "$W/alt/prepper_docs.py")" == "$KNOWN_PD16" ]] || stop "AST-Guard: Stand ohne relHygiene ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py")/$(s16 "$W/alt/funk_health.py")/$(s16 "$W/alt/mesh_hang_watchdog.py")/$(s16 "$W/alt/prepper_docs.py"))"
"$VPY" "$RGD" check "$W/alt" "$W/neu" "$RDH" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard relHygiene meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" "$VPY" "$RGD" mutate "$W/neu" "$RDH" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER" "$W/gm.log" | head -12 | cut -c1-200; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt"; }
tail -1 "$W/gm.log" | cut -c1-200
# Generator in der Sandbox: Kopie der Programmdateien (ohne config.py), Ausgabe nach $W/sbxdocs, kein Zugriff auf das laufende Dashboard (Port 1), nichts gesendet
for x in "$DASH_DIR"/*.py "$DASH_DIR"/*.sh; do [[ -f "$x" ]] || continue; [[ "$(basename "$x")" == config.py ]] && continue; cp "$x" "$W/dsbx/"; done
[[ -d "$DASH_DIR/tools" ]] && cp -a "$DASH_DIR/tools" "$W/dsbx/tools"
mkdir -p "$W/dsbx/tools" "$W/dsbx/static/vendor"; [[ -d "$DASH_DIR/static" ]] && { cp -a "$DASH_DIR/static/." "$W/dsbx/static/" 2>/dev/null || true; }
cp "$W/neu/dashboard.py" "$W/neu/funk_health.py" "$W/neu/mesh_hang_watchdog.py" "$W/neu/prepper_docs.py" "$W/dsbx/"; cp "$RSL" "$W/dsbx/tools/schreiblast.py"; cp "$W/chart.js" "$W/dsbx/static/vendor/chart-4.4.1.min.js"
PRDOCS_BASE="$W/dsbx" PRDOCS_OUT="$W/sbxdocs" PRDOCS_PORT=1 python3 "$W/dsbx/prepper_docs.py" --dump-stable "$W/st1.txt" > "$W/gen0.log" 2>&1 || { tail -12 "$W/gen0.log"; stop "Generator prepper_docs.py in der Sandbox meldet einen Fehler"; }
python3 "$PCK" docs "$W/sbxdocs" > "$W/gen1.log" 2>&1 || { cat "$W/gen1.log"; stop "Sandbox-Version der Projektbeschreibung fehlerhaft"; }
echo "OK Generator-Probelauf in der Sandbox: $(cat "$W/gen1.log")"
SBT=$(ls -1 "$W/sbxdocs"/*.txt | tail -1)
for k in "Logs und Schreiblast (relHygiene commit19, Audit REL-04)" "Diagramme: Chart.js lokal (relHygiene commit19, Audit REL-09)" "Sicherung und Wiederherstellung (relBackup commit18, relBackup2 commit18b)" "tools/schreiblast.py" "static/vendor/chart-4.4.1.min.js" "74401d738dd3e03e" "kein logrotate" "142 MB" "Zugriffsprotokoll"; do
  grep -qF "$k" "$SBT" || stop "Sandbox-Version der Beschreibung enthaelt '$k' nicht (neuer Text fehlt)"
done
if grep -qi "cdn.jsdelivr.net/npm" "$SBT"; then
  grep -i "cdn.jsdelivr.net/npm" "$SBT" | head -3 | cut -c1-200 | sed 's/^/   | /'
  stop "Sandbox-Version der Beschreibung nennt noch eine CDN-Adresse fuer Chart.js als Ist-Zustand"
fi
echo "OK Sandbox-Version beschreibt Log-Richtlinie (Zugriffsprotokoll, Rotation, schreiblast.py, kein logrotate), lokale Chart.js und die Sicherung nach relBackup/relBackup2 (~142 MB)"
PRDOCS_BASE="$W/dsbx" PRDOCS_OUT="$W/sbxdocs" PRDOCS_PORT=1 python3 "$W/dsbx/prepper_docs.py" --dump-stable "$W/st2.txt" > "$W/gen2.log" 2>&1 || true
if grep -q "UNVERAENDERT" "$W/gen2.log"; then echo "OK Generator idempotent (zweiter Lauf: UNVERAENDERT, keine neue Version)"
else
  echo "Generator-Lauf 2 meldet nicht UNVERAENDERT. Unterschied der in den Stand-Hash eingehenden Teile (Lauf 1 -> Lauf 2, geschwaerzt, erste 40 Zeilen):"
  diff -u "$W/st1.txt" "$W/st2.txt" 2>&1 | head -40 | cut -c1-220 | sed 's/^/   | /' || true
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
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
CH0=$(code "$B/static/vendor/chart-4.4.1.min.js"); echo "Chart.js-Adresse vorher: HTTP $CH0 (vor dem Patch normalerweise 404)"
# welche Dateien muessen ersetzt werden
NEED_D=0; NEED_FH=0; NEED_HW=0; NEED_P=0; NEED_CH=0; NEED_SL=0
cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
cmp -s "$W/work/funk_health.py" "$FH" || NEED_FH=1
cmp -s "$W/work/mesh_hang_watchdog.py" "$HW" || NEED_HW=1
cmp -s "$W/work/prepper_docs.py" "$PD" || NEED_P=1
cmp -s "$W/chart.js" "$CH" 2>/dev/null || NEED_CH=1
cmp -s "$RSL" "$SL" 2>/dev/null || NEED_SL=1
NEED_ALL="$NEED_D$NEED_FH$NEED_HW$NEED_P$NEED_CH$NEED_SL"
NEED_RESTART=0; [[ "$NEED_D" == 1 || "$NEED_FH" == 1 || "$NEED_CH" == 1 ]] && NEED_RESTART=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_ALL" == 000000 ]]; then echo "  Zustand: relHygiene ist schon vollstaendig installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py=$NEED_D funk_health.py=$NEED_FH mesh_hang_watchdog.py=$NEED_HW prepper_docs.py=$NEED_P static/vendor/chart-4.4.1.min.js=$NEED_CH tools/schreiblast.py=$NEED_SL (1 = ersetzen/neu), Neustart nur prepper-dashboard: $([[ "$NEED_RESTART" == 1 ]] && echo ja || echo nein), Sicherungen *.bak-relhygiene-ZEIT (letzte $KEEP_LAST), eine sudo-Passwortabfrage."; fi
  echo "COMMIT $COMMIT_ARG relhygiene=dry fertig"
  exit 0
fi
[[ "$NEED_ALL" == 000000 ]] || { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; }
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
JB0=$(jc -u prepper-dashboard --since "-10min" --no-pager -o cat | wc -l || true)
JA0=$(jc -u prepper-dashboard --since "-10min" --no-pager -o cat | grep -cE '"[A-Z]+ [^"]* HTTP/[0-9.]+" [0-9]{3} ' || true)
echo "Journal prepper-dashboard vorher (letzte 10 min): ${JB0:-0} Zeilen, davon Zugriffszeilen ${JA0:-0} (nur Zaehlung, Inhalte nicht ausgegeben)"
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert) ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0; INST_CH=0; INST_SL=0; MK_STATIC=0; MK_VENDOR=0; MK_TOOLS=0
ls -1 "$DOCS" 2>/dev/null | sort > "$W/docs0.txt" || true
DOCS_EXISTED=0; [[ -d "$DOCS" ]] && DOCS_EXISTED=1
ALL=("$F" "$PD" "$FH" "$HW")
T0D=$(date +%s)
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "relHygiene|Traceback" | tail -4 | cut -c1-200
  for x in "${ALL[@]}"; do [[ -f "$x.bak-relhygiene-$TS" ]] && cp -a "$x.bak-relhygiene-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
  [[ "$INST_CH" == 1 ]] && rm -f "$CH"
  [[ "$INST_SL" == 1 ]] && rm -f "$SL"
  [[ "$MK_VENDOR" == 1 ]] && rmdir "$DASH_DIR/static/vendor" 2>/dev/null
  [[ "$MK_STATIC" == 1 ]] && rmdir "$DASH_DIR/static" 2>/dev/null
  [[ "$MK_TOOLS" == 1 ]] && rmdir "$DASH_DIR/tools" 2>/dev/null
  if [[ -d "$DOCS" ]]; then
    ls -1 "$DOCS" | sort > "$W/docs1.txt"
    comm -13 "$W/docs0.txt" "$W/docs1.txt" | grep -E '^Projektbeschreibung Lage Pi v[0-9]{8}-[0-9]{4}\.(txt|md)$' | while read -r o; do rm -f -- "$DOCS/$o"; done
    [[ "$DOCS_EXISTED" == 0 ]] && rmdir "$DOCS" 2>/dev/null
  fi
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  for x in "${ALL[@]}"; do [[ -f "$x.bak-relhygiene-$TS" ]] || continue; cmp -s "$x" "$x.bak-relhygiene-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
  echo "  neue Dateien entfernt, soweit dieser Lauf sie angelegt hat: chart-4.4.1.min.js=$([[ -e "$CH" ]] && echo vorhanden || echo weg), schreiblast.py=$([[ -e "$SL" ]] && echo vorhanden || echo weg)"
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_ALL" != 000000 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_ALL" == 000000 ]]; then
  echo "OK relHygiene schon installiert (dashboard.py, funk_health.py, mesh_hang_watchdog.py, prepper_docs.py, Chart.js, schreiblast.py) - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  for pair in "$NEED_D:$F" "$NEED_FH:$FH" "$NEED_HW:$HW" "$NEED_P:$PD"; do
    [[ "${pair%%:*}" == 1 ]] || continue; x="${pair#*:}"
    cp -a "$x" "$x.bak-relhygiene-$TS"
    { ls -1t "$x.bak-relhygiene-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  mkdir -p "$DOCS" || { rb "docs/ nicht anlegbar"; exit 1; }
  [[ -d "$DASH_DIR/static" ]] || MK_STATIC=1; [[ -d "$DASH_DIR/static/vendor" ]] || MK_VENDOR=1; [[ -d "$DASH_DIR/tools" ]] || MK_TOOLS=1
  mkdir -p "$DASH_DIR/static/vendor" "$DASH_DIR/tools" || { rb "static/vendor oder tools nicht anlegbar"; exit 1; }
  inst() { cp "$1" "$2.new" && chmod --reference="$2.bak-relhygiene-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $(basename "$2")"; exit 1; }; }
  instn() { cp "$1" "$2.new" && chmod "$3" "$2.new" && mv -f "$2.new" "$2" || { rm -f "$2.new"; rb "installieren $(basename "$2")"; exit 1; }; }
  if [[ "$NEED_CH" == 1 ]]; then INST_CH=1; instn "$W/chart.js" "$CH" 644; fi
  if [[ "$NEED_SL" == 1 ]]; then INST_SL=1; instn "$RSL" "$SL" 755; fi
  [[ "$(sha256sum "$CH" | cut -d' ' -f1)" == "$CH_SHA" ]] || { rb "static/vendor/chart-4.4.1.min.js nach dem Kopieren falsch"; exit 1; }
  [[ "$NEED_P" == 1 ]] && inst "$W/work/prepper_docs.py" "$PD"
  [[ "$NEED_HW" == 1 ]] && inst "$W/work/mesh_hang_watchdog.py" "$HW"
  [[ "$NEED_FH" == 1 ]] && inst "$W/work/funk_health.py" "$FH"
  [[ "$NEED_D" == 1 ]] && inst "$W/work/dashboard.py" "$F"
  echo "OK Dateien atomar ersetzt (Sicherungen *.bak-relhygiene-$TS, behalten: letzte $KEEP_LAST); neu: static/vendor/chart-4.4.1.min.js (sha256 geprueft), tools/schreiblast.py"
  if [[ "$NEED_RESTART" == 1 ]]; then
    RESTARTED_D=1
    T0D=$(date +%s)
    echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'relHygiene aktiv' im Journal ..."
    sudo systemctl restart prepper-dashboard.service
    ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
    [[ "$ok" == 1 ]] || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
  else
    echo "Kein Dienst-Neustart noetig (dashboard.py/funk_health.py/Chart.js unveraendert)"
  fi
fi
PHASE=Pruefung
# Nach dem Neustart zeigt das Dashboard erst eine Startseite ("Dashboard startet"), bis das erste Voll-Update da ist; die Beschreibung soll ein fertig gestartetes Dashboard sehen
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
[[ "$NACH" == 0 ]] && echo "OK Beschreibung ohne Nachtrag (alles Gefundene ist redaktionell beschrieben)" || echo "HINWEIS Beschreibung enthaelt $NACH Nachtrag-Abschnitt(e) (nur Hinweis; Details im Kapitel Nachtrag der neuen Version; nichts davon stammt aus relHygiene)"
# ---------- 5) Rauchtest (nur GET auf lesende Seiten/APIs) ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist /karte /api/sdr/wd /api/sdr/ui /api/t2/status /api/t4/status /api/t4/tii /api/br24 /api/docs/list; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
# Chart.js lokal: Bytes, Kopfzeilen, bedingte Anfrage
"${CURL[@]}" -D "$W/ch.hdr" -o "$W/ch.body" "$B/static/vendor/chart-4.4.1.min.js" || true
python3 "$RHC" js "$W/ch.hdr" "$W/ch.body" > "$W/rc.log" 2>&1 && echo "OK $(cat "$W/rc.log")" || { cat "$W/rc.log"; rbx "Chart.js-Adresse liefert nicht die erwartete Datei"; }
"${CURL[@]}" -H "If-None-Match: \"${CH_SHA:0:32}\"" -D "$W/ch2.hdr" -o /dev/null "$B/static/vendor/chart-4.4.1.min.js" || true
python3 "$RHC" js304 "$W/ch2.hdr" > "$W/rc.log" 2>&1 && echo "OK $(cat "$W/rc.log")" || { cat "$W/rc.log"; rbx "Chart.js-Adresse: bedingte Anfrage"; }
# Seiten: lokale Chart.js eingebunden, keine externe Adresse (alle 26 Seiten/APIs ohne CDN)
NCH=0
for p in / /energie /lokale-energie /adsb /pegel /luft /funk; do
  c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"
  "${CURL[@]}" "$B$p" -o "$W/pg/c.html" || true
  python3 "$RHC" page "$W/pg/c.html" > "$W/rc.log" 2>&1 || { cat "$W/rc.log"; rbx "$p bindet die lokale Chart.js nicht ein"; }
  NCH=$((NCH + 1)); echo "OK $p: $(cat "$W/rc.log")"
done
DYN=0
for p in "${PAGES[@]}" "${APIS[@]}"; do
  "${CURL[@]}" -L --max-redirs 5 "$B$p" -o "$W/pg/p.html" || true
  if grep -q "stTileMsg" "$W/pg/p.html" 2>/dev/null; then python3 "$RHC" page "$W/pg/p.html" dyn > "$W/rc.log" 2>&1 && { DYN=$((DYN + 1)); echo "OK $p (Speedtest-Kachel): $(cat "$W/rc.log")"; } || { cat "$W/rc.log"; rbx "$p: dynamischer Chart.js-Lader nicht lokal"; }
  else python3 "$RHC" page "$W/pg/p.html" none > "$W/rc.log" 2>&1 || { cat "$W/rc.log"; rbx "$p enthaelt eine externe Chart.js-/CDN-Adresse"; }; fi
done
[[ "$DYN" -ge 1 ]] && echo "OK dynamischer Chart.js-Lader (Speedtest-Kachel) lokal auf $DYN Seite(n); 26 Seiten/APIs ohne externe Chart.js-Adresse" || echo "HINWEIS dynamischer Lader auf keiner der 26 Seiten gefunden (Kachel evtl. auf einer anderen Seite) - im Code geprueft (AST-Guard)"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x doPrepperRestore wie vorher)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$PCK" pi "$W/pi.html" "$DOCS" > "$W/pi.log" 2>&1 && echo "OK $(cat "$W/pi.log") (Sicherung = vorletzte, Projektbeschreibung = letzte Kachel)" || { cat "$W/pi.log"; rbx "/pi: Kachel Projektbeschreibung Lage Pi / Reihenfolge"; }
"${CURL[@]}" "$B/api/docs/list" -o "$W/dl_list.json" || true
python3 "$PCK" list "$W/dl_list.json" "$DOCS" > "$W/pl.log" 2>&1 && echo "OK $(cat "$W/pl.log")" || { cat "$W/pl.log"; rbx "/api/docs/list"; }
for fmt in txt md; do
  for v in "" "$(python3 -c "import json;print(json.load(open('$W/dl_list.json'))['current'])")"; do
    curl -s --connect-timeout 3 --max-time 40 -D "$W/dl.hdr" -o "$W/dl.body" "$B/api/docs/download?fmt=$fmt&v=$v" || true
    python3 "$PCK" dl "$W/dl.hdr" "$W/dl.body" "$DOCS" "$v" "$fmt" > "$W/pdl.log" 2>&1 && echo "OK $(cat "$W/pdl.log")$([[ -z "$v" ]] && echo " (ohne Versionsangabe = neueste)")" || { cat "$W/pdl.log"; rbx "/api/docs/download fmt=$fmt v=$v"; }
  done
done
"${CURL[@]}" "$B/api/docs/routes" -o "$W/dr.json" || true
python3 "$PCK" routes "$W/dr.json" "${PAGES[@]}" "${APIS[@]}" /api/docs/list /api/docs/download /api/docs/routes /api/meshpost/status /static/vendor/chart-4.4.1.min.js > "$W/pr.log" 2>&1 && echo "OK $(cat "$W/pr.log")" || { cat "$W/pr.log"; rbx "/api/docs/routes"; }
# absichtlicher 404: Fehlerzeilen muessen im Journal sichtbar bleiben, 2xx/3xx nicht
PROBE="/api/rh-probe-gibt-es-nicht"
c404=$(code "$B$PROBE"); [[ "$c404" == 404 ]] || rbx "Probe-Adresse $PROBE antwortet $c404 statt 404"
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | wc -l"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "relHygiene aktiv: relHygiene ok" | tail -1 || true)
    [[ -n "$JA" && "$JA" == *"Chart.js 4.4.1 lokal ok"* ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-260)" || rbx "Journal prepper-dashboard ohne 'relHygiene aktiv: relHygiene ok (... Chart.js 4.4.1 lokal ok ...)' ($(echo "$JA" | cut -c1-200))"
  fi
  python3 "$RHC" journal "$W/jd.txt" "$PROBE" > "$W/rj.log" 2>&1 && echo "OK $(cat "$W/rj.log")" || { cat "$W/rj.log"; rbx "Journal: Zugriffsprotokoll nicht wie erwartet"; }
  E2=$(echo "$JD" | grep -c -E 'Traceback|relHygiene FEHLER|relHygiene: lokale Chart.js fehlt|projDoc (FEHLER|Liste:|Download:|/pi:)|funkUI FEHLER' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/relHygiene-Fehler" || { echo "$JD" | grep -E 'Traceback|relHygiene FEHLER|relHygiene: lokale Chart.js fehlt|projDoc' | head -5 | cut -c1-240; rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"; }
  JB1=$(echo "$JD" | wc -l)
  echo "   Journal seit Neustart: $JB1 Zeilen (vorher in 10 min: ${JB0:-0} Zeilen, davon Zugriffszeilen ${JA0:-0})"
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)"); prepper-sdr, mesh-bridge, Timer unveraendert"
for x in "$DBF:$DB16" "$MR:$MR16" "$M:$SDR16" "$SMF:$SM16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ "$(s16 "$CF")" == "$CF16" ]] && echo "OK sdr_config.json unveraendert ($CF16)" || echo "HINWEIS sdr_config.json hat sich im Betrieb geaendert (nicht durch diesen Patch)"
CNT=$(grep -c '# ===== relHygiene:' "$F" || true); NCDN=$(cat "$F" "$FH" | grep -c -E 'jsdelivr|unpkg|cdnjs|chart\.js@' || true)
[[ "$CNT" == 1 && "$NCDN" == 0 ]] && echo "OK guards relHygiene(dash)=$CNT, externe Chart.js-Adressen in dashboard.py/funk_health.py=$NCDN" || rbx "Marker relHygiene=$CNT oder externe Chart.js-Adressen=$NCDN"
"$SPY" -W error -m py_compile "$HW" 2>"$W/pyc.log" && echo "OK mesh_hang_watchdog.py installiert und kompiliert (Rotation gilt ab dem naechsten Timer-Lauf; aktuelles Protokoll: $(ls -l "$DASH_DIR/mesh_hang_watchdog.log" 2>/dev/null | awk '{print $5}') Bytes, Grenze 1048576)" || { cat "$W/pyc.log"; rbx "mesh_hang_watchdog.py kompiliert nicht"; }
echo "--- Schreiblast-Hilfe (nur lesend, 3 s Messfenster, nichts geaendert):"
PRSL_SUDO=1 python3 "$SL" 3 > "$W/sl.out" 2>&1 && sed -n '1,14p' "$W/sl.out" | cut -c1-200 | sed 's/^/   /' || { tail -5 "$W/sl.out" | cut -c1-200; echo "HINWEIS tools/schreiblast.py meldet einen Fehler (nur Hilfsprogramm, Betrieb nicht betroffen)"; }
JU=$(jc --disk-usage 2>/dev/null | head -1 || true); [[ -n "$JU" ]] && echo "Journal Platzbedarf: $JU"
echo "OK Datenbank, Alarm-, Sende- und Abruflogik, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-relhygiene-$TS" || -f "$FH.bak-relhygiene-$TS" || -f "$HW.bak-relhygiene-$TS" || -f "$PD.bak-relhygiene-$TS" ]] && echo "Backups: *.bak-relhygiene-$TS (nur geaenderte Dateien: dashboard.py, funk_health.py, mesh_hang_watchdog.py, prepper_docs.py), behalten: letzte $KEEP_LAST je Datei; keine SQLite-Sicherung (Datenbank unberuehrt)"
for x in "$F" "$PD" "$FH" "$HW" "$CH" "$SL"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -c < "$x") Bytes, $(wc -l < "$x") Zeilen"; done
VNEW=$(python3 -c "import json;print(json.load(open('$W/dl_list.json'))['current'])")
echo "docs/ (neueste Version v$VNEW; aeltere Versionen bleiben):"
for x in "$DOCS/Projektbeschreibung Lage Pi v$VNEW.txt" "$DOCS/Projektbeschreibung Lage Pi v$VNEW.md"; do echo "  $(basename "$x") sha256 $(sha256sum "$x" | cut -d' ' -f1), $(wc -c < "$x") Bytes, $(wc -l < "$x") Zeilen"; done
if [[ -f "$F.bak-relhygiene-$TS" || -f "$FH.bak-relhygiene-$TS" ]]; then echo "Rueckweg: geaenderte Dateien aus *.bak-relhygiene-$TS zurueckkopieren (dashboard.py, funk_health.py, mesh_hang_watchdog.py, prepper_docs.py), static/vendor/chart-4.4.1.min.js und tools/schreiblast.py koennen bleiben oder geloescht werden, dann sudo systemctl restart prepper-dashboard"
else LB=$({ ls -1t "$F.bak-relhygiene-"* 2>/dev/null || true; } | head -1); [[ -n "$LB" ]] && echo "Rueckweg (neueste Sicherung: $(basename "$LB")): geaenderte Dateien zurueckkopieren, dann prepper-dashboard neu starten" || echo "Rueckweg: keine relHygiene-Sicherung vorhanden (nichts geaendert)"; fi
echo "Neue Version spaeter: cd $DASH_DIR && python3 prepper_docs.py (erzeugt nur bei geaendertem Stand eine neue Version, --force erzwingt, behaelt die letzten 10)"
echo "Pruefen (nur lesend): python3 $SL 20 | curl -sI $B/static/vendor/chart-4.4.1.min.js | sudo journalctl -u prepper-dashboard --since -10min --no-pager | wc -l"
echo "REL-04: Zugriffsprotokoll nur noch Fehler (4xx hoechstens 60/min, 5xx immer), mesh_hang_watchdog.log ab 1 MB rotiert (.1 bis .3), Journal-Limit vorhanden/gemeldet, logrotate nicht noetig. REL-09: Chart.js 4.4.1 lokal, ruhiger Hinweis statt JS-Fehler wenn die Datei fehlt. Nichts gesendet (kein Mesh, kein Telegram, keine Alarme)."
echo "COMMIT $COMMIT_ARG relhygiene=1 fertig"
