import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// M1 · 安全存储：DeepSeek key / 云地址 / 云端 token（自注册签发，非固定）
/// 存于系统 Keystore/Keychain，卸载重装需重填（P3 再做备份）。
class SecureStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kDeepseek = 'deepseek_key';
  static const _kCloudUrl = 'cloud_url';
  static const _kCloudToken = 'cloud_token';
  static const _kAccountId = 'account_id';

  static Future<void> writeAll({
    required String deepseekKey,
    required String cloudUrl,
    required String cloudToken,
    required String accountId,
  }) async {
    await _storage.write(key: _kDeepseek, value: deepseekKey);
    await _storage.write(key: _kCloudUrl, value: cloudUrl);
    await _storage.write(key: _kCloudToken, value: cloudToken);
    await _storage.write(key: _kAccountId, value: accountId);
  }

  static Future<void> clearCloudToken() async {
    await _storage.delete(key: _kCloudToken);
    await _storage.delete(key: _kAccountId);
  }

  static Future<String?> get deepseekKey => _storage.read(key: _kDeepseek);
  static Future<String?> get cloudUrl => _storage.read(key: _kCloudUrl);
  static Future<String?> get cloudToken => _storage.read(key: _kCloudToken);
  static Future<String?> get accountId => _storage.read(key: _kAccountId);

  /// 是否已配置：DeepSeek key 存在 且 云端 token 不是 P0 遗留的固定 token
  static Future<bool> get isConfigured async {
    final k = await _storage.read(key: _kDeepseek);
    final t = await _storage.read(key: _kCloudToken);
    if (k?.trim().isEmpty ?? true) return false;
    if (t == 'p0-dev-token-change-me') return false;
    return true;
  }
}
