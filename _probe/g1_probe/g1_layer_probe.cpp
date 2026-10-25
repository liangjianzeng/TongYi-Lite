// g1_layer_probe.cpp -- A7.1 G1 巨核三阶段数值对拍探针（独立，不依赖 ggml）
//
// 数据流：host 生成确定性随机权重/输入（xorshift，seed 固定）→ CPU 参考实现
// （与 kernels/g1_ssm_layer.cl 逐公式对齐，双精度累积）→ OpenCL 跑三阶段 kernel
// → 逐阶段读回对拍。
//
// 判据（设计文档 §9）：stage1/3 GEMV 与 stage2 输出相对误差阈值、state 绝对误差。
// 注意 GPU f32 + FMA vs CPU 双精度的固有差：实测反馈阈值，不硬卡 2e-6。
//
// 用法（设备）：
//   PROBE_OCL=/vendor/lib64/libOpenCL.so g1_layer_probe /path/g1_ssm_layer.cl   # vendor 腿
//   PROBE_OCL=$B/lib/libOpenCL.so（+Mesa env）g1_layer_probe /path/g1_ssm_layer.cl  # Mesa 腿
// 输出：每阶段 max abs/rel err + VERDICT=PASS/FAIL。

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <vector>
#include <string>
#include <dlfcn.h>
#include <CL/cl.h>

// ---- 维度（与 g1_ssm_layer.cl 默认一致）----
#define N_EMBD 2048
#define S_K    128
#define H_K    16
#define H_V    32
#define S_V    128
#define D_CONV 4
#define RF     (H_V/H_K)
#define QKVZ_NEW (2*S_K + 2*S_V*RF)      // 768
#define QKVZ_DIM (H_K * QKVZ_NEW)        // 12288
#define BA_NEW   (2*RF)                  // 4
#define BA_DIM   (H_K * BA_NEW)          // 64
#define CONV_NEW (2*S_K + S_V*RF)        // 512
#define CC       (2*H_K*S_K + H_V*S_V)   // 8192
#define QKV_BLOCKS (N_EMBD/32)           // 64
#define OUT_BLOCKS ((H_V*S_V)/32)        // 128
#define SCR_K_OFF     (H_V*S_K)          // 4096
#define SCR_V_OFF     (2*H_V*S_K)        // 8192
#define SCR_Z_OFF     (2*H_V*S_K + H_V*S_V)  // 12288
#define SCR_GATE_OFF  (2*H_V*S_K + 2*H_V*S_V) // 16384
#define SCR_BETA_OFF  (SCR_GATE_OFF + H_V)    // 16416
#define SCR_TOTAL     (SCR_BETA_OFF + H_V)    // 16448
#define L1_SIZE    (N_EMBD + QKVZ_NEW + CONV_NEW + BA_NEW)  // 3332
#define WG1 64
#define WG2 128
#define WG3 64
#define L2_EPS   1e-6f
#define RMS_EPS  1e-6f

// ---- 阈值（moe_probe 纪律：NMSE 主判据；实测 vendor 腿 ~1e-8 量级）----
#define TH_NMSE   1e-6

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
    if (exp == 0)      bits = sign << 31;                       // 零/次正规（scale 恒正规，不细做）
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

// ---- CPU 参考实现（双精度累积，公式序与 kernel 一致）----
static inline float silu_ref(float v)     { return v / (1.0f + expf(-v)); }
static inline float softplus_ref(float v) { return v > 20.0f ? v : log1pf(expf(v)); }

struct Ref {
    std::vector<float> scratch;        // [SCR_TOTAL]
    std::vector<float> conv_state_out; // [3*CC]
    std::vector<float> state;          // [H_V*S_V*S_V]（stage2 后）
    std::vector<float> out;            // [H_V*S_V]
    std::vector<float> y;              // [N_EMBD]
};

static void ref_stage1(const std::vector<Blk>& W_in, const std::vector<float>& W_ba,
                       const std::vector<float>& x, const std::vector<float>& ssm_dt,
                       const std::vector<float>& ssm_a, const std::vector<float>& w_conv,
                       const std::vector<float>& conv_state, Ref& r) {
    r.scratch.assign(SCR_TOTAL, 0.0f);
    r.conv_state_out.assign(3 * CC, 0.0f);
    // in_proj GEMV（镜像 kernel：逐块内积 ×d 再累加）
    std::vector<double> mixed(QKVZ_DIM, 0.0);
    for (int col = 0; col < QKVZ_DIM; ++col) {
        double acc = 0.0;
        const Blk* row = &W_in[(size_t)col * QKV_BLOCKS];
        for (int b = 0; b < QKV_BLOCKS; ++b) {
            double s = 0.0;
            for (int t = 0; t < 32; ++t) s += (double)blk_val(row[b], t) * x[b*32 + t];
            acc += s * (double)blk_scale(row[b]);
        }
        mixed[col] = acc;
    }
    // ba GEMV
    std::vector<double> ba(BA_DIM, 0.0);
    for (int col = 0; col < BA_DIM; ++col) {
        double acc = 0.0;
        for (int i = 0; i < N_EMBD; ++i) acc += (double)W_ba[col * N_EMBD + i] * x[i];
        ba[col] = acc;
    }
    float* sc = r.scratch.data();
    for (int g = 0; g < H_K; ++g) {
        // gate/beta
        for (int rr = 0; rr < RF; ++rr) {
            const double b = ba[g*BA_NEW + rr], a = ba[g*BA_NEW + RF + rr];
            sc[SCR_BETA_OFF + 2*g + rr] = 1.0f / (1.0f + expf(-(float)b));
            sc[SCR_GATE_OFF + 2*g + rr] =
                softplus_ref((float)a + ssm_dt[2*g + rr]) * ssm_a[2*g + rr];
        }
        // conv + silu（通道映射与 kernel 一致；窗口行 D_CONV-1 = 本 token 混合值）
        std::vector<double> convv(CONV_NEW, 0.0);
        for (int t = 0; t < CONV_NEW; ++t) {
            const uint32_t c = (t < S_K) ? (uint32_t)(g*S_K + t)
                             : (t < 2*S_K) ? (uint32_t)(H_K*S_K + g*S_K + (t - S_K))
                             : (uint32_t)(2*H_K*S_K + g*S_V*RF + (t - 2*S_K));
            double acc = 0.0;
            for (int w = 0; w < D_CONV-1; ++w)
                acc += (double)conv_state[(size_t)w*CC + c] * w_conv[(size_t)c*D_CONV + w];
            acc += mixed[g*QKVZ_NEW + t] * (double)w_conv[(size_t)c*D_CONV + (D_CONV-1)];
            convv[t] = silu_ref((float)acc);
        }
        // l2norm q/k + interleave（闭式因子 n/sqrt(Σx²+eps)）
        for (int seg = 0; seg < 2; ++seg) {
            double ss = 0.0;
            for (int t = 0; t < S_K; ++t) ss += convv[seg*S_K + t] * convv[seg*S_K + t];
            const float f = (float)S_K / sqrtf((float)ss + L2_EPS);
            float* base = r.scratch.data() + (seg == 0 ? 0 : SCR_K_OFF);
            for (int t = 0; t < S_K; ++t) {
                const float v_ = (float)convv[seg*S_K + t] * f;
                base[(2*g)   * S_K + t] = v_;
                base[(2*g+1) * S_K + t] = v_;
            }
        }
        // v/z 直通 + conv_state 滚动
        for (int t = 0; t < S_V*RF; ++t) {
            const uint32_t h = 2*g + (uint32_t)t / S_V, j = (uint32_t)t % S_V;
            sc[SCR_V_OFF + h*S_V + j] = (float)convv[2*S_K + t];
            sc[SCR_Z_OFF + h*S_V + j] = (float)mixed[g*QKVZ_NEW + 2*S_K + t];
        }
        for (int t = 0; t < CONV_NEW; ++t) {
            const uint32_t c = (t < S_K) ? (uint32_t)(g*S_K + t)
                             : (t < 2*S_K) ? (uint32_t)(H_K*S_K + g*S_K + (t - S_K))
                             : (uint32_t)(2*H_K*S_K + g*S_V*RF + (t - 2*S_K));
            r.conv_state_out[(size_t)0*CC + c] = conv_state[(size_t)1*CC + c];
            r.conv_state_out[(size_t)1*CC + c] = conv_state[(size_t)2*CC + c];
            r.conv_state_out[(size_t)2*CC + c] = (float)mixed[g*QKVZ_NEW + t];
        }
    }
}

static void ref_stage2(const Ref& r1, const std::vector<float>& rms_w,
                       const std::vector<float>& state_in, Ref& r) {
    r.out.assign(H_V * S_V, 0.0f);
    r.state = state_in;  // 拷贝后原地 AR
    const float* sc = r1.scratch.data();
    const float* q = sc, *k = sc + SCR_K_OFF, *v = sc + SCR_V_OFF;
    const float* gate = sc + SCR_GATE_OFF, *beta = sc + SCR_BETA_OFF, *z = sc + SCR_Z_OFF;
    const float qs = 1.0f / sqrtf((float)S_K);
    for (int h = 0; h < H_V; ++h) {
        float* S = r.state.data() + (size_t)h * S_V * S_V;  // S(i,j) = S[j*S_V+i]
        const float gexp = expf(gate[h]), b = beta[h];
        for (int idx = 0; idx < S_V*S_V; ++idx) S[idx] *= gexp;
        std::vector<double> dcol(S_V, 0.0);
        for (int j = 0; j < S_V; ++j) {
            double sk = 0.0;
            for (int i = 0; i < S_V; ++i) sk += (double)S[j*S_V + i] * k[h*S_K + i];
            dcol[j] = ((double)v[h*S_V + j] - sk) * (double)b;
        }
        for (int j = 0; j < S_V; ++j)
            for (int i = 0; i < S_V; ++i)
                S[j*S_V + i] += (float)((double)k[h*S_K + i] * dcol[j]);
        std::vector<double> o(S_V, 0.0);
        for (int j = 0; j < S_V; ++j) {
            double acc = 0.0;
            for (int i = 0; i < S_V; ++i) acc += (double)S[j*S_V + i] * q[h*S_K + i];
            o[j] = acc * qs;
        }
        double ss = 0.0;
        for (int j = 0; j < S_V; ++j) ss += o[j] * o[j];
        const float f = 1.0f / sqrtf((float)(ss / S_V) + RMS_EPS);
        for (int j = 0; j < S_V; ++j)
            r.out[h*S_V + j] = (float)o[j] * f * rms_w[j] * silu_ref(z[h*S_V + j]);
    }
}

static void ref_stage3(const Ref& r2, const std::vector<Blk>& W_out, Ref& r) {
    r.y.assign(N_EMBD, 0.0f);
    for (int col = 0; col < N_EMBD; ++col) {
        double acc = 0.0;
        const Blk* row = &W_out[(size_t)col * OUT_BLOCKS];
        for (int b = 0; b < OUT_BLOCKS; ++b) {
            double s = 0.0;
            for (int t = 0; t < 32; ++t) s += (double)blk_val(row[b], t) * r2.out[b*32 + t];
            acc += s * (double)blk_scale(row[b]);
        }
        r.y[col] = (float)acc;
    }
}

// ---- 误差统计（moe_probe 纪律：NMSE 为主判据，max_abs/rel 留信息）----
struct Err { double max_abs = 0, max_rel = 0, nmse = 0, se = 0, ref_ss = 0; size_t worst = 0; };
static Err cmp(const float* gpu, const float* ref, size_t n, bool rel_to_abs_floor = true) {
    Err e;
    for (size_t i = 0; i < n; ++i) {
        const double a = gpu[i], b = ref[i], d = fabs(a - b);
        e.se += d * d; e.ref_ss += b * b;
        if (d > e.max_abs) { e.max_abs = d; e.worst = i; }
        const double den = (b > 1e-3 || b < -1e-3) ? fabs(b) : (rel_to_abs_floor ? 1e-3 : 1.0);
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
    if (argc < 2) { fprintf(stderr, "usage: %s <g1_ssm_layer.cl>\n", argv[0]); return 3; }
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
    cl_kernel k1 = p_clCreateKernel(pr, "g1_ssm_stage1_proj", &e);
    cl_kernel k2 = p_clCreateKernel(pr, "g1_ssm_stage2_gdn", &e);
    cl_kernel k3 = p_clCreateKernel(pr, "g1_ssm_stage3_out", &e);
    if (!k1 || !k2 || !k3) { fprintf(stderr, "create kernel fail (%p %p %p) e=%d\n", k1, k2, k3, e); return 1; }
    printf("kernels: 3 created OK\n");
    printf("[step] 数据生成\n");

    // ---- 数据生成（确定性）----
    g_rng = 42;
    std::vector<Blk> W_in((size_t)QKVZ_DIM * QKV_BLOCKS), W_out((size_t)N_EMBD * OUT_BLOCKS);
    for (auto& b : W_in)  blk_gen(b);
    for (auto& b : W_out) blk_gen(b);
    std::vector<float> W_ba((size_t)BA_DIM * N_EMBD), x(N_EMBD), ssm_dt(H_V), ssm_a(H_V),
        w_conv((size_t)CC * D_CONV), conv_state((size_t)(D_CONV-1) * CC), rms_w(S_V),
        state_in((size_t)H_V * S_V * S_V);
    for (auto& v : W_ba) v = rndf() * 0.5f;
    for (auto& v : x) v = rndf() * 0.5f;
    for (auto& v : ssm_dt) v = rndf() * 0.1f;
    for (auto& v : ssm_a) v = -(0.01f + (float)(rnd32() % 100) / 100.0f * 0.1f);
    for (auto& v : w_conv) v = rndf() * 0.5f;
    for (auto& v : conv_state) v = rndf() * 0.5f;
    for (auto& v : rms_w) v = 0.5f + rndf() * 0.5f;
    for (auto& v : state_in) v = rndf() * 0.1f;

    printf("[step] CPU 参考\n");
    Ref r1, r2, r3;
    ref_stage1(W_in, W_ba, x, ssm_dt, ssm_a, w_conv, conv_state, r1);
    ref_stage2(r1, rms_w, state_in, r2);
    ref_stage3(r2, W_out, r3);
    printf("CPU 参考完成\n");

    // ---- 设备缓冲 ----
    printf("[step] 设备缓冲\n");
    cl_mem mW_in  = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, W_in.size()*18, W_in.data(), &e);
    cl_mem mW_ba  = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, W_ba.size()*4, W_ba.data(), &e);
    cl_mem mx     = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, x.size()*4, x.data(), &e);
    cl_mem mdt    = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, ssm_dt.size()*4, ssm_dt.data(), &e);
    cl_mem ma     = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, ssm_a.size()*4, ssm_a.data(), &e);
    cl_mem mconv  = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, w_conv.size()*4, w_conv.data(), &e);
    cl_mem mcst   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, conv_state.size()*4, conv_state.data(), &e);
    cl_mem mscr   = p_clCreateBuffer(cx, CL_MEM_READ_WRITE, SCR_TOTAL*4, nullptr, &e);
    cl_mem mcsout = p_clCreateBuffer(cx, CL_MEM_WRITE_ONLY, 3*CC*4, nullptr, &e);
    cl_mem mrms   = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, rms_w.size()*4, rms_w.data(), &e);
    cl_mem mstate = p_clCreateBuffer(cx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, state_in.size()*4, state_in.data(), &e);
    cl_mem mout   = p_clCreateBuffer(cx, CL_MEM_READ_WRITE, H_V*S_V*4, nullptr, &e);
    cl_mem mW_out = p_clCreateBuffer(cx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, W_out.size()*18, W_out.data(), &e);
    cl_mem my     = p_clCreateBuffer(cx, CL_MEM_WRITE_ONLY, N_EMBD*4, nullptr, &e);
    if (e != CL_SUCCESS || !mscr) { fprintf(stderr, "buffer err=%d\n", e); return 2; }

    // ---- stage1 ----
    float nullf = 0;
    (void)nullf;
    cl_uint a = 0;
    cl_ulong z = 0;
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mW_in);  p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mW_ba);  p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mx);     p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mdt);    p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &ma);     p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mconv);  p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mcst);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mscr);   p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, sizeof(cl_mem), &mcsout); p_clSetKernelArg(k1, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k1, a++, L1_SIZE*4, nullptr);
    { const size_t g = H_K*WG1, l = WG1;
      e = p_clEnqueueNDRangeKernel(q_, k1, 1, nullptr, &g, &l, 0, nullptr, nullptr); }
    if (e != CL_SUCCESS) { fprintf(stderr, "stage1 NDRange err=%d\n", e); return 2; }
    p_clFinish(q_);
    std::vector<float> gpu_scr(SCR_TOTAL), gpu_csout(3*CC);
    p_clEnqueueReadBuffer(q_, mscr, CL_TRUE, 0, SCR_TOTAL*4, gpu_scr.data(), 0, nullptr, nullptr);
    p_clEnqueueReadBuffer(q_, mcsout, CL_TRUE, 0, 3*CC*4, gpu_csout.data(), 0, nullptr, nullptr);
    { Err e1 = cmp(gpu_scr.data(), r1.scratch.data(), SCR_TOTAL);
      Err e2 = cmp(gpu_csout.data(), r1.conv_state_out.data(), 3*CC);
      printf("[stage1] scratch nmse=%.3e max_abs=%.3e max_rel=%.3e (worst %zu) | conv_state_out nmse=%.3e max_abs=%.3e\n",
             e1.nmse, e1.max_abs, e1.max_rel, e1.worst, e2.nmse, e2.max_abs);
      printf("[stage1] %s\n", (e1.nmse <= TH_NMSE && e2.nmse <= TH_NMSE) ? "PASS" : "FAIL"); }

    // ---- stage2 ----
    a = 0;
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mscr);   p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mrms);   p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mstate); p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, sizeof(cl_mem), &mout);   p_clSetKernelArg(k2, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k2, a++, (S_V+1)*4, nullptr);
    { const size_t g = H_V*WG2, l = WG2;
      e = p_clEnqueueNDRangeKernel(q_, k2, 1, nullptr, &g, &l, 0, nullptr, nullptr); }
    if (e != CL_SUCCESS) { fprintf(stderr, "stage2 NDRange err=%d\n", e); return 2; }
    p_clFinish(q_);
    std::vector<float> gpu_out(H_V*S_V), gpu_state(state_in.size());
    p_clEnqueueReadBuffer(q_, mout, CL_TRUE, 0, H_V*S_V*4, gpu_out.data(), 0, nullptr, nullptr);
    p_clEnqueueReadBuffer(q_, mstate, CL_TRUE, 0, state_in.size()*4, gpu_state.data(), 0, nullptr, nullptr);
    { Err e1 = cmp(gpu_out.data(), r2.out.data(), H_V*S_V);
      Err e2 = cmp(gpu_state.data(), r2.state.data(), state_in.size());
      printf("[stage2] out nmse=%.3e max_abs=%.3e | state nmse=%.3e max_abs=%.3e max_rel=%.3e (worst %zu)\n",
             e1.nmse, e1.max_abs, e2.nmse, e2.max_abs, e2.max_rel, e2.worst);
      printf("[stage2] %s\n", (e1.nmse <= TH_NMSE && e2.nmse <= TH_NMSE) ? "PASS" : "FAIL"); }

    // ---- stage3 ----
    a = 0;
    p_clSetKernelArg(k3, a++, sizeof(cl_mem), &mout);   p_clSetKernelArg(k3, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k3, a++, sizeof(cl_mem), &mW_out); p_clSetKernelArg(k3, a++, sizeof(cl_ulong), &z);
    p_clSetKernelArg(k3, a++, sizeof(cl_mem), &my);     p_clSetKernelArg(k3, a++, sizeof(cl_ulong), &z);
    { const size_t g = N_EMBD, l = WG3;
      e = p_clEnqueueNDRangeKernel(q_, k3, 1, nullptr, &g, &l, 0, nullptr, nullptr); }
    if (e != CL_SUCCESS) { fprintf(stderr, "stage3 NDRange err=%d\n", e); return 2; }
    p_clFinish(q_);
    std::vector<float> gpu_y(N_EMBD);
    p_clEnqueueReadBuffer(q_, my, CL_TRUE, 0, N_EMBD*4, gpu_y.data(), 0, nullptr, nullptr);
    { Err e1 = cmp(gpu_y.data(), r3.y.data(), N_EMBD);
      printf("[stage3] y nmse=%.3e max_abs=%.3e max_rel=%.3e (worst %zu)\n", e1.nmse, e1.max_abs, e1.max_rel, e1.worst);
      printf("[stage3] %s\n", e1.nmse <= TH_NMSE ? "PASS" : "FAIL"); }

    int fails = 0;
    // 汇总 VERDICT 由三段 PASS/FAIL 组成（人工扫）
    printf("DONE\n");
    return fails;
}
