// ============================================================
// Remote OpenAI-compatible model configuration.
// Each entry maps a display name to an OpenAI-compatible endpoint
// ({baseUrl}/chat/completions). Configs are persisted (plaintext) in
// the same settings JSON as local inference settings.
// ============================================================

/// 一个 OpenAI 兼容的远程模型配置。
///
/// 字段说明：
/// - [id]      本地生成的唯一标识（uuid），用于持久化与激活引用。
/// - [name]    界面显示名（如 "GPT-4o"）。
/// - [baseUrl] OpenAI 兼容端点根地址（如 `https://api.openai.com/v1`，
///   或本地 `http://127.0.0.1:8080/v1`）。服务调用时自动补 `/chat/completions`。
/// - [apiKey]  访问密钥（明文存本地 JSON，适合本地个人使用）。
/// - [model]   远端模型名（如 `gpt-4o`、`qwen2.5-7b-instruct`）。
/// - [temperature] 可空的生成温度；null 用全局默认 0.7。
/// - [maxTokens]   可空的输出上限；null 用全局默认 1024。
class ApiModelConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  final double? temperature;
  final int? maxTokens;

  const ApiModelConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature,
    this.maxTokens,
  });

  /// 生效温度：配置值 ?? 0.7。
  double get effectiveTemperature => temperature ?? 0.7;

  /// 生效输出上限：配置值 ?? 1024（与本地推理默认一致）。
  int get effectiveMaxTokens => maxTokens ?? 1024;

  ApiModelConfig copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    int? maxTokens,
    bool clearTemperature = false,
    bool clearMaxTokens = false,
  }) {
    return ApiModelConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      temperature:
          clearTemperature ? null : temperature ?? this.temperature,
      maxTokens: clearMaxTokens ? null : maxTokens ?? this.maxTokens,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        'maxTokens': maxTokens,
      };

  factory ApiModelConfig.fromJson(Map<String, dynamic> json) {
    return ApiModelConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      temperature: (json['temperature'] as num?)?.toDouble(),
      maxTokens: (json['maxTokens'] as num?)?.toInt(),
    );
  }
}
