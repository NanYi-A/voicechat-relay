import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../routes.dart';
import 'memories_screen.dart';
import 'sticker_manage_screen.dart';

/// 系统配置页（后续用户可控操作统一放这里）
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  /// 获取记忆触发条数（默认 100 条 = 50 轮）
  static Future<int> getMemoryTrigger() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/app_settings.json');
      if (f.existsSync()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return (data['memory_trigger_count'] as int?) ?? 100;
      }
    } catch (_) {}
    return 100;
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _memoryTrigger = 100; // 条数（50轮=100条）

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await SettingsScreen.getMemoryTrigger();
    if (mounted) setState(() => _memoryTrigger = v);
  }

  Future<void> _save() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/app_settings.json');
    Map<String, dynamic> data = {};
    if (f.existsSync()) {
      try {
        data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
    }
    data['memory_trigger_count'] = _memoryTrigger;
    await f.writeAsString(jsonEncode(data));
  }

  @override
  Widget build(BuildContext context) {
    final rounds = _memoryTrigger ~/ 2;
    return Scaffold(
      appBar: AppBar(title: const Text('系统配置')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.psychology),
            title: const Text('查看记忆'),
            subtitle: const Text('管理各角色的记忆摘要'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, SlideRoute(const MemoriesScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_emotions),
            title: const Text('表情包管理'),
            subtitle: const Text('按情绪分类浏览、导入、删除表情包'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, SlideRoute(const StickerManageScreen())),
          ),
          const Divider(),
          // 记忆摘要触发设置
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('自动记忆触发', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        '每 $_memoryTrigger 条消息（$rounds 轮对话）自动生成记忆摘要',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('20条', style: Theme.of(context).textTheme.bodySmall),
                Expanded(
                  child: Slider(
                    value: _memoryTrigger.toDouble(),
                    min: 20,
                    max: 200,
                    divisions: 18, // 20,30,40,...200
                    label: '$_memoryTrigger 条',
                    onChanged: (v) => setState(() => _memoryTrigger = v.toInt()),
                    onChangeEnd: (_) => _save(),
                  ),
                ),
                Text('200条', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 后续扩展：缓存清理、主动消息全局开关、备份恢复等
        ],
      ),
    );
  }
}
