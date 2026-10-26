/* [C1 S0 落锤 · 背书②] subgroup 依赖 kernel 卡死测试：真提交一个同时用
 * sub_group_shuffle_xor + sub_group_barrier + sub_group_reduce_add 的 kernel，
 * 带 20s 硬超时等它跑完。0001 补丁把 IFP 谎报 true + 放开 cl_khr_subgroups 后，
 * 这是"正门路线不会挂 GPU"的直接证据（挂 = kgsl 侧 watchdog 兜底，本进程 timeout 判 HANG）。
 *
 * 判据（全部打到 stdout，主线按行取证）：
 *   [HANGTEST] driver=...                      —— 真 Mesa 验收门（rusticl=裸版本号；出现 QUALCOMM 串=vendor，作废）
 *   [HANGTEST] ext_cl_khr_subgroups=yes ifp=1  —— 被测 lib 真的 advertise 了 subgroup
 *   [HANGTEST] wait=done status=0              —— kernel 跑完（status=CL_COMPLETE）
 *   [HANGTEST] VERDICT=PASS                     —— 唯一合法 PASS（另判 HANG / BUILD_FAIL / NO_EXT）
 *
 * 与 cl_subgroup_probe 同族：dlopen("libOpenCL.so") 自取符号（路 A 上 clrt 目录需有
 * libOpenCL.so -> libOpenCL.so.1 软链；设备上 ln -s 一次即可），绝不回落 /vendor 的 ICD。
 * 编译：chroot 内 gcc -O2 -I <repo>/third_party/OpenCL-Headers 本文件 -ldl -o cl_subgroup_hangtest
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CL/cl.h>

#ifndef CL_DEVICE_SUB_GROUP_SIZES_INTEL
#define CL_DEVICE_SUB_GROUP_SIZES_INTEL 0x4108
#endif
#ifndef CL_TIMEOUT
#define CL_TIMEOUT (-11)
#endif

typedef cl_int (*fn_get_platforms)(cl_uint, cl_platform_id *, cl_uint *);
typedef cl_int (*fn_get_platform_info)(cl_platform_id, cl_platform_info, size_t, void *, size_t *);
typedef cl_int (*fn_get_devices)(cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *);
typedef cl_int (*fn_get_device_info)(cl_device_id, cl_device_info, size_t, void *, size_t *);
typedef cl_context (*fn_create_context)(const cl_context_properties *, cl_uint, const cl_device_id *, void (*)(const char *, const void *, size_t, void *), void *, cl_int *);
typedef cl_command_queue (*fn_create_queue)(cl_context, cl_device_id, cl_command_queue_properties, cl_int *);
typedef cl_mem (*fn_create_buffer)(cl_context, cl_mem_flags, size_t, void *, cl_int *);
typedef cl_program (*fn_create_prog_src)(cl_context, cl_uint, const char *const *, const size_t *, cl_int *);
typedef cl_int (*fn_build_program)(cl_program, cl_uint, const cl_device_id *, const char *, void (*)(cl_program, void *), void *);
typedef cl_int (*fn_get_prog_build_info)(cl_program, cl_device_id, cl_program_build_info, size_t, void *, size_t *);
typedef cl_kernel (*fn_create_kernel)(cl_program, const char *, cl_int *);
typedef cl_int (*fn_set_kernel_arg)(cl_kernel, cl_uint, size_t, const void *);
typedef cl_int (*fn_enqueue_ndrange)(cl_command_queue, cl_kernel, cl_uint, const size_t *, const size_t *, const size_t *, cl_uint, const cl_event *, cl_event *);
typedef cl_int (*fn_wait_events)(cl_uint, const cl_event *, cl_ulong);
typedef cl_int (*fn_enqueue_read)(cl_command_queue, cl_mem, cl_bool, size_t, size_t, void *, cl_uint, const cl_event *, cl_event *);

static fn_get_platforms p_get_platforms;
static fn_get_platform_info p_get_platform_info;
static fn_get_devices p_get_devices;
static fn_get_device_info p_get_device_info;
static fn_create_context p_create_context;
static fn_create_queue p_create_queue;
static fn_create_buffer p_create_buffer;
static fn_create_prog_src p_create_prog_src;
static fn_build_program p_build_program;
static fn_get_prog_build_info p_get_prog_build_info;
static fn_create_kernel p_create_kernel;
static fn_set_kernel_arg p_set_kernel_arg;
static fn_enqueue_ndrange p_enqueue_ndrange;
static fn_wait_events p_wait_events;
static fn_enqueue_read p_enqueue_read;

/* 主变体：shuffle_xor + barrier + reduce_add（ggml 内核 subgroup 面的并集） */
static const char *SRC_FULL =
"__kernel void sg_hang(__global int * out) {\n"
"  int gid = get_global_id(0);\n"
"  int v = gid + 1;\n"
"  int acc = 0;\n"
"  for (int i = 0; i < 4; i++) {\n"
"    v = sub_group_shuffle_xor(v, 1);\n"
"    sub_group_barrier(CL_MEMORY_SEQ_CST);\n"
"    acc += sub_group_reduce_add(v);\n"
"    sub_group_barrier(CL_MEMORY_SEQ_CST);\n"
"  }\n"
"  out[gid] = acc;\n"
"}\n";
/* 降级变体（只为"编译不过"兜底，不为绕挂死）：去掉 reduce_add */
static const char *SRC_BASIC =
"__kernel void sg_hang(__global int * out) {\n"
"  int gid = get_global_id(0);\n"
"  int v = gid + 1;\n"
"  int acc = 0;\n"
"  for (int i = 0; i < 4; i++) {\n"
"    v = sub_group_shuffle_xor(v, 1);\n"
"    sub_group_barrier(CL_MEMORY_SEQ_CST);\n"
"    acc += v;\n"
"  }\n"
"  out[gid] = acc;\n"
"}\n";

int main(void) {
    void *h = dlopen("libOpenCL.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) h = dlopen("libOpenCL.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "[HANGTEST] dlopen libOpenCL.so 失败: %s\n", dlerror()); return 2; }
    p_get_platforms      = (fn_get_platforms)      dlsym(h, "clGetPlatformIDs");
    p_get_platform_info  = (fn_get_platform_info)  dlsym(h, "clGetPlatformInfo");
    p_get_devices        = (fn_get_devices)        dlsym(h, "clGetDeviceIDs");
    p_get_device_info    = (fn_get_device_info)    dlsym(h, "clGetDeviceInfo");
    p_create_context     = (fn_create_context)     dlsym(h, "clCreateContext");
    p_create_queue       = (fn_create_queue)       dlsym(h, "clCreateCommandQueueWithProperties");
    p_create_buffer      = (fn_create_buffer)      dlsym(h, "clCreateBuffer");
    p_create_prog_src    = (fn_create_prog_src)    dlsym(h, "clCreateProgramWithSource");
    p_build_program      = (fn_build_program)      dlsym(h, "clBuildProgram");
    p_get_prog_build_info= (fn_get_prog_build_info)dlsym(h, "clGetProgramBuildInfo");
    p_create_kernel      = (fn_create_kernel)      dlsym(h, "clCreateKernel");
    p_set_kernel_arg     = (fn_set_kernel_arg)     dlsym(h, "clSetKernelArg");
    p_enqueue_ndrange    = (fn_enqueue_ndrange)    dlsym(h, "clEnqueueNDRangeKernel");
    p_wait_events        = (fn_wait_events)        dlsym(h, "clWaitForEvents");
    p_enqueue_read       = (fn_enqueue_read)       dlsym(h, "clEnqueueReadBuffer");
    if (!p_get_platforms || !p_create_context || !p_enqueue_ndrange || !p_wait_events) {
        fprintf(stderr, "[HANGTEST] dlsym 缺符号\n"); return 2;
    }

    cl_platform_id pf; cl_uint npf = 0;
    if (p_get_platforms(1, &pf, &npf) != CL_SUCCESS || npf == 0) { fprintf(stderr, "[HANGTEST] no platform\n"); return 2; }
    char prof[128] = {0}, drv[128] = {0};
    p_get_platform_info(pf, CL_PLATFORM_PROFILE, sizeof prof, prof, NULL);
    p_get_platform_info(pf, CL_PLATFORM_VERSION, sizeof drv, drv, NULL);
    printf("[HANGTEST] platform=%s\n", drv);

    cl_device_id dev; cl_uint nd = 0;
    if (p_get_devices(pf, CL_DEVICE_TYPE_GPU, 1, &dev, &nd) != CL_SUCCESS || nd == 0) {
        fprintf(stderr, "[HANGTEST] no GPU device\n"); return 2;
    }
    char name[128] = {0}, dver[128] = {0};
    p_get_device_info(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
    p_get_device_info(dev, CL_DRIVER_VERSION, sizeof dver, dver, NULL);
    printf("[HANGTEST] device=%s driver=%s\n", name, dver);

    size_t extlen = 0; p_get_device_info(dev, CL_DEVICE_EXTENSIONS, 0, NULL, &extlen);
    char *exts = calloc(1, extlen + 1);
    p_get_device_info(dev, CL_DEVICE_EXTENSIONS, extlen, exts, NULL);
    int has_khr = strstr(exts, "cl_khr_subgroups") != NULL;
    cl_bool ifp = CL_FALSE;
    p_get_device_info(dev, CL_DEVICE_SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS, sizeof ifp, &ifp, NULL);
    printf("[HANGTEST] ext_cl_khr_subgroups=%s ifp=%d\n", has_khr ? "yes" : "no", (int)ifp);
    cl_uint sg_sizes[8] = {0}; size_t sgsz = 0;
    p_get_device_info(dev, (cl_device_info)CL_DEVICE_SUB_GROUP_SIZES_INTEL, sizeof sg_sizes, sg_sizes, &sgsz);
    int nsg = (int)(sgsz / sizeof(cl_uint));
    printf("[HANGTEST] subgroup_sizes=");
    for (int i = 0; i < nsg; i++) printf("%u ", sg_sizes[i]);
    printf("\n");
    if (!has_khr) { printf("[HANGTEST] VERDICT=NO_EXT\n"); return 3; }

    /* 选一个能整除 local=2*s 的 subgroup size（Adreno 报 64/128 族） */
    cl_uint s = 0;
    for (int i = 0; i < nsg; i++) if (sg_sizes[i] >= 8 && sg_sizes[i] <= 128) { s = sg_sizes[i]; break; }
    if (!s) s = 32;
    size_t global = 2 * s, local = s;

    cl_int rc;
    cl_context ctx = p_create_context(NULL, 1, &dev, NULL, NULL, &rc);
    if (!ctx) { fprintf(stderr, "[HANGTEST] createContext rc=%d\n", rc); return 2; }
    cl_command_queue q = p_create_queue(ctx, dev, 0, &rc);
    if (!q) { fprintf(stderr, "[HANGTEST] createQueue rc=%d\n", rc); return 2; }

    cl_program prog = NULL; cl_kernel kn = NULL; const char *variant = "full";
    for (int attempt = 0; attempt < 2; attempt++) {
        const char *src = attempt == 0 ? SRC_FULL : SRC_BASIC;
        size_t srclen = strlen(src);
        variant = attempt == 0 ? "full" : "basic";
        prog = p_create_prog_src(ctx, 1, &src, &srclen, &rc);
        if (!prog) { fprintf(stderr, "[HANGTEST] CreateProgram rc=%d\n", rc); printf("[HANGTEST] VERDICT=BUILD_FAIL\n"); return 3; }
        /* CL3.0 = rustc 前端原生路（自带 prelude）；1.2 会掉 CLC+上游 libclc（已知带 bug，
         * 启动时那条 "Patched Mesa libclc not detected" 警告就是它），sub_group 面编不过 */
        rc = p_build_program(prog, 1, &dev, "-cl-std=CL3.0", NULL, NULL);
        if (rc == CL_SUCCESS) { kn = p_create_kernel(prog, "sg_hang", &rc); if (kn) break; }
        char log[2048] = {0};
        p_get_prog_build_info(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof log - 1, log, NULL);
        printf("[HANGTEST] build %s rc=%d log_tail=%.300s\n", variant, rc, log + (strlen(log) > 300 ? strlen(log) - 300 : 0));
        break; /* 只建 full；BUILD_FAIL 直接如实入账（降级变体留手不动用，防"绕挂死"嫌疑） */
    }
    if (!kn) { printf("[HANGTEST] VERDICT=BUILD_FAIL\n"); return 3; }
    printf("[HANGTEST] build=ok variant=%s local=%zu\n", variant, local);

    cl_mem buf = p_create_buffer(ctx, CL_MEM_READ_WRITE, global * sizeof(int), NULL, &rc);
    if (!buf) { fprintf(stderr, "[HANGTEST] CreateBuffer rc=%d\n", rc); return 2; }
    p_set_kernel_arg(kn, 0, sizeof buf, &buf);

    cl_event ev = NULL;
    rc = p_enqueue_ndrange(q, kn, 1, NULL, &global, &local, 0, NULL, &ev);
    if (rc != CL_SUCCESS) { fprintf(stderr, "[HANGTEST] EnqueueNDRange rc=%d\n", rc); printf("[HANGTEST] VERDICT=BUILD_FAIL\n"); return 3; }
    rc = p_wait_events(1, &ev, 20000 /* ms */);
    if (rc == CL_TIMEOUT) { printf("[HANGTEST] wait=TIMEOUT after 20s\n[HANGTEST] VERDICT=HANG\n"); return 4; }
    if (rc != CL_SUCCESS) { printf("[HANGTEST] wait=error rc=%d\n[HANGTEST] VERDICT=HANG\n", rc); return 4; }
    printf("[HANGTEST] wait=done status=0\n");

    int out[256] = {0};
    size_t rd = global * sizeof(int) < sizeof out ? global * sizeof(int) : sizeof out;
    p_enqueue_read(q, buf, CL_TRUE, 0, rd, out, 0, NULL, NULL);
    int allpos = 1; long sum = 0;
    for (size_t i = 0; i < global && i < 256; i++) { if (out[i] <= 0) allpos = 0; sum += out[i]; }
    printf("[HANGTEST] out[0]=%d out[1]=%d sum=%ld allpositive=%s\n", out[0], out[1], sum, allpos ? "yes" : "no");
    if (!allpos) { printf("[HANGTEST] VERDICT=BAD_OUTPUT\n"); return 5; }
    printf("[HANGTEST] VERDICT=PASS\n");
    return 0;
}
