# AI 开发智能体（Dev Agent）详细设计方案 —— 工作区 / 任务 / 规划 / 远端执行

> 配套：`docs/ssh_agent_environment_2026-10-01.md`（SSH 执行环境评估）、
> `docs/agent_light_design.md`（DSH 复刻核心）、`docs/agent_accessibility_方案.md`。
>
> **目标**：把现有"对话智能体"升级为"能真开发"的 Dev Agent——在手机/电脑的
> Linux 用户态里做 AI 编程：工作区管理、任务会话、规划、git、验证、远端执行。
> 本文是施工前总图：先功能框架，再数据模型，再结合点，再分阶段施工。

---

## 0. 一句话定位

**现有智能体 = 对话 + 工具执行；Dev Agent = 工作区 + 任务 + 规划 + 代码操作 + 验证。**

核心差异不是"多了几个工具"，而是**状态模型的升级**：从"一段对话"升级为
"一个开发会话（绑定工作区 + 任务 + 计划 + git 状态）"，所有新状态沿用现有
事件源架构（SessionLog）表达，UI 靠 reducer 投影，模型靠系统提示注入。

---

## 1. 现状盘点：已有 vs 缺口（"做 AI 开发智能体还缺什么"）

### 1.1 已有（复用，不动）

| 能力 | 现状 | 说明 |
|---|---|---|
| Agent 主循环 | `ReactLoopAgent` | turn/step 循环、失败瀑布、重试、压缩、取消 |
| 会话日志 | `SessionLog` + JSONL 存储 | 事件源、append-only、replace 遮蔽、崩溃修复 |
| 工具体系 | `ToolRegistry` + 六段 `ToolPipeline` | 校验/审批/超时/溢写全齐 |
| 沙箱审批 | `SandboxMode` + `AgentSandboxApprover` | workspace-write → danger-full-access |
| 子代理 | `SubagentProvider`（in-process，深度≤2） | fork/spawn |
| 技能 | `load_skill` + skills 目录 + 10 内置 | 含 plan-todo / explain-code |
| 工作区指引 | AGENTS.md（全局 + workspace，**workspacePath 未接线**） | agents_md.dart 已支持参数 |
| 基础工具 | read/write/edit/glob/grep/memory/todo/shell/python | 作用域 app workspace |
| 上下文工程 | spill（工具输出落盘）+ deterministic compaction | 端侧 token 预算保护 |

### 1.2 缺口（本次设计补的）

| # | 缺口 | 为什么缺 | 设计落点 |
|---|---|---|---|
| 1 | **工作区对象化** | 现在 workspace 只是一个目录（app docs/workspace），无身份/切换/远端映射/git 状态 | §3.1 Workspace |
| 2 | **任务层** | 会话只有"对话"语义，没有"开发任务"（issue→plan→implement→verify→done） | §3.2 Task |
| 3 | **结构化规划** | todo 是回合内一次性清单；跨回合的步骤计划+验证标准没有 | §3.3 Plan |
| 4 | **git 工具集** | AI 编程第一需求，零支持 | §3.4 Git |
| 5 | **远端执行接缝** | shell/python 只在 app 沙箱；Termux/远程 PC 环境未接（方案 A） | §3.5 SSH |
| 6 | **workspace 级记忆/上下文** | memory 是全局的；开发场景记忆应绑定工作区 | §3.6 Memory |
| 7 | **验证循环** | 改完代码怎么跑测试、对照完成标准 | §3.7 Verify |
| 8 | **开发视图 UI** | 工作区切换、任务/计划面板、git 状态、连接状态 | §3.8 UI |

---

## 2. 功能框架（先罗列）

按"Dev Agent 的工作循环"组织成 8 大模块，每个模块 = 数据模型 + 工具 + UI + 注入：

```
┌─────────────────────────────────────────────────────────────┐
│  ① 工作区管理 Workspace    切换/绑定/远端映射/同步/git 状态   │
│  ② 任务会话 Task           任务生命周期 + 会话绑定 + 恢复      │
│  ③ 任务规划 Plan           步骤计划 + 完成标准 + 状态机        │
│  ④ 代码操作 Code           read/write/edit/glob/grep（远端版） │
│  ⑤ 版本控制 Git            status/diff/log/commit/push        │
│  ⑥ 执行验证 Verify         运行测试/构建 + 结果回填迭代        │
│  ⑦ 环境连接 SSH            连接状态机 + exec + SFTP + 重连     │
│  ⑧ 记忆上下文 Memory       workspace 作用域记忆 + 上下文注入    │
└─────────────────────────────────────────────────────────────┘
        全部状态 → SessionLog 新事件类型（可回看/可投影）
        全部能力 → ToolRegistry 新工具组（按后端可用性注册）
        UI     → agentUiStateProvider reducer 投影 + 开发视图
```

**Dev 回合的模型工作循环**（注入系统提示教模型按此走）：

```
1. 先 workspace_switch/workspace_status 确认"我在哪个项目"
2. 有任务 → task_plan/plan_list 看计划 → 按步骤实施
3. 改代码：read_file → edit_file/write_file → git_diff 自查
4. 验证：run_tests → 失败 → 修 → 再跑 → 通过
5. git_commit → git_push（push 需用户审批）
6. 更新 plan 状态 → 最终回答（改动摘要）
```

---

## 3. 核心数据模型与结合点（"怎么结合实现"）

### 3.1 Workspace 模型（对象化）

```dart
/// 开发工作区：一个可操作目录的"身份"。
/// 默认 workspace（app docs/workspace）退化为 backend=localApp 的普通实例，
/// 旧行为零回归。
class DevWorkspace {
  final String id;                    // 'default' | 用户新建项目的 uuid
  final String name;                  // 显示名（如 "TongYi-Lite"）
  final WorkspaceBackend backend;     // localApp | termux | remotePc
  final String remotePath;            // 远端根目录（Termux/PC 的路径）
  final String? localMirror;          // 本地镜像目录（app workspace/projects/<id>）
  final bool gitManaged;              // 是否 git 仓库
  final String? repoUrl;              // 克隆源
  final String? currentBranch;        // 当前分支（git_status 刷新）
  final DateTime lastSyncedAt;
}
enum WorkspaceBackend { localApp, termux, remotePc }
```

- **持久化**：`ApplicationSupport/workspaces/<id>.json`（元数据）+ 本地镜像目录
  `appDocuments/workspace/projects/<id>/`。现有 `workspace/` 根目录 = `default` 工作区。
- **激活态**：全局单例 `DevSessionController` 持有 `activeWorkspaceId` +
  `activeTaskId` + `activePlanId`，Riverpod 状态驱动 UI 与工具。
- **工具路径翻译**：模型看到的路径**一律相对当前 workspace**；工具执行层按
  backend 映射：
  - `localApp` → 现有文件工具（零改动路径）；
  - `termux` / `remotePc` → `ssh_exec`（路径翻译为远端绝对路径）+ SFTP 读写。
- **结合点（关键）**：文件工具不再硬编码 `_workspaceDir()`，改为执行时经
  `ToolPipeline.pre-execute` 注入内部键 `_workspaceId`（对齐现有 `_sandboxMode`
  模式），工具据此解析路径。默认/未注入 → `default`（旧行为不变，测试不破）。
- **AGENTS.md 接线**：`loadAgentsMd(workspacePath: <当前工作区路径>)`——
  chat_provider 现在传空，接上后每工作区一份 AGENTS.md（`workspace/AGENTS.md`
  在远端 git 仓库里天然存在），Dev 回合自动注入 `workspace:guidance`。
- **注入系统提示**：新增「工作区上下文」段：项目名 / 后端 / 分支 / 当前任务
  一句话摘要（token 预算：≤80 token，按需注入）。

### 3.2 任务模型（会话之上的"开发语义"）

```dart
/// 开发任务：一次开发目标的生命周期容器。
/// 一个任务 = 元数据 + 若干会话引用 + 状态机。会话（SessionLog）保持"对话"，
/// 任务把多个会话串成一次开发闭环。
class DevTask {
  final String id;
  final String title;                  // "修复登录页 token 过期 bug"
  final String? workspaceId;           // 绑定工作区
  final List<String> sessionIds;       // 关联会话（可跨天恢复）
  final DevTaskStatus status;          // planning→implementing→verifying→done/blocked
  final String? currentPlanId;         // 绑定的计划
  final DateTime updatedAt;
}
enum DevTaskStatus { planning, implementing, verifying, done, blocked }
```

- **持久化**：`ApplicationSupport/tasks/<id>.json`；会话 JSONL 沿用，任务→会话
  关联为元数据引用。
- **会话绑定**：会话元数据（SessionLog header 扩展字段）记录 `workspaceId` +
  `taskId`；**重建 agent 时（app 重启/切换会话）从任务元数据恢复注入**——
  DevContext 一致，模型"记得"自己在哪个项目干什么。
- **结合点**：新事件类型 `task/event`（创建/状态迁移/绑定）进 SessionLog
  （log-only，不进模型历史），UI reducer 投影成任务面板。
- **任务恢复**：会话列表按任务分组；点开任务 = 恢复最后一个会话 + 注入
  DevContext（workspace/task/plan/git 摘要）。

### 3.3 规划模型（Plan，跨回合）

```dart
class DevPlan {
  final String id;
  final String taskId;
  final List<DevPlanStep> steps;      // 有序步骤
  final int currentStep;              // 进行中步骤索引
  final DateTime updatedAt;
}
class DevPlanStep {
  final String id;
  final String title;                 // "实现 token 刷新"
  final String detail;                // 实施要点（模型可执行）
  final String? verify;               // 完成标准："登录后 token 30 分钟过期自动刷新"
  final bool done;                    // 完成态
}
```

- **工具**：`plan_create`（task 下建计划）/ `plan_update`（标记步骤 done/追加）/
  `plan_list`。与现有 `todo_write` 区分：todo = 回合内即时清单；plan = 跨回合
  开发计划，持久化 + 状态机。
- **注入**：系统提示带「当前计划」段：进行中步骤 + 已完成计数 + 下一步建议
  （≤120 token）。
- **完成标准挂钩**：回合收尾时对照 `currentStep.verify`，未满足 → 提示模型
  继续（不强制，防止死循环——端侧模型遵循率有限，提示优于强约束）。

### 3.4 Git 工具集（AI 编程第一需求）

| 工具 | 命令映射 | 输出 |
|---|---|---|
| `git_status` | `git status --short --branch` | 结构化摘要（分支/改动文件/未跟踪） |
| `git_diff` | `git diff [--staged] [<file>]` | 按文件截断（≤4000 字符 + 文件清单） |
| `git_log` | `git log --oneline -10` | 最近提交 |
| `git_commit` | `git add <files> + commit -m` | 提交摘要（**commit 本地允许**） |
| `git_push` | `git push` | **需用户审批**（危险操作，走 AgentSandboxApprover） |

- 实现：全部经 `ssh_exec`（Termux/PC）执行 git 命令，Dart 侧解析文本为结构化
  结果；localApp 工作区无 git 时返回明确"不是 git 仓库"。
- **安全策略**：commit 是本地操作默认允许；push/checkout 切换分支/force 操作
  默认审批；`git reset --hard` 等破坏性命令进黑名单。
- **git 状态注入**：Dev 回合每 step 开头不带（省 token），git 工具结果自带
  最新状态；回合结束时 UI 展示"提交 N 个文件"摘要。

### 3.5 远端执行接缝（SSH，方案 A 落地）

复用 `docs/ssh_agent_environment_2026-10-01.md` 结论：

- **依赖**：从 DSH-Phone 拷贝 vendored `dartssh2` fork（SDK 兼容、真机验证过）。
- **连接层** `SshEnvironmentService`：单例，状态机（idle/connecting/connected/
  failed），exec（`client.run`，UTF-8→GBK 健壮解码）、SFTP（8MB 上限）、TCP 转发、
  断线重连 + 连接前探测；可配前台服务保活（复用 DSH-Phone flutter_foreground_task）。
- **工具**：
  - `ssh_exec`：默认不注册，设置开启；复用 shell_tool 的超时/截断/沙箱审批形态；
  - `ssh_read_file` / `ssh_write_file`：SFTP 读写远端文件（对齐现有文件工具参数）；
  - `workspace_sync`：本地镜像 ↔ 远端双向同步（Phase D）。
- **护栏**（复用现有 `sandbox.dart`）：危险命令黑名单（rm -rf /、wget \| sh、
  reboot、mount、su、git push --force 等）+ 审批；Termux sshd 只绑 127.0.0.1。
- **认证**：ed25519 密钥优先，存 flutter_secure_storage（DSH-Phone 已有模式）；
  主机指纹 trust-on-first-use + 可重置。
- **生命周期**：Android 杀后台 → 连接前探测 + 自动重连；连接状态 UI 常驻灯。

### 3.6 Workspace 级记忆

- `memory_set/get` 增加可选 `workspace` 参数；key 内部前缀 `ws:<workspaceId>:`，
  全局记忆（不传 workspace）保持现有行为。
- 系统提示带「工作区记忆摘要」（≤80 token）：该工作区最近 N 条关键记忆
  （任务结论/踩坑/决策），模型跨会话记得项目上下文。

### 3.7 验证循环（Verify）

- `run_tests`：在当前 workspace 执行测试命令（参数 `command`，模型给 or 约定
  `pkg test`/`python -m pytest`），输出截断 + 超时（复用 kShellTimeout 模式，
  可配 60s+）；结果回填模型，失败 → 迭代修复 → 再跑。
- **结合点**：tools/result hook 里 `run_tests` 成功 → 尝试自动推进
  `plan.currentStep`（done=true），失败 → 保持，模型继续修。

### 3.8 UI 与设置（开发视图）

- **开发模式开关**（设置 → 智能体 Tab「开发模式」）：关闭 = 现有行为零回归；
  开启后：
  - 会话页：任务分组 + 任务状态徽标（planning/implementing/verifying/done）；
  - 消息页：工作区切换器（顶栏 chip）+ 连接状态灯 + git 状态条
    （分支/改动数/提交按钮）；
  - 工具卡：git/plan/verify 专属图标与摘要（复用现有 ToolActivityCard 形态）；
  - 任务/计划面板：点开查看步骤列表、完成标准、当前进行步骤。
- **设置新增**：SSH 配置卡（host/port/认证/测试连接/指纹管理）、危险命令策略
  （黑名单/每次审批）、开发工具启用开关（git/plan/verify/ssh 各自开关）。
- **结合点**：全部 UI 状态来自 `agentUiStateProvider` reducer 对 SessionLog
  新事件的投影（workspace/event、task/event、plan/event、git/event、ssh/event），
  历史回合回看 = 解析存储事件（对齐现有 🔧/💭 消息模式）。

---

## 4. DSH 复刻设计缺口分析（回答：复刻设计缺了这些考虑吗）

`docs/agent_light_design.md` 的取舍表当时写明：会话事件日志、并行调度、审批沙箱、
子代理/工作流等"架构预留"。其中 **会话事件日志、审批沙箱、子代理已补**；
但**工作区/任务/规划是"隐式"的，复刻设计与 DSH 本体都没有显式建模**：

| 复刻设计现状 | 缺口 | 根因 |
|---|---|---|
| workspace = flat 目录 + AGENTS.md（DSH 也是 cwd 隐式工作区） | **无 workspace 对象**（身份/切换/多后端/git 状态） | DSH 的 workspace 就是"宿主机的目录"，天然单机单目录；手机场景有 app 沙箱 / Termux / 远程 PC **三个后端**，必须显式化 |
| 会话 = 对话（SessionLog 事件源） | **无任务层**：对话之上没有"开发闭环"语义 | 复刻设计只做了"对话智能体"的循环，没做"开发智能体"的状态机 |
| todo = 回合内清单 | **无跨回合 plan** | todo 语义对齐 DSH 的 todo 工具，本就是轻量 |
| 无 git/远端执行 | **无代码操作与验证工具组** | 复刻设计默认沙箱内做通用任务，不涉及真实代码仓库 |

**结论**：复刻设计的"核心循环"是完整的（工具/协议/循环/存储），但**开发场景的
状态语义是隐式假设**。本方案在不动核心的前提下，把隐式变显式：workspace 对象化、
任务层、plan、git、SSH 全部作为**新事件类型 + 新工具组 + 新注入段**接入，核心
循环（ReactLoopAgent / SessionLog / ToolPipeline）零改动或最小改动。

---

## 5. 结合点总表（施工对照）

| 现有件 | 改动 | 新增/复用 |
|---|---|---|
| `SessionLog` | 新增事件类型（workspace/task/plan/git/ssh/event，log-only 不进模型历史） | 事件源不变，append/replace 不变 |
| `ReactLoopAgent` | 注入 `DevContext`（workspace+task+plan 摘要段）；tools/result hook 推进 plan | 主循环零改动；系统提示组装加段 |
| `ToolPipeline` | pre-execute 注入 `_workspaceId` 内部键（对齐 `_sandboxMode`） | 六段结构不变 |
| 文件工具 | 路径解析读 `_workspaceId` → 默认 `default` 零回归 | 工具实现小改 |
| `ToolRegistry` | 开发工具组按后端可用性注册（git/plan/verify 仅 Dev 模式；ssh_* 仅已连接） | createBuiltinTools 扩展 + 接入层过滤 |
| `AgentSandboxApprover` | 复用：git_push / 危险命令 / 远端写 走审批 | 零改动 |
| `chat_provider` | 开发模式开关 + DevContext 注入 + SshEnvironmentService 单例接线 | 接入层改动 |
| `agent_workflow.dart` | 开发视图（workspace chip / git 条 / plan 面板 / 连接灯） | reducer 投影新事件 |
| 设置 | SSH 配置卡 + 开发工具开关 + 危险命令策略 | settings_service/provider/screen |

---

## 6. 上下文工程（端侧 token 预算保护）

- **注入分层**（每层独立开关/预算）：身份/人格 → **工作区上下文(≤80)** →
  **当前计划(≤120)** → **工作区记忆(≤80)** → 工具指引 → AGENTS.md → skills。
- **工具输出**：git diff / 测试输出 / 远端文件 全部截断 + spill 落盘（复用
  Spill：>4096 token 落盘，模型见定位符回读）。
- **远端读文件**：`ssh_read_file` 对齐 `kReadFileLimit=8192` 上限，支持 offset
  分页（现有 read_file 无 offset——补上，防大文件塞爆）。
- **Dev 回合预算**：local 档沿用现有分档（maxTokensPerRound=1024、末步 2048）；
  API 档不变。开发任务默认建议 API 驱动模型（长上下文 + 强工具遵循），本地
  模型可跑但遵循率受限（对齐 agent_accessibility 方案的分级结论）。

---

## 7. 安全模型（红线）

1. **权限阶梯**：本地 workspace（默认）→ Termux（危险命令护栏）→ 远程 PC
   （审批）→ root（**不支持**，方案 C 排除）。
2. **危险命令黑名单**：rm -rf /、mkfs、dd、reboot、shutdown、mount、su、
   git reset --hard、git push --force、curl | sh、wget | sh 等——默认拒绝，
   设置可放宽为"每次审批"。
3. **审批通道复用**：git_push / 危险命令 / 跨工作区写 → AgentSandboxApprover
   逐次用户确认。
4. **认证安全**：ed25519 密钥存 flutter_secure_storage；密码不落明文；Termux
   sshd 只绑 127.0.0.1；主机指纹可重置。
5. **数据最小化**：远端文件只读模型需要的片段（截断+offset）；敏感文件
   （.env/密钥）默认不进模型（文件工具加敏感后缀过滤）。
6. **审计**：ssh/git/plan 操作全部进 SessionLog（log-only），UI 可回看
   "智能体刚才动了什么"（对齐无障碍方案审计思想）。

---

## 8. 分阶段施工计划（每阶段独立可验收）

### Phase A：工作区模型 + 本地多项目（不动远端）
- [ ] `DevWorkspace` 模型 + workspaces/<id>.json 持久化 + `DevSessionController`
- [ ] 文件工具 `_workspaceId` 注入（默认 default 零回归）
- [ ] AGENTS.md workspacePath 接线；workspace 记忆作用域
- [ ] 设置 UI：项目列表（新增/切换/删除），开发模式开关
- **验收**：两个本地项目切换，模型读写的文件落在对应项目目录；旧行为零回归
  （test/agent 全绿）。

### Phase B：SSH 执行环境（方案 A 落地）
- [ ] vendored dartssh2 fork 入库；`SshEnvironmentService` 单例
- [ ] `ssh_exec` / `ssh_read_file` / `ssh_write_file` 工具（默认关）
- [ ] Termux 引导流程 + SSH 配置卡 + 连接状态灯 + 危险命令黑名单/审批
- **验收**：真机 Termux sshd 连上，模型经 ssh_exec 跑 `git status`、读写文件；
  黑名单命令被拒且模型收到可读错误。

### Phase C：任务 / 规划 / git / 验证
- [ ] `DevTask` + task/event；`DevPlan` + plan_create/update/list
- [ ] git 工具集（status/diff/log/commit/push + push 审批）
- [ ] `run_tests` + verify 挂钩 + 任务/计划面板 UI + git 状态条
- **验收**：一个真实开发任务端到端：建任务 → 计划 → 改代码 → 跑测试 →
  提交 → push（审批）→ 任务 done；test/agent + providers 全绿。

### Phase D：远端进阶（可选）
- [ ] remotePc 后端（同一连接层，host 指 PC）+ `workspace_sync` 双向同步
- [ ] 工作区镜像冲突策略（last-write-wins + 冲突标记）
- **验收**：手机智能体驱动 PC 上的完整工程（编译/构建），同步状态可查。

---

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| 端侧模型工具遵循率低（4B 级） | 开发工具数量收敛（每类 1~2 个）、参数简单、结构化输出、失败可重试；开发任务建议 API 模型 |
| token 预算爆（git diff/测试输出大） | 注入分层可配、输出截断 + spill、按需注入 git 状态 |
| 远端状态漂移（Termux 被杀/仓库变了） | 每次连接前探测 + git_status 权威源 + 断线重连 |
| 安全（AI 跑危险命令） | 黑名单 + 审批复用 + loopback + 密钥加密存储 + 审计 |
| 真机验收成本 | 按 AGENTS.md 流程（adb 覆盖安装、uiautomator 文本验证）；每阶段先单测后真机 |
| 内存/发热竞争（推理 + 构建） | 构建类任务排队；对齐 oom-guard 教训（docs/bonsai2_opencl_oom_2026-09-27.md） |

---

## 10. 验收标准（Dev 模式端到端）

- [ ] 「把这个仓库克隆到工作区，实现 XXX，跑通测试并提交」→ 完整闭环
- [ ] 切换工作区后，文件工具/记忆/AGENTS.md 全部跟随切换（不串项目）
- [ ] app 重启后任务可恢复（DevContext 从持久化重建）
- [ ] git push / 危险命令触发审批，拒绝时模型收到可读错误并调整
- [ ] 关闭开发模式 = 现有行为完全一致（零回归，test/agent 全绿）
- [ ] Termux 断连自动重连；连接状态 UI 准确

---

## 11. 实施记录（2026-10-01 夜间施工，待用户明早验收）

> 按用户指示"按最优建议开工，能做的全做，明早验证"。方案：A（Termux）+ D（远程 PC），root 排除。
> 核心结论：SSH 只是传输不授权限；权限边界 = 服务端进程（app 沙盒 / Termux 用户态 / root / 远程 PC）。

### 已实施（代码级交付）
- **Phase A 工作区**：`workspace.dart`（DevWorkspace 多后端模型）、`workspace_store.dart`（DevStore 持久化，含 baseDirOverride 可测）、`dev_controller.dart`（激活状态单例）、文件/记忆工具工作区跟随（ToolExecutor workspaceResolver 注入 `_workspaceId` 内部键）。
- **Phase B SSH**：vendored dartssh2 fork（`third_party/dartssh2`，2.11.0 + zlib/批处理优化，源自 DSH-Phone 真机验证）、`ssh_credentials.dart`（SshConfig）、`ssh_environment.dart`（连接/认证/SFTP/TOFU 指纹内存缓存/健壮解码 UTF-8→latin1）、`ssh_tools.dart`（ssh_exec/ssh_read_file/ssh_write_file）、`safety.dart`（危险命令黑名单 deny/ask 策略）。
- **Phase C 计划/验证/提交**：`task.dart`（DevTask/DevPlan 状态机）、`plan_tools.dart`（plan_create/update/list）、`verify_tool.dart`（run_tests）、`git_tools.dart`（status/diff/log/commit/push，push 走审批）、`dev_context.dart`（工作区/计划/记忆注入段 + 开发循环指引）。
- **接线**：`builtin_tools.dart`（kDevToolNames + includeDevTools）、settings_service/provider（devModeEnabled/sshConfig/危险策略）、chat_provider（DevContext 注入 + workspaceResolver + AGENTS.md workspacePath）、settings_screen（开发模式卡：工作区管理/SSH 配置/测试连接/指纹/策略）。
- **测试**：dev_workspace_test（17）/plan_tools_test（13）/ssh_safety_test（8）/dev_context_test（10）/settings_service Dev 组（4）≈ 52 项新增。

### 遗留问题（明早用户确认）
1. **真机验证**：Termux sshd 配置 + 连接测试 + SFTP 读写 + git 闭环（adb install -r -t + uiautomator 文本验证）。
2. **SSH 配置明文存储**：settings JSON 明文保存私钥/密码（对齐 apiModels 先例）；后续迁移 secure storage。
3. **远端 AGENTS.md**：Dev 模式仅注入本地工作区 AGENTS.md；远端（Termux/PC）读取待 Phase D 补 SFTP。
4. **开发工具逐个开关**：MVP 只做总开关（devModeEnabled），git/plan/ssh/verify 无独立开关；后续可细分。
5. **打包验收**：APK 构建 + 字符串级验收（见 AGENTS.md 流程）。
