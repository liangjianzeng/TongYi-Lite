# MiniCPM-V 4.7 llama.cpp 实现与装载调研（llama.cpp-omni 解剖）

> 调研日期：2026-10-14 ｜ 触发：ModelScope 集合 OpenBMB/MiniCPM-V-47
> 前置：docs/MiniCPM-V4.7_调研报告_2026-10-13.md（模型侧/性能侧已定案），本篇补齐 **llama.cpp 实现细节 + 装载可行性**。
> 方法：浅克隆 `tc-mb/llama.cpp-omni`（ios-omni 分支，2026-10-13 提交头）源码实读 + ModelScope API 文件清单 + 官方 GGUF 头部 Range 探查。

---

## 1. 一句话结论

| 项 | 结论 |
|---|---|
| llama.cpp-omni 是什么 | MiniCPM-V-Apps 三端 App 共用的 llama.cpp fork（`tc-mb/llama.cpp-omni`，非 OpenBMB 主 org），基线是**较老的 upstream 快照**（arch.h 654 行 vs 我们 b11267 的 829 行），上面加了 **MoE 专家流式（slot runtime）+ LES 前瞻预取 + mtmd 视觉** 三块 |
| 模型 GGUF 用什么架构 | 语言底座 `general.architecture = **qwen35moe**`（Range 探查官方 Q4_K_M 与 mix_q3gud_im 实锤），**不是** minicpmv4_7——minicpmv4_7 只是 mmproj 视觉塔的 projector 类型 |
| 我们能装载吗 | **语言部分（纯文本）我们现在就能载**：vendored b11267 已含 `LLM_ARCH_QWEN35MOE`（llama-arch.h:47）。视觉部分缺 `clip_graph_minicpmv4_7`（在他们 mtmd/clip.cpp:908）。-les 拆分版需移植他们的 manifest loader |
| CPU/GPU 双线判位 | 他们的实现 = **CPU 侧 slot 流式 + 预读，计算留在 Metal/CPU**；OpenCL 的 mul_mat_id 只做了 q4_0/q4_1/q5_0/q5_1（K 系标 TODO）⇒ **我们 OpenCL batched q4_0/q4_K 在 GPU MoE 上已反超**，他们的价值在**调度与装载机制**而非 GPU 内核 |
| 最值钱的代码 | `src/llama-moe-slot.cpp`（2772 行）+ `llama-moe-experts.cpp`（169 行 manifest 解析）——就是我们三步走 P2「专家分层调度」的工业级参考实现 |

---

## 2. llama.cpp-omni 解剖（源码实读）

### 2.1 仓库与基线

- 正确仓库：**`tc-mb/llama.cpp-omni`**（OpenBMB org 下同名仓库只有 main 单分支，三端 App submodule 指向 tc-mb）。App 用的分支 `ios-omni`；另有 `feat/moe_ssd`、`opt/r5.1-moe-ssd`、`bench/huawei` 等活跃分支。
- 后端构成：**cpu / metal / opencl / vulkan 全都在源码里**。「Android 纯 CPU」是 App 的 CMakeLists 构建选择（`MiniCPM-V-demo-Android` 只编 CPU 变体），不是引擎能力边界。
- 上游代际：比我们 vendored 的 b11267 老（无 cl-program-cache 等 b11267 特性），⇒ **他们的调度代码可以往我们新基线上移植，反向不行**。

### 2.2 核心机制五件套（全部在 ios-omni 分支）

| # | 机制 | 实现位置 | 要点 |
|---|---|---|---|
| 1 | **专家 slot 缓存** | `src/llama-moe-slot.cpp`（2772 行）| 每层固定 slot 数的专家缓冲槽（decode 窗口），`process()` 是 CPU 自定义 op，每层每 token 跑一次：回读 expert_ids → miss 的 preadv 读盘装入槽位 → 写回 slot_ids。带 `park_expert_memory()`（Metal 专用：一轮生成后拆缓冲、丢宿主物理页防常驻） |
| 2 | **LES 前瞻预取** | 同文件 `lookahead_expert_prefetch` 结构 | 「下一层 router × 当前层 hidden（attn_post_norm 输出）」预测 top-8，**复用现成 router 零训练**；`LLAMA_MOE_LOOKAHEAD_PREFETCH=1` 开，DEPTH 1..16 可调；预测 ID 走 preadv 进共享 bank 的乒乓尾段 |
| 3 | **延后读取（A2 phase B）** | `process_deferred()` + `build_deferred_trigger()` | 把每层最后 N 个专家的读取**推迟到前段 matmul 算完之后**（建图时以依赖触发），`LLAMA_MOE_MATMUL_SPLIT` 控制 = 「用 attention 时间藏 UFS 读」的具体实现 |
| 4 | **静态预热** | `prewarm_experts()` | prefill 前空闲期把预热表读进各层 decode 窗口（decode/prefill 物理分离，能活过 prefill），对应我们「专家热集」概念 |
| 5 | **manifest 专家装载** | `src/llama-moe-experts.cpp`（169 行） | 解析 `experts/manifest.json`（schema_version=1，experts_kind/layout/model/entries），把主 GGUF 里「按 manifest 合成的、不在 weights_map 里」的专家张量映射到 `layer_XXX.bin` 分片；`create_expert_tensor_from_manifest()` 在 llama-model 里建张量 |

I/O 机制：**preadv 多线程（`LLAMA_MOE_IO_THREADS`）把打包的专家 span 直读进 host-visible 槽位**（Apple 统一内存 → Metal buffer 即宿主可见；Android CPU buffer 同样 host-visible ⇒ 机制可平移）。要求 gate/up/down 每专家连续打包（manifest 的 `layout` 字段管这个）。

全部旋钮（env，App 侧对应设置项）：
`LLAMA_MOE_IO_THREADS / PARK_WINDOW / LOOKAHEAD_PREFETCH[=DEPTH] / PREFETCH_READ / MATMUL_SPLIT / DECODE_WINDOW / PREFETCH_UNIFIED / LAYER_WINDOWS / WINDOW_MAX_ROWS / PREWARM / F_NOCACHE`

诊断/工程化亮点：`counters_snapshot()` 把每前向的 process/readids/install/writeids/miss/bytes/unique 纳秒级拆账（注释里明确写了「实测 1 行步非 I/O 记账 3.5ms、3 行步 19.5ms」这种调优记录）——我们 P2 需要同款探针。

### 2.3 他们 OpenCL 的 MoE 能力（与我们对位）

`ggml_cl_mul_mat_id`（ggml-opencl.cpp:14325 起，约 800 行，含重排/复用逻辑）：
- **已实现：Q4_0 / Q4_1 / Q5_0 / Q5_1**
- **K 系（q4_K/q5_K/q6_K/q8_0）标着 `TODO: general MoE for the following types`**
- 无 Adreno 专项优化痕迹（无 batched MUL_MAT_ID、无 host 预计算 dodge、无驱动 bug 防御）

⇒ 判定：**GPU MoE 内核这条线我们已经领先**（我们的 batched q4_0 + q4_K 预计算 dodge 在 Adreno 830 真机 11/11 形状 NMSE=0）。他们的护城河全在调度层。

### 2.4 模型产物盘点（ModelScope 实查）

**官方仓 `openbmb/MiniCPM-V-4.7-35B-A3B-gguf`**（333.75 GB，2026-10-13 更新）：

| 文件 | 大小 | 说明 |
|---|---|---|
| F16 | 66.2 GB | |
| Q4_K_M / Q4_K_S / Q4_0 | 20.2 / 19.0 / 18.8 GB | CookBook 门槛 ≥24GB 内存 |
| **mix_q3gud_im** | **14.8 GB** | **专家 = Q3_K 系 + imatrix 的逐层混精**（Apps README 明示 "q3gud-im (Q3_K experts)"），门槛 ≥18GB |
| mmproj-model-f16 / -4x | 1.07 / 0.87 GB | 视觉塔 f16（官方：量化视觉塔掉感知明显，保 f16） |
| Q8_0 | 35.2 GB | |

**拆分版（端侧用）`zerg13/MiniCPM-V-Apps-gguf`**（HF 对应 `tc-mb/MiniCPM-V-Apps-gguf`）：

| 文件 | 大小 |
|---|---|
| `MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf` | **1.59 GB**（专家已剥离，只含 dense/attention/router） |
| `experts/layer_000..039.bin` | **40 × 330 MB = 13.2 GB**（每层一个分片 = 权重连续布局重排的落地产物） |
| `experts/manifest.json` | 0.1 MB（schema v1） |
| `mmproj-model-f16.gguf` | 1.07 GB |
| （另有 VoxCPM2 TTS 两个文件 + 1B dense 版） | |

合计 ~16.6 GB，官方推荐 ≥12GB RAM + 快速闪存；**批次不匹配会通不过端上完整性校验直接拒载**。

### 2.5 关键架构实锤（GGUF 头部 Range 探查）

```
general.architecture = qwen35moe        ← 语言底座（不是 minicpmv4_7！）
general.name         = 35a3_hf_v47_0923
general.size_label   = 256x2.6B
qwen35moe.rope.section_order = zyxt
```

视觉部分才是 `minicpmv4_7` projector（他们 mtmd/clip-impl.h:399 + clip.cpp:908 的 `clip_graph_minicpmv4_7`）。**上游 master llama.cpp 也没有 minicpmv4_7 视觉支持**（llama-arch.h 仅 MINICPM/MINICPM3）——即官方 GGUF 的视觉部分目前只有 llama.cpp-omni 能跑。

---

## 3. 装载可行性判定（对 vendored b11267 @ TongYi-Lite）

| 目标 | 可行性 | 缺口 |
|---|---|---|
| ① 纯文本载官方 Q4_K_M（整个模型单文件，专家内联） | **现在就可试**：vendored 已有 QWEN35MOE 架构；20.2GB 只能 DGX/PC 验证，手机放不下 | 无（架构命中） |
| ② 纯文本载 mix_q3gud_im（Q3_K 专家） | CPU 路径可行（Q3_K 是标准类型）；OpenCL 白名单无 q3_K ⇒ 专家走 CPU | 需真机内存 ≥18GB 池——**8 Gen5 16G 不够**，仅 DGX 可验 |
| ③ 装载 -les 拆分版（手机真正可跑的形态） | **需移植两块代码**：manifest loader（169 行，直接抄）+ slot runtime（2772 行，需适配） | Metal park 逻辑换 Android 等价物；preadv 目标从 Metal buffer 换我们 CPU slot 或 OpenCL 上传路径 |
| ④ 视觉（mmproj） | 暂不可行 | 缺 clip_graph_minicpmv4_7；我们当前纯文本路线不需要 |

⇒ **「装载可用」的路径**：不需要切到他们的 fork（基线太老、会丢我们 dspark/OpenCL 全部补丁）。正确姿势 = **把他们的调度三件套（manifest loader / slot runtime / LES）移植进我们 vendored b11267**，套在我们已有的 OpenCL batched MoE 内核上。

---

## 4. 与三步走 CPU/GPU 双线的映射

| 我们规划（P2 调度四件套） | llama.cpp-omni 对应物 | 借鉴方式 |
|---|---|---|
| 热度表 | `LLAMA_MOE_PREWARM` 静态预热表 + slot LRU | 参考其窗口 slot 设计 |
| per-layer 填充 | 每层 decode 窗口（`LAYER_WINDOWS`/`DECODE_WINDOW`） | 直接抄 slot 数据结构 |
| 超集异步预读（读 top-32 用 top-8） | **LES：下一层 router 真实预测 top-8**（零训练、命中 >80%） | **升级采纳**（上轮报告已定），本次确认其实现就在 `lookahead_expert_prefetch`，且预测 ID 走乒乓 bank 与计算重叠 |
| 预算切分 | `MATMUL_SPLIT` 延后读取 + `IO_THREADS` preadv | **新增采纳**：A2 phase B「前段算完再读后段」正是「attention 藏 UFS 读」的现成实现 |
| （无对应） | counters 纳秒级拆账 | **新增**：P2 探针照此设计 |
| CPU 线（KleidiAI / 多编译档） | App 动态 dispatch（libggml-cpu-v86，上轮已录） | 不变 |
| GPU 线（OpenCL batched q4_0/q4_K） | 他们 OpenCL MoE 仅 q4_0/q4_1/q5_0/q5_1 | **无需借鉴，我们领先**；移植 slot runtime 时 GPU 侧接我们的 batched 内核 |

**同构同理的验证**：我们的「L0 Adreno 热集 3-3.5G / L1 CPU / L2 UFS mmap」三档分层 = 他们的「slot bank（常驻）+ preadv 流式（存储）+ park（降常驻）」；他们的 3.30× 单项增益（调度）是对我们门控假设「冷专家命中不 stall」的外部实证——上轮报告结论维持，本次拿到实现级细节。

**差异警示（不变）**：13+ t/s 出自 Apple 统一内存 + NVMe；我们的 Adreno OpenCL + UFS 4.x 数字必须自己测。且他们 App Android 构建是纯 CPU——**「MoE-SSD 流式 + Android」他们也没给出 GPU 成绩**，这正是我们 A 线（OpenCL）的差异化空间。

---

## 5. 端侧装载专项（2026-10-14 补，口径 = TongYi-Lite 手机端，非 DGX）⭐

### 5.1 真机硬指标（adb 实测测试机）

| 项 | 实测 | 门槛（官方 Apps README） | 判定 |
|---|---|---|---|
| SoC | **SM8750（骁龙 8 Elite / Adreno 830）** | — | 与我们全部 OpenCL 内核验证同机 ✓ |
| RAM | **15.5 GB**（MemTotal 15,476,460 kB） | ≥ 12 GB | ✓ |
| 存储 | 150 GB 可用 | ~17 GB（拆分版全量） | ✓ |

⇒ **这台测试机直接满足 35B-A3B 拆分版装载条件**，且官方 Apps 在 12GB iPhone 17 Pro 验证过同款装载路径；低内存机只是专家缓存变小、变慢，不会拒载。

### 5.2 装载形态判定：只有 -les 拆分版可行

| 形态 | 体积 | 手机判定 |
|---|---|---|
| 官方 Q4_K_M（专家内联） | 20.2 GB | ✗ mmap 4K 页故障死路（我们自测 216 页×100µs）+ Apps README 实锤「整包 OS 杀」 |
| mix_q3gud_im（专家内联） | 14.8 GB | ✗ 同上（≥18G 内存门槛超 16G 机型） |
| **-les 拆分版**（主文件 1.59G + experts/ 40×330M + manifest） | ~14.8G 纯文本（免 mmproj 省 1.07G） | **✓ 唯一可行**：专家按需 preadv，slot bank 常驻可控 |

### 5.3 -les 主文件量化构成（Range 探查 613 张量实锤）

| GGML 类型 | 数量 | 张量 | 我们 OpenCL 白名单 |
|---|---|---|---|
| F32 (t0) | 301 | router `ffn_gate_inp`(2048×256)、全部 norm | ✓ |
| **Q4_K (t12)** | 271 | **token_embd**(2048×248144)、共享专家 gate/up、attn_gate | **✓（batched 修复已验证）** |
| **Q6_K (t14)** | 41 | **attn_qkv**(2048×8192)×40、lm_head output、ffn_down_shexp | ✓ |

⇒ **dense 部分全部落在 Adreno 白名单内**：L0 GPU 跑 attention/dense（85% 每 token 时间），L1 CPU 跑 Q3_K 专家流式，L2 UFS 放专家分片 —— 与三步走「L0 热集 / L1 CPU / L2 mmap」分层**逐字对应**。另外 metadata `qwen35moe.attention.recurrent_layers`(40×bool) 直接给出 30 线性+10 全注意力的分层表。

### 5.4 专家分片格式（manifest.json 实测，已存 `_probe/minicpm47_experts_manifest.json`）

- `schema_version=1`，`layout="layer_major_expert"`，`experts_kind="omni_moe_gguf"`
- **120 条 = 40 层 × {ffn_gate_exps / ffn_up_exps / ffn_down_exps}**
- 每条：`quant_type: "Q3_K"`、`shape [2048,512,256]`（gate/up）/ `[512,2048,256]`（down）、`bytes_per_expert: 450560`、`source_offset`（从 mix_q3gud_im.gguf 抽出的原始位置）、`repacked_offset`（layer_XXX.bin 内偏移）
- 每专家每层 ≈ 1.35MB；每层每 token top-8 ≈ **10.8MB 顺序读**，UFS4.x ~1GB/s 有效读下 ≈ 10ms/层（无预取时）⇒ LES 命中 >80% 是把这笔藏掉的关键
- **关键设计红利：`quant_type` 是 per-entry 字段** ⇒ 未来自制 q4_0/q4_K 专家包（我们 batched 已验证的格式）可沿用同一 manifest schema 混合混排，loader 不用改

### 5.5 App 工程清单（TongYi-Lite 侧）

| 层 | 工作项 | 量级 |
|---|---|---|
| llama.cpp（vendored） | 移植 `llama-moe-experts.cpp`（manifest loader）→ slot runtime → LES/MATMUL_SPLIT | 169 行照抄 + 2772 行裁剪适配（Metal park 换空实现） |
| JNI | 透传 experts 目录路径 + slot/LES 参数 | 小 |
| Dart 模型管理 | catalog 新条目类型 `split-moe`；下载器多文件（主文件+40 分片+manifest，ModelScope 直链）；目录布局 `{model_id}/{main.gguf, experts/, manifest.json}` 与官方 App 一致；manifest 完整性校验 | 中 |
| 首版范围 | **纯文本**（跳过 mmproj 1.07G 与 clip_graph_minicpmv4_7 移植） | 减负 |
| GPU 侧 | dense 走现有 OpenCL（白名单全覆盖，无需新内核）；专家先 CPU；后续把专家重打包 q4_0/q4_K 上我们 batched 内核 | 分两步 |

### 5.6 风险与存疑

| 项 | 状态 |
|---|---|
| SM8750 UFS 实际读速 | 未实测（P0 顺手测，决定 slot bank 配额） |
| slot runtime 对非 Metal 后端的适配工作量 | preadv 目标是 host-visible CPU 内存（Android CPU buffer 同样满足），主要删 Metal park 逻辑；`process()` 每 token 40 层的记账开销他们自己实测 3.5ms/步（1 行步）——需要在 8 Elite 上复测 |
| 混合执行（dense GPU + 专家 CPU）的同步开销 | 我们已有 OpenCL↔CPU 混合调度经验（现 App 多后端探测）；真正要防的是 GPU 等专家读盘 stall，靠 MATMUL_SPLIT 延后读取 |
| 内存峰值 | 主文件 1.59G 常驻 + slot bank（建议 32 槽/层×40 层×1.35MB≈1.7G）+ KV + App ≈ 4-5G，16G 机充裕；可按官方策略低内存机自动缩槽 |

---

## 6. 行动建议（端侧口径，2026-10-14 修订）

1. **P0 真机装载实验（本周）**：测试机（SM8750/16G）拉 zerg13 拆分版纯文本（主文件 1.59G + 40 分片，~14.8G）；先在 PC/DGX 用移植了 manifest loader 的 vendored llama.cpp 验证装载正确性，再上真机 CPU-only 路径测 decode t/s + UFS 读速——拿到「同构 35B-A3B 在我们 SoC 上的第一手基线」。
2. **P2 移植清单立档**（顺序即依赖）：① `llama-moe-experts.cpp` manifest loader（169 行，照抄）；② slot runtime 的数据结构与 preadv 直载（2772 行裁剪，Metal park 换 Android 空实现/ashmem）；③ `lookahead_expert_prefetch`（LES）；④ counters 探针。GPU 侧 dense 直接用现有 OpenCL；专家先 CPU，后续重打包 q4_0/q4_K 上 batched 内核。
3. **不为装载而换引擎**：llama.cpp-omni 基线老、且其 App Android 是纯 CPU——我们保持 vendored b11267 + 自有补丁面，只移植调度层。拆分版 manifest `quant_type` per-entry 设计保证未来自制 q4_0/q4_K 专家包零 schema 改动。

---

## 附：本轮新证据源

- `tc-mb/llama.cpp-omni` ios-omni 分支源码（克隆在 `_probe/llama.cpp-omni`，勿 commit）
- ModelScope API：`openbmb/MiniCPM-V-4.7-35B-A3B-gguf`（17 文件/333.75GB）、`zerg13/MiniCPM-V-Apps-gguf`（56 文件，含 40×330MB 专家分片）
- 官方 GGUF 头部 Range 探查：`general.architecture = qwen35moe`
- OpenBMB/MiniCPM-V-Apps README：硬件门槛表、"q3gud-im (Q3_K experts)"、专家分片流式说明
