#!/bin/bash
# [C33] Like adb_wifi_takeover but watches for ANY authorized device (user may re-seat any phone).
# On success prints: WIFI_ADB_READY <serial> <model> <ip:port>
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
for i in $(seq 1 400); do
  LINE=$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')
  if [ -n "$LINE" ]; then
    S=$LINE
    IP=$("$ADB" -s $S shell "ip -f inet addr show wlan0" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | tr -d '\r')
    M=$("$ADB" -s $S shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    if [ -n "$IP" ]; then
      "$ADB" -s $S tcpip 5555 >/dev/null 2>&1
      sleep 3
      "$ADB" connect $IP:5555 >/dev/null 2>&1
      if "$ADB" -s $IP:5555 shell "echo ok" 2>/dev/null | grep -q ok; then
        echo "WIFI_ADB_READY $S $M $IP:5555"
        exit 0
      fi
    fi
  fi
  sleep 3
done
echo "WIFI_ADB_FAIL $(adb devices 2>/dev/null | tail -n +2 | tr '\n' ';')"
exit 1
