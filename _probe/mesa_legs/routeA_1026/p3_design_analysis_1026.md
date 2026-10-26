# P-3 提交合并 · 可施工设计分析（2026-10-26）

> 只读分析员出品。目标 = S5「每整图 1 次 KGSLSUBMIT」的现状解剖与改动点排序。
> 台账引用：R-006（docs/Mesa单提交架构解_C1_2026-10-25.md）、R-026/R-031
> （docs/全GPU卸载_执行记录_2026-10-25.md:780,886）。
> 代码基线：third_party/llama.cpp/ggml/src/ggml-opencl/ggml-opencl.cpp（下称 OCL，行号=当前工作树）；
> rusticl = 上游 mesa-26.2.4 tag（gitlab raw 在线读码，见 §5 存疑第 1 条）；
> kgsl winsys = third_party/mesa-kgsl/patches/0011-freedreno-drm-kgsl-Add-KGSL-backend-for-freedreno.patch
> （下称 P11，引用为补丁文件内行号；winsys 源码本体在 DGX chroot /opt/trixie-cl/root/mesa-26.2.4，本仓无拷贝）。

---

## 1. ggml 侧提交面

### 1.1 图执行主循环

- 主循环 = `ggml_backend_opencl_graph_compute`，OCL:9727：
  `static ggml_status ggml_backend_opencl_graph_compute(ggml_backend_t backend, ggml_cgraph * cgraph) {`
  逐节点遍历 = OCL:9739-9740：
  `for (int i = 0; i < cgraph->n_nodes; i++) {` / `ggml_tensor * node = cgraph->nodes[i];`
- **每节点 enqueue ≥1 次**：统一出口 = 成员函数 `enqueue_ndrange_kernel`（OCL:1356），
  非 profiling 分支直发 `clEnqueueNDRangeKernel(queue, kernel, work_dim, NULL, global_work_size,`（OCL:1372 为 profiling 分支）。
  一个 node 可触发多次（融合 op、split-k、pack+gemv）：35B decode 实测 n_enqueues≈2800+/token。
- **图尾无同步**：循环体之后直接 `return GGML_STATUS_SUCCESS;`（OCL:10100），
  graph_compute 体内除下述开关外**没有任何 clFlush/clFinish**。排空由 backend 接口
  `synchronize` 承担（OCL:11167 注册 `/* .synchronize = */ ggml_backend_opencl_synchronize`，实现 OCL:8608-8614）：
  `CL_CHECK(clEnqueueBarrierWithWaitList(backend_ctx->queue, 0, nullptr, &evt));`（:8612）
  `CL_CHECK(clWaitForEvents(1, &evt));`（:8613）
  → 在 rusticl 中 barrier 与 wait 各触发 flush（§2.1），即「每图 ≥1 flush」前提本已成立。

### 1.2 三开关确切语义（读码确认，非猜测）

| 开关 | 定义/生效行 | 语义 | 默认 |
|---|---|---|---|
| `GGML_OPENCL_OPFLUSH=<n>` | OCL:9765-9771 | 每 n 个节点 `clFlush(backend_ctx->queue);`（OCL:9769）——只推硬件，不等待 | **0 = 关** |
| `GGML_OPENCL_OPSYNC=1` | OCL:9746-9749, 9772-9791 | **每节点前** `cl_int fin_err = clFinish(backend_ctx->queue);`（OCL:9778） | 关 |
| `GGML_OPENCL_OPBATCH=<n>` | OCL:9755-9757 | 每 n 节点一次 clFinish；门 = OCL:9772 `if (opsync_en \|\| opbatch > 1) {` | **1 = 关**（=1 不进分支） |
| （附）`GGML_OPENCL_OPSYNC_READ=1` | OCL:9799-9811 | 节点后 16B 阻塞读 `clEnqueueReadBuffer(backend_ctx->queue, xs->data_device, CL_TRUE,`（OCL:9807） | 关 |

矩阵脚本印证（third_party/mesa-kgsl/scripts/run_mesa_matrix.sh:118-119）：
`MESA_ASYNC)  one MESA_ASYNC $MESA_ENV GGML_OPENCL_OPFLUSH=0 ;;`（:118）
`MESA_FLUSH1) one MESA_FLUSH1 $MESA_ENV GGML_OPENCL_OPFLUSH=1 ;;`（:119）
⇒ **MESA_ASYNC 态 = 图内零主动 flush**（opflush 默认 0，opbatch 默认 1 不进分支）。

两个历史注释是 P-3 的**安全红线**：
- OCL:9751-9752（OPBATCH 注释）：`// ring-pressure bisect: 118586 submits were`
  / `// observed for 271390 enqueued ops — kernels go missing under deep`——深 enqueue 下丢 kernel。
- OCL:9762-9763（OPFLUSH 注释）：`// clFinish) makes free-run text healthy = whole fragmentation was the`
  / `// submission race; flush is the production-grade candidate.`
- R-031 复证（执行记录:891）：`**MESA_ASYNC 两树皆垃圾 = async 竞态与守卫无关（挂账 P-3，S5 KGSLSUBMIT 子腿前置缺陷）**`。

### 1.3 clFlush/clFinish/阻塞传输全部调用点（图内 vs 图外）

**图内（9727..10101）**：仅 OPFLUSH clFlush（9769）、OPSYNC/OPBATCH clFinish（9778）、
OPSYNC_READ 阻塞读（9807）——默认全关。`sync_with_other_backends`（调用于 OCL:9816）
单 GPU 设备时直接返回：OCL:8621-8622 `if (g_ggml_backend_opencl_devices.size() < 2) {` / `return; // No other devices to synchronize with.`
⇒ 不产生 flush。

**图外、每 token 必经（= async 态提交税主嫌）**：
- logits/张量读回 `ggml_backend_opencl_buffer_get_tensor`（OCL:14004），F32 直通：
  OCL:14070 `CL_CHECK(clEnqueueReadBuffer(queue, data_device, CL_TRUE, offset, size, data, 0, NULL, NULL));`
- 张量写入 `ggml_backend_opencl_buffer_set_tensor`（OCL:11760），常规路径：
  OCL:13983-13984 `CL_CHECK(clEnqueueWriteBuffer( // queue, extra->data_device, CL_TRUE, extra->offset + offset,`
- 量化读回内嵌 unpack kernel + 事件等待（OCL:14048-14049 `clEnqueueNDRangeKernel(...&evt));` 后
  `CL_CHECK(clWaitForEvents(1, &evt));`）；同类组合遍布 11856/11964/12015/.../15353（grep 命中 40+ 处）。
- **CPU 岛往返（大头嫌疑）**：`MAP_CUSTOM1 ffn_moe_slots` 每层落 CPU——
  docs/全GPU卸载_ffn_moe_slots_考古与实现方案_2026-10-24.md:55：
  `decode 每 token 40+ 层各一次 MAP_CUSTOM1 = 40+ 次往返。`
  每次往返 = sched 图分裂 → OpenCL `synchronize`（8612-8613）+ input/output 阻塞 set/get_tensor
  （13983/14070）⇒ 每层 ≥3~6 次隐式 flush。
- 探针/调试（env 门控，生产须关）：OCL:11787-11789 `GGML_OPENCL_SET_TENSOR_FINISH`
  进 set_tensor 即 `clFinish(queue);`；OCL:10064-10068 `E2E_WATCH` 命中后每节点
  `ggml_backend_tensor_get(watch_t, wv, 0, sizeof(wv));`（=每节点一次阻塞读）。
- 一次性/装载期：FA 重建 `clFinish(retry_queue);`（OCL:1681）、prepack clFinish（OCL:12354）；
  set_rows 路径已有免同步意识（OCL:15796 附近注释 `// no clFinish: the in-order queue places this before any later GEMV that`）。

**判读**：MESA_ASYNC submits=23394/48tok ≈ **487/token**，而图内主动 flush=0，
故提交全部来自 (a) 阻塞 Read/Write/Map 与 event-wait 的隐式 flush（rusticl 语义 §2.1），
(b) CPU 岛图分裂同步，(c) fork 私有层（FDBATCH/FD_* 探针，源码未收编）。

---

## 2. rusticl 侧提交面（上游 mesa-26.2.4，gitlab raw 读码）

### 2.1 一次 clEnqueueNDRangeKernel 到 kgsl 提交的完整路径

```
api/kernel.rs clEnqueueNDRangeKernel
  → create_and_queue(q, CL_COMMAND_KERNEL, evs, event, block=false, EventSig)   [api/event.rs]
      block=false 分支只 q.queue(e)（pending.push(e)）——★提交不发生
  → worker 线程收到 chan_in 批次后才 e.call(&mut ctx) 执行 EventSig：
      core/kernel.rs launch_with_args：ctx.bind_kernel/…/ctx.launch_grid(...) 录制进 pipe 命令流
  → 批尾 flush_events：let fence = pipe.flush();   [core/queue.rs]  ← Gallium screen flush
  → freedreno translate 收尾 → kgsl winsys：fd_pipe_funcs.flush = fd_pipe_sp_flush（P11:559）
  → kgsl_ringbuffer_sp.c flush_submit_list（P11:708 起）合并全部延迟 submit 的 IB 链：
      .numcmds = cmd_idx,（P11:765）
      int ret = kgsl_pipe_safe_ioctl(pipe->dev->fd, IOCTL_KGSL_DEVICE_WAITTIMESTAMP... 见下
```
关键读码结论（每条 = 上游 tag 文件:符号）：

1. **clFlush/clFinish 语义**：`api/queue.rs`——
   clFlush 体 = `Queue::ref_from_raw(command_queue)?.flush(false)`；
   clFinish 体 = `Queue::ref_from_raw(command_queue)?.flush(true)`；
   `clReleaseCommandQueue` 释放前隐式 flush。barrier/marker =
   `create_and_queue(q, CL_COMMAND_BARRIER, evs, event, false, Box::new(|_, _| Ok(())))`（api/queue.rs）。
2. **Queue::flush(wait)**（core/queue.rs）：
   `pub fn flush(&self, wait: bool) -> CLResult<()> {`，体首 `let events = mem::take(&mut state.pending);`，
   然后 `state.chan_in.send(events)`（唯一投递点），wait=true 时
   `last.upgrade().map(|e| e.wait());`。⇒ **一次 Queue::flush = 一次 chan_in 批次**。
3. **worker 线程按批 flush（不按事件）**：worker 循环 `rx_t.try_recv()`/`recv()` 收批次，
   逐个 `e.call(&mut ctx)` 录制，批尾恰一次
   `let flush_err = flush_events(&mut flushed, &ctx, &tx_q2);`；
   `flush_events` 内 `let fence = pipe.flush();`（仅 `if !evs.is_empty()`）。
   中间 flush 只发生在**用户事件**处：`if e.is_user() { ...flush_events(...); e.wait(); }`
   与调试态 `sync_every_event`。fence 等待不在 worker，而在独立 signal 线程（`tx_q2` 收 `(PipeFence, events)`）。
4. **录制延迟**：core/kernel.rs `launch_with_args` 只返回 EventSig 闭包
   （bind_kernel/bind_sampler_states/set_global_binding/memory_barrier/launch_grid），
   体内唯一主动 flush 是调试开关：`ctx.flush().wait();` 仅当 `Platform::dbg().sync_every_event`。
   ⇒ **clSetKernelArg 不触发 flush**（参数快照进 EventSig，enqueue 不碰内核态）。
5. **阻塞传输**：`api/memory.rs` clEnqueueReadBuffer 等把 blocking 标志传入
   `create_and_queue(q, CL_COMMAND_READ_BUFFER, evs, event, block, Box::new(move |_, ctx| b.read(ctx, offset, ptr, cb)))`；
   `create_and_queue`（api/event.rs）block=true 分支 = `q.flush(true)?`（阻塞排空，不 ev.wait()）。
   core/memory.rs 的 `Buffer::read`/`write` 用 `ctx.buffer_map`/`ctx.buffer_subdata` 直拷，
   自带警告注释 `clEnqueueReadBuffer and clEnqueueMapBuffer stall the GPU`；
   跨设备迁移另有 `ctx.flush().wait()`（get_res_for_access，`if flush {`）。
   **clWaitForEvents**（api/event.rs）= 先对 deep-unflushed 队列逐个 `q.flush(false)?` 再 `e.wait()`
   （core/event.rs `Event::wait` = condvar：`while lock.status >= CL_RUNNING as cl_int {`）。
6. **既有批量钩子**（P-3 可搭的车）：
   - worker「按批 flush」本身就是聚合单位（批次=Queue::flush 次数）；
   - kgsl `flush_submit_list` 已实现多 submit 合一 ioctl（P11:718-748 foreach_submit 累加 nr_cmds、
     `DEBUG_MSG("merged %u submits", cmd_idx);` P11:742、
     `IOCTL_KGSL_GPU_COMMAND` 单次提交 P11:772）；
   - kgsl_device.c 预留软针异步队列：`/* async submit_queue used for softpin deffered submits */`（P11:375）/
     `util_queue_init(&dev->submit_queue, "sq", 8, 1, 0, NULL);`（P11:376）；
   - ringpool 复用 `fd_pipe_sp_ringpool_init(pipe);`（P11:610）；等待 ioctl =
     `wait_timestamp_safe(pipe->dev->fd, kgsl_pipe->queue_id, fence->kfence, timeout)`（P11:511）。

### 2.2 与实测的矛盾点（P-3 的真问题所在）

R-026（执行记录:782-786）：`**MESA_ASYNC 1.09 t/s**`（:782）、
`（prefill 35518ms，submits 23394，health_hits=0 输出乱码）`（:783）、
`（async 提交粒度 numcmds=2 主导，S5 需 1/图 = P-3/P-4 对象）`（:786）。
按 §2.1，纯 async（图内零主动 flush、图末 1 次 barrier+wait）应得 ≈每图 1~2 提交；
实测 numcmds=2 主导（≈1 launch 一提交）⇒ **每 token 有 ~487 次 Queue::flush 级触发**，
只可能来自 §1.3 的隐式 flush（阻塞传输/event-wait/CPU 岛分裂）或 fork 私有层额外 flush
（FDBATCH 是否主动分段——未见源码，存疑 §5）。**归因未实测，这是 P-3 的第一块砖。**

---

## 3. 合并点候选清单

### A. ggml 侧（便宜、env 门控、可 A/B）

| # | 改动点 | 位置 | 预期省提交 | 风险 |
|---|---|---|---|---|
| A1 | **归因探针先行**：LD_PRELOAD 计数 shim 套 libRusticlOpenCL 导出（clFlush/clFinish/clEnqueueRead/WriteBuffer(CL_TRUE)/Map/Barrier/Marker/clWaitForEvents），逐 token 直方图对账 KGSLSUBMIT | 路 A glibc clrt 运行时（_probe/mesa_legs/routeA_1026/dgx_pull/clrt-overlay） | 0（定性归因） | 无（只读插桩）；bionic 侧另需一套 |
| A2 | **CPU 岛批处理化**：ffn_moe_slots 每层往返 → prefetch/延迟排空（案 C「异步重叠」已在册，slots 方案:70 `**结论**：B 立即做，C 是主攻方向`） | 调度层+slots op；税点=OCL:13983/14070/8612 | 最大头（估 200~400/token） | slot 表被下游读之前必须完成——prefetch 须保留「末次读前 wait」；漏=读错专家权重 |
| A3 | **图外散点阻塞传输事件化**：非 logits 的 get/set_tensor 改非阻塞 enqueue+末尾单次 wait（n 次 flush→1） | OCL:13983,14070 及 14048-14050 型组合 | 中（每次 n→1） | logits 读=图末唯一强制排空必须保留；临时 buffer 生命周期（OCL:14071 `CL_CHECK(clReleaseMemObject(data_device));` 前必须已等待） |
| A4 | **OPFLUSH 粒度化**（图内每 N launch 一 flush 的对照腿） | OCL:9765-9771 改造 | 对照用（非收益） | 深队列丢 kernel（OCL:9751-9752）——N 是竞态容量参数，不是自由度 |
| A5 | **env 卫生检查**进 run_mesa_matrix 预检（E2E_WATCH/SET_TENSOR_FINISH/Opsync 残留） | OCL:10060,11787；scripts/run_mesa_matrix.sh | 防假阳性 | 无 |

**「OPFLUSH=0 下再减 flush」可行性**：图内主动 flush 已为 0，剩余可减 = A2/A3 隐式 flush。
若 A1 归因显示大头在 CPU 岛（40+ 层 × 每层 3~6 次 ≈ 120~240，加 logits/unpack 散点），
则 ggml 侧天花板由 slots 案 C 决定；rusticl 侧 B1 摊还则不受此限。

### B. rusticl 侧（提交语义手术，收益直达 KGSLSUBMIT 计数）

| # | 改动点 | 位置 | 预期省提交 | 风险 |
|---|---|---|---|---|
| B1 | **flush 聚合窗**：core/queue.rs `Queue::flush` 对 wait=false 的调用做窗口聚合（N 事件或 t 毫秒内只 chan_in 一次）；worker 批尾照旧 1 次 pipe.flush | core/queue.rs flush()（`state.chan_in` 投递处） | 与 (a) 类触发成正比下降，理想态→每图 1~k | clFlush 契约（「尽快提交」）被放宽——只对「等待全走 finish/blocking」的负载安全（ggml 正是）；窗口内崩溃丢命令 |
| B2 | **阻塞传输 flush 降级为 tail**：block=true 的 `q.flush(true)` 复用同批未清空 pending（core/queue.rs 已有 `state.last = Arc::downgrade(last);` 跟踪），只补尾 | api/event.rs create_and_queue + core/queue.rs | 与阻塞调用次数成正比 | 低（等待语义不变） |
| B3 | **上界对照**：现成 `Platform::dbg().sync_every_event`（core/kernel.rs `ctx.flush().wait();`）跑「每事件强制 flush」腿，量化 rusticl 层 per-event 税 | 现成调试旋钮 | 归因用 | 无 |
| B4 | **FDBATCH 分段审计**：kgsl flush_submit_list 已合并（P11:708-796），若 numcmds 恒=2 是因 fork 把一次 pipe.flush 的 submit 链截段，需 fork 源码定位 | fork 私有层（源码未收编，P0-1 旧账） | 若存在截短：直接回收 | 前置=P0-1 收编 fork 源码 |

**不能省的同步点（正确性红线清单）**：
1. logits 读回（图末唯一强制排空）——每 token ≥1 次 flush+wait 必须保留；
2. 每个 `CL_TRUE` Read/Map 的「此前写已可见」靠 block=true→`q.flush(true)` 保证（api/event.rs）；
3. CPU 岛边界：sched 分裂处 OpenCL `synchronize`（OCL:8608-8614 barrier+wait）在岛输出被
   下游 GPU 节点消费前不可省；
4. `clSetKernelArg` 安全（参数快照进 EventSig，录制延迟 worker 执行）——但同 kernel 对象跨节点
   复用时依赖同队列 in-order（rusticl worker 单线程录制，天然满足）；
5. `clGetEventProfilingInfo` 等待完成 = 隐式 flush+wait ⇒ `GGML_OPENCL_PROFILING` 编译态
   （OCL:1372-1375 每次 enqueue 后 `populateProfilingInfo(...)`）在 Mesa 栈必须保持 OFF。

### C. 最小实验设计（顺序执行）

1. **E-归因（半天，零风险）**：A1 探针 + run_mesa_matrix MESA_ASYNC 重跑 48tok，
   输出每 token 各 API 隐式 flush 直方图；判据 = 与 KGSLSUBMIT≈487/token 对账闭合 ≥80%。
2. **E-上界（1 天）**：ggml 加 `GGML_OPENCL_ENDFLUSH=1`（图尾一次 clFinish，其余不动）——
   预期 async submits 由 487/token 降至「不可延迟项」水平；
   文本健康判据沿用 leg-028（49×u32 与 ON 基线逐字节全等 + health_hits/drop，执行记录:892）。
3. **E-rusticl（2~3 天，DGX chroot /root/mesa-26.2.4）**：B1 聚合窗（新 env `RUSTICL_FLUSH_WINDOW=<events|ms>`），
   验收 = KGSLSUBMIT/token 计数 + **48-token 流全等回归**（async 乱码前科 R-031 两树皆垃圾——
   必须先修/绕深队列提交竞态，候选前置 = OPSYNC 已定位的 kgsl 提交竞态，或窗口按 N 封顶）。
4. **判据模板**：S5 = decode 段 `KGSLSUBMIT 次数 == graph_compute 次数`（每整图 1）；
   中间里程碑 M1 = submits/token ≤64；M2 = 每图 ≤2 且 numcmds 长尾（12~32）消失；
   性能门 = ≥ MESA_FLUSH1 1.49 t/s（R-026:783）×2，终门 vs CPU bank 8.07 t/s。

---

## 4. 施工建议排序（便宜→贵）

1. **A1 归因探针**：不知道 487/token 从哪来，其余全是盲打。结论三选一：
   CPU 岛（→A2）/ 阻塞传输（→A3）/ fork 私有层（→B4）。
2. **A5 env 卫生检查**：进 run_mesa_matrix 预检清单，防调试读污染归因（E2E_WATCH 每节点一读 = 直接翻倍提交）。
3. **A2 slots CPU 岛批处理（案 C）**：若归因证实，单点省 ~200-400/token（现存量 ~8 成）；
   与 P-4 kSpecs 路由解耦，独立验收（t/s + token 全等）。
4. **B1 rusticl flush 聚合窗**：结构性兜底，把所有隐式 flush 摊还成窗口提交；
   排在 A
2 之后做，避免竞态变量叠加；风险 = clFlush 契约放宽 + 竞态未修。
5. **A3 阻塞传输事件化**：与 B1 二选一即可到 1/图（B1 覆盖 A3 场景）；A3 只补 B1 不管的散点。
6. **B4 FDBATCH 审计**：依赖 P0-1 fork 源码收编，仅在 E-归因指向 winsys 截短后排产。

---

## 5. 我未验证 / 存疑清单

1. **在役 lib ≠ 上游 tag**：在役 libRusticlOpenCL.so（md5 c82f84d8，PROVENANCE.md §1）是
   **fork 带 FD_* 探针/FDBATCH 层**且已 strip；§2 所有 rusticl 结论读自**上游 mesa-26.2.4 tag**
   （gitlab raw，经 WebFetch 摘要转述，非逐字全文）。fork 的 FDBATCH 实现、是否额外插 flush
   未读源码（P0-1 未收编）。`flush_submit_list`/`submit_queue` 引自仓内补丁 P11，
   但**补丁≠构建树最终态**（chroot /root/mesa-26.2.4 无 .git，可能另有手工改动，R-025 在案）。
2. **487/token 归因未实测**：CPU 岛往返占比、阻塞传输占比、驱动内部 auto-flush（ring 压力/
   softpin deferred submit 触发时机）均为推断，freedreno translate 内部是否还有
   隐式 flush 点（如 BO 创建/map、memory_barrier）未逐一读码。
3. **numcmds=2 的确切构成**（preamble+user IB？还是每次 flush 只录到 1 launch≈2 IB）未见原始
   trace 复查（日志在 _probe/mesa_legs/p1_e2e/matrix_1026_quiet/，本轮未解析 .err）。
4. **worker/signal 线程细节**：WebFetch 摘要级证据，`Queue::flush` 全文、`create_and_queue`
   全文、`flush_events` 全文未逐字过目；api/queue.rs 中 clEnqueueNDRangeKernel 本体在
   api/kernel.rs（未 fetch，推断与 memory.rs 同走 create_and_queue）。
5. **kgsl 深队列丢 kernel 的根因**（OCL:9751 注释 vs kgsl winsys 哪一层丢）未定位——P-3 合并度
   的安全上限（B1 窗口大小 N）依赖此结论。
6. `sync_with_other_backends` 在 35B 实际运行时的设备数（若 CPU 岛以第二个 OpenCL
   设备形态出现则 OCL:8621 不成立）未验证；本次按单 GPU 设备推断。
7. R-026 的 submits=23394 是否含 prefill 全部提交、prefill/decode 分摊比例未知——
   487/token 是把总量摊到 48 token 的粗算。
