# mesa-kgsl: Adreno KGSL 全链路构建配方（rusticl + freedreno + kgsl）

mesa 26.2.4 在 Debian trixie (aarch64) chroot 内自编，产出 **rusticl + freedreno(ir3) + kgsl winsys**
的 OpenCL 栈——TongYi-Lite 全 GPU 卸载 Mesa 路线（M0 已裁决 GO，见
`docs/全GPU卸载_Mesa自研路线总档_2026-10-16.md` §11）的可复现唯一真理源。

830 真机验证结论：`Device #0: Adreno (TM) 830`（CL 3.1 / 6 CU）；判据 1 = ir3 GEMV
74%/108%/126% vs 高通 compiler（大形状反超）；判据 2 = 录制税 ~2.5-3µs/op（proot 污染内）。

## 目录

```
patches/
  0011-freedreno-drm-kgsl-Add-KGSL-backend-for-freedreno.patch   # droidvm, 752 行 kgsl 后端
  0012-freedreno-drm-Add-more-APIs-to-per-backend-API.patch      # droidvm, 77 行后端 API 扩展
  0026-pipe-loader-kgsl-probe-26.2.4.patch                       # 自写，pipe_loader /dev/kgsl-3d0 探测钩子
  LICENSE.droidvm-mesa-freedreno-patchs                          # 0011/0012 上游许可
scripts/
  build_mesa.sh        # chroot 内：依赖 → tarball → meson → ninja install
  fix_fd_device.py     # freedreno_device.c 26.2 结构适配（非 DRM fd 放行 + use_heap 处置）
  collect_runtime.sh   # ldd 递归收集运行时精简包（2.26G chroot → ~257M → xz ~60M）
  run_cl.sh            # 830 侧 proot 运行器模板
```

上游：0011/0012 取自 `droidvm/mesa-freedreno-patchs`（freedreno-kgsl-patchs-for-24.3.0 目录）。
**不要用 24.2.8 目录**；0015（termux-x11）等其余补丁与纯 compute 无关，不收。

## 构建配方（DGX /opt/trixie-cl，Debian trixie arm64 chroot）

```bash
# 1. chroot（一次性，已在 DGX 现存）
debootstrap --arch=arm64 trixie /opt/trixie-cl
chroot /opt/trixie-cl

# 2. 进 /root，按序打补丁（源码树 /root/mesa-26.2.4）
cd /root/mesa-26.2.4
patch -p1 < /root/0011-freedreno-drm-kgsl-Add-KGSL-backend-for-freedreno.patch  # 几乎干净（fuzz 1）
patch -p1 < /root/0012-freedreno-drm-Add-more-APIs-to-per-backend-API.patch
#    0012 会有一个 hunk 失败（freedreno_screen.c PIPE_CAP_DMABUF，26.2 已重构，纯 compute 不需要）→ 弃
python3 /root/fix_fd_device.py     # freedreno_device.c 适配（见下）
patch -p1 < /root/0026-pipe-loader-kgsl-probe-26.2.4.patch

# 3. 构建（脚本含全部 meson flags）
bash /root/build_mesa.sh           # ninja -j6，产出装到 /opt/mesa-cl
```

tarball 来源：`https://deb.debian.org/debian/pool/main/m/mesa/mesa_26.2.4.orig.tar.xz`
（mesa.freedesktop.org 慢、gh-proxy 404，deb pool 实测可用）。

### fix_fd_device.py 做了什么（26.2 vs 24.3 结构漂移适配）

1. `fd_device_new` 非 DRM fd（kgsl）放行：`version==NULL` 不再 early-return，改 DEBUG_MSG；
2. msm 分支 `version->name` 前加 NULL 守卫；unsupported 日志同样守卫；
3. 删掉 26.2 已改名的 `support_use_heap` 残留赋值；
4. **KGSL 的 use_heap 必须保持 false**：ring_heap 子分配（0012 对 gen≥6 启用）在 kgsl 上
   导致 GPU fault（submit 成功、wait 10s→EDEADLK、kernel 偶发执行 burst 2/10）。
   禁用后 10/10 全通 0.9ms/轮。26.2 默认已是 false 且 kgsl 分支 `goto out`，勿改回。

### 0026 关键点

- `driver_name` 必须是 **"kgsl"**——26.2 pipe_loader 表里没有 "freedreno" 条目
  （msm 描述符的 DRM_DRIVER_DESCRIPTOR_ALIAS 名）；
- msm_kgsl.h 是内核 uapi 头，glibc 用户态编译需 `__user` 兜底宏（补丁内已含）；
- 历史教训：driver_name 若写成 "freedreno"，RUSTICL_ENABLE=kgsl 时设备被前端静默丢弃。

## 运行时上机（830，proot）

```bash
# 收集（chroot 内）：2.26G chroot → ~257M → xz ~60M
bash /root/collect_runtime.sh

# 推机后（/data/local/tmp/mesa_m0/rootfs/clrt）：
# 1. ldd 抓不到 ELF 解释器，单独补 /lib/ld-linux-aarch64.so.1
# 2. 补 clang 资源头文件 /usr/lib/llvm-19/lib/clang/19/include（opencl-c-base.h 等，~1MB）
# 3. 补 libclc spirv：/usr/lib/clc/spirv-mesa3d-.spv + spirv64-mesa3d-.spv（缺了内核编译失败）
# 4. ICD：OCL_ICD_VENDORS env 不生效，用 OCL_ICD_FILENAMES 直指 + 造 /etc/OpenCL/vendors

sh run_cl.sh 'RUSTICL_ENABLE=kgsl OCL_ICD_FILENAMES=/.../libRusticlOpenCL.so.1.0.0 clinfo'
```

## 已知坑（M1 待处理）

| 坑 | 说明 |
|---|---|
| `RUSTICL_ENABLE=kgsl` 必须显式设 | 前端按名单静默过滤 driver_name，缺了设备枚举为空且 fd_device_new 根本不执行 |
| CL_QUEUE_PROFILING_ENABLE 被拒（-35） | 两代 API 都拒 → 只能 wall 口径计时 |
| ring_heap 禁用中 | 每 BO 独立分配，BO 多时有 handle 开销 → 修 heap 或保持禁用 |
| `kgsl_pipe_get_param` invalid param id 13 | FD_MAX_FREQ 故意 fault 的已知行为，无害 |
| gpu_id 打印=0 | debug 字段错位，chip_id 实际正确（Adreno 830 名字对） |
| SELinux Enforcing | renderD128/card0=graphics_device 域拒；kgsl-3d0=gpu_device 可开 → kgsl 是唯一通路 |

## 与 _probe/mesa_m0 的关系

测量探针 `probe_m0.c`（同源码 A/B：NDK bionic + vendor ICD vs glibc proot + rusticl）、
`ktest2.c`（GPU fault 判别）及各二进制按惯例留在 `_probe/mesa_m0/`（不入 git）。
本目录只维护**可复现配方**；M1 bionic 化产出（rust aarch64-linux-android 交叉编）落地后才进
`jniLibs/` 随 APK 分发。
