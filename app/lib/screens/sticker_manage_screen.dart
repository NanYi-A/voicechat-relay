import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import '../services/sticker.dart';

/// §9 表情包管理：按情绪分类浏览 + 导入（自动压缩）+ 删除 + 概率/次数设置
class StickerManageScreen extends StatefulWidget {
  const StickerManageScreen({super.key});

  /// 供 chat_screen 读取当前设置
  static Future<(double, int)> getSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/sticker_settings.json');
      if (f.existsSync()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return (
          (data['probability'] as num?)?.toDouble() ?? 20,
          (data['roll_count'] as int?) ?? 3,
        );
      }
    } catch (_) {}
    return (20.0, 3);
  }

  @override
  State<StickerManageScreen> createState() => _StickerManageScreenState();
}

class _StickerManageScreenState extends State<StickerManageScreen> {
  static const _emotions = [
    ('angry', '生气'), ('awkward', '尴尬'), ('confirm', '确认'),
    ('confused', '疑问'), ('evasive', '逃避'), ('fear', '害怕'),
    ('goofy', '搞怪'), ('happy', '开心'), ('loved', '被爱'),
    ('pathead', '摸头'), ('provoke', '挑衅'), ('reminded', '想起'),
    ('sad', '难过'), ('shy', '害羞'), ('speechless', '无语'),
    ('stare', '盯你看'), ('surprised', '震惊'), ('thumbsup', '点赞'),
    ('tired', '累了'),
  ];

  String _selected = 'happy';
  List<File> _files = [];
  bool _loading = true;

  // §9.2 用户可调：概率和次数
  double _probability = 20; // 百分比
  int _rollCount = 3;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 确保 assets 已拷贝到 documents（首次运行）
    await StickerService.ensureInitialized();
    await _loadSettings();
    await _loadFiles();
  }

  Future<File> _settingsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/sticker_settings.json');
  }

  Future<void> _loadSettings() async {
    try {
      final f = await _settingsFile();
      if (f.existsSync()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _probability = (data['probability'] as num?)?.toDouble() ?? 20;
        _rollCount = (data['roll_count'] as int?) ?? 3;
      }
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    final f = await _settingsFile();
    await f.writeAsString(jsonEncode({
      'probability': _probability,
      'roll_count': _rollCount,
    }));
  }

  Future<void> _loadFiles() async {
    setState(() => _loading = true);
    final dir = await getApplicationDocumentsDirectory();
    final emotionDir = Directory('${dir.path}/stickers/$_selected');
    final files = <File>[];
    if (emotionDir.existsSync()) {
      for (final e in emotionDir.listSync()) {
        if (e is File) {
          final ext = e.path.split('.').last.toLowerCase();
          if (['webp', 'jpg', 'jpeg', 'gif', 'png'].contains(ext)) {
            files.add(e);
          }
        }
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  /// §9.3 导入：自动等比缩放（上限512×512）+ 压缩（quality=85）
  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    final dir = await getApplicationDocumentsDirectory();
    final emotionDir = Directory('${dir.path}/stickers/$_selected');
    if (!emotionDir.existsSync()) emotionDir.createSync(recursive: true);

    int imported = 0;
    for (final pf in result.files) {
      if (pf.path == null) continue;
      final src = File(pf.path!);
      final ext = pf.path!.split('.').last.toLowerCase();
      final isGif = ext == 'gif';
      final maxSize = isGif ? 500 * 1024 : 200 * 1024;

      if (isGif) {
        final bytes = await src.readAsBytes();
        if (bytes.length > maxSize) continue;
        final target = File('${emotionDir.path}/${DateTime.now().millisecondsSinceEpoch}_$imported.gif');
        await target.writeAsBytes(bytes);
        imported++;
        continue;
      }

      final targetPath = '${emotionDir.path}/${DateTime.now().millisecondsSinceEpoch}_$imported.jpg';
      final compressed = await FlutterImageCompress.compressAndGetFile(
        src.absolute.path,
        targetPath,
        minWidth: 512,
        minHeight: 512,
        quality: 85,
      );
      if (compressed != null) {
        final compressedFile = File(compressed.path);
        if (compressedFile.lengthSync() > maxSize) {
          final rePath = '${emotionDir.path}/${DateTime.now().millisecondsSinceEpoch}_r.jpg';
          final re = await FlutterImageCompress.compressAndGetFile(
            compressed.path,
            rePath,
            minWidth: 256,
            minHeight: 256,
            quality: 70,
          );
          if (re != null) compressedFile.deleteSync();
        }
        imported++;
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 $imported 张到「${_label(_selected)}」')),
      );
    }
    _loadFiles();
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除表情包'),
        content: const Text('确定删除这张？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (f.existsSync()) f.deleteSync();
      _loadFiles();
    }
  }

  String _label(String key) {
    final match = _emotions.where((e) => e.$1 == key);
    return match.isEmpty ? key : match.first.$2;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('表情包管理'),
        actions: [
          IconButton(icon: const Icon(Icons.add_photo_alternate), tooltip: '导入', onPressed: _import),
        ],
      ),
      body: Column(
        children: [
          // §9.2 概率/次数设置
          _buildSettingsCard(),
          // 情绪分类横向滚动
          SizedBox(
            height: 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _emotions.length,
              itemBuilder: (_, i) {
                final (key, label) = _emotions[i];
                final selected = _selected == key;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
                  child: ChoiceChip(
                    label: Text(label, style: TextStyle(fontSize: 12, color: selected ? Colors.white : null)),
                    selected: selected,
                    onSelected: (_) {
                      setState(() => _selected = key);
                      _loadFiles();
                    },
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          // 网格展示
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty
                    ? Center(child: Text('「${_label(_selected)}」暂无表情包\n点右上角 + 导入', textAlign: TextAlign.center))
                    : GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        itemCount: _files.length,
                        itemBuilder: (_, i) {
                          final f = _files[i];
                          return GestureDetector(
                            onLongPress: () => _delete(f),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                f,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                              ),
                            ),
                          );
                        },
                      ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '长按删除 | 导入自动压缩（静态≤200KB，GIF≤500KB，上限512×512）',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('发送设置', style: Theme.of(context).textTheme.titleSmall),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('每次概率：${_probability.toInt()}%'),
                      Slider(
                        value: _probability,
                        min: 0,
                        max: 100,
                        divisions: 20,
                        onChanged: (v) => setState(() => _probability = v),
                        onChangeEnd: (_) => _saveSettings(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('掷骰次数：$_rollCount'),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, size: 20),
                          onPressed: _rollCount > 1
                              ? () { setState(() => _rollCount--); _saveSettings(); }
                              : null,
                        ),
                        Text('$_rollCount', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, size: 20),
                          onPressed: _rollCount < 10
                              ? () { setState(() => _rollCount++); _saveSettings(); }
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
