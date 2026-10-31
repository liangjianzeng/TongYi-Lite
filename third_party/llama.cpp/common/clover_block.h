// [dllm-lab K4#6 2026-10-31] masked-block drafting + checkpoint rollback common piece.
// Ported from PR #31306 @ 4838ffb0c (locked, never chase):
//   - common_speculative_add_masked_block  (common/speculative.cpp:222-229)
//   - draft-self usage pattern             (common/speculative.cpp:1544-1562)
//   - caller loop shape                    (examples/speculative-simple/speculative-simple.cpp:170-336)
// Era-adapted to this tree (fe8156f baseline): llama_batch (no common_batch),
// llama_state_seq_*_ext checkpoints, llama_memory_seq_rm, llama_set/get_causal_attn.
//
// Semantics preserved:
//   * block is always n_max+1 rows: [id_last, mask, mask, ...]  (fixed shape, kernel-friendly)
//   * the block forward runs NON-causal (causal toggled off around exactly one llama_decode)
//   * drafted tokens = argmax rows 1..n_max; std::max_element => first max => lowest id on ties
//   * draft side saves target state (PARTIAL_ONLY) before the block and restores + seq_rm after,
//     so the block leaves zero trace in KV/recurrent state (verified end-to-end in lab:
//     dllm_spec accepts greedy == causal AR token-for-token, ledger dllm-L5/L3b).
//
// Zero-perturbation: no dispatcher wiring here. This is a library piece for future spec work
// (product-side golden word 2026-10-31, K4#6). Lab-side proof carrier: tool/legs/dllm_spec.cpp.
#ifndef COMMON_CLOVER_BLOCK_H
#define COMMON_CLOVER_BLOCK_H

#include "llama.h"

#include <cstddef>
#include <cstdint>
#include <vector>

// true when the vocab carries a usable mask token (draft-self precondition,
// mirrors the draft-self ctor check at speculative.cpp:1511)
bool clover_block_mask_token_ok(const llama_vocab * vocab);

// capture the sequence state before drafting (caller keeps the buffer across the block)
size_t clover_block_save_state(llama_context * ctx, llama_seq_id seq_id, std::vector<uint8_t> & buf);

// restore a captured state and drop the [keep_from, *) suffix (post-block rollback,
// mirrors speculative.cpp:1561-1562)
bool clover_block_restore_state(llama_context * ctx, llama_seq_id seq_id,
                                const std::vector<uint8_t> & buf, llama_pos keep_from);

// one masked-block forward: [id_last @ pos0, mask @ pos0+1 .. pos0+n_max], logits on every row,
// non-causal; writes n_max argmax tokens to out. Returns false on decode/logits failure.
// The context is restored to causal on return (success or failure).
bool clover_block_draft(llama_context * ctx, llama_seq_id seq_id, llama_pos pos0,
                        llama_token id_last, int32_t n_max, llama_token mask,
                        std::vector<llama_token> & out);

#endif // COMMON_CLOVER_BLOCK_H
