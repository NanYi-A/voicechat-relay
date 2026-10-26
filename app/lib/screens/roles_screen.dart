import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/character.dart';
import '../services/database.dart';
import '../routes.dart';
import 'proactive_settings_screen.dart';

/// 角色 Tab：列表 + 新建 + 编辑 + 删除
class RolesScreen extends StatefulWidget {
  const RolesScreen({super.key});
  @override
  State<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends State<RolesScreen> {
  List<Map<String, dynamic>> _voices = [];

  @override
  void initState() {
    super.initState();
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    final rows = await DatabaseHelper.instance.getVoices();
    setState(() => _voices = rows);
  }

  @override
  Widget build(BuildContext ctx) {
    final app = Provider.of<AppState>(ctx);
    return Scaffold(
      appBar: AppBar(title: const Text('角色')),
      body: app.characters.isEmpty
          ? const Center(child: Text('还没有角色\n点右下角 + 创建', textAlign: TextAlign.center))
          : ListView.builder(
              itemCount: app.characters.length,
              itemBuilder: (_, i) {
                final c = app.characters[i];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(c.name),
                  subtitle: Text('音色: ${_voiceDisplay(c.defaultVoice)}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'edit') {
                        _showEdit(ctx, c);
                      } else if (action == 'proactive') {
                        Navigator.push(
                          ctx,
                          SlideRoute(ProactiveSettingsScreen(
                              charId: c.id, charName: c.name)),
                        );
                      } else if (action == 'delete') {
                        _confirmDelete(ctx, c);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'proactive', child: Text('主动消息')),
                      PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: Colors.red))),
                    ],
                  ),
                  onTap: () => _showEdit(ctx, c),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAdd(ctx),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _voiceDisplay(String? remoteName) {
    if (remoteName == null || remoteName.isEmpty) return '未绑定';
    final match = _voices.where((v) => v['remote_name'] == remoteName);
    if (match.isNotEmpty) return match.first['name'] as String? ?? remoteName;
    return remoteName.contains('::') ? remoteName.split('::').last : remoteName;
  }

  Future<void> _confirmDelete(BuildContext ctx, Character c) async {
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        title: const Text('删除角色'),
        content: Text('确定删除「${c.name}」？\n该角色的所有聊天记录、记忆、缓存将一并删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final app = Provider.of<AppState>(ctx, listen: false);
      await app.deleteCharacter(c.id);
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('已删除「${c.name}」')),
        );
      }
    }
  }

  void _showEdit(BuildContext ctx, Character c) {
    final nameCtrl = TextEditingController(text: c.name);
    final personaCtrl = TextEditingController(text: c.personaMd);
    String? selectedVoice = c.defaultVoice;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('编辑角色', style: Theme.of(sheetCtx).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '角色名 *'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: personaCtrl,
                  maxLines: 8,
                  minLines: 5,
                  decoration: const InputDecoration(
                    labelText: '人格 md（system 提示词）',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: selectedVoice,
                  decoration: const InputDecoration(labelText: '音色'),
                  items: _voices.isEmpty
                      ? [const DropdownMenuItem(value: null, child: Text('暂无音色'))]
                      : _voices
                          .map((v) => DropdownMenuItem(
                                value: v['remote_name'] as String,
                                child: Text(v['name'] as String? ?? v['remote_name'] as String),
                              ))
                          .toList(),
                  onChanged: (v) => setSheetState(() => selectedVoice = v),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    final app = Provider.of<AppState>(ctx, listen: false);
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) {
                      if (sheetCtx.mounted) {
                        ScaffoldMessenger.of(sheetCtx).showSnackBar(
                          const SnackBar(content: Text('角色名不能为空')),
                        );
                      }
                      return;
                    }
                    final updated = Character(
                      id: c.id,
                      name: name,
                      personaMd: personaCtrl.text.trim().isEmpty ? '(空人格)' : personaCtrl.text.trim(),
                      defaultVoice: selectedVoice,
                      lastReadAt: c.lastReadAt,
                      createdAt: c.createdAt,
                    );
                    await app.updateCharacter(updated);
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  },
                  child: const Text('保存修改'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAdd(BuildContext ctx) {
    final nameCtrl = TextEditingController();
    final personaCtrl = TextEditingController();
    String? selectedVoice;
    if (_voices.isNotEmpty) {
      selectedVoice = _voices.first['remote_name'] as String;
    }

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '角色名 *'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: personaCtrl,
                  maxLines: 8,
                  minLines: 5,
                  decoration: const InputDecoration(
                    labelText: '人格 md（system 提示词）',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: selectedVoice,
                  decoration: const InputDecoration(labelText: '音色'),
                  items: _voices.isEmpty
                      ? [const DropdownMenuItem(value: null, child: Text('暂无音色（请先克隆）'))]
                      : _voices
                          .map((v) => DropdownMenuItem(
                                value: v['remote_name'] as String,
                                child: Text(v['name'] as String? ?? v['remote_name'] as String),
                              ))
                          .toList(),
                  onChanged: (v) => setSheetState(() => selectedVoice = v),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    final text = await rootBundle
                        .loadString('assets/personas/yuan_yuhan_prompt.md');
                    personaCtrl.text = text;
                    final demoVoice = _voices.where(
                        (v) => (v['remote_name'] as String).endsWith('::voice_a'));
                    if (demoVoice.isNotEmpty) {
                      setSheetState(() => selectedVoice = demoVoice.first['remote_name'] as String);
                    }
                  },
                  child: const Text('导入示例人设'),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () async {
                    final app = Provider.of<AppState>(ctx, listen: false);
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) {
                      if (sheetCtx.mounted) {
                        ScaffoldMessenger.of(sheetCtx).showSnackBar(
                          const SnackBar(content: Text('请先填写角色名')),
                        );
                      }
                      return;
                    }
                    final c = Character(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      name: name,
                      personaMd: personaCtrl.text.trim().isEmpty
                          ? '(空人格)'
                          : personaCtrl.text.trim(),
                      defaultVoice: selectedVoice,
                      createdAt: DateTime.now().millisecondsSinceEpoch,
                    );
                    await app.addCharacter(c);
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  },
                  child: const Text('保存角色'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
