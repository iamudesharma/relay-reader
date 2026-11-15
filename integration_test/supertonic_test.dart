import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mediapipe_audio/mediapipe_audio.dart' as mp;
import 'package:relay_reader/audio_clip_cache.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/supertonic.dart';

import 'test_process_activity.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'all Supertonic voices synthesize; cancellation, live playback and Kokoro cast remain usable',
    (tester) async {
      await holdTestProcessActivity();
      // Provision through Settings, or download once for this opt-in device test.
      if (!await SupertonicModel.isInstalled()) {
        await SupertonicModel.download((_, _) {});
      }
      final root = await Directory.systemTemp.createTemp(
        'relay-supertonic-native-',
      );
      final player = AudioPlayer();
      final cacheDirectory = Directory('${root.path}/cache');
      final narrator = Narrator(
        player: player,
        prefetch: 1,
        cache: AudioClipCache(directory: cacheDirectory),
      );
      addTearDown(() async {
        await narrator.close();
        await root.delete(recursive: true);
      });
      for (final voice in SupertonicModel.voices.keys) {
        final path = '${root.path}/$voice.wav';
        await SupertonicNarration.synthesizeToFile(
          text: 'The garden was quiet, and the house was listening.',
          path: path,
          voice: voice,
        );
        final audio = mp.decodeWav(await File(path).readAsBytes());
        expect(audio.sampleRate, 44100);
        expect(audio.samples.length, greaterThan(44100));
        expect(audio.samples.any((sample) => sample.abs() > .001), isTrue);
      }
      for (final sample in {
        'fr': 'Le jardin est calme et la maison semble écouter.',
        'hi': 'सुबह बगीचा शांत था और पक्षी गा रहे थे।',
      }.entries) {
        final path = '${root.path}/${sample.key}.wav';
        await SupertonicNarration.synthesizeToFile(
          text: sample.value,
          path: path,
          voice: 'F2',
          language: sample.key,
        );
        expect(
          mp.decodeWav(await File(path).readAsBytes()).samples.length,
          greaterThan(44100),
        );
      }
      final cancelledPath = '${root.path}/cancelled.wav';
      debugPrint('Supertonic regression: voices and languages ready');
      final pending = SupertonicNarration.synthesizeToFile(
        text: List.filled(
          30,
          'The road curved between the trees and the river shone beyond the fields.',
        ).join(' '),
        path: cancelledPath,
        voice: 'M1',
      );
      final cancelled = expectLater(pending, throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      SupertonicNarration.cancel();
      await cancelled;
      expect(await File(cancelledPath).exists(), isFalse);
      await SupertonicNarration.synthesizeToFile(
        text: 'The next sentence is ready.',
        path: '${root.path}/after-cancel.wav',
        voice: 'M1',
      );
      Future<int> cachedClips() async => await cacheDirectory.exists()
          ? (await cacheDirectory
                    .list(recursive: true)
                    .where((entry) => entry.path.endsWith('.audio'))
                    .toList())
                .length
          : 0;
      narrator.settings = const VoiceSettings(
        engine: VoiceEngine.supertonic,
        volume: .01,
        batterySaver: true,
      );
      narrator.start(
        title: 'Supertonic check',
        bookId: 'supertonic-native-test',
        sectionName: 'Page',
        index: 0,
        length: 1,
        loadSpeech: (_) async => const [
          SpeechUtterance('The garden was quiet, and the house was listening.'),
          SpeechUtterance(
            'A bird sang outside the window.',
            speaker: 'Alice',
            kokoroVoice: 6,
          ),
        ],
        showSection: (_) {},
      );
      await _until(tester, () => narrator.state == SpeechState.playing);
      debugPrint('Supertonic regression: playback started');
      await narrator.pause();
      debugPrint('Supertonic regression: paused');
      await narrator.applySettings(
        narrator.settings.withChanges(speed: 1.3, volume: .02),
      );
      expect(player.speed, 1.3);
      expect(player.volume, .02);
      debugPrint('Supertonic regression: live speed and volume applied');
      narrator.sleepTimer.setDuration(const Duration(minutes: 15));
      await narrator.applySettings(
        narrator.settings.withChanges(supertonicVoice: 'F2'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _until(
        tester,
        () =>
            !narrator.navigating &&
            narrator.state == SpeechState.paused &&
            narrator.currentUtterance == 0,
      );
      debugPrint('Supertonic regression: F2 settings applied');
      // Battery saver may already have prefetched another M1 clip at pause.
      final beforeNavigation = await cachedClips();
      expect(beforeNavigation, greaterThanOrEqualTo(2));
      expect(narrator.sleepTimer.active, isTrue);
      await narrator.nextSentence();
      debugPrint('Supertonic regression: next sentence requested');
      await _until(tester, () => narrator.currentUtterance == 1);
      expect(narrator.speaker, 'Alice');
      expect(await cachedClips(), beforeNavigation + 1);
      await narrator.previousSentence();
      debugPrint('Supertonic regression: previous sentence requested');
      await _until(tester, () => narrator.currentUtterance == 0);
      expect(await cachedClips(), beforeNavigation + 1);
      await narrator.applySettings(
        narrator.settings.withChanges(engine: VoiceEngine.kokoro),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _until(
        tester,
        () =>
            !narrator.navigating &&
            narrator.state == SpeechState.paused &&
            narrator.currentUtterance == 0,
      );
      await narrator.nextSentence();
      await _until(tester, () => narrator.currentUtterance == 1);
      expect(narrator.speaker, 'Alice');
      expect(await cachedClips(), beforeNavigation + 3);
      expect(narrator.sleepTimer.active, isTrue);
      expect(narrator.error, isNull);
      await narrator.stop();
      expect(narrator.sleepTimer.active, isFalse);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _until(WidgetTester _, bool Function() ready) async {
  for (var i = 0; i < 400; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Native Supertonic playback did not reach the expected state');
}
