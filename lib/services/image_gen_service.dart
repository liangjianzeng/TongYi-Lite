/// 图像生成服务（同尾网 Tailscale / 局域网的 Unsloth Studio
/// Qwen-Image-2.1-Turbo，OpenAI 兼容
/// `/v1/images/generations`，b64_json 返回）。能力移植自汪柴 WangCai
/// （其方案 docs/image-gen-integration-plan.md 2026-11-09 评审定案版），
/// 移动端适配处的差异见各段注释。
///
/// 纪律与裁决：
/// - **纯 Dart + dio，零原生依赖**——与 openai_service 同级的纯 HTTP 客户端，
///   不进 JNI / 平台通道，`flutter analyze/test` 全覆盖。
/// - **单飞队列**：服务端单卡串行；客户端 Future 链排队防连点打爆。
/// - 取消用 dio CancelToken（2048² 一张 ~105s，取消必须真的掐断请求）。
/// - 超时按尺寸分档：≤1024 → 120s，≥2048 → 300s（首请求含模型加载也归入
///   该预算）。
/// - 配置快照（[ImageGenConfig]）由调用方每次传入——服务不持有全局可变
///   设置状态，测试直接构造 config 注入。
/// - 密钥随设置 JSON 明文存（与 ApiModelConfig.apiKey 同口径的本地个人
///   使用约定，见 models/api_model.dart:15）；生图 key 指向的是自建
///   （同尾网）服务，泄露面与聊天 API key 相同——但本仓是公开克隆，
///   出厂预置 key 按"已公开"对待（见 kImageGenDefaultApiKey 注释）。
library;

import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

/// 允许的尺寸档位（设置页下拉 / 工具 schema enum，与 API 契约一致）。
const List<String> kImageGenSizes = [
  '512x512',
  '1024x1024',
  '1440x1440',
  '2048x2048',
];

/// 出厂预置服务地址：liang-geekpro（Unsloth Studio 宿主）的 Tailscale serve
/// `https://liang-geekpro.tailfe4bdd.ts.net:8888 → 127.0.0.1:8888`。
/// **tailnet-only**：手机装 Tailscale 并连接同尾网即可跨网访问（不限局域网）；
/// 同局域网时也可直接填 `http://<PC>:8888`。本仓公开克隆者请改成自己的
/// 服务端地址（或清空，未配置时工具报"未配置服务地址"诊断）。
const String kImageGenDefaultBaseUrl =
    'https://liang-geekpro.tailfe4bdd.ts.net:8888';

/// 出厂预置模型 id：2026-11-10 实测 `GET /v1/models` 返回
/// `qwen-image-2.1-turbo-Q5_K_M`（task=text-to-image，常驻 loaded）。
/// 设置页从服务端拉列表选择；此值仅为服务端不可达时的兜底。
const String kImageGenDefaultModel = 'qwen-image-2.1-turbo-Q5_K_M';

/// 出厂预置 API key（Unsloth Studio 的 local-verify key，实测 /v1/models
/// 返回 200）。**本仓是公开克隆**——此 key 的安全边界按"已公开"对待：
/// 它只保护自建生图服务本身，泄露代价是 GPU 出图时长；换环境请重新签发。
const String kImageGenDefaultApiKey =
    'sk-unsloth-c9545d0d6ec5c05dd0c443d68034d5ac';

/// 一次生图调用的配置快照（来自 InferenceSettings，调用方负责取新值）。
class ImageGenConfig {
  final bool enabled;
  final String baseUrl;
  final String model;
  final String defaultSize;
  final String apiKey;

  const ImageGenConfig({
    required this.enabled,
    required this.baseUrl,
    this.model = kImageGenDefaultModel,
    this.defaultSize = '1024x1024',
    this.apiKey = '',
  });

  /// 生效地址：去尾斜杠。手机没有"本机 127.0.0.1"可言——空串就是未配置。
  /// 主路径是 Tailscale serve 地址（同尾网即可，跨网可用）；同局域网也可
  /// 直填 `http://<PC>:8888`（服务端需开 LAN + 防火墙放行 8888）。
  String get effectiveBaseUrl {
    final t = baseUrl.trim();
    if (t.isEmpty) return '';
    return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
  }

  bool get isConfigured => enabled && effectiveBaseUrl.isNotEmpty;

  /// 生效尺寸（脏值回落默认档）。
  String get effectiveSize =>
      kImageGenSizes.contains(defaultSize) ? defaultSize : '1024x1024';
}

/// 一次成功生图的结果（路径已落盘）。
class ImageGenResult {
  /// 本地 PNG 文件绝对路径（n 张）。
  final List<String> paths;

  /// 实际使用的随机种子（客户端生成并随消息留痕，支持同 seed 重生成）。
  final int seed;
  final String size;
  final int ms;

  const ImageGenResult({
    required this.paths,
    required this.seed,
    required this.size,
    required this.ms,
  });

  /// 溯源元数据（生图消息留痕的 JSON 结构，单真源）。
  Map<String, dynamic> metaJson(String prompt, String model) => {
        'seed': seed,
        'size': size,
        'ms': ms,
        'model': model,
        'prompt': prompt,
      };
}

class ImageGenErrorKind {
  final String name;
  const ImageGenErrorKind._(this.name);

  static const notConfigured = ImageGenErrorKind._('notConfigured');
  static const unreachable = ImageGenErrorKind._('unreachable');
  static const timeout = ImageGenErrorKind._('timeout');
  static const unauthorized = ImageGenErrorKind._('unauthorized');
  static const serverBusy = ImageGenErrorKind._('serverBusy');
  static const server = ImageGenErrorKind._('server');
  static const decode = ImageGenErrorKind._('decode');
  static const cancelled = ImageGenErrorKind._('cancelled');

  @override
  String toString() => name;
}

class ImageGenException implements Exception {
  final ImageGenErrorKind kind;
  final String message;
  ImageGenException(this.kind, this.message);

  @override
  String toString() => 'ImageGenException(${kind.name}: $message)';
}

/// 健康检查结果（设置页「测试连接」绿灯/红灯依据）。
class ImageGenHealth {
  final bool reachable;

  /// /v1/models（需 Bearer）是否通过；reachable 但 false = 密钥错误。
  final bool authorized;
  final int modelCount;

  /// /v1/models 顺带回传的模型 id（优先 task=text-to-image；列表不可用时空）。
  final List<String> models;
  final String message;
  const ImageGenHealth({
    required this.reachable,
    required this.authorized,
    this.modelCount = 0,
    this.models = const [],
    required this.message,
  });

  bool get ok => reachable && authorized;
}

/// 从 /v1/models 的 data 数组挑模型 id：优先 task=text-to-image 的生图模型；
/// 服务端不带 task 字段时（非 Unsloth 网关）回退全量列表。
List<String> pickImageModelIds(dynamic data) {
  final dynamic list = data is Map ? data['data'] : null;
  if (list is! List) return const [];
  final all = <String>[];
  final t2i = <String>[];
  for (final e in list) {
    if (e is Map && e['id'] is String && (e['id'] as String).isNotEmpty) {
      final id = e['id'] as String;
      all.add(id);
      if (e['task'] == 'text-to-image') t2i.add(id);
    }
  }
  return t2i.isNotEmpty ? t2i : all;
}

/// `/图 ` 聊天直达生图口令（P2，用户 2026-11-10 定案：聊天模式也要能出图，
/// 不必绕道智能体工具）。纯函数解析，chat_provider 拦截层消费，单测直测。
///
/// 规则：trim 后行首恰为 `/图` + 空格/换行/全角空格才算命中（「/图片」
/// 「帮我写个/图表」不误伤）。尾部尺寸口令 `尺寸 2048x2048`/`size:1024x1024`
/// /`@512x512`（档位在 [kImageGenSizes] 内）从提示词剥离并显式生效；
/// 非档位（如 999x999）留在提示词原文里不动。
class ImageGenSlash {
  final String prompt;
  final String? size;
  const ImageGenSlash({required this.prompt, this.size});
}

ImageGenSlash? parseImageSlash(String text) {
  final t = text.trim();
  if (t != '/图' &&
      !t.startsWith('/图 ') &&
      !t.startsWith('/图\n') &&
      !t.startsWith('/图　')) {
    return null;
  }
  var body = t.substring('/图'.length).trim();
  String? size;
  final m = RegExp(
          r'[，,、]?\s*(?:尺寸|size)?\s*[:：@]?\s*(512|1024|1440|2048)x\1\s*$')
      .firstMatch(body);
  if (m != null) {
    size = '${m.group(1)}x${m.group(1)}';
    body = body.substring(0, m.start).trim();
  }
  return ImageGenSlash(prompt: body, size: size);
}

class ImageGenService {
  ImageGenService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              // 有意不设 receiveTimeout（openai_service 同款口径）：生成本身
              // 就是分钟级长请求，超时分档在请求级 Future.timeout 控制。
            ));

  static final ImageGenService instance = ImageGenService();

  final Dio _dio;

  /// 测试注入口：覆盖**文档目录**（单测不走 path_provider 插件）；
  /// imagegen/YYYYMMDD 子目录结构照常生效（测试顺带覆盖落盘布局）。
  static Future<Directory> Function()? docsDirOverride;

  // ---- 单飞队列（Future 链；服务端单卡串行）----
  Future<void> _queueTail = Future<void>.value();
  CancelToken? _activeToken;

  /// 当前是否有请求在飞。
  bool get hasActive => _activeToken != null;

  /// 取消当前在飞请求（排队中的不取消——队列深度通常为 0/1）。
  void cancelActive() {
    _activeToken?.cancel('用户取消');
  }

  /// 队列化执行一次生图；返回已落盘的本地 PNG 路径与溯源参数。
  Future<ImageGenResult> generate({
    required ImageGenConfig config,
    required String prompt,
    String? size,
    String? negative,
    int? seed,
    int n = 1,
  }) {
    return _enqueue(() => _generate(config, prompt, size, negative, seed, n));
  }

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final run = _queueTail.then((_) => job());
    // 链继续挂接：本任务失败（含取消）不断链——后续任务照常执行。
    _queueTail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<ImageGenResult> _generate(
    ImageGenConfig config,
    String prompt,
    String? size,
    String? negative,
    int? seed,
    int n,
  ) async {
    final promptTrimmed = prompt.trim();
    if (promptTrimmed.isEmpty) {
      throw ImageGenException(ImageGenErrorKind.notConfigured, '提示词为空');
    }
    if (!config.isConfigured) {
      throw ImageGenException(
          ImageGenErrorKind.notConfigured,
          config.enabled
              ? '未配置服务地址（设置 → API 接入 → 图像生成）'
              : '图像生成未启用（设置 → API 接入 → 图像生成）');
    }
    final base = config.effectiveBaseUrl;
    final model = config.model.trim().isEmpty
        ? kImageGenDefaultModel
        : config.model.trim();
    final effectiveSize =
        kImageGenSizes.contains(size) ? size! : config.effectiveSize;
    final count = n.clamp(1, 4);
    final actualSeed = seed ?? Random().nextInt(1 << 31);

    final token = CancelToken();
    _activeToken = token;
    final sw = Stopwatch()..start();
    try {
      final Response<dynamic> resp;
      try {
        resp = await _dio
            .post<dynamic>(
              '$base/v1/images/generations',
              options: Options(
                headers: {
                  if (config.apiKey.isNotEmpty)
                    'Authorization': 'Bearer ${config.apiKey}',
                },
                responseType: ResponseType.json,
                sendTimeout: const Duration(seconds: 30),
              ),
              cancelToken: token,
              data: {
                'model': model,
                'prompt': promptTrimmed,
                if (negative != null && negative.trim().isNotEmpty)
                  'negative_prompt': negative.trim(),
                'n': count,
                'size': effectiveSize,
                'response_format': 'b64_json',
                'seed': actualSeed,
              },
            )
            .timeout(timeoutForSize(effectiveSize));
      } on TimeoutException {
        throw ImageGenException(
            ImageGenErrorKind.timeout,
            '生成超时（$effectiveSize 预算 '
            '${timeoutForSize(effectiveSize).inSeconds}s，可去设置换小尺寸）');
      } on DioException catch (e) {
        throw _fromDio(e);
      }
      final dynamic data = resp.data;
      final dynamic list = data is Map ? data['data'] : null;
      if (list is! List || list.isEmpty) {
        throw ImageGenException(
            ImageGenErrorKind.decode, '响应缺少 data 数组');
      }
      final dir = await _dayDir();
      final paths = <String>[];
      final ts = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < list.length; i++) {
        final entry = list[i];
        final dynamic b64 = entry is Map ? entry['b64_json'] : null;
        if (b64 is! String || b64.isEmpty) {
          throw ImageGenException(
              ImageGenErrorKind.decode, '第 ${i + 1} 张缺少 b64_json');
        }
        final List<int> bytes;
        try {
          bytes = base64Decode(b64);
        } on FormatException catch (e) {
          throw ImageGenException(
              ImageGenErrorKind.decode, 'base64 解码失败: $e');
        }
        final file = File(
            p.join(dir.path, 'img-$ts-${actualSeed}_${i + 1}.png'));
        await file.writeAsBytes(bytes, flush: true);
        paths.add(file.path);
      }
      sw.stop();
      return ImageGenResult(
        paths: paths,
        seed: actualSeed,
        size: effectiveSize,
        ms: sw.elapsedMilliseconds,
      );
    } finally {
      _activeToken = null;
    }
  }

  /// DioException → 带口径的 ImageGenException（错误文案区分 unreachable /
  /// unauthorized / 429 排队 / 超时，设置页与聊天报错共用）。
  ImageGenException _fromDio(DioException e) {
    if (CancelToken.isCancel(e)) {
      return ImageGenException(ImageGenErrorKind.cancelled, '已取消');
    }
    final code = e.response?.statusCode ?? 0;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      // dio 存量别名（等同 receiveTimeout，仍枚举在类型里）。
      case DioExceptionType.transformTimeout:
        return ImageGenException(
            ImageGenErrorKind.timeout, '连接超时（服务可能未启动）');
      case DioExceptionType.connectionError:
        return ImageGenException(ImageGenErrorKind.unreachable,
            '服务不可达（请确认 Unsloth 已启动；用 Tailscale 地址时'
            '需手机 Tailscale 已连接同尾网，用局域网地址时需同网段且放行 8888）');
      case DioExceptionType.badResponse:
        if (code == 401 || code == 403) {
          return ImageGenException(
              ImageGenErrorKind.unauthorized, '鉴权失败（API key 错误或已吊销）');
        }
        if (code == 429) {
          return ImageGenException(
              ImageGenErrorKind.serverBusy, '服务端正忙（429），请稍后重试');
        }
        return ImageGenException(
            ImageGenErrorKind.server, '服务端错误（HTTP $code）');
      case DioExceptionType.cancel:
        return ImageGenException(ImageGenErrorKind.cancelled, '已取消');
      case DioExceptionType.badCertificate:
        return ImageGenException(
            ImageGenErrorKind.unreachable, '证书校验失败');
      case DioExceptionType.unknown:
        return ImageGenException(ImageGenErrorKind.unreachable,
            '网络错误：${e.message ?? e.error ?? ''}');
    }
  }

  /// 超时预算按尺寸分档：>=2048 → 300s，否则 120s。
  static Duration timeoutForSize(String size) {
    final parts = size.split('x');
    final w = int.tryParse(parts.first) ?? 1024;
    final h = parts.length > 1 ? (int.tryParse(parts[1]) ?? w) : w;
    return max(w, h) >= 2048
        ? const Duration(seconds: 300)
        : const Duration(seconds: 120);
  }

  /// 健康检查：`GET {base}/api/health`（免鉴权）测可达性；
  /// `GET {base}/v1/models`（需 Bearer）测密钥并顺带数模型。
  /// 任一步网络异常都折算成可达性结论，绝不抛——设置页绿灯/红灯直接消费。
  Future<ImageGenHealth> checkHealth(ImageGenConfig config) async {
    final base = config.effectiveBaseUrl;
    if (!config.enabled || base.isEmpty) {
      return const ImageGenHealth(
          reachable: false,
          authorized: false,
          message: '未启用或未配置地址');
    }
    try {
      await _dio.get<dynamic>('$base/api/health',
          options: Options(
              receiveTimeout: const Duration(seconds: 6),
              sendTimeout: const Duration(seconds: 6)));
    } on DioException catch (e) {
      final ex = _fromDio(e);
      return ImageGenHealth(
          reachable: false,
          authorized: false,
          message: ex.kind == ImageGenErrorKind.timeout
              ? '服务无响应（超时）'
              : '服务不可达：${ex.message}');
    } catch (e) {
      return ImageGenHealth(
          reachable: false, authorized: false, message: '服务不可达：$e');
    }
    try {
      final resp = await _dio.get<dynamic>('$base/v1/models',
          options: Options(headers: {
            if (config.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${config.apiKey}',
          }, receiveTimeout: const Duration(seconds: 6)));
      final models = pickImageModelIds(resp.data);
      return ImageGenHealth(
          reachable: true,
          authorized: true,
          modelCount: models.length,
          models: models,
          message: models.isEmpty
              ? '已连接（未列出可用的生图模型 id）'
              : '已连接：${models.join('、')}');
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      if (code == 401 || code == 403) {
        return const ImageGenHealth(
            reachable: true,
            authorized: false,
            message: '服务可达，但 API key 无效（401）');
      }
      // /v1/models 个别网关实现缺失：health 已过即视为可用（保守放行）。
      return ImageGenHealth(
          reachable: true,
          authorized: true,
          message: '已连接（模型列表不可用：HTTP $code）');
    } catch (e) {
      return ImageGenHealth(
          reachable: true, authorized: true, message: '已连接（模型列表不可用：$e）');
    }
  }

  /// 拉服务端模型 id 列表（设置页「获取模型列表」选择用）。
  /// 失败抛 [ImageGenException]（设置页直接把 message 摆红字）。
  Future<List<String>> listModels(ImageGenConfig config) async {
    final base = config.effectiveBaseUrl;
    if (base.isEmpty) {
      throw ImageGenException(
          ImageGenErrorKind.notConfigured, '未配置服务地址（设置 → API 接入 → 图像生成）');
    }
    try {
      final resp = await _dio.get<dynamic>('$base/v1/models',
          options: Options(headers: {
            if (config.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${config.apiKey}',
          }, receiveTimeout: const Duration(seconds: 8)));
      final models = pickImageModelIds(resp.data);
      if (models.isEmpty) {
        throw ImageGenException(
            ImageGenErrorKind.decode, '服务端未列出任何模型 id');
      }
      return models;
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  /// 落盘目录：文档目录/imagegen/YYYYMMDD/（应用私有目录，用户取图走
  /// 生图卡片的「存下载/另存」按钮，与 export_file 的公共产物思路对齐）。
  /// 先只增不删（清理策略后续再定）。
  static Future<Directory> _dayDir() async {
    final override = docsDirOverride;
    final docs =
        override != null ? await override() : await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final dir = Directory(p.join(docs.path, 'imagegen', '${now.year}$mm$dd'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }
}
