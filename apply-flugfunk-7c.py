# -*- coding: utf-8 -*-
import argparse, base64, hashlib, json, os, secrets, shutil, subprocess, sys, tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

FEST = {
    "dashboard.py": ("f3ee3b89bbd79aa9", 1390250),
    "flugfunk.py": ("aae2b0f8f2a3ab53", 91686),
    "prepper_sdr.py": ("17ee0ae046d25be9", 794528),
    "prepper_log.py": ("f089377b322789e3", 17593),
}
FC_FEST = "6afaa565ef658ccb684128d6cfa287432a31d908a26a61c7cdcd38c054425e59"
FC_BYTES = 99209
FULL = Path("/home/fmg/fullcheck.sh")
ICE_ALT = """  if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8000/flugfunk; then ok "Icecast /flugfunk" "Mount"
  elif ! command -v icecast2 >/dev/null 2>&1; then info "Icecast /flugfunk" "Paketschritt offen"
  else warn "Icecast /flugfunk" "Mount fehlt" "icecast2 -c icecast-flugfunk.xml"; fi
"""
ICE_NEU = """  if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8000/flugfunk; then ok "Icecast /flugfunk" "Mount live"
  elif systemctl is-active --quiet prepper-icecast && ! find "$APP/flugfunk-audio/live" -name 'live*.mp3' -mmin -5 2>/dev/null | grep -q .; then warn "Icecast /flugfunk" "laeuft, keine Live-Datei seit 5 min" "rtl_airband"
  else info "Icecast /flugfunk" "Mount noch nicht, Datei frisch oder Dienst aus"; fi
"""
SUDO_BLOCK = """sudo install -o icecast2 -g icecast -m 640 /home/fmg/prepper-dashboard/icecast-flugfunk.xml /etc/icecast2/flugfunk.xml
sudo tee /etc/systemd/system/prepper-icecast.service >/dev/null <<'EOF'
[Unit]
Description=Prepper Icecast Flugfunk
After=network.target

[Service]
Type=simple
User=icecast2
Group=icecast
ExecStart=/usr/bin/icecast2 -c /etc/icecast2/flugfunk.xml
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now prepper-icecast.service
sudo systemctl restart prepper-icecast.service
"""

def sha(data):
    return hashlib.sha256(data).hexdigest()

def fenster(jetzt):
    jetzt = jetzt.astimezone(ZoneInfo("Europe/Berlin"))
    return 5 <= jetzt.minute <= 39, "Berlin %s Minute %02d" % (jetzt.strftime("%H:%M"), jetzt.minute)

def laden():
    return json.loads(PAYLOAD_TEXT)

def tausch(data, old, new):
    if new in data:
        return data
    if data.count(old) != 1:
        raise RuntimeError("stelle")
    return data.replace(old, new, 1)

_KACHEL = (
    "def _kachel_css(html):\n"
    "    stil = ('<style id=\"kachel-dunkel\">'"
    "'#lbText{background:#0f172a;color:#e2e8f0;-webkit-text-fill-color:#e2e8f0;"
    "border:1px solid #334155;border-radius:8px;padding:8px;width:100%;box-sizing:border-box}'"
    "'#flugfunkBox{max-width:100%;width:100%;min-width:0;box-sizing:border-box;overflow:visible}'"
    "'#flugfunkBox *{box-sizing:border-box;max-width:100%}'"
    "'#ffKopf,#ffAtis,#ffMsgs,#ffNot,#ffWetter,#ffZeit{overflow-wrap:anywhere;word-break:break-word}'"
    "'#ffKarte{display:block;width:100%;max-width:100%;aspect-ratio:1/1}'"
    "'#ffKarte svg{width:100%;height:100%;display:block}'"
    "'#ffAudio{display:block;width:100%;max-width:100%}'"
    "'</style>')\n"
    "    if 'id=\"kachel-dunkel\"' in html or ('id=\"lbText\"' not in html and 'id=\"flugfunkBox\"' not in html):\n"
    "        return html\n"
    "    stelle = html.find('</head>')\n"
    "    if stelle < 0:\n"
    "        stelle = html.find('<body')\n"
    "    return (stil + html) if stelle < 0 else html[:stelle] + stil + html[stelle:]\n\n\n"
)
DASH_PAARE = (
    ("def _flugfunk_after(resp):\n", _KACHEL + "def _flugfunk_after(resp):\n"),
    (
        '        neu = _ff.funk_seite(body, "/adsb" if _ff_rq.path == "/adsb" else "/funk")\n',
        '        neu = _kachel_css(_ff.funk_seite(body, "/adsb" if _ff_rq.path == "/adsb" else "/funk"))\n',
    ),
    (
        '            neu = _pl.in_seite(resp.get_data(as_text=True), request.path)\n',
        '            neu = _kachel_css(_pl.in_seite(resp.get_data(as_text=True), request.path))\n',
    ),
)


def fullcheck_neu(text, dash_sha, dash_n):
    if "elDBYTES" in text:
        raise RuntimeError("elif")
    if "Mount live" in text and 'FC_VERSION="2.8"' in text:
        return text
    if 'FC_VERSION="2.7"' not in text:
        raise RuntimeError("version")
    if ICE_ALT not in text:
        raise RuntimeError("anker")
    neu = text.replace('FC_VERSION="2.7"', 'FC_VERSION="2.8"', 1)
    neu = neu.replace(ICE_ALT, ICE_NEU, 1)
    return _soll_dash(neu, dash_sha, dash_n)


def _soll_dash(text, dash_sha, dash_n):
    neu = text
    for name, wert in (("FC_DASH_SHA16", dash_sha), ("FC_DASH_BYTES", str(dash_n))):
        muster = r"(\$\{%s:-)[^}\n]+" % name
        if not __import__("re").search(muster, neu):
            raise RuntimeError(name)
        neu, n = __import__("re").subn(muster, r"\g<1>" + wert, neu, count=1)
        if n != 1:
            raise RuntimeError(name)
    if "elDBYTES" in neu:
        raise RuntimeError("elif")
    return neu

def bash_n(text):
    tmp = Path(tempfile.mkstemp(prefix="fullcheck-", suffix=".sh")[1])
    try:
        tmp.write_text(text)
        r = subprocess.run(["bash", "-n", str(tmp)], capture_output=True, text=True)
        return r.returncode == 0, (r.stderr or "").strip()
    finally:
        tmp.unlink(missing_ok=True)

def sichern(path, data, ende):
    path = Path(path)
    stempel = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S")
    alt = sorted(path.parent.glob(path.name + ".bak-" + ende + "-*"))
    bak = Path(str(path) + ".bak-" + ende + "-" + stempel)
    shutil.copy2(path, bak)
    if bak.read_bytes() != data:
        bak.unlink()
        raise RuntimeError("Sicherung")
    for alt_pfad in alt[:-2]:
        alt_pfad.unlink(missing_ok=True)

def schreiben(path, data, ende, mode=None):
    path = Path(path)
    recht = mode if mode is not None else (path.stat().st_mode & 0o777 if path.exists() else 0o644)
    tmp = path.with_name("." + path.name + ".tmp-" + ende)
    if tmp.exists():
        raise RuntimeError("temporaer")
    roh = data if isinstance(data, bytes) else data.encode()
    try:
        with open(tmp, "wb") as handle:
            handle.write(roh)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, recht)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)

def icecast_dateien(ordner):
    geheim = secrets.token_hex(18)
    basis = Path(ordner)
    (basis / "bin").mkdir(exist_ok=True)
    schreiben(basis / "icecast-flugfunk.pw", geheim + "\n", "flugfunk7c", 0o600)
    xml = (
        "<icecast><hostname>127.0.0.1</hostname>"
        "<listen-socket><port>8000</port><bind-address>127.0.0.1</bind-address></listen-socket>"
        "<authentication><source-password>%s</source-password><relay-password>%s</relay-password>"
        "<admin-user>admin</admin-user><admin-password>%s</admin-password></authentication>"
        "<mount><mount-name>/flugfunk</mount-name><public>0</public></mount>"
        "<paths><logdir>/var/log/icecast2</logdir><webroot>/usr/share/icecast2/web</webroot>"
        "<adminroot>/usr/share/icecast2/admin</adminroot></paths></icecast>\n"
    ) % (geheim, geheim, geheim)
    schreiben(basis / "icecast-flugfunk.xml", xml, "flugfunk7c", 0o600)
    schreiben(basis / "bin" / "flugfunk-icecast.sh",
              "#!/bin/sh\n# Zubringer liegt in flugfunk.py. Dieses Skript enthaelt kein Passwort.\nexit 0\n",
              "flugfunk7c", 0o700)
    print("Neues Source-Passwort in icecast-flugfunk.pw (600) und flugfunk.xml. Nicht angezeigt. Gruppe icecast, User icecast2.")
    return geheim

def unit_install(ordner):
    basis = Path(ordner)
    cmd = ["sudo", "-n", "install", "-o", "icecast2", "-g", "icecast", "-m", "640",
           str(basis / "icecast-flugfunk.xml"), "/etc/icecast2/flugfunk.xml"]
    if str(ordner) != "/home/fmg/prepper-dashboard":
        print("Testordner, kein sudo")
        return
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("sudo -n fehlgeschlagen. Kompletter Block, Gruppe icecast:")
        print(SUDO_BLOCK)
        return
    r2 = subprocess.run(["sudo", "-n", "systemctl", "restart", "prepper-icecast.service"], capture_output=True, text=True)
    if r2.returncode != 0:
        print("sudo -n fehlgeschlagen. Kompletter Block, Gruppe icecast:")
        print(SUDO_BLOCK)
        return
    print("prepper-icecast neu gestartet, Bind 127.0.0.1, keine Firewall")

def apply_dir(ordner, dry, kein, jetzt=None, hashcheck=True, fullcheck_hash=None, full_pfad=None):
    print("Passwort geht nur in die Datei, nie in argv. ffmpeg liest die neueste live*.mp3 per tail -F.")
    print("prepper-sdr, prepper-dashboard und prepper-icecast muessen neu starten. Ein Pi-Neustart wird nicht ausgefuehrt.")
    ordner = Path(ordner)
    roh = laden()
    ziel = {}
    for name, fest in FEST.items():
        pfad = ordner / name
        if not pfad.is_file():
            if not hashcheck and name in ("dashboard.py", "prepper_sdr.py"):
                continue
            print("STOP: %s fehlt" % pfad)
            return 2
        data = pfad.read_bytes()
        print("%s sha16 %s bytes %d" % (name, sha(data)[:16], len(data)))
        if hashcheck and (not sha(data).startswith(fest[0]) or len(data) != fest[1]):
            print("STOP: %s ist nicht der Stand nach flugfunk-7b" % name)
            print("Live-Hash sha256 %s" % sha(data))
            return 2
        neu = data
        if name == "dashboard.py":
            try:
                for alt, neu_text in DASH_PAARE:
                    neu = tausch(neu, alt.encode(), neu_text.encode())
            except RuntimeError:
                print("STOP: Stelle in dashboard.py unbekannt. Nichts geschrieben.")
                return 2
        elif name in ("flugfunk.py", "prepper_log.py"):
            try:
                schluessel = "flugfunk" if name == "flugfunk.py" else "log"
                for paar in roh[schluessel]:
                    neu = tausch(neu, base64.b64decode(paar["old"]), base64.b64decode(paar["new"]))
            except RuntimeError:
                print("STOP: Stelle in %s unbekannt. Nichts geschrieben." % name)
                return 2
            if hashcheck:
                try:
                    compile(neu, name, "exec")
                except SyntaxError:
                    print("STOP: flugfunk.py kompiliert nicht. Nichts geschrieben.")
                    return 2
        ziel[name] = (pfad, data, neu)
        print("%s endstand sha16 %s bytes %d" % (name, sha(neu)[:16], len(neu)))
    fc_pfad = Path(full_pfad) if full_pfad else FULL
    if not fc_pfad.is_file():
        print("STOP: fullcheck.sh fehlt")
        return 2
    fc_alt = fc_pfad.read_bytes()
    print("fullcheck.sh sha256 %s bytes %d" % (sha(fc_alt), len(fc_alt)))
    if hashcheck and (sha(fc_alt) != FC_FEST or len(fc_alt) != FC_BYTES):
        print("STOP: fullcheck ist nicht der Stand 2.7")
        print("Live-Hash sha256 %s" % sha(fc_alt))
        return 2
    if fullcheck_hash != sha(fc_alt):
        print("STOP: fullcheck bestaetigen mit --fullcheck-hash %s" % sha(fc_alt))
        return 2
    try:
        dash = ziel.get("dashboard.py")
        dash_sha = sha(dash[2])[:16] if dash else FEST["dashboard.py"][0]
        dash_n = len(dash[2]) if dash else FEST["dashboard.py"][1]
        fc = fullcheck_neu(fc_alt.decode("utf-8"), dash_sha, dash_n)
    except RuntimeError as exc:
        print("STOP: fullcheck-Anker %s. Nichts geschrieben." % exc)
        return 2
    ok_bash, fehler = bash_n(fc)
    if not ok_bash:
        print("STOP: bash -n. Rollback, nichts geschrieben. %s" % fehler)
        return 2
    print("fullcheck.sh endstand sha16 %s bytes %d, bash -n gruen" % (sha(fc.encode())[:16], len(fc.encode())))
    gleich = all(alt == neu for _p, alt, neu in ziel.values()) and fc_alt.decode("utf-8") == fc
    if gleich:
        print("bereits installiert, keine Aenderung, kein Neustart")
        return 0
    frei, meldung = fenster(jetzt or datetime.now().astimezone())
    print(meldung)
    if dry:
        print("DRY-RUN: kein Backup, kein Schreiben, kein Neustart")
        return 0
    if not frei:
        print("STOP: Neustart nur Minute 05-39 Berlin. Nichts geschrieben.")
        return 2
    for pfad, alt, neu in ziel.values():
        if alt != neu:
            sichern(pfad, alt, "flugfunk7c")
            schreiben(pfad, neu, "flugfunk7c")
    sichern(fc_pfad, fc_alt, "flugfunk7c")
    schreiben(fc_pfad, fc.encode(), "flugfunk7c")
    geheim = icecast_dateien(ordner)
    print("geschrieben. prepper_sdr.py unveraendert. dashboard.py endstand steht oben.")
    if kein:
        print("kein Neustart.")
        if str(ordner) == "/home/fmg/prepper-dashboard":
            print("sudo -n nicht ausgefuehrt. Block mit Gruppe icecast:")
            print(SUDO_BLOCK)
        return 0
    unit_install(ordner)
    if str(ordner) != "/home/fmg/prepper-dashboard":
        print("Testordner, kein systemctl")
        return 0
    for dienst in ("prepper-sdr.service", "prepper-dashboard.service"):
        subprocess.run(["systemctl", "restart", dienst], check=False)
        print("Neustart %s" % dienst)
    del geheim
    return 0

FIX = """#!/bin/bash
# fullcheck.sh
FC_VERSION="2.7"
ok() { :; }
warn() { :; }
fail() { :; }
info() { :; }
DASH_SHA16="${FC_DASH_SHA16:-57df9398bd5813bc}"
DASH_BYTES="${FC_DASH_BYTES:-1390064}"
APP="${APP:-/home/fmg/prepper-dashboard}"
if [[ "$DSH" == "$DASH_SHA16" ]]; then ok "dashboard.py sha16" "$DSH"
elif [[ "$DSH" == "alt" ]]; then ok "alt" "x"
else warn "dashboard.py sha16" "$DSH" "Soll"; fi
""" + ICE_ALT + """
  # --- SDR-Watchdog (Datenlage der Sticks, nur lesen)
"""

def selftest():
    assert FC_FEST == "6afaa565ef658ccb684128d6cfa287432a31d908a26a61c7cdcd38c054425e59" and FC_BYTES == 99209
    assert FEST["flugfunk.py"] == ("aae2b0f8f2a3ab53", 91686)
    assert "Group=icecast\n" in SUDO_BLOCK and "Group=icecast2" not in SUDO_BLOCK
    roh = laden()
    ordner = Path(tempfile.mkdtemp(prefix="flugfunk7c-"))
    try:
        (ordner / "dashboard.py").write_text(
            'def _flugfunk_after(resp):\n'
            '        neu = _ff.funk_seite(body, "/adsb" if _ff_rq.path == "/adsb" else "/funk")\n'
            'def _log_after(resp):\n'
            '            neu = _pl.in_seite(resp.get_data(as_text=True), request.path)\n'
        )
        for name, key in (("flugfunk.py", "flugfunk"), ("prepper_log.py", "log")):
            daten = b""
            for paar in roh[key]:
                daten += base64.b64decode(paar["old"]) + b"\n"
            (ordner / name).write_bytes(daten)
        fp = ordner / "fullcheck.sh"
        fp.write_text(FIX)
        vorher = fp.read_bytes()
        assert apply_dir(ordner, True, True, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp) == 0
        assert fp.read_bytes() == vorher
        von = datetime(2026, 11, 26, 20, 4, tzinfo=ZoneInfo("Europe/Berlin"))
        assert apply_dir(ordner, False, False, jetzt=von, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp) == 2
        innen = datetime(2026, 11, 26, 20, 10, tzinfo=ZoneInfo("Europe/Berlin"))
        protokoll = tempfile.NamedTemporaryFile("w+", delete=False)
        alt = sys.stdout
        try:
            sys.stdout = protokoll
            rc = apply_dir(ordner, False, True, jetzt=innen, hashcheck=False, fullcheck_hash=sha(vorher), full_pfad=fp)
            protokoll.flush()
            text = Path(protokoll.name).read_text()
        finally:
            sys.stdout = alt
            os.unlink(protokoll.name)
        assert rc == 0
        neu = fp.read_text()
        assert 'FC_VERSION="2.8"' in neu and "Mount live" in neu and "mmin -5" in neu and "elDBYTES" not in neu
        dash_neu = (ordner / "dashboard.py").read_bytes()
        assert b"kachel-dunkel" in dash_neu and b"#0f172a" in dash_neu and b"aspect-ratio:1/1" in dash_neu
        assert sha(dash_neu)[:16] in neu and str(len(dash_neu)) in neu
        assert bash_n(neu)[0]
        ff = (ordner / "flugfunk.py").read_text()
        assert 'filename_template = "live";' in ff and '["tail", "-F"' in ff and "aspect-ratio:1/1" in ff and "icecast://source:${" not in ff
        assert "background:#0f172a" in (ordner / "prepper_log.py").read_text()
        skript = (ordner / "bin" / "flugfunk-icecast.sh").read_text()
        assert "icecast://source:" not in skript
        pw = (ordner / "icecast-flugfunk.pw").read_text().strip()
        xml = (ordner / "icecast-flugfunk.xml").read_text()
        assert pw and pw not in text and pw in xml and "127.0.0.1" in xml
        assert oct((ordner / "icecast-flugfunk.pw").stat().st_mode & 0o777) == "0o600"
    finally:
        shutil.rmtree(ordner, ignore_errors=True)
    return "flugfunk-7c ok"

PAYLOAD_TEXT = "{\"flugfunk\": [{\"old\": \"ICAgICAgdmFyIHN2Zz0nPHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjEwMCUiIGhlaWdodD0iMTUwIiBzdHlsZT0iYmFja2dyb3VuZDojMWUyOTNiO2JvcmRlcjoxcHggc29saWQgIzY0NzQ4YjtkaXNwbGF5OmJsb2NrIj4nOwo=\", \"new\": \"ICAgICAgdmFyIHN2Zz0nPHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgcHJlc2VydmVBc3BlY3RSYXRpbz0ieE1pZFlNaWQgbWVldCIgc3R5bGU9IndpZHRoOjEwMCU7aGVpZ2h0OjEwMCU7bWF4LXdpZHRoOjEwMCU7YmFja2dyb3VuZDojMWUyOTNiO2Rpc3BsYXk6YmxvY2siPic7Cg==\"}, {\"old\": \"ICAgICc8c3R5bGUgaWQ9ImZsdWdmdW5rLWNzcyI+LmdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOm1pbm1heCgwLDFmcikgbWlubWF4KDAsMWZyKX0nCiAgICAnLmdyaWQ+LmNhcmR7bWluLXdpZHRoOjA7bWF4LXdpZHRoOjEwMCV9I2ZsdWdmdW5rQm94e21heC13aWR0aDoxMDAlO21pbi13aWR0aDowO292ZXJmbG93OmhpZGRlbjsnCiAgICAnYm94LXNpemluZzpib3JkZXItYm94O2JvcmRlcjoxcHggc29saWQgIzMzNDE1NX0nCiAgICAnI2ZmS29wZiwjZmZBdGlzLCNmZk1zZ3MsI2ZmTm90LCNmZldldHRlciwjZmZaZWl0e292ZXJmbG93LXdyYXA6YW55d2hlcmU7d29yZC1icmVhazpicmVhay13b3JkO21heC13aWR0aDoxMDAlfScKICAgICcjZmZXZXR0ZXIsI2ZmWmVpdCwjZmZLYXJ0ZXtkaXNwbGF5OmJsb2NrO3dpZHRoOjEwMCU7Ym94LXNpemluZzpib3JkZXItYm94fScKICAgICcjZmZXZXR0ZXJ7bWluLWhlaWdodDoyLjRlbX0jZmZaZWl0e21pbi1oZWlnaHQ6NmVtfSNmZkthcnRle21pbi1oZWlnaHQ6MTUwcHh9JwogICAgJyNmZk1zZ3N7bWF4LWhlaWdodDo4LjdlbTtvdmVyZmxvdzpoaWRkZW59PC9zdHlsZT4nCiAgICAnPGRpdiBjbGFzcz0iY2FyZCBmdWxsIiBpZD0iZmx1Z2Z1bmtCb3giIHN0eWxlPSJtYXJnaW4tdG9wOjEycHgiPicK\", \"new\": \"ICAgICc8c3R5bGUgaWQ9ImZsdWdmdW5rLWNzcyI+JwogICAgJyNmbHVnZnVua0JveHttYXgtd2lkdGg6MTAwJTt3aWR0aDoxMDAlO21pbi13aWR0aDowO2JveC1zaXppbmc6Ym9yZGVyLWJveDtvdmVyZmxvdzp2aXNpYmxlfScKICAgICcjZmx1Z2Z1bmtCb3ggKntib3gtc2l6aW5nOmJvcmRlci1ib3g7bWF4LXdpZHRoOjEwMCV9JwogICAgJyNmZktvcGYsI2ZmQXRpcywjZmZNc2dzLCNmZk5vdCwjZmZXZXR0ZXIsI2ZmWmVpdHtvdmVyZmxvdy13cmFwOmFueXdoZXJlO3dvcmQtYnJlYWs6YnJlYWstd29yZH0nCiAgICAnI2ZmS2FydGV7ZGlzcGxheTpibG9jazt3aWR0aDoxMDAlO21heC13aWR0aDoxMDAlO2FzcGVjdC1yYXRpbzoxLzE7bWluLWhlaWdodDowfScKICAgICcjZmZLYXJ0ZSBzdmd7d2lkdGg6MTAwJTtoZWlnaHQ6MTAwJTtkaXNwbGF5OmJsb2NrfScKICAgICcjZmZBdWRpb3tkaXNwbGF5OmJsb2NrO3dpZHRoOjEwMCU7bWF4LXdpZHRoOjEwMCV9JwogICAgJyNmZldldHRlcnttaW4taGVpZ2h0OjIuNGVtfSNmZlplaXR7bWluLWhlaWdodDo2ZW19JwogICAgJzwvc3R5bGU+JwogICAgJzxkaXYgY2xhc3M9ImNhcmQgZnVsbCIgaWQ9ImZsdWdmdW5rQm94IiBzdHlsZT0ibWFyZ2luLXRvcDoxMnB4O21heC13aWR0aDoxMDAlO21pbi13aWR0aDowO2JveC1zaXppbmc6Ym9yZGVyLWJveCI+Jwo=\"}, {\"old\": \"ICAgICc8YXVkaW8gaWQ9ImZmQXVkaW8iIHByZWxvYWQ9Im5vbmUiIGNvbnRyb2xzIHN0eWxlPSJ3aWR0aDoxMDAlO21hcmdpbi10b3A6NnB4Ij48L2F1ZGlvPjwvZGl2PicK\", \"new\": \"ICAgICc8YXVkaW8gaWQ9ImZmQXVkaW8iIHByZWxvYWQ9Im5vbmUiIGNvbnRyb2xzIHN0eWxlPSJkaXNwbGF5OmJsb2NrO3dpZHRoOjEwMCU7bWF4LXdpZHRoOjEwMCU7Ym94LXNpemluZzpib3JkZXItYm94O21hcmdpbi10b3A6NnB4Ij48L2F1ZGlvPjwvZGl2PicK\"}, {\"old\": \"ICAgICAgICAgICAgemVpbGVuLmFwcGVuZCgnICAgICAgZmlsZW5hbWVfdGVtcGxhdGUgPSAibGl2ZV8lWSVtJWRfJUgubXAzIjsnKQo=\", \"new\": \"ICAgICAgICAgICAgemVpbGVuLmFwcGVuZCgnICAgICAgZmlsZW5hbWVfdGVtcGxhdGUgPSAibGl2ZSI7JykK\"}, {\"old\": \"ICAgIHJldHVybiBSZXNwb25zZShkYXRlbiwgbWltZXR5cGU9ImF1ZGlvL3dhdiIsIGhlYWRlcnM9eyJDYWNoZS1Db250cm9sIjogIm5vLXN0b3JlIn0pCgoK\", \"new\": \"ICAgIHJldHVybiBSZXNwb25zZShkYXRlbiwgbWltZXR5cGU9ImF1ZGlvL3dhdiIsIGhlYWRlcnM9eyJDYWNoZS1Db250cm9sIjogIm5vLXN0b3JlIn0pCgoKZGVmIGxpdmVfbXAzKGJhc2UpOgogICAgIiIiTmV1ZXN0ZSBMaXZlLURhdGVpIG5hY2ggbXRpbWUuIHJ0bF9haXJiYW5kIGhhZW5ndCBzZWxic3QgX0pKSkpNTVRUX1NTIGluIFVUQyBhbi4iIiIKICAgIG9yZG5lciA9IG9zLnBhdGguam9pbihhdWRpb19yb290KGJhc2UpLCAibGl2ZSIpCiAgICBpZiBub3Qgb3MucGF0aC5pc2RpcihvcmRuZXIpOgogICAgICAgIHJldHVybiBOb25lCiAgICBrYW5kaWRhdGVuID0gW10KICAgIGZvciBuYW1lIGluIG9zLmxpc3RkaXIob3JkbmVyKToKICAgICAgICBpZiBuYW1lLnN0YXJ0c3dpdGgoImxpdmUiKSBhbmQgbmFtZS5lbmRzd2l0aCgiLm1wMyIpOgogICAgICAgICAgICBwZmFkID0gb3MucGF0aC5qb2luKG9yZG5lciwgbmFtZSkKICAgICAgICAgICAgaWYgb3MucGF0aC5pc2ZpbGUocGZhZCk6CiAgICAgICAgICAgICAgICBrYW5kaWRhdGVuLmFwcGVuZChwZmFkKQogICAgaWYgbm90IGthbmRpZGF0ZW46CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIHJldHVybiBtYXgoa2FuZGlkYXRlbiwga2V5PW9zLnBhdGguZ2V0bXRpbWUpCgoKZGVmIF9wb3J0X2F1Zihob3N0LCBwb3J0KToKICAgIGltcG9ydCBzb2NrZXQKICAgIHNvY2sgPSBzb2NrZXQuc29ja2V0KCkKICAgIHNvY2suc2V0dGltZW91dCgwLjQpCiAgICB0cnk6CiAgICAgICAgc29jay5jb25uZWN0KChob3N0LCBpbnQocG9ydCkpKQogICAgICAgIHJldHVybiBUcnVlCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGZpbmFsbHk6CiAgICAgICAgc29jay5jbG9zZSgpCgoKX0lDRV9SRUxBWSA9ICgKICAgICJpbXBvcnQgb3Msc3lzLGJhc2U2NCxzb2NrZXRcbiIKICAgICJwdz1vcGVuKG9zLmVudmlyb25bJ0ZMVUdGVU5LX1BXX0ZJTEUnXSxlbmNvZGluZz0ndXRmLTgnKS5yZWFkKCkuc3RyaXAoKVxuIgogICAgInM9c29ja2V0LmNyZWF0ZV9jb25uZWN0aW9uKCgnMTI3LjAuMC4xJyw4MDAwKSw1KVxuIgogICAgInRvaz1iYXNlNjQuYjY0ZW5jb2RlKCgnc291cmNlOicrcHcpLmVuY29kZSgpKS5kZWNvZGUoKVxuIgogICAgInMuc2VuZGFsbCgoJ1NPVVJDRSAvZmx1Z2Z1bmsgSUNFLzEuMFxcclxcbkNvbnRlbnQtVHlwZTogYXVkaW8vbXBlZ1xcclxcbiIKICAgICJBdXRob3JpemF0aW9uOiBCYXNpYyAlc1xcclxcbkljZS1QdWJsaWM6IDBcXHJcXG5cXHJcXG4nJXRvaykuZW5jb2RlKCkpXG4iCiAgICAiYnVmPWInJ1xuIgogICAgIndoaWxlIFRydWU6XG4iCiAgICAiIGI9c3lzLnN0ZGluLmJ1ZmZlci5yZWFkKDQwOTYpXG4iCiAgICAiIGlmIG5vdCBiOiBicmVha1xuIgogICAgIiBzLnNlbmRhbGwoYilcbiIKKQoKCg==\"}, {\"old\": \"ICAgICIiIlN0YXJ0ZXQgSWNlY2FzdCB1bmQgZGVuIFp1YnJpbmdlciwgd2VubiBkYXMgUGFrZXQgZGEgaXN0LiBEYXMgUGFzc3dvcnQgYmxlaWJ0IGluIGRlciBEYXRlaS4iIiIKICAgIHNrcmlwdCA9IG9zLnBhdGguam9pbihiYXNlLCAiYmluIiwgImZsdWdmdW5rLWljZWNhc3Quc2giKQo=\", \"new\": \"ICAgICIiIlp1YnJpbmdlciBlcnN0IHdlbm4gSWNlY2FzdCBhbnR3b3J0ZXQuIFBhc3N3b3J0IG51ciBhdXMgZGVyIERhdGVpLCBuaWUgaW4gYXJndi4iIiIKICAgIHB3ID0gb3MucGF0aC5qb2luKGJhc2UsICJpY2VjYXN0LWZsdWdmdW5rLnB3IikKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZShwdykgb3Igbm90IF9wb3J0X2F1ZigiMTI3LjAuMC4xIiwgODAwMCk6CiAgICAgICAgcmV0dXJuCiAgICBkYXRlaSA9IGxpdmVfbXAzKGJhc2UpCiAgICBpZiBub3QgZGF0ZWkgb3Igbm90IHNodXRpbC53aGljaCgiZmZtcGVnIikgb3Igbm90IHNodXRpbC53aGljaCgidGFpbCIpOgogICAgICAgIHJldHVybgo=\"}, {\"old\": \"ICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZShza3JpcHQpOgogICAgICAgIHJldHVybgogICAgaWYgb3MucGF0aC5pc2ZpbGUocGlkX3BmYWQpOgo=\", \"new\": \"ICAgIG1lcmtfcGZhZCA9IG9zLnBhdGguam9pbihiYXNlLCAiZmx1Z2Z1bmstaWNlY2FzdC5kYXRlaSIpCiAgICB0cnk6CiAgICAgICAgcGlkID0gaW50KG9wZW4ocGlkX3BmYWQsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKS5zdHJpcCgpKQogICAgICAgIG1lcmsgPSBvcGVuKG1lcmtfcGZhZCwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpLnN0cmlwKCkKICAgIGV4Y2VwdCAoT1NFcnJvciwgVmFsdWVFcnJvcik6CiAgICAgICAgcGlkLCBtZXJrID0gMCwgIiIKICAgIGlmIHBpZCBhbmQgbWVyayA9PSBkYXRlaToK\"}, {\"old\": \"ICAgICAgICAgICAgcGlkID0gaW50KG9wZW4ocGlkX3BmYWQsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKS5zdHJpcCgpKQo=\", \"new\": \"\"}, {\"old\": \"ICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgZXhjZXB0IChPU0Vycm9yLCBWYWx1ZUVycm9yKToK\", \"new\": \"ICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6Cg==\"}, {\"old\": \"ICAgIHByb2MgPSBzdWJwcm9jZXNzLlBvcGVuKFtza3JpcHQsIGJhc2VdLCBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGFydF9uZXdfc2Vzc2lvbj1UcnVlKQo=\", \"new\": \"ICAgIGlmIHBpZDoKICAgICAgICB0cnk6CiAgICAgICAgICAgIG9zLmtpbGwocGlkLCAxNSkKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcGFzcwogICAgdGFpbCA9IHN1YnByb2Nlc3MuUG9wZW4oWyJ0YWlsIiwgIi1GIiwgIi1jIiwgIiswIiwgZGF0ZWldLCBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGFydF9uZXdfc2Vzc2lvbj1UcnVlKQogICAgZmYgPSBzdWJwcm9jZXNzLlBvcGVuKAogICAgICAgIFsiZmZtcGVnIiwgIi1sb2dsZXZlbCIsICJlcnJvciIsICItZmZsYWdzIiwgIm5vYnVmZmVyIiwgIi1mIiwgIm1wMyIsICItaSIsICJwaXBlOjAiLAogICAgICAgICAiLWMiLCAiY29weSIsICItZiIsICJtcDMiLCAicGlwZToxIl0sCiAgICAgICAgc3RkaW49dGFpbC5zdGRvdXQsIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsCiAgICApCiAgICBpZiB0YWlsLnN0ZG91dDoKICAgICAgICB0YWlsLnN0ZG91dC5jbG9zZSgpCiAgICB1bWdlYnVuZyA9IG9zLmVudmlyb24uY29weSgpCiAgICB1bWdlYnVuZ1siRkxVR0ZVTktfUFdfRklMRSJdID0gcHcKICAgIHJlbGF5ID0gc3VicHJvY2Vzcy5Qb3BlbigKICAgICAgICBbX19pbXBvcnRfXygic3lzIikuZXhlY3V0YWJsZSwgIi1jIiwgX0lDRV9SRUxBWV0sCiAgICAgICAgc3RkaW49ZmYuc3Rkb3V0LCBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLAogICAgICAgIGVudj11bWdlYnVuZywgc3RhcnRfbmV3X3Nlc3Npb249VHJ1ZSwKICAgICkKICAgIGlmIGZmLnN0ZG91dDoKICAgICAgICBmZi5zdGRvdXQuY2xvc2UoKQo=\"}, {\"old\": \"ICAgICAgICAgICAgaGFuZGxlLndyaXRlKHN0cihwcm9jLnBpZCkpCg==\", \"new\": \"ICAgICAgICAgICAgaGFuZGxlLndyaXRlKHN0cihyZWxheS5waWQpKQogICAgICAgIHdpdGggb3BlbihtZXJrX3BmYWQsICJ3IiwgZW5jb2Rpbmc9InV0Zi04IikgYXMgaGFuZGxlOgogICAgICAgICAgICBoYW5kbGUud3JpdGUoZGF0ZWkpCg==\"}, {\"old\": \"ICAgICAgICBpZiBlbXBmYW5nX2hhbHRlbihsZWJ0LCBUcnVlLCBnZXRhdHRyKHNlbGYsICJfc3R1bmRlIiwgTm9uZSkgPT0gc3R1bmRlLCBnZXRhdHRyKHNlbGYsICJfc2VpdCIsIDApLCBqZXR6dCkgYW5kIGR3ZWxsIGlzIE5vbmU6Cg==\", \"new\": \"ICAgICAgICBpZiBlbXBmYW5nX2hhbHRlbihsZWJ0LCBUcnVlLCBUcnVlLCBnZXRhdHRyKHNlbGYsICJfc2VpdCIsIDApLCBqZXR6dCkgYW5kIGR3ZWxsIGlzIE5vbmU6Cg==\"}, {\"old\": \"ICAgIGFzc2VydCAiZmZLYXJ0ZSIgaW4gc2VpdGUgYW5kICJmZlplaXQiIGluIHNlaXRlIGFuZCAiZmZXZXR0ZXIiIGluIHNlaXRlCg==\", \"new\": \"ICAgIGFzc2VydCAiZmZLYXJ0ZSIgaW4gc2VpdGUgYW5kICJmZlplaXQiIGluIHNlaXRlIGFuZCAiZmZXZXR0ZXIiIGluIHNlaXRlCiAgICBhc3NlcnQgIi5ncmlkeyIgbm90IGluIEtBUlRFIGFuZCAiYXNwZWN0LXJhdGlvOjEvMSIgaW4gS0FSVEUgYW5kICJvdmVyZmxvdy13cmFwOmFueXdoZXJlIiBpbiBLQVJURQo=\"}, {\"old\": \"ICAgIGFzc2VydCBlbXBmYW5nX2hhbHRlbihUcnVlLCBUcnVlLCBUcnVlLCAxMDAwLCAxMjAwKSBhbmQgbm90IGVtcGZhbmdfaGFsdGVuKFRydWUsIFRydWUsIEZhbHNlLCAxMDAwLCAxMjAwKQo=\", \"new\": \"ICAgIGFzc2VydCBlbXBmYW5nX2hhbHRlbihUcnVlLCBUcnVlLCBUcnVlLCAxMDAwLCAxMjAwKSBhbmQgbm90IGVtcGZhbmdfaGFsdGVuKFRydWUsIFRydWUsIEZhbHNlLCAxMDAwLCAxMjAwKQogICAgYXNzZXJ0ICJpY2VjYXN0Oi8vc291cmNlOiIgbm90IGluIF9JQ0VfUkVMQVkKICAgIGFzc2VydCAnZmlsZW5hbWVfdGVtcGxhdGUgPSAibGl2ZSInIGluIG9wZW4oX19maWxlX18sIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKQo=\"}], \"log\": [{\"old\": \"ICAgICc8dGV4dGFyZWEgaWQ9ImxiVGV4dCIgcmVhZG9ubHkgc3R5bGU9IndpZHRoOjEwMCU7bWluLWhlaWdodDoxMmVtO2JveC1zaXppbmc6Ym9yZGVyLWJveDttYXJnaW4tdG9wOjZweCI+PC90ZXh0YXJlYT4nCg==\", \"new\": \"ICAgICc8dGV4dGFyZWEgaWQ9ImxiVGV4dCIgcmVhZG9ubHkgc3R5bGU9IndpZHRoOjEwMCU7bWluLWhlaWdodDoxMmVtO2JveC1zaXppbmc6Ym9yZGVyLWJveDttYXJnaW4tdG9wOjZweDtiYWNrZ3JvdW5kOiMwZjE3MmE7Y29sb3I6I2UyZThmMDstd2Via2l0LXRleHQtZmlsbC1jb2xvcjojZTJlOGYwO2JvcmRlcjoxcHggc29saWQgIzMzNDE1NTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCI+PC90ZXh0YXJlYT4nCg==\"}, {\"old\": \"ICAgICAgICBhc3NlcnQgImxvZ2JlcmljaHRCb3giIGluIHNlaXRlIGFuZCAiS29waWVyZW4iIGluIHNlaXRlCg==\", \"new\": \"ICAgICAgICBhc3NlcnQgImxvZ2JlcmljaHRCb3giIGluIHNlaXRlIGFuZCAiS29waWVyZW4iIGluIHNlaXRlCiAgICAgICAgYXNzZXJ0ICJiYWNrZ3JvdW5kOiMwZjE3MmEiIGluIEtBUlRFIGFuZCAiYm9yZGVyLXJhZGl1czo4cHgiIGluIEtBUlRFCg==\"}]}"

def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--ordner", default="/home/fmg/prepper-dashboard")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--kein-neustart", action="store_true")
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--fullcheck-hash", default=FC_FEST)
    args = p.parse_args(argv)
    if args.selftest:
        print(selftest())
        return 0
    return apply_dir(args.ordner, args.dry_run, args.kein_neustart, fullcheck_hash=args.fullcheck_hash or None)

if __name__ == "__main__":
    raise SystemExit(main())
