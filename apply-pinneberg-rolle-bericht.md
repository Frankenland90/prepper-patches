# pinnebergRolle Stufe 1 — korrigiertes Apply

Nicht veröffentlicht. Nicht gemergt. Kein Pi-Zugriff. Keine weitere Stufe. Keine Paketinstallation.

Derselbe Testpfadfehler wie bei commit64: das System-Python sollte `dashboard` nicht importieren. Die Laufzeitdateien dieser Stufe sind unverändert.

## Überholt, nicht noch einmal hochladen

- apply-pinneberg-rolle.sh sha256 `6c4c64e24e5143fa1af1abb672d14b49e5327602e9ee85169d08903661b78ff1`, 3132201 Bytes
- Kopie nur zur Abgrenzung: `/opt/cursor/artifacts/apply-pinneberg-rolle-OBSOLET-6c4c64e2.sh`

## Neues Artefakt

- Datei: `/opt/cursor/artifacts/apply-pinneberg-rolle.sh`
- sha256: `480d9b0e705438c8a320aae7e5bbd605fe651197465228b5e4c0c793d2abe859`
- Größe: 3132852 Bytes
- bash -n: ok
- Nutzlast unverändert: dashboard.py `6d9fe2860fc636713461fd22b78de03941e23d167b7475e608f773fd0e5650b9`, prepper_docs.py `c26252d54344ca25875a5cf3e79b31df879af18ff9c504ec008a8ffff0080910`, prepper_sdr.py `533b6f9db8da0bcb73ca0e956bfc7a2edfade287375aa4eaf21f10a4ab37fb32`, pinneberg_rolle.py `981cacdbf5a81348f9b32f67ac1c9ca27382af916d340c3b7773a84e87df06f5`.

## Testpfad

- System-Python: `py_compile`, Guard, `pinneberg_rolle.selftest` und `prepper_sdr.selftest_sdrstick3e`. Beides ohne Flask.
- Dashboard-venv: muss Flask laden und ein eigenes venv sein. Dort `import dashboard` für Anzeige und Audiokern.
- Fehlende oder defekte venv: STOP vor jeder Änderung, kein Rückfall auf das System-Python.

## Nachweis

Dieselbe Trennung wie bei commit64: System-Python ohne Flask, echte venv mit Flask aus ihrem eigenen site-packages. Trockenlauf, normaler Lauf auf trim `6b10e3bae7118d95`, zweiter Lauf ohne weiteren Neustart, fremde `lage_pages.py`, Dashboard noch auf commit63, Sperre 21:51, Rollback mit Entfernen der neuen Dateien, fehlende venv. `prepper-sdr` wird nicht neu gestartet. Keine echte Wiedergabe und kein echtes Spektrum.

Dieses Skript setzt das korrigierte commit64 voraus. Der öffentliche Stand `f1351f3` enthält die überholten Skripte; hier wird nichts hochgeladen.
