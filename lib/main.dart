import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import 'package:tongyi_lite/providers/chat_provider.dart';
import 'package:tongyi_lite/services/inference_service.dart';
import 'package:tongyi_lite/services/model_manager.dart';
import 'package:tongyi_lite/services/storage_service.dart';
import 'package:tongyi_lite/screens/home_screen.dart';
import 'package:tongyi_lite/services/speech_service.dart';
import 'package:tongyi_lite/services/tts_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize native inference engine at startup
  final inference = InferenceService();
  await inference.initialize();

  // Check loaded status and memory
  final isLoaded = await inference.isLoaded();
  final memory = await inference.getMemoryInfo();
  debugPrint('[APP] Native engine loaded: $isLoaded');
  debugPrint('[APP] Memory: ${memory['usedMB']}MB / ${memory['maxMB']}MB');

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
