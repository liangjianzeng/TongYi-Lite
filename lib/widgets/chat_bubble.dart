import 'dart:io';
import 'package:flutter/material.dart';

class ChatBubble extends StatelessWidget {
  final String role; // 'user' or 'assistant' or 'system'
  final String content;
  final DateTime timestamp;
  final bool isStreaming;
  final bool showAvatar;
  final String? imagePath;

  const ChatBubble({
    super.key,
    required this.role,
    required this.content,
    required this.timestamp,
    this.isStreaming = false,
    this.showAvatar = true,
    this.imagePath,
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
                  child: Text(
                    _formatTime(timestamp),
                    style: TextStyle(fontSize: 11, color: Colors.grey),
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
}
