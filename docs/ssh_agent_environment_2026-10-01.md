# 方案评估：智能体通过 SSH 连接手机 Linux 环境（2026-10-01）

> 用户问题：项目智能体受限于安卓沙箱，能否集成 dartssh，与"手机自身的 shell"连接
> 登录系统，以系统环境为开发环境做更多事情（如 AI 编程）？

> **已确认决策（2026-10-01 用户答复）**：手机未 root；愿意安装 Termux；
> "AI 编程"轻量 + 重型都要 → **最终路线 = 方案 A（Termux，Phase 1）+ 方案 D
> （远程 PC，Phase 3 进阶）**，方案 C（root）排除。

## 结论（TL;DR）

- **方向可行，但"SSH 到手机自身的 shell"这个具体形态有两处认知误区，需要先校正**：
  1. 手机出厂**没有 sshd、没有可登录的 Linux 发行版**——Android 只有 adb 调试通道
     （shell 用户 uid 2000），app 无权登录它；
  2. **SSH 只是传输协议，不授予任何权限**——权限边界由"SSH 服务端跑在谁的进程里"决定。
- 真正解锁能力的是**执行环境**，不是传输通道。三条可行路径：
  **Termux sshd（推荐，无 root）/ root 提权（强大但危险）/ 远程 PC（AI 编程最实用）**。
- **dartssh 包本身不可用**（1.0.3+3，6 年未维护，Dart 3 不兼容）；
  但 **DSH-Phone 已 fork 的 dartssh2 2.11.0（TerminalStudio/dartssh2）完全可用**——
  纯 Dart、SDK `>=2.17 <4.0`（本项目 Dart 3.6 兼容）、同款手机上已跑通
  客户端/认证/隧道/SFTP/远程执行。**直接复用该 fork，集成风险很低**。

## 一、认知校正：Android 是 Linux 内核，但不是"可登录的 Linux"

Android 确实跑 Linux 内核，但与桌面发行版有三层本质差异：

| 层 | 桌面 Linux | Android app |
|---|---|---|
| 用户 | 普通用户（可 sudo） | 独立 UID，无提权 |
| SELinux | 多为宽松/关闭 | **强制 enforcing**，app 域受限 |
| 存储 | 完整文件系统 | scoped storage + app 私有目录 |
| 用户态 | 完整工具链（bash/gcc/git/pkg） | toybox 精简 sh，**无包管理器** |
| 登录 | sshd / 本地终端 | **无 sshd**，仅 adb（需主机授权，app 无权登录） |

关键结论：**"登录手机自身的 shell"没有目标可连**。Android 出厂不跑 sshd；
adb shell 的 shell 用户（uid 2000）只能由已授权的主机连接，app 进程无法登录它。

## 二、核心论证：SSH 不提供权限，权限由服务端进程决定

```
app 内跑 sshd  ──►  登录进去 = 同一个 app 沙箱（同 UID / 同 SELinux 域）
Termux sshd    ──►  登录进去 = Termux 用户态（完整 Linux 用户态 + pkg）
root shell     ──►  登录进去 = 系统级权限（Magisk/su，危险）
远程 PC sshd   ──►  登录进去 = 电脑上的真实开发环境
```

- 现在项目已有 `shell_exec`（dart:io Process 跑 `sh -c`，app 权限内）——它拿到的
  就是"app 自己的 shell"。app 内再嵌 sshd，登录进去**与现有 shell_exec 完全等价**，
  零新增能力，还多了密钥管理与端口暴露的复杂度。
- **dartssh2 是纯客户端库，没有 server 实现**（SSHTransport 的 `isServer` 仅为协议
  内部支持，无对外 SSHServer 类）——"app 内嵌 sshd"这条路线基本不可行，也不值得。
- 真正缺的不是"shell"，而是：**完整用户态工具链（git/编译器）+ 包管理器**。
  这只能来自 Termux（无 root）、root 提权、或远程 PC。

## 三、SSH 客户端选型：dartssh vs dartssh2 vs ssh2 插件

| 候选 | 状态 | 结论 |
|---|---|---|
| `dartssh`（GreenAppers）1.0.3+3 | 6 年未更新，pub.dev 标注 **Dart 3 incompatible**，依赖老版 pointycastle/tweetnacl/asn1lib | ❌ 不可用 |
| `dartssh2`（TerminalStudio）2.11.0 | 纯 Dart，SDK `>=2.17 <4.0`，依赖现代版（pointycastle 3.9.1 等）；**DSH-Phone 已 fork 并真机跑通** | ✅ 直接复用 |
| `ssh2`（Flutter 插件，包 JSch/NMSSH）2.2.3 | 5 年前，Gradle 7.0.2 兼容性问题，OpenSSH 新密钥算法兼容需验证 | ⚠️ 备选，不如 dartssh2 |

**决定性证据（来自你们自己的 DSH-Phone 工程）**：
- `DSH-Phone/pubspec.yaml`：`dartssh2: ^2.11.0` + dependency_overrides 指向本地
  `third_party/dartssh2` fork（优化：processAll 批处理解密 + 启用 zlib 压缩）。
- `lib/tunnel_service.dart`（1066 行，真机验证过）：SSHSocket.connect →
  SSHKeyPair.fromPem（密钥优先/密码兜底）→ host-key 指纹 trust-on-first-use +
  可清除 → TCP forward → SFTP（8MB 上限）→ `client.run()` 远程执行 →
  编码健壮解码（UTF-8→GBK）→ 前台服务保活/重连。
- 同一手机、同一 Dart SDK（^3.6.0）——**与 TongYi-Lite 完全同构**。

## 四、方案对比

| 方案 | 能力 | 成本 | 风险 | 结论 |
|---|---|---|---|---|
| A. Termux sshd + SSH 客户端 | 完整 Linux 用户态：`pkg install git clang python node`；AI 编程可行 | 中：用户装 Termux + openssh，配置认证 | 低：Termux 也是 app 沙箱（自己的 UID），但拥有完整用户态；无系统级权限 | ✅ **推荐主路径** |
| B. app 内嵌 sshd | 与现有 shell_exec 等价，零增益 | 中：需自己实现 server | 无 | ❌ 不推荐 |
| C. root 提权（Magisk/su） | 系统级权限，可装系统包/chroot | 中：需设备已 root | **高**：AI agent 持 root 可能搞死系统/泄露数据（参见 OOM 守卫教训：模型都能把 system_server 饿死） | ⚠️ 仅高级用户可选，默认不启用 |
| D. 远程 PC（SSH 到电脑） | 电脑的真实开发环境：完整编译/构建/容器 | 低-中：PC 开 OpenSSH（Win10+ 自带/WSL） | 中：暴露 PC 需授权与防火墙 | ⭐ AI 编程进阶路径（手机编译太慢） |

## 五、推荐实施蓝图（方案 A MVP）

1. **依赖**：从 DSH-Phone 拷贝 `third_party/dartssh2` fork 到本项目
   （或共享目录 path dependency），pubspec 加 dependency_overrides。
2. **连接服务** `SshEnvironmentService`（仿 tunnel_service.dart 精简版）：
   connect/disconnect/exec/upload/download + 状态流；连接前探测 + 自动重连
   （Android 杀后台）；可选前台服务保活。
3. **工具**：
   - `ssh_exec`：对齐现有 shell_tool 形态（默认不注册，设置开启）——输出截断
     `kShellOutputLimit=4000`、超时 `kShellTimeout`，复用现有参数模式；
   - `ssh_read_file` / `ssh_write_file`（SFTP）：打通 Termux 目录与 app 工作区。
4. **设置 UI「SSH 开发环境」卡**：host/port（默认 `127.0.0.1:8022`）、认证
   （ed25519 密钥优先，存 flutter_secure_storage）、测试连接、指纹管理、状态灯。
5. **Termux 引导**：检测未安装时给出步骤（安装 Termux → `pkg install openssh` →
   `sshd`；Termux 默认只绑 127.0.0.1:8022，不暴露局域网）。
6. **安全护栏**（复用现有沙箱体系 `lib/agent/sandbox.dart`）：
   - 危险命令黑名单（rm -rf /、wget | sh、reboot、mount、su 等）或审批；
   - 每回合命令预算 + 输出截断 + 超时；
   - 连接状态 UI 可见、一键断开、指纹可重置；
   - 密钥/密码绝不落明文（flutter_secure_storage）。
7. **回归测试**：连接层注入假 SSHClient，仿 shell_tool 测试模式；
   `flutter test test/agent` 保持全绿。

## 六、风险与坑（真机预判）

- **Termux 依赖安装 + 生命周期**：Android 杀后台导致断连——连接前探测 + 自动重连；
  参考 DSH-Phone 的前台服务保活模式。
- **认证算法兼容**：Termux openssh 新版默认弃用 ssh-rsa（SHA-1）签名——**用 ed25519
  密钥**，避开该坑。
- **内存/发热竞争**：本地 LLM 推理与 Termux 构建同时进行可能撞 OOM 守卫
  （参见 docs/bonsai2_opencl_oom_2026-09-27.md 教训）——构建类任务建议排队执行。
- **"AI 编程"的现实预期**：Termux 可做 git/编辑/Python/Node/轻量编译/测试；
  重型编译（Android 工程/大 C++ 项目）手机太慢且发热——走方案 D 远程 PC。
- **验收成本**：按 AGENTS.md 真机流程（adb 覆盖安装、uiautomator 文本验证，
  不依赖截图）。

## 七、分阶段建议

- **Phase 1（MVP）**：Termux + ssh_exec + SFTP 文件工具 + 设置配置 + 安全护栏。
- **Phase 2**：工作区互通（Termux git 仓库 ↔ app 工作区）、git 操作封装、
  连接状态 UI。
- **Phase 3（可选）**：远程 PC 模式——同一 ssh_exec 工具，host 指向 PC，
  实现手机智能体驱动电脑开发环境（AI 编程终极形态）。
