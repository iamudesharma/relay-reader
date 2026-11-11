import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:relay_reader/lfm3_audio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LFM3-Audio speaks a short sentence', (tester) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/lfm3_audio');
    final model = File('${directory.path}/LFM3-Audio-2B-Q4_K_M.gguf');
    final projector = File(
      '${directory.path}/mmproj-LFM3-Audio-2B-Q4_K_M.gguf',
    );
    expect(await model.exists(), isTrue);
    expect(await projector.exists(), isTrue);

    final engine = await TextToSpeechEngine.load(
      TextToSpeechModel(
        ModelSource.path(model.path),
        projector: ModelSource.path(projector.path),
        adapter: const Lfm3AudioTtsAdapter(),
      ),
      params: const ModelParams(
        contextSize: 4096,
        numberOfThreads: 4,
        numberOfThreadsBatch: 4,
      ),
    );
    try {
      final capabilities = await engine.capabilities;
      debugPrint(
        'LFM3-Audio capabilities: supported=${capabilities.isSupported} '
        'voices=${capabilities.voices} sampleRate=${capabilities.sampleRateHz} '
        'languages=${capabilities.supportedLanguages}',
      );
      expect(capabilities.isSupported, isTrue);
      expect(capabilities.voices, contains('female'));

      final result = await engine.synthesizeOnce(
        const TextToSpeechRequest(
          text:
              'In the morning the garden was quiet, and the whole house '
              'seemed to be listening.',
          voice: 'female',
          maxFrames: 1024,
        ),
      );
      debugPrint(
        'LFM3-Audio result: ${result.duration} at '
        '${result.sampleRateHz} Hz, ${result.framesGenerated} frames, '
        'truncated=${result.truncated}',
      );
      expect(result.samples, isNotEmpty);
      final out = File('${Directory.systemTemp.path}/lfm3-audio-test.wav');
      await out.writeAsBytes(result.toWavBytes());
      debugPrint('Wrote ${out.path}');

      final longText =
          'The morning light came slowly through the tall windows of the '
          'library, touching the spines of the books and the dust that hung '
          'in the air. Elizabeth stood by the shelf for a long moment, her '
          'hand resting on a volume she had read a dozen times before. She '
          'was thinking not of the words but of the conversation that had '
          'ended so badly the night before, and of the look on his face when '
          'she had turned away. Outside, a carriage rattled past the gate and '
          'the sound faded into the ordinary noise of the street.';
      final longResult = await engine.synthesizeOnce(
        TextToSpeechRequest(text: longText, voice: 'male', maxFrames: 2048),
      );
      debugPrint(
        'LFM3-Audio long result: ${longResult.duration} at '
        '${longResult.sampleRateHz} Hz, ${longResult.framesGenerated} frames, '
        'truncated=${longResult.truncated}',
      );
      expect(longResult.samples, isNotEmpty);
      expect(longResult.truncated, isFalse);
      await File('${Directory.systemTemp.path}/lfm3-audio-long-test.wav')
          .writeAsBytes(longResult.toWavBytes());

      await engine.dispose();

      final productPath = '${Directory.systemTemp.path}/lfm3-audio-product.wav';
      await Lfm3Audio.synthesizeToFile(
        text:
            'The house was quiet, and the garden lay still in the morning '
            'light.',
        voice: 'male',
        path: productPath,
      );
      final productWav = await File(productPath).readAsBytes();
      expect(productWav.length, greaterThan(44));
      expect(String.fromCharCodes(productWav.take(4)), 'RIFF');
      debugPrint('LFM3-Audio product path wrote ${productWav.length} bytes');
      await Lfm3Audio.unload();

      final reloadedPath =
          '${Directory.systemTemp.path}/lfm3-audio-reloaded.wav';
      await Lfm3Audio.synthesizeToFile(
        text: 'Good morning. The garden is quiet again.',
        voice: 'female',
        path: reloadedPath,
      );
      final reloadedWav = await File(reloadedPath).readAsBytes();
      expect(reloadedWav.length, greaterThan(44));
      expect(String.fromCharCodes(reloadedWav.take(4)), 'RIFF');
      debugPrint('LFM3-Audio reloaded path wrote ${reloadedWav.length} bytes');
      await Lfm3Audio.unload();
    } finally {
      await engine.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
