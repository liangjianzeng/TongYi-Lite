/// 系统提示分段组装 —— 参照 DSH `system-prompt` 的分段思想，简化为三段：
/// 身份(identity) → 工具指引 → 工具清单（由协议呈现）。
///
/// 分段注册表预留：未来第三方/自定义分段可扩展（参照 DSH `section({name, order, text})`），
/// 此处先做最简拼接。
library;

import 'protocol/tool_protocol.dart';
import 'tool_registry.dart';

/// 组装系统提示。
///
/// [modelName] 模型名（身份段变量注入）；
/// [registry] 工具注册表；
/// [protocol] 决定工具呈现方式（原生 tools 协议可返回空段，工具走请求体）；
/// [modelId] 按模型渲染可见工具清单。
String buildSystemPrompt({
  required String modelName,
  required ToolRegistry registry,
  required ToolProtocol protocol,
  String modelId = '',
}) {
  final toolSection = protocol.buildToolSection(registry, modelId: modelId);
  final sections = <String>[
    // 身份段：明确「工具型智能体」定位。
    '你是 TongYi-Lite 智能体，由 $modelName 模型驱动。'
    '你能调用工具获取真实信息或精确计算结果。',

    // 工具指引段：给出触发规则（覆盖所有工具场景，强调「必须调用」而非
    // 「假装执行」——小模型常见的错误是只在回答里描述操作而不真正调用）。
    '【工具调用规则】\n'
    '1. 以下场景你必须先调用工具，再根据真实结果回答，'
    '绝不能假装已执行或编造结果：\n'
    '   - 实时信息（时间/日期/天气/搜索）→ 调用 get_time / get_weather / web_search\n'
    '   - 计算/换算 → 调用 calculator / unit_converter\n'
    '   - 待办/便签/记忆 → 调用 todo_write / note_take / memory_set\n'
    '   - 读写工作区文件 → 调用 read_file / write_file / edit_file\n'
    '2. 调用工具时只输出一个工具调用块（格式见下方），'
    '不要思考过程、不要多余文字、不要先回答再"补充"调用。\n'
    '3. 首次调用工具就必须一次性给出全部必填参数（工具清单已标注必填项），'
    '绝不要空着必填参数或只填部分参数——那样会执行失败并浪费算力；'
    '信息不足时先向用户确认，再一次性调用。\n'
    '4. 收到工具结果后，根据真实结果组织最终回答；'
    '若工具不可用或失败，如实告知用户。\n'
    '5. 不需要工具时直接回答用户。',
    if (toolSection.isNotEmpty) toolSection,
  ];
  return sections.join('\n\n');
}
