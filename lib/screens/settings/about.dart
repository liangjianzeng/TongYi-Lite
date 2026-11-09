part of '../settings_screen.dart';

class _buildAboutTab extends StatelessWidget {
  const _buildAboutTab();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(12),
      child: Column(
        children: [
          AboutSettingsCard(),
          SizedBox(height: 10),
          _LicenseCard(),
        ],
      ),
    );
  }
}

// About 页版本号：集中式常量，**必须与 pubspec.yaml 的 version 一致**
// （gradle 的 versionName/versionCode 已在构建期改由 pubspec 派生，见
// android/app/build.gradle.kts）。离线沙箱无法下载 package_info_plus 的
// AGP 依赖，故不引插件动态读取，直接用此常量——代价是它需要人（或发版
// 流程）手动跟上，由 test/meta/version_consistency_test.dart 钉住：
// 忘了同步=红。（历史：0.3.8/0.3.9 两次发版这里都停在 0.3.7。）
const _appVersion = '0.3.9';

/// GitHub 项目主页地址（README 介绍与使用说明）。
const _githubUrl = 'https://github.com/liangjianzeng/TongYi-Lite';

/// 通过系统外部浏览器打开 GitHub README 页面。
Future<void> _openGithub(BuildContext context) async {
  final uri = Uri.parse(_githubUrl);
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('无法打开浏览器，请手动访问：$_githubUrl')),
    );
  }
}

class AboutSettingsCard extends StatelessWidget {
  const AboutSettingsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const Icon(Icons.auto_awesome, size: 64, color: Colors.indigo),
            const SizedBox(height: 10),
            const Text(
              'TongYi-Lite',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              '端侧离线 AI 智能体',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 10),
            _AboutRow(label: '版本', value: _appVersion),
            _AboutRow(label: '推理引擎', value: 'llama.cpp b11267'),
            _AboutRow(label: '框架', value: 'Flutter 3.x'),
            _AboutRow(label: '平台', value: 'Android API 33+'),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _openGithub(context),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.open_in_new, size: 18, color: Colors.indigo),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'GitHub 项目主页 · README 介绍与使用说明',
                      style: TextStyle(
                        color: Colors.indigo,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LicenseCard extends StatelessWidget {
  const _LicenseCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('开源许可', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('MIT License'),
            const SizedBox(height: 8),
            const Text('Copyright (c) 2026 TongYi-Lite Contributors'),
            const SizedBox(height: 10),
            const Text(
              '本项目使用 llama.cpp 作为推理引擎，遵循其开源许可协议。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade700)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

