#!/bin/bash
set -euo pipefail
# tiiFix (nach Teil 4): MASTS_DB 11D auf die echten TII-Kennungen von BR Bayern (fmlist Ensemble 10A5):
# 08/18 Bamberg (Geisberg) und 05/14 Nuernberg-Schweinau (beide live empfangen 17.10.2026), 05/01 Hersbruck und 05/13 Dillberg (fmlist).
# Die alten Werte 07/01, 02, 05 (Vorgabe Teil 2) entfallen. Nur prepper_sdr.py (5 Stellen im sdrTeil2-Block), Neustart nur prepper-sdr.
# Nur Anzeige/Zuordnung der TII-Ereignisse - Empfang, Sticks, Alarme und Mesh bleiben unveraendert. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
M="$DASH_DIR/prepper_sdr.py"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/tiifix-apply
KEEP_LAST=3
KNOWN_SDR16="f9873b86788f745a"   # prepper_sdr.py live nach Teil 4
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== tiiFix apply (MASTS_DB 11D), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_PT="65fe7058efe1516c9097fe8e1c7c4a9971cde1e28bf80da95d882d69f125c0a9"
cat > "$W/patch-tiifix-sdr.py" << 'TFP_EOF'
"""tiiFix: MASTS_DB 11D auf die tatsaechlich empfangenen/fmlist-TII umstellen (08/18, 05/14 live 17.10.2026; 05/01, 05/13 fmlist), alte 07/01, 02, 05 weg.
Genau 5 Stellen im sdrTeil2-Block (Eintrag 11D, t2_mast, Rollen-Meldung, 2 Selbsttest-Zeilen), sonst nichts. Idempotent.
Aufruf: patch-tiifix-sdr.py QUELLE ZIEL -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst = sys.argv[1:3]
s = open(src, encoding="utf-8").read()
OLD_11D = '''    "11D": {"f_mhz": 222.064, "name": "BR Bayern", "main_id": 7, "sub_ids": [1, 2, 5], "rx": "Stick 1 fest",
            "src": "Frequenz: ETSI EN 300 401 Kanalraster Band III (11D = 222,064 MHz); TII MainID 07 / SubID 01, 02, 05: Vorgabe Frank (Teil 2)"},
'''
NEW_11D = '''    "11D": {"f_mhz": 222.064, "name": "BR Bayern", "main_id": None, "sub_ids": [], "rx": "Stick 1 fest",   # tiiFix: TII-Paare je Mast statt 07/01, 02, 05
            "tii": [{"main": 8, "sub": 18, "mast": "Bamberg (Geisberg)", "lat": 49.866, "lon": 10.844, "src": "live empfangen 17.10.2026 (TII-Ereignis 11D); Mast laut fmlist Ensemble 10A5"},
                    {"main": 5, "sub": 14, "mast": "Nürnberg (Fernmeldeturm Schweinau)", "lat": 49.4283, "lon": 11.0403, "src": "live empfangen 17.10.2026 (TII-Ereignis 11D); Mast laut fmlist Ensemble 10A5"},
                    {"main": 5, "sub": 1, "mast": "Hersbruck", "lat": 49.5181, "lon": 11.46, "src": "fmlist Ensemble 10A5 (Abruf 17.10.2026), bisher nicht empfangen"},
                    {"main": 5, "sub": 13, "mast": "Dillberg", "lat": 49.3239, "lon": 11.3831, "src": "fmlist Ensemble 10A5 (Abruf 17.10.2026), bisher nicht empfangen"}],
            "src": "Frequenz: ETSI EN 300 401 Kanalraster Band III (11D = 222,064 MHz); TII: fmlist.org Ensemble 10A5 (BR Bayern), 08/18 + 05/14 live empfangen 17.10.2026; "
                   "Koordinaten ungefaehr (etwa 1 km, Wikipedia/helmuthzeitler.com/Teil-1-Liste, nicht von fmlist) - nur Anzeige"},
'''
OLD_MAST = '''def t2_mast(ch, main, sub):
    m = MASTS_DB.get(str(ch)) or {}
    if m.get("main_id") == main'''
NEW_MAST = '''def t2_mast(ch, main, sub):
    m = MASTS_DB.get(str(ch)) or {}
    for t in m.get("tii") or []:   # tiiFix: TII-Paar -> Mastname
        if t.get("main") == main and t.get("sub") == sub:
            return "%s MainID %02d / SubID %02d (%s)" % (t.get("mast") or m.get("name"), main, sub, m.get("name"))
    if m.get("main_id") == main'''
OLD_T1 = '''and MASTS_DB["11D"]["main_id"] == 7 and MASTS_DB["11D"]["sub_ids"] == [1, 2, 5]\n'''
NEW_T1 = '''and [(t["main"], t["sub"]) for t in MASTS_DB["11D"]["tii"]] == [(8, 18), (5, 14), (5, 1), (5, 13)]   # tiiFix\n'''
OLD_T2 = '''    assert x["tii"][0]["mast"] == "BR Bayern MainID 07 / SubID 02" and "nicht in MASTS_DB" in x["tii"][1]["mast"], x["tii"]\n'''
NEW_T2 = '''    assert x["tii"][0]["mast"] == "MainID 07 / SubID 02 (nicht in MASTS_DB)" and "nicht in MASTS_DB" in x["tii"][1]["mast"], x["tii"]   # tiiFix: 07/xx nicht mehr in MASTS_DB
    assert t2_mast("11D", 8, 18) == "Bamberg (Geisberg) MainID 08 / SubID 18 (BR Bayern)" and t2_mast("11D", 5, 14).startswith("Nürnberg (Fernmeldeturm Schweinau) MainID 05 / SubID 14")   # tiiFix
'''
OLD_RL = """        if {x: old.get(x) for x in row} != row:
            row["since"] = int(now) if (old.get("mode") != mode) else old.get("since", int(now))
"""
NEW_RL = """        if {x: old.get(x) for x in row} != row or t2.get("masts") != MASTS_DB:   # tiiFix: neue MASTS_DB auch ohne Rollenwechsel melden
            row["since"] = int(now) if (old.get("mode") != mode) else old.get("since", int(now))
"""
EDITS = ((OLD_11D, NEW_11D), (OLD_MAST, NEW_MAST), (OLD_T1, NEW_T1), (OLD_T2, NEW_T2), (OLD_RL, NEW_RL))
bad = []
for need in ("# ===== sdrTeil2:", "# ===== /sdrTeil2 =====", "MASTS_DB = {", "def t2_fig_parse(", "def selftest_teil2():"):
    if s.count(need) != 1:
        bad.append("%s nicht genau 1x" % need)
for old, new in EDITS:
    if s.count(old) + s.count(new) != 1:
        bad.append("Stelle nicht eindeutig: %s" % old.strip().splitlines()[0][:60])
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
a, z = s.index("# ===== sdrTeil2:"), s.index("# ===== /sdrTeil2 =====")
s2 = s
for old, new in EDITS:
    if old in s2:
        i = s2.index(old)
        if not a < i < z:
            print("Basis passt nicht: Stelle ausserhalb sdrTeil2"); raise SystemExit(3)
        s2 = s2.replace(old, new)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
TFP_EOF
EXPECT_GUARD="27e1e5fb7c9f035695b18e14e2076dbe8b901916bbd95f2adae8465ed2423202"
cat > "$W/guard_tiifix.py" << 'TFG_EOF'
"""tiiFix AST-Guard. Aufruf: guard_tiifix.py SDR_ALT SDR_NEU PATCH -> 0 ok, 1 Verstoss.
prepper_sdr.py: nur die 5 tiiFix-Stellen im sdrTeil2-Block (Ruecktausch ergibt Byte fuer Byte die Basis); keine neuen Importe/Aufrufe/shell."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
p0, p1 = rd(sys.argv[1]), rd(sys.argv[2])
err = []
ptf_src = rd(sys.argv[3])
g = {}
exec(compile(ptf_src.split("EDITS = (")[0].split("import sys\n", 1)[1].split("s = open(src")[1].split("\n", 1)[1], "ptf", "exec"), g)
EDITS = ((g["OLD_11D"], g["NEW_11D"]), (g["OLD_MAST"], g["NEW_MAST"]), (g["OLD_T1"], g["NEW_T1"]), (g["OLD_T2"], g["NEW_T2"]), (g["OLD_RL"], g["NEW_RL"]))
r1, r0 = p1, p0
for old, new in EDITS:
    if r1.count(new) != 1:
        err.append("tiiFix-Stelle fehlt: %s" % new.strip().splitlines()[0][:60])
    r1 = r1.replace(new, old)
    r0 = r0.replace(new, old)
if r1 != r0:
    err.append("prepper_sdr.py: anders geaendert als die 5 tiiFix-Stellen")


def sig(src):
    t = ast.parse(src)
    imp = sorted((getattr(n, "module", None) or a.name) for n in ast.walk(t) if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names)
    calls = sorted((c.func.attr if isinstance(c.func, ast.Attribute) else getattr(c.func, "id", "?")) for c in ast.walk(t) if isinstance(c, ast.Call))
    sh = sum(1 for n in ast.walk(t) if isinstance(n, ast.keyword) and n.arg == "shell")
    return imp, calls, sh


i0, c0, s0 = sig(r0)
i1, c1, s1 = sig(p1)
if i1 != i0 or s1 != s0:
    err.append("prepper_sdr.py: Importe/shell geaendert")
extra = list(c1)
for c in c0:
    if c in extra:
        extra.remove(c)
if set(extra) - {"get", "startswith", "t2_mast"}:
    err.append("prepper_sdr.py: neue Aufrufe %s" % sorted(set(extra)))
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard tiiFix: prepper_sdr.py nur MASTS_DB 11D, t2_mast, Rollen-Meldung und 2 Selbsttest-Zeilen geaendert; keine neuen Importe, Prozesse, Netz oder shell")
TFG_EOF
PT="$W/patch-tiifix-sdr.py"; SG="$W/guard_tiifix.py"
for x in "$EXPECT_PT $PT" "$EXPECT_GUARD $SG"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
[[ -f "$M" && -f "$F" ]] || { echo "STOP: prepper_sdr.py/dashboard.py fehlt - nichts geaendert"; exit 1; }
S16=$(sha256sum "$M" | cut -c1-16)
echo "Basis prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $([[ "$S16" == "$KNOWN_SDR16" ]] && echo "bekannt (Teil 4)" || echo "neu, Erkennung ueber Guards"))"
grep -q '# ===== /sdrTeil4 =====' "$M" || { echo "STOP: Teil 4 fehlt in prepper_sdr.py - bitte zuerst apply-teil4.sh, nichts geaendert"; exit 1; }
python3 "$PT" "$M" "$W/work/prepper_sdr.py" > "$W/p.log" || { cat "$W/p.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: sdrTeil2 + sdrTeil4, 5 tiiFix-Stellen eindeutig -> $(cat "$W/p.log")"
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
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY (Sandbox, kein Stick): sdrTeil2 (inkl. 08/18 -> Bamberg, 05/14 -> Schweinau, 07/xx nicht mehr) + sdrTeil4 + aeltere Bloecke"
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
sys.exit(0 if [(t.get('main'), t.get('sub')) for t in m.get('tii') or []] == [(8, 18), (5, 14), (5, 1), (5, 13)] and not m.get('sub_ids') else 1)" "$DASH_DIR/broadcast_state.json"; }
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
  echo "OK tiiFix schon installiert - kein Neustart"
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
    for x in "$M" "$DASH_DIR/broadcast_state.json"; do [[ -f "$x.bak-tiifix-$TS" ]] && cp -a "$x.bak-tiifix-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    for i in $(seq 1 60); do sleep 3; systemctl is-active --quiet prepper-sdr && break; done
    cmp -s "$M" "$M.bak-tiifix-$TS" && echo "  prepper_sdr.py = Sicherung ($(sha256sum "$M" | cut -c1-16))" || echo "  WARNUNG prepper_sdr.py ungleich Sicherung"
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "$M" "$DASH_DIR/broadcast_state.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-tiifix-$TS"
    { ls -1t "$x.bak-tiifix-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-tiifix-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
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
[[ "$ok" == 1 ]] && echo "OK broadcast_state.json: 11D TII 08/18, 05/14, 05/01, 05/13 (07/xx entfernt)" || rbx "prepper-sdr meldet die neue MASTS_DB nicht"
sleep 5
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrTeil[24] [a-z_ 0-9]+:" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrTeil-Fehler" || rbx "$E Traceback/sdrTeil-Fehlerzeilen im Journal prepper-sdr"
echo "OK guards tiiFix=$(grep -c '# tiiFix' "$M" || true) sdrTeil2=$(grep -c '# ===== sdrTeil2:' "$M" || true) sdrTeil4=$(grep -c '# ===== sdrTeil4:' "$M" || true) rdsNotfall=$(grep -c '# ===== rdsNotfall:' "$M" || true)"
[[ -f "$M.bak-tiifix-$TS" ]] && echo "Backups: *.bak-tiifix-$TS (prepper_sdr.py, broadcast_state.json), behalten: letzte $KEEP_LAST"
for x in "$M" "$F" "$DASH_DIR/sdr_manager.py"; do echo "  $(basename "$x") sha16 $(sha256sum "$x" | cut -c1-16), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG tiifix=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, tiiFix bleibt aktiv. COMMIT $COMMIT_ARG tiifix=1"; exit 0' INT
echo "MASTS_DB 11D jetzt:"
python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))['t2']['masts']['11D']
for t in m['tii']: print('  %02d/%02d %s - %s' % (t['main'], t['sub'], t['mast'], t['src']))
print('  Koordinaten ungefaehr (etwa 1 km), nicht von fmlist')" "$DASH_DIR/broadcast_state.json" || true
echo "Hinweis: Das naechste TII-Ereignis auf der Lage-Seite/dabhist zeigt dann z. B. Bamberg (Geisberg) MainID 08 / SubID 18 statt nicht in MASTS_DB."
echo "COMMIT $COMMIT_ARG tiifix=1 fertig"
