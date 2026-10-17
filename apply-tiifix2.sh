#!/bin/bash
set -euo pipefail
# tiiFix2 (nach tiiFix): MASTS_DB 11D um 72 weitere BR-Bayern-Masten (Ensemble 10A5) bis etwa 200 km um Kalchreuth ergaenzen,
# u. a. 08/01 Ochsenkopf, 05/15 Buettelberg, 05/11 Hesselberg, 07/02 Amberg (Rotbuehl), 07/12 Hohe Linie. TII laut fmlist.org (Abruf 17.10.2026),
# gegengeprueft mit sender-tabelle.de; alle "bisher nicht empfangen". Danach Empfangspruefung (nur lesen) + Live-Beobachtung max 10 min.
# Nur prepper_sdr.py (5 Stellen im sdrTeil2-Block), Neustart nur prepper-sdr. Nur Anzeige/Zuordnung - Sticks, Alarme, Mesh unveraendert. Sendet nichts.
# Nur pruefen ohne Aenderung: bash tiifix2.sh pruefen
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
M="$DASH_DIR/prepper_sdr.py"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/tiifix2-apply
KEEP_LAST=3
KNOWN_SDR16="8b45ff4709d06d08"   # prepper_sdr.py live nach tiiFix
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
if [[ "$COMMIT_ARG" == pruefen ]]; then echo "=== tiiFix2 nur pruefen (11D-Empfang, nur lesen), Dashboard-Port $PORT ==="; else echo "=== tiiFix2 apply (MASTS_DB 11D + Empfangspruefung), Dashboard-Port $PORT ==="; fi
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXP_PAIRS="08/18 05/14 05/01 05/13 08/01 05/15 05/11 07/02 07/12 08/04 07/06 08/03 08/10 07/01 05/05 08/08 06/18 06/21 05/06 01/05 01/04 07/11 05/02 08/06 06/17 08/07 06/01 06/16 07/05 07/03 06/19 04/07 03/10 08/02 07/08 08/09 08/05 06/07 04/08 07/04 01/12 01/23 06/20 04/21 06/22 06/03 06/15 06/05 06/06 06/04 04/03 04/11 07/21 03/01 03/06 06/02 04/05 06/09 04/16 04/17 04/02 02/07 02/01 02/08 03/09 01/06 06/08 03/04 01/08 04/20 04/19 03/05 01/16 01/10 03/03 01/03"
EXPECT_PT="9249e0aa877eedbdcb50e9004350bce86134c1ace2474268de33dbf3d7f7fcb6"
cat > "$W/patch-tiifix2-sdr.py" << 'TFP2_EOF'
"""tiiFix2: MASTS_DB 11D um 72 weitere BR-Bayern-Masten (Ensemble 10A5) bis etwa 200 km um Kalchreuth ergaenzen (TII laut fmlist.org,
Abruf 17.10.2026, gegengeprueft mit sender-tabelle.de; alle "bisher nicht empfangen"). Nur sdrTeil2-Block: Liste 11D, Kanal-Quelle,
3 Selbsttest-Zeilen. Idempotent. Aufruf: patch-tiifix2-sdr.py QUELLE ZIEL -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst = sys.argv[1:3]
s = open(src, encoding="utf-8").read()
OLD_LST = '                    {"main": 5, "sub": 13, "mast": "Dillberg", "lat": 49.3239, "lon": 11.3831, "src": "fmlist Ensemble 10A5 (Abruf 17.10.2026), bisher nicht empfangen"}],\n'
NEW_LST = '                    {"main": 5, "sub": 13, "mast": "Dillberg", "lat": 49.3239, "lon": 11.3831, "src": "fmlist Ensemble 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 1, "mast": "Ochsenkopf", "lat": 50.03, "lon": 11.8086, "km": 70, "site_m": 1013, "ant_m": 169, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},   # tiiFix2: 72 weitere 11D-Masten bis etwa 200 km (fmlist 10A5)\n                    {"main": 5, "sub": 15, "mast": "Büttelberg", "lat": 49.4146, "lon": 10.378, "km": 58, "site_m": 527, "ant_m": 159, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 5, "sub": 11, "mast": "Wassertrüdingen (Hesselberg)", "lat": 49.0682, "lon": 10.5257, "km": 71, "site_m": 678, "ant_m": 76, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 2, "mast": "Amberg (Hirschau/Rotbühl)", "lat": 49.5088, "lon": 12.0048, "km": 62, "site_m": 666, "ant_m": 95, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 12, "mast": "Hohe Linie", "lat": 49.0397, "lon": 12.1716, "km": 94, "site_m": 474, "ant_m": 140, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 4, "mast": "Ebermannstadt (Pretzfeld)", "km": 22, "site_m": 477, "ant_m": 34, "erp_kw": 5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 6, "mast": "Weigendorf (Ernhüll)", "km": 32, "site_m": 551, "ant_m": 34, "erp_kw": 4, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 3, "mast": "Pegnitz (Gunzerberg)", "km": 36, "site_m": 493, "ant_m": 28, "erp_kw": 8, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 10, "mast": "Burgwindheim", "km": 50, "site_m": 428, "ant_m": 138, "erp_kw": 6.3, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 1, "mast": "Amberg-Süd", "km": 57, "site_m": 383, "ant_m": 45, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 5, "sub": 5, "mast": "Weißenburg (Rohrberg)", "km": 58, "site_m": 598, "ant_m": 33, "erp_kw": 6.3, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 8, "mast": "Kulmbach (Rehberg)", "km": 64, "site_m": 485, "ant_m": 27, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 18, "mast": "Zeil am Main (Schleifberg)", "km": 65, "site_m": 350, "ant_m": 27, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 21, "mast": "Ebern (Haubeberg)", "km": 68, "site_m": 430, "ant_m": 34, "erp_kw": 2, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 5, "sub": 6, "mast": "Treuchtlingen (Schloßberg)", "km": 69, "site_m": 491, "ant_m": 21, "erp_kw": 1.3, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 5, "mast": "Gelbelsee", "km": 71, "site_m": 539, "ant_m": 105, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 4, "mast": "Eichstätt (Schönblick)", "km": 73, "site_m": 480, "ant_m": 8, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 11, "mast": "Altenstadt (Oberpfalz)", "km": 74, "site_m": 504, "ant_m": 36, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 5, "sub": 2, "mast": "Rothenburg ob der Tauber (Deponie)", "km": 75, "site_m": 420, "ant_m": 33, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 6, "mast": "Kronach", "km": 78, "site_m": 490, "ant_m": 69, "erp_kw": 5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 17, "mast": "Volkach (Escherndorf)", "km": 78, "site_m": 305, "ant_m": 35, "erp_kw": 6.3, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 7, "mast": "Coburg (Eckardtsberg)", "km": 78, "site_m": 431, "ant_m": 60, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 1, "mast": "Dettelbach", "km": 79, "site_m": 254, "ant_m": 33, "erp_kw": 2, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 16, "mast": "Schweinfurt (A70/Weyer)", "km": 80, "site_m": 276, "ant_m": 35, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 5, "mast": "Pfreimd (Trausnitz)", "km": 80, "site_m": 536, "ant_m": 65, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 3, "mast": "Fuchsmühl (Herzogöd)", "km": 81, "site_m": 749, "ant_m": 34, "erp_kw": 2.5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 19, "mast": "Würzburg (Frankenwarte/BR)", "km": 83, "site_m": 355, "ant_m": 102, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 7, "mast": "Kelheim (Hohenpfahl)", "km": 89, "site_m": 491, "ant_m": 29, "erp_kw": 2, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 3, "sub": 10, "mast": "Hühnerberg", "km": 93, "site_m": 571, "ant_m": 137, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 2, "mast": "Bad Steben (Lichtenberg)", "km": 98, "site_m": 608, "ant_m": 32, "erp_kw": 6, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 8, "mast": "Schönsee (Drechselberg)", "km": 103, "site_m": 823, "ant_m": 29, "erp_kw": 5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 9, "mast": "Hof (Labyrinthberg)", "km": 103, "site_m": 566, "ant_m": 45, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 8, "sub": 5, "mast": "Ludwigsstadt-Ebersdorf", "km": 105, "site_m": 577, "ant_m": 28, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 7, "mast": "Hammelburg (Westheim)", "km": 108, "site_m": 309, "ant_m": 126, "erp_kw": 8, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 8, "mast": "Mainburg-Wambach", "km": 110, "site_m": 460, "ant_m": 45, "erp_kw": 2.6, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 4, "mast": "Geigant (Waldmünchen)", "km": 113, "site_m": 576, "ant_m": 56, "erp_kw": 6.3, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 12, "mast": "Pfaffenhofen (Wolfsberg)", "km": 115, "site_m": 513, "ant_m": 119, "erp_kw": 25, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 23, "mast": "Pfaffenhofen (BR)", "km": 117, "site_m": 484, "ant_m": 57, "erp_kw": 2, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 20, "mast": "Pfaffenberg", "km": 117, "site_m": 431, "ant_m": 120, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 21, "mast": "Mallersdorf (Hofkirchen)", "km": 118, "site_m": 460, "ant_m": 88, "erp_kw": 25, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 22, "mast": "Wertheim (Schloßberg)", "km": 119, "site_m": 257, "ant_m": 45, "erp_kw": 5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 3, "mast": "Gemünden (Main) Hofstetten", "km": 120, "site_m": 390, "ant_m": 83, "erp_kw": 12.5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 15, "mast": "Ostheim (Heidelberg)", "km": 120, "site_m": 522, "ant_m": 39, "erp_kw": 2, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 5, "mast": "Neustadt am Main (Erlachberg)", "km": 122, "site_m": 358, "ant_m": 34, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 6, "mast": "Kreuzberg (Rhön)", "km": 123, "site_m": 925, "ant_m": 142, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 4, "mast": "Burgsinn", "km": 126, "site_m": 419, "ant_m": 55, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 3, "mast": "Rattenberg (Kreuzhaus)", "km": 127, "site_m": 879, "ant_m": 44, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 11, "mast": "Landshut (Altdorf)", "km": 130, "site_m": 458, "ant_m": 51, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 7, "sub": 21, "mast": "Hoher Bogen", "km": 132, "site_m": 975, "ant_m": 53, "erp_kw": 4, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 3, "sub": 1, "mast": "Augsburg (Welden/Staufersberg)", "km": 134, "site_m": 576, "ant_m": 130, "erp_kw": 25, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 3, "sub": 6, "mast": "Augsburg (Hotelturm)", "km": 135, "site_m": 494, "ant_m": 139, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 2, "mast": "Miltenberg (Wenschdorf)", "km": 135, "site_m": 481, "ant_m": 132, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 5, "mast": "Dingolfing (BMW)", "km": 140, "site_m": 357, "ant_m": 60, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 9, "mast": "Obernburg am Main", "km": 150, "site_m": 245, "ant_m": 47, "erp_kw": 4, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 16, "mast": "Vilsbiburg", "km": 151, "site_m": 504, "ant_m": 51, "erp_kw": 5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 17, "mast": "Deggendorf (Aletsberg)", "km": 152, "site_m": 395, "ant_m": 56, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 2, "mast": "Einödriegel", "km": 153, "site_m": 1105, "ant_m": 39, "erp_kw": 6.3, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 2, "sub": 7, "mast": "München (Ismaning)", "km": 153, "site_m": 482, "ant_m": 168, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 2, "sub": 1, "mast": "München-Freimann", "km": 155, "site_m": 496, "ant_m": 93, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 2, "sub": 8, "mast": "München (Olympiaturm)", "km": 157, "site_m": 511, "ant_m": 272, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 3, "sub": 9, "mast": "Ulm (Kuhberg)", "km": 157, "site_m": 582, "ant_m": 94, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 6, "mast": "Fürstenfeldbruck (Schöngeising)", "km": 157, "site_m": 605, "ant_m": 127, "erp_kw": 2, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 6, "sub": 8, "mast": "Alzenau (Hahnenkamm BR)", "km": 160, "site_m": 430, "ant_m": 62, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 3, "sub": 4, "mast": "Markt Wald (Mittelneufnach)", "km": 160, "site_m": 638, "ant_m": 112, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 8, "mast": "Isen (Schnaupping)", "km": 168, "site_m": 640, "ant_m": 63, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 20, "mast": "Brotjacklriegel", "km": 171, "site_m": 1009, "ant_m": 106, "erp_kw": 4, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 4, "sub": 19, "mast": "Pfarrkirchen (Postmünster)", "km": 179, "site_m": 462, "ant_m": 100, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 3, "sub": 5, "mast": "Memmingen (Niederrieden)", "km": 182, "site_m": 667, "ant_m": 49, "erp_kw": 1, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 16, "mast": "Wasserburg (Koblberg)", "km": 183, "site_m": 510, "ant_m": 38, "erp_kw": 2.5, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 10, "mast": "Neuötting", "km": 184, "site_m": 487, "ant_m": 45, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 3, "sub": 3, "mast": "Kaufbeuren (Weinhaldeweg)", "km": 190, "site_m": 711, "ant_m": 11, "erp_kw": 0.63, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},\n                    {"main": 1, "sub": 3, "mast": "Hohenpeißenberg", "km": 196, "site_m": 936, "ant_m": 66, "erp_kw": 10, "src": "fmlist 10A5 (Abruf 17.10.2026), bisher nicht empfangen"}],\n'
OLD_SRC = '            "src": "Frequenz: ETSI EN 300 401 Kanalraster Band III (11D = 222,064 MHz); TII: fmlist.org Ensemble 10A5 (BR Bayern), 08/18 + 05/14 live empfangen 17.10.2026; "\n                   "Koordinaten ungefaehr (etwa 1 km, Wikipedia/helmuthzeitler.com/Teil-1-Liste, nicht von fmlist) - nur Anzeige"},\n'
NEW_SRC = '            "src": "Frequenz: ETSI EN 300 401 Kanalraster Band III (11D = 222,064 MHz); TII: fmlist.org Ensemble 10A5 (BR Bayern), 08/18 + 05/14 live empfangen 17.10.2026; "\n                   "Koordinaten ungefaehr (etwa 1 km, Wikipedia/helmuthzeitler.com/Teil-1-Liste, nicht von fmlist) - nur Anzeige; "   # tiiFix2\n                   "tiiFix2: weitere Masten TII/Hoehe/Antenne/ERP laut fmlist.org 10A5 (Abruf 17.10.2026, gegengeprueft sender-tabelle.de), lat/lon nur bei 5 Masten (Wikipedia-Senderartikel), "\n                   "km = Entfernung zu Kalchreuth ungefaehr (ohne lat/lon: Ortslage OpenStreetMap, etwa +-10 km)"},\n'
OLD_T1 = 'and [(t["main"], t["sub"]) for t in MASTS_DB["11D"]["tii"]] == [(8, 18), (5, 14), (5, 1), (5, 13)]   # tiiFix\n'
NEW_T1 = 'and [(t["main"], t["sub"]) for t in MASTS_DB["11D"]["tii"]][:9] == [(8, 18), (5, 14), (5, 1), (5, 13), (8, 1), (5, 15), (5, 11), (7, 2), (7, 12)] and len(MASTS_DB["11D"]["tii"]) == 76   # tiiFix # tiiFix2\n'
OLD_T2 = '    assert x["tii"][0]["mast"] == "MainID 07 / SubID 02 (nicht in MASTS_DB)" and "nicht in MASTS_DB" in x["tii"][1]["mast"], x["tii"]   # tiiFix: 07/xx nicht mehr in MASTS_DB\n'
NEW_T2 = '    assert x["tii"][0]["mast"] == "Amberg (Hirschau/Rotbühl) MainID 07 / SubID 02 (BR Bayern)" and "nicht in MASTS_DB" in x["tii"][1]["mast"], x["tii"]   # tiiFix # tiiFix2: 07/02 = Amberg laut fmlist, 07/09 nicht in MASTS_DB\n'
OLD_T3 = '    assert t2_mast("11D", 8, 18) == "Bamberg (Geisberg) MainID 08 / SubID 18 (BR Bayern)" and t2_mast("11D", 5, 14).startswith("Nürnberg (Fernmeldeturm Schweinau) MainID 05 / SubID 14")   # tiiFix\n    assert t2_fig_parse({"ensemble": {"id": "0x0000", "label": ""}, "services": []}, now, "11D") is None and t2_fig_parse(None, now, "11D") is None\n'
NEW_T3 = '    assert t2_mast("11D", 8, 18) == "Bamberg (Geisberg) MainID 08 / SubID 18 (BR Bayern)" and t2_mast("11D", 5, 14).startswith("Nürnberg (Fernmeldeturm Schweinau) MainID 05 / SubID 14")   # tiiFix\n    assert t2_mast("11D", 8, 1) == "Ochsenkopf MainID 08 / SubID 01 (BR Bayern)" and t2_mast("11D", 7, 12).startswith("Hohe Linie MainID 07 / SubID 12") and t2_mast("11D", 9, 9).endswith("(nicht in MASTS_DB)")   # tiiFix2\n    assert len({(t["main"], t["sub"]) for t in MASTS_DB["11D"]["tii"]}) == len(MASTS_DB["11D"]["tii"]) and all(t.get("src") and t.get("mast") for t in MASTS_DB["11D"]["tii"])   # tiiFix2\n    assert t2_fig_parse({"ensemble": {"id": "0x0000", "label": ""}, "services": []}, now, "11D") is None and t2_fig_parse(None, now, "11D") is None\n'
EDITS = ((OLD_LST, NEW_LST), (OLD_SRC, NEW_SRC), (OLD_T1, NEW_T1), (OLD_T2, NEW_T2), (OLD_T3, NEW_T3))
bad = []
for need in ("# ===== sdrTeil2:", "# ===== /sdrTeil2 =====", "MASTS_DB = {", "def t2_mast(", "def selftest_teil2():", "# tiiFix: TII-Paar -> Mastname"):
    if s.count(need) != 1:
        bad.append("%s nicht genau 1x" % need)
for old, new in EDITS:
    if s.count(old) + s.count(new) != 1:
        bad.append("Stelle nicht eindeutig: %s" % old.strip().splitlines()[0][:60])
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
s2 = s
for old, new in EDITS:
    if old in s2:
        a, z, i = s2.index("# ===== sdrTeil2:"), s2.index("# ===== /sdrTeil2 ====="), s2.index(old)
        if not a < i < z:
            print("Basis passt nicht: Stelle ausserhalb sdrTeil2"); raise SystemExit(3)
        s2 = s2.replace(old, new)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
TFP2_EOF
EXPECT_GUARD="d9152ddc774c6894c447a00fb0c9f51038e795ea232fd3408212f8060b0ead4f"
cat > "$W/guard_tiifix2.py" << 'TFG2_EOF'
"""tiiFix2 AST-Guard. Aufruf: guard_tiifix2.py SDR_ALT SDR_NEU PATCH -> 0 ok, 1 Verstoss.
prepper_sdr.py: nur die 5 tiiFix2-Stellen im sdrTeil2-Block (Ruecktausch ergibt Byte fuer Byte die Basis); MASTS_DB 11D nur um Eintraege ergaenzt
(die 4 bisherigen unveraendert, 5C/10C unveraendert); keine neuen Importe/shell, neue Aufrufe nur in Selbsttest-Zeilen."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
p0, p1 = rd(sys.argv[1]), rd(sys.argv[2])
err = []
ptf_src = rd(sys.argv[3])
g = {}
exec(compile(ptf_src.split("EDITS = (")[0].split("import sys\n", 1)[1].split("s = open(src")[1].split("\n", 1)[1], "ptf", "exec"), g)
EDITS = ((g["OLD_LST"], g["NEW_LST"]), (g["OLD_SRC"], g["NEW_SRC"]), (g["OLD_T1"], g["NEW_T1"]), (g["OLD_T2"], g["NEW_T2"]), (g["OLD_T3"], g["NEW_T3"]))
r1, r0 = p1, p0
for old, new in EDITS:
    if r1.count(new) != 1:
        err.append("tiiFix2-Stelle fehlt: %s" % new.strip().splitlines()[0][:60])
    r1 = r1.replace(new, old)
    r0 = r0.replace(new, old)
if r1 != r0:
    err.append("prepper_sdr.py: anders geaendert als die 5 tiiFix2-Stellen")


def masts(src):
    t = ast.parse(src)
    for n in t.body:
        if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id == "MASTS_DB" for x in n.targets):
            return ast.literal_eval(n.value)
    return None


try:
    m0, m1 = masts(r0), masts(p1)
    t0, t1 = m0["11D"]["tii"], m1["11D"]["tii"]
    if t1[:len(t0)] != t0 or len(t1) <= len(t0):
        err.append("MASTS_DB 11D: bisherige Eintraege veraendert")
    if {k: v for k, v in m1.items() if k != "11D"} != {k: v for k, v in m0.items() if k != "11D"}:
        err.append("MASTS_DB: andere Kanaele veraendert")
    if {k: v for k, v in m1["11D"].items() if k not in ("tii", "src")} != {k: v for k, v in m0["11D"].items() if k not in ("tii", "src")}:
        err.append("MASTS_DB 11D: andere Felder veraendert")
    pr = [(x["main"], x["sub"]) for x in t1]
    if len(set(pr)) != len(pr):
        err.append("MASTS_DB 11D: TII doppelt")
    for x in t1[len(t0):]:
        if not (isinstance(x.get("main"), int) and isinstance(x.get("sub"), int) and 1 <= x["main"] <= 69 and 0 <= x["sub"] <= 23 and x.get("mast")
                and "bisher nicht empfangen" in str(x.get("src")) and "fmlist" in str(x.get("src"))):
            err.append("MASTS_DB 11D: Eintrag unvollstaendig %r" % (x,)); break
except Exception as e:
    err.append("MASTS_DB nicht lesbar: %s" % e)


def sig(src):
    t = ast.parse(src)
    imp = sorted((getattr(n, "module", None) or a.name) for n in ast.walk(t) if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names)
    calls = sorted((c.func.attr if isinstance(c.func, ast.Attribute) else getattr(c.func, "id", "?")) for c in ast.walk(t) if isinstance(c, ast.Call))
    sh = sum(1 for n in ast.walk(t) if isinstance(n, ast.keyword) and n.arg == "shell")
    return imp, calls, sh


i0, c0, s0 = sig(p0)
i1, c1, s1 = sig(p1)
if i1 != i0 or s1 != s0:
    err.append("prepper_sdr.py: Importe/shell geaendert")
extra = list(c1)
for c in c0:
    if c in extra:
        extra.remove(c)
if set(extra) - {"get", "startswith", "endswith", "t2_mast", "len", "all", "str"}:
    err.append("prepper_sdr.py: neue Aufrufe %s" % sorted(set(extra)))
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard tiiFix2: prepper_sdr.py nur MASTS_DB 11D (+%d Masten, bisherige 4 unveraendert), Kanal-Quelle und 3 Selbsttest-Zeilen; keine neuen Importe, Prozesse, Netz oder shell" % (len(t1) - len(t0)))
TFG2_EOF
EXPECT_CK="441687673f52446511ee85f3f717f3df9d47043ac593e54a1c4d1556c6d0420a"
cat > "$W/tii2check.py" << 'TFC2_EOF'
"""tiiFix2 Empfangspruefung 11D - NUR LESEN. Aufruf: tii2check.py DASH_DIR [LIVE_SEKUNDEN]
Quellen: broadcast_state.json (t2.masts 11D, t2.fig 11D = letzte Pruefung, t2.ev TII-Ereignisse) und lagezentrum.db (read-only:
telemetry kind 'fig' Kanal 11D = TII je Pruefung, 48 h; events DAB/tii). Live: liest nur broadcast_state.json alle 5 s (prepper-sdr
schreibt hoechstens 1x je Minute). Kein Stick-Zugriff, kein Netz, sendet nichts, schreibt nichts."""
import json
import math
import os
import re
import sqlite3
import sys
import time

D = sys.argv[1]
LIVE = max(0, min(600, int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 0))
BS = os.path.join(D, "broadcast_state.json")
DB = os.path.join(D, "lagezentrum.db")


def ts(t):
    try:
        return time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(int(t)))
    except Exception:
        return "?"


def load_bs():
    for _ in range(3):
        try:
            with open(BS, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            time.sleep(0.5)
    return {}


def key(m, s):
    try:
        return "%02d/%02d" % (int(m), int(s))
    except Exception:
        return None


def pairs_text(txt):
    """TII-Ereignistext -> gesehene Paare (bei Wechsel nur die neuen nach '->')."""
    t = str(txt or "").split(" (", 1)[0]
    if "->" in t:
        t = t.split("->", 1)[1]
    return re.findall(r"\b\d{2}/\d{2}\b", t)


bs = load_bs()
t2 = bs.get("t2") if isinstance(bs.get("t2"), dict) else {}
m11 = ((t2.get("masts") or {}).get("11D") or {}) if isinstance(t2.get("masts"), dict) else {}
masts = [x for x in (m11.get("tii") or []) if isinstance(x, dict) and key(x.get("main"), x.get("sub"))]
for x in masts:   # Entfernung fuer Masten mit lat/lon, aber ohne km (die 4 aus tiiFix)
    try:
        if not x.get("km") and isinstance(x.get("lat"), (int, float)) and isinstance(x.get("lon"), (int, float)):
            la1, lo1, la2, lo2 = map(math.radians, (49.55782283, 11.15501383, x["lat"], x["lon"]))
            x["km"] = int(round(2 * 6371.0088 * math.asin(math.sqrt(math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2))))
    except Exception:
        pass
name = {key(x["main"], x["sub"]): x for x in masts}
seen = {}   # key -> dict(n, ev, last, err, km)
src_used = []


def note(k, t, err=None, km=None, ev=False):
    if not k:
        return
    s = seen.setdefault(k, {"n": 0, "ev": 0, "last": 0, "err": None, "km": None, "first": None})
    if ev:
        s["ev"] += 1
    else:
        s["n"] += 1
    if isinstance(t, (int, float)):
        s["last"] = max(s["last"], int(t))
        s["first"] = int(t) if s["first"] is None else min(s["first"], int(t))
    if isinstance(err, (int, float)) and (s["err"] is None or err < s["err"]):
        s["err"] = err
        s["km"] = km if isinstance(km, (int, float)) else s["km"]


# 1) lagezentrum.db read-only
n_chk = n_chk_tii = 0
t_min = t_max = None
if os.path.exists(DB):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=5)
        try:
            for t, tii in con.execute("SELECT ts, tii FROM telemetry WHERE kind='fig' AND channel='11D' ORDER BY ts"):
                n_chk += 1
                t_min = t if t_min is None else min(t_min, t)
                t_max = t if t_max is None else max(t_max, t)
                try:
                    lst = json.loads(tii or "[]")
                except Exception:
                    lst = []
                if lst:
                    n_chk_tii += 1
                for y in lst if isinstance(lst, list) else []:
                    if isinstance(y, dict):
                        note(key(y.get("main"), y.get("sub")), t, y.get("err"), y.get("km"))
            src_used.append("lagezentrum.db Telemetrie (TII je 11D-Pruefung, 48 h): %d Pruefungen, davon %d mit TII%s" % (
                n_chk, n_chk_tii, (", %s bis %s" % (ts(t_min), ts(t_max))) if n_chk else ""))
            ev_ids = set()
            try:
                for t, txt, eid in con.execute("SELECT created, COALESCE(text, headline), ext_id FROM events WHERE source='DAB' AND type='tii'"):
                    if "11D" in str(txt):
                        ev_ids.add(str(eid))
                        for k in pairs_text(txt):
                            note(k, t, ev=True)
                src_used.append("lagezentrum.db Ereignisse DAB/tii (24 h): %d" % len(ev_ids))
            except Exception as e:
                ev_ids = set()
                src_used.append("lagezentrum.db Ereignisse: nicht lesbar (%s)" % str(e)[:60])
        finally:
            con.close()
    except Exception as e:
        ev_ids = set()
        src_used.append("lagezentrum.db: nicht lesbar (%s)" % str(e)[:80])
else:
    ev_ids = set()
    src_used.append("lagezentrum.db: nicht vorhanden")
# 2) broadcast_state.json t2.ev (nur Ereignisse, die nicht schon aus der DB kamen)
n_ev = 0
for e in t2.get("ev") or []:
    if isinstance(e, dict) and e.get("k") == "tii" and e.get("ch") == "11D" and str(e.get("id")) not in ev_ids:
        n_ev += 1
        for k in pairs_text(e.get("text")):
            note(k, e.get("t"), ev=True)
src_used.append("broadcast_state.json TII-Ereignisse 11D (zusaetzlich zur DB): %d" % n_ev)
# 3) letzte Pruefung
f11 = ((t2.get("fig") or {}).get("11D") or {}) if isinstance(t2.get("fig"), dict) else {}
if isinstance(f11.get("t"), (int, float)) and (t_max is None or f11["t"] > t_max):   # noch nicht in der DB
    for y in f11.get("tii") or []:
        if isinstance(y, dict):
            note(key(y.get("main"), y.get("sub")), f11["t"], y.get("err"), y.get("km"))
cur = ", ".join(key(y.get("main"), y.get("sub")) or "?" for y in (f11.get("tii") or []) if isinstance(y, dict)) or "keine"
src_used.append("letzte 11D-Pruefung: %s, TII jetzt: %s, stabile Menge: %s" % (ts(f11.get("t")) if f11.get("t") else "keine", cur,
                                                                                   ", ".join(f11.get("tii_set") or []) or "noch keine"))
dm = (((bs.get("dab") or {}).get("11D") or {}).get("demod") or {}) if isinstance(bs.get("dab"), dict) else {}
print("=== Empfangspruefung 11D (nur lesen, sendet nichts, kein Stick-Zugriff) ===")
for s in src_used:
    print("Quelle: " + s)
print("Journal prepper-sdr: enthaelt keine TII-Zeilen (prepper-sdr protokolliert TII nur in broadcast_state.json/lagezentrum.db)")
print("Pegel je Mast: welle-cli liefert je TII nur Laufzeit-Differenz (delay_km) und Fehlermass (error), KEINEN Pegel/RSSI je Mast."
      " Gesamtwert 11D: SNR %s dB, FIC-Fehlerrate %s" % (dm.get("snr", "?") if dm else "?", dm.get("fic_rate", "?") if dm else "?"))
print("MASTS_DB 11D (laut laufendem prepper-sdr): %d Masten" % len(masts))
if not masts:
    print("WARNUNG: broadcast_state.json enthaelt noch keine MASTS_DB 11D - prepper-sdr laeuft? (nichts geaendert)")
yes = [x for x in masts if key(x["main"], x["sub"]) in seen]
no = [x for x in masts if key(x["main"], x["sub"]) not in seen]
print("EMPFANGEN (%d):" % len(yes))
for x in sorted(yes, key=lambda x: -seen[key(x["main"], x["sub"])]["last"]):
    k = key(x["main"], x["sub"]); s = seen[k]
    print("  JA   %s %s%s - %d Pruefungen, %d Ereignisse, zuletzt %s%s" % (
        k, x.get("mast"), (" (ca. %s km)" % x["km"]) if x.get("km") else "", s["n"], s["ev"], ts(s["last"]),
        (", bestes error %.2f, delay %s km" % (s["err"], s["km"])) if s["err"] is not None else ""))
print("NICHT EMPFANGEN (%d), nach Entfernung:" % len(no))
no = sorted(no, key=lambda x: x.get("km") or 0)
for i in range(0, len(no), 4):
    print("  nein " + "; ".join("%s %s%s" % (key(x["main"], x["sub"]), x.get("mast"), (" %s km" % x["km"]) if x.get("km") else "") for x in no[i:i + 4]))
unk = sorted(k for k in seen if k not in name)
print("EMPFANGEN, ABER NICHT IN MASTS_DB (%d):" % len(unk))
for k in unk:
    s = seen[k]
    print("  ??   %s - %d Pruefungen, %d Ereignisse, zuletzt %s%s" % (k, s["n"], s["ev"], ts(s["last"]),
                                                                       (", bestes error %.2f" % s["err"]) if s["err"] is not None else ""))
if unk:
    print("  Hinweis: welle-cli meldet gelegentlich Schein-TII (hohes error, nur 1x) - erst nach mehreren Pruefungen werten.")
sys.stdout.flush()
if LIVE <= 0:
    raise SystemExit(0)
print("--- Live-Beobachtung %d s (Strg-C beendet vorzeitig, aendert nichts). Neue 11D-Pruefung erscheint hoechstens 1x je Minute. ---" % LIVE)
sys.stdout.flush()
live, last_t, n_live = {}, f11.get("t") or 0, 0
end = time.time() + LIVE
try:
    while time.time() < end:
        time.sleep(5)
        b = load_bs()
        f = (((b.get("t2") or {}).get("fig") or {}).get("11D") or {}) if isinstance(b.get("t2"), dict) else {}
        if not isinstance(f.get("t"), (int, float)) or f["t"] <= last_t:
            continue
        last_t = f["t"]; n_live += 1
        parts = []
        for y in f.get("tii") or []:
            if not isinstance(y, dict):
                continue
            k = key(y.get("main"), y.get("sub"))
            live[k] = live.get(k, 0) + 1
            parts.append("%s %s (error %s, delay %s km)" % (k, (name.get(k) or {}).get("mast", "nicht in MASTS_DB"), y.get("err"), y.get("km")))
        print("  %s 11D: %s" % (ts(f["t"]), "; ".join(parts) or "Sync ohne TII"))
        sys.stdout.flush()
except KeyboardInterrupt:
    print("\n  (Live-Beobachtung mit Strg-C beendet)")
print("Live-Ergebnis: %d neue Pruefungen; %s" % (n_live, "; ".join("%s %s %dx" % (k, (name.get(k) or {}).get("mast", "nicht in MASTS_DB"), n)
                                                                for k, n in sorted(live.items(), key=lambda z: -z[1])) or "keine TII"))
TFC2_EOF
PT="$W/patch-tiifix2-sdr.py"; SG="$W/guard_tiifix2.py"; CK="$W/tii2check.py"
for x in "$EXPECT_PT $PT" "$EXPECT_GUARD $SG" "$EXPECT_CK $CK"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 0) nur pruefen (nichts aendern) ----------
if [[ "$COMMIT_ARG" == pruefen ]]; then
  [[ -f "$DASH_DIR/broadcast_state.json" ]] || { echo "STOP: broadcast_state.json fehlt - nichts geaendert"; exit 1; }
  grep -q '# tiiFix2' "$M" && echo "tiiFix2 ist installiert (prepper_sdr.py sha16 $(sha256sum "$M" | cut -c1-16))" || echo "Hinweis: tiiFix2 noch nicht installiert - geprueft wird die aktuelle MASTS_DB"
  trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert"; exit 0' INT
  python3 "$CK" "$DASH_DIR" 600 || true
  echo "Pruefung fertig - nichts geaendert, nichts gesendet"
  exit 0
fi
# ---------- 1) Basis ----------
[[ -f "$M" && -f "$F" ]] || { echo "STOP: prepper_sdr.py/dashboard.py fehlt - nichts geaendert"; exit 1; }
S16=$(sha256sum "$M" | cut -c1-16)
echo "Basis prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $([[ "$S16" == "$KNOWN_SDR16" ]] && echo "bekannt (tiiFix)" || echo "neu, Erkennung ueber Guards"))"
grep -q '# ===== /sdrTeil4 =====' "$M" || { echo "STOP: Teil 4 fehlt in prepper_sdr.py - bitte zuerst apply-teil4.sh, nichts geaendert"; exit 1; }
grep -q '# tiiFix: TII-Paar -> Mastname' "$M" || { echo "STOP: tiiFix fehlt in prepper_sdr.py - bitte zuerst apply-tiifix.sh, nichts geaendert"; exit 1; }
python3 "$PT" "$M" "$W/work/prepper_sdr.py" > "$W/p.log" || { cat "$W/p.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: sdrTeil2 + sdrTeil4 + tiiFix, 5 tiiFix2-Stellen eindeutig -> $(cat "$W/p.log")"
a=$(systemctl is-active prepper-sdr 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: prepper-sdr ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
a=$(systemctl is-active prepper-dashboard 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: prepper-dashboard ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
# ---------- 2) Trockenlauf ----------
python3 "$PT" "$W/work/prepper_sdr.py" "$W/work/x.py" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/x.py" || { echo "STOP: nicht idempotent"; exit 1; }
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do "$py" -W error -m py_compile "$W/work/prepper_sdr.py" || { echo "STOP: py_compile ($py) - nichts geaendert"; exit 1; }; done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 300 "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest rdsNotfall ok" "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest OK:"; do
    [[ "$(cat "$W/selftest.log")" == *"$k"* ]] || { echo "STOP: Selbsttest ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY (Sandbox, kein Stick): sdrTeil2 (inkl. 08/01 -> Ochsenkopf, 07/02 -> Amberg, 07/12 -> Hohe Linie, TII eindeutig) + sdrTeil4 + aeltere Bloecke"
python3 "$SG" "$M" "$W/work/prepper_sdr.py" "$PT" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
masts_ok() { python3 -c "
import json,sys
try: m=json.load(open(sys.argv[1]))['t2']['masts']['11D']
except Exception: sys.exit(1)
sys.exit(0 if ['%02d/%02d' % (t.get('main'), t.get('sub')) for t in m.get('tii') or []] == sys.argv[2].split() and not m.get('sub_ids') else 1)" "$DASH_DIR/broadcast_state.json" "$EXP_PAIRS"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
D16=$(sha256sum "$F" | cut -c1-16)
# ---------- 3) Installieren (Strg-C wird bis fertig ignoriert) ----------
trap '' INT
RESTARTED=0
if cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK tiiFix2 schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sdrTeil|Traceback" | tail -6 | cut -c1-200 || true
    for x in "$M" "$DASH_DIR/broadcast_state.json"; do [[ -f "$x.bak-tiifix2-$TS" ]] && cp -a "$x.bak-tiifix2-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    for i in $(seq 1 60); do sleep 3; systemctl is-active --quiet prepper-sdr && break; done
    cmp -s "$M" "$M.bak-tiifix2-$TS" && echo "  prepper_sdr.py = Sicherung ($(sha256sum "$M" | cut -c1-16))" || echo "  WARNUNG prepper_sdr.py ungleich Sicherung"
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "$M" "$DASH_DIR/broadcast_state.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-tiifix2-$TS"
    { ls -1t "$x.bak-tiifix2-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-tiifix2-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  echo "Neustart: nur prepper-sdr - warte auf frischen SDR-Status (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr ohne frischen Status"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in /karte /dabhist /api/t2/status /api/t4/status /api/t4/map; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
[[ "$(sha256sum "$F" | cut -c1-16)" == "$D16" ]] && echo "OK dashboard.py unveraendert ($D16)" || rbx "dashboard.py hat sich veraendert"
echo "Warte, bis prepper-sdr die neue MASTS_DB meldet (max 180 s) ..."
ok=0; for i in $(seq 1 36); do masts_ok && { ok=1; break; }; sleep 5; done
[[ "$ok" == 1 ]] && echo "OK broadcast_state.json: MASTS_DB 11D mit $(echo $EXP_PAIRS | wc -w) Masten (08/18, 05/14, 05/01, 05/13 + 72 neue)" || rbx "prepper-sdr meldet die neue MASTS_DB nicht"
sleep 5
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrTeil[24] [a-z_ 0-9]+:" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrTeil-Fehler" || rbx "$E Traceback/sdrTeil-Fehlerzeilen im Journal prepper-sdr"
echo "OK guards tiiFix2=$(grep -c '# tiiFix2' "$M" || true) tiiFix=$(grep -c '# tiiFix' "$M" || true) sdrTeil2=$(grep -c '# ===== sdrTeil2:' "$M" || true) sdrTeil4=$(grep -c '# ===== sdrTeil4:' "$M" || true) rdsNotfall=$(grep -c '# ===== rdsNotfall:' "$M" || true)"
[[ -f "$M.bak-tiifix2-$TS" ]] && echo "Backups: *.bak-tiifix2-$TS (prepper_sdr.py, broadcast_state.json), behalten: letzte $KEEP_LAST"
for x in "$M" "$F" "$DASH_DIR/sdr_manager.py"; do echo "  $(basename "$x") sha16 $(sha256sum "$x" | cut -c1-16), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG tiifix2=1 - Einspielen fertig. Jetzt nur noch Empfangspruefung (nur lesen): Abbruch mit Strg-C aendert nichts."
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, tiiFix2 bleibt aktiv. COMMIT $COMMIT_ARG tiifix2=1"; exit 0' INT
echo "Neu in MASTS_DB 11D (TII laut fmlist.org 10A5, Abruf 17.10.2026, alle bisher nicht empfangen), Auszug:"
python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))['t2']['masts']['11D']['tii']
for t in m[4:9]: print('  %02d/%02d %s - ca. %s km, Standort %s m + Antenne %s m, %s kW' % (t['main'], t['sub'], t['mast'], t.get('km'), t.get('site_m'), t.get('ant_m'), t.get('erp_kw')))
print('  ... und %d weitere bis etwa 200 km (Liste unten bei NICHT EMPFANGEN / EMPFANGEN)' % (len(m) - 9))" "$DASH_DIR/broadcast_state.json" || true
echo "Hinweis: Pruefung spaeter jederzeit nur lesend: bash /tmp/tiifix2.sh pruefen"
python3 "$CK" "$DASH_DIR" 600 || true
echo "COMMIT $COMMIT_ARG tiifix2=1 fertig"
