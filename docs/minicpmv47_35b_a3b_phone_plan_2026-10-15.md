# MiniCPM-V 4.7 35B-A3B 小米13 端侧落地施工方案（split-MoE + DSpark + 可选视觉）

日期：2026-10-15 ｜ 目标设备：小米13（adb `98fc9410`，SM8550 / Adreno **740**，MemTotal 11.4GB / 当前可用 ~5.9GB，/data 余 136GB）
目标：在 TongYi-Lite（小米13 真机）上跑通 MiniCPM-V 4.7 35B-A3B：**split-MoE 槽流式 + 官方 DSpark 投机加速 + 视觉投影用户可选**，并把上一轮 OpenCL MoE 代码审查的修复项一并落地。

---

## 0. 事实盘点（已核对）

| 项 | 状态 | 说明 |
|---|---|---|
| 主模型 GGUF | ✅ 已在机 | `models/minicpm-v4.7-35b-a3b-les.gguf` 1.66GB（qwen35moe：40 层 / 256 专家取 8 / hidden 2048 / GDN 线性注意力 full_attention_interval=4 / ssm_inner 4096 / ctx 262144） |
| 专家分片 | ✅ 已在机 | `.experts/layer_000..039.bin`（40×330MB，Q3_K，gate/up 各 450,560B + expert_stride 1,351,680B/层/专家 → **单专家全 slot ≈ 52.9MB**）+ `manifest.json`（schema v1，源 = mix_q3gud_im） |
| catalog 条目 | ✅ 已存在 | `assets/models_catalog.json` → `minicpm-v4.7-35b-a3b-les`（zerg13/MiniCPM-V-Apps-gguf 源；ModelScope+hf-mirror 双镜像） |
| 引擎 split-MoE | ✅ | JNI `moeManifest/moeBank` → `model_params.moe_slot_bank`；slot runtime（llama-moe-slot.cpp）q3_K 批处理内核链 |
| 引擎 qwen35moe | ✅ | `LLM_ARCH_QWEN35MOE` 全支持（含 GDN、MTP graph——本 GGUF 无 nextn 张量，MTP 不可用） |
| DSpark 头 | ❌ 不在机 | 官方 `dspark-MiniCPM-V-4_7-35B-A3B-F16.gguf` 789MB（arch=**dflash**，5 层 trunk，`dflash.target_layers[5]`，confidence head + **Markov 头**）。引擎侧 `draft-dspark` 全链路已在（dflash.cpp/dspark.cpp，Markov/confidence 全在 ggml 图内，设备无关） |
| mmproj | ❌ 不在机 | 官方仅 `mmproj-model-f16.gguf` 1.12GB 与 `mmproj-model-f16-4x.gguf` 0.91GB；projector_type=**minicpmv4_7** |
| mtmd minicpmv4_7 | ❌ 缺口 | fork 只注册到 `minicpmv4_6`（clip-impl.h:562）→ 本模型 mmproj 加载会报未知 projector type（**唯一硬开发**） |
| 采样默认 | 信息 | GGUF 内嵌 top_k=20 / top_p=0.95 / temp=1.0；vocab 248,144 |

已知 sha256（OpenBMB 原仓 API 实测）：dspark 头 `dbeca717b96448ecbb2240864ae00d2f90fe069bc3a8ce08c58084c8b7b96c0f`；mmproj-f16 `bff3b688…5d20f1`；mmproj-f16-4x `30f4daac…6518`。注意 **catalog 的 les.gguf/experts 是 zerg13 repack**，sha256 需按其实际文件回算补录（当前条目为 null）。

---

## 1. 验收标准

- **A1 文本主链路**：split-MoE 加载成功出字，长对话稳定（先记基线，后比增益）；无 watchdog（dropbox 无新增 pre_watchdog）。
- **A2 DSpark 净收益**：dflash 草稿头加载 OK；同组 prompt dspark on/off 对比，接受长度 ≥2.0、decode 中位数 ≥ +25%；**中位数+全样本记录，同轮同组**。
- **A3 视觉可选**：开关 ON 出图理解正确；OFF 省 ~0.9GB 且不初始化 mtmd。
- **A4 内存自适应**：bank 按 MemAvailable 自动分档（11G/12G/16G 机型），`[oom-guard]` 全通过；手工覆写可用。
- **A5 回归**：其它模型（Ling/split-MoE 老用户）bank 行为不变；**Adreno 740 上 q3_K/q4_0 batched 探针 NMSE 复测**（当前 revision）。

---

## 2. 任务分解（P0→P6）

### P0 资产补齐 + catalog 修正（0.5d）
1. 机内完整性校验：`manifest.json` 40 片齐全性（model_provider 已有 incomplete 分支，看 logcat）；抽样层文件 sha256。
2. catalog 条目增补：
   - `dsparkDraftMirrors` → `dspark-MiniCPM-V-4_7-35B-A3B-F16.gguf`（ModelScope `OpenBMB/MiniCPM-V-4.7-35B-A3B-gguf` + hf-mirror `OpenBMB`），本机名 `minicpm-v4.7-35b-a3b-les.dspark.gguf`，sha256 见上；
   - `mmprojMirrors` → `mmproj-model-f16-4x.gguf`（0.91GB，默认）与 `mmproj-model-f16.gguf`（1.12GB，高清可选）；
   - `mtpSupported: true → false`（GGUF 无 nextn 张量；加注释防再误开）；`recommendedNctx` 11G 机型降 8192；
   - sha256Hash 按 zerg13 实际文件回算补录。
3. `model_provider` 仿 `moeManifest` 先例：draft 文件存在 → 传 `draftPath`（加载日志带 `draft=` 行，复用现链）。

### P1 mtmd `minicpmv4_7` 投影器移植（1–2d，唯一硬开发）
1. **桌面先行**：PC/DGX 上 mingw `llama-mtmd-cli` 用 4.6 版 mmproj 跑通，再上 4.7 mmproj 观察报错张量表（460 tensors：ViT 27 层 1152、patch14/448、`wa_layer_indexes`、scale_factor=4、max_slice_nums=9）。
2. 移植：
   - `clip-impl.h`：`PROJECTOR_TYPE_MINICPMV4_7 "minicpmv4_7"`；
   - `tools/mtmd/models/minicpmv.cpp`：新增 `clip_graph_minicpmv4_7`（以 `clip_graph_minicpmv4_6` 为底，按张量表核对 LLaVA-UHD v4 intra-ViT 早压缩与 4x/16x resampler 差异）；
   - `clip.cpp` build 分支 + `mtmd-image` 预处理沿用 `mtmd_image_preprocessor_minicpmv`；
   - CMake 无需动（models/minicpmv.cpp 已在）。
3. **Adreno 编译门**：qwen3.5-4b OpenCL 加载一次全量编译，logcat 无 kernel compile error（`half` 保留字教训适用）。
4. 桌面过图 → 真机过图（视觉塔 device 跟主后端，MTMD device 设置项 b11267 修法已在）。

### P2 DSpark 端侧接线 + GDN 回滚验证（1–1.5d，**go/no-go 门**）
1. draft F16 上 740：`draft_params.n_gpu_layers = effective_gpu_layers`（现逻辑）；markov_w1 为 vocab 248K × rank 的 f16 表，rank 小，内存无虞。
2. **关键风险（最高优先级验证）：GDN 线性注意力状态回滚 × 投机解码**。qwen35moe 是 GatedDeltaNet（conv_kernel=4 / state_size=128），draft 被拒后的回退不能只靠 KV seq-remove——验证同 seed 下 `dspark on` 与 `dspark off` greedy 输出**逐 token 一致**（一致性不过 = fork state session 未覆盖 GDN 状态 → 修状态存取或 dspark 缓行）。列为第一个真机实验。
3. 参数：`dspark_block_size` 用训练值（dflash.block_size=16），手机端 n_draft 上限先 8（740 compute-bound，草稿成本要算账）；acceptance 统计走现有 logcat 驱动日志。
4. 若 789MB F16 头在 11G 机型挤压过大：备选 = 后续自研 dspark 头 q8_0 化（同 P4 的 quantize 缺口，本期不做）。

### P3 内存自适应热专家 bank（S8 提案落地，0.5d + 探针 0.5d）
回应本方案两大机型档位问题（12G 档 / 16G 档，后者可用多 3–4GB）：

- 现状：`model_provider.dart:360` 固定 `moeBank = 16`（bank16 稳、32 平台期——**那是小 E 模型的扫描结论**）。
- 方案：auto 分档，单一预算源与 OOM 守卫公式合并：
  ```
  slot_bytes = manifest 单专家 slot 字节（本模型 ≈ 52.9MB，读 manifest 不硬编码）
  budget     = MemAvailable − reserve(1.5G) − KV(n_ctx) − draft(dspark 在机 ?) 
               − (视觉 ON ? mmproj : 0) − compute buffer
  bank       = clamp(8, floor(0.6 × budget / slot_bytes), 64)
  ```
- 预期：16G 机型多 3–4GB ≈ **+56~74 个热专家**，热池覆盖率 6% → 30%（E=256），miss 换入次数显著降；11G 小米13 上界约 bank 20~24。
- 设置项：「智能 MoE bank：自动/手动（滑条 8–64）」；手动值持久化按模型。
- **验证探针**：bank 16/20/24 扫描（小米13）记录专家换入 miss 率 + tok/s（slot runtime 计数器 + logcat 聚合）；证实"大 bank 对 256 专家模型有收益"后才把 16G 机型默认抬上去——不照搬旧平台期结论。

### P4 视觉投影用户开关（0.5d）
- 按模型 per-model「图片理解」开关（复用 `mtpEnabledByModel` 的 Map 持久化模式）；**默认 OFF**。
- ON → `mmprojPath = mmproj-model-f16-4x.gguf`（默认）/f16（高清可选）；OFF → 传 null，不加载视觉塔（省 ~0.9GB，自动回给 bank 预算公式或 n_ctx）。
- 切换需重载模型（mmproj 在 load 时建立），UI 明确提示"切换将重新加载模型"。
- **mmproj Q8 结论（已查）**：官方仓库**没有** Q8 版（只有 f16 1.12GB / f16-4x 0.91GB）；b11267 的 `llama-quantize` **不支持视觉张量量化**（quantize.cpp 无 v.* 处理）。本期用 4x 版折中；长期跟进 unsloth 风格 mm-Q8_0 bundle 或上游 mtmd 量化支持，再考虑自产。

### P5 OpenCL MoE 审查修复项（前轮审查报告，1d；均在私有 fork，**不 commit 上游**）
| # | 修复 | 位置 |
|---|---|---|
| P1-1 | supports_op 对 q3_K 增加 `GGML_OPENCL_BATCHED_MOE` env 判断（关闭 → 返回 false 走 CPU；计算期 `GGML_ABORT` 只留给真门失配，文案补 env 提示） | ggml-opencl.cpp supports_op（:9609 区）/ :28042 |
| P1-2 | dense-loop 非法 id：**本列写零后 continue**（对齐批处理路径"写零"语义），不再 `return` 遗留未写 dst 列 | `ggml_cl_mul_mat_id_dense_loop` |
| P2-1 | 批处理与 dense-loop 显式拒绝非 q3_K 视图：`if (!is_q3_k && src0->view_src) return false;`（q4_0 重打包转正 S7 的护栏） | :23572 附近 |
| P2-2 | **740 真机 NMSE 复测**：当前 revision 的 q3_K/q4_0/q4_K batched 探针（`_probe/moe_probe` + `GGML_OPENCL_MOE_KDBG=1`），双 pack 路线（LLAMA_MOE_UPLOAD=0/1）；小米13=Adreno 740 即第二台硬件，正好扩设备矩阵 | 真机 |
| P2-3 | FGSVM route-0 可见性假设写入注释（生产 route 1 不动） | :14120 |
| P3 | 陈旧注释清理（:23504 "DISABLED" 块、:8962 矛盾路由注释）；sort scratch 分桶缓存（顺手） | — |

### P6 集成与基准（1d）
- 矩阵：dspark{off,on} × 视觉{off,on} × bank{16,24}；同 prompt 同轮同组，3 轮取中位数，**全样本记录**。
- 指标：decode tok/s、首 Tok、专家 miss 率、接受长度/接受率、`dumpsys meminfo` 峰值、温度节流。
- 稳定性：20 分钟长对话 + 5 图混合；重启后查 dropbox 无 pre_watchdog。

---

## 3. 风险与回退

1. **GDN × 投机回滚语义**（最高）：P2 第 1 个实验做；不过 → dspark 缓行（split-MoE 文本主链路不受影响），另案修状态存取。
2. minicpmv4_7 图结构差异超预期：桌面先行；兜底 = 本期视觉先不上（catalog `type:text` 保持可用）。
3. 740 与 830 内核行为差异（E031 前车之鉴）：P2-2 NMSE 门不过则本模型专家层回落 CPU 并记录。
4. 11G 内存三方挤压（bank×KV×draft）：n_ctx 8192 起步；OOM 守卫拒绝加载优于一命搏。
5. dspark F16 头 789MB：若净收益为负（草稿开销>收益）→ 关 dspark 保 bank。
6. zerg13 repack 与 OpenBMB 原版权重一致性：manifest `source.model_files` 已记录源，抽 1 层与原 gguf 比对字节。

## 4. 顺序与工时

P0(0.5d) → P1 桌面(0.5d) → **P2 GDN 门(0.5d)** → P1 移植收尾(1d) → P5 修复(1d) → P3(1d) → P4(0.5d) → P6(1d)。合计 **5–7 人日**；GDN 门失败则砍 P2 剩余与 A2。

## 5. 附录

- 设备：`98fc9410`（adb `C:\Users\jianz\AppData\Local\Android\Sdk\platform-tools\adb.exe`）；模型目录 `/storage/emulated/0/TongYiLite/models/`。
- 官方仓文件清单（ModelScope `OpenBMB/MiniCPM-V-4.7-35B-A3B-gguf`）：Q4_0 19.7GB / Q4_K_M 21.2GB / mix_q3gud_im 15.5GB / dspark-F16 0.79GB / mmproj f16 1.12GB / mmproj f16-4x 0.91GB。
- 探针 env：`GGML_OPENCL_MOE_KDBG=1`、`GGML_MOE_TRACE=1`、`LLAMA_MOE_UPLOAD=0|1`。
- 审查全量问题清单见前轮报告（P0 无；P1-1/P1-2/P2-1..3/P3 系列，本方案 P5 已覆盖全部可落地项）。

---

## 6. 实施进度（2026-10-15 当日记录）

| 阶段 | 状态 | 说明 |
|---|---|---|
| P0 资产+catalog | ✅ | catalog 已改 vision + mmproj/dspark 双镜像块（JSON 校验过）；`E:\DTXY\model_dl\` 已下载 sha256 复核：dspark 789,442,368B `dbeca717…`、mmproj-4x 910,491,648B。**待小米13 回线 push**（`minicpm-v4.7-35b-a3b-les.dspark.gguf` / `.mmproj`） |
| P1 mtmd minicpmv4_7 | ✅ 代码+编译 | fork 4_6 merger 图与 omni 4_7 图逐行等价（is_4x/DownsampleMLP/pos buckets），按 omni（OpenBMB llama.cpp-omni，真机验证版）移植：clip-impl.h enum+string；clip.cpp 六处 case 并入 4_6（builder/hparams/ffn-swap/tensor-load/n_patches/pos-buckets/n_embd）+ 4_7 hparams 新 case（scale_factor、image_pad_ov/rf=PAD_NONE、wa→insert_layer_id 带界校验）；mtmd.cpp 模板 case（同 4_6 模板）+ **`use_image_id` 机制移植**（字段+`<image_id>N</image_id>` emit，复用 fork 已有 `n_images_added` 计数）。canvas M-RoPE 位置分期 2（fork 无该机制，回退 4_6 式位置）。桌面/NDK 编译过，APK 字符串级验收（libmtmd.so `minicpmv4_7`/`<image_id>` 命中）。`v.tok_embd_sep` 不加载（omni 同款忽略） |
| P5 OpenCL 修复 | ✅ 代码+编译 | P1-1 supports_op q3_K 分支尊重 `GGML_OPENCL_BATCHED_MOE=0`（关→拒 GPU 走 CPU，abort 只留真门失配）；P1-2 dense-loop 非法 id 改**本列写零 continue**（clEnqueueFillBuffer，不再 return 遗留未写列）；P2-1 batched() 非 q3_K view 显式 return false（防 q4_0/q4_K view 读 base planes 静默错值）；P3 注释清理（:8969 过时 vendor-DEFAULT 路由块删除、:23518 DISABLED 历史块标注 superseded-by-v2）。FGSVM route-0 注释项（P2-3）与 sort scratch 缓存为可选项未动 |
| P3 内存自适应 bank | ✅ 代码 | `model_provider` auto 公式：`bank=clamp(8, floor(0.6×(MemAvailable−1.5G−0.75G计算/GDN−KV(contextSize×0.03MB/tok))−draft在机−mmproj在机)/slot), 64)`；slot 从 manifest Σbytes_per_expert（不硬编码）；读不到→兜底16。日志行带 MemAvailable/预算/slot 明细。手动覆写：`moeBankOverrideByModel`（`'*'`=全局滑条，8–64）设置→推理引擎「智能 MoE 加载」卡内。**bank16/20/24 真机探针扫描待小米13** |
| P4 视觉开关 | ✅ 代码 | `visionEnabledByModel` per-model「图片理解」开关（模型卡片，vision 模型显示）；未配置回退全局 autoLoadMmproj（既有行为不变）；OFF→mmproj 传 null 不加载视觉塔 |
| 回归 | ✅ | dart analyze 改动文件 0 error；`flutter test test/agent test/services test/providers` **552 全绿+2 skip** |
| P2 dspark 真机验证 | ⏳ | 前提链已核（qwen35moe layer taps 在、recurrent 快照回滚在、JNI 自动读 trained block_size=15）；同 seed greedy dspark on/off 等值 = GDN go/no-go 门，**待小米13 回线** |
| P6 基准矩阵 | ⏳ | 待小米13（dspark×视觉×bank 矩阵 + NMSE 复测 P2-2） |

设备状态：小米13 `98fc9410` **USB 离线**（push/装机/真机验证全被卡）；`43328e37`（SM8750）在线但按约定不推模型。APK（含 P1/P5/P3/P4 全部改动）已产出在 `build\app\outputs\flutter-apk\app-debug.apk`，待回线 `adb install -r -t` + push 1.7GB 资产。

---

## 7. dspark 加速无效根因排查（2026-10-16，**用户定案：暂停，等 GPU 全卸载方案**）

结论速览：第一层根因已修复入库；但按 830 实测的账，当前"MoE 流式 bank + GDN 快照回滚"架构上 dspark 期望收益极薄，停止现架构调优。

1. **根因①（已修，commit `d7ca447`）**：JNI 建 dspark draft ctx 未设 `n_outputs_max/n_outputs_max_per_seq = n_draft_max+1`（官方 spec-init 有、App 没抄），draft ctx 挂了 backend sampler 后 `llama_process` 逐行拒绝：`backend sampling supports at most 1 outputs per sequence` → **ret=-1，草稿恒空**（"加速无效"第一真凶；App 侧 8 轮空草稿 auto-dead 掩盖了它）。harness 修复后 `[dspark-dbg] done result=15` 实锤草稿产出正常。APK 已装 K90（18:45 构建，覆盖安装）。
2. **测量教训**：harness 曾混入 `common_speculative_accept` 重复调用（JNI 侧核对为单次、无误），此前 accept≈0 的数据被其污染；harness 已修（`_probe/moe_probe/minicpm_e2e.cpp`，含行对齐诊断/RS/回滚旁路/E2E_NDMAX/DKV 开关）。
3. **830 成本账（why 停）**：verify 16 行 ≈4s（0.25s/行，MoE 流式按 unique 专家搬运、摊不平）；draft GPU ≈0.5s/轮；**首次 GDN `seq_rm` 回滚后每步 6.8–8.3s**（plain 同 prompt 0.42s/步；RS 槽位本身只 -18%，回滚动作是大头）。算术上限 accept=16 → ~3.6 tok/s（对 plain 2.4 仅 +48%），而 draft 头真实 accept_len 需 ≥3.5 才净赚，混合 GDN 上 16 行 verify 还引发专家窗口抖动。
4. **RS 回滚机制备忘**（新架构会再遇到）：`llama_memory_recurrent::seq_rm` 仅当 `1≤rollback≤n_rs_seq` 且无未消费 pending 时经快照回滚，否则 return false（状态不回滚）；delta-net/dsv4 要求**尾部 `1+n_rs_seq` 个 token 必须同 ubatch**；App 里 MTP 用 checkpoint(get/set_data) 是另一条正确路径。
5. **环境雷（全卸载前仍生效）**：`LOOKAHEAD_PREFETCH=16`+`WINDOW=16` → blk.0 base=1536 slots → q_img 151M px，830 `clCreateImage -40` 崩；8+8=896 在限内，勿加大。
6. **未竟项（GPU 全卸载方案内重做）**：P2 同 seed greedy dspark on/off 逐 token 等值门；干净 accept 统计（harness `ab830.sh` 现成；注意默认 prompt 短、易一步 EOS，重测用 `GGML_E2E_PROMPT` 强制长回答 + `E2E_TEMP=0`）；dspark×plain 真机 A/B（验收：accept_len≥2.0、decode 中位 ≥+25%）。
