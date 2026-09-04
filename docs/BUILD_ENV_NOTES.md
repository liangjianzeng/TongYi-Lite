# 本机打包构建环境备忘（为什么慢 / 怎么快速构建）

> 适用机器：开发机（Windows）。2026-09-04 定位整理。目标是让「改一点代码 → 快速出包」不再是
> 反复折腾。先读这篇，再动手构建。

---

## TL;DR：快速构建的正确姿势

改 **只有 Dart/资源** 时（绝大多数情况），最快路径 = 增量：

```bat
:: 1. 先修 PATHEXT（本机环境异常，见下文「根因 1」），否则工具链到处找不到 exe
set PATHEXT=.EXE;.COM;.BAT;.CMD;.VBS;.JS;.WSF;.MSC

:: 2. 编译最新 Dart kernel（debug）
flutter assemble -o build\flutter-assemble --define=BuildMode=debug --define=TargetPlatform=android-arm64 debug_android_application

:: 3. 同步 flutter_assets 到 gradle 的 intermediates（否则装进去的是旧 Dart！）
xcopy /E /I build\flutter-assemble\flutter_assets\ build\app\intermediates\flutter\debug\flutter_assets\

:: 4. gradle 增量打包（-x 跳过 flutter 编译；NDK 未变会自动 up-to-date，不重编）
cd android && gradlew.bat assembleDebug -x compileFlutterBuildDebug

:: 5. 覆盖安装（绝不先卸载！-r 保留模型缓存）
adb install -r ..\build\app\outputs\flutter-apk\app-debug.apk
```

release 同理，把 `debug` 换成 `release`、目标换成 `release_android_application`，输出目录用
`build\flutter-assemble-release`，同步到 `build\app\intermediates\flutter\release\flutter_assets\`，
再 `gradlew.bat assembleRelease -x compileFlutterBuildRelease`。

实测增量 debug 全流程 **约 2 分钟**（flutter assemble ~1min + gradle ~2min，NDK up-to-date）。

---

## 为什么每次构建都很久很难：5 个根因

### 根因 1（最隐蔽）：PATHEXT=.CPL 导致 PATH 查找全部失效

**现象**：`cmd` 里 `where`、`git` 一律「不是内部或外部命令」；`flutter.bat` 报 git 找不到；
release 报 `Failed to find ... gen_snapshot in the search path`；PowerShell 里 `& git --version`
拿不到输出。

**根因（2026-09-04 真机定位）**：本机环境的 `PATHEXT` 环境变量被设成了 `.CPL`（正常应是
`.COM;.EXE;.BAT;.CMD;...`）。Windows 的 `cmd`、Dart `package:process`、PowerShell 的 exe 查找
都依赖 PATHEXT 追加扩展名 → 只认 `.CPL` → 所有无扩展名/非 .CPL 的 exe 都「找不到」。

验证铁证：`dart` 脚本打印 `PATHEXT: [.CPL]`；把 PATHEXT 改回正常值后 release assemble 立即通过。

**修复**：构建命令前先 `set PATHEXT=.EXE;.COM;.BAT;.CMD;.VBS;.JS;.WSF;.MSC`（PowerShell 下
`$env:PATHEXT = ".EXE;.COM;.BAT;.CMD;.VBS;.JS;.WSF;.MSC"`）。

> 本机曾用「给 flutter 内部文件打补丁 + 完整路径 git」绕过，那是治标；**改 PATHEXT 才是治本**，
> 一改全好（cmd / gradle / flutter / package:process 全恢复）。

### 根因 2：NDK 全量编译（llama.cpp）本身就是最慢的一环

本项目 = Flutter + NDK(CMake + llama.cpp + KleidiAI + mtmd)。**全量 NDK 编译动辄 30 分钟+**，
是「每次打包都很久」的最大来源。

**解决**：只有 Dart/资源改动时**绝不清 `.cxx`、绝不全量重编**。gradle 会对 CMake 增量做
up-to-date 判定（`buildCMakeDebug` 秒过），增量打包全程约 2 分钟。

**只有** 改了 `android/app/src/main/cpp/**`、`CMakeLists.txt` 或 `third_party/llama.cpp/**` 时，
才需要清 `.cxx` 全量重建（此时慢是物理必然，无法避免）。

### 根因 3：`flutter build apk` 在 Windows/gradle 批处理下静默失败

本机直接 `flutter build apk --debug` 会静默失败（gradle 启动 `flutter.bat` 的 Windows 批处理
问题）。所以必须走 **flutter assemble → gradle 两步法**（见 TL;DR）。

### 根因 4：Dart 改动「装不进」APK（kernel 路径不一致）

`flutter assemble -o build/flutter-assemble` 把最新 kernel 写到
`build/flutter-assemble/flutter_assets/kernel_blob.bin`；但 gradle 打包读的是
`build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin`（旧拷贝），
`-x compileFlutterBuildDebug` 不会刷新它。

**必须**：assemble 之后把 `flutter_assets` 同步覆盖到 intermediates（TL;DR 第 3 步），
再用 `ls -la .../kernel_blob.bin` 确认大小/时间已更新。

### 根因 5：CMake 优化选项会被 NDK 工具链静默顶掉

`set(CMAKE_C_FLAGS_DEBUG "-O3 -DNDEBUG")` 会被 NDK 在 Debug 配置重新套 `-g` 覆盖 → 内核失去
优化（全模型变慢）。正确做法是目录级：

```cmake
add_compile_options(-O3)
add_compile_definitions(NDEBUG)
```

改 CMake 后必须清 `.cxx` 全量重建，并用 `compile_commands.json` 核对同时含 `-O3 -DNDEBUG -march`。

---

## 本机已打的 flutter SDK 补丁（clone 新环境需重打）

> 都在 `C:\dev-tools\flutter\bin\internal\`（flutter SDK 内部文件，不在项目 git 里）。

1. `shared.bat`：git 改用完整路径 `C:\Program Files\Git\cmd\git.exe`（FOR /f 里 PATH 查找失效）。
2. `update_engine_version.ps1`：git 改用完整路径；并加**兜底**——git stdout 在本沙箱拿不到时，
   直接读 `bin\cache\flutter.version.json` 的 `engineRevision` 写 `engine.version`
   （否则 engine.version 被写成空 → shared.bat 的 `IF` 解析崩「此时不应有 ...」）。

> **PATHEXT 修复后这些补丁理论上不再必要**，但补丁无害，保留可降低偶发失败率。

---

## 耗时分解（增量 vs 全量）

| 步骤 | 增量（只改 Dart） | 全量（改了 NDK/CMake） |
|------|------------------|------------------------|
| flutter assemble | ~1 min | ~1 min |
| gradle 打包（NDK up-to-date） | ~2 min | — |
| NDK 全量编译（llama.cpp 等） | — | **30 min+** |
| 合计 | **~2–3 min** | **~35 min+** |

---

## 排查工具：本机 pwsh 调用原生程序注意事项

- 直接 `& git.exe ...`、`& cmd.exe /c ...` 在 DSH pwsh 包装下**拿不到输出**（原生 stdout 被吞）。
- 可靠姿势：`Start-Process -FilePath <完整路径> -ArgumentList ... -RedirectStandardOutput <文件>
  -RedirectStandardError <文件> -PassThru -Wait`，再读文件。
- `.bat`（flutter.bat / gradlew.bat）经 `cmd /c "call ..."` 时，**路径带空格必须整体引号**，
  且子进程 PATH/PATHEXT 查找不可靠 → 优先用完整路径，或先 `set PATHEXT`。

---

## 真机安装铁律（防模型缓存丢失）

- **覆盖更新**：`adb install -r app-debug.apk`（`-r` 保留已下载模型缓存；**绝不先卸载再装**）。
- 被 `INSTALL_FAILED_USER_RESTRICTED` 拒绝时加 `-t`，并请用户在设备上点允许。
- 签名必须 `CN=TongYiLite`（O=DGXSpark），否则覆盖安装报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`。
  验证：`apksigner verify --print-certs app-debug.apk`，SHA-256 应为
  `FB:BE:1B:6C:F8:79:AB:94:1A:65:CD:D7:A7:A8:DD:6F:5A:6B:B6:40:41:2D:E3:8C:43:CB:89:4F:08:88:69:92`。
- 构建/安装前先 `adb devices` 确认设备在线（USB 断开时设备会消失，需等待或重连）。

---

## 常见失败速查

| 报错 | 根因 | 解法 |
|------|------|------|
| `git : 无法将"git"项识别...`（flutter 报 Unable to determine engine version） | PATHEXT=.CPL / git 不在子进程 PATH | `set PATHEXT=...` 或改 ps1 用完整路径 git |
| `此时不应有 <hash>`（批处理崩） | engine.version 被写成空 → IF 解析错 | 修 ps1（JSON 兜底） |
| `Failed to find ... gen_snapshot in the search path` | PATHEXT=.CPL → package:process 只试 .CPL | `set PATHEXT=.EXE;...`（release assemble 立即通过） |
| 装上去 UI 没变化 | kernel 没同步到 intermediates | assemble 后 `xcopy` 覆盖 flutter_assets |
| Device or resource busy / access-denied（.cxx） | `glslc.exe`/`vulkan-shaders-gen.exe` 残留进程锁 | 杀进程再删 `.cxx` |
| buildCMakeDebug 偶发失败 | gradle 守护进程持有 `.cxx` 锁 | `gradlew.bat --stop` 后重试 |
