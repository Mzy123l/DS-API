/// 系统提示词与用户消息的解析规则。
///
/// 约定：`<system>...</system>` **必须出现在输入最开头**才被识别为系统提示词，
/// 出现在其他地方一律按普通文本处理；中间内容允许跨行。
library;

/// 默认系统提示词（没有 `<system>` 标签时使用）。
const String defaultSystemPrompt = 'You are a helpful assistant!';

const String _openTag = '<system>';
const String _closeTag = '</system>';

/// 解析结果：[system] 为 null 表示这次输入没有指定系统提示词。
class ParsedInput {
  const ParsedInput({this.system, required this.text});

  final String? system;

  /// 去掉系统提示词标签后的正文（没有标签时原样返回）
  final String text;
}

/// 从用户输入里拆出开头的 `<system>` 块。
ParsedInput parseSystemPrompt(String raw) {
  final trimmed = raw.trimLeft();
  if (!trimmed.startsWith(_openTag)) return ParsedInput(text: raw);
  final end = trimmed.indexOf(_closeTag, _openTag.length);
  if (end < 0) return ParsedInput(text: raw); // 没闭合 → 当普通文本
  final system = trimmed.substring(_openTag.length, end).trim();
  final text = trimmed.substring(end + _closeTag.length).trim();
  return ParsedInput(system: system.isEmpty ? null : system, text: text);
}

/// 显示用文本：去掉开头的 `<system>` 块（气泡里不展示这段指令）。
String displayTextOf(String content) {
  final parsed = parseSystemPrompt(content);
  return identical(parsed.text, content) ? content : parsed.text;
}

/// 从模型返回的 JSON 里取标题；解析不出来返回 null。
String? parseTitleFromJson(String raw) {
  final match = RegExp(r'"title"\s*:\s*"([^"\n]{1,40})"').firstMatch(raw);
  if (match == null) return null;
  final title = match.group(1)!.trim();
  return title.isEmpty ? null : title;
}
