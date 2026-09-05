# 方案 A：AccessibilityService 驱动的"手机操作"能力 —— 设计与落地

> 状态：草案（备用）。目标：让端侧离线智能体获得"读取/操作当前前台 App 界面"的能力。
> 配套阅读：`docs/agent_light_design.md`、`docs/python_support.md`。

---

## 0. 一句话定位

在 app 沙箱里跑 `shell_exec` 无法跨 App，原语选错了。业界手机侧 agent（Google Gemini /
Project Mariner、三星、GPT-on-Android 等）的标准答案是 **`AccessibilityService`（无障碍）UI 自动化**——
它不是"突破沙箱"，而是 Android **官方授权、无需 root** 的"像人一样操作任意 App"的合法通道。

| 维度 | 现状 `shell_exec` | 方案 A `AccessibilityService` |
|---|---|---|
| 跨 App 操作 | ❌ 不能 | ✅ 能（读/点/输入/滑动任意 App） |
| root | 不需要 | 不需要 |
| 分发 | 需要但没用 | 消费级可分发，用户开一次即可 |
| 安全模型 | 沙箱内空转 | 保留 app 沙箱 + 用户显式授权的增强层 |

---

## 1. 模型能力评估（先想清楚哪些模型能驱动）

**结论：技术上所有模型都能"调用"工具，但"自主可靠地操作手机"能力差距极大，必须按模型分级开放。**

### 1.1 模型分三档（依据 `assets/models_catalog.json` 的 `agentCapabilities`）

| 档位 | 模型 | 工具调用方式 | 驱动手机操作评价 |
|---|---|---|---|
| ① 原生工具调用档（唯一） | `spark-x2.5-4b`（`nativeToolCall=true`, `toolTemplate=spark-native`） | 结构化原生协议 | ✅ **最佳载体** |
| ② prompt 文本协议档 | `gemma-3-4b`、`qwen3.5-2b/4b`、`lfm2.5-2.6b/8b`、`bonsai-8b/27b` | prompt JSON/XML 文本协议 | ⚠️ 看参数 |
| ③ 能力上限 | 0.8B（不推荐）→ 2B → **4B（实用下限）** → 8B → 27B（需 6–10GB RAM） | — | — |

**只有 `spark-x2.5-4b` 是原生工具调用**，其余全部走 `prompt_json_protocol`（priority 0）。

### 1.2 三个核心矛盾（为什么小模型做不好手机操作）

1. **工具调用可靠性**：`prompt_json_protocol.dart` 442 行全在给小模型"格式乱/漏参数/输出 `[fn()]`"打补丁；
   再加 5 个参数更复杂的无障碍工具，2B 级遵循率会进一步塌方。只有 Spark 用原生协议不受拖累。
2. **UI 文本幻觉（最致命）**：`tap` 必须用界面上**真实出现的文本**；≤2B 模型会编造"确认/下一步"等
   看似合理的文本 → 精确匹配失败 → 死循环或放弃。
3. **多步感知-行动循环 + 上下文压力**：手机操作 = read→理解→决策→执行→再 read→适应，需要工作记忆；
   2B 模型上下文仅 4k–8k，一次 `read_screen` 快照就占一大半，推理快速退化。

### 1.3 一个错配：视觉模型没被用上

`gemma-3-4b`、`qwen3.5-2b`、`qwen3.5-4b` 都是 **vision 模型**，但 `read_screen` 只提取文本，
**完全没用上视觉能力**。视觉模型的真优势是理解纯图标/无文本 UI、按视觉位置定位元素。
→ 对视觉模型，**截图式交互**（二期 `MediaProjection`）比文本提取更契合。

### 1.4 分模型结论

| 模型 | 能否驱动手机操作 | 说明 |
|---|---|---|
| Spark-X2.5-4B | ✅ 最佳 | 唯一原生工具调用 + 智能体优化 + 百万上下文 |
| Bonsai-8B / LFM-8B | ✅ 良好 | 智能体优化，多步推理够用；Bonsai-8B 仅 1.2GB 轻量 |
| Gemma3-4B / Qwen3.5-4B | ⚠️ 可用（截图路线更佳） | 4B 是实用下限 |
| Qwen3.5-2B / LFM-2.6B | ⚠️ 仅约束单步，需人工确认 | 失败率偏高 |
| Qwen3.5-0.8B | ❌ 不建议开手机操作 | 工具遵循幻觉严重 |

---

## 2. 能力边界（设计里写死，避免模型盲目尝试）

**能做**：遍历任意前台 App 的 UI 节点、读可见文本/描述、点击/长按/输入文字/滚动、返回/Home/最近任务。

**不能做**（必须优雅降级为"读不到/操作失败"，绝不崩溃）：
- 无法绕过登录/验证码/支付密码（没有 UI 节点就没有可点对象）。
- 屏幕熄灭/锁屏时多数操作失效（需先唤醒解锁）。
- 部分 App（银行/支付/部分 IM）反无障碍检测 → 返回空。
- 截屏是**另一套权限体系**（`MediaProjection`，需前台服务 + 运行时权限 + Android 14 前台特殊类型），
  复杂度高一档，**二期**。

---

## 3. 总体分层（对齐现有架构）

```
模型 → PromptJsonProtocol/native-tools(工具段) → AgentLoop → AccessibilityTool(Dart)
        ↓ MethodChannel: com.dgxspark.tongyilite/accessibility
Kotlin: AccessibilityHelper(AccessibilityService) → MethodChannel handler
        ↓
Android AccessibilityService 框架 → UI 节点树 / performAction
```

- **原生层**：`AccessibilityHelper.kt`（`AccessibilityService` 子类）+ `AndroidManifest.xml` 注册 +
  `MainActivity` 内新增 `MethodChannel(".../accessibility")`（跟 `.../python` 同款写法）。
- **Dart 层**：`lib/agent/builtin_tools/accessibility_tool.dart`（`ToolDefinition`，跟 `python_tool.dart`
  同款 `MethodChannel` 调用 + 超时 + 截断 + 错误映射）。
- **协议层**：注册工具被 `PromptJsonProtocol.buildToolSection` 自动注入；另加"手机操作"使用引导。
- **注册/启用**：加入 `kOptionalToolNames`（默认关，设置开启后见），在 `createBuiltinTools()` 注册。

---

## 4. 原生层实现（Kotlin）

### 4.1 `AccessibilityHelper.kt`（核心骨架）

```kotlin
package com.dgxspark.tongyilite

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/** 无障碍服务：把"任意 App 的 UI"暴露给 agent。与 InferenceService 同级。 */
class AccessibilityHelper : AccessibilityService() {

    companion object {
        const val TAG = "AccessibilityHelper"
        const val MAX_NODES = 300      // 单次快照最大节点数（防 UI 树过大塞爆上下文）
        const val MAX_TEXT_LEN = 200

        /** 用户是否在系统设置里启用了本无障碍服务。 */
        fun isEnabled(context: Context): Boolean {
            val thisComponent = "${context.packageName}/$AccessibilityHelper::class.java.name"
            val enabled = Settings.Secure.getString(context.contentResolver, "accessibility_enabled")
                ?: return false
            return enabled.contains(thisComponent)
        }

        /** 引导用户到「设置 > 无障碍」页面（App 内无法自动开启）。 */
        fun guideToSettings(context: Context) {
            context.startActivity(
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    override fun onServiceConnected(config: AccessibilityServiceInfo) {
        super.onServiceConnected(config)
        config.eventTypes = AccessibilityServiceInfo.ALL_EVENTS
        config.notificationTimeout = 100
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            config.responsePolicy = AccessibilityNodeInfo.RESPONSE_POLICY_HANDLE_ALL // API30+
        }
        Log.i(TAG, "service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event?.let { ev ->
            if (ev.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                updateSnapshotIfNeeded() // 带节流，见第 7 节
            }
        }
    }

    override fun onInterrupt(reason: CharSequence?) {}

    // ---- 供 MethodChannel 调用的能力 ----

    /** 取当前前台界面的归一化文本快照（供 read_screen）。 */
    fun getForegroundSnapshot(): String {
        val root = focusedNode ?: getRootNode()
            ?: return "（无法读取界面：请先打开目标 App 并点亮屏幕）"
        val sb = StringBuilder()
        collectText(root, sb, 0)
        return sb.toString().trim()
    }

    /** 按文本匹配点击（优先第一个匹配）。 */
    fun tapByText(text: String): Boolean {
        val node = findAccessibilityNodeInfosByText(text).firstOrNull() ?: return false
        return node.performAction(AccessibilityNodeInfo.ACTION_CLICK).also { node.recycle() }
    }

    /** 输入文字（替代键盘打字）。 */
    fun typeText(text: String): Boolean {
        val args = Bundle().apply { putString(AccessibilityNodeInfo.ActionInfo.ARGS_TEXT, text) }
        return focusedNode?.performAction(AccessibilityNodeInfo.ACTION_TEXT, args)
            ?: performGlobalAction(AccessibilityNodeInfo.ACTION_TEXT) // API26+
    }

    fun scrollUp(): Boolean = focusedNode
        ?.performAction(AccessibilityNodeInfo.ACTION_SCROLL)
        ?.apply { if (this) sendScrollEvent() } ?: false

    fun goBack() = performGlobalAction(AccessibilityNodeInfo.ACTION_BACK)
    fun goHome() = performGlobalAction(AccessibilityNodeInfo.ACTION_NAVIGATION_HOME)
    fun goRecent() = performGlobalAction(AccessibilityNodeInfo.ACTION_NAVIGATION_RECENTS)

    private val focusedNode: AccessibilityNodeInfo?
        get() = focusedNode ?: getRootNode()

    private fun collectText(node: AccessibilityNodeInfo, sb: StringBuilder, depth: Int) {
        if (depth > MAX_NODES) return
        val text = node.text
        if (!text.isNullOrEmpty() && !isSensitive(node)) {
            sb.append("· ").append(text.take(MAX_TEXT_LEN)).append('\n')
        }
        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { collectText(it, sb, depth + 1); it.recycle() }
        }
    }

    /** 隐私红线：密码框/敏感字段不入模型。 */
    private fun isSensitive(node: AccessibilityNodeInfo): Boolean =
        node.viewIdResourceName.contains("password", ignoreCase = true) ||
            node.className?.toString() == "android.widget.EditText"

    private fun logI(m: String) = Log.i(TAG, m)
}
```

> 坐标点击（`tapAt`）在无障碍框架没有直接 API，需 `InputManager`（需 `INJECT_EVENTS` 系统签名权限）
> 或模拟手势 —— **v1 只提供"按文本点击"**，坐标点击/手势放二期或用 `am input tap`（ADB 桥）。
> `typeText` 全局注入在部分 ROM 行为不一致，需实测；退路是聚焦到可编辑节点再注入。

### 4.2 注册到 `AndroidManifest.xml`（在 `<application>` 内追加）

```xml
<service
    android:name=".AccessibilityHelper"
    android:exported="true"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService" />
    </intent-filter>
    <meta-data
        android:name="android.accessibilityservice"
        android:resource="@xml/accessibility_service_config" />
</service>
```

资源文件 `android/app/src/main/res/xml/accessibility_service_config.xml`：

```xml
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:eventTypes="windowStateChanged|windowContentChanged|uiChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows|flagReportViewIds"
    android:notificationTimeout="100"
    android:description="允许 TongYi-Lite 的智能体读取并操作你手机上其他 App 的界面。" />
```

> `targetSdk=36` 下 `android:exported="true"` 必须显式声明（与现有清单风格一致）。

### 4.3 在 `MainActivity.kt` 注册 MethodChannel

在 `configureFlutterEngine` 里、`.../python` 通道旁边加：

```kotlin
MethodChannel(
    flutterEngine.dartExecutor.binaryMessenger,
    "com.dgxspark.tongyilite/accessibility"
).setMethodCallHandler { call, result ->
    when (call.method) {
        "isAvailable" -> result.success(if (AccessibilityHelper.isEnabled(this)) "ok" else "DISABLED")
        "guide"       -> AccessibilityHelper.guideToSettings(this); result.success(null)
        "snapshot"    -> result.success(AccessibilityHelper().foregroundSnapshotSafe())
        "tapText"     -> result.success(AccessibilityHelper().tapByText(call.argument<String>("text")!!))
        "typeText"    -> result.success(AccessibilityHelper().typeText(call.argument<String>("text")!!))
        "scroll"      -> result.success(AccessibilityHelper().scrollUp())
        "back"        -> result.success(AccessibilityHelper().goBack())
        "home"        -> result.success(AccessibilityHelper().goHome())
        "recent"      -> result.success(AccessibilityHelper().goRecent())
        else          -> result.notImplemented()
    }
}
```

---

## 5. Dart 工具层实现（`accessibility_tool.dart`）

完全照 `python_tool.dart` 套路：`MethodChannel` + 超时 + 截断 + 错误码映射。
对端侧小模型推荐**少量、命名明确的工具**（减少提示词噪声、提高遵循率）：

| 工具 | 用途 |
|---|---|
| `read_screen` | 读取当前前台界面文本 |
| `tap` | 按控件文本点击 |
| `type_text` | 向当前焦点输入文字 |
| `scroll_view` | 向上滚动当前界面 |
| `press_key` | back / home / recent（action 枚举） |

每个工具 `execute`：`invokeMethod` → 超时 `kToolTimeout`（15s）→ 成功返回文本，失败按错误码
（`DISABLED`/`NOT_FOUND`/`TIMEOUT`/平台异常）映射为可读 `ToolResult`。
**关键**：失败信息要告诉模型"下一步怎么办"（如没读到界面 → 提示"先打开目标 App"）。

---

## 6. 协议 / 提示词

工具注册后即被 `PromptJsonProtocol.buildToolSection` 自动注入描述。
额外在提示词里加"手机操作"引导（新常量 `kAccessibilityInstruction`），教小模型正确顺序：

```
[手机操作]
可读取/操作当前前台 App 的界面：
- 先 read_screen 看当前界面有哪些可点文本
- 再 tap（用界面上真实出现的文本）操作
- 找不到目标文本说明没在正确的界面：先 press_key home 回到桌面，打开目标 App，再 read_screen
- 不要编造界面上不存在的文本去 tap
```

（沿用你们已有的"收到工具结果后组织最终回答"约定。）

---

## 7. 授权与首次运行流程

无障碍服务 **App 无法自行开启**，必须由用户在系统设置里开。

```
Agent 调用 read_screen/tap
  → isAvailable == "DISABLED"
  → 工具返回："手机操作未授权，请前往 设置>无障碍 开启 TongYi-Lite"
  → 同时 App 内弹引导页 + "去开启"按钮（调用 guideToSettings）
```

- **粗粒度门**：系统设置开关（天然的用户授权）。
- **App 内二次同意**：第一次引导时明确告知"将允许读取/操作其他 App 界面"，用户点同意再引导去设置。
- **状态常驻检查**：每次调用前 `isAvailable`，关闭时立即反馈，不静默失败。
- 与 `SandboxMode` 审批是**不同维度**：sandbox 是"单次文件访问升级"，无障碍是"常开能力 + 一次性授权"。

---

## 8. 安全与隐私设计（红线）

1. **数据最小化**：只把归一化可见文本送给模型，不送原始节点树（不含包名/坐标/隐私 content-desc）。
2. **敏感字段红线下沉到原生层**：`isSensitive()` 把密码框/`EditText` 在原生侧直接跳过，
   模型永远看不到（不依赖 Dart 层过滤，避免隐私先进 Dart 内存）。
3. **前台上下文提示**：快照里标注当前 `packageName`/界面标题，让模型知道"现在在哪个 App"。
4. **屏幕状态门**：屏幕熄灭/锁屏时直接返回"屏幕已锁，请先解锁"，不空转。
5. **操作审计日志**：每次 `performAction` 写一条到 app workspace（`{time, action, target}`），
   用户可在设置里查看"智能体刚才动了什么"（信任基础）。
6. **节流防抖**：`onAccessibilityEvent` 高频，`updateSnapshotIfNeeded` 加时间窗（如 500ms）。
7. **异常 App 降级**：反无障碍检测的 App 返回空 → 工具返回明确"该界面不可读取"，模型据此放弃。
8. **默认关闭 + 按模型可见性**：进 `kOptionalToolNames`，且可被 `ToolRegistry.restrictModel`
   对特定模型隐藏（未成年模型默认禁用手机操作）。

---

## 9. 测试策略

无障碍难点在原生交互难单测，测试要分层：

- **纯函数优先（可单测）**：UI 树→文本归一化、敏感字段过滤、action 映射抽成无 Android 依赖的纯函数，
  Kotlin 侧给纯逻辑写 `unitTest`，Dart 侧做参数校验/错误映射的 `flutter_test`。
- **Dart 层**：mock `MethodChannel`（`TestDefaultBinaryMessengerBinding`）测 `execute` 的成功/超时/错误映射。
- **原生层**：`androidx.test` 的 `AccessibilityServiceTest` + `FakeAccessibilityService` 跑 Instrumentation test。
- **真机 E2E**：P1 完成后，手动"打开设置 → 让 agent read_screen → tap 某个开关"走通最小链路。

---

## 10. 模型门控策略（让方案与端侧模型协作得好）

**核心：别做成"所有模型通用"，做成"按模型能力分级开放"。**

1. **按模型门控**：手机操作工具只对 **4B+**（尤其 Spark-X2.5-4B、Bonsai-8B、LFM-8B）开放，
   0.8B–2B 默认关闭或限单步。用 `ToolRegistry.restrictModel(modelId, deny = setOf("read_screen", ...))`。
2. **让 Spark 走原生工具调用**：它本就被 `protocol_selector` 自动切到 native-tools 协议，
   可靠性远高于文本协议。
3. **视觉模型走截图路线**：Gemma3/Qwen3.5 视觉模型用 `MediaProjection` 截屏让模型"看"界面（二期）。
4. **收敛工具 + 人工确认**：先收敛成"读 + 1~2 高频动作"；高风险动作（改系统设置/发消息/装东西）
   走 `AgentSandboxApprover` 逐次人工确认；强制"先 read 再 action"。
5. **上下文瘦身**：`read_screen` 只回传关键文本（`MAX_NODES` 截断）。

---

## 11. 分阶段路线图 + 工作量

| 阶段 | 内容 | 交付 | 估算 |
|---|---|---|---|
| P0 前置 | 澄清 `shell_exec` 在 Android 上实际可用的 shell（大概率无 `sh`），文件操作统一走 `python_exec` | shell 能力澄清 + 文档 | 0.5d |
| P1 核心闭环 | `AccessibilityHelper` + manifest + MethodChannel + `read_screen`/`tap`/`press_key` 3 工具 + 首次授权引导 + 审计日志 | 能"读界面→按文本点"走通 | 2–3d |
| P2 补全 | `type_text`、`scroll_view`、前台上下文标注、敏感过滤完善、节流 | 支持输入/长页面 | 1.5d |
| P3 鲁棒性 | 反无障碍 App 降级、屏幕锁门、UI 变更容错、Instrumentation 测试 | 真机稳定 | 2d |
| P4 二期（可选） | `MediaProjection` 截屏（`screenshot` 工具，供"看界面图"）、坐标点击/手势、`am input` ADB 桥 | 能力扩展 | 3–4d |

**最小可用（P1）约 2.5 天**可拿到一条可演示的"智能体操作其他 App"链路。

---

## 12. 风险与已知坑

- **UI 脆弱性**：节点依赖界面结构，App 升级/文案变就会失效。对策：`tap` 支持"多候选模糊匹配"，
  失败时 read 新界面重试（模型循环天然支持）。
- **ROM 差异**：MIUI/ColorOS/EMUI 对无障碍有额外限制（后台限制、自启动），需适配白名单。
- **`typeText` 全局注入**在部分 ROM 不一致；退路是聚焦到可编辑节点再注入。
- **`ACTION_TEXT`/`ACTION_NAVIGATION_HOME`** 需 API26+/30+，`minSdk=33` 满足，但低版本兜底要写。
- **截屏（MediaProjection）**别在 P1 碰 —— 独立的高复杂度权限线。
- **不要做成"万能 root"**：保持"保留 app 沙箱 + 用户授权增强层"定位，这是可分发、可信任的前提。

---

## 附录：关键决策清单

- [ ] 模型门控：4B+ 开放，0.8B–2B 限单步/关闭（`restrictModel`）
- [ ] Spark 走原生工具调用协议
- [ ] 视觉模型二期接截图（MediaProjection）
- [ ] 高风险动作走 AgentSandboxApprover 人工确认
- [ ] 敏感字段过滤下沉到原生层
- [ ] 操作审计日志
- [ ] 首次运行"去设置开启"引导
