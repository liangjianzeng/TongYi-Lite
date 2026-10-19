# TongYi-Lite 打包指南（Windows / Linux 双宿主）

> 一台 Windows 开发机 + 一台 DGX Spark（aarch64 Linux）都能**不改任何入库文件**直接出包。
> 目标：`git clone` 后只配置"机器层"（一次性），即可 `tool/build_apk.ps1` / `tool/build_apk.sh` 一键构建。

## 三层配置模型（重构定案，勿再回退）

| 层 | 载体 | 进 git？ | 内容 |
|---|---|---|---|
| **项目层** | `android/gradle.properties`、`cpp/CMakeLists.txt`、`tool/*` | ✅ | 只放平台无关配置。CMake 里**禁止**出现 `C:\`、`/home/xxx` 等宿主路径，一律走宿主分派 + `VULKAN_SDK` 环境变量 |
| **机器层** | `~/.gradle/gradle.properties`、`android/local.properties`、`android/key.*`、`%USERPROFILE%\.gradle\gradle.properties` | ❌ | JDK 路径、堆大小、并行度、sdk.dir、签名密钥 |
| **环境层** | `JAVA_HOME` / `ANDROID_HOME` / `VULKAN_SDK` / `CMAKE_BUILD_PARALLEL_LEVEL` | ❌ | 由构建入口脚本探测注入 |

**历史教训**：机器层值曾被提交进项目层（Windows JDK 路径、`C:/VulkanSDK`、NDK 目录写死
`windows-x86_64`、`.gitignore` 误忽略 `gradle-wrapper.jar`），导致 Linux 机一切 `reset`
即瘫痪。以上四处已在本次重构中修正，**评审 PR 时盯住项目层文件不得再混入本机路径**。

## 双平台一键入口

```powershell
# Windows（PowerShell）——整合旧 build.bat/build_release.bat
tool\build_apk.ps1                 # debug+release 都打（默认策略）
tool\build_apk.ps1 -Check          # 只自检
tool\build_apk.ps1 -Fast           # 两步法增量（只改 Dart ~2min）
tool\build_apk.ps1 -CleanNative    # 改了 cpp/llama.cpp 必用（防 .so 陈旧）
tool\build_apk.ps1 -Install        # adb install -r（绝不 uninstall）
```

```bash
# Linux（含 aarch64/DGX Spark）——与 DSH-Phone tool/build_apk.sh 同构
tool/build_apk.sh                  # debug+release 都打（默认策略）
tool/build_apk.sh --check
tool/build_apk.sh --clean-native
tool/build_apk.sh --fix-artifacts  # 一次性：补 flutter arm64 主机 gen_snapshot
tool/setup_vulkan_sdk.sh           # 一次性：组装 Linux 原生 Vulkan SDK（glslc 走 apt，免 FEX）
```

两个入口尾部都做**签名验收**：`apksigner` 校验 APK 指纹必须等于
`fbbe1b6c…6992`（`CN=TongYiLite, O=DGXSpark`），不符即失败退出（AGENTS 铁律，防错签名包覆盖不了线上版）。

`dart tool/env_check.dart` 可在任一平台输出同一口径的环境清单（CI/新人自查）。

## 新机器一次性 setup

**Windows**：① 装 Flutter（`C:\src\flutter` 或 PATH）、JDK17（Adoptium）、Android SDK
（platform-tools/platforms/ndk/build-tools/cmake）；② 写 `%USERPROFILE%\.gradle\gradle.properties`：
`org.gradle.java.home`、`org.gradle.jvmargs=-Xmx8g`、`org.gradle.workers.max=16`；
③ 拷 `android/key.jks` + `key.properties`（或 `-KeyFrom <备份路径>`）；④ 可选：LunarG SDK
装到 `C:\VulkanSDK` + MinGW-w64 到 `C:\mingw64`（Vulkan 后端）。

**Linux aarch64**（DGX Spark 已就绪，换机照做）：① Flutter arm64 于 `~/flutter`、JDK17、
Android SDK 于 `~/android-sdk`（含 ndk 27 + cmake）；② amd64 多架构运行库
（`dpkg --add-architecture amd64` + `libc6/libstdc++6/zlib1g:amd64`，官方 x64 aapt2/工具靠它）；
③ FEX（`ppa:fex-emu/fex`，跑 gen_snapshot，qemu 会崩）；④ `tool/build_apk.sh --fix-artifacts`；
⑤ `tool/setup_vulkan_sdk.sh`（可选，Vulkan 后端）；⑥ 写 `~/.gradle/gradle.properties`
（java.home=/usr/lib/jvm/java-17-openjdk-arm64、`-Xmx6g`、workers=8——vLLM 常驻机慎用默认）；
⑦ 拷 `android/key.*`。密钥源备份：Geekpro `E:\DTXY\TongYi-Lite\android\key.*`。

## APK 产物与验收

- 输出目录：`build/app/outputs/flutter-apk/`（两平台一致）
- release 正式签名 = `CN=TongYiLite`；debug 也统一用同证书（可互相覆盖安装）
- 覆盖安装一律 `adb install -r`（先卸载会清端侧模型缓存——AGENTS 铁律）
- Dart 改动后建议字符串级验收（见 [docs/BUILD_ENV_NOTES.md](docs/BUILD_ENV_NOTES.md) 根因 4 与 AGENTS「AOT 暂存 app.so 原名」条）

## VULKAN / OpenCL 后端矩阵

| 宿主 | OpenCL | Vulkan | 条件 |
|---|---|---|---|
| Windows | 自动启用 | 装 LunarG(`C:\VulkanSDK`)+MinGW(`C:\mingw64`) | 缺则自动降级，构建仍成功 |
| Linux x86_64/aarch64 | 自动启用 | `tool/setup_vulkan_sdk.sh` 或 `VULKAN_SDK=<dir>` | 缺则自动降级，构建仍成功 |

CMake 宿主分派逻辑在 `android/app/src/main/cpp/CMakeLists.txt`（宿主探测 →
`host-toolchain-mingw.cmake` / `host-toolchain-linux.cmake`；NDK prebuilt 目录名按宿主生成）。

---
---

# 附录 A：Windows 真机打包调测标准流程（原文保留）

> 目标：用当前源码编出 debug 包并装到已连接的真机，平均 ~1 分钟
> （llama.cpp 原生库已缓存；改写 `third_party/` 下 C++ 会触发 NDK 重编，耗时显著变长）。
> 注：本机路径（`E:\Work\DgxSpark`、`C:\dev-tools\flutter`）为 Windows 开发机专属，属机器层。

## 环境（本机 Windows）

| 组件 | 路径 / 版本 |
|---|---|
| Flutter SDK | `C:\dev-tools\flutter`（Flutter 3.29.0 / Dart 3.7.0 stable） |
| Android SDK / ADB | `C:\Users\jianz\AppData\Local\Android\Sdk`（含 platform-tools/ndk/build-tools/cmake） |
| NDK | `C:\Users\jianz\AppData\Local\Android\Sdk\ndk\27.0.12077973` |
| LunarG Vulkan SDK | `C:\VulkanSDK\1.4.357.0`（编 `vulkan-shaders-gen` 主机工具用） |
| MinGW-w64 GCC | `C:\mingw64`（GCC 16.1.0，主机编 vulkan-shaders-gen 需要配套 C++ 标准库） |
| 包名 | `com.dgxspark.tongyilite`（`android/app/build.gradle.kts`） |
| APK 产物 | `build/app/outputs/flutter-apk/`（app-debug.apk） |

**已验证设备**：小米 `25053RT47C`（Android 16/API 36，序列号 `bf1552ef`，arm64）。

## 标准打包调测流程（每次照做）

### 0. 环境（每条命令前都要）

```bash
export PATH="/c/dev-tools/flutter/bin:/c/mingw64/bin:$PATH"
# ANDROID_HOME 已用 flutter config --android-sdk 持久化（Windows 反斜杠），一般无需再 export
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
cd "/e/Work/DgxSpark/TongYi-Lite"
```

> ⚠️ **mingw 必须加进 PATH**：KleidiAI / Vulkan 的 CMake 构建需要主机端
> `vulkan-shaders-gen`（NDK clang 顶替不了——没有配套 mingw C++ 标准库）。
> （Linux 侧对应物：`tool/setup_vulkan_sdk.sh` 的 glslc + host-toolchain-linux.cmake）

### 1. 确认设备在线

```bash
"$ADB" devices -l          # 应看到 bf1552ef  device；空白=手机未授权/仅充电，回去开 USB 调试
```

### 2. 取依赖（仅改了 pubspec 时需要）

```bash
flutter.bat pub get
```

### 3. 编 debug 包（绕开 flutter run -d 的 daemon 设备匹配抖动）

```bash
flutter.bat build apk --debug --target-platform android-arm64
# 成功标志：√ Built build\app\outputs\flutter-apk\app-debug.apk
# 推荐直接用 tool\build_apk.ps1（含 PATHEXT 修复 + 签名验收）
```

### 3b. 打开产物文件夹（方便自取安装包）

> ⚠️ 必须用 **PowerShell**（不是 Bash）：① Bash 里 `explorer` 参数会被 Git Bash
> 引号破坏；② 从 Bash 调 `powershell.exe` 被安全策略拦截。
> ⚠️ **只打开文件夹，不要高亮选中 APK**（Windows/浏览器无法预览 APK，`/select` 常被解析成下载）。

```powershell
Start-Process 'E:\Work\DgxSpark\TongYi-Lite\build\app\outputs\flutter-apk'
```

### 4. 装到真机（保留数据）

```bash
"$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk   # Success
# 若报 INSTALL_FAILED_UPDATE_INCOMPATIBLE（release 签名冲突）：
#   "$ADB" uninstall com.dgxspark.tongyilite   # 会丢 App 数据+外部模型文件，谨慎
#   再重新 install
```

### 5. 启动 + 验证无崩溃

```bash
"$ADB" logcat -c
"$ADB" shell am start -n com.dgxspark.tongyilite/.MainActivity
"$ADB" shell sleep 6
PID=$("$ADB" shell pidof com.dgxspark.tongyilite | tr -d '\r')
"$ADB" logcat -d --pid=$PID | grep -iE "Native inference|BUILD 2026"   # 引擎初始化 + 版本标识
"$ADB" logcat -d -b crash | tail -5                                     # crash buffer 应为空
```

## 已知坑（已踩过，勿重复）

- **Git Bash 里 `ANDROID_HOME` 必须用 Windows 反斜杠**（`C:\Users\...`），POSIX
  `/c/Users/...` 会被 `flutter.bat` 拒认 → "No Android SDK found"。已用
  `flutter config --android-sdk` 持久化，后续不必再 export。
- **不要用 `flutter run -d bf1552ef`**：daemon 偶发 2 秒内报 "No supported devices found"，
  而 `flutter devices` 又能看到——直接用 build apk + adb install 最稳。
- **改 CMakeLists 的 cache 变量后必须清 `.cxx`**：`rm -rf` 会被沙箱 safe-delete 静默拦截
  （命令看似成功、目录仍在、Gradle 7 秒"编译完成"却产物没变）。用 **PowerShell**：
  `Remove-Item -LiteralPath 'E:\Work\DgxSpark\TongYi-Lite\android\app\.cxx' -Recurse -Force`
  判断是否真重编：看 `build/app/intermediates/cxx/Debug/*/obj/arm64-v8a/` 时间戳与文件清单。
  （或用 `tool\build_apk.ps1 -CleanNative`）
- **构建写入失败 / 锁文件拒绝访问**：build 中断或 Gradle daemon 残留（java.exe /
  FlutterPlugins.exe 持锁）会导致 `flutter_assets` 写不进或
  `fileHashes.lock 拒绝访问`。处理顺序（均带 `dangerouslyDisableSandbox:true`）：
  ① `android/gradlew.bat --stop` + `taskkill /F /PID <java> <FlutterPlugins>`；
  ② `rm -f android/.gradle/<ver>/fileHashes/fileHashes.lock`；
  ③ 仍失败则删 `build/app/intermediates/flutter`（仅 Dart 资源层，不触发原生重编）。
- **沙箱 Git Bash 下 `ANDROID_HOME` 用 Windows 反斜杠**（同上）；本环境 PowerShell 工具
  不回显输出，删除操作用 Bash（safe-delete 能删成功时）。
- **原生构建偶发 `Gradle build daemon disappeared` / CMake 配置失败**：多为 sandbox 守护
  进程崩溃或 `.cxx` 缓存损坏，不是代码问题；先 `./gradlew.bat --stop` 清守护进程再重跑。
- **ADB 识别不到设备** = 手机未开启「USB 调试」/ 未授权 / USB 模式仅充电 / 缺驱动 /
  数据线无数据。Android 11+ 可用「无线调试」→ `adb pair <IP>:<配对端口>` → `adb connect <IP>:<调试端口>`。
- **`sleep` 命令不可用**（Git Bash 沙箱）：用 `"$ADB" shell sleep N` 在设备侧等待。

## 构建配置速查

| 配置 | 位置 | 当前值 |
|---|---|---|
| applicationId / namespace | `android/app/build.gradle.kts` | `com.dgxspark.tongyilite` |
| minSdk / targetSdk / compileSdk | 同上 | 33 / 36 / 36 |
| versionCode / versionName | `pubspec.yaml`（flutter 注入） | 见 pubspec（版本号策略见 AGENTS：复用不轻抬） |
| ABI | 同上 `ndk.abiFilters` | `arm64-v8a` |
| KleidiAI | `android/app/src/main/cpp/CMakeLists.txt` | `GGML_CPU_KLEIDIAI=ON` + vendor 路径 |
| ARM 微架构 | 同上 | `GGML_CPU_ARM_ARCH=armv8.6-a+dotprod+i8mm+fp16+bf16`（三台 Armv9 实测档） |
| Debug 优化 | 同上 | `add_compile_options(-O3)` 目录级（勿再用 CMAKE_C_FLAGS_DEBUG，会被 NDK 顶掉） |
| Vulkan 后端 | 同上（宿主分派） | Win: `C:\VulkanSDK`+mingw；Linux: `~/vulkan-sdk` 或 `$VULKAN_SDK` |

## 推送代码

```bash
git add <改动文件>
git commit -m "fix: 描述修改内容"
git push origin main
# 若被拒（远端有新提交）：git pull --rebase origin main 后再 push
```
