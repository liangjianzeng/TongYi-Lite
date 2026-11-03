# TongYi-Lite Windows 桌面移植实施方案（CPU + GPU + NPU 三后端）

日期：2026-10-30
状态：方案定稿待评审
关联仓：`E:\DTXY\TongYi-Lite`（App）、`E:\DTXY\WangCai`（NPU 后端）

---

## 1. 目标与产物定义

| 项 | 内容 |
|---|---|
| 产物 | `TongYiLite.exe`（Flutter Windows 桌面版），单目录分发（exe + DLL + 模型目录），可选 Inno Setup 安装包 |
| CPU 后端 | ggml-cpu，AVX2/AVX512 自动分发，全模型可用（与 Android CPU 行为一致） |
| GPU 后端 | **Vulkan**（fork 已内置，NVIDIA/AMD/Intel 独显核显通用）；CUDA 列为后续可选 |
| NPU 后端 | **OpenVINO NPU**（WangCai ggml-openvino 后端），Intel Core Ultra AI Boost，仅白名单模型可用 |
| 不变项 | Agent 框架、websearch、会话存储、插件体系、模型管理全部复用；Android 端零回归 |

### 范围外（明确不做）
- Android 端任何行为变更（NPU 是 Windows 专属能力）。
- OpenCL/Adreno 那条线（Mesa 主战场）与 Windows 版无关，互不影响。
- NPU 上的多模态/mmproj、投机解码（MTP/dspark）——NPUW 静态图单序列约束，天然不支持。

---

## 2. 关键调研结论（方案成立的三根柱子）

1. **`gpuBackend` 参数位已存在**：`nativeLoadModel(..., enableGpu, gpuLayers, gpuBackend, ...)`
   （tongyilite_jni.cpp:3235，InferenceEngine.kt:75）。Dart→Kotlin→C++ 全链路已有"后端选择"
   概念，Windows 版只需在枚举里加一个 `npu` 值 + 白名单门控。
2. **TongYi-Lite 的 llama.cpp fork 已接 Vulkan**：`loadVkFlagsConf()`/GGML_VK_* 体系已在
   fork 内（Adreno 特调 flags 是 Android 分支逻辑，`#ifdef __ANDROID__` 隔离后桌面端
   Vulkan 开箱即用，无需 Turnip/NO_SUBGROUP 那些 workaround）。
3. **WangCai 本身就是 llama.cpp 后端**：架构是
   `ggml cgraph → ggml-openvino（op_table 降级）→ OpenVINO NPUW → NPU`，
   以 `0001-ggml-openvino-npu-adaptation.patch` 形式打在 llama.cpp 上，
   MSVC + Ninja 构建配方现成（`tools/configure.ps1` / `build.ps1`），选设备走
   `-dev OPENVINO3` / `GGML_OPENVINO_DEVICE=NPU`。

**结论：CPU / GPU(Vulkan) / NPU(OpenVINO) 三后端可共用同一份 llama.cpp 核心，一次编译出
`tongyilite_core.dll`，按模型目录里的 deviceProfile 路由。不存在"三个引擎拼装"问题。**

### 版本对齐现状（需要在 M0 解决）
- TongYi-Lite fork：基线约 b10176，HEAD `9f6915a`（含自有 probe 提交）。
- WangCai：基线 `abb76ab`（另一条 llama.cpp 线），补丁针对该基线编写。
- 两者不同基 ⇒ ggml-openvino 补丁不能裸 apply，见 §4 决策点。

---

## 3. 总体架构

```
┌────────────────────────── TongYiLite.exe (Flutter Windows) ──────────────────────────┐
│  Dart 层（~95% 直接复用）                                                             │
│  ├─ lib/services/inference_service.dart ──► InferenceBridge 抽象（新增接口）          │
│  │       ├─ WindowsFfiBridge      （dart:ffi + NativePort 流式回调）  ← 新写           │
│  │       └─ AndroidMethodChannel  （现有 MethodChannel 逻辑原样收编）                 │
│  ├─ model_catalog：新增 deviceProfile 字段（cpu / vulkan / npu）                      │
│  └─ 设置页：后端选择器、NPU 缓存目录、NPU 实验性开关                                   │
└──────────────────────────────────────┬───────────────────────────────────────────────┘
                                       │ C ABI（tongyilite_core.h）
┌──────────────────────────────────────▼───────────────────────────────────────────────┐
│  tongyilite_core.dll  ← 新：从 tongyilite_jni.cpp(3886行) 抽出的平台无关核心            │
│  生命周期 / loadModel / completion 流式 / kv 精度 / oom-guard / 统计                    │
│  平台差异点全部 #ifdef：oom-guard 内存查询、日志、路径、conf 文件                        │
└───────┬──────────────────────┬──────────────────────────────┬────────────────────────┘
        │                      │                              │
   ggml-cpu               ggml-vulkan                  ggml-openvino（来自 WangCai）
   （全模型）             （全模型，ngl 分层）          （LFM3 白名单，静态图，NPUW）
                                                        └─ OpenVINO 2026.4.1 runtime DLL
                                                           + Intel NPU 驱动（目标机预装）

Android 端平行保留：tongyilite_jni.cpp 改为"JNI 薄壳 → 调同一份 core 源文件"，
一个核心两个壳，杜绝双平台逻辑分叉。
```

---

## 4. 核心决策点：NPU 后端如何并入（M0 spike 定案）

| | 方案 A：补丁移植到 TongYi fork（共核） | 方案 B：双引擎并行（WangCai 独立 DLL） |
|---|---|---|
| 做法 | 把 0001 补丁 rebase 到 fork 基线（b10176 系），ggml-openvino 与 ggml-vulkan/opencl 共存 | fork 编 `tongyilite_core.dll`（CPU+VK）；WangCai 编 `tongyilite_npu.dll`；core 层做引擎路由 |
| 优点 | 单 DLL、单版本线、长期维护成本最低 | M0 当天即可通；WangCai 基线 abb76ab 不动，零 rebase 风险 |
| 缺点 | rebase 冲突风险（ggml backend registry / CMake 两个基线间有变动），估计 1~3 天排雷 | 两份 llama.cpp 并存，包体 +~30MB，长期双维护 |
| 判据 | `git apply --3way` 冲突 < 30 处且集中，选 A | 冲突深且涉及 backend 注册机制，选 B |

**执行方式：M0 第一天就做 `git apply --3way` 干跑，用数据定 A/B，不空谈。**
（倾向：先 A 后退 B；A 成功则方案 B 的 DLL 仍可作为 WangCai 独立验证工具保留。）

---

## 5. C API 设计草案（`tongyilite_core.h`）

从 JNI 导出面 1:1 映射，去掉全部 JNIEnv 语义，流式回调改为函数指针 + user_data：

```c
// 生命周期
TLC_API bool  tl_init(const char* conf_dir);          // 替代 nativeInit（含 vk/ov flags conf 加载）
TLC_API void  tl_shutdown(void);                       // nativeDestroy

// 回调句柄（token 流 / 装载日志 / 统计）
typedef void (*tl_token_cb)(const char* piece, bool is_thinking, void* ud);
typedef void (*tl_log_cb)(const char* msg, void* ud);  // 替代 loading/spec 回调合流

// 模型加载（对齐 nativeLoadModel 全参数 + 新增 npu 档）
typedef struct {
    const char* model_path;      const char* mmproj_path;
    const char* draft_path;      // NPU 档忽略
    int  n_ctx;    int  n_ubatch;
    int  n_gpu_layers;
    char gpu_backend[16];        // "cpu" | "vulkan" | "opencl"(Android) | "npu"
    int  enable_mtp;             // NPU 档强制 0
    char kv_cache_type[8];       int  flash_attn;   // NPU 档强制 1
    const char* moe_manifest;    int moe_bank;
    long moe_slot_bytes;         long moe_experts_bytes;
    const char* npu_cache_dir;   // NPU 档必填（OpenVINO 编译缓存）
} tl_load_params;
TLC_API bool  tl_load_model(const tl_load_params* p, tl_log_cb log_cb, void* ud);
TLC_API const char* tl_last_loading_message(void);    // nativeGetLastLoadingMessage
TLC_API void  tl_unload_model(void);  TLC_API bool  tl_is_loaded(void);

// 推理
TLC_API bool  tl_completion(const char* prompt_json, tl_token_cb cb, void* ud,
                            char* out_json, size_t out_cap);   // 对齐 nativeCompletion(WithMessages)
TLC_API void  tl_stop(void);  TLC_API void  tl_reset_context(void);
TLC_API void  tl_set_enable_thinking(int);  TLC_API void  tl_set_kv_cache_type(const char*);
TLC_API void  tl_set_flash_attn(int);  TLC_API void  tl_set_oom_guard(int,int,int);

// 信息 / 基准
TLC_API const char* tl_last_stats(void);   TLC_API const char* tl_model_info(void);
TLC_API long tl_model_size_bytes(void);    TLC_API long tl_kv_cache_bytes(void);
TLC_API int  tl_benchmark(double* out, int cap);
```

要点：
- **token 流式**：`tl_token_cb` 在 FFI 壳里转发到 Dart `NativePort`（`NativeCallable.listener`），
  语义对齐现有 Kotlin 回调，Dart 上层 `inference_service.dart` 的事件模型不变。
- **JNI 壳瘦身**：tongyilite_jni.cpp 保留 JNI marshal + logcat/全局引用，实现体全部下沉 core，
  Android 行为零变化（回归靠现有真机晨测）。
- `tl_load_params` 的 `gpu_backend` 直接对接现有 `gpuBackend: String` 链路，
  Dart/Kotlin 不需要改参数结构，只加取值。

---

## 6. 里程碑计划

### M0 — 技术排雷 spike（0.5 周）
| 任务 | 产出 / 验收 |
|---|---|
| `git apply --3way` 干跑 WangCai 补丁到 fork 基线，§4 A/B 定案 | 冲突清单 + 决策记录 |
| `flutter create --platforms=windows .` 脚手架，现有 Dart 代码编译通过（允许临时 stub 原生桥） | `flutter build windows` 出 exe，UI 可进 |
| MSVC + Ninja 三后端合并构建配方（fork 全后端 or fork+WangCai 双 DLL） | build.ps1（复用 WangCai 配方扩展） |
| 目标机 NPU 环境确认：Intel NPU 驱动版本、OpenVINO 2026.4.1 runtime、`hello` 冒烟 | NPU llama-cli 独立跑通（已知可行，复核即可） |

### M1 — 核心抽取 + CPU 端到端（1.5 周）
| 任务 | 产出 / 验收 |
|---|---|
| tongyilite_jni.cpp 平台无关逻辑下沉 `tongyilite_core.{h,cpp}`；Android 壳收编，真机回归 | Android 晨测全绿（740/830 速度无回退） |
| core 编译为 Windows DLL（MSVC，CPU 后端先行）；平台差异点落 `#ifdef`：<br>• oom-guard `/proc/meminfo` → `GlobalMemoryStatusEx`<br>• stderr→logcat → stderr→文件/调试器<br>• 路径 conf 候选表 → exe 目录 + `%APPDATA%`<br>• Turnip//proc/self/maps 段整体 `__ANDROID__` 隔离 | `tl_*` 单元冒烟 exe：加载 Q4 模型→流式生成→stats 正确 |
| Dart `InferenceBridge` 抽象 + `WindowsFfiBridge`（FFI + NativePort 流式）；<br>`inference_service.dart` 改走抽象（Android 路径不变） | Windows exe CPU 档完整对话，流式、stop、reset、thinking 全通 |
| 模型路径约定：`%USERPROFILE%\TongYiLite\models\`（对齐 Android 外置存储习惯） | 模型管理页可直接导入/下载 |

**M1 出口 = 最小可用 CPU 版 exe（对话可用，GPU/NPU 还没有）。**

### M2 — Vulkan GPU 档（0.5~1 周）
| 任务 | 产出 / 验收 |
|---|---|
| Vulkan 后端并进 Windows 构建；`loadVkFlagsConf` 桌面分支（Adreno defaults 全部不启用） | `test-backend-ops` 在目标 GPU 全绿 |
| 设置页后端选择器接 `deviceProfile`；ngl 分层滑杆沿用现有逻辑 | 目标 GPU 上 decode 对比 CPU 提速达标（目标：≥3× CPU 档，具体以基准为准） |
| KV 精度 / flash-attn / MTP 在 Vulkan 档回归 | MTP 投机解码 Windows 档跑通 |

### M3 — NPU 档（1~1.5 周，依赖 M0 定的 A/B）
| 任务 | 产出 / 验收 |
|---|---|
| ggml-openvino 并入（方案 A rebase 完成 / 方案 B 双 DLL 路由） | `-dev OPENVINO3` 等价能力从 core DLL 可达 |
| `deviceProfile: npu` 白名单门控：**仅 LFM3 家族 + Q4_K_M 类量化 + 固定 ctx**；<br>`gpu_backend=npu` 时强制 `flash_attn=1、np=1、单序列、无 draft`（在 core 层硬闸，不靠 UI 自觉） | 非 LFM3 模型选 NPU 被明确拒绝并给出原因（复用 `last_loading_message` 通道） |
| OpenVINO runtime 随包分发 + NPU 驱动检测：驱动缺失/编译失败 → 自动降级 Vulkan 并提示 | 降级路径实测 |
| NPU 编译缓存目录（首次 cold ~36s，之后命中缓存）：装载进度 UI 挂上 `tl_log_cb` 显示编译进度，避免用户以为卡死 | 二次装载 <5s |
| **准确性门控（WangCai 现状 cosine 0.73~0.87 WIP）**：NPU 档默认"实验性"开关关闭；开启后首条回复附带一致性提示 | LFM3-1.7B greedy 输出与 CPU 参考对比留档（bench_ledger 追加） |

### M4 — 平台功能补齐 + 打包分发（1 周）
| 任务 | 产出 / 验收 |
|---|---|
| `sqflite` → `sqflite_common_ffi`（store 层一处切换） | 会话/记忆全量迁移读写正常 |
| PDF 抽取：PdfBox-Android 替换为 Windows 实现（pdfium dll 或先砍到"仅纯文本提示"） | 附件注入 docx/xlsx（archive 纯 Dart）不受影响 |
| ASR：sherpa_onnx 1.13.8 Windows DLL 接入；TTS：edge_tts/audioplayers 天然跨平台 | 按住说话可用（可放 M4 末，允许延后） |
| Dev/Termux、share intent、存储权限等 Android 专属模块条件编译禁用 | 设置页无失效项 |
| 打包：`flutter build windows --release` + DLL 收集脚本（core/ggml/openvino/sherpa）→ zip；Inno Setup 安装包（可选 MSIX） | 干净机器（含/不含 NPU 驱动两台）安装即用 |

---

## 7. Dart 侧改动清单（全量）

| 文件/模块 | 改动 | 量级 |
|---|---|---|
| `lib/services/inference_bridge.dart`（新） | 接口抽象：load/completion/stop/stats/事件流 | 新 ~150 行 |
| `lib/services/inference_bridge_ffi.dart`（新） | Windows FFI 实现（NativePort 流式） | 新 ~300 行 |
| `lib/services/inference_service.dart` | 从直连 MethodChannel 改为按平台取 bridge 实现 | 改 ~80 行 |
| `lib/models/model_catalog.dart` / `model_info.dart` | + `deviceProfile`（cpu/vulkan/npu）、+ npuCacheDir | 改 ~60 行 |
| 设置页 | 后端选择器（三档）、NPU 实验开关 + 缓存目录 | 改 ~120 行 |
| `pubspec.yaml` | +sqflite_common_ffi；Windows 条件依赖核对 | 小 |
| 平台判断收口 | 现有散落的 `Platform.isAndroid` 审一遍（share/termux/权限） | 小 |

**不用改的**：agent 框架、websearch、插件体系、下载管理、会话模型 —— 全平台无关。

---

## 8. NPU 专项约束表（写给实现者，一条都不许破）

| 约束 | 原因 | 实现位置 |
|---|---|---|
| 模型白名单 = LFM3 家族（当前 LFM3-1.7B） | WangCai op_table 目前只降级 LFM3 图结构 | core 加载前置校验 |
| 固定 ctx、静态 shape；改 ctx = 重编译 | NPUW 静态图机制 | ctx 变更时清缓存提示 |
| 单序列 `np=1`、`flash_attn=1` | 静态图 + 已验证配方 | core 硬闸 |
| 无投机解码 / 无 mmproj / 无 batched MoE | NPUW 不支持 | 同上 |
| 首次装载 cold compile ~36s | LEIF 编译 | 进度 UI + 磁盘缓存 |
| 数值精度 WIP（decode cosine 0.73~0.87） | WangCai 已知问题 | 实验性开关 + 提示 |
| 目标机需 Intel NPU 驱动（AI Boost 3720+） | 用户态插件依赖驱动 | 装载前检测降级 |

---

## 9. 测试计划

1. **后端算子级**：`test-backend-ops`（Vulkan 桌面 GPU / CPU），NPU 用 WangCai `tools/` 里的 parity 工具。
2. **引擎级**：LFM3-1.7B + 常用 Q4 模型在 CPU/Vulkan/NPU 三档的 prefill/decode/TTFT 表格进 `bench_ledger.jsonl`（沿用现有台账习惯）。
3. **应用级冒烟清单**：流式对话、stop、多轮、KV 量化切换、MTP(Vulkan 档)、模型下载导入、会话持久化、附件注入。
4. **Android 回归**：每次 core 下沉提交后跑 740/830 晨测（CPU+三件套速度对齐基线，防 core 抽取引入回退）。
5. **分发验证**：无开发环境的干净 Win11 机器 × 2（有/无 NPU）。

---

## 10. 风险清单

| # | 风险 | 概率 | 缓解 |
|---|---|---|---|
| R1 | WangCai 补丁 rebase 到 fork 基线冲突深 | 中 | M0 第一天干跑定 A/B；B 方案兜底当天可通 |
| R2 | NPU 数值漂移（上游 WIP） | 高（已知） | 实验性开关 + 白名单 + 一致性提示；不阻塞 CPU/VK 交付 |
| R3 | FFI 流式回调线程模型出错（丢 token/卡 UI） | 中 | NativeCallable.listener 单独 spike 在 M1 第一周；对齐 Kotlin 回调语义做差分测试 |
| R4 | OpenVINO runtime 体积大、驱动兼容矩阵 | 低中 | 只带 npu plugin 必需 DLL；检测降级 |
| R5 | core 抽取引发 Android 回归 | 中 | 抽取是纯搬移 + `#ifdef`，提交粒度细 + 真机晨测门禁 |
| R6 | sherpa_onnx Windows DLL 版本/许可 | 低 | 1.13.8 官方有 Windows 产物，M4 才接入 |

---

## 11. 总估时

| 里程碑 | 估时 | 累计出口 |
|---|---|---|
| M0 spike | 0.5 周 | 构建配方 + A/B 定案 + exe 壳 |
| M1 核心抽取 + CPU | 1.5 周 | **最小可用 CPU 版 exe** |
| M2 Vulkan | 0.5~1 周 | GPU 档可用 |
| M3 NPU | 1~1.5 周 | 三后端齐（NPU 实验性） |
| M4 补齐 + 打包 | 1 周 | 可分发安装包 |
| **合计** | **4.5~5.5 周**（激进 4 周，含回归缓冲 6 周） | |

关键路径：M1 的 core 下沉（Android 回归是门禁，不能抢进度）。
M3 与 M2 可部分并行（A/B 定案后 M3 的构建/白名单工作可提前启动）。
