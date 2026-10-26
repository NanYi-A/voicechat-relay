import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/character.dart';
import '../services/database.dart';
import '../services/secure_storage.dart';
import '../services/voices.dart';

/// 全局状态：配置 + 角色列表
class AppState extends ChangeNotifier {
  List<Character> _characters = [];
  String? _deepseekKey;
  String _cloudUrl = 'http://192.168.1.8:8000';
  String _cloudToken = '';
  bool _initialized = false;
  String? _accountId;

  List<Character> get characters => _characters;
  String? get deepseekKey => _deepseekKey;
  String get cloudUrl => _cloudUrl;
  String get cloudToken => _cloudToken;
  bool get initialized => _initialized;

  Future<void> init() async {
    _deepseekKey = await SecureStorage.deepseekKey;
    final url = await SecureStorage.cloudUrl;
    final token = await SecureStorage.cloudToken;
    final accountId = await SecureStorage.accountId;
    _accountId = accountId;
    if (url != null && url.trim().isNotEmpty) _cloudUrl = url.trim();
    if (token != null && token.trim().isNotEmpty) _cloudToken = token.trim();
    // 按账号隔离：切换账号前先打开对应本地库，结构性隔离角色/聊天/记忆等全部本地数据
    if (accountId != null && accountId.trim().isNotEmpty) {
      await DatabaseHelper.instance.setAccount(accountId.trim());
    }
    await loadCharacters();
    await fetchVoices();
    _initialized = true;
    notifyListeners();
  }

  /// M3：拉取本账号音色并落库；顺带把旧角色里裸音色名(voice_a/voice_b)迁移到带命名空间的 remote_name。
  Future<void> fetchVoices() async {
    if (_cloudToken.isEmpty) return;
    try {
      final svc = VoiceService(Dio(), _cloudUrl, _cloudToken);
      final vs = await svc.fetch();
      for (final v in vs) {
        await DatabaseHelper.instance.upsertVoice({
          'id': v['remote_name'],
          'name': v['name'] ?? v['remote_name'],
          'remote_name': v['remote_name'],
          'status': v['status'] ?? 'active',
          'created_at': v['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
        });
      }
      // 迁移旧角色 defaultVoice：统一命名空间为当前账号 ID。
      // 无论旧值是裸名(voice_a)、错误前缀(other::voice_a)还是正确前缀，都归一成 <accountId>::<bare>。
      if (_accountId != null && _accountId!.isNotEmpty) {
        for (final c in _characters) {
          final dv = c.defaultVoice;
          if (dv == null || dv.isEmpty) continue;
          final bare = dv.contains('::') ? dv.split('::').last : dv;
          final target = '$_accountId::$bare';
          if (target != dv) {
            await DatabaseHelper.instance.updateCharacterVoice(c.id, target);
            c.defaultVoice = target;
          }
        }
      }
      notifyListeners();
    } catch (_) {
      // 离线或失败不影响其余功能
    }
  }

  Future<void> loadCharacters() async {
    _characters = await DatabaseHelper.instance.getCharacters();
    notifyListeners();
  }

  Future<void> addCharacter(Character c) async {
    await DatabaseHelper.instance.insertCharacter(c);
    await loadCharacters();
  }

  Future<void> updateCharacter(Character c) async {
    await DatabaseHelper.instance.updateCharacter(c);
    await loadCharacters();
  }

  Future<void> deleteCharacter(String id) async {
    await DatabaseHelper.instance.deleteCharacter(id);
    await loadCharacters();
  }

  /// M1：登出 -> 清云端 token + 当前账号标识，关闭账号库（其他账号库文件不受影响）
  Future<void> logout() async {
    await SecureStorage.clearCloudToken();
    _cloudToken = '';
    _characters = [];
    _initialized = false;
    await DatabaseHelper.instance.resetAccount();
    notifyListeners();
  }
}
