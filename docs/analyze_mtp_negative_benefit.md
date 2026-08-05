# MTP 负收益根因分析 + 修复（对比 llama.cpp / llamacpp.rn 成功经验）

> 结论先行：**MTP 循环结构移植是正确的**（与 llamacpp.rn `refill_mtp_tokens()` 逐句一致），
> **MTP 头前向只跑 1 层、不是全模型**——所以旧会话"每步 3 次完整前向"的定性是错的。
> 负收益的真凶是 **cost 结构 × acceptance 的权衡**：每次迭代 verify 一个 `(1+n_draft)` token 的 batch，
> 当 acceptance 只有 0~1/3 时，付出的 verify 成本收不回来。修复 = 自适应 draft 预算 + 低置信度早停。

---

## 1. 逐项比对：自定义循环 vs llama.cpp / llamacpp.rn

### 1.1 循环结构（完全一致，无结构 bug）

| 步骤 | TongYi-Lite 自定义 | llama.cpp `speculative-simple.cpp` | llamacpp.rn `refill_mtp_tokens()` |
|---|---|---|---|
| draft | `common_speculative_draft()` | 同 | 同 |
| wipe draft 区 | `seq_rm(mtp_ctx, n_past, -1)` | `seq_rm(ctx_dft, ...)` | `common_context_seq_rm(spec_ctx, spec_n_past, -1)` |
| verify | `llama_decode(context, [id_last+drafts])` | 同 | 同 |
| 镜像同步 | `common_speculative_process(spec, batch)` | 同 | 同 |
| accept | `common_sampler_sample_and_accept_n` + `common_speculative_accept` | 同 | 同 |
| 回滚 | `seq_rm(context)` + `seq_rm(mtp_ctx)` | `seq_rm(ctx_tgt)` + `seq_rm(ctx_dft)` | `common_context_seq_rm(parent_ctx)` + `common_context_seq_rm(spec_ctx)` |

KV 位置记账（id_last 在 `P`，draft 在 `P+1..P+N`，accept 后 `n_past += ids.size()-1`，`seq_rm(n_past)`）逐一核对一致。
`pending_h`（MTP 头跨步隐状态）由 `accept()` 从 `verify_h[n_accepted]` 拷贝，与官方相同。

### 1.2 MTP 头成本（关键修正）

`qwen35.cpp:487 graph_mtp`（`LLM_GRAPH_TYPE_DECODER_MTP`）只构建：
`tok_embd + eh_proj + 1 层 attention + 共享头`。**不重跑主干 28~40 层**。

→ 每次 draft/process 的 MTP 头前向 ≈ **1/28 ~ 1/40 的目标前向**，不是"完整前向"。
旧会话"每步 draft + verify + process 三次完整前向"的定性**不成立**。

### 1.3 真正成本模型（per 迭代，n_draft=N）

```
MTP 头:   N+1 次单 token decode（draft）+ 1 次 batch decode（process）≈ (N+2)/L 目标
verify:   1 次 (1+N) token 的 batch decode
每次迭代产出 = 1 + a 个 token（a = 接受数）
```

- **compute-bound（4B 偏计算密集）**：`verify(1+N) ≈ (1+N)×verify(1)`，要 **a ≥ N** 才回本。
  实测 a≈0~1 → 每 token 成本 > 普通自回归 → **负收益**（符合"速度减半"）。
- **memory-bound（0.8B 偏内存带宽）**：`verify(1+N) ≈ verify(1)`（批处理共享权值加载），a≥1 即可正收益。
  0.8B 也负收益 → 说明 MTP 头 decode 的独立 context 图提交有固定开销，且 acceptance 过低。

### 1.4 acceptance 为何只有 0~1/3

1. **draft 头 greedy（`top_k=10` → argmax）vs 目标采样 temp=0.7**：
   `sample_and_accept_n` 用目标 temp-0.7 分布采样，只有采样到 greedy token 才接受 → acceptance 被压到 ~0.4~0.6，
   对弱 MTP 头更低。
2. **无早停**：旧代码 `p_min=0` → 头不确定时也硬 draft 满 N 个 → 白付 verify 钱。
3. unsloth 转换的 Qwen3.5 MTP 头本身质量偏弱（接受率比理论低）。

---

## 2. 修复（已落地 `tongyilite_jni.cpp`）

1. **自适应 draft 预算**：追踪滑动接受率，接受率 <0.5 → n_draft 降到 2/1，≥0.75 恢复满预算。
   → verify batch 从 `1+3` 缩到 `1+1`，低接受率时不再为被拒 draft 付 verify 钱。
2. **低置信度早停** `p_min=0.3`（官方 speculative.cpp 的既有机制，旧代码用 0 禁用了它）：
   头 top-1 概率低于阈值就停止 draft，直接省掉被拒 draft + 对应 verify 前向。
3. 保留 `n_min=1`：始终至少 draft 1 个，保证循环不断。
4. 日志：每轮输出 `accept_rate` 与 `adaptive_n_draft`，便于真机验证。

## 3. 待验证 / 后续可选

- 真机对比 MTP 开/关的 tok/s 与 `accept_rate`；若 4B 仍负，考虑把 `n_draft_max` 默认降到 2。
- 若想进一步抬 acceptance：让 draft 头采样分布贴近目标（需在 mtp_ctx 上配 backend sampler 链），
  或把 verify 目标采样 temp 调低（会改变输出风格，需权衡）。
- 参考 server `slot.get_n_draft_max()`：按剩余 token / 上下文预算动态限幅（本项目已按 KV 预算 clamp）。
