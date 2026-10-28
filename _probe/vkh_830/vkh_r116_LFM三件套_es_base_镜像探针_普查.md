# R-116 · 目标② LFM2.5-24B 现场三件套（es_base 解锁规格 / image 能力探针 / supports_op 全谱普查）
作者：vkh（子代理）｜ 基线：主仓 `56c76220`（含父 TYL-UNLOCK-R3）｜ 全部离线，**未碰 740、未开一腿**
纪律：diff 送父批、构建父代跑；乱文案（`rs_*_copy`/`moe_sort`）**只记录不定罪**；conv/recurrent-state 类坠 CPU 或可疑异步读回同样**只记录**。

---

## 0. 解剖定案（离线 GGUF，`_probe/vkh_830/vkh_gguf_tensors.py` + `/tmp/lfm_census.py`）
`general.architecture=lfm2moe`，`LFM2.5-24B-A2B-QAD-Q4_0`，13 578 190 880 B，n_tensors=428。

| 元数据 | 值 | 对我方的意思 |
|---|---|---|
| `block_count` | **40**（不是 25） | 父口径"25 层"需对账（疑为某腿的 offload 层数，非模型层数） |
| `expert_count` / **`expert_used_count`** | 64 / **4** | **top-k=4** ⇒ `n_cols = n_used×n_tok`，nb16 时 = 64 ≪ 门 `2^20` ⇒ **cols_range 对 LFM 永远不构成威胁** |
| `expert_feed_forward_length` / `feed_forward_length` | 1536 / 11776 | 专家维度 |
| `leading_dense_block_count` | 2 | blk.0/1 = 稠密 FFN（`ffn_gate/up/down` [2048,11776]） |
| `attention.head_count` / `head_count_kv[]` | 32 / 每四一块为 8 | **只有 10 个注意力块**（2,6,10,14,…,38），GQA 4:1，head_dim=64 ⇒ FA 维度 `{64,64}` **在准入白名单内** ✓ |
| `shortconv.l_cache` | 3 ⇒ `d_conv = 2` | 28 个纯卷积块（另 10 attn 块无 shortconv；blk.0/1 稠密但也带 shortconv ⇒ **30 块含 shortconv**） |
| `expert_gating_func` | 2 | — |

**张量类型普查**：`q4_0=220  f32=207  q6_k=1`（token_embd 是 q6_k [2048,128000]）。
**每块算子集三种签名**：
- `x28` = {attn_norm, ffn_norm, exp_probs_b, ffn_gate_inp, ffn_{gate,up,down}_exps, shortconv.{conv,in_proj,out_proj}} —— 纯 conv + MoE
- `x10` = 上者去掉 shortconv、加上 {attn_q,k,v,output,q_norm,k_norm} —— 注意力 + MoE
- `x2` = blk.0/1：稠密 FFN + shortconv（无 MoE）
**MoE 专家张量**：`ffn_{gate,up}_exps` = q4_0 [2048,1536,**64**]、`ffn_down_exps` = q4_0 [1536,2048,**64**]（38 块 ×3 = 114 枚）。

---

## 1. supports_op 全谱普查（离线半：op 级准入矩阵，零腿）
承认 op 全谱取自 `ggml_opencl_supports_op_inner`（:10801 起）：`ADD ADD_ID ARGSORT CLAMP CONCAT CONT CONV_2D CPY CUMSUM DIAG DIAG_MASK_INF DIV DUP FILL FLASH_ATTN_EXT G1_KDA_IN G1_KDA_OUT G1_SSM_LAYER GATED_DELTA_NET GET_ROWS GLU GROUP_NORM IM2COL L2_NORM MEAN MOE_TOPK_FUSED MUL MUL_MAT MUL_MAT_ID NONE NORM PAD PERMUTE REPEAT RESHAPE RMS_NORM ROPE SCALE SET SET_ROWS SOFT_MAX SOLVE_TRI SQR SQRT SSM_CONV SSM_SCAN SUB SUM_ROWS TIMESTEP_EMBEDDING TOP_K TRANSPOSE TRI UNARY UPSCALE VIEW`。
LFM 前向（`src/models/lfm2.cpp` / `lfm2moe.cpp`）实际发的 op 对照：

| LFM 用到的 op | 后端态度 | 判据位置 / 备注 |
|---|---|---|
| **SSM_CONV**（shortconv 的 conv，`ggml_ssm_conv`） | **GPU，条件准入** | :11040-11050：`src0/src1/dst 全 f32` ⇒ LFM conv 权重是 f32 [3,2048] ✓、conv state f32 ✓ ⇒ **上 GPU**。⚠️ A8X 才有 `GGML_OPENCL_SSM_A8X=0` 逃生门；Mesa(740) 不受该 env 影响。源码自带血证：*"routing it to CPU splits the graph 4x more (138 vs 30 segments), decode drops ~2x"* |
| **SSM_SCAN** | 条件准入 | :11051+：f32×7 + `src6=i32` + `1≤d_state≤256 且为 2 的幂`。LFM 是否发此 op 待 d2 op 级确认（`lfm2.cpp` 只见 `ggml_ssm_conv`） |
| MUL_MAT（in_proj/out_proj/q/k/v/o/稠密 ffn） | GPU | 稠密支；`type_has_gemm`={q4_0,q4_1,iq4_nl,q8_0,q4_K,q5_K,q6_K}；LFM 稠密面**全是 q4_0** ⇒ `uses_gemm=true` |
| MUL_MAT_ID（3 枚 ×38 块） | 表决 | `tongyi::resolve_admission`；LFM 门集全过：`K%32=0`（2048/1536 ✓）、`M%128=0`（1536 ✓ / 2048 ✓）、名字 `ffn…exps` ✓、`n_cols=4×nb` ✓ ⇒ **静态门全绿，剩平面/装载面**（父 R-113 配对闸领地） |
| RMS_NORM / ADD / MUL / GLU / GET_ROWS / ROPE / CONCAT / CONT / VIEW / SCALE / SOFT_MAX / SUM_ROWS / MUL_ID / ADD_ID / CPY | GPU | 承认表内 |
| FLASH_ATTN_EXT（10 attn 块） | 条件准入 | 维度 `{64,64}` 在 `supported_dims[]` ✓；类型组合 `is_f32_f16` 需父 R2 `fa_a7x_kv_guard`（`GGML_OPENCL_FA_A7X_GUARD=0`）在场 |
| **CONV_1D / CONV_1D_DW** | **不承认**（全文件 0 命中） | **假警报，已排雷**：LFM shortconv 走 `ggml_ssm_conv`，不走 CONV_1D。`CONV_1D` 只有 wavtokenizer 用 |

**结论（离线半）**：LFM 的 30 个 shortconv 块**不是 CPU 岛**；装载期稠密面**一枚都不坠 CPU**（预测：GPU q4_0×106 + q6_k×1、GENERAL f32×68、n/a f32×139、MMID 另案 q4_0×114）⇒ **父 R3 的大-N 豁免对 LFM 稠密面基本用不上**（ling 教训不复用在此）。
**剩下必须腿侧补的半**（740 归父，先 d2 op 级再开火）：`GGML_SCHED_DEBUG=2` 的 op 级节点表 + `[host-timing] nodes= kernels= splits=`，重点看三类：① conv/recurrent-state 相关 op（`get_r_l` 的 state 读写、`ggml_backend_tensor_set` ×2、`ggml_fp32_to_fp16` ×2 —— **只记录，归父定罪**）；② `kernel_moe_sort_scatter` 的 GPU/CPU 归属；③ 每层 `SET_ROWS`/`FILL`（G-782 判例：搬 CPU 会 abort）。

---

## 2. es_base / G-740 `forbid_view` 判据读透（**目标② 关键路径**）
### 2.1 判据在树里的确切位置（六处，逐条给因）
| # | 位置 | 内容 / 为什么拒 |
|---|---|---|
| ① | `ggml-opencl.cpp:26540-26545` | **硬拒口**：`else if (src0->view_src != nullptr) → mmid_gate_fail(6,"view_slot","q4_0/q4_K lack es_base view handling (grid G-740)")`。原文理由：*"reading the parent planes from slot 0 would **silently produce wrong results**"* ⇒ 这是**防静默错值**的正当拒绝，不是懒门 |
| ② | `ggml-opencl.cpp:26533-26539` | **q3_K 的正确姿势（唯一母本）**：`slot_bpe = ggml_nbytes(src0)/ne[2]`；`view_offs % slot_bpe != 0` ⇒ `gate_fail(6,"view_slot_q3k")`；否则 `es_base = view_offs/slot_bpe` |
| ③ | `ggml-opencl.cpp:26820-26824` | **`es_base` 只作为 q3_K 内核参数存在**（`if (is_q3_k) clSetKernelArg(kernel, k_arg++, sizeof(cl_ulong), &es_base_u)`）⇒ q4_0/q4_K 的 batched 内核签名里**根本没有这个参数** ⇒ 光抄算术解不开 |
| ④ | `kernels/gemv_noshuffle_q3_k_f32.cl:168,196` | 内核语义钉死：`const ulong esb = (ulong)es + es_base;`（ids 在 view 内选择，基槽 = es + es_base） |
| ⑤ | `tongyi_route_table.cpp:173-181` | 表侧同源拒口：`if (q.is_view) { if (t==RTYPE_Q3_K) {…view_slot_q3k…} else { *why = "view_slot (q4_0/q4_K lack es_base, G-740)"; return false; } }` |
| ⑥ | `tongyi_route_table.h:76` + 行 :25/:35/… | 行字段 `forbid_view`（注释"无 es_base 处理（网格 G-740）"）：q4_0/q4_1/q4_K batched 行 = `true`，q3_K 行 = `view_slot_align=true` |
| ⑦（**反向好消息**） | `ggml-opencl.cpp:26593,26596` | **view 输出侧早已支持**：`cl_ulong dst_base = extrad->offset + dst->view_offs;`（+%4 对齐门）。⇒ 父提的 "result_norm view 输出案" **不需新件**；被 G-740 拒的只有**权重（输入侧）view 绑定** |

### 2.2 地基已在树里（不用我造）
`src/models/lfm2moe.cpp` 已有 **split-MoE 分组机器**：*"split-moe grouping: one base per family, layers become **windows** on it"*（`moe_slot` / `moe_groups` / `moe_experts_entry(base)->bytes_per_expert` / `ggml_backend_opencl_svm_buft`）。它产出的正是**基座张量上的窗口 view** ⇒ 与 G-740 正面相撞。**目标② 的卡点 = 本条，不是内核缺失。**

### 2.3 两条实现路线（**A 强烈推荐**）
- **A. 子缓冲 origin 平移（零内核改动、零新参数）**
  在 :26517-26522 绑定 `wq/wd/we` 处，当 `src0->view_src` 且算得 `es_base>0` 时，改用 `ggml_cl_subbuffer_from_parent(pextra->q, es_base*q_layer, E*q_layer)`（`wd`/`we` 同理，各自 layer 尺寸），并把 `q_img` 的 `img_desc.buffer` 指向该子缓冲。
  **等价性证明**：q3_K 内核语义是 `esb = es + es_base` 再乘 layer 尺寸 ⇒ 绝对字节 = `(es+es_base)*layer`；A 路 `es` 从 origin=`es_base*layer` 起算 ⇒ 同一绝对字节。✓
  **三条前置**（全部可机检）：
  (a) 平面必须覆盖整基座：已由 :26636-26637 `E_base = soa0->ne[2]` + `image_width = E_base*q_layer/4` 保证 ✓；
  (b) `view_offs % slot_bpe == 0` **且** `q_layer/d_layer/se_layer % backend_ctx->alignment(1024) == 0`（否则子缓冲 origin 不合法）——LFM：`q_layer = M*(K/4)*2 = 1 572 864 B`、`d_layer = M*(K/32)*2 = 196 608 B` ⇒ 均 %1024=0 ✓；
  (c) **图像缓存键必须纳入 `es_base`**：现 `q_img` 缓存在 extra 上、注释明说"view-independent"（:26629-26641）。A 路下同一基座的不同窗口需要**不同 origin 的 image** ⇒ 键要加 `es_base`（先例就在旁边：`b_img` 的 `(buffer,origin,size)` 缓存 :26643-26646，`GGML_OPENCL_MOE_BCACHE` 可关做二分）。
  为何首选 A：`ggml-opencl.cpp:26797-26798` 有血案记录 —— *"q4_0/q4_K kernels reverted to the pre-P3 signature (**perm param triggered an E031.47 miscompile on 830**)"* ⇒ 给这两个内核**加参数**在 830 面上有前科。
- **B. 抄 q3_K 加参数**：改 `kernels/gemv/gemm_noshuffle_q4_{0,k}_f32.cl` ×2（加 `ulong es_base` + `esb = es + es_base`）+ 参数表 :26815-26824 + `k_arg` 计数 + 830 重编。语义最干净，但**再入 E031.47 雷区**，且触及父 R-113 配对闸的镜像面。
- **我的建议**：Mesa(740) 走 A 先出数；B 仅在 A 的 image 缓存命中率在 `[host-timing]` 里现形（每步重建 image）时作为退路。

### 2.4 表侧与测试同步（父落码时必跑）
- 表行：q4_0 / q4_K batched 行 `forbid_view: true → view_slot_align: true`；:173-181 的 else 分支改为与 q3_K 同门（拒因串统一 `"view_slot"`，保留 `view_slot_q3k` 便于历史日志对账）。
- `tongyi_route_table_test.cpp` 内有 **G-740 漂移 pin**（AGENTS.md:3326 记的三族单测，dgx 原生 aarch64 `31546 pass/0 fail`）⇒ 改行必重跑三族，否则 pin 会（正确地）红。
- env：`GGML_OPENCL_MOE_VIEW_SLOT=1`（未设/0 ⇒ 逐字节零扰动），Mesa-only（同 R-084/R3 家族姿势）。

### 2.5 验收（防的正是 ① 警告的静默错值）
1. **阳性对照（本环唯一能抓"读 slot 0"的枪）**：同一基座取**两个不同 `view_offs` 的窗口**、喂**同一组 ids** ⇒ 若 `es_base` 失效，两臂输出必然**逐字节相同**（= 抓到）；正确时两者应不同且各自等于"直接从对应专家段算"的 CPU 金标。
2. CPU 金标逐 token 对拍（K40 ngl=0，B2 那套，seed42/temp0，`GOLD_SHA_OK=1`）；**乱文未清前提速结论不单独入账**。
3. 日志机检：`route[…] -> BATCHED_MOE` 命中、`MUL_MAT_ID batched GATE-FAIL[6] refused` 计数 = 0（记住 `MMID_FAIL_LOG_MAX 8` 是日志上限不是真值）。
4. 图结构闸：`[host-timing] nodes= kernels=` + `## SPLIT #N` 计数（SSM 注释的 "138 vs 30 段" 同款指标）；view 解锁后 split 数**不得**恶化。
5. R-083 尺子铁律：`LLAMA_MOE_SLOT_BANK=32` + `E2E_NB=16`（LFM top-k=4 ⇒ `n_cols=64`，远低于 `2^20` 门）。

---

## 3. image 能力探针规格（父已批准并入同拍）
**现状（为什么要装）**：真腿日志 `clCreateImage` 共 **65 462** 次且 rc=0 走完，但现有 RSWRAP 只打 `errp=<地址>` **不打状态值** ⇒ "在调用" ≠ "全成功"；一旦 image 创建静默失败，batched 路会拿着 `nullptr` image 继续跑 = 最坏形态的静默错值。
**探针设计（一次性，零热路径成本）**：
1. init 期打一次设备能力：`CL_DEVICE_IMAGE_SUPPORT`、`CL_DEVICE_IMAGE_MAX_BUFFER_SIZE`、`CL_DEVICE_IMAGE_MAX_ARRAY_SIZE`、`CL_DEVICE_MAX_MEM_ALLOC_SIZE`。
2. **首个 `q_img` 打真实 err**（`clCreateImage` 返回值 + `image_width` + `buffer` 尺寸 + 张量名），只打第一次（static flag），err 非 0 时**立即 `GGML_LOG_ERROR` 并进装载证明**。
3. **宽度账本（我普查顺手算出的新雷，必须机检）**：`image_width = E*q_layer/4`
   - LFM gate/up_exps：`q_layer = 1536*(2048/4)*2 = 1 572 864 B` ⇒ **width = 64×1 572 864/4 = 25 165 824 px**
   - LFM down_exps：`q_layer = 2048*(1536/4)*2 = 1 572 864 B` ⇒ 同 **25 165 824 px**
   - 对照 ling（已跑通 batched）：`q_layer=393 216 B`、E=128 ⇒ **12 582 912 px**
   ⇒ **LFM 需要 2× ling 的 image 宽度**。740 实测能容 12.58M px 不等于能容 25.17M px（`IMAGE_MAX_BUFFER_SIZE` 是硬闸，rusticl 各家取值不一）⇒ **这是 LFM 开火前的硬前置，不是 nice-to-have**。
4. 输出形态（进装载证明，供我离线核）：一行 `#### IMAGECAP support=1 max_buffer=… first_q_img name=… width=… bytes=… err=0`。

---

## 4. 我下一步（不动 740；K40 归我）
- 等父落 A 路（或 B）后，K40 侧跑 **ngl=0 CPU 金标 + 阳性对照**（correctness only，不出性能结论）；K40 是 A6x，vendor MoE 内核默认关，batched 命中情况我会一并记录。
- 4B 中转（K40 2.8GB）按双 md5 令继续：push 枪 md5 `0c265b8a`、pull 枪 `0d2e17c6`，两端真 `sha256sum` 对拍（哑火 #23 教训已内建）。
- **不定罪清单**（交父）：`ggml_backend_tensor_set`×2、`ggml_fp32_to_fp16`×2、`mctx_cur->get_r_l(il)` conv state 读写、`kernel_moe_sort_scatter` 归属 —— 均只记录。
