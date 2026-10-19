# TongYi-Lite —— Linux / aarch64 打包机指南

> 一键入口：`tool/build_apk.sh`（自检→构建→签名验收）。本文为其背景手册；
> Windows 侧见 BUILD.md 附录 与 [BUILD_ENV_NOTES.md](BUILD_ENV_NOTES.md)。
> 已验证机器：DGX Spark `gx10-85f3`（Ubuntu 24.04，aarch64/GB10，Flutter 3.29）。

## 为什么 aarch64 Linux 编 Android 比 x86 多一堆动作

四个与项目代码无关的坑（DSH-Phone `tool/build_apk.sh` 头注释有完整事故记录）：

1. **官方构建工具只有 x86-64**：aapt2、NDK（旧版）clang 均为 x86-64 ELF。
   解法：`dpkg --add-architecture amd64` + `libc6/libstdc++6/zlib1g:amd64`（archive.ubuntu.com 源，ports 没有 amd64）。
2. **qemu-user 跑 Dart gen_snapshot 必崩**（guest 里 `mmap(NULL,-4096)` 被 qemu 误判成功）。
   解法：FEX（`ppa:fex-emu/fex`，`fex-emu-armv8.2`）。NDK clang/aapt2 用 qemu 即可。
3. **Flutter 不发 arm64 主机的 Android AOT 产物**：运行时按 hostArch 找
   `engine/android-arm64-release/linux-arm64/gen_snapshot`，官方只发 linux-x64。
   解法：`tool/build_apk.sh --fix-artifacts`（官方 linux-x64.zip + FEX 包装层，幂等）。
4. **flutter 会改写 `android/local.properties` 的 sdk.dir** 到 apt 半残 SDK
   （`/usr/lib/android-sdk` 只有 platform-tools）→ `LicenceNotAcceptedException`。
   解法：`flutter config --android-sdk ~/android-sdk` 一次性修正 +
   `build_apk.sh` 每次构建前自愈。

## Linux 特有：Vulkan 后端

LunarG **不发** linux-aarch64 SDK 包（packages.lunarg.com 404）。
`tool/setup_vulkan_sdk.sh` 从发行版原生 deb（glslc/libvulkan-dev/spirv-headers/libshaderc1，
免 root）组装出 LunarG 同布局的 `~/vulkan-sdk/`，glslc 为**原生 arm64**（连 FEX 都不需要）。
CMake 通过宿主分派自动发现（`cpp/CMakeLists.txt`）：Windows→`C:/VulkanSDK`+mingw，
Linux→`~/vulkan-sdk` 或 `$VULKAN_SDK`。缺失时自动降级 OpenCL+CPU（不阻塞构建）。

## 机器层清单（不进 git，换机必配）

| 文件 | 内容 |
|---|---|
| `~/.gradle/gradle.properties` | `org.gradle.java.home=/usr/lib/jvm/java-17-openjdk-arm64`；`jvmargs=-Xmx6g`（vLLM 常驻机慎抬）；`workers.max=8` |
| `android/local.properties` | `sdk.dir=~/android-sdk`（构建脚本自愈，IDE 写歪不影响命令行构建） |
| `android/key.jks` + `key.properties` | 正式签名（CN=TongYiLite）。备份源：Geekpro `E:\DTXY\TongYi-Lite\android\`；`tool/build_apk.sh` 尾部 apksigner 指纹验收 |
| 环境 | FEX、amd64 运行库、`~/android-sdk`（ndk 27 + cmake + licenses 已 accept：`yes \| sdkmanager --sdk_root=$HOME/android-sdk --licenses`） |

## 历史坑修复记录（评审 PR 时对照，防止回退）

- `android/gradle.properties` 曾提交 Windows 的 `org.gradle.java.home` → 已移到机器层。
- `cpp/CMakeLists.txt` 曾写死 `C:/VulkanSDK`、`host-toolchain-mingw.cmake`、
  `prebuilt/windows-x86_64` → 已宿主分派化（`host-toolchain-linux.cmake` 入库）。
- `.gitignore` 曾忽略 `android/gradle/wrapper/gradle-wrapper.jar`（主线一度不跟踪它，
  新 clone 无法跑 gradlew；手工拼 uber-jar 不可行——需 wrapper-main+wrapper-shared+cli
  三层合并，正解是 `cd android && gradle wrapper --gradle-version 8.9 --distribution-type all`
  重生成并**入库**）→ 已修，勿再忽略。
- `android/gradlew` 执行位曾丢（644）→ `git update-index --chmod=+x`。
- `flutter build apk` 直接构建时曾报 `LicenceNotAcceptedException: ndk;27.0.12077973`
  → sdk.dir 指向错误 + `sdkmanager --licenses` 未接受。

## 常用命令

```bash
tool/build_apk.sh --check          # 16+ 项自检，看缺哪层
tool/build_apk.sh                  # debug+release（AGENTS 默认策略）
tool/build_apk.sh --release --install
tool/build_apk.sh --clean-native   # 改过 cpp/ 或 third_party/llama.cpp 必用
dart tool/env_check.dart           # 跨平台统一清单
```

改 native 后的四道门验收（编译/内核/参数/基准）照 AGENTS「llama.cpp 升级门槛」执行；
Linux 侧本机可用 `build/app/intermediates/cxx/*/arm64-v8a/compile_commands.json`
核对 `-O3 -DNDEBUG -march=armv8.6-a...`。
