/// 文件类工具 —— 对齐 DSH 的 read/write/edit/glob/grep，作用域为应用沙盒
/// `documents/workspace`（模型可读写的工作目录），路径规范化防逃逸。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../tool_definition.dart';

/// 单次读文件的最大字节（保护上下文预算）。
const int kReadFileLimit = 8192;

/// 单次写入的最大字节。
const int kWriteFileLimit = 65536;

/// 搜索结果的单文件最大匹配数。
const int kGrepPerFileLimit = 20;

/// 解析沙盒工作目录路径（惰性缓存）。
Future<Directory> _workspaceDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'workspace'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// 规范化路径并确保落在沙盒内（防 `../` 逃逸）。
Future<String> _resolveSafePath(String rawPath) async {
  final workspace = await _workspaceDir();
  final resolved = p.normalize(p.join(workspace.path, rawPath));
  final workspaceNorm = p.normalize(workspace.path);
  if (!p.equals(resolved, workspaceNorm) &&
      !resolved.startsWith('$workspaceNorm${p.separator}')) {
    throw ArgumentError('路径越界：$rawPath（仅允许 workspace 内）');
  }
  return resolved;
}

/// 读文件：返回内容（截断到 [kReadFileLimit]）。
ToolDefinition createReadFileTool() {
  return ToolDefinition(
    name: 'read_file',
    description:
        '读取工作区内文本文件内容。path 为相对 workspace 的路径（如 "notes/draft.txt"）。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对 workspace 的文件路径'},
      },
      'required': ['path'],
    },
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      try {
        final path = await _resolveSafePath(rawPath);
        final file = File(path);
        if (!await file.exists()) return ToolResult.error('文件不存在：$rawPath');
        final len = await file.length();
        if (len > kReadFileLimit * 2) {
          return ToolResult.error('文件过大（${len ~/ 1024}KB），仅支持读取前 ${kReadFileLimit ~/ 1024}KB');
        }
        final content = await file.readAsString();
        return ToolResult(
          content: content.length <= kReadFileLimit
              ? content
              : '${content.substring(0, kReadFileLimit)}\n…（已截断）',
        );
      } catch (e) {
        return ToolResult.error('读取失败：$e');
      }
    },
  );
}

/// 写文件：覆盖写入（目录自动创建）。
ToolDefinition createWriteFileTool() {
  return ToolDefinition(
    name: 'write_file',
    description: '覆盖写入文本到工作区文件（目录自动创建）。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对 workspace 的文件路径'},
        'content': {'type': 'string', 'description': '完整文件内容'},
      },
      'required': ['path', 'content'],
    },
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      final content = (args['content'] as String?) ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      if (content.isEmpty) return ToolResult.error('content 为空');
      if (content.length > kWriteFileLimit) {
        return ToolResult.error('内容过大（>${kWriteFileLimit ~/ 1024}KB）');
      }
      try {
        final path = await _resolveSafePath(rawPath);
        await File(path).parent.create(recursive: true);
        await File(path).writeAsString(content, flush: true);
        return ToolResult(content: '已写入 $rawPath（${content.length} 字符）');
      } catch (e) {
        return ToolResult.error('写入失败：$e');
      }
    },
  );
}

/// 编辑文件：替换 oldString → newString（oldString 必须唯一）。
ToolDefinition createEditFileTool() {
  return ToolDefinition(
    name: 'edit_file',
    description:
        '替换工作区文件中的文本（oldString 必须唯一，出现多次会报错）。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对 workspace 的文件路径'},
        'oldString': {'type': 'string', 'description': '被替换的原文'},
        'newString': {'type': 'string', 'description': '替换后的文本'},
      },
      'required': ['path', 'oldString', 'newString'],
    },
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      final oldString = (args['oldString'] as String?) ?? '';
      final newString = (args['newString'] as String?) ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      if (oldString.isEmpty) return ToolResult.error('oldString 为空');
      try {
        final path = await _resolveSafePath(rawPath);
        final file = File(path);
        if (!await file.exists()) return ToolResult.error('文件不存在：$rawPath');
        final content = await file.readAsString();
        final count = _countOccurrences(content, oldString);
        if (count == 0) return ToolResult.error('未找到要替换的文本');
        if (count > 1) {
          return ToolResult.error('oldString 出现 $count 次，需提供更长的上下文');
        }
        final updated = content.replaceFirst(oldString, newString);
        await file.writeAsString(updated, flush: true);
        return ToolResult(content: '已替换 1 处（${updated.length} 字符）');
      } catch (e) {
        return ToolResult.error('编辑失败：$e');
      }
    },
  );
}

/// 列出文件：递归 glob（对齐 DSH glob）。
ToolDefinition createListFilesTool() {
  return ToolDefinition(
    name: 'list_files',
    description:
        '列出工作区文件。pattern 为 glob（如 "**/*.txt"），缺省列出全部。',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string', 'description': 'glob 模式'},
      },
    },
    execute: (args) async {
      try {
        final workspace = await _workspaceDir();
        final files = <String>[];
        await for (final entity in workspace.list(recursive: true)) {
          if (entity is File) {
            files.add(p.relative(entity.path, from: workspace.path));
          }
        }
        files.sort();
        final pattern = (args['pattern'] as String?)?.trim() ?? '';
        var matches = files;
        if (pattern.isNotEmpty) {
          matches = files.where(_matchesGlob(pattern)).toList();
        }
        if (matches.isEmpty) return ToolResult(content: '无匹配文件');
        final limited = matches.take(100).toList();
        return ToolResult(
          content: '共 ${matches.length} 个文件${matches.length > 100 ? '（仅显示前 100）' : ''}：\n'
              '${limited.join('\n')}',
        );
      } catch (e) {
        return ToolResult.error('列出失败：$e');
      }
    },
  );
}

/// 搜索内容：递归 grep（对齐 DSH grep）。
ToolDefinition createSearchTextTool() {
  return ToolDefinition(
    name: 'search_text',
    description:
        '在工作区文件内容中搜索正则 pattern（如 "TODO|bug"），返回文件名:行号:行。',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string', 'description': '正则表达式'},
      },
      'required': ['pattern'],
    },
    execute: (args) async {
      final pattern = (args['pattern'] as String?)?.trim() ?? '';
      if (pattern.isEmpty) return ToolResult.error('缺少 pattern 参数');
      try {
        final re = RegExp(pattern);
        final workspace = await _workspaceDir();
        final hits = <String>[];
        await for (final entity in workspace.list(recursive: true)) {
          if (entity is! File) continue;
          if (!(await _isTextFile(entity))) continue;
          try {
            final lines = await entity.readAsLines();
            var matched = 0;
            for (var i = 0; i < lines.length && matched < kGrepPerFileLimit; i++) {
              if (re.hasMatch(lines[i])) {
                final rel = p.relative(entity.path, from: workspace.path);
                hits.add('$rel:${i + 1}:${lines[i].length > 120 ? lines[i].substring(0, 117) + '…' : lines[i]}');
                matched++;
              }
            }
          } catch (_) {
            // 跳过无法读取的文件
          }
        }
        if (hits.isEmpty) return ToolResult(content: '无匹配');
        return ToolResult(content: hits.take(40).join('\n'));
      } catch (e) {
        return ToolResult.error('搜索失败：$e');
      }
    },
  );
}

/// 判断是否为文本文件（跳过二进制）。
Future<bool> _isTextFile(File file) async {
  final raf = await file.open();
  try {
    final bytes = await raf.read(2048);
    // 含 NUL 字节视为二进制。
    return !bytes.contains(0);
  } catch (_) {
    return false;
  } finally {
    await raf.close();
  }
}

int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var idx = 0;
  while ((idx = haystack.indexOf(needle, idx)) >= 0) {
    count++;
    idx += needle.length;
  }
  return count;
}

/// 简单 glob → 正则（支持 *、?、**）。
bool Function(String) _matchesGlob(String pattern) {
  final normalized = pattern.replaceAll(r'\', '/');
  final parts = normalized.split('/');
  final regex = StringBuffer('^');
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (part == '**') {
      regex.write('(?:.*/)?');
    } else {
      regex.write(RegExp.escape(part)
          .replaceAll(r'\*', '[^/]*')
          .replaceAll(r'\?', '[^/]'));
    }
    if (i < parts.length - 1) regex.write('/');
  }
  regex.write(r'$');
  return (path) => RegExp(regex.toString()).hasMatch(path);
}
