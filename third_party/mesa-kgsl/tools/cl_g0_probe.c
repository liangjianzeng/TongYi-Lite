/* cl_g0_probe.c -- S0 G0 形态评估（A7.0）：整图单核两大支撑的可行性探针
 *
 * G0（整图单核巨核）四路攻克路线里，三条可以当场出判据：
 *   路线② device enqueue（OpenCL 2.0 child kernel）：查 CL_DEVICE_VERSION ≥ 2.0
 *          且 CL_DEVICE_QUEUE_PROPERTIES 含 CL_QUEUE_ON_DEVICE*。
 *   路线① 巨核内自同步栅栏（自研 atomics 协议）：多 workgroup 原子计数栅栏——
 *          关键问题是 **活性**：Adreno 的 WG 并发度有限（CU×槽位），
 *          栅栏参与者数 > 最大并发 WG 数 = 必死锁。本探针从 N=2 逐级扫描，
 *          内核带自旋上限（防真挂死），找出"能活的最大 N"，并测栅栏单次成本。
 *          —— N_max ≥ 一个巨核需要的 WG 数 ⇒ 路线①成立。
 *   线①' cl_qcom_recordable_queues（vendor 单提交复活线索，A6b KHR 判死后）：
 *          录制 N 条命令 → clEnqueuePlaybackQCOM 一次重放 = 单提交整图。
 *          本探针做真录制/重放微基准，出 µs/replay vs 逐条 µs/launch。
 *
 * ⚠ Adreno 只认旧式 atomics（atomic_add on volatile global uint*），
 *    C11 atomic API（atomic_uint* / atomic_fetch_add_explicit）编不过（R-005 前车）。
 * ⚠ 栅栏必须每 WG 单线程参与（local_id==0），全组 64 线程各自增 counter
 *    会 64× 超计目标恒假活——扫描结果无效。
 *
 * 用法：cl_g0_probe            # 全流程：能力 + 栅栏活性扫描(N=2..512) + 重放微基准
 * 环境：PROBE_OCL/PROBE_DEV 同 cl_cc_probe；SPIN_LIMIT 自旋上限；PROBE_TAG 台账机型标。
 * 退出码：0 跑完 / 1 运行失败 / 2 无设备 / 4 dlopen 失败
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
FP(void *, clEnqueueMapBuffer, (cl_command_queue, cl_mem, cl_bool, cl_map_flags, size_t, size_t, cl_uint, const cl_event *, cl_event *, cl_int *))
FP(cl_int, clEnqueueUnmapMemObject, (cl_command_queue, cl_mem, void *, cl_uint, const cl_event *, cl_event *))
FP(cl_int, clReleaseMemObject, (cl_mem))

typedef void *(*eafp_t)(cl_platform_id, const char *);
static eafp_t g_eafp; static cl_platform_id g_plat;
static void *sym(const char *n) {
    void *p = dlsym(h, n);
    if (!p && g_eafp && g_plat) p = g_eafp(g_plat, n);
    return p;
}
#define LOAD(n) do { p_##n = (fn_##n) sym(#n); if (!p_##n) { fprintf(stderr, "FATAL: %s 不可用\n", #n); return 4; } } while (0)

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
static char g_bufA[16384], g_bufB[16384], g_bufC[16384];
static char *dupinfo3(cl_device_id d, cl_device_info k, char *buf) {
    size_t n = 0; buf[0] = 0;
    if (p_clGetDeviceInfo(d, k, 16384, buf, &n) != CL_SUCCESS) strcpy(buf, "<err>");
    return buf;
}
static int has(const char *e, const char *x) { return e && strstr(e, x) != NULL; }

/* 栅栏内核：N 个 workgroup，每 WG 仅 local_id==0 参与（防假活），旧式 atomics。
 * 防死锁三保险：①自旋上限 SPIN_LIMIT 后退出并写 out[1]=2(timeout)
 * ②多轮栅栏（ROUNDS）验证可复用性 ③位标记 arrived[] 每 WG 每轮一次。
 * g0_nop：重放微基准用的最小内核。 */
static const char *kBarrier =
"kernel void g0_barrier(volatile global uint* counter,\n"
"                       volatile global uint* arrived,\n"
"                       global uint* out,\n"
"                       const uint n_wg, const uint rounds, const uint spin_limit) {\n"
"    const uint gid = get_group_id(0);\n"
"    if (get_local_id(0) != 0u) return;\n"
"    for (uint r = 0; r < rounds; r++) {\n"
"        arrived[gid] = r + 1u;\n"
"        atomic_add(counter, 1u);\n"
"        const uint target = (r + 1u) * n_wg;\n"
"        uint spin = 0;\n"
"        while (*counter < target) {\n"
"            if (++spin > spin_limit) { out[1] = 2u; return; }\n"
"        }\n"
"    }\n"
"    if (gid == 0u) out[0] = 1u;\n"
"}\n"
"kernel void g0_nop(global uint* out) {\n"
"    if (get_global_id(0) == 0u) out[0] = out[0] + 1u;\n"
"}\n";

/* cl_qcom_recordable_queues 入口（vendor 扩展，按 spec 签名本地声明） */
typedef cl_command_queue (CL_API_ENTRY *fn_crq_qcom)(cl_context, cl_device_id, cl_command_queue_properties, cl_int *);
typedef cl_int (CL_API_ENTRY *fn_pb_qcom)(cl_command_queue, cl_command_queue, cl_uint, const cl_event *, cl_event *);

int main(void) {
    const char *lib = getenv("PROBE_OCL"); if (!lib || !*lib) lib = "libOpenCL.so";
    const char *want = getenv("PROBE_DEV");
    const char *devtag = getenv("PROBE_TAG"); if (!devtag || !*devtag) devtag = "740";
    unsigned spin_limit = getenv("SPIN_LIMIT") ? (unsigned)atoi(getenv("SPIN_LIMIT")) : 8000000u;

    h = dlopen(lib, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen(%s) 失败: %s\n", lib, dlerror()); return 4; }
    LOAD(clGetPlatformIDs); LOAD(clGetPlatformInfo); LOAD(clGetDeviceIDs); LOAD(clGetDeviceInfo);
    LOAD(clCreateContext); LOAD(clCreateCommandQueue); LOAD(clFinish); LOAD(clReleaseCommandQueue);
    LOAD(clReleaseContext); LOAD(clCreateProgramWithSource); LOAD(clBuildProgram);
    LOAD(clGetProgramBuildInfo); LOAD(clCreateKernel); LOAD(clSetKernelArg);
    LOAD(clEnqueueNDRangeKernel); LOAD(clReleaseKernel); LOAD(clReleaseProgram);
    LOAD(clCreateBuffer); LOAD(clEnqueueMapBuffer); LOAD(clEnqueueUnmapMemObject);
    LOAD(clReleaseMemObject);

    cl_platform_id plats[8]; cl_uint nplat = 0;
    if (p_clGetPlatformIDs(8, plats, &nplat) != CL_SUCCESS || !nplat) return 2;
    cl_device_id dev = NULL; cl_platform_id plat = NULL;
    for (cl_uint i = 0; i < nplat && !dev; i++) {
        cl_device_id ds[8]; cl_uint nd = 0;
        if (p_clGetDeviceIDs(plats[i], CL_DEVICE_TYPE_GPU, 8, ds, &nd) != CL_SUCCESS) continue;
        for (cl_uint j = 0; j < nd; j++) {
            char nmbuf[256]; size_t nn = 0; nmbuf[0] = 0;
            p_clGetDeviceInfo(ds[j], CL_DEVICE_NAME, sizeof(nmbuf), nmbuf, &nn);
            const char *nm = nmbuf;
            if (!want || !*want || strstr(nm, want)) { dev = ds[j]; plat = plats[i]; break; }
        }
    }
    if (!dev) { fprintf(stderr, "选不到设备\n"); return 2; }
    g_plat = plat;
    g_eafp = (eafp_t) sym("clGetExtensionFunctionAddressForPlatform");

    const char *dname = dupinfo3(dev, CL_DEVICE_NAME, g_bufA);
    const char *dver  = dupinfo3(dev, CL_DEVICE_VERSION, g_bufB);
    const char *dext  = dupinfo3(dev, CL_DEVICE_EXTENSIONS, g_bufC);
    cl_uint cus = 0; p_clGetDeviceInfo(dev, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(cus), &cus, NULL);
    cl_uint qprops_ok = 0;
    {
        /* OpenCL 2.0+ : CL_DEVICE_QUEUE_PROPERTIES(0x102A) 含 CL_QUEUE_ON_DEVICE(0x100) */
        cl_bitfield qp = 0;
        if (p_clGetDeviceInfo(dev, 0x102A, sizeof(qp), &qp, NULL) == CL_SUCCESS)
            qprops_ok = (qp & 0x100) ? 1 : 0;
    }
    printf("== cl_g0_probe（S0 G0 形态评估 / A7.0）==\n");
    printf("device : %s  (%s, CU=%u)\n", dname, dver, cus);
    int de2 = (strncmp(dver, "OpenCL 2", 8) == 0 || strncmp(dver, "OpenCL 3", 8) == 0);
    int de_ext = has(dext, "cl_khr_device_enqueue");
    printf("[cap] device enqueue: CL>=2.0 %s, cl_khr_device_enqueue 扩展 %s, on-device queue %s\n",
           de2 ? "Y" : "N", de_ext ? "Y" : "N", qprops_ok ? "Y" : "N");

    cl_int err;
    cl_context ctx = p_clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    if (!ctx) { fprintf(stderr, "clCreateContext err=%d\n", err); return 1; }
    cl_command_queue q = p_clCreateCommandQueue(ctx, dev, 0, &err);
    if (!q) { fprintf(stderr, "clCreateCommandQueue err=%d\n", err); return 1; }
    const char *src = kBarrier; size_t slen = strlen(kBarrier);
    cl_program prog = p_clCreateProgramWithSource(ctx, 1, &src, &slen, &err);
    if (p_clBuildProgram(prog, 1, &dev, NULL, NULL, NULL) != CL_SUCCESS) {
        size_t ln = 0; p_clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &ln);
        char *lb = malloc(ln + 1); p_clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, ln, lb, NULL);
        lb[ln] = 0; fprintf(stderr, "栅栏内核编译失败:\n%s\n", lb); return 1;
    }
    cl_kernel k = p_clCreateKernel(prog, "g0_barrier", &err);
    if (!k) { fprintf(stderr, "clCreateKernel(g0_barrier) err=%d\n", err); return 1; }

    const uint32_t NMAXWG = 512;
    cl_mem mctr = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, 4, NULL, &err);
    cl_mem marr = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, NMAXWG * 4, NULL, &err);
    cl_mem mout = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_ALLOC_HOST_PTR, 8, NULL, &err);
    uint32_t rounds = 4;
    cl_uint spin = spin_limit;

    printf("[scan] 自同步栅栏活性扫描（每档 %u 轮，自旋上限 %u）:\n", rounds, spin_limit);
    uint32_t alive_max = 0; double alive_ms = 0;
    const uint32_t steps[] = {2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512};
    for (unsigned si = 0; si < sizeof(steps)/sizeof(steps[0]); si++) {
        uint32_t n = steps[si];
        /* 清 counter/arrived/out：map 写零再 unmap，随后 finish 保证生效 */
        uint32_t *ctr = p_clEnqueueMapBuffer(q, mctr, CL_TRUE, CL_MAP_WRITE, 0, 4, 0, NULL, NULL, &err);
        if (!ctr) { fprintf(stderr, "map mctr err=%d\n", err); return 1; }
        *ctr = 0; p_clEnqueueUnmapMemObject(q, mctr, ctr, 0, NULL, NULL);
        uint32_t *arr = p_clEnqueueMapBuffer(q, marr, CL_TRUE, CL_MAP_WRITE, 0, NMAXWG * 4, 0, NULL, NULL, &err);
        if (!arr) { fprintf(stderr, "map marr err=%d\n", err); return 1; }
        memset(arr, 0, NMAXWG * 4); p_clEnqueueUnmapMemObject(q, marr, arr, 0, NULL, NULL);
        uint32_t *o = p_clEnqueueMapBuffer(q, mout, CL_TRUE, CL_MAP_WRITE, 0, 8, 0, NULL, NULL, &err);
        if (!o) { fprintf(stderr, "map mout err=%d\n", err); return 1; }
        o[0] = 0; o[1] = 0; p_clEnqueueUnmapMemObject(q, mout, o, 0, NULL, NULL);
        p_clFinish(q);

        p_clSetKernelArg(k, 0, sizeof(cl_mem), &mctr);
        p_clSetKernelArg(k, 1, sizeof(cl_mem), &marr);
        p_clSetKernelArg(k, 2, sizeof(cl_mem), &mout);
        p_clSetKernelArg(k, 3, sizeof(cl_uint), &n);
        p_clSetKernelArg(k, 4, sizeof(cl_uint), &rounds);
        p_clSetKernelArg(k, 5, sizeof(cl_uint), &spin);
        size_t gws = (size_t)n * 64, lws = 64;
        double t0 = now_ms();
        cl_int rc = p_clEnqueueNDRangeKernel(q, k, 1, NULL, &gws, &lws, 0, NULL, NULL);
        p_clFinish(q);
        double dt = now_ms() - t0;
        uint32_t ok = 0, tmo = 0;
        uint32_t *o2 = p_clEnqueueMapBuffer(q, mout, CL_TRUE, CL_MAP_READ, 0, 8, 0, NULL, NULL, &err);
        if (o2) { ok = o2[0]; tmo = o2[1]; p_clEnqueueUnmapMemObject(q, mout, o2, 0, NULL, NULL); }
        else { fprintf(stderr, "map mout(read) err=%d\n", err); return 1; }
        printf("  N=%3u: rc=%d %s (%.2f ms)\n", n, rc,
               ok == 1 ? "ALIVE" : (tmo == 2 ? "TIMEOUT(自旋退出)" : "FAIL"), dt);
        if (ok != 1) break;
        alive_max = n; alive_ms = dt / rounds;
    }

    printf("[verdict] 自同步栅栏最大存活 WG 数 = %u（每轮 %.3f ms）；CU=%u\n",
           alive_max, alive_ms, cus);
    printf("[verdict] device enqueue 路线②: %s\n",
           (de2 && qprops_ok) || de_ext ? "待深探（版本/队列在场）" : "不可用（路线①自同步为主）");

    /* cl_qcom_recordable_queues 深探：线① vendor 单提交复活线索（A6b KHR 判死后） */
    int rq_ext = has(dext, "cl_qcom_recordable_queues");
    fn_crq_qcom p_crq = (fn_crq_qcom) sym("clCreateRecordableQueueQCOM");
    fn_pb_qcom  p_pb  = (fn_pb_qcom)  sym("clEnqueuePlaybackQCOM");
    printf("[qcom] cl_qcom_recordable_queues: 扩展 %s, clCreateRecordableQueueQCOM %s, clEnqueuePlaybackQCOM %s\n",
           rq_ext ? "Y" : "N", p_crq ? "Y" : "N", p_pb ? "Y" : "N");
    double rq_base_us = -1, rq_replay_us = -1;
    const int nlan = 1024, reps = 64;
    if (rq_ext && p_crq && p_pb) {
        cl_kernel kn = p_clCreateKernel(prog, "g0_nop", &err);
        if (!kn) printf("[qcom] clCreateKernel(g0_nop) err=%d\n", err);
        else {
            p_clSetKernelArg(kn, 0, sizeof(cl_mem), &mout);
            size_t ng = 64, nl = 64;
            /* 基线：逐条提交 nlan 次（decode 今天的形态） */
            p_clFinish(q);
            double b0 = now_ms();
            for (int i = 0; i < nlan; i++)
                p_clEnqueueNDRangeKernel(q, kn, 1, NULL, &ng, &nl, 0, NULL, NULL);
            double b1 = now_ms();
            p_clFinish(q);
            rq_base_us = (b1 - b0) * 1000.0 / nlan;
            printf("[qcom] 基线逐条 %d 次: host %.2f ms → %.2f µs/launch\n", nlan, b1 - b0, rq_base_us);
            /* 录制 → 重放 */
            cl_int rerr = 0;
            cl_command_queue rq = p_crq(ctx, dev, 0, &rerr);
            if (!rq) printf("[qcom] clCreateRecordableQueueQCOM err=%d\n", rerr);
            else {
                int okrec = 1;
                for (int i = 0; i < nlan; i++)
                    if (p_clEnqueueNDRangeKernel(rq, kn, 1, NULL, &ng, &nl, 0, NULL, NULL) != CL_SUCCESS) { okrec = 0; break; }
                if (!okrec) printf("[qcom] 录制失败\n");
                else {
                    double r0 = now_ms();
                    int okpb = 1; cl_int prc = 0; int done = 0;
                    for (int r = 0; r < reps; r++) {
                        prc = p_pb(rq, q, 0, NULL, NULL);
                        if (prc != CL_SUCCESS) { done = r + 1; okpb = 0; break; }
                    }
                    double r1 = now_ms();
                    p_clFinish(q);
                    if (!okpb) printf("[qcom] playback 失败 rc=%d（第 %d 次）\n", prc, done);
                    else {
                        rq_replay_us = (r1 - r0) * 1000.0 / reps;
                        printf("[qcom] record %d 条 OK；playback %d 次: host %.2f ms → %.3f µs/replay（摊 %.4f µs/launch）\n",
                               nlan, reps, r1 - r0, rq_replay_us, rq_replay_us / nlan);
                    }
                }
                p_clReleaseCommandQueue(rq);
            }
            p_clReleaseKernel(kn);
        }
    }
    printf("[verdict] recordable_queues 单提交(线①'): %s\n",
           rq_replay_us > 0 ? "成立——vendor 单提交路径复活，接 C1/巨核编排" :
           (rq_ext ? "扩展在但未跑成（看上方错误）" : "不可用（与 KHR 同判死）"));

    printf("[BENCH] mode=probe stack=S-VOCL model=tiny dev=%s la=1 thermal=warm ngl=0 kv=na "
           "ubatch=0 build=cl_g0_probe prompt=probe leg=1/1 tok=0 metric=g0form tps=0 "
           "alive_wg_max=%u us_per_barrier_round=%.2f de=%d rq_ext=%d us_per_launch=%.2f us_per_replay_of_%d=%.3f\n",
           devtag, alive_max, alive_ms * 1000.0, (de2 && qprops_ok) || de_ext ? 1 : 0,
           rq_ext ? 1 : 0, rq_base_us, nlan, rq_replay_us);

    p_clReleaseMemObject(mctr); p_clReleaseMemObject(marr); p_clReleaseMemObject(mout);
    p_clReleaseKernel(k); p_clReleaseProgram(prog); p_clReleaseCommandQueue(q); p_clReleaseContext(ctx);
    return 0;
}
