# Bonsai-2 27B + OpenCL "一推理就死机" 根因：整机 OOM 回收风暴打死 system_server

> 日期：2026-09-27 · 分支 `spike/opencl-bonsai2` · 设备 Xiaomi 25053RT47C（8 Elite，**11.0GB RAM**）
> 关联：[`ptq1_0_opencl_bonsai2_2026-09-27.md`](ptq1_0_opencl_bonsai2_2026-09-27.md)（内核实现）、
> [`bonsai2_vulkan_research_2026-09-27.md`](bonsai2_vulkan_research_2026-09-27.md)

## 现象

Ternary-Bonsai-2-27B-PTQ1_0.gguf（5.95GB）+ OpenCL 后端，App 加载/推理后**整机卡死**，
连死三回；第二次起手机开机几分钟后自行重启。logcat 无任何 llama/OpenCL 报错。

## 排查过程（关键方法）

1. **现场不在 logcat 里**——system_server 死时 logd 一起死，`logcat -d` 重启后只剩新 boot。
   实时抓取（本次两份）显示：OpenCL init 正常（`ggml_opencl: selected platform / device`），
   用户点加载后 ~3 秒链路随死机中断。
2. **跨重启取证靠 dropbox**：`adb shell dumpsys dropbox --print system_server_pre_watchdog`
   命中 2026-09-27 17:32:22 转储（`sys.boot.reason=reboot`，无 KERNEL PANIC 条目 = 内核没崩）。
3. 转储三件套直接定罪：
   - `Subject: Blocked in monitor Watchdog$BinderThreadMonitor ... for 30s`（main/display/AM/Power 全阻塞）
   - `/proc/pressure/memory`：`some avg60=19.31 / full avg60=12.30`（内存停滞病危级）
   - `kswapd0` 5.5% CPU；system_server **11897 major faults**；tongyilite 385 major faults；
     整机 CPU 总占用仅 15%——全部卡在内存回收上。

## 根因

Adreno 是 UMA：OpenCL/Vulkan 的权重和 KV **就是系统 RAM**。该机 MemTotal 仅 11.0GB、
日常 MemAvailable ≈ 3.5-5GB。bonsai2 + OpenCL(n_gpu_layers=100, n_ctx=4096) 需求：

```
权重 GPU 拷贝 5.95GB（必 resident）
+ KV cache f16 数 GB（也在 GPU/RAM）
+ mmap 权重文件工作集（回收风暴前 ~6GB 冷页）
≈ 8-11GB ≫ 可用 4-5GB
```

→ 内核回收风暴（kswapd + major fault 风暴）饿死 system_server → Watchdog 30s → **整机 reboot**。

对照实验天然成立：**一代 Bonsai 27B Q1_0（3.8GB）压线能活**（08-04 基准 OpenCL 8.77 tok/s）；
CPU 后端能活是因为权重是 mmap 文件页（可回收），GPU 后端是必 resident 拷贝。
PTQ1_0 OpenCL 内核本身无罪：test-backend-ops 174/174（含奇数尾行与 Bonsai 形状）为证。

## 修复（本次已落地）

1. **JNI OOM 守卫**（`tongyilite_jni.cpp`，`[oom-guard]`）：建 ctx 前读
   `/proc/meminfo MemAvailable`，估算 `GPU 权重（按 GPU 层数比例折算 + dspark 草稿）
   + KV(n_layer × kv_dim × f16 × n_ctx) + 1.5GB 头量`：
   - 超预算但 n_ctx≥512 放得下 → **自动下调 n_ctx**（应用内推理日志横幅提示）；
   - 连 512 都放不下 → **拒绝加载**，提示"调低 GPU 层数或改用 CPU 后端"。
   宁拒绝，不死机。
2. **内核尾行读 clamp**（`mul_mv_ptq1_0_f32.cl`）：`ax[row]` 读指针钳到 `ne01-1`
   （写本有 guard、读没有；尾块越界读最后一个 cl_mem 之外的页理论上可触发 SMMU 故障，
   顺手堵雷，数值行为不变）。
3. **目录元数据**：bonsai2 `minRamMB` 8192→16384，加"需≥16GB内存"标签。
   注意 `minRamMB` 仅元数据（Dart 端无强制执行），真正的闸是 JNI 守卫。

## 结论与边界

- **这台 11GB 手机 GPU 全载 bonsai2 物理不可能**；要跑只有：CPU 后端（慢但能活）、
  或调低 GPU 层数让守卫算得过账（部分 offload）。
- 该守卫同样护住 Vulkan/任何 UMA 后端的大模型加载——死机不是 OpenCL 专属，是内存问题。

## 验证协议（防再次死机）

1. 打包装守卫版 → 加载 bonsai2 + OpenCL：应看到 `[oom-guard]` 横幅（拒绝或降 n_ctx），手机不死。
2. 若守卫自动降到 n_ctx≈512-2048 仍要求高内存：先 `调低 GPU 层数`（如 8-16 层）再试。
3. 死机若复发：先 `dumpsys dropbox --print system_server_pre_watchdog` 看 PSI 三件套再分析。
