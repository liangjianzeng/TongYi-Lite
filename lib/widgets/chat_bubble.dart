import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/chat_message.dart';
import '../services/share_service.dart';

class ChatBubble extends StatelessWidget {
  final String role; // 'user' or 'assistant' or 'system'
  final String content;
  final DateTime timestamp;
  final bool isStreaming;
  final bool showAvatar;
  final String? imagePath;
  final List<String>? imagePaths;
  final List<String>? attachments;
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
    this.imagePaths,
    this.attachments,
    this.audioPath,
    this.inferenceStats,
  });

  bool get _isUser => role == 'user';

  /// 工具活动消息（🔧 前缀，智能体模式工具轮）。
  bool get _isToolActivity => !_isUser && content.startsWith('🔧');

  /// 思考中占位（内容为空 + 流式中 → 显示「思考中…」指示器）。
  bool get _isThinkingPlaceholder => !_isUser && isStreaming && content.isEmpty;

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
                  padding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: _isToolActivity ? 8 : 12,
                  ),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: _isUser
                        ? theme.colorScheme.primary
                        : (_isToolActivity
                            ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5)
                            : theme.colorScheme.surfaceContainerHighest),
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
                      // Show image if present (user messages only)；多图 ≤10 依次展示。
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
                      if (imagePaths != null && imagePaths!.length > 1) ...[
                        SizedBox(
                          height: 110,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final path in imagePaths!.skip(1))
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      File(path),
                                      height: 100,
                                      width: 100,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      // 智能体附件（WP-A）：文件名 chips 展示。
                      if (attachments != null && attachments!.isNotEmpty) ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final name in attachments!)
                              Chip(
                                visualDensity: VisualDensity.compact,
                                avatar: const Icon(Icons.description, size: 16),
                                label: Text(
                                  name,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      // 工具活动消息：紧凑文本 + 工具图标（不暴露原始 JSON）。
                      if (_isToolActivity) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.construction,
                              size: 13,
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                content,
                                style: TextStyle(
                                  color: theme.colorScheme.onTertiaryContainer,
                                  fontSize: 13,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        // 思考中占位：空内容 + 流式 → 显示「思考中…」。
                        if (_isThinkingPlaceholder) ...[
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '思考中…',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 13,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ),
                        ] else if (content.isNotEmpty) ...[
                          if (_isUser)
                            Text(
                              content,
                              style: TextStyle(
                                color: theme.colorScheme.onPrimary,
                                fontSize: 15,
                                height: 1.5,
                              ),
                            )
                          else
                            // 智能体回答 markdown 美化渲染（WP-B）：标题/列表/
                            // 代码块/表格/加粗等结构化排版。流式期间部分 MD
                            // 也能渐进渲染；纯文本行不受影响。
                            MarkdownBody(
                              data: content,
                              selectable: true,
                              softLineBreak: true,
                              styleSheet: MarkdownStyleSheet.fromTheme(
                                theme,
                              ).copyWith(
                                p: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                                h1: theme.textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                h2: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                h3: theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                codeblockDecoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                code: TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  backgroundColor: theme
                                      .colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.7),
                                ),
                                tableBorder: TableBorder.all(
                                  color: theme.dividerColor,
                                ),
                              ),
                            ),
                        ],
                        if (isStreaming && !_isThinkingPlaceholder) ...[
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
                      const SizedBox(width: 6),
                      // 转发/分享：经系统分享面板（微信/QQ/邮件等均可选）。
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          final ok = await ShareService.instance
                              .shareText(content, title: '分享回复');
                          if (context.mounted && !ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('未找到可用的分享入口'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.share,
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
  /// 首Tok=0（智能体回答无单步首Tok语义）时省略，显示 '耗时 X · Y tok/s'。
  String _formatStats(InferenceStats s) {
    final first = s.firstTokenMs > 0
        ? (s.firstTokenMs >= 1000
            ? '首Tok ${(s.firstTokenMs / 1000).toStringAsFixed(1)}s · '
            : '首Tok ${s.firstTokenMs}ms · ')
        : '';
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
    return '$first$vision$audio · 耗时 $total · $rate tok/s';
  }
}
