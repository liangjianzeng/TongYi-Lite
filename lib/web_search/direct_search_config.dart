/// 直连搜索引擎配置（独立可复用，不依赖 TongYi-Lite settings_service）。
library;

/// 可用的直连引擎 id。
class DirectEngine {
  static const String bing = 'bing';
  static const String baidu = 'baidu';
  static const String quake = '360search';
  static const String sogou = 'sogou';

  static const List<String> all = [bing, baidu, quake, sogou];
}

/// 手机直连搜索引擎的配置。
///
/// 核心思路：手机 IP 随网络经常变化，反爬标记远少于固定服务器 IP，因此
/// 用真实浏览器 User-Agent 直接请求搜索引擎 HTML 页，规避国内引擎（百度/
/// 360/搜狗）对数据中心 IP 的 CAPTCHA 拦截——无需自建 SearXNG 实例。
class DirectSearchConfig {
  /// 参与搜索的引擎列表（按 [DirectEngine] 常量）。
  final List<String> engines;

  /// 单次搜索最多返回来源条数。
  final int maxResults;

  /// 单次搜索超时。
  final Duration timeout;

  /// 搜索语言（如 "zh-CN"）；空 = 不指定。
  final String? language;

  /// 真实浏览器 User-Agent（核心：绕开反爬）。
  final String userAgent;

  const DirectSearchConfig({
    this.engines = const [
      DirectEngine.bing,
      DirectEngine.baidu,
      DirectEngine.quake
    ],
    this.maxResults = 8,
    this.timeout = const Duration(seconds: 12),
    this.language,
    this.userAgent = kRealBrowserUserAgent,
  });

  /// 真实 Chrome 桌面 UA——国内引擎据此放行而非判定为爬虫。
  static const String kRealBrowserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 配置签名：内容相同即同一份配置，供宿主判断是否需要重建 provider。
  String get configSignature => [
        engines.join(','),
        maxResults,
        timeout.inMilliseconds,
        language ?? '',
        userAgent,
      ].join('\u0000');
}
