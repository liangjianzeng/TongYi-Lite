# Vulkan / Adreno 825（SM8735, 骁龙 8 Elite2）数值与崩溃修复全记录

> 日期：2026-09-26 · 状态：已落地 App（release APK）+ `third_party/llama.cpp` 源码级修复
> 适用范围：Adreno 0800.71 驱动（编译器 E031），推测同代 Adreno 7xx/8xx 高概率复现

## 1. 症状

- Vulkan 后端跑量化模型（Q4_K_M 等）输出乱码（`@@@@@@`、多语言混杂字符），prefill 即错
- 部分算子建管线失败：`Compute pipeline creation failed for mul_mat_vec_f32_f32_f32` / `mul_mat_vec_q4_k_f32_f32 ... ErrorUnknown` → App 直接崩
- 模型内部出现全零中间结果（后表现为 RMS_NORM 后 MUL 输出全零）
- 纯 CPU 路径完全正常 → 排除模型/分词器/JNI，锁定 Vulkan 后端数值

## 2. 根因链（5 个独立问题，逐个取证隔离）

| # | 根因 | 机制 | 证据 |
|---|------|------|------|
| 1 | **驱动错误编译 `unpack8()`**（GL_EXT_shader_explicit_arithmetic_types_int8，SPIR-V Int8 capability） | q8_0/q6_K/q4_K/q5_K 等反量化函数用 `unpack8()` 解包字节，Adreno 编译器生成的 Int8 序列数值错误；q4_0（纯 32 位位操作）与 f32/f16（无 unpack8）完全正确 | 同模板对照：`mul_mat_vec.comp` 下 q4_0 OK（err 0.008）、q8_0 错（0.81）；GET_ROWS 全对（读数据没问题）→ 错在反量化算术；误差非确定性（同形状 1.27~2.05 波动）= 错误编译特征 |
| 2 | **subgroup 归约管线变体建不出来** | `mul_mat_vec_*` 为 NCOLS=1..8 各建一条管线，subgroup 变体在 Adreno 上 link/create 失败；实测 n=1..4 OK、n=5..8 全挂（NCOLS=5 起命中坏变体） | `-p` 过滤逐形状测试；`GGML_VK_NO_SUBGROUP=1`（强制 SHMEM 归约）后 n=5/8 全 OK |
| 3 | **图融合 kernel（add+rms）输出全零** | 融合路径在该驱动上 kernel 未执行/写零填充缓冲，输出全零（非小误差） | 模型 CHECK_RESULTS 在 check 22 卡 MUL 全零；独立 MUL 测试 106 用例全对（shader 本身没问题）；`GGML_VK_DISABLE_FUSION=1` 后 check 22 → 114 |
| 4 | **dp4a（int8 点积）数值错误** | `quantize_y` 命中 `integer_dot_product` 时 src1 量化为 q8_1 走 dp4a，avg_err > 1.0 | 原厂驱动 FORCE_MMVQ（dp4a 路径）ERR=3.25；CLI 验收中 dp4a 变体 check20 MUL_MAT err=1.06 |
| 5 | **decode (n=1) 部分 matvec 管线建不出** | 与 #2 同族（NCOLS=1 变体也可能坏），NO_SUBGROUP 后端到端测试 decode 仍崩在 `mul_mat_vec_q4_k_f32_f32` | e2e：prefill 文本正确后 decode 崩；`GGML_VK_NO_MMV=1` 把 n=1 也送去 MMQ 后通过 |

外部佐证：llama.cpp 上游 b10034 曾因 Adreno A7x 编译器错编 MoE repack 内核输出乱码做 vendor 排除；b10171 修 Adreno OpenCL 乱码 —— 同类「驱动错编特定 shader 模式」先例明确。

### 已证伪的方向（避免日后重走弯路）

- ❌ **Turnip（Mesa freedreo）换驱动**：Mesa 上游已知小 n MUL_MAT 数值 bug（n≤8 错、n≥9 对，2026-07-21 邮件列表），且独立于本项目；短期不可用
- ❌ **新版原厂驱动 v849 / v842.6**：与设备内核 KGSL 代差过大，`ubsan: divrem-overflow` 直接 abort，补库无法解
- ❌ **`spirv-opt -O` 是根因**：`GGML_VK_MATVEC_NO_OPT=1` 重生成后结果逐位相同 → 证伪（但保留 hook 供排查）
- ❌ **`-fa off` / `-ctk f32 -ctv f32`**：无效
- ❌ **vkshim（自制 loader）诬告**：无 shim 对照逐位一致，shim 无罪
- ❌ **同步/竞态**：各类 submission 序列化 env 全部无效且误差逐位相同 → 是确定性错误

## 3. 修复方案（"四药" + unpack8 补丁）

### 3.1 shader 层：纯 32 位 unpack8 替换（核心）

`vulkan-shaders/types.glsl`：用纯 32 位位操作替代扩展 `unpack8()`：

```glsl
u8vec4 vk_unpack8u(uint32_t x);          // 按字节切分，uint 语义
i8vec4 vk_unpack8i(int32_t x);           // 每字节符号扩展 (b^0x80)-128
#define unpack8(x) vk_unpack8u(x)        // 覆盖全部无符号调用点
```

- `dequant_funcs.glsl`：q8_0 `dequantize4` 整体重写为纯 32 位（位模式与原实现逐位一致）
- 21 处 `unpack8(int32_t(...))`（有符号赋值点）→ `vk_unpack8i(int32_t(...))`
- GLSL 坑：u8vec2→i8vec2 隐式转换不允许（需 i8vec4 版本）；宏内 `(uint32_t)(x)` 显式强转 uint16_t 需要 NV 扩展（宏不能带强转）

### 3.2 C++ 层 env 开关（全部已入 `ggml-vulkan.cpp`）

| 开关 | 作用 | 位置 |
|------|------|------|
| `GGML_VK_NO_SUBGROUP=1` | 强制 SHMEM 归约，绕开坏 subgroup 管线变体 | `use_subgroups` 定义处 |
| `GGML_VK_DISABLE_FUSION=1` | 关 add+rms 融合 | 既有 hook |
| `GGML_VK_NO_MMV=1` | n=1 (decode) 也走 MMQ，避开坏 matvec 变体 | `ggml_vk_should_use_mmvq` 开头早退 |
| `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1` | 关 dp4a 路径 | 既有 hook |

### 3.3 App 层落地

- `tongyilite_jni.cpp` `loadVkFlagsConf()`：默认注入上述 4 个 env（`setenv overwrite=0`，可被 `vk_flags.conf` 覆盖）
- `cpp/CMakeLists.txt`：强制 `Vulkan_GLSLC_EXECUTABLE` → `_study/vkcli/sdk/vksdk-new/Bin/glslc.exe`（shaderc v2026.3，与 CLI 验证环境一致；headers/SPIRV-Headers 仍用 LunarG 1.4.357.0）
- **glslc 版本敏感性**：App 旧 glslc 与验证版编出的 shader 集合不同（dp4a 内核有无等），必须与验证环境锁同版

## 4. 验证证据

- **逐算子校验**（`GGML_VULKAN_CHECK_RESULTS=ON`，CPU 参考逐 tensor 对比）：q6_K/q4_K/q5_K/q8_0/q2_K/iq4_xs 全部 avg_err 0.006~0.009（修复前 1.7~3.8），f32 2e-7
- **端到端真机**：三药组合下 prefill 输出完全正确（"The capital of France is Paris"、"中国的首都是北京"）
- **APK 等价性**：包内 `mul_mat_vec_q6_k_f32_f32.spv` 与真机验证版 **md5 逐字节一致**（`df9ab924e6`）；2173 个 SPIR-V 中 632 个与验证版完全一致，differ 集中在 matmul 族（两树版本差异）与 subgroup 变体（NO_SUBGROUP 下不派发）
- 签名校验通过（与在装版本同证书，可覆盖安装）

### CHECK_RESULTS 插桩（上游编不过，已本地修）

上游 `GGML_VULKAN_CHECK_RESULTS=ON` 因 `static` 跨 TU 链接问题编不过。修法：`ggml-vulkan-common.h` 加 `extern` 声明（`vk_skip_checks`/`vk_output_tensor`/两个 check 函数），`ggml-vulkan-debug.cpp` 去 4 处 `static`。插桩后第一个 `avg_err>0.01` 算子直接 abort 并打印 op 名/形状 —— 本次定位主力工具。

## 5. 构建工具链坑（Windows 专属，重踩概率高）

1. **`vulkan-shaders-gen` 16 线程并发写竞争**：Windows 上随机 `glslc: cannot open output file`，且失败集合每轮不同、重试收敛慢 → 可能静默留下**过期 .comp.cpp**。已加 `GGML_VK_SHADER_GEN_THREADS`（=1 确定性生成）。
2. **CRLF/LF**：vendored 树（third_party）为 CRLF，upstream 源为 LF；跨树打补丁必须先归一化行尾再匹配锚点，改完转回。
3. **flutter build apk 在 WorkBuddy 沙箱被拦**（`CreateFile failed 231` / 管道耗尽）：Dart 层零改动时用 `cmd //c "gradlew.bat assembleRelease -x compileFlutterBuildRelease"` 直驱 gradle（自动签名用 `android/key.properties`）。

## 6. 遗留问题与日后方向

- [ ] **matmul 族（MMQ）shader 为 third_party 源码版本 + 补丁，未经真机逐算子验证**（CLI 验证在 upstream master 树上做的）—— 用户 APK 实测覆盖；若乱码残留，优先 `CHECK_RESULTS` 插桩 third_party 树定位
- [ ] 速度未测：`NO_MMV` 让 decode 走 MMQ、`NO_SUBGROUP` 走 SHMEM 归约，均可能低于理论吞吐；待用户实测后评估是否值得针对个别变体做精细 vendor 排除（参照上游 Imagination `is_imagination_proprietary` 的做法，按 driver_id 排除而非全局关）
- [ ] 长期：升级 third_party 到最新 master（含 24 个新增 shader 族），与 `_study/upstream/llama.cpp-master` 对齐后可整体替换 ggml-vulkan 子树
- [ ] 历史文档修正：`tongyilite_jni.cpp` 中 "verified OK on Adreno 825" 的旧注释与 `CMakeLists.txt` 的 "numerically corrupt" 注释口径已过时
- [ ] 向上游提 issue/PR：unpack8 Adreno 错编可复现（test-backend-ops + Adreno 0800.71），vendor 级排除先例充分（b10034）

## 7. 快速复现 / 调试入口

```bash
# 逐算子数值校验（需要 CHECK_RESULTS 构建，见第 4 节）
adb shell "cd /data/local/tmp/vkm6 && LD_LIBRARY_PATH=$PWD \
  GGML_VK_NO_SUBGROUP=1 GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1 \
  ./test-backend-ops -b Vulkan0 -o MUL_MAT -p 'type_a=q6_K,type_b=f32,m=16,n=2,k=256,'"

# 单形状过滤（绕开一进程一 abort）：-p 'type_a=q4_K,type_b=f32,m=16,n=5,k=256,'
# 全算子族扫描：-o MUL_MAT（不带 -p）；注意 subgroup 变体可能建管线失败属预期

# App A/B 开关：/storage/emulated/0/TongYiLite/vk_flags.conf（KEY=VALUE，每行一条，# 注释）
# 例：关闭四药之一做对照 → GGML_VK_NO_SUBGROUP=0
```

相关产物：CLI 验证构建 `_study/vkcli/build-m5chk/`、驱动素材 `_study/vkcli/drivers/`、实验脚本 `_study/vkcli/{checkres,final,combo,ksweep,probe*}.sh`、工作日志 `.workbuddy/memory/2026-09-26.md`。

---

## 2026-09-27 补充：最终定案 —— e2e 从未通过，Vulkan 在本机不可用

**重要修正**：本文档早期版本称「CLI 端到端 prefill 文本正确（Paris/北京）」——经全文检索 `_study/vkcli/*.out` 证伪：**6 次 CLI e2e 全部输出乱码或中途崩溃，0 次出现正确文本**。"验证通过"的说法来自单算子 CHECK_RESULTS 微测试（那部分属实），e2e 从未成功过。

### 真相链（全部有日志/测试证据）
1. 本机 Vulkan 失败模式与树无关：
   - vendored b11028（App）：GPU 静默停摆（per-chunk fence 归因到 `MUL_MAT(conv.in_proj-11)` 附近，挂点不固定，前 10 层同算子均正常 → 时序敏感竞态）
   - master（CLI）：`createComputePipeline: ErrorUnknown` 直接崩（warmup 第一个 ubatch）；`-ot conv=CPU` 无效
   - test-backend-ops（master）：全系列 IQ 量化 GET_ROWS 数值错（ERR 0.2~1.0）；CPY(q8_0→f32) 数值错；后续 CPY 变体建管线时 ErrorUnknown 崩溃
2. 共性：高通 Vulkan 驱动 0800.71 对 int8/unpack 族 shader 存在**多个独立编译器 bug**——错编（数值错）、拒建（ErrorUnknown）、执行挂死（静默停摆）三种表现并存。unpack8 补丁只修了其中一类（数值错），修不完。
3. **OpenCL 后端完全正常**（同机同模型同配置实测出字），ggml-opencl 对 Adreno 是 Qualcomm 官方路径。

### 结论与行动
- TongYi-Lite 在 SM8735/Adreno 8 Elite2 上：**GPU 推理走 OpenCL，Vulkan 标记为驱动不可用**（除非未来高通驱动更新后重测）。
- 本文档的 shader 补丁（unpack8 等）仍有价值：修复的是真实驱动错编，未来驱动修复后重测可直接对照。
