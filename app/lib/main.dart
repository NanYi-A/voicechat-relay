import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'providers/app_state.dart';
import 'services/secure_storage.dart';
import 'services/proactive.dart';
import 'screens/setup_screen.dart';
import 'screens/home_screen.dart';

// flutter_foreground_task 要求的顶层回调（独立 isolate 入口）
@pragma('vm:entry-point')
void startProactiveTask() {
  FlutterForegroundTask.setTaskHandler(ProactiveTaskHandler());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化前台任务框架
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'proactive_fg',
      channelName: 'AI 伴侣保活',
      channelDescription: '保持 AI 主动消息调度运行',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(60000), // 每 60s 触发一次 onRepeatEvent
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  final app = AppState();
  await app.init();

  // 写 DeepSeek key 缓存文件供前台 isolate 读取
  await _writeKeyCache(app.deepseekKey);

  // 启动前台服务
  await _startForeground();

  runApp(ChangeNotifierProvider.value(value: app, child: const MyApp()));
}

Future<void> _writeKeyCache(String? key) async {
  if (key == null || key.isEmpty) return;
  try {
    final dbDir = await getDatabasesPath();
    final docsDir = Directory(dbDir).parent.path;
    final f = File('$docsDir/.deepseek_key_cache');
    await f.writeAsString(key);
  } catch (_) {}
}

Future<void> _startForeground() async {
  try {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 1001,
        notificationTitle: 'AI 伴侣运行中',
        notificationText: '主动消息调度已开启',
        callback: startProactiveTask,
      );
    }
  } catch (e) {
    print('[fg] start error: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '语音聊天',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          type: BottomNavigationBarType.fixed,
        ),
      ),
      home: FutureBuilder<bool>(
        future: SecureStorage.isConfigured,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          return snap.data! ? const HomeScreen() : const SetupScreen();
        },
      ),
    );
  }
}
