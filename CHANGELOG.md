# 更新日志

所有重要变更将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

---

## [Unreleased] — 2026-09-01

### 修复（代码质量评估 P0 隐患加固）

- **消息 role 反序列化崩溃**：`MessageRole.values...first` 三处直接抛 `StateError`——历史脏数据
  或将来新增 role（如 system）会让整个会话列表/消息读取崩溃。新增 `messageRoleFromName()`
  安全解析（未知 role 回落 user），`ChatMessage.fromMap` 与 SQLite 行映射统一替换。
- **语音消息 audioPath 持久化**：模型字段存在但 messages 表无该列，语音消息重进会话后
  「语音」标记全部丢失。数据库 **v2→v3** 迁移补列（`ALTER TABLE messages ADD COLUMN audioPath`），
  `saveMessage` 写入、行映射读取；顺带把 getMessages/getAllMessages 两份重复行映射收敛为
  `_mapMessageRow`。
- **原生消息 JSON 解析器重写**：`parseMessagesJson` 原用 `find('}')` 截取对象——内容含
  `{`/`}`（贴代码/JSON）被截成空内容、`\n`/`\"` 不解码（多行提问以字面量 `\n` 喂给模型）、
  结尾转义反斜杠的内容丢失。重写为结构化解析 + 完整 JSON 字符串解码（`\uXXXX` 含代理对
  → UTF-8）；宿主机编译 + 11 个行为用例全过（覆盖三个旧失效场景）。
- **设置写入原子化**：`SettingsService.save` / `ModelDisplayNameService.save` 改为
  先写 `.tmp` 再 rename——崩溃/断电不再留半截 JSON 导致用户配置静默回默认。
- **假数据 stub 移除**：`getAvailableSpace`（恒 64GB）、`hasEnoughMemory`（恒 true）、
  `checkAllModels`（假 5120MB 空闲）均无消费者，删除；「清空日志」按钮空实现改为真实清空
  （`ModelManagerNotifier.clearLogs()`）。
- **日志页「刷新」按钮移除**：原实现 `ref.invalidate(modelManagerProvider)` 会重建 notifier
  并把状态复位为 idle，让已加载的模型在 UI 上显示「未加载」。
- **死代码/过期注释清理**：`g_callback_obj`（从未赋值 + 两处无效 DeleteGlobalRef）、
  `reportLoadingLog` 重复前置声明、`ModelStateExtension`（调用即抛 UnimplementedError）、
  `_migrateLegacyMtp` 同分支冗余、model_provider 过期 vision 注释。

## [0.1.6] — 2026-08-19

### 引擎升级

- **llama.cpp 升级到上游 master**：vendored 从 `f5b9bd3`（b10173，2026-07-29）升级到
  `fe8156f`（2026-08-19，含 333 个上游 commit）。API 适配：`llama_sampler_init_penalties`
  新签名（增加 `n_vocab` 参数，JNI 两处调用点已同步）；`LLAMA_INSTALL_VERSION` →
  `LLAMA_VERSION_BASE`（上游 CMake 变量改名，项目 CMake mtmd 段已适配）。

### 天玑 / Mali Vulkan 崩溃根治（真机验证）

**症状**：天玑（MediaTek Mali-G68）上选 Vulkan 后端，加载模型或首次推理即 SIGSEGV
（`vulkan::api::QueueSubmit+0`，fault addr 0x0）。Adreno 正常。

**排查过程（逐项排除）**：验证层（APK 内 13MB `libVkLayer_khronos_validation.so`，
Flutter debug 打包带入，已从打包排除）→ `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT/F16/ASYNC`
→ `internallySynchronizedQueues` 特性 → 均非根因。

**最终根因**：Mali 驱动的 `vkGetDeviceQueue2`（Vulkan 1.2）返回 dispatch 表为 NULL 的坏
queue → 首次 `vkQueueSubmit` 崩在 loader trampoline。**改用 Vulkan 1.0 的 `vkGetDeviceQueue`
修复**（Impeller 同款路径）。

**最终 patch（3 处，仅 ARM vendor 0x13B5 生效，ggml-vulkan.cpp）**：
1. `ggml_vk_create_queue`：Mali 用 `device.getQueue(family, index)` 替代 `getQueue2`；
2. `has_internally_synchronized_queues` 在 Mali 强制 false；
3. `buffer_device_address` 在 Mali 强制 false（驱动上报 true 但 `getBufferAddress` 崩）。

> 注意：**不要**调用 `VULKAN_HPP_DEFAULT_DISPATCHER.init(device)`——Mali 上会把
> `vkQueueSubmit` 等 loader trampoline 覆盖为 NULL，引入新崩溃（已验证）。

### 其他修复与优化

- **mmproj 视觉编码后端跟随主后端**：原来写死 `MTMD_BACKEND_DEVICE=OpenCL`（Adreno 时代
  遗留），选 Vulkan 时显示矛盾、天玑上 OpenCL 不可用。现按 `enable_gpu` + `backend` 选择
  CPU/OpenCL/Vulkan，天玑上正确显示「图像理解 (Vulkan GPU 编码)」。
- **天玑 OpenCL 设置置灰**：检测到 MediaTek SoC 时，GPU 后端 OpenCL 选项禁用并提示
  「天玑芯片不支持 OpenCL，优先 Vulkan」（真机实证：天玑 `libOpenCL.so` 仅为 72KB
  Khronos ICD 加载器空壳，`/vendor/etc/OpenCL/vendors/` 无驱动注册 → 枚举 0 平台）。
- **标题栏字体调小**：`TongYi-Lite` 标题从默认 AppBar 大字号改为标准大小。
- **Gradle 16 核并行构建**：`-Xmx8g` + `workers.max=16` + `parallel=true`，NDK 全量重编
  从 20+ 分钟降到 ~2 分钟。
- **设备信息通道**：新增 `getDeviceInfo` MethodChannel（暴露 SoC 硬件信息），供设置页
  按芯片判断 OpenCL 可用性。

### 性能说明（天玑）

- 天玑 900（Mali-G68）Vulkan 解码实测 ~5.7 tok/s（0.8B），约为 CPU 的 1/3——这是
  **Mali-G68 无矩阵加速单元的硬件天花板**（社区 PR #18493/#27163 佐证，均未合入主线），
  非软件 bug。大模型（4B+）上 GPU 卸载仍可省内存。
- 恢复 `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT` 等临时排查开关（非崩溃根因，纯性能杀手）；
  保留 Mali 实测较稳的路径（BDA / internal-sync 禁用由 vendor 判断自动生效）。

## [0.1.3] — 2026-08-04

### 体验优化

- **助手消息复制**：气泡右下角新增小号复制图标，点击即复制全文并提示「已复制回复内容」。
- **性能指标标签精简**：消息底部统计由「首Token / 总耗时」改为紧凑的「首Tok / 耗时」
  （如 `首Tok 1.2s · 耗时 5.3s · 14.5 tok/s`）。
- **Bonsai27B 等大模型下载断点续传修复**：旧逻辑每次失败都删除 `.tmp` 残留、且探测用
  `GET` 把整个多 GB 文件拉进内存，大文件网络抖动即反复失败/断开。改为最多 8 次自动重试
  + 失败保留 `.tmp` + 按 HTTP `Range` 断点续传（`hf-mirror`/`huggingface` 均支持 206），
  探测改为 `Range: bytes=0-0` 仅取 1 字节；错误文案不再误导「CDN 不支持续传」。
- **自定义模型名称**：设置页每个模型卡片底部新增可编辑名称框（持久化到
  `model_display_names.json`）；聊天页右上角加载后优先显示自定义名，未设置则回落「模型就绪」。
- **切换模型不再红屏（友好提示 + 安全切换）**：推理中点击切换模型先弹友好确认框
  （橙色信息图标「已有模型正在运行」），确认后先 `stopGeneration()` 停止生成，再卸载旧模型、
  加载新模型，避免卸载正在推理的模型导致原生引擎崩溃红屏。
- **大模型加载实时进度弹窗**：点击「加载到内存」后弹出不可取消的「正在加载模型…」对话框，
  实时展示原生层最新加载日志；加载完成走原成功/失败提示路径。

### 修复（2026-08-04 晚 · 真机验证）

- **tok/s 口径对齐真实值**：聊天气泡的 tok/s 此前数的是「字符数」且分母含 prefill，与 logcat
  对不上。现由 JNI 回传真实 `n_gen`（decode token 数）与 `t_gen_ms`（纯生成耗时），UI 与
  logcat 完全一致（实测 10.2 / 8.7 / 8.5 tok/s 三档全对齐）。
- **n_ubatch 按后端动态分设**：GPU 路径 `n_ubatch=512`（prefill 走 GPU kernel，规避 CPU 量化
  GEMM bug 并显著提速 prefill，实测 4B 多轮 prefill 1.4s）；CPU 路径保留 `16` 保正确。
- **聊天顺序改为标准「上旧下新」**：去掉 `ListView reverse`（此前导致最旧的显示在底部、最新的
  在顶部），最新消息固定在下；流式输出期间自动滚到底部保持可见，用户上滑读历史后暂停跟随。

## [0.1.2] — 2026-08-03

### 补充修复（2026-08-04 · 真机验证）

- **量化 GEMM 路径计算出错（根因 5）**：`n_ubatch=512` 时，prompt ≥32 tokens 的 prefill
  进入 ggml-cpu 量化 GEMM 路径产生垃圾 logits（第一轮 15 tokens 走 vec_dot 正常，第二轮
  37+ tokens 乱码 `oother民nedbish枉叶`）。`n_ubatch` 调回 `16` 强制走正确的 vec_dot 路径
  （首 token 延迟略增，GEMM bug 待 ggml-cpu 侧修复后恢复）。
- **重复惩罚失效（根因 6）**：采样循环缺 `llama_sampler_accept()`，penalties 的 token
  历史永不更新 → repeat penalty 永不生效 → 退化循环（9841/57699 反复、无 EOS）。采样后
  补 `llama_sampler_accept(smpl_chain, new_token)`。
- **flash attention CPU 陷阱**：`LLAMA_FLASH_ATTN_TYPE_AUTO` 在 CPU 后端会实际启用
  （ggml-cpu 实现了 FLASH_ATTN_EXT op），seq_rm 清空 KV 后第二轮 prefill 乱码。当前
  `DISABLED`，待状态重置验证后恢复。
- **流式输出块化**：`on_token` 回调批处理从 64 字节（≈21 个 CJK 字符）改为 8 字节
  （≈2 字），恢复逐字流式观感。

### 修复（多轮对话正确性 · 重大）

彻底修复「第一轮正常、第二轮起输出乱码 / 死循环（"魔魔魔…"）/ 空回复 / 只出两个字」的问题。
真机（Xiaomi onyx，Qwen3-0.6B Q4_K_M）连续三轮对话已验证正常。

- **KV 缓存跨轮残留（根因 1）**：`llama_memory_clear()` 在本版 llama.cpp 上对
  hybrid/unified 后端是**空操作**，不重置每序列长度计数器；从位置 0 重新解码只是
  「叠加」在上一轮的陈旧 KV 之上，注意力被污染 → 从第二轮起坍缩为退化循环。
  改用 `llama_memory_seq_rm(mem, 0, 0, n_ctx)` 真正清空序列 0。
- **`kv_unified = true` 强制走 hybrid memory（根因 2）**：该路径的 `seq_rm` 只要
  recurrent 部分不支持就整体返回 `false`，注意力 KV 长度计数清不掉。Qwen3 是纯
  Transformer，无需 unified，改回 `kv_unified = false`（llama.cpp 官方默认值），
  经典 KV 的 `seq_rm` 可靠生效。
- **`decode_pos` off-by-one（根因 3）**：`n_gen++` 原本在计算 `decode_pos` 之前执行，
  导致每轮生成位置跳格、KV 出现空洞，表现为"每轮只出两个字"。`n_gen++` 挪到
  `llama_decode()` 之后，保证 `decode_pos = kv_position + n_gen` 连续。
- **prompt 多 token 批量解码写坏 KV（根因 4）**：13 token 的短 prompt 侥幸正常、
  33 token 的第二轮 prompt 解码后 logits 被压平（top5 全部落在 12.0~12.6 一条直线，
  对比正常轮的 42.18 / 38.60 / 35.47）。改为**逐 token 解码 prompt**，与已验证可用的
  生成循环走同一条单 token 路径。
- **`llama_batch_get_one()` 返回 pos=nullptr 导致 SIGSEGV**：本版该函数只借用 token
  指针，`pos / n_seq_id / seq_id / logits` 全为 `nullptr`，手动填充即崩溃。改用
  `llama_batch_init(n, 0, 1)` 分配真实批次并自行填写各字段。
- **`llama_get_logits_ith()` 下标越界导致 SIGABRT**：该下标是**相对最近一次 decode 的
  batch**，不是全局 token 位置。改为逐 token 解码后最后一批只有 1 行，旧代码仍用
  `n_prompt-1` 取值 → `ggml_abort` 整个进程挂掉（debug 构建下 `GGML_ABORT` 而非
  `return nullptr`，兜底判断永不生效）。统一改用 `-1`（源码明确支持负下标 =
  最后一个输出行），与 batch 大小解耦。
- **消息重复注入**：Dart 侧已把当前消息一并存入历史再整体下发，JNI 侧又 append 了一次
  → 移除 JNI 的重复拼接。

### 新增

- **`resetContext()` 全链路**：Dart `InferenceService.resetContext()` → MethodChannel →
  Kotlin `InferenceEngine.nativeResetContext()` → JNI `g_engine.resetContext()`。
  `ChatNotifier` 记录 `_currentKvConvId`，检测到切换会话时主动清空 KV，避免跨会话污染。

### 变更

- 设置页「GPU 层数」滑块在 GPU 开启时置灰不可调，并说明：本设备（Adreno 825）**部分卸载
  会输出崩坏**，故 GPU 模式固定为全量卸载。

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
