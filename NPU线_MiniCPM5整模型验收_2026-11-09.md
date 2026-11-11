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

## 八、Q4/W4A16 设备实测全案（2026-11-10）——免 pack 量化三档终局

**背景**：用户 Q4 诉求（体积/内存）；M1 会话 4B W4A16 单图 ctx（2.97GB）当年唯一缺角 = 设备实测。

**① 4B 单图 ctx 设备加载 = HTP 内存墙（0x3ea 实锤）**：md5 完好（dc919c3d…），qnn-net-run 与 chain_run4 两实现同判 createFromBinary 失败——单图 >~2GB 在 SM8550 上不可加载。M1"设备传输玄学"只是表层，拉全也过不了加载。**4B 也必须分层链**（本 2B 分层架构存在价值再 +1）。

**② 分层 W4A16/W8A16 配方全打通（新增件）**：层图权重被匿名化为 `val_N`（同名跨层冲突）→ **每层独立 enc.json**（`mcp5_52_gen_enc_w4.py`：图内 2D 权重按首次消费顺序对号 q/k/v/o/gate/up/down，从 HF safetensors 算 per-channel scale；`activation_encodings` 必须显式空 dict；int8 对称 offset 必须 -127 而非 int4 的 7；head/norm 不入 overrides 靠 --float_fallback 保 fp16）。构建器 `mcp5_53/56`、批量 `mcp5_54/57`、manifest 与判分同 s128 管线。注意 W4/W8 图 out tensor id=91（fp16=90），换图必查 json。

**③ 三档终局（740/SM8550，SEQ=128 整链 42 层+norm，head fp16）**：

| 方案 | 模型体积 | 整链 exec | tok/s | logits cos | top1 |
|---|---|---|---|---|---|
| fp16 | 4.3 GB | 421-545 ms | **235-304** | 1.0000 | ✓ |
| W8A16 | 1.9 GB | 1039-1072 ms | 119-123 | 0.9973 | ✓（top6 4/6 同） |
| W4A16 | 1.1 GB | 654-693 ms | 185-196 | **0.6539 ✗** | ✗ |

**④ 判决**：免 pack（SFIXED_POINT_8 容器 + HTP 运行时解包）是 exec 负优化（fp16 10ms/层 → W4 15 → W8 23）——解包开销 > 权重流收益，Q4 提速预期被推翻。**App NPU 后端建议：fp16 为默认（速度+精度双优），W8 为体积敏感场景备选（123 tok/s 仍为 GPU 基线 33 tok/s 的 ~3.7×）**；W4 不可用（精度崩），原生 int4 要 `--pack_4_bit_weights`（SFIXED_POINT_4），QAIRT 2.44 硬拒，升 SDK 版本是后续课题。GPU 基线（台账 leg 273）：740 OpenCL 4B Q4 pp512=33.2 tok/s。

**工具索引**：`E:/MyLLM_exp/_repro/rb/mcp5_52…57`（enc 生成/构建/批量）、`serve_w4/ serve_w8/`（42+42 ctx）、设备 `/data/local/tmp/npu_m1/manifest_w4 manifest_w8`。

## 九、decode（KV-cache 链）抢救与端到端贯通（2026-11-10）

**背景**：「decode 是 App 可对话前的最大缺口」。前会话 decode v1（mcp5_58）报过 "v1 cos=1.0" 里程碑——本次回顾（db.sqlite 原始会话）定性为**自指判分**：设备对拍的参照是同族手写模块的 ORT 运行，三者同错即满分。挖出三重真错：① block 违反 HF pre/post-norm 结构；② 手写 rope 表 theta=10000 与模型不符（HANDROPE_DIFF max=1.97，knew vs-HF 仅 0.56，但被 NC+1 行缓存稀释在 h 里看不见）；③ GQA 用 repeat_kv Expand/Gather 实体化 [1,16,NC,128]，NC=512 时单层 exec ~100ms。

**① dec2 图（mcp5_63）设计**：块结构镜像 HF LlamaDecoderLayer（pre-norm attn / post_attention_layernorm MLP / 残差不归一化）；逐 kv-head 两个 4D matmul + stack 消灭 Expand/Gather；**kcache/vcache 只读输入 + 只发射新行**（cache-row 字节序 [1,1,HD,NKV]），drop-oldest+append 由宿主 chain_run5 ROLL 完成；rope cos/sin 走模型 rotary_emb 真值表（graph 输入 + 每步 stride）。**全 42 层 vs 真 HF 层：h=k=v=1.0000**。

**② 内存墙与 3 进程架构**：fp16 42×~95MB ctx ≈ 3.95GB > HTP 常驻池；实测池为**每进程 ~2.3GB**（24×95MB 过、25 撞 0x3ea；双并发进程各 2.28GB 全过 = 按进程隔离）→ **拆 3 驻留进程 A=l0–13 / B=l14–27 / C=l28–41+norm+head（各 ≤1.9GB）**，hs 中继 4KB/token 走共享文件，文件计数器闸门（CR5_GATE）锁步三进程。设备端 launcher 必须是脚本文件（内联 `cd && j0 & j1 & j2` 只给 j0 绑 env，兄弟进程死无对证——坑 39）。

**③ 判分（两协议两口径）**：
- **数值对拍**（随机初始 + hidden 中继，设备/参照同协议自洽）：4 步 cos 0.9953（argmax 同）、6 步 0.9758（argmax 同）、8 步 0.9267；ORT 同图三方参照 8 步对 HF 0.9947/top8 8/8 → 图语义干净，设备掉分定性为 **HTP fp16 在分布外对抗初始下的累积数值**，无状态破坏（曲线平滑无断点）。
- **真协议 e2e（产品口径，mcp5_72/69）**：512 token 真实中英 prompt 走 HF 前向出 cache/hs0，8 步 **teacher-forcing**（每步注入参照 embed——坑 40：步间输入是采样 token 的 embedding，不是上一步 hidden）。**结果 cos=1.0000、argmax 1753/1753、top8 8/8**。HF 参照链自身 sanity：贪心续写复述 prompt 原文（重复嵌入下行为正确）。

**④ 性能与定位（740/SM8550）**：单层 exec 11.0–12.6ms@NC512（NC=128 对照同档 → **注意力 op 非瓶颈，权重流是地板**：95MB@~9GB/s≈10.5ms）；驻留稳态 token 时间 ≈ **630ms（1.5–2.5 tok/s）**，exec 串行和 ≈580ms（A/B 各 ~170 + C 240 含 head ~60）。同表：**prefill fp16 235–304 tok/s（§七）** vs decode 1.6–2.5；GPU 基线 OpenCL 4B-Q4 pp512=33.2。**结论：NPU 线价值锚在 prefill，decode 打不过 GPU 是结构性结论（权重流 × 单 die 面积），App 正确形态 = NPU prefill + GPU decode 混合调度；纯 NPU 低功耗 decode 待 M2 功耗数据再评（候选杠杆：W8 decode 权重减半→理论 ~2×、多层融合减 launch 税）**。

**⑤ 必缺件与后续**：**prefill 图不输出 KV cache——真对话的第一块缺件**（prefill 后 decode 无从续链；ADR-2 早已定性 KV 桥必须直写 buffer）。后续四件：a) KV-output prefill 变体（输出滚动 cache 布局）；b) W8 decode 实测；c) 多层融合减 launch/流税；d) M2 功耗判 NPU decode 存续价值。

**工具索引**：`mcp5_63_export_dec2.py`（dec2 导出+vs-HF 判分）、`mcp5_65_build_dec2.sh`/`mcp5_67_batch_dec2.sh`（构建/批量）、`mcp5_68`（数值对拍参照）、`mcp5_70`（ORT 三方）、`mcp5_71_judgeN.py`（逐步判分）、`mcp5_72_real_prep.py`（真 prompt 参照+feed）、`chain_run5.cpp`（ROLL+闸门+reseed，坑 42/43 已修）、`dump_ids.sh`（ctx 张量 id 反查）；产物 `E:/MyLLM_exp/serve_dec/`（42+2 ctx，4.5G）、设备 `/data/local/tmp/npu_m1/{manifest_dec2_A,B,C,launch3.sh}`。运行入口 `bash mcp5_69_run_full_dec2.sh`（STEPS 可控，含推送/闸门/判分全流程）。

## 十、prefill KV 输出（chunked-prefill pre2）设备贯通（2026-11-10）

**背景**：§九 定性的「真对话第一块缺件」——prefill 图不输出 KV cache。本节：pre2（S=128 分块 prefill 图：cache 只读入 + 每步发射 S 新行 + 图内 mask）从导出到 740 设备端到端的验收。

**① 图语义（mcp5_63 DEC_S=128）**：同 dec2 家族（HF 镜像块结构 / 逐 kv-head 分组 matmul / cache 只读 + ROLL 宿主滚窗），两处 prefill 专属：
- **amask[1,1,S,NC+S] 图输入（-1e4 加法 mask）**：零 pad 窗口行必须屏蔽（否则 softmax 分母虚增 chunk0 5×），chunk 内因果三角必须给（HF layer 级 `attention_mask=None` = eager 全连——参照与设备同错即自洽的暗坑）。广播加走 HTP bias 路（无 Expand 雷区），exec 代价 12→30ms/chunk。
- **proj view 布局修正（坑 44）**：HF 语义 `view(1,S,HEADS,HD).transpose(1,2)`；`view(1,HEADS,S,HD)` 只在 S=1 恒等——decode 线 42 层全绿掩藏到 pre2 才爆（同坑 37 恒等假象族）。
- 修后 **42/42 层 vs 真 HF 层 k=v=1.0000**；h 沿深度 0.998→0.91（随机 OOD 输入的 fp16 数值带，非语义错——语义错是 ~0 不是 0.91；真分布判据在 e2e logits）。

**② 设备 IO 铁律（76c 探针定罪，坑 45）**：**APP buffer 字节序 = ctx 声明维 row-major**，声明 = onnx 维 dim1 挪尾（NHWC 化）：hs=(hid,s)、cos/sin=(hd,s)（**方阵也转**）、cache=(s,hd,kv)。S=1 decode 与方阵 dims 各自掩藏了一个自由度，pre2 第一次全暴露。探针法=单变量（vnew 不含 rope 先钉 hs）+ 候选读法 ORT 对号（knew 0.37→1.0000 一击定位）。

**③ 单层设备验收（mcp5_73/75/76，740/SM8550）**：4 chunk 单进程，零起 cache 宿主滚窗：每 chunk **knew/vnew vs HF 逐 chunk 新行 = 1.0000（absmax-diff ~0.002 fp16 粒度）**，终态 512 行 cache 全窗 = 1.0000，exec 28–30ms/chunk。滚窗/发射/判定闭环。

**④ 全链 e2e PASS（mcp5_77/79/79j，740/SM8550）**：真 512-token prompt（P0=88）4-chunk 分块 prefill，3 进程闸门驻留（A l0-13 / B l14-27 / C l28-41），每层宿主滚窗 cache，l41 末行 → host norm+head（decode 线已验组件）：

| 判据 | 值 |
|---|---|
| logits vs HF 全前向 | **cos 1.0000**（absmax 18.09 vs 18.05） |
| argmax / top8 | **一致（101715）** / **8/8** |
| l0 终态 cache vs HF | kc/vc **1.0000** |
| exec 关键路径 | 42 层×4 chunk ≈4.7s → **~116 tok/s**（mask 版单层 ~26ms vs 无 mask 10ms，broadcast-add 代价 ~2.5×，优化候选：mask 折叠/降维） |
| wall（含 42 ctx 启动税） | ~9.5s（驻留热态后只剩 exec） |

**⑤ 调试期间定罪的两大协议坑（坑 49/50，详见交接档）**：ao 布局三重掩蔽（S=1 恒等 + head-major 假相等 + **h 被 residual 主导**——判 h 必须配 attn 分支单判，BRANCH_{k}_COS 判据已入 mcp5_63）；**mask 窗口语义 off-by-one**（chunk c 执行时 cache 真值行数 = c·S 而非 (c+1)·S——参照与设备两侧同错即判分假绿，HF 层级 vs HF 全前向 0.8586 才是照妖镜）。

**⑥ prefill 终态 KV → decode 续链 PASS（2026-11-11，mcp5_8x 系列，工具与复跑入口 npu-line/probe_m1/dec2/DEC640.md）**：真对话 prefill 终态 cache（④ 产物 d2q_*）接 decode 图 8 步贪心续链——这是「真对话」全链（prefill→KV→decode）在 740 上的首次贯通。

关键障碍与解法：HTP **S=1 attention 内核在 K=513 非对齐列 × 特定 cache 数据（eos-heavy 77-prompt）probs 均匀化塌缩**（手工 softmax / K-split 旁路均无效，内核级；S=128 pre2 图与 72-prompt cache 不触发，坑 51）。解 = **NC=640 pad（512 真值 + 128 零行）+ 逐步 amask**：roll（drop-oldest+append）使零 pad 窗每步左移一行，故第 t 步必须 mask 注意力列 `[512-t .. 639-t]=-1e4`（新 token 列 640 常开）——静态/零 amask 皆错（坑 52）。

| 判据 | 向量 A（80-era 真对话，EOS 退化贪心链） | 向量 B（72-prompt 有意义贪心链） |
|---|---|---|
| 8 步 logits vs HF rolled-window greedy 参照 | **8/8 cos 1.0000** | **8/8 cos 1.0000** |
| argmax / top8 | 8/8 MATCH / 8/8 | 8/8 MATCH / 8/8（"清晰完整的回答。技术讨论应"） |
| exec | A 575ms / C 807ms（含 norm+head），wall ≈ 895ms/token | 同档 |

定罪链要点（坑 53/54，交接档）：首轮 FAIL 三连环——**跨 prompt 配对错**（wsl_stage 里 72-era feeds/refs 配 77-prompt cache，feeds/refs/cache 必须同代同 prompt，ORT-vs-HF host 回放 mcp5_86 是分钟级仲裁）；**stale d2e_hs_t0.raw 残留**（chain_run5 reseed 在 t=0 读 `d2e_hs_t0.raw`，旧代文件毒化第 0 步——启动脚本必须 `cp hs0→hs_t0` 规范化；顺序跑 vs 门控跑差异由此而来）；**零 amask 单层探针的自洽盲区**（设备|ORT 同图互证不证 HF 等价，真 mask + ORT/HF 锚缺一不可）。逐层扫（mcp5_89）与链式自喂扫（mcp5_90）构成「逐层无罪→链级定罪」的隔离阶梯。
