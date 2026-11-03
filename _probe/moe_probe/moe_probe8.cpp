// moe_probe8: [dspark 2026-10-15] dense MUL_MAT GEMV probe for full-GPU path.
// Question: can the dense side (attn/ssm projections + lm_head) run on Adreno
// OpenCL with validated numerics? This is the prerequisite for ngl>0 /
// all-GPU decode (the 185ms CPU dense wall on 830 / ~125ms on 740).
// Shapes mirror the MiniCPM-V 4.7 35B-A3B -les dense tensors (hidden=2048):
//   proj    : K=2048 N=2048   (attn o / ssm_out class)
//   qkv     : K=2048 N=6144
//   lmhead6 : K=2048 N=248144 Q6_K (output.weight as shipped, 398MiB)
//   lmhead4 : K=2048 N=248144 Q4_K (output.weight if requantized Q6->Q4)
//   prefill : K=2048 N=2048 m=512 (ubatch-size prefill GEMM sanity)
// Gate: GPU output vs CPU backend output NMSE <= 1e-6-ish (CPU fp32 GEMV is
// the ground truth; dequant-exact ref skipped for the 2GB lm_head shapes).
// Env: GGML_OPENCL_MOE_FORCE_A7X=1 on 740 (same gate as probe5/e2e).
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

static uint32_t rng_state = 104729;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}
static const char * g_filter = nullptr;
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

// Run one dense mul_mat [K,N] x [K,m] -> [N,m] on the given backend device.
static std::vector<float> run_dense(ggml_backend_dev_t dev, ggml_type qt,
                                    int K, int N, int m,
                                    const std::vector<uint8_t> & qdata,
                                    const std::vector<float> & x) {
    ggml_init_params ip = { 2048ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    ggml_tensor * wq = ggml_new_tensor_2d(ctx, qt, K, N);
    ggml_set_name(wq, "dense.weight");
    ggml_tensor * xs = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, m);
    ggml_tensor * y = ggml_mul_mat(ctx, wq, xs);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, y);
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    ggml_backend_tensor_set(wq, qdata.data(), 0, ggml_nbytes(wq));
    ggml_backend_tensor_set(xs, x.data(), 0, x.size() * sizeof(float));
    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");
    std::vector<float> o((size_t)N * m);
    ggml_backend_tensor_get(y, o.data(), 0, o.size() * sizeof(float));
    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return o;
}

static double bench_dense(ggml_backend_dev_t dev, ggml_type qt,
                          int K, int N, int m,
                          const std::vector<uint8_t> & qdata,
                          const std::vector<float> & x, int iters) {
    ggml_init_params ip = { 2048ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    ggml_tensor * wq = ggml_new_tensor_2d(ctx, qt, K, N);
    ggml_tensor * xs = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, m);
    ggml_tensor * y = ggml_mul_mat(ctx, wq, xs);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, y);
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    ggml_backend_tensor_set(wq, qdata.data(), 0, ggml_nbytes(wq));
    ggml_backend_tensor_set(xs, x.data(), 0, x.size() * sizeof(float));
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
                      int K, int N, int m, const char * label) {
    if (g_filter && !strstr(label, g_filter)) return;
    printf("\n===== %s: K=%d N=%d m=%d qt=%s =====\n", label, K, N, m, ggml_type_name(qt));
    fflush(stdout);
    const size_t blk = ggml_blck_size(qt);
    const size_t wbytes = (size_t)N * K * ggml_type_size(qt) / blk;

    std::vector<float> w((size_t)K * N);
    for (auto & v : w) v = frand();
    std::vector<float> x((size_t)K * m);
    for (auto & v : x) v = frand();
    std::vector<uint8_t> qdata(wbytes);
    ggml_quantize_chunk(qt, w.data(), qdata.data(), 0, N, K, NULL);
    w.clear(); w.shrink_to_fit();   // free fp32 weights before device runs

    // CPU backend = ground truth (fp32 accumulate GEMV over dequantized weights)
    std::vector<float> cref = run_dense(cpu, qt, K, N, m, qdata, x);
    std::vector<float> gout = run_dense(ocl, qt, K, N, m, qdata, x);
    double e = nmse(gout, cref);
    printf("NMSE(GPU vs CPU) = %.3e  %s\n", e, e <= 1e-5 ? "PASS" : "<-- FAIL");
    if (e > 1e-3) {
        printf("  cpu[0..5]:");
        for (int i = 0; i < 6; ++i) printf(" %9.3f", cref[i]);
        printf("\n  gpu[0..5]:");
        for (int i = 0; i < 6; ++i) printf(" %9.3f", gout[i]);
        printf("\n");
    }
    fflush(stdout);

    // bench: fewer iters for the big lm_head shapes
    const double mb = wbytes / 1048576.0;
    const int iters = mb > 300 ? 10 : 30;
    double us_gpu = bench_dense(ocl, qt, K, N, m, qdata, x, iters);
    double us_cpu = bench_dense(cpu, qt, K, N, m, qdata, x, iters);
    const double gbs_gpu = (double)wbytes / (us_gpu * 1e-6) / 1e9;
    const double gbs_cpu = (double)wbytes / (us_cpu * 1e-6) / 1e9;
    printf("bench: GPU %.1f us (%.1f GB/s)   CPU %.1f us (%.1f GB/s)   ratio %.2f\n",
           us_gpu, gbs_gpu, us_cpu, gbs_cpu, us_gpu / us_cpu);
    fflush(stdout);
}

int main(int argc, char ** argv) {
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

    // decode GEMV (m=1) — the per-token dense wall
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2048, 2048,    1, "proj-q4K-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q6_K, 2048, 2048,    1, "proj-q6K-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2048, 6144,    1, "qkv-q4K-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q6_K, 2048, 248144,  1, "lmhead6-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2048, 248144,  1, "lmhead4-tok1");
    // [dspark 2026-10-17] e2e suspect: attn-layer o_proj is K=2304 (9 superblocks)
    // while the healthy qkv GEMV is K=2048 (8). Reproduce the exact decode shape.
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2304, 2048,    1, "oproj-q4K-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q6_K, 2304, 2048,    1, "oproj-q6K-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2560, 2048,    1, "fdown-q4K-tok1");
    // prefill GEMM sanity (ubatch-scale m)
    run_shape(ocl, cpu, GGML_TYPE_Q4_K, 2048, 2048,  512, "proj-q4K-m512");
    // small-model format comparison: why 2B/4B full-GPU wins (q4_0/q8_0 kernels)
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 2048, 2048,    1, "proj-q40-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q8_0, 2048, 2048,    1, "proj-q80-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 2048, 6144,    1, "qkv-q40-tok1");
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 2048, 248144,  1, "lmhead40-tok1");
    return 0;
}
