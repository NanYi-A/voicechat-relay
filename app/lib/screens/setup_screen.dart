import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/secure_storage.dart';
import '../services/auth.dart';
import '../screens/home_screen.dart';
import '../routes.dart';

/// M1 · 首次配置引导（DeepSeek key / 云地址 / 注册或登录）
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _keyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController(text: 'http://your-server-ip:8001');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isLogin = false;
  bool _saving = false;
  String? _error;

  Future<void> _submit() async {
    setState(() => _saving = true);
    setState(() => _error = null);
    try {
      // 在首个 await 之前取 AppState 引用，避免跨异步 gap 使用 context
      final app = Provider.of<AppState>(context, listen: false);
      final k = _keyCtrl.text.trim();
      final u = _urlCtrl.text.trim();
      final user = _userCtrl.text.trim();
      final pass = _passCtrl.text;
      if (k.isEmpty) throw Exception('请填写 DeepSeek API Key');
      if (u.isEmpty) throw Exception('请填写云端地址');
      if (user.isEmpty) throw Exception('请填写用户名');
      if (pass.isEmpty) throw Exception('请填写密码');
      if (!_isLogin && pass.length < 6) throw Exception('密码至少 6 位');

      final dio = Dio();
      final auth = AuthService(dio, u);
      final result = _isLogin
          ? await auth.login(user, pass)
          : await auth.register(user, pass);

      await SecureStorage.writeAll(
        deepseekKey: k,
        cloudUrl: u,
        cloudToken: result.token,
        accountId: result.userId,
      );
      await app.init();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        SlideRoute(const HomeScreen()),
        (r) => false,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 / 注册')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ),
              TextField(
                controller: _keyCtrl,
                decoration: const InputDecoration(labelText: 'DeepSeek API Key *'),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: '云端地址',
                  hintText: '如 http://your-server-ip:8001',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _userCtrl,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passCtrl,
                decoration: const InputDecoration(
                    labelText: '密码', hintText: '注册至少 6 位'),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              ToggleButtons(
                isSelected: [!_isLogin, _isLogin],
                onPressed: (i) => setState(() => _isLogin = i == 1),
                children: const [
                  Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('注册')),
                  Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('登录')),
                ],
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: Text(_saving ? '处理中...' : (_isLogin ? '登录' : '注册并进入')),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
