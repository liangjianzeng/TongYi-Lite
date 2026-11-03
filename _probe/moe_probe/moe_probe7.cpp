// [dspark 2026-10-14] probe7: reproduce e2e idx13 (blk.0 attn_qkv, q6_K
// [2048, 8192], n=1) with REAL weight bytes and REAL activation from the
// 830 dump. GPU vs precomputed CPU reference (node13_ref.bin) + on-device
// CPU backend cross-check.
//
// files (pushed next to the binary):
//   attn_qkv_l0.bin  -- q6_K raw block bytes, 13762560 B
//   attn_norm_l0.bin -- f32[2048] activation
//   node13_ref.bin   -- f32[8192] CPU reference output
#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-opencl.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cmath>

static void die(const char * msg) {
    fprintf(stderr, "FATAL: %s\n", msg);
    exit(1);
}

static std::vector<uint8_t> read_file(const char * path) {
    FILE * f = fopen(path, "rb");
    if (!f) {
        char buf[256];
        snprintf(buf, sizeof(buf), "cannot open %s", path);
        die(buf);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v((size_t) n);
    if (fread(v.data(), 1, (size_t) n, f) != (size_t) n) die("short read");
    fclose(f);
    return v;
}

int main(int argc, char ** argv) {
    ggml_time_init();
    const int K = 2048, M = 8192;

    std::vector<uint8_t> wgt = read_file("attn_qkv_l0.bin");
    std::vector<uint8_t> xb  = read_file("attn_norm_l0.bin");
    std::vector<uint8_t> rb  = read_file("node13_ref.bin");
    std::vector<float>   x((size_t)K);  memcpy(x.data(),   xb.data(), xb.size());
    std::vector<float>   ref((size_t)M); memcpy(ref.data(), rb.data(), rb.size());
    fprintf(stderr, "loaded: wgt=%zu x=%zu ref=%zu\n", wgt.size(), x.size()*4, ref.size()*4);
    if ((int)wgt.size() != ggml_row_size(GGML_TYPE_Q6_K, (int64_t)K) * M) die("weight size mismatch");
    if (x.size() != (size_t)K || ref.size() != (size_t)M) die("x/ref size mismatch");

    ggml_backend_dev_t dev_ocl = nullptr, dev_cpu = nullptr;
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        const char * name = ggml_backend_dev_name(d);
        printf("dev[%zu] = %s\n", i, name);
        if (strstr(name, "OpenCL")) dev_ocl = d;
        if (strcmp(name, "CPU") == 0) dev_cpu = d;
    }
    if (!dev_ocl || !dev_cpu) die("backend missing");

    ggml_backend_t be_ocl = ggml_backend_dev_init(dev_ocl, nullptr);
    ggml_backend_t be_cpu = ggml_backend_dev_init(dev_cpu, nullptr);

    struct ggml_init_params ip = {
        /*.mem_size   =*/ ggml_tensor_overhead()*512,
        /*.mem_buffer =*/ NULL,
        /*.no_alloc   =*/ true,
    };
    ggml_context * ctx = ggml_init(ip);

    // CPU reference graph
    ggml_tensor * wq_c = ggml_new_tensor_2d(ctx, GGML_TYPE_Q6_K, K, M);
    ggml_tensor * xc_c = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, 1);
    ggml_tensor * y_c  = ggml_mul_mat(ctx, wq_c, xc_c);

    ggml_backend_buffer_t buf_c = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev_cpu));
    ggml_backend_tensor_set(wq_c, wgt.data(), 0, wgt.size());
    ggml_backend_tensor_set(xc_c, x.data(), 0, x.size()*4);

    ggml_cgraph * gf_c = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf_c, y_c);
    ggml_backend_graph_compute(be_cpu, gf_c);

    std::vector<float> out_c(M);
    ggml_backend_tensor_get(y_c, out_c.data(), 0, M*4);

    // GPU graph (fresh tensors to force GPU-side set_tensor prep)
    ggml_tensor * wq_g = ggml_new_tensor_2d(ctx, GGML_TYPE_Q6_K, K, M);
    ggml_tensor * xc_g = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, 1);
    ggml_tensor * y_g  = ggml_mul_mat(ctx, wq_g, xc_g);

    ggml_backend_buffer_t buf_g = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev_ocl));
    ggml_backend_tensor_set(wq_g, wgt.data(), 0, wgt.size());
    ggml_backend_tensor_set(xc_g, x.data(), 0, x.size()*4);

    ggml_cgraph * gf_g = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf_g, y_g);
    ggml_backend_graph_compute(be_ocl, gf_g);

    std::vector<float> out_g(M);
    ggml_backend_tensor_get(y_g, out_g.data(), 0, M*4);

    double worst_g = 0, worst_c = 0;
    int wg_i = -1, wc_i = -1;
    for (int i = 0; i < M; ++i) {
        double r = fabs(ref[i]) > 1e-30 ? fabs(ref[i]) : 1e-30;
        double eg = fabs(out_g[i]-ref[i]) / r;
        double ec = fabs(out_c[i]-ref[i]) / r;
        if (eg > worst_g) { worst_g = eg; wg_i = i; }
        if (ec > worst_c) { worst_c = ec; wc_i = i; }
    }
    printf("q6_K REAL M=%d K=%d n=1: GPU-vs-ref rel=%.6f (idx %d)  CPU-vs-ref rel=%.6f (idx %d)\n",
           M, K, worst_g, wg_i, worst_c, wc_i);
    printf("ref[0:4]     = %.6f %.6f %.6f %.6f\n", ref[0], ref[1], ref[2], ref[3]);
    printf("cpu_out[0:4] = %.6f %.6f %.6f %.6f\n", out_c[0], out_c[1], out_c[2], out_c[3]);
    printf("gpu_out[0:4] = %.6f %.6f %.6f %.6f\n", out_g[0], out_g[1], out_g[2], out_g[3]);
    printf("gpu_out[%d:  ] = %.6f   ref=%.6f\n", wg_i, out_g[wg_i], ref[wg_i]);

    // dump GPU output for offline per-row analysis
    {
        FILE * f = fopen("/data/local/tmp/moe5/probe7_gpu_out.bin", "wb");
        if (f) { fwrite(out_g.data(), 4, M, f); fclose(f); printf("dumped gpu_out\n"); }
        f = fopen("/data/local/tmp/moe5/probe7_cpu_out.bin", "wb");
        if (f) { fwrite(out_c.data(), 4, M, f); fclose(f); printf("dumped cpu_out\n"); }
    }

    ggml_backend_buffer_free(buf_c);
    ggml_backend_buffer_free(buf_g);
    ggml_free(ctx);
    ggml_backend_free(be_ocl);
    ggml_backend_free(be_cpu);
    return 0;
}
