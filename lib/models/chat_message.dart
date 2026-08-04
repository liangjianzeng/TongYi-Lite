enum MessageRole { user, assistant }

/// 单次回复的性能统计（仅 assistant 消息有）。
class InferenceStats {
  final int firstTokenMs; // 首 token 延迟（发送到首个 token 的时间）
  final int totalMs;      // 总耗时
  final double tokPerSec; // 生成速率（token/秒）

  const InferenceStats({
    required this.firstTokenMs,
    required this.totalMs,
    required this.tokPerSec,
  });

  Map<String, dynamic> toMap() => {
        'firstTokenMs': firstTokenMs,
        'totalMs': totalMs,
        'tokPerSec': tokPerSec,
      };

  factory InferenceStats.fromMap(Map<String, dynamic> map) => InferenceStats(
        firstTokenMs: (map['firstTokenMs'] as num?)?.toInt() ?? 0,
        totalMs: (map['totalMs'] as num?)?.toInt() ?? 0,
        tokPerSec: (map['tokPerSec'] as num?)?.toDouble() ?? 0,
      );
}

class ChatMessage {
  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final String? imagePath;
  final DateTime timestamp;
  final bool isStreaming;
  final InferenceStats? inferenceStats;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.imagePath,
    DateTime? timestamp,
    this.isStreaming = false,
    this.inferenceStats,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role.name,
      'content': content,
      'imagePath': imagePath,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isStreaming': isStreaming ? 1 : 0,
      'inferenceStats': inferenceStats?.toMap(),
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    final stats = map['inferenceStats'];
    return ChatMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      role: MessageRole.values.where((e) => e.name == map['role']).first,
      content: map['content'] as String,
      imagePath: map['imagePath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      isStreaming: (map['isStreaming'] as int?) == 1,
      inferenceStats: stats is Map<String, dynamic> ? InferenceStats.fromMap(stats) : null,
    );
  }

  ChatMessage copyWith({
    String? content,
    bool? isStreaming,
    InferenceStats? inferenceStats,
  }) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content ?? this.content,
      imagePath: imagePath,
      timestamp: timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
      inferenceStats: inferenceStats ?? this.inferenceStats,
    );
  }
}
