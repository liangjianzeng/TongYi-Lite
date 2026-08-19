import 'package:flutter/material.dart';

/// 启动画面：展示与「关于」页上半部分一致的应用 LOGO 与描述，
/// 在模型目录 / 原生引擎初始化期间显示，避免启动出现空白加载页。
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 与应用图标 / 关于页一致的主题色 LOGO
            const Icon(Icons.auto_awesome, size: 64, color: Colors.indigo),
            const SizedBox(height: 16),
            const Text(
              'TongYi-Lite',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              '端侧离线 AI 智能体',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
