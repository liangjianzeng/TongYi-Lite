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

## 3. Turnip e2e 乱码定位（进行中）

- 症状：tbo 的 MUL_MAT/MUL_MAT_HADAMARD 全绿，但全模型输出 `.yahooabasorie grahtmugelhtmanski...`
  式碎片；`-fa off` 无改善 → 非 FA；decode/prefill 均走已验证路径。
- 全算子扫描结果：Turnip 上仅 `CONV_2D`(1158)/`CONV_TRANSPOSE_2D`(6) FAIL（qwen35 架构不用）；
  FA 全线错（sinks=0/1 共 2405 FAIL）但 `-fa off` 同乱已排除；其余算子族（ROPE/NORM/SOFTMAX/GLU/
  GET_ROWS/CPY…）全绿。原厂对照仅 4 个 `GET_ROWS(iq4_xs)` FAIL（上游已知，与 Bonsai-2 无关）。
- hadamard 宽度盲区假设**证伪**：tbo 补 4096/8192 用例后 `MUL_MAT_HADAMARD` 29/29 全绿（shmem）。
- 大 buffer（>4GB）假设：Turnip + `-ngl 16`（GPU buffer ~2GB）输出亦异常，实验中止，**未定案**。
- **下一步（最快分叉判定）**：用 App 真身（spike 分支 APK：shader 与 0.2.3 验证环境同源、
  JNI 自动注入三药+Turnip）跑 Bonsai-2 e2e——App 乱 → 树/代码层问题；App 连贯 → CLI 交叉构建
  环境差异（NDK glslc vs 验证环境 shaderc v2026.3，0.2.2 文档明示 glslc 版本敏感性）。
  备选重手段：`GGML_VULKAN_CHECK_RESULTS` 插桩定位首个错算子。

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

- [x] Turnip 全算子扫描：仅 CONV_2D/CONV_TRANSPOSE_2D FAIL（qwen35 不用）；FA 已排除；hadamard 4096/8192 盲区已补用例并证伪
- [ ] Turnip e2e 乱码根因定案（§3 下一步：App 真身分叉判定）→ 修复 → llama-bench pp/tg 性能（对照原厂三药 0.6/0.2 t/s、OpenCL 路径）
- [ ] 桌面 Arc OpenCL PTQ1_0 GEMM 补丁（d6a5ecf）的 Adreno 真机 tbo 复测
- [ ] MTP/dspark 与 Bonsai-2 无关（一代专属），不做接线
- [ ] 全绿后：catalog `bonsai-2-27b-ternary-ptq1_0` 后端偏好 Vulkan + 需 ≥16GB RAM 标签复核
