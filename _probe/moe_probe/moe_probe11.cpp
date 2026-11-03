// moe_probe11: [dspark 2026-10-17] repro for "RS cache state writes lost beyond
// the first ~2MB of an OpenCL buffer" (e2e: layer 0 r@0 + s@96KB correct, layer 1+
// r@2.1MB truncated/zeros). Emulates the llama-memory-recurrent layout: ONE device
// buffer holding many f32 tensors at increasing offsets (r rows 96KB, s rows 2MB),
// then exercises three round-trip paths per tensor:
//   T1 host  : ggml_backend_tensor_set  -> ggml_backend_tensor_get
//   T2 kernel: graph ggml_cpy(src_dev -> view of tensor) -> tensor_get
//   T3 kernel read: tensor_set -> graph ggml_get_rows -> tensor_get of result
// Any T2/T3 failure with T1 pass = device-side offset handling bug.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <vector>
#include <algorithm>

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"

static uint32_t rng_state = 104729;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}
static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }
static void t4_sched_repro(ggml_backend_dev_t ocl, ggml_backend_dev_t cpu);

int main() {
    ggml_backend_load_all();
    ggml_backend_dev_t ocl = nullptr, cpu = nullptr;
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t d = ggml_backend_dev_get(i);
        const char * name = ggml_backend_dev_name(d);
        printf("dev[%zu] = %s (%s)\n", i, name, ggml_backend_dev_description(d));
        if (strstr(name, "OpenCL")) ocl = d;
        if (strcmp(name, "CPU") == 0) cpu = d;
    }
    if (!ocl) die("no OpenCL device");

    // layout mirror of llama-memory-recurrent on 740 e2e: 3 "layers" of r(96KB)+s(2MB)
    const int NR = 24576;      // r row elements (conv state)
    const int NS = 524288;     // s row elements (ssm state)
    const int NL = 3;          // layers
    const int NROW = 1;        // mem_size = 1 slot (e2e cache has 1 row per layer)

    ggml_init_params ip = { 1024ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");

    // allocate ALL tensors in one context -> one buffer (same as RS cache)
    ggml_tensor * r[NL]; ggml_tensor * s[NL];
    char nm[64];
    for (int l = 0; l < NL; ++l) {
        snprintf(nm, sizeof(nm), "cache_r_l%d", l);
        r[l] = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, NR, NROW);
        ggml_set_name(r[l], nm);
        snprintf(nm, sizeof(nm), "cache_s_l%d", l);
        s[l] = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, NS, NROW);
        ggml_set_name(s[l], nm);
    }
    ggml_backend_t b = ggml_backend_dev_init(ocl, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(ocl));
    if (!buf) die("alloc device buffer");
    printf("buffer size = %.2f MiB (name %s)\n", ggml_backend_buffer_get_size(buf)/1048576.0, ggml_backend_buffer_name(buf));
    ggml_backend_buffer_clear(buf, 0);
    fflush(stdout);

    // T1: host set -> host get
    printf("\n--- T1: tensor_set -> tensor_get (host path) ---\n");
    for (int l = 0; l < NL; ++l) {
        std::vector<float> pat(NR);
        for (auto & v : pat) v = frand();
        ggml_backend_tensor_set(r[l], pat.data(), 0, NR*4);
        std::vector<float> back(NR, 0.f);
        ggml_backend_tensor_get(r[l], back.data(), 0, NR*4);
        int bad = 0; for (int i = 0; i < NR; ++i) if (back[i] != pat[i]) bad++;
        printf("  r_l%d: mismatch %d/%d %s\n", l, bad, NR, bad == 0 ? "OK" : "<-- FAIL");
        fflush(stdout);
    }

    // T2: kernel cpy -> tensor_get. Graph: x = scale(inp,1) on device; cpy(x -> view of r[l])
    printf("\n--- T2: graph cpy(dev src -> view dst) -> tensor_get ---\n");
    for (int l = 0; l < NL; ++l) {
        std::vector<float> pat(NR);
        for (auto & v : pat) v = frand();
        ggml_backend_buffer_clear(buf, 0);
        // put pattern into a device tensor first (host path, proven by T1)
        ggml_backend_tensor_set(r[l], pat.data(), 0, NR*4);
        // now round-trip via kernel: read r[l] rows through get_rows, cpy result back
        ggml_context * gctx = ggml_init(ip);
        ggml_tensor * idx = ggml_new_tensor_1d(gctx, GGML_TYPE_I32, 1);
        ggml_tensor * rd = ggml_get_rows(gctx, r[l], idx);      // [NR,1] read from device
        ggml_tensor * dstv = ggml_view_2d(gctx, r[l], NR, 1, r[l]->nb[1], 0);
        ggml_tensor * cp = ggml_cpy(gctx, rd, dstv);            // device->device write
        ggml_cgraph * gf = ggml_new_graph(gctx);
        ggml_build_forward_expand(gf, cp);
        // allocate graph-local tensors (idx) on the device too; views inherit r[l]'s buffer
        ggml_backend_buffer_t gbuf = ggml_backend_alloc_ctx_tensors_from_buft(gctx, ggml_backend_dev_buffer_type(ocl));
        if (!gbuf) die("alloc gbuf T2");
        int32_t zero = 0;
        ggml_backend_tensor_set(idx, &zero, 0, 4);
        if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute T2");
        std::vector<float> back(NR, 0.f);
        ggml_backend_tensor_get(r[l], back.data(), 0, NR*4);
        int bad = 0; for (int i = 0; i < NR; ++i) if (back[i] != pat[i]) bad++;
        printf("  r_l%d: mismatch %d/%d %s (nonzero %d)\n", l, bad, NR, bad == 0 ? "OK" : "<-- FAIL",
               (int)std::count_if(back.begin(), back.end(), [](float v){ return v != 0.f; }));
        ggml_backend_buffer_free(gbuf);
        ggml_free(gctx);
        fflush(stdout);
    }

    // T3: same but with 2MB-strided s tensors (big offsets)
    printf("\n--- T3: s tensors (2MB rows) kernel round-trip ---\n");
    for (int l = 0; l < NL; ++l) {
        std::vector<float> pat(NS);
        for (auto & v : pat) v = frand();
        ggml_backend_buffer_clear(buf, 0);
        ggml_backend_tensor_set(s[l], pat.data(), 0, NS*4);
        ggml_context * gctx = ggml_init(ip);
        ggml_tensor * idx = ggml_new_tensor_1d(gctx, GGML_TYPE_I32, 1);
        ggml_tensor * rd = ggml_get_rows(gctx, s[l], idx);
        ggml_tensor * dstv = ggml_view_2d(gctx, s[l], NS, 1, s[l]->nb[1], 0);
        ggml_tensor * cp = ggml_cpy(gctx, rd, dstv);
        ggml_cgraph * gf = ggml_new_graph(gctx);
        ggml_build_forward_expand(gf, cp);
        ggml_backend_buffer_t gbuf = ggml_backend_alloc_ctx_tensors_from_buft(gctx, ggml_backend_dev_buffer_type(ocl));
        if (!gbuf) die("alloc gbuf T3");
        int32_t zero = 0;
        ggml_backend_tensor_set(idx, &zero, 0, 4);
        if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute T3");
        // verify first/last 4096 elements + middle
        std::vector<float> back(NS, 0.f);
        ggml_backend_tensor_get(s[l], back.data(), 0, NS*4);
        int bad = 0, nz = 0;
        for (int i = 0; i < NS; ++i) { if (back[i] != pat[i]) bad++; if (back[i] != 0.f) nz++; }
        // find first mismatch index
        int first = -1; for (int i = 0; i < NS; ++i) if (back[i] != pat[i]) { first = i; break; }
        printf("  s_l%d: mismatch %d/%d nonzero %d first_bad@%d %s\n", l, bad, NS, nz, first,
               bad == 0 ? "OK" : "<-- FAIL");
        ggml_backend_buffer_free(gbuf);
        ggml_free(gctx);
        fflush(stdout);
    }

    ggml_backend_buffer_free(buf);
    ggml_backend_free(b);
    ggml_free(ctx);
    t4_sched_repro(ocl, cpu);
    printf("\nDONE\n");
    return 0;
}

// T4: full sched-based repro of the delta-net conv-state chain (llama-memory +
// multi-backend, mirrors qwen35moe build_conv_state):
//   cache_r = [24576,1] f32 in device buffer (cleared 0)
//   per iter: conv_states = get_rows(cache, idx[1])
//             conv_reshaped = reshape -> [3,8192]
//             qkv = input [1,8192] (new pattern each iter)
//             conv_input = concat(conv_reshaped, qkv, 0) -> [4,8192]
//             state_last = view_3d(conv_input, 3, 8192, 1, nb1, nb2, 4)
//             cpy(state_last -> view_2d(cache_r, 24576, 1, nb1, 0))
//             + CPU-side mul_mat node to force sched splits (MoE-on-CPU analog)
//   expected cache after iter k: [old[8192:24576] | qkv_k]
static void t4_sched_repro(ggml_backend_dev_t ocl, ggml_backend_dev_t cpu) {
    printf("\n--- T4: sched-based delta-net conv chain ---\n");
    const int NR = 24576, CH = 8192;
    ggml_init_params ip = { 512ULL * 1024 * 1024, nullptr, true };

    // cache context: one device tensor
    ggml_context * cctx = ggml_init(ip);
    ggml_tensor * cache = ggml_new_tensor_2d(cctx, GGML_TYPE_F32, NR, 1);
    ggml_set_name(cache, "cache_r");
    ggml_backend_t b_ocl = ggml_backend_dev_init(ocl, nullptr);
    ggml_backend_buffer_t cbuf = ggml_backend_alloc_ctx_tensors_from_buft(cctx, ggml_backend_dev_buffer_type(ocl));
    if (!cbuf) die("alloc cache buf");
    ggml_backend_buffer_clear(cbuf, 0);

    // CPU weight for split-forcing node
    ggml_tensor * cw = ggml_new_tensor_2d(cctx, GGML_TYPE_F32, CH, 32);
    ggml_set_name(cw, "cpu_weight");
    ggml_backend_buffer_t wbuf = ggml_backend_alloc_ctx_tensors_from_buft(cctx, ggml_backend_dev_buffer_type(cpu));
    if (!wbuf) die("alloc weight buf");
    {
        std::vector<float> w((size_t)CH * 32);
        for (auto & v : w) v = frand();
        ggml_backend_tensor_set(cw, w.data(), 0, w.size()*4);
    }

    // sched: OpenCL first (preferred), CPU fallback
    ggml_backend_t b_cpu = ggml_backend_dev_init(cpu, nullptr);
    ggml_backend_t sched_backends[2] = { b_ocl, b_cpu };
    ggml_backend_sched_t sched = ggml_backend_sched_new(sched_backends, nullptr, 2, 1024, false, false);

    std::vector<float> prev(NR, 0.f);   // expected cache state
    for (int it = 0; it < 3; ++it) {
        ggml_context * gctx = ggml_init(ip);
        ggml_tensor * idx = ggml_new_tensor_1d(gctx, GGML_TYPE_I32, 1);
        ggml_tensor * qkv = ggml_new_tensor_2d(gctx, GGML_TYPE_F32, CH, 1);   // qkv_mixed: [qkv_dim, n_tok]
        ggml_tensor * cwr = ggml_new_tensor_2d(gctx, GGML_TYPE_F32, CH, 32);  // weight input copy

        ggml_tensor * conv_states = ggml_get_rows(gctx, cache, idx);          // [NR,1]
        conv_states = ggml_reshape_2d(gctx, conv_states, 3, CH);              // [3,8192]
        ggml_tensor * qkvT = ggml_transpose(gctx, qkv);                       // [CH,1]^T -> [CH,1]... ne=[1? ]
        ggml_tensor * conv_input = ggml_concat(gctx, conv_states, qkvT, 0);   // [3+1, 8192]
        ggml_tensor * state_last = ggml_view_3d(gctx, conv_input, 3, CH, 1,
                conv_input->nb[1], conv_input->nb[2], ggml_row_size(GGML_TYPE_F32, 1));
        ggml_tensor * dstv = ggml_view_2d(gctx, cache, NR, 1, cache->nb[1], 0);
        ggml_tensor * cp = ggml_cpy(gctx, state_last, dstv);
        // CPU-side node to force splits (weight lives in CPU buffer)
        ggml_tensor * y = ggml_mul_mat(gctx, cw, cwr);
        ggml_cgraph * gf = ggml_new_graph(gctx);
        ggml_build_forward_expand(gf, cp);
        ggml_build_forward_expand(gf, y);

        ggml_backend_sched_reset(sched);
        if (!ggml_backend_sched_alloc_graph(sched, gf)) die("sched alloc");

        int32_t zero = 0;
        ggml_backend_tensor_set(idx, &zero, 0, 4);
        std::vector<float> qkvp(CH);
        for (auto & v : qkvp) v = frand();
        ggml_backend_tensor_set(qkv, qkvp.data(), 0, CH*4);
        ggml_backend_tensor_set(cwr, qkvp.data(), 0, CH*4);   // content irrelevant

        if (ggml_backend_sched_graph_compute_async(sched, gf) != GGML_STATUS_SUCCESS) die("sched compute");
        ggml_backend_sched_synchronize(sched);

        // expected: [prev[8192:24576] | qkv]
        std::vector<float> exp(NR), got(NR, -1.f);
        for (int i = 0; i < NR - CH; ++i) exp[i] = prev[CH + i];
        for (int i = 0; i < CH; ++i) exp[NR - CH + i] = qkvp[i];
        ggml_backend_tensor_get(cache, got.data(), 0, NR*4);
        int bad = 0, first = -1;
        for (int i = 0; i < NR; ++i) if (got[i] != exp[i]) { if (first < 0) first = i; bad++; }
        int nz = (int)std::count_if(got.begin(), got.end(), [](float v){ return v != 0.f; });
        printf("  iter %d: mismatch %d/%d nonzero %d first_bad@%d %s\n", it, bad, NR, nz, first,
               bad == 0 ? "OK" : "<-- FAIL");
        fflush(stdout);
        prev = got;
        ggml_backend_sched_reset(sched);
        ggml_free(gctx);
    }
    ggml_backend_sched_free(sched);
    ggml_backend_buffer_free(wbuf);
    ggml_backend_buffer_free(cbuf);
    ggml_backend_free(b_ocl);
    ggml_backend_free(b_cpu);
    ggml_free(cctx);
}
