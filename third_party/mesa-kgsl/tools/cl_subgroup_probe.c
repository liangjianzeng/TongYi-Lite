/* [Mesa 线 P3] 一颗"到底谁在藏 subgroup"的探针：把 rusticl 暴露的扩展串与 subgroup 相关查询全部打出来。
 *
 * 为什么需要它（源码级定位，见接管复评文档 §5 P3 回填）：
 *   - 上游 Mesa 26.2.4 `rusticl/core/device.rs:766-779`：`if self.subgroups_supported()` 分支里
 *     `cl_khr_subgroup_extended_types` / `__opencl_c_subgroups` / ballot / clustered 都是**无条件加**的，
 *     唯独 `add_ext(1,0,0,"cl_khr_subgroups")` 被**注释掉**，注释写着
 *     "requires CL_DEVICE_SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS"；
 *   - `rusticl/api/device.rs:314`：`CL_DEVICE_SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS => false`（写死）；
 *   - `freedreno/freedreno_screen.c:370-372`：`caps->subgroup_sizes = screen->info->threadsize_base`
 *     （gen6 wave=64 ⇒ 连 ballot 该有）；
 *   - 现场事实：ggml 在 `ALLOW_NO_SUBGROUP` 不传时打印 `device does not support subgroups
 *     (cl_khr_subgroups or cl_intel_subgroups) … drop unsupported device 'FD650'` ⇒ **整颗 GPU 被丢掉**，
 *     我们全靠那个降级开关才跑得起来（token-18 数值分歧就挂在这条降级路上）。
 *   - 反常：部署的那颗 lib 里**有** `cl_khr_subgroups` 字面串，却**没有** `cl_khr_subgroup_extended_types`
 *     等串 —— 与上游 26.2.4 正好相反 ⇒ fork 在这块动过手，但运行时没吐出来。
 * ⇒ 所以要分清三种可能，修法各自不同、责任人也不同：
 *     A) 扩展串被藏（IFP 写死 false 连坐）          ⇒ 两行补丁（IFP 报 true + 打开 add_ext）
 *     B) kgsl 路径上 `subgroups_supported()` 为假     ⇒ fork 的 winsys 没把 threadsize_base 填进 caps
 *     C) caps 有值但 clGetDeviceInfo 查询返回错误      ⇒ rusticl 查询实现缺失
 *   本探针一次性把三者分开。
 *
 * 用 dlopen("libOpenCL.so") 自己取符号，不依赖任何 stub/导入库，换机器即可跑。
 * 编译：bash scripts/build_tools_android.sh（自动收 tools/*.c）
 * 跑：  与 e2e 同一套环境（OCL_ICD_VENDORS=…/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl …）
 *       /data/local/tmp/cl_subgroup_probe
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CL/cl.h>

/* cl_intel_subgroups 的那组查询在 cl_ext_intel.h 里；不引那个头，直接给值（省依赖）。
 * CL_DEVICE_SUB_GROUP_SIZES_INTEL = 0x4108（已在本仓库 third_party/OpenCL-Headers/CL/cl_ext.h:2986 核对） */
#ifndef CL_DEVICE_SUB_GROUP_SIZES_INTEL
#define CL_DEVICE_SUB_GROUP_SIZES_INTEL 0x4108
#endif

typedef cl_int (*fn_get_platforms)(cl_uint, cl_platform_id *, cl_uint *);
typedef cl_int (*fn_get_platform_info)(cl_platform_id, cl_platform_info, size_t, void *, size_t *);
typedef cl_int (*fn_get_devices)(cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *);
typedef cl_int (*fn_get_device_info)(cl_device_id, cl_device_info, size_t, void *, size_t *);

static fn_get_platforms p_get_platforms;

int main(void) {
    void *h = dlopen("libOpenCL.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "[probe] dlopen libOpenCL.so 失败: %s\n", dlerror()); return 2; }
    p_get_platforms   = (fn_get_platforms)   dlsym(h, "clGetPlatformIDs");
    fn_get_platform_info p_plat_info = (fn_get_platform_info) dlsym(h, "clGetPlatformInfo");
    fn_get_devices       p_get_devices = (fn_get_devices)     dlsym(h, "clGetDeviceIDs");
    fn_get_device_info   p_dev_info   = (fn_get_device_info)  dlsym(h, "clGetDeviceInfo");
    if (!p_get_platforms || !p_plat_info || !p_get_devices || !p_dev_info) {
        fprintf(stderr, "[probe] 符号不全，换 loader\n"); return 2;
    }

    cl_platform_id pl[8]; cl_uint npl = 0;
    cl_int rc = p_get_platforms(8, pl, &npl);
    printf("[probe] clGetPlatformIDs rc=%d n=%u\n", rc, npl);
    if (rc != CL_SUCCESS || npl == 0) return 3;

    char buf[8192]; size_t need = 0;
    for (cl_uint i = 0; i < npl; i++) {
        memset(buf, 0, sizeof buf);
        p_plat_info(pl[i], CL_PLATFORM_NAME, sizeof buf - 1, buf, &need);
        printf("[probe] platform[%u] name='%s'\n", i, buf);
    }

    cl_device_id dev[8]; cl_uint ndev = 0;
    rc = p_get_devices(pl[0], CL_DEVICE_TYPE_ALL, 8, dev, &ndev);
    printf("[probe] clGetDeviceIDs rc=%d n=%u\n", rc, ndev);
    if (rc != CL_SUCCESS || ndev == 0) return 4;

    for (cl_uint d = 0; d < ndev; d++) {
        printf("\n===== device[%u] =====\n", d);
        struct { cl_device_info q; const char *name; } strs[] = {
            {CL_DEVICE_NAME, "name"}, {CL_DEVICE_VENDOR, "vendor"},
            {CL_DEVICE_VERSION, "device_version"}, {CL_DRIVER_VERSION, "driver_version"},
            {CL_DEVICE_PROFILE, "profile"},
        };
        for (unsigned k = 0; k < sizeof strs / sizeof *strs; k++) {
            memset(buf, 0, sizeof buf);
            rc = p_dev_info(dev[d], strs[k].q, sizeof buf - 1, buf, &need);
            printf("  %-16s rc=%d '%s'\n", strs[k].name, rc, rc == CL_SUCCESS ? buf : "");
        }

        memset(buf, 0, sizeof buf);
        rc = p_dev_info(dev[d], CL_DEVICE_EXTENSIONS, sizeof buf - 1, buf, &need);
        printf("  extensions       rc=%d bytes=%zu\n  extensions = %s\n", rc, need, rc == CL_SUCCESS ? buf : "");

        /* 关键三问 */
        const char *want_khr   = strstr(buf, "cl_khr_subgroups");
        const char *want_khrx  = strstr(buf, "cl_khr_subgroup_extended_types");
        const char *want_intel = strstr(buf, "cl_intel_subgroups");
        const char *want_qcom  = strstr(buf, "cl_qcom_subgroup_shuffle");
        printf("  [判定A] 扩展串: cl_khr_subgroups=%s  cl_khr_subgroup_extended_types=%s  "
               "cl_intel_subgroups=%s  cl_qcom_subgroup_shuffle=%s\n",
               want_khr ? "YES" : "no", want_khrx ? "YES" : "no",
               want_intel ? "YES" : "no", want_qcom ? "YES" : "no");

        cl_bool ifp = CL_FALSE;
        rc = p_dev_info(dev[d], CL_DEVICE_SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS, sizeof ifp, &ifp, &need);
        printf("  [判定A] SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS rc=%d val=%d (%s)\n",
               rc, (int) ifp, rc != CL_SUCCESS ? "查询不被支持 ⇒ rusticl 连 IFP 都没实现" : "");

        cl_uint u[32]; memset(u, 0, sizeof u);
        rc = p_dev_info(dev[d], CL_DEVICE_SUB_GROUP_SIZES_INTEL, sizeof u, u, &need);
        printf("  [判定B] SUB_GROUP_SIZES_INTEL rc=%d bytes=%zu 值=", rc, need);
        for (size_t k = 0; k < need / sizeof(cl_uint) && k < 8; k++) printf("%u ", u[k]);
        printf("\n");

        cl_uint mns = 0;
        rc = p_dev_info(dev[d], CL_DEVICE_MAX_NUM_SUB_GROUPS, sizeof mns, &mns, &need);
        printf("  [判定B] MAX_NUM_SUB_GROUPS rc=%d val=%u\n", rc, mns);

        size_t psz = 0;
        rc = p_dev_info(dev[d], CL_DEVICE_PREFERRED_WORK_GROUP_SIZE_MULTIPLE, sizeof psz, &psz, &need);
        printf("  [判定B] PREFERRED_WORK_GROUP_SIZE_MULTIPLE rc=%d val=%zu\n", rc, psz);

        printf("  [小结] A(串被藏)=%s  B(caps 无值)=%s\n",
               (!want_khr && !want_intel) ? "成立" : "不成立（串在，问题不在扩展表）",
               (rc != CL_SUCCESS) ? "疑似（查询失败/caps 未填）" : "不成立（caps 有值）");
    }
    printf("\n读法：A 成立 + IFP=0 ⇒ 两行补丁（api/device.rs:314 报 true + core/device.rs:770 打开 add_ext）\n"
           "      A 成立 + caps 也无值 ⇒ 先修 fork winsys 的 threadsize_base→caps->subgroup_sizes\n"
           "      A 不成立 ⇒ ggml 的探测条件本身有问题，回到 ggml-opencl 侧查\n");
    return 0;
}
