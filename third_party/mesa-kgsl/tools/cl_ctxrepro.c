/* [路 A 诊断] ggml clCreateContext(properties,...) SIGILL 最小复现：
 * 与 cl_subgroup_hangtest 的差别 = 我们显式传 CL_CONTEXT_PLATFORM 属性数组 +
 * num_devices>1 选项。逐档加深（props NULL → props plat → n=2 dup），
 * 崩在哪档 = rusticl 哪段在 glibc 运行时下炸。 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CL/cl.h>

typedef cl_int (*fn_gp)(cl_uint, cl_platform_id *, cl_uint *);
typedef cl_int (*fn_gd)(cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *);
typedef cl_context (*fn_cc)(const cl_context_properties *, cl_uint, const cl_device_id *, void (*)(const char *, const void *, size_t, void *), void *, cl_int *);

int main(int argc, char ** argv) {
    int stage = argc > 1 ? atoi(argv[1]) : 1;
    void *h = dlopen("libOpenCL.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) h = dlopen("libOpenCL.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "dlopen fail %s\n", dlerror()); return 2; }
    fn_gp gp = (fn_gp) dlsym(h, "clGetPlatformIDs");
    fn_gd gd = (fn_gd) dlsym(h, "clGetDeviceIDs");
    fn_cc cc = (fn_cc) dlsym(h, "clCreateContext");
    cl_platform_id pf; cl_uint np = 0;
    printf("platforms rc=%d n=%u\n", gp(1, &pf, &np), np);
    cl_device_id devs[4]; cl_uint nd = 0;
    printf("devices rc=%d n=%u\n", gd(pf, CL_DEVICE_TYPE_GPU, 4, devs, &nd), nd);
    fflush(stdout);

    cl_int err = -99;
    cl_context ctx = NULL;
    if (stage == 0) {
        printf("stage0 props=NULL\n"); fflush(stdout);
        ctx = cc(NULL, 1, devs, NULL, NULL, &err);
    } else if (stage == 1) {
        cl_context_properties props[3] = { CL_CONTEXT_PLATFORM, (cl_context_properties) pf, 0 };
        printf("stage1 props=[PLATFORM,plat]\n"); fflush(stdout);
        ctx = cc(props, 1, devs, NULL, NULL, &err);
    } else {
        cl_context_properties props[3] = { CL_CONTEXT_PLATFORM, (cl_context_properties) pf, 0 };
        cl_device_id two[2] = { devs[0], devs[0] };
        printf("stage2 dup n=2\n"); fflush(stdout);
        ctx = cc(props, 2, two, NULL, NULL, &err);
    }
    printf("clCreateContext err=%d ctx=%p\n", err, (void *) ctx);
    return err == CL_SUCCESS ? 0 : 3;
}
