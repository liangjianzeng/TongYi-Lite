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
