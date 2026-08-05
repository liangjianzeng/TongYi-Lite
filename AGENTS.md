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
