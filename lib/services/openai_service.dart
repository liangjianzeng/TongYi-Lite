// ============================================================
// OpenAI-compatible remote inference service.
//
// Implements the standard OpenAI `chat/completions` (SSE streaming)
// protocol over dio, so any OpenAI-compatible endpoint (OpenAI 官方、
// 本地 llama.cpp server、vLLM 等) can serve as a remote model fallback.
// The chat layer routes to this service ONLY when the local model is
// unavailable (local-first policy), and consumes a Stream<String> that
// mirrors the local engine's token stream.
// ============================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/api_model.dart';

/// OpenAI 兼容远程推理服务。密钥明文由配置持有，此处仅用于请求头。
class OpenAiService {
  OpenAiService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 当前流式请求的取消令牌，用于「停止生成」。
  CancelToken? _cancelToken;

  /// 归一化 chat/completions 端点：
  /// - 去首尾空白、去尾部斜杠；
  /// - 若用户已带 `/chat/completions` 则不重复拼接。
  static String normalizeChatUrl(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) return url;
    return '$url/chat/completions';
  }

  Map<String, String> _headers(String apiKey) {
    return {
      'Accept': 'text/event-stream',
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
  }

  /// 发起流式 chat/completions，返回增量文本流（与本地接口同形）。
  ///
  /// [messages] 形如 `[{role: user|assistant, content: ...}]`。
  /// 网络/鉴权/解析失败时抛出可读中文 [Exception]，由调用方兜底。
  Stream<String> chatCompletion({
    required ApiModelConfig config,
    required List<Map<String, String>> messages,
    double? temperature,
    int? maxTokens,
  }) async* {
    // 中断上一轮（若存在），并为本轮创建新令牌。
    _cancelToken?.cancel();
    _cancelToken = CancelToken();

    final url = normalizeChatUrl(config.baseUrl);
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'stream': true,
      'temperature': temperature ?? config.effectiveTemperature,
      'max_tokens': maxTokens ?? config.effectiveMaxTokens,
    };

    final Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        url,
        data: body,
        options: Options(
          responseType: ResponseType.stream,
          headers: _headers(config.apiKey),
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      throw Exception(_friendlyDioError(e));
    }

    if (response.statusCode != 200) {
      throw Exception('API 请求失败：HTTP ${response.statusCode}');
    }

    // 逐行解析 SSE：data: {json} ... data: [DONE]
    // dio 流式响应：response.data 是 ResponseBody，其 .stream 为字节流。
    final byteStream =
        response.data?.stream ?? const Stream<Uint8List>.empty();
    final lines = utf8.decoder
        .bind(byteStream)
        .transform(const LineSplitter());

    await for (final rawLine in lines) {
      final line = rawLine.trim();
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;
      try {
        final json = jsonDecode(payload) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final first = choices.first;
        if (first is! Map<String, dynamic>) continue;
        final delta = first['delta'];
        final content =
            (delta is Map<String, dynamic>) ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          yield content;
        }
      } catch (_) {
        // 忽略无法解析的行（心跳/注释/不完整 JSON），继续下一行。
      }
    }
  }

  /// 测试连接：发一个最小的非流式 chat/completions（max_tokens=1），
  /// 校验 baseUrl / apiKey / model 是否可用。
  ///
  /// 返回 null 表示成功；否则返回可读中文错误信息。
  Future<String?> testConnection(ApiModelConfig config) async {
    final url = normalizeChatUrl(config.baseUrl);
    final body = <String, dynamic>{
      'model': config.model,
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
      'stream': false,
      'max_tokens': 1,
    };
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        url,
        data: body,
        options: Options(
          responseType: ResponseType.json,
          headers: _headers(config.apiKey),
        ),
      );
      if (response.statusCode != 200) {
        return 'HTTP ${response.statusCode}';
      }
      final choices = response.data?['choices'];
      if (choices is List && choices.isNotEmpty) {
        return null; // 成功
      }
      return '响应缺少 choices';
    } on DioException catch (e) {
      return _friendlyDioError(e);
    }
  }

  /// 停止当前流式生成（中断 SSE 请求）。
  void stop() {
    _cancelToken?.cancel();
  }

  /// 把 dio 异常转成可读中文信息。
  String _friendlyDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查 baseUrl 与网络';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return '服务端返回异常（HTTP $code）：${e.response?.statusMessage ?? ''}';
      case DioExceptionType.connectionError:
        return '无法连接到服务端，请检查 baseUrl';
      default:
        return '请求失败：${e.message ?? e.type}';
    }
  }
}
