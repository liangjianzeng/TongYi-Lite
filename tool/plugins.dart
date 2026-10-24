// TongYi-Lite —— 插件平台命令行（P3 作者工具链）
//
// 用法（项目根）：
//   dart run tool/plugins.dart scaffold my-plugin --name 单词卡 --desc 按间隔念单词
//   dart run tool/plugins.dart validate ./plugins
//   dart run tool/plugins.dart scan --plugins-dir ./plugins --data-dir ./plugin_data
//   dart run tool/plugins.dart reset --data-dir ./plugin_data --enabled --yes
//
// 逻辑全在 `packages/plugin_kernel/lib/src/cli.dart`（纯 Dart + 注入的文件系统，
// 因此有 91 项离线测试钉着）；本文件只做两件事：给一个 dart:io 版文件系统、
// 把宿主真实能力清单传进去。**这里不许长出业务逻辑**。
//
// 退出码：0 成功 / 1 校验不合格或未确认 / 2 用法错误（CI 能分辨）。
import 'dart:io';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:tongyi_lite/plugins/host/host_capabilities.dart';

class _IoFileSystem implements PluginCliIo {
  @override
  bool exists(String path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  @override
  bool isDir(String path) => Directory(path).existsSync();

  @override
  List<String> listDir(String path) => Directory(path)
      .listSync()
      .map((e) => e.path.split('/').last)
      .toList()
    ..sort();

  @override
  String? readString(String path) {
    final f = File(path);
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  @override
  void writeString(String path, String content) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  @override
  void deleteFile(String path) => File(path).deleteSync();

  @override
  void createDir(String path) => Directory(path).createSync(recursive: true);
}

void main(List<String> args) {
  final result = PluginCli(
    _IoFileSystem(),
    const PluginCliConfig(hostCapabilityIds: kHostCapabilityIds, appVersion: kPluginHostAppVersion),
  ).run(args);
  for (final line in result.lines) {
    stdout.writeln(line);
  }
  exitCode = result.exitCode;
}
