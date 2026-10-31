// [dllm-lab K4#6 2026-10-31] implementation -- see clover_block.h for provenance.
#include "clover_block.h"

#include <algorithm>
#include <cstring>

bool clover_block_mask_token_ok(const llama_vocab * vocab) {
    return vocab != nullptr && llama_vocab_mask(vocab) != LLAMA_TOKEN_NULL;
}

size_t clover_block_save_state(llama_context * ctx, llama_seq_id seq_id, std::vector<uint8_t> & buf) {
    const size_t sz = llama_state_seq_get_size_ext(ctx, seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
    buf.resize(sz);
    if (sz == 0) {
        return 0;
    }
    return llama_state_seq_get_data_ext(ctx, buf.data(), sz, seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
}

bool clover_block_restore_state(llama_context * ctx, llama_seq_id seq_id,
                                const std::vector<uint8_t> & buf, llama_pos keep_from) {
    if (buf.empty()) {
        return false;
    }
    const size_t n = llama_state_seq_set_data_ext(
            ctx, buf.data(), buf.size(), seq_id, LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY);
    if (n != buf.size()) {
        return false;
    }
    return llama_memory_seq_rm(llama_get_memory(ctx), seq_id, keep_from, -1);
}

bool clover_block_draft(llama_context * ctx, llama_seq_id seq_id, llama_pos pos0,
                        llama_token id_last, int32_t n_max, llama_token mask,
                        std::vector<llama_token> & out) {
    if (!ctx || n_max < 1 || mask == LLAMA_TOKEN_NULL) {
        return false;
    }
    const int32_t rows = n_max + 1;   // block shape is fixed: anchor row + n_max masked rows

    std::vector<llama_token>  toks(rows, mask);
    std::vector<llama_pos>    pos(rows);
    std::vector<int32_t>      n_seq_id(rows, 1);
    std::vector<llama_seq_id> seq_store(rows, seq_id);
    std::vector<llama_seq_id *> seq_ids(rows);
    std::vector<int8_t>       logits(rows, 1);

    toks[0] = id_last;                // anchor row, mirrors add_masked_block(i == 0 ? id_last : mask)
    for (int32_t i = 0; i < rows; ++i) {
        pos[i]     = pos0 + i;
        seq_ids[i] = &seq_store[i];
    }

    llama_batch batch = {};
    batch.n_tokens  = rows;
    batch.token     = toks.data();
    batch.embd      = nullptr;
    batch.pos       = pos.data();
    batch.n_seq_id  = n_seq_id.data();
    batch.seq_id    = seq_ids.data();
    batch.logits    = logits.data();

    // the one and only non-causal window (mirrors speculative.cpp:1548-1550)
    llama_set_causal_attn(ctx, false);
    const int rc = llama_decode(ctx, batch);
    llama_set_causal_attn(ctx, true);
    if (rc != 0) {
        return false;
    }

    const llama_model   * model = llama_get_model(ctx);
    const llama_vocab   * vocab = llama_model_get_vocab(model);
    const int32_t         n_vocab = llama_vocab_n_tokens(vocab);

    out.clear();
    out.reserve(n_max);
    for (int32_t i = 0; i < n_max; ++i) {
        const float * lg = llama_get_logits_ith(ctx, i + 1);   // row 0 is the anchor, not drafted from
        if (!lg) {
            out.clear();
            return false;
        }
        // std::max_element picks the FIRST maximum == lowest id on ties (clover tie rule)
        const float * best = std::max_element(lg, lg + n_vocab);
        out.push_back((llama_token) (best - lg));
    }
    return true;
}
