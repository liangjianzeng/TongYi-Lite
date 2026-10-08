import 'dart:convert';

enum MessageRole { user, assistant }

/// 解析消息 role：未知值（历史脏数据、将来新增的 role 如 system）回落为
/// user。此前多处用 `.first` 直接反序列化——一条脏消息就能让整个会话
/// 列表/消息读取抛 StateError 崩溃。
MessageRole messageRoleFromName(Object? name) {
  if (name == MessageRole.assistant.name) return MessageRole.assistant;
  return MessageRole.user;
}

/// 单次回复的性能统计（仅 assistant 消息有）。
class InferenceStats {
  final int firstTokenMs; // 首 token 延迟（发送到首个 token 的时间）
  final int totalMs;      // 总耗时
  final double tokPerSec; // 生成速率（token/秒）
  final int visionMs;     // 视觉编码耗时（仅视觉回复 >0）
  final int audioMs;      // 听音时间（音频编码耗时，仅语音回复 >0）

  const InferenceStats({
    required this.firstTokenMs,
    required this.totalMs,
    required this.tokPerSec,
    this.visionMs = 0,
    this.audioMs = 0,
  });

  Map<String, dynamic> toMap() => {
        'firstTokenMs': firstTokenMs,
        'totalMs': totalMs,
        'tokPerSec': tokPerSec,
        'visionMs': visionMs,
        'audioMs': audioMs,
      };

  factory InferenceStats.fromMap(Map<String, dynamic> map) => InferenceStats(
        firstTokenMs: (map['firstTokenMs'] as num?)?.toInt() ?? 0,
        totalMs: (map['totalMs'] as num?)?.toInt() ?? 0,
        tokPerSec: (map['tokPerSec'] as num?)?.toDouble() ?? 0,
        visionMs: (map['visionMs'] as num?)?.toInt() ?? 0,
        audioMs: (map['audioMs'] as num?)?.toInt() ?? 0,
      );
}

class ChatMessage {
  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final String? imagePath;

  /// 多图（WP 多图上传，≤10；[imagePath] 恒等于首张，兼容旧链路）。
  /// **用户视图**：UI（输入区预览/气泡/大图）永远展示这里的原图。
  final List<String>? imagePaths;

  /// **模型视图**（长图切块/缩放后的路径序列；null = 与 [imagePaths] 相同）。
  /// 切块是后端为视觉模型准备的输入细节，用户不应看到碎片——只有发给
  /// 模型（本地 JNI / API buildMessages / 智能体 kick）时才消费本字段。
  final List<String>? visionPaths;

  /// 智能体附件文件名列表（≤5；本体在 documents/uploads/<convId>/）。
  final List<String>? attachments;
  final String? audioPath;
  final DateTime timestamp;
  final bool isStreaming;
  final InferenceStats? inferenceStats;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.imagePath,
    List<String>? imagePaths,
    List<String>? visionPaths,
    this.attachments,
    this.audioPath,
    DateTime? timestamp,
    this.isStreaming = false,
    this.inferenceStats,
  })  : imagePaths = (imagePaths != null && imagePaths.isNotEmpty)
            ? imagePaths
            : (imagePath != null ? [imagePath] : null),
        visionPaths = (visionPaths != null && visionPaths.isNotEmpty)
            ? visionPaths
            : null,
        timestamp = timestamp ?? DateTime.now();

  /// 模型侧取图入口：有切块序列用切块，否则用原图。UI 展示禁用本 getter。
  List<String>? get modelImagePaths =>
      (visionPaths != null && visionPaths!.isNotEmpty) ? visionPaths : imagePaths;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role.name,
      'content': content,
      'imagePath': imagePath,
      'imagePaths': imagePaths == null
          ? null
          : jsonEncode(imagePaths),
      'visionPaths': visionPaths == null
          ? null
          : jsonEncode(visionPaths),
      'attachments':
          attachments == null ? null : jsonEncode(attachments),
      'audioPath': audioPath,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isStreaming': isStreaming ? 1 : 0,
      'inferenceStats': inferenceStats?.toMap(),
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    final stats = map['inferenceStats'];
    List<String>? _decodeList(Object? raw) {
      if (raw is! String || raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List && decoded.isNotEmpty) {
          return decoded.map((e) => '$e').toList();
        }
      } catch (_) {}
      return null;
    }

    return ChatMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      role: messageRoleFromName(map['role']),
      content: map['content'] as String,
      imagePath: map['imagePath'] as String?,
      imagePaths: _decodeList(map['imagePaths']),
      visionPaths: _decodeList(map['visionPaths']),
      attachments: _decodeList(map['attachments']),
      audioPath: map['audioPath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      isStreaming: (map['isStreaming'] as int?) == 1,
      inferenceStats: stats is Map<String, dynamic> ? InferenceStats.fromMap(stats) : null,
    );
  }

  ChatMessage copyWith({
    String? content,
    bool? isStreaming,
    InferenceStats? inferenceStats,
    List<String>? attachments,
  }) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content ?? this.content,
      imagePath: imagePath,
      imagePaths: imagePaths,
      visionPaths: visionPaths,
      attachments: attachments ?? this.attachments,
      audioPath: audioPath,
      timestamp: timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
      inferenceStats: inferenceStats ?? this.inferenceStats,
    );
  }
}
