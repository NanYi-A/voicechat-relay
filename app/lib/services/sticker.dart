import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path_provider/path_provider.dart';

/// §9 表情包服务：首次运行从 assets 拷贝到 documents/stickers/，提供随机选图
class StickerService {
  static const _emotionKeys = [
    'angry', 'awkward', 'confirm', 'confused', 'evasive',
    'fear', 'goofy', 'happy', 'loved', 'pathead',
    'provoke', 'reminded', 'sad', 'shy', 'speechless',
    'stare', 'surprised', 'thumbsup', 'tired',
  ];

  static bool _initialized = false;
  static final _rng = Random();

  /// 确保 stickers 已拷贝到持久目录（仅首次运行执行）
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    final stickerRoot = Directory('${dir.path}/stickers');
    // 用一个标记文件判断是否已拷贝过
    final marker = File('${stickerRoot.path}/.copied');
    if (marker.existsSync()) {
      _initialized = true;
      return;
    }
    // 从 assets 拷贝全部情绪目录
    for (final emotion in _emotionKeys) {
      final emotionDir = Directory('${stickerRoot.path}/$emotion');
      if (!emotionDir.existsSync()) emotionDir.createSync(recursive: true);
      final manifest = await _listAssetDir('assets/stickers/$emotion/');
      for (final assetPath in manifest) {
        final fileName = assetPath.split('/').last;
        final target = File('${emotionDir.path}/$fileName');
        if (!target.existsSync()) {
          final bytes = await rootBundle.load(assetPath);
          await target.writeAsBytes(bytes.buffer.asUint8List());
        }
      }
    }
    marker.createSync();
    _initialized = true;
  }

  /// 列出 assets 目录下所有文件（通过 AssetManifest）
  static Future<List<String>> _listAssetDir(String prefix) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final all = manifest.listAssets();
    return all.where((p) => p.startsWith(prefix) && !p.endsWith('/')).toList();
  }

  /// 中→英映射（模型可能输出中文标签）
  static const _cnToEn = {
    '点赞': 'thumbsup', '盯你看': 'stare', '搞怪': 'goofy', '摸头': 'pathead',
    '生气': 'angry', '疑问': 'confused', '逃避': 'evasive', '开心': 'happy',
    '被爱': 'loved', '想起': 'reminded', '难过': 'sad', '震惊': 'surprised',
    '累了': 'tired', '尴尬': 'awkward', '害怕': 'fear', '害羞': 'shy',
    '确认': 'confirm', '挑衅': 'provoke', '无语': 'speechless',
  };

  /// 归一化情绪 key：中文→英文，已经是英文则直接返回
  static String? normalizeEmotion(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final lower = raw.trim().toLowerCase();
    if (_emotionKeys.contains(lower)) return lower;
    return _cnToEn[raw.trim()];
  }

  /// 从指定情绪池随机选一张，返回文件路径；池空返回 null
  static Future<String?> pickRandom(String emotionKey) async {
    await ensureInitialized();
    final dir = await getApplicationDocumentsDirectory();
    final emotionDir = Directory('${dir.path}/stickers/$emotionKey');
    if (!emotionDir.existsSync()) return null;
    final files = emotionDir
        .listSync()
        .whereType<File>()
        .where((f) {
          final ext = f.path.split('.').last.toLowerCase();
          return ext == 'webp' || ext == 'jpg' || ext == 'jpeg' || ext == 'gif' || ext == 'png';
        })
        .toList();
    if (files.isEmpty) return null;
    return files[_rng.nextInt(files.length)].path;
  }
}
