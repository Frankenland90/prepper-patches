# pinnebergRolle Stufe 1 — Apply nach dem Rollback 23:09

Nicht veröffentlicht. Nicht gemergt. Kein Pi-Zugriff. Keine weitere Stufe. Stufe 1 reserviert Stick 3 nur. Sie empfängt DDH47 nicht.

Der Lauf des Skripts `480d9b0e705438c8a320aae7e5bbd605fe651197465228b5e4c0c793d2abe859` hat die Dateien gesetzt, nur das Dashboard neu gestartet und dann zurückgerollt. Der Pi bleibt auf commit64, `lage_pages.py` `6b10e3bae7118d95`. Nichts wurde gesendet, `prepper-sdr` lief weiter.

## Ursache

Die Bereitschaftsprüfung suchte den Text `"alarm": false` mit Leerzeichen. Die Dashboard-venv liefert über Flask `jsonify` kompaktes JSON. Nachweis mit dieser venv:

`{"alarm":false,"rf_hz":147300,"if_hz":120147300,...}`

`"alarm": false` kommt darin nicht vor. `147300` und die Kachel waren schon da, deshalb blieb im Log nur `WAIT fehlt: "alarm": false`. Nach 180 s folgte der Rollback. Dieselbe Folge stand danach ein zweites Mal im Log, weil `tee` sie schon zeigte und `cat` die Datei noch einmal ausgab. Gewartet wurde einmal 180 s, nicht zweimal. Der zweite Ausdruck ist entfernt. Die Frist bleibt 180 s.

Die Laufzeitdateien sind unverändert. Der Fehler saß nur in der Prüfung des Apply.

## Überholt

`480d9b0e705438c8a320aae7e5bbd605fe651197465228b5e4c0c793d2abe859`, 3132852 Bytes. Nicht noch einmal verwenden.

## Neues Artefakt

- Datei: `/opt/cursor/artifacts/apply-pinneberg-rolle.sh`
- sha256: `98497d1c14f6487d79a5d0d4c791dc93ac240cd48c8804eceaee856615440f0b`
- Größe: 3133740 Bytes
- bash -n: ok
- Nutzlast unverändert: dashboard.py `6d9fe2860fc63671`, prepper_docs.py `c26252d54344ca25`, prepper_sdr.py `533b6f9db8da0bcb`, pinneberg_rolle.py `981cacdbf5a81348`

## Was die Prüfung jetzt verlangt

Das JSON wird gelesen, nicht als Text mit fester Leerstelle gesucht. Kompakt und eingerückt gelten gleich.

- `alarm` ist der Wahrheitswert false. Der Text `"false"`, die Zahl 0, ein fehlendes Feld und true fallen sofort durch und lösen den Rollback aus.
- `empfang` und `bias_tee` sind false.
- `rf_hz` ist 147300 und `if_hz` ist 120147300.
- Stufe 1. `bereit` nur mit dem Satz „Empfang nicht gestartet“. `stop` nur mit einem Text, der mit STOP beginnt. `aus` ist ein Fehler, weil die Datei installiert ist.
- Die Funkseite enthält `pinnebergBox`, ist nicht der Startbildschirm und nicht HTTP 500 oder ein Traceback.

Eine unklare USB-Rolle bleibt `stop` und wird nicht als reserviert ausgegeben.

## Tests

System-Python ohne Flask, echte venv mit Flask und eigenem `sys.prefix`. Sandbox nur Port 5093.

Die Prüfung selbst: kompaktes Flask-JSON, eingerücktes JSON, STOP-Text, alarm true, alarm als Text, alarm 0, alarm fehlt, falsche Frequenz, bereit ohne den Satz, Rolle aus, Empfang true, HTTP 500, Traceback, Startbildschirm.

Apply: Trockenlauf, normaler Lauf auf trim `6b10e3bae7118d95` mit kompaktem JSON, zweiter Lauf ohne weiteren Neustart, fremde `lage_pages.py`, Dashboard noch auf commit63, Sperre 21:51, Rollback, fehlende venv. `prepper-sdr` wird nicht neu gestartet. Keine echte Wiedergabe, kein Spektrum, kein Alarm.

Aufruf: `bash apply-pinneberg-rolle.sh pinnebergRolle`.
