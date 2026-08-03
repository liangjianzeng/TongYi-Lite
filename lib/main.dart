import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/home_screen.dart';
import 'services/inference_service.dart';
import 'services/model_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 启动时加载模型下载目录（assets/models_catalog.json，可选远程热更新）。
  // 加载完成后再渲染 UI，保证设置页的模型列表立即可用。
  // 即便目录解析失败也不要让启动崩溃——降级为空列表，App 仍可运行。
  try {
    await ModelManager().init();
  } catch (e) {
    debugPrint('[Main] Failed to load model catalog, continuing with empty list: $e');
  }

  // 初始化原生推理引擎 — 必须在首次使用 llama.cpp API 前调用
  // llama_backend_init() 是线程安全的，多次调用无副作用
  try {
    await InferenceService().initialize();
    debugPrint('[Main] Native inference engine initialized');
  } catch (e) {
    debugPrint('[Main] Failed to initialize native engine: $e');
  }

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
      home: const HomeScreen(),
    );
  }
}
