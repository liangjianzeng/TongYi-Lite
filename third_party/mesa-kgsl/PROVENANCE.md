# Mesa 线 · 部署物溯源（P0-1 之前先把"我们手上到底是什么"钉死）

> 为什么要这份文件：P0 要求"把带 `FD_*` 探针的 Mesa fork 源码/补丁/构建配方收进本目录"。
> 源码树要等 `sudo tar`（P0-1，见 §6 的验收清单）。**但"在跑的那颗 lib 究竟是什么"不该靠记忆**——
> 今天两次差点把"不知道是什么的东西"当证据用，所以先把部署物身份、探针清单、运行配方全部机检化。

## 1. 在役 artifact 身份（两台机器同一颗）

| 项 | 值 | 怎么复核 |
|---|---|---|
| 文件 | `libRusticlOpenCL.so` | 830：`/data/local/tmp/mesa_bionic/lib/`；K40：`/data/local/tmp/mesa_clean/lib/` |
| **md5** | **`c82f84d89d6962e582796b114a9f4c83`** | `adb -s <dev> shell md5sum <路径>` —— **两台必须一致，否则 A/B 无意义** |
| ELF Build ID | `d8ee9a53fe033ca335d93b405e00a478b5f357b8` | `llvm-readelf -n` |
| SONAME | `libRusticlOpenCL.so` | `llvm-readelf -d` |
| 符号 | **已 strip**（只剩动态符号） | ⇒ 任何"读码断言"都必须标明是从**上游 26.2.4** 读的，不是从这颗 lib 读的 |
| 另一颗（勿混用） | chroot glibc 版 `d3fa4d86…`，**未 strip**、**缺 `FD_NODEFER`** | 只有它能查符号；**今天所有实测都不是它** |

## 2. 构建期烙进二进制的源码根 —— P0-1 的靶子

`strings` 出来的断言路径统一是 **`../../src/mesa-26.2.4/...`** ⇒ 构建时源码根是 `<某目录>/src/mesa-26.2.4/`，
与 chroot 里 `/opt/trixie-cl/root/...` 的布局对得上。**版本号 = 26.2.4**。

断言里露出的 **42 个源文件**（= 这份 lib 的"责任面"，P0-1 到手后逐个核对是否被 fork 改过）：

- `src/gallium/frontends/rusticl/**` 共 **31** 个：`api/{context,device,icd,kernel,memory,program,semaphore,util}.rs`、
  `core/{context,device,event,format,gl,kernel,memory,meta,platform,program,queue,semaphore}.rs`、
  `mesa/compiler/clc/spirv.rs`、`mesa/compiler/nir.rs`、`mesa/pipe/{context,device,fence,query,resource,screen}.rs`、
  `util/{math,properties,string}.rs`
- `src/compiler/spirv/**` 共 **9** 个：`vtn_{alu,cfg,cmat,glsl450,opencl,private.h,structured_cfg,subgroup,variables}`
- `src/freedreno/ir3/instr-a3xx.h`、`src/util/xmlconfig.c` 各 1

⇒ **注意这三处今天已经各自命中过一次**（都不是巧合，是 fork 动过的区域）：
- [`core/kernel.rs:2047`]：`buf = &buf[0..(length - 4) as usize];` 无下界减法 ⇒ gen7 上 `tbo -o MUL_MAT_ID` 的 abort 根因；
- `api/device.rs:314` + `core/device.rs:770`：`CL_DEVICE_SUB_GROUP_INDEPENDENT_FORWARD_PROGRESS` 写死 `false`，
  连坐 `//add_ext(1, 0, 0, "cl_khr_subgroups");` 被注释 ⇒ ggml 的准入检查因此丢设备（P3）；
- `core/queue.rs` / `mesa/pipe/fence.rs`：提交与 fence 路径 ⇒ P2 候选 B（BO/ring 复用）要读的就是这里。

## 3. `FD_*` 探针/开关全表（从这颗 lib 的 `strings` 里挖的，**这就是 fork 的能力面**）

`FD_COMPUTE_WFI`、`FD_DEV_FEATURES`、`FD_FORCE_REEMIT`、`FD_GPU_TRACEPOINT`、`FD_IBTRACE`、`FD_KGSL_TSSYNC`、
`FD_KGSL_USLEEP_US`、`FD_MESA_DEBUG`、`FD_MESA_GMEM`、`FD_NO_BOCACHE`、`FD_NODEFER`、
`FD_RD_DUMP`(+`_FRAMES`/`_PATH`/`_SUBMITS`/`_TESTNAME`)，以及 `FD_MESA_DEBUG` 的字面值 `inorder`、`nogrow`。

| 开关 | 状态 | 结论（今日实测） |
|---|---|---|
| `FD_NODEFER` | **已用** | `merged` 6040→0（合并确实被关）但**正确性纹丝不动** ⇒ 上游 `should_defer` 合并假设证伪 |
| `FD_MESA_DEBUG=inorder` / `=nogrow` | **已用** | 观测量（submits/ibs/merged）与基线**逐位相同** ⇒ 串在≠通路在，别再花时间 |
| `FD_RD_DUMP*` | **已用** | 目录恒空 ⇒ 判据 C（"没输出"不等于"没差别"） |
| `FD_NO_BOCACHE` | **试过但只到方向级** | 4 腿 health 仍 0；**token 级 `token_diff` 没拿到**（830 adb 掉线）⇒ 不作裁决 |
| `FD_FORCE_REEMIT` / `FD_COMPUTE_WFI` / `FD_KGSL_TSSYNC` / `FD_KGSL_USLEEP_US` | 同上 | 同上；`FD_KGSL_USLEEP_US` 那条**只要与 repro 不同就直接判 timing race** |
| **`FD_IBTRACE`** | **从没试过** | 唯一还能给"提交层直接证据"的开关；830/740 可用时的第一刀 |
| `FD_GPU_TRACEPOINT` / `FD_MESA_GMEM` / `FD_DEV_FEATURES` | 从没试过 | 低优先 |

> 判具：[scripts/run_p2_fdknob_ab.sh](scripts/run_p2_fdknob_ab.sh)（判据先写死 + GPU 证据硬闸）。

## 4. 运行配方（bionic 直跑，**不需要 proot/glibc**）

今天发现的关键事实：**K40 与 830 都直接带 bionic 版 `mesa_clean`/`mesa_bionic`，md5 相同**
⇒ 原计划里"给 K40 用 proot+glibc 跑 Mesa"的前提**是多余的**，那条路线不要再投入。

每台机器跑 Mesa 腿必需的 env（缺一个就不是在 GPU 上跑）：

```sh
B=<bundle 根>            # 830: /data/local/tmp/mesa_bionic   K40: /data/local/tmp/mesa_clean
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so   # ICD 入口，指错=退回 CPU 而日志看不出来
export RUSTICL_ENABLE=kgsl                            # 不给这个环境变量就不建 kgsl 屏
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp              # 否则写 /data/local/tmp 的默认 cache 目录会失败
export CLC_RESOURCE_DIR=$B/lib/clang/21/include       # 缺它 -> 内核编译期找不到 include -> 全算子 not supported
```

ggml 侧准入依赖两个兼容开关（今日实测**都是承重的**）：
`GGML_OPENCL_ALLOW_NO_SUBGROUP=1`（关它 ⇒ 设备被直接丢弃）、`GGML_OPENCL_FAKE_QCOM_REQD=1`（关它 ⇒ `rc=1`）。

## 5. 已入库的补丁

- [`patches/0001-rusticl-advertise-cl_khr_subgroups.patch`](patches/0001-rusticl-advertise-cl_khr_subgroups.patch)：
  相对上游 26.2.4 **只有 2 处改动**（`api/device.rs:314` IFP `false`→`true`；`core/device.rs:770` 取消 `add_ext(1,0,0,"cl_khr_subgroups")` 的注释）。
  **上机前三件背书缺一不可**：① subgroup barrier 环回挂死测试；② `tools/cl_subgroup_probe` 复测扩展串真的出现；
  ③ `q0a0`（`ALLOW_NO_SUBGROUP=0`）被接受且真机 48 token 与 CPU 全等。

## 6. P0-1 `sudo tar` 的验收清单（拿到源码后逐条过，缺一条都不算"收进仓库"）

1. tar 内必须存在 `src/mesa-26.2.4/`（与 §2 烙进二进制的路径逐字对得上），且版本号串为 `26.2.4`；
2. §2 那 **42 个文件**逐个与上游 26.2.4 `diff`，产出 `fork-diff-against-upstream.txt`（这才叫"补丁序列"，
   比现在只有 1 个 patch 可信）；
3. `build_mesa.sh`（或等价 meson 脚本）+ meson `buildoptions` + **交叉到 android 的 toolchain 文件** 一并入库；
4. `git` 元数据或 `VERSION` 串能定出 fork 基点（今天查 `^[0-9a-f]{40}$` **没查到**，说明没烙 git hash —— 需要问当事人或从 chroot 里找）；
5. 编出来的 trace-off lib 必须 **md5 与这颗不同**（否则"干净构建"是假的），且 `strings` 里 `FD_NODEFER` 仍在（证明 fork 探针没丢）。

> 第 5 条就是"trace-off 干净构建"的机检定义，配套判具见 [scripts/verify_mesa_bundle.sh](scripts/verify_mesa_bundle.sh)。
