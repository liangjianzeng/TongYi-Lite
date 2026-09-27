# Bonsai 2 Vulkan 调研：实现现状、机制原理与 Adreno 825 验证计划

> 日期：2026-09-27 · 性质：代码考古 + 兼容性风险分析（纯静态调研，未动设备）
> 关联文档：[`docs/vulkan_adreno825_fix_2026-09-26.md`](vulkan_adreno825_fix_2026-09-26.md)（Turnip 三药修复）

## 0. 结论（TL;DR）

1. **Bonsai2（PTQ1_0 / PQ2_0 / prism.hadamard tied output / dspark）在 vendored fork（XHToken 树）已有全后端实现**——CPU、CUDA、OpenCL、Vulkan 四路齐全。Vulkan 侧覆盖 dequant / matvec（f32、f16、q8_1-int）/ MMQ GEMM / matmul_id（MoE）/ get_rows 共 **32 处管线注册**。**缺口是「未在真机验证」，不是「未实现」**。
2. Adreno 825 / Turnip 上最大风险点：**FWHT（快速 Walsh-Hadamard）subgroup shuffle shader 不在 `NO_SUBGROUP` 门控内**——它的选择条件是 `subgroup_basic && subgroup_shuffle`，而三药修复只置 `subgroup_arithmetic=false`。Turnip gen8 已实锤错编 subgroup **算术**归约；shuffle 是另一类指令，**从未验证**。Bonsai2 的 tied-output 输出头必经 FWHT → 若 shuffle 同样错编，输出必乱。
3. test-backend-ops **无法覆盖 FWHT**（仅在 MUL_MAT 携带 `GGML_HINT_SRC0_IS_HADAMARD` 参数时触发，tbo 不设 hint）——且 master 树不含 Bonsai2 代码，现有 CLI 构建不可用。**必须从 vendored fork 树构建 CLI** 做 e2e 验证。
4. 降级路径已备好：OpenCL 后端同样实现了 PTQ1_0（`mul_mv_ptq1_0_f32.cl`），本机日常后端即可跑 Bonsai2 GPU 卸载；CPU 有完整 vec_dot + 编解码（同族 Bonsai 27B Q1_0 实测 2.7~2.9 t/s）。

## 1. 模型侧事实

- **产物**：`Ternary-Bonsai-2-27B-PTQ1_0.gguf`（5.95 GB，1.58-bit 三值，实际 1.75 bpw）；catalog 条目 `bonsai-2-27b-ternary-ptq1_0`，tag「需新版引擎」（commit d4d6725 已入目录，17 项单测）。
- **架构**：`dspark`（`LLM_ARCH_DSPARK`，XHToken fork 私有），配套 **dspark Markov 投机解码**（draft 模型 `Bonsai-27B-dspark-Q4_1` 1.7 GB，catalog 已配镜像；Metal/CUDA/通用 C++ 三套实现在 `common/dspark-markov-*`，均为未提交新文件）。
- **输出头（关键差异点）**：`prism.hadamard` v2 `tied_output` —— token embedding 与 output projection 共享 Hadamard 行：查表侧重建 `s·(H·z)`，投影侧先对输入做 `H·(s·h)`。loader 在 `llama-model.cpp:1196+` 校验元数据（version 1/2、tied_output、`output.weight` 必须缺席）并注册前向/逆向变换；计算图里以 **MUL_MAT + `GGML_HINT_SRC0_IS_HADAMARD`**（`ggml.h:449`）标记，`llama-context.cpp:61` 消费。
- **量化格式 PTQ1_0**（`GGML_TYPE_PTQ1_0 = 143`，"Prism-private ternary, group 128"）：group 128 三值 trit 流，**非位置序**——qs 16B 段载元素 `t*16+j` → 8B 段载 `80+t*8+(j-16)` → qh 每 4 trit/字节载 `120+t*2+h`；解码用基 3 余项递推 `t = (v*3)>>8, v = (v*3)&0xFF`（`ptq1_0.glsl`）。CPU 编解码（`ggml-quants.c`）与 GPU shader 必须逐位一致——shader 头注释明示「divergence shows up as wrong matmul results rather than a build error」（错了不报编译错，直接出乱码）。PQ2_0 为同族 group-128 Q2_0。

## 2. 各后端实现覆盖矩阵

| 后端 | 组件 | 位置 | 状态 |
|---|---|---|---|
| CPU | vec_dot + 编解码 | `ggml-cpu/quants.c`（5 处）、`arch/x86/quants.c`、`arch-fallback.h` | ✅ 在用（Q1_0 同族实测 2.7~2.9 t/s） |
| CUDA | MMQ 实例 + Hopper q1 专用核 | `mmq-instance-ptq1_0.cu`、`mmq-hopper-q1.cu`、`mmq-config-pascal.cuh` | ✅（未跟踪新文件，服务器向，本项目不验） |
| OpenCL | matvec PTQ1_0 专用核 | `kernels/mul_mv_ptq1_0_f32.cl` + `ggml-opencl.cpp` 分派 4 处（含 128 对齐约束 11578） | ✅ 代码在；**本机默认后端 → Bonsai2 GPU 卸载的现实路径** |
| Vulkan | dequant / matvec f32·f16·q8_1(int) / MMQ GEMM / matmul_id / get_rows | `ggml-vulkan.cpp` 32 处（`CREATE_MM2` 注册，**无 coopmat2**——`dequant_funcs_cm2.glsl` 不带 PTQ1_0 decoder，shader-gen 显式跳过） | ✅ 代码在，❌ 未在 A825 验证 |
| Vulkan | FWHT（hadamard 专用算子） | `fwht.comp`（subgroup shuffle 变体）+ `fwht_shmem_*.comp`（fallback），宽档阈值 `MAX_SUBGROUP_N=2048 / EL_W=64` | ⚠️ **shuffle 变体在 Turnip 未验证** |

## 3. Vulkan 侧机制原理

- **decode（n=1）matvec 三选一**：f32 / f16 matvec（SHMEM 归约变体，受 `use_subgroups` 门控）与 q8_1 matvec（dp4a 整数路径，要求 `integer_dot_product`，且 PTQ1_0 特有 4 rows/workgroup 布局）。三药下两条都进安全区：`NO_MMV=1` → 全走 MMQ GEMM；`IDP` 禁用 → q8_1 管线根本不创建。
- **prefill**：MMQ GEMM（`matmul_ptq1_0_f32`）。tbo 全类型 MUL_MAT × NO_SUBGROUP 已验「f32×f32 / bf16 / 全部量化类型（q4_K 等）全过」，但 **PTQ1_0 是否在该 sweep 内待确认**（fork-only 类型，需 fork 构建 tbo 复测）。
- **MoE 行**：`matmul_id_ptq1_0_f32` / `matmul_id_subgroup_ptq1_0_f32`——subgroup 变体创建时传 `use_subgroups` 参数，NO_SUBGROUP 下不派发 → 落非 subgroup 变体。Bonsai2 27B 是否 MoE 待查（dspark 架构描述里未见 expert 字段，倾向 dense）。
- **FWHT 触发链**：`ggml_vk_mul_mat` 分派末尾 `ggml_vk_can_use_fwht`（检查 op_params hint、对应宽度管线存在、src/dst 类型与连续性、无融合附加算子）→ `ggml_vk_fwht` 专用管线。管线选择：`use_subgroup = subgroup_basic && subgroup_shuffle`；Adreno 825 subgroup_size=64，hadamard block_size=128 → n=128 非 wide（128/64=2 ≤ 64）→ **走 subgroup shuffle 变体**（`fwht_f32`，{sg, 128, 4 rows/wg}）。
- **FWHT 算法本质**：蝶形网络用 `subgroupShuffleXor` 交换数据，无算术归约 → 与已实锤的 subgroupAdd 错编是**不同指令类**，坏不坏未知。Intel Windows 驱动曾有 fwht 崩溃先例（已有 driver_id 门控），说明这类专用 shader 出驱动问题是有先例的。

## 4. Adreno 825 / Turnip 风险清单（按优先级）

| 级别 | 风险 | 机制 | 缓解 |
|---|---|---|---|
| **P0** | FWHT subgroup shuffle 错编 | 不在 NO_SUBGROUP 门控内（判 shuffle 不判 arithmetic）；无 tbo 覆盖；坏则 tied output 头全乱 | A/B patch：`use_subgroup` 判定叠加 NO_SUBGROUP 检查强制走 `fwht_shmem_*`；确认后可上报 whitebelyash/Banners（与 subgroupAdd 案并列） |
| **P0** | PTQ1_0 未进 tbo 验证集 | master 树无此类型；现有 CLI 构建不可复用 | 从 vendored fork 编 CLI + tbo，`-o MUL_MAT -p type_a=PTQ1_0` |
| P1 | 性能 | 27B PTQ1_0 5.95 GB 统一内存，Turnip f32 累加路径，预估 decode 1~3 t/s（对照 CPU 2.7~2.9 t/s） | dspark 投机解码补偿（draft-on-GPU 链路未验）；或回退 OpenCL/CPU |
| P1 | matmul_id_subgroup_ptq1_0 | MoE id 路径 subgroup 变体 | 已被 NO_SUBGROUP 门控（确认参数传递即可） |
| P2 | 已知遗留 | CONV_2D f32 全错（dspark 无 conv 层则无关，待查）、FA hsk=192 | `-fa off` 绕开 FA；conv 待模型结构确认 |

## 5. 验证计划（设备分批执行，避免长烤）

1. **构建**：从 vendored fork 树编 Android CLI（复用 `_study/vkcli` 工具链；`GGML_VK_TURNIP` 直载补丁 vendored 树已含）。
2. **静态**：tbo `-o MUL_MAT -p type_a=PTQ1_0`（若 tbo 支持该类型）+ GET_ROWS PTQ1_0，`GGML_VK_NO_SUBGROUP=1`。
3. **e2e**：Ternary-Bonsai-2-27B-PTQ1_0 短生成 ×5，三药 + `-fa off`；**与 CPU 同模型输出对照判定 FWHT 正确性**（首个疑点即 tied output 头）。
4. **若乱码**：A/B 强制 shmem FWHT → 定位 shuffle 错编后修门控/上报。
5. **性能**：记录 t/s；< 1.5 t/s 则评估 dspark 投机解码或回退 OpenCL。
6. **APK 化前置**：清理 `[turnip-step]` 诊断探针；JNI `loadVkFlagsConf` 增加 Turnip 模式注入三药。

## 6. 顺带产出：上游上报素材清单

- subgroupAdd（算术归约）错编：tbo f32 MUL_MAT 203 FAIL → NO_SUBGROUP 203/203
- GDN S_V=128 shmem lanes 错编：钳 64 后 36/36
- CONV_2D f32/f16 全错（1155/1981）
- FLASH_ATTN_EXT hsk=192 FAIL
- （待验）FWHT subgroup shuffle

复现环境：Banners-Turnip v26.3.0-20260918-r6 A8xx（Mesa 26.3.0, Vulkan 1.4.363, KGSL build）+ Redmi Turbo 4 Pro（SM8735 / Adreno 825）。
