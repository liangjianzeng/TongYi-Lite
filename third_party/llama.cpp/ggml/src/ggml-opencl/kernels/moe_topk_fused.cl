// moe_topk_fused.cl -- [tongyi M-R1 2026-10-25] fused MoE router top-k pipeline.
//
// Replaces the per-layer plumbing chain emitted by build_moe_ffn (llama-graph.cpp):
//   SIGMOID + ADD(bias) + ARGSORT_TOP_K(2/group) + GET_ROWS + SUM_ROWS
//   + ARGSORT_TOP_K(4 groups) + GET_ROWS + FILL(-inf) + SET_ROWS
//   + ARGSORT_TOP_K(8) + GET_ROWS(weights) + MUL/DIV(norm)
// with ONE kernel for grouped-MoE architectures (bailingmoe3: E=128, G=8,
// epg=16, group_used=4, k=8). ~13 kernels/layer -> 1 (+1 downstream cast).
//
// Semantics contract (byte-equivalence with the graph path):
//   * selection uses sel = sigmoid(logits) + bias; weights gather uses the
//     UNBIASED p = sigmoid(logits) (weights = get_rows(probs, selected)).
//   * comparator is strict > (cmp_argsort<DESC>, ops.cpp:8798); ties resolved
//     by lowest index via ordered argmax scan. Real ties only occur among -inf
//     masked entries (outside top-8 when >=8 finite candidates exist).
//   * weight normalization: w_i /= max(sum(w), 6.103515625e-5f)  -- the clamp
//     from ggml_clamp in build_moe_ffn (weights_sum).
//
// Dst layout: float dst[16] = { w[0..7] (f32), ids[0..7] (f32-bit-cast i32) }.
// The graph wires ids through a CAST node into I32 for MUL_MAT_ID's src2.
//
// Launch: ONE workgroup, local_size = 128 (one thread per expert).
// Args: logits [E] f32, bias [E] f32, dst [16] f32, E, G, epg, gu, K.

#pragma OPENCL EXTENSION cl_khr_fp16 : enable

__kernel void kernel_moe_topk_fused(
        __global const float * logits,   // [E]
        __global const float * bias,     // [E], may contain 0 when no bias
        __global float * dst,            // [2*K]
        const int E,
        const int G,
        const int epg,                   // E / G
        const int gu,                    // groups used
        const int K) {                   // experts used
    const int t = get_local_id(0);
    const int lsz = get_local_size(0);

    __local float p_sel[128];    // sigmoid + bias (selection score)
    __local float p_raw[128];    // sigmoid only (weight source)
    __local float gsum[8];       // per-group top-2 sum
    __local int   gsel[4];       // selected group ids (gu <= 4)
    __local float masked[128];
    __local int   topk[8];

    // 1) probs
    if (t < E) {
        const float x = logits[t];
        const float s = 1.0f / (1.0f + exp2(-1.4426950408889634f * x)); // sigmoid
        p_raw[t]  = s;
        p_sel[t]  = s + bias[t];
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 2) per-group top-2 sum (each group = epg threads; thread 0 of the group
    //    scans its epg members serially -- epg <= 32, E <= 128 work total)
    if (t < G) {
        const int base = t * epg;
        float best1 = -INFINITY, best2 = -INFINITY;
        for (int j = 0; j < epg; ++j) {
            const float v = p_sel[base + j];
            if (v > best1) { best2 = best1; best1 = v; }
            else if (v > best2) { best2 = v; }
        }
        gsum[t] = best1 + best2;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 3) top-gu groups by gsum (gu <= 4; deterministic tie = lowest index)
    if (t == 0) {
        for (int j = 0; j < gu; ++j) {
            int bi = -1; float bv = -INFINITY;
            for (int g = 0; g < G; ++g) {
                if (gsum[g] > bv) { bv = gsum[g]; bi = g; }
            }
            gsel[j] = bi;
            gsum[bi] = -INFINITY;   // remove from candidacy
        }
        // restore gsum not needed afterwards
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 4) group mask: in-group flag per thread
    if (t < E) {
        const int g = t / epg;
        bool in = false;
        for (int j = 0; j < gu; ++j) { if (gsel[j] == g) { in = true; break; } }
        masked[t] = in ? p_sel[t] : -INFINITY;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 5) global top-K by masked score (ordered argmax x K; lowest-index tie)
    if (t == 0) {
        for (int j = 0; j < K; ++j) {
            int bi = -1; float bv = -INFINITY;
            for (int e = 0; e < E; ++e) {
                if (masked[e] > bv) { bv = masked[e]; bi = e; }
            }
            topk[j] = bi;
            if (bi >= 0) masked[bi] = -INFINITY;
        }
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 6) weights: gather unbiased probs by selected ids + normalize
    if (t < K) {
        const int e = topk[t];
        dst[K + t] = as_float(e);                       // ids bit-cast to f32
        float w = (e >= 0) ? p_raw[e] : 0.0f;
        // sequential normalize: sum first, then divide
        dst[t] = w;                                      // temp store
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (t == 0) {
        float s = 0.0f;
        for (int j = 0; j < K; ++j) s += dst[j];
        s = max(s, 6.103515625e-5f);
        for (int j = 0; j < K; ++j) dst[j] /= s;
    }
}
