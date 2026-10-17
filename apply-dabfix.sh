#!/bin/bash
set -euo pipefail
# dabFix (auf lageDB/lageGeo): DAB-Empfangsguete richtig aus welle-cli lesen (mux.json waehrend der Pruefung alle 3 s, erst nach Sync,
# SNR = letzter Wert ueber 0, 0/fehlend = unbekannt statt 0, FIC-Fehlerrate aus Zaehler-Differenz) und bekannte Rundfunktraeger
# (DAB-Bloecke laut Kanaltabelle, UKW-Sender der Senderliste) nicht als Stoerer werten. Nur prepper_sdr.py, Neustart nur prepper-sdr.
# Sendet nichts, kein Mesh, keine neuen Sockets/Server/Faeden; liest nur mux.json ueber den vorhandenen Abruf (127.0.0.1).
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/dabfix-apply
KEEP_LAST=3
KNOWN_SDR16="1bf6f747054b7bd6"   # live nach lageDB/lageGeo (5140 Zeilen)
DAB_WAIT_S="${DAB_WAIT_S:-1500}"  # danach: auf naechste DAB-Pruefung + Stoerer-Messung warten und Werte zeigen (nur Anzeige, kein Rollback)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== dabFix apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_BLK="56040b199a0a23da757b878a4ffba2369e57b200be9f505894ce8d15c650d7b5"
cat > "$W/df_sdr_block.py" << 'DFSDR_EOF'
# ===== dabFix: DAB-Empfangsguete richtig lesen (welle-cli mux.json waehrend der Pruefung mehrfach, erst nach Sync, 0/fehlend = unbekannt) + bekannte Rundfunktraeger (DAB-Bloecke, UKW-Raster) nicht als Stoerer werten; nur Empfang, nur lesen =====
# welle-cli: demodulator.snr ist nach Programmstart/Umschalten 0 und wird erst nach Sync (Rahmen-Takt) gesetzt; welle rechnet den Wert ganzzahlig
# geglaettet, unter ca. 4 dB bleibt er 0. Darum: alle DABFIX_POLL_S Sekunden mux.json lesen (vorhandener Abruf, nur 127.0.0.1), nur Proben mit
# Sync zaehlen (demodulator.time_last_fct0_frame frisch, sonst Ensemble-Name), SNR = letzter Wert ueber 0, FIC-Fehlerrate aus der Differenz der
# Fehlerzaehler zwischen erster und letzter Sync-Probe. Kein Sync -> SNR/Fehlerrate leer (None), nie 0.
# Schluessel: verschachtelt (demodulator.snr, demodulator.fic.numcrcerrors) oder flach (demodulator_snr ...) oder alt (snr oben).
# Stoerer: Traeger im DAB-Band mit Spitze <= 0,8 MHz neben einer Blockmitte und Breite 0,5-2,0 MHz = DAB-Ensemble (Block halb sichtbar, wenn die
# Messung ihn an einer Sprungmitte teilt); UKW: schmal (<= 250 kHz) und +-60 kHz an einem Sender der Senderliste (fm) oder an noise_fm_known
# (MHz-Liste in sdr_config.json) = Sender. Andere UKW-Traeger bleiben wie bisher (Dauer-Traeger lernt die Messung nach 24 h selbst als bekannt).
# Bekannte zaehlen nicht als Stoerer, stehen aber in bc_known (Kanal/Sender, Abstand) im Status. Abschalten: sdr_config.json "noise_bc_white": false.
DABFIX_POLL_S = 3.0
DABFIX_SYNC_MS = 6000
DABFIX_MAXN = 240
DABFIX_DAB_DF = 0.8
DABFIX_DAB_W = (500.0, 2000.0)
DABFIX_FM_W = 250.0
_dabfix_orig_want = Planner.want
_dabfix_orig_on_dab = StateBC.on_dab
_dabfix_orig_nadd = NoiseState.add
_dabfix_orig_nsum = Planner.noise_summary


def _dfnum(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v) if math.isfinite(float(v)) else None
    if isinstance(v, str):
        try:
            x = float(v.strip())
            return x if math.isfinite(x) else None
        except ValueError:
            return None
    return None


def dabfix_parse(mux, now=None):
    """mux.json -> Probe {t, snr, err, fc, fct0, sync, ens} (Werte None wenn nicht da)."""
    now = float(now or time.time())
    if not isinstance(mux, dict):
        return None
    dm = mux.get("demodulator") if isinstance(mux.get("demodulator"), dict) else {}
    fic = dm.get("fic") if isinstance(dm.get("fic"), dict) else {}
    tf = mux.get("fic") if isinstance(mux.get("fic"), dict) else {}

    def pick(*vs):
        for v in vs:
            x = _dfnum(v)
            if x is not None:
                return x
        return None
    snr = pick(dm.get("snr"), mux.get("demodulator_snr"), mux.get("snr"))
    err = pick(fic.get("numcrcerrors"), mux.get("demodulator_fic_numcrcerrors"), tf.get("numcrcerrors"))
    fc = pick(dm.get("frequencycorrection"), mux.get("demodulator_frequencycorrection"), mux.get("frequencycorrection"))
    fct0 = pick(dm.get("time_last_fct0_frame"), mux.get("demodulator_timelastfct0frame"), mux.get("demodulator_time_last_fct0_frame"))
    ens = mux.get("ensemble") if isinstance(mux.get("ensemble"), dict) else {}
    lab = ens.get("label")
    lab = lab.get("label") if isinstance(lab, dict) else lab
    lab = str(lab).strip() if isinstance(lab, str) else ""
    if fct0 is not None and fct0 > 0:
        sync = abs(now * 1000.0 - fct0) <= DABFIX_SYNC_MS
    else:
        sync = bool(lab) or (snr is not None and snr > 0)
    return {"t": round(now, 1), "snr": snr, "err": int(err) if err is not None and err >= 0 else None, "fc": fc, "fct0": fct0, "sync": bool(sync), "ens": lab or None}


def dabfix_summary(ss, since=None):
    """Proben einer Pruefung -> Kennwerte. SNR/Fehlerrate None ohne Sync."""
    ss = [x for x in (ss or []) if isinstance(x, dict)]
    sy = [x for x in ss if x.get("sync")]
    out = {"n_samp": len(ss), "n_sync": len(sy), "sync": bool(sy), "snr": None, "snr_med": None, "snr_n": 0, "snr0_n": 0,
           "fic_rate": None, "fic_secs": None, "fic_derr": None, "fcorr": None, "sync_s": None}
    if not sy:
        return out
    nz = [x["snr"] for x in sy if x.get("snr") is not None and x["snr"] > 0]
    out["snr0_n"] = sum(1 for x in sy if x.get("snr") is not None and x["snr"] <= 0)
    if nz:
        out["snr"], out["snr_med"], out["snr_n"] = round(nz[-1], 2), round(_med(nz), 2), len(nz)
    fcs = [x["fc"] for x in sy if x.get("fc") not in (None, 0)]
    if fcs:
        out["fcorr"] = int(fcs[-1])
    if isinstance(since, (int, float)) and 0 <= sy[0]["t"] - since < 86400:
        out["sync_s"] = round(sy[0]["t"] - since, 1)
    es = [x for x in sy if x.get("err") is not None]
    if len(es) >= 2 and es[-1]["t"] - es[0]["t"] >= 5 and es[-1]["err"] >= es[0]["err"]:
        secs = es[-1]["t"] - es[0]["t"]
        de = es[-1]["err"] - es[0]["err"]
        out.update({"fic_rate": round(min(1.0, de / (secs * LZDB_FIB_PER_S)), 6), "fic_secs": round(secs, 1), "fic_derr": int(de)})
    return out


def dabfix_sample(self, now, mux=None):
    """Planner: waehrend einer DAB-Pruefung (Block oder Vorwahl) mux.json lesen und Probe ablegen."""
    a = str(getattr(self, "active", "") or "")
    ch = None
    if a.startswith("dab:"):
        ch = str(self.dab_list()[int(a[4:])])
    elif a.startswith("p:") and self._pkind(a) == "dab":
        ch = str((preset(a[2:]) or {}).get("ch") or "") or None
    if not ch or not self.procs or not self.alive():
        return None
    st = getattr(self, "_dabfix", None)
    if not isinstance(st, dict) or st.get("job") != a or st.get("since") != self.since:
        st = self._dabfix = {"job": a, "since": self.since, "ch": ch, "s": [], "last": 0.0}
    if mux is None:
        if now - st["last"] < DABFIX_POLL_S or now - self.since < 3:
            return None
        st["last"] = now
        import prepper_sdr_net
        mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
    x = dabfix_parse(mux, now)
    if x is None:
        return None
    st["s"] = (st["s"] + [x])[-DABFIX_MAXN:]
    if x["sync"]:
        self.raw_t, self.raw_fail = time.time(), 0  # DAB synchron = Stick liefert (auch wenn welle SNR 0 meldet)
    try:
        self.sbc._dabfix_ctx = {"ch": ch, "since": self.since, "s": list(st["s"]), "t": now}
    except Exception:
        pass
    return x


def _dabfix_want(self, mode, now):
    try:
        dabfix_sample(self, now)
    except Exception as ex:
        if not getattr(self, "_dabfix_errlog", None) or now - self._dabfix_errlog > 300:
            self._dabfix_errlog = now
            print("dabFix Probe:", ex, flush=True)
    return _dabfix_orig_want(self, mode, now)


def _dabfix_on_dab(self, ch, mux, now=None):
    r = _dabfix_orig_on_dab(self, ch, mux, now)
    try:
        if isinstance(r, dict):
            t = float(now or time.time())
            ctx = getattr(self, "_dabfix_ctx", None) or {}
            ss = list(ctx.get("s") or []) if str(ctx.get("ch")) == str(ch) and 0 <= t - float(ctx.get("t") or 0) < 60 else []
            x = dabfix_parse(mux, t)
            if x is not None and not (ss and abs(ss[-1]["t"] - x["t"]) < 0.5):
                ss.append(x)
            sm = dabfix_summary(ss, ctx.get("since") if ss else None)
            dm = r.get("demod") if isinstance(r.get("demod"), dict) else None
            if dm is None and x is not None:
                lz = getattr(self, "_lzdb_ctx", None) or {}
                dm = {"t": int(t), "fic_err": x["err"], "secs": None, "sn": str(lz["sn"]) if lz.get("sn") else None}
            if dm is not None:
                prev = (getattr(self, "_dabfix_last", None) or {}).get(str(ch)) or {}
                dm["snr_raw"] = dm.get("snr")
                dm["snr"] = sm["snr"]
                if sm["fic_rate"] is not None:
                    dm["fic_rate"], dm["secs"] = sm["fic_rate"], sm["fic_secs"]
                elif not sm["sync"] or len(ss) >= 2:
                    dm["fic_rate"] = None  # ohne Sync / zu kurz: keine Fehlerrate (statt 0)
                if sm["fcorr"] is not None:
                    dm["fcorr"] = sm["fcorr"]
                dm.update({"sync": sm["sync"], "sync_s": sm["sync_s"], "snr_med": sm["snr_med"], "snr_n": sm["snr_n"], "snr0_n": sm["snr0_n"],
                           "n_samp": sm["n_samp"], "n_sync": sm["n_sync"], "fic_derr": sm["fic_derr"], "src": "dabFix"})
                if sm["snr"] is not None:
                    prev = {"snr": sm["snr"], "t": int(t)}
                    if not hasattr(self, "_dabfix_last"):
                        self._dabfix_last = {}
                    self._dabfix_last[str(ch)] = prev
                    dm.pop("snr_last", None)
                    dm.pop("snr_last_t", None)
                elif prev.get("snr") is not None:
                    dm["snr_last"], dm["snr_last_t"] = prev["snr"], prev["t"]  # letzter Wert ueber 0 (nur Anzeige, nicht als aktuell)
                if sm["sync"] and sm["snr"] is None:
                    dm["snr_why"] = "welle meldet 0 dB (Schaetzwert unter ca. 4 dB)"
                elif not sm["sync"]:
                    dm["snr_why"] = "kein Sync"
                else:
                    dm.pop("snr_why", None)
                r["demod"] = dm
                self.dirty = True
                if ss and str(ctx.get("ch")) == str(ch):
                    print("dabFix DAB %s: Sync %s%s, SNR %s (Median %s, %d Werte, %d x 0), FIC-Fehlerrate %s (%s Fehler in %s s), Proben %d" % (
                        ch, "ja" if sm["sync"] else "nein", (" nach %s s" % sm["sync_s"]) if sm["sync_s"] is not None else "", sm["snr"], sm["snr_med"],
                        sm["snr_n"], sm["snr0_n"], sm["fic_rate"], sm["fic_derr"], sm["fic_secs"], sm["n_samp"]), flush=True)
    except Exception as ex:
        print("dabFix on_dab:", ex, flush=True)
    return r


def dabfix_bc_class(bid, c, fm_f=()):
    """Traeger -> bekannter Rundfunktraeger {..., kind, ch, df_khz} oder None."""
    f, w = _dfnum(c.get("f")), _dfnum(c.get("w_khz"))
    if f is None:
        return None
    if bid == "dab" and w is not None and DABFIX_DAB_W[0] <= w <= DABFIX_DAB_W[1]:
        ch, fc = min(DAB_CHANNELS.items(), key=lambda kv: abs(kv[1] - f))
        if abs(fc - f) <= DABFIX_DAB_DF:
            return {"f": c.get("f"), "db": c.get("db"), "w_khz": c.get("w_khz"), "kind": "DAB", "ch": ch, "df_khz": int(round((f - fc) * 1000))}
    if bid == "fm" and 87.4 <= f <= 108.1 and (w is None or w <= DABFIX_FM_W):
        for nm, ff in fm_f:
            if abs(ff - f) <= 0.06:
                return {"f": c.get("f"), "db": c.get("db"), "w_khz": c.get("w_khz"), "kind": "UKW", "ch": nm, "df_khz": int(round((f - ff) * 1000))}
    return None


def _dabfix_fm_f(cfg):
    """Bekannte UKW-Sender: Senderliste (fm) + noise_fm_known (MHz-Liste in sdr_config.json)."""
    out = []
    v = (cfg or {}).get("fm")
    for st in (v if isinstance(v, list) and v else FM_DEFAULT):
        try:
            ff = str(st.get("f") or "").strip().upper().rstrip("M")
            out.append((str(st.get("name") or ff), float(ff) / (1e6 if float(ff) > 1e5 else 1.0)))
        except Exception:
            pass
    for x in ((cfg or {}).get("noise_fm_known") or []) if isinstance((cfg or {}).get("noise_fm_known"), list) else []:
        y = _dfnum(x)
        if y is not None and 87.4 <= y <= 108.1:
            out.append(("%.2f" % y, y))
    return out


def _dabfix_nadd(self, r, cfg, now=None):
    try:
        bid = (r or {}).get("band")
        if bid in ("dab", "fm") and (cfg or {}).get("noise_bc_white", True) is not False and isinstance(r.get("cars"), list) and r.get("ok"):
            fmf = _dabfix_fm_f(cfg) if bid == "fm" else ()
            keep, known = [], []
            for c in r["cars"]:
                k = dabfix_bc_class(bid, c, fmf) if isinstance(c, dict) else None
                (known if k else keep).append(k or c)
            r2 = dict(r, cars=keep)
            res = _dabfix_orig_nadd(self, r2, cfg, now)
            b = self.d["bands"].get(bid)
            if isinstance(b, dict) and b.get("ok"):
                b["bc_known"] = sorted(known, key=lambda y: -(y.get("db") or 0))[:8]
                b["n_bc"] = len(known)
            return res
    except Exception as ex:
        print("dabFix Stoerer-Filter:", ex, flush=True)
    return _dabfix_orig_nadd(self, r, cfg, now)


def _dabfix_nsum(self):
    s = _dabfix_orig_nsum(self)
    try:
        bd = (self.snoise.d.get("bands") or {})
        for b in s.get("bands") or []:
            x = bd.get(b.get("id")) or {}
            if "bc_known" in x:
                b["bc_known"] = (x.get("bc_known") or [])[:6]
                b["n_bc"] = x.get("n_bc")
    except Exception as ex:
        print("dabFix Status:", ex, flush=True)
    return s


Planner.want = _dabfix_want
StateBC.on_dab = _dabfix_on_dab
NoiseState.add = _dabfix_nadd
Planner.noise_summary = _dabfix_nsum


def selftest_dabfix():
    t0 = 1790000000.0
    a = dabfix_parse({"demodulator": {"snr": 0, "fic": {"numcrcerrors": 0}, "time_last_fct0_frame": 0}}, t0)
    assert a["sync"] is False and a["snr"] == 0
    b = dabfix_parse({"demodulator_snr": 11.0, "demodulator_fic_numcrcerrors": 4, "demodulator_timelastfct0frame": (t0 + 9) * 1000}, t0 + 10)
    assert b["sync"] and b["snr"] == 11.0 and b["err"] == 4, b
    assert dabfix_parse({"snr": "7.5", "ensemble": {"label": {"label": "Bayern"}}}, t0)["snr"] == 7.5
    ss = [dabfix_parse({"demodulator": {"snr": 0, "fic": {"numcrcerrors": 0}, "time_last_fct0_frame": 0}}, t0 + 3)]
    for i, (sn, e) in enumerate(((0, 2), (9, 2), (12, 5), (0, 5), (10, 8))):
        ss.append(dabfix_parse({"demodulator": {"snr": sn, "frequencycorrection": -300, "fic": {"numcrcerrors": e}, "time_last_fct0_frame": (t0 + 6 + 3 * i) * 1000}}, t0 + 6 + 3 * i))
    sm = dabfix_summary(ss, t0)
    assert sm["sync"] and sm["snr"] == 10.0 and sm["snr_n"] == 3 and sm["snr0_n"] == 2 and sm["sync_s"] == 6 and sm["fic_derr"] == 6 and sm["fic_secs"] == 12, sm
    assert abs(sm["fic_rate"] - 6 / (12 * 125.0)) < 1e-6 and sm["fcorr"] == -300
    z = dabfix_summary([ss[0]], t0)
    assert z["snr"] is None and z["fic_rate"] is None and not z["sync"]
    import tempfile
    bx = StateBC(tempfile.mkdtemp())
    bx._dabfix_ctx = {"ch": "11D", "since": t0, "s": ss, "t": t0 + 18}
    r = bx.on_dab("11D", {"ensemble": {"label": {"label": "Bayern"}}, "services": [], "demodulator": {"snr": 0, "fic": {"numcrcerrors": 8}, "time_last_fct0_frame": (t0 + 19) * 1000}}, now=t0 + 19.5)
    dm = r["demod"]
    assert dm["snr"] == 10.0 and dm["snr_raw"] == 0 and dm["sync"] and dm["src"] == "dabFix" and dm["fic_rate"] is not None, dm
    bx._dabfix_ctx = None
    r = bx.on_dab("11D", {"ensemble": {"label": {"label": ""}}, "services": [], "demodulator": {"snr": 0, "fic": {"numcrcerrors": 0}, "time_last_fct0_frame": 0}}, now=t0 + 2000)
    dm = r["demod"]
    assert dm["snr"] is None and dm["fic_rate"] is None and dm["snr_last"] == 10.0 and dm["snr_why"] == "kein Sync", dm
    for f, w, ch in ((177.85, 1890, "5C"), (186.53, 1632, "6D"), (200.97, 945, "8D"), (222.0, 1500, "11D")):
        k = dabfix_bc_class("dab", {"f": f, "db": 20, "w_khz": w})
        assert k and k["ch"] == ch, (f, k)
    assert dabfix_bc_class("dab", {"f": 178.35, "db": 25, "w_khz": 25}) is None and dabfix_bc_class("dab", {"f": 179.3, "db": 25, "w_khz": 2600}) is None
    fmf = _dabfix_fm_f({"fm": [{"name": "BR24", "f": "102.0M"}]})
    assert dabfix_bc_class("fm", {"f": 102.0125, "db": 30, "w_khz": 100}, fmf)["ch"] == "BR24"
    assert dabfix_bc_class("fm", {"f": 96.2425, "db": 14, "w_khz": 40}, fmf) is None
    assert dabfix_bc_class("fm", {"f": 96.2425, "db": 14, "w_khz": 40}, _dabfix_fm_f({"noise_fm_known": [96.25]}))["ch"] == "96.25"
    assert dabfix_bc_class("fm", {"f": 99.025, "db": 25, "w_khz": 25}, fmf) is None
    ns = NoiseState(tempfile.mkdtemp())
    cfg = dict(DEFAULT_CFG) if isinstance(globals().get("DEFAULT_CFG"), dict) else {}
    ns.add({"band": "dab", "t": int(t0), "ok": True, "floor": -40.0, "cars": [{"f": 177.85, "db": 24.0, "w_khz": 1890}, {"f": 205.0, "db": 22.0, "w_khz": 30}]}, cfg, int(t0))
    bd = ns.d["bands"]["dab"]
    assert bd["n_bc"] == 1 and bd["bc_known"][0]["ch"] == "5C" and bd["n_car"] == 1, bd
    print("selftest dabFix ok (Sync, SNR letzter Wert ueber 0, 0 = unbekannt, flache Schluessel, FIC-Rate aus Differenz, DAB/UKW-Traeger bekannt)", flush=True)
# ===== /dabFix =====
DFSDR_EOF
EXPECT_PATCH="e3ae071204261b6fe2c3c85a8aee831efcea7b4023e55e7f3ee99128c38014b0"
cat > "$W/patch-df.py" << 'DFPATCH_EOF'
"""dabFix: Block in prepper_sdr.py einsetzen oder ersetzen (idempotent).
Aufruf: patch-df.py QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== dabFix:", "# ===== /dabFix =====\n"
ANCHOR = "# ===== /lageDB =====\n"
ST0, ST1 = "        selftest_lagedb()\n", "        selftest_dabfix()\n"
NEED = ("class StateBC:", "class Planner:", "class NoiseState:", "    def on_dab(self, ch, mux, now=None):", "    def want(self, mode, now):",
        "    def noise_summary(self):", "    def add(self, r, cfg, now=None):", "DAB_CHANNELS = {", "FM_DEFAULT = [", "LZDB_FIB_PER_S = ",
        "StateBC.on_dab = _lzdb_on_dab\n", "def _med(xs):", "def preset(", "# ===== dabHist:", "# ===== stickTestFix:", "# ===== lageDB:")
bad = [n.strip()[:40] for n in NEED if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if s.count(ST0) != 1:
    bad.append("selftest_lagedb() x%d" % s.count(ST0))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("dabFix-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: dabFix-Block steht nicht direkt nach /lageDB"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
if ST1 not in s2:
    s2 = s2.replace(ST0, ST0 + ST1, 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
DFPATCH_EOF
EXPECT_GUARD="25344380e37db2db7f5c8f7642cdc2de7b0b662caf2f19e0f308a39a045d6e44"
cat > "$W/guard_df.py" << 'DFGUARD_EOF'
"""dabFix AST-Guard. Aufruf: guard_df.py SDR_ALT SDR_NEU -> 0 ok, 1 Verstoss.
Keine Sendestelle, kein shell=True, keine neuen Sockets/Server/Prozesse/Faeden, keine neuen Importe; der Block liest nur mux.json ueber den
vorhandenen Abruf prepper_sdr_net.fetch_welle (127.0.0.1) und wertet vorhandene Messwerte aus."""
import ast
import sys

RISKY = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "sendText", "sendData", "TCPInterface", "urlopen", "socket",
         "create_connection", "bind", "listen", "connect", "serve_forever", "HTTPServer", "make_server", "system", "Popen", "run", "call", "check_output",
         "check_call", "execv", "spawn", "fork", "Thread", "Timer", "start_new_thread", "kill", "killpg", "_dev", "write_json", "remove", "unlink")
NETMOD = {"requests", "urllib", "http", "socket", "subprocess", "os", "signal", "threading"}


def info(src):
    t = ast.parse(src)
    imp, calls, shell, attrs = set(), [], 0, []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False):
            shell += 1
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            calls.append(nm)
            if isinstance(f, ast.Attribute):
                attrs.append(((f.value.id if isinstance(f.value, ast.Name) else "?"), f.attr))
    return imp, calls, shell, attrs


rd = lambda f: open(f, encoding="utf-8").read()
s0, s1 = rd(sys.argv[1]), rd(sys.argv[2])
A, Z = "# ===== dabFix:", "# ===== /dabFix ====="
err = []
if s1.count(A) != 1 or s1.count(Z) != 1:
    err.append("dabFix-Marker nicht genau 1x")
blk = s1[s1.index(A):s1.index(Z) + len(Z) + 1] if A in s1 else ""
old = s0[s0.index(A):s0.index(Z) + len(Z) + 1] if A in s0 else ""
rest0 = s0.replace(old, "") if old else s0
rest1 = s1.replace(blk, "")
if rest1.replace("        selftest_dabfix()\n", "") != rest0.replace("        selftest_dabfix()\n", ""):
    err.append("ausserhalb des dabFix-Blocks geaendert (ausser Aufruf selftest_dabfix)")
bi, bc, bs, _ = info(s0)
ni, nc, ns, _ = info(s1)
if ni != bi:
    err.append("Importe geaendert %s" % (ni ^ bi))
if ns != bs:
    err.append("shell=True geaendert")
_bi, kc, ks, ka = info(blk)
for nm in RISKY:
    if nm in kc:
        err.append("Block ruft %s" % nm)
if _bi - {"prepper_sdr_net", "tempfile"}:
    err.append("Block importiert %s" % (_bi - {"prepper_sdr_net", "tempfile"}))
if [x for x in ka if x[0] in NETMOD]:
    err.append("Block: Netz-/Prozessaufruf %s" % [x for x in ka if x[0] in NETMOD])
net = [x for x in ka if x[0] == "prepper_sdr_net"]
if net != [("prepper_sdr_net", "fetch_welle")]:
    err.append("Block: Abrufe %s (erwartet genau 1x prepper_sdr_net.fetch_welle)" % net)
for w in ("mesh", "rtl_tcp", "rtl_sdr", "transmit", "Popen", "open(", "subprocess", "socket", "requests", "urllib", "send(", ".send", "sendtext"):
    if w in blk.lower():
        err.append("Block enthaelt %s" % w)
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard dabFix: nur Block + Selbsttest-Aufruf neu, keine neuen Importe, kein shell=True, keine Sende-/Socket-/Prozess-/Faden-Aufrufe; "
      "einziger Abruf prepper_sdr_net.fetch_welle (mux.json 127.0.0.1, wie bisher)")
DFGUARD_EOF
EXPECT_SHOW="054a6799b0c69582bb71281c33a4c0d80a459935acd0c51ebd0f7dce2b77fbb7"
cat > "$W/show_df.py" << 'DFSHOW_EOF'
"""dabFix Anzeige nach dem Einspielen (nur lesen).
show_df.py chans SDR_CONFIG            -> DAB-Kanaele der Pruefung
show_df.py dab BSTATE T0 CH...         -> 0 wenn alle Kanaele neue dabFix-Werte haben (zeigt sie), 2 sonst; --final zeigt den Stand trotzdem
show_df.py noise STATUS T0 [--final]   -> 0 wenn neue Stoerer-Messung DAB + Gesamtampel da sind (zeigt QRM), 2 sonst
show_df.py live LIVE_JSON              -> /api/sdr/live kurz"""
import json
import sys


def ld(f):
    try:
        return json.load(open(f, encoding="utf-8"))
    except Exception:
        return {}


def fnum(v, nd=2):
    return "-" if v is None else (("%." + str(nd) + "f") % v if isinstance(v, (int, float)) else str(v))


a = sys.argv[1]
fin = "--final" in sys.argv
args = [x for x in sys.argv[2:] if x != "--final"]
if a == "chans":
    c = ld(args[0])
    v = c.get("dab") if isinstance(c.get("dab"), list) and c.get("dab") else ["11D"]
    v = [str(x) for x in v]
    if c.get("asa_5c", True) and "5C" not in v:
        v.append("5C")
    print(" ".join(v))
elif a == "dab":
    d = ld(args[0]).get("dab") or {}
    t0 = float(args[1])
    chs = args[2:]
    got = {ch: (d.get(ch) or {}).get("demod") or {} for ch in chs}
    new = {ch: g for ch, g in got.items() if g.get("src") == "dabFix" and (g.get("t") or 0) >= t0}
    if len(new) < len(chs) and not fin:
        sys.exit(2)
    for ch in chs:
        g = got[ch]
        if ch not in new:
            print("  DAB %s: noch keine neue Pruefung (letzter Wert %s, Quelle %s)" % (ch, g.get("t"), g.get("src") or "alt"))
            continue
        print("  DAB %s: Sync %s%s, SNR %s dB (Median %s, %s Werte >0, %s x 0; welle roh %s)%s, FIC-Fehlerrate (ber) %s = %s Fehler in %s s, Frequenzkorrektur %s Hz, Proben %s, Stick %s" % (
            ch, "ja" if g.get("sync") else "NEIN", (" nach %s s" % g.get("sync_s")) if g.get("sync_s") is not None else "", fnum(g.get("snr"), 1), fnum(g.get("snr_med"), 1),
            g.get("snr_n"), g.get("snr0_n"), g.get("snr_raw"), (" [%s]" % g["snr_why"]) if g.get("snr_why") else "",
            fnum(g.get("fic_rate"), 6), g.get("fic_derr"), g.get("secs"), g.get("fcorr"), g.get("n_samp"), g.get("sn")))
        if g.get("snr_last") is not None:
            print("         letzter SNR ueber 0: %s dB (t %s)" % (g.get("snr_last"), g.get("snr_last_t")))
    sys.exit(0 if len(new) == len(chs) else 2)
elif a == "noise":
    st = ld(args[0])
    t0 = float(args[1])
    out, ok = [], False
    for lab, n in (("Stick 1", st.get("noise")), ("Stick 2", (st.get("s2") or {}).get("noise") if isinstance(st.get("s2"), dict) else None)):
        if not isinstance(n, dict):
            continue
        bd = {b.get("id"): b for b in n.get("bands") or []}
        dab = bd.get("dab") or {}
        q = n.get("qrm") or {}
        if dab and (dab.get("t") or 0) >= t0 and (q.get("t") or 0) >= (dab.get("t") or 0):
            ok = True  # DAB-Band neu gemessen und Gesamtampel danach berechnet
        out.append("  %s: QRM gesamt %s (t %s); %s" % (lab, q.get("lvl"), q.get("t"), "; ".join(
            "%s %s n_pers %s%s" % (b.get("short") or b.get("id"), b.get("lvl"), b.get("n_pers"),
                                   (" bekannt %s" % ", ".join("%s %s (%s MHz, %s kHz breit, %+d kHz)" % (k.get("kind"), k.get("ch"), k.get("f"), k.get("w_khz"), k.get("df_khz") or 0)
                                                              for k in (b.get("bc_known") or [])[:4])) if b.get("bc_known") else "")
            for b in (bd.get("fm") or {}, dab) if b)))
        for b in (bd.get("fm") or {}, dab):
            for c in (b.get("cars") or [])[:3]:
                out.append("     Stoerer %s: %s MHz %s dB %s kHz seit %s" % (b.get("short") or b.get("id"), c.get("f"), c.get("db"), c.get("w_khz"), c.get("since")))
    if not ok and not fin:
        sys.exit(2)
    print("\n".join(out) if out else "  (keine Stoerer-Messung im Status)")
    sys.exit(0 if ok else 2)
elif a == "live":
    d = ld(args[0])
    print("  /api/sdr/live: status %s, ber %s, Mast %s, SDR1 %s, SDR2 %s (%s)" % (d.get("status"), d.get("ber"), d.get("active_mast"), d.get("sdr1_role"), d.get("sdr2_role"), d.get("sdr2_status")))
    seen = set()
    for x in sorted(d.get("telemetry") or [], key=lambda y: -(y.get("ts") or 0)):
        if x.get("channel") in seen:
            continue
        seen.add(x.get("channel"))
        print("    Telemetrie %s: ts %s, SNR %s, ber %s, FIC-Fehler %s in %s s, Stick %s" % (x.get("channel"), x.get("ts"), x.get("snr"), x.get("ber"), x.get("fic_err"), x.get("secs"), x.get("serial")))
DFSHOW_EOF
P="$W/patch-df.py"; BK="$W/df_sdr_block.py"; SG="$W/guard_df.py"; SH="$W/show_df.py"
for x in "$EXPECT_BLK $BK" "$EXPECT_PATCH $P" "$EXPECT_GUARD $SG" "$EXPECT_SHOW $SH"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis (an Guards erkannt) ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
case " $KNOWN_SDR16 " in *" $S16 "*) KN=bekannt;; *) KN="neu, Erkennung ueber Guards";; esac
echo "Basis prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $KN); dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, bleibt unveraendert)"
grep -q "# ===== lageDB:" "$F" || { echo "STOP: Dashboard ohne lageDB-Guard (sha16 $D16) - erst apply-lagedb.sh, nichts geaendert"; exit 1; }
python3 "$P" "$M" "$W/work/prepper_sdr.py" "$BK" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: Guards lageDB + dabHist + stickTestFix in prepper_sdr, Anker /lageDB genau 1x, lageDB-Guard im Dashboard; prepper_sdr $(cat "$W/p1.log")"
SDR_ACT=$(systemctl is-active prepper-sdr 2>/dev/null || true)
[[ "$SDR_ACT" == active ]] || { echo "STOP: prepper-sdr ist nicht aktiv ($SDR_ACT) - erst Dienst pruefen, nichts geaendert"; exit 1; }
# ---------- 2) Trockenlauf ----------
python3 "$P" "$W/work/prepper_sdr.py" "$W/work/s2.py" "$BK" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/s2.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
rm -f "$W/work/s2.py"
for py in "$SPY" "$VPY"; do "$py" -W error -m py_compile "$W/work/prepper_sdr.py" || { echo "STOP: py_compile prepper_sdr ($py) - nichts geaendert"; exit 1; }; done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest dabFix ok" "selftest lageDB ok" "selftest dabHist ok" "selftest OK:"; do grep -q "$k" "$W/selftest.log" || { echo "STOP: Selbsttest ohne $k ($py)"; exit 1; }; done
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY (Sandbox): $(grep 'selftest dabFix ok' "$W/selftest.log")"
python3 "$SG" "$M" "$W/work/prepper_sdr.py" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys,time
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
# ---------- 3) Installieren ----------
RESTARTED=0
if cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK dabFix schon installiert - kein Neustart"
  T0=$(python3 -c "import json;print(int(json.load(open('$DASH_DIR/sdr_status.json')).get('started') or 0))" 2>/dev/null || echo 0)
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -15 | cut -c1-200 || true
    [[ -f "$M.bak-dabfix-$TS" ]] && cp -a "$M.bak-dabfix-$TS" "$M.rb" && mv -f "$M.rb" "$M"
    sudo systemctl restart prepper-sdr.service || true
    cmp -s "$M" "$M.bak-dabfix-$TS" && echo "  prepper_sdr.py = Sicherung ($(sha256sum "$M" | cut -c1-16))" || echo "  WARNUNG prepper_sdr.py ungleich Sicherung"
    sleep 5
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "$M" "$DASH_DIR/noise_state.json" "$DASH_DIR/broadcast_state.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-dabfix-$TS"
    { ls -1t "$x.bak-dabfix-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-dabfix-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  echo "Neustart: nur prepper-sdr - warte auf frischen SDR-Status (max 120 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 60); do sleep 2; systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr schreibt keinen frischen Status"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in /api/sdr/ui /api/sdr/live; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
sleep 8
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
sdr_fresh "$T0" || rbx "SDR-Status nicht frisch"
python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
n=d.get('noise') or {}
assert isinstance(n.get('bands'), list), 'noise.bands fehlt'
print('  OK sdr_status.json: aktiv %s, Rolle %s, QRM %s' % (d.get('active'), d.get('role'), (n.get('qrm') or {}).get('lvl')))" "$DASH_DIR/sdr_status.json" || rbx "sdr_status.json unvollstaendig"
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live0.json" || true
python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); assert d.get('status') in ('SDR_OFFLINE','OK','PROBEALARM','ECHTALARM'), d.get('status')" "$W/live0.json" || rbx "/api/sdr/live ungueltig"
python3 "$SH" live "$W/live0.json"
c=$(code -X POST "$B/api/sdr/live"); [[ "$c" == 405 ]] && echo "OK POST /api/sdr/live abgelehnt (405)" || rbx "POST /api/sdr/live nicht abgelehnt ($c)"
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "dabFix (Probe|on_dab|Stoerer-Filter|Status):|Traceback" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne dabFix-Fehler/Traceback" || echo "WARNUNG: $E dabFix-Fehler/Traceback-Zeilen im Journal (Wert bleibt dann wie vor dabFix)"
echo "OK guards dabFix=$(grep -c '# ===== dabFix:' "$M" || true) lageDB(sdr)=$(grep -c '# ===== lageDB:' "$M" || true) dabHist(sdr)=$(grep -c '# ===== dabHist:' "$M" || true) stickTestFix(sdr)=$(grep -c '# ===== stickTestFix:' "$M" || true) lageDB(dash)=$(grep -c '# ===== lageDB:' "$F" || true) lageGeo(dash)=$(grep -c '# ===== lageGeo:' "$F" || true)"
[[ -f "$M.bak-dabfix-$TS" ]] && echo "Backups: *.bak-dabfix-$TS (prepper_sdr.py, noise_state.json, broadcast_state.json), behalten: letzte $KEEP_LAST"
echo "prepper_sdr.py sha16 jetzt $(sha256sum "$M" | cut -c1-16), $(wc -l < "$M") Zeilen; dashboard.py sha16 $(sha256sum "$F" | cut -c1-16) (unveraendert), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG dabFix=1 - Einspielen fertig. Jetzt nur noch Anzeige: Warten ist ungefaehrlich, Abbruch mit Strg-C aendert nichts."
# ---------- 5) Warten auf DAB-Pruefung + Stoerer-Messung (nur Anzeige) ----------
CH=$(python3 "$SH" chans "$DASH_DIR/sdr_config.json")
echo "Warte auf naechste DAB-Pruefung ($CH) und Stoerer-Messung DAB, max $DAB_WAIT_S s (Rundfunk-Block ca. 2 min nach Neustart, Messung ca. 5 min) ..."
dd=0; nn=0; t=0
while [[ "$t" -lt "$DAB_WAIT_S" ]]; do
  if [[ "$dd" == 0 ]] && python3 "$SH" dab "$DASH_DIR/broadcast_state.json" "$T0" $CH > "$W/dab.txt"; then dd=1; echo "DAB-Pruefung nach $t s:"; cat "$W/dab.txt"; fi
  if [[ "$nn" == 0 ]] && python3 "$SH" noise "$DASH_DIR/sdr_status.json" "$T0" > "$W/nz.txt"; then nn=1; echo "Stoerer-Messung nach $t s:"; cat "$W/nz.txt"; fi
  [[ "$dd" == 1 && "$nn" == 1 ]] && break
  systemctl is-active --quiet prepper-sdr || { echo "WARNUNG: prepper-sdr laeuft nicht mehr - bitte melden"; break; }
  sleep 15; t=$((t + 15))
  [[ $((t % 120)) == 0 ]] && echo "  ... $t s (DAB $([[ $dd == 1 ]] && echo da || echo offen), Messung $([[ $nn == 1 ]] && echo da || echo offen))"
done
[[ "$dd" == 1 ]] || { echo "DAB: nach $DAB_WAIT_S s noch nicht alle Kanaele neu, Stand:"; python3 "$SH" dab "$DASH_DIR/broadcast_state.json" "$T0" $CH --final || true; }
[[ "$nn" == 1 ]] || { echo "Stoerer-Messung: noch nicht neu, Stand:"; python3 "$SH" noise "$DASH_DIR/sdr_status.json" "$T0" --final || true; }
sleep 3
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
python3 "$SH" live "$W/live.json" || true
sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep "dabFix DAB" | tail -4 | cut -c1-220 || true
echo "COMMIT $COMMIT_ARG dabFix=1 fertig"
