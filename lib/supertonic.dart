import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'mediapipe_tts.dart';
import 'verified_model_bundle.dart';

abstract final class SupertonicModel {
  static const revision =
      '2b5b939dfa1bca362c5212dcafeb8aadde90b1bc-ane-int4-v1';
  static const displaySize = '172 MB';
  static bool get supported {
    if (!Platform.isIOS && !Platform.isMacOS) return false;
    final major =
        int.tryParse(
          RegExp(r'\d+')
                  .firstMatch(Platform.operatingSystemVersion)
                  ?.group(0) ??
              '',
        ) ??
        0;
    return Platform.isIOS ? major >= 18 : major >= 15;
  }

  static const voices = {
    'M1': 'Male 1',
    'M2': 'Male 2',
    'M3': 'Male 3',
    'M4': 'Male 4',
    'M5': 'Male 5',
    'F1': 'Female 1',
    'F2': 'Female 2',
    'F3': 'Female 3',
    'F4': 'Female 4',
    'F5': 'Female 5',
  };
  static const languages = {
    'en': 'English',
    'ar': 'Arabic',
    'bg': 'Bulgarian',
    'hr': 'Croatian',
    'cs': 'Czech',
    'da': 'Danish',
    'nl': 'Dutch',
    'et': 'Estonian',
    'fi': 'Finnish',
    'fr': 'French',
    'de': 'German',
    'el': 'Greek',
    'hi': 'Hindi',
    'hu': 'Hungarian',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'lv': 'Latvian',
    'lt': 'Lithuanian',
    'pl': 'Polish',
    'pt': 'Portuguese',
    'ro': 'Romanian',
    'ru': 'Russian',
    'sk': 'Slovak',
    'sl': 'Slovenian',
    'es': 'Spanish',
    'sv': 'Swedish',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'vi': 'Vietnamese',
  };
  static Future<Map<String, dynamic>>? _manifest;
  static Future<Map<String, dynamic>> manifest() => _manifest ??= rootBundle
      .loadString('assets/supertonic/manifest.json')
      .then((text) => jsonDecode(text) as Map<String, dynamic>);
  static Future<Directory> directory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/supertonic3/$revision',
  );
  static final bundle = VerifiedModelBundle(
    directory: directory,
    manifest: manifest,
    verifyFiles: (path, files) async =>
        await SupertonicNarration.channel.invokeMethod<bool>('verify', {
          'path': path,
          'files': files,
        }) ??
        false,
  );
  static Future<bool> isInstalled() => bundle.installed();
  static Future<void> download(void Function(int, int) onProgress) =>
      bundle.download(onProgress);
  static Future<void> delete() async {
    await SupertonicNarration.unload();
    await bundle.delete();
  }
}

abstract final class SupertonicNarration {
  static const channel = MethodChannel('relay_reader/supertonic3');
  static Future<void> _tail = Future.value();
  static Timer? _idle;
  static bool _loaded = false;
  static bool get isLoaded => _loaded;
  static bool _nativeRequested = false;
  static int _generation = 0;
  static Map<String, Object?> lastLoadTimings = const {};
  static Map<String, Object?> lastSynthesisTimings = const {};

  static Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  static void _check(int generation) {
    if (_generation != generation) {
      throw const MediaPipeSpeechException('Speech synthesis cancelled.');
    }
  }

  static Future<void> _load(int generation) async {
    if (_loaded) return;
    final watch = Stopwatch()..start();
    if (!await SupertonicModel.bundle.installed(verify: true)) {
      throw const MediaPipeSpeechException(
        'Download the complete Supertonic 3 model in Settings.',
      );
    }
    final path = (await SupertonicModel.directory()).path;
    final verificationMs = watch.elapsedMicroseconds / 1000;
    _check(generation);
    _nativeRequested = true;
    final native = await channel.invokeMapMethod<String, dynamic>('load', {
      'path': path,
    });
    lastLoadTimings = {
      'verificationMs': verificationMs,
      'totalMs': watch.elapsedMicroseconds / 1000,
      ...?native,
    };
    _loaded = true;
  }

  static Future<void> ensureLoaded() {
    _idle?.cancel();
    final generation = _generation;
    return _serial(() async {
      _check(generation);
      await _load(generation);
      _check(generation);
    }).whenComplete(release);
  }

  static Future<void> synthesizeToFile({
    required String text,
    required String path,
    required String voice,
    String language = 'en',
    double pauses = 1,
  }) {
    _idle?.cancel();
    final generation = _generation;
    return _serial(() async {
      _check(generation);
      if (!SupertonicModel.voices.containsKey(voice) ||
          !SupertonicModel.languages.containsKey(language)) {
        throw const MediaPipeSpeechException(
          'Choose a supported Supertonic voice and language.',
        );
      }
      await _load(generation);
      _check(generation);
      final result = await channel.invokeMapMethod<String, dynamic>(
        'synthesize',
        {'text': text, 'voice': voice, 'language': language},
      );
      _check(generation);
      lastSynthesisTimings = {
        'nativeMs': result?['nativeMs'],
        'modelsMs': result?['modelsMs'],
      };
      if (result?['samples'] is! Float32List) {
        throw const MediaPipeSpeechException('Supertonic returned no audio.');
      }
      final bytes = speechWav(
        result!['samples'] as Float32List,
        result['sampleRate'] as int,
        pauses: pauses,
      );
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      if (_generation != generation) {
        await file.delete();
        _check(generation);
      }
    }).whenComplete(release);
  }

  static void cancel() {
    _generation++;
    if (!_nativeRequested) return;
    unawaited(channel.invokeMethod<void>('cancel').catchError((Object _) {}));
  }

  static void release({Duration after = const Duration(seconds: 60)}) {
    _idle?.cancel();
    _idle = Timer(
      after,
      () => unawaited(_serial(_dispose).catchError((Object _) {})),
    );
  }

  static Future<void> _dispose() async {
    if (!_nativeRequested) return;
    _loaded = false;
    try {
      await channel.invokeMethod<void>('unload');
    } finally {
      _nativeRequested = false;
    }
  }

  static Future<void> unload() {
    _idle?.cancel();
    cancel();
    return _serial(() async {
      _idle?.cancel();
      _idle = null;
      await _dispose();
    });
  }
}
