/*
 * vkh_imagecap.c — IMAGE 能力探针（R-117，vkh 枪族；父腿侧 740 先跑，先于任何 diff）
 *
 * 为什么存在：
 *   batched MoE 的 q_img 是 CL_MEM_OBJECT_IMAGE1D_BUFFER，宽度 = E*q_layer/4。
 *   LFM2.5-24B 需要 image_width = 25 165 824 px（ling 已跑通的 12 582 912 px 的 2 倍）。
 *   CL_DEVICE_IMAGE_MAX_BUFFER_SIZE 是硬闸 ⇒ 不够则 A 路（子缓冲 origin 平移）直接死刑，
 *   必须在编译任何 diff 之前测出来。
 *
 * 关键防呆（哑火线 #25）：**必须与腿同驱动栈**。740 的腿跑在 glibc CLRT sysroot + Mesa ICD
 *   （/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/etc/OpenCL/vendors），不是 Android
 *   /vendor/lib64/libOpenCL.so。若探针 dlopen 了 vendor 驱动，测出来的是 Adreno 闭源驱动
 *   的闸 = 假 PASS。故：打印真实加载路径 + vendor/driver 串，非 Mesa 即红牌 ABORT。
 *
 * 三个测项（全部真跑，不看声明看实测）：
 *   (1) 设备能力：IMAGE_SUPPORT / IMAGE_MAX_BUFFER_SIZE / IMAGE_MAX_ARRAY_SIZE /
 *       MAX_MEM_ALLOC_SIZE / GLOBAL_MEM_SIZE / MAX_WORK_ITEM_SIZES[0]
 *   (2) 真实 clCreateImage 阶梯：ling 宽度 12 582 912 与 LFM 闸门宽度 25 165 824，
 *       对 q_img(CL_R/CL_UNSIGNED_INT32)、d_img(CL_R/CL_HALF_FLOAT)、b_img(CL_RGBA/CL_FLOAT)
 *       三种格式各测一次（真分配 backing buffer，测完即放）
 *   (3) **A 路专属前置**：在"多槽位基座"上取 origin=es_base*q_layer 的**子缓冲**，
 *       再对该子缓冲 clCreateImage —— 这正是 A 路的姿势；rusticl 若不支持
 *       "image over sub-buffer" 或强制 origin 对齐，这里当场见光。
 *       另测一个故意不对齐的 origin 作为**阴性对照**（期望失败；若也成功说明对齐门是摆设）。
 *
 * 输出（全部 `#### ` 前缀，父腿侧直接 grep）：
 *   #### IMAGECAP loaded=… vendor=… driver=… image_support=… max_buffer=… …
 *   #### IMAGEPROBE tag=… kind=… fmt=… width=… bytes=… rc=…
 *   #### IMAGECAP_VERDICT ling=PASS|FAIL lfm=PASS|FAIL a_route=PASS|FAIL gate=25165824
 * 退出码：0 = 全 PASS；1 = 有 FAIL（A 路不可行）；2 = 探针自身无效（红牌，结论作废）
 *
 * 可调（免重编）：VKH_IC_Q_LAYER(默认 1572864) VKH_IC_E(64) VKH_IC_ES_BASE(32)
 *   VKH_IC_LING_W(12582912) VKH_IC_LFM_W(25165824) VKH_IC_LIB(强制 libOpenCL 路径)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

#ifndef CL_TARGET_OPENCL_VERSION
#define CL_TARGET_OPENCL_VERSION 300   /* rusticl = OpenCL 3.0；只影响声明可见性 */
#endif
#include <CL/cl.h>                     /* 常数唯一来源 = 树内 vendored Khronos 头（与产品库同源） */

typedef cl_int (*fn_get_platforms)(cl_uint, cl_platform_id *, cl_uint *);
typedef cl_int (*fn_get_devices)(cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *);
typedef cl_context (*fn_create_context)(const cl_context_properties *, cl_uint, const cl_device_id *,
                                          void *(CL_CALLBACK *)(const char *, const void *, size_t, void *),
                                          void *, cl_int *);                              /* 返回 cl_context！ */
typedef cl_int (*fn_get_device_info)(cl_device_id, cl_device_info, size_t, void *, size_t *);
typedef cl_int (*fn_get_platform_info)(cl_platform_id, cl_platform_info, size_t, void *, size_t *);
typedef cl_mem (*fn_create_buffer)(cl_context, cl_mem_flags, size_t, void *, cl_int *);   /* 返回 cl_mem，不是 cl_int！ */
typedef cl_mem (*fn_create_subbuffer)(cl_mem, cl_mem_flags, cl_buffer_create_type,
                                        const cl_buffer_region *, cl_int *);              /* 返回 cl_mem，不是 cl_int！ */
typedef cl_mem (*fn_create_image)(cl_context, cl_mem_flags, const cl_image_format *,
                                  const cl_image_desc *, void *, cl_int *);
typedef cl_int (*fn_release_mem)(cl_mem);
typedef cl_int (*fn_finish)(cl_command_queue);

static fn_get_platforms   p_GetPlatformIDs;
static fn_get_devices     p_GetDeviceIDs;
static fn_create_context  p_CreateContext;
static fn_get_device_info p_GetDeviceInfo;
static fn_get_platform_info p_GetPlatformInfo;
static fn_create_buffer   p_CreateBuffer;
static fn_create_subbuffer p_CreateSubBuffer;
static fn_create_image    p_CreateImage;
static fn_release_mem     p_ReleaseMemObject;

static long envl(const char *k, long d) { const char *v = getenv(k); return v && *v ? strtol(v, NULL, 10) : d; }

static int n_fail = 0, n_bad = 0;   /* n_fail=真闸不过；n_bad=探针无效 */

static void str_raw(cl_device_id d, cl_device_info q) {
    char buf[192] = {0};
    if (p_GetDeviceInfo(d, q, sizeof(buf) - 1, buf, NULL) != CL_SUCCESS) { snprintf(buf, sizeof buf, "<ERR>"); n_bad = 1; }
    fputs(buf, stdout);
    fflush(stdout);
}
static void num_info(cl_device_id d, cl_device_info q, const char *tag) {
    cl_ulong v = 0;
    if (p_GetDeviceInfo(d, q, sizeof(v), &v, NULL) != CL_SUCCESS) { v = 0; n_bad = 1; }
    printf(" %s=%llu", tag, (unsigned long long) v);
}
static void bool_info(cl_device_id d, cl_device_info q, const char *tag) {
    cl_bool v = CL_FALSE;
    if (p_GetDeviceInfo(d, q, sizeof(v), &v, NULL) != CL_SUCCESS) { n_bad = 1; }
    printf(" %s=%d", tag, (int) v);
}

/* 真建一张 IMAGE1D_BUFFER：backing buffer 现分配、测完即放 */
static int try_image(cl_context ctx, const char *tag, cl_channel_order co, cl_channel_type ct,
                     size_t px, size_t bytes_per_px, int from_sub_of, cl_mem sub) {
    cl_int err = CL_SUCCESS;
    cl_mem buf = NULL;
    cl_mem storage = sub;
    if (!from_sub_of) {
        buf = p_CreateBuffer(ctx, CL_MEM_READ_ONLY, bytes_per_px * px, NULL, &err);
        if (err != CL_SUCCESS || !buf) {
            printf("#### IMAGEPROBE tag=%s kind=direct fmt=0x%x/0x%x width=%zu bytes=%llu rc=ALLOC_%d\n",
                   tag, (unsigned) co, (unsigned) ct, px, (unsigned long long) (bytes_per_px * px), (int) err);
            return 1;
        }
        storage = buf;
    }
    cl_image_format fmt; memset(&fmt, 0, sizeof fmt);
    fmt.image_channel_order = co; fmt.image_channel_data_type = ct;
    cl_image_desc desc; memset(&desc, 0, sizeof desc);
    desc.image_type = CL_MEM_OBJECT_IMAGE1D_BUFFER;
    desc.image_width = px;
    desc.image_height = 0; desc.image_array_size = 0;
    desc.image_row_pitch = 0; desc.image_slice_pitch = 0;
    desc.num_mip_levels = 0; desc.num_samples = 0;
    desc.buffer = storage;
    cl_mem img = p_CreateImage(ctx, CL_MEM_READ_ONLY, &fmt, &desc, NULL, &err);
    printf("#### IMAGEPROBE tag=%s kind=%s fmt=0x%x/0x%x width=%zu bytes=%llu rc=%d\n",
           tag, from_sub_of ? "subbuf_origin" : "direct", (unsigned) co, (unsigned) ct, px,
           (unsigned long long) (bytes_per_px * px), (int) err);
    if (img) p_ReleaseMemObject(img);
    if (buf) p_ReleaseMemObject(buf);
    if (err != CL_SUCCESS) { n_fail = 1; return 1; }
    return 0;
}

int main(int argc, char **argv) {
    (void) argc; (void) argv;
    setvbuf(stdout, NULL, _IONBF, 0);   // [father 2026-10-28] SEGV 尸检: 无缓冲, 行不随崩溃丢
    const long q_layer  = envl("VKH_IC_Q_LAYER", 1572864L);    /* LFM: M*(K/4)*2 = 1536*512*2 */
    const long E        = envl("VKH_IC_E",        64L);
    const long es_base  = envl("VKH_IC_ES_BASE",  32L);
    const long ling_w   = envl("VKH_IC_LING_W",   12582912L);  /* ling 已跑通的 q_img 宽度 */
    const long lfm_w    = envl("VKH_IC_LFM_W",    25165824L);  /* LFM 需要的宽度 = 硬闸 */

    /* ---- 与腿同驱动栈：优先 VKH_IC_LIB，再 ICD 加载器，最后 Android 面 TONGYILITE_LIBOPENCL ---- */
    const char *cands[5]; int nc = 0;
    const char *forced = getenv("VKH_IC_LIB");
    if (!forced) forced = getenv("TONGYILITE_LIBOPENCL");
    if (forced && *forced) cands[nc++] = forced;
    cands[nc++] = "libOpenCL.so.1";      /* CLRT/Mesa ICD 加载器（腿用的就是这个） */
    cands[nc++] = "libOpenCL.so";
    cands[nc++] = "/vendor/lib64/libOpenCL.so";   /* 最后兜底；若非 Mesa 会被红牌拦下 */
    cands[nc] = NULL;

    void *h = NULL; const char *loaded = "<none>";
    for (int i = 0; i < nc; i++) {
        void *t = dlopen(cands[i], RTLD_NOW | RTLD_GLOBAL);
        if (!t) continue;
        p_GetPlatformIDs = (fn_get_platforms) dlsym(t, "clGetPlatformIDs");
        if (!p_GetPlatformIDs) { dlclose(t); continue; }
        cl_uint np = 0;
        if (p_GetPlatformIDs(0, NULL, &np) != CL_SUCCESS || np == 0) { dlclose(t); continue; } /* 哑火：代理库能 dlopen 但 0 platform */
        h = t; loaded = cands[i]; break;
    }
    if (!h) { printf("#### IMAGECAP_ABORT_NO_BACKEND\n"); return 2; }

    printf("#### IMAGECAP loaded=%s\n", loaded);
    /* [father 2026-10-28 哑火#26] 全符号 dlsym + NULL 红牌: 原枪只 sym 了 GetPlatformIDs,
       其余 p_* 全 NULL——首个 p_GetPlatformInfo(NULL) 即 SEGV。缺一符号=结论作废, 不放行。*/
    {   struct { void **slot; const char *sym; } syms[] = {
            { (void**)&p_GetDeviceIDs,    "clGetDeviceIDs"    },
            { (void**)&p_GetPlatformInfo, "clGetPlatformInfo" },
            { (void**)&p_GetDeviceInfo,   "clGetDeviceInfo"   },
            { (void**)&p_CreateContext,   "clCreateContext"   },
            { (void**)&p_CreateBuffer,    "clCreateBuffer"    },
            { (void**)&p_CreateSubBuffer, "clCreateSubBuffer" },
            { (void**)&p_CreateImage,     "clCreateImage"     },
            { (void**)&p_ReleaseMemObject,"clReleaseMemObject"},
            { NULL, NULL } };
        for (int i = 0; syms[i].slot; i++) {
            *syms[i].slot = dlsym(h, syms[i].sym);
            if (!*syms[i].slot) { printf("#### IMAGECAP_ABORT_MISSING_SYM %s\n", syms[i].sym); return 2; }
        }
    }

    /* platform/vendor/driver —— 驱动归属证明（哑火 #25） */
    cl_platform_id pl = NULL; { cl_uint np = 0; p_GetPlatformIDs(1, &pl, &np); }
    char pbuf[128] = {0}, vbuf[128] = {0}, dbuf[128] = {0};
    p_GetPlatformInfo(pl, CL_PLATFORM_VENDOR,  sizeof(pbuf) - 1, pbuf, NULL);
    p_GetPlatformInfo(pl, CL_PLATFORM_NAME,    sizeof(vbuf) - 1, vbuf, NULL);
    p_GetPlatformInfo(pl, CL_PLATFORM_VERSION, sizeof(dbuf) - 1, dbuf, NULL);
    printf("#### IMAGECAP platform=\"%s\" vendor=\"%s\" version=\"%s\"\n", vbuf, pbuf, dbuf);

    cl_device_id dev = NULL;
    if (p_GetDeviceIDs(pl, CL_DEVICE_TYPE_GPU, 1, &dev, NULL) != CL_SUCCESS || !dev)
        p_GetDeviceIDs(pl, CL_DEVICE_TYPE_ALL, 1, &dev, NULL);
    if (!dev) { printf("#### IMAGECAP_ABORT_NO_DEVICE\n"); return 2; }

    cl_context ctx = NULL; { cl_int e = CL_SUCCESS; ctx = p_CreateContext(NULL, 1, &dev, NULL, NULL, &e);
        if (!ctx || e != CL_SUCCESS) { printf("#### IMAGECAP_ABORT_NO_CONTEXT rc=%d\n", (int) e); return 2; } }

    printf("#### IMAGECAP dev=\""); str_raw(dev, CL_DEVICE_NAME); printf("\"");
    printf(" drv=\"");           str_raw(dev, CL_DRIVER_VERSION); printf("\"");
    bool_info(dev, CL_DEVICE_IMAGE_SUPPORT, "image_support");
    num_info(dev, CL_DEVICE_IMAGE_MAX_BUFFER_SIZE, "max_buffer");
    num_info(dev, CL_DEVICE_IMAGE_MAX_ARRAY_SIZE,  "max_array");
    num_info(dev, CL_DEVICE_MAX_MEM_ALLOC_SIZE,    "max_alloc");
    num_info(dev, CL_DEVICE_GLOBAL_MEM_SIZE,       "global_mem");
    {   cl_ulong wi[3] = {0,0,0};
        if (p_GetDeviceInfo(dev, CL_DEVICE_MAX_WORK_ITEM_SIZES, sizeof wi, wi, NULL) == CL_SUCCESS)
            printf(" max_wi0=%llu", (unsigned long long) wi[0]);
    }
    printf("\n");

    /* ---- 探针阳性对照：极小 image 必须成功，否则整支枪作废 ---- */
    {
        int bad = try_image(ctx, "selftest_tiny", CL_R, CL_UNSIGNED_INT32, 1024, 4, 0, NULL);
        if (bad) { printf("#### IMAGECAP_ABORT_SELFTEST rc!=0（探针自身不可信，结论作废）\n"); return 2; }
    }

    /* ---- (2) 宽度阶梯：三种格式 × {ling, LFM 闸门宽度} ---- */
    struct { const char *tag; cl_channel_order co; cl_channel_type ct; size_t bpp; } F[3] = {
        { "q_img",  CL_R,    CL_UNSIGNED_INT32, 4  },   /* batched q 平面 */
        { "d_img",  CL_R,    CL_HALF_FLOAT,     2  },   /* scale 平面 */
        { "b_img",  CL_RGBA, CL_FLOAT,          16 },   /* 激活平面（16B/px） */
    };
    long W[2] = { ling_w, lfm_w };
    int pass_w[2] = { 1, 1 };
    for (int i = 0; i < 2; i++)
        for (int f = 0; f < 3; f++)
            if (try_image(ctx, W[i] == ling_w ? "ling_width" : "lfm_width", F[f].co, F[f].ct,
                          (size_t) W[i], F[f].bpp, 0, NULL)) pass_w[i] = 0;

    /* ---- (3) A 路专属：多槽位基座 + origin=es_base*q_layer 的子缓冲 + 其上建 image ---- */
    int a_route_ok = 1;
    {
        const size_t slot = (size_t) q_layer;
        const size_t base_bytes = slot * (size_t) (es_base + E);      /* 基座必须覆盖 es_base+E 槽 */
        cl_int err = CL_SUCCESS;
        if (base_bytes > (size_t) (1ull << 31)) { printf("#### IMAGEPROBE tag=a_route rc=SKIP_BASE_TOO_BIG bytes=%llu\n",
                                                          (unsigned long long) base_bytes); a_route_ok = 0; }
        else {
            cl_mem base = p_CreateBuffer(ctx, CL_MEM_READ_ONLY, base_bytes, NULL, &err);
            if (!base || err != CL_SUCCESS) {
                printf("#### IMAGEPROBE tag=a_route kind=base bytes=%llu rc=ALLOC_%d\n",
                       (unsigned long long) base_bytes, (int) err); a_route_ok = 0;
            } else {
                cl_buffer_region r; memset(&r, 0, sizeof r);
                r.origin = (size_t) es_base * slot; r.size = slot * (size_t) E;
                cl_mem sub = p_CreateSubBuffer(base, CL_MEM_READ_ONLY, CL_BUFFER_CREATE_TYPE_REGION, &r, &err);
                printf("#### IMAGEPROBE tag=a_route kind=subbuf origin=%llu size=%llu rc=%d\n",
                       (unsigned long long) r.origin, (unsigned long long) r.size, (int) err);
                if (!sub || err != CL_SUCCESS) { a_route_ok = 0; }
                else {
                    /* 子缓冲之上建 q_img：E 槽宽，正是 A 路派发时喂内核的 image */
                    if (try_image(ctx, "a_route_qimg", CL_R, CL_UNSIGNED_INT32,
                                  (size_t) E * slot / 4, 4, 1, sub)) a_route_ok = 0;
                    p_ReleaseMemObject(sub);
                }
                /* 阴性对照：故意不 1024 对齐的 origin —— 期望失败；若成功说明对齐门是摆设 */
                cl_buffer_region r2; memset(&r2, 0, sizeof r2);
                r2.origin = 1; r2.size = slot;
                cl_mem sub2 = p_CreateSubBuffer(base, CL_MEM_READ_ONLY, CL_BUFFER_CREATE_TYPE_REGION, &r2, &err);
                printf("#### IMAGEPROBE tag=a_route_negctl_unaligned kind=subbuf origin=1 rc=%d %s\n",
                       (int) err, (err == CL_SUCCESS) ? "(!)UNALIGNED_ORIGIN_ACCEPTED" : "as_expected");
                if (sub2) p_ReleaseMemObject(sub2);
                p_ReleaseMemObject(base);
            }
        }
    }

    printf("#### IMAGECAP_VERDICT ling=%s lfm=%s a_route=%s gate=%ld ling_w=%ld q_layer=%ld E=%ld es_base=%ld\n",
           pass_w[0] ? "PASS" : "FAIL", pass_w[1] ? "PASS" : "FAIL", a_route_ok ? "PASS" : "FAIL",
           lfm_w, ling_w, q_layer, E, es_base);
    if (n_bad) { printf("#### IMAGECAP_ABORT_ATTR_READ_FAIL（能力项读取失败，结论作废）\n"); return 2; }
    return (pass_w[1] && a_route_ok) ? 0 : 1;
}
