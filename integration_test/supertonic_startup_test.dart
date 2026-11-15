import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mediapipe_audio/mediapipe_audio.dart' as mp;
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:relay_reader/audio_clip_cache.dart';
import 'package:relay_reader/library.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/reader.dart';
import 'package:relay_reader/reader_preferences.dart';
import 'package:relay_reader/theme.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:relay_reader/supertonic.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('measure model-cold Supertonic preparation and first audio', (
    tester,
  ) async {
    expect(await SupertonicModel.isInstalled(), isTrue);
    await SupertonicNarration.channel.invokeMethod<void>('beginBenchmark');
    addTearDown(() async {
      await SupertonicNarration.unload();
      await SupertonicNarration.channel.invokeMethod<void>('endBenchmark');
    });
    final root = await getApplicationSupportDirectory();
    const variant = String.fromEnvironment(
      'STARTUP_VARIANT',
      defaultValue: 'optimized',
    );
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final output = Directory(
      '${root.path}/benchmarks/supertonic-startup/$variant-$stamp',
    );
    await output.create(recursive: true);
    final rows = <Map<String, Object?>>[];
    for (var run = 0; run < 3; run++) {
      await SupertonicNarration.unload();
      final watch = Stopwatch()..start();
      await SupertonicNarration.ensureLoaded();
      final loadMs = watch.elapsedMicroseconds / 1000;
      final path = '${output.path}/first-$run.wav';
      await SupertonicNarration.synthesizeToFile(
        text: 'A gentle breeze moved through the open window. Across the garden, the old house stood quietly beneath the evening sky.',
        path: path,
        voice: 'M1',
      );
      final firstMs = watch.elapsedMicroseconds / 1000;
      final pcm = mp.decodeWav(await File(path).readAsBytes());
      expect(pcm.samples.any((sample) => sample.abs() > .001), isTrue);
      final coldSynthesis = Map<String, Object?>.from(
        SupertonicNarration.lastSynthesisTimings,
      );
      final warm = Stopwatch()..start();
      await SupertonicNarration.synthesizeToFile(
        text: 'The garden was quiet, and the house was listening.',
        path: '${output.path}/warm-$run.wav',
        voice: 'F2',
      );
      final row = <String, Object?>{
        'run': run,
        'loadMs': loadMs,
        'loadPlusFirstClipMs': firstMs,
        'firstSynthesisMs': firstMs - loadMs,
        'warmVoiceSwitchMs': warm.elapsedMicroseconds / 1000,
        'load': Map<String, Object?>.from(SupertonicNarration.lastLoadTimings),
        'firstSynthesis': coldSynthesis,
      };
      rows.add(row);
      // ignore: avoid_print
      print(jsonEncode(row));
    }
    await File('${output.path}/results.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'variant': variant,
        'os': Platform.operatingSystemVersion,
        'dart': Platform.version,
        'note': 'Mac debug app; App Nap inhibited; model-cold reloads with existing OS specialization caches; same fixed text; no clip cache',
        'rows': rows,
      }),
    );
    // ignore: avoid_print
    print('Startup artifacts: ${output.path}');
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
    'opening a book prepares the default narrator without starting audio',
    (tester) async {
      final originalPreferences = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await SupertonicNarration.unload();
      await SupertonicNarration.channel.invokeMethod<void>('beginBenchmark');
      final root = await Directory.systemTemp.createTemp(
        'relay-default-preparation-',
      );
      final preferences = ReaderPreferences();
      await preferences.load();
      expect(preferences.voice.engine, VoiceEngine.supertonic);
      final theme = ReaderThemeController(ThemeChoice.day);
      final library = Library();
      final player = AudioPlayer();
      final narrator = Narrator(
        player: player,
        prefetch: 1,
        cache: AudioClipCache(directory: Directory('${root.path}/clips')),
      );
      final closed = Completer<void>();
      var mountedReader = false;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        if (mountedReader) await closed.future;
        await narrator.close();
        await library.close();
        preferences.dispose();
        theme.dispose();
        SharedPreferencesAsyncPlatform.instance = originalPreferences;
        await SupertonicNarration.channel.invokeMethod<void>('endBenchmark');
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Reader(
            book: OpenedBook(
              const LibraryBook(
                'startup-test',
                'Startup test',
                '',
                BookFormat.txt,
              ),
              text: 'The garden was quiet. A bird sang outside.',
            ),
            library: library,
            theme: theme,
            position: 0,
            bookmark: null,
            narrator: narrator,
            preferences: preferences,
            onClosed: () => closed.complete(),
          ),
        ),
      );
      mountedReader = true;
      await _until(tester, () => SupertonicNarration.isLoaded);
      expect(narrator.state, SpeechState.idle);
      expect(player.audioSources, isEmpty);
      expect(player.playing, isFalse);
      final watch = Stopwatch()..start();
      final playing = Completer<double>();
      void changed() {
        if (narrator.state == SpeechState.playing && !playing.isCompleted) {
          playing.complete(watch.elapsedMicroseconds / 1000);
        }
      }

      narrator.addListener(changed);
      await tester.tap(find.byTooltip('Read aloud'));
      await _until(tester, () => playing.isCompleted);
      final ms = await playing.future;
      narrator.removeListener(changed);
      await narrator.pause();
      expect(narrator.error, isNull);
      final support = await getApplicationSupportDirectory();
      final result = {
        'preparedBookPlayMs': ms,
        'stateBeforePlay': 'idle',
        'audioSourcesBeforePlay': 0,
      };
      final output = File(
        '${support.path}/benchmarks/supertonic-startup/prepared-play.json',
      );
      await output.writeAsString(jsonEncode(result));
      // ignore: avoid_print
      print('Prepared book playback: ${jsonEncode(result)}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 400; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Default narrator did not reach the expected state');
}
