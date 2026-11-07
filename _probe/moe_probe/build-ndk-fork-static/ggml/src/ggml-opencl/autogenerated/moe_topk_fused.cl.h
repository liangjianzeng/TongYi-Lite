R"(// moe_topk_fused.cl -- [tongyi M-R1 2026-10-25] fused MoE router top-k pipeline.
)"
R"(//
)"
R"(// Replaces the per-layer plumbing chain emitted by build_moe_ffn (llama-graph.cpp):
)"
R"(//   SIGMOID + ADD(bias) + ARGSORT_TOP_K(2/group) + GET_ROWS + SUM_ROWS
)"
R"(//   + ARGSORT_TOP_K(4 groups) + GET_ROWS + FILL(-inf) + SET_ROWS
)"
R"(//   + ARGSORT_TOP_K(8) + GET_ROWS(weights) + MUL/DIV(norm)
)"
R"(// with ONE kernel for grouped-MoE architectures (bailingmoe3/Ling: E=128, G=8,
)"
R"(// epg=16, group_used=4, k=8). ~13 kernels/layer -> 1 (+1 downstream f32->i32 cpy).
)"
R"(//
)"
R"(// Semantics contract (byte-equivalence with the graph path):
)"
R"(//   * sigmoid uses the SAME expression as kernels/sigmoid.cl
)"
R"(//     (1.0f / (1.0f + exp(-x))) and the SAME compile flags
)"
R"(//     (backend kernel_compile_opts, incl. -cl-fast-relaxed-math) so the fused
)"
R"(//     probs are bit-identical with the old path's kernel_sigmoid_f32.
)"
R"(//   * selection uses sel = sigmoid(logits) + bias; weights gather uses the
)"
R"(//     UNBIASED p = sigmoid(logits) (weights = get_rows(probs, selected)).
)"
R"(//   * comparator is strict > (cmp_argsort<DESC>, ops.cpp:8798); ties resolved
)"
R"(//     by lowest index via ordered argmax scan. Real ties only occur among -inf
)"
R"(//     masked entries (outside top-8 when >=8 finite candidates exist) or on
)"
R"(//     exact fp32 ties of finite scores (rare; e2e text-diff is the arbiter).
)"
R"(//   * weight normalization: w_i /= max(sum(w), 6.103515625e-5f)  -- the clamp
)"
R"(//     from ggml_clamp in build_moe_ffn (weights_sum); then w_i *= w_scale
)"
R"(//     (ggml_scale) when the graph passed a real scaling factor.
)"
R"(//   * ids are stored as EXACT float values (NOT bit-cast): the graph wires
)"
R"(//     them through ggml_cast(F32 -> I32), which is a numeric conversion in
)"
R"(//     ggml (f32_to_i32), so as_float() denormals would truncate to 0. Exact
)"
R"(//     for ids < 2^24.
)"
R"(//
)"
R"(// Dst layout [K, n_tokens, 2] F32 (flat, row-major):
)"
R"(//   dst[row*K + k]              = weights[k]   (plane 0)
)"
R"(//   dst[K*nt + row*K + k]       = (float)id[k] (plane 1)
)"
R"(//
)"
R"(// Launch: ONE workgroup per token row, local_size = 128 (one thread/expert).
)"
R"(// Args (fork convention): base pointers + ulong offsets.
)"
R"(
)"
R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(__kernel void kernel_moe_topk_fused(
)"
R"(        __global const float * logits,   // [E x nt]
)"
R"(        const ulong offset0,
)"
R"(        __global const float * bias,     // [E], unused when has_bias == 0
)"
R"(        const ulong offset1,
)"
R"(        __global float * dst,            // [K, nt, 2]
)"
R"(        const ulong offsetd,
)"
R"(        const int E,
)"
R"(        const int G,
)"
R"(        const int epg,                   // E / G
)"
R"(        const int gu,                    // groups used
)"
R"(        const int K,                     // experts used
)"
R"(        const int nt,                    // n_tokens (for the ids plane base)
)"
R"(        const int has_bias,
)"
R"(        const float w_scale) {
)"
R"(    const int t = get_local_id(0);
)"
R"(    const int row = get_group_id(0);     // one workgroup per token
)"
R"(
)"
R"(    __global const float * lg = (__global const float *)((__global const char *) logits + offset0);
)"
R"(    __global const float * bs = (__global const float *)((__global const char *) bias   + offset1);
)"
R"(    __global float * out = (__global float *)((__global char *) dst + offsetd);
)"
R"(
)"
R"(    __local float p_sel[128];    // sigmoid + bias (selection score)
)"
R"(    __local float p_raw[128];    // sigmoid only (weight source)
)"
R"(    __local float gsum[8];       // per-group top-2 sum
)"
R"(    __local int   gsel[4];       // selected group ids (gu <= 4)
)"
R"(    __local float masked[128];
)"
R"(    __local int   topk[8];
)"
R"(
)"
R"(    // 1) probs (bit-identical with kernel_sigmoid_f32)
)"
R"(    if (t < E) {
)"
R"(        const float x = lg[row*E + t];
)"
R"(        const float s = 1.0f / (1.0f + exp(-x));
)"
R"(        p_raw[t] = s;
)"
R"(        p_sel[t] = has_bias ? (s + bs[t]) : s;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // 2) per-group top-2 sum (thread g scans its epg members serially; the
)"
R"(    //    sum order matches the graph's get_rows + sum_rows: top1 + top2)
)"
R"(    if (t < G) {
)"
R"(        const int base = t * epg;
)"
R"(        float best1 = -INFINITY, best2 = -INFINITY;
)"
R"(        for (int j = 0; j < epg; ++j) {
)"
R"(            const float v = p_sel[base + j];
)"
R"(            if (v > best1) { best2 = best1; best1 = v; }
)"
R"(            else if (v > best2) { best2 = v; }
)"
R"(        }
)"
R"(        gsum[t] = best1 + best2;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // 3) top-gu groups by gsum (gu <= 4; ordered argmax, tie = lowest index).
)"
R"(    //    Only the SET of selected groups matters (the mask is a union).
)"
R"(    if (t == 0) {
)"
R"(        for (int j = 0; j < gu; ++j) {
)"
R"(            int bi = -1; float bv = -INFINITY;
)"
R"(            for (int g = 0; g < G; ++g) {
)"
R"(                if (gsum[g] > bv) { bv = gsum[g]; bi = g; }
)"
R"(            }
)"
R"(            gsel[j] = bi;
)"
R"(            gsum[bi] = -INFINITY;   // remove from candidacy
)"
R"(        }
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // 4) group mask: keep values of selected groups, -inf elsewhere
)"
R"(    if (t < E) {
)"
R"(        const int g = t / epg;
)"
R"(        bool in = false;
)"
R"(        for (int j = 0; j < gu; ++j) { if (gsel[j] == g) { in = true; break; } }
)"
R"(        masked[t] = in ? p_sel[t] : -INFINITY;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // 5) global top-K by masked score (ordered argmax x K; lowest-index tie)
)"
R"(    if (t == 0) {
)"
R"(        for (int j = 0; j < K; ++j) {
)"
R"(            int bi = -1; float bv = -INFINITY;
)"
R"(            for (int e = 0; e < E; ++e) {
)"
R"(                if (masked[e] > bv) { bv = masked[e]; bi = e; }
)"
R"(            }
)"
R"(            topk[j] = bi;
)"
R"(            if (bi >= 0) masked[bi] = -INFINITY;
)"
R"(        }
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // 6) weights: gather unbiased probs by selected ids; ids as exact floats
)"
R"(    if (t < K) {
)"
R"(        const int e = topk[t];
)"
R"(        out[row*K + t] = p_raw[e];                    // plane 0: weights
)"
R"(        out[K*nt + row*K + t] = (float) e;            // plane 1: ids
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // 7) normalize: sum (sequential, k order = sum_rows), clamp, div, scale
)"
R"(    if (t == 0) {
)"
R"(        float s = 0.0f;
)"
R"(        for (int j = 0; j < K; ++j) s += out[row*K + j];
)"
R"(        s = s > 6.103515625e-5f ? s : 6.103515625e-5f;
)"
R"(        for (int j = 0; j < K; ++j) out[row*K + j] /= s;
)"
R"(        if (w_scale != 0.0f && w_scale != 1.0f) {
)"
R"(            for (int j = 0; j < K; ++j) out[row*K + j] *= w_scale;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
