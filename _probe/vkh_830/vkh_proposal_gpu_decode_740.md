# GPU decode < CPU 头号案：每 token 路径定位与修复提案（只提案，产品码不动）

**档位与口径声明**：性能判词只出自 **740（小米13 / Adreno 740，主力+底线档）**；**K40（Adreno 650）只出结构性归因，不出 tok/s 判词**。三口径依 R-088：口径甲 = FA ON；口径丙 = App 真身（`--flash-attn off` + 无 FA env）；CPU = `-ngl 0`。

---

## 1. 判词（740 pass1，两轮复现）

| 口径 | 第一轮 | 第二轮 pass1 | buft CPU/GPU | enq_rows |
|---|---|---|---|---|
| **丙 App 真身** `--flash-attn off -ngl 99` | **0.9 t/s** | **0.9 t/s** | 0/1566 | 918 |
| 甲 campaign `--flash-attn on -ngl 99` | 0.9 t/s | 0.9 t/s | 0/1470 | 7794 |
| CPU `--flash-attn off -ngl 0` | 1.5 t/s ⚠️ | **6.7 t/s** | — | 0 |

- **R-088 作废的旧判词重新证实为真**：App 真身口径下 GPU 依然输给 CPU。
- **FA 与 App 案彻底分账**：甲 = 丙 = 0.9 t/s ⇒ FA 档位对 740 decode 无影响。FA 案只归"战役 FA-ON"与未来启用，**"关 FA"永远不是修法**（K40 实测：NO_FA 使 decode 恶化 34%，并新增 CONT 480 + SOFT_MAX 240 节点）。
- ⚠️ **CPU 参考值待复核（引信）**：第一轮 1.5 t/s 与第二轮 6.7 t/s 差 4.5 倍。6.7 对 8 Gen 2 跑 4B-Q4_K 是量级正确的数；1.5 那条腿 buft 报 GPU=980（capability probe），若其时确有 op 落在 GPU 上造成逐 token 跨设备搬运，则真实差距是 **0.9 vs 6.7 = GPU 慢 7.4×**，本战役头号判词需改写。复核动作：CPU 腿同时抓 `[buft-probe]` 逐 op 落地 + `kernels=` 是否为 0。

## 2. 归因（形状比数字锋利）

**丙口径下全部 19 个 op 类挤在 0.45–0.61 ms/node**，与 op 内容无关 ⇒ 每 token 的成本是**结构常数**，不是任何单个算子。740 每 token 907 次发射 ⇒ 提交循环 host 时间 491–577 ms/step（`[host-timing]`），占 0.9 t/s（1111 ms/token）的 44%。自洽校验：`GRAPH_TOTAL ≈ LOOP_TOTAL`（511.3 vs 511.3 ms/graph）⇒ 图级 prologue/epilogue ≈ 0；`Σop ≈ 环的 80%` ⇒ 每节点 forward 之前 ≈ 102 ms/token。

## 3. 定罪：门铃，不是装填（K40 mechanism-only，ENQ 子行）

仪表头 `vkh_instrument.h`（md5 `1ddf3bac`）+ 双钩子（HEAD `de7bbc8e`）。规则：`ENQ/<op>` 是 `<op>` 的**子行，禁与父行相加**；`ENQ/op ≥ 80%` ⇒ 门铃定罪。K40 / qwen2.5-0.5b-q4_k_m / `--flash-attn off -ngl 99`：

| op | host_ms | ms/node | `ENQ/<op>` ms | **ENQ/op** |
|---|---|---|---|---|
| MUL_MAT | 1156.5 | 0.533 | 982.5（2809 次） | **85 %** |
| ADD | 460.8 | 0.384 | 421.5 | **91 %** |
| SET_ROWS | 185.1 | 0.386 | 169.4 | **91 %** |
| ROPE | 184.3 | 0.384 | 168.9 | **92 %** |
| SOFT_MAX | 130.5 | 0.544 | 121.3 | **93 %** |
| CONT | 115.0 | 0.479 | 108.9 | **95 %** |
| GLU | 83.7 | 0.349 | 76.8 | **92 %** |
| GET_ROWS | 8.1 | 0.403 | 6.9 | **85 %** |

> ### ⚠️ 本节判词已撤回（R-091 A/B 推翻），保留仅作证伪记录 —— 见 §3b

`ΣENQ / LOOP_TOTAL = 4411 / 4807 = `**92 %** —— *（原文）*提交循环的 host 时间几乎全部发生在 `enqueue_ndrange_kernel`（L1365）内部。**此判词作废**：下表与 §3b 对照即见破绽 —— 同一批 2809 次 MUL_MAT 发射，`IDLE=2` 腿记 0.384 ms/发，`IDLE=0` 腿记 **0.051 ms/发**（相差 7.5 倍），而内层 `ENQ_DRV` 恒为 0.39–0.48 ms/发；内层大于其应有父行 8 倍、且嵌套的 `LOOP_TOTAL`(5333) > `GRAPH_TOTAL`(4902)（L9912 确实包住 L9924）—— **直方图违反可加性，属仪表缺陷，任何绝对 ms 归因都不可信**。仪表缺陷已修：`vkh_instrument.h` **v4**（md5 `252ae09d…`）把 `clock()`（进程 CPU 时间，含驱动线程，且共享 `std::map` 非线程安全）换成 `CLOCK_MONOTONIC` 墙钟 + `std::recursive_mutex` + 标签复原 + 可加性自检（详见 §3b 末"仪表可信度声明"）。**注意**：产品自带的 `[host-timing] host_ms` 亦为 `clock()`（L10279），只可作跨臂方向性对照；**真墙钟判据只有 tok/s 与 v4 直方图**。

## 3b. R-091 A/B：**门铃改判"自戕"** —— 每 2 发 `clFinish` 才是头号成本（K40 mechanism-only，墙钟判据）

`ggml-opencl.cpp` L1456 `idle_n` 默认 **2**（`atol(e): 2`，R-060 产品化的 H2′ 保险）+ L1459-1467：每 2 次成功 NDRange 就 `clFinish(queue)` 全队列排空（GAP=0）。decode 907 kernels/token ⇒ **~450 次排空/token**，host 与 GPU 之间零流水线。三口径所有历史腿从来都带着它跑，**性能面从未 A/B 过**。

**仪表 v4（墙钟 `CLOCK_MONOTONIC` + 递归锁 + 可加性自检）复测的同腿 A/B**（K40 / Adreno 650 / qwen2.5-0.5b-q4_k_m / 丙口径 `--flash-attn off -ngl 99`，同 prompt 同 `--temp 0`，仅 env 不同，2 rep 交替抑制温漂，batt 335 ℃；产物 `out/ab_k40idle3_*`、`ab_k40idle6_*`，日志 `ab3_run.log`/`ab6_run.log`。下表 ms 均为墙钟，非 CPU 时间）：

| 指标 | `IDLE=2`（默认，出厂形） | `IDLE=0`（关排空） | 判读 |
|---|---|---|---|
| **Generation（128 token 深探针）** | 1.5 / 1.5 t/s | **6.4 / 6.3 t/s** | **×4.2**（浅探针复现：1.6/1.7 vs 6.1/6.4/6.7） |
| `[host-timing] host_ms`/step（产品自带 `clock()` 口径，仅作方向性对照） | 450.2 | **190.8** | **−58 %** |
| `LOOP_TOTAL` / 节点 | 8226.7（0.920 ms） | **1389.5（0.155 ms）** | −83 % |
| `GRAPH_TOTAL` / 图 | 864.2 | 149.9 | −83 % |
| `ENQ_IDLE`（每 2 发一次排空） | **6844.5 ms / 3099 次 = 2.209 ms/次** | 整行消失 | 排空 = LOOP 的 **83 %** |
| `ENQ_DRV`（真·驱动门铃） | 1076.7 / 6199 = 0.174 | **1303.2 / 6199 = 0.210 ms/发** | 关排空后占 LOOP 的 **94 %** |
| `ENQ/MUL_MAT`（普通发射） | 1.252（含嵌套排空） | **0.161 ms/发** | 排空是其成本主体 |
| `ENQ/PRE_FORWARD`（暗区 490 发） | 1.834 | **1.124 ms/发 = LOOP 的 40 %** | 单价是同腿普通发射的 **7×** |
| CPU 参考 `-ngl 0` | 21.8 / 23.7 t/s | 18.9 / 23.4 t/s | GPU 仍慢 CPU ~3.5× |

排空次数 3099 = ⌈6199/2⌉，与 L1459 计数逻辑严格吻合（自证）。

**数值闸（H2′ 复发判定）**：128 token 贪心续写，六条腿（`idle2`×2、`idle0`×2、`cpu`×2）生成文本**逐字节相同**（md5 `77ad7420…`，与 CPU 参考一致）；浅探针（48 token）六腿亦相同（`4804f8d3…`）。⇒ **本案未观测到 H2′ 乱文**，但样本仅 0.5B/单 prompt/K40，**不足以宣布保险可拆**：修法定位为"**智能排空替代无脑每 2 发**"（节点/张量级依赖驱动的定向等待，保 R-060 治愈语义），而非删除保险。740 + 战役 4B + 多 prompt 数值闸是拆/留的最终裁判。

**墙钟下的三条结论（R-091/R-092）**：
1. **头号成本是自家人**：每 2 发一次的全队列 `clFinish`（2.209 ms/次 × ~450 次/token）吃掉提交循环 83 %，驱动门铃本身只有 **0.2 ms/发**量级 —— 原"门铃定罪 92 %"作废。
2. **排空之后才是真门铃**：`IDLE=0` 腿 LOOP_TOTAL 的 **94 %** 是 `clEnqueueNDRangeKernel` 自身（1303 ms / 6199 发）⇒ **减发射条数恢复主修位（P1）**，收益 ≈ 0.21 ms × 省下的条数，且这是排空治理之后唯一还能砍的大头。
3. **暗区独立成立**：490 发非 op 标记发射 = 550 ms（LOOP 的 40 %），单价 1.124 ms 是同腿普通发射的 7×，**排空关掉它纹丝不动** ⇒ 不是通用驱动税，是这 490 发各自贵；与排空无关，须单独立靶（下一步：给暗区发射点分站点标签，看清是哪几处）。

**仪表可信度声明（R-092）**：v1–v3 用 `clock()`（进程 CPU 时间）+ 无锁共享 map，产出过违反可加性的行（内层 8× 父行、`LOOP_TOTAL` > `GRAPH_TOTAL`），其绝对归因全部作废；v4（`vkh_instrument.h` md5 `252ae09d…`，lib `80ab2580…`）换墙钟 + 递归锁，并内建可加性自检：**闭合窗口**（`graph_depth==0`）内层超父行即 `abort()`，中途 dump 只报 `MIDGRAPH_INFO`（dump 点在 `graph_compute` 内部，正在飞的图尚未入账，判它为违规会误杀每一条 GPU 腿 —— 本条已用真机 rc=134 现场验证过）。仪表自身成本单列 `DUMP_COST` 行。

## 4. 提案（R-091 改判 + R-092 墙钟复核后的优先级）

**P0 — 智能排空替代无脑每 2 发（头号修法）**：把 L1459 的"每 N 发无条件 `clFinish`"换成**依赖驱动的定向同步**（只在真正跨流/跨队列竞争点等待，或改为 `clFlush` + 关键节点 event 等待），保持 R-060 的 H2′ 治愈语义。验收 = 本 A/B 的墙钟形状（host_ms/step 与 tok/s）+ 数值闸全绿（多 prompt、4B、740）。风险 = H2′ 复发即乱文，故**必须先立数值闸再改**；默认值 2→0 的产品化须用户金口。

**P1 — 减发射条数（墙钟复核后恢复主修位：排空之后 94 % 的提交墙钟就是门铃本身）**
现状 907 kernels/token（丙口径，`host-timing kernels=`）。GLU 融合（`MUL_MATx2+GLU(fused)`）已入库且被 ledger 181 证明"开/关都 ~1.0 t/s"—— 说明**单点融合不够，要按发射条数总账减**。候选（按 740 丙口径节点数排序，收益 ∝ 条数）：
1. `UNARY(0.453) / SCALE(0.488) / MUL(0.476) / ADD(0.501)` 这类逐元素链 → 同 shape 相邻节点合并成一条 multi-op kernel（一个 kernel 内做 mul→scale→add→unary）；
2. `RMS_NORM(0.457)` 与其后的 `SCALE/MUL` 合流；
3. `CPY(0.528)` / `GET_ROWS(0.532)`：decode 期 `n=1` 的 gather 与拷贝尽量在消费端 kernel 内直接索引，消掉独立 kernel；
4. `SSM_CONV(0.528)` 与相邻 GLU/NORM 合流（战役模型 Qwen3.5-4B 专有）。
**验收**：`[host-timing] kernels=` 每 step 下降幅度 ≈ t/s 上升幅度（同温 <4 ℃、三口径 ×3 中位）；数值闸用我的 `vkh_tbo` 贪心前缀对比（禁"看着快就算过"）。
**风险**：融合改变数值序 → 必须过数值闸；融合体在 FA-ON 路径要单独验（甲口径）。

**P2 — 包装器内部二分：已结案（v4 墙钟判定，无需再挂第二层钩子）**
`enqueue_ndrange_kernel` 体内另有 wgs / subgroup 查询与 `tyl_l0_note_enq` 簿记，v1–v3 用 CPU 时间无法把它和驱动调用本体分开。v4 已挂 `ENQ_DRV`（只包真正的 `clEnqueueNDRangeKernel`），墙钟结果：**Σ`ENQ_DRV` = 1303.2 ms 与 Σ`ENQ/<op>` ≈ 1280 ms 相差 <2 %**（`IDLE=0` 腿）⇒ **包装器自有工作不是成本，驱动调用本体铁案**：0.21 ms/发是 Adreno 用户态驱动的价格，唯一杠杆是**减条数（P1）**，"给 wgs/subgroup 加缓存"这类包装器优化可以排除。

**P3 — 未标注发射的暗区（独立第二靶，v4 墙钟坐实）**
`ENQ/PRE_FORWARD`：`IDLE=0` 腿 **550.6 ms / 490 次 = 1.124 ms/次**，是同腿普通发射 `ENQ/MUL_MAT`（0.161 ms/次）的 **7×**，占 LOOP_TOTAL 的 **40 %**，且排空开关几乎不动它（`IDLE=2` 腿 1.834 ms/次）⇒ 不是通用驱动税，是这 490 发**各自**贵。这些发射发生在"每节点 `LOOP_TOTAL` 计时起点 → 该节点 op 计时器构造点"之间（forward 之前的暗区）。仪表侧两件事：① `vkh_op_timer` 析构恢复上一层 op（save/restore）**已在 v4 实施**，暗区不再被 op 行串标签；② **分站点标签**（在暗区内按发射点细分 `ENQ/PRE_FORWARD@<site>`）待父智能体批准后再做，批准前不挂载以免污染对照。**这 490 × 1.1 ms 若能在 740 复现，其价值可能高于所有单点优化。**

**P4 — q5_0 路线（独立案，不入本三口径变量）**
按 ledger 187 收窄，本案 campaign 4B 无 q5_0，**三口径变量只有 FA 档位 + 暗区**。q5_0 单独走：① 先把 `supports_op` 的 **decline 与 placement 解耦**（`-ngl 0` 时 `-ngl` 仍放 CPU，但能力探针说"能上 GPU"，两件事混在一起导致历史判词误读）；② 白名单 `type_has_gemm`（L11072，现含 Q4_0/Q4_1/IQ4_NL/Q8_0/Q4_K/Q5_K/Q6_K）**加 q5_0/q5_1 作对照腿**，配合 load 期 `m=512` 单口径探针（L11085-11086 `!uses_gemm && !small_weight && src[1]->ne[1] >= 512` → decline）拆成 **decode / prefill 双口径**；③ 厂商 q5_0 GEMM 内核存在性 = 父智能体 ledger 185，数值正确性 = 我的 `vkh_tbo` 闸。

**P5 — CL 对象指纹缓存（定罪后降级为次级）**
`ggml_cl_subbuffer_from_parent`（L8000，内部 L8017 无缓存 `clCreateSubBuffer`）被 MoE 路径逐 expert 调用（L12178/12179、L13331-13334、L14329），加 `(parent, origin, size)` 指纹缓存 + pending-release-queue（L847 已注明该 TODO）。**门铃定罪后它不再是主靶**：只在观测到 subbuffer 风暴的模型（MoE）上按 P1 同法验收。

## 5. 明确排除项（勿再投入）

- ❌ **关 FA 当修法**（是仪表，不是药；K40 实测 decode 恶化 34%）。
- ❌ **优化 `clSetKernelArg` 装填 / 张量簿记缓存**（v4 墙钟复核仍成立：Σ`ENQ_DRV` 与 Σ`ENQ/<op>` 相差 <2 %，包装器自有工作近乎免费 —— 见 P2；v1–v3 的"≤8 %"是 CPU 时间口径，数字作废但结论同向）。
- ❌ **本战役加 q5_0 变量**（ledger 187）。
- ❌ **第二轮带 patch80**（父智能体裁定）；第三轮靶点定案后再复测。
- ❌ **830 压测**（用户明令；830 只做正常调试，adbd 现仍拒连，等用户侧 `adb-wifi.ps1`）。

## 6. 未决清单

1. **740 掉线**（~23:45，与父智能体 13.58GB adb pull 时点重合）：pass1 完整 + pass2 残腿保留在 `/data/local/tmp/vkh2/out/`，不清不动；恢复后跑 pass2/pass3 取中位。
2. **CPU 腿污染复核**（§1 ⚠️，头号判词引信）。
3. **P2 包装器内二分钩子** 挂载 + **P3 暗区标签修复**（均需父智能体挂载；被跟踪文件我零改动）。
4. K40 上无战役 4B（父智能体所记 `/data/local/tmp/g759/qwen35-4b-q4km.gguf` 在 K40 不存在，宿主亦无），如需 4B-on-K40 须先限速传 2.8 GB。
5. GPU≠CPU 贪心分歧（md5 `36c7d6d7d1e6` vs `0d0858efe9ee`）仍挂账，与本案无关。
