/// 版本号一致性锁（2026-11-09 发版事故复盘而加）。
///
/// 事故：本仓的版本号有 4 处真相源各自飘——
/// - `android/app/build.gradle.kts` 硬编 `versionCode = 31 / versionName = "0.3.8"`，
///   构建期把 pubspec 的 `0.3.9+32` **整个盖掉**（已入库的 TongYi-Lite-v0.3.9.apk
///   `aapt dump badging` 自报 0.3.8/31，README 写的「v0.3.9+32」是假标签）；
/// - About 页 `_appVersion` 停在 0.3.7（连飘两个版本没人动）；
/// - 插件宿主握手 `kPluginHostAppVersion` 停在 0.2.8（插件侧 minAppVersion
///   判定一直拿 7 个版本前的旧号比）。
///
/// 现在的口径：**pubspec.yaml 的 `version:` 是唯一真源**，gradle 构建期读
/// `flutter.versionName` / `flutter.versionCode`（Flutter 由 pubspec 注入）。
/// Dart 侧因离线沙箱拿不到 package_info_plus，只能留常量——留常量就必须有人
/// 钉住，钉住它的就是本测试：改版本号时漏掉任何一处，这里直接红。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 仓库根目录下的文件（`flutter test` 的工作目录即包根）。
String _read(String rel) => File(rel).readAsStringSync();

const String _semver = r'\d+\.\d+\.\d+';

void main() {
  group('版本号单一真源（pubspec 为准）', () {
    late String version;
    late int versionCode;

    setUp(() {
      // 注：raw 串不插值——模式里的 semver 必须写成字面量（"$xxx" 在 r'' 里
      // 是字面字符），行尾锚写 $ 而非 \$。
      final m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
              multiLine: true)
          .firstMatch(_read('pubspec.yaml'));
      expect(m, isNotNull,
          reason: 'pubspec.yaml 的 version 必须是 "X.Y.Z+N" 形状'
              '（发版号在此声明，其余各处由本测试对齐到它）');
      version = m!.group(1)!;
      versionCode = int.parse(m.group(2)!);
    });

    test('About 页显示版本 == pubspec version', () {
      final src = _read('lib/screens/settings/about.dart');
      final m =
          RegExp("const _appVersion = '($_semver)';").firstMatch(src);
      expect(m, isNotNull, reason: 'about.dart 的 _appVersion 常量形态走样');
      expect(m!.group(1), version,
          reason: 'About 页停在 v${m.group(1)}，包真身是 v$version——'
              '用户看到的版本与安装器/dumpsys 不一致');
    });

    test('插件宿主上报版本 == pubspec version', () {
      final src = _read('lib/plugins/host/host_capabilities.dart');
      final m = RegExp("const String kPluginHostAppVersion = '($_semver)';")
          .firstMatch(src);
      expect(m, isNotNull,
          reason: 'host_capabilities.dart 的 kPluginHostAppVersion 形态走样');
      expect(m!.group(1), version,
          reason: '插件宿主向插件上报 v${m.group(1)}，真身是 v$version——'
              '插件的 minAppVersion 门会按旧号判定');
    });

    test('gradle 版本由 pubspec 派生，不得再硬编', () {
      final gradle = _read('android/app/build.gradle.kts');
      expect(gradle, contains('versionCode = flutter.versionCode'),
          reason: 'gradle 必须取构建期注入的 flutter.versionCode；'
              '硬编数字会盖掉 pubspec 的号（2026-11-09 事故根因）');
      expect(gradle, contains('versionName = flutter.versionName'),
          reason: '同上：versionName 也必须派生自 pubspec');
      expect(
          RegExp(r'^\s*versionCode\s*=\s*\d+\s*$', multiLine: true)
              .hasMatch(gradle),
          isFalse,
          reason: 'gradle 里出现了硬编 versionCode 数字');
      expect(RegExp(r'^\s*versionName\s*=\s*"', multiLine: true).hasMatch(gradle),
          isFalse,
          reason: 'gradle 里出现了硬编 versionName 字符串');
      // versionCode 必须是个正数（派生值为 0 通常意味着 pubspec 号形走样）。
      expect(versionCode, greaterThan(0));
    });

    test('README 徽章与 CHANGELOG 最新节跟随 pubspec version', () {
      expect(_read('README.md'), contains('![v$version]('),
          reason: 'README 顶部徽章没更到 v$version（用户第一眼看的号）');
      final changelog = _read('CHANGELOG.md');
      final sections = RegExp(r'^## \[(\d+\.\d+\.\d+)\]', multiLine: true)
          .allMatches(changelog)
          .map((e) => e.group(1)!)
          .toList();
      expect(sections, isNotEmpty, reason: 'CHANGELOG 找不到任何版本节');
      expect(sections.first, version,
          reason: 'CHANGELOG 最新节是 ${sections.first}，发版应是 v$version');
    });
  });
}
