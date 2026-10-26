# B0 · batched-MoE q3_K slot bank「CPU 岛」阻塞传输静态解剖与施工设计（2026-10-26）

> 只读分析员出品（ZCode Explore），主线验尸后由主线补录落盘（原 agent 只读无法写文件）。
> 台账锚点：leg-036（`bench_ledger.jsonl`）。
> 简称：**OCL** = `third_party/llama.cpp/ggml/src/ggml-opencl/ggml-opencl.cpp`（行号=当前工作树）；**SLOT** = `third_party/llama.cpp/src/llama-moe-slot.cpp`；**P11/P12** = `third_party/mesa-kgsl/patches/0011-…KGSL-backend…patch` / `0012-…per-backend-API.patch`（补丁文件内行号）；**LOG** = `docs/全GPU卸载_执行记录_2026-10-25.md`。

## 0. 事实底座（leg-036 原文）

> "per-token 边际=nd1974/wait367/read_blk181/write_blk157(全 CL_TRUE,map=0)/KGSLSUBMIT81；worker 合并 ~8.7:1；1.66 t/s=600ms/token ⇒ 税∝同步点数(705/token)非提交数"
> "CPU 岛（MoE slot bank ~8 阻塞传输/层×40 层）=最大可控同步源；P-3 主攻=消 705 同步（B0 fd_bo 常驻消 338 传输+配对 wait…）"

模型：qwen35moe 40 层 / 256 专家取 8（`docs/minicpmv47_35b_a3b_phone_plan_2026-10-15.md:12`，expert_stride **1,351,680B/层/专家**，Q3_K，gate/up/down 各 450,560B）。

## 1. 每 token 阻塞传输的确切来源（file:line）

### 1.1 生产路径上的 CL_TRUE 传输点（全量枚举）

**T1 · set_tensor 通用写（sched input_cpy → GPU）— OCL:13983-13985**
```cpp
    CL_CHECK(clEnqueueWriteBuffer(
        queue, extra->data_device, CL_TRUE, extra->offset + offset,
        size, data, 0, NULL, NULL));
```
触发者 = CPU 岛边界每次「CPU 张量→OpenCL pool buffer」复制。CPU 岛 = `MAP_CUSTOM1 ffn_moe_slots`（SLOT:2869 `ggml_map_custom1(ctx, expert_ids, map_custom, 1, &userdata[layer]);`；图上锚点 llama-graph.cpp:2494-2499，`build_slot_ids_tensor`）。每层 ≥1 次 slot-ids 上传；若 `MUL_MAT_ID` 的 3 个消费者（gate/up/down）不共享同一次 input_cpy，则 ×3/层。

**T2 · get_tensor 阻塞读（GPU→CPU，含 ids 回读与 logits）— OCL:14070（同型 40+ 臂）**
```cpp
        CL_CHECK(clEnqueueReadBuffer(queue, data_device, CL_TRUE, offset, size, data, 0, NULL, NULL));
```
每层 MAP_CUSTOM1 的输入 `selected_experts`（GPU 算出的 i32，llama-graph.cpp:2494 `ggml_argsort_top_k`）必须回读宿主 = 1 read/层；logits 读回 1/token（语义注释 OCL:14074-14075 "get_tensor is usually used to get back the logits"）。量化臂（如 q3_K OCL:14767-14770 三连读 + unpack kernel+event wait，OCL:14048-14049 同型）只在权重被 get 时触发——e2e 正常不触。

**T3 · stage drain WriteBuffer（LES 冷专家换页上传）— OCL:15944-15946**
```cpp
    CL_CHECK(clEnqueueWriteBuffer(backend_ctx->queue, bctx->raw_stage,
        blocking ? CL_TRUE : CL_FALSE,
        raw_off, slot_bpe, src_host, 0, NULL, ev_out ? &ev : NULL));
```
调用链：SLOT:2234-2249（drain，`LLAMA_MOE_DRAIN_ASYNC` 默认 on=CL_FALSE+每波一次 `ggml_cl_moe_q3k_stage_wait`→clWaitForEvents OCL:15989；`?0` 回落 OCL:15955 逐条 **CL_TRUE**）。每 miss 专家 = **2 条 rec**（SLOT:2161-2162 注释 "The per-expert rec pair (gate_up owner + down non-owner…)"）。**结论：expert 磁盘流式上传（[moe-ssd] merge-scan，SLOT:2441）走的正是 write_blk 口径**——map=0 印证 bank 本体是持久映射（preadv 直写不经 CL API，SLOT:1896-1903 route0 else 分支 `iov[i].iov_base = (uint8_t *) b.tensor->data + …`），miss 换页才产生 WriteBuffer。OCL:15911 注释自证历史口径：
> "// thread_local staging is reused by the next wave. …220 blocking writes/token each pay the driver round-trip (~0.35ms)"（OCL:15911-15912）

leg-036 write_blk=157 全 CL_TRUE ⇒ 该腿 drain 实质走了阻塞口径（或 async 事件 wait 被计入 wait367 而 write 全来自 T1——见 §5 存疑 1）。

**T4 · q3_K set_tensor CPU 岛 repack（3×CL_TRUE）— OCL:13021-13026**
```cpp
        CL_CHECK(clEnqueueWriteBuffer(queue, extra->q, CL_TRUE, 0,
                    qplane.size() * sizeof(cl_uint), qplane.data(), 0, NULL, NULL));
```
（se0/se1 同型 :13023/:13025）。仅在 q3_K 张量落**普通 OpenCL buffer**（非 SVM buft）时执行；GPU bank 态下 bank 张量走 buft set_tensor=纯 memcpy（OCL:15558 `memcpy((char *) ctx->svm + offset, data, size);`）不触发。**若 sched 每 token 重上传 slot 视图，则 3 write/层×40=120，是 write_blk 的另一候选大头（§5 存疑 2）。**

**T5 · dense-loop ids 回读 — OCL:26564-26566（每 dense-loop MUL_MAT_ID 1 read）**
```cpp
    CL_CHECK(clEnqueueReadBuffer(backend_ctx->queue, extra2->data_device, CL_TRUE,
        (size_t)(extra2->offset + src2->view_offs), ids.size()*sizeof(int),
```
只适用 q4_0/q4_K（q3_K batched-only，OCL 注释 "No dense-loop fallback exists (no dense q3_K GEMV)"）→ 对应普查「路由 MUL_MAT_ID 4 形状」≈ 4 read/token。

**已排除（env/编译门控，生产须关）**：OCL:9807（`GGML_OPENCL_OPSYNC_READ` 每节点 16B 读）、OCL:16509/16966/33216（`GGML_CL_OFFS_DEBUG`）、OCL:25025/25065（debug dump）、OCL:30575（`MOE_TILES` 门）、OCL:16257+（`#if 0` dump_tensor）、e2e CBD 审计读（`_probe/moe_probe/minicpm_e2e.cpp:185-206` `E2E_CBD_ONLY`）。q0a0 协议（`routeA_legs.sh:22-44`）未含这些开关。

### 1.2 账目表（传输点 → 次数/层 → 次数/token，40 MoE 层）

| # | 传输点 | file:line | /层 | /token 估 | 方向 |
|---|---|---|---|---|---|
| T1a | MAP_CUSTOM1 输入 selected_experts 回读 | OCL:14070 | 1 R | 40 R | R |
| T1b | slot-ids 输出上传（MUL_MAT_ID src2） | OCL:13983 | 1~3 W | 40~120 W | W |
| T3 | LES miss stage drain（2 rec/miss） | OCL:15944 (CL_TRUE 口径) | 2×miss(≈1.x) W | ~80~160 W | W |
| T3w | drain 波尾 clWaitForEvents / 各 unpack evt wait | OCL:15989 / 14049 | ~1~2 | ~367（wait 计数） | W |
| T4 | q3_K 面 repack（仅 CPU-buffer 态） | OCL:13021-26 | 3 W | 0（GPU bank 态）/120（CPU 岛态） | W |
| T5 | dense-loop ids 回读（路由 4 形状） | OCL:26564 | — | 4 R | R |
| L | logits 读回 | OCL:14070 系 | — | 1 R | R |
| 岛 | CPU 岛边界 OpenCL synchronize（barrier+wait） | OCL:8612-8613 | ~2 | ~80（计入 wait） | W |

对账：台账口径「~8 阻塞传输/层×40=320」与 T1a+T1b+T3（1R+1~3W+2×1.x W ≈ 5~8/层）吻合；read 侧 181−44≈**137 未逐点归因**（候选：sched 对同一 CPU 输出多消费者重复 input_cpy、lookahead pred/窗口张量宿主读、map_custom2 双源读）。write 侧 157 ≈ 40~120(T1b)+80~160(T3 阻塞口径) 之组合。逐 API 直方图未入库 ⇒ 列入 §5 存疑，L1 腿对账闭合 ≥80% 才算数（P-3 报告 A1 判据，`p3_design_analysis_1026.md:188`）。

## 2. fd_bo 面盘点

**Mesa 侧（0011/0012）**：
- **0012**（上游 Igalia/Lucas Fryzek）给 per-backend API 补三刀（补丁头逐字）："Add bo_map, bo_from_dmabuf, and bo_close_handle to the per backend APIs for freedreno/drm."（P12:5-7）。即 `fd_bo_map` 派发对 kgsl 后端可用。
- **0011 kgsl_bo_map**（P11:115-148）：native BO = `os_mmap(0, bo->size, PROT_READ|PROT_WRITE, MAP_SHARED, bo->dev->fd, offset)`（offset=`handle<<12`，P11:65-68 "the returned alloc id shifted over 12"）；import 态 = `os_mmap(…, kgsl_bo->import_fd, 0)`（P11:124）。**= 一次性映射、常驻可读写的持久映射能力，正是 B0 所需**。
- **BO 分配**：native `IOCTL_KGSL_GPUMEM_ALLOC_ID`（P11:318）不带 cache 旗；`FD_BO_SHARED|SCANOUT` 走 dma_heap/ION（P11:233-282），ION 路 `.flags = 0, /* uncached */`（P11:255）。**无 GEM_MMAP、无 virml、无 IOCTL_KGSL_SHAREDMEM_MAP_USER_MEM**（用户内存映射不走 SHAREDMEM；ggml 注释 OCL:15592-15594 亦证 "kgsl MAP_USER_MEM gives a non-host GPU VA… pointer-identity SVM is unreachable"）。
- **共面风险（关键）**：`kgsl_bo_cpu_prep` 为 **NOP**（P11:78-83 "only need to handle implicit sync here which is a NOP for KGSL"）⇒ CPU 写/GPU 读的 cache 维护全押 KGSL 默认 cachemode，**fd_bo 路 coherency 必须在 Mesa 真机验证**（R-012 残余风险同源：OCL:7642-7644 "GPU read 8-12 GB/s vs 2.3 GB/s via regular cl_mem"，旧数据 vendor/740，Mesa 未量）。

**ggml 树内骨架（已在树，2026-10-17 起）**：
- SVM buft = **fd_bo 持久映射模型**：`clCreateBuffer(CL_MEM_READ_WRITE | CL_MEM_ALLOC_HOST_PTR, …)`（OCL:15608-09）+ 一次 `clEnqueueMapBuffer(…, CL_TRUE, CL_MAP_READ|CL_MAP_WRITE, 0, size, …)`（OCL:15619-20）持到 free（OCL:15529 才 unmap）；`is_host=true`（OCL:15643-47）；模型注释 OCL:15591-15598 "fd_bo persistent-map model (replaces FGSVM)… One copy of the data, standard OpenCL, works on vendor and Mesa alike."
- 消费方：`third_party/llama.cpp/src/models/qwen35moe.cpp:55-69`（`LLAMA_MOE_BANK_GPU=1` → `ggml_backend_opencl_svm_buft(gpu_dev)`）；pack 消费 raw_stage 同 BO（OCL:15890-15899）。
- **R-011 bitrot 现状（实测本工作树）**：`kernel_moe_q3k_pack/has_fgsvm/svm_mem_align` 声明已在守卫外（OCL:1502-1504），pack 内核创建无守卫（OCL:4334），`has_fgsvm` 写点 OCL:7647 无守卫 ⇒ R-011 清单三成员簇**已修**（R-028 guard-sweep 落地），OFF 构建编译门需复核（§5 存疑 6）。死代码可删（R-012）：`clEnqueueSVMMemcpy` 路（OCL:15713）、`clSetKernelArgSVMPointer` 分支（OCL:15782）。
- **R-012 定案**（LOG:355-361）：方案序 = 方案0 fd_bo 持久映射（零实现量）＞ 方案1 host staging+WriteBuffer（A/B 备胎，2×带宽）＞ 方案3 sub-buffer 池（max_alloc 兜底）；排除一切 clSVMAlloc/SVMMemcpy（Mesa SVM caps 0x0，R-015 表）。
- **地图 B0/B 线**（`全GPU卸载_全景地图与网格计划_2026-10-25.md:314,379-383`）：B1 已锁「全常驻不可能；全 GPU=热专家+流式换页成立」；B0=能力矩阵⬜、B2 基线⬜、B3 knob🟡、B5 LES 接 GPU bank🟡；胜负账「GPU 命中率 ≥~70% + 提交受控 ⇒ 物理上限 ~12 t/s > 8.07」（:313）。R-015 追加：「B0 bank 预算勿信 Mesa GLOBAL_MEM（高估 2×），OOM 守卫照开」（LOG:465）。

## 3. B0 施工路线（≤2 条）

### 路线一 · fd_bo 常驻 buft 全量消传输（主推）

| 改动点 | file:line | 内容 | 消同步/token |
|---|---|---|---|
| ① LES 换页切 route 0（preadv 直写持久映射 + pack 同 BO） | SLOT:1880-1903（选路）、OCL:15716-15727（`ggml_cl_svm_upload_mode` 默认已 0）、OCL:15890-15899（pack 同 BO）；drain 侧 SLOT:2234-2249 归零 | 消 T3 stage WriteBuffer | −80~160 W + 配对 wait/事件 |
| ② CPU 岛小张量（slot-ids 输出、selected_experts）落持久映射 buft | 复用 OCL:15589-15631 buft（is_host=true，GPU 以 cl_mem 直读）；sched 侧让其驻 host-visible buft，免 OCL:13983/14070 | 消 T1a/T1b | −80~160 R/W + wait |
| ③ 兜底事件化（若②不落地）：set/get_tensor CL_TRUE→CL_FALSE+末次 wait | OCL:13983,14070；生命周期教训已在 OCL:14071（release 前必须已等待） | n 次隐式 flush→1 | 中 |
| 保留红线 | logits 读回、岛边界 synchronize（OCL:8612-8613）不可省（P-3 报告「正确性红线清单」:174-184） | — | 底线 ≈40 wait |

预期：**705 → ~100-150 同步/token（−75~85%）**；KGSLSUBMIT 81 → 岛数下界（~41+/token）。
依赖：0011 `kgsl_bo_map` + 0012 `bo_map` API 均在；**缺 = Mesa 真机三证**：(a) rusticl `ALLOC_HOST_PTR` 在 kgsl 选 native BO 还是 dma_heap（决定 cache 口径）；(b) cpu_prep-NOP 下 CPU写→pack 读 coherency（错专家权重=静默错数）；(c) 持久映射 BO 的 GPU 读带宽（喂 GEMV，R-012 判据）。

### 路线二 · 混合「热专家常驻 + 冷专家仍换页」（B1 已锁形态，路线一的运营态）

冷路径 = 路线一①（换页走持久映射，0 staging）；热路径 = LES（SLOT:2441 merge-scan，B5 预测器在树未接）把命中专家 pin 出换页集：改动点 = SLOT 窗口/淘汰（`window_mode` 分支 SLOT:1826-1830、miss 统计 SLOT:3288-3324）加 LRU-pin + 面常驻（planes 已常驻，免重 pack）。热层每 token **0 传输**；冷 miss 仍 2W（route0 后=纯 CPU memcpy+pack）。命中率 ≥70% 时同步 ≈ 30%×路线一残余换页税。
**内存账**（vendor heap 口径 7.38GiB 为 GPU 可用上界，LOG:459；Mesa GLOBAL_MEM 14.76GiB ×2 高估不可信 LOG:465）：单专家 slot raw 1.289MiB + planes≈0.15×raw（q=M·K/32×12B、se0/se1 各×2B/半行，OCL:15757-15759 式）≈ **1.48MiB/常驻专家**；40 层×N 热 ⇒ N=32：1.9GB、N=64：3.8GB（+非专家 1.66GB+KV+prefill bank，830 可行）；全 256/层=12.65GB（地图:300「全常驻不可行」实锤）。830 MemTotal 实测值未入库（§5-8）。

### 最小真机验证腿（≤3 腿，短腿纪律，协议 = `routeA_legs.sh:7-13` 三背书 + driver=26.2.4 判据）

- **L1 归因+coherency 门（0.5d）**：libclcount 垫片复跑 q0a0 + `LLAMA_MOE_UPLOAD=0` + `LLAMA_MOE_DRAIN_ASYNC=0/1` 双腿；判据 = ①write_blk 157→≤40、直方图与 338 账闭合 ≥80%；②pack 同 BO 自洽（planes 对拍 NMSE≤1e-6，coherency 错=专家权重静默错，health_hits 必查）；③fd_bo 读带宽采样（喂数不塌 2.3GB/s 旧底）。
- **L2 CPU 岛小张量持久化（1d）**：slot-ids/selected_experts 走持久映射 buft（或 OCL:13983/14070 事件化兜底）；判据 = read_blk≤~10、wait367→<150、**48-token 与 leg-028 基线逐字节全等**（LOG:892 口径）。
- **L3 热池混合 A/B（1d）**：hot-pin N=32/64 扫描 + 冷换页 route0；判据 = t/s ≥2×MESA_FLUSH1(1.49) 且 health_hits 一致、miss 率随 N 下降、meminfo 峰值不出 vendor 7.38GiB 口径。

## 4. R-026 红线对照（S5 = 1 提交/图）

| 指标 | leg-036 现状 | 路线一 L1+L2 后 | 路线二叠加（命中≥70%） |
|---|---|---|---|
| 同步点/token（R+W+wait） | 705 | **~100-150（−75~85%）** | ~60-100 |
| 阻塞传输（R+W） | 338 | **≤~20**（logits+dense-loop+杂散） | ~15+2×冷miss |
| KGSLSUBMIT/token | 81（numcmds=2 主导） | **~41+ 下界**＝CPU 岛数+图尾 | 同左 |

**判读**：R-026/leg-036 已裁「税∝同步点数非提交数」（bench_ledger:37）⇒ B0 的收益兑现于 600ms 同步税，**不兑现 S5=1/图**：提交数下界由 40×MAP_CUSTOM1 岛切分（OCL:8612-8613 barrier+wait 每岛必发）钉死，S5 达标仍需 P-3 岛消除（deferred 管线深化，`全GPU卸载_ffn_moe_slots_考古与实现方案_2026-10-24.md` 案 C「主攻」）+ rusticl B1 聚合窗（P-3 报告 §3B）。B0 定位 = P-3 前置最大可控单点，非 S5 充分条件。

## 5. 未验证 / 存疑清单

1. **逐点直方图未入库**：181R/157W 的 T1/T3/T4 分解是静态重构（账闭合 ~94% 靠台账「~8/层」口径背书），libclcount 逐调用点计数未归档；L1 腿补账。write_blk「全 CL_TRUE」与 drain async 默认 on（SLOT:2229-2232）矛盾——要么该腿走了 `LLAMA_MOE_DRAIN_ASYNC=0`，要么 157 全来自 T1/T4。
2. sched 对同一 slot-ids 张量的 3 个 MUL_MAT_ID 消费者是否共享一次 input_cpy（ggml-backend-sched 未逐行读）→ T1b 乘数 1 还是 3。
3. rusticl `CL_MEM_ALLOC_HOST_PTR` 在 kgsl winsys 落 native GPUMEM BO 还是 dma_heap 路（`FD_BO_SHARED` 触发条件未实测）→ cache 口径/带宽差异（P11:305-307）。
4. `kgsl_bo_cpu_prep`=NOP 下的 CPU写→GPU读 coherency 无测试用例（L1②为门）。
5. fd_bo 持久映射 GPU 读带宽 Mesa 实测缺（OCL:7642-7644 为 vendor/740 旧数）。
6. OFF（TYL_MESA_LEG）构建下 SVM buft/pack 链编译态：R-011 三成员现树已出守卫（OCL:1502-1504/4334 实证），但未过双编译门复验（R-028 手术态）。
7. leg-036 是否残留 CBD/WDUMP/E2E_WATCH 类探针（q0a0 协议未含，默认关——按零算，待 err 复核）。
8. 830 MemTotal/MemAvailable 实测值未入库；预算表用 vendor 7.38GiB heap 口径。
9. `expert 26240/token` 与 40×8=320 选专家的口径差（疑为 merge-scan 累计 runs，SLOT:2441 日志字段）未核。
10. free 时 unmap 路（OCL:15529-15530）在 Mesa/kgsl 上从未跑过（free-on-exit 即可掩盖泄漏/挂死）。
