# commit64 stimmeDe — korrigiertes Apply

Nicht veröffentlicht. Nicht gemergt. Kein Pi-Zugriff. Keine Paketinstallation.

Der Lauf um 22:35 auf dem Pi ist vor jeder Änderung stehen geblieben. Der Pi hat weiter commit63. Ursache war nur der Testpfad im Apply: `/usr/bin/python3` hat `import dashboard` ausgeführt und Flask nicht gefunden. Die eingebetteten Laufzeitdateien waren in Ordnung.

## Überholt, nicht noch einmal hochladen

- apply-commit64.sh sha256 `372d281d60a1dec55e80caf966cbb3af7069e13efae4c7e9b1073514f2e94ccf`, 2078850 Bytes
- Kopie nur zur Abgrenzung: `/opt/cursor/artifacts/apply-commit64-OBSOLET-372d281d.sh`

## Neues Artefakt

- Datei: `/opt/cursor/artifacts/apply-commit64.sh`
- sha256: `4e53e5b3031e1ee6448381b5f256afd355c597b844ccdd9cdfc26b1a3e672916`
- Größe: 2079378 Bytes
- bash -n: ok
- Die Nutzlast ist bytegleich mit dem überholten Skript. dashboard.py bleibt `5858908eaf6498bbcb737ad4791adb0bba0e4c7f4be0657f0bb31cdbef157a1d`, prepper_docs.py bleibt `36804387c50cba2b2021c71eaef1babc7aee85ebb0042e0849fa2267013d9937`. Es war keine Änderung am Programm nötig.

## Testpfad

- System-Python `/usr/bin/python3`: nur Syntax (`py_compile`), Guard und der abhängigkeitsfreie `ups_manager`-Selbsttest. Er importiert `dashboard` nicht.
- Dashboard-venv `$DASH_DIR/venv/bin/python`: muss ausführbar sein, Flask laden und ein eigenes venv sein (`sys.prefix` verschieden von `sys.base_prefix`). Dort läuft `import dashboard`, also der Audiokern-Selbsttest mit Ersatzprozessen.
- Fehlt die venv, ist sie nicht ausführbar oder lädt sie Flask nicht, STOP vor jeder Änderung. Kein Umbiegen auf das System-Python. Nichts wird nachinstalliert.

## Nachweis der getrennten Umgebungen

- `/usr/bin/python3` mit `PYTHONNOUSERSITE=1`: `import flask` endet mit `ModuleNotFoundError`.
- Eigene venv `/tmp/venv-dash`: `sys.prefix` ist nicht `sys.base_prefix`, Flask kommt aus `venv/lib/python3.12/site-packages`. Die Simulationsordner bekommen diese venv als `venv/bin/python` plus `pyvenv.cfg`, nicht einen zweiten Namen desselben Interpreters.
- Damit liefen Trockenlauf, normaler Lauf auf trim `6b10e3bae7118d95`, zweiter Lauf ohne weiteren Neustart, ungekürzte Basis `d268d324f4fd55a5`, fremde `lage_pages.py`, Mischstand, Sperre 21:51 vor dem Ersetzen, Rollback auf commit63, fehlende venv und venv ohne Flask. Guard im Lauf 10/10. Die Meldung lautet: Import nur in der Dashboard-venv, System-Python importiert dashboard nicht.
- Keine echte Wiedergabe. `espeak-ng`, `aplay` und `mbrola` liefen nicht; der Audiotest bleibt der Ersatzprozess-Selbsttest in der venv.

Aufruf unverändert: `bash apply-commit64.sh commit64` und für die Vorprüfung `bash apply-commit64.sh commit64 dry-run`.
