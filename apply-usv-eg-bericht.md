# usvEgMessung

Gebaut und lokal geprüft. Nicht veröffentlicht, nicht installiert, nicht live verbunden. Pinneberg-Empfang bleibt pausiert. commit65 bleibt frei.

## Stand

| | |
|---|---|
| gebaut und getestet | dieser Apply und der Review-Branch |
| veröffentlicht | nein, prepper-patches unangetastet |
| auf dem Prepper installiert | nein |
| live mit der USV EG verbunden | nein |

Die Kachel bleibt auf „nicht verbunden“, bis der Tunnel unten separat steht und `usv_eg.json` eingeschaltet ist. Ein Dashboard-Patch allein erreicht das NUT nicht: auf dem Pi-hole hört es nur auf `127.0.0.1:3493`.

## Apply

`apply-usv-eg.sh`
sha256 `5424691f129d866372422b8faa49a16a9b1e7813a61902b4a58f169627a99393`
646700 Bytes

Aufruf später, nicht jetzt: `bash apply-usv-eg.sh usvEgMessung` und davor `dry-run`. Nur auf Port 5000. Die Simulation lief auf 5093.

Basis, nur die installierte Stufe 1. Ein anderer Stand stoppt.

| Datei | vorher | nachher |
|---|---|---|
| ups_manager.py | `b2e491e36a9a1861de4c609f80a613f9b824e4f6f52319c50e5c5a87252ddcf8` | `4a28a09242bc9b40eb655a3a61e446ed75407736a24670c2647f506cea9b80cb` (50412 B) |
| lage_pages.py | Kürzung `6b10e3bae7118d9519760b492220e88a5caf2e9dc99e9ed8db096eb911d0e778` | Kürzung `8ac12d053ccc3ed9d6ed7dcff7772a6ef62821736d581513560461b00d3dbb38` (213623 B) |
| prepper_docs.py | `c26252d54344ca25875a5cf3e79b31df879af18ff9c504ec008a8ffff0080910` | `8fcc17daf1b3d4d2549aad3e4523b16bd60f4a679ad5c6db5f3c40d6199ba105` (201895 B) |
| dashboard.py, prepper_sdr.py, pinneberg_rolle.py, pinneberg_rolle.json | bleiben `6d9fe2860fc63671`, `533b6f9db8da0bcb`, `981cacdbf5a81348`, `e091123291a18874` | unverändert |

Die ungekürzte Lage `d268d324f4fd55a5` stoppt. Die Gaszeilen Profil und Szenariohinweis werden nicht zurückgeschrieben. Gemischt und unbekannt stoppen. Drei Sicherungen, atomar, Rollback. System-Python ohne Flask prüft nur `ups_manager`. Das Dashboard wird nur in der echten venv importiert. Ein kaputtes venv stoppt vor dem Ersetzen. Neustart nur `prepper-dashboard`, und nur außerhalb HH:50–HH:04 einschließlich 5 Minuten Vorlauf. `prepper-sdr` bleibt. `usv_eg.json` legt der Apply nicht an.

Im Review-Branch hat `lage_pages.py` die Gaszeilen noch (sha256 `f85f24fd0ef8189cfd818eaf2dfaa0173f46bd6efbde516ce28a569eaa64ffa0`, 213849 B). Das ist nicht die Datei für den Prepper. Installiert wird nur die Kürzung aus dem Apply.

## Was die Kachel tut

Nur Anzeige. Der EG-Faden liest höchstens `LIST UPS` und `LIST VAR usv_eg` auf `127.0.0.1` und einem anderen Port als 3493. Vorgesehen ist 3494, der lokale Ausgang eines Tunnels. Eine andere Adresse, der Text `"true"`, ein Kennwortfeld oder Port 3493 werden nicht verbunden. WAIT, fehlende und ungültige Felder sind kein OK. Nach 10 Sekunden bleiben die letzten Zahlen als veraltet stehen. Ladung 100 % wird nie zur Akku-Gesundheit. Die Laufzeit bleibt eine Schätzung. Akkubetrieb der EG setzt weder Alarm noch Abschaltung der USV SPITZBODEN. Deren Schwelle bleibt 20 % oder 5 Minuten, `USVA_LOW_S` bleibt 300.

## Prüfung

`ups_manager.selftest` gegen eine Loopback-Attrappe, keine echte USV: erster Stand WAIT ist nicht OK, danach Ladung 100 bei SoH leer, veraltete letzte Zahl, ungültige Ladung verwirft den neuen Stand, Host `192.168.178.3` öffnet keine Verbindung, die Befehle bleiben bei LIST, ein OB der EG lässt Spitzboden auf NETZ.

Apply-Simulation, 0 Fehler: dry-run, unbekannter Stand, Mischstand, ungekürzte Lage, kaputtes venv, Sperre 23:50, Normallauf, zweiter Lauf ohne weiteren Neustart, Rollback wenn die Antwort eine SoH-Prozentzahl liefert. Guard 11/11. 14 Seiten und 16 APIs in der Attrappe weiter 200. Die Bereitschaft liest JSON (`ok` und `eg.ok` müssen Wahrheitswerte sein, `eg.soh.pct` muss null sein) und lehnt den Startbildschirm ab. Das war der Sandkasten, nicht der Pi und nicht Port 5000.

## Blocker für Live-Werte

Die Pi-hole-Adresse ist mit dem aktuellen `ip`-Befehl nicht belegt. `192.168.178.3` wird nicht angenommen. Zusätzlich gibt es keinen LAN-Listener. Beides muss Frank später selbst prüfen. Dieser Lauf öffnet nichts.

`upsd` kann mit `LISTEN` nur die eigene Adresse wählen, nicht die erlaubte Gegenstelle. Ein `LISTEN` auf eine LAN-Adresse ohne Firewall würde die Messwerte jedem zeigen, der den Port erreicht. NUT 2.8 beantwortet `LIST` ohne Benutzer. Das ist keine Steuerung, aber es ist auch keine Quellenbeschränkung. Eine Firewalländerung ist nicht freigegeben. Deshalb ist der Tunnel der Weg, und ein LAN-Listener wird hier nicht vorbereitet.

## Später, erst nach dem Apply, von Frank

Pi-hole, nur lesen, nichts ändern:

```sh
ip -4 -br addr
ss -H -lnt 'sport = :3493'
systemctl is-active nut-server
systemctl show nut-monitor.service -p LoadState -p ActiveState
upsc usv_eg@127.0.0.1
```

Erwartet: nur `127.0.0.1:3493`, nut-monitor weiter `masked` und `inactive`, `upsc` mit aktuellen Werten. WAIT ist noch kein gültiger Stand. `upsd.conf`, `upsmon.conf` und `upsd.users` bleiben. Kein Schlüssel, kein Pi-hole-Neustart, keine Firewall.

Prepper, wenn Port 3494 frei ist und die IP aus `ip` feststeht. Bestehender SSH-Login, keine neuen Schlüssel:

```sh
ss -H -lnt 'sport = :3494'
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:3494:127.0.0.1:3493 BENUTZER@BESTAETIGTE_IP
```

Zweite Sitzung auf dem Prepper: `upsc usv_eg@127.0.0.1:3494`. Nur wenn das aktuelle Werte und nicht WAIT zeigt, diese Datei anlegen:

`/home/fmg/prepper-dashboard/usv_eg.json`

```json
{"enabled":true,"host":"127.0.0.1","port":3494,"ups":"usv_eg"}
```

`enabled` ist der Wahrheitswert `true`. Kein Benutzer, kein Kennwort. Kein Neustart nötig. Der Faden liest die Datei alle 2 Sekunden.

Rückweg Tunnel: `ssh -N` beenden. Die Kachel wird veraltet und zeigt danach keine Live-Werte. `upsd.conf` nicht anfassen.

Rückweg Apply, außerhalb HH:50–HH:04, nur die drei Sicherungen dieses Laufs:

```sh
cd /home/fmg/prepper-dashboard
cp -a ups_manager.py.bak-usveg-ZEITSTEMPEL ups_manager.py
cp -a lage_pages.py.bak-usveg-ZEITSTEMPEL lage_pages.py
cp -a prepper_docs.py.bak-usveg-ZEITSTEMPEL prepper_docs.py
sudo systemctl restart prepper-dashboard
```

`prepper-sdr` nicht neu starten. Eine selbst angelegte `usv_eg.json` löschen oder `enabled` auf `false` setzen.
