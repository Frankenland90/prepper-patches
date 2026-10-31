#!/usr/bin/env bash
# fullcheck.sh - Gesamtpruefung "Lage Pi" (BND-Prepper): Pi, Dienste, Dashboard, Patch-Stand (bis commit47), NINA-Zertifikatskette, Mesh, SDR, DB, Backups, Sicherheit, Journal
# Aufruf:  bash fullcheck.sh [--kurz] [--json] [--sudo] [--no-color] [--help] | --selftest | --version      (auch: bash ~/fullcheck.sh)
# Strikt nur lesend: aendert nichts am System, am Projekt, am Dashboard oder an der Datenbank, startet nichts neu, sendet nichts (kein Mesh, kein Telegram,
# keine Alarme, keine Mail, keine POSTs), oeffnet keine SDR-Sticks, scannt kein Netz, zeigt nie Schluessel/Passwoerter/Tokens, schreibt keine Dateien (auch keine temporaeren).
# Stufen: OK, HINWEIS (Abweichung/Beobachten), FEHLER (Handlungsbedarf), INFO, SKIP.   Exit-Code: 0 = alles OK, 1 = mindestens ein HINWEIS, 2 = mindestens ein FEHLER, 64 = falscher Aufruf.
# shellcheck disable=SC2015  # ok/warn/fail/info/skip liefern immer 0: "A && ok .. || warn .." ist hier exakt if-then-else
set -u
export LC_ALL=C.UTF-8
export TZ=Europe/Berlin
export PYTHONDONTWRITEBYTECODE=1
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin:/usr/local/bin"

FC_VERSION="2.0.2"
T0=$SECONDS

# ---------------------------------------------------------------- Konfiguration (Umgebungsvariablen FC_* nur fuer Tests/Sonderfaelle)
APP="${FC_APP:-/home/fmg/prepper-dashboard}"
BACKUPS="${FC_BACKUPS:-/home/fmg/prepper-backups}"
HOSTN="${FC_HOST:-127.0.0.1}"
PORT="${FC_PORT:-5000}"
BR1_PORT="${FC_BRIDGE1_PORT:-5001}"
BR2_PORT="${FC_BRIDGE2_PORT:-5002}"
NTP_HOST="${FC_NTP_HOST:-192.168.178.15}"
GPSD_PORT="${FC_GPSD_PORT:-2947}"
PROC="${FC_PROC:-/proc}"
SYS="${FC_SYS:-/sys}"
DROPIN_DIR="${FC_DROPIN_DIR:-/etc/systemd/system/prepper-dashboard.service.d}"
DASH_SHA16="${FC_DASH_SHA16:-74ac7bfd0eebd4e0}"   # Soll nach commit47 speedAsync (31.10.2026), 22340 Zeilen; vorher bb94f52af6e03c3b nach commit37
PYBIN="${FC_PY:-python3}"
VENV_PY="${FC_VENV_PY:-$APP/venv/bin/python}"
BUDGET_S="${FC_BUDGET_S:-50}"                      # nach so vielen Sekunden werden restliche Seitentests uebersprungen
QC_MAX_MB="${FC_QC_MAX_MB:-64}"                    # quick_check live nur bei kleinerer Datenbank (sonst Cache der DB-Wartung)
SLOT_MAX_S=$((3 * 3600 + 10 * 60))                 # Auto-Stempel Wetter: hoechstens 3 h 10 min alt

SERVICES=(prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern)
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte
       /api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events
       /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
MARKERS=(relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync)   # je genau 1x "# ===== <Name>:"
NINA_PEM_REL="certs/sectigo-e36.pem"; NINA_PEM_DER16="873f0ba8"   # DER-sha256 beginnt so (Sectigo Public Server Authentication CA DV E36)
# Referenz-sha16 weiterer Dateien laut AUDIT-STAND.md (NICHT als bestaetigt gefuehrt -> nur Anzeige): "Pfad:sha16"
REFS=(database.py:e7a7ef192c522480 lage_xml.py:f77305fc17ed2f77 mesh_bridge.py:3482f6e386cf26ce mesh_bridge_bayern.py:c1176b457346ae49
      mesh_bridge_core.py:ddc134f29a6a8949 luft.py:0ccae0834ab27f6d secret_util.py:ff8e2ac7049f4bde tools/backup.sh:5053f6b8a43a8638
      tools/restore.sh:c0e305b8ea4d9007 health_check.py:5a0156ff02d5960c prepper_docs.py:609f0a7f00ab586b lage_clock.py:c909aea1148518fe lage_disk.py:4b6b35ab7c97dfc7)
AIRSPY_VIDPID="1d50:60a1"; AIRSPY_SN="637862DC2E8092D7"; STICK1_SN="19348831"; STICK2_SN="72055505"; STICK3_SN="26102403"

# ---------------------------------------------------------------- Optionen
QUICK=0; JSON=0; SUDO=0; NOCOL=0; SELFTEST=0
[[ -n "${NO_COLOR:-}" ]] && NOCOL=1

usage() {
  cat <<'EOT'
fullcheck.sh - Gesamtpruefung der Lage Pi (strikt nur lesend: nichts wird veraendert, gesendet oder neu gestartet)

Aufruf:
  bash fullcheck.sh [Optionen]          (oder bash ~/fullcheck.sh)

Optionen:
  --kurz        ohne Seitentest der 26 Seiten/APIs und ohne langsame Pruefungen (quick_check, Archiv-Pruefsumme); Alias: --quick
  --json        Ausgabe maschinenlesbar (ein JSON-Dokument, ohne Secrets); Exit-Code wie sonst.
                Stufen-Schluessel im JSON: ok, warn (= HINWEIS), fail (= FEHLER), info, skip
  --sudo        zusaetzlich lesende Pruefungen mit sudo (nur journalctl und dmesg); fragt einmal nach dem Passwort
  --no-color    keine Farben (auch NO_COLOR=1 wird beachtet; ohne Terminal gibt es nie Farben)
  --selftest    interner Selbsttest der Hilfsfunktionen (ohne Zugriff auf das System)
  --version     Version anzeigen
  --help        diese Hilfe

Stufen: OK, HINWEIS (Abweichung, Beobachten), FEHLER (Handlungsbedarf), INFO (nur Anzeige), SKIP (nicht pruefbar, z. B. braucht sudo).
Der NINA-Zertifikatsketten-Rueckfall (ninaFix, gepinnte Zwischenstelle Sectigo E36) zaehlt als OK bzw. HINWEIS, nie als FEHLER; FEHLER nur, wenn die Kette auch mit dem Rueckfall nicht pruefbar ist.
Punkte: 100 minus 2 je HINWEIS minus 10 je FEHLER (mindestens 0). Exit-Code: 0 = OK, 1 = HINWEIS, 2 = FEHLER, 64 = falscher Aufruf.
Das Skript schreibt keine Dateien, startet nichts neu, sendet nichts und gibt keine Schluessel aus (Ausgaben werden maskiert).
EOT
}

while (( $# > 0 )); do
  case "$1" in
    --kurz|--quick) QUICK=1 ;;
    --json) JSON=1 ;;
    --sudo) SUDO=1 ;;
    --no-color) NOCOL=1 ;;
    --selftest) SELFTEST=1 ;;
    --version) echo "fullcheck.sh $FC_VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "fullcheck.sh: unbekannte Option: ${1:0:40}" >&2; echo "Hilfe: bash fullcheck.sh --help" >&2; exit 64 ;;
  esac
  shift
done

# ---------------------------------------------------------------- Ausgabe-Grundlagen
if [[ -t 1 && "$NOCOL" == 0 && "$JSON" == 0 && "${TERM:-dumb}" != "dumb" ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[1;31m'; C_INFO=$'\033[36m'; C_SKIP=$'\033[90m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_SKIP=""; C_B=""; C_0=""
fi

N_OK=0; N_WARN=0; N_FAIL=0; N_INFO=0; N_SKIP=0
declare -a R_SEC=() R_ST=() R_NAME=() R_DET=() R_HINT=()
CUR_SEC=""
declare -a SECRET_VALS=()

# Werte geheimer Umgebungsvariablen (nur im Speicher) - werden aus JEDER Ausgabe entfernt, falls sie je in einem Text auftauchen sollten
collect_secret_values() {
  local line name val
  while IFS= read -r line; do
    name="${line%%=*}"; val="${line#*=}"
    [[ "$name" =~ (KEY|TOKEN|SECRET|PASS|PWD|CREDENTIAL|AUTH) ]] || continue
    (( ${#val} >= 6 )) || continue
    SECRET_VALS+=("$val")
  done < <(env 2>/dev/null)
}

# einzeilig, ohne Steuerzeichen, Secrets (Umgebungswerte) entfernt, begrenzt
clean() {
  local v="$1" s
  v="${v//[^[:print:]]/ }"
  for s in "${SECRET_VALS[@]}"; do v="${v//"$s"/***}"; done
  [[ "$v" =~ [Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss]|[Pp][Ww][Dd]|[Aa][Uu][Tt][Hh]|[Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc]|[Ss][Ii][Gg] ]] && v="$(mask_keys "$v")"   # Sicherheitsnetz fuer jede Ausgabe
  (( ${#v} > 400 )) && v="${v:0:397}..."
  printf '%s' "$v"
}

# Freitext aus Logs/Diensten: bekannte Schluesselformen maskieren (Parameter, Header, lange Kennungen)
# Stufe 1 (sed): "Authorization: Bearer ...", key=..., token: ..., Bearer/Basic ..., /lange-Kennung in Pfaden, 32+ Zeichen Schluesselalphabet
# Stufe 2 (bash): jedes Wort ab 20 Zeichen aus Buchstaben UND Ziffern (Schluesselalphabet) wird ganz maskiert - auch ohne Schluesselwort davor
mask_keys() {
  printf '%s' "$1" | sed -E \
    -e 's/(authorization[=:] *)(Bearer|Basic) +[^&[:space:]"'"'"'<>,;]+/\1***/Ig' \
    -e 's/((api[_-]?key|apikey|key|token|secret|passwd|password|pwd|auth|authorization|bearer|signature|sig|access[_-]?token)[=:] *)[^&[:space:]"'"'"'<>,;]+/\1***/Ig' \
    -e 's/(Bearer|Basic) +[A-Za-z0-9._~+\/=-]+/\1 ***/Ig' \
    -e 's#/[A-Za-z0-9_-]{24,}#/***#g' \
    -e 's/[A-Za-z0-9+\/_=-]{32,}/***/g' 2>/dev/null
}
mask() {
  local t w out="" sp=""
  t="$(mask_keys "$1")"
  t="${t//$'\n'/ }"; t="${t//$'\t'/ }"
  local -a words=()
  read -r -a words < <(printf '%s' "$t")
  for w in "${words[@]}"; do
    if (( ${#w} >= 20 )) && [[ "$w" =~ [0-9] && "$w" =~ [A-Za-z] && "$w" != *"***"* ]]; then w="***"; fi
    out+="$sp$w"; sp=" "
  done
  printf '%s' "$out"
}

section() {
  CUR_SEC="$1"
  (( JSON )) || printf '\n%s== %s ==%s\n' "$C_B" "$1" "$C_0"
}

_emit() { # status name detail [hint]
  local st="$1" name="$2" det hint col lab
  det="$(clean "${3:-}")"; hint="$(clean "${4:-}")"
  R_SEC+=("$CUR_SEC"); R_ST+=("$st"); R_NAME+=("$name"); R_DET+=("$det"); R_HINT+=("$hint")
  case "$st" in
    ok) N_OK=$((N_OK + 1)); col="$C_OK"; lab="OK     " ;;
    warn) N_WARN=$((N_WARN + 1)); col="$C_WARN"; lab="HINWEIS" ;;
    fail) N_FAIL=$((N_FAIL + 1)); col="$C_FAIL"; lab="FEHLER " ;;
    skip) N_SKIP=$((N_SKIP + 1)); col="$C_SKIP"; lab="SKIP   " ;;
    *) N_INFO=$((N_INFO + 1)); col="$C_INFO"; lab="INFO   " ;;
  esac
  if (( ! JSON )); then
    printf '[%s%s%s] %-30s %s\n' "$col" "$lab" "$C_0" "$name" "$det"
    [[ -n "$hint" ]] && printf '         -> %s\n' "$hint"
  fi
  return 0
}
ok() { _emit ok "$@"; }
warn() { _emit warn "$@"; }
fail() { _emit fail "$@"; }
info() { _emit info "$1" "${2:-}" ""; }
skip() { _emit skip "$1" "${2:-}" ""; }

have() { command -v "$1" >/dev/null 2>&1; }
# grosse Texte nie per Here-String weitergeben (bash legt dafuer ab 64 KB eine temporaere Datei an): immer per Pipe
pf() { printf '%s\n' "$1"; }

# Gleitkomma-Vergleich: fcmp 1.5 '>' 1.2
fcmp() { awk -v a="$1" -v b="$3" "BEGIN{exit !(a $2 b)}" 2>/dev/null; }

# curl time_total ("0.191088") -> ganze Millisekunden
ms_of() {
  local t="$1" s f
  [[ "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo 0; return; }
  s="${t%%.*}"; f="0"; [[ "$t" == *.* ]] && f="${t#*.}"
  f="${f}000"
  echo $((10#$s * 1000 + 10#${f:0:3}))
}

# Sekunden -> "3 T 4 h" / "12 min" / "45 s"
dur() {
  local s="$1"
  [[ "$s" =~ ^-?[0-9]+$ ]] || { printf '?'; return; }
  (( s < 0 )) && s=0
  if (( s >= 172800 )); then printf '%d T %d h' $((s / 86400)) $(((s % 86400) / 3600))
  elif (( s >= 3600 )); then printf '%d h %d min' $((s / 3600)) $(((s % 3600) / 60))
  elif (( s >= 120 )); then printf '%d min' $((s / 60))
  else printf '%d s' "$s"; fi
}

# systemd-Dauer ("5min", "300s", "5min 30s", "300000000") -> Sekunden (ganzzahlig) oder leer
sd_seconds() {
  local v="$1" tot=0 num unit rest found=0
  [[ "$v" == infinity || "$v" == 0 || -z "$v" ]] && { echo 0; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then echo $((v >= 1000000 ? v / 1000000 : v)); return; fi
  rest="$v"
  while [[ "$rest" =~ ^[[:space:]]*([0-9]+)(us|ms|s|min|h|d|w)(.*)$ ]]; do
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"; found=1
    case "$unit" in
      us|ms) ;;
      s) tot=$((tot + num)) ;;
      min) tot=$((tot + num * 60)) ;;
      h) tot=$((tot + num * 3600)) ;;
      d) tot=$((tot + num * 86400)) ;;
      w) tot=$((tot + num * 604800)) ;;
    esac
  done
  (( found )) && echo "$tot" || echo ""
}

# Bytes -> MB mit einer Nachkommastelle
mbf() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

# Dateialter in Sekunden (leer, wenn nicht lesbar)
file_age() { local m; m="$(stat -c %Y -- "$1" 2>/dev/null)" || return 1; [[ "$m" =~ ^[0-9]+$ ]] || return 1; echo $((EPOCHSECONDS - m)); }
file_mode() { stat -c %a -- "$1" 2>/dev/null; }
sha16_of() { local h; h="$(sha256sum -- "$1" 2>/dev/null)" || return 1; echo "${h:0:16}"; }

# JSON-Dokument von stdin -> flache Tabelle J[pfad]=wert (Python3, nur lesend). Modus: flat | html <id>
declare -A J=()
read -r -d '' PYFLAT <<'PYEOF' || true
import sys, json, re
mode = sys.argv[1] if len(sys.argv) > 1 else "flat"
raw = sys.stdin.read()
if mode == "html":
    m = re.search(r'id="%s"[^>]*>(.*?)</script>' % re.escape(sys.argv[2]), raw, re.S)
    if not m:
        sys.exit(4)
    raw = m.group(1)
try:
    d = json.loads(raw)
except Exception:
    sys.exit(3)
out = []
def val(v):
    if v is None: return "null"
    if v is True: return "true"
    if v is False: return "false"
    return str(v).replace("\r", " ").replace("\n", " ").replace("\t", " ")[:200]
def walk(p, v, depth):
    if len(out) >= 700 or depth > 7:
        return
    if isinstance(v, dict):
        out.append("%s#=%d" % (p + "." if p else "", len(v)))
        out.append("%s@=%s" % (p + "." if p else "", " ".join(str(k).replace("=", "_").replace(" ", "_") for k in list(v)[:60])))
        for k, x in v.items():
            walk((p + "." if p else "") + str(k).replace("=", "_").replace(" ", "_"), x, depth + 1)
    elif isinstance(v, list):
        out.append("%s.#=%d" % (p, len(v)))
        for i, x in enumerate(v[:30]):
            walk("%s.%d" % (p, i), x, depth + 1)
    else:
        out.append("%s=%s" % (p, val(v)))
try:
    walk("", d, 0)
except Exception:
    sys.exit(5)
sys.stdout.write("\n".join(out) + "\n")
PYEOF

jload() {
  J=()
  local outp rc line
  have "$PYBIN" || return 2
  outp="$(timeout 10 "$PYBIN" -c "$PYFLAT" "$@" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || return "$rc"
  while IFS= read -r line; do
    [[ "$line" == *=* ]] && J["${line%%=*}"]="${line#*=}"
  done <<<"$outp"
  return 0
}
# JSON aus einer Zeichenkette (nur kleine Antworten; Here-Strings ab 64 KB wuerden eine temporaere Datei anlegen)
jloads() {
  J=()
  (( ${#1} <= 60000 )) || return 6
  jload flat <<<"$1"
}
jv() { printf '%s' "${J[$1]:-}"; }   # Wert oder leer

# HTTP GET (nur GET, nur lokal): setzt HTTP_CODE, HTTP_TIME (s), HTTP_MS, HTTP_BODY, HTTP_RC
http_get() {
  local url="$1" to="${2:-8}" out tail
  HTTP_BODY=""; HTTP_CODE="000"; HTTP_TIME="0"; HTTP_MS=0; HTTP_RC=0
  have curl || { HTTP_RC=127; return 1; }
  out="$(timeout $((to + 3)) curl -s -m "$to" --connect-timeout 3 -w $'\n%{http_code} %{time_total}' -- "$url" 2>/dev/null)"; HTTP_RC=$?
  tail="${out##*$'\n'}"; HTTP_BODY="${out%$'\n'*}"
  [[ "$out" == *$'\n'* ]] || HTTP_BODY=""
  if [[ "$tail" =~ ^([0-9]{3})\ ([0-9.]+)$ ]]; then HTTP_CODE="${BASH_REMATCH[1]}"; HTTP_TIME="${BASH_REMATCH[2]}"; fi
  HTTP_MS="$(ms_of "$HTTP_TIME")"
  return 0
}

# sudo nur fuer lesende Befehle (journalctl, dmesg)
SUDO_OK=0
priv() {
  case "$1" in journalctl|dmesg) ;; *) echo "intern: priv erlaubt nur journalctl/dmesg" >&2; return 99 ;; esac
  if [[ "$(id -u)" == "0" ]]; then timeout 25 "$@"
  elif (( SUDO_OK )); then timeout 25 sudo -n -- "$@"
  else return 98; fi
}
can_journal() {
  local g; g=" $(id -nG 2>/dev/null) "
  [[ "$(id -u)" == "0" || "$g" == *" adm "* || "$g" == *" systemd-journal "* ]]
}

# ================================================================ Selbsttest (nur Hilfsfunktionen, kein Systemzugriff)
selftest() {
  local n=0 bad=0
  t() { n=$((n + 1)); if [[ "$2" == "$3" ]]; then :; else bad=$((bad + 1)); echo "SELFTEST FAIL $1: erwartet '$3' erhalten '$2'"; fi; }
  t ms1 "$(ms_of 0.191088)" 191
  t ms2 "$(ms_of 12.5)" 12500
  t ms3 "$(ms_of 7)" 7000
  t ms4 "$(ms_of abc)" 0
  t dur1 "$(dur 45)" "45 s"
  t dur2 "$(dur 600)" "10 min"
  t dur3 "$(dur 7500)" "2 h 5 min"
  t dur4 "$(dur 200000)" "2 T 7 h"
  t dur5 "$(dur x)" "?"
  t sd1 "$(sd_seconds 5min)" 300
  t sd2 "$(sd_seconds 300s)" 300
  t sd3 "$(sd_seconds 300000000)" 300
  t sd4 "$(sd_seconds '1min 30s')" 90
  t sd5 "$(sd_seconds infinity)" 0
  t sd6 "$(sd_seconds 0)" 0
  t sd7 "$(sd_seconds quatsch)" ""
  local old_vals=("${SECRET_VALS[@]}")
  SECRET_VALS=("GEHEIMWERT123")
  t cl1 "$(clean $'a\tGEHEIMWERT123 b\nc')" "a *** b c"
  SECRET_VALS=("${old_vals[@]}")
  t mk1 "$(mask 'GET /x?api_key=ABCDEF123456&b=1')" "GET /x?api_key=***&b=1"
  t mk2 "$(mask 'Authorization: Bearer abc.def-ghi')" "Authorization: ***"
  t mk3 "$(mask 'url https://h/v1/abcdefghijklmnopqrstuvwxyz0123/x')" "url https://h/v1/***/x"
  t mk4 "$(mask 'token=abc')" "token=***"
  t cl2 "$(clean 'Fehler api_key=ABCDEF1234 ende')" "Fehler api_key=*** ende"
  t cl3 "$(clean 'Authorization: Bearer abc.def-ghi')" "Authorization: ***"
  t cl4 "$(clean 'normaler Text ohne Schluessel')" "normaler Text ohne Schluessel"
  t mk5 "$(mask 'ok normal text 123')" "ok normal text 123"
  t mk6 "$(mask 'fehler k=SECRET_API_RESPONSE_c0ffee ende')" "fehler *** ende"
  t mk7 "$(mask 'unit prepper-dashboard.service gestartet')" "unit prepper-dashboard.service gestartet"
  t mk8 "$(mask 'a  b'$'\t''c')" "a b c"
  t mk9 "$(mask 'abcdefghijklmnopqrstuvwxyz nur Buchstaben')" "abcdefghijklmnopqrstuvwxyz nur Buchstaben"
  t mk10 "$(mask 'x*y ? [a]')" "x*y ? [a]"
  if fcmp 1.5 '>' 1.2; then t fc1 y y; else t fc1 n y; fi
  if fcmp 1.5 '<' 1.2; then t fc2 y n; else t fc2 n n; fi
  local s0=$N_OK; N_OK=0; N_WARN=0; N_FAIL=0
  t sc1 "$((100 - 2 * 3 - 10 * 1))" 84
  N_OK=$s0
  echo "SELFTEST: $n Pruefungen, $bad fehlerhaft"
  (( bad == 0 ))
}
if (( SELFTEST )); then collect_secret_values; selftest; exit $?; fi

collect_secret_values
trap 'echo >&2; echo "Abbruch durch Signal - keine Aenderungen am System (das Skript schreibt nichts)" >&2; exit 130' INT TERM

NOW_STR="$(date '+%d.%m.%Y %H:%M:%S %Z')"
if (( ! JSON )); then
  printf '%sfullcheck %s%s - Lage Pi %s - %s - Benutzer %s%s%s\n' "$C_B" "$FC_VERSION" "$C_0" "$(hostname 2>/dev/null || echo '?')" "$NOW_STR (Europe/Berlin)" "$(id -un 2>/dev/null || echo '?')" "$( (( QUICK )) && echo ' - Modus kurz')" "$( (( SUDO )) && echo ' - mit sudo (nur lesend)')"
  echo "Strikt nur lesend: nichts wird veraendert, gesendet oder neu gestartet."
fi

if (( SUDO )); then
  if [[ "$(id -u)" == "0" ]]; then SUDO_OK=1
  elif have sudo; then
    if [[ -t 0 ]]; then
      (( JSON )) || echo "sudo wird nur fuer journalctl und dmesg (lesend) genutzt - Passwort-Abfrage:"
      # shellcheck disable=SC2024  # nur Eingabe vom Terminal fuer die Passwort-Abfrage, keine Ausgabe-Umleitung
      sudo -v 2>/dev/null </dev/tty && SUDO_OK=1
    else
      sudo -n true 2>/dev/null && SUDO_OK=1
    fi
  fi
fi

# ================================================================ 1) System
section "System"
# Uptime
if read -r up _ < "$PROC/uptime" 2>/dev/null && [[ "${up%%.*}" =~ ^[0-9]+$ ]]; then
  US="${up%%.*}"
  if (( US < 600 )); then warn "Uptime" "erst $(dur "$US") seit dem Boot (kein RTC: Uhr erst nach chrony-Sync verlaesslich)" "Nach einem Neustart 10 Minuten warten, dann erneut pruefen."
  else ok "Uptime" "$(dur "$US") seit dem Boot"; fi
else skip "Uptime" "nicht lesbar ($PROC/uptime)"; fi

# Load
NCPU="$(nproc 2>/dev/null || echo 0)"; [[ "$NCPU" =~ ^[0-9]+$ && "$NCPU" -ge 1 ]] || NCPU=1
if read -r l1 l5 l15 _ < "$PROC/loadavg" 2>/dev/null && [[ "$l1" =~ ^[0-9.]+$ ]]; then
  if fcmp "$l5" '>' "$((NCPU * 3))"; then fail "Load" "1/5/15 min: $l1 $l5 $l15 bei $NCPU Kernen (5-min-Wert ueber ${NCPU}x3)" "Mit top pruefen, welcher Prozess die CPU blockiert (SDR, Dashboard, Backup)."
  elif fcmp "$l5" '>' "$(awk -v n="$NCPU" 'BEGIN{printf "%.1f", n*1.5}')"; then warn "Load" "1/5/15 min: $l1 $l5 $l15 bei $NCPU Kernen (5-min-Wert ueber 1,5 pro Kern)" "Mit top beobachten; kurzzeitig bei SDR-Last normal."
  else ok "Load" "1/5/15 min: $l1 $l5 $l15 bei $NCPU Kernen"; fi
else skip "Load" "nicht lesbar ($PROC/loadavg)"; fi

# CPU-Temperatur
TZ0="$SYS/class/thermal/thermal_zone0/temp"
if [[ -r "$TZ0" ]] && read -r tm < "$TZ0" && [[ "$tm" =~ ^-?[0-9]+$ ]]; then
  TC="$(awk -v t="$tm" 'BEGIN{printf "%.1f", t/1000}')"
  if (( tm >= 80000 )); then fail "CPU-Temperatur" "${TC} Grad C (ab 80 Grad drosselt der Pi)" "Luftzug/Kuehlkoerper pruefen, Gehaeuse nicht abdecken."
  elif (( tm >= 70000 )); then warn "CPU-Temperatur" "${TC} Grad C (ab 80 Grad drosselt der Pi)" "Belueftung pruefen."
  else ok "CPU-Temperatur" "${TC} Grad C"; fi
else skip "CPU-Temperatur" "$TZ0 nicht lesbar"; fi

# Drosselung / Unterspannung
THR=""
if have vcgencmd; then
  o="$(timeout 5 vcgencmd get_throttled 2>/dev/null)"; [[ "$o" =~ throttled=(0x[0-9a-fA-F]+) ]] && THR="${BASH_REMATCH[1]}"
fi
if [[ -z "$THR" ]]; then
  f="$SYS/devices/platform/soc/soc:firmware/get_throttled"
  if [[ -r "$f" ]] && read -r v < "$f" 2>/dev/null && [[ "$v" =~ ^[0-9a-fA-Fx]+$ ]]; then [[ "$v" == 0x* ]] || v="0x$v"; THR="$v"; fi
fi
if [[ -n "$THR" ]]; then
  TV=$((THR))
  NOWB=""; HISTB=""
  (( TV & 0x1 )) && NOWB+=" Unterspannung"
  (( TV & 0x2 )) && NOWB+=" Frequenz-Begrenzung"
  (( TV & 0x4 )) && NOWB+=" gedrosselt"
  (( TV & 0x8 )) && NOWB+=" Temperatur-Limit"
  (( TV & 0x10000 )) && HISTB+=" Unterspannung"
  (( TV & 0x20000 )) && HISTB+=" Frequenz-Begrenzung"
  (( TV & 0x40000 )) && HISTB+=" gedrosselt"
  (( TV & 0x80000 )) && HISTB+=" Temperatur-Limit"
  if (( TV & 0x5 )); then fail "Drosselung (vcgencmd)" "aktuell:$NOWB (get_throttled=$THR)" "Netzteil (5 V / 3 A) und Kabel pruefen; Kuehlung pruefen."
  elif (( TV & 0xA )); then warn "Drosselung (vcgencmd)" "aktuell:$NOWB (get_throttled=$THR)" "Kuehlung und Netzteil pruefen."
  elif [[ -n "$HISTB" ]]; then warn "Drosselung (vcgencmd)" "seit dem Boot aufgetreten:$HISTB (get_throttled=$THR)" "Netzteil/Kuehlung pruefen; Wert wird erst beim Neustart zurueckgesetzt."
  else ok "Drosselung (vcgencmd)" "keine Unterspannung/Drosselung (get_throttled=$THR)"; fi
else skip "Drosselung (vcgencmd)" "vcgencmd/get_throttled nicht verfuegbar"; fi

# RAM / Swap
MT=0
if [[ -r "$PROC/meminfo" ]]; then
  MT=0; MA=0; ST=0; SF=0
  while IFS=': ' read -r k v _; do
    case "$k" in MemTotal) MT="$v" ;; MemAvailable) MA="$v" ;; SwapTotal) ST="$v" ;; SwapFree) SF="$v" ;; esac
  done < "$PROC/meminfo"
  if (( MT > 0 )); then
    PA=$((MA * 100 / MT))
    DET="$((MA / 1024)) MB verfuegbar von $((MT / 1024)) MB ($PA %)"
    if (( PA < 5 )); then fail "RAM" "$DET" "Speicher fast voll: prepper-dashboard/prepper-sdr pruefen (top, ps)."
    elif (( PA < 15 )); then warn "RAM" "$DET" "Speicher wird knapp: Prozesse beobachten."
    else ok "RAM" "$DET"; fi
  else skip "RAM" "MemTotal nicht lesbar"; fi
  if (( ST > 0 )); then
    SU=$(((ST - SF) * 100 / ST)); DET="$(((ST - SF) / 1024)) MB von $((ST / 1024)) MB belegt ($SU %)"
    if (( SU > 90 )); then fail "Swap" "$DET" "Swap fast voll: Speicherfresser suchen."
    elif (( SU > 60 )); then warn "Swap" "$DET" "Hohe Swap-Nutzung: Dashboard-Speicher pruefen."
    else ok "Swap" "$DET"; fi
  else info "Swap" "kein Swap eingerichtet"; fi
else skip "RAM/Swap" "$PROC/meminfo nicht lesbar"; fi

# Dateisysteme: Fuellstand und Inodes
if have df; then
  TMPFS_SEEN=0
  DFOUT="$(timeout 10 df -PTl 2>/dev/null)"
  while read -r _ type blocks _ avail pct mnt; do
    [[ "$blocks" =~ ^[0-9]+$ ]] || continue
    case "$type" in
      ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat) WARNP=80; FAILP=92 ;;
      tmpfs) case "$mnt" in /tmp|/dev/shm|/run) ;; *) continue ;; esac; WARNP=70; FAILP=90; [[ "$mnt" == /tmp ]] && TMPFS_SEEN=1 ;;
      *) continue ;;
    esac
    p="${pct%\%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
    DET="$p % belegt, $((avail / 1024)) MB frei ($type)"
    nm="Disk $mnt"
    if (( p >= FAILP )); then fail "$nm" "$DET" "Platz schaffen (alte Backups/.bak/Logs); bei tmpfs: Dateien in $mnt pruefen."
    elif (( p >= WARNP )); then warn "$nm" "$DET" "Fuellstand beobachten, bald aufraeumen."
    else ok "$nm" "$DET"; fi
  done <<<"$DFOUT"
  (( TMPFS_SEEN )) || info "Disk /tmp" "kein eigener tmpfs-Mount fuer /tmp"
  DFI="$(timeout 10 df -PTil 2>/dev/null)"
  while read -r _ type inodes iused _ ipct mnt; do
    [[ "$inodes" =~ ^[0-9]+$ && "$inodes" -gt 0 ]] || continue
    case "$type" in ext2|ext3|ext4|xfs|f2fs) ;; *) continue ;; esac
    p="${ipct%\%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
    DET="$p % Inodes belegt ($iused von $inodes)"
    if (( p >= 95 )); then fail "Inodes $mnt" "$DET" "Sehr viele kleine Dateien: Ursache suchen (find | wc)."
    elif (( p >= 80 )); then warn "Inodes $mnt" "$DET" "Viele kleine Dateien: aufraeumen."
    else ok "Inodes $mnt" "$DET"; fi
  done <<<"$DFI"
else warn "Dateisysteme" "df fehlt" "Paket coreutils pruefen."; fi

# Dateisystem schreibgeschuetzt?
if [[ -r "$PROC/mounts" ]]; then
  RO_BAD=""; RO_ROOT=0
  while read -r _ mnt type opts _; do
    case "$type" in ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat) ;; *) continue ;; esac
    if [[ ",$opts," == *,ro,* ]]; then RO_BAD+=" $mnt"; [[ "$mnt" == / ]] && RO_ROOT=1; fi
  done < "$PROC/mounts"
  if (( RO_ROOT )); then fail "Dateisystem schreibbar" "/ ist schreibgeschuetzt (read-only)${RO_BAD:+ (auch:$RO_BAD)}" "Vermutlich Dateisystemfehler: dmesg lesen, ggf. fsck beim naechsten Boot; SD/SSD pruefen."
  elif [[ -n "$RO_BAD" ]]; then warn "Dateisystem schreibbar" "read-only eingehaengt:$RO_BAD" "Pruefen, ob gewollt (z. B. /boot/firmware)."
  else ok "Dateisystem schreibbar" "alle Datentraeger lesend+schreibend eingehaengt"; fi
else skip "Dateisystem schreibbar" "$PROC/mounts nicht lesbar"; fi
if [[ -d "$APP" ]]; then
  [[ -w "$APP" ]] && ok "Projektordner schreibbar" "$APP fuer $(id -un 2>/dev/null) schreibbar" || fail "Projektordner schreibbar" "$APP nicht beschreibbar" "Rechte/Eigentuemer pruefen (ls -ld)."
else fail "Projektordner" "$APP fehlt" "Pfad pruefen (FC_APP)."; fi

# Kernel-Meldungen (dmesg)
if have dmesg; then
  DM="$(timeout 10 dmesg 2>&1)"; DMRC=$?
  if [[ "$DM" == *"Operation not permitted"* || "$DM" == *"not permitted"* || $DMRC -ne 0 && -z "$DM" ]]; then
    if (( SUDO_OK )); then DM="$(priv dmesg 2>&1)"; DMRC=$?; else DM="__NOPERM__"; fi
  fi
  if [[ "$DM" == "__NOPERM__" ]]; then skip "Kernel-Meldungen (dmesg)" "braucht sudo (dmesg ist fuer Benutzer gesperrt) - Aufruf mit --sudo"
  else
    DMP='I/O error|EXT4-fs error|mmc[0-9:]+.*(error|timeout)|Under-voltage|Out of memory|oom-kill|blk_update_request|Buffer I/O|Remounting filesystem read-only|segfault|Call trace|hung task|nvme.*(timeout|reset)|usb.*(disconnect, error|device descriptor read.*error)'
    DMC="$(pf "$DM" | grep -Ec "$DMP")"; [[ "$DMC" =~ ^[0-9]+$ ]] || DMC=0
    if (( DMC > 0 )); then
      LASTL="$(pf "$DM" | grep -E "$DMP" | tail -1)"
      DMAGE=""
      DMTS=""; [[ "$LASTL" =~ ^\[\ *([0-9]+)\.[0-9]+\] ]] && DMTS="${BASH_REMATCH[1]}"
      if [[ -n "$DMTS" && "${US:-}" =~ ^[0-9]+$ ]]; then
        DMA=$((US - DMTS)); (( DMA < 0 )) && DMA=0
        DMAGE=" (Zeitstempel $DMTS s nach dem Boot, Uptime $(dur "$US"): letzte Meldung vor $(dur "$DMA")$( ((DMA > 3600)) && echo ', also alt' ))"
      fi
      warn "Kernel-Meldungen (dmesg)" "$DMC Zeile(n) mit Fehlerbezug seit dem Boot$DMAGE, zuletzt: $(mask "${LASTL:0:140}")" "Der Kernel-Puffer behaelt Meldungen bis zum Neustart: eine alte Meldung ist kein aktuelles Problem. dmesg lesen (journalctl -k); bei I/O-/Dateisystemfehlern Datentraeger sichern und pruefen."
    else ok "Kernel-Meldungen (dmesg)" "keine I/O-/Dateisystem-/Unterspannungs-/OOM-Fehler seit dem Boot"; fi
  fi
else skip "Kernel-Meldungen (dmesg)" "dmesg fehlt"; fi

# ================================================================ 2) Zeit
section "Zeit (Europe/Berlin, chrony)"
if have timedatectl; then
  declare -A TD=()
  while IFS= read -r line; do [[ "$line" == *=* ]] && TD["${line%%=*}"]="${line#*=}"; done < <(timeout 5 timedatectl show 2>/dev/null)
  if [[ -n "${TD[Timezone]:-}" ]]; then
    [[ "${TD[Timezone]}" == "Europe/Berlin" ]] && ok "Zeitzone" "Europe/Berlin" || warn "Zeitzone" "System steht auf ${TD[Timezone]:0:40}, erwartet Europe/Berlin" "Nur pruefen: timedatectl (Dashboard-Zeiten und Wetter-Slots rechnen in Berliner Zeit)."
  else skip "Zeitzone" "timedatectl liefert keine Zeitzone"; fi
  case "${TD[NTPSynchronized]:-}" in
    yes) ok "NTP synchronisiert" "timedatectl: NTPSynchronized=yes" ;;
    no) warn "NTP synchronisiert" "timedatectl: NTPSynchronized=no" "chrony pruefen (chronyc tracking, chronyc sources)." ;;
    *) skip "NTP synchronisiert" "kein Wert von timedatectl" ;;
  esac
else skip "Zeitzone / NTP" "timedatectl fehlt"; fi

if have chronyc; then
  TR="$(timeout 5 chronyc -n -c tracking 2>/dev/null)"; TRRC=$?
  if (( TRRC == 0 )) && [[ -n "$TR" ]]; then
    IFS=, read -r -a CF <<<"$TR"
    STR="${CF[2]:-}"; REFN="${CF[1]:-}"; OFFS="${CF[4]:-}"; RTM="${CF[3]:-0}"; LEAP="${CF[13]:-}"
    [[ -n "$REFN" ]] || REFN="${CF[0]:-?}"
    if [[ "$OFFS" =~ ^-?[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ && "$STR" =~ ^[0-9]+$ ]]; then
      OFFUS="$(awk -v o="$OFFS" 'BEGIN{v=o*1e6; if(v<0)v=-v; printf "%.1f", v}')"
      SIDE="$(awk -v o="$OFFS" 'BEGIN{print (o>0)?"Systemuhr geht nach":((o<0)?"Systemuhr geht vor":"exakt")}')"
      DET="Offset $OFFUS us ($SIDE), Stratum $STR, Referenz ${REFN:0:40}"
      if [[ "$LEAP" == *"Not synchronised"* || "$STR" == 0 || "$STR" -ge 16 ]]; then fail "chrony: Synchronisation" "nicht synchronisiert (Leap: ${LEAP:-?}, Stratum $STR)" "chronyc sources -v lesen; Quelle $NTP_HOST erreichbar? Uhr ohne RTC ist dann unzuverlaessig."
      elif fcmp "$OFFUS" '>=' 100000; then fail "chrony: Offset" "$DET (ueber 100 ms)" "chronyc sources/tracking lesen; Zeitquelle pruefen."
      elif fcmp "$OFFUS" '>=' 10000; then warn "chrony: Offset" "$DET (ueber 10 ms)" "Beobachten; bei Dauer Zeitquelle pruefen."
      else ok "chrony: Offset" "$DET"; fi
      if [[ "$STR" -gt 5 ]]; then warn "chrony: Stratum" "Stratum $STR (erwartet 2 bis 4)" "Zeitquelle pruefen."; else ok "chrony: Stratum" "Stratum $STR"; fi
      [[ "$LEAP" == "Normal" ]] && ok "chrony: Leap-Status" "Normal" || { [[ "$LEAP" == *"Not synchronised"* ]] || warn "chrony: Leap-Status" "${LEAP:-?}" "Nur Anzeige: Schaltsekunde angekuendigt."; }
      RTI="${RTM%%.*}"
      if [[ "$RTI" =~ ^[0-9]+$ && "$RTI" -gt 0 ]]; then
        RAGE=$((EPOCHSECONDS - RTI))
        if (( RAGE > 3600 )); then warn "chrony: letzte Messung" "vor $(dur "$RAGE") (erwartet < 1 h)" "Quelle $NTP_HOST erreichbar? chronyc sources lesen."
        else ok "chrony: letzte Messung" "vor $(dur "$RAGE")"; fi
      fi
    else fail "chrony: tracking" "Ausgabe nicht lesbar (Format)" "chronyc -c tracking von Hand pruefen."; fi
  else fail "chrony: tracking" "chronyc antwortet nicht (rc $TRRC)" "Dienst chrony pruefen: systemctl status chrony."; fi
  SRC="$(timeout 5 chronyc -n -c sources 2>/dev/null)"
  if [[ -n "$SRC" ]]; then
    FOUND=0; NSRC=0
    while IFS=, read -r mode state name rest; do
      [[ -n "$name" ]] || continue
      NSRC=$((NSRC + 1))
      [[ "$name" == "$NTP_HOST" ]] || continue
      FOUND=1
      IFS=, read -r -a SF <<<"$rest"
      REACH="${SF[2]:-?}"
      case "$state" in
        '*') ok "chrony: Quelle $NTP_HOST" "Status $mode$state (ausgewaehlt), Reach $REACH" ;;
        '+') ok "chrony: Quelle $NTP_HOST" "Status $mode$state (kombiniert), Reach $REACH" ;;
        x) fail "chrony: Quelle $NTP_HOST" "als falsch markiert (falseticker, Status $mode$state), Reach $REACH" "Zeitquelle pruefen: chronyc sources -v." ;;
        *) warn "chrony: Quelle $NTP_HOST" "Status $mode$state, Reach $REACH (nicht ausgewaehlt)" "Quelle erreichbar? chronyc sources -v lesen." ;;
      esac
    done <<<"$SRC"
    (( FOUND )) || warn "chrony: Quelle $NTP_HOST" "nicht unter den $NSRC Quellen" "Konfiguration der Zeitquelle pruefen (nur lesen: chronyc sources)."
  else warn "chrony: Quellen" "keine Quellen gelistet" "chronyc sources lesen."; fi
else warn "chrony" "chronyc fehlt - Zeitpruefung nicht moeglich" "Paket chrony pruefen."; fi

# gpsd auf der Zeitquelle: nur TCP-Verbindung testen (nichts senden, nichts lesen)
if [[ "$NTP_HOST" =~ ^[0-9A-Za-z.:-]+$ ]] && [[ "$GPSD_PORT" =~ ^[0-9]+$ ]]; then
  # shellcheck disable=SC2016  # $0/$1 sollen in der Unter-Shell expandieren, nicht hier
  if timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1" && exec 3>&-' "$NTP_HOST" "$GPSD_PORT" 2>/dev/null; then ok "gpsd $NTP_HOST:$GPSD_PORT" "Port erreichbar (nur Verbindung getestet)"
  else warn "gpsd $NTP_HOST:$GPSD_PORT" "Port nicht erreichbar" "gpsd auf $NTP_HOST laeuft? (nur auf dem Zeitgeber pruefen; Dashboard-Zeit nutzt chrony)"; fi
fi

# ================================================================ 3) Dienste
section "Dienste (systemd)"
declare -A S=()
sc_show() {
  S=(); local line
  while IFS= read -r line; do [[ "$line" == *=* ]] && S["${line%%=*}"]="${line#*=}"; done < <(timeout 10 systemctl show "$1" --no-pager -p LoadState -p ActiveState -p SubState -p UnitFileState -p NRestarts -p MainPID -p ExecMainStartTimestamp -p WatchdogUSec -p NotifyAccess -p NeedDaemonReload -p DropInPaths -p Result 2>/dev/null)
}
declare -A SVC_MAINPID=() SVC_START=()
if have systemctl; then
  for u in "${SERVICES[@]}"; do
    sc_show "$u"
    if [[ -z "${S[ActiveState]:-}" ]]; then skip "Dienst $u" "systemctl liefert nichts"; continue; fi
    if [[ "${S[LoadState]:-}" == "not-found" ]]; then fail "Dienst $u" "Unit nicht installiert" "Installation pruefen."; continue; fi
    SVC_MAINPID[$u]="${S[MainPID]:-0}"; SVC_START[$u]="${S[ExecMainStartTimestamp]:-}"
    if [[ "${S[ActiveState]}" == "active" && "${S[SubState]:-}" == "running" ]]; then ok "Dienst $u" "active (running), PID ${S[MainPID]:-?}"
    else fail "Dienst $u" "${S[ActiveState]}/${S[SubState]:-?}, Ergebnis ${S[Result]:-?}" "journalctl -u $u -n 50 lesen; Start nur nach Ursache (kein Neustart durch dieses Skript)."; fi
    case "${S[UnitFileState]:-}" in
      enabled|enabled-runtime|static|alias|generated) ok "Autostart $u" "${S[UnitFileState]}" ;;
      "") skip "Autostart $u" "Zustand unbekannt" ;;
      *) warn "Autostart $u" "${S[UnitFileState]} (startet nach einem Reboot nicht)" "systemctl enable $u (mit sudo, bewusst entscheiden)." ;;
    esac
    NR="${S[NRestarts]:-}"
    if [[ "$NR" =~ ^[0-9]+$ ]]; then
      if (( NR >= 5 )); then fail "Neustarts $u" "NRestarts=$NR seit dem letzten manuellen Start" "journalctl -u $u lesen: Absturzschleife?"
      elif (( NR >= 1 )); then warn "Neustarts $u" "NRestarts=$NR (automatische Neustarts seit dem letzten Start)" "journalctl -u $u --since -24h lesen: warum hat systemd neu gestartet?"
      else ok "Neustarts $u" "NRestarts=0"; fi
    else skip "Neustarts $u" "NRestarts nicht verfuegbar"; fi
  done
  # Watchdog des Dashboards
  sc_show prepper-dashboard
  WDS="$(sd_seconds "${S[WatchdogUSec]:-}")"
  if [[ "$WDS" == "300" ]]; then ok "Watchdog Dashboard" "WatchdogUSec=${S[WatchdogUSec]} (300 s), NotifyAccess=${S[NotifyAccess]:-?}"
  elif [[ -z "$WDS" ]]; then skip "Watchdog Dashboard" "WatchdogUSec nicht lesbar"
  else fail "Watchdog Dashboard" "WatchdogUSec=${S[WatchdogUSec]:-?} (erwartet 5min = 300 s)" "Drop-in zz-relwatch.conf pruefen (relWatch, commit30)."; fi
  DROPF="$DROPIN_DIR/zz-relwatch.conf"
  if [[ -r "$DROPF" || "${S[DropInPaths]:-}" == *zz-relwatch.conf* ]]; then
    ok "Drop-in zz-relwatch.conf" "vorhanden$([[ "${S[DropInPaths]:-}" == *zz-relwatch.conf* ]] && echo ', von systemd geladen')"
  else fail "Drop-in zz-relwatch.conf" "fehlt in $DROPIN_DIR" "relWatch (commit30) erneut anwenden."; fi
  if [[ "${S[NeedDaemonReload]:-}" == "yes" ]]; then warn "systemd: daemon-reload" "Unit-Dateien geaendert, daemon-reload steht aus" "sudo systemctl daemon-reload (bewusst entscheiden)."; fi
  # Laeuft der Prozess auf altem Programmstand?
  if [[ -n "${SVC_START[prepper-dashboard]:-}" && -f "$APP/dashboard.py" ]]; then
    ST_EP="$(date -d "${SVC_START[prepper-dashboard]}" +%s 2>/dev/null)"; DM_EP="$(stat -c %Y -- "$APP/dashboard.py" 2>/dev/null)"
    if [[ "$ST_EP" =~ ^[0-9]+$ && "$DM_EP" =~ ^[0-9]+$ ]]; then
      if (( DM_EP > ST_EP + 2 )); then warn "Dashboard-Prozess aktuell" "dashboard.py ist neuer als der laufende Prozess (Datei $(dur $((EPOCHSECONDS - DM_EP))) alt, Start vor $(dur $((EPOCHSECONDS - ST_EP))))" "Neustart noetig, damit der Stand wirkt (nicht in 20:55-21:59 und HH:55-HH:04 der Wetter-Slots)."
      else ok "Dashboard-Prozess aktuell" "laeuft seit $(dur $((EPOCHSECONDS - ST_EP))), Datei nicht neuer"; fi
    fi
  fi
  # Speicher der Dienste
  for u in "${SERVICES[@]}"; do
    pid="${SVC_MAINPID[$u]:-0}"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -r "$PROC/$pid/status" ]] || continue
    rss="$(awk '/^VmRSS:/{print $2}' "$PROC/$pid/status" 2>/dev/null)"
    [[ "$rss" =~ ^[0-9]+$ ]] || continue
    if (( MT > 0 && rss * 100 / MT > 40 )); then warn "Speicher $u" "RSS $((rss / 1024)) MB (ueber 40 % des RAM)" "Speicherleck? Dienst beobachten."
    else info "Speicher $u" "RSS $((rss / 1024)) MB"; fi
  done
  # Timer und fehlgeschlagene Units
  TS="$(timeout 5 systemctl is-active prepper-health.timer 2>/dev/null)"
  case "$TS" in active) ok "Timer prepper-health" "active (Health-Check alle 3 h)" ;; "") : ;; *) warn "Timer prepper-health" "$TS" "systemctl status prepper-health.timer lesen." ;; esac
  FU="$(timeout 10 systemctl --failed --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  if [[ -z "${FU// /}" ]]; then ok "Fehlgeschlagene Units" "keine"
  else
    SEV=warn; for u in "${SERVICES[@]}"; do [[ "$FU" == *"$u.service"* ]] && SEV=fail; done
    _emit "$SEV" "Fehlgeschlagene Units" "${FU:0:200}" "systemctl status <Unit> lesen; journalctl -u <Unit> -n 50."
  fi
else warn "Dienste" "systemctl fehlt - Dienstpruefung nicht moeglich" "Nur auf der Pi sinnvoll."; fi

# ================================================================ 4) Dashboard
section "Dashboard (Port $PORT)"
BASEURL="http://$HOSTN:$PORT"
DASH_UP=1; NINA_MODE=""; WD_ALL_LVL=""; WD_AIRSPY_LVL=""
if ! have curl; then
  warn "Dashboard" "curl fehlt - Seiten-/API-Pruefung nicht moeglich" "Paket curl pruefen."; DASH_UP=0
else
  http_get "$BASEURL/api/time" 5
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail "Dashboard erreichbar" "GET /api/time -> HTTP $HTTP_CODE (curl rc $HTTP_RC, ${HTTP_MS} ms)" "Dienst prepper-dashboard pruefen (journalctl -u prepper-dashboard -n 50); Start dauert nach Neustart bis ca. 1 min."
    DASH_UP=0
  fi
fi

if (( DASH_UP )); then
  # --- /api/time (leichte Seite, zugleich Uhrenvergleich)
  if jloads "$HTTP_BODY"; then
    DMS="$(jv ms)"; NOWMS="$(date +%s%3N 2>/dev/null)"
    if [[ "$DMS" =~ ^[0-9]+$ && "$NOWMS" =~ ^[0-9]+$ ]]; then
      D=$((NOWMS - DMS)); (( D < 0 )) && D=$((-D))
      if (( D > 10000 )); then fail "/api/time Uhrenvergleich" "Dashboard-Uhr weicht $((D / 1000)) s von der Systemuhr ab" "Dashboard neu geladen? Zeitquelle pruefen."
      elif (( D > 2000 )); then warn "/api/time Uhrenvergleich" "Abweichung $((D / 1000)) s" "Beobachten (Antwortzeit ${HTTP_MS} ms)."
      else ok "/api/time Uhrenvergleich" "Abweichung $D ms zur Systemuhr, Antwort $HTTP_MS ms, Dashboard-Zeit $(mask "$(jv str)")"; fi
    else warn "/api/time Uhrenvergleich" "Antwort ohne ms-Feld" "Dashboard-Version pruefen."; fi
  else warn "/api/time Uhrenvergleich" "Antwort ist kein JSON" "Dashboard pruefen."; fi

  # --- Seiten und APIs
  # Kurz nach einem Dashboard-Start ist /pi bekannt langsamer (Zwischenspeicher fuellt sich): dann hoechstens HINWEIS
  FRESH_S=-1
  if [[ -n "${SVC_START[prepper-dashboard]:-}" ]]; then
    FS_EP="$(date -d "${SVC_START[prepper-dashboard]}" +%s 2>/dev/null)"
    [[ "$FS_EP" =~ ^[0-9]+$ ]] && FRESH_S=$((EPOCHSECONDS - FS_EP))
  fi
  PAGE1_BODY=""
  if (( QUICK )); then
    skip "Seitentest (26 Seiten/APIs)" "mit --kurz uebersprungen"
  else
    NP=0; NPOK=0; NSKIPB=0
    for pg in "${PAGES[@]}"; do
      if (( SECONDS - T0 > BUDGET_S )); then NSKIPB=$((NSKIPB + 1)); continue; fi
      NP=$((NP + 1))
      http_get "$BASEURL$pg" 8
      [[ "$pg" == "/" && "$HTTP_CODE" == "200" ]] && PAGE1_BODY="$HTTP_BODY"
      if [[ "$HTTP_CODE" != "200" ]]; then
        if [[ "$HTTP_CODE" == "000" ]]; then fail "GET $pg" "keine Antwort (curl rc $HTTP_RC, nach ${HTTP_MS} ms; Timeout 8 s)" "Seite haengt oder Dienst weg: journalctl -u prepper-dashboard -n 80."
        else fail "GET $pg" "HTTP $HTTP_CODE in ${HTTP_MS} ms" "journalctl -u prepper-dashboard -n 80 lesen (Traceback?)."; fi
      elif [[ "$HTTP_BODY" == *'id="sbLoading"'* ]]; then
        warn "GET $pg" "HTTP 200, aber Ladehinweis (Dashboard startet noch), ${HTTP_MS} ms" "1 Minute warten und erneut pruefen."
      elif [[ "$pg" == /pi ]] && (( HTTP_MS >= 2500 && FRESH_S >= 0 && FRESH_S < 600 )); then
        warn "GET $pg" "HTTP 200 in ${HTTP_MS} ms, Dashboard erst vor $(dur "$FRESH_S") gestartet (nach einem Neustart kurz langsamer: Zwischenspeicher, bekannt)" "Nach ca. 10 Minuten erneut pruefen; dann sollte /pi wieder schnell sein."
      elif (( HTTP_MS >= 6000 )); then fail "GET $pg" "HTTP 200, aber sehr langsam: ${HTTP_MS} ms" "Last pruefen (Load, SDR); /api/sysboot/status zeigt langsame Anfragen."
      elif (( HTTP_MS >= 2500 )); then warn "GET $pg" "HTTP 200 in ${HTTP_MS} ms (langsam, ueber 2,5 s)" "Last beobachten; /api/sysboot/status -> slow."
      else ok "GET $pg" "HTTP 200 in ${HTTP_MS} ms"; NPOK=$((NPOK + 1)); fi
    done
    (( NSKIPB > 0 )) && warn "Seitentest Zeitbudget" "$NSKIPB Seite(n) nicht geprueft: Zeitbudget ${BUDGET_S} s ueberschritten" "Pi ist sehr langsam: Last pruefen, Skript erneut starten."
  fi

  # --- /pi: Kacheln und DB-Zeile (eine Anfrage)
  http_get "$BASEURL/pi" 8
  if [[ "$HTTP_CODE" == "200" ]]; then
    PI_BODY="$HTTP_BODY"
    [[ "$PI_BODY" == *doPrepperRestore* ]] && ok "/pi Kachel Sicherung" "vorhanden" || warn "/pi Kachel Sicherung" "nicht in der Seite gefunden" "Seite /pi und Patch-Stand pruefen."
    [[ "$PI_BODY" == *Projektbeschreibung* ]] && ok "/pi Kachel Projektbeschreibung" "vorhanden" || warn "/pi Kachel Projektbeschreibung" "nicht in der Seite gefunden" "Seite /pi und Patch-Stand pruefen."
    DBJ="${PI_BODY#*id=\"dbVisData\"}"; DBJ="${DBJ#*>}"; DBJ="${DBJ%%</script>*}"
    if [[ "$PI_BODY" == *'id="dbVisData"'* ]] && jloads "$DBJ"; then
      DBS="$(jv state)"; DBV="$(mask "$(jv val)")"
      case "$DBS" in
        ok) ok "/pi Datenbank-Zeile" "$DBV" ;;
        ausgefallen) fail "/pi Datenbank-Zeile" "$DBV" "Datenbank sichern (Backup), dann quick_check/Wartung pruefen; nichts loeschen." ;;
        alt) warn "/pi Datenbank-Zeile" "$DBV" "Datenbank-Wartung (relDb) pruefen; kein WAL oder veraltete Pruefung." ;;
        *) info "/pi Datenbank-Zeile" "${DBV:-ohne Wert} (Zustand ${DBS:-?})" ;;
      esac
    else warn "/pi Datenbank-Zeile" "dbVis-Daten nicht in /pi gefunden" "commit31 dbVis angewendet? (Marker dbVis)"; fi
  else skip "/pi Kacheln/DB-Zeile" "/pi lieferte HTTP $HTTP_CODE"; fi

  # --- /api/clock-off
  http_get "$BASEURL/api/clock-off" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    CSRC="$(jv src)"; CUS="$(jv us)"; CTXT="$(mask "$(jv text)")"
    case "$CSRC" in
      chrony) ok "/api/clock-off (Zeit-Offset-Kachel)" "Quelle chrony: $CTXT (${CUS:-?} us)" ;;
      ntplib) warn "/api/clock-off (Zeit-Offset-Kachel)" "nur ntplib-Rueckfall: $CTXT" "Dashboard kann chronyc nicht lesen: chronyc -c tracking als Benutzer fmg pruefen." ;;
      *) warn "/api/clock-off (Zeit-Offset-Kachel)" "kein Wert (Quelle ${CSRC:-?})" "chronyc pruefen." ;;
    esac
  else skip "/api/clock-off" "HTTP $HTTP_CODE oder kein JSON"; fi

  # --- /api/sysboot/status (rel, wx, alarm, Start)
  http_get "$BASEURL/api/sysboot/status" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    [[ "$(jv loading)" == "false" ]] && ok "sysBoot: Start" "Dashboard fertig geladen, ersten Voll-Update nach $(jv first_update_s) s, Laufzeit $(dur "$(jv up_s)")" || warn "sysBoot: Start" "Dashboard laedt noch (loading=$(jv loading))" "Nach ca. 1 Minute erneut pruefen."
    FE="$(jv first_err)"; [[ -z "$FE" || "$FE" == null ]] || warn "sysBoot: erstes Update" "Fehler beim ersten Update: $(mask "$FE")" "journalctl -u prepper-dashboard --since -1h lesen."
    ST_SELF="$(jv selftest)"
    if [[ "$ST_SELF" == *FEHLER* ]]; then fail "sysBoot: Selbsttest" "$(mask "$ST_SELF")" "Dashboard-Journal lesen; Patch-Stand pruefen."; elif [[ -n "$ST_SELF" && "$ST_SELF" != null ]]; then ok "sysBoot: Selbsttest" "$(mask "${ST_SELF:0:80}")"; fi
    SLN="$(jv slow_n)"
    if [[ "$SLN" =~ ^[0-9]+$ ]]; then
      SL0="$(jv slow.0.p)"
      if (( SLN > 10 )); then warn "sysBoot: langsame Anfragen" "$SLN Anfragen ueber 3 s seit dem Start${SL0:+ (zuletzt $(mask "$SL0"))}" "Last/SDR pruefen; journalctl -u prepper-dashboard | grep langsam."
      else ok "sysBoot: langsame Anfragen" "$SLN seit dem Start (Grenze 10)"; fi
    fi
    # relWatch
    if [[ -n "$(jv 'rel.threads.@')" || -n "$(jv rel.ticks)" ]]; then
      BAD=""; NTH=0
      for th in $(jv 'rel.threads.@'); do
        NTH=$((NTH + 1)); stt="$(jv "rel.threads.$th.state")"
        case "$stt" in ok) ;; stale) BAD+=" $th:stale(ohne Durchlauf $(dur "$(jv "rel.threads.$th.age_s")"))" ;; tot) BAD+=" $th:TOT" ;; *) BAD+=" $th:$stt" ;; esac
      done
      if [[ "$BAD" == *TOT* ]]; then fail "relWatch: Faeden" "Faden gestorben:$BAD" "journalctl -u prepper-dashboard lesen; der Watchdog startet bei Dauerfehler neu."
      elif [[ -n "$BAD" ]]; then warn "relWatch: Faeden" "Faden stockt:$BAD" "Beobachten; bei Dauer Dashboard-Journal lesen."
      else ok "relWatch: Faeden" "$NTH Hintergrundfaeden laufen ($(jv 'rel.threads.@'))"; fi
      RR="$(jv rel.red.#)"; [[ "$RR" == 0 || -z "$RR" ]] || warn "relWatch: rot" "$RR Eintrag/Eintraege rot: $(mask "$(jv rel.red.0)") $(mask "$(jv rel.red.1)")" "Dashboard-Journal lesen."
      [[ "$(jv rel.thread)" == true ]] && ok "relWatch: Waechterfaden" "laeuft ($(jv rel.ticks) Takte)" || warn "relWatch: Waechterfaden" "Waechterfaden laeuft nicht" "Dashboard neu starten lassen (REL-01)."
      RE="$(jv rel.err)"; [[ -z "$RE" || "$RE" == null ]] || warn "relWatch: Fehler" "$(mask "$RE")" "Dashboard-Journal lesen."
      if [[ "$(jv rel.wd.sock)" == true ]]; then
        BA="$(jv rel.wd.beat_age_s)"
        if [[ "$(jv rel.wd.brake)" == true ]]; then warn "Watchdog: Neustart-Bremse" "Bremse aktiv: $(mask "$(jv rel.wd.brake_why)") (Starts/h: $(jv rel.wd.starts_1h))" "Ursache im Journal suchen; die Bremse verhindert Neustartschleifen."
        elif [[ "$BA" =~ ^[0-9]+$ ]] && (( BA > 120 )); then warn "Watchdog: Herzschlag" "letzter Herzschlag vor $(dur "$BA")" "Dashboard-Faden haengt? Journal lesen."
        else ok "Watchdog: Herzschlag" "systemd-Socket aktiv, Takt vor ${BA:-?} s, Pruefalter $(jv rel.wd.probe_age_s) s, scharf: $(jv rel.wd.armed)"; fi
        FS_="$(jv rel.wd.fail_s)"; [[ -z "$FS_" || "$FS_" == null ]] || warn "Watchdog: Selbsttest-Anfrage" "Webserver antwortet seit $FS_ s nicht (Grenze $(jv rel.wd.fail_limit_s) s)" "Gleich Neustart durch Watchdog moeglich: journalctl -u prepper-dashboard lesen."
      else warn "Watchdog: Herzschlag" "Dienst laeuft ohne systemd-Watchdog-Socket" "Drop-in zz-relwatch.conf und Dashboard-Neustart (relWatch) pruefen."; fi
    else warn "sysBoot: rel-Abschnitt" "kein rel-Abschnitt in /api/sysboot/status" "relWatch (commit30) angewendet?"; fi
    # wxSlot
    if [[ -n "$(jv wx.installed)" ]]; then
      if [[ "$(jv wx.installed)" != true ]]; then fail "wxSlot: installiert" "wxSlot meldet nicht installiert" "commit34 pruefen."
      else
        WXE="$(jv wx.fehler)"
        [[ "$(jv wx.faden)" == true ]] && ok "wxSlot: Faden" "laeuft ($(jv wx.takte) Takte), Slot $(jv wx.slot)" || fail "wxSlot: Faden" "Wetter-Slot-Faden laeuft nicht" "Dashboard-Journal lesen; ohne Faden werden Slots nicht nachgeholt."
        [[ -z "$WXE" || "$WXE" == null ]] || warn "wxSlot: Fehler" "$(mask "$WXE")" "Dashboard-Journal: grep wxSlot."
        WR="$(jv wx.ergebnis)"; WV="$(jv wx.versuche)"
        if [[ "$WR" == aufgegeben* || "$WR" == verpasst* ]]; then warn "wxSlot: Slot-Ergebnis" "Slot $(jv wx.slot): $(mask "$WR"), Versuche ${WV:-0}" "Nur anzeigen: war das Dashboard in der Slot-Stunde neu gestartet? /mesh-Verlauf und Bridge-Zustand pruefen."
        else ok "wxSlot: Slot-Ergebnis" "Slot $(jv wx.slot): $(mask "${WR:-noch offen (Slot-Stunde nicht erreicht oder Stempel vorhanden)}"), Stempel im Slot=$(jv wx.stempel_im_slot), Versuche ${WV:-0}"; fi
        WSF="$(jv wx.strom.fehler)"
        if [[ -n "$WSF" && "$WSF" != null ]]; then warn "wxSlot: Stromausfall-Stand" "Fehler: $(mask "$WSF")" "Dashboard-Journal: grep wxSlot."
        else ok "wxSlot: Stromausfall-Stand" "Datei vorhanden=$(jv wx.strom.datei), geladen: $(mask "$(jv wx.strom.geladen)"), bekannte IDs: $(jv wx.strom.bekannt)"; fi
      fi
    else warn "sysBoot: wx-Abschnitt" "kein wx-Abschnitt in /api/sysboot/status" "wxSlot (commit34) angewendet?"; fi
    # Alarm-Faden
    if [[ -n "$(jv alarm.thread)" ]]; then
      AL_BAD=""
      [[ "$(jv alarm.thread)" == true ]] || AL_BAD+=" Alarm-Faden laeuft nicht;"
      AE="$(jv alarm.err)"; [[ -z "$AE" || "$AE" == null ]] || AL_BAD+=" Fehler: $(mask "$AE");"
      for w in nina dwd; do
        AG="$(jv "alarm.src.$w.age_s")"; AF="$(jv "alarm.src.$w.fails")"; PS="$(jv alarm.poll_s)"
        [[ "$AF" =~ ^[0-9]+$ && "$AF" -ge 3 ]] && AL_BAD+=" $w $AF Fehlversuche in Folge;"
        [[ "$AG" =~ ^[0-9]+$ && "$PS" =~ ^[0-9]+$ ]] && (( AG > PS * 3 )) && AL_BAD+=" $w letzter Abruf vor $(dur "$AG");"
      done
      if [[ -n "$AL_BAD" ]]; then warn "Alarm-Faden (NINA/DWD)" "$AL_BAD" "Internet/Quellen pruefen; Dashboard-Journal lesen."
      else ok "Alarm-Faden (NINA/DWD)" "laeuft, NINA vor $(jv alarm.src.nina.age_s) s, DWD vor $(jv alarm.src.dwd.age_s) s (Takt $(jv alarm.poll_s) s)"; fi
    fi
  else skip "/api/sysboot/status" "HTTP $HTTP_CODE oder kein JSON"; fi

  # --- NINA-Zertifikatskette (ninaFix, commit36): Rueckfall ueber gepinnte Zwischenstelle ist ERWARTET (OK/HINWEIS), nur eine nicht pruefbare Kette ist FEHLER
  http_get "$BASEURL/api/nina-cert" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    NINA_MODE="$(jv mode)"; NPINOK="$(jv pin_ok)"; NPDAYS="$(jv pin_days_left)"; NFBN="$(jv fallback_n)"; NFAGO="$(jv fallback_ago_s)"
    NFAILW="$(mask "$(jv fail.why)")"; NPINWHY="$(mask "$(jv pin_why)")"; NPLN="$(jv plain_n)"
    NDET="Abrufe normal ${NPLN:-?}x, ueber Rueckfall ${NFBN:-?}x"
    case "$NINA_MODE" in
      normal)
        ok "NINA Zertifikatskette" "normaler Abruf mit voller Pruefung (Server sendet die Kette vollstaendig oder Rueckfall nicht noetig); $NDET" ;;
      rueckfall)
        if [[ "$NPINOK" == true ]]; then
          ok "NINA Zertifikatskette (Rueckfall)" "Rueckfall ueber gepinnte Zwischenstelle (Sectigo E36) aktiv - erwartet, warnung.bund.de sendet die Zwischenstelle nicht; Pruefung bleibt voll, letzter Rueckfall vor $(dur "${NFAGO:-0}"); $NDET"
        else
          warn "NINA Zertifikatskette (Rueckfall)" "Rueckfall gemeldet, aber gepinnte Zwischenstelle nicht nutzbar (${NPINWHY:-?}); $NDET" "Datei certs/sectigo-e36.pem im Projekt pruefen (nur lesen); NINA kann sonst blind werden."
        fi ;;
      fehler)
        fail "NINA Zertifikatskette" "Kette auch mit dem Rueckfall nicht pruefbar: ${NFAILW:-?} (vor $(dur "$(jv fail.ago_s)")); NINA zeigt nur den letzten Stand" "Dashboard-Journal lesen (grep ninaFix); Zwischenstelle certs/sectigo-e36.pem und Systemzertifikate pruefen; kein verify=False einbauen." ;;
      *) warn "NINA Zertifikatskette" "/api/nina-cert meldet Zustand '${NINA_MODE:-?}'" "Dashboard-Journal lesen (grep ninaFix)." ;;
    esac
    if [[ "$NPINOK" == false ]] && [[ "$NINA_MODE" == normal ]]; then
      warn "NINA gepinnte Zwischenstelle" "Rueckfall waere ausgeschaltet: ${NPINWHY:-?}" "certs/sectigo-e36.pem im Projekt pruefen (nur lesen); solange der Server die Kette sendet, ist NINA nicht betroffen."
    fi
    if [[ "$NPDAYS" =~ ^-?[0-9]+$ ]]; then
      if (( NPDAYS < 0 )); then fail "NINA Zwischenstelle Ablauf" "gepinnte Zwischenstelle ist abgelaufen (vor $((-NPDAYS)) Tagen)" "Neue Zwischenstelle bereitstellen (Patch), sonst ist der Rueckfall unwirksam."
      elif (( NPDAYS < 90 )); then warn "NINA Zwischenstelle Ablauf" "gepinnte Zwischenstelle laeuft in $NPDAYS Tagen ab" "Neue Zwischenstelle rechtzeitig bereitstellen."
      else ok "NINA Zwischenstelle Ablauf" "gepinnte Zwischenstelle noch $NPDAYS Tage gueltig (bis 2036)"; fi
    fi
  elif [[ "$HTTP_CODE" == 404 ]]; then warn "NINA Zertifikatskette" "/api/nina-cert nicht vorhanden (HTTP 404)" "ninaFix (commit36) angewendet?"
  else skip "NINA Zertifikatskette" "/api/nina-cert lieferte HTTP $HTTP_CODE oder kein JSON"; fi

  # --- hideTexts (commit37): Lage-Seite ("/") ohne Zertifikatsketten-Hinweis (Rueckfall) und ohne SDR-Rollentext
  if [[ -z "$PAGE1_BODY" ]]; then http_get "$BASEURL/" 8; [[ "$HTTP_CODE" == 200 ]] && PAGE1_BODY="$HTTP_BODY"; fi
  if [[ -n "$PAGE1_BODY" && "$PAGE1_BODY" != *'id="sbLoading"'* ]]; then
    if [[ "$PAGE1_BODY" == *'id="nina-cert"'* ]]; then
      if [[ "$NINA_MODE" == rueckfall ]]; then warn "hideTexts: Ketten-Hinweis" "Lage-Seite zeigt den Zertifikatsketten-Hinweis trotz erwartetem Rueckfall" "hideTexts (commit37) angewendet? Marker hideTexts und sha16 pruefen."
      else info "hideTexts: Ketten-Hinweis" "Lage-Seite zeigt den Hinweis (Zustand ${NINA_MODE:-?}: Fehler oder Ablauf unter 90 Tagen bleiben bewusst sichtbar)"; fi
    else ok "hideTexts: Ketten-Hinweis" "Lage-Seite ohne Zertifikatsketten-Hinweis"; fi
    if [[ "$PAGE1_BODY" != *'id="lm1-js"'* ]]; then skip "hideTexts: SDR-Rollentext" "Lage-Skript (lm1-js) nicht in der Seite gefunden"
    elif [[ "$PAGE1_BODY" == *"A.note"* || "$PAGE1_BODY" == *"querySelector('.sdl-note')"* ]]; then warn "hideTexts: SDR-Rollentext" "Lage-Skript schreibt den SDR-Rollentext (bc_note) noch in die BR24-Kachel" "hideTexts (commit37) angewendet? Marker hideTexts und sha16 pruefen."
    else ok "hideTexts: SDR-Rollentext" "Lage-Skript schreibt den SDR-Rollentext nicht mehr in die Kachel"; fi
  else skip "hideTexts" "Lage-Seite nicht verfuegbar oder laedt noch"; fi

  # --- SDR-Watchdog (Datenlage der Sticks, nur lesen)
  http_get "$BASEURL/api/sdr/wd" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    WL="$(jv lvl)"; WT="$(mask "$(jv short)")"; [[ -n "$WT" ]] || WT="$(mask "$(jv txt)")"
    case "$WL" in
      ok) ok "SDR-Daten-Watchdog" "$WT" ;;
      gelb) warn "SDR-Daten-Watchdog" "$WT" "Betroffenen Stick im Dashboard (/funk) ansehen." ;;
      rot) fail "SDR-Daten-Watchdog" "$WT" "Stick/Empfang pruefen (Dashboard /funk); prepper-sdr-Journal lesen." ;;
      *) info "SDR-Daten-Watchdog" "${WT:-keine Bewertung} (Stufe ${WL:-?})" ;;
    esac
    WD_ALL_LVL="$WL"
    NS="$(jv sticks.#)"
    if [[ "$NS" =~ ^[0-9]+$ ]]; then
      for ((i = 0; i < NS && i < 6; i++)); do
        SL="$(jv "sticks.$i.lvl")"; STX="$(mask "$(jv "sticks.$i.txt")")"
        # Benennung nach der Rolle im Watchdog-Text (nicht nach Listenplatz): Airspy 11D, Stick 1 5C, Stick 2 Hobby, Stick 3 Hobby2
        case "$STX" in
          *[Aa]irspy*|*11D*) RNAME="Airspy 11D"; WD_AIRSPY_LVL="${SL:-?}" ;;
          *"Stick 1"*|*5C*) RNAME="Stick 1 5C" ;;
          *"Stick 2"*) RNAME="Stick 2 Hobby" ;;
          *"Stick 3"*) RNAME="Stick 3 Hobby2" ;;
          *) RNAME="Eintrag $((i + 1))" ;;
        esac
        case "$SL" in gelb) warn "SDR $RNAME (Watchdog)" "$STX" "Stick im Dashboard ansehen." ;; rot) fail "SDR $RNAME (Watchdog)" "$STX" "Stick/Empfang pruefen." ;; *) info "SDR $RNAME (Watchdog)" "$STX" ;; esac
      done
    fi
  else skip "SDR-Daten-Watchdog" "/api/sdr/wd lieferte HTTP $HTTP_CODE"; fi
fi

# ================================================================ 5) Patch-Stand
section "Patch-Stand (Soll: AUDIT-STAND.md, nach commit47)"
DASHF="$APP/dashboard.py"
if [[ -r "$DASHF" ]]; then
  DSH="$(sha16_of "$DASHF")"
  if [[ "$DSH" == "$DASH_SHA16" ]]; then ok "dashboard.py sha16" "$DSH = Soll (Pi-Stand nach commit47), $(wc -l < "$DASHF") Zeilen"
  else warn "dashboard.py sha16" "$DSH, Soll $DASH_SHA16 (nach commit47)" "Neuer Patch seit commit47 oder Abweichung? Dann Soll im Skript (FC_DASH_SHA16) nachziehen; sonst Stand gegen AUDIT-STAND.md pruefen."; fi
  MKBAD=""; MKSUM=""
  for m in "${MARKERS[@]}"; do
    c="$(grep -c "# ===== $m:" "$DASHF" 2>/dev/null)"; [[ "$c" =~ ^[0-9]+$ ]] || c="?"
    MKSUM+=" $m=$c"; [[ "$c" == 1 ]] || MKBAD+=" $m=$c"
  done
  if [[ -z "$MKBAD" ]]; then ok "Patch-Marker in dashboard.py" "alle ${#MARKERS[@]} Marker genau 1x:$MKSUM"
  else fail "Patch-Marker in dashboard.py" "nicht genau 1x:$MKBAD (0 = Patch fehlt, 2 oder mehr = doppelt angewendet)" "Patch-Stand mit AUDIT-STAND.md vergleichen; nichts von Hand aendern, Patch-Reihenfolge pruefen."; fi
else fail "dashboard.py" "$DASHF nicht lesbar" "Pfad/Rechte pruefen."; fi
# NINA: gepinnte Zwischenstelle (ninaFix) - nur Datei lesen, DER-sha256 vergleichen (oeffentliches Zertifikat, kein Schluessel)
PEMF="$APP/$NINA_PEM_REL"
if [[ -r "$PEMF" ]]; then
  if have "$PYBIN"; then
    PEMR="$(timeout 10 "$PYBIN" - "$PEMF" 2>/dev/null <<'PYPEM'
import sys, re, ssl, hashlib
try:
    t = open(sys.argv[1], "r", errors="replace").read(200000)
    if "PRIVATE KEY" in t:
        print("private"); sys.exit(0)
    m = re.search(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", t, re.S)
    if not m:
        print("kein_zertifikat"); sys.exit(0)
    print("sha=" + hashlib.sha256(ssl.PEM_cert_to_DER_cert(m.group(0))).hexdigest())
except Exception:
    print("fehler")
PYPEM
)"
    case "$PEMR" in
      sha=*)
        PEMH="${PEMR#sha=}"
        if [[ "${PEMH:0:${#NINA_PEM_DER16}}" == "$NINA_PEM_DER16" ]]; then ok "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL vorhanden, DER-sha256 beginnt mit $NINA_PEM_DER16 (Sectigo E36, wie gepinnt)"
        else warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL vorhanden, DER-sha256 beginnt mit ${PEMH:0:8} statt $NINA_PEM_DER16" "Das Dashboard prueft den Pin selbst; Datei nicht von Hand aendern, Patch ninaFix pruefen."; fi ;;
      private) fail "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL enthaelt einen privaten Schluessel (darf nicht sein; Inhalt wird nicht angezeigt)" "Datei pruefen und durch die oeffentliche Zwischenstelle ersetzen (Patch ninaFix)." ;;
      kein_zertifikat) warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL enthaelt kein Zertifikat im PEM-Format" "Patch ninaFix erneut pruefen (nur lesen)." ;;
      *) warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL nicht auswertbar" "Datei nur ansehen; Dashboard-Journal grep ninaFix." ;;
    esac
  else info "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL vorhanden (python3 fehlt, Pruefsumme nicht berechnet)"; fi
  PEMM="$(file_mode "$PEMF")"
  [[ "$PEMM" =~ ^[0-7]{3,4}$ ]] && (( 8#$PEMM & 8#022 )) && warn "NINA Zwischenstelle Rechte" "$NINA_PEM_REL ist fuer Gruppe/andere schreibbar (Rechte $PEMM)" "chmod go-w (nur Rechte); die Datei ist die Vertrauensbasis fuer den Rueckfall."
else
  case "$NINA_MODE" in
    normal) warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL fehlt - Rueckfall nicht moeglich (NINA laeuft gerade ohne Rueckfall)" "ninaFix (commit36) erneut anwenden, falls warnung.bund.de die Kette wieder unvollstaendig sendet." ;;
    *) fail "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL fehlt oder nicht lesbar - Rueckfall nicht moeglich" "ninaFix (commit36) erneut anwenden (Datei certs/sectigo-e36.pem)." ;;
  esac
fi
# weitere Dateien: nur Anzeige (Sollwerte der Stand-Datei gelten nicht als bestaetigt)
SAME=0; DIFF=""; MISS=""
for ref in "${REFS[@]}"; do
  rf="${ref%%:*}"; rs="${ref##*:}"
  if [[ ! -f "$APP/$rf" ]]; then MISS+=" $rf"; continue; fi
  h="$(sha16_of "$APP/$rf")"
  if [[ "${h:0:${#rs}}" == "$rs" ]]; then SAME=$((SAME + 1)); else DIFF+=" $rf=$h"; fi
done
info "weitere Dateien (nur Anzeige)" "$SAME von ${#REFS[@]} gleich der Referenz der Stand-Datei (Sollwerte dort unbestaetigt)${DIFF:+; abweichend:$DIFF}${MISS:+; fehlt:$MISS}"
for rf in prepper_sdr.py sdr_manager.py sdr_config.json; do [[ -f "$APP/$rf" ]] && info "sha16 $rf" "$(sha16_of "$APP/$rf")"; done

# ================================================================ 6) Mesh
section "Mesh (Bridges nur lesen)"
check_bridge() { # port name
  local port="$1" nm="$2"
  http_get "http://$HOSTN:$port/health" 5
  if [[ "$HTTP_CODE" != 200 ]]; then fail "Bridge $nm /health" "Port $port: HTTP $HTTP_CODE (curl rc $HTTP_RC)" "Dienst $nm pruefen: systemctl status; Dashboard sendet solange nichts (Meldungen werden nicht gesendet)."; return; fi
  if ! jloads "$HTTP_BODY"; then warn "Bridge $nm /health" "Antwort ist kein JSON" "Bridge-Journal lesen."; return; fi
  local conn sf so q held hl le qa qr
  conn="$(jv connected)"; sf="$(jv sent_fail)"; so="$(jv sent_ok)"; q="$(jv queued)"; held="$(jv held)"; hl="$(jv hold_left)"; le="$(jv last_error)"; qa="$(jv q_alarm)"; qr="$(jv q_routine)"
  if [[ "$conn" == true ]]; then ok "Bridge $nm: verbunden" "connected=true, gesendet ok=${so:-?} fail=${sf:-?}"
  else fail "Bridge $nm: verbunden" "connected=${conn:-?}${le:+, letzter Fehler: $(mask "${le:0:100}")}" "Funkgeraet/Verbindung der Bridge pruefen (Journal $nm); bis dahin gehen keine Mesh-Meldungen raus."; fi
  if [[ "$sf" =~ ^[0-9]+$ && "$so" =~ ^[0-9]+$ ]]; then
    if (( sf > 0 && sf * 5 > so + sf )); then warn "Bridge $nm: Sendefehler" "sent_fail=$sf bei sent_ok=$so (ueber 20 % Fehler)" "Mesh-Verbindung und Kanal-Auslastung pruefen."
    else ok "Bridge $nm: Sendefehler" "sent_fail=$sf bei sent_ok=$so"; fi
  fi
  if [[ "$q" =~ ^[0-9]+$ ]]; then
    if (( q > 20 )); then fail "Bridge $nm: Warteschlange" "queued=$q (alarm ${qa:-0}, routine ${qr:-0})" "Bridge steckt: Verbindung pruefen."
    elif (( q > 5 )); then warn "Bridge $nm: Warteschlange" "queued=$q (alarm ${qa:-0}, routine ${qr:-0})" "Beobachten; bei Dauer Bridge pruefen."
    else ok "Bridge $nm: Warteschlange" "queued=$q (alarm ${qa:-0}, routine ${qr:-0})"; fi
  fi
  if [[ "$held" == true ]]; then warn "Bridge $nm: Sendesperre" "gehalten (held=true, noch ${hl:-?} s)" "Gewollte Sendepause? Sonst im Dashboard fortsetzen (Pause nicht durch dieses Skript)."
  else ok "Bridge $nm: Sendesperre" "keine (held=false)"; fi
}
check_bridge "$BR1_PORT" "mesh-bridge"
check_bridge "$BR2_PORT" "mesh-bridge-bayern"

# Wetter-Auto-Stempel (Slot-Stunden 0,3,...,21)
WXF="$APP/mesh_weather_status.json"
if [[ -r "$WXF" ]]; then
  if jload flat < "$WXF"; then
    AUTO="$(jv auto)"
    if [[ "$AUTO" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})\ ([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
      AEP="$(date -d "${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null)"
      if [[ "$AEP" =~ ^[0-9]+$ ]]; then
        AA=$((EPOCHSECONDS - AEP))
        if (( AA < 0 )); then warn "Mesh Wetter-Auto-Stempel" "Stempel $AUTO liegt in der Zukunft" "Systemuhr pruefen."
        elif (( AA > SLOT_MAX_S * 2 )); then fail "Mesh Wetter-Auto-Stempel" "letzter Auto-Versand $AUTO, vor $(dur "$AA") (erwartet hoechstens 3 h 10 min, mehrere Slots verpasst)" "/mesh-Verlauf und Journal (grep wxSlot, meshBootQuiet) lesen; Bridge-Zustand pruefen."
        elif (( AA > SLOT_MAX_S )); then warn "Mesh Wetter-Auto-Stempel" "letzter Auto-Versand $AUTO, vor $(dur "$AA") (erwartet hoechstens 3 h 10 min)" "Slot verpasst? wxSlot holt innerhalb der Slot-Stunde nach; /mesh-Verlauf lesen."
        else ok "Mesh Wetter-Auto-Stempel" "letzter Auto-Versand $AUTO, vor $(dur "$AA") (Grenze 3 h 10 min)"; fi
      else warn "Mesh Wetter-Auto-Stempel" "Stempel nicht auswertbar" "mesh_weather_status.json ansehen (nur lesen)."; fi
    else warn "Mesh Wetter-Auto-Stempel" "kein gueltiger auto-Stempel in der Datei" "mesh_weather_status.json ansehen (nur lesen)."; fi
  else warn "Mesh Wetter-Auto-Stempel" "mesh_weather_status.json ist kein gueltiges JSON" "Datei nur lesen/ansehen; Dashboard schreibt sie beim naechsten Versand neu."; fi
else warn "Mesh Wetter-Auto-Stempel" "mesh_weather_status.json fehlt" "Wird beim ersten Auto-Versand angelegt."; fi
OUTF="$APP/outage_mesh_state.json"
if [[ -r "$OUTF" ]]; then
  OAGE="$(file_age "$OUTF")"
  if jload flat < "$OUTF"; then
    ok "Stromausfall-Stand (Datei)" "outage_mesh_state.json vorhanden, geschrieben vor $(dur "${OAGE:-0}"), $(jv ids.#) bekannte Meldung(en)"
  else fail "Stromausfall-Stand (Datei)" "outage_mesh_state.json ist kein gueltiges JSON" "Datei nur ansehen; wxSlot ignoriert sie dann und beginnt neu (keine Sendung)."; fi
else warn "Stromausfall-Stand (Datei)" "outage_mesh_state.json fehlt" "Wird nach der ersten Beobachtung (wxSlot, commit34) angelegt."; fi

# ================================================================ 7) SDR
section "SDR (nur lesen, keine Sticks geoeffnet)"
declare -A USBSN=() USBID=() USBID_SN=()
# 2.0.2: Airspy meldet im sysfs "AIRSPY SN:637862DC2E8092D7" - Praefix bis "SN:" abschneiden, verglichen wird nur die Hex-Nummer
SN_RE='^[A-Z0-9_ .-]*SN:[[:space:]]*([0-9A-F]+)[[:space:]]*$'
for d in "$SYS"/bus/usb/devices/*; do
  [[ -d "$d" ]] || continue
  sn=""; [[ -r "$d/serial" ]] && { read -r sn < "$d/serial" 2>/dev/null || sn=""; }
  sn="${sn^^}"; [[ "$sn" =~ $SN_RE ]] && sn="${BASH_REMATCH[1]}"
  pr=""; [[ -r "$d/product" ]] && read -r pr < "$d/product" 2>/dev/null
  [[ -n "$sn" ]] && USBSN["${sn^^}"]="${pr:-?}"
  vid=""; pid=""
  [[ -r "$d/idVendor" ]] && read -r vid < "$d/idVendor" 2>/dev/null
  [[ -r "$d/idProduct" ]] && read -r pid < "$d/idProduct" 2>/dev/null
  if [[ -n "$vid" && -n "$pid" ]]; then USBID["${vid,,}:${pid,,}"]=$(( ${USBID["${vid,,}:${pid,,}"]:-0} + 1 )); USBID_SN["${vid,,}:${pid,,}"]="${sn^^}"; fi
done
# zusaetzlich lsusb (ohne Optionen = nur die Geraeteliste aus sysfs, oeffnet kein Geraet): "Bus 001 Device 003: ID 1d50:60a1 ..."
LSUSB_SEEN=0
if have lsusb; then
  LSU="$(timeout 10 lsusb 2>/dev/null)"
  while read -r _ _ _ _ _ lid _; do
    [[ "$lid" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || continue
    LSUSB_SEEN=$((LSUSB_SEEN + 1))
    [[ -n "${USBID[${lid,,}]:-}" ]] || USBID["${lid,,}"]=1
  done <<<"$LSU"
fi
sdr_dev() { # serial name severity-if-missing
  local sn="${1^^}"
  if [[ -n "${USBSN[$sn]:-}" ]]; then ok "$2 (SN $1)" "am USB-Bus gefunden: ${USBSN[$sn]:0:40}"
  else _emit "$3" "$2 (SN $1)" "nicht am USB-Bus gefunden" "Stick/USB-Kabel/Hub pruefen (lsusb); SDR-Zugriff nur ueber prepper-sdr."; fi
}
# Airspy R2: Erkennung ueber VID:PID 1d50:60a1 (Existenz = OK, auch ohne Seriennummer im sysfs); Seriennummer nur lesend aus sysfs verglichen
airspy_check() {
  local nm="Airspy R2 (11D fest)" got="${USBID_SN[$AIRSPY_VIDPID]:-}" exp="${AIRSPY_SN^^}" src="sysfs"
  [[ -n "${USBID[$AIRSPY_VIDPID]:-}" ]] || src=""
  if [[ -n "$src" ]]; then
    if [[ -n "${USBSN[$exp]:-}" ]]; then ok "$nm (SN $AIRSPY_SN)" "am USB-Bus gefunden (VID:PID $AIRSPY_VIDPID), Seriennummer passt"
    elif [[ -n "$got" ]]; then warn "$nm (SN $AIRSPY_SN)" "VID:PID $AIRSPY_VIDPID gefunden, aber Seriennummer weicht ab (gelesen: ${got:0:24}, erwartet: $AIRSPY_SN)" "Anderer Airspy angesteckt oder getauscht? Nur Anzeige - Empfang laeuft laut Watchdog separat (Dashboard /funk)."
    else ok "$nm (SN $AIRSPY_SN)" "am USB-Bus gefunden (VID:PID $AIRSPY_VIDPID); Seriennummer im sysfs nicht lesbar - nur die Existenz geprueft"; fi
    return
  fi
  if [[ -n "${USBSN[$exp]:-}" ]]; then ok "$nm (SN $AIRSPY_SN)" "ueber die Seriennummer am USB-Bus gefunden: ${USBSN[$exp]:0:40}"; return; fi
  if [[ "$WD_AIRSPY_LVL" == ok || ( -z "$WD_AIRSPY_LVL" && "$WD_ALL_LVL" == ok ) ]]; then
    warn "$nm (SN $AIRSPY_SN)" "Widerspruch: weder VID:PID $AIRSPY_VIDPID noch Seriennummer am USB-Bus gefunden, aber der Daten-Watchdog meldet Empfang ok" "lsusb als Benutzer fmg lesen (nur Anzeige); Skript/Rechte pruefen, Empfang laeuft offenbar."
  else
    fail "$nm (SN $AIRSPY_SN)" "nicht am USB-Bus gefunden (VID:PID $AIRSPY_VIDPID) und der Daten-Watchdog meldet keinen Empfang (${WD_AIRSPY_LVL:-${WD_ALL_LVL:-keine Angabe}})" "Airspy/USB-Kabel/Hub pruefen (lsusb); SDR-Zugriff nur ueber prepper-sdr."
  fi
}
if (( ${#USBSN[@]} > 0 || ${#USBID[@]} > 0 )); then
  airspy_check
  sdr_dev "$STICK1_SN" "Stick 1 (5C/10C)" fail
  sdr_dev "$STICK2_SN" "Stick 2 (hobby)" warn
  sdr_dev "$STICK3_SN" "Stick 3 (hobby2)" warn
else skip "SDR-Sticks am USB-Bus" "keine USB-Geraeteliste lesbar ($SYS/bus/usb/devices, lsusb)"; fi
AGF="$APP/sdr_autogain.json"
if [[ -r "$AGF" ]] && jload flat < "$AGF"; then
  CUR="$(jv cur)"; AMODE="$(jv mode)"; LK="$(jv lock.kind)"; FLT="$(jv fault)"
  if [[ "$CUR" == 16 ]]; then ok "Airspy Gain-Stufe" "Stufe 16 (autoGain-Modus ${AMODE:-?})"
  elif [[ -z "$CUR" || "$CUR" == null ]]; then info "Airspy Gain-Stufe" "noch keine Stufe gemerkt (autoGain-Modus ${AMODE:-?})"
  elif [[ "$AMODE" == auto ]]; then info "Airspy Gain-Stufe" "Stufe $CUR (autoGain hat gewechselt; nur die Automatik darf aendern)"
  else warn "Airspy Gain-Stufe" "Stufe $CUR statt 16 im festen Modus (${AMODE:-?})" "Nur autoGain darf die Stufe aendern: Ursache im Dashboard (/funk, Gain) ansehen."; fi
  [[ "$FLT" == true ]] && warn "autoGain Zustand" "autoGain meldet Fehler (fault=true, Sperre $(mask "${LK:-?}"))" "Dashboard /funk: Gain-Anzeige lesen; Rueckfall ist Stufe 16."
elif [[ -f "$AGF" ]]; then warn "Airspy Gain-Stufe" "sdr_autogain.json nicht lesbar/kein JSON" "Datei nur ansehen; Rueckfall ist Stufe 16."
else info "Airspy Gain-Stufe" "keine sdr_autogain.json (Stufe 16 gilt)"; fi
SSA="$(file_age "$APP/sdr_status.json")" && info "prepper-sdr Statusdatei" "sdr_status.json zuletzt geschrieben vor $(dur "$SSA")" || info "prepper-sdr Statusdatei" "sdr_status.json nicht vorhanden"

# ================================================================ 8) Datenbank
section "Datenbank (nur lesend)"
DBF="$APP/lagezentrum.db"
if [[ -r "$DBF" ]]; then
  DBSZ="$(stat -c %s -- "$DBF" 2>/dev/null)"; WALSZ="$(stat -c %s -- "$DBF-wal" 2>/dev/null || echo 0)"
  [[ "$DBSZ" =~ ^[0-9]+$ ]] || DBSZ=0; [[ "$WALSZ" =~ ^[0-9]+$ ]] || WALSZ=0
  if [[ -e "$DBF-wal" ]]; then
    if (( WALSZ > 268435456 )); then warn "DB: WAL-Datei" "WAL $(mbf "$WALSZ") MB (ueber 256 MB, Checkpoint haengt?)" "Dashboard-Wartung (relDb) pruefen; WAL nicht von Hand loeschen."
    else ok "DB: WAL-Datei" "WAL vorhanden, $(mbf "$WALSZ") MB"; fi
  else info "DB: WAL-Datei" "keine -wal-Datei (Datenbank gerade ohne offene Schreibvorgaenge oder nicht im WAL-Mode)"; fi
  info "DB: Groesse" "lagezentrum.db $(mbf "$DBSZ") MB"
  # journal_mode direkt aus dem Dateikopf (Byte 18/19 = 2: WAL) - ohne SQLite zu oeffnen
  HDR="$(od -An -tu1 -j0 -N20 -- "$DBF" 2>/dev/null)"; read -r -a HB <<<"${HDR//$'\n'/ }"
  if (( ${#HB[@]} >= 20 )) && [[ "${HB[0]}" == 83 && "${HB[1]}" == 81 && "${HB[2]}" == 76 ]]; then
    if [[ "${HB[18]}" == 2 && "${HB[19]}" == 2 ]]; then ok "DB: journal_mode" "WAL (Dateikopf)"
    else warn "DB: journal_mode" "kein WAL-Mode (Dateikopf ${HB[18]}/${HB[19]})" "Datenbank-Wartung (relDb) pruefen."; fi
  else fail "DB: Dateikopf" "kein gueltiger SQLite-Kopf (Datei beschaedigt oder keine Datenbank)" "Sofort Backup sichern (Dashboard /pi, Sicherung), dann pruefen; nichts loeschen."; fi
  # quick_check nur lesend (mode=ro), nur bei kleiner Datenbank, mit Zeitlimit; sonst gilt der Cache der DB-Wartung
  # nur wenn das Dashboard die Datenbank geoeffnet hat (WAL-Index -shm vorhanden): so legt der lesende Zugriff keine neue Datei an
  DOQC=0; (( ! QUICK && DBSZ <= QC_MAX_MB * 1048576 )) && [[ -e "$DBF-shm" ]] && DOQC=1
  if (( DOQC )); then
    if have "$PYBIN"; then
      DBR="$(timeout 40 "$PYBIN" - "$DBF" 2>&1 <<'PYDB'
import sqlite3, sys, os, time
from urllib.parse import quote
p = sys.argv[1]
try:
    con = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(p)), uri=True, timeout=2)
    con.execute("PRAGMA query_only=1")
    t0 = time.time()
    con.set_progress_handler(lambda: 1 if time.time() - t0 > 25 else 0, 20000)
    try:
        rows = [str(r[0]) for r in con.execute("PRAGMA quick_check").fetchall()]
        print("qc=" + ("ok" if rows == ["ok"] else "BEFUND " + "; ".join(rows[:2])[:100]))
    except sqlite3.OperationalError as e:
        print("qc=abgebrochen " + str(e)[:60])
    except sqlite3.DatabaseError as e:
        print("qc=BEFUND " + str(e)[:80])
    print("qcms=%d" % int((time.time() - t0) * 1000))
    con.close()
except sqlite3.DatabaseError as e:
    print("qc=BEFUND " + str(e)[:80])
except Exception as e:
    print("err=" + str(e)[:100])
PYDB
)"
      DQC=""; DQMS=""; DERR=""
      while IFS= read -r line; do
        case "$line" in qc=*) DQC="${line#qc=}" ;; qcms=*) DQMS="${line#qcms=}" ;; err=*) DERR="${line#err=}" ;; esac
      done <<<"$DBR"
      if [[ -n "$DERR" ]]; then warn "DB: quick_check (live, mode=ro)" "SQLite-Fehler: $(mask "$DERR")" "Datenbank-Datei/Rechte pruefen; Dashboard nicht neu starten, erst Backup sichern."
      else
        case "$DQC" in
          ok) ok "DB: quick_check (live, mode=ro)" "ok in ${DQMS:-?} ms" ;;
          BEFUND*) fail "DB: quick_check (live, mode=ro)" "$(mask "$DQC")" "Sofort Backup sichern (Dashboard /pi, Sicherung), dann Ursache pruefen; nichts loeschen." ;;
          *) warn "DB: quick_check (live, mode=ro)" "${DQC:-keine Antwort}" "Datenbank unter Last: spaeter erneut pruefen (Zeitlimit 25 s)." ;;
        esac
      fi
    else skip "DB: quick_check (live)" "python3 fehlt"; fi
  elif (( QUICK )); then skip "DB: quick_check (live)" "mit --kurz uebersprungen"
  elif [[ ! -e "$DBF-shm" ]]; then info "DB: quick_check (live)" "nicht gelaufen: Datenbank gerade nicht vom Dashboard geoeffnet (kein WAL-Index) - so wird nichts angelegt; es gilt der Cache der DB-Wartung"
  else info "DB: quick_check (live)" "nicht gelaufen: Datenbank ueber $QC_MAX_MB MB (Zeit- und I/O-Schutz) - es gilt der Cache der DB-Wartung"; fi
  # Cache der DB-Wartung (quick_check von relDb)
  if [[ -r "$DBF.maint.json" ]] && jload flat < "$DBF.maint.json"; then
    QOK="$(jv qc.ok)"; QT="$(jv qc.t)"; QT="${QT%%.*}"
    if [[ "$QOK" == false ]]; then fail "DB: Wartungs-quick_check (Cache)" "Befund: $(mask "$(jv qc.rows.0)")" "Sofort Backup sichern, dann Datenbank pruefen."
    elif [[ "$QOK" == true && "$QT" =~ ^[0-9]+$ ]]; then
      QA=$((EPOCHSECONDS - QT))
      if (( QA > 8 * 86400 )); then warn "DB: Wartungs-quick_check (Cache)" "ok, aber vor $(dur "$QA") (erwartet woechentlich)" "Wartungsfaden (relDb) im Dashboard-Journal pruefen."
      else ok "DB: Wartungs-quick_check (Cache)" "ok, vor $(dur "$QA")"; fi
    else info "DB: Wartungs-quick_check (Cache)" "noch kein Ergebnis (laeuft woechentlich im Hintergrund)"; fi
  else info "DB: Wartungs-quick_check (Cache)" "lagezentrum.db.maint.json noch nicht vorhanden"; fi
else fail "Datenbank" "$DBF nicht lesbar" "Pfad/Rechte pruefen."; fi

# ================================================================ 9) Backups
section "Backups"
if [[ -d "$BACKUPS" ]]; then
  NB=0; NEWF=""; NEWM=0
  for f in "$BACKUPS"/prepper-*.tgz; do
    [[ -f "$f" ]] || continue
    NB=$((NB + 1)); m="$(stat -c %Y -- "$f" 2>/dev/null)"; [[ "$m" =~ ^[0-9]+$ ]] || continue
    if (( m > NEWM )); then NEWM=$m; NEWF="$f"; fi
  done
  if (( NB == 0 )); then fail "Backups" "keine Sicherung in $BACKUPS" "Im Dashboard /pi eine Sicherung anlegen (Kachel Sicherung) oder tools/backup.sh M pruefen."
  else
    BAGE=$((EPOCHSECONDS - NEWM)); BSZ="$(stat -c %s -- "$NEWF" 2>/dev/null)"
    DET="$NB Sicherung(en), neueste $(basename "$NEWF") ($(mbf "${BSZ:-0}") MB), vor $(dur "$BAGE")"
    if (( BAGE > 10 * 86400 )); then fail "Backup: Alter" "$DET (aelter als 10 Tage)" "Neue Sicherung anlegen (Dashboard /pi, Kachel Sicherung)."
    elif (( BAGE > 3 * 86400 )); then warn "Backup: Alter" "$DET (aelter als 3 Tage)" "Neue Sicherung anlegen oder Zeitplan pruefen."
    else ok "Backup: Alter" "$DET"; fi
    MJ="${NEWF%.tgz}.json"
    if [[ -r "$MJ" ]] && jload flat < "$MJ"; then
      BOK="$(jv ok)"; BSHA="$(jv sha256)"
      [[ "$BOK" == true ]] && ok "Backup: Protokoll (.json)" "ok=true, ${BSHA:+sha256 vorhanden, }Mitglieder $(jv members), DB-Pruefung: $(mask "$(jv db.0.quick_check)")" || fail "Backup: Protokoll (.json)" "ok=${BOK:-?}, Fehler: $(mask "$(jv err)")" "Sicherung wiederholen; Ursache in backup.sh-Meldung."
      if (( ! QUICK )) && [[ -n "$BSHA" && "$BSHA" != null && ${BSZ:-0} -le 524288000 ]]; then
        CS="$(timeout 60 sha256sum -- "$NEWF" 2>/dev/null)"; CS="${CS%% *}"
        if [[ -z "$CS" ]]; then warn "Backup: Pruefsumme" "nicht berechenbar (Zeitlimit/Lesefehler)" "Spaeter erneut pruefen."
        elif [[ "$CS" == "$BSHA" ]]; then ok "Backup: Pruefsumme" "sha256 stimmt mit dem Protokoll ueberein"
        else fail "Backup: Pruefsumme" "sha256 der Datei weicht vom Protokoll ab (Archiv veraendert/defekt)" "Neue Sicherung anlegen; dieses Archiv nicht fuer Restore nutzen."; fi
      elif (( QUICK )); then skip "Backup: Pruefsumme" "mit --kurz uebersprungen"; fi
    else warn "Backup: Protokoll (.json)" "kein lesbares Protokoll zur neuesten Sicherung" "Sicherung mit tools/backup.sh pruefen; Archiv ggf. mit tar -tzf lesen."; fi
    BM="$(file_mode "$NEWF")"; [[ "$BM" == 600 ]] && ok "Backup: Rechte" "Archiv 600" || warn "Backup: Rechte" "Archiv hat Rechte ${BM:-?} (erwartet 600; enthaelt Konfiguration)" "chmod 600 auf das Archiv (nur Rechte)."
  fi
  BDM="$(file_mode "$BACKUPS")"; [[ "$BDM" == 700 ]] || warn "Backup: Ordnerrechte" "$BACKUPS hat Rechte ${BDM:-?} (erwartet 700)" "chmod 700 (nur Rechte)."
else fail "Backups" "Ordner $BACKUPS fehlt" "Sicherung anlegen (Dashboard /pi)."; fi
for tool in backup.sh restore.sh; do
  tf="$APP/tools/$tool"
  if [[ -f "$tf" ]]; then [[ -x "$tf" ]] && ok "Werkzeug tools/$tool" "vorhanden, ausfuehrbar (sha16 $(sha16_of "$tf"))" || warn "Werkzeug tools/$tool" "vorhanden, aber nicht ausfuehrbar" "Dashboard ruft es per bash auf; Rechte nur pruefen."
  else fail "Werkzeug tools/$tool" "fehlt" "relBackup (commit18/18b) erneut anwenden."; fi
done

# ================================================================ 10) Sicherheit (lesend, ohne Inhalte)
section "Sicherheit (nur Rechte und Vorhandensein, nie Inhalte)"
perm_check() { # pfad name erwartet-maximal-Oktal-Maske-Text
  local p="$1" nm="$2" want="$3" m
  [[ -e "$p" ]] || { info "$nm" "nicht vorhanden"; return; }
  m="$(file_mode "$p")"
  if [[ ! "$m" =~ ^[0-7]{3,4}$ ]]; then skip "$nm" "Rechte nicht lesbar"; return; fi
  if (( (8#$m & 8#077) == 0 )); then ok "$nm" "Rechte $m (nur Eigentuemer)"
  elif (( 8#$m & 8#007 )); then warn "$nm" "Rechte $m: fuer ALLE lesbar/zugaenglich (empfohlen $want)" "chmod $want darauf (nur Rechte; kein Schluesseltausch noetig)."
  else warn "$nm" "Rechte $m: Gruppe hat Zugriff (empfohlen $want)" "chmod $want darauf (nur Rechte)."; fi
}
perm_check "$APP/config.py" "Rechte config.py" 600
perm_check "$APP/secrets" "Rechte secrets/ (Ordner)" 700
perm_check "$APP/secrets/keys.env" "Rechte secrets/keys.env" 600
if [[ -n "${PREPPER_KEYS_FILE:-}" ]]; then perm_check "$PREPPER_KEYS_FILE" "Rechte PREPPER_KEYS_FILE" 600; fi
perm_check "${HOME:-/home/fmg}/.ssh" "Rechte ~/.ssh" 700
if [[ -d "$APP" ]]; then
  SECBAD=""; SECN=0
  while IFS= read -r f; do
    SECN=$((SECN + 1)); m="$(file_mode "$f")"
    [[ "$m" =~ ^[0-7]{3,4}$ ]] && (( 8#$m & 8#007 )) && SECBAD+=" ${f#"$APP"/}($m)"
  done < <(timeout 20 find "$APP" -maxdepth 3 \( -path "$APP/venv" -o -path "$APP/.git" -o -path "$APP/archive" \) -prune -o -type f \( -name '*.env' -o \( -name '*.pem' ! -path "$APP/certs/*" \) -o -name '*.key' -o -name '.netrc' -o -name 'id_rsa*' -o -name 'id_ed25519*' \) -print 2>/dev/null)
  if [[ -n "$SECBAD" ]]; then warn "Schluessel-/Env-Dateien im Projekt" "fuer alle lesbar:${SECBAD:0:200}" "chmod 600 (nur Rechte)."
  else ok "Schluessel-/Env-Dateien im Projekt" "$SECN Datei(en) gefunden, keine fuer alle lesbar (certs/ mit oeffentlichen Zertifikaten ausgenommen)"; fi
fi
# defusedxml (XML-Haertung secXml)
for py in "$VENV_PY" "$PYBIN"; do
  have "$py" || [[ -x "$py" ]] || continue
  lab="$([[ "$py" == "$VENV_PY" ]] && echo venv || echo system)"
  if timeout 15 "$py" -c 'import defusedxml' 2>/dev/null; then ok "defusedxml ($lab-Python)" "importierbar"
  elif [[ "$lab" == venv ]]; then fail "defusedxml (venv-Python)" "nicht importierbar im venv (das Dashboard laeuft damit)" "requirements/venv pruefen (secXml, commit31x); kein pip install durch dieses Skript."
  else info "defusedxml (system-Python)" "im System-Python nicht installiert (nur das venv zaehlt)"; fi
done
# offene Ports (nur Anzeige)
if have ss; then
  SSO="$(timeout 5 ss -H -ltn 2>/dev/null)"
  if [[ -n "$SSO" ]]; then
    EXPO=""; LOCP=""; P5000=0; BR_EXPO=""
    while read -r _ _ _ laddr _; do
      port="${laddr##*:}"; addr="${laddr%:*}"
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      case "$addr" in 127.*|"[::1]"|::1) LOCP+=" $port" ;; *) EXPO+=" $port" ;; esac
      [[ "$port" == "$PORT" ]] && P5000=1
      if [[ "$port" == "$BR1_PORT" || "$port" == "$BR2_PORT" ]]; then case "$addr" in 127.*|"[::1]"|::1) ;; *) BR_EXPO+=" $port" ;; esac; fi
    done <<<"$SSO"
    (( P5000 )) && ok "Port $PORT lauscht" "Dashboard hoert auf Port $PORT" || fail "Port $PORT lauscht" "kein Listener auf Port $PORT" "Dienst prepper-dashboard pruefen."
    [[ -z "$BR_EXPO" ]] && ok "Bridge-Ports nur lokal" "Ports $BR1_PORT/$BR2_PORT nicht von aussen erreichbar" || warn "Bridge-Ports nur lokal" "Bridge-Port(s)$BR_EXPO lauschen auf allen Schnittstellen" "Bridge-Konfiguration pruefen (soll 127.0.0.1 sein); keine Firewall-Aenderung durch dieses Skript."
    info "Offene Ports (ss -ltn)" "von aussen erreichbar:${EXPO:- keine}; nur lokal:${LOCP:- keine} - Firewall/rpcbind bewusst offen (SEC-06/08), nur Information"
  else skip "Offene Ports" "ss lieferte nichts"; fi
else skip "Offene Ports" "ss fehlt"; fi

# ================================================================ 11) Journal (letzte 60 Minuten)
section "Journal (letzte 60 min, 4 Dienste)"
if ! have journalctl; then skip "Journal" "journalctl fehlt"
elif ! can_journal && (( ! SUDO_OK )); then skip "Journal der 4 Dienste" "braucht sudo (Benutzer nicht in Gruppe adm/systemd-journal) - Aufruf mit --sudo"
else
  jcmd() { if can_journal; then timeout 25 journalctl "$@"; else priv journalctl "$@"; fi; }
  for u in "${SERVICES[@]}"; do
    ERRS="$(jcmd -u "$u" --since "-60min" -p err --no-pager -q -o cat 2>/dev/null)"; ERC=$?
    ALLJ="$(jcmd -u "$u" --since "-60min" --no-pager -q -o cat 2>/dev/null)"
    if (( ERC > 1 )) && [[ -z "$ALLJ" ]]; then skip "Journal $u" "nicht lesbar (rc $ERC)"; continue; fi
    NERR=0; [[ -n "$ERRS" ]] && NERR="$(pf "$ERRS" | grep -c '')"
    NTB="$(pf "$ALLJ" | grep -c 'Traceback (most recent call last)')"; [[ "$NTB" =~ ^[0-9]+$ ]] || NTB=0
    LASTE="$(pf "$ALLJ" | grep -E '^[A-Za-z_.]*(Error|Exception)\b' | tail -1)"
    if [[ "$u" == prepper-dashboard ]]; then
      NNF="$(pf "$ALLJ" | grep -c '^ninaFix')"; [[ "$NNF" =~ ^[0-9]+$ ]] || NNF=0
      (( NNF > 0 )) && info "Journal ninaFix" "$NNF Meldung(en) in 60 min, zuletzt: $(mask "$(pf "$ALLJ" | grep '^ninaFix' | tail -1 | cut -c1-140)") (Rueckfall-Meldungen sind erwartet)"
    fi
    DET="$NTB Traceback(s), $NERR Zeile(n) mit Prioritaet err in 60 min"
    [[ -n "$LASTE" ]] && DET+=", letzte Ausnahme: $(mask "${LASTE:0:120}")"
    if (( NTB >= 5 || NERR >= 20 )); then fail "Journal $u" "$DET" "journalctl -u $u --since -60min -p err lesen; Ursache beheben."
    elif (( NTB >= 1 || NERR >= 1 )); then warn "Journal $u" "$DET" "journalctl -u $u --since -60min lesen (Einzelfaelle durch Quellen-Ausfaelle moeglich)."
    else ok "Journal $u" "keine Tracebacks, keine err-Zeilen in 60 min"; fi
  done
fi

# ================================================================ 12) Aufraeumen (nur Information)
section "Aufraeumen (nur Information)"
if [[ -d "$APP" ]]; then
  NBAK=0
  for f in "$APP"/*.bak "$APP"/*.bak-* "$APP"/tools/*.bak-*; do [[ -f "$f" ]] && NBAK=$((NBAK + 1)); done
  if (( NBAK > 100 )); then info ".bak-Dateien im Projekt" "$NBAK Stueck (Aufraeumen steht auf der Liste; Patches behalten je 3 eigene)"; else info ".bak-Dateien im Projekt" "$NBAK Stueck"; fi
  if [[ -d "$APP/venv" ]]; then
    NROOT="$(timeout 20 find "$APP/venv" ! -user "$(id -un 2>/dev/null)" 2>/dev/null | wc -l)"
    [[ "$NROOT" =~ ^[0-9]+$ ]] && { (( NROOT > 0 )) && info "venv: fremde Eigentuemer" "$NROOT Datei(en)/Ordner nicht von $(id -un) (root-eigenes ~ip, Aufraeumen braucht sudo; stoert nur pip)" || info "venv: fremde Eigentuemer" "keine"; }
  fi
fi

# ================================================================ Zusammenfassung
ELAPSED=$((SECONDS - T0))
SCORE=$((100 - 2 * N_WARN - 10 * N_FAIL)); (( SCORE < 0 )) && SCORE=0
EXITC=0; (( N_WARN > 0 )) && EXITC=1; (( N_FAIL > 0 )) && EXITC=2
END_STR="$(date '+%d.%m.%Y %H:%M:%S %Z')"

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//[^[:print:]]/ }"
  printf '%s' "$s"
}

if (( JSON )); then
  printf '{"tool":"fullcheck","version":"%s","host":"%s","user":"%s","time":"%s","tz":"Europe/Berlin","duration_s":%d,"mode":{"quick":%s,"sudo":%s},' \
    "$FC_VERSION" "$(json_esc "$(hostname 2>/dev/null || echo '?')")" "$(json_esc "$(id -un 2>/dev/null || echo '?')")" "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$ELAPSED" "$( ((QUICK)) && echo true || echo false)" "$( ((SUDO_OK)) && echo true || echo false)"
  printf '"summary":{"ok":%d,"warn":%d,"fail":%d,"info":%d,"skip":%d,"score":%d,"exit":%d},"checks":[' "$N_OK" "$N_WARN" "$N_FAIL" "$N_INFO" "$N_SKIP" "$SCORE" "$EXITC"
  for i in "${!R_NAME[@]}"; do
    (( i > 0 )) && printf ','
    printf '{"section":"%s","name":"%s","status":"%s","detail":"%s","hint":"%s"}' "$(json_esc "${R_SEC[$i]}")" "$(json_esc "${R_NAME[$i]}")" "${R_ST[$i]}" "$(json_esc "${R_DET[$i]}")" "$(json_esc "${R_HINT[$i]}")"
  done
  printf ']}\n'
else
  echo
  RC_COL="$C_OK"; (( N_WARN > 0 )) && RC_COL="$C_WARN"; (( N_FAIL > 0 )) && RC_COL="$C_FAIL"
  printf '%sErgebnis: %d OK, %d HINWEIS, %d FEHLER%s\n' "$RC_COL" "$N_OK" "$N_WARN" "$N_FAIL" "$C_0"
  printf 'Punkte: %d/100 (100 minus 2 je HINWEIS, 10 je FEHLER) - dazu %d INFO, %d uebersprungen\n' "$SCORE" "$N_INFO" "$N_SKIP"
  printf 'Stand: %s (Europe/Berlin), Laufzeit %d s, Exit-Code %d\n' "$END_STR" "$ELAPSED" "$EXITC"
  if (( N_FAIL > 0 )); then
    echo "FEHLER:"; for i in "${!R_NAME[@]}"; do [[ "${R_ST[$i]}" == fail ]] && printf '  - %s: %s\n' "${R_NAME[$i]}" "${R_DET[$i]}"; done
  fi
  if (( N_WARN > 0 )); then
    echo "HINWEIS:"; for i in "${!R_NAME[@]}"; do [[ "${R_ST[$i]}" == warn ]] && printf '  - %s: %s\n' "${R_NAME[$i]}" "${R_DET[$i]}"; done
  fi
  if (( N_SKIP > 0 && ! SUDO )); then echo "Hinweis: uebersprungene Pruefungen brauchen teils sudo - mit --sudo wiederholen (nur lesend)."; fi
fi
exit "$EXITC"
