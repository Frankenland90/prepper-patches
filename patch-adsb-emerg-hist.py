#!/usr/bin/env python3
"""ADSB Squawk/Notlage: letzte 10 Notfälle persistieren. /* adsbEmergHist */."""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* adsbEmergHist */" in src:
    print("adsbEmergHist schon drin — nichts geaendert.")
    raise SystemExit(0)

changed = []

def one(old, new, label, required=True):
    global src
    n = src.count(old)
    if n == 1:
        src = src.replace(old, new, 1)
        changed.append(label)
        return True
    if required:
        raise SystemExit("STOP %s: Anker %sx (erwartet 1)." % (label, n))
    return False

HELPER = r'''
def _adsb_update_emerg_hist(emerg):
    """Letzte Notfall-Squawks speichern (max. 10, ein Event je Squawk-Beginn). /* adsbEmergHist */"""
    import json, os, time
    path = "/home/fmg/prepper-dashboard/adsb_emerg_hist.json"
    data = {"active": [], "items": []}
    if os.path.exists(path):
        try:
            with open(path) as f:
                data = json.load(f) or data
        except Exception:
            pass
    if not isinstance(data, dict):
        data = {"active": [], "items": []}
    items = list(data.get("items") or [])
    prev_active = set(data.get("active") or [])
    cur_keys = []
    for e in emerg or []:
        hx = str(e.get("hex") or "").upper()
        kind = str(e.get("kind") or "")
        key = "%s|%s" % (hx, kind)
        cur_keys.append(key)
        if key and key not in prev_active:
            items.append({
                "ts": time.time(),
                "at": now().strftime("%d.%m. %H:%M"),
                "kind": kind,
                "hex": hx,
                "flight": str(e.get("flight") or "–").strip() or "–",
                "sq": str(e.get("sq") or "–"),
                "alt": e.get("alt"),
            })
    items = items[-10:]
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"active": cur_keys, "items": items}, f)
        os.replace(tmp, path)
    except Exception:
        pass
    return list(reversed(items))


'''

# Insert helper before def fetch_adsb
m = re.search(r"\ndef fetch_adsb\(", src)
if not m:
    raise SystemExit("STOP: def fetch_adsb nicht gefunden.")
if "_adsb_update_emerg_hist" not in src:
    src = src[: m.start()] + "\n" + HELPER + src[m.start() :]
    changed.append("helper")

# out init: add emerg_hist
one(
    '"with_pos": 0, "emerg": [], "mil": 0, "mil_list": [], "updated": now_str(),',
    '"with_pos": 0, "emerg": [], "emerg_hist": [], "mil": 0, "mil_list": [], "updated": now_str(),',
    "out-init-mil",
    False,
)
if "emerg_hist" not in src.split("def fetch_adsb", 1)[-1][:800]:
    one(
        '"with_pos": 0, "emerg": [], "updated": now_str(),',
        '"with_pos": 0, "emerg": [], "emerg_hist": [], "updated": now_str(),',
        "out-init",
        True,
    )

# After out.update that sets emerg, call hist update
# Prefer mil variant, else plain
upd_mil = '''        out.update({
            "ok": True, "feeder": "online", "total": len(acs), "fresh": fresh_n,
            "adsb": n_adsb, "mode_s": n_mode, "mlat": n_mlat, "with_pos": n_pos,
            "emerg": emerg, "mil": mil_n, "mil_list": mil_list, "updated": now_str(),
        })'''
upd_mil_new = '''        out.update({
            "ok": True, "feeder": "online", "total": len(acs), "fresh": fresh_n,
            "adsb": n_adsb, "mode_s": n_mode, "mlat": n_mlat, "with_pos": n_pos,
            "emerg": emerg, "mil": mil_n, "mil_list": mil_list, "updated": now_str(),
        })
        out["emerg_hist"] = _adsb_update_emerg_hist(emerg)  # /* adsbEmergHist */'''
upd_plain = '''        out.update({
            "ok": True, "feeder": "online", "total": len(acs), "fresh": fresh_n,
            "adsb": n_adsb, "mode_s": n_mode, "mlat": n_mlat, "with_pos": n_pos,
            "emerg": emerg, "updated": now_str(),
        })'''
upd_plain_new = '''        out.update({
            "ok": True, "feeder": "online", "total": len(acs), "fresh": fresh_n,
            "adsb": n_adsb, "mode_s": n_mode, "mlat": n_mlat, "with_pos": n_pos,
            "emerg": emerg, "updated": now_str(),
        })
        out["emerg_hist"] = _adsb_update_emerg_hist(emerg)  # /* adsbEmergHist */'''

if src.count(upd_mil) == 1:
    src = src.replace(upd_mil, upd_mil_new, 1)
    changed.append("update-mil")
elif src.count(upd_plain) == 1:
    src = src.replace(upd_plain, upd_plain_new, 1)
    changed.append("update-plain")
else:
    # regex fallback: after "emerg": emerg ... })
    src2, n = re.subn(
        r'("emerg": emerg(?:, "mil": mil_n, "mil_list": mil_list)?, "updated": now_str\(\),\s*\}\))',
        r'\1\n        out["emerg_hist"] = _adsb_update_emerg_hist(emerg)  # /* adsbEmergHist */',
        src,
        count=1,
    )
    if n != 1:
        raise SystemExit("STOP: out.update emerg-Anker nicht gefunden.")
    src = src2
    changed.append("update-re")

OLD_TMPL = '''<div class="card{% if adsb.emerg %} warn{% endif %}">
  <div class="title">Squawk / Notlage</div>
  {% if adsb.emerg %}
    {% for e in adsb.emerg %}
    <div style="margin:6px 0;font-size:0.95rem">
      <b style="color:#fca5a5">{{ e.kind }}</b>
      · {{ e.flight }} · {{ e.hex }} · Squawk {{ e.sq }}
      {% if e.alt %} · {{ e.alt }} ft{% endif %}
    </div>
    {% endfor %}
  {% else %}
    <div><span class="okdot">●</span> Keine Notfall-Squawks (7500 / 7600 / 7700)</div>
  {% endif %}
  <div class="small">7500 Entführung · 7600 Funkausfall · 7700 allgemeiner Notfall</div>
</div>'''

NEW_TMPL = '''<div class="card{% if adsb.emerg %} warn{% endif %}">
  <div class="title">Squawk / Notlage</div>
  {% if adsb.emerg %}
    {% for e in adsb.emerg %}
    <div style="margin:6px 0;font-size:0.95rem">
      <b style="color:#fca5a5">{{ e.kind }}</b>
      · {{ e.flight }} · {{ e.hex }} · Squawk {{ e.sq }}
      {% if e.alt %} · {{ e.alt }} ft{% endif %}
    </div>
    {% endfor %}
  {% else %}
    <div><span class="okdot">●</span> Keine Notfall-Squawks (7500 / 7600 / 7700)</div>
  {% endif %}
  {% if adsb.emerg_hist %}
  <div class="small" style="margin-top:10px;color:#93c5fd;font-weight:600">Letzte Notfälle (max. 10)</div>
  {% for e in adsb.emerg_hist %}
  <div style="margin:4px 0;font-size:0.9rem;border-bottom:1px solid #1e293b;padding-bottom:4px">
    {{ e.at }} · <b style="color:#fca5a5">{{ e.kind }}</b>
    · {{ e.flight }} · {{ e.hex }} · Squawk {{ e.sq }}{% if e.alt %} · {{ e.alt }} ft{% endif %}
  </div>
  {% endfor %}
  {% endif %}
  <div class="small">7500 Entführung · 7600 Funkausfall · 7700 allgemeiner Notfall · Historie in adsb_emerg_hist.json</div>
</div>'''

one(OLD_TMPL, NEW_TMPL, "template", True)

PATH.write_text(src, encoding="utf-8")
print("OK adsbEmergHist:", ", ".join(changed))
