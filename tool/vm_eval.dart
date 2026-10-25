// vm_eval.dart — 通过 Dart VM service 在真机 App 里求值表达式（调试包专用）。
// 用法：dart tool/vm_eval.dart <ws-url> "<expression>"
// ws-url 形如 ws://127.0.0.1:PORT/AUTHTOKEN/ws（adb forward 后的地址）。
// 表达式在 package:tongyi_lite/services/inference_service.dart 库上下文里求值，
// 可直接用 InferenceService() 单例调 loadModel/benchmark 等。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart vm_eval.dart <ws-url> "<expression>"');
    exit(2);
  }
  final url = args[0];
  final expr = args[1];
  final ws = await WebSocket.connect(url);
  final completer = Completer<Map<String, dynamic>>();
  var id = 0;
  final pending = <int, Completer<Map<String, dynamic>>>{};

  late StreamSubscription sub;
  sub = ws.listen((data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    if (msg.containsKey('id')) {
      final c = pending.remove(msg['id']);
      c?.complete(msg);
    }
  }, onDone: () {
    if (!completer.isCompleted) completer.complete({'error': 'ws closed'});
  });

  Future<Map<String, dynamic>> rpc(String method, Map<String, dynamic> params) {
    final myId = ++id;
    final c = Completer<Map<String, dynamic>>();
    pending[myId] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': myId, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(seconds: 180));
  }

  try {
    final vm = await rpc('getVM', {});
    final isolates = (vm['result']['isolates'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic>? mainIso;
    for (final iso in isolates) {
      final detail = await rpc('getIsolate', {'isolateId': iso['id']});
      final r = detail['result'];
      if (r['isolateGroupId'] != null || (r['name'] as String?) == 'main') {
        // main isolate 通常名为 main；其余是 worker（ASR 等）。
        if ((r['name'] as String? ?? '') == 'main') mainIso = r;
      }
    }
    mainIso ??= isolates.first;
    final isoId = mainIso['id'];
    stdout.writeln('isolate: $isoId (${mainIso['name']})');

    // 列 libraries 找 inference_service.dart（可能要等 app 完成启动）。
    Map<String, dynamic>? lib;
    for (var attempt = 0; attempt < 10 && lib == null; attempt++) {
      final detail = await rpc('getIsolate', {'isolateId': isoId});
      final libs = (detail['result']['libraries'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final l in libs) {
        if ((l['uri'] as String? ?? '').endsWith('inference_service.dart')) {
          lib = l;
          break;
        }
      }
      if (lib == null) await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (lib == null) {
      stdout.writeln('LIB_NOT_FOUND');
      exit(1);
    }
    stdout.writeln('lib: ${lib!['uri']}');

    final ev = await rpc('evaluate', {'isolateId': isoId, 'targetId': lib!['id'], 'expression': expr});
    if (ev.containsKey('error')) {
      stdout.writeln('EVAL_ERROR: ${jsonEncode(ev['error'])}');
    } else {
      final r = ev['result'] as Map<String, dynamic>;
      stdout.writeln('RESULT: ${r['type']} ${r['valueAsString'] ?? r['id'] ?? ''}');
    }
  } finally {
    await sub.cancel();
    await ws.close();
  }
  exit(0);
}
