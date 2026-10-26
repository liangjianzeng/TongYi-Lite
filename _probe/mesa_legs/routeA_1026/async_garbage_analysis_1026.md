# async 乱码根因分析与判别实验设计（routeA 1026）

战役：真 Mesa rusticl（Adreno 830 / fork 26.2.4）× ggml-opencl e2e。
现象：GGML_OPENCL_OPFLUSH 不设/0 → 输出乱码（"loom Chinhndeaticernity…"，leg-036 复现）；
同 bundle OPFLUSH=1 逐字节正确。async per-token 实测：1974 enqueue / 367 clWaitForEvents /
338 阻塞传输 / 81 KGSLSUBMIT（垫片计数）。RC=0，tok_s 与 OPFLUSH=1 相近。

DGX 侧全部为 ssh 只读命令（cat/grep/sed -n，sudo -n 仅用于读取 root 属主文件，
路径 /opt/trixie-cl/root/mesa-26.2.4，未做任何写/删/编译）。

---

## 1. ggml-opencl（OCL）侧事实

### 1.1 graph 内 kernel 全部是"无事件、无 flush"纯异步入队
E:\Work\DgxSpark\TongYi-Lite\third_party\llama.cpp\ggml\src\ggml-opencl\ggml-opencl.cpp:1356-1438（enqueue_ndrange_kernel 包装）:
```cpp
cl_int enq_err = clEnqueueNDRangeKernel(queue, kernel, work_dim, NULL, global_work_size, local_work_size, 0, NULL, NULL);
```
graph kernel 的 event=NULL、num_events_in_wait_list=0 → 节点间数据依赖完全寄托于
**单队列 in-order 提交序**。每 token 的 367 次 clWaitForEvents 几乎都挂在 ggml 自己的
小工具 op 上（prepack/sort 等，cpp:11856-13802 各处 `CL_CHECK(clWaitForEvents(1, &evt));`；
profiling 路径 cpp:1219；跨后端同步 cpp:8613/8635），不是 graph kernel。

### 1.2 "深队列丢 kernel" 注释上下文（±80 行已读全）
ggml-opencl.cpp:9750-9754（OPBATCH 注释）:
```cpp
// instead of every node. Ring-pressure bisect: 118586 submits were
// observed for 271390 enqueued ops — kernels go missing under deep
// enqueue on rusticl+kgsl. If batch-16/32 restores logits, the loss is
```
ggml-opencl.cpp:9758-9764（OPFLUSH 注释）:
```cpp
// in the soft queue / lost at depth on rusticl+kgsl" (fixed by flush,
// near-zero cost) from "in-order violated on hardware" (flush won't
// help; needs events or kgsl backend fix). 2026-10-19: OPSYNC=1 (full
```
要点：OPSYNC=1（每节点 clFinish）文本恢复健康 → 问题在**提交路径**而非 kernel 内部；
flush（提交不等）与 finish（等）谁能治，是既有实验只区分到"提交竞态"这一层。

### 1.3 noshuffle/GEMV 协议与 sgs>64 防线（RUSTICL define）
ggml-opencl.cpp:1804-1813（program build opts）:
```cpp
// protocol (slid<4 B load + subgroup broadcast + slid-indexed local
// reduce) silently corrupts when sgs > 64 because subgroups then span
// local y-groups (wrong B per k) and the slid-indexed reduce aliases.
```
kernels/gemv_noshuffle_q4_0_f32.cl:247-249:
```c
// [dspark 2026-10-20] rusticl-safe (GGML_OPENCL_RUSTICL) per-lane self-load
// dequant: no subgroup broadcast, no local reduce. One lane owns a row pair
// end-to-end (full K loop), reads B itself, writes dst directly.
```
kernels/gemv_noshuffle_q4_0_f32.cl:293-295 / 331：广播协议整体被
`#if defined(ADRENO_GPU) && !defined(GGML_OPENCL_RUSTICL)` 关掉，RUSTICL 下走 per-lane 全 K。
kernels/gemv_noshuffle_q4_k_f32.cl:383/537/640/899/1046 的 `barrier(CLK_LOCAL_MEM_FENCE)`
与 ggml-opencl.cpp:9718-9720 的 rms_norm `sum[]` per-lane local reduce：
```cpp
// indexes sum by native subgroup id / native lane id, and rusticl ignores
// the qcom reqd-subgroup-size attribute (nominal 64 != actual).
```
**协议假设分析（任务 1 结论）**：per-lane 全 K 协议、local+barrier reduce 全部是
**workgroup 内**协议，与"队列是否 flush/多深/有无 host 交错"无关 —— async 不改变
local memory 生命周期或 barrier 语义。被 async 破坏的唯一假设是：
**"生产者 kernel 的 global 写对后继 consumer kernel 可见"由单队列 in-order 硬件提交序保证**。
该保证在 rusticl 侧塌缩为"提交进同一条 ring 的顺序与内容不被篡改"（见 §2.3）。
另注意：这些协议假设 enqueue→execute 之间**没有对 kernel 对象/参数/BO 的破坏性复用**；
参数复用已被 args 快照排除（§2.2c），但 **BO 复用未排除**（§2.3a）。

---

## 2. rusticl worker 侧（DGX chroot，ssh 只读）

文件：/opt/trixie-cl/root/mesa-26.2.4/src/gallium/frontends/rusticl/{core/queue.rs, core/event.rs, api/event.rs, api/kernel.rs, core/kernel.rs}
与 /opt/trixie-cl/root/mesa-26.2.4/src/freedreno/drm/{kgsl/kgsl_ringbuffer_sp.c, msm/msm_ringbuffer_sp.c, freedreno_ringbuffer_sp.c, freedreno_ringbuffer.c}

### 2.1 软队列无上限、不丢命令
core/queue.rs:254-259：`QueueState { pending: Vec<Arc<Event>>, ... chan_in: mpsc::Sender<Vec<Arc<Event>>> }`。
pending 是无限增长的 Vec + mpsc 通道，**没有 ringbuffer 尺寸/批量上限 → 该层不丢命令**。
clFlush/clFinish 之前命令只是"未执行"，不是"丢失"。

### 2.2 worker/flush 锁协议与事件语义
- core/queue.rs:339-357 `flush_events`：批次尾才 `let fence = pipe.flush();` 然后把
  `(fence, evs)` 发给 signal 线程；core/queue.rs:495 一个接收批次处理完后统一 flush。
  worker 与 API 线程仅以 `state: Mutex<QueueState>` + 两个 mpsc 通道交接，
  Queue::flush 里显式 `drop(state)` 防死锁（core/queue.rs:540-575）。
- signal 线程 core/queue.rs:500-530：`if fence.wait() { evs.for_each(|e| e.signal()); }`
  —— **整批事件共享一个 pipe fence，fence 成功即整批 signal**。若某条 IB 内容已被篡改但
  GPU 仍"跑完"了 timestamp，全部事件照样 CL_COMPLETE → 静默（RC=0）的机制解释。
- core/event.rs:212-222 `wait()`：Condvar 1s 超时轮询 `status >= CL_RUNNING`，
  signal 走 set_status+notify（200-210）→ 无丢失唤醒结构缺陷。
- **clWaitForEvents 在未 flush 命令上的语义（任务 2 必查项）**：api/event.rs:93-116：
```rust
// find all queues we have to flush
for q in Event::deep_unflushed_queues(&evs) {
    q.flush(false)?;
```
然后 `e.wait()`。规范要求的 implicit flush 已实现，语义正确（低风险候选）。
- kernel 参数竞态已排除：api/kernel.rs:809-817 enqueue 即 `k.launch(...)`，
  core/kernel.rs:1678-1682 `let args = self.values.clone();`，且 1685-1686 注释：
```rust
// the painful part is, that host threads are allowed to modify the kernel object once it was
// enqueued, so return a closure with all req data included.
```
  → clSetKernelArg 在 API 线程改写同一 kernel 对象不影响已入队命令 → **参数复用竞态排除**。

### 2.3 kgsl 提交路径 = 真正的分叉点（最硬发现）
DGX 实测（ssh 只读）kgsl_ringbuffer_sp.c（与本地
E:\Work\DgxSpark\TongYi-Lite\third_party\mesa-kgsl\patches\0011-...patch 第 708-801 行 hunk 一致）：

(a) 合并路径提前释放中间 submit 的全部 BO 引用。kgsl_ringbuffer_sp.c:42-64（DGX live）：
```c
foreach_submit_safe (submit, submit_list) {
    ...
    list_del(&submit->node);
    fd_submit_del(submit);
```
`cmds[cmd_idx++]` 只填了 `.gpuaddr/.size/.id`（live:49-56），**全程无一次
`fd_submit_append_bo`**（grep 计数为 0），而 `IOCTL_KGSL_GPU_COMMAND` 在 live:92 才发生。
即：中间 submit 的 ring BO 引用（per-cmd `fd_bo_ref`，freedreno_ringbuffer_sp.c:504）与
其 attach 的全部 reloc/权重/激活 BO 引用，在 ioctl **之前**被 fd_submit_del→
fd_ringbuffer_del（freedreno_ringbuffer.c:26-42）丢弃；refcount 归零即回 bo-cache，
**同进程同 VA 可被 CPU 立即改写复用，而 GPU 正在执行这段 IB**。

(b) 对照组：上游 MSM 同一函数（msm_ringbuffer_sp.c:50-85，ssh 只读）在 fd_submit_del 前先转移引用：
```c
cmds[cmd_idx].submit_idx = fd_submit_append_bo(fd_submit, ring_bo);
...
// Now that the cmds/bos have been transfered over to the current submit,
// we can remove the deferred submit from the list and drop it's reference
```
KGSL 移植丢掉了这两步（ring_bo 迁移 + deferred bos 并入 last submit 表）。

(c) 合并何时发生（决定 async/OPFLUSH 分叉）：freedreno_ringbuffer_sp.c:329-395 `fd_submit_sp_flush`：
```c
if (!use_fence_fd && !has_shared && should_defer(submit)) {
    DEBUG_MSG("defer: %u", submit->fence);
```
should_defer（live:310-325）：`nr_bos > 30` 或 `dev->deferred_cmds > 128` 停止 defer。
deep 队列 → 每个 compute pass 一个 submit 被 defer、攒批后由 flush_deferred_submits
（live:258-307，其中 274-286 已把中间 submit 的 in_fence_fd accumulate 进 last ——
**in-fence 丢失不是危害，排除**）合并成一次 kgsl ioctl。
async：worker 大批次、pipe.flush 稀疏 → 每次 pipe flush 产生多个 submit → 深合并列表；
OPFLUSH=1：每节点 clFlush → worker 每事件一收一发 → pipe.flush/submit 近 1:1 →
`submit == last_submit` 先 break、fd_submit_del 走 flush_cleanup（ioctl 后、fence 后）→
提前释放路径不被触发。81 KGSLSUBMIT/token ÷ 1974 op ≈ 1 次 ioctl/24 条 IB，
与 should_defer 双阈值收敛出的合并深度吻合。

(d) 次要结构问题：live:40 `struct kgsl_command_object cmds[nr_cmds];` 为无上界 VLA
（MSM 对 bos 表有 4k 栈上界，此处没有）→ 超深队列有 worker/signal 线程栈溢出风险
（若发生应见 crash/RC≠0，与 RC=0 观察不完全相容，列为次要）。

---

## 3. 候选根因清单（排序 + 置信度）

| # | 根因假设 | 置信度 | 与观测相容性 |
|---|---|---|---|
| R1 | **kgsl flush_submit_list 合并路径提前 fd_submit_del（BO/ring 引用未迁移即丢）→ 在飞 IB/权重 BO 被 CPU 复用改写**（§2.3a/b/c） | **0.70** | 完美：仅深合并触发（async 有、OPFLUSH 无）；kernel-side KGSL 仍持 object 不 fault→RC=0；GPU 仍跑到 timestamp→整批 signal（§2.2）→ 无错误冒头；不增等待→tok_s≈OPFLUSH=1 |
| R2 | R1 的放大维度：defer/合并粒度本身（should_defer 阈值、每 ioctl 合并 IB 数）决定腐蚀率 | 0.55（依附 R1） | 解释 OPFLUSH 代价≈0（deferred 列表本就等下一次 flush 一起提交） |
| R3 | 整批单 fence → 被腐蚀批次仍"成功完成"，事件假 COMPLETE（掩盖 R1 的帮凶；独立成立需 fence/kfence 映射 bug） | 0.30（作为独立根因）| 解释乱码但 RC=0；若独立成立则 E4"单 clFinish"组也应乱码 |
| R4 | 内核内并发（local/barrier/subgroup sgs）在 async 下变化 | 0.20→建议降 0.10 | OPSYNC=1 健康（cpp:9762-9763）且 barrier 为 workgroup 内协
议，队列模式不改变其语义 |
| R5 | clSetKernelArg 与 worker 执行的参数竞态 | 0.05 | 已被 enqueue 时 args 快照排除（core/kernel.rs:1685 注释明示该风险已处理） |
| R6 | clWaitForEvents 对未 flush 命令语义缺陷（不 implicit flush / 早回） | 0.10 | api/event.rs:108-110 已实现 deep flush 后 wait |
| R7 | cmds[] VLA 栈溢出 / numcmds 超 KGSL 上限 | 0.10 | 应产生 ioctl 失败或 abort，与 RC=0 不相容 |

与 leg-036 观测总相容性：81 提交/token（深合并证据，R1 直接吻合）；乱码但 RC=0
（R1+R3 组合：篡改不 fault、假完成）；tok_s 与 OPFLUSH=1 相近（R1 无需额外等待即"修复"，
只是不再篡改，性能差本就来自提交合并而非 sync）。

---

## 4. 判别实验设计（只设计，不真机）

**E1 — worker 粒度归零（纯 env，零改动）**
`MESA_DEBUG=sync`（rusticl `sync_every_event`，core/platform.rs:134 `"sync" => debug.sync_every_event = true`）
+ OPFLUSH 不设。worker 每个事件后立刻 pipe.flush（core/queue.rs:487-490）→ 每 submit 单独出栈，
合并列表恒≈1。
预期：文本正确 ⇒ 危害在"批次合并/kgsl 提交"层（支持 R1/R2），并基本排除 R4（in-kernel；
此开关不动 kernel 执行内容）；仍乱码 ⇒ 危害在事件/fence 完成语义（升 R3、R6），
再叠加 `GGML_OPENCL_OPFLUSH=1` 对照组（应仍正确）。tok_s 崩掉属预期，只看正确性。

**E2 — flush 频率扫描（定阈值，证 R1/R2 的"合并深度"变量）**
`GGML_OPENCL_OPFLUSH ∈ {1,2,4,8,16,32,64,256,0}`（只 clFlush 不等待，cpp:9768-9771），
其余同 leg-036 bundle。垫片同时计数 KGSLSUBMIT/token 与（可加）每次
IOCTL_KGSL_GPU_COMMAND 的 numcmds。
预期：存在阈值 N*，N<N* 正确、N≥N* 乱码，且 KGSLSUBMIT/token 与 N 的比值即平均合并
IB 数；若"OPFLUSH 大 N 乱码 + 同 N 的 OPBATCH（带等待）正确" ⇒ 分叉变量是"CPU 是否被拖慢/
BO 是否在 ioctl 前归还"，直接支持 R1；若带等待同 N 也乱码 ⇒ 合并深度本身即可腐蚀（仍 R1，
但腐蚀对象是 deferred 期 reuse 而非 ioctl 前瞬间）。

---

## 6. 主线裁决（2026-10-26 17:4x，真机三连腿后追加）

- **E1 判废**：`MESA_DEBUG=sync` 在路 A 束上**未生效**（NPRED=8 腿 KGSLSUBMIT=3450 = async 线性插值
  2964+6×81 分毫不差，合并比未变；乱码依旧 health=0）。该 env 是否被本 build 的 platform.rs 解析待查
  （分析员引 core/platform.rs:134，但 DGX 树复核未做）。**E1 对 R1 不构成证伪。**
- **E2（部分）**：`GGML_OPENCL_OPFLUSH=32` NPRED=8 仍乱码（KGSLSUBMIT=4652）⇒ 阈值 N*<32，
  合并深度相关性存在但非二值开关 ⇒ 弱化 R2 的"单阈值"形态。
- **R1 证伪（0030 判决腿）**：按 MSM 版镜像补 `fd_submit_append_bo`（ring_bo + deferred bos 表迁移，
  补丁 `third_party/mesa-kgsl/patches/0030-kgsl-ringbuffer-sp-append-bo.patch`，chroot 增量重编
  libRusticlOpenCL=33cc4a00，$R/bin 影子加载，背书库 8de7d05f 未动）——async NPRED=16 腿**仍乱码**
  （health=0，"baserafeطق…"，KGSLSUBMIT=4098 不变）。**fd_submit_del 引用早丢不是（ sole ）根因**；
  R1 置信度 0.70→0.15（补丁保留在案，MSM 不对称是真实上游缺陷，值得独立提交上游）。
- **新主嫌 R8（ggml 侧，async 才暴露）**：OCL:15911 注释自证"thread_local staging is reused by the
  next wave"——`LLAMA_MOE_DRAIN_ASYNC` 默认 on 时 `clEnqueueWriteBuffer(CL_FALSE, src_host=thread_local)`
  返回后 CPU 立即复用 staging ⇒ 下一波覆写**未执行**的异步写源 ⇒ 专家权重静默错。与 leg-036
  write_blk=157 全 CL_TRUE 的表面矛盾（应走 CL_FALSE）= 归因洞，L1 腿（DRAIN_ASYNC=0/1 双腿对拍）优先。
- **背书无损**：diag 库撤除后 q0a0g 复跑 tok=e9b88e56 全等 + KGSLSUBMIT=135543 复现（双跑一致）。
