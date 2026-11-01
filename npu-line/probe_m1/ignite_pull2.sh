#!/bin/bash
# v2: on the first online window, disable doze FIRST (stops adb flapping),
# then ignite nohup curl on device.
ADB="C:/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
export MSYS_NO_PATHCONV=1
S=100.75.247.55:5555
URL=https://liang-geekpro.tailfe4bdd.ts.net/libspark_v4_qnn.so
DST=/data/local/tmp/npu_m1/libspark_v4_qnn.so
for i in $(seq 1 144); do
  echo "[$(date +%T)] attempt $i"
  "$ADB" connect $S 2>&1 | head -1
  STATE=$("$ADB" -s $S get-state 2>/dev/null)
  if [ "$STATE" = "device" ]; then
    echo "[$(date +%T)] online -> disable doze"
    "$ADB" -s $S shell "dumpsys deviceidle disable" 2>&1 | head -1
    "$ADB" -s $S shell "settings put global wifi_sleep_policy 2" 2>&1 | head -1
    sleep 2
    echo "[$(date +%T)] ignite curl"
    "$ADB" -s $S shell "nohup sh -c 'curl -k -C - --retry 60 --retry-delay 3 --retry-all-errors -o $DST $URL' > /data/local/tmp/npu_m1/curl_pull.log 2>&1 &" 2>&1 | head -1
    sleep 8
    "$ADB" -s $S shell "ls -la $DST 2>/dev/null" 2>&1 | head -1
    "$ADB" -s $S shell "tail -2 /data/local/tmp/npu_m1/curl_pull.log 2>/dev/null" 2>&1 | head -2
    # confirm it is still alive
    sleep 20
    SZ1=$("$ADB" -s $S shell "stat -c %s $DST 2>/dev/null" 2>/dev/null | tr -d '\r')
    sleep 15
    SZ2=$("$ADB" -s $S shell "stat -c %s $DST 2>/dev/null" 2>/dev/null | tr -d '\r')
    echo "size1=$SZ1 size2=$SZ2"
    if [ -n "$SZ2" ] && [ "$SZ2" != "$SZ1" -o "$SZ2" -gt 1000000 ]; then
      echo "PULL_RUNNING_OR_DONE"
      exit 0
    fi
  fi
  sleep 300
done
echo NEVER_ONLINE
exit 1
