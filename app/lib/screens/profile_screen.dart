import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/secure_storage.dart';
import '../routes.dart';
import 'setup_screen.dart';
import 'settings_screen.dart';

/// 我的 Tab（M1 · 账号信息 + 登出）
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const CircleAvatar(radius: 32, child: Icon(Icons.person, size: 36)),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.cloud),
            title: const Text('云地址'),
            subtitle: Text(app.cloudUrl),
          ),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('云端账号'),
            subtitle: Text(app.cloudToken.isEmpty ? '未登录' : '已登录（token 已签发）'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.chat),
            title: const Text('角色数'),
            subtitle: Text('${app.characters.length} 个'),
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('系统配置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, SlideRoute(const SettingsScreen())),
          ),
          const Divider(),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('退出登录'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('退出登录'),
                  content: const Text('将清除本机云端 token，本地角色与聊天记录保留。确认退出？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('退出'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await app.logout();
                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const SetupScreen()),
                    (route) => false,
                  );
                }
              }
            },
          ),
          const SizedBox(height: 8),
          FutureBuilder<String?>(
            future: SecureStorage.cloudUrl,
            builder: (ctx, snap) => Text(
              '本地数据仅存于本机；切换账号不影响其他账号的音色与记录。',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
