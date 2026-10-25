/* cl_cmdbuf_probe.c -- S0 整图提交线①（A6b）：OpenCL 命令缓冲能力探针 + 计时原型
 *
 * 回答一个问题：这块驱动上，"整图一次提交"能不能落地、落地后 host 提交成本摊到多少。
 *
 * 做三件事：
 *  1) 能力清单：枚举 platform/device 扩展，找 cl_khr_command_buffer（+
 *     cl_khr_command_buffer_mutable_dispatch / cl_qcom_* 相关），出三栈能力表；
 *  2) 基线计时：N 次 tiny kernel 逐条 clEnqueueNDRangeKernel 的 host 成本
 *     （µs/launch——这就是 llama.cpp decode 今天付的税）；
 *  3) 原型计时（扩展在场时）：record 同样 N 条 → clEnqueueCommandBuffer 重放，
 *     出 replay 摊销 µs/次 与逐条提交的比值——**这是 S0 的直接证据**。
 *
 * 用法（设备上）：
 *   cl_cmdbuf_probe                # 全流程（能力表 + 基线 + 原型[若可用]）
 *   NLAN=2048 REPS=200             # 调发射条数 / 重放次数
 * 环境同 cl_cc_probe：PROBE_OCL=libOpenCL.so  PROBE_DEV=Adreno|rusticl|...
 * 退出码：0 跑完（能力在或不在都会给基线）/ 1 运行失败 / 2 选不到设备 / 4 dlopen 失败
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
FP(cl_context, clCreateContext, (const cl_context_properties *, cl_uint, const cl_device_id *, void (CL_CALLBACK *)(const char *, const void *, size_t, void *), void *, cl_int *))
FP(cl_command_queue, clCreateCommandQueue, (cl_context, cl_device_id, cl_command_queue_properties, cl_int *))
FP(cl_int, clFinish, (cl_command_queue))
FP(cl_int, clReleaseCommandQueue, (cl_command_queue))
FP(cl_int, clReleaseContext, (cl_context))
FP(cl_program, clCreateProgramWithSource, (cl_context, cl_uint, const char **, const size_t *, cl_int *))
FP(cl_int, clBuildProgram, (cl_program, cl_uint, const cl_device_id *, const char *, void (CL_CALLBACK *)(cl_program, void *), void *))
FP(cl_int, clGetProgramBuildInfo, (cl_program, cl_device_id, cl_program_build_info, size_t, void *, size_t *))
FP(cl_kernel, clCreateKernel, (cl_program, const char *, cl_int *))
FP(cl_int, clSetKernelArg, (cl_kernel, cl_uint, size_t, const void *))
FP(cl_int, clEnqueueNDRangeKernel, (cl_command_queue, cl_kernel, cl_uint, const size_t *, const size_t *, const size_t *, cl_uint, const cl_event *, cl_event *))
FP(cl_int, clReleaseKernel, (cl_kernel))
FP(cl_int, clReleaseProgram, (cl_program))
FP(cl_mem, clCreateBuffer, (cl_context, cl_mem_flags, size_t, void *, cl_int *))
FP(cl_int, clReleaseMemObject, (cl_mem))

/* ICD 形态驱动的扩展函数查询（同 cl_cc_probe 教训：只 dlsym 会误判"驱动不可用"） */
typedef void *(*eafp_t)(cl_platform_id, const char *);
static eafp_t g_eafp;
static cl_platform_id g_plat;
static void *sym(const char *n) {
    void *p = dlsym(h, n);
    if (!p && g_eafp && g_plat) p = g_eafp(g_plat, n);
    return p;
}
#define LOAD(n) do { p_##n = (fn_##n) sym(#n); if (!p_##n) { fprintf(stderr, "FATAL: %s 不可用\n", #n); return 4; } } while (0)

/* ---- cl_khr_command_buffer 入口（自己声明，头文件普遍没有） ---- */
typedef struct _cl_command_buffer_khr *cl_command_buffer_khr;
/* cl_khr_command_buffer 的属性串类型按 spec 是 cl_properties（位串对）；
   头文件没有就自定义为 cl_ulong 数组（传 NULL 时类型不参与 ABI）。 */
typedef cl_ulong cl_command_buffer_properties_khr_t;
typedef cl_ulong cl_ndrange_kernel_command_properties_khr_t;
typedef cl_command_buffer_khr (CL_API_ENTRY *fn_clCreateCommandBufferKHR)(cl_uint num_queues, const cl_command_queue *queues, const cl_command_buffer_properties_khr_t *properties, cl_int *errcode_ret);
typedef cl_int (CL_API_ENTRY *fn_clCommandNDRangeKernelKHR)(cl_command_buffer_khr cmd, cl_command_queue queue, const cl_ndrange_kernel_command_properties_khr_t *props, cl_kernel kernel, cl_uint work_dim, const size_t *gwo, const size_t *gws, const size_t *lws);
typedef cl_int (CL_API_ENTRY *fn_clFinalizeCommandBufferKHR)(cl_command_buffer_khr cmd);
typedef cl_int (CL_API_ENTRY *fn_clEnqueueCommandBufferKHR)(cl_uint num_queues, cl_command_queue *queues, cl_command_buffer_khr cmd, cl_uint num_events_wait, const cl_event *wait_list, cl_event *event);
typedef cl_int (CL_API_ENTRY *fn_clReleaseCommandBufferKHR)(cl_command_buffer_khr cmd);
static fn_clCreateCommandBufferKHR  p_clCreateCommandBufferKHR;
static fn_clCommandNDRangeKernelKHR p_clCommandNDRangeKernelKHR;
static fn_clFinalizeCommandBufferKHR p_clFinalizeCommandBufferKHR;
static fn_clEnqueueCommandBufferKHR p_clEnqueueCommandBufferKHR;
static fn_clReleaseCommandBufferKHR p_clReleaseCommandBufferKHR;

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static const char *kTiny =
"kernel void cmdbuf_tiny(global const float* src, global float* dst, const int n) {\n"
"    int i = get_global_id(0); if (i < n) dst[i] = src[i] + 1.0f;\n"
"}\n";

static char *dupinfo_d(cl_device_id d, cl_device_info k) {
    size_t n = 0; static char buf[16384]; buf[0] = 0;
    if (p_clGetDeviceInfo(d, k, sizeof(buf), buf, &n) != CL_SUCCESS) strcpy(buf, "<err>");
    return buf;
}
static char *dupinfo_p(cl_platform_id d, cl_platform_info k) {
    size_t n = 0; static char pbuf[16384]; pbuf[0] = 0;
    if (p_clGetPlatformInfo(d, k, sizeof(pbuf), pbuf, &n) != CL_SUCCESS) strcpy(pbuf, "<err>");
    return pbuf;
}
static int has(const char *e, const char *x) { return e && strstr(e, x) != NULL; }

int main(void) {
    const char *lib = getenv("PROBE_OCL"); if (!lib || !*lib) lib = "libOpenCL.so";
    const char *want = getenv("PROBE_DEV");
    int nlan = getenv("NLAN") ? atoi(getenv("NLAN")) : 1024;
    int reps = getenv("REPS") ? atoi(getenv("REPS")) : 100;
    if (nlan < 1) nlan = 1024;
    if (reps < 1) reps = 100;

    h = dlopen(lib, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen(%s) 失败: %s\n", lib, dlerror()); return 4; }
    LOAD(clGetPlatformIDs); LOAD(clGetPlatformInfo); LOAD(clGetDeviceIDs); LOAD(clGetDeviceInfo);
    LOAD(clCreateContext); LOAD(clCreateCommandQueue); LOAD(clFinish); LOAD(clReleaseCommandQueue);
    LOAD(clReleaseContext); LOAD(clCreateProgramWithSource); LOAD(clBuildProgram);
    LOAD(clGetProgramBuildInfo); LOAD(clCreateKernel); LOAD(clSetKernelArg);
    LOAD(clEnqueueNDRangeKernel); LOAD(clReleaseKernel); LOAD(clReleaseProgram);
    LOAD(clCreateBuffer); LOAD(clReleaseMemObject);

    cl_platform_id plats[8]; cl_uint nplat = 0;
    if (p_clGetPlatformIDs(8, plats, &nplat) != CL_SUCCESS || nplat == 0) { fprintf(stderr, "无平台\n"); return 2; }
    cl_device_id dev = NULL; cl_platform_id plat = NULL;
    for (cl_uint i = 0; i < nplat && !dev; i++) {
        cl_device_id ds[8]; cl_uint nd = 0;
        if (p_clGetDeviceIDs(plats[i], CL_DEVICE_TYPE_GPU, 8, ds, &nd) != CL_SUCCESS) continue;
        for (cl_uint j = 0; j < nd; j++) {
            const char *nm = dupinfo_d(ds[j], CL_DEVICE_NAME);
            if (!want || !*want || strstr(nm, want)) { dev = ds[j]; plat = plats[i]; break; }
        }
    }
    if (!dev) { fprintf(stderr, "选不到设备（PROBE_DEV=%s）\n", want ? want : ""); return 2; }
    g_plat = plat;
    g_eafp = (eafp_t) sym("clGetExtensionFunctionAddressForPlatform");

    const char *dname = dupinfo_d(dev, CL_DEVICE_NAME);
    const char *dext  = dupinfo_d(dev, CL_DEVICE_EXTENSIONS);
    const char *pext  = dupinfo_p(plat, CL_PLATFORM_EXTENSIONS);
    const char *dver  = dupinfo_d(dev, CL_DEVICE_VERSION);

    printf("== cl_cmdbuf_probe（S0 线① A6b）==\n");
    printf("device : %s\n", dname);
    printf("ocl    : %s\n", dver);
    printf("lib    : %s\n", lib);

    /* 1) 能力表 */
    int cmdbuf = has(dext, "cl_khr_command_buffer") || has(pext, "cl_khr_command_buffer");
    int mutdsp = has(dext, "cl_khr_command_buffer_mutable_dispatch") || has(pext, "cl_khr_command_buffer_mutable_dispatch");
    printf("[cap] cl_khr_command_buffer                : %s\n", cmdbuf ? "YES" : "NO");
    printf("[cap] cl_khr_command_buffer_mutable_dispatch: %s\n", mutdsp ? "YES" : "NO");
    const char *qcom[8]; int nq = 0;
    for (const char *p = dext; p && *p && nq < 8; ) {
        const char *e = strstr(p, "cl_qcom_");
        if (!e) break;
        const char *end = e; while (*end && *end != ' ') end++;
        if (end > e) { char buf[128]; size_t n = end - e < 127 ? end - e : 127; memcpy(buf, e, n); buf[n] = 0; qcom[nq++] = strdup(buf); }
        p = end;
    }
    for (int i = 0; i < nq; i++) printf("[cap] qcom ext: %s\n", qcom[i]);

    /* 2) 上下文/队列/tiny kernel 就绪 */
    cl_int err;
    cl_context ctx = p_clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    if (!ctx) { fprintf(stderr, "clCreateContext err=%d\n", err); return 1; }
    cl_command_queue q = p_clCreateCommandQueue(ctx, dev, 0, &err);
    if (!q) { fprintf(stderr, "clCreateCommandQueue err=%d\n", err); return 1; }
    const char *src = kTiny; size_t slen = strlen(kTiny);
    cl_program prog = p_clCreateProgramWithSource(ctx, 1, &src, &slen, &err);
    if (p_clBuildProgram(prog, 1, &dev, NULL, NULL, NULL) != CL_SUCCESS) {
        size_t ln = 0; p_clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &ln);
        char *logb = malloc(ln + 1); p_clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, ln, logb, NULL);
        logb[ln] = 0; fprintf(stderr, "tiny kernel 编译失败:\n%s\n", logb); return 1;
    }
    cl_kernel k = p_clCreateKernel(prog, "cmdbuf_tiny", &err);
    cl_mem a = p_clCreateBuffer(ctx, CL_MEM_READ_ONLY,  64 * sizeof(float), NULL, &err);
    cl_mem b = p_clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, 64 * sizeof(float), NULL, &err);
    cl_int n64 = 64;
    p_clSetKernelArg(k, 0, sizeof(cl_mem), &a);
    p_clSetKernelArg(k, 1, sizeof(cl_mem), &b);
    p_clSetKernelArg(k, 2, sizeof(cl_int), &n64);
    size_t gws = 64, lws = 64;

    /* 基线：逐条提交 nlan 次（decode 今天的形态） */
    p_clFinish(q);
    double t0 = now_ms();
    for (int i = 0; i < nlan; i++) p_clEnqueueNDRangeKernel(q, k, 1, NULL, &gws, &lws, 0, NULL, NULL);
    double t_submit = now_ms();
    p_clFinish(q);
    double t_done = now_ms();
    double per_launch = (t_submit - t0) * 1000.0 / nlan;           /* µs/launch 纯 host */
    double per_launch_w = (t_done - t0) * 1000.0 / nlan;           /* 含 GPU 排空 */
    printf("[base] 逐条提交 %d 次: host %.2f ms → %.2f µs/launch；含完成 %.2f µs/launch\n",
           nlan, t_submit - t0, per_launch, per_launch_w);

    /* 3) 原型：record → finalize → replay reps 次 */
    double per_replay = -1;
    if (cmdbuf) {
        p_clCreateCommandBufferKHR  = (fn_clCreateCommandBufferKHR)  sym("clCreateCommandBufferKHR");
        p_clCommandNDRangeKernelKHR = (fn_clCommandNDRangeKernelKHR) sym("clCommandNDRangeKernelKHR");
        p_clFinalizeCommandBufferKHR= (fn_clFinalizeCommandBufferKHR)sym("clFinalizeCommandBufferKHR");
        p_clEnqueueCommandBufferKHR = (fn_clEnqueueCommandBufferKHR) sym("clEnqueueCommandBufferKHR");
        p_clReleaseCommandBufferKHR = (fn_clReleaseCommandBufferKHR) sym("clReleaseCommandBufferKHR");
        if (!p_clCreateCommandBufferKHR || !p_clCommandNDRangeKernelKHR || !p_clFinalizeCommandBufferKHR ||
            !p_clEnqueueCommandBufferKHR || !p_clReleaseCommandBufferKHR) {
            printf("[cmd ] 扩展在但入口取不全（dlsym+ICD 均失败）——按不可用处理\n");
        } else {
            cl_command_buffer_khr cmd = p_clCreateCommandBufferKHR(1, &q, NULL, &err);
            if (!cmd) {
                printf("[cmd ] clCreateCommandBufferKHR err=%d\n", err);
            } else {
                int okrec = 1;
                for (int i = 0; i < nlan; i++)
                    if (p_clCommandNDRangeKernelKHR(cmd, q, NULL, k, 1, NULL, &gws, &lws) != CL_SUCCESS) { okrec = 0; break; }
                if (!okrec || p_clFinalizeCommandBufferKHR(cmd) != CL_SUCCESS) {
                    printf("[cmd ] record/finalize 失败\n");
                } else {
                    /* record 成本 */
                    double tr0 = now_ms();
                    /* 重放 reps 次（SIMULTANEOUS 未开 → 串行重放安全） */
                    int okr = 1;
                    for (int r = 0; r < reps; r++)
                        if (p_clEnqueueCommandBufferKHR(1, &q, cmd, 0, NULL, NULL) != CL_SUCCESS) { okr = 0; break; }
                    double tr1 = now_ms();
                    p_clFinish(q);
                    double tr2 = now_ms();
                    if (!okr) printf("[cmd ] replay 提交失败\n");
                    else {
                        per_replay = (tr1 - tr0) * 1000.0 / reps;   /* µs/次 replay（含 nlan 条命令） */
                        printf("[cmd ] record %d 条 + finalize OK；replay %d 次: host %.2f ms → %.3f µs/replay"
                               "（摊 %.4f µs/launch）\n",
                               nlan, reps, tr1 - tr0, per_replay, per_replay / nlan);
                    }
                }
                p_clReleaseCommandBufferKHR(cmd);
            }
        }
    }

    /* 汇总行（进台账用） */
    printf("[BENCH] mode=probe stack=S-VOCL model=tiny dev=740 la=auto thermal=warm ngl=na kv=na "
           "ubatch=%d build=cl_cmdbuf_probe prompt=na leg=1/1 tok=%d metric=submit "
           "us_per_launch=%.2f us_per_replay_of_%d=%.3f cmdbuf=%d\n",
           nlan, nlan, per_launch, per_replay, nlan, cmdbuf ? 1 : 0);

    p_clReleaseMemObject(a); p_clReleaseMemObject(b); p_clReleaseKernel(k); p_clReleaseProgram(prog);
    p_clReleaseCommandQueue(q); p_clReleaseContext(ctx);
    return 0;
}
