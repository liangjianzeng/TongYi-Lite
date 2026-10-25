// g1_kda_probe.cpp -- R-017 G1-KDA 变体三阶段数值对拍探针（独立，不依赖 ggml）
//
// 照 g1_layer_probe.cpp 模板：host 生成确定性随机权重/输入（xorshift seed 固定）
// → CPU 参考实现（与 kernels/g1_kda_layer.cl 逐公式对齐 KDA_SPEC.md，双精度累积）
// → OpenCL 跑三阶段 kernel → 逐阶段读回对拍（NMSE 主判据 ≤1e-6）。
//
// 语义锚点 = src/models/bailingmoe3.cpp:406-443（KDA op 链）+
//   bailingmoe3_causal_conv1d(:182-215)。维度（KDA_SPEC §维度）：
//   D=head_dim=128, H=32, D_INNER=4096, N_EMBD=2048, D_CONV=4。
//
// 用法（设备）：
//   PROBE_OCL=/vendor/lib64/libOpenCL.so g1_kda_probe /path/g1_kda_layer.cl   # vendor 腿
//   PROBE_OCL=$B/lib/libOpenCL.so（+Mesa env）g1_kda_probe /path/g1_kda_layer.cl  # Mesa 腿
// 输出：每阶段 NMSE/max_abs/rel + PASS/FAIL，DONE 收尾。

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <vector>
#include <string>
#include <dlfcn.h>
#include <CL/cl.h>

// ---- 维度（与 g1_kda_layer.cl 默认一致）----
#define N_EMBD 2048
#define D      128     // head_dim
#define H      32      // n_head
#define D_CONV 4
#define D_INNER   (D*H)                 // 4096
#define KDA_BLOCKS (N_EMBD/32)          // 64（wq/wk/wv 每行块数）
#define OUT_BLOCKS (D_INNER/32)         // 128（wo 每行块数）
#define CS_SLOT   ((D_CONV-1)*D_INNER)  // 12288
#define SCR_TOTAL (3*D_INNER + H)       // 12320
#define GATE_LB  -8.0f
#define WG1 64
#define WG2 D                            // stage2 一线程一通道
#define WG3 64
#define L2_EPS  1e-6f
#define RMS_EPS 1e-6f

// ---- 阈值（KDA_SPEC 红线：NMSE ≤1e-6；GEMV f32 噪声 ~1e-4 abs 另留信息）----
#define TH_NMSE 1e-6

static uint32_t g_rng = 42;
static uint32_t rnd32() {
    g_rng ^= g_rng << 13; g_rng ^= g_rng >> 17; g_rng ^= g_rng << 5;
    return g_rng;
}
static float rndf() { return ((float)(rnd32() % 20001) - 10000.0f) / 10000.0f; } // [-1,1]

// ---- f16 <-> f32（块 scale 用）----
static float f16tof32(uint16_t h) {
    const uint32_t sign = (h >> 15) & 1, exp = (h >> 10) & 0x1F, man = h & 0x3FF;
    uint32_t bits;
    if (exp == 0)      bits = sign << 31;
    else if (exp == 31) bits = (sign << 31) | 0x7F800000 | (man << 13);
    else {
        const int32_t e = (int32_t)exp - 15 + 127;
        bits = (sign << 31) | ((uint32_t)e << 23) | (man << 13);
    }
    float f; memcpy(&f, &bits, 4); return f;
}
static uint16_t f32tof16(float f) {
    uint32_t x; memcpy(&x, &f, 4);
    const uint32_t sign = (x >> 16) & 0x8000;
    int32_t e = (int32_t)((x >> 23) & 0xFF) - 127 + 15;
    uint32_t m = x & 0x7FFFFF;
    if (e <= 0) return (uint16_t)sign;
    if (e >= 31) return (uint16_t)(sign | 0x7C00);
    return (uint16_t)(sign | ((uint32_t)e << 10) | (m >> 13));
}

// ---- q4_0 块（与 kernel q4_scale/q4_val 同约定：偶数位=低 nibble）----
struct Blk { uint16_t d; uint8_t qs[16]; };
static float blk_scale(const Blk& b) { return f16tof32(b.d); }
static float blk_val(const Blk& b, uint32_t i) {
    const uint8_t by = b.qs[i >> 1];
    return (float)(((i & 1) ? (by >> 4) : (by & 0xF)) - 8);
}
static void blk_gen(Blk& b) {
    b.d = f32tof16(0.01f + (float)(rnd32() % 1000) / 1000.0f * 0.19f);
    for (int i = 0; i < 16; ++i) b.qs[i] = (uint8_t)(rnd32() & 0xF) | ((uint8_t)(rnd32() & 0xF) << 4);
}

// ---- CPU 参考实现（双精度累积，公式序与 kernel/KDA_SPEC 一致）----
static inline float silu_ref(float v) { return v / (1.0f + expf(-v)); }

struct Ref {
    std::vector<float> scratch;        // [SCR_TOTAL] q|k|v|beta
    std::vector<float> conv_state_out; // [3*CS_SLOT] 滚动后
    std::vector<float> state;          // [H*D*D]（stage2 后）
    std::vector<float> gated;          // [D_INNER] stage2 gated RMSNorm 出
    std::vector<float> y;              // [N_EMBD]
};

static void ref_stage1(const std::vector<Blk>& Wq, const std::vector<Blk>& Wk,
                       const std::vector<Blk>& Wv, const std::vector<float>& x,
                       const std::vector<float>& cq, const std::vector<float>& ck,
                       const std::vector<float>& cv, const std::vector<float>& W_beta,
                       const std::vector<float>& conv_state, Ref& r) {
    r.scratch.assign(SCR_TOTAL, 0.0f);
    r.conv_state_out.assign(3 * (size_t)CS_SLOT, 0.0f);
    // 三路 q4_0 GEMV（镜像 kernel：逐块内积 ×d 再累加；行 = 通道 c）
    std::vector<double> mixed(3 * (size_t)D_INNER, 0.0);
    const std::vector<Blk>* Ws[3] = { &Wq, &Wk, &Wv };
    for (int s = 0; s < 3; ++s)
        for (int c = 0; c < D_INNER; ++c) {
            double acc = 0.0;
            const Blk* row = &(*Ws[s])[(size_t)c * KDA_BLOCKS];
            for (int b = 0; b < KDA_BLOCKS; ++b) {
                double t = 0.0;
                for (int i = 0; i < 32; ++i) t += (double)blk_val(row[b], i) * x[b*32 + i];
                acc += t * (double)blk_scale(row[b]);
            }
            mixed[(size_t)s * D_INNER + c] = acc;
        }
    // beta GEMV + sigmoid
    for (int h = 0; h < H; ++h) {
        double acc = 0.0;
        for (int i = 0; i < N_EMBD; ++i) acc += (double)W_beta[(size_t)h * N_EMBD + i] * x[i];
        r.scratch[3 * D_INNER + h] = 1.0f / (1.0f + expf(-(float)acc));
    }
    const float* cwv[3] = { cq.data(), ck.data(), cv.data() };
    std::vector<double> convv(D_INNER);   // 本槽 conv+silu 出（头内偏移 h*D+j）
    for (int s = 0; s < 3; ++s) {
        const float* cw = cwv[s];
        // conv：窗口 = conv_state D_CONV-1 行 + 本 token 混合值（(w,c) 在 c*D_CONV+w）
        for (int c = 0; c < D_INNER; ++c) {
            double acc = 0.0;
            for (int w = 0; w < D_CONV-1; ++w)
                acc += (double)conv_state[(size_t)(s*(D_CONV-1) + w)*D_INNER + c]
                     * (double)cw[(size_t)c*D_CONV + w];
            acc += mixed[(size_t)s * D_INNER + c] * (double)cw[(size_t)c*D_CONV + (D_CONV-1)];
            convv[c] = (double)silu_ref((float)acc);
        }
        if (s < 2) {
            // q/k 逐头 l2norm（因子 = D/sqrt(Σx²+eps)，KDA_SPEC 闭式）
            for (int h = 0; h < H; ++h) {
                double ss = 0.0;
                for (int j = 0; j < D; ++j) ss += convv[h*D + j] * convv[h*D + j];
                const float f = 1.0f / sqrtf((float)ss + L2_EPS);
                for (int j = 0; j < D; ++j)
                    r.scratch[(size_t)s * D_INNER + (size_t)h * D + j] = (float)convv[h*D + j] * f;
            }
        } else {
            for (int c = 0; c < D_INNER; ++c)
                r.scratch[2 * D_INNER + c] = (float)convv[c];
        }
        // conv_state 原地滚动（out_w = in_{w+1}，末行 = 本 token 混合值）
        for (int c = 0; c < D_INNER; ++c) {
            float* co = r.conv_state_out.data() + (size_t)s * CS_SLOT + c;
            for (int w = 0; w < D_CONV-2; ++w)
                co[(size_t)w * D_INNER] = conv_state[(size_t)(s*(D_CONV-1) + w + 1)*D_INNER + c];
            co[(size_t)(D_CONV-2) * D_INNER] = (float)mixed[(size_t)s * D_INNER + c];
        }
    }
}

static void ref_stage2(const Ref& r1, const std::vector<float>& x,
                       const std::vector<float>& f_a, const std::vector<float>& g_a,
                       const std::vector<float>& dt_b, const std::vector<float>& ssm_a,
                       const std::vector<float>& o_norm,
                       const std::vector<float>& state_in, Ref& r) {
    r.gated.assign(D_INNER, 0.0f);
    r.state = state_in;  // 拷贝后原地 AR
    const float* sc = r1.scratch.data();
    const float* q = sc;                       // [D_INNER]
    const float* k = sc + D_INNER;             // [D_INNER]
    const float* v = sc + 2 * D_INNER;         // [D_INNER]
    const float* beta = sc + 3 * D_INNER;      // [H]
    float* Sbase = r.state.data();             // S(i,j) = S[j*D+i]，头 h 基址 h*D*D
    const float qs = 1.0f / sqrtf((float)D);
    for (int h = 0; h < H; ++h) {
        const float ah = ssm_a[h], b = beta[h];
        float* S = Sbase + (size_t)h * D * D;
        // gate / out-gate 逐通道自算（每通道一个 N_EMBD 点积）
        std::vector<double> ge(D), og(D);
        for (int i = 0; i < D; ++i) {
            const size_t row = (size_t)(h*D + i) * N_EMBD;
            double gpre = (double)dt_b[h*D + i], opre = 0.0;
            for (int t = 0; t < N_EMBD; ++t) {
                gpre += (double)f_a[row + t] * x[t];
                opre += (double)g_a[row + t] * x[t];
            }
            ge[i] = exp((double)GATE_LB / (1.0 + exp(-(gpre * (double)ah))));
            og[i] = 1.0 / (1.0 + exp(-opre));
        }
        // sk（衰减后 S 口径）→ d → 衰减+外积合并单趟 → o（q 预乘 1/sqrt(D)）
        std::vector<double> o(D, 0.0);
        for (int j = 0; j < D; ++j) {
            double sk = 0.0;
            for (int i = 0; i < D; ++i)
                sk += (double)S[(size_t)j*D + i] * ge[i] * (double)k[h*D + i];
            const double dj = ((double)v[h*D + j] - sk) * (double)b;
            double acc = 0.0;
            for (int i = 0; i < D; ++i) {
                const double sn = (double)S[(size_t)j*D + i] * ge[i]
                                + (double)k[h*D + i] * dj;
                S[(size_t)j*D + i] = (float)sn;
                acc += sn * (double)q[h*D + i];
            }
            o[j] = acc * (double)qs;
        }
        // gated RMSNorm（本头内）
        double ss = 0.0;
        for (int j = 0; j < D; ++j) ss += o[j] * o[j];
        const float f = 1.0f / sqrtf((float)(ss / D) + RMS_EPS);
        for (int j = 0; j < D; ++j)
            r.gated[(size_t)h*D + j] = (float)o[j] * f * o_norm[j] * (float)og[j];
    }
}

static void ref_stage3(const Ref& r2, const std::vector<Blk>& W_out, Ref& r) {
    r.y.assign(N_EMBD, 0.0f);
    for (int col = 0; col < N_EMBD; ++col) {
        double acc = 0.0;
        const Blk* row = &W_out[(size_t)col * OUT_BLOCKS];
        for (int b = 0; b < OUT_BLOCKS; ++b) {
            double s = 0.0;
            for (int t = 0; t < 32; ++t) s += (double)blk_val(row[b], t) * r2.gated[b*32 + t];
            acc += s * (double)blk_scale(row[b]);
        }
        r.y[col] = (float)acc;
    }
}

// ---- 误差统计（NMSE 主判据，max_abs/rel 留信息）----
struct Err { double max_abs = 0, max_rel = 0, nmse = 0, se = 0, ref_ss = 0; size_t worst = 0; };
static Err cmp(const float* gpu, const float* ref, size_t n) {
    Err e;
    for (size_t i = 0; i < n; ++i) {
        const double a = gpu[i], b = ref[i], d = fabs(a - b);
        e.se += d * d; e.ref_ss += b * b;
        if (d > e.max_abs) { e.max_abs = d; e.worst = i; }
        const double den = (b > 1e-3 || b < -1e-3) ? fabs(b) : 1e-3;
        const double rel = d / den;
        if (rel > e.max_rel) e.max_rel = rel;
    }
    e.nmse = e.ref_ss > 0 ? e.se / e.ref_ss : e.se;
    return e;
}

// ---- OpenCL 加载（dlopen，ICD 兼容）----
#define SYM(rt, name, ...) typedef rt (*fn_##name)(__VA_ARGS__); static fn_##name p_##name;
SYM(cl_int, clGetPlatformIDs, cl_uint, cl_platform_id*, cl_uint*)
SYM(cl_int, clGetDeviceIDs, cl_platform_id, cl_device_type, cl_uint, cl_device_id*, cl_uint*)
SYM(cl_context, clCreateContext, const cl_context_properties*, cl_uint, const cl_device_id*, void*, void*, cl_int*)
SYM(cl_command_queue, clCreateCommandQueueWithProperties, cl_context, cl_device_id, const cl_queue_properties*, cl_int*)
SYM(cl_mem, clCreateBuffer, cl_context, cl_mem_flags, size_t, void*, cl_int*)
SYM(cl_program, clCreateProgramWithSource, cl_context, cl_uint, const char**, const size_t*, cl_int*)
SYM(cl_int, clBuildProgram, cl_program, cl_uint, const cl_device_id*, const char*, void*, void*)
SYM(cl_kernel, clCreateKernel, cl_program, const char*, cl_int*)
SYM(cl_int, clSetKernelArg, cl_kernel, cl_uint, size_t, const void*)
SYM(cl_int, clEnqueueNDRangeKernel, cl_command_queue, cl_kernel, cl_uint, const size_t*, const size_t*, const size_t*, cl_uint, const cl_event*, cl_event*)
SYM(cl_int, clEnqueueWriteBuffer, cl_command_queue, cl_mem, cl_bool, size_t, size_t, const void*, cl_uint, const cl_event*, cl_event*)
SYM(cl_int, clEnqueueReadBuffer, cl_command_queue, cl_mem, cl_bool, size_t, size_t, void*, cl_uint, const cl_event*, cl_event*)
SYM(cl_int, clFinish, cl_command_queue)
SYM(cl_int, clGetProgramBuildInfo, cl_program, cl_device_id, cl_program_build_info, size_t, void*, size_t*)
SYM(cl_int, clGetDeviceInfo, cl_device_id, cl_device_info, size_t, void*, size_t*)
SYM(cl_int, clGetPlatformInfo, cl_platform_id, cl_platform_info, size_t, void*, size_t*)

static void* g_ocl = nullptr;
#define LOAD(name) do { p_##name = (fn_##name)dlsym(g_ocl, #name); if (!p_##name) { \
    fprintf(stderr, "FATAL: dlsym %s\n", #name); exit(4); } } while (0)

static char* devinfo(cl_device_id d, cl_device_info info) {
    static char buf[512]; memset(buf, 0, sizeof(buf));
    p_clGetDeviceInfo(d, info, sizeof(buf) - 1, buf, nullptr); return buf;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: %s <g1_kda_layer.cl>\n", argv[0]); return 3; }
    const char* lib = getenv("PROBE_OCL"); if (!lib || !*lib) lib = "libOpenCL.so";
    g_ocl = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!g_ocl) { fprintf(stderr, "FATAL: dlopen(%s)=%s\n", lib, dlerror()); return 4; }
    LOAD(clGetPlatformIDs); LOAD(clGetDeviceIDs); LOAD(clCreateContext);
    LOAD(clCreateCommandQueueWithProperties); LOAD(clCreateBuffer);
    LOAD(clCreateProgramWithSource); LOAD(clBuildProgram); LOAD(clCreateKernel);
    LOAD(clSetKernelArg); LOAD(clEnqueueNDRangeKernel); LOAD(clEnqueueWriteBuffer);
    LOAD(clEnqueueReadBuffer); LOAD(clFinish); LOAD(clGetProgramBuildInfo);
    LOAD(clGetDeviceInfo); LOAD(clGetPlatformInfo);

    cl_platform_id pl[8]; cl_uint npl = 0;
    if (p_clGetPlatformIDs(8, pl, &npl) != CL_SUCCESS || !npl) { fprintf(stderr, "no platform\n"); return 2; }
    cl_device_id dev[8]; cl_uint nd = 0;
    for (cl_uint i = 0; i < npl && nd == 0; ++i) p_clGetDeviceIDs(pl[i], CL_DEVICE_TYPE_ALL, 8, dev, &nd);
    if (!nd) { fprintf(stderr, "no device\n"); return 2; }
    const char* want = getenv("PROBE_DEV");
    cl_device_id d = dev[0];
    if (want && *want) {
        for (cl_uint i = 0; i < nd; ++i)
            if (strstr(devinfo(dev[i], CL_DEVICE_NAME), want)) { d = dev[i]; break; }
    }
    char plat[256] = {0};
    p_clGetPlatformInfo(pl[0], CL_PLATFORM_NAME, sizeof(plat) - 1, plat, nullptr);
    printf("libOpenCL=%s\nplatform  =%s\ndevice    =%s\ndriver    =%s\n",
           lib, plat, devinfo(d, CL_DEVICE_NAME), devinfo(d, CL_DRIVER_VERSION));

    // 内核源
    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "FATAL: 打不开 %s\n", argv[1]); return 3; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    std::string src(sz + 1, 0);
    if (fread(&src[0], 1, sz, f) != (size_t)sz) return 3; fclose(f);

    cl_int e = CL_SUCCESS;
    printf("[step] ctx\n");
    cl_context cx = p_clCreateContext(nullptr, 1, &d, nullptr, nullptr, &e);
    if (!cx || e != CL_SUCCESS) { fprintf(stderr, "context err=%d\n", e); return 2; }
    printf("[step] queue\n");
    cl_command_queue q_ = p_clCreateCommandQueueWithProperties(cx, d, nullptr, &e);
    if (!q_ || e != CL_SUCCESS) { fprintf(stderr, "queue err=%d\n", e); return 2; }
    printf("[step] program\n");
    const char* sptr = src.c_str(); const size_t slen = (size_t)sz;
    cl_program pr = p_clCreateProgramWithSource(cx, 1, &sptr, &slen, &e);
    printf("[step] build\n");
    e = p_clBuildProgram(pr, 1, &d, "", nullptr, nullptr);
    if (e != CL_SUCCESS) {
        size_t ln = 0; p_clGetProgramBuildInfo(pr, d, CL_PROGRAM_BUILD_LOG, 0, nullptr, &ln);
        std::string log(ln + 1, 0);
        if (ln > 1) p_clGetProgramBuildInfo(pr, d, CL_PROGRAM_BUILD_LOG, ln, &log[0], nullptr);
        fprintf(stderr, "BUILD FAIL err=%d\n%s\n", e, log.c_str());
        return 1;
    }
    cl_kernel k1 = p_clCreateKernel(pr, "g1_kda_stage1_in", &e);
    cl_kernel k2 = p_clCreateKernel(pr, "g1_kda_stage2_core", &e);
    cl_kernel k3 = p_clCreateKernel(pr, "g1_kda_stage3_out", &e);
    if (!k1 || !k2 || !k3) { fprintf(stderr, "create kernel fail (%p %p %p) e=%d\n", k1, k2, k3, e); return 1; }
    printf("kernels: 3 created OK\n");
    printf("[step] 数据生成\n");

    // ---- 数据生成（确定性）----
    g_rng = 42;
    std::vector<Blk> Wq((size_t)D_INNER * KDA_BLOCKS), Wk((size_t)D_INNER * KDA_BLOCKS),
        Wv((size_t)D_INNER * KDA_BLOCKS), W_out((size_t)N_EMBD * OUT_BLOCKS);
    for (auto& b : Wq)    blk_gen(b);
    for (auto& b : Wk)    blk_gen(b);
    for (auto& b : Wv)    blk_gen(b);
    for (auto& b : W_out) blk_gen(b);
    std::vector<float> x(N_EMBD), cq((size_t)D_CONV * D_INNER), ck((size_t)D_CONV * D_INNER),
        cv((size_t)D_CONV * D_INNER), W_beta((size_t)H * N_EMBD),
        conv_state(3 * (size_t)CS_SLOT), f_a((size_t)D_INNER * N_EMBD),
        g_a((size_t)D_INNER * N_EMBD), dt_b(D_INNER), ssm_a(H), o_norm(D),
        state_in((size_t)H * D * D);
    for (auto& v : x) v = rndf() * 0.5f;
    for (auto& v : cq) v = rndf() * 0.5f;
    for (auto& v : ck) v = rndf() * 0.5f;
    for (auto& v : cv) v = rndf() * 0.5f;
    for (auto& v : W_beta) v = rndf() * 0.5f;
    for (auto& v : conv_state) v = rndf() * 0.5f;
    for (auto& v : f_a) v = rndf() * 0.5f;
    for (auto& v : g_a) v = rndf() * 0.5f;
    for (auto& v : dt_b) v = rndf() * 0.1f;
    for (auto& v : ssm_a) v = -(0.5f + (float)(rnd32() % 1000) / 1000.0f);   // [1.5, 0.5] 负
    for (auto& v : o_norm) v = 0.5f + rndf() * 0.5f;
    for (auto& v : state_in) v = rndf() * 0.1f;

    printf("[step] CPU 参考\n");
    Ref r1, r2, r3;
    ref_stage1(Wq, Wk, Wv, x, cq, ck, cv, W_beta, conv_state, r1);
    ref_stage2(r1, x, f_a, g_a, dt_b, ssm_a, o_norm, state_in, r2);
    ref_stage3(r2, W_out, r3);
    printf("CPU 参考完成\n");

    // ---- 设备缓冲 ----
    printf("[step] 设备缓冲\n");
    cl_mem mWq   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, Wq.size()*18, Wq.data(), &e);
    cl_mem mWk   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, Wk.size()*18, Wk.data(), &e);
    cl_mem mWv   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, Wv.size()*18, Wv.data(), &e);
    cl_mem mx    = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, x.size()*4, x.data(), &e);
    cl_mem mcq   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, cq.size()*4, cq.data(), &e);
    cl_mem mck   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, ck.size()*4, ck.data(), &e);
    cl_mem mcv   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, cv.size()*4, cv.data(), &e);
    cl_mem mbw   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, W_beta.size()*4, W_beta.data(), &e);
    cl_mem mcst  = p_clCreateBuffer(cx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, conv_state.size()*4, conv_state.data(), &e);
    cl_mem mscr  = p_clCreateBuffer(cx, CL_MEM_READ_WRITE, SCR_TOTAL*4, nullptr, &e);
    cl_mem mfa   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, f_a.size()*4, f_a.data(), &e);
    cl_mem mga   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, g_a.size()*4, g_a.data(), &e);
    cl_mem mdtb  = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, dt_b.size()*4, dt_b.data(), &e);
    cl_mem ma    = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, ssm_a.size()*4, ssm_a.data(), &e);
    cl_mem mon   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, o_norm.size()*4, o_norm.data(), &e);
    cl_mem mstate= p_clCreateBuffer(cx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, state_in.size()*4, state_in.data(), &e);
    cl_mem mgated= p_clCreateBuffer(cx, CL_MEM_READ_WRITE, D_INNER*4, nullptr, &e);
    cl_mem mW_out= p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, W_out.size()*18, W_out.data(), &e);
    cl_mem my    = p_clCreateBuffer(cx, CL_MEM_WRITE_ONLY, N_EMBD*4, nullptr, &e);
    if (e != CL_SUCCESS || !mscr || !mcst) { fprintf(stderr, "buffer err=%d\n", e); return 2; }

    // ---- stage1 ----
    cl_uint a = 0;
    cl_ulong z = 0;
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mWq);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mWk);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mWv);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mx);    p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mcq);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mck);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mcv);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mbw);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mcst);  p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mscr);  p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, (N_EMBD + 2*D + 1)*4, nullptr);
    { const size_t g = 3*H*WG1, l = WG1;
      e = p_clEnqueueNDRangeKernel(q_, k1, 1, nullptr, &g, &l, 0, nullptr, nullptr); }
    if (e != CL_SUCCESS) { fprintf(stderr, "stage1 NDRange err=%d\n", e); return 2; }
    p_clFinish(q_);
    std::vector<float> gpu_scr(SCR_TOTAL), gpu_cs(3 * (size_t)CS_SLOT);
    p_clEnqueueReadBuffer(q_, mscr, CL_TRUE, 0, SCR_TOTAL*4, gpu_scr.data(), 0, nullptr, nullptr);
    p_clEnqueueReadBuffer(q_, mcst, CL_TRUE, 0, 3*(size_t)CS_SLOT*4, gpu_cs.data(), 0, nullptr, nullptr);
    { Err e1 = cmp(gpu_scr.data(), r1.scratch.data(), SCR_TOTAL);
      Err e2 = cmp(gpu_cs.data(), r1.conv_state_out.data(), 3 * (size_t)CS_SLOT);
      printf("[stage1] scratch nmse=%.3e max_abs=%.3e max_rel=%.3e (worst %zu) | conv_state nmse=%.3e max_abs=%.3e\n",
             e1.nmse, e1.max_abs, e1.max_rel, e1.worst, e2.nmse, e2.max_abs);
      printf("[stage1] %s\n", (e1.nmse <= TH_NMSE && e2.nmse <= TH_NMSE) ? "PASS" : "FAIL"); }

    // ---- stage2 ----
    a = 0;
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mscr);   p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mx);     p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mfa);    p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mga);    p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mdtb);   p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &ma);     p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mon);    p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mstate); p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mgated); p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, (3*D + 1)*4, nullptr);
    { const size_t g = H*WG2, l = WG2;
      e = p_clEnqueueNDRangeKernel(q_, k2, 1, nullptr, &g, &l, 0, nullptr, nullptr); }
    if (e != CL_SUCCESS) { fprintf(stderr, "stage2 NDRange err=%d\n", e); return 2; }
    p_clFinish(q_);
    std::vector<float> gpu_gated(D_INNER), gpu_state(state_in.size());
    p_clEnqueueReadBuffer(q_, mgated, CL_TRUE, 0, D_INNER*4, gpu_gated.data(), 0, nullptr, nullptr);
    p_clEnqueueReadBuffer(q_, mstate, CL_TRUE, 0, state_in.size()*4, gpu_state.data(), 0, nullptr, nullptr);
    { Err e1 = cmp(gpu_gated.data(), r2.gated.data(), D_INNER);
      Err e2 = cmp(gpu_state.data(), r2.state.data(), state_in.size());
      printf("[stage2] gated nmse=%.3e max_abs=%.3e | state nmse=%.3e max_abs=%.3e max_rel=%.3e (worst %zu)\n",
             e1.nmse, e1.max_abs, e2.nmse, e2.max_abs, e2.max_rel, e2.worst);
      printf("[stage2] %s\n", (e1.nmse <= TH_NMSE && e2.nmse <= TH_NMSE) ? "PASS" : "FAIL"); }

    // ---- stage3 ----
    a = 0;
    p_clSetKernelArg(k3, a++, sizeof(cl_mem), &mgated); p_clSetKernelArg(k3, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k3, a++, sizeof(cl_mem), &mW_out); p_clSetKernelArg(k3, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k3, a++, sizeof(cl_mem), &my);     p_clSetKernelArg(k3, a++, sizeof(cl_ulong), &z);
    { const size_t g = N_EMBD, l = WG3;   // 同 g1_layer_probe 模板（kernel 侧 col 越界守卫）
      e = p_clEnqueueNDRangeKernel(q_, k3, 1, nullptr, &g, &l, 0, nullptr, nullptr); }
    if (e != CL_SUCCESS) { fprintf(stderr, "stage3 NDRange err=%d\n", e); return 2; }
    p_clFinish(q_);
    std::vector<float> gpu_y(N_EMBD);
    p_clEnqueueReadBuffer(q_, my, CL_TRUE, 0, N_EMBD*4, gpu_y.data(), 0, nullptr, nullptr);
    { Err e1 = cmp(gpu_y.data(), r3.y.data(), N_EMBD);
      printf("[stage3] y nmse=%.3e max_abs=%.3e max_rel=%.3e (worst %zu)\n", e1.nmse, e1.max_abs, e1.max_rel, e1.worst);
      printf("[stage3] %s\n", e1.nmse <= TH_NMSE ? "PASS" : "FAIL"); }

    printf("DONE\n");
    return 0;
}
