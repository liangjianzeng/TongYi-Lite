# NPU 线 · MiniCPM5-2B 整模型 HTP 验收（2026-11-09）

> **里程碑：catalog 原版权重（`minicpm5-2b`，Llama 架构 GQA 42 层）fp16 在 740（SM8550/V73）
> QNN/HTP 整模型跑通——logits vs torch fp32 ref cos 0.9999、top-6 token 完全一致。**
> 本文自包含：根因判决、修复、分层链配方、复跑指引、通用教训。台账真源：
> `E:/MyLLM_exp/_repro/rb/W4_verdict.md`（C37-9y 补1–补5）。

## 0. 一句话根因

**QNN HTP 后端的 `Expand` 算子计算错误**（不是校验死局——是**悄悄算错**，输出 ~1e-6 垃圾）。
HF `repeat_kv`（`expand + reshape`）导出 ONNX 后是 Expand 节点 → 每层 GQA 的 k/v 被碾成零 →
QK^T≈0 → softmax 均匀 → attention 全废 → 整模型 cos 0.35。MLP 满分、attention 烂、
每层均匀烂（0.71–0.85）全部由此解释。

**修复（三行，`E:/MyLLM_exp/_repro/rb/qnn_gqa_patch.py`）**：

```python
def _repeat_kv_gather(hidden_states, n_rep):
    if n_rep == 1: return hidden_states
    kv = hidden_states.shape[1]
    idx = torch.arange(kv, device=hidden_states.device).repeat_interleave(n_rep)
    return hidden_states.index_select(1, idx)   # trace 成 ONNX Gather
import transformers.models.llama.modeling_llama as lm
lm.repeat_kv = _repeat_kv_gather
```

ORT 等价 maxdiff 0.0；device k 输出从 1.5e-6 → **8.65625 与 ORT 逐位一致**。

## 1. 判决证据链（逐刀定位，9 个手术探针图）

| 探针（切点） | device vs ORT/torch | 判决 |
|---|---|---|
| softmax 隔离：dev_pre 喂 numpy softmax vs dev_post | **1.0000** | softmax 无罪 |
| QK^T 输入 q（post-rope） | 6.47265625 **逐位同** | q 支路无罪 |
| k_norm 输出 div_2 | 10.3203 ≈ ORT | RMSNorm sqrt/div 无罪 |
| k_proj matmul 输出 view_5 | 8.65625 **逐位同** | 权重/matmul 无罪 |
| k rope 输出 add_12 | 8.65625/1.06389 **逐位同** | rope 无罪 |
| k Expand 输出 transpose_8 | **1.5e-6** | **Expand 定罪** |

辅助铁证：随机输入喂 l1pre 仅引起 1e-6 响应（增益碾碎而非输入断线）；pre-softmax 分数
RAIL=1920 = causal mask（finfo.min）两边一致；ARGMAX 0.875 = 分差 0.1–0.6 的赢家翻转。

## 2. 分层链配方（整模型如何绕过 4GB 单 ctx 墙）

单 ctx 需 4.2GB fp16 权重 → converter cpp 文本管线不可行（>4GiB 官方 uint32 bug 同源）。
解法 = **每图一 ctx，设备端串 raw**：

- 导出（`mcp5_41_layered.py`，MODE=all 单进程全 44 图）：
  div_norm(fp32 upcast) + qnn_gqa_patch 双补丁；层图必须走 **replacer 重放模式**
  （模型内重跑 + 换入层输入），直接 `torch.onnx.export(layer)` 会撞 transformers 5.x
  tensor subclass `.numpy()` 禁令；**导出前必须摘除捕获 hooks**。
- 构建（`mcp5_29_build_deepk.sh`，4 并发）：`qnn-onnx-converter --float_bitwidth 16
  --float_bias_bitwidth 16 --disable_defer_loading` → cpp/objcopy/g++ → 
  `qnn-context-binary-generator` + `host_cfg_740.json`（**V73: soc_model 43, dsp_arch v73；
  误用 V79 config 建的 ctx 在 740 上 contextCreateFromBinary 0x138d**）。
- 设备链（`mcp5_43_ids.sh` 自动查每图输出 id → `devchain.sh`；`chain_run2` 位置参数式）：
  输入输出一律 **T-layout [1,2048,16] raw 线性直传**（converter 自动把 onnx [1,16,2048]
  翻成 HTP [1,2048,16]）。norm 输出是 natural [1,16,2048] → head 前需一次显式 transpose
  （分两段跑）。**chain_run2 只支持单输出图**（多输出图 graphExecute 0x1774）。
- 判分（`mcp5_44_judge.py`）：head_out.raw reshape(V,16).T 取末行 vs torch logits ref。

## 3. 验收数据（740 / SM8550 / V73）

| 判据 | 值 |
|---|---|
| 最终 logits vs torch fp32 | **cos 0.9999**（absmax 21.06 vs 21.08） |
| top-6 token | `[1, 396, 2570, 7562, 8, 85]` **完全一致**，TOP1 匹配 |
| 42 层链中段（norm 输出） | vs torch cos 1.0 |
| 42 层+norm QNN execute | 213.6 ms（层均 ~5ms，1.2–14.5ms） |
| head（vocab 130560）execute | 31.7 ms（≈277 GFLOPS fp16） |
| **PREFILL（SEQ=16）** | **≈ 65–75 tok/s**（纯 HTP 计算，不含 graph 创建） |

decode t/s 未测（需 KV-cache 链，见 §5）。830（V79）复测未做（同留 §5）。

## 4. 通用教训（升级交接档死路清单）

1. **HTP Expand = 计算雷区（不只是校验死局）**：凡 HF 导出含 Expand/Tile 的图
   （GQA repeat_kv、rope cache、beam）上 HTP 前必须换成 Gather/Slice 等寻址算子；
   长期项 = 建 QNN HTP **算子 device 对拍黑白名单**（每算子单层图 device vs ORT 判分）。
2. **HTP 无 fp32 岛**：`Precision custom config and fp16_relaxed_precision values are
   ignored in HTP backend`；Cast 在转换期折叠（`Only numerical type cast is supported`）。
   数值病不要用"升 fp32"思路修，从数学上移病态（本例：不是精度，是算子错）。
3. **判分布局**：device ctx 张量一律看 `qnn-context-binary-utility` 的 dims 声明；
   2D/3D 图输入 T-layout 与 natural 的 transpose 关系必须显式记账（本链仅 norm→head 一处中转）。
4. **chain_run3 弃用**（定罪），chain_run2 位置参数式为唯一可信 runner；
   输出张量 id 因图结构而异，binary-utility 查 id 是必步。
5. 临时物料只准 `E:\MyLLM_exp`（Windows）或 `/home/liang`（WSL）——C/D 盘禁放（C37-9z 铁律）。

## 5. 下一步

- **KV-cache decode 链**：每层拆 prefill/decode 双图（或动态 seq），逐 token t/s 才是
  闸门判据；届时与 Spark W4A16（交接档 §2 路线 A）合并设备侧基建（`run_dev_ctx.sh` 一族）。
- **830/V79 复测**：同套 ctx 用 `host_cfg_830.json` 重建即得 V79 弹药。
- **Spark-X2.6-4B 主靶**：MiniCPM 线打通的分层链/判分/运维件直接复用；Spark 的
  headwise sigmoid 门控与 3:1 滑窗是新算子风险面，先按 §4-1 建黑白名单再过主图。

## 6. 现场索引（全部保留可复跑）

| 物 | 位置 |
|---|---|
| 导出/构建/判分脚本 | `E:/MyLLM_exp/_repro/rb/mcp5_{40,41,42,43,44}_*.{py,sh}` + `qnn_gqa_patch.py` + `mcp5_29_build_deepk.sh` |
| 44 ctx 产物 | `E:/MyLLM_exp/serve/spark_l{0..41,998norm,999head}_ctx.bin` |
| 设备端 | `/data/local/tmp/npu_m1`（devchain.sh + d1.sh + 各层 L*_out.raw + head_out.raw） |
| torch refs | `/home/liang/mcp5_full_logits_ref.npy`、`mcp5_L{0..41,998}_ref.npy` |
| 判决过程台账 | `E:/MyLLM_exp/_repro/rb/W4_verdict.md` C37-9y 补2–补5 |

## 六、日常自测入口（2026-11-09 固化）

一条命令复跑整模型加载+判分：`bash tool/npu_selftest.sh`（740 USB 默认；换机 `DEV=<序列号>` 传参）。
前提：设备 /data/local/tmp/npu_m1 资产齐（缺则从 E:/MyLLM_exp/serve 重 push）、WSL Ubuntu-22.04 的 /home/liang 有 HF 参考 npy。
实测：44 层+norm+transpose+head 全链 ~1 分钟，判分 cos 0.9999 / TOP1_MATCH True 复现验收。
教训（本档根因系列的延续）：当年 devchain 生成器把 norm→head 显式 transpose 写丢过，
"分两段跑"才是真配方——selftest 脚本已把该步显式化并加布局铁则注释，勿回退成单段。

## 七、SEQ=128 大批量 prefill（2026-11-10）

**动机**：SEQ=16 是编译期定死的小批量（带宽 bound，~65 tok/s）；128-token 单次 forward 让 HTP 迁出带宽 bound。

**管线**（复用 42 层导出/构建配方，独立目录防撞）：`mcp5_46_layered_s128.py all`（SEQ=128 导出 46 图，ORT 等价 1.0）→ `mcp5_47_build_s128.sh` + `mcp5_48_batch_s128.sh`（4 并发构建，产物 `serve_s128/`）→ `mcp5_50_devchain_s128.sh`（生成 chain_run4 manifest，强制 norm→transpose→head 两段式）→ 设备 `chain_run4 manifest_s128`。

**740 实测（fp16）**：

| 口径 | SEQ=16 | SEQ=128 |
|---|---|---|
| 整链 HTP exec | 245-343 ms → 47-66 tok/s | 421-545 ms → **235-304 tok/s** |
| 整链 wall（46 进程 chain_run2） | 17.8 s | — |
| 整链 wall（chain_run4 单进程） | 6.0 s（**3×**） | 7.1 s |
| head exec | 32 ms | 42 ms（vocab 130560） |

**判分**：logits cos **1.0000**（absmax 17.66/17.59）、top-6 `[47744, 101715, 33917, 43258, 106306, 121414]` 逐位一致——s128 数值与 HF 全对齐。

**新工具**：`chain_run4.cpp`（单进程常驻 backend/device + manifest 驱动多段链，vs 46 进程 3× wall 加速；ctx 全驻留模式撞 HTP 内存池 0x3ea，不采用）。

**边界**：exec 421ms 距权重流理论下限（~88ms/forward ≈ 1450 tok/s）尚远，瓶颈是 mmap ctx 权重搬运效率；再往上走要 QNN 权重共享/TCM 驻留（M2 课题）。decode（KV-cache 链）仍是 App 可对话前的最大缺口。
