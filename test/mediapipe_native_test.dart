import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediapipe_audio/mediapipe_audio.dart' as mp;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:relay_reader/mediapipe_tts.dart';

class _Network extends HttpOverrides {}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Explicit opt-in: exercises the actual native library and downloads Phonon.
/// flutter test test/mediapipe_native_test.dart --dart-define=RUN_MEDIAPIPE_NATIVE=true
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('RUN_MEDIAPIPE_NATIVE');
  test(
    'native Kokoro and Phonon synthesize WAV clips',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'relay-mediapipe-native-',
      );
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        await kokoroSpeech.unload();
        await phononSpeech.unload();
        PathProviderPlatform.instance = previous;
        await root.delete(recursive: true);
      });
      final samples = Directory('build/mediapipe-samples');
      await samples.create(recursive: true);
      for (final voice in ['af_heart', 'bf_emma', 'bm_george']) {
        final watch = Stopwatch()..start();
        final path = '${samples.path}/$voice.wav';
        await kokoroSpeech.synthesizeToFile(
          text: 'Reid’s garden has 45 roses. In 1969, a ticket cost twelve dollars.',
          voice: voice,
          path: path,
        );
        final audio = mp.decodeWav(await File(path).readAsBytes());
        final seconds = audio.samples.length / audio.sampleRate;
        expect(seconds, greaterThan(1));
        expect(audio.sampleRate, 24000);
        // ignore: avoid_print
        print(
          '$voice: ${watch.elapsedMilliseconds} ms, ${seconds.toStringAsFixed(2)} s audio',
        );
      }
      await kokoroSpeech.unload();
      await HttpOverrides.runWithHttpOverrides(
        () => MediaPipeModels.downloadPhonon((_, _) {}),
        _Network(),
      );
      expect(await MediaPipeModels.phononInstalled(), isTrue);
      final voices = await phononSpeech.voices();
      expect(voices, contains('freya'));
      final watch = Stopwatch()..start();
      final path = '${samples.path}/freya.wav';
      await phononSpeech.synthesizeToFile(
        text: 'The garden was quiet, and the house was listening.',
        path: path,
        voice: 'freya',
      );
      final audio = mp.decodeWav(await File(path).readAsBytes());
      expect(audio.samples, isNotEmpty);
      // ignore: avoid_print
      print(
        'freya: ${watch.elapsedMilliseconds} ms, ${(audio.samples.length / audio.sampleRate).toStringAsFixed(2)} s audio',
      );
      await MediaPipeModels.deletePhonon();
      expect(await MediaPipeModels.phononInstalled(), isFalse);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
