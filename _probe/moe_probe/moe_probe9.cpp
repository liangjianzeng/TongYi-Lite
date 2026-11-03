// probe9: [dspark 2026-10-16] submission-tax anatomy for Adreno OpenCL decode.
// Motivation: bank30/31/32 on 830 showed every GPU path loses to CPU hybrid
// (3983 ops/token). Question: where does the per-op cost live?
//   Q1 tiny-op slope : graphs of K chained ggml_add [256] f32, K=1..500
//                      -> per-op (sched+enqueue) overhead, GPU vs CPU.
//   Q2 decode chain  : 40 chained q4_K GEMV [2048x2048] m=1 (dense wall of a
//                      whole layer stack) -> per-GEMV in-graph cost vs single.
//   Q3 lm_head class : 1 GEMV [2048x248144] m=1 sanity (probe8 cross-check).
// Fused-kernel ceiling = Q2_total - 40 * slope_Q1 (analysis, not simulated).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <vector>
#include <algorithm>
#include <dlfcn.h>

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-quants.h"

static uint32_t rng_state = 104729;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}
static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }

static double best_of(ggml_backend_t b, ggml_cgraph * gf, int warm, int iters) {
    for (int i = 0; i < warm; ++i) {
        if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("warmup");
    }
    double best = 1e30;
    for (int i = 0; i < iters; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("bench");
        auto t1 = std::chrono::steady_clock::now();
        double us = std::chrono::duration<double, std::micro>(t1 - t0).count();
        if (us < best) best = us;
    }
    return best;
}

// ---- Q1: tiny-op chain slope -------------------------------------------
static void run_tiny_slope(ggml_backend_dev_t dev, const char * nm) {
    printf("\n===== Q1 tiny-op slope [%s] =====\n", nm);
    fflush(stdout);
    struct { int k; } cases[] = { {1}, {50}, {200}, {500} };
    double slope_us = 0;
    for (auto & c : cases) {
        ggml_init_params ip = { 256ULL * 1024 * 1024, nullptr, true };
        ggml_context * ctx = ggml_init(ip);
        if (!ctx) die("ggml_init");
        ggml_tensor * a = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 256);
        ggml_tensor * b = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 256);
        ggml_tensor * y = a;
        for (int i = 0; i < c.k; ++i) y = ggml_add(ctx, y, b);
        ggml_cgraph * gf = ggml_new_graph(ctx);
        ggml_build_forward_expand(gf, y);
        ggml_backend_t be = ggml_backend_dev_init(dev, nullptr);
        ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
        if (!buf) die("alloc");
        std::vector<float> ones(256, 0.5f), zeros(256, 0.0f);
        ggml_backend_tensor_set(a, zeros.data(), 0, 256 * sizeof(float));
        ggml_backend_tensor_set(b, ones.data(), 0, 256 * sizeof(float));
        double us = best_of(be, gf, 10, 30);
        printf("  K=%4d: %9.1f us  (%.2f us/op)\n", c.k, us, us / c.k);
        if (c.k == 500) slope_us = us / c.k;
        ggml_backend_buffer_free(buf);
        ggml_backend_free(be);
        ggml_free(ctx);
        fflush(stdout);
    }
    printf("  -> per-op tax ~= %.2f us\n", slope_us);
    fflush(stdout);
}

// ---- Q2: decode-realistic GEMV chain -----------------------------------
static void run_gemv_chain(ggml_backend_dev_t dev, const char * nm,
                           int n_gemv, int K, int N) {
    printf("\n===== Q2 GEMV chain x%d [K=%d N=%d q4_K m=1] [%s] =====\n", n_gemv, K, N, nm);
    fflush(stdout);
    const size_t blk = ggml_blck_size(GGML_TYPE_Q4_K);
    const size_t wbytes = (size_t)N * K * ggml_type_size(GGML_TYPE_Q4_K) / blk;

    ggml_init_params ip = { 2048ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    std::vector<ggml_tensor *> ws;
    std::vector<uint8_t> qdata(wbytes);
    std::vector<float> w((size_t)K * N);
    for (int i = 0; i < n_gemv; ++i) {
        for (auto & v : w) v = frand();
        ggml_quantize_chunk(GGML_TYPE_Q4_K, w.data(), qdata.data(), 0, N, K, NULL);
        ggml_tensor * wt = ggml_new_tensor_2d(ctx, GGML_TYPE_Q4_K, K, N);
        ws.push_back(wt);
    }
    ggml_tensor * x = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, K);
    std::vector<float> xd(K);
    for (auto & v : xd) v = frand();
    ggml_tensor * y = ggml_mul_mat(ctx, ws[0], x);
    for (int i = 1; i < n_gemv; ++i) y = ggml_mul_mat(ctx, ws[i], y);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, y);
    ggml_backend_t be = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    for (int i = 0; i < n_gemv; ++i) {
        ggml_backend_tensor_set(ws[i], qdata.data(), 0, wbytes);
    }
    ggml_backend_tensor_set(x, xd.data(), 0, xd.size() * sizeof(float));
    double us = best_of(be, gf, 3, 20);
    printf("  chain total %9.1f us  per-GEMV %.1f us  (%.1f GB/s effective)\n",
           us, us / n_gemv, (double)wbytes * n_gemv / (us * 1e-6) / 1e9);
    ggml_backend_buffer_free(buf);
    ggml_backend_free(be);
    ggml_free(ctx);
    fflush(stdout);
}

// ---- Q3: lm_head sanity -------------------------------------------------
static void run_lmhead(ggml_backend_dev_t dev, const char * nm) {
    printf("\n===== Q3 lm_head [K=2048 N=248144 q4_K m=1] [%s] =====\n", nm);
    fflush(stdout);
    const int K = 2048, N = 248144;
    const size_t blk = ggml_blck_size(GGML_TYPE_Q4_K);
    const size_t wbytes = (size_t)N * K * ggml_type_size(GGML_TYPE_Q4_K) / blk;
    ggml_init_params ip = { 2048ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    ggml_tensor * wt = ggml_new_tensor_2d(ctx, GGML_TYPE_Q4_K, K, N);
    ggml_tensor * x = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, K);
    std::vector<float> xd(K);
    for (auto & v : xd) v = frand();
    ggml_tensor * y = ggml_mul_mat(ctx, wt, x);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, y);
    ggml_backend_t be = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    {
        std::vector<float> w((size_t)K * N);
        for (auto & v : w) v = frand();
        std::vector<uint8_t> qdata(wbytes);
        ggml_quantize_chunk(GGML_TYPE_Q4_K, w.data(), qdata.data(), 0, N, K, NULL);
        w.clear(); w.shrink_to_fit();
        ggml_backend_tensor_set(wt, qdata.data(), 0, wbytes);
    }
    ggml_backend_tensor_set(x, xd.data(), 0, xd.size() * sizeof(float));
    double us = best_of(be, gf, 3, 10);
    printf("  %9.1f us  (%.1f GB/s)\n", us, (double)wbytes / (us * 1e-6) / 1e9);
    ggml_backend_buffer_free(buf);
    ggml_backend_free(be);
    ggml_free(ctx);
    fflush(stdout);
}

int main(int argc, char ** argv) {
    const char * which = (argc > 1) ? argv[1] : "all"; // q1 | q2 | q3 | all

    // [dspark 2026-10-16] does the driver expose cl_khr_command_buffer
    // (OpenCL's CUDA-Graph equivalent, the Metal one-command-buffer trick)?
    // Headerless: dlsym only; CL constants inlined; aarch64 handles = pointers.
    {
        typedef int (* fn5)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);
        typedef int (* fn3)(uintptr_t, uintptr_t, uintptr_t);
        void * h = dlopen("libOpenCL.so", RTLD_NOW | RTLD_LOCAL);
        if (!h) h = dlopen("libOpenCL.so.1", RTLD_NOW | RTLD_LOCAL);
        if (h) {
            fn3 pGetIDs = (fn3) dlsym(h, "clGetPlatformIDs");
            fn5 pGetInfo = (fn5) dlsym(h, "clGetPlatformInfo");
            fn5 pGetDevInfo = (fn5) dlsym(h, "clGetDeviceInfo");
            fn5 pGetDevIDs = (fn5) dlsym(h, "clGetDeviceIDs");
            uintptr_t plats[4] = {};
            unsigned int n = 0;
            if (pGetIDs && pGetInfo && pGetDevInfo && pGetDevIDs &&
                pGetIDs(4, (uintptr_t) plats, (uintptr_t) &n) == 0 && n > 0) {
                char exts[4096] = {};
                pGetInfo(plats[0], 0x0904 /*CL_PLATFORM_EXTENSIONS*/, sizeof(exts), (uintptr_t) exts, 0);
                printf("platform extensions: %s\n", exts);
                uintptr_t devs[8] = {};
                unsigned int nd = 0;
                if (pGetDevIDs(plats[0], 0xFFFFFFFFu /*CL_DEVICE_TYPE_ALL*/, 8, (uintptr_t) devs, (uintptr_t) &nd) == 0) {
                    for (unsigned int di = 0; di < nd && di < 8; ++di) {
                        char dexts[4096] = {}, dname[256] = {};
                        pGetDevInfo(devs[di], 0x102B /*CL_DEVICE_NAME*/, sizeof(dname), (uintptr_t) dname, 0);
                        pGetDevInfo(devs[di], 0x102F /*CL_DEVICE_EXTENSIONS*/, sizeof(dexts), (uintptr_t) dexts, 0);
                        printf("device[%u] %s command_buffer=%s\n", di, dname,
                               strstr(dexts, "cl_khr_command_buffer") ? "KHR-yes" :
                               (strstr(dexts, "cl_arm_command_buffer") ? "ARM-yes" : "NO"));
                    }
                }
            } else {
                printf("libOpenCL dlsym/probe failed (ggml stub active?)\n");
            }
        } else {
            printf("libOpenCL.so not loadable\n");
        }
        fflush(stdout);
    }

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
    fflush(stdout);

    if (strcmp(which, "q1") == 0 || strcmp(which, "all") == 0) {
        run_tiny_slope(cpu, "CPU");
        run_tiny_slope(ocl, "OpenCL");
    }
    if (strcmp(which, "q2") == 0 || strcmp(which, "all") == 0) {
        run_gemv_chain(cpu, "CPU", 40, 2048, 2048);
        run_gemv_chain(ocl, "OpenCL", 40, 2048, 2048);
    }
    if (strcmp(which, "q3") == 0 || strcmp(which, "all") == 0) {
        run_lmhead(cpu, "CPU");
        run_lmhead(ocl, "OpenCL");
    }
    printf("\nDONE\n");
    return 0;
}
