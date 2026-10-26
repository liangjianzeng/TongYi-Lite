// moe_probe4: vendor MoE kernels with REAL Ling-3.0-tiny shapes.
// Real dims: E=128 experts top-8, gate/up [K=1536, M=512, E], down [K=512, M=1536, E].
// Decode usage: src1 ne11=1 (broadcast), ids = 8 experts, name must contain "ffn"+"exps"
// so use_adreno_moe_kernels() matches (as in the app). Compare vs exact CPU dequant ref.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <chrono>
#include <vector>

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-quants.h"

static uint32_t rng_state = 4242;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}
static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }

static double nmse(const std::vector<float> & a, const std::vector<float> & b) {
    double num = 0, den = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        double d = (double)a[i] - b[i];
        num += d * d;
        den += (double)b[i] * b[i];
    }
    return num / (den > 1e-12 ? den : 1);
}

// vendor-path MUL_MAT_ID: 3D qt weights [K,N,E], src1 [K, ne11, n_tok], ids [n_used, n_tok]
// name must contain "ffn"+"exps" to trigger the vendor Adreno MoE path (as in app).
static std::vector<float> vendor_moe(ggml_backend_dev_t dev, ggml_type qt,
                                     int K, int N, int E, int n_used, int n_tok,
                                     const std::vector<uint8_t> & qdata,
                                     const std::vector<float> & x,
                                     const std::vector<int32_t> & ids,
                                     const char * name, bool broadcast) {
    ggml_init_params ip = { 1024ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    ggml_tensor * wq = ggml_new_tensor_3d(ctx, qt, K, N, E);
    ggml_set_name(wq, name);
    ggml_tensor * xs = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, K, broadcast ? 1 : n_used, n_tok);
    ggml_tensor * idt = ggml_new_tensor_2d(ctx, GGML_TYPE_I32, n_used, n_tok);
    ggml_tensor * moe = ggml_mul_mat_id(ctx, wq, xs, idt);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, moe);
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    ggml_backend_tensor_set(wq, qdata.data(), 0, ggml_nbytes(wq));
    // [R-029 2026-10-26] get_tensor round-trip for MoE weights (exercises the
    // dense-loop noshuffle restore arms = audit G3; batched-plane/other families
    // have no byte-exact get contract, so non-ok on those is informational).
    if (getenv("MOE_PROBE_READBACK") && strstr(ggml_backend_dev_name(dev), "OpenCL")) {
        std::vector<uint8_t> rb(ggml_nbytes(wq));
        ggml_backend_tensor_get(wq, rb.data(), 0, rb.size());
        size_t bad = 0;
        for (size_t i = 0; i < rb.size(); ++i) bad += (rb[i] != qdata[i]);
        printf("[READBACK-MOE] %s K=%d N=%d E=%d nbytes=%zu mismatch=%zu (%s)\n",
               name, K, N, E, rb.size(), bad, bad ? "FAIL" : "ok");
    }
    if (broadcast) {
        // one activation vector replicated over n_tok token positions
        std::vector<float> x2((size_t)K * n_tok);
        for (int t = 0; t < n_tok; ++t) memcpy(x2.data() + (size_t)t * K, x.data(), K * sizeof(float));
        ggml_backend_tensor_set(xs, x2.data(), 0, x2.size() * sizeof(float));
    } else {
        std::vector<float> x2((size_t)K * n_used * n_tok);
        for (int t = 0; t < n_tok; ++t)
            for (int j = 0; j < n_used; ++j)
                memcpy(x2.data() + ((size_t)t * n_used + j) * K, x.data(), K * sizeof(float));
        ggml_backend_tensor_set(xs, x2.data(), 0, x2.size() * sizeof(float));
    }
    ggml_backend_tensor_set(idt, ids.data(), 0, ids.size() * sizeof(int32_t));
    fprintf(stderr, "[m1p] before compute\n"); fflush(stderr);
    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");
    fprintf(stderr, "[m1p] compute done\n"); fflush(stderr);
    std::vector<float> o((size_t)N * n_used * n_tok);
    ggml_backend_tensor_get(moe, o.data(), 0, o.size() * sizeof(float));
    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return o;
}

// steady-state per-op latency (µs): build once, warm up, loop graph_compute
// (each call syncs — fair end-to-end op cost incl. dispatch/sync overhead)
static double bench_moe(ggml_backend_dev_t dev, ggml_type qt,
                        int K, int N, int E, int n_used, int n_tok,
                        const std::vector<uint8_t> & qdata,
                        const std::vector<float> & x,
                        const std::vector<int32_t> & ids,
                        const char * name, bool broadcast, int iters) {
    ggml_init_params ip = { 1024ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    ggml_tensor * wq = ggml_new_tensor_3d(ctx, qt, K, N, E);
    ggml_set_name(wq, name);
    ggml_tensor * xs = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, K, broadcast ? 1 : n_used, n_tok);
    ggml_tensor * idt = ggml_new_tensor_2d(ctx, GGML_TYPE_I32, n_used, n_tok);
    ggml_tensor * moe = ggml_mul_mat_id(ctx, wq, xs, idt);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, moe);
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    ggml_backend_tensor_set(wq, qdata.data(), 0, ggml_nbytes(wq));
    if (broadcast) {
        std::vector<float> x2((size_t)K * n_tok);
        for (int t = 0; t < n_tok; ++t) memcpy(x2.data() + (size_t)t * K, x.data(), K * sizeof(float));
        ggml_backend_tensor_set(xs, x2.data(), 0, x2.size() * sizeof(float));
    } else {
        std::vector<float> x2((size_t)K * n_used * n_tok);
        for (int t = 0; t < n_tok; ++t)
            for (int j = 0; j < n_used; ++j)
                memcpy(x2.data() + ((size_t)t * n_used + j) * K, x.data(), K * sizeof(float));
        ggml_backend_tensor_set(xs, x2.data(), 0, x2.size() * sizeof(float));
    }
    ggml_backend_tensor_set(idt, ids.data(), 0, ids.size() * sizeof(int32_t));
    for (int i = 0; i < 3; ++i) {
        if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("warmup");
    }
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < iters; ++i) {
        if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("bench");
    }
    auto t1 = std::chrono::steady_clock::now();
    double us = std::chrono::duration<double, std::micro>(t1 - t0).count() / iters;
    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return us;
}

static void run_shape(ggml_backend_dev_t ocl, ggml_backend_dev_t cpu, ggml_type qt,
                      int K, int N, int E, int n_used, const char * label, bool broadcast = true,
                      int n_tok = 1) {
    printf("\n===== %s: K=%d N=%d E=%d n_used=%d n_tok=%d (broadcast=%d) =====\n",
           label, K, N, E, n_used, n_tok, (int)broadcast);
    const size_t blk = ggml_blck_size(qt);

    std::vector<float> w((size_t)K * N * E);
    for (auto & v : w) v = frand();
    std::vector<float> x(K);
    for (auto & v : x) v = frand();
    std::vector<uint8_t> qdata((size_t)N * E * K * ggml_type_size(qt) / blk);
    fprintf(stderr, "[m1p] before quantize type=%d\n", (int)qt); fflush(stderr);
    ggml_quantize_chunk(qt, w.data(), qdata.data(), 0, N * E, K, NULL);
    fprintf(stderr, "[m1p] quantize done\n"); fflush(stderr);
    // MOE_PROBE_SAME=1: replicate expert-0 bytes to all E experts — any per-expert
    // base-offset error then disappears (every es reads identical data).
    if (getenv("MOE_PROBE_SAME")) {
        const size_t slice = (size_t)N * K * ggml_type_size(qt) / blk;
        for (int e = 1; e < E; ++e)
            memcpy(qdata.data() + (size_t)e * slice, qdata.data(), slice);
    }

    std::vector<int32_t> ids((size_t)n_used * n_tok);
    const bool uni_ids = getenv("MOE_PROBE_UNI") != nullptr;   // all slots -> same expert (leakage check)
    for (int t = 0; t < n_tok; ++t)
        for (int j = 0; j < n_used; ++j)
            ids[(size_t)t * n_used + j] = uni_ids ? 3 : (j + t * 3) * 7 % E; // spread, differ per token
    // exact dequant reference for the selected experts (by id)
    std::vector<float> wdq((size_t)K * N * n_used * n_tok);
    {
        const size_t slice_b = (size_t)N * K * ggml_type_size(qt) / blk;
        std::vector<float> tmp((size_t)K * N);
        int n_ref = 0;
        for (int t = 0; t < n_tok; ++t) {
            for (int j = 0; j < n_used; ++j) {
                const int e = ids[(size_t)t * n_used + j];
                if (qt == GGML_TYPE_Q4_0) {
                    dequantize_row_q4_0((const block_q4_0 *)(qdata.data() + (size_t)e * slice_b),
                                        tmp.data(), (size_t)K * N);
                } else if (qt == GGML_TYPE_Q4_K) {
                    dequantize_row_q4_K((const block_q4_K *)(qdata.data() + (size_t)e * slice_b),
                                        tmp.data(), (size_t)K * N);
                } else if (qt == GGML_TYPE_IQ4_XS) {
                    // [tongyi M1] CPU 参考：dequantize_row_iq4_xs（ggml-quants.c 同源语义）
                    dequantize_row_iq4_xs((const block_iq4_xs *)(qdata.data() + (size_t)e * slice_b),
                                          tmp.data(), (size_t)K * N);
                } else {
                    die("unsupported type");
                }
                memcpy(wdq.data() + (size_t)n_ref * K * N, tmp.data(), (size_t)K * N * sizeof(float));
                ++n_ref;
            }
        }
    }
    std::vector<std::vector<float>> ref((size_t)n_used * n_tok, std::vector<float>(N));
    for (int t = 0; t < n_tok; ++t) {
        for (int j = 0; j < n_used; ++j) {
            const int slot = t * n_used + j;
            const float * we = wdq.data() + (size_t)slot * K * N; // slot ref = expert ids[slot]
            for (int n = 0; n < N; ++n) {
                double s = 0;
                for (int k = 0; k < K; ++k) s += (double)we[(size_t)n * K + k] * x[k];
                ref[slot][n] = (float)s;
            }
        }
    }

    std::vector<float> out = vendor_moe(ocl, qt, K, N, E, n_used, n_tok, qdata, x, ids,
                                        "blk.0.ffn_gate_exps.weight", broadcast);
    // sanity: CPU backend same op
    std::vector<float> cout_ = vendor_moe(cpu, qt, K, N, E, n_used, n_tok, qdata, x, ids,
                                          "blk.0.ffn_gate_exps.weight", broadcast);
    double worst_gpu = 0, worst_cpu = 0;
    for (int t = 0; t < n_tok; ++t) {
        for (int j = 0; j < n_used; ++j) {
            const int slot = t * n_used + j;
            std::vector<float> got(out.begin() + (size_t)slot * N, out.begin() + ((size_t)slot + 1) * N);
            std::vector<float> cref(cout_.begin() + (size_t)slot * N, cout_.begin() + ((size_t)slot + 1) * N);
            worst_gpu = worst_gpu > nmse(got, ref[slot]) ? worst_gpu : nmse(got, ref[slot]);
            worst_cpu = worst_cpu > nmse(cref, ref[slot]) ? worst_cpu : nmse(cref, ref[slot]);
        }
    }
    printf("worst over %d slots: GPU NMSE=%.6f  CPU NMSE=%.6f\n",
           n_used * n_tok, worst_gpu, worst_cpu);
    if (getenv("MOE_PROBE_KREF")) {
        // [dspark 2026-10-14] CPU per-k-block contributions for slot 0, rows 0/1
        // (from the DEQUANTIZED quantized weights = exactly what the GPU kernel
        // should multiply). Compare with host-side KDBG dump (cols are slot-ordered).
        for (int n = 0; n < 2; ++n) {
            for (int kb = 0; kb < K/32; ++kb) {
                double acc = 0;
                for (int i = 0; i < 32; ++i)
                    acc += (double)wdq[(size_t)0 * K * N + (size_t)n * K + kb * 32 + i] * x[kb * 32 + i];
                fprintf(stderr, "KREF row=%d k=%2d contrib=%12.4f\n", n, kb, (float)acc);
            }
        }
        if (qt == GGML_TYPE_Q4_K) {
            // expected s/m per (row, k) decoded straight from the raw q4_K blocks
            // (same math as the kernel: fp16 product of d*sc / dmin*mn).
            const size_t slice = (size_t)N * K * ggml_type_size(qt) / ggml_blck_size(qt);
            const uint8_t * base = qdata.data();   // expert ids[0] = 0 for slot 0
            for (int n = 0; n < 2; ++n) {
                const uint8_t * row = base + (size_t)n * (K/256) * 144;
                for (int sb = 0; sb < K/256; ++sb) {
                    const uint8_t * blk = row + (size_t)sb * 144;
                    float d    = ggml_fp16_to_fp32(*(const ggml_fp16_t *)(blk + 0));
                    float dmin = ggml_fp16_to_fp32(*(const ggml_fp16_t *)(blk + 2));
                    const uint8_t * sc = blk + 4;
                    if (n < 2 && sb < 8) {
                        fprintf(stderr, "RAW row=%d sb=%d d=%04x dmin=%04x scales=",
                                n, sb, *(const uint16_t *)(blk + 0), *(const uint16_t *)(blk + 2));
                        for (int cc = 0; cc < 12; ++cc) fprintf(stderr, " %02x", sc[cc]);
                        fprintf(stderr, "\n");
                    }
                    for (int jk = 0; jk < 8; ++jk) {
                        uint8_t sv, mn;
                        if (jk < 4) { sv = sc[jk] & 63; mn = sc[jk+4] & 63; }
                        else {
                            sv = (sc[jk+4] & 0xF) | ((sc[jk-4] & 0xC0) >> 2);
                            mn = (sc[jk+4] >> 4) | ((sc[jk-4] & 0xC0) >> 2);
                        }
                        fprintf(stderr, "KSCAL row=%d k=%2d s_exp=%9.5f m_exp=%9.5f (d=%9.5f dmin=%9.5f sv=%02x mn=%02x)\n",
                                n, sb*8+jk, d*sv, dmin*mn, d, dmin, sv, mn);
                    }
                }
            }
        }
        fflush(stderr);
    }
    if (getenv("MOE_PROBE_DUMP")) {
        for (int s = 0; s < 2 && s < n_used * n_tok; ++s) {
            printf("slot %d ref[0..5]:", s);
            for (int i = 0; i < 6; ++i) printf(" %9.3f", ref[s][i]);
            printf("\nslot %d got[0..5]:", s);
            for (int i = 0; i < 6; ++i) printf(" %9.3f", out[(size_t)s * N + i]);
            // find best-matching slot (permutation check)
            int best = -1; double bestn = 1e30;
            for (int s2 = 0; s2 < n_used * n_tok; ++s2) {
                std::vector<float> g2(out.begin() + (size_t)s2 * N, out.begin() + ((size_t)s2 + 1) * N);
                double n2 = nmse(g2, ref[s]);
                if (n2 < bestn) { bestn = n2; best = s2; }
            }
            printf("\nslot %d best-matching got-slot = %d (NMSE=%.6f)\n", s, best, bestn);
        }
    }

    // steady-state timing: GPU (current default MoE path) vs CPU
    const int iters = 30;
    double us_gpu = bench_moe(ocl, qt, K, N, E, n_used, n_tok, qdata, x, ids,
                              "blk.0.ffn_gate_exps.weight", broadcast, iters);
    double us_cpu = bench_moe(cpu, qt, K, N, E, n_used, n_tok, qdata, x, ids,
                              "blk.0.ffn_gate_exps.weight", broadcast, iters);
    printf("bench: GPU %.1f us/op   CPU %.1f us/op   ratio GPU/CPU = %.2f\n",
           us_gpu, us_cpu, us_gpu / us_cpu);
}

// ---------------------------------------------------------------------------
// [S5 bisection 2026-10-26] DENSE MUL_MAT coverage (non-MUL_MAT_ID).
// The OFF-build e2e degeneration (48x token 0 / 'endah') shipped while every
// batched-MoE shape was NMSE-clean — the untested surface is the dense
// ggml_mul_mat path (attn q/gate, shared experts, output head all go through
// it; the model is q3_K_L-heavy). This section probes exactly that op.
// ---------------------------------------------------------------------------
static std::vector<float> vendor_dense(ggml_backend_dev_t dev, ggml_type qt, int K, int N, int n_tok,
                                       const std::vector<uint8_t> & qdata, const std::vector<float> & x) {
    ggml_init_params ip = { 1024ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("dense ggml_init");
    ggml_tensor * wq = ggml_new_tensor_2d(ctx, qt, K, N);
    ggml_set_name(wq, "dense.weight");
    ggml_tensor * xs = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, n_tok);
    ggml_tensor * res = ggml_mul_mat(ctx, wq, xs);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, res);
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("dense alloc");
    ggml_backend_tensor_set(wq, qdata.data(), 0, ggml_nbytes(wq));
    // [R-029 2026-10-26] readback round-trip: exercises buffer get_tensor (the
    // reverse direction of the set_tensor transposes). A guarded restore arm in
    // an ADRENO=OFF build restores plane bytes from transposed extras -> the
    // memcmp below fails loudly (reverse-direction P2, audit G1/G2/G3).
    if (getenv("MOE_PROBE_READBACK") && strstr(ggml_backend_dev_name(dev), "OpenCL")) {
        std::vector<uint8_t> rb(ggml_nbytes(wq));
        ggml_backend_tensor_get(wq, rb.data(), 0, rb.size());
        size_t bad = 0;
        for (size_t i = 0; i < rb.size(); ++i) bad += (rb[i] != qdata[i]);
        printf("[READBACK] %s K=%d N=%d nbytes=%zu mismatch=%zu (%s)\n",
               ggml_type_name(qt), K, N, rb.size(), bad, bad ? "FAIL" : "ok");
    }
    std::vector<float> x2((size_t)K * n_tok);
    for (int t = 0; t < n_tok; ++t) memcpy(x2.data() + (size_t)t * K, x.data(), K * sizeof(float));
    ggml_backend_tensor_set(xs, x2.data(), 0, x2.size() * sizeof(float));
    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("dense compute");
    std::vector<float> o((size_t)N * n_tok);
    ggml_backend_tensor_get(res, o.data(), 0, o.size() * sizeof(float));
    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return o;
}

static void run_dense(ggml_backend_dev_t ocl, ggml_backend_dev_t cpu, ggml_type qt,
                      int K, int N, int n_tok, const char * label) {
    printf("\n===== DENSE %s: type=%s K=%d N=%d n_tok=%d =====\n",
           label, ggml_type_name(qt), K, N, n_tok);
    const size_t blk = ggml_blck_size(qt);
    std::vector<float> w((size_t)K * N);
    for (auto & v : w) v = frand();
    std::vector<float> x(K);
    for (auto & v : x) v = frand();
    std::vector<uint8_t> qdata((size_t)N * K * ggml_type_size(qt) / blk);
    ggml_quantize_chunk(qt, w.data(), qdata.data(), 0, N, K, NULL);
    std::vector<float> wdq((size_t)K * N);
    if (qt == GGML_TYPE_Q4_0) {
        dequantize_row_q4_0((const block_q4_0 *)qdata.data(), wdq.data(), (int64_t)K * N);
    } else if (qt == GGML_TYPE_Q4_K) {
        dequantize_row_q4_K((const block_q4_K *)qdata.data(), wdq.data(), (int64_t)K * N);
    } else if (qt == GGML_TYPE_Q3_K) {
        dequantize_row_q3_K((const block_q3_K *)qdata.data(), wdq.data(), (int64_t)K * N);
    } else {
        die("dense: unsupported type");
    }
    std::vector<std::vector<float>> ref((size_t)n_tok, std::vector<float>(N));
    for (int t = 0; t < n_tok; ++t)
        for (int n = 0; n < N; ++n) {
            double s = 0;
            for (int k = 0; k < K; ++k) s += (double)wdq[(size_t)n * K + k] * x[k];
            ref[t][n] = (float)s;
        }
    // supports_op verdict first: a "no" means the real scheduler keeps the node
    // on CPU (safe); a "yes" must be numerically correct or it is the culprit.
    {
        ggml_init_params ip = { 1024ULL * 1024 * 1024, nullptr, true };
        ggml_context * ctx = ggml_init(ip);
        ggml_tensor * wq = ggml_new_tensor_2d(ctx, qt, K, N);
        ggml_tensor * xs = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, n_tok);
        ggml_tensor * res = ggml_mul_mat(ctx, wq, xs);
        bool sup = ggml_backend_dev_supports_op(ocl, res);
        printf("supports_op(OpenCL) = %s\n", sup ? "YES" : "no (CPU fallback in real sched)");
        ggml_free(ctx);
        if (!sup) return;
    }
    std::vector<float> out = vendor_dense(ocl, qt, K, N, n_tok, qdata, x);
    std::vector<float> cout_ = vendor_dense(cpu, qt, K, N, n_tok, qdata, x);
    double worst_gpu = 0, worst_cpu = 0;
    for (int t = 0; t < n_tok; ++t) {
        std::vector<float> got(out.begin() + (size_t)t * N, out.begin() + (size_t)(t + 1) * N);
        std::vector<float> cref(cout_.begin() + (size_t)t * N, cout_.begin() + (size_t)(t + 1) * N);
        double g = nmse(got, ref[t]);   if (g > worst_gpu) worst_gpu = g;
        double c = nmse(cref, ref[t]); if (c > worst_cpu) worst_cpu = c;
    }
    printf("DENSE worst over %d tok: GPU NMSE=%.6f  CPU NMSE=%.6f\n", n_tok, worst_gpu, worst_cpu);
}

int main() {
    ggml_backend_load_all();
    ggml_backend_dev_t ocl = nullptr, cpu = nullptr;
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        const char * name = ggml_backend_dev_name(d);
        printf("dev[%zu] = %s (%s)\n", i, name, ggml_backend_dev_description(d));
        if (strstr(name, "OpenCL") || strstr(name, "GPUOpenCL")) ocl = d;
        if (strcmp(name, "CPU") == 0) cpu = d;
    }
    if (!ocl || !cpu) die("backend missing");

    // [dspark 2026-10-14] MOE_PROBE_ONLY=Q4K|Q40 skips the other family: cache
    // isolation — the P4 activation cache is keyed (buffer,origin,size) and the
    // q_img lives on the tensor extra; running q4_K with zero prior q4_0 calls
    // rules out cross-test image-cache pollution.
    const char * only = getenv("MOE_PROBE_ONLY");
    const bool only_q40 = only && strcmp(only, "Q40") == 0;
    const bool only_q4k = only && strcmp(only, "Q4K") == 0;
    const bool only_dense = only && strcmp(only, "DENSE") == 0;
    const bool skip_batched = only_dense;

    if (!skip_batched && !only_q4k) {
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 1536, 512, 128, 8, "REAL-gateup", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 512, 1536, 128, 8, "REAL-down", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 1536, 512, 128, 8, "PREFILL-gateup-tok4", true, 4);
    }
    if (!skip_batched) {
    // [tongyi M1 2026-10-25] iq4_xs 首个 sub-3bpw 内核验收（G-733 路线①）：
    // Ling 真形状（K=1536/512 M%128=0）+ 边界（K=256 单超块）。
    run_shape(ocl, cpu, GGML_TYPE_IQ4_XS, 1536, 512, 128, 8, "M1-IQ4XS-gateup", true);
    run_shape(ocl, cpu, GGML_TYPE_IQ4_XS, 512, 1536, 128, 8, "M1-IQ4XS-down", true);
    run_shape(ocl, cpu, GGML_TYPE_IQ4_XS, 256, 128, 128, 8, "M1-IQ4XS-K256", true);
    }
    if (!skip_batched && !only_q40) {
    // [dspark 2026-10-14] q4_K batched kernel bisection (phone garble)
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 1536, 512, 128, 8, "Q4K-gateup", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 512, 1536, 128, 8, "Q4K-down", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 1536, 512, 128, 8, "Q4K-PREFILL-tok4", true, 4);
    // [dspark 2026-10-14] shape bisection: isolate expert addressing (E/used) and
    // superblock scale offset (K). T1 degenerates to near-dense (E=1, used=1);
    // T2 isolates es/base on used=1; T3/T4 isolate K=256 (single superblock, sb=0
    // only) vs K=512 (sb=1 exists).
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 256, 128, 1,   1, "B1-K256-E1-u1", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 256, 128, 128, 1, "B2-K256-E128-u1", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 256, 128, 128, 8, "B3-K256-E128-u8", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 512, 128, 128, 8, "B4-K512-E128-u8", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 512, 128, 1,   8, "B5-K512-E1-u8", true);
    }

    // [S5 bisection 2026-10-26] dense MUL_MAT on the minicpm-35b-a3b real shapes
    // (hidden=2048; attn_q/qkv N=8192, attn_gate inner=4096, shared-expert
    // 512<->2048; output head q4_K sampled at N=8192). n_tok 1 = decode GEMV.
    if (!only_q40 && !only_q4k) {
        run_dense(ocl, cpu, GGML_TYPE_Q4_0, 2048, 8192, 1, "sanity-q4_0");
        run_dense(ocl, cpu, GGML_TYPE_Q3_K, 2048, 8192, 1, "attn-q-q3K");
        run_dense(ocl, cpu, GGML_TYPE_Q3_K, 2048, 4096, 1, "attn-gate-q3K");
        run_dense(ocl, cpu, GGML_TYPE_Q3_K, 2048,  512, 1, "shexp-gate-q3K");
        run_dense(ocl, cpu, GGML_TYPE_Q3_K,  512, 2048, 1, "shexp-down-q3K");
        run_dense(ocl, cpu, GGML_TYPE_Q3_K, 2048, 8192, 4, "attn-q-q3K-tok4");
        run_dense(ocl, cpu, GGML_TYPE_Q4_K, 2048,  512, 1, "attn-v-q4K");
        run_dense(ocl, cpu, GGML_TYPE_Q4_K, 2048, 8192, 1, "out-like-q4K");
        run_dense(ocl, cpu, GGML_TYPE_Q4_K, 2048, 8192, 4, "out-like-q4K-tok4");
    }
    return 0;
}
