// TongYi-Lite —— 双平台共享构建环境自检清单（Windows/Linux 同一口径）
//
// 供人工/CI 快速回答"这台机器能不能出包、缺哪一层"。tool/build_apk.sh 与
// tool/build_apk.ps1 内嵌了各自的深度自检（含平台专属坑），本脚本负责
// 跨平台一致的基础层检查，输出退出码：0=可构建，1=有阻塞项。
//
// 用法（项目根）：
//   flutter pub global activate --source path .   （可选注册）
//   dart tool/env_check.dart
//
// 配置三层模型（见 docs/BUILD.md）：
//   项目层（git）    ：gradle.properties / CMakeLists —— 必须平台无关
//   机器层（不进git）：~/.gradle/gradle.properties、android/local.properties、key.*
//   环境层（脚本注入）：JAVA_HOME / ANDROID_HOME / VULKAN_SDK / CMAKE_BUILD_PARALLEL_LEVEL
import 'dart:io';

const expectedCertFp = 'fbbe1b6cf879ab941a65cdd7a7a8dd6f5a6bb640412de38c43cb894f08886992';

void main(List<String> args) {
  final root = Directory.current.path;
  var fail = 0;
  var warn = 0;
  void ok(String m) => print('  ✓ $m');
  void bad(String m) { print('  ✗ $m'); fail++; }
  void miss(String m) { print('  ! $m'); warn++; }
  bool has(String p) => File(p).existsSync() || Directory(p).existsSync();
  String? first(List<String?> c) { for (final p in c) { if (p != null && p.isNotEmpty && has(p)) return p; } return null; }

  print('== TongYi-Lite 构建环境检查（${Platform.operatingSystem} ${_arch()}）');

  // --- Flutter ---
  final flutter = first([
    Platform.environment['FLUTTER_BIN'],
    if (Platform.isWindows) r'C:\src\flutter\bin\flutter.bat',
    if (Platform.isWindows) r'C:\dev-tools\flutter\bin\flutter.bat',
    '${home ?? ''}/flutter/bin/flutter',
    '/opt/flutter/bin/flutter',
  ]);
  flutter != null ? ok('flutter $flutter') : bad('flutter 未找到（FLUTTER_BIN / 安装到默认位置）');

  // --- Android SDK（必须含 platforms+build-tools，防 apt 半残版）---
  final sdk = first([
    Platform.environment['ANDROID_HOME'],
    Platform.environment['ANDROID_SDK_ROOT'],
    '${home ?? ''}/android-sdk',
    Platform.environment['LOCALAPPDATA'] == null
        ? null
        : '${Platform.environment['LOCALAPPDATA']}/Android/Sdk',
    '/opt/android-sdk',
  ]);
  if (sdk != null && has('$sdk/platforms') && has('$sdk/build-tools')) {
    ok('Android SDK $sdk');
  } else if (sdk != null) {
    bad('Android SDK $sdk 缺 platforms/build-tools（多半是 apt 半残版）');
  } else {
    bad('Android SDK 未找到（ANDROID_HOME）');
  }

  // --- JDK 17（AGP 要求，别用系统默认新版本）---
  final jdk = first([
    Platform.environment['JAVA_HOME'],
    if (Platform.isLinux) '/usr/lib/jvm/java-17-openjdk-${_arch()}',
    if (Platform.isWindows)
      Directory(r'C:\Program Files\Eclipse Adoptium')
          .existsSync()
          ? (Directory(r'C:\Program Files\Eclipse Adoptium')
              .listSync()
              .whereType<Directory>()
              .where((d) => d.path.contains('jdk-17'))
              .map((d) => d.path)
              .firstOrNull)
          : null,
  ]);
  jdk != null ? ok('JDK 17 候选 $jdk（构建脚本会校验版本）') : bad('JDK 17 未找到');

  // --- 机器层 gradle 配置（项目层已去机器化，缺这里会用错 JDK/默认堆）---
  final machineGradleProps =
      '${home ?? ''}${Platform.isWindows ? r'\.gradle\gradle.properties' : '/.gradle/gradle.properties'}';
  if (File(machineGradleProps).existsSync() &&
      File(machineGradleProps).readAsStringSync().contains('org.gradle.java.home')) {
    ok('机器层 $machineGradleProps');
  } else {
    miss('缺机器层 gradle.properties（$machineGradleProps：java.home/jvmargs/workers）');
  }

  // --- 项目层完整性（git 应带）---
  has('$root/android/gradle/wrapper/gradle-wrapper.jar')
      ? ok('gradle-wrapper.jar')
      : bad('缺 gradle-wrapper.jar（应入库；重生成后 git add）');
  if (!Platform.isWindows) {
    final ga = File('$root/android/gradlew');
    (ga.existsSync() && (ga.statSync().mode & 0x40) != 0)
        ? ok('gradlew 可执行位')
        : miss('gradlew 缺执行位（chmod +x 且 git update-index --chmod=+x）');
  }

  // --- 签名（release 硬要求）---
  if (has('$root/android/key.properties') && has('$root/android/key.jks')) {
    ok('签名文件（正式证书指纹 $expectedCertFp 前8位=${expectedCertFp.substring(0, 8)}，构建后 apksigner 验收）');
  } else {
    miss('缺 android/key.jks|key.properties → release 回退 debug 签名，无法覆盖安装正式版');
  }

  // --- native 后端 ---
  has('$root/android/app/src/main/cpp/host-toolchain-mingw.cmake')
      ? ok('host-toolchain-mingw.cmake（Windows 宿主 Vulkan）')
      : bad('缺 host-toolchain-mingw.cmake');
  if (Platform.isLinux) {
    has('${home ?? ''}/vulkan-sdk/Bin/glslc') || has('${Platform.environment['VULKAN_SDK'] ?? ''}/Bin/glslc')
        ? ok('Linux Vulkan SDK（ggml-vulkan 启用）')
        : miss('无 Linux Vulkan SDK → 只有 OpenCL+CPU（跑 tool/setup_vulkan_sdk.sh）');
  }
  if (Platform.isWindows) {
    (has(r'C:\VulkanSDK') && has(r'C:\mingw64\bin\g++.exe'))
        ? ok('Windows Vulkan：LunarG SDK + MinGW-w64')
        : miss('Windows 无 C:\\VulkanSDK 或 C:\\mingw64 → 只有 OpenCL+CPU');
  }

  print(fail == 0
      ? '\n通过（$warn 项提示）。可运行 tool/build_apk${Platform.isWindows ? '.ps1' : '.sh'}'
      : '\n$fail 项阻塞，先修复。');
  exit(fail == 0 ? 0 : 1);
}

String? get home =>
    Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
String _arch() {
  if (!Platform.isLinux) return Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'x86_64';
  return Process.runSync('uname', ['-m']).stdout.toString().trim();
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
