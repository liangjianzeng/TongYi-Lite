// cl_alloc_probe: find the largest single clCreateBuffer the active OpenCL stack will give
// us, and report it next to the current MemAvailable. Needed because ggml-opencl aborts
// model load on a single 1044893696 B allocation (err=-5) on vendor Adreno 650, and the
// size is invariant to n_batch and n_ctx, so we must know the ceiling, not guess the owner.
// Build: NDK clang, arm64. Run with PROBE_OCL=<path to libOpenCL.so>.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef void * cl_device_id;
typedef void * cl_context;
typedef void * cl_mem;
typedef int    cl_int;
typedef unsigned int cl_uint;

static cl_int (*p_clGetPlatformIDs)(cl_int, cl_device_id *, cl_int *);
static cl_int (*p_clGetDeviceIDs)(cl_device_id, cl_int, cl_int, cl_device_id *, cl_int *);
static cl_context (*p_clCreateContext)(const cl_int *, cl_int, const cl_device_id *, void (*)(const char *, const void *, size_t, void *), void *, cl_int *);
static cl_mem (*p_clCreateBuffer)(cl_context, cl_int, size_t, void *, cl_int *);
static cl_int (*p_clReleaseMemObject)(cl_mem);
static cl_int (*p_clGetDeviceInfo)(cl_device_id, cl_int, size_t, void *, size_t *);

#define CL_DEVICE_TYPE_ALL 0x1000
#define CL_MEM_READ_WRITE  1
#define CL_DEVICE_MAX_MEM_ALLOC_SIZE 0x1028
#define CL_DEVICE_GLOBAL_MEM_SIZE    0x101F

static size_t read_meminfo_kb(const char * key) {
    FILE * f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    char line[256];
    size_t v = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, strlen(key)) == 0) { sscanf(line + strlen(key), " %zu", &v); break; }
    }
    fclose(f);
    return v;
}

int main(void) {
    const char * ocl = getenv("PROBE_OCL");
    if (!ocl || !ocl[0]) ocl = "/vendor/lib64/libOpenCL.so";
    void * h = dlopen(ocl, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("FATAL dlopen %s: %s\n", ocl, dlerror()); return 2; }
    *(void **) &p_clGetPlatformIDs  = dlsym(h, "clGetPlatformIDs");
    *(void **) &p_clGetDeviceIDs    = dlsym(h, "clGetDeviceIDs");
    *(void **) &p_clCreateContext   = dlsym(h, "clCreateContext");
    *(void **) &p_clCreateBuffer    = dlsym(h, "clCreateBuffer");
    *(void **) &p_clReleaseMemObject= dlsym(h, "clReleaseMemObject");
    *(void **) &p_clGetDeviceInfo   = dlsym(h, "clGetDeviceInfo");
    if (!p_clGetPlatformIDs || !p_clGetDeviceIDs || !p_clCreateContext || !p_clCreateBuffer || !p_clReleaseMemObject) {
        printf("FATAL missing core symbols in %s\n", ocl); return 2;
    }
    cl_device_id plats[8]; cl_int np = 0;
    cl_int rcp = p_clGetPlatformIDs(8, plats, &np);
    printf("clGetPlatformIDs(8,..) rc=%d np=%d plat0=%p\n", rcp, np, (void *) plats[0]);
    cl_device_id d = NULL; cl_int n = 0;
    for (cl_int i = 0; i < np && !d; i++) {
        if (!plats[i]) continue;
        cl_device_id devs[8]; cl_uint got = 0;
        cl_int rcd = p_clGetDeviceIDs(plats[i], CL_DEVICE_TYPE_ALL, 8, devs, &got);
        printf("  clGetDeviceIDs(plat %d) rc=%d got=%u\n", (int) i, rcd, got);
        if (rcd == 0 && got > 0) d = devs[0];
    }
    if (!d) {
        // Vendor libOpenCL.so is the Khronos ICD loader: plain clGetPlatformIDs can hand back
        // a platform with no enumerable devices. Same fallback the compile probe needed.
        typedef cl_int (*icd_get_t)(cl_uint, cl_device_id *, cl_uint *);
        icd_get_t icd = (icd_get_t) dlsym(h, "clIcdGetPlatformIDsKHR");
        if (!icd) icd = (icd_get_t) (size_t) 0;
        if (icd && icd(8, plats, &np) == 0) {
            for (cl_int i = 0; i < np && !d; i++) {
                if (!plats[i]) continue;
                cl_device_id devs[8]; cl_uint got = 0;
        cl_int rcd = p_clGetDeviceIDs(plats[i], CL_DEVICE_TYPE_ALL, 8, devs, &got);
        printf("  clGetDeviceIDs(plat %d) rc=%d got=%u\n", (int) i, rcd, got);
        if (rcd == 0 && got > 0) d = devs[0];
            }
        }
    }
    if (!d) { printf("FATAL no device (platforms=%d)\n", np); return 2; }

    size_t maxalloc = 0, gmem = 0;
    if (p_clGetDeviceInfo) {
        p_clGetDeviceInfo(d, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(maxalloc), &maxalloc, NULL);
        p_clGetDeviceInfo(d, CL_DEVICE_GLOBAL_MEM_SIZE,    sizeof(gmem),    &gmem,    NULL);
    }
    printf("libOpenCL=%s\n", ocl);
    printf("CL_DEVICE_MAX_MEM_ALLOC_SIZE = %zu B (%.2f GiB)   CL_DEVICE_GLOBAL_MEM_SIZE = %zu B (%.2f GiB)\n",
           maxalloc, maxalloc / 1073741824.0, gmem, gmem / 1073741824.0);
    printf("/proc/meminfo MemAvailable = %zu MiB  MemFree = %zu MiB\n",
           read_meminfo_kb("MemAvailable:") / 1024, read_meminfo_kb("MemFree:") / 1024);

    cl_int rc = 0;
    cl_context ctx = p_clCreateContext(NULL, 1, &d, NULL, NULL, &rc);
    if (!ctx || rc != 0) { printf("FATAL clCreateContext rc=%d\n", rc); return 2; }

    // The exact size that kills model load, then a descending scan for the ceiling.
    const size_t killer = 1044893696u;
    rc = 0;
    cl_mem m = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, killer, NULL, &rc);
    printf("single alloc %zu B (the model-load killer): rc=%d %s\n", killer, rc, rc == 0 ? "OK" : "FAIL");
    if (m) p_clReleaseMemObject(m);

    size_t sizes[] = { 2147483648u, 1610612736u, 1073741824u, 805306368u, 536870912u, 268435456u, 134217728u, 0 };
    for (int i = 0; sizes[i]; i++) {
        rc = 0;
        cl_mem b = p_clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizes[i], NULL, &rc);
        printf("  %12zu B (%6.2f GiB): rc=%d %s\n", sizes[i], sizes[i] / 1073741824.0, rc, rc == 0 ? "OK" : "FAIL");
        if (b) p_clReleaseMemObject(b);
        if (rc == 0) break;   // first success is the ceiling we care about
    }
    printf("VERDICT=ALLOC_PROBE_DONE\n");
    return 0;
}
