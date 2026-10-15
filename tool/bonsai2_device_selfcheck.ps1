# bonsai2-27b 新机加载失败 一键自检（Redmi K90 至尊版 / 骁龙8至尊版 / 16GB）
# 用法：
#   .\bonsai2_device_selfcheck.ps1              # 静态检查 + dump 现有日志
#   .\bonsai2_device_selfcheck.ps1 -ClearLogcat # 先清日志 → 手机上点“加载” → 再跑一次本脚本收日志
# 输出同时打印并保存到 tool\selfcheck_report.txt

param([switch]$ClearLogcat)

$ErrorActionPreference = 'Continue'
$pkg = 'com.dgxspark.tongyilite'
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
if (-not (Test-Path $adb)) { $adb = 'adb' }

$report = @()
function Say($s) { $script:report += $s; Write-Host $s }

$devs = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' }
if (-not $devs) { Write-Host "!! 没有已授权的 adb 设备。请开启 USB 调试并连接。" ; exit 1 }
Say ("设备: " + (($devs | ForEach-Object { ($_ -split '\t')[0] }) -join ', '))

function SH($cmd) { (& $adb shell $cmd) -join "`n" }

Say "`n===== [1] 机型 / SoC ====="
foreach ($p in 'ro.product.model','ro.product.marketname','ro.board.platform','ro.soc.model','ro.hardware','ro.build.version.release','ro.build.version.sdk') {
  Say ("{0} = {1}" -f $p, (SH "getprop $p"))
}

Say "`n===== [2] 内存（bonsai2 生死线）====="
Say (SH "cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|ZramUsed'")
Say ("PSI memory: " + (SH "cat /proc/pressure/memory"))

Say "`n===== [3] GPU / Vulkan / OpenCL 可用性 ====="
Say ("GLES: " + ((SH "dumpsys SurfaceFlinger | grep -m2 -iE 'GLES|Vulkan'") -replace "`n", ' | '))
Say ("vulkan features: " + ((SH "pm list features | grep -i vulkan") -replace "`n", ' | '))
Say ("/vendor/lib64/hw 驱动: " + ((SH "ls /vendor/lib64/hw 2>/dev/null | grep -iE 'vulkan|opencl'") -replace "`n", ' | '))
Say ("libOpenCL.so: " + ((SH "ls -l /vendor/lib64/libOpenCL.so /system/lib64/libOpenCL.so 2>/dev/null") -replace "`n", ' | '))
Say ("adreno props: " + ((SH "getprop | grep -iE 'adreno|gralloc.*version' | head -5") -replace "`n", ' | '))

Say "`n===== [4] App 版本（是否旧 APK 不认识 PTQ1_0）====="
Say ((SH "dumpsys package $pkg | grep -E 'versionCode|versionName|lastUpdateTime'") -join "`n")

Say "`n===== [5] 模型文件 + 空间 ====="
Say ("外部目录: " + (SH "ls -l /storage/emulated/0/TongYiLite/models/ 2>/dev/null"))
Say ("半截下载(.part): " + ((SH "ls /storage/emulated/0/TongYiLite/models/*.part 2>/dev/null; ls /storage/emulated/0/TongYiLite/models/ 2>/dev/null | grep -i part") -replace "`n", ' | '))
Say ("app私有目录: " + (SH "ls -lR /storage/emulated/0/Android/data/$pkg/files 2>/dev/null | head -20"))
Say ("空间: " + ((SH "df /data | tail -1") -replace "`n", ' '))

if ($ClearLogcat) {
  & $adb logcat -c | Out-Null
  Say "`n日志已清空。请在手机上点『加载』跑一次 bonsai2，几秒后再跑: .\bonsai2_device_selfcheck.ps1"
} else {
  Say "`n===== [6] logcat 关键证据（oom-guard / handleLoadModel / 后端 / 崩溃）====="
  $pat = 'oom-guard|handleLoadModel|loadModel|ggml|llama|Vulkan|OpenCL|turnip|F DEBUG|AndroidRuntime|DEBUG.*signal|PTQ'
  $log = & $adb logcat -d -v time 2>$null | Select-String -Pattern $pat
  if ($log) { $log | Select-Object -Last 120 | ForEach-Object { Say $_.Line } } else { Say "(无匹配日志；先 -ClearLogcat 清一次再复现)" }
}

$out = Join-Path $PSScriptRoot 'selfcheck_report.txt'
$report -join "`n" | Out-File -FilePath $out -Encoding utf8
Write-Host "`n报告已保存: $out"
