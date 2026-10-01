/// 意图理解 + 关键词变体生成（独立可复用模块，不依赖 TongYi-Lite 服务）。
///
/// 背景：通用搜索引擎对"国庆""南宁新闻"这类偏概念/泛关键词，优先返回
/// 高权重百科、攻略、日历页，缺时效性。通过意图理解把关键词扩展成多组
/// 时效性更强的变体（补"新闻 / 最新 / 今天 / 年份"等），按优先级从高到低
/// 依次搜索、跨关键词合并去重，显著提升真实新闻命中率——单次 web_search
/// 工具调用即可在内部循环多搜几组关键词，充分利用每回合搜索预算。
library;

/// 搜索意图类型。
enum SearchIntent {
  /// 要时效/新闻：关键词含"新闻 / 最新 / 今天 / 热点 / 报道"等。
  news,

  /// 本地新闻：地名 + 新闻意图。
  localNews,

  /// 概念/百科类：泛查询（如"国庆"），无明确时效意图。
  concept,

  /// 一般检索。
  general,
}

/// 时效/新闻意图信号词（命中任一即偏时效）。
const List<String> _newsSignals = <String>[
  '新闻', '最新', '今天', '今日', '昨日', '昨天', '近日', '最近',
  '热点', '消息', '报道', '动态', '时讯', '进展', '情况',
  '发生了什么', '怎么样', '出炉', '公布', '发布',
];

/// 常见地名/地域词（用于判本地新闻意图）。
const List<String> _placeNames = <String>[
  '南宁', '北京', '上海', '广州', '深圳', '成都', '重庆', '武汉', '西安',
  '长沙', '杭州', '南京', '天津', '郑州', '苏州', '青岛', '昆明', '贵阳',
  '拉萨', '香港', '澳门', '台湾', '全国', '各地', '本地', '城市',
];

bool _containsAny(String q, List<String> words) => words.any(q.contains);

/// 检测查询意图。
SearchIntent detectIntent(String query) {
  final q = query.trim();
  if (_containsAny(q, _newsSignals)) {
    return _containsAny(q, _placeNames)
        ? SearchIntent.localNews
        : SearchIntent.news;
  }
  return SearchIntent.concept;
}

/// 把关键词扩展成多个变体，按优先级从高到低（index 0 最高），去重。
///
/// 第一个恒为原始关键词；随后按意图补时效词（新闻 / 年份 / 最新消息）。
/// 返回最多 [maxVariants] 个（默认 3）。
List<String> expandQuery(String query,
    {DateTime? now, int maxVariants = 3}) {
  final q = query.trim();
  if (q.isEmpty) return const <String>[];
  final intent = detectIntent(q);
  final year = now?.year.toString();
  final hasYear = _containsAny(q, const <String>['20']);

  final out = <String>[];
  void add(String s) {
    final t = s.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  // 原词优先级最高（最贴近模型意图）。
  add(q);

  switch (intent) {
    case SearchIntent.news:
    case SearchIntent.localNews:
      // 补时效词：q + 今天 最新消息。
      add('$q 今天 最新消息');
      // 补年份 + 最新（缺年份时），否则补"最新消息"。
      if (!hasYear && year != null) {
        add('$q $year 最新');
      } else {
        add('$q 最新消息');
      }
    case SearchIntent.concept:
      // 泛/概念词 → 拉向时效：q + 新闻；q + 年份。
      add('$q 新闻');
      if (!hasYear && year != null) {
        add('$q $year');
      }
    case SearchIntent.general:
      add('$q 最新');
  }

  return out.take(maxVariants).toList();
}

/// 把一组关键词（主查询 + 附加查询）统一扩展成"候选关键词池"，
/// 按优先级从高到低、整体去重。供工具层内部循环搜索使用。
///
/// [cap] 限制候选池总条数（默认 6），避免内部搜索过载拖慢单次调用。
List<String> expandKeywords(List<String> queries,
    {DateTime? now, int cap = 6}) {
  final out = <String>[];
  for (final q in queries) {
    for (final v in expandQuery(q, now: now)) {
      if (!out.contains(v)) out.add(v);
    }
  }
  return out.take(cap).toList();
}
