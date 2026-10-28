# R-115 第二拍 · 环2 = q4_1 MoE 全链 diff（**候父编译**；产品码一字未落）
diff：`_probe/vkh_830/vkh_r115_环2_q4_1_MoE_全链.diff`（209 行 / 11 hunk，`git apply --check -p1` = **PASS**，基线 = 当前工作区**含父 R3**）
环1（dense 面装载豁免）已按 13:3x 分工作废：`VOID_vkh_r115_环1_已被父R3取代_勿编译.diff`（留档，内含可作 R3 白名单参考的类型清单）。

## 0. 一句话
**零新内核、零新 .cl**。q4_1 MoE 的缺口不是内核资产（件证：`kernel_gemv_noshuffle_q4_1_f32`+`_mc3` 声明 :1586/创建 :4782-4783/被 :23932 的 `ggml_cl_mul_mat_q4_1_f32_adreno` 消费、dense 派发 :28873 今日在用；repack `kernel_convert_block_q4_1_noshuffle` 声明 :1056/创建 :2218），缺的是**一条路线的表行 + 装载布局 + 逐专家子缓冲 + 派发 arm**。本 diff 补这四处，并把旧表行注里那句错话（"dense GEMV 家族无 q4_1 内核，勿猜"）就地纠正并附件证。

## 1. 现场靶子（本模型唯一 q4_1 MoE 权重）
`blk.1.ffn_down_exps` / `blk.2.ffn_down_exps`，q4_1，ne=[512,1536,128]（K=512, N=1536, E=128）。
今日形态（我三条真腿的 `[buft-probe]` 去重表）：**装载期判 GPU**（`MUL_MAT_ID … type=q4_1 … -> GPU`）但 d2 派发无 q4_1 分支 ⇒ "路由说支持、派发没路"的**承诺过度**案。旧路由 `mmid_q4_1_batched` 的 executor = vendor `gemv/gemm_moe_q4_1_f32_ns`，与 q4_0 ns 同族——**Mesa 面 R-084 已判死**。

## 2. 十一处 hunk（表侧 7 + ggml-opencl 4）
| # | 文件:行 | 干什么 |
|---|---|---|
| T0 | `tongyi_route_table.cpp:12` | `#include <stdlib.h>`（表内首次读 env） |
| T1 | `:66` | 新增表行 `"mmid_q4_1_dense", DENSE_LOOP, RTYPE_Q4_1`，门集逐字镜像 `mmid_q4_0_dense`（K%32 / N%4 / 名字不查 / 代际不查），owner=`vkh-q41` |
| T1b | `:33` | `mmid_q4_1_batched` 的 fallback 由 `"cpu"` 改指 `"mmid_q4_1_dense"`（batched 被拒时有兜底，不再直接坠岛） |
| T2 | `:126` | `dense_loop_type()` 加 q4_1 支：**默认关**，`GGML_OPENCL_MOE_Q4_1=1` 显式开，或沿用既有 `GGML_OPENCL_DENSE_MOE=1`（dense_force） |
| T3 | `:135` | `dense_slice_sizes()` 加 q4_1 支：`s_q=M*(K/4)*2`、`s_d=M*(K/32)*2`、**`s_dm=M*(K/32)*2`（q4_1 块 = 16B quants + d 与 m 两根 f16，比 q4_0 多一根 min 面）** |
| T4 | `:149` | `dense_static_ok` 的 `shape_ok`：q4_1 与 q4_0 同为 32 元素块 ⇒ `K%32`（原式会把 q4_1 误按 K%256 拒） |
| T5 | `:208` | `resolve_admission` 第 1 步（dense 分支）纳入 `RTYPE_Q4_1`；准入与否仍**完全**由 `dense_loop_type` 决定 |
| G1 | `ggml-opencl.cpp:8152` | `ggml_tensor_extra_cl_q4_1` 加 `std::vector<…*> moe_dense_extras` + 析构里逐片 delete（镜像 q4_0 `:8100`/`:8110-8113`） |
| G2 | `:12441` | set_tensor q4_1 支前插入 **3D MoE 装填臂**：整块 `kernel_convert_block_q4_1_noshuffle` + **逐专家子缓冲就地 transpose（q/d/m 三面）**，母本 = q4_0 MoE 支 `:12198-12248` |
| G3 | `:26950` | `ggml_cl_mul_mat_id_dense_loop` 的逐专家 extras 链加 q4_1 分支（q/d/m 三面 subbuffer，尺寸公式与装填同源） |
| G4 | `:27035` | 派发链加 `else if (Q4_1) → ggml_cl_mul_mat_q4_1_f32_adreno(backend,&f0,&f1,&fd)`（既有件 :23932，顶层函数，其 ne1==1 分支取 `kernel_gemv_noshuffle_q4_1_f32`） |

**与父领地零重叠**：我的 4 个 hunk 在 8152 / 12441 / 26950 / 27035；supports_op（含父 R3 改动，:10428-10448 与 :11146-11147）我一字未碰。

## 3. 为什么不会静默错值（本环最危险形态 = "装填按旧路、派发按新路"）
装填（G2）、准入（T5/T2）、派发（G4）**同读一个真源** `moe_use_dense_loop(GGML_TYPE_Q4_1)` → 路由表 `dense_loop_type`。三者要么全走新路、要么全走旧路，不可能半新半旧。
第二道保险在 G2 的守卫：`Mc%4==0 && q/d/m_layer % alignment == 0` 才做逐专家 transpose；不满足就**保留整块 row-major 且不 return**，让 `dense_static_ok` 的 `subbuf_align` 门在准入期拒掉 ⇒ 坠 CPU，而不是让派发期读到"半 transpose"布局。ling tiny 实测 K=512/N=1536 ⇒ q_layer=393216、d/m_layer=49152，均 %1024==0 ⇒ 走 GPU 路。

## 4. 零扰动自证
`GGML_OPENCL_MOE_Q4_1` 未设/0 且未设 `GGML_OPENCL_DENSE_MOE=1` ⇒ `dense_loop_type(q4_1)=false` ⇒ T1/T1b/T5 表行为不变、G2 装填臂不进（q4_1 仍走今日 `kernel_convert_block_q4_1` shuffle 路）、G3/G4 派发不进（准入已拒）。G1 只是加字段+析构清理（空 vector 时零成本）。
⇒ 关 env 复跑应与今日 **逐字节等价**（腿前后 txt md5 对拍即证）。

## 5. 腿形（父编译后；740 = 父车道，我不碰机）
```
off  臂：现状（无新 env）
on   臂：GGML_OPENCL_MOE_Q4_1=1   +（父 R3 的）GGML_OPENCL_MESA_LARGE_N_GEMV=1 + GGML_OPENCL_FA_A7X_GUARD=0
```
验收（全部机检，不做成人眼终审）：
1. **对拍是闸**（本环是数值路径改动，最高风险）：CPU gold 轨（K40 ngl=0，`b2_cpu_gold_k40.sh`，`GOLD_SHA_OK=1`）逐 token 对同腿 txt；**乱文未清之前，任何"提速"结论都不许单独入账**。
2. `route[blk.1.ffn_down_exps] … -> DENSE_LOOP (mmid_q4_1_dense)` 出现在日志（证走新行，而非继续 batched 空转）。
3. `[vkh-optime]` 必须出现 `gemv_noshuffle_q4_1_f32` 行；若出现 `..._moe_q4_1_..._ns` = 走错路（撤 env）。
4. **GATE-FAIL = 0**：`MUL_MAT_ID batched GATE-FAIL[…] refused (gen/shape)` 计数（注意 `MMID_FAIL_LOG_MAX 8` 是**日志上限**，不是真值，需按 route 行反推）。
5. **CPU split：父 fa0 基线 20 → 目标个位**（本环只消 q4_1 岛；q5_0 那 36 枚归父 R3 的腿）。
6. txt fail-closed：`vkh_b1_txtgate.sh <dir> <tag> <reps>` → `B1TXT_VERDICT gate=DETERMINISTIC uniq_md5=1/N`。
7. 速度闸：`[host-timing]` per-token（聚合器 `vkh_ht_perpass.py`，四基线对表已通）+ `[e2e][METRIC] leg=decode tok_s=`；**只正确不快 = 没做完**。
8. R-083 尺子铁律不动：`LLAMA_MOE_SLOT_BANK=32` + `E2E_NB=16`。

## 6. 报父两条（我领地外，只报不碰）
1. **R3 建议加类型白名单**：`mesa_large_n_gemv_ok(ctx)` 不收 type ⇒ 该支所有类型一并豁免。件证：`kernel_mul_mv_q4_k_f32 / q5_k / q6_k / q2_k / q3_k / q4_0` 在本文件 **出现次数 = 0**（K-quant 系只有 `kernel_mul_mm_*_f32` GEMM 变体，走的是 vendor Adreno 路；通用执行器那个 switch 里只有 Q5_0/Q5_1 等 case）。⇒ 若某 K-quant 稠密权重 `uses_gemm=false`（例如 `ne[1]%64!=0` 或 `ne[2]!=1`）又被 R3 放进 GPU，派发期将 `GGML_ABORT`（fail-fast 断腿，非静默）。**q4_0 同样在 0 之列**（它靠 noshuffle 链）。建议一行：`&& mesa_general_gemv_type(t)`，白名单 = q4_1/q5_0/q5_1/q8_0/iq4_nl/mxfp4/ptq1_0/q1_0（逐条来自 `kernel_mul_mv_*_f32` 创建清单）。**K40 侧同改同跑**。
2. FA MQA mask 广播案（`kq->ne[1]>=1` 三拒）与 es_base 同族：按父令**候审不动**，我不重复开火；环2 落地后并案。
