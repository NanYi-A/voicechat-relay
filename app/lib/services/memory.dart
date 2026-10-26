import 'package:dio/dio.dart';

/// §8 记忆摘要：非流式调 DeepSeek，把早期对话压缩为 ≤300 字摘要
class MemoryService {
  static const _endpoint = 'https://api.deepseek.com/v1/chat/completions';
  final Dio _dio;
  MemoryService(this._dio);

  /// 输入：需要总结的历史消息（role/content 列表）
  /// 输出：≤300 字中文摘要
  Future<String> summarize({
    required String apiKey,
    required List<Map<String, String>> messages,
  }) async {
    final conversation = messages
        .map((m) => '${m['role'] == 'user' ? '用户' : 'AI'}：${m['content']}')
        .join('\n');

    final resp = await _dio.post(
      _endpoint,
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        receiveTimeout: const Duration(seconds: 60),
      ),
      data: {
        'model': 'deepseek-v4-flash',
        'messages': [
          {
            'role': 'system',
            'content': '你是一个对话摘要助手。请把以下对话压缩为不超过300字的中文摘要，'
                '重点保留：用户的个人信息、偏好、重要事件、情感状态、未解决的话题。'
                '用第三人称（"用户"）描述。不要输出任何多余解释，直接输出摘要。',
          },
          {'role': 'user', 'content': conversation},
        ],
        'temperature': 0.3,
        'max_tokens': 600,
      },
    );

    final data = resp.data as Map<String, dynamic>;
    final content = data['choices']?[0]?['message']?['content'] as String? ?? '';
    // 硬截断保底（模型偶尔超限）
    return content.length > 300 ? content.substring(0, 300) : content;
  }
}
