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
