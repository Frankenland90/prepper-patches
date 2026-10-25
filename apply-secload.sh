#!/bin/bash
set -eEuo pipefail
# secLoad (commit26): Audit SEC-01 (Code-Seite), SEC-04, SEC-12. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). KEINE Schluessel-Rotation, KEINE neuen Schluessel, KEIN Anbieter-Aufruf,
#  keine Historien-Aenderung. Gibt NIE einen Schluesselwert aus (nur Namen, Laengen, ja/nein, Zaehler).
#  1) neu: secret_util.py (Schluessel optional aus Umgebung oder secrets/keys.env laden, rueckwaertskompatibel; safe_err = Fehlertext ohne Schluessel).
#  2) config.py: am Ende ein kleiner Block (nur Anhaengen, Rechte bleiben). Ohne Umgebungsvariable/Datei bleiben ALLE Werte exakt wie bisher. Fehlt secret_util.py, laeuft config.py unveraendert.
#  3) luft.py: Fehlertexte (FIRMS-Schluessel steht im URL-Pfad) laufen ueber safe_err: kein Schluessel mehr im Fehlerfeld/in API-Antworten (SEC-04).
#  Sicherung (SEC-12): tools/backup.sh bleibt unveraendert (sha16 5053f6b8a43a8638: umask 077, Archiv 600, Ordner 700); config.py und secrets/ bleiben bewusst IM Archiv, damit die Wiederherstellung ohne Handarbeit klappt.
# Basis streng (sha16): luft.py a31e99eb32df4498 (oder secLoad schon drin); config.py: muss gueltiges Python sein (Werte werden nicht geprueft/gezeigt); backup.sh 5053f6b8a43a8638 (nur Pruefung, wird nicht geaendert).
# Neustart: nur prepper-dashboard (laedt luft.py). prepper-sdr, mesh-bridge und Timer werden nicht angefasst. Sicherungen *.bak-secload-ZEIT: letzte 3 je Datei. Keine Datenbank-Aenderung.
# Aufruf: bash /tmp/apply-secload.sh commit26 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
if [[ "${SECLOAD_TEST:-}" == 1 ]]; then DASH_DIR="${SL_DASH:-$DASH_DIR}"; fi   # nur fuer den Sandbox-Test des Apply-Skripts
WN=80; if [[ "${SECLOAD_TEST:-}" == 1 ]]; then WN="${SECLOAD_WAITN:-80}"; fi   # nur Sandbox-Test: kuerzere Wartezeit
LF="$DASH_DIR/luft.py"
CF="$DASH_DIR/config.py"
SU="$DASH_DIR/secret_util.py"
BK="$DASH_DIR/tools/backup.sh"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/secload-apply
KEEP_LAST=3
KNOWN_L16="a31e99eb32df4498"      # luft.py vor secLoad (Basis, Stand Branch-Spitze/Pi, 279 Zeilen)
KNOWN_L16N="0ccae0834ab27f6d"             # luft.py nach secLoad (Ziel)
KNOWN_SU16="ff8e2ac7049f4bde"             # secret_util.py (neu)
KNOWN_BK16="5053f6b8a43a8638"     # tools/backup.sh (nur Pruefung)
PHASE=vorher
ERRLN=""; ERRCMD=""
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
trap 'ec=$?; if [[ $ec -ne 0 && -n "$ERRLN" ]]; then echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE$([[ "$PHASE" == vorher ]] && echo " - es wurde nichts geaendert")"; fi' EXIT
stop() { echo "STOP: $1 - nichts geaendert"; exit 1; }
s16() { sha256sum "$1" | cut -c1-16; }
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CF" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then stop "Dashboard-Port unklar ($PORT)"; fi
if [[ "$PORT" == "8080" ]]; then stop "Port 8080 ist kiwix-serve, nicht das Dashboard"; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== secLoad apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Schluessel optional aus Umgebung/Datei, Fehlertexte ohne Schluessel (SEC-01 Code, SEC-04), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/neu" "$W/alt" "$W/emb"
# ---------- 1) eingebettete Dateien auspacken und pruefen ----------
cat > "$W/emb/secret_util.py.b64" <<'EMB_SU'
IyAtKi0gY29kaW5nOiB1dGYtOCAtKi0KIiIic2VjcmV0X3V0aWwucHkgLSBzZWNMb2FkIChjb21taXQyNik6IFNjaGx1ZXNzZWwt
SGlsZmVuIGZ1ZXIgZGFzIFByZXBwZXItRGFzaGJvYXJkIChMYWdlIFBpKS4KClp3ZWkga2xlaW5lLCB2b25laW5hbmRlciB1bmFi
aGFlbmdpZ2UgRGluZ2UgKEF1ZGl0IFNFQy0wMSBDb2RlLVNlaXRlLCBTRUMtMDQsIFNFQy0xMik6CjEuIFNjaGx1ZXNzZWwgT1BU
SU9OQUwgYXVzIFVtZ2VidW5nIG9kZXIgU2NobHVlc3NlbGRhdGVpIGxhZGVuIChydWVja3dhZXJ0c2tvbXBhdGliZWwpOgogICBS
ZWloZW5mb2xnZSBqZSBTY2hsdWVzc2VsOiBQcm96ZXNzLVVtZ2VidW5nICh6dW0gQmVpc3BpZWwgc3lzdGVtZCBFbnZpcm9ubWVu
dEZpbGUpID4gRGF0ZWkgc2VjcmV0cy9rZXlzLmVudgogICAob2RlciBQUkVQUEVSX0tFWVNfRklMRSkgPiBkZXIgYmlzaGVyaWdl
IFdlcnQgaW4gY29uZmlnLnB5LiBGZWhsdCBiZWlkZXMsIGFlbmRlcnQgc2ljaCBOSUNIVFMuCiAgIERpZSBEYXRlaSB3aXJkIG51
ciBnZWxlc2VuLCB3ZW5uIEdydXBwZS9BbmRlcmUga2VpbmVuIFp1Z3JpZmYgaGFiZW4gKFJlY2h0ZSA2MDApOyBzb25zdCB3aXJk
IHNpZSBpZ25vcmllcnQuCjIuIHNhZmVfZXJyKGUpOiBGZWhsZXJ0ZXh0IG9obmUgU2NobHVlc3NlbCAoYmVrYW5udGUgU2NobHVl
c3NlbHdlcnRlLCBrZXk9L3Rva2VuPS1QYXJhbWV0ZXIsIGxhbmdlIFBmYWRzZWdtZW50ZSBpbiBVUkxzKS4KRGllc2VzIE1vZHVs
IGdpYnQgTklFIFdlcnRlIGF1cyAoa2VpbiBwcmludCwga2VpbiBMb2dnaW5nIHZvbiBXZXJ0ZW4pIHVuZCB3aXJmdCBOSUUgZWlu
ZSBBdXNuYWhtZSBuYWNoIGF1c3Nlbi4KSW1wb3J0aWVydCBjb25maWcgbmljaHQgYmVpbSBJbXBvcnQgKGNvbmZpZy5weSBydWZ0
IGFwcGx5X3RvX25hbWVzcGFjZSgpIHNlbGJzdCBhbSBFbmRlIGF1ZikuIiIiCmltcG9ydCBvcwppbXBvcnQgcmUKaW1wb3J0IHN0
YXQKCktFWV9OQU1FUyA9ICgiQVBJX0tFWV9HSUUiLCAiVEFOS0VSS09FTklHX0FQSV9LRVkiLCAiRklSTVNfTUFQX0tFWSIpCl9N
SU5fU0VDUkVUX0xFTiA9IDgKX1JFX1BBUkFNID0gcmUuY29tcGlsZShyIig/aSkoKD86YXBpW18tXT9rZXl8YXBpa2V5fGtleXx0
b2tlbnxzZWNyZXR8eC1rZXl8cGFzc3dvcmR8cGFzc3dkKT0pW14mXHMnXCI8Pl0rIikKX1JFX1NFRyA9IHJlLmNvbXBpbGUociIo
Pzw9LylbQS1aYS16MC05X1wtXXsyNCx9KD89Wy8/XHMnXCI8Pl18JCkiKQpfTUFTSyA9ICIqKioiCgoKZGVmIGtleXNfZmlsZV9w
YXRoKCk6CiAgICBwID0gb3MuZW52aXJvbi5nZXQoIlBSRVBQRVJfS0VZU19GSUxFIiwgIiIpCiAgICBpZiBwOgogICAgICAgIHJl
dHVybiBwCiAgICByZXR1cm4gb3MucGF0aC5qb2luKG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSwg
InNlY3JldHMiLCAia2V5cy5lbnYiKQoKCmRlZiBfZmlsZV9vayhwYXRoKToKICAgICIiIkRhdGVpIGRhcmYgbnVyIHZvbSBFaWdl
bnR1ZW1lciBsZXNiYXIvc2NocmVpYmJhciBzZWluIChrZWluZSBSZWNodGUgZnVlciBHcnVwcGUvQW5kZXJlKSwgcmVndWxhZXJl
IERhdGVpLCBrZWluIFN5bWxpbmsuIiIiCiAgICB0cnk6CiAgICAgICAgc3QgPSBvcy5sc3RhdChwYXRoKQogICAgZXhjZXB0IE9T
RXJyb3I6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBub3Qgc3RhdC5TX0lTUkVHKHN0LnN0X21vZGUpOgogICAgICAgIHJl
dHVybiBGYWxzZQogICAgaWYgc3Quc3RfbW9kZSAmIDBvMDc3OgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuIFRydWUK
CgpkZWYgX3BhcnNlX2Vudl9maWxlKHBhdGgpOgogICAgb3V0ID0ge30KICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4ocGF0aCwg
InIiLCBlbmNvZGluZz0idXRmLTgiKSBhcyBmOgogICAgICAgICAgICBmb3IgcmF3IGluIGY6CiAgICAgICAgICAgICAgICBsaW5l
ID0gcmF3LnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpIG9yICI9IiBu
b3QgaW4gbGluZToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgaWYgbGluZS5zdGFydHN3aXRo
KCJleHBvcnQgIik6CiAgICAgICAgICAgICAgICAgICAgbGluZSA9IGxpbmVbNzpdLmxzdHJpcCgpCiAgICAgICAgICAgICAgICBr
LCB2ID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAgICAgICAgICBrID0gay5zdHJpcCgpCiAgICAgICAgICAgICAgICB2ID0g
di5zdHJpcCgpCiAgICAgICAgICAgICAgICBpZiBsZW4odikgPj0gMiBhbmQgdlswXSA9PSB2Wy0xXSBhbmQgdlswXSBpbiAiJ1wi
IjoKICAgICAgICAgICAgICAgICAgICB2ID0gdlsxOi0xXQogICAgICAgICAgICAgICAgaWYgayBpbiBLRVlfTkFNRVMgYW5kIHY6
CiAgICAgICAgICAgICAgICAgICAgb3V0W2tdID0gdgogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4ge30KICAg
IHJldHVybiBvdXQKCgpkZWYgbG9hZF9vdmVycmlkZXMoZW52aXJvbj1Ob25lLCBwYXRoPU5vbmUpOgogICAgIiIiTGllZmVydCB7
TkFNRTogV2VydH0gbnVyIGZ1ZXIgU2NobHVlc3NlbCwgZGllIFVtZ2VidW5nIG9kZXIgRGF0ZWkgc2V0emVuLiBMZWVyID0gbmlj
aHRzIHp1IGFlbmRlcm4uIiIiCiAgICBlbnYgPSBvcy5lbnZpcm9uIGlmIGVudmlyb24gaXMgTm9uZSBlbHNlIGVudmlyb24KICAg
IHJlcyA9IHt9CiAgICB0cnk6CiAgICAgICAgcCA9IHBhdGggb3Iga2V5c19maWxlX3BhdGgoKQogICAgICAgIGlmIF9maWxlX29r
KHApOgogICAgICAgICAgICByZXMudXBkYXRlKF9wYXJzZV9lbnZfZmlsZShwKSkKICAgICAgICBmb3IgayBpbiBLRVlfTkFNRVM6
CiAgICAgICAgICAgIHYgPSBlbnYuZ2V0KGssICIiKQogICAgICAgICAgICBpZiB2OgogICAgICAgICAgICAgICAgcmVzW2tdID0g
dgogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4ge30KICAgIHJldHVybiByZXMKCgpkZWYgYXBwbHlfdG9fbmFt
ZXNwYWNlKG5zKToKICAgICIiIlZvbiBjb25maWcucHkgYW0gRW5kZSBhdWZnZXJ1ZmVuOiB1ZWJlcnNjaHJlaWJ0IG51ciBnZXNl
dHp0ZSBTY2hsdWVzc2VsLiBHaWJ0IGRpZSBOQU1FTiBkZXIgdWViZXJzY2hyaWViZW5lbiB6dXJ1ZWNrLiIiIgogICAgY2hhbmdl
ZCA9IFtdCiAgICB0cnk6CiAgICAgICAgZm9yIGssIHYgaW4gbG9hZF9vdmVycmlkZXMoKS5pdGVtcygpOgogICAgICAgICAgICBu
c1trXSA9IHYKICAgICAgICAgICAgY2hhbmdlZC5hcHBlbmQoaykKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJu
IFtdCiAgICByZXR1cm4gY2hhbmdlZAoKCmRlZiBrbm93bl9zZWNyZXRzKCk6CiAgICAiIiJBa3R1ZWxsZSBTY2hsdWVzc2Vsd2Vy
dGUgKGF1cyBjb25maWcsIFVtZ2VidW5nLCBEYXRlaSkgLSBudXIgenVtIEVyc2V0emVuIGluIEZlaGxlcnRleHRlbi4iIiIKICAg
IHZhbHMgPSBzZXQoKQogICAgdHJ5OgogICAgICAgIGltcG9ydCBjb25maWcgYXMgX2MKICAgICAgICBmb3IgayBpbiBLRVlfTkFN
RVM6CiAgICAgICAgICAgIHYgPSBnZXRhdHRyKF9jLCBrLCAiIikKICAgICAgICAgICAgaWYgaXNpbnN0YW5jZSh2LCBzdHIpIGFu
ZCBsZW4odikgPj0gX01JTl9TRUNSRVRfTEVOOgogICAgICAgICAgICAgICAgdmFscy5hZGQodikKICAgIGV4Y2VwdCBFeGNlcHRp
b246CiAgICAgICAgcGFzcwogICAgdHJ5OgogICAgICAgIGZvciB2IGluIGxvYWRfb3ZlcnJpZGVzKCkudmFsdWVzKCk6CiAgICAg
ICAgICAgIGlmIGxlbih2KSA+PSBfTUlOX1NFQ1JFVF9MRU46CiAgICAgICAgICAgICAgICB2YWxzLmFkZCh2KQogICAgZXhjZXB0
IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gdmFscwoKCmRlZiByZWRhY3QodGV4dCwgZXh0cmE9KCkpOgogICAg
IiIiRXJzZXR6dCBiZWthbm50ZSBTY2hsdWVzc2VsLCBrZXk9L3Rva2VuPS1QYXJhbWV0ZXIgdW5kIGxhbmdlIFBmYWRzZWdtZW50
ZSBkdXJjaCAqKiouIiIiCiAgICB0cnk6CiAgICAgICAgcyA9IHRleHQgaWYgaXNpbnN0YW5jZSh0ZXh0LCBzdHIpIGVsc2Ugc3Ry
KHRleHQpCiAgICAgICAgZm9yIHYgaW4gc29ydGVkKHNldChrbm93bl9zZWNyZXRzKCkpIHwgc2V0KHggZm9yIHggaW4gZXh0cmEg
aWYgaXNpbnN0YW5jZSh4LCBzdHIpIGFuZCBsZW4oeCkgPj0gX01JTl9TRUNSRVRfTEVOKSwga2V5PWxlbiwgcmV2ZXJzZT1UcnVl
KToKICAgICAgICAgICAgcyA9IHMucmVwbGFjZSh2LCBfTUFTSykKICAgICAgICBzID0gX1JFX1BBUkFNLnN1YihsYW1iZGEgbTog
bS5ncm91cCgxKSArIF9NQVNLLCBzKQogICAgICAgIGlmICI6Ly8iIGluIHMgb3IgIi8iIGluIHM6CiAgICAgICAgICAgIHMgPSBf
UkVfU0VHLnN1YihfTUFTSywgcykKICAgICAgICByZXR1cm4gcwogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4g
IkZlaGxlciAoVGV4dCBuaWNodCBkYXJzdGVsbGJhcikiCgoKZGVmIHNhZmVfZXJyKGUsIGxpbWl0PU5vbmUpOgogICAgIiIiRmVo
bGVydGV4dCBlaW5lciBBdXNuYWhtZSBvaG5lIFNjaGx1ZXNzZWw7IG9wdGlvbmFsIGF1ZiBsaW1pdCBaZWljaGVuIGdla3Vlcnp0
IChlcnN0IHJlZGlnaWVyZW4sIGRhbm4ga3VlcnplbikuIiIiCiAgICB0cnk6CiAgICAgICAgcyA9IHJlZGFjdChzdHIoZSkpCiAg
ICAgICAgcmV0dXJuIHNbOmxpbWl0XSBpZiBsaW1pdCBlbHNlIHMKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJu
ICJGZWhsZXIiCgoKZGVmIHN0YXR1c19saW5lcygpOgogICAgIiIiTnVyIFp1c3RhbmQsIG5pZSBXZXJ0ZTogZnVlciBqZWRlbiBT
Y2hsdWVzc2VsIFF1ZWxsZSAoVW1nZWJ1bmcvRGF0ZWkvY29uZmlnLnB5L2ZlaGx0KSB1bmQgTGFlbmdlIGluIFplaWNoZW4uIiIi
CiAgICBsaW5lcyA9IFtdCiAgICB0cnk6CiAgICAgICAgcCA9IGtleXNfZmlsZV9wYXRoKCkKICAgICAgICBmb2sgPSBfZmlsZV9v
ayhwKQogICAgICAgIGZ2YWxzID0gX3BhcnNlX2Vudl9maWxlKHApIGlmIGZvayBlbHNlIHt9CiAgICAgICAgZXhpc3RzID0gb3Mu
cGF0aC5sZXhpc3RzKHApCiAgICAgICAgbGluZXMuYXBwZW5kKCJTY2hsdWVzc2VsZGF0ZWkgJXM6ICVzJXMiICUgKHAsICJ2b3Jo
YW5kZW4iIGlmIGV4aXN0cyBlbHNlICJuaWNodCB2b3JoYW5kZW4iLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICgiLCBSZWNodGUgb2sgKG51ciBFaWdlbnR1ZW1lcikiIGlmIGZvayBlbHNlICIsIFdJUkQgSUdOT1JJ
RVJUIChSZWNodGUgbmljaHQgNjAwL1R5cCkiKSBpZiBleGlzdHMgZWxzZSAiIikpCiAgICAgICAgdHJ5OgogICAgICAgICAgICBp
bXBvcnQgY29uZmlnIGFzIF9jCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgX2MgPSBOb25lCiAgICAgICAg
Zm9yIGsgaW4gS0VZX05BTUVTOgogICAgICAgICAgICBldiA9IG9zLmVudmlyb24uZ2V0KGssICIiKQogICAgICAgICAgICBjdiA9
IGdldGF0dHIoX2MsIGssICIiKSBpZiBfYyBpcyBub3QgTm9uZSBlbHNlICIiCiAgICAgICAgICAgIGlmIGV2OgogICAgICAgICAg
ICAgICAgc3JjLCBuID0gIlVtZ2VidW5nIiwgbGVuKGV2KQogICAgICAgICAgICBlbGlmIGsgaW4gZnZhbHM6CiAgICAgICAgICAg
ICAgICBzcmMsIG4gPSAiRGF0ZWkiLCBsZW4oZnZhbHNba10pCiAgICAgICAgICAgIGVsaWYgaXNpbnN0YW5jZShjdiwgc3RyKSBh
bmQgY3Y6CiAgICAgICAgICAgICAgICBzcmMsIG4gPSAiY29uZmlnLnB5IiwgbGVuKGN2KQogICAgICAgICAgICBlbHNlOgogICAg
ICAgICAgICAgICAgc3JjLCBuID0gImZlaGx0IiwgMAogICAgICAgICAgICBsaW5lcy5hcHBlbmQoIiAgJS0yMnMgUXVlbGxlOiAl
LTEwcyBMYWVuZ2U6ICVkIiAlIChrLCBzcmMsIG4pKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBsaW5lcy5hcHBlbmQo
IlN0YXR1cyBuaWNodCBlcm1pdHRlbGJhciIpCiAgICByZXR1cm4gbGluZXMKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgog
ICAgaW1wb3J0IHN5cwogICAgaWYgbGVuKHN5cy5hcmd2KSA+IDEgYW5kIHN5cy5hcmd2WzFdID09ICJzdGF0dXMiOgogICAgICAg
IHByaW50KCJcbiIuam9pbihzdGF0dXNfbGluZXMoKSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KCJBdWZydWY6IHB5dGhvbjMg
c2VjcmV0X3V0aWwucHkgc3RhdHVzICAgKHplaWd0IG51ciBRdWVsbGUgdW5kIExhZW5nZSwgbmllIFdlcnRlKSIpCg==
EMB_SU
cat > "$W/emb/secload_edit.py.b64" <<'EMB_ED'
IyAtKi0gY29kaW5nOiB1dGYtOCAtKi0KIiIic2VjbG9hZF9lZGl0LnB5IC0gQWVuZGVydW5nZW4gc2VjTG9hZCAoY29tbWl0MjYp
OiBsdWZ0LnB5IHVuZCBjb25maWcucHkgKGlkZW1wb3RlbnQsIG1pdCBaYWVobHBydWVmdW5nKS4gR2lidCBuaWUgRGF0ZWlpbmhh
bHRlIGF1cy4iIiIKaW1wb3J0IHJlCmltcG9ydCBzeXMKCk1BUktfTCA9ICIjIHNlY0xvYWQgKGNvbW1pdDI2KSIKTUFSS19DX0JF
R0lOID0gIiMgPT09PT0gc2VjTG9hZCAoY29tbWl0MjYpOiBTY2hsdWVzc2VsIG9wdGlvbmFsIGF1cyBVbWdlYnVuZy9zZWNyZXRz
L2tleXMuZW52LCBzb25zdCB1bnZlcmFlbmRlcnQgPT09PT0iCk1BUktfQ19FTkQgPSAiIyA9PT09PSBFbmRlIHNlY0xvYWQgPT09
PT0iCgpMVUZUX0lNUE9SVCA9ICcnJ2ltcG9ydCByZXF1ZXN0cwoKdHJ5OiAgIyBzZWNMb2FkIChjb21taXQyNik6IEZlaGxlcnRl
eHRlIG9obmUgU2NobHVlc3NlbCAoU0VDLTA0KQogICAgZnJvbSBzZWNyZXRfdXRpbCBpbXBvcnQgc2FmZV9lcnIgYXMgX3NhZmVf
ZXJyCmV4Y2VwdCBFeGNlcHRpb246ICAjIFJ1ZWNrZmFsbCBvaG5lIHNlY3JldF91dGlsOiB3ZW5pZ3N0ZW5zIGtleT0vdG9rZW49
LVBhcmFtZXRlciB1bmQgbGFuZ2UgUGZhZHNlZ21lbnRlIGVudGZlcm5lbgogICAgaW1wb3J0IHJlIGFzIF9yZV9zbAoKICAgIGRl
ZiBfc2FmZV9lcnIoZSwgbGltaXQ9Tm9uZSk6CiAgICAgICAgcyA9IF9yZV9zbC5zdWIociIoP2kpKCg/OmFwaVtfLV0/a2V5fGtl
eXx0b2tlbnxzZWNyZXQpPSlbXiZcXHMnXFwiPD5dKyIsIHIiXFwxKioqIiwgc3RyKGUpKQogICAgICAgIHMgPSBfcmVfc2wuc3Vi
KHIiKD88PS8pW0EtWmEtejAtOV9cXC1dezI0LH0oPz1bLz9cXHMnXFwiPD5dfCQpIiwgIioqKiIsIHMpCiAgICAgICAgcmV0dXJu
IHNbOmxpbWl0XSBpZiBsaW1pdCBlbHNlIHMKJycnCgpDT05GSUdfQkxPQ0sgPSBNQVJLX0NfQkVHSU4gKyAnJycKdHJ5OgogICAg
aW1wb3J0IHNlY3JldF91dGlsIGFzIF9zZWNyZXRfdXRpbAogICAgX3NlY3JldF91dGlsLmFwcGx5X3RvX25hbWVzcGFjZShnbG9i
YWxzKCkpCmV4Y2VwdCBFeGNlcHRpb246CiAgICBwYXNzCicnJyArIE1BUktfQ19FTkQgKyAiXG4iCgoKZGVmIGVkaXRfbHVmdChz
cmMpOgogICAgaWYgTUFSS19MIGluIHNyYzoKICAgICAgICByZXR1cm4gc3JjCiAgICBpZiBzcmMuY291bnQoIlxuaW1wb3J0IHJl
cXVlc3RzXG4iKSAhPSAxOgogICAgICAgIHJhaXNlIFN5c3RlbUV4aXQoImx1ZnQucHk6ICdpbXBvcnQgcmVxdWVzdHMnIG5pY2h0
IGdlbmF1IGVpbm1hbCIpCiAgICBpZiBzcmMuY291bnQoInN0cihlKVs6MTIwXSIpICE9IDI6CiAgICAgICAgcmFpc2UgU3lzdGVt
RXhpdCgibHVmdC5weTogJ3N0cihlKVs6MTIwXScgbmljaHQgZ2VuYXUgendlaW1hbCAoJWQpIiAlIHNyYy5jb3VudCgic3RyKGUp
WzoxMjBdIikpCiAgICBvdXQgPSBzcmMucmVwbGFjZSgiXG5pbXBvcnQgcmVxdWVzdHNcbiIsICJcbiIgKyBMVUZUX0lNUE9SVCwg
MSkKICAgIG91dCA9IG91dC5yZXBsYWNlKCJzdHIoZSlbOjEyMF0iLCAiX3NhZmVfZXJyKGUpWzoxMjBdIikKICAgIHJldHVybiBv
dXQKCgpkZWYgZWRpdF9jb25maWcoc3JjKToKICAgIGlmIE1BUktfQ19CRUdJTiBpbiBzcmM6CiAgICAgICAgaWYgc3JjLmNvdW50
KE1BUktfQ19CRUdJTikgIT0gMSBvciBub3Qgc3JjLnJzdHJpcCgiXG4iKS5lbmRzd2l0aChNQVJLX0NfRU5EKToKICAgICAgICAg
ICAgcmFpc2UgU3lzdGVtRXhpdCgiY29uZmlnLnB5OiBzZWNMb2FkLUJsb2NrIG1laHJmYWNoIG9kZXIgbmljaHQgYW0gRW5kZSIp
CiAgICAgICAgcmV0dXJuIHNyYwogICAgaWYgInNlY0xvYWQiIGluIHNyYzoKICAgICAgICByYWlzZSBTeXN0ZW1FeGl0KCJjb25m
aWcucHk6IHVuZXJ3YXJ0ZXRlIHNlY0xvYWQtTWFya2UiKQogICAgYmFzZSA9IHNyYyBpZiBzcmMuZW5kc3dpdGgoIlxuIikgZWxz
ZSBzcmMgKyAiXG4iCiAgICByZXR1cm4gYmFzZSArICJcbiIgKyBDT05GSUdfQkxPQ0sKCgppZiBfX25hbWVfXyA9PSAiX19tYWlu
X18iOgogICAgd2hhdCwgYSwgYiA9IHN5cy5hcmd2WzE6NF0KICAgIHMgPSBvcGVuKGEsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQo
KQogICAgciA9IHsibHVmdCI6IGVkaXRfbHVmdCwgImNvbmZpZyI6IGVkaXRfY29uZmlnfVt3aGF0XShzKQogICAgb3BlbihiLCAi
dyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRlKHIpCg==
EMB_ED
cat > "$W/emb/sltest.py.b64" <<'EMB_T'
IyAtKi0gY29kaW5nOiB1dGYtOCAtKi0KIiIic2x0ZXN0LnB5IC0gU2VsYnN0dGVzdCB1bmQgV2FjaGUgZnVlciBzZWNMb2FkIChj
b21taXQyNikuIEF1ZnJ1ZjogcHl0aG9uMyBzbHRlc3QucHkgTkVVRElSIEFMVENPTkZJRwpORVVESVIgZW50aGFlbHQgY29uZmln
LnB5IChuZXUpLCBsdWZ0LnB5IChuZXUpLCBzZWNyZXRfdXRpbC5weS4gQUxUQ09ORklHID0gY29uZmlnLnB5IHZvciBkZW0gUGF0
Y2guCkdpYnQgTklFIFNjaGx1ZXNzZWx3ZXJ0ZSBhdXMgKFBydWVmdW5nZW4gdmVyZ2xlaWNoZW4gaW50ZXJuLCBtZWxkZW4gbnVy
IG9rL2ZlaGxlcikuIFRlc3RzY2hsdWVzc2VsIHNpbmQgenVmYWVsbGlnIGVyemV1Z3QuIiIiCmltcG9ydCBhc3QKaW1wb3J0IGhh
c2hsaWIKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCByYW5kb20KaW1wb3J0IHNodXRpbAppbXBvcnQgc3RyaW5nCmltcG9y
dCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRlbXBmaWxlCgpORVUsIEFMVCA9IHN5cy5hcmd2WzFdLCBzeXMuYXJndlsy
XQpvayA9IGZhaWwgPSAwCgoKZGVmIGNoayhuYW1lLCBjb25kLCB3aHk9IiIpOgogICAgZ2xvYmFsIG9rLCBmYWlsCiAgICBpZiBj
b25kOgogICAgICAgIG9rICs9IDEKICAgIGVsc2U6CiAgICAgICAgZmFpbCArPSAxCiAgICAgICAgcHJpbnQoIiAgRkFJTCAlcyAl
cyIgJSAobmFtZSwgd2h5KSkKCgpkZWYgcm5kKG4sIGFscGhhPXN0cmluZy5hc2NpaV9sZXR0ZXJzICsgc3RyaW5nLmRpZ2l0cyk6
CiAgICByZXR1cm4gIiIuam9pbihyYW5kb20uU3lzdGVtUmFuZG9tKCkuY2hvaWNlKGFscGhhKSBmb3IgXyBpbiByYW5nZShuKSkK
CgpkZWYgcnVuKGNvZGUsIGN3ZCwgZW52X2V4dHJhPU5vbmUsIGNsZWFuX2tleXM9VHJ1ZSk6CiAgICBlbnYgPSBkaWN0KG9zLmVu
dmlyb24pCiAgICBmb3IgayBpbiAoIkFQSV9LRVlfR0lFIiwgIlRBTktFUktPRU5JR19BUElfS0VZIiwgIkZJUk1TX01BUF9LRVki
LCAiUFJFUFBFUl9LRVlTX0ZJTEUiKToKICAgICAgICBlbnYucG9wKGssIE5vbmUpCiAgICBlbnYudXBkYXRlKGVudl9leHRyYSBv
ciB7fSkKICAgIGVudlsiUFlUSE9ORE9OVFdSSVRFQllURUNPREUiXSA9ICIxIgogICAgcCA9IHN1YnByb2Nlc3MucnVuKFtzeXMu
ZXhlY3V0YWJsZSwgIi1jIiwgY29kZV0sIGN3ZD1jd2QsIGVudj1lbnYsIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwg
dGltZW91dD02MCkKICAgIHJldHVybiBwLnJldHVybmNvZGUsIHAuc3Rkb3V0LCBwLnN0ZGVycgoKCmRlZiB0cmVlX25hbWVzKHBh
dGgpOgogICAgdCA9IGFzdC5wYXJzZShvcGVuKHBhdGgsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKSkKICAgIHJldHVybiB0CgoK
IyAtLS0tIFdhY2hlIChBU1QpIC0tLS0Kc3JjX2wgPSBvcGVuKG9zLnBhdGguam9pbihORVUsICJsdWZ0LnB5IiksIGVuY29kaW5n
PSJ1dGYtOCIpLnJlYWQoKQpzcmNfYyA9IG9wZW4ob3MucGF0aC5qb2luKE5FVSwgImNvbmZpZy5weSIpLCBlbmNvZGluZz0idXRm
LTgiKS5yZWFkKCkKc3JjX3UgPSBvcGVuKG9zLnBhdGguam9pbihORVUsICJzZWNyZXRfdXRpbC5weSIpLCBlbmNvZGluZz0idXRm
LTgiKS5yZWFkKCkKZm9yIG4sIHMgaW4gKCgibHVmdC5weSIsIHNyY19sKSwgKCJjb25maWcucHkiLCBzcmNfYyksICgic2VjcmV0
X3V0aWwucHkiLCBzcmNfdSkpOgogICAgdHJ5OgogICAgICAgIGFzdC5wYXJzZShzKQogICAgICAgIGNoaygiYXN0ICIgKyBuLCBU
cnVlKQogICAgZXhjZXB0IFN5bnRheEVycm9yIGFzIGU6CiAgICAgICAgY2hrKCJhc3QgIiArIG4sIEZhbHNlLCBzdHIoZSlbOjgw
XSkKY2hrKCJsdWZ0OiBrZWluIHN0cihlKVs6MTIwXSBtZWhyIiwgInN0cihlKVs6MTIwXSIgbm90IGluIHNyY19sKQpjaGsoImx1
ZnQ6IF9zYWZlX2VyciBhbiAyIFN0ZWxsZW4iLCBzcmNfbC5jb3VudCgiX3NhZmVfZXJyKGUpWzoxMjBdIikgPT0gMikKY2hrKCJs
dWZ0OiBnZW5hdSBlaW5lIE1hcmtlIiwgc3JjX2wuY291bnQoIiMgc2VjTG9hZCAoY29tbWl0MjYpIikgPT0gMSkKY2hrKCJjb25m
aWc6IGdlbmF1IGVpbiBCbG9jayBhbSBFbmRlIiwgc3JjX2MuY291bnQoIj09PT09IHNlY0xvYWQgKGNvbW1pdDI2KSIpID09IDEg
YW5kIHNyY19jLnJzdHJpcCgiXG4iKS5lbmRzd2l0aCgiIyA9PT09PSBFbmRlIHNlY0xvYWQgPT09PT0iKSkKY2hrKCJjb25maWc6
IEJsb2NrIG9obmUgcHJpbnQvb3BlbiIsICJwcmludCIgbm90IGluIHNyY19jLnNwbGl0KCI9PT09PSBzZWNMb2FkIChjb21taXQy
NikiKVsxXSBhbmQgIm9wZW4oIiBub3QgaW4gc3JjX2Muc3BsaXQoIj09PT09IHNlY0xvYWQgKGNvbW1pdDI2KSIpWzFdKQpjaGso
InNlY3JldF91dGlsOiBrZWluIHByaW50IGF1c3NlciBpbSBBdWZydWYgcHl0aG9uMyBzZWNyZXRfdXRpbC5weSBzdGF0dXMiLCAi
cHJpbnQoIiBub3QgaW4gc3JjX3Uuc3BsaXQoIlxuaWYgX19uYW1lX18iKVswXSkKY2hrKCJzZWNyZXRfdXRpbDoga2VpbiBpbXBv
cnQgY29uZmlnIGF1ZiBNb2R1bGViZW5lIiwgbm90IGFueShsLnN0YXJ0c3dpdGgoImltcG9ydCBjb25maWciKSBvciBsLnN0YXJ0
c3dpdGgoImZyb20gY29uZmlnIikgZm9yIGwgaW4gc3JjX3Uuc3BsaXQoIlxuIikpKQphbHRfc3JjID0gb3BlbihBTFQsIGVuY29k
aW5nPSJ1dGYtOCIpLnJlYWQoKQpjaGsoImNvbmZpZzogYWx0ZXIgSW5oYWx0IHVudmVyYWVuZGVydCBkYXZvciIsIHNyY19jLnN0
YXJ0c3dpdGgoYWx0X3NyYy5yc3RyaXAoIlxuIikpKQoKIyAtLS0tIFRlc3QgMTogZWNodGUgY29uZmlnLnB5OiBvaG5lIERhdGVp
L1VtZ2VidW5nIG5pY2h0cyBnZWFlbmRlcnQgLS0tLQpXID0gdGVtcGZpbGUubWtkdGVtcChwcmVmaXg9InNsdGVzdC0iKQp0cnk6
CiAgICBkMSA9IG9zLnBhdGguam9pbihXLCAidDEiKTsgb3MubWFrZWRpcnMoZDEpCiAgICBzaHV0aWwuY29weShvcy5wYXRoLmpv
aW4oTkVVLCAiY29uZmlnLnB5IiksIGQxKTsgc2h1dGlsLmNvcHkob3MucGF0aC5qb2luKE5FVSwgInNlY3JldF91dGlsLnB5Iiks
IGQxKQogICAgZDAgPSBvcy5wYXRoLmpvaW4oVywgInQwIik7IG9zLm1ha2VkaXJzKGQwKQogICAgc2h1dGlsLmNvcHkoQUxULCBv
cy5wYXRoLmpvaW4oZDAsICJjb25maWcucHkiKSkKICAgIGNvZGUgPSAiaW1wb3J0IGNvbmZpZyxoYXNobGliLGpzb247cHJpbnQo
aGFzaGxpYi5zaGEyNTYoanNvbi5kdW1wcyh7azpyZXByKHYpIGZvciBrLHYgaW4gdmFycyhjb25maWcpLml0ZW1zKCkgaWYgay5p
c3VwcGVyKCl9LHNvcnRfa2V5cz1UcnVlKS5lbmNvZGUoKSkuaGV4ZGlnZXN0KCkpIgogICAgcjAgPSBydW4oY29kZSwgZDApOyBy
MSA9IHJ1bihjb2RlLCBkMSkKICAgIGNoaygiVDEgZWNodGUgY29uZmlnOiBhbGxlIFdlcnRlIGlkZW50aXNjaCBvaG5lIERhdGVp
L1VtZ2VidW5nIiwgcjBbMF0gPT0gMCBhbmQgcjFbMF0gPT0gMCBhbmQgcjBbMV0gPT0gcjFbMV0gYW5kIHIxWzFdLnN0cmlwKCkg
IT0gIiIsIChyMFsyXSArIHIxWzJdKVs6MTAwXS5yZXBsYWNlKCJcbiIsICIgIikpCiAgICAjIG9obmUgc2VjcmV0X3V0aWwucHk6
IGNvbmZpZy5weSBsYWV1ZnQgdHJvdHpkZW0gKFJ1ZWNrZmFsbCkKICAgIGQxYiA9IG9zLnBhdGguam9pbihXLCAidDFiIik7IG9z
Lm1ha2VkaXJzKGQxYik7IHNodXRpbC5jb3B5KG9zLnBhdGguam9pbihORVUsICJjb25maWcucHkiKSwgZDFiKQogICAgcjFiID0g
cnVuKGNvZGUsIGQxYikKICAgIGNoaygiVDFiIGNvbmZpZyBvaG5lIHNlY3JldF91dGlsLnB5IGxhZXVmdCB1bnZlcmFlbmRlcnQi
LCByMWJbMF0gPT0gMCBhbmQgcjFiWzFdID09IHIwWzFdKQoKICAgICMgLS0tLSBUZXN0IDIuLjogc3ludGhldGlzY2hlIGNvbmZp
ZyBtaXQgWnVmYWxsc3NjaGx1ZXNzZWxuIC0tLS0KICAgIGsxLCBrMiwgazMgPSBybmQoMzIpLCBybmQoMzYpLCBybmQoMzIpCiAg
ICBuMSwgbjIsIG4zID0gcm5kKDMyKSwgcm5kKDM2KSwgcm5kKDMyKQogICAgZDIgPSBvcy5wYXRoLmpvaW4oVywgInQyIik7IG9z
Lm1ha2VkaXJzKG9zLnBhdGguam9pbihkMiwgInNlY3JldHMiKSkKICAgIG9wZW4ob3MucGF0aC5qb2luKGQyLCAiY29uZmlnLnB5
IiksICJ3Iikud3JpdGUoJ0FQSV9LRVlfR0lFID0gIiVzIlxuVEFOS0VSS09FTklHX0FQSV9LRVkgPSAiJXMiXG5GSVJNU19NQVBf
S0VZID0gIiVzIlxuUE9SVCA9IDUwMDBcbicgJSAoazEsIGsyLCBrMykpCiAgICBzaHV0aWwuY29weShvcy5wYXRoLmpvaW4oTkVV
LCAic2VjcmV0X3V0aWwucHkiKSwgZDIpCiAgICBvcGVuKG9zLnBhdGguam9pbihkMiwgImNvbmZpZy5weSIpLCAiYSIpLndyaXRl
KCJcbiIgKyBzcmNfY1tzcmNfYy5pbmRleCgiIyA9PT09PSBzZWNMb2FkIik6XSkKICAgIHNob3cgPSAiaW1wb3J0IGNvbmZpZztw
cmludChjb25maWcuQVBJX0tFWV9HSUU9PSVyLCBjb25maWcuVEFOS0VSS09FTklHX0FQSV9LRVk9PSVyLCBjb25maWcuRklSTVNf
TUFQX0tFWT09JXIsIGNvbmZpZy5QT1JUKSIKICAgIG8gPSBydW4oc2hvdyAlIChrMSwgazIsIGszKSwgZDIpCiAgICBjaGsoIlQy
IHN5bnRoZXRpc2NoIG9obmUgRGF0ZWk6IFdlcnRlIGF1cyBjb25maWcucHkiLCBvWzFdLnN0cmlwKCkgPT0gIlRydWUgVHJ1ZSBU
cnVlIDUwMDAiLCBvWzJdWzoxMDBdKQogICAgbyA9IHJ1bihzaG93ICUgKG4xLCBrMiwgazMpLCBkMiwgeyJBUElfS0VZX0dJRSI6
IG4xfSkKICAgIGNoaygiVDMgVW1nZWJ1bmcgdWViZXJzY2hyZWlidCBudXIgZGVuIGdlc2V0enRlbiBTY2hsdWVzc2VsIiwgb1sx
XS5zdHJpcCgpID09ICJUcnVlIFRydWUgVHJ1ZSA1MDAwIiwgb1syXVs6MTAwXSkKICAgIGtmID0gb3MucGF0aC5qb2luKGQyLCAi
c2VjcmV0cyIsICJrZXlzLmVudiIpCiAgICBvcGVuKGtmLCAidyIpLndyaXRlKCIjIEtvbW1lbnRhclxuVEFOS0VSS09FTklHX0FQ
SV9LRVk9JXNcbmV4cG9ydCBGSVJNU19NQVBfS0VZPSclcydcblVOQkVLQU5OVD0lc1xuQVBJX0tFWV9HSUU9XG4iICUgKG4yLCBu
Mywgcm5kKDIwKSkpCiAgICBvcy5jaG1vZChrZiwgMG82MDApCiAgICBvID0gcnVuKHNob3cgJSAoazEsIG4yLCBuMyksIGQyKQog
ICAgY2hrKCJUNCBEYXRlaSAoNjAwKTogendlaSBTY2hsdWVzc2VsIHVlYmVyc2NocmllYmVuLCBsZWVyZXIgV2VydCBpZ25vcmll
cnQiLCBvWzFdLnN0cmlwKCkgPT0gIlRydWUgVHJ1ZSBUcnVlIDUwMDAiLCBvWzJdWzoxMDBdKQogICAgbyA9IHJ1bigiaW1wb3J0
IGNvbmZpZztwcmludChoYXNhdHRyKGNvbmZpZywnVU5CRUtBTk5UJykpIiwgZDIpCiAgICBjaGsoIlQ0YiB1bmJla2FubnRlciBO
YW1lIGF1cyBkZXIgRGF0ZWkgd2lyZCBuaWNodCB1ZWJlcm5vbW1lbiIsIG9bMV0uc3RyaXAoKSA9PSAiRmFsc2UiLCBvWzJdWzox
MDBdKQogICAgb3MuY2htb2Qoa2YsIDBvNjQ0KQogICAgbyA9IHJ1bihzaG93ICUgKGsxLCBrMiwgazMpLCBkMikKICAgIGNoaygi
VDUgRGF0ZWkgbWl0IFJlY2h0ZW4gNjQ0IHdpcmQgaWdub3JpZXJ0Iiwgb1sxXS5zdHJpcCgpID09ICJUcnVlIFRydWUgVHJ1ZSA1
MDAwIiwgb1syXVs6MTAwXSkKICAgIG9zLmNobW9kKGtmLCAwbzYwMCkKICAgIG8gPSBydW4oc2hvdyAlIChuMSwgbjIsIG4zKSwg
ZDIsIHsiQVBJX0tFWV9HSUUiOiBuMX0pCiAgICBjaGsoIlQ2IFVtZ2VidW5nIHVuZCBEYXRlaSBnZW1pc2NodCIsIG9bMV0uc3Ry
aXAoKSA9PSAiVHJ1ZSBUcnVlIFRydWUgNTAwMCIsIG9bMl1bOjEwMF0pCiAgICBvcGVuKGtmLCAidyIpLndyaXRlKCJGSVJNU19N
QVBfS0VZPSVzXG4iICUgbjMpCiAgICBvID0gcnVuKCJpbXBvcnQgY29uZmlnO3ByaW50KGNvbmZpZy5GSVJNU19NQVBfS0VZPT0n
eHh4eHgnKSIsIGQyLCB7IkZJUk1TX01BUF9LRVkiOiAieCIgKiA1fSkKICAgIGNoaygiVDdiIFVtZ2VidW5nID4gRGF0ZWkgZXhh
a3QiLCBvWzFdLnN0cmlwKCkgPT0gIlRydWUiLCBvWzJdWzoxMDBdKQogICAgIyBTeW1saW5rIC8gVmVyemVpY2huaXMgLyBrYXB1
dHRlIERhdGVpCiAgICBvcy5yZW1vdmUoa2YpOyByZWFsID0gb3MucGF0aC5qb2luKGQyLCAicmVhbC5lbnYiKTsgb3BlbihyZWFs
LCAidyIpLndyaXRlKCJGSVJNU19NQVBfS0VZPSVzXG4iICUgbjMpOyBvcy5jaG1vZChyZWFsLCAwbzYwMCk7IG9zLnN5bWxpbmso
cmVhbCwga2YpCiAgICBvID0gcnVuKHNob3cgJSAoazEsIGsyLCBrMyksIGQyKQogICAgY2hrKCJUOCBTeW1saW5rIGFscyBTY2hs
dWVzc2VsZGF0ZWkgd2lyZCBpZ25vcmllcnQiLCBvWzFdLnN0cmlwKCkgPT0gIlRydWUgVHJ1ZSBUcnVlIDUwMDAiLCBvWzJdWzox
MDBdKQogICAgb3MucmVtb3ZlKGtmKTsgb3BlbihrZiwgIndiIikud3JpdGUoYiJceGZmXHhmZVx4MDBnYXJiYWdlXG49XG49PT1c
biIpOyBvcy5jaG1vZChrZiwgMG82MDApCiAgICBvID0gcnVuKHNob3cgJSAoazEsIGsyLCBrMyksIGQyKQogICAgY2hrKCJUOSBr
YXB1dHRlIERhdGVpOiBrZWluIEFic3R1cnosIFdlcnRlIHVudmVyYWVuZGVydCIsIG9bMF0gPT0gMCBhbmQgb1sxXS5zdHJpcCgp
ID09ICJUcnVlIFRydWUgVHJ1ZSA1MDAwIiwgb1syXVs6MTAwXSkKICAgIG9zLnJlbW92ZShrZikKICAgICMgLS0tLSBzYWZlX2Vy
ciAtLS0tCiAgICBjb2RlID0gKAogICAgICAgICJpbXBvcnQgc2VjcmV0X3V0aWwgYXMgcyxyZXF1ZXN0c1xuIgogICAgICAgICJr
PSVyO3Q9JXJcbiIKICAgICAgICAiY2FzZXM9Wyc0MDMgQ2xpZW50IEVycm9yOiBGb3JiaWRkZW4gZm9yIHVybDogaHR0cHM6Ly9m
aXJtcy5tb2RhcHMuZW9zZGlzLm5hc2EuZ292L2FwaS9hcmVhL2Nzdi8nK2srJy9WSUlSU19TTlBQX05SVC8xMC43NSw0OS4yNSwx
MS43NSw0OS44Ny8xJyxcbiIKICAgICAgICAiICdIVFRQU0Nvbm5lY3Rpb25Qb29sKGhvc3Q9eCk6IE1heCByZXRyaWVzIGV4Y2Vl
ZGVkIHdpdGggdXJsOiAvYXBpL2RldGFpbC5waHA/aWQ9YWJjJmFwaWtleT0nK3QrJyAoQ2F1c2VkIGJ5IFgpJyxcbiIKICAgICAg
ICAiICd1cmwgL3YxLycraysnP2tleT0nK2srJyZ0b2tlbj0nK3RdXG4iCiAgICAgICAgImJhZD0wXG4iCiAgICAgICAgImZvciBj
IGluIGNhc2VzOlxuIgogICAgICAgICIgICAgcj1zLnNhZmVfZXJyKHJlcXVlc3RzLkhUVFBFcnJvcihjKSlcbiIKICAgICAgICAi
ICAgIHIyPXMuc2FmZV9lcnIocmVxdWVzdHMuSFRUUEVycm9yKGMpLDEyMClcbiIKICAgICAgICAiICAgIGlmIGsgaW4gciBvciB0
IGluIHIgb3IgayBpbiByMiBvciB0IGluIHIyIG9yIGxlbihyMik+MTIwOiBiYWQrPTFcbiIKICAgICAgICAicHJpbnQoYmFkLCBs
ZW4ocy5zYWZlX2VycihWYWx1ZUVycm9yKCdub3JtYWxlciBGZWhsZXIgb2huZSBTY2hsdWVzc2VsJykpKT4wLCBzLnNhZmVfZXJy
KFZhbHVlRXJyb3IoJ1RpbWVvdXQgbmFjaCAyNSBzJykpPT0nVGltZW91dCBuYWNoIDI1IHMnKVxuIgogICAgKSAlIChrMSwgazIp
CiAgICBvID0gcnVuKGNvZGUsIGQyKQogICAgY2hrKCJUMTAgc2FmZV9lcnI6IGJla2FubnRlIFNjaGx1ZXNzZWwgKFBmYWQsIGFw
aWtleT0sIGtleT0sIHRva2VuPSkgZW50ZmVybnQsIGF1Y2ggZ2VrdWVyenQiLCBvWzFdLnNwbGl0KClbOjFdID09IFsiMCJdIGFu
ZCBvWzFdLnN0cmlwKCkuZW5kc3dpdGgoIlRydWUgVHJ1ZSIpLCAob1sxXSArIG9bMl0pWzoxMjBdKQogICAga2sgPSBybmQoMTIp
CiAgICBjb2RlID0gKAogICAgICAgICJpbXBvcnQgc2VjcmV0X3V0aWwgYXMgc1xuIgogICAgICAgICJrPSVyXG4iCiAgICAgICAg
InI9cy5zYWZlX2VycihFeGNlcHRpb24oJ3gnKjExMCtrKSwxMjApXG4iCiAgICAgICAgInIyPXMuc2FmZV9lcnIoRXhjZXB0aW9u
KCdWZXJiaW5kdW5nIHp1ICcraysnIHZlcmxvcmVuJykpXG4iCiAgICAgICAgInIzPXMuc2FmZV9lcnIoRXhjZXB0aW9uKCd1cmwg
P2FwaWtleT1LdXJ6ZXJXZXJ0MSBFbmRlJykpXG4iCiAgICAgICAgInByaW50KGtbOjhdIG5vdCBpbiByLCBrIG5vdCBpbiByMiwg
J0t1cnplcldlcnQxJyBub3QgaW4gcjMpXG4iCiAgICApICUga2sKICAgIG8gPSBydW4oY29kZSwgZDIsIHsiRklSTVNfTUFQX0tF
WSI6IGtrfSkKICAgIGNoaygiVDEwYiBLdWVyemVuIGVyc3QgbmFjaCBSZWRha3Rpb24sIGVpbmZhY2hlIE5lbm51bmcsIHVuYmVr
YW5udGVyIGFwaWtleT0tV2VydCIsIG9bMV0uc3RyaXAoKSA9PSAiVHJ1ZSBUcnVlIFRydWUiLCAob1sxXSArIG9bMl0pWzoxMjBd
KQogICAgY29kZSA9ICgKICAgICAgICAiaW1wb3J0IHNlY3JldF91dGlsIGFzIHNcbiIKICAgICAgICAidT0naHR0cHM6Ly9leGFt
cGxlLm9yZy9hcGkvJyslcisnL3gnXG4iCiAgICAgICAgInI9cy5zYWZlX2VycihFeGNlcHRpb24oJ0ZlaGxlciAnK3UpKVxuIgog
ICAgICAgICJwcmludCglciBub3QgaW4gciwgJyoqKicgaW4gcilcbiIKICAgICkgJSAoIkEiICogMzAsICJBIiAqIDMwKQogICAg
byA9IHJ1bihjb2RlLCBkMikKICAgIGNoaygiVDExIHNhZmVfZXJyOiB1bmJla2FubnRlciBsYW5nZXIgUGZhZGFic2Nobml0dCAo
Pj0yNCkgd2lyZCBlbnRmZXJudCIsIG9bMV0uc3RyaXAoKSA9PSAiVHJ1ZSBUcnVlIiwgb1syXVs6MTAwXSkKICAgICMgLS0tLSBs
dWZ0LnB5IG1pdCBzaW11bGllcnRlbSBOZXR6ZmVobGVyIChrZWluZSBlY2h0ZSBWZXJiaW5kdW5nKSAtLS0tCiAgICBkMyA9IG9z
LnBhdGguam9pbihXLCAidDMiKTsgc2h1dGlsLmNvcHl0cmVlKGQyLCBkMykKICAgIHNodXRpbC5jb3B5KG9zLnBhdGguam9pbihO
RVUsICJsdWZ0LnB5IiksIGQzKQogICAgY29kZSA9ICgKICAgICAgICAiaW1wb3J0IGx1ZnQscmVxdWVzdHNcbiIKICAgICAgICAi
az0lclxuIgogICAgICAgICJkZWYgYm9vbSh1cmwsKiprdyk6XG4iCiAgICAgICAgIiAgICByYWlzZSByZXF1ZXN0cy5IVFRQRXJy
b3IoJzQwMyBDbGllbnQgRXJyb3I6IEZvcmJpZGRlbiBmb3IgdXJsOiAnK3VybClcbiIKICAgICAgICAibHVmdC5yZXF1ZXN0cy5n
ZXQ9Ym9vbVxuIgogICAgICAgICJyPWx1ZnQuZmV0Y2hfZmlybXMoKTsgcjI9bHVmdC5mZXRjaF9zZW5zb3JzKClcbiIKICAgICAg
ICAicHJpbnQoayBpbiBzdHIociksIGsgaW4gc3RyKHIyKSwgclsnb2snXSwgcjJbJ29rJ10sICdlcnJvcicgaW4gcilcbiIKICAg
ICkgJSBrMwogICAgbyA9IHJ1bihjb2RlLCBkMykKICAgIGNoaygiVDEyIGx1ZnQuZmV0Y2hfZmlybXMvZmV0Y2hfc2Vuc29yczog
RmVobGVyZmVsZCBvaG5lIFNjaGx1ZXNzZWwiLCBvWzFdLnN0cmlwKCkgPT0gIkZhbHNlIEZhbHNlIEZhbHNlIEZhbHNlIFRydWUi
LCAob1sxXSArIG9bMl0pWzoxNDBdKQogICAgIyBSdWVja2ZhbGw6IHNlY3JldF91dGlsIGZlaGx0CiAgICBkNCA9IG9zLnBhdGgu
am9pbihXLCAidDQiKTsgb3MubWFrZWRpcnMoZDQpOyBzaHV0aWwuY29weShvcy5wYXRoLmpvaW4oTkVVLCAibHVmdC5weSIpLCBk
NCkKICAgIG9wZW4ob3MucGF0aC5qb2luKGQ0LCAiY29uZmlnLnB5IiksICJ3Iikud3JpdGUoJ0ZJUk1TX01BUF9LRVkgPSAiJXMi
XG4nICUgazMpCiAgICBvID0gcnVuKGNvZGUsIGQ0KQogICAgY2hrKCJUMTMgbHVmdCBvaG5lIHNlY3JldF91dGlsLnB5OiBSdWVj
a2ZhbGwgZW50ZmVybnQgZGVuIFNjaGx1ZXNzZWwgaW0gVVJMLVBmYWQiLCBvWzFdLnN0cmlwKCkgPT0gIkZhbHNlIEZhbHNlIEZh
bHNlIEZhbHNlIFRydWUiLCAob1sxXSArIG9bMl0pWzoxNDBdKQogICAgIyAtLS0tIGtlaW5lIEF1c2dhYmUgdm9uIFdlcnRlbiAt
LS0tCiAgICBjb2RlID0gImltcG9ydCBjb25maWcsc2VjcmV0X3V0aWwgYXMgcztzLmxvYWRfb3ZlcnJpZGVzKCk7cy5rbm93bl9z
ZWNyZXRzKCk7cy5zYWZlX2VycihFeGNlcHRpb24oJ3gnKSk7Y29uZmlnIgogICAgbyA9IHJ1bihjb2RlLCBkMiwgeyJBUElfS0VZ
X0dJRSI6IG4xfSkKICAgIGNoaygiVDE0IE1vZHVsZSBnZWJlbiBuaWNodHMgYXVzIChzdGRvdXQvc3RkZXJyIGxlZXIpIiwgb1sw
XSA9PSAwIGFuZCBvWzFdID09ICIiIGFuZCBvWzJdID09ICIiLCAob1sxXSArIG9bMl0pWzo2MF0pCmZpbmFsbHk6CiAgICBzaHV0
aWwucm10cmVlKFcsIGlnbm9yZV9lcnJvcnM9VHJ1ZSkKCnByaW50KCJTRUxGVEVTVCBzZWNMb2FkOiAlZCBPSywgJWQgRkFJTCIg
JSAob2ssIGZhaWwpKQpzeXMuZXhpdCgxIGlmIGZhaWwgZWxzZSAwKQo=
EMB_T
cat > "$W/emb/luft_base.py.gz.b64" <<'EMB_L'
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
qvtLimr6AfpmVcd+hV/xhcB3IciQ+IKR5GhJh8yzsTYwHTRRXB33JqrSyVsO2b5w0HZ0Z8ZtO0b5AvtTYwf56Bjtm4SuCfTXmKfj
Ten6YpwUxl4LqL5pGHBqyrroTI2uidEpMdrqO12V8RCu+wf7P01gG9biMkhpaSIl9WWskWowQeBfY35VYK8uwpKmea+1701XqziB
CkJIZXJT7INT32GE+tAGiDmN2g6gsVZ7ApOoR45CIKrQMmx4azBYdEf6/k4abRqwZucaomhBD/jKU4aGp2gvG1peVtL5lJdviDoR
98yeCtI0eiBqB82KMiLFSk2WDppVNbeGngmuVzd+FWdNgH0QRR0OagL1DPWfv/zxbwz/Z4v3K57E1Y8/VOxf/2RHUv067Ii55su4
T1x7E8t9o/2uakb3yArs1rVG9g47I8Jv4yQq19C77Gmtb0W6XuZIrLdnNxzsmTaa5tdpG5dSkNnsuE7bj3wNcmsPG32Nz2wj5rwo
4SSOOtNoxEKtxRfljz9kcJc2yvqqxB6bo1UCe2iVXKc+ntXbcmQnb+NUpOq6ZAB1//mvSOpIakr4Bgxs+WozoylEr6rqKaWWCRZp
YAHNENt1pmzwhWY3ayEFY27nScfi7SgYzBn+EGPqkgQkYUf9nWf101hT+dZ2riJP3X0bD8PJ0NArluJmQYn3vB2tLpsrGnJtAqfS
LkJ29Y7EVQGsn5jHDd7E294Vt1YQ7XCDlyJli80rsfIuuNKj9nF2l0nSMogMjaK7RIGptyVkA+BwQ88LSkHP4q4TYITyjTPvWsUf
/q6sojYwzR+VrNpPwFCgwieuPKsydH6XOcF3ORTARNXD5NLDh+j/AgFf93DeJQAA
EMB_L
for f in secret_util.py secload_edit.py sltest.py; do base64 -d "$W/emb/$f.b64" > "$W/emb/$f" 2>/dev/null || stop "eingebettete Datei $f nicht lesbar (Skript beschaedigt oder veraendert)"; done
base64 -d "$W/emb/luft_base.py.gz.b64" 2>/dev/null | gunzip > "$W/emb/luft_base.py" 2>/dev/null || stop "eingebettete Datei luft_base.py nicht lesbar (Skript beschaedigt oder veraendert)"
chk_emb() { [[ "$(sha256sum "$W/emb/$1" | cut -d' ' -f1)" == "$2" ]] || stop "eingebettete Datei $1 hat die falsche Pruefsumme (Skript beschaedigt oder veraendert)"; }
chk_emb secret_util.py "ff8e2ac7049f4bde59e6eb7e3737905c7c4af0b2a95d1eddc6f032dabfe33099"
chk_emb secload_edit.py "80eb136947de0890f251aee6fa24d71751d304f10a5a7ddf0d1ce15759cf21bb"
chk_emb sltest.py "70dc120e792fd524e93b787ccd5d1d63ae3795b67a0b60c045ffdcb2e7cdb600"
chk_emb luft_base.py "a31e99eb32df4498577c846dcce1c3d53f829628c1b081613ebadbab9d2a9d42"
[[ "$(s16 "$W/emb/secret_util.py")" == "$KNOWN_SU16" ]] || stop "secret_util.py sha16 passt nicht zum Skript"
echo "OK eingebettete Dateien: sha256 stimmt (secret_util.py $KNOWN_SU16)"
# ---------- 2) Basis pruefen (nur lesen) ----------
[[ -d "$DASH_DIR" && -f "$LF" && -f "$CF" ]] || stop "Projektordner/luft.py/config.py nicht gefunden ($DASH_DIR)"
"$SPY" -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$CF" 2>/dev/null || stop "config.py ist kein gueltiges Python (Inhalt wird nicht angezeigt)"
L0=$(s16 "$LF")
if [[ "$L0" != "$KNOWN_L16" && "$L0" != "$KNOWN_L16N" ]]; then
  echo "luft.py sha16 $L0 (erwartet $KNOWN_L16 oder neu $KNOWN_L16N). Unterschiede zur erwarteten Basis (Zeilen mit - fehlen auf dem Pi, mit + sind zusaetzlich):"
  diff <(cat "$W/emb/luft_base.py") "$LF" | head -40 | cut -c1-160 || true
  stop "luft.py hat nicht den erwarteten Stand"
fi
echo "OK Basis luft.py $L0 ($(wc -l < "$LF") Zeilen, $([[ "$L0" == "$KNOWN_L16N" ]] && echo "secLoad schon drin" || echo "bekannt"))"
CMODE=$(stat -c %a "$CF"); echo "OK config.py: gueltiges Python, Rechte $CMODE$([[ "$CMODE" == 600 ]] || echo " (HINWEIS: im Kopf der Datei steht chmod 600; Empfehlung: chmod 600 $CF)") - Inhalt wird nicht angezeigt"
if [[ -f "$BK" ]]; then B0=$(s16 "$BK"); [[ "$B0" == "$KNOWN_BK16" ]] && echo "OK tools/backup.sh $B0 (unveraendert; umask 077, Archiv 600, config.py und secrets/ bleiben fuer die Wiederherstellung im Archiv)" || echo "HINWEIS tools/backup.sh hat sha16 $B0 (erwartet $KNOWN_BK16) - wird von diesem Patch nicht geaendert"; fi
if [[ -d "$DASH_DIR/secrets" ]]; then echo "OK secrets/ vorhanden, Rechte $(stat -c %a "$DASH_DIR/secrets")$([[ "$(stat -c %a "$DASH_DIR/secrets")" =~ ^7[0-5]0$ ]] || echo " (HINWEIS: Empfehlung chmod 700 $DASH_DIR/secrets)")"; fi
# ---------- 3) neue Dateien in der Sandbox bauen und testen ----------
cp -p "$CF" "$W/alt/config.py"; cp -p "$LF" "$W/alt/luft.py"
"$SPY" "$W/emb/secload_edit.py" luft "$LF" "$W/neu/luft.py" || stop "luft.py: Aenderung nicht anwendbar"
"$SPY" "$W/emb/secload_edit.py" config "$CF" "$W/neu/config.py" || stop "config.py: Aenderung nicht anwendbar"
cp "$W/emb/secret_util.py" "$W/neu/secret_util.py"
chmod 600 "$W/neu/config.py" "$W/alt/config.py"
"$SPY" "$W/emb/secload_edit.py" luft "$W/neu/luft.py" "$W/neu/luft2.py" && cmp -s "$W/neu/luft.py" "$W/neu/luft2.py" && "$SPY" "$W/emb/secload_edit.py" config "$W/neu/config.py" "$W/neu/config2.py" && cmp -s "$W/neu/config.py" "$W/neu/config2.py" || stop "Aenderung ist nicht idempotent"
rm -f "$W/neu/luft2.py" "$W/neu/config2.py"
echo "OK Trockenlauf idempotent (zweite Anwendung aendert nichts)"
for PY in "$SPY" "$VPY"; do
  PYTHONPYCACHEPREFIX="$W/pyc" "$PY" -W error -m py_compile "$W/neu/luft.py" "$W/neu/config.py" "$W/neu/secret_util.py" "$W/emb/secload_edit.py" "$W/emb/sltest.py" 2>"$W/pyc.log" || { cat "$W/pyc.log" | cut -c1-200 | sed 's/^/  /'; stop "py_compile ($PY) meldet einen Fehler"; }
done
echo "OK py_compile ohne Warnung (luft.py, config.py, secret_util.py, Pruefprogramme; $SPY und $VPY)"
for PY in "$SPY" "$VPY"; do
  "$PY" "$W/emb/sltest.py" "$W/neu" "$W/alt/config.py" > "$W/st.log" 2>&1 || { cut -c1-200 "$W/st.log"; stop "Selbsttest ($PY) fehlgeschlagen"; }
  echo "OK $(tail -1 "$W/st.log") ($PY; Sandbox, Zufallsschluessel, echte config.py nur zum Vergleich, keine Netzverbindung)"
done
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF beendet: Dateien, Tests und Basis sind in Ordnung; nichts installiert, kein sudo, kein Neustart. Echter Lauf: bash /tmp/apply-secload.sh $COMMIT_ARG"
  exit 0
fi
# ---------- 4) Zustand vorher ----------
PHASE=nachher-vorbereitung
code() { local c; c=$(curl -s --connect-timeout 3 --max-time 40 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true); echo "${c:-000}"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
[[ "${PRE[/]}" == 200 ]] || stop "Dashboard antwortet vor dem Patch nicht mit 200 (/ = ${PRE[/]})"
SVCS="prepper-dashboard prepper-sdr mesh-bridge"
declare -A ACT0 AET0
for u in $SVCS; do ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); done
NEED_L=0; NEED_C=0; NEED_S=0
[[ "$(s16 "$LF")" == "$KNOWN_L16N" ]] || NEED_L=1
grep -q "===== secLoad (commit26)" "$CF" || NEED_C=1
[[ -f "$SU" && "$(s16 "$SU")" == "$KNOWN_SU16" ]] || NEED_S=1
NEED_ALL="$NEED_L$NEED_C$NEED_S"
RESTARTED_D=0; INST_SU=0; SU_PREEXIST=0; [[ -f "$SU" ]] && SU_PREEXIST=1
code_r() { code "$@"; }
rb() {
  echo "ROLLBACK: $1"
  [[ -f "$LF.bak-secload-$TS" ]] && cp -p "$LF.bak-secload-$TS" "$LF" && echo "  luft.py zurueck"
  [[ -f "$CF.bak-secload-$TS" ]] && cp -p "$CF.bak-secload-$TS" "$CF" && echo "  config.py zurueck"
  [[ "$INST_SU" == 1 && "$SU_PREEXIST" == 0 ]] && rm -f "$SU" && echo "  secret_util.py entfernt"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 $WN); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    echo "  prepper-dashboard neu gestartet: $(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  fi
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_ALL" != 000 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_ALL" == 000 ]]; then
  echo "OK secLoad schon installiert (luft.py, config.py, secret_util.py) - kein Neustart, keine Aenderung"
else
  sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart von prepper-dashboard erforderlich"
  PHASE=Installation
  for x in "$LF" "$CF"; do
    cp -a "$x" "$x.bak-secload-$TS"
    { ls -1t "$x.bak-secload-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  inst() { cp "$1" "$2.new" && chmod --reference="$2.bak-secload-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $(basename "$2")"; exit 1; }; }
  if [[ "$NEED_S" == 1 ]]; then INST_SU=1; cp "$W/neu/secret_util.py" "$SU.new" && chmod 644 "$SU.new" && mv -f "$SU.new" "$SU" || { rb "secret_util.py nicht installierbar"; exit 1; }; fi
  [[ "$NEED_C" == 1 ]] && inst "$W/neu/config.py" "$CF"
  [[ "$NEED_L" == 1 ]] && inst "$W/neu/luft.py" "$LF"
  [[ "$(s16 "$SU")" == "$KNOWN_SU16" ]] || { rb "secret_util.py nach dem Kopieren falsch"; exit 1; }
  [[ "$NEED_L" == 0 || "$(s16 "$LF")" == "$KNOWN_L16N" ]] || { rb "luft.py nach dem Kopieren falsch"; exit 1; }
  echo "OK Dateien atomar ersetzt (Sicherungen *.bak-secload-$TS, behalten: letzte $KEEP_LAST; config.py-Rechte unveraendert)"
  # Import-Probe mit den Python-Interpretern des Dienstes, bevor der Dienst neu startet (nur Namen/Zaehler)
  for PY in "$SPY" "$VPY"; do
    (cd "$DASH_DIR" && PYTHONDONTWRITEBYTECODE=1 "$PY" -c 'import config, secret_util, luft; print("import ok")' > "$W/imp.log" 2>&1) || { cut -c1-200 "$W/imp.log"; rb "Import-Probe ($PY) fehlgeschlagen"; exit 1; }
  done
  echo "OK Import-Probe config, secret_util, luft mit $SPY und $VPY"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 $WN); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
fi
[[ -n "${T0D:-}" ]] || { T0D=$(( $(date +%s) - 3600 )); TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D"); }
PHASE=Pruefung
# ---------- 5) Pruefungen ----------
rdy=0
for i in $(seq 1 40); do
  ok2=1; for p in /umwelt /; do "${CURL[@]}" "$B$p" -o "$W/pg.html" || true; grep -q "<title>Dashboard startet" "$W/pg.html" 2>/dev/null && ok2=0; done
  [[ "$ok2" == 1 ]] && { rdy=1; break; }
  [[ "$RESTARTED_D" == 1 ]] || { rdy=1; break; }
  sleep 5
done
[[ "$rdy" == 1 ]] && echo "OK Dashboard fertig gestartet" || echo "HINWEIS Dashboard zeigt nach 200 s noch die Startseite (Voll-Update laeuft noch)"
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /umwelt /luft; do c=$(code "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
echo "OK alle 26 Seiten/APIs wie vorher, zusaetzlich /luft = 200"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
# Schluessel-Status und Redaktion mit den ECHTEN Schluesseln (nur ja/nein, Namen, Laengen; keine Werte)
(cd "$DASH_DIR" && PYTHONDONTWRITEBYTECODE=1 "$VPY" secret_util.py status) > "$W/status.txt" 2>&1 || true
sed 's/^/   /' "$W/status.txt" | cut -c1-200
cat > "$W/real.py" <<'PYREAL'
import os, sys
sys.path.insert(0, os.getcwd())
import secret_util as s, config, requests
vals = [getattr(config, k, "") for k in s.KEY_NAMES]
vals = [v for v in vals if isinstance(v, str) and len(v) >= 8]
bad = 0; n = 0
for v in vals:
    for t in ("403 Client Error: Forbidden for url: https://x.example/api/area/csv/%s/VIIRS/1" % v,
              "Max retries exceeded with url: /api/detail.php?id=1&apikey=%s (Caused by X)" % v,
              "x" * 100 + v):
        for lim in (None, 120):
            n += 1
            if v in s.safe_err(requests.HTTPError(t), lim) or (lim is None and v[:10] in s.safe_err(requests.HTTPError(t))):
                bad += 1
print("Redaktion mit den echten Schluesseln: %d Pruefungen, %d Treffer von Schluesseln in der Ausgabe (soll 0 sein)" % (n, bad))
raise SystemExit(1 if bad or not n else 0)
PYREAL
(cd "$DASH_DIR" && PYTHONDONTWRITEBYTECODE=1 "$VPY" "$W/real.py") > "$W/real.log" 2>&1 && echo "OK $(cat "$W/real.log")" || { cut -c1-200 "$W/real.log"; rbx "Redaktion mit den echten Schluesseln wirkt nicht"; }
# Journal: Schluessel in den letzten 7 Tagen? (nur Zaehler, nichts angezeigt)
cat > "$W/leak.py" <<'PYLEAK'
import os, sys
sys.path.insert(0, os.getcwd())
import secret_util as s, config
vals = [getattr(config, k, "") for k in s.KEY_NAMES]
vals = [v for v in vals if isinstance(v, str) and len(v) >= 8]
lines = hits = 0
for line in sys.stdin:
    lines += 1
    if any(v in line for v in vals):
        hits += 1
print("%d %d" % (lines, hits))
PYLEAK
JL=$(cd "$DASH_DIR" && { sudo journalctl -u prepper-dashboard --since "-7d" --no-pager -o cat 2>/dev/null || true; } | nice -n 19 env PYTHONDONTWRITEBYTECODE=1 "$VPY" "$W/leak.py" 2>/dev/null || echo "0 0")
JLN=${JL% *}; JLH=${JL#* }
if [[ "${JLN:-0}" == 0 ]]; then echo "HINWEIS Journal prepper-dashboard nicht lesbar (Rechte) - Zaehlung uebersprungen"
elif [[ "${JLH:-0}" == 0 ]]; then echo "OK Journal prepper-dashboard (7 Tage, $JLN Zeilen): kein Schluesselwert gefunden"
else echo "HINWEIS Journal prepper-dashboard (7 Tage, $JLN Zeilen): $JLH Zeilen enthalten einen Schluesselwert (nur Zaehler; ohne Rotation bleibt das so lange das Journal sie haelt; Journal-Aufraeumen ist deine Entscheidung)"; fi
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then echo "HINWEIS Journal seit dem Neustart nicht lesbar - Journal-Pruefung uebersprungen"
else
  E2=$(echo "$JD" | grep -c -E 'Traceback|ModuleNotFoundError|ImportError|secLoad' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal prepper-dashboard seit dem Neustart ohne Traceback/Importfehler" || { echo "$JD" | grep -E 'Traceback|ModuleNotFoundError|ImportError|secLoad' | head -4 | cut -c1-200; rbx "$E2 Fehlerzeilen im Journal seit dem Neustart"; }
fi
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)"); prepper-sdr, mesh-bridge, Timer, Datenbank unberuehrt"
echo "  luft.py sha16 $(s16 "$LF"), $(wc -l < "$LF") Zeilen; secret_util.py sha16 $(s16 "$SU"), $(wc -l < "$SU") Zeilen; config.py: Block secLoad am Ende, Rechte $(stat -c %a "$CF")"
[[ -f "$LF.bak-secload-$TS" ]] && echo "Rueckgaengig: cp -p $LF.bak-secload-$TS $LF  und  cp -p $CF.bak-secload-$TS $CF  und  rm -f $SU  danach sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine secLoad-Sicherung dieses Laufs (schon installiert); fruehere Sicherungen: *.bak-secload-*"
echo "Schluessel spaeter in eine Datei legen (freiwillig, ohne neue Schluessel): Datei $DASH_DIR/secrets/keys.env mit Zeilen NAME=WERT (Rechte 600) anlegen - sie gilt dann vor config.py; ohne Datei bleibt alles wie bisher"
echo "COMMIT $COMMIT_ARG secload=1 fertig"
