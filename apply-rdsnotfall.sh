#!/bin/bash
set -euo pipefail
# rdsNotfall (auf dabGain + lageGeo): "RDS Notfall" nur noch bei echten Kennzeichen - PTY 31 (Alarm, dauerhaft), PTY 30 (Alarmtest = grau Test),
# Gruppe 9A (EWS) mindestens 3x in 60 s und nicht als ODA angemeldet, oder Warnwoerter im RadioText (wie bisher). TA allein, PTY Finance,
# die 1A-EWS-Kennung (redsea "ews" = Slow Labelling Variante 7) und einzelne/gestoerte Gruppen zaehlen nie. Alte unbestaetigte EWS-Ereignisse
# werden im Dashboard nicht mehr rot gezeigt (Daten bleiben unveraendert). DAB unveraendert.
# prepper_sdr.py + dashboard.py, Neustart nur prepper-sdr + prepper-dashboard. Sendet nichts, kein Mesh, keine neuen Sockets/Server/Faeden.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/rdsnotfall-apply
KEEP_LAST=3
KNOWN_SDR16="999496010649ccab"   # live nach dabGain (5693 Zeilen)
KNOWN_DASH16="eae4f12e3a71bdd2"  # live nach lageGeo (17917 Zeilen)
DAB_WAIT_S="${DAB_WAIT_S:-600}"  # danach nur Anzeige: auf frische DAB-Pruefung 11D warten
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== rdsNotfall apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_BS="bd63511a6bb5bccab40fc517ed8193665aa666e5572421afd102069b2a7b9728"
cat > "$W/rn_sdr_block.py" << 'RNSDR_EOF'
# ===== rdsNotfall: RDS-Notfall nur bei echten Kennzeichen - PTY 31 (Alarm), PTY 30 (Alarmtest = nur Test), Gruppe 9A (EWS, mind. 3x in 60 s, nicht als ODA belegt) oder Warnwoerter im RadioText; TA, PTY Finance, 1A-EWS-Kennung (Slow Labelling Variante 7) und andere Gruppen zaehlen nie; nur Empfang, sendet nichts =====
RDSN_EWS9A_N = 3                 # echte EWS-Gruppen 9A werden wiederholt gesendet; eine einzelne (Bitfehler) ist kein Notfall
RDSN_EWS9A_WIN_S = 60
RDSN_ODA_KEEP_S = 3600           # 9A per 3A als ODA angemeldet -> 9A ist Datendienst, kein Notfall
_RDSN_PTY_TXT = {"alarm": 31, "emergency": 31, "alarm test": 30, "emergency test": 30}


def rdsn_pty(v):
    """redsea prog_type -> 31 (Alarm), 30 (Alarmtest), sonst Zahl 0..29 oder None. Nur exakte Namen, kein Teilwort."""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v if 0 <= v <= 31 else None
    if isinstance(v, str):
        t = " ".join(v.strip().lower().split())
        if t.isdigit():
            n = int(t)
            return n if 0 <= n <= 31 else None
        return _RDSN_PTY_TXT.get(t)
    return None


def _rdsn_rej(s, why, now):
    """Verworfene Notfall-Ausloeser je Sender zaehlen (nur Anzeige/Diagnose)."""
    r = s.get("ews_rej") if isinstance(s.get("ews_rej"), dict) else {}
    r[why] = int(r.get(why) or 0) + 1
    r["t"], r["last"] = int(now), why
    s["ews_rej"] = r


def _rdsn_on_rds(self, name, freq, line, now=None):
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        g = json.loads(line)
    except Exception:
        return None
    if not isinstance(g, dict):
        return None
    now = now or time.time()
    s = self.d["fm"].get(name) or {"name": name, "f": freq}
    s.update({"f": freq, "t": int(now)})
    s["groups"] = s.get("groups", 0) + 1
    if g.get("pi"):
        s["pi_t"] = int(now)
    for k_in, k_out in (("pi", "pi"), ("ps", "ps"), ("radiotext", "rt"), ("prog_type", "pty"), ("tp", "tp"), ("ta", "ta")):
        if k_in in g:
            s[k_out] = g[k_in] if not isinstance(g[k_in], str) else g[k_in].strip()[:80]
    rp = g.get("radiotext_plus")
    if isinstance(rp, dict) and isinstance(rp.get("tags"), list):
        s["rtp"] = [str(x.get("content-type"))[:24] for x in rp["tags"][:6] if isinstance(x, dict) and x.get("content-type")]
    if "prog_type" in g:
        pc = rdsn_pty(g.get("prog_type"))
        if pc == 31:
            if not s.get("pty31_since") or now - s.get("pty31_last", 0) > 120:
                s["pty31_since"], s["pty31_n"], s["pty31_persist"] = int(now), 0, 0
                self.evl.add("pty31", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 31 (Alarm) gesehen", persist=False)
            s["pty31_n"] = s.get("pty31_n", 0) + 1
            s["pty31_last"] = int(now)
            if not s.get("pty31_persist") and s["pty31_n"] >= 3 and now - s["pty31_since"] >= PTY31_PERSIST_S:
                s["pty31_persist"] = 1
                self.evl.add("pty31", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 31 (Alarm) dauerhaft seit %d s" % int(now - s["pty31_since"]), persist=True)
                self.warn(name, "PTY31", "RDS PTY 31 Alarm (dauerhaft)", now)
        else:
            s["pty31_since"], s["pty31_persist"] = 0, 0
        if pc == 30:
            if not s.get("pty30_since") or now - s.get("pty30_last", 0) > 120:
                s["pty30_since"], s["pty30_n"], s["pty30_persist"] = int(now), 0, 0
                self.evl.add("pty30", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 30 (Alarmtest) gesehen - Test, kein Alarm", persist=False, test=True)
            s["pty30_n"] = s.get("pty30_n", 0) + 1
            s["pty30_last"] = int(now)
            if not s.get("pty30_persist") and s["pty30_n"] >= 3 and now - s["pty30_since"] >= PTY31_PERSIST_S:
                s["pty30_persist"] = 1
                self.evl.add("pty30", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 30 Alarmtest dauerhaft seit %d s - Test, kein Alarm" % int(now - s["pty30_since"]), persist=True, test=True)
        else:
            s["pty30_since"], s["pty30_persist"] = 0, 0
    rt = g["radiotext"].strip()[:80] if isinstance(g.get("radiotext"), str) else None
    rt_new_stable = False
    if rt:
        sn = self.rt_seen.get(name)
        if sn and sn[0] == rt:
            sn[1] += 1
        else:
            sn = self.rt_seen[name] = [rt, 1]
        if sn[1] == 2:       # vollstaendig (redsea: ganze Nachricht) und 2x gleich empfangen = stabil
            rt_new_stable = True
            s["rt_ok"], s["rt_ok_t"] = rt, int(now)
    if g.get("ta") is True and s.get("tp"):
        s["ta_t"] = int(now)
        self.warn(name, "TA", "Durchsage aktiv (TA)", now)
        if name not in self.ta_open:
            e = self.evl.add("ta", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), open=True, rt=[x for x in (s.get("rt"),) if x])
            self.ta_open[name] = e["id"]
    elif g.get("ta") is False and name in self.ta_open:
        self.ta_close(name, now)
    if rt and rt != self.last_rt.get(name):
        self.last_rt[name] = rt
        if name in self.ta_open:
            self._rt_into(self.ta_open[name], rt)
        elif name in self.ta_post and now <= self.ta_post[name][1]:
            self._rt_into(self.ta_post[name][0], rt)
    if rt_new_stable:
        sc = _ws_score(rt, s.get("rtp"))
        if sc["cls"] or WARN_WORDS.search(rt):
            self.evl.add("rt_warn", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text=rt, cls=sc["cls"], why=sc["why"][:80])
        if sc["cls"] == "rot":
            self.warn(name, "RT", rt, now)
    # rdsNotfall: redsea "ews" = Gruppe 1A Slow Labelling Variante 7 = nur Kennung des EWS-Kanals (wird im Normalbetrieb gesendet) -> nie Notfall
    if "ews" in g:
        v = g.get("ews")
        s["ews_eci"], s["ews_eci_t"] = (v if isinstance(v, int) and not isinstance(v, bool) else str(v)[:12]), int(now)
        _rdsn_rej(s, "1A_kennung", now)
    oda = g.get("open_data_app")
    if isinstance(oda, dict) and str(oda.get("oda_group") or "").upper() == "9A":
        s["oda9a"], s["oda9a_t"] = str(oda.get("app_name") or "?")[:40], int(now)
    if str(g.get("group") or "").upper() == "9A":
        q9 = getattr(self, "_rdsn9a", None)
        if not isinstance(q9, dict):
            q9 = self._rdsn9a = {}
        if "open_data_app" in g or "unknown_oda" in g or (s.get("oda9a") and now - (s.get("oda9a_t") or 0) < RDSN_ODA_KEEP_S):
            _rdsn_rej(s, "9A_oda", now)
        else:
            q = [t for t in (q9.get(name) or []) if 0 <= now - t <= RDSN_EWS9A_WIN_S] + [now]
            q9[name] = q[-20:]
            if len(q) < RDSN_EWS9A_N:
                _rdsn_rej(s, "9A_einzeln", now)
            else:
                if now - self.last_ann.get("ews:" + name, 0) > 1800:
                    self.evl.add("ews", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), ews9a=True, n=len(q),
                                 text="RDS-Notfallgruppe 9A empfangen (%dx in %d s)" % (len(q), int(now - q[0])))
                self.last_ann["ews:" + name] = now
                self.warn(name, "EWS", "RDS-Notfallgruppe 9A empfangen", now)
    self.d["fm"][name] = s
    self.dirty = True
    return s


StateBC.on_rds = _rdsn_on_rds


def selftest_rdsnotfall():
    import tempfile
    assert rdsn_pty("Alarm") == 31 and rdsn_pty("Alarm test") == 30 and rdsn_pty(" alarm  TEST ") == 30 and rdsn_pty("Finance") is None
    assert rdsn_pty(31) == 31 and rdsn_pty(30) == 30 and rdsn_pty(17) == 17 and rdsn_pty(True) is None and rdsn_pty("Emergency") == 31 and rdsn_pty("Alarmanlage") is None
    tmp = tempfile.mkdtemp()
    T = 1790000000
    b = StateBC(tmp)
    ks = lambda: [x["k"] for x in b.evl.ev]
    wk = lambda: [w["kind"] for w in b.d["warn"]]
    for i in range(6):     # Fall 12:02: PI 0xD315, PS BR24, PTY Finance, TA dauernd, RT leer
        b.on_rds("BR24", "102.0M", '{"pi":"0xD315","group":"0A","tp":true,"ta":true,"ps":"BR24","prog_type":"Finance"}', now=T + 1000 + i)
    assert "ews" not in ks() and "pty31" not in ks() and "pty30" not in ks() and wk() == ["TA"], (ks(), wk())
    b.on_rds("BR24", "102.0M", '{"pi":"0xD315","group":"1A","ews":1234,"prog_type":"Finance"}', now=T + 1010)
    assert "ews" not in ks() and b.d["fm"]["BR24"]["ews_rej"]["1A_kennung"] == 1 and b.d["fm"]["BR24"]["ews_eci"] == 1234
    b.on_rds("BR24", "102.0M", '{"pi":"0xD315","group":"9A","prog_type":"News"}', now=T + 1020)
    b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"9A","prog_type":"News"}', now=T + 1100)
    assert "ews" not in ks() and b.d["fm"]["BR24"]["ews_rej"]["9A_einzeln"] == 2 and "EWS" not in wk(), ks()   # einzelne 9A (Bitfehler) -> kein Notfall
    for i in range(3):
        b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"9A"}', now=T + 1200 + 5 * i)
    ev = [x for x in b.evl.ev if x["k"] == "ews"]
    assert len(ev) == 1 and ev[0]["ews9a"] is True and ev[0]["n"] == 3 and "EWS" in wk(), ev
    os.makedirs(os.path.join(tmp, "c"), exist_ok=True)
    c = StateBC(os.path.join(tmp, "c"))
    c.on_rds("X", "99.0M", '{"pi":"0xD999","group":"3A","open_data_app":{"oda_group":"9A","app_name":"Test-ODA"}}', now=T + 2000)
    for i in range(4):
        c.on_rds("X", "99.0M", '{"pi":"0xD999","group":"9A","unknown_oda":{"raw_data":"00"}}', now=T + 2001 + i)
    c.on_rds("X", "99.0M", '{"pi":"0xD999","group":"9A"}', now=T + 2010)
    assert [x for x in c.evl.ev if x["k"] == "ews"] == [] and c.d["fm"]["X"]["ews_rej"]["9A_oda"] == 5
    for tt in (0, 10, 20, 31):
        b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","prog_type":"Alarm"}', now=T + 3000 + tt)
    p31 = [x for x in b.evl.ev if x["k"] == "pty31"]
    assert [x["persist"] for x in p31] == [False, True] and b.d["fm"]["BR24"]["pty31_persist"] == 1 and "PTY31" in wk(), p31
    b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","prog_type":"News"}', now=T + 3040)
    assert b.d["fm"]["BR24"]["pty31_persist"] == 0
    n31, nw = len(p31), len(b.d["warn"])
    for tt in (0, 10, 20, 31):
        b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","prog_type":"Alarm test"}', now=T + 4000 + tt)
    p30 = [x for x in b.evl.ev if x["k"] == "pty30"]
    assert [x["persist"] for x in p30] == [False, True] and all(x["test"] for x in p30) and b.d["fm"]["BR24"]["pty30_persist"] == 1, p30
    assert len([x for x in b.evl.ev if x["k"] == "pty31"]) == n31 and b.d["fm"]["BR24"]["pty31_persist"] == 0 and len(b.d["warn"]) == nw   # Test ist kein Alarm, keine Warnung
    for _ in range(2):
        b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Amtliche Gefahrendurchsage: Fenster und Tueren schliessen"}', now=T + 5000)
    assert [x for x in b.evl.ev if x["k"] == "rt_warn"], ks()
    print("selftest rdsNotfall ok (TA allein kein Notfall, PTY Finance/1A-Kennung/einzelne 9A/ODA-9A verworfen, 9A 3x = Notfall, PTY 31 = Alarm, PTY 30 = Test, RT-Warnwort)", flush=True)
# ===== /rdsNotfall =====
RNSDR_EOF
EXPECT_BD="d54f59ef004c037d5e079e0dad7651b838bb9c483c4b834dea1d6efc4008f5a6"
cat > "$W/rn_dash_block.py" << 'RNDASH_EOF'
# ===== rdsNotfall: BR24-Zeile/Rundfunk/Funk-Kachel - "RDS Notfall" nur noch bei bestaetigter 9A-Notfallgruppe (ews9a von prepper-sdr rdsNotfall), alte unbestaetigte EWS-Ereignisse/Warnungen (TA, PTY Finance, 1A-Kennung, Einzelgruppe) zaehlen nicht; PTY 30 = Test (grau); nur lesen/anzeigen, sendet nichts =====
_rdsn_items0 = _br24_items
_rdsn_sdrf0 = _sdrf_data
_rdsn_bc0 = _sdrp_bc
RDSN_EWS_TXT = "RDS-Notfallgruppe 9A empfangen"


def _rdsn_ews_ok(e):
    return isinstance(e, dict) and e.get("k") == "ews" and e.get("ews9a") is True


def _br24_items(b, events, m):
    """wie br24Warn2, aber EWS nur bestaetigt (9A mehrfach) und PTY 30 als Test."""
    ev = [e for e in (events or []) if not (isinstance(e, dict) and e.get("k") == "ews" and not _rdsn_ews_ok(e))]
    it = _rdsn_items0(b, ev, m)
    for e in ev:
        if isinstance(e, dict) and e.get("k") == "pty30" and e.get("persist") and isinstance(e.get("t"), (int, float)) and _br24_ev_src(dict(e, k="pty31"), m):
            it.append({"t": e["t"], "src": "BR24 UKW", "kind": "RDS PTY 30 Alarmtest", "text": e.get("text") or "PTY 30 Alarmtest", "cls": "test", "score": "PTY 30 = Test"})
    return it


def _sdrf_data():
    """/rundfunk: unbestaetigte EWS-Ereignisse nicht mehr rot (nur als verworfen gelistet), PTY 30 als Alarmtest."""
    d = _rdsn_sdrf0()
    evs = []
    for e in d.get("events") or []:
        if isinstance(e, dict) and e.get("k") == "ews" and not _rdsn_ews_ok(e):
            e = dict(e, k="RDS verworfen", text="%s - kein Notfall (keine bestaetigte 9A-Gruppe)" % (e.get("text") or "RDS-Gruppe"))
        elif isinstance(e, dict) and e.get("k") == "pty30":
            e = dict(e, k="RDS Alarmtest")
        evs.append(e)
    d["events"] = evs
    return d


def _sdrp_bc():
    """Funk-Kachel/Status: alte EWS-Warnung ohne Bestaetigung ausblenden."""
    d = _rdsn_bc0()
    d["warn"] = [x for x in (d.get("warn") or []) if not (isinstance(x, dict) and x.get("kind") == "EWS" and x.get("text") != RDSN_EWS_TXT)]
    return d


def _rdsn_selftest():
    now = 179 * 10 ** 7
    b = {"fm": {"BR24": {"name": "BR24", "f": "102.0M", "pi": "0xD315", "ps": "BR24", "t": now - 60, "pty": "Finance", "ta": True, "tp": True, "rt": ""}}, "dab": {}}
    ta = {"t": now - 30, "k": "ta", "src": "BR24", "ps": "BR24", "pi": "0xD315"}
    old = {"t": now - 20, "k": "ews", "src": "BR24", "ps": "BR24", "pi": "0xD315", "f": "102.0M", "text": "RDS-Notfallgruppe empfangen"}
    r = _br24_eval(b, [ta, old], now)
    assert r["state"] == "gruen" and "Notfall" not in r["text"], r                                    # TA + alte EWS (Fall 12:02) -> kein Notfall
    r = _br24_eval(b, [ta, dict(old, ews9a=True, n=3, text=RDSN_EWS_TXT + " (3x in 10 s)")], now)
    assert r["state"] == "rot" and r["why"]["kind"] == "RDS Notfall", r
    r = _br24_eval(b, [{"t": now - 10, "k": "pty31", "src": "BR24", "ps": "BR24", "persist": True}], now)
    assert r["state"] == "rot" and r["why"]["kind"].startswith("RDS PTY 31"), r
    r = _br24_eval(b, [{"t": now - 10, "k": "pty30", "src": "BR24", "ps": "BR24", "persist": True, "test": True, "text": "RDS PTY 30 Alarmtest"}], now)
    assert r["state"] == "grau" and r["test"] and "Test" in r["text"], r
    assert _br24_eval(b, [{"t": now - 10, "k": "pty30", "src": "BR24", "ps": "BR24", "persist": False}], now)["state"] == "gruen"
    assert _br24_eval(b, [{"t": now - 10, "k": "pty30", "src": "Bayern 3", "ps": "BAYERN 3", "pi": "0xD313", "persist": True}], now)["state"] == "gruen"
    assert _br24_eval(b, [ta], now)["state"] == "gruen"
    return "rdsNotfall selftest ok (TA/alte EWS kein Notfall, 9A bestaetigt rot, PTY 31 rot, PTY 30 Test)"


try:
    print("rdsNotfall aktiv: %s" % _rdsn_selftest(), flush=True)
except Exception as _rdsn_e:
    _br24_items, _sdrf_data, _sdrp_bc = _rdsn_items0, _rdsn_sdrf0, _rdsn_bc0
    print("rdsNotfall FEHLER (alter Stand aktiv):", repr(_rdsn_e)[:300], flush=True)
# ===== /rdsNotfall =====
RNDASH_EOF
EXPECT_PS="3309456a02932762cb24272351bc25610014dce4611b0446d6c10a46c442a29c"
cat > "$W/patch-rn-sdr.py" << 'RNPS_EOF'
"""rdsNotfall: Block in prepper_sdr.py direkt nach /dabGain einsetzen oder ersetzen (idempotent).
Aufruf: patch-rn-sdr.py QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== rdsNotfall:", "# ===== /rdsNotfall =====\n"
ANCHOR = "# ===== /dabGain =====\n"
ST0, ST1 = "        selftest_dabgain()\n", "        selftest_rdsnotfall()\n"
NEED = ("class StateBC:", "    def on_rds(self, name, freq, line, now=None):", "    def warn(self, src, kind, text, now):", "    def ta_close(self, name, now, why=None):",
        "    def _rt_into(self, eid, rt):", "    def add(self, k, src, now, **kw):", "PTY31_PERSIST_S = ", "WARN_WORDS = ", "def _ws_score(", "self.last_ann = {}",
        "self.ta_post = {}", "self.rt_seen = {}", "if self.sbc.on_rds(st[\"name\"], st[\"f\"], line):", "# ===== dabGain:", "# ===== dabFix:", "# ===== lageDB:")
bad = [n.strip()[:40] for n in NEED if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if s.count(ST0) != 1:
    bad.append("selftest_dabgain() x%d" % s.count(ST0))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("rdsNotfall-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
if "StateBC.on_rds = " in s.replace(s[s.index(A):s.index(Z) + len(Z)] if A in s and Z in s else "", ""):
    bad.append("on_rds wird schon anderswo ersetzt")
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: rdsNotfall-Block steht nicht direkt nach /dabGain"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
if ST1 not in s2:
    s2 = s2.replace(ST0, ST0 + ST1, 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
RNPS_EOF
EXPECT_PD="989d7d3a434dc97921d4b3235faba68fc1147579f27f01b6f5fe740795fed254"
cat > "$W/patch-rn-dash.py" << 'RNPD_EOF'
"""rdsNotfall: Block in dashboard.py direkt nach /lageGeo einsetzen oder ersetzen (idempotent).
Aufruf: patch-rn-dash.py QUELLE ZIEL BLOCKDATEI -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
A, Z = "# ===== rdsNotfall:", "# ===== /rdsNotfall =====\n"
ANCHOR = "# ===== /lageGeo =====\n"
MAIN = "\nif __name__ == \"__main__\":\n"
NEED = ("# ===== br24Warn2:", "# ===== /br24Warn2 =====", "def _br24_items(b, events, m):", "def _br24_eval(b, events, now=None):", "def _br24_ev_src(e, m):",
        "_br24_orig_sdrf_data = _sdrf_data", "def _sdrf_data():", "def _sdrp_bc():", "# ===== lageDB:", "# ===== lageGeo:", MAIN)
bad = [n.strip()[:40] for n in NEED if s.count(n) < 1]
if s.count(ANCHOR) != 1:
    bad.append("%s x%d" % (ANCHOR.strip(), s.count(ANCHOR)))
if s.count(A) > 1 or s.count(Z) != s.count(A):
    bad.append("rdsNotfall-Marker kaputt (%d/%d)" % (s.count(A), s.count(Z)))
if not bad and (s.index(ANCHOR) > s.rindex(MAIN) or s.index("# ===== /br24Warn2 =====") > s.index(ANCHOR)):
    bad.append("Reihenfolge br24Warn2 < /lageGeo < __main__ stimmt nicht")
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
if A in s:
    a = s.index(A); b = s.index(Z, a) + len(Z)
    if s.index(ANCHOR) + len(ANCHOR) != a:
        print("Basis passt nicht: rdsNotfall-Block steht nicht direkt nach /lageGeo"); raise SystemExit(3)
    s2 = s[:a] + blk + s[b:]
else:
    s2 = s.replace(ANCHOR, ANCHOR + blk, 1)
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
RNPD_EOF
EXPECT_GUARD="73e06e1a76173b1c1a0a9a2de7b180a7d93c0fb50f2800916865060939e6c913"
cat > "$W/guard_rn.py" << 'RNGUARD_EOF'
"""rdsNotfall AST-Guard. Aufruf: guard_rn.py SDR_ALT SDR_NEU DASH_ALT DASH_NEU -> 0 ok, 1 Verstoss.
Nur je ein Block neu (+ Aufruf selftest_rdsnotfall), keine neuen Importe ausser tempfile im Selbsttest, kein shell=True,
keine Sende-/Socket-/Server-/Prozess-/Faden-/Netz-/Datei-Loesch-Aufrufe, kein Mesh."""
import ast
import sys

RISKY = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "sendText", "sendData", "TCPInterface", "SerialInterface", "urlopen",
         "socket", "create_connection", "bind", "listen", "connect", "serve_forever", "HTTPServer", "make_server", "system", "Popen", "run", "call", "check_output",
         "check_call", "execv", "spawn", "fork", "Thread", "Timer", "start_new_thread", "kill", "killpg", "_dev", "write_json", "remove", "unlink", "rmtree",
         "add_url_rule", "route", "after_request")
NETMOD = {"requests", "urllib", "http", "socket", "subprocess", "signal", "threading", "shutil", "meshtastic"}


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


def cut(s, A, Z):
    if A not in s:
        return ""
    a = s.index(A)
    return s[a:s.index(Z, a) + len(Z) + 1]


rd = lambda f: open(f, encoding="utf-8").read()
s0, s1, d0, d1 = (rd(x) for x in sys.argv[1:5])
A, Z = "# ===== rdsNotfall:", "# ===== /rdsNotfall ====="
err = []
for lab, o, n, extra in (("prepper_sdr", s0, s1, "        selftest_rdsnotfall()\n"), ("dashboard", d0, d1, None)):
    if n.count(A) != 1 or n.count(Z) != 1:
        err.append("%s: rdsNotfall-Marker nicht genau 1x" % lab); continue
    blk, old = cut(n, A, Z), cut(o, A, Z)
    r0, r1 = (o.replace(old, "") if old else o), n.replace(blk, "")
    if extra:
        r0, r1 = r0.replace(extra, ""), r1.replace(extra, "")
    if r0 != r1:
        err.append("%s: ausserhalb des rdsNotfall-Blocks geaendert" % lab)
    bi, _, bs, _ = info(o)
    ni, _, ns, _ = info(n)
    if ni != bi:
        err.append("%s: Importe geaendert %s" % (lab, ni ^ bi))
    if ns != bs:
        err.append("%s: shell=True geaendert" % lab)
    ki, kc, ks, ka = info(blk)
    if ks:
        err.append("%s: Block mit shell=" % lab)
    for nm in RISKY:
        if nm in kc:
            err.append("%s: Block ruft %s" % (lab, nm))
    if ki - {"tempfile"}:
        err.append("%s: Block importiert %s" % (lab, ki - {"tempfile"}))
    if [x for x in ka if x[0] in NETMOD]:
        err.append("%s: Block Netz-/Prozessaufruf %s" % (lab, [x for x in ka if x[0] in NETMOD]))
    low = blk.lower()
    for w in ("mesh", "transmit", "popen", "subprocess", "socket", "requests", "urllib", "send(", ".send", "sendtext", "open(", "<script"):
        if w in low:
            err.append("%s: Block enthaelt %s" % (lab, w))
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard rdsNotfall: je 1 Block in prepper_sdr.py und dashboard.py + Selbsttest-Aufruf, sonst nichts geaendert; keine neuen Importe, kein shell=True, "
      "keine Sende-/Mesh-/Socket-/Server-/Prozess-/Faden-/Netz-/Loesch-Aufrufe, kein JS")
RNGUARD_EOF
EXPECT_SHOW="bc3b58e2dd367ededbdfde4d7790dd4e8e95be4a4f71c9c3b1ac1d4dbe5553a2"
cat > "$W/show_rn.py" << 'RNSHOW_EOF'
"""rdsNotfall Anzeige (nur lesen).
show_rn.py events EVENTS_JSON            -> 0 wenn kein unbestaetigtes EWS-Ereignis mehr als 'ews' ausgeliefert wird
show_rn.py br24 BR24_JSON BSTATE         -> BR24-Zeile, Grund, RDS-Zustand BR24
show_rn.py dab BSTATE T0 [--final]       -> 0 wenn 11D seit T0 neu geprueft; zeigt 11D/5C + Gain-Leiter"""
import json
import sys
import time


def ld(f):
    try:
        return json.load(open(f, encoding="utf-8"))
    except Exception:
        return {}


def ts(t):
    try:
        return time.strftime("%d.%m. %H:%M:%S", time.localtime(float(t))) if t else "-"
    except Exception:
        return str(t)


a = sys.argv[1]
fin = "--final" in sys.argv
args = [x for x in sys.argv[2:] if x != "--final"]
if a == "events":
    d = ld(args[0])
    ev = d.get("events") if isinstance(d.get("events"), list) else None
    if ev is None:
        print("  /api/broadcast/events: keine Ereignisliste"); sys.exit(1)
    bad = [e for e in ev if isinstance(e, dict) and e.get("k") == "ews" and e.get("ews9a") is not True]
    rej = [e for e in ev if isinstance(e, dict) and e.get("k") == "RDS verworfen"]
    ok9 = [e for e in ev if isinstance(e, dict) and e.get("k") == "ews" and e.get("ews9a") is True]
    print("  /api/broadcast/events: %d Ereignisse, alte EWS jetzt 'verworfen' %d, bestaetigte 9A-Notfaelle %d, unbestaetigt noch rot %d" % (len(ev), len(rej), len(ok9), len(bad)))
    sys.exit(1 if bad else 0)
if a == "br24":
    r, b = ld(args[0]), ld(args[1])
    w = r.get("why") if isinstance(r.get("why"), dict) else None
    print("  BR24-Zeile: %s (Zustand %s%s)" % (r.get("text"), r.get("state"), ", Test" if r.get("test") else ""))
    print("  Grund: %s" % (("%s · %s · %s · „%s“" % (w.get("src"), w.get("kind"), w.get("t_txt"), w.get("text"))) if w else "keiner (keine Warnung aktiv)"))
    br = r.get("br24_row") if isinstance(r.get("br24_row"), dict) else {}
    if br:
        print("  br24_row: %s / %s" % (br.get("l1"), br.get("l2")))
    s = (b.get("fm") or {}).get("BR24") or {}
    print("  RDS BR24 %s: zuletzt %s, PI %s, PS %s, PTY %s, TA %s, RT '%s', PTY31 dauerhaft %s, PTY30 dauerhaft %s" % (
        s.get("f"), ts(s.get("t")), s.get("pi"), s.get("ps"), s.get("pty"), s.get("ta"), s.get("rt") or "", s.get("pty31_persist"), s.get("pty30_persist")))
    print("  verworfene Notfall-Ausloeser BR24 (seit Einspielen): %s; 1A-EWS-Kennung %s; 9A als ODA %s" % (
        json.dumps(s.get("ews_rej") or {}, ensure_ascii=False), s.get("ews_eci", "-"), s.get("oda9a", "-")))
    sys.exit(0)
if a == "dab":
    b, t0 = ld(args[0]), float(args[1])
    dab = b.get("dab") or {}
    e11 = dab.get("11D") or {}
    new11 = ((e11.get("demod") or {}).get("t") or 0) >= t0
    if not new11 and not fin:
        sys.exit(2)
    for ch in ("11D", "5C"):
        e = dab.get(ch) or {}
        g = e.get("demod") or {}
        neu = (g.get("t") or 0) >= t0
        sync = e.get("rx") is not False and bool(e.get("services")) and str(g.get("ens_id") or "") != "0x0000"
        print("  DAB %s: %s, Pruefung %s (%s), SNR %s, Stufe %s (%s dB), welle-Gain %s, Ensemble '%s', Dienste %d%s" % (
            ch, "Sync ja" if sync else "KEIN SYNC", ts(g.get("t") or e.get("t")), "neu" if neu else "alt", g.get("snr"), g.get("gain_idx"), g.get("gain_db"),
            g.get("hw_gain"), e.get("ensemble") or "", len(e.get("services") or []), (" - " + str(e.get("rx_why"))) if e.get("rx") is False and e.get("rx_why") else ""))
    print("  Gain-Leiter (dabgain): %s" % json.dumps(b.get("dabgain"), ensure_ascii=False)[:400])
    sys.exit(0 if new11 else 2)
sys.exit(1)
RNSHOW_EOF
PS_="$W/patch-rn-sdr.py"; PD="$W/patch-rn-dash.py"; BS="$W/rn_sdr_block.py"; BD="$W/rn_dash_block.py"; SG="$W/guard_rn.py"; SH="$W/show_rn.py"
for x in "$EXPECT_BS $BS" "$EXPECT_BD $BD" "$EXPECT_PS $PS_" "$EXPECT_PD $PD" "$EXPECT_GUARD $SG" "$EXPECT_SHOW $SH"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis (sha16 bekannt oder Guards erkannt) ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
case " $KNOWN_SDR16 " in *" $S16 "*) KN=bekannt;; *) KN="neu, Erkennung ueber Guards";; esac
case " $KNOWN_DASH16 " in *" $D16 "*) KD=bekannt;; *) KD="neu, Erkennung ueber Guards";; esac
echo "Basis prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $KN); dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $KD)"
python3 "$PS_" "$M" "$W/work/prepper_sdr.py" "$BS" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
python3 "$PD" "$F" "$W/work/dashboard.py" "$BD" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: prepper_sdr Guards dabGain/dabFix/lageDB, Anker /dabGain genau 1x, on_rds nicht anderswo ersetzt -> $(cat "$W/p1.log"); Dashboard Guards br24Warn2/lageDB/lageGeo, Anker /lageGeo genau 1x -> $(cat "$W/p2.log")"
for u in prepper-sdr prepper-dashboard; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - erst Dienst pruefen, nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
python3 "$PS_" "$W/work/prepper_sdr.py" "$W/work/s2.py" "$BS" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/s2.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
python3 "$PD" "$W/work/dashboard.py" "$W/work/d2.py" "$BD" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: Dashboard nicht idempotent"; exit 1; }
rm -f "$W/work/s2.py" "$W/work/d2.py"
for py in "$SPY" "$VPY"; do
  "$py" -W error -m py_compile "$W/work/prepper_sdr.py" || { echo "STOP: py_compile prepper_sdr ($py) - nichts geaendert"; exit 1; }
  "$py" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile dashboard ($py) - nichts geaendert"; exit 1; }
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest rdsNotfall ok" "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest dabHist ok" "selftest br24Warn2 ok" "selftest OK:"; do
    [[ "$(cat "$W/selftest.log")" == *"$k"* ]] || { echo "STOP: Selbsttest ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY (Sandbox): $(grep 'selftest rdsNotfall ok' "$W/selftest.log" | head -1)"
python3 "$SG" "$M" "$W/work/prepper_sdr.py" "$F" "$W/work/dashboard.py" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons, beide Dateien)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/api/br24" -o "$W/br24_0.json" || true
echo "BR24 vorher:"; python3 "$SH" br24 "$W/br24_0.json" "$DASH_DIR/broadcast_state.json" || true
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK rdsNotfall schon installiert - kein Neustart"
  T0=$(python3 -c "import json;print(int(json.load(open('$DASH_DIR/sdr_status.json')).get('started') or 0))" 2>/dev/null || echo 0)
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "rdsNotfall|Traceback|Error" | tail -8 | cut -c1-200 || true
    sudo journalctl -u prepper-sdr --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "rdsNotfall|Traceback|Error" | tail -8 | cut -c1-200 || true
    for x in "$M" "$F"; do [[ -f "$x.bak-rdsnotfall-$TS" ]] && cp -a "$x.bak-rdsnotfall-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    for x in "$M" "$F"; do cmp -s "$x" "$x.bak-rdsnotfall-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "$M" "$F" "$DASH_DIR/broadcast_state.json" "$DASH_DIR/broadcast_events.jsonl"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-rdsnotfall-$TS"
    { ls -1t "$x.bak-rdsnotfall-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-rdsnotfall-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-rdsnotfall-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
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
for p in /api/sdr/ui /api/br24 /api/sdr/live /api/broadcast/events; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
c=$(code -X POST "$B/api/br24"); [[ "$c" == 405 ]] && echo "OK POST /api/br24 abgelehnt (405)" || rbx "POST /api/br24 nicht abgelehnt ($c)"
sleep 5
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
sdr_fresh "$T0" || rbx "SDR-Status nicht frisch"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "rdsNotfall" | tail -3 || true)
if [[ "$JD" == *"rdsNotfall FEHLER"* ]]; then rbx "Dashboard: $JD"; fi
if [[ "$JD" == *"rdsNotfall aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | tail -1 | cut -c1-160)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet rdsNotfall nicht (Journal)"; fi
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|on_rds|_rdsn" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/on_rds-Fehler" || rbx "$E Traceback/on_rds-Zeilen im Journal prepper-sdr"
"${CURL[@]}" "$B/api/broadcast/events" -o "$W/ev.json" || true
python3 "$SH" events "$W/ev.json" || rbx "/api/broadcast/events liefert noch unbestaetigte EWS als Notfall"
"${CURL[@]}" "$B/api/br24" -o "$W/br24_1.json" || true
python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get('state') in ('gruen','rot','grau') and d.get('text'), d
" "$W/br24_1.json" || rbx "/api/br24 ungueltig"
echo "OK guards rdsNotfall(sdr)=$(grep -c '# ===== rdsNotfall:' "$M" || true) rdsNotfall(dash)=$(grep -c '# ===== rdsNotfall:' "$F" || true) dabGain=$(grep -c '# ===== dabGain:' "$M" || true) dabFix=$(grep -c '# ===== dabFix:' "$M" || true) lageDB(sdr)=$(grep -c '# ===== lageDB:' "$M" || true) dabHist(sdr)=$(grep -c '# ===== dabHist:' "$M" || true) stickTestFix(sdr)=$(grep -c '# ===== stickTestFix:' "$M" || true) br24Warn2(dash)=$(grep -c '# ===== br24Warn2:' "$F" || true) lageDB(dash)=$(grep -c '# ===== lageDB:' "$F" || true) lageGeo(dash)=$(grep -c '# ===== lageGeo:' "$F" || true)"
[[ -f "$M.bak-rdsnotfall-$TS" ]] && echo "Backups: *.bak-rdsnotfall-$TS (prepper_sdr.py, dashboard.py, broadcast_state.json, broadcast_events.jsonl), behalten: letzte $KEEP_LAST"
echo "prepper_sdr.py sha16 jetzt $(sha256sum "$M" | cut -c1-16), $(wc -l < "$M") Zeilen; dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG rdsNotfall=1 - Einspielen fertig. Jetzt nur noch Anzeige: Warten ist ungefaehrlich, Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, rdsNotfall bleibt aktiv. COMMIT $COMMIT_ARG rdsNotfall=1"; exit 0' INT
echo "BR24 jetzt:"
python3 "$SH" br24 "$W/br24_1.json" "$DASH_DIR/broadcast_state.json" || true
echo "Warte auf frische DAB-Pruefung 11D (max $DAB_WAIT_S s, Rundfunk-Block ca. 2 min nach Neustart) ..."
t=0; dd=0
while [[ "$t" -lt "$DAB_WAIT_S" ]]; do
  if python3 "$SH" dab "$DASH_DIR/broadcast_state.json" "$T0" > "$W/dab.txt" 2>/dev/null; then dd=1; echo "DAB-Pruefung nach $t s:"; cat "$W/dab.txt"; break; fi
  systemctl is-active --quiet prepper-sdr || { echo "WARNUNG: prepper-sdr laeuft nicht mehr - bitte melden"; break; }
  sleep 15; t=$((t + 15))
  [[ $((t % 120)) == 0 ]] && echo "  ... $t s"
done
[[ "$dd" == 1 ]] || { echo "DAB: 11D nach $DAB_WAIT_S s noch nicht neu geprueft, letzter Stand:"; python3 "$SH" dab "$DASH_DIR/broadcast_state.json" "$T0" --final || true; }
"${CURL[@]}" "$B/api/br24" -o "$W/br24_2.json" || true
echo "BR24 nach Rundfunk-Block:"
python3 "$SH" br24 "$W/br24_2.json" "$DASH_DIR/broadcast_state.json" || true
echo "COMMIT $COMMIT_ARG rdsNotfall=1 fertig"
