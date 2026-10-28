# 更新日志

所有重要变更将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

---

## [0.3.6] — 2026-10-28（versionCode 24）

### 📱 远程控制（ADB）：App 内纯 Dart ADB 客户端，直接控制另一台手机

用户诉求：「增加 adb 这个命令工具能力，在需要的时候可以直接控制其他手机」——并明确要求
**在 app 里直接集成实现**（不是调 Termux 的 adb、不是 SSH 到 PC 借 adb、不打包 adb 二进制）。

- **零依赖协议栈**（`lib/agent/adb/`）：`adb_protocol.dart`（24B 小端帧 + CNXN/AUTH/OPEN/OKAY/WRTE/CLSE +
  shell_v2 子帧 + sync 变长记录）、`adb_rsa.dart`（自研 PKCS#1 v1.5 签名 + AOSP 524B 公钥 blob，
  与真 `adb` 的 `adbkey` 字节级同构，可直接导入 `~/.android/adbkey`）、`adb_connection.dart`
  （握手状态机 + 流多路复用）、`adb_client.dart`（shell/execOut/push/pull/ls/stat/install/logcat/screenshot）、
  `adb_targets.dart`（目标机白名单 + 密钥托管）、`adb_tool.dart`（**单工具 + `action` 枚举**，16 个动作）。
- **传输 = Wi-Fi TCP + RSA 经典模式**：目标机 `adb tcpip 5555` 或开启无线调试即可；首连上送公钥，
  目标机弹「允许 USB 调试」一次即长期有效。不做 TLS-PSK/SPAKE2、不做 USB-OTG、不做 scrcpy 镜像。
- **门禁 = 设置页开关**（用户定案：开启即免审批，不设逐次确认框）：目标机只能来自
  「设置 → 开发者 → 远程控制（ADB）」白名单（模型无法现编 IP）；`uninstall` / `pm clear` /
  `reboot` / 系统目录 `rm -rf` / `dd` / `mkfs` 在 `execute` 体内直接拒绝（护住已下载端侧模型缓存，
  安装固定 `install -r -t` 覆盖安装）；`adb` **不属于 Dev 工具组**，由自己的 `adbEnabled` 注册。
- **测试即验收**：`test/agent/adb_protocol_test.dart`（真机抓到的字节作向量）、`adb_rsa_test.dart`
  （签名/公钥 blob 与 AOSP 逐字段对齐）、`test/agent/fake_adbd.dart` + `adb_client_test.dart`
  （**进程内假 adbd 全链路**：复现"入站帧 data_check=0""子进程已退出时不再 ack 最后一次 WRTE"
  "STAT 回复 16 字节 mode 在头部字""sync 请求 a0 含义随 id 变"等真机取证结论）、`adb_tool_test.dart`
  （门禁 / 黑名单 / 输入转义 / 端到端打假 adbd）。共 56 项，全量回归 **882 通过 + 4 skip**。
- **测试反过来抓到两个真 bug**（都是真机上会偶发/致命的）：
  ① `AdbConnection.sendRaw` 里 `await flush()` 与另一路 `add()` 并发 → dart:io 抛
  `Bad state: StreamSink is bound to a stream`（`flush()` 内部就是 `addStream(空流)`，会把 sink 绑住；
  我们的 OKAY 是在收包回调里 unawaited 发的）→ 出站改为**单条串行链**；
  ② 命令黑名单 `pm clear` 的正则误写成 `\npm\s+clear\b`（`\n` 是**字面换行**不是 `\b`）→
  行首 `pm clear 包名` 一条都不拦，正是会清掉模型缓存的那条 → 改 `\b`，并留测试钉死。
- **验收状态**：真机侧此前已对小米13（2211133C / Adreno 740）逐帧取证并复验握手/shell/截图；
  push-pull/ls/stat/logcat/install 的真机跑测受设备离线阻塞（`<redacted-tailscale>` Tailscale 离线），
  复跑入口：`TONGYI_LIVE_ADB=1 dart run tool/adb_probe.dart <ip>:5555 --selftest`
  （失败现在给可读结论而非未捕获异常）。

### 🖥️ Dev Agent：远程电脑密码登录 + 工作区激活/目录自愈 + dartssh2 错误收口

- **远程电脑密码登录 + 工作区激活（A/B/C/D）**：SSH 配置支持密码认证；连接成功后的引导
  （建远端目录 / 建并激活工作区 / 浏览远端目录）从设置页私有方法抽成共享动作层
  `dev_workspace_actions.dart`——设置页向导、聊天页工作区面板、目录浏览对话框三处复用同一套，
  不再各抄一份漂移；激活态落 `active_workspace.json` 唯一真源，文件损坏回落默认、绝不因坏文件起不来。
- **工作区目录「有就用、没有就建」**：远端路径一律 `mkdir -p` 幂等创建（ensureRemoteProjectDir /
  ensureWorkspaceRemoteDir / remoteCdPrefix / write_file 父目录四处），消灭「未配置远端路径」硬抛；
  家目录读不到时明确报因（不再指向 Termux 话术）。
- **dartssh2 错误收口（修「发送失败: SftpStatusError: No such file(code 2)」整条消息被打死）**：
  dartssh2 的 `SSHError`/`SftpError` **不实现 Exception**，本模块所有 `on Exception` 兜底对其一条不生效——
  现在只有 `SshEnvironmentService` 可碰 dartssh2，出口统一换型 `SshServiceException implements Exception`
  （SFTP code 2/3/4/7/8 各有中文指引，类名不进气泡、原始对象进 `cause`）；直接触 SFTP 的 `sync_tools`
  改**裸 catch**；哨兵测试 `ssh_error_surface_test` 钉死该类型学，上游若修复用例会红并提醒删包装层。
- **SSH 诊断分流话术**（`ssh_diagnostics.dart`）：按**目标类型（手机 Termux / 远程电脑）× 认证方式
  （密钥 / 密码）**分流失败话术与修复动作——密钥失败不讲密码，电脑失败不讲 Termux；
  根治旧版只有一套 Termux 话术、连"远程电脑"失败也教人"打开 Termux 重装"的跑偏。
- **测试**：新增 `ssh_password_auth_test` / `dev_workspace_active_test` / `dev_workspace_dir_test` /
  `ssh_error_surface_test`（四套 53 项）连同 ADB 56 项，全量回归 **882 通过 + 4 skip**。

---

## [0.3.5] — 2026-10-25

### 🚀 GPU 全卸载产品化第一轮（740 主线）+ 仓库单主线收敛

- **双线合流出包**：`feature/rail-harness`（UI 线）与 `main`（GPU-offload 线）merge 进同一
  构建树，debug/release 双包验收装机（签名 CN=TongYiLite，字符串级验收 native 符号
  `moe_topk_fused` / `mmid_q4_1_batched` / `GGML_BUFT_PROBE_BATCH` 全命中）。**此后仓库单主线
  （main）**：`temp-appbuild-gpuoffload` / `spike` / `tongyi-r2` 分支删除；spike 线独有的
  OpenCL 显存硬上限守卫（未合入 JNI）以 tag `archive/spike-opencl-clmem-guard` 归档。
- **KV 精度开关新增 F16 档（JNI + 设置页三档）**：混合架构（GDN+注意力，如 Ling）上 Q4 K 会把
  注意力链踢回 CPU 岛（decode splits 暴涨、CPU compute 313MB）；ling 的 Q4/Q8 KV 更因 V 尺寸
  不齐直接建不了 ctx（JNI 已有自动回退 F16 重试）。选 F16 恢复 decode 3-split 结构
  （CPU-embed 头 + GPU 整网 + CPU-lm_head 尾，GGML_SCHED_DEBUG dump 实证）。
- **offload 线成果并入产品**：M-R1 融合路由算子（`GGML_FUSED_MOE_TOPK`，CLI 实测 kernel
  1498→1199、host 提交 -24%、+6~20% tok/s，App 侧 env 门默认关待验收开启）；BUFT placement
  探针默认批量 512→1（CLI splits 31→6）；q4_1 batched MoE 路由行（splits 6→2，CLI decode
  2.97→8.38 tok/s = 2.8×）；K-quant flat GEMV 数值门通过。
- **App 侧实测基线（740 · ling-3.0-tiny · OpenCL 全 GPU）**：decode **5.3 tok/s**（f16 KV 直载，
  UI 统计条权威）；回合 wall 大头 = 智能体系统提示词 prefill（12k 字符，pp 图 63-split 中 37 个
  dense q5_0 MUL_MAT 按 Adreno `ne[1]>=512` GEMV 门设计内回退 CPU）——UBATCH 收敛与 M-R1 开启
  两腿 A/B 待续。测量装备：`tool/measure_toks.sh` + `vk_flags.conf` 任意 env 注入通道
  （HOST_TIMING / SCHED_DEBUG / UBATCH，免重编免 root）。
- worktree 三坑入档：`local.properties` 与 `GeneratedPluginRegistrant.java`（必须 `flutter pub
  get`，缺失 = 全插件不注册且症状静默）gitignored 不随 worktree；Dart 设置白名单会洗掉 JSON
  注入值。

### 🧠 智能体思考治理：失控根治 + API「思考强度」档位 + token 读数 + 停止按钮修复

- **思考失控根治（思考动辄几万字不收口）**：旧守卫只量当前思考块，块一闭合清零 → think/response
  反复横跳时累计无上限（机检实测 4 万字畅通无阻）。新口径唯一真源
  `AgentStreamProcessor.thinkingRunaway`：**跨块累计** + `producedAnything` 门槛（有工具调用或
  可见文本 ≥80 字才豁免，"开头两句寒暄"不豁免）；止损后**先抢救再判死**——已产出工具调用/够长
  答案照常交付，`thinkingOverflow` 允许重试**一次**且强制 `forceNoThinking`；工具决策步默认不下发
  思考（设置 → 智能体 → 执行参数可回退）。机检：`dart run tool/measure_thinking_guard.dart`。
- **API「思考强度」档位**：每条 API 模型配置独立 `thinkingEffort`（null = 请求体与改动前逐字节
  相同，不做全局开关）。一族一字段，唯一真源 `lib/agent/llm/thinking_effort.dart`：OpenAI/grok/
  MiniMax 顶层 `reasoning_effort`；Claude `thinking.budget_tokens`（必须 < max_tokens）；Gemini
  `thinking_config.thinking_budget`；DeepSeek/Kimi `thinking.type`；GLM `thinking.enabled`；Qwen
  云端 `enable_thinking`；vLLM/SGLang `chat_template_kwargs.enable_thinking`。字段被严格端点拒绝
  → 自动去字段重发（丢档位可以，丢请求不行）。
- **状态条实时 token 读数**：生成中的「生成中 + 停止」行改为实时计量（中日韩按字、其余 4 字符折 1，
  **含工具调用参数**）；思考 ≥600 tok 且产出 <5% 显 `⚠️只想不写`。
- **停止按钮「没反应」三洞修复**：① 取消以 transport 形态到达而 transport 可重试 → 停止后循环自己
  再发一次；② `cancel()` 旧版仅在 generate 中置位 → 步间隙按了无效；③ 停止以 `agent.isRunning` 当
  门槛 → 工具执行相位只停一次。取消为**回合级**、幂等。
- 验收：`flutter test test/agent test/providers test/services` = **714 passed + 2 skip**；
  `dart analyze lib` 0 error。新增测试：`thinking_runaway_test`（12 项）、`thinking_effort_test`、
  `turn_meter_test`、`stop_generation_test`、`openai_service_thinking_test`。

### 🔬 Mesa 全 GPU 卸载线：测量接管 + L3 临时裁决（引擎侧，真机 K40）

- **10-19「整线重估」作废**：三重测量污染（`830env.sh` 写死逐 op clFlush、逐提交 printf 调试版
  Mesa、CPU 对照腿漂移 2.2×），24 份旧 e2e 日志全部不作数。重建纪律：BUILD_INFO + env 指纹强制
  前置（`verify_mesa_bundle.sh`，缺失 exit 4 拒跑）、trace-off 构建、交错 A/B + 90s 冷却 + ≥3 轮。
- **L3 裁决级 A/B（K40，安静态）**：Mesa 全 GPU decode ≈ CPU bank 的 **17.5–20%**（CPU 3.14 /
  Mesa async 0.55 / flush1 0.63 t/s）；提交层封死（P5 整图单提交永久降级）；专家 I/O 排除出关键
  路径（读量 ÷5.6 只 +6%，采纳 `DECODE_WINDOW=64+ROUTE_KEEP=1`）；**头号嫌疑 = CPU 回落往返**：
  真实 decode 图 207 形状中 87 个（42%）每 token 落 CPU，其中 80 个是 fork 自己的
  `MAP_CUSTOM1 ffn_moe_slots`（ggml-opencl 无 OpenCL 实现）。
- **App/OpenCL 侧同批定案**：G-769 SSM 判 CPU 使图 30→138 段是真因（修复后 Ling 6.72→19.90 t/s，
  2.96×）；A7X batched MoE 默认放行（+46%）；a6xx 四个内核补 `cl_khr_3d_image_writes`（K40 加载
  失败定案）；`opencl_stub` 自证防"假 GPU 腿"；`run_mesa_matrix.sh` 证据闸改数提交证据。
- 状态快照与解锁即动手清单：`docs/全GPU卸载_Mesa线_状态快照_2026-10-24.md`。

### 📱 其他

- 调试机型分级定案（2026-10-22）：小米13/Adreno 740 = 调试主力与支持底线、K90(830) = 高端参考、
  K40/Adreno 650 = 最低档冒烟；任何真机结论必须标机型档位，跨档结论不许互抄。
- 打包验收抽出 `tool/verify_apk.sh`（唯一真源），`tool/build_apk.sh --verify-only` 只验产物不重编。
- Dev Agent 安全面加固（`lib/agent/dev/safety.dart`）+ 插件平台契约冻结（`docs/插件平台_契约冻结清单_2026-10-23.md`）、
  英语听写插件与离线朗读（sherpa-onnx OfflineTts，零新依赖）。

## [Unreleased] — 2026-10-20

### 🔊 TTS 播报修复：微软强制 Sec-MS-GEC v2（内置 edge_tts 已移植）+ 失败不再静默

- **症状**：回答气泡点 🔊、设置页「试听」全都不出声，音色列表却正常（HTTP 200 / 322 音色）。
- **根因**：微软免费 readaloud 端点自 2026-10-10 起**强制 Sec-MS-GEC v2** token，
  旧的 v1（纯 SHA-256，64 hex）一律 **403** —— 合成 WebSocket 握手即被拒，全音色无解。
  与网络、时钟偏差（实测 0 秒）、Edge 版本号声明、Origin/Cookie 均无关。
- **修复**：vendored `third_party/edge_tts` 新增 `lib/src/gec_v2.dart`（上游 python
  edge-tts PR #492 的机械移植：魔改 SHA-256 + CS64，输出 `<16hex>-<64hex>`），
  `Sec-MS-GEC-Version` 前缀同步 `1-`→`2-`（两者必须成对切换，只改一边仍 403）。
- **验证**：14 组 golden 值与上游抓包/参考实现逐字节一致；探针实测恢复出音
  （mp3 48kbps/24kHz mono），36 音色矩阵全出音；`flutter test test/tts test/providers
  test/services test/websearch` = 168 通过 + 2 skip。
- **顺手堵雷**：合成/播放失败不再只写 debugPrint。新增 `EdgeTtsService.lastFailure`
  与分类器 `classifyTtsError`（鉴权失败/网络/空音频/播放），**手动点 🔊 或试听失败
  会上 SnackBar**（自动播报仍保持静默、不打断聊天）。
- **手机侧第二层坑（同日追加）**：手机到 `speech.platform.bing.com` 的 **IPv6 通道半死**
  （TCP 连上、TLS 被 RST；`curl -6` = 000、`curl -4` = 200），而 dart:io 只在 TCP 连接失败时
  才换地址、TLS 阶段失败不回退 → 连接层静默哑掉。TTS 的三个 HttpClient 改为
  **IPv4 优先、IPv6 兜底**（`createTtsHttpClient()`，不是只走 IPv4）。
- **排障工具（新）**：`tool/tts_diag_probe.dart`（全链路分层定位，TTS 不出声首选）、
  `tool/tts_conn_probe.dart`（连接层：HTTP/WS 双模式，专抓 connectionFactory 的 TLS/端口坑）、
  `tool/tts_gec_matrix.dart`、`tool/tts_gec_golden.dart`、`tool/tts_raw_upgrade.dart`。

---

## [0.3.3] — 2026-10-16（当前版本 · versionCode 21）

### 🚀 LFM2.5-24B-A2B 官方整包 in-place split-MoE 真机验收

- **官方整包直下直读**：catalog 新增 `lfm2.5-24b-a2b-q4_0`（`splitMoe.inplaceFullGguf`），
  端侧只下载 **官方单文件 gguf**（12.65GB，ModelScope/hf-mirror，sha256 校验），
  **免 PC 打包、免分片传输**。引擎（`llama-moe-experts.cpp`）扫描 gguf header 后为
  114 个 `blk.N.*_exps.weight` 条目按 `entry->offset + e×expert_stride` 原地绑定，
  slot 引擎（seg 模式）per-entry `readv` 直读专家——真机日志
  `init pack=seg pack_layers=38/38 bank=16 experts=64`。
- **实测（小米13 / OpenCL / n_ctx=4096）**：decode **1.6 t/s**（旧 split-bins 路 0.9，
  **+78%**）；专家 I/O **1902 MiB/s**、456 preadv/token、**zerocopy 100%**；
  PSS 913MB 无 lmkd；12.6GB 整包加载 ~70s；回答正确自识。
- **修复 ① JNI 漏传参**：`nativeLoadModel→g_engine.load(...)` 漏传 `moe_experts_bytes`
  → in-place 整包被 oom-guard 按 24.9GB 全量误拒；补传后按 dense+bank 常驻估重 3.88GB 放行。
- **修复 ② bank 通配覆写泄漏**：`moeBankOverrideByModel['*']`（MiniCPM slot~1.3MB 时代
  遗留）套到 in-place slot 192.38MB 会要求 12.9GB 常驻；in-place 现忽略手动覆写，
  走内存自适应 autoBank。
- **回归**：MiniCPM-V 4.7 packed-bins 生产路径同 session 自动加载成功，行为零变化；
  seg 模式仅在 strict pack 失败时启用。
- 真机操作通道沉淀：触屏注入失效期经 **VM Service evaluate**（`_probe/vm_eval.py`，
  裸 websocket JSON-RPC）直达 Riverpod 完成全部驱动，等效 UI 操作。
- versionCode 20 → 21。详细验收记录：
  `docs/lfm25-24b-a2b-q40-moe-smart-loading-eval-2026-10-15.md`「方案 C 真机验收」节。

---

## [0.3.2] — 2026-10-15~16（versionCode 19+，主干未单独发布）

### 🧠 智能 MoE 拆分加载（split-MoE）+ LES 前瞻调度 + GPU 路线双机定案

- **split-MoE 双形态**：权重剥离 `.experts/`（40 分片 + manifest）或 in-place GGUF 直读
  （seg fallback，按 expert-stride 分段 preadv，免剥离）；slot bank 流式供给专家
  （热度表 + per-layer 填充 + 超集异步预读 + LES 下一层 router 预测）。
- CPU slot bank 热稳态小米13（830）MiniCPM-V 4.7 35B-A3B **8.07 t/s**、740（Adreno 825）
  3.0–3.4 t/s；GPU bank 全套（FGSVM / route0 直写 drain 归零 / `pack_async` / uploads race fix，
  bank23–32 共 14 腿零崩）默认关。
- **GPU decode 路线双机定案**：SCHED_STATS 插桩 + probe9 提交税探针（OpenCL 9µs/op vs
  CPU 0.34µs，Adreno 不暴露 `cl_khr_command_buffer`）→ decode CPU 混合守擂；CPU 岛收编
  （小权重豁免 + `GGML_OPENCL_SSM_A8X`，splits 203→83）；Mesa 整图单提交路线立项。

---

## [0.3.1] — 2026-10-14（versionCode 19）

### ⚡ q4_K batched MoE 修复上线（预计算 scale dodge）

- **q4_K batched MoE 由禁用转启用**：v0.3.0 时因 Adreno 830 (E031.47) 确定性乱码
  （探针 NMSE 1.27/23.5/2.6，7 种代码形状改写位级不变、内核内同地址跨子群读出
  不同字节）临时禁用、走 dense-loop。本轮定位为 E031 在线编译器对
  `get_scale_min_k4` + 三平面 6-bit mask 重组代码形状的损坏后实施修复：
  **host 一次性预计算有效 scale 平面** `seff=d·sc` / `meff=dm·mn`（fp16、half2
  行对打包、per 32-block，见 `ggml_tensor_extra_cl_q4_K`），内核 scale 读取
  退化为与已验证 q4_0 batched 内核结构相同的纯 half2 加载。
- 真机探针（`_probe/moe_probe`）：**11/11 形状 NMSE=0~1e-6，重跑位级一致**，
  含 Ling-3.0-tiny 实际层形状与 5 个二分退化形状；GPU bench 与 q4_0 batched
  同档（gateup 199 vs 198 µs）。seff/meff 缺失时自动回退 dense-loop（fallback 保留）。
- 其它：KDBG 逐块对撞基建简化回 6-float 格式；opencl-stub 补
  `clCreateProgramWithIL` 转发（实测 Adreno Android `CL_DEVICE_IL_VERSION` 为空，
  SPIR-V 交付不可行，留档）；探针新增 `MOE_PROBE_ONLY=Q4K|Q40` 缓存隔离开关。
- versionCode 18 → 19。

---

## [0.3.0] — 2026-10-14（versionCode 18）

### ⚡ OpenCL batched MoE（q4_0 单 dispatch）

- **batched MUL_MAT_ID**：新增 `kernel_mul_mat_id_q4_0_f32_batched`——一次 dispatch 计算
  全部 (slot, token) GEMV 列，ids 张量驻留设备端直读，免去逐专家 launch 与 ids 回读同步；
  权重按专家层 SoA 转置布局（q image + d 平面），q4_0 真机（Adreno 830）probe NMSE=0，
  App 实测 **prefill 149 t/s、decode 14–22 t/s**。
- **P3 专家桶排序**（prefill）：设备端 hist/scan/scatter 三小内核把同专家列聚邻
  （`perm` 排序由主内核读取），同专家权重命中 L2 而非反复流式重读；
  scratch 布局 `[hist | perm]` 的 perm 起点 256B 对齐（修复 clCreateSubBuffer -13 崩溃）。
- **P4 激活缓存**：激活 sub-buffer + image 8 槽 direct-mapped 缓存（key = buffer/origin/size），
  decode 每步免重建（修复 image 宽度 `b_size/16` 误写 `/4` 导致的 -38 崩溃）；
  权重 q image 缓存于张量 extra。
- **P0 KV checkpoint/restore**：长对话多轮不再整段重 prefill——边界 checkpoint，
  恢复后仅对增量 token prefill，**多轮对话二次 TTFT 34s → 4.4s**；
  短对话（<512 单 chunk）自动 full clear，代价 <1s。

### 🧯 修复

- CL 内核写 `nullptr`（OpenCL C 非 C++）→ err=-11 加载即崩，改为 `(global uint *)0`。
- MoE 激活 image1d_buffer 宽度按字节/16 计算（原 /4 宽 4 倍）→ clCreateImage -38 崩溃。
- P3 sort scratch perm 区起点按 CL_DEVICE_MEM_BASE_ADDR_ALIGN 对齐 → clCreateSubBuffer -13。

### 🔒 q4_K batched MoE 定案禁用（正确性优先）

- q4_K 版 batched 内核在 Adreno 830 输出确定性乱码：真机探针 NMSE 1.27 / 23.5 / 2.6，
  **5 种代码形状改写（VSB 宏变体 / mad 开关 / dequant-once / 直线化 scale 解码）NMSE 位级不变**，
  同程序 dense 内核对同一份平面数据位精确；UNI 探针（全 slot 同专家）各 slot 输出彼此一致但皆错
  ⇒ 排除跨 slot 泄漏与专家基址偏移，根因未定（疑 Adreno E031 编译器对该内核代码形状的误编，
  但改写未躲开）。**发布版禁用 q4_K batched（入口直接回退 dense-loop），q4_0 不受影响。**
- 新增 `_probe/moe_probe` 真机探针工具（本版起入库维护）：`moe_probe*.cpp` 真机 NMSE 对照，
  支持 `MOE_PROBE_UNI`（跨 slot 泄漏检查）/ `MOE_PROBE_SAME`（专家基址隔离）/
  `MOE_PROBE_DUMP`（数值形态）诊断 env；配套 adb 工作流（cl-cache 清理、推库、运行）。

### 其它

- `GGML_OPENCL_MOE_DEBUG=1` 打印 batched MoE 全部标量参数；
  `GGML_OPENCL_BATCHED_MOE=0` 强制 dense-loop（A/B 基准）。

---

## [0.2.9+] — 2026-10-06 ~ 2026-10-08（同 versionName 复用 · 主干合批，随 v0.3.0 发布线交付）

> 本次为 0.2.9 后不升 versionName 的主干合批（commit `695746b` 起），全部功能已合入 main 并
> 双真机（小米 13 / 8 Elite）验证。此前仅在 README「版本更新」一句话带过，CHANGELOG 缺记，现补录。

### 🎙️ 端侧流式 ASR（sherpa-onnx）——语音输入整体重做

- **弃用旧方案**：原「录音文件喂给带音频编码器的模型」覆盖面窄且慢，整体弃用；改为与模型无关的
  **sherpa-onnx 流式 ASR**，任何对话场景可用。
- **引擎**：sherpa-onnx 流式 Zipformer 中文 int8（`sherpa-onnx-streaming-zipformer-*-zh-int8`，
  ~160MB），FFI 进程内推理（`lib/asr/sherpa_streaming_asr.dart`），**完全离线零网络依赖**
  （飞行模式可验证）。模型不入 APK：首次长按触发下载（hf-mirror 主源 + huggingface 兜底，
  断点续传）；`asr_model_manager.dart` 管理下载/删除（释放 160MB）。
- **交互**：微信式按住说话——长按 🎤 → 浮层「准备中」（首次约 5s 引擎加载）→ 实时回显 partial
  识别结果 → 上滑取消 → 松手终稿**直接发送**（自动附加输入框已有文字）。
- **热词偏置**：9 个内置分类约 290 词（智能体开发 / 端侧推理 / 本项目 / 开发调试 / 日常指令 /
  常用应用 / 手机操作 / 生活服务 / 办公学习，全部纯中文），ContextGraph 偏置 +
  `hotword_corrector.dart` 同音后校正；设置页可查看/编辑分类词表（**差量存储**：默认词表改版
  不顶掉用户编辑）、添加自定义热词、开启增强识别模式（beam search）。
- **单载复用**：加载统一收口 `start()` 按最终形态一次加载，杜绝每会话双载 ~9.5s。

### 其它合批项（同一主干演进）

- **多会话并发**：并发会话槽位 1~4，API 会话可真正并行执行回合，会话抽屉「● 执行中」徽标。
- **Dev Agent 全链路**：工作区四级后端（App 沙箱 / 内嵌 dev_shell+busybox+JGit / Termux
  RUN_COMMAND 免 SSH / 远程 PC SSH）+ 任务与规划管理 + `workspace_sync` 双向同步 +
  远端 `AGENTS.md` 自动叠加。
- **端侧直连搜索**：`lib/websearch/` 纯 Dart 六引擎（必应/百度/搜狗/360/夸克/中国搜索），
  零配置默认可用；每引擎窗口请求预算 + 指数熔断 + UA 池；`web_search` 并发多关键词一次调用 +
  每回合上限（`max_uses`，默认 5）。
- **智能体人格系统**：标准 + 自定义人格（人设独立注入，切换自动重置 KV）；技能库扩充至 17 个
  （含用户技能导入 / `save_skill` 自主沉淀）。
- **计划模式与无人值守**：`/plan` 只读规划 → 审批 → 结构化计划落库自动续跑
  （`agentGoalMaxRounds` 默认 8）；todo 清单按会话隔离（v3，旧全局清单一次性迁移）。
- **执行质量九件套 + eval**：步数上限收敛注入与自动收尾续跑、【任务执行纪律】段、回合内插话
  steer、`run_code` PTC、重复调用守护等；`eval/` 12 个基线任务 + 六维离线评分，
  `turn_metrics.jsonl` 回合指标纯派生自事件日志。
- **输入区 composer 重构**：标准智能体 composer（四态主键 / 附件 chips / 模式图标 chips /
  会话草稿 / 上下文占用圈）；上下文占用圈详情面板 + 存储级手动压缩（详见 [0.2.9] 条目）。

## [0.2.9] — 2026-10-06（versionCode 17）

### 🔊 Edge 在线 TTS 语音播报

- **免费无 key**：微软 Edge neural 语音端点（`speech.platform.bing.com`），`Sec-MS-GEC`
  本地 token 鉴权（SHA256(5min 窗口 ticks + token)，时钟偏差自动校正）；合成端纯 Dart
  （`edge_tts` 0.1.5 vendored 进 `third_party/edge_tts`，放宽 SDK 约束适配 Dart 3.6），
  播放 `audioplayers` 6.6.0。
- **入口**：回答气泡 🔊 按钮（播报中变停止，再点即停）；设置可开「回复后自动播报」；
  新消息发送 / 手动停止时自动停播，不与旧声音交叠。
- **设置卡**（智能体 Tab ⑧「语音播报」）：总开关、自动播报、音色（在线拉取 300+、
  zh 系置顶、失败回退 8 个内置常用音色、可刷新）、语速（-50%~+100%）、音调（±50Hz）、
  音量（±50%）、试听按钮。
- **管线**：markdown 清洗（代码块/图片/裸 URL 剔除、链接保留文字、标题/表格/表情清理）
  → 按句分段（≤600 字，超长硬切）→ 逐段合成（mp3 按 SHA-256 落 `tts_cache/` 复用）
  → 逐段播放（代次计数防旧任务回写）；任何失败静默降级不打断聊天。

### 上下文占用圈 + 详情面板 + 存储级手动压缩

- **占用圈**：输入框 chips 行最左圆形进度环（阈值配色蓝/橙/红 + 环心百分比），
  点开底部详情面板：占用数字/来源（实测/配置/原生）、其它会话快照、最近压缩记录、
  阈值图例、「手动压缩」按钮。
- **快照回填**：占用快照原本只在回合结束时更新（内存态），重启即灰——启动/切会话
  按本地历史重估（中文加权 token 估算器），窗口按首页同款路由规则（API 实测 n_ctx
  优先 → 配置 contextWindow；本地 → contextSize），且**直读持久层设置**规避
  provider 异步加载竞态（此前 API 256k 被误显示为本地 4096「估算」）。
- **手动压缩（存储级持久）**：把较早轮次的 🔧TRACE 工具结果信封从 SQLite 清出
  （保留最近一条 = 最近一轮工具上下文，短对话也能生效），最早一条**原位改写**为
  摘要信封（TRACE 前缀 + user/message 摘要事件，下一轮导入投影为 user 摘要，
  模型仍记得做过什么），其余删除；可见对话文本不动、UI 历史不受影响；与回合内
  内存压缩（重建即失效）互补；压缩后占用快照即时回落。

### 任务清单按会话隔离（todo v3）

- `todo_write`/`todo_list`/计划面板清单从全局单文件 `agent_todo.json` 改为按会话
  落盘 `agent_todo_<convId>.json`——不同会话各看各的清单；旧全局文件首次被某会话
  读取时一次性迁移（迁移即删，只归第一个打开的会话）。

### 其它修复与增强

- SSE 停摆看门狗（120s 无数据 → 可重试失败档，UI 重试横幅）+ `[AgentStep]` 步级
  观测日志；API 上下文占用全链路修复（`stream_options.include_usage` + usage 末块
  yield + lastUsage 兜底 + 细条阈值变色）。
- git 能力闭环：git_clone 浅克隆（JGit setDepth）、目标目录语义（`<workspace>/<name>`）、
  陈旧目录自动备份、git 工具支持子目录仓库 `path` 参数、计划模式副作用工具声明。
- 用户消息复制按钮；任务清单卡片可视化（✓/▶/○）；计划文案精简 + 面板统一渲染
  （✓/▶/○ 状态徽标共用 TodoChecklistCard）；KV/压缩观测（中文加权估算器、
  CompactionStats、推理日志压缩记录）。

**回归**：test/tts+agent+providers+services+websearch 全量 594 项 + 4 skip 全绿；
analyze lib+test 0 error。


---

## [0.2.8] — 2026-09-29（versionCode 16）

### 智能体：执行顺序渲染 + 思考流式自动展开 + 空响应重试 + 思考泄漏修复

- **① 执行顺序渲染（timeline markers）**：`AgentUiState` 新增 `timeline: List<UiTimelineMarker>`，
  归约器在事件到达时追加标记（思考落档 → `UiTimelineThinking(i)`；工具卡加入 → `UiTimelineTool(i)`），
  `AgentTurnBlock._timelineWidgets()` 依序交错渲染——不再"思考一律在前、工具一律在后"。
  历史回合 timeline 恒空，仍走存储 🔧 消息顺序。
- **② 思考流式自动展开**：`ThinkingStreamCard` 展开条件改为 `_override ?? (running && !answerVisible)`——
  流式中自动展开跟随滚动（每次重建 `_followStream` animateTo 底部），答案开始/回合结束自动闭合。
- **③ 空响应重试（web_search"不行"主因）**：4B 模型思考中途直接 EOS（思考块未闭合被丢弃 → 空响应），
  本地路线 `emptyResponse` 原本不可重试 → 瀑布直接 giveUp。修复：loop 里 `retryEmptyResponse: true`
  （两条路线都计入可重试档，maxRetries 有界）。
- **④ 思考泄漏修复**：`AgentStreamProcessor` 新增"孤立闭合记号"处理——模型偶发在回答中途再输出
  ` response`（无前置 think），当作**隐式 opener** 重新进入思考态、续写一并丢弃；带保护：
  ` response` 紧跟英文/数字（如 "API response"）不吞，避免误伤英文词。
- **⑤ 工具卡 / 思考流滚动**：ToolActivityCard 单行紧凑行；思考流式长内容 150px 滚动区
  `jumpTo(maxScrollExtent)` 跟随底部，用户上滑暂停。

### Vulkan 全败定案：turnip dlopen 缺 libhardware.so（jniLibs stub 复活）

- **根因**：JNI 把 `GGML_VK_TURNIP` 指向 APK 内置 turnip（libturnip_freedreno.so），dlopen 失败：
  `library "libhardware.so" not found`——turnip 的 DT_NEEDED 含 `libhardware.so`（Android HAL 库），
  **App 进程 classloader 命名空间不能 dlopen 系统 HAL 库** → ggml-vulkan init 失败 → Vulkan 回落 CPU。
  v0.2.6 时代 turnip 验证全在 CLI 测试基建，从没在 App 进程内验证过——入库即埋雷。
- **修复**：`jniLibs/arm64-v8a/libhardware.so` 极简 stub（源码 `stub_hardware.c`，NDK clang 编译，
  仅导出 turnip 实际 import 的 `hw_get_module` 返回 -ENOENT）。dlopen turnip 依赖解析在 app 自己的
  lib 目录命中 stub → 成功。LLM 推理不走 gralloc/AHardwareBuffer 导入路径，-ENOENT 安全。
  SONAME 必须与系统库同名（`-Wl,-soname,libhardware.so`）。
- **验收铁证**：logcat `using Vulkan HAL GetInstanceProcAddr from .../libturnip_freedreno.so`
  + `Found 1 Vulkan devices: Adreno (TM) 825 (turnip Mesa driver)` + `backend_ptrs.size()=2`
  + `loadModel result: true`。
- **坑**：NDK 裸 `clang --target=aarch64-linux-android` 缺 crt 文件，须用带 sysroot 的 wrapper
  （`aarch64-linux-androidXX-clang.cmd`）编译。

### web_search：并发多关键词 + 每回合搜索上限（max_uses 语义）

- **并发搜索**：`web_search` 加可选 `additional_queries: string[]`（最多 3 个），`Future.wait` 并行
  搜索全部关键词，合并返回（每关键词一小节 `[搜索：xxx]`，均分 1500 字预算）。描述教模型
  "一个问题的多个角度一次提交，不必多次调用"。
- **每回合搜索上限**：每次调用消耗 1 次（含重复）；达上限拒绝联网返回
  `ToolResult.error('本轮搜索次数已达上限（N 次）…请直接回答，不要再调用 web_search')`。
- **同内容去重**：主查询归一化（小写/去空白标点）相同 → 直接回缓存结果（`已搜索过，结果同上，
  未重复联网`），重复同样消耗预算尽快逼模型收敛。
- **设置项** `agentMaxSearchesPerTurn`（1~10，默认 5）；系统提示加规则：已有足够结果直接回答；
  收到"已达上限"立即停止调用。

### 智能体回答 tok/s 指标 + 思考流滚动

- agent 路径保存 answer 时补原生 `getInferenceStats()`（末步口径 = 答案步，与普通聊天同公式）；
  API 路线无原生 stats 不显示；首Tok 对多步回合无单步语义 → `firstTokenMs=0` 时整段省略。
- ThinkingStreamCard 内部 150px 滚动区 ScrollController + didUpdateWidget 跟随底部。

**验收**：test/agent + test/providers 全绿（259+ 项）；analyze 无新增告警（既有 4 项为旧代码）。
APK：debug `app-debug.apk` / release `app-release.apk`，字符串级验收过（libhardware.so +
libturnip_freedreno.so 均在 APK）。

---

## [0.2.7] — 2026-09-29（分支停维护 · 主干统一）

### 分支停维护（用户指令）

- `spike/opencl-bonsai2-ptq1-gemm` 快进合并进 main（含 v0.2.6 + PTQ1_0 GEMM + FWHT hadamard +
  Turnip 驱动 + agent 内嵌工作流重构），此后所有开发只在 main 做。
- **主仓 `third_party/llama.cpp` 树 = spike 完整树（fe8156f 基线）；此前「b11028 半升级 +
  PTQ graft」方向废弃**，别再按那条线排查编译错误。

### API 视觉接通

- kick 把 imagePath 写进 user/message 事件，`deriveModelMessages` 投影，OpenAiAdapter
  `attachWireImages` 转 image_url part（visionCapable 门控，每 step 重发；
  OpenAiService.encodeImageFile 带 8 张 FIFO 缓存）。

### 思考流单独展示

- adapter.generate 新增 `onThinking` 通道（全量快照推送）；API 原生路线解析
  `delta.reasoning_content` / `reasoning` + content 内嵌 ` think` 剥离
  （OpenAiNativeStreamAssembler 字符状态机，跨分片安全）；本地/文本协议路线走
  `AgentStreamProcessor.thinking`。chat_provider 节流 120ms 落 `agentUiStateProvider.thinking`；
  UI = agent_workflow.dart ThinkingStreamCard（live 回合内嵌，自动展开跟随滚动，点按头可手动收起）。

### 工具卡压缩

- ToolActivityCard 从 ExpansionTile 卡改为单行紧凑行（~22px：图标+名+参数摘要+执行中），
  点按行内展开参数/结果。

**回归**：test/agent 全绿（phase6_test 点按目标同步更新）；新增 test/agent/vision_thinking_test.dart。

---

## [0.2.6] — 2026-09-28

### Bonsai-2 双后端补齐 + Turnip 错编双定案

**OpenCL：PTQ1_0 prefill GEMM 内核**（此前 decode 有专用内核、prefill 掉进逐行 matvec 反复发射）

- 新增 `mul_mm_ptq1_0_f32_l4_lm.cl`：BM64/BN64/BK32 分块 GEMM，raw `block_ptq1_0` 布局逐元素
  staged 三进制解码（pow3 三元选择规避 Adreno `__constant` 误编），BK=32 整除 QK=128 故
  K-tile 永不跨量化块；host 门控 ne00%128==0 + ne11≥32（与 q1_0 同门槛）。
- 桌面 Arc 140T（OpenCL 3.0 NEO）实测：pp128 **1.14 → 18.89 t/s（16.5×）**，tbo 174/174，
  e2e 答案正确。

**Vulkan：FWHT subgroup 门控 + Turnip 错编双定案**

- FWHT（tied-output 头每 token 必经）的 subgroup 变体判定并入三药门控；新增
  `GGML_VK_FWHT_SUBGROUP=1`（vk_flags.conf 可控）供 A/B。真机实锤：**Turnip shuffle 错编**
  （开启后 MUL_MAT_HADAMARD 8/27），原厂 0800.71 无罪（27/27）——门控默认关，恰好兜住。
- **Turnip e2e 乱码根因定案**：GEMM **大 n（≥48）编译器错编**——PTQ1_0 MMQ 二分
  n=16/24/32 全对、n=48/64/512 全错（ERR≈1.0）；f16 GEMM n=64/512 同错；原厂同 shader
  16/16 全绿；App 的 shader 集（shaderc v2026.3）同错 → 驱动端问题，与 glslc 版本无关。
- **0.2.3 时代 e2e 连贯之谜解开**：App JNI 的 `n_ubatch=16` 限制使 prefill 恒走安全区。
  CLI 复现（默认 ub512 乱码）与闭环（`-ub 16` 连贯）双双落地。
- **生产口径**：App n_ubatch 上限保持 ≤32（现值 16）为 Turnip 正确性必要条件；
  CLI/服务端用 Turnip 跑 Bonsai-2 必须 `-ub ≤32`。

**测试与文档**

- tbo 增补：hadamard 4096/8192 宽度（此前盲区）、PTQ1_0 二分/大 batch（n=64/128/512）、
  f16 大 n——本次定位主力，防回归。
- 新增验证记录 [`docs/vulkan_bonsai2_turnip_verify_2026-09-28.md`](docs/vulkan_bonsai2_turnip_verify_2026-09-28.md)
  （双驱动全矩阵：原厂 0800.71 / fork Turnip × 三药）与 `scripts/cl_enum.cs`（免编译器
  OpenCL 平台枚举探针）。

---

## [0.2.5] — 2026-09-27

### OpenCL 后端支持 PTQ1_0 三元量化（Bonsai-2 27B）

- Bonsai-2 27B 全模型 402 个 PTQ1_0 张量（GGML `type 143`，-1/0/1 三元，28 B/128 值）；上游 OpenCL
  后端只有 Q4/Q5/Q8 系列 mul_mv 内核 → 此前全部回退 CPU、decode 极慢。
- 新增 `mul_mv_ptq1_0_f32.cl`（Adreno 64-wide subgroup、2 trit/lane、subgroup 归约）实现全 GPU decode。
- **根治 Adreno OpenCL 编译器对 `__constant` 数组变址的误编**（`pow3[4]` 恒读 0 → 每块 16 trit 全解成
  -1，数据正确但内积系统性偏差）：弃用 `__constant` 数组索引，改三元表达式。
- 真机 `test-backend-ops` MUL_MAT PTQ1_0 套件 **174/174 通过**（含 67 个奇数尾行与 Bonsai 形状）。

> 块结构 / 编码 / 解码 / 内核并行 / Adreno 陷阱定位过程：
> [`docs/ptq1_0_opencl_bonsai2_2026-09-27.md`](docs/ptq1_0_opencl_bonsai2_2026-09-27.md)。

---

## [0.2.4] — 2026-09-27（智能体卡死路径根治 · v0.2.4-agent-stall-fix）

### 根因 1：工具调用块被 token 预算截断 → 静默降级成普通回答（主因）

- 模型输出 `{"name":"file_write","arguments":{"content":"……`（写到一半被 `maxTokensPerRound=512`
  拦断），`prompt_json_protocol` 括号不平衡 → **整段当普通文本返回** → 主循环判定"无工具调用 →
  本轮完成"，任务没做还显示得像成功。**这是"迭代一两下就停、没结果"的头号元凶。**
- 修复（`prompt_json_protocol.dart` `_parseText` 第 0 步三分类）：先 `_truncatedToolCall` 判定——
  ① 断在字符串/参数内容内部 → 抛 `LlmFailureCode.toolCallTruncated`（不可伪造执行）；
  ② 仅缺收尾括号且能补全 → 自动补括号照常执行（参数无损）；③ 补完仍非法 = 模型自身语法错误 →
  优雅降级为文本，**不误报截断**误导用户去调设置。`failure.dart` 的 `LlmRetry` 把 toolCallTruncated
  纳入有限重试预算。

### 根因 2：失败轮回溯历史旧答案冒充本轮回复（"重复问候 bug"）

- 第二轮起 turn 内失败 → UI 又显示第一轮的问候，像"模型只会这一句"。
- 修复：`ReactLoopAgent._turnAnswer` **只取本轮 append 的 assistant**，失败置空串绝不穿透历史；
  失败原因走 `_turnError` → chat_provider 明确报「⚠️ 本轮执行失败：…」，不再拿旧回复顶包。

### 根因 3：每轮重建 log 时 system 落在消息中段 → OpenAI 兼容服务端 400 拒收

- 新引擎每轮 importFromMessages 先导入历史，构造 agent 时才 append system → system 不在队首 →
  API 路线 400、本地 chatml 被中段 system 污染 → 表现为"执行不下去"。
- 修复：`SessionLog.deriveModelMessages` **system 恒置队首**（纯投影重排，不破坏事件序不变量）。

### 顺带：思考失控守卫 + 天气工具路径形态

- 思考块超长未闭合到阈值即主动止损（`agentThinkingMaxChars`，默认 6000，可调）。
- `get_weather` 改用 `https://wttr.in/<url-encoded-city>?format=…` 路径形态（`/?q=城市` 返回
  HTTP 500，路径形态 200）。

**回归防线**：test/agent 全绿 241 项（含截断三分类、toolCallTruncated 有界重试后终态 error、
lastTurnAnswer 不回溯、system 晚 append 仍恒队首）。

---

## [0.2.3] — 2026-09-27

### Vulkan 在 Adreno 825 重新可用（Turnip 直载）

- 原厂 0800.71 驱动 OTA 回归实锤后（2026-08-05 HyperOS OS3.0.305 OTA 后 7 月原味代码 + 新驱动同样
  拒建管线），切换 Mesa out-of-tree gen8 Turnip **App 内直载**：免 root、不碰系统分区。该驱动不导出
  任何 `vk_*` 符号，入口是 Android Vulkan HAL 模块（`hw_module_t → vulkan_device_t`，PFN 表偏移
  +0x70、GetInstanceProcAddr +0x88，逆向确认）；ggml-vulkan 4 处直接 C 符号调用全部改走 dispatcher，
  `GGML_VK_TURNIP=<驱动.so>` 指定直载。
- 数值损坏三根因逐一修复：
  - ① Turnip gen8 **错编 subgroup 算术归约（subgroupAdd）**——一切含归约的算子数值错 → 设备能力
    初始化处直接置 `subgroup_arithmetic=false`（一处覆盖全部 op 级选择），tbo f32 MUL_MAT 203/203；
  - ② 我方 `NO_SUBGROUP` 门控漏网——ssm_scan / gated_delta_net 管线选择直查 `device->subgroup_arithmetic`
    不走 use_subgroups 门控 → 直置 false 覆盖；
  - ③ GDN shmem butterfly 的 **S_V=128 lanes 配置错编**（clustered LANES=8 / 全宽 128 均坏）→
    `!subgroup_arithmetic` 时 lanes 钳 64（与已验证的 S_V=64 布局同构）。
- 验收：tbo GDN 36/36 + SSM_SCAN 12/12，LFM2.5-2.6B 短生成 5/5 连贯（6~10.6 t/s）、Qwen3.5-4B
  连贯（5.0 t/s）。

---

## [0.2.2] — 2026-09-26

### Vulkan / Adreno 825（8 Elite2）乱码与崩溃根治

- 驱动 0800.71 错编 `unpack8()`（Int8 capability）→ 量化模型输出乱码，另存在 subgroup matvec 管线
  创建失败、图融合 kernel 输出全零、dp4a 数值错误、decode 部分管线建不出共 5 个独立问题。
- 修复：shader 层用纯 32 位位操作替换 `unpack8()`（21 处调用点 + q8_0 反量化重写，位模式逐位等价），
  运行时默认注入 `GGML_VK_NO_SUBGROUP / GGML_VK_DISABLE_FUSION / GGML_VK_NO_MMV /
  GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1`（JNI 层注入，可用 `/storage/emulated/0/TongYiLite/vk_flags.conf`
  覆盖做 A/B）。

---

## [0.2.1] — 2026-09-26

### 变更：联网搜索改为「用户自配 SearXNG 实例」

- **不再预置任何搜索实例**：`SearXNGSearchProvider.kDefaultBaseUrl` 与设置项默认值全部中立（留空 =
  未配置）。未配置时 `available()` 直接回「未配置 SearXNG 地址：请在 设置 → API 接入 → 联网搜索 填写」，
  而不是拿 `127.0.0.1` 去连手机自己再报一句误导性的"不可达"。
- **设置页「API 接入」新增 🌐 联网搜索配置卡**（`_WebSearchCard`）：启用开关、实例地址、API Key
  （可切换明文显示；http 明文传密钥到非回环地址时告警）、引擎白名单、搜索语言、最多条数、超时，
  以及「测试连接」——用输入框里的**草稿值**直接发一次真实搜索，回显条数 / 耗时 / 具体失败原因，
  不必先保存。数字项保存后回显真正生效的值（`SettingsNotifier` 会夹紧到合法区间）。
- **新增设置项与 setter**（`InferenceSettings` + `SettingsNotifier`）：
  `webSearchSearXngBaseUrl` / `ApiKey` / `Engines` / `Language` / `MaxResults` / `TimeoutMs`，
  全部随 settings JSON 持久化；每项 setter 保存后热更新到 `WebSearchSeam`，改地址无需重启应用。
- **provider 复用不打断连接池**：`applySearXNGProviderFromSettings` 先比 `configSignature`
  （由配置内容计算，非实例身份），内容未变直接复用现有实例；`WebSearchSeam.registerProvider`
  同签名也复用，避免每轮对话重建 Dio / 释放 HttpClient。

### 修复：搜索链路 4 处「静默失效」（不报错，只是搜不到或必超时）

- **URL 构造**：旧实现 `Uri.replace(query: …)` 生成 `host:8080?q=…`（空 path），依赖实例 308 跳到
  `/search` 才勉强能用，换成不跳转的实例就彻底失效。现在 `buildRequestUri` 自行补齐 `/search`
  （尾斜杠 / 已写 `/search` 均不会重复拼），并把查询参数合并进 `Uri.queryParameters`
  （`q` / `format=json` / `language` / `categories` / `engines`）。
- **HTTP 状态判定是死代码**：Dio 默认 `validateStatus` 只放过 2xx，`statusCode >= 400` 分支永远进不去。
  现在请求带 `validateStatus: (_) => true` 自行判定，并按状态码给出原因（401 未授权 / 403 被拒 /
  404 baseURL 多写路径 / 429 限流 / 400·422 引擎不被接受 / 5xx 实例内部错误）。
- **HTML 被误报成"不可达"**：Dio 只在 Content-Type 是 JSON 时才解码，实例未开 `format=json` 时
  `assureResponse<String>` 抛类型错，界面显示「SearXNG 不可达」把排查指向网络。现在按
  `ResponseType.plain` 收响应、自行 `jsonDecode`，明确提示「需在实例 settings.yml 的 `search.formats`
  加 json」；坏 JSON 单独报「响应不是合法 JSON」。
- **工具超时从未生效**：`ToolDefinition.timeout` 没有任何地方消费，且 `WebSearchSeam.search` 写死
  15s 默认值会覆盖设置项里的超时 → 慢实例上搜索必然超时。现在接缝的 `timeout` 默认为 null
  （null = 用 provider 自身配置），`ToolExecutor` 与旧 `agent_loop` 均改为 `tool.timeout ?? timeout`，
  `web_search` 声明 30s、provider 默认 30s、`connectTimeout` 6s。

### 优化：搜索质量、上下文预算与诊断

- **结果去重与排序**：URL 规范化（去 `utm_*` / `from` / fragment / 尾斜杠、scheme+host 小写）后去重，
  按 SearXNG `score` 降序，`take(maxResults)`；原始条数 > 映射条数时置 `WebSearchResult.truncated`，
  提示模型"换更具体关键词"。
- **回填文本预算**：单条摘要截到 200 字、整体截到 1500 字（`kSnippetMaxChars` / `kResultMaxChars`），
  够了就停 —— 端侧 `n_ctx` 常见 8k，8 条长摘要既挤占上下文也拖慢手机 prefill。
- **引擎白名单被拒自愈**：白名单里有该实例不认识的引擎时 SearXNG 返回 400/422，provider 去掉
  `engines` 参数自动重试一次（`kWebEngineRejected`），不会一错到底。
- **诊断挖到根**：`_describeDioError` 区分连接超时 / 接收超时 / 发送超时 / 取消 / 连接错误，并把被
  Dio 塞进 `DioException.error` 的真实 `SocketException`（含 `osError` 错误码）挖出来展示，附带
  `host:port` 与已耗时（实测不可达地址 2.0s 报「远程计算机拒绝网络连接。(1225)」）。
- **延迟来自引擎**：SearXNG 会等待实例上每一个引擎，存在访问不到的引擎时整次搜索被拖到超时
  （一台自建实例实测全引擎 21s，只留可达引擎 2.2s）。引擎白名单因此做成设置项并在界面上写明。

### 测试

- 新增 `test/agent/web_search_provider_test.dart` **21 项**（注入可编程 `HttpClientAdapter`，
  覆盖 URL 构造 3 类 base 变体、5 类错误分类、引擎被拒重试、URL 去重、score 排序 + truncated、
  摘要/总量预算、接缝不遮蔽 provider 超时、`ToolDefinition.timeout` 生效与全局超时兜底、
  provider 复用/重建、设置项 toJson/fromJson 往返、默认值中立）。
- 新增 `test/agent/web_search_live_test.dart`：真实实例连通性验收（打印条数/耗时/引擎/摘要长度）+
  不可达地址快速失败，**默认跳过**（需设 `SEARX_LIVE_URL`），不污染常规测试与 CI。
- 与本改动相关的用例全绿；改动涉及文件 `dart analyze` 无 error。

### 已知无关问题

- 全量 `flutter test` 另有 3 个测试文件（`loop_test` / `pipeline_test` / `subagents_test`）编译失败，
  根因是 `lib/agent/skills/*`、`lib/agent/agents_md/*`、`lib/agent/loop/agent.dart` 中尚未完成的
  WIP 语法/类型错误，与本次联网搜索改动无关。

---

## [0.2.0] — 2026-09-04

### 新增：端侧 Agent Lite 智能体

- **Agent 循环（参照 agent-loop step() 简化）**：模型 ↔ 工具多轮交互，轮次上限可配置（默认 5），
  工具结果以 user 角色消息回填后再生成，直到无工具调用返回最终回答。
- **协议可插拔**：`ToolProtocol` 抽象 + 按 `EngineCapabilities` 自动选协议；本地/API 首版统一走
  prompt-JSON/XML 文本协议（`PromptJsonProtocol` 双格式解析），原生 tools 留待能力探测后新增 adapter。
- **工具注册表**：分层（全局/按模型/用户）动态注册/注销、按模型可见性渲染清单；内置
  get_time/calculator/todo_write/todo_list/web_search/note/memory/shell/file/unit/weather 等工具。
- **设置页「智能体」Tab**：驱动模型选择（本地/API/跟随默认）、总开关、循环轮次/每轮预算/工具超时/
  智能体上下文/并行工具/联网搜索全部可调并持久化（按模型 `agentToolsByModel`）。
- **流式处理 `AgentStreamProcessor`**：思考块过滤（HTML/Qwen 双风格，含 Qwen3.5 不带 ing 的 ` think`）
  + XML/JSON 工具调用块增量隐藏。
- **llama.cpp fork 升级**：`third_party/llama.cpp` 换为 XHToken 官方 fork（`spark2_5` 架构 +
  function-calling），NDK 全量重建成功；旧版 b10176 仅本地备份不入库。
- **根治工具调用"缺参数"**（对照 `defineTool/validateArgs` 落地）：工具执行前统一必填校验，
  错误信息明确列出缺失参数名与用途并回填"补全后重试"；工具清单渲染带必填参数提示
  （如 `shell_exec（必填: command）`），让模型知道带参数工具必须给出哪些参数。
- 修复真机工具遵循率问题：提示语规则段与 XML 协议口径一致、强调必填参数、XML 数组参数解码、
  todo_write 兼容 JSON 字符串形态。**101 项单测全绿。**

### 新增：端侧 Python 执行（python_exec，Chaquopy 17.0.0 / CPython 3.11）

- **嵌入式 CPython 3.11**：Chaquopy 17.0.0 集成，APK 内嵌 `libpython3.11.so` + 标准库（stdlib .imy），
  `agent_runner.py` 经 MethodChannel（`com.dgxspark.tongyilite/python`）执行脚本，
  15s 超时 / 4KB 输出截断；无运行时优雅降级为明确错误，不影响其他工具。
- **沙箱授权体系（对照 escalation）**：严格更宽阶梯 `workspace-write` →
  `danger-full-access`；模型带 `sandbox_permissions` + `justification` 请求升级，
  agent 循环执行前经**用户确认框逐次批准**（allowed-once）；拒绝/升级标记与平台同文案
  （`[sandbox: file access denied under ...]` / `[sandbox: escalation available ...]`）。
- **设置页新增开关**：「Python 执行（python_exec）」与「完整文件访问授权」
  （danger-full-access 前置，依赖 MANAGE_EXTERNAL_STORAGE / All-Files-Access）。
- **123 项单测全绿**（新增 sandbox 阶梯/审批/字段声明/降级 22 项）；debug APK 已含 Python 运行时。

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
