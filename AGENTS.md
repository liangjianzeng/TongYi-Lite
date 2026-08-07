# TongYi-Lite 项目指令 / 记忆

## 真机打包安装（重要规则，务必遵守）

> **更新安装真机时，绝不要"先卸载再装"**（`adb uninstall` + `adb install`）。
> 卸载会清掉应用数据，包括已下载的端侧模型缓存（例如 qwen3.5-4b，重新下载很费劲）。

**正确做法**：始终走**覆盖更新**，保留模型缓存：

```bash
adb install -r app-debug.apk    # -r = replace/update，不清数据
```

- 只在需要彻底清数据（换模型/出问题时）才考虑卸载，且要先告知用户模型会被清除。
- 安装被 `INSTALL_FAILED_USER_RESTRICTED` 拒绝时，加 `-t` 并请用户在设备上点允许：`adb install -r -t app-debug.apk`。

## 构建环境备忘

- 本项目是 Flutter + NDK(CMake + llama.cpp)。
- `flutter build apk --debug` 在本机 gradle 启动 `flutter.bat` 会静默失败（Windows/gradle 批处理问题）。
  **workaround**：先 `flutter assemble ... debug_android_application` 生成 kernel/assets，
  再用 `./gradlew.bat assembleDebug -x compileFlutterBuildDebug` 打包（NDK 全量编译 + 链接）。
- NDK 构建目录 `.cxx` 若被残留进程（`glslc.exe`/`vulkan-shaders-gen.exe`）锁定会报
  "Device or resource busy" / access-denied，需先终止对应进程再删 `.cxx`。
- gradle 守护进程可能持有 `.cxx` 锁导致 `buildCMakeDebug` 偶发失败：`./gradlew.bat --stop` 后重试。
- 构建/安装前先 `adb devices` 确认设备在线；设备可能因 USB 断开而消失，需等待或重连。

## APK 签名（重要记忆）

> **正确签名是 `CN=TongYiLite`（O=DGXSpark），不是临时生成的 dev keystore。**

- **签名证书**：`CN=TongYiLite, OU=Dev, O=DGXSpark, L=Wuhan, ST=Hubei, C=CN`
  SHA-256 指纹：`FB:BE:1B:6C:F8:79:AB:94:1A:65:CD:D7:A7:A8:DD:6F:5A:6B:B6:40:41:2D:E3:8C:43:CB:89:4F:08:88:69:92`
- **签名文件**：`android/key.jks` + `android/key.properties`（均被 `.gitignore` 排除，不提交远程）。
  `key.properties`：`storePassword=android` / `keyAlias=androiddebugkey` / `storeFile=../key.jks`
- **铁律**：覆盖更新安装必须保持同一签名（否则 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。构建时若发现 APK 签名不是 `CN=TongYiLite`（比如变成了临时生成的 `CN=TongYi-Lite Dev`），说明签名文件不对，需核对 `key.jks`。
- 新环境 clone 后若签名文件缺失：从源工作区拷贝，或用 `keytool -genkey -dname "CN=TongYiLite, OU=Dev, O=DGXSpark, L=Wuhan, ST=Hubei, C=CN"` 重新生成并写 `key.properties`。

## 关键教训：CMAKE_C_FLAGS_DEBUG 会被 NDK 工具链静默顶掉（CPU 内核失去 -O3 → 全模型变慢）

> **血泪教训（2026-08-07 真机定位）**：`set(CMAKE_C_FLAGS_DEBUG "-O3 -DNDEBUG")` 看似正确，但
> **Android NDK 工具链会在 Debug 配置重新套上自己的 `-g`，静默覆盖该变量**，导致 `-O3 -DNDEBUG` 根本没生效。
> 表现：**所有模型同等降速**（0.8B 1.2 tok/s、2.7B ~1.2），效果像"最早没做 KleidiAI"——因为量化 matmul
> 内核以默认 `-O0` 编译。此时 KleidiAI 内核虽编进去了（`-march` 有），但没优化级别等于没加速。

**验证铁证**：看 `.cxx/.../compile_commands.json`，若 ggml-cpu/kleidiai 源文件只有 `-march` 而**无 `-O3`、无 `-DNDEBUG`**，即中招。

**正确做法**：改用 NDK 覆盖不了的目录级选项（会传给 llama/ggml-cpu/kleidiai/mtmd 所有子目录目标）：
```cmake
add_compile_options(-O3)
add_compile_definitions(NDEBUG)
```
改 CMake 后必须**清 `.cxx` 全量重建**，并核对 compile_commands 同时含 `-O3 -DNDEBUG -march` 才算生效。

## 关键教训：flutter assemble 输出路径 ≠ gradle 读取路径（Dart 改动"装不进"APK）

> **血泪教训**：改了 Dart 代码后，光 `flutter assemble` + `gradlew assembleDebug -x compileFlutterBuildDebug`，
> 装出来的 APK **可能仍是旧代码**——因为两个工具读写的 kernel 路径不一致：
>
> - `flutter assemble -o build/flutter-assemble ...` 把最新 kernel 写到
>   `build/flutter-assemble/flutter_assets/kernel_blob.bin`；
> - 但 gradle 打包时用的是 **`build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin`**（旧拷贝），
>   `-x compileFlutterBuildDebug` 跳过了 flutter 编译，**不会自动刷新这个路径**。
>
> 结果：UI 改了半天，装上去界面毫无变化，还以为代码没写对——实际是打包了旧 Dart。
>
> **正确做法（每次 Dart 改动后必须做）**：
> ```bash
> flutter assemble -o build/flutter-assemble --define=BuildMode=debug --define=TargetPlatform=android-arm64 debug_android_application
> cp -r build/flutter-assemble/flutter_assets/* build/app/intermediates/flutter/debug/flutter_assets/
> cd android && gradlew.bat assembleDebug -x compileFlutterBuildDebug
> ```
> 即：**先把最新 flutter_assets 同步覆盖到 gradle 的 intermediates/flutter/debug，再打包**。
> 可用 `ls -la build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin` 确认大小/时间已更新。

## 关键教训：MTP 是全局开关会"点一个全开全关"

> MTP 开关最初做成全局一个 `bool enableMtp`，用户点某个模型开关，**所有模型一起变**。
> 应改成**按模型 id 的 `Map<String, bool>`**（`mtpEnabledByModel`），每个模型独立持久化，
> 加载时用 `gpu.mtpEnabled(modelId)` 取当前模型自己的开关。迁移旧配置时全局 bool 不迁移为开（保持默认关）。

## 真机调试注意

- 屏幕休眠（`mWakefulness=Dozing`）时 `uiautomator dump` 返回**空节点**，易误判"UI 没渲染"。
  先 `input keyevent KEYCODE_WAKEUP` + `KEYCODE_MENU` 唤醒，再 dump 验证界面。
- Flutter 的 `Switch` 在 uiautomator 里可能不显示为 `android.widget.Switch` 类（可能显示为带
  `checked` 属性的普通 View），别只看 class 名判断开关是否存在。

## 重要：当前模型不支持视觉理解（调试禁用"看图片/截图"）

> **用户不主动喂图；当前驱动模型不支持视觉，无法真正"看"图片/截图。**
> 一旦任务流程里出现"查看截图/图片"这类依赖视觉的步骤，模型会拿不到任何图像内容，
> 任务会**彻底僵死**（卡在等图、误判界面等死循环）。

**铁律**：
- 调试/验证一律走**文本通道**：`uiautomator dump` 的 XML 文本、`adb logcat`、`dumpsys`、
  文件内容（`cat`/`Read`）等——**绝不依赖截图判读**。
- 不主动生成、不主动查看 `screen.png` 之类的截图产物；即便存在也不把图像内容当真。
- 判断 UI 状态只看文本节点/属性（`text`、`content-desc`、`checked`、`bounds`），
  不要写"打开截图确认一下"这种步骤。
