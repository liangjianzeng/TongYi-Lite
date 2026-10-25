// 环境自检：验证当前终端里 Dart 能否创建子进程。
//
// 背景：WorkBuddy 助手沙箱会拦掉 Dart 的 CreateProcess（报
// "CreateFile failed 231" / ERROR_PIPE_BUSY），导致 flutter/dart analyze、
// flutter test、flutter build 全部起不来。你在自己的 cmd/PowerShell 里
// 运行应当输出 DART_SPAWN_OK；若这里也失败，说明是机器级问题，先修环境再构建。
import 'dart:io';

void main() {
  try {
    final r = Process.runSync('cmd', ['/c', 'echo', 'probe']);
    if (r.exitCode == 0) {
      print('DART_SPAWN_OK');
      return;
    }
    print('DART_SPAWN_FAIL exit=${r.exitCode}');
  } catch (e) {
    print('DART_SPAWN_FAIL $e');
  }
  exitCode = 1;
}
