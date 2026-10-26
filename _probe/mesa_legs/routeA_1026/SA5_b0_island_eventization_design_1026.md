# SA-5 · B0「CPU 岛」事件化改造设计（前线②，2026-10-26）

> 只读分析出品（SA-5）。**未改任何代码、未跑任何设备/adb 命令、未 commit。**
> 台账锚点：`docs/全GPU卸载_执行记录_2026-10-25.md` R-012/R-027/R-033~R-036；网格 B0/B3（`docs/全GPU卸载_全景地图与网格计划_2026-10-25.md:379-384`）。
> 前作差分：`_probe/mesa_legs/routeA_1026/b0_slot_island_analysis_1026.md` 已做完「传输点账目表 T1–T5 + fd_bo 面盘点」，本文**不重复**，只做它的三件缺项：
> ① 把「NULL 异步钩子」从猜测钉成**七处挂点 + 三级传导链**；② 把「谁落 CPU 岛」做成**可机检的 op 集合**；③ 给出**可施工的事件化分层设计 + env 门控 + 与 OPFLUSH=1 治愈机制的交互约束**。
> 简称：**OCL** = `third_party/llama.cpp/ggml/src/ggml-opencl/ggml-opencl.cpp`；**BASE** = `third_party/llama.cpp/ggml/src/ggml-backend.cpp`；**SLOT** = `third_party/llama.cpp/src/llama-moe-slot.cpp`；**CTX** = `third_party/llama.cpp/src/llama-context.cpp`；行号 = 当前工作树实测。

---

## 0. 结论先行

1. **根因坐实**：`OCL:11159-11176` 的 backend 接口表里 **async 钩子全 NULL**（`set_tensor_async/get_tensor_async/set_tensor_2d_async/get_tensor_2d_async/cpy_tensor_async` = `OCL:11162-11166`，`event_record/event_wait` = `OCL:11173-11174`）。这不是孤立的一处，而是**七处 NULL 组成的一个「无异步能力声明」簇**（见 §1.1）。
2. **三级传导链**（§1.2）：`caps.async/events=false`（`OCL:16045-16051`）→ CTX 关掉 pipeline_parallel（`CTX:530-547`）→ sched `n_copies=1` 且 `event_new=NULL` 使 `sched->events[][]` 恒 NULL（`BASE:674-680`、`BASE:2153-2158`）→ **每一次跨后端拷贝/每一个 split 边界都退化成 `ggml_backend_synchronize` = 全队列 barrier+wait**（`OCL:8608-8615`）。
3. **每个 CPU 岛的固定税 ≈ 3 次全队列 drain + 1 次阻塞读 + 1 次阻塞写**（`BASE:1869` / `BASE:1880+1884` / `BASE:1928`；`OCL:13983-13985` CL_TRUE 写、`OCL:14070/14084-14088` CL_TRUE 读）。40 层 × MAP_CUSTOM1 ⇒ **~120 drain + 80 阻塞传输/token**，与台账 `wait367/read_blk181/write_blk157` 同量级（**逐项直方图仍未入库，见 §4-P1**）。
4. **重大雷点（先记死）**：`OCL:8585-8606` 三个 async 函数**是空 stub（`GGML_UNUSED` 全丢参数）**。**谁把它们直接挂上 11162-11166，set_tensor_async 就变成静默丢数据**——不崩、不报错、输出全乱。必须**先写实现再挂表**。
5. **岛的本体**：`MAP_CUSTOM1/2/3`（以及 50 个算子）在 `ggml_opencl_supports_op_inner` 的 switch 里**根本没有 case**，落 `OCL:11146-11148` `default: return false` ⇒ **恒 CPU**。生产图每 token 40 个岛 = 40 次 `ggml_map_custom1`（`SLOT:2857-2869`，图锚 `llama-graph.cpp:2493-2496` argsort_top_k → `:2550`）。
6. **岛不可"删"，只能"摊平"**：MAP_CUSTOM1 的语义是**宿主侧换页决策**（查 slot bank、发 flash 预读），所以专家 id 必须回读宿主、slot id 必须交给 GPU。事件化目标 = **把 3 次全队列 drain + 2 次阻塞传输压成「0 次 drain + 1 次末位 wait」，最终压成 0 传输**。
7. **最优解不是事件化，是 L3「消传输」**：岛边界张量只要落在**宿主可见的 OpenCL buft**（`OCL:15497-15509` svm buft，`is_host=true` @`OCL:15652-15657`），sched 在 `BASE:1524` 的 `!ggml_backend_sched_buffer_supported(...)` 判定为假 ⇒ **连 input_cpy 都不建，一次 CL API 都不发**；CPU 侧 `SLOT:2003-2010 host_data()` 同时翻成 memcpy 快路（顺带灭掉 `SLOT:2026/2048` 的**逐 token 循环** get/set，prefill 512 token 时这是 512×40 次阻塞传输的隐雷）。**缺口 = svm buft `.init_tensor = NULL`（`OCL:15578`）不给 per-tensor `extra`（cl_mem+offset），内核无从寻址**——这是 L3 唯一要实现的东西（~100 行）。
8. **与 OPFLUSH=1 的关系是硬约束不是可选项**：R-036 判定「async 全乱 / OPFLUSH≤2 对 / N≥3 乱」，区分量是 **CPU 领先 GPU 的量**。任何事件化都必须**保留 OPFLUSH≥1**，并新增 **in-flight 上限**（`GGML_OPENCL_MAX_INFLIGHT`，默认 8）把「CPU 领先量」显式夹住——否则本设计自己就是 R11/cb0 slab 环绕复用的放大器。
9. **落地次序建议**：**L0 计数（0.5d）→ L3 岛边界宿主可见 buft（1d，收益最大）→ L1 set/get 事件化（1d，兜底）→ L2 真 sched 事件（1.5d，收益大但风险最高）**。L4（MAP_CUSTOM1 上 GPU）**挂账不推荐**。
10. **全部改动 env 门控、默认关、单变量可回退**，命名沿用战役 `GGML_OPENCL_*` 规范（§3.8）；正确性判据沿用背书库口径（tok 逐字节 `e9b88e56` + health_hits + KGSLSUBMIT 指纹）。

---

## 1. 核实：NULL 异步钩子的确切位置、触发条件、调用链

### 1.1 七处挂点（全部实测行号 + 片段）

| # | file:line | 内容 | 直接后果 |
|---|---|---|---|
| N1 | `OCL:11162-11163` | `/* .set_tensor_async = */ NULL, /* .get_tensor_async = */ NULL,` | `BASE:411-413`/`425-427`：**先 `ggml_backend_synchronize` 再阻塞 set/get** |
| N2 | `OCL:11164-11165` | `set_tensor_2d_async/get_tensor_2d_async = NULL` | `BASE:439-443`/`460-464`：退化成逐 copy 的 1D async（= N1 的 drain ×n_copies） |
| N3 | `OCL:11166` | `/* .cpy_tensor_async = */ NULL,` | `BASE:659-669` 与 **`BASE:1879`**：`synchronize(src)+synchronize(dst)+阻塞 copy` |
| N4 | `OCL:11173-11174` | `event_record/event_wait = NULL` | `BASE:1857/1867/1882/1926/1998` 的 event 分支**永不可达**（且 `BASE:691/705` 有 `GGML_ASSERT`，挂了 caps 不挂实现会直接 abort） |
| N5 | `OCL:16045-16051` | `props.caps = {async=false, …, events=false}` | `CTX:538-546` → `pipeline_parallel=false` → `n_copies=1` |
| N6 | `OCL:16154-16156` | device iface `event_new/event_free/event_synchronize = NULL` | `BASE:676-678` `ggml_backend_event_new` 返回 NULL ⇒ 即使 `n_copies=2` 也拿不到事件 |
| N7 | `OCL:8585-8606` | 三个 async 函数体**是空 stub**（`GGML_UNUSED(backend/tensor/data/offset/size);` / `return false;`） | **雷**：指针一挂就是"静默丢数据"（N1 的"正确实现"必须重写函数体） |
| N8 | `OCL:1427` | `clEnqueueNDRangeKernel(queue,…,0,NULL,NULL)`（生产路径，非 PROFILING 分支） | **不产出 producer event** ⇒ 读侧事件链没有上游可挂 |

旁证（同一族"没接线"证据）：`OCL:8601-8606` `cpy_tensor_async` 存在但 `return false`；`OCL:15578` svm buft `.init_tensor = NULL`；`OCL:16149` `get_host_buffer_type = NULL`。

### 1.2 调用链（一个岛从图到 ioctl）

```
llama-graph.cpp:2493  selected_experts = ggml_argsort_top_k(...)      ← GPU 产出 i32
llama-graph.cpp:2550  moe_slots->build_slot_ids_tensor(...)           → SLOT:2869 ggml_map_custom1
   └─ BASE:1214 ggml_backend_sched_split_graph
        ├─ BASE:1206-1211 set_if_supported → OCL:10534 supports_op_inner → OCL:11146 default:false
        │     ⇒ MAP_CUSTOM1 只能落 CPU（pass2 也不许 GPU 扩张越过 CPU，BASE:1287-1289）
        └─ BASE:1524  跨后端 src 且 buft 不被目标后端支持 ⇒ 建 input_cpy（BASE:1536-1547）
   └─ BASE:1911 ggml_backend_sched_compute_splits
        ├─ BASE:1924-1930  上一 split 边界：events==NULL ⇒ ggml_backend_synchronize(prev)   ← drain #1
        ├─ BASE:1935  copy_input(expert_ids, GPU→CPU)
        │     ├─ BASE:1869  events==NULL ⇒ synchronize(split_backend)                       ← drain #2
        │     ├─ BASE:1879  cpy_tensor_async==NULL ⇒ synchronize(input_backend)
        │     │              + BASE:1884 synchronize(split_backend)                          ← drain #3
        │     └─ BASE:638 → OCL:14070/14084-14088  clEnqueueReadBuffer(CL_TRUE)              ← 阻塞读
        ├─ BASE:1945  CPU split 计算 → SLOT:2728 map_custom → SLOT:2243 process
        │     └─ SLOT:2013-2030 read_i32_ids / SLOT:2032-2052 write_i32_ids
        │           host_data()==null（张量在 GPU buft）⇒ **逐 token** get/set（:2026/:2048）
        └─ 下一 GPU split 的 copy_input(slot_ids, CPU→GPU)
              └─ BASE:636 → OCL:13983-13985 clEnqueueWriteBuffer(CL_TRUE)                    ← 阻塞写
```

岛内 CPU 侧还有第二条税：`SLOT:2229-2232 LLAMA_MOE_DRAIN_ASYNC` + `OCL:15955-15971 moe_q3k_stage_pack_impl(blocking)` / `OCL:15969-16000 stage_wait`——但它受 `ggml_cl_svm_upload_mode()` 默认 0（前作 R-033 已判「死代码 A/B」），本文不当活税计。

### 1.3 岛边界同步预算（40 层/token）

| 项 | 出处 | /岛 | /token |
|---|---|---|---|
| 全队列 barrier+wait | `BASE:1869`、`1880`、`1884`、`1928`（每次 = `OCL:8611-8614` barrier+wait+release） | 3~4 | **120~160** |
| 阻塞读（i32 ids） | `OCL:14070`/`14084-14088` via `BASE:638` | 1（prefill 经 `SLOT:2026` 可 ×n_tokens） | 40 |
| 阻塞写（slot ids） | `OCL:13983-13985` via `BASE:636` | 1 | 40 |
| 岛内 CPU 计算 | `SLOT:2741 process`（自带 ns 计数） | 1 | 40 |
| **不含** | `sync_with_other_backends`（`OCL:9816` 每节点调，但 `OCL:8621-8623` 单设备直接 return）——830 单机 = 0 成本，**别再怀疑它** | — | 0 |

---

## 2. 落到 CPU 岛的 op 集合

### 2.1 结构性恒 CPU（switch 无 case ⇒ `OCL:11146-11148` default:false）
穷举比对 `ggml.h` 的 105 个 `GGML_OP_*` 与 `OCL:10534-11148` 的 55 个 case，**无 case 的 50 项**中与本战役相关者：

- **岛生成器**：`MAP_CUSTOM1`、`MAP_CUSTOM2`、`MAP_CUSTOM3`、`CUSTOM` ← 本 B0 岛的**唯一本体**（40/token）。
- 其它（本模型基本不触发，列出以免误判）：`ADD1 ACC LOG SIN COS SUM ARGMAX COUNT_EQUAL REPEAT_BACK SILU_BACK RMS_NORM_BACK OUT_PROD GET_ROWS_BACK DIAG_MASK_ZERO SOFT_MAX_BACK ROPE_BACK CONV_* IM2COL_*/COL2IM_* POOL_* PAD_REFLECT_1D ROLL ARANGE LEAKY_RELU FLASH_ATTN_BACK WIN_* GET_REL_POS ADD_REL_POS RWKV_WKV6/7 GATED_LINEAR_ATTN LIGHTNING_INDEXER DSV4_HC_* CROSS_ENTROPY_LOSS(_BACK) OPT_STEP_*`。
- 注：`OCL:10543-10590` 的 G-782 小算子路由（`tongyi::small_op_to_cpu`，`tongyi_route_table.cpp:406-418`）**自证在本挂点「3176 节点 0 次轮询」**⇒ 它当前不是有效路径，别把它算进岛账。

### 2.2 条件性 CPU 回落（类型/门控黑名单，逐条 file:line）

| 触发条件 | file:line | 备注 |
|---|---|---|
| `CPY/DUP/CONT`：`src0 ∉ {F32,F16,I32}` 或 `dst ∉ {F16,F32}`（`F32→I32` 仅 CPY 且有 `kernel_cpy_f32_i32`） | `OCL:10632-10668` | R-027 定案的 **Q8/Q4 KV CONT 落 CPU 岛**就在这里 |
| `GET_ROWS`：`src0` 量化（Q4_0 且 `GGML_OPENCL_SOA_Q`） | `OCL:10599-10613` | 嵌入查表 |
| `SET_ROWS`：`src0 != F32`，或 `type ∉ {F16,F32,Q8_0,Q4_0}` | `OCL:10614-10631` | |
| `MUL_MAT_ID`：路由表 `resolve_admission` 不准入（q3_K 非 batched 形状、`src1!=F32`、`src2∉{I32}`、非连续、slot 未对齐） | `OCL:10908-10933`（表实现 `tongyi_route_table.cpp`） | q3_K batched-only；落 CPU 就是**大岛** |
| `MUL_MAT`：`src1 != F32` 等 gate 外 | `OCL:10832-10907` | A7X dense K-quant 曾判「CPU 更快」 |
| `FLASH_ATTN_EXT`：A7X 混合/量化 KV、`dk==512` 非 f32_f16、Intel | `OCL:11094-11143` | **740 专属**；Mesa/rusticl 侧 `adreno_gen` 判定不同需复核（§5-Q4） |
| `GGML_OPENCL_OPFILTER` 正则命中 | `OCL:7510-7513`、`10591-10594` | 现成的人工黑名单 |
| `MUL_MAT_ID` 想上 GPU 需 `GGML_OPENCL_OFFLOAD_MMID=1`（host 权重 offload） | `OCL:16129-16139` | 默认关（sched 复制的 slot 缺 pre-packed se planes ⇒ SIGSEGV） |

### 2.3 机检口径（不许靠读码结论定罪）
现成仪表：`BASE:2004-2052` `GGML_SCHED_STATS=1` 打 `[SCHED_STATS] splits=/ops=/copies=` 与 **`CPU-fallback op histogram`**（限前 5 个图）；归因串 `SET_CAUSE`（`BASE:1061-1064`、`"1.dst" "2.sup" "3.best" "4.cpy" "6.cpy"`）。**L0 腿必须先把这张直方图 + 每 split 的 drain 计数落进台账**，否则 §1.3 的 120/40/40 只是静态重构（前作 §5-1 的同一洞）。

---

## 3. 事件化改造设计（分层，全部 env 门控）

### 3.0 不变量（改任何一条前先背熟）
- **I1 队列是 in-order**（`OCL:7749-7753`，`props=0`；OUT_OF_ORDER 分支在 `OCL:7745-7747` 是注释）。⇒ 事件链买到的是**「非阻塞提交 + 定点等待」**，不是乱序并发。不要指望事件链带来 kernel 重叠。
- **I2 host 缓冲区生命周期**：async 写的 src 必须活到写完成。sched 的 `input_cpy` 池在 `n_copies==1`（当前）时**下一图立刻复用** ⇒ 「无脑 async」= 制造 R11 同族竞态。必须配套：in-flight 环 + `n_copies≥2`（L2）或 ring 深度自持（L1）。
- **I3 `GGML_TENSOR_FLAG_INPUT` 张量不得延迟拷**（`BASE:1854-1863` 注释原话：用户随时可能覆写）⇒ 白名单外一律保持同步。
- **I4 正确性红线**（前作 §3 保留红线）：logits 读回、岛边界**语义上的**最后一次等待不可省——可以挪位置，不可以删。
- **I5 不许把 `OCL:8585-8606` 的空 stub 挂上接口表**（N7 雷）。

### L0 · 计数与归因（前置，不改行为）
- 在 `OCL:8608-8615` synchronize、`BASE:1869/1880/1884/1928` 四个 drain 点、`OCL:13983`/`14070` 两个阻塞传输点加**进程内计数器**（`GGML_OPENCL_ISLAND_STATS=1` 时按 op 名/方向/调用点分桶，图末/每 32 图 fprintf）。
- 目标判据：`drain/op/图` 直方图 + 与 `KGSLSUBMIT`/`read_blk`/`write_blk` 对账闭合 ≥80%（P-3 报告 A1 判据口径）。
- 不实现即不可信：§1.3 预算、前作 T1/T3/T4 分解、`n_copies` 乘数（前作 §5-2）全等这一腿裁。

### L1 · set/get_tensor 事件化（消「阻塞」，保留「顺序」）
**改哪些函数**
- `OCL:13969-14002`（`…_buffer_set_tensor` 通用臂）：`CL_TRUE` ⇒ `CL_FALSE + cl_event`，事件进 backend_ctx 的 **per-buffer in-flight 环**（深度 `GGML_OPENCL_MAX_INFLIGHT`，默认 8；满则先 `clWaitForEvents` 最老一个）。
- `OCL:14004-…`（`…_buffer_get_tensor` 通用臂）：同法，但**必须**带 wait-list = {producer event} ⇒ 依赖 **N8 修复**：`OCL:1379-1437` 生产分支在 `GGML_OPENCL_ASYNC_GET=1` 时把 `clEnqueueNDRangeKernel(..., &ev)` 的 ev 记入 `tensor->extra->event`（`OCL:7935 struct ggml_tensor_extra_cl` 加一成员 + 生命周期规则：新 enqueue 覆盖前先 release 旧 ev；**extra 进 `temp_tensor_extras_in_use` 的那条路不得 unbind 未完成的 ev**）。
- 新写实现并**只在实现完成后**把 `OCL:11162-11163` 从 NULL 换成新函数（`GGML_OPENCL_ASYNC_SET/ASYNC_GET` 运行时门；env 关 ⇒ 走老 CL_TRUE 码路，**两条码路同时留在二进制里**）。
- 收口点（唯一允许 wait 的地方，其余一律不许插）：① `OCL:8608-8615` synchronize（先 `clFlush` 再 drain 环）；② 图末（`OCL:9727` graph_compute 出口）；③ 环满；④ `clReleaseMemObject` 前（防 BO 早复用 = R11 侧翼）。
**事件编排**
```
[W_i = clEnqueueWriteBuffer(CL_FALSE, ev=W)]  ──in-order──▶  K1 K2 … Kn
   宿主仅在 {环满 | 岛末真消费者 | synchronize | 释放该 cl_mem} 处 clWaitForEvents(W_oldest…)
[K_prod(ev=P)] ──wait-list{P}──▶ [R_j = clEnqueueReadBuffer(CL_FALSE, ev=R)] ──▶ 宿主 clWaitForEvents(R)
```
**收益/风险**：n 次驱动往返 ⇒ 每岛 1 次（对齐 `SLOT:2229` v3 drain 的已验证打法）；风险 = in-flight 环里的 host 源被复用（违反 I2）⇒ **L1 单开时必须 `MAX_INFLIGHT=1` 起步逐步抬**，并用 L0 计数 + 背书库 tok 全等做门。

### L2 · 真 sched 事件（消 120+ 次全队列 drain，收益最大风险最高）
**改哪些函数**
- `OCL:16154-16156`：实现 `event_new/event_free/event_synchronize`（`cl_event` 包装 + `clFlush(queue)` on record、`clWaitForEvents` on wait）。
- `OCL:11173-11174`：实现 `event_record/event_wait`（record = `clEnqueueMarkerWithWaitList(queue,0,nullptr,&ev)`；wait = `clWaitForEvents(1,&ev)`）——**与 `OCL:8611-8613` 同型，但语义只覆盖"到该点为止"**。
- `OCL:16045-16051`：`caps.async/events` 在 `GGML_OPENCL_EVENTS=1` 时置 true（默认仍 false ⇒ 零扰动）。
- **必须同时**解决 `n_copies`：`CTX:521-529` 的 pipeline_parallel 前置含 `model.n_devices()>1`，830 单 GPU 恒假 ⇒ 光抬 caps **拿不到事件**（`BASE:2153-2158` 的 `if (sched->n_copies > 1)` 永不进）。故加 fork 局部 env `GGML_OPENCL_SCHED_COPIES=<1|2>`（沿用 `GGML_OPENCL_*` 命名），在 `CTX:717-721 sched_new` 处覆盖 `parallel` 实参。
**事件编排**：`BASE:1997-1999` 每 split 末 record → `BASE:1857/1867/1882/1926` 从"全队列 drain"降为"只等上一 split 的那一个 marker"。
**风险**：`n_copies=2` 使 input_cpy 双份（显存/compute buffer 抬升，需报数）；`BASE:2246-2247` `cur_copy/next_copy` 轮转与 realloc（`BASE:1774-1782`）路径要在 prefill/decode 切换下验；`BASE:691/705` 的 `GGML_ASSERT` 要求 caps 与四个 event 钩子**同进同退**（分两次提交会当场 abort）。

### L3 · 岛边界张量落「宿主可见 OpenCL buft」（消传输，**主推**）
**原理（三行实证）**：`OCL:16098-16111` OpenCL `supports_buft` **同时接受 svm buft**；`OCL:15652-15657` svm buft `is_host=true`；CPU `ggml-cpu.cpp:493-496 supports_buft = ggml_backend_buft_is_host(buft) || extra_buffer_type` ⇒ `BASE:1524` 判定为「已支持」⇒ **不建 input_cpy、不发任何 CL API**；同时 `SLOT:2003-2010 host_data()` 返回非空 ⇒ `SLOT:2026/2048` 的逐 token get/set 循环被 memcpy 取代。
**唯一实现缺口**：`OCL:15578` svm buft `.init_tensor = NULL` ⇒ 张量没有 `extra{data_device,offset}`，GPU 内核无法寻址。
**施工**：给 svm buffer context（`OCL:15497-15509`）加**一个**持久映射 BO 的 `cl_mem`（与 `raw_stage` 同法：`CL_MEM_READ_WRITE|CL_MEM_ALLOC_HOST_PTR` @`OCL:15608-15610` + 一次持久 `clEnqueueMapBuffer` @`OCL:15619-15621`，`ctx->svm = host` @`OCL:15626`），并补 `.init_tensor`（照 `OCL:11629` `…_buffer_init_tensor` 的 extra 生成逻辑，`data_device = bctx->bo`，`offset = 张量在 BO 内的偏移`）；宿主可见性靠 `ctx->svm`，GPU 侧靠同一 `cl_mem` —— 正是 `OCL:15891-15899` 注释自证的「pack 读同一个 cl_mem，从不读宿主指针」模式的泛化。
**接线点**（谁把张量放进这个 buft）：图节点由 gallocr 分配，但 **`ggml-alloc.c:594 t->data != NULL // tensor data already set externally` 让外部预绑定的张量绕开池分配**，公开 API 现成：`ggml-backend.h:454 ggml_backend_tensor_alloc(buffer, tensor, addr)`（KV-cache 已在用同型手法）。⇒ 在 `SLOT:2857-2869 build_slot_ids_tensor` 建完 `map_custom1` 后，对**输出 slot_ids** 与**输入 selected_experts**（`llama-graph.cpp:2493` 的产物）各调一次 `ggml_backend_tensor_alloc` 绑到岛专用 svm buffer；env `GGML_OPENCL_ISLAND_HBUFT=1` + `…_MAX=<bytes>`（只收 ≤阈值的 i32 小张量，**绝不让 KV/bank 混进来**）。
**收益**：§1.3 表中 2 次阻塞传输 + 逐 token 循环 → **0**；drain 仍由 L1/L2 处理。
**前置门（不可跳）**：前作 §3 路线一的 Mesa 真机三证仍然承重——(a) `ALLOC_HOST_PTR` 在 kgsl 落 native BO 还是 dma_heap；(b) `kgsl_bo_cpu_prep`=NOP 下 **CPU 写→GPU 读 coherency**（错专家权重 = 静默错数）；(c) 持久映射 GPU 读带宽。本设计不新增例外：**L3 腿就是这三证的执行载体**。

### L4 · MAP_CUSTOM1 GPU 认领（**挂账不推荐**）
在 `OCL:11146` 前加 `case GGML_OP_MAP_CUSTOM1` 并在 `ggml_cl_compute_forward` 派发一个 remap 内核。**否决理由**：岛的语义是宿主换页决策（`SLOT:2243 process` 查 bank/发预读/记 stats/驱动 `split_dynamic`），上 GPU 等于把 flash I/O 策略塞进内核参数；且 `OCL:9822-9824` 的 `GGML_TENSOR_FLAG_COMPUTE` 与 custom1 的 `ith/nth` 语义（`SLOT:2735-2737` 只允许 ith==0）在图融合区易踩坑。**保留为「岛税归零后的下一步」，需要独立的专家常驻设计（B5 LES）一起做。**

### 3.7 与 OPFLUSH=1 治愈机制的交互（硬约束）
1. **OPFLUSH 语义**（`OCL:9765-9771`）：每 n 个节点 `clFlush`，**不等**。R-036：`N≤2` 对、`N≥3` 乱；区分量 = **CPU 领先量**（E4PREP 判读）。⇒ **L1/L2 打开时 OPFLUSH 必须 ≥1，且 `MAX_INFLIGHT` 提供第二道夹逼**。
2. **in-flight 上限就是"CPU 领先量上限"的 ggml 侧代理**：cb0/BO 环绕复用假说（E4CB0：async `min_gap 8699 ≈ 环绕一周恰逢 GPU 落后 1 token`）说明危险发生在"CPU 领先 ≈1 token"。把 outstanding 传输压到 ≤8，等于把这条窗口收紧两个量级。
3. **`clWaitForEvents` 隐含 flush**（spec），但**不要依赖**：所有 wait 站点显式 `clFlush` 后再 wait（照 `OCL:8611-8613` 的 barrier+wait 改成 marker+wait 时同理），以免新码路比现状少一次 flush 而偷偷改变队列深度。
4. **验收矩阵**（每层各两腿，短腿纪律）：`OPFLUSH=1 + 新开关=0`（必须与背书库逐字节全等，证明零扰动）→ `OPFLUSH=1 + 新开关=1`（tok 全等 + health=1 + drain 计数下降 + KGSLSUBMIT 指纹）；**禁止**任何「async(OPFLUSH=0) + 新开关」组合作为收益证据（那是已知全乱区，只可用于探针取证）。
5. **`GGML_OPENCL_SYNC_MODE`**（新）：`0`=barrier+wait（现状 `OCL:8611-8613`）/`1`=clFinish/`2`=marker+wait。用于回答"barrier 自身是否贡献 KGSLSUBMIT"，纯诊断，不改默认。

### 3.8 env 门控与回退矩阵（默认全关）
| env | 层 | 默认 | 关 = 回退到哪 |
|---|---|---|---|
| `GGML_OPENCL_ISLAND_STATS=0/1` | L0 | 0 | 纯计数，零行为 |
| `GGML_OPENCL_ASYNC_SET=0/1` | L1 | 0 | `OCL:13983` 原 CL_TRUE 臂 |
| `GGML_OPENCL_ASYNC_GET=0/1` | L1 | 0 | 各臂原 CL_TRUE 读 |
| `GGML_OPENCL_MAX_INFLIGHT=<n>` | L1 | 8 | 1 ≡ 近似现状（每次即等） |
| `GGML_OPENCL_EVENTS=0/1` | L2 | 0 | `OCL:16045-16051` 全 false（现状） |
| `GGML_OPENCL_SCHED_COPIES=<1\|2>` | L2 | 1 | `CTX:717-721` 原 parallel |
| `GGML_OPENCL_ISLAND_HBUFT=0/1` + `…_MAX=<bytes>` | L3 | 0/65536 | 现状 input_cpy + 阻塞传输 |
| `GGML_OPENCL_SYNC_MODE=<0\|1\|2>` | 诊断 | 0 | `OCL:8611-8613` 现状 |
| （沿用）`GGML_OPENCL_OPFLUSH/OPSYNC/OPBATCH/OPFILTER/OFFLOAD_MMID` | — | — | 不动，只与之共存 |
> 纪律：① 单变量开；② 一次只动一层；③ `GGML_OPENCL_EVENTS` 必须与四个 event 钩子**同一提交原子性**（`BASE:691/705` assert 会当场 abort）；④ 双编译门（`TYL_MESA_LEG` ON/OFF）照 R-028/R-011 清单复核——L1/L2/L3 触及的成员（extra 结构、svm buft、enqueue helper）与 R-011 三成员同区。

---

## 4. 需要的新探针/计数（**只设计，不实现**）

- **P1 `libclcount` LD_PRELOAD 垫片（前作 §3 L1 腿点名，树内无实现）**：包 `clEnqueueWriteBuffer/ReadBuffer/MapBuffer/NDRangeKernel/WaitForEvents/Finish/Flush/BarrierWithWaitList/MarkerWithWaitList/ReleaseMemObject`，输出 `per-callsite × {blocking,async} × {tensor name bucket}` 直方图；join key 用 `cl_mem` 指针 + tensor name 前 28B。**这是 §1.3 与 §2.3 唯一可信的定罪工具。**
- **P2 岛边界计数器（in-tree，L0）**：四 drain 点 + 两传输点 + `split.n_inputs`，按 `ggml_op_name(src)` 分桶；附带 `n_copies/cur_copy` 实际值（回答前作 §5-2 的乘数问题）。
- **P3 scratch 释放↔再分配配对计数（R11 共用把手，与 E4BOREUSE 对拍）**：在 `clReleaseMemObject`/`clCreateBuffer`/`clCreateSubBuffer` 记 `{ptr, ts, tensor}`，配对率给 Mesa 侧 E4BOREUSE 做 ggml 侧对齐（执行记录 R-035/036 「ggml 垫片释放配对计数」同一把手）。
- **P4 producer-event 覆盖率探针（L1b/L2 前置）**：统计"读事件 wait-list 为空但队列里其 producer 未退休"的比例 ⇒ 直接量化 N8 修复是否完整。
- **P5 岛 CPU 侧画像**：`SLOT:2741` 已有 `process_ns`，补 `readids/writeids` 的**调用次数与逐次字节**（现在只有 ns 累计，分不出 `SLOT:2026/2048` 循环次数）。

---

## 5. 未决问题

- **Q1** L1 的 host 源生命周期：`n_copies==1` 时 sched 的 input_cpy 池复用是否真的在下一图立刻发生（`BASE:2246-2247` 轮转 + realloc 路径）？需要 L0 实测，否则 L1 只能 `MAX_INFLIGHT=1`（≈无收益）。
- **Q2** `n_copies=2` 的显存/compute buffer 增量与 `BASE:1774-1782` realloc 抖动；prefill(512)/decode(1) 交替是否触发反复 realloc。
- **Q3** rusticl+kgsl 下 `cl_event` 是否真语义化（E1 定案 `RUSTICL_DEBUG=sync` 才 tok 级全等，说明事件路径可疑）：**必须先用一腿验证 marker+wait 与 barrier+wait 行为等价**，再谈 L2。
- **Q4** Mesa 栈下 `backend_ctx->adreno_gen/gpu_family` 判定是否仍命中 `OCL:11094-11143` 的 A7X/Intel  declines（若误命中，FA 会被踢 CPU 岛 = 巨大岛；logcat `[buft-probe]` 行 `OCL:10512-10522` 可机检）。
- **Q5** L3 的三证（ALLOC_HOST_PTR 落哪、cpu_prep-NOP coherency、持久映射读带宽）未跑——**L3 腿就是这三证**，不许先码后证。
- **Q6** svm buft 补 `.init_tensor` 后，bank 既有路径是否被新增 extra 生命周期干扰——buft 身份判定共 5 处（`OCL:15702`、`15734`、`15829`、`15923`（stage_pack 门）、`16102`（supports_buft）），新 extra 必须与 `OCL:15507 extras` 向量同所有权/同释放路径。
- **Q7** 岛专用 svm buffer 的偏移分配（自带 bump allocator？对齐取 `OCL:15644-15647 svm_mem_align`）与 `alignment`（`OCL:10931 rq.align_bytes`）一致性。
- **Q8** `SLOT:2026/2048` 逐 token 循环在 L3 后是否真的全部消失（`expert_ids` 若被 sched 判为 GPU 张量仍可能走 input_cpy）——需要 P2 直方图闭环。
- **Q9** 前作 §5-1 的 write_blk 157「全 CL_TRUE」与 `LLAMA_MOE_DRAIN_ASYNC` 默认 on 的矛盾仍未裁（R-033 判其为死代码 A/B）；本文把它降级为「drain 非活税」，**若 P1 显示 drain 侧仍有阻塞写，L1 需扩到 `OCL:15955-15971`**。

---

## 6. 证据索引（本文全部行号，均本工作树实测）

| 主题 | file:line |
|---|---|
| async 钩子 NULL 簇 | `OCL:11159-11176`（11162-11166、11173-11174）；空 stub `OCL:8585-8606` |
| caps / device events | `OCL:16040-16052`、`OCL:16146-16157` |
| synchronize 原语 | `OCL:8608-8615`；`sync_with_other_backends` `OCL:8620-8649`（8621 单设备早退） |
| 阻塞传输点 | `OCL:13983-13985`（写）、`OCL:14070`、`14084-14088`（读）、logits 注释 `14074-14075` |
| 内核 enqueue 不产 event | `OCL:1427`（+ `1370-1379` PROFILING 分支对照）；队列 in-order `OCL:7749-7753` |
| OPFLUSH/OPSYNC/OPBATCH | `OCL:9742-9791`；OPSYNC_READ `OCL:9799-9811` |
| supports_op 黑名单 | `OCL:10534`、`10543-10590`、`10591-10594`、`10599-10631`、`10632-10668`、`10908-10933`、`11094-11143`、`11146-11148` |
| buft 互认 / offload_op | `OCL:16098-16111`、`16129-16139` |
| svm buft（宿主可见） | `OCL:15497-15509`、`15545-15561`、`.init_tensor=NULL @15578`、`is_host @15652-15657`、alloc/map `15608-15610`/`15619-15621`、身份门 `15702/15734/15829/15923/16102` |
| sched：async 回落 | `BASE:405-431`、`433-473`、`628-649`、`651-670`、`674-680` |
| sched：copy/compute/事件 | `BASE:1524`（skip-copy 判据）、`1536-1547`、`1838-1909`、`1911-2002`（1924-1930/1986/1997）、`2151-2158`、`2246-2247` |
| sched 仪表 | `BASE:2004-2052`（`GGML_SCHED_STATS` + CPU 直方图）、`SET_CAUSE @1061-1064` |
| pipeline_parallel 门 | `CTX:521-550`、`sched_new @CTX:717-721` |
| CPU 接受 host buft | `ggml-cpu.cpp:493-496`；外部绑定 `ggml-backend.h:454`、`ggml-alloc.c:594` |
| 岛本体 | `llama-graph.cpp:2493-2496`（argsort_top_k）、`:2550`；`SLOT:2857-2869`、`2728-2744`、`2003-2010`、`2013-2052`、`2229-2249` |
| 网格/纪律 | `全景地图与网格计划:314`、`:379-384`；执行记录 R-012 `:346-361`、R-027 `:798-816`、R-033~R-036 `:986-1078` |
