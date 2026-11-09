#!/bin/bash
# [C33] Wait for $1 (serial) to become 'device' (user must accept RSA dialog), then
# switch adb to tcpip:5555 and connect over WiFi. Prints WIFI_ADB_READY <ip:port>.
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
S=$1
for i in $(seq 1 100); do
  ST=$("$ADB" devices | awk -v s=$S '$1==s{print $2}')
  if [ "$ST" == "device" ]; then
    IP=$("$ADB" -s $S shell "ip -f inet addr show wlan0" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | tr -d '\r')
    if [ -n "$IP" ]; then
      "$ADB" -s $S tcpip 5555 >/dev/null 2>&1
      sleep 3
      "$ADB" connect $IP:5555 >/dev/null 2>&1
      if "$ADB" -s $IP:5555 shell "echo ok" 2>/dev/null | grep -q ok; then
        echo "WIFI_ADB_READY $IP:5555"
        exit 0
      fi
    fi
  fi
  sleep 3
done
echo "WIFI_ADB_FAIL last_state=$("$ADB" devices | grep $S | awk '{print $2}')"
exit 1
