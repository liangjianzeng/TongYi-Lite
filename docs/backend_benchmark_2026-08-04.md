# TongYi-Lite 推理后端性能实测报告

> **测试日期**：2026-08-04
> **测试设备**：Xiaomi 25053RT47C（Android 16 / API 36，Snapdragon 8 Elite + **Adreno 825**）
> **App 版本**：V0.1.3（llama.cpp 内置 b10176；推理管线 `flash_attn=DISABLED`、`n_ubatch=16`、`sampler: penalties→top_k(128)→top_p(0.9)→temp(0.8)→dist`、每轮 `llama_sampler_accept`）
> **测试模型**：`qwen3.5-4b-q4_k_m.gguf`（Qwen3.5-4B，Q4_K_M，params≈4.21B，n_embd=2560，n_layer=32，约 2.5 GB）
> **上下文**：n_ctx=4096，GPU 层数 n_gpu_layers=100（全卸载）

---

## 1. 测试目的

厘清本机（Adreno 825）上 **Vulkan / OpenCL / CPU** 三种推理后端的真实性能差异，回答两个工程问题：

1. 之前被误判为"在 Adreno 825 上崩坏"的 Vulkan 后端，实际是否可用、性能如何？
2. GPU 后端（Vulkan / OpenCL）相对纯 CPU 到底快多少，Vulkan 与 OpenCL 谁更优？

---

## 2. 测试方法

- 三组后端各测 3 轮，每组使用**同一固定长 prompt**（关于 AI 发展脉络 + Transformer 技术突破的阐述题，约 80 字）。
- 切换后端必须**重新加载模型**才生效（Vulkan→OpenCL 在 19:55:17 重载；OpenCL→CPU 在 19:57:06 重载，`enableGpu=false`）。
- 指标从 App 的 JNI 日志 `Generation done: N tokens, X.X tok/s (prompt Pms, gen Gms)` 抓取：
  - **tok/s** = 解码吞吐（纯生成速度，与历史上下文无关，最可信）
  - **prompt Pms** = 首 Token 延迟 / prefill 耗时（受多轮对话上下文累积影响，本测试未每轮清上下文，**仅作参考**）
  - **gen Gms** = 纯生成耗时
- 数据来源：真机 `logcat`（`TongYiLite` tag，pid 28258），原始行见附录。

---

## 3. 原始数据

| # | 后端 | tokens | tok/s | 首Token(prefill) | 生成耗时 |
|---|------|-------:|------:|-----------------:|---------:|
| 1 | Vulkan | 10 | 8.5 | 460 ms | 1173 ms |
| 2 | Vulkan | 229 | 8.7 | 912 ms | 26248 ms |
| 3 | Vulkan | 113 | 8.6 | 5406 ms | 13149 ms |
| 1 | OpenCL | 36 | 8.7 | 319 ms | 4128 ms |
| 2 | OpenCL | 156 | 8.9 | 1191 ms | 17444 ms |
| 3 | OpenCL | 130 | 8.7 | 4485 ms | 14884 ms |
| 1 | CPU | 40 | 4.4 | 5228 ms | 9002 ms |
| 2 | CPU | 157 | 4.3 | 4051 ms | 36733 ms |
| 3 | CPU | 79 | 4.3 | 16110 ms | 18476 ms |

---

## 4. 后端汇总（3 轮均值）

| 后端 | 解码吞吐 (tok/s) | 首Token 均值 | 相对 CPU |
|------|----------------:|-------------:|---------:|
| **Vulkan** | **8.60** | ~2259 ms* | ~2.0× |
| **OpenCL** | **8.77** | ~1998 ms* | ~2.0× |
| **CPU** | **4.33** | ~8463 ms* | 1.0× |

\* 首Token 受多轮上下文累积污染（对话越长 prefill 越慢），组内方差大，故标 *，不用于严格横向对比。

---

## 5. 结论

### 5.1 Vulkan 后端完全可用（推翻旧误判）
本次实测 Vulkan 全程输出合法中文、模型自报身份正确（"我是 Qwen3.5"）、无任何 padding-token 塌缩、无崩溃、无异常。此前"Vulkan 在 Adreno 825 上崩坏 = Qualcomm 驱动 bug"的结论是**误判**——当时看到的输出塌缩实为 `n_ubatch=512` 垃圾 logits + 缺 `llama_sampler_accept` 退化循环所致，与后端无关。修复后 Vulkan 正常。

### 5.2 Vulkan 与 OpenCL 性能等价
解码吞吐 8.60 vs 8.77 tok/s，OpenCL 仅快约 2%，**无实质差异**。这与"行业 Vulkan 通常 ≈1.7× OpenCL"的普遍结论不同，原因应是：
- Qualcomm 自家 **OpenCL 驱动高度优化**，而 Vulkan 驱动相对保守；
- 4B 模型 GPU 计算压力不足以让 Vulkan 的异步/并行优势显现（换更大模型可能拉开差距）。

→ 本机 **Vulkan 与 OpenCL 可任选，无需偏袒**。

### 5.3 GPU 后端相对 CPU 约 2 倍
解码吞吐上 GPU（Vulkan/OpenCL ≈8.7 tok/s）约为纯 CPU（4.33 tok/s）的 **2 倍**；首Token 延迟上 CPU 明显更慢（均值 8.5s，单轮即 5~16s），GPU 仅 2~5s，差距更大。功耗未测（一般 GPU 更省电）。

### 5.4 对 App 默认后端的建议
- 本机默认走 **OpenCL 或 Vulkan 均可**（当前 App 默认 OpenCL，经验证正确，无需翻转）。
- 纯 CPU 模式仅适合无 GPU 驱动的设备兜底，体验差一半。

---

## 6. 27B 模型专项对比（Vulkan vs OpenCL）

为验证大模型下两 GPU 后端的差异，使用 `bonsai-27b-q1_0.gguf`（Bonsai-27B，Q1_0 量化，约 3.5 GB，params≈27B）复测，方法同第 2 节。

### 6.1 原始数据

| # | 后端 | tokens | tok/s | 首Token(prefill) | 生成耗时 |
|---|------|-------:|------:|-----------------:|---------:|
| 1 | Vulkan | 21 | 2.9 | 1602 ms | 7336 ms |
| 2 | Vulkan | 195 | 2.8 | 4416 ms | 68562 ms |
| 3 | Vulkan | 55 | 2.8 | 23584 ms | 19570 ms |
| 1 | OpenCL | 12 | 2.9 | 1611 ms | 4165 ms |
| 2 | OpenCL | 33 | 2.9 | 3997 ms | 11513 ms |
| 3 | OpenCL | 94 | 2.8 | 8401 ms | 33083 ms |

### 6.2 汇总

| 后端 | 解码吞吐 (tok/s) | 相对同后端 4B |
|------|----------------:|--------------:|
| Vulkan (27B) | **2.83** | ~33% |
| OpenCL (27B) | **2.87** | ~33% |

### 6.3 结论

- **Vulkan 与 OpenCL 在 27B 上仍等价**（2.83 vs 2.87 tok/s，差 ~1.4%），延续 4B 结论。
- **27B 解码吞吐约为 4B 的 1/3**（~2.85 vs ~8.7 tok/s），符合模型规模放大带来的算力/带宽压力。
- **Vulkan 在 27B 上同样未崩坏**：3 轮生成均正常完成、无异常、无 padding-token 塌缩（日志可见稳定的 2.8~2.9 tok/s 正常输出）。这进一步确认此前"Adreno 825 上 Vulkan 崩坏"为误判——当前 JNI 里仍残留的 `已选择 Vulkan 后端（注意：本设备 Adreno 825 上输出可能崩坏）` 警告已不准确，**应在打包时删除**。

---

## 7. 局限与后续

- **首Token 数据不可严格横向比较**：本次未每组每轮"新建对话"，历史上下文累积污染了 prefill 时间。如需精确 prefill 对比，需重测时强制清空上下文。
- **仅测了 4B 模型**：小模型（2B）/ 大模型（27B）下三后端差距未必相同，尤其 27B 更能压满 GPU，可能拉开 Vulkan 与 OpenCL。
- **功耗未量化**：续航差异待专项测试。
- **CPU 组 `gpuBackend` 字段仍为 opencl**：JNI 仅在 `enableGpu=true` 时按 backend 选设备，纯 CPU 路径不受该字段影响，记录无歧义。

---

## 附录：原始 logcat 摘录

```
19:54:04.717  Generation done: 10 tokens, 8.5 tok/s (prompt 460ms, gen 1173ms)     # Vulkan R1
19:54:37.072  Generation done: 229 tokens, 8.7 tok/s (prompt 912ms, gen 26248ms)   # Vulkan R2
19:55:08.089  Generation done: 113 tokens, 8.6 tok/s (prompt 5406ms, gen 13149ms)  # Vulkan R3
19:55:17.672  [handleLoadModel] ... enableGpu=true, gpuLayers=100, gpuBackend=opencl
19:55:17.673  [onLoadingLog] 已选择 OpenCL 后端
19:55:46.976  Generation done: 36 tokens, 8.7 tok/s (prompt 319ms, gen 4128ms)     # OpenCL R1
19:56:10.684  Generation done: 156 tokens, 8.9 tok/s (prompt 1191ms, gen 17444ms)  # OpenCL R2
19:56:34.770  Generation done: 130 tokens, 8.7 tok/s (prompt 4485ms, gen 14884ms)  # OpenCL R3
19:57:06.583  [handleLoadModel] ... enableGpu=false, gpuLayers=100, gpuBackend=opencl
19:57:06.584  GPU acceleration disabled by user -> pure CPU
19:57:33.383  Generation done: 40 tokens, 4.4 tok/s (prompt 5228ms, gen 9002ms)    # CPU R1
19:58:21.375  Generation done: 157 tokens, 4.3 tok/s (prompt 4051ms, gen 36733ms)  # CPU R2
19:59:08.703  Generation done: 79 tokens, 4.3 tok/s (prompt 16110ms, gen 18476ms)  # CPU R3
```

---

*本报告由 TongYi-Lite 工程会话实测整理，数据均取自真机 logcat，未做人工修饰。*
