# moe_probe — Adreno OpenCL MoE 真机探针

MUL_MAT_ID / batched MoE 内核的数值正确性对照工具：同一份量化权重在 GPU（OpenCL）
与 CPU 各跑一遍 MoE gather，逐 slot 算 NMSE。**GPU NMSE=0 才允许新内核上线。**

## 构建（Windows 宿主 → Android arm64）

```bash
cd _probe/moe_probe/build   # 已配置好的 NDK toolchain（ninja）
C:\Users\jianz\AppData\Local\Android\Sdk\cmake\3.22.1\bin\ninja.exe moe_probe4 ggml-opencl
```

`moe_probe4.cpp` 为最新版（q4_0 + q4_K 全覆盖）。改动 `.cl` 内核后 ninja 会重编
`libggml-opencl.so`（源码内嵌）。

## 推送与运行（设备 <redacted-tailscale>:5555）

```bash
ADB="C:\Users\jianz\AppData\Local\Android\Sdk\platform-tools\adb.exe"
adb start-server; adb connect <redacted-tailscale>:5555
adb push build/ggml/src/ggml-opencl/libggml-opencl.so /data/local/tmp/
adb push build/ggml/src/libggml.so                  /data/local/tmp/
adb push build/moe_probe4                           /data/local/tmp/
adb shell "chmod 755 /data/local/tmp/moe_probe4 && \
  rm -rf /data/local/tmp/llama.cpp/cl-cache && \
  cd /data/local/tmp && LD_LIBRARY_PATH=/data/local/tmp ./moe_probe4"
```

坑位备忘：

- **每次实验必须 `rm -rf cl-cache`**（Adreno 驱动 CL 程序缓存，不清会跑旧内核）。
- Git Bash 下 adb 路径参数须 `MSYS_NO_PATHCONV=1`；daemon 每条命令被回收，
  `start-server + connect + 操作` 须链在同一条命令里。
- `-cl-opt-disable` 会让 Adreno 编译器直接 segfault，不要用。

## 测试形状

| 用例 | 形状 | 对应 |
|------|------|------|
| REAL-gateup/down / PREFILL-tok4 | Ling-3.0-tiny 实际层 | q4_0 |
| Q4K-gateup / Q4K-down / Q4K-PREFILL-tok4 | 同形状 q4_K | q4_K |

## 诊断环境变量

| 变量 | 作用 |
|------|------|
| `MOE_PROBE_UNI=1` | 全 slot 指向同一专家——各 slot 输出应彼此一致，查跨 slot 泄漏 |
| `MOE_PROBE_SAME=1` | expert-0 数据复制到全部专家——排除 per-expert 基址偏移 |
| `MOE_PROBE_DUMP=1` | 打印 slot 0/1 的 ref/got 前 6 值 + best-matching slot 置换检查 |
| `MOE_PROBE_KREF=1` | CPU 逐 k-block 参考贡献 + KSCAL 期望 scale + RAW 原始 12 字节码/d/dmin hex |
| `GGML_OPENCL_MOE_KDBG=1` | 内核侧 dbg：逐 (col,k) 贡献/s/m + 解码 sv/mn + cs 原始 24 字节 + d/dm/regA 位型（host 回读打印，static 一次性） |

App 侧开关：`GGML_OPENCL_BATCHED_MOE=0` 强制 dense-loop（正确性基准），
`GGML_OPENCL_MOE_DEBUG=1` 打印 batched dispatch 全部标量参数。

## 已知结论（2026-10-14 定案 → 当日修复）

- q4_0 batched：全形状 NMSE=0，**已上线**（App 默认路径）。
- q4_K batched：**已修复上线（预计算 scale dodge）**。内核改为消费 host 预计算
  的有效 scale 平面 seff=d·sc / meff=dm·mn（fp16、half2 行对打包，per 32-block），
  scale 读取退化为与 q4_0 batched（NMSE=0）结构相同的纯 half2 加载——整套
  `get_scale_min_k4` + 三平面 6-bit mask 重组子系统从内核中移除（移到 set_tensor
  的 host 一次性预计算，见 `ggml_tensor_extra_cl_q4_K::seff/meff`）。真机探针
  **11/11 形状 NMSE=0~1e-6，重跑位级一致**；GPU bench 与 q4_0 batched 同档
  （gateup 199us vs 198us）。seff/meff 缺失时自动回退 dense-loop（fallback 保留）。
- 修复前的驱动级证据链（原始三平面内核，留档）：
  1. **7 种代码形状改写 NMSE 位级不变**：VSB 宏变体 / `-cl-mad-enable` 开关 /
     dequant-once（mc3 式）/ 直线化 scale 解码（私有数组 cs[24]）/ 加 dbg 参数 /
     load-bearing printf（q6_K E031.41 先例，对 .47 无效）——含退化形状
     B1(K=256,E=1,used=1)；位级不变 ⇒ 与代码形状无关。
  2. **数据面位精确**：host clEnqueueReadBuffer 直读 s/d/dm 平面 == 原始 q4_K
     块内码（逐字节核对，含 6-bit 高位重组）；同 program 的 dense 内核对同一
     平面 NMSE=0。
  3. **内核内不自洽**（KDBG 决定性证据）：同一 s 平面地址（rp=0,sb=0）四个
     子群读出**互不相同**的字节；regA（q 权重 image，CL_R/UINT32）读回**浮点
     位型**（0x3df60000 式，低半全零 = 激活值特征）；d/dm half2 位型与所有平面
     都不匹配；同一内核源码换一次 .so 构建 KDBG 值即漂移。
  4. **同族缺陷在档**：vendor gemv_moe/gemm_moe q4_K"输出=正确值×错误常数"，
     vendored b11267 与上游 master 9d7d504 同挂。
  5. SPIR-V 绕行不可行：`CL_DEVICE_IL_VERSION = ''`（Adreno Android 驱动不收 IL）。
- 定位过程中的两个假阳性，复用时警惕：
  - 改动 ggml-opencl.cpp 后**若探针 Q4K 行突然全 PASS，先查 batched 入口
    disable 是否在场**（disable 在场时 Q4K 行走 dense-loop，PASS 是假的）；
  - 只有 `ninja moe_probe4` 不会重编 libggml-opencl.so，需显式 `ninja ggml-opencl`。
- 其它诊断 env：`MOE_PROBE_ONLY=Q4K|Q40` 只跑一族（缓存隔离实验用）。
