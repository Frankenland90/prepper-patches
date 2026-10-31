#!/bin/bash
set -eEuo pipefail
# commit57 usvShutdown - automatische Abschaltung des Pi ueber NUT/upsmon (baut auf commit56 auf):
#  Phase A (NUT): ups.conf [eaton] + ignorelb + override.battery.charge.low = 20 + override.battery.runtime.low = 300 (offdelay 20 / ondelay 30 = Eaton-Werte),
#     upsd.users: Benutzer upsmon_local (upsmon primary, Passwort lokal zufaellig erzeugt, Datei 640 root:nut, wird NIE ausgegeben),
#     upsmon.conf: MONITOR eaton@127.0.0.1 primary, SHUTDOWNCMD "/sbin/shutdown -h +0", POWERDOWNFLAG /etc/killpower, FINALDELAY 5.
#     Treiber-NEUSTART (override/ignorelb wirken erst danach), upsd neu, nut-monitor enable --now. killpower: Debian nutshutdown (systemd-shutdown) schaltet die USV
#     ganz am Ende des Herunterfahrens ab (offdelay 20 s); bei Netzrueckkehr startet die USV neu (ondelay 30 s) und der Pi bootet.
#     Kein Test-Herunterfahren, KEIN "upsmon -c" (das wuerde ausloesen). Pruefung nur: upsc zeigt 20 % / 300 s / ignorelb, upsmon angemeldet, Status OL.
#     Fehler in Phase A -> /etc/nut zurueck, nut-monitor disable --now, Treiber + upsd neu, Abbruch OHNE Dashboard-Aenderung.
#  Phase B (Dashboard): Block usvShutdown (liest alle 30 s nur LIST VAR/LIST CLIENT), /api/usv mit Feld shutdown, Kachel-Zeile "Abschaltung bei 20 % oder 5 min · upsmon aktiv".
#  Keine Mesh-Meldung beim Herunterfahren (nicht freigegeben). Nichts nach aussen, keine Firewall-/rpcbind-Aenderung.
# Aufruf: bash /tmp/apply-commit57.sh commit57 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein Neustart; liest /etc/nut nur mit gueltigem sudo-Ticket)
# Basis streng (sha16): dashboard.py 35fbc0604b09c0dd / lage_pages.py 92a37e6326f0900d / ups_manager.py ef0b9e3d4bf42003 (nach commit56); neu 7d494c1a21e50e96 / a9740c629a41806c.
#   prepper_sdr.py 264ef34996e17753 und prepper_evlog.py 8bffd396972b60fa bleiben unveraendert. Stand vor commit56 -> STOP "erst commit56 anwenden".
# Sicherungen DATEI.bak-commit57-ZEIT fuer dashboard.py, lage_pages.py und /etc/nut/ups.conf, upsd.users, upsmon.conf (je letzte 3). Keine Datenbank-Aenderung.
# Neu gestartet werden nur NUT-Treiber, upsd, upsmon (neu) und prepper-dashboard (prepper-sdr und Mesh-Bruecken bleiben). Gain-Stufe 16 bleibt. Beim Einspielen wird nichts gesendet.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
FL="$DASH_DIR/lage_pages.py"
FU="$DASH_DIR/ups_manager.py"
FS="$DASH_DIR/prepper_sdr.py"
FE="$DASH_DIR/prepper_evlog.py"
VENV="$DASH_DIR/venv"
VPY="$VENV/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/commit57-apply
KEEP_LAST=3
NM=commit57
KNOWN_D16="35fbc0604b09c0dd"; KNOWN_D16N="7d494c1a21e50e96"; KNOWN_D16_C55="86f712401eddab5f"; KNOWN_D16_C54="7b81384b4af00883"
KNOWN_L16="92a37e6326f0900d"; KNOWN_L16N="a9740c629a41806c"; KNOWN_L16_C55="495ee5ac809143c8"; KNOWN_U16="ef0b9e3d4bf42003"
KNOWN_S16="264ef34996e17753"; KNOWN_E16="8bffd396972b60fa"
NUT_ETC=/etc/nut
NUT_PORT=3493
NUT_UPS=eaton
NUT_MARK55="# commit55 usvNut"
NUT_MARK="# commit57 usvShutdown"
NUTSHUT=""
for x in /usr/lib/systemd/system-shutdown/nutshutdown /lib/systemd/system-shutdown/nutshutdown; do [[ -z "$NUTSHUT" && -x "$x" ]] && NUTSHUT="$x"; done
KPF=/etc/killpower
PHASE=vorher
STATE=unbekannt
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
SIM=0; [[ -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && SIM=1
if [[ "$SIM" == 1 ]]; then [[ -n "${C55_NUT_ETC:-}" ]] && NUT_ETC="$C55_NUT_ETC"; [[ -n "${C55_NUT_PORT:-}" ]] && NUT_PORT="$C55_NUT_PORT"; [[ -n "${C57_NUTSHUT+x}" ]] && NUTSHUT="$C57_NUTSHUT"; [[ -n "${C57_KPF:-}" ]] && KPF="$C57_KPF"; fi
echo "=== commit57 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): usvShutdown (upsmon faehrt den Pi bei 20 % oder 5 min herunter, killpower), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/G/nut" "$W/nut" && chmod 700 "$W"
EXPECT_PAT="a9efdd496c0bb6b9f8df75e8a02c741a7bd5e8e6225d2f0cffeaf1d0024c71f3"
cat > "$W/patch.py" << 'MK_C57_PAT_EOF'
"""Patcher commit57 (generisch wie commit56). Aufruf: patch.py NAME dsh|lp QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
name = {"dsh": "dashboard.py", "lp": "lage_pages.py"}[kind]
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
MK_C57_PAT_EOF
EXPECT_EDI="a970644338f97a1aca5cccac69b3ea0d12b031c3425cf33758d1ab826b74207c"
cat > "$W/edits.py" << 'MK_C57_EDI_EOF'
"""Stellen commit57: dashboard.py ein Block vor __main__ (usvShutdown, nach usvAlarm); lage_pages.py vier Stellen in der USV-Kachel (Zeile usvShut, Info-Text)."""
_A = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
DSH_ANCHOR = _A
LP_EDITS = [('    <div class="small" id="usvAlarm"></div>\n', '    <div class="small" id="usvAlarm"></div>\n    <div class="small" id="usvShut"></div>\n'), (' Kein Herunterfahren.</div>', ' Herunterfahren: upsmon fährt den Pi im Akkubetrieb bei 20 % Ladung oder 5 min Restlaufzeit sauber herunter; danach schaltet die USV ab und startet bei Netzrückkehr neu.</div>'), ('  function show(d){\n', "  function shut(d){var s=d.shutdown||{},e=$('usvShut');if(!e)return;e.className='small'+(s.lvl==='gelb'?' usv-gelb':'');tx('usvShut',s.txt?String(s.txt).slice(0,160):'');}\n  function show(d){\n"), ('    var sh=soh(d);test(d);alarm(d);\n', '    var sh=soh(d);test(d);alarm(d);shut(d);\n')]
LP_ANCHOR = None
MK_C57_EDI_EOF
EXPECT_BDS="24e81c9885824b3accbf53ec96fe0782e1829180e30edf17e3df2b23715aadef"
cat > "$W/G/blk_dsh.py" << 'MK_C57_BDS_EOF'
# ===== usvShutdown: Anzeige der automatischen Abschaltung (commit57: upsmon primary, ignorelb, battery.charge.low 20 %, battery.runtime.low 300 s) - liest alle 30 s ueber NUT (127.0.0.1, nur LIST VAR/LIST CLIENT) Schwellen und ob upsmon angemeldet ist; /api/usv mit Feld shutdown; loest selbst NIE etwas aus (kein FSD, kein INSTCMD, kein Befehl) =====
import re as _usvs_re
import threading as _usvs_th
import time as _usvs_time

USVS_CHARGE_LOW = 20
USVS_RUNTIME_LOW = 300
USVS_POLL_S = 30
USVS_STALE_S = 120
USVS_WANT = ("battery.charge.low", "battery.runtime.low", "driver.flag.ignorelb", "ups.delay.shutdown")
_USVS_VAR = _usvs_re.compile(r'^VAR (\S+) (\S+) "(.*)"$')
_USVS_CLI = _usvs_re.compile(r"^CLIENT (\S+) (\S+)$")
_USVS = {"ok": False, "err": None, "started": False, "t": None, "vars": {}, "clients": None, "rerr": None, "orig_api": None, "fake": None, "st": None}


def _usvs_parse(var_lines, cli_lines):
    v = {}
    for ln in var_lines or []:
        m = _USVS_VAR.match(ln)
        if m and m.group(2) in USVS_WANT:
            v[m.group(2)] = m.group(3)[:20]
    c = []
    for ln in cli_lines or []:
        m = _USVS_CLI.match(ln)
        if m:
            c.append(m.group(2)[:40])
    return v, c


def _usvs_read(now):
    f = _USVS.get("fake")
    if callable(f):
        vl, cl = f()
    else:
        m = (globals().get("_USV") or {}).get("mgr")
        port = getattr(m, "port", None) if m is not None else None
        if port is None:
            raise RuntimeError("usvLesen nicht aktiv")
        cli = _uv_m.NutClient(port=port)
        try:
            ups = getattr(m, "ups", None) or "eaton"
            vl = cli._list("VAR %s" % ups)
            try:
                cl = cli._list("CLIENT %s" % ups)
            except Exception:
                cl = None
        finally:
            cli.close()
    v, c = _usvs_parse(vl, cl)
    if cl is None:
        c = None
    _USVS.update(t=now, vars=v, clients=c, rerr=None)
    return v, c


def _usvs_num(v, k):
    try:
        return float(v.get(k))
    except (TypeError, ValueError):
        return None


def _usvs_info(now):
    t = _USVS.get("t")
    if t is None or now - t > USVS_STALE_S:
        return {"aktiv": None, "lvl": "grau", "txt": "Abschaltung: Zustand unbekannt (NUT nicht lesbar%s)" % (": %s" % _USVS["rerr"] if _USVS.get("rerr") else "")}
    v, c = _USVS["vars"], _USVS["clients"]
    ch, rt = _usvs_num(v, "battery.charge.low"), _usvs_num(v, "battery.runtime.low")
    ign = str(v.get("driver.flag.ignorelb") or "").lower() in ("enabled", "1", "yes", "on", "set")
    mon = None if c is None else any(x in ("127.0.0.1", "::1", "localhost") for x in c)
    soll = ch == USVS_CHARGE_LOW and rt == USVS_RUNTIME_LOW and ign
    if mon is None:
        return {"aktiv": None, "lvl": "gelb" if not soll else "ok", "txt": "Abschaltung bei %s %% oder %s s%s · upsmon-Status nicht lesbar" % (
            "?" if ch is None else int(ch), "?" if rt is None else int(rt), "" if ign else ", ignorelb fehlt"), "charge_low": ch, "runtime_low": rt, "ignorelb": ign}
    if not mon:
        return {"aktiv": False, "lvl": "gelb", "txt": "Abschaltung NICHT aktiv: upsmon nicht angemeldet", "charge_low": ch, "runtime_low": rt, "ignorelb": ign}
    if not soll:
        return {"aktiv": True, "lvl": "gelb", "txt": "Abschaltung aktiv, Schwellen abweichend: %s %% / %s s%s (Soll 20 %% oder 5 min)" % (
            "?" if ch is None else int(ch), "?" if rt is None else int(rt), "" if ign else ", ignorelb fehlt"), "charge_low": ch, "runtime_low": rt, "ignorelb": ign}
    return {"aktiv": True, "lvl": "ok", "txt": "Abschaltung bei 20 % oder 5 min · upsmon aktiv", "charge_low": ch, "runtime_low": rt, "ignorelb": ign}


def _usvs_api():
    from flask import jsonify
    resp = _USVS["orig_api"]()
    try:
        d = resp.get_json()
        if isinstance(d, dict):
            d["shutdown"] = _usvs_info(_usvs_time.time())
            resp = jsonify(d)
    except Exception as e:
        print("usvShutdown /api/usv:", type(e).__name__, flush=True)
    resp.headers["Cache-Control"] = "no-store"
    return resp


def _usvs_worker():
    while True:
        try:
            _usvs_read(_usvs_time.time())
        except Exception as e:
            _USVS["rerr"] = ("%s %s" % (type(e).__name__, str(e)[:60])).strip()
        _usvs_time.sleep(USVS_POLL_S)


def _selftest_usvshutdown():
    keep = dict(_USVS)
    try:
        t0 = 1793450000
        vl = ['VAR eaton battery.charge.low "20"', 'VAR eaton battery.runtime.low "300"', 'VAR eaton driver.flag.ignorelb "enabled"', 'VAR eaton ups.delay.shutdown "20"',
              'VAR eaton ups.serial "G000"', 'VAR eaton battery.charge "100"']
        v, c = _usvs_parse(vl, ["CLIENT eaton 127.0.0.1"])
        assert v == {"battery.charge.low": "20", "battery.runtime.low": "300", "driver.flag.ignorelb": "enabled", "ups.delay.shutdown": "20"} and c == ["127.0.0.1"], (v, c)
        _USVS["fake"] = lambda: (vl, ["CLIENT eaton 127.0.0.1"])
        _usvs_read(t0)
        i = _usvs_info(t0 + 10)
        assert i["aktiv"] is True and i["lvl"] == "ok" and i["txt"] == "Abschaltung bei 20 % oder 5 min · upsmon aktiv", i
        assert _usvs_info(t0 + USVS_STALE_S + 1)["aktiv"] is None
        _USVS["fake"] = lambda: (vl, [])
        _usvs_read(t0)
        assert _usvs_info(t0)["txt"] == "Abschaltung NICHT aktiv: upsmon nicht angemeldet" and _usvs_info(t0)["lvl"] == "gelb"
        _USVS["fake"] = lambda: (vl[:1] + ['VAR eaton battery.runtime.low "120"'], ["CLIENT eaton 127.0.0.1"])
        _usvs_read(t0)
        i = _usvs_info(t0)
        assert i["lvl"] == "gelb" and i["txt"].startswith("Abschaltung aktiv, Schwellen abweichend: 20 % / 120 s, ignorelb fehlt"), i
        assert "serial" not in repr(_USVS["vars"]).lower()
        _USVS["fake"] = lambda: (vl, None)
        _usvs_read(t0)
        assert _usvs_info(t0)["txt"] == "Abschaltung bei 20 % oder 300 s · upsmon-Status nicht lesbar", _usvs_info(t0)
    finally:
        _USVS.clear()
        _USVS.update(keep)
    return "usvShutdown ok (Anzeige: Abschaltung bei 20 % oder 5 min · upsmon aktiv; ohne upsmon gelb; abweichende Schwellen gelb; nur LIST VAR/CLIENT, keine Seriennummer)"


def _usvs_install():
    if not isinstance(globals().get("_USV"), dict) or not callable(globals().get("_usv_api")):
        raise RuntimeError("usvLesen fehlt")
    if not getattr(globals().get("_usva_api"), "_usva", False):
        raise RuntimeError("usvAlarm fehlt")
    vf = app.view_functions.get("usv_api")
    if vf is None:
        raise RuntimeError("/api/usv fehlt")
    if not getattr(vf, "_usvs", False):
        _USVS["orig_api"] = vf
        _usvs_api._usvs = True
        app.view_functions["usv_api"] = _usvs_api


try:
    _USVS["st"] = _selftest_usvshutdown()
    _usvs_install()
    _USVS["ok"] = True
    if __name__ == "__main__" and not _USVS["started"]:
        _USVS["started"] = True
        _usvs_th.Thread(target=_usvs_worker, name="usvShutdown", daemon=True).start()
    print("usvShutdown aktiv: %s; Faden %s" % (_USVS["st"], "laeuft (30 s)" if _USVS["started"] else "nur im Hauptprogramm"), flush=True)
except Exception as _usvs_e:
    _USVS["err"] = "%s: %s" % (type(_usvs_e).__name__, str(_usvs_e)[:200])
    print("usvShutdown Selbsttest FEHLER (%s) - ohne Abschalt-Anzeige, Dashboard laeuft weiter" % _USVS["err"], flush=True)
# ===== /usvShutdown =====
MK_C57_BDS_EOF
EXPECT_GRD="df341f961181aeb4c4182cdd76250eb0dc57cd5ccd6d1e8e078c3eea97b65a3e"
cat > "$W/guard.py" << 'MK_C57_GRD_EOF'
"""Guard commit57 (usvShutdown dashboard.py, Zeile usvShut + Info-Text in der USV-Kachel lage_pages.py, NUT-Vorlagen ups.conf/upsd.users/upsmon.conf).
  guard.py revert NEU_VERZ ALT_VERZ W   -> ALT_VERZ/{dashboard,lage_pages}.py = NEU ohne commit57 (byte-genau)
  guard.py check  ALT_VERZ NEU_VERZ W   -> Rueckbau = ALT, statische Regeln (Block nur LIST VAR/CLIENT, nie FSD/INSTCMD/SET/LOGIN), NUT-Vorlagen, Verhalten mit Attrappen, Kachel (node falls vorhanden)
  guard.py mutate ALT_VERZ NEU_VERZ W   -> Mutationstest (jede Mutation muss check scheitern lassen)
W enthaelt blk_dsh.py, edits.py und nut/{ups.conf,upsd.users,upsmon.conf}.tpl (Passwort-Platzhalter @PW@). GUARD_NO_NODE=1 schaltet den node-Test ab."""
import ast, contextlib, io, json, os, re, shutil, subprocess, sys, tempfile, time

ANCH = '\n\nif __name__ == "__main__":\n'
MK = "usvShutdown"
PREV_MK = "# ===== /usvAlarm =====\n"
CONSTS = {"USVS_CHARGE_LOW": 20, "USVS_RUNTIME_LOW": 300, "USVS_POLL_S": 30, "USVS_STALE_S": 120,
          "USVS_WANT": ("battery.charge.low", "battery.runtime.low", "driver.flag.ignorelb", "ups.delay.shutdown")}
BAD_ID = re.compile(r"^(subprocess|Popen|system|popen|eval|exec|__import__|urlopen|requests|socket|sqlite3|open|sendall|_au_offer|_usva_offer|_t4_send_m1|send_meshtastic|_hp_send|create_connection)$")
BAD_STR = ["INSTCMD", "SET VAR", "FSD", "LOGIN", "USERNAME", "PASSWORD", "PRIMARY", "upsmon -c", "shutdown -h", "poweroff", "/etc/nut", "killpower", "serial"]
NEED = ['vl = cli._list("VAR %s" % ups)', 'cl = cli._list("CLIENT %s" % ups)', 'cli = _uv_m.NutClient(port=port)', 'if __name__ == "__main__" and not _USVS["started"]:',
        'app.view_functions["usv_api"] = _usvs_api', 'resp.headers["Cache-Control"] = "no-store"', 'if m and m.group(2) in USVS_WANT:']
JS_NEED = ["  function shut(d){var s=d.shutdown||{},e=$('usvShut');if(!e)return;e.className='small'+(s.lvl==='gelb'?' usv-gelb':'');tx('usvShut',s.txt?String(s.txt).slice(0,160):'');}\n",
           "    var sh=soh(d);test(d);alarm(d);shut(d);\n", '    <div class="small" id="usvShut"></div>\n']
NUT_UPS = ["\tdriver = usbhid-ups\n", "\tport = auto\n", "\tvendorid = 0463\n", "\tpollinterval = 2\n", "\tignorelb\n", "\toverride.battery.charge.low = 20\n",
           "\toverride.battery.runtime.low = 300\n", "\toffdelay = 20\n", "\tondelay = 30\n"]
NUT_MON_RE = re.compile(r"^MONITOR eaton@127\.0\.0\.1:(\d+) 1 upsmon_local @PW@ primary$")
NUT_MON = ["MINSUPPLIES 1", 'SHUTDOWNCMD "/sbin/shutdown -h +0"', "POLLFREQ 5", "POLLFREQALERT 5", "HOSTSYNC 15", "DEADTIME 15", 'POWERDOWNFLAG "/etc/killpower"',
           "OFFDURATION 30", "RBWARNTIME 43200", "NOCOMMWARNTIME 300", "FINALDELAY 5"]
NODE_JS = r"""
const fs=require('fs');const code=fs.readFileSync(process.argv[2],'utf8');const cases=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
(async()=>{const out=[];for(const d of cases){const E={};const doc={visibilityState:'visible',getElementById:(i)=>{if(!E[i])E[i]={id:i,textContent:'',className:'',hidden:i==='usvInfo',style:{},addEventListener(){}};return E[i];},addEventListener(){}};
 const f=new Function('document','fetch','setInterval','setTimeout',code);f(doc,(u,o)=>Promise.resolve({json:()=>Promise.resolve(d)}),()=>0,()=>0);
 for(let k=0;k<4;k++)await new Promise(r=>setImmediate(r));
 out.push({shut:E.usvShut?E.usvShut.textContent:'',cls:E.usvShut?E.usvShut.className:'',alarm:E.usvAlarm?E.usvAlarm.textContent:''});}
 process.stdout.write(JSON.stringify(out));})();
"""


def rd(p):
    return open(p, encoding="utf-8").read()


def fail(m):
    print("VERSTOSS:", m)
    sys.exit(1)


def edits(W):
    g = {}
    exec(compile(rd(os.path.join(W, "edits.py")), "edits", "exec"), g)
    return g


def blk(W):
    return rd(os.path.join(W, "blk_dsh.py")).rstrip("\n") + "\n"


def revert_all(neud, W):
    E = edits(W)
    B = blk(W)
    d = rd(os.path.join(neud, "dashboard.py"))
    bx = "\n\n" + B.rstrip("\n")
    assert d.count(PREV_MK.rstrip("\n") + bx + ANCH) == 1, "Block nicht genau einmal direkt nach usvAlarm vor __main__"
    d = d.replace(bx + ANCH, ANCH, 1)
    assert "# ===== %s:" % MK not in d and "_usvs_" not in d and "USVS_" not in d, "Reste ausserhalb des Blocks"
    assert E["DSH_EDITS"] == [] and len(E["LP_EDITS"]) == 4, "Stellen: dashboard nur Block, lage_pages genau vier Stellen"
    lp = rd(os.path.join(neud, "lage_pages.py"))
    for o, n in E["LP_EDITS"]:
        assert lp.count(n) == 1, "Kachel-Stelle nicht genau einmal: %s" % n[:60]
        lp = lp.replace(n, o, 1)
    assert "usvShut" not in lp and "shut(d)" not in lp, "Kachel-Reste ausserhalb der Stellen"
    return {"dashboard.py": d, "lage_pages.py": lp}


def static_dsh(B):
    if not B.startswith("# ===== %s:" % MK) or not B.rstrip("\n").endswith("# ===== /%s =====" % MK):
        fail("Block beginnt/endet nicht mit Marker")
    try:
        T = ast.parse(B)
    except SyntaxError as e:
        fail("Syntax %s" % e)
    seen = {}
    for n in T.body:
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in CONSTS:
            seen[n.targets[0].id] = ast.literal_eval(n.value)
    for k, v in CONSTS.items():
        if seen.get(k) != v:
            fail("Konstante %s = %r (erwartet %r)" % (k, seen.get(k), v))
    st = next((n for n in T.body if isinstance(n, ast.FunctionDef) and n.name == "_selftest_usvshutdown"), None)
    stn = {id(x) for x in ast.walk(st)} if st else set()
    for n in ast.walk(T):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            names = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module]
            for x in names:
                if x not in ("re", "threading", "time", "flask"):
                    fail("Import %s nicht erlaubt" % x)
        if isinstance(n, ast.Name) and BAD_ID.match(n.id) or isinstance(n, ast.Attribute) and BAD_ID.match(n.attr):
            fail("verbotener Name %s" % (getattr(n, "id", None) or n.attr))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in stn:
            for b in BAD_STR:
                if b in n.value:
                    fail("verbotener Text %r" % b)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else (f.id if isinstance(f, ast.Name) else "")
            if nm in ("add_url_rule", "route", "after_request", "before_request", "write", "remove", "unlink"):
                fail("%s nicht erlaubt" % nm)
            if nm == "_list" and ast.unparse(n) not in ("cli._list('VAR %s' % ups)", "cli._list('CLIENT %s' % ups)"):
                fail("NUT nur LIST VAR/LIST CLIENT: %s" % ast.unparse(n)[:80])
            if nm == "Thread" and ast.unparse(n) != "_usvs_th.Thread(target=_usvs_worker, name='usvShutdown', daemon=True)":
                fail("Faden nur usvShutdown (daemon)")
    for x in NEED:
        if B.count(x) != 1:
            fail("Pflichtstelle fehlt: %s" % x[:80])
    return "dashboard.py: Marker, Konstanten (20 %, 300 s, 30 s), NUT nur LIST VAR/LIST CLIENT ueber usvLesen-Client (127.0.0.1), kein Befehl/FSD/Anmeldung, keine Route, Faden nur im Hauptprogramm"


def nut_tpl(W):
    d = os.path.join(W, "nut")
    u = rd(os.path.join(d, "ups.conf.tpl"))
    us = rd(os.path.join(d, "upsd.users.tpl"))
    mo = rd(os.path.join(d, "upsmon.conf.tpl"))
    if not u.startswith("# commit57 usvShutdown") or u.count("\n[") != 1 or "\n[eaton]\n" not in u:
        fail("ups.conf: genau ein Abschnitt [eaton] mit Kennung commit57")
    body = u[u.index("\n[eaton]\n") + 9:]
    if sorted(x for x in body.splitlines(True) if x.strip()) != sorted(NUT_UPS + ['\tdesc = "Eaton Ellipse PRO 650"\n']):
        fail("ups.conf [eaton]: Zeilen weichen ab (erwartet usbhid-ups, vendorid 0463, ignorelb, override 20/300, offdelay 20, ondelay 30)")
    act = [x.strip() for x in us.splitlines() if x.strip() and not x.lstrip().startswith("#")]
    if act != ["[upsmon_local]", "password = @PW@", "upsmon primary"]:
        fail("upsd.users: nur [upsmon_local] mit Platzhalter-Passwort und upsmon primary (%r)" % act)
    if "actions" in us.lower() or "instcmds" in us.lower():
        fail("upsd.users: keine actions/instcmds")
    act = [x.strip() for x in mo.splitlines() if x.strip() and not x.lstrip().startswith("#")]
    mon = [x for x in act if x.startswith("MONITOR")]
    if len(mon) != 1 or not NUT_MON_RE.match(mon[0]):
        fail("upsmon.conf: genau ein MONITOR eaton@127.0.0.1:PORT 1 upsmon_local @PW@ primary")
    if sorted(x for x in act if not x.startswith("MONITOR")) != sorted(NUT_MON):
        fail("upsmon.conf: Einstellungen weichen ab (%r)" % [x for x in act if x not in NUT_MON and not x.startswith("MONITOR")][:3])
    for t in (u, us, mo):
        if re.search(r"(?i)serial|0\.0\.0\.0|NOTIFYCMD|upssched", t):
            fail("NUT-Vorlagen: Seriennummer/fremde Adresse/NOTIFYCMD nicht erlaubt")
        if "@PW@" in t and t is u:
            fail("ups.conf mit Passwort")
    return "NUT-Vorlagen: ups.conf [eaton] usbhid-ups + ignorelb + override.battery.charge.low 20 + override.battery.runtime.low 300 + offdelay 20/ondelay 30; upsd.users nur upsmon_local (upsmon primary, keine Befehle); upsmon.conf MONITOR eaton@127.0.0.1 primary, SHUTDOWNCMD shutdown -h +0, POWERDOWNFLAG /etc/killpower, FINALDELAY 5"


class FakeCli:
    log = []
    vl = []
    cl = []

    def __init__(self, host="127.0.0.1", port=3493, timeout=1.5):
        FakeCli.log.append(("new", host, port))

    def _list(self, what):
        FakeCli.log.append(("list", what))
        if what.startswith("VAR "):
            return list(FakeCli.vl)
        if FakeCli.cl is None:
            raise RuntimeError("ACCESS-DENIED")
        return list(FakeCli.cl)

    def close(self):
        FakeCli.log.append(("close",))


class FakeMgr:
    port = 3494
    ups = "eaton"

    def snapshot(self):
        return {"mode": "NETZ", "ok": True}


def beh(B):
    import flask
    import types
    for name in ("g57test", "__main__"):
        app = flask.Flask("g57" + name)

        def usv_api():
            r = flask.jsonify({"mode": "NETZ", "ok": True, "alarm": {"txt": "Ansage: bereit"}})
            r.headers["Cache-Control"] = "no-store"
            return r
        usv_api._usva = True
        app.add_url_rule("/api/usv", endpoint="usv_api", view_func=usv_api, methods=["GET"])
        g = {"__name__": name, "app": app, "_USV": {"mgr": FakeMgr()}, "_usv_api": lambda: None, "_usva_api": usv_api,
             "_uv_m": types.SimpleNamespace(NutClient=FakeCli)}
        src = B.replace('_usvs_th.Thread(target=_usvs_worker, name="usvShutdown", daemon=True).start()', '_USVS.update(thr=1)') if name == "__main__" else B
        o = io.StringIO()
        with contextlib.redirect_stdout(o):
            exec(compile(src, "blk", "exec"), g)
        txt = o.getvalue()
        assert "usvShutdown aktiv: usvShutdown ok (" in txt, txt[:300]
        S = g["_USVS"]
        assert S["ok"] and S["started"] == (name == "__main__") and (S.get("thr") == 1) == (name == "__main__"), "Faden nur im Hauptprogramm"
        rules = sorted(r.rule for r in app.url_map.iter_rules() if r.rule != "/static/<path:filename>")
        assert rules == ["/api/usv"], rules
    FakeCli.log = []
    FakeCli.vl = ['VAR eaton battery.charge.low "20"', 'VAR eaton battery.runtime.low "300"', 'VAR eaton driver.flag.ignorelb "enabled"', 'VAR eaton ups.serial "G999GUARD"', 'VAR eaton ups.delay.shutdown "20"']
    FakeCli.cl = ["CLIENT eaton 127.0.0.1"]
    now = time.time()
    g["_usvs_read"](now)
    assert FakeCli.log == [("new", "127.0.0.1", 3494), ("list", "VAR eaton"), ("list", "CLIENT eaton"), ("close",)], FakeCli.log
    with app.test_client() as c:
        r = c.get("/api/usv")
        j = r.get_json()
    assert r.headers.get("Cache-Control") == "no-store" and j["alarm"]["txt"] == "Ansage: bereit", j
    sd = j["shutdown"]
    assert sd["txt"] == "Abschaltung bei 20 % oder 5 min · upsmon aktiv" and sd["lvl"] == "ok" and sd["aktiv"] is True and "G999" not in json.dumps(j), sd
    FakeCli.cl = []
    g["_usvs_read"](now)
    assert g["_usvs_info"](now)["txt"] == "Abschaltung NICHT aktiv: upsmon nicht angemeldet"
    FakeCli.cl = ["CLIENT eaton 192.168.178.20"]
    g["_usvs_read"](now)
    assert g["_usvs_info"](now)["aktiv"] is False, "nur lokales upsmon zaehlt"
    FakeCli.cl = None
    g["_usvs_read"](now)
    assert g["_usvs_info"](now)["txt"] == "Abschaltung bei 20 % oder 300 s · upsmon-Status nicht lesbar"
    FakeCli.cl = ["CLIENT eaton 127.0.0.1"]
    FakeCli.vl = ['VAR eaton battery.charge.low "10"', 'VAR eaton battery.runtime.low "120"']
    g["_usvs_read"](now)
    i = g["_usvs_info"](now)
    assert i["lvl"] == "gelb" and "abweichend: 10 % / 120 s, ignorelb fehlt" in i["txt"], i
    assert g["_usvs_info"](now + 121)["aktiv"] is None and "unbekannt" in g["_usvs_info"](now + 121)["txt"]
    g2 = {"__name__": "x", "app": flask.Flask("g57b"), "_USV": {"mgr": None}, "_usv_api": lambda: None}
    o = io.StringIO()
    with contextlib.redirect_stdout(o):
        exec(compile(B, "blk", "exec"), g2)
    assert "usvShutdown Selbsttest FEHLER" in o.getvalue() and "Dashboard laeuft weiter" in o.getvalue()
    g3 = {"__name__": "x", "app": flask.Flask("g57c"), "_USV": {"mgr": FakeMgr()}, "_usv_api": lambda: None, "_uv_m": types.SimpleNamespace(NutClient=FakeCli)}
    o = io.StringIO()
    with contextlib.redirect_stdout(o):
        exec(compile(B, "blk", "exec"), g3)
    assert "usvAlarm fehlt" in o.getvalue() and not g3["_USVS"]["ok"] and "usv_api" not in g3["app"].view_functions, o.getvalue()[:200]
    return ("Verhalten: liest ueber usvLesen-Port nur LIST VAR + LIST CLIENT und schliesst, /api/usv mit shutdown (20 % oder 5 min · upsmon aktiv) + no-store, ohne upsmon/fremder Client gelb 'NICHT aktiv', "
            "Schwellen abweichend gelb, nach 120 s unbekannt, keine Seriennummer, Faden nur im Hauptprogramm, ohne usvAlarm Fehlermeldung ohne Absturz")


def tile(neud):
    lp = rd(os.path.join(neud, "lage_pages.py"))
    i = lp.index("def page_lokale_energie(")
    j = lp.find("\ndef ", i + 10)
    fn = lp[i:j if j > 0 else len(lp)]
    for x in JS_NEED:
        if fn.count(x) != 1:
            fail("Kachel: Pflichtstelle fehlt %s" % x.strip()[:60])
    if fn.count("innerHTML") or "Kein Herunterfahren." in fn:
        fail("Kachel: innerHTML oder alter Info-Text")
    if "Herunterfahren: upsmon fährt den Pi im Akkubetrieb bei 20 % Ladung oder 5 min Restlaufzeit sauber herunter" not in fn:
        fail("Kachel: Info-Text fehlt")
    k = fn.index("<script>/* usvKachel */") + 8
    return fn[k:fn.index("</script>", k)]


def node_test(js):
    nd = shutil.which("node") or shutil.which("nodejs")
    if os.environ.get("GUARD_NO_NODE") or not nd:
        return "Kachel statisch (node fehlt)"
    cases = [{"ok": True, "mode": "NETZ", "alarm": {"txt": "Ansage: bereit"}, "shutdown": {"lvl": "ok", "txt": "Abschaltung bei 20 % oder 5 min · upsmon aktiv"}},
             {"ok": True, "mode": "NETZ", "shutdown": {"lvl": "gelb", "txt": "Abschaltung NICHT aktiv: upsmon nicht angemeldet"}},
             {"ok": False, "mode": "KEINE_DATEN"}]
    d = tempfile.mkdtemp(prefix="g57n")
    try:
        for n, t in (("t.js", NODE_JS), ("k.js", js), ("c.json", json.dumps(cases))):
            open(os.path.join(d, n), "w", encoding="utf-8").write(t)
        o = subprocess.run([nd, os.path.join(d, "t.js"), os.path.join(d, "k.js"), os.path.join(d, "c.json")], capture_output=True, text=True, timeout=60)
        if o.returncode:
            fail("Kachel-Skript (node): %s" % (o.stderr.strip().splitlines() or ["?"])[-1][:200])
        r = json.loads(o.stdout)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    assert r[0]["shut"] == "Abschaltung bei 20 % oder 5 min · upsmon aktiv" and r[0]["cls"] == "small" and r[0]["alarm"] == "Ansage: bereit", r[0]
    assert r[1]["shut"].startswith("Abschaltung NICHT aktiv") and r[1]["cls"] == "small usv-gelb", r[1]
    assert r[2]["shut"] == "", r[2]
    return "Kachel mit node: Zeile Abschaltung (ok normal, NICHT aktiv gelb, leer ohne Daten)"


def check(altd, neud, W):
    try:
        rv = revert_all(neud, W)
    except AssertionError as e:
        fail("Rueckbau: %s" % e)
    for fn, t in rv.items():
        if t != rd(os.path.join(altd, fn)):
            fail("Rueckbau %s != Basis (Aenderung ausserhalb Block/Kachel-Stellen)" % fn)
    B = blk(W)
    s1 = static_dsh(B)
    s2 = nut_tpl(W)
    js = tile(neud)
    try:
        b1 = beh(B)
        b2 = node_test(js)
    except AssertionError as ex:
        fail("Verhalten: %s" % str(ex)[:600])
    except SystemExit:
        raise
    except Exception as ex:
        fail("Verhalten (%s): %s" % (type(ex).__name__, str(ex)[:400]))
    print("Guard commit57 ok: Rueckbau byte-genau = Basis (dashboard.py ein Block nach usvAlarm, lage_pages.py vier Stellen); %s; %s; %s; %s" % (s1, s2, b1, b2))


MUTS = [
    ("dsh", "USVS_CHARGE_LOW = 20\n", "USVS_CHARGE_LOW = 10\n"), ("dsh", "USVS_RUNTIME_LOW = 300\n", "USVS_RUNTIME_LOW = 120\n"),
    ("dsh", 'vl = cli._list("VAR %s" % ups)', 'vl = cli._list("VAR %s" % ups) + cli._list("CMD %s" % ups)'),
    ("dsh", 'if m and m.group(2) in USVS_WANT:', 'if m:'),
    ("dsh", '    mon = None if c is None else any(x in ("127.0.0.1", "::1", "localhost") for x in c)', '    mon = None if c is None else bool(c)'),
    ("dsh", "    soll = ch == USVS_CHARGE_LOW and rt == USVS_RUNTIME_LOW and ign\n", "    soll = True\n"),
    ("dsh", "        finally:\n            cli.close()\n", "        finally:\n            pass\n"),
    ("dsh", 'if __name__ == "__main__" and not _USVS["started"]:', 'if not _USVS["started"]:'),
    ("dsh", '            d["shutdown"] = _usvs_info(_usvs_time.time())\n', '            pass\n'),
    ("dsh", '    resp.headers["Cache-Control"] = "no-store"\n', ''),
    ("dsh", "    if t is None or now - t > USVS_STALE_S:", "    if t is None:"),
    ("dsh", "import time as _usvs_time\n", "import time as _usvs_time\nimport subprocess\n"),
    ("dsh", '    if not getattr(globals().get("_usva_api"), "_usva", False):\n        raise RuntimeError("usvAlarm fehlt")\n', ''),
    ("lp", "e.className='small'+(s.lvl==='gelb'?' usv-gelb':'');", ""), ("lp", "tx('usvShut',s.txt?String(s.txt).slice(0,160):'')", "e.innerHTML=s.txt||''"),
    ("lp", "    var sh=soh(d);test(d);alarm(d);shut(d);\n", "    var sh=soh(d);test(d);alarm(d);\n"),
    ("lp", "bei 20 % Ladung oder 5 min Restlaufzeit", "bei 10 % Ladung"),
    ("nut", "ups.conf.tpl", "\tignorelb\n", ""), ("nut", "ups.conf.tpl", "override.battery.charge.low = 20", "override.battery.charge.low = 10"),
    ("nut", "ups.conf.tpl", "override.battery.runtime.low = 300", "override.battery.runtime.low = 30"),
    ("nut", "ups.conf.tpl", "\toffdelay = 20\n", "\toffdelay = 0\n"), ("nut", "ups.conf.tpl", "\tvendorid = 0463\n", ""),
    ("nut", "upsd.users.tpl", "\tupsmon primary\n", "\tupsmon primary\n\tinstcmds = ALL\n"), ("nut", "upsd.users.tpl", "\tpassword = @PW@\n", "\tpassword = geheim\n"),
    ("nut", "upsmon.conf.tpl", " primary\n", " secondary\n"), ("nut", "upsmon.conf.tpl", "MONITOR eaton@127.0.0.1:", "MONITOR eaton@0.0.0.0:"),
    ("nut", "upsmon.conf.tpl", 'SHUTDOWNCMD "/sbin/shutdown -h +0"', 'SHUTDOWNCMD "/sbin/reboot"'), ("nut", "upsmon.conf.tpl", 'POWERDOWNFLAG "/etc/killpower"\n', ""),
    ("nut", "upsmon.conf.tpl", "FINALDELAY 5\n", "FINALDELAY 120\n"), ("nut", "upsmon.conf.tpl", "MINSUPPLIES 1\n", "MINSUPPLIES 0\n"),
    ("nut", "upsmon.conf.tpl", "FINALDELAY 5\n", "FINALDELAY 5\nNOTIFYCMD /usr/bin/x\n"),
]


def mutate(altd, neud, W):
    me = os.path.abspath(__file__)
    d = tempfile.mkdtemp()
    caught = missed = 0
    E = edits(W)
    etxt0 = rd(os.path.join(W, "edits.py"))
    nut0 = {f: rd(os.path.join(W, "nut", f)) for f in ("ups.conf.tpl", "upsd.users.tpl", "upsmon.conf.tpl")}
    try:
        def run(files, wfiles):
            nd, wd = os.path.join(d, "n"), os.path.join(d, "w")
            for x in (nd, wd):
                shutil.rmtree(x, ignore_errors=True)
                os.makedirs(x)
            os.makedirs(os.path.join(wd, "nut"))
            for fn, t in files.items():
                open(os.path.join(nd, fn), "w", encoding="utf-8").write(t)
            for fn, t in wfiles.items():
                open(os.path.join(wd, fn), "w", encoding="utf-8").write(t)
            o = subprocess.run([sys.executable, me, "check", altd, nd, wd], capture_output=True, text=True, timeout=900)
            return o.returncode != 0, [x[:160] for x in ((o.stdout + o.stderr).strip().splitlines() or [""])[-1:]]
        files = {fn: rd(os.path.join(neud, fn)) for fn in ("dashboard.py", "lage_pages.py")}
        wf = {"blk_dsh.py": blk(W), "edits.py": etxt0}
        wf.update({"nut/" + f: t for f, t in nut0.items()})
        bad, msg = run(files, wf)
        if bad:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        cases = []
        for m in MUTS:
            fm, wm = dict(files), dict(wf)
            if m[0] == "nut":
                _, f, a, b = m
                if nut0[f].count(a) < 1:
                    print("UEBERSEHEN (Mutation passt nicht): nut %s %r" % (f, a[:60])); missed += 1; continue
                wm["nut/" + f] = nut0[f].replace(a, b, 1)
                cases.append(("nut %s %s" % (f, a[:40]), fm, wm))
                continue
            k, a, b = m
            if k == "dsh":
                B = wf["blk_dsh.py"]
                if B.count(a) < 1:
                    print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70])); missed += 1; continue
                bm = B.replace(a, b, 1)
                wm["blk_dsh.py"] = bm
                fm["dashboard.py"] = files["dashboard.py"].replace("\n\n" + B.rstrip("\n") + ANCH, "\n\n" + bm.rstrip("\n") + ANCH, 1)
            else:
                hit = [i for i, (o, n) in enumerate(E["LP_EDITS"]) if a in n]
                if not hit:
                    print("UEBERSEHEN (Mutation passt nicht): %s %r" % (k, a[:70])); missed += 1; continue
                o, n = E["LP_EDITS"][hit[0]]
                nm = n.replace(a, b, 1)
                fm["lage_pages.py"] = files["lage_pages.py"].replace(n, nm, 1)
                wm["edits.py"] = etxt0.replace(repr(n)[1:-1], repr(nm)[1:-1], 1)
                assert wm["edits.py"] != etxt0, a
            cases.append(("%s %s" % (k, a[:50]), fm, wm))
        f = dict(files); f["dashboard.py"] = files["dashboard.py"].replace("T4_SAY_MAX = 600", "T4_SAY_MAX = 601", 1); assert f["dashboard.py"] != files["dashboard.py"]
        cases.append(("Zeile ausserhalb dashboard", f, wf))
        f = dict(files); f["lage_pages.py"] = files["lage_pages.py"].replace("<title>Lokale Energie</title>", "<title>Lokale Energie!</title>", 1); assert f["lage_pages.py"] != files["lage_pages.py"]
        cases.append(("Zeile ausserhalb Kachel", f, wf))
        f = dict(files); f["dashboard.py"] = files["dashboard.py"].replace(ANCH, "\n\n" + wf["blk_dsh.py"].rstrip("\n") + ANCH, 1)
        cases.append(("Block doppelt", f, wf))
        for name, fm, wm in cases:
            bad, msg = run(fm, wm)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest commit57: %d erkannt, %d uebersehen%s" % ("OK" if missed == 0 else "FEHLER", caught, missed,
          " (ohne node)" if os.environ.get("GUARD_NO_NODE") or not (shutil.which("node") or shutil.which("nodejs")) else " (mit node)"))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    md = sys.argv[1]
    if md == "revert":
        os.makedirs(sys.argv[3], exist_ok=True)
        for fn, t in revert_all(sys.argv[2], sys.argv[4]).items():
            open(os.path.join(sys.argv[3], fn), "w", encoding="utf-8").write(t)
    elif md == "check":
        check(*sys.argv[2:5])
    elif md == "mutate":
        mutate(*sys.argv[2:5])
MK_C57_GRD_EOF
trap 'ec=$?; rm -f "$W"/nut/*.real 2>/dev/null; if [[ $ec -ne 0 && -n "$ERRLN" ]]; then echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE$([[ "$PHASE" == vorher ]] && echo " - es wurde nichts geaendert")"; fi' EXIT
EMB="patch.py:$EXPECT_PAT edits.py:$EXPECT_EDI G/blk_dsh.py:$EXPECT_BDS guard.py:$EXPECT_GRD"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
cp "$W/edits.py" "$W/G/edits.py"
echo "OK eingebettete Dateien geprueft (4: Patcher, Kachel-Stellen, Block usvShutdown, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "$2"; return; }; shift 2; done; echo UNBEKANNT; }
# ---------- 1) Basis: dashboard.py + lage_pages.py gemeinsam alt oder neu; ups_manager.py wie nach commit55/56 ----------
for x in "$F" "$FL" "$FS" "$FE"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS"); E16=$(s16 "$FE")
U16=fehlt; [[ -e "$FU" ]] && U16=$(s16 "$FU")
SD=$(lbl "$D16" "$KNOWN_D16" alt "$KNOWN_D16N" neu); SL=$(lbl "$L16" "$KNOWN_L16" alt "$KNOWN_L16N" neu)
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit56, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 ($(wc -l < "$FL") Zeilen) - $SL (alt $KNOWN_L16, neu $KNOWN_L16N)"
echo "Basis ups_manager.py $U16 - $([[ "$U16" == "$KNOWN_U16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo "ABWEICHUNG (erwartet $KNOWN_U16)")"
echo "Basis prepper_sdr.py sha16 $S16, prepper_evlog.py sha16 $E16 - $([[ "$S16" == "$KNOWN_S16" && "$E16" == "$KNOWN_E16" ]] && echo "wie erwartet (bleiben unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C55" || "$L16" == "$KNOWN_L16_C55" ]]; then
  echo "STOP: erst commit56 anwenden - der Projektordner ist noch der Stand nach commit55 (dashboard.py $D16, lage_pages.py $L16); commit57 braucht dashboard.py $KNOWN_D16 und lage_pages.py $KNOWN_L16 (nach commit56) - nichts geaendert."
  exit 1
fi
if [[ "$D16" == "$KNOWN_D16_C54" || "$U16" == fehlt ]]; then
  echo "STOP: erst commit55 und commit56 anwenden - der Projektordner ist noch ein Stand vor commit55 (dashboard.py $D16, ups_manager.py $U16) - nichts geaendert."
  exit 1
fi
for v in "dashboard.py:$SD:$D16" "lage_pages.py:$SL:$L16"; do
  IFS=: read -r fn st hh <<< "$v"
  if [[ "$st" == UNBEKANNT ]]; then
    echo "STOP: $fn weicht vom erwarteten Stand ab (sha16 $hh) - nichts geaendert."
    echo "      commit57 passt nur auf den Stand nach commit56. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
    exit 1
  fi
done
if [[ "$SD$SL" != altalt && "$SD$SL" != neuneu ]]; then
  echo "STOP: Mischstand (dashboard.py $SD, lage_pages.py $SL) - erwartet beide alt oder beide neu - nichts geaendert."
  for x in "$F" "$FL"; do LBX=$({ ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LBX" ]] && echo "      Sicherung vorhanden: $LBX ($(s16 "$LBX"))"; done
  echo "      Ein abgebrochener Lauf? Bitte diese Ausgabe an Grok schicken (nichts von Hand kopieren)."
  exit 1
fi
[[ "$U16" == "$KNOWN_U16" ]] || stop "ups_manager.py ($U16) ist nicht der erwartete Stand ($KNOWN_U16)"
[[ "$S16" == "$KNOWN_S16" && "$E16" == "$KNOWN_E16" ]] || stop "prepper_sdr.py ($S16) oder prepper_evlog.py ($E16) ist nicht der erwartete Stand ($KNOWN_S16 / $KNOWN_E16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach qrmRun usvLesen usvAlarm; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" && -w "$FL" ]] || stop "Projektordner, dashboard.py oder lage_pages.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug/jinja2 nicht"
# ---------- 1b) NUT-Zustand (nur lesen) ----------
NG=nut; getent group nut >/dev/null 2>&1 || NG=root
cat > "$W/nut/nut.conf.c55" << MK_C57_NUTCONF
$NUT_MARK55: NUT nur lokal (Treiber + upsd auf 127.0.0.1), upsmon NICHT aktiv - kein Herunterfahren (kommt erst mit commit57)
MODE=standalone
MK_C57_NUTCONF
cat > "$W/nut/ups.conf.c55" << MK_C57_UPS55
$NUT_MARK55: Eaton Ellipse PRO 650 VA / 400 W (ELP650DIN) per USB, nur lesen; kein ignorelb/override (kommt erst mit commit57)
maxretry = 3

[$NUT_UPS]
	driver = usbhid-ups
	port = auto
	vendorid = 0463
	pollinterval = 2
	desc = "Eaton Ellipse PRO 650"
MK_C57_UPS55
cat > "$W/nut/upsd.conf.c55" << MK_C57_UPSDCONF
$NUT_MARK55: upsd nur auf 127.0.0.1 - nichts nach aussen, kein Benutzer noetig (Lesen ohne Anmeldung)
LISTEN 127.0.0.1 $NUT_PORT
MK_C57_UPSDCONF
cat > "$W/G/nut/ups.conf.tpl" << MK_C57_UPSCONF
$NUT_MARK: Eaton Ellipse PRO 650 VA / 400 W (ELP650DIN) per USB; LB selbst bestimmt (ignorelb): Ladung unter 20 % oder Restlaufzeit unter 300 s -> upsmon faehrt den Pi herunter
maxretry = 3

[$NUT_UPS]
	driver = usbhid-ups
	port = auto
	vendorid = 0463
	pollinterval = 2
	desc = "Eaton Ellipse PRO 650"
	ignorelb
	override.battery.charge.low = 20
	override.battery.runtime.low = 300
	offdelay = 20
	ondelay = 30
MK_C57_UPSCONF
cat > "$W/G/nut/upsd.users.tpl" << MK_C57_USERS
$NUT_MARK: einziger Benutzer = upsmon auf diesem Pi (Passwort lokal zufaellig erzeugt, nirgends ausgegeben, keine Befehle)
[upsmon_local]
	password = @PW@
	upsmon primary
MK_C57_USERS
cat > "$W/G/nut/upsmon.conf.tpl" << MK_C57_UPSMON
$NUT_MARK: upsmon primary fuer die USV am eigenen USB - Akkubetrieb + LB (20 % oder 300 s, siehe ups.conf) -> Pi faehrt herunter, danach killpower (nutshutdown)
MONITOR $NUT_UPS@127.0.0.1:$NUT_PORT 1 upsmon_local @PW@ primary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG "/etc/killpower"
OFFDURATION 30
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
MK_C57_UPSMON
cat > "$W/nutcmp.py" << 'MK_C57_NUTCMP'
"""nutcmp.py VORLAGEN AKTUELL -> fertig | alt | anders57 | anders (gibt nie ein Passwort aus)"""
import os, re, sys
t, c = sys.argv[1], sys.argv[2]
def rd(d, f):
    try:
        return open(os.path.join(d, f), encoding="utf-8").read()
    except OSError:
        return None
def pw(tpl, txt):
    if tpl is None or txt is None:
        return None
    m = re.fullmatch(re.escape(tpl).replace(re.escape("@PW@"), "([0-9a-f]{32})"), txt)
    return m.group(1) if m else None
up, us, mo = rd(c, "ups.conf"), rd(c, "upsd.users"), rd(c, "upsmon.conf")
p1, p2 = pw(rd(t, "upsd.users.tpl"), us), pw(rd(t, "upsmon.conf.tpl"), mo)
if up == rd(t, "ups.conf.tpl") and p1 and p1 == p2:
    print("fertig")
elif up == rd(t, "ups.conf.c55") and not re.search(r"(?m)^\s*MONITOR\s", mo or "") and not re.search(r"(?m)^\s*\[", us or ""):
    print("alt")
elif any("# commit57 usvShutdown" in (x or "") for x in (up, us, mo)):
    print("anders57")
else:
    print("anders")
MK_C57_NUTCMP
cp "$W/nut/ups.conf.c55" "$W/G/nut/ups.conf.c55"
NUTF="nut.conf ups.conf upsd.conf upsd.users upsmon.conf"
pkgok() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]; }
nutget() { # kopiert nut.conf/ups.conf/upsd.conf nach $W/cur (fehlt = keine Datei); /etc/nut ist oft nur fuer root/nut lesbar -> sudo (im Trockenlauf nur mit gueltigem Ticket); NUTRD=0 wenn nicht lesbar
  local f su=0; NUTRD=1; rm -rf "$W/cur"; mkdir -p "$W/cur"
  [[ -e "$NUT_ETC" ]] || return 0
  [[ -r "$NUT_ETC" && -x "$NUT_ETC" ]] || su=1
  for f in $NUTF; do [[ "$su" == 0 && -e "$NUT_ETC/$f" && ! -r "$NUT_ETC/$f" ]] && su=1; done
  if [[ "$su" == 1 ]]; then
    if [[ "$DRY" == 1 ]] && ! sudo -n true 2>/dev/null; then NUTRD=0; return 0; fi
    for f in $NUTF; do if sudo test -e "$NUT_ETC/$f"; then sudo cat "$NUT_ETC/$f" > "$W/cur/$f" || NUTRD=0; fi; done
  else
    for f in $NUTF; do if [[ -e "$NUT_ETC/$f" ]]; then cat "$NUT_ETC/$f" > "$W/cur/$f" || NUTRD=0; fi; done
  fi
  return 0; }
P1=0; P2=0; pkgok nut-server && P1=1; pkgok nut-client && P2=1
[[ "$P1$P2" == 11 ]] || stop "nut-server/nut-client nicht installiert - erst commit55 anwenden"
NSU=0; if [[ -e "$NUT_ETC" ]]; then [[ -r "$NUT_ETC" && -x "$NUT_ETC" ]] || NSU=1; for f in $NUTF; do [[ -e "$NUT_ETC/$f" && ! -r "$NUT_ETC/$f" ]] && NSU=1; done; fi
if [[ "$DRY" == 0 && "$NSU" == 1 ]]; then
  echo "$NUT_ETC ist nur fuer root lesbar - sudo-Passwort zum Lesen der NUT-Einrichtung:"
  sudo -v || stop "sudo -v fehlgeschlagen - $NUT_ETC nicht lesbar"
fi
nutcmp() { python3 "$W/nutcmp.py" "$W/G/nut" "$W/cur" 2>/dev/null || echo fehler; }
nutget
if [[ "$NUTRD" == 0 ]]; then
  [[ "$DRY" == 1 ]] || stop "$NUT_ETC nicht lesbar (auch mit sudo nicht)"
  NUTST=unklar
else
  cmp -s "$W/nut/nut.conf.c55" "$W/cur/nut.conf" && cmp -s "$W/nut/upsd.conf.c55" "$W/cur/upsd.conf" || stop "nut.conf/upsd.conf sind nicht der Stand von commit55 (MODE=standalone, LISTEN 127.0.0.1 $NUT_PORT) - erst commit55 anwenden oder diese Ausgabe an Grok schicken"
  NUTST=$(nutcmp)
  case "$NUTST" in
    fertig|alt) ;;
    anders57) stop "NUT-Einrichtung von commit57 ist da, aber veraendert (ups.conf/upsd.users/upsmon.conf ungleich Soll) - bitte diese Ausgabe an Grok schicken";;
    *) echo "STOP: NUT ist anders eingerichtet als nach commit55 (ups.conf nicht von commit55, oder upsd.users/upsmon.conf haben schon Benutzer/MONITOR) - nichts geaendert."
       echo "      Abschnitte in upsd.users: $(grep -hE '^[[:space:]]*\[' "$W/cur/upsd.users" 2>/dev/null | tr -d ' \t' | tr '\n' ' ')- MONITOR-Zeilen in upsmon.conf: $(grep -cE '^[[:space:]]*MONITOR' "$W/cur/upsmon.conf" 2>/dev/null || true) - bitte diese Ausgabe an Grok schicken."
       exit 1;;
  esac
fi
rm -rf "$W/cur"
upsst() { upsc "$NUT_UPS@127.0.0.1:$NUT_PORT" ups.status 2>/dev/null | head -1 || true; }
upsv() { upsc "$NUT_UPS@127.0.0.1:$NUT_PORT" 2>/dev/null | grep -iv serial | sed -n "s/^$1: //p" | head -1 || true; }
upscl() { upsc -c "$NUT_UPS@127.0.0.1:$NUT_PORT" 2>/dev/null | grep -cE '^(127\.0\.0\.1|::1|localhost)$' || true; }
lsn() { ss -ltnH 2>/dev/null | awk -v p=":$NUT_PORT" '{a=$4; if (substr(a, length(a) - length(p) + 1) == p) print a}' | sort -u || true; }
ST0=$(upsst)
echo "USV jetzt: Status ${ST0:-unbekannt}, Ladung $(upsv battery.charge) %, Laufzeit $(upsv battery.runtime) s, Schwellen jetzt $(upsv battery.charge.low) % / $(upsv battery.runtime.low) s, ignorelb $(upsv driver.flag.ignorelb | grep . || echo aus), ups.delay.shutdown $(upsv ups.delay.shutdown) s"
if [[ ! "$ST0" =~ ^OL ]] || [[ " $ST0 " == *" LB "* || " $ST0 " == *" OB "* || " $ST0 " == *" FSD "* ]]; then
  [[ "$DRY" == 1 ]] && echo "HINWEIS USV nicht im Netzbetrieb ($ST0) - ein echter Lauf wuerde jetzt stoppen" || stop "USV nicht im reinen Netzbetrieb (Status '${ST0:-leer}') - commit57 nur bei Netzbetrieb einspielen"
fi
UMON=$(command -v upsmon 2>/dev/null || true); [[ -z "$UMON" && -x /usr/sbin/upsmon ]] && UMON=/usr/sbin/upsmon
[[ -n "$UMON" || "$SIM" == 1 ]] || stop "upsmon fehlt (Paket nut-client) - erst commit55 anwenden"
if [[ -n "$NUTSHUT" ]]; then echo "OK killpower-Weg vorhanden: $NUTSHUT (Debian nut-server; schaltet die USV am Ende des Herunterfahrens ab, nur wenn upsmon den Merker $KPF gesetzt hat)"
else stop "nutshutdown fehlt (/usr/lib/systemd/system-shutdown/nutshutdown) - ohne killpower bliebe der Pi nach Netzrueckkehr womoeglich aus"; fi
if [[ "$NUTST" != fertig && -e "$KPF" ]]; then stop "killpower-Merker $KPF liegt schon (Altlast) - beim naechsten Herunterfahren wuerde die USV abschalten; bitte diese Ausgabe an Grok schicken"; fi
case "$NUTST" in
  unklar) echo "HINWEIS $NUT_ETC nur mit sudo lesbar - der Trockenlauf vergleicht die Einrichtung nicht (der echte Lauf prueft mit sudo)";;
  fertig) echo "OK NUT schon wie commit57 eingerichtet (ignorelb, 20 % / 300 s, upsmon_local, MONITOR primary) - Phase A: nur pruefen";;
  alt)    echo "OK NUT wie nach commit55 (nur lesen, upsmon aus) - Phase A richtet upsmon + Schwellen ein";;
esac
# ---- perfWsgi muss laufen (waitress, 8 Arbeitsfaeden) ----
wsst() { "${CURL[@]}" "$B/api/perfwsgi/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("server"), d.get("workers"))' 2>/dev/null || echo "? ?"; }
PCSV=$(wsst)
if [[ "$PCSV" == "waitress 8" ]]; then echo "OK perfWsgi laeuft (waitress, 8 Arbeitsfaeden)"
elif [[ "$DRY" == 1 ]]; then echo "HINWEIS perfWsgi-Status nicht lesbar ($PCSV) - im Trockenlauf unerheblich"
else stop "perfWsgi-Status $PCSV statt 'waitress 8' - Dashboard laeuft nicht wie erwartet"; fi
# ---- Neustart-Sperre HH:55-HH:04 (Berlin); Vorlauf 15 min mit apt, sonst 5 min ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C57_FAKE_HM:-}" && "$SIM" == 1 ]]; then hm="$C57_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
NEED=0; [[ "$STATE" == alt ]] && NEED=1
NUTNEED=0; [[ "$NUTST" != fertig ]] && NUTNEED=1
LA=300; [[ "$NUTST" != fertig ]] && LA=600
rscheck() { local s0 s1 la="$2" k x; s0=$(rssec 0); s1=$(rssec "$la"); k=0
  for ((x = 0; x <= la; x += 60)); do rswin "$(rssec "$x")" && k=1; done
  if [[ "$k" == 1 ]] || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04, Vorlauf $((la / 60)) min) - frei ab HH:05"
    elif [[ "$NEED" == 0 && "$NUTNEED" == 0 ]]; then echo "OK Neustart-Sperre: commit57 ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - Sperre HH:55-HH:04, dieser Lauf braucht bis zu $((la / 60)) min (Start also bis HH:$(printf '%02d' $(( 55 - la / 60 ))) Uhr) - bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04, auch in $((la / 60)) min ($1)"; fi; }
rscheck "Vorpruefung" "$LA"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" || "$f" == "$FL" || "$f" == "$FU" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher; auch prepper_sdr.py)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
PT() { python3 "$W/patch.py" "$1" "$2" "$3" "$4" "$5" "$W/edits.py"; }
PT usvShutdown dsh "$F" "$W/work/dashboard.py" "$W/G/blk_dsh.py" > "$W/q1.log" || { cat "$W/q1.log"; stop "dashboard.py: Stelle fuer usvShutdown nicht eindeutig"; }
PT usvShutdown lp "$FL" "$W/work/lage_pages.py" - > "$W/q2.log" || { cat "$W/q2.log"; stop "lage_pages.py: Stellen fuer die USV-Kachel nicht eindeutig"; }
for v in "dashboard.py:$KNOWN_D16N" "lage_pages.py:$KNOWN_L16N"; do
  IFS=: read -r fn hh <<< "$v"
  [[ "$(s16 "$W/work/$fn")" == "$hh" ]] || stop "Ergebnis $fn $(s16 "$W/work/$fn") statt $hh (Zielstand nicht erreicht)"
done
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(cat "$W/q1.log")), lage_pages.py $KNOWN_L16N ($(cat "$W/q2.log"))"
PT x dsh "$W/work/dashboard.py" "$W/work/x1" "$W/G/blk_dsh.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
PT x lp "$W/work/lage_pages.py" "$W/work/x2" - > /dev/null && cmp -s "$W/work/lage_pages.py" "$W/work/x2" || stop "lage_pages.py nicht idempotent"
rm -f "$W/work/x1" "$W/work/x2"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/patch.py" "$W/edits.py" "$W/G/blk_dsh.py" "$W/guard.py" "$W/nutcmp.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/G" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: commit57 im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" && "$(s16 "$W/alt/lage_pages.py")" == "$KNOWN_L16" ]] || stop "Guard: Stand ohne commit57 ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt" "$W/neu" "$W/G" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "Guard commit57 meldet Verstoss"; }
grep "^Guard commit57" "$W/g.log" | cut -c1-2400
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Kachel-Skript hier statisch geprueft; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C57_SIM_NOMUT:-}" && "$SIM" == 1 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt" "$W/neu" "$W/G" > "$W/gm.log" 2>&1 || { cat "$W/gm.log"; stop "Mutationstest commit57: eine Verfehlung wurde nicht erkannt"; }
[[ "$MUTS" == 0 ]] || grep -E "^OK Mutationstest" "$W/gm.log"
# ---------- 3) Zustand vorher (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local i; for i in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte /lokale-energie)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
UAPI0=$(code "$B/api/usv")
t4st() { "${CURL[@]}" "$B/api/t4/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - - -"); sys.exit(0)
t = d.get("tick") or {}
print(int(bool(d.get("ok"))), int(t.get("n") or 0), int(bool(t.get("thread"))), str(((d.get("hb") or {}).get("last") or {}).get("text") or "-").replace(" ", "_")[:60])' 2>/dev/null || echo "FEHLER - - -"; }
read -r T4OK0 T4N0 T4TH0 HBL0 <<< "$(t4st)"
if [[ "$DRY" != 1 ]]; then [[ "$T4OK0" == 1 ]] || stop "teil4 nicht aktiv (/api/t4/status ok=$T4OK0) - Dashboard nicht im erwarteten Zustand"; fi
pcode() { code -X POST "$@"; }
TLAT0=$(tmed "$B/api/t4/status")
echo "Zustand vorher: teil4 aktiv $T4OK0 (Takt $T4N0), /api/t4/status Median ${TLAT0} s, /api/usv HTTP $UAPI0"
aust() { "${CURL[@]}" "$B/api/audio/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - -"); sys.exit(0)
t = d.get("tools") or {}
c = d.get("cfg") or {}
print(int(bool(d.get("aktiv") and d.get("faden"))), ",".join(sorted(k for k, v in t.items() if not v)) or "-", c.get("vol", "?"))' 2>/dev/null || echo "FEHLER - -"; }
read -r AUOK0 AUMISS0 AUVOL0 <<< "$(aust)"
echo "audioKern vorher: Ausgabe $([[ "$AUOK0" == 1 ]] && echo aktiv || echo "NICHT aktiv ($AUOK0)"), fehlende Programme ${AUMISS0}, Regler ${AUVOL0} %"
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, nichts gesendet, kein Herunterfahren."
  case "$NUTST" in
    fertig) echo "  Phase A: NUT ist schon wie commit57 eingerichtet - ein echter Lauf prueft nur (Schwellen, upsmon angemeldet).";;
    unklar) echo "  Phase A: Einrichtung nur mit sudo pruefbar - der echte Lauf liest $NUT_ETC mit sudo und richtet nur ein, wenn es der Stand von commit55 ist (sonst STOP).";;
    alt)    echo "  Phase A: ein echter Lauf sichert ups.conf/upsd.users/upsmon.conf, schreibt ignorelb + 20 %/300 s + upsmon_local (Passwort lokal zufaellig, nie ausgegeben) + MONITOR primary, startet Treiber und upsd neu und nut-monitor (enable --now). Kein Test-Herunterfahren.";;
  esac
  if [[ "$NEED" == 0 ]]; then echo "  Phase B: commit57 ist schon installiert - ein echter Lauf aendert an den Dateien nichts."
  else echo "  Phase B: ein echter Lauf wuerde dashboard.py und lage_pages.py ersetzen (Sicherungen DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, 27 Seiten/APIs + /api/usv pruefen. Eine sudo-Passwortabfrage. Beim Einspielen wird nichts gesendet."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
if [[ "$NEED" == 1 || "$NUTNEED" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer NUT, den Neustart und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung"
# ---------- 4A) Phase A: NUT (upsmon + Schwellen) ----------
NUTBAK=()
nutok() { # setzt NCK; 0 = Treiber-Schwellen wirken und upsd liefert Status, nur 127.0.0.1
  local st l bad
  st=$(upsst); NUTSTAT="$st"
  [[ "$st" =~ ^(OL|OB|LB|CAL|CHRG|DISCHRG|BYPASS|TRIM|BOOST|OFF|RB|ALARM|FSD|OVER|TEST) ]] || { NCK="upsc liefert keinen ups.status ('${st:-leer}')"; return 1; }
  l=$(lsn | tr '\n' ' '); bad=$(lsn | grep -v "^127\.0\.0\.1:$NUT_PORT\$" || true)
  [[ -n "$l" && -z "$bad" ]] || { NCK="Port $NUT_PORT: '${l}' (erlaubt nur 127.0.0.1)"; return 1; }
  [[ "$(upsv battery.charge.low)" == 20 && "$(upsv battery.runtime.low)" == 300 && "$(upsv driver.flag.ignorelb)" == enabled ]] || { NCK="Schwellen wirken nicht: battery.charge.low '$(upsv battery.charge.low)', battery.runtime.low '$(upsv battery.runtime.low)', driver.flag.ignorelb '$(upsv driver.flag.ignorelb)'"; return 1; }
  NCK="ups.status $st, battery.charge.low 20 %, battery.runtime.low 300 s, ignorelb aktiv, Port $NUT_PORT nur ${l% }"; return 0; }
nutrb() {
  set +e +o pipefail
  trap - ERR
  rm -f "$W"/nut/*.real
  echo "NUT-ROLLBACK: $1"
  jc -u nut-monitor -u "nut-driver@$NUT_UPS" -u nut-server --since "@${TNA:-0}" --no-pager -n 300 -o cat | grep -iv serial | grep -iv password | tail -12 | cut -c1-200 | sed 's/^/   | /'
  sudo systemctl disable --now nut-monitor.service >/dev/null 2>&1
  local f
  for f in "${NUTBAK[@]}"; do sudo cp -a "$NUT_ETC/$f.bak-$NM-$TS" "$NUT_ETC/$f" && echo "  $NUT_ETC/$f = Sicherung"; done
  sudo systemctl restart "nut-driver@$NUT_UPS.service" >/dev/null 2>&1
  sudo systemctl restart nut-server.service >/dev/null 2>&1
  local i st=""; for i in $(seq 1 20); do sleep 2; st=$(upsst); [[ -n "$st" ]] && break; done
  echo "  upsmon aus (disable --now), Treiber + upsd mit der commit55-Einrichtung neu gestartet: Status ${st:-nicht lesbar}"
  [[ -e "$KPF" ]] && echo "  WARNUNG: $KPF existiert - bitte diese Ausgabe an Grok schicken (nicht neu starten)"
  echo "STOP: Phase A (NUT) fehlgeschlagen - Dashboard NICHT geaendert (dashboard.py, lage_pages.py unveraendert, kein Neustart)"
  exit 1
}
TNA=$(date +%s)
if [[ "$NUTNEED" == 0 ]]; then
  nutok && echo "OK NUT wie commit57: $NCK" || echo "HINWEIS NUT eingerichtet, aber gerade nicht wie erwartet lesbar: $NCK"
  MA=$(systemctl is-active nut-monitor.service 2>/dev/null || true); MC=$(upscl)
  [[ "$MA" == active && "$MC" -ge 1 ]] && echo "OK upsmon aktiv und angemeldet (upsc -c: ${MC} lokaler Client)" || echo "HINWEIS upsmon $MA, angemeldet $MC - Handpruefung: systemctl status nut-monitor; upsc -c $NUT_UPS@127.0.0.1"
else
  PHASE="Phase A (NUT)"
  trap '' INT
  # jeder unerwartete Fehler in Phase A -> NUT-Rollback (nie halb eingerichtet stehen lassen)
  trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND; [[ "$BASHPID" == "$$" ]] && nutrb "unerwarteter Fehler in Zeile $ERRLN ($(echo "$ERRCMD" | cut -c1-80))"' ERR
  rscheck "vor NUT" 600
  NBK=0
  for f in ups.conf upsd.users upsmon.conf; do
    sudo test -f "$NUT_ETC/$f" || nutrb "$NUT_ETC/$f fehlt"
    sudo cp -a "$NUT_ETC/$f" "$NUT_ETC/$f.bak-$NM-$TS" || nutrb "Sicherung $NUT_ETC/$f fehlgeschlagen"
    NBK=$((NBK + 1)); NUTBAK+=("$f")
    { sudo ls -1t "$NUT_ETC" 2>/dev/null || true; } | grep "^$f\.bak-$NM-" | tail -n +$((KEEP_LAST + 1)) | while read -r o; do sudo rm -f -- "$NUT_ETC/$o"; done || true
  done
  echo "OK Sicherungen $NUT_ETC/DATEI.bak-$NM-$TS ($NBK Dateien: ups.conf, upsd.users, upsmon.conf; nut.conf und upsd.conf bleiben)"
  ( umask 077
    PW=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
    [[ "$PW" =~ ^[0-9a-f]{32}$ ]] || exit 1
    for x in "upsd.users:$W/G/nut/upsd.users.tpl" "upsmon.conf:$W/G/nut/upsmon.conf.tpl"; do
      PWX="$PW" python3 -c 'import os, sys; open(sys.argv[2], "w").write(open(sys.argv[1]).read().replace("@PW@", os.environ["PWX"]))' "${x#*:}" "$W/nut/${x%%:*}.real" || exit 1
    done
    cp "$W/G/nut/ups.conf.tpl" "$W/nut/ups.conf.real" ) || nutrb "Dateien mit neuem Passwort nicht erzeugbar"
  for f in ups.conf upsd.users upsmon.conf; do sudo install -m 0640 -o root -g "$NG" "$W/nut/$f.real" "$NUT_ETC/$f" || nutrb "$NUT_ETC/$f schreiben fehlgeschlagen"; done
  rm -f "$W"/nut/*.real
  nutget; [[ "$NUTRD" == 1 && "$(nutcmp)" == fertig ]] || { rm -rf "$W/cur"; nutrb "$NUT_ETC nach dem Schreiben ungleich Soll"; }
  rm -rf "$W/cur"
  RG=$(sudo stat -c '%U:%G %a' "$NUT_ETC/upsd.users" 2>/dev/null || echo "?")
  [[ "$RG" == "root:$NG 640" ]] || nutrb "$NUT_ETC/upsd.users hat $RG (erwartet root:$NG 640)"
  echo "OK $NUT_ETC: ups.conf ignorelb + override 20 % / 300 s, upsd.users upsmon_local (Passwort lokal zufaellig, nicht ausgegeben, root:$NG 640), upsmon.conf MONITOR primary"
  echo "Treiber-Neustart (override/ignorelb wirken erst danach; 2-4 s keine Werte) ..."
  sudo systemctl restart "nut-driver@$NUT_UPS.service" > "$W/drv.log" 2>&1 || { grep -iv serial "$W/drv.log" | tail -6 | sed 's/^/   | /' || true; nutrb "Treiber-Neustart fehlgeschlagen"; }
  sudo systemctl restart nut-server.service >> "$W/drv.log" 2>&1 || nutrb "upsd startet nicht"
  NOK=0
  for i in $(seq 1 30); do sleep 2; nutok && { NOK=1; break; }; done
  [[ "$NOK" == 1 ]] || nutrb "$NCK"
  echo "OK Treiber + upsd: $NCK"
  ST1=$(upsst)
  if [[ ! "$ST1" =~ ^OL ]] || [[ " $ST1 " == *" LB "* || " $ST1 " == *" OB "* || " $ST1 " == *" FSD "* ]]; then nutrb "USV nicht mehr im reinen Netzbetrieb ($ST1) - upsmon wird nicht eingeschaltet"; fi
  sudo systemctl enable --now nut-monitor.service > "$W/mon.log" 2>&1 || { tail -5 "$W/mon.log" | grep -iv password | sed 's/^/   | /' || true; nutrb "nut-monitor startet nicht"; }
  MOK=0
  for i in $(seq 1 20); do sleep 2; [[ "$(systemctl is-active nut-monitor.service 2>/dev/null || true)" == active && "$(upscl)" -ge 1 ]] && { MOK=1; break; }; done
  JM=$(jc -u nut-monitor --since "@$TNA" --no-pager -n 200 -o cat | grep -iv password || true)
  BADM=$(echo "$JM" | grep -iE "login.*(fail|denied)|access.?denied|password|fatal|insufficient|can.t connect|unable to|not authorized" || true)
  [[ -z "$BADM" ]] || { echo "$BADM" | cut -c1-200 | sed 's/^/   | /' || true; nutrb "upsmon meldet Fehler im Journal"; }
  [[ "$MOK" == 1 ]] || nutrb "upsmon nicht aktiv oder nicht bei upsd angemeldet (upsc -c ohne 127.0.0.1)"
  [[ ! -e "$KPF" ]] || nutrb "killpower-Merker $KPF wurde gesetzt"
  [[ "$(upsst)" =~ ^OL ]] || nutrb "Status nach dem Start von upsmon nicht OL"
  echo "OK upsmon (nut-monitor) $(systemctl is-active nut-monitor.service 2>/dev/null || true)/$(systemctl is-enabled nut-monitor.service 2>/dev/null || true), bei upsd angemeldet (upsc -c: 127.0.0.1), kein killpower-Merker, Status $(upsst)"
  echo "$JM" | grep -iv serial | tail -3 | cut -c1-160 | sed 's/^/  Journal nut-monitor: /' || true
  trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
fi
NTS=$(systemctl show -p TimeoutStopUSec --value prepper-dashboard 2>/dev/null || true)
echo "OK Abschalt-Reihenfolge: upsmon -> 'shutdown -h +0' nach FINALDELAY 5 s; systemd stoppt prepper-dashboard (relStop, longArchive, SQLite-WAL; Zeitlimit ${NTS:-unbekannt}) vor dem Ausschalten; Puffer bis Akku leer ca. 300 s; danach nutshutdown -> USV aus nach ups.delay.shutdown $(upsv ups.delay.shutdown) s, Neustart bei Netz nach ups.delay.start $(upsv ups.delay.start) s"
NTG=$(systemctl is-enabled nut.target 2>/dev/null || true); echo "  nut.target: ${NTG:-?} (startet beim Booten Treiber, upsd und upsmon)"
# ---------- 4B) Phase B: Dashboard ----------
PHASE="Phase B (Dashboard)"
# ---------- 4) Dashboard ----------
trap '' INT
RESTARTED=0
T0D=$(date +%s)
INST=()
waitd() { local i; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done; return 1; }
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -n 400 -o cat | grep -E "usvShutdown|Traceback" | tail -5 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  if [[ "$RESTARTED" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    waitd
  fi
  echo "  NUT bleibt wie commit57 (upsmon aktiv - Abschaltung wirkt auch ohne Anzeige); ups_manager.py, Datenbank, prepper_sdr.py und Mesh-Regeln unveraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED" == 0 ]]; then
  echo "OK commit57 schon installiert - kein Neustart, keine Aenderung an den Dateien"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen" 300
  for x in "$F" "$FL"; do
    cp -a "$x" "$x.bak-$NM-$TS"
    { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  echo "OK Sicherungen *.bak-$NM-$TS: dashboard.py, lage_pages.py (behalten: letzte $KEEP_LAST)"
  for v in "$FL:lage_pages.py:$KNOWN_L16N" "$F:dashboard.py:$KNOWN_D16N"; do
    IFS=: read -r x fn hh <<< "$v"
    INST+=("$x")
    cp "$W/work/$fn" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rb "$fn installieren"; exit 1; }
    [[ "$(s16 "$x")" == "$hh" ]] || { rb "$fn nach dem Kopieren falsch ($(s16 "$x"))"; exit 1; }
  done
  echo "OK lage_pages.py und dashboard.py atomar ersetzt"
  RESTARTED=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard - warte auf HTTP 200 (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  waitd || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
fi
PHASE=Pruefung
# ---------- 5) Pruefung ----------
for p in "${PAGES[@]}" "${APIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rbx "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs antworten wie vorher (alle $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
T4OK=0
for i in $(seq 1 30); do
  read -r T4OK1 T4N1 T4TH1 HBL1 <<< "$(t4st)"
  [[ "$T4OK1" == 1 && "$T4N1" -ge 3 ]] && { T4OK=1; break; }
  sleep 4
done
[[ "$T4OK" == 1 ]] || rbx "teil4 nach dem Neustart nicht aktiv oder Takt steht (ok $T4OK1, Takt $T4N1, Faden $T4TH1)"
sleep 6; read -r T4OK2 T4N2 T4TH2 HBL2 <<< "$(t4st)"
[[ "$T4N2" -gt "$T4N1" ]] || rbx "teil4-Takt laeuft nicht weiter ($T4N1 -> $T4N2)"
echo "OK teil4 aktiv, Takt laeuft ($T4N1 -> $T4N2 in 6 s)"
TLAT1=$(tmed "$B/api/t4/status")
echo "OK /api/t4/status Median ${TLAT1} s (vorher ${TLAT0} s)"
awk -v a="$TLAT0" -v b="$TLAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/api/t4/status ist deutlich langsamer geworden (${TLAT0} s -> ${TLAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200)"
n=$(grep -c "^# ===== usvShutdown:" "$F" || true); [[ "$n" == 1 ]] || rbx "dashboard.py Marker usvShutdown ${n}x"
n=$(grep -c 'id="usvShut"' "$FL" || true); [[ "$n" == 1 ]] || rbx "lage_pages.py Zeile usvShut ${n}x"
echo "OK Marker usvShutdown (dashboard.py) und Kachel-Zeile usvShut (lage_pages.py) je 1x; ups_manager.py $(s16 "$FU") unveraendert"
for i in $(seq 1 20); do
  UH=$("${CURL[@]}" "$B/lokale-energie" -o "$W/le.html" -w "%{http_code}" || true)
  UQ=$(grep -c 'id="usvShut"' "$W/le.html" || true)
  [[ "$UH" == 200 && "$UQ" == 1 ]] && break
  sleep 3
done
[[ "$UH" == 200 && "$UQ" == 1 ]] || rbx "/lokale-energie HTTP $UH, Zeile usvShut ${UQ}x"
uapi() { "${CURL[@]}" -D "$W/uh.txt" "$B/api/usv" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - - -"); sys.exit(0)
s = d.get("shutdown") or {}
print(d.get("mode") or "-", int("serial" in json.dumps(d).lower()), int(isinstance(d.get("alarm"), dict)), str(s.get("txt") or "-").replace(" ", "_")[:200])' 2>/dev/null || echo "FEHLER - - -"; }
for i in $(seq 1 25); do read -r UM USRL UAL USH <<< "$(uapi)"; [[ "$USH" == *upsmon_aktiv* ]] && break; sleep 2; done
[[ "$UM" != FEHLER ]] || rbx "/api/usv nicht lesbar (HTTP $(code "$B/api/usv"))"
[[ "$USRL" == 0 ]] || rbx "/api/usv enthaelt 'serial'"
[[ "$UAL" == 1 ]] || rbx "/api/usv ohne Feld alarm (usvAlarm verloren?)"
grep -qi "^cache-control:.*no-store" "$W/uh.txt" || rbx "/api/usv ohne Cache-Control no-store"
[[ "$USH" == "Abschaltung_bei_20_%_oder_5_min_·_upsmon_aktiv" ]] || rbx "/api/usv shutdown: '$(echo "$USH" | tr '_' ' ')' statt 'Abschaltung bei 20 % oder 5 min · upsmon aktiv'"
echo "OK /api/usv (Modus $UM): $(echo "$USH" | tr '_' ' ')"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -n 3000 -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep usvShutdown"
else
  if [[ "$RESTARTED" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "usvShutdown aktiv: usvShutdown ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'usvShutdown aktiv: usvShutdown ok' ($(echo "$JD" | grep -F usvShutdown | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok' 'audioKern aktiv: audioKern ok' 'audioUi aktiv: audioUi ok' 'kartePop aktiv: kartePop ok' 'hbProblem aktiv: hbProblem ok' 'umweltFlach aktiv: umweltFlach ok' 'qrmRun aktiv: qrmRun ok' 'usvLesen aktiv: usvLesen ok' 'usvAlarm aktiv: usvAlarm ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'usvShutdown Selbsttest FEHLER|usvShutdown /api/usv:|usvAlarm: Faden-Fehler|usvAlarm /api/usv:|usvLesen: Faden-Fehler|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|usvAlarm Selbsttest FEHLER|usvLesen Selbsttest FEHLER|qrmRun Selbsttest FEHLER|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|No module named .ups_manager|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'usvShutdown Selbsttest FEHLER|usvShutdown /api/usv:|usvAlarm: Faden-Fehler|usvAlarm /api/usv:|usvLesen: Faden-Fehler|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|usvAlarm Selbsttest FEHLER|usvLesen Selbsttest FEHLER|qrmRun Selbsttest FEHLER|umweltFlach Selbsttest FEHLER|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|No module named .ups_manager|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein commit57-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED" == 1 ]]; then [[ "$a" == active ]] || rbx "$u laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- neu gestartet: $([[ "$RESTARTED" == 1 ]] && echo "nur prepper-dashboard" || echo "keiner"); prepper-sdr und Mesh-Bruecken unveraendert"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"), darunter prepper_sdr.py)" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach qrmRun usvLesen usvAlarm usvShutdown; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
[[ "$(systemctl is-active nut-monitor.service 2>/dev/null || true)" == active && "$(upscl)" -ge 1 && ! -e "$KPF" ]] && echo "OK zum Schluss: upsmon aktiv und angemeldet, Status $(upsst), kein killpower-Merker" || echo "WARNUNG zum Schluss: upsmon $(systemctl is-active nut-monitor.service 2>/dev/null || true), angemeldet $(upscl), killpower-Merker $([[ -e "$KPF" ]] && echo JA || echo nein) - bitte diese Ausgabe an Grok schicken"
echo "OK Datenbank, Mesh-Regeln (keine Meldung beim Herunterfahren), Gain-Waechter (Stufe 16), prepper_sdr.py, ups_manager.py, nut.conf, upsd.conf (nur 127.0.0.1), Firewall und rpcbind unberuehrt; beim Einspielen nichts gesendet, kein Test-Herunterfahren, kein 'upsmon -c'"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F") ($(wc -l < "$F") Zeilen), lage_pages.py sha16 $(s16 "$FL") ($(wc -l < "$FL") Zeilen), ups_manager.py sha16 $(s16 "$FU") (unveraendert)"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1); LBL=$({ ls -1t "$FL.bak-$NM-"* 2>/dev/null || true; } | head -1)
if [[ -n "$LB" && -n "$LBL" ]]; then
  echo "Rueckweg Dashboard (beide zusammen, NUT bleibt):"
  echo "  cp -a $LB $F && cp -a $LBL $FL && sudo systemctl restart prepper-dashboard"
else echo "Rueckweg Dashboard: keine $NM-Sicherung vorhanden (Dateien nicht geaendert)"; fi
NB=$({ sudo -n ls -1t "$NUT_ETC" 2>/dev/null || true; } | grep "^ups\.conf\.bak-$NM-" | head -1 | sed "s/^ups\.conf\.bak-$NM-//" || true)
if [[ -n "$NB" ]]; then
  echo "Rueckweg Abschaltung (NUT zurueck auf commit55, upsmon aus):"
  echo "  sudo systemctl disable --now nut-monitor && for f in ups.conf upsd.users upsmon.conf; do sudo cp -a $NUT_ETC/\$f.bak-$NM-$NB $NUT_ETC/\$f; done && sudo systemctl restart nut-driver@$NUT_UPS nut-server"
else echo "Rueckweg Abschaltung: sudo systemctl disable --now nut-monitor, dann $NUT_ETC/ups.conf, upsd.users, upsmon.conf aus DATEI.bak-$NM-ZEIT zurueck, sudo systemctl restart nut-driver@$NUT_UPS nut-server"; fi
echo "Pruefen (nur lesend), jeweils einzeln - NIE 'upsmon -c fsd' oder 'upsmon -c stop' zum Testen:"
echo "  upsc eaton@127.0.0.1 battery.charge.low"
echo "  upsc eaton@127.0.0.1 battery.runtime.low"
echo "  upsc eaton@127.0.0.1 driver.flag.ignorelb"
echo "  upsc -c eaton@127.0.0.1"
echo "  systemctl is-active nut-monitor"
echo "  sudo journalctl -u nut-monitor -n 20 --no-pager"
echo "  curl -s http://127.0.0.1:5000/api/usv | grep -o shutdown.*"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep usvShutdown"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Beim Einspielen nichts gesendet (kein Mesh, kein Telegram, keine Alarme), kein Test-Herunterfahren, nichts nach aussen geoeffnet, keine Datenbank geaendert. Neue Docs-Version: bewusst nicht."
echo "Dauer: $(( $(date +%s) - TNA )) s"
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
