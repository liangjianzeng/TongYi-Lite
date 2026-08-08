import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  final String role; // 'user' or 'assistant' or 'system'
  final String content;
  final DateTime timestamp;
  final bool isStreaming;
  final bool showAvatar;
  final String? imagePath;
  final String? audioPath;
  final InferenceStats? inferenceStats;

  const ChatBubble({
    super.key,
    required this.role,
    required this.content,
    required this.timestamp,
    this.isStreaming = false,
    this.showAvatar = true,
    this.imagePath,
    this.audioPath,
    this.inferenceStats,
  });

  bool get _isUser => role == 'user';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: _isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!showAvatar && !_isUser) const SizedBox(width: 40),
          if (showAvatar && !_isUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(Icons.auto_awesome, size: 16, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: const BoxConstraints(maxWidth: 600),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: _isUser ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 语音消息标记（端侧语音理解）
                      if (audioPath != null && audioPath!.isNotEmpty) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.mic,
                                size: 14,
                                color: _isUser
                                    ? theme.colorScheme.onPrimary
                                    : theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              '语音',
                              style: TextStyle(
                                color: _isUser
                                    ? theme.colorScheme.onPrimary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                      ],
                      // Show image if present (user messages only)
                      if (imagePath != null && imagePath!.isNotEmpty) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 300, maxHeight: 300),
                            child: Image.file(
                              File(imagePath!),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      // Show text content
                      if (content.isNotEmpty) ...[
                        Text(
                          content,
                          style: TextStyle(
                            color: _isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),
                      ],
                      if (isStreaming) ...[
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _isUser ? Colors.white : theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                         Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(timestamp),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                    if (!_isUser && inferenceStats != null) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _formatStats(inferenceStats!),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                    if (!_isUser && content.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: content));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已复制回复内容'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.content_copy,
                            size: 15,
                            color: Colors.grey.shade400,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ],
            ),
          ),
          if (showAvatar && _isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.secondaryContainer,
              child: Icon(Icons.person, size: 16, color: theme.colorScheme.onSecondaryContainer),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// 性能指标：首Tok / 视觉(仅视觉) / 耗时 / 速率。
  /// 例：'首Tok 1.2s · 视觉 3.4s · 耗时 5.3s · 14.5 tok/s'
  String _formatStats(InferenceStats s) {
    final first = s.firstTokenMs >= 1000
        ? '${(s.firstTokenMs / 1000).toStringAsFixed(1)}s'
        : '${s.firstTokenMs}ms';
    final total = s.totalMs >= 1000
        ? '${(s.totalMs / 1000).toStringAsFixed(1)}s'
        : '${s.totalMs}ms';
    final rate = s.tokPerSec.toStringAsFixed(1);
    // 视觉回复额外展示「视觉」耗时，语音回复展示「听音」耗时（媒体编码耗时）。
    final vision = s.visionMs > 0
        ? (s.visionMs >= 1000
            ? ' · 视觉 ${(s.visionMs / 1000).toStringAsFixed(1)}s'
            : ' · 视觉 ${s.visionMs}ms')
        : '';
    final audio = s.audioMs > 0
        ? (s.audioMs >= 1000
            ? ' · 听音 ${(s.audioMs / 1000).toStringAsFixed(1)}s'
            : ' · 听音 ${s.audioMs}ms')
        : '';
    return '首Tok $first$vision$audio · 耗时 $total · $rate tok/s';
  }
}
