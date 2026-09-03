# 端侧 Python 支持方案（python_exec 工具）

> 目标：对齐 DSH 的脚本/编程能力，让智能体在端侧执行 Python 脚本，
> 能力向更强方向延伸（计算、数据处理、文件、网络等），不自我设限。

## 方案选型：Chaquopy（Android 嵌入式 CPython）

- **为什么 Chaquopy**：最成熟的 Android 嵌入式 Python 方案，提供完整 CPython
  运行时 + pip 依赖安装；与现有 NDK(CMake + llama.cpp) 构建共存。
- **版本兼容**：Chaquopy 16/17 支持 Gradle 8.x + AGP 8.x（本项目 Gradle 8.9 / AGP 8.7 ✓）。
- **体积**：CPython 核心 + 标准库约 15~20MB（含 pip 依赖另计）。用户已明确"别管大"，
  体积不设限；与 libggml-vulkan（52MB）同级别，可接受。

## 集成步骤（Phase 1：运行时 + python_exec 工具）

1. **Gradle 配置**
   - `settings.gradle.kts`：pluginManagement repositories 增加
     `maven { url = uri("https://maven.aliyun.com/repository/public") }`（国内镜像已有）；
     根级 plugins 增加 `id("com.chaquo.python") version "16.1.0" apply false`。
   - `app/build.gradle.kts`：plugins 增加 `id("com.chaquo.python")`；
     `android` 块内增加：
     ```kotlin
     // python {
     //     buildPython "python3"   // 主机 Python（Windows 用 py -3 或 conda）
     //     pip { install "requests", "numpy" }  // 按需
     // }
     ```
2. **Python 脚本目录**：`android/app/src/main/python/`（Chaquopy 约定）。
   首期放 `agent_runner.py`：接收脚本文本，执行后返回 stdout/stderr。
3. **原生桥接**（tongyilite_jni.cpp 或新 java 通道）：
   - Flutter `python_exec` 工具 → MethodChannel（`com.dgxspark.tongyilite/python`）
   - Android 侧调用 Chaquopy：`new Python(...)` → `pyRunner.run("agent_runner.py", script)`，
     返回结果文本。
   - 超时保护（15s）与输出截断（4KB）与 shell_exec 一致。
4. **Dart 工具**（`lib/agent/builtin_tools/python_tool.dart`）：
   - `python_exec(script)`：通过 `MethodChannel` 执行；默认注册（能力不设限），
     设置页可关（与 shell_exec 同一"脚本执行"开关组）。
   - 无 Python 运行时（未集成 Chaquopy）时返回明确错误"Python 运行时未集成"，
     不崩溃（优雅降级）。

## 能力边界与安全

- Chaquopy 的 Python 以 **app 权限**运行（与 shell_exec 相同边界）：
  可读写 workspace 沙盒、发网络请求；不可 root/系统级操作。
- 脚本执行由 agent 决策触发（用户授权模式），工具层加超时 + 输出截断 + 体积限制。
- 后续可扩展：`pip` 安装常用库（requests/numpy），脚本能力随库扩展。

## 后续演进

- Phase 2：python_exec 支持传参（文件路径/数据），返回结构化 JSON。
- Phase 3：预装脚本库（如天气/汇率/计算脚本），模型按需选择调用。
- 与 shell_exec 的关系：Python 是"安全沙盒内的高级脚本"，shell 是"命令直通"，
  两者互补；默认都开启，设置页提供独立开关。
