import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/character.dart';
import '../models/message.dart';

/// M2 · 本地数据库（sqflite，按账号隔离：每个云端账号一个独立 DB 文件）
///
/// ⚠️ 踩坑记录：sqflite 原生插件用【进程级静态表】按 path 管理数据库实例，
/// 默认 singleInstance:true 时不同 isolate 打开同一路径会共享同一个原生连接。
/// §16 主动消息的后台 isolate 曾因此把主 isolate 正在用的库 close 掉，
/// 导致前台全部查询抛 database_closed（聊天记录"消失"、音色页转圈）。
/// 现在：① 后台 isolate 改用 singleInstance:false 独立连接；
///       ② 主 isolate 所有操作经 _safe() 自愈，遇到 database_closed 自动重开重试。
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _db;
  static Future<Database>? _opening; // 并发打开守卫，避免重复 open
  String? _accountId;

  DatabaseHelper._init();

  /// 当前账号标识（云端 user_id）。未登录时 null，用 'default' 占位文件名。
  /// 切换账号时关闭旧库，下次访问打开新账号库，从而实现结构性隔离。
  Future<void> setAccount(String accountId) async {
    if (_accountId == accountId && _db != null) return;
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
    _opening = null;
    _accountId = accountId;
  }

  /// 登出：关闭当前账号库并清空标识，使下次打开切换为新账号（不影响其他账号库文件）
  Future<void> resetAccount() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
    _opening = null;
    _accountId = null;
  }

  String _dbFileName() {
    final id = _accountId ?? 'default';
    final hash = sha256.convert(utf8.encode(id)).toString();
    return 'voicechat_$hash.db';
  }

  Future<Database> get db async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = null;
    _opening ??= _initDB(_dbFileName()).whenComplete(() => _opening = null);
    _db = await _opening;
    return _db!;
  }

  /// 自愈执行：若底层连接被外部关闭（database_closed），丢弃缓存重开一次再重试。
  Future<T> _safe<T>(Future<T> Function(Database d) op) async {
    try {
      return await op(await db);
    } on DatabaseException catch (e) {
      if (e.isDatabaseClosedError()) {
        _db = null;
        return await op(await db);
      }
      rethrow;
    }
  }

  Future<Database> _initDB(String file) async {
    final dir = await getDatabasesPath();
    final path = join(dir, file);
    final legacy = join(dir, 'voicechat.db');
    final isRealAccount = _accountId != null && _accountId != 'default';
    // 一次性迁移：旧版单库（voicechat.db）归并到首个登录的账号库，随后删除旧文件
    if (isRealAccount && !File(path).existsSync() && File(legacy).existsSync()) {
      await File(legacy).copy(path);
      await File(legacy).delete();
    }
    return openDatabase(path, version: 2, onCreate: _createDB, onUpgrade: (db, old, _) async {
      if (old < 2) {
        await db.execute('ALTER TABLE sticker_messages ADD COLUMN position INTEGER DEFAULT 0');
      }
    });
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE characters (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        persona_md TEXT NOT NULL,
        default_voice TEXT,
        last_read_at INTEGER DEFAULT 0,
        created_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        char_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        emotion TEXT,
        audio_cached INTEGER DEFAULT 0,
        is_proactive INTEGER DEFAULT 0,
        created_at INTEGER,
        FOREIGN KEY (char_id) REFERENCES characters(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE sticker_messages (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL,
        emotion TEXT,
        sticker_path TEXT NOT NULL,
        position INTEGER DEFAULT 0,
        created_at INTEGER,
        FOREIGN KEY (message_id) REFERENCES messages(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE memories (
        id TEXT PRIMARY KEY,
        char_id TEXT NOT NULL,
        summary TEXT NOT NULL,
        covers_msg_ids TEXT,
        created_at INTEGER,
        FOREIGN KEY (char_id) REFERENCES characters(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE audio_cache (
        id TEXT PRIMARY KEY,
        char_id TEXT NOT NULL,
        text TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_size INTEGER,
        created_at INTEGER,
        last_used_at INTEGER,
        FOREIGN KEY (char_id) REFERENCES characters(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE voices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        remote_name TEXT NOT NULL,
        status TEXT DEFAULT 'active',
        created_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE proactive_settings (
        char_id TEXT PRIMARY KEY,
        enabled INTEGER NOT NULL DEFAULT 0,
        min_hours REAL NOT NULL DEFAULT 2.0,
        max_hours REAL NOT NULL DEFAULT 4.0,
        quiet_start INTEGER NOT NULL DEFAULT 1260,
        quiet_end INTEGER NOT NULL DEFAULT 420,
        daily_cap INTEGER NOT NULL DEFAULT 5,
        last_trigger INTEGER NOT NULL DEFAULT 0,
        proactive_date TEXT,
        today_count INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (char_id) REFERENCES characters(id)
      )
    ''');
  }

  // ---------- characters ----------
  Future<int> insertCharacter(Character c) =>
      _safe((d) => d.insert('characters', c.toMap()));

  Future<List<Character>> getCharacters() => _safe((d) async {
        final rows = await d.query('characters', orderBy: 'created_at DESC');
        return rows.map(Character.fromMap).toList();
      });

  Future<Character?> getCharacter(String id) => _safe((d) async {
        final rows = await d.query('characters', where: 'id = ?', whereArgs: [id]);
        return rows.isEmpty ? null : Character.fromMap(rows.first);
      });

  Future<int> updateCharacter(Character c) => _safe((d) =>
      d.update('characters', c.toMap(), where: 'id = ?', whereArgs: [c.id]));

  /// 删除角色 + 级联清理所有关联数据
  Future<void> deleteCharacter(String id) => _safe((d) async {
        // 先查消息 ID（sticker_messages 通过 message_id 关联）
        final msgs = await d.query('messages', columns: ['id'], where: 'char_id = ?', whereArgs: [id]);
        if (msgs.isNotEmpty) {
          final ids = msgs.map((r) => r['id'] as String).toList();
          await d.delete('sticker_messages',
              where: 'message_id IN (${ids.map((_) => '?').join(',')})', whereArgs: ids);
        }
        await d.delete('messages', where: 'char_id = ?', whereArgs: [id]);
        await d.delete('memories', where: 'char_id = ?', whereArgs: [id]);
        await d.delete('audio_cache', where: 'char_id = ?', whereArgs: [id]);
        await d.delete('proactive_settings', where: 'char_id = ?', whereArgs: [id]);
        await d.delete('characters', where: 'id = ?', whereArgs: [id]);
      });

  // ---------- messages ----------
  Future<int> insertMessage(Message m) =>
      _safe((d) => d.insert('messages', m.toMap()));

  Future<List<Message>> getMessages(String charId) => _safe((d) async {
        final rows = await d.query('messages',
            where: 'char_id = ?', whereArgs: [charId], orderBy: 'created_at ASC');
        return rows.map(Message.fromMap).toList();
      });

  /// 删除单条消息（§15 重新生成时级联移除旧 AI 回复）
  Future<int> deleteMessage(String id) =>
      _safe((d) => d.delete('messages', where: 'id = ?', whereArgs: [id]));

  // ---------- voices (M3) ----------
  Future<int> upsertVoice(Map<String, dynamic> row) => _safe((d) =>
      d.insert('voices', row, conflictAlgorithm: ConflictAlgorithm.replace));

  Future<List<Map<String, dynamic>>> getVoices() =>
      _safe((d) => d.query('voices'));

  Future<int> updateCharacterVoice(String id, String remoteName) => _safe((d) =>
      d.update('characters', {'default_voice': remoteName},
          where: 'id = ?', whereArgs: [id]));

  // ---------- audio_cache ----------
  Future<Map<String, dynamic>?> getAudioCache(String id) => _safe((d) async {
        final rows = await d.query('audio_cache', where: 'id = ?', whereArgs: [id]);
        return rows.isEmpty ? null : rows.first;
      });

  Future<void> insertAudioCache(Map<String, dynamic> row) =>
      _safe((d) => d.insert('audio_cache', row));

  Future<void> updateAudioCacheLastUsed(String id, int ts) => _safe((d) =>
      d.update('audio_cache', {'last_used_at': ts},
          where: 'id = ?', whereArgs: [id]));

  Future<String?> getAudioCachePath(String id) async {
    final row = await getAudioCache(id);
    return row?['file_path'] as String?;
  }

  // ---------- memories (§8 记忆摘要) ----------
  Future<void> insertMemory(Map<String, dynamic> row) =>
      _safe((d) => d.insert('memories', row));

  /// 取该角色最新一份摘要
  Future<Map<String, dynamic>?> getLatestMemory(String charId) => _safe((d) async {
        final rows = await d.query('memories',
            where: 'char_id = ?', whereArgs: [charId],
            orderBy: 'created_at DESC', limit: 1);
        return rows.isEmpty ? null : rows.first;
      });

  /// 统计该角色非主动消息条数（用于判断是否满 50 轮 = 100 条）
  Future<int> countNonProactiveMessages(String charId) => _safe((d) async {
        final result = await d.rawQuery(
            'SELECT COUNT(*) AS n FROM messages WHERE char_id = ? AND is_proactive = 0',
            [charId]);
        return (result.first['n'] as int?) ?? 0;
      });
}
