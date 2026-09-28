# Vulkan / Bonsai-2（PTQ1_0）三值适配：Turnip 与原厂驱动真机验证记录

> 日期：2026-09-28 · 分支 `spike/opencl-bonsai2-ptq1-gemm`（基 `spike/opencl-bonsai2` + PTQ1_0 GEMM `d6a5ecf` + FWHT 门控 `1b8c67c`）
> 设备：Redmi Turbo 4 Pro（SM8735 / Adreno 825），原厂驱动 0800.71 与 App 内 fork Turnip（`libturnip_freedreno.so`，v26.3.0-20260918-r6 KGSL）双驱动 A/B
> 构链：本机 MinGW(host gcc 15.3 + NDK r27 clang) 交叉编 Android arm64 CLI（`test-backend-ops`/`llama-cli`），glslc = NDK r27 shader-tools
> 测试二进制与日志：设备 `/data/local/tmp/vkptq/`（t_*.log、e2e_*.log）

## 0. 结论（TL;DR）

1. **PTQ1_0 全算子数值双驱动全绿**：`-o MUL_MAT -p ptq1_0` 在原厂+三药 **155/155**、Turnip+三药 **155/155**（Bonsai-2 全形状 m=67/70、k=1024/5120/6144/17408、n=1..8，含 matmul_id）。
2. **FWHT subgroup shuffle 在 Turnip 上实锤错编**：`GGML_VK_FWHT_SUBGROUP=1` 时 `MUL_MAT_HADAMARD` 8/27（21 FAIL）；默认门控（shmem 变体）27/27。**生产禁开 FWHT_SUBGROUP**。原厂驱动 shuffle 无罪（27/27）——错编是 Turnip 特有，与 spike 文档 P0 预判一致。
3. 原厂裸跑仍 `createComputePipeline: ErrorUnknown`（三药前决不可用）。
4. **遗留缺口：Turnip e2e 乱码（tbo 全绿 vs 全模型乱）**——`-fa off` 同样乱（FA 排除），全算子 tbo 扫描定位中（见 §3）。
5. e2e 正确性参照：原厂+三药 e2e 连贯英文零乱码（"We need answer user's request..."）。

## 1. 测试矩阵与结果

| # | 驱动 | 配置 | 测试 | 结果 |
|---|------|------|------|------|
| 1 | 原厂 0800.71 | 裸跑（无药） | MUL_MAT ptq1_0 单形状 | ❌ `vk::Device::createComputePipeline: ErrorUnknown` |
| 2 | 原厂 | 三药 | MUL_MAT ptq1_0 全套 | ✅ 155/155 |
| 3 | 原厂 | 三药 + FWHT_SUBGROUP=1 | MUL_MAT_HADAMARD | ✅ 27/27（shuffle 无罪） |
| 4 | 原厂 | 三药 | e2e 2+2 | ✅ 连贯英文，0.6/0.2 t/s |
| 5 | Turnip | 三药（生产配置） | MUL_MAT ptq1_0 全套 | ✅ 155/155 |
| 6 | Turnip | 三药（默认门控 → shmem FWHT） | MUL_MAT_HADAMARD | ✅ 27/27 |
| 7 | Turnip | 三药 + FWHT_SUBGROUP=1（shuffle 首验） | MUL_MAT_HADAMARD | ❌ **8/27，21 FAIL** |
| 8 | Turnip | 三药 | e2e 2+2 | ❌ **乱码**（多语言碎片混合） |
| 9 | Turnip | 三药 + `-fa off` | e2e 2+2 | ❌ 乱码（FA 排除） |

三药 = `GGML_VK_NO_SUBGROUP=1 GGML_VK_NO_MMV=1 GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1 GGML_VK_DISABLE_FUSION=1`。
Turnip 直载 = `GGML_VK_TURNIP=/data/local/tmp/vkptq/libturnip_freedreno.so`（驱动提取自已装 App APK `lib/arm64-v8a/`）。

## 2. FWHT 门控补丁（1b8c67c，本次验证的核心防雷）

- 现象与机制：FWHT（tied-output 头每 token 必经）的 subgroup 变体判定原为
  `subgroup_basic && subgroup_shuffle`，不在三药门控内。实测 Turnip 上 shuffle 变体 21/27 数值错
  （蝶形 `subgroupShuffleXor` 被 Turnip 编译器错编），原厂同变体全对 → **驱动特有错编，而非算法/形状问题**。
- 补丁：判定叠加 `subgroup_arithmetic`（App 默认注入 `GGML_VK_NO_SUBGROUP=1` 后为 false）→
  自动落 `fwht_shmem_*` 变体；新增 `GGML_VK_FWHT_SUBGROUP=1` 供 A/B。
- 生产口径：**Turnip 上 FWHT_SUBGROUP 永久关闭**（vk_flags.conf 不配置该项）。

## 3. Turnip e2e 乱码定位（已定案）

- 症状：tbo 的 MUL_MAT/MUL_MAT_HADAMARD 全绿，但全模型输出 `.yahooabasorie grahtmugelhtmanski...`
  式碎片；`-fa off` 无改善 → 非 FA。
- 排除记录：全算子扫描 Turnip 上仅 `CONV_2D`(1158)/`CONV_TRANSPOSE_2D`(6) FAIL（qwen35 不用）；
  FA 全线错但 `-fa off` 同乱；hadamard 4096/8192 盲区补用例后 29/29 绿；原厂对照仅
  `GET_ROWS(iq4_xs)` 4 FAIL（上游已知，无关）。
- **根因定案（二分实测）**：Turnip 端 **GEMM 大 n 错编**——PTQ1_0 的 MMQ 与 f16 GEMM 双双中招：
  `m=5120` 二分 n=16/24/32 全对（8/8）、n=48/64/512 全错（ERR≈1.0 纯随机级）；
  f16 GEMM n=512 同错（n=64 也错）。**原厂驱动同 shader 16/16 全绿** → 驱动特有，shader 无罪。
  App 的 libggml-vulkan.so（shaderc v2026.3）同样大 n 全错 → **glslc 版本假设证伪**，
  与 0.2.2 的 unpack8、subgroupAdd、FWHT shuffle 同谱系：Turnip gen8 编译器错编。
- `-ngl 16` 输出全 `0000…` 修正推论：其 prefill 仍是默认 ubatch=512 的大 n → 同一根因的
  表现变体，与 GPU/CPU 边界层、buffer 大小无关。
- **为何 0.2.3 时代 e2e 连贯**：App JNI 带 `n_ubatch=16` 限制 → prefill 恒走 n=16 安全区。
  CLI 未限 ubatch（默认 512）才踩雷。
- **验证闭环**：CLI e2e `-ub 16`（其余同 Turnip 生产配置）→ 连贯英文零乱码。
- **生产口径**：
  1. App 的 n_ubatch 上限保持 ≤32（现值 16），是 Turnip 上的正确性必要条件（JNI 层确认即可）；
  2. CLI/服务端用 Turnip 跑 Bonsai-2 必须 `-ub ≤32`；
  3. 大 ubatch 长上下文性能（MMQ 按 n≤32 分块调度，权重流量 ×⌈n/32⌉）留作优化项，非阻塞。

## 4. 复现入口

```bash
# 二进制：/data/local/tmp/vkptq/{test-backend-ops,llama-cli,*.so}（含 libomp.so）
# Turnip 直载（生产）：
LD_LIBRARY_PATH=$PWD GGML_VK_TURNIP=$PWD/libturnip_freedreno.so \
  GGML_VK_NO_SUBGROUP=1 GGML_VK_NO_MMV=1 GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1 GGML_VK_DISABLE_FUSION=1 \
  ./test-backend-ops -b Vulkan0 -o MUL_MAT -p ptq1_0          # 155/155
./test-backend-ops -b Vulkan0 -o MUL_MAT_HADAMARD             # 27/27 (shmem)
# ⚠️ Turnip 上禁用 GGML_VK_FWHT_SUBGROUP=1（8/27 数值错）
# e2e：
./llama-cli -m /storage/emulated/0/TongYiLite/models/bonsai-2-27b-ternary-ptq1_0.gguf \
  -ngl 99 -fa on -c 4096 --temp 0 -n 32 -st -p 'Question: What is 2 + 2? ...'
```

## 5. 遗留与下一步

- [x] Turnip e2e 乱码根因定案：Turnip 端 GEMM 大 n（≥48）错编（f16+MMQ 双中招，原厂全绿），App 靠 n_ubatch=16 避开；`-ub 16` e2e 连贯闭环
- [ ] App 侧确认 n_ubatch 上限 ≤32（生产安全闸）；MMQ 按 n≤32 分块调度留作长上下文优化项；llama-bench 性能基线（对照 OpenCL 路径）
- [ ] 桌面 Arc OpenCL PTQ1_0 GEMM 补丁（d6a5ecf）的 Adreno 真机 tbo 复测
- [ ] MTP/dspark 与 Bonsai-2 无关（一代专属），不做接线
- [ ] 全绿后：catalog `bonsai-2-27b-ternary-ptq1_0` 后端偏好 Vulkan + 需 ≥16GB RAM 标签复核
