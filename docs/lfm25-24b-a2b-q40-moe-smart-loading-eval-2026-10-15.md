# LFM2.5-24B-A2B Q4_0：MoE 智能加载 + 全 GPU 卸载评估方案

**日期**：2026-10-15 ｜ **模型**：`LFM2.5-24B-A2B-QAD-Q4_0.gguf`（13,578,190,880 B = 12.65 GiB，已在 `D:\MyLLM\models\LFM2.5-24B-A2B\`）
**目标平台**：A = 本机 PC（RTX 5060 Ti 16GB / 48GB RAM / Windows）；B = 手机端 TongYi-Lite App（Adreno，8 Elite 等）
**结论级别**：评估方案（含实测锚点与实施/验收清单，未开工）

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| PC 全 GPU 卸载能不能做？ | **已经做成并在跑**：8090 服务 `-ngl 999 -fa on`，decode **152-157 tok/s**、prefill **~1900 tok/s**（log：`D:\myllm\logs\lfm25_8090.log`）。显存余量仅 **128 MiB**，无升级空间 |
| PC 上"MoE 智能加载"还有什么价值？ | 腾显存：`-ncmoe 999 --moe-cache-mib 8192`（CPU 专家 + GPU LRU 缓存）可把模型常驻压到 **~0.9G + 缓存**，给 KV/多槽/并发让路。**注意**：Strata 复盘"moe_cache 证死"（坑 #32）是 125B/40.9G 专家、缓存覆盖率 7.5% 的结论；本模型专家仅 **12.05 GiB**，8G 缓存覆盖 **66%**，不可照搬"证死"，需 A/B 实测 |
| 手机能不能全 GPU 卸载整包？ | **Q4_0 整包 12.65 GiB 在 11-12G 机上物理不可能**（Adreno UMA，bonsai2 死机案同款账）。16G 机也只剩 ~6-7G MemAvailable，整包放不下 |
| 手机正确路线 | **split-MoE 智能加载**（fork 已为 MiniCPM-V-4.7-35B-A3B/qwen35moe 建成整条链路：manifest+层分片+slot bank+preadv 流式+异步预读+GPU FGSVM slot bank 雏形）。本模型需要一次 **lfm2moe 架构适配**（load+graph 两处，模式照抄 qwen35moe）+ **打包脚本** + **3 处按模型化的内存核算修正** |
| 手机预期性能 | 12-16G 机 bank 8-16：冷流 **4-10 tok/s**，热窗口/预读命中后 **10-15 tok/s**（MiniCPM 4.7 同机制实测锚点推算，见 §5） |
| 明确不做 | MTP/dspark（无草稿头）、IQ 系列换量化（QAD-Q4_0 即官方甜点）、`--fit` 与 `-ngl` 同时给（互相矛盾） |

---

## 1. 模型画像（实测/元数据精确值）

来源：本机 GGUF 元数据 + `llama-server` 加载日志 + HF `config.json`。

| 项 | 值 |
|---|---|
| 架构 | `lfm2moe`（fork 已支持：[llm2moe 映射 LLM_TYPE_24B_A2B](../third_party/llama.cpp/src/models/lfm2moe.cpp)，40 层） |
| 混合结构 | 40 层 = **30 conv（shortconv L=4）+ 10 full_attention**（layer 2,6,...,38），GQA 32Q/8KV，head_dim 64 → KV 维 512/层 |
| MoE | 前 2 层 dense FFN(11776)，**后 38 层 MoE：64 experts / top-4**，moe_ffn=1536，sigmoid 门控 + expert_bias，norm_topk |
| 词表 | 128,000（tied embeddings） |
| 量化 | 428 tensors：Q4_0 主体 + **embedding Q6_K** + norm/router/conv 核 f32；**QAD 量化感知蒸馏版**（Q4_0 质量接近他模型 Q4_K_M，无需换量化） |
| 文件 | 12.65 GiB = **experts 12.02 GiB + embedding 0.20 GiB + dense conv/attn/FFN 0.42 GiB**（本机 GGUF 按张量实测拆分） |

**关键拆分**（38 层 × 64 experts × gate/up/down {2048×1536} Q4_0）：

| 分量 | 数值 | 说明 |
|---|---|---|
| routed experts 总量 | **12.02 GiB**（95%） | 3×1,769,472 B/expert → **expert stride 5,308,416 B = 5.06 MiB**；324 MiB/层 |
| 常驻 dense（含 embedding） | ~0.62 GiB | output tied → GPU 侧 duplicate 再 +0.25 GiB |
| 每 token 活跃读取 | ~2.45B 参数 ≈ **0.77 GiB**（152 个 expert 片 × 5.06 MiB + dense 0.42 GiB 读） | "A2B"来源 |
| KV @128K（q4_0） | **~0.63 GiB**（10 层注意力才有 KV，5.63 KiB/pos） | 混合架构红利：dense 24B 同 ctx 要 4-8 倍 |
| conv 状态 | <1 MiB | 3×2048×4B×30 层 |

---

## 2. 两个平台的目标定义

- **"全 GPU 卸载"（PC）**：权重全部驻留 16G 显存，decode 只吃显存带宽。→ 现状已达成。
- **"MoE 智能加载"（PC）**：专家权重放主存，GPU 只驻 dense + **LRU 专家缓存**，miss 走 PCIe 异步补。目标：显存占用 12.9G → **≤9G**，速度损失 <30%，换出 KV/并发空间。
- **"MoE 智能加载 + 全 GPU 卸载"（手机）**：App 现有 split-MoE 形态——主 GGUF 剥离专家（-les），专家按 top-k 从 UFS preadv 进 **slot 窗口**；`LLAMA_MOE_BANK_GPU=1` 时 slot 落 Adreno OpenCL FGSVM、batched MUL_MAT_ID 在 GPU 算专家（= 计算全在 GPU 的"全 GPU 卸载"），否则 CPU bank 回退。

---

## 3. 平台 A：PC 5060 Ti 16GB

### 3.1 现状（实测，2026-10-15）

```
llama.cpp b11539 · -ngl 999 -fa on -c 262144 --parallel 2 -b 2048 -ub 512
KV q4_0 · 权重 12,941 MiB + ctx 1,440 MiB + compute 660 MiB = 15,042 / 15,170 空闲 MiB（余 128 MiB）
实测：decode 152-157 tok/s · prefill ~1,900 tok/s（19-20K 上下文会话）
```

注意两点：
1. 日志里 `common_params_fit_impl: n_gpu_layers already set by user to 999, abort`——**给了 `-ngl 999` 时 `--fit` 自动让位**，现在的"能跑"是手动卡边，Windows 桌面/WDDM 抖动即可能崩边（显存读数方法论见 Strata 复盘坑 #23/#31）。
2. 该配置下 **KV 加不动**（q8_0 要 +1.4G、第 3 槽、MTP 类需求全部没空间）——这就是智能加载要解决的问题。

### 3.2 候选配置（同一时刻最多 1 实例纪律不变）

| 方案 | 配置 | 显存模型 | 预期 decode | 定位 |
|---|---|---|---|---|
| **A0 现状** | `-ngl 999 -c 262144 kv q4_0` | 15.0G | **152-157（实测）** | 基线保留，bat 已有 |
| **A1 智能加载** | `-ngl 999 -ncmoe 999 --moe-cache-mib 6144`（GPU 常驻=dense 0.9G + 缓存 6G） | ~7-7.5G | **预计 80-130**，miss 走 PCIe 5.0（55GB/s，冷 769 MiB/token 上限 ≈70 tok/s；热态命中率上来后 >100） | 腾 7.5G 显存 → KV 可 q8_0/双槽/长上下文 |
| A1' 保守 | `-ncmoe 999 --moe-cache-mib 4096` | ~5G | 预计 60-110 | 更稳，缓存覆盖 34% |
| A2 半卸载 | `-ncmoe 19`（前 19 MoE 层专家进 CPU）+ cache 2G | ~9-10G | 介于两者 | 调优备选 |

**为什么坑 #32（moe-cache 证死）不能直接套到本模型**：Qwen3.8-125B 专家 40.9 GiB、3 GiB 缓存覆盖 7.5% → 命中率≈0、tg 34.7→15.9 倒贴。本模型专家 12.05 GiB，**6 GiB 缓存覆盖 50%、8 GiB 覆盖 66%**；且 LFM2.5 top-4/64、带 expert_bias 路由（比 top-8/256 更集中），命中率有真实生存空间。**结论必须以实测定**：跑 §7 的 M1 矩阵，用 `[MoE cache]` 命中率遥测 + tg 判定，命中率高就转正、≈0 就放弃（照抄 #32 判据）。

**A1 附带红利——prefill**：ub 窗口内 unique expert 逼近 64/层（MiniCPM/Strata 同款 ub=2048 杠杆，Strata 报告 §三.2）。本模型专家 324 MiB/层，一个 ub2048 窗口每层最多重传 324 MiB，PCIe 5.0 摊薄后 prefill 影响 <20%；建议 `-b 2048 -ub 2048` 对比现 `-ub 512`。

### 3.3 明确不做

- **MTP/投机**：GGUF 无 NextN 头、LiquidAI 未发草稿头（同 MiniCPM5 DSpark 定案）。
- **换 IQ3/IQ4_XS**：QAD-Q4_0 是官方 QAT 甜点，更小的量化把质量换进了不该换的地方；体积问题智能加载已解决。
- **`--fit` + `-ngl 999` 并存**：语义矛盾（fit 会拒绝改用户显式值），A1 里给 `-ncmoe` 后如仍想保险可**去掉 `-ngl`** 让 fit 托管。

---

## 4. 平台 B：手机端 App（split-MoE 智能加载）

### 4.1 已有资产（全部现成，MiniCPM-V-4.7-35B-A3B 已跑通同链路）

| 环节 | 现状 | 代码 |
|---|---|---|
| 运行时：slot bank + top-k preadv + 合并读 + 异步延后 miss + 下一层路由预读 | ✅ 3.2k 行，成熟 | [llama-moe-slot.cpp](../third_party/llama.cpp/src/llama-moe-slot.cpp) |
| 解码窗口 LRU（每层 8 热窗+预读槽，prefill/decode 段物理分离） | ✅ | [qwen35moe.cpp 分组/window](../third_party/llama.cpp/src/models/qwen35moe.cpp#L77-L158) |
| GPU slot bank 雏形（`LLAMA_MOE_BANK_GPU=1` → OpenCL FGSVM，preadv 直写 + raw→plane kernel + batched GPU MoE kernel） | ✅（默认关，CPU bank 回退） | 同上 [#L50-L75](../third_party/llama.cpp/src/models/qwen35moe.cpp#L50-L75)；[OpenCL batched MUL_MAT_ID q4_0](third_party/llama.cpp/ggml/src/ggml-opencl/kernels/gemv_noshuffle_q4_0_f32.cl) |
| 打包产物形态：`-les` 主 gguf + `experts/layer_%03d.bin`（expert-major stride 重排，1 次 preadv/专家）+ manifest.json | ✅（MiniCPM 实测形态：layer bins 330 MB） | 样例 [manifest](../_probe/minicpm47_experts_manifest.json)；本机 `D:\myllm\models\MiniCPM-V-4.7-35B-A3B-split\` |
| App 下载/校验/加载路由（`splitMoe` 目录声明 → manifest+分片存在性检查 → JNI `moeManifest/moeBank`） | ✅ 通用（按 catalog 驱动，模型无关） | [model_provider.dart #L338-L413](../lib/providers/model_provider.dart#L338-L413)、[download_service.dart](../lib/services/download_service.dart)、[models_catalog.json splitMoe 段](../assets/models_catalog.json) |
| 内存自适应 bank（MemAvailable 倒推 bank 8-32，手动覆写入口） | ✅（有按模型缺陷，见 4.3③） | [model_provider.dart #L363-L395](../lib/providers/model_provider.dart#L363-L395) |
| lfm2/lfm2moe 架构本体（conv/attn 内核、ISWA 记忆、chat template、LFM2.5 JSON 工具调用协议） | ✅（App 已上架 2.6B/8B-A1B，真机日志 `_probe/logcat_lfm_live*.log`） | [lfm2.cpp](../third_party/llama.cpp/src/models/lfm2.cpp)、prompt_json_protocol |

### 4.2 本模型 delta（要做的事）

1. **lfm2moe 接入 slot 加载**（核心代码项，~1-2 天）：
   - `lfm2moe::load_arch_tensors` 的 `ffn_gate/up/down_exps` 改走 qwen35moe 同款 `create_routed_exps`（manifest 合成 → `virtualize_expert_tensor` → 分组 base + prefill/decode window，[qwen35moe 模板](../third_party/llama.cpp/src/models/qwen35moe.cpp#L134-L158)）；建议把这段抽 helper 共用。
   - [lfm2.cpp graph 的 build_moe_feed_forward](../third_party/llama.cpp/src/models/lfm2.cpp#L115-L127) 支持 pf/pf_dec 窗口选择（prefill 用共享 bank 窗、decode 用每层 LRU 窗）。
   - 运行时本身按张量名（`blk.N.ffn_{gate,up,down}_exps`）驱动，lfm2moe 命名一致，llama-moe-slot 无需改。
   - 注意 tied output：`output = TOKEN_EMBD DUPLICATED`，GPU 侧多 0.25 GiB，预算计入。
2. **打包脚本 `pack_lfm25_split.py`**（~0.5 天）：解析 Q4_0 gguf → expert-major stride 重排 38 个 `layer_%03d.bin`（**324 MiB/片，38 片 = 12.05 GiB**）+ manifest（`bytes_per_expert=1769472`/族、`expert_stride=5308416`）+ `-les` 主 gguf（0.62 GiB，删 114 个 exps 张量）。本机即产即验（先 PC llama-cli 加载 split 版对拍 logits）。
3. **catalog 新条目** `lfm2.5-24b-a2b-q4_0-split`：主 gguf + mmproj 无 + `splitMoe{layerBinCount:38, layerBinSizeMB:324, pattern experts/layer_%03d.bin}` + mirrors（ModelScope 需建 zerg13 同款仓）+ `agentCapabilities{nativeToolCall:true, maxContextTokens:131072, mtpSupported:false}` + 标签「超大MoE/拆分流式/实验」。下载链路零改动。
4. **GPU FGSVM slot bank 真机门**（`LLAMA_MOE_BANK_GPU=1`）：Adreno OpenCL 前台 SVM 可用性实测；不可用自动回 CPU bank（计算退 CPU，速度腰斩——这是"全 GPU 卸载"在手机上的成立条件，必须在验收单列）。App 需把该开关透传（现仅 env，App 层未接线，`android/` 内 grep `LLAMA_MOE` 为 0 处）。

### 4.3 按模型化的内存核算修正（3 处，都是 MiniCPM 常量硬编码）

> **2026-10-16 实施记录**：① 改为 Dart 从 manifest 求 Σ`bytes_per_expert`（即
> 单槽全层驻留）经 channel `moeSlotBytes` 传入 JNI，替代常量（MiniCPM 同公式，
> 估算从 1.35MB/槽×bank 修正到 51.56MB/槽×bank）；② 改为新增公共 API
> `llama_model_n_expert_used()`（fork 增量），JNI 两处除数取运行期 k；
> ③ **复核后无需改**：`_moeSlotBytesFromManifest` 本来就对全部 entries（层×family）
> 求和 = 单槽全层字节，MiniCPM 51.56 MiB / LFM2.5 192.4 MiB，公式自动落位
> （12G 小米13 自动 bank≈14-17）。另修 `scripts/experts.py`：bin 改按 MoE
> 顺序编号 layer_000..037（app 快检按 [0, layerBinCount) 探测，绝对层号 002..039
> 会判分片不完整；MiniCPM 全层 MoE 命名不变），verify 子命令文件句柄 dict bug 修复。

| # | 位置 | 现值 | 问题 → 修正 |
|---|---|---|---|
| ① | [JNI oom-guard `weights_est += moe_bank × 1351680 + 256MiB`](../android/app/src/main/cpp/tongyilite_jni.cpp#L702-L703) | 1,351,680 B = MiniCPM expert stride | LFM2.5 = **5,308,416 B 且 bank 常驻按层乘**（见③）。改：从 manifest 读 `expert_stride` × 层数 × bank |
| ② | JNI `max_pass = moe_bank / 8`、`cap = moe_bank/8 - 3`（[#L821-L835, #L998-L1002](../android/app/src/main/cpp/tongyilite_jni.cpp#L821)） | 按 top-k=8（MiniCPM） | LFM2.5 top-4 → 除数改 `n_expert_used`（运行期从 hparams 取） |
| ③ | Dart 自动 bank 公式 `bank = clamp(8, 0.8×budget/slot_bytes, 32)` | ~~未乘 MoE 层数~~ 复核：slot_bytes 已是全层求和 | 无缺陷（helper 对 层×family entries 求 Σ`bytes_per_expert`，天然含层数）；不改 |

### 4.4 机型预算表（bank 按修正后公式自动落位）

| 机型（MemAvailable 典型） | dense 常驻(GPU) | bank 常驻 | KV@8K+conv+运行时 | 可行性 |
|---|---|---|---|---|
| 8 Elite 16G（≈9-10G） | 0.87G（含 tied dup） | bank 16 → 3.1G | ~0.9G | ✅ 主目标，可试 FGSVM |
| 小米13 12G（≈6-7G） | 0.87G | bank 8 → 1.54G | ~0.8G | ✅ 偏紧，bank 8 起步 |
| 11G 机（≈3.5-5G，bonsai2 案机型） | 0.87G | bank 8 → 1.54G | ~0.8G+LMKD 余量 | ⚠️ 边缘，oom-guard 应拒或降 bank<8（下限=4，需扩 clamp）；建议直接推 8B-A1B 整包（catalog 已有） |
| Mali（天玑）各机 | — | — | — | ❌ 首轮不支持（OpenCL 定制内核全按 Adreno，AGENTS 既有结论） |

---

## 5. 手机性能预估（模型 + MiniCPM 同机制锚点）

每 token 专家流：152 片 × 5.06 MiB = **769 MiB（冷）**；MiniCPM-4.7 同 runtime 实测（[_probe/adb_r12d.txt](../_probe/adb_r12d.txt)）：
- 冷启动 decode `miss≈150-180/320, pread_wall 128-156ms, realio 2.0-2.8 GB/s`；
- LRU 热窗收敛后 `miss=0, pread=0`（重复前缀）；异步预读把 pread 折进 GPU 计算窗。

换算 LFM2.5（top-4 流量比 MiniCPM top-8 少约一半）：

| 态 | 每 token 实流 | UFS4.0 @3.5-4.5GB/s | 预计 decode |
|---|---|---|---|
| 冷（首轮长文） | ~700 MiB | 160-200ms 读（部分与 GPU 重叠） | **4-7 tok/s** |
| 常规对话（bank8 + 预读） | ~250-400 MiB | 55-110ms | **8-14 tok/s** |
| 热窗命中（短上下文重复） | <100 MiB | <30ms | **15+ tok/s**（GPU 计算 30-60ms 成主项） |

prefill：dense 全 GPU + 每 ub 窗口每层至多 324 MiB 流式 → 预计 **60-150 tok/s**（GPU conv/注意力 dense 部分计算占主），长文首 token 体验差于 PC 一个数量级——预期管理要写进 App 模型说明。

---

## 6. 分阶段实施计划

| 阶段 | 内容 | 产出/验收 |
|---|---|---|
| **P0 打包（PC，0.5d）** | `pack_lfm25_split.py` 产 -les + 38 bins + manifest；PC fork 版 llama-cli 加载 split 版 vs 原 gguf 对拍（greedy 前 64 token 一致） | 产物 + 对拍日志 |
| **P1 PC 智能加载矩阵（0.5d）** | §7 M1：A0/A1/A1'/A2 × {tg, pp, 显存曲线, cache 命中率}；判据照 #23/#31/#32 | 决策：A1 转正或证死留档 |
| **P2 lfm2moe slot 移植（1-2d）** | §4.2-1；宿主先验（用 fork 编 Windows 版跑 split 包），再上 Android | fork 回归：MiniCPM4.7 split 不回归（同 bank 同 prompt tg 差 <5%）+ lfm2moe 整包（非 split）路径字节级不变 |
| **P3 手机端到端（1d + 真机）** | catalog 条目 + 上传 ModelScope + 4.3 三处修正 + FGSVM 开关接线；8 Elite 16G 与小米13 12G 各跑 §7 M2 | oom-guard 参数门 logcat diff（bank/stride 正确）、死机零发生（dropbox 无 pre_watchdog）、tg 落 §5 区间 |
| **P4 收敛发布** | bank 默认公式定档、模型说明文案（含"实验"标签与首 token 预期）、AGENTS.md 记忆条目 | 覆盖安装（`adb install -r`，勿卸载） |

## 7. 实测矩阵（验收门）

**M1 · PC**（每次只起 1 实例；每组 3 轮取中位；用 `_bench_lfm25_32k.py` 扩参）：

| # | 配置 | 看什么 |
|---|---|---|
| M1-0 | 现状 A0 | 基线复现 152-157/1900 |
| M1-1 | `-ncmoe 999 --moe-cache-mib 6144` | tg、cache 命中率（b11539 `llama-moe-cache` 遥测）、显存峰值 |
| M1-2 | 同上 `--moe-cache-mib 8192 -c 393216 kv q8_0` | 智能加载红利（更大/更精 KV）是否净赚 |
| M1-3 | A1 + `-ub 2048` | prefill 重传摊薄效应 |
| M1-4 | `-ncmoe 19`（半卸载） | 折中点 |

**M2 · 手机（8 Elite 16G）**：`smartMoe` 开/关各一遍；记录 `[moe-ssd] decode` 的 miss/pread_wall/realio、`[oom-guard]` 决策、bank 自动值、tg（App 统计 + logcat）；重复前缀热窗、冷长文、工具调用回合三种负载。**FGSVM on/off 成对对比**（CPU bank vs GPU slot 计算）。

**通过标准**：无整机死机/无 lmkd 杀（dropbox 干净）；16G 机 tg ≥8；对拍 P0 一致；MiniCPM 回归不劣化 >5%；`handleLoadModel` 日志参数与 §4.3 修正公式逐项吻合。

## 8. 风险与回退

| 风险 | 缓解 |
|---|---|
| lfm2moe slot 移植踩 ISWA/conv 状态交互 | 分两段验：先 `bank=n_expert_used`（最小窗）纯功能，再放大 bank 调性能；lfm2moe 整包路径（非 split）保持原字节不动 |
| Adreno 无 FGSVM → 手机退 CPU 计算 | 已内建 CPU bank 回退；验收单列该项，失败不阻塞发布（功能可用、速度降级） |
| bank 公式修正引发 MiniCPM 行为变化 | clamp 下限用 `n_expert_used`，MiniCPM 16G 上修正后 bank 仍 ≥ 现值；回归 M2 同 prompt 对比 |
| PC A1 命中率证死 | 照 #32 处理：留档、A0 保持生产；不再加码 |
| 11G 机型误装 | catalog `minRamMB:16384` + oom-guard 真闸；11G 用户导向 8B-A1B |
| ModelScope 分片传输截断（Range 坑，Strata #327） | 下载器已有精确字节校验；上传侧给每 bin 的 sha256 清单 |

---

### 附：本评估引用的关键一手证据

- `D:\myllm\logs\lfm25_8090.log`（当前全载实测与 fit 行为）；`D:\myllm\start_lfm25_q4a_8090.bat`
- GGUF 元数据（本会话解析：40 层/64E/top4/stride/量化混合）；HF config.json（layer_types 10 attn/30 conv）
- StrataLike 复盘（坑 #23/#26/#31/#32/#327、ub=2048 杠杆、moe-cache 证死边界条件）：`D:\myllm\reports\StrataLike_工作汇报_2026-10-12.md`
- MiniCPM-V-4.7 split 实机 `[moe-ssd]` decode 计数：`_probe/adb_r12d.txt`、`_probe/adb_dev2.txt`；manifest 样例 `_probe/minicpm47_experts_manifest.json`
- 代码：[llama-moe-slot.cpp](../third_party/llama.cpp/src/llama-moe-slot.cpp)、[qwen35moe.cpp](../third_party/llama.cpp/src/models/qwen35moe.cpp)、[lfm2moe.cpp](../third_party/llama.cpp/src/models/lfm2moe.cpp)、[tongyilite_jni.cpp split-MoE 段](../android/app/src/main/cpp/tongyilite_jni.cpp#L529-L539)、[model_provider.dart bank 公式](../lib/providers/model_provider.dart#L363-L395)
