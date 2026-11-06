# usvKacheln

Gebaut und lokal geprüft. Nicht veröffentlicht, nicht installiert. Die bestehende Live-Verbindung und `usv_eg.json` werden von diesem Apply nicht angefasst. Pinneberg bleibt Stufe 1.

## Apply

`apply-usv-kacheln.sh`
sha256 `ceb37913762c4baef6b5e2103d29ba9f84d7337af89048e05316e9f96e6339fc`
655086 Bytes

Aufruf später: `bash apply-usv-kacheln.sh usvKacheln` und davor `dry-run`. Nur Port 5000. Die Simulation lief auf 5093.

| Datei | vorher (installierter USV-EG-Stand) | nachher |
|---|---|---|
| ups_manager.py | `4a28a09242bc9b40` | `d670aca41895559c` voll `d670aca41895559c2aa5c46dc6432cdba78b60b2c69720e4482e2b16b45f55dd` (53069 B) |
| lage_pages.py | Kürzung `8ac12d053ccc3ed9` | Kürzung `27c72615609e2ef1` voll `27c72615609e2ef11ade38d9dd5a681505c992e4dba4904badc4fb793f81b748` (215661 B) |
| prepper_docs.py | `8fcc17daf1b3d4d2` | `38aff52eae6bfbdf` voll `38aff52eae6bfbdf5aa572905c8ee18e492cf5a3c0a1726504422e24f3d751d4` (202133 B) |
| dashboard.py, prepper_sdr.py, pinneberg_rolle.py | `6d9fe2860fc63671`, `533b6f9db8da0bcb`, `981cacdbf5a81348` | unverändert |

`usv_eg.json` wird nicht angelegt, nicht ersetzt und nicht ausgeschaltet. Ein vorhandener Inhalt bleibt bytegleich. Der Tunnel wird nicht geöffnet und nicht umgestellt.

Die Review-Datei `lage_pages.py` im Branch behält die Gaszeilen (sha256 `1576a4065d9be0e209246fdd89b54003afa8858383e54639a95f01e2d041ba5e`, 215887 B). Der Apply nimmt sie nicht. Auf dem Prepper gilt nur die Kürzung.

Neustart nur `prepper-dashboard`, weil die Seite und der Leser beim Start geladen werden. Danach liest derselbe Faden wieder `127.0.0.1:3494` und die vorhandene Datei. Für ein paar Sekunden fehlen die Werte, danach sind sie wieder live, wenn der Tunnel steht. Sperre HH:50–HH:04 einschließlich 5 Minuten Vorlauf. `prepper-sdr` bleibt.

## Kacheln

Beide Kacheln haben dieselben Zeilen: Betrieb, Last, Balken, Autonomie, SoH, Selbsttest, Alarm, Abschaltung, Erklärung. Die Zahlen kommen jede für sich.

EG-Akku: Einbau `2026-05`, Alter mit derselben Monatsrechnung wie Spitzboden, Wechsel weiter „nicht festgelegt“. Ladung 100 % bleibt Ladung. SoH bleibt `UNBEKANNT` ohne Tag 7/14. Spitzboden-Lernstand und der Satz „Abschaltung bei 20 % oder 5 min · upsmon aktiv“ bleiben an der Spitzboden-Kachel.

## Was die EG nicht hat

- SoH-Prozent und Lernzähler
- geglättete Restlaufzeit (Median 5 min). Angezeigt wird die Schätzung der USV, als Schätzung bezeichnet
- Anteil an 400 W. Der Balken nutzt `ups.load` und sagt „laut USV“
- gelernter Selbsttest und Stresstest. Steht „kein Test“. Eine Geräteangabe erscheint nur, wenn NUT `ups.test.result` liefert
- Alarm, Mesh und die rote Netzausfall-Zeile. Akkubetrieb wird nur als AKKUBETRIEB gezeigt, ohne Startzeitpunkt
- Abschaltung. Die Zeile sagt „keine · nur Anzeige“. `steuerung` bleibt false
- Wechseldatum
- Batteriespannung, solange NUT sie nicht sendet

Eingang, Ausgang, Scheinleistung und Frequenz bleiben in der API, wenn NUT sie liefert. Sie werden nicht als SoH oder als Nennlast ausgegeben.

## Prüfung

`ups_manager.selftest` an der Loopback-Attrappe: Einbau 2026-05 auch ohne Verbindung, WAIT ohne Ladung, danach eigene Last 123 W gegen Spitzboden 34 W, Ladung 100 bei SoH leer, veraltet mit demselben Einbau, Config-Text nach dem Lesen unverändert, EG-Akkubetrieb lässt Spitzboden auf NETZ und schreibt seinen Zustand nicht.

Apply-Simulation: dry-run, unbekannt, gemischt, Review-Lage, kaputtes venv, Sperre 23:50, Normallauf, zweiter Lauf ohne weiteren Neustart, Rollback bei einer SoH-Prozentzahl. Guard 13/13. Eine vorhandene `usv_eg.json` blieb gleich, auch im Rollback. System-Python ohne Flask, Dashboard-Import nur in der venv. Keine echte USV, kein Port 5000, kein Pi.

Rückweg außerhalb der Sperre, nur die Sicherungen `*.bak-usvkachel-ZEITSTEMPEL` von `ups_manager.py`, `lage_pages.py` und `prepper_docs.py`, danach nur `prepper-dashboard` neu starten. `usv_eg.json` nicht anfassen.
