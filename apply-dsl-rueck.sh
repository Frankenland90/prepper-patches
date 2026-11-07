#!/bin/bash
# shellcheck disable=SC2015
set -euo pipefail
# dslRueck: DSL-Voralarm in der Lage-Ampel endet nur, wenn der Uplink wieder Telekom ist,
# frisch (nicht stale), seit 300 s ohne laufenden Wechsel, und die bestehende
# Frequenzpruefung t4_freq_eval stabil ist (300 s im Band 49,950-50,050 Hz).
# NETZ, SDR_OFFLINE, Echtalarm und NINA bleiben. pre.on bleibt an. Stick 2 bleibt
# gekapert, bis der bestehende Knopf "SDR 2 freigeben" gedrueckt wird.
# Kein Loeschen von teil4_state.json / uplink_state.json, kein Mesh-Versand.
# Aufruf auf dem Pi: bash apply-dsl-rueck.sh dslRueck
# Nur Tests:        bash apply-dsl-rueck.sh --selftest
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
W=$(mktemp -d /tmp/dslrueck.XXXXXX)
trap 'rm -rf "$W"' EXIT
ROOT=$(cd "$(dirname "$0")" && pwd)

cat > "$W/patch.py" << 'ENDPY'
# -*- coding: utf-8 -*-
"""dslRueck: nur die DSL-Art nehmen, wenn Telekom frisch gehalten ist und t4_freq_eval stabil ist."""
import ast
import os
import re
import sys

HOLD = 300  # gehaltener Telekom-Pfad; Frequenzstabilitaet kommt aus t4_freq_eval (T4_F_STABLE_S)

HELPERS = '''
# dslRueck: DSL-Art endet bei gehaltenem Telekom und stabiler Frequenz (t4_freq_eval). NETZ bleibt. Stick 2 nur per Knopf.
T4_DSL_RECOVER_S = 300

def _t4_dsl_recovered(us, freq, now):
    """True nur bei current telekom, stale genau False, kein Wechsel, since >= 300 s und freq.stable genau True."""
    if not isinstance(us, dict) or us.get("current") != "telekom" or us.get("stale") is not False:
        return False
    if not isinstance(freq, dict) or freq.get("stable") is not True:
        return False
    pend = us.get("pending")
    if pend not in (None, "", "telekom"):
        return False
    since = us.get("since")
    if isinstance(since, bool) or not isinstance(since, (int, float)):
        return False
    try:
        return float(now) - float(since) >= T4_DSL_RECOVER_S
    except Exception:
        return False


def _t4_dsl_drop(st, now):
    """Entfernt nur die Art DSL. pre.on bleibt an, damit die Knopf-Freigabe und die Stick-2-Sperre gelten. NETZ bleibt."""
    pre = st.get("pre") if isinstance(st, dict) else None
    if not isinstance(pre, dict) or not pre.get("on"):
        return False
    had = [k for k in (pre.get("kinds") or []) if isinstance(k, str)]
    if "DSL" not in had:
        return False
    kinds = [k for k in had if k != "DSL"]
    if kinds:
        parts = []
        for p in str(pre.get("why") or "").split(";"):
            s = p.strip()
            if not s or "Starlink" in s or "Telekom" in s:
                continue
            parts.append(s)
        pre["why"] = "; ".join(parts) if parts else "Netzfrequenz"
    else:
        pre["why"] = "DSL zurueck, Stick 2 nur per Knopf freigeben"
    pre["on"] = True
    pre["kinds"] = kinds
    st["pre"] = pre
    pend = st.get("pending")
    if isinstance(pend, dict):
        pend.pop("DSL", None)
    return True

'''

OLD = (
    '    e = _lz_mgr.t4_dsl_edge(_t4_us(), st.get("dsl_handled"), now)\n'
    '    if e:\n'
    '        st["dsl_handled"] = e["t"]\n'
    '        if not _t4_pre_on("DSL", "Telekom -> Starlink um %s" % _t4_time.strftime("%H:%M", _t4_time.localtime(e["t"])), now):\n'
    '            _t4_save()\n'
)

NEW = (
    '    us = _t4_us()\n'
    '    e = _lz_mgr.t4_dsl_edge(us, st.get("dsl_handled"), now)\n'
    '    if e:\n'
    '        st["dsl_handled"] = e["t"]\n'
    '        if not _t4_pre_on("DSL", "Telekom -> Starlink um %s" % _t4_time.strftime("%H:%M", _t4_time.localtime(e["t"])), now):\n'
    '            _t4_save()\n'
    '    fe = _lz_mgr.t4_freq_eval(list(_T4["fs"]), now)\n'
    '    if _t4_dsl_recovered(us, fe, now) and _t4_dsl_drop(st, now):  # dslRueck\n'
    '        _t4_save()\n'
    '        _t4_event("VORALARM", "dsl-ende", "info", "DSL-Voralarm beendet: Telekom gehalten und Frequenz stabil, Stick 2 bleibt bis zur Freigabe", now)\n'
    '        _t4_say("teil4: DSL-Voralarm beendet (Telekom zurueck). Stick 2 nicht automatisch freigegeben")\n'
)


def patch_text(text):
    if not isinstance(text, str):
        raise SystemExit("dslRueck: Dashboard-Text fehlt")
    has_fn = "def _t4_dsl_recovered(" in text
    has_call = "_t4_dsl_recovered(us, fe, now) and _t4_dsl_drop(st, now)" in text
    if has_fn or has_call or "\n# dslRueck:" in text:
        if has_fn and has_call and text.count("def _t4_dsl_recovered(") == 1 and text.count("def _t4_dsl_drop(") == 1 and text.count(OLD) == 0:
            return text, "schon"
        raise SystemExit("dslRueck: Markierung unvollstaendig - nichts geaendert")
    if text.count("def _t4_pre_tick(now):") != 1:
        raise SystemExit("dslRueck: def _t4_pre_tick nicht genau einmal - nichts geaendert")
    if text.count(OLD) != 1:
        raise SystemExit("dslRueck: DSL-Flanke nicht genau einmal gefunden - nichts geaendert")
    text = text.replace("def _t4_pre_tick(now):\n", HELPERS + "def _t4_pre_tick(now):\n", 1)
    text = text.replace(OLD, NEW, 1)
    if text.count("def _t4_dsl_recovered(") != 1 or text.count(OLD) != 0 or "_t4_dsl_drop(st, now)" not in text:
        raise SystemExit("dslRueck: Einbau unvollstaendig - nichts geaendert")
    ast.parse(text)
    return text, "neu"


def _extract(src, name):
    m = re.search(r"(?m)^def %s\(" % re.escape(name), src)
    if not m:
        raise SystemExit("Funktion %s fehlt" % name)
    n = re.search(r"(?m)^def ", src[m.end():])
    end = m.end() + n.start() if n else len(src)
    return src[m.start():end]


def _banner_ns(teil4_path):
    src = open(teil4_path, encoding="utf-8").read()
    start = src.find("T4_COLORS = {")
    if start < 0:
        raise SystemExit("T4_COLORS fehlt in %s" % teil4_path)
    chunk = src[start:]
    # Konstanten bis einschliesslich T4_DSL_MAX_AGE_S, dann die beiden Funktionen
    cut = chunk.find("\nT4_HB_MAX")
    head = chunk[:cut] + "\n"
    ns = {
        "WATCHDOG_S": 15,
        "is_own_test": lambda t: "keine echte Warnung" in str(t),
        "is_probe": lambda t: "Probe" in str(t) or "Probewarnung" in str(t),
    }
    ns["time"] = __import__("time")
    exec(head + _extract(src, "t4_level") + _extract(src, "t4_freq_eval") + _extract(src, "t4_dsl_edge") + _extract(src, "t4_release_ok"), ns)
    return ns


def selftest():
    ns = {}
    exec(HELPERS, ns)
    rec, drop = ns["_t4_dsl_recovered"], ns["_t4_dsl_drop"]
    assert ns["T4_DSL_RECOVER_S"] == HOLD
    now = 1790000000
    assert "takeover_set" not in HELPERS and "nina" not in HELPERS.lower()
    assert "pre[\"on\"] = False" not in HELPERS and "on=False" not in HELPERS

    def tele(since, stale=False, pending=None, current="telekom"):
        return {"current": current, "stale": stale, "pending": pending, "since": since, "history": []}

    okf = {"stable": True}
    assert rec(tele(now - HOLD), okf, now) is True
    assert rec(tele(now - HOLD + 1), okf, now) is False          # noch nicht gehalten
    assert rec(tele(now - 7200), okf, now) is True               # Stunden spaeter, weiter Telekom
    assert rec(tele(now - 7200, stale=True), okf, now) is False  # veraltet
    assert rec(tele(now - 7200, stale=None), okf, now) is False  # stale unbekannt
    assert rec({"current": "telekom", "since": now - 7200}, okf, now) is False
    assert rec(tele(now - 7200, current="starlink"), okf, now) is False
    assert rec(tele(now - 7200, current="unclear"), okf, now) is False
    assert rec(tele(now - 7200, current=None), okf, now) is False
    assert rec(None, okf, now) is False
    assert rec(tele(now - 7200, pending="starlink"), okf, now) is False
    assert rec(tele(now - 7200, pending="unclear"), okf, now) is False
    assert rec(tele(now - 7200, pending="telekom"), okf, now) is True
    assert rec(tele(True), okf, now) is False                    # since bool
    assert rec(tele(None), okf, now) is False
    assert rec(tele(now - HOLD), {"stable": False}, now) is False
    assert rec(tele(now - HOLD), None, now) is False
    assert rec(tele(now - HOLD), {}, now) is False
    assert rec(tele(now - HOLD), {"stable": 1}, now) is False

    def pre(kinds, why, on=True):
        return {"pre": {"on": on, "kinds": list(kinds), "since": now - 8000, "why": why},
                "pending": {"DSL": {"t": now}, "NETZ": {"t": now}}, "dsl_handled": now - 8000}

    st = pre(["DSL"], "Telekom -> Starlink um 01:09")
    assert drop(st, now) is True
    assert st["pre"]["on"] is True and st["pre"]["kinds"] == []
    assert st["pre"]["why"].startswith("DSL zurueck")
    assert "DSL" not in st["pending"] and "NETZ" in st["pending"]
    assert st["dsl_handled"] == now - 8000
    assert drop(st, now) is False                               # zweiter Lauf aendert nichts

    st = pre(["DSL", "NETZ"], "Telekom -> Starlink um 01:09; 49,700 Hz")
    assert drop(st, now) is True
    assert st["pre"]["on"] is True and st["pre"]["kinds"] == ["NETZ"] and st["pre"]["why"] == "49,700 Hz"
    st = pre(["NETZ", "DSL"], "49,700 Hz; Telekom -> Starlink um 01:09")
    assert drop(st, now) is True and st["pre"]["kinds"] == ["NETZ"] and st["pre"]["why"] == "49,700 Hz"
    st = pre(["NETZ"], "49,700 Hz")
    assert drop(st, now) is False and st["pre"]["kinds"] == ["NETZ"] and st["pre"]["on"] is True
    st = pre(["DSL"], "Telekom -> Starlink um 01:09", on=False)
    assert drop(st, now) is False and st["pre"]["on"] is False
    nina = {"title": "Trinkwasserverschmutzung"}
    st = pre(["DSL"], "Telekom -> Starlink um 01:09")
    assert drop(st, now) is True and nina["title"] == "Trinkwasserverschmutzung"

    # Ablauf: Ausfall, Starlink, kurzer Rueckwechsel, gehaltener Telekom, stale/unbekannt, NETZ bleibt
    edge_src = '''
T4_DSL_MAX_AGE_S = 1800
def t4_dsl_edge(us, handled_t, now=None):
    now = float(now or 0)
    if not isinstance(us, dict) or us.get("current") != "starlink":
        return None
    for h in reversed([x for x in us.get("history") or [] if isinstance(x, dict)]):
        t = h.get("t")
        if not isinstance(t, (int, float)):
            continue
        if h.get("to") == "starlink" and h.get("from") == "telekom" and (handled_t is None or t > handled_t) and now - t <= T4_DSL_MAX_AGE_S:
            return {"t": float(t), "why": str(h.get("why") or "")[:80]}
        if h.get("to") == "starlink":
            return None
    return None
'''
    ens = {}
    exec(edge_src, ens)
    edge = ens["t4_dsl_edge"]

    def latch(st, us, t, freq=None):
        if freq is None:
            freq = okf
        e = edge(us, st.get("dsl_handled"), t)
        if e and "DSL" not in st["pre"]["kinds"]:
            st["dsl_handled"] = e["t"]
            st["pre"]["on"] = True
            st["pre"]["kinds"] = sorted(set(st["pre"]["kinds"] + ["DSL"]))
            st["pre"]["since"] = st["pre"].get("since") or e["t"]
            st["pre"]["why"] = (st["pre"].get("why") + "; " if st["pre"].get("why") else "") + "Telekom -> Starlink um 01:09"
        if rec(us, freq, t) and drop(st, t):
            return "cleared"
        return "held"

    st = {"pre": {"on": False, "kinds": [], "since": None, "why": ""}, "pending": {"DSL": {"t": 1}}, "dsl_handled": None}
    fail = {"current": "starlink", "stale": False, "pending": None, "since": now - 60,
            "history": [{"t": now - 60, "from": "telekom", "to": "starlink", "why": "x"}]}
    assert latch(st, fail, now) == "held" and st["pre"]["kinds"] == ["DSL"] and st["pre"]["on"] is True
    assert edge(fail, st["dsl_handled"], now) is None                 # dieselbe Flanke nicht noch einmal
    brief = tele(now - 30)
    brief["history"] = fail["history"] + [{"t": now, "from": "starlink", "to": "telekom"}]
    assert latch(st, brief, now) == "held" and "DSL" in st["pre"]["kinds"]
    assert latch(st, tele(now - HOLD, stale=True), now) == "held"
    assert latch(st, {"current": None, "stale": False, "since": now - HOLD}, now) == "held"
    assert latch(st, {"current": "unclear", "stale": False, "since": now - HOLD, "pending": None}, now) == "held"
    assert latch(st, tele(now - HOLD), now, {"stable": False}) == "held" and "DSL" in st["pre"]["kinds"]
    assert latch(st, tele(now - HOLD), now) == "cleared"
    assert st["pre"]["on"] is True and st["pre"]["kinds"] == [] and "DSL" not in st["pending"]
    # neuer Ausfall nach der Ruecknahme loest wieder aus
    fail2 = {"current": "starlink", "stale": False, "pending": None, "since": now + 1000,
             "history": fail["history"] + [{"t": now + 1000, "from": "telekom", "to": "starlink"}]}
    assert latch(st, fail2, now + 1000) == "held" and st["pre"]["kinds"] == ["DSL"]
    stn = {"pre": {"on": True, "kinds": ["NETZ", "DSL"], "since": now, "why": "49,700 Hz; Telekom -> Starlink um 01:09"},
           "pending": {}, "dsl_handled": now - 10}
    assert latch(stn, tele(now - HOLD), now) == "cleared" and stn["pre"]["kinds"] == ["NETZ"] and stn["pre"]["on"] is True

    teil4 = os.environ.get("DSLRUECK_TEIL4") or ""
    if teil4 and os.path.isfile(teil4):
        raw = open(teil4, encoding="utf-8").read()
        if raw.count(OLD) != 1:
            raise SystemExit("Anker in apply-teil4.sh nicht genau einmal")
        b = _banner_ns(teil4)
        level = b["t4_level"]
        pd = {"on": True, "kinds": ["DSL"], "why": "Telekom -> Starlink um 01:09"}
        assert level("OK", [], pd)["label"] == "VORALARM DSL-AUSFALL"
        cleared = {"on": True, "kinds": [], "why": "DSL zurueck, Stick 2 nur per Knopf freigeben"}
        ok = level("OK", [], cleared)
        assert ok["lvl"] == "ok" and ok["label"] == "OK" and not ok["label"].startswith("VORALARM")
        netz = {"on": True, "kinds": ["NETZ"], "why": "49,700 Hz"}
        assert level("OK", [], netz)["label"] == "VORALARM NETZFREQUENZ"
        real = [{"src": "ASA", "text": "Gefahr", "real": True, "test": False}]
        assert level("OK", real, pd)["label"] == "ECHTALARM" and level("OK", real, cleared)["label"] == "ECHTALARM"
        nina_probe = [{"src": "NINA", "text": "Trinkwasserverschmutzung", "real": False, "test": True}]
        assert level("OK", nina_probe, cleared)["lvl"] == "ok"
        off = level("SDR_OFFLINE", [], cleared)
        assert off["label"] == "SDR_OFFLINE" and "DSL" not in off["why"]
        off_dsl = level("SDR_OFFLINE", [], pd)
        assert "DSL" in off_dsl["why"] and off_dsl["label"] == "SDR_OFFLINE"
        fev = b["t4_freq_eval"]
        samples = [(now - 400 + 25 * i, 50.0) for i in range(17)]
        stable = fev(samples, now)
        shaky = fev(samples[:8] + [(now - 200, 49.94)] + samples[9:], now)
        gappy = fev(samples[:-6] + samples[-3:], now)
        assert stable["stable"] is True and shaky["stable"] is False and gappy["stable"] is False
        assert rec(tele(now - HOLD), stable, now) is True
        assert rec(tele(now - HOLD), shaky, now) is False
        assert rec(tele(now - HOLD), gappy, now) is False
        assert b["t4_release_ok"]({"current": "telekom", "stale": False}, stable)[0] is True
        assert b["t4_release_ok"]({"current": "telekom", "stale": False}, shaky)[0] is False
        # Anker aus dem ausgelieferten teil4-Block laesst sich einbauen und bleibt beim zweiten Mal gleich
        i = raw.find("def _t4_pre_tick(now):")
        j = raw.find("\ndef _t4_release_state(", i)
        if i < 0 or j < 0:
            raise SystemExit("Auszug _t4_pre_tick fehlt")
        excerpt = raw[i:j]
        once, how = patch_text(excerpt)
        assert how == "neu"
        twice, how2 = patch_text(once)
        assert how2 == "schon" and twice == once
        ast.parse(once)
        try:
            patch_text("def _t4_pre_tick(now):\n    pass\n")
            raise SystemExit("fehlender Anker wurde nicht abgelehnt")
        except SystemExit as ex:
            if "nicht genau einmal" not in str(ex):
                raise
        print("OK dslRueck mit apply-teil4.sh (Ampel, Flanke, Anker)")
    else:
        excerpt = "def _t4_pre_tick(now):\n" + OLD + "    return\n"
        once, how = patch_text(excerpt)
        assert how == "neu"
        twice, how2 = patch_text(once)
        assert how2 == "schon" and twice == once
        ast.parse(once)
    print("OK dslRueck Selbsttest")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) != 2:
        print("Aufruf: patch.py --selftest | patch.py DASHBOARD.py", file=sys.stderr)
        return 2
    path = argv[1]
    text = open(path, encoding="utf-8").read()
    new, how = patch_text(text)
    if how == "neu":
        tmp = path + ".dslrueck-tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(new)
        os.replace(tmp, path)
    print(how)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit as e:
        if isinstance(e.code, str):
            print("STOP:", e.code, file=sys.stderr)
            sys.exit(1)
        raise
ENDPY

python3 -m py_compile "$W/patch.py"
if [[ -f "$ROOT/apply-teil4.sh" ]]; then
  DSLRUECK_TEIL4="$ROOT/apply-teil4.sh" python3 "$W/patch.py" --selftest
else
  python3 "$W/patch.py" --selftest
fi
if [[ "$COMMIT_ARG" == "--selftest" ]]; then
  echo "OK dslRueck nur Selbsttest, nichts installiert"
  exit 0
fi

[[ -f "$DASH" ]] || { echo "STOP: $DASH fehlt - nichts geaendert"; exit 1; }
command -v python3 >/dev/null && command -v sha256sum >/dev/null && command -v curl >/dev/null || { echo "STOP: python3/sha256sum/curl fehlt"; exit 1; }
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT)"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard"; exit 1; fi
B="http://127.0.0.1:${PORT}"

rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
s0=$(rssec 0); s1=$(rssec 300)
if rswin "$s0" || rswin "$s1"; then
  echo "STOP: Neustart-Sperre $(rshm "$s0") Uhr Berlin (HH:50 bis HH:04 inklusive Vorlauf) - nichts geaendert"
  exit 1
fi
echo "OK Neustart-Sperre: $(rshm "$s0") Uhr Berlin, auch in 5 min frei"

cp -a "$DASH" "$W/before.py"
set +e
python3 "$W/patch.py" "$W/before.py"
prc=$?
set -e
if [[ "$prc" -ne 0 ]]; then
  echo "STOP: Patch nicht anwendbar - Dashboard unveraendert"
  exit 1
fi
if cmp -s "$DASH" "$W/before.py"; then
  echo "OK dslRueck schon installiert - kein Neustart"
  echo "COMMIT $COMMIT_ARG dslRueck=schon"
  exit 0
fi
python3 -m py_compile "$W/before.py"
python3 - "$W/before.py" << 'PY'
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
ast.parse(src)
assert src.count("def _t4_dsl_recovered(") == 1
assert src.count("def _t4_dsl_drop(") == 1
assert "takeover_set" not in src[src.find("# dslRueck:"):src.find("def _t4_pre_tick(now):")]
assert 'pre["on"] = False' not in src[src.find("# dslRueck:"):src.find("def _t4_pre_tick(now):")]
print("OK eingebauter Block ohne Takeover-Loesung und ohne pre.on = False")
PY

cp -a "$DASH" "$DASH.bak-dslrueck-$TS"
rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-dslrueck-$TS" "$DASH"
  if [[ "${RESTARTED:-0}" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service || true
  fi
  echo "alter Stand wiederhergestellt, Backup $DASH.bak-dslrueck-$TS"
}
cp -a "$W/before.py" "$DASH"
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
RESTARTED=1
sudo systemctl restart prepper-dashboard.service || { rollback "Neustart prepper-dashboard"; exit 1; }
ok=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  code=$(curl -sS --connect-timeout 3 --max-time 15 -o "$W/t4.json" -w "%{http_code}" "$B/api/t4/status" || true)
  if [[ "$code" == "200" ]]; then ok=1; break; fi
  sleep 2
done
[[ "$ok" == 1 ]] || { rollback "HTTP /api/t4/status = ${code:-000}"; exit 1; }
python3 - "$W/t4.json" << 'PY' || { rollback "Status ohne pre/release"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(d.get("pre"), dict) and isinstance(d.get("release"), dict), d.keys()
print("OK /api/t4/status pre.on=%s release.ok=%s" % ((d.get("pre") or {}).get("on"), (d.get("release") or {}).get("ok")))
PY
echo "Backup: $DASH.bak-dslrueck-$TS"
echo "COMMIT $COMMIT_ARG dslRueck=1 Dienst=prepper-dashboard.service Port=$PORT"
