#!/usr/bin/env python3
"""keepLast — fehlgeschlagener oder leerer Fetch loescht keine Kachel.

Letzter guter Payload bleibt. Der Zeitstempel bleibt der der letzten
erfolgreichen Lieferung und wird von staleTs (grau/gelb/rot) gefaerbt,
falls vorhanden.

Nicht angefasst:
- update_all() # einmal beim Start
- die data_store-Zuweisung im Voll-Update
- data_store.clear()
- Internet, Ping, Netz-Probes (echte Offline-Messung, kein Einfrieren)

Self-check (Docstring, kein AST-Call und keine Zuweisung):
    data_store.clear()
    data_store = {
"""
from __future__ import annotations

import ast
import sys
from pathlib import Path

MARKER = "keepLast"
DASH = Path(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "/home/fmg/prepper-dashboard/dashboard.py")

RUNTIME = r'''
# keepLast — letzter guter Payload, Zeitstempel der letzten echten Lieferung.
import copy as _keep_copy
import json as _keep_json
import os as _keep_os
import threading as _keep_threading

_KEEP_MEM = {}
_KEEP_LOCK = _keep_threading.RLock()
_KEEP_TLS = _keep_threading.local()
_KEEP_NO_COLOR = set(["frequenz", "rohoel", "stratum"])
_KEEP_SKIP_FETCH = set(["fetch_internet", "fetch_ping", "fetch_public_ip", "fetch_download_mbps", "fetch_frequenz_live", "fetch_net_probes", "fetch_mesh_link", "fetch_mesh_status"])

def _keep_path():
    try:
        base = _keep_os.path.dirname(_keep_os.path.abspath(__file__))
    except Exception:
        base = "/home/fmg/prepper-dashboard"
    if not base:
        base = "/home/fmg/prepper-dashboard"
    return _keep_os.path.join(base, "keep-last.json")

def _keep_pred_pegel(v):
    if isinstance(v, dict):
        v = [v]
    return isinstance(v, list) and any(isinstance(x, dict) and x.get("cm") is not None for x in v)

def _keep_pred_news(v):
    if not isinstance(v, dict):
        return False
    return any(isinstance(f, dict) and f.get("items") for f in (v.get("feeds") or []))

def _keep_pred_adsb(v):
    return isinstance(v, dict) and v.get("ok") is True and not v.get("kept")

def _keep_pred_lng_term(v):
    if not isinstance(v, dict):
        return False
    if v.get("de_util") is not None:
        return True
    return any(isinstance(t, dict) and t.get("util") is not None for t in (v.get("terminals") or []))

def _keep_pred_luft_lokal(v):
    if not isinstance(v, dict) or not v:
        return False
    if v.get("label") or v.get("winds") or v.get("sensors"):
        return True
    if v.get("n_hotspots") is not None:
        return True
    if v.get("hotspots") or v.get("fires"):
        return True
    return False

# fetch-name -> (store_key, kind, pred, substitute)
# kind "value": Slot ist {value, updated}. kind "slot": der Fetch IST der Slot.
# substitute False: Rueckgabe nicht ersetzen (Mesh-Entwarnung), nur merken/stempeln.
_KEEP_FETCH = {
    "fetch_mix": ("mix", "value", lambda v: isinstance(v, dict) and (v.get("renew") is not None or v.get("shares")), True),
    "fetch_load": ("load", "value", lambda v: isinstance(v, dict) and v.get("load_gw") is not None, True),
    "fetch_strom": ("strom", "value", lambda v: isinstance(v, dict) and v.get("current") is not None, True),
    "fetch_gas": ("gas", "value", lambda v: isinstance(v, dict) and v.get("full") is not None, True),
    "fetch_lng": ("lng", "value", lambda v: isinstance(v, dict) and v.get("full") is not None, True),
    "fetch_lng_terminals": ("lng_term", "value", _keep_pred_lng_term, True),
    "fetch_kraftstoff": ("kraftstoff", "value", lambda v: isinstance(v, dict) and v.get("diesel") is not None, True),
    "fetch_rohoel": ("rohoel", "value", lambda v: isinstance(v, dict) and v.get("brent") is not None, True),
    "fetch_stromausfall": ("stromausfall", "value", lambda v: isinstance(v, dict) and ("count" in v or "items" in v), True),
    "fetch_wetter": ("wetter", "value", lambda v: isinstance(v, dict) and v.get("temp") is not None, True),
    "fetch_odl": ("odl", "value", lambda v: isinstance(v, dict) and v.get("avg") is not None, True),
    "fetch_luft_erlangen": ("luft", "value", lambda v: isinstance(v, dict) and (v.get("lqi") is not None or v.get("components")), True),
    "fetch_luft": ("luft_lokal", "direct", _keep_pred_luft_lokal, True),
    "fetch_pegel": ("pegel", "value", _keep_pred_pegel, True),
    "fetch_pegel_lokal": ("pegel", "value", _keep_pred_pegel, True),
    "fetch_spaceweather": ("spaceweather", "value", lambda v: isinstance(v, dict) and v.get("kp") is not None, True),
    "fetch_nina": ("nina", "value", lambda v: isinstance(v, list), False),
    "fetch_metalle": ("metalle", "value", lambda v: isinstance(v, dict) and (v.get("btc") is not None or v.get("gold") is not None), True),
    "fetch_news": ("news", "value", _keep_pred_news, True),
    "fetch_adsb": ("adsb", "value", _keep_pred_adsb, True),
    "fetch_system": ("system", "value", lambda v: isinstance(v, dict) and (v.get("cpu") is not None or v.get("ram")), True),
    "fetch_stratum": ("stratum", "value", lambda v: isinstance(v, dict) and v.get("time") not in (None, "", "--:--:--", "–"), True),
    "fetch_dwd_warnungen": ("dwd_warn", "value", lambda v: isinstance(v, dict) and "items" in v, True),
    "fetch_dwd_wbi": ("dwd_wbi", "value", lambda v: isinstance(v, dict) and v.get("wbi") is not None, True),
}

def _keep_locked(fn):
    lk = globals().get("data_store_lock")
    if lk is None:
        with _KEEP_LOCK:
            return fn()
    with lk:
        with _KEEP_LOCK:
            return fn()

def _keep_now():
    fn = globals().get("now_str")
    if callable(fn):
        try:
            return fn()
        except Exception:
            pass
    return ""

def _keep_fail_increased(key, before):
    try:
        fc = globals().get("fail_counters") or {}
        return int(fc.get(key, 0) or 0) > int(before or 0)
    except Exception:
        return False

def _keep_fail_now(key):
    try:
        fc = globals().get("fail_counters") or {}
        return int(fc.get(key, 0) or 0)
    except Exception:
        return 0

def _keep_strip_obj(obj):
    ts = None
    if isinstance(obj, dict) and "_keepLastTs" in obj:
        ts = obj.pop("_keepLastTs")
    elif isinstance(obj, list):
        for it in obj:
            if isinstance(it, dict) and "_keepLastTs" in it:
                ts = it.pop("_keepLastTs")
                break
    return ts

def _keep_tag(payload, ts):
    payload = _keep_copy.deepcopy(payload)
    if not ts:
        return payload
    if isinstance(payload, dict):
        payload["_keepLastTs"] = ts
    elif isinstance(payload, list):
        for it in payload:
            if isinstance(it, dict):
                it["_keepLastTs"] = ts
                break
    return payload

def _keep_remember(key, payload, updated):
    if payload is None:
        return
    try:
        blob = _keep_copy.deepcopy(payload)
    except Exception:
        return
    _keep_strip_obj(blob)
    if isinstance(blob, dict):
        blob.pop("_keepLastTs", None)
        blob.pop("kept", None)
    rec = {"payload": blob, "updated": updated or ""}
    _KEEP_MEM[key] = rec
    try:
        out = {}
        for k, v in _KEEP_MEM.items():
            out[k] = {"payload": v.get("payload"), "updated": v.get("updated") or ""}
        path = _keep_path()
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            _keep_json.dump(out, f, ensure_ascii=False)
        _keep_os.replace(tmp, path)
    except Exception as e:
        print("keepLast disk:", e)

def _keep_load_disk():
    path = _keep_path()
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = _keep_json.load(f)
    except Exception:
        return
    if not isinstance(raw, dict):
        return
    for key, rec in raw.items():
        if not isinstance(rec, dict) or "payload" not in rec:
            continue
        if key in _KEEP_MEM:
            continue
        _KEEP_MEM[key] = {"payload": rec.get("payload"), "updated": rec.get("updated") or ""}
        print("keepLast disk", key)

def _keep_recolor(key, slot):
    if not isinstance(slot, dict) or key in _KEEP_NO_COLOR:
        return
    fn = globals().get("stale_ts_color")
    if not callable(fn):
        return
    try:
        col = fn(key, slot.get("updated"))
    except Exception:
        col = None
    if col:
        slot["color"] = col

def _keep_mark(key, ts):
    if not key or not ts:
        return
    bag = getattr(_KEEP_TLS, "marks", None)
    if not isinstance(bag, dict):
        bag = {}
        _KEEP_TLS.marks = bag
    bag[key] = ts

def _keep_take_marks():
    bag = getattr(_KEEP_TLS, "marks", None)
    _KEEP_TLS.marks = {}
    return dict(bag or {})

def _keep_payload_of(kind, slot):
    if kind == "slot":
        return slot
    if isinstance(slot, dict):
        return slot.get("value")
    return None

def _keep_good(key, payload):
    spec = None
    for _name, row in _KEEP_FETCH.items():
        if row[0] == key:
            spec = row
            break
    if spec is None:
        return False
    try:
        return bool(spec[2](payload))
    except Exception:
        return False

def _keep_apply_ts(slot, ts):
    if isinstance(slot, dict) and ts:
        slot["updated"] = ts
    return slot

def _keep_untag_slot(slot):
    ts = None
    if not isinstance(slot, dict):
        return None
    if "_keepLastTs" in slot:
        ts = slot.pop("_keepLastTs")
    val = slot.get("value") if "value" in slot else None
    inner = _keep_strip_obj(val) if val is not None else None
    if inner:
        ts = inner
    if ts:
        slot["updated"] = ts
    return ts

def _keep_heal_store():
    def work():
        marks = _keep_take_marks()
        for key, ts in marks.items():
            slot = data_store.get(key)
            if isinstance(slot, dict) and ts:
                slot["updated"] = ts
                _keep_recolor(key, slot)
        for key in list(_KEEP_MEM.keys()):
            slot = data_store.get(key)
            if not isinstance(slot, dict):
                continue
            _keep_untag_slot(slot)
            kind = "value"
            for row in _KEEP_FETCH.values():
                if row[0] == key:
                    kind = row[1]
                    break
            if kind == "direct":
                continue
            payload = _keep_payload_of(kind, slot)
            if _keep_good(key, payload):
                _keep_remember(key, payload if kind != "slot" else slot, slot.get("updated"))
                _keep_recolor(key, slot)
                continue
            mem = _KEEP_MEM.get(key)
            if not mem or not _keep_good(key, mem.get("payload")):
                continue
            ts = mem.get("updated") or ""
            if kind == "slot":
                restored = _keep_copy.deepcopy(mem.get("payload"))
                if isinstance(restored, dict):
                    restored.pop("_keepLastTs", None)
                    if ts:
                        restored["updated"] = ts
                data_store[key] = restored
                print("keepLast keep", key)
                continue
            # In place, damit **data_store beim Rendern denselben Slot sieht.
            restored_val = _keep_copy.deepcopy(mem.get("payload"))
            _keep_strip_obj(restored_val)
            slot["value"] = restored_val
            if ts:
                slot["updated"] = ts
            if key == "nina":
                slot["error"] = True
            _keep_recolor(key, slot)
            print("keepLast keep", key)
    try:
        _keep_locked(work)
    except Exception as e:
        print("keepLast heal:", e)

def _keep_scrub_ctx(ctx):
    if not isinstance(ctx, dict):
        return ctx
    marks = _keep_take_marks()
    for key, val in list(ctx.items()):
        if not isinstance(val, dict):
            continue
        ts = _keep_untag_slot(val)
        if key in marks and marks[key]:
            val["updated"] = marks[key]
            ts = marks[key]
        if ts or key in marks:
            _keep_recolor(key, val)
            # Kein Rueckschreiben nach data_store: /luft legt den lokalen
            # Fetch unter ctx-Key "luft" ab, das ist nicht die Erlangen-Kachel.
    return ctx

def _keep_wrap_fetch(name):
    row = _KEEP_FETCH.get(name)
    orig = globals().get(name)
    if row is None or not callable(orig) or getattr(orig, "_keepLast", False):
        return
    key, kind, pred, substitute = row
    def wrapped(*a, **k):
        before = _keep_fail_now(key)
        out = orig(*a, **k)
        failed = _keep_fail_increased(key, before)
        good = False
        if not failed:
            try:
                good = bool(pred(out))
            except Exception:
                good = False
        if good:
            ts = ""
            if isinstance(out, dict) and out.get("updated") not in (None, "", "–"):
                ts = out.get("updated")
            if not ts:
                ts = _keep_now()
            try:
                _keep_locked(lambda: _keep_remember(key, out if kind != "slot" else out, ts))
            except Exception as e:
                print("keepLast remember", name, e)
            return out
        mem = _KEEP_MEM.get(key)
        payload = mem.get("payload") if isinstance(mem, dict) else None
        ts = (mem.get("updated") if isinstance(mem, dict) else "") or ""
        if not _keep_good(key, payload):
            return out
        _keep_mark(key, ts)
        print("keepLast keep", key)
        if not substitute:
            return out
        return _keep_tag(payload, ts)
    wrapped._keepLast = True
    globals()[name] = wrapped

def _keep_wrap_update():
    orig = globals().get("update_all")
    if not callable(orig) or getattr(orig, "_keepLast", False):
        return
    def wrapped(*a, **k):
        _KEEP_TLS.marks = {}
        try:
            return orig(*a, **k)
        finally:
            _keep_heal_store()
    wrapped._keepLast = True
    globals()["update_all"] = wrapped

def _keep_wrap_render():
    orig = globals().get("render_template_string")
    if not callable(orig) or getattr(orig, "_keepLast", False):
        return
    def wrapped(src, **ctx):
        try:
            _keep_heal_store()
            _keep_scrub_ctx(ctx)
        except Exception as e:
            print("keepLast render:", e)
        return orig(src, **ctx)
    wrapped._keepLast = True
    globals()["render_template_string"] = wrapped

def _keep_before():
    try:
        _keep_heal_store()
    except Exception as e:
        print("keepLast before:", e)

def _keep_install():
    if globals().get("_KEEP_INSTALLED"):
        return
    globals()["_KEEP_INSTALLED"] = True
    _keep_load_disk()
    for name in list(_KEEP_FETCH.keys()):
        if name in _KEEP_SKIP_FETCH:
            continue
        try:
            _keep_wrap_fetch(name)
        except Exception as e:
            print("keepLast wrap", name, e)
    _keep_wrap_update()
    _keep_wrap_render()
    app_obj = globals().get("app")
    try:
        if app_obj is not None and hasattr(app_obj, "before_request"):
            app_obj.before_request(_keep_before)
    except Exception as e:
        print("keepLast hook:", e)
    print("keepLast installed")

_keep_install()
# keepLast
'''


def _forbid_counts(text: str):
    import re
    boot = text.count("update_all()  # einmal beim Start")
    clear = text.count("data_store.clear()")
    assign = 0
    for line in text.splitlines():
        if re.match(r"\s*data_store\s*=", line):
            assign += 1
    return boot, clear, assign


def apply_to(src: str) -> str:
    if MARKER in src and "def _keep_install" in src and "keepLast installed" in src:
        print("already patched (keepLast) — skip")
        return src
    boot, clear, assign = _forbid_counts(src)
    anchor = '\nif __name__ == "__main__":\n'
    idx = src.rfind(anchor)
    if idx < 0:
        raise SystemExit("STOP: __main__ Anker fehlt")
    src = src[:idx] + "\n" + RUNTIME + "\n" + src[idx:]
    b2, c2, a2 = _forbid_counts(src)
    if b2 != boot:
        raise SystemExit("STOP: Boot-Pfad update_all() veraendert")
    if c2 != clear:
        raise SystemExit("STOP: data_store.clear veraendert")
    if a2 != assign:
        raise SystemExit("STOP: data_store-Zuweisung veraendert (%s -> %s)" % (assign, a2))
    if "def _keep_install" not in src or "keepLast installed" not in src:
        raise SystemExit("STOP: keepLast runtime fehlt")
    return src


def _selftest() -> None:
    from datetime import datetime, timedelta

    ns = {
        "__file__": "/tmp/keep-last-test/dashboard.py",
        "fail_counters": {},
        "data_store": {},
        "now_str": lambda: datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
        "stale_ts_color": lambda key, updated: "#eab308",
        "render_template_string": lambda src, **ctx: ("RENDER", src, ctx),
    }

    class _App:
        def before_request(self, fn):
            ns["before"] = fn
            return fn

    ns["app"] = _App()
    old = (datetime.now() - timedelta(minutes=20)).strftime("%d.%m.%Y %H:%M:%S")
    fresh = datetime.now().strftime("%d.%m.%Y %H:%M:%S")

    def fetch_mix():
        ns["fail_counters"]["mix"] = ns["fail_counters"].get("mix", 0) + 1
        return {}

    def fetch_load():
        ns["fail_counters"]["load"] = ns["fail_counters"].get("load", 0) + 1
        return {"load_gw": None, "residual_gw": None}

    def fetch_nina():
        ns["fail_counters"]["nina"] = ns["fail_counters"].get("nina", 0) + 1
        return None

    def fetch_stromausfall():
        ns["fail_counters"]["stromausfall"] = 0
        return {"items": [], "count": 0}

    def fetch_dwd_warnungen():
        ns["fail_counters"]["dwd_warn"] = ns["fail_counters"].get("dwd_warn", 0) + 1
        return {"items": [], "count": 0, "max_level": 0}

    ns["fetch_mix"] = fetch_mix
    ns["fetch_load"] = fetch_load
    ns["fetch_nina"] = fetch_nina
    ns["fetch_stromausfall"] = fetch_stromausfall
    ns["fetch_dwd_warnungen"] = fetch_dwd_warnungen
    exec("""
def update_all():
    data_store['mix'] = {'value': fetch_mix(), 'updated': now_str(), 'color': '#94a3b8'}
    data_store['load'] = {'value': fetch_load(), 'updated': now_str(), 'color': '#94a3b8'}
    _n = fetch_nina()
    old_nina = _nina_prev
    data_store['nina'] = {
        'value': _n if _n is not None else old_nina,
        'updated': now_str(),
        'error': _n is None,
        'color': '#94a3b8',
    }
    data_store['stromausfall'] = {'value': fetch_stromausfall(), 'updated': now_str(), 'color': '#94a3b8'}
    data_store['dwd_warn'] = {'value': fetch_dwd_warnungen(), 'updated': now_str(), 'color': '#94a3b8'}
""", ns)
    ns["data_store"]["mix"] = {
        "value": {"renew": 62.4, "shares": {"Solar": 20.0, "Wind onshore": 30.0}, "total_mw": 45000},
        "updated": old,
        "color": "#94a3b8",
    }
    ns["data_store"]["load"] = {
        "value": {"load_gw": 48.2, "residual_gw": 12.1, "ren_share_load": 55.0, "ren_share_gen": 60.0},
        "updated": old,
        "color": "#94a3b8",
    }
    ns["data_store"]["nina"] = {"value": [{"city": "Erlangen", "title": "Test"}], "updated": old, "error": False}
    ns["_nina_prev"] = [{"city": "Erlangen", "title": "Test"}]
    ns["data_store"]["stromausfall"] = {"value": {"items": [{"id": "1"}], "count": 1}, "updated": old}
    ns["data_store"]["dwd_warn"] = {"value": {"items": [{"event": "Wind"}], "count": 1, "max_level": 2}, "updated": old}
    exec(compile(RUNTIME, "keep_last_runtime.py", "exec"), ns)
    # Install remembered nothing yet (store was good but install does not scan).
    # Seed memory the way a previous good render would.
    ns["_keep_remember"]("mix", ns["data_store"]["mix"]["value"], old)
    ns["_keep_remember"]("load", ns["data_store"]["load"]["value"], old)
    ns["_keep_remember"]("nina", ns["data_store"]["nina"]["value"], old)
    ns["_keep_remember"]("stromausfall", ns["data_store"]["stromausfall"]["value"], old)
    ns["_keep_remember"]("dwd_warn", ns["data_store"]["dwd_warn"]["value"], old)
    ns["update_all"]()
    mix = ns["data_store"]["mix"]
    load = ns["data_store"]["load"]
    assert mix["value"]["renew"] == 62.4, mix
    assert mix["value"]["shares"]["Solar"] == 20.0, mix
    assert "_keepLastTs" not in mix["value"], mix
    assert mix["updated"] == old, mix
    assert mix["color"] == "#eab308", mix
    assert load["value"]["load_gw"] == 48.2, load
    assert load["updated"] == old, load
    # NINA: Fetch bleibt None fuer Mesh, Store behaelt die Warnung und den alten Stempel.
    assert ns["data_store"]["nina"]["value"][0]["title"] == "Test"
    assert ns["data_store"]["nina"]["updated"] == old, ns["data_store"]["nina"]
    # Echter Leer-Erfolg (Zaehler auf 0) darf nicht den alten Ausfall festkleben.
    assert ns["data_store"]["stromausfall"]["value"]["count"] == 0, ns["data_store"]["stromausfall"]
    assert ns["data_store"]["stromausfall"]["updated"] != old
    # DWD-Fehlfetch (Zaehler hoch) behaelt die letzte Warnung.
    assert ns["data_store"]["dwd_warn"]["value"]["items"][0]["event"] == "Wind", ns["data_store"]["dwd_warn"]
    assert ns["data_store"]["dwd_warn"]["updated"] == old
    # Render schrubbt Tags und setzt den Stempel, wenn die Seite ihn neu schreibt.
    tagged = ns["fetch_mix"]()
    assert tagged.get("_keepLastTs") == old or (isinstance(tagged, dict) and tagged.get("renew") == 62.4)
    ns["data_store"]["load"] = {"value": {}, "updated": fresh, "color": "#94a3b8"}
    ctx = {
        "mix": {"value": {"renew": 62.4, "shares": {"Solar": 1}, "_keepLastTs": old}, "updated": fresh, "color": "#94a3b8"},
        "load": ns["data_store"]["load"],
    }
    _kind, _src, out_ctx = ns["render_template_string"]("PAGE", **ctx)
    assert out_ctx["mix"]["updated"] == old, out_ctx["mix"]
    assert "_keepLastTs" not in out_ctx["mix"]["value"]
    assert out_ctx["load"]["value"]["load_gw"] == 48.2, out_ctx["load"]
    assert out_ctx["load"]["updated"] == old, out_ctx["load"]
    # Erfolg ueberschreibt und setzt einen frischen Stempel.
    def fetch_mix_ok():
        ns["fail_counters"]["mix"] = 0
        return {"renew": 70.0, "shares": {"Solar": 40.0}, "total_mw": 40000}
    ns["fetch_mix"] = fetch_mix_ok
    # re-wrap the new function
    ns["_keep_wrap_fetch"]("fetch_mix")
    got = ns["fetch_mix"]()
    assert got["renew"] == 70.0, got
    assert "_keepLastTs" not in got
    print("SELFTEST OK")


def main() -> None:
    if not DASH.is_file():
        raise SystemExit("STOP: dashboard fehlt: %s" % DASH)
    src = DASH.read_text(encoding="utf-8")
    new = apply_to(src)
    if new != src:
        DASH.write_text(new, encoding="utf-8")
        print("OK patched keepLast ->", DASH)
    else:
        print("DONE keepLast (unveraendert)")
    compile(new, str(DASH), "exec")
    print("DONE keepLast")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
