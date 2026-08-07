import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/home_screen.dart';
import 'services/inference_service.dart';
import 'services/model_manager.dart';
import 'widgets/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 立即渲染启动画面（LOGO + APP 描述），避免初始化期间出现空白加载页。
  // 模型目录 / 原生引擎的初始化改在启动画面内异步进行（见 AppStartupGate）。
  runApp(
    const ProviderScope(
      child: TongYiLiteApp(),
    ),
  );
}

class TongYiLiteApp extends ConsumerWidget {
  const TongYiLiteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'TongYi-Lite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const AppStartupGate(),
    );
  }
}

/// 启动门控：先显示启动画面（LOGO + APP 描述），等模型目录与原生引擎
/// 初始化完成后切换到首页，避免启动期间出现空白加载页。
class AppStartupGate extends ConsumerStatefulWidget {
  const AppStartupGate({super.key});

  @override
  ConsumerState<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends ConsumerState<AppStartupGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 启动时加载模型下载目录（assets/models_catalog.json，可选远程热更新）。
    // 即便目录解析失败也不要让启动崩溃——降级为空列表，App 仍可运行。
    try {
      await ModelManager().init();
    } catch (e) {
      debugPrint('[Main] Failed to load model catalog, continuing with empty list: $e');
    }

    // 初始化原生推理引擎 — 必须在首次使用 llama.cpp API 前调用。
    // llama_backend_init() 是线程安全的，多次调用无副作用。
    try {
      await InferenceService().initialize();
      debugPrint('[Main] Native inference engine initialized');
    } catch (e) {
      debugPrint('[Main] Failed to initialize native engine: $e');
    }

    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return _ready ? const HomeScreen() : const SplashScreen();
  }
}
