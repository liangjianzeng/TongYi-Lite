# 代码库分析参考（子智能体探索结果）

> 本文档汇总对 TongYi-Lite 代码库的三轮深度探索结论，作为后续开发的参考。
> 覆盖：模型管理/选择逻辑、推理服务分发链路、设置持久化与模型目录结构。

---

## 1. 模型管理 UI 与选择逻辑

### 1.1 设置页 TAB 结构（`lib/screens/settings_screen.dart`）
- 原为 3 个 TAB，`TabController(length: 3)`（L47），TabBar（L85-92）：
  - `模型管理`（L88）→ `_buildModelManagementTab()`（L109）
  - `推理引擎`（L89）→ `_InferenceEngineTab`（L691，独立 ConsumerWidget）
  - `关于`（L90）→ `_buildAboutTab`（L1100）
- 新增「API 接入」后为 4 TAB，插在模型管理与推理引擎之间。

### 1.2 「无法反选默认模型」Bug 根因
- 存在两个独立选择概念：
  - **设为默认加载**（持久化 `defaultModelId`）：UI `_buildDefaultToggle`（L461-499）
  - **当前激活模型**（内存态 `currentModelIdProvider`，chat_provider.dart L30）
- **Bug 根因**（`lib/services/settings_service.dart:72`）：
  `copyWith` 里 `defaultModelId: clearDefaultModel ? null : defaultModelId ?? this.defaultModelId`，
  `?? this` 吞掉 null → 传 null 无法清除。`clearDefaultModel: true` 已定义但从未被调用。
- **修复**（`lib/providers/settings_provider.dart` `setDefaultModel`）：
  `copyWith(defaultModelId: modelId, clearDefaultModel: modelId == null)`。

### 1.3 当前选中模型引用点
- `defaultModelId`：settings_service.dart L36/48；settings_provider L64-68；home_screen L109
- `currentModelIdProvider`：chat_provider L30 定义、L138 读取；home_screen L122；settings_screen L674

### 1.4 可复用组件
- 模型卡片 `_buildModelCard`（L184-322）、状态 chip `_buildStatusChip`（L502-540）、
  内嵌开关 `_buildToggleTitle`（L1069-1094）、分段选择 `SegmentedButton`（L718-752）、
  加载进度对话框 `_ModelLoadProgressDialog`（L1384-1428）。

---

## 2. 推理服务分发链路

### 2.1 完整调用链（纯本地，无 HTTP server）
```
chat_provider.sendMessage
  → inference_service.dart (completionWithMessages)
    → MethodChannel "com.dgxspark.tongyilite/inference" (invokeMethod)
      → MainActivity.kt (setMethodCallHandler)
        → InferenceEngine.kt (nativeCompletionWithMessages)
          → tongyilite_jni.cpp (g_engine.completion)
            → emit_token → on_token → EventChannel "tokens" → Dart 流式
```
- 通道名：Method `com.dgxspark.tongyilite/inference`，Event tokens/loading_logs
- Method 清单：init/loadModel/unloadModel/isLoaded/completion/completionWithMessages/
  stopGeneration/setEnableThinking/resetContext/benchmark/getModelInfo/getMemoryInfo/getInferenceStats

### 2.2 原生无网络能力；HTTP 仅在 Dart 侧（dio 用于下载）
- 原生（C++/Kotlin）纯 llama.cpp 解码，无 socket/curl/okhttp。
- `pubspec.yaml` 依赖 `dio: ^5.7.0`，仅用于模型下载（download_service.dart）。
- 无 openai/http/anthropic 等 LLM provider 依赖。

### 2.3 模型加载传参链
`loadModel(modelId)` → `ModelStorageService.getModelPath` → `_inference.loadModel(path, enableGpu, gpuLayers, gpuBackend, nCtx, enableMtp)`。
C++ 侧：GPU 探测（auto 优先 OpenCL）、n_ubatch GPU=512/CPU=16、MTP 仅当 enable_mtp && n_nextn>0。

### 2.4 返回机制
- 流式：C++ emit_token 分批（8 字节/批）→ EventChannel → Dart `Stream<String>`
- 一次性：`result.success(fullText)` 关闭流
- 停止：回调返回 false；用户停止走 `stopGeneration`

### 2.5 Android 网络权限
- `INTERNET` 权限已有（AndroidManifest.xml L4）。
- 新增 API 接入后补 `android:usesCleartextTraffic="true"` 支持 http:// 明文端点。

---

## 3. 设置持久化与模型目录

### 3.1 配置持久化（`lib/services/settings_service.dart`）
- 基于本地 JSON 文件 `inference_settings.json`（`getApplicationDocumentsDirectory()`），
  非 SharedPreferences / 非 sqflite。
- `InferenceSettings` 字段：enableGpu/gpuLayers/contextSize/enableThinking/gpuBackend/
  mtpEnabledByModel(defaultModelId + API 接入新增 apiModels/activeApiModelId)。
- `_migrateLegacyMtp()`：旧全局 `enableMtp` → 按模型 map（缺字段时默认全关）。

### 3.2 模型信息（`lib/models/model_info.dart`）
- `ModelConfig`：id/name/type/mirrors/sizeBytes/sizeMBDisplay/recommended/minRamMB/sha256Hash/mtp。
- 数据源 `assets/models_catalog.json`，`ModelCatalog.load()` 内存缓存解析。

### 3.3 model_provider 状态机
- `ModelLifecyclePhase`：idle/loading/loaded/unloading/error。
- `loadModel(modelId)`：先卸载旧模型（单模型约束）→ 查路径 → 读 settings → 调原生 → 同步 thinking。

### 3.4 API 接入新增（本次实现）
- 模型：`lib/models/api_model.dart` `ApiModelConfig`（id/name/baseUrl/apiKey/model/temperature/maxTokens）
- 服务：`lib/services/openai_service.dart`（dio 流式 chat/completions + testConnection + stop）
- 路由：`chat_provider.sendMessage`（本地优先；无本地意图 + 激活 API → 直接走 API）
- UI：设置页新增「API 接入」TAB（settings_screen.dart）

---

## 4. 关键教训 / 注意事项
- Flutter 的 Switch/Checkbox 在 uiautomator 里可能不显示为原生类，别只看 class 判断。
- `copyWith` 对可空字段必须用显式清空标记，否则 `?? this` 吞 null。
- dio 流式响应：`Response.data` 是 `ResponseBody`，其 `.stream` 为字节流（无 `responseStream`）。
