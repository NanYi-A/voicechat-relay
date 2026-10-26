import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/database.dart';
import '../services/tts.dart';
import '../routes.dart';
import 'clone_voice_screen.dart';

/// 音色 Tab（P1）：列表 + 试听 + 设为角色默认 + 克隆入口
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  List<Map<String, dynamic>> _voices = [];
  bool _loading = true;
  String? _playingId; // 正在试听的音色 remote_name
  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _loadVoices();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadVoices() async {
    setState(() => _loading = true);
    final app = Provider.of<AppState>(context, listen: false);
    await app.fetchVoices();
    final rows = await DatabaseHelper.instance.getVoices();
    setState(() {
      _voices = rows;
      _loading = false;
    });
  }

  /// 试听：用该音色合成一句固定短句（持久化缓存，二次试听秒播）
  static const _auditionText = '你好，这是我的声音，听起来怎么样？';

  Future<void> _audition(Map<String, dynamic> voice) async {
    final remoteName = voice['remote_name'] as String;
    if (_playingId == remoteName) {
      await _player.stop();
      setState(() => _playingId = null);
      return;
    }
    final app = Provider.of<AppState>(context, listen: false);
    setState(() => _playingId = remoteName);
    try {
      // 缓存 key：hash(charId + text + voice + tts_v4)
      final cacheKey = sha256
          .convert(utf8.encode('_audition|$_auditionText|$remoteName|tts_v4'))
          .toString();
      final cached = await DatabaseHelper.instance.getAudioCache(cacheKey);
      String filePath;

      if (cached != null && File(cached['file_path'] as String).existsSync()) {
        // 命中缓存
        filePath = cached['file_path'] as String;
        await DatabaseHelper.instance
            .updateAudioCacheLastUsed(cacheKey, DateTime.now().millisecondsSinceEpoch);
      } else {
        // 未命中：合成 + 持久化
        final svc = TtsService(Dio(), app.cloudUrl, app.cloudToken);
        final wav = await svc.synthesize(
          charId: '_audition',
          text: _auditionText,
          voice: remoteName,
        );
        final dir = await getApplicationDocumentsDirectory();
        final audioDir = Directory('${dir.path}/audio_cache');
        if (!audioDir.existsSync()) audioDir.createSync(recursive: true);
        final f = File('${audioDir.path}/$cacheKey.wav');
        await f.writeAsBytes(wav);
        filePath = f.path;
        await DatabaseHelper.instance.insertAudioCache({
          'id': cacheKey,
          'char_id': '_audition',
          'text': _auditionText,
          'file_path': filePath,
          'file_size': wav.length,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'last_used_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      await _player.setFilePath(filePath);
      await _player.play();
      _player.playerStateStream.listen((st) {
        if (st.processingState == ProcessingState.completed) {
          _player.stop();
          if (mounted) setState(() => _playingId = null);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _playingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('试听失败: $e')),
        );
      }
    }
  }

  /// 设为某角色的默认音色
  Future<void> _setAsDefault(Map<String, dynamic> voice) async {
    final app = Provider.of<AppState>(context, listen: false);
    final chars = app.characters;
    if (chars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有角色，请先创建')),
      );
      return;
    }
    final remoteName = voice['remote_name'] as String;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('设为哪个角色的默认音色？'),
        children: chars
            .map((c) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, c.id),
                  child: Text(c.name),
                ))
            .toList(),
      ),
    );
    if (picked != null) {
      await DatabaseHelper.instance.updateCharacterVoice(picked, remoteName);
      await app.loadCharacters();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已设为「${chars.firstWhere((c) => c.id == picked).name}」的默认音色')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('音色'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadVoices,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _voices.isEmpty
              ? const Center(child: Text('暂无音色\n点右下角 + 克隆一个', textAlign: TextAlign.center))
              : RefreshIndicator(
                  onRefresh: _loadVoices,
                  child: ListView.builder(
                    itemCount: _voices.length,
                    itemBuilder: (_, i) {
                      final v = _voices[i];
                      final rn = v['remote_name'] as String;
                      final displayName = v['name'] as String? ?? rn;
                      final isPlaying = _playingId == rn;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              isPlaying ? Colors.blue : Colors.grey.shade300,
                          child: Icon(
                            isPlaying ? Icons.volume_up : Icons.record_voice_over,
                            color: isPlaying ? Colors.white : Colors.black54,
                          ),
                        ),
                        title: Text(displayName),
                        subtitle: Text(rn),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow),
                              tooltip: '试听',
                              onPressed: () => _audition(v),
                            ),
                            IconButton(
                              icon: const Icon(Icons.link),
                              tooltip: '设为角色默认',
                              onPressed: () => _setAsDefault(v),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await Navigator.push(
            context,
            SlideRoute(const CloneVoiceScreen()),
          );
          if (result == true) _loadVoices();
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
