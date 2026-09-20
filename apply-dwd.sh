set +H
cd /tmp
rm -f patch-dwd.py patch-dwd.part*
for i in 0 1 2 3; do
  curl -fsSL "https://raw.githubusercontent.com/Frankenland90/prepper-patches/main/patch-dwd.part$i" -o "patch-dwd.part$i" || { echo CURL_FAIL $i; exit 1; }
done
cat patch-dwd.part0 patch-dwd.part1 patch-dwd.part2 patch-dwd.part3 > patch-dwd.py
wc -c patch-dwd.py
python3 -m py_compile patch-dwd.py || { echo BAD_PATCH; exit 1; }
grep -q 'forecast/recent' patch-dwd.py || { echo NO_FORECAST; exit 1; }
cp -a /home/fmg/prepper-dashboard/dashboard.py /home/fmg/prepper-dashboard/dashboard.py.bak-dwd-$(date +%Y%m%d-%H%M%S)
python3 /tmp/patch-dwd.py /home/fmg/prepper-dashboard/dashboard.py
python3 -m py_compile /home/fmg/prepper-dashboard/dashboard.py || { echo BAD_DASH; exit 1; }
sudo systemctl restart prepper-dashboard
sleep 2
systemctl is-active prepper-dashboard
grep -c fetch_dwd_wbi /home/fmg/prepper-dashboard/dashboard.py
