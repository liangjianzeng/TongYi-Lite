#!/usr/bin/env bash
# adb-wifi.sh - connect wireless adb to every Android node on the tailnet.
#
# Designed for a remote host (e.g. DGX Spark) that has no USB access to the phone.
# The phone must already have adbd in TCP mode (run scripts\adb-wifi.ps1 on the
# Windows box that has the USB cable) and the Tailscale app must be online.
#
# Usage:
#   ./adb-wifi.sh              connect + verify all android tailnet peers
#   ./adb-wifi.sh -d           disconnect all
#
# Requires: adb (android-tools-adb) + ~/.android/adbkey copied from the Windows box
#           (otherwise the phone shows "unauthorized" and needs an on-screen tap).
set -u

PORT="${PORT:-5555}"
ADB="$(command -v adb || true)"
TS="$(command -v tailscale || echo /usr/bin/tailscale)"

if [ -z "$ADB" ]; then
    echo "ERROR: adb not found. Install it with: sudo apt-get install -y android-tools-adb" >&2
    exit 1
fi

# collect IPs of peers whose OS column is "android", skipping offline ones
# (connecting to an offline peer blocks for a long time and stalls the whole run)
mapfile -t IPS < <("$TS" status 2>/dev/null | awk '$4 == "android" && $0 !~ /offline/ { print $1 }')

if [ "${#IPS[@]}" -eq 0 ]; then
    echo "ERROR: no reachable android node found on the tailnet."
    echo "       Is the Tailscale app running and logged in on the phone?"
    echo "       From the USB host: adb shell monkey -p com.tailscale.ipn -c android.intent.category.LAUNCHER 1"
    exit 1
fi

echo "[1/3] android tailnet peers: ${IPS[*]}"

if [ "${1:-}" = "-d" ]; then
    for ip in "${IPS[@]}"; do timeout 10 "$ADB" disconnect "${ip}:${PORT}" >/dev/null 2>&1; done
    "$ADB" devices
    exit 0
fi

"$ADB" start-server >/dev/null 2>&1

echo "[2/3] connecting:"
for ip in "${IPS[@]}"; do
    timeout 15 "$ADB" connect "${ip}:${PORT}" 2>&1 | sed 's/^/      /'
done
sleep 2
"$ADB" devices -l

echo "[3/3] verify:"
rc=0
for ip in "${IPS[@]}"; do
    model="$(timeout 15 "$ADB" -s "${ip}:${PORT}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    if [ -n "$model" ]; then
        tcp="$(timeout 15 "$ADB" -s "${ip}:${PORT}" shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')"
        lvl="$(timeout 15 "$ADB" -s "${ip}:${PORT}" shell "dumpsys battery | grep -m1 level" 2>/dev/null | tr -d '\r ')"
        echo "      OK   ${ip}:${PORT}  model=${model} tcp=${tcp} ${lvl}"
    else
        echo "      FAIL ${ip}:${PORT}  (not reachable)"
        rc=1
    fi
done

exit $rc
