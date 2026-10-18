# fork 合并升级主线方案：llama.cpp b11267 → v0.7.0/master@10-17（2026-10-18）

> 结论先行：**建议升级，升级目标取 master@848bbda（10-17），不是 v0.7.0 tag**。
> 三树对账已完成（脚本 `_probe/upgrade3tree.py`，全量清单 `E:\DTXY\model_dl\upgrade3tree.txt`）：
> 人肉合并面只有 **50 个文件**（上游漂移 6012+/1296-），fork 纯新增资产 132 个文件零冲突直接搬。

## 0. 升级对象与理由

- `v0.7.0` = 10-15 tag（620d222，"bump version to 0.7.0"），**含完整 MoE 专家缓存**（`--moe-cache-mib`、`src/llama-moe-cache.{h,cpp}`、context/graph 全接线，已逐文件核实）——机制深读见 [dspark_全GPU栈支持方案 §11](dspark_全GPU栈支持方案_2026-10-16.md)。
- master@10-17 在 tag 之上再 +236 文件，其中与我们直接相关的修复：
  - **opencl: OOB tail fix for adreno noshuffle gemv (#30421)**——我们同族 noshuffle 内核的越界读修复，必须吃到；
  - opencl: FA softcap before mask (#30546)、MxFP4 MoE bin kernel for Adreno (#30691)；
  - spec: lilicorr (#30506)、server draft-slot state (#30574)；
  - graph: k-pool input views 跨层共享 (#30613)、llama_prefetch 拆分 merge/prefetch (#30532，LES 直接相关)；
  - vulkan: gpu-visible host memory fix (#30468)。
- 取 master 尾而非 tag 符合历史做法（b11028/b11267 都是 master 快照）；tag 与 master 的合并面差异（236 文件）远小于收益。

## 1. 三树对账（fork 树 vs 上游 b11267=5c200e0c vs 升级目标）

| 类 | 数量 | 含义 |
|---|---|---|
| SAME | 2705 | 三边一致，白过 |
| UP-ONLY | 1016 | 只被上游改（b11267→0.7.0 一个月的主体进化），拿新树即得 |
| FORK-ONLY | 132 | 只被我们改/新增（LES、dspark、PTQ1_0/FWHT、dspark 测试族、cl 内核族、snapdragon 脚本等），直接搬 |
| **CONFLICT** | **50** | **人肉合并面 = 升级工作量本体** |

CONFLICT 50 的上游漂移量（b11267→v0.7.0 diffstat 摘要）：

| 文件组 | 上游漂移 | 我们的改动 | 合并策略 |
|---|---|---|---|
| `ggml-opencl.cpp` | **511 行** | LES bank/q3_K pack/GPU 岛/并行会话 Mesa 战役改动 | **最大雷区**。以 git 补丁序列（本仓 commit）重放到新树；Mesa 战役合入后作为起点 |
| 14 × `gemv_noshuffle_*.cl` + 3 × `flash_attn_*.cl` | 5~247 行/文件 | 32b_trans/_o4/_spec 族扩展 | 逐文件 3-way；**上游 #30421 OOB 修复必须全收** |
| `llama-model.cpp/.h` + `arch.{h,cpp}` + `hparams.h` | 609+119+215 | arch 键（dspark/les）、模型表、hparams 上限 `llama_moe_layer_max_experts` | 机械跟锚；arch 枚举尾部追加无冲突 |
| `llama-context.{h,cpp}` | 355+42 | moe-slot 接线、prefetch/LES hooks、moe_stream 前身 | 逐 hunk 重放；注意与上游 moe_cache 成员并存 |
| `llama-graph.{h,cpp}` | 529+100 | moe-slot slot 注入（`build_moe_cache_slots` 同款思路我们已自研） | 逐 hunk；**与上游 moe_cache 图路径互斥校验**（两者都挂会双份 indirection） |
| `ggml-backend.cpp` | **397 行** | copy-callback/调度侧小改 | 跟锚 |
| `ggml-cpu/ops.cpp + ggml-cpu.c + quants` | 444+38+5 | PTQ1_0/FWHT/kv-mean ops | 基本是追加，好合 |
| `ggml.h` | 6 行 | ops 枚举追加 | 枚举追加位置冲突一行级 |
| `include/llama.h` | 15 行 | `dspark_head_source`/`moe_experts_path`/`moe_slot_bank` 扩展字段（llama.h:320-331） | 字段追加到 struct 尾；ABI 无所谓（静态链） |
| `common/speculative.{h,cpp}` | 211 行 | dspark spec 接线 | **升级红利点**，见 §2.3 |
| `llama-model-loader.{h,cpp}` + `gguf.cpp` | 152+40 | split-MoE 直读、bank 元数据 | 跟锚 |
| `tools/mtmd/*` | 728 行 | 视觉后端选择/dspark mmproj | JNI 锚点签名已兼容（见 §2.2） |
| `models/lfm2.cpp + models.h + qwen35moe.cpp` | 293+315+16 | LFM2.5 验收线/qwen35moe les 化 | models.h 宏表合并即可 |
| `memory-recurrent.*` | 25 | GDN 回滚 staging | 小 |
| `tests/test-backend-ops.cpp` | +859 | PTQ1_0 用例 | 追加式 |
| `CMakeLists.txt`（src） | 1 | 新文件登记 | 一行 |

## 2. API 漂移核查（四道门口径的静默失效项，已对 tag 逐项 grep）

1. **`llama_set_embeddings_nextn`（llama-ext.h staging API）存活且转正**：0.7.0 官方 `common/speculative.cpp` 自己就 include 并调用（masked 双向），MTP/dspark staging 通道与上游同构。✅
2. **mtmd**：`mtmd_helper_bitmap_init_from_file` 已是 4 参新签名（JNI 在 b11028 时代已适配）；**`MTMD_BACKEND_DEVICE` env 上游回归**（arg.cpp:2631）——JNI 兼容层可保留双保险。✅
3. **spec/dflash**：官方 `src/models/dflash.cpp` 与我们基线**字节相同**（b11267→0.7.0 未动），fork 的 `dspark.cpp` 为纯新增。官方 spec 框架已含 draft-dflash 全套（arg/download/opts 230 命中）+ `--spec-draft-cpu-moe/--spec-draft-ncmoe`（**草稿侧专家驻 CPU，dspark 白拿**）。⚠️ 评估项：官方 dflash builder 能否直接吃我们的 dspark 头（同 arch 键 `dflash`），能则 fork 的 dspark.cpp 缩减为"markov/conf 头扩展"。
4. **Vulkan turnip 三件套必丢**：`GGML_VK_TURNIP`/subgroups/mmvq 三个 env 上游无（本就是我们移植），且 b11267→0.7.0 Vulkan 又漂 601 行——b11267 升级教训重演：**锚点函数改名、裸 Vulkan C 调用必须重新全量 dispatcher 化审计**（上次 11 处 SIGSEGV）。⚠️⚠️
5. **KleidiAI vendored**：tag 的 `GGML_CPU_KLEIDIAI` 逻辑在 ggml-cpu/CMakeLists:630+，FetchContent 项目名以内核门流程复核（b11028 时 `KleidiAI_Download→kleidiai` 静默坑，app CMakeLists 已双变量兜底，升级后仍要机检 pin 版本对得上）。⚠️
6. **MoE cache（新功能）与我们的 LES/moe-slot 是并行两套机制**：上游要求"整层专家在 host + GPU bank"；我们的 bank 是 CPU 零拷贝 + q3_K pack。短期共存（不同开关），**同层双开必须加互斥断言**（graph slot 注入只走一条路）。⚠️

## 3. 合并策略总纲

**打法 = 换树 + 补丁序列重放**（四道门流程原文照抄 b11028/b11267 打法），在 **git worktree 升级分支**上做，main 冻结窗口只收 P0 级修复：

1. **P0 备料**（0.5 天）：
   - `git worktree add wt/upgrade-070`；从本仓 git 历史导出 fork 补丁序列（`git log --oneline -- third_party/llama.cpp` 自 0909603 起，按模块归组成 patch series）；
   - **等并行会话 Mesa 战役（§12）落地一个稳定点**——ggml-opencl.cpp 511 行漂移 vs 高频编辑中的本地改动是本方案唯一硬阻塞。
2. **P1 换树 + 模块序列重放**（1-2 天）：`robocopy master@848bbda → third_party/llama.cpp /MIR`（保留清单 = FORK-ONLY 132 文件先备份回填），然后按 §1 表逐模块重放。顺序：llama.h 字段 → arch/hparams/model 表 → moe-slot/LES → dspark → ggml-cpu ops → **opencl（最大块）** → vulkan/turnip → mtmd/JNI → CMake。
3. **P2 四道门**（AGENTS.md 原文流程，一项不能少）：编译门（-O3 -DNDEBUG -march 扫描）/ 内核门（KleidiAI vendored）/ 参数门（logcat 逐项 diff）/ 基准门（8 Elite 三后端 vs 8-04 基线 ±10%）。
4. **P3 功能回归**（半天-1 天）：
   - dspark：RS3 链 greedy on/off 25/25 EQUAL（GDN 回滚等价性，最高优先）+ N1/N2 e2e + 8090 采样 accept 位等抽查；
   - LES：bank0/bank1 加载矩阵 + Hook-1/3a 路径；
   - 模型 smoke：MiniCPM-V 对话、Ornith IQ4_XS+dflash 官方头（**顺便验证 §2.3 评估项**）、qwen35moe、lfm2.5、MiniCPM5-2B（工具调用回归 = App 侧）、vision 一图；
   - App：APK 出包 + 字符串级验收 + 真机（830）参数门。
5. **P4 新武器接入评估**（升级后另开）：① 830 上 `--moe-cache-mib` 与 LES 同场景对测（G3 前哨）；② STRP profile 冷启动方案；③ `--spec-draft-cpu-moe` 用于 dspark 的 CPU/GPU 混合布局重测（本方案最大红利候选：**官方可能把"830 dspark 必亏"的账改写**）。

## 4. 风险与回滚

| 风险 | 等级 | 缓解 |
|---|---|---|
| ggml-opencl 511 行漂移 × 并行会话高频改动 = 合并地狱 | 高 | Mesa 战役稳定点前不动 opencl；用补丁序列而非文件覆盖 |
| Vulkan turnip/subgroups 锚点漂移复发（裸调用 SIGSEGV） | 高 | 照 b11267 案全量重扫裸 `vk*` 调用 → dispatcher；真机 Vulkan smoke 必测 |
| 静默性能回归（升级类通病） | 中 | 基准门 ±10% 不过不收工；旧树 .cxx/参数日志留底对比 |
| dspark × 官方 dflash/moe_cache 双挂载冲突 | 中 | 图路径互斥断言 + 回归矩阵含"全关"档 |
| KleidiAI 静默失去 vendored | 中 | 内核门机检（对象文件路径必须来自 third_party/kleidiai） |
| 回滚 | — | worktree 分支不合 main 不过门不合并；main 旧树 tag 固化 `fork/b11267-pre-070` |

## 5. 明确不做

- 不在升级同一批做 moe_cache/LES 融合（P4 独立评估）；
- 不追 G2 sampling.cl 挂载进升级门（并行会话地盘，另账）；
- 不借升级重构 dspark 接线（先等价迁移，官方 dflash 接管评估放 P4）。

**验收定义**：四道门全绿 + dspark RS EQUAL + 基准门内 → 升级分支快进 main；P4 三项各出结论文档。

## 6. 实施进度（2026-10-18）

**冲突解决完成**：wt/upgrade-070（分支 upgrade/v0.7.0）换树 master@848bbda + fork 回贴（里程碑 f34edaf）→ 20 文件 47 hunk 手工合并全清（a352358 → e18b3e8），全树冲突标记 = 0。

关键合并决策：
- **hadamard 双系统并存**：fork 链保功能（load_tensors 内联 `register_hadamard_weights` → model 成员 → gparams → graph inline + memo），上游 `load_hparams/load_tensors_hadamard` 保留但不接线（hdmd 空 → 自动 no-op）；context.cpp verify 升上游 4 参版（含 moe_cache forward 扩展）。注意：**fork HEAD 本座 context 成员即无赋值**（Mesa 战役进行中的接线），dspark graph 直读 model 成员，合并后行为与 fork HEAD 等价，统一接线放 P4。
- **llama-graph.cpp**：fork seg 循环（A2 split）保留；`build_lora_mm_id` 收上游第 5 参 slots（LES 激活时 moe_cache 必空 → slots==nullptr 走 ids_seg，互斥安全）；swiglu clamp 补 GLM5_NEXT、down 段补 MELLUM（上游新增跟车）。
- **llama-context**：gparams dspark×4 + hadamard×2 + moe_cache 全并存；balloc 收上游 mixed-batch 参；rs `s_copy_main/s_copy_extra/s_copy_tail` 三视图并存（graph.h 补 extra 字段）。
- **ggml-backend.cpp**：取上游 copy_input 重构（host weights 延后拷 + callback_copy 协议）；dspark EVERY-split 输入注册 fix 存活；offs-in/cpyp 两探针迁进新 helper；FORCE_SPLIT_SYNC/SCHED_STATS/offs-p5 原样。
- **opencl（最后攻坚）**：6 个 noshuffle .cl = fork `nsg_rt=get_local_size(1)` 运行时 K-stride × 上游 `gid_s` 尾行 OOB clamp（#30421，方案红线已吸收）**组合合并**；MUL_MAT_ID supports 取 fork dense-loop 侧（830 vendor kernel 禁用策略不变，上游 PREC_F32 检查被 fork 全禁覆盖）；VSB 判定 = 上游 E17 + fork FORCE_VSB 探针并存；ALLOW_NO_SUBGROUP 旁路保留；q3k stage 函数群 + 上游 buffer_type_interface 双保。
- **speculative.cpp**：LLAMA_DSPARK_SHARED_HEAD env 块保 + 上游 `model_path` 变量采用。
- **arch-fallback.h**：x86 段 PTQ1_0/PQ2_0 三 alias 保，q2_0 线弃（上游 x86 现已原生）。

**静态核查过**：src/CMakeLists 上游 `llama-moe-cache.cpp` + fork 追加文件并存在册；models GLOB 收 dspark.cpp；model.h `hadamard_rotations` 成员齐（dspark.cpp 借用链编译安全）；`nextn_flags` 上游新 API 可用；graph.h params/成员双系统字段齐；vulkan `operator<<` 上游 common.h 已供（fork 重复定义已删）；KleidiAI FetchContent 名=`kleidiai`（app 双名兜底命中）。

**疑点登记**：① ~~上游 KleidiAI pin 升 v1.31.0，vendored 仍 v1.24.0~~ → **已定案解决**：上游 kernels.cpp 对 v1.31.0 新内核是强引用（无 `#ifdef` 守卫），vendored 已换 v1.31.0（官方 CMake 每 kernel 族自带 per-file `-march=armv8.x-a+扩展` 编译，SME/SME2/SVE2 全族入库）+ 运行期 `required_cpu` 分派——**830（A78/armv8.2）运行路径不变零风险，ARMv9 新机（高端机渐多，用户定案方向）直接吃到 SME2 GEMM**（q4_0/q4_k/q8_0 等 SME2 mopa 内核）。注意 kleidiai 换源后必须清 `.cxx` 全量重建（增量会留旧对象文件集 → 新内核符号 undefined）。② wt 构建需补 gitignored 三件（local.properties/key.properties/key.jks/gradle-wrapper.jar，已做）。

**当前**：编译门 NDK arm64 全量重编进行中（buildCMakeDebug）。

**编译门实战记录（2026-10-18 晚，下次升级照单核）**：
1. **stale configure 缓存**：清 `.cxx` 后首轮 configure 生成的 compile_commands 可能不带 `-march`（app `GGML_CPU_ARM_ARCH` 的 FORCE 值未进首轮 generate）——别信第一份 compile_commands；重跑 `:app:configureCMakeDebug[arm64-v8a]` 后 grep `build.ninja` 确认 ggml-cpu.c 带 `-march=armv8.6-a+dotprod+i8mm+fp16+bf16`（Mesa 满血档）再全量编。`.cxx\tools\profile\` 会混入 compile_commands glob，机检锁 `\Debug\` 路径。
2. **KleidiAI v1.31.0 落地**：官方 CMake 全族 per-file march（SME2 在册 107 units），换源必清 `.cxx`（对象不随源刷新）。
3. **hadamard 类型双定义**：graph.h fork struct × 上游 model.h L679 → graph.h 改前向声明 + using 别名（同类型别名合法共存）。
4. **buffer_type_i 新字段**（`alloc_buffer_n`/`get_alloc_size_n`）：SVM buft 旧 6 字段初始化错位 → 补 NULL；主 buft 接口 fork 副本删（上游已实现，fork 对函数体的 SOA_Q 等改动存活，已 diff 验证函数体一致）。
5. **mtmd MiniCPM-V 4.7 上游已收编**：`PROJECTOR_TYPE_MINICPMV4_7` case 与 `use_image_id` 成员在 fork 侧成重复 → 删 fork 重复块。
6. **common_batch C++ 化**：`common_batch_clear/add` 已删 → JNI `legacy_to_common_batch()` 包装喂 `common_speculative_process`；verify batch 改 llama_batch 直写（语义等价）。
7. **Mesa 在途代码随镜像入树**：`transpose_activation_q8.cl`（cpp 已引用）需补注册 `GGML_OPENCL_KERNELS`；`fwht.cl` 无引用不入编。
8. **REGC 宏守卫错位（fork 潜伏 bug，本次 Adreno 首爆）**：17 个 `gemm/gemv_moe_*_f32_ns.cl` 把 `REGC_Q00/Q01/Q10/Q11/LO/HI` 宏定义包在 `#ifdef GGML_GENERIC_SUBGROUP_SHUFFLE` 内（该宏仅 rusticl 经 `GGML_OPENCL_FAKE_QCOM_REQD=1` 注入），但 kernel 体内使用处无守卫 → Adreno 上 `use of undeclared identifier 'REGC_Q00'`（err=-11）。fork HEAD 同构，只是旧 init 从不预编译这些 bundle；0.7.0 init 全量预编译才暴露。修复 = 把 `#ifdef GGML_MESA_SPIRV/#else/#endif` 宏块移出 GENERIC 守卫（Mesa 位等，Adreno 走 `reg_c.lo/hi` 正常路径）。wt commit `40d1b31`。**教训：`.cl` 宏守卫作用域要看使用处，不只看定义处；Adreno 内核门要覆盖全部 bundle（0.7.0 init 预编译天然覆盖，是升级红利）。**

**四道门收官（2026-10-18 晚，wt `upgrade/v0.7.0`）**：
- **编译门 PASS**：`gate_compile070.ps1` 全绿（725 units：ggml-cpu 18 全带 march，`-O3 -DNDEBUG` 零违规，kleidiai 369 vendored，SME2 units 107）。
- **内核门 PASS**：Adreno 740（小米13 `98fc9410`）加载 bonsai-8b OpenCL 全 bundle 编译零 `kernel compile error`（REGC 修复后，commit `40d1b31`）。
- **参数门 PASS**：`[handleLoadModel]` 逐项对平基线：`nCtx=4096, gpuLayers=100, gpuBackend=opencl, nUbatch=512, flash_attn=off, KV q4_0/f16, backend_ptrs.size()=2, oom-guard 旁路=关`。
- **基准门 PASS（有提升）**：同机同模型 bonsai-8b-q1_0 OpenCL，同 prompt `count_1_to_20` 各 3 轮 decode：升级前（主仓 10-16 旧包）1.3/1.3/1.2 tok/s → 升级后 **1.5/1.6/1.6 tok/s（+27%）**；首 Tok/prefill ~10.3s → 5.3s（-49%，含 0.7.0 prefill 改进）。AGENTS 四门 ±10% 判据满足（正向）。
- 附注：App 侧驱动注意（本次调试踩坑）——小米13 MIUI 冷启动后 Flutter 需先盲点一次屏幕激活事件通道；发送必须点 FAB（`input keyevent 66` 不透传 TextField action）；FAB 随键盘上移（(976,1369) vs (976,2263)）。
