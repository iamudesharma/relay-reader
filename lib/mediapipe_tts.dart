import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mediapipe_audio/mediapipe_audio.dart' as mp;
import 'package:path_provider/path_provider.dart';

/// Stable mapping from the persisted sherpa voice table to Kokoro voice IDs.
const kokoroVoiceIds = [
  'af_alloy',
  'af_aoede',
  'af_bella',
  'af_heart',
  'af_jessica',
  'af_kore',
  'af_nicole',
  'af_nova',
  'af_river',
  'af_sarah',
  'af_sky',
  'am_adam',
  'am_echo',
  'am_eric',
  'am_fenrir',
  'am_liam',
  'am_michael',
  'am_onyx',
  'am_puck',
  'am_santa',
  'bf_alice',
  'bf_emma',
  'bf_isabella',
  'bf_lily',
  'bm_daniel',
  'bm_fable',
  'bm_george',
  'bm_lewis',
];

class MediaPipeSpeechException implements Exception {
  const MediaPipeSpeechException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Optional models have separate stores from bundled Kokoro.
abstract final class MediaPipeModels {
  static Future<mp.ModelStore> store(String name, {http.Client? client}) async {
    final root = await getApplicationSupportDirectory();
    return mp.ModelStore(
      cacheDirectory: '${root.path}/mediapipe/$name',
      client: client,
    );
  }

  static Future<String> path(String name, mp.DownloadAsset model) async {
    final source = await (await store(name)).find(model);
    if (source?.path == null) {
      throw MediaPipeSpeechException(
        name == 'kokoro'
            ? 'Kokoro assets are missing. Run scripts/prepare-reader-voice.sh and rebuild.'
            : 'Download the ${name == 'pocket_tts_en' ? 'Pocket TTS' : 'Phonon'} model in Settings first.',
      );
    }
    return source!.path!;
  }

  static Future<bool> phononInstalled() async =>
      await (await store('phonon')).find(mp.AudioModels.phonon) != null;

  static Future<void> downloadPhonon(
    void Function(int received, int total) onProgress,
  ) async {
    final client = _ProgressClient(onProgress);
    try {
      await (await store('phonon', client: client)).get(mp.AudioModels.phonon);
    } finally {
      client.close();
    }
  }

  static Future<void> deletePhonon() async {
    await phononSpeech.unload();
    await (await store('phonon')).clear();
  }

  static Future<bool> pocketInstalled() async =>
      await (await store('pocket_tts_en')).find(mp.AudioModels.pocketTtsEn) !=
      null;

  static Future<void> downloadPocket(
    void Function(int received, int total) onProgress,
  ) async {
    final client = _ProgressClient(onProgress);
    try {
      await (await store(
        'pocket_tts_en',
        client: client,
      )).get(mp.AudioModels.pocketTtsEn);
    } finally {
      client.close();
    }
  }

  static Future<void> deletePocket() async {
    await pocketSpeech.unload();
    await (await store('pocket_tts_en')).clear();
  }
}

class _ProgressClient extends http.BaseClient {
  _ProgressClient(this.onProgress);
  final void Function(int, int) onProgress;
  final http.Client _client = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _client.send(request);
    var received = 0;
    final total = response.contentLength ?? 0;
    onProgress(0, total);
    return http.StreamedResponse(
      response.stream.map((chunk) {
        received += chunk.length;
        onProgress(received, total);
        return chunk;
      }),
      response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      request: response.request,
      isRedirect: response.isRedirect,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _client.close();
}

final kokoroSpeech = MediaPipeSpeech('kokoro', mp.AudioModels.kokoro);
final phononSpeech = MediaPipeSpeech('phonon', mp.AudioModels.phonon);
final pocketSpeech = MediaPipeSpeech(
  'pocket_tts_en',
  mp.AudioModels.pocketTtsEn,
);

/// Small boundary for exercising task lifecycle without loading native weights.
abstract interface class SpeechTask {
  Future<List<String>> voices();
  Future<({Float32List samples, int rate})> synthesize(
    String text,
    String voice,
  );
  void cancel();
  Future<void> dispose();
}

class _NativeSpeechTask implements SpeechTask {
  _NativeSpeechTask(this.task);
  final mp.TextToSpeech task;
  @override
  Future<List<String>> voices() async =>
      (await task.listVoices()).map((v) => v.voiceId).toList();
  @override
  Future<({Float32List samples, int rate})> synthesize(
    String text,
    String voice,
  ) async {
    final result = await task.synthesize(text, voiceId: voice);
    return (samples: result.samples, rate: result.sampleRateHz);
  }

  @override
  void cancel() => task.cancel();
  @override
  Future<void> dispose() => task.dispose();
}

/// One warm task per model. File creation, model changes and disposal are
/// serialized; cancellation invalidates work even while the model is loading.
class MediaPipeSpeech {
  MediaPipeSpeech(this.name, this.model, {this.openTask});
  final Future<SpeechTask> Function(double speed, bool batterySaver)? openTask;
  final String name;
  final mp.DownloadAsset model;
  SpeechTask? _task;
  double? _speed;
  bool? _batterySaver;
  Set<String> _voices = {};
  Future<void> _tail = Future.value();
  Timer? _idle;
  int _generation = 0;

  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _check(int generation) {
    if (generation != _generation) {
      throw const MediaPipeSpeechException('Speech synthesis cancelled.');
    }
  }

  Future<SpeechTask> _load(double speed, bool batterySaver) async {
    if (_task != null && _speed == speed && _batterySaver == batterySaver) {
      return _task!;
    }
    await _dispose();
    final task = await (openTask ?? _openNative)(speed, batterySaver);
    try {
      _voices = (await task.voices()).toSet();
      if (name == 'kokoro' && !kokoroVoiceIds.every(_voices.contains)) {
        throw const MediaPipeSpeechException(
          'This Kokoro bundle is missing saved character voices.',
        );
      }
      _task = task;
      _speed = speed;
      _batterySaver = batterySaver;
      return task;
    } catch (_) {
      await task.dispose();
      rethrow;
    }
  }

  Future<SpeechTask> _openNative(double speed, bool batterySaver) async {
    final path = await MediaPipeModels.path(name, model);
    final support = await mp.queryTextToSpeechCapabilities();
    final gpu =
        name == 'kokoro' &&
        !batterySaver &&
        support.supportedDelegates.contains(mp.Delegate.gpu);
    return _NativeSpeechTask(
      await mp.TextToSpeech.create(
        mp.TextToSpeechOptions(
          modelPath: path,
          speakingRate: speed,
          delegate: gpu ? mp.Delegate.gpu : mp.Delegate.cpu,
        ),
      ),
    );
  }

  Future<List<String>> voices({bool batterySaver = true}) {
    _idle?.cancel();
    final generation = _generation;
    return _serial(() async {
      _check(generation);
      await _load(1, batterySaver);
      _check(generation);
      return _voices.toList();
    }).whenComplete(release);
  }

  Future<void> synthesizeToFile({
    required String text,
    required String path,
    required String voice,
    double speed = 1,
    double pauses = 1,
    bool batterySaver = true,
  }) {
    _idle?.cancel();
    final generation = _generation;
    return _serial(() async {
      _check(generation);
      final task = await _load(speed, batterySaver);
      _check(generation);
      if (!_voices.contains(voice)) {
        throw MediaPipeSpeechException(
          'The $name voice "$voice" is unavailable.',
        );
      }
      final result = await task.synthesize(text, voice);
      _check(generation);
      final bytes = speechWav(result.samples, result.rate, pauses: pauses);
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      if (generation != _generation) {
        await file.delete();
        _check(generation);
      }
    }).whenComplete(release);
  }

  void cancel() {
    _generation++;
    _task?.cancel();
  }

  void release({Duration after = const Duration(seconds: 60)}) {
    _idle?.cancel();
    _idle = Timer(
      after,
      () => unawaited(_serial(_dispose).catchError((Object _) {})),
    );
  }

  Future<void> unload() {
    _idle?.cancel();
    cancel();
    return _serial(() async {
      _idle?.cancel();
      _idle = null;
      await _dispose();
    });
  }

  Future<void> _dispose() async {
    final task = _task;
    _task = null;
    _speed = null;
    _batterySaver = null;
    _voices = {};
    await task?.dispose();
  }
}

/// PCM16 WAV for just_audio. Scale only sustained internal silence, retaining
/// short gaps inside words and leading/trailing audio. MediaPipe has no native
/// equivalent of sherpa's silenceScale.
Uint8List speechWav(Float32List samples, int rate, {double pauses = 1}) {
  if (samples.isEmpty ||
      rate <= 0 ||
      !pauses.isFinite ||
      pauses <= 0 ||
      samples.any((s) => !s.isFinite)) {
    throw const MediaPipeSpeechException(
      'The speech engine returned invalid audio.',
    );
  }
  final pcm = <int>[];
  var i = 0;
  while (i < samples.length) {
    final start = i;
    if (pauses != 1 && samples[i].abs() < .002) {
      while (i < samples.length && samples[i].abs() < .002) {
        i++;
      }
      final length = i - start;
      if (start > 0 && i < samples.length && length >= rate * .12) {
        pcm.addAll(List.filled((length * pauses).round(), 0));
        continue;
      }
      for (var j = start; j < i; j++) {
        pcm.add((samples[j].clamp(-1, 1) * 32767).round());
      }
    } else {
      pcm.add((samples[i++].clamp(-1, 1) * 32767).round());
    }
  }
  final bytes = Uint8List(44 + pcm.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + 4, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, pcm.length * 2, Endian.little);
  for (var j = 0; j < pcm.length; j++) {
    data.setInt16(44 + j * 2, pcm[j], Endian.little);
  }
  return bytes;
}
