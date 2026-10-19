# TongYi-Lite —— Windows 打包机一键 APK 构建（PowerShell）
#
# 与 tool/build_apk.sh（Linux 侧）同语义：环境自检 → 构建 → 签名验收。
# 整合并取代根目录 build.bat / build_release.bat，沉淀 docs/BUILD_ENV_NOTES.md
# 的 Windows 五大根因经验：
#   1) PATHEXT 被改成 .CPL 会让 flutter/gradle/git 全线找不到 exe —— 本脚本进入即修复
#   2) NDK 全量编译最慢：默认增量，--clean-native 才清 .cxx（改了 native 必须用）
#   3) flutter build apk --debug 在本机 gradle 批处理下会静默失败 —— --fast 走
#      「flutter assemble → 同步 intermediates → gradlew -x」两步法（release 同理，
#      app.so 保持原名进 intermediates/flutter/release/arm64-v8a/，见 AGENTS）
#   4) kernel 路径不一致 → 两步法必须同步 flutter_assets，否则打进旧 Dart
#   5) 覆盖安装绝不 uninstall（模型缓存），adb install -r [-t]
#
# 用法：
#   tool\build_apk.ps1                    # debug+release 都打（AGENTS 默认策略）
#   tool\build_apk.ps1 -Release / -Debug  # 单选
#   tool\build_apk.ps1 -Check             # 只环境自检
#   tool\build_apk.ps1 -Fast              # 两步法增量（只改 Dart/资源时最快 ~2min）
#   tool\build_apk.ps1 -CleanNative       # 清 .cxx 全量重编 NDK
#   tool\build_apk.ps1 -Analyze           # 构建前 flutter analyze
#   tool\build_apk.ps1 -Install           # adb install -r（需连手机）
#   tool\build_apk.ps1 -KeyFrom <path>    # 从备份部署 key.properties（或 $env:TONGYI_KEY_PATH）
#
# 机器层约定（不进 git）：%USERPROFILE%\.gradle\gradle.properties 配
#   org.gradle.java.home=C:\Program Files\Eclipse Adoptium\jdk-17*
#   org.gradle.jvmargs=-Xmx8g ... / org.gradle.workers.max=16
# Vulkan：装 LunarG SDK 到 C:\VulkanSDK（或设 $env:VULKAN_SDK）+ MinGW-w64 于
#   C:\mingw64（cpp/host-toolchain-mingw.cmake 固定路径）。缺失自动降级 OpenCL+CPU。
param(
    [switch]$Release, [switch]$Debug, [switch]$Check, [switch]$Fast,
    [switch]$CleanNative, [switch]$Analyze, [switch]$Install,
    [string]$KeyFrom = ""
)
$ErrorActionPreference = "Stop"
$PROJ = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# 根因 1：PATHEXT 异常直接毁掉所有 exe 查找（cmd/dart package:process 都依赖）
if ($env:PATHEXT -eq ".CPL" -or [string]::IsNullOrEmpty($env:PATHEXT)) {
    $env:PATHEXT = ".EXE;.COM;.BAT;.CMD;.VBS;.JS;.WSF;.MSC"
    Write-Host "  ! PATHEXT 已修复为系统默认（根因 1）" -ForegroundColor Yellow
}

$script:FAIL = 0
function Ok($m)   { Write-Host "  ok $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  X $m" -ForegroundColor Red; $script:FAIL = 1 }
function Find-First($cands) { foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } } return $null }

# ---------- 组件定位 ----------
$Flutter = Find-First @("$env:FLUTTER_BIN",
    (Get-Command flutter -ErrorAction SilentlyContinue)?.Source,
    "C:\src\flutter\bin\flutter.bat", "C:\dev-tools\flutter\bin\flutter.bat")
$AndroidSdk = Find-First @("$env:ANDROID_HOME", "$env:ANDROID_SDK_ROOT",
    "$env:LOCALAPPDATA\Android\Sdk", "C:\Users\jianz\AppData\Local\Android\Sdk")
$Jdk17 = Find-First @("$env:JAVA_HOME",
    ((Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Filter "jdk-17*" -Directory -ErrorAction SilentlyContinue | Select -First 1)?.FullName))

Write-Host "== 环境自检（Windows $([Environment]::OSVersion.Version)）"
if ($Flutter) { Ok "flutter  $Flutter" } else { Bad "找不到 flutter（FLUTTER_BIN 或装到 C:\src\flutter）" }
if ($AndroidSdk -and (Test-Path "$AndroidSdk\platforms") -and (Test-Path "$AndroidSdk\build-tools")) { Ok "Android SDK  $AndroidSdk" } else { Bad "Android SDK 缺 platforms/build-tools：$AndroidSdk" }
if ($Jdk17) { Ok "JDK 17  $Jdk17" } else { Bad "找不到 JDK 17（AGP 要求，Adoptium 安装器）" }

# 机器层 gradle 配置
$mg = Join-Path $env:USERPROFILE ".gradle\gradle.properties"
if ((Test-Path $mg) -and (Select-String -Quiet -Pattern 'org.gradle.java.home' $mg)) { Ok "机器层 ~/.gradle/gradle.properties 已配" }
else { Warn "缺机器层 $mg（org.gradle.java.home / jvmargs / workers 放这里，不放项目 gradle.properties）" }

# wrapper / gradlew（历史 .gitignore 坑，现在必须入库）
if (Test-Path "$PROJ\android\gradle\wrapper\gradle-wrapper.jar") { Ok "gradle-wrapper.jar 就位" }
else { Bad "缺 android/gradle/wrapper/gradle-wrapper.jar —— 从 git 恢复或重跑 'gradle wrapper'，并提交入库" }

# local.properties 防 IDE 写歪
$lp = "$PROJ\android\local.properties"
if ((Test-Path $lp) -and $AndroidSdk) {
    $cur = (Select-String -Path $lp -Pattern '^sdk\.dir=(.*)' | Select -First 1)?.Matches[0]?.Groups[1]?.Value
    if ($cur -ne ($AndroidSdk -replace '\\','/')) { Warn "local.properties sdk.dir=$cur，构建以 ANDROID_HOME=$AndroidSdk 注入为准" }
    else { Ok "local.properties sdk.dir 正确" }
}

# Vulkan（可选，缺则 OpenCL+CPU）
$VkSdk = if ($env:VULKAN_SDK -and (Test-Path $env:VULKAN_SDK)) { $env:VULKAN_SDK } else { Find-First @("C:\VulkanSDK\1.4.357.0", ((Get-ChildItem C:\VulkanSDK -Directory -EA SilentlyContinue | Select -Last 1)?.FullName)) }
if ($VkSdk -and (Test-Path "$VkSdk\Bin\glslc.exe") -and (Test-Path "$PROJ\android\app\src\main\cpp\host-toolchain-mingw.cmake")) {
    Ok "Vulkan SDK $VkSdk（ggml-vulkan 将启用）"
} else { Warn "Vulkan SDK/MinGW 未就绪 → 本次只有 OpenCL+CPU（LunarG 装到 C:\VulkanSDK + mingw64 到 C:\mingw64）" }

# 签名（AGENTS 铁律：CN=TongYiLite）
$EXPECT_FP = "fbbe1b6cf879ab941a65cdd7a7a8dd6f5a6bb640412de38c43cb894f08886992"
if (-not (Test-Path "$PROJ\android\key.properties") -and ($KeyFrom -or $env:TONGYI_KEY_PATH)) {
    $src = if ($KeyFrom) { $KeyFrom } else { $env:TONGYI_KEY_PATH }
    if (Test-Path $src) { Copy-Item $src "$PROJ\android\key.properties" -Force; Ok "key.properties 已从 $src 部署" }
    else { Bad "key 备份不存在：$src" }
}
if ((Test-Path "$PROJ\android\key.properties") -and (Test-Path "$PROJ\android\key.jks")) { Ok "release 签名文件就位" }
else { Warn "缺 android/key.jks|key.properties → release 回退 debug 签名（不能覆盖安装正式版！）" }

if ($FAIL) { Write-Host "`n自检未通过。" -ForegroundColor Red; exit 1 }
if ($Check) { Write-Host "`n自检全部通过。"; exit 0 }

# ---------- 构建 ----------
Set-Location $PROJ
$env:ANDROID_HOME = $AndroidSdk; $env:ANDROID_SDK_ROOT = $AndroidSdk; $env:JAVA_HOME = $Jdk17
$Modes = if ($Release) { @("release") } elseif ($Debug) { @("debug") } else { @("debug","release") }

if ($Analyze) { Write-Host "== flutter analyze"; & $Flutter analyze --no-pub }
Write-Host "== flutter pub get"; & $Flutter pub get

if ($CleanNative) {
    Write-Host "== 清 native 全量重编（先杀锁 .cxx 的残留进程，AGENTS）"
    Stop-Process -Name vulkan-shaders-gen,glslc -Force -EA SilentlyContinue
    Push-Location "$PROJ\android"; .\gradlew.bat --stop | Out-Null; Pop-Location
    Remove-Item -Recurse -Force "$PROJ\android\app\.cxx","$PROJ\build\app\intermediates\cxx" -EA SilentlyContinue
}

foreach ($m in $Modes) {
    if ($Fast) {
        # 两步法（根因 3/4）：assemble → 同步 intermediates → gradlew -x
        Write-Host "== [fast] flutter assemble $m"
        $out = "build\flutter-assemble-$m"
        $platform = if ($m -eq "debug") { "debug_android_application" } else { "release_android_application" }
        & $Flutter assemble -o $out --define=BuildMode=$m --define=TargetPlatform=android-arm64 $platform
        if ($LASTEXITCODE) { throw "flutter assemble 失败" }
        $inter = "build\app\intermediates\flutter\$m"
        if ($m -eq "debug") {
            robocopy "$out\flutter_assets" "$inter\flutter_assets" /MIR /NFL /NDL | Out-Null
        } else {
            New-Item -ItemType Directory -Force "$inter\arm64-v8a" | Out-Null
            Copy-Item "$out\app.so" "$inter\arm64-v8a\app.so" -Force          # 必须原名 app.so（AGENTS 2026-09-18）
            robocopy "$out\flutter_assets" "$inter\flutter_assets" /MIR /NFL /NDL | Out-Null
        }
        Push-Location "$PROJ\android"
        Write-Host "== [fast] gradlew assemble$($m.Substring(0,1).ToUpper())$($m.Substring(1)) -x compileFlutterBuild..."
        .\gradlew.bat "assemble$($m.Substring(0,1).ToUpper())$($m.Substring(1))" "-x" "compileFlutterBuild$($m.Substring(0,1).ToUpper())$($m.Substring(1))"
        $code = $LASTEXITCODE; Pop-Location
        if ($code) { throw "gradle 打包失败" }
    } else {
        Write-Host "== flutter build apk --$m --target-platform android-arm64"
        if ($m -eq "debug") {
            # debug 直接 flutter build 在部分机器静默失败（根因 3），失败自动转两步法
            & $Flutter build apk --debug
            if ($LASTEXITCODE) { Warn "flutter build apk --debug 失败 → 自动转两步法（根因 3）"; $Fast = $true; $Modes = @($m) + ($Modes | Where-Object { $_ -ne $m }); continue }
        } else {
            & $Flutter build apk --release --target-platform android-arm64
            if ($LASTEXITCODE) { throw "flutter build apk 失败" }
        }
    }
    $apk = "build\app\outputs\flutter-apk\app-$m.apk"
    if (-not (Test-Path $apk)) { throw "未找到 $apk" }
    Ok "产物 $apk  $([math]::Round((Get-Item $apk).Length/1MB,1))MB"
}

# ---------- 签名验收（AGENTS 铁律） ----------
$apksigner = (Get-ChildItem "$AndroidSdk\build-tools\*\apksigner.bat" | Sort-Object FullName | Select -Last 1)?.FullName
foreach ($m in $Modes) {
    $apk = "build\app\outputs\flutter-apk\app-$m.apk"
    if ($apksigner) {
        $out = & $apksigner verify --print-certs $apk 2>$null
        $dn = ($out | Select-String 'certificate DN: (.*)').Matches[0].Groups[1].Value
        $fp = ($out | Select-String 'SHA-256 digest: (.*)').Matches[0].Groups[1].Value -replace ':',''
        if ($fp -eq $EXPECT_FP) { Ok "签名验收：$dn" }
        else { Bad "签名不符！$dn 非 CN=TongYiLite —— 检查 android/key.jks（AGENTS 铁律）"; exit 1 }
    }
}
if (-not $CleanNative) { Warn "改过 cpp/ 或 third_party/llama.cpp 时记得 -CleanNative（up-to-date 会跳过）" }

if ($Install) {
    $adb = Find-First @("$AndroidSdk\platform-tools\adb.exe", "adb")
    if ($adb -and (& $adb get-state 2>$null)) {
        foreach ($m in $Modes) { & $adb install -r "build\app\outputs\flutter-apk\app-$m.apk" ; if ($LASTEXITCODE) { & $adb install -r -t "build\app\outputs\flutter-apk\app-$m.apk" } }
    } else { Warn "无 adb 设备，跳过安装" }
}
Write-Host "`n== 完成。APK 目录：$PROJ\build\app\outputs\flutter-apk\" -ForegroundColor Green
