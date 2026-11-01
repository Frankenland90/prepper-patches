#!/bin/bash
# shellcheck disable=SC2015
set -eEuo pipefail
# snFrei (commit59): Stick-/Airspy-Seriennummern raus aus den Programmdateien (prepper_sdr.py, sdr_manager.py, dashboard.py, database.py, prepper_docs.py).
#  - Selbsttests rechnen mit neutralen Platzhaltern (90000001..3, AB12CD34EF560001..3), die Doku-Tabelle zeigt "lokal".
#  - Die einzige Seriennummer, die das Programm selbst brauchte (Ersatzwert Stick 1, DEFAULT_SERIAL), liest prepper_sdr.py jetzt aus
#    sdr_serials.local.json im Projektordner (Rechte 600, nicht im Repo). Das Skript legt die Datei beim Einspielen aus dem bisherigen Wert an.
#    Die Werte werden NIE ausgegeben. Ohne Datei ist der Ersatzwert leer. Die Rollen kommen wie bisher aus sdr_config.json (unveraendert).
#  - Die Seriennummern werden auf dem Pi aus den bisherigen Dateien gelesen (feste Ankerstellen) und ersetzt; dieses Skript enthaelt keine.
# Aufruf: bash /tmp/apply-commit59.sh commit59 [dry-run]   (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein Neustart)
# Basis streng (sha16, Zielstand commit58): prepper_sdr.py 264ef34996e17753, sdr_manager.py 6dd122356d8f3ae1, dashboard.py 7d494c1a21e50e96, database.py e7a7ef192c522480, prepper_docs.py 43032d218135e329.
#  Ziel: prepper_sdr.py 50a41432722569f4, sdr_manager.py 5a26efff608bf541, dashboard.py 2d0412bbbecc25b3, database.py 2754d0bdddca9400, prepper_docs.py 2e1e23726611b2ec.
# Neustart: prepper-sdr und prepper-dashboard (fuer diesen Patch freigegeben), Sperre HH:55-HH:04 (Start ab HH:50 gesperrt).
# Pruefung danach: Dienste aktiv, Stick-Zuordnung wie vorher (gleiche Geraete), prepper_sdr.py selftest, Seiten/APIs wie vorher, Journal ohne Traceback.
# Fehler -> Rollback: 5 Dateien aus DATEI.bak-commit59-ZEIT, neue lokale Datei entfernt, beide Dienste erneut neu gestartet. Datenbank und sdr_config.json bleiben unberuehrt. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
W=/tmp/commit59-apply
NM=commit59
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
KEEP_LAST=3
FILES=(prepper_sdr.py sdr_manager.py dashboard.py database.py prepper_docs.py)
declare -A ALT=([prepper_sdr.py]=264ef34996e17753 [sdr_manager.py]=6dd122356d8f3ae1 [dashboard.py]=7d494c1a21e50e96 [database.py]=e7a7ef192c522480 [prepper_docs.py]=43032d218135e329)
declare -A NEU=([prepper_sdr.py]=50a41432722569f4 [sdr_manager.py]=5a26efff608bf541 [dashboard.py]=2d0412bbbecc25b3 [database.py]=2754d0bdddca9400 [prepper_docs.py]=2e1e23726611b2ec)
declare -A KEEP58=([lage_pages.py]=a9740c629a41806c [ups_manager.py]=ef0b9e3d4bf42003 [prepper_evlog.py]=8bffd396972b60fa)
KNOWN_P16_57="41f34abc4cabeb5a"   # prepper_docs.py vor commit58
LOCALF="$DASH_DIR/sdr_serials.local.json"
PHASE=vorher
FINISHED=0
RESTARTED=0
LOCAL_NEW=0
STOPPED=0
INST=()
ERRLN=""; ERRCMD=""
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
stop() { STOPPED=1; echo "STOP: $1 - nichts geaendert"; exit 1; }
SIM=0; [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && SIM=1
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
    elif [[ "$PHASE" == installiert && "${RB_DONE:-0}" == 0 ]]; then
      echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile ${ERRLN:-?}, Befehl: $(echo "${ERRCMD:-?}" | cut -c1-160) - Rollback"
      rb "unerwarteter Fehler" || true
    fi
  fi
  # Arbeitskopien mit den alten Werten bzw. dem lokalen Wert aufraeumen (Ordner bleibt 700 fuer die Diagnose)
  [[ -d "$W" ]] && rm -rf "$W/sn.json" "$W/lf.json" "$W"/st*/sdr_serials.local.json "$W/st_old" "$W/alt" "$W/map" 2>/dev/null || true
}
trap on_exit EXIT
echo "=== snFrei apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Seriennummern nur noch lokal (sdr_serials.local.json), Selbsttests mit Platzhaltern, Dashboard-Port $PORT ==="
umask 077
mkdir -p "$(dirname "$W")"
exec 9>"$W.lock"
flock -n 9 || stop "ein anderer commit59-Lauf ist aktiv (Sperre $W.lock)"
rm -rf "$W" && mkdir -p "$W/map" "$W/neu" "$W/st" "$W/st_old" "$W/st2" && chmod 700 "$W"
EXPECT_SNM="1e18dade2a7ae78af631e7c19199fefc6ccd5014912a42bf4e818a8e5e121e7f"
cat > "$W/snmap.py" << 'MK_SNM_EOF'
"""snFrei commit59: Stick-/Airspy-Seriennummern -> neutrale Platzhalter. Gibt NIE einen Wert aus.
  snmap.py extract DIR SNJSON          -> liest die 6 Werte an festen Ankerstellen aus DIR (prepper_sdr.py, prepper_docs.py), schreibt SNJSON (600)
  snmap.py map DIR_IN DIR_OUT SNJSON   -> ersetzt in den 5 Dateien jeden Wert durch seinen Platzhalter (Gross/Klein wie gefunden)
  snmap.py scan DIR SNJSON [DATEIEN]   -> zaehlt Restvorkommen (Ausgabe nur Zahlen)"""
import json
import os
import re
import sys

FILES = ["prepper_sdr.py", "sdr_manager.py", "dashboard.py", "database.py", "prepper_docs.py"]
KEYS = ["airspy", "airspy_doc", "airspy_t", "stick1", "stick2", "stick3"]
PH = {"airspy": "AB12CD34EF560001", "airspy_doc": "AB12CD34EF560002", "airspy_t": "AB12CD34EF560003",
      "stick1": "90000001", "stick2": "90000002", "stick3": "90000003"}
ANCHORS = [
    ("stick1", "prepper_sdr.py", r'^DEFAULT_SERIAL = "([0-9]{8})"  # Nooelec NESDR SMArt v5 von Frank$'),
    ("stick2", "prepper_sdr.py", r'^# ===== sdrTeil2: Teil 2 von 4 - Stick 1 \(SN [0-9]{8}\) fest auf 11D; Stick 2 \(SN ([0-9]{8})\) '),
    ("stick3", "prepper_sdr.py", r'^# ===== sdrStick3e: Stick 3 \(RTL2838UHIDIR, SN ([0-9]{8})\) als zweiter Hobby-Stick'),
    ("airspy", "prepper_sdr.py", r'dev\("1-1\.3", "1d50", "60a1", "([0-9A-F]{16})", "7"\)'),
    ("airspy_t", "prepper_sdr.py", r'\("serial", "([0-9a-fA-F]{16})"\), \("product", "AirSpy"\)\):$'),
    ("airspy_doc", "prepper_docs.py", r'^\| Airspy R2 \u00b7 11D \| Airspy R2 \| 1d50:60a1 \| ([0-9A-F]{16}) \|'),
]


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def extract(d):
    v = {}
    for k, fn, rx in ANCHORS:
        m = sorted(set(re.findall(rx, rd(os.path.join(d, fn)), re.M)))
        if len(m) != 1:
            raise SystemExit("extract: Ankerstelle %s in %s %d verschiedene Werte (erwartet 1)" % (k, fn, len(m)))
        v[k] = m[0]
    if len(set(x.lower() for x in v.values())) != len(KEYS):
        raise SystemExit("extract: Werte nicht verschieden")
    if any(x.lower() == PH[k].lower() for k, x in v.items()):
        raise SystemExit("extract: Wert ist schon ein Platzhalter")
    return v


def rx_of(x):
    return re.compile(r"(?<![0-9A-Za-z])" + re.escape(x) + r"(?![0-9A-Za-z])", re.I)


def mapping(s, v):
    for k in KEYS:
        ph = PH[k]
        s = rx_of(v[k]).sub(lambda m: ph.lower() if m.group(0) == m.group(0).lower() and not m.group(0).isdigit() else ph, s)
    return s


def count(s, v):
    return sum(len(re.findall(re.escape(x), s, re.I)) for x in v.values())


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "extract":
        v = extract(sys.argv[2])
        old = os.umask(0o077)
        with open(sys.argv[3], "w") as f:
            json.dump(v, f)
        os.umask(old)
        os.chmod(sys.argv[3], 0o600)
        print("extract ok: %d Werte (nicht ausgegeben)" % len(v) + "")
    elif c == "map":
        v = json.load(open(sys.argv[4]))
        n = 0
        for fn in FILES:
            s = rd(os.path.join(sys.argv[2], fn))
            t = mapping(s, v)
            if count(t, v):
                raise SystemExit("map: %s enthaelt danach noch Werte" % fn)
            n += count(s, v)
            with open(os.path.join(sys.argv[3], fn), "w", encoding="utf-8") as f:
                f.write(t)
        print("map ok: %d Stellen in %d Dateien neutral" % (n, len(FILES)))
    elif c == "scan":
        v = json.load(open(sys.argv[3]))
        fs = sys.argv[4:] or FILES
        tot = 0
        for fn in fs:
            p = fn if os.path.isabs(fn) else os.path.join(sys.argv[2], fn)
            n = count(rd(p), v)
            tot += n
            print("scan %s: %d" % (os.path.basename(p), n))
        print("scan gesamt: %d" % tot)
        sys.exit(1 if tot else 0)
MK_SNM_EOF
EXPECT_EDT="d8aa0d581b12cf4ccacf85cfd2970c9ed4d14cb3331ed2ac2dab9362b531061c"
cat > "$W/edits.py" << 'MK_EDT_EOF'
# commit59 snFrei - Textstellen NACH dem Platzhalter-Tausch (snmap.py); enthaelt keine echten Seriennummern
SDR_EDITS = [
    ('    "device": None, "serial": "90000001", "dab_tcp_port": 1235,',
     '    "device": None, "serial": "", "dab_tcp_port": 1235,'),
    ('DEFAULT_SERIAL = "90000001"  # Nooelec NESDR SMArt v5 von Frank\n',
     '# snFrei (commit59): Seriennummern stehen nicht im Programm, nur lokal auf dem Pi (sdr_config.json und\n'
     '# sdr_serials.local.json, Rechte 600, nicht im Repo). Ersatzwert ohne Datei: leer.\n'
     'SN_LOCAL_FILE = "sdr_serials.local.json"\n'
     'SNFREI_TEST_SERIAL = "90000001"   # neutraler Platzhalter, nur fuer die Selbsttests\n'
     '\n'
     '\n'
     'def _snfrei_local(key):\n'
     '    try:\n'
     '        with open(os.path.join(BASE, SN_LOCAL_FILE), encoding="utf-8") as f:\n'
     '            v = json.load(f)\n'
     '        v = str((v if isinstance(v, dict) else {}).get(key) or "").strip()\n'
     '        return v if re.match(r"^[0-9]{1,16}$", v) else ""\n'
     '    except Exception:\n'
     '        return ""\n'
     '\n'
     '\n'
     'DEFAULT_SERIAL = _snfrei_local("stick1")  # Stick 1 (Nooelec NESDR SMArt v5), Wert nur lokal\n'
     'DEFAULT_CFG["serial"] = DEFAULT_SERIAL\n'
     '\n'
     '\n'
     'def _snfrei_selftest_mode():\n'
     '    """Selbsttests rechnen mit dem neutralen Platzhalter statt mit der lokalen Seriennummer (nur im Testprozess)."""\n'
     '    global DEFAULT_SERIAL\n'
     '    DEFAULT_SERIAL = SNFREI_TEST_SERIAL\n'
     '    DEFAULT_CFG["serial"] = DEFAULT_SERIAL\n'
     '\n'
     '\n'),
    ('# ===== sdrTeil2: Teil 2 von 4 - Stick 1 (SN 90000001) fest auf 11D; Stick 2 (SN 90000002) Hobby/Bereitschaft',
     '# ===== sdrTeil2: Teil 2 von 4 - Stick 1 fest auf 11D; Stick 2 Hobby/Bereitschaft'),
    ('# ===== sdrStick3e: Stick 3 (RTL2838UHIDIR, SN 90000003) als zweiter Hobby-Stick',
     '# ===== sdrStick3e: Stick 3 (RTL2838UHIDIR) als zweiter Hobby-Stick'),
    ('assert sorted(s) == ["00000003", "90000001", "AB12CD34EF560001", "90000002"] and s["90000001"]',
     'assert sorted(s) == ["00000003", "90000001", "90000002", "AB12CD34EF560001"] and s["90000001"]'),
    ('    elif a == "selftest":\n        selftest()\n',
     '    elif a == "selftest":\n        _snfrei_selftest_mode()   # snFrei\n        selftest()\n'),
]
DOC_EDITS = [
    ('Rollen sind seit 23.10.2026 fest nach Seriennummer vergeben (Geraete-Register in sdr_config.json, Schluessel devs):\n',
     'Rollen sind seit 23.10.2026 fest nach Seriennummer vergeben (Geraete-Register in sdr_config.json, Schluessel devs). Die Seriennummern selbst stehen nur lokal auf dem Pi (sdr_config.json und sdr_serials.local.json, Rechte 600, Patch snFrei commit59), nicht in Programmdateien, Repo oder dieser Beschreibung:\n'),
    ('| 1d50:60a1 | AB12CD34EF560002 | fest DAB 11D', '| 1d50:60a1 | lokal | fest DAB 11D'),
    ('| 0bda:2838 | 90000001 | fest DAB 5C', '| 0bda:2838 | lokal | fest DAB 5C'),
    ('| 0bda:2838 | 90000002 | Hobby: UKW-RDS', '| 0bda:2838 | lokal | Hobby: UKW-RDS'),
    ('| 0bda:2838 | 90000003 | zweiter Hobby-Stick', '| 0bda:2838 | lokal | zweiter Hobby-Stick'),
    ('- Stick 3 (Realtek RTL2838UHIDIR, SN 90000003, Register-Rolle hobby2)', '- Stick 3 (Realtek RTL2838UHIDIR, Register-Rolle hobby2)'),
    ('(Stick 3 bekommt die eindeutige Seriennummer 90000003 per rtl_eeprom;', '(Stick 3 bekommt eine eindeutige Seriennummer per rtl_eeprom;'),
    ('- sdrStick3c: Seriennummer fuer Stick 3 (90000003) per rtl_eeprom schreiben und Stick umstecken (erledigt; Stick 3 hat die SN 90000003).',
     '- sdrStick3c: eindeutige Seriennummer fuer Stick 3 per rtl_eeprom schreiben und Stick umstecken (erledigt).'),
    ('Stick 3 (Hobby, SN 90000003) wird nur von prepper-sdr geoeffnet', 'Stick 3 (Hobby) wird nur von prepper-sdr geoeffnet'),
    ('und dokuStand (58, nur diese Datei, Generator-Version 3).',
     'und dokuStand (58, nur diese Datei, Generator-Version 3); danach snFrei (59): Stick-Seriennummern nur noch lokal (sdr_serials.local.json), Selbsttests mit neutralen Platzhaltern.'),
]
EDITS = {"prepper_sdr.py": SDR_EDITS, "prepper_docs.py": DOC_EDITS}
MK_EDT_EOF
EXPECT_PPK="338b544e24641d9f604b1d9da6b18b80f8c08ac4c332c863d1976bdec4639ba1"
cat > "$W/patch.py" << 'MK_PPK_EOF'
"""patch59.py IN_DIR OUT_DIR EDITS -> wendet die Textstellen (nach snmap) an. Jede alte Stelle genau 1x, neue 0x; Exit 2 bei Teilzustand."""
import os
import sys

src, dst, ep = sys.argv[1:4]
g = {}
exec(open(ep, encoding="utf-8").read(), g)
for fn, eds in g["EDITS"].items():
    s = open(os.path.join(src, fn), encoding="utf-8").read()
    for i, (o, n) in enumerate(eds, 1):
        co, cn = s.count(o), s.count(n)
        if co == 1 and (cn == 0 or n.find(o) >= 0):
            s = s.replace(o, n, 1)
        else:
            print("%s Stelle %d: alt %dx, neu %dx" % (fn, i, co, cn))
            sys.exit(2)
    open(os.path.join(dst, fn), "w", encoding="utf-8").write(s)
    print("%s: %d Stellen snFrei" % (fn, len(eds)))
MK_PPK_EOF
EXPECT_EQC="42f6167599f56f330c8cdbd099b8c99decacd960b66c8f966a503566e9505eae"
cat > "$W/eqcheck.py" << 'MK_EQC_EOF'
"""eqcheck.py CODE_DIR DATA_DIR -> Fingerprint der Stick-Zuordnung, die prepper_sdr.py (aus CODE_DIR) aus DATA_DIR ableitet.
Gibt nur sha256-Kurzwerte aus, nie Seriennummern. Vergleich alt/neu macht der Aufrufer."""
import hashlib
import importlib.util
import json
import os
import sys
import tempfile

code, data = sys.argv[1], sys.argv[2]
sys.path.insert(0, code)
spec = importlib.util.spec_from_file_location("prepper_sdr", os.path.join(code, "prepper_sdr.py"))
m = importlib.util.module_from_spec(spec)
sys.modules["prepper_sdr"] = m
spec.loader.exec_module(m)
h = lambda o: hashlib.sha256(json.dumps(o, sort_keys=True, default=str).encode()).hexdigest()[:16]
c = m.config(data)
empty = tempfile.mkdtemp(prefix="eq59")
ce = m.config(empty)
c2 = getattr(m, "cfg_serial2", lambda x: None)
print("cfg", h(c))
print("sn", h([m.cfg_serial(c), c2(c)]))
print("leer", h([m.cfg_serial(ce), m.DEFAULT_SERIAL]))
MK_EQC_EOF
EXPECT_GRD="6b58b24ae610e413196657f0214b6f7e573a5d5b8acbbae11cc1ff22ca693231"
cat > "$W/guard.py" << 'MK_GRD_EOF'
"""Guard snFrei commit59 (prepper_sdr.py, sdr_manager.py, dashboard.py, database.py, prepper_docs.py). Gibt NIE eine Seriennummer aus.
  guard59.py check  ALT_VERZ NEU_VERZ EDITS SNJSON  -> Regeln (keine echte SN mehr, Rest byte-genau = Platzhalter-Tausch + Stellen, lokale Konfig richtig verdrahtet)
  guard59.py mutate ALT_VERZ NEU_VERZ EDITS SNJSON  -> Mutationstest (jede Verfehlung muss erkannt werden)
Nur lesend ausser einem Temp-Ordner; kein Netz, keine Dienste."""
import ast
import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import snmap  # noqa: E402

FILES = snmap.FILES
PHS = set(x.upper() for x in snmap.PH.values())
HEX16 = re.compile(r"(?<![0-9A-Za-z])[0-9A-Fa-f]{16}(?![0-9A-Za-z])")


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(rd(ep), g)
    return g["EDITS"]


def check(alt, neu, ep, snj):
    v = json.load(open(snj))
    E = load_edits(ep)
    errs = []
    for fn in FILES:
        p = os.path.join(neu, fn)
        if not os.path.isfile(p):
            errs.append("%s fehlt" % fn)
            continue
        s = rd(p)
        n = snmap.count(s, v)
        if n:
            errs.append("%s: %d echte Seriennummer(n) stehen noch drin" % (fn, n))
        a = rd(os.path.join(alt, fn))
        m = snmap.mapping(a, v)
        # verlustfrei: Platzhalter kamen in ALT nicht vor
        if any(ph.lower() in a.lower() for ph in PHS):
            errs.append("%s: Platzhalter stand schon im alten Stand (Tausch nicht eindeutig)" % fn)
        bad = sorted(set(x for x in HEX16.findall(s) if not x.isdigit() and x.upper() not in PHS and x not in HEX16.findall(m)))
        if bad:
            errs.append("%s: %d neue 16-stellige Hex-Kennung(en)" % (fn, len(bad)))
        r = s
        for i, (o, nn) in reversed(list(enumerate(E.get(fn, []), 1))):
            if r.count(nn) != 1:
                errs.append("%s Stelle %d: neue Fassung %dx statt 1x" % (fn, i, r.count(nn)))
                continue
            r = r.replace(nn, o, 1)
        if r != m:
            errs.append("%s: Rueckbau ergibt nicht byte-genau den alten Stand mit Platzhaltern (Aenderung ausserhalb der Stellen?)" % fn)
    if not errs:
        s = rd(os.path.join(neu, "prepper_sdr.py"))
        t = ast.parse(s)
        top = {}
        for nd in t.body:
            if isinstance(nd, ast.Assign) and len(nd.targets) == 1:
                tg = nd.targets[0]
                if isinstance(tg, ast.Name):
                    top.setdefault(tg.id, []).append(nd)
                elif isinstance(tg, ast.Subscript) and isinstance(tg.value, ast.Name):
                    top.setdefault("%s[%s]" % (tg.value.id, ast.unparse(tg.slice)), []).append(nd)
            if isinstance(nd, ast.FunctionDef):
                top.setdefault("def " + nd.name, []).append(nd)
        def lit(name):
            n = top.get(name, [])
            return ast.unparse(n[-1].value) if n else None
        dc = top.get("DEFAULT_CFG", [None])[0]
        keys = {}
        if dc is not None and isinstance(dc.value, ast.Dict):
            keys = {ast.literal_eval(k): ast.unparse(vv) for k, vv in zip(dc.value.keys, dc.value.values) if k is not None}
        if keys.get("serial") != "''":
            errs.append("DEFAULT_CFG: Schluessel serial fehlt oder ist nicht leer")
        if lit("SN_LOCAL_FILE") != "'sdr_serials.local.json'":
            errs.append("SN_LOCAL_FILE nicht sdr_serials.local.json")
        if lit("DEFAULT_SERIAL") != "_snfrei_local('stick1')" or len(top.get("DEFAULT_SERIAL", [])) != 1:
            errs.append("DEFAULT_SERIAL nicht aus der lokalen Konfig (stick1)")
        if lit("DEFAULT_CFG['serial']") != "DEFAULT_SERIAL":
            errs.append("DEFAULT_CFG['serial'] = DEFAULT_SERIAL fehlt")
        else:
            if top["DEFAULT_CFG['serial']"][0].lineno < top["DEFAULT_SERIAL"][0].lineno:
                errs.append("DEFAULT_CFG['serial'] vor DEFAULT_SERIAL")
        fl = top.get("def _snfrei_local")
        src = ast.unparse(fl[0]) if fl else ""
        if "os.path.join(BASE, SN_LOCAL_FILE)" not in src or "'^[0-9]{1,16}$'" not in src or "return ''" not in src:
            errs.append("_snfrei_local: Pfad (BASE), Ziffernpruefung oder Ersatzwert leer falsch")
        fm = top.get("def _snfrei_selftest_mode")
        if not fm or "DEFAULT_SERIAL = SNFREI_TEST_SERIAL" not in ast.unparse(fm[0]) or "DEFAULT_CFG['serial'] = DEFAULT_SERIAL" not in ast.unparse(fm[0]):
            errs.append("_snfrei_selftest_mode falsch")
        if lit("SNFREI_TEST_SERIAL") != "'90000001'":
            errs.append("SNFREI_TEST_SERIAL nicht der Platzhalter")
        if not re.search(r'elif a == "selftest":\n        _snfrei_selftest_mode\(\)   # snFrei\n        selftest\(\)\n', s):
            errs.append("Selbsttest-Aufruf setzt den Platzhalter nicht zuerst")
        d = rd(os.path.join(neu, "prepper_docs.py"))
        if d.count(" | lokal | ") != 4 or "sdr_config.json und sdr_serials.local.json, Rechte 600" not in d:
            errs.append("Doku: Stick-Tabelle nicht neutral (4x lokal) oder lokale Datei nicht genannt")
        for ph in ("90000001", "90000002", "90000003", "AB12CD34EF56000"):
            core = d[d.find("CORE = r'''"):]
            core = core[:core.find("'''", 12)]
            if ph in core:
                errs.append("Doku-Text nennt noch einen Platzhalter")
                break
    if errs:
        for e in errs:
            print("VERSTOSS: " + e)
        return 1
    print("check ok: %d Dateien ohne echte Seriennummer, Rest byte-genau = Platzhalter-Tausch + %d Stellen, lokale Konfig sdr_serials.local.json verdrahtet, Selbsttest-Platzhalter, Doku neutral"
          % (len(FILES), sum(len(x) for x in E.values())))
    return 0


def mutate(alt, neu, ep, snj):
    v = json.load(open(snj))
    tmp = tempfile.mkdtemp(prefix="g59m")
    M = []

    def sub(fn, o, n, cnt=1):
        def f(d):
            p = os.path.join(d, fn)
            s = rd(p)
            assert s.count(o) >= 1, (fn, "Mutationsstelle fehlt")
            open(p, "w", encoding="utf-8").write(s.replace(o, n, cnt))
        return f
    M.append(("echte SN Stick 1 in dashboard.py", sub("dashboard.py", '"90000001"', '"%s"' % v["stick1"])))
    M.append(("echte SN Stick 2 in sdr_manager.py", sub("sdr_manager.py", '90000002', v["stick2"])))
    M.append(("echte SN Stick 3 in prepper_docs.py (Text)", sub("prepper_docs.py", "- Stick 3 (Realtek RTL2838UHIDIR, Register-Rolle hobby2)", "- Stick 3 (Realtek RTL2838UHIDIR, SN %s, Register-Rolle hobby2)" % v["stick3"])))
    M.append(("echte Airspy-SN klein in prepper_sdr.py", sub("prepper_sdr.py", "AB12CD34EF560001", v["airspy"].lower())))
    M.append(("echte Airspy-SN (Doku-Wert) in dashboard.py", sub("dashboard.py", "AB12CD34EF560002", v["airspy_doc"])))
    M.append(("echte Airspy-Testkennung in prepper_sdr.py", sub("prepper_sdr.py", "ab12cd34ef560003", v["airspy_t"])))
    M.append(("echte SN Stick 1 in database.py", sub("database.py", "90000001", v["stick1"])))
    M.append(("DEFAULT_SERIAL fest im Programm", sub("prepper_sdr.py", 'DEFAULT_SERIAL = _snfrei_local("stick1")', 'DEFAULT_SERIAL = "90000001"')))
    M.append(("DEFAULT_CFG ohne Schluessel serial", sub("prepper_sdr.py", '"device": None, "serial": "", ', '"device": None, ')))
    M.append(("DEFAULT_CFG serial nicht leer", sub("prepper_sdr.py", '"device": None, "serial": "", ', '"device": None, "serial": "90000001", ')))
    M.append(("DEFAULT_CFG['serial'] = DEFAULT_SERIAL fehlt", sub("prepper_sdr.py", 'DEFAULT_CFG["serial"] = DEFAULT_SERIAL\n\n\ndef _snfrei_selftest_mode', '\n\ndef _snfrei_selftest_mode')))
    M.append(("andere lokale Datei", sub("prepper_sdr.py", 'SN_LOCAL_FILE = "sdr_serials.local.json"', 'SN_LOCAL_FILE = "sdr_config.json"')))
    M.append(("lokale Datei aus dem Arbeitsordner statt BASE", sub("prepper_sdr.py", "os.path.join(BASE, SN_LOCAL_FILE)", "os.path.join(os.getcwd(), SN_LOCAL_FILE)")))
    M.append(("Ziffernpruefung gelockert", sub("prepper_sdr.py", 'return v if re.match(r"^[0-9]{1,16}$", v) else ""', 'return v')))
    M.append(("Ersatzwert nicht leer", sub("prepper_sdr.py", '    except Exception:\n        return ""\n\n\nDEFAULT_SERIAL', '    except Exception:\n        return "90000001"\n\n\nDEFAULT_SERIAL')))
    M.append(("Selbsttest ohne Platzhalter-Modus", sub("prepper_sdr.py", "        _snfrei_selftest_mode()   # snFrei\n", "")))
    M.append(("Platzhalter-Modus setzt DEFAULT_CFG nicht", sub("prepper_sdr.py", '    DEFAULT_SERIAL = SNFREI_TEST_SERIAL\n    DEFAULT_CFG["serial"] = DEFAULT_SERIAL\n', '    DEFAULT_SERIAL = SNFREI_TEST_SERIAL\n')))
    M.append(("sortierte Liste nicht angepasst", sub("prepper_sdr.py", '["00000003", "90000001", "90000002", "AB12CD34EF560001"]', '["00000003", "90000001", "AB12CD34EF560001", "90000002"]')))
    M.append(("Kommentar sdrTeil2 nicht neutral", sub("prepper_sdr.py", "Stick 1 fest auf 11D; Stick 2 Hobby", "Stick 1 (SN 90000001) fest auf 11D; Stick 2 (SN 90000002) Hobby")))
    M.append(("zusaetzliche Zeile in prepper_sdr.py", sub("prepper_sdr.py", "SNFREI_TEST_SERIAL = ", "X_EXTRA = 1\nSNFREI_TEST_SERIAL = ")))
    M.append(("Zeichen in dashboard.py geaendert", sub("dashboard.py", "import ", "import  ")))
    M.append(("anderer Platzhalter in sdr_manager.py", sub("sdr_manager.py", "90000002", "90000004")))
    M.append(("Platzhalter Gross/Klein vertauscht in dashboard.py", sub("dashboard.py", "AB12CD34EF560001", "ab12cd34ef560001")))
    M.append(("Doku-Tabelle mit Platzhalter statt lokal", sub("prepper_docs.py", "| 0bda:2838 | lokal | fest DAB 5C", "| 0bda:2838 | 90000001 | fest DAB 5C")))
    M.append(("Doku nennt lokale Datei nicht", sub("prepper_docs.py", "(sdr_config.json und sdr_serials.local.json, Rechte 600, Patch snFrei commit59)", "(sdr_config.json, Rechte 600, Patch snFrei commit59)")))
    M.append(("neue Hex-Kennung in dashboard.py", sub("dashboard.py", "AB12CD34EF560001", "C0FFEE00C0FFEE01")))

    def rm(d):
        os.remove(os.path.join(d, "database.py"))
    M.append(("Datei fehlt", rm))
    # Semantik-Mutanten: Datei UND Stellen-Liste gleich veraendert (byte-genauer Rueckbau passt dann) -> muss die Verdrahtungspruefung finden
    SEM = [("DEFAULT_SERIAL fest im Programm", 'DEFAULT_SERIAL = _snfrei_local("stick1")', 'DEFAULT_SERIAL = "90000001"'),
           ("DEFAULT_CFG serial nicht leer", '"device": None, "serial": "", ', '"device": None, "serial": "90000001", '),
           ("DEFAULT_CFG ohne serial", '"device": None, "serial": "", ', '"device": None, '),
           ("DEFAULT_CFG['serial'] fehlt", 'DEFAULT_CFG["serial"] = DEFAULT_SERIAL\n\n\ndef _snfrei_selftest_mode', '\n\ndef _snfrei_selftest_mode'),
           ("andere lokale Datei", 'SN_LOCAL_FILE = "sdr_serials.local.json"', 'SN_LOCAL_FILE = "sdr_config.json"'),
           ("Pfad cwd statt BASE", "os.path.join(BASE, SN_LOCAL_FILE)", "os.path.join(os.getcwd(), SN_LOCAL_FILE)"),
           ("Ziffernpruefung weg", 'return v if re.match(r"^[0-9]{1,16}$", v) else ""', 'return v'),
           ("Ersatzwert nicht leer", '    except Exception:\n        return ""\n', '    except Exception:\n        return "90000001"\n'),
           ("Selbsttest ohne Platzhalter-Modus", "        _snfrei_selftest_mode()   # snFrei\n", "        pass   # snFrei\n"),
           ("Platzhalter-Modus ohne DEFAULT_CFG", '    DEFAULT_SERIAL = SNFREI_TEST_SERIAL\n    DEFAULT_CFG["serial"] = DEFAULT_SERIAL\n', '    DEFAULT_SERIAL = SNFREI_TEST_SERIAL\n'),
           ("Test-Platzhalter = echte Form", 'SNFREI_TEST_SERIAL = "90000001"', 'SNFREI_TEST_SERIAL = "90000009"'),
           ("Doku-Tabelle Platzhalter", "| 0bda:2838 | lokal | fest DAB 5C", "| 0bda:2838 | 90000001 | fest DAB 5C"),
           ("Doku ohne lokale Datei", "(sdr_config.json und sdr_serials.local.json, Rechte 600, Patch snFrei commit59)", "(sdr_config.json, Rechte 600, Patch snFrei commit59)")]
    E0 = load_edits(ep)
    for name, o, n in SEM:
        o = o.encode().decode("unicode_escape"); n = n.encode().decode("unicode_escape")
        fn = "prepper_docs.py" if "Doku" in name else "prepper_sdr.py"
        E2 = {k: [(a, b.replace(o, n)) for a, b in vv] for k, vv in E0.items()}
        if E2 == E0:
            print("MUTATION NICHT ANWENDBAR (Stellen): %s" % name)
            M.append(("SEM " + name, None))
            continue
        ep2 = os.path.join(tmp, "e_%d.py" % len(M))
        open(ep2, "w", encoding="utf-8").write("EDITS = " + repr(E2) + "\n")
        M.append(("SEM " + name, (sub(fn, o, n), ep2)))
    miss = 0
    for name, f in M:
        epx = ep
        if isinstance(f, tuple):
            f, epx = f
        if f is None:
            miss += 1
            continue
        d = os.path.join(tmp, "n")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(neu, d, ignore=shutil.ignore_patterns("__pycache__"))
        try:
            f(d)
        except AssertionError as e:
            print("MUTATION NICHT ANWENDBAR: %s (%s)" % (name, e))
            miss += 1
            continue
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = check(alt, d, epx, snj)
        out = buf.getvalue()
        if rc == 0:
            print("NICHT ERKANNT: %s" % name)
            miss += 1
        else:
            first = [x for x in out.splitlines() if x.startswith("VERSTOSS")][:1]
            print("OK erkannt: %-48s -> %s" % (name, (first[0][10:] if first else "?")[:110]))
    shutil.rmtree(tmp, ignore_errors=True)
    print("Mutationstest: %d Mutationen, %d nicht erkannt" % (len(M), miss))
    return 1 if miss else 0


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "check":
        sys.exit(check(*sys.argv[2:6]))
    elif c == "mutate":
        sys.exit(mutate(*sys.argv[2:6]))
    print("unbekannt")
    sys.exit(64)
MK_GRD_EOF
for x in "$EXPECT_SNM $W/snmap.py" "$EXPECT_EDT $W/edits.py" "$EXPECT_PPK $W/patch.py" "$EXPECT_EQC $W/eqcheck.py" "$EXPECT_GRD $W/guard.py"; do
  read -r xs xf <<< "$x"; echo "$xs  $xf" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$xf") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Tausch, Stellen, Patcher, Vergleich, Pruefprogramm)"
# ---------- 1) Basis ----------
NA=0; NN=0; ODD=""
for f in "${FILES[@]}"; do
  [[ -f "$DASH_DIR/$f" ]] || stop "$f fehlt im Projektordner $DASH_DIR"
  h=$(s16 "$DASH_DIR/$f")
  if [[ "$h" == "${ALT[$f]}" ]]; then NA=$((NA + 1)); elif [[ "$h" == "${NEU[$f]}" ]]; then NN=$((NN + 1)); else ODD+="$f=$h "; fi
done
if [[ -n "$ODD" ]]; then
  [[ "$(s16 "$DASH_DIR/prepper_docs.py")" == "$KNOWN_P16_57" ]] && stop "prepper_docs.py ist der Stand vor commit58 - bitte erst commit58 einspielen, dann commit59"
  stop "Stand weicht ab: ${ODD}(erwartet Zielstand commit58 oder schon commit59). Bitte diese Ausgabe an Grok schicken"
fi
STATE=""
if [[ "$NA" == 5 ]]; then STATE=alt; echo "OK Basis: Zielstand commit58 (5 Dateien wie erwartet)"
elif [[ "$NN" == 5 ]]; then STATE=neu; echo "OK commit59 ist schon installiert (5 Dateien im Zielstand)"
else stop "Mischstand: $NA Datei(en) commit58, $NN Datei(en) commit59 - bitte diese Ausgabe an Grok schicken"; fi
for bf in "${!KEEP58[@]}"; do
  [[ -f "$DASH_DIR/$bf" ]] || stop "$bf fehlt im Projektordner"
  b16=$(s16 "$DASH_DIR/$bf"); [[ "$b16" == "${KEEP58[$bf]}" ]] || stop "$bf sha16 $b16 ist nicht der Zielstand commit58 (${KEEP58[$bf]})"
done
echo "OK lage_pages.py, ups_manager.py, prepper_evlog.py wie commit58 (bleiben unveraendert)"
lfok() { [[ -f "$LOCALF" ]] && python3 - "$LOCALF" << 'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if isinstance(d, dict) and re.match(r"^[0-9]{1,16}$", str(d.get("stick1") or "")) else 1)
except Exception:
    sys.exit(1)
PY
}
if [[ "$STATE" == neu ]]; then
  lfok || stop "commit59 ist installiert, aber $LOCALF fehlt oder ist ungueltig. Wiederherstellen: die Sicherungen *.bak-$NM-* zurueckkopieren und commit59 neu einspielen (Seriennummer steht nur in der Sicherung)"
  [[ "$(stat -c %a "$LOCALF")" == 600 ]] || { [[ "$DRY" == 1 ]] && echo "HINWEIS $LOCALF hat Rechte $(stat -c %a "$LOCALF") statt 600" || { chmod 600 "$LOCALF"; echo "OK Rechte $LOCALF auf 600 gesetzt"; }; }
  echo "OK lokale Datei sdr_serials.local.json vorhanden (Rechte $(stat -c %a "$LOCALF"), Inhalt gueltig, Wert nicht ausgegeben)"
  FINISHED=1
  echo "COMMIT $COMMIT_ARG snfrei=1 fertig (schon installiert, nichts geaendert, kein Neustart)"
  exit 0
fi
fp() { python3 - "$DASH_DIR/sdr_status.json" << 'PY'
import hashlib, json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("? 0 0 0 -"); sys.exit(0)
it = [("main", d.get("sn") or d.get("serial"), d.get("pin_err") is None)]
du = d.get("dual") or {}
for i in (1, 2, 3, 4):
    it.append(("dual%d" % i, du.get("sn%d" % i), None))
for k in ("s2", "s3", "s4"):
    s = d.get(k) or {}
    it.append((k, s.get("sn"), (s.get("pin_err") is None) if s else None))
s2 = d.get("stick2") or {}
it.append(("stick2", s2.get("serial"), s2.get("present")))
it.append(("sticks_n", d.get("sticks_n"), None))
h = hashlib.sha256(json.dumps(it, sort_keys=True, default=str).encode()).hexdigest()[:16]
per = ",".join("%s:%s" % (a, hashlib.sha256(json.dumps([b, c], default=str).encode()).hexdigest()[:12]) for a, b, c in it if b)
print(h, sum(1 for x in it[:-1] if x[1]), sum(1 for x in it if x[2] is True), int(d.get("t") or 0), per or "-")
PY
}
read -r FPA FPNA FPPA FPTA FPIA <<< "$(fp)"
if [[ -e "$LOCALF" ]]; then echo "HINWEIS $LOCALF gibt es schon (wird geprueft, nicht ueberschrieben)"; fi
[[ -w "$DASH_DIR" ]] || stop "Projektordner nicht beschreibbar"
for f in "${FILES[@]}"; do [[ -w "$DASH_DIR/$f" ]] || stop "$f ist nicht beschreibbar"; done
"$VPY" -c "import sys; assert sys.version_info >= (3, 9)" 2>/dev/null || stop "Python der venv ($VPY) ist aelter als 3.9 oder nicht startbar"
ME=$(id -un)
for u in prepper-sdr prepper-dashboard; do
  su=$(systemctl show -p User --value "$u" 2>/dev/null | head -1 || true)
  if [[ -n "$su" && "$su" != root && "$su" != "$ME" ]]; then stop "Dienst $u laeuft als Benutzer $su, nicht $ME/root - die lokale Datei (600, Eigentuemer $ME) waere fuer ihn nicht lesbar"; fi
done
echo "OK Dienstbenutzer passen zur lokalen Datei (600, Eigentuemer $ME)"
# ---------- 2) Sandbox (alles auf Kopien in $W, Rechte 700) ----------
python3 "$W/snmap.py" extract "$DASH_DIR" "$W/sn.json" > "$W/x.log" 2>&1 || { cat "$W/x.log"; stop "Seriennummern an den Ankerstellen nicht eindeutig lesbar"; }
echo "OK $(cat "$W/x.log")"
python3 "$W/snmap.py" map "$DASH_DIR" "$W/map" "$W/sn.json" > "$W/m.log" 2>&1 || { cat "$W/m.log"; stop "Platzhalter-Tausch fehlgeschlagen"; }
echo "OK $(cat "$W/m.log")"
cp "$W/map/"*.py "$W/neu/"
python3 "$W/patch.py" "$W/map" "$W/neu" "$W/edits.py" > "$W/p.log" 2>&1 || { cat "$W/p.log"; stop "Textstellen nicht eindeutig"; }
for f in "${FILES[@]}"; do
  h=$(s16 "$W/neu/$f"); [[ "$h" == "${NEU[$f]}" ]] || stop "Ergebnis $f $h statt ${NEU[$f]} (Zielstand nicht erreicht)"
done
echo "OK Ergebnis wie erwartet (5 Dateien im Zielstand commit59; $(tr '\n' ' ' < "$W/p.log"))"
python3 "$W/snmap.py" scan "$W/neu" "$W/sn.json" > "$W/s.log" 2>&1 || { cat "$W/s.log"; stop "im Ergebnis steht noch eine Seriennummer"; }
echo "OK im Ergebnis steht keine der Seriennummern mehr (geprueft gegen die echten Werte, nicht ausgegeben)"
for py in "$SPY" "$VPY"; do
  for x in "$W"/neu/*.py "$W"/*.py; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK py_compile ohne Warnung ($SPY und $VPY)"
mkdir -p "$W/alt"; for f in "${FILES[@]}"; do cp "$DASH_DIR/$f" "$W/alt/"; done
nice -n 10 python3 "$W/guard.py" check "$W/alt" "$W/neu" "$W/edits.py" "$W/sn.json" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "Guard commit59 meldet Verstoss"; }
echo "OK Guard: $(cut -c1-220 "$W/g.log")"
MUTS=1; [[ -n "${C59_SIM_NOMUT:-}" && "$SIM" == 1 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen"; }
if [[ "$MUTS" == 1 ]]; then
  nice -n 10 python3 "$W/guard.py" mutate "$W/alt" "$W/neu" "$W/edits.py" "$W/sn.json" > "$W/gm.log" 2>&1 || { grep -E "NICHT|Mutationstest" "$W/gm.log" | cut -c1-120; stop "Mutationstest commit59: eine Verfehlung wurde nicht erkannt"; }
  echo "OK $(grep -E '^Mutationstest' "$W/gm.log")"
fi
rm -rf "$W/alt"
# Selbsttests auf Kopien (alter Stand fuer den Vergleich, neuer Stand fuer die Tests)
for f in "$DASH_DIR"/*.py; do cp "$f" "$W/st_old/"; cp "$f" "$W/st/"; done
cp "$W/neu/"*.py "$W/st/"
stt() { local d="$1" lg="$2" rc=0
  ( cd "$d" && timeout 600 nice -n 10 "$SPY" prepper_sdr.py selftest ) > "$lg.sdr" 2>&1 || rc=1
  ( cd "$d" && timeout 300 nice -n 10 "$SPY" sdr_manager.py selftest ) > "$lg.mgr" 2>&1 || rc=$((rc + 2))
  ( cd "$d" && timeout 300 nice -n 10 "$VPY" database.py selftest ) > "$lg.db" 2>&1 || rc=$((rc + 4))
  return $rc; }
stt "$W/st" "$W/stn" || { tail -n 4 "$W"/stn.* | python3 -c 'import re,sys; [print("  | " + re.sub(r"[0-9A-Fa-f]{8,}", "<..>", l.rstrip())[:200]) for l in sys.stdin]'; stop "Selbsttest im neuen Stand fehlgeschlagen (prepper_sdr/sdr_manager/database)"; }
echo "OK Selbsttests neuer Stand (Sandbox): prepper_sdr.py selftest, sdr_manager.py selftest, database.py selftest ohne Fehler"
python3 - "$W/sn.json" "$W/st/sdr_serials.local.json" << 'PY'
import json, os, sys
v = json.load(open(sys.argv[1]))
old = os.umask(0o077)
with open(sys.argv[2], "w") as f:
    json.dump({"stick1": v["stick1"]}, f)
os.umask(old)
os.chmod(sys.argv[2], 0o600)
PY
cp "$W/st/sdr_serials.local.json" "$W/lf.json"
( cd "$W" && PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/eqcheck.py" "$W/st_old" "$DASH_DIR" ) > "$W/eq0.txt" 2>"$W/eq0.err" || { tail -3 "$W/eq0.err"; stop "Vergleich alter Stand nicht lesbar"; }
( cd "$W" && PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/eqcheck.py" "$W/st" "$DASH_DIR" ) > "$W/eq1.txt" 2>"$W/eq1.err" || { tail -3 "$W/eq1.err"; stop "Vergleich neuer Stand nicht lesbar"; }
cmp -s "$W/eq0.txt" "$W/eq1.txt" || stop "der neue Stand leitet eine andere Stick-Zuordnung ab als der alte (Konfig, Seriennummern, Ersatzwert)"
echo "OK neuer Stand mit lokaler Datei leitet dieselbe Stick-Zuordnung ab wie der alte (sdr_config.json, Ersatzwert Stick 1; Vergleich nur ueber Pruefsummen)"
if [[ -f "$LOCALF" ]]; then cmp -s "$LOCALF" "$W/lf.json" || python3 - "$LOCALF" "$W/lf.json" << 'PY' || stop "$LOCALF gibt es schon mit anderem Inhalt - bitte pruefen (Wert wird nicht ausgegeben)"
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])).get("stick1") == json.load(open(sys.argv[2])).get("stick1") else 1)
PY
fi
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
# ---------- 3) Zustand vorher (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /lokale-energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/sdr/status /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/br24 /api/t2/status /api/t3/status /api/t4/status /api/meteor /api/usv /api/docs/list)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
read -r FP0 FPN0 FPP0 FPT0 FPI0 <<< "$(fp)"
[[ "$FP0" != "?" && "$FPN0" -gt 0 ]] || { [[ "$DRY" == 1 ]] && echo "HINWEIS sdr_status.json nicht lesbar" || stop "sdr_status.json nicht lesbar - Stick-Zuordnung vorher unbekannt"; }
# Zuordnung vorher muss ruhig sein: gleiche Pruefsumme wie zu Beginn (vor der Sandbox), sonst bis 90 s auf zwei gleiche Lesungen im Abstand von 15 s warten
if [[ "$FP0" != "$FPA" ]]; then
  echo "HINWEIS Stick-Zuordnung hat sich seit dem Start des Skripts geaendert - warte auf einen ruhigen Stand (max 90 s)"
  FPS=0
  for i in 1 2 3 4 5 6; do sleep 15; read -r FPX FPNX FPPX FPTX FPIX <<< "$(fp)"; if [[ "$FPX" == "$FP0" ]]; then FPS=1; break; fi; FP0=$FPX; FPN0=$FPNX; FPP0=$FPPX; FPI0=$FPIX; done
  [[ "$FPS" == 1 ]] || { [[ "$DRY" == 1 ]] && echo "HINWEIS Stick-Zuordnung schwankt gerade" || stop "Stick-Zuordnung schwankt gerade (prepper-sdr startet oder ein Stick wurde umgesteckt) - bitte in ein paar Minuten erneut starten"; }
fi
echo "Stick-Zuordnung vorher: $FPN0 Seriennummer-Felder belegt, $FPP0 Geraete als vorhanden gemeldet (Pruefsumme $FP0, Werte nicht ausgegeben)"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a)" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A ACT0
for u in $SVCS; do ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f b; for f in "$DASH_DIR"/*.py; do b=$(basename "$f"); [[ " ${FILES[*]} " == *" $b "* ]] || echo "$b $(s16 "$f")"; done; }
others > "$W/others0.txt"
# ---- Neustart-Sperre HH:55-HH:04 (Berlin), geprueft jetzt und fuer die naechsten 300 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C59_FAKE_HM:-}" && "$SIM" == 1 ]]; then hm="$C59_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 300)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04, Vorlauf 5 min) - frei ab HH:05"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - Sperre HH:55-HH:04 (mit 5 min Vorlauf: Start ab HH:50 gesperrt) - prepper-sdr und prepper-dashboard werden jetzt nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04, auch in 5 min ($1)"; fi; }
rscheck "Vorpruefung"
if [[ "$DRY" == 1 ]]; then
  FINISHED=1
  echo "TROCKENLAUF fertig - nichts installiert, kein Neustart, keine lokale Datei angelegt."
  echo "  Ein echter Lauf wuerde: 5 Dateien ersetzen (Sicherungen DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST), sdr_serials.local.json (600) anlegen, prepper-sdr und prepper-dashboard neu starten, Stick-Zuordnung, Selbsttest, ${#PAGES[@]} Seiten und ${#APIS[@]} APIs pruefen; eine sudo-Passwortabfrage. Beim Einspielen wird nichts gesendet."
  echo "COMMIT $COMMIT_ARG snfrei=dry fertig"
  exit 0
fi
sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer die Neustarts und das Lesen des Journals erforderlich"
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
# ---------- 4) Installieren + Neustart ----------
trap '' INT
waitd() { local i; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done; return 1; }
waits() { local i st0="$1"; for i in $(seq 1 60); do sleep 2; if systemctl is-active --quiet prepper-sdr; then [[ -f "$DASH_DIR/sdr_status.json" && "$(stat -c %Y "$DASH_DIR/sdr_status.json")" -gt "$st0" ]] && return 0; fi; done; return 1; }
RB_DONE=0
rb() {
  set +e +o pipefail
  trap - ERR
  RB_DONE=1
  echo "ROLLBACK: $1"
  jc -u prepper-sdr --since "@${T0D:-0}" --no-pager -n 300 -o cat | grep -E "Traceback|Error|snFrei" | tail -4 | python3 -c 'import re,sys; [print("  | " + re.sub(r"[0-9A-Fa-f]{8,}", "<..>", l.rstrip())[:200]) for l in sys.stdin]'
  local x
  [[ "$RESTARTED" == 1 ]] && sudo systemctl stop prepper-sdr.service 9>&-
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  if [[ "$LOCAL_NEW" == 1 ]]; then rm -f "$LOCALF" && echo "  sdr_serials.local.json wieder entfernt (alter Stand braucht sie nicht)"; fi
  if [[ "$RESTARTED" == 1 ]]; then
    sudo systemctl start prepper-sdr.service 9>&-
    sudo systemctl restart prepper-dashboard.service 9>&-
    waitd
  fi
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
  echo "  Datenbank und sdr_config.json wurden nicht veraendert; beim Einspielen wurde nichts gesendet"
}
rbx() { rb "$1"; exit 1; }
rscheck "unmittelbar vor dem Ersetzen"
PHASE=installiert
T0D=$(date +%s)
for f in "${FILES[@]}"; do
  x="$DASH_DIR/$f"
  cp -a "$x" "$x.bak-$NM-$TS"
  { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
done
echo "OK Sicherungen *.bak-$NM-$TS fuer die 5 Dateien (behalten: letzte $KEEP_LAST; sie enthalten die alten Werte und bleiben lokal)"
if [[ ! -f "$LOCALF" ]]; then
  cp "$W/lf.json" "$LOCALF.new" && chmod 600 "$LOCALF.new" && mv -f "$LOCALF.new" "$LOCALF" || rbx "lokale Datei anlegen"
  LOCAL_NEW=1
  echo "OK sdr_serials.local.json angelegt (Rechte $(stat -c %a "$LOCALF"), Eigentuemer $(stat -c %U "$LOCALF"), Wert nicht ausgegeben)"
else
  chmod 600 "$LOCALF"; echo "OK sdr_serials.local.json war schon da mit gleichem Wert (Rechte 600)"
fi
for f in database.py sdr_manager.py prepper_docs.py prepper_sdr.py dashboard.py; do
  x="$DASH_DIR/$f"
  INST+=("$x")
  cp "$W/neu/$f" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rbx "$f installieren"; }
  [[ "$(s16 "$x")" == "${NEU[$f]}" ]] || rbx "$f nach dem Kopieren falsch ($(s16 "$x"))"
done
echo "OK 5 Dateien atomar ersetzt"
RESTARTED=1
ST0=$(stat -c %Y "$DASH_DIR/sdr_status.json" 2>/dev/null || echo 0); [[ "$ST0" -lt "$T0D" ]] || ST0=$T0D
echo "Neustart prepper-sdr - warte bis aktiv und Status neu geschrieben (max 120 s) ..."
sudo systemctl restart prepper-sdr.service 9>&-
waits "$ST0" || rbx "prepper-sdr nach dem Neustart nicht aktiv oder schreibt keinen Status (120 s)"
echo "OK prepper-sdr aktiv, Status neu ($(TZ=Europe/Berlin date -d "@$(stat -c %Y "$DASH_DIR/sdr_status.json")" +%H:%M:%S))"
echo "Neustart prepper-dashboard - warte auf HTTP 200 (max 240 s) ..."
sudo systemctl restart prepper-dashboard.service 9>&-
waitd || rbx "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"
echo "OK prepper-dashboard aktiv, HTTP 200"
# ---------- 5) Pruefung ----------
# jedes Geraet, das vorher mit Seriennummer gemeldet war, muss nachher mit derselben Seriennummer und demselben Vorhanden-Zustand gemeldet sein;
# zusaetzlich gemeldete Eintraege (z. B. Stick 3, der vorher noch nicht im Status stand) sind erlaubt und werden genannt
fpcmp() { python3 - "$1" "$2" << 'PY'
import sys
a = dict(x.split(":") for x in sys.argv[1].split(",") if ":" in x)
b = dict(x.split(":") for x in sys.argv[2].split(",") if ":" in x)
bad = [k for k in a if k in b and b[k] != a[k]]
gone = [k for k in a if k not in b]
add = [k for k in b if k not in a]
if bad or [k for k in gone if k != "s4"]:
    print("ABW " + " ".join(bad + gone))
elif gone:
    print("S4 " + (" ".join(add) if add else "-"))
else:
    print("OK " + (" ".join(add) if add else "-"))
PY
}
FPOK=0; FPR=""
# bis 180 s auf den vollen Stand warten; fehlt danach nur die Live-Zeile von Stick 3 (s4, eigener Planer-Faden startet spaeter), bis 300 s weiter warten
for i in $(seq 1 100); do
  read -r FP1 FPN1 FPP1 FPT1 FPI1 <<< "$(fp)"
  if [[ "$FPT1" -gt "$T0D" ]]; then FPR=$(fpcmp "$FPI0" "$FPI1"); [[ "$FPR" == OK* ]] && { FPOK=1; break; }; fi
  [[ "$i" -ge 60 && "$FPR" != S4* ]] && break
  sleep 3
done
if [[ "$FPOK" == 0 && "$FPR" == S4* ]]; then
  FPOK=1; FPR="OK ${FPR#S4 }"
  echo "HINWEIS Stick 3: Live-Zeile (s4) nach 300 s noch nicht im Status - Zuordnung aus dem Register (dual) ist gleich; bitte spaeter auf /funk pruefen, ob Stick 3 · Hobby wieder laeuft"
fi
[[ "$FPOK" == 1 ]] || rbx "Stick-Zuordnung nach dem Neustart anders als vorher (vorher $FPN0 Felder/$FPP0 vorhanden, jetzt ${FPN1:-?}/${FPP1:-?}; abweichend: ${FPR#ABW }; 180 s gewartet)"
echo "OK Stick-Zuordnung wie vorher: gleiche Geraete mit gleicher Seriennummer erkannt ($FPN0 Felder vorher, keine Abweichung; jetzt $FPN1 Felder, $FPP1 vorhanden; Werte nicht ausgegeben)"
[[ "${FPR#OK }" == "-" ]] || echo "HINWEIS nach dem Neustart zusaetzlich gemeldet (vorher noch nicht im Status): ${FPR#OK }"
for u in prepper-sdr prepper-dashboard; do systemctl is-active --quiet "$u" || rbx "$u laeuft nicht"; done
( cd "$W" && PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/eqcheck.py" "$DASH_DIR" "$DASH_DIR" ) > "$W/eq2.txt" 2>"$W/eq2.err" || rbx "Vergleich installierter Stand nicht lesbar"
cmp -s "$W/eq0.txt" "$W/eq2.txt" || rbx "installierter Stand leitet eine andere Stick-Zuordnung ab als der alte"
echo "OK installierter Stand (mit sdr_serials.local.json) leitet dieselbe Zuordnung ab wie vorher"
for f in "$DASH_DIR"/*.py; do cp "$f" "$W/st2/"; done
stt "$W/st2" "$W/st2l" || { tail -n 4 "$W"/st2l.* | python3 -c 'import re,sys; [print("  | " + re.sub(r"[0-9A-Fa-f]{8,}", "<..>", l.rstrip())[:200]) for l in sys.stdin]'; rbx "Selbsttest des installierten Stands fehlgeschlagen"; }
echo "OK prepper_sdr.py selftest (installierter Stand$(cmp -s "$W/st2/prepper_sdr.py" "$DASH_DIR/prepper_sdr.py" && echo ", byte-gleich")): $(tail -n 1 "$W/st2l.sdr" | cut -c1-60)...; sdr_manager.py und database.py selftest ok"
python3 "$W/snmap.py" scan "$DASH_DIR" "$W/sn.json" > "$W/s2.log" 2>&1 || rbx "in den installierten Dateien steht noch eine Seriennummer"
echo "OK installierte 5 Dateien ohne Seriennummer (gegen die echten Werte geprueft)"
for p in "${PAGES[@]}" "${APIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rbx "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK ${#PAGES[@]} Seiten und ${#APIS[@]} APIs antworten wie vorher (alle $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
JS=$(jc -u prepper-sdr --since "@$T0D" --no-pager -n 3000 -o cat || true)
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -n 20000 -o cat || true)
if [[ -z "$JS$JD" ]]; then echo "HINWEIS Journal nicht lesbar - Journal-Pruefung uebersprungen"
else
  E1=$(echo "$JS" | grep -c "Traceback" || true); E2=$(echo "$JD" | grep -c "Traceback" || true)
  [[ "${E1:-0}" == 0 ]] || rbx "$E1 Traceback(s) im Journal prepper-sdr seit dem Neustart"
  [[ "${E2:-0}" == 0 ]] || rbx "$E2 Traceback(s) im Journal prepper-dashboard seit dem Neustart"
  echo "OK Journal prepper-sdr und prepper-dashboard seit dem Neustart ohne Traceback"
  if [[ -n "$JD" ]]; then
    MISS=""
    for n in sdrAir sdrAir2 sdrStick3 sdrStick3e sdrRest; do echo "$JD" | grep -qE "^$n aktiv: $n Anzeige ok" || MISS+="$n "; done
    [[ -z "$MISS" ]] || rbx "Dashboard-Selbsttests mit Stick-Daten nicht ok seit dem Neustart: $MISS"
    echo "OK Dashboard-Selbsttests mit Stick-Daten beim Start ok (sdrAir, sdrAir2, sdrStick3, sdrStick3e, sdrRest)"
  fi
fi
others > "$W/others1.txt"; cmp -s "$W/others0.txt" "$W/others1.txt" || rbx "andere Programmdateien haben sich veraendert"
for u in $SVCS; do a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$u" == mesh-bridge* && "$a" != "${ACT0[$u]}" ]] && rbx "$u: $a (vorher ${ACT0[$u]})"; done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- neu gestartet: prepper-sdr und prepper-dashboard; Mesh-Bruecken unveraendert"
PHASE=fertig
FINISHED=1
echo "Rueckweg von Hand (nur bei Bedarf):"
echo "  sudo systemctl stop prepper-sdr && cd $DASH_DIR && for f in ${FILES[*]}; do cp -a \$f.bak-$NM-$TS \$f; done && rm -f sdr_serials.local.json && sudo systemctl start prepper-sdr && sudo systemctl restart prepper-dashboard"
echo "COMMIT $COMMIT_ARG snfrei=1 fertig prepper_sdr=${NEU[prepper_sdr.py]} sdr_manager=${NEU[sdr_manager.py]} dashboard=${NEU[dashboard.py]} database=${NEU[database.py]} prepper_docs=${NEU[prepper_docs.py]} dauer=$(( $(date +%s) - T0D ))s"
