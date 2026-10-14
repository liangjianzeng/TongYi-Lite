// Shape sweep for MUL_MAT_ID on Adreno 830 OpenCL.
// Reference = CPU backend on the SAME quantized buffer, so quantization noise
// cancels out and any mismatch > fp-tolerance is a real backend bug.
// Usage: moe_probe2 <q4_0|q4_K|q8_0>
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

static uint32_t rng_state = 12345;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}

static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }

// one MUL_MAT_ID compute on the given device with a fresh ctx; returns output
static std::vector<float> compute_on(ggml_backend_dev_t dev, ggml_type qt,
                                     int N, int K, int E, int nids, int ntok,
                                     const std::vector<uint8_t> & qdata,
                                     const std::vector<float> & x,
                                     const std::vector<int32_t> & ids) {
    ggml_init_params ip = { 512 * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");

    ggml_tensor * wq = ggml_new_tensor_3d(ctx, qt, K, N, E);
    ggml_tensor * xs = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, K, nids, ntok);
    ggml_tensor * idt = ggml_new_tensor_2d(ctx, GGML_TYPE_I32, nids, ntok);
    ggml_set_name(wq, "as"); // force moe_router_reoerder like test-backend-ops
    ggml_tensor * moe = ggml_mul_mat_id(ctx, wq, xs, idt);

    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, moe);

    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc ctx tensors");

    ggml_backend_tensor_set(wq, qdata.data(), 0, ggml_nbytes(wq));
    ggml_backend_tensor_set(xs, x.data(), 0, x.size() * sizeof(float));
    ggml_backend_tensor_set(idt, ids.data(), 0, ids.size() * sizeof(int));

    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");

    std::vector<float> out((size_t)N * nids * ntok);
    ggml_backend_tensor_get(moe, out.data(), 0, out.size() * sizeof(float));

    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    return out;
}

static bool run_case(ggml_backend_dev_t ocl, ggml_backend_dev_t cpu, ggml_type qt,
                     int N, int K, int E, int nids, int ntok, const char * shape_tag) {
    // host-side source data
    std::vector<float> w((size_t)K * N * E);
    for (auto & v : w) v = frand();
    std::vector<float> x((size_t)K * ntok);
    for (auto & v : x) v = frand();
    std::vector<int32_t> ids((size_t)nids * ntok);
    for (size_t i = 0; i < ids.size(); ++i) ids[i] = (int32_t)((i * 7 + 3) % E);

    size_t qsize = (size_t)N * E * K * ggml_type_size(qt) / ggml_blck_size(qt);
    std::vector<uint8_t> qdata(qsize);
    ggml_quantize_chunk(qt, w.data(), qdata.data(), 0, N * E, K, NULL);

    std::vector<float> ref = compute_on(cpu, qt, N, K, E, nids, ntok, qdata, x, ids);
    std::vector<float> out = compute_on(ocl, qt, N, K, E, nids, ntok, qdata, x, ids);

    double num = 0, den = 0;
    for (size_t i = 0; i < out.size(); ++i) {
        num += fabs((double)out[i] - ref[i]);
        den += fabs((double)ref[i]);
    }
    double rel = num / (den > 1e-9 ? den : 1);
    bool pass = rel < 0.02;
    printf("  %-28s rel_err=%.5f  %s\n", shape_tag, rel, pass ? "PASS" : "** FAIL **");
    return pass;
}

int main(int argc, char ** argv) {
    const char * type_arg = (argc > 1) ? argv[1] : "q4_0";
    ggml_type qt = GGML_TYPE_Q4_0;
    if (strcmp(type_arg, "q4_K") == 0) qt = GGML_TYPE_Q4_K;
    if (strcmp(type_arg, "q8_0") == 0) qt = GGML_TYPE_Q8_0;

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

    printf("\n=== MUL_MAT_ID shape sweep, type=%s ===\n", type_arg);
    struct C { int N, K, E, nids, ntok; };
    C cases[] = {
        {   32,  256, 2,  1,   1 },   // minimal decode-like (known good in v2)
        {   32,  256, 8,  8,   1 },   // more experts, all selected
        {   32,  256, 8,  4,   1 },   // subset selected
        {   32,  256, 8,  8,   2 },   // 2 tokens
        {   32,  256, 8,  8,  64 },   // many tokens
        {  512,  256, 8,  8,   1 },   // bigger N
        {  512, 1792, 8,  8,   1 },   // LFM-like N,K decode
        {  512, 1792, 8,  8, 512 },   // prefill-like
        { 1792, 1792, 8,  8,   1 },
        {  512, 1792, 32, 8,   1 },   // 32 experts like LFM
    };
    int fails = 0;
    for (auto & c : cases) {
        char tag[64];
        snprintf(tag, sizeof(tag), "N=%d K=%d E=%d ids=%d tok=%d", c.N, c.K, c.E, c.nids, c.ntok);
        if (!run_case(ocl, cpu, qt, c.N, c.K, c.E, c.nids, c.ntok, tag)) ++fails;
    }
    printf("=== %d/%zu cases FAILED ===\n", fails, sizeof(cases) / sizeof(cases[0]));
    return fails ? 1 : 0;
}
