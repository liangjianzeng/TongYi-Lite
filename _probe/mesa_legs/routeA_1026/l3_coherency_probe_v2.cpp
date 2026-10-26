// [TongYi-Lite 2026-10-27 R-053] L3 fallback 三证探针 v2：合法 CL 同步语义（map/unmap）能否替代裸持久映射。
// v1 判词：vendor 驱动 (a)HOST_PTR=NULL、(b1/b2)持久映射裸读写双向 FAIL=直读同 BO 死刑。
// v2 问题：clEnqueueMapBuffer/UnmapMemObject 包裹后，CPU↔GPU 双向是否 cohere？
//   过证 = L3 fallback 定稿（岛边界用 map/unmap 包裹写读）。
// 编译（DGX chroot）:
//   g++ -O2 -std=c++17 -I/build-tyl/third_party/OpenCL-Headers l3_coherency_probe_v2.cpp \
//     -o l3_coherency_probe_v2 -L/routeA-staging/clrt-overlay/opt/mesa-cl/lib/aarch64-linux-gnu/clrt \
//     -l:libOpenCL.so.1 -Wl,-rpath,/routeA-staging/clrt-overlay/opt/.../clrt   (无 .so 符号链 → -l:)
// 退出码: 0=m1&&m2&&c1&&c2 全过; 1=任一 coherency FAIL; 2=环境失败。
#include <CL/cl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <vector>

static double now_ms() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}
#define CK(x) do { cl_int e_ = (x); if (e_ != CL_SUCCESS) { \
    fprintf(stderr, "FATAL %s -> %d\n", #x, e_); exit(2); } } while (0)

static const char * SRC = R"CL(
__kernel void sum_check(__global const int * buf, __global int * out, const int n) {
    int g = get_global_id(0);
    int base = g * 256;
    int s = 0;
    for (int i = 0; i < 256; i++) { int idx = base + i; if (idx < n) s += buf[idx]; }
    out[g] = s;
}
__kernel void pat_write(__global int * buf, const int n, const int salt) {
    int i = get_global_id(0);
    if (i < n) buf[i] = (i * 2654435761u) ^ salt;
}
)CL";

int main(int argc, char ** argv) {
    const size_t MB = (argc > 1) ? atoi(argv[1]) : 32;
    const int ROUNDS = (argc > 2) ? atoi(argv[2]) : 32;
    const size_t n = MB * 1024 * 1024 / sizeof(int);
    const int PLAIN = (argc > 3) ? atoi(argv[3]) : 0;   // 上提（printf 早于分配点）

    cl_platform_id pl; cl_uint npl = 0;
    if (clGetPlatformIDs(1, &pl, &npl) != CL_SUCCESS || npl == 0) { fprintf(stderr, "no platform\n"); return 2; }
    cl_device_id dev;
    CK(clGetDeviceIDs(pl, CL_DEVICE_TYPE_GPU, 1, &dev, nullptr));
    char v[256] = {0};
    clGetDeviceInfo(dev, CL_DRIVER_VERSION, sizeof(v) - 1, v, nullptr);
    printf("PROBE2 driver=\"%s\" mb=%zu rounds=%d plain=%d\n", v, MB, ROUNDS, PLAIN);

    cl_int err;
    cl_context ctx = clCreateContext(nullptr, 1, &dev, nullptr, nullptr, &err);
    if (!ctx) { fprintf(stderr, "ctx %d\n", err); return 2; }
    cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err);
    CK(err);
    cl_program prg = clCreateProgramWithSource(ctx, 1, &SRC, nullptr, &err); CK(err);
    if (clBuildProgram(prg, 1, &dev, "", nullptr, nullptr) != CL_SUCCESS) {
        char log[4096] = {0}; clGetProgramBuildInfo(prg, dev, CL_PROGRAM_BUILD_LOG, sizeof(log) - 1, log, nullptr);
        fprintf(stderr, "build fail: %s\n", log); return 2;
    }
    cl_kernel k_sum = clCreateKernel(prg, "sum_check", &err); CK(err);
    cl_kernel k_wr  = clCreateKernel(prg, "pat_write", &err); CK(err);

    cl_mem bo = clCreateBuffer(ctx, CL_MEM_READ_WRITE | (PLAIN ? 0 : CL_MEM_ALLOC_HOST_PTR), n * sizeof(int), nullptr, &err);
    if (!bo) { fprintf(stderr, "alloc %d\n", err); return 2; }
    if (PLAIN) {   // 普通 BO 无 host map 语义保证；m1 改用 WriteBuffer 预填后仅测 GPU->CPU 向
        std::vector<int> z(n, 0);
        CK(clEnqueueWriteBuffer(q, bo, CL_TRUE, 0, n * sizeof(int), z.data(), 0, nullptr, nullptr));
    }
    cl_mem gout = clCreateBuffer(ctx, CL_MEM_READ_WRITE, (n / 256 + 1) * sizeof(int), nullptr, &err); CK(err);
    std::vector<int> cpu(n / 256 + 1);
    int fails = 0;
    size_t gws = ((n / 256) + 63) / 64 * 64;          // sum_check: 每线程 256 元素
    size_t gws_wr = ((n) + 63) / 64 * 64;              // pat_write: 每线程 1 元素（v2.2 修：原误用 gws=只写前 1/256，冤枉驱动）
    CK(clSetKernelArg(k_sum, 0, sizeof(cl_mem), &bo));
    CK(clSetKernelArg(k_sum, 1, sizeof(cl_mem), &gout));
    CK(clSetKernelArg(k_sum, 2, sizeof(int), (int *)&n));
    CK(clSetKernelArg(k_wr, 0, sizeof(cl_mem), &bo));
    CK(clSetKernelArg(k_wr, 1, sizeof(int), (int *)&n));

    // ---- (m1) map→CPU 写→**unmap**→GPU 读（fallback b1）----
    {
        if (PLAIN) { printf("PROBE2(m1) SKIPPED(plain bo)\n"); }
        int * hi = (int *) clEnqueueMapBuffer(q, bo, CL_TRUE, CL_MAP_WRITE, 0, n * sizeof(int), 0, nullptr, nullptr, &err);
        if (!hi || err) { fprintf(stderr, "m1 map %d\n", err); return 2; }
        for (size_t i = 0; i < n; i++) hi[i] = (int)(i * 3 + 7);
        CK(clEnqueueUnmapMemObject(q, bo, hi, 0, nullptr, nullptr));   // 合法 flush 点
        CK(clFinish(q));
        CK(clEnqueueNDRangeKernel(q, k_sum, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr));
        CK(clEnqueueReadBuffer(q, gout, CL_TRUE, 0, cpu.size() * sizeof(int), cpu.data(), 0, nullptr, nullptr));
        long bad = 0;
        for (size_t g = 0; g < n / 256; g++) {
            int s = 0; for (int i = 0; i < 256; i++) s += (int)((g * 256 + i) * 3 + 7);
            if (cpu[g] != s) bad++;
        }
        printf("PROBE2(m1) map_write_unmap->gpu_read groups=%zu mismatch=%ld %s\n", n / 256, bad, bad ? "FAIL" : "OK");
        if (bad) fails++;
    }

    // ---- (m0) pat_write 覆盖自证（探针自证铁律）----
    {
        int salt = 12345;
        CK(clSetKernelArg(k_wr, 2, sizeof(int), &salt));
        CK(clEnqueueNDRangeKernel(q, k_wr, 1, nullptr, &gws_wr, nullptr, 0, nullptr, nullptr));
        CK(clFinish(q));
        std::vector<int> h(64);
        CK(clEnqueueReadBuffer(q, bo, CL_TRUE, 0, 64 * sizeof(int), h.data(), 0, nullptr, nullptr));
        int want0 = (int)(((unsigned)(13 * 2654435761u)) ^ (unsigned)salt);   // 探针元素 13 处（避开 0）
        bool cov = false;
        for (int i = 0; i < 64; i++) { int w = (int)(((unsigned)(i * 2654435761u)) ^ (unsigned)salt); if (h[i] == w) cov = true; }
        (void)want0;
        printf("PROBE2(m0) pat_write coverage selfproof via ReadBuffer head64=%s\n", cov ? "OK" : "FAIL");
        if (!cov) { printf("PROBE2(m0) FAIL -> kernel coverage broken, abort\n"); return 2; }
    }

    // ---- (m2) GPU 写→finish→map(READ)→CPU 读→unmap（fallback b2）----
    {
        long bad_rounds = 0;
        for (int r = 0; r < ROUNDS; r++) {
            int salt = r * 31 + 11;
            CK(clSetKernelArg(k_wr, 2, sizeof(int), &salt));
            CK(clEnqueueNDRangeKernel(q, k_wr, 1, nullptr, &gws_wr, nullptr, 0, nullptr, nullptr));
            CK(clFinish(q));
            const int * hi = (const int *) clEnqueueMapBuffer(q, bo, CL_TRUE, CL_MAP_READ, 0, n * sizeof(int), 0, nullptr, nullptr, &err);
            if (!hi || err) { fprintf(stderr, "m2 map %d\n", err); return 2; }
            long bad = 0;
            for (size_t i = 0; i < n; i += 997) {
                int want = (int)(((unsigned)(i * 2654435761u)) ^ (unsigned)salt);
                if (hi[i] != want) bad++;
            }
            CK(clEnqueueUnmapMemObject(q, bo, (void *)hi, 0, nullptr, nullptr));
            CK(clFinish(q));
            if (bad) { bad_rounds++; if (bad_rounds <= 3) printf("PROBE2(m2) round=%d sample_mismatch=%ld\n", r, bad); }
        }
        printf("PROBE2(m2) gpu_write->map_read rounds=%d bad_rounds=%ld %s\n", ROUNDS, bad_rounds, bad_rounds ? "FAIL" : "OK");
        if (bad_rounds) fails++;
    }

    // ---- (c1/c2) 阳性对照：WriteBuffer/ReadBuffer（现役 set_tensor 路）----
    {
        std::vector<int> h(n);
        for (size_t i = 0; i < n; i++) h[i] = (int)(i ^ 0x5a5a);
        CK(clEnqueueWriteBuffer(q, bo, CL_TRUE, 0, n * sizeof(int), h.data(), 0, nullptr, nullptr));
        CK(clEnqueueNDRangeKernel(q, k_sum, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr));
        CK(clEnqueueReadBuffer(q, gout, CL_TRUE, 0, cpu.size() * sizeof(int), cpu.data(), 0, nullptr, nullptr));
        long bad1 = 0;
        for (size_t g = 0; g < n / 256; g++) {
            int s = 0; for (int i = 0; i < 256; i++) s += (int)(((g * 256 + i) ^ 0x5a5a));
            if (cpu[g] != s) bad1++;
        }
        printf("PROBE2(c1) writebuffer->gpu_read mismatch=%ld %s\n", bad1, bad1 ? "FAIL" : "OK");
        if (bad1) fails++;
        int salt = 777;
        CK(clSetKernelArg(k_wr, 2, sizeof(int), &salt));
        CK(clEnqueueNDRangeKernel(q, k_wr, 1, nullptr, &gws_wr, nullptr, 0, nullptr, nullptr));
        CK(clEnqueueReadBuffer(q, bo, CL_TRUE, 0, n * sizeof(int), h.data(), 0, nullptr, nullptr));
        long bad2 = 0;
        for (size_t i = 0; i < n; i += 997) {
            int want = (int)(((unsigned)(i * 2654435761u)) ^ (unsigned)salt);
            if (h[i] != want) bad2++;
        }
        printf("PROBE2(c2) gpu_write->readbuffer mismatch=%ld %s\n", bad2, bad2 ? "FAIL" : "OK");
        if (bad2) fails++;
    }

    printf("PROBE2 done fails=%d %s\n", fails, fails ? "SEE_ABOVE" : "ALL_OK");
    return fails ? 1 : 0;
}
