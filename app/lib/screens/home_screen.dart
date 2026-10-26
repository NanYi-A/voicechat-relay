import 'package:flutter/material.dart';
import 'chat_list_screen.dart';
import 'roles_screen.dart';
import 'voice_screen.dart';
import 'profile_screen.dart';

/// M4 · 底部 4 Tab（消息 / 角色 / 音色 / 我的）
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _idx = 0;
  final _screens = const [
    ChatListScreen(),
    RolesScreen(),
    VoiceScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_idx],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        onTap: (i) => setState(() => _idx = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: '消息'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '角色'),
          BottomNavigationBarItem(icon: Icon(Icons.graphic_eq), label: '音色'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '我的'),
        ],
      ),
    );
  }
}
