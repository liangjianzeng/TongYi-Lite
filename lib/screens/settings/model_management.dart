part of '../settings_screen.dart';

/// 模型管理面板 Body（2026-10-25 自 _SettingsScreenState 原样抽出：
/// 模型列表/下载/续传/加载/删除/默认开关），供左栏「模型」面板直嵌；
/// 老设置页 Tab1 也复用同一 Body，行为不变。
class ModelManagementBody extends ConsumerStatefulWidget {
  const ModelManagementBody();

  @override
  ConsumerState<ModelManagementBody> createState() =>
      _ModelManagementBodyState();
}

class _ModelManagementBodyState extends ConsumerState<ModelManagementBody> {
  late final Future<List<ModelConfig>> _catalogFuture;

  /// 存储占用信息的重建 tick：任一模型下载完成后自增，迫使 StorageInfoWidget
  /// 重新拉取磁盘占用（它用 FutureBuilder 只拉一次）。
  int _storageTick = 0;

  @override
  void initState() {
    super.initState();
    _catalogFuture = loadModelCatalog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // APP 启动后首次进入「模型管理」做一次全盘扫描；之后进出 tab 只做
      // 轻量校验（对已知 id 做 File.exists，无目录遍历、无提示）。
      if (_appLaunchScanDone) {
        _refreshCacheStatus();
      } else {
        _appLaunchScanDone = true;
        _scanModels(silent: true);
      }
    });
  }

  /// 轻量缓存状态校验：只对目录内已知 id 的 .gguf 做存在性判断，
  /// 用于纠正「文件已在磁盘但界面仍显示未下载」以及「文件被外部删除但
  /// 界面仍显示已缓存」两种不一致。开销极小，可每次进入页面执行。
  Future<void> _refreshCacheStatus() async {
    try {
      final catalog = await _catalogFuture;
      if (!mounted) return;
      await ref
          .read(downloadNotifierProvider.notifier)
          .refreshCacheStatus(catalog);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // 全局监听下载状态：任一模型下载完成 → 立即整体重扫模型列表 + 刷新存储
    // 占用，而不是只更新刚完成的那个模型卡片（否则列表排序/存储统计会滞后）。
    ref.listen<Map<String, DownloadTask>>(downloadNotifierProvider,
        (prev, next) {
      bool anyCompleted = false;
      for (final e in next.entries) {
        if (e.value.state == DownloadState.completed &&
            prev?[e.key]?.state != DownloadState.completed) {
          anyCompleted = true;
          break;
        }
      }
      if (anyCompleted) {
        _storageTick++;
        _scanModels(silent: true);
      }
    });
    return _buildModelManagementTab();
  }

  // =========================================================================
  // Tab 1 / 模型面板：模型列表
  //
  // 2026-10-28 按新 UI 语言重排（对齐 home_screen 左栏面板「p-card」密度：
  // 行高 ~40、字号 13/11、图标 18、卡面 surfaceContainerHigh + outlineVariant
  // 细描边，明暗两套全走 colorScheme，不再 Colors.blue.shade50 硬涂）：
  // 旧形态每个模型是一张 Card（头部行 + chip 行 + 最多三个 48dp Switch 行 +
  // 三个等分按钮行），22 个模型滚不到头。现在——
  //   · 主行 = 状态图标 + 模型名（窄栏可换两行，2026-10-25 定案不许截断）
  //     + 默认星标 + **一个**主操作按钮；
  //   · 次行只在「有信息要讲」时出现：未下载 → 体积与特性、下载中 → 进度、
  //     失败 → 错误原因；已缓存模型就占一行；
  //   · 次要配置（图片理解 / MTP / dspark / 删除）收进点开的展开区；
  //   · 说明性长文案（扫描提示、视觉塔省 0.9GB）撤下，改由 tooltip 承载。
  // =========================================================================

  /// 展开态（modelId 集合）：次要配置默认收起，列表保持一行/模型。
  final Set<String> _expanded = {};

  void _toggleExpanded(String id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
  }

  Widget _buildModelManagementTab() {
    final tasks = ref.watch(downloadNotifierProvider);
    final settings = ref.watch(settingsProvider);
    final ms = ref.watch(modelManagerProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 扫描入口收成小节标题右侧的图标钮（原来是置顶一颗大 ElevatedButton
          // + 下面一行灰字说明，两行高度换一个低频动作）。
          _sectionHeader('可用模型', trailing: [
            _iconAction(Icons.refresh, '扫描已有模型（启动时已自动扫一次）',
                () => _scanModels()),
          ]),
          FutureBuilder<List<ModelConfig>>(
            future: _catalogFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              // 先按族归组（同族量化折叠为一行，见 model_family.dart），再对
              // 「行」排序——排序规则不变：已缓存最优先在前；未下载的按名称
              // 首字母排序（A→Z）。族行的缓存判定是行内任一档位已缓存。
              final rowsData = buildModelRows(snapshot.data!);
              bool rowCached(ModelListRow r) => switch (r) {
                    SingleModelRow(:final model) =>
                      tasks[model.id]?.state == DownloadState.completed,
                    FamilyModelRow(:final family) => family.variants.any(
                        (v) => tasks[v.id]?.state == DownloadState.completed),
                  };
              String rowName(ModelListRow r) => switch (r) {
                    SingleModelRow(:final model) => cleanModelName(model.name),
                    FamilyModelRow(:final family) => cleanModelName(family.name),
                  }.toLowerCase();
              rowsData.sort((a, b) {
                final ca = rowCached(a);
                final cb = rowCached(b);
                if (ca != cb) return ca ? -1 : 1;
                return rowName(a).compareTo(rowName(b));
              });
              final cachedCount = rowsData.where(rowCached).length;
              final rows = <Widget>[];
              for (var i = 0; i < rowsData.length; i++) {
                // 已缓存块与未下载块之间插一条分组标签，长列表有个分段感。
                if (i == cachedCount && cachedCount > 0) {
                  rows.add(_groupLabel('未下载'));
                }
                final r = rowsData[i];
                switch (r) {
                  case SingleModelRow(:final model):
                    rows.add(_modelRow(model, tasks[model.id], settings, ms));
                  case FamilyModelRow(:final family):
                    rows.add(_familyRow(family, tasks, settings, ms));
                }
              }
              return Column(children: rows);
            },
          ),
          const SizedBox(height: 10),
          // 存储信息（自带标题行，不再另加小节头）。用 tick 作 key：任一模型
          // 下载完成时强制重建，重新读磁盘占用。
          StorageInfoWidget(key: ValueKey(_storageTick)),
        ],
      ),
    );
  }

  /// 小节标题（11px 灰 w600，与左栏面板同一密度）。
  Widget _sectionHeader(String label, {List<Widget> trailing = const []}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        ...trailing,
      ]),
    );
  }

  /// 分组标签（「未下载」）——比小节标题更轻一档，只做分段。
  Widget _groupLabel(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 3),
        child: Text(label,
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.4,
                color: Theme.of(context).colorScheme.outline)),
      );

  /// 轻量图标钮（扫描这类低频动作，不给大按钮）。
  Widget _iconAction(
      IconData icon, String tooltip, VoidCallback? onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// 行首状态图标（_modelRow / _familyRow 共用）：图形 + 颜色表达
  /// 已加载 / 加载中 / 下载中 / 暂停 / 失败 / 已缓存 / 待下载。
  (IconData, Color) _rowLeadIcon(
    ColorScheme scheme, {
    required bool isLoadedHere,
    required bool isLoadingHere,
    required DownloadState state,
    required bool isCached,
  }) {
    if (isLoadedHere) return (Icons.bolt, scheme.primary);
    if (isLoadingHere) return (Icons.sync_alt, scheme.primary);
    if (state == DownloadState.downloading ||
        state == DownloadState.verifying) {
      return (Icons.download, Colors.blue);
    }
    if (state == DownloadState.paused) {
      return (Icons.pause_circle_outline, Colors.orange);
    }
    if (state == DownloadState.failed) return (Icons.error_outline, Colors.red);
    if (isCached) return (Icons.check_circle_outline, Colors.green);
    return (Icons.cloud_download_outlined, scheme.outline);
  }

  /// 单个模型的一行（+ 可选次行 / 展开区）。
  Widget _modelRow(ModelConfig model, DownloadTask? task,
      InferenceSettings settings, ModelState ms) {
    final scheme = Theme.of(context).colorScheme;
    final isCached = task?.state == DownloadState.completed;
    final isLoadingHere = ms.isLoading && ms.modelId == model.id;
    final isLoadedHere = ms.modelId == model.id && ms.isLoaded;
    final isDefault = settings.defaultModelId == model.id;
    final expanded = _expanded.contains(model.id);
    final DownloadState state;
    if (task != null &&
        (task.state == DownloadState.downloading ||
            task.state == DownloadState.paused ||
            task.state == DownloadState.failed ||
            task.state == DownloadState.verifying)) {
      state = task.state;
    } else {
      state = isCached ? DownloadState.completed : DownloadState.idle;
    }

    // 状态全靠「图标颜色 + 主操作文案」表达，不再叠「已缓存 / 待下载」chip。
    final (leadIcon, leadColor) = _rowLeadIcon(scheme,
        isLoadedHere: isLoadedHere,
        isLoadingHere: isLoadingHere,
        state: state,
        isCached: isCached);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isLoadedHere
            ? scheme.secondaryContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLoadedHere
              ? scheme.primary.withValues(alpha: 0.5)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 主行 ----
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _toggleExpanded(model.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(leadIcon, size: 18, color: leadColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cleanModelName(model.name),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (model.type == ModelType.vision) ...[
                    const SizedBox(width: 4),
                    const Tooltip(
                      message: '支持图片理解（视觉模型）',
                      child: Icon(Icons.visibility_outlined,
                          size: 14, color: Colors.grey),
                    ),
                  ],
                  // 默认模型星标：点一下 = 设为/取消「启动自动加载」的默认模型
                  // （原来是一颗 Checkbox + 「默认」二字，占宽且语义不直白）。
                  if (isCached)
                    Tooltip(
                      message: isDefault
                          ? '启动时自动加载（当前默认模型），点按取消'
                          : '设为默认：启动时自动加载',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .setDefaultModel(isDefault ? null : model.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Icon(
                            isDefault
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 18,
                            color: isDefault
                                ? Colors.amber.shade700
                                : scheme.outline,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 2),
                  _buildActionButton(model, state, isCached,
                      isLoadedHere: isLoadedHere,
                      isLoadingHere: isLoadingHere),
                ],
              ),
            ),
          ),

          // ---- 次行（只在该说点什么时出现）----
          // 展开态让位给展开区：那里用**同一个**渲染点画体积+标签，两边都画
          // 就是上下两行一模一样的内容（2026-10-30 反馈：未下载模型描述重复）。
          if (!isCached &&
                !expanded &&
                (state == DownloadState.idle ||
                    state == DownloadState.failed)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 12, 7),
              child: _modelMetaLine(
                model,
                failedMessage: state == DownloadState.failed
                    ? (task?.errorMessage ?? '下载失败')
                    : null,
              ),
            ),
          ] else if (state == DownloadState.downloading ||
              state == DownloadState.verifying ||
              state == DownloadState.paused) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                      value: task?.progress,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _progressLabel(state, task),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant),
                        ),
                      ),
                      Text(
                        '${task?.downloadedDisplay ?? '-'} / ${task?.totalDisplay ?? '-'} · ${task?.progressPercent ?? ''}',
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          // ---- 展开区：次要配置与危险动作 ----
          if (expanded) _buildExpandArea(model, settings, state, isCached),
        ],
      ),
    );
  }

  /// 模型族的一行（同基础模型多量化折叠，2026-11-08）：主行 = 状态图标 +
  /// 族名 + 当前量化档 chip + 主操作按钮，全部绑定 resolveSelectedVariant
  /// 选中的档位；展开区顶部是量化选择列表（点选即持久化），其余控件复用
  /// [_buildExpandArea]（同样绑定选中档位）。展开 key 用 `family:` 前缀，
  /// 避免与 variant id 撞车。
  Widget _familyRow(ModelFamily family, Map<String, DownloadTask> tasks,
      InferenceSettings settings, ModelState ms) {
    final scheme = Theme.of(context).colorScheme;
    final selected = resolveSelectedVariant(family, settings);
    final task = tasks[selected.id];
    final isCached = task?.state == DownloadState.completed;
    final isLoadingHere = ms.isLoading && ms.modelId == selected.id;
    final isLoadedHere = ms.modelId == selected.id && ms.isLoaded;
    final isDefault = settings.defaultModelId == selected.id;
    final expandKey = 'family:${family.familyId}';
    final expanded = _expanded.contains(expandKey);
    final DownloadState state;
    if (task != null &&
        (task.state == DownloadState.downloading ||
            task.state == DownloadState.paused ||
            task.state == DownloadState.failed ||
            task.state == DownloadState.verifying)) {
      state = task.state;
    } else {
      state = isCached ? DownloadState.completed : DownloadState.idle;
    }
    final (leadIcon, leadColor) = _rowLeadIcon(scheme,
        isLoadedHere: isLoadedHere,
        isLoadingHere: isLoadingHere,
        state: state,
        isCached: isCached);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isLoadedHere
            ? scheme.secondaryContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLoadedHere
              ? scheme.primary.withValues(alpha: 0.5)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 主行 ----
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _toggleExpanded(expandKey),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(leadIcon, size: 18, color: leadColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            cleanModelName(family.name),
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 当前量化档 chip：不展开也能看到选了哪档。
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer
                                .withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            selected.quantLabel ?? family.variants.first.id,
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSecondaryContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 默认星标：绑定选中档位（点按 = 设/取消启动自动加载）。
                  if (isCached)
                    Tooltip(
                      message: isDefault
                          ? '启动时自动加载（当前默认模型），点按取消'
                          : '设为默认：启动时自动加载',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .setDefaultModel(isDefault ? null : selected.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Icon(
                            isDefault
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 18,
                            color: isDefault
                                ? Colors.amber.shade700
                                : scheme.outline,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 2),
                  _buildActionButton(selected, state, isCached,
                      isLoadedHere: isLoadedHere,
                      isLoadingHere: isLoadingHere),
                ],
              ),
            ),
          ),

          // ---- 次行（与 _modelRow 同规则：只在该说点什么时出现）----
          if (!isCached &&
                !expanded &&
                (state == DownloadState.idle ||
                    state == DownloadState.failed)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 12, 7),
              child: _modelMetaLine(
                selected,
                failedMessage: state == DownloadState.failed
                    ? (task?.errorMessage ?? '下载失败')
                    : null,
              ),
            ),
          ] else if (state == DownloadState.downloading ||
              state == DownloadState.verifying ||
              state == DownloadState.paused) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                      value: task?.progress,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _progressLabel(state, task),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                      ),
                      Text(
                        '${task?.downloadedDisplay ?? '-'} / ${task?.totalDisplay ?? '-'} · ${task?.progressPercent ?? ''}',
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          // ---- 展开区：量化选择 + 次要配置与危险动作（绑定选中档位）----
          if (expanded) ...[
            _buildQuantSelector(family, selected, tasks),
            _buildExpandArea(selected, settings, state, isCached),
          ],
        ],
      ),
    );
  }

  /// 量化选择列表（展开区顶部）：每档一行 = 单选钮 + 档位标签 + 体积 + 状态。
  /// 点击即选中并持久化（setQuantChoice，下次进入无需再选）；已缓存且非当前
  /// 档的行给一颗删除钮，清理切档后遗留的旧文件。
  Widget _buildQuantSelector(ModelFamily family, ModelConfig selected,
      Map<String, DownloadTask> tasks) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '量化档位（默认最小档，选择会被记住）',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant),
            ),
          ),
          for (final v in family.variants)
            _quantOptionRow(family, v, v.id == selected.id, tasks[v.id]),
        ],
      ),
    );
  }

  /// 单个量化档位选项行。
  Widget _quantOptionRow(ModelFamily family, ModelConfig v, bool isSelected,
      DownloadTask? task) {
    final scheme = Theme.of(context).colorScheme;
    final isCached = task?.state == DownloadState.completed;
    final busy = task != null &&
        (task.state == DownloadState.downloading ||
            task.state == DownloadState.paused ||
            task.state == DownloadState.verifying);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => ref
          .read(settingsProvider.notifier)
          .setQuantChoice(family.familyId, v.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 15,
              color: isSelected ? scheme.primary : scheme.outline,
            ),
            const SizedBox(width: 8),
            Text(
              v.quantLabel ?? v.id,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400),
            ),
            const SizedBox(width: 8),
            Text(v.sizeMBDisplay,
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const Spacer(),
            if (task != null && busy)
              Text('下载中 ${task.progressPercent}',
                  style: const TextStyle(fontSize: 11, color: Colors.blue))
            else if (isCached)
              Text('已缓存',
                  style:
                      TextStyle(fontSize: 11, color: Colors.green.shade700)),
            if (isCached && !isSelected) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: '删除该档位文件（清理切档后不再使用的旧文件）',
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _confirmDeleteModel(v, context),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(Icons.delete_outline,
                        size: 15, color: Colors.red.shade600),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 下载次行的状态文字：档位前缀 + 当前阶段（多文件模型有 主模型/投影器/加速头）。
  String _progressLabel(DownloadState state, DownloadTask? task) {
    final prefix = state == DownloadState.paused
        ? '已暂停'
        : (state == DownloadState.verifying ? '校验中' : '下载中');
    final stage = task?.stage;
    return stage == null || stage.isEmpty ? prefix : '$prefix · $stage';
  }

  /// 主操作按钮：一个模型只留一颗（加载/下载/暂停/继续/重试）。
  ///
  /// 「加载到内存」→「加载」：这一列里能点的就是它，不必把话说全（2026-10-28
  /// 用户指令：列表太臃肿）；旧「下载＋含投影器」那颗同理——投影器要不要补下，
  /// 下载阶段那行已经写清楚了。（注释里刻意不写原字面量：doc 注释会进 debug
  /// kernel_blob，字符串级验收时会被当成"旧 UI 幽灵"误报。）
  Widget _buildActionButton(
    ModelConfig model,
    DownloadState state,
    bool isCached, {
    required bool isLoadedHere,
    required bool isLoadingHere,
  }) {
    final manager = ref.read(modelManagerProvider.notifier);
    if (state == DownloadState.downloading) {
      return _actionButton(
          label: '暂停',
          onPressed: () =>
              ref.read(downloadNotifierProvider.notifier).pauseDownload(model.id));
    }
    if (state == DownloadState.paused) {
      return _actionButton(
          label: '继续',
          tone: true,
          onPressed: () => _resumeDownloadAndRescan(model.id));
    }
    if (state == DownloadState.failed) {
      return _actionButton(
          label: '重试',
          foreground: Colors.red.shade600,
          onPressed: () => _startDownloadAndRescan(model));
    }
    if (state == DownloadState.verifying) {
      return _actionButton(label: '校验中', onPressed: null);
    }
    if (!isCached) {
      return _actionButton(
          label: '下载',
          tone: true,
          onPressed: () => _startDownloadAndRescan(model));
    }
    if (isLoadingHere) {
      return _actionButton(
          label: '加载中',
          onPressed: null,
          icon: const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (isLoadedHere) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _actionButton(
              label: '已加载',
              onPressed: null,
              tone: true,
              foreground: Colors.green.shade700),
          const SizedBox(width: 4),
          _actionButton(
              label: '卸载',
              foreground: Colors.red.shade600,
              onPressed: manager.isBusy
                  ? null
                  : () => unloadModelAndNotify(ref, context, model.name)),
        ],
      );
    }
    return _actionButton(
        label: '加载',
        tone: true,
        onPressed: manager.isBusy ? null : () => _handleLoadModel(model));
  }

  /// 紧凑按钮（高 30 / 字号 12 / 圆角 8）：tone=true 为 tonal 主操作。
  Widget _actionButton({
    required String label,
    VoidCallback? onPressed,
    bool tone = false,
    Color? foreground,
    Widget? icon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foreground ??
        (tone ? scheme.onSecondaryContainer : scheme.onSurfaceVariant);
    return OutlinedButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 11)),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8))),
        backgroundColor: WidgetStatePropertyAll(
            tone ? scheme.secondaryContainer.withValues(alpha: 0.8) : null),
        foregroundColor: WidgetStatePropertyAll(fg),
        side: WidgetStatePropertyAll(BorderSide(
            color: tone ? Colors.transparent : scheme.outlineVariant)),
      ),
      child: icon == null
          ? Text(label)
          : Row(mainAxisSize: MainAxisSize.min, children: [
              icon,
              const SizedBox(width: 5),
              Text(label),
            ]),
    );
  }

  /// 展开区：体积/全量特性 + 逐项开关 + 删除。
  Widget _buildExpandArea(
      ModelConfig model, InferenceSettings settings, DownloadState state, bool isCached) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 体积 + 特性标签全量：折叠态那行在这里接管（同一渲染点、同一缩进），
          // 展开只是把标签补全，不再重复画一遍。
          _modelMetaLine(model, expanded: true),
          const SizedBox(height: 4),
          if (isCached)
            _switchRow(
              label: '设为默认',
              tooltip: '勾选后 APP 启动进入首页时自动加载该模型',
              value: settings.defaultModelId == model.id,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setDefaultModel(v == true ? model.id : null),
            ),
          if (model.type == ModelType.vision)
            _switchRow(
              label: '图片理解',
              tooltip: '关闭后不加载视觉投影器（省 ~0.9GB，只能文本对话）；'
                  '切换后重新加载模型生效',
              value: settings.visionEnabled(model.id),
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setVisionEnabled(model.id, v),
            ),
          if (settings.enableMtpFeature && model.mtp)
            _switchRow(
              label: 'MTP 加速',
              value: settings.mtpEnabled(model.id),
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setEnableMtp(model.id, v),
            ),
          if (settings.enableDsparkFeature && model.dspark != null)
            _switchRow(
              label: 'dspark 加速',
              value: settings.dsparkEnabled(model.id),
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setEnableDspark(model.id, v),
            ),
          // 删除是危险动作，收在展开区（原来和「加载/卸载」等分挤在主行三颗）。
          if (isCached)
            _dangerButton('删除', () => _confirmDeleteModel(model, context))
          else if (state != DownloadState.idle)
            // 下载中 / 已暂停 / 失败：连同半成品一起清掉。
            _dangerButton('删除', () => _confirmDeleteDownloading(model, context)),
        ],
      ),
    );
  }

  /// 紧凑开关行（30dp 高 Switch；标题可带 tooltip 承载原来的长注释）。
  Widget _switchRow({
    required String label,
    String? tooltip,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final title = tooltip == null
        ? Text(label, style: const TextStyle(fontSize: 12.5))
        : Tooltip(
            message: tooltip,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: const TextStyle(fontSize: 12.5)),
              const SizedBox(width: 4),
              Icon(Icons.info_outline, size: 12, color: scheme.outline),
            ]),
          );
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(child: title),
          SizedBox(
            height: 30,
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  /// 展开区里的危险动作（小号红字按钮）。
  Widget _dangerButton(String label, VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 6)),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: WidgetStatePropertyAll(Colors.red.shade600),
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.delete_outline, size: 15),
        const SizedBox(width: 4),
        Text(label),
      ]),
    );
  }

  /// 删除已缓存模型前先弹确认框，避免误删（模型文件移除后需重新下载）。
  /// 确认后才真正调用 deleteModel。
  ///
  /// 两道以前没有的收尾（2026-10-30 反馈「删除点了没反应，再进列表还在」）：
  /// ① 正在内存里用的模型不许删——文件被 mmap，删掉后再次缺页就是 SIGBUS
  ///    直接崩进程，先让用户「卸载」；
  /// ② 删完立刻用磁盘真值校正列表并如实播报删了几项，不再只把内存态清成
  ///    idle（那样文件没删净时要等下次进页面才被发现，看着像按钮坏了）。
  Future<void> _confirmDeleteModel(
      ModelConfig model, BuildContext context) async {
    final ms = ref.read(modelManagerProvider);
    if (ms.modelId == model.id && ms.isLoaded) {
      _showDeleteToast(
          '「${model.name}」正在使用中，请先点「卸载」再删除（删除正在使用的模型文件会导致应用崩溃）',
          warn: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除模型？'),
        content: Text(
          '删除「${model.name}」会移除已下载的模型文件（${_formatSize(model.sizeBytes)}），'
          '之后需要重新下载才能再用。确定删除吗？',
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

    final res =
        await ref.read(downloadNotifierProvider.notifier).deleteModel(model.id);
    // 若删除的是默认模型，同时清除默认设置，避免启动时指向已不存在的模型。
    if (ref.read(settingsProvider).defaultModelId == model.id) {
      await ref.read(settingsProvider.notifier).setDefaultModel(null);
    }
    await _afterDelete(model, res);
  }

  /// 删除/取消下载之后的统一收尾：磁盘真值校正 + 存储占用刷新 + 如实播报。
  Future<void> _afterDelete(
      ModelConfig model, ({List<String> removed, String? error}) res) async {
    // 用磁盘真值校正：文件真没了才显示「未下载」，没删净就继续显示「已缓存」，
    // 免得界面先装作删好了、下次进来又冒出来。
    await _refreshCacheStatus();
    if (!mounted) return;
    setState(() => _storageTick++);

    final stillCached = ref
            .read(downloadNotifierProvider)[model.id]
            ?.state ==
        DownloadState.completed;
    if (res.error != null) {
      _showDeleteToast('删除「${model.name}」失败：${res.error}', warn: true);
    } else if (stillCached) {
      _showDeleteToast(
        '「${model.name}」文件仍在磁盘上（已删 ${res.removed.length} 项）——'
        '请到「存储空间」确认目录权限后重试',
        warn: true,
      );
    } else if (res.removed.isEmpty) {
      _showDeleteToast('「${model.name}」没有需要清理的文件');
    } else {
      _showDeleteToast('已删除「${model.name}」（${res.removed.length} 个文件）');
    }
  }

  void _showDeleteToast(String message, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: warn ? Colors.orange : null,
    ));
  }

  /// 删除「下载中」的模型任务：先弹确认框（会丢失已下载的半成品，需重下），
  /// 确认后取消当前下载并清理主 gguf / mmproj 及其残留 .tmp 文件。
  Future<void> _confirmDeleteDownloading(
      ModelConfig model, BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载中的模型？'),
        content: Text(
          '删除「${model.name}」会取消当前下载，并移除已下载的半成品文件'
          '（${_formatSize(model.totalBytes)}，含 mmproj 投影器）。\n\n'
          '之后需要重新下载才能再用。确定删除吗？',
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
    // cancelDownload 会取消进行中的传输并清理全部产物与 .tmp（多目录清扫），
    // 收尾与「删除已缓存模型」一致：磁盘真值校正 + 如实播报。
    final res = await ref
        .read(downloadNotifierProvider.notifier)
        .cancelDownload(model.id);
    await _afterDelete(model, res);
  }

  /// 折叠态次行最多展示的特性标签数（全量在展开区，不丢信息）。
  static const int _kCollapsedTagLimit = 3;

  /// 体积 + 特性标签描述行 —— **唯一渲染点**。
  ///
  /// 折叠态的次行与展开区都调它，只按 [expanded] 决定标签放几条（折叠 = 前
  /// [_kCollapsedTagLimit] 条，展开 = 全量），两处缩进一致，点开即原地补全。
  ///
  /// 2026-10-30 修复：未下载模型原先「次行」与「展开区」各画一遍体积+前三个
  /// 标签，点开就是上下两行一模一样的内容。
  Widget _modelMetaLine(
    ModelConfig model, {
    bool expanded = false,
    String? failedMessage,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildModelTag(_formatSize(model.totalBytes), neutral: true),
        if (failedMessage != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              failedMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: Colors.red.shade600),
            ),
          )
        else
          for (final tag in modelFeatureTags(
            model,
            limit: expanded ? null : _kCollapsedTagLimit,
          ))
            _buildModelTag(tag),
      ],
    );
  }

  String _formatSize(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  /// 统一的特性标记小 chip（11px，胶囊底 = 语义色 12% 透明：明暗两套都成立，
  /// 不再用 Colors.x.shade100 那种只适配浅色的实底）。
  Widget _buildModelTag(String label, {bool neutral = false}) {
    final scheme = Theme.of(context).colorScheme;
    final (i, color) = neutral ? ('', scheme.outline) : _tagStyle(label);
    final text = i.isEmpty ? label : '$i $label';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10.5, color: color)),
    );
  }

  /// 特性标签 → (icon, 语义色)。未知标签给中性灰，防未知 tag 视觉失控。
  (String, Color) _tagStyle(String tag) {
    switch (tag) {
      case '推荐':
        return ('⭐', Colors.blue);
      case '速度快':
        return ('⚡', Colors.orange);
      // 不推荐：警示红，提示「体积大/门槛高，普通机型不推荐」。
      case '不推荐':
        return ('⚠️', Colors.red);
      // 限高端旗舰：金色，提示「需要旗舰级硬件（内存/算力）才带得动」。
      case '限高端旗舰':
        return ('👑', Colors.amber.shade800);
      default:
        if (tag.startsWith('需')) return ('⚠️', Colors.red.shade700);
        return ('🏷️', Colors.blueGrey);
    }
  }

  /// 启动下载。下载完成的「全局重扫 + 存储刷新」由 build 里的
  /// downloadNotifierProvider 监听统一处理（任何入口完成都会触发），
  /// 这里不再重复扫描。
  Future<void> _startDownloadAndRescan(ModelConfig model) async {
    await ref.read(downloadNotifierProvider.notifier).startDownload(model);
  }

  /// 断点续传。同上，完成后的全局重扫由监听统一处理。
  Future<void> _resumeDownloadAndRescan(String modelId) async {
    await ref.read(downloadNotifierProvider.notifier).resumeDownload(modelId);
  }

  Future<void> _scanModels({bool silent = false}) async {
    final manager = ModelManager();
    final cachedIds = await manager.scanExistingModels();

    if (!mounted) return;

    if (cachedIds.isEmpty) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('未找到已下载的模型文件'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    final allModels = await loadModelCatalog();
    final foundModels =
        allModels.where((m) => cachedIds.contains(m.id)).toList();

    if (foundModels.isNotEmpty) {
      await ref
          .read(downloadNotifierProvider.notifier)
          .initCachedModels(foundModels);

      // 静默扫描（启动首次 / 下载完成）不弹 SnackBar，避免打扰。
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已恢复 ${foundModels.length} 个模型状态'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('找到文件但未匹配到已知模型，请检查模型ID'),
            backgroundColor: Colors.orange),
      );
    }
  }

  Future<void> _handleLoadModel(ModelConfig model) async {
    final manager = ref.read(modelManagerProvider.notifier);
    // 模型重载影响本地引擎：任何会话（含后台并发回合）在跑都算。
    final isGenerating = ref.read(runningTurnsProvider).isNotEmpty;

    // 1) 已有一个不同模型在内存中（可能正在推理）→ 友好提醒，确认后再切换。
    if (manager.isLoadedState && manager.modelId != model.id) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.orange),
              SizedBox(width: 8),
              Text('已有模型正在运行'),
            ],
          ),
          content: Text(
            '当前「${manager.currentModelName}」已在内存中'
            '${isGenerating ? '（正在推理）' : ''}。\n\n'
            '切换到「${model.name}」会先卸载当前模型，再加载新模型。确定继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('切换模型'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    // 2) 若正在推理，必须先停止全部回合，否则卸载模型会令原生引擎崩溃（红屏）。
    if (ref.read(runningTurnsProvider).isNotEmpty) {
      try {
        await ref.read(chatNotifierProvider.notifier).stopGeneration();
      } catch (_) {
        // 忽略停止异常，继续尝试卸载/加载。
      }
      // 给原生层一点时间完成停止流程。
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (!mounted) return;

    // 3) 弹出「加载中」对话框，实时展示进度（大模型耗时较长，避免用户不知所措）。
    final loadFuture = manager.loadModel(model.id);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ModelLoadProgressDialog(modelName: model.name),
    );

    final ok = await loadFuture;

    // 加载结束，关闭进度弹窗。
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (!mounted) return;

    // 4) 走原有完成提示路径：成功 / 失败 SnackBar。
    if (ok) {
      ref.read(currentModelIdProvider.notifier).state = model.id;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('✅ ${model.name} 已加载到内存'),
            backgroundColor: Colors.green),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('❌ 模型加载失败，请查看"推理引擎"标签页的日志'),
            backgroundColor: Colors.red),
      );
    }
  }
}

