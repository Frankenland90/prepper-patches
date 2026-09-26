#!/usr/bin/env python3
# bakRestore patcher lives in patch-backup-restore.zb64 (zlib+base64).
# apply-backup-restore.sh decodes that when this stub is too small / PLACEHOLDER.
# Full source also in repo as local patch-backup-restore.py for maintainers.
raise SystemExit("Use apply-backup-restore.sh (decodes patch-backup-restore.zb64)")
