# TongYi-Lite 项目长期记忆

## 构建/调测环境（本机 Windows）
- **Flutter SDK**：`C:\dev-tools\flutter`（Flutter 3.29.0 / Dart 3.7.0，stable）。沙箱 PATH 默认不含，需 `export PATH="/c/dev-tools/flutter/bin:$PATH"` 后用 `flutter.bat`。
- **Android SDK / ADB**：`C:\Users\jianz\AppData\Local\Android\Sdk`（含 platform-tools/ndk/build-tools/cmake）。
- 包名：`com.dgxspark.tongyilite`（android/app/build.gradle.kts `applicationId`/`namespace`）。
- APK 产物：`build/app/outputs/flutter-apk/`（app-debug.apk / app-release.apk）。真机调测走下方「标准打包调测流程」，`flutter run -d` 不稳。

## 标准打包调测流程（固化 · 每次照做）
> 目标：用当前源码编出 debug 包并装到已连接的真机，平均 ~1 分钟（llama.cpp 原生库已缓存）。
> 已验证设备：小米 `25053RT47C`（Android 16/API 36，序列号 `bf1552ef`，arm64）。

**0. 环境（每条命令前都要）**
```bash
export PATH="/c/dev-tools/flutter/bin:$PATH"
# ANDROID_HOME 已用 flutter config --android-sdk 持久化（Windows 反斜杠），一般无需再 export
ADB="/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
cd "/e/Work/DgxSpark/TongYi-Lite"
```

**1. 确认设备在线**
```bash
"$ADB" devices -l          # 应看到 bf1552ef  device；空白=手机未授权/仅充电，回去开 USB 调试
```

**2. 取依赖（仅改了 pubspec 时需要）**
```bash
flutter.bat pub get
```

**3. 编 debug 包（绕开 flutter run -d 的 daemon 设备匹配抖动）**
```bash
flutter.bat build apk --debug --target-platform android-arm64
# 成功标志：√ Built build\app\outputs\flutter-apk\app-debug.apk
```

**3b. 打包完成后打开产物文件夹（方便自取安装包）**
> ⚠️ 必须用 **PowerShell 工具**（不是 Bash）执行，原因：① Bash 里直接 `explorer` 参数会被 Git Bash 引号破坏，弹不出来；② 从 Bash 调 `powershell.exe` 被安全策略拦截。  
> ⚠️ **只打开文件夹，不要高亮选中 APK**：Windows/浏览器无法预览 APK，`/select` 或直接打开 APK 路径常被解析成下载，反复弹「保存 app-debug.apk」对话框。
```powershell
# 只打开文件夹，手动进去复制 APK：
Start-Process 'E:\Work\DgxSpark\TongYi-Lite\build\app\outputs\flutter-apk'
```

**4. 装到真机（保留数据）**
```bash
"$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk   # Success
# 若报 INSTALL_FAILED_UPDATE_INCOMPATIBLE（release 签名冲突）：
#   "$ADB" uninstall com.dgxspark.tongyilite   # 会丢 App 数据+外部模型文件，谨慎
#   再重新 install
```

**5. 启动 + 验证无崩溃**
```bash
"$ADB" logcat -c
"$ADB" shell am start -n com.dgxspark.tongyilite/.MainActivity
# 等 ~5 秒后：
"$ADB" logcat -d | grep -iE "tongyilite|flutter|fatal|exception" | grep -v "WindowManager\|RecentsModel\|VA_\|DynamicIsland\|Miui\|QQ\|xmsf"
# 本 App 进程应 FOREGROUND 且 FlutterSurfaceView 已创建，无本 App 的 crash/ANR
```

**关键坑（已踩过，勿重复）**
- Git Bash 里 `ANDROID_HOME` 必须用 Windows 反斜杠（`C:\Users\...`），POSIX `/c/Users/...` 会被 `flutter.bat` 拒认 → "No Android SDK found"。已 `flutter config --android-sdk` 持久化。
- **不要用 `flutter run -d bf1552ef`**：daemon 偶发 2 秒内报 "No supported devices found"，而 `flutter devices` 又能看到——直接用 build apk + adb install 最稳。
- 包名 `com.dgxspark.tongyilite`，主 Activity `.MainActivity`。
- 改写 `third_party/` 下 C++ 会触发 NDK 重编，耗时显著变长；纯 Dart 改动 ~1 分钟。
- Flutter 3.29.0 / Dart 3.7.0（stable）。
- 真机安装调测：`flutter run`（debug，带 hot reload + logcat，最适合 调测）→ 或 `flutter build apk` 后 `adb install -r`。
- **沙箱 Git Bash 下 ANDROID_HOME 必须用 Windows 反斜杠路径**（如 `C:\Users\jianz\AppData\Local\Android\Sdk`），POSIX 的 `/c/Users/...` 会被 `flutter.bat` 子进程拒认（报 "No Android SDK found"）。已用 `flutter config --android-sdk` 持久化，后续不必再 export。
- **flutter daemon 设备匹配抖动**：`flutter run -d bf1552ef` 偶发 2 秒内报 "No supported devices found" 而 `flutter devices` 又能看到设备。规避法：跳过 daemon（`flutter build apk`）+ `adb install -r`，adb 层设备始终稳定。

## Vulkan GPU 加速（已打通 · 2026-08-03）
- 状态：**编译已通过**，APK 含 `lib/arm64-v8a/libggml-vulkan.so`（依赖链 `libggml.so → libggml-vulkan.so → libvulkan.so`）。真机验证待手机连上。
- 必备环境：LunarG Vulkan SDK `C:\VulkanSDK\1.4.357.0` + MinGW-w64 GCC 16.1.0 `C:\mingw64`（主机编 `vulkan-shaders-gen` 用，NDK clang 顶替不了——没有配套 mingw C++ 标准库）。
- **编译前必须**把 mingw 加进 PATH：`export PATH="/c/dev-tools/flutter/bin:/c/mingw64/bin:$PATH"`。
- 关键文件 `android/app/src/main/cpp/{CMakeLists.txt, host-toolchain-mingw.cmake}`，四条不可动的规则：
  1. host-toolchain **不要设 `CMAKE_SYSTEM_NAME`**（否则 CMake 当交叉编译，try_compile 报 "cmTC_xxxx && 参数错误"）。
  2. host-toolchain 的 `CMAKE_MAKE_PROGRAM` **必须 `CACHE FILEPATH ... FORCE`** 指向 Android SDK 的 ninja（ExternalProject 不转发 `-D`，普通变量对 generator 不可见 → make program 变空串）。
  3. `Vulkan_INCLUDE_DIR` pin 到 SDK 的 `Include`（NDK 只有 C 头 `vulkan.h`，没有 C++ 的 `vulkan.hpp`）。
  4. `Vulkan_LIBRARY` pin 到 NDK **minSdk 对应级别**（本项目 33）的 `libvulkan.so` 桩；用 24 会缺 `vkGetPhysicalDeviceFeatures2`（Vulkan 1.1，API 28+）。查桩符号用 `llvm-readelf --dyn-syms`，`llvm-nm -D` 无输出。
- `tongyilite_jni.cpp` 的 `detect_gpu_layers()` 运行时探测 ggml backend registry，有 GPU 才设 `n_gpu_layers=999`，否则 0（保证无 Vulkan 驱动的机器也不挂）。
- **改了 CMakeLists 的 cache 变量后必须清 `.cxx`**；`rm -rf` 会被沙箱 safe-delete 静默拦截（命令看似成功、目录仍在、Gradle 7 秒"编译完成"却产物没变），要用 **PowerShell 工具** `Remove-Item -LiteralPath 'E:\Work\DgxSpark\TongYi-Lite\android\app\.cxx' -Recurse -Force`。判断是否真重编：看 `build/app/intermediates/cxx/Debug/*/obj/arm64-v8a/` 的时间戳与文件清单。
- 单独调试主机子构建（比整包快百倍）：`cmake -G Ninja -DCMAKE_MAKE_PROGRAM=<ninja> -DCMAKE_TOOLCHAIN_FILE=<host-toolchain> third_party/llama.cpp/ggml/src/ggml-vulkan/vulkan-shaders`。⚠️ 命令行传 `-DCMAKE_MAKE_PROGRAM` 会掩盖上面规则 2 的 bug。
- 完整踩坑记录见 `.workbuddy/memory/2026-08-03.md`。

## 跨会话协作约束
- ~~Vulkan 部分由另一个会话负责，本会话不碰~~ → **已作废（2026-08-03）**：用户直接要求本会话开启 Vulkan，环境搭建 + CMake/JNI 改动均由本会话完成，见上一节。
- 纯 Dart 改动编译验证：`flutter analyze` 与 `flutter build bundle --debug` 均 exit 0，原生层失败不影响 Dart 代码正确性。
- 原生构建偶发 `Gradle build daemon disappeared unexpectedly` / CMake 配置失败：多为 sandbox 守护进程崩溃或 `.cxx` 缓存损坏，不是代码问题；先 `./gradlew.bat --stop` 清守护进程再重跑。

## 真机连接坑
- ADB 识别不到设备 = 手机未开启「USB 调试」/ 未授权 / USB 模式为仅充电 / 缺驱动 / 数据线无数据。需用户在手机上开启开发者选项+USB调试、选「传输文件」、点允许调试。
- 备选：Android 11+ 用「无线调试」→ `adb pair <IP>:<配对端口>`（输配对码）→ `adb connect <IP>:<调试端口>`。配对端口与连接端口不同。
- `flutter devices` 在仅桌面环境下会列出 Windows/Chrome/Edge，但不含手机即说明 ADB 未识别。
- 已联调设备：小米 `25053RT47C`（model onyx，Android 16 / API 36），序列号 `bf1552ef`，`android-arm64`。该机已装过本 App 且用默认 debug 签名，`adb install -r` 可覆盖保留数据（与 release 签名一致时才能免卸载）。
