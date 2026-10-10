#!/bin/bash
set -euo pipefail
# bakAufraeumen: Backups (*.bak*) in /home/fmg/prepper-dashboard aufraeumen.
# Standard = TROCKENLAUF (zeigt nur). Behalten: je Basisdatei die neuesten 3, dazu IMMER die Backups der
# heutigen Patches (funkharden, fh2, fh3, escfix, m1f, pegtrend, alltime, archive, firmskeep) zusaetzlich. rtl433 bleibt unberuehrt.
#   bash x.sh <commit8>                      Trockenlauf
#   bash x.sh <commit8> loeschen             VERSCHIEBEN nach /home/fmg/prepper-bak-archiv/<zeit>/ (umkehrbar)
#   bash x.sh <commit8> loeschen endgueltig  wirklich loeschen
# Kein Neustart, kein Netz, sendet nichts. Nur Dateien direkt im Ordner (keine Unterordner).
COMMIT_ARG="${1:-unbekannt}"
MODE="${2:-trocken}"
HARD="${3:-}"
DASH_DIR="/home/fmg/prepper-dashboard"
ARCH_ROOT="/home/fmg/prepper-bak-archiv"
KEEP_N="${KEEP_N:-3}"
TS=$(date +%Y%m%d-%H%M%S)
case "$MODE" in trocken|loeschen) ;; *) echo "STOP: zweites Argument nur loeschen (oder leer) - nichts geaendert"; exit 1;; esac
if [[ -n "$HARD" && "$HARD" != "endgueltig" ]]; then echo "STOP: drittes Argument nur endgueltig - nichts geaendert"; exit 1; fi
[[ -d "$DASH_DIR" ]] || { echo "STOP: $DASH_DIR fehlt"; exit 1; }
echo "=== bakAufraeumen $COMMIT_ARG, Modus: $MODE${HARD:+ $HARD}, behalte je Basisdatei $KEEP_N + heutige Patch-Backups ==="
PLAN=/tmp/bak-aufraeumen-plan.txt
python3 - "$DASH_DIR" "$KEEP_N" "$PLAN" << 'PY'
import os, re, sys, time
d, keep_n, plan = sys.argv[1], int(sys.argv[2]), sys.argv[3]
PROTECT = re.compile(r"\.bak[-_.]?(funkharden|fh2|fh3|escfix|m1f|pegtrend|alltime|archive|firmskeep)\b", re.I)
groups = {}
skipped = []
now = time.time()
for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    i = name.find(".bak")
    if i <= 0 or os.path.islink(p) or not os.path.isfile(p):
        continue
    if "rtl433" in name.lower() or "rtl_433" in name.lower():
        skipped.append(name); continue
    st = os.stat(p)
    groups.setdefault(name[:i], []).append((st.st_mtime, name, st.st_size))
total = sum(len(v) for v in groups.values())
dele, keepc, prot, freed = [], 0, 0, 0
lines = []
for base in sorted(groups):
    items = sorted(groups[base], reverse=True)
    k, x = [], []
    normal = 0
    for mt, name, sz in items:
        if PROTECT.search(name):
            k.append(name); prot += 1
        elif normal < keep_n or now - mt < 600:
            k.append(name); normal += 1
        else:
            x.append((name, sz))
    keepc += len(k)
    dele.extend(x)
    freed += sum(s for _, s in x)
    lines.append((base, len(items), len(k), x))
print("Backups gefunden: %d in %d Basisdateien (rtl433 unberuehrt: %d)" % (total, len(groups), len(skipped)))
print("%-34s %6s %8s %7s" % ("Basisdatei", "gesamt", "bleiben", "weg"))
for base, n, k, x in lines:
    print("%-34s %6d %8d %7d" % (base[:34], n, k, len(x)))
print("SUMME: bleiben %d (davon %d heutige Patch-Backups), weg %d, frei werden %.1f MB" % (keepc, prot, len(dele), freed / 1048576.0))
if dele:
    print("--- Liste weg (kurz: Basis: Endungen) ---")
    for base, n, k, x in lines:
        if x:
            sfx = " ".join(name[len(base):] for name, _ in x)
            out = "%s: %s" % (base, sfx)
            while out:
                print(out[:150]); out = "   " + out[150:] if len(out) > 150 else ""
with open(plan, "w") as f:
    for name, _ in dele:
        f.write(name + "\n")
PY
N=$(wc -l < "$PLAN")
if [[ "$MODE" == "trocken" ]]; then
  echo "TROCKENLAUF - nichts geaendert. Verschieben mit zweitem Argument loeschen."
  echo "COMMIT $COMMIT_ARG bakAufraeumen=trocken weg=$N"
  exit 0
fi
if [[ "$N" -eq 0 ]]; then echo "Nichts zu tun."; echo "COMMIT $COMMIT_ARG bakAufraeumen=$MODE weg=0"; exit 0; fi
FREE0=$(df -B1M --output=avail "$DASH_DIR" | tail -1 | tr -d ' ')
moved=0; gone=0
if [[ "$HARD" == "endgueltig" ]]; then
  while IFS= read -r n; do
    [[ -n "$n" && "$n" == *.bak* && "$n" != */* ]] || continue
    rm -f -- "$DASH_DIR/$n" && gone=$((gone + 1))
  done < "$PLAN"
  echo "ENDGUELTIG geloescht: $gone Dateien"
else
  DEST="$ARCH_ROOT/$TS"
  mkdir -p "$DEST"
  cp "$PLAN" "$DEST/LISTE.txt"
  while IFS= read -r n; do
    [[ -n "$n" && "$n" == *.bak* && "$n" != */* ]] || continue
    [[ -e "$DEST/$n" ]] && continue
    mv -n -- "$DASH_DIR/$n" "$DEST/$n" && moved=$((moved + 1))
  done < "$PLAN"
  echo "VERSCHOBEN: $moved Dateien nach $DEST (Liste in LISTE.txt)"
  echo "Zurueckholen: cd $DEST und mv -n Dateinamen aus LISTE.txt nach $DASH_DIR"
  SAME=$(stat -c %d "$DASH_DIR"); SAME2=$(stat -c %d "$DEST")
  [[ "$SAME" == "$SAME2" ]] && echo "Hinweis: gleiche Karte - Platz wird erst frei, wenn $ARCH_ROOT spaeter geloescht wird"
fi
REST=$(find "$DASH_DIR" -maxdepth 1 -type f -name '*.bak*' | wc -l)
echo "Backups im Dashboard-Ordner jetzt: $REST, frei vorher ${FREE0} MB, jetzt $(df -B1M --output=avail "$DASH_DIR" | tail -1 | tr -d ' ') MB"
echo "COMMIT $COMMIT_ARG bakAufraeumen=$MODE${HARD:+-$HARD} weg=$N"
