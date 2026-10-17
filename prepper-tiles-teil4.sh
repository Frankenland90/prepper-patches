#!/bin/bash
# prepper-tiles-teil4.sh - Offline-Kartenkacheln fuer /karte (BND-Prepper, Teil 4)
# Quelle: BKG TopPlusOpen (WMTS, Web Mercator), Lizenz dl-de/by-2-0 - Offline-Speicherung erlaubt.
# Rund um Kalchreuth: Zoom 0-10 im Umkreis 200 km, Zoom 11-13 im Umkreis 60 km.
# Fortsetzbar (vorhandene Kacheln werden uebersprungen), hoeflich (ca. 2 Abrufe/s, eigener User-Agent),
# atomar (erst .part, dann umbenennen), Strg-C sicher. Aendert nichts an Diensten, Code oder secrets.
# Aufruf: bash prepper-tiles-teil4.sh            (zeigt Umfang, fragt nach)
#         bash prepper-tiles-teil4.sh --probe    (nur Umfang anzeigen, nichts laden)
#         bash prepper-tiles-teil4.sh --ja       (ohne Rueckfrage)
set -u
DASH_DIR="/home/fmg/prepper-dashboard"
OWNER="fmg"
MODE="frage"
for a in "$@"; do
  case "$a" in
    --probe|--dry-run|probe) MODE="probe" ;;
    --ja|--yes|-y) MODE="ja" ;;
    [0-9a-f]*) : ;;
    *) echo "Unbekannte Option: $a (erlaubt: --probe, --ja)"; exit 2 ;;
  esac
done
[[ -d "$DASH_DIR" ]] || { echo "STOP: $DASH_DIR fehlt"; exit 1; }
PY=/usr/bin/python3
[[ -x "$PY" ]] || PY=$(command -v python3)
[[ -n "$PY" ]] || { echo "STOP: python3 fehlt"; exit 1; }
TPY=$(mktemp /tmp/prepper-tiles-XXXXXX.py) || { echo "STOP: mktemp fehlgeschlagen"; exit 1; }
trap 'rm -f "$TPY"' EXIT
cat > "$TPY" << 'PYEOF'
import sys, os, math, time, json, datetime, shutil, signal, urllib.request, urllib.error

DASH, MODE = sys.argv[1], sys.argv[2]
HOME = (49.55782283, 11.15501383)
Z_WIDE, R_WIDE = 10, 200.0
Z_NEAR, R_NEAR = 13, 60.0
URL = "https://sgx.geodatenzentrum.de/wmts_topplus_open/tile/1.0.0/web/default/WEBMERCATOR/{z}/{y}/{x}.png"
UA = "BND-Prepper-Tiles/1.0 (privates Offline-Dashboard Kalchreuth; einmaliger Abruf, ca. 2 Abrufe/s)"
PAUSE = 0.5
AVG_KB = 28
OUT = os.path.join(DASH, "static", "tiles")


def tile_xy(lat, lon, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    la = math.radians(max(-85.0511, min(85.0511, lat)))
    y = int((1.0 - math.asinh(math.tan(la)) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def tiles():
    lat, lon = HOME
    for z in range(0, Z_NEAR + 1):
        r = R_WIDE if z <= Z_WIDE else R_NEAR
        dlat = r / 111.32
        dlon = r / (111.32 * math.cos(math.radians(lat)))
        x0, y0 = tile_xy(lat + dlat, lon - dlon, z)
        x1, y1 = tile_xy(lat - dlat, lon + dlon, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                yield z, x, y


def path(z, x, y):
    return os.path.join(OUT, str(z), str(x), "%d.png" % y)


def ok_png(p):
    try:
        with open(p, "rb") as f:
            return f.read(8) == b"\x89PNG\r\n\x1a\n" and os.path.getsize(p) > 60
    except OSError:
        return False


def quelle():
    d = datetime.date.today()
    datum = d.strftime("%d.%m.%Y")
    src = "https://sgx.geodatenzentrum.de/web_public/gdz/datenquellen/datenquellen_topplusopen_%s.pdf" % datum
    q = {"attribution": "Kartendarstellung: © BKG (%d) dl-de/by-2-0, Datenquellen: %s" % (d.year, src),
         "attribution_html": ('Kartendarstellung: © <a href="https://www.bkg.bund.de" target="_blank" rel="noopener">BKG</a> (%d) '
                              '<a href="https://www.govdata.de/dl-de/by-2-0" target="_blank" rel="noopener">dl-de/by-2-0</a>, '
                              'Datenquellen: <a href="%s" target="_blank" rel="noopener">%s</a>' % (d.year, src, src)),
         "date": datum, "z_wide": Z_WIDE, "z_near": Z_NEAR, "r_wide_km": int(R_WIDE), "r_near_km": int(R_NEAR),
         "source": "BKG TopPlusOpen WMTS (web, WEBMERCATOR)"}
    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(OUT, ".quelle.json.part")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(q, f, ensure_ascii=False, indent=1)
    os.replace(tmp, os.path.join(OUT, "quelle.json"))


allt = list(tiles())
per = {}
for z, x, y in allt:
    per[z] = per.get(z, 0) + 1
todo = [t for t in allt if not ok_png(path(*t))]
print("Kacheln BKG TopPlusOpen rund um Kalchreuth (%.5f, %.5f)" % HOME)
print("  Zoom 0-%d bis %d km, Zoom %d-%d bis %d km" % (Z_WIDE, R_WIDE, Z_WIDE + 1, Z_NEAR, R_NEAR))
print("  je Zoomstufe: " + ", ".join("z%d=%d" % (z, per[z]) for z in sorted(per)))
print("  gesamt %d Kacheln, schon vorhanden %d, zu laden %d" % (len(allt), len(allt) - len(todo), len(todo)))
mb = len(todo) * AVG_KB / 1024.0
print("  geschaetzt ca. %.0f MB, Dauer ca. %.0f min (ca. 2 Abrufe/s)" % (mb, len(todo) * (PAUSE + 0.15) / 60.0))
print("  Ziel: %s/{z}/{x}/{y}.png" % OUT)
free = shutil.disk_usage(DASH).free / 1048576.0
print("  freier Speicher: %.0f MB" % free)
if free < mb * 2 + 200:
    print("STOP: zu wenig freier Speicher (brauche ca. %.0f MB Reserve)" % (mb * 2 + 200)); sys.exit(1)
if MODE == "probe":
    sys.exit(0)
if not todo:
    if not os.path.isfile(os.path.join(OUT, "quelle.json")):
        quelle()
    print("OK: alle Kacheln schon vorhanden - nichts zu laden"); sys.exit(0)

stop = {"v": False}


def on_int(sig, frm):
    if stop["v"]:
        raise KeyboardInterrupt
    stop["v"] = True
    print("\nStrg-C: beende nach der aktuellen Kachel ... (nochmal Strg-C = sofort)")


signal.signal(signal.SIGINT, on_int)
signal.signal(signal.SIGTERM, on_int)
got = fail = 0
bytes_ = 0
t0 = time.time()
miss = []
try:
    for i, (z, x, y) in enumerate(todo):
        if stop["v"]:
            break
        p = path(z, x, y)
        u = URL.format(z=z, x=x, y=y)
        done = False
        for tries in range(4):
            if stop["v"]:
                break
            t1 = time.time()
            try:
                rq = urllib.request.Request(u, headers={"User-Agent": UA, "Accept": "image/png"})
                with urllib.request.urlopen(rq, timeout=30) as r:
                    data = r.read()
                if data[:8] != b"\x89PNG\r\n\x1a\n":
                    raise ValueError("keine PNG-Antwort")
                os.makedirs(os.path.dirname(p), exist_ok=True)
                tmp = p + ".part"
                with open(tmp, "wb") as f:
                    f.write(data)
                os.replace(tmp, p)
                got += 1
                bytes_ += len(data)
                done = True
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    miss.append("%d/%d/%d" % (z, x, y)); done = True
                elif e.code in (429, 503):
                    print("  Server bittet um Pause (HTTP %d) - warte 60 s" % e.code); time.sleep(60)
                else:
                    time.sleep(5 * (tries + 1))
            except Exception:
                time.sleep(5 * (tries + 1))
            el = time.time() - t1
            if el < PAUSE:
                time.sleep(PAUSE - el)
            if done:
                break
        if not done and not stop["v"]:
            fail += 1
        if (i + 1) % 50 == 0 or i + 1 == len(todo):
            print("  %d/%d geladen (%.1f MB, Fehler %d, %.0f s)" % (i + 1, len(todo), bytes_ / 1048576.0, fail, time.time() - t0), flush=True)
except KeyboardInterrupt:
    stop["v"] = True
for root, dirs, files in os.walk(OUT):
    for fn in files:
        if fn.endswith(".part"):
            try:
                os.remove(os.path.join(root, fn))
            except OSError:
                pass
if got or os.path.isdir(os.path.join(OUT, "10")):
    quelle()
print("Ergebnis: %d neu geladen (%.1f MB), %d fehlgeschlagen, %d beim Server nicht vorhanden" % (got, bytes_ / 1048576.0, fail, len(miss)))
if stop["v"]:
    print("ABGEBROCHEN - erneut starten setzt fort (vorhandene Kacheln werden uebersprungen)"); sys.exit(130)
if fail:
    print("WARN: %d Kacheln fehlen noch - Skript einfach erneut starten" % fail); sys.exit(1)
print("OK: Offline-Kacheln vollstaendig. Karte: http://<Pi>:5000/karte (Seite neu laden)")
PYEOF
if [[ "$MODE" == "frage" ]]; then
  "$PY" "$TPY" "$DASH_DIR" probe || exit 1
  if [[ -r /dev/tty ]]; then
    read -r -p "Download jetzt starten? [j/N] " ans < /dev/tty || ans=""
  else
    ans=""
  fi
  [[ "$ans" == "j" || "$ans" == "J" || "$ans" == "ja" ]] || { echo "Nichts geladen. (Ohne Rueckfrage: --ja)"; exit 0; }
  MODE="ja"
fi
"$PY" "$TPY" "$DASH_DIR" "$MODE" < /dev/null
rc=$?
if [[ $(id -u) -eq 0 && -d "$DASH_DIR/static/tiles" ]] && id "$OWNER" > /dev/null 2>&1; then
  chown -R "$OWNER:$OWNER" "$DASH_DIR/static/tiles"
fi
exit $rc
