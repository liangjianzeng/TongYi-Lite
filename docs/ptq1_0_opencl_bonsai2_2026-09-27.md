# PTQ1_0 三元量化（Bonsai-2 27B）：OpenCL 内核实现机制

> 日期：2026-09-27 · 分支 `spike/opencl-bonsai2`（v0.2.5）
> 关联文档：[`bonsai2_vulkan_research_2026-09-27.md`](bonsai2_vulkan_research_2026-09-27.md)（Vulkan 侧调研）、[`vulkan_adreno825_fix_2026-09-26.md`](vulkan_adreno825_fix_2026-09-26.md)（Turnip 修复）

## 背景与结论

Bonsai-2 27B 用 GGML `type 143`（PTQ1_0）三元量化（-1/0/1，28 字节/128 值），全模型 402 个 PTQ1_0 张量。上游 llama.cpp 的 OpenCL 后端只有 Q4/Q5/Q8 系列 mul_mv 内核，PTQ1_0 无对应内核 → 全部经 `get_rows`/`CPY` 回退 CPU，decode 极慢；Vulkan 侧旧实现实测在 Adreno 825 不可用，故在分支 `spike/opencl-bonsai2` 新增 OpenCL 内核实现全 GPU decode。

## 块结构（`block_ptq1_0`，与 `ggml-quants.c` 一致）

- `qs[24]` + `qh[2]` + `half d`（块 scale = 块内最大绝对值），28 B / 128 个三元值（trits）；
- 128 个 trit 分三段铺在字节上：`qs[0..15]` 每字节放 5 个（间隔 16）共 80 个、`qs[16..23]` 每字节放 5 个（间隔 8）共 40 个、`qh[0..1]` 每字节放 4 个（间隔 2）共 8 个。

## 编码（量化工具 `quantize_row_ptq1_0_ref`）

三元值先 `xi = round(x/d) + 1 ∈ {0,1,2}`；一个字节以三进制装下 5 个三元值（`q = xi_0 + xi_1*3 + xi_2*9 + xi_3*27 + xi_4*81 ∈ [0,242]`），再按 `(q*256 + 242) / 243` 展开到 8 位（0 保持 0，1..242 展开到 2..255，为解码留出裕度）。

## 解码（C 参考 `dequantize_row_ptq1_0` 与内核同一式）

取字节 `b`，第 n 个（n=0..4，qh 段 n=0..3）三元值：`t = (b * 3^n) & 0xFF`，`xi = (t * 3) >> 8 ∈ {0,1,2}`，值 = `(xi - 1) * d`。

## 内核并行（`mul_mv_ptq1_0_f32.cl`，Adreno 64-wide subgroup）

- `N_SG=2` subgroup/work-group、`N_R0=4` 行/subgroup；每 lane 负责每块连续的 `128/64 = 2` 个 trit，对 4 行各做 `(xi-1)*d*y` 累加，`sub_group_reduce_add` 在 64 lane 内归约，subgroup 首 lane 写 `dst[row]`；
- 上传：PTQ1_0 权重按 raw 块布局直接入显存（无 SoA 转换）；
- host 门控（`ggml_cl_can_mul_mat`）：`src1` f32、dst f32、各轴 ≥32，且 `src0` 为 PTQ1_0 时要求 `ne[0] % 128 == 0`（整块对齐），否则回退 CPU；dispatch 以 19 个参数传入块指针/偏移。

## Adreno 编译器陷阱（本次核心教训）

内核初版用 `__constant uint pow3[5]` 变址取 `3^n`。Adreno OpenCL 编译器把 `pow3[4]`（值 81）误编成恒读 0 → 每块 n=4 的 16 个 trit 全解成 -1，dot 系统性偏差。症状极具欺骗性：权重字节和 wsum 全对、只有内积对不上（数据正确、数值错误，编译器 bug 特征）。

定位：内核 printf 全 128 值落盘 + Python 用相同字节重算 dot（内核 -7.30 vs 真值 -7.40）。

修复：弃用所有 `__constant` 数组索引，改三元表达式 `(n==4)?81:(n==3)?27:(n==2)?9:(n==1)?3:1`，并从内核删除 `__constant` 数组。

## 验证（真机 Adreno 825，`test-backend-ops`）

- MUL_MAT PTQ1_0 套件 **174/174 OK**（`max_nmse_err=5e-4`；CPU 参考为 `vec_dot_ptq1_0_q8_0`，q8_0 的 y 自带 ~0.004 噪声，阈值留了余量）；
- 含 67 个奇数尾行与 Bonsai 形状；删光调试代码后复测仍绿。

## 已知边界

- `CONV_2D cwhn=1+dilation` 是旧后端遗留 FAIL（ERR ~1.96，与本移植无关）；
- 27B 全模型 tok/s 待设备连 USB 后补测。
