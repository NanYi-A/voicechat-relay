import 'package:dio/dio.dart';

/// M1 · 云端账号：自注册 / 登录，换取 token + user_id
class AuthResult {
  final String userId;
  final String token;
  AuthResult({required this.userId, required this.token});
}

/// M1 · 云端账号：自注册 / 登录，换取 token
class AuthService {
  final Dio _dio;
  final String cloudUrl;
  AuthService(this._dio, this.cloudUrl);

  Future<AuthResult> register(String username, String password) async {
    try {
      final resp = await _dio.post('$cloudUrl/api/register',
          data: {'username': username, 'password': password});
      return AuthResult(
        userId: resp.data['user_id'] as String,
        token: resp.data['token'] as String,
      );
    } on DioException catch (e) {
      final sc = e.response?.statusCode;
      final msg = e.response?.data is Map
          ? (e.response!.data['detail']?.toString() ?? '注册失败')
          : '注册失败';
      if (sc == 409) throw Exception('用户名已存在');
      if (sc == 400) throw Exception(msg);
      throw Exception(msg);
    }
  }

  Future<AuthResult> login(String username, String password) async {
    try {
      final resp = await _dio.post('$cloudUrl/api/login',
          data: {'username': username, 'password': password});
      return AuthResult(
        userId: resp.data['user_id'] as String,
        token: resp.data['token'] as String,
      );
    } on DioException catch (e) {
      final msg = e.response?.data is Map
          ? (e.response!.data['detail']?.toString() ?? '登录失败')
          : '登录失败';
      throw Exception(msg);
    }
  }
}
