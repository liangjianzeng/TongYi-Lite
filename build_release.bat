@echo off
rem TongYi-Lite release build - run this in YOUR OWN cmd/PowerShell window
rem (WorkBuddy sandbox blocks dart.exe pipe spawn; user terminal is clean)
setlocal
set LOG=E:\DTXY\TongYi-Lite\_study\bonsai2_port\build_release_user.log
set DART=C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe
set FLUTTER=C:\src\flutter\bin\flutter.bat

echo === build start %date% %time% === > "%LOG%"

echo [1/2] dart spawn probe...
"%DART%" E:\DTXY\TongYi-Lite\_study\bonsai2_port\_dp.dart >> "%LOG%" 2>&1
type "%LOG%" | findstr /C:"DART_SPAWN_OK" >nul
if errorlevel 1 (
  echo [ABORT] dart spawn FAIL in this terminal too - machine-wide problem
  type "%LOG%" | findstr "DART"
  pause
  exit /b 1
)
echo [1/2] dart spawn OK

echo [2/2] flutter build apk --release ...
cd /d E:\DTXY\TongYi-Lite
call "%FLUTTER%" build apk --release >> "%LOG%" 2>&1
set RC=%errorlevel%
echo [2/2] BUILD_EXIT=%RC%
echo BUILD_EXIT=%RC% >> "%LOG%"

if "%RC%"=="0" (
  echo APK: E:\DTXY\TongYi-Lite\build\app\outputs\flutter-apk\app-release.apk
)
pause
endlocal
