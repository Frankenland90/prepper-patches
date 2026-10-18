#!/bin/bash
set -euo pipefail
# sdrWd: Daten-Watchdog fuer die SDR-Sticks (Ausfall 17./18.10.: Stick 1 haengt, Sync nein/SNR None, nur Abstecken half).
# Je Stick Zeit seit letztem ECHTEN Empfang (DAB-Sync mit Ensemble / RDS-Gruppen), in lagezentrum.db (state sdr_wd) + sdr_wd.json:
#   ab 10 min gelb (Gain-Leiter laeuft weiter) - ab 30 min Neustart welle-cli + rtl_tcp - ab 45 min USB-Neuverbindung NUR dieses Sticks
#   (per Seriennummer, 0bda:2838, max 2 je Vorfall) - ab 60 min Pi-Neustart (max 1 je Stunde, nach 3 erfolglosen Stopp: Stick/Antenne pruefen).
#   Nie bei echtem Alarm, Stick-2-Uebernahme 5C/10C, ASA-Warnung, PTY 31, Antennentest, Meteor; 5 min nach Start nur beobachten. Sendet nichts.
# Root nur ueber /usr/local/sbin/prepper-sdr-wdhelper (check | usb-reset 8 Ziffern | reboot) + sudoers-Regel genau dafuer, wenn prepper-sdr nicht als root laeuft.
# Anzeige: /funk Funk-Lage (Ampel, Stufe, seit, USB-Resets, Pi-Neustarts heute/zuletzt), /pi Kachel ueber der Sicherung, /api/sdr/wd, Lage-Text ehrlich,
# BR24-Hinweis Rolle bc, Empfaenger-Zeilen auf /funk ruhig (eine Zeile, Kurztext, Details aufklappbar). Kein uhubctl, kein Portstrom - SSD bleibt unberuehrt.
# mastFix: MASTS_DB (prepper_sdr.py) und Kartenliste (sdr_manager.py) mit gleichen Namen/Lagen je Standort; 11D/5C/10C vollstaendig bis etwa 255 km
#   (fmlist.org 10A5/10BC/10AD, dazu gleicher Kanal anderer Ensembles als Ueberreichweite), Liste Frank 18.10. als Basis, bei Widerspruch gewinnt die Quelle.
# Aendert prepper_sdr.py, sdr_manager.py, dashboard.py; database.py, mesh_router.py, lagegeo.py bleiben. Neustart prepper-sdr + prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
HDST="/usr/local/sbin/prepper-sdr-wdhelper"
SDST="/etc/sudoers.d/zz-prepper-sdr-wd"   # zz-: sortiert zuletzt, keine spaetere Datei ueberdeckt die Regel
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdrwd-apply
KEEP_LAST=3
KNOWN_D16="ccccd6476c2ab2e4"     # dashboard.py nach funkUI
KNOWN_D16N="1c0b6b2db92f802f"     # dashboard.py nach sdrWd (Ziel)
KNOWN_SM16="4cbc77c70193bacd"    # sdr_manager.py nach funkUI
KNOWN_SM16N="53ab078bd5398e42"    # sdr_manager.py nach sdrWd (Ziel)
KNOWN_SDR16="786f2c925f0e88a7"   # prepper_sdr.py nach sdrLog
KNOWN_SDR16N="1f8b450db19854d1"   # prepper_sdr.py nach sdrWd (Ziel)
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
echo "=== sdrWd apply (Daten-Watchdog je Stick: gelb 10 / Neustart 30 / USB 45 / Pi-Neustart 60 min, Anzeige /funk + /pi, Masten-Liste), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_PF="24ca150b11f4c77b5d34085330c7cc64c90e5795e498cde56fb0f2562ae906ef"
cat > "$W/patch-fu.py" << 'WDP_EOF'
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
WDP_EOF
EXPECT_ED="c4717af88ce9330ada92b6684588d7bec0786125bfe670293876a7878c653d01"
cat > "$W/wd_edits.py" << 'WDE_EOF'
# sdrWd: Stellen (alt, neu). Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
('''        selftest_sdrlog()
    elif a in''', '''        selftest_sdrlog()
        selftest_sdrwd()
    elif a in'''),
(''' and len(MASTS_DB["11D"]["tii"]) == 76   # tiiFix # tiiFix2''', ''' and len(MASTS_DB["11D"]["tii"]) >= 76   # tiiFix # tiiFix2 # sdrWd/mastFix: weitere Sender'''),
('''t2_mast("11D", 5, 14).startswith("Nürnberg (Fernmeldeturm Schweinau) MainID 05 / SubID 14")   # tiiFix''', '''t2_mast("11D", 5, 14).startswith("Nürnberg (Schweinau) MainID 05 / SubID 14")   # tiiFix # sdrWd/mastFix: Kurzname'''),
('''    assert t2_mast("11D", 8, 1) == "Ochsenkopf MainID 08 / SubID 01 (BR Bayern)" and t2_mast("11D", 7, 12).startswith("Hohe Linie MainID 07 / SubID 12")''', '''    assert t2_mast("11D", 8, 1) == "Ochsenkopf (Fichtelgebirge) MainID 08 / SubID 01 (BR Bayern)" and t2_mast("11D", 7, 12).startswith("Hohe Linie (Regensburg) MainID 07 / SubID 12")'''),
('''tl.ev[4]["text"].endswith(": Nürnberg (Fernmeldeturm Schweinau) · 05/14"), tl.ev   # Klarnamen''', '''tl.ev[4]["text"].endswith(": Nürnberg (Schweinau) · 05/14"), tl.ev   # Klarnamen # sdrWd/mastFix'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SM_EDITS = [
('''            if not isinstance(dm, dict) or not isinstance(dm.get("t"), (int, float)):
                continue
            ens = str(d.get("ensemble") or "").strip()[:40] or None''', '''            if not isinstance(dm, dict) or not isinstance(dm.get("t"), (int, float)):
                continue
            if dm.get("sync") is False or d.get("rx") is False:   # sdrWd: DAB-Messwerte nur bei Sync (Lebenszeichen bleiben hb-Zeilen)
                continue
            ens = str(d.get("ensemble") or "").strip()[:40] or None'''),
('''    print(selftest_funkui())
''', '''    print(selftest_funkui())
    print(selftest_sdrwd())
'''),
('''                site(m["id"], m["name"], m)["ch"].append({"ch": ch, "tii": m["tii"][ch]})
    return [sites[k] for k in order], src
''', '''                site(m["id"], m["name"], m)["ch"].append({"ch": ch, "tii": m["tii"][ch]})
    globals().get("_wd_kv_more", lambda *a: None)(bs, sites, site)   # sdrWd/mastFix: alle 5C/10C-Sender aus MASTS_DB
    return [sites[k] for k in order], src
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
DASH_EDITS = [
('''    r["bc_note"] = "Stick 1 prüft abwechselnd BR24 (UKW + DAB 11D) und ASA DE (DAB 5C), nicht gleichzeitig"
''', '''    r["bc_note"] = globals().get("_wd_bc_note", lambda: "Stick 1 prüft abwechselnd BR24 (UKW + DAB 11D) und ASA DE (DAB 5C), nicht gleichzeitig")()   # sdrWd: Rolle bc = nur 11D
'''),
('''    lvl = _lz_mgr.t4_level(live_st, al, st["pre"], br)
    sd = _lz_mgr.t4_sdr(base, now)
''', '''    lvl = _lz_mgr.t4_level(live_st, al, st["pre"], br)
    sd = _lz_mgr.t4_sdr(base, now)
    lvl = globals().get("_wd_t4", lambda a, *b: a)(lvl, sd, base, now)   # sdrWd: echter SDR-Zustand im Lage-Text (Stufe/Label/Mesh unveraendert) + Alarm-Sperre
'''),
("""function txt(r){return r.text+' · '+ago(r.t)+(r.run?' · prüft gerade':(r.next?' · nächste '+hm(r.next):''));}""",
 """function rel(t){if(!t)return 'nie';var s=now()-t;if(s<90)return 'jetzt';if(s<3600)return Math.floor(s/60)+' min';if(s<86400)return Math.floor(s/3600)+' h';var d=new Date(t*1000);return p2(d.getDate())+'.'+p2(d.getMonth()+1)+'.';}
function sh(x){return String(x||'').replace(/ seit \\d\\d\\.\\d\\d\\.(\\d{4})? ?\\d\\d:\\d\\d(:\\d\\d)?/g,'').replace(/(\\d\\d)\\.(\\d\\d)\\.\\d{4} (\\d\\d:\\d\\d)(:\\d\\d)?/g,'$1.$2. $3');}
function txt(r){return sh(r.text)+' · '+rel(r.t)+(r.run?' · prüft':(r.next?' · →'+hm(r.next):''));}
function full(r){return r.text+' · zuletzt '+(r.t?hm(r.t):'nie')+(r.run?' · prüft gerade':(r.next?' · nächste Prüfung '+hm(r.next):''))+(r.tip?'\\n'+r.tip:'');}"""),
("""x.appendChild(el('span','su-i',r.icon||''));x.appendChild(el('span','su-k',r.label||''));var a=el('a','su-v',txt(r));a.href=r.href;x.appendChild(a);if(r.tip)x.title=r.tip;rf.parentNode.insertBefore(x,ref);});}""",
 """x.appendChild(el('span','su-i',r.icon||''));x.appendChild(el('span','su-k',r.label||''));var a=el('a','su-v',txt(r));a.href=r.href;x.appendChild(a);x.title=full(r);rf.parentNode.insertBefore(x,ref);});}"""),
]
DASH_ANCHOR = "# ===== /funkUI =====\n"
WDE_EOF
EXPECT_BSD="3ccc1979b7586255022a7d448160e9ec1f234c14a0cb10384131ebc8ac0a8b10"
cat > "$W/wd_sdr_block.py" << 'WDB_EOF'
# ===== sdrWd: Daten-Watchdog je Stick - Zeit seit letztem ECHTEN Empfang (DAB-Sync mit Ensemble, RDS-Gruppen); Stufe 1 ab 10 min gelb (Gain-Leiter laeuft weiter), Stufe 2 ab 30 min Neustart welle-cli + rtl_tcp dieses Sticks, Stufe 3 ab 45 min USB-Neuverbindung NUR dieses Sticks (Seriennummer, 0bda:2838, root-Hilfsprogramm, max 2 je Vorfall), Stufe 4 ab 60 min Pi-Neustart (max 1 je Stunde, nach 3 erfolglosen keine weiteren: Stick/Antenne pruefen); Stufen 2-4 nie bei Alarm, Stick-2-Uebernahme, ASA-Warnung, PTY 31, Antennentest, Meteor; Zustand in lagezentrum.db (state sdr_wd) + sdr_wd.json (ueberlebt Neustart); Schalter/Schwellen in sdr_config.json; sendet nichts =====
WD_DEFAULTS = {"wd_enable": True, "wd_yellow_min": 10, "wd_restart_min": 30, "wd_usb_min": 45, "wd_reboot_min": 60, "wd_reboot_min_interval_min": 60,
               "wd_reboot_max_fail": 3, "wd_usb_max": 2}
for _wd_k, _wd_v in WD_DEFAULTS.items():
    DEFAULT_CFG.setdefault(_wd_k, _wd_v)
WD_HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"
WD_FILE = "sdr_wd.json"
WD_GATE = "sdr_wd_gate.json"       # vom Dashboard: echter Alarm im Lagezentrum (frisch <= 15 min) sperrt Stufen 2-4
WD_KEY = "sdr_wd"
WD_SN_RE = re.compile(r"^[0-9]{8}$")
WD_MIN_RAN_S = 15                  # Pruefung zaehlt erst nach 15 s Laufzeit
WD_VERIFY_S = 240                  # nach jeder Aktion mind. 4 min + 2 Pruefungen abwarten
WD_EVID_S = 1200                   # Eskalation nur mit frischer Fehl-Pruefung (<= 20 min)
WD_PENDING_S = 600                 # Pi-Neustart angefordert, aber nach 10 min noch derselbe Prozess = nicht erfolgt
WD_SAVE_S = 300
WD_BLOCKLOG_S = 1800
WD_START_GRACE_S = 300             # nach Prozessstart 5 min nur beobachten (Gain-Leiter/Einspielen in Ruhe)
WD_STAGE_TXT = {1: "Gain-Leiter läuft weiter", 2: "Neustart welle-cli + rtl_tcp", 3: "USB-Neuverbindung", 4: "Pi-Neustart"}
WD_ACT_TXT = {None: "Gain-Leiter", "restart": "Neustart welle-cli + rtl_tcp", "usb": "USB-Reset", "reboot": "Pi-Neustart"}
_WD_LOCK = threading.RLock()
_WD = {"d": None, "base": None, "dirty": False, "saved": 0.0, "busy": None, "start": time.time(), "cfg": None, "cfg_key": None,
       "started": set(), "helper": None, "err_t": 0.0, "live": False}   # live: nur im Dienst (Planner.loop) - Selbsttests loesen nie etwas aus


def wd_cfg(base):
    """Schalter + Schwellen aus sdr_config.json (fehlt/kaputt = Standard), Reihenfolge erzwungen; nach mtime zwischengespeichert."""
    fn = p("sdr_config.json", base)
    try:
        _st = os.stat(fn)
        key = (fn, _st.st_mtime_ns, _st.st_size)
    except Exception:
        key = (fn, None)
    if _WD["cfg"] is not None and _WD["cfg_key"] == key:
        return _WD["cfg"]
    u = load_json(fn, {}) if key[1] is not None else {}
    u = u if isinstance(u, dict) else {}
    c = {}
    for k, dv in WD_DEFAULTS.items():
        v = u.get(k, dv)
        if k == "wd_enable":
            c[k] = not (v is False or str(v).strip().lower() in ("0", "false", "off", "aus", "nein", "no"))
            continue
        try:
            v = float(v)
            if v != v or v < 0 or v > 100000:
                raise ValueError
        except Exception:
            v = float(dv)
        c[k] = v
    c["wd_yellow_min"] = max(0.2, c["wd_yellow_min"])
    c["wd_restart_min"] = max(c["wd_yellow_min"], c["wd_restart_min"])
    c["wd_usb_min"] = max(c["wd_restart_min"], c["wd_usb_min"])
    c["wd_reboot_min"] = max(c["wd_usb_min"], c["wd_reboot_min"])
    c["wd_reboot_min_interval_min"] = max(1.0, c["wd_reboot_min_interval_min"])
    c["wd_reboot_max_fail"] = int(min(10, c["wd_reboot_max_fail"]))
    c["wd_usb_max"] = int(min(5, c["wd_usb_max"]))
    for k, dv in (("wd_verify_s", WD_VERIFY_S), ("wd_start_grace_s", WD_START_GRACE_S)):   # fuer Fachleute/Simulation: Wartezeit nach Aktion, Startphase (min 30 s)
        try:
            v = float(u.get(k, dv))
            c[k] = max(30.0, min(3600.0, v)) if v == v else float(dv)
        except Exception:
            c[k] = float(dv)
    c["src"] = {k: ("sdr_config.json" if k in u else "Standard") for k in list(WD_DEFAULTS) + ["wd_verify_s", "wd_start_grace_s"]}
    _WD["cfg"], _WD["cfg_key"] = c, key
    return c


def _wd_hm(t, now=None):
    try:
        t = int(t)
        now = now or time.time()
        return time.strftime("%H:%M" if time.localtime(t)[:3] == time.localtime(now)[:3] else "%d.%m. %H:%M", time.localtime(t))
    except Exception:
        return "?"


def _wd_dur(s):
    s = int(max(0, s or 0))
    return "%d min" % (s // 60) if s < 3600 else "%d h %02d min" % (s // 3600, (s % 3600) // 60)


def _wd_new():
    return {"v": 1, "t": 0, "sticks": {}, "reboots": [], "reboot_fail_n": 0, "rb_sn": None, "pending": None, "stopped": False}


def _wd_clean(d):
    """Geladenen Zustand pruefen; alles Unbekannte faellt auf leer zurueck."""
    o = _wd_new()
    if not isinstance(d, dict):
        return o
    num = lambda x: x if isinstance(x, (int, float)) and not isinstance(x, bool) else None
    o["t"] = num(d.get("t")) or 0
    for sn, s in (d.get("sticks") or {}).items() if isinstance(d.get("sticks"), dict) else []:
        if not (isinstance(sn, str) and SERIAL_RE.match(sn) and isinstance(s, dict)):
            continue
        x = {"n": int(s.get("n") or 1) if s.get("n") in (1, 2) else 1, "last_ok": num(s.get("last_ok")), "last_ok_src": str(s.get("last_ok_src") or "")[:30] or None,
             "last_check": num(s.get("last_check")), "last_fail": num(s.get("last_fail")), "fail_n": int(num(s.get("fail_n")) or 0),
             "src": s.get("src") if s.get("src") in ("dab", "rds") else None, "ch": str(s.get("ch") or "")[:12] or None, "why": str(s.get("why") or "")[:120] or None,
             "inc": None, "last_inc": s.get("last_inc") if isinstance(s.get("last_inc"), dict) else None}
        i = s.get("inc")
        if isinstance(i, dict) and num(i.get("since")):
            x["inc"] = {"since": num(i["since"]), "t0": num(i.get("t0")) or num(i["since"]), "ch": str(i.get("ch") or "")[:12] or None,
                        "src": i.get("src") if i.get("src") in ("dab", "rds") else None, "restart_n": int(num(i.get("restart_n")) or 0),
                        "usb_n": int(num(i.get("usb_n")) or 0), "reboot_n": int(num(i.get("reboot_n")) or 0), "act": i.get("act") if i.get("act") in ("restart", "usb", "reboot") else None,
                        "act_t": num(i.get("act_t")), "chk": int(num(i.get("chk")) or 0), "lg": int(num(i.get("lg")) or 0), "block": str(i.get("block") or "")[:120] or None,
                        "blk_t": num(i.get("blk_t")) or 0, "usb_last": str(i.get("usb_last") or "")[:120] or None}
        o["sticks"][sn] = x
    o["reboots"] = [{"t": int(r["t"]), "sn": str(r.get("sn") or "")[:16], "n": r.get("n"), "ch": str(r.get("ch") or "")[:12], "ok": r.get("ok") if r.get("ok") in (True, False, None) else None,
                     "why": str(r.get("why") or "")[:120]} for r in (d.get("reboots") or []) if isinstance(r, dict) and num(r.get("t"))][-60:]
    o["reboot_fail_n"] = int(num(d.get("reboot_fail_n")) or 0)
    o["rb_sn"] = str(d.get("rb_sn"))[:16] if d.get("rb_sn") else None
    pd = d.get("pending")
    o["pending"] = {"t": int(pd["t"]), "sn": str(pd.get("sn") or "")[:16]} if isinstance(pd, dict) and num(pd.get("t")) else None
    o["stopped"] = d.get("stopped") is True
    return o


def _wd_db(base):
    try:
        if base not in sys.path:
            sys.path.insert(0, base)
        import database as _wd_d
        return _wd_d
    except Exception:
        return None


def _wd_load(base, now):
    """Zustand laden: neuerer Stand aus lagezentrum.db (state sdr_wd) oder sdr_wd.json. Offener Pi-Neustart = erfolgt (neuer Prozess)."""
    a = load_json(p(WD_FILE, base), None)
    b = None
    dbp = os.path.join(base, "lagezentrum.db")
    if os.path.exists(dbp):
        dbm = _wd_db(base)
        try:
            r = dbm.state_get(WD_KEY, dbp, timeout=1.0) if dbm is not None else {}
            if r.get("ok") and r.get("text"):
                b = json.loads(r["text"])
        except Exception:
            b = None
    ta = a.get("t") if isinstance(a, dict) and isinstance(a.get("t"), (int, float)) else -1
    tb = b.get("t") if isinstance(b, dict) and isinstance(b.get("t"), (int, float)) else -1
    d = _wd_clean(b if tb > ta else a)
    msgs = []
    pd = d.get("pending")
    if pd:
        for r in d["reboots"][::-1]:
            if r["t"] == pd["t"]:
                r["ok"] = True
                r["why"] = (r.get("why") or "") + " · erfolgt"
                break
        d["pending"] = None
        for sn, s in d["sticks"].items():
            i = s.get("inc")
            if i:
                i.update(t0=int(now), restart_n=0, usb_n=0, act=None, act_t=None, chk=0, lg=max(1, i.get("lg") or 0), block=None, blk_t=0)
        msgs.append(("wd_boot", "Pi-Neustart durch Watchdog erfolgt (angefordert %s, %d/%d ohne Erfolg) – Sticks werden neu geprüft"
                     % (_wd_hm(pd["t"], now), d["reboot_fail_n"], int(wd_cfg(base)["wd_reboot_max_fail"])), None, "gelb"))
        _WD["dirty"] = True
    return d, msgs


def _wd_state(base, now=None):
    """Zustand im Speicher (einmal je Prozess geladen). Nur unter _WD_LOCK aufrufen. -> (Zustand, Meldungen)"""
    now = now or time.time()
    if _WD["d"] is None or _WD["base"] != base:
        try:
            d, msgs = _wd_load(base, now)
        except Exception as e:
            print("sdrWd Zustand laden:", e, flush=True)
            d, msgs = _wd_new(), []
        _WD.update(d=d, base=base, started=set())
        _WD.setdefault("boot_msgs", [])
        _WD["boot_msgs"] = msgs
    return _WD["d"]


def _wd_save(base, now, force=False):
    """Atomar sdr_wd.json (fsync) + lagezentrum.db state sdr_wd, wenn geaendert (gedrosselt) oder alle 5 min. Nur unter _WD_LOCK."""
    d = _WD["d"]
    if d is None or not (force or (_WD["dirty"] and now - _WD["saved"] >= 20) or now - _WD["saved"] >= WD_SAVE_S):
        return False
    d["t"] = int(now)
    s = json.dumps(d, ensure_ascii=False, separators=(",", ":"))
    fn = p(WD_FILE, base)
    tmp = fn + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(s)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, fn)
    except Exception as e:
        print("sdrWd speichern:", e, flush=True)
    dbp = os.path.join(base, "lagezentrum.db")
    if os.path.exists(dbp):
        dbm = _wd_db(base)
        try:
            if dbm is not None and not dbm.state_put(WD_KEY, s, now, dbp, "prepper-sdr"):
                raise RuntimeError("state_put")
        except Exception as e:
            if now - _WD["err_t"] > 600:
                _WD["err_t"] = now
                print("sdrWd DB speichern (JSON ok):", e, flush=True)
    _WD["dirty"], _WD["saved"] = False, now
    return True


def _wd_emit(base, msgs, now):
    """Meldungen in den Technik-Verlauf (sdr_techlog.json) - ausserhalb von _WD_LOCK aufrufen."""
    if not msgs:
        return
    try:
        with _SDRLOG_LOCK:
            tl = sdrlog_get(base)
            for k, text, ch, lvl in msgs:
                tl.add(k, "tech", text, now, ch, lvl, save=False)
            tl.save()
    except Exception as e:
        print("sdrWd Technik-Verlauf:", e, flush=True)


def _wd_name(n, i):
    ch = (i or {}).get("ch") or "?"
    return "Stick %d · %s" % (int(n or 1), ch)


def _wd_seed(pl, src, ch, now):
    """Beginn ohne Empfang: letzte echte Empfangszeit aus broadcast_state (dabGain behaelt t = letzter echter Empfang)."""
    try:
        d = pl.sbc.d
        e = (d.get("dab") or {}).get(ch) if src == "dab" else (d.get("fm") or {}).get(ch)
        t = e.get("t") if isinstance(e, dict) else None
        if isinstance(t, (int, float)) and now - 7 * 86400 < t < now:
            return int(t)
    except Exception:
        pass
    return int(now)


def wd_check(pl, src, ok, now, ch=None, why=None):
    """Ergebnis einer Pruefung (DAB-Block / RDS-Fenster) dieses Sticks. ok = echter Empfang."""
    sn = cfg_serial(pl.cfg)
    if not sn:
        return
    msgs = []
    seed = None if ok else _wd_seed(pl, src, ch, now)
    with _WD_LOCK:
        d = _wd_state(pl.base, now)
        s = d["sticks"].get(sn)
        if s is None:
            s = d["sticks"][sn] = _wd_clean({"sticks": {sn: {"n": int(pl.stickno or 1)}}})["sticks"][sn]
        s.update(n=int(pl.stickno or 1), last_check=int(now), src=src, ch=str(ch or "")[:12] or None)
        i = s.get("inc")
        if ok:
            s.update(last_ok=int(now), last_ok_src=("%s %s" % ("DAB" if src == "dab" else "RDS", ch or ""))[:30], fail_n=0, why=None)
            if i:
                dur = now - i["since"]
                msgs.append(("wd_ok", "%s wieder Sync nach %s (ohne Empfang %s–%s, %s)" % (_wd_name(s["n"], dict(i, ch=ch or i.get("ch"))), WD_ACT_TXT.get(i.get("act"), "Gain-Leiter"),
                                                                                         _wd_hm(i["since"], now), _wd_hm(now, now), _wd_dur(dur)), ch, "ok"))
                s["last_inc"] = {"since": i["since"], "end": int(now), "act": i.get("act"), "usb_n": i.get("usb_n"), "reboot_n": i.get("reboot_n")}
                s["inc"] = None
            if d["reboot_fail_n"] and (d.get("rb_sn") in (None, sn) or not any(x.get("inc") for x in d["sticks"].values())):
                d["reboot_fail_n"], d["stopped"], d["rb_sn"] = 0, False, None
                msgs.append(("wd_rearm", "Pi-Neustart-Automatik wieder bereit (Stick %d hat wieder echten Empfang)" % s["n"], ch, "ok"))
        else:
            s.update(fail_n=int(s.get("fail_n") or 0) + 1, last_fail=int(now), why=str(why or "kein Empfang")[:120])
            if not i:
                since = int(s["last_ok"]) if s.get("last_ok") and s["last_ok"] <= now else int(seed or now)
                s["inc"] = {"since": since, "t0": since, "ch": str(ch or "")[:12] or None, "src": src, "restart_n": 0, "usb_n": 0, "reboot_n": 0, "act": None,
                            "act_t": None, "chk": 1, "lg": 0, "block": None, "blk_t": 0, "usb_last": None}
            else:
                i["chk"] = int(i.get("chk") or 0) + 1
                if ch:
                    i["ch"] = str(ch)[:12]
        _WD["dirty"] = True
        _wd_save(pl.base, now, force=bool(msgs))
    _wd_emit(pl.base, msgs, now)


def _wd_helper(args, timeout):
    """Root-Hilfsprogramm aufrufen (als root direkt, sonst sudo -n nur fuer genau dieses Programm). -> (rc, Text)"""
    if not _WD.get("live"):
        return 125, "nicht im Dienst (Selbsttest) - nichts ausgefuehrt"
    h = os.environ.get("SDR_WD_HELPER") or WD_HELPER
    if not os.path.isfile(h):
        return 127, "Hilfsprogramm fehlt (%s)" % h
    cmd = ([h] if os.geteuid() == 0 else ["sudo", "-n", h]) + [str(a) for a in args]
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        lines = (r.stdout or "").strip().splitlines() or (r.stderr or "").strip().splitlines() or [""]
        return r.returncode, lines[-1][:160]
    except subprocess.TimeoutExpired:
        return 124, "Zeitueberschreitung nach %d s" % timeout
    except Exception as e:
        return 126, str(e)[:120]


def wd_helper_state(force=False):
    """Einmal je Prozess: Hilfsprogramm da und Berechtigung ok? (Aufruf check aendert nichts)."""
    h = _WD.get("helper")
    if h is not None and not force and time.time() - h.get("t", 0) < 6 * 3600:
        return h
    rc, txt = _wd_helper(["check"], 20)
    h = {"t": time.time(), "ok": rc == 0, "rc": rc, "txt": ("bereit" if rc == 0 else ("fehlt" if rc == 127 else "keine Berechtigung/Fehler (rc %d: %s)" % (rc, txt)))[:120]}
    _WD["helper"] = h
    return h


def _wd_block(pl, now, sn):
    """Sperrgrund fuer Stufen 2-4 oder None. Pruef-Fehler = gesperrt."""
    try:
        if t2_takeover(pl.base).get("on"):
            return "Alarm-Übernahme Stick 2 (5C/10C) aktiv"
        m = getattr(pl, "main", None) or pl
        if getattr(m, "st_pause", False) or getattr(pl, "st_pause", False):
            return "Antennentest läuft"
        g = load_json(p(WD_GATE, pl.base), {}) or {}
        if isinstance(g, dict) and g.get("alarm") is True and isinstance(g.get("t"), (int, float)) and -60 <= now - g["t"] <= 900:
            return "echter Alarm im Lagezentrum"
        with pl.lock:
            fm = [dict(x) for x in (pl.sbc.d.get("fm") or {}).values() if isinstance(x, dict)]
            wl = [dict(x) for x in (pl.sbc.d.get("warn") or [])[-40:] if isinstance(x, dict)]
        for s in fm:
            if s.get("pty31_persist") and now - (s.get("pty31_last") or 0) <= 900:
                return "RDS-Alarm PTY 31 (%s)" % (s.get("name") or "?")
        for w in wl:
            if str(w.get("src") or "").startswith("DAB 5C") and w.get("kind") in ("DLS", "Ansage") and now - (w.get("last") or w.get("t") or 0) <= 7200:
                return "ASA-Warnung/Ansage auf 5C (letzte 2 h)"
        if getattr(pl, "pmeteor", None):
            return "Meteor-Aufnahme läuft"
        if _WD.get("busy") and _WD["busy"] != sn:
            return "anderer Stick wird gerade zurückgesetzt"
        return None
    except Exception as e:
        return "Alarm-Prüfung fehlgeschlagen (%s)" % str(e)[:60]


def _wd_today(d, now):
    day = time.localtime(now)[:3]
    rs = [r for r in d.get("reboots") or [] if r.get("ok") is not False]
    return len([r for r in rs if time.localtime(r["t"])[:3] == day]), (rs[-1] if rs else None)


def _wd_decide(d, s, i, c, now):
    """Naechste Stufe -> ("restart"|"usb"|"reboot"|"stop"|"wait", Text) oder (None, None)."""
    el = now - max(i["since"], i.get("t0") or i["since"])
    if i.get("act_t") and (now - i["act_t"] < c.get("wd_verify_s", WD_VERIFY_S) or int(i.get("chk") or 0) < 2):
        return None, None
    if not i.get("restart_n") and el >= c["wd_restart_min"] * 60:
        return "restart", None
    if i.get("usb_n", 0) < c["wd_usb_max"] and el >= c["wd_usb_min"] * 60:
        return "usb", None
    if el >= c["wd_reboot_min"] * 60 and i.get("usb_n", 0) >= c["wd_usb_max"]:
        if c["wd_reboot_max_fail"] <= 0:
            return "wait", "Pi-Neustart abgeschaltet (wd_reboot_max_fail 0)"
        if d["reboot_fail_n"] >= c["wd_reboot_max_fail"]:
            return "stop", None
        last = max([r["t"] for r in d.get("reboots") or []] + [0])
        nx = last + c["wd_reboot_min_interval_min"] * 60
        if now < nx:
            return "wait", "nächster Pi-Neustart frühestens %s (höchstens 1 je %d min)" % (_wd_hm(nx, now), int(c["wd_reboot_min_interval_min"]))
        return "reboot", None
    return None, None


def wd_tick(pl, now):
    """Nach jedem Planer-Schritt: Startmeldung, Stufen auswerten, hoechstens eine Aktion. Fehler nie nach aussen."""
    sn = cfg_serial(pl.cfg)
    if not sn:
        return
    c = wd_cfg(pl.base)
    msgs, act = [], None
    with _WD_LOCK:
        d = _wd_state(pl.base, now)
        if _WD.get("boot_msgs"):
            msgs += _WD["boot_msgs"]
            _WD["boot_msgs"] = []
        pd = d.get("pending")
        if pd and now - pd["t"] > WD_PENDING_S:
            for r in d["reboots"][::-1]:
                if r["t"] == pd["t"]:
                    r.update(ok=False, why=(r.get("why") or "") + " · nicht erfolgt")
                    break
            d["pending"] = None
            d["reboot_fail_n"] = max(0, d["reboot_fail_n"] - 1)
            msgs.append(("wd_reboot", "Pi-Neustart angefordert um %s, aber nicht erfolgt - Automatik versucht es frühestens nach der Wartezeit erneut" % _wd_hm(pd["t"], now), None, "rot"))
            _WD["dirty"] = True
        s = d["sticks"].get(sn)
        i = s.get("inc") if s else None
        if s and sn not in _WD["started"]:
            _WD["started"].add(sn)
            if i:
                msgs.append(("wd_start", "Start: %s kein Sync seit %s (%s · USB-Resets %d/%d · Pi-Neustarts ohne Erfolg %d/%d)" % (
                    _wd_name(s["n"], i), _wd_hm(i["since"], now), ("Stufe %d" % _wd_stage(d, i)) if _wd_stage(d, i) else "Stufe 0",
                    i.get("usb_n", 0), int(c["wd_usb_max"]), d["reboot_fail_n"], int(c["wd_reboot_max_fail"])), i.get("ch"), "gelb"))
        if i and not d.get("pending"):
            dur = now - i["since"]
            fresh = int(s.get("fail_n") or 0) >= 2 and now - (s.get("last_fail") or 0) <= WD_EVID_S
            if fresh and dur >= c["wd_yellow_min"] * 60 and not i.get("lg"):
                i["lg"] = 1
                msgs.append(("wd_stage", "%s kein Sync seit %s · Stufe 1 gelb (%s)" % (_wd_name(s["n"], i), _wd_hm(i["since"], now), WD_STAGE_TXT[1]), i.get("ch"), "gelb"))
                _WD["dirty"] = True
            if fresh and not c["wd_enable"]:
                i["block"] = "Automatik aus (sdr_config.json wd_enable)"
            elif fresh and not _WD.get("live"):
                i["block"] = "nur Anzeige (nicht im Dienst)"
            elif fresh and now - _WD["start"] < c.get("wd_start_grace_s", WD_START_GRACE_S):
                i["block"] = "Startphase: Aktionen frühestens %s" % _wd_hm(_WD["start"] + c.get("wd_start_grace_s", WD_START_GRACE_S), now)
            elif fresh and pl.active not in ("nostick", "pause"):
                a, why = _wd_decide(d, s, i, c, now)
                blk = _wd_block(pl, now, sn) if a in ("restart", "usb", "reboot") else None
                if a == "stop":
                    if not d.get("stopped"):
                        d["stopped"] = True
                        msgs.append(("wd_stop", "%s kein Sync seit %s · keine weiteren Pi-Neustarts (%d ohne Erfolg) – Stick/Antenne prüfen" % (
                            _wd_name(s["n"], i), _wd_hm(i["since"], now), d["reboot_fail_n"]), i.get("ch"), "rot"))
                    i["block"] = "%d Pi-Neustarts ohne Erfolg – Stick/Antenne prüfen" % d["reboot_fail_n"]
                    _WD["dirty"] = True
                elif a == "wait":
                    i["block"] = why
                elif blk:
                    if i.get("block") != blk or now - (i.get("blk_t") or 0) > WD_BLOCKLOG_S:
                        msgs.append(("wd_block", "%s kein Sync seit %s · Stufe %d gesperrt: %s" % (
                            _wd_name(s["n"], i), _wd_hm(i["since"], now), {"restart": 2, "usb": 3, "reboot": 4}[a], blk), i.get("ch"), "gelb"))
                        i["blk_t"] = int(now)
                    i["block"] = blk
                    _WD["dirty"] = True
                elif a:
                    i["block"] = None
                    act = a
                    _WD["busy"] = sn
                    i["act"], i["act_t"], i["chk"] = a, int(now), 0
                    if a == "restart":
                        i["restart_n"] = int(i.get("restart_n") or 0) + 1
                        msgs.append(("wd_stage", "%s kein Sync seit %s · Stufe 2 %s" % (_wd_name(s["n"], i), _wd_hm(i["since"], now), WD_STAGE_TXT[2]), i.get("ch"), "rot"))
                    elif a == "usb":
                        i["usb_n"] = int(i.get("usb_n") or 0) + 1
                        msgs.append(("wd_stage", "%s kein Sync seit %s · Stufe 3 USB-Neuverbindung (%d/%d, nur SN %s)" % (
                            _wd_name(s["n"], i), _wd_hm(i["since"], now), i["usb_n"], int(c["wd_usb_max"]), sn), i.get("ch"), "rot"))
                    else:
                        today, _ = _wd_today(d, now)
                        d["reboot_fail_n"] = int(d["reboot_fail_n"]) + 1
                        d["rb_sn"] = sn
                        i["reboot_n"] = int(i.get("reboot_n") or 0) + 1
                        d["pending"] = {"t": int(now), "sn": sn}
                        d["reboots"].append({"t": int(now), "sn": sn, "n": s["n"], "ch": i.get("ch") or "", "ok": None,
                                             "why": "kein Sync seit %s" % _wd_hm(i["since"], now)})
                        d["reboots"] = d["reboots"][-60:]
                        msgs.append(("wd_reboot", "%s kein Sync seit %s · Stufe 4 Pi-Neustart (%d/%d ohne Erfolg, heute %d.)" % (
                            _wd_name(s["n"], i), _wd_hm(i["since"], now), d["reboot_fail_n"], int(c["wd_reboot_max_fail"]), today + 1), i.get("ch"), "rot"))
                    _WD["dirty"] = True
        _wd_save(pl.base, now, force=bool(msgs) or act is not None)
        ctx = (s["n"], dict(i)) if act and i else None
    _wd_emit(pl.base, msgs, now)
    if act:
        try:
            _wd_do(pl, act, sn, ctx, now)
        finally:
            with _WD_LOCK:
                _WD["busy"] = None


def _wd_stage(d, i):
    if not i:
        return 0
    if d.get("stopped") or i.get("reboot_n") or (d.get("pending") or {}).get("sn"):
        return 4
    if i.get("usb_n"):
        return 3
    if i.get("restart_n"):
        return 2
    return 1 if i.get("lg") else 0


def _wd_do(pl, act, sn, ctx, now):
    """Aktion ausfuehren (Stufe 2/3/4). Nie im Selbsttest echt: _wd_helper wird dort ersetzt."""
    n, i = ctx
    nm = _wd_name(n, i)
    msgs = []
    if act == "restart":
        pl.kill()
        pl.active, pl.retry_at, pl.fails = "idle", 0, 0
        pl.log("sdrWd: %s Stufe 2 - welle-cli + rtl_tcp neu gestartet" % nm)
    elif act == "usb":
        if not WD_SN_RE.match(sn):
            msgs.append(("wd_usb", "%s USB-Neuverbindung nicht möglich: Seriennummer %s hat nicht 8 Ziffern" % (nm, sn), i.get("ch"), "rot"))
        else:
            pl.kill()
            pl.active, pl.retry_at, pl.fails = "idle", 0, 0
            rc, txt = _wd_helper(["usb-reset", sn], 90)
            seen = False
            for _ in range(20):
                if any(str(x.get("serial")) == sn for x in stick_info(pl.cfg["usb_ids"])):
                    seen = True
                    break
                time.sleep(1)
            idx = None
            if seen:
                try:
                    pl.resolve()
                    idx = pl.dev_idx
                except Exception as e:
                    txt = (txt + " · Index: %s" % e)[:160]
            ok = rc == 0 and seen
            det = ("Stick wieder da (SN %s, Index %s) – prüfe Empfang" % (sn, idx if idx is not None else "?")) if ok else \
                ("fehlgeschlagen (rc %d: %s)%s" % (rc, txt, "" if seen else " · Stick nicht wieder gemeldet"))
            msgs.append(("wd_usb", "%s USB-Neuverbindung %d: %s" % (nm, int(i.get("usb_n") or 0), det), i.get("ch"), "ok" if ok else "rot"))
            with _WD_LOCK:
                st = _wd_state(pl.base, now)
                ii = (st["sticks"].get(sn) or {}).get("inc")
                if ii:
                    ii["usb_last"] = ("ok" if ok else "rc %d: %s" % (rc, txt))[:120]
                    _WD["dirty"] = True
            pl.log("sdrWd: %s USB-Neuverbindung rc %d (%s), Stick %s" % (nm, rc, txt, "da" if seen else "FEHLT"))
    elif act == "reboot":
        rc, txt = _wd_helper(["reboot"], 30)
        pl.log("sdrWd: %s Pi-Neustart angefordert rc %d (%s)" % (nm, rc, txt))
        if rc != 0:
            with _WD_LOCK:
                d = _wd_state(pl.base, now)
                pd = d.get("pending")
                for r in d["reboots"][::-1]:
                    if pd and r["t"] == pd["t"]:
                        r.update(ok=False, why=(r.get("why") or "") + " · abgelehnt rc %d: %s" % (rc, txt))
                        break
                d["pending"] = None
                d["reboot_fail_n"] = max(0, d["reboot_fail_n"] - 1)
                _WD["dirty"] = True
            msgs.append(("wd_reboot", "%s Pi-Neustart nicht möglich (rc %d: %s)" % (nm, rc, txt), i.get("ch"), "rot"))
    with _WD_LOCK:
        _wd_save(pl.base, time.time(), force=True)
    _wd_emit(pl.base, msgs, time.time())


def wd_view(pl, now):
    """Anzeige je Stick (in stick_health[wd]) + gemeinsamer Teil (Pi-Neustarts)."""
    sn = cfg_serial(pl.cfg)
    c = wd_cfg(pl.base)
    with _WD_LOCK:
        d = _wd_state(pl.base, now)
        s = dict(d["sticks"].get(sn) or {})
        i = dict(s.get("inc") or {}) if s.get("inc") else None
        today, last = _wd_today(d, now)
        g = {"reboots_today": today, "last_reboot": last["t"] if last else None, "last_reboot_ok": last.get("ok") if last else None,
             "reboot_fail_n": d["reboot_fail_n"], "reboot_max_fail": int(c["wd_reboot_max_fail"]), "stopped": bool(d.get("stopped")),
             "pending": (d.get("pending") or {}).get("t"), "on": bool(c["wd_enable"]), "helper": (_WD.get("helper") or {}).get("txt"),
             "cfg": {k: c[k] for k in WD_DEFAULTS}}
        stage = _wd_stage(d, i)
    n = int(pl.stickno or 1)
    v = {"sn": sn, "n": n, "on": bool(c["wd_enable"]), "last_ok": s.get("last_ok"), "last_ok_src": s.get("last_ok_src"), "last_check": s.get("last_check"),
         "fail_n": int(s.get("fail_n") or 0), "src": s.get("src"), "ch": (i or {}).get("ch") or s.get("ch"), "stage": stage, "usb_max": int(c["wd_usb_max"]), "g": g}
    nm = "Stick %d%s" % (n, (" · " + v["ch"]) if v["ch"] else "")
    if not s.get("last_check"):
        v.update(lvl="grau", txt="%s noch keine Prüfung seit Start" % nm)
    elif not i:
        v.update(lvl="ok", txt="%s Empfang ok (zuletzt %s)" % (nm, _wd_hm(s.get("last_ok"), now)) if s.get("last_ok") else "%s Empfang ok" % nm)
    else:
        dur = now - i["since"]
        stale = now - (s.get("last_check") or 0) > WD_EVID_S
        lvl = "rot" if (dur >= c["wd_restart_min"] * 60 or stage >= 2) else ("gelb" if dur >= c["wd_yellow_min"] * 60 else "ok")
        if stale:
            lvl = "grau" if lvl == "ok" else lvl
        st = ("Stufe 4 gestoppt – Stick/Antenne prüfen" if d.get("stopped") and stage == 4 else
              ("Stufe %d %s%s" % (stage, WD_STAGE_TXT[stage], (" (%d/%d)" % (i.get("usb_n", 0), int(c["wd_usb_max"]))) if stage == 3 else "") if stage else "kurz ohne Sync"))
        v.update(lvl=lvl, since=i["since"], dur_s=int(dur), restart_n=i.get("restart_n", 0), usb_n=i.get("usb_n", 0), reboot_n=i.get("reboot_n", 0),
                 block=i.get("block"), usb_last=i.get("usb_last"),
                 txt="%s kein Sync seit %s · %s%s" % (nm, _wd_hm(i["since"], now), st, (" · gesperrt: %s" % i["block"]) if i.get("block") else ""),
                 hint=("Automatik: Stufe 2 ab %g min, USB-Neuverbindung ab %g min (max %d), Pi-Neustart ab %g min (max 1 je %g min, Stopp nach %d)" % (
                     c["wd_restart_min"], c["wd_usb_min"], c["wd_usb_max"], c["wd_reboot_min"], c["wd_reboot_min_interval_min"], c["wd_reboot_max_fail"]))
                 if c["wd_enable"] else "Automatik aus (wd_enable) – Stick einmal ab- und wieder anstecken")
        if stale:
            v["txt"] += " · letzte Prüfung %s" % _wd_hm(s.get("last_check"), now)
    return v


_wd_orig_sub_done = Planner.sub_done
_wd_orig_step = Planner.step
_wd_orig_start = Planner.start
_wd_orig_stick_health = Planner.stick_health
_wd_orig_dual_tick = Planner.dual_tick
_wd_orig_tl_dab = TechLog.dab
_wd_orig_loop = Planner.loop


def _wd_loop(self):
    _WD["live"] = True      # Dienst: Stufen 2-4 erlaubt
    try:
        h = wd_helper_state(True)
        c = wd_cfg(self.base)
        self.log("sdrWd aktiv: Daten-Watchdog %s - gelb %g min, Neustart %g min, USB %g min (max %d), Pi-Neustart %g min (max 1 je %g min, Stopp nach %d); Hilfsprogramm %s" % (
            "AN" if c["wd_enable"] else "AUS (wd_enable)", c["wd_yellow_min"], c["wd_restart_min"], c["wd_usb_min"], c["wd_usb_max"], c["wd_reboot_min"],
            c["wd_reboot_min_interval_min"], c["wd_reboot_max_fail"], h.get("txt")))
    except Exception as ex:
        print("sdrWd Start:", ex, flush=True)
    return _wd_orig_loop(self)


def _wd_start(self, what):
    try:
        self.__dict__["_wd_c0"] = (str(what), int((self.counts or {}).get("rds", 0)))
    except Exception:
        pass
    return _wd_orig_start(self, what)


def _wd_sub_done(self, sp, now):
    pre = None
    try:
        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") and 0 <= int(sp.get("i", 0)) < len(sp["queue"]) else ""
        ran = now - float(self.since or now)
        if job.startswith("dab:"):
            pre = ("dab", str(self.dab_list()[int(job[4:])]), ran, self.alive(), None)
        elif job.startswith("rds:"):
            f = self.fm_list()[int(job[4:])]
            c0 = self.__dict__.get("_wd_c0")
            pre = ("rds", str(f.get("name") if isinstance(f, dict) else f)[:20], ran, self.alive(), c0[1] if isinstance(c0, tuple) and c0[0] == job else None)
    except Exception:
        pre = None
    try:
        return _wd_orig_sub_done(self, sp, now)
    finally:
        try:
            if pre:
                _wd_eval(self, pre, now)
        except Exception as ex:
            print("sdrWd Pruefung:", ex, flush=True)


def _wd_eval(pl, pre, now):
    kind, ch, ran, alive, c0 = pre
    if kind == "dab":
        e = ((pl.sbc.d.get("dab") or {}).get(ch) or {})
        if e.get("rx") is True and isinstance(e.get("t"), (int, float)) and now - e["t"] <= 15:
            ok, why = True, None
        elif isinstance(e.get("err_t"), (int, float)) and now - e["err_t"] <= 15 and ran >= WD_MIN_RAN_S:
            ok, why = False, "welle-cli ohne Status: %s" % str(e.get("err") or "?")[:60]
        elif e.get("rx") is False and isinstance(e.get("try_t"), (int, float)) and now - e["try_t"] <= 15 and ran >= WD_MIN_RAN_S:
            dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
            ok, why = False, "%s, SNR %s" % (e.get("rx_why") or "kein Sync", dm.get("snr"))
        elif not alive and ran >= WD_MIN_RAN_S:
            ok, why = False, "DAB-Prozess beendet"
        else:
            return
        if pl.role == "bc":
            pl.raw_fail = 0 if ok else int(pl.raw_fail or 0) + 1   # Rolle bc: DAB-Pruefung ohne Sync = Messung ohne Daten
            if ok:
                pl.raw_t = time.time()
        wd_check(pl, "dab", ok, now, ch, why)
    elif kind == "rds" and c0 is not None:
        n = int((pl.counts or {}).get("rds", 0)) - int(c0)
        if n > 0:
            wd_check(pl, "rds", True, now, ch)
        elif ran >= max(20, WD_MIN_RAN_S):
            wd_check(pl, "rds", False, now, ch, "0 RDS-Gruppen in %d s" % ran)


def _wd_step(self):
    r = _wd_orig_step(self)
    try:
        wd_tick(self, time.time())
    except Exception as ex:
        print("sdrWd:", ex, flush=True)
    return r


def _wd_dual_tick(self):
    if _WD.get("busy"):
        return None    # USB-Neuverbindung laeuft: Rollen nicht umschalten
    return _wd_orig_dual_tick(self)


def _wd_stick_health(self, now):
    r = _wd_orig_stick_health(self, now)
    try:
        v = wd_view(self, now)
        r = dict(r)
        r["wd"] = v
        if not self.pin_err and v.get("lvl") in ("gelb", "rot") and v.get("src") == "dab":
            r.update(lvl="rot" if r.get("lvl") == "rot" or v["lvl"] == "rot" else "gelb", txt="Stick ohne DAB-Empfang", why=v["txt"], hint=v.get("hint"), since=v.get("since"))
        elif "kein automatischer USB-Reset" in str(r.get("hint") or ""):
            r["hint"] = str(r["hint"]).replace("(kein automatischer USB-Reset)", "(Watchdog: USB-Neuverbindung nach %d min ohne Empfang)" % int(wd_cfg(self.base)["wd_usb_min"]))
    except Exception as ex:
        print("sdrWd Anzeige:", ex, flush=True)
    return r


def _wd_tl_dab(self, ch, e, fig, t2ev, now):
    try:
        chu = str(ch).upper()
        prev = (self.st.get("sync") or {}).get(chu) if isinstance(self.st.get("sync"), dict) else None
        rx = e.get("rx") if isinstance(e, dict) else None
    except Exception:
        chu, prev, rx = None, None, None
    r = _wd_orig_tl_dab(self, ch, e, fig, t2ev, now)
    try:
        fl = self.__dict__.setdefault("_wd_nostart", {})
        if rx is False and prev is None:
            fl[chu] = True
        elif rx is True:
            fl.pop(chu, None)
        elif rx is False and prev is False and fl.get(chu) and int(self.cand.get(chu, 0)) >= SDRLOG_LOST_N:
            fl.pop(chu, None)
            self.add("sync_lost", "tech", "DAB %s ohne Sync seit Start (%s, %d Prüfungen ohne Sync)" % (chu, e.get("rx_why") or "kein Sync", int(self.cand.get(chu, 0))),
                     now, chu, "gelb", save=False)
            r = True
    except Exception as ex:
        print("sdrWd Technik-Verlauf DAB:", ex, flush=True)
    return r


Planner.start = _wd_start
Planner.sub_done = _wd_sub_done
Planner.step = _wd_step
Planner.dual_tick = _wd_dual_tick
Planner.stick_health = _wd_stick_health
Planner.loop = _wd_loop
TechLog.dab = _wd_tl_dab


# ----- sdrWd/mastFix: MASTS_DB vollstaendig je Kanal (Frank 18.10.2026 als Basis, bei Widerspruch gewinnt die Quelle: fmlist.org Sendertabelle 10A5/10BC/10AD, Wikipedia, OpenStreetMap; dazu Ueberreichweite: gleicher Kanal, anderes Ensemble bis etwa 255 km um Kalchreuth, Ensemble im Namen) - nur Namen/Lage fuer Anzeige, TII-Codes je Kanal eindeutig -----
WD_MF_KEYS = ('main', 'sub', 'mast', 'lat', 'lon', 'h_mast', 'site_m', 'ant_m', 'erp_kw', 'km', 'ens', 'src')
WD_MF = {
    '11D': (
        (8, 18, 'Bamberg (Geisberg)', 49.8893, 11.062, 115, 585, 104, 10, 37, None, 'live empfangen 17.10.2026 (TII-Ereignis 11D); TII laut fmlist 10A5 (korrigiert gegen Liste Frank 18.10.2026); Lage OSM Sender Bamberg (Geisberg) Gipfel'),
        (5, 14, 'Nürnberg (Schweinau)', 49.42639, 11.03778, 292, 318, 260, 10, 17, None, 'live empfangen 17.10.2026 (TII-Ereignis 11D); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (5, 1, 'Hersbruck', 49.5181, 11.46, None, 499, 43, 5, 22, None, 'fmlist Ensemble 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (5, 13, 'Dillberg (Neumarkt)', 49.32639, 11.38194, 231, 595, 194, 10, 31, None, 'fmlist 10A5 (Abruf 18.10.2026); TII laut fmlist 10A5 (korrigiert gegen Liste Frank 18.10.2026)'),
        (8, 1, 'Ochsenkopf (Fichtelgebirge)', 50.03111, 11.81389, 176, 1013, 169, 10, 71, None, 'fmlist 10A5 (Abruf 18.10.2026); TII laut fmlist 10A5 (korrigiert gegen Liste Frank 18.10.2026)'),
        (5, 15, 'Büttelberg (Frankenhöhe)', 49.4146, 10.378, 220, 527, 159, 10, 58, None, 'fmlist 10A5 (Abruf 18.10.2026); TII laut fmlist 10A5 (korrigiert gegen Liste Frank 18.10.2026)'),
        (5, 11, 'Hesselberg (Wassertrüdingen)', 49.0682, 10.5257, None, 678, 76, 10, 71, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (7, 2, 'Amberg (Hirschau/Rotbühl)', 49.5088, 12.0048, None, 666, 95, 10, 62, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (7, 12, 'Hohe Linie (Regensburg)', 49.0397, 12.1716, None, 474, 140, 10, 94, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (8, 4, 'Ebermannstadt (Pretzfeld)', 49.73804, 11.18093, None, 477, 34, 5, 20, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Funkmast 54 m bei Pretzfeld, Gelaendehoehe passt zu fmlist'),
        (7, 6, 'Weigendorf (Ernhüll)', 49.51255, 11.59309, None, 551, 34, 4, 32, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (8, 3, 'Pegnitz (Gunzerberg)', 49.75433, 11.55942, None, 493, 28, 8, 36, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (8, 10, 'Burgwindheim', 49.79494, 10.61092, None, 428, 138, 6.3, 47, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (7, 1, 'Amberg-Süd (Ödengaudorf)', 49.41806, 11.87917, 95, 383, 45, 1, 55, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (5, 5, 'Weißenburg (Rohrberg)', 49.04379, 11.01065, None, 598, 33, 6.3, 58, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (8, 8, 'Kulmbach (Rehberg)', 50.10043, 11.4698, None, 485, 27, 10, 64, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 18, 'Zeil am Main (Schleifberg)', 50.01886, 10.59943, None, 350, 27, 10, 65, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 21, 'Ebern (Haubeberg)', 50.1088, 10.73589, None, 430, 34, 2, 68, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (5, 6, 'Treuchtlingen (Schloßberg)', 48.95758, 10.90142, None, 491, 21, 1.3, 69, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (1, 5, 'Gelbelsee', 48.94642, 11.42872, 112, 539, 105, 10, 71, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (1, 4, 'Eichstätt (Schönblick)', 48.90125, 11.16175, None, 480, 8, 1, 73, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (7, 11, 'Altenstadt (Oberpfalz)', 49.71833, 12.15833, 85, 504, 36, 1, 74, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (5, 2, 'Rothenburg ob der Tauber (Deponie)', 49.38556, 10.22444, 65, 420, 33, 1, 70, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (8, 6, 'Kronach', 50.21371, 11.33228, None, 490, 69, 5, 74, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 17, 'Volkach (Escherndorf)', 49.8578, 10.16389, None, 305, 35, 6.3, 79, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (8, 7, 'Coburg (Eckardtsberg)', 50.25312, 10.98483, None, 431, 60, 10, 78, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 1, 'Dettelbach', 49.81321, 10.13318, None, 254, 33, 2, 79, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Dettelbach (Ortslage, ungefaehr)'),
        (6, 16, 'Schweinfurt (A70/Weyer)', 50.03303, 10.30288, None, 276, 35, 10, 81, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (7, 5, 'Pfreimd (Trausnitz)', 49.56028, 12.26111, 75, 536, 65, 10, 80, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (7, 3, 'Fuchsmühl (Herzogöd)', 49.9075, 12.13889, 80, 749, 34, 2.5, 81, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (6, 19, 'Würzburg (Frankenwarte)', 49.7805, 9.9063, 118, 355, 102, 10, 93, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (4, 7, 'Kelheim (Hohenpfahl)', 48.90296, 11.86953, None, 491, 29, 2, 89, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (3, 10, 'Hühnerberg', 48.78554, 10.66821, None, 571, 137, 10, 93, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (8, 2, 'Bad Steben (Lichtenberg)', 50.36833, 11.63778, 60, 608, 32, 6, 97, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (7, 8, 'Schönsee (Drechselberg)', 49.50817, 12.57664, None, 823, 29, 5, 103, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (8, 9, 'Hof (Labyrinthberg)', 50.32361, 11.92889, 45, 566, 45, 10, 102, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (8, 5, 'Ludwigsstadt-Ebersdorf', 50.49502, 11.36782, None, 577, 28, 1, 105, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 7, 'Hammelburg (Westheim)', 50.13624, 9.93173, None, 309, 126, 8, 109, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (4, 8, 'Mainburg (Wambach)', 48.60833, 11.80278, 90, 460, 45, 2.6, 116, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (7, 4, 'Geigant (Waldmünchen)', 49.33611, 12.63778, 70, 576, 56, 6.3, 110, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (1, 12, 'Pfaffenhofen (Wolfsberg)', 48.54321, 11.43134, None, 513, 119, 25, 115, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (1, 23, 'Pfaffenhofen (BR)', 48.53056, 11.48194, 80, 484, 57, 2, 117, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage Vorgabe Frank 18.10.2026 (Lage/Masthoehe; Name laut fmlist Pfaffenhofen/BR)'),
        (6, 20, 'Pfaffenberg', 49.93281, 9.24084, None, 431, 120, 10, 144, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (4, 21, 'Mallersdorf (Hofkirchen)', 48.76062, 12.33486, None, 460, 88, 25, 123, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 22, 'Wertheim (Schloßberg)', 49.75667, 9.52305, None, 257, 45, 5, 120, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 3, 'Gemünden (Main) Hofstetten', 50.05718, 9.67405, None, 390, 83, 12.5, 120, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Hofstetten, Gemünden (Ortslage, ungefaehr)'),
        (6, 15, 'Ostheim (Heidelberg)', 50.4269, 10.215, None, 522, 39, 2, 118, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 5, 'Neustadt am Main (Erlachberg)', 49.92389, 9.58194, 75, 358, 34, 10, 120, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (6, 6, 'Kreuzberg (Rhön)', 50.36944, 9.98051, None, 925, 142, 10, 123, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 4, 'Burgsinn', 50.14983, 9.66741, None, 419, 55, 1, 125, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (4, 3, 'Rattenberg (Kreuzhaus)', 49.08576, 12.75235, None, 879, 44, 1, 127, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Rattenberg (Ortslage, ungefaehr)'),
        (4, 11, 'Landshut (Altdorf)', 48.5693, 12.11271, None, 458, 51, 10, 130, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (7, 21, 'Hoher Bogen', 49.24911, 12.89096, None, 975, 53, 4, 130, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (3, 1, 'Augsburg (Welden)', 48.45972, 10.68194, 100, 576, 130, 25, 127, None, 'fmlist 10A5 (Abruf 18.10.2026); Vorgabe Frank 18.10.2026 (Lage/Masthoehe), TII laut fmlist 10A5'),
        (3, 6, 'Augsburg (Hotelturm)', 48.3594, 10.88585, None, 494, 139, 10, 135, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 2, 'Miltenberg (Wenschdorf)', 49.68381, 9.27231, None, 481, 132, 10, 136, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (4, 5, 'Dingolfing (BMW)', 48.63008, 12.49774, None, 357, 60, 1, 142, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Dingolfing (Ortslage, ungefaehr)'),
        (6, 9, 'Obernburg am Main', 49.8239, 9.11072, None, 245, 47, 4, 150, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Obernburg am Main (Ortslage, ungefaehr)'),
        (4, 16, 'Vilsbiburg', 48.44848, 12.3558, None, 504, 51, 5, 151, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Vilsbiburg (Ortslage, ungefaehr)'),
        (4, 17, 'Deggendorf (Aletsberg)', 48.87811, 12.99373, None, 395, 56, 1, 153, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Sender Deggendorf Hochoberndorf 56 m'),
        (4, 2, 'Einödriegel', 48.9275, 13.0279, None, 1105, 39, 6.3, 153, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (2, 7, 'München (Ismaning)', 48.25, 11.752, None, 482, 168, 10, 152, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (2, 1, 'München-Freimann', 48.18782, 11.62765, None, 496, 93, 1, 156, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (2, 8, 'München (Olympiaturm)', 48.17444, 11.55361, None, 511, 272, 10, 157, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (3, 9, 'Ulm (Kuhberg)', 48.38197, 9.94867, None, 582, 94, 10, 158, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (1, 6, 'Fürstenfeldbruck (Schöngeising)', 48.13196, 11.22405, None, 605, 127, 2, 159, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (6, 8, 'Alzenau (Hahnenkamm BR)', 50.07863, 9.11, None, 430, 62, 10, 158, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (3, 4, 'Markt Wald (Mittelneufnach)', 48.16997, 10.59788, None, 638, 112, 10, 160, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Mittelneufnach, Markt Wald (Ortslage, ungefaehr)'),
        (1, 8, 'Isen (Schnaupping)', 48.17459, 12.07615, None, 640, 63, 10, 168, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Schnaupping, Isen (Ortslage, ungefaehr)'),
        (4, 20, 'Brotjacklriegel', 48.81696, 13.21758, None, 1009, 106, 4, 171, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (4, 19, 'Pfarrkirchen (Postmünster)', 48.40527, 12.88599, None, 462, 100, 10, 180, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (3, 5, 'Memmingen (Niederrieden)', 48.04213, 10.21922, None, 667, 49, 1, 182, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Niederrieden, Memmingen (Ortslage, ungefaehr)'),
        (1, 16, 'Wasserburg (Koblberg)', 48.06876, 12.20811, None, 510, 38, 2.5, 183, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Koblberg, Wasserburg (Ortslage, ungefaehr)'),
        (1, 10, 'Neuötting', 48.24058, 12.68674, None, 487, 45, 10, 184, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Neuötting (Ortslage, ungefaehr)'),
        (3, 3, 'Kaufbeuren (Weinhaldeweg)', 47.88302, 10.64201, None, 711, 11, 0.63, 190, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Weinhaldeweg, Kaufbeuren (Ortslage, ungefaehr)'),
        (1, 3, 'Hohenpeißenberg', 47.8011, 11.02458, None, 936, 66, 10, 196, None, 'fmlist 10A5 (Abruf 17./18.10.2026), bisher nicht empfangen'),
        (1, 1, 'Wendelstein', 47.70345, 12.01216, None, 1828, 41, 10, 216, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage Wikipedia Sender Wendelstein (Gipfel)'),
        (1, 2, 'Hochberg (Traunstein)', 47.85883, 12.61222, None, 772, 69, 10, 217, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Fernmeldeturm Traunstein 75 m'),
        (1, 7, 'Inntal (Ebbs)', 47.63083, 12.24333, None, 712, 31, 10, 229, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage Wikipedia (de) Sender Inntal'),
        (1, 9, 'Untersberg', 47.723, 13.009, None, 1755, 25, 5, 245, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage Wikipedia (de) Sender Untersberg'),
        (1, 14, 'Reit im Winkl', 47.66724, 12.52565, None, 996, 37, 1, 233, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Reit im Winkl (Ortslage, ungefaehr)'),
        (1, 15, 'Herzogstand (Fahrenbergkopf)', 47.60694, 11.31611, None, 1620, 15, 5, 217, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage Wikipedia (de) Sender Herzogstand'),
        (1, 17, 'Oberammergau (Laber)', 47.58611, 11.10306, None, 1673, 26, 5, 219, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage Wikipedia (de) Sender Oberammergau'),
        (1, 19, 'Tegernseer Tal (Wallberg)', 47.72587, 11.73859, None, 1620, 23, 1, 208, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Tegernseer Tal (Ortslage, ungefaehr)'),
        (1, 22, 'Bad Tölz-Gaißach', 47.75, 11.57444, None, 729, 56, 1, 203, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage Wikipedia (de) Sender Gaißach'),
        (3, 11, 'Bregenz (Pfänder)', 47.50808, 9.77996, None, 1050, 74, 10, 249, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Sender Pfänder 94 m'),
        (3, 13, 'Pfronten', 47.54861, 10.57028, None, 1500, 14, 2, 228, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage Wikipedia (de) Sender Pfronten'),
        (3, 16, 'Grünten (Allgäu)', 47.55337, 10.31707, None, 1704, 74, 4, 231, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Sender Grünten 94 m'),
        (4, 1, 'Oberfrauenwald', 48.685, 13.65805, None, 945, 22, 6.3, 206, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Oberfrauenwald (Berg/Turm, ungefaehr)'),
        (4, 6, 'Passau (Kühberg)', 48.56547, 13.43348, None, 396, 45, 5, 199, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Fernmeldeturm Passau 52 m'),
        (4, 14, 'Rotthalmünster', 48.35885, 13.2016, None, 428, 26, 5, 200, None, 'fmlist 10A5 (Abruf 18.10.2026), bisher nicht empfangen; Lage OSM Nominatim Rotthalmünster (Ortslage, ungefaehr)'),
    ),
    '5C': (
        (24, 3, 'Brocken', 51.80019, 10.6144, None, 1135, 91, 2, 252, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Funkturm Brocken 123 m'),
        (24, 1, 'Halle (Petersberg)', 51.59546, 11.95731, None, 232, 108, 10, 234, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia Fernmeldeturm Petersberg'),
        (19, 5, 'Göttingen-Bovenden', 51.58292, 9.95605, None, 350, 137, 3.2, 241, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Göttingen 2 155 m'),
        (26, 6, 'Kulpenberg', 51.41184, 11.07616, None, 473, 103, 10, 206, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Kulpenberg 123 m'),
        (17, 9, 'Habichtswald', 51.31407, 9.34587, None, 594, 102, 10, 234, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sendeturm Kassel (Habichtswald) 186 m'),
        (23, 2, 'Leipzig (Messegrund)', 51.31674, 12.4482, None, 126, 174, 10, 216, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Leipzig-Holzhausen 68 m'),
        (23, 5, 'Oschatz (Collmberg)', 51.30398, 13.00956, None, 311, 101, 10, 234, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Oschatz'),
        (24, 6, 'Pettstädt (Weißenfels)', 51.23733, 11.8815, None, 198, 93, 10, 194, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Nominatim Weißenfels, Pettstädt (Ortslage, ungefaehr)'),
        (17, 4, 'Hoher Meißner', 51.20726, 9.84771, None, 698, 151, 10, 205, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Hoher Meißner 220 m'),
        (23, 1, 'Dresden-Wachwitz', 51.04005, 13.83883, None, 231, 232, 10, 252, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernsehturm Dresden 116 m'),
        (26, 1, 'Weimar (Ettersberg)', 51.01379, 11.25865, None, 476, 29, 10, 162, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Weimar (Ettersberg)'),
        (23, 10, 'Freiberg (Niederschöna)', 50.91694, 13.34289, None, 412, 58, 5, 217, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Nominatim Freiberg (Ortslage, ungefaehr)'),
        (26, 9, 'Erfurt (Chamissostr.)', 50.95902, 11.02285, None, 234, 52, 0.5, 156, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Erfurt (Chamissostr.)'),
        (17, 10, 'Biedenkopf (Sackpfeife)', 50.95114, 8.53207, None, 658, 142, 10, 242, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Biedenkopf 210 m'),
        (26, 3, 'Gera-Roschütz (Langenberg)', 50.91845, 12.076, None, 293, 94, 10, 165, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldetum Gera 127 m'),
        (26, 4, 'Jena (Oßmaritz)', 50.91539, 11.60114, None, 397, 77, 5, 154, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Jena'),
        (26, 2, 'Inselsberg', 50.85141, 10.46533, None, 908, 92, 5, 152, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sendeturm Inselsberg 127 m'),
        (23, 7, 'Chemnitz-Reichenhain', 50.79993, 12.96576, None, 428, 66, 10, 189, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sendeturm Chemnitz-Reichenhain'),
        (26, 8, 'Saalfeld (Remda/Kalmberg)', 50.77371, 11.18284, None, 536, 167, 10, 135, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Remda 169 m'),
        (23, 9, 'Zwickau-Ost (Pöhlau)', 50.71827, 12.5472, None, 383, 78, 10, 163, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Nominatim Pöhlau, Zwickau-Ost (Ortslage, ungefaehr)'),
        (17, 5, 'Gießen (Dünsberg)', 50.65082, 8.58029, None, 489, 112, 3.2, 220, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Gießen (Dünsberg) 108 m'),
        (23, 3, 'Chemnitz (Geyer)', 50.79993, 12.96573, None, 738, 172, 10, 189, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sendemast Chemnitz-Reichenhain'),
        (26, 10, 'Suhl (Erleshügel)', 50.61241, 10.74503, None, 837, 63, 1, 121, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sendeturm Suhl-Erleshügel 69 m'),
        (17, 6, 'Fulda (Hummelskopf)', 50.60397, 9.67663, None, 416, 123, 3.2, 157, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Fulda Hummelskopf 128 m'),
        (26, 7, 'Sonneberg (Bleßberg)', 50.4468, 11.0044, 195, 864, 177, 10, 99, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM/Wikipedia Sender Bleßberg 195 m'),
        (26, 5, 'Sieglitzberg (Lobenstein)', 50.42684, 11.61345, None, 721, 86, 10, 102, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sendeturm Bad Lobenstein-Sieglitzberg'),
        (23, 4, 'Schöneck (Vogtland)', 50.40051, 12.35029, None, 780, 47, 10, 127, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Schöneck'),
        (12, 14, 'Kreuzberg (Rhön)', 50.36944, 9.98051, None, 925, 142, 10, 123, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0606'),
        (17, 3, 'Großer Feldberg (Taunus)', 50.23214, 8.45732, None, 870, 96, 5, 207, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Großer Feldberg 83 m'),
        (17, 8, 'Gelnhausen (Schnepfenkopf)', 50.20926, 9.21027, None, 322, 80, 2, 157, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Schnepfenkopf 75 m'),
        (17, 2, 'Frankfurt (Europaturm)', 50.13532, 8.65463, None, 116, 320, 5, 190, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Europaturm 337 m'),
        (17, 12, 'Hohe Wurzel', 50.10931, 8.13336, None, 608, 125, 5, 225, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Hohe Wurzel 133 m'),
        (15, 19, 'Gemünden (Main) Hofstetten', 50.05718, 9.67405, None, 390, 83, 10, 120, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0603'),
        (12, 6, 'Ochsenkopf (Fichtelgebirge)', 50.03111, 11.81389, 176, 1013, 169, 10, 71, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0801'),
        (17, 1, 'Mainz (Kastel)', 50.02256, 8.27707, None, 87, 150, 10, 213, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Mainz-Kastel 170 m'),
        (12, 9, 'Pfaffenberg', 49.93281, 9.24084, None, 431, 120, 10, 144, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0620'),
        (12, 11, 'Bamberg (Geisberg)', 49.8893, 11.062, 115, 585, 104, 10, 37, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0818'),
        (21, 11, 'Bad Kreuznach (Schanzenkopf)', 49.82685, 7.83382, None, 319, 115, 7.1, 241, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Bad Kreuznach 127 m'),
        (12, 8, 'Würzburg (Frankenwarte)', 49.7805, 9.9063, 118, 355, 102, 10, 93, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0619'),
        (17, 11, 'Hardberg', 49.53977, 8.80365, None, 591, 133, 10, 170, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Hardberg'),
        (12, 16, 'Amberg (Hirschau/Rotbühl)', 49.5088, 12.0048, None, 666, 95, 10, 62, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0702'),
        (11, 16, 'Bad Mergentheim (Löffelstelzen)', 49.50744, 9.78241, None, 357, 122, 5, 99, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sendeturm Löffelstelzen 179 m'),
        (12, 3, 'Nürnberg (Schweinau)', 49.42639, 11.03778, 292, 318, 260, 10, 17, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0514'),
        (12, 12, 'Büttelberg (Frankenhöhe)', 49.4146, 10.378, 220, 527, 159, 10, 58, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0515'),
        (21, 5, 'Kaiserslautern (Dansenberg)', 49.41254, 7.74059, None, 404, 62, 10, 247, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Dansenberg 133 m'),
        (11, 2, 'Heidelberg (Königstuhl)', 49.40282, 8.73058, None, 562, 58, 10, 176, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Heidelberg 102 m'),
        (22, 21, 'Dillberg (Neumarkt)', 49.32639, 11.38194, 231, 595, 194, 10, 31, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0513'),
        (21, 6, 'Kalmit (Edenkoben)', 49.28009, 8.12271, None, 665, 49, 5, 221, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Edenkoben 0 41 m'),
        (12, 22, 'Hoher Bogen', 49.24911, 12.89096, None, 975, 53, 4, 130, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0721'),
        (11, 3, 'Heilbronn (Schweinsberg)', 49.11174, 9.25101, None, 371, 57, 2, 147, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Heilbronn 89 m'),
        (22, 20, 'Nennslingen (Burgsalach)', 49.04505, 11.08752, 158, 614, 153, 5, 57, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM/Wikipedia Fernmeldeturm Nennslingen (Burgsalach) 158 m'),
        (12, 5, 'Hohe Linie (Regensburg)', 49.0397, 12.1716, None, 474, 140, 10, 94, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0712'),
        (11, 19, 'Mainhardt (Großerlach)', 49.03691, 9.55029, None, 586, 125, 10, 130, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Großerlach 133 m'),
        (12, 4, 'Gelbelsee', 48.94642, 11.42872, 112, 539, 105, 10, 71, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0105'),
        (11, 14, 'Aalen (Braunenberg)', 48.86084, 10.13738, None, 720, 120, 10, 107, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Aalen 139 m'),
        (12, 10, 'Brotjacklriegel', 48.81696, 13.21758, None, 1009, 106, 4, 171, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0420'),
        (11, 6, 'Pforzheim (Langenbrand)', 48.92095, 8.68868, None, 707, 123, 10, 193, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Pforzheim 7 76 m'),
        (15, 23, 'Unterringingen', 48.76597, 10.50719, None, 609, 116, 10, 100, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Unterringingen'),
        (11, 1, 'Stuttgart-Frauenkopf', 48.76362, 9.20576, None, 462, 186, 10, 167, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Stuttgart-Frauenkopf 192 m'),
        (11, 5, 'Baden-Baden (Fremersberg)', 48.75278, 8.20229, None, 525, 54, 3.2, 233, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fremersbergturm 52 m'),
        (11, 8, 'Geislingen (Oberböhringen)', 48.61802, 9.78544, None, 737, 52, 2, 144, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Geislingen-Oberböhringen'),
        (11, 20, 'Hornisgrinde', 48.61083, 8.20179, None, 1133, 40, 2, 239, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Hornisgrinde SWR 206 m'),
        (12, 15, 'Landshut (Altdorf)', 48.5693, 12.11271, None, 458, 51, 10, 130, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0411'),
        (15, 22, 'Pfaffenhofen (Wolfsberg)', 48.54321, 11.43134, None, 513, 140, 10, 115, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0112'),
        (12, 17, 'Passau (Dommelstadl)', 48.56547, 13.43348, None, 484, 77, 5, 199, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Fernmeldeturm Passau 52 m'),
        (11, 18, 'Reutlingen (Scheibengipfel)', 48.49555, 9.23174, None, 529, 50, 1, 183, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Scheibengipfel 57 m'),
        (12, 23, 'Pfarrkirchen (Postmünster)', 48.40527, 12.88599, None, 462, 100, 10, 180, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0419'),
        (11, 4, 'Ulm (Kuhberg)', 48.38197, 9.94867, None, 582, 94, 10, 158, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0309'),
        (12, 2, 'Augsburg (Hotelturm)', 48.3594, 10.88585, None, 494, 139, 10, 135, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0306'),
        (11, 9, 'Raichberg', 48.3059, 8.99225, None, 953, 128, 10, 211, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Raichberg 147 m'),
        (12, 1, 'München (Olympiaturm)', 48.17444, 11.55361, None, 511, 272, 10, 157, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0208'),
        (11, 21, 'Rottweil (Deilingen)', 48.15461, 8.65914, None, 980, 67, 5, 240, None, 'fmlist 10BC (Abruf 18.10.2026); Lage Wikipedia (de) Sender Rottweil-Stadt'),
        (12, 20, 'Hochberg (Traunstein)', 47.85883, 12.61222, None, 772, 69, 8, 217, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0102'),
        (11, 10, 'Ravensburg (Höchsten)', 47.82181, 9.39922, None, 829, 95, 10, 232, None, 'fmlist 10BC (Abruf 18.10.2026); Lage OSM Sender Ravensburg (Höchsten) 172 m'),
        (15, 21, 'Bad Tölz-Gaißach', 47.75, 11.57444, None, 729, 56, 1.6, 203, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0122'),
        (22, 23, 'Untersberg', 47.723, 13.009, None, 1755, 25, 3.5, 245, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0109'),
        (12, 7, 'Wendelstein', 47.70345, 12.01216, None, 1828, 41, 2, 216, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0101'),
        (15, 20, 'Inntal (Ebbs)', 47.63083, 12.24333, None, 712, 31, 6.3, 229, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0107'),
        (12, 18, 'Herzogstand (Fahrenbergkopf)', 47.60694, 11.31611, None, 1620, 15, 5, 217, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0115'),
        (22, 22, 'Oberammergau (Laber)', 47.58611, 11.10306, None, 1673, 26, 5, 219, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0117'),
        (12, 13, 'Grünten (Allgäu)', 47.55337, 10.31707, None, 1704, 74, 4, 231, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0316'),
        (12, 21, 'Pfronten', 47.54861, 10.57028, None, 1500, 14, 2, 228, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0313'),
        (12, 19, 'Bregenz (Pfänder)', 47.50808, 9.77996, None, 1050, 74, 2, 249, None, 'fmlist 10BC (Abruf 18.10.2026); Lage wie 11D 0311'),
        (2, 2, 'Praha (Děvín) [FIERA (CZ)]', 50.04513, 14.39156, None, 303, 50, 10, 239, 'FIERA (CZ)', 'fmlist 2119 (Abruf 18.10.2026), Ueberreichweite anderes Ensemble; Lage OSM Nominatim Děvín, Praha (Berg/Turm, ungefaehr)'),
    ),
    '10C': (
        (7, 3, 'Hersbruck', 49.5181, 11.46, None, 499, 43, 5, 22, None, 'fmlist 10AD (Abruf 18.10.2026); Lage wie 11D 0501'),
        (7, 1, 'Nürnberg (Schweinau)', 49.42639, 11.03778, 292, 318, 260, 10, 17, None, 'fmlist 10AD (Abruf 18.10.2026); Lage wie 11D 0514'),
        (7, 2, 'Dillberg (Neumarkt)', 49.32639, 11.38194, 231, 595, 194, 10, 31, None, 'fmlist 10AD (Abruf 18.10.2026); Lage wie 11D 0513'),
        (7, 5, 'Votice (Mezivrata) [CRA DAB+ CZ]', 49.60254, 14.67109, None, 707, 60, 10, 254, 'CRA DAB+ CZ', 'fmlist 2034 (Abruf 18.10.2026), Ueberreichweite anderes Ensemble; Lage OSM Vysílač Votice – Mezivrata 101 m'),
        (12, 1, 'Kleť (České Budějovice) [CRA DAB+ CZ]', 48.865, 14.28389, None, 1058, 115, 20, 240, 'CRA DAB+ CZ', 'fmlist 2034 (Abruf 18.10.2026), Ueberreichweite anderes Ensemble; Lage Wikipedia Kleť (Gipfel, Sender ČRa)'),
        (29, 1, 'Ústí nad Labem (Buková hora) [PLAY.CZ DAB+]', 50.67178, 14.22887, None, 666, 185, 10, 252, 'PLAY.CZ DAB+', 'fmlist 211B (Abruf 18.10.2026), Ueberreichweite anderes Ensemble; Lage OSM Vysílač Buková hora 223 m'),
    ),
}
WD_MF_SRC = {"11D": "; mastFix 18.10.2026: Namen/Lage nach Liste Frank (12 bestaetigt) + Korrekturen laut fmlist 10A5 (08/18 Bamberg, 05/13 Dillberg, 08/01 Ochsenkopf, 05/15 Buettelberg), "
                     "15 weitere BR-Sender bis 255 km; Lage je Eintrag in src (Wikipedia/OSM, ohne Quelle = Ortslage ungefaehr)",
             "5C": "; mastFix 18.10.2026: alle Sender DR Deutschland 10BC bis 255 km (fmlist, Abruf 18.10.2026) + Ueberreichweite FIERA (CZ) 5C; 09/03 Hof gestrichen (keine Quelle)",
             "10C": "; mastFix 18.10.2026: Ensemble Nuernberg 10AD 07/01 Schweinau, 07/02 Dillberg, 07/03 Hersbruck (fmlist) + Ueberreichweite CZ 10C bis 255 km"}
WD_MF_N = {"11D": 91, "5C": 84, "10C": 6}


def _wd_mf_apply():
    """MASTS_DB je Kanal ersetzen (Reihenfolge der ersten 11D-Eintraege bleibt). Idempotent."""
    for ch, rows in WD_MF.items():
        m = MASTS_DB.get(ch)
        if not isinstance(m, dict):
            continue
        m["tii"] = [{k: v for k, v in zip(WD_MF_KEYS, r) if v is not None} for r in rows]
        s = str(m.get("src") or "")
        if WD_MF_SRC[ch] not in s:
            m["src"] = s + WD_MF_SRC[ch]


_wd_mf_apply()


def _selftest_mastfix():
    for ch, n in WD_MF_N.items():
        t = MASTS_DB[ch]["tii"]
        codes = [(x["main"], x["sub"]) for x in t]
        assert len(t) == n and len(set(codes)) == n, (ch, len(t))
        assert all(x.get("mast") and x.get("src") and isinstance(x.get("lat"), float) and isinstance(x.get("lon"), float) and 0 <= x["km"] <= 255 for x in t), ch
    assert [(t["main"], t["sub"]) for t in MASTS_DB["11D"]["tii"]][:9] == [(8, 18), (5, 14), (5, 1), (5, 13), (8, 1), (5, 15), (5, 11), (7, 2), (7, 12)]
    nm = lambda ch, a, b: [x for x in MASTS_DB[ch]["tii"] if (x["main"], x["sub"]) == (a, b)][0]
    assert nm("11D", 8, 18)["mast"] == nm("5C", 12, 11)["mast"] == "Bamberg (Geisberg)" and (nm("11D", 8, 18)["lat"], nm("11D", 8, 18)["lon"]) == (49.8893, 11.062)
    assert nm("11D", 5, 14)["mast"] == nm("5C", 12, 3)["mast"] == nm("10C", 7, 1)["mast"] == "Nürnberg (Schweinau)" and nm("11D", 5, 14)["h_mast"] == 292
    assert nm("11D", 5, 13)["mast"] == nm("5C", 22, 21)["mast"] == nm("10C", 7, 2)["mast"] == "Dillberg (Neumarkt)"
    assert nm("11D", 8, 1)["mast"] == nm("5C", 12, 6)["mast"] == "Ochsenkopf (Fichtelgebirge)" and nm("11D", 5, 15)["mast"] == nm("5C", 12, 12)["mast"]
    assert nm("11D", 1, 23)["mast"] == "Pfaffenhofen (BR)" and nm("11D", 1, 12)["mast"] == "Pfaffenhofen (Wolfsberg)" and nm("11D", 4, 3)["mast"] == "Rattenberg (Kreuzhaus)"
    assert nm("11D", 8, 4)["mast"] == "Ebermannstadt (Pretzfeld)" and nm("5C", 26, 7)["mast"] == "Sonneberg (Bleßberg)" and nm("5C", 12, 8)["mast"] == "Würzburg (Frankenwarte)"
    assert nm("5C", 12, 4)["mast"] == "Gelbelsee" and nm("5C", 22, 20)["mast"].startswith("Nennslingen") and nm("10C", 7, 3)["mast"] == "Hersbruck"
    assert not [x for x in MASTS_DB["5C"]["tii"] if (x["main"], x["sub"]) == (9, 3)] and all(x.get("ens") and "[" in x["mast"] for t in MASTS_DB.values() for x in t["tii"] if "ens" in x)
    assert t2_mast("5C", 12, 11) == "Bamberg (Geisberg) MainID 12 / SubID 11 (%s)" % MASTS_DB["5C"]["name"] and t2_mast("11D", 9, 9).endswith("(nicht in MASTS_DB)")
    _wd_mf_apply()
    assert len(MASTS_DB["11D"]["tii"]) == WD_MF_N["11D"] and MASTS_DB["11D"]["src"].count("mastFix") == 1
    return sum(WD_MF_N.values())
# ----- /mastFix -----


def selftest_sdrwd():
    import tempfile
    old_h, old_env = globals()["_wd_helper"], os.environ.get("SDR_WD_HELPER")
    os.environ["SDR_WD_HELPER"] = "/nonexistent/sdrwd-selftest"     # echtes Hilfsprogramm nie
    calls = []
    assert _wd_helper(["check"], 1)[0] == 125 and not _WD["live"]     # ausserhalb des Dienstes nie ausfuehren
    try:
        _WD["live"] = True
        n = _selftest_sdrwd(tempfile.mkdtemp(prefix="sdrwd-"), calls)
        nm_mf = _selftest_mastfix()
    finally:
        globals()["_wd_helper"] = old_h
        if old_env is None:
            os.environ.pop("SDR_WD_HELPER", None)
        else:
            os.environ["SDR_WD_HELPER"] = old_env
        _WD.update(d=None, base=None, dirty=False, saved=0.0, busy=None, cfg=None, cfg_key=None, started=set(), helper=None, boot_msgs=[], live=False, start=time.time())
    print("selftest sdrWd ok (Stufen 10/30/45/60 min, USB nur per Seriennummer, max 2 USB je Vorfall, Pi-Neustart max 1/h + Stopp nach 3, Sperre bei Alarm/Übernahme/ASA/PTY31, "
          "Zustand übersteht Neustart, Gain-Leiter unberührt, Anzeige/Technik-Verlauf; Fake-Hilfsprogramm %d Aufrufe, nichts echt zurückgesetzt/neu gestartet; MASTS_DB %d Einträge 11D/5C/10C eindeutig, Namen je Standort gleich)" % (n, nm_mf), flush=True)


def _selftest_sdrwd(tmp, calls):
    results = {"usb-reset": 0, "reboot": 0}

    def fake_helper(args, timeout):
        calls.append(list(args))
        results["n"] = results.get("n", 0) + 1
        assert args[0] in ("usb-reset", "reboot", "check") and (args[0] != "usb-reset" or WD_SN_RE.match(args[1]))
        rc = results.get(args[0], 0)
        return rc, "fake %s" % args[0]
    globals()["_wd_helper"] = fake_helper
    _WD.update(d=None, base=None, dirty=False, saved=0.0, busy=None, cfg=None, cfg_key=None, started=set(), helper=None, boot_msgs=[], start=0.0)
    # Konfiguration: Standard und Reihenfolge
    c = wd_cfg(tmp)
    assert (c["wd_enable"], c["wd_yellow_min"], c["wd_restart_min"], c["wd_usb_min"], c["wd_reboot_min"], c["wd_reboot_min_interval_min"], c["wd_reboot_max_fail"], c["wd_usb_max"]) == \
        (True, 10, 30, 45, 60, 60, 3, 2), c
    save_cfg_keys(tmp, {"wd_usb_min": 5, "wd_enable": "aus", "wd_reboot_max_fail": "x"})
    c = wd_cfg(tmp)
    assert c["wd_usb_min"] == 30 and c["wd_enable"] is False and c["wd_reboot_max_fail"] == 3 and c["src"]["wd_usb_min"] == "sdr_config.json"
    save_cfg_keys(tmp, {"wd_usb_min": 45, "wd_enable": True, "wd_reboot_max_fail": 3, "wd_verify_s": 1})
    assert wd_cfg(tmp)["wd_verify_s"] == 30 and wd_cfg(tmp)["wd_start_grace_s"] == WD_START_GRACE_S
    save_cfg_keys(tmp, {"wd_verify_s": WD_VERIFY_S})
    assert config(tmp)["wd_usb_min"] == 45 and "wd_enable" in DEFAULT_CFG
    sysfs = os.path.join(tmp, "sysfs")
    for n, sn in (("1-1.1", "19348831"), ("1-1.2", "72055505")):
        os.makedirs(os.path.join(sysfs, n))
        for k, v in (("idVendor", "0bda"), ("idProduct", "2838"), ("serial", sn), ("product", "RTL2838UHIDIR")):
            open(os.path.join(sysfs, n, k), "w").write(v + "\n")
    old_sys = os.environ.get("SDR_SYSFS_USB")
    os.environ["SDR_SYSFS_USB"] = sysfs
    try:
        _selftest_sdrwd2(tmp, calls, results)
        return results.get("n", 0)
    finally:
        if old_sys is None:
            os.environ.pop("SDR_SYSFS_USB", None)
        else:
            os.environ["SDR_SYSFS_USB"] = old_sys


def _selftest_sdrwd2(tmp, calls, results):
    save_cfg_keys(tmp, {"stick2": {"serial": "72055505", "enabled": True}, "dab": ["11D"]})
    m = Planner(tmp)
    w = Planner(tmp, stick=2, main=m)
    m.worker = w
    m.set_role("bc"); w.set_role("rot")
    killed = []
    for x in (m, w):
        x.kill = (lambda q: (lambda: killed.append(q.stickno)))(x)
        x.resolve = (lambda q: (lambda: setattr(q, "dev_idx", q.stickno - 1)))(x)
        x.log = lambda *a: None
    with _SDRLOG_LOCK:
        sdrlog_get(tmp).quiet = True
    t0 = 1790000000.0
    m.active = "dab:0"
    m.special = {"kind": "bc", "queue": ["dab:0"], "i": 0}

    def chk(ok, t, ch="11D", pl=m):
        wd_check(pl, "dab", ok, t, ch, None if ok else "kein Sync: Ensemble leer, SNR None")

    def tick(t, pl=m):
        wd_tick(pl, t)

    def st():
        return _WD["d"]["sticks"]["19348831"]
    m.sbc.d["dab"]["11D"] = {"ch": "11D", "t": int(t0 - 60), "rx": False}
    chk(True, t0)
    assert st()["last_ok"] == int(t0) and not st()["inc"]
    tick(t0 + 30)
    assert not calls and not killed
    # Ausfall 23:11 -> Stufe 1 nach 10 min, Gain-Leiter unberuehrt (keine Aktion)
    for k in range(1, 12):
        chk(False, t0 + 60 * k)
        tick(t0 + 60 * k + 1)
    i = st()["inc"]
    assert i and i["since"] == int(t0) and i["lg"] == 1 and not i["restart_n"] and not killed and not calls, i
    v = m.stick_health(t0 + 700)
    assert v["txt"] == "Stick ohne DAB-Empfang" and v["lvl"] == "gelb" and "kein Sync seit" in v["why"] and v["wd"]["stage"] == 1, v
    assert m.raw_fail == 0   # wd_check direkt (ohne sub_done) zaehlt nicht doppelt
    # Stufe 2 ab 30 min: Neustart welle-cli + rtl_tcp (nur dieser Stick)
    for k in range(12, 31):
        chk(False, t0 + 60 * k)
        tick(t0 + 60 * k + 1)
    assert st()["inc"]["restart_n"] == 1 and killed == [1] and m.active == "idle" and not calls, (st()["inc"], killed)
    assert m.stick_health(t0 + 1900)["lvl"] == "rot" and "Stufe 2" in m.stick_health(t0 + 1900)["why"]
    # Sperre: Uebernahme Stick 2 aktiv -> keine USB-Neuverbindung
    write_json(p(T2_TAKEOVER, tmp), {"on": True, "since": int(t0), "src": "ASA", "why": "Test", "by": "auto"})
    _T2_TO.clear()
    for k in range(31, 50):
        chk(False, t0 + 60 * k)
        tick(t0 + 60 * k + 1)
    assert st()["inc"]["usb_n"] == 0 and not calls and "Übernahme" in (st()["inc"]["block"] or ""), st()["inc"]
    write_json(p(T2_TAKEOVER, tmp), {"on": False})
    _T2_TO.clear()
    # Sperre: echter Alarm im Lagezentrum (Gate vom Dashboard)
    write_json(p(WD_GATE, tmp), {"t": int(t0 + 60 * 50), "alarm": True})
    chk(False, t0 + 60 * 50); tick(t0 + 60 * 50 + 1)
    assert not calls and st()["inc"]["block"] == "echter Alarm im Lagezentrum"
    write_json(p(WD_GATE, tmp), {"t": int(t0 + 60 * 50), "alarm": False})
    # PTY 31 sperrt ebenfalls
    m.sbc.d["fm"]["BR24"] = {"name": "BR24", "pty31_persist": 1, "pty31_last": int(t0 + 60 * 51)}
    chk(False, t0 + 60 * 51); tick(t0 + 60 * 51 + 1)
    assert not calls and "PTY 31" in st()["inc"]["block"]
    m.sbc.d["fm"]["BR24"] = {"name": "BR24"}
    # Stufe 3: USB-Neuverbindung nur dieses Sticks (per Seriennummer), max 2 je Vorfall, Abstand >= 4 min + 2 Pruefungen
    chk(False, t0 + 60 * 52); tick(t0 + 60 * 52 + 1)
    assert calls == [["usb-reset", "19348831"]] and st()["inc"]["usb_n"] == 1 and killed[-1] == 1 and st()["inc"]["usb_last"] == "ok", (calls, st()["inc"])
    chk(False, t0 + 60 * 53); tick(t0 + 60 * 53 + 1)
    assert len(calls) == 1                                                     # Wartezeit nach Aktion
    for k in range(54, 58):
        chk(False, t0 + 60 * k); tick(t0 + 60 * k + 1)
    assert calls[-1] == ["usb-reset", "19348831"] and len(calls) == 2 and st()["inc"]["usb_n"] == 2
    for k in range(58, 62):
        chk(False, t0 + 60 * k); tick(t0 + 60 * k + 1)
    assert len(calls) == 3 and calls[-1] == ["reboot"] and st()["inc"]["usb_n"] == 2, calls  # kein dritter USB-Reset; Pi-Neustart ab 60 min
    d = _WD["d"]
    assert d["pending"] and d["reboot_fail_n"] == 1 and d["reboots"][-1]["ok"] is None
    vv = m.stick_health(t0 + 60 * 62)["wd"]
    assert vv["stage"] == 4 and vv["g"]["reboots_today"] == 1 and vv["g"]["last_reboot"] == d["reboots"][-1]["t"] and vv["g"]["pending"], vv
    # "Pi-Neustart": neuer Prozess laedt Zustand aus Datei, Neustart gilt als erfolgt, neue Phase
    js = load_json(p(WD_FILE, tmp))
    assert js["pending"] and js["sticks"]["19348831"]["inc"]["usb_n"] == 2
    _WD.update(d=None, base=None, started=set(), boot_msgs=[])
    tb = t0 + 60 * 64
    chk(False, tb)
    d = _WD["d"]
    assert not d["pending"] and d["reboots"][-1]["ok"] is True and st()["inc"]["t0"] == int(tb) and st()["inc"]["usb_n"] == 0 and st()["inc"]["since"] == int(t0)
    tick(tb + 1)
    tl = load_json(p(SDRLOG_FILE, tmp))
    tx = [x["text"] for x in tl["ev"]]
    assert any("Pi-Neustart durch Watchdog erfolgt" in x for x in tx) and any(x.startswith("Start: Stick 1 · 11D kein Sync seit") for x in tx), tx[-4:]
    assert any("Stufe 3 USB-Neuverbindung (1/2, nur SN 19348831)" in x for x in tx) and any("Stufe 4 Pi-Neustart (1/3" in x for x in tx) and any("Stufe 2 Neustart welle-cli + rtl_tcp" in x for x in tx)
    assert any("Stufe 3 gesperrt: Alarm-Übernahme" in x for x in tx), tx
    # Zweite Phase: wieder Stufe 2, 3, 3, 4 - Pi-Neustart erst nach 60 min seit letztem
    nrb = 1
    t = tb
    for phase in range(3):
        for k in range(1, 75):
            t = tb + 60 * k
            chk(False, t); tick(t + 1)
            if calls[-1] == ["reboot"] and _WD["d"]["pending"]:
                break
        if _WD["d"].get("stopped"):
            break
        nrb += 1
        assert calls[-1] == ["reboot"] and _WD["d"]["reboot_fail_n"] == nrb, (phase, calls[-5:], _WD["d"]["reboot_fail_n"])
        rbs = [r["t"] for r in _WD["d"]["reboots"]]
        assert rbs[-1] - rbs[-2] >= 3600, rbs
        _WD.update(d=None, base=None, started=set(), boot_msgs=[])
        tb = t + 120
        chk(False, tb)
    # nach 3 Neustarts ohne Erfolg: Stopp, keine weiteren
    n_rb = sum(1 for x in calls if x == ["reboot"])
    for k in range(1, 130):
        chk(False, tb + 60 * k); tick(tb + 60 * k + 1)
    assert sum(1 for x in calls if x == ["reboot"]) == n_rb == 3 and _WD["d"]["stopped"], (n_rb, _WD["d"]["reboot_fail_n"])
    vv = m.stick_health(tb + 60 * 130)
    assert "Stick/Antenne prüfen" in vv["why"] and vv["lvl"] == "rot" and vv["wd"]["g"]["stopped"], vv
    # Echter Empfang: Vorfall zu, Automatik wieder bereit
    chk(True, tb + 60 * 131)
    assert not st()["inc"] and not _WD["d"]["stopped"] and _WD["d"]["reboot_fail_n"] == 0
    tx = [x["text"] for x in load_json(p(SDRLOG_FILE, tmp))["ev"]]
    assert any("keine weiteren Pi-Neustarts (3 ohne Erfolg) – Stick/Antenne prüfen" in x for x in tx) and any("11D wieder Sync nach USB-Reset" in x for x in tx), tx[-5:]
    assert m.stick_health(tb + 60 * 132)["wd"]["lvl"] == "ok"
    # Neuer Vorfall: USB-Reset hilft -> "wieder Sync nach USB-Reset"; Fehler-rc des Hilfsprogramms wird gemeldet
    t1 = tb + 86400
    calls.clear()
    chk(True, t1)
    results["usb-reset"] = 3
    for k in range(1, 47):
        chk(False, t1 + 60 * k); tick(t1 + 60 * k + 1)
    assert calls == [["usb-reset", "19348831"]] and st()["inc"]["usb_last"].startswith("rc 3"), (calls, st()["inc"])
    results["usb-reset"] = 0
    for k in range(47, 52):
        chk(False, t1 + 60 * k); tick(t1 + 60 * k + 1)
    assert calls[-1] == ["usb-reset", "19348831"] and len(calls) == 2
    chk(True, t1 + 60 * 53)
    tx = [x["text"] for x in load_json(p(SDRLOG_FILE, tmp))["ev"]]
    assert any("USB-Neuverbindung 1: fehlgeschlagen (rc 3" in x for x in tx) and tx[-1].startswith("Stick 1 · 11D wieder Sync nach USB-Reset"), tx[-3:]
    # Stick 2: RDS-Fenster ohne Gruppen zaehlen, Uebernahme sperrt, nie Stick-1-Seriennummer
    w.counts["rds"] = 5
    w.since = t1 + 60 * 100
    w._wd_c0 = ("rds:0", 5)
    _wd_eval(w, ("rds", "BR24", 60, True, 5), t1 + 60 * 101)
    s2 = _WD["d"]["sticks"]["72055505"]
    assert s2["fail_n"] == 1 and s2["inc"] and s2["n"] == 2
    w.counts["rds"] = 9
    _wd_eval(w, ("rds", "BR24", 60, True, 5), t1 + 60 * 102)
    assert not s2.get("inc") and _WD["d"]["sticks"]["72055505"]["fail_n"] == 0
    calls.clear()
    write_json(p(T2_TAKEOVER, tmp), {"on": True, "since": int(t1), "src": "ASA", "why": "Test", "by": "auto"})
    _T2_TO.clear()
    w.active = "dab:0"
    for k in range(103, 200):
        wd_check(w, "dab", False, t1 + 60 * k, "5C", "kein Sync"); wd_tick(w, t1 + 60 * k + 1)
    assert not calls and "Übernahme" in _WD["d"]["sticks"]["72055505"]["inc"]["block"], _WD["d"]["sticks"]["72055505"]["inc"]
    write_json(p(T2_TAKEOVER, tmp), {"on": False})
    _T2_TO.clear()
    for k in range(200, 206):
        wd_check(w, "dab", False, t1 + 60 * k, "5C", "kein Sync"); wd_tick(w, t1 + 60 * k + 1)
    assert calls and all(x[0] != "usb-reset" or x[1] == "72055505" for x in calls), calls
    # Schalter aus: keine Aktion
    calls.clear()
    save_cfg_keys(tmp, {"wd_enable": False})
    for k in range(206, 300):
        wd_check(w, "dab", False, t1 + 60 * k, "5C", "kein Sync"); wd_tick(w, t1 + 60 * k + 1)
    assert not calls and "wd_enable" in _WD["d"]["sticks"]["72055505"]["inc"]["block"]
    save_cfg_keys(tmp, {"wd_enable": True})
    # Bewertung je DAB-Block (_wd_eval): Sync / ohne Sync / welle-cli weg; Rolle bc zaehlt raw_fail
    tq = t1 + 60 * 400
    m.raw_fail = 0
    m.sbc.d["dab"]["11D"] = {"ch": "11D", "t": int(tq - 3600), "rx": False, "try_t": int(tq), "rx_why": "kein Sync: Ensemble leer", "demod": {"snr": None}}
    _wd_eval(m, ("dab", "11D", 40, True, None), tq)
    assert m.raw_fail == 1 and st()["why"].startswith("kein Sync: Ensemble leer")
    _wd_eval(m, ("dab", "11D", 5, True, None), tq + 1)       # zu kurz gelaufen: keine Bewertung
    assert m.raw_fail == 1
    m.sbc.d["dab"]["11D"] = {"ch": "11D", "t": int(tq + 60), "rx": True}
    _wd_eval(m, ("dab", "11D", 40, True, None), tq + 61)
    assert m.raw_fail == 0 and not st()["inc"]
    # Technik-Verlauf: ohne Sync seit Start wird gemeldet
    tl2 = TechLog(os.path.join(tmp, "tl2")) if os.makedirs(os.path.join(tmp, "tl2")) is None else None
    tl2.quiet = True
    bad = {"rx": False, "rx_why": "kein Sync: Ensemble leer"}
    tl2.dab("11D", bad, {}, [], 100)
    assert not any(x["k"] == "sync_lost" for x in tl2.ev)
    tl2.dab("11D", bad, {}, [], 200)
    assert [x["text"] for x in tl2.ev if x["k"] == "sync_lost"] == ["DAB 11D ohne Sync seit Start (kein Sync: Ensemble leer, 2 Prüfungen ohne Sync)"], tl2.ev
    tl2.dab("11D", bad, {}, [], 300)
    assert len([x for x in tl2.ev if x["k"] == "sync_lost"]) == 1
    # DB-Zustand (lagezentrum.db state sdr_wd) wird bevorzugt, wenn neuer
    import database as _dbt
    dbp = os.path.join(tmp, "lagezentrum.db")
    assert _dbt.migrate(dbp)
    with _WD_LOCK:
        _WD["d"]["sticks"]["19348831"]["last_ok_src"] = "DAB DBTEST"
        _wd_save(tmp, tq + 100, force=True)
    r = _dbt.state_get(WD_KEY, dbp)
    assert r.get("ok") and "DBTEST" in r["text"]
    open(p(WD_FILE, tmp), "w").write('{"t": 1, "sticks": {}}')
    _WD.update(d=None, base=None, started=set(), boot_msgs=[])
    with _WD_LOCK:
        assert _wd_state(tmp)["sticks"]["19348831"]["last_ok_src"] == "DAB DBTEST"
    assert _wd_clean({"sticks": {"../x": {}, "123": "x"}, "reboots": [{"t": "x"}], "pending": {"t": None}}) == _wd_new()
    # Sicherheit: dual_tick waehrend USB-Neuverbindung unterdrueckt, Hilfsprogramm-Pfad fest (Umgebung nur Test/Simulation)
    _WD["busy"] = "19348831"
    assert _wd_dual_tick(m) is None
    _WD["busy"] = None
    assert WD_HELPER == "/usr/local/sbin/prepper-sdr-wdhelper" and not WD_SN_RE.match("1934883") and not WD_SN_RE.match("19348831;x")
WDB_EOF
EXPECT_BSM="d22ac2ee235d8aec2a3685284999ccb4698f9b6db86343d920e3976d2bd90e8e"
cat > "$W/wd_sm_block.py" << 'WDS_EOF'
# ===== sdrWd: Anzeige Daten-Watchdog (aus sdr_status stick_health[.wd]) - Funk-Lage/T4 zeigen den echten SDR-Zustand ("SDR laeuft, 11D ohne Empfang seit ...") statt fest "SDR liefert Daten"; Lage-Stufe/Label (und damit der Mesh-Heartbeat) bleiben unveraendert; DAB-Telemetrie nur bei Sync; nur lesen, sendet nichts =====
WD_STATUS_MAX_AGE_S = 180
WD_LVL_ORDER = {"grau": 0, "ok": 1, "gelb": 2, "rot": 3}
WD_LVL_COLOR = {"grau": "#94a3b8", "ok": "#22c55e", "gelb": "#eab308", "rot": "#ef4444"}


def _wd_hm(t, now=None):
    try:
        t, now = int(t), int(now or time.time())
        return time.strftime("%H:%M" if time.localtime(t)[:3] == time.localtime(now)[:3] else "%d.%m. %H:%M", time.localtime(t))
    except Exception:
        return "–"


def wd_status(st, now=None):
    """Daten-Watchdog je Stick + Pi-Neustarts aus sdr_status. -> {"lvl", "color", "txt", "short", "sticks", "reboots_today", "last_reboot", "reboot_line", ...}"""
    now = int(now or time.time())
    st = st if isinstance(st, dict) else {}
    t = st.get("t")
    fresh = isinstance(t, (int, float)) and -60 <= now - t <= WD_STATUS_MAX_AGE_S
    sticks = []
    for k in ("stick_health", "stick_health2"):
        h = st.get(k) if isinstance(st.get(k), dict) else {}
        v = h.get("wd") if isinstance(h.get("wd"), dict) else None
        if v and v.get("sn"):
            sticks.append({x: v.get(x) for x in ("sn", "n", "lvl", "txt", "ch", "src", "since", "dur_s", "stage", "usb_n", "usb_max", "restart_n", "reboot_n", "block", "last_ok",
                                                  "last_ok_src", "last_check", "fail_n", "usb_last", "hint")})
    g = next((v.get("g") for k in ("stick_health", "stick_health2") for v in [((st.get(k) or {}) if isinstance(st.get(k), dict) else {}).get("wd") or {}]
              if isinstance(v.get("g"), dict)), {}) or {}
    worst = max(sticks, key=lambda v: (WD_LVL_ORDER.get(v.get("lvl"), 0), -(v.get("n") or 9))) if sticks else None
    if not sticks:
        lvl, txt, short = "grau", "Daten-Watchdog: noch keine Angaben von prepper-sdr", None
    elif not fresh:
        lvl, txt, short = "grau", "Daten-Watchdog: prepper-sdr meldet seit %s nichts" % _wd_hm(t, now), None
    else:
        lvl = worst.get("lvl") or "grau"
        if lvl in ("gelb", "rot"):
            txt = worst.get("txt") or "?"
            short = "SDR läuft, %s ohne Empfang seit %s" % (worst.get("ch") or "Stick %s" % worst.get("n"), _wd_hm(worst.get("since"), now))
        else:
            txt, short = "alle Sticks mit echtem Empfang" if lvl == "ok" else (worst.get("txt") or "noch keine Prüfung"), None
    if g.get("stopped"):
        lvl = "rot"
        short = (short or "SDR ohne Empfang") + " – Stick/Antenne prüfen (keine weiteren Pi-Neustarts)"
    lr = g.get("last_reboot")
    rl = "Pi-Neustarts heute: %d · zuletzt %s%s" % (int(g.get("reboots_today") or 0), _wd_hm(lr, now) if lr else "–",
                                                    (" (läuft)" if g.get("pending") else "") if lr else "")
    if g.get("reboot_fail_n"):
        rl += " · ohne Erfolg %d/%d" % (int(g["reboot_fail_n"]), int(g.get("reboot_max_fail") or 3))
    return {"lvl": lvl, "color": WD_LVL_COLOR.get(lvl, "#94a3b8"), "txt": txt, "short": short, "fresh": bool(fresh), "sticks": sticks, "on": g.get("on", True) is not False,
            "reboots_today": int(g.get("reboots_today") or 0), "last_reboot": lr, "reboot_fail_n": int(g.get("reboot_fail_n") or 0),
            "reboot_max_fail": int(g.get("reboot_max_fail") or 3), "stopped": bool(g.get("stopped")), "pending": g.get("pending"), "helper": g.get("helper"),
            "cfg": g.get("cfg") if isinstance(g.get("cfg"), dict) else {}, "reboot_line": rl}


def wd_status_base(base, now=None):
    return wd_status(_load(os.path.join(base, "sdr_status.json"), {}) or {}, now)


_wd_orig_t4_sdr = t4_sdr


def t4_sdr(base, now=None):
    r = _wd_orig_t4_sdr(base, now)
    try:
        r["wd"] = wd_status_base(base, now)
    except Exception as e:
        r["wd"] = {"lvl": "grau", "color": WD_LVL_COLOR["grau"], "txt": "Daten-Watchdog nicht lesbar: %s" % str(e)[:80], "sticks": [], "reboot_line": ""}
    return r


def wd_level(lvl, sd):
    """t4_level-Ergebnis um den echten SDR-Zustand ergaenzen: Text statt fest "SDR liefert Daten", lvl["sdr"]; lvl/label/blink bleiben (Mesh-Heartbeat gleich)."""
    try:
        if not isinstance(lvl, dict):
            return lvl
        w = (sd or {}).get("wd") if isinstance(sd, dict) else None
        out = dict(lvl)
        if not isinstance(w, dict):
            return out
        if w.get("lvl") in ("gelb", "rot") and w.get("short"):
            why = str(out.get("why") or "")
            out["why"] = (why.replace("SDR liefert Daten", w["short"]) if "SDR liefert Daten" in why else (why + " · " + w["short"]).strip(" ·"))[:260]
            out["sdr"] = {"lvl": w["lvl"], "color": w.get("color"), "txt": w["short"]}
        elif w.get("lvl") == "grau" and "SDR liefert Daten" in str(out.get("why") or ""):
            out["why"] = str(out["why"]).replace("SDR liefert Daten", "SDR-Empfang ungeprüft")[:260]
            out["sdr"] = {"lvl": "grau", "color": w.get("color"), "txt": w.get("txt")}
        else:
            out["sdr"] = {"lvl": w.get("lvl") or "ok", "color": w.get("color"), "txt": "SDR liefert Daten"}
        return out
    except Exception as e:
        print("sdr_manager sdrWd:", e, flush=True)
        return lvl


# ----- sdrWd/mastFix: Kartenliste T4_MASTS/TRANSMITTERS mit denselben Namen/Lagen wie MASTS_DB (prepper-sdr); kartevec zeichnet zusaetzlich alle 5C/10C-Sender aus MASTS_DB -----
WD_T4_FIX = {
    "nbg-schweinau": {"name": "Nürnberg (Schweinau)", "lat": 49.42639, "lon": 11.03778, "h_mast": 292},
    "dillberg": {"name": "Dillberg (Neumarkt)", "lat": 49.32639, "lon": 11.38194, "h_mast": 231},
    "hersbruck": {"name": "Hersbruck"},
    "ochsenkopf": {"name": "Ochsenkopf (Fichtelgebirge)", "lat": 50.03111, "lon": 11.81389, "h_mast": 176},
    "bamberg-geisberg": {"name": "Bamberg (Geisberg)", "lat": 49.8893, "lon": 11.062, "h_mast": 115},
    "buettelberg": {"name": "Büttelberg (Frankenhöhe)", "lat": 49.4146, "lon": 10.378, "h_mast": 220},
    "hesselberg": {"name": "Hesselberg (Wassertrüdingen)"},
    "amberg-rotbuehl": {"name": "Amberg (Hirschau/Rotbühl)"},
    "hohe-linie": {"name": "Hohe Linie (Regensburg)"},
}
WD_T4_NEW = [
    {"id": "wuerzburg-frankenwarte", "name": "Würzburg (Frankenwarte)", "lat": 49.7805, "lon": 9.9063, "site_m": 355, "ant_m": 102, "h_mast": 118, "tii": {"11D": "0619", "5C": "1208"}},
    {"id": "gelbelsee", "name": "Gelbelsee", "lat": 48.94642, "lon": 11.42872, "site_m": 539, "ant_m": 105, "h_mast": 112, "tii": {"11D": "0105", "5C": "1204"}},
    {"id": "nennslingen", "name": "Nennslingen (Burgsalach)", "lat": 49.04505, "lon": 11.08752, "site_m": 614, "ant_m": 153, "h_mast": 158, "tii": {"5C": "2220"}},
    {"id": "blessberg", "name": "Sonneberg (Bleßberg)", "lat": 50.4468, "lon": 11.0044, "site_m": 864, "ant_m": 177, "h_mast": 195, "tii": {"5C": "2607"}},
]


def _wd_t4_fix():
    """T4_MASTS/TRANSMITTERS in place angleichen (ids bleiben), neue 5C-Standorte anhaengen. Idempotent."""
    for lst in (T4_MASTS, TRANSMITTERS):
        for m in lst:
            f = WD_T4_FIX.get(m.get("id"))
            if f:
                m.update({k: v for k, v in f.items() if k != "h_mast" or lst is T4_MASTS})
    have = {m["id"] for m in T4_MASTS}
    for n in WD_T4_NEW:
        if n["id"] not in have:
            T4_MASTS.append(dict(n, tii=dict(n["tii"])))


_wd_t4_fix()


def _wd_kv_more(bs, sites, site):
    """kartevec: 5C/10C-Sender aus MASTS_DB (t2.masts) ergaenzen, die nicht schon ueber T4_MASTS/11D drin sind; gleicher Name = gleicher Standort."""
    t2 = bs.get("t2") if isinstance(bs, dict) and isinstance(bs.get("t2"), dict) else {}
    ms = t2.get("masts") if isinstance(t2.get("masts"), dict) else {}
    have = {(c["ch"], c["tii"]) for s in sites.values() for c in s["ch"]}
    byname = {}
    for k, s in sites.items():
        byname.setdefault(s["name"], k)
    for ch in ("5C", "10C"):
        md = ms.get(ch) if isinstance(ms.get(ch), dict) else {}
        for x in md.get("tii") or []:
            if not isinstance(x, dict):
                continue
            try:
                code = kv_code(x.get("main"), x.get("sub"))
            except Exception:
                continue
            if (ch, code) in have:
                continue
            nm = str(x.get("mast") or kv_txt(code))
            sid = byname.get(nm) or "%s-%s" % (ch.lower(), code)
            site(sid, nm, None, dict(x, _code=code))["ch"].append({"ch": ch, "tii": code})
            byname.setdefault(nm, sid)
            have.add((ch, code))


def _selftest_mastfix_sm():
    by = {m["id"]: m for m in T4_MASTS}
    assert by["bamberg-geisberg"]["lat"] == 49.8893 and by["nbg-schweinau"]["name"] == "Nürnberg (Schweinau)" and by["dillberg"]["tii"] == {"11D": "0513", "5C": "2221", "10C": "0702"}
    assert by["blessberg"]["tii"] == {"5C": "2607"} and by["wuerzburg-frankenwarte"]["tii"]["5C"] == "1208" and all(m.get("site_m") and m.get("ant_m") for m in T4_MASTS)
    assert {t["id"]: t for t in TRANSMITTERS}["bamberg-geisberg"]["lon"] == 11.062 and "h_mast" not in TRANSMITTERS[0]
    n0 = len(T4_MASTS)
    _wd_t4_fix()
    assert len(T4_MASTS) == n0
    bs = {"t2": {"masts": {"11D": {"tii": [{"main": 8, "sub": 18, "mast": "Bamberg (Geisberg)", "lat": 49.8893, "lon": 11.062},
                                           {"main": 6, "sub": 6, "mast": "Kreuzberg (Rhön)", "lat": 50.36944, "lon": 9.98051}]},
                           "5C": {"tii": [{"main": 12, "sub": 11, "mast": "Bamberg (Geisberg)", "lat": 49.8893, "lon": 11.062},
                                          {"main": 12, "sub": 14, "mast": "Kreuzberg (Rhön)", "lat": 50.36944, "lon": 9.98051},
                                          {"main": 26, "sub": 6, "mast": "Kulpenberg", "lat": 51.38, "lon": 11.09, "site_m": 473, "ant_m": 103}]},
                           "10C": {"tii": [{"main": 12, "sub": 1, "mast": "Kleť (České Budějovice) [CRA DAB+ CZ]", "lat": 48.865, "lon": 14.28389, "ens": "CRA DAB+ CZ"}]}}}}
    ml, _src = kv_mastlist(bs)
    b = {m["id"]: m for m in ml}
    assert [c["tii"] for c in b["11d-0606"]["ch"]] == ["0606", "1214"] and b["5c-2606"]["name"] == "Kulpenberg" and b["5c-2606"]["site_m"] == 473
    assert b["10c-1201"]["lat"] == 48.865 and len([c for m in ml for c in m["ch"] if (c["ch"], c["tii"]) == ("5C", "1211")]) == 1
    return len(ml)
# ----- /mastFix -----


def selftest_sdrwd():
    import tempfile
    now = int(time.time())
    g = {"reboots_today": 1, "last_reboot": now - 600, "reboot_fail_n": 1, "reboot_max_fail": 3, "stopped": False, "pending": None, "on": True, "helper": "bereit", "cfg": {"wd_usb_min": 45}}
    w1 = {"sn": "19348831", "n": 1, "lvl": "rot", "ch": "11D", "src": "dab", "since": now - 3 * 3600, "stage": 3, "usb_n": 1, "usb_max": 2,
          "txt": "Stick 1 · 11D kein Sync seit 23:11 · Stufe 3 USB-Neuverbindung (1/2)", "g": g}
    w2 = {"sn": "72055505", "n": 2, "lvl": "ok", "ch": "BR24", "src": "rds", "txt": "Stick 2 · BR24 Empfang ok", "g": g}
    st = {"t": now - 10, "stick_health": {"lvl": "gelb", "wd": w1}, "stick_health2": {"lvl": "ok", "wd": w2}}
    s = wd_status(st, now)
    assert s["lvl"] == "rot" and s["short"].startswith("SDR läuft, 11D ohne Empfang seit ") and s["reboots_today"] == 1 and "Pi-Neustarts heute: 1 · zuletzt" in s["reboot_line"], s
    assert len(s["sticks"]) == 2 and "ohne Erfolg 1/3" in s["reboot_line"]
    base = t4_level(None, [], {}, None)
    assert base["lvl"] == "ok" and "SDR liefert Daten" in base["why"]
    lv = wd_level(base, {"wd": s})
    assert lv["lvl"] == base["lvl"] and lv["label"] == base["label"] and lv["blink"] == base["blink"] and lv["color"] == base["color"]       # Mesh-Heartbeat unveraendert
    assert "SDR liefert Daten" not in lv["why"] and "11D ohne Empfang seit" in lv["why"] and lv["sdr"]["lvl"] == "rot", lv
    ok = wd_status({"t": now, "stick_health": {"wd": dict(w1, lvl="ok", txt="Stick 1 · 11D Empfang ok")}}, now)
    assert ok["lvl"] == "ok" and wd_level(base, {"wd": ok})["why"] == base["why"]
    assert wd_status({"t": now - 900, "stick_health": {"wd": w1}}, now)["lvl"] == "grau" and wd_status({}, now)["lvl"] == "grau"
    assert "SDR-Empfang ungeprüft" in wd_level(base, {"wd": wd_status({}, now)})["why"]
    stp = wd_status({"t": now, "stick_health": {"wd": dict(w1, g=dict(g, stopped=True, reboot_fail_n=3))}}, now)
    assert stp["lvl"] == "rot" and "Stick/Antenne prüfen" in stp["short"]
    al = t4_level(None, [{"real": True, "src": "ASA", "text": "Warnung"}], {}, None)
    assert wd_level(al, {"wd": s})["label"] == "ECHTALARM" and wd_level("x", {}) == "x" and wd_level(base, None) == base
    # Telemetrie: DAB-Zeile nur bei Sync
    d = tempfile.mkdtemp(prefix="lzwd-")
    _write_json(os.path.join(d, "broadcast_state.json"), {"dab": {"11D": {"rx": False, "t": now - 3600, "demod": {"t": now, "snr": None, "sync": False}},
                                                                   "5C": {"rx": True, "t": now, "demod": {"t": now, "snr": 9.5, "sn": "72055505"}},
                                                                   "10C": {"t": now, "demod": {"t": now, "snr": 3.0, "sync": False}}}})
    rows = telemetry_rows(d, now)
    assert [r["channel"] for r in rows] == ["5C"], rows
    _write_json(os.path.join(d, "sdr_status.json"), st)
    assert t4_sdr(d, now)["wd"]["lvl"] == "rot"
    nmf = _selftest_mastfix_sm()
    return "sdr_manager selftest sdrWd ok (Watchdog-Anzeige je Stick, Pi-Neustarts heute/zuletzt, Lage-Text ehrlich, Stufe/Label/Mesh-Heartbeat unveraendert, DAB-Telemetrie nur bei Sync; Kartenliste wie MASTS_DB, kartevec 5C/10C aus MASTS_DB, Test %d Standorte)" % nmf
WDS_EOF
EXPECT_BDA="d45772c17decd78b53090e62edb28c1ad8a1d37c3571ce9d231d2ead262248f1"
cat > "$W/wd_dash_block.py" << 'WDD_EOF'
# ===== sdrWd: Daten-Watchdog-Anzeige - /funk Funk-Lage Kasten mit Ampel (Stufe, ohne Empfang seit, USB-Resets, Pi-Neustarts heute/zuletzt), /pi Kachel ueber der Sicherung (Sicherung bleibt letzte), GET /api/sdr/wd, Lage-Text ehrlich (Stufe/Label/Mesh unveraendert), Alarm-Sperre fuer prepper-sdr (sdr_wd_gate.json), Empfaenger-Zeilen ruhig (eine Zeile, fester Kurztext, Details aufklappbar); nur Anzeige, sendet nichts =====
import os as _wd_os, time as _wd_time, json as _wd_json, html as _wd_html
_WDD = {"err": None, "selftest": None, "gate": None, "gate_t": 0}
WD_GATE_FILE = "sdr_wd_gate.json"


def _wd_base():
    try:
        return _t4_paths()[0]
    except Exception:
        return _wd_os.path.dirname(_wd_os.path.abspath(__file__))


def _wd_st(now=None):
    try:
        if _lz_mgr is None or not hasattr(_lz_mgr, "wd_status"):
            return {"lvl": "grau", "color": "#94a3b8", "txt": "Daten-Watchdog: sdr_manager ohne sdrWd", "sticks": [], "reboot_line": ""}
        return _lz_mgr.wd_status(_sdr_load("sdr_status.json", {}) or {}, now or _wd_time.time())
    except Exception as e:
        return {"lvl": "grau", "color": "#94a3b8", "txt": "Daten-Watchdog nicht lesbar: %s" % str(e)[:80], "sticks": [], "reboot_line": ""}


def _wd_gate_write(base, alarm, why, now):
    """Echter Alarm im Lagezentrum -> prepper-sdr sperrt Stufen 2-4 (Datei atomar, nur bei Wechsel oder alle 60 s)."""
    k = (bool(alarm), str(why or "")[:80])
    if _WDD["gate"] == k and now - _WDD["gate_t"] < 60:
        return
    fn = _wd_os.path.join(base, WD_GATE_FILE)
    tmp = fn + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(_wd_json.dumps({"t": int(now), "alarm": bool(alarm), "why": str(why or "")[:160]}, ensure_ascii=False))
    _wd_os.replace(tmp, fn)
    _WDD["gate"], _WDD["gate_t"] = k, now


def _wd_t4(lvl, sd, base, now):
    try:
        if not (_T4.get("fake") or {}):
            _wd_gate_write(base, isinstance(lvl, dict) and lvl.get("lvl") == "alarm", (lvl or {}).get("why"), now)
    except Exception as e:
        print("sdrWd Alarm-Sperre:", e, flush=True)
    try:
        return _lz_mgr.wd_level(lvl, sd) if _lz_mgr is not None and hasattr(_lz_mgr, "wd_level") else lvl
    except Exception as e:
        print("sdrWd Lage-Text:", e, flush=True)
        return lvl


def _wd_bc_note():
    try:
        st = _sdr_load("sdr_status.json", {}) or {}
        du = st.get("dual") if isinstance(st.get("dual"), dict) else {}
        if du.get("role1") == "bc":
            return "Stick 1 hört fest BR24 über DAB 11D (Gain-Leiter + Daten-Watchdog); ASA DE (DAB 5C) liest Stick 2 nur bei Alarm-Übernahme, UKW-RDS macht Stick 2 im Hobby-Betrieb"
        if du.get("role1") == "single" or not du:
            return "Ein Stick: prüft abwechselnd BR24 (UKW + DAB 11D) und ASA DE (DAB 5C), nicht gleichzeitig"
        return "Stick 1 Rolle %s · Stick 2 Rolle %s" % (du.get("role1"), du.get("role2"))
    except Exception:
        return "Stick 1 hört DAB 11D"


def _wd_api():
    try:
        d = _wd_st()
        code = 200
    except Exception as e:
        d, code = {"err": str(e)[:160]}, 200
    d["now"] = int(_wd_time.time())
    return _wd_json.dumps(d, ensure_ascii=False), code, {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"}


def _wd_g(x):
    try:
        return "%g" % float(x)
    except Exception:
        return "?"


def _wd_pi_html(w, now):
    e = _wd_html.escape
    col = w.get("color") or "#94a3b8"
    lab = {"ok": "OK", "gelb": "GELB", "rot": "ROT"}.get(w.get("lvl"), "–")
    rows = ['<div style="display:flex;align-items:center;gap:8px;font-size:0.86rem;line-height:1.35;flex-wrap:wrap"><span style="color:%s">●</span><b>%s</b><span>%s</span></div>'
            % (col, lab, e(w.get("short") or w.get("txt") or ""))]
    for s in w.get("sticks") or []:
        c2 = {"ok": "#22c55e", "gelb": "#eab308", "rot": "#ef4444"}.get(s.get("lvl"), "#94a3b8")
        rows.append('<div style="font-size:0.82rem;line-height:1.35;overflow-wrap:anywhere"><span style="color:%s">●</span> %s</div>' % (c2, e(str(s.get("txt") or "")[:200])))
    rows.append('<div style="font-size:0.82rem;line-height:1.35;font-variant-numeric:tabular-nums">%s</div>' % e(w.get("reboot_line") or ""))
    c = w.get("cfg") or {}
    rows.append('<div class="small" style="color:#94a3b8;overflow-wrap:anywhere">Automatik %s · gelb %s min · Neustart %s min · USB %s min (max %s) · Pi-Neustart %s min, max 1 je %s min, Stopp nach %s ohne Erfolg · Hilfsprogramm %s</div>' % ((
        "an" if w.get("on", True) else "AUS",) + tuple(_wd_g(c.get(k, d)) for k, d in (("wd_yellow_min", 10), ("wd_restart_min", 30), ("wd_usb_min", 45), ("wd_usb_max", 2),
        ("wd_reboot_min", 60), ("wd_reboot_min_interval_min", 60), ("wd_reboot_max_fail", 3))) + (e(str(w.get("helper") or "?")),)))
    return '<div class="card" id="wdPiBox" style="margin-top:16px"><div class="title">SDR-Daten-Watchdog</div>%s</div>' % "".join(rows)


_WD_CSS = r"""#sdrUiCard .su-rows .su-row:not(.fu-ropen){align-items:center!important;min-height:32px}
#sdrUiCard .su-rows .su-row:not(.fu-ropen) .su-dot{margin-top:0!important}
#sdrUiCard .su-rows .su-row .su-k{flex:0 0 auto!important;white-space:nowrap!important}
#sdrUiCard .su-rows .su-row:not(.fu-ropen) .su-v,#sdrUiCard .su-rows .su-row.dh-row:not(.fu-ropen) .su-v{white-space:nowrap!important;overflow:hidden!important;text-overflow:ellipsis!important;overflow-wrap:normal!important;flex:1 1 0!important;min-width:0!important}
#sdrUiCard .su-rows .su-row .su-v,#sdrUiCard .su-chip .su-l2{font-variant-numeric:tabular-nums}
#sdrUiCard .sd-lb{line-height:17px;min-height:34px;font-variant-numeric:tabular-nums}
#sdrUiCard .su-rows .su-row.fu-ropen .su-v{white-space:normal!important;overflow:visible!important;overflow-wrap:anywhere!important}
#sdrUiCard .su-chip .su-l2{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#wdBox{margin-top:8px;padding-top:8px;border-top:1px solid #1e293b;font-size:.85rem;min-width:0}
#wdBox .wd-hd{display:flex;align-items:center;gap:8px;margin-bottom:4px}
#wdBox .wd-t{font-weight:600;color:#e2e8f0}
#wdBox .wd-pill{padding:1px 8px;border-radius:999px;font-size:.75rem;font-weight:700;color:#0f172a;background:#94a3b8}
#wdBox .wd-pill.ok{background:#22c55e}#wdBox .wd-pill.gelb{background:#eab308}#wdBox .wd-pill.rot{background:#ef4444;color:#fff}
#wdBox .wd-r{display:flex;gap:6px;align-items:flex-start;line-height:1.35;overflow-wrap:anywhere;min-width:0;margin:2px 0}
#wdBox .wd-d{flex:0 0 auto}#wdBox .wd-s{color:#94a3b8;font-variant-numeric:tabular-nums}"""

_WD_JS = r"""(function(){var W=null;try{W=JSON.parse(document.getElementById('wd-data').textContent);}catch(e){W=null;}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
var COL={ok:'#22c55e',gelb:'#eab308',rot:'#ef4444',grau:'#94a3b8'},LAB={ok:'OK',gelb:'GELB',rot:'ROT',grau:'\u2013'};
function box(){var c=document.getElementById('fuLage');if(!c||!c.querySelector('.fu-kv'))return;var b=document.getElementById('wdBox');
if(!b){b=el('div');b.id='wdBox';var pb=c.querySelector('.fu-pbox');if(pb)c.insertBefore(b,pb);else c.appendChild(b);}
if(!W)return;var sig=JSON.stringify(W);if(b.dataset.sig===sig)return;b.dataset.sig=sig;b.textContent='';
var h=el('div','wd-hd');h.appendChild(el('span','wd-t','Daten-Watchdog'));h.appendChild(el('span','wd-pill '+(W.lvl||'grau'),LAB[W.lvl]||'\u2013'));b.appendChild(h);
if(W.lvl==='gelb'||W.lvl==='rot'||!(W.sticks||[]).length){var r0=el('div','wd-r');r0.appendChild(el('span','wd-d','\u25CF'));r0.firstChild.style.color=COL[W.lvl]||COL.grau;r0.appendChild(el('span',null,W.short||W.txt||''));b.appendChild(r0);}
(W.sticks||[]).forEach(function(s){var r=el('div','wd-r');var d=el('span','wd-d','\u25CF');d.style.color=COL[s.lvl]||COL.grau;r.appendChild(d);r.appendChild(el('span',null,s.txt||''));b.appendChild(r);});
var c2=W.cfg||{};b.appendChild(el('div','wd-s',(W.reboot_line||'')));
b.appendChild(el('div','wd-s','Automatik '+(W.on===false?'AUS':'an')+' \u00b7 USB-Neuverbindung ab '+(c2.wd_usb_min||45)+' min \u00b7 Pi-Neustart ab '+(c2.wd_reboot_min||60)+' min (max 1/h, Stopp nach '+(c2.wd_reboot_max_fail||3)+')'));}
function rowfix(){var c=document.getElementById('sdrUiCard');if(!c)return;var rs=c.querySelectorAll('.su-rows .su-row');for(var i=0;i<rs.length;i++){var r=rs[i];
if(!r.querySelector('.fu-more')){if(!r.getAttribute('title')&&!r.dataset.fuTip)r.dataset.fuTip=' ';var x=el('button','fu-more','\u25BE');x.type='button';x.setAttribute('aria-label','Details');r.appendChild(x);}}}
function load(){fetch('/api/sdr/wd',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.lvl){W=j;box();}}).catch(function(){});}
function tick(){try{box();rowfix();}catch(e){}}
tick();setInterval(tick,1000);setInterval(load,20000);})();"""


def _wd_after(resp):
    try:
        from flask import request as rq
        if rq.path not in ("/funk", "/pi") or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="sdrwd-js"' in body or 'id="wdPiBox"' in body:
            return resp
        now = _wd_time.time()
        if rq.path == "/funk":
            j = body.rfind("</body>")
            if j >= 0:
                dj = _wd_json.dumps(_wd_st(now), ensure_ascii=False).replace("<", "\\u003c")
                resp.set_data(body[:j] + '<style id="sdrwd-css">' + _WD_CSS + '</style><script type="application/json" id="wd-data">' + dj +
                              '</script><script id="sdrwd-js">' + _WD_JS + '</script>' + body[j:])
        else:
            k = body.find('<div class="card" id="backupBox"')
            if k >= 0:
                resp.set_data(body[:k] + _wd_pi_html(_wd_st(now), now) + body[k:])
    except Exception as e:
        print("sdrWd Seite:", e, flush=True)
    return resp


def _wd_selftest():
    now = 1790000000
    w = {"lvl": "rot", "color": "#ef4444", "txt": "x", "short": "SDR läuft, 11D ohne Empfang seit 23:11", "reboot_line": "Pi-Neustarts heute: 1 · zuletzt 03:12", "on": True,
         "sticks": [{"n": 1, "lvl": "rot", "txt": "Stick 1 · 11D kein Sync seit 23:11 · Stufe 3 USB-Neuverbindung (1/2) <script>"}], "cfg": {"wd_usb_min": 45}, "helper": "bereit"}
    h = _wd_pi_html(w, now)
    assert h.startswith('<div class="card" id="wdPiBox"') and "<script>" not in h and "Pi-Neustarts heute: 1" in h and "ROT" in h and "USB 45" in h, h
    assert "doPrepperRestore" not in h and 'id="backupBox"' not in h
    for k in ("/api/sdr/wd", "wdBox", "fu-more", "fuLage"):
        assert k in _WD_JS, k
    assert "method:" not in _WD_JS and "XMLHttpRequest" not in _WD_JS and "localStorage" not in _WD_JS and _WD_JS.count("fetch(") == 1 and ".click()" not in _WD_JS
    assert "text-overflow:ellipsis" in _WD_CSS and "tabular-nums" in _WD_CSS
    if _lz_mgr is not None and hasattr(_lz_mgr, "wd_level"):
        lv = {"lvl": "ok", "label": "OK", "blink": False, "color": "#22c55e", "why": "kein echter Alarm, keine ASA-Probe, SDR liefert Daten, kein Vor-Alarm", "notes": []}
        o = _lz_mgr.wd_level(lv, {"wd": w})
        assert o["label"] == "OK" and "11D ohne Empfang" in o["why"]
    assert "Stick" in _wd_bc_note()
    return "sdrWd selftest ok (Funk-Lage Watchdog-Kasten, /pi-Kachel vor Sicherung, API nur lesen, Lage-Text ehrlich, Empfänger-Zeilen einzeilig mit Details, JS ohne POST)"


try:
    try:
        _WDD["selftest"] = _wd_selftest()
    except Exception as _wd_e1:
        _WDD["selftest"] = "sdrWd selftest FEHLER: %s" % _wd_e1
    if "app" in globals() and str(_WDD["selftest"]).startswith("sdrWd selftest ok"):
        if "sdrwd_api" not in app.view_functions:
            app.add_url_rule("/api/sdr/wd", endpoint="sdrwd_api", view_func=_wd_api, methods=["GET"])
        if not any(getattr(f, "__name__", "") == "_wd_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_wd_after)
        print("sdrWd aktiv: /funk Daten-Watchdog in Funk-Lage + ruhige Empfänger-Zeilen, /pi Kachel vor Sicherung, /api/sdr/wd; %s" % _WDD["selftest"], flush=True)
    else:
        print("sdrWd FEHLER: %s" % _WDD["selftest"], flush=True)
except Exception as _wd_e2:
    _WDD["err"] = str(_wd_e2)[:160]
    print("sdrWd FEHLER:", _wd_e2, flush=True)
# ===== /sdrWd =====
WDD_EOF
EXPECT_HL="ff536c2eadc4a2e447307e7776ec5d7f7aa4e551df46456e95693a90170ba92a"
cat > "$W/prepper-sdr-wdhelper" << 'WDH_EOF'
#!/usr/bin/python3 -I
"""prepper-sdr-wdhelper (sdrWd) - die einzigen root-Aktionen des SDR-Daten-Watchdogs von prepper-sdr.
  check              nichts aendern, nur Aufruf/Berechtigung pruefen (rc 0)
  usb-reset SERIAL   genau EIN USB-Geraet 0bda:2838 (RTL-SDR) mit dieser Seriennummer (genau 8 Ziffern), kein Hub:
                     USBDEVFS_RESET auf /dev/bus/usb/BBB/DDD, danach authorized 0 -> 1, wartet bis die Seriennummer wieder da ist
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


def find(root, sn):
    """Alle Geraete 0bda:2838 mit genau dieser Seriennummer, ohne Hubs. -> [(Name, Pfad)]"""
    out = []
    for n in sorted(os.listdir(root)):
        if not NAME_RE.match(n):
            continue
        d = os.path.join(root, n)
        try:
            vid, pid, ser = _rd(d, "idVendor").lower(), _rd(d, "idProduct").lower(), _rd(d, "serial")
        except Exception:
            continue
        if (vid, pid) != VIDPID or ser != sn:
            continue
        try:
            if _rd(d, "bDeviceClass") == "09":
                continue                                               # Hub - nie
        except Exception:
            pass
        out.append((n, d))
    return out


def usb_reset(sn, root=SYS, devroot=DEV, ioctl=None, sleep=time.sleep, wait_s=20):
    if not isinstance(sn, str) or not SN_RE.match(sn):
        return 2, "Seriennummer ungueltig (genau 8 Ziffern)"
    f = find(root, sn)
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
        if os.path.exists(auth) and len(find(root, sn)) == 1:
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
        if len(find(root, sn)) == 1:
            return 0, "Stick SN %s wieder da (%s): %s" % (sn, name, "; ".join(note))
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
    print("wdhelper selftest ok (nur 0bda:2838 mit genau dieser 8-stelligen Seriennummer, kein Hub/Interface/SSD, doppelt = nichts, Neustart max 1 je 55 min + 6 je 24 h, Fake-Baum)")
    return 0


def main(argv):
    if argv == ["check"]:
        print("bereit (uid %d)" % os.geteuid())
        return 0
    if argv == ["selftest"]:
        return selftest()
    if not ((len(argv) == 2 and argv[0] == "usb-reset") or argv == ["reboot"]):
        if os.environ.get("WDH_QUIET") != "1":
            print("Aufruf: prepper-sdr-wdhelper check | usb-reset SERIAL | reboot | selftest", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("nur als root (sudo -n)", file=sys.stderr)
        return 8
    lk = open(LOCK, "w")
    fcntl.flock(lk, fcntl.LOCK_EX)
    if argv[0] == "usb-reset":
        rc, txt = usb_reset(argv[1])
    else:
        rc, txt = reboot()
    log("%s %s -> rc %d: %s" % (argv[0], argv[1] if len(argv) > 1 else "", rc, txt))
    print(txt)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
WDH_EOF
EXPECT_G="e1f6fc04cfe6dd9258235d574ddf2784e274d1e2696eddbb565ddebac92538e8"
cat > "$W/guard_wd.py" << 'WDG_EOF'
"""AST-Guard fuer sdrWd (aus guard_fu). Aufruf: guard_fu.py NAME EDITS  ART ALT NEU BLOCK ...  (ART = sm | sdr | dash) -> 0 ok, 1 Verstoss.
Ruecktausch (Block weg, Stellen zurueck) muss Byte fuer Byte die Basis ergeben (schon eingespielt: nur Struktur).
Neue Bloecke/Stellen: keine Prozesse, kein Netz, kein shell, keine Sendewege, keine neuen Faeden.
dashboard: nur GET-Routen /meteor/thumb/<name> (neu) und /dabhist (Ersatz), sonst nur Ansichten ersetzt; prepper_sdr: nur PIL fuer Vorschaubilder."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
label = sys.argv[1]
g = {}
exec(compile(rd(sys.argv[2]), "edits", "exec"), g)
OKMOD = {"sm": {"os", "time", "json", "tempfile"}, "dash": {"os", "time", "json", "html", "flask"},
         "sdr": {"os", "time", "json", "tempfile", "database"}}
ROUTES = {"/api/sdr/wd"}
# sdrWd: genau diese privilegierten/Prozess-Aufrufe sind erlaubt (Funktion, Name) - sonst Verstoss
ALLOW = {("sdr", "_wd_helper", "run"), ("sdr", "_wd_do", "kill")}
seen_allow = {}
err, new_code = [], []
a = sys.argv[3:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    done = old == new and B.splitlines()[0] in old
    if new.count(B) != 1:
        err.append("%s: Block %s fehlt oder doppelt" % (kind, label))
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1) if kind != "dash" else new.replace(B, "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block %s" % (kind, len(E), label))
    new_code.append((kind, "Block", B))
    for o, n in E:
        ol = set(o.splitlines())
        new_code.append((kind, "Stelle", "\n".join(x for x in n.splitlines() if x not in ol)))
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover_auto", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode")
for kind, what, code in new_code:
    name = "%s %s" % (kind, what)
    if what != "Block":
        low = code.lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread"):
            if k in low:
                err.append("%s: %s" % (name, k))
        continue
    try:
        t = ast.parse(code)
    except SyntaxError as e:
        err.append("%s: Syntax %s" % (name, e)); continue
    fn_of = {}
    for f in t.body:
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                fn_of[id(x)] = f.name
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                full = getattr(n, "module", None) or x.name
                mod = full.split(".")[0]
                if mod not in OKMOD[kind]:
                    err.append("%s: Import %s" % (name, mod))
                if mod == "flask" and x.name not in ("request", "send_from_directory", "abort"):
                    err.append("%s: flask.%s" % (name, x.name))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s: shell" % name)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if nm == "add_url_rule" and kind == "dash":
                kw = {k.arg: k.value for k in n.keywords}
                rule = getattr(n.args[0], "value", None) if n.args else None
                meth = kw.get("methods")
                if rule not in ROUTES or not (isinstance(meth, ast.List) and [getattr(x, "value", None) for x in meth.elts] == ["GET"]):
                    err.append("%s: Route %s" % (name, rule))
                continue
            ctx = (kind, fn_of.get(id(n), ""), nm)
            if ctx in ALLOW and (nm != "run" or base == "subprocess"):
                seen_allow[ctx] = seen_allow.get(ctx, 0) + 1
                continue
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer") \
                    or base in ("subprocess", "requests", "socket", "multiprocessing"):
                err.append("%s: Aufruf %s" % (name, nm))
        if kind == "dash" and isinstance(n, ast.Subscript) and isinstance(n.value, ast.Attribute) and n.value.attr == "view_functions" and isinstance(n.ctx, ast.Store):
            err.append("%s: Ansicht ersetzt" % name)
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and any(k in n.value for k in ("uhubctl", "/unbind", "bind_ports", "power/control", "usb_port_power")):
            err.append("%s: verbotener USB-Weg im Text" % name)
    if kind == "sdr":
        src = ast.get_source_segment(code, [f for f in t.body if isinstance(f, ast.FunctionDef) and f.name == "_wd_helper"][0]) or ""
        if '["sudo", "-n", h]' not in src or "shell" in src or 'os.environ.get("SDR_WD_HELPER") or WD_HELPER' not in src or 'if not _WD.get("live")' not in src:
            err.append("sdr Block: _wd_helper anders als vorgesehen")
        consts = [n.value.value for n in t.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "WD_HELPER" and isinstance(n.value, ast.Constant)]
        if consts != ["/usr/local/sbin/prepper-sdr-wdhelper"]:
            err.append("sdr Block: WD_HELPER-Pfad")
    if kind == "dash":
        jsv = [n.value.value for n in t.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "_WD_JS" and isinstance(n.value, ast.Constant)]
        if len(jsv) != 1:
            err.append("%s: _WD_JS fehlt" % name)
        for js in ("method:", "XMLHttpRequest", "sendBeacon", "WebSocket", "localStorage"):
            if any(js in v for v in jsv):
                err.append("%s: JavaScript %s" % (name, js))
if "sdr" in a[0::4] and (seen_allow.get(("sdr", "_wd_helper", "run")) != 1 or not seen_allow.get(("sdr", "_wd_do", "kill"))):
    err.append("sdr Block: erlaubte Aufrufe nicht genau wie vorgesehen %s" % seen_allow)
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard %s: nur die vorgesehenen Stellen + Bloecke%s; kein Netz, kein shell, keine Faeden, keine Sendewege; einziger Prozessaufruf subprocess.run in _wd_helper (fest %s, sonst sudo -n genau dieses Programm, nur im Dienst), kill nur in _wd_do; kein uhubctl/Portstrom/unbind; Dashboard nur GET /api/sdr/wd, keine Ansicht ersetzt, JS ohne POST" % (
    label, " (schon eingespielt)" if all(rd(a[i + 1]) == rd(a[i + 2]) for i in range(0, len(a), 4)) else "", "/usr/local/sbin/prepper-sdr-wdhelper"))
WDG_EOF
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
EXPECT_WC="aba4a8ccf5b7761cc2982a9f88b4ec5eee0d4107f026c17e26d1cf7810d34590"
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
    print("Hilfsprogramm: nur 0bda:2838 mit 8-stelliger Seriennummer (keine Hubs/Interfaces), einziger Prozess systemctl reboot (gesperrt: 1 je 55 min, 6 je 24 h), kein uhubctl/Portstrom/unbind")
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
    exp = "%s ALL=(root) NOPASSWD: %s check, %s usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], %s reboot\n" % (u, h, h, h)
    lines = [x for x in s.splitlines(True) if not x.startswith("#")]
    assert lines == [exp], (lines, exp)
    print("sudoers: genau eine Regel fuer %s: %s check | usb-reset <8 Ziffern> | reboot" % (u, h))
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
PF="$W/patch-fu.py"; ED="$W/wd_edits.py"; BSD="$W/wd_sdr_block.py"; BSM="$W/wd_sm_block.py"; BDA="$W/wd_dash_block.py"; HL="$W/prepper-sdr-wdhelper"
SG="$W/guard_wd.py"; CK="$W/sqlccheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_ED $ED" "$EXPECT_BSD $BSD" "$EXPECT_BSM $BSM" "$EXPECT_BDA $BDA" "$EXPECT_HL $HL" "$EXPECT_G $SG" "$EXPECT_CK $CK" "$EXPECT_FC $FC" "$EXPECT_WC $WC"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ -n "${4:-}" && "$1" == "$4" ]] && echo "bekannt ($5)" || echo "neu, Erkennung ueber Stellen/Guards"; }; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "funkUI" "$KNOWN_D16N" "sdrWd schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "funkUI" "$KNOWN_SM16N" "sdrWd schon drin"))"
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sdrLog" "$KNOWN_SDR16N" "sdrWd schon drin"))"
echo "database.py sha16 $DB16 ($(wc -l < "$DBF") Zeilen, $(kn "$DB16" "$KNOWN_DB16" "sqlC")) - bleibt unveraendert"
echo "mesh_router.py sha16 $MR16 ($(wc -l < "$MR") Zeilen, $(kn "$MR16" "$KNOWN_MR16" "Teil 3")) - bleibt unveraendert"
echo "lagegeo.py sha16 $LG16 ($(kn "$LG16" "$KNOWN_LG16" "lageGeo")) - bleibt unveraendert"
grep -q '# ===== funkUI:' "$F" || { echo "STOP: funkUI fehlt in dashboard.py - bitte zuerst apply-funkui.sh, nichts geaendert"; exit 1; }
grep -q 'def selftest_funkui' "$SMF" || { echo "STOP: funkUI fehlt in sdr_manager.py - nichts geaendert"; exit 1; }
grep -q '# ===== sdrLog:' "$M" || { echo "STOP: sdrLog fehlt in prepper_sdr.py - nichts geaendert"; exit 1; }
grep -q '# ===== sqlC:' "$M" || { echo "STOP: sqlC fehlt in prepper_sdr.py - nichts geaendert"; exit 1; }
grep -q 'def state_get' "$DBF" || { echo "STOP: database.py ohne state_get - nichts geaendert"; exit 1; }
python3 "$PF" sdrWd sdr "$M" "$W/work/prepper_sdr.py" "$BSD" "$ED" > "$W/p0.log" || { cat "$W/p0.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $SDR16) - nichts geaendert"; exit 1; }
python3 "$PF" sdrWd sm "$SMF" "$W/work/sdr_manager.py" "$BSM" "$ED" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: sdr_manager.py unbekannte Basis (sha16 $SM16) - nichts geaendert"; exit 1; }
python3 "$PF" sdrWd dash "$F" "$W/work/dashboard.py" "$BDA" "$ED" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
NP16=$(s16 "$W/work/prepper_sdr.py"); NS16=$(s16 "$W/work/sdr_manager.py"); ND16=$(s16 "$W/work/dashboard.py")
ex() { [[ "$1" == "$2" ]] && echo "wie erwartet" || echo "abweichend von $2 - Guards entscheiden"; }
echo "OK Basis erkannt: $(cat "$W/p0.log"); $(cat "$W/p1.log"); $(cat "$W/p2.log")"
echo "   Ergebnis prepper_sdr.py sha16 $NP16 ($(ex "$NP16" "$KNOWN_SDR16N")), sdr_manager.py sha16 $NS16 ($(ex "$NS16" "$KNOWN_SM16N")), dashboard.py sha16 $ND16 ($(ex "$ND16" "$KNOWN_D16N"))"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
SU=$(systemctl show -p User --value prepper-sdr 2>/dev/null || true); [[ -z "$SU" ]] && SU=root
if ! [[ "$SU" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "STOP: Benutzer von prepper-sdr unklar ($SU) - nichts geaendert"; exit 1; fi
RULE="$SU ALL=(root) NOPASSWD: $HDST check, $HDST usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], $HDST reboot"
if [[ "$SU" == root ]]; then echo "prepper-sdr laeuft als root: Hilfsprogramm direkt, keine sudoers-Regel noetig"; else echo "prepper-sdr laeuft als $SU: Hilfsprogramm ueber sudo -n, sudoers-Regel genau dafuer"; fi
# sdrWd-sudo: echter Test wie im Dienst - als $SU, ohne Terminal (setsid, stdin /dev/null), ohne zwischengespeichertes Passwort
asu() { if [[ "$(id -un)" == "$SU" ]]; then setsid -w "$@" < /dev/null; else sudo -n -u "$SU" setsid -w "$@" < /dev/null; fi; }
WD_SUDO_ERR=""; WD_SUDO_OK=""
wd_sudo_verify() {
  local c out rc
  for c in "check" "usb-reset 19348831" "reboot"; do
    rc=0; if [[ "$(id -un)" == "$SU" ]]; then sudo -n -l "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?; else sudo -n -l -U "$SU" "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?; fi
    [[ "$rc" == 0 ]] || { WD_SUDO_ERR="sudo -l: $HDST $c fuer $SU nicht erlaubt (rc $rc: $(head -c 200 "$W/sl.log" | tr '\n' ' '))"; return 1; }
  done
  rc=0; out=$(asu sudo -n "$HDST" check 2>&1) || rc=$?
  [[ "$rc" == 0 && "$out" == *"bereit (uid 0)"* ]] || { WD_SUDO_ERR="$SU kann $HDST check nicht ohne Passwort und ohne Terminal ausfuehren (rc $rc: $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200))"; return 1; }
  rc=0; asu sudo -n true > /dev/null 2>&1 || rc=$?
  if [[ "$rc" == 0 ]]; then
    WD_SUDO_OK="$HDST check | usb-reset <8 Ziffern> | reboot ohne Passwort, Aufruf ohne Terminal wie im Dienst geprueft (Hinweis: $SU hat schon allgemeines sudo ohne Passwort - Gegenprobe entfaellt)"; return 0
  fi
  for c in "selftest" "usb-reset 1234" "usb-reset 19348831 x" "usb-reset ../x"; do
    rc=0; out=$(asu sudo -n "$HDST" $c 2>&1) || rc=$?
    [[ "$rc" != 0 && "$out" == sudo:* ]] || { WD_SUDO_ERR="sudo erlaubt zu viel ohne Passwort: $HDST $c (rc $rc)"; return 1; }
  done
  WD_SUDO_OK="nur $HDST check | usb-reset <8 Ziffern> | reboot ohne Passwort, Aufruf ohne Terminal wie im Dienst geprueft, andere Aufrufe verlangen Passwort"
}
wd_sudo_diag() {
  echo "DIAG $(sudo -V 2>/dev/null | head -1); Skript als $(id -un), Dienst als $SU (Gruppen $(id -nG "$SU" 2>/dev/null | tr ' ' ','))"
  echo "DIAG Hilfsprogramm: $(ls -l "$HDST" 2>&1 | cut -c1-160)"
  echo "DIAG /etc/sudoers.d: $(sudo -n ls -1 /etc/sudoers.d 2>&1 | tr '\n' ' ' | cut -c1-400)"
  echo "DIAG Defaults tty/pty/env: $(sudo -n grep -rhE '^[[:space:]]*Defaults.*(tty|pty|env_)' /etc/sudoers /etc/sudoers.d 2>/dev/null | tr -s ' \t' ' ' | tr '\n' ';' | cut -c1-400)"
  echo "DIAG Regeln mit $SU oder Gruppe: $(sudo -n grep -rlE "^[[:space:]]*($SU|%)" /etc/sudoers /etc/sudoers.d 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
  sudo -n -l -U "$SU" 2>&1 | sed -n '/may run/,$p' | head -14 | cut -c1-200 | sed 's/^/DIAG sudo -l: /' || true
}
# ---------- 2) Trockenlauf ----------
for k in "sdr prepper_sdr $BSD" "sm sdr_manager $BSM" "dash dashboard $BDA"; do set -- $k
  python3 "$PF" sdrWd "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$ED" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/work/dashboard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
  "$py" -W error -c "import ast,sys; compile(open(sys.argv[1]).read(), 'wdhelper', 'exec')" "$HL" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: Hilfsprogramm ($py) - nichts geaendert"; exit 1; }
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
[[ -f "$LG" ]] && cp "$LG" "$W/sbx/"
cp "$DBF" "$MR" "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrwd-selftest timeout 300 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok" "sdr_manager selftest sdrWd ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrwd-selftest timeout 420 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  "$py" -I "$HL" selftest > "$W/hlt.log" 2>&1 || { tail -6 "$W/hlt.log"; echo "STOP: Selbsttest Hilfsprogramm ($py) - nichts geaendert"; exit 1; }
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum, Fake-Neustart; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet):"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest sdrWd ok' "$W/sdrt.log" | tail -1 | cut -c1-300)"
  echo "   $(grep -F 'sdr_manager selftest sdrWd ok' "$W/smt.log" | tail -1 | cut -c1-300)"
  echo "   $(tail -1 "$W/hlt.log" | cut -c1-220)"
done
python3 "$SG" sdrWd "$ED" sdr "$M" "$W/work/prepper_sdr.py" "$BSD" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" dash "$F" "$W/work/dashboard.py" "$BDA" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
python3 "$WC" helper "$HL" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; echo "STOP: Hilfsprogramm-Guard - nichts geaendert"; exit 1; }
if command -v node >/dev/null 2>&1; then
  python3 - "$W/work/dashboard.py" "$W" << 'JSPY' || { echo "STOP: JavaScript fehlerhaft - nichts geaendert"; exit 1; }
import ast, re, subprocess, sys
want = ("_T2D_JS", "_T4_JS", "_FU_JS", "_WD_JS", "_DH_JS")
n_ok = 0
for n in ast.parse(open(sys.argv[1], encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in want and isinstance(n.value, ast.Constant):
        f = "%s/%s.js" % (sys.argv[2], n.targets[0].id)
        v = n.value.value
        if v.lstrip().startswith("<"):
            v = "\n;\n".join(re.findall(r"<script[^>]*>(.*?)</script>", v, re.S))
        open(f, "w", encoding="utf-8").write(v)
        if not v.strip() or subprocess.run(["node", "--check", f]).returncode:
            raise SystemExit(1)
        n_ok += 1
if n_ok != len(want):
    raise SystemExit("JS-Bloecke %d/%d" % (n_ok, len(want)))
JSPY
  echo "OK JavaScript (Watchdog-Kasten, Empfaenger-Zeilen, Funk-Lage) syntaktisch geprueft (node)"
fi
if [[ "$SU" != root ]]; then
  printf '# sdrWd: prepper-sdr (%s) darf genau diese drei Aufrufe des Hilfsprogramms als root, sonst nichts\n%s\n' "$SU" "$RULE" > "$W/sudoers"
  python3 "$WC" sudoers "$W/sudoers" "$SU" "$HDST" > "$W/wc.log" 2>&1 || { cat "$W/wc.log"; echo "STOP: sudoers-Regel falsch - nichts geaendert"; exit 1; }
  visudo -cf "$W/sudoers" > "$W/vis.log" 2>&1 || { cat "$W/vis.log"; echo "STOP: visudo -cf lehnt die Regel ab - nichts geaendert"; exit 1; }
  echo "OK sudoers-Regel geprueft (visudo -cf): $(cat "$W/wc.log")"
fi
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
ALL=("$M" "$SMF" "$F")
perm_ok() { [[ "$(stat -c '%U:%G %a' "$1" 2>/dev/null)" == "root:root $3" ]]; }
H_SAME=0; cmp -s "$HL" "$HDST" 2>/dev/null && perm_ok "$HDST" x 755 && H_SAME=1
S_SAME=1; if [[ "$SU" != root ]]; then sudo -v; S_SAME=0; sudo -n cmp -s "$W/sudoers" "$SDST" 2>/dev/null && S_SAME=1; fi
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/dashboard.py" "$F" && [[ "$H_SAME" == 1 && "$S_SAME" == 1 ]]; then
  echo "OK sdrWd schon installiert (3 Dateien, Hilfsprogramm, sudoers) - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  H_OLD=0; [[ -f "$HDST" ]] && { cp -a "$HDST" "$W/helper.old"; H_OLD=1; }
  S_OLD=0; sudo -n test -f "$SDST" 2>/dev/null && { sudo -n cat "$SDST" > "$W/sudoers.old"; S_OLD=1; }
  rb() {
    echo "ROLLBACK: $1"
    for u in prepper-sdr prepper-dashboard; do sudo journalctl -u "$u" --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sdrWd|Traceback" | tail -4 | cut -c1-200 || true; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sdrwd-$TS" ]] && cp -a "$x.bak-sdrwd-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    if [[ "$H_OLD" == 1 ]]; then sudo install -o root -g root -m 0755 "$W/helper.old" "$HDST" || true; else sudo rm -f "$HDST" || true; fi
    if [[ "$SU" != root ]]; then
      if [[ "$S_OLD" == 1 ]]; then sudo install -o root -g root -m 0440 "$W/sudoers.old" "$SDST" || true; else sudo rm -f "$SDST" || true; fi
      sudo rm -f "$SDST.tmp" || true
    fi
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-sdrwd-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Hilfsprogramm $HDST: $([[ -f "$HDST" ]] && echo "alter Stand" || echo "entfernt"); sudoers $SDST: $(sudo -n test -f "$SDST" 2>/dev/null && echo "alter Stand" || echo "entfernt")"
    echo "  Sicherung lagezentrum.db von vorher: $LZ.bak-sdrwd-$TS (nicht zurueckgespielt; sdrWd fuegt nur Zustand sdr_wd + Ereignisse hinzu)"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-sdrwd-$TS"
    { ls -1t "$x.bak-sdrwd-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sdrwd-$TS" \
      || { rm -f "$LZ.bak-sdrwd-$TS"; for x in "${ALL[@]}"; do rm -f "$x.bak-sdrwd-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sdrwd-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
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
  # sdrWd-sudo: Pruefung erst NACH dem Einspielen des Hilfsprogramms (sudo -l mit Befehl meldet sonst "command not found")
  if [[ "$SU" != root ]]; then
    wd_sudo_verify || { echo "FEHLER sudo-Pruefung: $WD_SUDO_ERR"; wd_sudo_diag; rb "sudo-Regel wirkt nicht wie erwartet ($WD_SUDO_ERR)"; exit 1; }
    echo "OK sudo-Regel fuer $SU: $WD_SUDO_OK"
  fi
  for k in "prepper_sdr $M" "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sdrwd-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (max 240 s; Watchdog beobachtet die ersten 5 min nur, setzt nichts zurueck; sendet nichts) ..."
  sudo systemctl restart prepper-sdr.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$CK" statusfresh "$DASH_DIR" "$T0" && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr meldet keinen frischen Status"; exit 1; }
  echo "Neustart prepper-dashboard - warte auf HTTP (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist "/dabhist?ch=11D" "/dabhist?c=warn,tech,stick,rx,prog" /karte /api/sdr/wd /api/sdr/live /api/t2/status /api/t4/status /api/t4/tii /api/br24; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
python3 "$FC" funk "$W/funk.html" "$W" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/funk ohne funkUI"; }
python3 "$WC" funk "$W/funk.html" "$W" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne Daten-Watchdog"; }
"${CURL[@]}" "$B/dabhist" -o "$W/dh.html" || true
python3 "$FC" dabhist "$W/dh.html" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/dabhist alt"; }
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$WC" pi "$W/pi.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/pi Watchdog-Kachel"; }
"${CURL[@]}" "$B/api/sdr/wd" -o "$W/wd.json" || true
python3 "$WC" api "$W/wd.json" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/wd"; }
"${CURL[@]}" "$B/api/br24" -o "$W/br24.json" || true
python3 "$WC" br24 "$W/br24.json" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/br24 Hinweis alt"; }
NMF=$(grep -o 'WD_MF_N = {"11D": [0-9]*, "5C": [0-9]*, "10C": [0-9]*}' "$M" | grep -o ': [0-9][0-9]*' | tr -d ': ' | tr '\n' ' ' || true)
mok=0; for i in $(seq 1 30); do "${CURL[@]}" "$B/api/t2/status" -o "$W/t2.json" || true; python3 "$WC" masts "$W/t2.json" $NMF > "$W/wc.log" 2>&1 && { mok=1; break; }; sleep 6; done
[[ "$mok" == 1 ]] && echo "OK $(cat "$W/wc.log")" || { [[ "$RESTARTED" == 1 ]] && rbx "$(cat "$W/wc.log")"; echo "HINWEIS $(cat "$W/wc.log")"; }
"${CURL[@]}" "$B/api/t4/tii" -o "$W/tii.json" || true
python3 "$WC" tii "$W/tii.json" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t4/tii Karte"; }
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JS=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrWd aktiv" | tail -2 || true)
if [[ "$JS" == *"sdrWd aktiv"* ]]; then echo "OK Journal prepper-sdr: $(echo "$JS" | tail -1 | cut -c1-300)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "prepper-sdr meldet sdrWd nicht (Journal)"; fi
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(sdrWd|funkUI|sqlC) (aktiv|FEHLER)" | tail -10 || true)
if [[ "$JD" == *"sdrWd FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2)"; fi
if [[ "$JD" == *"sdrWd aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'sdrWd aktiv' | tail -1 | cut -c1-400)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet sdrWd nicht (Journal)"; fi
[[ "$JD" == *"funkUI aktiv"* || "$RESTARTED" == 0 ]] && echo "OK Journal Dashboard: funkUI weiter aktiv" || rbx "Dashboard meldet funkUI nicht mehr"
E1=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrWd (Start|Pruefung|Anzeige|speichern|Zustand|Technik)|^sdrWd:" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrWd-Fehler" || rbx "$E1 Traceback/sdrWd-Fehlerzeilen im Journal prepper-sdr"
E2=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrWd FEHLER|funkUI FEHLER|sdr_manager kartevec" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sdrWd-Fehler" || rbx "$E2 Traceback/sdrWd-Fehlerzeilen im Journal Dashboard"
echo "$(python3 "$WC" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-300)"
for x in "$DBF:$DB16" "$MR:$MR16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
echo "OK guards sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sdrWd(sdr_manager)=$(grep -c '# ===== sdrWd:' "$SMF" || true) sdrWd(dash)=$(grep -c '# ===== sdrWd:' "$F" || true) mastFix(sdr)=$(grep -c '# ----- sdrWd/mastFix:' "$M" || true) mastFix(sdr_manager)=$(grep -c '# ----- sdrWd/mastFix:' "$SMF" || true) sdrLog(sdr)=$(grep -c '# ===== sdrLog:' "$M" || true) sqlC(sdr)=$(grep -c '# ===== sqlC:' "$M" || true) funkUI(dash)=$(grep -c '# ===== funkUI:' "$F" || true) funkUI(sdr_manager)=$(grep -c 'def selftest_funkui' "$SMF" || true) sqlC(dash)=$(grep -c '# ===== sqlC:' "$F" || true)"
echo "Hilfsprogramm $HDST: $([[ -f "$HDST" ]] && echo "sha16 $(s16 "$HDST"), $(stat -c '%U:%G %a' "$HDST")" || echo fehlt) · sudoers $SDST: $([[ "$SU" == root ]] && echo "nicht noetig (prepper-sdr als root)" || (sudo -n test -f "$SDST" && echo "$RULE" || echo fehlt))"
echo "Schalter/Schwellen (sdr_config.json, fehlt = Standard): $(python3 "$WC" cfg "$DASH_DIR" 2>&1 | tail -1 | cut -c1-300)"
[[ -f "$F.bak-sdrwd-$TS" ]] && echo "Backups: *.bak-sdrwd-$TS (prepper_sdr.py, sdr_manager.py, dashboard.py, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: die drei .bak-sdrwd-$TS zurueckkopieren, sudo rm $SDST $HDST, dann sudo systemctl restart prepper-sdr prepper-dashboard"
echo "Abschalten ohne Rueckweg: in sdr_config.json wd_enable auf false (wirkt ohne Neustart; Anzeige bleibt)"
echo "COMMIT $COMMIT_ARG sdrwd=1 fertig"
