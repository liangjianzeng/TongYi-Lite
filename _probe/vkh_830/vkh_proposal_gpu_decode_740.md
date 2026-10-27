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
3. **暗区独立成立（2026-10-28 已结案，见 P3）**：490 发非 op 标记发射 = 550 ms（LOOP 的 40 %），单价 1.124 ms 是同腿普通发射的 7×，**排空关掉它纹丝不动** ⇒ 不是通用驱动税，是这 490 发各自贵；与排空无关，当时判为"须单独立靶"。**后续**：站点标签枪把 490 发全部收束到唯一站点 `graph_compute` **L10119**（= L10118 `ggml_opencl_op_rms_norm_fused` 的续行），并用产品自带 `GGML_OPENCL_FUSE_RMS_MUL=0` 定价 —— 关融合使 LOOP 反而 **+3.6 %**、发射数 +490 ⇒ 暗区是**被位移的工作**而非可删浪费；下一靶改指"单次融合发射 host 侧 4.6–7× 于普通发射"的 image-pool 嫌疑（P5 升格）。

**仪表可信度声明（R-092）**：v1–v3 用 `clock()`（进程 CPU 时间）+ 无锁共享 map，产出过违反可加性的行（内层 8× 父行、`LOOP_TOTAL` > `GRAPH_TOTAL`），其绝对归因全部作废；v4（`vkh_instrument.h` md5 `252ae09d…`，lib `80ab2580…`）换墙钟 + 递归锁，并内建可加性自检：**闭合窗口**（`graph_depth==0`）内层超父行即 `abort()`，中途 dump 只报 `MIDGRAPH_INFO`（dump 点在 `graph_compute` 内部，正在飞的图尚未入账，判它为违规会误杀每一条 GPU 腿 —— 本条已用真机 rc=134 现场验证过）。仪表自身成本单列 `DUMP_COST` 行。**v5（`vkh_instrument.h` md5 `3a32ff63…`，lib `66b24e4e…`）**在此之上加：闭合窗口 dump 的常开可加性保险（1240 次闭合判定零误杀后转常开）、R-094 三指纹配套字段、以及 **env 门控（`VKH_DZ_TAG=1`，默认关）的站点标签**（`ENQ@+0x<off>` / `DZ@+0x<off>` / `ENQ#<n>` + `STATIONS` banner，含 `STATION_COLLAPSED` 内联坍缩自检）；站点标签的"观察者免费"已由 `vkh_dz_selftest.sh` 双臂证明，关掉时表内一行 station 都不产生 ⇒ 所有 campaign 腿字节级同旧表。

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

**P3 — 暗区已结案（2026-10-28 站点标签枪）：唯一站点 = `rms_norm+mul` 融合助手；"砍融合"实测是亏本方向**
站点标签枪（`VKH_DZ_TAG=1`，env 门控默认关；站点 = `enqueue_ndrange_kernel` 的**调用者 PC** − .so 装载基址，基址由纯 libc 的 `dl_iterate_phdr` 求得，偏移可直接喂 `addr2line -e libggml-opencl.so -f -C`；**故意不用 `dladdr`** —— 它归属 libdl 还是 libc 随 Android API 变，未解析符号会让整个后端加载失败）在 K40 首枪即把暗区收束到一点：`STATIONS rows=25 launches=6199 dz_rows=1 dz_launches=490`，`DZ@+0x2e96c4` → **`ggml_backend_opencl_graph_compute` @ ggml-opencl.cpp:10119**，即 **L10118 `ggml_opencl_op_rms_norm_fused(backend, node, cgraph->nodes[i+1]);`** 的续行。机制闭环：融合助手自己发射却不设 `g_vkh_current_op`，故其发射全部沉淀在 `ENQ/PRE_FORWARD`（不是"神秘驱动税"，是没挂标签的自有工作）。
**定价实验**（`vkh_fuse_ab.sh` md5 `7ced440a`，`IDLE=0` 干净归因，用产品自带 `GGML_OPENCL_FUSE_RMS_MUL=0`（L10113-10116），产品码零改动）：

| 臂 | LOOP_TOTAL | `ENQ/PRE_FORWARD` | `ENQ_DRV` 发射数 | `MUL_MAT` | tok/s |
|---|---|---|---|---|---|
| 融合开 | 1302.1 ms | 435.9 / 490 = **0.890 ms/发** | 1202.3 / **6199** | 533.4 | 5.8 |
| 融合关 | **1349.0 ms** | 行消失（`dz_launches=0`） | 1261.1 / **6689** | **730.3** | 5.9 |

⇒ **暗区不是可删除的浪费，而是被位移的工作**：关融合清了 490 发暗区发射，却多发射 490 次、`MUL_MAT` +197 ms、LOOP **+47 ms（≈3.6 %）**，tok/s 在打印量子内不变 ⇒ **砍融合不是修法，反而净亏**。
（数值诚实：本节早前所记 `IDLE=0` 腿 `550.6 ms/490 = 1.124 ms/发、占 LOOP 40 %` 作为**量级**判据仍成立；两次独立 `IDLE=0` 测量该行为 435.9–550.6 ms，**run-to-run 约 20 % 散布**，引用按量级不按小数。）
**剩下的唯一锐利问题（R-097 已挂完刀，候 740 一发即裁）**：一次融合发射 host 侧 0.890–1.124 ms，是同腿普通发射（0.161–0.194 ms）的 **4.6–7×**，贵在哪。原嫌疑 = addr2line inline 链里的 `ggml_cl_img_pool_get_or_create → std::map<ImagePoolKey>::operator[]`（image pool），**已被 R-097 真机证伪**（见 P5：池税 0.017 ms/发 = 1.9 %）。现场两把计时行均已由父智能体挂载：L10122 `FUSE/RMS_MUL`（R-096，`set_cur=false` ⇒ 融合体内发射仍归 `ENQ/PRE_FORWARD`）、L1445 `ENQ_DRV` 补第 4 参 `__builtin_return_address(0)`（R-097 ⇒ `ENQ_DRV@+0x<site>` 站点行）。判词由仪表自落四档，740 暗区法证腿一发即裁：`TAX_IN_WRAPPER`（包装器 wgs/subgroup/簿记 ⇒ 可按 kernel 缓存）/ `TAX_IN_DRIVER`（门铃本体 ⇒ 只剩减条数/换内核）/ `TAX_INSIDE_ENQUEUE`（L1445 的 ra 未生效）/ `TAX_OUTSIDE_ENQUEUE`（image-pool 类自有工作 ⇒ P5 复燃）。native 双模已验两分支均可达（wrapper 模 `enqueue=2.749 drv=0.678`、driver 模 `enqueue=1.558 drv=1.558`）。
仪表侧现状：① 析构恢复上一层 op（save/restore）已在 v4 实施；② 分站点标签已在 v5 实施并**自测合格**（`vkh_dz_selftest.sh` md5 `18561841`：观察者免费 —— host_ms Δ **0.18 %**、tok/s 差在打印量子内、结构指纹两臂逐字相同 `idle=n3099 darkzone=n490 drv=n6199`、`txt` 相同、`dz_cross=ok`），**默认关 ⇒ campaign 各腿字节级同旧表**。

**P4 — q5_0 路线（独立案，不入本三口径变量）**
按 ledger 187 收窄，本案 campaign 4B 无 q5_0，**三口径变量只有 FA 档位 + 暗区**。q5_0 单独走：① 先把 `supports_op` 的 **decline 与 placement 解耦**（`-ngl 0` 时 `-ngl` 仍放 CPU，但能力探针说"能上 GPU"，两件事混在一起导致历史判词误读）；② 白名单 `type_has_gemm`（L11072，现含 Q4_0/Q4_1/IQ4_NL/Q8_0/Q4_K/Q5_K/Q6_K）**加 q5_0/q5_1 作对照腿**，配合 load 期 `m=512` 单口径探针（L11085-11086 `!uses_gemm && !small_weight && src[1]->ne[1] >= 512` → decline）拆成 **decode / prefill 双口径**；③ 厂商 q5_0 GEMM 内核存在性 = 父智能体 ledger 185，数值正确性 = 我的 `vkh_tbo` 闸。

**P5 — CL 对象指纹缓存（R-096 升格 → R-097 自证伪，回原档：定罪后次级）**
**原档判词（保留）**：`ggml_cl_subbuffer_from_parent`（L8000，内部 L8017 无缓存 `clCreateSubBuffer`）被 MoE 路径逐 expert 调用（L12178/12179、L13331-13334、L14329），加 `(parent, origin, size)` 指纹缓存 + pending-release-queue（L847 已注明该 TODO）。门铃定罪后它不是主靶：**只在观测到 subbuffer 风暴的模型（MoE）上按 P1 同法验收**。
**R-096 升格文本（保留作证伪记录，已作废）**：当时因暗区被证实是融合助手自有工作、且砍融合是净亏，判"暗区剩下唯一可下手的对象就是其 host 侧准备成本"，并把 addr2line inline 链里的 `ggml_cl_img_pool_get_or_create → std::map<ImagePoolKey>::operator[]` 认作"每次融合发射查/建 image pool"，据此把 P5 升为"暗区唯一可行修法方向"。
**证伪（真机，K40 / qwen2.5-0.5b-q4_k_m / 丙口径 / `IDLE=0` / `VKH_DZ_TAG=1` / lib `f52adb68`；判词由仪表自落，非人算）**：

```
[vkh-optime] FUSETAX fuse=430.1/490(0.878/发) enqueue=421.9/490(0.861/发)
             tax=8.3(0.017/发) rule=FUSE_TOTAL-DZ_site
             verdict=TAX_INSIDE_ENQUEUE(image-pool 无罪)
```

⇒ 融合助手在发射之外的自有工作（含 image-pool 查询）合计 **0.017 ms/发 = 单次融合发射的 1.9 %** ⇒ **image-pool 清白，升格撤回，P5 回原档**。
**复燃条件（写死，免后人凭印象重升）**：仅当某模型/某口径上仪表自动落出 `verdict=TAX_OUTSIDE_ENQUEUE`（即 `ΣDZ@ < 0.85 × FUSE_TOTAL`）时 P5 才重升；判词由仪表落，**禁止人手相减**（`FUSE_TOTAL − 全局 ENQ_DRV` 是负数假账：430.1 − 1170.6 = −740）。

## 5. 明确排除项（勿再投入）

- ❌ **关 FA 当修法**（是仪表，不是药；K40 实测 decode 恶化 34%）。
- ❌ **优化 `clSetKernelArg` 装填 / 张量簿记缓存**（v4 墙钟复核仍成立：Σ`ENQ_DRV` 与 Σ`ENQ/<op>` 相差 <2 %，包装器自有工作近乎免费 —— 见 P2；v1–v3 的"≤8 %"是 CPU 时间口径，数字作废但结论同向）。
- ❌ **砍 `rms_norm+mul` 融合当修法**（2026-10-28 实测：`GGML_OPENCL_FUSE_RMS_MUL=0` 使 LOOP_TOTAL 1302→1349 ms、发射 6199→6689，tok/s 量子内不变 —— 见 P3；暗区是位移的工作，不是可删的浪费）。
- ❌ **人手相减算池税**（`FUSE_TOTAL − 全局 ENQ_DRV` 是负数假账：`430.1 − 1170.6 = −740`；`ENQ_DRV` 覆盖全部发射而非融合那几百发。减法归仪表 `FUSETAX`（`rule=FUSE_TOTAL-DZ_site`）自落四档判词，人不插手）。
- ❌ **跨 build 抄偏移喂 addr2line**（实测不报错的假符号：拿 K40 件 `f52adb68` 的 `+0x2ee404` 去解父侧 `0cc2855e`，得到 `ggml_cl_ssm_scan @ :0` —— 该函数在 0.5B decode 路径上根本不参与。同一段代码仅加一行挂载，DZ 站点即从 `+0x2e96c4` 漂到 `+0x2ee404`。**铁律：addr2line 必须喂同 md5 的 .so**，先 `md5sum` 再解）。
- ❌ **本战役加 q5_0 变量**（ledger 187）。
- ❌ **第二轮带 patch80**（父智能体裁定）；第三轮靶点定案后再复测。
- ❌ **830 压测**（用户明令；830 只做正常调试，adbd 现仍拒连，等用户侧 `adb-wifi.ps1`）。

## 6. 未决清单

1. **740 掉线**（~23:45，与父智能体 13.58GB adb pull 时点重合）：pass1 完整 + pass2 残腿保留在 `/data/local/tmp/vkh2/out/`，不清不动；恢复后跑 pass2/pass3 取中位。
2. ~~**CPU 腿污染复核**（§1 ⚠️，头号判词引信）~~ ✅ **已结案（R-099 / ledger 199）**：740/4B `-ngl 0` 参考腿四执行指纹+两独立源全零、txt 与 GPU 控制腿逐字节同 ⇒ `contaminated=no ref_recalc=no`，头版不必重算。
3. **暗区后续**：站点标签枪已合格（`VKH_DZ_TAG=1` 默认关），两把计时行均已由父智能体挂载（L10122 `FUSE/RMS_MUL` = R-096；L1445 `ENQ_DRV` 补 `__builtin_return_address(0)` = R-097）。剩余唯一未决 = **740 暗区法证腿**（`VKH_DZ_TAG=1` + `GGML_OPENCL_NDRANGE_IDLE=0`），由 `FUSETAX` 自落四档判词当场裁"4.6× 归属"。**⚠️740 主战件定案 = `959cb859`（R-098 裁定：vk-rel/Release 现树，含 L10122/L1445ra/头 `e7b8724d`，**自带 `.debug_line`**，SONAME=`libggml-opencl.so`）**；`0cc2855e` 已退役为交叉校验件并封存 `.x4`——**它无行号表，addr2line 会对它静默吐假符号（实证：`f52adb68` 偏移喂 `0cc2855e` 解析出 `ggml_cl_ssm_scan @ ggml-opencl.cpp:0`），禁入暗区法证腿**；addr2line 只准喂与被测栈同 md5 的件。换件前置 `vkh_artifact_gate.sh`（`56ba3468`）。`ENQ_WAIT` 设计已批但**未挂载**。P0 默认值 `2→0` 与产品化**候金口**（须 740+830 X4 数值闸全绿后）。
4. K40 上无战役 4B（父智能体所记 `/data/local/tmp/g759/qwen35-4b-q4km.gguf` 在 K40 不存在，宿主亦无），如需 4B-on-K40 须先限速传 2.8 GB。
5. GPU≠CPU 贪心分歧（md5 `36c7d6d7d1e6` vs `0d0858efe9ee`）仍挂账，与本案无关。
