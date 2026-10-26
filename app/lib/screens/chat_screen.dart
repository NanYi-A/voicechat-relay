import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/character.dart';
import '../models/message.dart';
import '../providers/app_state.dart';
import '../services/database.dart';
import '../services/deepseek.dart';
import '../services/memory.dart';
import '../services/sticker.dart';
import '../services/tts.dart';
import '../services/cloud_status.dart';
import '../widgets/message_bubble.dart';
import 'sticker_manage_screen.dart';
import 'settings_screen.dart';

/// M5/M6/M7 聊天页：流式聊天 + 句级 TTS 流水线 + 离线预热
class ChatScreen extends StatefulWidget {
  final Character character;
  const ChatScreen({super.key, required this.character});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _player = AudioPlayer();
  final Dio _dio = Dio();

  List<Message> _messages = [];
  bool _online = true;
  bool _playing = false;
  bool _stopTts = false;
  String _ttsHint = '';
  // 预合成：AI 回复收到后(onDone)立即后台合成整段 WAV，
  // 点喇叭时若已完成直接播放，否则等待完成再播放
  String? _prefetchMsgId; // 正在预合成的消息 ID
  Future<String>? _prefetchFuture; // 预合成 future（返回 wav 文件路径）
  // 逐句打字效果：流式期间显示"正在输入…"，onDone 后逐个揭示气泡
  bool _typing = false; // 流式期间显示"正在输入…"指示器
  String? _revealedMsgId; // 正在渐进揭示的消息 ID（null=不在揭示中）
  int _revealedCount = 0; // 已揭示的气泡数量
  // §9 表情包：message_id -> {segment位置索引: 表情包文件路径}
  final Map<String, Map<int, String>> _stickers = {};

  late final DeepSeekService _deepseek;
  late final TtsService _tts;
  late final StatusService _status;
  StreamSubscription<String>? _sub;
  int _streamToken = 0; // 每次发起/中断流式自增，用于在途旧流回调失效

  @override
  void initState() {
    super.initState();
    final app = Provider.of<AppState>(context, listen: false);
    _deepseek = DeepSeekService(_dio);
    _tts = TtsService(_dio, app.cloudUrl, app.cloudToken);
    _status = StatusService(_dio, app.cloudUrl, app.cloudToken);
    _loadMessages();
    _checkOnline();
  }

  Future<void> _loadMessages() async {
    _messages = await DatabaseHelper.instance.getMessages(widget.character.id);
    // §9：加载历史表情包（含位置索引）
    final d = await DatabaseHelper.instance.db;
    final rows = await d.query('sticker_messages', orderBy: 'created_at ASC');
    _stickers.clear();
    for (final r in rows) {
      final msgId = r['message_id'] as String;
      final path = r['sticker_path'] as String;
      final pos = (r['position'] as int?) ?? 0;
      _stickers.putIfAbsent(msgId, () => {})[pos] = path;
    }
    if (mounted) setState(() {});
    _scrollToEnd();
  }

  Future<void> _checkOnline() async {
    _online = await _status.getOnline();
    if (mounted) setState(() {});
  }

  // v3: 缓存 key 纳入音色 voice——换音色(如 zxy 从官方示例音改为真人声)自动重合成；
  //     同时版本号使旧缓存(静音/旧音色)全部失效。
  String _cacheKey(String text, String voice) =>
      sha256.convert(utf8.encode('${widget.character.id}|$text|$voice|tts_v4')).toString();

  // ---------- M5 发送 + 流式 ----------
  void _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _interruptStream(); // 中断当前流式（半截丢弃不存）
    _ctrl.clear();
    // 立即显示"正在输入…"指示器（不等 DB 写入）
    _typing = true;
    await _appendMessage(Message(
      id: _id(),
      charId: widget.character.id,
      role: 'user',
      content: text,
      createdAt: _now(),
    ));
    _stream(text); // _stream 内部会再设 _typing = true（幂等）
  }

  /// 中断当前流式回复：取消订阅 + 作废在途旧流回调 + 清空半截气泡（不写 messages 表）
  void _interruptStream() {
    _sub?.cancel();
    _sub = null;
    _streamToken++; // 让任何在途的旧流 onDone/onError 变 no-op
    _typing = false;
    _revealedMsgId = null; // 渐进揭示中断：立即显示全部气泡
    if (mounted) setState(() {});
  }

  void _stream(String userText) async {
    _sub?.cancel(); // 兜底：清掉任何遗漏的订阅
    final myToken = ++_streamToken; // 本次流的唯一令牌
    if (mounted) setState(() => _typing = true); // 立即显示"正在输入…"
    final app = Provider.of<AppState>(context, listen: false);
    String raw = '';
    final history = await _buildHistory();
    if (myToken != _streamToken) return; // 等待期间已被新消息打断，放弃
    // §8：注入最新记忆摘要
    final memRow = await DatabaseHelper.instance.getLatestMemory(widget.character.id);
    final memorySummary = memRow?['summary'] as String?;
    if (myToken != _streamToken) return;
    _sub = _deepseek
        .streamChat(
          apiKey: app.deepseekKey ?? '',
          personaMd: widget.character.personaMd,
          history: history,
          userText: userText,
          memorySummary: memorySummary,
        )
        .listen(
      (delta) {
        if (myToken != _streamToken) return; // 已打断，丢弃增量
        raw += delta;
        // 流式期间只显示"正在输入…"指示器，不显示半截气泡
        // raw 静默累积，onDone 后逐句揭示
      },
      onDone: () {
        if (myToken != _streamToken) return; // 已打断，半截丢弃不存
        // 提取末尾 ["emotion"] 隐藏标签（不显示在气泡中）
        final tailEmotion = _extractTailEmotion(raw);
        final content = _stripTailEmotion(raw);
        final msgId = _id();
        final msg = Message(
          id: msgId,
          charId: widget.character.id,
          role: 'assistant',
          content: content, // 保留内联 <emotion> 标签，去掉末尾 ["xx"]
          createdAt: _now(),
        );
        // 立即落库 + 加入 _messages（朗读、长按等功能可用）
        DatabaseHelper.instance.insertMessage(msg);
        _messages.add(msg);
        // 收到回复即开始后台预合成（与逐句揭示并行）
        _prefetchAudio(msg.content, msgId);
        // §8：满 50 轮异步生成记忆摘要（不阻塞 UI）
        _maybeSummarize();
        // §9：内联 emotion 段优先；无则用末尾情绪兜底
        _rollInlineStickers(msg, msgId, tailEmotion);
        // 停止"正在输入…"指示器，开始逐句揭示
        _typing = false;
        final segs = msg.segments;
        if (segs.isEmpty) {
          if (mounted) setState(() {});
          return;
        }
        _revealProgressively(msg, myToken);
      },
      onError: (_) {
        if (myToken != _streamToken) return; // 已打断则静默
        _typing = false;
        _revealedMsgId = null;
        if (mounted) setState(() {});
      },
    );
  }

  // 历史：近 15 轮（不含主动消息），content 用原文（含 /）
  Future<List<Map<String, String>>> _buildHistory() async {
    var msgs = (await DatabaseHelper.instance.getMessages(widget.character.id))
        .where((m) => m.isProactive == 0)
        .toList();
    // 当前这条 user 消息已落库，而 streamChat 会在请求末尾再追加 userText，
    // 必须在这里剔除末尾的当前用户消息，否则同一句话在请求里出现两遍
    if (msgs.isNotEmpty && msgs.last.role == 'user') {
      msgs.removeLast();
    }
    // §7.5 Prompt Caching：不能每轮裁一次（每超 30 条就砍会导致每轮请求前缀都变，
    // DeepSeek 自动前缀缓存全部失效）。改为超过 36 条才一次性裁回 30 条，
    // 两次裁剪之间前缀逐轮稳定增长，缓存命中率最大化。
    if (msgs.length > 36) {
      msgs = msgs.sublist(msgs.length - 30);
      // 保证历史以 user 消息开头（避免孤立的 assistant 开头让模型困惑）
      while (msgs.isNotEmpty && msgs.first.role != 'user') {
        msgs.removeAt(0);
      }
    }
    return msgs
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
  }

  /// §8 记忆摘要：满 50 轮（100 条非主动消息）异步触发，不阻塞聊天
  bool _summarizing = false;
  void _maybeSummarize() async {
    if (_summarizing) return;
    final trigger = await SettingsScreen.getMemoryTrigger();
    final count = await DatabaseHelper.instance.countNonProactiveMessages(widget.character.id);
    if (count < trigger) return;
    // 检查是否已有摘要覆盖了当前消息（避免重复生成）
    final latest = await DatabaseHelper.instance.getLatestMemory(widget.character.id);
    if (latest != null) {
      final lastCovered = latest['covers_msg_ids'] as String? ?? '';
      // 如果最新摘要覆盖的消息数 >= 当前总数 - 30，说明还没积累够新对话
      final coveredCount = lastCovered.isEmpty ? 0 : int.tryParse(lastCovered) ?? 0;
      if (count - coveredCount < trigger) return;
    }
    _summarizing = true;
    try {
      final app = Provider.of<AppState>(context, listen: false);
      final key = app.deepseekKey;
      if (key == null || key.isEmpty) return;
      // 取 15 轮之前的消息做摘要（近 30 条留给上下文窗口）
      final allMsgs = (await DatabaseHelper.instance.getMessages(widget.character.id))
          .where((m) => m.isProactive == 0)
          .toList();
      final toSummarize = allMsgs.length > 30
          ? allMsgs.sublist(0, allMsgs.length - 30)
          : allMsgs;
      if (toSummarize.isEmpty) return;
      final historyForSummary = toSummarize
          .map((m) => {'role': m.role, 'content': m.content.replaceAll('/', '。')})
          .toList();
      final svc = MemoryService(Dio());
      final summary = await svc.summarize(apiKey: key, messages: historyForSummary);
      if (summary.isNotEmpty) {
        await DatabaseHelper.instance.insertMemory({
          'id': _id(),
          'char_id': widget.character.id,
          'summary': summary,
          'covers_msg_ids': '${toSummarize.length}',
          'created_at': _now(),
        });
      }
    } catch (_) {
      // 摘要失败静默，不影响聊天
    } finally {
      _summarizing = false;
    }
  }

  /// §9 内联表情包：
  /// 优先：模型输出了内联 <emotion> 段 → 按位置掷骰插入
  /// 兜底：无内联段 → 用末尾 ["情绪"] 标签，对每句按 30%×概率 掷骰，总数≤次数上限
  void _rollInlineStickers(Message msg, String msgId, String? fallbackEmotion) async {
    final (prob, count) = await StickerManageScreen.getSettings();
    if (prob <= 0 || count <= 0) return;
    final segs = msg.segments;
    final hits = <int, String>{};

    // 检查是否有内联 emotion 段
    var hasEmotionSeg = false;
    for (var i = 0; i < segs.length; i++) {
      final (type, value) = segs[i];
      if (type != 'emotion') continue;
      hasEmotionSeg = true;
      final key = StickerService.normalizeEmotion(value) ?? 'happy';
      for (var r = 0; r < count; r++) {
        if (Random().nextDouble() * 100 < prob) {
          final path = await StickerService.pickRandom(key);
          if (path != null) {
            hits[i] = path;
            break;
          }
        }
      }
    }

    // 兜底：无内联段 → 用末尾情绪，每句 30%×概率 掷骰，上限 count 张
    if (!hasEmotionSeg) {
      final key = StickerService.normalizeEmotion(fallbackEmotion) ?? 'happy';
      var sent = 0;
      for (var i = 0; i < segs.length && sent < count; i++) {
        if (segs[i].$1 != 'text') continue;
        if (Random().nextDouble() < 0.30 * (prob / 100)) {
          final path = await StickerService.pickRandom(key);
          if (path != null) {
            hits[i] = path;
            sent++;
          }
        }
      }
    }

    if (hits.isEmpty) return;
    // 持久化到 sticker_messages 表（含 position）
    final d = await DatabaseHelper.instance.db;
    for (final entry in hits.entries) {
      await d.insert('sticker_messages', {
        'id': _id(),
        'message_id': msgId,
        'emotion': segs[entry.key].$2,
        'sticker_path': entry.value,
        'position': entry.key,
        'created_at': _now(),
      });
    }
    _stickers[msgId] = hits;
    if (mounted) setState(() {});
  }

  // ---------- 逐句打字效果 ----------
  // onDone 后逐段揭示：文字段按字数延迟，emotion 段短延迟；模拟真人打字节奏
  void _revealProgressively(Message msg, int myToken) async {
    final segs = msg.segments;
    _revealedMsgId = msg.id;
    _revealedCount = 0;
    if (mounted) setState(() {});
    _scrollToEnd();

    for (int i = 0; i < segs.length; i++) {
      if (myToken != _streamToken) {
        // 被新消息打断：立即显示全部
        _revealedMsgId = null;
        if (mounted) setState(() {});
        return;
      }

      if (i == 0) {
        _revealedCount = 1;
      } else {
        final (type, value) = segs[i];
        int delayMs;
        if (type == 'text') {
          final len = value.length;
          final baseMs = len * 80;
          final jitter = Random().nextInt(500) + 300;
          delayMs = (baseMs + jitter + 500).clamp(600, 3500);
        } else {
          delayMs = 300; // emotion 段短延迟
        }
        await Future.delayed(Duration(milliseconds: delayMs));
        if (myToken != _streamToken) {
          _revealedMsgId = null;
          if (mounted) setState(() {});
          return;
        }
        _revealedCount = i + 1;
      }
      if (mounted) setState(() {});
      _scrollToEnd();
    }

    // 全部揭示完成
    _revealedMsgId = null;
    if (mounted) setState(() {});
  }

  // ---------- 消息落库 ----------
  Future<void> _appendMessage(Message m) async {
    await DatabaseHelper.instance.insertMessage(m);
    _messages.add(m);
    if (mounted) setState(() {});
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(0); // reverse:true → 0 即底部（最新消息）
      }
    });
  }

  // ---------- M6 朗读：整段合成 + 连续播放 ----------
  // 合成时机：AI 回复收到后(onDone)立即后台预合成（_prefetchAudio）；
  // 点喇叭时：若预合成已完成直接播放，否则等待预合成完成再播放。
  // 之前踩过的坑：逐句独立合成+流水线播放在 daemon 单 GPU 串行队列下
  // 句间仍需空等合成，反而不如整段一次合成连贯；故改回整段方案，
  // 只把合成时机从"点喇叭"前移到"收到回复"。
  Future<void> _readAloud() async {
    final last = _messages.lastWhere(
      (m) => m.role == 'assistant',
      orElse: () => Message(
        id: '',
        charId: widget.character.id,
        role: 'assistant',
        content: '',
        createdAt: 0,
      ),
    );
    if (last.content.isEmpty) return;
    final sents = last.bubbles;
    if (sents.isEmpty) return;

    setState(() => _playing = true);
    _stopTts = false;
    try {
      String path;
      // 若已有预合成在跑（收到回复时就启动了），直接等它完成
      if (_prefetchMsgId == last.id && _prefetchFuture != null) {
        if (mounted) setState(() => _ttsHint = '正在准备语音…');
        path = await _prefetchFuture!;
        // 预合成失败（返回空串）则现场重试
        if (path.isEmpty) {
          if (mounted) setState(() => _ttsHint = '正在合成语音…');
          path = await _ensureAudio(sents);
        }
      } else {
        // 旧消息（预合成已过期或从未预合成），现场合成
        if (mounted) setState(() => _ttsHint = '正在合成语音…');
        path = await _ensureAudio(sents);
      }
      if (mounted) setState(() => _ttsHint = '');
      if (_stopTts) return;
      await _playFile(path);
    } on Exception catch (e) {
      // 所有异常都可见，避免静默失败（之前 401 / 播放异常被吞）
      final msg = e.toString();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg.contains('tts_unavailable')
                ? '语音服务不可用（电脑离线）'
                : msg.contains('no_voice_configured')
                    ? '该角色未设置音色，请到「音色」选择或新建'
                    : '朗读失败: $msg'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      print('[readAloud] error: $msg');
    } finally {
      if (mounted) {
        setState(() => _playing = false);
        setState(() => _ttsHint = '');
      }
    }
  }

  /// 提取末尾 ["emotion"] 隐藏标签
  static final _tailEmotionRe = RegExp(r'\["(\w+)"\]\s*$');
  String? _extractTailEmotion(String raw) {
    final m = _tailEmotionRe.firstMatch(raw);
    return m?.group(1);
  }

  String _stripTailEmotion(String raw) =>
      raw.replaceAll(_tailEmotionRe, '').trim();

  /// 从原始 content 提取纯文字段（过滤 <emotion> 段），供 TTS 合成
  static final _emotionSegRe = RegExp(r'^<emotion>.*?</emotion>$');
  List<String> _textBubbles(String raw) {
    if (raw.contains('/')) {
      return raw.split('/').map((e) => e.trim())
          .where((e) => e.isNotEmpty && !_emotionSegRe.hasMatch(e)).toList();
    }
    if (raw.contains('\n')) {
      return raw.split(RegExp(r'\n+')).map((e) => e.trim())
          .where((e) => e.isNotEmpty && !_emotionSegRe.hasMatch(e)).toList();
    }
    return [raw];
  }

  /// 收到 AI 回复后立即后台预合成整段语音（fire-and-forget）
  /// 点喇叭时若已完成则直接播放，否则等待完成；预合成失败静默，点喇叭时会重试并提示
  void _prefetchAudio(String content, String msgId) {
    _prefetchMsgId = msgId;
    _prefetchFuture = _ensureAudio(_textBubbles(content)).catchError((e) {
      print('[prefetch] failed: $e');
      return '';
    });
  }

  /// 整段合成：把所有句子一次性发给 daemon 合成拼接成一个连续 WAV
  /// 句级 cache key = hash(charId|全文|音色|版本)，换音色/换版本自动重合成
  Future<String> _ensureAudio(List<String> texts) async {
    final joined = texts.join('/');
    final key = _cacheKey(joined, _resolveVoice(widget.character));
    final existing = await DatabaseHelper.instance.getAudioCachePath(key);
    if (existing != null && File(existing).existsSync()) {
      await DatabaseHelper.instance.updateAudioCacheLastUsed(key, _now());
      return existing;
    }
    final wav = await _tts.synthesize(
      charId: widget.character.id,
      texts: texts,
      voice: _resolveVoice(widget.character),
    );
    print('[tts] synthesized bytes=${wav.length} sents=${texts.length} first="${texts.isNotEmpty ? (texts[0].length > 12 ? texts[0].substring(0, 12) : texts[0]) : ''}"');
    final dir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${dir.path}/audio');
    await audioDir.create(recursive: true);
    final path = '${audioDir.path}/$key.wav';
    await File(path).writeAsBytes(wav);
    await DatabaseHelper.instance.insertAudioCache({
      'id': key,
      'char_id': widget.character.id,
      'text': joined,
      'file_path': path,
      'file_size': wav.length,
      'created_at': _now(),
      'last_used_at': _now(),
    });
    return path;
  }

  Future<void> _playFile(String path) async {
    try {
      await _player.stop();
      await _player.setVolume(1.0);
      await _player.setFilePath(path);
      await _player.play();
      print('[tts] playing $path');
      final done = Completer<void>();
      final sub = _player.playerStateStream.listen((st) {
        if (!st.playing && st.processingState == ProcessingState.completed) {
          if (!done.isCompleted) done.complete();
        }
      });
      // 兜底超时：按文件大小估算（16bit 单声道 24000Hz ≈ 48KB/s），最长 60s
      final f = File(path);
      final bytes = await f.length().catchError((_) => 0);
      final estSec = (bytes / 48000).ceil().clamp(3, 60) + 1;
      final deadline = DateTime.now().add(Duration(seconds: estSec));
      while (!done.isCompleted && !_stopTts && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      await sub.cancel();
    } catch (e) {
      throw Exception('play_failed:$e');
    }
  }

  // 角色存的 defaultVoice 已是带命名空间的 remote_name（如 user1::voice_a）。
  // 直接原样返回，交给云端 /api/tts 做归属校验；为空说明该角色未绑定音色，
  // 抛清晰异常让上层提示用户去「音色」选择/新建，而非静默回落到他人音色。
  String _resolveVoice(Character c) {
    final v = c.defaultVoice;
    if (v != null && v.trim().isNotEmpty) return v.trim();
    throw Exception('no_voice_configured');
  }

  void _stopRead() {
    _stopTts = true;
    _player.stop();
    setState(() => _playing = false);
  }

  // ---------- §15 消息操作：长按复制 / 长按 AI 回复重新生成 ----------
  void _showMessageMenu(Message m) {
    // 重新生成仅对"最后一条助手回复"开放，避免新回复追加到末尾打乱上下文
    final canRegenerate = m.role == 'assistant' &&
        _messages.isNotEmpty &&
        _messages.last.id == m.id;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制'),
              onTap: () {
                Navigator.pop(ctx);
                _copyMessage(m);
              },
            ),
            if (canRegenerate)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重新生成'),
                onTap: () {
                  Navigator.pop(ctx);
                  _regenerate(m);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyMessage(Message m) async {
    // 复制可读文本：用 bubbles（已过滤 emotion 段），拼接为自然标点
    final text = m.bubbles.join('，');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制'), duration: Duration(seconds: 2)),
      );
    }
  }

  /// 重新生成：删除该 AI 回复，并以其前面最近的用户消息为 prompt 重新请求
  Future<void> _regenerate(Message aiMsg) async {
    final idx = _messages.indexOf(aiMsg);
    String? userText;
    for (int j = idx - 1; j >= 0; j--) {
      if (_messages[j].role == 'user') {
        userText = _messages[j].content;
        break;
      }
    }
    if (userText == null || userText.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('无法重新生成：找不到对应的用户消息'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _interruptStream();
    setState(() => _messages.removeWhere((m) => m.id == aiMsg.id));
    await DatabaseHelper.instance.deleteMessage(aiMsg.id);
    _stream(userText);
  }

  String _id() => '${_now()}_${Random().nextInt(9999)}';
  int _now() => DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    _sub?.cancel();
    _streamToken++; // 作废在途回调，避免回调已释放的 state
    _player.dispose();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 按段构建消息 widgets：text→气泡，emotion→内联表情包（命中时）
  List<Widget> _buildSegmentWidgets(Message m, List<(String, String)> segs, int limit) {
    final widgets = <Widget>[];
    final stickerMap = _stickers[m.id];
    for (var i = 0; i < limit && i < segs.length; i++) {
      final (type, value) = segs[i];
      if (type == 'text') {
        widgets.add(MessageBubble(text: value, isUser: m.role == 'user'));
        // 兜底表情包可能挂在 text 段索引上，显示在该气泡之后
        final path = stickerMap?[i];
        if (path != null) {
          widgets.add(_stickerImage(path));
        }
      } else {
        // emotion 段：有表情包则显示，否则跳过
        final path = stickerMap?[i];
        if (path != null) {
          widgets.add(_stickerImage(path));
        }
      }
    }
    return widgets;
  }

  Widget _stickerImage(String path) => Padding(
        padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            width: 120,
            height: 120,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      );

  // ---------- UI ----------
  /// "正在输入…"指示器：左对齐灰色气泡 + 小转圈，风格与 MessageBubble 一致
  Widget _buildTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.grey.shade500),
              ),
            ),
            const SizedBox(width: 8),
            Text('正在输入…',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readDisabled = !_online && !_playing;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.character.name),
        actions: [
          IconButton(
            icon: Icon(_online ? Icons.cloud_done : Icons.cloud_off),
            tooltip: _online ? '电脑在线' : '电脑离线',
            onPressed: _checkOnline,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              reverse: true, // 聊天页从底部开始，新消息自动在底部
              padding: const EdgeInsets.all(8),
              itemCount: _messages.length + (_typing ? 1 : 0),
              itemBuilder: (ctx, i) {
                // reverse:true → i=0 是底部（最新消息）
                if (_typing && i == 0) return _buildTypingIndicator();
                final msgIdx = _messages.length - 1 - (i - (_typing ? 1 : 0));
                final m = _messages[msgIdx];
                final segs = m.segments;
                // 渐进揭示中的消息：只显示已揭示的段，禁用长按
                final revealing =
                    m.id == _revealedMsgId && _revealedCount < segs.length;
                if (revealing) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildSegmentWidgets(m, segs, _revealedCount),
                  );
                }
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => _showMessageMenu(m),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildSegmentWidgets(m, segs, segs.length),
                  ),
                );
              },
            ),
          ),
          if (_ttsHint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  Text(_ttsHint, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          if (!_online)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Text('电脑离线：已缓存音频仍可播放',
                  style: TextStyle(color: Colors.orange, fontSize: 12)),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  icon: _playing
                      ? const Icon(Icons.stop)
                      : const Icon(Icons.volume_up),
                  onPressed: _messages.isEmpty || readDisabled
                      ? null
                      : (_playing ? _stopRead : _readAloud),
                  tooltip: '朗读',
                ),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      hintText: '说点什么…',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _send),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
