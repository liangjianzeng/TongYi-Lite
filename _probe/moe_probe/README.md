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

App 侧开关：`GGML_OPENCL_BATCHED_MOE=0` 强制 dense-loop（正确性基准），
`GGML_OPENCL_MOE_DEBUG=1` 打印 batched dispatch 全部标量参数。

## 已知结论（2026-10-14）

- q4_0 batched：全形状 NMSE=0，**已上线**（App 默认路径）。
- q4_K batched：NMSE 1.27/23.5/2.6，**5 种代码形状改写位级不变**
  （VSB 宏变体 / mad / dequant-once / 直线 scale 解码），同程序 dense 内核对
  同一平面数据位精确，UNI 无泄漏 ⇒ 根因未定（疑 Adreno E031 误编但未躲开）。
  **发布版入口直接禁用**（`ggml_cl_mul_mat_id_batched` 内 `if (is_q4_k) return false`），
  修复后删除该行并跑本探针验证。
