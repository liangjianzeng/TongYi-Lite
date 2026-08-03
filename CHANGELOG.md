# 更新日志

所有重要变更将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

---

## [0.1.1] — 2026-08-03

### 新增

- **Vulkan GPU 加速**（端侧 LLM 上 GPU）：arm64-v8a 启用 ggml-vulkan 后端
  - `CMakeLists.txt` 在 `ANDROID_ABI == arm64-v8a` 时强制 `GGML_VULKAN=ON`，构建主机用
    LunarG Vulkan SDK（glslc + SPIRV-Headers + `<vulkan/vulkan.hpp>`）预编译着色器
  - 新增 `host-toolchain-mingw.cmake`：在 Windows 构建主机用 MinGW-w64 (GCC) 编译
    `vulkan-shaders-gen` 主机工具（完全静态链接，零 DLL 依赖）
  - `tongyilite_jni.cpp` 新增 `detect_gpu_layers()`：**运行时**探测 ggml 后端注册表，
    发现 GPU 设备才启用卸载，否则回落 `0`（纯 CPU），同一 APK 可在无 Vulkan 驱动的设备上安全运行
  - **推理引擎设置 UI**：设置页「推理引擎」标签页新增「启用 GPU 加速」开关（默认开启）
    与「GPU 层数」滑块（默认 20）。关闭开关即纯 CPU 推理；开启时把用户设定的层数传给原生层
    （`enableGpu` / `gpuLayers` 经 MethodChannel → Kotlin → JNI 透传），实现运行时可控的 GPU offload
  - 依赖链 `libggml.so → libggml-vulkan.so → libvulkan.so`（系统运行时提供）
  - CPU 优化（KleidiAI + SME2）作为 Vulkan 不可用时的备选方案
- **模型下载系统**：完整的模型选择、下载和缓存管理
  - 多镜像源优先（hf-mirror → ModelScope → HuggingFace），HTTP Range 断点续传
  - Riverpod 状态管理 + UI 实时进度，SHA256 完整性校验，磁盘空间检测
- **设置页 UI**：模型管理界面（卡片展示、下载进度、状态芯片、存储信息）
- **对话持久化**：SQLite (sqflite) 存储对话和消息历史

### 修复

- **Android 构建环境**：Gradle plugin 通过 `includeBuild` 复合构建解析，阿里云 Maven 镜像解决 dl.google.com 超时
- **NDK + CMake**：安装 NDK r27.0.12077973 + CMake 3.31.6，修正 CMakeLists.txt 路径（5 级 `../`）与 Vulkan 编译依赖（SPIRV-Headers / Vulkan include / NDK Vulkan 桩库按 minSdk API 级别）
- **C++ JNI bridge**：适配 llama.cpp b1017+ 新 API（`llama_model*` → `llama_vocab*`、`llama_init_from_model`、`llama_token_eos(vocab)` 等），手动实现 temperature + top-p 采样
- **Dart 编译错误**：修复 `ConsumerStateNotifier`、`const DateTime(0)`、`as int? == 1` 运算符优先级、重复 `ModelConfig` 类冲突等约 50 个错误
- **Android 资源缺失**：创建 ic_launcher mipmap + Theme.TongYiLite style + colors.xml
- **Kotlin import**：修复 MainActivity.kt / InferenceService.kt 缺少 Intent/Context import

### 修复（运行时稳定性 · 重大）

- **推理正确性**：彻底修复大模型"答非所问 / 乱码 / 一直转圈"
  - 每次生成前 `llama_memory_clear` 清空 KV cache，避免多轮后上下文污染导致 padding token（151935）无限循环
  - 修复 `parseMessagesJson` 悬垂指针（`llama_chat_message` 只存 `const char*`，改用 `deque<string>` 持有字符串）
  - 修复 `llama_batch.n_tokens` 漏设（首 token 后 decode 失败）与 `llama_get_logits_ith` 越界（SIGABRT）
  - 修复 Qwen3 思考模式空思考块注入 off-by-one（`"assistant\n"` 长度 10 误写 11），并新增「思考模式」开关（默认关=直接作答）
  - 修复 top-p nucleus 采样退化成贪心（cumsum 早停）
- **GPU 加速默认关闭**：ggml-vulkan 在小米 onyx（Adreno 825）上卸载层数后第 2 个 token 起数值崩坏（已知 GPU 后端数值 bug），故「启用 GPU 加速」默认改为关闭，回退稳定纯 CPU 推理；开关变更需重新加载模型生效
- **CPU 推理提速**：采样改用 `partial_sort` top-K(K=128) + top-K softmax（替代全词表 sort），显式设置线程数 `min(硬件并发, 8)`

---

## [0.1.0] — 2025-07-29

### 新增

- **端侧 LLM 推理引擎**：基于 llama.cpp b1017+，支持 KleidiAI + SME2 优化
- **Flutter 前端**：Material3 设计，聊天界面、设置页面、模型管理
- **Plugin 插件架构**：支持视觉/语音/文本/文件任务的热插拔 Plugin 系统
- **荒野求生游戏化任务**：远程指令推送 + Plugin 离线执行 + 结果回传
- **架构设计文档 v2**：完整的系统架构与技术选型说明
- **编译与调试指南**：BUILD_AND_DEBUG_GUIDE.md

### 技术栈

- Flutter 3.x + Riverpod 状态管理
- Android NDK r29 + CMake 3.31
- JNI 直调通信（无 HTTP Server）
- Qwen3-1.7B-Instruct Q4_K_M 默认模型

### 文档

- 架构设计 v2
- Plugin 架构设计
- 实施方案
- 移动端 LLM 基准报告 v2
- 编译与调试指南
