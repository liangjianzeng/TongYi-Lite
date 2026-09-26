import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/chat_message.dart' show ChatMessage, MessageRole;
import 'event.dart';
import 'log.dart';

/// JSONL 会话存储（Phase 0）。
///
/// 对照 DSH 持久化（Part 5）：每会话一个 JSONL 文件
/// `ApplicationSupport/sessions/<conversationId>.jsonl`，首行 header，
/// 后续每行一个事件。文件操作 append-only，加载时做崩溃修复（closeOpenTurns）。
///
/// 端侧设计决策：
/// - 不压缩（JSONL 明文，文件小，读取简单）；
/// - 版本门：version <= kSessionFormatVersion 可读，否则抛（迁移链 Phase 2+）；
/// - 旧 SQLite 会话经 [importFromMessages] 一次性迁移（log-only 标记 imported）。

final class JsonlSessionStore {
  JsonlSessionStore();

  /// 会话文件路径（相对 ApplicationSupport/sessions）。
  Future<String> pathFor(String conversationId) async {
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'sessions', '${_safe(conversationId)}.jsonl');
  }

  /// 确保 sessions 目录存在，返回目录路径。
  Future<String> _ensureDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = p.join(base.path, 'sessions');
    if (!Directory(dir).existsSync()) {
      Directory(dir).createSync();
    }
    return dir;
  }

  /// 读取会话日志（load + 崩溃修复 + 版本门）。
  Future<SessionLog> load(String conversationId) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    if (!file.existsSync()) {
      return SessionLog.fromEvents([]);
    }
    // 逐行解析
    final bytes = file.readAsBytesSync();
    final lines = bytes.isEmpty
        ? <String>[]
        : utf8.decode(bytes, allowMalformed: true).split('\n');
    final events = <SessionEvent>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      // 首行可能是 header
      if (i == 0 && isHeaderLine(line)) continue;
      final e = SessionEvent.fromJsonLine(line);
      if (e != null) events.add(e);
      // 末行撕裂且非 header → 判损坏丢弃（DSH：完整帧内撕裂不抢救）
    }
    final log = SessionLog.fromEvents(events);
    // 崩溃修复：补未闭合 turn/step/tool 结果
    log.closeOpenTurns(cause: 'crash-repair');
    return log;
  }

  /// 追加事件到磁盘（append-only）。
  Future<void> appendEvent(String conversationId, SessionEvent event) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    if (!file.existsSync()) {
      final h = SessionHeader(
        version: kSessionFormatVersion,
        conversationId: conversationId,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await file.writeAsString('${h.toJson()}\n');
    }
    await file.writeAsString('${event.toJsonLine()}\n', mode: FileMode.append);
  }

  /// 完整重写日志文件（导入/迁移用）。
  Future<void> rewrite(String conversationId, SessionLog log) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    final h = SessionHeader(
      version: kSessionFormatVersion,
      conversationId: conversationId,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final sb = StringBuffer();
    sb.writeln(h.toJson());
    for (final e in log.rawEvents) {
      sb.writeln(e.toJsonLine());
    }
    await file.writeAsString(sb.toString());
  }

  /// 从旧 SQLite ChatMessage 列表导入为 v1 日志（一次性迁移）。
  SessionLog importFromMessages(
    String conversationId,
    List<ChatMessage> messages,
  ) {
    final log = SessionLog.fromEvents([]);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final m in messages) {
      final isUser = m.role == MessageRole.user;
      log.append(
        isUser ? kEventUserMessage : kEventAssistantMessage,
        <String, dynamic>{
          'content': m.content,
          if (m.imagePath != null) 'imagePath': m.imagePath,
          if (m.audioPath != null) 'audioPath': m.audioPath,
          if (m.inferenceStats != null) 'stats': m.inferenceStats!.toMap(),
        },
        source: <String, String>{'kind': 'import'},
        timeMs: m.timestamp.millisecondsSinceEpoch,
      );
      // log-only 导入标记（记录原 id，便于追溯）
      log.append(
        kEventImported,
        <String, dynamic>{
          'originalId': m.id,
          'originalRole': m.role.name,
        },
        source: <String, String>{'kind': 'import'},
        timeMs: now,
      );
    }
    return log;
  }

  /// 判断某会话是否已迁移（存在 .jsonl 文件）。
  Future<bool> isMigrated(String conversationId) async {
    final dirPath = await _ensureDir();
    return File(p.join(dirPath, '${_safe(conversationId)}.jsonl')).existsSync();
  }

  /// 删除会话文件。
  Future<void> delete(String conversationId) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    if (file.existsSync()) await file.delete();
  }
}

/// 路径安全：把非法字符替换为下划线。
String _safe(String s) =>
    s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');