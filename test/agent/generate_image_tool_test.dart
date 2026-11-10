// generate_image 工具（能力移植自汪柴 WangCai）单测：注册门控 / schema
// 契约 / 执行链（缺参 → 未配置 → 成功回调落库钩子）+ listModels（设置页
// 模型下拉数据源，用户 2026-11-10 定案：选模型名而非填目录）。服务经注入
// 的 fake / 假 HttpClientAdapter 隔离网络。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/builtin_tools/builtin_tools.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/services/image_gen_service.dart';

/// fake 服务：继承真实类覆写 generate（工具的 service 注入口为具体类型）。
class _FakeSvc extends ImageGenService {
  _FakeSvc({this.result}) : super(dio: Dio());

  ImageGenResult? result;
  ImageGenConfig? lastConfig;
  String? lastPrompt;

  @override
  Future<ImageGenResult> generate({
    required ImageGenConfig config,
    required String prompt,
    String? size,
    String? negative,
    int? seed,
    int n = 1,
  }) async {
    lastConfig = config;
    lastPrompt = prompt;
    final r = result!;
    return ImageGenResult(paths: r.paths, seed: r.seed, size: r.size, ms: r.ms);
  }
}

class _FailingSvc extends ImageGenService {
  _FailingSvc() : super(dio: Dio());

  @override
  Future<ImageGenResult> generate({
    required ImageGenConfig config,
    required String prompt,
    String? size,
    String? negative,
    int? seed,
    int n = 1,
  }) async {
    throw ImageGenException(
        ImageGenErrorKind.unauthorized, '鉴权失败（API key 错误或已吊销）');
  }
}

/// 假适配器：按预设 status/body 应答 /v1/models，记录请求 URL 与头。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.status = 200, this.body, this.connectionError = false});

  final int status;
  final dynamic body;
  final bool connectionError;

  String? lastUrl;
  Map<String, dynamic> lastHeaders = const {};

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<dynamic>? cancelFuture) async {
    lastUrl = options.uri.toString();
    lastHeaders = Map<String, dynamic>.of(options.headers);
    if (connectionError) {
      throw DioException(
          type: DioExceptionType.connectionError, requestOptions: options);
    }
    return ResponseBody.fromString(
      jsonEncode(body ?? {'data': []}),
      status,
      headers: {
        HttpHeaders.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ImageGenService _svcWithAdapter(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 1)));
  dio.httpClientAdapter = adapter;
  return ImageGenService(dio: dio);
}

void main() {
  group('注册门控（照 weather/web_search 先例）', () {
    test('默认（未传 loader）→ createBuiltinTools 不含 generate_image', () {
      final tools = createBuiltinTools();
      expect(tools.any((t) => t.name == 'generate_image'), isFalse);
    });

    test('传 loader → 注册；独占执行 + 6 分钟预算 + 必填 prompt', () {
      final tools = createBuiltinTools(
          imageGenConfigLoader: () async =>
              const ImageGenConfig(enabled: true, baseUrl: 'http://x'));
      final tool = tools.firstWhere((t) => t.name == 'generate_image');
      expect(tool.isConcurrencySafe!.call(const {}), isFalse,
          reason: '单卡串行：独占执行（同 export_file）');
      expect(tool.timeout, const Duration(minutes: 6));
      final required = (tool.parameters['required'] as List).cast<String>();
      expect(required, contains('prompt'));
      // 描述引导模型使用时机与耗时预期。
      expect(tool.description, contains('生成图片'));
      expect(tool.description, contains('2 分钟'));
    });

    test('generate_image 在 kOptionalToolNames（默认关名单）内', () {
      expect(kOptionalToolNames, contains('generate_image'));
    });
  });

  group('执行链', () {
    ToolDefinition toolWith(
            _FakeSvc svc, List<ImageGenResult>? onGen) =>
        createGenerateImageTool(
          configLoader: () async =>
              const ImageGenConfig(enabled: true, baseUrl: 'http://x'),
          service: svc,
          onGenerated: (r, p, m) => onGen?.add(r),
        );

    test('缺 prompt → 可读错误（validate 前的工具自检）', () async {
      final tool = toolWith(_FakeSvc(), null);
      final r = await tool.execute(const {'size': '1024x1024'});
      expect(r.isError, isTrue);
      expect(r.content, contains('prompt'));
    });

    test('成功：返回路径与 seed/尺寸/耗时，onGenerated 带模型名回调', () async {
      final calls = <ImageGenResult>[];
      final svc = _FakeSvc(
          result: const ImageGenResult(
              paths: ['/tmp/a.png', '/tmp/b.png'],
              seed: 7,
              size: '2048x2048',
              ms: 123456));
      final tool = toolWith(svc, calls);
      final r = await tool.execute({
        'prompt': '赛博朋克柴犬',
        'size': '2048x2048',
        'n': 2,
        'seed': 7,
      });
      expect(r.isError, isFalse);
      expect(r.content, contains('/tmp/a.png'));
      expect(r.content, contains('/tmp/b.png'));
      expect(r.content, contains('2048x2048'));
      expect(r.content, contains('seed 7'));
      expect(svc.lastPrompt, '赛博朋克柴犬');
      expect(calls, hasLength(1));
      expect(svc.lastConfig!.effectiveBaseUrl, 'http://x');
    });

    test('服务抛 ImageGenException → 错误文本给模型（不抛出）', () async {
      final tool = createGenerateImageTool(
        configLoader: () async =>
            const ImageGenConfig(enabled: true, baseUrl: 'http://x'),
        service: _FailingSvc(),
      );
      final r = await tool.execute({'prompt': '随便画'});
      expect(r.isError, isTrue);
      expect(r.content, contains('鉴权失败'));
    });
  });

  group('ImageGenConfig 口径（移动端适配）', () {
    test('空地址 = 未配置（手机无 127.0.0.1 回落）', () {
      const c = ImageGenConfig(enabled: true, baseUrl: '  ');
      expect(c.effectiveBaseUrl, isEmpty);
      expect(c.isConfigured, isFalse);
    });

    test('尾斜杠剥除；脏尺寸回落 1024x1024', () {
      const c = ImageGenConfig(
          enabled: true,
          baseUrl: 'http://192.168.1.5:8888/',
          defaultSize: '800x600');
      expect(c.effectiveBaseUrl, 'http://192.168.1.5:8888');
      expect(c.isConfigured, isTrue);
      expect(c.effectiveSize, '1024x1024');
    });

    test('未启用 → isConfigured false（工具报"未启用"文案的判据）', () {
      const c =
          ImageGenConfig(enabled: false, baseUrl: 'http://192.168.1.5:8888');
      expect(c.isConfigured, isFalse);
    });

    test('超时按尺寸分档：≥2048 → 300s，其余 120s', () {
      expect(ImageGenService.timeoutForSize('2048x2048'),
          const Duration(seconds: 300));
      expect(ImageGenService.timeoutForSize('1024x1024'),
          const Duration(seconds: 120));
      expect(ImageGenService.timeoutForSize('1440x1440'),
          const Duration(seconds: 120));
    });
  });

  group('parseImageSlash（/图 聊天直达口令，P2）', () {
    test('非命中零干扰：普通消息 / 前缀粘连 / 句中斜杠', () {
      expect(parseImageSlash('帮我画只柴犬'), isNull);
      expect(parseImageSlash('/图片真好看'), isNull, reason: '「/图片」不是口令');
      expect(parseImageSlash('参考这个 /图 提示词'), isNull, reason: '行首才算');
      expect(parseImageSlash('/tuzi 跑'), isNull);
      expect(parseImageSlash(''), isNull);
    });

    test('命中：空格/换行/全角空格/裸口令（空提示词留给用法提示）', () {
      final a = parseImageSlash('/图 赛博朋克柴犬')!;
      expect(a.prompt, '赛博朋克柴犬');
      expect(a.size, isNull);
      expect(parseImageSlash('/图\n海报草稿')!.prompt, '海报草稿');
      expect(parseImageSlash('/图　海报草稿')!.prompt, '海报草稿');
      expect(parseImageSlash('/图')!.prompt, isEmpty);
      expect(parseImageSlash('  /图  柴犬  ')!.prompt, '柴犬',
          reason: '首尾空白先 trim');
    });

    test('尾部尺寸口令：尺寸/size/@ 变体剥离并显式生效', () {
      final a = parseImageSlash('/图 新年海报，尺寸 2048x2048')!;
      expect(a.prompt, '新年海报');
      expect(a.size, '2048x2048');
      expect(parseImageSlash('/图 海报 size:1024x1024')!.size, '1024x1024');
      expect(parseImageSlash('/图 海报 @512x512')!.size, '512x512');
      expect(parseImageSlash('/图 海报 1440x1440')!.size, '1440x1440',
          reason: '裸档位尾部也认');
    });

    test('非档位尺寸留在提示词原文（不当尺寸吞掉）', () {
      final a = parseImageSlash('/图 画一面 999x999 的砖墙')!;
      expect(a.size, isNull);
      expect(a.prompt, contains('999x999'));
    });
  });

  group('listModels（设置页模型下拉数据源）', () {
    const modelsBody = {
      'data': [
        {'id': 'Qwen3-VL-8B-Instruct-UD-Q4_K_XL', 'task': 'chat'},
        {'id': 'qwen-image-2.1-turbo-Q5_K_M', 'task': 'text-to-image'},
      ],
    };

    test('pickImageModelIds：优先 task=text-to-image；无 task 字段回退全量', () {
      expect(pickImageModelIds(modelsBody), ['qwen-image-2.1-turbo-Q5_K_M']);
      expect(
        pickImageModelIds({
          'data': [
            {'id': 'a'},
            {'id': 'b'},
          ]
        }),
        ['a', 'b'],
      );
      // 非 Map / 无 data / id 非字符串 → 空（脏响应不崩）。
      expect(pickImageModelIds(null), isEmpty);
      expect(pickImageModelIds({'data': 'x'}), isEmpty);
      expect(pickImageModelIds({
        'data': [
          {'id': 42},
          {'id': ''},
          'junk',
        ]
      }), isEmpty);
    });

    test('成功：GET /v1/models 带 Bearer，返回 t2i id 列表', () async {
      final adapter = _FakeAdapter(body: modelsBody);
      final models = await _svcWithAdapter(adapter).listModels(
          const ImageGenConfig(
              enabled: true,
              baseUrl: 'https://liang-geekpro.tailfe4bdd.ts.net:8888/',
              apiKey: 'sk-test'));
      expect(models, ['qwen-image-2.1-turbo-Q5_K_M']);
      expect(adapter.lastUrl,
          'https://liang-geekpro.tailfe4bdd.ts.net:8888/v1/models');
      expect(adapter.lastHeaders['Authorization'], 'Bearer sk-test');
    });

    test('无 key 配置不发 Authorization 头（无鉴权实例可直连）', () async {
      final adapter = _FakeAdapter(body: modelsBody);
      await _svcWithAdapter(adapter).listModels(
          const ImageGenConfig(enabled: true, baseUrl: 'http://192.168.1.5:8888'));
      expect(adapter.lastHeaders.containsKey('Authorization'), isFalse);
    });

    test('空地址 → notConfigured（不发出请求）', () async {
      final adapter = _FakeAdapter(body: modelsBody);
      await expectLater(
        _svcWithAdapter(adapter).listModels(
            const ImageGenConfig(enabled: true, baseUrl: '')),
        throwsA(isA<ImageGenException>()
            .having((e) => e.kind, 'kind', ImageGenErrorKind.notConfigured)),
      );
      expect(adapter.lastUrl, isNull);
    });

    test('服务端空列表 → decode 错误（下拉无从填充，红字提示）', () async {
      final adapter = _FakeAdapter(body: {'data': []});
      await expectLater(
        _svcWithAdapter(adapter).listModels(
            const ImageGenConfig(enabled: true, baseUrl: 'http://x:8888')),
        throwsA(isA<ImageGenException>()
            .having((e) => e.kind, 'kind', ImageGenErrorKind.decode)),
      );
    });

    test('401 → unauthorized（key 错，设置页红字口径）', () async {
      final adapter = _FakeAdapter(status: 401, body: {'error': 'bad key'});
      await expectLater(
        _svcWithAdapter(adapter).listModels(const ImageGenConfig(
            enabled: true, baseUrl: 'http://x:8888', apiKey: 'sk-wrong')),
        throwsA(isA<ImageGenException>()
            .having((e) => e.kind, 'kind', ImageGenErrorKind.unauthorized)),
      );
    });

    test('连接失败 → unreachable（含 Tailscale 未连提示口径）', () async {
      final adapter = _FakeAdapter(connectionError: true);
      await expectLater(
        _svcWithAdapter(adapter).listModels(
            const ImageGenConfig(enabled: true, baseUrl: 'http://x:8888')),
        throwsA(isA<ImageGenException>().having(
            (e) => e.kind, 'kind', ImageGenErrorKind.unreachable)),
      );
    });
  });
}
