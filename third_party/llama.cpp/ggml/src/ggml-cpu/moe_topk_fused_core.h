// moe_topk_fused_core.h -- [tongyi M-R1 2026-10-25] fused grouped-MoE router
// top-k, pure core (no ggml / OpenCL deps) so that:
//   * ggml-cpu/ops.cpp uses it as the CPU reference implementation, and
//   * the desktop A/B test (_probe/moe_probe/moe_topk_fused_route_test.cpp)
//     cross-checks it against an independently transcribed simulation of the
//     build_moe_ffn graph chain (two-eyes discipline, cf. tongyi_route_table).
//
// Semantics contract = byte-exact transcription of build_moe_ffn's routing
// section (src/llama-graph.cpp, gated on n_expert_groups > 1):
//   1. probs = sigmoid(logits)                                  [caller]
//   2. selection = probs + exp_probs_b (ggml_add; skip when no bias)
//   3. per group g of epg experts: argsort_top_k(sel[g], 2) (DESC, strict >,
//      std::sort over identity indices) -> get_rows -> sum_rows
//      (sequential adds over the sorted values)
//   4. argsort_top_k(gsum, gu) -> expert_groups (only the SET matters: the
//      mask is a union, placement is order-independent)
//   5. masked = set_rows(fill(-inf), values of selected groups)
//   6. selected = argsort_top_k(masked, K)
//   7. w[k] = probs[selected[k]]        (UNBIASED gather, ggml_get_rows)
//      s = sum_rows(w) (sequential)     (ggml_sum_rows over [K, n_tokens])
//      s = clamp(s, 6.103515625e-5, +inf) == MAX(MIN(s, inf), min)
//      w[k] /= s                        (ggml_div)
//      w[k] *= w_scale iff w_scale != 0 && != 1 (ggml_scale)
//   8. ids[k] = selected[k]
//
// Tie discipline: real ties only occur among -inf masked entries (outside the
// top-8 whenever >= K finite candidates exist). The CPU reference reuses the
// exact same std::sort + strict-> comparator as the graph path (ops.cpp
// cmp_argsort), so CPU-vs-CPU is byte-identical by construction; the OpenCL
// kernel's ordered argmax may only differ on exact fp32 ties of finite
// scores (accepted, e2e text-diff is the arbiter).
#ifndef MOE_TOPK_FUSED_CORE_H
#define MOE_TOPK_FUSED_CORE_H

#include <algorithm>
#include <cmath>
#include <stdint.h>

namespace moe_topk_core {

// hard capacity (mirrors the OpenCL kernel's local memory arrays)
static const int kMaxE  = 128;
static const int kMaxG  = 8;
static const int kMaxGu = 4;
static const int kMaxK  = 8;

// smallest number representable by F16 -- the ggml_clamp in build_moe_ffn
static const float kMinWeightSum = 6.103515625e-5f;

// strict > comparator: same as cmp_argsort<GGML_SORT_ORDER_DESC> (ops.cpp:8798)
struct cmp_argsort_desc {
    const float * data;
    bool operator()(int32_t a, int32_t b) const {
        return data[a] > data[b];
    }
};

struct Workspace {
    float   p[kMaxE];       // unbiased sigmoid probs
    float   sel[kMaxE];     // selection scores (probs + bias)
    float   gsum[kMaxG];
    float   masked[kMaxE];
    int32_t idx[kMaxE];
    float   w[kMaxK];
};

// One token row. p[E] = unbiased sigmoid probs (caller computes with the same
// expression as ggml_vec_sigmoid_f32: 1.f / (1.f + expf(-x))). bias may be
// NULL. Writes w_out[K] (normalized + scaled) and ids_out[K].
inline void route_row(
        const float * p,
        const float * bias,
        int E, int G, int epg, int gu, int K,
        float w_scale,
        float * w_out,
        int32_t * ids_out,
        Workspace & ws) {
    // 2) selection scores
    if (bias) {
        for (int i = 0; i < E; ++i) ws.sel[i] = p[i] + bias[i];
    } else {
        for (int i = 0; i < E; ++i) ws.sel[i] = p[i];
    }

    // 3) per-group top-2 sum
    for (int g = 0; g < G; ++g) {
        const float * row = ws.sel + g*epg;
        for (int j = 0; j < epg; ++j) ws.idx[j] = j;
        std::sort(ws.idx, ws.idx + epg, cmp_argsort_desc{row});
        // sum_rows over the gathered top-2 (sequential adds, sorted order)
        ws.gsum[g] = row[ws.idx[0]] + row[ws.idx[1]];
    }

    // 4) group top-gu
    for (int g = 0; g < G; ++g) ws.idx[g] = g;
    std::sort(ws.idx, ws.idx + G, cmp_argsort_desc{ws.gsum});

    // 5) mask: fill(-inf) + set_rows(selected group values)
    for (int i = 0; i < E; ++i) ws.masked[i] = -INFINITY;
    for (int j = 0; j < gu; ++j) {
        const int g0 = ws.idx[j];
        for (int i = 0; i < epg; ++i) {
            ws.masked[g0*epg + i] = ws.sel[g0*epg + i];
        }
    }

    // 6) global top-K
    for (int i = 0; i < E; ++i) ws.idx[i] = i;
    std::sort(ws.idx, ws.idx + E, cmp_argsort_desc{ws.masked});

    // 7) weights: unbiased gather + clamp/sum/div(/scale) normalization
    for (int k = 0; k < K; ++k) ws.w[k] = p[ws.idx[k]];
    float s = 0.f;
    for (int k = 0; k < K; ++k) s += ws.w[k];
    s = s > kMinWeightSum ? s : kMinWeightSum;
    for (int k = 0; k < K; ++k) w_out[k] = ws.w[k] / s;
    if (w_scale != 0.0f && w_scale != 1.0f) {
        for (int k = 0; k < K; ++k) w_out[k] *= w_scale;
    }

    // 8) ids
    for (int k = 0; k < K; ++k) ids_out[k] = ws.idx[k];
}

} // namespace moe_topk_core

#endif // MOE_TOPK_FUSED_CORE_H
