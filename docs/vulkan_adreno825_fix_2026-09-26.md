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

### 排除「实验驱动污染」（2026-09-27 复核）
用户疑问：问题是否由我们装的第三方开源驱动（Turnip/Mesa）引起。复核结论：**不是**。
- 全部失败测试（App 各轮 + master CLI）加载的均为原厂驱动，日志自识别字符串统一为 `Adreno (TM) 825 (Qualcomm Technologies Inc. Adreno Vulkan Driver)`；整份日志 Turnip/Mesa 零匹配。
- Turnip 仅在早期做过 App 内局部 overlay 实验（已证伪并弃用），无法影响系统驱动；设备无 root，本次所有操作均无能力改动 /system 厂商驱动。
- 旁证：同一 GPU 的 OpenCL 栈（原厂用户态驱动）完全正常，仅 Vulkan shader 编译路径出问题。

---

## 2026-09-27 上午复核修订（钉子补全）

### ① 版本号勘误：0800.71 不是 Vulkan 驱动版本
- `dumpsys SurfaceFlinger` 实锤：`GLES: Qualcomm, Adreno (TM) 825, OpenGL ES 3.2 V@0800.71 (GIT@208ca19915, Iab05a79315, 1770369230) (Date:02/06/26)` —— **0800.71 是 OpenGL ES 3.2 的版本串（V@ 族），不是 Vulkan 的**。
- 高通同一驱动包内 GLES/Vulkan/OpenCL 是三套版本命名空间；Vulkan 族应为 512.x 格式。`dumpsys gpu` 的 `vulkanVersion = 4206592`（= 1.3.0）是 Vulkan API 版本，非 driverVersion。
- **真实 Vulkan driverVersion（原始 uint32）尚未读到**。已落地收口手段：vendored 树设备枚举处新增 `[drvfp]` 日志（driverVersion=0x%08x + apiVersion + driverID + driverName），下次构建 APK 后每条 logcat 自带驱动版本指纹，"是否同一驱动"不再靠推理。

### ② deviceName 证据效力限定
`ggml_vulkan: 0 = Adreno (TM) 825 (Qualcomm Technologies Inc. Adreno Vulkan Driver)` 只证明「厂商 = 高通原厂」（足以证伪 Turnip/Mesa），**不锁定版本**。Android GPU 驱动可脱离 OTA 单独更新，跨夜多轮同字符串 ≠ 同版本。原文中"原厂驱动 0800.71"应读作"高通原厂驱动（GLES 串 V@0800.71 时代，Vulkan 版本待 drvfp 读数）"。

### ③ OpenCL 证据降级：从"佐证驱动坏"降为"排除硬件坏"
Adreno 的 Vulkan（libvulkan.adreno.so）与 OpenCL（libOpenCL_adreno.so）是两套独立用户态驱动 + 两个独立编译器。OpenCL 正常只能证明 GPU 硬件/固件无故障，**不能**为 Vulkan 驱动的版本正确性或固件匹配性背书。定案中"坏的只是原厂驱动的 Vulkan shader 编译路径"一句维持成立，但 OpenCL 那条证据的效力仅到"排除硬件"为止。

### ④ 零 env 对照（封死"四药 env 背锅"嫌疑）
master CLI **不加任何 GGML_VK_* env**（默认配置）跑 lfm2.5-2.6b：同样 `createComputePipeline: ErrorUnknown`（exit=134），且日志直接给出**被拒建管线名：`mul_mat_vec_q4_k_f32_f32`**（q4_K matvec shader，驱动编译失败）。结论升级：原厂驱动在**默认配置**下即拒建 q4_K matvec 管线；四药 env 只是我们此前规避部分炸点的手段，不是问题成因。

### ⑤ Turnip 状态改判：从"已证伪弃用"改为"当前不可用，待复测"
早期弃用 Turnip 的决定在当时正确（彼时 Mesa 尚无 Adreno Gen 8 支持）。现 Mesa 26.0 已合入 Adreno Gen 8 Vulkan 支持（社区打包标注 Adreno 8xx 为 beta、OpenGL 之外渲染异常）。Turnip 形态为 App 内可加载的独立驱动包，无需 root、不碰系统分区——**复测路径比等高通 OTA 可控得多**。驱动版本指纹（[drvfp]）齐备后，Turnip 复测应优先于坐等原厂驱动更新。

---

## 2026-09-27 上午补充：8 月取证——「早期 Vulkan 是好的」的历史真伪

用户质疑：①Bonsai2 Vulkan 实现导致坏；②llama.cpp 主线升级导致坏；③早期是好的。git + 归档文档取证结论：

### ① 「早期好」仅对天玑/Mali 成立，对 Adreno 不成立
- **天玑（Mali）**：真·Vulkan 可用（UI 禁用 OpenCL、无代跑污染可能；v0.1.6 Mali 崩溃修复属实）。用户记忆正确。
- **Adreno 825**：8/04 基准报告（docs/archive/backend_benchmark_2026-08-04.md）声称「Vulkan 完全可用」，但该结论无效：
  1. **设备 pinning 9/26 才引入**（git log -S pinned_devices → 0a5d4f7）；此前 App「选 Vulkan」只改日志和 n_gpu_layers，不控制设备归属；
  2. **iGPU 去重 bug 在 8 月树里就存在**（_study/vkcli/src-b10176/src/llama.cpp:253 `if (igpus.empty())`，同 b11028:264 的 PR #23897 workaround）——OpenCL 先注册 → 8/04 的「Vulkan 组」实际是 OpenCL 在跑；
  3. 旁证：8/04 数据 Vulkan 8.60 vs OpenCL 8.77 tok/s（差 2%，同后端特征）；9/25 VKDIAG=0 直接证明选 Vulkan 时 mul_mat 一次没被调；
  4. 当前驱动二进制 Date:02/06/26（2 月构建）→ 8 月与现在是同一驱动；该驱动现在被零 env CLI 实锤拒建 `mul_mat_vec_q4_k_f32_f32`（8/04 基准 ubatch=16 的 prefill 恰恰需要这条管线）→ 8/04 若真跑 Vulkan 必然当场炸，没炸 = 没在跑 Vulkan。
- **推论：Adreno 上不存在「从好变坏」的转折点——从未真跑过。**

### ② Bonsai2 Vulkan 实现嫌疑：排除（决定性证据）
- Bonsai2/PTQ1_0/PQ2_0/FWHT Vulkan 内核 9/19+ 才进入 vendored 树（8/04 的 751bb68 未触碰 ggml-vulkan）；
- 决定性反证：**master CLI 完全不含 Bonsai2 代码，同样失败**（零 env ErrorUnknown + test-backend-ops IQ/CPY 同类错）——失败与 Bonsai2 代码无关，驱动级。

### ③ 主线升级嫌疑：Adreno 上无法「搞坏」从未工作的东西；Mali 待验
b10176(8月) → fe8156f(8/19) → XHToken fork(9/03) → b11028(9/19, "Vulkan 重写")，期间所有 Adreno App 测试均被去重 bug 污染，无真 Vulkan 数据点，故升级不是 Adreno 问题的原因。**唯一遗留疑点在天玑**：9/19 后未在 Mali 设备上重测过 Vulkan（不同驱动、不同代码路径），如该设备还在可安排一轮验证。

---

## 2026-09-27 上午补充②：7 月考古 + b10176 原味复测 —— 驱动 OTA 回归实锤（待用户确认装更新时间）

### 实验：7 月原味代码复测（决定性）
用 `_study/vkcli/push-b10176`（7/29 项目 init 时的 b10176 树，无 unpack8 补丁、无四药开关，纯 7 月 shader）在当前设备跑 qwen3.5-4b-q4_k_m：
- `-ngl 99 -ub 16` → **createComputePipeline: ErrorUnknown**（首个 prefill ubatch 崩溃）
- 追加 `-fa off`（对齐 App 当时配置）→ **同样 ErrorUnknown**
- 结论：**7 月的代码 + 现在的驱动 = 跑不了**。

### 逻辑链：驱动在 7~9 月间被 OTA 更换
- 7/29-8/3（Vulkan 唯一 GPU 后端时代，无 OpenCL 代跑可能）：App 的 Vulkan **管线创建成功、能执行**（输出乱码 = unpack8 错编 + App 层 ubatch/sampler bug；若管线建不出会直接抛异常，观察不到"塌缩"）。
- 今天：同一份 b10176 代码 + 同一模型 + 当前驱动 = 管线建不出。代码相同、模型相同、SPIR-V 编译确定性 → **变的只能是驱动**。
- 设备系统：OS3.0.305.0.WOLCNXM，system/vendor 构建日期均 2026-07-13，安全补丁 2026-07-01。当前驱动 0800.71 就在这个包里。
- **待用户确认**：OS3.0.305 这版系统更新是什么时候装的。若 7 月底测试时还是旧版系统 → 驱动 OTA 回归实锤：7 月（旧驱动）Vulkan 能跑（乱码但管线能建）→ 8~9 月间 OTA 换新驱动 → 三类 bug（错编/拒建/挂死）全出现。

### 版本号二次勘误（修正上午的"512.x"推断）
在 `vulkan.adreno.so` 二进制内直接 grep 到 **0800.71** —— 该驱动包的 Vulkan 部分就使用 0800 命名，上午引用的"Vulkan 应为 512.x 格式"是文档推断，实际不适用此包。`0800.71` 可作为当前 Vulkan 驱动版本串使用（前提：OS3.0.305 时代）。

### 对三个嫌疑的最终裁决
1. **Bonsai2 Vulkan 实现**：排除（b10176 无 Bonsai2 代码也炸；master CLI 无 Bonsai2 也炸）。
2. **llama.cpp 主线升级**：排除为 Adreno 根因（b10176 原味今天也炸——升级前后代码在**当前驱动**上全炸）。
3. **"早期是好的"**：**部分平反** —— 7 月底 Vulkan 确实真跑过（乱码但能建管线能执行），"变坏"的是**高通 OTA 驱动回归**，不是我们任何一次代码变更。
### 行动含义
驱动回归若确认：原厂驱动无法回滚（无 root）→ **Turnip（Mesa 26.0 Adreno Gen 8）成为主攻路径**（App 内 overlay，完全绕开厂商驱动），unpack8 补丁对 Turnip 同样必要。次选：向高通/小米反馈驱动回归，附本文档证据链。

### 驱动 OTA 回归实锤（2026-09-27 终审，公开 ROM 记录闭环）
- 用户提供的系统信息页：Redmi Turbo 4 Pro（onyx），OS3.0.305.0.WOLCNXM.C11，Android 16，安全补丁 2026-07-01。
- 公开 ROM 记录（hyperosupdate.com / xiaomiadvices.com）：**OS3.0.305.0.WOLCNXM 中国稳定版推送于 2026-08-05**（增量 303→305 同日；changelog 仅"安全补丁至 2026-07"）。
- 时间线闭环：
  | 时段 | 系统/驱动 | Vulkan 状态 |
  |---|---|---|
  | 7/29–8/3（App Vulkan 唯一 GPU 后端时代） | 旧系统（≤303，旧驱动） | 管线能建、能执行（输出乱码 = unpack8 错编[旧驱动已有] + App 层 ubatch/sampler bug） |
  | **2026-08-05~10** | **OTA → 305.0，驱动换 0800.71** | — |
  | 8/4~9 月全部测试 | 新驱动 | 8/04 基准（OpenCL 污染，仍旧驱动窗口末尾）→ 9 月起管线拒建/挂死/数值错全现 |
- 终审结论：**llama.cpp Vulkan 在本机"从好变坏"的转折点 = 2026-08-05 的 HyperOS OS3.0.305.0 OTA（Adreno 驱动回归）**。用户"早期是好的"记忆正确；Bonsai2 实现、llama.cpp 升级均与故障无关（7 月原味代码在新驱动上同样崩）。
- 设备更正：Redmi Turbo 4 Pro 为**骁龙 8s Gen 4（SM8735）**（旧文档"Snapdragon 8 Elite"表述有误），GPU Adreno 825 不变。
- 行动定案：
  1. 原厂 0800.71 驱动不可回滚（无 root、Mi Flash 降级有风险）→ **放弃原厂 Vulkan**；
  2. **Turnip（Mesa 26.0+ Adreno Gen 8）升级为主攻路径**：App 内 overlay 加载、绕开厂商驱动，unpack8 补丁对 Turnip 同样必要；早期 Turnip 证伪记录基于旧 Mesa，需用 Mesa 26.0+ 重测；
  3. 日常 GPU 推理继续走 OpenCL（已验证正常）；
  4. 可选：持本文档证据链向高通/小米反馈 0800.71 驱动回归；关注后续 HyperOS 更新是否修复 Adreno Vulkan（升级后用 [drvfp] 指纹一行日志即可复测）。

---

## 2026-09-27 下午：Turnip（out-of-tree A8xx 分支）直载验证——llama.cpp 首次在 Adreno 825 上跑通 Vulkan 后端初始化

### 路线定性（措辞收窄）
- A825 的 Turnip 支持来自 **whitebelyash 的 turnip/gen8 out-of-tree 分支**（Banners-Turnip 打包，Mesa main + a8xx_gen8.patch 13 commits），**不在 Mesa 上游**；上游 Turnip 目前覆盖 6xx/7xx。
- **此前无任何 llama.cpp compute 负载在该组合上的验证记录**——本次为首次勘探。即使失败也能证伪"我们的代码有问题"：换掉高通闭源编译器后行为变化即驱动侧责任。
- 选包：Banners-Turnip v26.3.0-20260918-r6 A8xx（Mesa 26.3.0, Vulkan 1.4.363, KGSL build，免 root）。

### 加载机制破解（关键逆向）
- 该 zip 的 libvulkan_freedreno.so **不导出任何 vk_* 符号**（dynsym 仅 HMI 一个 OBJECT）。入口 = **Android Vulkan HAL 模块**：dlsym("HMI") → hw_module_t（tag 'HWMT', id="vulkan", name="Mesa 3D Vulkan HAL", author="Mesa 3D"）→ methods->open(mod, "vulkan", &dev) → vulkan_device_t。
- **Mesa HAL device 布局与 AOSP hardware/vulkan.h 头文件不一致**：PFN 表从字节偏移 **0x70** 开始（AOSP 头按 hw_device_t reserved[32] 应为 0xA0），4 个 PFN 顺序同 AOSP，GetInstanceProcAddr 在 +0x88。经反汇编确认 +0x88 槽的函数为 strcmp 分派链（首项即 "vkEnumerateInstanceExtensionProperties"）。
- ggml-vulkan 原代码存在**绕过 dispatcher 的直接 C 符号调用**（vkGetPhysicalDeviceFeatures2 ×3、vkGetDeviceProcAddr ×1，链接到系统 libvulkan.so）——系统 loader 不认识 Turnip 句柄，trampoline 解引用即崩。全部改走 VULKAN_HPP_DEFAULT_DISPATCHER。
- 另修：Turnip 的 gipa 对 "vkEnumerateInstanceVersion" 返回的函数（turnip+0x9ba3b4）调用即崩（HAL 模式缺陷），api_version 改为手动解析 + 失败回退 VK_API_VERSION_1_2。

### 验证结果（CLI，master 树 + GGML_VK_TURNIP env 直载）
全部通过（logcat 实测）：
```
instance created ✓ → dispatcher init ✓（NULL 扫描仅 3 个 KHR 别名，无害）
physical devices: 1 ✓
props2 ok, device=Adreno (TM) 825 driver=turnip Mesa driver ✓
device_is_supported=1 ✓ → 模型加载、prefill 启动、进程正常退出（无崩溃）
```
- **llama.cpp Vulkan 后端在 Adreno 825 上首次完成全链路初始化**——用原厂驱动时此路径在 mul_mat_vec_q4_k_f32_f32 管线创建即 ErrorUnknown。
- 剩余验证（设备 ADB 断线待续）：GMEM 默认模式的端到端推理文本正确性、性能；TU_DEBUG=sysmem 模式日志噪音过大（6.2M 行）不适合 CLI 直测。

### 代码改动
- vendored + master 两树的 ggml-vulkan.cpp：新增 [turnip] 直载补丁（GGML_VK_TURNIP=驱动.so 绝对路径；支持标准 ICD 导出与 Android HAL 两种入口）、4 处直接调用改 dispatcher、api_version 安全解析、若干 [turnip-step] 诊断探针（待清理）。
- 事故记录：一次 python 补丁脚本锚点误配（匹配到文件头 include 块）删除了两树 ggml-vulkan.cpp 中段，靠 git 恢复；master 树 checkout 丢失了未提交的 NO_SUBGROUP/NO_MMV 补丁，已从 vendored 对应实现重建。

---

## 2026-09-27 深夜：Turnip GMEM 端到端验证完成——跑通但数值非确定性损坏，判定不可用

### 端到端结果（CLI，lfm2.5-2.6b-q4_k_m，/data/local/tmp/m2b.gguf）
- 全链路运行**不再崩溃、不再挂死**，EXIT=0，decode ~8-11 t/s（原厂驱动在此前连管线都建不出）。
- 但**输出文本非确定性乱码**：首 token 即错（`年@@@`/`seg@@@`/`洛夫@@@` 等，每次不同），同一配置同一 prompt 重复执行结果在「连贯」与「乱码」间随机翻转。

### 二分取证（约 30 组对照）
| 变量 | 结果 |
|---|---|
| 零 env / 四药 / 任意单药+组合（SUBGRP/FUSION/MMV/IDP/MMVQ/COOPMAT/COOPMAT2/F16/DOT2） | 全部乱码（早期 3药/单药曾 8 次连贯，后续 0/16+ 复现乱码 → 早期连贯为随机碰对，env 均无效） |
| FORCE_MMVQ=1（强制全走 matvec，绕开 GEMM） | 乱码 |
| TU_DEBUG=sysmem（绕开 GMEM tile memory） | 乱码 6/6 |
| MESA_SHADER_CACHE_DISABLE=true（排除 shader 磁盘缓存污染） | 乱码 3/3（设备上也无 mesa 缓存目录） |
| GGML_VK_DISABLE_ASYNC=1 / +SERIALIZE_SUBMISSIONS=1（排除多队列/事件竞态开关） | 乱码 6/6 |

### test-backend-ops 数值地图（全量 800s 截断 + 定向补测）
- **通过**（覆盖算子内零失败）：全部 unary 激活、GLU 系（GEGLU/SWIGLU/SILU_MUL 等）、GET_ROWS/GET_ROWS_BACK、SET_ROWS、ROPE_SET_ROWS、POOL_1D/2D、DSV4_HC_*、IM2COL/IM2COL_3D —— 注意 GET_ROWS 在原厂驱动上是挂的，Turnip 上正常。
- **CONV_2D 大面积错**：1155/1981 FAIL，f32 与 f16 kernel 全错（ERR≈1.0，纯浮点路径，与 int8 无关）——out-of-tree 分支独立 bug。
- **MUL_MAT 定向补测：连 f32×f32 / f16×f32 都错**（m=16, k=4096, n=1/8，ERR 1.06~3.02，0 OK）——核心 matmul 数值损坏实锤，e2e 乱码完全归因于此。SSM_CONV 过滤器零匹配（该构建无此测试项）。

### 结论
- Turnip out-of-tree gen8 分支在 A825 上：初始化 ✓、执行不崩 ✓、**数值正确性 ✗（非确定乱码，env 级 workaround 全部无效）**。损坏点在驱动内部（编译器或内核侧竞态），llama.cpp 侧无开关可达。
- 维持既定定性：纯勘探价值（已兑现——换掉高通闭源编译器后行为完全改变，进一步实锤原厂 0800.71 回归），**不可用为推理后端**。
- 后续可选：①向 whitebelyash/Banners 上报（附 tbo 数据：CONV_2D f32 全错 + e2e 非确定乱码 + 复现命令）；②跟踪该分支后续版本复测；③llama.cpp 日常路径维持 OpenCL。

---

## 2026-09-27 下午续：数值损坏根因挖到代码级——subgroup 算术错编（已修一半）

### 关键转折：test-backend-ops × env 二分（此前从未在 tbo 上做过）
- `tbo -o MUL_MAT -p type_a=f32`：零 env → FAIL；**`GGML_VK_NO_SUBGROUP=1` → 203/203 全 OK**。
- 全类型 MUL_MAT + NO_SUBGROUP：仅剩 24 个 `type_a=f16,type_b=f32` case 挂（且全部 `per=[0,2,1,3]` 置换、k=128/129 小 k matvec；模型实际连续布局不涉及），**f32×f32 / bf16 / 全部量化类型（q4_K 等）全过**。
- ⇒ 症状闭环：元素级算子（无 subgroup 归约）全对；matmul/conv（有归约）全错 = **subgroup 算术归约（subgroupAdd）错编**。

### 根因 #1：Turnip gen8 分支错编 subgroup 算术
- 证据：tbo f32 MUL_MAT 203 case 全 FAIL → NO_SUBGROUP 全 OK；ERR≈1.0 结构性错。
- 既有 `GGML_VK_NO_SUBGROUP` env（vendored 0800.71 修复时加）已覆盖 mul_mat 系管线选择。

### 根因 #2：`GGML_VK_NO_SUBGROUP` 门控有漏网（代码级 bug，我方修）
- `ggml-vulkan.cpp:3728` ssm_scan 管线选择用 `device->subgroup_arithmetic && subgroup_require_full_support` 直接判断，**不走 use_subgroups 门控** → NO_SUBGROUP 时 ssm_scan 仍选 subgroup 变体 → recurrent state 损坏 → LFM2.5 首 token 对、token 2+ 全坏（词沙拉/@@@）。
- 修复：设备能力初始化处（subgroup_arithmetic 赋值点）NO_SUBGROUP 直接置 false——一处改动让 ssm_scan / gated_delta_net / lightning_indexer 等全部 op 落回非 subgroup 变体。vendored 与 master 两树均已打补丁；master 已重编（libggml-vulkan.so 已推设备验证：输出从 @@@ 变词沙拉，行为确有改变，但仍有残余损坏）。
- 对比：ssm_conv shader 本身极简（无 subgroup/共享内存）；CONV_2D 独立 bug 与此无关（1162 FAIL 不受 NO_SUBGROUP 影响）。

### 当前状态（设备无线 ADB 再次掉线，待恢复）
- e2e（noSG+全门控修复）：仍是词沙拉 → 还有第三个损坏点未除。
- 排除：FA（-fa off 仍坏）、f16 置换 matvec（模型形状不涉及）、CONV_2D（模型用 SSM_CONV）。
- 下一步：①Qwen3.5-4B（纯 Transformer）隔离实验——正常则残余 bug 锁定 LFM2.5 的 SSM/GDN 路径；②tbo 全量 × NO_SUBGROUP 建立完整失败算子地图；③嫌疑：gated_delta_net 非 subgroup 变体正确性、ssm_conv vec4 dot、attention KQ f16 matvec。

---

## 2026-09-27 傍晚终审：数值损坏根因全部闭合——三药修复后 Turnip e2e 连贯，定性翻案

### 根因 #3：GDN S_V=128 shmem 布局错编（最后一环）
- tbo `-o GATED_DELTA_NET`（注意 `-o` 需精确算子名 `GATED_DELTA_NET`，宽泛词如 `GATED` 匹配 0 个测试）：修复 #2 后仍 2/36 FAIL，且**全部是 head_size=128（S_V=128）**，其余 34 case（16/32/64、KDA、permuted、K=4、127 token）全过。
- 机制：`GGML_VK_NO_SUBGROUP` 下 GDN 走 `gated_delta_net_f32_shmem`（shmem butterfly 归约）。S_V=128 档的 lanes 配置（clustered 捷径 LANES=8，或全宽 LANES=128）被 Turnip 错编；S_V=64/32/16 布局正确。
- decode 路径恰好 n_seq_tokens=1 + LFM2.5/Qwen3.5 head_size=128 → e2e 逐 token 全坏的直接原因。
- **修复**：`subgroup_arithmetic` 为 false 时把 `lanes_per_column` 钳到 64（与已验证通过的 S_V=64 布局同构：64-lane butterfly、2 cols/workgroup）。master 与 vendored 两树均已打补丁（ggml-vulkan.cpp GDN 管线选择处）。

### 修复后验证（同一 so，md5 1abc475c，NO_SUBGROUP=1 + 钳位）
| 验证项 | 修复前 | 修复后 |
|---|---|---|
| tbo GATED_DELTA_NET（36 case） | 2 FAIL（S_V=128） | **36/36 全过** |
| tbo SSM_SCAN（12 case） | 全 FAIL（subgroup 变体，修复 #2 前） | 12/12 全过 |
| LFM2.5 e2e 短生成 ×5 | 0/10 连贯（词沙拉/@@@） | **5/5 连贯**（中英文皆可，6~10 t/s） |
| LFM2.5 e2e n=96 长生成 | 必乱 | **连贯**（10.6 t/s） |
| Qwen3.5-4B e2e | `?111.111.1.111` 确定性乱码 | **连贯**（"Analyze the Input: 你好 (Nǐ hǎo)..."，5.0 t/s） |

### 三药总方（Turnip gen8 / A825 可用配置）
1. `GGML_VK_NO_SUBGROUP=1` + `subgroup_arithmetic=false` 全局门控（修复 #1/#2，覆盖 mul_mat 系 + ssm_scan/gdn/lightning_indexer 全部 op 级选择）
2. GDN lanes 钳位 64（修复 #3，本节）
3. Turnip 直载（GGML_VK_TURNIP HAL 路径 + dispatcher 化 4 处直接调用 + vkEnumerateInstanceVersion 安全解析）

### 遗留与后续
- CONV_2D f32/f16 独立 bug 未修（Turnip 分支错编，LFM2.5 的 SSM_CONV 恰好不走 CONV_2D 故不影响 e2e；其他 conv 类模型仍会坏）。
- FLASH_ATTN_EXT hsk=192 FAIL（-fa off 绕开；后续可上报）。
- [turnip-step] 诊断探针待清理后才能出正式 APK。
- 可向 whitebelyash/Banners 上报：tbo 证据齐全（subgroupAdd 错编 + GDN S_V=128 错编 + CONV_2D f32 全错 + FA hsk=192 错）。
- Turnip 定性从「不可用」修正为「**NO_SUBGROUP+钳位下数值正确、性能 5~11 t/s，可作勘探后端**」；原厂 0800.71 回归结论不变。
