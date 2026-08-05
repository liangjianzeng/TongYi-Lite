# 跨轮 KV 增量 Prefill + MTP 合并实现方案

> 适用对象：正在 `tongyilite_jni.cpp` 实现 MTP 投机解码的那个会话。  
> 目标：在**不破坏 MTP 解码循环**的前提下，根治"多轮对话首 TOK 越来越慢"——把每轮"全量清空 KV + 全量重算历史"改为"保留历史 KV、只喂新 token"。两者必须落在**同一次 `completion()` 重构**里，否则会二次触碰这段最脆弱的代码。

---

## 1. 根因（已核实当前代码）

`completion()` 顶部（当前 `tongyilite_jni.cpp:680`）：

```cpp
if (!llama_memory_seq_rm(llama_get_memory(context), 0, 0, (llama_pos)ctx_val)) { ... }
kv_position = 0;
```

**每轮都 `seq_rm(0, 0, n_ctx)` 清空整段 KV，再在第 872–902 行把整段 `prompt_tokens`（= 全量对话历史）重新 prefill。**  
历史越长 → 每轮 prefill 的 token 越多 → 首 TOK（TTFT）越慢。实测第三轮 327 token / 21.6s。

`n_ubatch=512` 只加速"给定长度"的 prefill，不阻止长度随轮次增长——所以必须改策略，而不是调参数。

---

## 2. 核心设计原则（务必先读）

**KV 增量 prefill 是 MTP 驱动「下面那一层」。**

- MTP 驱动（`common_speculative_*`）工作在 **prompt 语义层**：它关心的是"prompt 是什么"（用 `mtp_prompt_tgt` / `mtp_id_last` / `mtp_n_past` 表达，见 :853-855、:985-992）。
- KV 增量 prefill 只改变 **prompt 的 KV 是怎么来的**（全量重算 vs 只补后缀）。
- **只要最终 KV 状态 ≡ 整段 prompt，MTP 的视图就完全等价**，无需改 MTP 的 prompt 语义逻辑。

→ 因此本方案**不碰** MTP 的 `spec_params` / `mtp_prompt_tgt` / `mtp_id_last` / `mtp_n_past` 计算，只改：

1. 顶部 `seq_rm` 从"全清"变"只清发散后缀"；
2. prefill 循环从"prefill 全部"变"只 prefill `[prefix, end)`"；
3. 轮末把"本轮 prompt + 本轮生成"缓存，供下轮求公共前缀。

---

## 3. 新增成员状态（JNI 类内）

```cpp
std::vector<llama_token> prev_prompt_tokens;  // 上轮完整 prompt tokens（模板后、截断后）
bool                    have_prev_kv = false;  // 当前 KV 是否 ≡ prev_prompt_tokens
```

> 注意：`prev_prompt_tokens` 必须在**截断之后**（见 :792-803 的 gen_budget 截断）再赋值，保证与 KV 中实际内容一致。

---

## 4. 代码改动（按行定位）

### 4.1 顶部：增量 seq_rm 取代全清（改 :680-685）

```cpp
// ---- 跨轮 KV 增量 prefill：求公共前缀，只清发散后缀 ----
int prefix_len = 0;
if (have_prev_kv && !prev_prompt_tokens.empty()) {
    prefix_len = longest_common_prefix(prev_prompt_tokens, prompt_tokens);
    if (prefix_len >= 1 && prefix_len < n_prompt) {
        // 保留前缀 KV，只删 [prefix_len, end)
        llama_memory_seq_rm(llama_get_memory(context), 0, prefix_len, (llama_pos)ctx_val);
        // ⚠️ mtp_ctx 与 context 共享 KV 但各自维护序列视图，必须同步清理
        if (mtp_ctx != nullptr)
            llama_memory_seq_rm(llama_get_memory(mtp_ctx), 0, prefix_len, (llama_pos)ctx_val);
        kv_position = prefix_len;        // 关键：不要归零！
        LOGI("KV incremental: kept prefix=%d, will prefill only %d tokens (saved %d)",
             prefix_len, n_prompt - prefix_len, prefix_len);
    } else {
        full_clear();                    // prefix==0 或 prefix>=n_prompt → 退回全清
    }
} else {
    full_clear();                        // 首轮 / 模型切换 / resetContext
}
```

其中 `full_clear()` 封装现有逻辑：

```cpp
auto full_clear = [&]() {
    llama_memory_seq_rm(llama_get_memory(context), 0, 0, (llama_pos)ctx_val);
    if (mtp_ctx) llama_memory_seq_rm(llama_get_memory(mtp_ctx), 0, 0, (llama_pos)ctx_val);
    kv_position = 0;
    have_prev_kv = false;
};
```

### 4.2 Prefill 循环：只喂后缀（改 :867、:872）

```cpp
llama_pos cur_pos = (llama_pos)prefix_len;   // ← 从前缀末尾继续，不再从 0
int i = prefix_len;                           // ← 跳过已 prefill 的前缀
while (i < n_prompt) {
    const int32_t chunk = std::min((int32_t)n_batch, n_prompt - i);
    llama_batch tok_batch = llama_batch_init(chunk, 0, 1);
    tok_batch.n_tokens = chunk;
    for (int32_t j = 0; j < chunk; ++j) {
        tok_batch.token[j]   = prompt_tokens[i + j];
        tok_batch.pos[j]     = cur_pos + j;     // 绝对位置，与 KV 对齐
        tok_batch.n_seq_id[j]  = 1;
        tok_batch.seq_id[j][0] = 0;
        tok_batch.logits[j] = (i + j == n_prompt - 1) ? 1 : 0;
    }
    if (llama_decode(context, tok_batch) != 0) { ... }
    if (mtp_spec) common_speculative_process(mtp_spec, tok_batch);  // 同步 mtp_ctx
    llama_batch_free(tok_batch);
    cur_pos += chunk; i += chunk;
}
kv_position = cur_pos;   // == n_prompt，与现状一致
```

> prefill 开销从 `O(n_prompt)` 降为 `O(n_prompt - prefix_len)`。多轮场景下 `prefix_len ≈ n_prompt - Δ`，Δ = 本轮新增 user 消息 token 数（通常 10–30），**TTFT 变为每轮常数**。

### 4.3 MTP 设置：无需改动（:822-857、:985-992）

`mtp_prompt_tgt` / `mtp_id_last` / `mtp_n_past` 全部由 `prompt_tokens` 推导，与 KV 如何生成无关。最终 KV ≡ 整段 prompt，驱动视图不变。**保持原样。**

### 4.4 两条解码循环：收集本轮生成 token

MTP 循环（:962-1058）与 plain 循环（:1061+）都需用同一个 `std::vector<llama_token> gen_tokens` 收集每次 `emit_token(tok)` 的 `tok`（可在 `emit_token` lambda 内 `gen_tokens.push_back(tok)`，两个分支共用）。

### 4.5 轮末：写回缓存（在 `completion()` 返回前）

```cpp
prev_prompt_tokens = prompt_tokens;                       // 本轮完整 prompt
prev_prompt_tokens.insert(prev_prompt_tokens.end(),
                           gen_tokens.begin(), gen_tokens.end());  // + 本轮生成
have_prev_kv = true;
```

下轮 `prompt_tokens` = 模板(全历史 + 新 user 消息)，其与 `prev_prompt_tokens` 的公共前缀恰好 = 全部历史 + 本轮回复，发散点 = 新 user 消息 → 只 prefill 新增部分。✅

### 4.6 resetContext / 模型切换：清缓存

`resetContext()`（:600-606）与模型卸载处补：

```cpp
prev_prompt_tokens.clear();
have_prev_kv = false;
```

---

## 5. 第一风险点（必须真机验证）

**`mtp_ctx` 的 KV 一致性。** `mtp_ctx` 以 `ctx_type=LLAMA_CONTEXT_TYPE_MTP`、`ctx_other=context` 创建（:534-545），与 context **共享 KV buffer 但各自维护序列视图**。解码阶段现有代码对 `context` 与 `mtp_ctx` 分别 `seq_rm`（:997、:1053-1054），说明 KV 操作需**显式双写**。

→ 增量 prefill 顶部的 `seq_rm` 同样必须**双写**（见 4.1 的 `if (mtp_ctx) ...`）。但 `mtp_ctx` 在 prefill 阶段是靠 `common_speculative_process` 镜像填充的，其"已填充到的位置"是否严格等于 `prefix_len` 需要验证。

**验证动作**：在真机加载一个带 head 的模型，跑 3 轮对话，对比：

- 增量路径下 `mtp_ctx` 解码是否产生合理 logits（无 padding/-127 塌缩、无乱码）；
- 若 `mtp_ctx` 视图错位，则需在 `common_speculative_begin` 之前额外对 `mtp_ctx` 做一次 `seq_rm(0, prefix_len, n_ctx)` 或重建 draft 上下文状态（参考 `server-context.cpp` 的 `update_slots` 对 draft ctx 的处理）。

---

## 6. 守卫与回退（确保零回归）

| 条件                                           | 行为                                        |
| -------------------------------------------- | ----------------------------------------- |
| `prefix_len == 0` 或 `prefix_len >= n_prompt` | 退回 `full_clear()`（当前行为）                   |
| 模型切换 / `resetContext()` / 新会话                | `have_prev_kv=false` → 全清                 |
| `n_prompt`（截断后）超过 `gen_budget`（:792-803）     | 先截断再增量；截断规则保持尾部，前缀仍有效                     |
| 增量后 KV 仍放不下（`prefix_len + 生成预算 > n_ctx`）     | 退回截断 + 全量重 prefill                        |
| `!mtp_enabled`（无 NextN head 的模型）             | 增量 prefill 仍生效（TTFT 修复与解码方式解耦）；plain 循环照常 |



> 增量 prefill **独立于 MTP**：即使模型无 head，多轮 TTFT 也会被修好；MTP 只在有 head 时再叠加解码加速。两者正交，可分别验证。

---

## 7. 验证清单（真机）

1. 下载 `qwen3.5-4b-q4_k_m`（`assets/models_catalog.json:46`），确认 `llama_model_n_layer_nextn() > 0`。
2. 加日志 `KV incremental: kept prefix=%d, will prefill only %d`（4.1）与 MTP `accepted %zu/%zu`。
3. 跑 5 轮对话，确认：
   - TTFT 不再随轮次增长（第 1 轮 ≈ 第 5 轮）；
   - 生成无乱码、接受率合理（1.5–2.5× 加速）；
   - logcat 无 `seq_rm`/`decode` 报错、`mtp_ctx` 无塌缩。
4. 对比同模型：开/关增量 prefill 的 TTFT 与 tok/s。

---

## 8. 不要做的事

- **不要**重写 MTP 的 prompt 语义逻辑（`mtp_prompt_tgt` / `mtp_n_past`），它是对的。
- **不要**在 `completion()` 外另起一套 KV 管理（如每轮 `llama_init_from_model`）——历史已证明会产出乱码（见 :672-674 注释）。
- **不要** `git add -A` 把其他会话的未提交改动一起提交；本方案只改 `tongyilite_jni.cpp` 局部，且须与上述 MTP 实现合并在同一工作树。
- **必须**保留 `full_clear()` 回退路径，作为开关失效/异常时的安全网。
