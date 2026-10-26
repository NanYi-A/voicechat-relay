import 'dart:typed_data';
import 'package:dio/dio.dart';

/// M6 · 云端 TTS 转发（手机 → 云 /api/tts → 电脑 CosyVoice）
class TtsService {
  final Dio _dio;
  final String cloudUrl;
  final String token;
  TtsService(this._dio, this.cloudUrl, this.token);

  /// 返回句级 WAV 字节；电脑离线抛 Exception('tts_unavailable')
  Future<Uint8List> synthesize({
    required String charId,
    String? text,
    required String voice,
    List<String>? texts,
  }) async {
    final Map<String, dynamic> data = {
      'char_id': charId,
      'voice': voice,
    };
    if (texts != null) {
      data['texts'] = texts;
    } else {
      data['text'] = text ?? '';
    }
    final resp = await _dio.post(
      '$cloudUrl/api/tts',
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 150),
      ),
      data: data,
    );
    if (resp.statusCode == 200) {
      return Uint8List.fromList(resp.data as List<int>);
    } else if (resp.statusCode == 503) {
      throw Exception('tts_unavailable');
    } else {
      throw Exception('tts_error_${resp.statusCode}');
    }
  }
}
