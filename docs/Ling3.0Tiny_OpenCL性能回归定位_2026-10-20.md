# Ling 3.0 Tiny OpenCL/CPU 吞吐大跌 — 真机定位报告

日期：2026-10-20　设备：SM8750 / 8 Elite / Adreno 830 / Android 16 (SDK 36)
CL 驱动：V@0800.71　Shader Compiler：E031.47.18.49　App：0.3.4（与本机 release 构建 sha1 逐字节一致）
被测模型：`ling-3.0-tiny-q4_k_m`（4.5GB）与 `ling-3.0-tiny-q4_0`（4.4GB），两者均已缓存
架构：GGUF arch `bailingmoe3` — 层 0–2 dense attention + dense FFN；层 3+ MLA（`attn_q_a/q_b/kv_a_mqa/k_b/v_b`）；
　　　每层 KDA 线性注意力（`ssm_conv1d_q/k/v`、`ssm_a/beta/f_a/g_a/norm/dt`）；MoE 128 专家 top-8；vocab 157184

---

## 0. 一句话结论

**自研 batched MoE 内核在 App 里从未被派发，Q4_K_M 与 Q4_0 一律静默回落 dense-loop（每 token 约 550 次
逐专家 GEMV + 550 次 add_row），解码线程被 kernel 提交开销打满（227 ms 用户态 CPU/token，单线程），
实测 2.8–3.9 tok/s；而 10-15 之前 batched 在跑时同一台机是 8+ tok/s 档。**
拦截点是 `ggml-opencl.cpp:24733-24736` 的"预打包平面必须存在"检查（`seff/meff`/`q`/`d`），
该路径**一行日志都不打**，因此静态审计无法定案 —— 需要一次插桩构建（见第 6 节）。

---

## 1. 复现数据（真机实测，非推算）

同一 prompt（约 200 字中文写作请求），n_ctx=4096，OpenCL 后端，`n_gpu_layers=100`。

| 轮次 | 时间 | 模型 | token | 墙钟 | tok/s | 每 token 中位 |
|---|---|---|---|---|---|---|
| run1 | 12:12–12:13 | Q4_K_M | 237 | 64.2s | **3.69** | 264ms (P10 244 / P90 289) |
| run2 | 12:15–12:17 | Q4_K_M | 436 | 112.1s | **3.89** | 252ms (P10 224 / P90 284) |
| run3 | 12:35 | Q4_K_M | 63 | 15.9s | **3.97** | — |
| run4 | 12:35–12:37 | Q4_K_M | 447 | 124.6s | **3.59** | — |
| run5 | 12:48 | **Q4_0** | 102 | 36.7s | **2.78** | — |

对 8-04 基线（同机 Vulkan 8.60 / OpenCL 8.77 / CPU 4.33 tok/s）为 **-56% ~ -69%**，远超 ±10% 基准门容差。

**关键：Q4_0 不比 Q4_K 快（2.78 < 3.69）。** 若 Q4_0 真在走 batched，它应当显著更快 —— 与 catalog 里
把 Q4_0 标为「GPU 加速 / OpenCL batched MoE 通用内核」直接矛盾。

### 1.1 每 token 成本解剖（`/proc/<pid>/task/*/stat`，2s 采样）

```
每 token：墙钟 ~256ms，用户态 CPU 227ms   → 解码期间单核占用 ~89%
线程累计 CPU（解码 5 分钟窗口）：
  pool-9-thread-1 (JNI 解码线程)  utime 50.55s → 91.36s   stime 4.55s
  park.tongyilite                 14.52s
  1.raster                        10.42s
  AdrenoOsLib                      4.77s
  全 62 线程合计                   81.9s   ← 无隐藏消费者
空闲时 cpu_ticks = 0（排除空转 bug）
MemAvailable 7.28GB → 1986MB
```

**"没有任何 CPU 工作线程在忙"是决定性证据**：ggml-cpu 跑 550 次专家矩阵必然拉起线程池、出现多个忙线程。
实测只有一个 JNI 线程忙 → **专家矩阵在 GPU 上**，那 227ms 用户态 CPU 全部是**驱动侧 kernel 提交开销**。
`~llama_context` 复核：OpenCL compute buffer 322MB / **CPU compute buffer 46MB**（后者即 KDA/SSM CPU 孤岛）。

### 1.2 batched 探针：0 条

`vk_flags.conf` 注入 `GGML_OPENCL_MOE_KDBG=1`（日志串 `batched MoE dump: type=.. K=.. M=.. E=.. n_used=..`）
+ `GGML_OPENCL_MOE_TIME=1`，并确认已生效：

```
10-20 12:34:27.299 I/TongYiLite( 6346): vk flag applied: GGML_OPENCL_MOE_KDBG=1
10-20 12:34:27.299 I/TongYiLite( 6346): vk flag applied: GGML_OPENCL_MOE_TIME=1
```

该进程生成 447 + 102 token，`grep -ac "batched MoE" = 0`。**Q4_K 与 Q4_0 都是 0。**

### 1.3 加载期参数门（全部正常，无需怀疑 JNI）

```
n_gpu_layers = 100            model_params.devices pinned to GPUOpenCL
load_tensors: offloaded 25/25 layers to GPU      backend_ptrs.size() = 2
llama_context: n_ubatch = 512 (TONGYI_UBATCH 未改)
OpenCL compute buffer = 322.00 MiB / RS buffer = 19.27 MiB / CPU compute buffer = 46.02 MiB
ggml_opencl: using kernels optimized for Adreno
native subgroup size ... lws=1024 -> 64
零 kernel compile error，零 err=-11
[oom-guard] 预检：可用 7.28 GB，权重估算 4.49 GB，预检余量 256 MB，旁路=开
```

`offloaded 25/25` + MemAvailable 掉 5.3GB（不可回收的 GPU resident 拷贝）→ 4.4GB 专家权重确在 GPU，
`MUL_MAT_ID` 由 OpenCL 承接（若被甩到 CPU，该计数会跌且权重会变成可回收页缓存）。

---

## 2. 拦截点：batched 的静默 `return false` 清单

`ggml_cl_mul_mat_id()` 的派发顺序（`ggml-opencl.cpp:29243-29257`）—— batched **本来就是先试**，
失败后**无日志**回落 dense-loop：

```c
static const bool batched_moe_enabled = [] { const char *e = getenv("GGML_OPENCL_BATCHED_MOE");
                                              return !e || e[0] != '0'; }();
if (moe_use_dense_loop(src0->type)) {
    if (batched_moe_enabled && ggml_cl_mul_mat_id_batched(backend, src0, src1, src2, dst)) return;
    ggml_cl_mul_mat_id_dense_loop(backend, src0, src1, src2, dst);   // ← 我们现在一直在这
    return;
}
```

`ggml_cl_mul_mat_id_batched()` 内所有可能静默失败的门（逐个核验结果）：

| 行 | 条件 | Ling Q4_K / Q4_0 判定 |
|---|---|---|
| :24681 | `src1->type==F32 && src2->type==I32` | **与准入 :10236-10237 同一套约定，一致**（我一度怀疑方向反了，已撤回） |
| :24694 | type ∈ {Q4_0, Q4_K, Q3_K} | 过 |
| :24733 | q4_0：`extra->q && ->d` | **未证实** ← 嫌疑 |
| :24734 | q4_K：`q && d && dm && s` | **未证实** ← 嫌疑 |
| :24735 | q4_K：`seff && meff` | **未证实** ← 头号嫌疑 |
| :24748 | `use_adreno_moe_kernels()`：gen∈{A8X,X1E,X2E} + 名字含 `ffn`&`exps` + `ne01%32` | 过（"830" 命中 A8X 名单 :300-305；张量名 69/69 命中；ne01 512/1536） |
| :24751 | `src0`/`src1` 连续 | 过 |
| :24773 | **非 q3_K 且 `src0->view_src != nullptr` → `return false`** | Ling 不走 slot bank → 不触发（见 3.2） |
| :24778 | `K%32==0 && M%128==0` | 过（1536/512 全中） |
| :24779 | q4_K/q3_K 加 `K%256==0` | 过（1536%256=0、512%256=0） |
| :24780 | `n_used*n_tok ≤ 2^20` | 过（解码 8×1） |

`seff/meff` 由 `set_tensor` 在 `:12389` 建立，条件 `Kc%256==0 && Mc%2==0 && !extra->seff`，
外层还套着 `:12359` 的四连对齐守卫（`q_layer/d_layer/dm_layer/s_layer % alignment`）——
**任一不过则整段跳过，之后 batched 永久失败且无人知晓。**

同族故障已被作者自己记录在案（`:15259-15262`）：

> DEFAULT OFF: sched-copied GPU copies of slot tensors **lack the pre-packed se planes** that the
> batched MoE kernels require (**set_tensor creates them on the original tensor only**) -> SIGSEGV
> in `ggml_cl_mul_mat_id_batched`.

即"平面只存在于原张量、调度器复制出的副本没有"是本函数已知失效模式。Ling 是单体 GGUF 不走 slot bank，
但 `ggml_backend_sched` pass-2 的张量复制同样能造成相同后果 —— 这就是唯一尚未闭合的一环。

---

## 3. 顺带定案的两个真缺陷（与本次同源，值得单独修）

### 3.1 `GGML_OPENCL_OFFLOAD_MMID` / `LLAMA_MOE_BANK_GPU` 是 split-MoE 的死路
`ggml_backend_opencl_device_offload_op`（:15265）默认 OFF；打开会 SIGSEGV（上面那段注释）。
正确路线 `LLAMA_MOE_BANK_GPU=1`（FGSVM 零拷贝 bank）作者标注"能跑但没调优（740 上 pmgmt 290ms/tok，
prefill 2×）"。**结论：35B-A3B 这类 `.experts` 分片模型目前没有可用的 GPU MoE 路线。**

### 3.2 自研 batched 的 slot 视图支持只补了一半
`:24767-24777`：q3_K 拿到了 `es_base = view_offs/slot_bpe` 的视图偏移处理，
**q4_0 / q4_K 留了一句硬 `return false`**（注释：reading the parent planes from slot 0 would silently
produce wrong results）。一旦对 Ling 这类模型启用 slot bank（或任何走视图的 MoE），
Q4_0/Q4_K 的 batched **永久不可用**。这是"batched 效率 vs dense-loop 慢"差距的又一处来源。

### 3.3 GPU MoE 覆盖面本身太窄（影响"各模式都该最优"这条要求）

| 量化 | GPU MoE 路径 | 备注 |
|---|---|---|
| Q4_0 | 自研 batched（:4125，`gemv_noshuffle_q4_0_f32.cl:471`）+ dense-loop | 三者最干净；留有 10-14「Ling q4_0 garbling bisect」记录（:9543） |
| Q4_K | 自研 batched（:4725，`gemv_noshuffle_q4_k_f32.cl:942`）+ dense-loop | 有已确认的 E031.47 驱动级 codegen 损坏，靠 `seff/meff` dodge 绕开 |
| Q3_K | 自研 batched **only**（:4749，`gemv_noshuffle_q3_k_f32.cl:146`） | 无 dense 回退；准入与派发两道门不一致时 **`GGML_ABORT` 直接崩**（:29267） |
| Q8_0 / Q5_K / Q6_K / Q2_K / IQ* / MXFP4 | **无** | `supports_op` 一律 false → 整个 MoE 在 CPU，「OpenCL」是假 GPU MoE |
| 厂商 `gemv_moe`/`gemm_moe`（q4_0/q8_0/mxfp4/q4_K） | 已损坏，默认禁用 | 定性为"输出 = 正确值 × 错误常量"；08:05 的 `SYSTEM_TOMBSTONE`（`test-backend-ops -b GPUOpenCL -o MUL_MAT_ID` SIGABRT）内存转储里可见 `kernel_gemv_moe_q4_k_f32_ns` |
| A6X / A7X / ADRENO_UNKNOWN | **自研 batched 完全不参与** | `use_adreno_moe_kernels` 显式排除（:9553-9558）→ 老 Adreno 上 MoE 只能 CPU |

---

## 4. 已排除项（都查过，别再查）

| 假设 | 判定 | 证据 |
|---|---|---|
| 内核编译失败 / `err=-11` | **排除** | 加载日志零 `kernel compile error`（含 17 个 MoE `_ns` 内核） |
| `n_ubatch` 被设错 | **排除** | 日志 `n_ubatch = 512`（GPU 档正确） |
| `GGML_VK_*` 四条 Vulkan workaround 污染 OpenCL | **排除** | `ggml-opencl.cpp` 中 `GGML_VK_` 出现 **0 次** |
| A7X lm_head→CPU 规则误伤 | **排除** | 需 `adreno_gen==A7X` + `src0->ne[1]>=32768`；本机是 A8X |
| i8mm/bf16 在本机 SIGILL | **排除** | `/proc/cpuinfo` Features 含 `i8mm bf16 asimddp`（implementer 0x51） |
| 空闲 CPU 空转 | **排除** | 空闲 `cpu_ticks=0` |
| MoE 整体掉 CPU | **排除** | 无 CPU 工作线程忙；`offloaded 25/25`；MemAvailable 掉 5.3GB（GPU resident） |
| Q4_K 被 `K%256` 门槛踢回 CPU | **排除** | Ling K=1536/512 全部 `%256==0`（该门槛真会踢的是 ffn=1408 这类形状） |
| slot bank 视图触发 :24773 | **排除（对 Ling）** | 加载日志无任何 slot bank/moe-ssd 行；`split_moe` 需 Dart 传 manifest（JNI :552-556），Ling 是单体 GGUF |
| Ling 模型未下载 | **排除（我曾判断错误并已向用户更正）** | 模型在 App 私有目录；`dumpsys diskstats` `com.dgxspark.tongyilite` Data = 42.17GB |
| 调试包 `-O0` 拖慢 | **排除** | 设备 APK 与本机 release 构建 sha1 一致 |

### 我自己撤回过的三条错误结论（留档，防再次误导）
1. "Ling 没下载" —— 只看了外部 models 目录。
2. "Q4_K 的 `K%256` 门槛把 MoE 踢回 CPU" —— Ling 形状全过。
3. "`src1/src2` 类型检查方向反了" + "`seff/meff` 缺失已定案" —— 前者与准入一致故撤回；
   后者降级为"头号嫌疑，需插桩证实"。另：`/data/local/tmp/test-backend-ops` 那次实验**无效**
   （`OCL_ICD_FILENAMES=` 导致 `Backend 1/1: CPU`，没拿到 OpenCL 平台），不作为证据。

---

## 5. 结构性问题（为什么这类回归防不住，也是用户"各模式都该最优"要求的真正障碍）

1. **`supports_op` 只判"能不能"，从不判"值不值"。** 所有"其实 GPU 更快/更慢"的例外都是手改的一行
   （A7X lm_head、prefill decline、SSM CPU 岛、dense-loop 形状门），且靠一个仍叫 `vk_flags.conf`
   的隐藏文件逐个 env 手工试 —— **JNI 侧对 OpenCL 设 0 个出厂默认 env**（Vulkan 侧有 4 个默认 + turnip）。
2. **零可观测性。** 卸载决策（哪些 op 留在 CPU）、batched/dense 的路径选择、七道静默 `return false`，
   全部无日志。这次定位耗时全部花在"从外部反推它走了哪条路"。
3. **基准矩阵里没有 MoE、也没有线性注意力模型**（基线是 Vulkan 8.60 / OpenCL 8.77 / CPU 4.33 的稠密模型），
   所以 10-13→10-16 这一串 MoE/SSM 大改**基准门从未触发**。这是回归能活到今天的原因。
4. **OOM 守卫过于乐观**：只按权重预检（4.49GB + 256MB 余量）、**不为 KV 与 compute buffer 预留**、
   `旁路=开` 直接放行。n_ctx=16384 那轮实测 `Mem: 131M free / Swap 7337M used`，09:49:03 被系统杀掉
   （`WINDOW DIED`、`fg TOP`、无 tombstone = 被杀非崩溃）。这正是"内存刚好够时反而最慢/直接死"的另一半原因。
5. **catalog 自相矛盾**：被标「GPU 加速 / OpenCL batched MoE 通用内核」的是 **Q4_0**，而 App 打「推荐」的
   是同样拿不到 batched 的 **Q4_K_M** —— 两个标签在当前代码下都不成立。

---

## 6. 下一步（唯一能定案的手段 + 修复清单）

### 6.1 定案：一次插桩构建（3 行，不动数值路径）
在 `ggml_cl_mul_mat_id_batched` 的七个 `return false` 各加一条 `GGML_LOG_INFO`（带 type/K/M/E/n_used
与失败的平面指针），一次加载 + 一条消息即可看到是哪道门。预计与 8.46 tok/s 的差距全部在此。

### 6.2 修复清单（按性价比）
1. **加载期自检 + 一行日志**：`set_tensor` 结束时报「Q4_K MoE `seff/meff` 已建/未建」+「N 个 op / 这些层将跑在 CPU」。
   把这次所有考古变成 App 日志里的两行。
2. **JNI 出厂 env 块**：按 `adreno_gen` 下发 OpenCL 侧推荐 env（对齐 Vulkan 侧已有的 4 默认 + turnip 做法），
   设置页给一个开关；终结"手写 `vk_flags.conf` 考古"。
3. **补齐 :24773 的 q4_0/q4_K 视图偏移**（照 q3_K 的 `es_base` 配方），使 slot bank 与 batched 不互斥。
4. **OOM 守卫补 KV + compute buffer 预算**，并让 `旁路=开` 时至少打 warning（现在它静默放行到 free=13M）。
5. **基准矩阵补一行 MoE + 线性注意力模型**（就用 Ling 3.0 Tiny），把这条纳入基准门；
   顺手修 catalog 两个标签。

### 6.3 立即可用的规避（不需要改代码）
- 当前**没有** env 级解药：`GGML_OPENCL_DENSE_MOE=0` 会把 MoE 整个丢 CPU（更慢）；
  `GGML_OPENCL_MUL_MAT_ID=1` 走厂商内核（数值损坏，且 08:05 的 abort 就是它）；
  `GGML_OPENCL_BATCHED_MOE=0` 是反方向（强制 dense-loop，已验证与现状同速 → 再次佐证 batched 本来就没在跑）。
- n_ctx 建议留在 4096（16K 会被系统杀），直到 6.2-④ 落地。
