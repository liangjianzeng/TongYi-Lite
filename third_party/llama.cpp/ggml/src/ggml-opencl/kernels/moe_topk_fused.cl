// moe_topk_fused.cl -- [tongyi M-R1 2026-10-25] fused MoE router top-k pipeline.
//
// Replaces the per-layer plumbing chain emitted by build_moe_ffn (llama-graph.cpp):
//   SIGMOID + ADD(bias) + ARGSORT_TOP_K(2/group) + GET_ROWS + SUM_ROWS
//   + ARGSORT_TOP_K(4 groups) + GET_ROWS + FILL(-inf) + SET_ROWS
//   + ARGSORT_TOP_K(8) + GET_ROWS(weights) + MUL/DIV(norm)
// with ONE kernel for grouped-MoE architectures (bailingmoe3/Ling: E=128, G=8,
// epg=16, group_used=4, k=8). ~13 kernels/layer -> 1 (+1 downstream f32->i32 cpy).
//
// Semantics contract (byte-equivalence with the graph path):
//   * sigmoid uses the SAME expression as kernels/sigmoid.cl
//     (1.0f / (1.0f + exp(-x))) and the SAME compile flags
//     (backend kernel_compile_opts, incl. -cl-fast-relaxed-math) so the fused
//     probs are bit-identical with the old path's kernel_sigmoid_f32.
//   * selection uses sel = sigmoid(logits) + bias; weights gather uses the
//     UNBIASED p = sigmoid(logits) (weights = get_rows(probs, selected)).
//   * comparator is strict > (cmp_argsort<DESC>, ops.cpp:8798); ties resolved
//     by lowest index via ordered argmax scan. Real ties only occur among -inf
//     masked entries (outside top-8 when >=8 finite candidates exist) or on
//     exact fp32 ties of finite scores (rare; e2e text-diff is the arbiter).
//   * weight normalization: w_i /= max(sum(w), 6.103515625e-5f)  -- the clamp
//     from ggml_clamp in build_moe_ffn (weights_sum); then w_i *= w_scale
//     (ggml_scale) when the graph passed a real scaling factor.
//   * ids are stored as EXACT float values (NOT bit-cast): the graph wires
//     them through ggml_cast(F32 -> I32), which is a numeric conversion in
//     ggml (f32_to_i32), so as_float() denormals would truncate to 0. Exact
//     for ids < 2^24.
//
// Dst layout [K, n_tokens, 2] F32 (flat, row-major):
//   dst[row*K + k]              = weights[k]   (plane 0)
//   dst[K*nt + row*K + k]       = (float)id[k] (plane 1)
//
// Launch: ONE workgroup per token row, local_size = 128 (one thread/expert).
// Args (fork convention): base pointers + ulong offsets.

#pragma OPENCL EXTENSION cl_khr_fp16 : enable

__kernel void kernel_moe_topk_fused(
        __global const float * logits,   // [E x nt]
        const ulong offset0,
        __global const float * bias,     // [E], unused when has_bias == 0
        const ulong offset1,
        __global float * dst,            // [K, nt, 2]
        const ulong offsetd,
        const int E,
        const int G,
        const int epg,                   // E / G
        const int gu,                    // groups used
        const int K,                     // experts used
        const int nt,                    // n_tokens (for the ids plane base)
        const int has_bias,
        const float w_scale) {
    const int t = get_local_id(0);
    const int row = get_group_id(0);     // one workgroup per token

    __global const float * lg = (__global const float *)((__global const char *) logits + offset0);
    __global const float * bs = (__global const float *)((__global const char *) bias   + offset1);
    __global float * out = (__global float *)((__global char *) dst + offsetd);

    __local float p_sel[128];    // sigmoid + bias (selection score)
    __local float p_raw[128];    // sigmoid only (weight source)
    __local float gsum[8];       // per-group top-2 sum
    __local int   gsel[4];       // selected group ids (gu <= 4)
    __local float masked[128];
    __local int   topk[8];

    // 1) probs (bit-identical with kernel_sigmoid_f32)
    if (t < E) {
        const float x = lg[row*E + t];
        const float s = 1.0f / (1.0f + exp(-x));
        p_raw[t] = s;
        p_sel[t] = has_bias ? (s + bs[t]) : s;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 2) per-group top-2 sum (thread g scans its epg members serially; the
    //    sum order matches the graph's get_rows + sum_rows: top1 + top2)
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

    // 3) top-gu groups by gsum (gu <= 4; ordered argmax, tie = lowest index).
    //    Only the SET of selected groups matters (the mask is a union).
    if (t == 0) {
        for (int j = 0; j < gu; ++j) {
            int bi = -1; float bv = -INFINITY;
            for (int g = 0; g < G; ++g) {
                if (gsum[g] > bv) { bv = gsum[g]; bi = g; }
            }
            gsel[j] = bi;
            gsum[bi] = -INFINITY;   // remove from candidacy
        }
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 4) group mask: keep values of selected groups, -inf elsewhere
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

    // 6) weights: gather unbiased probs by selected ids; ids as exact floats
    if (t < K) {
        const int e = topk[t];
        out[row*K + t] = p_raw[e];                    // plane 0: weights
        out[K*nt + row*K + t] = (float) e;            // plane 1: ids
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // 7) normalize: sum (sequential, k order = sum_rows), clamp, div, scale
    if (t == 0) {
        float s = 0.0f;
        for (int j = 0; j < K; ++j) s += out[row*K + j];
        s = s > 6.103515625e-5f ? s : 6.103515625e-5f;
        for (int j = 0; j < K; ++j) out[row*K + j] /= s;
        if (w_scale != 0.0f && w_scale != 1.0f) {
            for (int j = 0; j < K; ++j) out[row*K + j] *= w_scale;
        }
    }
}
