<#
  adb-wifi.ps1 - enable / re-connect wireless adb over LAN **and** VPN (Tailscale).

  Usage:
    scripts\adb-wifi.bat                  auto: USB present -> read wlan0 + tun IPs, switch adbd to tcp,
                                          connect BOTH the LAN and the VPN channel
    scripts\adb-wifi.bat 192.168.0.107    explicit LAN IP
    scripts\adb-wifi.bat -VpnIp 100.70.7.18   explicit VPN IP
    scripts\adb-wifi.bat -Port 5555       custom port
    scripts\adb-wifi.bat -Status          list devices + per-channel health check
    scripts\adb-wifi.bat -Disconnect      drop the wireless connections

  Requirements: phone on the same LAN. First-time enable (adb tcpip) needs a USB cable.
  Note: adbd falls back to USB mode after a phone reboot - plug USB and run once again.

  NOTE: keep this file pure ASCII. PowerShell 5.1 reads BOM-less scripts as ANSI(GBK),
        so non-ASCII text here breaks parsing on zh-CN Windows.
#>
param(
    [Parameter(Position = 0)][string]$Ip,
    [string]$VpnIp,
    [int]$Port = 5555,
    [switch]$Disconnect,
    [switch]$Status
)

$ErrorActionPreference = 'Continue'

# --- locate adb ---
$adbCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
    'C:\Android\Sdk\platform-tools\adb.exe'
)
$adb = $adbCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $adb) { $adb = 'adb' }   # fall back to PATH

$ipCache    = Join-Path $PSScriptRoot '.adb_wifi_ip'
$vpnIpCache = Join-Path $PSScriptRoot '.adb_wifi_vpnip'

function Get-UsbSerial {
    $devs = & $adb devices 2>$null | Select-Object -Skip 1
    foreach ($line in $devs) {
        if ($line -match '^(\S+)\s+device\b') {
            $serial = $Matches[1]
            if ($serial -notmatch ':\d+$') { return $serial }   # skip wireless ip:port entries
        }
    }
    return $null
}

function Get-WirelessTargets {
    # fill only what is still empty - never clobber an explicitly passed / freshly read value
    if (-not $script:Ip    -and (Test-Path $ipCache))    { $script:Ip    = (Get-Content $ipCache    -Raw).Trim() }
    if (-not $script:VpnIp -and (Test-Path $vpnIpCache)) { $script:VpnIp = (Get-Content $vpnIpCache -Raw).Trim() }
}

# --- status mode ---
if ($Status) {
    Write-Host "[status] devices:"
    & $adb devices -l
    Write-Host ""
    Get-WirelessTargets
    foreach ($target in @($Ip, $VpnIp) | Where-Object { $_ }) {
        $ep = "${target}:$Port"
        $model = & $adb -s $ep shell "getprop ro.product.model" 2>$null
        if ($model) {
            $tcp = & $adb -s $ep shell "getprop service.adb.tcp.port" 2>$null
            $bat = & $adb -s $ep shell "dumpsys battery | grep -m1 level" 2>$null
            Write-Host ("  OK   {0,-22} model={1} tcp={2} {3}" -f $ep, ($model -join '').Trim(), ($tcp -join '').Trim(), ($bat -join '').Trim())
        } else {
            Write-Host ("  FAIL {0,-22} (not reachable)" -f $ep)
        }
    }
    return
}

# --- disconnect mode ---
if ($Disconnect) {
    Get-WirelessTargets
    foreach ($target in @($Ip, $VpnIp) | Where-Object { $_ }) {
        & $adb disconnect "${target}:$Port" 2>$null | Out-Null
    }
    if (-not (Test-Path $ipCache) -and -not (Test-Path $vpnIpCache)) { & $adb disconnect | Out-Null }
    & $adb devices
    return
}

# --- 1. find a USB-attached device ---
$usb = Get-UsbSerial
$lanFromUsb = $null
$vpnFromUsb = $null

if ($usb) {
    Write-Host "[1/5] USB device: $usb"

    $rawWlan = (& $adb -s $usb shell "ip -4 addr show wlan0" 2>$null) -join "`n"
    $m = [regex]::Match($rawWlan, 'inet (\d+\.\d+\.\d+\.\d+)')
    if ($m.Success) { $lanFromUsb = $m.Groups[1].Value }

    $rawAll = (& $adb -s $usb shell "ip -4 addr show" 2>$null) -join "`n"
    $addrs = [regex]::Matches($rawAll, 'inet (\d+\.\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value }
    # Tailscale lives in the CGNAT range 100.64.0.0/10
    $vpnFromUsb = $addrs | Where-Object { $_ -match '^100\.(6[4-9]|[7-9]\d|1[0-1]\d|12[0-7])\.' } | Select-Object -First 1

    if ($lanFromUsb) { Write-Host "[2/5] phone LAN IP: $lanFromUsb" } else {
        Write-Host "[2/5] WARN: no wlan0 IPv4 - is the phone on wifi?"
    }
    if ($vpnFromUsb) { Write-Host "      phone VPN IP: $vpnFromUsb" } else {
        Write-Host "      WARN: no 100.64/10 address - is the Tailscale app running on the phone?"
    }

    $r = & $adb -s $usb tcpip $Port 2>&1
    Write-Host "[3/5] $r"
    Start-Sleep -Seconds 4
} else {
    Write-Host "[1/5] no USB device, will reuse cached IPs"
}

# --- 2. resolve targets (explicit param > USB reading > cache) ---
if (-not $Ip    -and $lanFromUsb) { $Ip    = $lanFromUsb }
if (-not $VpnIp -and $vpnFromUsb) { $VpnIp = $vpnFromUsb }
Get-WirelessTargets   # fills only the ones still empty

if ($Ip)    { Set-Content -Path $ipCache    -Value $Ip    -NoNewline -Encoding ascii }
if ($VpnIp) { Set-Content -Path $vpnIpCache -Value $VpnIp -NoNewline -Encoding ascii }

if (-not $Ip -and -not $VpnIp) {
    Write-Host "ERROR: phone IP unknown. Plug USB, or pass it explicitly: scripts\adb-wifi.bat 192.168.0.107"
    exit 1
}

# --- 3. idempotent reconnect on every channel ---
$targets = @($Ip, $VpnIp) | Where-Object { $_ } | Select-Object -Unique
foreach ($target in $targets) {
    & $adb disconnect "${target}:$Port" 2>$null | Out-Null
    $out = & $adb connect "${target}:$Port" 2>&1
    Write-Host "[3/5] $out"
}
Start-Sleep -Seconds 2

# --- 4. result ---
Write-Host "[4/5] devices:"
& $adb devices -l

# --- 5. verify with a real command on each channel ---
Write-Host "[5/5] verify:"
foreach ($target in $targets) {
    $ep = "${target}:$Port"
    $model = & $adb -s $ep shell "getprop ro.product.model" 2>$null
    if ($model) {
        $tcp = & $adb -s $ep shell "getprop service.adb.tcp.port" 2>$null
        $bat = & $adb -s $ep shell "dumpsys battery | grep -m1 level" 2>$null
        Write-Host ("  OK   {0,-22} model={1} tcp={2} {3}" -f $ep, ($model -join '').Trim(), ($tcp -join '').Trim(), ($bat -join '').Trim())
    } else {
        Write-Host ("  FAIL {0,-22} (not reachable)" -f $ep)
    }
}
