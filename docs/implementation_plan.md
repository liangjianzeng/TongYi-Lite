# TongYi-Lite 实施方案（基于架构评审与可行性修正）

> **版本**：v1.0  
> **日期**：2026-07-29  
> **性质**：对现有 4 份设计文档（架构 v1/v2、插件、基准报告）的**评审 + 修正 + 落地计划**  
> **基准来源**：llama.cpp 官方仓库 b10173（2026-07-28 最新发布）、HuggingFace、ModelScope

---

## 目录

1. [评审结论速览](#1-评审结论速览)
2. [第一部分：优点发散与补充](#第一部分优点发散与补充)
3. [第二部分：不足识别与弥补](#第二部分不足识别与弥补)
4. [第三部分：可行性修正后的最终架构](#第三部分可行性修正后的最终架构)
5. [第四部分：分阶段实施方案](#第四部分分阶段实施方案)
6. [第五部分：风险登记册](#第五部分风险登记册)

---

## 1. 评审结论速览

### 评审方法
我逐字通读了 `architecture_design.md`、`architecture_design_v2.md`、`plugin_architecture.md`、`mobile_llm_benchmark_report_v2.md` 四份核心文档，并对照 llama.cpp 官方最新版本（b10173，2026-07-28）的真实代码、构建配置、Android 示例做了交叉验证。

### 核心发现（一句话）

> **现有架构的方向完全正确，但有 3 处关键技术假设需要修正，否则会导致工程返工。**

| # | 文档假设 | 真实情况（b10173 验证） | 影响 |
|---|---------|----------------------|------|
| ⚠️1 | "Android 用 **Vulkan + ARM NEON** GPU 加速" | 官方 Android 预编译包与示例**仅 CPU**（KleidiAI + SME2），无 Vulkan 预编译；Vulkan 后端需自行 NDK 交叉编译 | 性能预期需下调；GPU 加速是工程项而非现成能力 |
| ⚠️2 | "前端 Flutter 通过 **localhost:8080 HTTP Server** 与 llama-server 通信" | 官方 Android 示例（`com.arm.aichat`）采用 **直接 JNI 调用 llama C API**，不跑 HTTP server | 架构更简单更省内存，但通信层需重新设计 |
| ⚠️3 | "Qwen3.5-4B 在手机上 ~2GB 流畅运行" | VL 模型需额外 **mmproj 视觉编码器**（+几百 MB）+ 双阶段推理，3B-VL 在中端机内存紧张 | 视觉模块需分层降级策略 |

### 修正后整体仍然成立 ✅

方向没问题、产品愿景清晰、模块划分合理。修正后是**高度可落地的方案**。下面分两部分展开。

---

## 第一部分：优点发散与补充

> 现有文档中值得**放大、强化、外延**的亮点。

### 优点 1：离线优先（Offline-First）的产品定位 ⭐⭐⭐⭐⭐

**为什么这是最大优势**：当前所有主流 AI 应用（元宝、豆包、ChatGPT）都是"云端必联网"模式，而 TongYi-Lite 押注的是**隐私 + 离线**这个差异化赛道。这个定位在以下场景有不可替代的价值：
- 🏕️ 户外/荒野（无信号）
- 🔒 企业/政务（数据不出域）
- ✈️ 出差旅行（飞机/漫游）
- 💰 零成本长期使用（无 API 计费）

**发散补充——把"离线"做成可量化的卖点**：
- 增加**"离线天数徽章"**：连续离线运行 N 天，强化"你的数据从未离开设备"的信任感
- 增加**"数据足迹仪表盘"**：可视化展示"本会话产生 0 次网络请求、0 字节上传"
- 这些都能成为 App Store / 应用市场的**强力宣传素材**，是云端应用无法对标的护城河

### 优点 2：Plugin + 游戏化的产品形态极具想象空间 ⭐⭐⭐⭐⭐

这是整个方案**最有商业想象力**的部分。"荒野求生"只是第一皮肤，Plugin 架构天然支持换皮：
- 🏕️ 荒野求生（娱乐向）
- 📋 远程任务助手（效率向，B 端可收费）
- 🎓 学习闯关（教育向）
- 🏥 离线知识问答（行业向）

**发散补充——把 Plugin 做成"AI App Store"**：
现有文档的 Plugin 设计偏"功能扩展"，我建议升级为**"任务剧本（Scenario）"**概念：
- Plugin 不是冷冰冰的能力，而是有**剧情线、任务链、角色扮演**的剧本
- 用户完成任务 = 推进剧情 = 解锁新剧本，形成**留存闭环**
- 这是把工具型产品升级为**内容型产品**的关键，直接拉高 DAU 和留存率

### 优点 3：多模态能力矩阵（视觉+语音+对话+TTS）⭐⭐⭐⭐

四模态齐全，覆盖了人机交互的完整闭环（看、说、听、读）。

**发散补充——缺失的第五模态：传感器/环境感知**：
建议增加基于手机传感器的"环境感知"能力，让"荒野求生"更真实：
- 📍 GPS → 判断真实地理位置（森林/城市/海边）
- 🧭 指南针 → 方向任务
- 📳 加速度计 → 检测行走/静止状态
- 🌡️ 气压计 → 海拔/天气变化感知

这让"荒野求生"从**屏幕里的游戏**变成**结合真实物理世界的 AR 生存体验**，差异化更强。

### 优点 4：模型管理中心（Model Hub）⭐⭐⭐⭐

用户可自选模型、量化精度、切换——这是极客向用户的核心吸引力，也解决了"一模型打天下"的局限。

**发散补充——增加"模型适配性自检"**：
下载模型前，App 应先**检测本机内存/CPU**，给出红黄绿灯建议：
- 🟢 本机 8GB RAM → 可流畅运行 Qwen3-1.7B
- 🟡 本机 6GB RAM → 建议选 Qwen3-0.6B（1.7B 可能卡顿）
- 🔴 本机 4GB RAM → 仅支持 0.6B，强行装大模型会被 OOM 杀进程

这一步能**大幅降低"下载了大模型却跑不动"的差评率**。

### 优点 5：远程任务协议设计（WebSocket + 离线队列）⭐⭐⭐⭐

离线队列 + 有网回传的设计很成熟，幂等性、签名验证、超时控制都考虑到了。

**发散补充——增加"任务结果本地加密存证"**：
既然主打隐私，任务执行结果回传前应在本地做：
- 📝 生成执行摘要（不回传原始敏感数据，可选）
- 🔐 端到端加密回传（即使经过服务器也无法解密）
- 📜 本地留存任务日志哈希，可审计"我执行过什么"

这把"隐私"从口号变成**可证明的技术机制**。

---

## 第二部分：不足识别与弥补

> 现有文档中**会导致返工或不可行**的问题，按严重程度排序。

### 🔴 不足 1（致命）：Android GPU 加速是"工程项"而非"现成能力"

**文档假设**（architecture_design_v2.md）：
> "加速后端：Metal (iOS) / **Vulkan + ARM NEON** (Android)"
> "Samsung S24 Ultra + Qwen3-1.7B → ~22 tok/s"

**真实情况**（b10173 验证）：
1. 官方 Android 预编译包 `llama-b10173-bin-android-arm64.tar.gz` **只有 72.9MB，仅 CPU**（KleidiAI 优化）
2. 官方 Android 示例 `com.arm.aichat` 的 CMakeLists **没有启用任何 GPU 后端**（无 `GGML_VULKAN`、无 OpenCL）
3. 它用的是 `GGML_BACKEND_DL=ON` 动态加载后端 + `GGML_CPU_KLEIDIAI=ON`（ARM 的 CPU 加速库）
4. Vulkan for Android **需要自行用 NDK 交叉编译**，且 Adreno/Mali 驱动兼容性问题多

**影响**：如果按文档"Vulkan 加速"的预期去承诺性能（~22 tok/s），实际交付时只能跑出 CPU 性能（可能 ~8-12 tok/s），属于**性能缩水 40-50%**。

**弥补方案**：
1. **性能预期下调并分级**：
   - CPU-only（开箱即用）：8-12 tok/s（仍可用，人眼可读）
   - Vulkan 加速（需自研工程）：15-20 tok/s（作为 P2 优化目标）
2. **MVP 阶段直接用 CPU-only**：参照官方示例 `com.arm.aichat` 的构建方式（KleidiAI + SME2），这是**最稳妥、最省心**的路径，性能足够 MVP 演示
3. **Vulkan 作为明确的技术攻坚项**列入 P2，而不是默认能力。需要专人研究 Adreno/Mali 驱动兼容、`mmproj` 视觉模型在 Vulkan 下的稳定性

**修正后的加速后端说明**：
```
iOS  (iPhone)  → Metal GPU（官方 XCFramework 原生支持，开箱即用）  ✅
Android        → Phase 1: CPU (KleidiAI + SME2) 开箱即用            ✅
               → Phase 2: Vulkan (需自研 NDK 编译)                  🔧
```

### 🔴 不足 2（致命）：通信架构假设错误——Android 不跑 HTTP Server

**文档假设**（architecture_design.md）：
> "Flutter 内嵌 HTTP Server，与 llama-server 的 server 模块对接；支持 SSE streaming"
> "Flutter HTTP POST localhost:8080/v1/chat/completions"

**真实情况**（b1013 验证）：
1. 官方 Android 示例**根本不启动 HTTP server**，而是通过 **JNI 直接调用 llama C API**（`llama_model_load_from_file`、`llama_decode`、`common_chat_format_single`）
2. 在 Android 上跑一个 HTTP server + SSE 有额外问题：
   - 多一个 server 进程/线程，**内存 +50-100MB**
   - localhost HTTP 在 Android 后台受限（省电策略会杀后台 socket）
   - SSE 长连接在移动端不稳定

**影响**：按文档架构，需要：Flutter → HTTP Server（端口监听）→ llama-server 进程。这条链路在 Android 上**既复杂又不稳定**，且浪费内存。

**弥补方案**：改为 **Flutter ↔ Kotlin(FFI/JNI) ↔ llama C API** 的直接调用架构：

```
【修正前（文档方案，不推荐）】
Flutter  --HTTP localhost:8080-->  llama-server(C++)  ← 多一个server进程
   ↑                                   ↑
   └----------- SSE stream ------------┘

【修正后（官方示例验证，推荐）】
Flutter(Dart)
   │  (MethodChannel / dart:ffi)
   ▼
Kotlin: InferenceEngine (JNI 绑定)
   │  (JNI native call)
   ▼
C++: ai_chat.cpp (直接调用 llama C API)
   │  llama_decode() → token
   ▼
回传 token 到 Flutter → StreamBuilder 渲染打字机效果
```

**好处**：
- 少一个 server 进程，**省 50-100MB 内存**
- token 通过 JNI 回调直接到 Dart，延迟更低
- 后台推理用 Android `Foreground Service` 保活，比 HTTP server 更省电合规

**技术实现要点**：参考官方 `ai_chat.cpp` 的 `ggml_backend_load_all_from_path` + `llama_model_load_from_file`，用 `Java_com_..._load` 这样的 JNI 接口暴露给 Kotlin。

### 🔴 不足 3（重要）：视觉模型内存预算被严重低估

**文档假设**：
> "Qwen3.5-4B-Instruct | Q4_K_M ~2.0 GB | ✅ 中端以上手机可运行"

**真实情况**：
1. VL 模型不是单文件，而是 **LLM 部分 + 视觉编码器（mmproj）两部分**：
   - `qwen3.5-4b-q4_k_m.gguf`（语言模型，~2GB）
   - `mmproj-qwen3.5-4b-f16.gguf`（视觉编码器，**+0.5-1GB**）
2. 运行时还需要：图片预处理内存 + 视觉 token 注入上下文
3. 实际运行内存占用：**3-3.5GB**，而非文档说的 ~2GB

**影响**：中端手机（6GB RAM，系统占 2.5GB，可用 ~3.5GB）跑 3B-VL 会**逼近 OOM 边界**，极易被系统杀进程。

**弥补方案——视觉模块分层降级策略**：

| 设备档位 | 可用内存 | 推荐视觉方案 | 体积 |
|---------|---------|------------|------|
| 🟢 旗舰（≥8GB） | ~5GB+ | Qwen3.5-4B（LLM+mmproj） | ~3GB |
| 🟡 中端（6-8GB） | ~3.5GB | Qwen3.5-4B（更小变体）或 3B-Q3 | ~2GB |
| 🔴 低端（≤6GB） | ~3GB | **MOONCHIP/MiniCPM-Llama3-V 2.5（8B 但优化）** 或**禁用视觉**，仅文字 | — |

并增加**启动时内存自检**：视觉功能仅在内存充足时解锁，否则隐藏入口，避免崩溃。

### 🟡 不足 4（中等）：性能基准数据缺少"实测标注"

**问题**：`mobile_llm_benchmark_report_v2.md` 中的 tok/s 数据（如"iPhone 17 Pro ~35 tok/s"）没有标明**来源**——是实测、社区报告、还是理论估算。文档末尾虽有"基于训练数据整理"的免责声明，但正文表格读起来像权威数据，容易被当作承诺。

**弥补方案**：
- 所有性能表格增加**置信度列**：`[实测]` / `[社区报告]` / `[理论估算]`
- MVP 阶段必须建立**自有基准测试脚本**（`scripts/benchmark.py`），在真实目标设备上跑出真实数据，替换估算值
- 这是工程严谨性的基本要求，也是后续优化的度量基线

### 🟡 不足 5（中等）：进程/内存模型缺少 Android 后台杀进程应对

**问题**：文档提到"进程模型"但未考虑 Android 的**后台限制**：
- Android 8+ 严格限制后台 Service
- 长时间推理（10s+）时若 App 进后台，会被系统冻结/杀掉
- 用户切到其他 App 再回来，推理状态丢失

**弥补方案**：
1. 推理必须跑在 **Foreground Service**（前台服务 + 通知栏常驻），这是 Android 官方推荐的长时间任务方案
2. 推理状态做**断点保存**：每生成 N 个 token 存一次 KV cache 到磁盘，被杀后可恢复
3. 增加**推理中断恢复**机制：用户切回 App 时若发现推理中断，提示"继续生成？"

### 🟡 不足 6（中等）：Plugin 安全沙箱在移动端难以真正隔离

**问题**：`plugin_architecture.md` 设计的"独立内存空间、文件隔离、CPU 配额"，在**单进程 Flutter App 内**几乎无法实现。Dart/Flutter 不支持进程级沙箱，所谓"隔离"只是逻辑上的命名空间隔离，恶意 Plugin 仍能访问 App 全部内存。

**弥补方案**：
1. **降低安全承诺**：Plugin 沙箱定位为"**防误操作 + 资源配额**"，而非"**防恶意代码**"（后者在端侧 App 内不现实）
2. **Plugin 来源管控**：只允许从**官方签名市场**安装 Plugin，第三方 Plugin 需显式"开发者模式 + 风险确认"
3. **如果真要强隔离**：Plugin 用**独立 Android 进程**（`android:process=":plugin"`）跑，通过 IPC 通信——但成本高，列为可选

### 🟢 不足 7（轻微）：文档版本管理混乱

**问题**：
- 存在 v1/v2 并存（`architecture_design.md` + `architecture_design_v2.md`），内容大量重叠
- `mobile_llm_benchmark_report.md`（v1）已过时但仍保留，易混淆
- 之前还出现过文件被误删（已恢复）

**弥补方案**：
- v1 文档移入 `docs/archive/` 归档
- 建立文档**单一事实来源**原则：每个主题只有一份"当前版本"
- 本实施方案文档作为**索引页**，统一指向各主题的最新版

---

## 第三部分：可行性修正后的最终架构

> 综合优点放大 + 不足弥补后的落地架构。

### 3.1 修正后的分层架构

```
┌──────────────────────────────────────────────────────────────┐
│                     TongYi-Lite Android APK                    │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Layer 1: Flutter UI (Dart)                            │  │
│  │  · ChatScreen / VisionScreen / WildernessDashboard     │  │
│  │  · Riverpod 状态管理                                    │  │
│  │  · StreamBuilder 流式渲染                               │  │
│  └───────────────────────┬────────────────────────────────┘  │
│                          │ MethodChannel / Pigeon             │
│  ┌───────────────────────▼────────────────────────────────┐  │
│  │  Layer 2: Kotlin Platform Service                      │  │
│  │  · InferenceEngine (JNI 绑定，直接调用 llama C API)     │  │  ← 修正点：无 HTTP Server
│  │  · ForegroundService (推理保活)                        │  │  ← 修正点：后台保活
│  │  · PluginEngine (Plugin 加载/执行)                      │  │
│  │  · MemoryGuard (启动内存自检)                          │  │  ← 修正点：内存门槛
│  └───────────────────────┬────────────────────────────────┘  │
│                          │ JNI                                │
│  ┌───────────────────────▼────────────────────────────────┐  │
│  │  Layer 3: C++ Native (ai_chat.cpp)                     │  │
│  │  · llama_model_load_from_file()  加载模型               │  │
│  │  · common_chat_format_single()   格式化对话             │  │
│  │  · llama_decode() + 回调         逐 token 生成          │  │
│  │  · ggml_backend_load_all()       动态加载 CPU 后端       │  │  ← 修正点：CPU-only MVP
│  │  · [P2] Vulkan backend           GPU 加速（可选）       │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Layer 4: Storage & Models                             │  │
│  │  · SQLite: 对话历史、任务队列、玩家存档                  │  │
│  │  · /models/: GGUF 模型（LLM + mmproj 视觉）             │  │
│  │  · /plugins/: Plugin 包（manifest + 脚本）              │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 修正后的模型矩阵（含内存门槛）

| 用途 | 模型 | 体积 | 运行内存 | 设备门槛 | 可用性 |
|------|------|------|---------|---------|--------|
| 文字对话（旗舰） | Qwen3-1.7B-Q4_K_M | 1.2GB | ~2GB | ≥6GB RAM | ✅ |
| 文字对话（中端） | Qwen3-0.6B-Q4_K_M | 0.42GB | ~1GB | ≥4GB RAM | ✅ |
| 视觉理解（旗舰） | Qwen3.5-4B + mmproj | 3GB | ~3.5GB | ≥8GB RAM | ✅ |
| 视觉理解（中端） | 更小 VL 或降级禁用 | ~2GB | ~2.5GB | 6-8GB RAM | ⚠️ |
| 语音识别 STT | sherpa-onnx WeNet | 0.04GB | ~0.1GB | 全机型 | ✅ |
| TTS | Android 系统引擎 | 系统级 | ~0.03GB | 全机型 | ✅ |

### 3.3 修正后的开发优先级（MVP 聚焦）

**MVP（P0）只做文字对话**，砍掉所有"锦上添花"：
- ✅ Flutter 聊天 UI + 流式输出
- ✅ llama.cpp CPU 推理（JNI 直调，参考 `com.arm.aichat`）
- ✅ Qwen3-1.7B 模型加载/切换
- ✅ 模型下载（断点续传）
- ✅ SQLite 会话管理
- ❌ 视觉（P1）
- ❌ 语音（P1）
- ❌ Plugin/游戏化（P2）

> **理由**：先验证最难的"端侧推理链路跑通 + 性能达标"，再叠加功能。一上来全做，大概率在 JNI/内存问题上翻车。

---

## 第四部分：分阶段实施方案

### Phase 0：技术验证 Spike（1 周）⭐ 最高优先

> **目标：用最小代价验证"端侧推理是否真能跑起来、性能是否达标"。不写业务代码。**

| 任务 | 验证目标 | 产出 |
|------|---------|------|
| 0.1 复刻官方 `com.arm.aichat` | 能在 Android 真机加载 Qwen3-1.7B 并对话 | 可运行的 Demo APK |
| 0.2 真机基准测试 | 在 2-3 台目标设备测 tok/s | `benchmark_results.md`（真实数据） |
| 0.3 内存峰值测量 | 记录推理时 RSS/PSS 峰值 | 确认不会 OOM |
| 0.4 Vulkan 可行性预研 | 评估 NDK 编译 Vulkan 后端的难度 | Go/No-Go 决策 |

**Phase 0 的 Gate 条件**（全部满足才进 P1）：
- [ ] 真机对话 tok/s ≥ 8（CPU-only）
- [ ] 推理时内存峰值 < 设备 RAM 的 60%
- [ ] 连续对话 10 轮无崩溃

### Phase 1：MVP 文字对话（2-3 周）

| 模块 | 任务 | 依据 |
|------|------|------|
| Flutter UI | 聊天气泡 + 流式渲染 + 输入栏 | `architecture_design.md` 第 5 节 |
| 推理引擎 | JNI 直调（非 HTTP server） | **修正点 2** |
| 模型管理 | 下载/切换 + 内存自检建议 | **优点 4 补充** |
| 会话管理 | SQLite 多轮对话 | `architecture_design_v2.md` 第 6 节 |
| 后台保活 | ForegroundService | **修正点 5** |

### Phase 2：多模态扩展（2-3 周）

| 模块 | 任务 | 依据 |
|------|------|------|
| 视觉理解 | Qwen3.5-4B + mmproj + 分层降级 | **修正点 3** |
| 语音输入 | sherpa-onnx STT 集成 | `architecture_design_v2.md` 第 4 节 |
| TTS 播报 | Android TextToSpeech | `architecture_design_v2.md` 第 4 节 |

### Phase 3：Plugin + 游戏化（2-3 周）

| 模块 | 任务 | 依据 |
|------|------|------|
| Plugin 引擎 | 加载/执行/生命周期 | `plugin_architecture.md` 第 2 节 |
| 安全策略 | 来源管控 + 降级承诺 | **修正点 6** |
| 荒野求生 | 等级/成就/挑战 | `plugin_architecture.md` 第 4 节 |
| 远程任务 | WebSocket + 离线队列 | `plugin_architecture.md` 第 3 节 |

### Phase 4：体验打磨（持续）

- Vulkan GPU 加速（若 P0 验证可行）
- iOS 适配（Metal 原生支持，相对容易）
- 传感器环境感知（**优点 3 补充**）
- 数据足迹仪表盘（**优点 1 补充**）

### 时间线总览

```
Week 1     ▏Phase 0: 技术验证 Spike
Week 2-4   ▏█████████ Phase 1: MVP 文字对话
Week 5-7   ▏█████████ Phase 2: 视觉+语音
Week 8-10  ▏█████████ Phase 3: Plugin+游戏化
Week 11+   ▏█████████ Phase 4: 持续打磨
```

---

## 第五部分：风险登记册

| ID | 风险 | 概率 | 影响 | 缓解措施 | 负责阶段 |
|----|------|------|------|---------|---------|
| R1 | CPU-only 性能不达标（<8 tok/s） | 中 | 高 | P0 提前验证；备选更小模型 Qwen3-0.6B | Phase 0 |
| R2 | Qwen3.5-4B 在中端机 OOM | 高 | 高 | 分层降级 + 内存自检门槛 | Phase 2 |
| R3 | Vulkan 后端兼容性差（Adreno/Mali） | 高 | 中 | CPU-only 兜底；Vulkan 设为 P2 可选 | Phase 4 |
| R4 | Android 后台杀进程导致推理中断 | 高 | 中 | ForegroundService + 断点恢复 | Phase 1 |
| R5 | llama.cpp 版本快速迭代导致 API 变更 | 中 | 中 | 锁定 b10173 版本，升级前做回归 | 全周期 |
| R6 | Plugin 安全漏洞被利用 | 低 | 高 | 来源管控 + 降低安全承诺 + 开发者模式 | Phase 3 |
| R7 | 模型下载体积大（~1-3GB）劝退用户 | 中 | 中 | 分片下载 + 首启引导 + WiFi 提示 | Phase 1 |
| R8 | HuggingFace 国内访问受限 | 高 | 中 | ModelScope 镜像源 + 自建 CDN | Phase 1 |

---

## 附录：文档索引（单一事实来源）

| 主题 | 当前版本 | 归档/废弃 |
|------|---------|----------|
| 架构设计 | `architecture_design_v2.md` | `architecture_design.md`（v1，待归档） |
| 基准报告 | `mobile_llm_benchmark_report_v2.md` | `mobile_llm_benchmark_report.md`（v1，待归档） |
| Plugin/游戏化 | `plugin_architecture.md` | — |
| **实施方案（本文档）** | `implementation_plan.md` ⭐ | — |

> 本实施方案是对上述文档的**评审与修正**，存在冲突时以本文档为准。后续设计文档更新应同步反映本文档的修正结论。

---

*实施方案完毕。建议立即启动 Phase 0 技术验证 Spike，用真实数据替换所有估算假设。*
