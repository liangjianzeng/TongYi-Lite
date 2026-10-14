// Decomposition probe for the dense-loop MUL_MAT_ID accumulation error.
// Shape: N=512 K=256 E=8 nids=2 ntok=1 (matches tbo case with NMSE ~0.006).
// Stages compared against exact CPU dequant reference:
//   A) GPU MUL_MAT_ID (dense-loop)           -> gpu_id
//   B) GPU MUL_MAT  per expert (dense 2D)    -> g0, g1  (standalone, neutral name)
//   C) CPU MUL_MAT  per expert               -> r0, r1
// Then: g0+g1 vs r0+r1 vs gpu_id pinpoints which stage deviates.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <vector>

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-quants.h"

static uint32_t rng_state = 777;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}
static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }

static const int N = 512, K = 256, E = 8;
static const int e0 = 3, e1 = 5;   // fixed expert ids

static double nmse(const std::vector<float> & a, const std::vector<float> & b) {
    double num = 0, den = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        double d = (double)a[i] - b[i];
        num += d * d;
        den += (double)b[i] * b[i];
    }
    return num / (den > 1e-12 ? den : 1);
}

// dense 2D MUL_MAT: w [K,N] qt, x [K,1] f32, on given device
static std::vector<float> dense_matmul(ggml_backend_dev_t dev, ggml_type qt,
                                       const std::vector<uint8_t> & qslice,
                                       const std::vector<float> & x) {
    ggml_init_params ip = { 256 * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    ggml_tensor * w = ggml_new_tensor_2d(ctx, qt, K, N);
    ggml_set_name(w, "w2dneu"); // neutral name: no moe gate match
    ggml_tensor * xs = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, 1);
    ggml_tensor * out = ggml_mul_mat(ctx, w, xs);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, out);
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    ggml_backend_tensor_set(w, qslice.data(), 0, ggml_nbytes(w));
    ggml_backend_tensor_set(xs, x.data(), 0, x.size() * sizeof(float));
    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");
    std::vector<float> o(N);
    ggml_backend_tensor_get(out, o.data(), 0, o.size() * sizeof(float));
    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return o;
}

// MUL_MAT_ID dense-loop on OpenCL with configurable ids
static std::vector<float> moe_id(ggml_backend_dev_t dev, ggml_type qt,
                                 const std::vector<uint8_t> & qdata,
                                 const std::vector<float> & x, int id0, int id1) {
    ggml_init_params ip = { 256 * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");
    ggml_tensor * wq = ggml_new_tensor_3d(ctx, qt, K, N, E);
    ggml_set_name(wq, "as");
    ggml_tensor * xs = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, K, 2, 1);
    ggml_tensor * idt = ggml_new_tensor_2d(ctx, GGML_TYPE_I32, 2, 1);
    ggml_tensor * moe = ggml_mul_mat_id(ctx, wq, xs, idt);
    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, moe);
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    ggml_backend_tensor_set(wq, qdata.data(), 0, ggml_nbytes(wq));
    std::vector<float> x2((size_t)K * 2);
    memcpy(x2.data(), x.data(), K * sizeof(float));       // slot 0
    memcpy(x2.data() + K, x.data(), K * sizeof(float));   // slot 1 (same x, b=false)
    ggml_backend_tensor_set(xs, x2.data(), 0, x2.size() * sizeof(float));
    int32_t ids[2] = { id0, id1 };
    ggml_backend_tensor_set(idt, ids, 0, sizeof(ids));
    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");
    std::vector<float> o((size_t)N * 2);
    ggml_backend_tensor_get(moe, o.data(), 0, o.size() * sizeof(float));
    return o; // [slot0 | slot1]
    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return o;
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

    const ggml_type qt = GGML_TYPE_Q4_0;
    const size_t blk = 32;

    // host data
    std::vector<float> w((size_t)K * N * E);
    for (auto & v : w) v = frand();
    std::vector<float> x(K);
    for (auto & v : x) v = frand();
    std::vector<uint8_t> qdata((size_t)N * E * K * ggml_type_size(qt) / blk);
    ggml_quantize_chunk(qt, w.data(), qdata.data(), 0, N * E, K, NULL);

    const size_t slice_bytes = (size_t)N * K * ggml_type_size(qt) / blk;
    std::vector<uint8_t> q0(qdata.begin() + (size_t)e0 * slice_bytes, qdata.begin() + (size_t)(e0 + 1) * slice_bytes);
    std::vector<uint8_t> q1(qdata.begin() + (size_t)e1 * slice_bytes, qdata.begin() + (size_t)(e1 + 1) * slice_bytes);

    // exact CPU dequant reference for the two experts
    std::vector<float> wdq((size_t)K * N * E);
    dequantize_row_q4_0((const block_q4_0 *)qdata.data(), wdq.data(), (size_t)K * N * E);
    std::vector<float> r0(N), r1(N), rsum(N);
    for (int n = 0; n < N; ++n) {
        double s0 = 0, s1 = 0;
        for (int k = 0; k < K; ++k) {
            s0 += (double)wdq[(size_t)e0 * N * K + (size_t)n * K + k] * x[k];
            s1 += (double)wdq[(size_t)e1 * N * K + (size_t)n * K + k] * x[k];
        }
        r0[n] = (float)s0;
        r1[n] = (float)s1;
        rsum[n] = (float)(s0 + s1);
    }

    // GPU stages
    std::vector<float> g0 = dense_matmul(ocl, qt, q0, x);
    std::vector<float> g1 = dense_matmul(ocl, qt, q1, x);
    std::vector<float> gpu_id = moe_id(ocl, qt, qdata, x, e0, e1);
    std::vector<float> gpu_same = moe_id(ocl, qt, qdata, x, e0, e0); // gather: both slots = W_e0*x

    // CPU backend stages (same quantized data)
    std::vector<float> c0 = dense_matmul(cpu, qt, q0, x);
    std::vector<float> c1 = dense_matmul(cpu, qt, q1, x);

    // gather-semantics references
    std::vector<float> ref0(gpu_id.begin(), gpu_id.begin() + N);
    std::vector<float> ref1(gpu_id.begin() + N, gpu_id.end());
    std::vector<float> same0(gpu_same.begin(), gpu_same.begin() + N);
    std::vector<float> same1(gpu_same.begin() + N, gpu_same.end());
    std::vector<float> gsum(N);
    for (int i = 0; i < N; ++i) gsum[i] = g0[i] + g1[i];

    printf("\n--- NMSE vs exact-dequant CPU reference (gather semantics) ---\n");
    printf("gpu dense MUL_MAT e%d      : %.8f\n", e0, nmse(g0, r0));
    printf("gpu dense MUL_MAT e%d      : %.8f\n", e1, nmse(g1, r1));
    printf("cpu dense MUL_MAT e%d      : %.8f\n", e0, nmse(c0, r0));
    printf("cpu dense MUL_MAT e%d      : %.8f\n", e1, nmse(c1, r1));
    printf("gpu_id slot0 vs r0         : %.8f\n", nmse(ref0, r0));
    printf("gpu_id slot1 vs r1         : %.8f\n", nmse(ref1, r1));
    printf("gpu_same slot0 vs r0       : %.8f\n", nmse(same0, r0));
    printf("gpu_same slot1 vs r0       : %.8f\n", nmse(same1, r0));
    return 0;
}
