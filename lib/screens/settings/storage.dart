part of '../settings_screen.dart';

// =========================================================================
// 存储信息组件
// =========================================================================

class StorageInfoWidget extends ConsumerStatefulWidget {
  const StorageInfoWidget({super.key});

  @override
  ConsumerState<StorageInfoWidget> createState() => _StorageInfoWidgetState();
}

/// 存储卡（新 UI 形态）：一行摘要「N 个 · 共 X」，明细点开才展开——
/// 模型行自己就带体积，这里再平铺一份模型名/体积是重复信息。
///
/// 明细行带**按行删除**：这一行可能就是模型目录里没有的孤儿文件（换过 id 的
/// 旧模型、手工预置的包），模型管理列表里根本没有它，没有这个按钮就没人能清掉
/// 那几 GB（2026-10-30 换 Spark-X2.5→X2.6 后就留下一个 2.4GB 孤儿）。
class _StorageInfoWidgetState extends ConsumerState<StorageInfoWidget> {
  bool _detail = false;

  /// 扫描结果缓存在 state 里：以前 `future:` 直接写 `_loadStorageInfo()`，
  /// 父级每次重建都重新全盘扫一遍（删完文件想刷新还得靠重建）。
  /// 父级换 key（`_storageTick`）时本 State 重建，扫描自然跟着重来。
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadStorageInfo();
  }

  void _reload() => setState(() => _future = _loadStorageInfo());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final info = snapshot.data!;
        final cachedModels =
            (info['cachedModels'] as List? ?? []).cast<Map<String, dynamic>>();
        final totalBytes = info['totalBytes'] as int? ?? 0;

        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: cachedModels.isEmpty
                    ? null
                    : () => setState(() => _detail = !_detail),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                  child: Row(children: [
                    Icon(Icons.storage,
                        size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    const Expanded(
                        child: Text('存储空间',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500))),
                    Text('${cachedModels.length} 个 · ${_formatSize(totalBytes)}',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    if (cachedModels.isNotEmpty)
                      Icon(_detail ? Icons.expand_less : Icons.expand_more,
                          size: 16, color: scheme.outline),
                  ]),
                ),
              ),
              if (_detail)
                for (final m in cachedModels)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(36, 0, 6, 6),
                    child: Row(children: [
                      Expanded(
                          child: Text(m['name'] as String,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12))),
                      if (m['orphan'] == true)
                        Tooltip(
                          message: '不在模型目录里（换过 id 的旧模型 / 手工预置包）。\n'
                              '模型管理列表里没有它，只能从这里删。',
                          child: Icon(Icons.help_outline,
                              size: 14, color: scheme.outline),
                        ),
                      Text(_formatSize(m['sizeBytes'] as int),
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        iconSize: 17,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints:
                            const BoxConstraints(minWidth: 30, minHeight: 26),
                        color: scheme.onSurfaceVariant,
                        tooltip: '删除该模型文件（含投影器/草稿头/专家包）',
                        onPressed: () => _deleteStoredModel(m),
                      ),
                    ]),
                  ),
            ],
          ),
        );
      },
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024)
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
  }

  /// 按行删除一个模型文件：先删它本身，再按 id 清扫附属文件（mmproj 投影器 /
  /// dspark 草稿头 / 拆分专家包 / 残留 .tmp），最后让模型管理列表的「已缓存」
  /// 跟着磁盘真值走。
  ///
  /// 这一行可能是**目录里没有的孤儿文件**（换过 id 的旧模型、手工预置包），
  /// 模型管理列表里没有它 —— 这个按钮是唯一能把那几 GB 清掉的入口。
  Future<void> _deleteStoredModel(Map<String, dynamic> row) async {
    final path = row['path'] as String? ?? '';
    final id = row['id'] as String? ?? '';
    final name = row['name'] as String? ?? id;
    if (path.isEmpty || !mounted) return;

    final ms = ref.read(modelManagerProvider);
    if (id.isNotEmpty && ms.modelId == id && ms.isLoaded) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('该模型正在使用中，请先在模型管理里点「卸载」再删除'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型文件？'),
        content: Text(
          '将移除：\n${p.basename(path)}'
          '（${_formatSize(row['sizeBytes'] as int? ?? 0)}）\n\n'
          '以及它的投影器 / 草稿头 / 专家包等附属文件。之后需要重新下载才能再用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    int removed = 0;
    String? error;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        removed++;
      }
      if (id.isNotEmpty) {
        removed += (await ModelStorageService().deleteModelArtifacts(id)).length;
      }
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;

    // 模型管理列表的「已缓存」跟着磁盘真值走（删的也可能是目录里的正常模型）。
    try {
      await ref
          .read(downloadNotifierProvider.notifier)
          .refreshCacheStatus(await loadModelCatalog());
    } catch (_) {}
    if (!mounted) return;

    _reload();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error != null
          ? '删除失败：$error'
          : '已删除「$name」（$removed 个文件）'),
      backgroundColor: error != null ? Colors.orange : null,
    ));
  }

  Future<Map<String, dynamic>> _loadStorageInfo() async {
    final cachedModels = <Map<String, dynamic>>[];
    int totalBytes = 0;

    try {
      // 目录列表统一由 ModelStorageService 提供（内含 Android 路径别名去重）。
      //
      // 曾经这里自行拼三份目录：主目录 + 硬编码 `/data/data/<pkg>/app_flutter/models`
      // + `getApplicationDocumentsDirectory()/models`。而后者返回的是
      // `/data/user/0/<pkg>/app_flutter/models` —— 与前者是**同一个物理目录**
      // （同一 inode，bind mount 别名），字符串却不同，于是同一个目录被扫两遍：
      // **每个模型列出两遍、总占用翻倍**。去重已在 candidateModelDirs() 内完成。
      final dirs = await modelStorageService.candidateModelDirs();

      final seenFiles = <String>{};
      for (final dir in dirs) {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          final isGguf = entity.path.endsWith('.gguf');
          final isMmproj = entity.path.endsWith('.mmproj');
          // 投机草稿头落盘形如 `<模型id>.dspark.gguf`：它是模型的附属文件，
          // 不是独立模型。此前只按扩展名过滤，草稿头会多出一行（看起来像"双份模型"）。
          final isDspark = entity.path.endsWith('.dspark.gguf');
          if (!isGguf && !isMmproj) continue;
          // 兜底：同一物理文件的不同路径写法（别名/软链）只计一次。
          var realPath = entity.path;
          try {
            realPath = await entity.resolveSymbolicLinks();
          } catch (_) {}
          if (!seenFiles.add(ModelStorageService.pathDedupeKey(realPath))) {
            continue;
          }
          final sizeBytes = await entity.length();
          totalBytes += sizeBytes;
          // 投影器 / 草稿头只计入总量，不单列模型行。
          if (!isGguf || isDspark) continue;
          final fileName = p.basenameWithoutExtension(entity.path);

          String displayName = fileName;
          // 「目录里没有」= 孤儿文件（换过 id 的旧模型 / 手工预置包），明细行
          // 给个 ? 角标，说明它为什么在模型管理列表里找不到。
          var orphan = false;
          try {
            final allModels = await loadModelCatalog();
            final match = allModels.where((m) => m.id == fileName).toList();
            if (match.isNotEmpty) {
              displayName = match.first.name;
            } else {
              orphan = true;
            }
          } catch (_) {}

          cachedModels.add({
            'name': displayName,
            'id': fileName,
            'path': entity.path,
            'sizeBytes': sizeBytes,
            'orphan': orphan,
          });
        }
      }
    } catch (e) {
      debugPrint('[Settings] Failed to scan storage: $e');
    }

    return {'cachedModels': cachedModels, 'totalBytes': totalBytes};
  }
}

// =========================================================================
// 最近日志组件（在推理引擎 Tab 显示）
// =========================================================================

class RecentLogsWidget extends ConsumerWidget {
  const RecentLogsWidget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(modelManagerProvider.notifier);
    final logs = manager.loadingLogs;

    if (logs.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8)),
        child: const Center(
          child: Column(
            children: [
              Icon(Icons.help_outline, size: 48, color: Colors.grey),
              SizedBox(height: 8),
              Text('暂无日志', style: TextStyle(color: Colors.grey)),
              SizedBox(height: 4),
              Text('点模型列表里的「加载」后开始记录',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[index];
          IconData icon;
          Color color;

          if (log.contains('✓') || log.contains('成功')) {
            icon = Icons.check_circle;
            color = Colors.green;
          } else if (log.contains('失败') ||
              log.contains('错误') ||
              log.contains('ERROR')) {
            icon = Icons.error;
            color = Colors.red;
          } else {
            icon = Icons.terminal;
            color = Colors.blueGrey;
          }

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    log,
                    style: TextStyle(
                        fontSize: 12,
                        color: color.withValues(alpha: 0.9),
                        fontFamily: 'monospace'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// =========================================================================
// 自定义模型显示名称输入框（可选）
// =========================================================================

/// 自定义模型显示名称输入框（可选）。
/// 用 StatefulWidget 持有独立的 TextEditingController，
/// 使下载进度频繁重建时不会丢失输入焦点/光标。
/// 模型名内联编辑框（替换原独立「自定义名称」行）。
/// 直接显示在模型卡片标题位置：有自定义名则显示自定义名，否则显示模型配置名
/// 加载模型时的「加载中」对话框。
/// 监听 [modelManagerProvider]，实时展示原生层推送的最新加载日志，
/// 让用户清楚大模型（数 GB）加载的进展，避免误以为卡死。
class _ModelLoadProgressDialog extends ConsumerWidget {
  final String modelName;
  const _ModelLoadProgressDialog({required this.modelName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms = ref.watch(modelManagerProvider);
    final log = ms.latestLog;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 10),
              Text('正在加载模型…', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(modelName,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              if (log != null)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      log,
                      style:
                          TextStyle(fontSize: 12, color: Colors.blue.shade800),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

