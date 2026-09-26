/// 智能体主循环配置（Phase 1）。
///
/// 全部可配置，不做死配置。字段命名与 DSH 语义对齐：
/// [maxStepsPerTurn] 一次 turn 内最多模型请求（step）数；
/// [maxTokensPerRound] 每步生成预算。
final class AgentConfig {
  /// 一次 turn 内最大 step 数（达到则 turn/end {reason: maxSteps}）。
  final int maxStepsPerTurn;

  /// 每步生成 token 预算（由本地引擎消费）。
  final int maxTokensPerRound;

  /// 生成温度。
  final double temperature;

  /// 单工具执行超时。
  final Duration toolTimeout;

  /// 预留：并行工具调用（依赖能力 + 工具声明）。
  final bool allowParallelTools;

  /// 并行执行上限（端侧默认 4；Dart 单线程事件驱动，I/O 并发）。
  final int maxParallel;

  /// 预留：工具轨迹持久化。
  final bool persistTrajectory;

  const AgentConfig({
    this.maxStepsPerTurn = 12,
    this.maxTokensPerRound = 512,
    this.temperature = 0.7,
    this.toolTimeout = const Duration(seconds: 15),
    this.allowParallelTools = false,
    this.maxParallel = 4,
    this.persistTrajectory = false,
  }) :
    assert(maxStepsPerTurn >= 1 && maxStepsPerTurn <= 24,
        'maxStepsPerTurn must be in [1, 24]'),
    assert(temperature >= 0.0 && temperature <= 2.0,
        'temperature must be in [0, 2]');
}