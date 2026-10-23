#!/bin/bash
set -euo pipefail
# sdrAir: Geraete-Register (USB-ID + Seriennummer) mit festen Rollen, enthaelt sdrWd2.
#  - Airspy R2 (USB 1d50:60a1, Hex-Seriennummer aus sysfs) fest auf 11D: welle-cli -F airspy (oder SoapySDR driver=airspy), Port 7979 wie bisher,
#    eigene Gain-Leiter (Linearitaets-Stufe 16/12/19/9/21/AGC), CPU von welle-cli gemessen (5 min Mittel), nice 5, Warnung ueber 85 % (10 min). Spyverter nicht benutzt.
#  - Stick 1 (SN 19348831) fest 5C (ASA DE, Warnungen) mit Rueckfall 10C wie bisher. Stick 2 (SN 72055505) nur Hobby, wenn angesteckt.
#  - Keine Uebernahme mehr: die alte manuelle Uebernahme vom 18.10. wird einmal sauber beendet (sdr_takeover.json off_by sdrAir), Knopf/Automatik schalten nichts mehr ein.
#  - Fehlt ein Geraet: grau "<Name> nicht angeschlossen", keine Stufe, keine Aktion; wieder angesteckt -> automatisch erkannt (ohne Dienst-Neustart), Vorfall zu.
#    Unbekannte/nicht eingetragene Sticks: "erkannt, ohne Rolle", nie benutzt (3. Stick spaeter: nur Eintrag in sdr_config.json devs).
#  - Watchdog (sdrWd2 komplett): Neustart = nur welle-cli; USB-Neuverbindung des Airspy ueber das Hilfsprogramm "usb-reset-air <16 Hex>" (1d50:60a1 + Seriennummer),
#    sudoers-Regel genau um diesen einen Aufruf erweitert. Hobby-Stick nie Pi-Neustart.
#  - /funk: Geraetenamen vor Kanal/TII, Namen vor TII-Kennungen auch fuer 5C/10C, ruhige Zeilen fester Hoehe, kein Uebernahme-Knopf; /pi Empfaenger je Geraet.
# Basis streng: prepper_sdr.py + sdr_manager.py = Stand nach sdrWd (18.10.), dashboard.py = Stand nach sysBoot; oder sdrAir schon drin. Sonst Abbruch ohne Aenderung.
# Aendert prepper_sdr.py, sdr_manager.py, dashboard.py, sdr_config.json (devs), Hilfsprogramm, sudoers-Regel. Neustart prepper-sdr + prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
CF="$DASH_DIR/sdr_config.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
HDST="/usr/local/sbin/prepper-sdr-wdhelper"
SDST="/etc/sudoers.d/zz-prepper-sdr-wd"
SYSUSB="${SDR_SYSFS_USB:-/sys/bus/usb/devices}"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdrair-apply
KEEP_LAST=3
KNOWN_D16="eb4ce30b1f550f1d"     # dashboard.py nach sysBoot
KNOWN_D16N="169cd40bba5aba29"    # dashboard.py nach sdrAir (Ziel)
KNOWN_SM16="53ab078bd5398e42"    # sdr_manager.py nach sdrWd
KNOWN_SM16N="3705c2249f8a3d60"    # sdr_manager.py nach sdrAir (Ziel)
KNOWN_SDR16="1f8b450db19854d1"   # prepper_sdr.py nach sdrWd
KNOWN_SDR16N="a27db4d1f9c4b7fc"   # prepper_sdr.py nach sdrAir (Ziel)
KNOWN_DB16="431077d36822a090"    # database.py (bleibt unveraendert)
KNOWN_MR16="c5ffda3907b0dd51"    # mesh_router.py (bleibt unveraendert)
KNOWN_LG16="3788481354f47656"    # lagegeo.py (bleibt unveraendert)
KNOWN_HL16="ff536c2eadc4a2e4"    # Hilfsprogramm aus sdrWd (wird ersetzt)
KNOWN_HL16N="01c19375256b05bc"    # Hilfsprogramm nach sdrAir (Ziel)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== sdrAir apply (Airspy fest 11D, Stick 1 fest 5C + 10C, Stick 2 Hobby, keine Uebernahme, Geraete-Register, Watchdog sdrWd2 + Airspy), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/mid" "$W/sbx"
EXPECT_PF="24ca150b11f4c77b5d34085330c7cc64c90e5795e498cde56fb0f2562ae906ef"
cat > "$W/patch-fu.py" << 'AIP_EOF'
"""Patcher fuer sdrLog/funkUI. Aufruf: patch-fu.py NAME ART QUELLE ZIEL BLOCK EDITS   (ART = sm | sdr | dash). Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E, ANCH = g["%s_EDITS" % kind.upper()], g["%s_ANCHOR" % kind.upper()]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
MARK = B.splitlines()[0]
name = {"sm": "sdr_manager", "sdr": "prepper_sdr", "dash": "dashboard"}[kind]
if MARK in s:
    rest = s.replace(B, "", 1)
    ok = s.count(B) == 1 and all(rest.count(n) == 1 for o, n in E)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if s.count(ANCH) != 1:
    print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
if kind == "dash":
    i = s.index(ANCH) + len(ANCH)
    s = s[:i] + B + s[i:]
else:
    i = s.index(ANCH)
    s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen + Block %s" % (name, len(E), label))
AIP_EOF
EXPECT_ED="7790fa89fc18ca6ae03748fee49c1ce948acc5e645afa8cd7f870971a77d5bf0"
cat > "$W/wd2_edits.py" << 'WDE_EOF'
# sdrWd2: Stellen (alt, neu) auf dem Stand nach sdrWd. Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
# Zustand: Zusatzfelder je Vorfall laden; alte sdrWd-Vorfaelle einmalig umstellen
('''                        "blk_t": num(i.get("blk_t")) or 0, "usb_last": str(i.get("usb_last") or "")[:120] or None}
''', '''                        "blk_t": num(i.get("blk_t")) or 0, "usb_last": str(i.get("usb_last") or "")[:120] or None}
            x["inc"].update(_wd2_clean_inc(i, num))   # sdrWd2: Uebernahme/vor Start/Rueckfall 10C
'''),
('''    d = _wd_clean(b if tb > ta else a)
    msgs = []
''', '''    d = _wd_clean(b if tb > ta else a)
    _wd2_migrate(d, now)   # sdrWd2: Vorfall aus sdrWd -> Eskalation ab jetzt
    msgs = []
'''),
# Pruefung: Uebernahme zaehlt nur 5C, 10C = Lebenszeichen
('''        i = s.get("inc")
        if ok:
''', '''        i = s.get("inc")
        tk = _wd2_kind(pl, ch, src)   # sdrWd2: "alarm" 5C / "fb" Rueckfall 10C bei Uebernahme
        if tk == "fb" and _wd2_fb(s, i, ok, now, ch, why):
            pass
        elif ok:
'''),
('''                since = int(s["last_ok"]) if s.get("last_ok") and s["last_ok"] <= now else int(seed or now)
''', '''                since = _wd2_since(pl, s, tk, seed, now)   # sdrWd2
'''),
('''                            "act_t": None, "chk": 1, "lg": 0, "block": None, "blk_t": 0, "usb_last": None}
''', '''                            "act_t": None, "chk": 1, "lg": 0, "block": None, "blk_t": 0, "usb_last": None}
                _wd2_new_inc(pl, s["inc"], tk)   # sdrWd2: Uebernahme-Kennzeichen, (vor Start)
'''),
('''                if ch:
                    i["ch"] = str(ch)[:12]
''', '''                if ch and not i.get("to"):   # sdrWd2: Uebernahme-Vorfall bleibt 5C
                    i["ch"] = str(ch)[:12]
'''),
# Sperre: Uebernahme sperrt nur noch den Pi-Neustart
('''def _wd_block(pl, now, sn):
''', '''def _wd_block(pl, now, sn, act=None):
'''),
('''        if t2_takeover(pl.base).get("on"):
            return "Alarm-Übernahme Stick 2 (5C/10C) aktiv"
''', '''        if act in (None, "reboot") and t2_takeover(pl.base).get("on"):   # sdrWd2: Uebernahme sperrt nur Stufe 4 (Stick 2 empfaengt Alarm)
            return "Alarm-Übernahme Stick 2 (5C/10C) aktiv – kein Pi-Neustart"
'''),
# Stufen: Uebernahme-Ende schliesst, Stick lebt (10C ok) = warten, Bezugszeit vor Start/Uebernahme
('''        if i and not d.get("pending"):
            dur = now - i["since"]
''', '''        i = _wd2_pre_tick(pl, d, s, i, now, msgs)   # sdrWd2: Uebernahme-Vorfall kennzeichnen / bei Uebernahme-Ende schliessen
        if i and not d.get("pending") and not i.get("abs"):   # sdrWd2: Stick fehlt = keine Stufe
            dur = _wd2_dur(pl, i, now)   # sdrWd2
'''),
('''            elif fresh and pl.active not in ("nostick", "pause"):
                a, why = _wd_decide(d, s, i, c, now)
                blk = _wd_block(pl, now, sn) if a in ("restart", "usb", "reboot") else None
''', '''            elif fresh and _wd2_alive(pl, i, now):   # sdrWd2: Rueckfall 10C ok = Stick lebt, keine Aktion
                i["block"] = WD2_ALIVE_TXT
            elif fresh and pl.active not in ("nostick", "pause"):
                a, why = _wd_decide(d, s, _wd2_eff(pl, i, now), c, now)   # sdrWd2: Bezugszeit
                blk = _wd_block(pl, now, sn, a) if a in ("restart", "usb", "reboot") else None
'''),
# Anzeige (Stick nicht angeschlossen: immer klar, auch ohne Vorfall)
('''    return v


_wd_orig_sub_done = Planner.sub_done
''', '''    return _wd2_view_abs(pl, v, now)   # sdrWd2: Stick nicht angeschlossen


_wd_orig_sub_done = Planner.sub_done
'''),
# Anzeige
('''        dur = now - i["since"]
        stale = now - (s.get("last_check") or 0) > WD_EVID_S
''', '''        dur = _wd2_dur(pl, i, now)   # sdrWd2: (vor Start)/Uebernahme ab Bezugszeit
        stale = now - (s.get("last_check") or 0) > WD_EVID_S
'''),
('''        if stale:
            v["txt"] += " · letzte Prüfung %s" % _wd_hm(s.get("last_check"), now)
''', '''        _wd2_view(pl, i, v, c, now, nm)   # sdrWd2
        if stale:
            v["txt"] += " · letzte Prüfung %s" % _wd_hm(s.get("last_check"), now)
'''),
('''txt="Stick ohne DAB-Empfang", why=v["txt"]''', '''txt=v.get("hl") or "Stick ohne DAB-Empfang", why=v["txt"]'''),
('''Pi-Neustart max 1/h + Stopp nach 3, Sperre bei Alarm/Übernahme/ASA/PTY31, ''', '''Pi-Neustart max 1/h + Stopp nach 3, Sperre bei Alarm/ASA/PTY31/Antennentest, Übernahme nur Pi-Neustart (sdrWd2), '''),
# Selbsttest sdrWd: Uebernahme sperrt Stick 1 nicht mehr -> Sperre dort mit Antennentest pruefen; Stick 2 darf Neustart + USB, kein Pi-Neustart
('''    # Sperre: Uebernahme Stick 2 aktiv -> keine USB-Neuverbindung
    write_json(p(T2_TAKEOVER, tmp), {"on": True, "since": int(t0), "src": "ASA", "why": "Test", "by": "auto"})
    _T2_TO.clear()
    for k in range(31, 50):
        chk(False, t0 + 60 * k)
        tick(t0 + 60 * k + 1)
    assert st()["inc"]["usb_n"] == 0 and not calls and "Übernahme" in (st()["inc"]["block"] or ""), st()["inc"]
    write_json(p(T2_TAKEOVER, tmp), {"on": False})
    _T2_TO.clear()
''', '''    # Sperre: Antennentest laeuft -> keine USB-Neuverbindung (sdrWd2: Uebernahme sperrt nur noch den Pi-Neustart)
    m.st_pause = True
    for k in range(31, 50):
        chk(False, t0 + 60 * k)
        tick(t0 + 60 * k + 1)
    assert st()["inc"]["usb_n"] == 0 and not calls and "Antennentest" in (st()["inc"]["block"] or ""), st()["inc"]
    m.st_pause = False
'''),
('''    assert any("Stufe 3 gesperrt: Alarm-Übernahme" in x for x in tx), tx
''', '''    assert any("Stufe 3 gesperrt: Antennentest läuft" in x for x in tx), tx   # sdrWd2
'''),
('''    assert not calls and "Übernahme" in _WD["d"]["sticks"]["72055505"]["inc"]["block"], _WD["d"]["sticks"]["72055505"]["inc"]
''', '''    assert ["reboot"] not in calls and calls.count(["usb-reset", "72055505"]) == 2 and all(x[0] != "usb-reset" or x[1] == "72055505" for x in calls) \\
        and "kein Pi-Neustart" in _WD["d"]["sticks"]["72055505"]["inc"]["block"], (calls, _WD["d"]["sticks"]["72055505"]["inc"])   # sdrWd2: Neustart + USB ja, Pi-Neustart nein
'''),
('''        selftest_sdrwd()
    elif a in''', '''        selftest_sdrwd()
        selftest_sdrwd2()
    elif a in'''),
('''"sdrWd aktiv: Daten-Watchdog %s - gelb''', '''"sdrWd aktiv (sdrWd2: Übernahme sperrt nur Pi-Neustart, Rückfall 10C = Lebenszeichen, vor Start ab Start): Daten-Watchdog %s - gelb'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SM_EDITS = [
('''            sticks.append({x: v.get(x) for x in ("sn", "n", "lvl", "txt", "ch", "src", "since", "dur_s", "stage", "usb_n", "usb_max", "restart_n", "reboot_n", "block", "last_ok",
                                                  "last_ok_src", "last_check", "fail_n", "usb_last", "hint")})
''', '''            sticks.append({x: v.get(x) for x in ("sn", "n", "lvl", "txt", "ch", "src", "since", "dur_s", "stage", "usb_n", "usb_max", "restart_n", "reboot_n", "block", "last_ok",
                                                  "last_ok_src", "last_check", "fail_n", "usb_last", "hint", "short", "pre", "to", "absent")})   # sdrWd2: Kurztext/vor Start/Uebernahme/nicht angeschlossen
'''),
('''            short = "SDR läuft, %s ohne Empfang seit %s" % (worst.get("ch") or "Stick %s" % worst.get("n"), _wd_hm(worst.get("since"), now))
''', '''            short = worst.get("short") or "SDR läuft, %s ohne Empfang seit %s" % (worst.get("ch") or "Stick %s" % worst.get("n"), _wd_hm(worst.get("since"), now))   # sdrWd2
'''),
('''    print(selftest_sdrwd())
''', '''    print(selftest_sdrwd())
    print(selftest_sdrwd2())
'''),
('''    if g.get("stopped"):
        lvl = "rot"''', '''    lvl, txt, short = _wd2_sum(sticks, lvl, txt, short, fresh)   # sdrWd2: Stick nicht angeschlossen
    if g.get("stopped"):
        lvl = "rot"'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'

DASH_EDITS = [
# /funk Watchdog-Kasten ruhig: jede Zeile genau eine Zeile (Kurztext mit ...), voller Text als Tooltip und per Tipp aufklappbar; Kopfzeile immer da (feste Zeilenzahl)
('''#wdBox .wd-r{display:flex;gap:6px;align-items:flex-start;line-height:1.35;overflow-wrap:anywhere;min-width:0;margin:2px 0}
#wdBox .wd-d{flex:0 0 auto}#wdBox .wd-s{color:#94a3b8;font-variant-numeric:tabular-nums}\"\"\"''',
 '''#wdBox .wd-r{display:flex;gap:6px;align-items:center;line-height:1.35;height:1.35em;white-space:nowrap;overflow:hidden;min-width:0;margin:2px 0;cursor:pointer;font-variant-numeric:tabular-nums}
#wdBox .wd-r>span:last-child{flex:1 1 0;min-width:0;overflow:hidden;text-overflow:ellipsis}
#wdBox .wd-r.wd-open{height:auto;white-space:normal;align-items:flex-start}#wdBox .wd-r.wd-open>span:last-child{overflow:visible;overflow-wrap:anywhere}
#wdBox .wd-d{flex:0 0 auto}#wdBox .wd-s{color:#94a3b8;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.35;height:1.35em}
/* sdrWd2: Watchdog-Zeilen einzeilig */\"\"\"'''),
('''var COL={ok:'#22c55e',gelb:'#eab308',rot:'#ef4444',grau:'#94a3b8'},LAB={ok:'OK',gelb:'GELB',rot:'ROT',grau:'\\u2013'};''',
 '''var COL={ok:'#22c55e',gelb:'#eab308',rot:'#ef4444',grau:'#94a3b8'},LAB={ok:'OK',gelb:'GELB',rot:'ROT',grau:'\\u2013'},OP={};
function fx(r,k,t){r.title=t;if(OP[k])r.className+=' wd-open';r.addEventListener('click',function(){OP[k]=!OP[k];r.classList.toggle('wd-open');});return r;}'''),
('''if(W.lvl==='gelb'||W.lvl==='rot'||!(W.sticks||[]).length){var r0=el('div','wd-r');r0.appendChild(el('span','wd-d','\\u25CF'));r0.firstChild.style.color=COL[W.lvl]||COL.grau;r0.appendChild(el('span',null,W.short||W.txt||''));b.appendChild(r0);}
(W.sticks||[]).forEach(function(s){var r=el('div','wd-r');var d=el('span','wd-d','\\u25CF');d.style.color=COL[s.lvl]||COL.grau;r.appendChild(d);r.appendChild(el('span',null,s.txt||''));b.appendChild(r);});''',
 '''{var r0=el('div','wd-r');r0.appendChild(el('span','wd-d','\\u25CF'));r0.firstChild.style.color=COL[W.lvl]||COL.grau;r0.appendChild(el('span',null,W.short||W.txt||''));b.appendChild(fx(r0,'g',W.txt||W.short||''));}
(W.sticks||[]).forEach(function(s){var r=el('div','wd-r');var d=el('span','wd-d','\\u25CF');d.style.color=COL[s.lvl]||COL.grau;r.appendChild(d);r.appendChild(el('span',null,s.txt||''));b.appendChild(fx(r,'s'+s.n,s.txt||''));});'''),
('''var c2=W.cfg||{};b.appendChild(el('div','wd-s',(W.reboot_line||'')));''', '''var c2=W.cfg||{};var rl=el('div','wd-s',(W.reboot_line||''));rl.title=rl.textContent;b.appendChild(rl);'''),
('''    assert "text-overflow:ellipsis" in _WD_CSS and "tabular-nums" in _WD_CSS
''', '''    assert "text-overflow:ellipsis" in _WD_CSS and "tabular-nums" in _WD_CSS
    assert _wd2_dash_ok(), "sdrWd2 Watchdog-Zeilen"   # sdrWd2
'''),
('''    return "sdrWd selftest ok (Funk-Lage Watchdog-Kasten, /pi-Kachel vor Sicherung, API nur lesen, Lage-Text ehrlich, Empfänger-Zeilen einzeilig mit Details, JS ohne POST)"''',
 '''    return "sdrWd selftest ok (Funk-Lage Watchdog-Kasten, /pi-Kachel vor Sicherung, API nur lesen, Lage-Text ehrlich, Empfänger-Zeilen einzeilig mit Details, JS ohne POST; sdrWd2 Watchdog-Zeilen einzeilig, feste Zeilenzahl)"'''),
]
DASH_ANCHOR = "# ===== /funkUI =====\n"
WDE_EOF
EXPECT_BSD="c1d5f0a7e7c8e7f5d2bd3b5c29e7874391d016ed33ce3cbd28051cc590177f75"
cat > "$W/wd2_sdr_block.py" << 'WDB_EOF'
# ===== sdrWd2: Daten-Watchdog bei Stick-2-Uebernahme - Uebernahme sperrt nur noch Stufe 4 (Pi-Neustart), Stick 1 Stufen 2-3 immer, Stick 2 im Alarmdienst Neustart + USB-Neuverbindung nur wenn weder 5C noch Rueckfall 10C Sync haben (Stick haengt); Vorfall der Uebernahme zaehlt nur 5C (10C-Sync = Stick lebt, schliesst nichts, kein Technik-Verlauf alle 10 min), Anzeige gelb "Uebernahme aktiv · 5C ohne Sync seit .. · Rueckfall 10C ok", rot erst wenn auch 10C ausfaellt; Vorfall schliesst bei echtem 5C-Sync oder Uebernahme-Ende; Beginn vor Watchdog-Start = "(vor Start)", Eskalation ab Watchdog-Start; sendet nichts =====
WD2_ALIVE_TXT = "Rückfall 10C ok – Stick lebt, nur 5C ohne Sync; Watchdog wartet"


def _wd2_num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) else None


def _wd2_clean_inc(i, num=None):
    """Zusatzfelder sdrWd2 eines Vorfalls aus geladenem Zustand (fehlt = alter Vorfall, v2 0 -> Umstellung beim Laden)."""
    try:
        num = num or _wd2_num
        return {"v2": 1 if i.get("v2") == 1 else 0, "to": 1 if i.get("to") == 1 else 0, "pre": 1 if i.get("pre") == 1 else 0,
                "fb_t": num(i.get("fb_t")), "fb_ok": i.get("fb_ok") if i.get("fb_ok") in (True, False) else None, "fb_ok_t": num(i.get("fb_ok_t")),
                "fb_fail": int(num(i.get("fb_fail")) or 0), "abs": 1 if i.get("abs") == 1 else 0}
    except Exception:
        return {"v2": 0, "to": 0, "pre": 0, "fb_t": None, "fb_ok": None, "fb_ok_t": None, "fb_fail": 0, "abs": 0}


def _wd2_migrate(d, now):
    """Vorfall aus sdrWd (ohne v2): Beginn bleibt, Eskalation zaehlt ab jetzt (Beginn lag vor diesem Watchdog-Start) - einmalig, keine Sofort-Aktion."""
    try:
        for sn, s in (d.get("sticks") or {}).items():
            i = s.get("inc") if isinstance(s, dict) else None
            if isinstance(i, dict) and not i.get("v2"):
                i["v2"] = 1
                if i["since"] < int(now):
                    i["pre"] = 1
                i["t0"] = int(max(i.get("t0") or i["since"], int(now)))
                _WD["dirty"] = True
    except Exception as e:
        print("sdrWd2 Umstellung:", e, flush=True)


def _wd2_kind(pl, ch, src):
    """Pruefung des gekaperten Stick 2: "alarm" (5C), "fb" (Rueckfall 10C) oder None (alles andere / keine Uebernahme)."""
    try:
        if src != "dab" or not _t2_alarm(pl):
            return None
        c = str(ch or "").upper()
        return "alarm" if c == T2_CH_ALARM else ("fb" if c == T4_CH_FB else None)
    except Exception:
        return None


def _wd2_to_since(pl):
    try:
        t = t2_takeover(pl.base).get("since")
        return int(t) if _wd2_num(t) else 0
    except Exception:
        return 0


def _wd2_since(pl, s, tk, seed, now):
    """Beginn ohne Empfang: bei Uebernahme der letzte echte 5C-Sync (broadcast_state 5C bzw. letzter 5C-Erfolg dieses Sticks), sonst wie sdrWd."""
    try:
        if tk == "alarm":
            c = [int(seed or now)]
            if s.get("last_ok") and s["last_ok"] <= now and str(s.get("last_ok_src") or "") == "DAB %s" % T2_CH_ALARM:
                c.append(int(s["last_ok"]))
            return max(c)
    except Exception:
        pass
    return int(s["last_ok"]) if s.get("last_ok") and s["last_ok"] <= now else int(seed or now)


def _wd2_new_inc(pl, i, tk):
    """Neuer Vorfall: Kennzeichen Uebernahme (nur 5C zaehlt) und "(vor Start)" - Eskalation dann ab Watchdog-Start, nicht ab dem alten Beginn."""
    try:
        i.update(v2=1, to=1 if tk == "alarm" else 0, pre=0, fb_t=None, fb_ok=None, fb_ok_t=None, fb_fail=0)
        st = int(_WD.get("start") or 0)
        if i["since"] < st:
            i["pre"] = 1
            i["t0"] = max(int(i.get("t0") or i["since"]), st)
    except Exception as e:
        print("sdrWd2 Vorfall:", e, flush=True)


def _wd2_fb(s, i, ok, now, ch, why):
    """Rueckfall-10C-Pruefung waehrend der Uebernahme. True = erledigt (Vorfall bleibt offen, nur Lebenszeichen), False = normal weiter."""
    try:
        if ok:
            if i and not i.get("to"):
                if str(i.get("ch") or "").upper() == T2_CH_ALARM:
                    i["to"] = 1
                else:
                    return False      # alter Vorfall aus dem Hobby-Betrieb: echter Empfang schliesst ihn wie bisher
            s.update(last_ok=int(now), last_ok_src=("DAB %s" % (ch or T4_CH_FB))[:30], fail_n=0, why=None)
            if i:
                i.update(fb_t=int(now), fb_ok=True, fb_ok_t=int(now), fb_fail=0)
        else:
            s.update(fail_n=int(s.get("fail_n") or 0) + 1, last_fail=int(now), why=str(why or "kein Empfang")[:120])
            if i:
                if not i.get("to") and str(i.get("ch") or "").upper() == T2_CH_ALARM:
                    i["to"] = 1
                i.update(fb_t=int(now), fb_ok=False, fb_fail=int(i.get("fb_fail") or 0) + 1)
                i["chk"] = int(i.get("chk") or 0) + 1
        return True
    except Exception as e:
        print("sdrWd2 Rueckfall:", e, flush=True)
        return False


def _wd2_alive(pl, i, now):
    """Uebernahme-Vorfall, aber Rueckfall 10C hatte zuletzt Sync (frisch) = Stick lebt, nur 5C schwach."""
    try:
        return bool(i and i.get("to") and i.get("fb_ok") is True and now - (i.get("fb_t") or 0) <= WD_EVID_S)
    except Exception:
        return False


def _wd2_dead(i):
    """Uebernahme-Vorfall und auch Rueckfall 10C mind. 2 Pruefungen nacheinander ohne Sync = Stick liefert gar nichts."""
    try:
        return bool(i and i.get("to") and i.get("fb_ok") is False and int(i.get("fb_fail") or 0) >= 2)
    except Exception:
        return False


def _wd2_t0(pl, i):
    """Bezugszeit der Eskalation: Beginn bzw. Watchdog-Start (vor Start); bei Uebernahme zusaetzlich Uebernahme-Beginn und letzter 10C-Sync."""
    t = max(i["since"], i.get("t0") or i["since"])
    if i.get("to"):
        t = max(t, _wd2_to_since(pl), int(i.get("fb_ok_t") or 0))
    return t


def _wd2_eff(pl, i, now):
    try:
        if i.get("to") or i.get("pre"):
            return dict(i, t0=_wd2_t0(pl, i))
    except Exception as e:
        print("sdrWd2 Bezugszeit:", e, flush=True)
    return i


def _wd2_dur(pl, i, now):
    """Dauer fuer Ampel/Stufe 1: ab Beginn, bei "(vor Start)"/Uebernahme ab der Bezugszeit (kein Sofort-Rot)."""
    try:
        if i.get("to") or i.get("pre"):
            return now - _wd2_t0(pl, i)
    except Exception:
        pass
    return now - i["since"]


WD2_ABS_TXT = "Stick nicht angeschlossen – keine Aktion (kein Neustart, keine USB-Neuverbindung, kein Pi-Neustart)"


def _wd2_absent(pl):
    """Stick dieses Planers nicht am USB (prepper-sdr: pin_err "Stick <SN> fehlt", active "nostick"). Andere USB-Geraete (z. B. Airspy 1d50:60a1) zaehlen nie."""
    try:
        return str(getattr(pl, "pin_err", "") or "").startswith("Stick ") or getattr(pl, "active", None) == "nostick"
    except Exception:
        return False


def _wd2_abs_tick(pl, s, i, now, msgs):
    """Stick fehlt: Vorfall bleibt (kein Schliessen, keine Eskalation, Sperrgrund sichtbar); Stick wieder da: Eskalation zaehlt neu ab jetzt."""
    if _wd2_absent(pl):
        if not i.get("abs"):
            i["abs"] = 1
            msgs.append(("wd_block", "%s nicht angeschlossen (SN %s) – Watchdog wartet, keine Aktion" % (_wd_name(s["n"], i), cfg_serial(pl.cfg)), i.get("ch"), "rot"))
        i["block"] = WD2_ABS_TXT
        _WD["dirty"] = True
        return True
    if i.get("abs"):
        i.update(abs=0, t0=int(now), restart_n=0, usb_n=0, act=None, act_t=None, chk=0, block=None, blk_t=0, fb_fail=0)
        s["fail_n"] = 0
        msgs.append(("wd_block", "%s wieder angeschlossen – Watchdog prüft neu, Eskalation ab %s" % (_wd_name(s["n"], i), _wd_hm(now, now)), i.get("ch"), "gelb"))
        _WD["dirty"] = True
    return False


def _wd2_pre_tick(pl, d, s, i, now, msgs):
    """Vor der Stufen-Auswertung: Stick fehlt = warten; Uebernahme-Vorfall kennzeichnen; Uebernahme beendet = Vorfall zu (Stick 2 zurueck im Hobby-Betrieb)."""
    try:
        if not (s and i):
            return i
        if _wd2_abs_tick(pl, s, i, now, msgs):
            return i
        if i.get("block") == WD2_ALIVE_TXT and not _wd2_alive(pl, i, now):
            i["block"] = None          # sdrWd2: Rueckfall 10C nicht mehr ok -> Wartegrund weg
        ta = _t2_alarm(pl)
        is5 = str(i.get("ch") or "").upper() == T2_CH_ALARM and i.get("src") == "dab"
        if ta and is5 and not i.get("to"):
            i["to"] = 1
            _WD["dirty"] = True
        if not ta and (i.get("to") or (is5 and pl.role == "rot" and t2_on(pl))):
            msgs.append(("wd_ok", "%s Vorfall beendet: Übernahme aus (5C ohne Sync %s–%s, %s) – Stick 2 zurück im Hobby-Betrieb" % (
                _wd_name(s["n"], i), _wd_hm(i["since"], now), _wd_hm(now, now), _wd_dur(now - i["since"])), i.get("ch"), "ok"))
            s["last_inc"] = {"since": i["since"], "end": int(now), "act": i.get("act"), "usb_n": i.get("usb_n"), "reboot_n": i.get("reboot_n"), "why": "Übernahme aus"}
            s["inc"] = None
            s["fail_n"] = 0
            _WD["dirty"] = True
            return None
    except Exception as e:
        print("sdrWd2 Uebernahme:", e, flush=True)
    return i


def _wd2_view_abs(pl, v, now):
    """Anzeige je Stick: fehlt der Stick am USB, klar grau "Stick N nicht angeschlossen", egal ob Vorfall offen (keine Eskalation)."""
    try:
        if not _wd2_absent(pl):
            return v
        n = int(v.get("n") or getattr(pl, "stickno", 1) or 1)
        t = "Stick %d nicht angeschlossen (SN %s)" % (n, v.get("sn") or "?")
        v.update(lvl="grau", absent=True, stage=0, block=WD2_ABS_TXT, hl="Stick %d nicht angeschlossen" % n, short=t + " – Einzelbetrieb mit Stick %d" % (3 - n if n in (1, 2) else 1),
                 txt=t + " · Watchdog wartet, keine Aktion" + (" · letzter Empfang %s" % _wd_hm(v.get("last_ok"), now) if v.get("last_ok") else ""),
                 hint="USB-Stecker prüfen bzw. Stick wieder anstecken – danach prüft der Watchdog neu")
    except Exception as e:
        print("sdrWd2 Anzeige fehlt:", e, flush=True)
    return v


def _wd2_view(pl, i, v, c, now, nm):
    """Anzeige: "(vor Start)", Uebernahme gelb (10C ok) / rot (auch 10C ohne Sync), Kurztext fuer Funk-Lage."""
    try:
        hm = _wd_hm(i["since"], now)
        pre = " (vor Start)" if i.get("pre") else ""
        v["pre"], v["to"] = bool(i.get("pre")), bool(i.get("to"))
        if pre:
            v["txt"] = v["txt"].replace("kein Sync seit %s" % hm, "kein Sync seit %s%s" % (hm, pre), 1)
        v["short"] = "SDR läuft, %s ohne Empfang seit %s%s" % (v.get("ch") or "Stick %s" % v.get("n"), hm, pre)
        if not i.get("to"):
            return v
        if _wd2_alive(pl, i, now):
            v.update(lvl="gelb", hl="5C ohne Sync, Rückfall 10C ok", block=WD2_ALIVE_TXT,
                     short="Übernahme aktiv · 5C ohne Sync seit %s%s · Rückfall 10C ok" % (hm, pre),
                     txt="Stick %d · Übernahme aktiv · 5C ohne Sync seit %s%s · Rückfall 10C ok (zuletzt %s) · Watchdog wartet" % (
                         int(v.get("n") or 2), hm, pre, _wd_hm(i.get("fb_ok_t"), now)))
        else:
            dead = _wd2_dead(i)
            fb = ((" · 10C ohne Sync seit %s" % _wd_hm(i["fb_ok_t"], now)) if i.get("fb_ok_t") else " · 10C ohne Sync") if dead else ""
            v["hl"] = "Übernahme: 5C%s ohne Sync" % (" + 10C" if dead else "")
            v["short"] = "Übernahme aktiv · 5C ohne Sync seit %s%s%s" % (hm, pre, fb)
            v["txt"] = v["txt"].replace("%s kein Sync seit %s%s" % (nm, hm, pre), "Stick %d · Übernahme aktiv · 5C ohne Sync seit %s%s%s" % (int(v.get("n") or 2), hm, pre, fb), 1)
            if i.get("block") == WD2_ALIVE_TXT:      # alter Wartegrund (10C ok) gilt nicht mehr
                v["block"] = None
                v["txt"] = v["txt"].replace(" · gesperrt: %s" % WD2_ALIVE_TXT, "", 1)
            if dead and not int(v.get("stage") or 0):
                v["txt"] = v["txt"].replace(" · kurz ohne Sync", " · Neustart frühestens %s" % _wd_hm(_wd2_t0(pl, i) + c["wd_restart_min"] * 60, now), 1)
            # Ampel: 5C (Alarmkanal) aus = mind. gelb ab wd_yellow_min seit letztem 5C-Sync; rot erst, wenn auch 10C ausfaellt (Stick liefert gar nichts) oder Stufe >= 2
            lv = v.get("lvl")
            if dead or int(v.get("stage") or 0) >= 2:
                lv = "rot"
            elif now - i["since"] >= c["wd_yellow_min"] * 60:
                lv = "gelb"
            elif lv not in ("grau",):
                lv = "ok"
            v["lvl"] = lv
    except Exception as e:
        print("sdrWd2 Anzeige:", e, flush=True)
    return v


def selftest_sdrwd2():
    import tempfile
    old_h, old_env = globals()["_wd_helper"], os.environ.get("SDR_WD_HELPER")
    old_sys = os.environ.get("SDR_SYSFS_USB")
    os.environ["SDR_WD_HELPER"] = "/nonexistent/sdrwd2-selftest"     # echtes Hilfsprogramm nie
    calls = []
    try:
        _WD["live"] = True
        r = _selftest_sdrwd2b(tempfile.mkdtemp(prefix="sdrwd2-"), calls)
    finally:
        globals()["_wd_helper"] = old_h
        for k, v in (("SDR_WD_HELPER", old_env), ("SDR_SYSFS_USB", old_sys)):
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        _T2_TO.clear()
        _WD.update(d=None, base=None, dirty=False, saved=0.0, busy=None, cfg=None, cfg_key=None, started=set(), helper=None, boot_msgs=[], live=False, start=time.time())
    print("selftest sdrWd2 ok (Übernahme: 5C ohne Sync + 10C ok = gelb, kein Schließen/Öffnen, %d Technik-Einträge in 2 h; 5C + 10C ohne Sync = Stick 2 Neustart + %d USB, Pi-Neustart gesperrt; "
          "Stick 1 hängt während Übernahme = Stufe 2 + 3; 5C-Sync bzw. Übernahme-Ende schließt; Beginn vor Start = (vor Start), keine Sofort-Eskalation; "
          "Stick nicht angeschlossen = grau ohne Aktion, Airspy ignoriert, wieder da = Eskalation neu; Fake-Hilfsprogramm %d Aufrufe, nichts echt)" % r, flush=True)


def _selftest_sdrwd2b(tmp, calls):
    nh = [0]

    def fake_helper(args, timeout):
        nh[0] += 1
        calls.append(list(args))
        assert args[0] in ("usb-reset", "reboot", "check") and (args[0] != "usb-reset" or WD_SN_RE.match(args[1]))
        return 0, "fake %s" % args[0]
    globals()["_wd_helper"] = fake_helper
    _WD.update(d=None, base=None, dirty=False, saved=0.0, busy=None, cfg=None, cfg_key=None, started=set(), helper=None, boot_msgs=[], start=0.0)
    sysfs = os.path.join(tmp, "sysfs")
    for n, sn in (("1-1.1", "19348831"), ("1-1.2", "72055505")):
        os.makedirs(os.path.join(sysfs, n))
        for k, v in (("idVendor", "0bda"), ("idProduct", "2838"), ("serial", sn), ("product", "RTL2838UHIDIR")):
            open(os.path.join(sysfs, n, k), "w").write(v + "\n")
    os.environ["SDR_SYSFS_USB"] = sysfs
    save_cfg_keys(tmp, {"stick2": {"serial": "72055505", "enabled": True}, "dab": ["11D"]})
    m = Planner(tmp)
    w = Planner(tmp, stick=2, main=m)
    m.worker = w
    m.set_role("bc"); w.set_role("rot")
    m.t2 = True                                   # Teil 2 aktiv wie im Dienst (Stick 2 = Alarm-Stick)
    killed = []
    for x in (m, w):
        x.kill = (lambda q: (lambda: killed.append(q.stickno)))(x)
        x.resolve = (lambda q: (lambda: setattr(q, "dev_idx", q.stickno - 1)))(x)
        x.log = lambda *a: None
    with _SDRLOG_LOCK:
        sdrlog_get(tmp).quiet = True
    t0 = 1790000000.0
    m.active, w.active = "dab:0", "dab:0"

    def ev():
        return [x for x in (load_json(p(SDRLOG_FILE, tmp), {}) or {}).get("ev") or [] if str(x.get("k") or "").startswith("wd_")]

    def s2():
        return _WD["d"]["sticks"].get("72055505") or {}

    def s1():
        return _WD["d"]["sticks"].get("19348831") or {}
    # Uebernahme an (Knopf), 5C zuletzt echt vor 1 h; Rueckfall 10C hat Sync
    write_json(p(T2_TAKEOVER, tmp), {"on": True, "since": int(t0), "src": "manual", "why": "Knopf auf der Funk-Seite", "by": "dashboard"})
    _T2_TO.clear()
    assert _t2_alarm(w) and not _t2_alarm(m) and _wd2_kind(w, "10C", "dab") == "fb" and _wd2_kind(w, "5C", "dab") == "alarm" and _wd2_kind(m, "11D", "dab") is None
    w.sbc.d["dab"]["5C"] = {"ch": "5C", "t": int(t0 - 3600), "rx": False}
    m.sbc.d["dab"]["11D"] = {"ch": "11D", "t": int(t0), "rx": True}
    wd_check(m, "dab", True, t0, "11D")
    n_ev0 = len(ev())
    for k in range(0, 121):
        t = t0 + 60 * k
        if k % 10 == 0:
            wd_check(w, "dab", False, t, "5C", "kein Sync")
        else:
            wd_check(w, "dab", True, t, "10C")
        wd_tick(w, t + 1)
        if k == 2:
            i0 = dict(s2()["inc"])
        if k % 5 == 0:
            wd_check(m, "dab", True, t + 2, "11D"); wd_tick(m, t + 3)
    i = s2()["inc"]
    assert i and i["since"] == int(t0 - 3600) and i["to"] == 1 and i["ch"] == "5C" and i["since"] == i0["since"] and not i["restart_n"] and not i["usb_n"], i
    assert not calls and not killed, (calls, killed)
    e2 = ev()[n_ev0:]
    assert not any(x["k"] == "wd_ok" for x in e2) and len(e2) <= 2, e2           # kein Schliessen/Oeffnen alle 10 min
    v = wd_view(w, t0 + 60 * 120 + 5)
    assert v["lvl"] == "gelb" and v["short"].startswith("Übernahme aktiv · 5C ohne Sync seit ") and v["short"].endswith(" · Rückfall 10C ok") and "Watchdog wartet" in v["txt"], v
    h = w.stick_health(t0 + 60 * 120 + 5)
    assert h["lvl"] in ("gelb", "rot") and h["txt"] == "5C ohne Sync, Rückfall 10C ok" and h["wd"]["to"], h
    n_spam = len(e2)
    # Jetzt auch 10C ohne Sync: Stick haengt -> Neustart, dann USB-Neuverbindung (nur SN Stick 2), Pi-Neustart gesperrt (Uebernahme)
    tb = t0 + 60 * 121
    for k in range(0, 170):
        t = tb + 60 * k
        wd_check(w, "dab", False, t, "5C" if k % 10 == 0 else "10C", "kein Sync")
        wd_tick(w, t + 1)
        if k == 1:
            assert wd_view(w, t + 2)["lvl"] == "gelb", wd_view(w, t + 2)          # erster 10C-Fehlschlag: nie kurz "ok", gelb bleibt
        if k == 2:
            vv = wd_view(w, t + 2)
            assert vv["lvl"] == "rot" and vv["short"].endswith(" · 10C ohne Sync seit %s" % _wd_hm(t0 + 60 * 119, t + 2)) and "Neustart frühestens" in vv["txt"] and "Stick lebt" not in vv["txt"] and " + 10C" not in vv["short"], vv   # 2x 10C ohne Sync = rot
        if k == 20:
            assert not killed and wd_view(w, t + 2)["lvl"] == "rot", (killed, wd_view(w, t + 2))       # Eskalation zaehlt ab letztem 10C-Sync, nicht ab 5C-Beginn
        if k == 40:
            assert killed == [2] and s2()["inc"]["restart_n"] == 1 and not calls, (killed, calls)
        if k % 5 == 0:
            wd_check(m, "dab", True, t + 2, "11D"); wd_tick(m, t + 3)
    i = s2()["inc"]
    assert calls == [["usb-reset", "72055505"], ["usb-reset", "72055505"]] and i["usb_n"] == 2 and i["to"] == 1 and i["ch"] == "5C", (calls, i)
    assert "kein Pi-Neustart" in (i["block"] or "") and "Übernahme" in i["block"] and not _WD["d"]["pending"] and not _WD["d"]["reboots"], i
    v = wd_view(w, tb + 60 * 170)
    assert v["lvl"] == "rot" and v["short"].startswith("Übernahme aktiv · 5C ohne Sync seit") and " · 10C ohne Sync seit " in v["short"] and "10C ohne Sync seit" in v["txt"] and v["hl"] == "Übernahme: 5C + 10C ohne Sync", v
    tx = [x["text"] for x in ev()]
    assert any("Stick 2 · 5C kein Sync seit" in x and "Stufe 4 gesperrt: Alarm-Übernahme" in x for x in tx) and any("Stufe 3 USB-Neuverbindung (2/2, nur SN 72055505)" in x for x in tx), tx[-6:]
    # Stick 1 haengt waehrend der Uebernahme: Stufen 2 und 3 laufen, Pi-Neustart bleibt gesperrt
    tc = tb + 60 * 200
    killed.clear(); calls.clear()
    for k in range(1, 75):
        t = tc + 60 * k
        wd_check(m, "dab", False, t, "11D", "kein Sync: Ensemble leer, SNR None")
        wd_tick(m, t + 1)
    assert 1 in killed and calls == [["usb-reset", "19348831"], ["usb-reset", "19348831"]] and s1()["inc"]["usb_n"] == 2, (killed, calls, s1()["inc"])
    assert "kein Pi-Neustart" in (s1()["inc"]["block"] or "") and not _WD["d"]["reboots"], s1()["inc"]
    wd_check(m, "dab", True, tc + 60 * 76, "11D")
    assert not s1()["inc"]
    # 5C-Sync schliesst den Uebernahme-Vorfall (eine Meldung)
    n1 = len(ev())
    w.sbc.d["dab"]["5C"] = {"ch": "5C", "t": int(tc + 60 * 77), "rx": True}
    wd_check(w, "dab", True, tc + 60 * 77, "5C")
    assert not s2()["inc"] and s2()["last_ok_src"] == "DAB 5C" and [x["k"] for x in ev()[n1:]] == ["wd_ok"], ev()[n1:]
    # neuer 5C-Vorfall: Beginn = letzter 5C-Sync (nicht der letzte 10C-Sync); Uebernahme-Ende schliesst ihn
    td = tc + 60 * 80
    wd_check(w, "dab", True, td, "10C")
    wd_check(w, "dab", False, td + 60, "5C", "kein Sync"); wd_check(w, "dab", False, td + 120, "5C", "kein Sync")
    assert s2()["inc"]["since"] == int(tc + 60 * 77) and s2()["inc"]["to"] == 1, s2()["inc"]
    write_json(p(T2_TAKEOVER, tmp), {"on": False, "off_t": int(td + 150), "by": "dashboard"})
    _T2_TO.clear()
    n1 = len(ev())
    wd_tick(w, td + 180)
    assert not s2()["inc"] and s2()["last_inc"]["why"] == "Übernahme aus" and any("Übernahme aus" in x["text"] for x in ev()[n1:]), ev()[n1:]
    wd_tick(w, td + 240)
    assert not s2()["inc"] and wd_view(w, td + 240)["lvl"] == "ok"
    # alter sdrWd-Vorfall (ohne v2) auf 5C, Uebernahme schon aus: Umstellung + Schliessen statt ewig rot
    _WD["d"]["sticks"]["72055505"]["inc"] = _wd_clean({"sticks": {"72055505": {"n": 2, "inc": {"since": int(td - 5 * 3600), "t0": int(td - 5 * 3600), "ch": "5C", "src": "dab"}}}})["sticks"]["72055505"]["inc"]
    assert s2()["inc"]["v2"] == 0
    _wd2_migrate(_WD["d"], td + 300)
    assert s2()["inc"]["pre"] == 1 and s2()["inc"]["t0"] == int(td + 300) and s2()["inc"]["v2"] == 1
    wd_tick(w, td + 301)
    assert not s2()["inc"]
    # Beginn vor Watchdog-Start: "(vor Start)", Eskalation ab Start
    ts = td + 3600
    _WD["start"] = ts
    killed.clear(); calls.clear()
    wd_check(m, "dab", True, ts - 4 * 3600, "11D")
    m.sbc.d["dab"]["11D"] = {"ch": "11D", "t": int(ts - 4 * 3600), "rx": False}
    wd_check(m, "dab", False, ts + 60, "11D", "kein Sync")
    i = s1()["inc"]
    assert i["since"] == int(ts - 4 * 3600) and i["pre"] == 1 and i["t0"] == int(ts), i
    wd_check(m, "dab", False, ts + 120, "11D", "kein Sync"); wd_tick(m, ts + 121)
    v = wd_view(m, ts + 125)
    assert v["lvl"] == "ok" and "(vor Start)" in v["txt"] and v["short"].endswith("(vor Start)") and not killed and not calls, v
    for k in range(3, 29):
        wd_check(m, "dab", False, ts + 60 * k, "11D", "kein Sync"); wd_tick(m, ts + 60 * k + 1)
    v = wd_view(m, ts + 60 * 29)
    assert not killed and not calls and v["lvl"] == "gelb" and "(vor Start)" in v["txt"], (killed, v)
    for k in range(29, 34):
        wd_check(m, "dab", False, ts + 60 * k, "11D", "kein Sync"); wd_tick(m, ts + 60 * k + 1)
    assert killed == [1] and s1()["inc"]["restart_n"] == 1 and not calls, (killed, calls)
    # Zustand mit Zusatzfeldern uebersteht Neustart
    with _WD_LOCK:
        _wd_save(tmp, ts + 60 * 35, force=True)
    _WD.update(d=None, base=None, started=set(), boot_msgs=[])
    with _WD_LOCK:
        ii = _wd_state(tmp, ts + 60 * 36)["sticks"]["19348831"]["inc"]
    assert ii["pre"] == 1 and ii["v2"] == 1 and ii["t0"] == int(ts) and ii["restart_n"] == 1, ii
    # Sperre fuer Stufen 2-3 bleibt: echter Alarm im Lagezentrum
    write_json(p(WD_GATE, tmp), {"t": int(ts + 60 * 36), "alarm": True})
    assert _wd_block(m, ts + 60 * 36, "19348831", "usb") == "echter Alarm im Lagezentrum" and _wd_block(m, ts + 60 * 36, "19348831", "restart") == "echter Alarm im Lagezentrum"
    write_json(p(WD_GATE, tmp), {"t": int(ts + 60 * 36), "alarm": False})
    write_json(p(T2_TAKEOVER, tmp), {"on": True, "since": int(ts), "src": "manual", "by": "dashboard"})
    _T2_TO.clear()
    assert _wd_block(m, ts + 60 * 36, "19348831", "usb") is None and "kein Pi-Neustart" in _wd_block(m, ts + 60 * 36, "19348831", "reboot")
    assert _wd2_clean_inc({"fb_ok": "x", "to": "1", "v2": 1}) == {"v2": 1, "to": 0, "pre": 0, "fb_t": None, "fb_ok": None, "fb_ok_t": None, "fb_fail": 0, "abs": 0}
    # Stick 2 nicht angeschlossen (z. B. nur ein RTL-Stick + Airspy am USB) waehrend Uebernahme und offenem Vorfall: rot "nicht angeschlossen", keine Aktion, kein Absturz
    os.makedirs(os.path.join(sysfs, "1-1.3"))
    for k, v2 in (("idVendor", "1d50"), ("idProduct", "60a1"), ("serial", "26c868dc2d4b8a1f"), ("product", "AirSpy")):
        open(os.path.join(sysfs, "1-1.3", k), "w").write(v2 + "\n")
    assert [x["serial"] for x in stick_info(w.cfg["usb_ids"])] == ["19348831", "72055505"]     # Airspy (1d50:60a1) zaehlt nie als Stick
    os.rename(os.path.join(sysfs, "1-1.2", "idVendor"), os.path.join(sysfs, "1-1.2", "idVendor.abgezogen"))   # Stick 2 abgezogen
    assert [x["serial"] for x in stick_info(w.cfg["usb_ids"])] == ["19348831"]
    killed.clear(); calls.clear()
    te = ts + 60 * 40
    w.sbc.d["dab"]["5C"] = {"ch": "5C", "t": int(te - 7200), "rx": False}
    wd_check(w, "dab", False, te, "5C", "kein Sync"); wd_check(w, "dab", False, te + 60, "5C", "kein Sync")
    assert s2()["inc"] and s2()["inc"]["to"] == 1
    w.pin_err, w.active = "Stick 72055505 fehlt", "nostick"
    n1 = len(ev())
    for k in range(2, 200):
        wd_tick(w, te + 60 * k)
    i = s2()["inc"]
    assert i and i["abs"] == 1 and not i["restart_n"] and not i["usb_n"] and not killed and not calls and not _WD["d"]["pending"] and not _WD["d"]["reboots"], (i, killed, calls)
    eb = [x for x in ev()[n1:] if x["k"] != "wd_start"]
    assert [x["k"] for x in eb] == ["wd_block"] and "nicht angeschlossen" in eb[0]["text"], eb      # eine Meldung, nicht alle 60 s
    v = wd_view(w, te + 60 * 200)
    assert v["lvl"] == "grau" and v["absent"] and v["short"].startswith("Stick 2 nicht angeschlossen (SN 72055505)") and "Einzelbetrieb mit Stick 1" in v["short"] and v["block"] == WD2_ABS_TXT, v
    h = w.stick_health(te + 60 * 200)
    assert h["txt"] == "Stick fehlt" and h["wd"]["absent"] and h["wd"]["lvl"] == "grau", h          # stick_health selbst wie bisher (Teil 2)
    w.sbc.d["dab"]["5C"] = {"ch": "5C", "t": int(te - 7200), "rx": False}
    w2 = Planner(tmp, stick=2, main=m); w2.pin_err, w2.active = "Stick 72055505 fehlt", "nostick"
    assert wd_view(w2, te)["lvl"] == "grau" and wd_view(w2, te)["absent"]          # auch ohne Vorfall/Pruefung klar "nicht angeschlossen"
    # wieder angesteckt: Eskalation zaehlt neu ab jetzt, keine Sofort-Aktion
    w.pin_err, w.active = None, "dab:0"
    tr = te + 60 * 201
    wd_tick(w, tr)
    i = s2()["inc"]
    assert i and not i["abs"] and i["t0"] == int(tr) and i["block"] is None and s2()["fail_n"] == 0, i
    for k in range(1, 5):
        wd_check(w, "dab", False, tr + 60 * k, "5C" if k == 1 else "10C", "kein Sync"); wd_tick(w, tr + 60 * k + 1)
    assert not killed and not calls, (killed, calls)
    # Stick 1 fehlt (Einzelbetrieb mit Stick 2): Anzeige rot, keine Aktion fuer Stick 1
    m.pin_err, m.active = "Stick 19348831 fehlt", "nostick"
    for k in range(5, 120):
        wd_check(m, "dab", False, tr + 60 * k, "11D", "kein Sync") if k < 7 else None
        wd_tick(m, tr + 60 * k + 2)
    assert not [x for x in calls if x[0] == "usb-reset" and x[1] == "19348831"] and 1 not in killed and wd_view(m, tr + 60 * 120)["short"].startswith("Stick 1 nicht angeschlossen"), (calls, killed)
    return n_spam, 2, nh[0]
# ===== /sdrWd2 =====
WDB_EOF
EXPECT_BSM="0857da6b4a3a40acf4ff8ddc3879cf91a94aa25f98863acc0cd42f85567206f0"
cat > "$W/wd2_sm_block.py" << 'WDS_EOF'
# ===== sdrWd2: Anzeige Daten-Watchdog - Kurztext je Stick aus prepper-sdr (Uebernahme "Übernahme aktiv · 5C ohne Sync seit .. · Rückfall 10C ok", "(vor Start)") fuer Funk-Lage/Lage-Text; Lage-Stufe/Label/Mesh-Heartbeat unveraendert; nur lesen, sendet nichts =====


def _wd2_sum(sticks, lvl, txt, short, fresh):
    """Stick nicht angeschlossen: grau je Stick; Gesamtstufe aus den angeschlossenen Sticks, Kurztext nennt den fehlenden Stick."""
    try:
        ab = [s for s in sticks or [] if s.get("absent")]
        if not ab or not fresh:
            return lvl, txt, short
        pr = [s for s in sticks if not s.get("absent")]
        if not pr:
            return "grau", "; ".join(str(s.get("txt") or "") for s in ab), " · ".join(str(s.get("short") or "") for s in ab)
        if lvl in ("ok", "grau"):
            lv = max((s.get("lvl") or "grau" for s in pr), key=lambda x: WD_LVL_ORDER.get(x, 0))
            ok = " · ".join("Stick %s %s" % (s.get("n"), "ok" if s.get("lvl") == "ok" else "wird geprüft") for s in pr)
            return lv, "%s; %s" % (ok, "; ".join(str(s.get("txt") or "") for s in ab)), "%s · %s" % (ok, " · ".join(str(s.get("short") or "") for s in ab))
    except Exception as e:
        print("sdr_manager sdrWd2 Zusammenfassung:", e, flush=True)
    return lvl, txt, short


def selftest_sdrwd2():
    now = int(time.time())
    g = {"reboots_today": 0, "last_reboot": None, "reboot_fail_n": 0, "reboot_max_fail": 3, "stopped": False, "pending": None, "on": True, "helper": "bereit", "cfg": {}}
    w1 = {"sn": "19348831", "n": 1, "lvl": "ok", "ch": "11D", "src": "dab", "txt": "Stick 1 · 11D Empfang ok", "g": g}
    w2 = {"sn": "72055505", "n": 2, "lvl": "gelb", "ch": "5C", "src": "dab", "since": now - 5 * 3600, "stage": 0, "to": True, "pre": False,
          "short": "Übernahme aktiv · 5C ohne Sync seit 10:23 · Rückfall 10C ok", "txt": "Stick 2 · Übernahme aktiv · 5C ohne Sync seit 10:23 · Rückfall 10C ok (zuletzt 15:20) · Watchdog wartet", "g": g}
    s = wd_status({"t": now - 5, "stick_health": {"wd": w1}, "stick_health2": {"wd": w2}}, now)
    assert s["lvl"] == "gelb" and s["short"] == w2["short"] and s["sticks"][1]["to"] is True and s["sticks"][1]["short"] == w2["short"], s
    base = t4_level(None, [], {}, None)
    lv = wd_level(base, {"wd": s})
    assert lv["lvl"] == base["lvl"] and lv["label"] == base["label"] and lv["blink"] == base["blink"] and "Rückfall 10C ok" in lv["why"] and lv["sdr"]["lvl"] == "gelb", lv
    w3 = dict(w1, lvl="gelb", since=now - 4 * 3600, pre=True, short=None, txt="Stick 1 · 11D kein Sync seit 11:00 (vor Start) · kurz ohne Sync")
    s3 = wd_status({"t": now, "stick_health": {"wd": w3}}, now)
    assert s3["short"].startswith("SDR läuft, 11D ohne Empfang seit ") and s3["sticks"][0]["pre"] is True, s3
    w4 = dict(w1, lvl="rot", since=now - 4 * 3600, pre=True, short="SDR läuft, 11D ohne Empfang seit 11:00 (vor Start)")
    assert wd_status({"t": now, "stick_health": {"wd": w4}}, now)["short"].endswith("(vor Start)")
    wa = dict(w2, lvl="grau", absent=True, stage=0, to=False, short="Stick 2 nicht angeschlossen (SN 72055505) – Einzelbetrieb mit Stick 1",
              txt="Stick 2 nicht angeschlossen (SN 72055505) · Watchdog wartet, keine Aktion")
    sa = wd_status({"t": now, "stick_health": {"wd": w1}, "stick_health2": {"wd": wa}}, now)
    assert sa["lvl"] == "ok" and sa["short"] == "Stick 1 ok · Stick 2 nicht angeschlossen (SN 72055505) – Einzelbetrieb mit Stick 1" and sa["sticks"][1]["absent"] is True, sa
    sb = wd_status({"t": now, "stick_health": {"wd": dict(w1, lvl="rot", short="SDR läuft, 11D ohne Empfang seit 11:00")}, "stick_health2": {"wd": wa}}, now)
    assert sb["lvl"] == "rot" and sb["short"].startswith("SDR läuft, 11D"), sb
    assert wd_status({"t": now, "stick_health2": {"wd": wa}}, now)["lvl"] == "grau"
    lv = wd_level(base, {"wd": sa})
    assert lv["lvl"] == base["lvl"] and lv["label"] == base["label"], lv
    return "sdr_manager selftest sdrWd2 ok (Kurztext je Stick: Übernahme gelb mit Rückfall 10C, (vor Start), Stick nicht angeschlossen grau mit Einzelbetrieb-Hinweis; Lage-Stufe/Label/Mesh-Heartbeat unverändert)"
# ===== /sdrWd2 =====
WDS_EOF
EXPECT_BDA="ff787e233b1bcc814ce6a88ddce2abe078ccc136ed408d9253cdf3556d3272c3"
cat > "$W/wd2_dash_block.py" << 'WDD_EOF'
# ===== sdrWd2: /funk Daten-Watchdog-Kasten ruhig - jede Zeile genau eine Zeile (Kurztext mit Auslassung, voller Text als Tooltip, per Tipp aufklappbar), Kopfzeile immer da (feste Zeilenzahl); nur Anzeige, sendet nichts =====
def _wd2_dash_ok():
    """Pruefung der sdrWd2-Anzeigeteile in _WD_CSS/_WD_JS (beim Laden von sdrWd aufgerufen)."""
    c, j = globals().get("_WD_CSS", ""), globals().get("_WD_JS", "")
    return ("/* sdrWd2: Watchdog-Zeilen einzeilig */" in c and "height:1.35em;white-space:nowrap;overflow:hidden" in c and ".wd-r.wd-open" in c
            and "function fx(r,k,t)" in j and "W.lvl==='gelb'||W.lvl==='rot'||" not in j and j.count("fx(") == 3 and "method:" not in j and j.count("fetch(") == 1)
# ===== /sdrWd2 =====
WDD_EOF
EXPECT_AE="8ec4d9759be7c1624c4c9cdabaffe53e433608fdcb7344755b2ad2ed5e65d996"
cat > "$W/air_edits.py" << 'AIE_EOF'
# sdrAir: Stellen (alt, neu) auf dem Stand nach sdrWd2. Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
# Watchdog-Zustand: Airspy-Seriennummer (16 Hex) und Planer-Platz 3 (Hobby) behalten
('''        if not (isinstance(sn, str) and SERIAL_RE.match(sn) and isinstance(s, dict)):
            continue
        x = {"n": int(s.get("n") or 1) if s.get("n") in (1, 2) else 1,''', '''        if not (isinstance(sn, str) and (SERIAL_RE.match(sn) or AIR_SN_RE.match(sn)) and isinstance(s, dict)):   # sdrAir: Airspy 16 Hex
            continue
        x = {"n": int(s.get("n") or 1) if s.get("n") in (1, 2, 3) else 1,'''),
('''        selftest_sdrwd2()
''', '''        selftest_sdrwd2()
        selftest_sdrair()
'''),
('''    assert StateBC.on_dab is _sdrlog_on_dab and Planner.want is _sdrlog_want and Planner.collect_meteor is _sdrlog_collect_meteor''',
 '''    assert StateBC.on_dab is _sdrlog_on_dab and Planner.want in (_sdrlog_want, globals().get("_air_want")) and Planner.collect_meteor is _sdrlog_collect_meteor   # sdrAir: want umhuellt'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SM_EDITS = [
('''        out["roles"] = t2.get("roles") or {}
''', '''        out["roles"] = t2.get("roles") or {}
        out["air"], out["devs"] = bool(t2.get("air")) or sm_air_on(base), t2.get("devs") if isinstance(t2.get("devs"), list) else []   # sdrAir
'''),
('''        mon = bool(to.get("on")) and isinstance(s2, dict) and s2.get("alarm") is True''', '''        mon = (bool(to.get("on")) or sm_air_on(base)) and isinstance(s2, dict) and s2.get("alarm") is True   # sdrAir: 5C fest = dauernd ueberwacht'''),
('''    for k in ("stick_health", "stick_health2"):
        h = st.get(k)''', '''    for k in ("stick_health", "stick_health2", "stick_health3"):   # sdrAir: Hobby-Geraet
        h = st.get(k)'''),
('''"short", "pre", "to", "absent")})''', '''"short", "pre", "to", "absent", "name")})'''),
('''    g = next((v.get("g") for k in ("stick_health", "stick_health2") for v''', '''    g = next((v.get("g") for k in ("stick_health", "stick_health2", "stick_health3") for v'''),
('''            ok = " · ".join("Stick %s %s" % (s.get("n"), "ok"''', '''            ok = " · ".join("%s %s" % (s.get("name") or "Stick %s" % s.get("n"), "ok"'''),
('''    if to.get("on"):
        fb = bool(s2x.get("fb"))''', '''    if to.get("on") or sm_air_on(base):   # sdrAir: Stick 1 fest 5C / Rueckfall 10C
        fb = bool(s2x.get("fb"))'''),
('''    print(selftest_sdrwd2())
''', '''    print(selftest_sdrwd2())
    print(selftest_sdrair())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
DASH_EDITS = [
# /funk Funk-Lage: Geraetenamen, 5C fest ohne Uebernahme, Hobby/ohne Rolle sichtbar, Namen vor TII-Kennungen (5C/10C wie 11D)
('''var sig=JSON.stringify([D4&&D4.level,D4&&D4.sdr,''', '''var sig=JSON.stringify([D2&&D2.devs,D2&&D2.air,D2&&D2.fig&&[D2.fig['5C'],D2.fig['10C']],D4&&D4.level,D4&&D4.sdr,'''),
('''kv(box,'Stick 1',(s1.sn?''', '''var AIR=!!(D2&&D2.air)||!!s1.fest;kv(box,AIR?(s1.name||(r.s1||{}).name||'11D'):'Stick 1',(s1.absent?'nicht angeschlossen – keine Aktion · ':'')+(s1.sn?'''),
('''kv(box,'Stick 2',to.on?(''', '''if(AIR)kv(box,s2.name||'5C',s2.absent?('nicht angeschlossen – 5C/10C ohne Empfang, keine Aktion'+(s2.sn?' · SN '+s2.sn:'')):((s2.sn?'SN '+s2.sn+' · ':'')+(s2.state||'')+(((r.s2||{}).mode)?' · '+r.s2.mode:'')),s2.absent?'#94a3b8':(s2.fb?'#fb923c':'#4ade80'),true);else kv(box,'Stick 2',to.on?('''),
('''if(to.on||s2.takeover)kv(box,'Empfang 2',''', '''if(to.on||s2.takeover||(AIR&&!s2.absent))kv(box,'Empfang 2','''),
('''kv(box,'ASA-Dienst',''', '''if(AIR){var c5=s2.fb?'10C':'5C',f5=((D2&&D2.fig)||{})[c5]||{};var t5=(f5.tii||[]).map(function(x){var c=p2(x.main)+'/'+p2(x.sub);return (x.mast&&!mname(c5,c))?tfix(x.mast,c5):tlab(c5,c,null);}).join(', ');
if(!s2.absent)kv(box,c5,(f5.ens||'–')+' · TII '+(t5||'–')+(f5.t?' · '+fmt(f5.t):''),'#cbd5e1');var s3=sd.s3||{};if(s3.name)kv(box,s3.name,(s3.absent?'nicht angeschlossen – keine Aktion':(s3.mode||s3.state||'–'))+(s3.sn?' · SN '+s3.sn:''),s3.absent?'#94a3b8':'#cbd5e1');
((D2&&D2.devs)||[]).forEach(function(x){if(!x.role&&x.present)kv(box,'ohne Rolle',x.name+' ('+x.usb+') · erkannt, ohne Rolle – nie benutzt','#94a3b8');});}
kv(box,'ASA-Dienst','''),
('''var to=(D2&&D2.takeover)||{};syncProxy('b1',!to.on);''', '''var to=(D2&&D2.takeover)||{};var s2s=d.querySelector('[data-slot=s2]');if(s2s)s2s.style.display=(D2&&D2.air)?'none':'';syncProxy('b1',!to.on);'''),
# t4-Kachel/Proxy: im Geraete-Register-Betrieb kein Knopf SDR 2 freigeben (keine Uebernahme mehr)
('''t._b.style.display=pre.on?'':'none';t._b.textContent=''', '''if(D.sdr.air)pre={};t._b.style.display=pre.on?'':'none';t._b.textContent='''),
# /pi Empfaenger: Airspy-Kennzeichen
('''bd.title=v==='S1'?''', '''bd.title=v==='AIR'?'läuft auf dem Airspy (SN '+(U.sna||'?')+')':v==='S1'?'''),
]
DASH_ANCHOR = "# ===== /funkUI =====\n"
AIE_EOF
EXPECT_ASD="0c249926b516d282e6058bcbae0215f16ecd096d12b7b6336bcc9c16770facb3"
cat > "$W/air_sdr_block.py" << 'AIB_EOF'
# ===== sdrAir: Geraete-Register (USB-ID + Seriennummer, Rollen in sdr_config.json devs) - Airspy R2 fest 11D (welle-cli -F airspy, Port 7979), Stick 1 fest 5C (Warnungen) mit Rueckfall 10C, Stick 2 Hobby; keine Uebernahme mehr; Geraet fehlt = grau "nicht angeschlossen", keine Eskalation; nur Empfang =====
# Register: devs = [{"name", "kind": rtl|airspy, "usb": "vid:pid", "serial", "role": 11D|5C|hobby|"", "ppm_sfx"}], devs_on = true. Planer je Rolle:
# 11D = Haupt-Planer (Port dab_port 7979, stick_health), 5C = Planer 2 (dab_port2 7981, stick_health2, Teil 2/4: 5C + Rueckfall 10C fest),
# hobby = Planer 3 (dab_port3 7983, stick_health3). Je Rolle hoechstens ein Geraet; weitere/unbekannte Geraete: "erkannt, ohne Rolle", nie benutzt.
# Airspy: nur welle-cli (kein rtl_tcp/rtl_fm/rtl_433/Kalibrierung), Gain-Leiter Linearitaet 0..21, CPU von welle-cli gemessen + nice.
# Stick fehlt/kommt wieder: wie bisher alle 15 s per sysfs (kein Dienst-Neustart), Watchdog wartet, Eskalation zaehlt danach neu.
AIR_USB = "1d50:60a1"
AIR_SN_RE = re.compile(r"^[0-9A-F]{16}$")
DEV_KIND_USB = {"rtl": ("0bda:2838", "0bda:2832"), "airspy": (AIR_USB,)}
DEV_ROLES = ("11D", "5C", "hobby")
DEV_SLOT = {"11D": 1, "5C": 2, "hobby": 3}
DEV_ROLE_TXT = {"11D": "fest 11D (BR Bayern)", "5C": "fest 5C (ASA DE, Warnungen) · Rückfall 10C", "hobby": "Hobby (RDS, QRM, Kalibrierung, 433, APRS)", "": "erkannt, ohne Rolle"}
AIR_LADDER = (16, 12, 19, 9, 21, "agc")   # Airspy R2: welle-cli -g = Linearitaets-Stufe 0..21; ohne Sync 2x -> naechste, zuletzt welle-AGC
AIR_CPU_WIN_S = 300.0
_AIR = {"bases": {}, "names": {}, "kinds": {}, "cache": {}}
DEFAULT_CFG.update({"devs_on": False, "devs": [], "air_fe": "airspy", "air_gain": None, "air_nice": 5, "air_cpu_max": 85,
                    "dab_port3": 7983, "dab_tcp_port3": 1239, "ppm3": 0, "ppm_cal3": None, "cal_hour3": 4, "ppm4": 0, "ppm_cal4": None, "cal_hour4": 4})


def _air_sn(kind, sn):
    """Seriennummer normieren: Airspy 'AIRSPY SN:44A4...' / '0x44a4...' -> 16 Hex gross; RTL unveraendert."""
    s = str(sn if sn is not None else "").strip()
    if kind == "airspy":
        s = s.upper()
        for pre in ("AIRSPY SN:", "0X"):
            if s.startswith(pre):
                s = s[len(pre):].strip()
    return s


def _air_kind(usb):
    u = str(usb or "").lower()
    return next((k for k, v in DEV_KIND_USB.items() if u in v), None)


def air_reg(cfg):
    """sdr_config.json devs -> Register oder None (devs_on fehlt/aus, kein gueltiges 11D-Geraet = altes Verhalten)."""
    if not isinstance(cfg, dict) or cfg.get("devs_on") is not True or not isinstance(cfg.get("devs"), list):
        return None
    try:
        key = json.dumps(cfg.get("devs"), sort_keys=True, default=str)
    except Exception:
        return None
    if key in _AIR["cache"]:
        return _AIR["cache"][key]
    devs, err, seen = [], [], set()
    for k, x in enumerate(cfg.get("devs")[:8]):
        if not isinstance(x, dict):
            err.append("Eintrag %d kein Objekt" % (k + 1))
            continue
        kind, usb = x.get("kind"), str(x.get("usb") or "").lower()
        if kind not in DEV_KIND_USB or usb not in DEV_KIND_USB[kind]:
            err.append("Eintrag %d: Art/USB-ID %s/%s unbekannt" % (k + 1, kind, usb))
            continue
        sn = _air_sn(kind, x.get("serial"))
        if not (AIR_SN_RE.match(sn) if kind == "airspy" else SERIAL_RE.match(sn)):
            err.append("Eintrag %d: Seriennummer %r ungueltig" % (k + 1, str(x.get("serial"))[:24]))
            continue
        if (kind, sn) in seen:
            err.append("Seriennummer %s doppelt" % sn)
            continue
        seen.add((kind, sn))
        role = x.get("role") if x.get("role") in DEV_ROLES else ""
        if x.get("role") not in DEV_ROLES + ("", None):
            err.append("%s: Rolle %r unbekannt -> ohne Rolle" % (sn, x.get("role")))
        if kind == "airspy" and role == "hobby":
            err.append("%s: Airspy kann kein Hobby (nur welle-cli) -> ohne Rolle" % sn)
            role = ""
        sfx = str(x.get("ppm_sfx") or "")
        name = " ".join(str(x.get("name") or ("Airspy R2" if kind == "airspy" else "Stick SN %s" % sn)).split())[:24]
        devs.append({"name": name, "kind": kind, "usb": usb, "serial": sn, "role": role, "ppm_sfx": sfx if sfx in ("", "2", "3", "4") else ""})
    by = {}
    for e in devs:
        if e["role"] and e["role"] in by:
            err.append("Rolle %s doppelt (%s) -> %s ohne Rolle" % (e["role"], by[e["role"]]["name"], e["name"]))
            e["role"] = ""
        elif e["role"]:
            by[e["role"]] = e
    r = {"devs": devs, "by_role": by, "err": err} if "11D" in by else None
    if r is None:
        print("sdrAir: Register ungueltig (kein Geraet mit Rolle 11D) - altes Verhalten: %s" % "; ".join(err)[:300], flush=True)
    _AIR["cache"] = {key: r}
    return r


def _air_pl(pl):
    """Register-Eintrag dieses Planers oder None (Register aus)."""
    a = getattr(pl, "__dict__", {}).get("air")
    return a if isinstance(a, dict) and a.get("on") else None


def air_on(pl_or_base):
    if isinstance(pl_or_base, str):
        return pl_or_base in _AIR["bases"]
    return _air_pl(pl_or_base) is not None


def air_name(n):
    return _AIR["names"].get(int(n or 1)) or "Stick %d" % int(n or 1)


_air_orig_stick_info = stick_info
_air_orig_cfg_serial = cfg_serial
_air_orig_cfg_serial2 = cfg_serial2
_air_orig_init = Planner.__init__
_air_orig_resolve = Planner.resolve
_air_orig_cmd_dab = Planner._cmd_dab
_air_orig_lage_apply = Planner.lage_apply
_air_orig_want = Planner.want
_air_orig_status = Planner.status
_air_orig_step = Planner.step
_air_orig_dual_tick = Planner.dual_tick
_air_orig_stick_health = Planner.stick_health
_air_orig_stick2_info = Planner.stick2_info
_air_orig_cal_finish = Planner.cal_finish
_air_orig_loop = Planner.loop
_air_orig_dabgain_step = dabgain_step
_air_orig_t2_alarm = _t2_alarm
_air_orig_t2_takeover = t2_takeover
_air_orig_t2_note = _t2_note
_air_orig_wd_name = _wd_name
_air_orig_wd_view = wd_view
_air_orig_wd_do = _wd_do
_air_orig_wd_block = _wd_block
_air_orig_wd_emit = _wd_emit
_air_orig_stk_poll = stk_poll


def stick_info(ids):
    """wie bisher (sysfs), Airspy-Seriennummer normiert (16 Hex)."""
    out = _air_orig_stick_info(ids)
    for x in out:
        if _air_kind(x.get("usb")) == "airspy" and x.get("serial") is not None:
            x["serial"] = _air_sn("airspy", x["serial"])
    return out


def cfg_serial(cfg):
    if isinstance(cfg, dict) and cfg.get("dev_kind") == "airspy":
        sn = str(cfg.get("serial") or "")
        return sn if AIR_SN_RE.match(sn) else None
    return _air_orig_cfg_serial(cfg)


def cfg_serial2(cfg):
    r = air_reg(cfg) if isinstance(cfg, dict) else None
    if r is not None:
        e = r["by_role"].get("5C")
        return e["serial"] if e else None
    return _air_orig_cfg_serial2(cfg)


def _air_init(self, base, stick=1, main=None):
    _air_orig_init(self, base, stick, main)
    self.air = None
    try:
        r = air_reg(self.cfg)
        if r is None:
            return
        role = {1: "11D", 2: "5C"}.get(stick, "hobby")
        e = r["by_role"].get(role)
        self.air = {"on": True, "role": role, "slot": stick, "name": e["name"] if e else role, "kind": e["kind"] if e else None, "sn": e["serial"] if e else None}
        _AIR["bases"][base] = r
        if e is None:
            return
        _AIR["names"][stick], _AIR["kinds"][stick] = e["name"], e["kind"]
        c, c0 = self.cfg, config(base)
        sfx = e["ppm_sfx"]
        c.update(serial=e["serial"], usb_ids=list(DEV_KIND_USB[e["kind"]]), dev_kind=e["kind"], dev_name=e["name"], ppm_sfx=sfx)
        c["ppm"], c["ppm_cal"], c["cal_hour"] = c0.get("ppm" + sfx) or 0, c0.get("ppm_cal" + sfx), int(c0.get("cal_hour" + sfx) or 4)
        if stick >= 3:
            c["dab_port"], c["dab_tcp_port"] = int(c0.get("dab_port3") or 7983), int(c0.get("dab_tcp_port3") or 1239)
        if e["kind"] == "airspy":
            c["cal_enable"] = c["noise_enable"] = c["meteor_enable"] = False
            c["auto"] = []
    except Exception as ex:
        print("sdrAir init:", ex, flush=True)


def _air_resolve(self):
    if self.cfg.get("dev_kind") != "airspy":
        return _air_orig_resolve(self)
    sn = cfg_serial(self.cfg)
    m = [x for x in stick_info(self.cfg["usb_ids"]) if sn and x.get("serial") == sn]
    if len(m) != 1:
        raise RuntimeError("Stick %s fehlt" % sn if not m else "doppelte Seriennummer %s - nicht gestartet" % sn)
    self.dev_idx, self.dev_sn, self.list_n = 0, sn, 1
    return 0


def _air_gain_state(self):
    st = _dg_state(self)
    if not st.get("air") or (st.get("cur") not in AIR_LADDER):
        st.clear()
        g0 = self.cfg.get("air_gain")
        st.update({"air": 1, "cur": int(g0) if isinstance(g0, int) and 0 <= g0 <= 21 else AIR_LADDER[0], "ok": None, "ok_t": None, "fail_n": 0, "tried": []})
    return st


def _air_cmd_dab(self, ch):
    if self.cfg.get("dev_kind") != "airspy":
        return _air_orig_cmd_dab(self, ch)
    c = self.cfg
    check_tune("dab", ch=ch)
    sn = cfg_serial(c)
    if not sn or self.dev_sn != sn:
        raise RuntimeError("Airspy nicht aufgeloest")
    fe = ["-F", "soapysdr", "-s", "driver=airspy,serial=%s" % sn.lower()] if c.get("air_fe") == "soapy" else ["-F", "airspy"]
    a = [self.tool("welle"), "-c", str(ch), "-C", "1", "-w", str(int(c["dab_port"]))] + fe
    self._dg_used = None
    try:
        st = _air_gain_state(self)
        use = st.get("cur")
        if use != "agc":
            a += ["-g", str(int(use))]
        self._dg_used = {"ch": str(ch), "kind": "dab", "db": "Airspy-Stufe %s" % use, "idx": None if use == "agc" else int(use), "since": None, "air": True}
    except Exception as ex:
        print("sdrAir Gain:", ex, flush=True)
    return [a]


def dabgain_step(st, sync, now, ch):
    if not (isinstance(st, dict) and st.get("air")):
        return _air_orig_dabgain_step(st, sync, now, ch)
    cur = st.get("cur")
    if sync:
        st.update({"ok": cur, "ok_t": int(now), "fail_n": 0, "ok_ch": ch})
        return None
    st["fail_n"] = int(st.get("fail_n") or 0) + 1
    if st["fail_n"] < DABGAIN_FAIL_N:
        return None
    lad = list(AIR_LADDER)
    nx = lad[(lad.index(cur) + 1) % len(lad)] if cur in lad else lad[0]
    st["tried"] = ([y for y in (st.get("tried") or []) if y != cur] + [cur])[-8:]
    st.update({"cur": nx, "fail_n": 0, "t_change": int(now)})
    return ("Airspy-Stufe %s" % cur), ("Airspy-Stufe %s" % nx)


def _air_lage_apply(self):
    _air_orig_lage_apply(self)
    try:
        if self.cfg.get("dev_kind") == "airspy":    # Airspy: nur welle-cli
            c = self.cfg
            c["cal_enable"] = c["noise_enable"] = c["meteor_enable"] = False
            c["auto"] = []
    except Exception as ex:
        print("sdrAir lage_apply:", ex, flush=True)


def _air_want(self, mode, now):
    try:
        if self.cfg.get("dev_kind") == "airspy" and mode.get("mode") != "auto":
            mode = {"mode": "auto"}                  # Airspy fest 11D: Betriebsart/Vorwahl gilt nur fuer Hobby (kein rtl_fm/rtl_433, kein Spyverter)
        if _air_pl(self) and self.air.get("role") == "5C" and mode.get("mode") in ("433", "aprs", "tcp", "preset", "off"):
            mode = {"mode": "auto"}                  # 5C fest hat Vorrang
    except Exception as ex:
        print("sdrAir want:", ex, flush=True)
    return _air_orig_want(self, mode, now)


def _t2_alarm(self):
    a = _air_pl(self)
    if a is not None:
        return a.get("role") == "5C" and self.role == "rot" and t2_on(self)
    return _air_orig_t2_alarm(self)


def t2_takeover(base):
    if base in _AIR["bases"]:
        return {"on": False, "since": None, "src": "", "why": "", "by": "", "fest": True}
    return _air_orig_t2_takeover(base)


def _t2_note(self, now):
    a = _air_pl(self)
    if a is None:
        return _air_orig_t2_note(self, now)
    role = a.get("role")
    mode = DEV_ROLE_TXT.get(role, role)
    row = {"role": self.role, "mode": mode, "sn": cfg_serial(self.cfg), "alarm": role == "5C", "active": str(self.active)[:20], "name": a.get("name"),
           "kind": a.get("kind"), "fest": role in ("11D", "5C"), "present": not self.pin_err}
    dv = None
    if role == "11D":                                # Geraeteliste ausserhalb der Sperre (sysfs)
        try:
            dv = [{x: e.get(x) for x in ("name", "kind", "usb", "serial", "role", "present", "state")} for e in air_devs(self, now)]
        except Exception as ex:
            print("sdrAir Geraete:", ex, flush=True)
    with self.lock:
        t2 = self.sbc.d.get("t2") if isinstance(self.sbc.d.get("t2"), dict) else {}
        self.sbc.d["t2"] = t2
        rl = t2.setdefault("roles", {})
        k = "s%d" % int(self.stickno or 1)
        old = rl.get(k) or {}
        to = t2_takeover(self.base)
        if dv is not None and t2.get("devs") != dv:
            t2["devs"] = dv
            self.sbc.dirty = True
            self.sbc.last_saved = 0
        if {x: old.get(x) for x in row} != row or t2.get("masts") != MASTS_DB or t2.get("takeover") != to:
            row["since"] = int(now) if (old.get("mode") != mode) else old.get("since", int(now))
            rl[k] = row
            t2.update(v=1, on=True, masts=MASTS_DB, dablin=t2_dablin(), journaline=T2_JOURNALINE, takeover=to, air=True, t=int(now))
            self.sbc.dirty = True
            if old.get("mode") != mode or old.get("present") != row["present"]:
                self.sbc.last_saved = 0


def _air_cal_finish(self, now):
    if _air_pl(self) is None:
        return _air_orig_cal_finish(self, now)
    if self.cfg.get("dev_kind") == "airspy":
        self.cal_res = [None, None]
        return None
    c = self.cfg
    ch = str(self.dab_list()[0])
    ppm, note = cal_compute(self.cal_res[0], self.cal_res[1], int(c.get("cal_step_ppm") or 5), DAB_CHANNELS[ch] * 1e6)
    rec = dict(c.get("ppm_cal") if isinstance(c.get("ppm_cal"), dict) else {})
    rec.update({"try_t": int(now), "note": note, "ch": ch, "c0": self.cal_res[0], "c1": self.cal_res[1]})
    upd = {"ppm_cal": rec}
    if ppm is not None:
        rec.update({"ppm": ppm, "t": int(now), "ok": True})
        if c.get("ppm_auto", True):
            upd["ppm"] = int(round(ppm))
    else:
        rec["ok_last"] = False
    sfx = str(c.get("ppm_sfx") or "")       # sdrAir: ppm je Geraet (Register), nicht je Planer-Platz
    save_cfg_keys(self.base, dict((k + sfx, v) for k, v in upd.items()))
    c.update(upd)
    self.cal_res = [None, None]
    self.log("Kalibrierung %s: %s -> %s" % (c.get("dev_name") or "?", note, "%+.2f ppm (angewendet %+d)" % (ppm, ppm_val(c)) if ppm is not None else "alter Wert bleibt"))


def _air_cpu_tick(self, now):
    """welle-cli am Airspy: CPU-Anteil (eine CPU = 100 %) ueber /proc messen, gleitend 5 min; nice einmal je Prozess."""
    cs = self.__dict__.setdefault("_air_cpu", {"pid": None, "pct": None, "avg": None, "nice": None, "hi_since": None, "warn": False, "t": None})
    pr = next((x for x in (self.procs or []) if x.poll() is None), None)
    if pr is None:
        cs.update(pid=None, pct=None)
        self.__dict__.pop("_air_cs", None)
        return cs
    try:
        with open("/proc/%d/stat" % pr.pid, encoding="ascii", errors="replace") as f:
            fl = f.read().rsplit(")", 1)[1].split()
        ticks = int(fl[11]) + int(fl[12])
        hz = float(os.sysconf("SC_CLK_TCK") or 100)
        prev = self.__dict__.get("_air_cs")
        self.__dict__["_air_cs"] = (pr.pid, now, ticks)
        if cs.get("pid") != pr.pid:
            cs.update(pid=pr.pid, pct=None, avg=None, hi_since=None, warn=False, nice=None)
            try:
                nv = int(self.cfg.get("air_nice") or 0)
                if 0 < nv <= 15:
                    os.setpriority(os.PRIO_PROCESS, pr.pid, nv)
                cs["nice"] = os.getpriority(os.PRIO_PROCESS, pr.pid)
            except Exception as ex:
                cs["nice"] = "? (%s)" % str(ex)[:40]
        if prev and prev[0] == pr.pid and now - prev[1] >= 1:
            pct = round(100.0 * (ticks - prev[2]) / hz / (now - prev[1]), 1)
            w = min(1.0, (now - prev[1]) / AIR_CPU_WIN_S)
            cs["pct"] = pct
            cs["avg"] = round(pct if cs.get("avg") is None else cs["avg"] + w * (pct - cs["avg"]), 1)
            cs["t"] = int(now)
            mx = float(self.cfg.get("air_cpu_max") or 85)
            if cs["avg"] > mx:
                cs["hi_since"] = cs.get("hi_since") or int(now)
                if not cs.get("warn") and now - cs["hi_since"] >= 600:
                    cs["warn"] = True
                    self.log("sdrAir: welle-cli am Airspy braucht %.0f %% CPU (Grenze %.0f %%, 10 min) - Empfang laeuft weiter, Pi pruefen" % (cs["avg"], mx))
            else:
                cs.update(hi_since=None, warn=False)
    except Exception as ex:
        cs["err"] = str(ex)[:60]
    return cs


def _air_step(self):
    r = _air_orig_step(self)
    try:
        if self.cfg.get("dev_kind") == "airspy":
            _air_cpu_tick(self, time.time())
    except Exception as ex:
        print("sdrAir CPU:", ex, flush=True)
    return r


def _air_dual_tick(self):
    if _air_pl(self) is None:
        return _air_orig_dual_tick(self)
    if _WD.get("busy"):
        return None
    self.set_role("bc")
    if self.worker is not None:
        self.worker.set_role("rot")
        e5 = _AIR["bases"].get(self.base, {}).get("by_role", {}).get("5C")
        if e5 and not self.worker.__dict__.get("_air_tag"):
            self.worker._air_tag = "[%s · 5C]" % e5["name"]     # Journal: echter Geraetename statt "[Stick 2]"
            self.worker.log = (lambda tg: (lambda *a: self.log(tg, *a)))(self.worker._air_tag)
    if "hobbies" not in self.__dict__:
        self.hobbies = []
        e = _AIR["bases"].get(self.base, {}).get("by_role", {}).get("hobby")
        if e:
            try:
                h = Planner(self.base, stick=3, main=self)
                h.log = (lambda nm: (lambda *a: self.log("[%s]" % nm, *a)))(e["name"])
                h.set_role("rot")
                self.hobbies.append(h)
                threading.Thread(target=h.loop2, daemon=True).start()
                self.log("sdrAir: %s SN %s Hobby gestartet" % (e["name"], e["serial"]))
            except Exception as ex:
                self.log("sdrAir: Hobby-Planer nicht gestartet:", ex)
    for h in self.hobbies:
        h.set_role("rot")
    return None


def air_devs(pl, now=None):
    """Alle Geraete am USB (bekannte USB-IDs) + Register: Rolle/Zustand. Unbekannte = erkannt, ohne Rolle (nie benutzt)."""
    r = _AIR["bases"].get(getattr(pl, "base", None))
    if not r:
        return []
    ids = tuple(x for v in DEV_KIND_USB.values() for x in v)
    seen = {}
    for x in stick_info(ids):
        k = _air_kind(x.get("usb"))
        seen.setdefault((k, _air_sn(k, x.get("serial"))), x)
    m = getattr(pl, "main", None) or pl
    pls = {1: m, 2: m.worker}
    for h in m.__dict__.get("hobbies") or []:
        pls[3] = h
    out = []
    for e in r["devs"]:
        x = seen.pop((e["kind"], e["serial"]), None)
        q = pls.get(DEV_SLOT.get(e["role"])) if e["role"] else None
        st = ("nicht angeschlossen" if x is None else ("aktiv" if q is not None and not q.pin_err else ("wartet" if q is not None else "erkannt, ohne Rolle")))
        out.append({"name": e["name"], "kind": e["kind"], "usb": e["usb"], "serial": e["serial"], "role": e["role"], "role_txt": DEV_ROLE_TXT.get(e["role"], e["role"]),
                    "present": x is not None, "state": st, "port": int(q.cfg["dab_port"]) if q is not None else None, "bus": (x or {}).get("bus"), "active": str(q.active)[:20] if q is not None else None})
    for (k, sn), x in sorted(seen.items(), key=lambda kv: str(kv[0])):
        out.append({"name": ("Airspy" if k == "airspy" else "RTL-Stick") + (" SN %s" % sn if sn else ""), "kind": k, "usb": x.get("usb"), "serial": sn or None, "role": "",
                    "role_txt": DEV_ROLE_TXT[""], "present": True, "state": "erkannt, ohne Rolle", "port": None, "bus": x.get("bus"), "active": None})
    return out


_AIR_SKEYS = ("active", "since", "err", "err_t", "pin_err", "special", "stick_health", "shares", "cal", "next_switch", "stderr", "stick_idx", "sn", "role")


def _air_status(self, mode, force=False, write=True):
    if _air_pl(self) is None:
        return _air_orig_status(self, mode, force, write)
    now = time.time()
    st = _air_orig_status(self, mode, force, False)
    a = self.air
    st["dev"] = {"name": a.get("name"), "kind": a.get("kind"), "role": a.get("role"), "slot": a.get("slot"), "sn": a.get("sn")}
    if self.cfg.get("dev_kind") == "airspy":
        st["dev"]["cpu"] = dict(self.__dict__.get("_air_cpu") or {})
        st["dev"]["fe"] = "soapysdr (driver=airspy)" if self.cfg.get("air_fe") == "soapy" else "welle-cli -F airspy"
    if not write or self.main is not None:
        return st
    w, hb = self.worker, (self.__dict__.get("hobbies") or [None])[0]
    w2, h3 = (w.st_cache if w is not None else None), (hb.st_cache if hb is not None else None)
    st["dual"] = {"on": True, "reg": True, "role1": self.role, "role2": w.role if w is not None else None, "role3": hb.role if hb is not None else None,
                  "sn1": cfg_serial(self.cfg), "sn2": cfg_serial(w.cfg) if w is not None else None, "sn3": cfg_serial(hb.cfg) if hb is not None else None,
                  "name1": _AIR["names"].get(1), "name2": _AIR["names"].get(2), "name3": _AIR["names"].get(3)}
    if w2:
        st["s2"] = {k: w2.get(k) for k in _AIR_SKEYS}
        st["s2"]["dev"] = w2.get("dev")
        st["shares2"], st["stick_health2"] = w2.get("shares"), w2.get("stick_health")
    if h3:
        st["s3"] = {k: h3.get(k) for k in _AIR_SKEYS}
        st["s3"]["dev"] = h3.get("dev")
        st["shares3"], st["stick_health3"] = h3.get("shares"), h3.get("stick_health")
        if not hb.pin_err:
            for k in ("noise_diag", "next_pass", "next_act", "auto", "slices", "next_switch"):
                st[k] = h3.get(k)
            mine = dict((x["k"], x) for x in st.get("sched") or [])
            for x in h3.get("sched") or []:
                if x["k"] in ("noise", "meteor"):
                    mine[x["k"]] = x
            st["sched"] = list(mine.values())
    try:
        st["devs"] = air_devs(self, now)
    except Exception as ex:
        st["devs"] = []
        print("sdrAir Geraete:", ex, flush=True)
    st["air"] = {"on": True, "names": {str(k): v for k, v in _AIR["names"].items()}, "err": list(_AIR["bases"].get(self.base, {}).get("err") or [])[:6]}
    sig = (st["mode"], st["active"], st["err"], len(st["stick"]), st["until"], bool(self.special), (w2 or {}).get("active"), (h3 or {}).get("active"),
           tuple((x.get("serial"), x.get("state")) for x in st["devs"]))
    if force or sig != self.lastsig or now - self.last_status >= 60:
        write_json(p("sdr_status.json", self.base), st)
        self.last_status, self.lastsig = now, sig
    return st


def _air_stick2_info(self):
    r = _air_orig_stick2_info(self)
    try:
        if _air_pl(self) is not None:
            w = self.worker
            e = _AIR["bases"].get(self.base, {}).get("by_role", {}).get("5C")
            r = dict(r if isinstance(r, dict) else {})
            r.pop("t4", None)
            if w is None or e is None:
                r.update(enabled=False, present=False, txt="kein Gerät mit Rolle 5C im Register", t2="fest5c")
            else:
                fb = bool(_t4_st(w).get("fb")) and not w.pin_err
                r.update(model=e["name"], serial=e["serial"], enabled=True, present=not w.pin_err, role=w.role, t2="fest5c",
                         txt=("%s SN %s: %s" % (e["name"], e["serial"], "fest 5C (ASA DE, Warnungen)" + (" · jetzt Rückfall 10C (5C ohne Sync)" if fb else " · Rückfall 10C bei 2 Prüfungen ohne Sync")))
                         if not w.pin_err else "%s SN %s nicht angeschlossen – 5C/10C ohne Empfang, keine Aktion" % (e["name"], e["serial"]))
                if fb:
                    r["t4"] = "fallback"
    except Exception as ex:
        print("sdrAir stick2_info:", ex, flush=True)
    return r


def _air_stick_health(self, now):
    r = _air_orig_stick_health(self, now)
    try:
        a = _air_pl(self)
        if a is not None:
            r = dict(r)
            r["name"] = a.get("name")
            if self.pin_err and str(self.pin_err).startswith("Stick ") or self.active == "nostick":
                r.update(lvl="grau", txt="%s nicht angeschlossen" % a.get("name"), why="%s SN %s nicht am USB – kein Empfang, Watchdog wartet (keine Aktion)" % (a.get("name"), a.get("sn")),
                         hint="anstecken – wird automatisch erkannt (Prüfung alle 15 s, kein Neustart nötig)", absent=True)
    except Exception as ex:
        print("sdrAir stick_health:", ex, flush=True)
    return r


def _wd_name(n, i):
    if _AIR["names"]:
        return "%s · %s" % (air_name(n), (i or {}).get("ch") or "?")
    return _air_orig_wd_name(n, i)


def wd_view(pl, now):
    v = _air_orig_wd_view(pl, now)
    a = _air_pl(pl)
    if a is None:
        return v
    try:
        v = dict(v)
        n, nm = int(v.get("n") or a.get("slot") or 1), a.get("name") or "?"
        v["name"], v["kind"], v["role"] = nm, a.get("kind"), a.get("role")
        for k in ("txt", "short", "hl", "hint", "block"):
            if isinstance(v.get(k), str):
                s = v[k].replace("Stick %d" % n, nm).replace("Übernahme aktiv", "5C fest").replace("Übernahme: ", "5C fest: ")
                if a.get("kind") == "airspy":
                    s = s.replace("welle-cli + rtl_tcp", "welle-cli")
                v[k] = s
        if v.get("absent"):
            t = "%s nicht angeschlossen (SN %s)" % (nm, a.get("sn") or "?")
            v.update(lvl="grau", hl="%s nicht angeschlossen" % nm, short=t + " – keine Aktion", txt=t + " · Watchdog wartet, keine Aktion" +
                     (" · letzter Empfang %s" % _wd_hm(v.get("last_ok"), now) if v.get("last_ok") else ""),
                     hint="anstecken – wird automatisch erkannt (alle 15 s), danach prüft der Watchdog neu")
    except Exception as ex:
        print("sdrAir Anzeige:", ex, flush=True)
    return v


def _wd_block(pl, now, sn, act=None):
    a = _air_pl(pl)
    if a is not None and a.get("role") == "hobby" and act in (None, "reboot"):
        return "Hobby-Gerät – kein Pi-Neustart (nur Neustart/USB-Neuverbindung)"
    return _air_orig_wd_block(pl, now, sn, act)


def _wd_emit(base, msgs, now):
    try:
        if _AIR["names"] and msgs:
            an = [nm for k, nm in _AIR["names"].items() if _AIR["kinds"].get(k) == "airspy"]
            msgs = [(m[0], m[1].replace("welle-cli + rtl_tcp", "welle-cli") if any(str(m[1]).startswith(x) for x in an) else m[1]) + tuple(m[2:]) for m in msgs]
    except Exception:
        pass
    return _air_orig_wd_emit(base, msgs, now)


def _air_usb(pl, sn, ctx, now):
    """Stufe 3 am Airspy: USB-Neuverbindung genau dieses Geraets 1d50:60a1 mit dieser Seriennummer (Hilfsprogramm usb-reset-air)."""
    n, i = ctx
    nm = _wd_name(n, i)
    msgs = []
    if not AIR_SN_RE.match(str(sn or "")):
        msgs.append(("wd_usb", "%s USB-Neuverbindung nicht möglich: Seriennummer %s ist keine 16-stellige Hex-Zahl" % (nm, sn), i.get("ch"), "rot"))
    else:
        pl.kill()
        pl.active, pl.retry_at, pl.fails = "idle", 0, 0
        rc, txt = _wd_helper(["usb-reset-air", sn], 90)
        seen = False
        for _ in range(20):
            if any(str(x.get("serial")) == sn for x in stick_info(pl.cfg["usb_ids"])):
                seen = True
                break
            time.sleep(1)
        ok = rc == 0 and seen
        msgs.append(("wd_usb", "%s USB-Neuverbindung %d: %s" % (nm, int(i.get("usb_n") or 0), ("Airspy wieder da (SN %s) – prüfe Empfang" % sn) if ok else
                     ("fehlgeschlagen (rc %d: %s)%s" % (rc, txt, "" if seen else " · Airspy nicht wieder gemeldet"))), i.get("ch"), "ok" if ok else "rot"))
        with _WD_LOCK:
            ii = (_wd_state(pl.base, now)["sticks"].get(sn) or {}).get("inc")
            if ii:
                ii["usb_last"] = ("ok" if ok else "rc %d: %s" % (rc, txt))[:120]
                _WD["dirty"] = True
        pl.log("sdrAir: %s USB-Neuverbindung rc %d (%s), Airspy %s" % (nm, rc, txt, "da" if seen else "FEHLT"))
    with _WD_LOCK:
        _wd_save(pl.base, time.time(), force=True)
    _wd_emit(pl.base, msgs, time.time())


def _wd_do(pl, act, sn, ctx, now):
    if act == "usb" and pl.cfg.get("dev_kind") == "airspy":
        return _air_usb(pl, sn, ctx, now)
    if act == "restart" and pl.cfg.get("dev_kind") == "airspy":
        r = _air_orig_wd_do(pl, act, sn, ctx, now)
        pl.log("sdrAir: Neustart nur welle-cli (Airspy, kein rtl_tcp)")
        return r
    return _air_orig_wd_do(pl, act, sn, ctx, now)


def _air_wd_role_close(pl, now):
    """Einmal je Geraet nach Start im Register: offener Vorfall auf einem Kanal, den die Rolle nicht mehr empfaengt (z. B. alte Uebernahme 5C auf Hobby-Stick,
    alter 11D-Vorfall auf dem jetzt 5C-Stick) -> sauber schliessen (Grund Rollenwechsel), keine Aktion."""
    a = _air_pl(pl)
    sn = cfg_serial(pl.cfg)
    done = _AIR.setdefault("closed", set())
    if a is None or not sn or sn in done:
        return
    done.add(sn)
    want = {"11D": ("11D",), "5C": (T2_CH_ALARM, T4_CH_FB), "hobby": ()}.get(a.get("role"), ())
    msgs = []
    with _WD_LOCK:
        d = _wd_state(pl.base, now)
        s = d["sticks"].get(sn)
        i = s.get("inc") if s else None
        if not i:
            return
        ch = str(i.get("ch") or "").upper()
        if (i.get("src") == "dab" and ch not in want) or (a.get("role") != "hobby" and i.get("src") == "rds"):
            msgs.append(("wd_ok", "%s Vorfall beendet: Rolle jetzt %s (sdrAir) – %s ohne Sync %s–%s, %s" % (
                "%s · %s" % (a.get("name") or _wd_name(s["n"], i), ch or "?"), DEV_ROLE_TXT.get(a.get("role")), ch or "?", _wd_hm(i["since"], now), _wd_hm(now, now), _wd_dur(now - i["since"])), i.get("ch"), "ok"))
            s["last_inc"] = {"since": i["since"], "end": int(now), "act": i.get("act"), "usb_n": i.get("usb_n"), "reboot_n": i.get("reboot_n"), "why": "Rollenwechsel sdrAir"}
            s["inc"], s["fail_n"] = None, 0
            _WD["dirty"] = True
            _wd_save(pl.base, now, force=True)
    _wd_emit(pl.base, msgs, now)


_air_orig_wd_tick = wd_tick


def wd_tick(pl, now):
    try:
        if _air_pl(pl) is not None:
            _air_wd_role_close(pl, now)
    except Exception as ex:
        print("sdrAir Vorfall/Rolle:", ex, flush=True)
    return _air_orig_wd_tick(pl, now)


def stk_poll(pl):
    """Register an: Antennen-/Stick-Test und Rollentausch hier aus (Rollen stehen in sdr_config.json devs; Vergleichstest kommt mit eigenem Patch)."""
    if _air_pl(pl) is None:
        return _air_orig_stk_poll(pl)
    why = "im Geräte-Register-Betrieb (sdrAir) aus – Rollen in sdr_config.json devs; Vergleichstest folgt mit eigenem Patch"
    for rq, res in ((STK_REQ_SWAP, "sdr_swap_result.json"), (STK_REQ_RELEARN, None), (STK_REQ, STK_RUN)):
        if stk_take(pl.base, rq):
            pl.log("sdrAir: Anforderung %s abgelehnt: %s" % (rq, why))
            if res:
                stk_write_atomic(p(res, pl.base), {"t": int(time.time()), "ok": False, "running": False, "why": why, "err": why})


def _air_loop(self):
    try:
        r = air_reg(self.cfg) if self.main is None else None
        if r is not None:
            self.log("sdrAir: Geraete-Register an - %s%s" % ("; ".join("%s %s SN %s -> %s" % (e["name"], e["usb"], e["serial"], DEV_ROLE_TXT.get(e["role"], e["role"])) for e in r["devs"]),
                                                             (" | Hinweise: " + "; ".join(r["err"])) if r["err"] else ""))
    except Exception as ex:
        print("sdrAir loop:", ex, flush=True)
    return _air_orig_loop(self)


Planner.__init__ = _air_init
Planner.resolve = _air_resolve
Planner._cmd_dab = _air_cmd_dab
Planner.lage_apply = _air_lage_apply
Planner.want = _air_want
Planner.status = _air_status
Planner.step = _air_step
Planner.dual_tick = _air_dual_tick
Planner.stick_health = _air_stick_health
Planner.stick2_info = _air_stick2_info
Planner.cal_finish = _air_cal_finish
Planner.loop = _air_loop


def selftest_sdrair():
    import tempfile
    keep = {k: os.environ.get(k) for k in ("SDR_SYSFS_USB", "SDR_WD_HELPER")}
    gl = {k: globals()[k] for k in ("_wd_helper", "_air_orig_want")}
    snap = (dict(_AIR["names"]), dict(_AIR["kinds"]), dict(_AIR["bases"]))
    os.environ["SDR_WD_HELPER"] = "/nonexistent/sdrair-selftest"     # echtes Hilfsprogramm nie
    calls = []
    try:
        _WD["live"] = True
        r = _selftest_sdrair(tempfile.mkdtemp(prefix="sdrair-"), calls)
    finally:
        globals().update(gl)
        for k, v in keep.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        _AIR["names"], _AIR["kinds"], _AIR["bases"] = snap[0], snap[1], snap[2]
        _AIR["cache"], _AIR["closed"] = {}, set()
        _T2_TO.clear()
        _WD.update(d=None, base=None, dirty=False, saved=0.0, busy=None, cfg=None, cfg_key=None, started=set(), helper=None, boot_msgs=[], live=False, start=time.time())
    print("selftest sdrAir ok (Register USB-ID + Seriennummer: Airspy 11D welle-cli -F airspy Port 7979 Gain-Leiter 16/12/19/9/21/AGC, Stick 1 fest 5C + 10C, Stick 2 Hobby Port 7983, "
          "unbekannter 3. Stick erkannt ohne Rolle nie benutzt; keine Uebernahme (Datei ignoriert); fehlt -> grau ohne Aktion, wieder da -> automatisch erkannt + Vorfall zu; "
          "alte Vorfaelle bei Rollenwechsel geschlossen; Airspy USB nur usb-reset-air, Neustart nur welle-cli; Hobby kein Pi-Neustart; %d Fake-Aufrufe)" % r, flush=True)


def _selftest_sdrair(tmp, calls):
    AS = "44A42E4F2A5B1C83"
    root = os.path.join(tmp, "sys")
    os.environ["SDR_SYSFS_USB"] = root

    def mk(n, vid, pid, sn, prod):
        d = os.path.join(root, n)
        os.makedirs(d)
        for k, v in (("idVendor", vid), ("idProduct", pid), ("serial", sn), ("product", prod)):
            open(os.path.join(d, k), "w").write(v + "\n")
    mk("1-1.1", "0bda", "2838", "19348831", "RTL2838UHIDIR")
    mk("1-1.2", "0bda", "2838", "72055505", "RTL2838UHIDIR")
    mk("1-1.3", "1d50", "60a1", "AIRSPY SN:%s" % AS.lower(), "AIRSPY")
    mk("1-1.4", "0bda", "2838", "00000003", "RTL2838UHIDIR")                       # 3. Stick, nicht im Register
    mk("1-2", "174c", "55aa", "19348831", "SSD")                                     # SSD-Bruecke: nie
    devs = [{"name": "Airspy R2", "kind": "airspy", "usb": "1d50:60a1", "serial": "0x" + AS.lower(), "role": "11D"},
            {"name": "Stick 1", "kind": "rtl", "usb": "0bda:2838", "serial": "19348831", "role": "5C", "ppm_sfx": ""},
            {"name": "Stick 2", "kind": "rtl", "usb": "0bda:2838", "serial": "72055505", "role": "hobby", "ppm_sfx": "2"}]
    # Register pruefen
    assert air_reg({"devs_on": False, "devs": devs}) is None and air_reg({"devs_on": True, "devs": devs[1:]}) is None
    r = air_reg({"devs_on": True, "devs": devs})
    assert r and r["by_role"]["11D"]["serial"] == AS and r["by_role"]["5C"]["serial"] == "19348831" and not r["err"], r
    bad = air_reg({"devs_on": True, "devs": devs + [{"kind": "rtl", "usb": "0bda:2838", "serial": "12;rm", "role": "hobby"}, {"kind": "airspy", "usb": "1d50:60a1", "serial": "1" * 16, "role": "hobby"},
                                                    {"kind": "rtl", "usb": "0bda:2838", "serial": "55555555", "role": "5C"}, {"kind": "rtl", "usb": "dead:beef", "serial": "1"}]})
    assert bad and len(bad["err"]) == 4 and bad["by_role"]["5C"]["serial"] == "19348831" and [e["role"] for e in bad["devs"]][3:] == ["", ""], bad
    assert _air_sn("airspy", "AIRSPY SN:44a42e4f2a5b1c83") == AS and _air_sn("rtl", "007") == "007"
    write_json(os.path.join(tmp, "sdr_config.json"), {"devs_on": True, "devs": devs, "ppm": 3, "ppm2": -2, "air_nice": 0})
    write_json(os.path.join(tmp, "sdr_takeover.json"), {"on": True, "since": 1790000000, "src": "manual", "why": "Knopf", "by": "dashboard"})
    m = Planner(tmp)
    w = Planner(tmp, stick=2, main=m)
    h = Planner(tmp, stick=3, main=m)
    m.worker, m.hobbies, m.t2 = w, [h], True
    for x in (m, w, h):
        x.log = lambda *a: None
        x.tools = {"welle": "/usr/bin/welle-cli", "redsea": "/usr/bin/redsea"}
    assert m.cfg["dev_kind"] == "airspy" and cfg_serial(m.cfg) == AS and m.cfg["usb_ids"] == ["1d50:60a1"] and int(m.cfg["dab_port"]) == 7979 and not m.cfg["cal_enable"]
    assert cfg_serial(w.cfg) == "19348831" and w.cfg["ppm"] == 3 and int(w.cfg["dab_port"]) == 7981 and cfg_serial2(m.cfg) == "19348831"
    assert cfg_serial(h.cfg) == "72055505" and h.cfg["ppm"] == -2 and int(h.cfg["dab_port"]) == 7983 and int(h.cfg["dab_tcp_port"]) == 1239
    assert _wd_name(1, {"ch": "11D"}) == "Airspy R2 · 11D" and _wd_name(2, {"ch": "5C"}) == "Stick 1 · 5C" and _wd_name(3, {"ch": "BR24"}) == "Stick 2 · BR24"
    # Rollen: keine Uebernahme mehr, Stick 1 fest 5C
    m.dual_tick()
    assert (m.role, w.role, h.role) == ("bc", "rot", "rot") and len(m.hobbies) == 1
    assert _t2_alarm(w) and not _t2_alarm(h) and not _t2_alarm(m) and t2_takeover(tmp)["on"] is False and _t4_active(w) and not _t4_active(h)
    # Betriebsart/Vorwahl: Airspy bleibt fest 11D (immer Automatik), Stick 1 fest 5C, Hobby folgt der Betriebsart
    ow = globals()["_air_orig_want"]
    globals()["_air_orig_want"] = lambda self, mode, now: mode
    for md in ({"mode": "433"}, {"mode": "off"}, {"mode": "preset", "preset": "dab_8c"}, {"mode": "preset", "preset": "ukw_br24"}):
        assert _air_want(m, md, 0) == {"mode": "auto"} and _air_want(w, md, 0) == {"mode": "auto"} and _air_want(h, md, 0) == md, md
    globals()["_air_orig_want"] = ow
    # Airspy: welle-cli -F airspy, Port 7979, Gain-Leiter
    m.resolve()
    assert m.dev_sn == AS and m.dev_idx == 0
    a = m._cmd_dab("11D")
    assert a == [["/usr/bin/welle-cli", "-c", "11D", "-C", "1", "-w", "7979", "-F", "airspy", "-g", "16"]] and m._dg_used["air"], a
    m.cfg["air_fe"] = "soapy"
    assert m._cmd_dab("11D")[0][7:11] == ["-F", "soapysdr", "-s", "driver=airspy,serial=%s" % AS.lower()]
    m.cfg["air_fe"] = "airspy"
    st = _air_gain_state(m)
    assert dabgain_step(st, False, 1000, "11D") is None and dabgain_step(st, False, 1001, "11D") == ("Airspy-Stufe 16", "Airspy-Stufe 12") and st["cur"] == 12
    assert dabgain_step(st, True, 1002, "11D") is None and st["ok"] == 12
    rs = {"cur": 40.2, "fail_n": 1}
    assert dabgain_step(rs, False, 1, "11D") == (40.2, 32.8)                           # RTL-Leiter unveraendert
    try:
        m._dev(["rtl_fm"])
        raise AssertionError("rtl-Werkzeug am Airspy")
    except RuntimeError:
        pass
    # Geraeteliste: 3. Stick erkannt, ohne Rolle, nie benutzt
    dv = air_devs(m)
    assert [(x["name"], x["state"]) for x in dv] == [("Airspy R2", "aktiv"), ("Stick 1", "aktiv"), ("Stick 2", "aktiv"), ("RTL-Stick SN 00000003", "erkannt, ohne Rolle")], dv
    assert not [x for x in dv if "174c" in str(x.get("usb"))] and dv[0]["port"] == 7979 and dv[2]["port"] == 7983 and dv[3]["port"] is None
    # Vorfaelle aus der alten Rollenverteilung: Stick 2 alte Uebernahme 5C, Stick 1 alter 11D -> sauber zu, keine Aktion
    t0 = time.time()
    _WD["start"] = t0 - 3600
    wd_check(h, "dab", False, t0 - 7200, "5C", "kein Sync")
    wd_check(h, "dab", False, t0 - 7100, "5C", "kein Sync")
    wd_check(w, "dab", False, t0 - 7000, "11D", "kein Sync")
    wd_check(w, "dab", False, t0 - 6900, "11D", "kein Sync")
    ev = lambda: (load_json(os.path.join(tmp, "sdr_techlog.json"), {}) or {}).get("ev") or []
    globals()["_wd_helper"] = lambda args, timeout: (calls.append(list(args)), (0, "ok"))[1]
    _AIR["closed"] = set()
    wd_tick(h, t0)
    wd_tick(w, t0)
    d = _wd_state(tmp, t0)
    assert d["sticks"]["72055505"]["inc"] is None and d["sticks"]["19348831"]["inc"] is None and not calls, (d["sticks"], calls)
    assert len([x for x in ev() if x["k"] == "wd_ok" and "Rolle jetzt" in x["text"]]) == 2, ev()
    assert any(x["text"].startswith("Stick 2 · 5C Vorfall beendet: Rolle jetzt Hobby") for x in ev()), [x["text"] for x in ev()]
    # Stick 2 fehlt -> grau, keine Aktion; wieder da -> automatisch erkannt (step, kein Neustart), Vorfall zu bei Empfang
    h.want = lambda mode, now: "idle"
    h.step()
    assert h.pin_err is None and h.active == "idle"
    for k in range(1, 4):
        wd_check(h, "rds", False, t0 + 60 * k, "BR24", "0 RDS-Gruppen")
    os.rename(os.path.join(root, "1-1.2", "idVendor"), os.path.join(root, "1-1.2", "x"))
    h.step()
    assert h.pin_err == "Stick 72055505 fehlt" and h.active == "nostick"
    for k in range(4, 140, 5):
        wd_tick(h, t0 + 60 * k)
    hh = h.stick_health(t0 + 60 * 140)
    v = wd_view(h, t0 + 60 * 140)
    assert hh["lvl"] == "grau" and hh["txt"] == "Stick 2 nicht angeschlossen" and hh.get("absent"), hh
    assert v["lvl"] == "grau" and v["short"] == "Stick 2 nicht angeschlossen (SN 72055505) – keine Aktion" and v["name"] == "Stick 2", v
    assert not calls and [x["name"] for x in air_devs(m) if x["state"] == "nicht angeschlossen"] == ["Stick 2"]
    os.rename(os.path.join(root, "1-1.2", "x"), os.path.join(root, "1-1.2", "idVendor"))
    h.step()
    assert h.pin_err is None and h.active == "idle" and h.stick_health(t0 + 60 * 141).get("absent") is None
    wd_tick(h, t0 + 60 * 141)
    i = _wd_state(tmp, t0)["sticks"]["72055505"]["inc"]
    assert i and not i.get("abs") and i["t0"] >= int(t0) and not i.get("restart_n") and not i.get("usb_n"), i
    wd_check(h, "rds", True, t0 + 60 * 142, "BR24")
    wd_tick(h, t0 + 60 * 142)
    assert _wd_state(tmp, t0)["sticks"]["72055505"]["inc"] is None and not calls
    assert [x["text"] for x in ev() if "wieder angeschlossen" in x["text"]] and wd_view(h, t0 + 60 * 143)["lvl"] != "grau"
    # Airspy fehlt -> grau; Neustart nur welle-cli, USB nur usb-reset-air dieses Geraets
    os.rename(os.path.join(root, "1-1.3", "idVendor"), os.path.join(root, "1-1.3", "x"))
    m.want = lambda mode, now: "idle"
    m.step()
    assert m.pin_err == "Stick %s fehlt" % AS and m.stick_health(t0)["txt"] == "Airspy R2 nicht angeschlossen" and m.stick_health(t0)["lvl"] == "grau"
    os.rename(os.path.join(root, "1-1.3", "x"), os.path.join(root, "1-1.3", "idVendor"))
    m.step()
    assert m.pin_err is None and m.active == "idle"
    ki = []
    m.kill = lambda: ki.append(1)
    m.resolve()
    inc = {"ch": "11D", "usb_n": 1}
    _wd_do(m, "usb", AS, (1, inc), t0)
    assert calls == [["usb-reset-air", AS]] and ki, calls
    _wd_do(m, "usb", "12345678", (1, inc), t0)
    assert len(calls) == 1 and "keine 16-stellige" in ev()[-1]["text"]
    _wd_do(m, "restart", AS, (1, inc), t0)
    assert len(calls) == 1 and len(ki) == 2
    assert _wd_block(h, t0, "72055505", "reboot").startswith("Hobby") and not str(_wd_block(h, t0, "72055505", "restart") or "").startswith("Hobby")
    assert "Hobby" not in str(_wd_block(w, t0, "19348831", "reboot") or "")
    # CPU-Messung (eigener Prozess als Stellvertreter, nice hier aus)
    class P:
        pid = os.getpid()
        poll = staticmethod(lambda: None)
    m.procs = [P()]
    _air_cpu_tick(m, t0)
    c2 = _air_cpu_tick(m, t0 + 2)
    assert c2["pid"] == os.getpid() and isinstance(c2["pct"], float) and c2["avg"] is not None, c2
    m.procs = []
    assert _air_cpu_tick(m, t0 + 3)["pid"] is None
    # Antennentest/Rollentausch: im Register-Betrieb abgelehnt, nichts gestartet
    stk_request(tmp, STK_REQ, "selftest")
    stk_poll(m)
    rr = load_json(os.path.join(tmp, STK_RUN), {})
    assert rr.get("ok") is False and "sdrAir" in rr.get("why", "") and not stk_take(tmp, STK_REQ), rr
    # Rollen-Zeilen fuer Dashboard
    _t2_note(m, t0)
    _t2_note(w, t0)
    _t2_note(h, t0)
    ro = m.sbc.d["t2"]["roles"]
    assert ro["s1"]["name"] == "Airspy R2" and ro["s2"]["alarm"] is True and ro["s2"]["fest"] and ro["s3"]["mode"].startswith("Hobby") and m.sbc.d["t2"]["takeover"]["on"] is False, ro
    s2i = m.stick2_info()
    assert s2i["t2"] == "fest5c" and s2i["txt"].startswith("Stick 1 SN 19348831: fest 5C"), s2i
    return len(calls)
AIB_EOF
EXPECT_ASM="d704b3d16ece86b40707a466b0fbf5afec56dcccad4fa8299b7d018c677f01b6"
cat > "$W/air_sm_block.py" << 'AIS_EOF'
# ===== sdrAir: Geraete-Register (sdr_config.json devs_on/devs) - keine Stick-2-Uebernahme mehr (Stick 1 fest 5C): alte Uebernahme endet einmal sauber, Knopf/Automatik/Vor-Alarm schalten nichts mehr ein; ASA-Ueberwachung dauerhaft; Anzeige mit Geraetenamen; nur lesen/rechnen =====
_SMAIR = {"fn": None, "mt": None, "on": False, "names": {}}


def sm_air_on(base):
    """Register an? (sdr_config.json devs_on true und ein Geraet mit Rolle 11D) - nach mtime zwischengespeichert."""
    fn = os.path.join(base, "sdr_config.json")
    try:
        mt = os.path.getmtime(fn)
    except Exception:
        return False
    if _SMAIR["fn"] == fn and _SMAIR["mt"] == mt:
        return _SMAIR["on"]
    d = _load(fn, {}) or {}
    on, names = False, {}
    if isinstance(d, dict) and d.get("devs_on") is True and isinstance(d.get("devs"), list):
        for x in d["devs"]:
            if isinstance(x, dict) and x.get("role") in ("11D", "5C", "hobby"):
                names[x["role"]] = " ".join(str(x.get("name") or "?").split())[:24]
        on = "11D" in names
    _SMAIR.update(fn=fn, mt=mt, on=on, names=names)
    return on


_air_orig_takeover_load = takeover_load
_air_orig_takeover_set = takeover_set
_air_orig_takeover_auto = takeover_auto
_air_orig_t4_sdr = t4_sdr

AIR_TO_END_WHY = "sdrAir: Stick 1 fest auf 5C (Warnungen) – Übernahme nicht mehr nötig"


def takeover_load(base):
    d = _air_orig_takeover_load(base)
    try:
        if d.get("on") and sm_air_on(base):     # alte Uebernahme (z. B. Knopf 18.10.) einmal sauber beenden
            now = int(time.time())
            d.update(on=False, off_t=now, off_by="sdrAir")
            d["hist"].append({"t": now, "on": False, "src": "sdrAir", "why": AIR_TO_END_WHY[:120], "by": "sdrAir"})
            _takeover_save(base, d, now)
            print("sdr_manager sdrAir: alte Stick-2-Uebernahme beendet (%s)" % AIR_TO_END_WHY, flush=True)
    except Exception as e:
        print("sdr_manager sdrAir Uebernahme-Ende:", e, flush=True)
    return d


def takeover_set(base, on, src="manual", why="", by="dashboard", now=None):
    if on and sm_air_on(base):
        d = takeover_load(base)
        d["air"] = "keine Übernahme im Geräte-Register-Betrieb – Stick 1 hört 5C fest"
        return d
    return _air_orig_takeover_set(base, on, src, why, by, now)


def takeover_auto(base, alarms, now=None):
    """Register an: neue Alarme nur merken (seen), nie einschalten - 5C laeuft ohnehin fest."""
    if not sm_air_on(base):
        return _air_orig_takeover_auto(base, alarms, now)
    now = int(now or time.time())
    d = takeover_load(base)
    new = [a for a in alarms or [] if isinstance(a, dict) and a.get("takeover") and a.get("real") and not a.get("test") and a.get("key")
           and ("%s:%s" % (a.get("src"), a["key"])) not in d["seen"]]
    if not new:
        return d, False
    for a in new:
        d["seen"]["%s:%s" % (a.get("src"), a["key"])] = now
    return _takeover_save(base, d, now), False


def t4_sdr(base, now=None):
    r = _air_orig_t4_sdr(base, now)
    try:
        if sm_air_on(base):
            bs = _t4_dab(base)
            roles = ((bs.get("t2") or {}).get("roles") or {}) if isinstance(bs.get("t2"), dict) else {}
            for k in ("s1", "s2"):
                ro = roles.get(k) or {}
                r[k]["name"] = ro.get("name") or _SMAIR["names"].get({"s1": "11D", "s2": "5C"}[k])
                r[k]["fest"] = True
                if ro.get("present") is False:
                    r[k]["state"] = "%s nicht angeschlossen" % (r[k]["name"] or k)
                    r[k]["absent"] = True
            r["s2"]["takeover"] = False
            for k in ("src", "since", "why"):
                r["s2"].pop(k, None)
            r3 = roles.get("s3") or {}
            r["s3"] = {"name": r3.get("name") or _SMAIR["names"].get("hobby"), "sn": r3.get("sn"), "mode": r3.get("mode"), "absent": r3.get("present") is False,
                       "state": ("nicht angeschlossen" if r3.get("present") is False else (r3.get("mode") or "–")) if r3 else ("wartet auf prepper-sdr" if _SMAIR["names"].get("hobby") else "kein Hobby-Gerät im Register")}
            r["air"] = True
    except Exception as e:
        print("sdr_manager sdrAir t4_sdr:", e, flush=True)
    return r


def selftest_sdrair():
    import tempfile
    d = tempfile.mkdtemp(prefix="sm-air-")
    now = int(time.time())
    _write_json(os.path.join(d, "sdr_takeover.json"), {"on": True, "since": now - 86400 * 5, "src": "manual", "why": "Knopf auf der Funk-Seite", "by": "dashboard"})
    assert takeover_load(d)["on"] is True                                       # ohne Register: alles wie bisher
    _write_json(os.path.join(d, "sdr_config.json"), {"devs_on": True, "devs": [{"name": "Airspy R2", "kind": "airspy", "role": "11D"}, {"name": "Stick 1", "role": "5C"},
                                                                                 {"name": "Stick 2", "role": "hobby"}]})
    t = takeover_load(d)
    assert t["on"] is False and t["off_by"] == "sdrAir" and t["hist"][-1]["src"] == "sdrAir" and not _load(os.path.join(d, "sdr_takeover.json"), {})["on"], t
    n = len(takeover_load(d)["hist"])
    assert n == len(takeover_load(d)["hist"])                                    # nur einmal beendet
    assert takeover_set(d, True, "manual", "Knopf")["on"] is False and not takeover_load(d)["on"]
    al = [{"src": "NINA", "key": "k1", "takeover": True, "real": True, "test": False, "text": "Unwetter"}]
    st, ch = takeover_auto(d, al, now)
    assert ch is False and not st["on"] and "NINA:k1" in takeover_load(d)["seen"]
    assert takeover_set(d, False, now=now)["on"] is False
    _write_json(os.path.join(d, "broadcast_state.json"), {"t2": {"roles": {"s1": {"sn": "44A42E4F2A5B1C83", "name": "Airspy R2", "present": True, "mode": "fest 11D"},
                                                                           "s2": {"sn": "19348831", "name": "Stick 1", "alarm": True, "fest": True, "present": True, "mode": "fest 5C"},
                                                                           "s3": {"sn": "72055505", "name": "Stick 2", "present": False, "mode": "Hobby"}}}})
    r = t4_sdr(d, now)
    assert r["air"] and r["s1"]["name"] == "Airspy R2" and r["s2"]["name"] == "Stick 1" and r["s2"]["state"].startswith("BUNDES-EBENE") and r["s2"]["takeover"] is False, r
    assert r["s3"]["absent"] and r["s3"]["state"] == "nicht angeschlossen", r["s3"]
    a = asa_monitor(d, now=now) if "asa_monitor" in globals() else None
    if a is not None:
        assert a["monitoring"] is True, a
    w = {"t": now, "stick_health": {"wd": {"sn": "44A42E4F2A5B1C83", "n": 1, "name": "Airspy R2", "lvl": "ok", "txt": "Airspy R2 · 11D Empfang ok"}},
         "stick_health2": {"wd": {"sn": "19348831", "n": 2, "name": "Stick 1", "lvl": "ok", "txt": "Stick 1 · 5C Empfang ok"}},
         "stick_health3": {"wd": {"sn": "72055505", "n": 3, "name": "Stick 2", "lvl": "grau", "absent": True, "txt": "Stick 2 nicht angeschlossen (SN 72055505) · Watchdog wartet, keine Aktion",
                                  "short": "Stick 2 nicht angeschlossen (SN 72055505) – keine Aktion"}}}
    s = wd_status(w, now)
    assert len(s["sticks"]) == 3 and s["lvl"] == "ok" and s["short"] == "Airspy R2 ok · Stick 1 ok · Stick 2 nicht angeschlossen (SN 72055505) – keine Aktion", s
    return "sdr_manager selftest sdrAir ok (alte Uebernahme endet einmal sauber, Knopf/Automatik schalten nichts ein, Alarme gemerkt; T4-Kachel mit Geraetenamen, Hobby fehlt grau; Watchdog 3 Geraete)"
AIS_EOF
EXPECT_ADA="f2c7903feda53efb7da1ae4675d4e098a47d0fa190d1719abf55ff1f03759edc"
cat > "$W/air_dash_block.py" << 'AID_EOF'
# ===== sdrAir: Anzeige Geraete-Register - /funk Funk-Lage mit Geraetenamen (Airspy 11D, Stick 1 5C fest + 10C, Stick 2 Hobby, erkannte Geraete ohne Rolle), Namen vor TII-Kennungen, kein Uebernahme-Knopf; /pi Empfaenger-Zeilen je Geraet; nur Anzeige =====
_air_orig_sdrui = _sdrui_data
AIR_TAG = {"11D": "AIR", "5C": "S1", "hobby": "S2"}


def _air_h(h, name, absent):
    h = h if isinstance(h, dict) else {}
    if absent:
        return {"lvl": "grau", "txt": "%s nicht angeschlossen" % name, "hint": "anstecken – wird automatisch erkannt (alle 15 s)", "why": h.get("why")}
    t = str(h.get("txt") or "?")
    if t.startswith(name):
        pass
    elif t.startswith("Stick "):
        t = name + " " + t[len("Stick "):]
    else:
        t = "%s: %s" % (name, t)
    return {"lvl": h.get("lvl") or "grau", "txt": t, "hint": h.get("hint"), "why": h.get("why")}


def _air_sdrui(st, d):
    du = st.get("dual") or {}
    s2, s3 = st.get("s2") or {}, st.get("s3") or {}
    n1, n2, n3 = du.get("name1") or "11D", du.get("name2") or "5C", du.get("name3")
    a1, a2, a3 = bool(st.get("pin_err")), bool(s2.get("pin_err")) or not s2, bool(s3.get("pin_err")) or not s3
    h1, h2 = _air_h(st.get("stick_health"), n1, a1), _air_h(st.get("stick_health2"), n2, a2)
    hs = [h1, h2]
    if n3:
        hs.append(_air_h(st.get("stick_health3"), n3, a3))
    devs = [x for x in st.get("devs") or [] if isinstance(x, dict)]
    free = [x for x in devs if not x.get("role") and x.get("present")]
    miss = [x.get("name") for x in devs if x.get("role") and not x.get("present")]
    mode = "Geräte: %s" % ", ".join("%s %s%s" % (x.get("name"), {"11D": "11D fest", "5C": "5C fest", "hobby": "Hobby"}.get(x.get("role"), ""), "" if x.get("present") else " (nicht angeschlossen)")
                                   for x in devs if x.get("role"))
    if free:
        mode += " · erkannt, ohne Rolle: %s" % ", ".join(str(x.get("name")) for x in free)
    sn1 = next((x.get("serial") for x in devs if x.get("role") == "11D"), du.get("sn1"))
    d["dual"] = {"on": True, "reg": True, "mode": mode, "sna": sn1, "sn1": du.get("sn2"), "sn2": du.get("sn3"), "role1": du.get("role1"), "role2": du.get("role2"),
                 "label1": "%s · SN %s · fest 11D" % (n1, sn1), "label2": "%s · SN %s · fest 5C (ASA DE) + Rückfall 10C" % (n2, du.get("sn2")),
                 "h1": h1, "h2": h2, "h3": hs[2] if len(hs) > 2 else None, "active2": s2.get("active"), "ppm2": (s3.get("cal") or {}).get("applied") if s3 else None,
                 "devs": devs, "chip_stick": {"bc": AIR_TAG["11D"], "asa": AIR_TAG["5C"], "cal": AIR_TAG["hobby"], "433": AIR_TAG["hobby"], "aprs": AIR_TAG["hobby"],
                                              "meteor": AIR_TAG["hobby"], "act": AIR_TAG["hobby"], "noise": AIR_TAG["hobby"]}}
    d["shares2"] = [dict(x, name=x.get("k")) for x in (st.get("shares2") or [])] if not a2 else []
    if a1:
        d["shares"] = []
    k = d.get("krise") or {}
    parts = [x for x in (k.get("txt") or "").split(" · ") if x and not x.startswith("Stick") and not x.startswith("Einzelbetrieb") and not any(x.startswith(str(n)) for n in (n1, n2, n3) if n)]
    parts.append(" · ".join(h["txt"] for h in hs))
    rank = {"ok": 0, "grau": 0, "lernt": 1, "gelb": 2, "rot": 3}
    lv = k.get("lvl") or "ok"
    for h in hs:
        if rank.get(h["lvl"], 0) > rank.get(lv, 0):
            lv = h["lvl"]
    hint = next((h.get("hint") for h in hs if h.get("hint")), None)
    if miss:
        hint = hint or "%s nicht angeschlossen – USB prüfen, wird automatisch erkannt" % ", ".join(miss)
    d["krise"] = {"txt": " · ".join(parts), "lvl": lv, "hint": hint, "why": k.get("why")}
    return d


def _sdrui_data():
    d = _air_orig_sdrui()
    try:
        st = (_sdr_status() or {}).get("status") or {}
        if (st.get("dual") or {}).get("reg"):
            d = _air_sdrui(st, d)
    except Exception as e:
        print("sdrAir Anzeige:", e, flush=True)
    return d


def _selftest_air_dash():
    st = {"pin_err": None, "stick_health": {"lvl": "ok", "txt": "Stick ok"}, "stick_health2": {"lvl": "gelb", "txt": "5C ohne Sync, Rückfall 10C ok"},
          "stick_health3": {"lvl": "grau", "txt": "Stick 2 nicht angeschlossen"}, "s2": {"active": "dab:1"}, "s3": {"pin_err": "Stick 72055505 fehlt"},
          "dual": {"on": True, "reg": True, "name1": "Airspy R2", "name2": "Stick 1", "name3": "Stick 2", "sn1": "44A42E4F2A5B1C83", "sn2": "19348831", "sn3": "72055505"},
          "devs": [{"name": "Airspy R2", "role": "11D", "present": True, "serial": "44A42E4F2A5B1C83"}, {"name": "Stick 1", "role": "5C", "present": True, "serial": "19348831"},
                   {"name": "Stick 2", "role": "hobby", "present": False, "serial": "72055505"}, {"name": "RTL-Stick SN 00000003", "role": "", "present": True, "usb": "0bda:2838"}]}
    d = _air_sdrui(st, {"krise": {"txt": "Lage ruhig · Stick 1 ok · Stick 2 fehlt", "lvl": "ok"}})
    u = d["dual"]
    assert u["label1"].startswith("Airspy R2 · SN 44A42E4F2A5B1C83") and u["h1"]["txt"] == "Airspy R2 ok" and u["h3"]["lvl"] == "grau" and u["h3"]["txt"] == "Stick 2 nicht angeschlossen", u
    assert "Stick 2 Hobby (nicht angeschlossen)" in u["mode"] and "erkannt, ohne Rolle: RTL-Stick SN 00000003" in u["mode"] and u["chip_stick"]["bc"] == "AIR", u["mode"]
    assert d["krise"]["txt"] == "Lage ruhig · Airspy R2 ok · Stick 1: 5C ohne Sync, Rückfall 10C ok · Stick 2 nicht angeschlossen" and d["krise"]["lvl"] == "gelb", d["krise"]
    j = globals().get("_FU_JS", "") + globals().get("_SD_JS", "")
    for k in ("D2&&D2.devs,D2&&D2.air", "var AIR=", "erkannt, ohne Rolle – nie benutzt", "s2s.style.display=(D2&&D2.air)?'none':''", "läuft auf dem Airspy"):
        assert k in j, k
    return "sdrAir Anzeige ok (Gerätenamen, fehlend grau, ohne Rolle sichtbar, kein Übernahme-Knopf, Namen vor TII)"


try:
    _AIRD = {"selftest": _selftest_air_dash()}
    print("sdrAir aktiv: %s" % _AIRD["selftest"], flush=True)
except Exception as _air_e:
    _AIRD = {"selftest": "FEHLER %s" % _air_e}
    print("sdrAir Anzeige FEHLER:", _air_e, flush=True)
AID_EOF
EXPECT_HL="01c19375256b05bc91c54877244c2ef27c9e866778eb9f2b98fe90eb4a430ed5"
cat > "$W/prepper-sdr-wdhelper" << 'AIH_EOF'
#!/usr/bin/python3 -I
"""prepper-sdr-wdhelper (sdrWd, sdrAir) - die einzigen root-Aktionen des SDR-Daten-Watchdogs von prepper-sdr.
  check              nichts aendern, nur Aufruf/Berechtigung pruefen (rc 0)
  usb-reset SERIAL   genau EIN USB-Geraet 0bda:2838 (RTL-SDR) mit dieser Seriennummer (genau 8 Ziffern), kein Hub:
                     USBDEVFS_RESET auf /dev/bus/usb/BBB/DDD, danach authorized 0 -> 1, wartet bis die Seriennummer wieder da ist
  usb-reset-air HEX  dasselbe fuer genau EIN Airspy 1d50:60a1 mit dieser Seriennummer (genau 16 Hex-Zeichen, sysfs "AIRSPY SN:<HEX>")
  reboot             systemctl reboot, hoechstens 1x je 55 min und 6x je 24 h (eigene Sperrdatei /var/lib/prepper-sdr-wd/reboots.json)
  selftest           nur Fake-Baum in einem Temp-Verzeichnis, nichts Echtes
Nie: Hubs, andere Geraete (SSD/SATA-Bruecke 174c:55aa, Hubs 2109:3431 / 05e3:0610), Portstrom (uhubctl), Interfaces, Root-Hubs.
rc: 0 ok, 2 Aufruf falsch, 3 Stick nicht/mehrfach gefunden, 4 Zuruecksetzen fehlgeschlagen, 5 Stick nicht wieder da, 6 Neustart-Sperre, 7 Neustart-Befehl fehlgeschlagen, 8 kein root"""
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import syslog
import time

SYS = "/sys/bus/usb/devices"
DEV = "/dev/bus/usb"
STATE = "/var/lib/prepper-sdr-wd"
LOCK = "/run/prepper-sdr-wdhelper.lock"
SN_RE = re.compile(r"^[0-9]{8}$")
AIR_SN_RE = re.compile(r"^[0-9A-F]{16}$")
AIR_VIDPID = ("1d50", "60a1")
NAME_RE = re.compile(r"^[0-9]{1,3}-[0-9]{1,3}(\.[0-9]{1,3}){0,6}$")   # nur Geraete (keine Interfaces 1-1.2:1.0, keine Root-Hubs usb1)
VIDPID = ("0bda", "2838")
USBDEVFS_RESET = 0x5514                                                # _IO('U', 20)
REBOOT_GAP_S = 55 * 60
REBOOT_MAX_24H = 6
SYSTEMCTL = ("/usr/bin/systemctl", "/bin/systemctl")


def log(msg):
    try:
        syslog.openlog("prepper-sdr-wdhelper")
        syslog.syslog(syslog.LOG_NOTICE, msg)
    except Exception:
        pass


def _rd(d, k):
    with open(os.path.join(d, k), encoding="ascii", errors="replace") as f:
        return f.read().strip()


def _air_sn(s):
    s = str(s or "").strip().upper()
    for pre in ("AIRSPY SN:", "0X"):
        if s.startswith(pre):
            s = s[len(pre):].strip()
    return s


def find(root, sn, air=False):
    """Alle Geraete 0bda:2838 (bzw. Airspy 1d50:60a1) mit genau dieser Seriennummer, ohne Hubs. -> [(Name, Pfad)]"""
    out = []
    for n in sorted(os.listdir(root)):
        if not NAME_RE.match(n):
            continue
        d = os.path.join(root, n)
        try:
            vid, pid, ser = _rd(d, "idVendor").lower(), _rd(d, "idProduct").lower(), _rd(d, "serial")
        except Exception:
            continue
        if air:
            if (vid, pid) != AIR_VIDPID or _air_sn(ser) != sn:
                continue
        elif (vid, pid) != VIDPID or ser != sn:
            continue
        try:
            if _rd(d, "bDeviceClass") == "09":
                continue                                               # Hub - nie
        except Exception:
            pass
        out.append((n, d))
    return out


def usb_reset(sn, root=SYS, devroot=DEV, ioctl=None, sleep=time.sleep, wait_s=20, air=False):
    if not isinstance(sn, str) or not (AIR_SN_RE if air else SN_RE).match(sn):
        return 2, "Seriennummer ungueltig (%s)" % ("genau 16 Hex-Zeichen" if air else "genau 8 Ziffern")
    f = find(root, sn, air)
    if len(f) != 1:
        return 3, "Stick SN %s %s" % (sn, "nicht gefunden" if not f else "mehrfach gefunden (%d) - nichts getan" % len(f))
    name, d = f[0]
    note = []
    try:
        bus, dev = int(_rd(d, "busnum")), int(_rd(d, "devnum"))
        node = os.path.join(devroot, "%03d" % bus, "%03d" % dev)
        st = os.stat(node, follow_symlinks=False)
        if ioctl is None and not stat.S_ISCHR(st.st_mode):
            raise RuntimeError("%s ist kein Geraeteknoten" % node)
        fd = os.open(node, os.O_WRONLY | os.O_NOFOLLOW)
        try:
            (ioctl or fcntl.ioctl)(fd, USBDEVFS_RESET, 0)
            note.append("USBDEVFS_RESET %s" % node)
        finally:
            os.close(fd)
    except Exception as e:
        note.append("USBDEVFS_RESET nicht moeglich (%s)" % str(e)[:80])
    sleep(1.0)
    try:
        auth = os.path.join(d, "authorized")
        if os.path.exists(auth) and len(find(root, sn, air)) == 1:
            with open(auth, "w") as fh:
                fh.write("0")
            sleep(1.5)
            with open(auth, "w") as fh:
                fh.write("1")
            note.append("authorized 0/1 %s" % name)
    except Exception as e:
        note.append("authorized nicht moeglich (%s)" % str(e)[:80])
    if not any(x.startswith(("USBDEVFS_RESET /", "authorized 0/1")) for x in note):
        return 4, "; ".join(note)
    end = time.time() + wait_s
    while True:
        if len(find(root, sn, air)) == 1:
            return 0, ("Airspy" if air else "Stick") + " SN %s wieder da (%s): %s" % (sn, name, "; ".join(note))
        if time.time() >= end:
            return 5, "Stick SN %s nach %d s nicht wieder da: %s" % (sn, wait_s, "; ".join(note))
        sleep(1.0)


def reboot(state=STATE, now=None, run=None):
    now = int(now or time.time())
    os.makedirs(state, mode=0o700, exist_ok=True)
    fn = os.path.join(state, "reboots.json")
    try:
        with open(fn, encoding="utf-8") as f:
            ts = [int(x) for x in json.load(f) if isinstance(x, (int, float))]
    except Exception:
        ts = []
    ts = [x for x in ts if x > now - 86400]          # Eintraege in der Zukunft (Uhr zurueckgesprungen) bleiben und sperren
    if ts and now - max(ts) < REBOOT_GAP_S:
        return 6, "Pi-Neustart gesperrt: letzter vor %d min (mindestens %d min Abstand)" % (max(0, now - max(ts)) // 60, REBOOT_GAP_S // 60)
    if len(ts) >= REBOOT_MAX_24H:
        return 6, "Pi-Neustart gesperrt: schon %d in 24 h" % len(ts)
    tmp = fn + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ts + [now], f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, fn)
    os.sync()
    sc = next((x for x in SYSTEMCTL if os.path.isfile(x)), None)
    if sc is None:
        return 7, "systemctl fehlt"
    r = (run or subprocess.run)([sc, "reboot"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
    return (0, "Pi-Neustart angefordert") if r.returncode == 0 else (7, "systemctl reboot rc %d: %s" % (r.returncode, (r.stderr or "").strip()[:100]))


def selftest():
    import tempfile
    t = tempfile.mkdtemp(prefix="wdhelper-")
    root, devroot = os.path.join(t, "sys"), os.path.join(t, "dev")

    def mk(n, vid, pid, sn, cls="00", bus=1, dev=5):
        d = os.path.join(root, n)
        os.makedirs(d)
        for k, v in (("idVendor", vid), ("idProduct", pid), ("serial", sn), ("bDeviceClass", cls), ("busnum", str(bus)), ("devnum", str(dev)), ("authorized", "1")):
            open(os.path.join(d, k), "w").write(v + "\n")
        os.makedirs(os.path.join(devroot, "%03d" % bus), exist_ok=True)
        open(os.path.join(devroot, "%03d" % bus, "%03d" % dev), "w").close()
    mk("1-1", "2109", "3431", "", "09", 1, 2)                     # VIA-Hub
    mk("2-1", "174c", "55aa", "19348831", "00", 2, 2)             # SSD-Bruecke (gleiche Ziffern als Falle)
    mk("1-1.1", "0bda", "2838", "19348831", "00", 1, 5)
    mk("1-1.2", "0bda", "2838", "72055505", "00", 1, 6)
    mk("1-1.3", "0bda", "2838", "11111111", "09", 1, 7)           # Hub-Klasse mit RTL-ID: nie
    os.makedirs(os.path.join(root, "1-1.1:1.0"))                   # Interface: nie
    open(os.path.join(root, "1-1.1:1.0", "serial"), "w").write("19348831\n")
    io, sl = [], []
    fake_io = lambda fd, req, arg: io.append((os.readlink("/proc/self/fd/%d" % fd), req))
    assert [n for n, _ in find(root, "19348831")] == ["1-1.1"] and find(root, "11111111") == []
    for bad in ("1934883", "193488311", "19348831;x", "../12345", "", None, "1934883a"):
        assert usb_reset(bad, root, devroot, fake_io, sl.append)[0] == 2, bad
    assert usb_reset("11111111", root, devroot, fake_io, sl.append)[0] == 3 and not io
    rc, txt = usb_reset("19348831", root, devroot, fake_io, sl.append, wait_s=0)
    assert rc == 0 and io == [(os.path.join(devroot, "001", "005"), USBDEVFS_RESET)], (rc, txt, io)
    assert open(os.path.join(root, "1-1.1", "authorized")).read() == "1" and open(os.path.join(root, "1-1.2", "authorized")).read().strip() == "1"
    assert open(os.path.join(root, "2-1", "authorized")).read().strip() == "1" and open(os.path.join(root, "1-1", "authorized")).read().strip() == "1"
    mk("1-1.4", "0bda", "2838", "72055505", "00", 1, 8)
    assert usb_reset("72055505", root, devroot, fake_io, sl.append)[0] == 3 and len(io) == 1      # doppelt: nichts
    ran = []

    class R:
        returncode = 0
        stderr = ""
    fake_run = lambda cmd, **kw: (ran.append(cmd), R())[1]
    st = os.path.join(t, "state")
    old = SYSTEMCTL
    globals()["SYSTEMCTL"] = (sys.executable,)
    try:
        assert reboot(st, 1000000, fake_run)[0] == 0 and ran == [[sys.executable, "reboot"]]
        assert reboot(st, 1000000 + 54 * 60, fake_run)[0] == 6 and len(ran) == 1
        assert reboot(st, 1000000 + 56 * 60, fake_run)[0] == 0 and len(ran) == 2
        for k in range(3, 7):
            reboot(st, 1000000 + k * 3600, fake_run)
        assert len(ran) == 6 and reboot(st, 1000000 + 7 * 3600, fake_run)[0] == 6
        assert reboot(st, 1000000 + 30 * 3600, fake_run)[0] == 0
        assert reboot(st, 1000000 + 20 * 3600, fake_run)[0] == 6         # Uhr zurueck: gesperrt
    finally:
        globals()["SYSTEMCTL"] = old
    os.environ["WDH_QUIET"] = "1"
    assert main(["x"]) == 2 and main(["usb-reset"]) == 2 and main(["usb-reset", "1", "2"]) == 2 and main(["reboot", "now"]) == 2 and main(["rm", "-rf"]) == 2
    AS = "44A42E4F2A5B1C83"
    mk("1-1.5", "1d50", "60a1", "AIRSPY SN:44a42e4f2a5b1c83", "00", 1, 9)
    mk("1-1.6", "1d50", "60a1", "AIRSPY SN:0000000000000001", "09", 1, 10)       # Hub-Klasse: nie
    assert [n for n, _ in find(root, AS, True)] == ["1-1.5"] and find(root, AS) == [] and find(root, "19348831", True) == []
    for bad in ("44a42e4f2a5b1c83", "44A42E4F2A5B1C8", "44A42E4F2A5B1C83;x", "19348831", "", None, "G4A42E4F2A5B1C83"):
        assert usb_reset(bad, root, devroot, fake_io, sl.append, air=True)[0] == 2, bad
    assert usb_reset("0000000000000001", root, devroot, fake_io, sl.append, air=True)[0] == 3
    n0 = len(io)
    rc, txt = usb_reset(AS, root, devroot, fake_io, sl.append, wait_s=0, air=True)
    assert rc == 0 and io[n0:] == [(os.path.join(devroot, "001", "009"), USBDEVFS_RESET)], (rc, txt, io)
    assert usb_reset("19348831", root, devroot, fake_io, sl.append, air=True)[0] == 2                  # RTL-Nummer nie als Airspy
    assert main(["usb-reset-air"]) == 2 and main(["usb-reset-air", AS, "x"]) == 2
    print("wdhelper selftest ok (Airspy nur 1d50:60a1 mit genau dieser 16-stelligen Hex-Seriennummer; nur 0bda:2838 mit genau dieser 8-stelligen Seriennummer, kein Hub/Interface/SSD, doppelt = nichts, Neustart max 1 je 55 min + 6 je 24 h, Fake-Baum)")
    return 0


def main(argv):
    if argv == ["check"]:
        print("bereit (uid %d)" % os.geteuid())
        return 0
    if argv == ["selftest"]:
        return selftest()
    if not ((len(argv) == 2 and argv[0] in ("usb-reset", "usb-reset-air")) or argv == ["reboot"]):
        if os.environ.get("WDH_QUIET") != "1":
            print("Aufruf: prepper-sdr-wdhelper check | usb-reset SERIAL | usb-reset-air HEX16 | reboot | selftest", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("nur als root (sudo -n)", file=sys.stderr)
        return 8
    lk = open(LOCK, "w")
    fcntl.flock(lk, fcntl.LOCK_EX)
    if argv[0] == "usb-reset":
        rc, txt = usb_reset(argv[1])
    elif argv[0] == "usb-reset-air":
        rc, txt = usb_reset(argv[1], air=True)
    else:
        rc, txt = reboot()
    log("%s %s -> rc %d: %s" % (argv[0], argv[1] if len(argv) > 1 else "", rc, txt))
    print(txt)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
AIH_EOF
EXPECT_G="a5c47534982d342f190a4980e95f06f5c73bd88391d473f1f9aa39ae2f440478"
cat > "$W/guard_wd2.py" << 'WDG_EOF'
"""AST-Guard sdrWd2. Aufruf: guard_wd2.py EDITS  ART ALT NEU BLOCK ...  (ART = sdr | sm | dash) -> 0 ok, 1 Verstoss.
Rueckbau (Block weg, Stellen zurueck) muss Byte fuer Byte die Basis ergeben. Neuer Block/Stellen: kein Prozess, kein Netz, kein shell, keine Faeden,
keine Sendewege, kein Hilfsprogramm-Aufruf; _wd_helper/_wd_do/WD_HELPER/Hilfsprogramm-Pfad unveraendert; Uebernahme sperrt nur noch den Pi-Neustart."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
OKMOD = {"sm": set(), "sdr": {"tempfile"}, "dash": set()}
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover_auto", "takeover_set", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode", "reboot", "_wd_helper", "_wd_do",
       "unlink", "remove", "rmtree", "chmod", "chown")
err = []
a = sys.argv[2:]
done_all = True
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    done = old == new and B.splitlines()[0] in old
    done_all = done_all and done
    if new.count(B) != 1:
        err.append("%s: Block sdrWd2 fehlt oder doppelt" % kind)
    r = new.replace(B, "", 1) if kind == "dash" else new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sdrWd2" % (kind, len(E)))
    for o, n in E:
        ol = set(o.splitlines())
        low = "\n".join(x for x in n.splitlines() if x not in ol).lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread", "_wd_helper(", "_wd_do(", "uhubctl", "unbind"):
            if k in low:
                err.append("%s Stelle: %s" % (kind, k))
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        err.append("%s Block: Syntax %s" % (kind, e)); continue
    fn_of = {}
    for f in t.body:
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                fn_of[id(x)] = f.name
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if mod not in OKMOD[kind] or not fn_of.get(id(n), "").startswith("selftest"):
                    err.append("%s Block: Import %s" % (kind, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s Block: shell" % kind)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer", "open") and not (
                    nm == "open" and fn_of.get(id(n), "").startswith("_selftest")) or base in ("subprocess", "requests", "socket", "multiprocessing", "shutil"):
                err.append("%s Block: Aufruf %s in %s" % (kind, nm, fn_of.get(id(n), "?")))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and any(k in n.value for k in ("uhubctl", "/unbind", "bind_ports", "power/control", "/usr/local/sbin", "sudo")):
            err.append("%s Block: verbotener Text %s" % (kind, n.value[:40]))
    if kind == "sdr":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_wd_helper", "_wd_do", "wd_helper_state", "_wd_decide", "_wd_save", "_wd_emit"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sdr: %s veraendert" % fn)
        if new.count('WD_HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"') != 1:
            err.append("sdr: WD_HELPER-Pfad")
        if new.count('if act in (None, "reboot") and t2_takeover(pl.base).get("on"):') != 1 or new.count("t2_takeover(pl.base).get(\"on\")") != 1:
            err.append("sdr: Uebernahme-Sperre nicht genau auf Pi-Neustart begrenzt")
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard sdrWd2: nur die vorgesehenen Stellen + Bloecke%s; kein Prozess/Netz/shell/Faden/Sendeweg, kein Aufruf des Hilfsprogramms im neuen Code; _wd_helper/_wd_do/_wd_decide/WD_HELPER unveraendert; Uebernahme sperrt nur Stufe 4 (Pi-Neustart)" % (
    " (schon eingespielt)" if done_all else ""))
WDG_EOF
EXPECT_AG="962c469ea9ea71beb7cfbbd47265fb87681f14ec34e6159359073efa111f63cf"
cat > "$W/guard_air.py" << 'AIG_EOF'
"""AST-Guard sdrAir. Aufruf: guard_air.py EDITS  ART ALT NEU BLOCK ...  (ART = sdr | sm | dash; ALT = Stand nach sdrWd2) -> 0 ok, 1 Verstoss.
Rueckbau (Block weg, Stellen zurueck) muss Byte fuer Byte ALT ergeben. Neuer Code: kein Prozess, kein Netz, kein shell, keine Sendewege;
erlaubt sind nur die aufgelisteten Aufrufe (Hilfsprogramm nur usb-reset-air ueber _wd_helper, Faden nur fuer den Hobby-Planer, nice nur fuer welle-cli des Airspy)."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
OKMOD = {"sm": {"tempfile"}, "sdr": {"tempfile"}, "dash": set()}
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover_auto", "takeover_set", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode", "reboot", "_wd_helper", "_wd_do",
       "unlink", "remove", "rmtree", "chmod", "chown", "setpriority", "thread")
# (Art, Funktion, Aufruf) die im neuen Code bewusst erlaubt sind
ALLOW = {("sdr", "_air_usb", "_wd_helper"),                 # nur ["usb-reset-air", <16 hex>]
         ("sdr", "_wd_do", "_air_orig_wd_do"), ("sdr", "_wd_do", "_air_usb"),
         ("sdr", "_air_cpu_tick", "setpriority"),           # nice fuer welle-cli des Airspy
         ("sdr", "_air_cpu_tick", "open"),                  # nur /proc/<pid>/stat lesen
         ("sdr", "_air_usb", "kill"),                       # eigenes welle-cli vor dem USB-Reset beenden
         ("sdr", "_air_dual_tick", "Thread"),                # Hobby-Planer (einmal)
         ("sm", "takeover_set", "_air_orig_takeover_set"), ("sm", "takeover_auto", "_air_orig_takeover_auto")}
err = []
seen_allow = set()
a = sys.argv[2:]
done_all = True
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    done = old == new and B.splitlines()[0] in old
    done_all = done_all and done
    if new.count(B) != 1:
        err.append("%s: Block sdrAir fehlt oder doppelt" % kind)
    r = new.replace(B, "", 1) if kind == "dash" else new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sdrAir" % (kind, len(E)))
    for o, n in E:
        ol = set(o.splitlines())
        low = "\n".join(x for x in n.splitlines() if x not in ol).lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread", "_wd_helper(", "_wd_do(", "uhubctl", "unbind",
                  "fetch(", "xmlhttprequest", "takeover_set(", "reboot"):
            if k in low:
                err.append("%s Stelle: %s" % (kind, k))
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        err.append("%s Block: Syntax %s" % (kind, e)); continue
    fn_of = {}
    for f in t.body:
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                fn_of[id(x)] = f.name
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if mod not in OKMOD[kind] or not fn_of.get(id(n), "").startswith("selftest"):
                    err.append("%s Block: Import %s" % (kind, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s Block: shell" % kind)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            fn = fn_of.get(id(n), "?")
            if (kind, fn, nm) in ALLOW:
                seen_allow.add((kind, fn, nm)); continue
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer", "open") and not (
                    nm == "open" and fn.startswith("_selftest")) or base in ("subprocess", "requests", "socket", "multiprocessing", "shutil"):
                if fn.startswith(("_selftest", "selftest")) and nm in ("_wd_helper", "_wd_do", "_air_usb", "remove", "kill", "reboot", "takeover_set", "takeover_auto"):
                    continue                                   # Selbsttest mit Fake-Hilfsprogramm
                err.append("%s Block: Aufruf %s in %s" % (kind, nm, fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and any(k in n.value for k in ("uhubctl", "/unbind", "bind_ports", "power/control", "/usr/local/sbin", "sudo")):
            err.append("%s Block: verbotener Text %s" % (kind, n.value[:40]))
    if kind == "sdr":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_wd_helper", "_wd_do", "wd_helper_state", "_wd_decide", "_wd_save", "_wd_emit"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sdr: Original %s veraendert" % fn)
        if new.count('WD_HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"') != 1:
            err.append("sdr: WD_HELPER-Pfad")
        hl = [n for n in ast.walk(t) if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "_wd_helper" and fn_of.get(id(n)) == "_air_usb"]
        if len(hl) != 1 or not (hl[0].args and isinstance(hl[0].args[0], ast.List) and isinstance(hl[0].args[0].elts[0], ast.Constant) and hl[0].args[0].elts[0].value == "usb-reset-air"):
            err.append("sdr: _air_usb ruft das Hilfsprogramm nicht genau einmal mit usb-reset-air")
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard sdrAir: nur die vorgesehenen Stellen + Bloecke%s; kein Prozess/Netz/shell/Sendeweg; erlaubt nur %d gelistete Aufrufe (Hilfsprogramm nur usb-reset-air, Faden nur Hobby-Planer, nice nur Airspy-welle-cli); Original-Watchdog-Funktionen + WD_HELPER unveraendert" % (
    " (schon eingespielt)" if done_all else "", len(seen_allow)))
AIG_EOF
EXPECT_CK="3a6213106b1d299dbce29f237b13cdcb255661460a7d12f15c5d6455bc06cc87"
cat > "$W/sqlccheck.py" << 'WDC_EOF'
"""sqlC Pruef-/Anzeigehilfe (nur lesen). Modi: counts DB | statusfresh DIR T0 | live F | dbok F | t4 F | observe DIR SEK | audit DIR"""
import json
import os
import sqlite3
import sys
import time

KEYS = (("sdr_status.json", "sdr_status"), ("broadcast_state.json", "broadcast_state"))


def ft(t):
    try:
        return time.strftime("%H:%M:%S", time.localtime(int(t)))
    except Exception:
        return "–"


def ro(p):
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
    c.execute("PRAGMA busy_timeout=10000")
    return c


def row(p, key):
    try:
        c = ro(p)
    except Exception:
        return None
    try:
        if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='state'").fetchone():
            return None
        return c.execute("SELECT ts, src_t, json, n FROM state WHERE key=?", (key,)).fetchone()
    finally:
        c.close()


def snap(base):
    p = os.path.join(base, "lagezentrum.db")
    out = {}
    for name, key in KEYS:
        r = row(p, key)
        f = os.path.join(base, name)
        out[name] = {"db_t": float(r[1] or r[0]) if r else None, "db_n": r[3] if r else None, "json_mt": os.path.getmtime(f) if os.path.exists(f) else None}
    w = row(p, "sqlb_writer")
    out["writer"] = json.loads(w[2]) if w else {}
    out["writer_t"] = float(w[1] or w[0]) if w else None
    return out


a = sys.argv[1]
now = time.time()
if a == "counts":
    c = ro(sys.argv[2])
    try:
        q = lambda s, *x: c.execute(s, x).fetchone()[0]
        st = q("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='state'")
        print("events %d (aktiv %d), telemetry %d, state %s" % (q("SELECT COUNT(*) FROM events"), q("SELECT COUNT(*) FROM events WHERE expires IS NULL OR expires >= ?", int(now)),
              q("SELECT COUNT(*) FROM telemetry"), ("%d Zeilen" % q("SELECT COUNT(*) FROM state")) if st else "fehlt"))
    finally:
        c.close()
elif a == "statusfresh":
    base, t0 = sys.argv[2], float(sys.argv[3])
    best = 0
    r = row(os.path.join(base, "lagezentrum.db"), "sdr_status")
    try:
        best = max(best, float(json.loads(r[2]).get("t") or 0)) if r else best
    except Exception:
        pass
    try:
        best = max(best, float(json.load(open(os.path.join(base, "sdr_status.json"))).get("t") or 0))
    except Exception:
        pass
    sys.exit(0 if best >= t0 else 1)
elif a == "live":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    assert t.get("line", "").startswith("Datenquelle:") and t.get("mode") in ("db", "dual", "json") and "mirror_age_s" in t and "fallback" in t, t
    w = t.get("writer") or {}
    print("/api/sdr/live Transport: Betriebsart %s, %s; Ersatz aktiv %s, JSON-Notkopie vor %s s; Schreibfaden ok %s, Fehler %s, verworfen %s, JSON-Schreibvorgaenge %s" % (
        t["mode"], t["line"], "ja" if t.get("fallback") else "nein", t.get("mirror_age_s"), w.get("ok"), w.get("err"), w.get("drop"), w.get("json_n")))
elif a == "dbok":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    bad = {k: v.get("why") for k, v in (t.get("items") or {}).items() if v.get("src") != "db"}
    assert t.get("mode") == "db" and not bad and not t.get("fallback") and t.get("ok"), "Betriebsart %s, nicht aus DB %s, Ersatz %s (%s)" % (t.get("mode"), bad, t.get("fallback"), t.get("line"))
    print("DB-primaer aktiv: beide aus der DB, kein JSON-Ersatz")
elif a == "t4":
    d = json.load(open(sys.argv[2]))
    t = d.get("tr") or {}
    assert t.get("line", "").startswith("Datenquelle:"), d.get("tr")
    print("/api/t4/status SDR-Status-Kachel: %s" % t["line"])
elif a == "observe":
    base, secs = sys.argv[2], int(sys.argv[3])
    s0 = snap(base)
    print("  Beobachtung %d s (nur lesen): Zeit | Status DB-Alter | Status JSON-Alter | Rundfunk DB-Alter | Rundfunk JSON-Alter | Ersatz" % secs)
    ok, n, chg = True, 0, {k: 0 for k, _ in KEYS}
    last = {k: s0[k]["json_mt"] for k, _ in KEYS}
    end = time.time() + secs
    while True:
        s = snap(base)
        t = time.time()
        ag = lambda v: ("%d s" % (t - v)) if v else "–"
        fb = (s["writer"] or {}).get("fallback")
        print("  %s | %s | %s | %s | %s | %s" % (ft(t), ag(s["sdr_status.json"]["db_t"]), ag(s["sdr_status.json"]["json_mt"]), ag(s["broadcast_state.json"]["db_t"]),
                                              ag(s["broadcast_state.json"]["json_mt"]), "JA" if fb else "nein"), flush=True)
        for k, _ in KEYS:
            if s[k]["json_mt"] != last[k]:
                chg[k] += 1
                last[k] = s[k]["json_mt"]
        if not s["sdr_status.json"]["db_t"] or t - s["sdr_status.json"]["db_t"] > 90:
            ok = False
        n += 1
        if time.time() >= end:
            break
        time.sleep(min(30, max(1, end - time.time())))
    s = snap(base)
    fb = (s["writer"] or {}).get("fallback")
    db_n = (s["sdr_status.json"]["db_n"] or 0) - (s0["sdr_status.json"]["db_n"] or 0)
    print("  Ergebnis: Status %d mal in die DB geschrieben, JSON-Dateien geaendert: sdr_status.json %dx, broadcast_state.json %dx (Notkopie alle 10 min), Ersatz %s" % (
        db_n, chg["sdr_status.json"], chg["broadcast_state.json"], "AKTIV" if fb else "aus"))
    good = ok and not fb and db_n >= 1 and chg["sdr_status.json"] <= 1
    print("  %s" % ("OK DB frisch, JSON-Notkopie altert, Ersatz aus" if good else "WARNUNG: DB nicht durchgehend frisch oder JSON wird laufend geschrieben (Ersatz/Anforderung?)"))
    sys.exit(0 if good else 1)
elif a == "audit":
    base = sys.argv[2]
    own = {"dashboard.py", "sdr_manager.py", "prepper_sdr.py", "database.py"}
    skip_d = {"venv", ".git", "__pycache__", "node_modules", ".cache", "archive", "mesh_inbox", "mesh_inbox_bayern", ".local", ".npm", ".mozilla", ".config"}
    hits = []
    roots = [os.path.dirname(base.rstrip("/")) or base, "/etc/systemd/system", "/etc/cron.d"]
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            dn[:] = [x for x in dn if x not in skip_d and not x.startswith("sqlb-") and dp.count(os.sep) - root.count(os.sep) < 4]
            for f in fn:
                if ".bak" in f or f.endswith((".json", ".jsonl", ".log", ".db", ".db-wal", ".db-shm", ".tmp", ".pyc", ".jpg", ".png", ".1")) or (dp.rstrip("/") == base.rstrip("/") and f in own):
                    continue
                fp = os.path.join(dp, f)
                try:
                    if os.path.getsize(fp) > 5 * 1024 * 1024:
                        continue
                    s = open(fp, encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                if "sdr_status.json" in s or "broadcast_state.json" in s:
                    hits.append(fp)
    pat = [h for h in hits if os.path.basename(h) in own or "/src/" in h or os.path.basename(h).startswith(("apply-", "patch-", "guard_", "edits", "sql", "kv", "tii", "body", "head", "build")) or "-apply" in h or "/sbx" in h]
    oth = [h for h in hits if h not in pat]
    if not oth:
        print("  keine weiteren Leser von sdr_status.json/broadcast_state.json gefunden (ausser dashboard.py, sdr_manager.py, prepper_sdr.py - alle auf DB zuerst umgestellt)")
    for h in oth[:30]:
        print("  liest/nennt JSON direkt (bekommt die Notkopie, max. 10 min alt; laufend nur im Ersatzfall): %s" % h)
    if pat:
        print("  dazu %d alte Patch-/Pruefskripte bzw. Kopien (nur beim Einspielen benutzt, unkritisch), z. B. %s" % (len(pat), ", ".join(os.path.basename(x) for x in pat[:4])))
WDC_EOF
EXPECT_FC="d570fbd0611aa288a86ac193f77a931efc373d5b1a2ce779416b2a06c9d446ba"
cat > "$W/fucheck.py" << 'WDF_EOF'
"""Pruefhilfen sdrLog/funkUI (nur lesen). fucheck.py funk|dabhist|meteor DATEI [W] | thumb BASIS | live DATEI | techlog BASIS | pil"""
import json, os, re, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="funkui-js"', 'id="funkui-css"', 'id="fu-meteor"', "#t2Tile,#t4Sdr{display:none", 'id="t4-data"', 'id="t2-data"', 'id="sdrui-data"', 'id="stickTestCard"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="funkui-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "funkui.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    import shutil
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: JavaScript fehlerhaft")
    print("/funk: Funk-Lage, Steuerung, Meteor-Kachel eingehaengt (1x), alte Kacheln Sticks/SDR-Status verborgen, Antennentest vorhanden")
elif a == "dabhist":
    s = rd(sys.argv[2])
    assert "fu-chips" in s and "<table" not in s and "Programm-Infos" in s and "Grenzwerte" in s, "/dabhist ohne Karten/Filter"
    print("/dabhist: Karten, 44-px-Filter (Programm-Infos aus), %d Eintraege angezeigt" % s.count('class="fu-ev '))
elif a == "meteor":
    s = rd(sys.argv[2])
    assert "fu-wrap" in s and "Überflüge" in s and "<table" not in s, "/meteor ohne neue Seite"
    print("/meteor: Karten-Seite, %d Bilder, %d Vorschau-Verweise" % (s.count('class="fu-th"'), s.count("/meteor/thumb/")))
elif a == "thumb":
    d = os.path.join(sys.argv[2], "meteor")
    r = re.compile(r"^[0-9]{8}-[0-9]{4}_[A-Za-z0-9]{1,8}_[A-Za-z0-9_-]{1,40}\.(jpg|png)$")
    fs = sorted((f for f in os.listdir(d) if r.match(f)), reverse=True) if os.path.isdir(d) else []
    print(fs[0] if fs else "")
elif a == "live":
    d = json.load(open(sys.argv[2]))
    w = d.get("watchdog") or {}
    print("/api/sdr/live: Status %s, Lebenszeichen %s%s" % (d.get("status"), w.get("src") or "DB", (" (%s)" % w.get("note_mem")) if w.get("note_mem") else ""))
elif a == "techlog":
    try:
        d = json.load(open(os.path.join(sys.argv[2], "sdr_techlog.json")))
        ev = d.get("ev") or []
        print("sdr_techlog.json: %d Eintraege%s" % (len(ev), (", zuletzt %s: %s" % (time.strftime("%d.%m. %H:%M", time.localtime(ev[-1]["t"])), str(ev[-1].get("text"))[:120])) if ev else ""))
    except FileNotFoundError:
        print("sdr_techlog.json: noch nicht vorhanden (entsteht beim ersten Technik-Ereignis)")
elif a == "pil":
    for py in sys.argv[2:]:
        r = subprocess.run([py, "-c", "import PIL; print(PIL.__version__)"], capture_output=True, text=True)
        print("  %s: PIL %s" % (py, r.stdout.strip() if r.returncode == 0 else "fehlt (Vorschaubilder aus, Seite zeigt Originale)"))
WDF_EOF
EXPECT_WC="5641abe55b10e371b440b0ff9b2a590041113b29ab490d3c8951264d0469d3bc"
cat > "$W/wdcheck.py" << 'WDK_EOF'
"""Pruefhilfen sdrWd (nur lesen). wdcheck.py helper DATEI | funk DATEI W | pi DATEI | api DATEI | state BASIS | sudoers DATEI NUTZER HELFER | masts DATEI N11 N5C N10C | tii DATEI | cfg BASIS | br24 DATEI"""
import ast, json, os, re, shutil, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "helper":
    s = rd(sys.argv[2])
    t = ast.parse(s)
    assert s.startswith("#!/usr/bin/python3 -I\n"), "Shebang"
    mods = {x.name.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.Import) for x in n.names} | {n.module.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.ImportFrom)}
    assert mods <= {"fcntl", "json", "os", "re", "stat", "subprocess", "sys", "syslog", "time", "tempfile"}, mods
    calls = [n for n in ast.walk(t) if isinstance(n, ast.Call)]
    nm = lambda f: f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
    bad = [nm(c.func) for c in calls if nm(c.func) in ("system", "popen", "Popen", "execv", "execvp", "check_output", "call", "spawn", "fork", "eval", "exec")]
    assert not bad, bad
    assert s.count("subprocess.run") == 1 and s.count("(run or subprocess.run)([sc, \"reboot\"]") == 1, "nur systemctl reboot"
    body = s.split('"""', 2)[2]
    for k in ("uhubctl", "unbind", "power/control", "bind_ports"):
        assert k not in body, k
    assert 'VIDPID = ("0bda", "2838")' in s and 'SN_RE = re.compile(r"^[0-9]{8}$")' in s and '== "09"' in s and "USBDEVFS_RESET = 0x5514" in s
    assert 'AIR_VIDPID = ("1d50", "60a1")' in s and 'AIR_SN_RE = re.compile(r"^[0-9A-F]{16}$")' in s
    print("Hilfsprogramm: nur 0bda:2838 mit 8-stelliger bzw. Airspy 1d50:60a1 mit 16-stelliger Hex-Seriennummer (keine Hubs/Interfaces), einziger Prozess systemctl reboot (gesperrt: 1 je 55 min, 6 je 24 h), kein uhubctl/Portstrom/unbind")
elif a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="sdrwd-js"', 'id="sdrwd-css"', 'id="wd-data"', 'id="funkui-js"', 'id="dh-js"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "sdrwd.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: sdrWd-JavaScript fehlerhaft")
    w = json.loads(re.search(r'<script type="application/json" id="wd-data">(.*?)</script>', s, re.S).group(1))
    assert "function rel(t)" in s and "x.title=full(r)" in s, "/funk: Empfaenger-Zeilen alt"
    print("/funk: Daten-Watchdog in Funk-Lage (%s: %s), Empfänger-Zeilen einzeilig, JS geprüft" % (w.get("lvl"), (w.get("short") or w.get("txt") or "")[:90]))
elif a == "pi":
    s = rd(sys.argv[2])
    i, j = s.find('id="wdPiBox"'), s.find('id="backupBox"')
    assert s.count('id="wdPiBox"') == 1 and 0 <= i < j, "/pi: Watchdog-Kachel fehlt oder nicht vor Sicherung"
    k = s.rfind("doPrepperRestore")
    last = k < 0 or (s.find('class="tile', max(k, j)) < 0 and s.find('class="card', j + 10) < 0)
    assert last, "/pi: Sicherung nicht mehr letzte Kachel"
    m = re.search(r'Pi-Neustarts heute: [0-9]+ · zuletzt [^<]*', s)
    print("/pi: Watchdog-Kachel vor Sicherung, Sicherung letzte Kachel; %s" % (m.group(0) if m else "?"))
elif a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and "reboot_line" in d, d
    print("/api/sdr/wd: %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:100], d.get("reboot_line")))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden (entsteht mit der ersten Prüfung)")
    else:
        d = json.load(open(f))
        st = d.get("sticks") or {}
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join("Stick %s SN %s %s" % (v.get("n"), k, ("Vorfall seit %s" % time.strftime("%d.%m. %H:%M", time.localtime(v["inc"]["since"]))) if v.get("inc") else "ok")
                                                                                     for k, v in sorted(st.items())) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "sudoers":
    f, u, h = sys.argv[2:5]
    s = rd(f)
    exp = "%s ALL=(root) NOPASSWD: %s check, %s usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], %s usb-reset-air %s, %s reboot\n" % (u, h, h, h, "[0-9A-F]" * 16, h)
    lines = [x for x in s.splitlines(True) if not x.startswith("#")]
    assert lines == [exp], (lines, exp)
    print("sudoers: genau eine Regel fuer %s: %s check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot" % (u, h))
elif a == "masts":
    d = json.load(open(sys.argv[2]))
    ms = d.get("masts") or {}
    want = dict(zip(("11D", "5C", "10C"), map(int, sys.argv[3:6])))
    got = {ch: len((ms.get(ch) or {}).get("tii") or []) for ch in want}
    if got != want:
        raise SystemExit("MASTS_DB noch nicht gemeldet: %s statt %s" % (got, want))
    nm = {}
    for ch, m in ms.items():
        for x in (m or {}).get("tii") or []:
            nm["%s %02d/%02d" % (ch, x["main"], x["sub"])] = x.get("mast")
    assert nm.get("11D 08/18") == nm.get("5C 12/11") == "Bamberg (Geisberg)" and nm.get("10C 07/01") == nm.get("11D 05/14") == "Nürnberg (Schweinau)", nm
    print("/api/t2/status MASTS_DB: 11D %(11D)d, 5C %(5C)d, 10C %(10C)d Sender (Namen je Standort gleich, z. B. 08/18 = 12/11 = Bamberg (Geisberg))" % got)
elif a == "tii":
    d = json.load(open(sys.argv[2]))
    assert d.get("ok") is not False and isinstance(d.get("masts"), list), str(d)[:200]
    n = {}
    for m in d["masts"]:
        for c in m.get("ch") or []:
            n[c.get("ch")] = n.get(c.get("ch"), 0) + 1
    print("/api/t4/tii Karte: %d Standorte mit Position, %d ohne; Kennungen je Kanal %s" % (len(d["masts"]), len(d.get("nopos") or []), ", ".join("%s %d" % kv for kv in sorted(n.items()))))
elif a == "cfg":
    D = {"wd_enable": True, "wd_yellow_min": 10, "wd_restart_min": 30, "wd_usb_min": 45, "wd_reboot_min": 60, "wd_reboot_min_interval_min": 60, "wd_reboot_max_fail": 3, "wd_usb_max": 2}
    try:
        c = json.load(open(os.path.join(sys.argv[2], "sdr_config.json")))
    except Exception:
        c = {}
    out = []
    for k, v in D.items():
        x = c.get(k, v) if isinstance(c, dict) else v
        out.append("%s=%s%s" % (k, ("an" if x else "aus") if k == "wd_enable" else x, "" if not isinstance(c, dict) or k not in c else " (gesetzt)"))
    print(" ".join(out))
elif a == "br24":
    d = json.load(open(sys.argv[2]))
    t = str(d.get("bc_note") or "")
    assert "abwechselnd" not in t and "Stick 1" in t, t
    print("/api/br24 Hinweis: %s" % t[:160])
WDK_EOF
EXPECT_WC2="fb2b6f1de50294433e16c3d52fd9f20ac4771bfd55bed95782a61a16cc09432f"
cat > "$W/wdcheck2.py" << 'WDK2_EOF'
"""Pruefhilfen sdrWd2 (nur lesen). wdcheck2.py api DATEI | state BASIS | dashok DASHBOARD BLOCK | funk HTML"""
import json, os, re, sys, time
a = sys.argv[1]
hm = lambda t: time.strftime("%d.%m. %H:%M", time.localtime(t)) if isinstance(t, (int, float)) else "–"
if a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and isinstance(d.get("sticks"), list), str(d)[:200]
    for s in d["sticks"]:
        assert all(k in s for k in ("short", "pre", "to")), "Stick %s ohne sdrWd2-Felder (short/pre/to): sdr_manager alt?" % s.get("n")
    print("/api/sdr/wd (sdrWd2): %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:110], " | ".join(
        "Stick %s %s%s%s" % (s.get("n"), s.get("lvl"), " Übernahme" if s.get("to") else "", " vor Start" if s.get("pre") else "") for s in d["sticks"])))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden"); raise SystemExit(0)
    d = json.load(open(f))
    out = []
    for sn, v in sorted((d.get("sticks") or {}).items()):
        i = v.get("inc")
        if not i:
            out.append("Stick %s SN %s ok" % (v.get("n"), sn)); continue
        out.append("Stick %s SN %s Vorfall %s seit %s%s%s, Eskalation ab %s, Neustart %s, USB %s%s" % (
            v.get("n"), sn, i.get("ch") or "?", hm(i.get("since")), " (vor Start)" if i.get("pre") else "", " Übernahme" if i.get("to") else "", hm(i.get("t0")),
            i.get("restart_n", 0), i.get("usb_n", 0), (" · 10C %s" % ("ok " + hm(i.get("fb_ok_t")) if i.get("fb_ok") else "ohne Sync")) if i.get("fb_t") else ""))
    print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "dashok":
    s = open(sys.argv[2], encoding="utf-8").read()
    def lit(name):
        i = s.index(name + ' = r"""') + len(name + ' = r"""')
        return s[i:s.index('"""', i)]
    g = {"_WD_CSS": lit("_WD_CSS"), "_WD_JS": lit("_WD_JS")}
    exec(compile(open(sys.argv[3], encoding="utf-8").read(), "wd2_dash_block", "exec"), g)
    assert g["_wd2_dash_ok"](), "sdrWd2-Anzeige fehlt in _WD_CSS/_WD_JS"
    assert s.count("# ===== sdrWd2:") == 1 and s.index("# ===== sdrWd2:") < s.index("# ===== sdrWd:"), "Block-Reihenfolge"
    print("dashboard.py sdrWd2: Watchdog-Zeilen einzeilig (CSS), Kopfzeile immer, Tooltip/aufklappbar (JS), kein POST")
elif a == "funk":
    s = open(sys.argv[2], encoding="utf-8", errors="replace").read()
    css = re.search(r'<style id="sdrwd-css">(.*?)</style>', s, re.S).group(1)
    js = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S).group(1)
    assert "/* sdrWd2: Watchdog-Zeilen einzeilig */" in css and "height:1.35em;white-space:nowrap" in css and "function fx(r,k,t)" in js, "/funk: Watchdog-Zeilen alt"
    print("/funk: Watchdog-Zeilen einzeilig (feste Höhe, Kurztext mit …, voller Text per Tipp)")
WDK2_EOF
EXPECT_AC="18e60b32ea5f0d61a7f7f992e500699693731f734370ed3e411781ca840c66dc"
cat > "$W/aircheck.py" << 'AIC_EOF'
"""sdrAir Pruefungen fuer apply-sdrair.sh (nur lesen, ausser 'cfg' = sdr_config.json Geraete-Register schreiben, atomar).
airspy SYSFS | fe WELLE | cfg DIR AIRSN FE | status DIR T0 | funk HTML | ui JSON | t2 JSON | port N"""
import json
import os
import re
import subprocess
import sys
import time

AIR = ("1d50", "60a1")
RTL = (("0bda", "2838"), ("0bda", "2832"))
S1, S2 = "19348831", "72055505"


def rd(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def norm(s):
    s = (s or "").strip().upper()
    for pre in ("AIRSPY SN:", "0X"):
        if s.startswith(pre):
            s = s[len(pre):].strip()
    return s


def newest(d, name, key):
    """sqlC: Stand liegt primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
    best = {}
    try:
        import sqlite3
        c = sqlite3.connect("file:%s?mode=ro" % os.path.join(d, "lagezentrum.db"), uri=True, timeout=10)
        try:
            r = c.execute("SELECT json FROM state WHERE key=?", (key,)).fetchone()
            best = json.loads(r[0]) if r else {}
        finally:
            c.close()
    except Exception:
        best = {}
    try:
        j = json.load(open(os.path.join(d, name), encoding="utf-8"))
        if float(j.get("t") or 0) > float(best.get("t") or 0) or not best:
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def scan(root):
    air, rtl = [], []
    for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        p = os.path.join(root, d)
        v, i = rd(os.path.join(p, "idVendor")).lower(), rd(os.path.join(p, "idProduct")).lower()
        if (v, i) == AIR:
            air.append((d, norm(rd(os.path.join(p, "serial")))))
        elif (v, i) in RTL:
            rtl.append((d, rd(os.path.join(p, "serial"))))
    return air, rtl


def main(a):
    m = a[0]
    if m == "airspy":
        air, rtl = scan(a[1])
        info = "RTL: %s" % (", ".join("%s SN %s" % x for x in rtl) or "keiner")
        if not air:
            print("kein Airspy (USB 1d50:60a1) gefunden · %s" % info); return 2
        if len(air) > 1:
            print("mehrere Airspy gefunden (%s) - Rolle 11D nicht eindeutig · %s" % (", ".join("%s SN %s" % x for x in air), info)); return 3
        sn = air[0][1]
        if not re.fullmatch(r"[0-9A-F]{16}", sn):
            print("Airspy-Seriennummer unlesbar (%r) · %s" % (sn, info)); return 4
        print(sn)
        print("Airspy SN %s an %s · %s" % (sn, air[0][0], info), file=sys.stderr)
        return 0
    if m == "fe":
        w = a[1]
        try:
            l = subprocess.run(["ldd", w], capture_output=True, text=True, timeout=20).stdout
        except Exception as e:
            print("ldd %s: %s" % (w, e)); return 1
        if "libairspy" in l:
            print("airspy"); return 0
        if "libSoapySDR" in l:
            try:
                s = subprocess.run(["SoapySDRUtil", "--info"], capture_output=True, text=True, timeout=30)
                t = (s.stdout + s.stderr).lower()
            except Exception as e:
                print("welle-cli mit SoapySDR, aber SoapySDRUtil fehlt (%s) - Airspy-Modul nicht pruefbar" % e); return 1
            if "airspy" in t:
                print("soapy"); return 0
            print("welle-cli mit SoapySDR, aber kein SoapySDR-Airspy-Modul (soapysdr-module-airspy)"); return 1
        print("welle-cli ohne Airspy-Unterstuetzung (weder libairspy noch SoapySDR gelinkt)"); return 1
    if m == "cfg":
        d, sn, fe = a[1], a[2], a[3]
        assert re.fullmatch(r"[0-9A-F]{16}", sn) and fe in ("airspy", "soapy")
        p = os.path.join(d, "sdr_config.json")
        c = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
        devs = [{"name": "Airspy R2", "kind": "airspy", "usb": "1d50:60a1", "serial": sn, "role": "11D"},
                {"name": "Stick 1", "kind": "rtl", "usb": "0bda:2838", "serial": S1, "role": "5C", "ppm_sfx": ""},
                {"name": "Stick 2", "kind": "rtl", "usb": "0bda:2838", "serial": S2, "role": "hobby", "ppm_sfx": "2"}]
        old = [{k: x.get(k) for k in ("name", "kind", "usb", "serial", "role", "ppm_sfx") if k in x} for x in c.get("devs") or [] if isinstance(x, dict)]
        keep = [x for x in old if x.get("serial") not in (sn, S1, S2)]       # spaeter eingetragene Geraete (3. Stick) bleiben
        new = devs + keep
        if c.get("devs_on") is True and c.get("air_fe") == fe and old == new:
            print("unveraendert (devs_on, %d Geraete, air_fe %s)" % (len(new), fe)); return 0
        c.update(devs_on=True, devs=new, air_fe=fe)
        t = p + ".sdrair-tmp"
        with open(t, "w", encoding="utf-8") as f:
            json.dump(c, f, ensure_ascii=False, indent=1)
            f.flush(); os.fsync(f.fileno())
        if os.path.exists(p):
            st = os.stat(p)
            try:
                os.chown(t, st.st_uid, st.st_gid)
            except OSError:
                pass
            os.chmod(t, st.st_mode & 0o777)
        os.replace(t, p)
        print("geschrieben: devs_on, Airspy R2 %s = 11D, Stick 1 %s = 5C, Stick 2 %s = Hobby%s, air_fe %s" % (sn, S1, S2, (", %d weitere behalten" % len(keep)) if keep else "", fe)); return 0
    if m == "status":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        if not st:
            print("kein SDR-Status (DB/JSON)"); return 1
        if float(st.get("t") or 0) < t0:
            print("Status noch alt"); return 1
        du = st.get("dual") or {}
        if not du.get("reg"):
            print("Status ohne Geraete-Register (dual.reg)"); return 1
        dv = {x.get("role"): x for x in st.get("devs") or [] if isinstance(x, dict)}
        a1 = dv.get("11D") or {}
        dev = st.get("dev") or {}
        dm = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {}).get("demod") or {}
        m11 = dm.get("sn") == a1.get("serial") and float(dm.get("t") or 0) >= t0          # 11D-Messung nach dem Neustart vom Airspy
        ran = m11 or str(st.get("active") or "").startswith("dab")
        if not a1.get("present") or a1.get("state") != "aktiv" or not ran:
            print("Airspy 11D nicht aktiv (angesteckt %s, %s, jetzt %s, 11D-Messung %s SN %s, Fehler %s)" % (a1.get("present"), a1.get("state"), st.get("active"), dm.get("t"), dm.get("sn"), str(st.get("err") or st.get("pin_err") or "")[:120])); return 1
        cpu = (dev.get("cpu") or {})
        print("11D vom Airspy: %s · Geraete: %s · Airspy %s · welle-cli CPU %s" % ("Sync %s, SNR %s, %s" % (dm.get("sync"), dm.get("snr"), dm.get("gain_db")) if m11 else "laeuft (noch keine Messung)",", ".join("%s=%s(%s)" % (x.get("name"), x.get("role") or "ohne Rolle", x.get("state")) for x in st.get("devs") or []),
                                                          dev.get("fe"), ("%s %% (5 min Mittel %s %%)" % (cpu.get("pct"), cpu.get("avg"))) if cpu else "noch nicht gemessen"))
        return 0
    if m == "funk":
        h = rd(a[1])
        for k in ("var AIR=", "erkannt, ohne Rolle", "s2s.style.display=(D2&&D2.air)"):
            if k not in h:
                print("/funk ohne sdrAir-Anzeige (%s)" % k); return 1
        print("/funk mit sdrAir-Anzeige (Geraetenamen, ohne Rolle, kein Uebernahme-Knopf)"); return 0
    if m == "ui":
        u = (json.load(open(a[1], encoding="utf-8")).get("dual") or {})
        if not u.get("reg") or "Airspy" not in str(u.get("label1")):
            print("/api/sdr/ui ohne Geraete-Register (%s)" % str(u)[:160]); return 1
        print("/api/sdr/ui: %s · %s" % (u.get("label1"), u.get("mode"))); return 0
    if m == "t2":
        t = json.load(open(a[1], encoding="utf-8"))
        if not t.get("air") or (t.get("takeover") or {}).get("on"):
            print("/api/t2/status: air=%s Uebernahme an=%s" % (t.get("air"), (t.get("takeover") or {}).get("on"))); return 1
        print("/api/t2/status: Geraete-Register an, Uebernahme aus (%s)" % ((t.get("takeover") or {}).get("off_by") or "war aus")); return 0
    if m == "port":
        n = int(a[1])
        s = rd("/proc/net/tcp") + "\n" + rd("/proc/net/tcp6")
        if any(len(x.split()) > 3 and x.split()[1].endswith(":%04X" % n) and x.split()[3] == "0A" for x in s.splitlines()):
            print("Port %d lauscht" % n); return 0
        print("Port %d lauscht nicht" % n); return 1
    print(__doc__); return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AIC_EOF
PF="$W/patch-fu.py"; ED="$W/wd2_edits.py"; BSD="$W/wd2_sdr_block.py"; BSM="$W/wd2_sm_block.py"; BDA="$W/wd2_dash_block.py"
AE="$W/air_edits.py"; ASD="$W/air_sdr_block.py"; ASM="$W/air_sm_block.py"; ADA="$W/air_dash_block.py"; HL="$W/prepper-sdr-wdhelper"
SG="$W/guard_wd2.py"; AG="$W/guard_air.py"; CK="$W/sqlccheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"; AC="$W/aircheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_ED $ED" "$EXPECT_BSD $BSD" "$EXPECT_BSM $BSM" "$EXPECT_BDA $BDA" "$EXPECT_AE $AE" "$EXPECT_ASD $ASD" "$EXPECT_ASM $ASM" "$EXPECT_ADA $ADA" "$EXPECT_HL $HL" \
         "$EXPECT_G $SG" "$EXPECT_AG $AG" "$EXPECT_CK $CK" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2" "$EXPECT_AC $AC"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
chmod 0755 "$HL"
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ "$1" == "$4" ]] && echo "bekannt ($5)" || echo "UNBEKANNT"; }; }
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sdrWd" "$KNOWN_SDR16N" "sdrAir schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sdrWd" "$KNOWN_SM16N" "sdrAir schon drin"))"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sysBoot" "$KNOWN_D16N" "sdrAir schon drin"))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
for x in "prepper_sdr.py $SDR16 $KNOWN_SDR16 $KNOWN_SDR16N sdrWd" "sdr_manager.py $SM16 $KNOWN_SM16 $KNOWN_SM16N sdrWd" "dashboard.py $D16 $KNOWN_D16 $KNOWN_D16N sysBoot"; do set -- $x
  [[ "$2" == "$3" || "$2" == "$4" ]] || bad="$bad $1 (sha16 $2, erwartet $3 = Stand nach $5 oder $4 = sdrAir schon drin);"
done
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      sdrAir passt nur auf prepper_sdr.py/sdr_manager.py nach sdrWd (18.10.) und dashboard.py nach sysBoot - nichts geaendert."
  echo "      Fehlt sysBoot noch: zuerst apply-sysboot.sh. Sonst bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = sdrWd (prepper_sdr.py, sdr_manager.py) + sysBoot (dashboard.py) bzw. sdrAir schon drin (alle drei sha16 bekannt)"
grep -q '# ===== sdrWd:' "$M" || { echo "STOP: sdrWd fehlt in prepper_sdr.py - nichts geaendert"; exit 1; }
grep -q '# ===== sysBoot' "$F" || { echo "STOP: sysBoot fehlt in dashboard.py - nichts geaendert"; exit 1; }
[[ -x "$HDST" ]] || { echo "STOP: Hilfsprogramm $HDST fehlt (sdrWd nicht vollstaendig) - nichts geaendert"; exit 1; }
HL16=$(s16 "$HDST")
echo "Hilfsprogramm $HDST sha16 $HL16 ($(kn "$HL16" "$KNOWN_HL16" "sdrWd" "$KNOWN_HL16N" "sdrAir schon drin")) -> wird $KNOWN_HL16N (zusaetzlich usb-reset-air)"
[[ "$HL16" == "$KNOWN_HL16" || "$HL16" == "$KNOWN_HL16N" ]] || { echo "STOP: Hilfsprogramm unbekannt ($HL16) - nichts geaendert"; exit 1; }
for k in "sdr prepper_sdr $M $BSD $ASD $KNOWN_SDR16N" "sm sdr_manager $SMF $BSM $ASM $KNOWN_SM16N" "dash dashboard $F $BDA $ADA $KNOWN_D16N"; do set -- $k
  if [[ "$(s16 "$3")" == "$6" ]]; then cp "$3" "$W/mid/$2.py"; cp "$3" "$W/work/$2.py"; echo "$2.py: sdrAir schon drin" > "$W/q_$1.log"; continue; fi
  python3 "$PF" sdrWd2 "$1" "$3" "$W/mid/$2.py" "$4" "$ED" > "$W/p_$1.log" || { cat "$W/p_$1.log"; echo "STOP: $2.py sdrWd2-Stufe passt nicht - nichts geaendert"; exit 1; }
  python3 "$PF" sdrAir "$1" "$W/mid/$2.py" "$W/work/$2.py" "$5" "$AE" > "$W/q_$1.log" || { cat "$W/q_$1.log"; echo "STOP: $2.py sdrAir-Stufe passt nicht - nichts geaendert"; exit 1; }
done
NP16=$(s16 "$W/work/prepper_sdr.py"); NS16=$(s16 "$W/work/sdr_manager.py"); ND16=$(s16 "$W/work/dashboard.py")
for x in "prepper_sdr.py $NP16 $KNOWN_SDR16N" "sdr_manager.py $NS16 $KNOWN_SM16N" "dashboard.py $ND16 $KNOWN_D16N"; do set -- $x
  [[ "$2" == "$3" ]] || { echo "STOP: Ergebnis $1 sha16 $2 statt $3 - nichts geaendert"; exit 1; }
done
echo "OK Ergebnis wie erwartet: prepper_sdr.py $NP16, sdr_manager.py $NS16, dashboard.py $ND16"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
# ---------- 1b) Geraete: Airspy erkennen, welle-cli mit Airspy pruefen ----------
AIRSN=$(python3 "$AC" airspy "$SYSUSB" 2>"$W/air.log") || { echo "$AIRSN"; echo "STOP: Airspy nicht eindeutig - nichts geaendert"; exit 1; }
echo "OK $(cat "$W/air.log")"
[[ "$AIRSN" =~ ^[0-9A-F]{16}$ ]] || { echo "STOP: Airspy-Seriennummer $AIRSN - nichts geaendert"; exit 1; }
WELLE=$(python3 -c "import json,sys;c=json.load(open(sys.argv[1]));w=c.get('welle');print(w if isinstance(w,str) and w.startswith('/') else '')" "$CF" 2>/dev/null || true)
[[ -n "$WELLE" ]] || WELLE=$(command -v welle-cli || true)
[[ -n "$WELLE" && -x "$WELLE" ]] || { echo "STOP: welle-cli nicht gefunden - nichts geaendert"; exit 1; }
FE=$(python3 "$AC" fe "$WELLE") || { echo "$FE"; echo "STOP: $WELLE kann den Airspy nicht ansprechen - nichts geaendert (welle-cli mit libairspy bauen oder soapysdr-module-airspy installieren)"; exit 1; }
echo "OK $WELLE spricht den Airspy an: $([[ "$FE" == airspy ]] && echo "-F airspy (libairspy)" || echo "-F soapysdr driver=airspy (SoapySDR-Modul)")"
SU=$(systemctl show -p User --value prepper-sdr 2>/dev/null || true); [[ -z "$SU" ]] && SU=root
if ! [[ "$SU" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "STOP: Benutzer von prepper-sdr unklar ($SU) - nichts geaendert"; exit 1; fi
HX='[0-9A-F]'; HX16="$HX$HX$HX$HX$HX$HX$HX$HX$HX$HX$HX$HX$HX$HX$HX$HX"
RULE="$SU ALL=(root) NOPASSWD: $HDST check, $HDST usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], $HDST usb-reset-air $HX16, $HDST reboot"
if [[ "$SU" == root ]]; then echo "prepper-sdr laeuft als root: Hilfsprogramm direkt, keine sudoers-Regel noetig"; else echo "prepper-sdr laeuft als $SU: Hilfsprogramm ueber sudo -n, sudoers-Regel genau dafuer"; fi
asu() { if [[ "$(id -un)" == "$SU" ]]; then setsid -w "$@" < /dev/null; else sudo -n -u "$SU" setsid -w "$@" < /dev/null; fi; }
WD_SUDO_ERR=""; WD_SUDO_OK=""
wd_sudo_verify() {
  local c out rc
  for c in "check" "usb-reset 19348831" "usb-reset-air $AIRSN" "reboot"; do
    rc=0; if [[ "$(id -un)" == "$SU" ]]; then sudo -n -l "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?; else sudo -n -l -U "$SU" "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?; fi
    [[ "$rc" == 0 ]] || { WD_SUDO_ERR="sudo -l: $HDST $c fuer $SU nicht erlaubt (rc $rc: $(head -c 200 "$W/sl.log" | tr '\n' ' '))"; return 1; }
  done
  rc=0; out=$(asu sudo -n "$HDST" check 2>&1) || rc=$?
  [[ "$rc" == 0 && "$out" == *"bereit (uid 0)"* ]] || { WD_SUDO_ERR="$SU kann $HDST check nicht ohne Passwort und ohne Terminal ausfuehren (rc $rc: $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200))"; return 1; }
  rc=0; asu sudo -n true > /dev/null 2>&1 || rc=$?
  if [[ "$rc" == 0 ]]; then
    WD_SUDO_OK="$HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot ohne Passwort, Aufruf ohne Terminal wie im Dienst geprueft (Hinweis: $SU hat schon allgemeines sudo ohne Passwort - Gegenprobe entfaellt)"; return 0
  fi
  for c in "selftest" "usb-reset 1234" "usb-reset 19348831 x" "usb-reset ../x" "usb-reset-air 1234" "usb-reset-air ${AIRSN,,}" "usb-reset-air $AIRSN x" "usb-reset-air ../x"; do
    rc=0; out=$(asu sudo -n "$HDST" $c 2>&1) || rc=$?
    [[ "$rc" != 0 && "$out" == sudo:* ]] || { WD_SUDO_ERR="sudo erlaubt zu viel ohne Passwort: $HDST $c (rc $rc)"; return 1; }
  done
  WD_SUDO_OK="nur $HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex gross> | reboot ohne Passwort, Aufruf ohne Terminal wie im Dienst geprueft, andere Aufrufe verlangen Passwort"
}
wd_sudo_diag() {
  echo "DIAG $(sudo -V 2>/dev/null | head -1); Skript als $(id -un), Dienst als $SU (Gruppen $(id -nG "$SU" 2>/dev/null | tr ' ' ','))"
  echo "DIAG Hilfsprogramm: $(ls -l "$HDST" 2>&1 | cut -c1-160)"
  echo "DIAG /etc/sudoers.d: $(sudo -n ls -1 /etc/sudoers.d 2>&1 | tr '\n' ' ' | cut -c1-400)"
  sudo -n -l -U "$SU" 2>&1 | sed -n '/may run/,$p' | head -14 | cut -c1-200 | sed 's/^/DIAG sudo -l: /' || true
}
# ---------- 2) Trockenlauf ----------
for k in "sdr prepper_sdr $ASD" "sm sdr_manager $ASM" "dash dashboard $ADA"; do set -- $k
  python3 "$PF" sdrAir "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$AE" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/work/dashboard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
  "$py" -W error -c "import sys; compile(open(sys.argv[1]).read(), 'wdhelper', 'exec')" "$HL" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: Hilfsprogramm ($py) - nichts geaendert"; exit 1; }
done
"$SPY" -I "$HL" selftest > "$W/hlt.log" 2>&1 || { cat "$W/hlt.log"; echo "STOP: Hilfsprogramm Selbsttest - nichts geaendert"; exit 1; }
echo "OK Hilfsprogramm (neu) Selbsttest: $(tail -1 "$W/hlt.log" | cut -c1-200)"
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$CF" ]] && cp "$CF" "$W/sbx/sdr_config.json"
[[ -f "$LG" ]] && cp "$LG" "$W/sbx/"
cp "$DBF" "$MR" "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrair-selftest timeout 300 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok" "sdr_manager selftest sdrWd ok" "sdr_manager selftest sdrWd2 ok" "sdr_manager selftest sdrAir ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrair-selftest timeout 420 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok" "selftest sdrWd2 ok" "selftest sdrAir ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum mit Airspy + 3 Sticks, Fake-Hilfsprogramm; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet)"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest sdrAir ok' "$W/sdrt.log" | tail -1 | cut -c1-420)"
  echo "   $(grep -F 'sdr_manager selftest sdrAir ok' "$W/smt.log" | tail -1 | cut -c1-220)"
done
if [[ "$SDR16" == "$KNOWN_SDR16N" && "$SM16" == "$KNOWN_SM16N" && "$D16" == "$KNOWN_D16N" ]]; then
  echo "OK sdrAir schon drin - Guard-Rueckbau gegen Basis entfaellt (Inhalt = gepruefter Zielstand, sha16)"
else
  python3 "$SG" "$ED" sdr "$M" "$W/mid/prepper_sdr.py" "$BSD" sm "$SMF" "$W/mid/sdr_manager.py" "$BSM" dash "$F" "$W/mid/dashboard.py" "$BDA" > "$W/g.log" 2>&1 \
    || { cat "$W/g.log"; echo "STOP: AST-Guard sdrWd2 - nichts geaendert"; exit 1; }
  echo "$(cat "$W/g.log")"
fi
python3 "$AG" "$AE" sdr "$W/mid/prepper_sdr.py" "$W/work/prepper_sdr.py" "$ASD" sm "$W/mid/sdr_manager.py" "$W/work/sdr_manager.py" "$ASM" dash "$W/mid/dashboard.py" "$W/work/dashboard.py" "$ADA" \
  || { echo "STOP: AST-Guard sdrAir - nichts geaendert"; exit 1; }
python3 "$WC2" dashok "$W/work/dashboard.py" "$BDA" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; echo "STOP: dashboard.py sdrWd2-Anzeige (CSS/JS) - nichts geaendert"; exit 1; }
if command -v node >/dev/null 2>&1; then
  python3 - "$W/work/dashboard.py" "$W" << 'JSPY' || { echo "STOP: JavaScript-Syntax (node --check) - nichts geaendert"; exit 1; }
import ast, re, subprocess, sys
want = {"_FU_JS", "_SD_JS"}
n_ok = 0
for n in ast.parse(open(sys.argv[1], encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in want and isinstance(n.value, ast.Constant):
        v = re.sub(r"<style.*?</style>", "", n.value.value, flags=re.S)
        v = re.sub(r"</?script[^>]*>", "", v)
        f = "%s/%s.js" % (sys.argv[2], n.targets[0].id)
        open(f, "w", encoding="utf-8").write(v)
        if not v.strip() or subprocess.run(["node", "--check", f]).returncode:
            raise SystemExit(1)
        n_ok += 1
if n_ok != len(want):
    raise SystemExit("JS-Bloecke %d/%d" % (n_ok, len(want)))
JSPY
  echo "OK JavaScript (Funk-Lage, Empfaenger) syntaktisch geprueft (node)"
fi
if [[ "$SU" != root ]]; then
  printf '# sdrWd/sdrAir: prepper-sdr (%s) darf genau diese vier Aufrufe des Hilfsprogramms als root, sonst nichts\n%s\n' "$SU" "$RULE" > "$W/sudoers"
  python3 "$WC" sudoers "$W/sudoers" "$SU" "$HDST" > "$W/wc.log" 2>&1 || { cat "$W/wc.log"; echo "STOP: sudoers-Regel falsch - nichts geaendert"; exit 1; }
  visudo -cf "$W/sudoers" > "$W/vis.log" 2>&1 || { cat "$W/vis.log"; echo "STOP: visudo -cf lehnt die Regel ab - nichts geaendert"; exit 1; }
  echo "OK sudoers-Regel geprueft (visudo -cf): $(cat "$W/wc.log")"
fi
cp "$CF" "$W/cfg.json" 2>/dev/null || echo '{}' > "$W/cfg.json"
mkdir -p "$W/cfgt" && cp "$W/cfg.json" "$W/cfgt/sdr_config.json"
python3 "$AC" cfg "$W/cfgt" "$AIRSN" "$FE" > "$W/cfg.log" || { cat "$W/cfg.log"; echo "STOP: sdr_config.json Geraete-Register - nichts geaendert"; exit 1; }
echo "OK sdr_config.json (Probe): $(cat "$W/cfg.log")"
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
echo "Watchdog vorher: $(python3 "$WC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-300)"
[[ -f "$DASH_DIR/sdr_takeover.json" ]] && echo "Uebernahme vorher: $(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print('an seit %s (%s)'%(d.get('since'),d.get('src')) if d.get('on') else 'aus')" "$DASH_DIR/sdr_takeover.json" 2>&1 | cut -c1-160)"
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
ALL=("$M" "$SMF" "$F")
perm_ok() { [[ "$(stat -c '%U:%G %a' "$1" 2>/dev/null)" == "root:root $3" ]]; }
H_SAME=0; cmp -s "$HL" "$HDST" 2>/dev/null && perm_ok "$HDST" x 755 && H_SAME=1
S_SAME=1; if [[ "$SU" != root ]]; then sudo -v; S_SAME=0; sudo -n cmp -s "$W/sudoers" "$SDST" 2>/dev/null && S_SAME=1; fi
C_SAME=0; grep -q '^unveraendert' "$W/cfg.log" && C_SAME=1
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/dashboard.py" "$F" && [[ "$H_SAME" == 1 && "$S_SAME" == 1 && "$C_SAME" == 1 ]]; then
  echo "OK sdrAir schon installiert (3 Dateien, Hilfsprogramm, sudoers, sdr_config.json) - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  H_OLD=0; [[ -f "$HDST" ]] && { cp -a "$HDST" "$W/helper.old"; H_OLD=1; }
  S_OLD=0; [[ "$SU" != root ]] && sudo -n test -f "$SDST" 2>/dev/null && { sudo -n cat "$SDST" > "$W/sudoers.old"; S_OLD=1; }
  rb() {
    echo "ROLLBACK: $1"
    for u in prepper-sdr prepper-dashboard; do sudo journalctl -u "$u" --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrAir|sdrWd|Traceback" | tail -4 | cut -c1-200 || true; done
    for x in "${ALL[@]}" "$CF" "$DASH_DIR/sdr_takeover.json"; do [[ -f "$x.bak-sdrair-$TS" ]] && cp -a "$x.bak-sdrair-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    if [[ "$H_OLD" == 1 ]]; then sudo install -o root -g root -m 0755 "$W/helper.old" "$HDST" || true; fi
    if [[ "$SU" != root ]]; then
      if [[ "$S_OLD" == 1 ]]; then sudo install -o root -g root -m 0440 "$W/sudoers.old" "$SDST" || true; else sudo rm -f "$SDST" || true; fi
      sudo rm -f "$SDST.tmp" || true
    fi
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}" "$CF"; do [[ -f "$x.bak-sdrair-$TS" ]] || continue; cmp -s "$x" "$x.bak-sdrair-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Hilfsprogramm $HDST: $(cmp -s "$HDST" "$W/helper.old" && echo "alter Stand ($(s16 "$HDST"))" || echo "WARNUNG ungleich alt"); sudoers $SDST: $([[ "$SU" == root ]] && echo "nicht noetig" || (sudo -n cmp -s "$SDST" "$W/sudoers.old" 2>/dev/null && echo "alter Stand" || echo "WARNUNG ungleich alt"))"
    echo "  Sicherung lagezentrum.db von vorher: $LZ.bak-sdrair-$TS (nicht zurueckgespielt; sdrAir aendert nur Zustand sdr_wd + Ereignisse)"
    echo "alter Stand wieder aktiv (Uebernahme-Datei wie vorher): prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$CF" "$DASH_DIR/sdr_takeover.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-sdrair-$TS"
    { ls -1t "$x.bak-sdrair-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sdrair-$TS" \
      || { rm -f "$LZ.bak-sdrair-$TS"; for x in "${ALL[@]}" "$CF" "$DASH_DIR/sdr_takeover.json"; do rm -f "$x.bak-sdrair-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sdrair-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  [[ -f "$DASH_DIR/sdr_wd.json" ]] && cp -a "$DASH_DIR/sdr_wd.json" "$W/sdr_wd.json.vorher"
  T0=$(date +%s)
  if [[ "$SU" != root && "$S_SAME" != 1 ]]; then
    sudo install -o root -g root -m 0440 "$W/sudoers" "$SDST.tmp" && sudo visudo -cf "$SDST.tmp" > "$W/vis.log" 2>&1 && sudo mv -f "$SDST.tmp" "$SDST" && sudo visudo -c > "$W/vis2.log" 2>&1 \
      || { cat "$W/vis.log" "$W/vis2.log" 2>/dev/null; rb "sudoers-Regel"; exit 1; }
    perm_ok "$SDST" x 440 || { rb "sudoers-Regel Rechte $(stat -c '%U:%G %a' "$SDST" 2>/dev/null)"; exit 1; }
    echo "OK sudoers-Regel $SDST eingespielt (0440 root:root), visudo -c gueltig"
  fi
  if [[ "$H_SAME" != 1 ]]; then
    sudo install -o root -g root -m 0755 "$HL" "$HDST.new" && sudo mv -f "$HDST.new" "$HDST" || { rb "Hilfsprogramm installieren"; exit 1; }
    perm_ok "$HDST" x 755 && cmp -s "$HL" "$HDST" || { rb "Hilfsprogramm Rechte/Inhalt"; exit 1; }
    "$SPY" -I "$HDST" selftest > "$W/hlt.log" 2>&1 || { cat "$W/hlt.log"; rb "Hilfsprogramm Selbsttest"; exit 1; }
    echo "OK Hilfsprogramm eingespielt ($(s16 "$HDST")): $(tail -1 "$W/hlt.log" | cut -c1-140)"
  fi
  if [[ "$SU" != root ]]; then
    wd_sudo_verify || { echo "FEHLER sudo-Pruefung: $WD_SUDO_ERR"; wd_sudo_diag; rb "sudo-Regel wirkt nicht wie erwartet ($WD_SUDO_ERR)"; exit 1; }
    echo "OK sudo-Regel fuer $SU: $WD_SUDO_OK"
  fi
  if [[ "$C_SAME" != 1 ]]; then
    python3 "$AC" cfg "$DASH_DIR" "$AIRSN" "$FE" > "$W/cfg.log" 2>&1 || { cat "$W/cfg.log"; rb "sdr_config.json schreiben"; exit 1; }
    echo "OK sdr_config.json: $(cat "$W/cfg.log")"
  fi
  for k in "prepper_sdr $M" "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sdrair-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status mit Airspy auf 11D (max 240 s; Watchdog beobachtet die ersten 5 min nur; sendet nichts) ..."
  sudo systemctl restart prepper-sdr.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$AC" status "$DASH_DIR" "$T0" > "$W/ast.log" 2>&1 && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { cat "$W/ast.log"; rb "prepper-sdr: Airspy 11D laeuft nicht ($(head -c 200 "$W/ast.log"))"; exit 1; }
  echo "OK $(cat "$W/ast.log" | cut -c1-400)"
  pok=0; for i in $(seq 1 120); do python3 "$AC" port 7979 > "$W/port.log" 2>&1 && { pok=1; break; }; sleep 1; done
  [[ "$pok" == 1 ]] && echo "OK welle-cli (Airspy) $(cat "$W/port.log") (11D-Datenweg wie bisher)" || { rb "Port 7979 (welle-cli Airspy) lauscht nicht"; exit 1; }
  echo "Neustart prepper-dashboard (laedt dashboard.py + sdr_manager.py neu, beendet alte Uebernahme einmal) - warte auf HTTP (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist /karte /api/sdr/wd /api/sdr/ui /api/t2/status /api/t4/status /api/t4/tii /api/br24; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
python3 "$FC" funk "$W/funk.html" "$W" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/funk ohne funkUI"; }
python3 "$WC" funk "$W/funk.html" "$W" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne Daten-Watchdog / Empfaenger-Zeilen alt"; }
python3 "$WC2" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk Watchdog-Zeilen nicht einzeilig (sdrWd2)"; }
python3 "$AC" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne sdrAir-Anzeige"; }
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$WC" pi "$W/pi.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/pi Watchdog-Kachel"; }
uok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/ui" -o "$W/ui.json" || true; python3 "$AC" ui "$W/ui.json" > "$W/wc.log" 2>&1 && { uok=1; break; }; sleep 6; done
[[ "$uok" == 1 ]] && echo "OK $(cat "$W/wc.log" | cut -c1-400)" || { cat "$W/wc.log"; rbx "/api/sdr/ui ohne Geraete-Register"; }
tok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/t2/status" -o "$W/t2.json" || true; python3 "$AC" t2 "$W/t2.json" > "$W/wc.log" 2>&1 && { tok=1; break; }; sleep 6; done
[[ "$tok" == 1 ]] && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "Uebernahme nicht beendet / Register nicht aktiv"; }
wok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/wd" -o "$W/wd.json" || true; python3 "$WC2" api "$W/wd.json" > "$W/wc.log" 2>&1 && { wok=1; break; }; sleep 6; done
[[ "$wok" == 1 ]] && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/wd ohne sdrWd2-Felder"; }
"${CURL[@]}" "$B/api/t4/tii" -o "$W/tii.json" || true
python3 "$WC" tii "$W/tii.json" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t4/tii Karte"; }
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JS=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrAir: Geraete-Register an" | tail -2 || true)
if [[ -n "$JS" ]]; then echo "OK Journal prepper-sdr: $(echo "$JS" | tail -1 | cut -c1-320)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "prepper-sdr meldet sdrAir nicht (Journal)"; fi
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(sdrAir|sdrWd|funkUI|sqlC|sysBoot) (aktiv|FEHLER)|sdrAir Anzeige" | tail -12 || true)
if [[ "$JD" == *"FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2)"; fi
if [[ "$JD" == *"sdrAir aktiv"* ]]; then echo "OK Journal Dashboard: sdrAir aktiv (Anzeige-Selbsttest ok)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet sdrAir nicht (Journal)"; fi
[[ "$JD" == *"funkUI aktiv"* || "$RESTARTED" == 0 ]] && echo "OK Journal Dashboard: funkUI weiter aktiv" || rbx "Dashboard meldet funkUI nicht mehr"
E1=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|^sdrAir [A-Za-z ]*:|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"
E2=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrWd FEHLER|funkUI FEHLER|sdr_manager sdrWd|sdr_manager sdrAir [A-Za-z_ -]+:|sdrAir Anzeige(:| FEHLER)" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"
python3 "$AC" status "$DASH_DIR" 0 > "$W/ast.log" 2>&1 && echo "Geraete nachher: $(cut -c1-400 "$W/ast.log")" || echo "HINWEIS Geraete nachher: $(cut -c1-300 "$W/ast.log")"
echo "Watchdog nachher: $(python3 "$WC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-360)"
for x in "$DBF:$DB16" "$MR:$MR16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
echo "OK guards sdrAir(sdr)=$(grep -c '# ===== sdrAir:' "$M" || true) sdrAir(sdr_manager)=$(grep -c '# ===== sdrAir:' "$SMF" || true) sdrAir(dash)=$(grep -c '# ===== sdrAir:' "$F" || true) sdrWd2(sdr)=$(grep -c '# ===== sdrWd2:' "$M" || true) sdrWd2(sm)=$(grep -c '# ===== sdrWd2:' "$SMF" || true) sdrWd2(dash)=$(grep -c '# ===== sdrWd2:' "$F" || true) sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sysBoot(dash)=$(grep -c '# ===== sysBoot' "$F" || true) funkUI(dash)=$(grep -c '# ===== funkUI:' "$F" || true)"
echo "Hilfsprogramm $HDST: sha16 $(s16 "$HDST"), $(stat -c '%U:%G %a' "$HDST") · sudoers $SDST: $([[ "$SU" == root ]] && echo "nicht noetig (prepper-sdr als root)" || (sudo -n test -f "$SDST" && echo "$RULE" || echo fehlt))"
[[ -f "$M.bak-sdrair-$TS" ]] && echo "Backups: *.bak-sdrair-$TS (prepper_sdr.py, sdr_manager.py, dashboard.py, sdr_config.json, sdr_takeover.json, lagezentrum.db), behalten: letzte $KEEP_LAST; altes Hilfsprogramm: $W/helper.old"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: die .bak-sdrair-$TS (prepper_sdr.py, sdr_manager.py, dashboard.py, sdr_config.json, sdr_takeover.json) zurueckkopieren, dann sudo systemctl restart prepper-sdr prepper-dashboard"
echo "Nur Register aus (ohne Rueckweg): in sdr_config.json devs_on auf false, dann sudo systemctl restart prepper-sdr (alte Rollen Stick 1 11D / Stick 2 Hobby)"
echo "COMMIT $COMMIT_ARG sdrair=1 fertig"
