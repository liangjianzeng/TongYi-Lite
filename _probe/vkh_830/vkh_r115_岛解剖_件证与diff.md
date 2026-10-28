# R-115 第二拍 · 岛解剖件证 + 环1 diff（候父编译；产品码一字未动）
提案人 vkh（GPU 解码路定位线）。**靶子按父令收窄到 96→20 基线**；本件回答父问："q4_1 全链是不是最后主犯、dense 面 `mm_type_blocked("q4_1")`/`kernel_mul_mv_q4_1_f32` 走通用 GEMV 还是必须 noshuffle"。

## 0. 先摆件证，再谈结论（三方独立，可复算）
**(A) 产品自带仪表 `[buft-probe]`（:10752-10767，装载期逐枚权重打分）**——我自己归档的**三条 ling patch79e 真腿**日志去重表（`/tmp/l3_740/l3_idle0_r1.err`、`/tmp/l5ab_740/l5ab_{dm0,bm0}_r1.err`）：

| 判定 | 数量 | 类型分布 |
|---|---|---|
| → **CPU** | **36** | **q5_0 = 36（唯一坠岛类型）** |
| → GPU | 233 | q4_0=101, q8_0=75, f32=41, f16=6, q6_K=9, **q4_1=1** |

36 枚 CPU 权重 = `blk.{10,12,13,15,…}.ffn_gate_shexp/ffn_up_shexp` [1536,512] + `ffn_down_shexp` [512,1536]（12 块 × 3）。

**(B) GGUF 张量表离线普查**（`vkh_gguf_tensors.py`，类型名取自本树 `ggml.h` enum，不靠记忆）：526 枚张量里
`f32=233 q4_0=169 q8_0=75 q5_0=36 q6_k=10 q4_1=3`；**q4_1 全家只有 3 枚** = `blk.0.ffn_down`[4608,1536] + `blk.1.ffn_down_exps`/`blk.2.ffn_down_exps`[512,1536,128]。

**(C) 模型解剖**：bailingmoe3 / Ling 3.0 Tiny，24 块 = **18 标准注意力块 + 6 MLA 块（3,7,11,15,19,23）**，与父 d2 的 `FLASH_ATTN×6` **逐块对上**（FA 案父已落 `fa_a7x_kv_guard()`，我不开火）。

## 1. 对父口径的一处纠正（件证在前，请父复算）
父说"37 个 MUL_MAT 全是 dense `ffn_gate/up`（**q4_1**）"。**节点名对、类型不是**：`ffn_gate_shexp/ffn_up_shexp/ffn_down_shexp` 这批是 **q5_0**（36 枚），q4_1 全模型只 3 枚且**装载期判 GPU**（表 A 最后一列）。⇒ **96 岛（fa0 后 20）的主体真凶是 q5_0 的装载期拒判，不是 q4_1**。
复算只需一条命令（父的 L6/fa0 腿日志里就有这些行，**不必新腿**）：
```sh
grep -a '\[buft-probe\] MUL_MAT ' out/*.err | grep -a ' -> CPU' | awk '{print $4}' | sort | uniq -c
```

## 2. 为什么"派发期解锁了、CPU split 纹丝不动"（L6 on1 之谜，本件顺带解答）
`uses_gemm = type_has_gemm && use_adreno_kernels()`，而 `type_has_gemm`（:11103 一带）**集合里没有 q5_0**；装载期 buft 探针恰以 `src1->ne[1]==512` 调用 ⇒ 命中 `!uses_gemm && !small_weight && N>=512` ⇒ **权重落 CPU buffer**。此后派发期把内核门开到多大都救不了——**权重不在 GPU 上**。这正解释 on1 臂 `cpusplit=96` 不动。
同型先例就在树里：dspark 2026-10-16 为 `ssm_alpha/ssm_beta` 小权重开过 `small_weight` 豁免（:11108-11116，830 实测 432 CPU ops/token 案的解）。**环1 就是它的 Mesa 续篇。**

## 3. 环1 = 可编译 diff（已验 `git apply --check` 过；产品码未落）
`_probe/vkh_830/vkh_r115_环1_q5_0装载豁免.diff`（49 行，两处）：
1. `moe_selfbuild_unlock()` 之后新增**一处真源** `mesa_general_gemv_admit(ctx, type)`（env `GGML_OPENCL_MESA_LOAD_ADMIT`，默认关=逐字节零扰动；仅 `is_mesa_rusticl`）；
2. 稠密支拒判那一句加 `&& !mesa_gemv_ok`。

**白名单不是猜的**，逐条来自本文件 `kernel_mul_mv_*_f32(+_flat)` 的 `clCreateKernel` 清单：`q4_1 / q5_0 / q5_1 / q8_0 / iq4_nl / mxfp4 / ptq1_0 / q1_0`。
**q4_0 故意排除**（通用执行器无 `kernel_mul_mv_q4_0_f32`，它靠 noshuffle 链；放行=发空内核）。q2_k/q3_k/q4_k/q5_k/q6_K 同因排除。

## 4. 父问两则的普查答复（dense 面）
- **`mm_type_blocked("q4_1")` 不是凶手，也不需要解锁**：它只是 A/B 旋钮（:28829 `GGML_OPENCL_NO_ADRENO_MM_TYPES` 子串匹配，默认未设 ⇒ 不拦）。
- **q4_1 不需要写内核**：通用 `kernel_mul_mv_q4_1_f32`(+`_flat`) 在树（`kernels/mul_mv_q4_1_f32.cl`、`..._flat.cl`）且在件（串 6）；noshuffle 链也成对存在（`kernel_convert_block_q4_1_noshuffle` @:1056/:2218/:12419 + `kernel_gemv_noshuffle_q4_1_f32` @:1586/:4782/**消费 :23972 已在 Mesa 面服役**）。⇒ **两条路都有件，选哪条由父定**；我的建议：**环1 先落**（它不改内核选择，只把权重搬上 GPU，收益 36 岛），环2 再定 q4_1 走通用还是 noshuffle。

## 5. 环2（q4_1 全链）现状：仍是缺口，但范围比想象小
唯一真缺 = **MoE 派发三元链无 q4_1 分支**（`:26714` 一带 `is_q4_0 ? … : (is_q4_k ? … : q3_k)`）+ 路由表 `dense_loop_type` 只收 q4_0/q4_K（`tongyi_route_table.cpp:124`）、`dense_slice_sizes` 无 q4_1 支（q4_1 块含 **d+m 两根 f16**，比 q4_0 多一根 min 面）。
表 A 的旁证：`blk.1/2.ffn_down_exps`（q4_1）装载期**判 GPU**——即"路由说支持、派发没内核"的**承诺过度**案，正是我环2 要补的四处接线（详见 `_probe/vkh_830/vkh_q4_1_全链规格_第二拍.md`）。**环2 diff 我下一步交**（需要逐行镜像 `ggml_cl_mul_mat_q4_0_f32_adreno`，我不想凭记忆出 diff）。

## 6. 验收（按父新基线；不做成人眼终审）
1. **一枪定谳先看日志**：`[buft-probe] MUL_MAT … q5_0 … -> GPU`（环1 生效证明，零额外成本）；
2. **CPU split：20 → 个位**（fa0 基线 20，父定）；
3. `[vkh-optime]` 必须出现 `kernel_mul_mv_q5_0_f32` 行（证真走通用 GEMV，防"上了 buffer 却发空内核"）；
4. txt fail-closed：`vkh_b1_txtgate.sh`（degenerate/topfreq/uniq/err_has_body + `B1TXT_VERDICT`）；
5. **只正确不快 = 没做完**：per-token 只引 `[host-timing]`（聚合器已做成枪 `_probe/vkh_830/vkh_ht_perpass.py`，四条基线对表通过）；
6. 关 env 复跑 = 与 fa0 基线逐字节等价（零扰动自证）。

## 7. 我这边新立的取证枪（host 侧，零设备）
- `vkh_gguf_tensors.py` —— GGUF 张量表普查 + 按 `use_adreno_kernels`/`type_has_gemm`/`small_weight` 判据逐条代入（哑火 #24：我第一版把 GGUF 标量表错位一格 ⇒ KeyError，已按规范摆正；类型名改从本树 `ggml.h` enum 取）。
- `vkh_ht_perpass.py` —— per-token 聚合：`Σ[host-timing].host_ms ÷ gen`，带 `graph_explosion` 形态闸（>60 图/token 分栏列判词）。
