// 构建（DGX linux-aarch64，NDK r27 已验证一行过）：
//   DK=$HOME/android-sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-aarch64
//   $DK/bin/aarch64-linux-android28-clang --sysroot=$DK/sysroot -shared -fPIC -O2 \
//     -o libtylgrp.so third_party/mesa-kgsl/tools/cl_relpair.c \
//     -I third_party/OpenCL-Headers -DCL_TARGET_OPENCL_VERSION=300
// 产物 md5(21:24 版)=libtylgrp.so aarch64 9176B；部署=push 到 $R/bin/，腿经
// EXTRAENV 'TYL_E4_GRP=1 LD_PRELOAD=$R/bin/libtylgrp.so' 注入（routeA_e4_legs.sh g7/fix8g 案例）。
/* [TongYi-Lite E4-G grp 垫片] cl_mem release→re-alloc 配对计数（LD_PRELOAD）。
 * 判 ggml 释放配对缺陷 / buffer 生命周期真相：
 *   E4GRELPAIR mem= sz= dist= rt=  —— 同一 cl_mem 指针在释放后 dist 个事件内重新出现
 *   E4GPOL created= released= repaired=  —— atexit 总结（released≈0 ⇒ ggml 全生命周期缓存，
 *                                            在飞复用只可能发生在 Mesa 侧内部分配）
 * 门控：TYL_E4=1 且 TYL_E4_GRP=1。仅诊断，不进背书腿。 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <CL/cl.h>

static int grp_on = -1;
static long c_created = 0, c_released = 0, c_repaired = 0, seq = 0;

#define RTAB 4096
struct rel { cl_mem m; size_t sz; long seq; };
static struct rel rtab[RTAB];

static unsigned long long ns_now(void) {
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static void rput(cl_mem m, size_t sz) {
    unsigned h = (unsigned)((uintptr_t)m / 8) % RTAB;
    for (unsigned i = 0; i < 8; i++) {
        struct rel *e = &rtab[(h + i) % RTAB];
        if (!e->m || e->m == m) { e->m = m; e->sz = sz; e->seq = seq; return; }
    }
}
static struct rel *rget(cl_mem m) {
    unsigned h = (unsigned)((uintptr_t)m / 8) % RTAB;
    for (unsigned i = 0; i < 8; i++) {
        struct rel *e = &rtab[(h + i) % RTAB];
        if (!e->m) return NULL;
        if (e->m == m) return e;
    }
    return NULL;
}

static void atexit_report(void) {
    if (grp_on == 1)
        fprintf(stderr, "E4GPOL created=%ld released=%ld repaired=%ld seq=%ld\n",
                c_created, c_released, c_repaired, seq);
    fflush(stderr);
}

typedef cl_mem (*fn_create)(cl_context, cl_mem_flags, size_t, void *, cl_int *);
typedef cl_mem (*fn_create_props)(cl_context, cl_mem_properties *, cl_mem_flags,
                                  size_t, void *, cl_int *);
typedef cl_int (*fn_release)(cl_mem);

CL_API_ENTRY cl_mem CL_API_CALL
clCreateBuffer(cl_context c, cl_mem_flags f, size_t sz, void *p, cl_int *e) {
    static fn_create r; if (!r) r = (fn_create)dlsym(RTLD_NEXT, "clCreateBuffer");
    cl_mem m = r(c, f, sz, p, e);
    if (grp_on < 0) grp_on = (getenv("TYL_E4") && getenv("TYL_E4_GRP") &&
        getenv("TYL_E4")[0]=='1' && getenv("TYL_E4_GRP")[0]=='1') ? 1 : 0;
    seq++; c_created++;
    if (grp_on && m && e && *e == CL_SUCCESS) {
        struct rel *re = rget(m);
        if (re) {
            c_repaired++;
            fprintf(stderr, "E4GRELPAIR mem=%p sz=%zu dist=%ld rt=%llu\n",
                    (void *)m, sz, seq - re->seq, ns_now());
            re->m = NULL;
        }
    }
    return m;
}

CL_API_ENTRY cl_mem CL_API_CALL
clCreateBufferWithProperties(cl_context c, const cl_mem_properties *pr,
                             cl_mem_flags f, size_t sz, void *p, cl_int *e) {
    static fn_create_props r;
    if (!r) r = (fn_create_props)dlsym(RTLD_NEXT, "clCreateBufferWithProperties");
    if (!r) return NULL;
    cl_mem m = r(c, (cl_mem_properties *)pr, f, sz, p, e);
    if (grp_on < 0) grp_on = (getenv("TYL_E4") && getenv("TYL_E4_GRP") &&
        getenv("TYL_E4")[0]=='1' && getenv("TYL_E4_GRP")[0]=='1') ? 1 : 0;
    seq++; c_created++;
    if (grp_on && m && e && *e == CL_SUCCESS) {
        struct rel *re = rget(m);
        if (re) {
            c_repaired++;
            fprintf(stderr, "E4GRELPAIR mem=%p sz=%zu dist=%ld rt=%llu\n",
                    (void *)m, sz, seq - re->seq, ns_now());
            re->m = NULL;
        }
    }
    return m;
}

CL_API_ENTRY cl_int CL_API_CALL
clReleaseMemObject(cl_mem m) {
    static fn_release r; if (!r) r = (fn_release)dlsym(RTLD_NEXT, "clReleaseMemObject");
    if (grp_on == 1 && m) { c_released++; rput(m, 0); }
    return r(m);
}

__attribute__((constructor)) static void init(void) { atexit(atexit_report); }
