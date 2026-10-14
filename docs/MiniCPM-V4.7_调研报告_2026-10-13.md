# MiniCPM-V 4.7 调研报告

> 调研日期：2026-10-13 ｜ 触发：量子位《iPhone断网跑35B多模态！国产开源新模型，只占3G内存》
> 结论先行：**这不是一个"别人的模型"，而是与 TongYi-Lite 目标模型（Qwen3.6-35B-A3B）几乎同构的端侧 MoE，且面壁已经把它在手机上跑通并开源了全套方法论。** 本报告第 6 节给出对三步走方案的直接影响。

---

## 1. 一句话结论

| 项 | 结论 |
|---|---|
| 是什么 | 面壁智能（ModelBest）× OpenBMB × 清华，首个 **MoE 多模态**版 MiniCPM-V，Apache-2.0 |
| 为什么跟我们有关 | 它的语言底座 config 标记 **`qwen3_5_moe_text`**，40 层 / 30 线性+10 全注意力 / 256 专家 top-8 / 词表 248,144 —— 与我们要跑的 **Qwen3.6-35B-A3B（40 层 / 30 DeltaNet+10 attn / 256 专家 top8+1shared / 词表 248,320）同族同规格** |
| 它做成了什么 | iPhone 17 Pro Max 上 **13+ t/s、常驻工作集约 3GB**；iPad Pro M4 分阶段实测最终 **5.86×** 于未优化基线 |
| 对我们的价值 | **LES（前瞻专家调度）是我们"超集异步预读"的精确化版本**，且已开源（llama.cpp-omni）；但它的成绩来自 Apple 统一内存平台，**不可直接外推到骁龙 + UFS + Adreno** |
| 最大冲突点 | 它用 **DSpark 投机在端侧拿到 +16.5%**（14.92→17.39 t/s），而我们方案的前提 A 写的是"端侧不做投机（负收益）"——**必须复核** |

---

## 2. 模型规格（官方 config 实读）

### 2.1 语言底座 `text_config`（35B-A3B）

| 字段 | 值 | 备注 |
|---|---|---|
| `model_type` | **`qwen3_5_moe_text`** | 语言堆栈直接标 Qwen3.5 MoE |
| `architectures` | `MiniCPMV4_7ForConditionalGeneration` | 多模态包装类 |
| `num_hidden_layers` | **40** | 与 Qwen3.6-35B-A3B 相同 |
| `layer_types` | **30 × `linear_attention` + 10 × `full_attention`**（`full_attention_interval: 4`） | 3:1 混合，与目标的「30 DeltaNet + 10 attn」一一对应 |
| `linear_conv_kernel_dim` | 4 | Mamba 风格短卷积 |
| `linear_num_key_heads` / `linear_num_value_heads` | 16 / 32 | key_dim 128 / value_dim 128 |
| `mamba_ssm_dtype` | float32 | SSM 状态高精度 |
| `num_attention_heads` / `num_key_value_heads` / `head_dim` | 16 / 2 / 256 | GQA 8:1 |
| `attn_output_gate` | true | 输出门控 |
| `num_experts` / `num_experts_per_tok` | **256 / 8** | 细粒度 MoE |
| `moe_intermediate_size` | 512 | 每专家很窄 |
| `shared_expert_intermediate_size` | 512 | **有共享专家**（与目标 1shared 一致） |
| `mtp_num_hidden_layers` | **1** | **有 MTP 投机头**（目标模型无） |
| `max_position_embeddings` | 262,144 | 真 256K |
| `rope_theta` / `partial_rotary_factor` | 1e7 / 0.25 | 仅 1/4 维度旋转 |
| 多模态 RoPE | `mrope_interleaved: true`，section [11,11,10]，mode `canvas` | |
| `vocab_size` | **248,144** | 目标为 248,320，差 176（视觉特殊 token） |
| `hidden_size` | 2048 | |

### 2.2 视觉塔 `vision_config`

`minicpmv4_7_vision`：27 层 / hidden 1152 / patch 14 / image_size 980 / GELU-tanh；`insert_layer_id: 6`（视觉嵌入在第 6 层注入语言堆栈）；`downsample_mode: "16x"`（可切 4x）。

### 2.3 两个版本

| 版本 | 参数 | 结构 | BF16 体积 | 词表 | 底座标记 |
|---|---|---|---|---|---|
| **35B-A3B** | 35,212,875,824 | MoE，8/256 激活 | **70.4 GB / 16 shards** | 248,144 | `qwen3_5_moe_text` |
| **1B** | 1,554,476,272 | dense，24 层（18 线性 + 6 全） | 3.11 GB 单文件 | 248,094 | `qwen3_6_text` |

> 1B 的底座标记是 `qwen3_6_text`，35B-A3B 是 `qwen3_5_moe_text` —— 两者都指向 Qwen hybrid linear-attention 家族，**与 TongYi-Lite 目标模型同源**。

---

## 3. 三项核心技术（官方口径）

### 3.1 LES · 前瞻专家调度（Lookahead Expert Scheduling）

**问题**：MoE 每层的专家选择依赖上一层输出，权重在闪存上时"只能等路由完成后才开始读盘"，这段等待卡在每层计算之前。

**做法**：
1. **跨层路由预测**：把**当前层的路由输入特征**直接送进**下一层的 router** 计算，取分数最高的 8 个作为预取目标 —— **复用现成 router，无需训练任何额外网络**；
2. **权重存取并行**：后台线程在该层计算的同时把专家权重读进预分配缓冲槽；
3. **计算顺序调整**：实际路由选中且**已加载到位**的专家先算，未命中的专家同步加载。
4. **关键红线**：预测只影响预取与调度顺序，**最终每个 token 用哪些专家仍由原路由决定**；没猜中的照常加载、照常计算，不会为了提速省专家。

**官方数据**：命中率 **>80%**；调度+加载这一项单独带来 **3.30×**（见 §4）。

> 🔑 这是本报告对我们最有价值的部分 —— 我们的「超集异步预读（读 top-32 用 top-8）」是同一思路的**朴素版**：靠扩大候选集合提高命中率，但没有借用下一层 router 做真实预测。换成 LES 的做法，命中率可量化（>80%），且零训练成本。

### 3.2 逐层混合精度量化 + 权重连续布局重排

- 逐层混精：**专家权重压得更小**（减少单次加载字节），同时"基本保留能力"；
- **重新组织为连续存储布局**：减少零散读取，让闪存走顺序读。

> 与我们的 GSQ hybrid（专家 T42 2.25bpw + dense Q8_0 + BF16 embd）思路一致；差异是他们把它做成了可发布的 GGUF（`mix_q3gud_im`，见 §5.2）。

### 3.3 DSpark 投机采样

配套草稿模型 + 主模型批量核验；与 MTP 头（`mtp_num_hidden_layers: 1`）同源。官方两处数据：

- iPad Pro M4 16GB：**14.92 → 17.39 t/s（+16.5%）**
- M5 Mac 16GB：解码平均**再提升 17%**

> ⚠️ 我们的 DGX 已在用 dspark 草稿（Q8_0），coupled 下 +28.9%；但**端侧方案却写着"不做投机（负收益）"**。这两条口径必须对齐（见 §6.3）。

### 3.4 附带：自回放微调（Self-Replay Fine-Tuning）

微调前让模型先答一批覆盖原有能力的问题 → 筛高质量回答 → 混进新任务训练数据。**比在线 RL / On-Policy Distillation 便宜**（无需每次训练重新采样），回放数据只生成一次可复用，沿用标准 SFT 流程、不改结构不改 loss。用于解决"业务微调后通用能力退化"。

---

## 4. 性能数据（官方，含分阶段解耦）

### 4.1 端侧解码（**厂商自测，未经第三方复现**）

| 设备 | 数字 | 内存 |
|---|---|---|
| iPhone 17 Pro Max | **13+ t/s**（文章另称优化后 8–12 t/s 于某演示场景） | **约 3 GB 常驻工作集** |
| iPad Pro（实测口径） | **15+ t/s** | — |

**iPad Pro M4 11" 16GB 的分阶段拆解（官方 LES 技术笔记，最有价值的一张表）**：

| 阶段 | t/s | 相对上一阶段 | 相对基线 |
|---|---|---|---|
| 基线（存储加载，无优化） | 2.97 | — | 1.00× |
| ＋调度 / 加载优化（LES） | 9.81 | **3.30×** | 3.30× |
| ＋量化（逐层混精） | 14.92 | 1.52× | 5.02× |
| ＋DSpark 投机 | **17.39** | 1.17× | **5.86×** |

> 这张表把「流式调度 / 量化 / 投机」三项的贡献分开了 —— **调度是最大单项（3.30×），但投机不是零（1.17×）**。

### 4.2 质量 benchmark（官方发布，图内数据）

| 类别 | 基准 | 35B-A3B |
|---|---|---|
| 通用视觉 | MMBench | 91.72 |
| | MMStar | 80.67 |
| 理科 | MMMU | 80.22 |
| | MathVista | 88.00 |
| 视频 | Video-MME | 76.40 |
| | LongVideoBench | 68.90 |
| 文档 | **OmniDocBench v1.6** | **94.24**（领先次优 12+ 分） |
| 纯文本 | CMMLU / τ²-Bench | 90.21 / 84.65 |
| 16× 视觉压缩代价 | MMBench 91.72→**90.87**；OCRBench 91.20→**90.40** | 省算力几乎不换精度 |

官方另宣称：**Instruct 模式下，比 Qwen3.6 35B-A3B 综合分更高、推理时间更短** —— 该宣称只存在于一张对比图内，**无表格、无复现**。

---

## 5. 端侧部署的真实含义（去水分）

### 5.1 "3GB" ≠ 模型只有 3GB

官方与多家分析都强调：**约 3GB 指的是特定部署方案（LES + 量化 + 流式加载）下的运行内存占用，不是权重的存储体积。** 朴素算法：

- 35B 参数 BF16 ≈ 70 GB；理想 4bit ≈ 17.5 GB（还不含量化元数据）

### 5.2 官方部署门槛表（MiniCPM-V-CookBook）

| 形态 | 后端 | 内存门槛 |
|---|---|---|
| 35B-A3B BF16 / FP16 | vLLM / SGLang | ≥ 80 GB |
| FP8 / INT4 / AWQ / GPTQ | vLLM | ≥ 40 GB |
| **GGUF Q4_K_M** | llama.cpp / Ollama | **≥ 24 GB** |
| **GGUF `mix_q3gud_im`** | llama.cpp | **≥ 18 GB** |
| （视觉塔 + KV 常额外 +2 GB） | | |

> `mix_q3gud_im` 就是 LES 配套的"逐层混合量化 + imatrix"GGUF 产物 —— **18GB 的池子 + 流式调度 = 3GB 常驻工作集**。这正好印证我们方案里"权重不全量常驻"的前提 B 是成立的。

### 5.3 生态

- **系统**：iOS / Android / HarmonyOS
- **芯片 day-0**：瑞芯微、后摩、Intel、AMD、Arm（另有报道含 NVIDIA、Apple）
- **推理框架**：SGLang / vLLM / llama.cpp / Ollama / OpenVINO
- **微调**：SWIFT / LLaMA-Factory
- **量化**：GGUF / BNB / AWQ / GPTQ / FP8 / int4
- **端侧引擎**：`OpenBMB/llama.cpp-omni`（LES 的实现载体）+ `MiniCPM-V-Apps`
- **权重**：HF `openbmb/MiniCPM-V-4.7-35B-A3B`、Shape/ModelScope `OpenBMB/MiniCPM-V-4.7-35B-A3B-gguf`

---

## 6. 对 TongYi-Lite 三步走的直接影响 ⭐

### 6.1 同构度判定：这是"同一道题的另一份答卷"

| 维度 | MiniCPM-V 4.7 35B-A3B | Qwen3.6-35B-A3B（我们目标） | 判定 |
|---|---|---|---|
| 语言底座 | `qwen3_5_moe_text` | Qwen3.6 MoE | **同族** |
| 层数 | 40 | 40 | **相同** |
| 注意力构成 | 30 linear + 10 full | 30 DeltaNet + 10 attn | **相同（3:1）** |
| 线性层卷积核 | 4（Mamba 风格） | — | 同风格 |
| 专家 | 256，top-8，+shared(512) | 256，top-8，+1shared | **相同** |
| 词表 | 248,144 | 248,320 | 差 176（视觉 token） |
| MTP | **有（1 层）** | 无 | **差异** |
| PLE | 无 | 无 | 相同 |
| 视觉塔 | 27 层 / hidden 1152 | 无 | 35B 多模态 vs 纯文本 |

**结论：我们规划的端侧 35B-A3B 路线，面壁已经用几乎相同的架构在手机上跑通了，并开源了方法论与引擎。** 这既是最好的可行性证据（架构在端侧确实能跑），也是最强的参照系（他们的每一步都有可对标的数字）。

### 6.2 可直接迁移的机制（对照我们的 P0–P4）

| MiniCPM 的机制 | 我们现有方案 | 建议动作 |
|---|---|---|
| **LES 跨层路由预测预取**（复用下一层 router，零训练，命中 >80%） | 超集异步预读（读 top-32 用 top-8） | **升级**：把"扩大候选集"换成"下一层 router 真实预测"，命中率可量化、候选集更小 ⇒ UFS 读量更省。**归入 P2 调度四件套** |
| **计算顺序优化**（已加载的先算，未命中并行加载） | 无（四件套里没有） | **新增为第 5 件**：与预取配套，是"藏住 UFS 读"的直接手段 |
| 权重**连续布局重排** | UFS mmap 顺序读（隐含） | **显式列为独立优化项**：减少零散读 = 直接省 UFS 带宽 |
| `mix_q3gud_im` 式**逐层混精 GGUF** | T42 2.25bpw + dense Q8_0 + BF16 embd | 思路同构；**P1 可先用 Q4_K_M 走通，再对齐混精** |
| **DSpark 投机** | 前提 A：端侧不做投机 | **必须复核**（见 6.3） |
| 4×/16× 视觉压缩 | 不适用（我们纯文本） | — |
| 自回放微调 | 无 | 若后期做定制化，可低成本借鉴 |

### 6.3 冲突点：端侧投机到底是不是负收益？

- **他们的数据**：DSpark 在 iPad M4 上 **14.92 → 17.39（+16.5%）**；M5 Mac **+17%**。**信号明确为正。**
- **我们的方案**：前提 A 写着"端侧不做投机（负收益）"，且 P0–P4 全程无投机规划。
- **我们的旁证**：DGX 上 dspark 草稿在 **coupled** 下 +28.9%，而在 **uncoupled** 下净收益≈0（接受率从 2.44 塌到 2.23，把草稿税节省吃光）。

**判断**：我们的负收益结论**很可能来自 uncoupled 设定**（或草稿模型与目标模型不匹配）。MiniCPM 的 DSpark **是配套训练的专用草稿 + MTP 头**（`mtp_num_hidden_layers: 1`），与"拿现成草稿硬套"完全不是一回事。

**动作**：P0/P1 增设一个复核项 —— 用与目标模型配套的草稿（而非通用草稿）重测端侧接受率；在此之前，**"端侧不做投机"从"前提"降级为"待验证假设"**。

### 6.4 平台差异警告（不可直接外推）

MiniCPM 的 13+/15+ t/s 全部来自 **Apple 平台**：

| 维度 | MiniCPM 实测平台 | TongYi-Lite 目标 |
|---|---|---|
| SoC | A19 Pro / M4 / M5 | 骁龙 8 Gen5 至尊 |
| 内存 | Apple 统一内存 | LPDDR5X（16G） |
| 存储 | NVMe（Apple 私有控制器） | UFS 4.x（顺序读 ~4 GB/s 级） |
| GPU 后端 | Metal | **OpenCL（Adreno）** |
| 已知坑 | — | **`mul_mat_id` 全量化数值损坏（驱动级 bug）**，我们靠 dense loop 绕行 |

⇒ **他们的数字不能用来看我们的天花板**，尤其在三个点上：① UFS 读带宽比 Apple 存储低；② Adreno 的 MoE kernel 有驱动 bug（Apple 没有）；③ 他们的 3GB 工作集里含被 Metal 高效利用的统一内存，我们不能照搬。

**但反过来说**：他们证明了「**权重放闪存 + 预测式预取 + 卸载（offload）**」这条路在 35B-A3B 上成立 —— 这正是我们 P2「attention 时间藏住 UFS 冷专家读」的门控假设的**外部实证**。

### 6.5 对 P1 代理选择的影响

我们已定案 P1 代理 = **Ling3.0-tiny**（7.9B/1.3B 激活 MoE，128 专家 top8+1shared，3:1 KDA+MLA）。

MiniCPM-V 4.7 出现后，**多了一个候选**：

| 候选 | 优势 | 劣势 |
|---|---|---|
| Ling3.0-tiny（现定案） | 体积小易调试；KDA 可验 delta-rule 算子族 | 与目标模型架构细节仍有差异；需核对 llama.cpp GGUF 支持 |
| **MiniCPM-V 4.7 1B**（1.554B dense） | 同门技术栈；官方有 GGUF/端侧代码；**可直接对标 LES** | 是 dense（无 MoE 路由，**验不了专家调度**） |
| **MiniCPM-V 4.7 35B-A3B** | **与目标模型同构度最高**，LES/混精/DSpark 全套可对照 | 70GB BF16 / Q4_K_M 需 24GB 内存，**手机上无法做代理** |

**建议**：P1 代理对象维持 Ling3.0-tiny（体积与可调试性优先），但**把 llama.cpp-omni 的 LES 实现作为 P2 的直接参考代码**；若 Ling 的端侧 GGUF 支持出问题，**MiniCPM-V 4.7 1B 作为备选**（虽验不了 MoE，但可验「端侧引擎整链路 + GGUF 部署」）。

---

## 7. 存疑与未证实项

| 项 | 状态 |
|---|---|
| iPhone 13+ t/s / 3GB | **厂商自测**，无量化格式、无构建、无 prompt、无测量方法学；**无第三方复现** |
| "比 Qwen3.6 35B-A3B 分更高、更快" | 仅存在于对比图内，**无表格数据** |
| 3GB 的边界条件 | "特定部署方案下的运行内存占用"，未公开该方案的精确定义 |
| LLM 底座的准确来源 | `model_type` 标 `qwen3_5_moe_text`，**推断**与 Qwen3.5/3.6 系同架构；未获官方明示 |
| 中文 benchmark 细节 | CMMLU 90.21 / τ²-Bench 84.65 为官方口径 |
| Android GPU（Adreno/Mali）路径 | 官方列"支持 Android"与 Arm 芯片适配，**未见 Adreno OpenCL 的具体成绩** |

---

## 8. 行动建议（收敛为 3 条）

1. **P0 增补两项**：① 复核端侧投机（用配套草稿，而非通用草稿）；② 核对本机 llama.cpp 对 `minicpmv4_7` / `qwen3_5_moe_text` 架构的支持情况（GGUF 已发布，可直接拉 `mix_q3gud_im` 试载）。
2. **P2 采用 LES 而非朴素超集**：把「读 top-32 用 top-8」升级为「复用下一层 router 预测 top-8」，参考 `OpenBMB/llama.cpp-omni`；同时新增"已加载优先计算"的顺序调度。
3. **维持 P1 = Ling3.0-tiny，但把 MiniCPM-V 4.7 1B 列为备选**；35B-A3B 本体因内存门槛（Q4_K_M ≥24GB）**只能作为方法论参照，不做端侧代理**。

---

## 附：关键链接

- 权重（HF）：`openbmb/MiniCPM-V-4.7-35B-A3B` ／ GGUF：`openbmb/MiniCPM-V-4.7-35B-A3B-gguf`
- 魔搭：`OpenBMB/MiniCPM-V-4.7-35B-A3B-gguf`
- 端侧引擎：`github.com/OpenBMB/llama.cpp-omni`
- 部署指南：`OpenSQZ/MiniCPM-V-CookBook`
- 原始报道：量子位 2026-10-13《iPhone断网跑35B多模态！国产开源新模型，只占3G内存》
