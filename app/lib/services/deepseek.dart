import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';

/// §7.5 Prompt Caching：人格 + 记忆摘要 + 格式要求构成字节级稳定的缓存前缀。
/// DeepSeek 官方自动缓存跨请求的相同前缀（命中计费约 1/10），
/// 聊天与主动消息都必须用同一份构造，才能共享同一段缓存。
/// ⚠️ 前缀内容不得包含任何随请求变化的内容（时间戳、随机数等）。
class PromptPrefix {
  static String build(String personaMd, String? memorySummary) {
    final system = StringBuffer();
    system.write(personaMd);
    if (memorySummary != null && memorySummary.isNotEmpty) {
      system.write('\n## 对用户了解\n$memorySummary');
    }
    system.write(
        '\n\n【格式要求——必须严格遵守】\n'
        '1. 每句话之间必须用 `/` 分隔（示例：你好/今天天气真好/你想去哪里玩？）\n'
        '   ⚠️ 绝对不要用逗号、句号或换行来分句，只用 `/`\n'
        '2. URL 用 `[链接]` 包裹\n'
        '3. 可选：在两句文字中间插入 /<emotion>标签</emotion>/ 段来发表情包（示例：是吗/<emotion>happy</emotion>/那太好了）\n'
        '4. ⚠️【强制】回复最末尾必须追加当前情绪标签，格式：["标签"]\n'
        '   标签只能从这19个里选：happy/sad/angry/surprised/tired/shy/loved/confused/awkward/fear/goofy/evasive/reminded/stare/provoke/confirm/speechless/thumbsup/pathead\n'
        '   示例完整回复：原来是这样啊/我还以为我天赋异禀呢["happy"]\n'
        '   ⚠️ 每条回复末尾必须有["标签"]，不能省略！\n'
        '5. 遵守人格设定，结合记忆');
    return system.toString();
  }
}

/// M5 · DeepSeek 流式聊天（手机直连）
class DeepSeekService {
  static const _endpoint = 'https://api.deepseek.com/v1/chat/completions';

  final Dio _dio;
  DeepSeekService(this._dio);

  /// 返回原始增量文本流（含 '/' 与 `<emotion>` 标签），由调用方定稿气泡
  Stream<String> streamChat({
    required String apiKey,
    required String personaMd,
    required List<Map<String, String>> history,
    required String userText,
    String? memorySummary,
  }) async* {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': PromptPrefix.build(personaMd, memorySummary)},
      ...history,
      {'role': 'user', 'content': userText},
    ];

    final resp = await _dio.post(
      _endpoint,
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.stream,
      ),
      data: {
        'model': 'deepseek-v4-flash',
        'messages': messages,
        'stream': true,
        'temperature': 0.9,
      },
    );

    final body = resp.data;
    if (body is! ResponseBody) {
      throw Exception('unexpected_response');
    }
    final stream = body.stream;
    String buffer = '';
    await for (final chunk in stream) {
      buffer += utf8.decode(chunk, allowMalformed: true);
      final lines = buffer.split('\n');
      buffer = lines.removeLast(); // 保留未完成的行
      for (final line in lines) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final jsonStr = trimmed.substring(5).trim();
        if (jsonStr == '[DONE]') continue;
        try {
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          final delta = data['choices']?[0]?['delta']?['content'] as String?;
          if (delta != null && delta.isNotEmpty) yield delta;
        } catch (_) {
          // 忽略无法解析的片段
        }
      }
    }
  }
}
