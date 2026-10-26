import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'deepseek.dart';

/// §16 AI 主动消息：前台服务保活 + 定时调度 + 内容生成 + 本地通知
///
/// flutter_foreground_task 的回调跑在独立 isolate，不能访问主 isolate 的
/// Provider/全局变量，所以这里直接开 DB + 直连 DeepSeek。
/// DeepSeek key 由主 isolate 写到 documents/.deepseek_key_cache 供本 isolate 读。

class ProactiveTaskHandler extends TaskHandler {
  static final _rng = Random();
  static final _localNotif = FlutterLocalNotificationsPlugin();
  static bool _notifInited = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _initNotif();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _checkAndTrigger();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  // ---------- 通知初始化 ----------
  Future<void> _initNotif() async {
    if (_notifInited) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _localNotif.initialize(
      const InitializationSettings(android: androidInit),
    );
    _notifInited = true;
  }

  // ---------- 调度主循环 ----------
  Future<void> _checkAndTrigger() async {
    try {
      final db = await _openDb();
      if (db == null) return;
      try {
        final chars = await db.query('characters');
        for (final row in chars) {
          final charId = row['id'] as String;
          final settings = await _getSettings(db, charId);
          if (settings == null) continue;
          if ((settings['enabled'] as int? ?? 0) != 1) continue;
          await _maybeTrigger(db, charId, row['name'] as String? ?? '', settings);
        }
      } finally {
        await db.close();
      }
    } catch (e) {
      print('[proactive] error: $e');
    }
  }

  Future<Database?> _openDb() async {
    try {
      final dbDir = await getDatabasesPath();
      final dir = Directory(dbDir);
      if (!dir.existsSync()) return null;
      // 找 voicechat 开头的 db 文件（取最近修改的）
      final dbFiles = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('voicechat') && f.path.endsWith('.db'))
          .toList();
      if (dbFiles.isEmpty) return null;
      dbFiles.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      // ⚠️ 必须 singleInstance:false！sqflite 原生端用进程级静态表按 path 共享实例，
      // 默认 true 会让本后台 isolate 拿到主 isolate 的同一个原生连接，
      // 之后的 db.close() 会把主 isolate 正在用的库关掉（database_closed）。
      return openDatabase(dbFiles.first.path, singleInstance: false);
    } catch (_) {
      return null;
    }
  }

  // ---------- 设置读取 ----------
  Future<Map<String, dynamic>?> _getSettings(Database db, String charId) async {
    final rows = await db.query('proactive_settings', where: 'char_id = ?', whereArgs: [charId]);
    return rows.isEmpty ? null : rows.first;
  }

  // ---------- 触发判定 ----------
  Future<void> _maybeTrigger(Database db, String charId, String charName, Map<String, dynamic> s) async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;

    // 跨日懒重置
    final today = _dateStr(now);
    final proactiveDate = s['proactive_date'] as String? ?? '';
    var todayCount = s['today_count'] as int? ?? 0;
    if (proactiveDate != today) {
      todayCount = 0;
      await db.update('proactive_settings',
          {'today_count': 0, 'proactive_date': today},
          where: 'char_id = ?', whereArgs: [charId]);
    }

    // 静默时段
    final quietStart = s['quiet_start'] as int? ?? 1260;
    final quietEnd = s['quiet_end'] as int? ?? 420;
    if (_inQuiet(now, quietStart, quietEnd)) return;

    // 每日上限
    final dailyCap = s['daily_cap'] as int? ?? 5;
    if (todayCount >= dailyCap) return;

    // 触发时间判定
    final lastTrigger = s['last_trigger'] as int? ?? 0;
    final lastChat = await _lastChatTime(db, charId);
    final base = max(lastTrigger, lastChat);
    final minH = (s['min_hours'] as num?)?.toDouble() ?? 2.0;
    final maxH = (s['max_hours'] as num?)?.toDouble() ?? 4.0;
    final intervalMs = (minH + _rng.nextDouble() * (maxH - minH)) * 3600 * 1000;
    if (nowMs < base + intervalMs) return;

    // 触发！
    await _sendProactive(db, charId, charName);

    // 更新状态
    await db.update('proactive_settings', {
      'last_trigger': nowMs,
      'today_count': todayCount + 1,
      'proactive_date': today,
    }, where: 'char_id = ?', whereArgs: [charId]);
  }

  bool _inQuiet(DateTime now, int quietStart, int quietEnd) {
    final m = now.hour * 60 + now.minute;
    if (quietStart < quietEnd) {
      return m >= quietStart && m < quietEnd;
    } else {
      return m >= quietStart || m < quietEnd;
    }
  }

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<int> _lastChatTime(Database db, String charId) async {
    final rows = await db.rawQuery(
        'SELECT MAX(created_at) as t FROM messages WHERE char_id = ?', [charId]);
    return (rows.first['t'] as int?) ?? 0;
  }

  // ---------- 内容生成 ----------
  Future<void> _sendProactive(Database db, String charId, String charName) async {
    try {
      final charRows = await db.query('characters', where: 'id = ?', whereArgs: [charId]);
      if (charRows.isEmpty) return;
      final personaMd = charRows.first['persona_md'] as String? ?? '';

      final memRows = await db.query('memories',
          where: 'char_id = ?', whereArgs: [charId], orderBy: 'created_at DESC', limit: 1);
      final memorySummary = memRows.isNotEmpty ? memRows.first['summary'] as String? : null;

      final userMsgs = await db.query('messages',
          where: 'char_id = ? AND role = ?', whereArgs: [charId, 'user'],
          orderBy: 'created_at DESC', limit: 2);
      final lastTopic = userMsgs.reversed.map((m) => m['content'] as String).join('；');

      final lastChat = await _lastChatTime(db, charId);
      final hours = ((DateTime.now().millisecondsSinceEpoch - lastChat) / 3600000).round();

      final apiKey = await _readApiKey();
      if (apiKey == null || apiKey.isEmpty) return;

      final prompt = _buildPrompt(personaMd, memorySummary, lastTopic, hours);
      final reply = await _callDeepSeek(apiKey, prompt);
      if (reply == null || reply.trim().isEmpty) return;

      // 剥离末尾 ["emotion"]
      final tailRe = RegExp(r'\["(\w+)"\]\s*$');
      final tailM = tailRe.firstMatch(reply);
      final emotion = tailM?.group(1);
      final content = reply.replaceAll(tailRe, '').trim();

      final msgId = '${DateTime.now().millisecondsSinceEpoch}_${_rng.nextInt(9999)}';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await db.insert('messages', {
        'id': msgId,
        'char_id': charId,
        'role': 'assistant',
        'content': content,
        'emotion': emotion,
        'is_proactive': 1,
        'created_at': nowMs,
      });

      // 弹通知
      final firstLine = content.split('/').first.trim();
      await _showNotification(charName, firstLine);
    } catch (e) {
      print('[proactive] send error: $e');
    }
  }

  String _buildPrompt(String personaMd, String? memory, String lastTopic, int hours) {
    final period = _timePeriod();
    final sb = StringBuffer();
    // 复用与聊天完全一致的缓存前缀（人格+记忆+格式要求），命中 Prompt Caching
    sb.write(PromptPrefix.build(personaMd, memory));
    sb.write('\n\n【主动场景指令】\n');
    sb.write('现在是$period，你有一阵子没和 TA 聊了（约 $hours 小时）。\n');
    if (lastTopic.isNotEmpty) {
      sb.write('上次你们聊到：$lastTopic\n');
    }
    sb.write('请主动发一句自然的开场，像真人突然想起朋友那样——可以聊 TA 感兴趣的事、接上次没聊完的话题，或随口关心一句。要求：不超过 2 句，口语、不油腻、不查户口，不要说"好久没聊"这类破功的话。');
    return sb.toString();
  }

  String _timePeriod() {
    final h = DateTime.now().hour;
    if (h < 6) return '凌晨';
    if (h < 9) return '早上';
    if (h < 12) return '上午';
    if (h < 14) return '中午';
    if (h < 18) return '下午';
    if (h < 20) return '傍晚';
    if (h < 23) return '晚上';
    return '深夜';
  }

  Future<String?> _callDeepSeek(String apiKey, String systemPrompt) async {
    try {
      final dio = Dio();
      final resp = await dio.post(
        'https://api.deepseek.com/v1/chat/completions',
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'model': 'deepseek-v4-flash',
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': '在吗'},
          ],
          'temperature': 0.95,
          'max_tokens': 200,
        },
      );
      final data = resp.data as Map<String, dynamic>;
      return data['choices']?[0]?['message']?['content'] as String?;
    } catch (e) {
      print('[proactive] deepseek error: $e');
      return null;
    }
  }

  Future<String?> _readApiKey() async {
    try {
      final dbDir = await getDatabasesPath();
      final docsDir = Directory(dbDir).parent.path;
      final f = File(p.join(docsDir, '.deepseek_key_cache'));
      if (f.existsSync()) return f.readAsStringSync().trim();
    } catch (_) {}
    return null;
  }

  // ---------- 通知 ----------
  Future<void> _showNotification(String title, String body) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'proactive_channel',
        'AI 主动消息',
        channelDescription: '角色主动发来的消息通知',
        importance: Importance.high,
        priority: Priority.high,
      );
      const details = NotificationDetails(android: androidDetails);
      await _localNotif.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        details,
      );
    } catch (e) {
      print('[proactive] notif error: $e');
    }
  }
}
