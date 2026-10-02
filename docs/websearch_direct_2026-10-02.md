# 端侧直连国内搜索引擎（独立搜索模块）——过程记录与坑报告

> 目标：摆脱对自建 SearXNG 的强依赖（实例挂/IP 封 → 联网搜索全灭），
> 在手机端直接接入至少 3 家国内可达的搜索引擎，构建为独立可复用模块
> `lib/websearch/`（不依赖 Flutter/agent 层），经 `WebSearchSeam` 接缝注入。
>
> 本文档**边做边写**，记录每一步实测证据、踩坑与规避办法，供后续维护/扩展引擎时避坑。

## 0. 现状与约束

- 现有链路：`web_search` 工具 → `WebSearchSeam`（可插拔接缝）→ `SearXNGSearchProvider`
  → 自建 SearXNG 实例（DGX 主机 docker）。痛点：实例离线/出口 IP 被上游引擎封禁时全军覆没。
- 集成点：`lib/agent/web_search/web_search_seam.dart`（接缝）、
  `lib/providers/settings_provider.dart:480` 与 `chat_provider.dart:1367`
  （applySearXNGProviderFromSettings 注册 provider）。
- 本模块改动范围约束：新模块 `lib/websearch/` + 接缝处薄适配层，不动智能体循环/协议。

## 1. 引擎候选实测（2026-10-02，本机武汉家宽 IP，真机同网络）

用 curl/Python 直接打各家 HTML 端点（UA=Chrome PC/Mobile，Accept-Language: zh-CN）：

| 引擎 | 端点 | 首发可达 | 连发 10 次 | 结果结构 | 备注 |
|---|---|---|---|---|---|
| 必应 CN | `cn.bing.com/search?q=&format=rss&mkt=zh-CN` | ✅ | **10/10 全成（6.3s）** | RSS XML：title/link/description/pubDate | **最优**：直链+日期+摘要，无需跳转还原 |
| 必应 CN (HTML) | `cn.bing.com/search?q=` | ✅ | - | `li.b_algo`，h2>a 直链 | 兜底解析 |
| 360 搜索 | `www.so.com/s?q=` | ✅ | **10/10 稳定** | `li.res-list`，块内 `data-mdurl`=真实URL | 摘要在 `p.res-desc`/`mh-news-desc` 类 |
| 搜狗 | `www.sogou.com/web?query=` | ✅ | **4-5 次后触发反爬** | `div.vrwrap`，块内 `data-url`=真实URL | 摘要 class `fz-mid space-txt` |
| 百度 PC | `www.baidu.com/s?wd=&rn=10` | ✅ | **连发全挂** | `div.result.c-container`，块内 `mu=`=真实URL | 反爬最凶，先取 BAIDUID Cookie 也挡不住连发 |

### 1.1 已实锤的机制

- **百度安全验证**：HTTP 200 + `<title>百度安全验证</title>`（仅 1.4KB 小页），
  判定串 `百度安全验证`。触发后该 IP 进入惩罚态，**带 Cookie 也没用**（实测）。
- **搜狗反爬**：HTTP 200 + `<title>搜狗搜索</title>` 小页（5.4KB），判定串
  `antispider`/`验证码`，页面 JS 引用 SNUID 检查。连发 4-5 次即触发。
- **360 / 必应 CN**：本机实测 10 连发无拦截；360 结果块内嵌 `data-mdurl` 真实 URL。
- **跳转链接还原**（不依赖内嵌字段时的兜底，均已实测可行）：
  - 百度 `http://www.baidu.com/link?url=...` → **302 Location** 直给真实 URL；
  - 搜狗 `https://www.sogou.com/link?url=...` → HTTP 200 页内 `URL='...'`（meta/JS 跳转）；
  - 360 `https://www.so.com/link?m=...` → HTTP 200 页内 meta/JS 跳转。
  - ⚠️ 取证注意：解析出的链接是 HTML 转义形态（`&amp;`），还原前必须 unescape，
    否则 302 Location 会给出乱码 URL（实测踩过）。
- **真实 URL 内嵌字段（优先用，省一次还原请求）**：
  - 百度：结果块内 `mu="真实URL"`；360：`data-mdurl`；搜狗：`data-url`。

### 1.2 压测烧 IP 事故记录（重要）

- 第一次 10 连发压测：搜狗 4 次后被封、百度全 0。
- 随后带 Cookie 会话复测：**百度/搜狗第一发即 BLOCK** —— 前一轮压测已把本机 IP
  记入惩罚，短时间内继续探测只会续罚。
- **教训**：
  1. 反爬探测本身要控频（同引擎两次探测间隔 ≥ 数秒），别拿真机/常用 IP 猛打；
  2. 模块必须内置**引擎级熔断冷却**：一旦判定 blocked，该引擎冷却数分钟起，
     冷却期内直接跳过，绝不硬打；
  3. 手机蜂窝 IP（CGNAT）经常变化，熔断 + 自动恢复天然适配 IP 漂移场景。

## 2. 定案架构

```
lib/websearch/                     # 独立模块（纯 Dart，无 Flutter/agent 依赖）
  src/search_hit.dart              # SearchHit / SearchEngineException（契约）
  src/search_engine.dart           # SearchEngine 接口 + FetchPage 注入（契约）
  src/html_text.dart               # 去标签/实体解码/折叠空白
  src/engines/bing_cn_engine.dart  # RSS 为主 + HTML 兜底
  src/engines/so360_engine.dart
  src/engines/sogou_engine.dart
  src/engines/baidu_engine.dart    # 尽力而为（熔断最激进）
  src/engine_http.dart             # Dio 注入方：UA/Cookie 会话/重试/限频
  src/multi_engine_search.dart     # 聚合：并行多引擎 + 熔断 + 去重 + 诊断
上层适配（薄）：
  lib/agent/web_search/direct_search_provider.dart  # SearchEngine→WebSearchProvider
注册逻辑：
  applySearXNGProviderFromSettings：SearXNG 未配置 → 直连多引擎 provider；
  已配置 → 保持 SearXNG（用户显式指定优先）。
```

引擎契约：`search(query, {limit})` → `List<SearchHit>`；HTTP 通过 `FetchPage`
注入（引擎保持纯解析逻辑，fixture 离线单测）。判定 blocked 抛
`SearchEngineException(kind: 'blocked')`。

## 3. 过程日志（追加式）

### 2026-10-02 上午

- 摸底现有接缝：`WebSearchSeam` 已可插拔，注册点唯一，改动面小。
- 六家端点首发全 200（百度/必应/搜狗/360/头条），见 §1 表。
- 必应 RSS 形态实锤：`cn.bing.com/search?format=rss` 10 items 全解析，含 pubDate。
- 三家跳转还原实测通过（百度 302 / 搜狗·360 meta-JS）。
- 10 连发压测：必应 RSS 10/10、360 10/10、搜狗 4-5 次封、百度全挂（§1.2）。
- 头条（so.toutiao.com）可解析（script 内 JSON 带 url 字段）但结构脆弱，暂缓。
- 待办：搜狗/百度 IP 惩罚衰减时长观察；引擎解析器实现；聚合器与熔断实现。

## 4. 已知坑与规避（持续追加）

1. **HTML 转义**：从结果页解析出的 href/属性值必须先 unescape（`&amp;`→`&`）
   再用于跳转还原，否则 302 Location 乱码（实测）。
2. **反爬判定不能只看 HTTP 状态**：百度/搜狗的拦截页都是 **HTTP 200 小页面**，
   必须按 title/特征串判定（`百度安全验证` / `antispider`）。
3. **压测即烧 IP**：同引擎连续探测会续罚（§1.2），开发期调试用单发+间隔。
4. **360 结果块含推广/垂直卡**：`data-mohe-type`（如 news_ai）与导航块也会带
   data-mdurl（如 hao.360.com），解析要过滤垂直卡/导航噪声。
5. **百度摘要 class 是哈希后缀**（如 `summary-text_15QGa`），解析必须按前缀匹配，
   不能整 class 精确匹配（百度 PC 页改版频繁，cosc-* 结构是新模板）。
6. 沙箱限制下 flutter.bat 静默挂死（AGENTS.md 已有记录），本机 SDK 实际在
   `/c/dev-tools/flutter`（3.29.0），`flutter --version` 首跑可能因网络抖动
   git fetch 失败（exit 128），重试即可。


## 5. 调研结论（子智能体，2026-10-02，详版见 build/search_recon/research_notes.md）

1. **搜狗**：antispider 以 SNUID Cookie 计数 + IP 频次为触发核心，惩罚主要绑
   Cookie 而非硬封 IP——清 Cookie/换会话常可恢复；持续高频才封几十分钟~数小时。
   m.sogou.com 无"限制更松"的公开证据。
2. **百度**："百度安全验证" = HTTP 200 小页（必须内容级检测）；重大发现：
   **`/s?wd=&rn=&pn=0&tn=json` 直接返回结构化 JSON**（data.feed.entry[]，
   title/url/abs/time），解析成本远低于 HTML——已落 BaiduEngine 主路径。
3. **必应 CN RSS**：无被限频/封禁的公开报告（官方输出格式），建议 ≤1 req/3~5s，
   可作主力引擎（已定）。
4. **360**：SearXNG 360search.py 揭示两段式请求 + `pn` 是页码不是偏移；
   真链在 data-mdurl（本地实测吻合）。
5. **SearXNG 引擎源码**（bing/baidu/sogou/360search/quark/chinaso.py）是请求形态
   的权威参考；注意 AGPL-3.0——只参考端点+参数事实，解析代码自写。
6. **CGNAT**：共享 IP 被限频概率约为独享 3 倍，但硬 IP 封禁对蜂窝流量基本失效
   （风控更依赖 Cookie/指纹）→ 手机端天然占优；熔断按"引擎×会话"计数、
   分钟级封顶、到期自动重试即可适配 IP 漂移。
7. **第 4/5 家**：中国搜索 chinaso 官方 JSON（免 key，uid Cookie 必带）→ 已落地；
   夸克（quark.sm.cn/s?layout=html，约 9 请求触发 X5SEC、罚 15min）留作后备；
   头条/B站（签名蔓延）、知乎/CSDN（垂直）不划算。

## 6. Live 验收记录（2026-10-02，本机=真机同网络）

`TONGYILITE_LIVE_SEARCH=1 flutter test test/websearch/live_search_test.dart`：

- 第一次搜索（华为Mate70 发布会）：**1154ms，bing_cn ok:8 / so360 ok:5 /
  chinaso ok:4**，合并去重 8 条，chinaso 跳转链还原成真实 URL（163/itbear 等）；
  sogou 302→antispider、baidu 302→wappass 被判 blocked（本机 IP 处于 §1.2
  事故后的惩罚期）——**判定与熔断完全按设计工作**。
- 第二次搜索（武汉天气）：bing_cn ok:8 / so360 ok:5 / chinaso ok:8，
  sogou/baidu 显示 `cooling(119s)` 被跳过——**冷却状态正常**。
- 结论：**≥3 家国内可达引擎（必应CN/360/中国搜索）实锤可用**；搜狗/百度在
  真机新 IP（或本机惩罚过期）上会经冷却自动恢复，其 blocked 判定链路已验证。

## 7. 模块最终形态与参数速查

```
lib/websearch/                     独立模块（纯 Dart，仅依赖 dio）
  websearch.dart                   barrel
  src/search_hit.dart              SearchHit / SearchEngineException（契约）
  src/search_engine.dart           SearchEngine 接口 + FetchPage 注入（契约）
  src/html_text.dart               去标签/实体解码
  src/engine_http.dart             Cookie 会话/UA/重试/不跟随重定向+302风控判定
  src/link_resolver.dart           跳转链还原（baidu/chinaso=302；sogou/360=页内meta/JS）
  src/multi_engine_search.dart     聚合：轮转合并/去重/熔断/诊断
  src/engines/                     bing_cn(RSS+HTML兜底) so360 chinaso(JSON)
                                   sogou baidu(tn=json主+HTML兜底)
上层（薄适配）：
  lib/agent/web_search/direct_search_provider.dart   DirectSearchProvider（单例）
  web_search_provider.dart::applySearXNGProviderFromSettings
    → SearXNG 地址已配置=SearXNG；未配置=直连多引擎（默认，零配置可用）
  settings_screen 联网搜索卡提示文案已同步更新
```

- 引擎优先级：必应CN → 360 → 中国搜索 → 搜狗 → 百度。
- 熔断参数：blocked 2min 起 ×2^连击 封顶 15min；parse 5min；network 45s；
  empty 不冷却（查询相关现象）。
- 结果映射：SearchHit → WebSearchSource（engine 字段=bing_cn/so360/chinaso/
  sogou/baidu，工具层无需改动）；全失败时 diagnostics 带"可行动"诊断文案。
- 测试：test/websearch/ 共 **46 项**（解析 fixture 25 + json 8 + 聚合器 9 +
  provider 注册 4 + live 2 门控）；全量 test/agent+providers+services+websearch
  **446 项 + 4 skip 全绿**；analyze 0 新增。

## 8. 已知坑与规避（第 2 批，持续追加）

7. **百度 tn=json 也被风控**：返回形式是 302→wappass（不是 200 小页），所以
   HTTP 层必须不跟随重定向才能拿到 Location 判 blocked（已内置）。
8. **chinaso 不带 uid Cookie 返回 `{"status":2,"msg":"ip control"}`**——不是
   真封 IP，是缺随机 uid Cookie（对齐 SearXNG chinaso.py 每请求随机生成）。
9. **Dio 默认跟随重定向**会吞掉 302 的 Location 信号（拿到的是 wappass 壳页），
   BaseOptions 必须 `followRedirects: false` + `validateStatus: (_) => true`。
10. **轮转合并的去重语义**：按索引轮转（第 i 轮取各引擎第 i 条，重复跳过），
    不是"每引擎先出第一条 distinct 再进入下一轮"——后者实现复杂收益小。
11. **测试包名**：本包是 `package:tongyi_lite/`（下划线），不是 tongyilite。
12. **聚合器统计 truncated 的口径**：= 各引擎产出总数 > 合并输出数（含去重丢弃），
    不是"检查过的条数"（曾把 total 放进循环内计数导致漏报）。


## 9. 安全管控定案（用户新需求：引擎开关 + 上限配置 + 细水长流）

**设置项**（「设置 → API 接入 → 联网搜索」卡，SearXNG 地址为空时生效）：
- 6 个直连引擎独立开关（必应CN/360/中国搜索/搜狗(高风险)/百度(高风险)/夸克(高风险)）；
- 「低风险引擎每 10 分钟搜索上限」默认 6（1~10）；
- 「高风险引擎每 10 分钟搜索上限」默认 2（1~6）。

**管控规则（模块内 MultiEngineSearch 实现）**：
- **窗口预算闸**：每引擎每 10 分钟固定窗口内最多 N 次真实请求；耗尽 → 本轮
  跳过（status=budget，不报错），窗口到期自动恢复。高风险档（搜狗/百度/夸克，
  实测短时连发 4-9 次即触发验证码）默认 2 次/窗口 = "细水长流"；低风险档
  （必应/360/中国搜索，实测 10 连发无感）宽松。
- **熔断冷却**（blocked 时）：指数退避 2min→4min→…封顶 15min，冷却期零请求。
- **身份轮换**：blocked 即清该引擎 Cookie 会话 + 从 6 个真实浏览器 UA 池
  随机换新 UA（调研实证搜狗/百度惩罚主要绑 Cookie，全新身份常可直接恢复）。
  **UA 是会话级不是请求级**——同一"浏览器"中途换 UA 是更强的机器特征。
- **跳线优先**：预算/熔断跳过的引擎由其余引擎覆盖，6 引擎下任何时刻至少
  2-3 家可答；全失败才返回带可行动诊断的空结果。

**UA 轮换原则（回答"共享 IP 是否可以 UA 多变"）**：可以但只在"换身份"时换。
同一会话内 UA 必须稳定（真实浏览器不会中途变 UA）；共享 CGNAT IP 的风险
来自"该 IP 上其它用户的量"，我方最优策略 = 低频 + 稳定会话 + 被封换身份，
而不是每请求伪装不同 UA（Header 组合不一致反而提升机器判定分）。

**新 IP 复验（手机热点网络，2026-10-02 10:4x）**：搜狗恢复（ok:8）、夸克恢复
（ok:7）、必应 8/360 5/中国搜索 4 —— **单次搜索 5 家引擎同时出结果**；
百度在该蜂窝 IP 段被重点风控（HTML/tn=json 均 302 wappass，带预热 Cookie
也一样）→ 熔断兜底，换网络自动恢复。搜狗惩罚绑旧 IP/Cookie 实证：换 IP+
新会话首发即过。

## 10. 构建产物与验收

- **2026-10-02 10:48/10:55 最新构建（v0.2.8+16，工作区未提交）**：
  `E:\Work\DgxSpark\TongYi-Lite\build\app\outputs\flutter-apk\` —
  app-debug.apk 106628214 B / app-release.apk 59897266 B。
- 字符串级验收：debug kernel UTF-8 `端侧直连引擎`6/`每 10 分钟搜索上限`4/
  `quark.sm.cn`5/`chinaso`37/`webSearchDirectEngines`15 命中；
  release libapp.so UTF-16LE `端侧直连引擎`2/`每 10 分钟搜索上限`2 +
  ASCII `webSearchDirectEngines`1 命中。
- 设备未连接（手机正作网络热点），`adb install -r -t` 留待重连后执行。

## 11. 已知坑与规避（第 3 批）

13. **Git Bash 的 `cd` 传不进 .bat 子进程**（本机实测反复复现）：bash 里
    `cd 项目根 && flutter.bat assemble` 子进程仍可能在旧 cwd 运行
    （报 `lib/main.dart 系统找不到指定的路径`）。**解法 = 用 PowerShell**：
    `powershell -NoProfile -Command "Set-Location 'E:\...'; & 'C:\dev-tools\flutter\bin\flutter.bat' assemble ..."`，
    或每条命令用绝对路径。release 产物在 `build/flutter-assemble/app.so`
    （不是 arm64-v8a/ 子目录）。
14. **百度对蜂窝 CGNAT IP 段有重点风控**：预热 Cookie/tn=json/HTML 全被
    302 wappass，属 IP 段级（非我们请求形态问题）；换 WiFi 或等惩罚衰减。
    夸克 x5sec 同理（对部分网络首发即拦）。
15. **搜狗/百度惩罚"主要绑 Cookie 会话"**（调研+实测双确认）：换 IP 后
    新会话首发即过；模块的"blocked 清 Cookie+换 UA"策略据此设计。


## 12. 真机质量复盘（2026-10-02 11:1x-11:30，用户反馈"还是百度百科"）

**取证**（8 Elite 消息库 + TRACE）：11:19"北海 新闻 今天"返回的结果全部是
必应 RSS 风格（百科/知乎旅游攻略置顶），随后 360 被 302 到 qcaptcha、其余
引擎 cooling/budget 耗尽 → "搜索服务异常"。复现实验证实：**必应 web RSS 对
中文时效类查询的排序本身就是百科优先**（有无年份后缀无差别）；必应新闻垂直
RSS（news/search?format=rss）已死（各形态均 0 items）。

**修复（11:30 包）**：
1. **聚合层时效降权**：查询含 今天/最新/新闻/消息/动态… 时，百科/文库/
   知乎词典类 host（baike/wenku/zhidao/baike.sogou）稳定排到结果尾部。
   实测"北海 新闻 今天"：新华网北海/北海政府要闻/广西新闻网顶到前排。
2. **结果引擎署名**：工具输出每条标题后带 〔必应〕〔搜狗〕 等——以后一眼
   定位"谁给的烂结果"，不用再翻库。
3. **引擎结果池扩到 ≥10**：给去重/降权留余量（输出上限仍 8）。

**共享热点 NAT 的注意**：开发机与手机共享公网出口，开发机反复测试烧的
IP 惩罚手机同样承受（360/quark/baidu 在此网络反复被拦属预期）；真机长期
使用（蜂窝/家庭 WiFi）下高风险引擎按 2 次/10min 细水长流，不会出现这种
全灭局面；全灭时工具返回 budget/cooling 诊断而非假结果。

**安装记录**：8 Elite 于 11:30 覆盖安装 11:30 构建成功（lastUpdateTime
2026-10-02 11:30:25）；小米 13 仍离线未装。


## 13. 端侧直连总开关（2026-10-02 11:50，用户需求：不再依赖"清空 SearXNG 地址"）

- 新增设置 `webSearchDirectEnabled`（默认开）：**打开 = 最高优先级**，即使
  配置了 SearXNG 地址也用端侧直连；关闭 = 回到 SearXNG 模式（未配置地址时
  web_search 报"请填写地址"诊断）。
- UI：「⚡ 端侧直连引擎」区块顶部新增总开关"端侧直连引擎（优先级最高）"，
  关闭时引擎开关/预算滑条整体置灰（Opacity+IgnorePointer，对齐 agentEnabled
  模式）；卡片顶部提示文案同步更新。
- 注册逻辑：`applySearXNGProviderFromSettings` 按 `directEnabled ? 直连 :
  SearXNG(或诊断型)` 分流；SearXNG 分支改用"构造 candidate 比签名"避免
  重复 dispose 连接池。
- 回归 460 项 + 4 skip 全绿；8 Elite 11:50 覆盖安装成功
  （lastUpdateTime 11:50:08）；小米 13 仍离线。
- APK：app-debug.apk 106631298 B / app-release.apk 59899434 B（11:49/11:50），
  字符串级验收过（debug `端侧直连引擎（优先级最高）`2/`webSearchDirectEnabled`15；
  release UTF-16LE `端侧直连引擎`4 + ASCII `webSearchDirectEnabled`1）。
