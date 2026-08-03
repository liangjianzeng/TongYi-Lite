# 打包安装标准流程

## 环境
- Flutter SDK: `/c/dev-tools/flutter/bin/flutter`
- ADB: `/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe`
- Android SDK: `/c/Users/jianz/AppData/Local/Android/Sdk`

## 打包安装命令（一条命令搞定）
```bash
export PATH="/c/dev-tools/flutter/bin:/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools:$PATH"
cd "/e/Work/DgxSpark/TongYi-Lite"
flutter build apk --release 2>&1 | tail -3
adb install -r "build/app/outputs/flutter-apk/app-release.apk" 2>&1
```

## 推送代码
```bash
cd "/e/Work/DgxSpark/TongYi-Lite"
git add -A
git commit -m "fix: 描述修改内容"
git push origin main
```
