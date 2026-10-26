# C1-P2 S0 落锤 —— 路 A（clrt/glibc 运行时系）830 上机束 · README

生成：2026-10-26，DGX（dgxspark <redacted-tailscale>）。**本束只在 DGX 打包自检，未碰 830、未碰 adb。**
staging 路径：`/home/jianzengliang/mesa_routeA_1026/`

## 0. 产物与来源链（可复现性已机检）

| 物 | 位置（DGX） | md5 |
|---|---|---|
| 自构建原始产物（含 0001 补丁，未 strip） | `/opt/trixie-cl/root/mesa-26.2.4/build-cl/src/gallium/targets/rusticl/libRusticlOpenCL.so.1.0.0` | `aaedc2c1a46b0d043a59951abba45caf`（= R-025 备案 ✓） |
| 同左副本 | `staging/lib/libRusticlOpenCL.so.1.0.0.pristine` | `aaedc2c1…` |
| **交付件**（patchelf 后） | `staging/lib/libRusticlOpenCL.so.1.0.0` 及 `clrt-overlay/opt/mesa-cl/lib/aarch64-linux-gnu/libRusticlOpenCL.so.1.0.0` / `.so.1` | `8de7d05fa40611fc8d66d67fda8b580c` |

- 树 = chroot `/opt/trixie-cl`（Debian 13 trixie, aarch64 原生非交叉）内 `/root/mesa-26.2.4`（上游 26.2.4 orig tarball，无 .git），meson 目录 `build-cl/`。
- 0001 补丁 = 两处一套：`api/device.rs` `CL_DEVICE_SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS → true`；`core/device.rs` `add_ext(1,0,0,"cl_khr_subgroups")` 取消注释。diff 取证：`logs/patch_site1_api_device_rs.diff`、`logs/patch_site2_core_device_rs.diff`（`.orig` 备份在树内）。
- **重编复验（本次新做的背书）**：touch 两补丁文件 → `chroot /opt/trixie-cl` 内 `ninja -C build-cl src/gallium/targets/rusticl/libRusticlOpenCL.so.1.0.0`（12 目标增量）→ 产物 md5 **逐字节 = aaedc2c1**。即：当前树 + build-cl 配置可确定性再生 R-025 产物，交付链闭合，无需"重打补丁重建、md5=新值"（协调令的前提"产物已丢"不成立）。
- kgsl：0011/0012 未以补丁文件形态在树内——26.2.4 上游自带 `src/freedreno/drm/kgsl/`（`build_mesa.sh` KMDs=msm,kgsl），strings kgsl 47 处与 R-025 相符。
- 交付件 patchelf 改动：**仅 RUNPATH**（`$ORIGIN:$ORIGIN/clrt:$ORIGIN/../../../lib/aarch64-linux-gnu:$ORIGIN/../../../opt/mesa-cl/lib/aarch64-linux-gnu`）。DT_NEEDED / SONAME 未动（自检 `logs/dt_selfcheck.txt`）。
  注：.so 无 PT_INTERP 段（patchelf 拒设 interpreter，属预期）；**loader 指定发生在可执行件侧**（下节用 `ld-linux-aarch64.so.1 --library-path` 直跑），不需要给库设 interpreter。

## 1. 依赖闭包（缺口清单 = 空）

DT_NEEDED 11 项 + 二级闭包共 18 条依赖，全部由束内 `clrt-overlay/opt/mesa-cl/lib/aarch64-linux-gnu/clrt/`（19 个文件，从 chroot `/opt/trixie-cl/lib/aarch64-linux-gnu` 拷入，与构建环境同源同版本）覆盖：

libc.so.6 / libm.so.6 / libstdc++.so.6 / libgcc_s.so.1 / ld-linux-aarch64.so.1 / libz.so.1 / libzstd.so.1 / libdrm.so.2 / libLLVM.so.19.1 / libclang-cpp.so.19.1 / libLLVMSPIRVLib.so.19.1 / libffi.so.8 / libedit.so.2 / libtinfo.so.6 / libxml2.so.2 / libz3.so.4 / libbsd.so.0 / libmd.so.0 / liblzma.so.5（+ 束内附 libOpenCL.so.1 ICD loader，供 clinfo）。

- clrt loader 机检：`LD_TRACE_LOADED_OBJECTS=1 <束内 ld-linux> --library-path <clrt/> libRusticlOpenCL.so.1.0.0` → **18/18 全部解析在束内，0 条逃逸**（`logs/ldd_selfcheck.txt`）。
- **无缺口**。注意点：RUNPATH 不被二级依赖继承——**必须**用 `--library-path`（或 LD_LIBRARY_PATH）把 `clrt/` 目录喂给 loader（下节命令已含）；若绕过束内 loader 借别的 loader 则 libffi/libedit/libz3/libxml2/libtinfo/libbsd/libmd/liblzma 会解析失败。
- icu **不需要**（宿主那次自检出现 libicuuc/libicudata 是宿主 Ubuntu 的 libxml2 干扰；chroot trixie 版 libxml2.so.2 的 NEEDED 只有 libz/liblzma/libm/libc）。
- 对照在役 bionic bundle（c82f84d8，DGX 只有散装 lib 无目录镜像）：其 DT_NEEDED 是 bionic 命名系（libc.so/libc++_shared.so/无版本 LLVM），与 glibc 系不互通——这正是路 A 必须自带 clrt 闭包、不能"其余留在役版"混链的原因。

## 2. opencl-c.h 兼容性结论（clang-19 构建链 vs 在役 bundle clang/21）

两版头全文已存 `staging/headers/`（clang19 来自构建链；clang21 = 在役 bundle 侧头，上游 release/21.x @2078da43），diff 摘要 `logs/header_diff_opencl_c.txt`：

- **路 A 实际用的是束内自带的 clang-19 资源目录**（`clrt-overlay/usr/lib/llvm-19/lib/clang/19/include/opencl-c.h{,-base.h}` + libclang-cpp.so.19.1），与 libLLVM.so.19.1 严格配套——**不消费在役 bundle 的 clang/21 头**，混用风险从根上绕开。
- 即便需要评估混用：21 = 19 的严格超集，337 行差异全部是 `intel_sub_group_shuffle{,_up,_down,_xor}` 的 64 位整型重载（各 +12）。
- 本仓库 ggml-opencl kernel 实际用到的 subgroup 面（对 `third_party/llama.cpp/ggml/src/ggml-opencl/kernels/` 机检）：标准名 `sub_group_shuffle` 家族 7 文件、`get_sub_group_id` 37 文件、`reqd_sub_group_size` 98 文件；两版头对这些**同形态**（`sub_group_shuffle` 家族计数 180 vs 228 中标准名部分计数相等；`get_sub_group_id` 1=1；`cl_khr_subgroups` 宏 7=7）。
- `cl_qcom_*` 在两版头中均 0 命中 → 它是 ggml 降级路注入的 `-D cl_qcom_reqd_sub_group_size=1` **假 define + `#pragma OPENCL EXTENSION`**，与头文件版本无关；`reqd_sub_group_size` 字面两版头均 0（work-group attribute 走 `__attribute__` 路），同理不受头版本影响。
- **CLC fallback 不可用（如实入账）**：clrt 快照与 chroot 的 `/usr/lib/clc/` 都只有 `spirv{,64}-mesa3d-.spv` 两个 SPIR-V builtins，**无任何 OpenCL C `.bc` builtins**（libclc-19 不提供 aarch64/spirv `.bc`）→ **SPIR-V 路径是唯一路径**。在役 bionic 版同样如此（bundle 无 clc `.bc`），故 S0 判据（扩展表出现 cl_khr_subgroups + 卡死测试 + q0a0 对拍）不受影响。

## 3. 上机替换步骤（830，主线照做；本束未上机）

> 路 A 的本质：**不动在役 bionic bundle**（`/data/local/tmp/mesa_bionic/lib` 整套原样在），把 clrt/glibc 运行时系作为**并列的第二运行时**推上机，我们的 0001 lib 只替换 clrt 树内 `opt/mesa-cl/lib/aarch64-linux-gnu/libRusticlOpenCL.so.1.0.0` 的位置。历史 clrt 树（若设备上还有 `/data/local/tmp/clrt` 旧物）**先整体改名备份**，本束用新目录名，天然可回滚。

### 3.1 上机前必做（主线，替换前置门）

```bash
# ① 在役 bundle 留底（DGX/PC 均无整机镜像，必须先从 830 拉）
adb -s <redacted-tailscale>:5555 shell 'ls -la /data/local/tmp/mesa_bionic/lib' > bundle_ls_before.txt
adb -s <redacted-tailscale>:5555 pull /data/local/tmp/mesa_bionic/lib ./mesa_bionic_backup_1026/
(cd mesa_bionic_backup_1026 && md5sum * > ../bundle_md5_before.txt)
# 预期在役 libRusticlOpenCL = c82f84d89d6962e582796b114a9f4c83（若不符先停下报告，别继续）
```

### 3.2 推束 + 冒烟（新增目录，不覆盖任何在役文件）

```bash
R=/data/local/tmp/mesa_clrt_1026
adb -s <redacted-tailscale>:5555 push clrt-overlay /data/local/tmp/mesa_clrt_1026
adb -s <redacted-tailscale>:5555 shell "chmod -R 755 $R"
# 校验交付件字节（应为 8de7d05fa40611fc8d66d67fda8b580c）
adb -s <redacted-tailscale>:5555 shell "md5sum $R/opt/mesa-cl/lib/aarch64-linux-gnu/libRusticlOpenCL.so.1.0.0"
# clinfo 冒烟（loader 直跑；.icd 已随束，指 libRusticlOpenCL.so.1，束内有同名件）
adb -s <redacted-tailscale>:5555 shell "LD_LIBRARY_PATH=$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt \
  OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors \
  $R/lib/ld-linux-aarch64.so.1 --library-path $R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt $R/usr/bin/clinfo"
# 验收点：设备表出现 FD 设备且 EXTENSIONS 含 cl_khr_subgroups（= 0001 生效）；
#          CL_DEVICE_SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS = YES
```

### 3.3 跑探针/llama 腿（glibc 构建的探针件，同 loader 姿势）

```bash
CLRT=$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt
LD_LIBRARY_PATH=$CLRT OCL_ICD_VENDORS=$R/opt/mesa-cl/etc/OpenCL/vendors \
  $R/lib/ld-linux-aarch64.so.1 --library-path $R/lib/aarch64-linux-gnu:$CLRT \
  <glibc 构建的 cl_subgroup_probe / moe_probe> [参数照 run_mesa_matrix 惯例]
```

- MESA/FD 环境变量（FD_MESA_DEBUG / MESA_SPIRV / GGML_* 矩阵开关）按 `run_mesa_matrix.sh` 现例传，注意本 lib **无 fork 探针面**（无 FD_NODEFER 等），只认上游 FD_MESA_DEBUG/FD_DEV_FEATURES。
- 三背书缺一不上锤（R-025 立规，全部上机做）：① cl_subgroup_probe 复验扩展表含 `cl_khr_subgroups`；② subgroup 依赖 kernel 卡死测试不挂 GPU；③ `run_p3_ablate.sh` q0a0 腿（两降级开关都不传）KGSLSUBMIT>0 且与 CPU 48-token 全等。
- ⚠️ 上机腿**不得**注入 `-D cl_qcom_reqd_sub_group_size=1` / `GGML_OPENCL_ALLOW_NO_SUBGROUP=1` 降级路（0001 的目的就是走正门；注入了就退回 P3 嫌疑路径，判据作废）。

### 3.4 回滚

- 路 A 是新增目录：**`adb shell rm -rf /data/local/tmp/mesa_clrt_1026` 即全量回滚**，在役 Mesa/OpenCL（mesa_bionic bundle、vendor ICD、App 路径）全程未触碰。
- 若主线选择在历史 `/data/local/tmp/clrt` 原位覆盖过：先 `mv /data/local/tmp/clrt /data/local/tmp/clrt.bak_$(date +%s)` 再恢复。任何情况下都不动 `/data/local/tmp/mesa_bionic`（3.1 的 md5 留底 + `bundle_md5_before.txt` 为核对基线，收尾复算必须一致）。

## 4. 待主线裁决段

1. **"同源复建"疑点 —— DGX 侧证据为反向**：协调令转述"在役版 56954574 与自构 unpatched 686808f6 同源同配置、diff 只差 0001"，但 **这两个 md5 的实体不在 DGX**（DGX 在役散装 = c82f84d8，34MB）。对 c82f84d8 机检：`FD_NODEFER` strings active=1 / self-built=0（fork 探针面缺失，R-025 原结论）；active 无 `.comment` 无 DWARF（bionic/NDK strip 件）vs self-built `.comment`=GCC 14.2 + rustc 1.85.1（glibc trixie）；build-id 不同（d8ee9a53… vs ae0091e6…，注：build-id 对 bionic-vs-glibc 比对无鉴别力，真正证据是 FD_NODEFER 面与 .comment）。**结论：DGX 能证的是"非同源"（维持 R-025 判词，S0 合格于最小目的而非同源背书）；若主线握有 56954574/686808f6 两实体，请直接在主线做 section/strings 级 diff 裁决，勿引用本束为同源证据。**
2. clinfo/clc：SPIR-V 唯一路径（见 §2），若 S0 判据里有任何 CLC 源编路径期望，需先补 `.bc` 再谈。
3. 830 上 clrt 系（Debian trixie glibc 2.41 用户态）历史可跑（10-16），但当前机件/OS 状态下需 §3.2 冒烟复验；loader 直跑失败时优先查 SELinux/`noexec`（`/data/local/tmp` 一般 exec 无碍）。
4. clrt-overlay 内 `usr/lib/llvm-19/lib/clang/19/include` 全量头（含 x86 intrin 等）为体积换稳妥的整目录拷贝，约 30MB，上机无碍；若主线要做薄束，留 `opencl-c*.h`+`stdint/stddef` 族即可（未验证，动了必须重跑 §3.2）。

## 5. staging 目录清单

```
mesa_routeA_1026/
├── lib/libRusticlOpenCL.so.1.0.0            8de7d05f（交付件，patchelf）
├── lib/libRusticlOpenCL.so.1.0.0.pristine   aaedc2c1（原始产物）
├── clrt-overlay/                            整树直推 /data/local/tmp/mesa_clrt_1026
│   ├── lib/{ld-linux-aarch64.so.1, aarch64-linux-gnu/*}
│   ├── opt/mesa-cl/lib/aarch64-linux-gnu/{libRusticlOpenCL.so.1.0.0, .so.1, clrt/*(19)}
│   ├── opt/mesa-cl/etc/OpenCL/vendors/rusticl.icd
│   ├── usr/bin/clinfo
│   └── usr/lib/{clc/spirv*.spv, llvm-19/lib/clang/19/include/*}
├── headers/{clang19,clang21}-opencl-c{,-base}.h
└── logs/{ldd_selfcheck.txt, dt_selfcheck.txt, header_diff_opencl_c.txt,
          patch_site1_api_device_rs.diff, patch_site2_core_device_rs.diff}
```

纪律自证：未碰 830/adb；未 git 提交；未删 DGX 任何目录；树改动 = 既有 0001 补丁（.orig 在旁）+ 本次 touch 重编（产物逐字节复现，无新增源码改动）。
