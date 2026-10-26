import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../services/database.dart';

/// §16 每角色主动消息设置：开关 + 间隔 + 静默时段 + 每日上限
class ProactiveSettingsScreen extends StatefulWidget {
  final String charId;
  final String charName;
  const ProactiveSettingsScreen({super.key, required this.charId, required this.charName});

  @override
  State<ProactiveSettingsScreen> createState() => _ProactiveSettingsScreenState();
}

class _ProactiveSettingsScreenState extends State<ProactiveSettingsScreen> {
  bool _enabled = false;
  double _minHours = 2.0;
  double _maxHours = 4.0;
  int _quietStart = 1260; // 21:00
  int _quietEnd = 420;    // 07:00
  int _dailyCap = 5;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await DatabaseHelper.instance.db;
    final rows = await d.query('proactive_settings', where: 'char_id = ?', whereArgs: [widget.charId]);
    if (rows.isNotEmpty) {
      final s = rows.first;
      _enabled = (s['enabled'] as int? ?? 0) == 1;
      _minHours = (s['min_hours'] as num?)?.toDouble() ?? 2.0;
      _maxHours = (s['max_hours'] as num?)?.toDouble() ?? 4.0;
      _quietStart = s['quiet_start'] as int? ?? 1260;
      _quietEnd = s['quiet_end'] as int? ?? 420;
      _dailyCap = s['daily_cap'] as int? ?? 5;
    }
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final d = await DatabaseHelper.instance.db;
    await d.insert('proactive_settings', {
      'char_id': widget.charId,
      'enabled': _enabled ? 1 : 0,
      'min_hours': _minHours,
      'max_hours': _maxHours,
      'quiet_start': _quietStart,
      'quiet_end': _quietEnd,
      'daily_cap': _dailyCap,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  String _fmtTime(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Future<void> _pickQuietStart() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _quietStart ~/ 60, minute: _quietStart % 60),
    );
    if (t != null) {
      setState(() => _quietStart = t.hour * 60 + t.minute);
      _save();
    }
  }

  Future<void> _pickQuietEnd() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _quietEnd ~/ 60, minute: _quietEnd % 60),
    );
    if (t != null) {
      setState(() => _quietEnd = t.hour * 60 + t.minute);
      _save();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text('${widget.charName} · 主动消息')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text('${widget.charName} · 主动消息')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 总开关
          Card(
            child: SwitchListTile(
              title: const Text('启用主动消息'),
              subtitle: const Text('角色会在你一阵子没聊时主动找你'),
              value: _enabled,
              onChanged: (v) {
                setState(() => _enabled = v);
                _save();
              },
            ),
          ),
          const SizedBox(height: 12),
          // 间隔设置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('触发间隔', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text('最短：${_minHours.toStringAsFixed(1)} 小时'),
                  Slider(
                    value: _minHours,
                    min: 0.5,
                    max: 12,
                    divisions: 23,
                    onChanged: (v) => setState(() => _minHours = v),
                    onChangeEnd: (_) => _save(),
                  ),
                  Text('最长：${_maxHours.toStringAsFixed(1)} 小时'),
                  Slider(
                    value: _maxHours,
                    min: 1,
                    max: 24,
                    divisions: 46,
                    onChanged: (v) => setState(() => _maxHours = v),
                    onChangeEnd: (_) => _save(),
                  ),
                  Text(
                    '距上次聊天 ${_minHours.toStringAsFixed(1)}~${_maxHours.toStringAsFixed(1)} 小时后随机触发',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 静默时段
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('静默时段', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('开始'),
                          subtitle: Text(_fmtTime(_quietStart)),
                          trailing: const Icon(Icons.access_time),
                          onTap: _pickQuietStart,
                        ),
                      ),
                      Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('结束'),
                          subtitle: Text(_fmtTime(_quietEnd)),
                          trailing: const Icon(Icons.access_time),
                          onTap: _pickQuietEnd,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${_fmtTime(_quietStart)}~${_fmtTime(_quietEnd)} 期间不会发送',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 每日上限
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('每日上限', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: _dailyCap > 1
                            ? () { setState(() => _dailyCap--); _save(); }
                            : null,
                      ),
                      Text('$_dailyCap 条/天', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: _dailyCap < 20
                            ? () { setState(() => _dailyCap++); _save(); }
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
