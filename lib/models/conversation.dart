class Conversation {
  final String id;
  final String title;
  final String modelId;
  final int messageCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    required this.id,
    required this.title,
    this.modelId = 'qwen3-1.7b-q4_k_m',
    this.messageCount = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'modelId': modelId,
      'messageCount': messageCount,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String? ?? '',
      modelId: map['modelId'] as String? ?? 'qwen3-1.7b-q4_k_m',
      messageCount: map['messageCount'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
    );
  }
}
