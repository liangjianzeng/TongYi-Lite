/* cl_bw_probe.c -- 740 带宽/发射税底座量具（全GPU卸载线 2026-10-25）
 *
 * 为什么需要它：profiling 普查显示数据搬运核占 GPU 时间 45%，但拷贝数字
 * （24KB/0.5ms）与 token 预算矛盾（测量扭曲嫌疑）。决策需要物理底：
 *   1) GPU 顺读/写带宽（理论天花板）
 *   2) MoE 专家 gather 带宽（行收集模式 = decode 真实负载）
 *   3) 小拷贝发射税（512 x 24KB，流水 vs 每次 sync —— 直接量化 cache 拷贝病态）
 *   4) KGSL 时钟采样（devfreq min/cur/max + busy%，前购/后采，看时钟是否掉）
 *
 * 用法（设备上，LD_LIBRARY_PATH 指向 opencl-stub 同款）：
 *   cl_bw_probe            # 全量
 *   REPS=5 MB=128 cl_bw_probe
 * 退出码：0 正常 / 2 选不到设备 / 4 dlopen 失败
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>
#include <CL/cl.h>

static void *h;
#define FP(ret, name, args) typedef ret(CL_API_ENTRY *fn_##name) args; static fn_##name p_##name;
FP(cl_int, clGetPlatformIDs, (cl_uint, cl_platform_id *, cl_uint *))
FP(cl_int, clGetPlatformInfo, (cl_platform_id, cl_platform_info, size_t, void *, size_t *))
FP(cl_int, clGetDeviceIDs, (cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *))
FP(cl_int, clGetDeviceInfo, (cl_device_id, cl_device_info, size_t, void *, size_t *))
FP(cl_context, clCreateContext, (const cl_context_properties *, cl_uint, const cl_device_id *, void (*)(const char *, const void *, size_t, void *), void *, cl_int *))
FP(cl_command_queue, clCreateCommandQueue, (cl_context, cl_device_id, cl_command_queue_properties, cl_int *))
FP(cl_mem, clCreateBuffer, (cl_context, cl_mem_flags, size_t, void *, cl_int *))
FP(cl_program, clCreateProgramWithSource, (cl_context, cl_uint, const char **, const size_t *, cl_int *))
FP(cl_int, clBuildProgram, (cl_program, cl_uint, const cl_device_id *, const char *, void (*)(cl_program, void *), void *))
FP(cl_kernel, clCreateKernel, (cl_program, const char *, cl_int *))
FP(cl_int, clSetKernelArg, (cl_kernel, cl_uint, size_t, const void *))
FP(cl_int, clEnqueueNDRangeKernel, (cl_command_queue, cl_kernel, cl_uint, const size_t *, const size_t *, const size_t *, cl_uint, const cl_mem *, cl_event *))
FP(cl_int, clEnqueueFillBuffer, (cl_command_queue, cl_mem, const void *, size_t, size_t, size_t, cl_uint, const cl_mem *, cl_event *))
FP(cl_int, clFinish, (cl_command_queue))
FP(cl_int, clReleaseMemObject, (cl_mem))
FP(cl_int, clReleaseKernel, (cl_kernel))
FP(cl_int, clReleaseProgram, (cl_program))
FP(cl_int, clReleaseCommandQueue, (cl_command_queue))
FP(cl_int, clReleaseContext, (cl_context))
FP(void *, clEnqueueMapBuffer, (cl_command_queue, cl_mem, cl_bool, cl_map_flags, size_t, size_t, cl_uint, const cl_mem *, cl_event *, cl_int *))
FP(cl_int, clEnqueueUnmapMemObject, (cl_command_queue, cl_mem, void *, cl_uint, const cl_mem *, cl_event *))

typedef void *(*eafp_t)(cl_platform_id, const char *);
typedef void *(*ea_t)(const char *);
static eafp_t g_eafp; static ea_t g_ea; static cl_platform_id g_plat;
static void *sym(const char *n) {
    void *p = dlsym(h, n);
    if (!p && g_eafp && g_plat) p = g_eafp(g_plat, n);
    if (!p && g_ea) p = g_ea(n);
    return p;
}
#define LOAD(n) do { p_##n = (fn_##n) sym(#n); if (!p_##n) { fprintf(stderr, "FATAL: no %s\n", #n); return 4; } } while (0)

static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void kgsl_clocks(const char * tag) {
    const char * files[] = { "min_clk_mhz", "max_clk_mhz", "cur_clk_mhz", "gpu_busy_percentage", "devfreq/cur_freq" };
    for (unsigned i = 0; i < sizeof(files)/sizeof(files[0]); ++i) {
        char p[160]; snprintf(p, sizeof(p), "/sys/class/kgsl/kgsl-3d0/%s", files[i]);
        FILE * f = fopen(p, "r");
        if (f) {
            char buf[64] = {0};
            size_t n = fread(buf, 1, sizeof(buf)-1, f); fclose(f);
            if (n > 0) { if (buf[n-1] == '\n') buf[n-1] = 0; printf("  [%s] %s = %s\n", tag, files[i], buf); }
        }
    }
}

static const char * K_SUM =
"kernel void k_sum(global float4 * a, global float * out, uint n4) {\n"
"    uint g = get_global_size(0);\n"
"    float4 s = (float4)(0.0f);\n"
"    for (uint i = get_global_id(0); i < n4; i += g) s += a[i];\n"
"    if (s.x + s.y + s.z + s.w == 1e38f) out[0] = s.x;  // never true; blocks DCE\n"
"}\n";

static const char * K_WRITE =
"kernel void k_write(global float4 * a, uint n4) {\n"
"    uint g = get_global_size(0);\n"
"    float4 v = (float4)(get_global_id(0) * 0.5f);\n"
"    for (uint i = get_global_id(0); i < n4; i += g) a[i] = v;\n"
"}\n";

// MoE 专家 gather：每个 workgroup 读 R 行 x 1536 float（6KB/行），行号来自行首元素
// 的伪随机（避免真随机表）。步长 128MB / R 行模拟 128 专家 bank。
static const char * K_GATHER =
"kernel void k_gather(global float * a, global float * out, uint row_floats, uint n_rows, uint bank_stride) {\n"
"    uint wg = get_group_id(0);\n"
"    uint lane = get_local_id(0);\n"
"    uint lsz = get_local_size(0);\n"
"    uint row = wg % n_rows;\n"
"    uint bank = (wg / n_rows) % 128;\n"
"    global float * base = a + (ulong)bank * bank_stride + (ulong)row * row_floats;\n"
"    float s = 0.0f;\n"
"    for (uint i = lane; i < row_floats; i += lsz) s += base[i];\n"
"    if (s == 1e38f) out[0] = s;\n"
"}\n";

// 小拷贝：与 llama cpy_flat 同形（1D 线性 float4 copy）
static const char * K_COPY =
"kernel void k_copy(global float4 * src, global float4 * dst, uint n4) {\n"
"    uint i = get_global_id(0);\n"
"    if (i < n4) dst[i] = src[i];\n"
"}\n";

// 30-arg variant: llama dispatches set 20-32 args per call; measures the
// per-arg cost of clSetKernelArg + clEnqueueNDRangeKernel on the host path.
static const char * K_COPY30 =
"kernel void k_copy30(global float4 * src, global float4 * dst, uint n4,\n"
"    ulong a0, ulong a1, ulong a2, ulong a3, ulong a4, ulong a5, ulong a6, ulong a7,\n"
"    ulong a8, ulong a9, ulong a10, ulong a11, ulong a12, ulong a13, ulong a14, ulong a15,\n"
"    int b0, int b1, int b2, int b3, int b4, int b5, int b6, int b7, int b8, int b9,\n"
"    int c0, int c1) {\n"
"    uint i = get_global_id(0);\n"
"    if (i < n4) dst[i] = src[i] + (float4)(a0+a1+a2+a3+a4+a5+a6+a7+a8+a9+a10+a11+a12+a13+a14+a15+b0+b1+b2+b3+b4+b5+b6+b7+b8+b9+c0+c1);\n"
"}\n";

static cl_program build(cl_context ctx, cl_device_id dev, const char * src) {
    cl_int err;
    cl_program p = p_clCreateProgramWithSource(ctx, 1, &src, NULL, &err);
    if (!p) { fprintf(stderr, "FATAL: create program err=%d\n", err); exit(1); }
    err = p_clBuildProgram(p, 1, &dev, "-O2", NULL, NULL);
    if (err != CL_SUCCESS) { fprintf(stderr, "FATAL: build err=%d\n", err); exit(1); }
    return p;
}

static double best_of(int reps, double * all) {
    double b = all[0];
    for (int i = 1; i < reps; ++i) if (all[i] < b) b = all[i];
    return b;
}

int main(void) {
    const char * lib = getenv("PROBE_OCL"); if (!lib || !*lib) lib = "libOpenCL.so";
    h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "FATAL: dlopen %s: %s\n", lib, dlerror()); return 4; }
    cl_uint nplat = 0;
    if (p_clGetPlatformIDs) {} // loaded below
    #define L(n) LOAD(n)
    L(clGetPlatformIDs); L(clGetPlatformInfo); L(clGetDeviceIDs); L(clGetDeviceInfo);
    L(clCreateContext); L(clCreateCommandQueue); L(clCreateBuffer);
    L(clCreateProgramWithSource); L(clBuildProgram); L(clCreateKernel);
    L(clSetKernelArg); L(clEnqueueNDRangeKernel); L(clEnqueueFillBuffer);
    L(clFinish); L(clReleaseMemObject); L(clReleaseKernel); L(clReleaseProgram);
    L(clReleaseCommandQueue); L(clReleaseContext); L(clEnqueueMapBuffer); L(clEnqueueUnmapMemObject);
    #undef L

    cl_platform_id plat; cl_device_id dev;
    if (p_clGetPlatformIDs(1, &plat, &nplat) != CL_SUCCESS || nplat == 0) { fprintf(stderr, "FATAL: no platform\n"); return 2; }
    if (p_clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, NULL) != CL_SUCCESS) { fprintf(stderr, "FATAL: no GPU dev\n"); return 2; }
    char dname[256] = {0}; p_clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof(dname)-1, dname, NULL);
    cl_uint cu = 0; p_clGetDeviceInfo(dev, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(cu), &cu, NULL);
    cl_ulong gm = 0; p_clGetDeviceInfo(dev, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(gm), &gm, NULL);
    printf("device: %s  CU=%u  max_alloc=%llu MB\n", dname, cu, (unsigned long long)(gm >> 20));

    cl_int err;
    cl_context ctx = p_clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    cl_command_queue q = p_clCreateCommandQueue(ctx, dev, 0, &err);

    int reps = getenv("REPS") ? atoi(getenv("REPS")) : 5;
    size_t mb = getenv("MB") ? (size_t)atoi(getenv("MB")) : 256;
    if ((size_t)gm && mb * 1048576ull > (size_t)gm) mb = (size_t)gm >> 20;
    size_t bytes = mb * 1048576ull;
    size_t n4 = bytes / 16;

    cl_mem buf = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, bytes, NULL, &err);
    if (!buf) { fprintf(stderr, "FATAL: alloc %zuMB err=%d\n", mb, err); return 1; }
    float zero = 0.f;
    p_clEnqueueFillBuffer(q, buf, &zero, sizeof(float), 0, bytes, 0, NULL, NULL);
    p_clFinish(q);
    cl_mem out = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, 4096, NULL, &err);

    printf("== 1) GPU 顺读带宽（%zu MB, %d reps best）==\n", mb, reps);
    cl_program ps = build(ctx, dev, K_SUM);
    cl_kernel ks = p_clCreateKernel(ps, "k_sum", &err);
    p_clSetKernelArg(ks, 0, sizeof(cl_mem), &buf);
    p_clSetKernelArg(ks, 1, sizeof(cl_mem), &out);
    p_clSetKernelArg(ks, 2, sizeof(cl_uint), &n4);
    size_t gws = 4096, lws = 256;
    double t[8];
    for (int r = -1; r < reps; ++r) {           // r=-1 热身（时钟爬坡）
        double t0 = now_s();
        p_clEnqueueNDRangeKernel(q, ks, 1, NULL, &gws, &lws, 0, NULL, NULL);
        p_clFinish(q);
        double t1 = now_s();
        if (r >= 0) t[r] = t1 - t0;
    }
    printf("   read: %.1f GB/s  (%.2f ms)\n", bytes / best_of(reps, t) / 1e9, best_of(reps, t) * 1e3);
    kgsl_clocks("after-read");

    printf("== 2) GPU 顺写带宽 ==\n");
    cl_program pw = build(ctx, dev, K_WRITE);
    cl_kernel kw = p_clCreateKernel(pw, "k_write", &err);
    p_clSetKernelArg(kw, 0, sizeof(cl_mem), &buf);
    p_clSetKernelArg(kw, 1, sizeof(cl_uint), &n4);
    for (int r = -1; r < reps; ++r) {
        double t0 = now_s();
        p_clEnqueueNDRangeKernel(q, kw, 1, NULL, &gws, &lws, 0, NULL, NULL);
        p_clFinish(q);
        double t1 = now_s();
        if (r >= 0) t[r] = t1 - t0;
    }
    printf("   write: %.1f GB/s  (%.2f ms)\n", bytes / best_of(reps, t) / 1e9, best_of(reps, t) * 1e3);
    kgsl_clocks("after-write");

    // 3) MoE gather：每 workgroup 读 1 行 6KB（1536 float），8 行/虚拟 token，
    //    128 专家 bank 均布在 256MB 里。workgroups = tokens x rows x banks 模拟。
    printf("== 3) MoE gather（每行 6KB, 8 行 x 128 bank 扫一遍 = 6.3MB/轮 x64 轮）==\n");
    cl_program pg = build(ctx, dev, K_GATHER);
    cl_kernel kg = p_clCreateKernel(pg, "k_gather", &err);
    {
        cl_uint row_floats = 1536, n_rows = 8;
        cl_uint bank_stride = (cl_uint)(bytes / 4 / 128);   // float 间隔
        p_clSetKernelArg(kg, 0, sizeof(cl_mem), &buf);
        p_clSetKernelArg(kg, 1, sizeof(cl_mem), &out);
        p_clSetKernelArg(kg, 2, sizeof(cl_uint), &row_floats);
        p_clSetKernelArg(kg, 3, sizeof(cl_uint), &n_rows);
        p_clSetKernelArg(kg, 4, sizeof(cl_uint), &bank_stride);
        size_t wgs = 1024, gl = 1024 * 64;                  // 64 轮 x 1024 行组
        for (int r = -1; r < reps; ++r) {
            double t0 = now_s();
            p_clEnqueueNDRangeKernel(q, kg, 1, NULL, &gl, &wgs, 0, NULL, NULL);
            p_clFinish(q);
            double t1 = now_s();
            if (r >= 0) t[r] = t1 - t0;
        }
        double gb = 1024.0 * 64 * row_floats * 4 / 1e9;     // 每 workgroup 一行
        printf("   gather: %.1f GB/s  (%.2f ms for %.1f MB)\n", gb / best_of(reps, t), best_of(reps, t) * 1e3, gb * 1000);
    }
    kgsl_clocks("after-gather");

    // 4) 小拷贝发射税：512 x 24KB copy，A=流水（一次 finish）B=每次 finish
    printf("== 4) 小拷贝发射税（512 x 24KB，llama cache 拷贝同型）==\n");
    cl_program pc = build(ctx, dev, K_COPY);
    cl_kernel kc = p_clCreateKernel(pc, "k_copy", &err);
    {
        size_t cbytes = 24576;                              // 24KB = cache_r 拷贝同款
        cl_uint cn4 = (cl_uint)(cbytes / 16);
        cl_mem csrc = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, cbytes, NULL, &err);
        cl_mem cdst = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, cbytes, NULL, &err);
        p_clSetKernelArg(kc, 0, sizeof(cl_mem), &csrc);
        p_clSetKernelArg(kc, 1, sizeof(cl_mem), &cdst);
        p_clSetKernelArg(kc, 2, sizeof(cl_uint), &cn4);
        size_t cg = cn4, cl_ = 64;
        const int N = 512;
        for (int mode = 0; mode < 2; ++mode) {
            for (int r = -1; r < reps; ++r) {
                double t0 = now_s();
                for (int i = 0; i < N; ++i) {
                    p_clEnqueueNDRangeKernel(q, kc, 1, NULL, &cg, &cl_, 0, NULL, NULL);
                    if (mode == 1) p_clFinish(q);           // B: 每次 sync
                }
                p_clFinish(q);
                double t1 = now_s();
                if (r >= 0) t[r] = t1 - t0;
            }
            double per = best_of(reps, t) / N * 1e6;
            printf("   %s: %.1f us/launch（含执行）, 有效带宽 %.1f GB/s\n",
                   mode == 0 ? "流水(1 finish)" : "每拷贝 sync ", per, cbytes * N / best_of(reps, t) / 1e9);
        }
        p_clReleaseMemObject(csrc); p_clReleaseMemObject(cdst);
    }

    // 4b) 参数数量税：3 args vs 30 args，同 kernel/形状，纯流水发射
    printf("== 4b) 参数数量税（512 x 24KB 流水，3 args vs 30 args）==\n");
    {
        size_t cbytes = 24576;
        cl_uint cn4 = (cl_uint)(cbytes / 16);
        cl_mem csrc = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, cbytes, NULL, &err);
        cl_mem cdst = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, cbytes, NULL, &err);
        size_t cg = cn4, cl_ = 64;
        const int N = 512;
        cl_program pc30 = build(ctx, dev, K_COPY30);
        cl_kernel k3 = p_clCreateKernel(pc, "k_copy", &err);
        cl_kernel k30 = p_clCreateKernel(pc30, "k_copy30", &err);
        cl_ulong z = 0; cl_int zi = 0;
        for (int variant = 0; variant < 2; ++variant) {
            cl_kernel k = variant ? k30 : k3;
            p_clSetKernelArg(k, 0, sizeof(cl_mem), &csrc);
            p_clSetKernelArg(k, 1, sizeof(cl_mem), &cdst);
            p_clSetKernelArg(k, 2, sizeof(cl_uint), &cn4);
            for (cl_uint a = 3; a < (variant ? 32u : 3u); ++a) p_clSetKernelArg(k, a, variant == 1 && a < 19 ? sizeof(cl_ulong) : sizeof(cl_int), variant == 1 && a < 19 ? (void *)&z : (void *)&zi);
            for (int r = -1; r < reps; ++r) {
                double t0 = now_s();
                for (int i = 0; i < N; ++i) p_clEnqueueNDRangeKernel(q, k, 1, NULL, &cg, &cl_, 0, NULL, NULL);
                p_clFinish(q);
                double t1 = now_s();
                if (r >= 0) t[r] = t1 - t0;
            }
            printf("   %d args: %.1f us/launch\n", variant ? 32 : 3, best_of(reps, t) / N * 1e6);
        }
        p_clReleaseMemObject(csrc); p_clReleaseMemObject(cdst);
    }
    kgsl_clocks("after-copy");

    // 5) CPU 参照：单线程 + 4 线程顺读
    printf("== 5) CPU 参照顺读（mmap 式大缓冲）==\n");
    {
        size_t cb = 256 * 1048576ull;
        char * p = (char *)malloc(cb);
        memset(p, 1, cb);
        for (int r = -1; r < reps; ++r) {
            double t0 = now_s();
            volatile unsigned long long s = 0;
            for (size_t i = 0; i < cb; i += 64) s += *(unsigned long long *)(p + i);
            double t1 = now_s();
            if (r >= 0) t[r] = t1 - t0;
        }
        printf("   cpu 1线程读: %.1f GB/s\n", cb / best_of(reps, t) / 1e9);
        free(p);
    }
    kgsl_clocks("end");
    printf("DONE_BW_PROBE\n");
    return 0;
}
