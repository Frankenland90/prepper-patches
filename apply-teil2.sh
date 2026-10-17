#!/bin/bash
set -euo pipefail
# Teil 2 von 4 (auf rdsNotfall): Stick 1 fest 11D, Stick 2 Hobby (RDS BR24/Bayern 3/Bayern 1, QRM, Kalibrierung, 433, APRS) und bei echtem Alarm
# (NINA Severe/Extreme, echter BR24-Notfall, ASA-Echtalarm) oder per Knopf sofort fest auf 5C; Rueckgabe NUR per Knopf. MASTS_DB 11D/5C/10C,
# FIG 0/9 + TII + Labels aus welle-cli in lagezentrum.db, ASA-Dienst-Ueberwachung (Soll gelernt, ASA_INTERRUPTED), GPIO vorbereitet (AUS),
# Auto-Versand echter Alarme an Mesh 1 (Schalter, Standard AUS; eine Meldung je Alarm, 6 h, max 3/h, Tests nie) ueber den bestehenden Sendeweg.
# Dateien: prepper_sdr.py, dashboard.py, database.py, sdr_manager.py, mesh_router.py. Neustart nur prepper-sdr + prepper-dashboard. Sendet beim Einspielen nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
MODS=(database.py sdr_manager.py mesh_router.py)
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/teil2-apply
KEEP_LAST=3
KNOWN_SDR16="d486114b716458ec"   # live nach rdsNotfall (Zweig f4652609; Teil 2 = Zweig 2b1b2f1e)
KNOWN_DASH16="a8968c0ed2029f43"  # live nach rdsNotfall (Zweig f4652609; Teil 2 = Zweig 2b1b2f1e)
OLD_MOD16="06dcbe99055e518f c9a152a99d769e68 33f376517dfd968d"   # Teil 1: database.py sdr_manager.py mesh_router.py
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== Teil 2 apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx" "$W/msbx" "$W/new" "$W/old"
EXPECT_BS="ef9a6f21e754fa63d9a2261a32d8b25926098b45552e2dba367dc3ff4375fd89"
cat > "$W/t2_sdr_block.py" << 'T2SDR_EOF'
# ===== sdrTeil2: Teil 2 von 4 - Stick 1 (SN 19348831) fest auf 11D; Stick 2 (SN 72055505) Hobby/Bereitschaft (RDS BR24/Bayern 3/Bayern 1 im Wechsel mit QRM, Kalibrierung, 433, APRS) und bei Alarm sofort fest auf 5C (ASA DE) bis Rueckgabe per Knopf; MASTS_DB mit TII-Referenz; FIG 0/9, TII und Labels aus welle-cli mux.json; ASA-Empfangszeiten; nur Empfang, sendet nichts =====
MASTS_DB = {
    "11D": {"f_mhz": 222.064, "name": "BR Bayern", "main_id": 7, "sub_ids": [1, 2, 5], "rx": "Stick 1 fest",
            "src": "Frequenz: ETSI EN 300 401 Kanalraster Band III (11D = 222,064 MHz); TII MainID 07 / SubID 01, 02, 05: Vorgabe Frank (Teil 2)"},
    "5C": {"f_mhz": 178.352, "name": "1. Bundesmux (DR Deutschland, ASA DE)", "main_id": None, "sub_ids": [], "rx": "Stick 2 nur bei Alarm",
           "src": "Frequenz: ETSI EN 300 401 Kanalraster Band III (5C = 178,352 MHz); Belegung: Vorgabe Frank (Teil 2)"},
    "10C": {"f_mhz": 213.360, "name": "Lokal Nürnberg", "main_id": None, "sub_ids": [], "rx": "nur Referenz, kein Empfang",
            "src": "Frequenz: ETSI EN 300 401 Kanalraster Band III (10C = 213,360 MHz); Belegung: Vorgabe Frank (Teil 2)"},
}
T2_CH1 = "11D"               # Stick 1 fest
T2_CH_ALARM = "5C"           # Stick 2 bei Alarm (ASA DE)
T2_TAKEOVER = "sdr_takeover.json"   # schreibt nur das Dashboard (Alarm-Ausloeser + Knopf); prepper-sdr liest nur
T2_TII_STABLE = 2            # gleiche TII-Kennungen in 2 Pruefungen nacheinander = stabil
T2_TII_GAP_S = 600           # TII-Wechsel je Kanal hoechstens alle 10 min als Ereignis
T2_EV_MAX = 100
T2_ASA_MAX = 400
T2_JOURNALINE = "nicht verfuegbar: welle-cli dekodiert keine Journaline-Datendienste; dablin wird nicht genutzt (siehe dablin)"
_T2_TLS = threading.local()
_T2_TO = {}
_T2_DABLIN = {}


def t2_on(pl):
    """Teil-2-Rollen nur im Dienst (loop setzt t2) - Selbsttests der alten Bloecke sehen das alte Verhalten."""
    m = getattr(pl, "main", None) or pl
    return bool(getattr(m, "t2", False))


def t2_takeover(base):
    """sdr_takeover.json lesen (nach mtime zwischengespeichert). Fehlt/kaputt = keine Uebernahme."""
    fn = p(T2_TAKEOVER, base)
    try:
        mt = os.path.getmtime(fn)
    except Exception:
        return {"on": False}
    if _T2_TO.get("fn") == fn and _T2_TO.get("mt") == mt:
        return _T2_TO["d"]
    d = load_json(fn, {}) or {}
    d = d if isinstance(d, dict) else {}
    r = {"on": d.get("on") is True, "since": d.get("since") if isinstance(d.get("since"), (int, float)) else None,
         "src": str(d.get("src") or "")[:20], "why": str(d.get("why") or "")[:160], "by": str(d.get("by") or "")[:20]}
    _T2_TO.update(fn=fn, mt=mt, d=r)
    return r


def t2_dablin():
    if not _T2_DABLIN:
        import shutil
        exe = shutil.which("dablin") or shutil.which("dablin_gtk")
        _T2_DABLIN.update(exe=exe, used=False, why=("installiert, aber nicht genutzt: dablin braucht einen ETI/EDI-Strom (eigener Stick-Oeffner), "
                                                     "die Sticks laufen nur ueber prepper-sdr/welle-cli" if exe else
                                                     "nicht installiert - FIG 0/9, TII und Labels kommen aus welle-cli mux.json"))
    return dict(_T2_DABLIN)


def t2_mast(ch, main, sub):
    m = MASTS_DB.get(str(ch)) or {}
    if m.get("main_id") == main and sub in (m.get("sub_ids") or []):
        return "%s MainID %02d / SubID %02d" % (m["name"], main, sub)
    return "MainID %02d / SubID %02d (nicht in MASTS_DB)" % (main, sub)


def _t2_num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def t2_fig_parse(mux, t, ch):
    """welle-cli mux.json -> FIG 0/9 (ECC, LTO), Ensemble-Kennung/Label, TII (pattern = MainID, comb = SubID), Dienst-Labels. Ohne Sync -> None."""
    if not isinstance(mux, dict):
        return None
    ens = mux.get("ensemble") if isinstance(mux.get("ensemble"), dict) else {}
    lab = ens.get("label")
    full, short = (lab.get("label"), lab.get("shortlabel")) if isinstance(lab, dict) else (lab, None)
    full = str(full or "").strip()[:40]
    eid = str(ens.get("id") or "").strip()[:8] or None
    ecc = str(ens.get("ecc") or "").strip()[:6] or None
    if ecc in ("0x00", "0x0", "0"):
        ecc = None
    ut = mux.get("utctime") if isinstance(mux.get("utctime"), dict) else {}
    lto = _t2_num(ut.get("lto"))
    labels = []
    for sv in (mux.get("services") or [])[:60] if isinstance(mux.get("services"), list) else []:
        if isinstance(sv, dict):
            l = sv.get("label")
            l = l.get("label") if isinstance(l, dict) else l
            l = str(l or "").strip()[:30]
            if l and l not in labels:
                labels.append(l)
    tii = []
    for x in (mux.get("tii") or [])[:24] if isinstance(mux.get("tii"), list) else []:
        if isinstance(x, dict) and isinstance(x.get("comb"), int) and isinstance(x.get("pattern"), int):
            km, er = _t2_num(x.get("delay_km")), _t2_num(x.get("error"))
            tii.append({"main": x["pattern"], "sub": x["comb"], "km": round(km, 1) if km is not None else None, "err": round(er, 2) if er is not None else None,
                        "mast": t2_mast(ch, x["pattern"], x["comb"])})
    tii.sort(key=lambda y: y["err"] if y["err"] is not None else 9e9)
    sync = bool(full or labels) and eid != "0x0000"
    if not sync:
        return None
    return {"t": int(t), "ch": str(ch), "ecc": ecc, "lto": lto, "ens_id": eid, "ens": full, "ens_short": str(short or "").strip()[:12] or None,
            "tii": tii[:8], "tii_on": isinstance(mux.get("tii"), list), "labels": sorted(labels)[:40], "n_svc": len(labels)}


def t2_fig_note(t2, ch, x, t):
    """Ergebnis einer Pruefung merken; Ereignisse nur bei Aenderung (FIG 0/9, Ensemble-Label, stabiler TII-Wechsel)."""
    fig = t2.setdefault("fig", {})
    prev = fig.get(ch) if isinstance(fig.get(ch), dict) else {}
    evs = t2.setdefault("ev", [])
    t = int(t)

    def ev(k, text):
        evs.append({"id": "T2:%s:%s:%d" % (ch, k, t), "t": t, "ch": ch, "k": k, "text": text[:200]})
        del evs[:-T2_EV_MAX]
    new = dict(x)
    f09 = [x.get("ecc"), x.get("lto")]
    old09 = prev.get("fig09")
    if x.get("ecc") is not None or x.get("lto") is not None:
        if old09 is None:
            ev("fig09", "DAB %s FIG 0/9: ECC %s, Ortszeit-Abstand LTO %s h" % (ch, x.get("ecc") or "?", "%+g" % x["lto"] if x.get("lto") is not None else "?"))
        elif list(old09) != f09:
            ev("fig09", "DAB %s FIG 0/9 geaendert: ECC %s -> %s, LTO %s -> %s" % (ch, old09[0] or "?", x.get("ecc") or "?", old09[1], x.get("lto")))
        new["fig09"] = f09
    elif old09 is not None:
        new["fig09"] = old09
    if x.get("ens") and prev.get("ens") and prev.get("ens") != x["ens"]:
        ev("label", "DAB %s Ensemble-Label: '%s' -> '%s'" % (ch, prev.get("ens"), x["ens"]))
    cur = sorted("%02d/%02d" % (y["main"], y["sub"]) for y in x.get("tii") or [])
    stable, cand, n = prev.get("tii_set"), prev.get("tii_cand"), int(prev.get("tii_cand_n") or 0)
    new["tii_set"], new["tii_ev_t"] = stable, prev.get("tii_ev_t")
    if x.get("tii_on") and cur:
        n = n + 1 if cand == cur else 1
        cand = cur
        if n >= T2_TII_STABLE and cur != stable and (stable is None or t - int(prev.get("tii_ev_t") or 0) >= T2_TII_GAP_S):
            names = "; ".join(y["mast"] for y in x["tii"][:3])
            ev("tii", ("DAB %s TII erstmals: %s (%s)" % (ch, ", ".join(cur), names)) if stable is None else
               ("DAB %s TII-Wechsel: %s -> %s (%s)" % (ch, ", ".join(stable), ", ".join(cur), names)))
            new["tii_set"], new["tii_ev_t"] = cur, t
    new["tii_cand"], new["tii_cand_n"] = cand, n
    fig[ch] = new
    return new


def _t2_alarm(self):
    """Stick 2 gekapert? (Rolle rot, Teil 2 aktiv, Uebernahme-Datei an)"""
    return self.role == "rot" and t2_on(self) and t2_takeover(self.base)["on"]


def _t2_dab_idx(self, ch):
    lst = [str(x) for x in self.dab_list()]
    return lst.index(ch) if ch in lst else None


_t2_orig_lage_apply = Planner.lage_apply
_t2_orig_bc_queue = Planner.bc_queue
_t2_orig_act_queue = Planner.act_queue
_t2_orig_want = Planner.want
_t2_orig_sub_done = Planner.sub_done
_t2_orig_stick2_info = Planner.stick2_info
_t2_orig_loop = Planner.loop
_t2_orig_on_dab = StateBC.on_dab


def _t2_lage_apply(self):
    _t2_orig_lage_apply(self)
    try:
        if not t2_on(self) or self.role != "rot":
            return
        c, u = self.cfg, (self.lage_user or {})
        if _t2_alarm(self):      # Alarm: nur noch 5C, kein QRM/Kalibrierung/Meteor/433/APRS/Aktivitaet
            c["bc_enable"] = bool(self.tool("welle"))
            c["asa_5c"] = True
            c["noise_enable"] = c["cal_enable"] = c["meteor_enable"] = False
            c["auto"] = []
            c["bc_interval_s"] = 5.0
        else:                    # Hobby: RDS (BR24, Bayern 3, Bayern 1) im Wechsel mit den bisherigen Aufgaben
            c["bc_enable"] = bool(u.get("bc_enable")) and self.lage["sw"].get("bc") != "aus"
    except Exception as ex:
        print("sdrTeil2 lage_apply:", ex, flush=True)


def _t2_bc_queue(self):
    q = _t2_orig_bc_queue(self)
    try:
        if not t2_on(self) or self.role not in ("bc", "rot"):
            return q
        lst = [str(x) for x in self.dab_list()]
        chq = lambda j: lst[int(j[4:])] if j.startswith("dab:") and int(j[4:]) < len(lst) else None
        if self.role == "bc":
            want = T2_CH1 if T2_CH1 in lst else next((x for x in lst if x != T2_CH_ALARM), None)
            return [x for x in q if chq(x[0]) == want]
        if _t2_alarm(self):
            out = [x for x in q if chq(x[0]) == T2_CH_ALARM]
            i = _t2_dab_idx(self, T2_CH_ALARM)
            if not out and i is not None and self.tool("welle"):
                out = [("dab:%d" % i, float(self.cfg.get("dab_s") or 60))]
            return out
        return [x for x in q if x[0].startswith("rds:")]
    except Exception as ex:
        print("sdrTeil2 bc_queue:", ex, flush=True)
        return q


def _t2_act_queue(self):
    try:
        if _t2_alarm(self):
            return []
    except Exception as ex:
        print("sdrTeil2 act_queue:", ex, flush=True)
    return _t2_orig_act_queue(self)


def _t2_switch(self, al, now):
    """Stick 2 sofort umschalten: laufenden Block/Auftrag sauber beenden, Planer neu waehlen lassen."""
    sp = self.special
    if sp:
        try:
            self.sub_done(sp, now)
        except Exception as ex:
            self.log("sdrTeil2 Blockabbruch:", ex)
        self.special = None
    if self.procs:
        self.kill()
    self.active, self.since = "idle", now
    self.last_bc = 0 if al else now - float(self.cfg.get("bc_interval_s") or 1800) + 120
    to = t2_takeover(self.base)
    if al:
        self.log("sdrTeil2: Stick 2 SN %s ALARM -> fest auf %s (ASA DE), Ausloeser %s: %s" % (cfg_serial(self.cfg), T2_CH_ALARM, to.get("src") or "?", to.get("why") or ""))
    else:
        self.log("sdrTeil2: Stick 2 SN %s zurueck im Hobby-Betrieb (RDS, QRM, Kalibrierung, 433, APRS)" % cfg_serial(self.cfg))


def _t2_note(self, now):
    """Rollen/Betriebsart in broadcast_state.json t2 (fuer Dashboard und lagezentrum.db)."""
    al = _t2_alarm(self) if self.role == "rot" else False
    mode = {"bc": "11D fest", "rot": ("ALARM 5C (ASA DE)" if al else "Hobby (RDS, QRM, Kalibrierung, 433, APRS)"), "single": "Einzelbetrieb (alles wie frueher)"}.get(self.role, str(self.role))
    row = {"role": self.role, "mode": mode, "sn": cfg_serial(self.cfg), "alarm": bool(al), "active": str(self.active)[:20]}
    with self.lock:
        t2 = self.sbc.d.get("t2") if isinstance(self.sbc.d.get("t2"), dict) else {}
        self.sbc.d["t2"] = t2
        rl = t2.setdefault("roles", {})
        k = "s%d" % int(self.stickno or 1)
        old = rl.get(k) or {}
        if {x: old.get(x) for x in row} != row:
            row["since"] = int(now) if (old.get("mode") != mode) else old.get("since", int(now))
            rl[k] = row
            t2.update(v=1, on=True, masts=MASTS_DB, dablin=t2_dablin(), journaline=T2_JOURNALINE, takeover=t2_takeover(self.base), t=int(now))
            self.sbc.dirty = True
            if old.get("mode") != mode:
                self.sbc.last_saved = 0   # Betriebsart gleich speichern
        elif t2.get("takeover") != t2_takeover(self.base):
            t2["takeover"] = t2_takeover(self.base)
            self.sbc.dirty = True
            self.sbc.last_saved = 0


def _t2_want(self, mode, now):
    try:
        if t2_on(self) and self.role in ("bc", "rot", "single"):
            if self.role == "rot":
                al = _t2_alarm(self)
                prev = getattr(self, "_t2_al", None)
                self._t2_al = al
                if prev is not None and al != prev or prev is None and al:
                    _t2_switch(self, al, now)
                if al:
                    mode = {"mode": "auto"}   # Alarm hat Vorrang vor 433/APRS/Netz/Vorwahl/Aus auf Stick 2
            else:
                self._t2_al = None
            _t2_note(self, now)
    except Exception as ex:
        print("sdrTeil2 want:", ex, flush=True)
    return _t2_orig_want(self, mode, now)


def _t2_sub_done(self, sp, now):
    _T2_TLS.sn = getattr(self, "dev_sn", None) or cfg_serial(self.cfg)
    try:
        return _t2_orig_sub_done(self, sp, now)
    finally:
        _T2_TLS.sn = None


def _t2_on_dab(self, ch, mux, now=None):
    r = _t2_orig_on_dab(self, ch, mux, now)
    try:
        t = float(now or time.time())
        t2 = self.d.get("t2") if isinstance(self.d.get("t2"), dict) else {}
        self.d["t2"] = t2
        x = t2_fig_parse(mux, t, str(ch))
        if x is not None:
            x["sn"] = getattr(_T2_TLS, "sn", None)
            t2_fig_note(t2, str(ch), x, t)
        e = (self.d.get("dab") or {}).get(ch) or {}
        if str(ch) == T2_CH_ALARM and e.get("asa") and e.get("rx") is not False and int(e.get("t") or 0) == int(t):
            lst = t2.setdefault("asa_rx", [])
            if not lst or t - lst[-1] >= 5:
                lst.append(int(t))
                del lst[:-T2_ASA_MAX]
        self.dirty = True
    except Exception as ex:
        print("sdrTeil2 on_dab:", ex, flush=True)
    return r


def _t2_stick2_info(self):
    r = _t2_orig_stick2_info(self)
    try:
        w = self.worker
        if t2_on(self) and w is not None and w.role == "rot" and not w.pin_err:
            to = t2_takeover(self.base)
            if to.get("on"):
                r["txt"] = "Stick 2 SN %s: ALARM - fest auf 5C (ASA DE) seit %s, Ausloeser %s; Rueckgabe nur per Knopf" % (
                    cfg_serial(w.cfg), time.strftime("%d.%m. %H:%M", time.localtime(to["since"])) if to.get("since") else "?", to.get("src") or "?")
                r["t2"] = "alarm"
            else:
                r["txt"] = "Stick 2 SN %s: Hobby/Bereitschaft (RDS BR24/Bayern 3/Bayern 1, QRM, Kalibrierung, 433, APRS)" % cfg_serial(w.cfg)
                r["t2"] = "hobby"
    except Exception as ex:
        print("sdrTeil2 stick2_info:", ex, flush=True)
    return r


def _t2_loop(self):
    self.t2 = self.cfg.get("t2_roles", True) is not False
    self.log("sdrTeil2: %s" % ("aktiv - Stick 1 fest 11D, Stick 2 Hobby + Alarm-Uebernahme 5C" if self.t2 else "AUS (sdr_config.json t2_roles=false) - Rollen wie vorher"))
    return _t2_orig_loop(self)


Planner.lage_apply = _t2_lage_apply
Planner.bc_queue = _t2_bc_queue
Planner.act_queue = _t2_act_queue
Planner.want = _t2_want
Planner.sub_done = _t2_sub_done
Planner.stick2_info = _t2_stick2_info
Planner.loop = _t2_loop
StateBC.on_dab = _t2_on_dab


def selftest_teil2():
    import tempfile
    had_np, old_np = "numpy" in sys.modules, sys.modules.get("numpy")
    if old_np is None:
        sys.modules["numpy"] = type(sys)("numpy")  # nur fuer den Test: QRM-Messprogramm gilt als vorhanden
    try:
        _selftest_teil2(tempfile.mkdtemp())
    finally:
        if not had_np or old_np is None:
            sys.modules.pop("numpy", None)
            if had_np:
                sys.modules["numpy"] = old_np


def _selftest_teil2(tmp):
    assert abs(MASTS_DB["11D"]["f_mhz"] - DAB_CHANNELS["11D"]) < 1e-6 and abs(MASTS_DB["5C"]["f_mhz"] - DAB_CHANNELS["5C"]) < 1e-6
    assert abs(MASTS_DB["10C"]["f_mhz"] - DAB_CHANNELS["10C"]) < 1e-6 and MASTS_DB["11D"]["main_id"] == 7 and MASTS_DB["11D"]["sub_ids"] == [1, 2, 5]
    assert all(MASTS_DB[k]["src"] for k in MASTS_DB) and "kein Empfang" in MASTS_DB["10C"]["rx"]
    save_cfg_keys(tmp, {"stick2": {"serial": "72055505", "enabled": True}, "dab": ["11D"]})
    m = Planner(tmp)
    w = Planner(tmp, stick=2, main=m)
    m.worker = w
    for x in (m, w):
        x.tools.update({"welle": "/x/welle-cli", "redsea": "/x/redsea", "satdump": None})
        x._has_rp = True
        x.cfg.update(bc_enable=True, noise_enable=True, cal_enable=True)
        x.lage_user = None
    m.set_role("bc"); w.set_role("rot")
    now = 1790000000.0
    assert not t2_on(m) and not t2_on(w)
    m.lage_apply(); w.lage_apply()
    assert any(j.startswith("rds:") for j, _ in m.bc_queue()) and not w.bc_queue()   # ohne t2 = altes Verhalten
    m.t2 = True
    assert t2_on(w)
    m.lage_apply(); w.lage_apply()
    q1 = [j for j, _ in m.bc_queue()]
    assert q1 == ["dab:%d" % m.dab_list().index("11D")], q1                           # Stick 1: nur 11D (kein RDS, kein 5C)
    q2 = [j for j, _ in w.bc_queue()]
    assert q2 and all(j.startswith("rds:") for j in q2) and len(q2) == len(w.fm_list()), q2   # Stick 2 Hobby: RDS
    m.last_bc = 0
    j1 = m.want({"mode": "auto"}, now)
    assert j1 == q1[0] and m.special["kind"] == "bc" and m.special["queue"] == q1, j1
    w.last_noise = 0
    assert w.want({"mode": "auto"}, now).startswith("nz:")                            # Hobby: QRM wie bisher
    w.special = None
    w.last_noise, w.last_bc = now, 0
    w.passes = []
    jr = w.want({"mode": "auto"}, now + 1)
    assert jr.startswith("rds:") and w.special["kind"] == "bc", jr                    # dann RDS-Block
    w.special = None
    w.last_bc = now + 1
    assert w.want({"mode": "auto"}, now + 2) in ("433", "aprs")                       # dazwischen 433/APRS
    sh2 = dict((x["k"], x["pct"]) for x in w.lage_shares(now))
    assert sh2.get("bc", 0) > 0 and "asa" not in sh2 and sh2.get("noise", 0) > 0, sh2
    # Alarm: Uebernahme-Datei an -> Stick 2 sofort fest auf 5C, 433/Vorwahl/Aus haben keinen Vorrang
    write_json(p(T2_TAKEOVER, tmp), {"on": True, "since": int(now), "src": "manual", "why": "Selbsttest", "by": "selftest"})
    w.special = {"kind": "noise", "queue": ["nz:0"], "durs": [60], "i": 0, "sub_end": now + 60, "t0": now}
    w.nzm = None
    ja = w.want({"mode": "433"}, now + 3)
    i5 = w.dab_list().index("5C")
    assert ja == "dab:%d" % i5 and w.special["kind"] == "bc" and w.special["queue"] == ["dab:%d" % i5], (ja, w.special)
    assert w.cfg["auto"] == [] and not w.cfg["noise_enable"] and not w.cfg["cal_enable"] and not w.act_queue() and w.cfg["bc_interval_s"] == 5.0
    assert [j for j, _ in m.bc_queue()] == q1                                            # Stick 1 bleibt auf 11D
    assert "ALARM" in m.stick2_info()["txt"] and m.stick2_info()["t2"] == "alarm"
    w.special = None
    w.last_bc = now + 3
    assert w.want({"mode": "preset", "preset": "fm_br24"}, now + 4) == "idle"           # Luecke zwischen 5C-Pruefungen: nichts anderes
    w.special = None
    assert w.want({"mode": "auto"}, now + 10).startswith("dab:")
    # Rueckgabe (nur per Knopf im Dashboard): Datei aus -> Hobby
    write_json(p(T2_TAKEOVER, tmp), {"on": False, "off_t": int(now) + 20, "by": "selftest"})
    os.utime(p(T2_TAKEOVER, tmp), (now + 20, now + 20))
    w.want({"mode": "auto"}, now + 20)
    assert not _t2_alarm(w) and all(j.startswith("rds:") for j, _ in w.bc_queue()) and w.cfg["auto"] == ["433", "aprs"], w.cfg["auto"]
    assert "Hobby" in m.stick2_info()["txt"]
    rl = m.sbc.d["t2"]["roles"]
    assert rl["s1"]["mode"] == "11D fest" and rl["s2"]["mode"].startswith("Hobby"), rl
    # FIG 0/9 + TII + Labels aus mux.json
    mux = {"ensemble": {"label": {"label": "Bayern", "shortlabel": "BR"}, "id": "0x10A1", "ecc": "0xE0"}, "utctime": {"lto": 2.0},
           "services": [{"label": {"label": "BR24"}}, {"label": {"label": "BAYERN 3"}}],
           "tii": [{"comb": 2, "pattern": 7, "delay_km": 12.34, "error": 0.2}, {"comb": 9, "pattern": 7, "delay_km": 40.0, "error": 0.9}]}
    x = t2_fig_parse(mux, now, "11D")
    assert x["ecc"] == "0xE0" and x["lto"] == 2.0 and x["ens"] == "Bayern" and x["n_svc"] == 2 and x["tii"][0]["main"] == 7 and x["tii"][0]["sub"] == 2
    assert x["tii"][0]["mast"] == "BR Bayern MainID 07 / SubID 02" and "nicht in MASTS_DB" in x["tii"][1]["mast"], x["tii"]
    assert t2_fig_parse({"ensemble": {"id": "0x0000", "label": ""}, "services": []}, now, "11D") is None and t2_fig_parse(None, now, "11D") is None
    b = StateBC(tmp)
    _T2_TLS.sn = "19348831"
    b.on_dab("11D", mux, now=now)
    b.on_dab("11D", mux, now=now + 70)
    ks = [e["k"] for e in b.d["t2"]["ev"]]
    assert ks == ["fig09", "tii"] and b.d["t2"]["fig"]["11D"]["sn"] == "19348831" and b.d["t2"]["fig"]["11D"]["tii_set"] == ["07/02", "07/09"], (ks, b.d["t2"]["fig"]["11D"])
    m2 = dict(mux, tii=[{"comb": 5, "pattern": 7, "delay_km": 30.0, "error": 0.1}])
    b.on_dab("11D", m2, now=now + 140)
    assert [e["k"] for e in b.d["t2"]["ev"]] == ["fig09", "tii"]                       # einmal gesehen = noch nicht stabil
    b.on_dab("11D", m2, now=now + 210)
    assert [e["k"] for e in b.d["t2"]["ev"]] == ["fig09", "tii"]                       # stabil, aber < 10 min seit letztem TII-Ereignis
    b.on_dab("11D", m2, now=now + 700)
    assert [e["k"] for e in b.d["t2"]["ev"]] == ["fig09", "tii", "tii"] and "07/05" in b.d["t2"]["ev"][-1]["text"], b.d["t2"]["ev"]
    b.on_dab("11D", dict(mux, ensemble={"label": {"label": "Bayern2"}, "id": "0x10A1", "ecc": "0xE1"}), now=now + 760)
    assert [e["k"] for e in b.d["t2"]["ev"]][-2:] == ["fig09", "label"], b.d["t2"]["ev"]
    asa = {"ensemble": {"label": "DR Deutschland", "id": "0x10BC"}, "services": [{"label": "ASA DE", "sid": "0x1D11"}, {"label": "Dlf"}]}
    b.on_dab("5C", asa, now=now + 800)
    b.on_dab("5C", asa, now=now + 802)
    b.on_dab("5C", {"ensemble": {"label": "DR Deutschland", "id": "0x10BC"}, "services": [{"label": "Dlf"}]}, now=now + 870)
    b.on_dab("5C", asa, now=now + 940)
    assert b.d["t2"]["asa_rx"] == [int(now + 800), int(now + 940)], b.d["t2"]["asa_rx"]
    _T2_TLS.sn = None
    assert t2_dablin()["used"] is False and t2_dablin()["why"]
    print("selftest sdrTeil2 ok (Stick 1 nur 11D, Stick 2 Hobby RDS/QRM/433/APRS, Alarm -> sofort 5C mit Vorrang, Rueckgabe nur per Datei/Knopf, MASTS_DB, FIG 0/9 + TII stabil + Labels, ASA-Empfangszeiten)")
# ===== /sdrTeil2 =====
T2SDR_EOF
EXPECT_BD="00633ebbf8bbe8035afbb964bfe3e744fac40709152f4643e6b803eef3a54a26"
cat > "$W/t2_dash_block.py" << 'T2DASH_EOF'
# ===== teil2: Teil 2 von 4 - Stick-2-Uebernahme 5C bei echtem Alarm (NINA Severe/Extreme, echter BR24-Notfall, ASA-Echtalarm) oder per Knopf, Rueckgabe NUR per Knopf (POST, gleicher Ursprung, lokal, Bestaetigung); Auto-Versand echter Alarme an Mesh 1 ueber denselben Sendeweg wie der Knopf "An Mesh 1 senden" (Schalter, Standard AUS, eine Meldung je Alarm, 6 h, max 3/h, Tests nie); ASA-Ueberwachung; FIG 0/9/TII in lagezentrum.db; GPIO vorbereitet (AUS); Kachel auf der Lage-Seite =====
import threading as _t2d_thr
import time as _t2d_time
import re as _t2d_re

_T2D = {"ok": False, "err": None, "selftest": None, "nina": {}, "alarms": [], "rep": None, "gpio": None, "t": 0, "n": 0, "started": False, "takeover_ch": None}
_T2D_LOCK = _t2d_thr.Lock()
T2D_TICK_S = 20                        # Pruefung alle 20 s im eigenen Faden (unabhaengig von Seitenaufrufen)
T2D_NINA_URL = "https://warnung.bund.de/api31/warnings/%s.json"   # amtliche Detaildaten (Schweregrad, Status) wie bei NINA/lageGeo
T2D_NINA_NEW_MAX = 3                   # je NINA-Abruf hoechstens 3 neue Detailabfragen
T2D_NINA_RETRY_S = 600                 # Details je Warnung hoechstens alle 10 min neu (NINA-Abruf alle 15 min)
T2D_ID_RE = _t2d_re.compile(r"^[A-Za-z0-9._:-]{3,140}$")
T2D_NINA_DUP = "NINA geht schon ueber die bestehende NINA-Automatik an Mesh 1 (maybe_mesh_nina) - Teil 2 sendet NINA nicht doppelt"


def _t2d_nina_detail(warnings, now=None):
    """Schweregrad/Status je aktiver NINA-Warnung holen (Cache im Speicher, je Warnung hoechstens alle 10 min neu, damit eine
    Hochstufung auf Severe/Extreme ankommt; je Abruf hoechstens 3, aelteste zuerst). Nur Lesen bei warnung.bund.de."""
    now = int(now or _t2d_time.time())
    n, ids = 0, []
    for w in warnings or []:
        wid = str(w.get("id") or "") if isinstance(w, dict) else ""
        if T2D_ID_RE.match(wid) and wid not in ids:
            c = _T2D["nina"].get(wid)
            if not c or now - c.get("t", 0) >= T2D_NINA_RETRY_S:
                ids.append(wid)
    for wid in sorted(ids, key=lambda k: (_T2D["nina"].get(k) or {}).get("t", 0)):
        if n >= T2D_NINA_NEW_MAX:
            break
        n += 1
        try:
            r = requests.get(T2D_NINA_URL % wid, timeout=8, headers={"User-Agent": "KaeswasserLage/1.0"})
            d = r.json() if r.status_code == 200 else None
            if not isinstance(d, dict):
                _T2D["nina"][wid] = dict(_T2D["nina"].get(wid) or {}, t=now, http=r.status_code)   # alter Schweregrad bleibt
                continue
            info = (d.get("info") or [{}])[0] if isinstance(d, dict) and isinstance(d.get("info"), list) and d.get("info") else {}
            _T2D["nina"][wid] = {"severity": info.get("severity") if isinstance(info, dict) else None, "status": d.get("status") if isinstance(d, dict) else None,
                                 "msgType": d.get("msgType") if isinstance(d, dict) else None, "t": now, "http": r.status_code}
        except Exception as e:
            old = _T2D["nina"].get(wid) or {}
            _T2D["nina"][wid] = dict(old, t=now, err=str(e)[:80])   # alter Schweregrad bleibt bei Netzfehler
    if len(_T2D["nina"]) > 300:
        for k in sorted(_T2D["nina"], key=lambda k: _T2D["nina"][k].get("t", 0))[:100]:
            _T2D["nina"].pop(k, None)
    return n


_t2d_orig_fetch_nina = fetch_nina


def fetch_nina():
    r = _t2d_orig_fetch_nina()
    try:
        if _T2D["ok"] and isinstance(r, list):
            _t2d_nina_detail(r)
    except Exception as e:
        print("teil2 NINA-Details:", e, flush=True)
    return r


def _t2d_cfg():
    try:
        c = _sdr_load("sdr_config.json", {}) or {}
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}


def _t2d_manual_sent(now):
    """Texte, die in den letzten 6 h per Knopf an Mesh 1 gingen (lageMesh1, nur im Speicher)."""
    try:
        return [x[2] for x in (globals().get("_lm1_log") or []) if now - x[0] < _lz_mesh.AUTO_SAME_S]
    except Exception:
        return []


def _t2d_tick(now=None, send_fn=None, base=None, path=None, ctx=None):
    """Alarme erkennen -> Stick-2-Uebernahme (immer automatisch) -> Auto-Versand (nur wenn Schalter AN) -> GPIO (vorbereitet, AUS)."""
    now = int(now or _t2d_time.time())
    base, path = base or _SDR_BASE, path or _LZ_PATH
    if ctx is None:
        _lz_sync(30)
        ctx = _lz_ctx()
    _lz_mgr.t2_sync(base, path, now)
    to0 = _lz_mgr.takeover_load(base)
    al = _lz_mgr.alarms_from(ctx.get("nina"), _T2D["nina"], ctx.get("br24"), _lz_dbm.active_events(now, path), now, to0.get("seen"))
    if callable(globals().get("maybe_mesh_nina")):
        for a in al:
            if a.get("src") == "NINA":
                a["dup_existing"] = T2D_NINA_DUP
    to, ch = _lz_mgr.takeover_auto(base, al, now)
    if ch and send_fn is None:
        _T2D["takeover_ch"] = now
        if to.get("on") and not to0.get("on"):
            print("teil2: echter Alarm -> Stick 2 auf 5C gekapert (Ausloeser %s: %s)" % (to.get("src"), str(to.get("why") or "")[:80]), flush=True)
        else:
            print("teil2: weiterer echter Alarm, Stick 2 %s" % ("schon auf 5C" if to.get("on") else "bleibt im Hobby-Betrieb (nur neue Alarme kapern)"), flush=True)
    boot = globals().get("mesh_auto_allowed")
    if callable(boot) and not boot() and send_fn is None:
        rep = {"on": _lz_mesh.auto_state(base)["on"], "t": now, "sent": [], "skip": [{"why": "Dashboard-Start: Mesh-Automatik erst nach %d s" % globals().get("MESH_BOOT_GUARD_SEC", 300)}]}
    else:
        rep = _lz_mesh.auto_send(al, send_fn or send_meshtastic, base, path, now, _t2d_manual_sent(now))
    gp = _lz_mgr.gpio_alarm(_lz_mgr.alarm_identifier(al), _t2d_cfg())
    _T2D.update(alarms=al, rep=rep, gpio=gp, t=now, n=_T2D["n"] + 1, err=None)
    return al, rep


def _t2d_loop():
    _t2d_time.sleep(30)
    while True:
        try:
            with _T2D_LOCK:
                _t2d_tick()
        except Exception as e:
            _T2D["err"] = str(e)[:160]
            print("teil2 Pruefung:", e, flush=True)
        _t2d_time.sleep(T2D_TICK_S)


def _t2d_autosend_info(now):
    st = _lz_mesh.auto_state(_SDR_BASE)
    rep = _T2D.get("rep") or {}
    return {"on": st["on"], "t": st["t"], "by": st["by"], "limit_h": _lz_mesh.AUTO_HOUR_MAX, "same_h": _lz_mesh.AUTO_SAME_S // 3600,
            "hour_n": _lz_dbm.mesh_auto_count(now - 3600, _LZ_PATH), "recent": _lz_dbm.mesh_auto_recent(5, _LZ_PATH),
            "last_skip": (rep.get("skip") or [])[:6], "last_sent": rep.get("sent") or []}


def _t2d_status():
    now = int(_t2d_time.time())
    s = _lz_mgr.t2_status(_SDR_BASE, _LZ_PATH, now, alarms=_T2D.get("alarms"), autosend=_t2d_autosend_info(now), gpio=_T2D.get("gpio"))
    s["tick"] = {"t": _T2D["t"], "n": _T2D["n"], "err": _T2D["err"], "every_s": T2D_TICK_S, "thread": _T2D["started"]}
    st = _sdr_load("sdr_status.json", {}) or {}
    s["stick2_txt"] = ((st.get("stick2") or {}).get("txt") if isinstance(st.get("stick2"), dict) else None)
    s["dual"] = st.get("dual") if isinstance(st.get("dual"), dict) else None
    return s


def _t2d_api():
    from flask import jsonify
    try:
        return jsonify(_t2d_status())
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


def _t2d_same_origin(rq):
    base = rq.host_url.rstrip("/")
    o = rq.headers.get("Origin")
    if o is not None and o.rstrip("/") != base:
        return False
    ref = rq.headers.get("Referer") or ""
    if o is None and not (ref == base or ref.startswith(base + "/")):
        return False
    sfs = rq.headers.get("Sec-Fetch-Site")
    if sfs is not None and sfs != "same-origin":
        return False
    return rq.headers.get("X-T2") == "1" and (rq.mimetype or "") == "application/json"


def _t2d_local(addr):
    """Nur aus dem Heimnetz/Tailscale/vom Pi selbst (keine oeffentliche Adresse)."""
    import ipaddress
    try:
        a = ipaddress.ip_address(str(addr or "").split("%")[0])
        if getattr(a, "ipv4_mapped", None):
            a = a.ipv4_mapped
        return bool(a.is_loopback or a.is_private or (a.version == 4 and a in ipaddress.ip_network("100.64.0.0/10")))
    except Exception:
        return False


def _t2d_check(rq):
    if not _t2d_same_origin(rq):
        return "nur von der Lage-Seite (gleicher Ursprung)", 403
    if not _t2d_local(rq.remote_addr):
        return "nur aus dem lokalen Netz", 403
    j = rq.get_json(silent=True) or {}
    if j.get("confirm") is not True:
        return "Bestaetigung fehlt", 400
    return None, j


def _t2d_stick2_post():
    """Knopf: Stick 2 auf 5C (action alarm) oder zurueck in den Hobby-Betrieb (action zurueck). Rueckgabe gibt es nur hier."""
    from flask import jsonify, request as rq
    err, j = _t2d_check(rq)
    if err:
        return jsonify({"ok": False, "error": err}), j
    act = j.get("action")
    if act not in ("alarm", "zurueck"):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _T2D_LOCK:
        d = _lz_mgr.takeover_set(_SDR_BASE, act == "alarm", "manual", "Knopf auf der Lage-Seite" if act == "alarm" else "", "dashboard")
    print("teil2: Knopf -> Stick 2 %s" % ("auf 5C (Alarm)" if act == "alarm" else "zurueck in den Hobby-Betrieb"), flush=True)
    return jsonify({"ok": True, "on": d.get("on"), "since": d.get("since"), "src": d.get("src")})


def _t2d_autosend_post():
    """Schalter Auto-Versand an Mesh 1 (Kill-Switch)."""
    from flask import jsonify, request as rq
    err, j = _t2d_check(rq)
    if err:
        return jsonify({"ok": False, "error": err}), j
    if not isinstance(j.get("on"), bool):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _T2D_LOCK:
        st = _lz_mesh.set_auto(_SDR_BASE, j["on"], "dashboard")
    print("teil2: Auto-Versand echter Alarme an Mesh 1 jetzt %s" % ("AN" if st["on"] else "AUS"), flush=True)
    return jsonify({"ok": True, "on": st["on"]})


_T2D_JS = r"""
(function(){var D=null,BUSY=0;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function ninaCard(){var ts=document.querySelectorAll('.title');for(var i=0;i<ts.length;i++){if(/\bNINA\b/i.test(ts[i].textContent||'')){var c=ts[i].closest('.card');if(c&&c.id!=='br24Tile'&&c.id!=='t2Tile')return c;}}return null;}
var BS='margin-top:10px;width:100%;background:#1e3a5f;color:#93c5fd;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:0.95rem';
var BR='margin-top:10px;width:100%;background:#3f1d1d;color:#fca5a5;border:1px solid #7f1d1d;border-radius:8px;padding:10px 12px;font-size:0.95rem';
function fmt(t){return t?new Date(t*1000).toLocaleString('de-DE',{timeZone:'Europe/Berlin',day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'–';}
function line(t,cls){var l=el('div',cls||'small');l.style.cssText='white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px';t.appendChild(l);return l;}
function post(url,body,ask,st){if(BUSY)return;if(!window.confirm(ask))return;BUSY=1;st.textContent='…';body.confirm=true;
fetch(url,{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-T2':'1'},body:JSON.stringify(body)})
.then(function(r){return r.json();}).then(function(j){st.textContent=j.ok?'erledigt':('nicht erledigt: '+(j.error||'Fehler'));})
.catch(function(){st.textContent='nicht erledigt: Netzfehler';}).then(function(){BUSY=0;load();});}
function tile(){var n=ninaCard();if(!n||!D)return;var after=document.getElementById('br24Tile')||n;var t=document.getElementById('t2Tile');
if(!t){t=el('div',n.className);t.id='t2Tile';t.appendChild(el('div','title','Sticks & Alarm-Automatik'));t._l=[line(t,'t2-l1'),line(t),line(t),line(t),line(t),line(t)];
t._b1=el('button','t2-btn');t._b1.type='button';t.appendChild(t._b1);t._b2=el('button','t2-btn');t._b2.type='button';t.appendChild(t._b2);t._st=line(t);
t._b1.addEventListener('click',function(){var on=D.takeover&&D.takeover.on;post('/api/t2/stick2',{action:on?'zurueck':'alarm'},on?'Stick 2 wirklich zurück in den Hobby-Betrieb (RDS, QRM, 433, APRS)?\n\n5C (ASA DE) wird dann nicht mehr empfangen.':'Stick 2 jetzt fest auf 5C (ASA DE) schalten?\n\nZurück nur über diesen Knopf.',t._st);});
t._b2.addEventListener('click',function(){var on=D.autosend&&D.autosend.on;post('/api/t2/autosend',{on:!on},on?'Auto-Versand echter Alarme an Mesh 1 AUSschalten?':'Auto-Versand echter Alarme an Mesh 1 EINschalten?\n\nNur echte Alarme (ASA, BR24-Notfall; NINA über die bestehende NINA-Automatik), nie Tests, eine Meldung je Alarm, gleicher Inhalt erst nach 6 h, höchstens 3 je Stunde.',t._st);});}
if(after.nextSibling!==t)after.parentNode.insertBefore(t,after.nextSibling);
var to=D.takeover||{},r=D.roles||{},s1=r.s1||{},s2=r.s2||{},a=D.asa||{},f=(D.fig||{})['11D']||{},as=D.autosend||{},L=t._l;
L[0].textContent='Stick 1'+(s1.sn?' SN '+s1.sn:'')+': '+(s1.mode||'–');
L[1].textContent=to.on?('Stick 2: ALARM – fest auf 5C seit '+fmt(to.since)+' ('+(to.src||'?')+(to.why?': '+to.why:'')+')'):('Stick 2'+(s2.sn?' SN '+s2.sn:'')+': '+(s2.mode||'–'));
L[1].style.color=to.on?'#ef4444':'';L[1].style.fontWeight=to.on?'600':'';
L[2].textContent='ASA-Dienst: '+(a.status||'–')+(a.text?' · '+a.text:'');L[2].style.color=a.status==='ASA_INTERRUPTED'?'#ef4444':'#94a3b8';
var ti=(f.tii||[]).map(function(x){return ('0'+x.main).slice(-2)+'/'+('0'+x.sub).slice(-2);}).join(', ');
L[3].textContent='11D: '+(f.ens||'–')+(f.ecc?' · ECC '+f.ecc:'')+(f.lto!=null?' · LTO '+(f.lto>=0?'+':'')+f.lto+' h':'')+' · TII '+(ti||'–')+(f.t?' · '+fmt(f.t):'');L[3].style.color='#94a3b8';
L[4].textContent='Auto-Versand Mesh 1: '+(as.on?'AN':'AUS')+(as.hour_n!=null?' · letzte Stunde '+as.hour_n+'/'+as.limit_h:'')+((as.recent&&as.recent[0])?' · zuletzt '+fmt(as.recent[0].last_try)+' '+(as.recent[0].ok===1?'ok':'FEHLER'):'');
L[4].style.color=as.on?'#22c55e':'#94a3b8';
var real=(D.alarms||[]).filter(function(x){return x.real;});L[5].textContent=real.length?('Echter Alarm: '+real[0].src+' – '+real[0].text):'kein echter Alarm';L[5].style.color=real.length?'#ef4444':'#94a3b8';
t._b1.textContent=to.on?'↩ Stick 2 zurück in den Hobby-Betrieb':'⚠ Stick 2 jetzt auf 5C (Alarm)';t._b1.setAttribute('style',to.on?BS:BR);
t._b2.textContent=as.on?'📡 Auto-Versand Mesh 1 ausschalten':'📡 Auto-Versand Mesh 1 einschalten';t._b2.setAttribute('style',BS);}
function load(){fetch('/api/t2/status',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.ok){D=j;tile();}}).catch(function(){});}
try{D=JSON.parse(document.getElementById('t2-data').textContent);}catch(e){}
tile();setInterval(tile,2000);setInterval(load,20000);})();
"""


def _t2d_after(resp):
    try:
        from flask import request as _t2d_rq
        if (_t2d_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="t2-js"' not in body:
                try:
                    data = _sdr_json.dumps(_t2d_status(), ensure_ascii=False, default=str).replace("<", "\\u003c")
                except Exception:
                    data = "null"
                add = '<script type="application/json" id="t2-data">' + data + '</script><script id="t2-js">' + _T2D_JS + '</script>'
                j = body.rfind("</body>")
                body = (body[:j] + add + body[j:]) if j >= 0 else (body + add)
                resp.set_data(body)
    except Exception as e:
        print("teil2 Kachel:", e, flush=True)
    return resp


def _t2d_live_wrap():
    orig = _lz_mgr.live
    if getattr(orig, "_t2", False):
        return False

    def live(base, path=None, br=None, extra=None, now=None):
        out = orig(base, path, br, extra, now)
        try:
            out["asa_status"] = _lz_mgr.asa_monitor(base, path, now)["status"]
            out["stick2_takeover"] = _lz_mgr.takeover_load(base)["on"]
        except Exception as e:
            print("teil2 live:", e, flush=True)
        return out
    live._t2 = True
    _lz_mgr.live = live
    return True


def _t2d_selftest():
    import tempfile
    import os as _o
    d = tempfile.mkdtemp()
    p = _o.path.join(d, "lagezentrum.db")
    sent = []

    def fake(text, channel=0):
        sent.append((text, channel))
        return True
    fake.selftest = True
    now = 1790000000
    br = {"state": "rot", "why": {"t": now - 20, "src": "BR24 UKW", "kind": "RDS Notfall", "text": "RDS-Notfallgruppe 9A empfangen (3x in 10 s)", "cls": "rot"}}
    ctx = {"nina": [{"city": "Nürnberg", "title": "Gefahr", "id": "mow.t2", "msgType": "Alert"}], "br24": br}
    nd0, _T2D["nina"] = _T2D["nina"], {"mow.t2": {"severity": "Severe", "status": "Actual", "t": now}}
    ep0 = _lz_mgr._T2.get("br_ep")
    _lz_mgr._T2["br_ep"] = {}
    try:
        al, rep = _t2d_tick(now, fake, d, p, ctx)
        assert sent == [] and not rep["on"] and _lz_mgr.takeover_load(d)["on"], rep                       # Schalter AUS: nichts; Uebernahme trotzdem
        assert {a["src"] for a in al if a["real"]} == {"NINA", "BR24"} and _lz_mgr.alarm_identifier(al) == 2
        _lz_mesh.set_auto(d, True, "selftest", now)
        al, rep = _t2d_tick(now + 30, fake, d, p, ctx)
        assert len(sent) == 1 and sent[0][1] == 0 and sent[0][0].startswith("ALARM BR24") and any(x["why"] == T2D_NINA_DUP for x in rep["skip"]), (sent, rep)
        _t2d_tick(now + 60, fake, d, p, ctx)
        br2 = {"state": "rot", "why": dict(br["why"], t=now + 50)}
        _t2d_tick(now + 70, fake, d, p, {"nina": ctx["nina"], "br24": br2})
        assert len(sent) == 1                                                                             # eine Meldung je Alarm (auch mit neuem Zeitstempel)
        t30 = {"state": "grau", "test": True, "why": {"t": now, "src": "BR24 UKW", "kind": "RDS PTY 30 Alarmtest", "text": "PTY 30 Alarmtest", "cls": "test"}}
        _t2d_tick(now + 90, fake, d, p, {"nina": [], "br24": t30})
        assert len(sent) == 1 and _lz_dbm.mesh_hash_since(_lz_mesh.msg_hash(sent[0][0], _lz_mesh.AUTO_LOGCH), now, p) is True   # Test nie, Protokoll da
        _lz_mgr.takeover_set(d, False, now=now + 100)
        _t2d_tick(now + 120, fake, d, p, ctx)
        assert not _lz_mgr.takeover_load(d)["on"] and len(sent) == 1                                      # Rueckgabe bleibt, kein erneutes Kapern
        assert _t2d_local("127.0.0.1") and _t2d_local("192.168.178.20") and _t2d_local("100.101.1.2") and _t2d_local("::ffff:10.0.0.3")
        assert not _t2d_local("8.8.8.8") and not _t2d_local("") and not _t2d_local("2a00:1450::1")
        assert callable(globals().get("send_meshtastic")) and "send_meshtastic" in _t2d_tick.__code__.co_names
    finally:
        _T2D["nina"] = nd0
        _lz_mgr._T2["br_ep"] = ep0 if isinstance(ep0, dict) else {}
    return "teil2 selftest ok (Schalter AUS = nichts, Uebernahme automatisch, BR24-Notfall 1x an Mesh 1 Kanal 0, NINA nicht doppelt, PTY 30 nie, Rueckgabe nur per Knopf, nur lokal)"


try:
    if _lz_mgr is None or _lz_mesh is None or _lz_dbm is None or not hasattr(_lz_mesh, "auto_send") or not hasattr(_lz_mgr, "takeover_auto"):
        raise RuntimeError("Module Teil 2 fehlen (%s)" % (_LZ.get("err") or "mesh_router/sdr_manager alt"))
    _lz_dbm.migrate_t2(_LZ_PATH)
    _T2D["selftest"] = _t2d_selftest()
    _T2D["ok"] = True
    for _t2d_rule, _t2d_ep, _t2d_fn, _t2d_m in (("/api/t2/status", "t2_status", _t2d_api, "GET"), ("/api/t2/stick2", "t2_stick2", _t2d_stick2_post, "POST"),
                                                 ("/api/t2/autosend", "t2_autosend", _t2d_autosend_post, "POST")):
        if _t2d_ep not in app.view_functions:
            app.add_url_rule(_t2d_rule, endpoint=_t2d_ep, view_func=_t2d_fn, methods=[_t2d_m])
    if not any(getattr(f, "__name__", "") == "_t2d_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_t2d_after)
    _t2d_live_wrap()
    if __name__ == "__main__" and not _T2D["started"]:
        _t2d_thr.Thread(target=_t2d_loop, name="teil2", daemon=True).start()
        _T2D["started"] = True
    print("teil2 aktiv: %s; Auto-Versand Mesh 1 %s; Stick 2 %s" % (_T2D["selftest"], "AN" if _lz_mesh.auto_state(_SDR_BASE)["on"] else "AUS",
                                                                   "ALARM 5C" if _lz_mgr.takeover_load(_SDR_BASE)["on"] else "Hobby"), flush=True)
except Exception as _t2d_e:
    _T2D.update(ok=False, err=repr(_t2d_e)[:200])
    fetch_nina = _t2d_orig_fetch_nina
    print("teil2 FEHLER (Teil 2 aus, alter Stand aktiv):", repr(_t2d_e)[:300], flush=True)
# ===== /teil2 =====
T2DASH_EOF
EXPECT_PS="990cc08fd5e75ba47fec9a1ec3d829264fa876df63b359ab2d3b9fb655ae2cac"
cat > "$W/patch-t2-sdr.py" << 'T2PS_EOF'
"""sdrTeil2: Block in prepper_sdr.py direkt nach /rdsNotfall einsetzen oder ersetzen + Selbsttest-Aufruf (idempotent).
Aufruf: patch-t2-sdr.py QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== sdrTeil2:", "# ===== /sdrTeil2 =====\n"
ANCHOR = "# ===== /rdsNotfall =====\n"
ST0 = "        selftest_rdsnotfall()\n"
ST1 = "        selftest_teil2()\n"
NEED = ("# ===== rdsNotfall:", "# ===== dabGain:", "# ===== dabFix:", "# ===== lageDB:", "# ===== sdrDual:", "class Planner", "class StateBC",
        "    def lage_apply(self):", "    def bc_queue(self):", "    def want(self, mode, now):", "    def stick2_info(self):", "    def loop(self):",
        "StateBC.on_dab = _dg_on_dab", "Planner.sub_done = _dg_sub_done", "def dual_roles(s1, s2, have2):", "def write_json(path, obj):", "\nif __name__ == \"__main__\":\n")
bad = [n.strip()[:40] for n in NEED if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if s.count(ST0) != 1:
    bad.append("selftest_rdsnotfall() x%d" % s.count(ST0))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("sdrTeil2-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
rest = s
if A in s and Z in s:
    rest = s.replace(s[s.index(A):s.index(Z) + len(Z)], "")
for k in ("Planner.lage_apply = ", "Planner.bc_queue = ", "Planner.act_queue = ", "Planner.want = _t2", "Planner.stick2_info = ", "Planner.loop = ", "StateBC.on_dab = _t2"):
    if k in rest:
        bad.append("%s schon anderswo ersetzt" % k.strip())
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: sdrTeil2-Block steht nicht direkt nach /rdsNotfall"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
if ST1 not in s2:
    s2 = s2.replace(ST0, ST0 + ST1, 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
T2PS_EOF
EXPECT_PD="42367b584312b382413cea54af27b11639d1f0a38008802bebeba0fb36df4648"
cat > "$W/patch-t2-dash.py" << 'T2PD_EOF'
"""teil2: Block in dashboard.py direkt nach /rdsNotfall einsetzen oder ersetzen (idempotent).
Aufruf: patch-t2-dash.py QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== teil2:", "# ===== /teil2 =====\n"
ANCHOR = "# ===== /rdsNotfall =====\n"
MAIN = "\nif __name__ == \"__main__\":\n"
NEED = ("# ===== rdsNotfall:", "# ===== lageDB:", "# ===== lageGeo:", "# ===== lageMesh1:", "# ===== br24Warn2:", "def send_meshtastic(text, channel=0):",
        "def _lz_sync(min_s, ctx=None):", "def _lz_ctx():", "_lm1_log = []", "def fetch_nina():", "def _sdr_load(name, default):", "def maybe_mesh_nina(nina_data):", MAIN)
bad = [n.strip()[:40] for n in NEED if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("teil2-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
if not bad and (s.index(ANCHOR) > s.rindex(MAIN) or s.index("# ===== lageDB:") > s.index(ANCHOR)):
    bad.append("Reihenfolge lageDB < /rdsNotfall < __main__ stimmt nicht")
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: teil2-Block steht nicht direkt nach /rdsNotfall"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
T2PD_EOF
EXPECT_GUARD="59ab93758fe72fee70963efd76db68e7f38da9053f501124e08e1a5e75969c9b"
cat > "$W/guard_t2.py" << 'T2GUARD_EOF'
"""Teil 2 AST-Guard. Aufruf: guard_t2.py SDR_ALT SDR_NEU DASH_ALT DASH_NEU MODDIR_ALT MODDIR_NEU -> 0 ok, 1 Verstoss.
prepper_sdr.py/dashboard.py: nur je ein Block neu (+ Aufruf selftest_teil2), sonst nichts geaendert, keine neuen Module-Importe, kein shell=True.
Einziger Sendeweg: mesh_router._tx() ruft send_fn genau 1x; das Dashboard uebergibt send_meshtastic genau 1x (an auto_send) und ruft selbst keine
Sendefunktion. Keine Sockets/Server/Prozesse; Netz nur 1x requests.get (NINA-Details warnung.bund.de) im Dashboard-Block."""
import ast
import os
import sys

SEND = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "send_nina_to_bayern", "sendText", "sendData", "send_fn", "_tx")
SOCK = ("socket", "create_connection", "bind", "listen", "serve_forever", "HTTPServer", "make_server", "TCPInterface", "SerialInterface", "urlopen",
        "system", "Popen", "check_output", "check_call", "call", "execv", "spawn", "fork", "killpg", "post", "put", "start_new_thread", "Timer", "unlink", "rmtree")
NETMOD = {"requests", "urllib", "http", "socket", "subprocess", "meshtastic", "serial", "asyncio", "socketserver"}


def info(src):
    t = ast.parse(src)
    imp, calls, shell, attrs, names = set(), [], 0, [], []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False):
            shell += 1
        if isinstance(n, ast.Call):
            f = n.func
            calls.append(f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
            if isinstance(f, ast.Attribute):
                attrs.append(((f.value.id if isinstance(f.value, ast.Name) else "?"), f.attr))
        if isinstance(n, ast.Name):
            names.append(n.id)
    return imp, calls, shell, attrs, names


def top_imports(src):
    return {(getattr(n, "module", None) or a.name).split(".")[0] for n in ast.parse(src).body if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names}


def cut(s, A, Z):
    if A not in s:
        return ""
    a = s.index(A)
    return s[a:s.index(Z, a) + len(Z) + 1]


rd = lambda f: open(f, encoding="utf-8").read()
s0, s1, d0, d1 = (rd(x) for x in sys.argv[1:5])
m0, m1 = sys.argv[5:7]
err = []
for lab, o, n, A, Z, extra, okimp in (("prepper_sdr", s0, s1, "# ===== sdrTeil2:", "# ===== /sdrTeil2 =====", "        selftest_teil2()\n", {"tempfile", "shutil"}),
                                      ("dashboard", d0, d1, "# ===== teil2:", "# ===== /teil2 =====", None, {"threading", "time", "re", "tempfile", "os", "flask", "ipaddress"})):
    if n.count(A) != 1 or n.count(Z) != 1:
        err.append("%s: Teil-2-Marker nicht genau 1x" % lab); continue
    blk, old = cut(n, A, Z), cut(o, A, Z)
    r0, r1 = (o.replace(old, "") if old else o), n.replace(blk, "")
    if extra:
        r0, r1 = r0.replace(extra, ""), r1.replace(extra, "")
    if r0 != r1:
        err.append("%s: ausserhalb des Teil-2-Blocks geaendert" % lab)
    bi, _, bs, _, _ = info(o)
    ni, _, ns, _, _ = info(n)
    if ni - bi - okimp:
        err.append("%s: neue Importe %s" % (lab, ni - bi - okimp))
    if ns != bs:
        err.append("%s: shell=True geaendert" % lab)
    ki, kc, ks, ka, kn = info(blk)
    if ks:
        err.append("%s: Block mit shell=" % lab)
    if ki - okimp:
        err.append("%s: Block importiert %s" % (lab, ki - okimp))
    for nm in SEND + SOCK:
        if nm in kc:
            err.append("%s: Block ruft %s" % (lab, nm))
    net = [x for x in ka if x[0] in NETMOD]
    if lab == "prepper_sdr":
        if net or "Thread" in kc or "requests" in kn or "send_meshtastic" in kn:
            err.append("prepper_sdr: Block mit Netz/Faden/Sendeweg %s" % net)
        low = blk.lower()
        for w in ("mesh", "socket", "requests", "urllib", "popen", "subprocess", "open("):
            if w in low:
                err.append("prepper_sdr: Block enthaelt %s" % w)
    else:
        if net != [("requests", "get")]:
            err.append("dashboard: Netzaufrufe im Block %s (erlaubt genau 1x requests.get)" % net)
        if kn.count("send_meshtastic") != 1:
            err.append("dashboard: send_meshtastic %dx im Block (erlaubt genau 1x als Sendeweg fuer auto_send)" % kn.count("send_meshtastic"))
        if kc.count("Thread") != 1 or kc.count("add_url_rule") != 1 or kc.count("after_request") != 1:
            err.append("dashboard: Faden/Routen/after_request nicht genau je 1x")
        if "requests.post" in blk or "5001" in blk or "5002" in blk:
            err.append("dashboard: direkter Bridge-Zugriff im Block")
        st = [a for a in ka if a[1] == "auto_send"]
        if len(st) != 1:
            err.append("dashboard: auto_send nicht genau 1x aufgerufen")
# Module
for name in ("database.py", "sdr_manager.py", "mesh_router.py"):
    o, n = rd(os.path.join(m0, name)), rd(os.path.join(m1, name))
    A = "\n\n# ---------------------------------------------------------------- Teil 2"
    if n.count(A) != 1:
        err.append("%s: Teil-2-Abschnitt nicht genau 1x" % name); continue
    a, b = n.index(A), n.index('\n\nif __name__ == "__main__":')

    def strip(x):
        if A not in x:
            return x
        return (x[:x.index(A)] + x[x.index('\n\nif __name__ == "__main__":'):]).replace("\n    print(selftest_t2())", "")
    r1, r0 = strip(n), strip(o)
    if name == "mesh_router.py":   # Kopf-Doku + Importe json/os/time duerfen sich aendern
        r0 = r0[r0.index("try:\n    import database"):]
        r1 = r1[r1.index("try:\n    import database"):]
    if r0 != r1:
        err.append("%s: Teil-1-Code geaendert" % name)
    ni, nc, ns, na, nn = info(n)
    sec = n[a:b]
    si, sc, ss, sa, sn = info(sec)
    if ns or ss:
        err.append("%s: shell=" % name)
    if (top_imports(n) | si) & NETMOD:
        err.append("%s: Netzmodul importiert %s" % (name, (top_imports(n) | si) & NETMOD))
    for nm in SOCK + ("Thread", "Popen", "run_server"):
        if nm in sc:
            err.append("%s: Teil 2 ruft %s" % (name, nm))
    if name == "mesh_router.py":
        tree = ast.parse(n)
        fn_calls, tx_calls = [], []
        for f in [x for x in tree.body if isinstance(x, ast.FunctionDef)]:
            for c in ast.walk(f):
                if isinstance(c, ast.Call) and isinstance(c.func, ast.Name):
                    if c.func.id == "send_fn":
                        fn_calls.append(f.name)
                    if c.func.id == "_tx":
                        tx_calls.append(f.name)
        if fn_calls != ["_tx"] or tx_calls != ["auto_send"]:
            err.append("mesh_router: Sendestellen %s / _tx-Aufrufe %s (erlaubt: send_fn nur in _tx, _tx nur in auto_send)" % (fn_calls, tx_calls))
        if top_imports(n) - {"hashlib", "json", "os", "re", "time", "database"}:
            err.append("mesh_router: Importe %s" % top_imports(n))
        if "channel=AUTO_CHANNEL" not in sec or "AUTO_CHANNEL = 0" not in sec:
            err.append("mesh_router: Kanal nicht fest Mesh 1 (0)")
    else:
        for nm in SEND:
            if nm in sc or nm in sn:
                err.append("%s: Sendeweg %s" % (name, nm))
        if si - {"gpiozero", "tempfile", "database"}:
            err.append("%s: Teil 2 importiert %s" % (name, si))
        if top_imports(n) != top_imports(o):
            err.append("%s: Modul-Importe geaendert" % name)
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard Teil 2: prepper_sdr.py/dashboard.py je 1 Block (+ Selbsttest-Aufruf), Teil-1-Code der Module unveraendert, kein shell=True, keine Sockets/Server/Prozesse; "
      "einziger Sendeweg mesh_router._tx -> send_fn (Mesh 1, Kanal 0), im Dashboard genau 1x send_meshtastic an auto_send; Netz nur 1x requests.get (NINA-Details)")
T2GUARD_EOF
EXPECT_SHOW="ff605638703874a80dff6bfe3edbeee69ae09090a7de8fa018cea13081bfd158"
cat > "$W/show_t2.py" << 'T2SHOW_EOF'
"""Teil 2 Anzeige (nur lesen). show_t2.py status|check|roles DATEI(/api/t2/status als JSON)"""
import json
import sys
import time


def fmt(t):
    try:
        return time.strftime("%d.%m. %H:%M:%S", time.localtime(int(t))) if t else "-"
    except Exception:
        return "-"


mode, f = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(f, encoding="utf-8"))
except Exception as e:
    print("  /api/t2/status nicht lesbar:", str(e)[:80])
    raise SystemExit(1)
if not isinstance(d, dict):
    raise SystemExit(1)
if mode == "check":
    ok = d.get("ok") is True and isinstance(d.get("takeover"), dict) and isinstance(d.get("asa"), dict) and isinstance((d.get("autosend") or {}).get("on"), bool) \
        and isinstance(d.get("roles"), dict) and isinstance(d.get("tick"), dict)
    raise SystemExit(0 if ok else 1)
r = d.get("roles") or {}
if mode == "roles":
    s1, s2 = r.get("s1") or {}, r.get("s2") or {}
    dual = isinstance(d.get("dual"), dict) and bool((d.get("dual") or {}).get("on", True))
    ok = d.get("sdr_t2") is True and (s1.get("mode") == "11D fest" or s1.get("role") == "single") and (s2.get("mode") or not dual or s1.get("role") == "single")
    raise SystemExit(0 if ok else 1)
to, a, au = d.get("takeover") or {}, d.get("asa") or {}, d.get("autosend") or {}
for k in ("s1", "s2"):
    x = r.get(k) or {}
    print("  Stick %s%s: %s (seit %s)" % (k[1], (" SN " + str(x.get("sn"))) if x.get("sn") else "", x.get("mode") or "noch kein Stand", fmt(x.get("since"))))
print("  Stick-2-Uebernahme: %s" % (("AN seit %s (%s: %s)" % (fmt(to.get("since")), to.get("src"), str(to.get("why") or "")[:70])) if to.get("on") else "AUS (Hobby-Betrieb)"))
print("  ASA-Dienst: %s%s" % (a.get("status") or "-", (" - " + str(a.get("text"))[:90]) if a.get("text") else ""))
for ch, x in sorted((d.get("fig") or {}).items()):
    ti = ", ".join("%02d/%02d%s" % (int(y.get("main") or 0), int(y.get("sub") or 0), (" " + str(y.get("mast"))[:30]) if y.get("mast") else "") for y in x.get("tii") or [])
    print("  FIG %s: %s ECC %s LTO %s TII %s (%s)" % (ch, x.get("ens") or "-", x.get("ecc") or "-", x.get("lto"), ti or "-", fmt(x.get("t"))))
if not d.get("fig"):
    print("  FIG 0/9 / TII: noch keine Daten (kommt mit der naechsten DAB-Pruefung 11D)")
print("  Auto-Versand Mesh 1: %s (letzte Stunde %s/%s, gleicher Inhalt erst nach %s h)" % ("AN" if au.get("on") else "AUS", au.get("hour_n"), au.get("limit_h"), au.get("same_h")))
real = [x for x in d.get("alarms") or [] if x.get("real")]
print("  Echte Alarme jetzt: %s" % ("; ".join("%s: %s" % (x.get("src"), str(x.get("text"))[:60]) for x in real[:3]) if real else "keine"))
print("  alarm_identifier: %s; GPIO: %s" % (d.get("alarm_identifier"), (d.get("gpio") or {}).get("why") or (d.get("gpio") or {}).get("state") or "aus"))
db = d.get("dablin") or {}
print("  dablin: %s; Journaline: %s" % (db.get("why") or db.get("exe") or "-", d.get("journaline")))
tk = d.get("tick") or {}
print("  Pruefung alle %s s: %s Durchlaeufe, zuletzt %s%s" % (tk.get("every_s"), tk.get("n"), fmt(tk.get("t")), (", Fehler: " + str(tk.get("err"))[:80]) if tk.get("err") else ""))
T2SHOW_EOF
EXPECT_MDB="47a3b6c30a38783bf073f13a8bca2eb690dd9bcc72796a44561a29ac9d2ea2fb"
cat > "$W/new/database.py" << 'T2MDB_EOF'
"""database.py - SQLite-Lagezentrum (lagezentrum.db) ZUSAETZLICH zu den JSON-Dateien.

Kaeswasser Lage Monitor, Teil 1. Nur Ablage/Abfrage, keine Netzwerkzugriffe, keine Sendewege.
- WAL-Modus, busy_timeout, eine Verbindung je Aufruf (thread-sicher ohne geteilte Verbindung)
- Schema-Migration idempotent (CREATE IF NOT EXISTS + fehlende Spalten per ALTER TABLE ADD COLUMN)
- jede Funktion faengt Fehler ab und liefert einen sicheren Standardwert (Seiten duerfen nie abstuerzen)

Tabellen:
  events     Lage-Ereignisse (NINA/MoWaS, DAB, ASA, BR24) - ext_id eindeutig (Upsert)
  mesh_log   md5-Hash gesehener Mesh-Texte je Kanal (nur Dublettenpruefung, kein Senden)
  telemetry  DAB-Empfangswerte je Stick/Kanal; 'ber' = FIC-CRC-Fehlerrate als Ersatz fuer die
             Bitfehlerrate (welle-cli liefert keine BER): numcrcerrors / (Messdauer_s * 125 FIB/s, DAB Mode I).
             kind 'dab' = echte Messung, kind 'hb' = Lebenszeichen aus sdr_status.json (Watchdog).
"""
import os
import sqlite3
import time

DB_PATH = "/home/fmg/prepper-dashboard/lagezentrum.db"
SCHEMA_VERSION = 1
TIMEOUT_S = 10.0

KEEP_MESH_S = 24 * 3600
KEEP_TELEMETRY_S = 48 * 3600

_TABLES = {
    "events": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("source", "TEXT NOT NULL"),          # NINA | DAB | ASA | BR24
        ("type", "TEXT"),                      # z. B. Alert/Update/Cancel, dls, ann, warn
        ("severity", "TEXT"),                  # info | warn | alarm | probe | unknown
        ("headline", "TEXT"),
        ("text", "TEXT"),
        ("lat", "REAL"),
        ("lon", "REAL"),
        ("geojson", "TEXT"),
        ("sent_at", "INTEGER"),
        ("created", "INTEGER"),
        ("updated", "INTEGER"),
        ("expires", "INTEGER"),
        ("is_test", "INTEGER DEFAULT 0"),      # eigene TEST-Knopf-Meldungen -> zaehlen nie
        ("ext_id", "TEXT"),
    ],
    "mesh_log": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("hash", "TEXT NOT NULL"),
        ("channel", "TEXT"),
        ("created", "INTEGER"),
    ],
    "telemetry": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("ts", "INTEGER NOT NULL"),
        ("kind", "TEXT DEFAULT 'dab'"),        # dab | hb
        ("serial", "TEXT"),
        ("channel", "TEXT"),                   # 11D | 5C (hb: Rolle/aktiv)
        ("snr", "REAL"),
        ("ber", "REAL"),                       # FIC-CRC-Fehlerrate (siehe oben)
        ("fic_err", "INTEGER"),
        ("secs", "REAL"),
        ("ensemble", "TEXT"),
        ("mast", "TEXT"),                      # Ensemble + Kanal, z. B. "Bayern · 11D"
        ("rssi", "REAL"),                      # nur wenn verfuegbar (welle-cli: nein)
        ("src_t", "INTEGER"),                  # Zeitstempel der Quelle (Dedup)
    ],
}
_INDEXES = (
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_events_ext ON events(ext_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_upd ON events(updated)",
    "CREATE INDEX IF NOT EXISTS ix_events_exp ON events(expires)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_hash ON mesh_log(hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_created ON mesh_log(created)",
    "CREATE INDEX IF NOT EXISTS ix_tel_ts ON telemetry(ts)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_tel_src ON telemetry(kind, serial, channel, src_t)",
)
_migrated = set()
_last_err = [None]


def _log(*a):
    _last_err[0] = " ".join(str(x) for x in a)[:200]
    print("lagezentrum.db:", *a, flush=True)


def last_error():
    return _last_err[0]


def connect(path=None):
    """Neue Verbindung (je Aufruf). WAL, busy_timeout, Row-Zugriff per Name."""
    con = sqlite3.connect(path or DB_PATH, timeout=TIMEOUT_S)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    return con


def migrate(path=None):
    """Schema anlegen/ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        con = connect(path)
        try:
            with con:
                con.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
                for tb, cols in _TABLES.items():
                    con.execute("CREATE TABLE IF NOT EXISTS %s (%s)" % (tb, ", ".join("%s %s" % c for c in cols)))
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ.replace("PRIMARY KEY AUTOINCREMENT", "").replace("NOT NULL", "")))
                for sql in _INDEXES:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_version', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (str(SCHEMA_VERSION),))
        finally:
            con.close()
        _migrated.add(path)
        return True
    except Exception as e:
        _log("Migration:", e)
        return False


def _ensure(path):
    path = path or DB_PATH
    if path not in _migrated:
        migrate(path)
    return path


def upsert_event(ev, path=None):
    """Ereignis anlegen oder (gleiche ext_id) aktualisieren. -> True/False"""
    path = _ensure(path)
    try:
        now = int(time.time())
        row = {k: ev.get(k) for k in ("source", "type", "severity", "headline", "text", "lat", "lon", "geojson", "sent_at", "created", "updated", "expires", "is_test", "ext_id")}
        if not row["ext_id"] or not row["source"]:
            return False
        row["created"] = int(row["created"] or now)
        row["updated"] = int(row["updated"] or row["created"])
        row["is_test"] = 1 if row["is_test"] else 0
        for k in ("headline", "text"):
            if row[k] is not None:
                row[k] = str(row[k])[:2000]
        con = connect(path)
        try:
            with con:
                con.execute(
                    "INSERT INTO events(source,type,severity,headline,text,lat,lon,geojson,sent_at,created,updated,expires,is_test,ext_id) "
                    "VALUES(:source,:type,:severity,:headline,:text,:lat,:lon,:geojson,:sent_at,:created,:updated,:expires,:is_test,:ext_id) "
                    "ON CONFLICT(ext_id) DO UPDATE SET updated=MAX(COALESCE(events.updated,0), COALESCE(excluded.updated,0)), "
                    "expires=CASE WHEN excluded.expires IS NULL THEN events.expires ELSE MAX(COALESCE(events.expires,0), excluded.expires) END, "
                    "severity=COALESCE(excluded.severity, events.severity), text=COALESCE(excluded.text, events.text), "
                    "headline=COALESCE(excluded.headline, events.headline), type=COALESCE(excluded.type, events.type), "
                    "lat=COALESCE(excluded.lat, events.lat), lon=COALESCE(excluded.lon, events.lon), geojson=COALESCE(excluded.geojson, events.geojson)", row)
        finally:
            con.close()
        return True
    except Exception as e:
        _log("Ereignis:", e)
        return False


def insert_telemetry(t, path=None):
    """Telemetrie-Zeile (gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    path = _ensure(path)
    try:
        row = {k: t.get(k) for k in ("ts", "kind", "serial", "channel", "snr", "ber", "fic_err", "secs", "ensemble", "mast", "rssi", "src_t")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        row["kind"] = row["kind"] or "dab"
        row["src_t"] = int(row["src_t"] if isinstance(row["src_t"], (int, float)) else row["ts"])
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,snr,ber,fic_err,secs,ensemble,mast,rssi,src_t) "
                                  "VALUES(:ts,:kind,:serial,:channel,:snr,:ber,:fic_err,:secs,:ensemble,:mast,:rssi,:src_t)", row)
                return cur.rowcount > 0
        finally:
            con.close()
    except Exception as e:
        _log("Telemetrie:", e)
        return False


def mesh_seen(hash_hex, channel=None, path=None, now=None):
    """Hash merken; True wenn er schon bekannt war (Dublette). Fehler -> None (Aufrufer entscheidet)."""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_log(hash, channel, created) VALUES(?,?,?)", (str(hash_hex), channel, int(now or time.time())))
                return cur.rowcount == 0
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_known(hash_hex, path=None):
    """Nur pruefen, nicht merken. -> True/False/None(Fehler)"""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return con.execute("SELECT 1 FROM mesh_log WHERE hash=?", (str(hash_hex),)).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def _rows(sql, args=(), path=None):
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return [dict(r) for r in con.execute(sql, args).fetchall()]
        finally:
            con.close()
    except Exception as e:
        _log("Abfrage:", e)
        return []


def recent_events(n=10, path=None, include_test=False):
    return _rows("SELECT * FROM events %s ORDER BY COALESCE(updated, created) DESC, id DESC LIMIT ?" % ("" if include_test else "WHERE COALESCE(is_test,0)=0"),
                 (int(n),), path)


def active_events(now=None, path=None, since_s=None):
    now = int(now or time.time())
    q = "SELECT * FROM events WHERE COALESCE(is_test,0)=0 AND (expires IS NULL OR expires >= ?)"
    a = [now]
    if since_s:
        q += " AND COALESCE(updated, created) >= ?"
        a.append(now - int(since_s))
    return _rows(q + " ORDER BY COALESCE(updated, created) DESC LIMIT 500", tuple(a), path)


def newest_telemetry(kind=None, path=None):
    r = _rows("SELECT * FROM telemetry %s ORDER BY ts DESC, id DESC LIMIT 1" % ("WHERE kind=?" if kind else ""), (kind,) if kind else (), path)
    return r[0] if r else None


def telemetry_latest_per_channel(path=None):
    return _rows("SELECT t.* FROM telemetry t JOIN (SELECT channel, MAX(ts) m FROM telemetry WHERE kind='dab' GROUP BY channel) x "
                 "ON t.channel=x.channel AND t.ts=x.m WHERE t.kind='dab' ORDER BY t.ts DESC", (), path)


def cleanup(now=None, path=None):
    """Abgelaufene Ereignisse, mesh_log > 24 h, Telemetrie > 48 h loeschen. -> {tabelle: anzahl}"""
    path = _ensure(path)
    now = int(now or time.time())
    out = {}
    try:
        con = connect(path)
        try:
            with con:
                out["events"] = con.execute("DELETE FROM events WHERE expires IS NOT NULL AND expires < ?", (now,)).rowcount
                out["mesh_log"] = con.execute("DELETE FROM mesh_log WHERE created < ?", (now - KEEP_MESH_S,)).rowcount
                out["telemetry"] = con.execute("DELETE FROM telemetry WHERE ts < ?", (now - KEEP_TELEMETRY_S,)).rowcount
        finally:
            con.close()
    except Exception as e:
        _log("Aufraeumen:", e)
    return out


def counts(path=None):
    out = {}
    for tb in _TABLES:
        r = _rows("SELECT COUNT(*) n FROM %s" % tb, (), path)
        out[tb] = r[0]["n"] if r else None
    return out


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "t.db")
    assert migrate(p) and migrate(p)  # idempotent
    con = connect(p)
    assert con.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    con.close()
    now = int(time.time())
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a", "expires": now + 60, "created": now - 10}, p)
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a2", "expires": now + 120, "updated": now}, p)
    ev = recent_events(5, p)
    assert len(ev) == 1 and ev[0]["headline"] == "a2" and ev[0]["expires"] == now + 120 and ev[0]["created"] == now - 10, ev
    assert upsert_event({"source": "BR24", "ext_id": "old", "expires": now - 5}, p)
    assert upsert_event({"source": "BR24", "ext_id": "t", "is_test": True}, p) and len(recent_events(9, p)) == 2
    assert insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert not insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert insert_telemetry({"ts": now - 3 * 86400, "serial": "1", "channel": "5C", "src_t": now - 3 * 86400}, p)
    assert newest_telemetry(path=p)["snr"] == 12.5 and telemetry_latest_per_channel(p)[0]["channel"] == "11D"
    assert mesh_seen("h", "0", p, now - 2 * 86400) is False and mesh_seen("h", "0", p) is True and mesh_known("zz", p) is False
    c = cleanup(now, p)
    assert c == {"events": 1, "mesh_log": 1, "telemetry": 1}, c
    assert counts(p) == {"events": 2, "mesh_log": 0, "telemetry": 1}, counts(p)
    assert recent_events(5, "/proc/nicht/schreibbar/x.db") == []  # Fehler -> leer, kein Absturz
    return "database selftest ok"


# ---------------------------------------------------------------- Teil 2 (SDR-Steuerung, Parser, Resilienz)
# Zusaetzlich, idempotent (migrate_t2): telemetry.tii/ecc/lto/ens_id (kind 'fig' = FIG 0/9 + TII + Ensemble aus welle-cli mux.json),
# mesh_log.src/text/ok/kind (Protokoll des Auto-Versands), Tabelle mesh_auto (eine Meldung je Alarm, 30 Tage) und
# Tabelle asa_rx (Empfangszeitpunkte des ASA-Dienstes auf 5C, 14 Tage). Bestehende Tabellen/Funktionen bleiben unveraendert.
KEEP_MESH_AUTO_S = 30 * 86400
KEEP_ASA_RX_S = 14 * 86400
_T2_ADD = {
    "telemetry": [("tii", "TEXT"), ("ecc", "TEXT"), ("lto", "REAL"), ("ens_id", "TEXT")],
    "mesh_log": [("src", "TEXT"), ("text", "TEXT"), ("ok", "INTEGER"), ("kind", "TEXT")],
}
_T2_SQL = (
    "CREATE TABLE IF NOT EXISTS mesh_auto (id INTEGER PRIMARY KEY AUTOINCREMENT, akey TEXT NOT NULL, hash TEXT, src TEXT, text TEXT, "
    "created INTEGER, last_try INTEGER, tries INTEGER DEFAULT 0, ok INTEGER)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_auto_key ON mesh_auto(akey)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_auto_try ON mesh_auto(last_try)",
    "CREATE TABLE IF NOT EXISTS asa_rx (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, channel TEXT, serial TEXT)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_asa_rx ON asa_rx(channel, ts)",
)
AUTO_RETRY_S = 600            # fehlgeschlagener Auto-Versand fruehestens nach 10 min erneut
AUTO_TRIES_MAX = 3            # hoechstens 3 Versuche je Alarm
_migrated_t2 = set()


def migrate_t2(path=None):
    """Teil-2-Schema ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
        if not migrate(path):
            return False
        con = connect(path)
        try:
            with con:
                for tb, cols in _T2_ADD.items():
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ))
                for sql in _T2_SQL:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_t2', '1') ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        finally:
            con.close()
        _migrated_t2.add(path)
        return True
    except Exception as e:
        _log("Migration Teil 2:", e)
        return False


def _ensure_t2(path):
    path = path or DB_PATH
    if path not in _migrated_t2:
        migrate_t2(path)
    return path


def _exec(sql, args, path, what):
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            with con:
                return con.execute(sql, args).rowcount
        finally:
            con.close()
    except Exception as e:
        _log(what, e)
        return None


def _rows_t2(sql, args, path):
    _ensure_t2(path)
    return _rows(sql, args, path)


def insert_fig(t, path=None):
    """FIG 0/9 + TII + Ensemble einer DAB-Pruefung (kind 'fig'; gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    try:
        row = {k: t.get(k) for k in ("ts", "serial", "channel", "ensemble", "mast", "tii", "ecc", "lto", "ens_id")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        return (_exec("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,ensemble,mast,src_t,tii,ecc,lto,ens_id) "
                      "VALUES(:ts,'fig',:serial,:channel,:ensemble,:mast,:ts,:tii,:ecc,:lto,:ens_id)", row, path, "Telemetrie fig:") or 0) > 0
    except Exception as e:
        _log("Telemetrie fig:", e)
        return False


def newest_fig(channel, path=None):
    r = _rows_t2("SELECT * FROM telemetry WHERE kind='fig' AND channel=? ORDER BY ts DESC, id DESC LIMIT 1", (str(channel),), path)
    return r[0] if r else None


def asa_rx_add(ts, channel="5C", serial=None, path=None):
    """Empfangszeitpunkt ASA-Dienst merken. -> True wenn neu"""
    if not isinstance(ts, (int, float)):
        return False
    return (_exec("INSERT OR IGNORE INTO asa_rx(ts, channel, serial) VALUES(?,?,?)", (int(ts), str(channel), serial), path, "asa_rx:") or 0) > 0


def asa_rx_list(since, channel="5C", path=None):
    return [r["ts"] for r in _rows_t2("SELECT ts FROM asa_rx WHERE channel=? AND ts>=? ORDER BY ts", (str(channel), int(since)), path)]


def mesh_hash_since(hash_hex, since, path=None, ok_only=True):
    """Gleicher Inhalt (Hash) seit 'since' gesendet? ok_only: fehlgeschlagene Versuche zaehlen nicht. -> True/False/None(Fehler)"""
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            q = "SELECT 1 FROM mesh_log WHERE hash=? AND created>=?" + (" AND COALESCE(ok, 1)=1" if ok_only else "")
            return con.execute(q, (str(hash_hex), int(since))).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_log_put(hash_hex, channel, now, src=None, text=None, ok=None, kind="auto", path=None):
    """Versand protokollieren (gleicher Hash -> Zeit/Ergebnis aktualisiert). -> True/False"""
    n = _exec("INSERT INTO mesh_log(hash, channel, created, src, text, ok, kind) VALUES(?,?,?,?,?,?,?) "
              "ON CONFLICT(hash) DO UPDATE SET created=excluded.created, channel=excluded.channel, src=excluded.src, text=excluded.text, ok=excluded.ok, kind=excluded.kind",
              (str(hash_hex), None if channel is None else str(channel), int(now), src, (str(text)[:300] if text is not None else None),
               None if ok is None else (1 if ok else 0), kind), path, "mesh_log:")
    return bool(n)


def mesh_auto_get(akey, path=None):
    r = _rows_t2("SELECT * FROM mesh_auto WHERE akey=?", (str(akey),), path)
    return r[0] if r else None


def mesh_auto_reserve(akey, hash_hex, src, text, now, path=None):
    """Versuch fuer einen Alarm anmelden. -> 'neu' | 'wieder' (frueherer Versuch fehlgeschlagen) | None (schon gesendet/zu frueh/zu oft/Fehler)"""
    now = int(now)
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_auto(akey, hash, src, text, created, last_try, tries, ok) VALUES(?,?,?,?,?,?,1,NULL)",
                                  (str(akey), str(hash_hex), src, str(text)[:300], now, now))
                if cur.rowcount > 0:
                    return "neu"
                r = con.execute("SELECT ok, tries, last_try FROM mesh_auto WHERE akey=?", (str(akey),)).fetchone()
                if r is None or r["ok"] != 0 or int(r["tries"] or 0) >= AUTO_TRIES_MAX or now - int(r["last_try"] or 0) < AUTO_RETRY_S:
                    return None
                con.execute("UPDATE mesh_auto SET tries=tries+1, last_try=?, ok=NULL, hash=?, text=? WHERE akey=?", (now, str(hash_hex), str(text)[:300], str(akey)))
                return "wieder"
        finally:
            con.close()
    except Exception as e:
        _log("mesh_auto:", e)
        return None


def mesh_auto_done(akey, ok, path=None):
    return bool(_exec("UPDATE mesh_auto SET ok=? WHERE akey=?", (1 if ok else 0, str(akey)), path, "mesh_auto:"))


def mesh_auto_count(since, path=None):
    """Auto-Versuche seit 'since' (Ratenbegrenzung). Fehler -> None"""
    r = _rows_t2("SELECT COUNT(*) n FROM mesh_auto WHERE last_try>=?", (int(since),), path)
    return r[0]["n"] if r else None


def mesh_auto_recent(n=10, path=None):
    return _rows_t2("SELECT akey, src, text, created, last_try, tries, ok FROM mesh_auto ORDER BY last_try DESC, id DESC LIMIT ?", (int(n),), path)


def cleanup_t2(now=None, path=None):
    now = int(now or time.time())
    return {"mesh_auto": _exec("DELETE FROM mesh_auto WHERE COALESCE(last_try, created, 0) < ?", (now - KEEP_MESH_AUTO_S,), path, "Aufraeumen:"),
            "asa_rx": _exec("DELETE FROM asa_rx WHERE ts < ?", (now - KEEP_ASA_RX_S,), path, "Aufraeumen:")}


def selftest_t2():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "t2.db")
    assert migrate_t2(p) and migrate_t2(p)
    con = connect(p)
    cols = {r[1] for r in con.execute("PRAGMA table_info(telemetry)")} | {r[1] for r in con.execute("PRAGMA table_info(mesh_log)")}
    con.close()
    assert {"tii", "ecc", "lto", "ens_id", "src", "text", "ok", "kind"} <= cols, cols
    now = int(time.time())
    assert insert_fig({"ts": now, "serial": "19348831", "channel": "11D", "ensemble": "Bayern", "mast": "BR Bayern MainID 07 / SubID 02", "tii": "[]", "ecc": "0xE0", "lto": 2.0}, p)
    assert not insert_fig({"ts": now, "serial": "19348831", "channel": "11D"}, p) and newest_fig("11D", p)["ecc"] == "0xE0"
    assert insert_telemetry({"ts": now, "serial": "19348831", "channel": "11D", "snr": 9.0, "src_t": now}, p)   # alte Telemetrie unberuehrt
    assert asa_rx_add(now - 100, path=p) and not asa_rx_add(now - 100, path=p) and asa_rx_add(now, path=p) and asa_rx_list(now - 200, path=p) == [now - 100, now]
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now, p) == "neu" and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 1, p) is None
    assert mesh_auto_done("A1", False, p) and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 60, p) is None          # zu frueh
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + AUTO_RETRY_S, p) == "wieder" and mesh_auto_done("A1", True, p)
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + 9 * AUTO_RETRY_S, p) is None and mesh_auto_get("A1", p)["tries"] == 2   # einmal ok = nie wieder
    assert mesh_auto_count(now, p) == 1 and mesh_auto_count(now + 10 * AUTO_RETRY_S, p) == 0
    assert mesh_hash_since("h1", now - 10, p) is False and mesh_log_put("h1", "auto0", now, "ASA", "x", True, path=p) and mesh_hash_since("h1", now - 10, p) is True
    assert mesh_log_put("h1", "auto0", now + 5, "ASA", "x", False, path=p) and mesh_hash_since("h1", now + 1, p) is False and mesh_known("h1", p) is True
    assert mesh_hash_since("h1", now + 1, p, ok_only=False) is True
    c = cleanup_t2(now + KEEP_ASA_RX_S + 1, p)
    assert c["asa_rx"] == 2 and c["mesh_auto"] == 0, c
    assert asa_rx_list(0, path="/proc/nicht/schreibbar/x.db") == [] and mesh_auto_reserve("x", "h", "s", "t", now, "/proc/nicht/schreibbar/x.db") is None
    return "database selftest Teil 2 ok"


if __name__ == "__main__":
    print(selftest())
    print(selftest_t2())
T2MDB_EOF
EXPECT_MSM="855225dc03abb5350f6ec8ec2797466d8a2e53ac17f95590a0436c4eb4ecddc1"
cat > "$W/new/sdr_manager.py" << 'T2MSM_EOF'
"""sdr_manager.py - Lagezentrum-Logik fuer SDR/DAB/NINA (Kaeswasser Lage Monitor, Teil 1).

Liest nur vorhandene Zustandsdateien/Daten (sdr_status.json, broadcast_state.json, sdr_dabhist.json,
NINA-Liste und BR24-Zustand aus dem Dashboard) und fuellt lagezentrum.db ZUSAETZLICH. Kein Netzwerk,
keine Sendewege, keine Prozesse. Jede Funktion faengt Fehler ab.

Status /api/sdr/live:
  SDR_OFFLINE  neueste Telemetrie aelter als WATCHDOG_S (15 s). Weil prepper-sdr DAB nur im Wechsel
               (11D/5C, je Pruefblock) misst und sdr_status.json nur bei Aenderung bzw. alle 60 s schreibt,
               gibt es keinen echten 15-s-Takt. Darum schreibt jede Synchronisierung (hoechstens alle
               HB_MIN_S = 10 s) eine Lebenszeichen-Zeile (kind 'hb'), aber NUR wenn sdr_status.json
               hoechstens STATUS_MAX_AGE_S (90 s) alt ist und der prepper-sdr-Prozess (pid) lebt.
  ECHTALARM    aktive ASA-DE-Warnung (DAB 5C), deren Text NICHT ausdruecklich Probe/Test sagt
  PROBEALARM   nur wenn ASA- oder MoWaS/NINA-Text ausdruecklich Probe/Test/Warntag sagt
  OK           sonst. Eigene TEST-Knopf-Meldungen ("TEST ... keine echte Warnung") zaehlen nie.
"""
import hashlib
import json
import os
import re
import time

try:
    import database as db
except Exception:
    db = None

WATCHDOG_S = 15
HB_MIN_S = 10
STATUS_MAX_AGE_S = 90
ASA_ACTIVE_S = 2 * 3600        # ASA-Warnung gilt so lange nach letztem Empfang als aktiv
PROBE_RE = re.compile(r"\b(probe\w*|test\w*|warntag|uebungs?\w*|übung\w*)\b", re.I)
OWN_TEST_RE = re.compile(r"^\s*TEST\b.*keine echte Warnung", re.I | re.S)

# Oeffentlich bekannte DAB+-Senderstandorte fuer 11D (BR "Bayern", 222,064 MHz) und 5C (Bundesmux "DR Deutschland",
# 178,352 MHz) im Empfangsgebiet Kalchreuth/Nuernberg (Heimatposition aus sdr_status.json "home" 49,557/11,133).
# Quellen: BR, Frequenzen und Empfang (PDF) https://www.br.de/unternehmen/inhalt/technik/download-frequenzen-pdf-102~attachment.pdf ;
# BR, Deutschlandweite Sendernetze https://www.br.de/unternehmen/inhalt/technik/digitalradio-dab-sendernetz-bundesweit-100.html ;
# https://www.digitalradio-in-deutschland.de/bayern/ und /belegung-deutschland/ (ERP) ;
# https://mobile.sender-tabelle.de/result.php?inputLand=D&inputRegion=bay&mode=d (ERP, TII).
# Koordinaten: Wikipedia-Artikel der Senderstandorte, gerundet (Genauigkeit etwa 1 km) - nur zur Kartenanzeige.
TRANSMITTERS = [
    {"id": "nbg-schweinau", "name": "Nürnberg (Fernmeldeturm Schweinau)", "lat": 49.4283, "lon": 11.0403, "channels": ["11D", "5C"], "erp_kw": {"11D": 10, "5C": 10}},
    {"id": "dillberg", "name": "Dillberg (bei Neumarkt i.d.OPf.)", "lat": 49.3239, "lon": 11.3831, "channels": ["11D", "5C"], "erp_kw": {"11D": 10, "5C": 10}},
    {"id": "ochsenkopf", "name": "Ochsenkopf (Fichtelgebirge)", "lat": 50.0306, "lon": 11.8083, "channels": ["11D", "5C"], "erp_kw": {"11D": 10}},
    {"id": "bamberg-geisberg", "name": "Bamberg (Geisberg)", "lat": 49.8660, "lon": 10.8440, "channels": ["11D", "5C"], "erp_kw": {"5C": 10}},
    {"id": "buettelberg", "name": "Büttelberg (Frankenhöhe)", "lat": 49.4070, "lon": 10.4030, "channels": ["11D", "5C"], "erp_kw": {"5C": 10}},
    {"id": "hesselberg", "name": "Hesselberg (Wassertrüdingen)", "lat": 49.0692, "lon": 10.5303, "channels": ["11D"], "erp_kw": {"11D": 10}},
]

# NINA-Abfragegebiete aus dashboard.fetch_nina() -> ungefaehre Mittelpunkte (Kreisstadt/Kreismitte), Radius grob.
NINA_AREAS = {
    "Nürnberg": (49.4521, 11.0767, 9000),
    "Fürth Stadt": (49.4771, 10.9887, 5000),
    "Erlangen Stadt": (49.5897, 11.0040, 6000),
    "LK Erlangen-Höchstadt": (49.6500, 10.8700, 15000),
    "LK Nürnberger Land": (49.5100, 11.4000, 18000),
    "LK Fürth": (49.4200, 10.8500, 13000),
    "LK Forchheim": (49.7200, 11.1000, 18000),
}


def _load(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if v is not None else default
    except Exception:
        return default


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _pid_alive(pid):
    try:
        return isinstance(pid, int) and pid > 1 and os.path.exists("/proc/%d" % pid)
    except Exception:
        return False


def _iso_ts(s):
    """NINA-Zeit '2026-10-17T08:00:00+02:00' -> Unix-Sekunden oder None."""
    try:
        from datetime import datetime
        return int(datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp())
    except Exception:
        return None


def is_own_test(text):
    return bool(OWN_TEST_RE.search(str(text or "")))


def is_probe(text):
    return bool(PROBE_RE.search(str(text or "")))


# ---------------------------------------------------------------- Telemetrie
def telemetry_rows(base, now=None):
    """Echte DAB-Messwerte aus broadcast_state.json (dab[ch].demod, von prepper-sdr guard lageDB) + Lebenszeichen."""
    now = int(now or time.time())
    out = []
    try:
        bs = _load(os.path.join(base, "broadcast_state.json"), {}) or {}
        for ch, d in ((bs.get("dab") or {}) if isinstance(bs.get("dab"), dict) else {}).items():
            dm = d.get("demod") if isinstance(d, dict) else None
            if not isinstance(dm, dict) or not isinstance(dm.get("t"), (int, float)):
                continue
            ens = str(d.get("ensemble") or "").strip()[:40] or None
            out.append({"ts": int(dm["t"]), "kind": "dab", "serial": str(dm.get("sn") or "?"), "channel": str(ch), "snr": _num(dm.get("snr")),
                        "ber": _num(dm.get("fic_rate")), "fic_err": dm.get("fic_err") if isinstance(dm.get("fic_err"), int) else None,
                        "secs": _num(dm.get("secs")), "ensemble": ens, "mast": ("%s · %s" % (ens, ch)) if ens else str(ch),
                        "rssi": _num(dm.get("rssi")), "src_t": int(dm["t"])})
    except Exception as e:
        print("sdr_manager Telemetrie:", e, flush=True)
    return out


def heartbeat_row(status, now=None):
    """Lebenszeichen aus sdr_status.json, nur wenn frisch und Prozess lebt. -> Zeile oder None"""
    now = int(now or time.time())
    st = status if isinstance(status, dict) else {}
    t = st.get("t")
    if not isinstance(t, (int, float)) or now - t > STATUS_MAX_AGE_S or t - now > 60:
        return None
    if "pid" in st and not _pid_alive(st.get("pid")):
        return None
    return {"ts": now, "kind": "hb", "serial": str(st.get("sn") or st.get("serial") or "?"), "channel": str(st.get("active") or "")[:20] or None,
            "src_t": now}


# ---------------------------------------------------------------- Ereignisse
def events_from_dabhist(dh, now=None):
    """sdr_dabhist.json -> Ereignisse: nur BR24 (11D), ASA DE (5C), Ansagen und als Warnung markierte Texte."""
    now = int(now or time.time())
    out = []
    ev = (dh or {}).get("ev") if isinstance(dh, dict) else None
    for x in (ev or [])[-400:]:
        try:
            if not isinstance(x, dict) or not isinstance(x.get("t"), (int, float)):
                continue
            ch, src, text = str(x.get("ch") or ""), str(x.get("src") or ""), str(x.get("text") or "")
            asa = ch == "5C" and src.upper().startswith("ASA")
            br = ch == "11D" and src.upper().startswith("BR24")
            if not (asa or br or x.get("k") == "ann" or x.get("warn")):
                continue
            source = "ASA" if asa else ("BR24" if br else "DAB")
            warn = bool(x.get("warn")) or x.get("k") == "ann"
            last = int(x.get("last") or x["t"])
            sev = ("probe" if is_probe(text) else "warn") if warn else "info"
            out.append({"source": source, "type": x.get("k") or "dls", "severity": sev, "headline": ("%s: %s" % (src, text))[:160], "text": text,
                        "sent_at": int(x["t"]), "created": int(x["t"]), "updated": last, "expires": last + (48 if warn else 24) * 3600,
                        "is_test": is_own_test(text), "ext_id": "DH:%s:%s:%d" % (ch, hashlib.md5(("%s|%s" % (src, text)).encode("utf-8")).hexdigest()[:12], int(x["t"]))})
        except Exception as e:
            print("sdr_manager DAB-Verlauf:", e, flush=True)
    return out


def events_from_nina(nina, now=None):
    """NINA-Liste aus data_store['nina']['value'] -> Ereignisse (MoWaS/NINA), Ort = ungefaehrer Gebietsmittelpunkt."""
    now = int(now or time.time())
    out = []
    for w in (nina or [])[:50] if isinstance(nina, list) else []:
        try:
            if not isinstance(w, dict) or not w.get("title"):
                continue
            title, city = str(w.get("title")), str(w.get("city") or "")
            wid = str(w.get("id") or hashlib.md5(title.encode("utf-8")).hexdigest()[:16])
            sent = _iso_ts(w.get("sent"))
            exp = _iso_ts(w.get("expires"))
            mt = str(w.get("msgType") or "") or None
            sev = "probe" if is_probe(title) else ("info" if mt == "Cancel" else "warn")
            lat, lon, rad = NINA_AREAS.get(city, (None, None, None))
            geo = json.dumps({"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
                              "properties": {"radius_m": rad, "approx": True, "area": city}}, ensure_ascii=False) if lat is not None else None
            out.append({"source": "NINA", "type": mt, "severity": sev, "headline": title[:160], "text": ("%s (%s)" % (title, city)) if city else title,
                        "lat": lat, "lon": lon, "geojson": geo, "sent_at": sent, "created": sent or now, "updated": now,
                        "expires": exp if exp else now + 6 * 3600, "is_test": is_own_test(title), "ext_id": "NINA:%s:%s" % (wid, city)})
        except Exception as e:
            print("sdr_manager NINA:", e, flush=True)
    return out


def events_from_br24(br, now=None):
    """Aktueller BR24-Zustand (/api/br24): nur bei rot ein Ereignis (gleicher Text = gleiche ext_id)."""
    now = int(now or time.time())
    try:
        if not isinstance(br, dict) or br.get("state") != "rot":
            return []
        why = br.get("why") if isinstance(br.get("why"), dict) else {}
        text = str(why.get("text") or br.get("text") or "").strip()
        if not text:
            return []
        t = int(why.get("t") or br.get("last_rx") or now)
        src = "ASA" if str(why.get("src") or "").startswith("ASA") else "BR24"
        return [{"source": src, "type": "warn", "severity": "probe" if is_probe(text) else "warn", "headline": text[:160], "text": text,
                 "sent_at": t, "created": t, "updated": now, "expires": now + 2 * 3600, "is_test": is_own_test(text),
                 "ext_id": "%s:%s" % (src, hashlib.md5(text.encode("utf-8")).hexdigest()[:16])}]
    except Exception as e:
        print("sdr_manager BR24:", e, flush=True)
        return []


# ---------------------------------------------------------------- Synchronisierung
class Sync:
    """Leichte, rate-begrenzte Synchronisierung im Dashboard-Prozess (kein Faden, kein Netz)."""

    def __init__(self, base, path=None):
        self.base = base
        self.path = path or os.path.join(base, "lagezentrum.db")
        self.last = 0
        self.last_hb = 0
        self.last_dh = (None, 0)
        self.last_clean = 0
        self.last_nina_sig = None
        self.stat = {"n": 0, "err": None, "t": None, "added": {}}

    def tick(self, ctx=None, now=None, min_s=5, force=False):
        now = int(now or time.time())
        if db is None:
            self.stat["err"] = "database.py fehlt"
            return self.stat
        if not force and now - self.last < min_s:
            return self.stat
        self.last = now
        ctx = ctx or {}
        add = {"telemetry": 0, "events": 0, "hb": 0}
        try:
            for r in telemetry_rows(self.base, now):
                add["telemetry"] += 1 if db.insert_telemetry(r, self.path) else 0
            st = _load(os.path.join(self.base, "sdr_status.json"), {}) or {}
            if now - self.last_hb >= HB_MIN_S:
                hb = heartbeat_row(st, now)
                if hb and db.insert_telemetry(hb, self.path):
                    add["hb"] += 1
                    self.last_hb = now
            fdh = os.path.join(self.base, "sdr_dabhist.json")
            try:
                mt = os.path.getmtime(fdh)
            except Exception:
                mt = None
            if mt and (mt != self.last_dh[0] or now - self.last_dh[1] > 600):
                self.last_dh = (mt, now)
                for e in events_from_dabhist(_load(fdh, {}), now):
                    add["events"] += 1 if db.upsert_event(e, self.path) else 0
            nina = ctx.get("nina")
            sig = json.dumps(nina, sort_keys=True, default=str)[:4000] if nina is not None else None
            if nina is not None and (sig != self.last_nina_sig or now % 600 < min_s):
                self.last_nina_sig = sig
                for e in events_from_nina(nina, now):
                    add["events"] += 1 if db.upsert_event(e, self.path) else 0
            for e in events_from_br24(ctx.get("br24"), now):
                add["events"] += 1 if db.upsert_event(e, self.path) else 0
            if now - self.last_clean >= 600:
                self.last_clean = now
                self.stat["cleanup"] = db.cleanup(now, self.path)
            self.stat.update(n=self.stat["n"] + 1, err=None, t=now, added=add)
        except Exception as e:
            self.stat["err"] = str(e)[:160]
            print("sdr_manager Sync:", e, flush=True)
        return self.stat


# ---------------------------------------------------------------- API-Daten
def classify(active, br=None, now=None):
    """-> (status, grund). active = aktive Ereignisse aus der DB (ohne eigene Tests)."""
    now = int(now or time.time())
    real, probe = [], []
    for e in active or []:
        if e.get("is_test") or is_own_test(e.get("text")):
            continue
        src, sev = e.get("source"), e.get("severity")
        recent = now - int(e.get("updated") or e.get("created") or 0) <= ASA_ACTIVE_S
        if src == "ASA" and sev in ("warn", "alarm", "probe") and recent:
            (probe if (sev == "probe" or is_probe(e.get("text"))) else real).append(e)
        elif src == "NINA" and (sev == "probe" or is_probe(e.get("text") or e.get("headline"))):
            probe.append(e)
    try:
        a = (br or {}).get("asa_row") if isinstance(br, dict) else None
        tx = str(a.get("l1") or "") if isinstance(a, dict) else ""
        if tx and not is_own_test(tx):
            if a.get("state") == "rot":
                (probe if is_probe(tx) else real).append({"source": "ASA", "headline": tx})
            elif "Probewarnung/Test" in tx:
                probe.append({"source": "ASA", "headline": tx})
    except Exception:
        pass
    if real:
        return "ECHTALARM", (real[0].get("headline") or "ASA-Warnung")[:160]
    if probe:
        return "PROBEALARM", (probe[0].get("headline") or "Probe")[:160]
    return "OK", None


def live(base, path=None, br=None, extra=None, now=None):
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    out = {"status": "SDR_OFFLINE", "ber": None, "active_mast": None, "history": [], "sdr1_role": None, "sdr2_role": None, "sdr2_status": None}
    try:
        st = _load(os.path.join(base, "sdr_status.json"), {}) or {}
        du = st.get("dual") if isinstance(st.get("dual"), dict) else {}
        s2 = st.get("stick2") if isinstance(st.get("stick2"), dict) else {}
        out["sdr1_role"] = du.get("role1") or st.get("role")
        out["sdr2_role"] = du.get("role2") or s2.get("role")
        if not s2:
            out["sdr2_status"] = "nicht eingerichtet"
        elif not s2.get("present", True):
            out["sdr2_status"] = "fehlt"
        else:
            h2 = (st.get("stick_health2") or {}).get("lvl") if isinstance(st.get("stick_health2"), dict) else None
            out["sdr2_status"] = "%s · %s" % ((st.get("s2") or {}).get("active") or "?", h2 or "?") if isinstance(st.get("s2"), dict) else (h2 or "?")
        if db is None:
            out["error"] = "database.py fehlt"
            return out
        nt = db.newest_telemetry(path=path)
        age = (now - int(nt["ts"])) if nt else None
        out["watchdog"] = {"newest_ts": nt["ts"] if nt else None, "newest_kind": nt["kind"] if nt else None, "age_s": age, "limit_s": WATCHDOG_S,
                           "status_age_s": (now - int(st["t"])) if isinstance(st.get("t"), (int, float)) else None,
                           "note": "Lebenszeichen je Abruf (alle %d s) solange sdr_status.json <= %d s alt und prepper-sdr laeuft; DAB-Messwerte nur je Pruefblock" % (HB_MIN_S, STATUS_MAX_AGE_S)}
        dab = db.telemetry_latest_per_channel(path)
        if dab:
            n = dab[0]
            out["ber"] = n.get("ber")
            out["active_mast"] = n.get("mast")
            out["telemetry"] = [{k: x.get(k) for k in ("ts", "channel", "serial", "snr", "ber", "fic_err", "secs", "mast", "rssi")} for x in dab]
        out["history"] = [{k: e.get(k) for k in ("source", "type", "severity", "headline", "created", "updated", "expires", "lat", "lon")}
                          for e in db.recent_events(10, path)]
        if age is None or age > WATCHDOG_S:
            out["status"] = "SDR_OFFLINE"
        else:
            out["status"], why = classify(db.active_events(now, path), br, now)
            if why:
                out["reason"] = why
        if isinstance(extra, dict):
            out.update({k: v for k, v in extra.items() if k not in out})
    except Exception as e:
        out["error"] = str(e)[:160]
        print("sdr_manager live:", e, flush=True)
    return out


def map_geojson(base, path=None, now=None):
    """Leaflet-taugliche FeatureCollection: Senderstandorte (kind transmitter) + Gefahrenzonen aktiver Ereignisse (kind hazard)."""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    feats = []
    for t in TRANSMITTERS:
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [t["lon"], t["lat"]]},
                      "properties": {"kind": "transmitter", "id": t["id"], "name": t["name"], "channels": t["channels"], "erp_kw": t["erp_kw"], "approx": True}})
    try:
        st = _load(os.path.join(base, "sdr_status.json"), {}) or {}
        h = st.get("home")
        if isinstance(h, list) and len(h) == 2 and all(isinstance(x, (int, float)) for x in h):
            feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [h[1], h[0]]}, "properties": {"kind": "home", "name": "Empfänger"}})
        for e in (db.active_events(now, path) if db is not None else []):
            g = None
            try:
                g = json.loads(e["geojson"]) if e.get("geojson") else None
            except Exception:
                g = None
            props = {"kind": "hazard", "source": e.get("source"), "severity": e.get("severity"), "headline": e.get("headline"), "updated": e.get("updated"), "expires": e.get("expires")}
            if isinstance(g, dict) and g.get("type") == "Feature" and isinstance(g.get("geometry"), dict):
                g = dict(g, properties=dict(g.get("properties") or {}, **props))
                feats.append(g)
            elif isinstance(e.get("lat"), (int, float)) and isinstance(e.get("lon"), (int, float)):
                feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [e["lon"], e["lat"]]}, "properties": props})
    except Exception as ex:
        print("sdr_manager Karte:", ex, flush=True)
    return {"type": "FeatureCollection", "features": feats}


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    now = int(time.time())
    with open(os.path.join(d, "sdr_status.json"), "w") as f:
        json.dump({"t": now - 5, "pid": os.getpid(), "sn": "19348831", "active": "rds:0", "home": [49.557, 11.133],
                   "dual": {"role1": "bc", "role2": "rot"}, "stick2": {"present": True, "role": "rot"}, "s2": {"active": "idle"}, "stick_health2": {"lvl": "ok"}}, f)
    with open(os.path.join(d, "broadcast_state.json"), "w") as f:
        json.dump({"dab": {"11D": {"ensemble": "Bayern", "demod": {"t": now - 100, "snr": 14.2, "fic_err": 3, "secs": 50, "fic_rate": 0.00048, "sn": "19348831"}},
                           "5C": {"ensemble": "DR Deutschland"}}}, f)
    with open(os.path.join(d, "sdr_dabhist.json"), "w") as f:
        json.dump({"ev": [{"id": 1, "t": now - 50, "last": now - 20, "n": 3, "ch": "5C", "src": "ASA DE", "text": "Probealarm: Test der Warnsysteme", "warn": True, "k": "dls"},
                          {"id": 2, "t": now - 40, "last": now - 40, "n": 1, "ch": "11D", "src": "Bayern 3", "text": "Musik", "warn": False, "k": "dls"},
                          {"id": 3, "t": now - 30, "last": now - 30, "n": 1, "ch": "5C", "src": "ASA DE", "text": "TEST ASA DE (DAB 5C) · keine echte Warnung · x", "warn": True, "k": "dls"}]}, f)
    s = Sync(d)
    st = s.tick({"nina": [{"city": "Nürnberg", "title": "Warntag: Probewarnung", "id": "mow.1", "msgType": "Alert", "sent": "2026-10-17T08:00:00+02:00"}],
                "br24": {"state": "gruen"}}, now, force=True)
    assert st["err"] is None and st["added"]["telemetry"] == 1 and st["added"]["hb"] == 1 and st["added"]["events"] == 3, st
    L = live(d, now=now)
    assert L["status"] == "PROBEALARM" and abs(L["ber"] - 0.00048) < 1e-9 and L["active_mast"] == "Bayern · 11D", L
    assert L["sdr1_role"] == "bc" and L["sdr2_role"] == "rot" and L["sdr2_status"] == "idle · ok" and len(L["history"]) == 2, L
    db.upsert_event({"source": "ASA", "ext_id": "real", "severity": "warn", "headline": "Gefahr: Fenster schließen", "text": "Gefahr", "updated": now, "expires": now + 3600}, s.path)
    assert live(d, now=now)["status"] == "ECHTALARM"
    assert live(d, now=now + WATCHDOG_S + 1)["status"] == "SDR_OFFLINE"
    s.tick({}, now + 20)
    assert live(d, now=now + 20)["status"] == "ECHTALARM"  # Lebenszeichen erneuert
    m = map_geojson(d, now=now)
    kinds = [f["properties"]["kind"] for f in m["features"]]
    assert kinds.count("transmitter") == len(TRANSMITTERS) and "home" in kinds and "hazard" in kinds, kinds
    hz = [f for f in m["features"] if f["properties"]["kind"] == "hazard" and f["properties"]["source"] == "NINA"]
    assert hz and hz[0]["properties"]["radius_m"] == 9000
    assert classify([{"source": "ASA", "severity": "warn", "text": "TEST BR24-Warnkette · keine echte Warnung", "updated": now}], None, now)[0] == "OK"
    assert classify([], {"asa_row": {"state": "rot", "l1": "ASA DE · DAB 5C ⚠ Warnung: „Gefahr“"}}, now)[0] == "ECHTALARM"
    assert classify([], {"asa_row": {"state": "grau", "l1": "ASA DE · DAB 5C · Probewarnung/Test: „x“"}}, now)[0] == "PROBEALARM"
    b = events_from_br24({"state": "rot", "why": {"text": "Unwetter", "t": now, "src": "BR24 11D"}}, now)
    assert b and b[0]["source"] == "BR24" and b[0]["severity"] == "warn"
    assert events_from_br24({"state": "grau", "test": True, "why": {"text": "Test"}}, now) == []
    assert heartbeat_row({"t": now - 200}, now) is None and heartbeat_row({"t": now, "pid": 999999999}, now) is None
    assert live("/nicht/da", path=os.path.join(d, "x.db"), now=now)["status"] == "SDR_OFFLINE"
    return "sdr_manager selftest ok"


# ---------------------------------------------------------------- Teil 2 (SDR-Steuerung, Parser, Resilienz)
# Stick-2-Uebernahme (sdr_takeover.json, schreibt nur das Dashboard, prepper-sdr liest), Alarm-Erkennung fuer Uebernahme und
# Auto-Versand, ASA-Dienst-Ueberwachung (gelerntes Soll-Intervall), FIG 0/9/TII/ASA-Empfang aus broadcast_state.json t2 in
# lagezentrum.db, GPIO-Vorbereitung (Standard AUS, ohne Import). Kein Netz, keine Sendewege, keine Prozesse.
TAKEOVER_FILE = "sdr_takeover.json"
TAKEOVER_SEEN_S = 14 * 86400   # bekannte Alarm-Schluessel so lange merken (nach Rueckgabe kein erneutes Kapern durch denselben Alarm)
TAKEOVER_SEEN_MAX = 300
NINA_SEVERE = ("Severe", "Extreme")
NINA_TEST_STATUS = ("Exercise", "Test", "Draft", "System")
ASA_MIN_N = 20                 # erst ab 20 gelernten Abstaenden kann ASA_INTERRUPTED ausgeloest werden
ASA_FACTOR = 1.5
ASA_GAP_MAX_S = 1800           # groessere Luecken = keine durchgehende Ueberwachung -> nicht lernen
ASA_LEARN_S = 7 * 86400        # Median ueber die letzten 7 Tage
GPIO_PIN_KEY = "gpio_alarm_pin"
END_RE = re.compile(r"entwarn|aufheb|aufgehoben|keine warnung|all-clear", re.I)
_GPIO = {"dev": None, "pin": None, "state": None, "err": None}
_T2 = {"asa_max": 0, "clean": 0, "ev": [], "br_ep": {}}
BR_EP_GAP_S = 6 * 3600        # gleicher BR24/ASA-Text ohne 6 h Pause = derselbe Alarm (ein Schluessel, eine Meldung)


def _write_json(path, obj):
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def takeover_load(base):
    d = _load(os.path.join(base, TAKEOVER_FILE), {}) or {}
    d = d if isinstance(d, dict) else {}
    seen = d.get("seen") if isinstance(d.get("seen"), dict) else {}
    return {"on": d.get("on") is True, "since": d.get("since"), "src": d.get("src"), "why": d.get("why"), "by": d.get("by"),
            "off_t": d.get("off_t"), "off_by": d.get("off_by"), "seen": {str(k): v for k, v in seen.items() if isinstance(v, (int, float))},
            "hist": [x for x in (d.get("hist") or []) if isinstance(x, dict)][-20:] if isinstance(d.get("hist"), list) else []}


def _takeover_save(base, d, now):
    seen = {k: v for k, v in d["seen"].items() if now - v < TAKEOVER_SEEN_S}
    d["seen"] = dict(sorted(seen.items(), key=lambda kv: kv[1])[-TAKEOVER_SEEN_MAX:])
    d["hist"] = d["hist"][-20:]
    _write_json(os.path.join(base, TAKEOVER_FILE), d)
    return d


def takeover_set(base, on, src="manual", why="", by="dashboard", now=None):
    """Knopf im Dashboard: Stick 2 auf 5C (on) oder zurueck in den Hobby-Betrieb (off). Rueckgabe gibt es NUR hierueber."""
    now = int(now or time.time())
    d = takeover_load(base)
    if on:
        if not d["on"]:
            d.update(on=True, since=now, src=str(src)[:20], why=str(why)[:160], by=str(by)[:20])
    else:
        d.update(on=False, off_t=now, off_by=str(by)[:20])
    d["hist"].append({"t": now, "on": bool(on), "src": str(src)[:20], "why": str(why)[:120], "by": str(by)[:20]})
    return _takeover_save(base, d, now)


def takeover_auto(base, alarms, now=None):
    """Neue echte Alarme (Schluessel noch nie gesehen) kapern Stick 2. Nie automatische Rueckgabe. -> (Zustand, geaendert)"""
    now = int(now or time.time())
    d = takeover_load(base)
    new = [a for a in alarms or [] if isinstance(a, dict) and a.get("takeover") and a.get("real") and not a.get("test") and a.get("key")
           and ("%s:%s" % (a.get("src"), a["key"])) not in d["seen"]]
    if not new:
        return d, False
    for a in new:
        d["seen"]["%s:%s" % (a.get("src"), a["key"])] = now
    if not d["on"]:
        a = new[0]
        d.update(on=True, since=now, src=str(a.get("src"))[:20], why=str(a.get("text") or "")[:160], by="auto")
        d["hist"].append({"t": now, "on": True, "src": str(a.get("src"))[:20], "why": str(a.get("text") or "")[:120], "by": "auto"})
    return _takeover_save(base, d, now), True


def _core(t):
    return " ".join(str(t or "").replace("…", " ").split()).lower()


def _br_key(src, text, now, seen=None, ep=None):
    """Stabiler Schluessel je Alarm-Episode: gleicher Text, solange keine 6 h Pause (auch nach Dashboard-Neustart ueber seen)."""
    ep = _T2["br_ep"] if ep is None else ep
    h = hashlib.md5(("%s|%s" % (src, _core(text))).encode("utf-8")).hexdigest()[:12]
    e = ep.get(h)
    if not (e and 0 <= now - e[1] <= BR_EP_GAP_S):
        start = now
        for k, t in (seen or {}).items():
            if str(k).startswith("%s:%s@" % (src, h)) and 0 <= now - int(t or 0) <= BR_EP_GAP_S:
                try:
                    start = min(start, int(str(k).rsplit("@", 1)[1]))
                except Exception:
                    pass
        e = [start, now]
    e[1] = now
    ep[h] = e
    if len(ep) > 200:
        for k in sorted(ep, key=lambda k: ep[k][1])[:50]:
            ep.pop(k, None)
    return "%s@%d" % (h, e[0])


def alarms_from(nina=None, nina_detail=None, br=None, active=None, now=None, seen=None, ep=None):
    """Echte Alarme + Tests (Tests nur zur Anzeige). -> [{"src", "key", "text", "kind", "real", "test", "takeover"}]
    NINA: real nur bei Schweregrad Severe/Extreme und Status Actual (aus warnung.bund.de warnings/<id>.json), keine Entwarnung.
    BR24: Zustand rot aus /api/br24 (rdsNotfall: PTY 31, bestaetigte 9A, Warnwoerter, DAB-Alarmansage); PTY 30/Test nie.
    ASA:  aktive ASA-Ereignisse aus lagezentrum.db (Probe/Test nie)."""
    now = int(now or time.time())
    out, ids = [], set()
    det = nina_detail if isinstance(nina_detail, dict) else {}
    for w in (nina or [])[:50] if isinstance(nina, list) else []:
        try:
            if not isinstance(w, dict) or not w.get("title"):
                continue
            title, city = str(w["title"]), str(w.get("city") or "")
            wid = str(w.get("id") or hashlib.md5(title.encode("utf-8")).hexdigest()[:16])
            if wid in ids or END_RE.search(title) or str(w.get("msgType") or "") == "Cancel":
                continue
            ids.add(wid)
            x = det.get(wid) if isinstance(det.get(wid), dict) else {}
            test = is_probe(title) or is_own_test(title) or x.get("status") in NINA_TEST_STATUS
            real = (not test) and x.get("severity") in NINA_SEVERE and x.get("status") == "Actual" and x.get("msgType") != "Cancel"
            out.append({"src": "NINA", "key": wid, "text": ("%s: %s" % (city, title)) if city else title, "kind": "NINA %s" % (x.get("severity") or "?"),
                        "real": bool(real), "test": bool(test), "takeover": bool(real), "severity": x.get("severity"), "status": x.get("status")})
        except Exception as e:
            print("sdr_manager Alarm NINA:", e, flush=True)
    asa = []
    try:
        if isinstance(br, dict) and isinstance(br.get("why"), dict) and (br.get("state") == "rot" or br.get("test")):
            w = br["why"]
            text, kind, src = str(w.get("text") or "").strip(), str(w.get("kind") or ""), str(w.get("src") or "")
            test = bool(br.get("test")) or w.get("cls") == "test" or is_probe(text) or is_own_test(text) or "PTY 30" in kind
            s0 = "ASA" if src.upper().startswith("ASA") else "BR24"
            key = _br_key(s0, text, now, seen, ep)
            a = {"src": s0, "key": key, "text": text, "kind": "%s %s" % (src, kind),
                 "real": bool(text) and not test and br.get("state") == "rot", "test": test}
            a["takeover"] = a["real"]
            (asa if a["src"] == "ASA" else out).append(a)
    except Exception as e:
        print("sdr_manager Alarm BR24:", e, flush=True)
    for e in active or []:
        try:
            if e.get("source") != "ASA" or e.get("severity") not in ("warn", "alarm", "probe"):
                continue
            if now - int(e.get("updated") or e.get("created") or 0) > ASA_ACTIVE_S:
                continue
            text = str(e.get("text") or e.get("headline") or "").strip()
            test = e.get("severity") == "probe" or bool(e.get("is_test")) or is_probe(text) or is_own_test(text)
            asa.append({"src": "ASA", "key": str(e.get("ext_id")), "text": text, "kind": "ASA DE 5C", "real": bool(text) and not test, "test": test, "takeover": bool(text) and not test, "db": True})
        except Exception as ex:
            print("sdr_manager Alarm ASA:", ex, flush=True)
    keep = []
    for a in sorted(asa, key=lambda y: (-len(_core(y["text"])), 0 if y.get("db") else 1)):   # gleiche ASA-Meldung aus zwei Quellen nur einmal (laengster Text, sonst DB-Schluessel)
        c = _core(a["text"])
        if c and any(k["test"] == a["test"] and _core(k["text"]).startswith(c) for k in keep):
            continue
        a.pop("db", None)
        keep.append(a)
    return out + keep


def alarm_identifier(alarms):
    """2 = echter Alarm, 1 = nur Probe/Test, 0 = nichts."""
    al = [a for a in alarms or [] if isinstance(a, dict)]
    if any(a.get("real") and not a.get("test") for a in al):
        return 2
    return 1 if any(a.get("test") for a in al) else 0


def gpio_alarm(ident, cfg=None):
    """Vorbereitet: bei alarm_identifier == 2 BCM-Pin HIGH (sonst LOW). Standard AUS (sdr_config.json gpio_alarm_pin fehlt/null):
    dann kein Import, keine Pin-Aenderung."""
    pin = (cfg or {}).get(GPIO_PIN_KEY) if isinstance(cfg, dict) else None
    if isinstance(pin, bool) or not isinstance(pin, int) or not 2 <= pin <= 27:
        return {"on": False, "pin": None, "state": None, "why": "aus (sdr_config.json %s nicht gesetzt)" % GPIO_PIN_KEY}
    want = ident == 2
    try:
        if _GPIO["dev"] is None or _GPIO["pin"] != pin:
            from gpiozero import OutputDevice   # nur wenn eingeschaltet
            _GPIO.update(dev=OutputDevice(pin, active_high=True, initial_value=False), pin=pin, state=False)
        if _GPIO["state"] != want:
            (_GPIO["dev"].on if want else _GPIO["dev"].off)()
            _GPIO["state"] = want
        _GPIO["err"] = None
    except Exception as e:
        _GPIO["err"] = str(e)[:120]
    return {"on": True, "pin": pin, "state": "HIGH" if _GPIO["state"] else "LOW", "err": _GPIO["err"], "why": "BCM %d folgt alarm_identifier == 2" % pin}


def _median(v):
    v = sorted(v)
    n = len(v)
    return None if not n else (v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2.0)


def asa_monitor(base, path=None, now=None, to=None):
    """ASA-Dienst-Ueberwachung: Soll-Intervall = Median der Abstaende zwischen ASA-Empfaengen (letzte 7 Tage, nur durchgehende
    Ueberwachung). ASA_INTERRUPTED nur wenn 5C gerade ueberwacht wird, >= ASA_MIN_N Abstaende gelernt und kein Empfang > 1,5 x Soll."""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    out = {"status": "ASA_RUHT", "soll_s": None, "limit_s": None, "n": 0, "min_n": ASA_MIN_N, "last_rx": None, "monitoring": False, "since": None}
    try:
        to = to if isinstance(to, dict) else takeover_load(base)
        bs = _load(os.path.join(base, "broadcast_state.json"), {}) or {}
        t2 = bs.get("t2") if isinstance(bs.get("t2"), dict) else {}
        s2 = (t2.get("roles") or {}).get("s2") if isinstance(t2.get("roles"), dict) else None
        mon = bool(to.get("on")) and isinstance(s2, dict) and s2.get("alarm") is True
        rx = db.asa_rx_list(now - ASA_LEARN_S, path=path) if db is not None and hasattr(db, "asa_rx_list") else []
        gaps = [b - a for a, b in zip(rx, rx[1:]) if 0 < b - a <= ASA_GAP_MAX_S]
        soll = _median(gaps)
        out.update(n=len(gaps), soll_s=soll, limit_s=round(soll * ASA_FACTOR, 1) if soll else None, last_rx=rx[-1] if rx else None,
                   monitoring=mon, since=s2.get("since") if mon else None)
        if not mon:
            out["text"] = "5C wird nur im Alarmfall (Stick 2) empfangen - keine Ueberwachung"
        elif len(gaps) < ASA_MIN_N:
            out.update(status="ASA_LERNT", text="lernt Soll-Intervall (%d von %d Abstaenden)" % (len(gaps), ASA_MIN_N))
        else:
            ref = max(rx[-1] if rx else 0, int(out["since"] or 0))
            late = now - ref
            out["age_s"] = late
            if late > soll * ASA_FACTOR:
                out.update(status="ASA_INTERRUPTED", text="ASA-Dienst seit %d s nicht empfangen (Soll %d s, Grenze %d s)" % (late, soll, soll * ASA_FACTOR))
            else:
                out.update(status="ASA_OK", text="ASA-Dienst vor %d s empfangen (Soll %d s)" % (late, soll))
    except Exception as e:
        out["err"] = str(e)[:120]
        print("sdr_manager ASA-Ueberwachung:", e, flush=True)
    return out


def t2_sync(base, path=None, now=None):
    """broadcast_state.json t2 -> lagezentrum.db: Telemetrie kind 'fig' (FIG 0/9, TII, Ensemble), asa_rx, Ereignisse (TII-Wechsel,
    FIG 0/9, Label). Idempotent. -> Zaehler"""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    add = {"fig": 0, "asa": 0, "events": 0}
    if db is None or not hasattr(db, "migrate_t2"):
        return add
    try:
        db.migrate_t2(path)
        bs = _load(os.path.join(base, "broadcast_state.json"), {}) or {}
        t2 = bs.get("t2") if isinstance(bs.get("t2"), dict) else {}
        for ch, x in (t2.get("fig") or {}).items() if isinstance(t2.get("fig"), dict) else ():
            if not isinstance(x, dict) or not isinstance(x.get("t"), (int, float)):
                continue
            tii = [y for y in (x.get("tii") or []) if isinstance(y, dict)]
            add["fig"] += 1 if db.insert_fig({"ts": int(x["t"]), "serial": str(x.get("sn") or "?"), "channel": str(ch), "ensemble": x.get("ens"),
                                              "mast": tii[0].get("mast") if tii else ("%s · %s" % (x.get("ens"), ch) if x.get("ens") else str(ch)),
                                              "tii": json.dumps(tii[:8], ensure_ascii=False), "ecc": x.get("ecc"), "lto": _num(x.get("lto")),
                                              "ens_id": x.get("ens_id")}, path) else 0
        sn2 = ((t2.get("roles") or {}).get("s2") or {}).get("sn") if isinstance(t2.get("roles"), dict) else None
        rx = [int(t) for t in (t2.get("asa_rx") or []) if isinstance(t, (int, float)) and t > _T2["asa_max"]]
        for t in rx:
            add["asa"] += 1 if db.asa_rx_add(t, "5C", sn2, path) else 0
        if rx:
            _T2["asa_max"] = max(rx)
        for e in (t2.get("ev") or [])[-T2_EV_SYNC:] if isinstance(t2.get("ev"), list) else []:
            if isinstance(e, dict) and e.get("id") and isinstance(e.get("t"), (int, float)) and str(e["id"]) not in _T2["ev"]:
                _T2["ev"] = (_T2["ev"] + [str(e["id"])])[-200:]
                add["events"] += 1 if db.upsert_event({"source": "DAB", "type": str(e.get("k") or "fig"), "severity": "info", "headline": str(e.get("text") or "")[:160],
                                                       "text": e.get("text"), "created": int(e["t"]), "updated": int(e["t"]), "expires": int(e["t"]) + 24 * 3600,
                                                       "ext_id": str(e["id"])[:80]}, path) else 0
        if now - _T2["clean"] >= 600:
            _T2["clean"] = now
            db.cleanup_t2(now, path)
    except Exception as e:
        print("sdr_manager Teil 2 Abgleich:", e, flush=True)
    return add


T2_EV_SYNC = 30


def t2_status(base, path=None, now=None, alarms=None, autosend=None, gpio=None):
    """Daten fuer /api/t2/status (nur lesen)."""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    out = {"ok": True, "now": now}
    try:
        to = takeover_load(base)
        to.pop("seen", None)
        out["takeover"] = to
        bs = _load(os.path.join(base, "broadcast_state.json"), {}) or {}
        t2 = bs.get("t2") if isinstance(bs.get("t2"), dict) else {}
        out["sdr_t2"] = bool(t2.get("on"))
        out["roles"] = t2.get("roles") or {}
        out["masts"] = t2.get("masts") or {}
        out["dablin"] = t2.get("dablin") or {"exe": None, "why": "noch kein Stand von prepper-sdr"}
        out["journaline"] = t2.get("journaline") or "nicht verfuegbar"
        fig = {}
        for ch, x in (t2.get("fig") or {}).items() if isinstance(t2.get("fig"), dict) else ():
            if isinstance(x, dict):
                fig[ch] = {k: x.get(k) for k in ("t", "sn", "ens", "ens_id", "ecc", "lto", "n_svc", "tii_on")}
                fig[ch]["tii"] = [{k: y.get(k) for k in ("main", "sub", "km", "mast")} for y in (x.get("tii") or [])[:4] if isinstance(y, dict)]
        out["fig"] = fig
        out["events"] = [e for e in (t2.get("ev") or [])[-8:]][::-1] if isinstance(t2.get("ev"), list) else []
        out["asa"] = asa_monitor(base, path, now, to)
        out["alarms"] = [{k: a.get(k) for k in ("src", "text", "kind", "real", "test", "takeover")} for a in (alarms or [])][:10]
        out["alarm_identifier"] = alarm_identifier(alarms)
        if autosend is not None:
            out["autosend"] = autosend
        if gpio is not None:
            out["gpio"] = gpio
    except Exception as e:
        out.update(ok=False, error=str(e)[:160])
        print("sdr_manager Teil 2 Status:", e, flush=True)
    return out


def selftest_t2():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "lagezentrum.db")
    now = 1790000000
    assert takeover_load(d)["on"] is False
    ns = [{"city": "Nürnberg", "title": "Gefahrstoffaustritt - Fenster schließen", "id": "mow.1", "msgType": "Alert"},
          {"city": "Fürth Stadt", "title": "Gefahrstoffaustritt - Fenster schließen", "id": "mow.1", "msgType": "Alert"},
          {"city": "Nürnberg", "title": "Hochwasser Information", "id": "mow.2", "msgType": "Alert"},
          {"city": "Nürnberg", "title": "Probealarm Sirenen", "id": "mow.3", "msgType": "Alert"},
          {"city": "Nürnberg", "title": "Entwarnung Gefahrstoff", "id": "mow.4", "msgType": "Update"},
          {"city": "Nürnberg", "title": "Übung Katastrophenschutz", "id": "mow.5", "msgType": "Alert"},
          {"city": "Nürnberg", "title": "Unwetter", "id": "mow.6", "msgType": "Alert"}]
    det = {"mow.1": {"severity": "Severe", "status": "Actual"}, "mow.2": {"severity": "Minor", "status": "Actual"}, "mow.3": {"severity": "Severe", "status": "Actual"},
           "mow.5": {"severity": "Extreme", "status": "Exercise"}}
    al = alarms_from(ns, det, None, [], now)
    by = {a["key"]: a for a in al}
    assert set(by) == {"mow.1", "mow.2", "mow.3", "mow.5", "mow.6"} and by["mow.1"]["real"] and by["mow.1"]["takeover"], by
    assert not by["mow.2"]["real"] and by["mow.3"]["test"] and not by["mow.3"]["real"] and by["mow.5"]["test"] and not by["mow.6"]["real"]   # Minor/Probe/Uebung/ohne Detail
    br_rot = {"state": "rot", "why": {"t": now - 30, "src": "BR24 UKW", "kind": "RDS PTY 31 Alarm (dauerhaft)", "text": "Programmart Alarm", "cls": "rot"}}
    br_t30 = {"state": "grau", "test": True, "why": {"t": now - 30, "src": "BR24 UKW", "kind": "RDS PTY 30 Alarmtest", "text": "PTY 30 Alarmtest", "cls": "test"}}
    a1 = [a for a in alarms_from(None, None, br_rot, [], now) if a["src"] == "BR24"]
    a2 = [a for a in alarms_from(None, None, br_t30, [], now) if a["src"] == "BR24"]
    assert a1 and a1[0]["real"] and a1[0]["takeover"] and a2 and a2[0]["test"] and not a2[0]["real"], (a1, a2)
    ep = {}
    k1 = alarms_from(None, None, br_rot, [], now, ep=ep)[0]["key"]
    br_rot2 = {"state": "rot", "why": dict(br_rot["why"], t=now + 40)}
    assert alarms_from(None, None, br_rot2, [], now + 60, ep=ep)[0]["key"] == k1                               # gleicher Alarm, neuer Zeitstempel -> gleicher Schluessel
    assert alarms_from(None, None, br_rot2, [], now + 60, ep={}, seen={"BR24:" + k1: now})[0]["key"] == k1    # auch nach Neustart
    assert alarms_from(None, None, br_rot2, [], now + 60 + BR_EP_GAP_S + 1, ep=ep)[0]["key"] != k1             # nach 6 h Pause neuer Alarm
    assert alarms_from(None, None, {"state": "gruen", "text": "BR24 empfangen"}, [], now) == []
    act = [{"source": "ASA", "severity": "warn", "text": "Gefahr: Fenster und Türen schließen und Radio einschalten", "headline": "ASA DE: Gefahr", "updated": now - 60, "ext_id": "DH:5C:a:1"},
           {"source": "ASA", "severity": "probe", "text": "Probewarnung", "updated": now - 60, "ext_id": "DH:5C:b:1"},
           {"source": "ASA", "severity": "warn", "text": "TEST BR24-Warnkette · keine echte Warnung", "updated": now - 60, "ext_id": "x", "is_test": 1},
           {"source": "ASA", "severity": "warn", "text": "alt", "updated": now - ASA_ACTIVE_S - 5, "ext_id": "old"}]
    br_asa = {"state": "rot", "why": {"t": now - 30, "src": "ASA DE 5C", "kind": "DLS", "text": "Gefahr: Fenster und Türen schließen und Radio…", "cls": "rot"}}
    aa = [a for a in alarms_from(None, None, br_asa, act, now) if a["src"] == "ASA"]
    assert [a["key"] for a in aa if a["real"]] == ["DH:5C:a:1"] and sum(1 for a in aa if a["test"]) == 2, aa     # gleiche ASA-Meldung einmal
    assert alarm_identifier(aa) == 2 and alarm_identifier(a2) == 1 and alarm_identifier([]) == 0
    st, ch = takeover_auto(d, al, now)
    assert ch and st["on"] and st["src"] == "NINA" and st["by"] == "auto" and "NINA:mow.1" in st["seen"]
    assert takeover_auto(d, al, now + 5)[1] is False
    st = takeover_set(d, False, by="dashboard", now=now + 60)
    assert not st["on"] and takeover_auto(d, al, now + 70)[1] is False and not takeover_load(d)["on"]      # Rueckgabe: alter Alarm kapert nicht erneut
    st, ch = takeover_auto(d, a1, now + 80)
    assert ch and st["on"] and st["src"] == "BR24"                                                           # neuer echter Alarm kapert
    takeover_set(d, False, now=now + 90)
    assert takeover_auto(d, a2, now + 95)[1] is False and not takeover_load(d)["on"]                         # PTY 30 nie
    assert takeover_set(d, True, "manual", "Knopf", now=now + 100)["on"] and takeover_load(d)["src"] == "manual"
    # ASA-Ueberwachung
    import database as _dbm
    _dbm.migrate_t2(p)
    with open(os.path.join(d, "broadcast_state.json"), "w") as f:
        json.dump({"t2": {"roles": {"s2": {"alarm": True, "since": now, "sn": "72055505", "mode": "ALARM 5C (ASA DE)"}},
                          "fig": {"11D": {"t": now, "sn": "19348831", "ens": "Bayern", "ecc": "0xE0", "lto": 2.0, "ens_id": "0x10A1",
                                          "tii": [{"main": 7, "sub": 2, "km": 12.3, "mast": "BR Bayern MainID 07 / SubID 02"}]}},
                          "asa_rx": [now + 65 * i for i in range(10)], "ev": [{"id": "T2:11D:tii:%d" % now, "t": now, "ch": "11D", "k": "tii", "text": "DAB 11D TII erstmals: 07/02"}]}}, f)
    _T2["asa_max"], _T2["ev"] = 0, []
    r = t2_sync(d, p, now)
    assert r == {"fig": 1, "asa": 10, "events": 1}, r
    assert t2_sync(d, p, now) == {"fig": 0, "asa": 0, "events": 0}                                           # idempotent
    m = asa_monitor(d, p, now + 650)
    assert m["status"] == "ASA_LERNT" and m["n"] == 9 and m["soll_s"] == 65, m
    for i in range(10, 25):
        _dbm.asa_rx_add(now + 65 * i, path=p)
    assert asa_monitor(d, p, now + 65 * 24 + 60)["status"] == "ASA_OK"
    m = asa_monitor(d, p, now + 65 * 24 + 98)
    assert m["status"] == "ASA_INTERRUPTED" and m["limit_s"] == 97.5, m
    takeover_set(d, False, now=now + 65 * 24 + 99)
    assert asa_monitor(d, p, now + 65 * 30)["status"] == "ASA_RUHT"                                          # 5C nicht ueberwacht -> nie unterbrochen
    ev = [e for e in db.recent_events(10, p) if e["source"] == "DAB"]
    assert ev and ev[0]["type"] == "tii" and ev[0]["severity"] == "info" and classify(db.active_events(now, p), None, now)[0] == "OK"
    assert gpio_alarm(2, {})["on"] is False and gpio_alarm(2, {"gpio_alarm_pin": None})["on"] is False and gpio_alarm(2, {"gpio_alarm_pin": True})["on"] is False
    assert _GPIO["dev"] is None and "gpiozero" not in __import__("sys").modules                                # AUS: kein Import, kein Pin
    s = t2_status(d, p, now, alarms=aa)
    assert s["ok"] and s["fig"]["11D"]["ecc"] == "0xE0" and s["alarm_identifier"] == 2 and "seen" not in s["takeover"], s
    return "sdr_manager selftest Teil 2 ok (NINA nur Severe/Extreme+Actual, BR24 rot, PTY 30/Probe/Uebung nie, ASA einmal, Uebernahme nur bei neuen Alarmen, Rueckgabe nur per Knopf, ASA-Soll gelernt/RUHT/LERNT/OK/INTERRUPTED, FIG/TII/ASA in DB, GPIO aus)"


if __name__ == "__main__":
    print(selftest())
    print(selftest_t2())
T2MSM_EOF
EXPECT_MMR="f0052cfd0f35d116f0285ca3e90febe43b2acec542d767202e47bc2f4804a481"
cat > "$W/new/mesh_router.py" << 'T2MMR_EOF'
"""mesh_router.py - Dublettenpruefung fuer Mesh-Texte (Teil 1) + automatischer Versand echter Alarme an Mesh 1 (Teil 2).

Teil 1: md5-Hashes normalisierter Texte je Kanal in lagezentrum.db (Tabelle mesh_log, 24 h).
Teil 2 (Freigabe Frank): echte Alarme (ASA-Echtalarm, NINA, echter BR24-Notfall) automatisch an Mesh 1 (Kanal 0).
  - Dieses Modul oeffnet selbst KEINE Verbindung und spricht kein Mesh-Geraet an: gesendet wird nur ueber die
    uebergebene Funktion send_fn (im Dashboard: dieselbe send_meshtastic wie der Knopf "An Mesh 1 senden",
    Bridge 127.0.0.1:5001). Einzige Sendestelle: _tx().
  - Schalter mesh_auto.json (Kill-Switch), fehlt/kaputt = AUS. Bei AUS wird nichts gesendet.
  - Probe/Test nie: Probealarm, Test/Uebung/Warntag im Text, eigene TEST-Meldungen, RDS PTY 30 (Alarmtest).
  - Eine Meldung je Alarm (Tabelle mesh_auto), gleicher Inhalt nicht innerhalb 6 h, hoechstens 3 Auto-Meldungen
    je Stunde, jeder Versuch in mesh_log protokolliert (Hash, Kanal auto0, Quelle, Text, Ergebnis).
"""
import hashlib
import json
import os
import re
import time

try:
    import database as _db
except Exception:  # Modul fehlt -> Hilfen liefern None, nie Absturz
    _db = None

_WS = re.compile(r"\s+")
_NUM = re.compile(r"\d+(?:[.,]\d+)?")


def normalize(text, ignore_numbers=False):
    """Kleinbuchstaben, Leerraum zusammengefasst; optional Zahlen neutralisiert (Messwert-Schwankung egal)."""
    t = _WS.sub(" ", str(text or "")).strip().lower()
    return _NUM.sub("#", t) if ignore_numbers else t


def msg_hash(text, channel=None, ignore_numbers=False):
    """md5 ueber Kanal + normalisierten Text (hex)."""
    raw = "%s|%s" % ("" if channel is None else str(channel), normalize(text, ignore_numbers))
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def is_duplicate(text, channel=None, ignore_numbers=False, path=None):
    """Nur pruefen (nicht merken). -> True/False, None bei Fehler/ohne DB."""
    if _db is None:
        return None
    return _db.mesh_known(msg_hash(text, channel, ignore_numbers), path)


def remember(text, channel=None, ignore_numbers=False, path=None):
    """Merken. -> True wenn schon bekannt war (Dublette), False wenn neu, None bei Fehler."""
    if _db is None:
        return None
    return _db.mesh_seen(msg_hash(text, channel, ignore_numbers), None if channel is None else str(channel), path)


def selftest():
    import os
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "m.db")
    assert normalize("  Hallo\n Welt ") == "hallo welt"
    assert msg_hash("Pegel 1,2 m", 0, True) == msg_hash("pegel 3,4 m", 0, True)
    assert msg_hash("a", 0) != msg_hash("a", 1)
    assert is_duplicate("x", 0, path=p) is False
    assert remember("x", 0, path=p) is False and remember(" X ", 0, path=p) is True and is_duplicate("x", 0, path=p) is True
    return "mesh_router selftest ok"


# ---------------------------------------------------------------- Teil 2: Auto-Versand echter Alarme an Mesh 1
AUTO_FILE = "mesh_auto.json"     # Kill-Switch {"on": true/false}; fehlt/kaputt = AUS
AUTO_CHANNEL = 0                 # Mesh 1 = Kanalindex 0 (wie Knopf "An Mesh 1 senden")
AUTO_LOGCH = "auto0"             # Kanal-Kennung im mesh_log fuer Auto-Versand
AUTO_SAME_S = 6 * 3600           # gleicher Inhalt erst nach 6 h wieder
AUTO_HOUR_MAX = 3                # hoechstens 3 Auto-Meldungen je Stunde
AUTO_MAX = 200                   # Zeichen (Bridge schneidet ebenfalls bei 200)
AUTO_SRC = {"ASA": "ALARM ASA DE", "BR24": "ALARM BR24", "NINA": "ALARM NINA"}
TEST_RE = re.compile(r"\b(probe\w*|test\w*|warntag|uebungs?\w*|übung\w*|exercise)\b", re.I)
OWN_TEST_RE = re.compile(r"^\s*TEST\b.*keine echte Warnung", re.I | re.S)


def auto_state(base):
    """-> {"on": bool, "t", "by"} - nur on == true (bool) zaehlt als AN."""
    try:
        with open(os.path.join(base, AUTO_FILE), encoding="utf-8") as f:
            d = json.load(f)
        d = d if isinstance(d, dict) else {}
    except Exception:
        d = {}
    return {"on": d.get("on") is True, "t": d.get("t") if isinstance(d.get("t"), (int, float)) else None, "by": str(d.get("by") or "")[:20] or None}


def set_auto(base, on, by="dashboard", now=None):
    """Schalter atomar setzen. -> neuer Zustand"""
    fn = os.path.join(base, AUTO_FILE)
    tmp = "%s.tmp-%d" % (fn, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"on": on is True, "t": int(now or time.time()), "by": str(by)[:20]}, f)
    os.replace(tmp, fn)
    return auto_state(base)


def is_test(a):
    """Probe/Test/Uebung/eigene TEST-Meldung/RDS PTY 30 -> True (wird nie gesendet)."""
    if not isinstance(a, dict) or a.get("test") or a.get("probe"):
        return True
    tx = " ".join(str(a.get(k) or "") for k in ("text", "kind", "why"))
    return bool(TEST_RE.search(tx) or OWN_TEST_RE.search(str(a.get("text") or "")) or re.search(r"\bPTY\s*30\b", tx))


def auto_text(a):
    t = " ".join(("%s: %s" % (AUTO_SRC.get(a.get("src"), "ALARM"), a.get("text") or "")).split())
    return t if len(t) <= AUTO_MAX else t[:AUTO_MAX - 1].rstrip() + "…"


def _tx(send_fn, text):
    """Einzige Sendestelle dieses Moduls."""
    return bool(send_fn(text, channel=AUTO_CHANNEL))


def auto_send(alarms, send_fn, base, path=None, now=None, also_sent=()):
    """Echte Alarme an Mesh 1 (nur wenn Schalter AN). alarms: [{"src": ASA|BR24|NINA, "key", "text", "real", "test", "dup_existing"}].
    also_sent: Texte, die in den letzten 6 h schon per Knopf an Mesh 1 gingen. -> Bericht {"on", "sent": [...], "skip": [...]}"""
    now = int(now or time.time())
    st = auto_state(base)
    rep = {"on": st["on"], "t": now, "sent": [], "skip": []}
    manual = {normalize(x) for x in (also_sent or ())}
    for a in alarms or []:
        try:
            if not isinstance(a, dict) or a.get("src") not in AUTO_SRC or not a.get("key") or not str(a.get("text") or "").strip():
                continue
            akey = "%s:%s" % (a["src"], a["key"])
            skip = lambda why: rep["skip"].append({"key": akey, "src": a["src"], "why": why})
            if is_test(a):
                skip("Probe/Test - wird nie gesendet")
                continue
            if not a.get("real"):
                skip("kein echter Alarm (z. B. NINA unter Severe) - wird nicht gesendet")
                continue
            if a.get("dup_existing"):
                skip(str(a.get("dup_existing"))[:120])
                continue
            if not st["on"]:
                skip("Auto-Versand AUS (Schalter)")
                continue
            if _db is None:
                skip("lagezentrum.db nicht verfuegbar - sicherheitshalber nicht gesendet")
                continue
            text = auto_text(a)
            h = msg_hash(text, AUTO_LOGCH)
            old = _db.mesh_auto_get(akey, path)
            if old and old.get("ok") == 1:
                skip("schon gesendet (eine Meldung je Alarm)")
                continue
            core = normalize(a.get("text"))
            if normalize(text) in manual or (len(core) >= 8 and any(core in m for m in manual)):
                skip("schon per Knopf an Mesh 1 gesendet")
                continue
            seen = _db.mesh_hash_since(h, now - AUTO_SAME_S, path)
            if seen is not False:
                skip("gleicher Inhalt in den letzten 6 h schon gesendet" if seen else "Dublettenpruefung nicht lesbar - nicht gesendet")
                continue
            n = _db.mesh_auto_count(now - 3600, path)
            if n is None or n >= AUTO_HOUR_MAX:
                skip("Grenze %d Auto-Meldungen je Stunde erreicht" % AUTO_HOUR_MAX if n is not None else "Zaehler nicht lesbar - nicht gesendet")
                continue
            r = _db.mesh_auto_reserve(akey, h, a["src"], text, now, path)
            if r is None:
                skip("schon versucht (naechster Versuch fruehestens nach %d min, hoechstens %d Versuche)" % (_db.AUTO_RETRY_S // 60, _db.AUTO_TRIES_MAX))
                continue
            try:
                ok = _tx(send_fn, text)
            except Exception as e:
                print("mesh_router Auto-Versand:", e, flush=True)
                ok = False
            _db.mesh_auto_done(akey, ok, path)
            _db.mesh_log_put(h, AUTO_LOGCH, now, a["src"], text, ok, "auto", path)
            rep["sent"].append({"key": akey, "src": a["src"], "text": text, "ok": ok, "try": r})
            if not getattr(send_fn, "selftest", False):     # Selbsttest-Sender nicht ins Journal (sieht sonst wie echter Versand aus)
                print("mesh_router: Auto-Versand %s an Mesh 1 (Kanal %d): %s -> %s" % (a["src"], AUTO_CHANNEL, text[:80], "ok" if ok else "FEHLER"), flush=True)
        except Exception as e:
            print("mesh_router Auto-Versand:", e, flush=True)
    return rep


def selftest_t2():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "m.db")
    out = []

    def fake(text, channel=0):
        out.append((text, channel))
        return True
    fake.selftest = True
    A = [{"src": "ASA", "key": "a1", "text": "Gefahr: Fenster und Türen schließen", "real": True}]
    assert auto_state(d)["on"] is False                                           # Standard AUS
    r = auto_send(A, fake, d, p, 1000)
    assert out == [] and r["skip"][0]["why"].startswith("Auto-Versand AUS"), r      # AUS -> nichts gesendet
    with open(os.path.join(d, AUTO_FILE), "w") as f:
        f.write('{"on": "ja"}')
    assert auto_state(d)["on"] is False and auto_send(A, fake, d, p, 1000) and out == []   # kaputt/kein true -> AUS
    tests = [{"src": "ASA", "key": "p", "text": "Probewarnung ASA DE", "real": True}, {"src": "BR24", "key": "t", "text": "RDS PTY 30 Alarmtest", "kind": "RDS PTY 30 Alarmtest", "real": True},
             {"src": "BR24", "key": "o", "text": "TEST BR24-Warnkette · keine echte Warnung", "real": True}, {"src": "NINA", "key": "w", "text": "Bundesweiter Warntag", "real": True},
             {"src": "ASA", "key": "x", "text": "Gefahr", "real": True, "test": True}, {"src": "ASA", "key": "y", "text": "Gefahr", "real": False}]
    set_auto(d, True, "selftest", 1000)
    assert auto_state(d)["on"] is True
    r = auto_send(tests, fake, d, p, 1000)
    assert out == [] and len(r["skip"]) == 6 and all("Test" in x["why"] for x in r["skip"][:5]) and "kein echter" in r["skip"][5]["why"], r   # Tests/Proben nie
    r = auto_send(A + A, fake, d, p, 1000)
    assert len(out) == 1 and out[0][1] == AUTO_CHANNEL and out[0][0].startswith("ALARM ASA DE: Gefahr") and r["skip"][0]["why"].startswith("schon gesendet"), r
    assert auto_send(A, fake, d, p, 1100)["skip"][0]["why"].startswith("schon gesendet") and len(out) == 1   # eine Meldung je Alarm
    B = [{"src": "ASA", "key": "a2", "text": "Gefahr: Fenster und Türen schließen", "real": True}]
    assert auto_send(B, fake, d, p, 2000)["skip"][0]["why"].startswith("gleicher Inhalt") and len(out) == 1  # gleicher Inhalt < 6 h
    assert len(auto_send(B, fake, d, p, 1000 + AUTO_SAME_S + 1)["sent"]) == 1 and len(out) == 2              # nach 6 h wieder erlaubt
    T = 1000 + AUTO_SAME_S + 10
    C = [{"src": "BR24", "key": "b%d" % i, "text": "Amtliche Gefahrendurchsage Nr. %d" % i, "real": True} for i in range(4)]
    r = auto_send(C, fake, d, p, T)
    assert len(r["sent"]) == 2 and r["skip"][-1]["why"].startswith("Grenze 3") and len(out) == 4, r          # max 3 je Stunde (B zaehlt mit)
    assert len(auto_send(C, fake, d, p, T + 3601)["sent"]) == 2 and len(out) == 6
    assert auto_send([{"src": "NINA", "key": "n1", "text": "Gefahr", "real": True, "dup_existing": "bestehende NINA-Automatik"}], fake, d, p, T + 9000)["skip"][0]["why"].startswith("bestehende")
    assert auto_send([{"src": "BR24", "key": "m1", "text": "Unwetter Erlangen", "real": True}], fake, d, p, T + 9000, also_sent=["BR24 Warnung 17.10.2026 12:00 BR24 UKW RadioText: Unwetter  Erlangen"])["skip"][0]["why"].startswith("schon per Knopf")

    def bad(text, channel=0):
        out.append((text, channel))
        return False
    bad.selftest = True
    D = [{"src": "ASA", "key": "f1", "text": "Gefahr Hochwasser", "real": True}]
    assert auto_send(D, bad, d, p, T + 20000)["sent"][0]["ok"] is False and len(out) == 7
    assert auto_send(D, fake, d, p, T + 20060)["skip"][0]["why"].startswith("schon versucht") and len(out) == 7
    assert auto_send(D, fake, d, p, T + 20000 + 601)["sent"][0]["try"] == "wieder" and len(out) == 8        # Fehlversuch -> spaeter erneut
    assert len(_db.mesh_auto_recent(50, p)) == 7 and all(x["ok"] == 1 for x in _db.mesh_auto_recent(50, p))
    set_auto(d, False, "selftest")
    assert auto_send([{"src": "ASA", "key": "z", "text": "Neue Gefahr", "real": True}], fake, d, p, T + 90000)["sent"] == [] and len(out) == 8   # Kill-Switch
    return "mesh_router selftest Teil 2 ok (AUS = nichts, Tests nie, eine Meldung je Alarm, 6 h gleicher Inhalt, max 3/h, Kill-Switch, Fehlversuch, nur ueber send_fn)"


if __name__ == "__main__":
    print(selftest())
    print(selftest_t2())
T2MMR_EOF
PS_="$W/patch-t2-sdr.py"; PD="$W/patch-t2-dash.py"; BS="$W/t2_sdr_block.py"; BD="$W/t2_dash_block.py"; SG="$W/guard_t2.py"; SH="$W/show_t2.py"
for x in "$EXPECT_BS $BS" "$EXPECT_BD $BD" "$EXPECT_PS $PS_" "$EXPECT_PD $PD" "$EXPECT_GUARD $SG" "$EXPECT_SHOW $SH" \
         "$EXPECT_MDB $W/new/database.py" "$EXPECT_MSM $W/new/sdr_manager.py" "$EXPECT_MMR $W/new/mesh_router.py"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
NEW_MOD16="$(for m in "${MODS[@]}"; do sha256sum "$W/new/$m" | cut -c1-16; done | tr '\n' ' ')"
# ---------- 1) Basis (sha16 bekannt oder Guards erkannt; rdsNotfall muss drin sein) ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
case " $KNOWN_SDR16 " in *" $S16 "*) KN=bekannt;; *) KN="neu, Erkennung ueber Guards";; esac
case " $KNOWN_DASH16 " in *" $D16 "*) KD=bekannt;; *) KD="neu, Erkennung ueber Guards";; esac
echo "Basis prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $KN); dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $KD)"
grep -q '# ===== /rdsNotfall =====' "$M" && grep -q '# ===== /rdsNotfall =====' "$F" || { echo "STOP: rdsNotfall fehlt noch - bitte zuerst apply-rdsnotfall.sh einspielen, nichts geaendert"; exit 1; }
python3 "$PS_" "$M" "$W/work/prepper_sdr.py" "$BS" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
python3 "$PD" "$F" "$W/work/dashboard.py" "$BD" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
i=0; set -- $OLD_MOD16; OLDS=("$@"); set -- $NEW_MOD16; NEWS=("$@")
for m in "${MODS[@]}"; do
  [[ -f "$DASH_DIR/$m" ]] || { echo "STOP: $m fehlt (Teil 1 nicht installiert?) - nichts geaendert"; exit 1; }
  h=$(sha256sum "$DASH_DIR/$m" | cut -c1-16)
  if [[ "$h" == "${OLDS[$i]}" ]]; then echo "  $m sha16 $h = Teil 1 -> wird ersetzt"
  elif [[ "$h" == "${NEWS[$i]}" ]]; then echo "  $m sha16 $h = Teil 2 schon drin"
  else echo "STOP: $m sha16 $h unbekannt (erwartet Teil 1 ${OLDS[$i]} oder Teil 2 ${NEWS[$i]}) - nichts geaendert"; exit 1; fi
  cp "$DASH_DIR/$m" "$W/old/$m"; i=$((i + 1))
done
echo "OK Basis erkannt: prepper_sdr Guards rdsNotfall/dabGain/dabFix/lageDB/sdrDual, Anker /rdsNotfall genau 1x -> $(cat "$W/p1.log"); Dashboard Guards rdsNotfall/lageDB/lageGeo/lageMesh1/br24Warn2 -> $(cat "$W/p2.log")"
for u in prepper-sdr prepper-dashboard; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - erst Dienst pruefen, nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
python3 "$PS_" "$W/work/prepper_sdr.py" "$W/work/s2.py" "$BS" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/s2.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
python3 "$PD" "$W/work/dashboard.py" "$W/work/d2.py" "$BD" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: Dashboard nicht idempotent"; exit 1; }
rm -f "$W/work/s2.py" "$W/work/d2.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/prepper_sdr.py" "$W/work/dashboard.py" "$W/new/database.py" "$W/new/sdr_manager.py" "$W/new/mesh_router.py"; do
    "$py" -W error -m py_compile "$x" || { echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp "$W/new/"*.py "$W/msbx/"
for py in "$SPY" "$VPY"; do
  for k in "database.py:database selftest Teil 2 ok" "sdr_manager.py:sdr_manager selftest Teil 2 ok" "mesh_router.py:mesh_router selftest Teil 2 ok"; do
    m=${k%%:*}; want=${k#*:}
    (cd "$W/msbx" && timeout 120 "$py" "$m" > "$W/mst.log" 2>&1) || { tail -12 "$W/mst.log"; echo "STOP: Selbsttest $m ($py) - nichts geaendert"; exit 1; }
    [[ "$(cat "$W/mst.log")" == *"$want"* ]] || { tail -5 "$W/mst.log"; echo "STOP: Selbsttest $m ohne '$want' ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest Module mit $SPY und $VPY (Sandbox, Testsender ohne Funk): database, sdr_manager, mesh_router Teil 1 + Teil 2"
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 300 "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest rdsNotfall ok" "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest dabHist ok" "selftest br24Warn2 ok" "selftest OK:"; do
    [[ "$(cat "$W/selftest.log")" == *"$k"* ]] || { echo "STOP: Selbsttest ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY (Sandbox): $(grep 'selftest sdrTeil2 ok' "$W/selftest.log" | head -1 | cut -c1-150)"
python3 "$SG" "$M" "$W/work/prepper_sdr.py" "$F" "$W/work/dashboard.py" "$W/old" "$W/new" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons, alle 5 Dateien)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
fsig() { for x in "$DASH_DIR/sdr_takeover.json" "$DASH_DIR/mesh_auto.json"; do [[ -f "$x" ]] && sha256sum "$x" | cut -c1-16 || echo fehlt; done | tr '\n' ' '; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
SAME=1
cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/dashboard.py" "$F" || SAME=0
for m in "${MODS[@]}"; do cmp -s "$W/new/$m" "$DASH_DIR/$m" || SAME=0; done
ALL=("$M" "$F"); for m in "${MODS[@]}"; do ALL+=("$DASH_DIR/$m"); done
if [[ "$SAME" == 1 ]]; then
  echo "OK Teil 2 schon installiert - kein Neustart"
  T0=$(python3 -c "import json;print(int(json.load(open('$DASH_DIR/sdr_status.json')).get('started') or 0))" 2>/dev/null || echo 0)
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "teil2|Traceback|Error" | tail -8 | cut -c1-200 || true
    sudo journalctl -u prepper-sdr --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sdrTeil2|Traceback|Error" | tail -8 | cut -c1-200 || true
    for x in "${ALL[@]}"; do [[ -f "$x.bak-teil2-$TS" ]] && cp -a "$x.bak-teil2-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-teil2-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  lagezentrum.db bleibt (neue Spalten/Tabellen stoeren Teil 1 nicht); Sicherung: lagezentrum.db.bak-teil2-$TS"
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$DASH_DIR/broadcast_state.json" "$DASH_DIR/sdr_config.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-teil2-$TS"
    { ls -1t "$x.bak-teil2-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$DASH_DIR/lagezentrum.db" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$DASH_DIR/lagezentrum.db" "$DASH_DIR/lagezentrum.db.bak-teil2-$TS" \
      || { rm -f "$DASH_DIR/lagezentrum.db.bak-teil2-$TS"; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$DASH_DIR/lagezentrum.db.bak-teil2-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for m in "${MODS[@]}"; do
    cp "$W/new/$m" "$DASH_DIR/$m.new" && chmod --reference="$DASH_DIR/$m.bak-teil2-$TS" "$DASH_DIR/$m.new" && mv -f "$DASH_DIR/$m.new" "$DASH_DIR/$m" || { rb "installieren $m"; exit 1; }
  done
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-teil2-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-teil2-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-sdr + prepper-dashboard - warte auf frischen SDR-Status und HTTP (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr ohne frischen Status oder Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in /api/sdr/ui /api/br24 /api/sdr/live /api/broadcast/events /api/t2/status; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/api/t2/status" -o "$W/t2_1.json" || true
python3 "$SH" check "$W/t2_1.json" && echo "OK /api/t2/status gueltig" || rbx "/api/t2/status ungueltig"
"${CURL[@]}" "$B/" -o "$W/lage.html" || true
grep -q 'id="t2-js"' "$W/lage.html" && grep -q 'id="t2-data"' "$W/lage.html" && echo "OK Lage-Seite: Kachel Sticks & Alarm-Automatik eingebunden (nach BR24)" || rbx "Lage-Seite ohne Teil-2-Kachel"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi unveraendert, Sicherung bleibt letzte Kachel ($R1)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
S0=$(fsig)
c1=$(code -X POST "$B/api/t2/stick2" -H 'Content-Type: application/json' -d '{"action":"alarm","confirm":true}')
c2=$(code -X POST "$B/api/t2/stick2" -H 'Content-Type: application/json' -H 'X-T2: 1' -H "Origin: $B" -d '{"action":"alarm"}')
c3=$(code -X POST "$B/api/t2/autosend" -H 'Content-Type: application/json' -d '{"on":true,"confirm":true}')
c4=$(code -X POST "$B/api/t2/autosend" -H 'Content-Type: application/json' -H 'X-T2: 1' -H 'Origin: http://example.invalid' -d '{"on":true,"confirm":true}')
c5=$(code -X POST "$B/api/t2/autosend" -H 'Content-Type: application/json' -H 'X-T2: 1' -H "Origin: $B" -d '{"on":true}')
c6=$(code "$B/api/t2/stick2"); c7=$(code "$B/api/t2/autosend")
S1=$(fsig)
[[ "$c1 $c2 $c3 $c4 $c5 $c6 $c7" == "403 400 403 403 400 405 405" && "$S0" == "$S1" ]] && echo "OK Knoepfe abgesichert: ohne Ursprung 403, fremder Ursprung 403, ohne Bestaetigung 400, GET 405; nichts umgeschaltet" \
  || rbx "Knopf-APIs nicht abgesichert ($c1 $c2 $c3 $c4 $c5 $c6 $c7; Dateien $S0/$S1)"
sleep 5
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
sdr_fresh "$T0" || rbx "SDR-Status nicht frisch"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "teil2" | tail -3 || true)
if [[ "$JD" == *"teil2 FEHLER"* ]]; then rbx "Dashboard: $JD"; fi
if [[ "$JD" == *"teil2 aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'teil2 aktiv' | tail -1 | cut -c1-200)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet teil2 nicht (Journal)"; fi
JS=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrTeil2: " | tail -2 || true)
if [[ "$JS" == *"sdrTeil2: aktiv"* || "$JS" == *"sdrTeil2: AUS"* ]]; then echo "OK Journal prepper-sdr: $(echo "$JS" | tail -1 | cut -c1-160)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "prepper-sdr meldet sdrTeil2 nicht (Journal)"; fi
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrTeil2 [a-z_0-9]+:" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrTeil2-Fehler" || rbx "$E Traceback/sdrTeil2-Fehlerzeilen im Journal prepper-sdr"
echo "Warte auf Stick-Rollen von prepper-sdr (max 180 s) ..."
ok=0; for i in $(seq 1 36); do "${CURL[@]}" "$B/api/t2/status" -o "$W/t2_2.json" || true; python3 "$SH" roles "$W/t2_2.json" && { ok=1; break; }; sleep 5; done
[[ "$ok" == 1 ]] && echo "OK Rollen von prepper-sdr gemeldet" || rbx "prepper-sdr meldet keine Teil-2-Rollen (Stick 1 11D fest)"
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|teil2 (Pruefung|Kachel|live|NINA-Details):" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/teil2-Fehler" || rbx "$E Traceback/teil2-Fehlerzeilen im Journal Dashboard"
echo "OK guards sdrTeil2=$(grep -c '# ===== sdrTeil2:' "$M" || true) teil2(dash)=$(grep -c '# ===== teil2:' "$F" || true) rdsNotfall(sdr)=$(grep -c '# ===== rdsNotfall:' "$M" || true) rdsNotfall(dash)=$(grep -c '# ===== rdsNotfall:' "$F" || true) dabGain=$(grep -c '# ===== dabGain:' "$M" || true) dabFix=$(grep -c '# ===== dabFix:' "$M" || true) lageDB(sdr)=$(grep -c '# ===== lageDB:' "$M" || true) sdrDual=$(grep -c '# ===== sdrDual:' "$M" || true) lageDB(dash)=$(grep -c '# ===== lageDB:' "$F" || true) lageGeo(dash)=$(grep -c '# ===== lageGeo:' "$F" || true) lageMesh1(dash)=$(grep -c '# ===== lageMesh1:' "$F" || true) Teil2(Module)=$(for m in "${MODS[@]}"; do grep -c '# ---------------------------------------------------------------- Teil 2' "$DASH_DIR/$m" || true; done | tr '\n' '/')"
[[ -f "$M.bak-teil2-$TS" ]] && echo "Backups: *.bak-teil2-$TS (prepper_sdr.py, dashboard.py, database.py, sdr_manager.py, mesh_router.py, broadcast_state.json, sdr_config.json, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "${ALL[@]}"; do echo "  $(basename "$x") sha16 $(sha256sum "$x" | cut -c1-16), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG teil2=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, Teil 2 bleibt aktiv. COMMIT $COMMIT_ARG teil2=1"; exit 0' INT
echo "Stand Teil 2:"
python3 "$SH" status "$W/t2_2.json" || true
echo "Hinweis: Auto-Versand an Mesh 1 ist AUS, bis du ihn auf der Lage-Seite einschaltest. Stick 2 kommt nur per Knopf aus dem Alarm zurueck."
echo "COMMIT $COMMIT_ARG teil2=1 fertig"
