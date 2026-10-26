// [TongYi-Lite 2026-10-27 R-046] L3 三证探针（SA-5 §L3 前置门，独立于 e2e）
// 编译（DGX chroot）:
//   g++ -O2 -std=c++17 -I/build-tyl/third_party/OpenCL-Headers l3_coherency_probe.cpp \
//     -o l3_coherency_probe -L/routeA-staging/clrt-overlay/opt/mesa-cl/lib/aarch64-linux-gnu/clrt \
//     -lOpenCL -Wl,-rpath,/routeA-staging/clrt-overlay/opt/mesa-cl/lib/aarch64-linux-gnu/clrt
// 判读:
//   (a) 后备归属: 打印 hostptr/fd 数变化；设备侧配 dmabuf_dump/kgsl procfs 对账
//   (b) coherency 金丝雀: CPU写→GPU读校验 与 GPU写→CPU读校验（全程同一持久映射，
//       无任何 remap/显式 flush——正是 kgsl_bo_cpu_prep=NOP 的最坏场景）
//   (c) 带宽: GPU 读/写 mapped BO 的 MB/s
// 退出码: 0=三证全过; 1=coherency 失败; 2=环境失败。
#include <CL/cl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <vector>

static double now_ms() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}
static int count_self_fds() {
    DIR * d = opendir("/proc/self/fd"); int n = 0;
    if (d) { while (readdir(d)) n++; closedir(d); if (n > 0) n -= 2; }
    return n;
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
    const int ROUNDS = (argc > 2) ? atoi(argv[2]) : 64;
    const size_t n = MB * 1024 * 1024 / sizeof(int);

    cl_platform_id pl; cl_uint npl = 0;
    if (clGetPlatformIDs(1, &pl, &npl) != CL_SUCCESS || npl == 0) { fprintf(stderr, "no platform\n"); return 2; }
    cl_device_id dev;
    CK(clGetDeviceIDs(pl, CL_DEVICE_TYPE_GPU, 1, &dev, nullptr));
    char v[256] = {0};
    clGetDeviceInfo(dev, CL_DRIVER_VERSION, sizeof(v) - 1, v, nullptr);
    printf("PROBE driver=\"%s\"\n", v);

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

    // ---- (a) ALLOC_HOST_PTR 后备归属观察 ----
    int fd_before = count_self_fds();
    cl_mem bo = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_ALLOC_HOST_PTR, n * sizeof(int), nullptr, &err);
    if (!bo) { fprintf(stderr, "alloc host ptr %d\n", err); return 2; }
    int fd_after = count_self_fds();
    void * hp = nullptr;
    clGetMemObjectInfo(bo, CL_MEM_HOST_PTR, sizeof(hp), &hp, nullptr);
    printf("PROBE(a) alloc_host_ptr mb=%zu hostptr=%p fd_delta=%d\n", MB, hp, fd_after - fd_before);
    void * host = clEnqueueMapBuffer(q, bo, CL_TRUE, CL_MAP_READ | CL_MAP_WRITE, 0, n * sizeof(int), 0, nullptr, nullptr, &err);
    if (!host || err) { fprintf(stderr, "persistent map %d\n", err); return 2; }
    printf("PROBE(a) persistent_map=%p same_as_hostptr=%d\n", host, host == hp);

    cl_mem gout = clCreateBuffer(ctx, CL_MEM_READ_WRITE, (n / 256 + 1) * sizeof(int), nullptr, &err); CK(err);
    std::vector<int> cpu(n / 256 + 1);

    // ---- (b1) CPU 写 -> GPU 读（无 flush，模拟 H2'/L3 主场景）----
    int * hi = (int *)host;
    for (size_t i = 0; i < n; i++) hi[i] = (int)(i * 3 + 7);
    size_t gws = ((n / 256) + 63) / 64 * 64;
    CK(clSetKernelArg(k_sum, 0, sizeof(cl_mem), &bo));
    CK(clSetKernelArg(k_sum, 1, sizeof(cl_mem), &gout));
    CK(clSetKernelArg(k_sum, 2, sizeof(int), (int *)&n));
    CK(clEnqueueNDRangeKernel(q, k_sum, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr));
    CK(clEnqueueReadBuffer(q, gout, CL_TRUE, 0, cpu.size() * sizeof(int), cpu.data(), 0, nullptr, nullptr));
    long bad1 = 0;
    for (size_t g = 0; g < n / 256; g++) {
        int s = 0; for (int i = 0; i < 256; i++) s += (int)((g * 256 + i) * 3 + 7);
        if (cpu[g] != s) bad1++;
    }
    printf("PROBE(b1) cpu_write->gpu_read groups=%zu mismatch=%ld %s\n", n / 256, bad1, bad1 ? "FAIL" : "OK");

    // ---- (b2) GPU 写 -> CPU 读（同一持久映射，无 remap/flush）----
    long bad2 = 0;
    for (int r = 0; r < ROUNDS; r++) {
        int salt = r * 31 + 5;
        CK(clSetKernelArg(k_wr, 0, sizeof(cl_mem), &bo));
        CK(clSetKernelArg(k_wr, 1, sizeof(int), (int *)&n));
        CK(clSetKernelArg(k_wr, 2, sizeof(int), &salt));
        CK(clEnqueueNDRangeKernel(q, k_wr, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr));
        clFinish(q);
        long badr = 0;
        for (size_t i = 0; i < n; i += 997) {   // 跨步抽样（含热点/尾部）
            int want = (int)(((unsigned)(i * 2654435761u)) ^ (unsigned)salt);
            if (hi[i] != want) badr++;
        }
        if (badr) { bad2++; if (bad2 <= 3) printf("PROBE(b2) round=%d sample_mismatch=%ld\n", r, badr); }
    }
    printf("PROBE(b2) gpu_write->cpu_read rounds=%d bad_rounds=%ld %s\n", ROUNDS, bad2, bad2 ? "FAIL" : "OK");

    // ---- (c) 带宽 ----
    double t0 = now_ms();
    for (int r = 0; r < 20; r++) {
        CK(clEnqueueNDRangeKernel(q, k_sum, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr));
    }
    clFinish(q);
    double t_read = (now_ms() - t0) / 20.0;
    t0 = now_ms();
    for (int r = 0; r < 20; r++) {
        int salt = 1000 + r;
        CK(clSetKernelArg(k_wr, 2, sizeof(int), &salt));
        CK(clEnqueueNDRangeKernel(q, k_wr, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr));
    }
    clFinish(q);
    double t_write = (now_ms() - t0) / 20.0;
    printf("PROBE(c) gpu_read %.2f ms %.0f MB/s | gpu_write %.2f ms %.0f MB/s\n",
           t_read, MB / (t_read / 1e3), t_write, MB / (t_write / 1e3));

    clEnqueueUnmapMemObject(q, bo, host, 0, nullptr, nullptr); clFinish(q);
    printf("PROBE done bad1=%ld bad2=%ld\n", bad1, bad2);
    return (bad1 || bad2) ? 1 : 0;
}
