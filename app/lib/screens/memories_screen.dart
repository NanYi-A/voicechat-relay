import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/character.dart';
import '../services/database.dart';

/// 记忆管理页：按角色分组展示摘要，支持新增/编辑/删除
class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key});
  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  Map<String, List<Map<String, dynamic>>> _memoriesByChar = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = Provider.of<AppState>(context, listen: false);
    final map = <String, List<Map<String, dynamic>>>{};
    for (final c in app.characters) {
      final d = await DatabaseHelper.instance.db;
      final rows = await d.query('memories',
          where: 'char_id = ?', whereArgs: [c.id], orderBy: 'created_at DESC');
      map[c.id] = rows;
    }
    setState(() {
      _memoriesByChar = map;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('记忆管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : app.characters.isEmpty
              ? const Center(child: Text('还没有角色'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: app.characters.length,
                    itemBuilder: (_, i) {
                      final c = app.characters[i];
                      final mems = _memoriesByChar[c.id] ?? [];
                      return _buildCharSection(c, mems);
                    },
                  ),
                ),
    );
  }

  Widget _buildCharSection(Character c, List<Map<String, dynamic>> mems) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(Icons.person, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text(c.name, style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showEditDialog(c, null),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新增'),
              ),
            ],
          ),
        ),
        if (mems.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('暂无记忆摘要', style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else
          ...mems.map((m) => _buildMemCard(c, m)),
        const Divider(),
      ],
    );
  }

  Widget _buildMemCard(Character c, Map<String, dynamic> m) {
    final summary = m['summary'] as String? ?? '';
    final ts = m['created_at'] as int? ?? 0;
    final date = ts > 0
        ? DateTime.fromMillisecondsSinceEpoch(ts).toString().substring(0, 16)
        : '';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(summary, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(date, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: '编辑',
                  onPressed: () => _showEditDialog(c, m),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                  tooltip: '删除',
                  onPressed: () => _confirmDelete(m),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditDialog(Character c, Map<String, dynamic>? existing) async {
    final ctrl = TextEditingController(text: existing?['summary'] as String? ?? '');
    final isEdit = existing != null;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? '编辑记忆' : '新增记忆（${c.name}）'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: '输入记忆摘要（≤300字）',
            alignLabelWithHint: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    final d = await DatabaseHelper.instance.db;
    if (isEdit) {
      await d.update('memories', {'summary': result},
          where: 'id = ?', whereArgs: [existing['id']]);
    } else {
      await d.insert('memories', {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'char_id': c.id,
        'summary': result,
        'covers_msg_ids': '',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    }
    _load();
  }

  Future<void> _confirmDelete(Map<String, dynamic> m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记忆'),
        content: const Text('确定删除这条记忆摘要？'),
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
      final d = await DatabaseHelper.instance.db;
      await d.delete('memories', where: 'id = ?', whereArgs: [m['id']]);
      _load();
    }
  }
}
