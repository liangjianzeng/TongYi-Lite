# TongYi-Lite 编译与端侧调试指南

> **适用环境**：Windows / macOS / Linux  
> **目标平台**：Android APK (API 33+)  
> **最后更新**：2026-07-29  

---

## 目录

1. [前置环境搭建](#1-前置环境搭建)
2. [项目初始化](#2-项目初始化)
3. [编译构建](#3-编译构建)
4. [端侧调试](#4-端侧调试)
5. [常见问题排查](#5-常见问题排查)
6. [性能分析工具](#6-性能分析工具)

---

## 1. 前置环境搭建

### Windows 环境（推荐）

#### Step 1: 安装 Android Studio

```powershell
# 下载链接：https://developer.android.com/studio
# 或使用 winget 一键安装
winget install Google.AndroidStudio

# 启动后在 Settings → Appearance & Behavior → System Settings → Android SDK 中勾选：
# ✅ SDK Platform (API 36)
# ✅ SDK Build-Tools (35.0.0+)
# ✅ NDK (Side by side, version 29.0.13113456)
# ✅ CMake (3.31.6+)
```

#### Step 2: 安装 Flutter SDK

```powershell
# 方式一：直接下载
# https://docs.flutter.dev/get-started/install/windows/desktop

# 方式二：使用 winget
winget install Flutter.Flutter

# 添加到 PATH（如果自动未生效）
[System.Environment]::SetEnvironmentVariable("PATH", "$env:PATH;C:\flutter\bin", "User")

# 验证安装
flutter --version
```

#### Step 3: 配置环境变量

在 Windows 系统变量中添加：

| 变量名 | 值 | 说明 |
|--------|-----|------|
| `ANDROID_HOME` | `C:\Users\<你的用户名>\AppData\Local\Android\Sdk` | Android SDK 路径 |
| `ANDROID_SDK_ROOT` | `%ANDROID_HOME%` | 同上（兼容） |
| `NDK_VERSION` | `29.0.13113456` | NDK 版本 |

验证环境变量：
```powershell
echo %ANDROID_HOME%
flutter doctor -v
```

#### Step 4: 安装 Git LFS（模型文件管理）

```powershell
winget install Git.GitLFS
git lfs install
```

---

### macOS 环境

```bash
# Android Studio
brew install --cask android-studio

# Flutter SDK
brew install flutter

# 配置环境变量 (~/.zshrc)
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH="$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools:$PATH"

# 验证
flutter doctor -v
```

---

### Linux (Ubuntu/Debian) 环境

```bash
# Android Studio + SDK
sudo snap install android-studio --classic

# Flutter SDK
git clone https://github.com/flutter/flutter.git ~/development/flutter
echo 'export PATH="$PATH:$HOME/development/flutter/bin"' >> ~/.bashrc
source ~/.bashrc

# NDK + CMake（通过 Android Studio 安装）
# 或使用命令行：
sdkmanager "ndk;29.0.13113456" "cmake;3.31.6"

flutter doctor -v
```

---

## 2. 项目初始化

### Step 1: 克隆仓库 + 子模块

```bash
cd E:/Work/DgxSpark/TongYi-Lite

# 如果还没克隆过：
git clone git@github.com:liangjianzeng/TongYi-Lite.git
cd TongYi-Lite

# 初始化 llama.cpp 子模块（这是核心推理引擎）
git submodule update --init --recursive

# 验证子模块是否正确
ls third_party/llama.cpp/src/llama.cpp && echo "✅ llama.cpp OK"
```

### Step 2: 获取 Flutter 依赖

```bash
flutter pub get
```

预期输出：
```
Resolving dependencies...
Downloading packages...
Got dependencies!
```

### Step 3: 验证项目结构

```bash
# 检查关键文件是否存在
ls -la android/app/src/main/cpp/CMakeLists.txt
ls -la android/app/src/main/cpp/tongyilite_jni.cpp
ls -la third_party/llama.cpp/src/llama.cpp
ls -la lib/main.dart

# 预期输出：所有文件都存在，无缺失
```

### Step 4: 配置 Gradle（首次构建）

```bash
cd android
./gradlew wrapper --gradle-version=8.7.0
cd ..
```

如果 `./gradlew` 不存在，Flutter 会自动生成。

---

## 3. 编译构建

### 方式一：Debug APK（快速迭代）

```bash
# 在终端中运行
flutter build apk --debug

# 输出位置
ls build/app/outputs/flutter-apk/

# 预期文件：app-debug.apk (~50-80 MB)
```

### 方式二：Release AAB（发布到 Google Play）

```bash
flutter build appbundle --release

# 输出位置
ls build/app/outputs/bundle/release/

# 预期文件：app-release.aab (~20-40 MB, 已压缩)
```

### 方式三：同时构建 Debug + Release

```bash
flutter build apk --debug && flutter build appbundle --release
```

---

## 4. 端侧调试

### Step 1: 连接 Android 设备

#### USB 调试模式（推荐）

1. 手机开启开发者选项：
   - 设置 → 关于手机 → 连续点击"版本号"7次
2. 进入开发者选项，开启 **USB 调试**
3. 用 USB 线连接电脑，允许 USB 调试授权

#### WiFi 调试（无线）

```bash
# 手机端：设置 → 开发者选项 → Wireless debugging → 打开
# 手机会显示 IP:端口 格式的连接信息

# 电脑上连接
adb connect <手机IP>:<端口>

# 验证连接
adb devices

# 预期输出
List of devices attached
192.168.x.x:<port>    device
```

### Step 2: 安装 APK 到设备

```bash
# 方式一：flutter run（推荐，自动编译+安装+启动）
flutter run -d <device_id>

# 方式二：手动安装已构建的 APK
adb install build/app/outputs/flutter-apk/app-debug.apk

# 验证安装成功
adb shell pm list packages | grep tongyilite
```

### Step 3: 实时日志查看

```bash
# Flutter 日志（Dart 层）
flutter logs

# Android 原生日志（JNI/C++ 层）
adb logcat -s TongYiLite:* InferenceEngine:*

# 过滤特定标签的日志
adb logcat | grep -E "TongYiLite|InferenceEngine|llama"

# 清空日志缓存后重新查看
adb logcat -c && adb logcat -s TongYiLite:*
```

### Step 4: 运行基准测试

在应用内或通过 ADB shell 执行：

```bash
# 通过 ADB shell 触发测试（如果应用提供了测试入口）
adb shell am start -n com.dgxspark.tongyilite/.MainActivity \
  --es test "benchmark"

# 或直接查看日志中的基准测试结果
adb logcat | grep "Benchmark"
```

预期日志输出：
```
I/TongYiLite: Benchmark (3 runs): prompt=45ms gen=120ms 8.5 tok/s
```

---

## 5. 常见问题排查

### 问题 1: `llama.cpp submodule not found`

**症状**：CMake 报错 "llama.cpp not found"

**解决**：
```bash
git submodule update --init --recursive
# 如果仍然失败，手动克隆
cd third_party/llama.cpp
git fetch origin master
git checkout b10173
cd ../..
```

### 问题 2: `NDK not found`

**症状**：Gradle 构建时报 NDK 版本错误

**解决**：
```bash
# 检查 Android Studio SDK Manager 中是否安装了正确的 NDK
# NDK version: 29.0.13113456 (Side by side)

# 或在命令行安装
sdkmanager "ndk;29.0.13113456"
```

### 问题 3: `CMake not found`

**症状**：构建时报 CMake 版本错误

**解决**：
```bash
# Android Studio SDK Manager 中安装 CMake 3.31.6+
sdkmanager "cmake;3.31.6"

# 或在命令行配置环境变量
export PATH="$ANDROID_HOME/cmake/3.31.6/bin:$PATH"
```

### 问题 4: `JNI library not loaded`

**症状**：App 启动后闪退，logcat 显示 "UnsatisfiedLinkError"

**解决**：
```bash
# 检查 APK 中是否包含 .so 文件
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep libllama

# 如果没有，重新构建
flutter clean && flutter build apk --debug

# 如果仍然失败，检查 CMakeLists.txt 中的路径配置
cat android/app/src/main/cpp/CMakeLists.txt | grep LLAMA_CPP_DIR
```

### 问题 5: `Model file not found`

**症状**：App 运行时提示模型文件不存在

**解决**：
1. 确认模型已下载到设备存储中
2. 检查 model_manager.dart 中的下载 URL 是否正确
3. 手动下载模型到设备：
   ```bash
   adb push qwen3-1.7b-q4_k_m.gguf /sdcard/Download/
   # 或在应用内触发下载
   ```

---

## 6. 性能分析工具

### Android Profiler（Android Studio）

```
Tools → Profile or Debug APK → 选择 app-debug.apk

可查看：
- CPU Usage (推理线程占用)
- Memory Allocation (内存峰值)
- Network Traffic (模型下载速度)
- Energy (功耗估算)
```

### systrace（高级性能分析）

```bash
# 记录 10 秒的性能 trace
adb shell /system/bin/systrace -t 10 \
  --devices=cpu,thermal,freq,gpu sched freq idle disk block power wm \
  -o profile.html com.dgxspark.tongyilite

# 在浏览器中打开 profile.html 分析瓶颈
```

### perf + ftrace（Linux/ARM 内核级）

```bash
# 在设备上运行（需要 root）
adb shell "su -c 'perf record -g -F 99999 -a -- sleep 5'"
adb pull /data/perf.data ./perf.data
perf report -i perf.data
```

---

## 附录：完整构建脚本（一键编译）

创建 `scripts/build.sh`：

```bash
#!/bin/bash
set -e

echo "=== TongYi-Lite Build Script ==="

# Step 1: Clean previous builds
flutter clean

# Step 2: Get dependencies
flutter pub get

# Step 3: Initialize submodules (if not done)
git submodule update --init --recursive

# Step 4: Build Debug APK
echo "Building Debug APK..."
flutter build apk --debug

# Step 5: Build Release AAB
echo "Building Release AAB..."
flutter build appbundle --release

# Step 6: Verify outputs
if [ -f build/app/outputs/flutter-apk/app-debug.apk ]; then
    echo "✅ Debug APK built successfully"
else
    echo "❌ Debug APK build failed"
    exit 1
fi

if [ -f build/app/outputs/bundle/release/app-release.aab ]; then
    echo "✅ Release AAB built successfully"
else
    echo "❌ Release AAB build failed"
    exit 1
fi

echo "=== Build Complete ==="
ls -lh build/app/outputs/flutter-apk/app-debug.apk
ls -lh build/app/outputs/bundle/release/app-release.aab
```

使用方法：
```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

---

## 下一步建议

1. **先跑通 Debug APK** → `flutter run` 验证基础功能
2. **再测 Release AAB** → 确认压缩和签名无误
3. **最后做性能调优** → 使用 Android Profiler 分析瓶颈

如遇问题，请查看本文档的"常见问题排查"章节。
