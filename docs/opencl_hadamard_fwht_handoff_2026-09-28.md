# OpenCL FWHT（prism.hadamard）实现交接 — 2026-09-28 深夜

## 症状（真机 25053RT47C / Adreno 825，Bonsai-2 27B PTQ1_0，OpenCL 后端）

- decode **16.5 s/token**（0.06 tok/s；基线 Vulkan 1.12 tok/s，慢 ~200×）。token 间隔精确 16.5s。
- 问"你好"答 **"Kotler's model: …"**——连贯但完全跑题 = **数值错但结构对**，非采样问题。

## 根因（已定案）

Bonsai-2 的 hadamard 是 **MUL_MAT 上的 hint**（`op_params[1] == GGML_HINT_SRC0_IS_HADAMARD`，
`src/llama-impl.h:71` 设置）。带 hint 的节点**不是矩阵乘**，语义 = `dst = FWHT_rows(src1)`；
真正的 hadamard 域权重 matmul 在图的其他节点消费该输出（`src/llama-context.cpp:61` 校验配对）。

- CPU/CUDA/Metal/BLAS/Vulkan 都实现了该语义；**OpenCL 完全无视 hint**，
  把它当普通 mul_mat 算 `rot[1024×1024 f32] × 激活` → 数值错（乱答）。
- 每 token ~400 个此类节点 × 1024×1024 f32 GEMV 慢启动 ≈ 12s+ → 慢的来源。
- 附带发现：真机残留 `test-backend-ops -b Vulkan0`（跑了 2h01m、96% CPU）已 kill -9（PID 7442）。

## 运行时契约（已从三处参考实现核实，一致）

`ggml/src/ggml-cpu/ops.cpp:12066 ggml_compute_forward_fwht_impl` 是 ground truth：

- `n = src1->ne[0]`（2 的幂；**模型恒为 1024**，block_size 分块由图层面 reshape 完成）
- `rows = ne11*ne12*ne13`，每行独立：先乘 `scale = 1/sqrt(n)`，再蝶形 `len=1..n/2`：
  `a[i]=u+v; a[i+len]=u−v`（**u−v 约定**；Vulkan fwht.comp shmem 变体与此一致——
  `other−val` 里 val 是自己、other 是伙伴，换算后即 u−v，勿再被绕进去）
- src1 = F32 或 F16，dst = F32；实现走连续内存（连惯性检查进 supports_op 门控）
- 显式符号（sign_values[28672]）在**加载期折进权重**，运行时无符号张量、无反向变体
- tbo 已有验收：`MUL_MAT_HADAMARD`（`tests/test-backend-ops.cpp:4637` + `test_fwht_signed:4693`——
  1024/5120/7 正是 Bonsai-2 形状）

## 实现清单（改 4 处，全部在 wt/spike-opencl）

1. **新内核** `ggml/src/ggml-opencl/kernels/fwht.cl`：
   `kernel_fwht_f32` + `kernel_fwht_f16`（f16 读 half→float）。
   一个 workgroup 处理一行：`local float l[4096]`（16KB，n≤4096 门控下安全），
   LSIZE=256，load×scale → 10 级蝶形（每级 barrier；线程 p=tid; p<n/2; p+=lsz，
   用位运算 `a = ((p>>log2len)<<(log2len+1)) + (p&(len-1))`）→ store。
   参数风格照 `kernels/abs.cl`：裸指针 + `ulong offset`（**字节偏移**，char* 加法）。
2. **`ggml/src/ggml-opencl/CMakeLists.txt`**：`GGML_OPENCL_KERNELS` 列表加 `fwht`
   （embed_kernel.py 自动嵌入，模式照 mul_mm_ptq1_0 那次）。
3. **`ggml-opencl.cpp`**：
   - struct 加 `cl_kernel kernel_fwht_f32, kernel_fwht_f16;`（~866 行区域）
   - 创建块（~3040 行 abs 的模式）：`build_program_from_source` + 2×clCreateKernel + release + `GGML_LOG_CONT(".")`
   - **`ggml_cl_mul_mat`（19119 行）函数最顶部**（在 src0->extra 断言**之前**，rot 张量可能没有 extra）：
     `if (ggml_get_op_params_i32(dst, 1) == GGML_HINT_SRC0_IS_HADAMARD) { ggml_cl_fwht(backend, src1, dst); return; }`
     helper 里只碰 src1/dst 的 extra->offset + view_offs，scale=1/sqrt(n)，global=n_rows×256
   - **`ggml_opencl_supports_op` MUL_MAT case（7770 行）case 体最顶部**加门控：
     hint 命中时 return `(src1 f32||f16) && dst f32 && n==2^k && n<=4096 && src1/dst 连续`；
     门控不过 → false → sched 自动落 CPU（正确，仅慢）
4. 注意：普通 mul_mat 的 op_params[1] 恒为 0，不会误触发 hint 分支。

## 验证闭环（顺序执行）

> **⚠️ 2026-09-29 实现注记（8cde426，本机）**：4 处改动已实现（fwht.cl /
> CMakeLists / struct+创建块 / mul_mat hint 分支 / supports_op 门控）。
> **第 3 步禁止照跑**：llama-cli 无 OOM 守卫，11GB 机全载 bonsai2 = 整机死机
> （AGENTS.md 死机案先例）。e2e 一律走**项目内 APK**（带 `[oom-guard]`）：
> 真机装新 APK 后在 App 内加载验证；若预检仍拒绝 bonsai2，该机型 e2e 不可行，
> 正确性以 tbo 全绿为准（MUL_MAT_HADAMARD 覆盖 1024/5120/7 全形状）。

> **✅ 2026-09-29 验证完成（本机 8cde426，真机 25053RT47C 经 5555 无线 adb）**：
>
> **两个 CLI 拦路虎（下次接手先看，否则 tbo 永远静默 0 测）：**
> 1. **设备名不是 `OpenCL0`，是 `GPUOpenCL`**（本 fork 注册名；`-b` 走 strcmp
>    精确匹配，写 `OpenCL0` → 后端被当"非目标"跳过，日志只字不提 fwht）。
>    正确：`test-backend-ops -b GPUOpenCL -o MUL_MAT_HADAMARD`。
> 2. **CLI 加载 opencl 需 `GGML_BACKEND_DL` 版 `.so`**：app 构建产物只导出
>    `ggml_backend_opencl_reg`，加载器 `load_backend()` 要的是 `ggml_backend_init`
>    （`GGML_BACKEND_DL_IMPL` 宏，`-DGGML_SHARED` 后加 `-DGGML_BACKEND_DL`）。
>    做法：从 `ninja -t commands` 抠出编译/链接命令，补宏重编
>    `ggml-opencl.cpp` → 链成 `libggml-opencl.so`，连同 **`libopencl_stub.so`**
>    （NEEDED，在 `build/app/intermediates/merged_native_libs/debug/.../arm64-v8a/`）
>    一起推 vkptq。缺 stub → dlopen 失败静默跳过。
>
> **结果**：
> - `-o MUL_MAT_HADAMARD -b GPUOpenCL`：**24/24 全绿**（含 test_fwht_signed
>   1024/5120/7 + 全 f32 FWHT 蝶形；8192/f16 走门控回落 CPU 属预期"not supported"）。
> - `-o MUL_MAT -b GPUOpenCL`：**1185/1185 全绿，FAIL=0**（PTQ1_0 GEMM/matvec 无回归）。
> - debug APK：包内 `libggml-opencl.so` 字符串验收 `kernel_fwht_f32/f16`=4、
>   `FWHT_rows` 源码在、`GGML_OPENCL_PTQ10_MM_N` 旋钮在 → `adb install -r` 成功。
>   FWHT 修复已交付真机 App，待用户 OpenCL 实测 bonsai2（守卫自动把关）。
> - 注：tbo 用 CLI 侧 `.so`，App 走静态注册（`ggml_backend_opencl_reg`），
>   同一份 ggml-opencl.cpp 源码，仅链接形态不同。

1. gradle 增量编译出 libggml-opencl.so（见上：CLI 测需 DL 版 + libopencl_stub.so 同推 vkptq）
2. `test-backend-ops -b GPUOpenCL -o MUL_MAT_HADAMARD` 全绿（含 test_fwht_signed 1024/5120/7）
3. ~~`llama-cli -m .../bonsai-2-27b-ternary-ptq1_0.gguf --device GPUOpenCL -ub 16 -st -p "你好"`~~
   **已废止（见上方注记：11GB 机死机风险）**。替代：真机 `adb install -r` 新 APK →
   App 内 OpenCL 加载 bonsai2（守卫自动把关）；或大内存设备（≥16GB）跑 llama-cli 记录 tok/s
4. 若速度仍差：再查 mul_mv_ptq1_0 在 K=17408 的表现（正确性已由 174/174 保证，纯性能问题）
5. 全量重打 APK（debug+release，AGENTS.md 协议：flutter assemble → intermediates 同步 → gradlew -x）→ `adb install -r`（debug 已装）

## 新增（2026-09-29）：Vulkan 正确但慢——留另起任务排查

> 用户实测：真机 **Vulkan** 后端跑 Bonsai-2，输出**正确**（Vulkan 路径 hadamard
> 折叠是通的，与 OpenCL"乱答"形成对照），但**速度也很慢**。本任务只交接总结，
> 排查在下一任务进行。

**已知/可对照：**

- 同设备 OpenCL：16.5 s/tk + 乱答（根因见本文，待实现 FWHT 修复）。
- 同设备 Vulkan：对答 + 慢 → 慢**不**来自 hadamard 折叠缺失，是另一线路。
- 设备 bf1552ef = 25053RT47C（Adreno 825）。AGENTS.md 8-04 基线（同机型 8 Elite）：
  Vulkan 8.60 / OpenCL 8.77 / CPU 4.33 tok/s（短 prompt，同一批模型）。
- 12GB 手机放不下 27B PTQ1_0（~17GB）：**先核实 Vulkan 实测时到底加载的
  哪个模型/量化**（4B 变体？），否则"慢/快"无参照。

**下一任务排查清单（建议顺序）：**

1. `adb logcat` 抓 `[handleLoadModel]`，逐项 diff 8-04 基线：`n_gpu_layers`、
   `n_ubatch`（GPU 应 512）、`flash_attn`、量化类型、sampler 链。
2. 记录 Vulkan 实测 tok/s（**prefill 与 decode 分开**报），对基线判断是"绝对慢"
   还是"机型/模型与基线不匹配"。
3. 怀疑点排序：
   - **flash_attn=DISABLED** → attention naive 路径，长 decode 慢（短 prompt 影响小）；
   - **n_gpu_layers 未全上 GPU** → 部分层落 CPU；
   - **Adreno 驱动/turnip fork 状态**（0.2.5 修过高通 driver bug，核实现时 APK
     是否带修复版库）；
   - **GEMM 内核选择**：量化类型决定 GEMM/GEMV 内核在 Adreno 825 的表现
     （PTQ1_0 批阈 GGML_OPENCL_PTQ10_MM_N 是 OpenCL 专属 env，Vulkan 另查 `mul_mat` 分支）；
   - 先排除"拿基线 4.33 tok/s 对照 27B/别的量化"的**参照错位**。
4. 若 config 全对纯慢：`test-backend-ops -b Vulkan0 -o MUL_MAT_HADAMARD`
   及 `-o MUL_MAT`/`MUL_MAT_PTQ1_0` 单算子计时，定位瓶颈算子。

## 修正（2026-09-29 日志分析）：「OpenCL 无视 hint → 数值错」结论被推翻

> 全部 26 个设备日志已拷至本机 `E:\Work\DgxSpark\TongYi-Lite\vkptq_logs\`（vkptq_logs.tgz），
> 以下结论以日志为据。设备已拔线。

**修正 1：hint 被无视在数值上无害。** `matmul(rot_hadamard, x) ≡ FWHT(x)`（数学等价；
`test_mul_mat_hadamard` 把 `a` 初始化成缩放过的 hadamard 矩阵，所以普通 matmul 也能过）。
`t_fwht_opencl.log` 24/24 绿、`t_mulmat_opencl.log` **1185/1185 全绿**
（含 ptq1_0 m=5120 n=512 k=17408 大 n）→ **OpenCL 单算子没有数值 bug**。
hint 无视的真实代价是**性能**：每 token ~400 次多余的 1024×1024 f32 GEMV + 400 次 launch。

**修正 2：OpenCL 全模型链路从未跑通，加载即卡死。** `oc_repro.log`（9-29 复现，
`--device GPUOpenCL -ngl 99 -ub 16 -c 2048`）：`adreno_drawctxt_wait` 挂 10+ 分钟、
进程 0% CPU（总 CPU 时间仅 21s）→ **GPU submit 永不完成**，不是慢 JIT（JIT 烧 CPU）。
此前没有任何一份 OpenCL 全模型 e2e 成功日志。

**修正 3：OpenCL 显存不足以全量 offload。** `ggml_opencl: global mem size: 5616 MB`、
`max mem alloc: 1024 MB`，模型 5807 MiB → 必然走 sched 拆图部分 offload。
tbo 单算子测试覆盖不到拆图/SoA repack 全图路径 → **app 侧 OpenCL 错答
（"Kotler's model"）的根因在拆图/加载路径，尚未定案**（需下次插线复现）。

**Vulkan 侧已定案（正确但慢）：**
- 乱码根因链：Turnip 大 n GEMM 错编（`t_ptq1_bign.log` ptq1_0 n≥64 ERR≈1.0 → **0/16**；
  `t_bign_appso.log`/`t_f16_bign2.log` f16 k=17408 n=512 也错 → 24/72）；
  **vendor 驱动 16/16 全绿**（`t_bign_vendor.log`）；
  **ndk-glslc 重建的 libggml-vulkan.so + `-ub 16` e2e 连贯**
  （`e2e_t_ub16_ndk.log` "We need answer user's simple question. Need final just number"）。
  → app（NDK r27 glslc 构建 + n_ubatch=16）正确，与用户实测吻合。
  注意：单靠 ub16 不够（`e2e_t_ub16.log` turnip 版同样乱），**换 shader 编译链是关键**。
- 慢的定量：generation 0.2~0.3 t/s（≈5s/token）；权重 5.7GB ÷ Adreno 825 ~50GB/s
  ≈ 9 t/s 理论带宽上限 → **45× 损耗全在每算子开销**（~700-900 算子/token × ~6ms/算子
  launch+同步）。Vulkan 已实现 FWHT 仍 0.2 t/s → hadamard 非主导因素。
  优化方向：减少每 token 算子数（算子融合/少同步），而非继续修单算子内核。

**下次插线复现清单（OpenCL 优先）：**
1. 重跑 oc_repro 同参数，确认加载卡死必现；试 `-ngl 32`（≤5616MB 可放下）对照——
   若小 offload 能跑，说明卡死在大 offload/拆图 repack 的 submit 上。
2. app 切 OpenCL 复现错答并抓 logcat（`[handleLoadModel]` + GGML/OpenCL 输出）。
3. CPU 后端同 prompt 记 tok/s，量化"不如 CPU"差距。

## 环境备忘

- 设备 bf1552ef = 25053RT47C（Adreno 825）；模型在 /storage/emulated/0/TongYiLite/models/
- App 侧最后一次加载（23:30）配置是 gpuBackend=**vulkan**（用户切过开关）；乱答样本来自更早的 OpenCL 跑
- v0.2.6 打包/推送已全部完成：886d302 已推 origin/spike/opencl-bonsai2-ptq1-gemm；
  main 上 AGENTS.md 备忘补丁 f5be232 已推。APK 在 wt/spike-opencl/build/app/outputs/flutter-apk/（验收全绿）
- adb 全路径：/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe（不在 PATH）
