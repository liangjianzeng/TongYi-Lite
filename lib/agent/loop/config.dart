/// 智能体主循环配置（Phase 1）。
///
/// 全部可配置，不做死配置。字段命名与 DSH 语义对齐：
/// [maxStepsPerTurn] 一次 turn 内最多模型请求（step）数；
/// [maxTokensPerRound] 每步生成预算。

/// 智能体驱动路线：端侧小模型 / API 云端模型。
///
/// 两条路线的资源约束与目标不同（端侧省 token、API 吃满上下文），
/// 循环参数按路线分档（见 [AgentConfig.forRoute]），不共用一套默认值。
enum AgentRoute { local, api }

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

  /// 主动压缩的上下文 token 预算（估算值，chars/4）。
  ///
  /// null = 不做主动计量（API 大窗口不需要）；local 档 = nctx×3/4，
  /// 请求前估算超预算则先压缩，不等撞墙（WP3 消费）。
  final int? contextTokenBudget;

  /// 「工具结果回填后」步的生成预算（null = 沿用 [maxTokensPerRound]）。
  ///
  /// 端侧小模型写最终回答比写工具调用更耗 token，统一小预算必然截断回答；
  /// 该预算只对"上一步有工具结果"的步生效（WP3 消费）。
  final int? maxTokensFinalRound;

  const AgentConfig({
    this.maxStepsPerTurn = 12,
    this.maxTokensPerRound = 512,
    this.temperature = 0.7,
    this.toolTimeout = const Duration(seconds: 15),
    this.allowParallelTools = false,
    this.maxParallel = 4,
    this.persistTrajectory = false,
    this.contextTokenBudget,
    this.maxTokensFinalRound,
  }) :
    assert(maxStepsPerTurn >= 1 && maxStepsPerTurn <= 24,
        'maxStepsPerTurn must be in [1, 24]'),
    assert(temperature >= 0.0 && temperature <= 2.0,
        'temperature must be in [0, 2]');

  /// 双场景档出厂默认值。
  ///
  /// local 沿用端侧现值（省 token、串行、短超时）；api 对齐 DSH 式云端
  /// 预算（大生成预算、并行工具、长超时），settings 可逐项覆盖。
  factory AgentConfig.forRoute(AgentRoute route) => switch (route) {
        AgentRoute.local => const AgentConfig(
            maxStepsPerTurn: 12,
            maxTokensPerRound: 1024,
            temperature: 0.7,
            toolTimeout: Duration(seconds: 15),
            allowParallelTools: false,
            maxParallel: 2,
            contextTokenBudget: null,
            maxTokensFinalRound: 2048,
          ),
        AgentRoute.api => const AgentConfig(
            maxStepsPerTurn: 16,
            maxTokensPerRound: 8192,
            temperature: 0.7,
            toolTimeout: Duration(seconds: 30),
            allowParallelTools: true,
            maxParallel: 4,
          ),
      };
}
