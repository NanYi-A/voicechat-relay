import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/character.dart';
import '../screens/chat_screen.dart';
import '../routes.dart';

/// 消息 Tab：以角色为会话入口（P0 单人单角色即一会话）
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext ctx) {
    final app = Provider.of<AppState>(ctx);
    final chars = app.characters;
    return Scaffold(
      appBar: AppBar(title: const Text('消息')),
      body: chars.isEmpty
          ? const Center(child: Text('还没有角色，去「角色」页添加'))
          : ListView.builder(
              itemCount: chars.length,
              itemBuilder: (_, i) {
                final Character c = chars[i];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(c.name),
                  subtitle: Text(c.defaultVoice ?? '未绑定音色'),
                  onTap: () => Navigator.push(
                    ctx,
                    SlideRoute(ChatScreen(character: c)),
                  ),
                );
              },
            ),
    );
  }
}
