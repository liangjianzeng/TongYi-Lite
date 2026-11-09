part of '../settings_screen.dart';

Widget _buildSectionHeader(String title, BuildContext context) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

/// 标题行内嵌开关：标题 + 右侧 Switch，可选副标题。用于节省卡片纵向空间。
/// 字号紧凑（14/11），开关用 shrinkWrap 减小触点占位。
Widget _buildToggleTitle(
  String title,
  bool value,
  ValueChanged<bool> onChanged, {
  String? subtitle,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 32,
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 2),
        // 副题限高两行 + 省略号：窄面板（内容区约 192dp）里长说明不再折三五行
        // 占满整行；头部信息在前、尾部补充说明超出部分省略（全 8 处 toggle 行共用）。
        Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    ],
  );
}

// =========================================================================
// Tab 4: 智能体（Agent）
// =========================================================================

/// 通用「标签 + 滑块 + 当前值 + 提示」行，用于设置页数值型配置。
/// 紧凑排版：文字 12/11，滑块区压到 34px 高，整体比默认省 ~40% 纵向空间。
Widget _buildSliderRow({
  required String label,
  required int value,
  required int min,
  required int max,
  required int divisions,
  required String display,
  required ValueChanged<int> onChanged,
  String? hint,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Text(display,
                style:
                    const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
          ],
        ),
        SizedBox(
          height: 34,
          child: Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            // 拖动气泡与行尾一致采用格式化值（k 级），不再裸露原始数值。
            label: display,
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        if (hint != null)
          Text(hint, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    ),
  );
}

/// 卸载当前已加载模型，并弹出结果提示（成功/失败）。
/// 顶层函数：设置页（模型卡片 / 推理引擎页）均可调用。
/// 卸载完成后由 modelManagerProvider 状态变化驱动 UI 刷新（模型卡片、引擎状态卡）。
Future<void> unloadModelAndNotify(
  WidgetRef ref,
  BuildContext context,
  String modelName,
) async {
  final manager = ref.read(modelManagerProvider.notifier);
  if (manager.isBusy) return;

  final ok = await manager.unloadModel();
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(ok ? '✅ 已卸载 $modelName，已释放内存' : '❌ 卸载失败，请重试'),
      backgroundColor: ok ? Colors.green : Colors.red,
      duration: const Duration(seconds: 2),
    ),
  );
}

// =========================================================================
// Tab 2: API 接入（OpenAI 兼容远程模型）
// =========================================================================

