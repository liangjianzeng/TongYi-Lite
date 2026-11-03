// moe_probe6: q4_K MUL_MAT shape sweep for Adreno 830 GEMM-path validation.
// For each (M, K): q4_K weight [K, M] + f32 activations [K, n], n=1 and n=8.
// GPU (OpenCL) vs CPU reference, prints max relative error per case.
//
// NOTE: tensors must be allocated via ggml_backend_alloc_ctx_tensors_from_buft
// (NOT ggml_gallocr): the OpenCL backend creates tensor->extra (cl_mem binding)
// inside buffer init_tensor, which gallocr never calls. Without extras the
// backend treats every op as CPU-only and MUL_MAT aborts ("op not supported").
#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-opencl.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <random>

struct Case { int M, K; const char * tag; };

static float run_case(ggml_backend_t be_gpu, ggml_backend_t be_cpu, int M, int K, int n, ggml_type wtype) {
    // host staging: random activations [K, n] and random f32 weights [K, M]
    std::mt19937 rng(1234 + M*7 + K*13 + n);
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    std::vector<float> x((size_t)K * n);
    for (auto & v : x) v = dist(rng);
    std::vector<float> wf((size_t)K * M);
    for (auto & v : wf) v = dist(rng);
    std::vector<uint8_t> qb;

    // ---- CPU reference ----
    std::vector<float> ref((size_t)M*n);
    {
        ggml_init_params ip = { 256*1024*1024, NULL, true };
        ggml_context * ctx = ggml_init(ip);

        ggml_tensor * xa = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, n);
        ggml_tensor * wq = ggml_new_tensor_2d(ctx, wtype, K, M);
        qb.resize(ggml_nbytes(wq));
        ggml_quantize_chunk(wtype, wf.data(), qb.data(), 0, M, K, NULL);

        ggml_tensor * y = ggml_mul_mat(ctx, wq, xa);
        ggml_cgraph * gf = ggml_new_graph(ctx);
        ggml_build_forward_expand(gf, y);

        ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(
            ctx, ggml_backend_get_default_buffer_type(be_cpu));
        ggml_backend_tensor_set(xa, x.data(), 0, x.size()*sizeof(float));
        ggml_backend_tensor_set(wq, qb.data(), 0, qb.size());
        ggml_backend_graph_compute(be_cpu, gf);
        ggml_backend_tensor_get(y, ref.data(), 0, ref.size()*sizeof(float));

        ggml_backend_buffer_free(buf);
        ggml_free(ctx);
    }

    // ---- GPU ----
    std::vector<float> got((size_t)M*n);
    {
        ggml_init_params ip = { 256*1024*1024, NULL, true };
        ggml_context * ctx = ggml_init(ip);

        ggml_tensor * xa = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, n);
        ggml_tensor * wq = ggml_new_tensor_2d(ctx, wtype, K, M);
        ggml_tensor * y = ggml_mul_mat(ctx, wq, xa);
        ggml_cgraph * gf = ggml_new_graph(ctx);
        ggml_build_forward_expand(gf, y);

        ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(
            ctx, ggml_backend_get_default_buffer_type(be_gpu));
        ggml_backend_tensor_set(xa, x.data(), 0, x.size()*sizeof(float));
        ggml_backend_tensor_set(wq, qb.data(), 0, qb.size());
        ggml_backend_graph_compute(be_gpu, gf);
        ggml_backend_tensor_get(y, got.data(), 0, got.size()*sizeof(float));

        ggml_backend_buffer_free(buf);
        ggml_free(ctx);
    }

    double worst = 0, refmax = 1e-9;
    for (size_t i = 0; i < ref.size(); i++) {
        double d = fabs((double)got[i] - ref[i]);
        double r = fabs((double)ref[i]);
        if (r > refmax) refmax = r;
        if (d > worst) worst = d;
    }
    return (float)(worst / refmax);
}

int main() {
    ggml_backend_load_all();

    ggml_backend_dev_t dev_gpu = nullptr;
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(d) == GGML_BACKEND_DEVICE_TYPE_GPU) { dev_gpu = d; break; }
    }
    if (!dev_gpu) { fprintf(stderr, "no GPU device\n"); return 1; }
    ggml_backend_t be_gpu = ggml_backend_dev_init(dev_gpu, NULL);
    ggml_backend_dev_t dev_cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    ggml_backend_t be_cpu = ggml_backend_dev_init(dev_cpu, NULL);

    std::vector<std::pair<ggml_type, std::vector<Case>>> suites = {
        { GGML_TYPE_Q4_K, {
            { 2048, 4096, "attn-like" },
            { 4096, 2048, "attn_q/out" },
            { 8192, 2048, "inner" },
            { 2048, 512,  "down-ish" },
            { 512,  2048, "shexp" },
            { 4096, 1024, "tbo-fail-shape" },
            { 1023, 4096, "tbo-pass-shape" },
        }},
        { GGML_TYPE_Q6_K, {
            { 2048, 4096, "attn-like" },
            { 4096, 2048, "attn_qkv" },
            { 8192, 2048, "ffn_down" },
            { 2048, 512,  "attn_v" },
            { 512,  2048, "attn_v-real" },
            { 2048, 2048, "sq" },
            { 248144, 2048, "lm_head" },
        }},
    };
    for (auto & suite : suites) {
        const char * tname = ggml_type_name(suite.first);
        for (auto & c : suite.second) {
            printf("--- case %s M=%d K=%d (%s)\n", tname, c.M, c.K, c.tag);
            fflush(stdout);
            float r1 = run_case(be_gpu, be_cpu, c.M, c.K, 1, suite.first);
            printf("%s M=%-6d K=%-5d n=1  rel_err=%.6f  %s  (%s)\n", tname, c.M, c.K, r1,
                   r1 < 0.01 ? "OK" : "FAIL", c.tag);
            fflush(stdout);
            float r8 = run_case(be_gpu, be_cpu, c.M, c.K, 8, suite.first);
            printf("%s M=%-6d K=%-5d n=8  rel_err=%.6f  %s  (%s)\n", tname, c.M, c.K, r8,
                   r8 < 0.01 ? "OK" : "FAIL", c.tag);
            fflush(stdout);
        }
    }

    ggml_backend_free(be_gpu);
    ggml_backend_free(be_cpu);
    return 0;
}
