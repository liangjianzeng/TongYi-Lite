import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/home_screen.dart';
import 'services/model_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 启动时加载模型下载目录（assets/models_catalog.json，可选远程热更新）。
  // 加载完成后再渲染 UI，保证设置页的模型列表立即可用。
  await ModelManager().init();

  // NOTE: Native engine initialization happens inside InferenceService
  // singleton on first use — NOT here. Calling native methods at startup
  // blocks the UI thread and type-mismatches across MethodChannel crash the
  // app before any widget is rendered.

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
