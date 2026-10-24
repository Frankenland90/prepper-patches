#!/bin/bash
set -euo pipefail
# relBackup (commit18): tools/backup.sh und tools/restore.sh korrigiert (REL-03 des Audits). Aendert KEINE Python-Datei, keine Konfiguration, startet KEINEN Dienst neu.
#  - backup.sh: tar-Ausschluesse wirksam (relativ zu -C: venv, __pycache__, backups, *.zim, *.bak-*, Live-DB samt -wal/-shm), lagezentrum.db konsistent per sqlite3-Backup-API
#    (quick_check der Kopie und der Kopie im Archiv), Archiv 600 / Ordner 700, tar-Exit >= 2 = Fehler, Pruefsumme + Pruefergebnisse in der .json (neue Zusatzfelder),
#    eindeutige Namen, Exit-Code ehrlich, Rotation (10) mit Schutz des gerade wiederhergestellten Archivs. Namensschema und Dashboard-Felder bleiben.
#  - restore.sh: koppelt sich aus der Control-Group des Dashboards ab (eigene transiente Einheit prepper-restore: root -> Benutzer-Manager -> sudo-Regel), prueft das Archiv
#    (sha256, gzip, tar-Liste, Pfade), entpackt VOR dem Stopp in einen Arbeitsordner und prueft Code (py_compile System- und venv-Python) und DB (quick_check), sichert den
#    Ist-Zustand, stoppt den Dienst (systemctl -> sudo -n -> SIGTERM bei Restart=always), tauscht den Ordner per zwei mv, startet, prueft Gesundheit, faellt sonst zurueck.
#    --dry-run stoppt/tauscht/sichert nichts. Aufruf aus dem Dashboard ("restore.sh <id>") bleibt unveraendert.
# Basis streng (sha16): backup.sh 724a7e4beb218d04, restore.sh 04da8489c6e6ecb6 (oder schon die neue Fassung = idempotent). Anderes = STOP mit Diff, nichts geaendert.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
DASH_DIR="/home/fmg/prepper-dashboard"
DEST="/home/fmg/prepper-backups"
if [[ "${RELBACKUP_TEST:-}" == 1 ]]; then DASH_DIR="${RB_DASH:-$DASH_DIR}"; DEST="${RB_DEST:-$DEST}"; fi   # nur fuer den Sandbox-Test des Apply-Skripts
TOOLS="$DASH_DIR/tools"
BF="$TOOLS/backup.sh"
RF="$TOOLS/restore.sh"
LZ="$DASH_DIR/lagezentrum.db"
TS=$(date +%Y%m%d-%H%M%S)
KEEP_LAST=3
W=/tmp/relbackup-apply
KNOWN_BASE_B16="724a7e4beb218d04"
KNOWN_BASE_R16="04da8489c6e6ecb6"
NEW_B16="5053f6b8a43a8638"
NEW_R16="a978ff684d92c619"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
echo "=== relBackup apply ($COMMIT_ARG): tools/backup.sh + tools/restore.sh (keine Python-Datei, kein Dienstneustart), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/new/fake" "$W/base" "$W/st"
EXPECT_backup="5053f6b8a43a8638b27eb9fc578d4170c5d211996e244e820ea7725b11d55f82"
mkdir -p "$W/new"
cat > "$W/new/backup.sh" << 'RB_BACKUP_EOF'
#!/bin/bash
# tools/backup.sh (relBackup): Sicherung des Projektordners nach /home/fmg/prepper-backups
# Aufruf: backup.sh [M|A] [Label]   (Dashboard-Knopf: M + Label; Zeitplan: A)  - Namensschema und .json wie bisher
# Ausgabe: eine Zeile "OK ..." bzw. "FAIL ... err=..."; Exit 0 = Archiv geprueft und fertig, 1 = Fehler (ehrlich weitergegeben)
# - Ausschluesse gelten relativ zu -C (venv, __pycache__, *.pyc, backups, *.zim, *.bak-*, *.bak, live-DB samt -wal/-shm/-journal)
# - SQLite-Datenbanken (Kopf "SQLite format 3") werden ueber die sqlite3-Backup-API kopiert (konsistent, auch im laufenden Betrieb) und
#   die Kopie mit PRAGMA quick_check geprueft; ins Archiv kommt nur die Kopie, nie die laufende Datei
# - config.py, secrets/, Zustands-JSONs, archive/, stick3-eeprom-Abbilder bleiben im Archiv (fuer eine Wiederherstellung noetig); Archiv 600, Ordner 700
# - Archiv wird als .part geschrieben, mit gzip/tar-Liste, Pflichtdateien und DB-Kopie aus dem Archiv geprueft und erst dann umbenannt;
#   sha256 + Pruefergebnisse stehen in der .json (Zusatzfelder, Dashboard liest nur die alten)
# - tar-Exit 1 (Datei waehrend des Packens geaendert) = Warnung, Exit >= 2 = Fehler
# - Rotation: neueste 10 Sicherungen (je Name mit .tgz/.json), das Archiv das gerade wiederhergestellt wird (PREPPER_BACKUP_PROTECT) und die neueste gute bleiben immer
set -u
umask 077
export LC_ALL=C

APP="/home/fmg/prepper-dashboard"
DEST="/home/fmg/prepper-backups"
KEEP=10
MINFREE_KB=307200
if [[ "${PREPPER_SELFTEST:-}" == "1" ]]; then
  APP="${PREPPER_APP:-$APP}"; DEST="${PREPPER_BACKUPS:-$DEST}"; KEEP="${PREPPER_KEEP:-$KEEP}"; MINFREE_KB="${PREPPER_MINFREE_KB:-$MINFREE_KB}"
  TAR="${PREPPER_TAR:-tar}"; PY="${PREPPER_PY:-python3}"
else
  TAR=tar; PY=python3
fi
AB="$(basename "$APP")"
PARENT="$(dirname "$APP")"

MODE="${1:-A}"
[[ "$MODE" == "M" || "$MODE" == "A" ]] || MODE="A"
RAW_LABEL="${2:-}"
LABEL="$(printf '%s' "$RAW_LABEL" | tr -cd 'A-Za-z0-9_-' | cut -c1-40)"
if [[ -z "$LABEL" ]]; then
  if [[ "$MODE" == "A" ]]; then LABEL="auto"; else LABEL="manual"; fi
fi
PROTECT="$(printf '%s' "${PREPPER_BACKUP_PROTECT:-}" | tr -cd 'A-Za-z0-9-')"

set_names() {
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BASE="prepper-${STAMP}-${MODE}"
  FILE="${DEST}/${BASE}.tgz"
  PART="${DEST}/.${BASE}.tgz.part"
  META="${DEST}/${BASE}.json"
}
set_names
OK=0; ERR=""; DETAIL=""; HASH=""; SHA=""; MEMBERS=0; TARRC=""; WARN=""; DBINFO=""
STAGE=""

cleanup() { [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"; rm -f "$PART" 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'ERR="signal"; DETAIL="Abbruch durch Signal"; exit 1' INT TERM HUP

finish_fail() { ERR="$1"; DETAIL="$2"; OK=0; rm -f "$PART" "$FILE" 2>/dev/null; }

mkdir -p "$DEST" 2>/dev/null
chmod 700 "$DEST" 2>/dev/null

step_run() {
  [[ -d "$APP" ]] || { finish_fail "app" "Projektordner fehlt: $APP"; return 1; }
  [[ -w "$DEST" ]] || { finish_fail "dest" "Sicherungsordner nicht beschreibbar: $DEST"; return 1; }
  # nicht waehrend einer Wiederherstellung sichern (App-Ordner wird dabei ausgetauscht); die Sicherung VOR der Wiederherstellung kommt aus restore.sh selbst
  if [[ "${PREPPER_BACKUP_INTERNAL:-}" != "1" ]] && command -v flock >/dev/null 2>&1; then
    if ! ( flock -n 7 ) 7>"$DEST/.restore.lock" 2>/dev/null; then finish_fail "restore-running" "Wiederherstellung laeuft - keine Sicherung"; return 1; fi
  fi
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$DEST/.backup.lock"
    flock -w 120 8 || { finish_fail "busy" "andere Sicherung laeuft (120 s gewartet)"; return 1; }
  fi
  # Name eindeutig machen: nie ein bestehendes Archiv/.json ueberschreiben (z. B. zwei Sicherungen in derselben Sekunde)
  local tries=0
  set_names
  while [[ -e "$FILE" || -e "$META" ]]; do
    tries=$((tries+1)); (( tries > 5 )) && { finish_fail "name" "Name $BASE schon vergeben"; return 1; }
    sleep 1; set_names
  done
  local free
  free="$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ "$free" =~ ^[0-9]+$ ]] && (( free < MINFREE_KB )); then finish_fail "space" "nur $((free/1024)) MB frei in $DEST (Minimum $((MINFREE_KB/1024)) MB)"; return 1; fi
  STAGE="$(mktemp -d "$DEST/.stage.XXXXXX" 2>/dev/null)" || { finish_fail "stage" "Arbeitsordner nicht anlegbar"; return 1; }
  mkdir -p "$STAGE/snapdb"

  # 1) SQLite-Datenbanken im Projektordner (nur oberste Ebene) konsistent kopieren
  local dbs=() f hdr
  shopt -s nullglob
  for f in "$APP"/*.db; do
    [[ -f "$f" && -s "$f" ]] || continue
    hdr="$(head -c 15 "$f" 2>/dev/null | tr -d '\0')"
    [[ "$hdr" == "SQLite format 3" ]] && dbs+=("$(basename "$f")")
  done
  shopt -u nullglob
  local EXCL=(--exclude="$AB/venv" --exclude="$AB/backups" --exclude="__pycache__" --exclude="*.pyc" --exclude="*.zim" --exclude="*.bak-*" --exclude="*.bak")
  local d
  for d in "${dbs[@]}"; do
    EXCL+=(--exclude="$AB/$d" --exclude="$AB/$d-wal" --exclude="$AB/$d-shm" --exclude="$AB/$d-journal")
  done
  DBINFO="[]"
  if (( ${#dbs[@]} > 0 )); then
    DBINFO="$("$PY" - "$APP" "$STAGE/snapdb" "${dbs[@]}" 2> "$STAGE/db.err" << 'PYDB'
import json, os, sqlite3, sys
app, out, names = sys.argv[1], sys.argv[2], sys.argv[3:]
res = []
for n in names:
    src = dst = None
    try:
        src = sqlite3.connect(os.path.join(app, n), timeout=30)
        dst = sqlite3.connect(os.path.join(out, n))
        src.backup(dst)          # sqlite3-Backup-API: konsistente Kopie
        dst.commit()
        qc = [r[0] for r in dst.execute("PRAGMA quick_check").fetchall()]
        ok = qc == ["ok"]
        res.append({"name": n, "quick_check": "ok" if ok else (qc[0] if qc else "leer")[:80], "bytes": os.path.getsize(os.path.join(out, n))})
        if not ok:
            print(json.dumps(res)); sys.exit(3)
    except Exception as e:
        print(json.dumps(res + [{"name": n, "quick_check": "Fehler: " + str(e)[:80]}])); sys.exit(2)
    finally:
        for c in (dst, src):
            try:
                c and c.close()
            except Exception:
                pass
print(json.dumps(res))
PYDB
    )"; local drc=$?
    if (( drc != 0 )); then
      [[ -n "$DBINFO" ]] || DBINFO="[]"
      finish_fail "db" "SQLite-Kopie fehlgeschlagen (rc $drc): $(head -c 160 "$STAGE/db.err" 2>/dev/null | tr '\n' ' ')$DBINFO"
      return 1
    fi
  fi

  # 2) packen: Projektordner ohne Ausschluesse + DB-Kopien (per --transform an den Platz der Originale)
  local ARGS=(-czf "$PART" --warning=no-file-changed "${EXCL[@]}")
  if (( ${#dbs[@]} > 0 )); then ARGS+=(--transform="s,^snapdb/,$AB/,"); fi
  ARGS+=(-C "$PARENT" "$AB")
  for d in "${dbs[@]}"; do ARGS+=(-C "$STAGE" "snapdb/$d"); done
  "$TAR" "${ARGS[@]}" 2> "$STAGE/tar.err"
  TARRC=$?
  if (( TARRC == 1 )); then WARN="tar rc 1: Datei beim Packen geaendert (Archiv trotzdem geprueft)"
  elif (( TARRC >= 2 )); then
    cp -f "$STAGE/tar.err" "$DEST/backup.err" 2>/dev/null; chmod 600 "$DEST/backup.err" 2>/dev/null
    finish_fail "tar" "tar rc $TARRC: $(head -c 160 "$STAGE/tar.err" 2>/dev/null | tr '\n' ' ')"; return 1
  fi

  # 3) pruefen: gzip, vollstaendige tar-Liste, Pflichtdateien, DB-Kopie aus dem Archiv
  [[ -s "$PART" ]] || { finish_fail "verify" "Archiv leer"; return 1; }
  gzip -t "$PART" 2>"$STAGE/gz.err" || { finish_fail "verify" "gzip -t: $(head -c 120 "$STAGE/gz.err" | tr '\n' ' ')"; return 1; }
  "$TAR" -tzf "$PART" > "$STAGE/list.txt" 2>"$STAGE/tl.err" || { finish_fail "verify" "tar -t: $(head -c 120 "$STAGE/tl.err" | tr '\n' ' ')"; return 1; }
  MEMBERS="$(wc -l < "$STAGE/list.txt")"
  grep -qx "$AB/dashboard.py" "$STAGE/list.txt" || { finish_fail "verify" "dashboard.py fehlt im Archiv"; return 1; }
  for d in "${dbs[@]}"; do
    grep -qx "$AB/$d" "$STAGE/list.txt" || { finish_fail "verify" "$d fehlt im Archiv"; return 1; }
    [[ "$(grep -cx "$AB/$d" "$STAGE/list.txt")" == "1" ]] || { finish_fail "verify" "$d mehrfach im Archiv"; return 1; }
    mkdir -p "$STAGE/chk"
    "$TAR" -xzf "$PART" -C "$STAGE/chk" "$AB/$d" 2>/dev/null || { finish_fail "verify" "$d nicht aus dem Archiv lesbar"; return 1; }
    "$PY" - "$STAGE/chk/$AB/$d" << 'PYQ' || { finish_fail "verify" "quick_check der DB-Kopie im Archiv ($d) fehlgeschlagen"; return 1; }
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); r = [x[0] for x in c.execute("PRAGMA quick_check").fetchall()]; c.close()
sys.exit(0 if r == ["ok"] else 1)
PYQ
    rm -rf "$STAGE/chk"
  done
  # live-DB-Dateien duerfen nicht (roh) im Archiv stehen
  if grep -E "^$AB/[^/]+\.db-(wal|shm|journal)$" "$STAGE/list.txt" | grep -q .; then finish_fail "verify" "rohe -wal/-shm Datei im Archiv"; return 1; fi
  if grep -qE "^$AB/venv/|/__pycache__/" "$STAGE/list.txt"; then finish_fail "verify" "Ausschluss unwirksam (venv/__pycache__ im Archiv)"; return 1; fi
  SHA="$(sha256sum "$PART" | awk '{print $1}')"
  mv -f "$PART" "$FILE" || { finish_fail "move" "Archiv nicht umbenennbar"; return 1; }
  chmod 600 "$FILE" 2>/dev/null
  HASH="$(sha256sum "$APP/dashboard.py" 2>/dev/null | awk '{print substr($1,1,12)}')"
  OK=1
  return 0
}

step_run || true

"$PY" - "$META" "$FILE" "$MODE" "$OK" "$ERR" "$LABEL" "$HASH" "$BASE" "$SHA" "$MEMBERS" "$TARRC" "$WARN" "$DETAIL" "$DBINFO" << 'PY'
import json, os, sys, datetime
meta, file, mode, ok, err, label, hash_, base, sha, members, tarrc, warn, detail, dbinfo = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1",
    sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9], sys.argv[10], sys.argv[11], sys.argv[12], sys.argv[13], sys.argv[14],
)
now = datetime.datetime.now()
wd = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][now.weekday()]
try:
    db = json.loads(dbinfo or "[]")
except Exception:
    db = []
d = {
    "ok": ok,
    "mode": mode,
    "err": err or None,
    "file": os.path.basename(file) if os.path.exists(file) else None,
    "bytes": os.path.getsize(file) if os.path.exists(file) else 0,
    "at": now.strftime("%d.%m.%Y %H:%M:%S"),
    "wd": wd,
    "iso": now.isoformat(timespec="seconds"),
    "label": label or None,
    "hash": hash_ or None,
    "id": base,
    "sha256": sha or None,
    "members": int(members) if members.isdigit() else None,
    "tar_rc": int(tarrc) if tarrc.isdigit() else None,
    "db": db,
    "warn": warn or None,
    "detail": detail[:300] or None,
    "tool": "relBackup",
}
tmp = meta + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
os.chmod(tmp, 0o600)
os.replace(tmp, meta)
if ok:
    print("OK " + d["at"] + " " + mode + " label=" + (label or "-") + " hash=" + (hash_ or "????") + " sha256=" + sha[:12] + " " + str(d["bytes"]) + " Bytes db=" + str(len(db)) + (" WARN " + warn if warn else ""))
else:
    print("FAIL " + d["at"] + " " + mode + " err=" + (err or "?") + ((" " + detail[:200]) if detail else ""))
PY
PYRC=$?

# Rotation: neueste $KEEP Sicherungen behalten (nach Namen/Zeitstempel); geschuetzt: PREPPER_BACKUP_PROTECT und die neueste gute
if [[ -d "$DEST" ]]; then
  "$PY" - "$DEST" "$KEEP" "$PROTECT" << 'PYROT' || true
import json, os, re, sys
dest, keep, protect = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rx = re.compile(r"^(prepper-\d{8}-\d{6}-[MA])\.(tgz|json)$")
ids = {}
for n in os.listdir(dest):
    m = rx.match(n)
    if m:
        ids.setdefault(m.group(1), []).append(n)
order = sorted(ids, reverse=True)
def good(i):
    p = os.path.join(dest, i + ".json")
    try:
        d = json.load(open(p))
    except Exception:
        d = None
    has_tgz = os.path.exists(os.path.join(dest, i + ".tgz"))
    return has_tgz and (d is None or d.get("ok") is True)   # Altbestand ohne json gilt als gut, wenn das Archiv da ist
keepset = set(order[:keep])
if protect:
    keepset.add(protect)
for i in order:
    if good(i):
        keepset.add(i)
        break
for i in order:
    if i in keepset:
        continue
    for n in ids[i]:
        try:
            os.remove(os.path.join(dest, n))
        except FileNotFoundError:
            pass
for n in os.listdir(dest):
    if n.startswith("prepper-") and (n.endswith(".tgz") or n.endswith(".json")):
        try:
            os.chmod(os.path.join(dest, n), 0o600)
        except OSError:
            pass
PYROT
fi
# alte Arbeitsordner/.part-Reste (Absturz) aufraeumen, nicht den eigenen
find "$DEST" -maxdepth 1 \( -name '.stage.*' -o -name '.prepper-*.tgz.part' \) -mmin +120 -exec rm -rf {} + 2>/dev/null || true

if [[ "$OK" -eq 1 && "$PYRC" -eq 0 ]]; then
  exit 0
fi
exit 1
RB_BACKUP_EOF
EXPECT_restore="a978ff684d92c6191595348f63f7f9751138cb19e7e75e8755f2ee0f666144a1"
mkdir -p "$W/new"
cat > "$W/new/restore.sh" << 'RB_RESTORE_EOF'
#!/bin/bash
# tools/restore.sh (relBackup): Wiederherstellung einer Sicherung aus /home/fmg/prepper-backups
# Aufruf:  restore.sh [--dry-run] [--foreground] prepper-YYYYMMDD-HHMMSS-[MA]
#   (Dashboard-Knopf ruft nur "restore.sh <id>" auf; Ausgabe: letzte Zeile, Exit 0 = Wiederherstellung gestartet bzw. (im Vordergrund) fertig und gesund)
# --dry-run     prueft Archiv, entpackt in einen Arbeitsordner, prueft Code/DB und meldet, welche Wege (Abkopplung, Stopp) moeglich waeren;
#               stoppt NICHTS, tauscht NICHTS, legt keine Sicherung an (Arbeitsordner wird wieder geloescht)
# --foreground  nicht abkoppeln (nur fuer Tests/SSH); ohne diesen Schalter koppelt sich das Skript aus der Control-Group des Dashboards ab
# Warum abkoppeln: Das Dashboard startet dieses Skript als Kindprozess. "systemctl stop prepper-dashboard" beendet bei KillMode=control-group
#   ALLE Prozesse der Einheit, auch dieses Skript, mitten in der Wiederherstellung. Deshalb startet das Skript sich in einer eigenen transienten
#   systemd-Einheit (prepper-restore) ausserhalb der Dashboard-Control-Group: root -> systemd-run; sonst Benutzer-Manager (systemd-run --user);
#   sonst sudo -n systemd-run (nur wenn eine sudo-Regel das erlaubt). Geht nichts davon: Abbruch VOR jeder Aenderung (Exit 3).
# Ablauf (in der eigenen Einheit): Archiv pruefen (sha256 aus .json, gzip, tar-Liste, Pfade) -> in Arbeitsordner entpacken, Code (py_compile mit
#   System-Python und venv, ohne Bytecode zu schreiben) und DB (quick_check) pruefen, venv/*.zim/*.bak-* per Hardlink uebernehmen (diese sind nicht
#   im Archiv) -> Sicherung des aktuellen Zustands (backup.sh M pre-restore; bei defekter DB nur Warnung, der alte Ordner bleibt als .bak-restore-*)
#   -> Dienst stoppen -> Ordner tauschen (zwei mv) -> starten -> Gesundheitspruefung (aktiv, neuer Prozess, HTTP 200 stabil)
#   -> bei Fehler automatischer Rueckfall auf den alten Ordner.
# Dienst stoppen: systemctl (root/Polkit) -> sudo -n systemctl (sudo-Regel) -> sudo mit Passwort (nur mit Terminal) -> SIGTERM an den Hauptprozess
#   (nur wenn Restart=always/on-success: systemd startet danach selbst neu; der Tausch geschieht dazwischen).
# Protokoll: /home/fmg/prepper-backups/restore.log, Zustand: restore-status.json (state running|ok|rolled-back|failed, step, reason).
# Exit: 0 ok | 1 Fehler, alter Stand ist (wieder) aktiv | 2 Fehler, Eingriff noetig (siehe Protokoll) | 3 nicht gestartet (nichts geaendert) | 4 Aufruf falsch
set -u
umask 077
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd / || exit 4

APP="/home/fmg/prepper-dashboard"
DEST="/home/fmg/prepper-backups"
SVC="prepper-dashboard"
UNIT="prepper-restore"
HEALTH_S=120
SYSTEMCTL=systemctl; SYSTEMD_RUN=systemd-run; SUDO=sudo; CURL=curl; TAR=tar; PY=python3
CGROUP_FILE=/proc/self/cgroup
KILL_WAIT_S=100
RESTART_WAIT_S=90
STAB_S=6
if [[ "${PREPPER_SELFTEST:-}" == "1" ]]; then
  APP="${PREPPER_APP:-$APP}"; DEST="${PREPPER_BACKUPS:-$DEST}"; SVC="${PREPPER_SVC:-$SVC}"; UNIT="${PREPPER_UNIT:-$UNIT}"
  HEALTH_S="${PREPPER_HEALTH_S:-$HEALTH_S}"; SYSTEMCTL="${PREPPER_SYSTEMCTL:-$SYSTEMCTL}"; SYSTEMD_RUN="${PREPPER_SYSTEMD_RUN:-$SYSTEMD_RUN}"
  SUDO="${PREPPER_SUDO:-$SUDO}"; CURL="${PREPPER_CURL:-$CURL}"; TAR="${PREPPER_TAR:-$TAR}"; PY="${PREPPER_PY:-$PY}"
  CGROUP_FILE="${PREPPER_CGROUP_FILE:-$CGROUP_FILE}"; KILL_WAIT_S="${PREPPER_KILL_WAIT_S:-$KILL_WAIT_S}"; RESTART_WAIT_S="${PREPPER_RESTART_WAIT_S:-$RESTART_WAIT_S}"
  STAB_S="${PREPPER_STAB_S:-$STAB_S}"
fi
AB="$(basename "$APP")"
PARENT="$(dirname "$APP")"
LOG="$DEST/restore.log"
STATUS="$DEST/restore-status.json"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

DRY=0; FG=0; ID=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --foreground) FG=1 ;;
    --detached) ;;
    -*) echo "ERR: unbekannter Schalter $a (restore.sh [--dry-run] [--foreground] <id>)" >&2; exit 4 ;;
    *) [[ -z "$ID" ]] && ID="$a" || { echo "ERR: nur eine id erlaubt" >&2; exit 4; } ;;
  esac
done
DETACHED="${PREPPER_RESTORE_DETACHED:-0}"
RUNID="${PREPPER_RESTORE_RUNID:-$(date +%s)-$$}"
[[ -n "$ID" ]] || { echo "ERR: usage: restore.sh [--dry-run] <id>  (e.g. prepper-20260920-140458-M)" >&2; exit 4; }
[[ "$ID" =~ ^prepper-[0-9]{8}-[0-9]{6}-[MA]$ ]] || { echo "ERR: invalid id: $ID" >&2; exit 4; }
TGZ="$DEST/$ID.tgz"
JSN="$DEST/$ID.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="${APP}.bak-restore-${STAMP}"
FAILED_DIR="${APP}.failed-restore-${STAMP}"
STAGE=""
STEP="start"
DOWN=0; DONE=0; SWAPPED=0; METHOD=""; OLDPID=0; SAFETY_ID=""; NOSTATUS=0
PORT_CFG="$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$APP/config.py" 2>/dev/null | head -1)"
PORT="${PREPPER_PORT:-${PORT_CFG:-5000}}"
[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=5000

log() {
  local m
  m="[$(date +%H:%M:%S)] $*"
  echo "$m"
  if [[ "$DRY" == 0 && -d "$DEST" ]]; then echo "$m" >> "$LOG" 2>/dev/null; fi
  return 0
}
status() {   # status <state> <reason>
  [[ "$DRY" == 0 && "$NOSTATUS" == 0 && -d "$DEST" ]] || return 0
  "$PY" - "$STATUS" "$ID" "$1" "$STEP" "${2:-}" "$RUNID" "$SAFETY_ID" "$BAK" "$LOG" "$METHOD" << 'PYS' 2>/dev/null || true
import json, os, sys, datetime
p, i, state, step, reason, run, safety, bak, log, method = sys.argv[1:11]
d = {"id": i, "state": state, "step": step, "reason": reason[:300] or None, "run": run, "safety_backup": safety or None,
     "old_dir": os.path.basename(bak), "log": log, "stop_method": method or None,
     "at": datetime.datetime.now().isoformat(timespec="seconds")}
t = p + ".tmp"
open(t, "w").write(json.dumps(d))
os.chmod(t, 0o600)
os.replace(t, p)
PYS
  return 0
}
die() {  # vor jeder Aenderung des Dienstes/Ordners: Exit 1
  log "FEHLER ($STEP): $*"; status failed "$*"; DONE=1; echo "ERR: $*" >&2; exit 1
}

SC() { "$SYSTEMCTL" --no-ask-password "$@"; }
svc_active() { [[ "$(SC is-active "$SVC" 2>/dev/null)" == active ]]; }
svc_mainpid() { local p; p="$(SC show -p MainPID --value "$SVC" 2>/dev/null)"; [[ "$p" =~ ^[0-9]+$ ]] || p=0; echo "$p"; }
pid_alive() { [[ "${1:-0}" -gt 0 ]] && kill -0 "$1" 2>/dev/null; }
restart_policy() { SC show -p Restart --value "$SVC" 2>/dev/null; }

in_dash_cgroup() { grep -q "${SVC}\.service" "$CGROUP_FILE" 2>/dev/null; }

# ---------------------------------------------------------------- Phase A: Archiv pruefen (keine Aenderung)
check_archive() {
  STEP="archiv-pruefen"
  [[ -f "$TGZ" && ! -L "$TGZ" ]] || die "Archiv fehlt oder ist ein Link: $TGZ"
  [[ -s "$TGZ" ]] || die "Archiv leer: $TGZ"
  if [[ -f "$JSN" ]]; then
    local jr
    jr="$("$PY" - "$JSN" "$TGZ" << 'PYJ' 2>&1
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
if d.get("ok") is False:
    print("BAD Sicherung war als fehlgeschlagen markiert (err=%s)" % d.get("err")); sys.exit(1)
want = d.get("sha256")
if not want:
    print("LEGACY ohne Pruefsumme (Altbestand): nur gzip/tar-Test"); sys.exit(0)
h = hashlib.sha256()
with open(sys.argv[2], "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""):
        h.update(b)
if h.hexdigest() != want:
    print("BAD sha256 stimmt nicht (Datei veraendert oder beschaedigt)"); sys.exit(1)
print("OK sha256 stimmt mit .json ueberein")
PYJ
    )" || die "${jr#BAD }"
    log "Archiv: ${jr#OK }"
  else
    log "Archiv: keine .json gefunden - nur gzip/tar-Test"
  fi
  gzip -t "$TGZ" 2>/dev/null || die "gzip -t fehlgeschlagen fuer $TGZ"
  local LST; LST="$(mktemp)" || die "temp"
  if ! "$TAR" -tzf "$TGZ" > "$LST" 2>/dev/null; then rm -f "$LST"; die "tar -tzf fehlgeschlagen fuer $TGZ"; fi
  if grep -qvE "^$AB(/|\$)" "$LST"; then local bad; bad="$(grep -vE "^$AB(/|\$)" "$LST" | head -1)"; rm -f "$LST"; die "Archiv enthaelt Pfade ausserhalb von $AB/ (z. B. $bad)"; fi
  if grep -qE '(^|/)\.\.(/|$)' "$LST"; then rm -f "$LST"; die "Archiv enthaelt Pfad mit .."; fi
  grep -qx "$AB/dashboard.py" "$LST" || { rm -f "$LST"; die "dashboard.py fehlt im Archiv"; }
  log "Archiv: $(wc -l < "$LST") Eintraege, nur $AB/..., dashboard.py vorhanden"
  rm -f "$LST"
}

# ---------------------------------------------------------------- Phase B: in Arbeitsordner entpacken und pruefen (Dienst laeuft weiter)
stage_and_check() {
  STEP="entpacken"
  local need_kb free
  need_kb=$(( $(stat -c %s "$TGZ") / 1024 * 3 + 307200 ))
  free="$(df -Pk "$PARENT" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ "$free" =~ ^[0-9]+$ ]] && (( free < need_kb )); then die "zu wenig Platz in $PARENT: $((free/1024)) MB frei, gebraucht etwa $((need_kb/1024)) MB"; fi
  STAGE="$(mktemp -d "$PARENT/.${AB}.restore-stage.XXXXXX")" || die "Arbeitsordner nicht anlegbar in $PARENT"
  if ! "$TAR" -xzpf "$TGZ" -C "$STAGE" 2>"$STAGE/.tar.err"; then die "Entpacken fehlgeschlagen: $(head -c 160 "$STAGE/.tar.err" | tr '\n' ' ')"; fi
  rm -f "$STAGE/.tar.err"
  local S="$STAGE/$AB"
  [[ -d "$S" && -f "$S/dashboard.py" ]] || die "nach dem Entpacken fehlt $AB/dashboard.py"
  STEP="code-pruefen"
  local pf=("$S"/*.py) cmp_err
  cmp_err="$("$PY" -c 'import sys
n = 0
for f in sys.argv[1:]:
    compile(open(f, "rb").read(), f, "exec"); n += 1
print(n)' "${pf[@]}" 2>&1)" || die "Code nicht uebersetzbar (System-Python): $(echo "$cmp_err" | tail -1 | cut -c1-200)"
  log "Code: $cmp_err Python-Dateien uebersetzbar (System-Python, ohne Bytecode zu schreiben)"
  if [[ -x "$APP/venv/bin/python" ]]; then
    cmp_err="$("$APP/venv/bin/python" -c 'import sys
for f in sys.argv[1:]:
    compile(open(f, "rb").read(), f, "exec")
print("ok")' "${pf[@]}" 2>&1)" || die "Code nicht uebersetzbar (venv-Python): $(echo "$cmp_err" | tail -1 | cut -c1-200)"
    log "Code: auch mit venv-Python uebersetzbar"
  else
    log "Hinweis: $APP/venv/bin/python nicht ausfuehrbar - venv-Pruefung uebersprungen"
  fi
  STEP="db-pruefen"
  local f hdr n=0
  shopt -s nullglob
  for f in "$S"/*.db; do
    hdr="$(head -c 15 "$f" 2>/dev/null | tr -d '\0')"
    [[ "$hdr" == "SQLite format 3" ]] || continue
    "$PY" - "$f" << 'PYQ' || die "SQLite quick_check der Kopie im Archiv fehlgeschlagen: $(basename "$f")"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); r = [x[0] for x in c.execute("PRAGMA quick_check").fetchall()]; c.close()
sys.exit(0 if r == ["ok"] else 1)
PYQ
    n=$((n+1))
  done
  shopt -u nullglob
  log "DB: $n SQLite-Datei(en) im Archiv, quick_check ok"
  STEP="uebernahme"
  # nicht im Archiv enthaltene, fuer den Betrieb noetige Teile aus dem aktuellen Ordner per Hardlink (kein Kopieren, alter Ordner bleibt vollstaendig)
  local it kept=""
  shopt -s nullglob dotglob
  for it in "$APP"/venv "$APP"/*.zim "$APP"/*.bak-* "$APP"/*.bak "$APP"/backups; do
    [[ -e "$it" ]] || continue
    [[ -e "$S/$(basename "$it")" ]] && continue
    cp -al "$it" "$S/" 2>/dev/null || cp -a "$it" "$S/" 2>/dev/null || die "Uebernahme von $(basename "$it") fehlgeschlagen"
    kept="$kept $(basename "$it")"
  done
  shopt -u nullglob dotglob
  log "Uebernommen aus dem aktuellen Ordner (per Hardlink):${kept:- nichts noetig}"
  # Sicherungs-/Wiederherstellungsskripte: stammt das Archiv aus der Zeit vor relBackup, bleiben die aktuellen (korrigierten) Skripte erhalten,
  # sonst stuende nach der Wiederherstellung wieder die alte, fehlerhafte Fassung im Ordner
  local t kept_tools=""
  for t in backup.sh restore.sh; do
    if grep -q relBackup "$APP/tools/$t" 2>/dev/null && ! grep -q relBackup "$S/tools/$t" 2>/dev/null; then
      mkdir -p "$S/tools" && cp -p "$APP/tools/$t" "$S/tools/$t.new" && mv -f "$S/tools/$t.new" "$S/tools/$t" || die "tools/$t konnte nicht uebernommen werden"
      kept_tools="$kept_tools $t"
    fi
  done
  [[ -n "$kept_tools" ]] && log "tools/:$kept_tools stammen im Archiv aus der Zeit vor relBackup - aktuelle Fassung bleibt erhalten"
  chmod +x "$S"/tools/*.sh 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- Dienst: Stopp/Start/Gesundheit
stop_main_and_wait() {  # SIGTERM an den Hauptprozess, warten bis weg
  local pid="$1" i
  kill -TERM "$pid" 2>/dev/null || return 1
  for ((i=0; i<KILL_WAIT_S*2; i++)); do pid_alive "$pid" || return 0; sleep 0.5; done
  return 1
}
svc_down() {  # setzt METHOD, DOWN
  STEP="dienst-stoppen"
  OLDPID="$(svc_mainpid)"
  if ! svc_active && [[ "$OLDPID" == 0 ]]; then METHOD="war-nicht-aktiv"; DOWN=1; log "Dienst $SVC lief nicht (nichts zu stoppen)"; return 0; fi
  if SC stop "$SVC" >/dev/null 2>&1; then METHOD="systemctl"; DOWN=1; log "Dienst gestoppt (systemctl stop)"; return 0; fi
  if "$SUDO" -n "$SYSTEMCTL" stop "$SVC" >/dev/null 2>&1; then METHOD="sudo-n"; DOWN=1; log "Dienst gestoppt (sudo -n systemctl stop)"; return 0; fi
  if [[ -t 0 ]] && "$SUDO" "$SYSTEMCTL" stop "$SVC"; then METHOD="sudo"; DOWN=1; log "Dienst gestoppt (sudo systemctl stop, Passwort)"; return 0; fi
  local pol; pol="$(restart_policy)"
  if [[ ( "$pol" == always || "$pol" == on-success ) && "$OLDPID" -gt 0 ]]; then
    log "systemctl/sudo nicht erlaubt - Ausweg: SIGTERM an Hauptprozess $OLDPID (Restart=$pol, systemd startet danach selbst neu)"
    if stop_main_and_wait "$OLDPID"; then METHOD="sigterm-restart"; DOWN=1; log "Hauptprozess beendet"; return 0; fi
    die "Hauptprozess $OLDPID beendete sich nach SIGTERM nicht innerhalb $KILL_WAIT_S s - nichts getauscht"
  fi
  die "Dienst nicht stoppbar: weder systemctl noch sudo -n erlaubt, und Restart=${pol:-?} erlaubt keinen SIGTERM-Ausweg - nichts geaendert"
}
svc_up() {
  STEP="dienst-starten"
  if [[ "$METHOD" == sigterm-restart ]]; then
    local i
    for ((i=0; i<RESTART_WAIT_S; i++)); do svc_active && [[ "$(svc_mainpid)" != "$OLDPID" ]] && { log "Dienst von systemd neu gestartet (Restart=always)"; return 0; }; sleep 1; done
    log "Kein Neustart durch systemd innerhalb $RESTART_WAIT_S s - versuche zu starten"
  fi
  if SC start "$SVC" >/dev/null 2>&1; then log "Dienst gestartet (systemctl start)"; return 0; fi
  if "$SUDO" -n "$SYSTEMCTL" start "$SVC" >/dev/null 2>&1; then log "Dienst gestartet (sudo -n systemctl start)"; return 0; fi
  if [[ -t 0 ]] && "$SUDO" "$SYSTEMCTL" start "$SVC"; then log "Dienst gestartet (sudo, Passwort)"; return 0; fi
  log "Dienst nicht startbar (systemctl/sudo nicht erlaubt)"
  return 1
}
http_code() {
  local u c
  for u in "http://127.0.0.1:$PORT/pi" "http://127.0.0.1:$PORT/"; do
    c="$("$CURL" -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$u" 2>/dev/null || true)"
    [[ "$c" == 200 ]] && { echo 200; return 0; }
  done
  echo "${c:-000}"
}
healthy() {  # neuer Prozess, aktiv, HTTP 200 zweimal im Abstand STAB_S
  STEP="gesundheit"
  local pid c1 c2 last="" t_end=$(( $(date +%s) + HEALTH_S ))
  while (( $(date +%s) < t_end )); do
    pid="$(svc_mainpid)"
    if svc_active && [[ "$pid" -gt 0 && "$pid" != "$OLDPID" ]]; then
      c1="$(http_code)"
      if [[ "$c1" == 200 ]]; then
        sleep "$STAB_S"
        pid="$(svc_mainpid)"
        c2="$(http_code)"
        if [[ "$c2" == 200 ]] && svc_active && [[ "$pid" != 0 && "$pid" != "$OLDPID" ]]; then log "Gesundheit: Dienst aktiv (neuer Prozess $pid), HTTP 200 stabil"; return 0; fi
      fi
      last="aktiv, HTTP ${c1}"
    else
      last="nicht aktiv oder alter Prozess"
    fi
    sleep 3
  done
  log "Gesundheit: nach $HEALTH_S s nicht gesund (letzter Stand: $last)"
  return 1
}
swap_dirs() {  # swap_dirs <alt-weg-nach> <neu-aus> ; zwei Umbenennungen
  mv "$APP" "$1" || return 1
  if ! mv "$2" "$APP"; then mv "$1" "$APP"; return 1; fi
  return 0
}

emergency() {
  # Sicherheitsnetz beim Verlassen: Dienst war unten/getauscht und das Ergebnis nicht endgueltig -> alter Ordner zurueck, Dienst starten
  [[ "$DOWN" == 1 && "$DONE" != 1 ]] || return 0
  log "NOTFALL: Skript endete unerwartet (Schritt $STEP) - alter Stand wird wiederhergestellt"
  if [[ "$SWAPPED" == 1 && -d "$BAK" ]]; then
    if [[ -d "$APP" ]]; then mv "$APP" "$FAILED_DIR" 2>/dev/null; fi
    if mv "$BAK" "$APP" 2>/dev/null; then SWAPPED=0; log "NOTFALL: alter Ordner zurueckgelegt ($APP), ungeprueften neuen Stand nach $(basename "$FAILED_DIR")"; fi
  elif [[ ! -f "$APP/dashboard.py" && -d "$BAK" ]]; then
    mv "$BAK" "$APP" 2>/dev/null && log "NOTFALL: alter Ordner zurueck ($APP)"
  fi
  svc_up >/dev/null 2>&1 || true
  status failed "Skript endete unerwartet im Schritt $STEP; alter Stand zurueckgelegt, Dienst gestartet (bitte pruefen)"
}
on_exit() {
  emergency
  [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"
  return 0
}
on_sig() { log "Signal empfangen (Schritt $STEP)"; exit 2; }

pre_backup() {  # 0 ok, 2 DB defekt (weiter mit Warnung), 1 Abbruch
  STEP="sicherung-vorher"
  local bk="$APP/tools/backup.sh" out rc
  [[ -x "$bk" ]] || { log "backup.sh fehlt oder nicht ausfuehrbar: $bk"; return 1; }
  out="$(PREPPER_BACKUP_INTERNAL=1 PREPPER_BACKUP_PROTECT="$ID" "$bk" M pre-restore 2>&1)"; rc=$?
  log "Sicherung vorher: $(echo "$out" | tail -1 | cut -c1-220)"
  SAFETY_ID="$("$PY" - "$DEST" << 'PYB'
import glob, json, os, sys
best = None
for p in glob.glob(os.path.join(sys.argv[1], "prepper-*-M.json")):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get("label") == "pre-restore" and (best is None or p > best[0]):
        best = (p, d)
print(best[1].get("id", "") if best else "")
PYB
  )"
  if [[ "$rc" == 0 ]]; then return 0; fi
  if echo "$out" | grep -q 'err=db'; then
    log "WARNUNG: Datenbank des laufenden Systems ist nicht sicherbar (defekt?) - genau dafuer ist die Wiederherstellung da; der alte Ordner bleibt vollstaendig als $(basename "$BAK") erhalten"
    return 2
  fi
  return 1
}

# ---------------------------------------------------------------- Abkopplung
can_root() { [[ "$(id -u)" == 0 ]]; }
user_bus_env() {
  local rd="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [[ -S "$rd/bus" ]] || return 1
  UBUS_ENV=("XDG_RUNTIME_DIR=$rd" "DBUS_SESSION_BUS_ADDRESS=unix:path=$rd/bus")
  return 0
}
can_sudo_run() { "$SUDO" -n -l "$(command -v "$SYSTEMD_RUN" 2>/dev/null || echo systemd-run)" >/dev/null 2>&1; }
unit_busy() {
  [[ "$("$SYSTEMCTL" is-active "$UNIT" 2>/dev/null)" =~ ^(active|activating)$ ]] && return 0
  user_bus_env && [[ "$(env "${UBUS_ENV[@]}" "$SYSTEMCTL" --user is-active "$UNIT" 2>/dev/null)" =~ ^(active|activating)$ ]] && return 0
  return 1
}
detach() {  # startet sich selbst in eigener Einheit; Rueckgabe 0 = gestartet, 1 = kein Weg
  STEP="abkoppeln"
  local cp="$DEST/.restore-run.sh" way="" out rc run
  cp -f "$SELF" "$cp" && chmod 700 "$cp" || { echo "ERR: Skriptkopie nach $cp nicht moeglich" >&2; return 1; }
  RUNID="$(date +%s)-$$"
  local base=(--unit="$UNIT" --collect --quiet --description="Prepper Wiederherstellung $ID" --setenv=PREPPER_RESTORE_DETACHED=1 --setenv="PREPPER_RESTORE_RUNID=$RUNID")
  if [[ "${PREPPER_SELFTEST:-}" == "1" ]]; then base+=(--setenv=PREPPER_SELFTEST=1); local v; for v in $(env | sed -n 's/^\(PREPPER_[A-Z_]*\)=.*/\1/p'); do [[ "$v" == PREPPER_RESTORE_DETACHED || "$v" == PREPPER_RESTORE_RUNID || "$v" == PREPPER_SELFTEST ]] || base+=(--setenv="$v=${!v}"); done; fi
  local cmd=(/bin/bash "$cp" --detached "$ID")
  out=""; rc=1
  if can_root; then
    way="systemd-run (root)"; out="$("$SYSTEMD_RUN" "${base[@]}" "${cmd[@]}" 2>&1)"; rc=$?
  fi
  if [[ "$rc" != 0 ]] && user_bus_env; then
    way="systemd-run --user (Benutzer-Manager)"; out="$(env "${UBUS_ENV[@]}" "$SYSTEMD_RUN" --user "${base[@]}" "${cmd[@]}" 2>&1)"; rc=$?
  fi
  if [[ "$rc" != 0 ]] && can_sudo_run; then
    way="sudo -n systemd-run"; out="$("$SUDO" -n "$SYSTEMD_RUN" --uid="$(id -u)" --gid="$(id -g)" "${base[@]}" "${cmd[@]}" 2>&1)"; rc=$?
  fi
  if [[ "$rc" != 0 ]]; then
    log "Abkoppeln nicht moeglich (${way:-kein Weg}): $(echo "$out" | tail -1 | cut -c1-200)"
    return 1
  fi
  log "Wiederherstellung $ID gestartet in eigener Einheit $UNIT ($way), Lauf $RUNID"
  # Beleg, dass die Einheit wirklich laeuft: Status-Datei mit dieser Lauf-ID
  local i
  for ((i=0; i<40; i++)); do
    run="$("$PY" -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("run",""))
except Exception:
    print("")' "$STATUS" 2>/dev/null)"
    [[ "$run" == "$RUNID" ]] && return 0
    sleep 0.25
  done
  log "WARNUNG: Einheit meldet sich nicht innerhalb 10 s im Status (laeuft vermutlich noch an) - Protokoll: $LOG"
  return 0
}

# ================================================================ Hauptablauf
trap on_exit EXIT
trap on_sig INT TERM HUP

mkdir -p "$DEST" 2>/dev/null; chmod 700 "$DEST" 2>/dev/null
if [[ "$DRY" == 1 ]]; then log "== DRY-RUN restore $ID (stoppt nichts, tauscht nichts, keine Sicherung) =="; fi

# --- Aufruf aus dem Dashboard-Prozess: erst nur pruefen, dann abkoppeln
if [[ "$DRY" == 0 && "$DETACHED" != 1 && "$FG" == 0 ]] && in_dash_cgroup; then
  NOSTATUS=1   # Starter schreibt weder Status noch Sperre (sonst wuerde er den Zustand einer laufenden Wiederherstellung ueberschreiben)
  if unit_busy; then die "Wiederherstellung laeuft bereits (Einheit $UNIT)"; fi
  check_archive
  if detach; then
    DONE=1
    echo "OK gestartet: Wiederherstellung $ID laeuft in eigener Einheit $UNIT, das Dashboard wird dabei neu gestartet. Ergebnis: $LOG (restore-status.json)"
    exit 0
  fi
  echo "ERR: nicht gestartet - das Skript laeuft in der Control-Group von $SVC.service und kann sich nicht abkoppeln (weder root, Benutzer-Manager noch sudo-Regel fuer systemd-run). Nichts wurde geaendert. Wiederherstellung per SSH: bash $APP/tools/restore.sh $ID" >&2
  DONE=1; exit 3
fi

# --- ab hier: eigentliche Arbeit (in eigener Einheit, per SSH oder im Dry-Run)
trap '' HUP   # SSH-Abbruch darf die Wiederherstellung nicht mittendrin beenden
if [[ "$DRY" == 0 ]]; then
  command -v flock >/dev/null 2>&1 || die "flock fehlt (util-linux)"
  exec 9>"$DEST/.restore.lock"
  flock -n 9 || die "eine Wiederherstellung laeuft bereits (Sperre $DEST/.restore.lock)"
  if [[ -f "$LOG" ]] && [[ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]]; then mv -f "$LOG" "$LOG.1"; fi
  STEP="start"; status running "gestartet"
  log "== Wiederherstellung $ID (Lauf $RUNID, Benutzer $(id -un), Abkopplung: $([[ "$DETACHED" == 1 ]] && echo 'eigene Einheit' || echo 'nein/nicht noetig')) =="
  if in_dash_cgroup; then log "WARNUNG: laeuft noch in der Control-Group von $SVC.service - systemctl stop wuerde dieses Skript beenden"; fi
fi

check_archive
stage_and_check

if [[ "$DRY" == 1 ]]; then
  log "-- Wege (nur lesend geprueft) --"
  detach_ways=""; stop_ways=""
  if in_dash_cgroup; then log "Aufruf aus Dashboard-Control-Group: ja (Abkopplung noetig)"; else log "Aufruf aus Dashboard-Control-Group: nein (z. B. SSH-Sitzung; kein Abkoppeln noetig)"; fi
  if can_root; then detach_ways="$detach_ways root(systemd-run)"; log "Abkoppeln: moeglich als root (systemd-run)"; else log "Abkoppeln als root: nein (Benutzer $(id -un))"; fi
  if user_bus_env; then detach_ways="$detach_ways Benutzer-Manager(systemd-run --user)"; log "Abkoppeln: Benutzer-Manager-Bus vorhanden (systemd-run --user): ja"; else log "Abkoppeln: Benutzer-Manager-Bus (systemd-run --user): nicht vorhanden (laeuft der Benutzer-Manager von $(id -un)? Abhilfe: loginctl enable-linger $(id -un))"; fi
  if can_sudo_run; then detach_ways="$detach_ways sudo-Regel(systemd-run)"; log "Abkoppeln: sudo -n systemd-run erlaubt: ja"; else log "Abkoppeln: sudo -n systemd-run erlaubt: nein"; fi
  if can_root; then stop_ways="$stop_ways systemctl(root)"; fi
  if "$SUDO" -n -l "$SYSTEMCTL" stop "$SVC" >/dev/null 2>&1; then stop_ways="$stop_ways sudo-Regel(systemctl stop)"; log "Stopp: sudo -n systemctl stop $SVC erlaubt: ja"; else log "Stopp: sudo -n systemctl stop $SVC erlaubt: nein/nur mit Passwort"; fi
  pol="$(restart_policy)"; mp="$(svc_mainpid)"
  own="nein"; [[ "$mp" -gt 0 && -r "/proc/$mp/status" && "$(stat -c %u "/proc/$mp" 2>/dev/null)" == "$(id -u)" ]] && own="ja"
  log "Stopp-Ausweg SIGTERM+Neustart: Restart=${pol:-?}, Hauptprozess $mp gehoert mir: $own"
  if [[ ( "$pol" == always || "$pol" == on-success ) && "$own" == ja ]]; then stop_ways="$stop_ways SIGTERM+Restart=$pol"; fi
  log "ZUSAMMENFASSUNG Abkoppeln: ${detach_ways:- KEIN WEG} | Stopp: ${stop_ways:- nur per SSH mit sudo-Passwort}"
  if [[ -n "$detach_ways" && -n "$stop_ways" ]]; then log "ZUSAMMENFASSUNG Dashboard-Knopf: sollte funktionieren"
  else log "ZUSAMMENFASSUNG Dashboard-Knopf: funktioniert voraussichtlich NICHT (meldet dann Exit 3/Fehler ohne etwas zu aendern); Wiederherstellung dann per SSH: bash $APP/tools/restore.sh <id>"; fi
  log "DRY-RUN OK: $ID ist wiederherstellbar (Archiv, Code, DB geprueft); es wurde nichts gestoppt, getauscht oder gesichert"
  DONE=1; exit 0
fi

# --- Sicherung des aktuellen Zustands (vor dem Stopp)
pre_backup; pb=$?
[[ "$pb" == 0 || "$pb" == 2 ]] || die "Sicherung vor der Wiederherstellung fehlgeschlagen - nichts geaendert (siehe Protokoll)"

# --- stoppen, tauschen, starten, pruefen
[[ ! -e "$BAK" && ! -e "$FAILED_DIR" ]] || die "Zielname fuer den alten Ordner existiert schon: $BAK - nichts geaendert"
svc_down
[[ "${PREPPER_SELFTEST:-}" == 1 && -n "${PREPPER_PAUSE_AFTER_STOP:-}" ]] && sleep "$PREPPER_PAUSE_AFTER_STOP"
STEP="tauschen"; status running "Dienst gestoppt, tausche Ordner"
if ! swap_dirs "$BAK" "$STAGE/$AB"; then
  log "Tausch fehlgeschlagen - alter Ordner bleibt"
  svc_up || true
  DONE=1; status failed "Ordner konnte nicht getauscht werden (alter Stand bleibt aktiv)"; exit 1
fi
SWAPPED=1
log "Ordner getauscht: alter Stand -> $(basename "$BAK"), Sicherung $ID -> $APP"
[[ "${PREPPER_SELFTEST:-}" == 1 && -n "${PREPPER_PAUSE_AFTER_SWAP:-}" ]] && sleep "$PREPPER_PAUSE_AFTER_SWAP"
[[ -f "$APP/dashboard.py" ]] || { log "dashboard.py fehlt nach dem Tausch"; }
status running "Dienst wird gestartet"
svc_up
if [[ -f "$APP/dashboard.py" ]] && healthy; then
  STEP="aufraeumen"
  shopt -s nullglob
  for old in "${APP}".bak-restore-* "${APP}".failed-restore-*; do [[ "$old" == "$BAK" ]] && continue; rm -rf "$old"; done
  shopt -u nullglob
  DONE=1; SWAPPED=0
  others="$(SC list-units --no-legend --plain --state=active 'prepper-*.service' 2>/dev/null | awk '{print $1}' | grep -v "^${SVC}.service$" | tr '\n' ' ')"
  [[ -n "$others" ]] && log "Hinweis: weitere Dienste laufen mit altem Code im Speicher weiter: ${others}- bei abweichendem Archivstand bei Bedarf neu starten (sudo systemctl restart <Dienst>)"
  log "OK Wiederherstellung $ID abgeschlossen; alter Stand: $(basename "$BAK"); Sicherung vorher: ${SAFETY_ID:-keine}"
  status ok "wiederhergestellt; alter Stand $(basename "$BAK")"
  echo "OK restore ${ID} (bak kept: $(basename "$BAK"))"
  exit 0
fi

# --- Rueckfall
STEP="rueckfall"
log "RUECKFALL: wiederhergestellter Stand wird nicht gesund - alter Stand wird zurueckgelegt"
status running "Rueckfall auf den alten Stand"
cur="$(svc_mainpid)"
if [[ "$cur" -gt 0 ]]; then
  if [[ "$METHOD" == sigterm-restart ]]; then stop_main_and_wait "$cur" || log "WARNUNG: Hauptprozess $cur laesst sich nicht beenden"
  else SC stop "$SVC" >/dev/null 2>&1 || "$SUDO" -n "$SYSTEMCTL" stop "$SVC" >/dev/null 2>&1 || { [[ -t 0 ]] && "$SUDO" "$SYSTEMCTL" stop "$SVC"; } || log "WARNUNG: Dienst nicht stoppbar fuer den Rueckfall"; fi
fi
OLDPID="$cur"
if swap_dirs "$FAILED_DIR" "$BAK"; then SWAPPED=0; else
  DONE=1; log "FEHLER: Rueckfall-Tausch fehlgeschlagen - EINGRIFF NOETIG: alter Stand liegt in $BAK, aktueller in $APP"
  status failed "Rueckfall-Tausch fehlgeschlagen; alter Stand in $BAK"; exit 2
fi
svc_up || true
HEALTH_S=90
if healthy; then
  DONE=1; log "Rueckfall ok: alter Stand laeuft wieder (fehlgeschlagener Stand: $(basename "$FAILED_DIR"))"
  status rolled-back "wiederhergestellter Stand wurde nicht gesund; alter Stand laeuft wieder"
  echo "ERR: Wiederherstellung $ID fehlgeschlagen (Dienst nicht gesund) - alter Stand laeuft wieder" >&2
  exit 1
fi
DONE=1
log "FEHLER: auch der alte Stand wird nicht gesund - EINGRIFF NOETIG: journalctl -u $SVC -n 50; Sicherung vorher: ${SAFETY_ID:-keine}; fehlgeschlagener Stand: $FAILED_DIR"
status failed "auch der alte Stand wird nicht gesund; Eingriff noetig"
echo "ERR: Wiederherstellung fehlgeschlagen und Rueckfall nicht gesund - Eingriff noetig, siehe $LOG" >&2
exit 2
RB_RESTORE_EOF
EXPECT_baseb="724a7e4beb218d04b007ca2946fb8eeddaedf8daacadf29ebbf9aed55af17ddb"
mkdir -p "$W/base"
cat > "$W/base/backup.sh" << 'RB_BASEB_EOF'
#!/bin/bash
set -u
MODE="${1:-A}"
[[ "$MODE" == "M" || "$MODE" == "A" ]] || MODE="A"
RAW_LABEL="${2:-}"
# sanitize: alnum, dash, underscore, max 40
LABEL="$(printf '%s' "$RAW_LABEL" | tr -cd 'A-Za-z0-9_-' | cut -c1-40)"
if [[ -z "$LABEL" ]]; then
  if [[ "$MODE" == "A" ]]; then LABEL="auto"; else LABEL="manual"; fi
fi

APP="/home/fmg/prepper-dashboard"
DEST="/home/fmg/prepper-backups"
mkdir -p "$DEST"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="prepper-${STAMP}-${MODE}"
FILE="${DEST}/${BASE}.tgz"
META="${DEST}/${BASE}.json"
OK=0
ERR=""
HASH=""

if tar \
  --exclude="${APP}/venv" \
  --exclude="${APP}/__pycache__" \
  --exclude="${APP}/backups" \
  --exclude="*.zim" \
  -C /home/fmg \
  -czf "$FILE" --warning=no-file-changed \
  prepper-dashboard \
  2>/home/fmg/prepper-dashboard/backup.err || [[ -s "$FILE" ]]
then
  if tar -tzf "$FILE" >/dev/null 2>&1 && [[ -s "$FILE" ]]; then
    OK=1
    HASH="$(sha256sum "$APP/dashboard.py" 2>/dev/null | awk '{print substr($1,1,12)}')"
  else
    ERR="verify"
  fi
else
  ERR="tar"
fi

python3 - "$META" "$FILE" "$MODE" "$OK" "$ERR" "$LABEL" "$HASH" "$BASE" << 'PY'
import json, os, sys, datetime
meta, file, mode, ok, err, label, hash_, base = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1",
    sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8],
)
now = datetime.datetime.now()
wd = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][now.weekday()]
d = {
    "ok": ok,
    "mode": mode,
    "err": err or None,
    "file": os.path.basename(file) if os.path.exists(file) else None,
    "bytes": os.path.getsize(file) if os.path.exists(file) else 0,
    "at": now.strftime("%d.%m.%Y %H:%M:%S"),
    "wd": wd,
    "iso": now.isoformat(timespec="seconds"),
    "label": label or None,
    "hash": hash_ or None,
    "id": base,
}
with open(meta, "w") as f:
    json.dump(d, f)
if ok:
    print("OK " + d["at"] + " " + mode + " label=" + (label or "-") + " hash=" + (hash_ or "????"))
else:
    print("FAIL " + d["at"] + " " + mode + " err=" + (err or "?"))
PY

# Rotation: neueste 10 Paare behalten
python3 - "$DEST" << 'PY'
import os, sys, glob
dest = sys.argv[1]
tgz = sorted(glob.glob(os.path.join(dest, "prepper-*.tgz")), key=os.path.getmtime, reverse=True)
for old in tgz[10:]:
    base = old[:-4]
    for p in (old, base + ".json"):
        try:
            os.remove(p)
        except FileNotFoundError:
            pass
PY

if [[ "$OK" -eq 1 ]]; then
  exit 0
fi
exit 1
RB_BASEB_EOF
EXPECT_baser="04da8489c6e6ecb63868dc14288a14185d68452bce63e5700d8fc9b9cbb64e26"
mkdir -p "$W/base"
cat > "$W/base/restore.sh" << 'RB_BASER_EOF'
#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERR: $*" >&2; exit 1; }

ID="${1:-}"
[[ -n "$ID" ]] || die "usage: restore.sh <id>  (e.g. prepper-20260920-140458-M)"
[[ "$ID" =~ ^prepper-[0-9]{8}-[0-9]{6}-[MA]$ ]] || die "invalid id: $ID"

APP="/home/fmg/prepper-dashboard"
DEST="/home/fmg/prepper-backups"
TGZ="${DEST}/${ID}.tgz"
TOOLS_DIR="${APP}/tools"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="${APP}.bak-restore-${STAMP}"

[[ -f "$TGZ" ]] || die "missing archive: $TGZ"
[[ -s "$TGZ" ]] || die "empty archive: $TGZ"
tar -tzf "$TGZ" >/dev/null || die "tar -tzf failed for $TGZ"

svc() {
  local action="$1"
  if systemctl "$action" prepper-dashboard >/dev/null 2>&1; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo systemctl "$action" prepper-dashboard
    return $?
  fi
  return 1
}

svc_is_active() {
  if systemctl is-active --quiet prepper-dashboard 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo systemctl is-active --quiet prepper-dashboard 2>/dev/null; then
    return 0
  fi
  return 1
}

rollback() {
  echo "ERR: $1 — rolling back" >&2
  rm -rf "$APP" 2>/dev/null || true
  if [[ -d "$BAK" ]]; then
    mv "$BAK" "$APP" || echo "ERR: could not restore bak $BAK" >&2
  fi
  svc start || true
  exit 1
}

# 2) Safety backup with label pre-restore (before stopping service)
[[ -x "${TOOLS_DIR}/backup.sh" ]] || die "backup.sh missing/not executable at ${TOOLS_DIR}/backup.sh"
"${TOOLS_DIR}/backup.sh" M pre-restore || die "pre-restore backup failed"

# 3) Stop service
svc stop || die "systemctl stop prepper-dashboard failed"

# 4) Move current app aside
[[ -d "$APP" ]] || die "APP missing: $APP"
mv "$APP" "$BAK" || die "mv $APP -> $BAK failed"

# 5) Extract archive (creates /home/fmg/prepper-dashboard)
if ! tar -xzf "$TGZ" -C /home/fmg; then
  rollback "tar extract failed"
fi
[[ -d "$APP" ]] || rollback "extract did not create $APP"
[[ -f "$APP/dashboard.py" ]] || rollback "dashboard.py missing after extract"

# 6–7) Compile check; rollback on fail
if ! python3 -m py_compile "$APP/dashboard.py"; then
  rollback "py_compile dashboard.py failed"
fi

# Ensure tools are executable (restored tree may have older tools)
chmod +x "$APP/tools/"*.sh 2>/dev/null || true

# 8) Start + check active
svc start || die "systemctl start prepper-dashboard failed"
sleep 2
if ! svc_is_active; then
  die "prepper-dashboard not active after start"
fi

# 9) Optional HTTP probe — keep restored code even on WARN
CODE="000"
for url in "http://127.0.0.1:5000/pi" "http://127.0.0.1:5000/"; do
  CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null || echo "000")"
  if [[ "$CODE" == "200" ]]; then
    break
  fi
done
if [[ "$CODE" != "200" ]]; then
  echo "WARN: HTTP check not 200 (got ${CODE}) — restored code left in place"
fi

# 10) Keep only the latest .bak-restore-*
shopt -s nullglob
for old in /home/fmg/prepper-dashboard.bak-restore-*; do
  [[ "$old" == "$BAK" ]] && continue
  rm -rf "$old"
done
shopt -u nullglob

echo "OK restore ${ID} (bak kept: $(basename "$BAK"))"
exit 0
RB_BASER_EOF
EXPECT_guard="1abdb823a38a2d1cfa0677e82869234eb943d2e2641d6bdaddd06dad016b2bc5"
cat > "$W/guardrel.py" << 'RB_GUARD_EOF'
#!/usr/bin/env python3
"""relBackup Guard: statische Pruefung von backup.sh/restore.sh (check) und Mutationstest der Pruefungen (mutation).
Aufruf: guardrel.py check <Ordner> | guardrel.py mutation <Ordner>   (Ordner enthaelt backup.sh und restore.sh)"""
import os, re, sys

def load(d):
    return open(os.path.join(d, "backup.sh")).read(), open(os.path.join(d, "restore.sh")).read()

def checks(b, r):
    """-> Liste (Name, ok)"""
    c = []
    bc = re.sub(r"(?m)^\s*#.*$", "", b); rc_ = re.sub(r"(?m)^\s*#.*$", "", r)
    def pos(txt, pat):
        m = re.search(pat, txt, re.M)
        return m.start() if m else -1
    ex = re.findall(r'--exclude=("?)([^\s"]+)\1', b)
    c.append(("backup: mindestens 7 --exclude, keiner mit absolutem Pfad", len(ex) >= 7 and not any(p.startswith("/") or p.startswith("${APP}") or p.startswith("$APP") for _, p in ex)))
    c.append(("backup: venv/backups/__pycache__/*.zim/*.bak-* ausgeschlossen", all(x in b for x in ('"$AB/venv"', '"$AB/backups"', '"__pycache__"', '"*.zim"', '"*.bak-*"'))))
    c.append(("backup: Live-DB (-wal/-shm/-journal) ausgeschlossen", '--exclude="$AB/$d-wal"' in b and '--exclude="$AB/$d-shm"' in b))
    c.append(("backup: sqlite3-Backup-API (src.backup) und quick_check", "src.backup(dst)" in b and bc.count("PRAGMA quick_check") >= 2))
    c.append(("backup: DB-Kopie ueber --transform an den Platz der Datei", '--transform="s,^snapdb/,$AB/,"' in b and '-C "$STAGE" "snapdb/$d"' in b))
    c.append(("backup: umask 077, Ordner 700, Archiv 600", "umask 077" in b and 'chmod 700 "$DEST"' in b and 'chmod 600 "$FILE"' in b))
    c.append(("backup: tar-Exit >= 2 ist Fehler, 1 nur Warnung", "(( TARRC >= 2 ))" in b and "(( TARRC == 1 ))" in b))
    c.append(("backup: gzip -t, tar -t, Pflichtdatei, sha256 in der json", "gzip -t" in b and 'tar -tzf' in b.replace('"$TAR" -tzf', 'tar -tzf') and '"$AB/dashboard.py"' in b and '"sha256": sha' in b))
    c.append(("backup: Archiv erst als .part, dann umbenannt", '.${BASE}.tgz.part' in b and 'mv -f "$PART" "$FILE"' in b))
    c.append(("backup: Exit 1 bei Fehler (ehrlich)", re.search(r'if \[\[ "\$OK" -eq 1 && "\$PYRC" -eq 0 \]\]; then\s+exit 0\s+fi\s+exit 1', b) is not None))
    c.append(("backup: Rotation behaelt Schutz-ID und neueste gute Sicherung", "keepset.add(protect)" in b and "if good(i):" in b))
    c.append(("backup: keine Ueberschreibung gleichnamiger Sicherung", 'while [[ -e "$FILE" || -e "$META" ]]; do' in b))
    c.append(("backup: Sperre waehrend Wiederherstellung", '.restore.lock' in b and 'restore-running' in b))
    c.append(("backup: keine Secret-Ausgabe (config.py wird nie gelesen)", "config.py" not in re.sub(r"#.*", "", b)))
    c.append(("restore: eigene Einheit (systemd-run --unit/--collect/--user/--uid), Pruefung der Control-Group", all(x in r for x in ("--unit=", "--collect", '--user', '--uid=', "in_dash_cgroup() {"))))
    c.append(("restore: sha256 aus json, gzip, Pfadpruefung (ausserhalb, ..)", all(x in r for x in ("h.hexdigest() != want", "gzip -t", "Pfade ausserhalb", "Pfad mit .."))))
    c.append(("restore: Arbeitsordner-Entpackung mit py_compile (compile) und DB quick_check vor dem Stopp", r.count('compile(open(f, "rb")') >= 2 and "PRAGMA quick_check" in rc_ and 0 < pos(rc_, r"^stage_and_check$") < pos(rc_, r"^svc_down$")))
    c.append(("restore: Sicherung vorher mit Rotationsschutz", 'PREPPER_BACKUP_PROTECT="$ID"' in r and "pre-restore" in r))
    c.append(("restore: Dry-Run endet vor Sicherung und Stopp", r.find("DRY-RUN OK") != -1 and 0 < pos(rc_, r"DRY-RUN OK") < pos(rc_, r"^pre_backup; pb=\$\?$") < pos(rc_, r"^svc_down$")))
    c.append(("restore: Gesundheitspruefung entscheidet ueber Erfolg, Rueckfall vorhanden", "&& healthy; then" in r and "RUECKFALL" in r and "swap_dirs" in r))
    c.append(("restore: Notfall-Netz (EXIT-Trap) und Signal-Trap", "trap on_exit EXIT" in r and "trap on_sig INT TERM HUP" in r and "emergency()" in r))
    c.append(("restore: kein 'rm -rf \"$APP\"' (alter Rollback-Fehler), Tausch nur per mv", 'rm -rf "$APP"' not in r and r.count("mv ") >= 3))
    c.append(("restore: Sperre (flock), Status-Datei, Protokoll", "flock -n 9" in r and "restore-status.json" in r and "restore.log" in r))
    c.append(("restore: config.py nur fuer die Port-Ziffern gelesen", len(re.findall(r"config\.py", re.sub(r"#.*", "", r))) == 1 and "PORT[[:space:]]" in r))
    c.append(("restore: Stopp-Leiter systemctl -> sudo -n -> sudo (Terminal) -> SIGTERM nur bei Restart=always/on-success", all(x in r for x in ('SC stop "$SVC"', '"$SUDO" -n "$SYSTEMCTL" stop', "[[ -t 0 ]]", 'restart_policy', "if [[ ( \"$pol\" == always || \"$pol\" == on-success ) && \"$OLDPID\" -gt 0 ]]; then"))))
    c.append(("restore: aktuelle tools/*.sh bleiben bei alten Archiven erhalten", "grep -q relBackup" in r))
    return c

# Mutationen: (Beschreibung, Datei b|r, alt, neu) - jede muss mindestens eine Pruefung kippen
MUT = [
 ("absoluter --exclude", "b", '--exclude="$AB/venv"', '--exclude="/home/fmg/prepper-dashboard/venv"'),
 ("Backup-API entfernt (Rohkopie)", "b", "src.backup(dst)", "pass"),
 ("quick_check im Snapshot entfernt", "b", 'qc = [r[0] for r in dst.execute("PRAGMA quick_check").fetchall()]', 'qc = ["ok"]'),
 ("tar-Fehler toleriert", "b", "(( TARRC >= 2 ))", "(( TARRC >= 9 ))"),
 ("Archiv-Rechte nicht gesetzt", "b", 'chmod 600 "$FILE"', ':'),
 ("Ordner 700 entfernt", "b", 'chmod 700 "$DEST"', ':'),
 ("Ausgabe-Exit immer 0", "b", "exit 1\nEOF_PLACEHOLDER", "exit 0\nEOF_PLACEHOLDER"),
 ("kein Rotationsschutz", "b", "keepset.add(protect)", "pass"),
 ("sha256 in json entfernt", "b", '"sha256": sha', '"x": sha'),
 ("kein Abkoppeln (systemd-run entfernt)", "r", "--collect", "--keep"),
 ("sha256-Pruefung entfernt", "r", "h.hexdigest() != want", "False"),
 ("Dry-Run nach der Sicherung", "r", "DRY-RUN OK: $ID", "DRY-RUN-ENDE: $ID"),
 ("Stopp vor Staging", "r", "check_archive\nstage_and_check\n", "svc_down\ncheck_archive\nstage_and_check\n"),
 ("Notfall-Trap entfernt", "r", "trap on_exit EXIT", ":"),
 ("rm -rf APP im Rueckfall", "r", "swap_dirs()", 'rm -rf "$APP"\nswap_dirs()'),
 ("Rotationsschutz bei Vorab-Sicherung entfernt", "r", 'PREPPER_BACKUP_PROTECT="$ID"', 'X_PROTECT="$ID"'),
 ("SIGTERM ohne Restart-Pruefung", "r", "always || \"$pol\" == on-success", "always || \"$pol\" == on-success || true"),
 ("config.py komplett gelesen", "r", "sed -n 's/^PORT", "cat \"$APP/config.py\" >/dev/null; sed -n 's/^PORT"),
]

def main():
    mode, d = sys.argv[1], sys.argv[2]
    b, r = load(d)
    res = checks(b, r)
    bad = [n for n, ok in res if not ok]
    if mode == "check":
        for n in bad:
            print("GUARD FEHLER:", n)
        print("guard: %d Pruefungen, %d fehlerhaft" % (len(res), len(bad)))
        sys.exit(1 if bad else 0)
    if mode == "mutation":
        if bad:
            print("Mutationstest abgebrochen: Guard schon im Original rot:", bad[0]); sys.exit(1)
        surv = []; n_app = 0
        for name, f, a, new in MUT:
            tb, tr = b, r
            if f == "b":
                if a == "exit 1\nEOF_PLACEHOLDER":
                    a2 = b.rindex("exit 1\n"); tb = b[:a2] + "exit 0\n" + b[a2 + 7:]
                elif a not in b:
                    print("Mutation nicht anwendbar:", name); sys.exit(1)
                else:
                    tb = b.replace(a, new, 1)
            else:
                if a not in r:
                    print("Mutation nicht anwendbar:", name); sys.exit(1)
                tr = r.replace(a, new, 1)
            n_app += 1
            if all(ok for _, ok in checks(tb, tr)):
                surv.append(name)
        for s in surv:
            print("MUTATION UEBERSEHEN:", s)
        print("mutation: %d Mutationen, %d erkannt, %d uebersehen" % (n_app, n_app - len(surv), len(surv)))
        sys.exit(1 if surv else 0)

main()
RB_GUARD_EOF
EXPECT_st="7d6a3acb235567bf065f49767890bf5d010b47749bd85f84d490d4c1cb7b08b4"
mkdir -p "$W/selftest"
cat > "$W/selftest/selftest.sh" << 'RB_ST_EOF'
#!/bin/bash
# relBackup Selbsttest (Sandbox mit Fake-systemctl/-sudo/-systemd-run und einem echten Mini-HTTP-Dienst; nichts Echtes wird angefasst)
# Aufruf: selftest.sh <Ordner mit backup.sh restore.sh fake/*> <Arbeitsordner>
set -u
SRCD="$1"; W="$2"; FD="$SRCD/fake"
rm -rf "$W/world"; mkdir -p "$W/world"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
T="$W/world"; A="$T/home/fmg/prepper-dashboard"; D="$T/home/fmg/prepper-backups"; FS="$T/fs"
fail=0; nok=0
ck() { if eval "$2"; then nok=$((nok+1)); echo "  OK   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }
mkapp() {  # mkapp ROOT VERSION MODE
  local R="$1" V="$2" M="$3" P
  P="$R/home/fmg/prepper-dashboard"
  mkdir -p "$P"/{venv/lib,tools,__pycache__,sub/__pycache__,backups,secrets,archive,stick3-eeprom} "$R/home/fmg/prepper-backups"
  sed -e "s/@MODE@/$M/" -e "s/@VERSION@/$V/" "$FD/dashboard.py.tpl" > "$P/dashboard.py"
  printf 'PORT = %s\nKEY = "FAKE-SECRET-123"\n' "$PORT" > "$P/config.py"
  echo FAKE-SECRET-FILE > "$P/secrets/key.txt"; echo '{"a":1}' > "$P/sdr_config.json"
  echo x > "$P/venv/lib/big.so"; echo '#!/x' > "$P/venv/pyvenv.cfg"; echo c > "$P/__pycache__/x.pyc"; echo c > "$P/sub/__pycache__/y.pyc"
  echo b > "$P/backups/old.tgz"; echo z > "$P/w.zim"; echo b > "$P/dashboard.py.bak-x-1"; echo b > "$P/lagezentrum.db.bak-x-1"
  head -c 256 /dev/zero > "$P/stick3-eeprom/stick3-eeprom-x.bin"
  cp "$SRCD/backup.sh" "$SRCD/restore.sh" "$P/tools/"; chmod +x "$P/tools/"*.sh
  python3 - "$P/lagezentrum.db" "$V" << 'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA journal_mode=WAL"); c.execute("create table t(i integer, s text)")
c.executemany("insert into t values(?,?)", [(i, "row%d" % i) for i in range(3000)]); c.execute("insert into t values(-1,?)", ("VER-" + sys.argv[2],)); c.commit(); c.close()
PY
}
mkapp "$T" v-alt ok
mkdir -p "$FS" "$T/run"; python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.bind('$T/run/bus')"
echo running > "$FS/desired"; echo "0::/system.slice/prepper-dashboard.service" > "$FS/cg_dash"; echo "0::/user.slice/prepper-restore.service" > "$FS/cg_other"
export PREPPER_SELFTEST=1 PREPPER_APP="$A" PREPPER_BACKUPS="$D" PREPPER_MINFREE_KB=1
export PREPPER_SYSTEMCTL="$FD/systemctl" PREPPER_SYSTEMD_RUN="$FD/systemd-run" PREPPER_SUDO="$FD/sudo"
export PREPPER_HEALTH_S=20 PREPPER_STAB_S=1 PREPPER_KILL_WAIT_S=10 PREPPER_RESTART_WAIT_S=15 PREPPER_PORT="$PORT"
export FAKE_FS="$FS" FAKE_SVC=prepper-dashboard FAKE_UNIT=prepper-restore FAKE_DIR="$FD" FAKE_RESTART_DELAY=2 XDG_RUNTIME_DIR="$T/run" PREPPER_CGROUP_FILE="$FS/cg_other"
chmod +x "$FD"/*
setsid bash "$FD/supervisor.sh" "$FS" "$A" > /dev/null 2>&1 < /dev/null &
echo $! > "$FS/sup.pid"
cleanup() {
  kill "$(cat "$FS/sup.pid" 2>/dev/null)" 2>/dev/null
  for d in /proc/[0-9]*; do { tr '\0' '\n' < "$d/environ" | grep -qx "FAKE_FS=$FS" && kill -9 "${d#/proc/}"; } 2>/dev/null; done
}
trap cleanup EXIT
ver() { curl -s --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null; }
waitv() { local i; for ((i=0; i<$2*4; i++)); do [[ "$(ver)" == "$1" ]] && return 0; sleep 0.25; done; return 1; }
waitst() { local i s; for ((i=0; i<$1*2; i++)); do s="$(python3 -c "import json;print(json.load(open('$D/restore-status.json'))['state'])" 2>/dev/null)"; [[ "$s" == ok || "$s" == failed || "$s" == rolled-back ]] && { echo "$s"; return 0; }; sleep 0.5; done; echo timeout; }
treehash() { (cd "$A" && find . -type f -not -path './venv/*' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16); }
dbrows() { python3 -c "import sqlite3;print([r[0] for r in sqlite3.connect('$A/lagezentrum.db').execute(\"select s from t where i<0\")])" 2>/dev/null; }
mkarch() {  # mkarch VERSION MODE -> AID
  rm -rf "$W/var"; mkapp "$W/var" "$1" "$2"; sleep 1.1
  PREPPER_APP="$W/var/home/fmg/prepper-dashboard" bash "$SRCD/backup.sh" M "arch-$1" > /dev/null || echo "mkarch FEHLER"
  AID="$(python3 -c "
import glob, json
b = None
for p in glob.glob('$D/prepper-*-M.json'):
    d = json.load(open(p))
    if d.get('label') == 'arch-$1' and (b is None or p > b[0]): b = (p, d)
print(b[1]['id'])")"
}
dashcall() {
  python3 - "$A/tools/restore.sh" "$1" "$FS/cg_dash" << 'PY'
import os, subprocess, sys
env = dict(os.environ); env["FAKE_CG"] = "dash"; env["PREPPER_CGROUP_FILE"] = sys.argv[3]
r = subprocess.run([sys.argv[1], sys.argv[2]], timeout=90, capture_output=True, text=True, env=env)
print("RC=%d" % r.returncode); print((r.stdout + r.stderr).strip()[-300:])
PY
}
waitv v-alt 15 || { echo "SELBSTTEST: Fake-Dienst startet nicht"; cat "$FS/app.log" | head -5; exit 2; }

echo "-- 1) backup.sh: Ausschluesse, DB-Kopie, Rechte, Pruefsumme"
python3 - "$A/lagezentrum.db" << 'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1]); t0 = time.time(); n = 0
while time.time() - t0 < 3:
    c.execute("insert into t values(?,?)", (n + 100000, "live")); c.commit(); n += 1; time.sleep(0.01)
PY
WP=$!; sleep 0.3
out="$(bash "$A/tools/backup.sh" M "t es-t")"; rc=$?; wait $WP
J="$(ls "$D"/prepper-*-M.json | head -1)"; TG="${J%.json}.tgz"; L="$(tar -tzf "$TG")"
ck "rc 0 und Ausgabe OK (bei laufendem DB-Schreiber)" "[[ $rc == 0 && \"\$out\" == OK* ]]"
ck "venv, __pycache__, backups/, *.zim, *.bak-*, -wal/-shm nicht im Archiv" "! grep -qE '/venv|__pycache__|prepper-dashboard/backups|\.zim|\.bak-|db-(wal|shm)' <<< \"\$L\""
ck "config.py, secrets/, sdr_config.json, archive/, stick3-eeprom im Archiv" "grep -q 'prepper-dashboard/config.py' <<< \"\$L\" && grep -q secrets/key.txt <<< \"\$L\" && grep -q sdr_config.json <<< \"\$L\" && grep -q archive/ <<< \"\$L\" && grep -q stick3-eeprom <<< \"\$L\""
ck "lagezentrum.db genau einmal, Kopie besteht quick_check" "[[ \$(grep -cx 'prepper-dashboard/lagezentrum.db' <<< \"\$L\") == 1 ]] && mkdir -p $W/x && tar -xzf $TG -C $W/x prepper-dashboard/lagezentrum.db && python3 -c \"import sqlite3;print(sqlite3.connect('$W/x/prepper-dashboard/lagezentrum.db').execute('pragma quick_check').fetchone()[0])\" | grep -qx ok"
ck "json: ok, sha256 stimmt, db-quick_check ok, Name wie Schema" "python3 -c \"import json,hashlib,re;d=json.load(open('$J'));assert d['ok'] is True and d['sha256']==hashlib.sha256(open('$TG','rb').read()).hexdigest() and d['db'][0]['quick_check']=='ok' and re.fullmatch(r'prepper-\d{8}-\d{6}-M',d['id']) and d['label']=='tes-t'\""
ck "Archiv 600, Ordner 700" "[[ \$(stat -c %a $TG) == 600 && \$(stat -c %a $D) == 700 ]]"

echo "-- 2) restore.sh --dry-run aendert nichts"
mkarch v-neu ok; h0="$(treehash)"; p0="$(cat "$FS/pid")"
out="$(bash "$A/tools/restore.sh" --dry-run "$AID" 2>&1)"; rc=$?
ck "dry-run rc 0, DRY-RUN OK, Wege genannt" "[[ $rc == 0 && \"\$out\" == *'DRY-RUN OK'* && \"\$out\" == *ZUSAMMENFASSUNG* ]]"
ck "nichts veraendert, Dienst unveraendert, keine Reste" "[[ \$(treehash) == $h0 && \$(cat $FS/pid) == $p0 && \$(ver) == v-alt && ! -e $D/restore-status.json && -z \$(ls -A $T/home/fmg | grep -E 'stage|bak-restore') ]]"

echo "-- 3) Dashboard-Aufruf: koppelt sich ab, ueberlebt 'systemctl stop' (KillMode=control-group), stellt wieder her"
out="$(dashcall "$AID")"; echo "$out" | head -1 | sed 's/^/     /'
ck "Aufruf kehrt mit rc 0 zurueck ('OK gestartet')" "[[ \"\$out\" == RC=0* && \"\$out\" == *'OK gestartet'* ]]"
ck "Ergebnis ok, neuer Stand live (v-neu), DB aus Archiv, alter Ordner als bak-restore" "[[ \$(waitst 60) == ok ]] && waitv v-neu 15 && [[ \"\$(dbrows)\" == *VER-v-neu* && \"\$(dbrows)\" != *VER-v-alt* && -d \$(ls -d $A.bak-restore-* | head -1) ]]"
ck "venv (Hardlink) und *.zim uebernommen, Sicherung vorher (pre-restore) vorhanden" "[[ -f $A/venv/pyvenv.cfg && -f $A/w.zim ]] && ls $D/prepper-*-M.json | xargs grep -l pre-restore | grep -q ."

echo "-- 4) Stand startet nicht -> automatischer Rueckfall"
mkarch v-kaputt crash; out="$(dashcall "$AID")"
ck "Ergebnis rolled-back, vorheriger Stand (v-neu) laeuft wieder" "[[ \$(waitst 120) == rolled-back ]] && waitv v-neu 20 && [[ \"\$(dbrows)\" == *VER-v-neu* ]]"

echo "-- 5) stop/sudo verweigert (Restart=always) -> SIGTERM-Ausweg"
export FAKE_DENY=1; mkarch v-drei ok; out="$(dashcall "$AID")"
ck "Ergebnis ok ueber SIGTERM+Neustart, v-drei laeuft" "[[ \$(waitst 90) == ok && \$(python3 -c \"import json;print(json.load(open('$D/restore-status.json'))['stop_method'])\") == sigterm-restart ]] && waitv v-drei 15"
unset FAKE_DENY

echo "-- 6) kein Weg zum Abkoppeln -> Exit 3, nichts geaendert"
rm -f "$T/run/bus"; mkarch v-vier ok; h0="$(treehash)"; p0="$(cat "$FS/pid")"; rm -f "$FS/unit.pid"
out="$(dashcall "$AID")"
ck "rc 3, 'Nichts wurde geaendert', Dienst und Ordner unveraendert" "[[ \"\$out\" == RC=3* && \"\$out\" == *'Nichts wurde geaendert'* && \$(treehash) == $h0 && \$(cat $FS/pid) == $p0 ]]"

echo "-- 7) beschaedigtes Archiv -> abgelehnt vor jeder Aenderung"
python3 - "$D/$AID.tgz" << 'PY'
import sys
f = open(sys.argv[1], "r+b"); f.seek(200); b = f.read(1); f.seek(200); f.write(bytes([b[0] ^ 0xFF])); f.close()
PY
python3 -c "socket=__import__('socket');s=socket.socket(socket.AF_UNIX);s.bind('$T/run/bus')"
out="$(dashcall "$AID")"
ck "rc 1, Pruefsumme/gzip, nichts gestartet" "[[ \"\$out\" == RC=1* && ( \"\$out\" == *sha256* || \"\$out\" == *gzip* ) && \$(treehash) == $h0 ]]"
echo "SELBSTTEST: $nok OK, $fail FAIL"
exit $fail
RB_ST_EOF
EXPECT_f_dashboard_py_tpl="14ac7809009e0b2757b13771fb2ca63fba3816fc1fa5b11595338cd3928765f2"
mkdir -p "$W/new/fake"
cat > "$W/new/fake/dashboard.py.tpl" << 'RB_F_DASHBOARD_PY_TPL_EOF'
import http.server, os, re, socketserver, sys
MODE = "@MODE@"
VERSION = "@VERSION@"
d = os.path.dirname(os.path.abspath(__file__))
port = int(re.search(r"PORT\s*=\s*(\d+)", open(os.path.join(d, "config.py")).read()).group(1))
if MODE == "crash":
    sys.stderr.write("boom\n"); sys.exit(1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(500 if MODE == "500" else 200); self.end_headers(); self.wfile.write(VERSION.encode())
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True; daemon_threads = True
S(("127.0.0.1", port), H).serve_forever()
RB_F_DASHBOARD_PY_TPL_EOF
EXPECT_f_systemctl="db9fe1d76b6f812e3cd144e714115f8689e58e9b18b53feb3e4e501cf9ef6a14"
mkdir -p "$W/new/fake"
cat > "$W/new/fake/systemctl" << 'RB_F_SYSTEMCTL_EOF'
#!/bin/bash
# Fake-systemctl: Zustand in $FAKE_FS
a=(); for x in "$@"; do case "$x" in --no-ask-password|--user|--no-legend|--plain|--quiet|-q|--state=*) ;; *) a+=("$x");; esac; done
set -- "${a[@]}"
FS="${FAKE_FS:?}"; cmd="${1:-}"; shift
svc() { [[ "${1:-}" == "$FAKE_SVC" ]]; }
alive() { local p; p="$(cat "$1" 2>/dev/null || echo 0)"; [[ "$p" -gt 0 ]] && kill -0 "$p" 2>/dev/null; }
case "$cmd" in
  is-active)
    if svc "$1"; then alive "$FS/pid" && { echo active; exit 0; } || { echo inactive; exit 3; }
    elif [[ "$1" == "$FAKE_UNIT" ]]; then alive "$FS/unit.pid" && { echo active; exit 0; } || { echo inactive; exit 3; }
    else echo inactive; exit 3; fi ;;
  show)
    prop=""; for x in "$@"; do [[ "$x" == -p ]] && continue; [[ "$x" == --value ]] && continue; [[ "$x" == "$FAKE_SVC" ]] && continue; prop="$x"; done
    case "$prop" in
      MainPID) alive "$FS/pid" && cat "$FS/pid" || echo 0 ;;
      Restart) echo "${FAKE_RESTART:-always}" ;;
      *) echo "" ;;
    esac ;;
  stop)
    svc "$1" || exit 5
    if [[ "${FAKE_DENY:-0}" == 1 ]]; then echo "Failed to stop $1: Interactive authentication required." >&2; exit 1; fi
    echo stopped > "$FS/desired"
    setsid env -u FAKE_CG bash "$FAKE_DIR/killer.sh" "$FS" < /dev/null > /dev/null 2>&1 &
    wait $!; exit 0 ;;
  start)
    svc "$1" || exit 5
    if [[ "${FAKE_DENY:-0}" == 1 ]]; then echo "Failed to start $1: Interactive authentication required." >&2; exit 1; fi
    rm -f "$FS/started_once"; echo running > "$FS/desired"
    for i in $(seq 1 40); do alive "$FS/pid" && break; sleep 0.25; done
    exit 0 ;;
  list-units) exit 0 ;;
  *) echo "fake systemctl: $cmd nicht gebaut" >&2; exit 1 ;;
esac
RB_F_SYSTEMCTL_EOF
EXPECT_f_killer_sh="706e1768f7713bd5f7494a8bd4478d3774f692e99bc8b80ecfa70e2575336279"
mkdir -p "$W/new/fake"
cat > "$W/new/fake/killer.sh" << 'RB_F_KILLER_SH_EOF'
#!/bin/bash
# wie systemd bei KillMode=control-group: alle Prozesse dieser Fake-Welt mit Markierung FAKE_CG=dash beenden (SIGKILL), plus Hauptprozess
FS="$1"
for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  { e="$(tr "\0" "\n" < "$d/environ")"; grep -qx "FAKE_CG=dash" <<< "$e" && grep -qx "FAKE_FS=$FS" <<< "$e" && kill -9 "$p"; } 2>/dev/null
done
exit 0
RB_F_KILLER_SH_EOF
EXPECT_f_supervisor_sh="d70ec81a4c7c5c8a863b5d71a0d62ae0c54ac967ec3048955a8c370fe6ea1866"
mkdir -p "$W/new/fake"
cat > "$W/new/fake/supervisor.sh" << 'RB_F_SUPERVISOR_SH_EOF'
#!/bin/bash
# wie systemd Restart=always: haelt die App am Laufen solange desired=running; Neustart nach FAKE_RESTART_DELAY
FS="$1"; APP="$2"
al() { local p; p="$(cat "$FS/pid" 2>/dev/null || echo 0)"; [[ "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] && kill -0 "$p" 2>/dev/null; }
while :; do
  want="$(cat "$FS/desired" 2>/dev/null)"
  if [[ "$want" == running ]] && ! al; then
    if [[ -e "$FS/started_once" ]]; then sleep "${FAKE_RESTART_DELAY:-2}"; [[ "$(cat "$FS/desired")" == running ]] || continue; fi
    al && continue
    touch "$FS/started_once"
    ( cd "$APP" && FAKE_CG=dash exec python3 dashboard.py >> "$FS/app.log" 2>&1 ) &
    echo $! > "$FS/pid"
  fi
  sleep 0.3
done
RB_F_SUPERVISOR_SH_EOF
EXPECT_f_sudo="4a670c078963198a928a9ee97012741c59a8d7acb5fe46163fbc9de8e600f894"
mkdir -p "$W/new/fake"
cat > "$W/new/fake/sudo" << 'RB_F_SUDO_EOF'
#!/bin/bash
# Fake-sudo: nur mit FAKE_SUDO_ALLOW=1 erlaubt, sonst "Passwort noetig"
if [[ "${FAKE_SUDO_ALLOW:-0}" != 1 ]]; then echo "sudo: a password is required" >&2; exit 1; fi
args=("$@"); [[ "${args[0]:-}" == -n ]] && args=("${args[@]:1}")
if [[ "${args[0]:-}" == -l ]]; then exit 0; fi
exec "${args[@]}"
RB_F_SUDO_EOF
EXPECT_f_systemd_run="546f50515812301066c6b2d9cfb587587a40198b970a27f95ea117354360d96a"
mkdir -p "$W/new/fake"
cat > "$W/new/fake/systemd-run" << 'RB_F_SYSTEMD_RUN_EOF'
#!/bin/bash
# Fake-systemd-run: startet den Befehl abgekoppelt (ohne FAKE_CG, ohne geerbte Umgebung ausser --setenv), Einheit = Hintergrundprozess
FS="${FAKE_FS:?}"
user=0; unit=""; envs=(); cmd=()
for x in "$@"; do
  if [[ ${#cmd[@]} -gt 0 ]]; then cmd+=("$x"); continue; fi
  case "$x" in
    --user) user=1 ;;
    --unit=*) unit="${x#--unit=}" ;;
    --setenv=*) envs+=("${x#--setenv=}") ;;
    --collect|--quiet|--description=*|--uid=*|--gid=*) ;;
    -*) echo "fake systemd-run: Option $x unbekannt" >&2; exit 1 ;;
    *) cmd+=("$x") ;;
  esac
done
if [[ "${FAKE_RUN_FAIL:-0}" == 1 ]]; then echo "Failed to start transient service unit: Access denied" >&2; exit 1; fi
if [[ $user == 1 && "${FAKE_USER_FAIL:-0}" == 1 ]]; then echo "Failed to connect to user scope bus" >&2; exit 1; fi
p="$(cat "$FS/unit.pid" 2>/dev/null || echo 0)"
if [[ "$p" -gt 0 ]] && kill -0 "$p" 2>/dev/null; then echo "Failed to start transient service unit: Unit $unit.service was already loaded or has a fragment file." >&2; exit 1; fi
echo "$user" > "$FS/unit.user"
fk=(); while IFS= read -r l; do fk+=("$l"); done < <(env | grep -E "^FAKE_" | grep -v "^FAKE_CG=")
setsid env -i PATH="$PATH" HOME="$HOME" "${fk[@]}" "${envs[@]}" PREPPER_CGROUP_FILE="$FS/cg_other" "${cmd[@]}" >> "$FS/unit.out" 2>&1 < /dev/null &
echo $! > "$FS/unit.pid"
exit 0
RB_F_SYSTEMD_RUN_EOF
for pair in EXPECT_backup:new/backup.sh EXPECT_restore:new/restore.sh EXPECT_baseb:base/backup.sh EXPECT_baser:base/restore.sh EXPECT_guard:guardrel.py EXPECT_st:selftest/selftest.sh EXPECT_f_dashboard_py_tpl:new/fake/dashboard.py.tpl EXPECT_f_systemctl:new/fake/systemctl EXPECT_f_killer_sh:new/fake/killer.sh EXPECT_f_supervisor_sh:new/fake/supervisor.sh EXPECT_f_sudo:new/fake/sudo EXPECT_f_systemd_run:new/fake/systemd-run; do v=${pair%%:*}; f=${pair#*:}; [[ "$(sha256sum "$W/$f" | cut -d' ' -f1)" == "${!v}" ]] || { echo "STOP: eingebettete Datei $f beschaedigt (sha256) - nichts geaendert"; exit 1; }; done
chmod +x "$W/new/fake/"* "$W/new/backup.sh" "$W/new/restore.sh" "$W/selftest/selftest.sh"
# ---------- 0) Voraussetzungen ----------
for c in python3 curl tar gzip flock sha256sum diff; do command -v "$c" >/dev/null 2>&1 || { echo "STOP: $c fehlt - nichts geaendert"; exit 1; }; done
[[ -d "$TOOLS" ]] || { echo "STOP: $TOOLS fehlt - nichts geaendert"; exit 1; }
for x in "$BF" "$RF"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt in $TOOLS - nichts geaendert"; exit 1; }; done
[[ "$(systemctl is-active prepper-dashboard 2>/dev/null || true)" == active ]] || { echo "STOP: prepper-dashboard ist nicht aktiv - nichts geaendert"; exit 1; }
# ---------- 1) Basis (streng) ----------
s16() { sha256sum "$1" | cut -c1-16; }
B16=$(s16 "$BF"); R16=$(s16 "$RF")
echo "Basis backup.sh sha16 $B16 ($(wc -l < "$BF") Zeilen, erwartet $KNOWN_BASE_B16 oder neu $NEW_B16)"
echo "Basis restore.sh sha16 $R16 ($(wc -l < "$RF") Zeilen, erwartet $KNOWN_BASE_R16 oder neu $NEW_R16)"
bad=""
[[ "$B16" == "$KNOWN_BASE_B16" || "$B16" == "$NEW_B16" ]] || bad="$bad tools/backup.sh (sha16 $B16);"
[[ "$R16" == "$KNOWN_BASE_R16" || "$R16" == "$NEW_R16" ]] || bad="$bad tools/restore.sh (sha16 $R16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  [[ "$B16" == "$KNOWN_BASE_B16" || "$B16" == "$NEW_B16" ]] || { echo "--- Diff backup.sh (erwartete Basis -> Pi), erste 60 Zeilen:"; diff -u "$W/base/backup.sh" "$BF" | head -60 || true; }
  [[ "$R16" == "$KNOWN_BASE_R16" || "$R16" == "$NEW_R16" ]] || { echo "--- Diff restore.sh (erwartete Basis -> Pi), erste 60 Zeilen:"; diff -u "$W/base/restore.sh" "$RF" | head -60 || true; }
  echo "      Nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
NEED_B=0; NEED_R=0
[[ "$B16" == "$NEW_B16" ]] || NEED_B=1
[[ "$R16" == "$NEW_R16" ]] || NEED_R=1
echo "OK Basis bekannt (backup.sh: $([[ $NEED_B == 1 ]] && echo 'wird ersetzt' || echo 'schon neu'), restore.sh: $([[ $NEED_R == 1 ]] && echo 'wird ersetzt' || echo 'schon neu'))"
# ---------- 2) Neue Dateien pruefen (Trockenlauf, noch keine Aenderung am Pi) ----------
for f in backup.sh restore.sh; do
  [[ "$(sha256sum "$W/new/$f" | cut -d' ' -f1)" == "$(eval echo "\$EXPECT_${f%.sh}")" ]] || { echo "STOP: eingebettete Datei $f beschaedigt (sha256) - nichts geaendert"; exit 1; }
  bash -n "$W/new/$f" || { echo "STOP: bash -n $f - nichts geaendert"; exit 1; }
done
[[ "$(s16 "$W/new/backup.sh")" == "$NEW_B16" && "$(s16 "$W/new/restore.sh")" == "$NEW_R16" ]] || { echo "STOP: sha16 der neuen Dateien stimmt nicht mit dem Skript ueberein - nichts geaendert"; exit 1; }
echo "OK bash -n backup.sh, restore.sh; sha256 der eingebetteten Dateien stimmt"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$W/new/backup.sh" "$W/new/restore.sh" > "$W/sc.log" 2>&1 && echo "OK shellcheck ohne Warnung" || { head -20 "$W/sc.log"; echo "STOP: shellcheck - nichts geaendert"; exit 1; }
else
  echo "Hinweis: shellcheck nicht installiert - uebersprungen (bash -n und die Selbsttests laufen trotzdem)"
fi
python3 "$W/guardrel.py" check "$W/new" > "$W/guard.log" 2>&1 && echo "OK $(tail -1 "$W/guard.log")" || { cat "$W/guard.log"; echo "STOP: Guard - nichts geaendert"; exit 1; }
python3 "$W/guardrel.py" mutation "$W/new" > "$W/mut.log" 2>&1 && echo "OK $(tail -1 "$W/mut.log")" || { cat "$W/mut.log"; echo "STOP: Mutationstest der Pruefungen - nichts geaendert"; exit 1; }
echo "Selbsttest in der Sandbox (Fake-systemctl/-sudo/-systemd-run, Mini-HTTP-Dienst, ca. 1-2 Minuten) ..."
bash "$W/selftest/selftest.sh" "$W/new" "$W/st" > "$W/selftest.log" 2>&1 && echo "OK $(tail -1 "$W/selftest.log") (Sandbox, nichts Echtes angefasst)" || { grep -E "FAIL|SELBSTTEST" "$W/selftest.log" | head -20; echo "STOP: Selbsttest in der Sandbox - nichts geaendert"; exit 1; }
# ---------- 3) Zustand vorher ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
PI_BEFORE=$(systemctl show -p MainPID --value prepper-dashboard 2>/dev/null || echo 0)
if [[ "$MODE_ARG" == trocken ]]; then
  echo "TROCKENLAUF beendet: alle Pruefungen und Selbsttests gruen, NICHTS am Pi geaendert. Ohne 'trocken' aufrufen zum Einspielen."
  exit 0
fi
if [[ $NEED_B == 0 && $NEED_R == 0 ]]; then echo "OK relBackup ist schon installiert - nur Nachpruefung (keine Dateiaenderung, kein Neustart)"; fi
# ---------- 4) Installieren (Strg-C wird ignoriert, bis fertig) ----------
trap '' INT
BAKB="$BF.bak-relbackup-$TS"; BAKR="$RF.bak-relbackup-$TS"; LZB=""
INSTALLED_B=0; INSTALLED_R=0
rb() {
  echo "FEHLER: $1 - Rueckgaengig"
  [[ $INSTALLED_B == 1 && -f "$BAKB" ]] && { cp -p "$BAKB" "$BF.rb" && mv -f "$BF.rb" "$BF" && echo "  backup.sh zurueck"; }
  [[ $INSTALLED_R == 1 && -f "$BAKR" ]] && { cp -p "$BAKR" "$RF.rb" && mv -f "$RF.rb" "$RF" && echo "  restore.sh zurueck"; }
  echo "  Dienste wurden nie angefasst (kein Neustart). Bitte diese Ausgabe an Grok schicken."
  exit 1
}
if [[ $NEED_B == 1 || $NEED_R == 1 ]]; then
  if [[ -f "$LZ" ]]; then
    LZB="$LZ.bak-relbackup-$TS"
    python3 - "$LZ" "$LZB" << 'PYB' || { echo "STOP: SQLite-Sicherung fehlgeschlagen - nichts geaendert"; exit 1; }
import sqlite3, sys
s = sqlite3.connect(sys.argv[1], timeout=30); d = sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()
PYB
    chmod 600 "$LZB" 2>/dev/null || true
  fi
  [[ $NEED_B == 1 ]] && { cp -p "$BF" "$BAKB" || { echo "STOP: Sicherung backup.sh fehlgeschlagen - nichts geaendert"; exit 1; }; }
  [[ $NEED_R == 1 ]] && { cp -p "$RF" "$BAKR" || { echo "STOP: Sicherung restore.sh fehlgeschlagen - nichts geaendert"; exit 1; }; }
  if [[ $NEED_B == 1 ]]; then
    cp "$W/new/backup.sh" "$BF.new" && chmod --reference="$BAKB" "$BF.new" && chmod +x "$BF.new" && mv -f "$BF.new" "$BF" || rb "installieren backup.sh"
    INSTALLED_B=1
  fi
  if [[ $NEED_R == 1 ]]; then
    cp "$W/new/restore.sh" "$RF.new" && chmod --reference="$BAKR" "$RF.new" && chmod +x "$RF.new" && mv -f "$RF.new" "$RF" || rb "installieren restore.sh"
    INSTALLED_R=1
  fi
  [[ "$(s16 "$BF")" == "$NEW_B16" && "$(s16 "$RF")" == "$NEW_R16" ]] || rb "sha16 nach dem Installieren stimmt nicht"
  bash -n "$BF" && bash -n "$RF" || rb "bash -n nach dem Installieren"
  # keepLast
  for pat in "$BF.bak-relbackup-*" "$RF.bak-relbackup-*" "$LZ.bak-relbackup-*"; do
    ls -1t $pat 2>/dev/null | tail -n +$((KEEP_LAST+1)) | while read -r o; do rm -f -- "$o"; done || true
  done
  echo "OK installiert: backup.sh $(s16 "$BF"), restore.sh $(s16 "$RF") (atomar per mv; Backups *.bak-relbackup-$TS, SQLite: ${LZB:+$(basename "$LZB")}, behalten: letzte $KEEP_LAST)"
fi
# ---------- 5) Nachpruefung am echten System (nur lesend am Projekt: eine echte Sicherung in $DEST, Trockenlauf der Wiederherstellung) ----------
echo "Echte Sicherung mit dem neuen backup.sh (liest den Projektordner, schreibt nur nach $DEST) ..."
BOUT=$("$BF" M relbackup 2>&1) && BRC=0 || BRC=$?
echo "  $BOUT"
[[ "$BRC" == 0 && "$BOUT" == OK* ]] || rb "backup.sh liefert Fehler (rc $BRC)"
J=$(ls -1t "$DEST"/prepper-*-M.json | head -1); TG="${J%.json}.tgz"
python3 - "$J" "$TG" > "$W/bj.log" 2>&1 << 'PYC' || { cat "$W/bj.log"; rb "Sicherungs-json/-Archiv fehlerhaft"; }
import hashlib, json, os, sys
d = json.load(open(sys.argv[1])); tg = sys.argv[2]
assert d["ok"] is True and d["label"] == "relbackup", d
assert d["sha256"] == hashlib.sha256(open(tg, "rb").read()).hexdigest()
assert all(x["quick_check"] == "ok" for x in d["db"]) and d["db"], d["db"]
assert oct(os.stat(tg).st_mode & 0o777) == "0o600"
print("ok bytes=%d members=%s db=%s" % (d["bytes"], d["members"], ",".join(x["name"] for x in d["db"])))
PYC
echo "  $(cat "$W/bj.log")"
NV=$(tar -tzf "$TG" | grep -c -E '/venv/|__pycache__|\.zim$|\.bak-|\.db-(wal|shm)$' || true)
[[ "$NV" == 0 ]] && echo "OK Archiv ohne venv/__pycache__/*.zim/*.bak-*/-wal/-shm ($(du -h "$TG" | cut -f1) statt bisher rund 170-180 MB; Rechte 600, Ordner $(stat -c %a "$DEST"))" || rb "Archiv enthaelt noch $NV unerwuenschte Eintraege"
echo "Trockenlauf der Wiederherstellung mit diesem Archiv (stoppt/tauscht/sichert nichts; sudo-Ticket wird vorher verworfen, damit die Wege ehrlich geprueft werden) ..."
sudo -k 2>/dev/null || true
ID=$(basename "${TG%.tgz}")
DOUT=$(bash "$RF" --dry-run "$ID" 2>&1) && DRC=0 || DRC=$?
echo "$DOUT" | sed 's/^/  /'
[[ "$DRC" == 0 && "$DOUT" == *"DRY-RUN OK"* ]] || rb "restore.sh --dry-run schlaegt fehl (rc $DRC)"
[[ -z "$(ls -A "$(dirname "$DASH_DIR")" 2>/dev/null | grep -E 'restore-stage' || true)" ]] || rb "Arbeitsordner vom Trockenlauf nicht aufgeraeumt"
# ---------- 6) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rb "Seite/API antwortet schlechter als vorher"
systemctl is-active --quiet prepper-dashboard || rb "prepper-dashboard laeuft nicht mehr"
PI_AFTER=$(systemctl show -p MainPID --value prepper-dashboard 2>/dev/null || echo 0)
[[ "$PI_BEFORE" == "$PI_AFTER" ]] && echo "OK prepper-dashboard unveraendert aktiv (gleicher Prozess $PI_AFTER, kein Neustart)" || rb "prepper-dashboard wurde neu gestartet ($PI_BEFORE -> $PI_AFTER)"
echo "OK keine Python-Datei geaendert (Skripte: nur tools/backup.sh, tools/restore.sh)"
echo
echo "=== relBackup FERTIG ($COMMIT_ARG) ==="
echo "backup.sh $(s16 "$BF")  restore.sh $(s16 "$RF")  | neues Archiv: $ID ($(du -h "$TG" | cut -f1))"
[[ -f "$BAKB" ]] && echo "Rueckgaengig: cp -p $BAKB $BF"
[[ -f "$BAKR" ]] && echo "Rueckgaengig: cp -p $BAKR $RF"
echo "Der Dashboard-Knopf 'Wiederherstellen' ist unveraendert. Hinweise zu den Wegen: siehe ZUSAMMENFASSUNG-Zeilen oben."
