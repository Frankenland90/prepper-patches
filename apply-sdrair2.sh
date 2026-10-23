#!/bin/bash
set -euo pipefail
# sdrAir2: Nachbesserung zu sdrAir (live seit 23.10. 23:07). Aendert prepper_sdr.py, sdr_manager.py und dashboard.py (nur Anzeige-Namen); Hilfsprogramm, sudoers, sdr_config.json bleiben.
#  - Hobby-Geraet (Stick 2) nur beobachten: kein Neustart, keine USB-Neuverbindung, kein Pi-Neustart; RDS ueber alle Sender der Rotation (ein leerer Sender ist kein Vorfall,
#    erst 3 leere Fenster in Folge = Hinweis), irgendein RDS-Empfang schliesst; eigene Zeile, nicht in der Gesamtstufe. Offener alter Hobby-Vorfall (RDS Bayern 1) wird beim Start geschlossen.
#  - Geraetenamen statt Platznummern (gespeicherte Platznummern in sdr_wd.json korrigiert; Startmeldung, Rollen-/Kalibrier-/Freigabe-Meldungen, Zusammenfassung).
#  - Zusammenfassung ehrlich: noch nicht gepruefte Geraete "wird geprüft" statt "alle Sticks mit echtem Empfang"; Startzeile sdrTeil2 nennt die Register-Rollen (keine Alarm-Uebernahme mehr).
#  - Apply prueft 11D-Sync vom Airspy nach dem Neustart (Empfang + Messung mit Airspy-Seriennummer), sonst Rueckbau.
#  - CPU ehrlich je Kern (plus Anteil am ganzen Pi), Warnung erst ueber 120 % eines Kerns im 10-min-Mittel.
#  - SoapySDR fuer den Airspy nur per sdr_config.json air_fe soapy (Standard bleibt -F airspy): Modul wird erkannt, eigene Stufen-Tabelle (Linearitaetsstufe -> Soapy-Gesamtverstaerkung,
#    16 -> 28), Rueckfall auf -F airspy nach 3 Runden ohne 11D-Sync oder ohne Modul. Gain-Leiter/-Logik unveraendert.
#  - Hobby-Stick: alle 6 h kurze 10C-Pruefung (welle-cli nur am Hobby-Stick, Sync/SNR/TII), letzter 10C-Sync dauerhaft in broadcast_state p10c (fuer spaeteres dabSql).
#  - RTL-Index nach jedem Start gegen die Seriennummer geprueft (neuer/umgesteckter Stick); doppelte Seriennummer = Stick nicht benutzt, Watchdog wartet; Werks-SN (00000001) nie mit Rolle.
#  - Anzeige-Namen 'Name · Rolle' aus sdr_config.json devs auf allen Seiten (Airspy R2 · 11D, Stick 1 · 5C, Stick 2 · Hobby, Stick 3 · ohne Rolle); Pruefung der Seiten auf alte Platz-Namen.
#  - sudo-Pruefung ohne gemerktes Passwort (sudo -k): nur die Regel zaehlt; "allgemeines sudo ohne Passwort" nur, wenn die Liste NOPASSWD: ALL zeigt.
# Basis streng (sha16): sdrAir-Stand oder sdrAir2 schon drin. Sonst Abbruch ohne Aenderung. Neustart prepper-sdr + prepper-dashboard (laedt sdr_manager.py). Sendet nichts.
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
WDJ="$DASH_DIR/sdr_wd.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
HDST="/usr/local/sbin/prepper-sdr-wdhelper"
SYSUSB="${SDR_SYSFS_USB:-/sys/bus/usb/devices}"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdrair2-apply
KEEP_LAST=3
KNOWN_D16="169cd40bba5aba29"     # dashboard.py nach sdrAir
KNOWN_D16N="b0712eafe3d2235d"     # dashboard.py nach sdrAir2 (Ziel)
KNOWN_SM16="3705c2249f8a3d60"    # sdr_manager.py nach sdrAir
KNOWN_SM16N="679fde6003d22ff7"    # sdr_manager.py nach sdrAir2 (Ziel)
KNOWN_SDR16="a27db4d1f9c4b7fc"   # prepper_sdr.py nach sdrAir
KNOWN_SDR16N="b139eaf50abf4d36"   # prepper_sdr.py nach sdrAir2 (Ziel)
KNOWN_HL16="01c19375256b05bc"    # Hilfsprogramm nach sdrAir (bleibt unveraendert)
KNOWN_DB16="431077d36822a090"    # database.py (bleibt unveraendert)
KNOWN_MR16="c5ffda3907b0dd51"    # mesh_router.py (bleibt unveraendert)
KNOWN_LG16="3788481354f47656"    # lagegeo.py (bleibt unveraendert)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== sdrAir2 apply (Hobby nur beobachten + 10C-Pruefung, Geraetenamen Name · Rolle, RTL-Index-Pruefung, ehrliche Zusammenfassung + 11D-Sync-Nachweis, CPU je Kern, SoapySDR nur per Einstellung mit Rueckfall), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_PF="dd875ef5406a3155d7996f49701e46eebf189a38b39e3dcdaa1401f25c3ab7a4"
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
name = {"sm": "sdr_manager", "sdr": "prepper_sdr", "dash": "dashboard", "dsh": "dashboard"}[kind]   # dsh = Dashboard-Block vor dem Hauptteil (nicht eingerueckt)
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
EXPECT_AE2="e026f569cf286edf56e98af4dd9185a9efb0f60a2139fc37070fbbce3d282878"
cat > "$W/air2_edits.py" << 'AE2_EOF'
# sdrAir2: Stellen (alt, neu) auf dem Stand nach sdrAir (live 23.10. 23:07). Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
('''        selftest_sdrair()
''', '''        selftest_sdrair()
        selftest_sdrair2()
'''),
# Startzeile sdrTeil2: im Register-Betrieb echte Rollen statt "Stick 1 fest 11D, Stick 2 Hobby + Alarm-Uebernahme 5C"
('''    self.log("sdrTeil2: %s" % ("aktiv - Stick 1 fest 11D, Stick 2 Hobby + Alarm-Uebernahme 5C" if self.t2 else "AUS (sdr_config.json t2_roles=false) - Rollen wie vorher"))''',
 '''    self.log("sdrTeil2: %s" % (air2_t2_txt(self) if self.t2 else "AUS (sdr_config.json t2_roles=false) - Rollen wie vorher"))   # sdrAir2: Register-Rollen'''),
# Geraetenamen statt Platznummern
('''        self.log("Stick %d: Rolle %s -> %s" % (self.stickno, self.role, r))''',
 '''        self.log("%s: Rolle %s -> %s" % (air_name(self.stickno), self.role, r))   # sdrAir2: Geraetename'''),
('''            tx = ("Kalibrierung Stick %d (%s): %+.2f ppm, angewendet %+d%s" % (n, rec.get("ch") or "?",''',
 '''            tx = ("Kalibrierung %s (%s): %+.2f ppm, angewendet %+d%s" % (air_name(n), rec.get("ch") or "?",'''),
('''                  if ok else "Kalibrierung Stick %d (%s): kein Ergebnis%s - alter Wert bleibt" % (n, rec.get("ch") or "?",''',
 '''                  if ok else "Kalibrierung %s (%s): kein Ergebnis%s - alter Wert bleibt" % (air_name(n), rec.get("ch") or "?",'''),
('''                msgs.append(("wd_rearm", "Pi-Neustart-Automatik wieder bereit (Stick %d hat wieder echten Empfang)" % s["n"], ch, "ok"))''',
 '''                msgs.append(("wd_rearm", "Pi-Neustart-Automatik wieder bereit (%s hat wieder echten Empfang)" % air_name(s["n"]), ch, "ok"))   # sdrAir2: Geraetename'''),
# CPU ehrlich: Prozent EINES Kerns
('''                    self.log("sdrAir: welle-cli am Airspy braucht %.0f %% CPU (Grenze %.0f %%, 10 min) - Empfang laeuft weiter, Pi pruefen" % (cs["avg"], mx))''',
 '''                    self.log("sdrAir: welle-cli am Airspy braucht %.0f %% eines Kerns (Grenze %.0f %% eines Kerns, 10 min; %d Kerne) - Empfang laeuft weiter, Pi pruefen" % (cs["avg"], mx, int(os.cpu_count() or 1)))   # sdrAir2'''),
# Frontend-Text: SoapySDR nur wenn wirklich benutzt, sonst -F airspy (mit Rueckfall-Grund)
('''        st["dev"]["fe"] = "soapysdr (driver=airspy)" if self.cfg.get("air_fe") == "soapy" else "welle-cli -F airspy"''',
 '''        st["dev"]["fe"] = air2_fe_txt(self)   # sdrAir2: SoapySDR nur per air_fe, Rueckfall sichtbar'''),
# Selbsttest sdrAir an sdrAir2 angepasst: SoapySDR-Modul vorhanden simulieren; Hobby blockiert jetzt alle Aktionen
('''    m.cfg["air_fe"] = "soapy"
    assert m._cmd_dab("11D")[0][7:11] == ["-F", "soapysdr", "-s", "driver=airspy,serial=%s" % AS.lower()]
    m.cfg["air_fe"] = "airspy"''', '''    m.cfg["air_fe"] = "soapy"
    _AIR2.update(soapy_t=time.time(), soapy_where="/selftest/libairspySupport.so", soapy=True)   # sdrAir2: Modul vorhanden simulieren
    assert m._cmd_dab("11D")[0][7:11] == ["-F", "soapysdr", "-s", "driver=airspy,serial=%s" % AS.lower()]
    m.cfg["air_fe"] = "airspy"
    _AIR2["soapy_t"] = 0.0
    m.__dict__.pop("_air2_fs", None)'''),
('''    assert _wd_block(h, t0, "72055505", "reboot").startswith("Hobby") and not str(_wd_block(h, t0, "72055505", "restart") or "").startswith("Hobby")''',
 '''    assert _wd_block(h, t0, "72055505", "reboot").startswith("Hobby") and str(_wd_block(h, t0, "72055505", "restart") or "").startswith("Hobby")   # sdrAir2: Hobby nur Beobachtung'''),
('''    wd_check(h, "dab", False, t0 - 7200, "5C", "kein Sync")
    wd_check(h, "dab", False, t0 - 7100, "5C", "kein Sync")''',
 '''    _air2_orig_wd_check(h, "dab", False, t0 - 7200, "5C", "kein Sync")   # sdrAir2: alter Uebernahme-Vorfall (Hobby-DAB zaehlt sonst nur als 10C-Pruefung)
    _air2_orig_wd_check(h, "dab", False, t0 - 7100, "5C", "kein Sync")'''),
('''    assert s2i["t2"] == "fest5c" and s2i["txt"].startswith("Stick 1 SN 19348831: fest 5C"), s2i''',
 '''    assert s2i["t2"] == "fest5c" and s2i["txt"].startswith("Stick 1 · 5C SN 19348831: fest 5C"), s2i   # sdrAir2: Anzeige-Name mit Rolle'''),
('''("Stick 2", "aktiv"), ("RTL-Stick SN 00000003", "erkannt, ohne Rolle")], dv''',
 '''("Stick 2", "aktiv"), ("Stick 3", "erkannt, ohne Rolle")], dv   # sdrAir2: Stick ohne Rolle = Stick N'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SM_EDITS = [
('''    assert r["air"] and r["s1"]["name"] == "Airspy R2" and r["s2"]["name"] == "Stick 1" and''',
 '''    assert r["air"] and r["s1"]["name"] == "Airspy R2 · 11D" and r["s2"]["name"] == "Stick 1 · 5C" and'''),
('''    print(selftest_sdrair())
''', '''    print(selftest_sdrair())
    print(selftest_sdrair2())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
("""_t4_event("VORALARM", kind.lower(), "warn", "VORALARM %s: %s - SDR 2 auf 5C" % (kind, why), now)""",
 """_t4_event("VORALARM", kind.lower(), "warn", "VORALARM %s: %s - %s" % (kind, why, globals().get("_air2d_5c", lambda o, s=False: o)("SDR 2 auf 5C")), now)"""),
("""_t4_say("teil4: VORALARM %s (%s) -> Stick 2 %s" % (kind, why, "auf 5C gekapert" if to.get("on") else "?"))""",
 """_t4_say("teil4: VORALARM %s (%s) -> %s" % (kind, why, globals().get("_air2d_5c", lambda o, s=False: o)("Stick 2 " + ("auf 5C gekapert" if to.get("on") else "?"))))"""),
("""_t4_event("DAB", "t4fb", "info", "SDR 2 %s" % ("LOCAL-EBENE""", """_t4_event("DAB", "t4fb", "info", "%s %s" % (globals().get("_air2d_5c", lambda o, s=False: o)("SDR 2", True), "LOCAL-EBENE"""),
("""        if not _lz_mgr.takeover_load(base).get("on"):
            _lz_mgr.takeover_set(base, True, (st["pre"].get("kinds") or ["DSL"])[0], "Vor-Alarm aktiv - Rueckgabe nur per SDR 2 freigeben", "teil4", now)""",
 """        if not _lz_mgr.takeover_load(base).get("on") and not globals().get("_air2d_reg", lambda: None)():   # sdrAir2: Register = 5C fest, keine Uebernahme (sonst alle 30 s Journal-Zeile)
            _lz_mgr.takeover_set(base, True, (st["pre"].get("kinds") or ["DSL"])[0], "Vor-Alarm aktiv - Rueckgabe nur per SDR 2 freigeben", "teil4", now)"""),
("""("Stick 2" if cat == "stick" else "Technik")""", """(globals().get("_air2d_src", lambda: "Stick 2")() if cat == "stick" else "Technik")"""),
("""' · Stick 2 Korrektur '""", """' · '+(U.ppm_lbl||'Stick 2')+' Korrektur '"""),
("""kv(box,'ohne Rolle',x.name+' ('+x.usb+') · erkannt, ohne Rolle – nie benutzt','#94a3b8')""",
 """kv(box,x.label||'ohne Rolle',(x.serial?'SN '+x.serial+' · ':'')+'USB '+x.usb+' · erkannt, ohne Rolle – nie benutzt'+(x.hint?' · '+x.hint:''),'#94a3b8')"""),
]
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
AE2_EOF
EXPECT_ASD2="4c97c2aecadd3401281aedd09d2915fc2aed86fb246ed449ad58ad038138c2bf"
cat > "$W/air2_sdr_block.py" << 'AB2_EOF'
# ===== sdrAir2: Hobby-Geraet nur beobachten (kein Neustart/USB/Pi-Neustart, RDS ueber alle Sender der Rotation, eigene Zeile, nicht in der Gesamtstufe), Geraetenamen statt Platznummern, ehrliche CPU-Anzeige (je Kern), SoapySDR fuer den Airspy nur per Einstellung (air_fe soapy) mit eigener Stufen-Tabelle und Rueckfall auf -F airspy; Hobby-Stick alle 6 h kurze 10C-Pruefung (welle-cli nur am Hobby-Stick, Sync/SNR/TII, letzter 10C-Sync dauerhaft in broadcast_state p10c); RTL-Index nach jedem Start gegen die Seriennummer geprueft (Umstecken/neuer Stick), doppelte/Werks-Seriennummer = nicht benutzt, Watchdog wartet, klarer Hinweis; Anzeige-Namen 'Name · Rolle' aus dem Register (Stick ohne Rolle = 'Stick N · ohne Rolle', Ein-/Abstecken einmal im Journal); Gain-Verhalten unveraendert =====
AIR2_HOBBY_FAIL_N = 3          # leere RDS-Fenster in Folge (Rotation BR24/Bayern 3/Bayern 1) bis Hobby-Hinweis
AIR2_HOBBY_BLOCK = "Hobby-Gerät – Watchdog beobachtet nur (kein Neustart, keine USB-Neuverbindung, kein Pi-Neustart)"
AIR2_SOAPY_MAX_STARTS = 3      # SoapySDR: so viele 11D-Runden ohne Sync, dann Rueckfall auf -F airspy (bis Neustart prepper-sdr)
AIR2_SOAPY_CACHE_S = 3600
# libairspy Linearitaets-Tabellen (VGA + Mixer + LNA, Index 21 - Stufe): Summe = Gesamtverstaerkung fuer SoapySDR (welle-cli -g = Index 0..44 der Soapy-Gesamtverstaerkung)
_AIR2_VGA = (13, 12, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 8, 7, 6, 5, 4)
_AIR2_MIX = (12, 12, 11, 9, 8, 7, 6, 6, 5, 0, 0, 1, 0, 0, 2, 2, 1, 1, 1, 1, 0, 0)
_AIR2_LNA = (14, 14, 14, 13, 12, 10, 9, 9, 8, 9, 8, 6, 5, 3, 1, 0, 0, 0, 0, 0, 0, 0)
AIR2_SOAPY_GAIN = dict((v, _AIR2_VGA[21 - v] + _AIR2_MIX[21 - v] + _AIR2_LNA[21 - v]) for v in range(22))   # 16 -> 28, 12 -> 19, 19 -> 36, 9 -> 15, 21 -> 39
DEFAULT_CFG.update({"air_cpu_max": 120})   # sdrAir2: Grenze in % EINES Kerns (welle-cli normal 55-75 %), 10 min im Mittel darueber -> Warnung
AIR2_P10_CH = "10C"            # Hobby-Pruefung: Lokal Nuernberg 10C (213,360 MHz)
AIR2_P10_EVERY_S = 6 * 3600    # alle 6 h (beim naechsten Hobby-Rundfunk-Block, also hoechstens ~30 min spaeter)
AIR2_P10_WIN_S = 1800          # 10C steht nur so lange in der Kanal-Liste des Hobby-Planers
AIR2_P10_KEY = "p10c"          # broadcast_state.json / lagezentrum.db state broadcast_state: letzter 10C-Sync (fuer spaeteres dabSql: 10C > 24 h ohne Sync = offline)
DEFAULT_CFG.update({"hobby_10c": True})   # sdr_config.json hobby_10c false = Hobby-Pruefung 10C aus
_AIR2 = {"soapy": None, "soapy_t": 0.0, "soapy_where": None, "hclosed": set(), "nfix": set()}

_air2_orig_wd_check = wd_check
_air2_orig_wd_tick = wd_tick
_air2_orig_wd_view = wd_view
_air2_orig_wd_block = _wd_block
_air2_orig_cpu_tick = _air_cpu_tick
_air2_orig_cmd_dab = Planner._cmd_dab


def _air2_hobby(pl):
    a = _air_pl(pl)
    return a if a is not None and a.get("role") == "hobby" else None


def air2_t2_txt(pl):
    """Startzeile sdrTeil2: im Register-Betrieb die echten Rollen statt der alten Stick-1/Stick-2-Aufteilung."""
    r = _AIR["bases"].get(getattr(pl, "base", None))
    if not r:
        return "aktiv - Stick 1 fest 11D, Stick 2 Hobby + Alarm-Uebernahme 5C"
    by = r.get("by_role") or {}
    return "aktiv im Geraete-Register (sdrAir, keine Uebernahme) - %s" % "; ".join(
        "%s %s" % (by[k]["name"], {"11D": "fest 11D", "5C": "fest 5C + Rueckfall 10C", "hobby": "Hobby"}[k]) for k in ("11D", "5C", "hobby") if by.get(k))


def _air2_nfix(pl, d):
    """Gespeicherte Platznummern (n) der Register-Geraete auf ihren Platz setzen (alte Zuordnung aus sdrWd/sdrAir-Start), einmal je Prozess. Nur unter _WD_LOCK."""
    r = _AIR["bases"].get(pl.base)
    if not r or pl.base in _AIR2["nfix"]:
        return
    _AIR2["nfix"].add(pl.base)
    for e in r.get("devs") or []:
        s = d["sticks"].get(e.get("serial"))
        if s is not None and e.get("role") in DEV_SLOT and s.get("n") != DEV_SLOT[e["role"]]:
            s["n"] = DEV_SLOT[e["role"]]
            _WD["dirty"] = True


def _air2_hobby_check(pl, a, src, ok, now, ch, why):
    """Hobby: nur RDS zaehlt, ueber alle Sender der Rotation. Ein Sender ohne RDS ist kein Vorfall; erst AIR2_HOBBY_FAIL_N leere Fenster in Folge -> Hinweis (nur Beobachtung).
    Irgendein RDS-Empfang -> Hinweis zu."""
    sn = cfg_serial(pl.cfg)
    if not sn or src != "rds":
        return
    hs = pl.__dict__.setdefault("_air2_h", {"fail": 0, "chs": []})
    nm = a.get("name") or air_name(pl.stickno)
    c = str(ch or "?")[:20]
    msgs = []
    with _WD_LOCK:
        d = _wd_state(pl.base, now)
        _air2_nfix(pl, d)
        s = d["sticks"].get(sn)
        if s is None:
            s = d["sticks"][sn] = _wd_clean({"sticks": {sn: {"n": int(pl.stickno or 3)}}})["sticks"][sn]
        s.update(n=int(pl.stickno or 3), last_check=int(now), src="rds", ch=c[:12])
        i = s.get("inc")
        if ok:
            hs.update(fail=0, chs=[])
            s.update(last_ok=int(now), last_ok_src=("RDS %s" % c)[:30], fail_n=0, why=None)
            if i:
                msgs.append(("wd_ok", "%s · Hobby: RDS wieder da (%s) – ohne RDS %s–%s, %s · nur Beobachtung" % (nm, c, _wd_hm(i["since"], now), _wd_hm(now, now), _wd_dur(now - i["since"])), ch, "ok"))
                s["last_inc"] = {"since": i["since"], "end": int(now), "act": None, "usb_n": 0, "reboot_n": 0}
                s["inc"] = None
        else:
            hs["fail"] = int(hs.get("fail") or 0) + 1
            hs["chs"] = ([x for x in hs.get("chs") or [] if x != c] + [c])[-6:]
            s.update(fail_n=hs["fail"], last_fail=int(now), why=("%s (%d leere Fenster in Folge: %s)" % (why or "kein RDS", hs["fail"], ", ".join(hs["chs"])))[:120])
            if i:
                i["chk"] = int(i.get("chk") or 0) + 1
            elif hs["fail"] >= AIR2_HOBBY_FAIL_N:
                since = int(s["last_ok"]) if s.get("last_ok") and s["last_ok"] <= now else int(now)
                s["inc"] = {"since": since, "t0": since, "ch": "RDS", "src": "rds", "restart_n": 0, "usb_n": 0, "reboot_n": 0, "act": None, "act_t": None, "chk": hs["fail"], "lg": 0,
                            "block": AIR2_HOBBY_BLOCK, "blk_t": int(now), "usb_last": None, "v2": 1, "to": 0, "pre": 0}
                msgs.append(("wd_stage", "%s · Hobby: kein RDS in %d Fenstern in Folge (%s) – nur Beobachtung, keine Aktion" % (nm, hs["fail"], ", ".join(hs["chs"])), "RDS", "gelb"))
        _WD["dirty"] = True
        _wd_save(pl.base, now, force=bool(msgs))
    _wd_emit(pl.base, msgs, now)


def wd_check(pl, src, ok, now, ch=None, why=None):
    a = _air2_hobby(pl)
    if a is not None and src == "rds":
        return _air2_hobby_check(pl, a, src, ok, now, ch, why)
    if a is not None and src == "dab":
        return _air2_p10_note(pl, a, ok, now, ch, why)     # Hobby-DAB = nur 10C-Pruefung, nie Watchdog-Vorfall
    try:
        fs = pl.__dict__.get("_air2_fs")
        if ok and src == "dab" and fs is not None and pl.cfg.get("dev_kind") == "airspy":
            fs.update(starts=0, ok_t=int(now))
    except Exception as ex:
        print("sdrAir2 Soapy:", ex, flush=True)
    return _air2_orig_wd_check(pl, src, ok, now, ch, why)


def _air2_hobby_tick(pl, a, now):
    """Hobby: keine Stufen, keine Aktionen. Alter Vorfall (z. B. RDS Bayern 1 aus sdrAir, alte Uebernahme 5C) einmal je Prozess schliessen; fehlt/wieder da wie bisher."""
    sn = cfg_serial(pl.cfg)
    if not sn:
        return
    try:
        _air_wd_role_close(pl, now)
    except Exception as ex:
        print("sdrAir2 Vorfall/Rolle:", ex, flush=True)
    nm = a.get("name") or air_name(pl.stickno)
    msgs = []
    with _WD_LOCK:
        d = _wd_state(pl.base, now)
        _air2_nfix(pl, d)
        s = d["sticks"].get(sn)
        if s is not None:
            if s.get("n") != int(pl.stickno or 3):
                s["n"] = int(pl.stickno or 3)
                _WD["dirty"] = True
            i = s.get("inc")
            if i and sn not in _AIR2["hclosed"]:
                msgs.append(("wd_ok", "%s · Hobby: alter Vorfall %s (seit %s) beendet – sdrAir2: Hobby nur Beobachtung, keine Aktion" % (nm, i.get("ch") or "?", _wd_hm(i["since"], now)), i.get("ch"), "ok"))
                s["last_inc"] = {"since": i["since"], "end": int(now), "act": i.get("act"), "usb_n": i.get("usb_n"), "reboot_n": i.get("reboot_n"), "why": "sdrAir2 Hobby nur Beobachtung"}
                s["inc"], s["fail_n"], i = None, 0, None
                pl.__dict__["_air2_h"] = {"fail": 0, "chs": []}
                _WD["dirty"] = True
            _AIR2["hclosed"].add(sn)
            if i:
                m0 = []
                _wd2_abs_tick(pl, s, i, now, m0)
                i["block"] = WD2_ABS_TXT if i.get("abs") else AIR2_HOBBY_BLOCK
                i.update(restart_n=0, usb_n=0, reboot_n=0, act=None, act_t=None)
                msgs += [(k, t.replace("Watchdog prüft neu, Eskalation ab %s" % _wd_hm(now, now), "Watchdog beobachtet weiter (Hobby, keine Aktion)"), c, lv) for k, t, c, lv in m0]
        _wd_save(pl.base, now, force=bool(msgs))
    _wd_emit(pl.base, msgs, now)


def wd_tick(pl, now):
    a = _air2_hobby(pl)
    if a is not None:
        try:
            return _air2_hobby_tick(pl, a, now)
        except Exception as ex:
            print("sdrAir2 Hobby:", ex, flush=True)
            return None
    try:
        sn = cfg_serial(pl.cfg)
        if _air_pl(pl) is not None and sn:
            with _WD_LOCK:
                d = _wd_state(pl.base, now)
                _air2_nfix(pl, d)
                s = d["sticks"].get(sn)
                if s is not None and s.get("n") != int(pl.stickno or 1):
                    s["n"] = int(pl.stickno or 1)
                    _WD["dirty"] = True
    except Exception as ex:
        print("sdrAir2 Namen:", ex, flush=True)
    return _air2_orig_wd_tick(pl, now)


def _wd_block(pl, now, sn, act=None):
    if _air2_hobby(pl) is not None:
        return AIR2_HOBBY_BLOCK
    return _air2_orig_wd_block(pl, now, sn, act)


def wd_view(pl, now):
    v = _air2_orig_wd_view(pl, now)
    try:
        ap = _air_pl(pl)
        if ap is not None and _air2_dup(pl):
            nm = ap.get("name") or "?"
            t = "%s: %s" % (nm, str(pl.pin_err)[:70])
            v = dict(v)
            v.update(lvl="gelb" if ap.get("role") == "hobby" else "rot", absent=False, dup=True, stage=0, block=AIR2_DUP_TXT, hl="%s: doppelte Seriennummer" % nm,
                     short=t + " – nicht benutzt, keine Aktion", txt=t + " · nicht benutzt, Watchdog wartet, keine Aktion", hint=AIR2_SN_HINT)
            if ap.get("role") == "hobby":
                v.update(watch=True, role="hobby")
            return v
    except Exception as ex:
        print("sdrAir2 Anzeige doppelt:", ex, flush=True)
    a = _air2_hobby(pl)
    if a is None:
        return v
    try:
        v = dict(v)
        nm = a.get("name") or "?"
        v.update(watch=True, role="hobby", stage=0, block=AIR2_HOBBY_BLOCK, hint="Hobby-Gerät: der Watchdog beobachtet nur RDS über alle Sender – kein Neustart, keine USB-Neuverbindung, kein Pi-Neustart")
        if v.get("absent"):
            return v
        sn = cfg_serial(pl.cfg)
        with _WD_LOCK:
            s = dict(_wd_state(pl.base, now)["sticks"].get(sn) or {})
        i = s.get("inc")
        hs = pl.__dict__.get("_air2_h") or {}
        if not s.get("last_check"):
            v.update(lvl="grau", txt="%s · Hobby: noch keine RDS-Prüfung seit Start · nur Beobachtung" % nm, short=None, hl="%s · Hobby" % nm)
        elif not i:
            lo = ("zuletzt %s %s" % (s.get("last_ok_src") or "RDS", _wd_hm(s.get("last_ok"), now))) if s.get("last_ok") else "noch kein RDS seit Start"
            v.update(lvl="ok", txt="%s · Hobby: RDS ok (%s)%s · nur Beobachtung" % (nm, lo, (" · zuletzt leer: %s" % ", ".join(hs.get("chs") or [])) if hs.get("fail") else ""), short=None,
                     hl="%s · Hobby" % nm)
        else:
            t = "%s · Hobby: kein RDS seit %s (%s) · nur Beobachtung, keine Aktion" % (nm, _wd_hm(i["since"], now), ", ".join(hs.get("chs") or []) or "alle Sender")
            v.update(lvl="gelb", txt=t, short="%s · Hobby: kein RDS seit %s – nur Beobachtung" % (nm, _wd_hm(i["since"], now)), hl="%s · Hobby ohne RDS" % nm, since=i.get("since"))
        pt = air2_p10_txt(pl, now)
        if pt and isinstance(v.get("txt"), str):
            v["txt"] = v["txt"] + " · " + pt
            v["p10c"] = air2_p10_get(pl)
    except Exception as ex:
        print("sdrAir2 Anzeige:", ex, flush=True)
    return v


def _air_cpu_tick(self, now):
    cs = _air2_orig_cpu_tick(self, now)
    try:
        n = int(os.cpu_count() or 1)
        cs["cores"] = n
        if cs.get("pct") is None:
            cs["txt"] = "noch nicht gemessen"
            return cs
        cs["pct_all"] = round(float(cs["pct"]) / n, 1)
        cs["avg_all"] = round(float(cs.get("avg") or 0) / n, 1)
        cs["max"] = float(self.cfg.get("air_cpu_max") or 120)
        cs["txt"] = "%.0f %% eines Kerns (5 min Mittel %.0f %% eines Kerns = %.0f %% des Pi mit %d Kernen), nice %s, Warnung über %.0f %% eines Kerns" % (
            cs["pct"], cs.get("avg") or 0, cs["avg_all"], n, cs.get("nice"), cs["max"])
    except Exception as ex:
        cs["txt"] = "?"
        print("sdrAir2 CPU:", ex, flush=True)
    return cs


def air2_soapy_module(now=None):
    """SoapySDR-Modul fuer den Airspy vorhanden? Nur Dateien ansehen (kein Programmstart), zwischengespeichert. -> Pfad oder None"""
    now = now or time.time()
    if _AIR2["soapy_t"] and now - _AIR2["soapy_t"] < AIR2_SOAPY_CACHE_S:
        return _AIR2["soapy_where"]
    roots = [x for x in str(os.environ.get("SDR_SOAPY_MODDIRS") or "").split(":") if x]
    if not roots:
        roots = ["/usr/local/lib", "/usr/lib"]
        try:
            roots += ["/usr/lib/" + x for x in sorted(os.listdir("/usr/lib")) if x.endswith("-linux-gnu")]
        except OSError:
            pass
    found = None
    for r in roots:
        d = os.path.join(r, "SoapySDR")
        try:
            mods = sorted(x for x in os.listdir(d) if x.startswith("modules"))
        except OSError:
            continue
        for m in mods:
            f = os.path.join(d, m, "libairspySupport.so")
            if os.path.isfile(f):
                found = f
                break
        if found:
            break
    _AIR2.update(soapy_t=now, soapy_where=found, soapy=bool(found))
    return found


def _air2_fe(self):
    """-> ("soapy" | "airspy", Grund des Rueckfalls oder None). Standard und Rueckfall: -F airspy."""
    if self.cfg.get("air_fe") != "soapy":
        return "airspy", None
    fs = self.__dict__.setdefault("_air2_fs", {"fb": None, "why": None, "starts": 0, "ok_t": None})
    if fs.get("fb"):
        return "airspy", fs.get("why")
    if not air2_soapy_module():
        fs.update(fb=int(time.time()), why="SoapySDR-Modul fuer Airspy (libairspySupport.so) fehlt")
        self.log("sdrAir2: air_fe soapy gewuenscht, aber %s - Airspy laeuft mit -F airspy" % fs["why"])
        return "airspy", fs["why"]
    return "soapy", None


def air2_fe_txt(self):
    fe, why = _air2_fe(self)
    if fe == "soapy":
        return "welle-cli -F soapysdr (driver=airspy, 2048 kS/s, Stufe -> Soapy-Gesamtverstaerkung)"
    return "welle-cli -F airspy" + (" (Rückfall: %s)" % why if why else "")


def _air2_cmd_dab(self, ch):
    r = _air2_orig_cmd_dab(self, ch)
    if self.cfg.get("dev_kind") != "airspy" or _air_pl(self) is None:
        return r
    try:
        a = list(r[0])
        fe, why = _air2_fe(self)
        if fe == "soapy":
            fs = self.__dict__["_air2_fs"]
            if int(fs.get("starts") or 0) >= AIR2_SOAPY_MAX_STARTS:
                fs.update(fb=int(time.time()), why="%d Runden 11D ohne Sync mit SoapySDR" % int(fs["starts"]))
                self.log("sdrAir2: SoapySDR am Airspy %s - zurueck auf welle-cli -F airspy (bis Neustart prepper-sdr)" % fs["why"])
                fe = "airspy"
            else:
                fs["starts"] = int(fs.get("starts") or 0) + 1
        i = a.index("-F")
        if fe == "airspy":
            j = i + 4 if a[i + 1] == "soapysdr" else i + 2
            a[i:j] = ["-F", "airspy"]
        else:
            if a[i + 1] != "soapysdr":
                a[i:i + 2] = ["-F", "soapysdr", "-s", "driver=airspy,serial=%s" % str(cfg_serial(self.cfg)).lower()]
            if "-g" in a:
                k = a.index("-g")
                lin = int(a[k + 1])
                a[k + 1] = str(AIR2_SOAPY_GAIN.get(lin, AIR2_SOAPY_GAIN[16]))
                if isinstance(self.__dict__.get("_dg_used"), dict):
                    self._dg_used["db"] = "Airspy-Stufe %s (SoapySDR %s)" % (lin, a[k + 1])
        return [a]
    except Exception as ex:
        print("sdrAir2 Befehl:", ex, flush=True)
        return r


Planner._cmd_dab = _air2_cmd_dab


def air2_p10_get(pl):
    """letzte Hobby-Pruefung 10C aus broadcast_state (gemeinsam mit Haupt-Planer, ueberlebt Neustart ueber DB/JSON)."""
    try:
        d = pl.sbc.d.get(AIR2_P10_KEY)
        return dict(d) if isinstance(d, dict) else {}
    except Exception:
        return {}


def _air2_p10_on(pl):
    a = _air2_hobby(pl)
    return (a is not None and pl.cfg.get("dev_kind") != "airspy" and pl.cfg.get("hobby_10c", True) is not False and AIR2_P10_CH in DAB_CHANNELS
            and not pl.pin_err and bool(pl.tool("welle")))


def _air2_p10_due(pl, now):
    t = air2_p10_get(pl).get("t_check")
    return not isinstance(t, (int, float)) or t > now + 300 or now - t >= AIR2_P10_EVERY_S


_air2_orig_dab_list = Planner.dab_list
_air2_orig_bc_queue = Planner.bc_queue
_air2_orig_sub_done = Planner.sub_done


def _air2_dab_list(self):
    v = _air2_orig_dab_list(self)
    try:
        t = self.__dict__.get("_air2_p10t")
        if t and abs(time.time() - t) < AIR2_P10_WIN_S and AIR2_P10_CH not in [str(x) for x in v]:
            v = list(v) + [AIR2_P10_CH]        # nur Hobby-Planer, nur waehrend der 10C-Pruefung; Reihenfolge der anderen bleibt
    except Exception as ex:
        print("sdrAir2 10C Liste:", ex, flush=True)
    return v


def _air2_bc_queue(self):
    q = _air2_orig_bc_queue(self)
    try:
        if not _air2_p10_on(self) or _t2_alarm(self):
            return q
        now = time.time()
        if now - float(self.last_bc or 0) < float(self.cfg.get("bc_interval_s") or 1800) or not _air2_p10_due(self, now):
            return q                            # nur wenn der Hobby-Rundfunk-Block jetzt beginnt
        self.__dict__["_air2_p10t"] = now
        i = _t2_dab_idx(self, AIR2_P10_CH)
        if i is None:
            return q
        return list(q or []) + [("dab:%d" % i, float(self.cfg.get("p10c_s") or self.cfg.get("dab_s") or 60))]   # zuletzt, danach wieder Hobby
    except Exception as ex:
        print("sdrAir2 10C Block:", ex, flush=True)
        return q


def _air2_sub_done(self, sp, now):
    try:
        return _air2_orig_sub_done(self, sp, now)
    finally:
        try:
            job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") and 0 <= int(sp.get("i", 0)) < len(sp["queue"]) else ""
            if self.__dict__.get("_air2_p10t") and (sp.get("kind") != "bc" or (job.startswith("dab:") and int(sp.get("i", 0)) == len(sp["queue"]) - 1)):
                self.__dict__["_air2_p10t"] = None   # 10C-Pruefung vorbei: Kanal-Liste wieder wie vorher
        except Exception as ex:
            print("sdrAir2 10C Ende:", ex, flush=True)


def _air2_p10_note(pl, a, ok, now, ch, why):
    """Ergebnis der Hobby-Pruefung 10C merken (kein Watchdog, keine Aktion); andere Kanaele am Hobby-Stick: nur ignorieren."""
    try:
        if str(ch or "").upper() != AIR2_P10_CH:
            return None
        d = pl.sbc.d
        e = ((d.get("dab") or {}).get(AIR2_P10_CH) or {})
        dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
        fg = (((d.get("t2") or {}).get("fig") or {}).get(AIR2_P10_CH)) if isinstance(d.get("t2"), dict) else None
        fg = fg if isinstance(fg, dict) and isinstance(fg.get("t"), (int, float)) and now - fg["t"] <= 120 else {}
        num = lambda x: round(float(x), 2) if isinstance(x, (int, float)) and not isinstance(x, bool) else None
        tii = [{"main": x.get("main"), "sub": x.get("sub"), "mast": str(x.get("mast") or "")[:60]} for x in (fg.get("tii") or [])[:4] if isinstance(x, dict)] if ok else []
        with pl.lock:
            o = d.get(AIR2_P10_KEY) if isinstance(d.get(AIR2_P10_KEY), dict) else {}
            r = {"v": 1, "ch": AIR2_P10_CH, "every_s": AIR2_P10_EVERY_S, "dev": a.get("name"), "sn": cfg_serial(pl.cfg), "t_check": int(now), "ok": bool(ok),
                 "why": None if ok else str(why or "kein Sync")[:120], "snr": num(dm.get("snr")), "fic_rate": num(dm.get("fic_rate")), "tii": tii,
                 "ens": str(fg.get("ens") or "")[:30] or None if ok else None, "n": int(o.get("n") or 0) + 1, "n_ok": int(o.get("n_ok") or 0) + (1 if ok else 0),
                 "t_sync": int(now) if ok else (o.get("t_sync") if isinstance(o.get("t_sync"), (int, float)) else None)}
            h = [x for x in (o.get("hist") or []) if isinstance(x, list) and len(x) == 3][-19:]
            r["hist"] = h + [[int(now), 1 if ok else 0, r["snr"]]]
            d[AIR2_P10_KEY] = r
            pl.sbc.dirty = True
            pl.sbc.last_saved = 0
        pl.log("sdrAir2: %s Hobby-Pruefung 10C: %s%s%s - naechste in %d h, zurueck zum Hobby" % (
            a.get("name"), "Sync" if ok else "kein Sync (%s)" % r["why"], (", SNR %s" % r["snr"]) if r["snr"] is not None else "",
            (", TII %s" % "; ".join(x["mast"] for x in tii[:2])) if tii else "", AIR2_P10_EVERY_S // 3600))
    except Exception as ex:
        print("sdrAir2 10C Ergebnis:", ex, flush=True)
    return None


def air2_p10_txt(pl, now):
    try:
        if pl.cfg.get("hobby_10c", True) is False:
            return "10C-Prüfung aus"
        r = air2_p10_get(pl)
        if not r.get("t_check"):
            return "10C-Prüfung alle %d h: noch nicht gelaufen" % (AIR2_P10_EVERY_S // 3600)
        ts = r.get("t_sync")
        return "10C-Prüfung alle %d h: %s%s" % (AIR2_P10_EVERY_S // 3600, ("Sync %s" % _wd_hm(r["t_check"], now)) if r.get("ok") else ("kein Sync %s" % _wd_hm(r["t_check"], now)),
                                                 (" (SNR %s)" % r["snr"]) if r.get("ok") and r.get("snr") is not None else ("" if r.get("ok") else (" · letzter Sync %s" % _wd_hm(ts, now) if ts else " · noch nie Sync")))
    except Exception:
        return None


Planner.dab_list = _air2_dab_list
Planner.bc_queue = _air2_bc_queue
Planner.sub_done = _air2_sub_done


AIR2_FACTORY_SN = ("00000000", "00000001", "")
AIR2_DUP_TXT = "doppelte Seriennummer – Stick nicht benutzt, Watchdog wartet (keine Aktion)"
AIR2_SN_HINT = "eindeutige Seriennummer setzen (rtl_eeprom -d INDEX -s NEUE_SN, nur von Hand, Stick allein am Pi), danach sdr_config.json devs anpassen"
_air2_orig_start = Planner.start
_air2_orig_wd2_absent = _wd2_absent
_air2_orig_wd2_abs_tick = _wd2_abs_tick
_air2_orig_air_devs = air_devs


def _air2_dup(pl):
    return str(getattr(pl, "pin_err", "") or "").startswith("doppelte Seriennummer")


def _air2_idx_bad(pl, lst):
    """Nach dem Start: steht unter dem benutzten Index noch unsere Seriennummer? -> Grund oder None. Unklare Liste = None (nichts tun)."""
    if lst is None or pl.dev_idx is None or not serial_ok(pl.dev_sn):
        return None
    at = [x for x in lst if x.get("idx") == pl.dev_idx]
    mine = [x for x in lst if x.get("sn") == pl.dev_sn]
    if int(pl.list_n or 0) == 1 and len(lst) > 1:
        return "jetzt %d RTL-Sticks statt 1 (neu angesteckt)" % len(lst)
    if len(mine) > 1:
        return "doppelte Seriennummer %s (%d Sticks)" % (pl.dev_sn, len(mine))
    if at and at[0].get("sn") and at[0]["sn"] != pl.dev_sn:
        return "Index %d ist jetzt SN %s statt %s (USB umgesteckt)" % (pl.dev_idx, at[0]["sn"], pl.dev_sn)
    if not at and mine:
        return "Index %d fehlt, SN %s jetzt Index %d (USB umgesteckt)" % (pl.dev_idx, pl.dev_sn, mine[0].get("idx"))
    return None


def _air2_start(self, what):
    r = _air2_orig_start(self, what)
    bad = None
    try:
        if self.cfg.get("dev_kind") != "airspy" and self.procs and what != "433" and self.cfg.get("idx_check", True) is not False:
            lst, e = list_sticks()
            bad = _air2_idx_bad(self, lst)
    except Exception as ex:
        print("sdrAir2 Index-Pruefung:", ex, flush=True)
    if bad:
        self.log("sdrAir2: %s SN %s: %s - %s sofort beendet, neuer Versuch mit neu aufgeloestem Index" % (air_name(self.stickno), self.dev_sn, bad, what))
        self.kill()                      # nur der eben gestartete eigene Prozess dieses Planers
        raise RuntimeError("Index-Pruefung: %s" % bad)
    return r


def _wd2_absent(pl):
    return _air2_orig_wd2_absent(pl) or (_air_pl(pl) is not None and _air2_dup(pl))   # doppelte SN: Watchdog wartet wie bei fehlendem Stick


def _wd2_abs_tick(pl, s, i, now, msgs):
    if not (_air_pl(pl) is not None and _air2_dup(pl)):
        return _air2_orig_wd2_abs_tick(pl, s, i, now, msgs)
    if not i.get("abs"):
        i["abs"] = 1
        msgs.append(("wd_block", "%s: %s (SN %s) – Watchdog wartet, keine Aktion · %s" % (_wd_name(s["n"], i), str(pl.pin_err)[:60], cfg_serial(pl.cfg), AIR2_SN_HINT), i.get("ch"), "rot"))
    i["block"] = AIR2_DUP_TXT
    _WD["dirty"] = True
    return True


AIR2_ROLE_SHORT = {"11D": "11D", "5C": "5C", "hobby": "Hobby", "": "ohne Rolle"}


def air2_label(name, role):
    """Anzeige-Name aus dem Register: 'Airspy R2 · 11D', 'Stick 1 · 5C', 'Stick 2 · Hobby', 'Stick 3 · ohne Rolle'."""
    sh = AIR2_ROLE_SHORT.get(role or "", str(role))
    n = " ".join(str(name or "?").split())
    return n if n.endswith(" · " + sh) else "%s · %s" % (n, sh)


def _air2_unk_names(out):
    """Geraete ohne Register-Eintrag: RTL -> 'Stick N' (N nach den Register-Namen 'Stick k'), Airspy -> 'Airspy SN ...'; Register-Name bleibt."""
    used = set()
    for e in out:
        m = re.match(r"^Stick (\d+)$", str(e.get("name") or ""))
        if m and not e.get("unreg"):
            used.add(int(m.group(1)))
    k = max(used or {0})
    for e in out:
        if e.get("unreg") and e.get("kind") == "rtl":
            k += 1
            e["name"] = "Stick %d" % k


def _air2_unk_log(pl, out):
    try:
        if getattr(pl, "main", None) is not None:
            return
        cur = dict((str(e.get("serial") or "?"), e) for e in out if not e.get("role") and e.get("present"))
        old = _AIR2.get("unk")
        _AIR2["unk"] = dict((k, e["label"]) for k, e in cur.items())
        if old is None:
            old = {}
            pre = " (beim Start)"
        else:
            pre = ""
        for k, e in cur.items():
            if k not in old:
                pl.log("sdrAir2: %s (SN %s, USB %s) angesteckt%s - erkannt, ohne Rolle, nie benutzt%s" % (e["label"], k, e.get("usb"), pre, (" · " + e["hint"]) if e.get("hint") else ""))
        for k, lb in old.items():
            if k not in cur:
                pl.log("sdrAir2: %s (SN %s) abgezogen" % (lb, k))
    except Exception as ex:
        print("sdrAir2 Geraete-Journal:", ex, flush=True)


def _air2_masts_rx(pl):
    try:
        r = _AIR["bases"].get(getattr(pl, "base", None)) or {}
        by = r.get("by_role") or {}
        if not by or _AIR2.get("masts_rx") == getattr(pl, "base", None):
            return
        _AIR2["masts_rx"] = pl.base
        lb = lambda ro: air2_label(by[ro]["name"], ro) if ro in by else None
        if lb("11D") and "11D" in MASTS_DB:
            MASTS_DB["11D"]["rx"] = "%s fest (BR Bayern)" % lb("11D")
        if lb("5C") and "5C" in MASTS_DB:
            MASTS_DB["5C"]["rx"] = "%s fest (ASA DE, Warnungen)" % lb("5C")
        if T4_CH_FB in MASTS_DB:
            MASTS_DB[T4_CH_FB]["rx"] = " · ".join(x for x in (("%s Rückfall, wenn 5C nach 2 Prüfungen keinen Sync hat" % lb("5C")) if lb("5C") else None,
                                                              ("%s Prüfung alle %d h" % (lb("hobby"), AIR2_P10_EVERY_S // 3600)) if lb("hobby") else None) if x)
    except Exception as ex:
        print("sdrAir2 Masten-Text:", ex, flush=True)


def air_devs(pl, now=None):
    out = _air2_orig_air_devs(pl, now)
    try:
        regsn = set((e["kind"], e["serial"]) for e in (_AIR["bases"].get(getattr(pl, "base", None)) or {}).get("devs") or [])
        for e in out:
            e["unreg"] = (e.get("kind"), e.get("serial")) not in regsn
        _air2_unk_names(out)
        for e in out:
            e["label"] = air2_label(e.get("name"), e.get("role") or "")
    except Exception as ex:
        print("sdrAir2 Geraete-Namen:", ex, flush=True)
    try:
        ids = tuple(x for v in DEV_KIND_USB.values() for x in v)
        cnt = {}
        for x in stick_info(ids):
            k = _air_kind(x.get("usb"))
            key = (k, _air_sn(k, x.get("serial")))
            cnt[key] = cnt.get(key, 0) + 1
        for e in out:
            n = cnt.get((e.get("kind"), e.get("serial") or ""), 0)
            if n > 1:
                e.update(dup=n, state="doppelte Seriennummer (%d Geräte) – nicht benutzt" % n, hint=AIR2_SN_HINT)
            elif e.get("kind") == "rtl" and not e.get("role") and str(e.get("serial") or "") in AIR2_FACTORY_SN:
                e["hint"] = "Werks-Seriennummer %s – nie benutzt; vor Einsatz %s" % (e.get("serial") or "leer", AIR2_SN_HINT)
            elif not e.get("role"):
                e.setdefault("hint", "nie benutzt (keine Rolle in sdr_config.json devs)")
    except Exception as ex:
        print("sdrAir2 Geraete:", ex, flush=True)
    _air2_unk_log(pl, out)
    _air2_masts_rx(pl)
    return out


_air2_orig_stick2_info = Planner.stick2_info


def _air2_stick2_info(self):
    r = _air2_orig_stick2_info(self)
    try:
        if _air_pl(self) is not None and isinstance(r, dict) and r.get("model") and str(r.get("txt") or "").startswith(str(r["model"]) + " SN"):
            r = dict(r)
            r["txt"] = air2_label(r["model"], "5C") + r["txt"][len(str(r["model"])):]
            r["label"] = air2_label(r["model"], "5C")
    except Exception as ex:
        print("sdrAir2 stick2_info:", ex, flush=True)
    return r


_air2_orig_air_reg = air_reg


def air_reg(cfg):
    """sdrAir2: RTL mit Werks-Seriennummer (00000000/00000001/leer) bekommt nie eine Rolle (kann jederzeit doppelt sein) -> ohne Rolle + Hinweis."""
    try:
        if isinstance(cfg, dict) and cfg.get("devs_on") is True and isinstance(cfg.get("devs"), list):
            bad = [x for x in cfg["devs"] if isinstance(x, dict) and x.get("kind") == "rtl" and x.get("role") and str(x.get("serial") or "").strip() in AIR2_FACTORY_SN]
            if bad:
                devs = [dict(x, role="") if x in bad else x for x in cfg["devs"]]
                r = _air2_orig_air_reg(dict(cfg, devs=devs))
                if r is not None:
                    for x in bad:
                        t = "SN %s ist eine Werks-Seriennummer -> ohne Rolle (%s); %s" % (str(x.get("serial") or "leer"), x.get("role"), AIR2_SN_HINT)
                        if t not in r["err"]:
                            r["err"].append(t)
                return r
    except Exception as ex:
        print("sdrAir2 Register:", ex, flush=True)
    return _air2_orig_air_reg(cfg)


Planner.start = _air2_start
Planner.stick2_info = _air2_stick2_info


def selftest_sdrair2():
    import tempfile
    keep = {k: os.environ.get(k) for k in ("SDR_SYSFS_USB", "SDR_WD_HELPER", "SDR_SOAPY_MODDIRS")}
    gl = {k: globals()[k] for k in ("_wd_helper", "list_sticks", "_air2_orig_start")}
    snap = (dict(_AIR["names"]), dict(_AIR["kinds"]), dict(_AIR["bases"]), dict(_AIR2), dict((k, MASTS_DB[k].get("rx")) for k in ("11D", "5C", "10C") if k in MASTS_DB))
    os.environ["SDR_WD_HELPER"] = "/nonexistent/sdrair2-selftest"     # echtes Hilfsprogramm nie
    calls = []
    try:
        _WD["live"] = True
        r = _selftest_sdrair2(tempfile.mkdtemp(prefix="sdrair2-"), calls)
    finally:
        globals().update(gl)
        for k, v in keep.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        _AIR["names"], _AIR["kinds"], _AIR["bases"] = snap[0], snap[1], snap[2]
        _AIR["cache"], _AIR["closed"] = {}, set()
        _AIR2.clear()
        _AIR2.update(snap[3], hclosed=set(), nfix=set(), soapy_t=0.0, soapy_where=None, soapy=None, unk=None, masts_rx=None)
        for k, v in snap[4].items():
            MASTS_DB[k]["rx"] = v
        _T2_TO.clear()
        _WD.update(d=None, base=None, dirty=False, saved=0.0, busy=None, cfg=None, cfg_key=None, started=set(), helper=None, boot_msgs=[], live=False, start=time.time())
    print("selftest sdrAir2 ok (Hobby nur Beobachtung: RDS ueber alle Sender, %d leere Fenster -> Hinweis, kein Neustart/USB/Pi-Neustart, alter Vorfall Bayern 1 geschlossen; "
          "Namen statt Platznummern (gespeicherte n korrigiert); sdrTeil2-Zeile Register; CPU je Kern; SoapySDR nur per air_fe mit Stufen-Tabelle 16->28 und Rueckfall -F airspy; Hobby-Pruefung 10C alle 6 h nur am Hobby-Stick, letzter Sync in p10c, kein Vorfall; RTL-Index nach Start gegen SN geprueft (dritter Stick), doppelte SN = nicht benutzt, keine Aktion, Werks-SN-Hinweis; Anzeige-Namen Name · Rolle, Stick 3 · ohne Rolle, Ein-/Abstecken einmal im Journal; %d Fake-Aufrufe)"
          % (AIR2_HOBBY_FAIL_N, r), flush=True)


def _selftest_sdrair2(tmp, calls):
    AS = "637862DC2E8092D7"
    root = os.path.join(tmp, "sys")
    os.environ["SDR_SYSFS_USB"] = root
    os.environ["SDR_SOAPY_MODDIRS"] = os.path.join(tmp, "nosoapy")

    def mk(n, vid, pid, sn, prod):
        d = os.path.join(root, n)
        os.makedirs(d)
        for k, v in (("idVendor", vid), ("idProduct", pid), ("serial", sn), ("product", prod)):
            open(os.path.join(d, k), "w").write(v + "\n")
    mk("1-1.1", "0bda", "2838", "19348831", "RTL2838UHIDIR")
    mk("1-1.2", "0bda", "2838", "72055505", "RTL2838UHIDIR")
    mk("1-1.3", "1d50", "60a1", "AIRSPY SN:%s" % AS.lower(), "AIRSPY")
    devs = [{"name": "Airspy R2", "kind": "airspy", "usb": "1d50:60a1", "serial": AS, "role": "11D"},
            {"name": "Stick 1", "kind": "rtl", "usb": "0bda:2838", "serial": "19348831", "role": "5C", "ppm_sfx": ""},
            {"name": "Stick 2", "kind": "rtl", "usb": "0bda:2838", "serial": "72055505", "role": "hobby", "ppm_sfx": "2"}]
    write_json(os.path.join(tmp, "sdr_config.json"), {"devs_on": True, "devs": devs, "air_nice": 0, "air_fe": "airspy"})
    t0 = time.time()
    # Stand wie live 23:18: alte Platznummern (Stick 2 n 2, Airspy fehlt), offener Hobby-Vorfall RDS Bayern 1
    write_json(os.path.join(tmp, "sdr_wd.json"), {"v": 1, "t": int(t0) - 60, "sticks": {
        "72055505": {"n": 2, "last_ok": int(t0) - 600, "last_ok_src": "RDS Bayern 3", "last_check": int(t0) - 540, "fail_n": 1, "src": "rds", "ch": "Bayern 1",
                     "inc": {"since": int(t0) - 600, "t0": int(t0) - 600, "ch": "Bayern 1", "src": "rds", "restart_n": 0, "usb_n": 0, "reboot_n": 0, "chk": 1, "v2": 1, "to": 0, "pre": 0}},
        "19348831": {"n": 1, "last_ok": int(t0) - 100, "last_ok_src": "DAB 11D", "last_check": int(t0) - 100, "src": "dab", "ch": "11D"}}})
    m = Planner(tmp)
    w = Planner(tmp, stick=2, main=m)
    h = Planner(tmp, stick=3, main=m)
    m.worker, m.hobbies, m.t2 = w, [h], True
    logs = []
    for x in (m, w, h):
        x.log = lambda *a: logs.append(" ".join(str(y) for y in a))
        x.tools = {"welle": "/usr/bin/welle-cli", "redsea": "/usr/bin/redsea"}
        x.kill = lambda: calls.append(["kill"])
    assert air2_t2_txt(m).startswith("aktiv im Geraete-Register") and "Alarm-Uebernahme" not in air2_t2_txt(m) and "Airspy R2 fest 11D" in air2_t2_txt(m)
    assert air2_t2_txt(Planner(os.path.join(tmp, "x"))).endswith("Alarm-Uebernahme 5C")
    ev = lambda: (load_json(os.path.join(tmp, "sdr_techlog.json"), {}) or {}).get("ev") or []
    globals()["_wd_helper"] = lambda args, timeout: (calls.append(list(args)), (0, "ok"))[1]
    _WD["start"] = t0 - 3600
    _AIR["closed"], _AIR2["hclosed"], _AIR2["nfix"] = set(), set(), set()
    # 1) Start: alter Hobby-Vorfall zu, Namen richtig (kein "Stick 1 · Bayern 1"), gespeicherte n korrigiert
    wd_tick(h, t0)
    d = _wd_state(tmp, t0)
    assert d["sticks"]["72055505"]["inc"] is None and d["sticks"]["72055505"]["n"] == 3 and d["sticks"]["19348831"]["n"] == 2, d["sticks"]
    tx = [x["text"] for x in ev()]
    assert any(x.startswith("Stick 2 · Hobby: alter Vorfall Bayern 1") for x in tx) and not any("Stick 1 · Bayern 1" in x for x in tx), tx
    wd_tick(h, t0 + 1)
    assert len([x for x in ev() if "alter Vorfall" in x["text"]]) == 1
    # 2) Hobby-RDS rotiert: ein Sender leer = kein Vorfall; irgendein RDS = ok
    for k, (c, ok) in enumerate((("BR24", True), ("Bayern 3", True), ("Bayern 1", False), ("BR24", True), ("Bayern 3", True), ("Bayern 1", False))):
        wd_check(h, "rds", ok, t0 + 60 * (k + 1), c, None if ok else "0 RDS-Gruppen in 60 s")
        wd_tick(h, t0 + 60 * (k + 1) + 1)
    assert _wd_state(tmp, t0)["sticks"]["72055505"]["inc"] is None and wd_view(h, t0 + 400)["lvl"] == "ok" and "RDS ok" in wd_view(h, t0 + 400)["txt"], wd_view(h, t0 + 400)
    # 3) alle Sender leer -> nach 3 Fenstern Hinweis, nur Beobachtung; 2 h lang keine Aktion
    for k, c in enumerate(("BR24", "Bayern 3", "Bayern 1")):
        wd_check(h, "rds", False, t0 + 600 + 60 * k, c, "0 RDS-Gruppen in 60 s")
    i = _wd_state(tmp, t0)["sticks"]["72055505"]["inc"]
    assert i and i["ch"] == "RDS" and i["block"] == AIR2_HOBBY_BLOCK, i
    for k in range(0, 7200, 60):
        wd_tick(h, t0 + 900 + k)
    i = _wd_state(tmp, t0)["sticks"]["72055505"]["inc"]
    assert i and not i.get("restart_n") and not i.get("usb_n") and not calls, (i, calls)
    v = wd_view(h, t0 + 8200)
    assert v["watch"] and v["lvl"] == "gelb" and "nur Beobachtung, keine Aktion" in v["txt"] and v["txt"].startswith("Stick 2 · Hobby") and v["stage"] == 0, v
    assert all(_wd_block(h, t0, "72055505", x) == AIR2_HOBBY_BLOCK for x in (None, "restart", "usb", "reboot"))
    assert "Hobby" not in str(_wd_block(w, t0, "19348831", "restart") or "")
    wd_check(h, "rds", True, t0 + 8300, "Bayern 3")
    assert _wd_state(tmp, t0)["sticks"]["72055505"]["inc"] is None and any("RDS wieder da (Bayern 3)" in x["text"] for x in ev())
    # 4) Hobby fehlt -> grau nicht angeschlossen, keine Aktion
    os.rename(os.path.join(root, "1-1.2", "idVendor"), os.path.join(root, "1-1.2", "x"))
    h.want = lambda mode, now: "idle"
    h.step()
    v = wd_view(h, t0 + 8400)
    assert v["lvl"] == "grau" and v["short"] == "Stick 2 nicht angeschlossen (SN 72055505) – keine Aktion" and v["watch"], v
    os.rename(os.path.join(root, "1-1.2", "x"), os.path.join(root, "1-1.2", "idVendor"))
    h.step()
    # 5) Namen in Meldungen: Pi-Neustart-Freigabe/Kalibrierung/Rolle mit Geraetenamen
    assert air_name(1) == "Airspy R2" and air_name(3) == "Stick 2"
    w.role = "x"
    w.set_role("rot")
    assert any(x.startswith("Stick 1: Rolle x -> rot") for x in logs), logs[-3:]
    # 6) CPU je Kern
    assert m.cfg["air_cpu_max"] == 120

    class P:
        pid = os.getpid()
        poll = staticmethod(lambda: None)
    m.procs = [P()]
    _air_cpu_tick(m, t0)
    c2 = _air_cpu_tick(m, t0 + 2)
    assert c2["cores"] >= 1 and "eines Kerns" in c2["txt"] and c2["pct_all"] <= c2["pct"], c2
    m.procs = []
    # 7) Airspy: Standard -F airspy unveraendert; SoapySDR nur per air_fe soapy, Modul fehlt -> Rueckfall
    m.resolve()
    assert m._cmd_dab("11D") == [["/usr/bin/welle-cli", "-c", "11D", "-C", "1", "-w", "7979", "-F", "airspy", "-g", "16"]]
    assert air2_fe_txt(m) == "welle-cli -F airspy"
    m.cfg["air_fe"] = "soapy"
    _AIR2["soapy_t"] = 0
    assert m._cmd_dab("11D")[0][7:] == ["-F", "airspy", "-g", "16"] and "fehlt" in air2_fe_txt(m), m._cmd_dab("11D")
    md = os.path.join(tmp, "soapy", "SoapySDR", "modules0.8")
    os.makedirs(md)
    open(os.path.join(md, "libairspySupport.so"), "w").close()
    os.environ["SDR_SOAPY_MODDIRS"] = os.path.join(tmp, "soapy")
    _AIR2["soapy_t"] = 0
    m.__dict__.pop("_air2_fs", None)
    a = m._cmd_dab("11D")[0]
    assert a[7:] == ["-F", "soapysdr", "-s", "driver=airspy,serial=%s" % AS.lower(), "-g", "28"] and m._dg_used["db"] == "Airspy-Stufe 16 (SoapySDR 28)", a
    assert AIR2_SOAPY_GAIN[16] == 28 and AIR2_SOAPY_GAIN[12] == 19 and AIR2_SOAPY_GAIN[19] == 36 and AIR2_SOAPY_GAIN[9] == 15 and AIR2_SOAPY_GAIN[21] == 39
    wd_check(m, "dab", True, t0 + 9000, "11D")                                       # Sync -> bleibt SoapySDR
    for k in range(5):
        assert m._cmd_dab("11D")[0][8] == "soapysdr"
        wd_check(m, "dab", True, t0 + 9001 + k, "11D")
    for k in range(AIR2_SOAPY_MAX_STARTS - 1):                                       # ohne Sync: noch SoapySDR
        assert m._cmd_dab("11D")[0][8] == "soapysdr"
    assert m._cmd_dab("11D")[0][8] == "soapysdr"
    a = m._cmd_dab("11D")[0]
    assert a[7:] == ["-F", "airspy", "-g", "16"] and "ohne Sync" in air2_fe_txt(m) and any("zurueck auf welle-cli -F airspy" in x for x in logs), (a, air2_fe_txt(m))
    assert m._cmd_dab("11D")[0][7:] == ["-F", "airspy", "-g", "16"]
    m.cfg["air_fe"] = "airspy"
    m.__dict__.pop("_air2_fs", None)
    st = m.status({"mode": "auto"}, write=False)
    assert st["dev"]["fe"] == "welle-cli -F airspy", st["dev"]
    # 8) Hobby-Pruefung 10C alle 6 h: nur am Hobby-Stick, zuletzt im Hobby-Block, Ergebnis in broadcast_state p10c, kein Watchdog-Vorfall
    tn = time.time()
    h.pin_err, h.last_bc, h.role = None, 0, "rot"
    assert "10C" not in [str(x) for x in h.dab_list()] and air2_p10_txt(h, tn).endswith("noch nicht gelaufen")
    q = h.bc_queue()
    i10 = [str(x) for x in h.dab_list()].index("10C")
    assert q and q[-1] == ("dab:%d" % i10, 60.0) and all(j.startswith("rds:") for j, _ in q[:-1]), q
    for x in (m, w):
        assert not any(j.startswith("dab:") and str(x.dab_list()[int(j[4:])]) == "10C" for j, _ in x.bc_queue()) and "10C" not in [str(y) for y in x.dab_list()] or x is w, (x.stickno, x.bc_queue())
    h.sbc.d["dab"]["10C"] = {"ch": "10C", "t": int(tn), "rx": True, "demod": {"snr": 12.5, "fic_rate": 0.0}}
    h.sbc.d.setdefault("t2", {}).setdefault("fig", {})["10C"] = {"t": int(tn), "ens": "Nuernberg", "tii": [{"main": 3, "sub": 1, "mast": "Nuernberg (Schweinau)"}]}
    h.since, h.procs = tn - 60, []
    sp = {"kind": "bc", "queue": [j for j, _ in q], "durs": [d for _, d in q], "i": len(q) - 1, "sub_end": tn, "hard_end": tn + 30, "t0": tn - 240}
    h.sub_done(sp, tn)
    r = m.sbc.d.get("p10c") or {}
    assert r.get("ok") is True and r.get("t_sync") == int(tn) and r.get("snr") == 12.5 and r["sn"] == "72055505" and r["tii"][0]["mast"].startswith("Nuernberg") and r["n"] == 1, r
    assert h.__dict__.get("_air2_p10t") is None and "10C" not in [str(x) for x in h.dab_list()]
    assert (_wd_state(tmp, tn)["sticks"].get("72055505") or {}).get("inc") is None and any("Hobby-Pruefung 10C: Sync" in x for x in logs), logs[-2:]
    assert "10C-Prüfung alle 6 h: Sync" in wd_view(h, tn)["txt"] and not any(j.startswith("dab:") for j, _ in h.bc_queue()), wd_view(h, tn)["txt"]
    m.sbc.d["p10c"]["t_check"] = int(tn) - AIR2_P10_EVERY_S - 10
    h.sbc.d["dab"]["10C"] = {"ch": "10C", "t": int(tn) - 3600, "rx": False, "try_t": int(tn), "rx_why": "kein Sync: Ensemble leer", "demod": {"snr": 1.0}}
    q = h.bc_queue()
    assert q[-1][0] == "dab:%d" % [str(x) for x in h.dab_list()].index("10C")
    wd_check(h, "dab", False, tn + 1, "10C", "kein Sync, SNR 1.0")
    r = m.sbc.d["p10c"]
    assert r["ok"] is False and r["t_sync"] == int(tn) and r["n"] == 2 and r["n_ok"] == 1 and len(r["hist"]) == 2 and "letzter Sync" in air2_p10_txt(h, tn + 2), r
    assert (_wd_state(tmp, tn)["sticks"].get("72055505") or {}).get("inc") is None
    h.__dict__["_air2_p10t"] = None
    m.sbc.d["p10c"]["t_check"] = 0
    h.cfg["hobby_10c"] = False
    assert not any(j.startswith("dab:") for j, _ in h.bc_queue()) and air2_p10_txt(h, tn) == "10C-Prüfung aus"
    h.cfg["hobby_10c"] = True
    # 9) RTL-Index nach dem Start gegen die Seriennummer pruefen (dritter Stick angesteckt, Reihenfolge verschoben)
    L = lambda *sn: [{"idx": k, "name": "Generic RTL2832U OEM", "sn": x} for k, x in enumerate(sn)]
    fake = {"lst": L("19348831", "72055505")}
    globals()["list_sticks"] = lambda timeout=12: (fake["lst"], None)

    class Q:
        pid = 0
        poll = staticmethod(lambda: None)

    def fstart(self, what):
        self.resolve()
        self.procs = [Q()]
    globals()["_air2_orig_start"] = fstart
    h.cfg["dev_kind"] = "rtl"
    h.start("rds:0")
    assert h.dev_idx == 1 and h.procs, h.dev_idx
    nk = len(calls)
    fake["lst"] = L("19348831", "72055505")
    orig_res = h.resolve
    h.resolve = lambda: (orig_res(), fake.update(lst=L("00000001", "19348831", "72055505")))[0]   # Stick kommt zwischen Liste und Start
    try:
        h.start("rds:0")
        raise AssertionError("Index-Verschiebung nicht erkannt")
    except RuntimeError as ex:
        assert "Index 1 ist jetzt SN 19348831 statt 72055505" in str(ex) and calls[nk:] == [["kill"]], (ex, calls[nk:])
    h.resolve = orig_res
    h.start("rds:0")
    assert h.dev_idx == 2 and _air2_idx_bad(h, fake["lst"]) is None
    assert _air2_idx_bad(h, None) is None and _air2_idx_bad(h, L("19348831", "", "72055505")) is None    # unklare Liste: nichts tun
    h.list_n = 1
    assert "statt 1" in _air2_idx_bad(h, L("72055505", "00000001"))
    h.list_n = 3
    fake["lst"] = L("00000001", "72055505", "72055505")
    try:
        h.start("rds:0")
        raise AssertionError("doppelt nicht erkannt")
    except RuntimeError as ex:
        assert "doppelte Seriennummer" in str(ex), ex
    nk = len(calls)
    m.start("dab:0")                                                  # Airspy: keine RTL-Liste
    assert len(calls) == nk
    h.procs = []
    # 10) doppelte Seriennummer am Stick 1 (5C) + Werks-SN 00000001: nicht benutzt, Watchdog wartet, klarer Hinweis, keine Aktion
    mk("1-1.4", "0bda", "2838", "19348831", "RTL2838UHIDIR")
    mk("1-1.5", "0bda", "2838", "00000001", "RTL2838UHIDIR")
    w.want = lambda mode, now: "idle"
    w.step()
    assert w.pin_err.startswith("doppelte Seriennummer 19348831") and _wd2_absent(w) and not _wd2_absent(h), w.pin_err
    tw = time.time()
    for k in range(0, 4 * 3600, 60):
        wd_tick(w, tw + k)
    v = wd_view(w, tw + 4 * 3600)
    assert v["lvl"] == "rot" and v["dup"] and v["stage"] == 0 and "rtl_eeprom" in v["hint"] and "keine Aktion" in v["txt"], v
    i = (_wd_state(tmp, tw)["sticks"].get("19348831") or {}).get("inc") or {}
    assert not i.get("restart_n") and not i.get("usb_n") and not i.get("reboot_n") and not [c for c in calls if c != ["kill"]], (i, calls)
    dv = dict((x["serial"], x) for x in air_devs(m))
    assert dv["19348831"]["state"].startswith("doppelte Seriennummer (2") and "Werks-Seriennummer 00000001" in dv["00000001"]["hint"] and dv["00000001"]["state"] == "erkannt, ohne Rolle", dv
    assert dv["72055505"]["state"] != "erkannt, ohne Rolle" and not dv["72055505"].get("dup")
    assert dv["00000001"]["name"] == "Stick 3" and dv["00000001"]["label"] == "Stick 3 · ohne Rolle" and dv["72055505"]["label"] == "Stick 2 · Hobby" and dv[AS]["label"] == "Airspy R2 · 11D", dv
    assert air2_label("Stick 1", "5C") == "Stick 1 · 5C" and air2_label("Stick 1 · 5C", "5C") == "Stick 1 · 5C"
    assert "Stick 1 · 5C fest" in MASTS_DB["5C"]["rx"] and "Stick 2 · Hobby Prüfung alle 6 h" in MASTS_DB["10C"]["rx"], MASTS_DB["10C"]["rx"]
    nl = len(logs)
    air_devs(m)
    assert len(logs) == nl                                           # nur einmal je Ein-/Abstecken
    rr = air_reg({"devs_on": True, "devs": devs[:2] + [{"name": "Stick 3", "kind": "rtl", "usb": "0bda:2838", "serial": "00000001", "role": "hobby"}]})
    assert rr is not None and "hobby" not in rr["by_role"] and [e["role"] for e in rr["devs"]][2] == "" and any("Werks-Seriennummer" in x for x in rr["err"]), rr
    assert air_reg({"devs_on": True, "devs": devs})["by_role"]["hobby"]["serial"] == "72055505"
    for n in ("1-1.4", "1-1.5"):
        os.rename(os.path.join(root, n, "idVendor"), os.path.join(root, n, "x"))
    w.step()
    assert w.pin_err is None and not _wd2_absent(w)
    air_devs(m)
    assert any("Stick 3 · ohne Rolle (SN 00000001) abgezogen" in x for x in logs), logs[-4:]
    assert w.stick2_info is not None and m.stick2_info()["txt"].startswith("Stick 1 · 5C SN 19348831"), m.stick2_info()
    assert not [c for c in calls if c != ["kill"]], calls
    return len(calls)
AB2_EOF
EXPECT_ASM2="0742bfe91048cd7287bc93c7e4df579e956af2e1e224faf6f4037b7c8503c2c1"
cat > "$W/air2_sm_block.py" << 'AS2_EOF'
# ===== sdrAir2: Daten-Watchdog-Zusammenfassung ehrlich mit Geraetenamen - Hobby-Geraet eigene Zeile (nur Beobachtung), nicht in der Gesamtstufe; noch nicht gepruefte Geraete "wird geprüft" statt "alle ok"; Anzeige-Namen 'Name · Rolle' (Funk-Lage, Zusammenfassung); nur lesen/rechnen =====
_air2_orig_wd_status = wd_status


AIR2_ROLE_SHORT = {"11D": "11D", "5C": "5C", "hobby": "Hobby", "": "ohne Rolle"}
_air2_orig_t4_sdr = t4_sdr


def air2_label(name, role):
    sh = AIR2_ROLE_SHORT.get(role or "", str(role))
    n = " ".join(str(name or "?").split())
    return n if n.endswith(" · " + sh) else "%s · %s" % (n, sh)


def _air2_nm(s):
    n = s.get("name") or "Stick %s" % s.get("n")
    return air2_label(n, s.get("role")) if s.get("role") else n


def t4_sdr(base, now=None):
    r = _air2_orig_t4_sdr(base, now)
    try:
        if r.get("air"):
            for k, ro in (("s1", "11D"), ("s2", "5C"), ("s3", "hobby")):
                x = r.get(k)
                if isinstance(x, dict) and x.get("name"):
                    x["dev_name"] = x.get("dev_name") or x["name"]
                    x["name"] = air2_label(x["dev_name"], ro)
                    if isinstance(x.get("state"), str) and x["state"].startswith(x["dev_name"] + " nicht angeschlossen"):
                        x["state"] = x["name"] + x["state"][len(x["dev_name"]):]
    except Exception as e:
        print("sdr_manager sdrAir2 t4_sdr:", e, flush=True)
    return r


def wd_status(st, now=None):
    r = _air2_orig_wd_status(st, now)
    try:
        st = st if isinstance(st, dict) else {}
        raw = {}
        for k in ("stick_health", "stick_health2", "stick_health3"):
            h = st.get(k) if isinstance(st.get(k), dict) else {}
            v = h.get("wd") if isinstance(h.get("wd"), dict) else None
            if v and v.get("sn"):
                raw[v["sn"]] = v
        sticks = r.get("sticks") or []
        for s in sticks:
            v = raw.get(s.get("sn")) or {}
            s["role"] = v.get("role")
            s["watch"] = bool(v.get("watch")) or v.get("role") == "hobby"
            s["name"] = s.get("name") or v.get("name")
        if not r.get("fresh") or not any(s.get("role") for s in sticks):
            return r                                          # ohne Geraete-Register bzw. alter Stand: wie bisher
        main = [s for s in sticks if not s["watch"]]
        hob = [s for s in sticks if s["watch"]]
        stopped = any(isinstance(v.get("g"), dict) and v["g"].get("stopped") for v in raw.values())
        pres = [s for s in main if not s.get("absent")]
        bad = [s for s in pres if s.get("lvl") in ("gelb", "rot")]
        parts = []
        for s in main:
            if s.get("absent"):
                parts.append("%s nicht angeschlossen" % _air2_nm(s))
            elif s.get("lvl") == "ok":
                parts.append("%s ok" % _air2_nm(s))
            elif s.get("lvl") == "grau":
                parts.append("%s wird geprüft" % _air2_nm(s))
            else:
                parts.append(s.get("short") or s.get("txt") or _air2_nm(s))
        if bad:
            worst = max(bad, key=lambda v: (WD_LVL_ORDER.get(v.get("lvl"), 0), -(v.get("n") or 9)))
            lvl, txt = worst["lvl"], worst.get("txt") or "?"
            short = worst.get("short") or "SDR läuft, %s ohne Empfang seit %s" % (worst.get("ch") or _air2_nm(worst), _wd_hm(worst.get("since"), now or time.time()))
        elif not pres:
            lvl, txt = "grau", " · ".join(parts) or "kein Gerät angeschlossen"
            short = txt
        elif any(s.get("lvl") != "ok" for s in pres):
            lvl, txt = "grau", " · ".join(parts)              # mindestens ein Geraet seit Start noch nicht geprueft
            short = txt
        else:
            lvl = "ok"
            txt = "alle Geräte mit echtem Empfang: " + " · ".join(parts)
            short = " · ".join(parts) if any(s.get("absent") for s in main) else None
        if stopped:
            lvl = "rot"
            short = (short or "SDR ohne Empfang") + " – Stick/Antenne prüfen (keine weiteren Pi-Neustarts)"
        hb = hob[0] if hob else None
        r.update(lvl=lvl, color=WD_LVL_COLOR.get(lvl, "#94a3b8"), txt=txt, short=short,
                 hobby={"name": hb.get("name") or _air2_nm(hb), "label": _air2_nm(hb), "lvl": hb.get("lvl"), "txt": hb.get("txt"), "absent": bool(hb.get("absent")), "watch": True} if hb else None)
    except Exception as e:
        print("sdr_manager sdrAir2 Zusammenfassung:", e, flush=True)
    return r


def selftest_sdrair2():
    now = int(time.time())
    g = {"reboots_today": 0, "last_reboot": None, "reboot_fail_n": 0, "reboot_max_fail": 3, "stopped": False, "pending": None, "on": True, "helper": "bereit", "cfg": {}}
    a = {"sn": "637862DC2E8092D7", "n": 1, "name": "Airspy R2", "role": "11D", "lvl": "ok", "ch": "11D", "src": "dab", "txt": "Airspy R2 · 11D Empfang ok (zuletzt 23:18)", "g": g}
    s1 = {"sn": "19348831", "n": 2, "name": "Stick 1", "role": "5C", "lvl": "ok", "ch": "5C", "src": "dab", "txt": "Stick 1 · 5C Empfang ok (zuletzt 23:18)", "g": g}
    h = {"sn": "72055505", "n": 3, "name": "Stick 2", "role": "hobby", "watch": True, "lvl": "gelb", "ch": "RDS", "src": "rds", "since": now - 3600,
         "txt": "Stick 2 · Hobby: kein RDS seit 22:11 (BR24, Bayern 3, Bayern 1) · nur Beobachtung, keine Aktion", "short": "Stick 2 · Hobby: kein RDS seit 22:11 – nur Beobachtung", "g": g}
    W = lambda x, y, z: {"t": now, "stick_health": {"wd": x}, "stick_health2": {"wd": y}, "stick_health3": {"wd": z}}
    s = wd_status(W(a, s1, h), now)                        # Hobby ohne RDS: Gesamt bleibt ok, eigene Zeile
    assert s["lvl"] == "ok" and s["txt"] == "alle Geräte mit echtem Empfang: Airspy R2 · 11D ok · Stick 1 · 5C ok" and s["short"] is None, s
    assert s["hobby"]["name"] == "Stick 2" and s["hobby"]["label"] == "Stick 2 · Hobby" and s["hobby"]["lvl"] == "gelb" and "nur Beobachtung" in s["hobby"]["txt"] and len(s["sticks"]) == 3 and s["sticks"][2]["watch"], s
    s = wd_status(W(dict(a, lvl="grau", txt="Airspy R2 · 11D noch keine Prüfung seit Start"), s1, dict(h, lvl="ok")), now)   # Airspy noch ungeprueft: nicht "alle ok"
    assert s["lvl"] == "grau" and s["txt"] == "Airspy R2 · 11D wird geprüft · Stick 1 · 5C ok" and "alle" not in s["txt"], s
    s = wd_status(W(a, dict(s1, lvl="rot", since=now - 3000, short="SDR läuft, 5C ohne Empfang seit 22:30"), h), now)
    assert s["lvl"] == "rot" and s["short"] == "SDR läuft, 5C ohne Empfang seit 22:30", s
    s = wd_status(W(a, s1, dict(h, lvl="grau", absent=True, short="Stick 2 nicht angeschlossen (SN 72055505) – keine Aktion")), now)
    assert s["lvl"] == "ok" and s["hobby"]["absent"], s
    s = wd_status(W(dict(a, g=dict(g, stopped=True)), s1, h), now)
    assert s["lvl"] == "rot" and "keine weiteren Pi-Neustarts" in s["short"], s
    o = wd_status({"t": now, "stick_health": {"wd": {"sn": "19348831", "n": 1, "lvl": "ok", "txt": "Stick 1 · 11D Empfang ok", "g": g}}}, now)   # ohne Register wie bisher
    assert o["txt"] == "alle Sticks mit echtem Empfang" and "hobby" not in o, o
    s = wd_status(W(a, dict(s1, lvl="grau", absent=True, short="Stick 1 nicht angeschlossen (SN 19348831) – keine Aktion"), h), now)
    assert s["lvl"] == "ok" and s["short"] == "Airspy R2 · 11D ok · Stick 1 · 5C nicht angeschlossen", s
    orig = globals()["_air2_orig_t4_sdr"]
    globals()["_air2_orig_t4_sdr"] = lambda base, now=None: {"air": True, "s1": {"name": "Airspy R2"}, "s2": {"name": "Stick 1", "state": "Stick 1 nicht angeschlossen"}, "s3": {"name": "Stick 2"}}
    try:
        t = t4_sdr("/nonexistent")
    finally:
        globals()["_air2_orig_t4_sdr"] = orig
    assert t["s1"]["name"] == "Airspy R2 · 11D" and t["s2"]["name"] == "Stick 1 · 5C" and t["s2"]["state"] == "Stick 1 · 5C nicht angeschlossen" and t["s3"]["name"] == "Stick 2 · Hobby" and t["s2"]["dev_name"] == "Stick 1", t
    return "sdr_manager selftest sdrAir2 ok (Anzeige-Namen Name · Rolle, Zusammenfassung mit Geraetenamen, Hobby eigene Zeile nicht in Gesamtstufe, ungepruefte Geraete wird geprueft, Stopp rot, ohne Register unveraendert)"
AS2_EOF
EXPECT_AG2="e97add9f37c1b319fb7b03f12f6cad94c6858a94d24d07ddecd775dea21e9ec3"
cat > "$W/guard_air2.py" << 'AG2_EOF'
"""AST-Guard sdrAir2. Aufruf: guard_air2.py EDITS  ART ALT NEU BLOCK ...  (ART = sdr | sm; ALT = Stand nach sdrAir) -> 0 ok, 1 Verstoss.
Rueckbau (Block weg, Stellen zurueck) muss Byte fuer Byte ALT ergeben. Neuer Code: kein Prozess, kein Netz, kein shell, kein Faden, keine Sendewege, kein Hilfsprogramm,
keine Aktion (kill/Neustart/USB/Pi-Neustart; einzige Ausnahme: _air2_start beendet den eben gestarteten eigenen Prozess bei verschobenem RTL-Index); Dateizugriff nur lesend (listdir/isfile fuer das SoapySDR-Modul), Schreiben nur im Selbsttest (tempfile)."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode", "reboot", "_wd_helper", "_wd_do", "_air_usb",
       "unlink", "remove", "rmtree", "chmod", "chown", "setpriority", "thread", "restart", "usb")
err = []
a = sys.argv[2:]
done_all = True
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    if new.count(B.rstrip("\n")) != 1:
        err.append("%s: Block sdrAir2 fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sdrAir2" % (kind, len(E)))
    for o, n in E:
        ol = set(o.splitlines())
        low = "\n".join(x for x in n.splitlines() if x not in ol and not x.strip().startswith("assert ")).lower()   # Selbsttest-Zusicherungen ausgenommen
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread", "_wd_helper(", "_wd_do(",
                  "uhubctl", "unbind", "fetch(", "xmlhttprequest", "takeover_set(", "reboot", "kill(", "open("):
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
        fn = fn_of.get(id(n), "?")
        st = fn.startswith(("selftest", "_selftest"))
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if mod != "tempfile" or not st:
                    err.append("%s Block: Import %s" % (kind, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s Block: shell" % kind)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if st and nm in ("open", "makedirs", "rename", "close", "write", "mkdtemp"):
                continue                                       # Selbsttest: Fake-USB-Baum/Fake-Modul im Temp-Ordner
            if fn == "_air2_start" and nm == "kill" and base == "self":
                continue                                       # Index-Pruefung: nur den eben gestarteten eigenen Prozess beenden
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer", "open",
                                                           "rename", "makedirs", "write", "replace") and not (nm == "replace" and kind in ("sdr", "sm", "dsh")) \
                    or base in ("subprocess", "requests", "socket", "multiprocessing", "shutil"):
                err.append("%s Block: Aufruf %s in %s" % (kind, nm, fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and any(k in n.value for k in ("uhubctl", "/unbind", "bind_ports", "power/control", "/usr/local/sbin", "sudo")):
            err.append("%s Block: verbotener Text %s" % (kind, n.value[:40]))
    if kind == "sdr":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_wd_helper", "_wd_do", "wd_helper_state", "_wd_decide", "_wd_save", "_wd_emit", "_air_usb", "dabgain_step", "_air_gain_state"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sdr: Original %s veraendert" % fn)
        if new.count('WD_HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"') != 1:
            err.append("sdr: WD_HELPER-Pfad")
        if 'AIR_LADDER = (16, 12, 19, 9, 21, "agc")' not in new:
            err.append("sdr: Airspy-Gain-Leiter veraendert")
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard sdrAir2: nur %s Stellen + Bloecke; kein Prozess/Netz/shell/Faden/Sendeweg/Hilfsprogramm/Aktion im neuen Code; Watchdog-Aktionen, Gain-Leiter/-Logik (dabgain_step, _air_gain_state) und WD_HELPER unveraendert" % (
    "/".join("%d" % len(g["%s_EDITS" % a[i].upper()]) for i in range(0, len(a), 4))))
AG2_EOF
EXPECT_AC2="adde5e4a0655c46be9511c68bde4585b9f92960ddeed156e6d7b55a85e7e025a"
cat > "$W/air2check.py" << 'AC2_EOF'
"""sdrAir2 Pruefungen fuer apply-sdrair2.sh (nur lesen). proof DIR T0 | api JSON | state DIR | hobby DIR"""
import json
import os
import re
import sys
import time

hm = lambda t: time.strftime("%d.%m. %H:%M:%S", time.localtime(t)) if isinstance(t, (int, float)) else "–"


def newest(d, name, key):
    """sqlC: Stand primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
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
        if not best or float(j.get("t") or 0) > float(best.get("t") or 0):
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def devs(d):
    try:
        c = json.load(open(os.path.join(d, "sdr_config.json"), encoding="utf-8"))
    except Exception:
        return {}
    return {str(x.get("serial") or "").upper(): x for x in c.get("devs") or [] if isinstance(x, dict) and c.get("devs_on") is True}


def main(a):
    m = a[0]
    if m == "proof":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        a1 = next((x for x in st.get("devs") or [] if isinstance(x, dict) and x.get("role") == "11D"), {})
        sn = str(a1.get("serial") or "")
        e = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {})
        dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
        dev = st.get("dev") or {}
        cpu = dev.get("cpu") or {}
        ok = bool(sn) and e.get("rx") is True and float(e.get("t") or 0) >= t0 and dm.get("sn") == sn and float(dm.get("t") or 0) >= t0
        if not ok:
            print("11D-Sync vom Airspy noch nicht nachgewiesen (Airspy SN %s, 11D Empfang %s um %s, Messung von SN %s um %s, seit Start %s)" % (
                sn or "?", e.get("rx"), hm(e.get("t")), dm.get("sn"), hm(dm.get("t")), hm(t0)))
            return 1
        print("11D-Sync vom Airspy nachgewiesen: Empfang %s, SNR %s, FIC-Fehlerrate %s · %s · welle-cli CPU %s" % (
            hm(e.get("t")), dm.get("snr"), dm.get("fic_rate"), dev.get("fe") or "?", cpu.get("txt") or "noch nicht gemessen"))
        return 0
    if m == "api":
        w = json.load(open(a[1], encoding="utf-8"))
        ss = w.get("sticks") or []
        assert w.get("lvl") in ("ok", "gelb", "rot", "grau") and ss, str(w)[:200]
        assert all(s.get("name") for s in ss), "Geraet ohne Namen: %s" % [s.get("sn") for s in ss if not s.get("name")]
        reg = any(s.get("role") for s in ss)
        assert reg, "keine Rollen in /api/sdr/wd (sdr_manager alt?)"
        assert w.get("txt") != "alle Sticks mit echtem Empfang", "alte Sammelzeile"
        hb = [s for s in ss if s.get("watch")]
        assert all(s.get("role") == "hobby" for s in hb) and (not hb or isinstance(w.get("hobby"), dict)), "Hobby-Zeile fehlt"
        if w["lvl"] == "ok":
            assert not [s for s in ss if not s.get("watch") and not s.get("absent") and s.get("lvl") != "ok"], "Gesamt ok trotz ungepruefter Geraete"
        print("/api/sdr/wd (sdrAir2): %s · %s · %s" % (w["lvl"], (w.get("short") or w.get("txt") or "")[:140], " | ".join(
            "%s %s%s" % (s["name"], s.get("lvl"), " (Hobby, nur Beobachtung)" if s.get("watch") else "") for s in ss)))
        return 0
    if m in ("state", "hobby"):
        d = a[1]
        f = os.path.join(d, "sdr_wd.json")
        if not os.path.exists(f):
            print("sdr_wd.json: noch nicht vorhanden"); return 0 if m == "state" else 1
        w = json.load(open(f, encoding="utf-8"))
        dv = devs(d)
        out, bad = [], []
        for sn, v in sorted((w.get("sticks") or {}).items()):
            x = dv.get(sn.upper()) or {}
            nm = "%s%s" % (x.get("name") or "Gerät ohne Rolle", " (Hobby)" if x.get("role") == "hobby" else "")
            i = v.get("inc")
            if not i:
                out.append("%s SN %s ok" % (nm, sn))
            else:
                out.append("%s SN %s Vorfall %s seit %s%s" % (nm, sn, i.get("ch") or "?", hm(i.get("since")), (", nur Beobachtung" if x.get("role") == "hobby" else
                                                                                                                 ", Neustart %s, USB %s" % (i.get("restart_n", 0), i.get("usb_n", 0)))))
                if x.get("role") == "hobby" and (i.get("ch") != "RDS" or i.get("restart_n") or i.get("usb_n")):
                    bad.append(sn)
        if m == "hobby":
            if bad:
                print("Hobby-Vorfall alter Art noch offen: %s" % ", ".join(bad)); return 1
            print("Hobby: kein alter Vorfall offen (%s)" % "; ".join(o for o in out if "(Hobby)" in o)); return 0
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(w.get("reboots") or []), w.get("reboot_fail_n") or 0))
        return 0
    if m == "names":                                   # names DIR: gespeicherte Seiten/APIs (p_*.html / p_*.json) auf alte Platz-Namen pruefen
        return names_check(a[1])
    print("unbekannt"); return 2


SLOT_RE = re.compile(r"(\bSDR ?[123]\b|\bStick [1-9]\b(?! · (?:11D|5C|Hobby|ohne Rolle)\b))")
NAME_KEYS = ("name", "model", "dev_name", "name1", "name2", "name3", "names", "1", "2", "3", "label_plain")
SKIP_KEYS = ("hist", "ev", "events", "fig", "log", "techlog", "boot_msgs", "last_inc", "inc", "msgs", "err")
TS_RE = re.compile(r"^(\d\d\.\d\d\.( \d\d:\d\d)?|\d\d:\d\d)\b")


def _walk(o, path, out):
    if isinstance(o, dict):
        for k, v in o.items():
            k = str(k)
            if k in SKIP_KEYS:
                continue
            if k in NAME_KEYS and isinstance(v, str):
                continue
            _walk(v, path + "." + k, out)
    elif isinstance(o, list):
        for i, v in enumerate(o[:200]):
            _walk(v, "%s[%d]" % (path, i), out)
    elif isinstance(o, str) and SLOT_RE.search(o) and not TS_RE.match(o):
        out.append("%s = %s" % (path, o[:160]))


def names_check(d):
    import glob
    import html as H
    bad = []
    n = 0
    for f in sorted(glob.glob(os.path.join(d, "p_*"))):
        n += 1
        s = open(f, encoding="utf-8", errors="replace").read()
        b = os.path.basename(f)
        if b.endswith(".json"):
            try:
                j = json.loads(s)
            except Exception:
                bad.append("%s: kein JSON" % b)
                continue
            out = []
            _walk(j, "", out)
            bad += ["%s %s" % (b, x) for x in out]
            continue
        s = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", s)
        for t in (H.unescape(x).strip() for x in re.sub(r"(?s)<[^>]+>", "\n", s).split("\n")):
            if not t or TS_RE.match(t) or not SLOT_RE.search(t):
                continue
            if "dabhist" in b and not re.fullmatch(r"(Stick [1-9]|SDR ?[123])", t):
                continue                               # /dabhist: Meldungs-Texte sind Verlauf; nur Quell-Etiketten pruefen
            bad.append("%s: %s" % (b, t[:160]))
    if not n:
        print("keine Seiten gespeichert"); return 1
    if bad:
        print("alte Platz-Namen (Stick N/SDR N ohne Rolle) in %d Stellen: %s" % (len(bad), " | ".join(bad[:12]))); return 1
    print("Anzeige-Namen: %d Seiten/APIs ohne alte Platz-Namen (Stick N / SDR N nur als 'Name · Rolle'; Verlauf ausgenommen)" % n)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AC2_EOF
EXPECT_ADB2="22b591a92fc8a477e4dcd29600014400c79a2d0323a9aca01fe2490e6cde370c"
cat > "$W/air2_dash_block.py" << 'ADB2_EOF'
# ===== sdrAir2: Anzeige-Namen 'Name · Rolle' aus dem Geraete-Register auf allen Seiten (Funk-Lage, Geraete-Zeile, Lage-Text, Hinweise, /dabhist-Quelle, Antennentest-Kachel); Hobby-Geraet nicht in der Gesamtstufe; Stick ohne Rolle mit Seriennummer + Hinweis; nur Anzeige =====
AIR2D_SHORT = {"11D": "11D", "5C": "5C", "hobby": "Hobby", "": "ohne Rolle"}
_air2d_orig_air_sdrui = _air_sdrui
_air2d_orig_bc_note = _wd_bc_note
_air2d_orig_stk_card = _stk_card
_air2d_orig_fu_dh_html = _fu_dh_html
_AIR2D_CAT0 = _FU_CAT.get("stick")
_air2d_orig_t4_pre_text = _t4_pre_text


def _air2d_label(name, role):
    sh = AIR2D_SHORT.get(role or "", str(role))
    n = " ".join(str(name or "?").split())
    return n if n.endswith(" · " + sh) else "%s · %s" % (n, sh)


def _air2d_devs(st):
    devs = [x for x in (st or {}).get("devs") or [] if isinstance(x, dict)]
    for x in devs:
        x.setdefault("label", _air2d_label(x.get("name"), x.get("role") or ""))
    return devs


def _air2d_relabel(t, pairs):
    t = str(t or "")
    for n, lb in pairs:
        if t.startswith(n) and not t.startswith(lb) and (len(t) == len(n) or t[len(n)] in " :"):
            return lb + t[len(n):]
    return t


def _air2d_reg():
    try:
        st = _sdr_load("sdr_status.json", {}) or {}
        return st if (st.get("dual") or {}).get("reg") else None
    except Exception:
        return None


def _air_sdrui(st, d):
    k0 = dict(d.get("krise") or {})
    d = _air2d_orig_air_sdrui(st, d)
    try:
        devs = _air2d_devs(st)
        by = dict((x.get("role"), x) for x in devs if x.get("role"))
        pairs = sorted(((str(x.get("name")), x["label"]) for x in devs if x.get("name")), key=lambda p: -len(p[0]))
        du = d.get("dual") or {}
        hs = []
        for k in ("h1", "h2", "h3"):
            h = du.get(k)
            if isinstance(h, dict):
                h = dict(h, txt=_air2d_relabel(h.get("txt"), pairs))
                du[k] = h
                hs.append((k, h))
        for k in ("label1", "label2"):
            if du.get(k):
                du[k] = _air2d_relabel(du[k], pairs)
        fest = {"11D": " fest", "5C": " fest"}
        mode = "Geräte: %s" % ", ".join("%s%s%s" % (x["label"], fest.get(x.get("role"), ""), "" if x.get("present") else " (nicht angeschlossen)") for x in devs if x.get("role"))
        free = [x for x in devs if not x.get("role") and x.get("present")]
        if free:
            mode += " · erkannt, ohne Rolle (nie benutzt): %s" % ", ".join("%s%s" % (x["label"], (" SN %s" % x["serial"]) if x.get("serial") else "") for x in free)
        du["mode"] = mode
        if "hobby" in by:
            du["ppm_lbl"] = by["hobby"]["label"]
        d["dual"] = du
        main = [h for k, h in hs if k != "h3"]
        rank = {"ok": 0, "grau": 0, "lernt": 1, "gelb": 2, "rot": 3}
        names = [str(x.get("name")) for x in devs if x.get("name")] + [x["label"] for x in devs]
        parts = [x for x in (k0.get("txt") or "").split(" · ") if x and not x.startswith("Stick") and not x.startswith("Einzelbetrieb") and not any(x.startswith(n) for n in names)]
        parts.append(" · ".join(h["txt"] for k, h in hs))
        lv = k0.get("lvl") or "ok"
        for h in main:                                           # Hobby-Geraet: eigene Zeile, nicht in der Gesamtstufe
            if rank.get(h.get("lvl"), 0) > rank.get(lv, 0):
                lv = h["lvl"]
        kr = dict(d.get("krise") or {})
        hint = next((h.get("hint") for h in main if h.get("hint")), None) or k0.get("hint")
        miss = [x["label"] for x in devs if x.get("role") in ("11D", "5C") and not x.get("present")]
        if miss and not hint:
            hint = "%s nicht angeschlossen – USB prüfen, wird automatisch erkannt" % ", ".join(miss)
        kr.update(txt=" · ".join(parts), lvl=lv, hint=hint)
        d["krise"] = kr
    except Exception as e:
        print("sdrAir2 Anzeige:", e, flush=True)
    return d


def _wd_bc_note():
    try:
        st = _air2d_reg()
        if st:
            by = dict((x.get("role"), x) for x in _air2d_devs(st) if x.get("role"))
            out = []
            if "11D" in by:
                out.append("%s hört fest BR24 über DAB 11D (Gain-Leiter + Daten-Watchdog)" % by["11D"]["label"])
            if "5C" in by:
                out.append("%s hört fest ASA DE über DAB 5C (Rückfall 10C)" % by["5C"]["label"])
            if "hobby" in by:
                out.append("%s: UKW-RDS BR24/Bayern 3/Bayern 1 im Wechsel + 10C-Prüfung alle 6 h, nur Beobachtung" % by["hobby"]["label"])
            if out:
                return "; ".join(out)
    except Exception as e:
        print("sdrAir2 Anzeige:", e, flush=True)
    return _air2d_orig_bc_note()


def _stk_card(now=None):
    h = _air2d_orig_stk_card(now)
    try:
        st = _air2d_reg()
        if st:
            lb = ", ".join(x["label"] for x in _air2d_devs(st) if x.get("present"))
            h = h.replace("🔌 Antennentest (Stick 1 / Stick 2)", "🔌 Antennentest – im Geräte-Register-Betrieb aus (Vergleichstest folgt) · Geräte: %s" % _html_escape_air2(lb), 1)
    except Exception as e:
        print("sdrAir2 Anzeige:", e, flush=True)
    return h


def _html_escape_air2(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _air2d_by(st=None):
    st = st or _air2d_reg()
    return dict((x.get("role"), x) for x in _air2d_devs(st) if x.get("role")) if st else {}


def _air2d_5c(old, short=False):
    """Texte zur alten Stick-2-Uebernahme: im Register-Betrieb hoert das 5C-Geraet 5C ohnehin fest."""
    try:
        e = _air2d_by().get("5C")
        if e:
            return e["label"] if short else "5C fest auf %s (keine Übernahme nötig)" % e["label"]
    except Exception:
        pass
    return old


def _t4_pre_text(kind, why, now):
    t = _air2d_orig_t4_pre_text(kind, why, now)
    try:
        e = _air2d_by().get("5C")
        if e:
            n = " ".join(str(e.get("name") or "5C-Geraet").split())
            t = t.replace("SDR 2 auf 5C (Bundes-Ebene) gekapert.", "5C (Bundes-Ebene) laeuft fest auf %s." % n).replace("SDR 2 auf 5C gekapert.", "5C laeuft fest auf %s." % n)
            t = t.replace(" Freigabe nur per Knopf.", "")[:200]
    except Exception as e2:
        print("sdrAir2 Anzeige:", e2, flush=True)
    return t


def _air2d_cat_fix(st=None):
    """/dabhist-Filter: Kategorie 'stick' heisst im Register-Betrieb 'Geräte' (sonst wie bisher 'Stick 2')."""
    try:
        if _AIR2D_CAT0:
            reg = _air2d_reg() if st is None else st
            _FU_CAT["stick"] = ("Geräte", _AIR2D_CAT0[1], _AIR2D_CAT0[2], "GERÄTE") if reg else _AIR2D_CAT0
    except Exception as e:
        print("sdrAir2 Anzeige:", e, flush=True)


def _fu_dh_html(items, cats, ch, skip, thr, now=None):
    _air2d_cat_fix()
    return _air2d_orig_fu_dh_html(items, cats, ch, skip, thr, now)


def _air2d_src():
    return "Gerät" if _air2d_reg() else "Stick 2"


def _selftest_air2_dash():
    st = {"pin_err": None, "stick_health": {"lvl": "ok", "txt": "Airspy R2 ok"}, "stick_health2": {"lvl": "ok", "txt": "Stick 1 ok"},
          "stick_health3": {"lvl": "gelb", "txt": "Stick 2 · Hobby: kein RDS seit 22:11 · nur Beobachtung", "hint": "Hobby-Hinweis"}, "s2": {"active": "dab:1"}, "s3": {"active": "rds:0"},
          "dual": {"on": True, "reg": True, "name1": "Airspy R2", "name2": "Stick 1", "name3": "Stick 2", "sn1": "637862DC2E8092D7", "sn2": "19348831", "sn3": "72055505"},
          "devs": [{"name": "Airspy R2", "role": "11D", "present": True, "serial": "637862DC2E8092D7", "label": "Airspy R2 · 11D"},
                   {"name": "Stick 1", "role": "5C", "present": True, "serial": "19348831"}, {"name": "Stick 2", "role": "hobby", "present": True, "serial": "72055505"},
                   {"name": "Stick 3", "role": "", "present": True, "serial": "00000001", "usb": "0bda:2838", "hint": "Werks-Seriennummer"}]}
    d = _air_sdrui(st, {"krise": {"txt": "Keine Warnung im Rundfunk · Stick 1 ok", "lvl": "ok"}})
    du, k = d["dual"], d["krise"]
    assert du["h1"]["txt"] == "Airspy R2 · 11D ok" and du["h2"]["txt"] == "Stick 1 · 5C ok" and du["h3"]["txt"].startswith("Stick 2 · Hobby: kein RDS"), du
    assert du["label1"].startswith("Airspy R2 · 11D · SN 637862DC2E8092D7") and du["label2"].startswith("Stick 1 · 5C · SN 19348831"), du
    assert du["mode"] == "Geräte: Airspy R2 · 11D fest, Stick 1 · 5C fest, Stick 2 · Hobby · erkannt, ohne Rolle (nie benutzt): Stick 3 · ohne Rolle SN 00000001", du["mode"]
    assert k["lvl"] == "ok" and k["txt"] == "Keine Warnung im Rundfunk · Airspy R2 · 11D ok · Stick 1 · 5C ok · Stick 2 · Hobby: kein RDS seit 22:11 · nur Beobachtung" and k.get("hint") != "Hobby-Hinweis", k
    assert du["ppm_lbl"] == "Stick 2 · Hobby"
    st["stick_health2"] = {"lvl": "rot", "txt": "Stick 1 · 5C kein Sync seit 22:00"}
    assert _air_sdrui(st, {"krise": {"txt": "", "lvl": "ok"}})["krise"]["lvl"] == "rot"
    assert _air2d_relabel("Stick 1 ok", [("Stick 1", "Stick 1 · 5C")]) == "Stick 1 · 5C ok" and _air2d_relabel("Stick 10 ok", [("Stick 1", "Stick 1 · 5C")]) == "Stick 10 ok"
    g0 = globals()["_air2d_reg"]
    globals()["_air2d_reg"] = lambda: st
    try:
        assert _air2d_5c("SDR 2 auf 5C") == "5C fest auf Stick 1 · 5C (keine Übernahme nötig)" and _air2d_5c("SDR 2", True) == "Stick 1 · 5C"
        pt = _t4_pre_text("DSL", "", 0)
        assert "SDR 2" not in pt and "5C (Bundes-Ebene) laeuft fest auf Stick 1." in pt and "Knopf" not in pt, pt
        assert "Stick 2 · Hobby: UKW-RDS" in _wd_bc_note() and _air2d_src() == "Gerät"
        _air2d_cat_fix(st)
        assert _FU_CAT["stick"][0] == "Geräte" and _FU_CAT["stick"][2] == "stick"
        _air2d_cat_fix(False)
        assert _FU_CAT["stick"] == _AIR2D_CAT0
    finally:
        globals()["_air2d_reg"] = g0
        _air2d_cat_fix()
    return "sdrAir2 Anzeige ok (Vor-Alarm-/Mesh-Text ohne SDR 2, /dabhist-Filter Geräte, Name · Rolle in Funk-Lage/Geraete-Zeile/Lage-Text, Stick 3 · ohne Rolle mit SN, Hobby nicht in der Gesamtstufe, Hinweis ohne Hobby)"


try:
    _AIR2D = {"selftest": _selftest_air2_dash()}
    print("sdrAir2 aktiv: %s" % _AIR2D["selftest"], flush=True)
except Exception as _air2d_e:
    _AIR2D = {"selftest": "FEHLER %s" % _air2d_e}
    print("sdrAir2 Anzeige FEHLER: %s" % _air2d_e, flush=True)
# ===== /sdrAir2 =====
ADB2_EOF
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
PF="$W/patch-fu.py"; AE2="$W/air2_edits.py"; ASD2="$W/air2_sdr_block.py"; ASM2="$W/air2_sm_block.py"; AG2="$W/guard_air2.py"; AC2="$W/air2check.py"; ADB2="$W/air2_dash_block.py"
AC="$W/aircheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"; CK="$W/sqlccheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_AE2 $AE2" "$EXPECT_ASD2 $ASD2" "$EXPECT_ASM2 $ASM2" "$EXPECT_AG2 $AG2" "$EXPECT_AC2 $AC2" "$EXPECT_ADB2 $ADB2" "$EXPECT_AC $AC" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2" "$EXPECT_CK $CK"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ "$1" == "$4" ]] && echo "bekannt ($5)" || echo "UNBEKANNT"; }; }
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sdrAir" "$KNOWN_SDR16N" "sdrAir2 schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sdrAir" "$KNOWN_SM16N" "sdrAir2 schon drin"))"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sdrAir" "$KNOWN_D16N" "sdrAir2 schon drin"))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
[[ "$SDR16" == "$KNOWN_SDR16" || "$SDR16" == "$KNOWN_SDR16N" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16 = sdrAir oder $KNOWN_SDR16N = sdrAir2);"
[[ "$SM16" == "$KNOWN_SM16" || "$SM16" == "$KNOWN_SM16N" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16 = sdrAir oder $KNOWN_SM16N = sdrAir2);"
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 = sdrAir oder $KNOWN_D16N = sdrAir2);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      sdrAir2 passt nur auf den sdrAir-Stand vom 23.10. 23:07 - nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = sdrAir (bzw. sdrAir2 schon drin), alle sha16 bekannt"
grep -q '# ===== sdrAir:' "$M" && grep -q '# ===== sdrAir:' "$SMF" && grep -q '# ===== sdrAir:' "$F" || { echo "STOP: sdrAir fehlt - nichts geaendert"; exit 1; }
[[ -x "$HDST" ]] || { echo "STOP: Hilfsprogramm $HDST fehlt - nichts geaendert"; exit 1; }
HL16=$(s16 "$HDST")
[[ "$HL16" == "$KNOWN_HL16" ]] || { echo "STOP: Hilfsprogramm sha16 $HL16 statt $KNOWN_HL16 (sdrAir) - nichts geaendert"; exit 1; }
echo "OK Hilfsprogramm $HDST sha16 $HL16 (sdrAir, bleibt)"
for k in "sdr prepper_sdr $M $ASD2 $KNOWN_SDR16N" "sm sdr_manager $SMF $ASM2 $KNOWN_SM16N" "dsh dashboard $F $ADB2 $KNOWN_D16N"; do set -- $k
  if [[ "$(s16 "$3")" == "$5" ]]; then cp "$3" "$W/work/$2.py"; echo "$2.py: sdrAir2 schon drin" > "$W/q_$1.log"; continue; fi
  python3 "$PF" sdrAir2 "$1" "$3" "$W/work/$2.py" "$4" "$AE2" > "$W/q_$1.log" || { cat "$W/q_$1.log"; echo "STOP: $2.py sdrAir2-Stufe passt nicht - nichts geaendert"; exit 1; }
done
NP16=$(s16 "$W/work/prepper_sdr.py"); NS16=$(s16 "$W/work/sdr_manager.py"); ND16=$(s16 "$W/work/dashboard.py")
[[ "$NP16" == "$KNOWN_SDR16N" && "$NS16" == "$KNOWN_SM16N" && "$ND16" == "$KNOWN_D16N" ]] || { echo "STOP: Ergebnis prepper_sdr.py $NP16 / sdr_manager.py $NS16 / dashboard.py $ND16 statt $KNOWN_SDR16N / $KNOWN_SM16N / $KNOWN_D16N - nichts geaendert"; exit 1; }
echo "OK Ergebnis wie erwartet: prepper_sdr.py $NP16 ($(wc -l < "$W/work/prepper_sdr.py") Zeilen), sdr_manager.py $NS16 ($(wc -l < "$W/work/sdr_manager.py") Zeilen), dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen)"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
AIRSN=$(python3 "$AC" airspy "$SYSUSB" 2>"$W/air.log") || { echo "$AIRSN"; echo "STOP: Airspy nicht eindeutig - nichts geaendert"; exit 1; }
[[ "$AIRSN" =~ ^[0-9A-F]{16}$ ]] || { echo "STOP: Airspy-Seriennummer $AIRSN - nichts geaendert"; exit 1; }
echo "OK $(cat "$W/air.log")"
FE=$(python3 -c "import json,sys;c=json.load(open(sys.argv[1]));print(c.get('air_fe') or 'airspy')" "$CF" 2>/dev/null || echo "?")
echo "OK Airspy-Frontend laut sdr_config.json: air_fe $FE ($([[ "$FE" == soapy ]] && echo "SoapySDR gewuenscht, Rueckfall -F airspy automatisch" || echo "Standard welle-cli -F airspy, bleibt"))"
# ---------- 1b) sudo-Regel pruefen (ohne gemerktes Passwort, nur lesen/check) ----------
SU=$(systemctl show -p User --value prepper-sdr 2>/dev/null || true); [[ -z "$SU" ]] && SU=root
if ! [[ "$SU" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "STOP: Benutzer von prepper-sdr unklar ($SU) - nichts geaendert"; exit 1; fi
asu() { if [[ "$(id -un)" == "$SU" ]]; then setsid -w "$@" < /dev/null; else sudo -n -u "$SU" setsid -w "$@" < /dev/null; fi; }
slist() { if [[ "$(id -un)" == "$SU" ]]; then sudo -n -l "$@"; else sudo -n -l -U "$SU" "$@"; fi; }
WD_SUDO_ERR=""; WD_SUDO_OK=""
wd_sudo_verify() {
  local c out rc
  for c in "check" "usb-reset 19348831" "usb-reset-air $AIRSN" "reboot"; do
    rc=0; slist "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?
    [[ "$rc" == 0 ]] || { WD_SUDO_ERR="sudo -l: $HDST $c fuer $SU nicht erlaubt (rc $rc: $(head -c 200 "$W/sl.log" | tr '\n' ' '))"; return 1; }
  done
  # sudo -k: gemerktes Passwort (z. B. vom sudo -v dieses Skripts, Zeitstempel global) zaehlt nicht - nur die NOPASSWD-Regel
  rc=0; out=$(asu sudo -k -n "$HDST" check 2>&1) || rc=$?
  [[ "$rc" == 0 && "$out" == *"bereit (uid 0)"* ]] || { WD_SUDO_ERR="$SU kann $HDST check nicht ohne Passwort und ohne Terminal ausfuehren (rc $rc: $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200))"; return 1; }
  rc=0; asu sudo -k -n true > /dev/null 2>&1 || rc=$?
  slist > "$W/slall.log" 2>&1 || true
  if [[ "$rc" == 0 ]] && grep -qE 'NOPASSWD: *ALL *$' "$W/slall.log"; then
    WD_SUDO_OK="$HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot ohne Passwort geprueft (sudo -k, ohne Terminal); Hinweis: $SU hat laut sudo -l NOPASSWD: ALL - Gegenprobe entfaellt"; return 0
  fi
  for c in "selftest" "usb-reset 1234" "usb-reset 19348831 x" "usb-reset ../x" "usb-reset-air 1234" "usb-reset-air ${AIRSN,,}" "usb-reset-air $AIRSN x" "usb-reset-air ../x"; do
    rc=0; out=$(asu sudo -k -n "$HDST" $c 2>&1) || rc=$?
    [[ "$rc" != 0 && "$out" == sudo:* ]] || { WD_SUDO_ERR="sudo erlaubt zu viel ohne Passwort: $HDST $c (rc $rc)"; return 1; }
  done
  WD_SUDO_OK="nur $HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex gross> | reboot ohne Passwort (sudo -k, ohne Terminal wie im Dienst), andere Aufrufe verlangen Passwort; allgemeines sudo verlangt Passwort"
}
if [[ "$SU" != root ]]; then
  wd_sudo_verify || { echo "STOP: sudo-Regel: $WD_SUDO_ERR - nichts geaendert"; exit 1; }
  echo "OK sudo-Regel fuer $SU: $WD_SUDO_OK"
fi
# ---------- 2) Trockenlauf ----------
for k in "sdr prepper_sdr $ASD2" "sm sdr_manager $ASM2" "dsh dashboard $ADB2"; do set -- $k
  python3 "$PF" sdrAir2 "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$AE2" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/work/dashboard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$LG" ]] && cp "$LG" "$W/sbx/"
cp "$DBF" "$MR" "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrair2-selftest timeout 300 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok" "sdr_manager selftest sdrWd ok" "sdr_manager selftest sdrWd2 ok" "sdr_manager selftest sdrAir ok" "sdr_manager selftest sdrAir2 ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrair2-selftest timeout 600 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok" "selftest sdrWd2 ok" "selftest sdrAir ok" "selftest sdrAir2 ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum, Fake-Hilfsprogramm, Fake-SoapySDR-Modul; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet)"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest sdrAir2 ok' "$W/sdrt.log" | tail -1 | cut -c1-420)"
  echo "   $(grep -F 'sdr_manager selftest sdrAir2 ok' "$W/smt.log" | tail -1 | cut -c1-220)"
done
if [[ "$SDR16" == "$KNOWN_SDR16N" && "$SM16" == "$KNOWN_SM16N" && "$D16" == "$KNOWN_D16N" ]]; then
  echo "OK sdrAir2 schon drin - Guard-Rueckbau gegen Basis entfaellt (Inhalt = gepruefter Zielstand, sha16)"
else
  python3 "$AG2" "$AE2" sdr "$M" "$W/work/prepper_sdr.py" "$ASD2" sm "$SMF" "$W/work/sdr_manager.py" "$ASM2" dsh "$F" "$W/work/dashboard.py" "$ADB2" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard sdrAir2 - nichts geaendert"; exit 1; }
  echo "$(cat "$W/g.log")"
fi
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
echo "Watchdog vorher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-360)"
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert) ----------
trap '' INT
RESTARTED=0
ALL=("$M" "$SMF" "$F")
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK sdrAir2 schon installiert (prepper_sdr.py, sdr_manager.py, dashboard.py) - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    for u in prepper-sdr prepper-dashboard; do sudo journalctl -u "$u" --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrAir|sdrWd|Traceback" | tail -4 | cut -c1-200 || true; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sdrair2-$TS" ]] && cp -a "$x.bak-sdrair2-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sdrair2-$TS" ]] || continue; cmp -s "$x" "$x.bak-sdrair2-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Sicherungen von vorher: $LZ.bak-sdrair2-$TS, $WDJ.bak-sdrair2-$TS (nicht zurueckgespielt; Watchdog-Zustand bleibt)"
    echo "alter Stand (sdrAir) wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$WDJ"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-sdrair2-$TS"
    { ls -1t "$x.bak-sdrair2-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sdrair2-$TS" \
      || { rm -f "$LZ.bak-sdrair2-$TS"; for x in "${ALL[@]}" "$WDJ"; do rm -f "$x.bak-sdrair2-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sdrair2-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "prepper_sdr $M" "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sdrair2-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (max 240 s) und 11D-Sync vom Airspy (max 300 s; sendet nichts) ..."
  sudo systemctl restart prepper-sdr.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$AC" status "$DASH_DIR" "$T0" > "$W/ast.log" 2>&1 && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { cat "$W/ast.log"; rb "prepper-sdr: Airspy 11D laeuft nicht ($(head -c 200 "$W/ast.log"))"; exit 1; }
  pok=0; for i in $(seq 1 120); do python3 "$AC" port 7979 > "$W/port.log" 2>&1 && { pok=1; break; }; sleep 1; done
  [[ "$pok" == 1 ]] && echo "OK welle-cli (Airspy) $(cat "$W/port.log")" || { rb "Port 7979 (welle-cli Airspy) lauscht nicht"; exit 1; }
  sok=0; for i in $(seq 1 100); do python3 "$AC2" proof "$DASH_DIR" "$T0" > "$W/proof.log" 2>&1 && { sok=1; break; }; sleep 3; done
  [[ "$sok" == 1 ]] && echo "OK $(cut -c1-460 "$W/proof.log")" || { cat "$W/proof.log"; rb "11D-Sync vom Airspy nach 300 s nicht nachgewiesen"; exit 1; }
  echo "Neustart prepper-dashboard (laedt dashboard.py + sdr_manager.py neu) - warte auf HTTP (max 240 s) ..."
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
python3 "$WC" funk "$W/funk.html" "$W" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne Daten-Watchdog"; }
python3 "$WC2" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk Watchdog-Zeilen"; }
python3 "$AC" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne sdrAir-Anzeige"; }
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$WC" pi "$W/pi.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/pi Watchdog-Kachel"; }
"${CURL[@]}" "$B/dabhist" -o "$W/dabhist.html" || true
[[ -s "$W/dabhist.html" ]] && echo "OK /dabhist $(wc -c < "$W/dabhist.html") Bytes" || rbx "/dabhist leer"
uok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/ui" -o "$W/ui.json" || true; python3 "$AC" ui "$W/ui.json" > "$W/wc.log" 2>&1 && { uok=1; break; }; sleep 6; done
[[ "$uok" == 1 ]] && echo "OK $(cut -c1-300 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/ui ohne Geraete-Register"; }
tok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/t2/status" -o "$W/t2.json" || true; python3 "$AC" t2 "$W/t2.json" > "$W/wc.log" 2>&1 && { tok=1; break; }; sleep 6; done
[[ "$tok" == 1 ]] && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t2/status Register"; }
wok=0; for i in $(seq 1 30); do "${CURL[@]}" "$B/api/sdr/wd" -o "$W/wd.json" || true; python3 "$AC2" api "$W/wd.json" > "$W/wc.log" 2>&1 && { wok=1; break; }; sleep 6; done
[[ "$wok" == 1 ]] && echo "OK $(cut -c1-400 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/wd ohne sdrAir2-Zusammenfassung (Namen/Hobby/wird geprueft)"; }
hok=0; for i in $(seq 1 40); do python3 "$AC2" hobby "$DASH_DIR" > "$W/hb.log" 2>&1 && { hok=1; break; }; sleep 3; done
[[ "$hok" == 1 ]] && echo "OK $(cut -c1-300 "$W/hb.log")" || { cat "$W/hb.log"; rbx "alter Hobby-Vorfall nicht geschlossen"; }
"${CURL[@]}" "$B/api/t4/tii" -o "$W/tii.json" || true
python3 "$WC" tii "$W/tii.json" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t4/tii Karte"; }
nok=0; for i in $(seq 1 10); do
  rm -rf "$W/nm" && mkdir -p "$W/nm"
  for p in / /funk /pi /umwelt /dabhist /mesh; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').html" || true; done
  for p in /api/sdr/ui /api/sdr/wd /api/t2/status /api/t4/status; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').json" || true; done
  python3 "$AC2" names "$W/nm" > "$W/nm.log" 2>&1 && { nok=1; break; }; sleep 6
done
[[ "$nok" == 1 ]] && echo "OK $(cut -c1-300 "$W/nm.log")" || { cat "$W/nm.log"; rbx "alte Platz-Namen auf Seiten/APIs"; }
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JP=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JS=$(echo "$JP" | grep -E "sdrTeil2: aktiv im Geraete-Register" | tail -1 || true)
  [[ -n "$JS" ]] && echo "OK Journal prepper-sdr: $(echo "$JS" | cut -c1-260)" || rbx "prepper-sdr meldet die Register-Rollen nicht (sdrTeil2-Zeile alt?)"
  if echo "$JP" | grep -q "Alarm-Uebernahme 5C"; then rbx "alte Zeile sdrTeil2 ... Alarm-Uebernahme 5C noch im Journal"; fi
  echo "OK Journal prepper-sdr: keine alte Zeile Alarm-Uebernahme 5C seit Neustart"
fi
E1=$(echo "$JP" | grep -c -E "Traceback|^sdrAir2? [A-Za-z/ ]*:|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JA=$(echo "$JD" | grep -F "sdrAir2 aktiv: sdrAir2 Anzeige ok" | tail -1 || true)
  [[ -n "$JA" ]] && echo "OK Journal Dashboard: $(echo "$JA" | cut -c1-260)" || rbx "Dashboard meldet sdrAir2-Anzeige nicht (Selbsttest)"
fi
E2=$(echo "$JD" | grep -c -E "Traceback|sdrWd FEHLER|funkUI FEHLER|sdr_manager sdrWd|sdr_manager sdrAir2? [A-Za-z_ -]+:|sdrAir2? Anzeige(:| FEHLER)" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"
python3 "$AC2" proof "$DASH_DIR" 0 > "$W/proof.log" 2>&1 && echo "Geraete nachher: $(cut -c1-460 "$W/proof.log")" || echo "HINWEIS Geraete nachher: $(cut -c1-300 "$W/proof.log")"
echo "Watchdog nachher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-400)"
for x in "$DBF:$DB16" "$MR:$MR16" "$HDST:$HL16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
echo "OK guards sdrAir2(sdr)=$(grep -c '# ===== sdrAir2:' "$M" || true) sdrAir2(sm)=$(grep -c '# ===== sdrAir2:' "$SMF" || true) sdrAir(sdr)=$(grep -c '# ===== sdrAir:' "$M" || true) sdrAir(sm)=$(grep -c '# ===== sdrAir:' "$SMF" || true) sdrAir(dash)=$(grep -c '# ===== sdrAir:' "$F" || true) sdrAir2(dash)=$(grep -c '# ===== sdrAir2:' "$F" || true) sdrWd2(sdr)=$(grep -c '# ===== sdrWd2:' "$M" || true) sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sysBoot(dash)=$(grep -c '# ===== sysBoot' "$F" || true)"
[[ -f "$M.bak-sdrair2-$TS" ]] && echo "Backups: *.bak-sdrair2-$TS (prepper_sdr.py, sdr_manager.py, dashboard.py, sdr_wd.json, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF" "$HDST"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: prepper_sdr.py.bak-sdrair2-$TS, sdr_manager.py.bak-sdrair2-$TS und dashboard.py.bak-sdrair2-$TS zurueckkopieren, dann sudo systemctl restart prepper-sdr prepper-dashboard"
echo "SoapySDR testen (nur auf Wunsch): in sdr_config.json air_fe auf soapy, dann sudo systemctl restart prepper-sdr; Rueckfall auf -F airspy geschieht automatisch"
echo "COMMIT $COMMIT_ARG sdrair2=1 fertig"
