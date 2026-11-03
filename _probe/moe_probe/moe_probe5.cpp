// moe_probe5: [dspark 2026-10-14] q3_K batched MoE gate (#28, v0.3.2).
// moe_probe4 harness adapted to GGML_TYPE_Q3_K: real MiniCPM-V 4.7 35B-A3B
// expert shapes (gate/up [K=2048, M=512, E=256], down [K=512, M=2048, E=256],
// top-8) + bisection shapes. Compares the OpenCL batched kernel
// (kernel_mul_mat_id_q3_k_f32_batched, host-precomputed se0/se1 planes)
// against exact CPU dequant reference — gate: NMSE <= 1e-6-ish (fp16 seff
// rounding), same acceptance as the q4_K dodge.
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

static uint32_t rng_state = 9973;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}
static const char * g_filter = nullptr;
static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }

// [dspark 2026-10-14] Packing self-check: replicate the set_tensor Q3_K pack
// formula (aux32 shuffle -> dl planes, code2/hmask re-pack) element-wise and
// compare against the verbatim dequantize_row_q3_K. Isolates host-packing bugs
// from kernel bugs without touching the device.
static void packing_selfcheck_q3k(const std::vector<uint8_t> & qdata,
                                  int K, int N, int E, const char * label) {
    const size_t q3_blk_bytes = 110;
    const int n_blk = K / 32, n_sb = K / 256;
    const uint32_t kmask1 = 0x03030303, kmask2 = 0x0f0f0f0f;
    std::vector<float> ref(K * N);
    dequantize_row_q3_K((const block_q3_K *)qdata.data(), ref.data(), (size_t)K * N);
    double worst = 0; int we = -1, wr = -1, wk = -1; int nmis = 0;
    for (int e = 0; e < 1; ++e) {          // expert 0 is enough to validate the formula
        for (int r = 0; r < N; ++r) {
            const uint8_t * row = qdata.data() + ((size_t)e * N + r) * n_sb * q3_blk_bytes;
            for (int sb = 0; sb < n_sb; ++sb) {
                const uint8_t * blk = row + sb * q3_blk_bytes;
                const float d = ggml_fp16_to_fp32(*(const ggml_fp16_t *)(blk + 108));
                const uint8_t * hm = blk + 0;
                const uint8_t * qs = blk + 32;
                uint32_t aux[4];
                memcpy(aux, blk + 96, 12);
                uint32_t tmp = aux[2];
                aux[2] = ((aux[0] >> 4) & kmask2) | (((tmp >> 4) & kmask1) << 4);
                aux[3] = ((aux[1] >> 4) & kmask2) | (((tmp >> 6) & kmask1) << 4);
                aux[0] = (aux[0] & kmask2) | (((tmp >> 0) & kmask1) << 4);
                aux[1] = (aux[1] & kmask2) | (((tmp >> 2) & kmask1) << 4);
                const int8_t * scales = (const int8_t *)aux;
                for (int pos = 0; pos < 8; ++pos) {
                    const int k = sb * 8 + pos;
                    const float dl0 = d * (scales[pos * 2]     - 32);
                    const float dl1 = d * (scales[pos * 2 + 1] - 32);
                    for (int l = 0; l < 32; ++l) {
                        const int e_in_sb = pos * 32 + l;
                        const int chunk = e_in_sb >> 7;
                        const int half  = (e_in_sb >> 4) & 1;
                        const int shift = 2 * ((e_in_sb >> 5) & 3);
                        const uint8_t qs_byte = qs[chunk * 32 + half * 16 + (e_in_sb & 15)];
                        const uint32_t code2 = (qs_byte >> shift) & 3u;
                        const uint32_t hbit  = (hm[e_in_sb & 31] >> (e_in_sb >> 5)) & 1u;
                        const float w = ((int)(code2 + 4 * hbit) - 4) * (l < 16 ? dl0 : dl1);
                        const float wref = ref[(size_t)r * K + k * 32 + l];
                        double dd = fabs((double)w - wref);
                        if (dd > worst) { worst = dd; we = e; wr = r; wk = k * 32 + l; }
                        if (dd > 1e-3 && nmis < 3) {
                            ++nmis;
                            printf("  MIS r=%d e_sb=%d (sb=%d pos=%d l=%d chunk=%d half=%d shift=%d)\n"
                                   "    qs_byte=0x%02x code2=%u hbit=%u d=%.6f dl=%.6f w=%.4f wref=%.4f\n"
                                   "    blk0: d=%.6f hm[0]=0x%02x qs[0]=0x%02x scales=%d,%d  qbytes:",
                                   r, e_in_sb, sb, pos, l, chunk, half, shift,
                                   qs_byte, code2, hbit, d, (l < 16 ? dl0 : dl1), w, wref,
                                   ggml_fp16_to_fp32(*(const ggml_fp16_t *)(blk + 0)),
                                   hm[0], qs[0], (int)scales[0], (int)scales[1]);
                            for (int b = 0; b < 16; ++b) printf(" %02x", row[b]);
                            printf("\n");
                        }
                    }
                }
            }
        }
    }
    printf("packing self-check (%s): expert0 max|w_sim - w_dequant| = %.6f at [r=%d k=%d]%s\n",
           label, worst, wr, wk, worst > 1e-3 ? "  <-- PACKING BUG" : "  OK");
    fflush(stdout);
}

static double nmse(const std::vector<float> & a, const std::vector<float> & b) {
    double num = 0, den = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        double d = (double)a[i] - b[i];
        num += d * d;
        den += (double)b[i] * b[i];
    }
    return num / (den > 1e-12 ? den : 1);
}

static std::vector<float> run_moe(ggml_backend_dev_t dev, ggml_type qt,
                                  int K, int N, int E, int n_used, int n_tok,
                                  const std::vector<uint8_t> & qdata,
                                  const std::vector<float> & x,
                                  const std::vector<int32_t> & ids,
                                  const char * name, bool broadcast) {
    ggml_init_params ip = { 2048ULL * 1024 * 1024, nullptr, true };
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
    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");
    std::vector<float> o((size_t)N * n_used * n_tok);
    ggml_backend_tensor_get(moe, o.data(), 0, o.size() * sizeof(float));
    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return o;
}

static double bench_moe(ggml_backend_dev_t dev, ggml_type qt,
                        int K, int N, int E, int n_used, int n_tok,
                        const std::vector<uint8_t> & qdata,
                        const std::vector<float> & x,
                        const std::vector<int32_t> & ids,
                        const char * name, bool broadcast, int iters) {
    ggml_init_params ip = { 2048ULL * 1024 * 1024, nullptr, true };
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

static void run_shape_f(ggml_backend_dev_t ocl, ggml_backend_dev_t cpu, ggml_type qt,
                      int K, int N, int E, int n_used, const char * label, bool broadcast,
                      int n_tok) {
    if (g_filter && !strstr(label, g_filter)) return;    printf("\n===== %s: K=%d N=%d E=%d n_used=%d n_tok=%d (broadcast=%d) =====\n",
           label, K, N, E, n_used, n_tok, (int)broadcast);
    const size_t blk = ggml_blck_size(qt);

    std::vector<float> w((size_t)K * N * E);
    for (auto & v : w) v = frand();
    std::vector<float> x(K);
    for (auto & v : x) v = frand();
    std::vector<uint8_t> qdata((size_t)N * E * K * ggml_type_size(qt) / blk);
    ggml_quantize_chunk(qt, w.data(), qdata.data(), 0, N * E, K, NULL);
    if (qt == GGML_TYPE_Q3_K) packing_selfcheck_q3k(qdata, K, N, E, label);
    if (getenv("MOE_PROBE_SAME")) {
        const size_t slice = (size_t)N * K * ggml_type_size(qt) / blk;
        for (int e = 1; e < E; ++e)
            memcpy(qdata.data() + (size_t)e * slice, qdata.data(), slice);
    }

    std::vector<int32_t> ids((size_t)n_used * n_tok);
    const bool uni_ids = getenv("MOE_PROBE_UNI") != nullptr;
    for (int t = 0; t < n_tok; ++t)
        for (int j = 0; j < n_used; ++j)
            ids[(size_t)t * n_used + j] = uni_ids ? 3 : (j + t * 3) * 7 % E;
    // exact dequant reference for the selected experts
    std::vector<float> wdq((size_t)K * N * n_used * n_tok);
    {
        const size_t slice_b = (size_t)N * K * ggml_type_size(qt) / blk;
        std::vector<float> tmp((size_t)K * N);
        int n_ref = 0;
        for (int t = 0; t < n_tok; ++t) {
            for (int j = 0; j < n_used; ++j) {
                const int e = ids[(size_t)t * n_used + j];
                if (qt == GGML_TYPE_Q3_K) {
                    dequantize_row_q3_K((const block_q3_K *)(qdata.data() + (size_t)e * slice_b),
                                        tmp.data(), (size_t)K * N);
                } else if (qt == GGML_TYPE_Q4_0) {
                    dequantize_row_q4_0((const block_q4_0 *)(qdata.data() + (size_t)e * slice_b),
                                        tmp.data(), (size_t)K * N);
                } else if (qt == GGML_TYPE_Q4_K) {
                    dequantize_row_q4_K((const block_q4_K *)(qdata.data() + (size_t)e * slice_b),
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
            const float * we = wdq.data() + (size_t)slot * K * N;
            for (int n = 0; n < N; ++n) {
                double s = 0;
                for (int k = 0; k < K; ++k) s += (double)we[(size_t)n * K + k] * x[k];
                ref[slot][n] = (float)s;
            }
        }
    }

    std::vector<float> out = run_moe(ocl, qt, K, N, E, n_used, n_tok, qdata, x, ids,
                                     "blk.0.ffn_gate_exps.weight", broadcast);
    std::vector<float> cout_ = run_moe(cpu, qt, K, N, E, n_used, n_tok, qdata, x, ids,
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
    if (getenv("MOE_PROBE_DUMP")) {
        for (int s = 0; s < 2 && s < n_used * n_tok; ++s) {
            printf("slot %d ref[0..5]:", s);
            for (int i = 0; i < 6; ++i) printf(" %9.3f", ref[s][i]);
            printf("\nslot %d got[0..5]:", s);
            for (int i = 0; i < 6; ++i) printf(" %9.3f", out[(size_t)s * N + i]);
            printf("\n");
        }
    }

    const int iters = 30;
    double us_gpu = bench_moe(ocl, qt, K, N, E, n_used, n_tok, qdata, x, ids,
                              "blk.0.ffn_gate_exps.weight", broadcast, iters);
    double us_cpu = bench_moe(cpu, qt, K, N, E, n_used, n_tok, qdata, x, ids,
                              "blk.0.ffn_gate_exps.weight", broadcast, iters);
    printf("bench: GPU %.1f us/op   CPU %.1f us/op   ratio GPU/CPU = %.2f\n",
           us_gpu, us_cpu, us_gpu / us_cpu);
    fflush(stdout);
}

// label-filtering wrapper (default args live here only)
static void run_shape(ggml_backend_dev_t ocl, ggml_backend_dev_t cpu, ggml_type qt,
                      int K, int N, int E, int n_used, const char * label,
                      bool broadcast = true, int n_tok = 1) {
    run_shape_f(ocl, cpu, qt, K, N, E, n_used, label, broadcast, n_tok);
}

int main(int argc, char ** argv) {
    // optional argv[1] = label substring filter (e.g. "Q40", "Q4K", "REAL")
    g_filter = (argc > 1) ? argv[1] : nullptr;
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

    // MiniCPM-V 4.7 35B-A3B real expert shapes (Q3_K, E=256 top-8)
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 2048, 512,  256, 8, "REAL-gateup", true);
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 512, 2048, 256, 8, "REAL-down", true);
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 2048, 512,  256, 8, "REAL-gateup-tok4", true, 4);
    // bisection ladder (same recipe as the q4_K probes)
    // E=1 shapes fall back to CPU by contract (set_tensor packs only ne[2]>1),
    // so the small-K GPU bisection uses E=2.
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 256, 128, 2,   1, "B1-K256-E2-u1", true);
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 256, 128, 128, 1, "B2-K256-E128-u1", true);
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 256, 128, 128, 8, "B3-K256-E128-u8", true);
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 512, 128, 128, 8, "B4-K512-E128-u8", true);
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 512, 128, 2,   8, "B5-K512-E2-u8", true);
    // bank-mode shapes: prefill view E = bank capacity (16), decode view E = window+prefetch
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 2048, 512, 16, 8, "BANK-E16-gateup", true);
run_shape(ocl, cpu, GGML_TYPE_Q3_K, 512, 2048, 16, 8, "BANK-E16-down", true);
    // [2026-10-14 晚] q4_0 batched kernel regression: the kernel source was changed
    // (P3 perm param) and recompiled AFTER its original NMSE=0 gate (2026-10-13);
    // E031 has proven recompile-drift UB, so it must be re-gated on 830.
    // tok>1 suites also exercise the P3 expert-bucket sort (never gated for q4_0).
run_shape(ocl, cpu, GGML_TYPE_Q4_0, 2048, 512, 128, 8, "Q40-gateup-tok4",  true, 4);
run_shape(ocl, cpu, GGML_TYPE_Q4_0, 512, 2048, 128, 8, "Q40-down-tok4",    true, 4);
run_shape(ocl, cpu, GGML_TYPE_Q4_0, 2048, 512, 256, 8, "Q40-mcp-gateup-tok4", true, 4);
    // n_tok=1 q4_0/q4_K never gated on 830 tonight — separates "kernel body
    // broken" (fails here too) from "multi-column path broken" (passes here).
run_shape(ocl, cpu, GGML_TYPE_Q4_0, 2048, 512, 128, 8, "Q40-gateup-tok1",  true);
run_shape(ocl, cpu, GGML_TYPE_Q4_0, 512, 2048, 128, 8, "Q40-down-tok1",    true);
run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2048, 512, 128, 8, "Q4K-gateup-tok1",  true);
    // q4_K batched also gained the perm param in the same edit as q4_0 — same
    // E031.47 recompile-drift suspect class. tok>1 exercises P3.
run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2048, 512, 128, 8, "Q4K-gateup-tok4", true, 4);
run_shape(ocl, cpu, GGML_TYPE_Q4_K, 512, 2048, 128, 8, "Q4K-down-tok4", true, 4);
    return 0;
}
