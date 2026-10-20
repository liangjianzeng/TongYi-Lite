// [Mesa 线 P2] 直接问 kgsl 内核要几个设备属性，用来判 fork 的提交层有没有把参数喂错。
//
// 起因（源码实读，接管文档 §5.1）：gallium 在 fd_screen 里查 FD_UCHE_TRAP_BASE（enum fd_param_id
// 的第 13 项），查不到就回退 `gen>=6 ? 0x1fffffffff000 : 0`（freedreno_screen.c:1025-1029）。
// fork 的 kgsl winsys 不实现这个 param，机器上就打 `kgsl_pipe_get_param:105: invalid param id: 13`，
// 于是 **gen6/gen7 都吃同一个硬编码回退值**；而 turnip 走 kgsl 时是老老实实读
// KGSL_PROP_UCHE_TRAP_BASE(0x2F) 的（tu_knl_kgsl.cc:1848）。
// 这个工具就是量"内核真值 vs 那个回退值"：若 830(gen7) 上两者不等、K40(gen6) 上相等，
// "gen7 丢 kernel、gen6 不丢"就有一条与内核一致的硬件级解释。
//
// 用法：adb push kgsl_props /data/local/tmp/ && adb shell /data/local/tmp/kgsl_props

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define KGSL_IOC_TYPE 0x09
struct kgsl_device_getproperty {
    unsigned int type;
    void *value;
    size_t sizebytes;
};
#define IOCTL_KGSL_DEVICE_GETPROPERTY _IOWR(KGSL_IOC_TYPE, 0x2, struct kgsl_device_getproperty)

#define PROP_DEVICE_POWER      0x03
#define PROP_MMU_ENABLE        0x06
#define PROP_UCHE_GMEM_VADDR   0x13   // u64
#define PROP_UCHE_TRAP_BASE    0x2F   // u64  ← 主角

static int q(int fd, unsigned int id, const char *name, void *buf, size_t sz)
{
    struct kgsl_device_getproperty req;
    memset(buf, 0xA5, sz);
    memset(&req, 0, sizeof(req));
    req.type = id;
    req.value = buf;
    req.sizebytes = sz;
    int rc = ioctl(fd, IOCTL_KGSL_DEVICE_GETPROPERTY, &req);
    if (rc)
        printf("  prop 0x%02x %-18s ioctl_rc=%d errno=%d (%s)\n", id, name, rc, errno, strerror(errno));
    else if (sz == 8)
        printf("  prop 0x%02x %-18s = 0x%016llx\n", id, name, (unsigned long long)*(uint64_t *)buf);
    else
        printf("  prop 0x%02x %-18s = 0x%08x\n", id, name, *(uint32_t *)buf);
    return rc;
}

static void cat_first(const char *path, const char *label)
{
    char buf[128] = {0};
    FILE *f = fopen(path, "r");
    if (!f) { printf("  %-22s (读不到 %s: %s)\n", label, path, strerror(errno)); return; }
    if (!fgets(buf, sizeof(buf), f)) buf[0] = 0;
    fclose(f);
    printf("  %-22s %s", label, buf);
    if (buf[0] && buf[strlen(buf)-1] != '\n') printf("\n");
}

int main(void)
{
    // gallium 查不到 UCHE_TRAP_BASE 时给 gen>=6 的那个回退常量（freedreno_screen.c:1026）
    const uint64_t GALLIUM_FALLBACK_GEN6PLUS = 0x1fffffffff000ull;
    uint64_t u64 = 0;
    uint32_t u32 = 0;

    printf("[kgslprops] /dev/kgsl-3d0 属性直读（对照 gallium 回退值 0x%llx）\n",
           (unsigned long long)GALLIUM_FALLBACK_GEN6PLUS);
    cat_first("/sys/class/kgsl/kgsl-3d0/gpu_model", "gpu_model");
    cat_first("/sys/class/kgsl/kgsl-3d0/gpuclk", "gpuclk");

    int fd = open("/dev/kgsl-3d0", O_RDWR);
    if (fd < 0) { printf("[kgslprops] open /dev/kgsl-3d0 失败: %s\n", strerror(errno)); return 2; }

    q(fd, PROP_DEVICE_POWER,    "DEVICE_POWER",     &u32, sizeof(u32));
    q(fd, PROP_MMU_ENABLE,      "MMU_ENABLE",       &u32, sizeof(u32));
    q(fd, PROP_UCHE_GMEM_VADDR, "UCHE_GMEM_VADDR",  &u64, sizeof(u64));
    int rc = q(fd, PROP_UCHE_TRAP_BASE, "UCHE_TRAP_BASE", &u64, sizeof(u64));

    if (rc == 0) {
        const char *verdict = (u64 == GALLIUM_FALLBACK_GEN6PLUS) ? "与 gallium 回退值相同 => gen 无关，无罪"
                                                                : "**与回退值不等 => 提交层喂的是猜值**";
        printf("[kgslprops] 内核真值 UCHE_TRAP_BASE = 0x%llx  vs 回退 0x%llx => %s\n",
               (unsigned long long)u64, (unsigned long long)GALLIUM_FALLBACK_GEN6PLUS, verdict);
    } else {
        printf("[kgslprops] 内核拒绝回答 UCHE_TRAP_BASE => 回退值是唯一可用值，须与 turnip 对齐验证\n");
    }
    close(fd);
    return 0;
}
