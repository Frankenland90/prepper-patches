#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/Frankenland90/prepper-patches/main/patch-adsb-mil-yaxis.py -o /tmp/patch-adsb-mil-yaxis.py
python3 /tmp/patch-adsb-mil-yaxis.py /home/fmg/prepper-dashboard/dashboard.py
python3 -m py_compile /home/fmg/prepper-dashboard/dashboard.py
systemctl restart prepper-dashboard
systemctl is-active prepper-dashboard
grep -n milyAxis /home/fmg/prepper-dashboard/dashboard.py
