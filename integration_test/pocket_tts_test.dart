import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mediapipe_audio/mediapipe_audio.dart' as mp;
import 'package:relay_reader/audio_clip_cache.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/pocket_tts.dart';

import 'test_process_activity.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'all Pocket voices synthesize; native playback retains live controls and Kokoro cast',
    (tester) async {
      await holdTestProcessActivity();
      // Provision through Settings, or download once for this opt-in device test.
      if (!await PocketTts.isInstalled()) await PocketTts.download((_, _) {});
      final root = await Directory.systemTemp.createTemp(
        'relay-pocket-native-',
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
      for (final voice in PocketTts.voices.keys) {
        final path = '${root.path}/$voice.wav';
        await PocketTts.synthesizeToFile(
          text: 'The garden was quiet, and the house was listening.',
          path: path,
          voice: voice,
        );
        final audio = mp.decodeWav(await File(path).readAsBytes());
        expect(audio.sampleRate, 24000);
        expect(audio.samples.length, greaterThan(24000));
        expect(audio.samples.any((sample) => sample.abs() > .001), isTrue);
      }
      Future<int> cachedClips() async => await cacheDirectory.exists()
          ? (await cacheDirectory
                    .list(recursive: true)
                    .where((entry) => entry.path.endsWith('.audio'))
                    .toList())
                .length
          : 0;
      narrator.settings = const VoiceSettings(
        engine: VoiceEngine.pocket,
        volume: .01,
        batterySaver: true,
      );
      narrator.start(
        title: 'Pocket check',
        bookId: 'pocket-native-test',
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
      await narrator.pause();
      await narrator.applySettings(
        narrator.settings.withChanges(speed: 1.3, volume: .02),
      );
      expect(player.speed, 1.3);
      expect(player.volume, .02);
      narrator.sleepTimer.setDuration(const Duration(minutes: 15));
      await narrator.applySettings(
        narrator.settings.withChanges(pocketVoice: 'marius'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _until(
        tester,
        () =>
            !narrator.navigating &&
            narrator.state == SpeechState.paused &&
            narrator.currentUtterance == 0,
      );
      // Battery saver may already have prefetched another Alba clip at pause.
      final beforeNavigation = await cachedClips();
      expect(beforeNavigation, greaterThanOrEqualTo(2));
      expect(narrator.sleepTimer.active, isTrue);
      await narrator.nextSentence();
      await _until(tester, () => narrator.currentUtterance == 1);
      expect(narrator.speaker, 'Alice');
      expect(await cachedClips(), beforeNavigation + 1);
      await narrator.previousSentence();
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
  fail('Native Pocket playback did not reach the expected state');
}
