import 'package:dio/dio.dart';

/// M7 · 云端在线状态（电脑守护是否反连）
class StatusService {
  final Dio _dio;
  final String cloudUrl;
  final String token;
  StatusService(this._dio, this.cloudUrl, this.token);

  Future<bool> getOnline() async {
    try {
      final resp = await _dio.get(
        '$cloudUrl/api/status',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = resp.data;
      if (data is Map && data['online'] == true) return true;
      return false;
    } catch (_) {
      return false;
    }
  }
}
