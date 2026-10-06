/// Edge 在线 TTS 服务（免费 neural 语音，无需 API key）。
///
/// 协议：`wss://speech.platform.bing.com`（Edge 浏览器"大声朗读"接口），
/// 鉴权 = 本地可算的 Sec-MS-GEC token（vendored edge_tts 包内置，含时钟
/// 偏差自动校正）。合成结果 mp3 落缓存目录，按 (文本+音色+参数) 哈希复用。
///
/// 播放：audioplayers 播本地 mp3；长回复按句分段逐段合成逐段播放
/// （不等整篇合成完才出声）。任一时刻只有一个播报任务：新请求/stop()
/// 会取消当前任务（代次计数防旧任务回写状态）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:edge_tts/edge_tts.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tts_text.dart';

/// 供 UI 直接展示的音色条目（解耦 edge_tts 的 Voice 类）。
class TtsVoiceInfo {
  final String shortName;
  final String localName;
  final String locale;
  final String gender;

  const TtsVoiceInfo({
    required this.shortName,
    required this.localName,
    required this.locale,
    required this.gender,
  });

  String get displayLabel => '$localName（${locale}）';
}

/// 网络不可达时音色下拉的兜底清单（常用 zh 系；拉取成功后会被覆盖）。
const List<TtsVoiceInfo> kFallbackVoices = [
  TtsVoiceInfo(
      shortName: 'zh-CN-XiaoxiaoNeural',
      localName: '晓晓',
      locale: 'zh-CN',
      gender: 'Female'),
  TtsVoiceInfo(
      shortName: 'zh-CN-XiaoyiNeural',
      localName: '晓伊',
      locale: 'zh-CN',
      gender: 'Female'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunxiNeural',
      localName: '云希',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunyangNeural',
      localName: '云扬',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunjianNeural',
      localName: '云健',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunxiaNeural',
      localName: '云夏',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-liaoning-XiaobeiNeural',
      localName: '小北（辽宁）',
      locale: 'zh-CN-liaoning',
      gender: 'Female'),
  TtsVoiceInfo(
      shortName: 'zh-CN-shaanxi-XiaoniNeural',
      localName: '小妮（陕西）',
      locale: 'zh-CN-shaanxi',
      gender: 'Female'),
];

class EdgeTtsService {
  EdgeTtsService._();
  static final EdgeTtsService instance = EdgeTtsService._();

  final AudioPlayer _player = AudioPlayer();

  /// 代次计数：每次 speak/stop 递增；旧任务的循环发现代次不对即退出。
  int _seq = 0;

  /// 当前正在播报的任务 key（消息 id 或试听标识）；null = 空闲。
  final ValueNotifier<String?> playingKey = ValueNotifier(null);

  bool get isPlaying => playingKey.value != null;

  // ---- 音色列表（30 分钟缓存）----

  List<TtsVoiceInfo>? _voicesCache;
  DateTime _voicesAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<List<TtsVoiceInfo>> listVoices() async {
    final now = DateTime.now();
    if (_voicesCache != null && now.difference(_voicesAt).inMinutes < 30) {
      return _voicesCache!;
    }
    try {
      final manager = await VoicesManager.create().timeout(const Duration(
          seconds: 15));
      final all = manager.voices
          .map((v) => TtsVoiceInfo(
                shortName: v.shortName,
                localName: _extractLocalName(v.friendlyName, v.shortName),
                locale: v.locale,
                gender: v.gender,
              ))
          .toList();
      // zh 系置顶、按 locale 排序，其余排后（下拉列表不淹没中文用户）。
      all.sort((a, b) {
        final az = a.locale.startsWith('zh'), bz = b.locale.startsWith('zh');
        if (az != bz) return az ? -1 : 1;
        return a.locale.compareTo(b.locale);
      });
      _voicesCache = all;
      _voicesAt = now;
      return all;
    } catch (e) {
      debugPrint('[EdgeTts] 音色列表拉取失败，用兜底清单: $e');
      return kFallbackVoices;
    }
  }

  static String _extractLocalName(String friendlyName, String shortName) {
    // FriendlyName 形如 "Microsoft Xiaoxiao Online (Natural) - Chinese
    // (Mandarin, Simplified)"；本地名没有直接字段，取 shortName 里
    // Neural 前段（XiaoxiaoNeural → Xiaoxiao）作为展示名。
    final m = RegExp(r'([A-Za-z]+)Neural$').firstMatch(shortName);
    return m?.group(1) ?? shortName;
  }

  // ---- 合成 ----

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'tts_cache'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _cacheKey(String text, String voice, int rate, int pitch,
          int volume) =>
      sha256.convert(utf8.encode('$voice|$rate|$pitch|$volume|$text'))
          .toString();

  /// 合成一段文本到缓存文件；失败返回 null（调用方静默降级）。
  Future<File?> _synthesize(String text,
      {required String voice,
      required int rate,
      required int pitch,
      required int volume}) async {
    try {
      final comm = Communicate(
        text: text,
        voice: voice,
        rate: _signed(rate, '%'),
        pitch: _signed(pitch, 'Hz'),
        volume: _signed(volume, '%'),
      );
      final bytes = await comm.toBytes().timeout(const Duration(seconds: 60));
      if (bytes.isEmpty) return null;
      final dir = await _cacheDir();
      final file = File(p.join(
          dir.path,
          '${_cacheKey(text, voice, rate, pitch, volume)}.mp3'));
      await file.writeAsBytes(bytes);
      return file;
    } catch (e) {
      debugPrint('[EdgeTts] 合成失败: $e');
      return null;
    }
  }

  static String _signed(int v, String unit) =>
      '${v >= 0 ? '+' : ''}$v$unit';

  // ---- 播报 ----

  /// 朗读 [text]（先清洗再分段）。[key] 标识播报来源（消息 id / 'preview'），
  /// UI 通过 [playingKey] 显示播放态并支持再次点按停止。
  /// 返回 true = 完整播完；false = 被停止/取消或合成失败。
  Future<bool> speak(
    String rawText, {
    String key = 'preview',
    required String voice,
    required int rate,
    required int pitch,
    required int volume,
  }) async {
    final text = cleanTextForTts(rawText);
    if (text.isEmpty) return false;
    if (isPlaying && playingKey.value == key) {
      // 同一按钮再点 = 停止。
      await stop();
      return false;
    }
    await stop();
    final seq = ++_seq;
    playingKey.value = key;
    try {
      final segments = segmentForTts(text);
      for (var i = 0; i < segments.length; i++) {
        if (seq != _seq) return false;
        final file = await _synthesize(segments[i],
            voice: voice, rate: rate, pitch: pitch, volume: volume);
        if (seq != _seq) return false;
        if (file == null) return false;
        await _playFile(file, seq);
      }
      return true;
    } finally {
      if (seq == _seq) playingKey.value = null;
    }
  }

  /// 停止当前播报（若有）：代次递增让后台循环退出 + 停掉播放器。
  Future<void> stop() async {
    _seq++;
    if (playingKey.value != null) playingKey.value = null;
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// 播放一个本地文件直到结束（代次不符 → 立即返回不播）。
  ///
  /// audioplayers 6.x 的播放错误直接从 play() 抛出（await 捕获即可）。
  Future<void> _playFile(File file, int seq) async {
    final completer = Completer<void>();
    late final StreamSubscription<void> sub;
    sub = _player.onPlayerComplete.listen((_) {
      sub.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    try {
      if (seq != _seq) return;
      await _player.play(DeviceFileSource(file.path));
      await completer.future.timeout(const Duration(minutes: 10),
          onTimeout: () {});
    } catch (e) {
      debugPrint('[EdgeTts] play 异常: $e');
    } finally {
      await sub.cancel();
    }
  }

  /// 清空缓存目录（超出龄的 mp3 文件）；返回删除的文件数。
  Future<int> clearCache() async {
    try {
      final dir = await _cacheDir();
      var n = 0;
      await for (final f in dir.list()) {
        if (f is File) {
          await f.delete();
          n++;
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }
}
