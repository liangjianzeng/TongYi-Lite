# Termux 集成实现方案 —— Dev Agent 端侧执行环境升级（2026-10-04）

> 目标：当前 Dev Agent 的 Termux 后端要求用户**自己安装 Termux + 配 sshd + 管密钥**，
> 且受 OpenSSH PerSourcePenalties 惩罚机制反复卡死（AGENTS.md 2026-10-01 两轮定案）。
> 本方案让智能体在手机本地获得"更大的发挥空间"：**内嵌工具沙箱（零外部依赖）**
> 打底 + **Termux 伴侣应用（免 SSH、自动装配）**扩展，分三级落地。
>
> 结论先行：**不整包内嵌 Termux bootstrap**（targetSdk 34 的 W^X 限制使其只有
> jniLibs 白名单位置可执行，apt/dpkg 世界装不进来）；改为
> **Level 0 用满系统工具链 → Level 1 内嵌沙箱（jniLibs + JGit）→ Level 2 Termux
> 伴侣（RUN_COMMAND intent 免 SSH）**。Level 1 是核心增量，Level 2 是能力天花板。

---

## 1. 现状盘点（已有资产）

| 资产 | 位置 | 状态 |
|---|---|---|
| `shell_exec` 工具 | `lib/agent/builtin_tools/shell_tool.dart` | 已有，`dart:io Process.start('sh','-c')`，**解析到 /system/bin/sh（mksh）+ toybox applet**，app 权限内直接可用 |
| Python 运行时 | Chaquopy（`python_tool.dart` + `run_code_tool.dart`） | 已有，嵌入式 CPython，app 沙盒内 exec 脚本 |
| Dev 工作区模型 | `lib/agent/dev/workspace.dart` | 已有，`WorkspaceBackend { localApp, termux, remotePc }`，`remotePath`/`sshConfigId` |
| SSH 工具链 | `lib/agent/dev/ssh/` + `dev/tools/{ssh,git,plan,verify}_tools.dart` | 已有，dartssh2 fork，ensureConnected/断线重连/[SSH] 错误前缀 |
| 危险命令策略 | `lib/agent/dev/safety.dart` | 已有，deny/ask 黑名单 |
| Termux 应用桥 | `lib/services/app_bridge.dart` | 已有，isAppInstalled / launchApp |
| 沙箱审批 | `lib/agent/sandbox.dart`（`sandbox_permissions`） | 已有，workspace-write / danger-full-access |

**痛点（用户原话级）**：Termux 后端 = 用户装 Termux → 跑一键命令 → 管 sshd →
被 PerSourcePenalties 拉黑（越试越死）→ SSH 环回链路延迟/瞬断。每一次配置
失败都是用户流失点；且 ssh_exec 每步 15-30s 超时预算，智能体节奏被拖垮。

## 2. 关键技术约束（决定方案走向的三条铁律）

### 2.1 W^X：targetSdk 34 下 app 不能 exec 数据目录里的任何 ELF

Android 10 起，targetSdk≥29 的应用对 `files/`、`code_cache/` 等**可写目录里的
二进制 execve 一律 EACCES**（SELinux `untrusted_app_29` 域，Google 官方 W^X
策略，[官方行为变更文档](https://developer.android.com/about/versions/10/behavior-changes-10)、
[termux-app#1072](https://github.com/termux/termux-app/issues/1072)）。

- **Termux 本体为什么能跑**：它 targetSdk 28（老域放行）。我们 targetSdk 34
  （compileSdk 36 / minSdk 33，Chaquopy + 现代 scoped storage 依赖），**降级
  targetSdk 不可行**——直接排除"把 Termux bootstrap 解压到我们 files/ 下跑"这条路。
- **唯一的合法 exec 白名单位置**：`nativeLibraryDir`
  （`/data/app/<pkg>/lib/arm64/`，只读+可执行）。把 ELF 以 `lib<name>.so` 命名
  放进 APK 的 `jniLibs/arm64-v8a/`，安装时被抽取到该目录即可 exec
  （社区标准打法，[StackOverflow 定案](https://stackoverflow.com/questions/63800440/android-cant-execute-process-for-android-api-29-android-10-from-lib-arch)）。
  **前提**：`useLegacyPackaging = true`（gradle jniLibs）/ `extractNativeLibs=true`
  （manifest）——否则 .so 不落盘、直接从 APK mmap，nativeLibraryDir 是空的。
- 对我们的含义：**内嵌工具集只能是"APK 里带了什么就有什么"**，编译期固定；
  运行时扩展（apt 装新包）物理不可行。

### 2.2 /system 工具链是免费的：mksh + toybox 已在设备上

Android 13+ 系统自带 `/system/bin/sh`（mksh）+ `/system/bin/toybox`（ls/cp/mv/
grep/sed/awk/find/tar/gzip/diff/vi/wget 等 150+ applet）。app 无需任何权限即可
ProcessBuilder 执行——**现有 shell_exec 工具今天就能用**，缺的只是：
① 工具未随 Dev 模式默认挂载；② 没有 git；③ 没有让模型知道"能干什么"的
环境说明。这是 Level 0 的全部内容。

### 2.3 Termux 的官方外部集成面：RUN_COMMAND intent（免 SSH）

Termux 官方支持外部 App 以 intent 直接在其环境内执行命令
（[RUN_COMMAND Intent wiki](https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent)）：

- 调用方声明 `com.termux.permission.RUN_COMMAND`（normal 级权限，manifest 声明即得）；
- intent → `com.termux/.app.RunCommandService`，extras：
  `RUN_COMMAND_PATH`（$PREFIX/bin 下可执行文件）、`RUN_COMMAND_ARGUMENTS`、
  `RUN_COMMAND_WORKDIR`、`RUN_COMMAND_BACKGROUND=true`；
- **结果回调**：传 `RUN_COMMAND_PENDINGINTENT` extra，命令结束（含退出码/错误）
  通过 PendingIntent 回传（Termux:Tasker 同机制）；
- **一次性前置**：`~/.termux/termux.properties` 里 `allow-external-apps=true`
  （默认关，安全开关）。

对我们的含义：**SSH 链路（端口探测/密钥/PerSourcePenalties/banner 超时）整体
退役**，替换为"intent 进、PendingIntent 出"的进程间调用，无需网络、无需密钥、
无拉黑问题。文件交换走共享存储（app 已有 MANAGE_EXTERNAL_STORAGE，
Termux 也有 → `/sdcard/TongYiLite/` 双向可达）。

## 3. 方案选型对比

| 方案 | 说明 | 判定 |
|---|---|---|
| A. 维持现状（外挂 Termux + SSH） | 已建成，但配置体验差、PerSourcePenalties 死穴 | 保留为兼容，不再投入 |
| B. 整包内嵌 Termux bootstrap | bootstrap-aarch64.zip 解压到 app files/ 跑 | **否决**：W^X 下数据目录不可 exec（§2.1）；即使全量 jniLibs 化（数百个二进制改名 lib*.so、APK +80~150MB），apt/dpkg 仍要 exec 数据目录内的包文件，装不进生态，得不偿失 |
| C. 分层集成（推荐） | Level 0 系统工具链用满 → Level 1 内嵌沙箱（jniLibs 白名单位置 + JGit）→ Level 2 Termux 伴侣（RUN_COMMAND） | **采纳**。Level 1 零外部依赖覆盖 80% 开发任务；Level 2 用官方 intent 面接通完整 apt 生态，同时把 SSH 死穴整体移除 |

## 4. Level 0 —— 用满系统工具链（1~2 天，立即可用）

**内容**：不改任何原生代码，纯 Dart/提示词/注册层。

1. **Dev 模式默认挂载本地 `shell_exec`**：现有 `createShellExecTool()` 目前
   按设置门控；Dev 模式开启时与 ssh 工具同批注册，工作区为 `localApp` 后端。
2. **环境说明注入 DevContext**：`dev_context.dart` 追加一段【本机执行环境】
   ——告知模型可用命令集（mksh/toybox applet 清单要点：文件/文本/压缩/查找）、
   有 Python（Chaquopy，`python_exec`）、无 git/包管理器（引导用 write/read_file
   代替；git 由 Level 1 JGit 补）、工作区根目录绝对路径。
3. **toybox applet 自检**：首次开启 Dev 模式时执行一次 `toybox 2>&1 | head -5`
   + `sh -c 'echo $HOSTTYPE'`，结果落 `DevStore`，设置页"环境自检"行显示
   （设备差异提前暴露，防模型幻觉有工具）。
4. **safety 黑名单对本地 shell 生效**：`shell_exec` 走 `lib/agent/dev/safety.dart`
   同一份 deny/ask 策略（现在只挂在 ssh_exec 上）；`rm -rf /`、`dd`、`mkfs`、
   `pm clear` 等本地同样拦截。

**验收门**：test/agent 新增 dev_tools 注册用例（Dev 开 → shell_exec 在注册表且
带 safety 包装）；真机 uiautomator/文本通道跑一轮"智能体在默认工作区建
hello.sh → shell_exec 执行 → 读回输出"。

## 5. Level 1 —— 内嵌工具沙箱（核心增量，~1 周）

### 5.1 架构

```
DevWorkspace.backend 新增枚举 embedded（后端四态）
  ├─ shell_exec   → Process.start(nativeLibraryDir/libbusybox.so …) 逐级回落 /system/bin/sh
  ├─ git_*        → JGit（进程内 Java 库，零 exec）
  ├─ python_exec  → Chaquopy（已有）
  └─ read/write/edit_file → 已有本地文件工具，路径锚定工作区根
```

新后端 `embedded` 与 `localApp` 的区别：`localApp` 是"app 沙盒文件 + 系统命令"，
`embedded` 是**专职开发沙箱**：独立根目录 `files/dev/home/`、预设 PATH 指向
nativeLibraryDir、带 busybox 补齐系统 toybox 缺的 applet、git 全功能。

### 5.2 jniLibs 工具集（编译期固定，精选 3+1 个）

| 二进制 | 来源/许可 | 作用 | 体积 |
|---|---|---|---|
| `libbusybox.so` | busybox 静态 aarch64（GPLv2）或 toybox 重编（BSD-2，优先试） | 补齐 sh/sed/awk/grep/find/tar/curl/wget 等，脚本执行环境兜底 | ~1MB |
| `librg.so`（ripgrep） | MIT | 代码检索，比 toybox grep 快且 rag 友好 | ~2MB |
| `libjq.so`（jq） | MIT/ISC | JSON 处理（配 web_search/run_code 输出加工） | ~200KB |
| （可选）`libnode.so` | MIT，~25MB | 后置再议，非必需 | — |

**打包要点（一次配好，写死在 gradle）**：
```kotlin
// android/app/build.gradle.kts
packaging { jniLibs { useLegacyPackaging = true } }  // 必须落盘，否则 nativeLibraryDir 为空
```
- ⚠️ 全局开关：现有 llama.cpp 全家桶 .so 也会变为解压安装，**安装后占用 +
  约等于 .so 未压缩体积**（debug 包本就 140MB，可接受；release 需复测体积）。
- 二进制必须 PIE ELF + `lib` 前缀 + `.so` 后缀，用 NDK `aarch64-linux-android*-clang`
  或直接采用上游发布的静态产物（验证 `-fPIE -pie`）。
- 启动期自检：MainActivity/DevController 首次进入 embedded 后端时
  `nativeLibraryDir` 下逐个探测文件存在 + `Process.start` 干跑一次，缺失项在
  DevContext 环境段如实声明（延续"如实报告铁律"，防模型幻觉）。

### 5.3 git = JGit（进程内，不走 exec）

- 引入 `org.eclipse.jgit`（EDL/BSD 许可，Android 兼容，MGit 等应用验证过），
  APK +~5MB。
- `git_tools.dart` 的四个工具（status/diff/log/commit/push）改为**按后端分派**：
  `termux/remotePc` 走 SSH（现状不动），`embedded/localApp` 走 JGit——
  clone/fetch/commit/push/status/diff 全部进程内完成，https + token 认证，
  不需要 git 二进制、不需要 exec 任何东西。
- push 审批复用现有机制；凭据存 `SshConfig` 同级的 `GitCredential`（apiModels
  明文先例，secure storage 迁移一并后置）。
- ssh:// 远端（Level 1 不做，标记 not supported；Level 2 里由 Termux 侧 git 兜底）。

### 5.4 工具层改动清单

| 文件 | 改动 |
|---|---|
| `lib/agent/dev/workspace.dart` | `WorkspaceBackend.embedded` 枚举 + 序列化兼容（旧 JSON 无此值，默认 localApp）+ `isRemote=false` |
| `lib/agent/dev/workspace_store.dart` | 无结构变更，仅注释/校验放行新枚举 |
| `lib/agent/dev/tools/shell_tools.dart`（新增） | `createEmbeddedShellTool()`：工作区根 = cwd、`PATH=nativeLibraryDir:/system/bin:/system/xbin`、超时/截断复用 `kShellOutputLimit` 语义、safety 包装、`sandbox_permissions` 升级字段对齐 shell_tool |
| `lib/agent/dev/tools/git_tools.dart` | 按后端分派：embedded → `embedded_git.dart`（JGit 封装，`org.eclipse.jgit` via MethodChannel 或纯 Dart 绑定？——**定案：走 MethodChannel `com.dgxspark.tongyilite/devgit`**，Kotlin 侧持 JGit 对象，Dart 传 JSON 指令；避免 Dart 侧找 JGit 绑定（无维护良好的 Dart JGit），Kotlin 侧调用是官方一等公民） |
| `lib/agent/dev/dev_context.dart` | 环境段按后端生成：embedded 描述 busybox/rg/jq/JGit/Chaquopy 能力边界 |
| `lib/agent/dev/dev_controller.dart` | embedded 后端工作区创建时初始化 `files/dev/home/` 目录骨架 + 工具自检 |
| `android/app/build.gradle.kts` | useLegacyPackaging + jniLibs 预编译产物 + JGit 依赖 |
| `settings_screen._DevTab` | 工作区后端下拉增加「内嵌沙箱」；工具自检行 |

### 5.5 明确不做（Level 1 内）

- ❌ apt/dpkg/任何包管理器（物理不可行，§2.1）；
- ❌ proot/完整发行版（guest 二进制落数据目录 = 不可 exec）；
- ❌ 下载可执行文件到沙箱再跑（W^X 拒绝 + 安全红线；需要新工具 = 出新版 APK，
  或引导切 Level 2 用 Termux 包管理）。

## 6. Level 2 —— Termux 伴侣应用（免 SSH 全生态，~1 周）

> 定位：**能力天花板**。gcc/clang/node/go、任意 apt 包、长驻服务——这些 Level 1
> 物理给不了，Termux 给。但接线方式从 SSH 换成 RUN_COMMAND intent，
> §2.3 官方通道，PerSourcePenalties 问题整体消失。

### 6.1 用户体验流（向导 v3，目标 = 零 SSH）

1. **检测**：`AppBridge.isAppInstalled('com.termux')`（已有）。
2. **自动获取 APK**：未安装 → 从模型服务器/GitHub releases 下载 termux-app
   （arm64 F-Droid 版），复用 `download_service`；下载完走标准安装 intent
   （`REQUEST_INSTALL_PACKAGES` + FileProvider，用户点一次确认）。
3. **一键配置命令（唯一人工动作，且为一次性）**：拉起 Termux（已有
   `launchApp`），粘贴一条命令——在现有向导命令基础上**追加写
   `allow-external-apps=true` + 装 git/gh**：
   ```sh
   pkg install -y openssh procps git; mkdir -p ~/.termux && grep -q allow-external ~/.termux/termux.properties 2>/dev/null || echo 'allow-external-apps=true' >> ~/.termux/termux.properties; termux-reload-settings; echo ALL_DONE
   ```
   （openssh 保留——作为 RUN_COMMAND 不可用时的回退通道。）
4. **此后所有交互免人工**：intent 直接执行。

### 6.2 执行链路（`termux_intent.dart`，替换 ssh_environment 在 termux 后端的角色）

```
Dart 工具层（ssh_tools 同签名：termux_exec/read/write）
  → MethodChannel('com.dgxspark.tongyilite/termux')
  → Kotlin: Intent(RUN_COMMAND) + PENDINGINTENT(ResultReceiver)
      RUN_COMMAND_PATH=$PREFIX/bin/sh, ARGUMENTS=[-c, <wrapped>]
  → 命令包装：输出 + 退出码 tee 到 $HOME/.out/<uuid>.txt
      再 cat 到 /sdcard/TongYiLite/termux_out/<uuid>.txt
  → Dart 轮询/单次读该文件（app 有 MANAGE_EXTERNAL_STORAGE，双向免申请）
```

- **为何用文件交换而非纯 PendingIntent**：PendingIntent 回传 Bundle 有大小
  限制且各 Termux 版本字段不一；文件交换 = 与 Chaquopy 桥（run_code 的
  `<uuid>.req/.resp`）同款已验证模式，输出大也不截断。PendingIntent 仍用于
  **完成信号**（收到即读文件，省轮询）。
- **超时与唤醒**：工具层超时 30s（对齐 ssh_tools 新值）；执行前置
  `termux-wake-lock` 防厂商杀后台（小米激进策略），回合结束 wake-unlock。
- **文件工具**：`termux_read/write_file` 直接读写 `/data/data/com.termux/...`？
  ——不行，沙盒隔离。统一走共享区：工作区 remotePath 约定
  `~/projects/<id>`，文件读写也经 `sh -c 'cat > path'` 包装（RUN_COMMAND
  stdin 不支持 → 用 `printf %s | base64 -d > path` 传内容，64KB 分块）。
- **git**：termux 侧 `git` 直接 shell 调用（apt 装的完整版，含 ssh remote），
  走同一 termux_exec 通道，`git_tools.dart` 后端分派加 `termux → termux_exec`。

### 6.3 与现状的取舍

| 项 | SSH（现状） | RUN_COMMAND（新） |
|---|---|---|
| 前置 | sshd + authorized_keys + 密钥格式全家桶 | 一条命令写 allow-external-apps |
| 拉黑/超时 | PerSourcePenalties 死穴 | 无网络层，无此问题 |
| 输出捕获 | SFTP 读，8MB 上限 | 文件交换，无上限 |
| 进程外依赖 | dartssh2 fork | Termux ≥ 0.109（PendingIntent 支持，GitHub 版 0.118.x 满足） |
| 兼容回退 | 保留 | 保留（设置里 RUN_COMMAND/SSH 二选一，默认 RUN_COMMAND） |

### 6.4 工具层改动清单

| 文件 | 改动 |
|---|---|
| `lib/agent/dev/ssh/termux_intent.dart`（新增） | intent 封装 + PendingResult 接收 + 文件交换协议 |
| `MainActivity.kt` | `com.dgxspark.tongyilite/termux` 通道：sendRunCommand（含 PendingIntent 注册）、读共享区输出文件 |
| `AndroidManifest.xml` | `<uses-permission android:name="com.termux.permission.RUN_COMMAND"/>` |
| `lib/agent/dev/tools/ssh_tools.dart` | `termux` 后端分派到 termux_intent（ssh 路径保留为回退）；git_tools 加 termux 分派 |
| `settings_screen._DevTab` | Termux 连接卡改两页签：向导（新）/ SSH（旧，标"回退"） |
| `safety.dart` | deny 名单增加 Termux 侧高危（`pkg uninstall`、`termux-setup-storage` 之外的全盘操作等） |

## 7. 安全与纪律（跨层共用）

1. **一份 safety 策略管所有执行面**：本地 shell、embedded shell、termux_exec、
   run_code 子调用全部过 `safety.dart`（deny/ask + 审批器）。这是智能体拿到大
   权限后的第一道闸，不允许某条通道绕过。
2. **DevContext 如实报告铁律延续**：每个后端的环境段都显式声明"哪些工具不存在"
   （Level 1 无包管理器/无 node 等），压制模型幻觉调用。
3. **数据边界**：embedded 沙箱根 = `files/dev/home/`（app 私有），termux 工作区
   = `~/projects/<id>`；导出到用户可见区仍走 `export_file`。不默认开放
   `/sdcard` 全盘读给模型（All-Files-Access 只给 export/附件链路）。

## 8. 里程碑与工作量

| 阶段 | 内容 | 预估 | 交付判定 |
|---|---|---|---|
| L0 | Dev 默认挂 shell_exec + DevContext 环境段 + safety 接入 + 自检 | 1~2 天 | 真机：智能体纯本地完成"建脚本→执行→读回" |
| L1a | useLegacyPackaging + busybox/rg/jq jniLibs + 自检 | 2~3 天 | nativeLibraryDir 探测全绿；字符串级 APK 验收；release 体积复测 |
| L1b | JGit MethodChannel + git_tools 后端分派 | 2~3 天 | 真机：embedded 工作区 clone→commit→push（GitHub https+token）全通 |
| L2a | RUN_COMMAND 通道 + 文件交换 + termux_exec 工具 | 3~4 天 | 真机：零 SSH 跑通 termux_exec/读/写 + `pkg install git` 后 git push |
| L2b | 向导 v3（自动下载 APK + 新一键命令）+ 设置页 | 1~2 天 | 新装用户全程只粘贴一条命令 |

依赖顺序：L0 独立可先行；L1a→L1b 串行；L2 可与 L1 并行（不同代码面）。

## 9. 验收门（机检化，延续项目传统）

1. **编译门**：`useLegacyPackaging=true` 后 `aapt dump badging` 确认
   `extractNativeLibs`；解包 APK 确认 `lib/arm64-v8a/libbusybox.so` 等存在且
   `file` 显示 PIE ELF。
2. **exec 门（真机）**：`nativeLibraryDir` 干跑三件套各一次，exit 0；
   logcat 无 SELinux avc denied。
3. **功能门**：test/agent 全绿（新增：embedded 注册/分派、git_tools 三后端
   分派、termux_intent 文件交换协议桩测试）；analyze 0 error。
4. **性能门**：embedded shell_exec 冷启动 P50 < 300ms（Process.start 无
   网络环回，应远快于 ssh_exec）。
5. **字符串门**：debug kernel UTF-8 / release libapp.so UTF-16LE 命中
   「内嵌沙箱」「RUN_COMMAND」等新串；Native 改动则验 libtongyilite_jni.so
   （NDK up-to-date 跳过老坑，AGENTS.md 2026-10-03）。

## 10. 风险与规避

| 风险 | 规避 |
|---|---|
| `useLegacyPackaging=true` 全局副作用（安装体积↑、llama .so 加载路径变化） | L1a 单独出包真机回归三后端推理；不可接受则改为 manifest 只对工具 .so 无法豁免（flag 全局）——兜底方案是放弃 jniLibs、Level 1 退化为 L0+JGit（仍然成立） |
| busybox GPLv2 传染 | 优先用 toybox 重编（BSD-2）；若必须 busybox，仅本 app 侧载分发（非 Play），可接受，但要记录 |
| JGit 与新 git 仓兼容（SHA-256 仓不支持等） | JGit 支持 SHA-1 全功能；SHA-256 仓检测到即报"不支持的仓库格式"，明确错误 |
| 各 ROM 后台查杀 Termux 服务 | RUN_COMMAND 前置 termux-wake-lock + 向导里引导用户加电池白名单；失败路径给"改用 SSH 回退"按钮 |
| PendingIntent 字段各版本漂移 | 完成信号丢失时 2s 轮询文件兜底（双保险）；真机验 Termux 0.118 基准 |
| 模型滥用执行权 | safety deny/ask 全通道覆盖 + `sandbox_permissions` 审批 + DevContext 纪律段；deny 名单随事故增补 |

## 11. 参考资料

- [Android 10 behavior changes（W^X exec 限制）](https://developer.android.com/about/versions/10/behavior-changes-10)
- [termux-app#1072 — No more exec from data folder on targetAPI >= Q](https://github.com/termux/termux-app/issues/1072)
- [Google Issue Tracker 128554619 — exec in home dir](https://issuetracker.google.com/issues/128554619)
- [Termux RUN_COMMAND Intent 官方 wiki](https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent)
- [StackOverflow — targetSdk 29 exec via jniLibs lib*.so](https://stackoverflow.com/questions/63800440/android-cant-execute-process-for-android-api-29-android-10-from-lib-arch)
- 本仓：`docs/ai_dev_agent_design_2026-10-01.md`、`docs/ssh_agent_environment_2026-10-01.md`、
  `docs/dartssh2_termux_pitfalls_2026-10-01.md`（SSH 老坑，回退通道排障用）
