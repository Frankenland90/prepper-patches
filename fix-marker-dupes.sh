#!/usr/bin/env bash
# fix-marker-dupes.sh — pagesSplit1/2/3 und pegelSplit je Datei.
# Mehr als 1x und nur identische Kommentarzeilen: weitere Zeilen weg, erste bleibt.
# Ganzer Codeblock doppelt oder Zeilen nicht identisch: nichts aendern, STOP.
# Ueberall hoechstens 1x: "nichts zu tun", Exit 0.
# shellcheck disable=SC2015
set -euo pipefail
export TZ=Europe/Berlin
export PYTHONDONTWRITEBYTECODE=1
APP="${MARKERFIX_APP:-/home/fmg/prepper-dashboard}"

rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }

plan() {
  python3 - "$1" "$2" << 'PY'
import pathlib, sys
app = pathlib.Path(sys.argv[1])
emit = pathlib.Path(sys.argv[2])
names = ("pagesSplit1", "pagesSplit2", "pagesSplit3", "pegelSplit")
files = ("dashboard.py", "lage_pages.py")

def hits(text, name):
    needle = "# ===== %s:" % name
    return [i for i, line in enumerate(text.splitlines(keepends=True)) if needle in line]

def code_from(lines, idx, limit=None):
    seq = []
    j = idx + 1
    while j < len(lines):
        if limit is not None and j >= limit:
            break
        s = lines[j].strip()
        j += 1
        if s and not s.startswith("#"):
            seq.append(s)
    return seq

def comments_only_between(lines, a, b):
    for k in range(a + 1, b):
        s = lines[k].strip()
        if s and not s.startswith("#"):
            return False
    return True

stops = []
plans = []
for fn in files:
    path = app / fn
    if not path.is_file():
        print("STOP")
        print("%s fehlt" % fn)
        sys.exit(2)
    raw = path.read_text(encoding="utf-8")
    lines = raw.splitlines(keepends=True)
    drop = set()
    file_stop = False
    for name in names:
        idx = hits(raw, name)
        if len(idx) <= 1:
            continue
        chosen = [lines[i] for i in idx]
        if not all(x.strip().startswith("#") for x in chosen):
            stops.append("%s: %s steht nicht nur als Kommentarzeile" % (fn, name))
            file_stop = True
            continue
        if len({x.rstrip("\r\n") for x in chosen}) != 1:
            stops.append("%s: %s-Kommentarzeilen sind nicht identisch" % (fn, name))
            file_stop = True
            continue
        blocked = False
        for a, b in zip(idx, idx[1:]):
            if comments_only_between(lines, a, b):
                continue
            between = code_from(lines, a, b)
            after = code_from(lines, b)
            if len(between) >= 2 and between == after[:len(between)]:
                stops.append("%s: %s mehrfach und der folgende Codeblock ist doppelt" % (fn, name))
                blocked = True
                break
            if len(after) >= 2 and after[:2] == between[:2]:
                stops.append("%s: %s mehrfach und der folgende Codeblock ist doppelt" % (fn, name))
                blocked = True
                break
        if blocked:
            file_stop = True
            continue
        drop.update(idx[1:])
    if file_stop:
        continue
    if drop:
        (emit / fn).write_text("".join(line for i, line in enumerate(lines) if i not in drop), encoding="utf-8")
        plans.append((fn, len(drop)))
if stops:
    print("STOP")
    for s in stops:
        print(s)
    sys.exit(2)
if not plans:
    print("NOOP")
    sys.exit(0)
print("FIX")
for fn, n in plans:
    print("%s %d" % (fn, n))
PY
}

compile_ok() {
  local f="$1" pyc
  pyc=$(mktemp)
  if python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$f" "$pyc"; then
    rm -f "$pyc"
    return 0
  fi
  rm -f "$pyc"
  return 1
}

if [[ "${1:-}" == "--selftest" ]]; then
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT
  python3 - "$T" << 'PY'
import pathlib, sys
t = pathlib.Path(sys.argv[1])
M = {
    "pagesSplit1": "# ===== pagesSplit1: Vorlage der ADS-B-Seite kommt aus lage_pages.py =====",
    "pagesSplit2": "# ===== pagesSplit2: Seitenvorlagen PAGE4 kommen aus lage_pages.py =====",
    "pagesSplit3": "# ===== pagesSplit3: Seitenvorlagen PAGE1 kommen aus lage_pages.py =====",
    "pegelSplit": "# ===== pegelSplit: Seitenvorlagen PAGE_PEGEL kommen aus lage_pages.py =====",
}
L = {
    "pagesSplit1": "# ===== pagesSplit1: Seitenvorlagen aus dashboard.py =====",
    "pagesSplit2": "# ===== pagesSplit2: Seitenvorlagen PAGE4 verschoben =====",
    "pagesSplit3": "# ===== pagesSplit3: Seitenvorlagen PAGE1 verschoben =====",
    "pegelSplit": "# ===== pegelSplit: Seitenvorlagen PAGE_PEGEL verschoben =====",
}
def put(name, dash):
    p = t / name
    p.mkdir()
    (p / "dashboard.py").write_text(dash, encoding="utf-8")
    (p / "lage_pages.py").write_text("# -*- coding: utf-8 -*-\ny = 2\n" + "\n".join(L.values()) + "\n", encoding="utf-8")
put("noop", "# -*- coding: utf-8 -*-\nx = 1\n" + "\n".join(M.values()) + "\n")
put("kommentar", "# -*- coding: utf-8 -*-\n%s\n%s\nx = 1\n%s\n" % (M["pagesSplit1"], M["pagesSplit1"], "\n".join(M[k] for k in ("pagesSplit2", "pagesSplit3", "pegelSplit"))))
block = M["pagesSplit1"] + "\nfrom lage_pages import page_adsb as _lp_page_adsb\nPAGE_ADSB = _lp_page_adsb\n"
put("block", "# -*- coding: utf-8 -*-\n" + block + "\n" + block + "x = 1\n")
put("ungleich", "# -*- coding: utf-8 -*-\n%s\n# ===== pagesSplit1: andere Zeile =====\nx = 1\n" % M["pagesSplit1"])
PY
  run() { MARKERFIX_APP="$1" MARKERFIX_NO_RESTART=1 MARKERFIX_IGNORE_WINDOW=1 bash "$0"; }
  bad=0
  set +e
  o1=$(run "$T/noop" 2>&1); e1=$?
  o2=$(run "$T/kommentar" 2>&1); e2=$?
  o3=$(run "$T/block" 2>&1); e3=$?
  o4=$(run "$T/ungleich" 2>&1); e4=$?
  set -e
  [[ "$e1" == 0 && "$o1" == *"nichts zu tun"* ]] || { echo "SELFTEST noop exit $e1"; printf '%s\n' "$o1"; bad=1; }
  c2=$(grep -c '^# ===== pagesSplit1:' "$T/kommentar/dashboard.py" || true)
  [[ "$e2" == 0 && "$c2" == 1 ]] || { echo "SELFTEST kommentar exit $e2 count $c2"; printf '%s\n' "$o2"; bad=1; }
  compgen -G "$T/kommentar/dashboard.py.bak-markerfix-*" >/dev/null || { echo "SELFTEST backup fehlt"; bad=1; }
  grep -q '^x = 1$' "$T/kommentar/dashboard.py" || { echo "SELFTEST code weg"; bad=1; }
  c3=$(grep -c 'pagesSplit1:' "$T/block/dashboard.py" || true)
  [[ "$e3" == 2 && "$o3" == *"STOP"* && "$c3" == 2 ]] || { echo "SELFTEST block exit $e3 count $c3"; printf '%s\n' "$o3"; bad=1; }
  compgen -G "$T/block/dashboard.py.bak-markerfix-*" >/dev/null && { echo "SELFTEST block hat Backup geschrieben"; bad=1; }
  c4=$(grep -c 'pagesSplit1:' "$T/ungleich/dashboard.py" || true)
  [[ "$e4" == 2 && "$c4" == 2 ]] || { echo "SELFTEST ungleich exit $e4 count $c4"; printf '%s\n' "$o4"; bad=1; }
  [[ "$bad" == 0 ]] || exit 1
  echo "SELFTEST ok"
  exit 0
fi

[[ -f "$APP/dashboard.py" && -f "$APP/lage_pages.py" ]] || { echo "STOP: dashboard.py oder lage_pages.py fehlt in $APP - nichts geaendert"; exit 1; }
command -v python3 >/dev/null || { echo "STOP: python3 fehlt - nichts geaendert"; exit 1; }

EMIT=$(mktemp -d)
trap 'rm -rf "$EMIT"' EXIT
set +e
out=$(plan "$APP" "$EMIT" 2>&1)
rc=$?
set -e
if [[ "$rc" == 2 ]]; then
  printf '%s\n' "$out"
  echo "STOP: nichts geaendert"
  exit 2
fi
if [[ "$rc" != 0 ]]; then
  printf '%s\n' "$out"
  echo "STOP: Plan fehlgeschlagen - nichts geaendert"
  exit 1
fi
if [[ "$out" == NOOP ]]; then
  echo "nichts zu tun"
  exit 0
fi
if [[ "$out" != FIX* ]]; then
  printf '%s\n' "$out"
  echo "STOP: unklarer Plan - nichts geaendert"
  exit 1
fi

if [[ "${MARKERFIX_IGNORE_WINDOW:-0}" != 1 ]]; then
  s0=$(rssec 0); s1=$(rssec 300)
  if rswin "$s0" || rswin "$s1"; then
    echo "STOP: Neustart-Sperre $(rshm "$s0") Uhr Berlin (HH:50 bis HH:04 inklusive Vorlauf) - nichts geaendert"
    exit 2
  fi
fi

TS=$(date +%Y%m%d-%H%M%S)
changed=()
backups=()
restore() {
  local i
  for i in "${!changed[@]}"; do
    cp -a "${backups[$i]}" "${changed[$i]}"
  done
}
while read -r fn n; do
  [[ "$fn" == FIX ]] && continue
  [[ -n "$fn" ]] || continue
  src="$APP/$fn"
  bak="$src.bak-markerfix-$TS"
  cp -a "$src" "$bak"
  cp -a "$EMIT/$fn" "$src"
  changed+=("$src")
  backups+=("$bak")
  echo "geaendert: $fn ($n Kommentarzeile(n) entfernt), Backup $(basename "$bak")"
done <<< "$out"

fail=0
for f in "${changed[@]}"; do
  if ! compile_ok "$f"; then
    echo "py_compile fehlgeschlagen: $f"
    fail=1
  fi
done
if [[ "$fail" == 1 ]]; then
  restore
  echo "ROLLBACK: Backup zurueckgespielt, nichts bleibt geaendert"
  exit 1
fi
echo "py_compile ok"

if [[ "${MARKERFIX_NO_RESTART:-0}" == 1 ]]; then
  echo "Neustart ausgelassen"
  exit 0
fi
if sudo systemctl restart prepper-dashboard.service; then
  echo "prepper-dashboard neu gestartet"
  exit 0
fi
restore
echo "ROLLBACK: Neustart fehlgeschlagen, Backup zurueckgespielt"
exit 1
