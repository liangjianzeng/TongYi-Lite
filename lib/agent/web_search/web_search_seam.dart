/// 联网搜索接缝（对齐 DSH `ctx.web` 的可插拔搜索能力）。
///
/// web_search 工具只调接缝、不写死搜索源；具体搜索实现（默认 SearXNG）通过
/// [registerProvider] 注入。切换 provider 时自动释放旧资源，避免泄漏 HttpClient。
library;

import 'web_search_provider.dart';

export 'web_search_provider.dart';

/// 持有当前可插拔搜索 provider 的进程内单例，跨 agent 循环共享同一 provider。
class WebSearchSeam {
  WebSearchSeam._();

  static final WebSearchSeam instance = WebSearchSeam._();

  WebSearchProvider? _provider;

  /// 当前注册（且非空）的搜索 provider。
  WebSearchProvider? get provider => _provider;

  /// 注册/切换当前搜索 provider（释放旧 provider 资源）。
  void registerProvider(WebSearchProvider? provider) {
    if (provider == _provider) return;
    _provider?.dispose();
    _provider = provider;
  }

  /// 可用性探测（廉价：仅本地校验，不联网）。
  String? available() => _provider?.available();

  /// 执行一次搜索；provider 不可用时抛出结构化 [WebSearchProviderError]。
  Future<WebSearchResult> search(
    String query, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final provider = _provider;
    final availableErr = provider?.available();
    if (availableErr != null) {
      throw WebSearchProviderError('WEB_PROVIDER_ERROR', availableErr);
    }
    if (provider == null) {
      throw const WebSearchProviderError(
          'WEB_PROVIDER_ERROR', '联网搜索 provider 未配置');
    }
    return provider.search(query, timeout: timeout);
  }

  /// 清空当前 provider（进程退出/重置时使用）。
  void dispose() {
    _provider?.dispose();
    _provider = null;
  }
}
