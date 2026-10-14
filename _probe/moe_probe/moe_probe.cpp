// Minimal on-device probe: is MUL_MAT_ID choosing the wrong expert (mapping
// bug) or computing wrong values (math/layout bug)?
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-quants.h"
static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }

static void run_on(ggml_backend_dev_t dev, const char * tag, ggml_type qt,
                   const std::vector<float> & w, const std::vector<float> & x,
                   int use_expert, const std::vector<float> & ref, int N, int K) {
    const int NMAT = 2;
    ggml_init_params ip = { 512 * 1024 * 1024, nullptr, true /*no_alloc*/ };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");

    ggml_tensor * wq = ggml_new_tensor_3d(ctx, qt, K, N, NMAT);
    ggml_tensor * xs = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, K);
    ggml_tensor * ids = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, 1);
    ggml_set_name(wq, "blk.0.ffn_gate_exps.weight"); // engage vendor Adreno MoE path like the app
    ggml_tensor * moe = ggml_mul_mat_id(ctx, wq, xs, ids);

    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, moe);

    // everything in one OCL buffer, compute directly on the backend - no sched
    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc ctx tensors");

    std::vector<uint8_t> qbuf(ggml_nbytes(wq));
    ggml_quantize_chunk(qt, w.data(), qbuf.data(), 0, NMAT * N, K, nullptr);
    ggml_backend_tensor_set(wq, qbuf.data(), 0, ggml_nbytes(wq));
    ggml_backend_tensor_set(xs, x.data(), 0, K * sizeof(float));
    ggml_backend_tensor_set(ids, &use_expert, 0, sizeof(int));

    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");

    std::vector<float> out(N);
    ggml_backend_tensor_get(moe, out.data(), 0, N * sizeof(float));

    double err_ref = 0, err_other = 0, scale = 0;
    printf("[%s] ids=[%d]:\n", tag, use_expert);
    for (int r = 0; r < N; ++r) {
        err_ref  += fabs(out[r] - ref[use_expert * N + r]);
        err_other += fabs(out[r] - ref[(1 - use_expert) * N + r]);
        scale += fabs(ref[use_expert * N + r]);
        if (r < 3)
            printf("  row%2d  out=%12.3f  ref(e%d)=%12.3f  ref(e%d)=%12.3f\n",
                   r, out[r], use_expert, ref[use_expert * N + r], 1 - use_expert,
                   ref[(1 - use_expert) * N + r]);
    }
    if (scale < 1e-9) scale = 1;
    printf("  rel|out-ref(e%d)| = %.5f   rel|out-ref(e%d)| = %.5f\n",
           use_expert, err_ref / scale, 1 - use_expert, err_other / scale);
    if (err_other / scale < 0.02 && err_other < err_ref * 0.01)
        printf("  >>> VERDICT: WRONG-EXPERT MAPPING (dispatch bug, C++-fixable)\n");
    else if (err_ref / scale < 0.02)
        printf("  >>> VERDICT: CORRECT\n");
    else
        printf("  >>> VERDICT: VALUES WRONG (matches neither expert, kernel/math bug)\n");

    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
}

int main(int argc, char ** argv) {
    const char * type_arg = (argc > 1) ? argv[1] : "q4_K";
    ggml_type qt = GGML_TYPE_Q4_K;
    if (strcmp(type_arg, "q4_0") == 0) qt = GGML_TYPE_Q4_0;
    if (strcmp(type_arg, "q8_0") == 0) qt = GGML_TYPE_Q8_0;

    const int K = 256, N = 32, NMAT = 2;
    std::vector<float> w(K * N * NMAT);
    for (int e = 0; e < NMAT; ++e)
        for (int r = 0; r < N; ++r)
            for (int k = 0; k < K; ++k)
                w[(e * N + r) * K + k] = ((k % 8) - 3.5f) * (r + 1) * (e == 0 ? 1.0f : -2.0f);
    std::vector<float> x(K);
    for (int k = 0; k < K; ++k) x[k] = ((k * 7) % 11) - 5.0f;

    std::vector<float> ref(NMAT * N);
    for (int e = 0; e < NMAT; ++e)
        for (int r = 0; r < N; ++r) {
            float s = 0;
            for (int k = 0; k < K; ++k) s += w[(e * N + r) * K + k] * x[k];
            ref[e * N + r] = s;
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
    if (!ocl) die("no OpenCL device");
    (void)cpu;


    for (int e = 0; e < NMAT; ++e) {
        run_on(ocl, type_arg, qt, w, x, e, ref, N, K);
    }
    printf("done\n");
    return 0;
}
