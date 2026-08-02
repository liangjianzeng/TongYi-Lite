enum MessageRole { user, assistant }

class ChatMessage {
  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final String? imagePath;
  final DateTime timestamp;
  final bool isStreaming;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.imagePath,
    DateTime? timestamp,
    this.isStreaming = false,
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
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      role: MessageRole.values.where((e) => e.name == map['role']).first,
      content: map['content'] as String,
      imagePath: map['imagePath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      isStreaming: (map['isStreaming'] as int?) == 1,
    );
  }

  ChatMessage copyWith({
    String? content,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content ?? this.content,
      imagePath: imagePath,
      timestamp: timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}
