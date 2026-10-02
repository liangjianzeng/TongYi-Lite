@echo off
rem adb-wifi.bat - entry point for wireless adb over LAN + VPN (logic lives in adb-wifi.ps1)
rem usage: scripts\adb-wifi.bat [lan-ip] [-VpnIp vpn-ip] [port]
rem        scripts\adb-wifi.bat -Status        list devices + per-channel health check
rem        scripts\adb-wifi.bat -Disconnect    drop the wireless connections
setlocal
set "PS1=%~dp0adb-wifi.ps1"
if not exist "%PS1%" (
  echo [adb-wifi] missing %PS1%
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
