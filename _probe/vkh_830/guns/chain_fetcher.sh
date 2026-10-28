#!/bin/bash
export ANDROID_ADB_SERVER_PORT=15037
OUT=/tmp/chain_fetch_740.log
: > $OUT
for i in $(seq 1 120); do
  for D in 100.75.247.55:5555 100.109.138.2:5555; do
    timeout 12 adb connect $D >/dev/null 2>&1
    st=$(timeout 10 adb devices 2>/dev/null | grep "$D" | awk '{print $2}')
    if [ "$st" = "device" ]; then
      echo "=== try$i ONLINE via $D $(date +%T) ===" >> $OUT
      timeout 30 adb -s $D shell "cat /data/local/tmp/mesa_clrt_1026/out/chain.log 2>/dev/null; echo '===CRASH==='; tail -40 /data/local/tmp/mesa_clrt_1026/out/chain_crash.txt 2>/dev/null" >> $OUT 2>&1
      if grep -q 'CHAIN done' $OUT; then echo FETCH_COMPLETE >> $OUT; exit 0; fi
    fi
  done
  sleep 20
done
echo EXHAUSTED >> $OUT
