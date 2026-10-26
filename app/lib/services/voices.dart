import 'dart:typed_data';
import 'package:dio/dio.dart';

/// M3 · 拉取当前账号的音色列表（按 user_id 隔离）+ 克隆
class VoiceService {
  final Dio _dio;
  final String cloudUrl;
  final String token;
  VoiceService(this._dio, this.cloudUrl, this.token);

  Future<List<Map<String, dynamic>>> fetch() async {
    final resp = await _dio.get('$cloudUrl/api/voices',
        options: Options(headers: {'Authorization': 'Bearer $token'}));
    final list = (resp.data['voices'] as List? ?? []);
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// §11 音色克隆：上传 WAV + 手填文本 → 云端推电脑注册 → 返回 remote_name
  Future<Map<String, dynamic>> clone({
    required Uint8List wavBytes,
    required String fileName,
    required String text,
    required String voiceName,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(wavBytes, filename: fileName),
      'text': text,
      'voiceName': voiceName,
    });
    final resp = await _dio.post(
      '$cloudUrl/api/voice/clone',
      data: form,
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        receiveTimeout: const Duration(seconds: 150),
      ),
    );
    return Map<String, dynamic>.from(resp.data as Map);
  }
}
