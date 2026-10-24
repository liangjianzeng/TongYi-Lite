/* cl_cc_probe.c -- 设备侧 OpenCL **编译门**探针（G-734）
 *
 * 为什么需要它：AGENTS 铁律——`.cl` 里 `half` 当变量名会让 Adreno 编译器
 * clBuildProgram 失败（err=-11 cannot combine with previous 'int' declaration
 * specifier），而 **NDK 交叉编译过 / 桌面 NEO 过都不代表 Adreno 过**，错误只在真机
 * logcat 里滚一遍就没了。以前要验编译门必须重编 libggml-opencl.so + 装 APK，代价太大，
 * 于是"先写完再发现编不过"。这个探针把编译门变成一个几十秒的独立实验：**不动
 * third_party/llama.cpp 一行**，直接把 .cl 喂给目标驱动的 clBuildProgram。
 *
 * 用法（设备上）：
 *   cl_cc_probe                      # 只出能力清单（扩展位，含 dp4a 真相）
 *   cl_cc_probe foo.cl               # 能力清单 + 编译 foo.cl，打印完整 build log
 * 环境：
 *   PROBE_OCL=/path/libOpenCL.so     # dlopen 哪个 ICD（vendor 或我们自带的 Mesa）
 *   PROBE_DEV=Adreno|rasticl|freedreno   # 按设备名子串选卡
 *   PROBE_OPTS=-cl-std=CL2.0 ...     # clBuildProgram 选项
 * 退出码：0 编译通过 / 1 编译失败 / 2 选不到设备 / 3 读文件失败 / 4 dlopen 失败
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <CL/cl.h>

static void *h;
#define FP(ret, name, args) typedef ret(CL_API_ENTRY *fn_##name) args; static fn_##name p_##name;
FP(cl_int, clGetPlatformIDs, (cl_uint, cl_platform_id *, cl_uint *))
FP(cl_int, clGetPlatformInfo, (cl_platform_id, cl_platform_info, size_t, void *, size_t *))
FP(cl_int, clGetDeviceIDs, (cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *))
FP(cl_int, clGetDeviceInfo, (cl_device_id, cl_device_info, size_t, void *, size_t *))
FP(cl_context, clCreateContext, (const cl_context_properties *, cl_uint, const cl_device_id *, void (*)(const char *, const void *, size_t, void *), void *, cl_int *))
FP(cl_program, clCreateProgramWithSource, (cl_context, cl_uint, const char **, const size_t *, cl_int *))
FP(cl_int, clBuildProgram, (cl_program, cl_uint, const cl_device_id *, const char *, void (*)(cl_program, void *), void *))
FP(cl_int, clGetProgramBuildInfo, (cl_program, cl_device_id, cl_program_build_info, size_t, void *, size_t *))
FP(cl_int, clGetProgramInfo, (cl_program, cl_program_info, size_t, void *, size_t *))
FP(cl_int, clReleaseProgram, (cl_program))
FP(cl_int, clReleaseContext, (cl_context))

/* ICD 形态的驱动（我们的 Mesa/rusticl）只把少数入口放成导出符号，其余要用 Khronos ICD
   的扩展函数查询拿。只 dlsym 会把"驱动好好的"误判成"驱动不可用"——本轮就撞过一次。 */
typedef void *(*eafp_t)(cl_platform_id, const char *);
typedef void *(*ea_t)(const char *);
static eafp_t g_eafp; static ea_t g_ea; static cl_platform_id g_plat;
static void *sym(const char *n) {
    void *p = dlsym(h, n);
    if (!p && g_eafp && g_plat) p = g_eafp(g_plat, n);
    if (!p && g_ea) p = g_ea(n);
    return p;
}
#define LOAD(n) do { p_##n = (fn_##n) sym(#n); if (!p_##n) { fprintf(stderr, "FATAL: 取不到 %s（非导出符号，也不是 ICD 扩展函数）\n", #n); return 4; } } while (0)

static char *dupinfo(cl_device_id d, cl_device_info k) {
    size_t n = 0; static char buf[8192]; buf[0] = 0;
    if (p_clGetDeviceInfo(d, k, sizeof(buf), buf, &n) != CL_SUCCESS) strcpy(buf, "<err>");
    return buf;
}
static int has(const char *exts, const char *e) { return strstr(exts, e) != NULL; }

int main(int argc, char **argv) {
    const char *lib = getenv("PROBE_OCL"); if (!lib || !*lib) lib = "libOpenCL.so";
    h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "FATAL: dlopen(%s) = %s\n", lib, dlerror()); return 4; }
    /* ICD 驱动（我们的 Mesa/rusticl）只导出 clIcdGetPlatformIDsKHR，没有 clGetPlatformIDs：
       直接 dlsym 会假失败，症状像"驱动不可用"。这里两条路都试。 */
    p_clGetPlatformIDs = (fn_clGetPlatformIDs) dlsym(h, "clGetPlatformIDs");
    if (!p_clGetPlatformIDs) p_clGetPlatformIDs = (fn_clGetPlatformIDs) dlsym(h, "clIcdGetPlatformIDsKHR");
    if (!p_clGetPlatformIDs) { fprintf(stderr, "FATAL: 既无 clGetPlatformIDs 也无 clIcdGetPlatformIDsKHR\n"); return 4; }
    g_eafp = (eafp_t) dlsym(h, "clGetExtensionFunctionAddressForPlatform");
    g_ea  = (ea_t) dlsym(h, "clGetExtensionFunctionAddress");
    { cl_uint np = 0; if (p_clGetPlatformIDs(1, &g_plat, &np) != CL_SUCCESS || !np) { fprintf(stderr, "FATAL: 探平台失败\n"); return 2; } }
    LOAD(clGetPlatformInfo); LOAD(clGetDeviceIDs); LOAD(clGetDeviceInfo);
    LOAD(clCreateContext); LOAD(clCreateProgramWithSource); LOAD(clBuildProgram);
    LOAD(clGetProgramBuildInfo); LOAD(clGetProgramInfo); LOAD(clReleaseProgram); LOAD(clReleaseContext);

    cl_platform_id pl[8]; cl_uint npl = 0;
    if (p_clGetPlatformIDs(8, pl, &npl) != CL_SUCCESS || npl == 0) { fprintf(stderr, "FATAL: no platform\n"); return 2; }
    cl_device_id dev[8]; cl_uint nd = 0;
    for (cl_uint i = 0; i < npl && nd == 0; i++)
        p_clGetDeviceIDs(pl[i], CL_DEVICE_TYPE_ALL, 8, dev, &nd);
    if (!nd) { fprintf(stderr, "FATAL: no device\n"); return 2; }

    const char *want = getenv("PROBE_DEV");
    cl_device_id d = dev[0];
    if (want && *want) {
        for (cl_uint i = 0; i < nd; i++)
            if (strstr(dupinfo(dev[i], CL_DEVICE_NAME), want)) { d = dev[i]; break; }
        if (!strstr(dupinfo(d, CL_DEVICE_NAME), want)) { fprintf(stderr, "FATAL: 没有名字含 '%s' 的设备\n", want); return 2; }
    }

    /* ---------- 能力清单（dp4a 的真相就在这里，不在内核源码的 #ifdef 里）---------- */
    char *name = strdup(dupinfo(d, CL_DEVICE_NAME));
    char *exts = strdup(dupinfo(d, CL_DEVICE_EXTENSIONS));
    printf("libOpenCL=%s\n", lib);
    printf("device   =%s\n", name);
    printf("version  =%s\n", dupinfo(d, CL_DEVICE_VERSION));
    printf("driver   =%s\n", dupinfo(d, CL_DRIVER_VERSION));
    printf("vendor   =%s\n", dupinfo(d, CL_DEVICE_VENDOR));
    cl_uint cu = 0; p_clGetDeviceInfo(d, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(cu), &cu, NULL);
    printf("CUs      =%u\n", cu);
    size_t wgs = 0; p_clGetDeviceInfo(d, CL_DEVICE_MAX_WORK_GROUP_SIZE, sizeof(wgs), &wgs, NULL);
    printf("maxWG    =%zu\n", wgs);
    /* MoE 平面生产端有一道 `*_layer %% backend_ctx->alignment == 0` 的静默整除守卫
       （ggml-opencl.cpp:12365 起）。Ling 的专家层 d_layer = Mc*Kc/128 = 6144 B：
       6144%%1024==0 但 6144%%4096!=0 ⇒ alignment 一个数就能让整块平面消失、batched 静默回落。
       所以 alignment 是编译/派发门的必量项，不是可选项。 */
    size_t balign = 0;
    p_clGetDeviceInfo(d, CL_DEVICE_MEM_BASE_ADDR_ALIGN, sizeof(balign), &balign, NULL);
    printf("memBaseAddrAlign =%zu B\n", balign);   /* CL_DEVICE_MEM_CACHELINE_SIZE 属 cl_ext_device_fission，非核心，不查 */
    printf("-- 扩展位（决定内核哪条路活着）--\n");
    const char *watch[] = {"cl_khr_fp16", "cl_khr_subgroups", "cl_khr_subgroup_shuffle",
                           "cl_khr_integer_dot_product", "cl_intel_required_subgroup_size",
                           "cl_intel_subgroups", "cl_khr_int64_base_atomics", "cl_khr_fp64", NULL};
    for (int i = 0; watch[i]; i++) printf("  %-32s %s\n", watch[i], has(exts, watch[i]) ? "YES" : "**NO**");
    printf("all_exts =%s\n", exts);

    if (argc < 2) { printf("(未给 .cl，只出能力清单)\n"); return 0; }

    /* ---------- 编译门 ---------- */
    FILE *f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "FATAL: 打不开 %s\n", argv[1]); return 3; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    char *src = (char *) malloc(sz + 1); if (!src) return 3;
    if (fread(src, 1, sz, f) != (size_t) sz) { fclose(f); free(src); return 3; }
    src[sz] = 0; fclose(f);

    const char *opts = getenv("PROBE_OPTS"); if (!opts) opts = "";
    cl_int e = CL_SUCCESS;
    cl_context cx = p_clCreateContext(NULL, 1, &d, NULL, NULL, &e);
    if (!cx || e != CL_SUCCESS) { fprintf(stderr, "FATAL: context err=%d\n", e); return 2; }
    cl_program pr = p_clCreateProgramWithSource(cx, 1, (const char **) &src, (const size_t *) &(long){ sz }, &e);
    if (!pr || e != CL_SUCCESS) { fprintf(stderr, "FATAL: program err=%d\n", e); p_clReleaseContext(cx); return 3; }
    cl_int be = p_clBuildProgram(pr, 1, &d, opts, NULL, NULL);
    size_t ln = 0; p_clGetProgramBuildInfo(pr, d, CL_PROGRAM_BUILD_LOG, 0, NULL, &ln);
    char *log = (char *) malloc(ln + 2); log[0] = 0;
    if (ln > 1) p_clGetProgramBuildInfo(pr, d, CL_PROGRAM_BUILD_LOG, ln, log, NULL);
    printf("-- 编译门 --\nsrc=%s (%ld B) opts='%s' clBuildProgram=%d\n", argv[1], sz, opts, be);
    if (log[0]) printf("BUILD LOG:\n%s\n", log);
    if (be != CL_SUCCESS) { printf("VERDICT=COMPILE_FAIL\n"); free(log); free(src); p_clReleaseProgram(pr); p_clReleaseContext(cx); return 1; }
    cl_uint nk = 0; p_clGetProgramInfo(pr, CL_PROGRAM_NUM_KERNELS, sizeof(nk), &nk, NULL);
    printf("kernels=%u\nVERDICT=COMPILE_OK\n", nk);
    free(log); free(src); p_clReleaseProgram(pr); p_clReleaseContext(cx);
    return 0;
}
