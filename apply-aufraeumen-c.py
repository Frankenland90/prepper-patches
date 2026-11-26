#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-aufraeumen-c. pip-Warnung, Pegel-Stempel, tote Wrapper, Header, except, textContent."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

PAYLOAD = json.loads(r"""{"paare": [["dashboard.py", "try:\n    import psutil\nexcept ImportError:\n    os.system(\"pip install psutil\")\n    import psutil\n", "try:\n    import psutil\nexcept ImportError:\n    psutil = None\n    print(\"dashboard: psutil fehlt\", flush=True)\n", 1], ["dashboard.py", "def maybe_mesh_pegel(force=False):\n", "def save_pegel_mesh_status():\n    \"\"\"Stempel der letzten Pegel-Meldung. Sendet nichts.\"\"\"\n    try:\n        stand = last_pegel_mesh_status if isinstance(last_pegel_mesh_status, dict) else {}\n        with open(\"/home/fmg/prepper-dashboard/pegel_mesh_status.json\", \"w\", encoding=\"utf-8\") as handle:\n            json.dump({\"ok\": bool(stand.get(\"ok\")), \"auto\": last_pegel_mesh_auto, \"manual\": last_pegel_mesh_manual, \"at\": stand.get(\"at\")}, handle)\n    except Exception:\n        pass\n\n\ndef maybe_mesh_pegel(force=False):\n", 1], ["dashboard.py", "if callable(globals().get(\"sw_sources\")):\n    _sdh_orig_sw_sources = sw_sources\n\n    def sw_sources():\n        d = _sdh_orig_sw_sources()\n        try:\n            v = sdh_view()\n            age = v.get(\"age_s\")\n            d[\"sources\"].append({\"key\": \"sd\", \"name\": \"SD-Karte\", \"state\": v[\"state\"], \"age_s\": age,\n                                 \"age_txt\": _sw_fmt_age(age) if age is not None else \"–\", \"threshold_s\": SDH_STALE_S,\n                                 \"threshold_txt\": _sw_fmt_age(SDH_STALE_S), \"fails\": 0, \"important\": True,\n                                 \"why\": \"; \".join(v.get(\"reasons\") or [])[:120], \"time_source\": \"sd_health.json\"})\n            d[\"counts\"][v[\"state\"]] = d[\"counts\"].get(v[\"state\"], 0) + 1\n            if v.get(\"level\") == \"red\":\n                d[\"important_down\"].append(\"SD-Karte\")\n            d[\"sd\"] = {\"level\": v.get(\"level\"), \"reasons\": v.get(\"reasons\")}\n        except Exception as e:\n            print(\"sdHealth sources:\", e, flush=True)\n        return d\n", "", 1], ["dashboard.py", "if callable(globals().get(\"_sw_banner\")):\n    _sdh_orig_sw_banner = _sw_banner\n\n    def _sw_banner(d):\n        if \"SD-Karte\" not in (d.get(\"important_down\") or []):\n            return _sdh_orig_sw_banner(d)\n        rest = dict(d)\n        rest[\"important_down\"] = [x for x in d[\"important_down\"] if x != \"SD-Karte\"]\n        rs = \"; \".join((d.get(\"sd\") or {}).get(\"reasons\") or [])\n        sd = ('<div class=\"src-banner sd-banner\" style=\"background:#7f1d1d;color:#fff;padding:10px 14px;margin:0 0 10px;'\n              'border-radius:8px;font-weight:600\">⚠️ SD-Karte: %s – Backup prüfen, Karte bald tauschen</div>'\n              % str(rs or \"Fehler\").replace(\"<\", \"&lt;\")[:200])\n        return sd + _sdh_orig_sw_banner(rest)\n", "", 1], ["dashboard.py", "if callable(globals().get(\"sw_sources\")):\n    _pp_orig_sw_sources = sw_sources\n\n    def sw_sources():\n        ds = globals().get(\"data_store\") or {}\n        disc = {}\n        try:\n            disc = _pp_discover(ds)\n            for i, ent in enumerate(list(SW_SOURCES)):\n                if ent[0] in (\"dwd\", \"wbi\") and (\"_orig_\" + ent[0]) not in _pp_orig:\n                    _pp_orig[\"_orig_\" + ent[0]] = (i, ent)\n            for k in (\"dwd\", \"wbi\"):\n                o = _pp_orig.get(\"_orig_\" + k)\n                f = disc.get(k)\n                if o:\n                    i, ent = o\n                    SW_SOURCES[i] = ((f[1],) + tuple(ent[1:])) if (f and f[0] == \"data_store\") else ent\n        except Exception as e:\n            print(\"piPolish discover:\", e, flush=True)\n        d = _pp_orig_sw_sources()\n        try:\n            fc = globals().get(\"fail_counters\") or {}\n            now = _pp_time.time()\n            for r in d.get(\"sources\") or []:\n                k = \"dwd\" if r.get(\"name\") == \"DWD-Warnungen\" else (\"wbi\" if r.get(\"name\") == \"Waldbrand-Index\" else None)\n                if not k:\n                    continue\n                f = disc.get(k)\n                r[\"data_key\"] = (\"%s:%s\" % f) if f else None\n                if r.get(\"state\") != \"unbekannt\" or not f or f[0] == \"data_store\":\n                    continue\n                t = src = None\n                if f[0] == \"keep-last.json\":\n                    t, src = _pp_tfield(_pp_keeplast().get(f[1]))\n                elif f[0] == \"global\":\n                    t, src = _pp_tfield(globals().get(f[1]))\n                elif f[0] == \"deque\":\n                    dq = list(globals().get(f[1]) or [])\n                    t = _sw_parse(dq[-1].get(\"t\")) if dq and isinstance(dq[-1], dict) else None\n                    src = \"t\"\n                if not t:\n                    continue\n                age = now - t\n                fk = \"dwd_warn\" if k == \"dwd\" else \"dwd_wbi\"\n                fails = int(fc.get(fk) or 0)\n                old = r[\"state\"]\n                r[\"state\"], r[\"why\"] = _pp_state(age, r[\"threshold_s\"], fails)\n                r[\"age_s\"], r[\"age_txt\"], r[\"fails\"] = int(age), _sw_fmt_age(age), fails\n                r[\"time_source\"] = \"%s:%s.%s\" % (f[0], f[1], src)\n                d[\"counts\"][old] = max(0, d[\"counts\"].get(old, 1) - 1)\n                d[\"counts\"][r[\"state\"]] = d[\"counts\"].get(r[\"state\"], 0) + 1\n                if r[\"important\"] and r[\"state\"] == \"ausgefallen\" and r[\"name\"] not in d[\"important_down\"]:\n                    d[\"important_down\"].append(r[\"name\"])\n            d[\"discovery\"] = {k: ((\"%s:%s\" % v) if v else None) for k, v in disc.items()}\n        except Exception as e:\n            print(\"piPolish sources:\", e, flush=True)\n        return d\n", "", 1], ["dashboard.py", "r.innerHTML=S.rows_html;", "r.textContent='';var doc=new DOMParser().parseFromString('<div>'+S.rows_html+'</div>','text/html');var host=doc.body.firstChild;while(host&&host.firstChild){var n=host.removeChild(host.firstChild);if(n.nodeType!==1)continue;var e=document.createElement(n.tagName);e.className=n.className||'';if(n.getAttribute('title'))e.setAttribute('title',n.getAttribute('title'));for(var c=n.firstChild;c;c=c.nextSibling){if(c.nodeType===3)e.appendChild(document.createTextNode(c.textContent));else if(c.nodeType===1){var s=document.createElement(c.tagName);s.className=c.className||'';s.textContent=c.textContent||'';e.appendChild(s);}}r.appendChild(e);}", 1], ["dashboard.py", "if __name__ == \"__main__\":\n    # sourceWatch final\n", "def _sec_headers(resp):\n    \"\"\"Anzeige-Header. CSP nur Report-Only.\"\"\"\n    resp.headers.setdefault(\"X-Content-Type-Options\", \"nosniff\")\n    resp.headers.setdefault(\"X-Frame-Options\", \"SAMEORIGIN\")\n    resp.headers.setdefault(\"Referrer-Policy\", \"same-origin\")\n    resp.headers.setdefault(\"Content-Security-Policy-Report-Only\", \"default-src 'self'\")\n    return resp\n\n\nif not any(getattr(f, \"__name__\", \"\") == \"_sec_headers\" for f in app.after_request_funcs.get(None, [])):\n    app.after_request(_sec_headers)\n\n\nif __name__ == \"__main__\":\n    # sourceWatch final\n", 1], ["fullcheck.sh", "DASH_SHA16=\"${FC_DASH_SHA16:-78d3c91944d6872d}\"", "DASH_SHA16=\"${FC_DASH_SHA16:-3a049826f2aae3e4}\"", 1], ["fullcheck.sh", "DASH_BYTES=\"${FC_DASH_BYTES:-1391894}\"", "DASH_BYTES=\"${FC_DASH_BYTES:-1389101}\"", 1]], "fest": {"dashboard.py": {"sha256": "78d3c91944d6872d530f8e3d5ff6b4d394e0c2c0db044bf9d9d1c4d189429cfd", "bytes": 1391894}, "lage_pages.py": {"sha256": "696638fd9ea3cd1723b25883d02d4516a1db9f3ba98711657f671ad6f29240c0", "bytes": 231498}, "flugfunk.py": {"sha256": "c45120614a9970db11412965fcbca7683d6d206e47dbf32f51e887440c7cc9ed", "bytes": 99369}, "fullcheck.sh": {"sha256": "2368ca9beb71c653b9c77eaf452214fe4a27c9f63bba6a12028893776c94634c", "bytes": 99209}}}""")
BASIS = "/home/fmg/prepper-dashboard"
FULLCHECK = "/home/fmg/fullcheck.sh"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def sperre(minute):
    minute = int(minute)
    return minute >= 40 or minute <= 4


def berlin_minute():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin")).minute
    return datetime.now().minute


def ersetze(text, alt, neu, name, n):
    c = text.count(alt)
    if c != n:
        raise SystemExit("STOP %s Anker %s erwartet %s" % (name, c, n))
    return text.replace(alt, neu)


def excepts(text):
    zeilen = text.splitlines(True)
    n = 0
    for i, zeile in enumerate(zeilen):
        m = re.match(r"^([ \t]*)except:\s*$", zeile)
        if not m:
            continue
        zeilen[i] = m.group(1) + "except Exception:\n"
        n += 1
    if n != 8:
        raise SystemExit("STOP nackte except %s" % n)
    return "".join(zeilen)


def sichere(path):
    if not os.path.isfile(path):
        return
    for i in (3, 2, 1):
        ziel = "%s.bak-aufraeumen-c-%s" % (path, i)
        if i == 1:
            shutil.copy2(path, ziel)
        else:
            vor = "%s.bak-aufraeumen-c-%s" % (path, i - 1)
            if os.path.isfile(vor):
                os.replace(vor, ziel)


def lade(path, soll, hashcheck):
    data = open(path, "rb").read()
    ist = sha256(data)
    if hashcheck and (ist != soll["sha256"] or len(data) != soll["bytes"]):
        print("STOP %s ist %s/%s soll %s/%s" % (path, ist[:16], len(data), soll["sha256"][:16], soll["bytes"]))
        raise SystemExit(2)
    return data.decode("utf-8")


def schreibe(path, text):
    sichere(path)
    tmp = path + ".c-tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    if path.endswith(".sh"):
        probe = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
        if probe.returncode != 0:
            os.remove(tmp)
            print("STOP bash -n")
            raise SystemExit(2)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)



RANGE = json.loads(r"""{"live": "def live_response(base):\n    from flask import Response, abort\n    if not lan_ok(_client()):\n        abort(403)\n    pfad = _live_datei(base)\n    ffmpeg = shutil.which(\"ffmpeg\")\n    if pfad and ffmpeg:\n        def stueck():\n            proc = subprocess.Popen(\n                [ffmpeg, \"-loglevel\", \"error\", \"-fflags\", \"nobuffer\", \"-f\", \"s16le\",\n                 \"-ar\", \"16000\", \"-ac\", \"1\", \"-i\", pfad, \"-f\", \"mp3\", \"-b:a\", \"32k\", \"-\"],\n                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,\n            )\n            try:\n                while True:\n                    block = proc.stdout.read(2048)\n                    if not block:\n                        break\n                    yield block\n            finally:\n                proc.kill()\n                _log(base, \"stream\", \"abbruch\")\n        return Response(stueck(), mimetype=\"audio/mpeg\", headers={\"Cache-Control\": \"no-store\"})\n    daten = live_wav(pfad) if pfad else None\n    if not daten:\n        abort(404)\n    return Response(daten, mimetype=\"audio/wav\", headers={\"Cache-Control\": \"no-store\"})\n\n", "ice": "def icecast_response(base):\n    \"\"\"Mount /flugfunk nur im LAN. Status erst nach dem ersten Audioblock, sonst 503.\"\"\"\n    from flask import Response, abort\n    import socket\n    if not lan_ok(_client()):\n        abort(403)\n    sock = None\n    try:\n        sock = socket.create_connection(_ICECAST, 3)\n        sock.settimeout(5)\n        sock.sendall(b\"GET /flugfunk HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nIcy-MetaData: 0\\r\\nConnection: close\\r\\n\\r\\n\")\n        kopf = b\"\"\n        while b\"\\r\\n\\r\\n\" not in kopf and len(kopf) < 8192:\n            teil = sock.recv(1024)\n            if not teil:\n                break\n            kopf += teil\n        teile = kopf.split(b\"\\r\\n\\r\\n\", 1)\n        status = teile[0].split(b\"\\r\\n\", 1)[0] if teile else b\"\"\n        rest = teile[1] if len(teile) > 1 else b\"\"\n        if b\"200\" not in status[:24]:\n            raise OSError(\"status\")\n        if not rest:\n            rest = sock.recv(4096)\n        if not rest:\n            raise OSError(\"leer\")\n    except Exception:\n        if sock is not None:\n            try:\n                sock.close()\n            except OSError:\n                pass\n        abort(503)\n    def stueck(erst=rest, verbindung=sock):\n        try:\n            yield erst\n            verbindung.settimeout(15)\n            while True:\n                block = verbindung.recv(4096)\n                if not block:\n                    break\n                yield block\n        finally:\n            verbindung.close()\n    antwort = Response(stueck(), mimetype=\"audio/mpeg\")\n    antwort.headers[\"Cache-Control\"] = \"no-store\"\n    antwort.headers[\"X-Accel-Buffering\"] = \"no\"\n    return antwort\n\n", "neu": "def live_response(base):\n    from flask import Response, abort, request\n    if not lan_ok(_client()):\n        abort(403)\n    stille = bytes.fromhex(_STILLE_MP3)\n    kopf = {\"Cache-Control\": \"no-store\", \"Accept-Ranges\": \"none\", \"X-Accel-Buffering\": \"no\"}\n    pfad = _live_datei(base)\n    ffmpeg = shutil.which(\"ffmpeg\")\n    if not pfad or not ffmpeg:\n        if request.headers.get(\"Range\"):\n            return Response(stille, mimetype=\"audio/mpeg\", headers=kopf)\n        abort(404)\n    def stueck(datei=pfad):\n        yield stille\n        proc = subprocess.Popen(\n            [ffmpeg, \"-loglevel\", \"error\", \"-fflags\", \"nobuffer\", \"-f\", \"s16le\",\n             \"-ar\", \"16000\", \"-ac\", \"1\", \"-i\", datei, \"-f\", \"mp3\", \"-b:a\", \"32k\", \"-\"],\n            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,\n        )\n        try:\n            while True:\n                block = proc.stdout.read(2048)\n                if not block:\n                    break\n                yield block\n        finally:\n            proc.kill()\n            _log(base, \"stream\", \"abbruch\")\n    return Response(stueck(), mimetype=\"audio/mpeg\", headers=kopf)\n\n\ndef icecast_response(base):\n    from flask import Response, abort\n    import socket\n    if not lan_ok(_client()):\n        abort(403)\n    stille = bytes.fromhex(_STILLE_MP3)\n    kopf = {\"Cache-Control\": \"no-store\", \"Accept-Ranges\": \"none\", \"X-Accel-Buffering\": \"no\"}\n    def stueck():\n        yield stille\n        sock = None\n        try:\n            sock = socket.create_connection(_ICECAST, 3)\n            sock.settimeout(5)\n            sock.sendall(b\"GET /flugfunk HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nIcy-MetaData: 0\\r\\nConnection: close\\r\\n\\r\\n\")\n            puff = b\"\"\n            while b\"\\r\\n\\r\\n\" not in puff and len(puff) < 8192:\n                teil = sock.recv(1024)\n                if not teil:\n                    break\n                puff += teil\n            teile = puff.split(b\"\\r\\n\\r\\n\", 1)\n            status = teile[0].split(b\"\\r\\n\", 1)[0] if teile else b\"\"\n            rest = teile[1] if len(teile) > 1 else b\"\"\n            if b\"200\" not in status[:24]:\n                return\n            if rest:\n                yield rest\n            sock.settimeout(15)\n            while True:\n                block = sock.recv(4096)\n                if not block:\n                    break\n                yield block\n        except Exception:\n            return\n        finally:\n            if sock is not None:\n                try:\n                    sock.close()\n                except OSError:\n                    pass\n    return Response(stueck(), mimetype=\"audio/mpeg\", headers=kopf)\n"}""")


def range_sofort(text):
    """Header und erster Block sofort aus dem Puffer. Icecast erst danach. Range wird nicht weitergereicht."""
    if text.count(RANGE["live"]) != 1 or text.count(RANGE["ice"]) != 1:
        raise SystemExit("STOP flugfunk Range-Anker")
    neu_live, neu_ice = RANGE["neu"].split("def icecast_response(base):", 1)
    text = text.replace(RANGE["live"], neu_live, 1)
    text = text.replace(RANGE["ice"], "def icecast_response(base):" + neu_ice, 1)
    if text.count("yield stille") < 2 or 'Accept-Ranges": "none"' not in text:
        raise SystemExit("STOP Range-Fix fehlt")
    return text


def anwenden(root, fullcheck, hashcheck, dry, kein, minute):
    if not dry and not kein and sperre(minute):
        print("STOP Neustart-Sperre Minute 40-04 Berlin, nichts geschrieben")
        return 2
    pfad = {
        "dashboard.py": os.path.join(root, "dashboard.py"),
        "lage_pages.py": os.path.join(root, "lage_pages.py"),
        "flugfunk.py": os.path.join(root, "flugfunk.py"),
        "fullcheck.sh": fullcheck,
    }
    texte = {}
    for name, soll in PAYLOAD["fest"].items():
        texte[name] = lade(pfad[name], soll, hashcheck)
    for name, alt, neu, n in PAYLOAD["paare"]:
        texte[name] = ersetze(texte[name], alt, neu, name, n)
    texte["dashboard.py"] = excepts(texte["dashboard.py"])
    texte["flugfunk.py"] = range_sofort(texte["flugfunk.py"])
    for name in ("dashboard.py", "lage_pages.py", "flugfunk.py"):
        compile(texte[name], name, "exec")
    if dry:
        print("dry-run: nichts geschrieben")
        for name in ("dashboard.py", "flugfunk.py", "fullcheck.sh"):
            data = texte[name].encode("utf-8")
            print("%s endstand sha16 %s bytes %s" % (name, sha256(data)[:16], len(data)))
        return 0
    for name in ("dashboard.py", "flugfunk.py", "fullcheck.sh"):
        schreibe(pfad[name], texte[name])
        data = open(pfad[name], "rb").read()
        print("%s endstand sha256 %s bytes %s" % (name, sha256(data), len(data)))
    print("entfernt: sw_sources-Wrapper sdHealth, _sw_banner-Wrapper, sw_sources-Wrapper piPolish")
    print("behalten: 25 Dashboard- und 37 SDR-Duplikate, Aufruf liegt zwischen den Fassungen")
    if not kein and not sperre(minute):
        for unit in ("prepper-dashboard", "prepper-sdr"):
            rc = subprocess.call(["systemctl", "restart", unit])
            print("restart %s rc %s" % (unit, rc))
    else:
        print("kein Neustart")
    return 0



def _range_probe(mod):
    import socket
    import threading
    import time
    from flask import Flask

    def langsam(bereit):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        bereit.append(srv.getsockname()[1])
        srv.settimeout(4)
        try:
            conn, _adr = srv.accept()
        except OSError:
            srv.close()
            return
        time.sleep(3)
        try:
            conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n" + b"\xff\xfb\x90\x00" * 8)
        except OSError:
            pass
        conn.close()
        srv.close()

    bereit = []
    threading.Thread(target=langsam, args=(bereit,), daemon=True).start()
    while not bereit:
        time.sleep(0.01)
    mod._ICECAST = ("127.0.0.1", bereit[0])
    app = Flask("range")
    app.add_url_rule("/flugfunk", endpoint="m", view_func=lambda: mod.icecast_response("/tmp"))
    app.add_url_rule("/api/flugfunk/stream", endpoint="s", view_func=lambda: mod.live_response("/tmp/leer"))
    client = app.test_client()
    start = time.perf_counter()
    antwort = client.get("/flugfunk", headers={"Range": "bytes=0-1"}, buffered=False)
    dauer = time.perf_counter() - start
    block = next(antwort.response)
    antwort.close()
    if antwort.status_code != 200 or dauer >= 1.0 or antwort.headers.get("Accept-Ranges") != "none" or len(block) < 16:
        raise SystemExit("selftest range %s %s" % (antwort.status_code, round(dauer, 3)))
    start = time.perf_counter()
    strom = client.get("/api/flugfunk/stream", headers={"Range": "bytes=0-1"}, buffered=False)
    dauer = time.perf_counter() - start
    block = next(strom.response)
    strom.close()
    if strom.status_code != 200 or dauer >= 1.0 or strom.mimetype != "audio/mpeg" or len(block) < 16:
        raise SystemExit("selftest stream %s %s" % (strom.status_code, round(dauer, 3)))


def _basis():
    for cand in (os.environ.get("HAERTEN_BASIS"), "/tmp/pi-stand", os.path.join(os.getcwd(), "pi-stand")):
        if cand and os.path.isfile(os.path.join(cand, "dashboard.py")) and os.path.isfile(os.path.join(cand, "flugfunk.py")):
            return cand
    raise SystemExit("STOP Selbsttest-Basis fehlt")


def selftest():
    import importlib.util
    import tempfile
    src = _basis()
    arbeit = tempfile.mkdtemp(prefix="aufraeumen-")
    for name in ("dashboard.py", "lage_pages.py", "flugfunk.py", "fullcheck.sh"):
        shutil.copy2(os.path.join(src, name), os.path.join(arbeit, name))
    fc = os.path.join(arbeit, "fullcheck.sh")
    def laden(pfad, name):
        spec = importlib.util.spec_from_file_location(name, pfad)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    arte = os.path.dirname(os.path.abspath(__file__))
    if laden(os.path.join(arte, "apply-haerten-a.py"), "ha").anwenden(arbeit, fc, True, False, True, 12) != 0:
        raise SystemExit("selftest A")
    if laden(os.path.join(arte, "apply-haerten-b.py"), "hb").anwenden(arbeit, fc, True, False, True, 12) != 0:
        raise SystemExit("selftest B")
    roh = open(fc, encoding="utf-8").read()
    roh = roh.replace("bd5efb5b00eb43b4", "78d3c91944d6872d", 1)
    roh = roh.replace("1391222", "1391894", 1)
    roh = roh.replace("e9ea014b5a4ff121", "696638fd9ea3cd17", 1)
    roh = roh.replace("230936", "231498", 1)
    open(fc, "w", encoding="utf-8").write(roh)
    dash = os.path.join(arbeit, "dashboard.py")
    os.chmod(dash, 0o640)
    os.chmod(fc, 0o640)
    if anwenden(arbeit, fc, True, True, True, 12) != 0:
        raise SystemExit("selftest dry")
    if anwenden(arbeit, fc, True, False, False, 41) != 2:
        raise SystemExit("selftest sperre")
    if anwenden(arbeit, fc, True, False, True, 15) != 0:
        raise SystemExit("selftest lauf")
    text = open(dash, encoding="utf-8").read()
    if 'os.system("pip install psutil")' in text or "def save_pegel_mesh_status" not in text:
        raise SystemExit("selftest kern")
    if re.search(r"(?m)^[ \t]*except:\s*$", text) or 'if callable(globals().get("sw_sources"))' in text:
        raise SystemExit("selftest except")
    if "r.innerHTML=S.rows_html" in text or "s.textContent=c.textContent" not in text:
        raise SystemExit("selftest text")
    if "Content-Security-Policy-Report-Only" not in text or "X-Frame-Options" not in text:
        raise SystemExit("selftest header")
    if text.count("def nina_bayern_auto_enabled") != 3 or text.count("def _ws_score") != 2:
        raise SystemExit("selftest duplikat")
    if (os.stat(dash).st_mode & 0o777) != 0o640 or (os.stat(fc).st_mode & 0o777) != 0o640:
        raise SystemExit("selftest mode")
    neu = open(fc, encoding="utf-8").read()
    if "3a049826f2aae3e4" not in neu or "1389101" not in neu or "696638fd9ea3cd17" not in neu:
        raise SystemExit("selftest soll")
    if FULLCHECK != "/home/fmg/fullcheck.sh":
        raise SystemExit("selftest pfad")
    ff_text = open(os.path.join(arbeit, "flugfunk.py"), encoding="utf-8").read()
    if "onstalled" not in ff_text or ff_text.count("yield stille") < 2:
        raise SystemExit("selftest fallback")
    spec = importlib.util.spec_from_file_location("ffc", os.path.join(arbeit, "flugfunk.py"))
    ff = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ff)
    _range_probe(ff)
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    parser.add_argument("--fullcheck", default=FULLCHECK)
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    return anwenden(args.basis, args.fullcheck, True, args.dry_run, args.kein_neustart, berlin_minute())


if __name__ == "__main__":
    raise SystemExit(main())
