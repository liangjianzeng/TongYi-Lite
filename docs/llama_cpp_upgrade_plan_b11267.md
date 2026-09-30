# llama.cpp 升级到上游最新（b11267）安全方案 —— 补丁外置化 + 四道门验收

> 状态：**已完成并提交推送（main `0909603`，2026-09-30）** · 基线：上游 `fe8156f`（2026-08-19，≈b1017x）· 目标：上游 `b11267`（HEAD `19e28a2`）
> 原则：**先算补丁面、再动手；补丁外置化；不整树替换硬打；四道门验收；失败可回滚零损失。**

---

## 1. 现状证据（2026-10 实测）

### 1.1 版本差距

| 项 | 当前 | 上游最新 | 差距 |
|----|------|---------|------|
| 基线 commit | `fe8156f789011f6ea0baf6917ea09f88b89d9554` | `19e28a27702117d8f2eb16b825b9a308111f67d9` | ≈2000 commits |
| tag | （≈b1017x 时代） | `b11267` | 巨大 |
| 版本号 | fork 自抬 `0.2.0-dev` | 上游 `0.3.x-dev` | — |

### 1.2 fork 补丁面（fork 相对 fe8156f 的改动，必须保留的本地资产）

- **530 files 被 fork 改动** + **69 files fork 独有**（上游不存在）。
- fork 独有关键资产（纯新增、零冲突，直接复制即可）：
  - `src/models/dspark.cpp`（dspark 架构，fork 特有）
  - `ggml/src/ggml-opencl/kernels/mul_mv_ptq1_0_f32.cl` / `mul_mm_ptq1_0_f32_l4_lm.cl`（PTQ1_0 内核）
  - `ggml/src/ggml-opencl/kernels/fwht.cl`（FWHT/hadamard）
  - `ggml/src/ggml-vulkan/vulkan-shaders/dequant_ptq1_0.comp` / `mul_mat_vecq_ptq1_0.comp` / `ptq1_0.glsl`
  - `common/dspark-markov.*` / `common/kv-mean-center.*`（fork 工具）
  - `conversion/dspark.py`、`gguf-py/gguf/scripts/gguf_dspark_to_dflash.py`

### 1.3 冲突面（fork 改过 ∧ 上游也改过 —— 升级真正的难点）

- **461 files 冲突**，其中 app 实际使用的关键区 **127 files**：
  - `ggml/`：129（CPU/OpenCL/Vulkan 后端——fork 补丁最密集）
  - `src/`：42（dspark arch 注册、MTP staging API、KV cache）
  - `common/`：28（chat 模板、speculative/MTP、json）
  - `tools/mtmd/`：19（视觉/语音）
  - `CMakeLists.txt`：1
- `src/llama.cpp` **不在冲突集**（好消息：核心文件 fork 改动极少）。

### 1.4 上游已合入的 fork 相关能力（可少搬的）

- **`spark2_5` arch 已合入上游**：`src/models/spark2-5.cpp`（b11028 时代已合入，b11267 仍在）。
- **MTP/NextN staging API 仍在**：`llama_set_embeddings_nextn(ctx, value, masked)` 存在于 b11267 的
  `src/llama-ext.h`（新增 `llama_set_nextn_layer_offset`）。
- **KleidiAI v1.24.0 相同 tag**：b11267 仍 fetch `v1.24.0`（app 已 vendored 同版本，`FETCHCONTENT_SOURCE_DIR_KLEIDIAI_DOWNLOAD`
  覆盖仍有效——构建门的关键绿灯）。

### 1.5 JNI API 依赖面（升级后的适配工作量）

JNI 共调用 **67 个 `llama_/mtmd_/ggml_` API**，b11267 头文件已大幅拆分
（`llama-vocab.h` / `llama-model.h` / `llama-sampler.h` / `llama-context.h` / `llama-cparams.h` … 取代旧 `llama.h`），
**每个都要逐个核对签名**。已知会变的：
- `llama_tokenize` / `llama_vocab_*` / `llama_model_get_vocab`（vocab 独立成对象）
- `mtmd_helper_bitmap_init_from_file`（b11028 已加第 4 参，b11267 返回 `mtmd_helper_bitmap_wrapper`）
- `ggml_backend_*`（b11028 已改 registry 模型，b11267 再演进）
- sampler 链 / `llama_batch_*` / KV cache API

---

## 2. 升级策略（安全可靠 + 不影响 fork）

### 核心原则

1. **补丁外置化**：先把 fork 相对 fe8156f 的改动导出为 per-file patch 系列（按目录分组），
   再打到上游新树上——绝不"整树替换 + 手动重打"，也不把本地补丁当祖传。
2. **隔离执行**：升级在独立分支/worktree 进行，主仓 tag 冻结，失败即回退零损失。
3. **四道门验收**（AGENTS.md 立规）：编译门 → 内核门 → 参数门 → 基准门，全过才算完。
4. **升级类回归几乎都是静默的**（不崩不报错、只是慢/数值错）——验收必须机检化，不信"看着没问题"。

### 步骤 0：冻结现状（必须最先做）

```bash
git tag v0.2.8-fe8156f-known-good   # 当前树已知良好，打 tag 备份
git commit -m "freeze: llama.cpp fe8156f known-good baseline"
```

### 步骤 1：生成补丁系列（算面）

```bash
# 仅导出 app 实际使用的关键区（src/ ggml/ common/speculative common/chat models/ tools/mtmd CMakeLists）
git diff --no-index <fe8156f树> third_party/llama.cpp > fork-full.patch   # 全量备份
# 按目录分组，便于逐组回放与评审：
#   fork-core.patch（src/ + common/speculative + models/）
#   fork-ggml-cpu.patch / fork-ggml-opencl.patch / fork-ggml-vulkan.patch
#   fork-mtmd.patch / fork-cmake.patch
```

### 步骤 2：隔离替换上游新树

```bash
git checkout -b upgrade-b11267          # 独立分支
robocopy <b11267树> third_party/llama.cpp /MIR   # AGENTS.md 已验证：robocopy 快，别用 Remove-Item
```

### 步骤 3：按类回放补丁（冲突分级处理）

| 类别 | 文件 | 做法 |
|------|------|------|
| **A. fork 独有（69）** | dspark.cpp、PTQ1_0 kernels、FWHT shaders、kv-mean-center | 直接复制，零冲突 |
| **B. 上游已合入（决策点）** | `spark2_5` arch、NextN/MTP API | **决策点**：若 Spark-X2.5 GGUF 声明 `spark2_5` arch → 可弃 fork 的 `dspark`，直接用上游实现（少搬一大块）；若声明 `dspark` arch → 必须保留 fork 版 dspark.cpp + arch 注册 |
| **C. 关键冲突（127）** | llama-arch / ggml-cpu / ggml-opencl / ggml-vulkan / common/speculative / tools/mtmd | 逐个 3-way merge：`fe8156f 旧` ← `fork 改` + `上游新`，按 API 漂移适配；每文件评审后再提交 |
| **D. 构建层** | CMakeLists（app + ggml） | 保留 vendored KleidiAI 双写覆盖、`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod`、目录级 `-O3 -DNDEBUG`、Turnip/vk_flags 注入；按 b11267 新 CMake 结构改 |

### 步骤 4：适配 JNI 层（67 个 API）

逐个对 b11267 头文件核对，重点：
- vocab 对象化（`llama_tokenize(vocab,…)` / `llama_vocab_*`）
- mtmd helper 签名（返回 `mtmd_helper_bitmap_wrapper`）
- ggml-backend registry API
- MTP staging（`llama_set_embeddings_nextn` 三参 + `llama_set_nextn_layer_offset`）
- **不许顺手改默认值**：`n_gpu_layers=100` / `n_ubatch`（CPU=16、GPU=512）/ `flash_attn=DISABLED` / sampler 链

### 步骤 5：四道门验收（机检化）

1. **编译门**：`gradlew --stop` + 清 `.cxx` 全量重编后扫 `compile_commands.json`：
   ggml-cpu / kleidiai / mtmd / llama core / JNI 命令行**必须同时含 `-O3 -DNDEBUG`**，
   ggml-cpu 主源码必须 `-march=armv8.2-a+dotprod`。⚠️ 注意 PowerShell `-match` 大小写不敏感、
   compile_commands 路径是反斜杠。
2. **内核门**：configure 摘要 KleidiAI 必须 ON，且对象文件来自 `third_party/kleidiai`（vendored，
   不是网络拉取）。⚠️ FetchContent 项目名可能再变：覆盖变量 `FETCHCONTENT_SOURCE_DIR_<名字大写>`，
   app CMakeLists 新旧名字双写兜底。
3. **参数门**：logcat 抓 `[handleLoadModel]` 与升级前逐项 diff：`n_gpu_layers=100` /
   `n_ubatch`（CPU=16、GPU=512）/ `flash_attn=DISABLED` / sampler 链。
4. **基准门**：基线设备（Xiaomi 25053RT47C / 8 Elite）同 prompt 三后端各 3 轮，tok/s 对
   `docs/archive/backend_benchmark_2026-08-04.md` 基线，**偏差 >±10% 不许收工**。
   排查顺序：编译门 → 内核门 → 上游回归。

### 步骤 6：回归 + 真机验证

- `flutter test test/agent` 全绿（动智能体循环/协议前必跑）。
- 真机三后端（CPU / OpenCL / Vulkan）各加载 + 推理一遍（Adreno 825 / 天玑）。
- **Mali 崩溃缓解在 b11267 上重验**（ggml-vulkan 大重写，旧"删 copy_transpose_02.comp"式改动未回带）。
- 视觉链路（mtmd）真机加载 + 图片问答；语音（Gemma 4 E2B）按住说话。
- APK 字符串级验收（debug kernel UTF-8 / release libapp.so UTF-16LE）。

### 步骤 7：回滚预案

- 升级分支任何一步失败 → `git switch main` + 恢复 tag `v0.2.8-fe8156f-known-good`，零损失。
- **绝不"先卸载再装"真机**：覆盖更新 `adb install -r`，保留模型缓存。

---

## 3. 风险清单

| 风险 | 等级 | 对策 |
|------|------|------|
| 冲突面巨大（461 冲突 / 127 关键） | 🔴 高 | 补丁外置化 + 3-way merge + 逐文件评审；不整树替换 |
| `dspark` vs `spark2_5` 决策错误 | 🔴 高 | 先查 Spark-X2.5 GGUF 的 arch 元数据再决定（见步骤 3-B） |
| mtmd 视觉/语音 19 冲突 | 🟠 中 | 上游 mtmd 大改；JNI 视觉链路逐 API 核对 + 真机验证 |
| ggml-vulkan 大重写 | 🟠 中 | Mali 崩溃缓解重验；Turnip 直载 + `libhardware.so` stub 重验 |
| 静默性能回归 | 🟠 中 | 四道门机检化，不信"看着没问题" |
| JNI 67 个 API 签名漂移 | 🟠 中 | 逐头文件核对；参数门 diff 兜底默认值漂移 |
| 升级半途状态污染主仓 | 🟢 低 | 独立分支 + tag 冻结 + robocopy 替换 |

---

## 4. 决策记录（2026-10 实测定案）

### 决策 1：Spark-X2.5 走上游原生 `spark2_5`；dspark 投机解码必须移植 fork 资产（已定案）

**证据链（全部实测）**：
- Spark-X2.5 GGUF（catalog 指向 `abenzerps/Spark-X2.5-4B-GGUF`）头部解析：
  `general.architecture = "spark2_5"`，KV 键全为 `spark2_5.*`
  （block_count/context_length/embedding_length/feed_forward_length/attention.head_count），
  **零 `dspark.*` 键、零 markov/confidence/log_snr 扩展键**。
- fork 只注册 `LLM_ARCH_DSPARK`（"dspark"），无 `spark2_5` → fork 当前加载该 GGUF 必然
  `LLM_ARCH_UNKNOWN`（`llm_arch_from_string` 无匹配，llama-model-loader 直接失败）。
- 上游 b11267 注册 `LLM_ARCH_SPARK2_5`（"spark2_5"，`src/models/spark2-5.cpp` 146 行）→
  升级后可正常加载。
- **但 JNI 有完整 dspark 投机解码**（`tongyilite_jni.cpp`：`draft_model`/`dspark_ctx`/`dspark_enabled`，
  加载 `Bonsai-27B-dspark-Q4_1.gguf` 式 draft 模型，读 `dflash.block_size` 键）；fork 的
  `common/speculative.cpp` 有 `COMMON_SPECULATIVE_TYPE_DRAFT_DSPARK`（198 行起完整实现），
  依赖 `llama_model_dspark_get_meta` / `llama_model_dspark_get_markov`（dspark.cpp + llama-model.cpp），
  错误消息「missing dspark.*.block_size KV」→ **dspark draft GGUF 的键是 `dspark.*` 前缀，fork 独有格式**。

**结论：双轨保留**：
- Spark-X2.5 主模型 → **上游原生 `spark2_5` arch**（零移植，上游维护）；
- dspark 投机解码 → **必须移植 fork 资产**：`src/models/dspark.cpp`(573行)、
  llama-arch 的 dspark arch/KV/张量键、llama-model.cpp 的 dspark dispatch +
  `llama_model_dspark_get_meta/get_markov` + `dspark_markov_head_a/b` 成员、
  `llama-ext.h` dspark API、`common/speculative.cpp` draft-dspark、
  `common/dspark-markov.h/.cu/.mm`（CUDA/Metal markov 扩展）。
- fork 的 dspark.cpp（573 行）**与上游 spark2-5.cpp（146 行）是完全不同的实现**，
  AGENTS.md「仅 1 行差异」指 XHToken 官方 fork 版，非本项目 dspark.cpp——勿混淆。

### 决策 2：MTP/投机解码 = 上游 NextN 主干 + fork dspark 移植，3-way merge
- b11267 的 speculative.cpp 是上游 NextN 驱动；fork 的是 MTP + dspark 双驱动。
- `common/speculative.cpp`（28 冲突之一）采用 3-way merge：上游 NextN 主干 +
  fork MTP 差异 + fork draft-dspark 块。JNI 的 MTP/dspark 互斥路径保持。

### 决策 3：一步到位 b11267（用户已确认）
- 中间无 b11028 过渡；一次性吸收 ~2000 commits；风险由四道门 + 补丁外置化兜底。

### 决策 4：基准设备
- 验收设备：Xiaomi 25053RT47C / 8 Elite（已知基线 tok/s：Vulkan 8.60 / OpenCL 8.77 / CPU 4.33）。

### 决策 5：PTQ1_0 完整移植三后端（用户已确认 2026-10）
- **必须**：bonsai-2-27b-ternary-ptq1_0（catalog）用 GGML_TYPE_PTQ1_0=143（group-128 ternary）；
  上游 b11267 GGUF 解析器拒绝未知类型 143 → 不移植则 Bonsai 模型无法加载。
- 连带移植 PQ2_0（142，group-128 Q2_0）：fork 类型共享 codec 基础设施；bonsai-27b-ternary-q2_0 使用。
- 移植面（已全部落到 worktree）：
  - 核心：`ggml.h`（类型枚举 142/143/144）、`ggml-common.h`（block 布局）、`ggml.c`（traits）、
    `ggml-quants.h/.c`（quantize/dequantize/vec_dot generic）、`gguf.cpp`（legacy Prism Q2_0 布局检测）。
  - CPU：`ggml-cpu/quants.h/.c`（3 generic vec_dot）、`ggml-cpu.c`（type_traits 2 组）、
    `ops.cpp`（7 处 case）、`arch-fallback.h`（7 段 vec_dot 别名）。
  - OpenCL：`ggml-opencl.cpp` 完整（2 成员 + 2 加载块 + supports_op + can_mul_mat + mm/mv 分发 + 类型检查）、
    CMakeLists 内核列表 2 处；`mul_mv_ptq1_0_f32.cl`/`mul_mm_ptq1_0_f32_l4_lm.cl`/`fwht.cl` 文件已在 worktree。
  - Vulkan：shader-gen 类型名 + mmvq 选择 + dequant（`dequant_pq2_0.comp` 已复制）。

### 决策 6：common_speculative_impl_draft_dspark 不移植（用户已确认 2026-10）
- fork `speculative.cpp` 的 `common_speculative_impl_draft_dspark` 类（198-855，~650 行，CLI-only）不移植；
  上游保留 `common_speculative_impl_draft_dflash`（2654-2658）处理 draft-dspark。
- **JNI 不受影响**：JNI 的 dspark 路径是自定义的（加载 draft 模型 + 读 `dflash.block_size` meta +
  设 n_draft_max），不使用 speculative.cpp 类；已逐行核实 JNI 不调用 `set_dspark_ctx`/`dspark_ctx`。

### 决策 7：CPU vec_dot 走 generic（SIMD 内核延期）
- fork type_traits 的 vec_dot 指向 SIMD 符号（`ggml_vec_dot_pq2_0_q8_K` 等），上游不存在 → 先移植
  generic 版本（功能正确），SIMD（arch/x86/quants.c、arch/arm/quants.c）延期。
- arch-fallback.h 别名把 generic 实现宏改名导出 SIMD 符号名（上游机制），无冲突（SIMD 未移植）。
- Bonsai 行宽为 256 的倍数，generic 路径正确（慢但对）。

### 决策 8：gemv/gemm_pq2_0 不移植
- fork `repack.cpp/.h`、`arch/x86/repack.cpp`（~800 行 + 模板特化）不移植——PQ2_0 mul_mat 走
  generic vec_dot 路径；arch-fallback.h 不添加 gemv/gemm 别名（避免引用不存在函数）。

### 决策 9：ggml_cpu_pq2_needs_q8_0 不移植
- fork `ggml-cpu.c` 1177-1199（非 256-multiple PQ2_0 行的 Q8_0 转换优化）不移植——上游 mul_mat
  直接使用 type_traits；该优化是极端边缘场景（Bonsai 行为 256-multiple）。

### 决策 10：Vulkan 后端 PTQ1_0/PQ2_0 先 fallback CPU（mm 加速不移植）
- **理由**：上游 ggml-vulkan b11267 大重写（pipeline map 架构、无 fork 的 CREATE_MM2 宏），
  fork 30+ 处 pipeline 注册无法直接移植，风险高。
- **做法**：上游 supports_op 的 MUL_MAT 用显式类型列表（15390-15421），PTQ1_0/PQ2_0 不在列表 →
  自动 fallback CPU（功能正确，无 GPU 加速）。
- shader-gen 仍生成 dequant_ptq1_0/dequant_pq2_0 + mmvq（PTQ1_0 整数点积 shader）——为将来
  mm 加速预留，不影响 fallback。
- **后续优化路径**：若需 Vulkan mm 加速，按上游 pipeline map 架构重做 fork 的 CREATE_MM2 注册。

### 决策 11：OpenCL 无 FWHT → supports_op 拒绝 hadamard hint
- 上游 OpenCL 无 fwht 内核（hadamard 在其他后端：CPU/BLAS/SYCL/Metal/Vulkan）；JNI 不使用 hadamard，
  llama 层（deepseek4.cpp）与上游一致。
- 防御性修复：上游 OpenCL supports_op 的 MUL_MAT 对 `GGML_HINT_SRC0_IS_HADAMARD` 返回 false
  → 调度器走 CPU（正确，仅慢）；防止 OpenCL 把 hadamard 当普通 matmul 执行（错误结果）。

### 决策 12：llama_dspark_ctx struct 补全（移植遗漏修复）
- 上游 llama-graph.h 已有 `llm_graph_input_dspark_ctx`（引用 `const llama_dspark_ctx*`）但
  **缺少 `struct llama_dspark_ctx` 定义**（此前移植遗漏）→ 已补 fork 定义（llama-graph.h）。
- JNI 48 个实际函数调用逐一核对：全部存在于上游（缺失的 `llama_n_layer_nextn`/
  `llama_prepare_model_devices`/`llama_kv_cache_dsv4` 仅出现在注释中，非调用）。

### 决策 13：编译期修复清单（编译门迭代抓到，已全部落地）
- **embed_kernel.py UTF-8**：上游默认编码读 .cl（Windows 中文 GBK 环境 UnicodeDecodeError）
  → 显式 `encoding="utf-8"`（llama.cpp 标准）。
- **JNI mtmd 4 参**：b11267 `mtmd_helper_bitmap_init_from_file(ctx, fname, placeholder, opt)`
  → JNI 补 `mtmd_helper_init_opt_default()` 第 4 参（b11028 漂移，AGENTS.md 预判命中）。
- **std::iota include**：llama-context.cpp 缺 `<numeric>`（NDK libc++ 不隐式包含）。
- **dspark API 移植遗漏（fork llama-ext.h → 上游）**：
  - `llama-hparams.h`：补 `dspark_log_snr_conditioning`/`dspark_min_log_snr`/`dspark_max_log_snr`
    （fork 275-277；上游只有注释）。
  - `llama-ext.h`：补 `struct llama_dspark_meta`（8 字段）+ `llama_model_dspark_get_meta`/
    `llama_model_dspark_get_markov`/`llama_model_has_dspark_markov_head` 声明（fork 132/198/210；
    上游缺失——上游 speculative.cpp 973 引用 has_dspark_markov_head → 编译失败）。
  - **不移植** capture-layers API（llama_set_capture_layers/get_embeddings_capture）：上游
    speculative.cpp 不调用、无实现 → 只加 speculative 实际引用的声明，避免 undefined reference。
- **Vulkan shader-gen 回退（先做后撤）**：type_names 加 ptq1_0/pq2_0 → shader-gen 为它们生成
  get_rows/dequant 命令，但上游 shader 无解码逻辑 → glslc 宏拼接失败。**撤销**（type_names
  + mmvq 回到上游原版），Vulkan PTQ1_0/PQ2_0 完全 fallback CPU（决策 10 一致）。

### 决策 14：KleidiAI i8mm 变体编译 = 上游 b11267 默认（非回归）
- b11028 验收标准「kai_matmul.*i8mm 预期 0」基于 fork 配置；**b11267 上游默认编译全部变体**
  （29 个 i8mm 源文件，用 KleidiAI 自己的 `-march=armv8.2-a+bf16+i8mm` 独立编译，非 app 的
  armv8.2-a+dotprod）。
- **运行时安全**：kleidiai.cpp 317-318 按 CPU 特性检测（8 Elite has_i8mm → 选 i8mm GEMM ✓；
  Cortex-A78 不支持 → 不选，走 dotprod ✓）——不会 SIGILL。
- 收益：8 Elite 设备获得 i8mm 加速（较 dotprod 更快），与上游行为一致。
- 内核门验收更新：KleidiAI=ON ✓、对象来自 `third_party/kleidiai` vendored ✓（FETCHCONTENT
  新旧变量名都指向 vendored）、i8mm 变体=运行时按特性选择（非禁用）。

### 编译门 + 内核门验收结果（2026-09-30 实测）
- 全量 NDK 重编 **BUILD SUCCESSFUL**（.cxx 清空后 616 编译单元）。
- compile_commands 检查：ggml-cpu/kleidiai/mtmd/llama/JNI **0 个缺 `-O3 -DNDEBUG`**；
  ggml-cpu.c/ggml-cpu.cpp 均含 `-march=armv8.2-a+dotprod` ✓。
- kai_matmul dotprod 57 个；i8mm 29 个（决策 14：运行时按特性选择）。
- KleidiAI 对象全部来自 `third_party/kleidiai`（vendored，无网络拉取）✓。

### 打包 + 静态验收（2026-09-30 实测）
- **test/agent 回归**：285 项 + 2 skip 全绿（Dart 未动）。
- **debug APK**（99.1MB）+ **release APK**（44.5MB）双包生成。
- **AOT 缓存坑**：flutter assemble 静默复用旧产物（11:14 缓存）→ 清 `build/flutter-assemble`
  重新 assemble 才生成新 AOT（16:22）。验收改用 **ASCII 方法名**（`_showPersonaDialog`/
  `writeUserSkill`/`agentMaxSearchesPerTurn`/`loadBuiltinSkills`/`_followStream` 等 12/13 命中）——
  const UI 中文串在 AOT 以非 UTF-16LE 形式存储（池化/压缩），直接 UTF-16LE 查找会 0 命中误判。
- **PTQ1_0 内核 embed 验收**：APK 内 `libggml-opencl.so` 含 `mul_mv_ptq1_0_f32`/
  `mul_mm_ptq1_0_f32_l4_lm` 各 4 处（debug + release 双验）。
- **OpenCL 分发静态 review**：5 处 PTQ1_0 分发点（supports_op/can_mul_mat/mm/mv/type-check）
  与 fork 逐字一致；ops.cpp 7+7 case；arch-fallback 7 段别名。
- **主仓 = worktree 全树 SHA256 一致**（含 tools/ui 特殊路径文件）。
- **回滚路径**：tag `v0.2.8-fe8156f-known-good`（指向 dd7845c，升级前 fork 基线）可
  `git checkout <tag> -- third_party/llama.cpp` 整树恢复。

### 决策 15：fork 独有文件恢复（robocopy /MIR 删除 → git 基线恢复）
- robocopy /MIR 把主仓树替换为上游树时，**50 个 fork 独有文件被删除**（dspark-markov-metal.cu/mm、
  conversion/dspark.py、kv-mean-center 工具、dspark 测试、mmq-instance-pq2_0/ptq1_0.cu、
  snapdragon 脚本、rs-rollback、tools/ui/embed.cpp、.github workflows 等）。
- **恢复**：`git checkout 8cde426 -- <path>`（git 原始字节）恢复到主仓 + worktree，
  **blob hash 字节级验证 0 不一致**（PowerShell 文本转码会误报——必须 git hash-object 对比）。
- **不影响构建**：恢复文件全部在 Android 构建范围之外（无 CUDA/Metal/Hexagon/OpenVINO/tests/
  tools 编译），tools/tests CMakeLists 均无引用——编译门无需重验。
- 全树 SHA256 复验：主仓 = worktree 一致（tools/ui 特殊路径文件是脚本通配符误报，
  实际 hash 相同）。

### 真机验收步骤（Xiaomi 25053RT47C / 8 Elite）
1. `adb install -r app-debug.apk`（覆盖更新，不清数据）。
2. **参数门**：logcat 抓 `[handleLoadModel]`（JNI 504 行 LOGI "n_gpu_layers = %d"），
   与升级前逐项 diff：`n_gpu_layers=100` / `n_ubatch`（CPU=16、GPU=512）/ `flash_attn=DISABLED` /
   sampler 链——不许顺手改默认值。
3. **OpenCL Adreno 编译门**：qwen3.5-4b 安全小模型 OpenCL 加载一次（全量编译内核），
   logcat 无 `kernel compile error` 才过；不许拿 bonsai2 当编译测试。
4. **Bonsai-2 27B PTQ1_0 加载验证**：OpenCL 后端加载（OOM 守卫默认开），无崩溃。
5. **基准门**：同 prompt 三后端各 3 轮，tok/s 对 8-04 基线（Vulkan 8.60 / OpenCL 8.77 /
   CPU 4.33），偏差 >±10% 不收工。
6. 全过 → 合并回 main（worktree `upgrade-b11267` 分支）+ 提交推送。

> **2026-09-30 基准门状态**：用户真机确认 Vulkan/OpenCL/一代 Bonsai 推理正常
> （功能验证 ✓），但用户不想反复测试（「不用反复测试了」），基准门精确 tok/s
> 待用户方便时一次测试（OpenCL + Vulkan 各 1 轮，对比 8-04 基线 ±10%）。

### 2026-09-30 真机定案（已提交 `0909603`）

**Vulkan 全模型转圈/空输出 —— 根因三层 + 修复（全部验证通过）**：
1. **GGML_VK_TURNIP env 被上游 b11267 移除**（大重写后无该 env）→ JNI 内置 turnip
   直载失效 → 走系统 stock 驱动（0800.71）→ 空输出/转圈。修复：移植 fork 的 turnip
   HAL 直载（dlopen + dlsym ICD→HAL，HAL 偏移 0x70 PFN 表），`GGML_VK_TURNIP` env
   触发。
2. **NO_SUBGROUP / NO_MMV env 被上游移除** → fork 的 Adreno 825 适配失效。修复：
   移植两 env（`use_subgroups` / `ggml_vk_should_use_mmvq` 首部检查）。
3. **b11267 混用裸 Vulkan C 函数**（系统 loader 符号）→ turnip 创建的 device/instance
   传入系统函数 → SIGSEGV（启动崩溃，fault addr 0x1cdc16e，`ggml_vk_device_is_supported`
   @16306）。修复：**11 处裸调用全部 dispatcher 化**
   （`ggml_vk_default_dispatcher().vkGetPhysicalDeviceFeatures2/GetInstanceProcAddr/
   GetDeviceProcAddr`——turnip GIPA 解析）。

**真机验收铁证**（logcat）：`using Vulkan HAL GetInstanceProcAddr from .../libturnip_freedreno.so`
+ `Found 1 Vulkan devices: Adreno (TM) 825 (turnip Mesa driver)` + `backend_ptrs.size()=2`
+ `loadModel result: true` → Vulkan 正常输出（用户确认）。

**一代 Bonsai 27B（Q1_0）OpenCL 偶发答非所问 —— 已恢复**：无 dspark 头、Q1_0 内核与
fork 字节相同（diff 确认）；Vulkan 修复后用户真机复测 OpenCL + Vulkan 均正常。

**Bonsai-2 27B（PTQ1_0 5.95GB）—— OOM 守卫定案**：11GB 机器（MemAvailable ≈3.5-5GB）
GPU 全载物理不可能（AGENTS.md 已记录死机案）；OOM 守卫预检拒绝
（`[oom-guard] refuse PRE-load`），宁拒绝不死机。OpenCL PTQ1_0 mm/mv 内核完整
（`mul_mm_ptq1_0_f32_l4_lm` / `mul_mv_ptq1_0_f32`）；Vulkan supports_op 显式类型列表
不含 PTQ1_0/PQ2_0 → fallback CPU。

**2026-09-30 旁路崩溃定案（用户故意关闭守卫验证物理限制）**：用户设置
`oomGuardEnabled=false`（默认 true——settings_service.dart:326）→
`nativeSetOomGuardParams(guard=false)` → `TONGYILITE_NO_OOM_GUARD=1` → 旁路预检 →
bonsai2 加载（5.95GB + mmap 工作集）→ 内存耗尽（20:03:25 lmk 延迟）→
20:03:27 `lmk 杀 app`（`Process com.dgxspark.tongyilite (pid 14442) has died: fg TOP`，
uptime 1 天——非整机重启）。**结论：11GB 机器旁路 bonsai2 加载即内存耗尽（lmk），
推理阶段需求更大必整机死机——旁路无意义，物理不可能，宁拒绝不死机。**

---

## 5. 验收清单（机检化模板）

```bash
# 编译门
grep -c -- "-O3" .cxx/Debug/*/arm64-v8a/compile_commands.json          # ggml-cpu/kleidiai/mtmd/llama/JNI 全含
grep -c -- "-march=armv8.2-a+dotprod" .../compile_commands.json        # ggml-cpu 主源码
grep -c -- "kai_matmul.*dotprod" .../compile_commands.json             # >0
grep -c -- "kai_matmul.*i8mm"    .../compile_commands.json             # 预期 0（已禁用）

# 内核门
# configure 摘要：KleidiAI=ON，对象文件来自 third_party/kleidiai（非网络拉取）

# 参数门
adb logcat | grep "[handleLoadModel]"                                  # 与升级前逐项 diff

# 基准门
# 基线设备同 prompt 三后端 3 轮 tok/s，偏差 >±10% 不收工
```
