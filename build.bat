@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: ============================================================
::  TongYi-Lite 一键打包脚本
::  用法: build.bat [key_path]
::    key_path : key.properties 源路径（默认从环境变量读取）
:: ============================================================

:: ---------- 配置区 ----------
set "ADB=C:\Users\jianz\AppData\Local\Android\Sdk\platform-tools\adb.exe"
set "FLUTTER=C:\dev-tools\flutter\bin\flutter.bat"
set "KEY_SRC=%~1"
if "%KEY_SRC%"=="" set "KEY_SRC=%TONGYI_KEY_PATH%"
if "%KEY_SRC%"=="" set "KEY_SRC=C:\Users\jianz\Documents\xwechat_files\love2bloved_ac69\msg\file\2026-08\key.properties"
set "KEY_DST=android\key.properties"
set "APP_ID=com.dgxspark.tongyilite"
:: ----------------------------

echo.
echo ============================================================
echo   TongYi-Lite 一键打包
echo ============================================================
echo.

:: Step 1: 检查设备
echo [1/6] 检查连接设备...
for /f "tokens=1" %%d in ('%ADB% devices ^| findstr /v "List\|^$"') do (
    set "DEVICE=%%d"
    goto :device_found
)
echo   ❌ 没有检测到设备，请先通过 USB 连接手机并开启调试模式。
pause
exit /b 1
:device_found
echo   ✅ 设备: %DEVICE%
echo.

:: Step 2: 复制 key.properties
echo [2/6] 部署签名配置...
if not exist "%KEY_SRC%" (
    echo   ❌ key.properties 源文件不存在: %KEY_SRC%
    pause
    exit /b 1
)
copy /y "%KEY_SRC%" "%KEY_DST%" >nul
echo   ✅ key.properties → %KEY_DST%
echo.

:: Step 3: 卸载旧版本（签名不同时必须彻底清除）
echo [3/6] 清除旧安装...
%ADB% -s %DEVICE% uninstall %APP_ID% >nul 2>&1
timeout /t 1 /nobreak >nul
echo   ✅ 旧版本已清除（或不存在）
echo.

:: Step 4: 构建 APK
echo [4/6] 构建 Debug APK ...
%FLUTTER% build apk --debug
if errorlevel 1 (
    echo   ❌ 构建失败！
    pause
    exit /b 1
)
echo   ✅ 构建成功
echo.

:: Step 5: 安装到设备
echo [5/6] 安装到设备...
%ADB% -s %DEVICE% install "build\app\outputs\flutter-apk\app-debug.apk"
if errorlevel 1 (
    echo   ❌ 安装失败！
    pause
    exit /b 1
)
echo   ✅ 安装成功！
echo.

:: Step 6: 打开 APK 文件夹
echo [6/6] 打开输出目录...
set "APK_DIR=%~dp0build\app\outputs\flutter-apk"
explorer.exe "%APK_DIR%"
echo 📂 已打开: %APK_DIR%
echo.
echo ============================================================
echo   完成！
echo ============================================================
pause
