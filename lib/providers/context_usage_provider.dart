import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单个会话的上下文占用快照。
///
/// - [usedTokens]：当前发送给模型的上下文 token 数（API `usage.prompt_tokens`）；
/// - [windowTokens]：上下文槽位大小（优先 API `/v1/models` 的 `n_ctx`，
///   回退 API 配置 [ApiModelConfig.contextWindow]）；
/// - [windowSource]：槽位来源，用于 UI 区分「实测 / 配置估算」。
class ContextUsage {
  final int? usedTokens;
  final int? windowTokens;
  final String windowSource;

  const ContextUsage({
    this.usedTokens,
    this.windowTokens,
    this.windowSource = '',
  });

  /// 占用比例（0..1）。任一项缺失 → null（无数据不显示）。
  double? get fraction {
    final used = usedTokens;
    final win = windowTokens;
    if (used == null || win == null || win <= 0) return null;
    return (used / win).clamp(0.0, 1.0);
  }

  bool get hasData => fraction != null;
}

/// 按会话 id 跟踪 API 接入模型的上下文占用，供顶部状态栏细条展示。
///
/// 仅记录 API 接入模型的占用；本地模型不更新（UI 侧也不显示）。
class ContextUsageNotifier extends StateNotifier<Map<String, ContextUsage>> {
  ContextUsageNotifier() : super(const {});

  /// 更新某会话的上下文占用。
  ///
  /// [windowTokens] 为 null 且 [windowSource] 非空时表示「无槽位数据」，
  /// 此时仍记录 used，但 fraction 因窗口缺失为 null（UI 不显示）。
  void update(
    String conversationId, {
    int? usedTokens,
    int? windowTokens,
    String windowSource = '',
  }) {
    final next = Map<String, ContextUsage>.from(state);
    next[conversationId] = ContextUsage(
      usedTokens: usedTokens,
      windowTokens: windowTokens,
      windowSource: windowSource,
    );
    state = next;
  }

  /// 读取某会话的占用快照（无记录返回 null）。
  ContextUsage? usageFor(String? conversationId) =>
      conversationId == null ? null : state[conversationId];

  /// 某会话是否已有可显示的占用数据。
  bool hasUsage(String? conversationId) =>
      usageFor(conversationId)?.hasData ?? false;
}

final contextUsageProvider =
    StateNotifierProvider<ContextUsageNotifier, Map<String, ContextUsage>>(
        (ref) => ContextUsageNotifier());
