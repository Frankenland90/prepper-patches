#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply-flugfunk-7e. Zubringer alle 15 s, Mount per GET, /luft unter 4 s."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

PAYLOAD = json.loads(r"""{"dateien": {"flugfunk.py": [["    \" sys.exit(2)\\n\"\n", "    \" sys.stderr.write('flugfunk: ice-antwort-nicht-200\\\\n'); sys.exit(2)\\n\"\n"], ["\ndef _mount_ok():\n", "\n_ICE_MELD = {}\n\n\ndef _ice_melden(text):\n    jetzt = time.time()\n    if jetzt - _ICE_MELD.get(text, 0.0) < 60:\n        return\n    _ICE_MELD[text] = jetzt\n    print(\"flugfunk: zubringer %s\" % text, flush=True)\n\n\ndef _mount_ok():\n"], ["        sock.sendall(b\"HEAD /flugfunk HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n\")\n", "        sock.sendall(b\"GET /flugfunk HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nRange: bytes=0-0\\r\\nConnection: close\\r\\n\\r\\n\")\n"], ["    if not os.path.isfile(pw) or not _port_auf(\"127.0.0.1\", 8000) or not shutil.which(\"ffmpeg\"):\n        return\n    datei = live_mp3(base) or \"\"\n", "    if not os.path.isfile(pw):\n        _ice_melden(\"Passwortdatei fehlt\")\n        return\n    if not _port_auf(\"127.0.0.1\", 8000):\n        _ice_melden(\"Port 8000 antwortet nicht\")\n        return\n    datei = live_mp3(base) or \"\"\n    if datei and not shutil.which(\"ffmpeg\"):\n        _ice_melden(\"ffmpeg fehlt, nur Stille\")\n        datei = \"\"\n"], ["        stdin=quelle, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,\n", "        stdin=quelle, stdout=subprocess.DEVNULL,\n        stderr=open(os.path.join(base, \"flugfunk-icecast.log\"), \"ab\"),\n"], ["        self.thread.start()\n        return True\n\n", "        self.thread.start()\n        self.ice_thread = threading.Thread(target=self._ice_loop, args=(base,), daemon=True)\n        self.ice_thread.start()\n        return True\n\n    def _ice_loop(self, base):\n        \"\"\"Alle 15 s, unabhaengig vom Funk-Durchgang. Fehler ins Journal.\"\"\"\n        while not self.stop.is_set():\n            try:\n                icecast_sicher(base)\n            except Exception as exc:\n                print(\"flugfunk: zubringer %s\" % type(exc).__name__, flush=True)\n            self.stop.wait(15)\n\n"], ["    assert len(bytes.fromhex(_STILLE_MP3)) == 104\n", "    assert len(bytes.fromhex(_STILLE_MP3)) == 104 and \"def _ice_loop\" in open(__file__, encoding=\"utf-8\").read()\n"]], "luft.py": [["import math\nfrom datetime import datetime\n", "import math\nimport time\nfrom datetime import datetime\n"], ["    )\n    try:\n        r = requests.get(url, headers=UA, timeout=25)\n        r.raise_for_status()\n        rows = list(csv.DictReader(io.StringIO(r.text)))\n", "    )\n    try:\n        r = requests.get(url, headers=UA, timeout=3)\n        r.raise_for_status()\n        rows = list(csv.DictReader(io.StringIO(r.text)))\n"], ["    url = \"https://data.sensor.community/airrohr/v1/filter/box=\" + SENSOR_BOX\n    try:\n        r = requests.get(url, headers=UA, timeout=25)\n        r.raise_for_status()\n        data = r.json()\n", "    url = \"https://data.sensor.community/airrohr/v1/filter/box=\" + SENSOR_BOX\n    try:\n        r = requests.get(url, headers=UA, timeout=3)\n        r.raise_for_status()\n        data = r.json()\n"], ["                timeout=15,\n", "                timeout=3,\n"], ["def fetch_luft():\n    firms = fetch_firms()\n    sensors = fetch_sensors()\n    winds = fetch_winds()\n", "_LUFT_CACHE = {\"t\": 0.0, \"data\": None}\n\n\ndef _fetch_luft_roh():\n    from concurrent.futures import ThreadPoolExecutor\n    with ThreadPoolExecutor(max_workers=3) as pool:\n        firms_f = pool.submit(fetch_firms)\n        sensors_f = pool.submit(fetch_sensors)\n        winds_f = pool.submit(fetch_winds)\n        firms = firms_f.result(timeout=3)\n        sensors = sensors_f.result(timeout=3)\n        winds = winds_f.result(timeout=3)\n"], ["        \"updated\": _now_str(),\n    }\n\n\n", "        \"updated\": _now_str(),\n    }\n\n\ndef fetch_luft():\n    \"\"\"Seite /luft darf nicht an NASA/Sensor/Meteo haengen. Cache 90 s, Deckel 4 s.\"\"\"\n    jetzt = time.time()\n    alt = _LUFT_CACHE[\"data\"]\n    if isinstance(alt, dict) and jetzt - _LUFT_CACHE[\"t\"] < 90:\n        return alt\n    from concurrent.futures import ThreadPoolExecutor\n    try:\n        with ThreadPoolExecutor(max_workers=1) as pool:\n            data = pool.submit(_fetch_luft_roh).result(timeout=4)\n    except Exception as exc:\n        print(\"luft: %s\" % type(exc).__name__, flush=True)\n        return alt or {\n            \"stage\": \"green\", \"label\": \"ruhig\", \"color\": \"#94a3b8\",\n            \"firms_ok\": False, \"firms_error\": \"timeout\", \"n_hotspots\": 0,\n            \"hotspots\": [], \"nearest\": None, \"sensors\": {}, \"winds\": [],\n            \"updated\": _now_str(),\n        }\n    _LUFT_CACHE[\"t\"] = jetzt\n    _LUFT_CACHE[\"data\"] = data\n    return data\n\n\n"]]}, "ice_alt": "  CODE=\"$(curl -sI -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8000/flugfunk || true)\"\n  if [[ \"$CODE\" == \"200\" ]]; then ok \"Icecast /flugfunk\" \"Mount live\"\n  elif systemctl is-active --quiet prepper-icecast; then warn \"Icecast /flugfunk\" \"HTTP $CODE\" \"Mount 404 bei laufendem Icecast\"\n  else info \"Icecast /flugfunk\" \"Dienst nicht aktiv\"; fi\n", "ice_neu": "  CODE=\"$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -r 0-0 http://127.0.0.1:8000/flugfunk || true)\"\n  if [[ \"$CODE\" == \"200\" ]]; then ok \"Icecast /flugfunk\" \"Mount live\"\n  elif systemctl is-active --quiet prepper-icecast; then warn \"Icecast /flugfunk\" \"HTTP $CODE\" \"Mount nicht 200\"\n  else info \"Icecast /flugfunk\" \"Dienst nicht aktiv\"; fi\n"}""")

FEST = {
    "flugfunk.py": ("4a21cfa1feb4db5c", 96546),
    "dashboard.py": ("bd5efb5b00eb43b4", 1391222),
    "prepper_sdr.py": ("17ee0ae046d25be9", 794528),
    "prepper_log.py": ("fd79a1c81de167f0", 17791),
    "luft.py": ("0ccae0834ab27f6d", 10214),
}
FC_HASH = "367d1ef3dbf83a20fb66bb624983d58357eeed52b81318423350db865866b247"
FC_BYTES = 99278
BASIS = "/home/fmg/prepper-dashboard"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def im_fenster(minute):
    return 5 <= int(minute) <= 39


def berlin_minute():
    if ZoneInfo is not None:
        return datetime.now(ZoneInfo("Europe/Berlin")).minute
    return datetime.now().minute


def ersetze(text, alt, neu, name):
    n = text.count(alt)
    if n != 1:
        raise SystemExit("STOP %s Anker %s" % (name, n))
    return text.replace(alt, neu, 1)


def sichere(path):
    if not os.path.isfile(path):
        return
    for i in (3, 2, 1):
        alt = "%s.bak-7e-%s" % (path, i)
        vor = "%s.bak-7e-%s" % (path, i - 1) if i > 1 else path + ".bak-7e-1"
        if i == 1:
            shutil.copy2(path, alt)
        elif os.path.isfile(vor):
            os.replace(vor, alt)


def pruefe(path, soll, hashcheck):
    data = open(path, "rb").read()
    ist = (sha256(data)[:16], len(data))
    if hashcheck and ist != soll:
        print("STOP %s ist %s/%s soll %s/%s" % (path, ist[0], ist[1], soll[0], soll[1]))
        raise SystemExit(2)
    return data.decode("utf-8")


def anwenden(root, fullcheck, hashcheck, dry, kein, minute):
    if not im_fenster(minute):
        print("STOP ausserhalb Fenster 05-39, nichts geschrieben")
        return 2
    pfade = {name: os.path.join(root, name) for name in FEST}
    texte = {}
    for name, soll in FEST.items():
        texte[name] = pruefe(pfade[name], soll, hashcheck)
    fc = open(fullcheck, "rb").read()
    if hashcheck and (sha256(fc) != FC_HASH or len(fc) != FC_BYTES):
        print("STOP fullcheck ist %s/%s" % (sha256(fc)[:16], len(fc)))
        return 2
    fc_text = fc.decode("utf-8")
    for name, paare in PAYLOAD["dateien"].items():
        for alt, neu in paare:
            texte[name] = ersetze(texte[name], alt, neu, name)
    fc_text = ersetze(fc_text, PAYLOAD["ice_alt"], PAYLOAD["ice_neu"], "fullcheck")
    if 'FC_VERSION="2.9"' in fc_text:
        fc_text = ersetze(fc_text, 'FC_VERSION="2.9"', 'FC_VERSION="2.10"', "version")
    elif 'FC_VERSION="2.8"' in fc_text:
        fc_text = ersetze(fc_text, 'FC_VERSION="2.8"', 'FC_VERSION="2.10"', "version")
    else:
        print("STOP fullcheck-Version fehlt")
        return 2
    if "HEAD /flugfunk" in texte["flugfunk.py"] or "curl -sI" in fc_text:
        print("STOP HEAD-Check noch vorhanden")
        return 2
    if hashcheck:
        compile(texte["flugfunk.py"], "flugfunk.py", "exec")
        compile(texte["luft.py"], "luft.py", "exec")
    if dry:
        print("dry-run: nichts geschrieben")
        for name in ("flugfunk.py", "luft.py"):
            print(name, sha256(texte[name].encode("utf-8"))[:16], len(texte[name].encode("utf-8")))
        print("fullcheck", sha256(fc_text.encode("utf-8"))[:16], len(fc_text.encode("utf-8")))
        return 0
    for name in ("flugfunk.py", "luft.py"):
        sichere(pfade[name])
        tmp = pfade[name] + ".7e-tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(texte[name])
        os.replace(tmp, pfade[name])
        data = open(pfade[name], "rb").read()
        print("%s endstand sha16 %s bytes %s" % (name, sha256(data)[:16], len(data)))
    sichere(fullcheck)
    tmp = fullcheck + ".7e-tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(fc_text)
    probe = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
    if probe.returncode != 0:
        os.remove(tmp)
        print("STOP bash -n, fullcheck nicht ersetzt")
        return 2
    os.replace(tmp, fullcheck)
    data = open(fullcheck, "rb").read()
    print("fullcheck.sh endstand sha256 %s bytes %s" % (sha256(data), len(data)))
    print("dashboard.py unveraendert sha16 bd5efb5b00eb43b4 bytes 1391222")
    print("Icecast-xml unveraendert, kein sudo, kein Passwort")
    if hashcheck and not kein:
        for unit in ("prepper-sdr", "prepper-dashboard"):
            rc = subprocess.call(["systemctl", "restart", unit])
            print("restart %s rc %s" % (unit, rc))
    else:
        print("kein Neustart")
    return 0


def selftest():
    import tempfile
    alt_fc = "ok(){ :; }\nwarn(){ :; }\ninfo(){ :; }\nFC_VERSION=\"2.9\"\n" + PAYLOAD["ice_alt"]
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "app")
        os.makedirs(root)
        for name, paare in PAYLOAD["dateien"].items():
            open(os.path.join(root, name), "w", encoding="utf-8").write("".join(a for a, _ in paare))
        for name in FEST:
            path = os.path.join(root, name)
            if not os.path.isfile(path):
                open(path, "w", encoding="utf-8").write("# %s\n" % name)
        fc = os.path.join(tmp, "fullcheck.sh")
        open(fc, "w", encoding="utf-8").write(alt_fc)
        vorher = open(os.path.join(root, "flugfunk.py"), "rb").read()
        rc = anwenden(root, fc, False, False, True, 4)
        if rc != 2 or open(os.path.join(root, "flugfunk.py"), "rb").read() != vorher:
            raise SystemExit("selftest fenster")
        rc = anwenden(root, fc, False, True, True, 12)
        if rc != 0 or b"def _ice_loop" in open(os.path.join(root, "flugfunk.py"), "rb").read():
            raise SystemExit("selftest dry")
        rc = anwenden(root, fc, False, False, True, 12)
        if rc != 0:
            raise SystemExit("selftest lauf %s" % rc)
        text = open(os.path.join(root, "flugfunk.py"), encoding="utf-8").read()
        luft = open(os.path.join(root, "luft.py"), encoding="utf-8").read()
        fc_text = open(fc, encoding="utf-8").read()
        if "def _ice_loop" not in text or "HEAD /flugfunk" in text:
            raise SystemExit("selftest flugfunk")
        if "timeout=4" not in luft and "timeout=4)" not in luft and "result(timeout=4)" not in luft:
            raise SystemExit("selftest luft")
        if "curl -sI" in fc_text or "-r 0-0" not in fc_text or 'FC_VERSION="2.10"' not in fc_text:
            raise SystemExit("selftest fullcheck")
        if "icecast://source:${" in text:
            raise SystemExit("selftest argv")
    print("selftest gruen")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--kein-neustart", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--basis", default=BASIS)
    parser.add_argument("--fullcheck", default="/home/fmg/fullcheck.sh")
    parser.add_argument("--fullcheck-hash", default=FC_HASH)
    args = parser.parse_args(argv)
    if args.fullcheck_hash != FC_HASH:
        print("STOP fullcheck-hash weicht vom Default ab")
        return 2
    if args.selftest:
        return selftest()
    return anwenden(args.basis, args.fullcheck, True, args.dry_run, args.kein_neustart, berlin_minute())


if __name__ == "__main__":
    raise SystemExit(main())
