# TongYi-Lite 项目指令 / 记忆

## 智能体模式总开关 + 「同时最多一个 spinner」不变量（2026-09-28）

> 用户要求：智能体模式**必须可关闭**（本地小模型扛不住大 prefill），关闭后 = 简单聊天；
> 且修复"发一条消息两处转圈思考"的蠢 UI。

**总开关**（设置 → 智能体 Tab 首排）：
- `agentEnabled` 路由本就存在（`chat_provider.sendMessage` 按 `_ref.read(settingsProvider).agentEnabled`
  分流），**缺的只是 UI**；现 `settings_screen._AgentTab` 首排加 `_buildToggleTitle` 绑
  `notifier.setAgentEnabled`，关闭时 `Opacity(0.45)+IgnorePointer` 置灰全部子设置卡。
- 关闭路径 = 纯历史消息直连模型（无系统提示词/工具定义/AGENTS.md/Skills），
  🔧 工具活动消息两路都已排除，历史互不污染。
- **模式切换必须 resetContext**：KV 缓存按会话复用（`_currentKvConvId`），
  同会话中途开/关智能体若不重置，普通聊天会续跑在被大提示词污染的 KV 上。
  已加 `_currentKvWasAgentMode` 标记，两路径在"同会话但模式变了"时强制 reset。

**双转圈根因**：智能体回合空答案占位气泡（ChatBubble 自带"思考中…"）+
`AgentTurnBlock.ThinkingIndicator` 同时渲染 = 两个转圈。修复（`agent_workflow.dart`）：
- `_answerPending`（live+running+答案空）时**不渲染空答案气泡**，只留思考行；
- 工具有 executing 步骤 → 思考行隐藏（工具卡自带"执行中…"状态）；
- `retryAttempt>0` → 思考行隐藏（已有 RetryIndicator）；重试/压缩横幅加 `ui.running` 门槛防串台。
- `home_screen`：`isLiveTurn` 改为 `(uiState.running || isGenerating) && 末组`，
  普通聊天生成中才有唯一"思考中…"占位与流式光标；
  `_stepsFor` 只在 `ui.running`（真智能体回合）取事件流，
  **普通聊天绝不借上一智能体回合残留的 ui.tools 工具卡**。
- 不变量：**界面上同时最多一个 spinner**。动这块先跑 `flutter test test/agent`
  （本次全绿 212 项 + 2 skip）。

**环境坑（本次抓到）**：沙箱受限模式下 `flutter.bat`/`flutter analyze`/`dart analyze`/`flutter test`
会**无声挂死**（fork analysis_server/编译测试子进程被拒：`CreateFile failed 5`），
不是编译慢。`flutter --version` 90s 不出结果即可确诊；解法=放开沙箱（full-access）后一切正常。

## 真机打包安装（重要规则，务必遵守）

> **更新安装真机时，绝不要"先卸载再装"**（`adb uninstall` + `adb install`）。
> 卸载会清掉应用数据，包括已下载的端侧模型缓存（例如 qwen3.5-4b，重新下载很费劲）。

**正确做法**：始终走**覆盖更新**，保留模型缓存：

```bash
adb install -r app-debug.apk    # -r = replace/update，不清数据
```

- 只在需要彻底清数据（换模型/出问题时）才考虑卸载，且要先告知用户模型会被清除。
- 安装被 `INSTALL_FAILED_USER_RESTRICTED` 拒绝时，加 `-t` 并请用户在设备上点允许：`adb install -r -t app-debug.apk`。

## 构建环境备忘

- **默认打包策略（2026-08-08 起）**：每次构建默认 **debug + release 一起打**，
  除非用户只点名一个。debug 用于真机安装调试，release 用于生产分发。
  两者共用 `CN=TongYiLite` 签名。
- 本项目是 Flutter + NDK(CMake + llama.cpp)。
- `flutter build apk --debug` 在本机 gradle 启动 `flutter.bat` 会静默失败（Windows/gradle 批处理问题）。
  **workaround**：先 `flutter assemble ... debug_android_application` 生成 kernel/assets，
  再用 `./gradlew.bat assembleDebug -x compileFlutterBuildDebug` 打包（NDK 全量编译 + 链接）。
- NDK 构建目录 `.cxx` 若被残留进程（`glslc.exe`/`vulkan-shaders-gen.exe`）锁定会报
  "Device or resource busy" / access-denied，需先终止对应进程再删 `.cxx`。
- gradle 守护进程可能持有 `.cxx` 锁导致 `buildCMakeDebug` 偶发失败：`./gradlew.bat --stop` 后重试。
- 构建/安装前先 `adb devices` 确认设备在线；设备可能因 USB 断开而消失，需等待或重连。

## APK 构建产物地址（打包必记）

> **每次构建后，把 APK 输出目录地址写进这条备忘**，方便用户直接找包。

- **APK 输出目录**：`build\app\outputs\flutter-apk\`（Windows 绝对路径
  `E:\Work\DgxSpark\TongYi-Lite\build\app\outputs\flutter-apk\`）。
- debug 包：`app-debug.apk`（真机调试，`adb install -r` 覆盖安装）。
- release 包：`app-release.apk`（生产分发）。
- **2026-09-29 15:12 最新构建（23049c5）**：app-debug.apk 100701814 B、
  app-release.apk 53408334 B，均在上述目录；字符串级验收过（debug kernel_blob
  UTF-8 / release libapp.so UTF-16LE 均命中新 UI 串）。
- **2026-09-30 10:16 最新构建（工作区未提交，v0.2.8+16 智能体多人格）**：
  本机目录 `E:\DTXY\TongYi-Lite\build\app\outputs\flutter-apk\` —
  app-debug.apk 103890496 B、app-release.apk 53755911 B；字符串级验收过
  （debug kernel UTF-8 `人格设定`/`_showPersonaDialog` 命中；release libapp.so
  UTF-16LE `人格设定`/`新增人格` 命中）。flutter SDK 本机在 `C:\src\flutter`；
  PATH 无 python，用 `$LOCALAPPDATA/Programs/Python/Python310/python.exe`。
- wt/ 工作区构建产物在 `wt\<name>\build\app\outputs\flutter-apk\`，不在主仓 build/
  （2026-09-28 v0.2.6 实测，另一台开发机用 wt 工作区，别看错目录）。
- 构建后**必须**列出该目录的 APK 名/大小/时间，并把目录地址发给用户。

## APK 签名（重要记忆）

> **正确签名是 `CN=TongYiLite`（O=DGXSpark），不是临时生成的 dev keystore。**

- **签名证书**：`CN=TongYiLite, OU=Dev, O=DGXSpark, L=Wuhan, ST=Hubei, C=CN`
  SHA-256 指纹：`FB:BE:1B:6C:F8:79:AB:94:1A:65:CD:D7:A7:A8:DD:6F:5A:6B:B6:40:41:2D:E3:8C:43:CB:89:4F:08:88:69:92`
- **签名文件**：`android/key.jks` + `android/key.properties`（均被 `.gitignore` 排除，不提交远程）。
  `key.properties`：`storePassword=android` / `keyAlias=androiddebugkey` / `storeFile=../key.jks`
- **铁律**：覆盖更新安装必须保持同一签名（否则 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。构建时若发现 APK 签名不是 `CN=TongYiLite`（比如变成了临时生成的 `CN=TongYi-Lite Dev`），说明签名文件不对，需核对 `key.jks`。
- 新环境 clone 后若签名文件缺失：从源工作区拷贝，或用 `keytool -genkey -dname "CN=TongYiLite, OU=Dev, O=DGXSpark, L=Wuhan, ST=Hubei, C=CN"` 重新生成并写 `key.properties`。

## 关键教训：wttr.in 只认 `/城市` 路径形态，`/?q=城市` 返回 HTTP 500（2026-09-29 真机定案）

> get_weather 工具"基本全失败"根因：`https://wttr.in/?q=武汉&format=...` 的查询参数
> 形态 **返回 500**（curl/Dio 一致，与 format 串、中文无关——连 `%c` 都挂）；改
> `https://wttr.in/<url-encoded-city>?format=...&m=&lang=zh` 路径形态即 200。
> 排查时手机 shell curl 测通不代表 app 能通——**必须用 app 的精确请求形态复现**。
> 修复已落 weather_tool.dart（`Uri.encodeComponent(city)` 进路径）。web_search
> 侧同日复核：DGX SearXNG 实例/设备配置/请求形态（含 language=zh-CN）全链路
> 200，无 app 侧 bug；`category=news` 与 general 结果相同是实例引擎配置问题
> （keep_only 下 bing news 未真正区分），非 app 代码问题。

## 关键教训：CMAKE_C_FLAGS_DEBUG 会被 NDK 工具链静默顶掉（CPU 内核失去 -O3 → 全模型变慢）

> **血泪教训（2026-08-07 真机定位）**：`set(CMAKE_C_FLAGS_DEBUG "-O3 -DNDEBUG")` 看似正确，但
> **Android NDK 工具链会在 Debug 配置重新套上自己的 `-g`，静默覆盖该变量**，导致 `-O3 -DNDEBUG` 根本没生效。
> 表现：**所有模型同等降速**（0.8B 1.2 tok/s、2.7B ~1.2），效果像"最早没做 KleidiAI"——因为量化 matmul
> 内核以默认 `-O0` 编译。此时 KleidiAI 内核虽编进去了（`-march` 有），但没优化级别等于没加速。

**验证铁证**：看 `.cxx/.../compile_commands.json`，若 ggml-cpu/kleidiai 源文件只有 `-march` 而**无 `-O3`、无 `-DNDEBUG`**，即中招。

**正确做法**：改用 NDK 覆盖不了的目录级选项（会传给 llama/ggml-cpu/kleidiai/mtmd 所有子目录目标）：
```cmake
add_compile_options(-O3)
add_compile_definitions(NDEBUG)
```
改 CMake 后必须**清 `.cxx` 全量重建**，并核对 compile_commands 同时含 `-O3 -DNDEBUG -march` 才算生效。

## 关键教训：Cortex-A78 不支持 i8mm → SIGILL 撞 crashes all backends

> **根因（2026-08-08 真机定位）**：`GGML_CPU_ARM_ARCH` 设为 `armv8.4-a+dotprod+i8mm`，
> 但天玑 8200 / 天玑 920 的 CPU 大核是 Cortex-A78（ARMv8.2-A），只支持 dotprod，
> **不支持 i8mm**（需 ARMv8.6-A/ARMv9）。ggml-cpu 的 i8mm kernel 在这些核心上执行
> `i8mm` 指令 → **SIGILL**，崩溃发生在共享的 CPU 加载/repack 路径，与推理后端无关，
> 因此"三个后端全崩"。

- **型号确认**：天玑 8200 = 1×A78@3.1GHz + 3×A78 + 4×A55；天玑 920 = 2×A78 + 6×A55。
  均为 ARMv8.2-A，`+dotprod`，无 `i8mm`。
- **修复**：`android/app/src/main/cpp/CMakeLists.txt` 中
  `set(GGML_CPU_ARM_ARCH armv8.4-a+dotprod+i8mm ...)` → `armv8.2-a+dotprod`。
  KleidiAI 的 dotprod 内核仍可用，i8mm 量化内核不可用（性能影响可接受）。
- **验证动作**：清 `.cxx` 全量重编 + 两台天玑三后端（CPU / OpenCL / Vulkan）各跑一遍
  加载+推理 + 高通 8s Gen 4 回归。
- **后续观察**：GPU 后端（Mali）的 ADRENA_KERNELS 问题与此修复无关，是独立线路。
  `n_ubatch=16` 限制在 dotprod 下可试探提回 512，但先验证不崩。

## 关键教训：flutter assemble 输出路径 ≠ gradle 读取路径（Dart 改动"装不进"APK）

> **血泪教训**：改了 Dart 代码后，光 `flutter assemble` + `gradlew assembleDebug -x compileFlutterBuildDebug`，
> 装出来的 APK **可能仍是旧代码**——因为两个工具读写的 kernel 路径不一致：
>
> - `flutter assemble -o build/flutter-assemble ...` 把最新 kernel 写到
>   `build/flutter-assemble/flutter_assets/kernel_blob.bin`；
> - 但 gradle 打包时用的是 **`build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin`**（旧拷贝），
>   `-x compileFlutterBuildDebug` 跳过了 flutter 编译，**不会自动刷新这个路径**。
>
> 结果：UI 改了半天，装上去界面毫无变化，还以为代码没写对——实际是打包了旧 Dart。
>
> **正确做法（每次 Dart 改动后必须做）**：
> ```bash
> flutter assemble -o build/flutter-assemble --define=BuildMode=debug --define=TargetPlatform=android-arm64 debug_android_application
> cp -r build/flutter-assemble/flutter_assets/* build/app/intermediates/flutter/debug/flutter_assets/
> cd android && gradlew.bat assembleDebug -x compileFlutterBuildDebug
> ```
> 即：**先把最新 flutter_assets 同步覆盖到 gradle 的 intermediates/flutter/debug，再打包**。
> 可用 `ls -la build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin` 确认大小/时间已更新。

## 关键教训：MTP 是全局开关会"点一个全开全关"

> MTP 开关最初做成全局一个 `bool enableMtp`，用户点某个模型开关，**所有模型一起变**。
> 应改成**按模型 id 的 `Map<String, bool>`**（`mtpEnabledByModel`），每个模型独立持久化，
> 加载时用 `gpu.mtpEnabled(modelId)` 取当前模型自己的开关。迁移旧配置时全局 bool 不迁移为开（保持默认关）。

## 关键教训：release 包 AOT 暂存必须用 app.so 原名，且必须字符串级验收（2026-09-18 踩坑）

> `-x compileFlutterBuildRelease` 跳过后，libapp.so 的唯一来源是 gradle `packJniLibs*` 任务，
> 它从 **`build/app/intermediates/flutter/release/arm64-v8a/app.so`（原名 app.so！）** 取文件，
> 打包时才改名成 `lib/arm64-v8a/libapp.so`。放成 `libapp.so` 会打成 `liblibapp.so`（Flutter 起不来）；
> 删掉 merged_native_libs 再指望它重新生成是错觉——flutter 任务被 `-x` 跳过，没人喂产物。

**release 打包正确流程**：`flutter assemble release_android_application` → 把输出的
**`app.so` 原名**拷到 `intermediates/flutter/release/arm64-v8a/`，flutter_assets 拷到同级 `flutter_assets/` → gradlew。

**打包后必做字符串级验收（本次连错两次才抓到的原因：只看时间戳/大小）**：
```bash
python -c "import zipfile; d=zipfile.ZipFile(apk).read('lib/arm64-v8a/libapp.so'); print(d.count('新代码字样'.encode('utf-16-le')), d.count('旧字样'.encode('utf-16-le')))"
```
AOT 串在 libapp.so 里是 **UTF-16LE**，debug kernel_blob 是 UTF-8；确认 NEW>0 且 OLD=0。
- **0.2.6 验收补充**：纯 ASCII 字面量（如版本号 `0.2.6`）在 libapp.so AOT 里按**单字节 ASCII**
存储——用 `d.count(b'0.2.6')` 查；UTF-16LE 只命中非 ASCII（中文）字面量，版本号按 UTF-16LE
查恒 0（2026-09-28 实测），勿误判成打包了旧 Dart。
`app-debug.apk`/`app-release.apk` 里"旧 Dart 幽灵"就用这招当场验尸。

## 真机调试注意

- 屏幕休眠（`mWakefulness=Dozing`）时 `uiautomator dump` 返回**空节点**，易误判"UI 没渲染"。
  先 `input keyevent KEYCODE_WAKEUP` + `KEYCODE_MENU` 唤醒，再 dump 验证界面。
- Flutter 的 `Switch` 在 uiautomator 里可能不显示为 `android.widget.Switch` 类（可能显示为带
  `checked` 属性的普通 View），别只看 class 名判断开关是否存在。

## 重要：当前模型不支持视觉理解（调试禁用"看图片/截图"）

> **用户不主动喂图；当前驱动模型不支持视觉，无法真正"看"图片/截图。**
> 一旦任务流程里出现"查看截图/图片"这类依赖视觉的步骤，模型会拿不到任何图像内容，
> 任务会**彻底僵死**（卡在等图、误判界面等死循环）。

**铁律**：
- 调试/验证一律走**文本通道**：`uiautomator dump` 的 XML 文本、`adb logcat`、`dumpsys`、
  文件内容（`cat`/`Read`）等——**绝不依赖截图判读**。
- 不主动生成、不主动查看 `screen.png` 之类的截图产物；即便存在也不把图像内容当真。
- 判断 UI 状态只看文本节点/属性（`text`、`content-desc`、`checked`、`bounds`），
  不要写"打开截图确认一下"这种步骤。

## 重要：通过 DSH Phone 把 APK 下发到手机的触发机制（2026-09-05 实测可行）

> **背景**：用户在手机上用 `E:\DTXY\DSH-Phone` 这个 App 通过 SSH 隧道连回本机，
> 想在手机上直接下载刚打包的 APK。DSH Phone 的"资源下载"能力链路：
>
> - 手机 webview 注入 `artifactBridgeJs`，监听 DSH Web UI 里**成果（artifact）点击**；
> - 只有当 Web UI 里出现**产物按钮（file-mention chip，`title` 存远端路径、
>   带 `.apk` 后缀 → 归类为 resource 走下载）**时，手机才会触发 SFTP 隧道下载；
> - 该产物按钮由 **`write` 工具调用（带 `file_path`）** 触发，**不是** gradle 编译产物。

**为什么之前触发不了**：APK 是 `gradle` 编译出来的，不是通过 `write` 工具调用产生的，
所以 Web UI 里**没有它的产物按钮** → 手机点不到、下不了。
**只有 `write` 工具产出的文件，才会被 Web UI 渲染成可点击的产物/资源按钮。**

**正确做法（让手机能下载）：**
1. 先确认手机 SSH 连的是哪台主机（`E:\DTXY\DSH-Phone\lib\tunnel_service.dart` 里配的 host）；
2. 用 **`write` 工具调用**把 APK 写到**手机所连主机上的某个路径**（不是直接给路径）；
3. 这样 Web UI 会把它渲染成产物按钮，手机一点就走 SFTP 隧道下载（`download_manager.dart`）。

**让输出更高概率触发下载的优化建议（针对 DSH Phone）：**
- 凡是可能下发的二进制（apk/zip/图片等），**一律走 `write` 工具写到一个明确路径**，
  不要只给路径文本或 `file://` 链接——只有 `write` 才会被识别为产物。
- `write` 的 `file_path` 用**带后缀的完整路径**（`.apk` 等），确保命中
  `artifact_recognizer.dart` 的 `resourceSuffixes`（`.apk/.zip/.png/.pdf` 等）。
- 若担心路径被 chips 隐藏，`write` 后在回复里**显式写出该完整路径**，
  配合 `webview_bridges.dart` 的 `findMentionPath` / `collectProducedDirs` 兜底解析。
- 大文件注意 `maxDownloadBytes = 256MB`、`maxRemoteReadBytes = 8MB` 上限，
  APK 一般没问题；超上限需换用 `download_manager` 的断点续传流程。
- 手机侧需开启"资源下载"开关（`config.dart` 的 `resourceDownloadEnabled`，默认开），
  且 SSH 隧道已连上对应主机。

## llama.cpp 升级门槛（四道门，缺一不算升级完成）（2026-09-18 实测立规）

> **背景**：另一台开发机升级到 b11028 后 CPU/GPU 全后端慢一倍——升级类回归几乎都是**静默的**
> （不崩、不报错、功能全对，就是慢），防不住它的人只能事后考古。所有检查必须**机检化**，
> 验收基准是 `docs/backend_benchmark_2026-08-04.md`（8 Elite 实测：Vulkan 8.60 / OpenCL 8.77 / CPU 4.33 tok/s）。

**升级流程（本机 b10173→b11028 走通的打法）：**
1. **先算 fork 增量再动手**：`git log --oneline -- third_party/llama.cpp` 找上游同步点（本仓库基线 = 上游 `fe8156f`），
   `git diff --no-index <上游base> third_party/llama.cpp` 得真实补丁面。**别把本地补丁当祖传**——
   本次发现 XHToken/Spark2.5 已合入上游 b11028（`spark2-5.cpp` 与 fork 版仅 1 行差异、模板改名 `Spark2.5.jinja`），
   fork 里多余的 `XHToken-Spark-X2.5-1.7B.jinja` 直接删。
2. 替换树：`robocopy <新树> third_party/llama.cpp /MIR`（`Remove-Item` 删 .cxx/大目录会慢到超时）。

**四道验收门（全过才算完）：**
1. **编译门**：`gradlew --stop` + 清 `.cxx` 全量重编后，扫 `.cxx/Debug/*/arm64-v8a/compile_commands.json`：
   ggml-cpu / kleidiai / mtmd / llama core / JNI 的命令行**必须同时含 `-O3 -DNDEBUG`**，
   ggml-cpu 主源码必须 `-march=armv8.2-a+dotprod`（NDK 顶掉 -O3 的老坑就是这么抓的）。
   ⚠️ 写检查脚本注意 PowerShell `-match` **大小写不敏感**、compile_commands 路径是**反斜杠**——本次差点误报 292 条不合格。
2. **内核门**：configure 摘要 KleidiAI 必须 ON，且对象文件来自 `third_party/kleidiai`（vendored），**不是网络拉取**。
   ⚠️ **FetchContent 项目名会变**：`KleidiAI_Download`(fe8156f) → `kleidiai`(b11028)，
   覆盖变量是 `FETCHCONTENT_SOURCE_DIR_<名字大写>`，名字错=静默失去 vendored 目录；
   app CMakeLists 已同时设新旧两个变量兜底。KleidiAI pin 版本（v1.24.0）要与 ggml-cpu/CMakeLists.txt 里 `KLEIDIAI_COMMIT_TAG` 对得上。
3. **参数门**：logcat 抓 `[handleLoadModel]`，与升级前逐项 diff：`n_gpu_layers=100` /
   `n_ubatch`（CPU=16、GPU=512）/ `flash_attn=DISABLED` / sampler 链。移植 JNI 时不许顺手改默认值。
4. **基准门**：基线设备（Xiaomi 25053RT47C / 8 Elite）同 prompt 各后端 3 轮，tok/s 对 8-04 基线，
   **偏差 >±10% 不许收工**，按 编译门→内核门→上游回归 顺序排查。

**b11028 实际踩到的 API 漂移（下次升级先查同类）：**
- `mtmd_helper_bitmap_init_from_file()` 加了第 4 参 `mtmd_helper_init_opt`，图片路径传 `mtmd_helper_init_opt_default()`（JNI 已修）。
- **`MTMD_BACKEND_DEVICE` 环境变量在 b11028 被删**（fe8156f `clip.cpp:189` 的 `getenv` 没了）→ 视觉编码后端必须改设
  `mtmd_context_params.device`（`ggml_backend_reg_by_name("vulkan"/"opencl")` + `ggml_backend_reg_dev_get(reg,0)`）。
  **静默失效不报错**，视觉塔从此不跟主后端——JNI 已修（保留 setenv 兼容旧库）。
- ⚠️ UI 报错文案会指错方向：model_provider 旧逻辑只要 `loadModel` 返回 false 且模型类型是 vision 就显示
  "mmproj 投影器加载出错"——上下文 OOM/主模型失败全被甩锅 mmproj（已改为只认真实日志）。
  **教训：真凶看引擎日志最后一步，别信红条标题。** 本机 b11028 宿主复现（mingw `llama-mtmd-cli` + 同款 4B/mmproj）
  加载推理全过，上游 mtmd 对 unsloth Qwen3.5 mmproj 无罪。
- ggml-opencl 直接用 CL2.1 核心入口 `clGetKernelSubGroupInfo` → `third_party/opencl-stub/opencl_stub.c` 已加转发
  （升级后链接报 `undefined symbol: cl*` 就照现有 CL_FORWARD 模式补）。
- Vulkan 后端 24k 行大重写（拆分出 buffers/types/push-constants 等新文件），
  **Mali 崩溃缓解需在 b11028 上重验**（旧"删 copy_transpose_02.comp"式改动未回带，若 Mali 再崩从这里查）。
- `llama-ext.h` 的 `llama_set_embeddings_nextn`（MTP/dspark staging API）仍在，MTP 代码未动。

**隔离口诀**：先在本机重编**旧版**——旧版也慢=环境问题（NDK 版本/构建类型/设备不同），旧版快=新树问题。
慢一倍这种问题，有这四道门就活不过当天。

## 智能体"迭代一两下就停 / 没正确结果"根因与修复（2026-09-27 v0.2.4-agent-stall-fix）

> 用户反馈：智能体模式跑一两轮就执行不下去、输出没完成任务。定位到**三条静默卡死路径**，
> 共同特征是**不崩不报错、任务半途而废当成功**——和升级回归一样阴险，验收靠"看有没有红字"永远抓不到。

**根因 1：工具调用块被 token 预算截断 → 静默降级成普通回答（主因）**
- 现象：模型输出 `{"name":"file_write","arguments":{"content":"……`（写到一半被 `maxTokensPerRound=512` 拦断），
  `prompt_json_protocol` 括号不平衡 → **整段当普通文本返回** → 主循环判定"无工具调用 → 本轮完成"，
  任务没做还显示得像成功。**这是"迭代一两下就停、没结果"的头号元凶。**
- 修复（`lib/agent/protocol/prompt_json_protocol.dart` `_parseText` 第 0 步三分类）：
  先 `_truncatedToolCall` 判定——① 断在字符串/参数内容内部 → 抛 `LlmFailureCode.toolCallTruncated`（不可伪造执行）；
  ② 仅缺收尾括号且能补全 → 自动补括号照常执行（参数无损）；③ 补完仍非法 = 模型自身语法错误 → 优雅降级为文本，
  **不误报截断**误导用户去调设置。`failure.dart` 的 `LlmRetry` 把 toolCallTruncated 纳入有限重试预算。
- **排障铁律**：智能体"没结果"先翻推理日志看是不是截断，别先怀疑模型笨。可调「智能体每轮生成 token」。

**根因 2：失败轮回溯历史旧答案冒充本轮回复（"重复问候 bug"）**
- 现象：第二轮起 turn 内失败 → UI 又显示第一轮的问候，像"模型只会这一句"。
- 修复：`ReactLoopAgent._turnAnswer` **只取本轮 append 的 assistant**，失败置空串绝不穿透历史；
  失败原因走 `_turnError` → chat_provider 明确报 `⚠️ 本轮执行失败：…`，不再拿旧回复顶包。

**根因 3：每轮重建 log 时 system 落在消息中段 → OpenAI 兼容服务端 400 拒收**
- 现象：新引擎每轮 importFromMessages 先导入历史，构造 agent 时才 append system →
  system 不在队首 → API 路线 400、本地 chatml 被中段 system 污染 → 表现为"执行不下去"。
- 修复：`SessionLog.deriveModelMessages` **system 恒置队首**（纯投影重排，不破坏事件序不变量）。

**回归防线（test/agent/ 全绿 241 项，含本次新增）**：截断三分类、toolCallTruncated 有界重试后终态 error、
lastTurnAnswer 不回溯、system 晚 append 仍恒队首。**下次动智能体循环/协议先跑 `flutter test test/agent`。**

## 智能体"新引擎唯一 + 对话内嵌工作流"（2026-09-27）

> 用户要求：智能体模式应**只有新引擎**（ReactLoopAgent），不要"关闭回退旧模式"的开关；
> 且状态提示要像主流智能体，在**对话内一步步向下**输出（[思考中…]→[🔧 工具卡]→[答案]），
> 而不是分散的 AppBar 徽章/输入区面板。

**已删除（彻底）**：旧 `runAgent` 循环（`lib/agent/agent_loop.dart`）及其测试
（`test/agent/agent_loop_test.dart`）、`useNewAgentMode` 回退开关
（settings_service/provider/screen）、`AgentStatusBadge`、`AgentActivityPanel`。
新引擎严格子集覆盖旧引擎（同路由/注册表/协议/工具/执行器/沙箱），删除安全。
共享展示类型（`ToolActivity` + `AgentToolActivityCallback`）迁到
`lib/agent/tool_activity.dart`，`lib/agent/agent.dart` 聚合导出随之指向它。

**内嵌工作流 UI**（`lib/widgets/agent_workflow.dart`，取代 agent_activity_panel）：
- `groupMessages` 把原始消息流重排为 `[UserUnit | TurnUnit]`：user 是分界，
  其后非 🔧 assistant = 回答，🔧 前缀 assistant = 工具步骤；**无论存储顺序
  （新 [user, ans, t1..tk] / 旧 [user, t1..tk, ans]）都重排成 [工具… → 答案]**。
- `parseToolActivity` 把存储 🔧 消息解析回卡片（历史回合回看），
  兼容新格式 `🔧 正在调用 X…` 与旧格式 `🔧 正在调用：A、B…`。
- `AgentTurnBlock` 内嵌块：[重试/压缩横幅（仅 live）]→[🔧 卡 ×N]→[思考中…（live 且无答案）]→
  [答案 ChatBubble（showAvatar:false，保留统计/复制）]。
- **live 回合**步骤取 `agentUiStateProvider` 事件流实时数据；**历史回合**
  解析自存储 🔧 消息（`parsedToolActivities`；解析为空但活动未结束
  [500ms 轮询间隙] 时短暂 fallback 事件流）。

**工具活动逐工具独立落库**（`chat_provider._AgentActivitySession` 重写）：
executing = `🔧 正在调用 X…`、done/failed = `🔧 X ✓/⚠️summary`（`isStreaming` 恒 false，
实时"执行中"由事件流驱动，存储只负责可回看步骤）；对位更新靠"最早执行中"匹配。
`stopGeneration`：智能体回合走 `_currentAgent.cancel()`（adapter.cancel 中止 native/API），
普通聊天仍直接 stop。

**坑**：`TurnUnit.tools` 曾拿 `pendingTools` 列表引用、`flush` 后 `clear()` 清空它 →
tools 全空；已改 `[...pendingTools]` 拷贝。`🔧` 后有空格 → `parseToolActivity`
须在 `substring` 后 `.trim()` 再判断/索引。

**回归（test/agent 全绿 211 项 + 2 skip）**：新增 groupMessages 重排、
parseToolActivity 解析、AgentTurnBlock 渲染 三组。下次动智能体循环/协议/活动 UI
先跑 `flutter test test/agent`。**

## 关键教训：大模型 GPU 加载 OOM 会打死整机 system_server（2026-09-27 Bonsai-2 死机案）

> **现象**：Bonsai-2 27B (PTQ1_0, 5.95GB) + OpenCL 在小米 25053RT47C 上"一推理就死机"，
> 连死三回：手机整机卡死 → Android Watchdog 重启。不是内核 panic、不是 OpenCL 内核 bug、
> 不是 App 崩溃——**logcat 里永远看不到凶手**（system_server 死时日志随缓冲一起断）。

**铁证**（dropbox `system_server_pre_watchdog`，dumpsys dropbox 可跨重启读）：
- `/proc/pressure/memory` some avg60=19.3 / full=12.3（严重内存停滞）；kswapd0 5.5% CPU；
- system_server **11897 次 major faults**；主线程/Binder/display/AM/Power 全部 blocked 30s；
- Subject: `Blocked in monitor Watchdog$BinderThreadMonitor … for 30s` → 看门狗 reboot。

**根因算账**：该机 **MemTotal 仅 11.0GB**（不是 12！），日常 MemAvailable ≈ 3.5-5GB。
Adreno UMA：OpenCL/Vulkan 的权重和 KV 都是系统 RAM。bonsai2 需求 =
权重 5.95GB(GPU) + KV @n_ctx4096 数 GB + mmap 文件工作集 ≈ 8-11GB → 超物理内存一倍 →
回收风暴饿死 system_server。**一代 Bonsai 27B（3.8GB）恰好压线能活，bonsai2 超线即死**。
CPU 后端能活的原因：权重是 mmap 文件页（可回收），而 GPU 后端是必 resident 的拷贝。

**修复（已实施）**：
- `tongyilite_jni.cpp` 加 **OOM 守卫**：建 ctx 前读 `/proc/meminfo` MemAvailable，
  估算 GPU 权重（按 GPU 层数折算 + dspark 草稿）+ KV（n_layer×kv_dim×f16）+ 1.5GB 头量，
  不够 → **自动下调 n_ctx**；连 n_ctx=512 都放不下 → **拒绝加载**并在应用内推理日志报
  "已拒绝加载以防整机死机"（宁拒绝不死机）。日志 tag `[oom-guard]`。
- `mul_mv_ptq1_0_f32.cl`：尾行**读**指针 clamp 到 `ne01-1`（写本来有 guard、读没有，
  尾行越界读最后一个 cl_mem 之外的页可触发 GPU SMMU 故障，属顺手堵雷，不影响数值）。
- catalog bonsai2：`minRamMB` 8192→16384 + 加"需≥16GB内存"标签（注意 minRamMB 仅元数据，
  Dart 端**从未强制执行**，真正的闸是 JNI 守卫）。

**排查方法论（下次整机死机照抄）**：
1. `dumpsys dropbox | grep -iE 'PRE_WATCHDOG|PANIC|SYSTEM_BOOT'`——pre_watchdog=系统卡死被狗咬，
   无 PANIC=内核没死；重启后依然可查（dropbox 落盘）。
2. 转储里看 `/proc/pressure/*` + major faults + `Subject:` 三件套定"饿死还是崩死"。
3. `getprop sys.boot.reason`、`/proc/meminfo` MemTotal 先算账再谈优化——**11GB 机器跑
   ≥6GB 权重的 GPU 全载方案是物理不可能的，不是 bug**。
4. 别再拿 llama-cli 往 /data/local/tmp 推了反复死机——**死机时现场日志只在 logcat 实时抓取
   + dropbox 里有**，事后 `logcat -d` 拿到的只有新 boot。

## 关键教训：Adreno OpenCL 编译器把 `half` 当类型关键字 + OpenCL 加载守卫开关（2026-09-28 GEMM 移植案）

> **现象**：带新 GEMM 内核的 APK 用 OpenCL 加载 bonsai2 到一半直接崩（不是死机，是进程 abort）。

**根因**：新内核里 `const int half = kt & 1;`——Adreno CL 编译器把 `half` 保留为类型说明符，
当变量名用则 **clBuildProgram 失败（err=-11: cannot combine with previous 'int' declaration
specifier）**，ggml-opencl init abort。NDK 交叉编译能过、桌面 NEO 能编，**都不代表 Adreno 能编**。
错误只在真机 logcat tag `llama` 里（主 buffer 滚得快：`logcat -c` 后实时抓文件复现；
二次 SIGABRT "pthread_mutex_lock on destroyed mutex" 是烟幕弹，真凶是首条 compile error）。
修复 = 改名 `blk_half`；验收 = APK 内 `libggml-opencl.so` 字符串级：`blk_half`>0 且旧代码=0。
现 `mul_mm_ptq1_0_f32_l4_lm.cl` 未用 `half` 变量名，安全。

**验证铁律**：`.cl` 改动必须过 Adreno 编译门——内核在 ggml-opencl init 时无条件编译，
**用任意安全小模型（qwen3.5-4b）开 OpenCL 加载一次即全量编译**，logcat 无
`kernel compile error` 才算过；不许拿 bonsai2 当编译测试（先过守卫/OOM 关）。

**OOM 加载守卫开关（设置 → 推理引擎）**：`oomGuardEnabled` 默认开；关 = 旁路预检+夹逼强行加载，
日志每次打 `guard=OFF(risk: hard reboot)`——**11.5GB 机型上旁路 bonsai2 必死机，不要建议用户关**。
链路：model_provider→`setOomGuard`→Kotlin MethodChannel→JNI `nativeSetOomGuardParams`
（setenv `TONGYILITE_NO_OOM_GUARD` + 预/后余量 MB）；`[oom-guard]` 日志带"旁路=开/关"。

## 约定：parseAndReturn 双参语义（main 原生工具调用 x 思考块清洗 合并版）

`base_engine_adapter.parseAndReturn(StringBuffer rawBuffer, AgentStreamProcessor processor)`：
优先解析 `processor.cleanText`（去  think/response 思考块、保留工具调用），cleanText 为空
（测试桩/调用方自持缓冲）回退 rawBuffer；空响应 fail-loud 抛 `emptyResponse`。
**两条调用线（local/openai adapter）都必须传 `(rawBuffer, processor)` 双参**；
改成单参会挂 main 线的 `native_tools_test`（它靠双参桩测空响应回退），动前先跑
`flutter test test/agent`。

## 2026-09-29 v0.2.7：分支停维护，主干统一 + API 视觉/思考流/工具卡三修复

> **分支停维护（用户指令）**：spike/opencl-bonsai2-ptq1-gemm 已快进合并进 main
> （739170c，含 v0.2.6 + PTQ1_0 GEMM + FWHT hadamard + Turnip 驱动 + agent 内嵌
> 工作流重构），此后所有开发只在 main 做。主仓 third_party/llama.cpp 树 = spike
> 完整树（fe8156f 基线）；此前「b11028 半升级 + PTQ graft」方向**废弃**，别再按
> 那条线排查编译错误。
>
> **v0.2.7+14 三修复**（版本三处同步：pubspec / build.gradle.kts / settings_screen
> _appVersion；必须高于已装机版本，否则 VERSION_DOWNGRADE 拒装）：
> 1. **API 视觉**：kick 把 imagePath 写进 user/message 事件，deriveModelMessages
>    投影，OpenAiAdapter attachWireImages 转 image_url part（visionCapable 门控，
>    每 step 重发；OpenAiService.encodeImageFile 带 8 张 FIFO 缓存）。
> 2. **思考流单独展示**：adapter.generate 新增 onThinking 通道（全量快照推送）；
>    API 原生路线解析 delta.reasoning_content/reasoning + content 内嵌 <think>
>    剥离（OpenAiNativeStreamAssembler 字符状态机，跨分片安全）；本地/文本协议
>    路线走 AgentStreamProcessor.thinking。chat_provider 节流 120ms 落
>    agentUiStateProvider.thinking；UI = agent_workflow.dart ThinkingStreamCard
>    （live 回合内嵌，自动展开跟随滚动，点按头可手动收起）。
> 3. **工具卡压缩**：ToolActivityCard 从 ExpansionTile 卡改为单行紧凑行
>    （~22px：图标+名+参数摘要+执行中），点按行内展开参数/结果。
>
> 回归：test/agent 全绿（phase6_test 点按目标 ExpansionTile→ToolActivityCard
> 同步更新）；新增 test/agent/vision_thinking_test.dart。

> **版本号策略（用户指令 2026-09-29）**：不要频繁升级版本号。同内容重打包
> （改 Dart/修 bug 未发版）**复用同一 versionName**，只保证 versionCode 不低于
> 任何已装机版本（install -r 同 code 可覆盖）。当前 = **0.2.8**（code 16）。
> 另注意：另一台开发机可能并行出包抬版本（曾装过 0.2.8+15），装机报
> VERSION_DOWNGRADE 时先 dumpsys 查设备 versionCode 再对齐。

> **2026-09-29 补充**：镜像已从 2026.7.19（8/20 构建）升级到 **2026.9.25**
> （searxng/searxng:latest，docker rm -f 后按原参数重建：named volume /etc/searxng +
> settings.yml ro bind + /data volume）。keep_only + cn.bing.com 覆写在新版下原样
> 生效，实测 10 条结果 0 unresponsive。用户的直觉部分正确：引擎解析器上游每周
> 多更，旧镜像确实会积累过期性不通；但本例主因仍是无代理（国外引擎）与 302
> 壳（bing），版本只是加重因素。升级后引擎仍以 keep_only 名单为准。

## 2026-10-01 DGX SearXNG 实例定位（dgxspark 主机）

> **SearXNG 实例所在主机**：`dgxspark` / `Dgx` = **100.81.83.59**（Tailscale 内网地址，
> 非公网）。这是 TongYi-Lite 智能体联网搜索（`web_search`）背后自建 SearXNG 的宿主机。
> 手机在设置「API 接入 → 联网搜索」里填的 baseURL 即指向该主机（如
> `http://100.81.83.59:8080`，需带 `/search` 或 app 自动补）。
> - 排查 web_search「不行」时，**先确认手机能否访问 100.81.83.59:8080**（Tailscale 是否
>   在线、端口是否开放），再谈引擎/配置问题。
> - 实例侧 settings.yml：`keep_only` 白名单 + `cn.bing.com` 覆写（bing 走 302 壳绕国内
>   访问）；引擎解析器每周更新，旧镜像会积累过期性不通，主因仍是无代理 + 302 壳。
> - 引擎白名单（`webSearchSearXngEngines`）是设置项：实例上不可达引擎各自等超时，
>   实测默认全引擎 21s、只指定可达引擎 2.5s → 白名单决定延迟。

## 2026-09-29 v0.2.8：执行顺序渲染 + 思考流式自动展开 + 空响应重试 + 思考泄漏修复

> 用户反馈：① 工具调用和思考的位置经常不按执行顺序呈现；② 思考流式输出应自动展开、流式滚动可见、完成才闭合；③ web_search 还是不行。commit `bce9b83`（已推送 main）。

**① 执行顺序渲染（timeline markers）**：`AgentUiState` 新增 `timeline: List<UiTimelineMarker>`，
归约器在**事件到达时**追加标记（思考落档 → `UiTimelineThinking(i)`；工具卡加入 → `UiTimelineTool(i)`），
`AgentTurnBlock._timelineWidgets()` 依序交错渲染——不再"思考一律在前、工具一律在后"。
⚠️ **坑**：`switch` 语句不能放进 `children: [...]` 列表字面量（collection-if/for 可以，switch 不行）——
必须抽成返回 `List<Widget>` 的辅助方法。历史回合 timeline 恒空，仍走存储 🔧 消息顺序。

**② 思考流式自动展开**：`ThinkingStreamCard` 展开条件从 `_override ?? false` 改为
`_override ?? (running && !answerVisible)`——流式中自动展开跟随滚动（home_screen 每次重建
`_followStream` 即 animateTo 底部），答案开始/回合结束自动闭合。

**③ web_search"不行"的两条静默路径 + 修复**：
- **思考截断空响应（主因）**：4B 模型常在思考中途直接 EOS（思考块未闭合被丢弃 → 空响应），
  本地路线 `emptyResponse` 原本**不可重试** → 瀑布直接 giveUp → 回合"本轮执行失败"，
  用户看到的就是"web_search 不行"（实际搜索已成功）。修复：loop 里 `retryEmptyResponse: true`
  （两条路线都计入可重试档，maxRetries 有界）。
- **实例瞬态故障**：DGX SearXNG 偶发 0 结果带 `unresponsive_engines` 诊断 → 工具返回
  "搜索服务异常"（内容带时间标签，logcat 里 contentLen≈378 与错误路径吻合）。主机复测实例
  已恢复（10 条结果 0 unresponsive）；此类属实例侧，app 代码无需改。
- **真机复现铁律**：logcat 单行截断 ~1024B、AGDBG print 截断 300 字符 → 工具结果看不全时
  直接读 `contentLen` + 从手机 shell `curl` 同请求复现，别只盯 logcat。

**④ 思考泄漏修复**：`AgentStreamProcessor` 新增"孤立闭合记号"处理——模型偶发在回答中途
再输出 ` response`（无前置 think，一段被提前闭合的思考续写），当作**隐式 opener** 重新
进入思考态、续写一并丢弃（否则闭合记号+后续内容直接渗进可见回答）。带保护：` response`
紧跟英文/数字（如 "API response"）不吞，避免误伤英文词。

**⑤ 顺手清理**：`loop/agent.dart` 残留的 `[AGDBG/STEPS]/[AGDBG/REQ]/[AGDBG/MSG]` 诊断 print
全删（此前只删了 adapter 层，loop 层漏了）。

**验收**：test/agent + test/providers 全绿 **259 项**（新增 6：交错渲染/自动展开/孤立记号/
英文词保护/本地空响应重试）；analyze 无新增告警。APK：debug `app-debug.apk` 100703276B /
release `app-release.apk` 53406582B（17:13/17:14，bce9b83），字符串级验收过
（debug kernel `_timelineWidgets`>0 且 `_dbgStep`=0；release `[AGDBG/STEPS]`=0）。

> **排障提示（web_search 类"工具失败"）**：先翻推理日志区分三段——① 工具结果是否含时间标签
> （含=搜索成功，是模型/回合的问题）；② 回合是否"本轮执行失败"（多半是思考截断空响应，看
> 是否触发重试）；③ 工具卡是否"执行中"卡死（超时/引擎慢）。别只看工具卡状态图标。

## 2026-09-29 v0.2.9：Vulkan 全败定案（turnip dlopen 缺 libhardware.so）+ 并发搜索 + agent tok/s 指标 + 思考流滚动

> 用户三连报：① Vulkan 加载任何模型都失败（回落 CPU）；② 智能体输出消息没有 toks 指标；
> ③ 一个问题要 web_search 试几次，要一次性并发。另补：思考流式长内容不自动滚动到可见区。

**① Vulkan 全败根因（打包问题实锤但非新回归）**：JNI 把 `GGML_VK_TURNIP` 指向 APK 内置
turnip（libturnip_freedreno.so），dlopen 失败：`library "libhardware.so" not found`——
turnip 的 DT_NEEDED 含 `libhardware.so`（Android HAL 库），**App 进程 classloader 命名空间
不能 dlopen 系统 HAL 库** → ggml-vulkan init 失败 → `backend_ptrs.size()=1`（只剩 CPU）→
`Vulkan 不可用，回落 CPU`。v0.2.6 时代 turnip 验证全在 CLI 测试基建（shell 命名空间可解析
libhardware.so），**从没在 App 进程内验证过**——入库即埋雷。
- **修复**：`jniLibs/arm64-v8a/libhardware.so` 极简 stub（源码 `stub_hardware.c`，NDK clang
  编译，仅导出 turnip 实际 import 的 `hw_get_module` 返回 -ENOENT）。dlopen turnip 时依赖
  解析在 app 自己的 lib 目录命中 stub → 成功。LLM 推理不走 gralloc/AHardwareBuffer 导入路径，
  -ENOENT 安全。SONAME 必须与系统库同名（`-Wl,-soname,libhardware.so`）。
- **验收铁证**：logcat `using Vulkan HAL GetInstanceProcAddr from .../libturnip_freedreno.so`
  + `Found 1 Vulkan devices: Adreno (TM) 825 (turnip Mesa driver)` + `backend_ptrs.size()=2`
  + `loadModel result: true`。
- **坑**：NDK 裸 `clang --target=aarch64-linux-android` 缺 crt 文件，须用
  `aarch64-linux-androidXX-clang.cmd`（带 sysroot 的 wrapper）编译。

**② 智能体回答 tok/s 指标**：agent 路径保存 answer 时从不带 `inferenceStats`（无计时）。
修复：`_sendAgentMessageNew` 回合结束后（本地路线）读原生 `getInferenceStats()`——
**末步（答案步）就是最后一次 generate，n_gen/t_gen_ms 恰好是答案步口径**，与普通聊天同一
tok/s 公式；API 路线无原生 stats 保持不显示。首Tok 对多步回合无单步语义 → `firstTokenMs=0`，
`_formatStats` 相应省略首Tok（`首Tok` 前缀并入 first 变量，0 时整段消失）。

**③ 并发搜索**：`web_search` 加可选 `additional_queries: string[]`（最多 3 个），
`Future.wait` 并行搜索全部关键词，合并返回（每关键词一个小节 `[搜索：xxx]`，各小节均分
1500 字预算）。描述里教模型"一个问题的多个角度一次提交，不必多次调用"。
回归：todo_web_search_test 新增并发合并 + 截断（≤4 关键词/空串忽略）两用例。

**④ 思考流式滚动**：ThinkingStreamCard 内部 150px 滚动区加 `ScrollController` +
didUpdateWidget 内容变长时 `jumpTo(maxScrollExtent)` 跟随底部；用户手动上滑暂停跟随
（scroll listener 判 atBottom），回合结束/答案开始自动恢复。测试：phase6 新增
"长内容自动滚到底 + 用户上滑后暂停"。

**验收**：test/agent 全绿 **242 项 + 2 skip**；analyze 无新增告警（既有 3 unnecessary_import
+ 1 null-aware warning 为旧代码，未动）。APK：debug `app-debug.apk` / release
`app-release.apk`，字符串级验收过（debug kernel `_followStream`>0 且 `_dbgStep`=0；
release libapp.so `_followStream` 单字节 ASCII 命中；libhardware.so + libturnip_freedreno.so
均在 APK）。

> **遗留（用户指示先放）**：简单对话 Vulkan tok/s 失真 vs OpenCL 正常——待真机抓原生
> t_gen_ms 对比定位，别在没证据时改计时口径。

> **反复调用结论（为什么"一个问题搜几次"）**：每步模型自由决策，结果不够就再搜（4B 模型
> 收敛性弱）；空响应重试（retryEmptyResponse:true）让截断步骤重试可见化，加重"反复"观感。
> 并发多关键词 = 一次调用覆盖多角度，直接压交互次数；工具结果尾部"以上结果已够，直接回答"
> 引导收敛留作后续可选优化。

## 2026-09-29 web_search 反复搜索死循环根治（DSH max_uses 语义，commit c9894f4）

> 用户反馈（三连）："为什么要反复调用多次""大部分搜索是重复搜索相同的内容"
> "经常反复搜索十几次，甚至用完循环次数没输出"。根因：端侧 4B 模型不收敛，
> 拿到结果后仍用同一/近似关键词反复调用 web_search，直到撞 maxRounds 无答案。
> 对照 DSH 真源（`/e/deepseek-harness-src/packages/web/web-search-deepseek/src/provider.ts`）：
> **web_search 服务端工具带 `max_uses` 硬上限**（默认 5），达到后拒绝调用、强制模型
> 基于既有结果回答——平台侧强制收敛，不靠模型自觉。

**落地（web_search_tool.dart）**：
- **回合级预算**：每次调用消耗 1 次（含重复，对齐服务端 max_uses 计数）；
  达到上限**拒绝联网**返回 `ToolResult.error('本轮搜索次数已达上限（N 次）…请直接回答，
  不要再调用 web_search')` —— 收敛指令即时返回、零网络成本。
- **同内容去重**：主查询归一化（小写/去空白标点）相同 → 直接回缓存结果
  （`已搜索过，结果同上，未重复联网`），不重复联网；重复同样消耗预算，尽快逼模型收敛。
- **状态随回合重置**：createWebSearchTool 每次新建回合会话，接入层每回合重建
  注册表（createBuiltinTools 全量新建），无需显式 reset。
- **设置项** `agentMaxSearchesPerTurn`（1~10，默认 5 = DSH 默认）：settings_service/
  provider/screen（智能体→执行参数「每回合搜索上限」）/chat_provider 传递。
- **系统提示**加规则：已有足够结果直接回答；收到"已达上限"立即停止调用 web_search。
- 回归：test/agent 245 + providers 20 全绿（新增去重/预算/重复消耗 3 测试）。
- 验收：APK 字符串级（debug kernel UTF-8 / release libapp.so UTF-16LE 均命中
  `已达上限`/`每回合搜索上限`）；app-debug.apk 100715376B / app-release.apk 53416056B。

## 2026-09-30 智能体多人格（Persona）：标准 + 用户自定义，按场景切换

> 用户需求：智能体不再只有一种人格；保留标准人格（行为不变），支持用户新增
> 多个人格，针对不同场景（写作/翻译/严谨问答…）切换不同智能体。

**数据模型**（`lib/models/agent_persona.dart`）：
- `AgentPersona {id, name, prompt}`（toJson/fromJson）；内置常量
  `kStandardPersonaId = 'standard'`，标准人格**不落盘**、不进列表。
- `InferenceSettings` 新增 `agentPersonas: List<AgentPersona>`（默认 const []）
  + `activePersonaId`（默认 standard），toJson/fromJson/copyWith 全链路；
  `_parsePersonas` 丢弃缺 id/name 的非法条目；便捷读取 `activePersona()`：
  标准人格返回 null（= 行为与旧版完全一致），激活 id 悬空（已删除）回落 null。

**提示词注入**（`agent_prompt.dart` buildSystemPrompt 新增可选参
`personaName/personaPrompt`）：
- 自定义人格：身份段改为「你是「{name}」——TongYi-Lite 智能体，由 X 模型驱动…」，
  人设指令作为独立【人格设定】段插在身份段与【工具调用规则】之间
  （人设不覆盖工具纪律）；prompt 为空只换自称不插段。
- 不传参 = 标准人格，逐字与旧版一致。
- 子代理（InProcessSubagentProvider）复用同一 systemPrompt，人格自动跟随。

**KV 不变量（重要）**：激活人格是系统提示词前缀的组成部分 → 同会话**切换人格
必须 resetContext**。chat_provider 新增 `_currentKvPersonaId` 标记，agent 路径
三段判断：会话变了 / 非 agent→agent / 人格变了，任一命中都 reset；普通聊天
路径把标记清 null。

**设置 UI**（settings_screen._AgentTab，①驱动模型与②执行参数之间新卡
「🎭 人格（Persona）」）：ChoiceChip 选择（标准 + 自定义），当前人格 prompt
预览（≤3 行省略）；新增/编辑走 `_showPersonaDialog`（名称必填 + 多行人设提示词，
保存 trim），删除有确认框；删除激活人格自动回落标准。
settings_provider 新增 `setActivePersona`（校验 id 存在）/`upsertPersona`/
`deletePersona`（删激活 → 回落 standard）。

**回归**：`test/agent/persona_test.dart` 新增 10 项（标准不变/自称+人设段注入/
段序/空 prompt/序列化往返/默认值/悬空 id 回落/旧配置兼容/非法条目丢弃/copyWith）；
`flutter test test/agent test/services test/providers` 全绿 **323 项 + 2 skip**，
analyze 无新增告警。本机 flutter SDK 在 `C:\src\flutter`（不在 PATH，直接用
绝对路径调 flutter.bat）。

## 2026-09-30 内置通用技能扩充（10 个；API 模式 load_skill 可启用）

> 用户需求：通用常用的 skill 搞一些进来，针对 API 模式接入智能体场景可启用。

- `lib/agent/skills/skill.dart` loadBuiltinSkills 从 2 个（web-research/code-review）
  扩到 **10 个**，新增 8 个通用技能：translation（翻译）、writing-polish（写作润色）、
  summarize（长文摘要）、data-analysis（数据分析，python_exec 统计+export_file 交付）、
  email-draft（邮件/文书）、explain-code（代码讲解/报错排查）、plan-todo（任务拆解，
  todo_write）、file-report（报告/网页产物，write_file+export_file）。
- 生效链路不变：`<available_skills>` 目录（name/description/whenToUse）每回合注入
  系统提示词（本地/API 都注入）；**load_skill 工具仅 API 模式注册**（useApi 门控，
  本地档省 prefill 不开）——模型按 whenToUse 命中后调用 load_skill 拉全文执行。
  用户技能目录 ApplicationSupport/skills/<name>/SKILL.md（rank 200）同名覆盖内置。
- 每个技能 body 都绑定本 app 真实工具集（read_file/python_exec/todo_write/
  export_file/web_search），不写空泛指引。
- 回归：`test/agent/skills_builtin_test.dart` 新增 4 项（清单/逐技能 load_skill
  拉全文/目录注入/用户同名覆盖）；test/agent+services+providers 全绿
  **327 项 + 2 skip**。
- **2026-09-30 11:07 重打包（v0.2.8+16，多人格+通用技能）**：
  app-debug.apk 103893384 B / app-release.apk 53759231 B；字符串级验收过
  （debug kernel `writing-polish`/`人格设定` 命中；release libapp.so UTF-16LE
  `高质量翻译`/`数据统计与分析`/`人格设定` 命中）。

## 2026-09-30 设置页用户技能管理 UI（新增技能不再手放文件）

> 用户需求："想加技能去哪找？能不能简单添加，别像现在那么麻烦"（原方式 = 手机上
> 手写 ApplicationSupport/skills/<name>/SKILL.md，根本没法操作）。

- **provider.dart 新增落盘函数**（直接写标准 SKILL.md，与扫描链路同构、零新存储）：
  `userSkillsDirPath()` / `sanitizeSkillDirName()`（空白→`-`、剔除
  `\/:*?"<>|.` 与首尾 `-`）/ `buildSkillMarkdown()`（meta 在 `---` 前，
  Skill.parse 兼容）/ `writeUserSkill()`（previousName 非空 = 改名迁移目录）/
  `deleteUserSkill()`（递归删目录）。
- **设置 UI**（智能体 Tab ⑤ Skills 卡）：用户技能列表行可点按编辑 +
  尾随删除按钮（确认框）；「新增技能」对话框四字段——技能名（编辑态锁定，
  保存后不可改）/ 一句话描述 / 何时触发 whenToUse / 技能正文（多行）；
  保存即写 SKILL.md + 自动重扫描。卡内附提示：网上现成 SKILL.md 复制进
  目录后「重新扫描」同样有效。
- **去哪找技能**：技能本质是纯文本提示词模板——① 设置页直接写；
  ② 从社区（GitHub anthropics/skills、awesome-claude-skills 等）复制 SKILL.md
  放入技能目录；③ 直接让智能体自己起草一份写入技能目录。
- 回归：`test/agent/user_skill_store_test.dart` 新增 6 项（写入→扫描往返/
  更新覆盖/改名迁移/删除/ sanitize/ buildSkillMarkdown↔Skill.parse 兼容）；
  全量 333 项 + 2 skip 全绿，analyze 0 error。
- **2026-09-30 11:15 重打包（v0.2.8+16，多人格+通用技能+技能管理 UI）**：
  app-debug.apk 103901793 B / app-release.apk 53760707 B；字符串级验收过
  （debug kernel `新增技能`/`writeUserSkill` 命中；release libapp.so UTF-16LE
  `新增技能`/`何时触发` 命中）。

## 2026-09-30 UI/体验批量调优 + MiniCPM5-2B 上架（v0.2.8+16 重打包）

> 一批 UI 反馈落地，版本号策略不变（复用 0.2.8，code 16，覆盖安装）。

**① 设置页紧凑化**：卡内 padding 16→12、卡片间距 16→10、`_buildToggleTitle`
16/12→14/11、滑块行文字 13/12→12/11 且 Slider 包 `SizedBox(height:34)`、
开关 `shrinkWrap`；推理引擎 tab 的 **OOM 守卫卡片重复渲染两次**已删一处
（拉取代码时引入的重复块）。
**② 存储空间 0MB 根因**：`_StorageInfoWidget` 只扫 `appDocs/models`，而模型
实际存外部主目录（`/storage/emulated/0/TongYiLite/models`）——已改为按
`ModelStorageService` 候选目录扫描（主目录+内部+app docs，.gguf 列表 +
.mmproj/.dspark.gguf 计入总量）。
**③ 推理日志一键复制**：日志页 AppBar + 推理引擎 tab「最近日志」标题行
复制按钮（全量 `join('\n')`）。
**④ 智能体 tab**：驱动模型 API 选择显示**配置名**（此前显示 ApiModelConfig
uuid）；单轮最大步数 24→**100**（slider/provider clamp/config assert 三处同步）。
**⑤ 输入区合并**：麦克风并入发送键（短按=发送/停止、长按=按住说话松手发送；
手势区在 FAB 外层 + ValueNotifier 驱动图标防松手丢失）；图片/相机/文件附件
合并为一个「+」按钮弹底部面板（徽标=已选总数）。
**⑥ 回合过程总折叠区**：`AgentTurnBlock` 完成后工具卡+思考存档自动收进
`_TurnProcessSection`（默认收起，"执行过程 · N 工具 · M 思考"点开回看）；
**思考落库**：turn 结束把 `thinkingHistory` 逐块存为 `💭 ` 前缀消息（与 🔧 同
规则不入模型上下文，`_isToolActivityMessage` 已扩展匹配 💭），历史回合经
`groupMessages` 的 `TurnUnit.thinking` 回看——此前思考只活在 live 状态、
回合结束即消失。
**⑦ 会话列表**：时间带日期（今天/昨天/MM-DD/YYYY-M-D）。
**⑧ 回复转发**：气泡新增分享按钮（`ShareService`→`files` channel
`shareText`→ACTION_SEND chooser，用户选微信等），MainActivity 加 handler。
**⑨ 对话文字整体缩放**：`chatTextScale`（0.7~1.3 默认 1.0，智能体 tab 滑条），
home_screen 消息列表包 `MediaQuery(textScaler: TextScaler.linear)` 整体缩放。
**⑩ catalog**：删 `agents-a1-4b`；新增 `minicpm5-2b-q4_k_m`（1.5GB，sha256
ec2d…02fd）与 `minicpm5-2b-q8_0`（2.5GB，sha256 c541…b078），ModelScope 主源
（OpenBMB/MiniCPM5-2B-GGUF，128K 上下文、tool-calling）。**DSpark 草稿头
（BF16 623MB）用户定案不挂**：仓库无 Q4/Q8 草稿头、fp16 太大。

回归：test/agent+providers+services 全绿 **335 项+2 skip**（phase6 两用例
更新为总折叠区交互 + 新增 💭 分组/折叠区回看用例）。
**2026-09-30 13:24 重打包（v0.2.8+16）**：app-debug.apk 105005917 B /
app-release.apk 53789540 B；字符串级验收过（debug kernel/release libapp.so
`对话文字大小`/`执行过程` 命中；APK 内 models_catalog.json `minicpm5-2b-q4_k_m`
命中、`agents-a1` 为 0）。

## 2026-09-30 补丁：附件面板死链 + 本地模型"回答漏 tool 标签"根治

> 用户两连报：① 附件/拍照/相册上传全坏 + 面板丑；② 本地模型智能体任务
> 全部失效，回答直接显示 `<tool_call><get_time</tool_call>` 这类原始标签。

**① 附件面板死链（真 bug）**：`_showAttachSheet` 把 `showModalBottomSheet`
的返回值丢弃（泛型写成 `void`）、靠一个从未赋值的 `_pendingAttachSource`
分发 → 选完任何项都只关面板、什么都不发生。修复 = 直接消费
`Future<_AttachSource?>` 返回值；面板重做样式（圆角+把手+着色图标容器+
副标题，`_AttachOption`）。
**② tool 标签泄漏机制（真机 uiautomator 抓到实锤）**：2B 级模型输出
`<tool_call><get_time</tool_call>`（名字前多一个杂散 `<`）→
`_extractXmlToolCall` 名字正则 `[^<\s]+` 匹配失败 → 三层容错全跳过 →
"优雅降级为普通文本"把整段原始标签当回答漏给用户，turn 还显示"完成"。
三层修复：
- **名字提取容错**：剥掉名字前 `<`/`>`/`/`/空白再提取（守卫 arg_key/
  arg_value/tool_call 假名）；`</tool_call` 漏 `>` 也能定位块尾；
  截断判定加宽：含 `</tool_call`（无 `>`）不算截断，交回 XML 容错。
- **防泄漏兜底 `_noLeakFallback`**：所有容错都解不开但文本含
  `<tool_call>` 标记 → 抛新失败码 `LlmFailureCode.toolCallSyntax`
  （可重试，走"上次尝试失败"反思注记），**绝不把原始标签当回答**。
- **load_skill 教唆门控**：`availableSkillsText({loadSkillAvailable})`，
  本地档（load_skill 未注册）注入文本不再教唆调用该工具。

排障方法论：真机复现别只盯 logcat（环形缓冲会滚掉）——`uiautomator dump`
的可见文本直接能抓到泄漏实锤；消息库 `run-as ... cat databases/tongyilite.db`
拉回本地 sqlite 查最近回合。adb shell 路径参数在 Git Bash 会 mangling，
`export MSYS_NO_PATHCONV=1`。

回归：test/agent+providers+services **340 项+2 skip 全绿**（协议新增 3 用例：
杂散 `<` 容错/漏 `>` 闭合/toolCallSyntax；phase5 新增 load_skill 门控用例）。
debug APK 13:5x 重打包已覆盖安装真机（install -r -t，设备弹窗需手动允许）。

## 2026-09-30 终修：MiniCPM5 工具标记是特殊 token，被原生反解码丢弃（root cause 定案）

> 用户三报"本地模型智能体还是不行"。真机 DB 取证（exec-out run-as cat 免
> CRLF 翻译）看到 MiniCPM5 回答是 ` name="get_weather">` 这种**掐头碎片**——
> `<function`/`<parameter`/`<tool_call` 前缀全消失。

**根因（实锤）**：MiniCPM5 系的工具调用标记是**特殊 token**，而
`tongyilite_jni.cpp` 生成循环 `llama_token_to_piece(..., special=false)`
把特殊 token 渲染为空 → Dart 侧永远收不到 `<tool_call>` 骨架，只剩普通
文本碎片 ` name="..."`；任何提示词格式/解析器容错都救不了（信息已在
原生层丢失）。此前 qwen3.5 漏 `<tool_call><get_time</tool_call>` 是另一
形态（tag 是普通 token 能到达 Dart，但格式坏+解析不容错）。

**修复（原生+协议双层）**：
- **原生**：emit_token `special=true` 渲染特殊 token；plain/MTP 两循环
  停止条件补 `llama_vocab_is_eog` 全集判定（eos 单 id 之外，
  `<im_end>`/`<end_of_turn>` 等必须挡在 emit 之前，防漏进正文）。
- **协议**：`_extractFunctionToolCall` 支持属性式
  `<function name=…><parameter name=…>…</function>`（tool_call 包裹与
  闭合均可缺省）；`_extractXmlToolCall` 假名守卫加 function/parameter
  （否则修复后 name 提取会误判成名为 "function" 的工具）；防泄漏正则
  扩到 function/parameter。

**排障工具链沉淀**：adb shell 输出有 CRLF 翻译（文件变大且 sqlite 损坏），
用 `adb exec-out`；Git Bash 路径 mangling 用 `MSYS_NO_PATHCONV=1`；python
读 /tmp 要 `cygpath -w` 对齐；live DB 快照可能撞上写中状态，多拉两次。
验证原生改动编入：APK 内 libtongyilite_jni.so 搜新日志串（如 `EOS/EOG`）。

回归：342 项+2 skip 全绿（新增属性式格式 2 用例）。debug APK 14:28 重打包
（libtongyilite_jni.so 已含改动，字符串级验证过），设备断开未装——重连后
`adb install -r -t`。

## 2026-09-30 llama.cpp b11267 升级 Vulkan 修复定案（commit 0909603，已推送 main）

> fork 基线 fe8156f → 上游 b11267（0.5.0）一步到位升级，保留全部 fork 资产
> （dspark/spark2_5、PTQ1_0 内核、FWHT、turnip 直载、KleidiAI vendored、MTP）。
> 升级后真机三连败 → 定案修复（全部验证通过，用户确认）。

**Vulkan 全模型转圈/空输出（根因三层）**：
1. **GGML_VK_TURNIP env 被上游移除**（大重写后无该 env）→ JNI 内置 turnip 直载失效
   → 系统 stock 驱动 → 空输出。修复：移植 fork 的 turnip HAL 直载
   （dlopen + dlsym ICD→HAL，HAL 偏移 0x70 PFN 表），GGML_VK_TURNIP env 触发。
2. **NO_SUBGROUP / NO_MMV env 被上游移除** → fork 的 Adreno 825 适配失效。
   修复：移植两 env（use_subgroups / ggml_vk_should_use_mmvq 首部检查）。
3. **b11267 混用裸 Vulkan C 函数**（系统 loader 符号）→ turnip 创建的 device 传入
   系统函数 → SIGSEGV 启动崩溃（ggml_vk_device_is_supported @16306，fault 0x1cdc16e）。
   修复：**11 处裸调用全部 dispatcher 化**（vkGetPhysicalDeviceFeatures2 ×3 /
   vkGetInstanceProcAddr ×7 / vkGetDeviceProcAddr ×1 → ggml_vk_default_dispatcher()）。

**验收铁证**：using Vulkan HAL GetInstanceProcAddr from .../libturnip_freedreno.so
+ Found 1 Vulkan devices: Adreno (TM) 825 (turnip Mesa driver) + ackend_ptrs.size()=2
+ loadModel result: true → Vulkan 正常输出（用户确认）。

**一代 Bonsai 27B（Q1_0）OpenCL 偶发答非所问**：无 dspark 头、Q1_0 内核与 fork 字节
相同；Vulkan 修复后用户真机复测 OpenCL + Vulkan 均正常（偶发未再现）。

**Bonsai-2 27B（PTQ1_0 5.95GB）OOM 守卫**：11GB 机器 GPU 全载物理不可能（OOM 守卫
预检拒绝 [oom-guard] refuse PRE-load）；OpenCL PTQ1_0 mm/mv 内核完整；
Vulkan supports_op 无 PTQ1_0/PQ2_0 → fallback CPU。**升级后新坑**：裸 Vulkan 函数
必须 dispatcher 化（b11267 大重写后混用系统 loader 符号），下次动 Vulkan 先查这类。

## 2026-10-01 Dev Agent 开发模式（Phase A/B/C，已提交待真机验收）

> 用户需求：安卓沙箱限制智能体，能否集成 dartssh 连手机自身 shell 以系统环境做开发（AI 编程）。
> 评估定案（docs/ssh_agent_environment_2026-10-01.md）：SSH 只传输不授权限（权限边界=服务端进程）；
> 路线 A（Termux）+ D（远程 PC），root 排除；dartssh(1.0.3) Dart3 不兼容 → 复用 DSH-Phone 的 dartssh2 fork。

**已实施（docs/ai_dev_agent_design_2026-10-01.md 第 11 节实施记录）**：
- **工作区**：`lib/agent/dev/workspace.dart`（DevWorkspace 多后端 localApp/Termux/remotePc，默认工作区不落盘）
  + `workspace_store.dart`（DevStore：ApplicationSupport/dev/workspaces|tasks/<id>.json，baseDirOverride 可测）
  + `dev_controller.dart`（全局单例激活状态）。ToolExecutor 注入 `_workspaceId` 内部键，
  file/memory 工具按 `effectiveWorkspaceOf(args)` 跟随工作区（projects/<safe-id>/）。
- **SSH**：`third_party/dartssh2/` vendored fork（2.11.0，pubspec dependency_overrides path）。
  `ssh_environment.dart`：SSHSocket.connect + SSHClient 认证 + SFTP 读写（8MB 上限）+ TOFU 指纹
  （**onVerifyHostKey 回调签名 = (typeName: String, fingerprint: Uint8List)，同步回调须先预载内存缓存**；
  模式组合用 `SftpFileOpenMode.write | .create | .truncate`）+ 解码 UTF-8→latin1。
- **工具**：ssh_exec/ssh_read_file/ssh_write_file（ssh_tools.dart）、git_status/diff/log/commit/push
  （git_tools.dart，push 带审批）、plan_create/update/list（plan_tools.dart）、run_tests
  （verify_tool.dart）；危险命令黑名单 `safety.dart`（deny/ask 策略）。
- **DevContext**：`dev_context.dart` 注入工作区/计划/记忆段 + 开发循环指引；chat_provider 接线
  （Dev 模式开启时 workspaceResolver + buildDevContext + AGENTS.md workspacePath）。
- **设置**：settings_service/provider Dev 字段（devModeEnabled/devWorkspaceId/sshConfig/dangerousCommandPolicy）；
  settings_screen 开发模式卡（工作区管理/SSH 配置/测试连接/指纹/策略）。
- **回归**：test/agent+services+providers 全量 **388 项 + 2 skip 全绿**（新增 dev_workspace/plan_tools/ssh_safety/dev_context/settings Dev 组）。

**遗留（明早用户确认）**：真机 Termux sshd 配置与连接/SFTP/git 闭环验证；SSH 密钥明文存储（对齐
apiModels 先例，后续迁移 secure storage）；远端 AGENTS.md 读取（Phase D SFTP）；Dev 工具逐个开关（MVP 只做总开关）。

## 2026-10-01 Dev Agent 配置自动化（独立开发者 Tab + 自动向导 + 连接可靠性，Phase E）

> 用户纠偏："你能自己做的，千万不要让我自己去配置操作…你本来是个AI" + "把这个设置页单独做
> 个开发者 tab，优化设置项智能友好些，远程 pc 根本没地方配置" + bug："测试连接成功但页面一直
> 显示未连接 / 123.py 创建报成功是假的"。

**① 独立「开发者」Tab**（settings_screen `_DevTab`，智能体与关于之间）：开发模式开关卡 +
连接配置卡（Termux/远程PC 各自独立入口）+ 工作区卡 + 危险命令策略卡。Dev 方法块从
_AgentTabState 整体迁出（备份 build/dev_block.dart，已弃用）。

**② 多 SSH 配置**：`SshConfig` 加 `id`/`name`；settings_service 单 `sshConfig` → `List<SshConfig>
sshConfigs`（旧单配置 JSON 自动迁移为列表首项）；settings_provider 改 `upsertSshConfig`（按 id
覆盖）/`removeSshConfig`；DevWorkspace 加 `sshConfigId` 绑定配置（工作区 ↔ 连接目标）。

**③ 自动配置向导（唯一人工动作 = 复制粘贴一条命令）**：
- `SshKeyGen`（pinenacl 生成 ed25519 seed+pub，手编 openssh-key-v1 私钥：magic+none/none/empty
  kdf、nkeys=1、checkint=同一 uint64 ×2、string(type)+string(pub)+string(priv)+comment、8B 块
  padding、70 列 base64）。
- **Termux 向导**：探测 127.0.0.1:8022 → 自动生成密钥 → 显示一键安装命令（`pkg install -y
  openssh && sshd && mkdir -p ~/.ssh && echo '<pubkey>' > ~/.ssh/authorized_keys && chmod 600 …;
  echo "USER=$(whoami)" > /sdcard/tongyilite_ssh_user.txt …; echo ALL_DONE`，分号+`|| true` 兜底）
  → 自动读取共享文件用户名（MANAGE_EXTERNAL_STORAGE 已有，读
  /storage/emulated/0/tongyilite_ssh_user.txt，失败回退对话框预填 u0_ 提示）→ 保存配置自动连接。
- **远程 PC 向导**：host/port（host 唯一必填）→ 自动生成密钥 → 显示公钥追加命令
  （`echo '<pubkey>' >> ~/.ssh/authorized_keys`）→ 用户名 → 保存并连接。
- **工作区自动建目录**：连接后 `echo $HOME` → `mkdir -p $HOME/projects/<sanitize>` → remotePath
  自动填入；后端下拉绑定 `sshConfigId`。
- 连接状态监听：_DevTabState 复用 _devStateListener（SshEnvironmentService +
  DevSessionController），否则"测试成功但页面未连接"复现。

**④ 连接可靠性（防幻觉成功）**：工具执行前 `ensureConnected`（按工作区 sshConfigId 自动连接，
复用已连接配置）；执行失败断连自动重连一次重试；错误统一 `[SSH]` 前缀区分未配置/连接失败/执行
失败；dev_context 加【如实报告铁律】——工具返回 error 必须如实复述，未确认结果不得编造"已创建/
已提交/已验证"。ssh_exec/read/write 超时 15s→30s。

**⑤ dartssh2 fork 两处修复（本次抓到，openssh 密钥解析错位）**：
- checkint 是同一 **uint64 写两次**（openssh 官方 = `arc4random_uniform(2^32)` 转 uint64 → 高
  32 位为 0），fork 原用 readUint32 ×2 读高/低半字节 → 官方密钥恒报 Invalid private key；
  改 readUint64 ×2（SshKeyGen 生成全量 64 位随机同样兼容）。
- openssh-key-v1 的 publicKeys 数组元素是**嵌套 blob** = string(type)+string(pub)，不是裸
  type 串 → 编码时 `_writeString(b, pubBlob.toBytes())`；privateKeysBlob 整体包成一个 string
  （checkint×2+type+pub+priv+comment+padding 内嵌）。

**回归**：test/agent+services+providers 全量 **393 项 + 2 skip 全绿**（新增 SshKeyGen 3 项
（fromPem 往返/公钥 47B 解码/每次随机）、settings Dev 组多配置+迁移、dev_workspace
sshConfigId roundtrip/清除/旧 JSON 兼容）；analyze 0 error。
**2026-10-01 09:51 重打包（v0.2.8+16）**：app-debug.apk 140176027 B / app-release.apk
47340915 B；字符串级验收过（debug kernel UTF-8 `开发者`11/`自动配置`4/`连接 Termux`2/`sshConfigs`62/
`_DevTab`9；release libapp.so UTF-16LE `开发者`4/`连接 Termux`1 + 单字节 `_DevTab`2/`sshConfigs`1；
release 内 libtongyilite_jni/libturnip_freedreno/libhardware/libggml-* 全在）。

> **遗留（明早用户确认）**：真机 Termux 一键命令闭环 + SFTP/git 验证；SSH 密钥明文存储（后续迁
> secure storage）；远端 AGENTS.md 读取（Phase D SFTP）；Dev 工具逐个开关（MVP 只做总开关）。

## 2026-10-01 Phase E 真机三 bug 定案修复（迁移补 id + 向导自动探测）

> 用户真机三报：① 已配置删不掉（点删除没反应）；② 编辑改名字又多一条出来；③ 点「连接 Termux」
> 一直转圈。真机取证（run-as 读 inference_settings.json）：用户 JSON 里 sshConfigs 两条**都缺 id**
> （旧配置迁移 + 编辑改名追加），完全吻合。

**根因**：
- 旧配置（无 `id` 字段）迁移后 id='' → `removeSshConfig('')` 直接 return（删不掉）；
  `upsertSshConfig` 空 id 走追加分支（编辑改名 = 复制一条）。
- Termux 向导 `probeAndGen` 定义了但**从未被调用**（打开对话框 step 0 转圈恒 true）。

**修复**（commit 待推送）：
1. `settings_service._parseSshConfigs`：迁移时**空 id 一律补稳定 id**
   （`ssh_legacy_<毫秒>_<index>`，无 name 的补 `host:port` 显示名）；加载即生效，
   编辑/删除用内存 id 操作正确；用户下次改动设置 persist 后 JSON 永久稳定。
2. 编辑对话框保存兜底：existing.id 空 → 分配新 id（防迁移遗漏路径）。
3. Termux 向导：StatefulBuilder 首次构建 `addPostFrameCallback` 自动启动探测
   （注意 Dart 局部函数必须先声明后引用——启动块放 probeAndGen 定义之后）。

**回归**：settings_service_test 新增迁移补 id（非空断言）+ 幂等（补完持久化二次加载
不变 + 空 id 列表全补齐且互异）2 项；全量 **395 项 + 2 skip 全绿**，analyze 0 error。
**2026-10-01 10:36 重打包（v0.2.8+16）**：app-debug.apk 140171564 B / app-release.apk
47343199 B；字符串级验收过（debug/release `ssh_legacy` 命中）；真机已覆盖安装成功。
**排障沉淀**：设备屏幕/前台状态不稳时 uiautomator dump 会抓到 systemui 或别的 app——
验证优先走文本通道（run-as 读设置 JSON 直接取证配置数据），UI dump 仅作辅助。

> **遗留（明早用户确认）**：真机 Termux 一键命令闭环 + SFTP/git 验证；SSH 密钥明文存储（后续迁
> secure storage）；远端 AGENTS.md 读取（Phase D SFTP）；Dev 工具逐个开关（MVP 只做总开关）。

## 2026-10-01 多会话并发（并发会话槽位）：AgentUiState 按会话分键 + 槽位门控

> 用户需求：智能体可能多对话并行，发送键不应被单一会话的"执行中"锁死整个 App；
> 在智能体 Tab 用「并发会话槽位」控制同时允许执行回合的会话数量。

**设置**：`agentMaxConcurrentTurns`（1~4，默认 1 = 与旧版行为完全一致），
智能体 Tab → 执行参数 →「并发会话槽位」滑条；fromJson 解析夹紧 1~4。

**核心机制（chat_provider）**：
- `runningTurnsProvider`（Map<convId, 是否本地路线>）= 多会话并发的唯一真相；
  `isGeneratingProvider` 变为其派生（任意会话在跑）。**UI 判"当前会话生成中"
  一律用 `runningTurnsProvider[当前会话id]`，不要再用全局 bool**。
- `ChatNotifier._activeTurns`（convId → `_ActiveTurn`，含 agent 引用/local 标记/
  started/userCancelled）：sendMessage **顶部同步注册占位**（检查与注册之间无
  await，防双开竞态），顶层 finally 统一注销；`started=false` 的占位不进 UI 态。
- 门控纯函数 `checkTurnAdmission`：① 本地引擎（权重+KV）单实例 → **本地回合
  彼此互斥**（与槽位无关）；② 总活跃回合数 ≤ 槽位（API 会话可真正并行）。
  拒绝文案经 `_rejectTurn` **落库为 assistant 消息**（sendMessage 返回值无人
  消费，不落库用户永远看不到被拒原因）。
- **KV 仅本地路线管理**：两条发送路径的 resetContext/KV 标记块都加了
  `if (!useApi)` 守卫——否则后台 API 回合启动会把并行运行中的本地回合
  KV 上下文重置掉（静默污染）。
- `stopGeneration({conversationId})`：传 id 只停该会话（聊天页停止键）；
  不传停**全部**（模型卸载/重载前，settings_screen、home_screen 弹窗用）。
  停止标记（userCancelled）随 `_ActiveTurn` 走，`_suppressUserCancelled` 按
  回合句柄判断。

**AgentUiState 按会话分键（agent_state_provider）**：
- `AgentUiStateNotifier` 的 state 改为 `Map<String, AgentUiState>`；
  `attach(convId, log)`/`detach(convId)`/`setThinking(convId,…)`/
  `setToolGen(convId,…)`/`onEvent(convId, e)` 全部带会话键；detach 仍保留末态。
- home_screen 取 `agentUiStateProvider[当前会话id] ?? const AgentUiState()`。
- ⚠️ 事件归约器必须 `if (!mounted) return;` 守卫 + dispose 时取消全部订阅
  （后台回合的订阅可能在 notifier 被丢弃后仍推事件，StateNotifier 置 state
  会抛 StateError）。

**回归**：test/agent+services+providers 全量 **402 项 + 2 skip 全绿**（新增
phase6 双会话隔离用例、settings 槽位往返/夹紧、checkTurnAdmission 5 用例）；
analyze 0 error（剩余 warning 均为旧代码既有）。

- **2026-10-01 13:13 最新构建（cbf8a6e：多会话并发槽位 + PDF PdfBox 原生桥合并后）**：
  `E:\DTXY\TongYi-Lite\build\app\outputs\flutter-apk\` —
  app-debug.apk 140193795 B（已装小米13：Tailscale 100.70.7.18:5555，无线 adb，
  全新安装 versionCode=16 / 0.2.8）、app-release.apk 59848057 B（含 pdfbox 依赖变大）。
  字符串级验收过：debug kernel UTF-8 `并发会话槽位`5/`checkTurnAdmission`3/
  `NativePdfService`3；release libapp.so UTF-16LE `并发会话槽位`1/`无文本层`1 +
  ASCII `runningTurnsProvider`2；dex 含 PdfExtracter + `com.dgxspark.tongyilite/pdf`
  channel；签名 CN=TongYiLite 核对过。**小米13 无线 adb 址录**：Tailscale peer
  `xiaomi-13` = 100.70.7.18（首连需手机点允许 USB 调试授权）。

## 2026-10-01 Dev Agent SSH 定案：dartssh2↔openssh 10.5 全链路打通 + SshKeyGen 四处格式 bug 修复

> 接 Phase E 遗留真机验证。对照实验（dartssh2 fork 连开发机 openssh 9.5 全握手通过、
> 连手机 Termux openssh 10.5 无响应）后继续排查，终局全链路 `AUTHED` + `echo ok` 通过。

**① "sshd 无响应" = per-source penalty，不是 dartssh2 bug**：OpenSSH 10.x
`PerSourcePenalties` 默认开，认证失败（authfail）/未认证即断（noauth）都会给源 IP
记内存态惩罚，被罚期间**接受 TCP 但不发 banner**（表现 = 连上后 20s 超时）。
手机场景所有连接源都是 127.0.0.1（adb forward / 本机 nc 皆然），且**反复探测会续罚**，
等 1-2 分钟不够（crash 类单次 90s、上限 5×）。**重启 sshd 即清零**（force-stop
com.termux + 拉起后 adb 注入 `sshd` 即可），重启后 banner 秒回。
⚠️ 排障时别用连接探测轰炸被罚的 sshd；判别方法 = 换源 IP 连通性对照。

**② SshKeyGen/解码层四处格式 bug（逐一实锤 + 修复，全部已过 OpenSSH 验收）**：
- **checkint 是两个相同 uint32（共 8 字节），不是 uint64×2**。Phase E 曾把
  dartssh2 fork 改成 `readUint64 ×2` 迁就 SshKeyGen 的 `_u64×2` 坏输出——**修错了层**：
  生成器+读取器自洽（app 内测试连接能过）但与 OpenSSH 官方（sshkey.c
  `buffer_get_int ×2`）及 fork 自己 encode 端（`writeUint32 ×2`）全冲突，官方密钥
  被拒、ssh 工具链不认。已双向改回 uint32 规范（ssh_credentials.dart +
  dartssh2/ssh_key_pair.dart）。
- **padding 字节必须 = 1,2,3,…N**（原来填常量 padLen=0x05×N；新版 OpenSSH 逐字节校验）。
- **公钥单行少内层长度前缀**：`_encodeOpenSshPublic` 原来 `b.add(pub)` 裸拼，
  authorized_keys 行 = string(type)+string(pub) 共 51 字节；坏行（47B）sshd 直接拒 →
  **这就是认证失败的直接根因**（真机 authorized_keys 里装的正是坏格式旧公钥）。
- **PEM 末尾必须有换行符**（`-----END…-----\n`），否则 OpenSSH 10.3p1+OpenSSL 3.5
  报 `error in libcrypto: unsupported`。

**验收链**：`ssh-keygen -y -f <pem>` 输出与 .pub 逐字一致（此前恒拒）；真机
authorized_keys 覆盖装新公钥 → dartssh2 fork 完整 KEX/认证/`echo ok` 全通；
test/services/settings_service_test 两个钉死坏格式的断言已改为规范断言
（公钥 blob 47→51 字节 + 内层 32 长度前缀；PEM 尾换行）。全量 test/agent+services+
providers **402 项 + 2 skip 全绿**。

**真机取证工具链（本次新增）**：Termux 无存储授权时 /sdcard 写不进——先
`appops set com.termux MANAGE_EXTERNAL_STORAGE allow` 再注入命令导出到 /sdcard 用 adb 读；
uiautomator 读不到 Termux 终端文本；注入前先 `input keyevent 66` 清半行/确认 shell 就绪，
Termux 冷启动要等 5-6s 再注入；`cat ~/.ssh/...` 在 adb shell 身份下看不到 Termux home。
无线 adb 瞬断会吞 adb forward（forward --list 看着在但连 18022 被拒）——remove 再 add。
临时复现测试 test/ssh_repro_live_test.dart、ssh_keygen_regen_test.dart 已按约定删除；
复现密钥留存 build/ssh_repro_key.pem/.pub（真机 authorized_keys 已装对应公钥）。
- **坑总结文档**：dartssh2 fork / SshKeyGen / Termux sshd 全部坑点与验收工具链
  已整理进 `docs/dartssh2_termux_pitfalls_2026-10-01.md`（SSH 排障先读它）。
- **2026-10-01 14:55 最新构建（5afdccd：SSH 密钥格式修复）**：
  `E:\DTXY\TongYi-Lite\build\app\outputs\flutter-apk\` —
  app-debug.apk 140191854 B（已覆盖安装小米13，versionCode=16 / 0.2.8，Success）、
  app-release.apk 59847585 B。验收：debug kernel 与 intermediates 副本**字节一致**、
  标记 `并发会话槽位`5/`sshConfigs`62/`开发者`11 命中；release libapp.so 与
  flutter-assemble/app.so 仅 ELF section 头顺序不同（gradle strip 重排，代码 section
  一致非陈旧产物），UTF-16LE `并发会话槽位`1/`开发者`4 + ASCII `checkTurnAdmission`1
  命中；签名 CN=TongYiLite 核对过。本次修复为纯逻辑改动、无新增运行时字符串，
  行为级验收 = 真机 dartssh2↔openssh 10.5 全链路 AUTHED + echo ok（见上节）。
- **2026-10-01 15:2x 双机覆盖安装**：5afdccd 的 app-debug.apk 已装两台——
  小米13（100.70.7.18:5555，Tailscale 直连）与 小米25053RT47C 8 Elite
  （100.123.25.54:5555，DERP sin 中继，140MB 传输约 20 分钟，install -r -t 均 Success，
  双机 versionCode=16 / 0.2.8）。8 Elite 无线 adb 址录：Tailscale peer
  `xiaomi-25053rt47c-1` = 100.123.25.54。

## 2026-10-02 端侧直连国内搜索引擎模块（lib/websearch，6 引擎 + 熔断 + 安全管控）

> 用户需求：摆脱自建 SearXNG 强依赖，端侧直连 ≥3 家国内搜索引擎（可复用独立
> 模块）；后续追加：引擎开关设置 + 每 10 分钟窗口搜索上限 + 细水长流防封。
> **过程文档（实测证据/调研/坑速查）= `docs/websearch_direct_2026-10-02.md`，
> 动搜索模块先读它。**

**模块**（纯 Dart 仅依赖 dio，无 Flutter/agent 依赖）：`lib/websearch/` —
契约 `SearchEngine`/`SearchHit`/`FetchPage` 注入；引擎 bing_cn（RSS 主+HTML 兜底）、
baidu（`tn=json` 主+HTML 兜底，302 wappass 判风控）、sogou、so360、quark、
chinaso（官方 JSON，**必须带随机 uid Cookie**）；`engine_http`（Cookie 会话+
UA 池）；`multi_engine_search`（加权轮转合并/去重/熔断/窗口预算/诊断）；
`link_resolver`（baidu·chinaso=302，sogou·360=页内 meta/JS）。
上层：`lib/agent/web_search/direct_search_provider.dart` 单例 +
`applySearXNGProviderFromSettings`：SearXNG 地址已配置=SearXNG，**未配置=直连引擎**（零配置可用）。

**安全管控（细水长流）**：每引擎每 10 分钟窗口请求预算（低风险档默认 6、
高风险档 sogou/baidu/quark 默认 2，设置页可调 1~10/1~6）+ 引擎独立开关
（`webSearchDirectEngines`）；blocked → 指数熔断 2min×2^n 封顶 15min + 清
Cookie 会话 + 换池内 UA（**UA 会话级稳定，只在换身份时换**）；budget/cooling
跳线由其余引擎覆盖。设置 UI 在「API 接入 → 联网搜索」卡下半部。

**实测结论**：必应 RSS 10 连发全成；360/中国搜索稳；搜狗连发 4-5 次封
（惩罚绑 Cookie，换 IP+新会话首发即过）；百度连发即封且对蜂窝 CGNAT IP 段
重点照顾（302 wappass）；夸克约 9 次触发 x5sec（罚 15min）。新 IP 实测
单次搜索 5 引擎同出（bing 8/sogou 8/quark 7/360 5/chinaso 4）。
解析坑速查：各引擎内嵌真实 URL 字段 = baidu `mu=` / so360 `data-mdurl` /
sogou `data-url`；百度/搜狗拦截页都是 HTTP 200 小页（判定串
`百度安全验证`/`antispider`），百度 tn=json 风控是 302→wappass（Dio 必须
`followRedirects:false`）；属性值先 unescape 再解析。

**回归**：test/websearch **54 项**（fixture 解析 25 + json 8 + quark 6 + 聚合器
12 + provider 5 + live 2 门控）；全量 test/agent+providers+services+websearch
**458 项 + 4 skip 全绿**，analyze 0 新增。
**APK**（v0.2.8+16 复用）：app-debug.apk 106628214 B / app-release.apk
59897266 B（10:48/10:55），字符串级验收过；设备未连未装，重连后
`adb install -r -t`。
**构建坑新增**：Git Bash 的 cd 传不进 .bat 子进程 → release assemble 用
PowerShell `Set-Location` 执行；release 产物在 `build/flutter-assemble/app.so`。

## 2026-10-01 API 档上下文生命周期三修复 + P1 harness 五件套（对照 DSH 差距分析）

> 定位修正（用户指令）：**本地模型只走简单对话，智能体主力 = API 接入档**。
> 差距分析全文在 `docs/dsh_gap_analysis_2026-10-01.md`（已对齐项/Tier1-3/P1-P3 分期）。

**Tier 1（bug 级，API 档上下文管理此前基本缺位）**：
1. **溢出分类修复**：此前 400 一律归 `invalidRequest`（终态失败），且
   `openai_service._friendlyDioError` 只取 HTTP reason phrase——400 响应体里的
   "context length exceeded" 详情在源头就被丢弃。修复：`_describeApiError` 异步读
   badResponse 响应体（ResponseBody 字节流，上限 4KB，提取 error.message）；
   `mapApiStatus(statusCode, {message})` 命中溢出文案（13 种特征，宁窄勿宽）→
   `contextWindowExceeded` → 失败瀑布走压缩 → 有界重试。
2. **API 主动压缩**：新设置 `agentApiContextBudget`（默认 32768 tok，夹 4096~200000，
   设置页智能体 Tab 滑条）；`_apiContextTokenBudget` = min(设置值, 端点 contextWindow×7/8)。
3. **工具结果投影剪枝**（DSH tool-result-pruner 语义）：`deriveModelMessages` 对
   >8192 字符的 tool/result 投影为头 4096 + `[…中间省略 N 字符…]` + 尾 1024；
   存储原文与 UI 视图不动。

**P1 harness（用户要求"结合人机交互，能优化就优化，必须重构就重构，不自我设限"）**：
4. **通用重复调用守护**：`ReactLoopAgent` 同一工具本回合第 3/5/8 次 → 结果尾部
   追加渐进提醒（advisory 不阻断），与签名去重双保险（DSH repeat-tool-reminder）。
5. **环境段注入（仅 API 档）**：`ReactLoopAgent.environmentNote` 恒追加系统提示
   **最末**（skills/AGENTS.md 之后）——稳定前缀在前、易变快照在后，API prompt cache
   友好；local 档不传（系统提示逐字节稳定保 KV）。
6. **记忆默认开 + 自动注入**：`agentMemoryEnabled` 默认 true（曾显式存 false 的
   保持 false）；系统提示自动注入【用户记忆】段（前 8 条/条 80 字）；**设置页新增
   记忆管理卡**（条目列表/逐条删/清空，与 memory.json 同存储）。
7. **skill 三连**（用户："skill 很扯淡，模型不能自主创建/不能生效"）：
   - 新工具 **save_skill**（`lib/agent/skills/save_skill_tool.dart`）：对话内模型
     自主沉淀技能 → writeUserSkill 落盘 + `provider.registerUser` 即时注册
     （本回合立即可 load_skill）；两档都注册。
   - **load_skill 去掉 API 门控**：本地档技能目录可见却拿不到正文 = 装饰品；
     工具 def 的 prefill 成本远小于技能失效（推翻 2026-09-30 定案）。
   - 设置页技能卡加 **「导入 SKILL.md」**（粘贴社区现成技能一键解析落盘）。
8. 回归：test/agent+providers+services 全绿 **417 项 + 2 skip**（新增 p1_harness/
   ctx_lifecycle 等 10 项）；主仓 lib+test analyze 0 error。
**2026-10-01 23:2x 重打包（工作区未提交，v0.2.8+16 复用版本号）**：
  app-debug.apk 140246321 B / app-release.apk 59871773 B，字符串级验收过
  （debug kernel：save_skill 16/用户记忆 4/API 上下文压缩预算 2/environmentNote 8；
  release libapp.so UTF-16LE：用户记忆/导入 SKILL.md/清空全部记忆/已保存技能/
  中间省略 均≥1，旧文案"默认关"残留=0）；签名 CN=TongYiLite 核对过。
- **双机覆盖安装 Success**：小米13（100.70.7.18 直连）+ 8 Elite（100.123.25.54），
  `install -r -t` 均 Success（versionCode=16 / 0.2.8 复用）。

## 2026-10-01 技能系统交互重构（用户纠偏三连：扩容/精简/整段粘贴）

> 用户批评：① 内置技能不够；② "描述废话太多"（指**设置页 UI 文案**，不是提示词）；
> ③ 新增技能逐字段手填"不经大脑"——应整段粘贴一站式；④ 内置技能应能点进去看内容。

**落地**：
1. **内置技能 10 → 16 个**：新增 travel-planner / meeting-notes / resume-polish /
   social-copy / shopping-compare / tutor（手机助理高频场景，body 全部绑定真实工具）。
2. **全部文案精简**：description ≤20 字、whenToUse ≤24 字（测试钉死断言），body 砍到
   3 条要点——技能目录每回合注入，技能文本本身就是 prefill 成本。
3. **新增技能 = 整段粘贴一站式**（`_showUserSkillDialog` new 模式重写）：
   一个文本框贴完整 SKILL.md（`name:` 行可选 + description/whenToUse + `---` + 正文），
   技能名自动取 `name:` 行、缺省从描述派生（去尾标点取前 12 字 + sanitize）——
   零额外输入。编辑已有技能才走字段表单。原「导入 SKILL.md」按钮删除（已合并）。
4. **内置技能可点开看全文**（`_showBuiltinSkillView`：触发条件 + 正文可复制），
   支持「另存为我的技能」（预填整段粘贴框，改名/改内容保存后 rank 200 同名覆盖内置）。
5. 设置页废话文案同步精简（记忆卡提示/压缩预算滑条 hint/技能卡说明各砍到一行）。

回归：全绿 **417 项 + 2 skip**（技能清单测试更新为 16 + 长度约束断言）；analyze 0 error。
**2026-10-01 23:4x 重打包（v0.2.8+16 复用）**：app-debug.apk 140246421 B /
app-release.apk 59872005 B；字符串级验收过（16 技能名/整段粘贴/另存为我的技能/
内置 · 均命中，旧逐字段表单文案残留=0；注意 travel-planner 等纯 ASCII 技能名在
libapp.so 按单字节查）。
- **双机覆盖安装 Success**（小米13 + 8 Elite，install -r -t，23:4x 包）。

## 2026-10-01 Termux SSH 连接可用性重构（用户定案："连接难度跟屎一样，从没成功过"）

> **根因（真机已实锤 + 本次补齐机制层）**：手机本机连接源恒为 127.0.0.1，
> Termux 的 OpenSSH 10.x `PerSourcePenalties` 对"连接未认证即断开"逐次记惩罚，
> 被罚期间 **接受 TCP 但不发 banner → 客户端表现 Connection timed out**；
> 而旧向导的 `_probeTcp`（连上就 destroy）+ 用户反复点重试 + 自动重连**全都在续罚**
> ——越试越死，重启 sshd 才清零。用户从未成功不是玄学，是我们自己探死的。
> 加上 Connection refused（sshd 未启动）和 timeout 只甩原始异常，零诊断零动作。

**修复（四件套）**：
1. **探测三分类 + 只探一次**：`_probeSshd` 返回 listening / refused（=sshd 未监听，
   不记惩罚）/ timeout（被拉黑或卡死）；向导打开时探一次，不再循环裸探测。
2. **万能命令 v2**：`pkg install -y openssh procps; pkill sshd; sleep 1; sshd; …`
   ——三种诊断状态一条命令全修复，且**每次执行顺带重启 sshd 清拉黑**（procps 提供 pkill）。
3. **一键拉起 Termux**：MainActivity 新增 `com.dgxspark.tongyilite/app` 通道
   （isAppInstalled / launchApp，launch 用 getLaunchIntentForPackage），
   Dart 侧 `lib/services/app_bridge.dart` AppBridge。sshd 未运行时用户点按钮直达
   Termux，不用回桌面找图标。
4. **失败提示人话分类**：`_classifySshError` 按 refused/timeout/auth 把原始异常翻译成
   "sshd 没在运行 → 重新执行安装命令" / "被临时拉黑 → 重启 sshd" / "认证不通过 →
   核对 USER="，向导与「连接」按钮共用。向导内诊断行直接显示三分类结论。

**验收**：全绿 417+2skip；analyze 0 error（顺手删了 _kvLine 死代码）；
2026-10-01 23:5x 重打包：app-debug.apk 140248864 B / app-release.apk 59872921 B，
字符串级验收过（诊断/拉起 Termux/临时拉黑/pkill sshd 均命中，dex 含 app 通道 +
launchApp/isAppInstalled）。双机覆盖安装 Success。
**遗留**：Termux RUN_COMMAND intent 自动执行命令（需 allow-external-apps，用户侧
一次性开启后可做到零粘贴）——待真机评估。
- **双机 Success**（小米13 一次过；8 Elite 首次 INSTALL_PARSE_FAILED_NOT_APK=
  DERP 中继传输截断，原样重试一次即 Success——140MB 中继安装失败先重试再排查）。

## 2026-10-02 内置技能正文重写（对齐 anthropics/skills 官方规范）+ 技能卡折叠

> 用户批评内置技能"就几句话能解决什么问题"+ 技能列表平铺会把设置页拉成 2 米长。
> 调研定案（anthropics/skills 45k stars + awesome-claude-skills）：官方优质技能正文
> **91~485 行**（工作流步骤+代码模板+验收清单），且 body 是 load_skill **按需加载**的，
> 写厚不增加每回合 prefill——常驻成本只有目录的 name/description/whenToUse 一行短句。
> 此前"body 砍到 3 条要点"是砍错了对象（该精简的是目录字段，不是正文）。

**改动**：
- `skill.dart` 17 个技能（16 原有 + 新增 **skill-creator** 元技能绑 save_skill）正文
  全部重写为真执行手册：`## 目标 / ## 工作流程（编号步骤）/ ## 输出格式（模板）/
  ## 验收清单` 四段式，20~28 行/个，只绑定真实工具名（web_search/read_file/
  write_file/edit_file/python_exec/shell_exec/todo_write/export_file/get_weather 等）。
- `skills_builtin_test.dart`：清单 17 个 + 新增**正文质量下限**断言（非空行 ≥20、
  含 `## ` 分节、含"验收"）——防止未来再回退成三句话。
- `settings_screen` 技能卡：17 个 ListTile 平铺改为**默认收起一行汇总**
  （"技能库（内置 17 · 我的 N）"，点开限高 320px 滚动列表）——技能再多设置页
  也不再拉长；内置取一次存 `_builtinSkills` 字段。

**回归**：test/agent+services+providers 全绿 **418 项 + 2 skip**；analyze 0 error。
**2026-10-02 00:0x 重打包（v0.2.8+16 复用）**：app-debug.apk 140268589 B /
app-release.apk 59886173 B；字符串级验收过（debug kernel UTF-8：验收清单 39/
避雷 2/skill-creator 2；release libapp.so UTF-16LE：验收清单 19/技能库 1 +
ASCII skill-creator 1）。**双机覆盖安装 Success**（小米13 100.70.7.18 直连 +
8 Elite 100.123.25.54 中继，install -r -t 均 Success）。

## 2026-10-03 智能体执行质量九件套（对照 DSH 二次差距分析，commit 5fa142f）

> 用户反馈"智能体还是笨笨的做不好任务"。重挖 DSH 全仓后定案：差距不在循环骨架
> （已对齐），在执行纪律层——收尾机制/验证纪律/todo 纪律/提示词教学段。
> DSH 哲学 = 薄系统提示 + 厚工具描述 + 结构化护栏（纪律靠执行期强制不靠自觉）。

**九件套（P2-A×4 + P2-B×2 + P3×3，全部落地）**：
1. **maxSteps 收敛注入 + 自动续跑**（头号修复）：剩 2 步注入收敛警告 user 事件；
   撞上限不死停——合成收尾提示追加预算（`maxWrapups×wrapupSteps` 默认 2×2），
   老语义用 `maxWrapups:0` 钉死。引导消息只活在本回合（trace 信封不编码 user 事件，
   跨回合自然消失）。
2. **【任务执行纪律】系统提示段**（仅 API 档，`taskDiscipline: useApi`）：
   规划/推进/验证（完成必用工具结果佐证）/诚实 grounding（DSH wrapup 反幻觉句）/停止。
3. **todo_write 执行期强制**：>1 个 in_progress（doing/inprogress/current/active 均为
   别名）→ 直接拒绝 + 修正指引，原清单不污染；结果回显计数。存储保留原词不归一化
   （老测试 `[done]` 兼容）。
4. **read/write/edit_file 描述加厚**：先读后改、写后读回核对、oldString 带上下文。
5. **steer 回合中转向**：ReactLoopAgent 新增收件箱 `steer()`/`injectNotice()`，step
   边界 drain 为 `[用户插话]`/`[系统通知]` user 事件（通知在前插话在后）；
   `ChatNotifier.steerTurn`（无运行回合回退 sendMessage）；home_screen 生成中输入框
   有文字 = 插话发送按钮 + Enter 插话，空 = 停止（heroTag 区分双 FAB）。
6. **ask_user_question**：`agentPendingQuestionProvider`（convId→提问+Completer）；
   UI 提问卡片（选项 chip/自由回答/跳过）；stopGeneration 兜底 complete(null)
   防挂死；等待上限 10 分钟；不假设无法继续才问，描述里写明。
7. **run_code（PTC 最小实现，仅 API 档）**：脚本内 `agent_tool(name, **args)` 编排
   子工具调用；Chaquopy 一次性 runScript 期间 Dart 轮询桥目录（`<uuid>.req/.resp`
   文件交换）；嵌套 run_code 禁止、30 次子调用上限、总超时 120s、桥目录用后即删。
   ⚠️ 桥接预置代码按 `TOOL_BRIDGE_DIR` 字面量注入脚本头。
8. **子代理专用 API 模型**（按步路由最小形态）：`agentSubagentApiModelId` 设置 +
   智能体 tab 子代理卡下拉；非空且 ≠ 主模型才单独建 OpenAiAdapter。
9. **子代理后台化 + send_message 续轮**：`run_in_background` 立即返回 id，完成通知
   经 `injectNotice` 投父回合 + 🔔 消息落库（不入模型上下文）；可续轮表 FIFO 8 个
   （`kContinuableCapacity`），`send_message{id,message}` 续跑；subagent 描述对齐
   DSH（完整独立任务书/独立委派一条消息并发起/stopReason 非 completed 附注部分输出）。

**回归**：test/agent+providers+services+websearch 全绿 **487 项 + 4 skip**（新增
loop 6/todo 3/persona 3）；analyze 0 error。**未出包**——真机验收待下次构建。

**坑**：Future 没有 isComplete（用 `whenComplete` 置 flag 轮询）；try/catch 内
final 变量 await 后 catch 再赋值会报 "might already be assigned"（改非 final）；
测试桩太快时回合内插话要用工具执行体入队（不能靠 10ms 延时）。
- **2026-10-03 11:5x 最新构建（5fa142f：执行质量九件套）**：
  `E:\Work\DgxSpark\TongYi-Lite\build\app\outputs\flutter-apk\` —
  app-debug.apk 106726734 B（11:51）/ app-release.apk 59956994 B（11:52），
  v0.2.8+16 复用版本号。字符串级验收过：debug kernel UTF-8
  任务执行纪律5/收尾阶段4/用户插话6/系统通知9/智能体提问3/子代理专用模型3/
  run_code25/send_message16 全命中；release libapp.so UTF-16LE 任务执行纪律/
  智能体提问/插话发送/收尾阶段 + ASCII run_code/send_message/ask_user_question
  全命中。**双机覆盖安装 Success**（小米13 100.70.7.18 直连 + 8 Elite
  100.123.25.54；8 Elite 首次空报错失败、原样重试一次 Success，与此前
  DERP 中继传输截断行为一致）。九件套真机验收点：长任务撞步数上限自动收尾、
  生成中输入框插话、提问卡片、后台子代理通知、run_code（需 Chaquopy）。

## 2026-10-03 KV 占比细条「一直不行」根因：合并后 NDK up-to-date 跳过 → .so 陈旧

> **现象**：顶部状态栏本地模型上下文/KV 占比条自 f00cf65 合并进来后从不更新（恒 0）。

**根因链**：合并带来三层改动——JNI `nativeGetLastStats` 输出增加 `kv_used/kv_ctx`
→ Kotlin `getLastStats()` 透传 → Dart `_updateLocalContextUsage` 消费。Dart/JNI 源码
都在树里，但**重打包时 CMake/Ninja 判定目标 up-to-date（git checkout/merge 保留旧
mtime，早于上次构建产物）跳过 NDK 重编** → APK 里 `libtongyilite_jni.so` 还是旧版
（实测 zip 内 .so 搜 `kv_used` = 0）→ Dart 每次拿到的 stats JSON 缺这两个键 →
`_updateLocalContextUsage` 每次提前 return → 细条恒 0。

**修复**：`touch android/app/src/main/cpp/tongyilite_jni.cpp` 强制重编（12:32 重打
debug+release，.so 内 kv_used/kv_ctx 均 =1），双机覆盖安装 Success。

**教训（打包验收新增一道门）**：凡合并/checkout 带来 **native（cpp/CMake）改动**，
构建后必须字符串级验证 APK 内 `libtongyilite_jni.so` 含新增日志串/字段名——
gradle 的 up-to-date 判定信任 mtime，git 操作不保证 mtime 前进。此前「Dart 幽灵」
教训是 kernel/libapp，这是同一坑的 NDK 版。

## 2026-10-03 KV/上下文占比细条「一直不行」定案（两层根因，全链路实锤打通）

> 用户三报顶部状态栏上下文/KV 占比条从不更新。**两层根因叠加**，分别断在本地档与
> API 档的数据源上：

**根因 1（本地档，.so 陈旧）**：合并 f00cf65 带来 JNI `nativeGetLastStats` 的
kv_used/kv_ctx 输出，但 gradle CMake 任务 up-to-date 跳过（git merge 保留旧 mtime）
→ APK 里 `libtongyilite_jni.so` 还是旧版 → Dart 拿到的 stats JSON 缺这两个键 →
细条恒 0。修复 = touch cpp 强制重编（详见上节）。

**根因 2（API 档，usage 从未到达，本次新定位）**：用户实机配置 = API 档
（Bonsai2），细条走 `prompt_tokens/contextWindow` 分支。两层断点：
1. **请求体没带 `stream_options:{"include_usage":true}`** → 端点流式默认不回
   usage（Bonsai2 curl 实锤：不带=NO，带=YES prompt_tokens=57，带 tools 同样 OK）
   → `OpenAiService.lastUsage` 恒 null；
2. **`chatCompletionEvents` 对 usage 末块（choices:[] 的独立 chunk）直接
   continue**，从不 yield → assembler.usage 恒 null → LlmResult.usage null →
   会话日志 assistant 事件无 usage 键 → agent 档的占用更新永不触发。
   （assembler 的 `case 'usage'` 处理器早就写好了，只是事件源从来没喂过它。）

**修复（openai_service.dart + chat_provider.dart）**：
- `_sseDataPayloads` 请求体加 `stream_options:{"include_usage":true}`；严格端点
  400/404/422 且报错含 stream_options → 自动去掉重试一次（牺牲 usage 换可用）；
- SSE 行层抓到 usage 打 `[SSE] usage captured`（assert-only，release 不打）；
- `chatCompletionEvents` choices 空时若带 usage → yield `{'type':'usage',...}`；
- agent 档 usage 读取加 lastUsage 兜底（事件链缺失时用 service 层捕获值）。

**真机验证（小米13 USB，14:03）**：`[SSE] usage captured: prompt_tokens=12502` →
`[ChatNotifier] API usage: prompt=12502 window=180000` 全链路日志齐 → 细条显示
≈7%。回归 429+2 全绿，analyze 0 error。14:00/14:01 重打包
（debug 106724401 B / release 59955886 B），双机覆盖安装 Success。

**排障沉淀**：adb 驱动发送消息用「点输入框 → input text → keyevent 66（Enter）」
——发送 FAB 会随键盘弹起移位，硬编码坐标点不中；锁屏（secure keyguard）adb 解不开，
`wm dismiss-keyguard` 只对无凭据锁有效，需用户手动解锁。

## 2026-10-05 规划系统补全：task_create/task_list 工具 + 开发者 Tab「任务与规划」卡（工作区可选）

> 用户反馈："创建新规划的时候没法选择工作区"。定位发现三层缺口：① `plan_create` 要求
> task_id 已存在，但**全工程没有任何创建 DevTask 的途径**（无工具无 UI，只有测试手动造）
> → 真机建规划恒报「任务不存在」；② `DevTask.workspaceId` 从未被赋值，规划与工作区脱钩；
> ③ `DevSessionController.activeTaskId` 被 chat_provider 读去注入 DevContext 但没人写过（恒 null）。

**落地（全部未提交，待真机验收）**：
- **`task_create` 工具**（plan_tools.dart）：title 必填 + workspace_id 可选（省略=
  ToolExecutor 注入的 `_workspaceId` 当前激活工作区；显式指定会校验存在）+ steps 可选
  （一步建计划，状态直接 implementing），id=`task_<ms>`。`task_list`：列当前工作区任务
  （id/标题/状态/进度），默认工作区收编无主任务（workspaceId null/'default'）。
- **plan_create 自动建任务**：task_id 不存在时不再报错——自动创建（title 可选，缺省取
  第一步标题；workspace_id 可选，缺省=当前工作区），返回内容注明"已自动创建"。
- **kDevInstruction** 更新：第 2 步改为"没有任务先 task_create（可带 steps），已有用
  task_list 找回 task_id"。
- **开发者 Tab 新卡「📋 任务与规划」**（工作区卡与安全策略卡之间）：任务列表按激活
  工作区过滤（新更新的在前）、状态中文化（规划中/实施中/验证中/已完成/受阻）+ 步骤进度、
  「当前」徽标 = activeTaskId；点行设为当前任务（DevContext 注入其计划）；尾随删除带确认；
  **「新建规划」对话框 = 标题 + 工作区 ChoiceChip（默认当前激活工作区）**——用户要的
  "创建规划选工作区"就在这里；创建后自动设为当前任务。
- `_DevTabState` 监听器现在同时 `_reloadDevTasks()`（工作区切换会改过滤范围）；
  `dev.dart` 新导出 `newDevTaskId`/`taskBelongsToWorkspace`（UI 复用，单一真相）。
- **坑**：测试里 `'$tmp/empty-...'` 插值 Directory 对象会调 toString()（带
  `Directory: '...'` 前缀）→ 路径非法 errno 123，必须插 `tmp.path`。

**回归**：test/agent+services+providers+websearch 全绿 **495 项 + 4 skip**（plan_tools_test
新增 9 项：task_create 绑定注入工作区/无 steps planning/工作区校验、task_list 过滤三态+
进度、plan_create 自动建任务 title 缺省/绑定工作区/坏工作区报错）；analyze 0 error。
**2026-10-05 14:55 构建（工作区未提交，v0.2.8+16 复用）**：
  `E:\DTXY\TongYi-Lite\build\app\outputs\flutter-apk\` —
  app-debug.apk 140376769 B（14:53）/ app-release.apk 59949345 B（14:55）。
  字符串级验收过：debug kernel UTF-8 `新建规划`4/`任务与规划`3/`task_create`11；
  release libapp.so UTF-16LE `新建规划`1/`所属工作区`2 + ASCII `task_create`1/
  `taskBelongsToWorkspace`1；签名 CN=TongYiLite 核对过。设备未连未装，重连后
  `adb install -r -t`。


## 2026-10-05 智能体执行质量全面提升（对照主流差距分析 P0/P1/P2 全量施工，工作区未提交）

> 全面评估定案：循环骨架已对齐 DSH，真实差距在四层——质量度量（无 eval/遥测）、
> 长任务编排（无计划模式/goal 续跑）、上下文工程深水区（LLM 压缩/暖前缀）、
> 生态扩展（无 MCP）。本次全部落地。

**P0 质量度量（最被低估的差距）**：
- `lib/agent/metrics/turn_metrics.dart`：回合指标**纯派生自 SessionLog**（循环零侵入）
  ——steps/工具调用/同签名重复/渐进提醒/llm 重试/失败码/压缩次数/终止原因；
  `TurnMetricsStore` JSONL 追加落盘 `ApplicationSupport/metrics/turn_metrics.jsonl`
  + 内存 ring 聚合（aggregate）。chat_provider 每回合结束自动记录。
- `lib/agent/session/trace_export.dart`：SessionLog → JSONL（header+全事件），
  `writeTraceFile` 落 `ApplicationSupport/traces/trace_<conv>_<ts>.jsonl`；
  设置项 `agentTraceExportEnabled`（默认关，智能体 tab 上下文管理卡）开启后每回合落盘。
- `eval/` 基线评估：`eval/tasks.json` 12 个代表性任务（问答/搜索/todo/文件/计划模式/
  goal/技能/子代理…）+ `eval/scoring.dart` 纯 Dart 评分库（期望工具/禁用工具/
  终止原因/步数/重复上限/回答断言六维）+ `dart run eval/score_traces.dart <traces目录>`
  离线评分（轨迹匹配 = 首条 user 消息含任务 prompt 前 40 字）。

**P1-A 计划模式 + goal 无人值守续跑**：
- `/plan <任务>` 前缀（仅 API 档）= 只读规划回合：注册表收窄为「并行安全（只读）
  工具 + exit_plan」——复用 P2-A 的 isConcurrencySafe 声明做白名单；
  系统提示注入【计划模式】纪律段。
- `exit_plan` 工具：计划提交用户审批（走 ask_user 提问通道），**批准即落持久目标**
  （origin=plan）；批准判定精确匹配「批准执行」且排除「不批准」（踩坑：contains('批准')
  会误吞拒绝）。
- `lib/agent/goal/goal_store.dart`：GoalState 按会话持久化（`ApplicationSupport/
  goals/<conv>.json`，已终结读出即清）+ 纯决策函数 `decideGoalAction`；
  goal_set/goal_complete/goal_cancel 工具组（仅 API 档注册——端侧小模型自驱多回合
  收敛性差）。
- 驱动器：sendMessage 顶层**回合注销后** `_driveGoalIfNeeded`——上回合 completed
  且目标活跃 → bumpRound + 合成续跑 user 消息（可见落库）+ 递归 sendMessage
  （深度 = 剩余轮数）；失败/中断/等提问不续；轮耗尽 → 落 ℹ️ 提示终结。
  设置 `agentGoalMaxRounds`（1~20 默认 8，智能体 tab 滑条）。

**P1-B LLM 摘要压缩 + 按步模型路由**：
- `DeterministicCompaction` 新增 `llmSummarizer` 回调：旧区摘要交给便宜模型
  （≤300 字，提示词含任务诉求+触达工具+旧工具结果摘录头 400 字，总长 12k 截断，
  20s 超时）；**失败/超时/空回退确定性 digest，压缩永不因摘要模型失败**。
- 模型链（仅 API 档）：专用压缩模型 > 子代理模型 > 主模型；设置
  `agentCompressionApiModelId`（智能体 tab 下拉「压缩摘要专用模型」）。

**P1-C/D prompt-cache 双修**：
- **环境快照移出系统提示**：`environmentNoteProvider` 每 step 边界取一次，
  内容变化才以**尾部 user 消息**【环境】注入（追加不破前缀）；分钟按 10 分钟桶化
  ——时间快照从"每回合全段破缓存"降为"每 ≤10 分钟一次小追加"；local 档恒不注入
  （系统提示逐字节稳定保 KV）。旧 `environmentNote` 构造参数保留兼容（测试用）。
- **技能目录冻结**：SkillProvider.frozenDirectoryText——同一会话目录文本恒定
  （chat_provider 按 convId 缓存 FIFO 32），增删技能延迟到会话切换才进目录；
  load_skill 注册表仍实时（新增技能可按名拉取）。

**P2-A 并行工具安全（isConcurrencySafe 消费 + abort 占位）**：
- **语义翻转**：ToolDefinition 默认并行安全（只读可并发），副作用工具显式
  `isConcurrencySafe: (_) => false`——此前默认不安全导致并行功能名存实亡。
  20 个副作用工具已声明：export_file/write_file/edit_file/note_take/memory_set/
  todo_write/python_exec/run_code/shell_exec/git_commit/git_push/task_create/
  plan_create/plan_update/ssh_exec/ssh_write_file/run_tests/save_skill/subagent/
  ask_user_question。
- `_runCalls` 重写：非安全调用**独占一批**；回合中断时未完成调用合成占位结果
  （「结果未知，先核实」，与 closeOpenTurns 同语义），保证每个 tool/call 有配对
  tool/result。

**P2-C 子代理 fan-out**：`subagent` 工具新增 `tasks` 数组（2~4 个独立任务书，
一次全部后台并行启动，逐个完成通知）；task/tasks 二选一（schema required 移除，
执行体自行校验）。

**P2-B MCP 客户端**：`lib/agent/mcp/mcp_client.dart`——Streamable HTTP JSON-RPC 2.0
（initialize/session-id/tools/list/tools/call；响应 JSON 与 SSE 帧双形态解析）；
工具映射 `mcp_<server>_<名>`（非法字符净化防撞名）；仅 API 档注册，失败 server
静默跳过。设置 `mcpServers` + 智能体 tab「🔌 MCP 远程工具」卡（增删/开关）。

**P2-D Dev Agent 遗留四件**：
1. **工具逐组开关**：`devToolToggles`（git/ssh/sync/plan/task/verify 六组，缺省=开），
   _buildAgentRegistry 按 group unregister；开发者 tab 开发模式卡内开关组。
2. **远端 AGENTS.md**：`readRemoteAgentsMd`（SFTP 读工作区根 ≤64KB，失败静默
   降级）叠加本地 AGENTS.md 注入。ssh_tools 助手公有化（resolveRemoteRoot/
   ensureSshConnectionFor/toRemotePath）供复用。
3. **SSH 密钥安全存储**：`secret_store.dart`——SshSecretStore 抽象（生产
   flutter_secure_storage/测试 InMemory 可注入）+ `migrateSshSecrets`（settings
   加载时明文一次性搬走、幂等、存储不可用 fail-open 保留明文）+
   `resolveSshSecrets`（connect 前回填，配置自带密钥直通）。pubspec 新增
   flutter_secure_storage。
4. **workspace_sync 工具**（Phase D MVP）：本地镜像 ↔ 远端双向同步（SFTP
   listdir/stat/mkdir 全 SFTP 实现，不依赖 find -printf）；mtime 判新旧，冲突
   默认只报告（overwrite=true 强制覆盖），.git 恒跳过，单次 500 文件/64KB 上限；
   `SshEnvironmentService.openSftp` 新增。

**本地档精简**：subagent 门控到 API 档（`agentSubagentEnabled && useApi`）——
端侧小模型自驱多回合收敛性差，子代理 prefill 是净损失。

**回归**：test/agent+providers+services+websearch 全绿 **545 项 + 4 skip**
（新增 quality_infra 17 / goal 12 / fanout 3 / mcp_client 5 / dev_quality 7 /
eval_scoring 4）；analyze 0 error。**未出包**——真机验收点：指标 JSONL 落盘、
/plan→exit_plan→自动续跑、goal 续跑/轮耗尽提示、MCP 卡、Dev 工具开关、
workspace_sync 真机 SFTP 闭环。

**坑**：① Dart 字符串插值内嵌同类引号（`'${x.join('、')}'`）在部分解析路径报错，
统一预计算变量；② GoalState.fromJson 结尾写成 `});`（factory => 赋值）编译错；
③ evaluate 里 `answer.contains('批准')` 会把「不批准（…）」判成批准——审批类
匹配必须精确且先排除否定词；④ HttpServer 写 SSE 中文必须 ContentType charset
utf-8（默认 latin1 write 抛 invalid characters）。

- **2026-10-05 20:47 最新构建（工作区未提交，v0.2.8+16 复用：执行质量全面提升包）**：
  `E:\DTXY\TongYi-Liteuildpp\outputslutter-apk\` —
  app-debug.apk 140506631 B（20:43）/ app-release.apk 62854409 B（20:47，含
  flutter_secure_storage 依赖变大）。字符串级验收过：debug kernel UTF-8
  `workspace_sync`8/`agentGoalMaxRounds`15/`MCP 远程工具`3/`目标续跑`4/
  `回合轨迹落盘`2/`压缩摘要专用模型`3；release libapp.so UTF-16LE `目标续跑`2/
  `工作区同步`1/`MCP 远程工具`1 + ASCII `fetchMcpTools`/`mcpServers`/`turn_metrics`
  命中；dex 含 FlutterSecureStoragePlugin；签名 CN=TongYiLite 核对过。
  **release 已覆盖安装双机：小米13（100.70.7.18，Success，20:50:31）+ 8 Elite（100.123.25.54，Success，22:10:52）**。
  打包坑新增：Git Bash 的 cd 会跨调用保留——assemble/gradlew 前必须显式回项目根
  （上次 `cd android` 后跑 assemble 报 "lib/main.dart 找不到路径"）。


## 2026-10-05 消息输入区重构（标准智能体 composer 形态，P1+P2+P3 全量，工作区未提交）

> 用户反馈"消息输入框区域不太行，按标准智能体重构"。对照 ChatGPT/Claude/Gemini
> 移动端 composer 形态，home_screen 输入区整体重写。

**布局（自上而下）**：
1. **生成中状态细条** `_buildTurnStatusStrip`：「● 执行中 · N 个工具 · 当前工具名」
   （agentUiStateProvider 实时数据；普通聊天显示「生成中…」）+ 右侧「停止」文字按钮
   ——停止永远两处可达（主键位 + 细条）。
2. **composer 卡片**（圆角 24，surfaceContainerHigh）：附件 chips 行（图片 44px 缩略图 /
   文件名 chip，右上角 × 单个删除，替代原 108px 大缩略图行）→ TextField（无框，
   min 1 / max 6 行，hint 随状态）→ 底部动作行 [+] [模式 chips…] [主键]。
3. **主键位置语义复用**（单键四态，删掉双 FAB 并排）`_buildComposerKey` +
   `_roundKey`（40px 圆形实心，非 FAB）：
   空闲空=🎤（长按说话手势保留）/ 空闲有字=➤ 发送 / 生成中空=⏹ 停止 /
   生成中有字=➤ 插话。
4. **模式 chips 行**（11px 轻量 pill，`_composerChip`）：🤖智能体开关（点按
   setAgentEnabled）/ 🎭人格（点按底部弹层快速切换 setActivePersona）/ 📋计划
   （点按在输入框加/去 `/plan ` 前缀，激活高亮）/ 模型名（点按开模型状态弹层）。
5. **hint 状态化**：计划模式「计划模式：先规划后执行…」/ 生成中「插话给执行中的
   智能体…（不打断）」/ 空闲「输入消息…」。
6. **会话草稿**：`_drafts` Map，切换/新建/删除回落时 `_saveDraft/_restoreDraft`，
   发送成功即删——切会话回来打字还在。
7. **插话附件语义**：steer 只发文字；已选附件保留并 snackbar 提示"将随下一条
   消息发送"。附件选择不再因生成中禁用（可选好等下一条）。

**回归**：test/agent+providers 458+2 全绿；analyze 0 error。
**2026-10-05 23:56 重打包（v0.2.8+16 复用）**：app-debug.apk 140513668 B（23:55）/
app-release.apk 62853949 B（23:56）；字符串级验收过（debug kernel
`插话给执行中的智能体`/`切换人格`/`_buildComposerKey`/`_restoreDraft`/
`_buildTurnStatusStrip`；release libapp.so 对应 UTF-16LE/ASCII 命中）。
**release 双机覆盖安装 Success**（小米13 + 8 Elite）。


## 2026-10-06 输入区模式键图标化 + Termux 零粘贴自动执行（RUN_COMMAND，遗留清零）

> 用户反馈"模式 chips 图标+文字拥挤堆叠，用图标就行"——四枚模式键全部改纯图标
>（`_composerChip` 重写：32×30 圆角方，17px 图标，active 高亮 + Tooltip 承载语义）：
> 🤖智能体开关 / 🎭人格（自定义人格激活时图标高亮紫色）/ 📋计划 / 🧠模型。

**Termux 零粘贴（AGENTS.md 长期遗留项，本次清零）**：
- MainActivity app 通道新增 `runInTermux`：RUN_COMMAND intent
  （className=com.termux/.app.RunCommandService，PATH=termux sh，
  ARGUMENTS=["-c", command]，WORKDIR=$HOME，BACKGROUND=false →
  API≥26 用 startForegroundService）。
- AndroidManifest 新增 `<uses-permission android:name=
  "com.termux.permission.RUN_COMMAND" />`（二进制 manifest 已验证编入）。
- AppBridge.runInTermux(command, {background})；Termux 向导命令展示区新增
  **「自动执行」主按钮**（复制粘贴降级为兜底），下方小字说明一次性前置：
  `~/.termux/termux.properties` 写 `allow-external-apps=true` 后重启 Termux。
- 开启后向导全流程零粘贴：装 Termux → 点「自动执行」→ 读共享文件自动填用户名
  → 自动连接。

**回归**：test/agent+providers+services+websearch 全绿 **545 项 + 4 skip**；
analyze 0 error。
**2026-10-06 00:10 重打包（v0.2.8+16 复用）**：app-debug.apk 140515377 B /
app-release.apk 62855125 B；字符串级验收过（debug kernel `runInTermux`4/
`allow-external-apps`5；release libapp.so `runInTermux` ASCII + `已发送到
Termux` UTF-16LE 命中；manifest 含 RUN_COMMAND 权限 UTF-16LE 池命中）。
**release 双机覆盖安装 Success**（小米13 + 8 Elite，00:1x）。


## 2026-10-06 计划一等实体化 + 会话抽屉重构（用户纠偏：计划"生成后是什么、在哪看、怎么更新状态"全缺）

> 用户批评成立：计划 chip 此前只是 /plan 前缀插入器——批准后的计划存哪、
> 长什么样、步骤状态如何更新、用户在哪看，全部缺失（goal 只有一段文本）。

**P1 计划实体化（goal 升级为结构化计划，三处呈现）**：
- **数据模型**（goal_store.dart）：GoalState 新增 id/title/steps
  （PlanStep{title,detail,verify,status: pending/running/done/failed}），
  progressText()（续跑消息增量进度）与 planCardText()（对话内活卡文本）；
  GoalStore.updateStep（步骤状态推进，1-based）；旧 JSON（无新字段）兼容。
- **工具链**：exit_plan 新增 title + steps 数组参数（批准即生成结构化计划，
  无 steps 退化为纯文本目标）；新工具 **plan_step_update**（步骤状态推进，
  命名避开 Dev 档 plan_update——两者在"开发模式+API 档"注册表共存）；
  goal_set/complete/cancel 均触发计划卡重写。
- **驱动器进度消息**：续跑 user 消息从"目标全文重发"改为 progressText()
  增量进度（✓/◐/○/✗ + ← 本轮先做这步 + 验证方式），要求模型完成当前步
  立即 plan_step_update。
- **对话内活计划卡**：固定 id `plan_<convId>` 的 assistant 消息，saveMessage
  upsert 同 id——每次计划变化重写，对话流里永远一张最新计划卡（模型历史
  可见、UI 可回看，不刷屏）。
- **计划面板**（home_screen `_PlanPanelSheet`，计划 chip 点按弹出）：
  无计划 = 说明 + 「生成计划」（填 /plan 回输入框）；有计划 = 标题+状态徽标+
  目标+步骤列表（点步骤循环置状态 / 菜单指定 / 当前步高亮 / 完成划线）+
  已完成 N/M + 放弃计划 / 重新规划。chip 激活 = 输入带 /plan 前缀或存在
  活跃计划（`_hasActivePlan`，切会话刷新）。

**P2 会话抽屉重构**：
- 头部：**新建主按钮**（FilledButton）+ 批量选择；下方常驻**搜索框**（标题过滤）。
- **分组节**：置顶 / 今天 / 昨天 / 7 天内 / 更早（updatedAt 分桶）。
- **会话行**：最后一条消息**摘要行**（`StorageService.lastMessageSnippets()`
  一次批量 SQL，打开抽屉失效重取）替代"N 条"；**● 执行中**徽标
  （runningTurnsProvider，多会话并发可见化）；置顶 📌 / 当前会话活跃计划 📋。
- **行内 ⋯ 菜单**：置顶（settings.pinnedConversationIds，免 DB 迁移）/
  重命名（对话框 → updateConversation）/ 删除；长按进多选（原批量能力保留）。

**回归**：test/agent+providers+services+websearch 全绿 **547 项 + 4 skip**
（goal_test 新增：批准+steps 结构化落库、plan_step_update 推进/越界/坏状态/
无计划报错/全完成收尾、旧 JSON 兼容）；analyze 0 error。
**2026-10-06 00:41 重打包（v0.2.8+16 复用）**：app-debug.apk 140547742 B /
app-release.apk 62893461 B；字符串级验收过（debug kernel `plan_step_update`11/
`_PlanPanelSheet`9/`置为执行中`/`放弃计划`/`pinnedConversationIds`14；
release libapp.so 对应 ASCII/UTF-16LE 命中）。**release 双机覆盖安装 Success**
（小米13 + 8 Elite，00:4x）。

**坑**：Python 脚本经 JSON 传参时 `
` 会被解码成真实换行——改写含转义序列的
Dart 字符串必须用 chr(92)+'n' 构造或 Write 工具落片段文件再拼接（Dart 三引号
''' 还会与 Python 三引号冲突）。


## 2026-10-06 语音接入重做：sherpa-onnx 端侧流式 ASR（自 DSH-Phone 搬迁），放弃 LLM 音频方案

> 用户指令：参考 DSH-Phone 实现语音接入，放弃「录音文件喂大模型」的 LLM 语音方案
> （旧方案要求 Gemma 4 E2B 带 mmproj 音频编码器的模型，覆盖面窄且慢）。

**方案（对照 DSH-Phone `lib/asr/`，整体搬迁解耦）**：
- 引擎 = sherpa-onnx 流式 Zipformer 中文 int8（`sherpa-onnx-streaming-zipformer-*
  zh-int8-2025-06-30`，~160MB），FFI 进程内推理，**完全离线零网络依赖**。
- 交互 = 微信式按住说话：长按 🎤 → 浮层「准备中」→ 引擎就绪实时回显 partial →
  上滑取消（>70px）→ 松手终稿**直接发送**（附加输入框已有文字）。
- 模型不入 APK：首次长按触发 `AsrModelGate.ensureModelReady` 下载对话框
  （hf-mirror 主源 + huggingface 兜底，background_downloader 断点续传），
  落 `<documents>/models/asr/<modelId>/` 四文件。`main.dart` 启动 warmup 预读页缓存。
- 热词：MVP 固定全部内置分类（200+ AI 术语，ContextGraph 偏置 + lpinyin 同音
  后校正）；档位固定 standard。`lib/asr/asr_settings.dart` 替代 DSH 的 SSHConfig
  配置面（后续可调时换 SharedPreferences 存取即可）。

**改动**：`lib/asr/` 七文件（6 个 DSH 原文件 + asr_settings.dart 解耦层）；
pubspec 加 sherpa_onnx/record/background_downloader 8.9.5/lpinyin；main.dart 预热；
home_screen 长按说话接 HoldToTalkSession + **删除旧录音路线全部代码**
（_startRecording/_stopRecording/_recordingNotifier/波形动画横幅/
_sendMessage audioPath 参数；旧语音消息渲染保留供历史回看）。

**打包坑（重要）**：background_downloader 是源码模块，其
`kotlin-serialization` 插件跟随**项目 Kotlin 版本**解析 compiler plugin——
项目钉 1.8.22 时请求 `kotlin-serialization-compiler-plugin-embeddable:1.8.22`，
该构件在 Maven Central **不存在**（1.8.22 serialization 插件未发布，404 实锤），
构建报 Could not find。修复 = Kotlin 1.8.22 → **1.9.22**（settings.gradle.kts，
对齐 DSH-Phone 同款插件集的已验证版本），Kotlin 全量重编 2m41s 过。
gradle daemon 偶发"产物 up-to-date 但内容陈旧"——删 APK 产物强制重跑。

**回归**：test/agent+providers+services+websearch 全绿 **547 项 + 4 skip**；
analyze 0 error。
**2026-10-06 01:13 重打包（v0.2.8+16 复用）**：app-debug.apk 124220922 B /
app-release.apk 81389944 B（release +18MB = sherpa/onnxruntime 原生库）；
字符串级验收过（debug kernel `HoldToTalkSession`7/`AsrModelGate`5/
`按住说话（端侧语音识别`2；release libapp.so 对应命中；APK 内
libsherpa-onnx-{c,cxx}-api.so + libonnxruntime.so 在）。**release 双机覆盖
安装 Success**（小米13 + 8 Elite，01:1x）。
真机验收点：首次长按说话弹模型下载（160MB 断点续传）→ 识别实时回显 →
松手直接发出文字消息；飞行模式下识别可用（纯端侧证明）。


## 2026-10-06 语音两连修：①Tooltip 抢长按手势（"按了没效果"根因）②语音设置卡补齐

**① "长按没效果"根因（adb 远程复现实锤）**：composer 主键 `_roundKey` 外包的
**Tooltip 默认带长按手势识别器**（显示气泡用），在手势竞技场里赢过外层
GestureDetector 的长按——长按 🎤 只弹 tooltip 气泡，语音处理从不触发。
修复 = `_roundKey` tooltip 传 null 时**条件包裹**（不建 Tooltip 实例）；
麦克风键提示改由单击 SnackBar 承担（同时作为新包自证：单击弹
「按住 🎤 说话，松手即发送」= 新代码生效）。诊断过程沉淀：uiautomator dump
抓 Flutter 语义树定位 composer 键坐标（mic ≈ (976,2263)），单击后 dump 内可见
SnackBar 文本；logcat 无 [Voice] 日志 = 长按未进处理器。

**② 语音设置卡（用户要求：热词等配置进设置页）**——智能体 tab 新卡
「🎙️ 语音输入（端侧识别）」：
- 增强识别模式 toggle（asrEnhancedMode：beam search + blankPenalty，默认标准档）；
- 热词分类 FilterChips（`asrHotwordCategories`，空 = 全部启用；首次取消某分类
  时自动把其余分类写入启用集）；
- 自定义热词（`asrHotwordCustom` 多行编辑，每行一个词，词表外同音后校正）；
- 模型管理行：就绪状态（FutureBuilder）+ 下载（AsrModelGate 复用向导对话框）/
  删除（AsrModelManager.deleteModel，释放 160MB）。
- `asr_settings.dart` 从固定值改为读 InferenceSettings（每次长按读本地 JSON，
  毫秒级）；新字段全链路（service/provider/卡片）。

**回归**：547 项 + 4 skip 全绿；analyze 0 error。
**2026-10-06 07:24 重打包（v0.2.8+16 复用）**：app-debug.apk 146484511 B /
app-release.apk 81393088 B；字符串级验收过（语音卡文案双包命中）；
**release 双机覆盖安装 Success**。真机验收点：①单击 🎤 出提示（新版自证）；
②长按弹下载/浮层回显（Tooltip 修复生效）；③设置页语音卡改热词/档位后
下次长按生效。


## 2026-10-06 语音"说话无转写"根因：识别器每会话双载 ~9.5s（final=0 实锤）

> 现象：模型已下载、长按弹监听浮层、但松手 final=0 字。后台 logcat 全程
> 捕获实锤：`recognizer loaded (greedy) 4.8s` → `recognizer loaded (hotwords)
> 4.8s` → `session start` → 用户在「准备中」等 9.5s 后松手 → held 仅
> 186ms~1.7s → `session stop, final=0 chars`。

**根因**：`create()` 按签名 'greedy' 预载（入参不含热词信息），`start()` 又因
热词签名 'hotwords' 不一致**重载一遍**——每个会话双载 ~9.5s，且热词默认启用
使该问题每会话必现（DSH 原实现无此症状，因其档位/热词多走 greedy）。

**修复**：`create()` 不再加载（注释写明双载根因），加载统一收口到 `start()`
按最终形态（enhanced+热词）做一次，签名幂等 → 后续会话瞬时启动；新增诊断
日志：`first pcm chunk: N bytes @Tms`（确认麦克风真在出数据）与
`session stop, final=N chars, held=Tms`（区分「没说话」vs「没音频」）。

**2026-10-06 07:34 重打包双机 Success**。真机验收点：第一次长按「准备中」
~5s（单载）→ 说话 3 秒+ 松手应出文字；第二次长按应瞬时开始（无准备中）。
若 first pcm chunk 日志出现但 final=0 且 held>3s → 麦克风数据为静音，
查 MIUI 麦克风权限/占用；连 first chunk 都没有 → record 流没起来。


## 2026-10-06 热词分类改版：Agent 智能体开发 + 端侧智能助手（用户指令）

> 用户指令：热词改为 agent 智能体开发、端侧智能助手相关分类。原 DSH 搬来的
> 10 类通用 AI 术语（机器学习/CV/NLP 等）与本项目场景不匹配，整体重写。

**新分类（5 类，全部中文词）**：
- `agent` 智能体/Agent 开发（38 词）：子代理/工具调用/计划模式/无人值守/
  上下文压缩/智能体提问/失败重试/扇出/目标续跑…
- `edge` 端侧推理/本地模型（40 词）：端侧推理/键值缓存/预填充/量化/层数卸载/
  实时转写/静音断句/离线识别…
- `app` 本项目/常用产品名（24 词）：彤 Yi/搜索聚合/并发搜索/覆盖安装/会话列表…
- `dev` 开发调试/打包验收（28 词）：真机调试/全量回归/字符串验收/热重载…
- `daily` 日常交互指令（30 词）：帮我/继续/重新规划/放弃计划…

**陈旧 id 兜底**：分类表改版后旧配置存的 id 可能全部失效（交集为空 → 热词
整体静默失效）——loadHotwords 过滤有效 id，交集为空但配置非空时按"全部启用"
处理。

**回归**：460+2 全绿（agent+providers）；analyze 0 error。
**2026-10-06 07:46 重打包双机 Success**（debug 146480488 B / release
81394644 B）。

## 2026-10-04 Dev Agent 执行环境三级升级（内嵌沙箱 L0/L1 + Termux 免 SSH L2，工作区未提交）

> 用户需求："一步到位，施工"——按 `docs/termux_integration_plan_2026-10-04.md` 全量落地。
> 核心结论：targetSdk 34 W^X 限制下**不能整包内嵌 Termux bootstrap**（app 数据目录不可 exec），
> 走三级：L0 系统工具链用满 → L1 内嵌沙箱（jniLibs + JGit 进程内 git，零 exec）→
> L2 Termux 伴侣应用（RUN_COMMAND intent 免 SSH，PerSourcePenalties 死穴整体退役）。

**L1 内嵌沙箱（embedded 后端）**：
- `WorkspaceBackend` 新增 `embedded`（本地执行、无 SSH、文件即本地镜像目录）+
  `isRemoteBackend` getter（枚举成员**必须在常量列表后加分号**，否则 analyzer 把 getter 当 static）。
- 新工具 **dev_shell**（`lib/agent/dev/tools/embedded_tools.dart`）：cwd 锚定工作区根
  （`devShellRoot`：default → documents/workspace，其他 → projects/<id>），
  **PATH 前插 nativeLibraryDir**（jniLibs 的 lib*.so 是 targetSdk 34 下唯一可 exec 白名单位置）；
  dangerFullAccess 批准后跳过黑名单。`executeDevShell` 为 dev_shell/run_tests 共享执行核心。
- **git 全走 JGit**（`lib/agent/dev/tools/embedded_git.dart` ↔ Kotlin `DevGitPlugin.kt`，
  通道 `com.dgxspark.tongyilite/devgit`）：status/diff/log/commit/push/clone 进程内完成，
  ssh:// 远端明确报错引导切 Termux/远程。git_tools 按后端分派：本地 → LocalGit，
  远端（termux/remotePc）→ SSH 原路径。新增 git_clone 工具（仅本地，https+token）。
- gradle 依赖 `org.eclipse.jgit:6.10.0.202406032230-r`（**版本号别再写错**：202406032230，
  aliyun 镜像无 JGit，走 repo.maven.apache.org）。

**L2 Termux 免 SSH 通道（RUN_COMMAND intent）**：
- 通道 `com.dgxspark.tongyilite/devenv`（`native_env.dart` + MainActivity）：
  nativeInfo / runTermux / canRequestInstall / installApk / downloadTermuxApk（DownloadManager）。
- `termux_intent.dart`：命令包装 `{ cmd ; } > 交换文件 2>&1; echo EXIT; echo DONE`，
  交换文件 = Termux 自己的外部目录 `/sdcard/Android/data/com.termux/files/tongyilite_out/<id>.out`
  （Termux 无需存储权限可写自家目录；本 app MANAGE_EXTERNAL_STORAGE 可直读），Dart 300ms 轮询
  `__TYL_DONE__` 标记；读文件走 base64 免换行截断，写文件 base64 塞命令行（单次 ≤64KB）。
- **ssh_tools 全工具 intent 优先**：termux 后端先走 `TermuxIntentService`，只有
  "Termux 通道不可用"（未装/未开 allow-external-apps）才回落 SSH；**命令超时不回落**
  （命令可能已执行，重复执行有副作用）。git_tools/run_tests 同样分派。
- manifest 新增 `com.termux.permission.RUN_COMMAND` + `REQUEST_INSTALL_PACKAGES`；
  Termux 侧仍需一次性配置 `allow-external-apps=true`（向导命令已带）。
- 设置页 DevTab：免 SSH 通道测试按钮 + 「下载 Termux」（DownloadManager →
  Download/TongYi-Lite/termux.apk → 轮询到位后 FileProvider 拉安装器）。

**L0 / 全通道**：
- kDevToolNames 新增 dev_shell/git_clone（开发模式即注册）；run_tests 本地分派到内嵌沙箱；
  safety 黑名单覆盖 dev_shell 与本地 run_tests（shell_exec 主线未动）。
- `DevStore.testDefault`（测试注入收口）：工具层无注入点的 `DevStore()` 一律改
  `DevStore.resolve()`，workspaceLocalMirror/defaultWorkspaceDir 在 override 下不触 path_provider。

**回归**：`test/agent/dev_embedded_test.dart` 新增 18 项（枚举序列化/wrapper/解析/intent 注入桩/
dev_shell 黑名单+PATH+cwd/git 分派/远端不触 JGit/DevContext）；全量 test/agent+services+
providers **447+2 skip**、test/websearch **58+2 skip** 全绿；analyze 0 error。

**APK（v0.2.8+16 复用版本号，2026-10-04 21:1x）**：app-debug.apk 118071859 B /
app-release.apk 62585127 B（JGit 使包体 +~3MB release）。验收：debug kernel UTF-8
dev_shell 15/git_clone 8/内嵌工具沙箱 5；release libapp.so UTF-16LE 内嵌工具沙箱 2 +
ASCII dev_shell/git_clone/TermuxIntentService；dex 含 DevGitPlugin（release 5 处）+
org.eclipse.jgit 类引用 2196；manifest（AXML UTF-16LE 串池）RUN_COMMAND/REQUEST_INSTALL
各 1；apksigner 签名 CN=TongYiLite SHA-256 与备忘指纹一致。**设备未连未装**，重连后
`adb install -r -t`。

**遗留（真机验收点）**：① Termux RUN_COMMAND 全链路（echo → 文件交换 → 工具结果）；
② JGit clone/commit/push GitHub https+token；③ embedded 工作区 dev_shell 智能体整回合；
④ 下载 Termux → 安装 → 配置 → intent 通道可用 的全自动流；⑤ 预编译 aarch64 工具
（busybox/rg/jq）无可靠静态源，**待 NDK 自编**后放 jniLibs/lib*.so 即点亮（PATH 探测已在）。

**busybox 32 位问题已解决（2026-10-04 21:5x，同日追加）**：busybox.net 预编译只有
armv8l（32 位），但 **DGX 服务器（ssh 别名 sync-DgxSpark，主机 gx10-85f3）本身是
ARM 机器**（aarch64-linux-gnu-gcc 已装好）——`~/busybox-build/bb` 里
`make defconfig` + `CONFIG_STATIC=y` + 关 `CONFIG_TC`（新内核头删了 CBQ，tc applet
必炸）+ `FEATURE_UTMP/WTMP` 关，`make -j16 CROSS_COMPILE=aarch64-linux-gnu-` 产出
**aarch64 全静态 2.15MB**，且服务器原生试跑 `echo hi` 通过。已改名
`libbusybox.so` 放 `android/app/src/main/jniLibs/arm64-v8a/`（非 PIE 静态 e_type=2，
Android 无动态链接器依赖），双 APK 重打验收：debug 118071932 B / release
63782732 B，APK 内 libbusybox.so ELF64-ARM64 + BusyBox v1.36.1 串命中，签名
CN=TongYiLite 不变。**dev_shell 的 PATH 已前插 nativeLibraryDir，装机即点亮
busybox 全量 applet**（ripgrep/jq 如需，同样路子服务器上编译）。

## 2026-10-04 免 SSH 通道真机全链路打通（四坑定案，两机验收过）

> 晚间真机验收把 RUN_COMMAND 免 SSH 通道跑通（小米13 USB + 8 Elite Tailscale），
> 途中抓到三个设计 bug + 一个权限坑，全部修复并重打包装机。**用户确认"提示成功"**。

**坑 1：wrapper 没建输出目录**。buildTermuxWrapper 最初 `> 文件` 但从不 mkdir
→ 首跑必失败且无任何报错痕迹。修复：wrapper 开头 `mkdir -p '<outDir>';`（自愈）。

**坑 2（架构级）：交换目录不能放 `/sdcard/Android/data/com.termux`**。那是 Termux
的私有外部目录——Termux 能写，但本 app 读不到：**MANAGE_EXTERNAL_STORAGE 不覆盖
其他应用的 Android/data**（Android 11+ 硬规则，All-Files-Access 也不行）。症状 =
intent 发了、Termux 执行了、文件也在（shell 可见），app 却永远超时。修复：交换目录
改 `/sdcard/TongYiLite/termux_out`（app 有 All-Files-Access 可读；Termux 需存储权限，
向导 v3 已引导 termux-setup-storage）。

**坑 3：RUN_COMMAND 在 Termux 0.118.3+ 是 dangerous 权限**（不再是 normal）——
manifest 声明不够，必须运行时 `pm grant com.dgxspark.tongyilite
com.termux.permission.RUN_COMMAND`。真机日志铁证：`Permission Denial: ... requires
com.termux.permission.RUN_COMMAND`。App 内暂无自动请求 UI，装机后需 adb 授一次或
后续加运行时请求。

**坑 4：全新安装的 app 缺 All-Files-Access**。小米13 全新装后 MANAGE_EXTERNAL_STORAGE
appops=default → 读 /sdcard/TongYiLite 被拒（MediaProvider SecurityException）。
`appops set <pkg> MANAGE_EXTERNAL_STORAGE allow` 授予后立通。

**免 SSH 通道真机验收（两机全过）**：App 内点「免 SSH 通道测试」→ RUN_COMMAND
intent → Termux sh 执行 `echo ok` → 交换文件出现 `ok / __TYL_EXIT__=0 / __TYL_DONE__`
→ App 读回显示「免 SSH 通道可用」。为让结果可持久查看，测试结果改为页面内
「上次测试：…」常驻显示（SnackBar 4s 即逝，真机 uiautomator 抓不到）。

**Termux 侧配置（已自动化验证的路径）**：向导一键命令升级 v3——追加写
`allow-external-apps=true` + `termux-reload-settings`；本机实测用 adb 往 Termux
终端 `input text`（空格用 %s）注入命令链即可全自动 provision，无需手打。

**注意**：uiautomator dump 会返回陈旧缓存（同字节数反复出现），据此判断"点击没生效"
不可靠——以 logcat（TongYiLite [handleRunTermux]）和文件系统证据为准。

**装机包（23:2x final）**：app-release.apk 6378xxxx B（含 mkdir 修复 + 交换目录
/sdcard/TongYiLite + 上次测试常驻行 + 向导 v3），双机 `install -r -t` Success；
小米13 额外执行了 pm grant + appops allow 两步授权。
