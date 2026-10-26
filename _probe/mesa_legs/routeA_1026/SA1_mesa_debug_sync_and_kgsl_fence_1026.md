# SA-1 只读回报 · MESA_DEBUG=sync 解析链复核 + kgsl fence/完成通路图 + P3 落点建议

生成：2026-10-26 18:4x（Asia/Shanghai）。纪律自证：全程只读 —— 未跑任何 git 命令、未碰 adb、未在 DGX/本机做任何写入/编译/安装；DGX 侧全部经 `ssh jianzengliang@<redacted-tailscale> "sudo -n cat|grep|sed -n|ls|find|md5sum|readelf|tar -cf -"` 读取 root 属主文件，外传用 `sudo tar` 到本机 `/tmp/audit_mesa/` 后本地加行号（未写入任何被审计文件）。

**主源树**：`/opt/trixie-cl/root/mesa-26.2.4`（下文所有 `file:line` 均指此树；本机 `/tmp/audit_mesa/` 下副本 md5 与 chroot 逐文件一致，见 §0.3）。

**任务书勘误（先入账）**：kgsl 层在 `src/freedreno/drm/kgsl/`（**不是** `src/freedreno/pipe/kgsl/`；后者在本树不存在：`ls: 无法访问 '.../src/freedreno/pipe/kgsl/': 没有那个文件或目录`）。该目录**无 kgsl_fence.c / kgsl_batch.c**，实际文件 = `kgsl_bo.c(295) kgsl_device.c(46) kgsl_pipe.c(227) kgsl_priv.h(57) kgsl_ringbuffer_sp.c(138) kgsl_ringbuffer_sp.c.orig(124)`；「batch/wait 循环」的通用层在 `src/freedreno/drm/freedreno_ringbuffer_sp.c(871) / freedreno_pipe.c / freedreno_priv.h / freedreno_drmif.h`。

---

## 0. 机检背书（读了什么、身份对不对）

### 0.1 构建配置 = release/ndebug（任务书前提成立）

```
build-cl/meson-info/intro-buildoptions.json → "name": "buildtype" / "value": "release"
build-cl/meson-info/intro-buildoptions.json → "name": "b_ndebug"  / "value": "true"
build-cl/meson-info/intro-buildoptions.json → "name": "gallium-rusticl" / "value": true
build-cl/build.ninja: rustc 实参 = "-C debug-assertions=no"×9, "-C opt-level=3"×9
```

### 0.2 在役/交付 artifact 与源树的对应关系

| 物 | md5 | 机检 |
|---|---|---|
| 路 A 交付件（830 上 `$R/opt/mesa-cl/lib/aarch64-linux-gnu/`） | `8de7d05fa40611fc8d66d67fda8b580c` | `/home/jianzengliang/mesa_routeA_1026/lib/libRusticlOpenCL.so.1.0.0` 实测 = 该值；`strings` 内含 **`RUSTICL_DEBUG`**（含字面 `no_variants`/`program`/`perfspam`/`validate`/`no_reuse_context` + `"Unknown RUSTICL_DEBUG flag found: "`）与 **`RUSTICL_FEATURES`**；**全库无 `RUSTICL_DEBUG` 第二解析点、无任何 `sync_every_event` 字样** |
| 同件 pristine（未 patchelf） | `aaedc2c1a46b0d043a59951abba45caf` | 与 `third_party/mesa-kgsl/PROVENANCE.md`/`_probe/moe_probe/routeA_README_1026.md` 备案一致 |
| chroot 现产物（diag0030 态） | `33cc4a0068b6c1f5e9990b09167b9bf5`，Build ID `fbf6d8d5b6c21b549b06a914150c770f37d48da7` | `strings` 同样含 `RUSTICL_DEBUG…Unknown RUSTICL_DEBUG flag found:` |
| chroot `core/platform.rs` | `1b3c05a86608b1860dd1d8aca1e5bea3`，mtime **10月16** | ⇒ **路 A 两颗 lib 的 platform.rs 解析面 = 本文引用的原样源码** |

### 0.3 树内 fork/诊断改动的存在性（不影响本文引用行号，但必须入账）

- `core/platform.rs` **无 .orig**、mtime 10-16 ⇒ 未被 fork 动过。
- `core/device.rs` 有 `.orig`（0001 子群补丁在位）；`core/kernel.rs:1823` 有 RSARG eprintln 残留（继承 `e4_working_state_1026.md` §1，本次未复量）。
- `kgsl_ringbuffer_sp.c` 仍处 **0030 已应用态**（mtime 10-26 17:40）；`diff -u .orig 现件` 唯一差异 = `[TongYi-Lite 0030]` 迁移块（现件 :63-75）。
- kgsl/rusticl 侧**既有 fprintf 诊断已是背书态**：`kgsl_pipe.c:36` `KGSLWAIT`、`kgsl_device.c:21` `KGSLDEV`、`kgsl_ringbuffer_sp.c:104/107` `KGSLSUBMIT`（`.orig` 里同样存在，非 0030 引入）。

---

## 1. 任务 A —— `MESA_DEBUG=sync` 解析链全链复核

### A-0 结论（一句话）

**解析开关的那个 env 不是 `MESA_DEBUG`，是 `RUSTICL_DEBUG`。本树全部 Rust 代码里不存在任何读取 `MESA_DEBUG` 的地方（tree-wide 实测 0 命中）。因此 `MESA_DEBUG=sync` 在路 A 束上永不生效，与导出方式无关 ⇒ E1「MESA_DEBUG=sync 未生效」不能用于任何关于 worker 粒度/合并假设的判定（E1 判废的判词应改写：不是"该 env 是否被解析待查"，而是"env 名从根上就错了"）。**

### A-1 输入 env / getenv 调用点 / 编译排除

声明（`core/platform.rs`）：

```
65:pub struct PlatformDebug {
75:    pub sync_every_event: bool,
77:}
101:static mut PLATFORM_DBG: PlatformDebug = PlatformDebug {
111:    sync_every_event: false,
113:};
```

解析入口 + 唯一 getenv 点（Rust `std::env::var`）：

```
119:fn load_env() {
121:    let debug = unsafe { &mut *addr_of_mut!(PLATFORM_DBG) };
122:    if let Ok(debug_flags) = env::var("RUSTICL_DEBUG") {
123:        for flag in debug_flags.split(',') {
124:            match flag {
134:                "sync" => debug.sync_every_event = true,
136:                "" => (),
137:                _ => eprintln!("Unknown RUSTICL_DEBUG flag found: {}", flag),
139:        }
```
同函数其余 env：`142: debug.max_grid_size = env::var("RUSTICL_MAX_WORK_GROUPS")`、`149: if let Ok(feature_flags) = env::var("RUSTICL_FEATURES")`。**platform.rs 内 `env::var` 只有这 3 处，无一处 `MESA_DEBUG`。**

调用链（`load_env` 的唯一驱动者）：

```
core/platform.rs:285:    pub fn init_once() {
core/platform.rs:286:        PLATFORM_ENV_ONCE.call_once(load_env);
core/platform.rs:289:        PLATFORM_ONCE.call_once(|| unsafe { PLATFORM.init() });
api/platform.rs:64:#[cl_entrypoint(clGetPlatformIDs)]      → api/platform.rs:81:    Platform::init_once();
```
（tree-wide `grep -rn "init_once"` 命中仅 `api/platform.rs:81`、`api/platform.rs:126`（`#[test]` 内）、`core/platform.rs:285` ⇒ 首次 `clGetPlatformIDs` 必然先于任何 `dbg()` 消费。）

`dbg()` 读取端：

```
core/platform.rs:181:    pub fn dbg() -> &'static PlatformDebug {
core/platform.rs:182:        debug_assert!(PLATFORM_ENV_ONCE.is_completed());
core/platform.rs:183:        unsafe { &*addr_of!(PLATFORM_DBG) };
```

**编译排除判定**：`load_env`/`match` 分支上**没有任何** `cfg(feature)`、`cfg!(debug_assertions)`、`#[cfg]`、`#[cfg_attr]` 门（platform.rs 内 `cfg(` 命中 = 0；`debug_assert` 命中仅 167/176/182/187 四处，且 `debug_assert!` 在 `-C debug-assertions=no`（§0.1 实证）下是 no-op，不会反向"关掉"解析）。⇒ **`buildtype=release -Db_ndebug=true` 不使 `sync` 分支失效**；binary 级背书 = `strings` 在交付 lib 内直接看到 `RUSTICL_DEBUGno_variantsprogramUnknown RUSTICL_DEBUG flag found: `（字符串常量未被折叠掉 ⇒ 分支活着）。

反证（MESA_DEBUG 的真实语义，纯 C 侧日志开关，与 rusticl debug 结构体零关系）：

```
src/util/log.c:205:      const char *env = os_get_option("MESA_DEBUG");
src/util/log.c:206:      bool silent = env && strstr(env, "silent") != NULL;
src/util/log.c:217:      debug = env && !silent;          /* #else（NDEBUG 即 release）分支 */
src/util/os_misc.c:228:os_get_option_internal(const char *name, bool use_secure_getenv)
src/util/os_misc.c:231:   if (use_secure_getenv) {
src/util/os_misc.c:233:      opt = secure_getenv(name);
src/util/os_misc.c:237:   } else {
src/util/os_misc.c:238:      opt = getenv(name);
src/util/os_misc.c:240:#if DETECT_OS_ANDROID
src/util/os_misc.c:242:      opt = os_get_android_option(name);
```
`os_get_option()` → `os_get_option_internal(name, false)`（`os_misc.c:251-254`）⇒ **普通 `getenv`，不用 `secure_getenv`**（setuid/hardened 无关）。
Android property 兜底（`os_misc.c:240-244`，键名 `debug.mesa.sync` 之类）**在路 A 的 glibc trixie 构建里被 `DETECT_OS_ANDROID` 编译排除** ⇒ MESA_DEBUG 只能走真 env。

tree-wide 反证（远程 `grep -rln "MESA_DEBUG" src/` 与 `grep -rn 'env::var("MESA_DEBUG")' --include=*.rs`）：
```
rusticl/ 目录内 MESA_DEBUG 命中 = 0 行
全部 *.rs 内 MESA_DEBUG 命中 = 0 行
```

### A-2 `sync_every_event` 的全部消费点 + 前置条件

tree-wide 只有 **1 个消费点**（`grep -rn sync_every_event src/`：`platform.rs:75/111/134` + `queue.rs:487`）：

```
core/queue.rs:424:                        debug_assert!(flushed.is_empty());
core/queue.rs:426:                        let new_events = match rx_t.try_recv() {
core/queue.rs:442:                        let new_events = QueueEvents::new(new_events);
core/queue.rs:443:                        for e in new_events {
core/queue.rs:453:                                let dep_err = if dep.is_user() || !e.has_same_queue_as(dep) {
core/queue.rs:463:                            if last_err < 0 {
core/queue.rs:465:                                e.set_user_status(last_err);
core/queue.rs:466:                                continue;
core/queue.rs:470:                            let (err, e) = e.call(&mut ctx);
core/queue.rs:471:                            last_err = err;
core/queue.rs:472:                            if last_err < 0 {
core/queue.rs:473:                                continue;
core/queue.rs:477:                            if e.is_user() {
core/queue.rs:481:                                last_err = flush_events(&mut flushed, &ctx, &tx_q2);
core/queue.rs:487:                            } else if Platform::dbg().sync_every_event {
core/queue.rs:488:                                flushed.push(e);
core/queue.rs:489:                                last_err = flush_events(&mut flushed, &ctx, &tx_q2);
core/queue.rs:490:                            } else {
core/queue.rs:491:                                flushed.push(e);
core/queue.rs:492:                            }
core/queue.rs:495:                        let flush_err = flush_events(&mut flushed, &ctx, &tx_q2);
```
⇒ 语义确认 = **「每非 user 事件后立刻 `flush_events` → `pipe.flush`」**，且 :495 每轮批尾再 flush 一次。

消费的前置条件（全部实测，无隐藏开关）：
1. `Platform::dbg()` 必须先于 `load_env`？—— 否，`dbg()` 的 `debug_assert!` 在 release 是 no-op；实际由 `api/platform.rs:81` 的 `init_once` 保证先跑 `load_env`。
2. `e.is_user()==false`（`:477`）：user event 走另一支（本来也会 flush），不受本开关影响。
3. `last_err >= 0`（`:463-466`、`:472-473` 两处 `continue` 会跳过本开关分支）：只要之前某事件出错，本开关对该事件不起作用。
4. `flush_events` 内 `if !evs.is_empty()`（`:344`）才有动作。
5. **无第二个必要条件**：不存在"还要别的 env/feature 同时打开"的形态。

关键限定（写死，防止 E1 复判误读）：`flush_events` 的 `pipe.flush()` 只是**前端 flush**，不等于出栈 ioctl：
```
core/queue.rs:339:fn flush_events(
core/queue.rs:344:    if !evs.is_empty() {
core/queue.rs:345:        let fence = pipe.flush();
core/queue.rs:346:        if pipe.device_reset_status() != pipe_reset_status::PIPE_NO_RESET {
core/queue.rs:354:            send.send((fence, evs)).unwrap();
core/mesa/pipe/context.rs:642:    pub fn flush(&self) -> PipeFence {
core/mesa/pipe/context.rs:645:            self.pipe.as_ref().flush.unwrap()(self.pipe.as_ptr(), &mut fence, 0);
```
`flags=0` ⇒ 不请求 `PIPE_FLUSH_FENCE_FD`，于是 freedreno/drm 层仍可合并（`freedreno_ringbuffer_sp.c:381: if (!use_fence_fd && !has_shared && should_defer(submit)) {` → `:382:      DEBUG_MSG("defer: %u", submit->fence);`，`should_defer` 阈值见 `:314 nr_bos>30`、`:322 deferred_cmds>128`），真正 ioctl 只在 `pipe->funcs->flush`（`kgsl_pipe.c:169 .flush = fd_pipe_sp_flush`）里发生。
另有一条**fence 复用**旁路：`src/gallium/drivers/freedreno/freedreno_context.c:701:   pctx->flush = fd_context_flush;`，其体内
```
freedreno_context.c:90:   if (ctx->last_fence) {
freedreno_context.c:91:      fd_pipe_fence_ref(&fence, ctx->last_fence);
freedreno_context.c:93:      goto out;
```
⇒ 「无新渲染的 flush」返回的是**上一个 fence**（不产生新 submit）。sync 模式下每个事件都刚 `e.call()` 过，通常会有新 batch，但这条是判读"每次 flush 是否真的对应一次 ioctl"时必须知道的口子。

### A-3 路 A 束真机形态下 `setenv→生效` 的完整条件（复判 E1 用）

`RUSTICL_DEBUG=sync` 要真正生效，以下 **6 条同时成立**（逐条给判据）：

1. **变量名必须是 `RUSTICL_DEBUG`**（A-1）。`MESA_DEBUG=sync` 的直接后果 = 走 `log.c:205-217` 只把 mesa_log 的"是否打印"打开（副作用：release 下 `mesa_loge/mesa_logw` 更容易可见），对提交/flush 行为**零影响**。
2. **必须被 `getenv` 看见**：`env::var` 与 `os_get_option` 都读真 env（`os_misc.c:238`），路 A 的 glibc 构建**没有** property 兜底（`os_misc.c:240` 被 `DETECT_OS_ANDROID` 排除）。⇒ 不导出 = 不可见。
3. **必须在 `clGetPlatformIDs` 之前就在环境里**（`api/platform.rs:81` → `platform.rs:286` `Once`）；进程内后期 `setenv` 无效（`Once` 只跑一次）。路 A 由 `ld-linux --library-path` 起 `minicpm_e2e`，`minicpm_e2e` 自身**不含任何 setenv 面**（`strings /opt/trixie-cl/root/routeA/stage2/minicpm_e2e | grep -E "MESA_DEBUG|RUSTICL|OCL_ICD|GGML_OPENCL"` = **0 命中**），所以 env 只能来自启动行/脚本 export。
4. **解析到的字符串必须是逗号分隔的确切 token**：`platform.rs:123 split(',')`，`"sync"` 精确匹配（`"Sync"`、`"sync "` 都会掉进 `:137` 未知分支并打 `Unknown RUSTICL_DEBUG flag found: `）。
5. **加载的必须是这颗 lib**（`OpenCL driver: 26.2.4` 验收 + md5 `8de7d05f…`，别让 `$R/bin` 影子或 `OCL_ICD_VENDORS` 指错）。
6. 事件流里**没有先前错误**（A-2 前置 3）。

**"adb shell 单行里同行赋值（不 export），Rust `std::env::var` 能否看到？"**
⇒ **能**。`VAR=val cmd args…` 这种前缀赋值是 POSIX/dash 的「为紧随其后的 utility 设置环境后 exec」语义，与 `export` 后 exec 对子进程完全等价 —— 它本来就必须"传下去"才有意义。所以 `adb shell "MESA_DEBUG=sync <loader> … minicpm_e2e"` 中，minicpm_e2e 及其加载的 lib 都会看到该变量。⇒ **E1 的失效不能归因于"同行赋值未导出"**；归因应是 A-0 的 env 名错误。（未核：本 harness 的 adb 转发层是否对整串再加一层 `sh -c` 包装 —— 这只影响 `VAR=val1 X=y val2 cmd` 这种"赋值后再接赋值/管道"的畸形写法；正规 `VAR=val cmd` 形态在 shell 层等价性上无争议，但**真机腿仍应以 §5 的阳性对照来实证**，不靠推理。）
⇒ 真正要防的坑是另一种：`sh -c "FOO=bar"`（只赋值不接命令）或 `FOO=bar; cmd`（分号后是独立语句）—— 那才是"没进 env"。

**给主线的复跑写法（零改动、可判读）**
```sh
# 阳性对照（先跑，证明 env 真进了 lib 并被 platform.rs:122 解析）：
RUSTICL_DEBUG=__tyl_probe__ ...   # 期望 err 出现 "Unknown RUSTICL_DEBUG flag found: __tyl_probe__"（platform.rs:137）
# 实验腿：
RUSTICL_DEBUG=sync ...
# 反证腿（可选）：MESA_DEBUG=sync ...   # 期望 KGSLSUBMIT 计数与 async 基线逐位相同（证明它本来就不动提交）
```
判据（比 E1 原设计正确的那个）：sync 生效时**不是** `KGSLSUBMIT` 行数线性变化，而应是
- `flush_events→pipe.flush` 次数 ≈ 事件数（Rust 侧，需 P3-C 打印，见 §4），且
- **单次 ioctl 的"共享同一 fence 的事件数"分布显著趋近 1**（P3-A/P3-C 配对，见 §4）。
（未核：`FD_DBG_INORDER/FD_DBG_NOGROW` 的解析点与语义 —— `FD_DBG(category)` 宏在 `src/gallium/drivers/freedreno/freedreno_util.h:94` 已引用，本次未追其 env 解析处，不影响本节结论。）

---

## 2. 任务 B —— kgsl fence/完成通路图（行级）

### 2.1 全链（自 Rusticl 到 KMD ioctl，每跳带 file:line）

```
core/queue.rs:345      let fence = pipe.flush();                        ← 一次 flush 一个 fence
core/queue.rs:354      send.send((fence, evs)).unwrap();                 ← (fence, Box<[events]>) 成对投递
core/mesa/pipe/context.rs:645  self.pipe.as_ref().flush.unwrap()(self.pipe.as_ptr(), &mut fence, 0);
  → gallium: freedreno_context.c:701  pctx->flush = fd_context_flush;
      freedreno_context.c:90-93   ctx->last_fence 复用旁路（无新渲染时不产生 submit）
      freedreno_context.c:97/108/111  fd_pipe_fence_ref(&fence, batch->fence); batch->needs_flush = true; fd_batch_flush(batch);
  → drm: freedreno_ringbuffer_sp.c:329  fd_submit_sp_flush(...)
      :350  list_addtail(&fd_submit_ref(submit)->node, &dev->deferred_submits);
      :352-353  if (!dev->deferred_submits_fence) dev->deferred_submits_fence = fd_fence_new(submit->pipe, use_fence_fd);
      :355  struct fd_fence *out_fence = fd_fence_ref(dev->deferred_submits_fence);   ← ★整批共享同一个 fd_fence
      :213  out_fence->ufence = submit->fence;            （fd_submit_sp_flush_prep，后到的 defer 会覆盖 ufence）
      :381  if (!use_fence_fd && !has_shared && should_defer(submit)) → 合并
      :267-305  flush_deferred_submits(): list_replace(...) + :292 struct util_queue_fence *fence = &fd_submit->out_fence->ready;
                :296-305 走 submit_queue 线程或同步执行 fd_submit_sp_flush_execute
      :239  fd_submit->flush_submit_list(&fd_submit->submit_list);     ← 绑定到 kgsl 的实现
  → kgsl: kgsl_ringbuffer_sp.c:25  flush_submit_list()
      :35-38  nr_cmds 累加；:42-56 组 cmds[]（gpuaddr/size/id，来自 ring_bo->iova）
      :92-101 kgsl_gpu_command req（.context_id = kgsl_pipe->queue_id, .numcmds = cmd_idx）
      :103-105 既有诊断 KGSLSUBMIT cmd[i] gpuaddr/size
      :106  int ret = kgsl_pipe_safe_ioctl(pipe->dev->fd, IOCTL_KGSL_GPU_COMMAND, &req);
      :107-108 既有诊断 KGSLSUBMIT ioctl ret/errno/timestamp/ctx/numcmds
      :115  fd_submit->out_fence->kfence = req.timestamp;               ← ★kfence 唯一赋值点（全树）
      :117-125 若 use_fence_fd 才 timestamp_to_fd()（IOCTL_KGSL_TIMESTAMP_EVENT，:17）
  → wait 侧（signal 线程）：
core/queue.rs:521      if fence.wait() {
core/mesa/pipe/fence.rs:68-70  pub fn wait(&self) -> bool { self.screen.fence_finish(self.fence.as_ptr()) }
core/mesa/pipe/screen.rs:538-545  self.screen().fence_finish.unwrap()(self.pipe(), ptr::null_mut(), fence, OS_TIMEOUT_INFINITE as u64)
  → freedreno_screen.c:1142  pscreen->fence_finish = fd_pipe_fence_finish;
  → freedreno_fence.c:127  fd_pipe_fence_finish(...)
      :136  if (!fence_flush(pctx, fence, timeout))  return false;
      :72   fd_fence_flush(fence->fence);    → freedreno_pipe.c:291-292 fd_pipe_flush + util_queue_fence_wait(&f->ready)
      :139-140 if (fence->last_fence) return fd_pipe_fence_finish(pscreen, pctx, fence->last_fence, timeout);   ← ★fence 链
      :145-148 use_fence_fd 时 sync_wait(fence->fence->fence_fd, timeout/1000000)（rusticl 路 A 不走：use_fence_fd=false）
      :151  if (fd_pipe_wait_timeout(fence->pipe, fence->fence, timeout)) return false;
  → freedreno_pipe.c:175 fd_pipe_wait_timeout()
      :178  if (!fd_fence_after(fence->ufence, pipe->control->fence)) return 0;   ← ★GPU 写的内存快速道
      :181  if (!timeout) return -ETIMEDOUT;
      :184  fd_pipe_flush(pipe, fence->ufence);                                   （= kgsl_pipe.c:169 .flush = fd_pipe_sp_flush）
      :186  return pipe->funcs->wait(pipe, fence, timeout);
  → kgsl_pipe.c:118 kgsl_pipe_wait()
      :121  return wait_timestamp_safe(pipe->dev->fd, kgsl_pipe->queue_id, fence->kfence, timeout);   ← ★kfence 唯一消费点（全树）
  → kgsl_pipe.c:22 wait_timestamp_safe()
      :28-32 struct kgsl_device_waittimestamp_ctxtid wait = {.context_id, .timestamp, .timeout};
      :35  int ret = kgsl_pipe_safe_ioctl(fd, IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID, &wait);
      :36-37 既有诊断 KGSLWAIT（仅 ret 非 0 时打）
```
ioctl/结构定义（同一树的本地头，`kgsl_priv.h:10 #include "../../vulkan/msm_kgsl.h"`）：
```
msm_kgsl.h:586 struct kgsl_device_waittimestamp_ctxtid {
msm_kgsl.h:592 #define IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID \
msm_kgsl.h:593 	_IOW(KGSL_IOC_TYPE, 0x7, struct kgsl_device_waittimestamp_ctxtid)
msm_kgsl.h:1552 struct kgsl_gpu_command {
msm_kgsl.h:1567 #define IOCTL_KGSL_GPU_COMMAND \
msm_kgsl.h:1568 	_IOWR(KGSL_IOC_TYPE, 0x4A, struct kgsl_gpu_command)
msm_kgsl.h:886 #define IOCTL_KGSL_TIMESTAMP_EVENT \
```

### 2.2 「timestamp 如何变成"完成"判定」

- **没有任何 sysfs / last-timestamp 轮询**：完成判定 = **一次阻塞 ioctl** `IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID`（`kgsl_pipe.c:35`），由 KMD 在 `context_id=queue_id` 的 `last_timestamp ≥ kfence` 时返回 0。
- **不做任何"读回时间戳再比较"**：`kgsl_pipe.c:102-103` 显式拒绝通用时间戳查询 ——
  ```
  102:   case FD_TIMESTAMP:
  103:      return -1;
  ```
  ⇒ 连 `fd_pipe_get_param(FD_TIMESTAMP)` 这条路都不存在（与 msm winsys 不同）。`kgsl_pipe_get_param` 其余 case 只回 dev_id/gmem/chip_id/优先级（:75-94），`FD_MAX_FREQ` 亦 `return -1`（:101，注释 :96-100 说明"KGSL timestamp 无法换算成时间"）。
- **第二条完成判定 = GPU 写进 CPU 映射内存的 ufence**：`freedreno_pipe.c:178` 用的 `pipe->control->fence` 是一块 `FD_BO_CACHED_COHERENT | _FD_BO_NOSYNC` 的 CPU-mapped BO（`freedreno_pipe.c:63-66`，初始化 `:71 pipe->control->fence = 0;`），由 `fd_pipe_emit_fence` 在每个 submit 尾部埋 `CP_EVENT_WRITE/CP_EVENT_WRITE7 (CACHE_FLUSH_TS)` 让 **GPU 自己写**：
  ```
  freedreno_pipe.c:192:   uint32_t fence = ++pipe->last_fence;
  freedreno_pipe.c:205/209: OUT_PKT7(ring, CP_EVENT_WRITE, 4) / OUT_PKT3(ring, CP_EVENT_WRITE, 3)
  freedreno_pipe.c:206/211: OUT_RELOC(ring, control_ptr(pipe, fence));   /* ADDR_LO/HI */
  freedreno_drmif.h:64-74: fd_fence_before(a,b){return (int32_t)(a-b)<0;} / fd_fence_after(a,b){return (int32_t)(a-b)>0;}
  ```
  这条内存道还被 BO 生命周期复用（`freedreno_bo.c:767: if (fd_fence_before(f->pipe->control->fence, f->ufence)) continue;`）⇒ **同一条"GPU 自报完成"通道同时决定"BO 可回收"**。

### 2.3 wait 循环：轮询间隔 / 超时 / 失败分支（实证）

```
kgsl_pipe.c:10:   do {
kgsl_pipe.c:11:      ret = ioctl(fd, request, arg);
kgsl_pipe.c:12:   } while (ret == -1 && (errno == EINTR || errno == EAGAIN));
kgsl_pipe.c:34:   while (true) {
kgsl_pipe.c:35:      int ret = kgsl_pipe_safe_ioctl(fd, IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID, &wait);
kgsl_pipe.c:36:      if (ret) fprintf(stderr, "KGSLWAIT ctx=%u ts=%u timeout=%d ret=%d errno=%s\n", ...);
kgsl_pipe.c:39:      if (ret == -1 && (errno == EINTR || errno == EAGAIN)) {
kgsl_pipe.c:43:         timeout_ms -= (current_time - start_time) / 1000000;
kgsl_pipe.c:44:         if (timeout_ms <= 0) {
kgsl_pipe.c:45:            errno = ETIME;
kgsl_pipe.c:46:            return -1;
kgsl_pipe.c:51:      } else {
kgsl_pipe.c:52:         return ret;
```
- **轮询间隔 = 0（无 sleep、无 backoff）**：阻塞式 ctxtid ioctl 单发，只有 EINTR/EAGAIN 才重入并把剩余 timeout 扣回去；`FD_KGSL_USLEEP_US` 在本树**不存在**（`grep` 未核项，但 kgsl 目录内无任何 sleep）。
- **timeout 由上层给定 = 无限**：`core/mesa/pipe/screen.rs:544 OS_TIMEOUT_INFINITE as u64` → `freedreno_fence.c:151` 原样透传 → `freedreno_pipe.c:171 fd_pipe_wait(...)  return fd_pipe_wait_timeout(pipe, fence, ~0)` → `kgsl_pipe.c:121`。**即 `timeout_ms` 是 `(int64_t)~0ULL`，永不走 :44 的 ETIME 分支**（除非 KMD 自己返回非 0）。
- **失败分支只有一个**：ioctl 返回非 0 → `kgsl_pipe.c:52 return ret` → `freedreno_fence.c:151-152 return false` → `core/queue.rs:521 if fence.wait()` 走 else：
  ```
  core/queue.rs:525:                            evs.for_each(|e| e.set_user_status(CL_OUT_OF_RESOURCES));
  ```
  ⇒ **唯一"失败"表现 = 整批事件被判 `CL_OUT_OF_RESOURCES`**；不存在"部分事件失败/内容校验失败"的分支。
- 复位检查是**另一条独立通道**，只在 flush 时看一眼，与 wait 无关：`core/queue.rs:346 if pipe.device_reset_status() != pipe_reset_status::PIPE_NO_RESET` → `kgsl_pipe.c:142 kgsl_get_prop(..., KGSL_PROP_GPU_RESET_STAT, ...)`。它在 `pipe.flush()` 之后立刻采样 —— **GPU 稍后才复位则完全漏检**（这是结构性口子，不是推测：调用点在 flush 之后、fence 之前）。

### 2.4 「批次被腐蚀但 GPU 跑到 timestamp」在此层能否被察觉 —— **实证：不能（0 处校验）**

穷举 kgsl + 通用 sp 层在「提交→完成」路径上的全部 CPU 侧判定点：

| # | 判定 | 位置 | 能否发现 IB 内容腐蚀 |
|---|---|---|---|
| 1 | ioctl 返回码 | `kgsl_ringbuffer_sp.c:106/110` | 否（只表示 KMD 接受命令） |
| 2 | `kfence = req.timestamp` | `kgsl_ringbuffer_sp.c:115` | 否（无条件赋值，不校验） |
| 3 | ufence 内存道 | `freedreno_pipe.c:178` | **否**（读的是 GPU 自报值；EVENT_WRITE 被腐蚀→只是不掉快速道，不会报错） |
| 4 | KMD timestamp 到没到 | `kgsl_pipe.c:121/35` | **否**（"跑到 timestamp"本身就是判定，内容与它无关） |
| 5 | 复位状态 | `kgsl_pipe.c:142`（经 `core/queue.rs:346`） | 仅在**恰好已复位**时；且采样点在 flush 后/fence 前 ⇒ 事后复位漏检 |
| 6 | 提交顺序断言 | `freedreno_ringbuffer_sp.c:242 assert(fd_fence_before(pipe->last_submit_fence, fd_submit->base.fence));` | **本 build 下被编译掉**（b_ndebug → NDEBUG，`assert` no-op） |
| 7 | fence 链 DEBUG | `freedreno_ringbuffer_sp.c:59 DEBUG_MSG("merged %u submits", cmd_idx);` | **常量折叠掉**：`freedreno_priv.h:477 #define enable_debug 0 /* TODO make dynamic */`，`freedreno_priv.h:486-491 DEBUG_MSG` 只在 `if (enable_debug)` 下展开 ⇒ release 里既不打也**不占运行时** |
| 8 | Rust 侧 debug_assert | `core/queue.rs:424`、`core/event.rs:204 debug_assert_eq!(state.status, CL_SUBMITTED as cl_int);` | **被编译掉**（`-C debug-assertions=no`，§0.1 实测） |
| 9 | TC 复位兜底断言 | `freedreno_context.c:133-134 if (FD_DBG(ABORT)) assert(...)` | 依赖 `FD_DBG(ABORT)` env + assert 仍被编译掉 |

⇒ **任务书预期成立**：该层「腐蚀批次」与「正确批次」在 CPU 侧**完全不可区分**；能观察到的只有"到没到 timestamp / ioctl 返回码 / 复位位"。唯一残留的间接信号是 3（GPU 自报 ufence）与 4（KMD timestamp）**不一致**：若某批 IB 被腐蚀到没执行尾部 `CP_EVENT_WRITE`，则 control->fence 不推进，但 KMD timestamp 照样推进 ⇒ 表现为"每次都掉进 kgsl ioctl（慢），但 wait 仍返回 0"。⇒ **这一"不一致"本身就是 E4-P3 想抓的东西**，必须新增打印才能观测（见 §4）。

### 2.5 「整批事件共享一个 pipe fence、fence 成功即整批 signal」在 kgsl KMD 路径上的对应代码（确认成立）

- 一个 fence 被整批共享：`freedreno_ringbuffer_sp.c:352-355`（`deferred_submits_fence` 建一次、所有被合并的 submit 共用）+ `:359 out_fence->use_fence_fd = true;`（唯一"升级"路径）+ `:225 fd_submit->out_fence = fd_fence_ref(out_fence);`。
- 一次 ioctl 可同时携带**多个 submit / 多个 fence 的活**：`kgsl_ringbuffer_sp.c:42 foreach_submit_safe`、`:58 if (submit == last_submit(submit_list))` + `:77-78 list_del(&submit->node); fd_submit_del(submit);`（非末位 submit 在 ioctl **之前**就被丢弃，其 `out_fence` 引用在 `freedreno_ringbuffer_sp.c:451-452` 释放）⇒ **被合并批次的"完成"完全由末位 submit 的单个 `kfence` 代言**。
- fence 成功 ⇒ 整批 signal（Rust 侧）：
  ```
  core/queue.rs:519:                        let evs = events.iter();
  core/queue.rs:521:                        if fence.wait() {
  core/queue.rs:522:                            evs.for_each(|e| e.signal());
  core/queue.rs:526:                            evs.for_each(|e| e.set_user_status(CL_OUT_OF_RESOURCES));
  core/event.rs:200:    pub(super) fn signal(&self) {
  core/event.rs:208:        self.set_status(state, CL_RUNNING as cl_int);
  core/event.rs:209:        self.set_status(self.state(), CL_COMPLETE as cl_int);
  ```
  ⇒ **无逐事件完成判定**：`fence.wait()` 的一次布尔返回值决定 N 个事件齐步 `CL_COMPLETE`。`core/event.rs:212-222 pub fn wait(&self)`（应用 `clWaitForEvents`/`clFinish` 的落点）也只是等 condvar 上的 status，不接触任何 GPU/KMD 事实。

---

## 3. 通路图（一页版）

```
 每事件/每批                 一次 flush = 一个 fence                  一次 ioctl = 一个 kfence
┌────────────────┐   pipe.flush    ┌──────────────────────┐  ioctl   ┌───────────────────────────┐
│ queue.rs:470   │ ──────────────► │ queue.rs:345/354     │ ───────► │ kgsl_ringbuffer_sp.c:106  │
│  e.call(ctx)   │                 │  (fence, evs) → tx_q2│          │  IOCTL_KGSL_GPU_COMMAND   │
│ queue.rs:487   │ sync_every_event│  = 1 pipe fence/batch│          │  :115 out_fence->kfence=  │
│  push+flush    │                 └──────────────────────┘          │      req.timestamp        │
└────────────────┘                                                   └─────────────┬─────────────┘
                                                                                   │ 同一 fd_fence 指针
┌─────────────────────── signal 线程 queue.rs:519-527 ────────────────────────────┘
│ fence.wait() → screen.rs:538 fence_finish(OS_TIMEOUT_INFINITE)
│   → freedreno_fence.c:136 fence_flush（:72 fd_fence_flush→util_queue_fence_wait）
│   → freedreno_fence.c:151 fd_pipe_wait_timeout
│        ├─ freedreno_pipe.c:178  【GPU 写的 control->fence】→ return 0（免 ioctl）
│        ├─ freedreno_pipe.c:184  fd_pipe_flush → kgsl_pipe.c:169 fd_pipe_sp_flush（把 defer 的 push 进 KMD）
│        └─ freedreno_pipe.c:186 → kgsl_pipe.c:118/121 → wait_timestamp_safe
│              └─ kgsl_pipe.c:35  IOCTL_KGSL_DEVICE_WAITTIMESTAMP_CTXTID(context_id=queue_id, ts=kfence)  ← 完成=KMD timestamp
│   true → evs.for_each(signal)   /   false → evs.for_each(set_user_status(CL_OUT_OF_RESOURCES))
└────────────────────────────────────────────────────────────────────────────────────────────────
```

---

## 4. P3 探针落点建议（只建议，不改；`TYL_E4=1` 门控；一律 `fprintf(stderr)`）

### 4.0 三条硬约束（本次实证）

1. **禁用 `DEBUG_MSG/INFO_MSG`**：`src/freedreno/drm/freedreno_priv.h:477 #define enable_debug 0 /* TODO make dynamic */` + `:486-491` ⇒ 编译期常量折叠，release 下永远不会打。`ERROR_MSG`（`freedreno_priv.h:496-499`）无条件走 `mesa_loge` ⇒ **不可门控，别用它做探针**。`INFO_MSG` 依赖 `fd_dbg()`（`freedreno_device.c:247-250` 实为 `debug_get_option_libgl()`；**该符号定义处未核**，libdrm/头文件里 grep 不到）。
2. **禁用 `assert`/`debug_assert`**：`-C debug-assertions=no`、`-Db_ndebug=true` 已实证（§0.1）。
3. **门控写法**：C 侧 `static int tyl_e4 = -1; if (tyl_e4 < 0) tyl_e4 = getenv("TYL_E4") ? 1 : 0; if (tyl_e4) fprintf(stderr, ...);`；Rust 侧用 `eprintln!`（与既有 `KGSLSUBMIT` 同 stderr；注意 `KGSLSUBMIT` 每 cmd 一行、q0a0f.err 已 78MB，**新探针务必只打配对汇总行**，并考虑 `TYL_E4=2` 再放开逐 cmd）。

### 4.1 五个落点（最少改动集）

| ID | file:line（插桩位置） | 打什么 | 为什么是这里 |
|---|---|---|---|
| **P3-A（必做）** | `src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c:115` **之后**（`fd_submit->out_fence->kfence = req.timestamp;` 与 `:117 if  (fd_submit->out_fence->use_fence_fd) {` 之间） | `TYL_E4 FENCE fence=%p kfence=%u ts=%u numcmds=%u nsubmit=%u ctx=%u ret=%d`，其中 `fence=(void*)fd_submit->out_fence`、`nsubmit` = 进函数时（`:35` 的 `foreach_submit` 里）顺手累加的 `nr_submits` | 这是 **fence↔timestamp 的唯一绑定点**；在此打可保证「timestamp 已被 KMD 写回（:106 之后）」且「尚未被 :117-125 分支扰动」；同时给出**本次 ioctl 合并了几个 submit / 几条 IB**（`nsubmit` 是本函数目前没有、但一行就能得到的量） |
| **P3-B（必做）** | `src/gallium/frontends/rusticl/core/queue.rs:345` 与 `:354` 之间 | `TYL_E4 FLUSH seq=%u fence=%p nev=%d`（`fence` 取 `fence.fence.as_ptr()`——`queue.rs` 与 `fence.rs` 同 crate，`PipeFence.fence` 字段可见；`nev = evs.len()`，放在 `:353 let evs = evs.drain(..).collect();` 之后） | 这是**批量事件数**的唯一权威点：`flush_events` 是「一次 pipe.flush ↔ 一个 fence ↔ N 个事件」的交汇口。有了 `fence=%p` 就能与 P3-A 的 `%p` **跨语言精确配对**（`fd_fence_new` 的堆指针一路透传到 `fd_submit->out_fence`，见 `freedreno_pipe.c:227`、`freedreno_ringbuffer_sp.c:355`） |
| **P3-C（必做）** | `src/gallium/frontends/rusticl/core/queue.rs:519-527`（`:519 let evs = events.iter();` 前打一次，`:521 if fence.wait()` 改成先 `let ok = fence.wait();` 再打，随后 `if ok`） | `TYL_E4 WAIT seq=%u fence=%p nev=%zu ok=%d`（两次打印：入队时 + wait 返回时，用同一 `fence=%p` 关联） | 这是「整批共享一个 fence、fence 成功即整批 signal」的**唯一判定点**（`event.rs:200-209` 无条件齐步 COMPLETE）。此处打印 = 直接给出任务书要的「最终 wait 结果」，并顺带抓 L-C/E1 复判里"sync 是否真的把 nev 压到 1" |
| **P3-D（强烈建议）** | `src/freedreno/drm/freedreno_pipe.c:178` **之前**（`fd_pipe_wait_timeout` 入口） | `TYL_E4 FASTPATH fence=%p kfence=%u ufence=%u ctrl=%u hit=%d`，`hit = !fd_fence_after(fence->ufence, pipe->control->fence)` | 全链**唯一一条"不经 KMD 的完成判定"**（§2.2）。只有在这里打，才能区分「KMD 说完成」与「GPU 自报完成」；若出现 `hit=1` 而对应 P3-A 的批次曾疑似腐蚀 ⇒ R3 直接升格。改动面 = 1 个 if，零行为扰动（读 `pipe->control->fence` 是 volatile 读） |
| **P3-E（建议，服务于 P2/0030 线）** | `src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c:69-75`（0030 块内）与 `:77-78`（`list_del`/`fd_submit_del`）之前 | 逐条被丢弃的 deferred submit：`TYL_E4 DROP fence=%p nr_bos=%u nr_cmds=%u ring_iova=%llx`，`nr_bos = to_fd_submit_sp(submit)->nr_bos` | 0030 判决腿（0.70→0.15）说明 BO 生命周期与腐蚀强相关；此打点给出「哪次 ioctl 丢弃了带 N 个 BO 的 submit」= **腐蚀窗口**的直接观测，且与 P3-A 的 `fence=%p` 同键 |

### 4.2 为什么不需要在 `kgsl_pipe_wait` / `wait_timestamp_safe` 新增加点

`kgsl_pipe.c:36-37` 的既有 `KGSLWAIT` **只在 `ret` 非 0 时打** ⇒ 现网 err 里看不到"成功 wait"。两种处置（都够用）：
- 最小：**不动它**，改由 P3-C（Rust 侧 `ok=%d`）给 wait 结果 + P3-D 给是否走 ioctl；P3-D 的 `hit=0` 即隐含"这次确实进 KMD 等了"。
- 若主线要 KMD 级时间戳：把 `:36` 的 `if (ret)` 改为 `if (tyl_e4 || ret)`，补打 `elapsed_us`（`os_time_get_nano()`，`start_time` 已在 `:27` 备好）。**注意**这会动既有诊断行的格式，影子库对拍时要在台账标注。

### 4.3 配对与判读配方（落点定了就能直接出的表）

以 `fence=%p` 为唯一 join key，三张表拼一条链：
```
TYL_E4 FLUSH seq,fence,nev     (queue.rs:354 前)
TYL_E4 FENCE fence,kfence,numcmds,nsubmit,ret   (kgsl_ringbuffer_sp.c:115 后)
TYL_E4 FASTPATH fence,kfence,ufence,ctrl,hit     (freedreno_pipe.c:178 前)
TYL_E4 WAIT fence,nev,ok       (queue.rs:521 前后)
```
预期正常形态：`1 个 FENCE : nsubmit 个 FLUSH : nev_total 个事件`，且 `WAIT.ok=1 ⇔ (FASTPATH.hit=1 ∨ KMD ret=0)`。
**异常形态 = P3 的靶**：同一 `fence` 上 `WAIT.ok=1` 而 `FASTPATH.hit=0` 且 `FENCE.retcmd` 对应批次疑似腐蚀 ⇒ 「腐蚀批次被 KMD 判完成」= R3 升格；反之若 `ok=1` 且 `hit=1` 但 `nev>1` 且其中部分事件的输出被判错 ⇒ 「整批单 fence 代言」的失配面（`freedreno_ringbuffer_sp.c:352-355` + `queue.rs:521-522`）。

---

## 5. 未核清单（明确标注，不作为结论使用）

1. **未核**：本 harness 的 adb 转发是否对整串再加一层 `sh -c`；仅影响畸形写法（`VAR=v1 X=v2 cmd` / `VAR=v; cmd`），正规 `VAR=val cmd` 的 env 传递性无需依赖此条。→ 以 `RUSTICL_DEBUG=__tyl_probe__` 阳性对照实证替代推理。
2. **未核**：`debug_get_option_libgl()` 的定义处（决定 `INFO_MSG`/`FD_DBG()` 是否真由某个 env 驱动）；`/opt/trixie-cl/usr/include/libdrm/` 与树内均 grep 不到该符号，但 build 用的是 `-I/usr/include/libdrm`（chroot 内），本次未继续追。不影响 §1/§2 任何结论。
3. **未核**：`fd_mesa_debug` 的解析点与 `FD_DBG_INORDER/NOGROW/ABORT` 语义（`freedreno_util.h:94 #define FD_DBG(category) unlikely(fd_mesa_debug &FD_DBG_##category)` 已引用，解析处未读）。
4. **未核**：`fd_submit_sp_flush_execute`（`freedreno_ringbuffer_sp.c:233-248`）与 `fd_device_threaded_submit`（`freedreno_priv.h:266-270`）在**本 build 的实际取值**：`kgsl_device.c:36 util_queue_init(&dev->submit_queue, "sq", 8, 1, 0, NULL)` 已实证 ⇒ 线程化提交为真、`fd_submit_sp_flush_execute` 跑在 `sq` 线程（非调用线程）；但 `flush_mtx/flush_cnd` 与 `last_submit_fence` 的可见性时序未做线程级复核。
5. **未核**：`fd_pipe_emit_fence` 生成的 `CP_EVENT_WRITE(CACHE_FLUSH_TS)` 在 kgsl `KGSL_CMDBATCH_SUBMIT_IB_LIST` + `KGSL_CONTEXT_PREAMBLE|NO_GMEM_ALLOC|SAVE_GMEM`（`kgsl_pipe.c:208-212`）组合下是否**确实**由 GPU 落到 `control_mem`（无独立实测）；P3-D 一旦落点，即可顺带证伪/证实这条内存道是否常为 0（若恒 0，则 §2.2 的"快速道"实际从不命中，`freedreno_bo.c:767` 的 BO 回收判据也恒不成立 —— 那将是一条独立的新线索）。
6. **未核**：`third_party/mesa-kgsl/PROVENANCE.md` 记的在役 bionic 件 `c82f84d8…` 与本次交付件 `8de7d05f…` 的解析面差异（禁 adb，未读设备侧 lib）。对"路 A"无影响（路 A 用后者）。

---

## 6. 给主线的三条"改变下一步动作"的结论（优先级序）

1. **E1 复判改令**：L-C 背书库对照腿的 env 必须换成 **`RUSTICL_DEBUG=sync`**（`MESA_DEBUG=sync` 永不动作，`core/platform.rs:122` 是唯一 getenv 点）；并**先跑阳性对照** `RUSTICL_DEBUG=__tyl_probe__`（期望 `Unknown RUSTICL_DEBUG flag found: __tyl_probe__`）。同时**修正 E1 判据**：sync 生效的观测面是「每 fence 的事件数趋近 1」，不是 `KGSLSUBMIT` 行数（提交合并在 drm/kgsl 层，`freedreno_ringbuffer_sp.c:381`）。同行赋值不是失效原因（§A-3）。
2. **P3 必落 P3-A/P3-B/P3-C 三点**（kgsl_ringbuffer_sp.c:115 后 / queue.rs:345-354 / queue.rs:519-527），以 `fence=%p` 为 join key；再加 **P3-D（freedreno_pipe.c:178 前）** 才能把「KMD timestamp 完成」与「GPU 自报 ufence 完成」分开 —— 这是 P3 判据能否成立的关键，缺它则 R3 升降无法裁决。
3. **探针写法铁律**：`DEBUG_MSG` 在 release 被常量折叠（`freedreno_priv.h:477 #define enable_debug 0`）、`assert/debug_assert` 被 ndebug/no-debug-assertions 清掉（`freedreno_ringbuffer_sp.c:242`、`core/queue.rs:424`、`core/event.rs:204`）⇒ E4 全部观测**只能新增 `fprintf(stderr)`**，且新行务必 `TYL_E4` 门控（既有 `KGSLSUBMIT` 逐 cmd 行已把 err 撑到 78MB，别再放大）。
