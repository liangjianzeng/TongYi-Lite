// ssm_probe: G-770 —— SSM_CONV / SSM_SCAN 的 OpenCL vs CPU 逐元素对拍（数值契约）。
// 背景（网格 G-770）：SSM 内核至今没有逐 op 数值契约；G-769 把 SSM 恢复 GPU 默认靠的
// 只是端到端贪心文本（弱证据）。本探针在同一输入上分别用 OpenCL 后端与 CPU 后端算
// 同一张图，报 max_abs / max_rel / NMSE；阈值 rel 1e-2（G-770 起点线）。
// 跑法：ssm_probe [-v]；设备上 LD_LIBRARY_PATH 指向带 libggml-opencl.so 的目录。
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <vector>

#include "ggml.h"
#include "ggml-backend.h"

static uint32_t rng_state = 20261025u;
static float frand() {
    rng_state = rng_state * 1664525u + 1013904223u;
    return ((rng_state >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}
static void die(const char * msg) { fprintf(stderr, "FATAL: %s\n", msg); exit(1); }

struct DiffStats {
    double max_abs = 0, max_rel = 0, nmse = 0;
    size_t n = 0;
    int idx_abs = 0;
};

static DiffStats diff(const std::vector<float> & a, const std::vector<float> & b) {
    DiffStats st;
    double num = 0, den = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        double d = fabs((double)a[i] - (double)b[i]);
        double r = d / (fabs((double)b[i]) > 1e-6 ? fabs((double)b[i]) : 1e-6);
        num += d * d;
        den += (double)b[i] * b[i];
        if (d > st.max_abs) { st.max_abs = d; st.idx_abs = (int)i; }
        if (r > st.max_rel) st.max_rel = r;
    }
    st.n = a.size();
    st.nmse = den > 1e-12 ? num / den : num;
    return st;
}

// 在指定后端上算 conv+scan 一张图，返回 (conv_out, scan_out)。
// conv: sx {d_conv-1+n_t, d_inner, n_s} × w {d_conv, d_inner} -> {d_inner, n_t, n_s}
// scan: s {d_state, dim, n_head, n_s} x {dim, n_head, n_t, n_s} dt {n_head, n_t, n_s}
//       A {d_state, n_head} B/C {d_state, n_group, n_t, n_s} ids {n_s} -> y+states 1D
struct SsmOut {
    std::vector<float> conv, scan;
};

static SsmOut run_on(ggml_backend_dev_t dev, int d_state, int dim, int n_head, int n_group,
                     int n_tok, int n_seqs, int d_conv,
                     const std::vector<float> & sx, const std::vector<float> & cw,
                     const std::vector<float> & s, const std::vector<float> & x,
                     const std::vector<float> & dt, const std::vector<float> & A,
                     const std::vector<float> & B, const std::vector<float> & C,
                     const std::vector<int32_t> & ids, int64_t K) {
    ggml_init_params ip = { 512ULL * 1024 * 1024, nullptr, true };
    ggml_context * ctx = ggml_init(ip);
    if (!ctx) die("ggml_init");

    ggml_tensor * tsx = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, d_conv - 1 + n_tok, dim, n_seqs);
    ggml_tensor * tcw = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, d_conv, dim);
    ggml_tensor * conv = ggml_ssm_conv(ctx, tsx, tcw);

    ggml_tensor * ts = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, d_state, dim, n_head, n_seqs);
    ggml_tensor * tx = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, dim, n_head, n_tok, n_seqs);
    ggml_tensor * tdt = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, n_head, n_tok, n_seqs);
    ggml_tensor * tA = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, d_state, n_head);
    ggml_tensor * tB = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, d_state, n_group, n_tok, n_seqs);
    ggml_tensor * tC = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, d_state, n_group, n_tok, n_seqs);
    ggml_tensor * tids = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, n_seqs);
    ggml_tensor * scan = ggml_ssm_scan(ctx, ts, tx, tdt, tA, tB, tC, tids, K);

    ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, conv);
    ggml_build_forward_expand(gf, scan);

    ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_dev_buffer_type(dev));
    if (!buf) die("alloc");
    ggml_backend_tensor_set(tsx, sx.data(), 0, ggml_nbytes(tsx));
    ggml_backend_tensor_set(tcw, cw.data(), 0, ggml_nbytes(tcw));
    ggml_backend_tensor_set(ts,  s.data(),  0, ggml_nbytes(ts));
    ggml_backend_tensor_set(tx,  x.data(),  0, ggml_nbytes(tx));
    ggml_backend_tensor_set(tdt, dt.data(), 0, ggml_nbytes(tdt));
    ggml_backend_tensor_set(tA,  A.data(),  0, ggml_nbytes(tA));
    ggml_backend_tensor_set(tB,  B.data(),  0, ggml_nbytes(tB));
    ggml_backend_tensor_set(tC,  C.data(),  0, ggml_nbytes(tC));
    ggml_backend_tensor_set(tids, ids.data(), 0, ggml_nbytes(tids));

    if (ggml_backend_graph_compute(b, gf) != GGML_STATUS_SUCCESS) die("compute");

    SsmOut o;
    o.conv.resize(ggml_nelements(conv));
    ggml_backend_tensor_get(conv, o.conv.data(), 0, o.conv.size() * sizeof(float));
    o.scan.resize(ggml_nelements(scan));
    ggml_backend_tensor_get(scan, o.scan.data(), 0, o.scan.size() * sizeof(float));

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
    if (!ocl) { printf("NO_OPENCL_DEVICE: 只有 CPU，本探针要求 OpenCL 在场\n"); return 2; }
    if (!cpu) die("CPU backend missing");

    // d_state 扫描（G-770 点名 4/8/16/32/128/256）× 两组头形
    const int d_states[] = { 4, 8, 16, 32, 128, 256 };
    int fails = 0, total = 0;
    for (unsigned di = 0; di < sizeof(d_states) / sizeof(d_states[0]); ++di) {
        const int d_state = d_states[di];
        // 两档：decode 形（n_tok=1）与 prefill 形（n_tok=8）；dim/head 取 Ling 侧常见量级
        const int configs[][4] = { {128, 8, 1, 1}, {64, 16, 2, 8} };   // {dim, n_head, n_group, n_tok}
        for (unsigned ci = 0; ci < 2; ++ci) {
            const int dim = configs[ci][0], n_head = configs[ci][1];
            const int n_group = configs[ci][2], n_tok = configs[ci][3];
            const int n_seqs = 1, d_conv = 4;
            const int64_t K = 1;

            const size_t n_sx = (size_t)(d_conv - 1 + n_tok) * dim * n_seqs;
            const size_t n_cw = (size_t)d_conv * dim;
            const size_t n_s = (size_t)d_state * dim * n_head * n_seqs;
            const size_t n_x = (size_t)dim * n_head * n_tok * n_seqs;
            const size_t n_dt = (size_t)n_head * n_tok * n_seqs;
            const size_t n_A = (size_t)d_state * n_head;
            const size_t n_B = (size_t)d_state * n_group * n_tok * n_seqs;
            std::vector<float> sx(n_sx), cw(n_cw), s(n_s), x(n_x), dt(n_dt), A(n_A), B(n_B), C(n_B);
            for (auto & v : sx) v = frand();
            for (auto & v : cw) v = frand();
            for (auto & v : s)  v = frand() * 0.1f;
            for (auto & v : x)  v = frand();
            for (auto & v : dt) v = 0.001f + 0.5f * (frand() + 1.0f);   // dt > 0（物理稳定）
            for (size_t i = 0; i < A.size(); ++i) A[i] = -(0.5f + (i % 7));  // A < 0（衰减）
            for (auto & v : B)  v = frand();
            for (auto & v : C)  v = frand();
            std::vector<int32_t> ids = { 0 };

            SsmOut oc = run_on(ocl, d_state, dim, n_head, n_group, n_tok, n_seqs, d_conv,
                               sx, cw, s, x, dt, A, B, C, ids, K);
            SsmOut cp = run_on(cpu, d_state, dim, n_head, n_group, n_tok, n_seqs, d_conv,
                               sx, cw, s, x, dt, A, B, C, ids, K);

            DiffStats dc = diff(oc.conv, cp.conv);
            DiffStats ds = diff(oc.scan, cp.scan);
            const bool conv_ok = dc.max_rel <= 1e-2;
            const bool scan_ok = ds.max_rel <= 1e-2;
            printf("[ssm] d_state=%-3d dim=%-3d head=%-2d grp=%d tok=%d | "
                   "CONV abs=%.3e rel=%.3e nmse=%.2e %s | SCAN abs=%.3e rel=%.3e nmse=%.2e %s\n",
                   d_state, dim, n_head, n_group, n_tok,
                   dc.max_abs, dc.max_rel, dc.nmse, conv_ok ? "PASS" : "FAIL",
                   ds.max_abs, ds.max_rel, ds.nmse, scan_ok ? "PASS" : "FAIL");
            if (!conv_ok || !scan_ok) {
                ++fails;
                printf("      first-bad idx=%d ocl=%.6f cpu=%.6f (conv)\n",
                       dc.idx_abs, oc.conv[dc.idx_abs], cp.conv[dc.idx_abs]);
            }
            ++total;
        }
    }
    printf("[ssm-probe] %d/%d 配置通过（阈值 rel<=1e-2，G-770 起点）\n", total - fails, total);
    return fails == 0 ? 0 : 1;
}
