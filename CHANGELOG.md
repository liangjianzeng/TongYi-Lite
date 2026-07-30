# 更新日志

所有重要变更将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

---

## [Unreleased]

### 新增

- **模型下载系统**：完整的模型选择、下载和缓存管理功能
  - 多镜像源优先（hf-mirror → ModelScope → HuggingFace）
  - HTTP Range 断点续传，支持网络中断恢复
  - Riverpod 状态管理 + UI 实时进度展示
  - SHA256 文件完整性校验
  - 磁盘空间检测和存储信息展示
- **Vulkan GPU 加速**：启用 ggml-vulkan 后端，Android 设备 Vulkan 1.2+ 自动启用 GPU 推理
  - `CMakeLists.txt` 添加 `GGML_VULKAN=ON`，arm64-v8a 自动开启
  - `tongyilite_jni.cpp` 将 `n_gpu_layers` 从 0 改为 -1（全部层卸载到 GPU）
  - CPU 优化（KleidiAI + SME2）作为 Vulkan 不可用时的备选方案

---

## [Unreleased]

### 修复

- **Android 构建环境**：Gradle plugin 通过 `includeBuild` 复合构建解析，添加阿里云 Maven 镜像解决 dl.google.com 超时
- **NDK + CMake**：安装 NDK r27.0.12077973 + CMake 3.31.6，修正 CMakeLists.txt 路径（5级 `../`）和 Vulkan 编译依赖
- **C++ JNI bridge**：适配 llama.cpp b1017+ 新版 API（`llama_model*` → `llama_vocab*`、`llama_init_from_model`、`llama_token_eos(vocab)` 等），手动实现 temperature + top-p 采样替代不存在的 `llama_sampler_init_simple`
- **Dart 编译错误**：修复 `ConsumerStateNotifier`（不存在）、`const DateTime(0)`（非法）、`as int? == 1`（运算符优先级）、重复 `ModelConfig` 类冲突等 ~50 个编译错误
- **Android 资源缺失**：创建 ic_launcher mipmap + Theme.TongYiLite style + colors.xml
- **Kotlin import**：修复 MainActivity.kt / InferenceService.kt 缺少 Intent/Context import

### 新增

- **设置页 UI**：完整的模型管理界面（卡片式展示、下载进度条、状态芯片、存储信息）
- **模型下载系统**：Dio + HTTP Range 断点续传 + hf-mirror → ModelScope → HuggingFace 镜像自动回退链
- **对话持久化**：SQLite (sqflite) 存储对话和消息历史

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
