# Bonsai-2 Vulkan 调研：实现现状、机制原理与 Adreno 825 验证计划

> 日期：2026-09-27 · 性质：代码考古 + 兼容性风险分析（纯静态调研，未动设备）
> 关联文档：[`docs/vulkan_adreno825_fix_2026-09-26.md`](vulkan_adreno825_fix_2026-09-26.md)（Turnip 三药修复）
> ⚠️ **勘误（2026-09-27）**：初版把 **Bonsai（一代）** 的 dspark 草稿架构与 Q1_0 实测数据错安到 Bonsai-2 头上。
> **Bonsai 与 Bonsai-2 是两个不同的模型与架构族**，本版已严格分开（§1）。

## 0. 结论（TL;DR）

1. **Bonsai-2（PTQ1_0 / PQ2_0 / prism.hadamard tied output）在 vendored fork 树已有全后端实现**——CPU、CUDA、OpenCL、Vulkan 四路齐全。Vulkan 侧覆盖 dequant / matvec（f32、f16、q8_1-int）/ MMQ GEMM / matmul_id / get_rows 共 **32 处管线注册**。**缺口是「未在真机验证」，不是「未实现」**。
2. Adreno 825 / Turnip 上最大风险点：**FWHT（快速 Walsh-Hadamard）subgroup shuffle shader 不在 `NO_SUBGROUP` 门控内**——选择条件是 `subgroup_basic && subgroup_shuffle`，而三药修复只置 `subgroup_arithmetic=false`。Turnip gen8 已实锤错编 subgroup **算术**归约；shuffle 是另一类指令，**从未验证**。Bonsai-2 的 tied-output 输出头必经 FWHT → 若 shuffle 同样错编，输出必乱。
3. **tbo 覆盖情况**：fork 树的 test-backend-ops **自带 Bonsai-2 专项形状用例**（`PTQ1_0/PQ2_0 × m=67/70, k=1024/5120/6144/17408, n=1..8`，含 mul_mat_id 4-expert 与 perf 用例，注释明写 "Bonsai-2 shapes"）——量化 matvec/GEMM 可直接用 fork tbo 验证；但 **FWHT 仍无 tbo 覆盖**（仅 MUL_MAT 携带 `GGML_HINT_SRC0_IS_HADAMARD` 时触发，tbo 不设 hint），且 **master 树不含 Bonsai-2 代码**，现有 CLI/tbo 构建不可复用，必须从 vendored fork 树构建。
4. 降级路径已备好：OpenCL 后端同样实现了 PTQ1_0（`mul_mv_ptq1_0_f32.cl`），本机日常后端即可跑 Bonsai-2 GPU 卸载；CPU 有完整 vec_dot + 编解码（**注意：实测 2.7~2.9 t/s 的证据来自 Bonsai 一代 27B Q1_0，非 Bonsai-2**，Bonsai-2 CPU 速度未测）。

## 1. 模型侧事实

### Bonsai-2 27B（本调研对象）

- **产物**：`Ternary-Bonsai-2-27B-PTQ1_0.gguf`（5.95 GB，1.58-bit 三值，实际 1.75 bpw）；catalog 条目 `bonsai-2-27b-ternary-ptq1_0`，tag「需新版引擎」**纯文本**（commit d4d6725 已入目录，17 项单测）。
- **base 架构：待实测**。fork 的 arch 注册表**没有 bonsai/prism 专用 arch**（`llama-arch.cpp` 全列表零匹配）；`prism.hadamard` 元数据在 `llama_model_base::load_hparams`（`llama-model.cpp:1196+`）加载——这是 **base 层、arch 无关**的通用钩子，任何 base arch 都可携带。真实 base 架构以 GGUF `general.architecture` 为准（模型未下载，未读）。
- **量化格式 PTQ1_0**（`GGML_TYPE_PTQ1_0 = 143`，"Prism-private ternary, group 128"）：fork **新增的私有类型**（上游无），group 128 三值 trit 流，**非位置序**——qs 16B 段载元素 `t*16+j` → 8B 段载 `80+t*8+(j-16)` → qh 每 4 trit/字节载 `120+t*2+h`；解码用基 3 余项递推 `t = (v*3)>>8, v = (v*3)&0xFF`（`ptq1_0.glsl`）。CPU 编解码（`ggml-quants.c`）与 GPU shader 必须逐位一致——shader 头注释明示「divergence shows up as wrong matmul results rather than a build error」（错了不报编译错，直接出乱码）。PQ2_0 为同族 group-128 Q2_0。
- **输出头（关键差异点）**：`prism.hadamard` v2 `tied_output` —— token embedding 与 output projection 共享 Hadamard 行：查表侧重建 `s·(H·z)`，投影侧先对输入做 `H·(s·h)`。loader 校验元数据（version 1/2、tied_output、`output.weight` 必须缺席）并注册前向/逆向变换；计算图里以 **MUL_MAT + `GGML_HINT_SRC0_IS_HADAMARD`**（`ggml.h:449`）标记，`llama-context.cpp:61` 消费。

### Bonsai（一代，27B/8B）——与 Bonsai-2 是不同模型、不同架构族，勿混

- 一代 catalog：`bonsai-27b-q1_0`（**带 dspark 草稿**）、`bonsai-27b-ternary-q2_0`、`bonsai-8b-q1_0`。
- **dspark（`LLM_ARCH_DSPARK`）是一代 Bonsai 27B 的投机解码草稿架构**（"Noncausal block drafter"：target tap 提供 K/V 上下文，draft token 走 dense trunk + 顺序纠偏/Markov 头；`common/dspark-markov-*` 三套实现，均为未提交新文件）——**与 Bonsai-2 无关**，Bonsai-2 catalog 条目无 dspark 字段、无 agentCapabilities。
- 一代 CPU 实测 2.7~2.9 t/s（README 注）是**一代 Q1_0 的数据**，不能作为 Bonsai-2 的性能证据。

## 2. 各后端实现覆盖矩阵

| 后端 | 组件 | 位置 | 状态 |
|---|---|---|---|
| CPU | vec_dot + 编解码 | `ggml-cpu/quants.c`（5 处）、`arch/x86/quants.c`、`arch-fallback.h` | ✅ 代码在（**2.7~2.9 t/s 是 Bonsai 一代 Q1_0 的数据，Bonsai-2 CPU 速度未测**） |
| CUDA | MMQ 实例 + Hopper q1 专用核 | `mmq-instance-ptq1_0.cu`、`mmq-hopper-q1.cu`、`mmq-config-pascal.cuh` | ✅（未跟踪新文件，服务器向，本项目不验） |
| OpenCL | matvec PTQ1_0 专用核 | `kernels/mul_mv_ptq1_0_f32.cl` + `ggml-opencl.cpp` 分派 4 处（含 128 对齐约束 11578） | ✅ 代码在；**本机默认后端 → Bonsai-2 GPU 卸载的现实路径** |
| Vulkan | dequant / matvec f32·f16·q8_1(int) / MMQ GEMM / matmul_id / get_rows | `ggml-vulkan.cpp` 32 处（`CREATE_MM2` 注册，**无 coopmat2**——`dequant_funcs_cm2.glsl` 不带 PTQ1_0 decoder，shader-gen 显式跳过） | ✅ 代码在，❌ 未在 A825 验证 |
| Vulkan | FWHT（hadamard 专用算子） | `fwht.comp`（subgroup shuffle 变体）+ `fwht_shmem_*.comp`（fallback），宽档阈值 `MAX_SUBGROUP_N=2048 / EL_W=64` | ⚠️ **shuffle 变体在 Turnip 未验证** |

## 3. Vulkan 侧机制原理

- **decode（n=1）matvec 三选一**：f32 / f16 matvec（SHMEM 归约变体，受 `use_subgroups` 门控）与 q8_1 matvec（dp4a 整数路径，要求 `integer_dot_product`，且 PTQ1_0 特有 4 rows/workgroup 布局）。三药下两条都进安全区：`NO_MMV=1` → 全走 MMQ GEMM；`IDP` 禁用 → q8_1 管线根本不创建。
- **prefill**：MMQ GEMM（`matmul_ptq1_0_f32`）。**fork 的 tbo 自带 Bonsai-2 专项用例**（`tests/test-backend-ops.cpp:9300+` 注释明写 "Bonsai-2 shapes"：m=67/70、k=1024/5120/6144/17408、n=1..8 含行尾不齐、batched 与多列 B，另含 `test_mul_mat_id` 4-expert 与 perf 带宽用例）→ 量化 matvec/GEMM 可用 fork tbo 直接验证；master 树无这些用例。NO_SUBGROUP 下其余量化类型已验全过，PTQ1_0 待 fork 构建复测。
- **MoE 行**：`matmul_id_ptq1_0_f32` / `matmul_id_subgroup_ptq1_0_f32`——subgroup 变体创建时传 `use_subgroups` 参数，NO_SUBGROUP 下不派发 → 落非 subgroup 变体。Bonsai-2 27B 是否 MoE **待 GGUF 元数据实测**（tbo 的 mul_mat_id 用例只是通用 MoE 形状，不代表模型结构）。
- **FWHT 触发链**：`ggml_vk_mul_mat` 分派末尾 `ggml_vk_can_use_fwht`（检查 op_params hint、对应宽度管线存在、src/dst 类型与连续性、无融合附加算子）→ `ggml_vk_fwht` 专用管线。管线选择：`use_subgroup = subgroup_basic && subgroup_shuffle`；Adreno 825 subgroup_size=64，hadamard block_size=128 → n=128 非 wide（128/64=2 ≤ 64）→ **走 subgroup shuffle 变体**（`fwht_f32`，{sg, 128, 4 rows/wg}）。
- **FWHT 算法本质**：蝶形网络用 `subgroupShuffleXor` 交换数据，无算术归约 → 与已实锤的 subgroupAdd 错编是**不同指令类**，坏不坏未知。Intel Windows 驱动曾有 fwht 崩溃先例（已有 driver_id 门控），说明这类专用 shader 出驱动问题是有先例的。

## 4. Adreno 825 / Turnip 风险清单（按优先级）

| 级别 | 风险 | 机制 | 缓解 |
|---|---|---|---|
| **P0** | FWHT subgroup shuffle 错编 | 不在 NO_SUBGROUP 门控内（判 shuffle 不判 arithmetic）；无 tbo 覆盖；坏则 tied output 头全乱 | A/B patch：`use_subgroup` 判定叠加 NO_SUBGROUP 检查强制走 `fwht_shmem_*`；确认后可上报 whitebelyash/Banners（与 subgroupAdd 案并列） |
| **P0** | PTQ1_0 未复测 | fork tbo **自带 Bonsai-2 用例但从未在 A825 跑过**；master 树无此类型、现有 CLI/tbo 构建不可复用 | 从 vendored fork 编 tbo，直接跑自带的 Bonsai-2 形状用例（`-p type_a=PTQ1_0`） |
| P1 | 性能 | 27B PTQ1_0 5.95 GB 统一内存，Turnip f32 累加路径，预估 decode 1~3 t/s（Bonsai-2 CPU 未测，一代 2.7~2.9 t/s 仅作量级参考） | 回退 OpenCL/CPU；**dspark 草稿是一代专属，Bonsai-2 无投机解码可用** |
| P1 | matmul_id_subgroup_ptq1_0 | MoE id 路径 subgroup 变体 | 已被 NO_SUBGROUP 门控（确认参数传递即可） |
| P2 | 已知遗留 | CONV_2D f32 全错（Bonsai-2 base 架构待实测，是否含 conv 未定）、FA hsk=192 | `-fa off` 绕开 FA；conv 待模型结构确认 |

## 5. 验证计划（设备分批执行，避免长烤）

1. **构建**：从 vendored fork 树编 Android CLI + tbo（复用 `_study/vkcli` 工具链；`GGML_VK_TURNIP` 直载补丁 vendored 树已含）。
2. **静态**：fork tbo 自带 Bonsai-2 形状用例——`-o MUL_MAT -p type_a=PTQ1_0`（m=67/70、k=1024/5120/6144/17408、n=1..8）+ matmul_id 用例，`GGML_VK_NO_SUBGROUP=1`。
3. **e2e**：Ternary-Bonsai-2-27B-PTQ1_0 短生成 ×5，三药 + `-fa off`；**与 CPU 同模型输出对照判定 FWHT 正确性**（首个疑点即 tied output 头）。
4. **若乱码**：A/B 强制 shmem FWHT → 定位 shuffle 错编后修门控/上报。
5. **性能**：记录 t/s；< 1.5 t/s 则回退 OpenCL/CPU（Bonsai-2 无 dspark 草稿，无投机解码可补）。
6. **APK 化前置**：清理 `[turnip-step]` 诊断探针；JNI `loadVkFlagsConf` 增加 Turnip 模式注入三药。

## 6. 顺带产出：上游上报素材清单

- subgroupAdd（算术归约）错编：tbo f32 MUL_MAT 203 FAIL → NO_SUBGROUP 203/203
- GDN S_V=128 shmem lanes 错编：钳 64 后 36/36
- CONV_2D f32/f16 全错（1155/1981）
- FLASH_ATTN_EXT hsk=192 FAIL
- （待验）FWHT subgroup shuffle

复现环境：Banners-Turnip v26.3.0-20260918-r6 A8xx（Mesa 26.3.0, Vulkan 1.4.363, KGSL build）+ Redmi Turbo 4 Pro（SM8735 / Adreno 825）。
