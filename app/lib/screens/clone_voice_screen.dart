import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/database.dart';
import '../services/tts.dart';
import '../services/voices.dart';

/// §11 音色克隆页：选 WAV + 填原文 + 克隆 + 自动试听确认
class CloneVoiceScreen extends StatefulWidget {
  const CloneVoiceScreen({super.key});
  @override
  State<CloneVoiceScreen> createState() => _CloneVoiceScreenState();
}

class _CloneVoiceScreenState extends State<CloneVoiceScreen> {
  final _nameCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  Uint8List? _wavBytes;
  String? _fileName;
  bool _busy = false;
  String? _status;
  final AudioPlayer _player = AudioPlayer();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _textCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
    );
    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final bytes = await file.readAsBytes();
      setState(() {
        _wavBytes = bytes;
        _fileName = result.files.single.name;
      });
    }
  }

  Future<void> _clone() async {
    final voiceName = _nameCtrl.text.trim();
    final text = _textCtrl.text.trim();
    if (_wavBytes == null) {
      _snack('请先选择 WAV 录音文件');
      return;
    }
    if (voiceName.isEmpty) {
      _snack('请填写音色名称');
      return;
    }
    if (text.isEmpty) {
      _snack('请填写录音对应的原文');
      return;
    }

    final app = Provider.of<AppState>(context, listen: false);
    setState(() {
      _busy = true;
      _status = '正在克隆，请等待（约 10~30 秒）...';
    });

    try {
      final svc = VoiceService(Dio(), app.cloudUrl, app.cloudToken);
      final result = await svc.clone(
        wavBytes: _wavBytes!,
        fileName: _fileName ?? 'recording.wav',
        text: text,
        voiceName: voiceName,
      );
      final remoteName = result['remote_name'] as String;

      // 落本地 voices 表
      await DatabaseHelper.instance.upsertVoice({
        'id': remoteName,
        'name': voiceName,
        'remote_name': remoteName,
        'status': 'active',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

      setState(() => _status = '克隆成功！正在合成测试语音...');

      // §11.1：克隆后自动合成测试语音供试听
      await _playTest(app, remoteName);

      setState(() {
        _status = '试听完毕，觉得满意就点「确认保存」';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _status = '克隆失败: $e';
      });
    }
  }

  static const _testText = '你好呀，我是刚刚克隆出来的声音，你觉得我像不像原来的那个人呢？';

  Future<void> _playTest(AppState app, String remoteName) async {
    try {
      final cacheKey = sha256
          .convert(utf8.encode('_clone_test|$_testText|$remoteName|tts_v4'))
          .toString();
      final cached = await DatabaseHelper.instance.getAudioCache(cacheKey);
      String filePath;

      if (cached != null && File(cached['file_path'] as String).existsSync()) {
        filePath = cached['file_path'] as String;
        await DatabaseHelper.instance
            .updateAudioCacheLastUsed(cacheKey, DateTime.now().millisecondsSinceEpoch);
      } else {
        final tts = TtsService(Dio(), app.cloudUrl, app.cloudToken);
        final wav = await tts.synthesize(
          charId: '_clone_test',
          text: _testText,
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
          'char_id': '_clone_test',
          'text': _testText,
          'file_path': filePath,
          'file_size': wav.length,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'last_used_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      await _player.setFilePath(filePath);
      await _player.play();
    } catch (e) {
      setState(() => _status = '测试语音合成失败（不影响克隆结果）: $e');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('克隆音色')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '请上传 2~10 秒、无背景噪音、音量正常的清晰人声录音（WAV 格式）',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),
            // 选文件
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.audio_file),
              label: Text(_fileName ?? '选择 WAV 录音文件'),
            ),
            const SizedBox(height: 16),
            // 音色名
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '音色名称 *',
                hintText: '如：小明、妈妈的声音',
              ),
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            // 原文
            TextField(
              controller: _textCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '录音对应原文 *',
                hintText: '逐字打出录音里说的话',
                alignLabelWithHint: true,
              ),
              enabled: !_busy,
            ),
            const SizedBox(height: 24),
            // 克隆按钮
            ElevatedButton(
              onPressed: _busy ? null : _clone,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('开始克隆'),
            ),
            const SizedBox(height: 16),
            // 状态
            if (_status != null)
              Text(_status!, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 24),
            // 确认保存（克隆成功后返回）
            if (_status != null && _status!.contains('试听完毕'))
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认保存，返回音色列表'),
              ),
          ],
        ),
      ),
    );
  }
}
