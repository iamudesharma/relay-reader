import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_reader/audio_clip_cache.dart';
import 'package:relay_reader/mediapipe_tts.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/reader_preferences.dart';

import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:relay_reader/library.dart';
import 'package:relay_reader/reader.dart';
import 'package:relay_reader/theme.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../test/listening_features_test.dart' show TestPlayer, until;
import 'test_process_activity.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerListeningUiTest();
  testWidgets(
    'real playback supports cached sentence navigation and sleep stop',
    (tester) async {
      await holdTestProcessActivity();
      await initializeNarration();
      final root = await Directory.systemTemp.createTemp(
        'relay-listening-native-',
      );
      final positions = <(int, int)>[];
      var synthesized = 0;
      final nativePlayer = AudioPlayer();
      final narrator = Narrator(
        player: nativePlayer,
        prefetch: 1,
        cache: AudioClipCache(directory: root),
        synthesizeClip: (_, _, path) async {
          synthesized++;
          final samples = Float32List.fromList(
            List.generate(48000, (i) => .03 * sin(2 * pi * 220 * i / 24000)),
          );
          await File(path).writeAsBytes(speechWav(samples, 24000));
        },
      );
      addTearDown(() async {
        await narrator.close();
        await root.delete(recursive: true);
      });
      narrator.start(
        bookId: 'native-test',
        title: 'Listening check',
        sectionName: 'Chapter',
        index: 0,
        length: 2,
        loadSpeech: (section) async => section == 0
            ? const [
                SpeechUtterance('First.'),
                SpeechUtterance('Second.', speaker: 'Alice'),
              ]
            : const [SpeechUtterance('Next chapter.')],
        showSection: (_) {},
        onProgress: (section, sentence, _) =>
            positions.add((section, sentence)),
      );
      await _until(tester, () => narrator.state == SpeechState.playing);
      await narrator.pause();
      await narrator.nextSentence();
      await _until(tester, () => narrator.passage == 'Second.');
      expect(narrator.state, SpeechState.paused);
      expect(narrator.speaker, 'Alice');
      await narrator.previousSentence();
      await _until(tester, () => narrator.passage == 'First.');
      expect(synthesized, 2);
      await narrator.applySettings(
        narrator.settings.withChanges(speed: 1.2, volume: .4),
      );
      expect(nativePlayer.speed, 1.2);
      expect(nativePlayer.volume, .4);
      narrator.sleepTimer.setSectionEnd(0);
      narrator.resume();
      await _until(tester, () => !narrator.active);
      expect(narrator.error, isNull);
      expect(positions, contains((0, 1)));
      expect(positions.every((position) => position.$1 == 0), isTrue);
      expect(synthesized, 2);
    },
  );
}

Future<void> _until(WidgetTester _, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Native playback did not reach the expected state');
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void registerListeningUiTest() {
  testWidgets(
    'listening controls and sleep menu fit phone portrait and landscape',
    (tester) async {
      await holdTestProcessActivity();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('relay-listening-ui-'),
      ))!;
      final previousPaths = PathProviderPlatform.instance;
      final previousPreferences = SharedPreferencesAsyncPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      await tester.runAsync(() async {
        await kokoroSpeech.unload();
        await phononSpeech.unload();
      });
      final preferences = (await tester.runAsync(() async {
        final value = ReaderPreferences();
        await value.load();
        // This regression exercises Kokoro's voice dropdown explicitly.
        value.voice = value.voice.withChanges(engine: VoiceEngine.kokoro);
        return value;
      }))!;
      var uiSynthesized = 0;
      final player = TestPlayer();
      final narrator = (await tester.runAsync(
        () async => Narrator(
          player: player,
          previewPlayer: TestPlayer(),
          prefetch: 1,
          configureAudioSession: () async {},
          cache: AudioClipCache(directory: Directory('${root.path}/cache')),
          synthesizeClip: (_, _, path) async {
            uiSynthesized++;
            await File(path).writeAsBytes(
              speechWav(Float32List.fromList([0, .2, -.2]), 24000),
            );
          },
        ),
      ))!;
      final library = Library();
      final theme = ReaderThemeController(ThemeChoice.day);
      final book = OpenedBook(
        const LibraryBook('listening-ui', 'Listening UI', '', BookFormat.txt),
        text: 'The garden was quiet. A bird sang.',
      );
      addTearDown(() async {
        debugPrint('Listening UI: closing narrator');
        await tester.runAsync(narrator.close);
        await tester.runAsync(library.close);
        theme.dispose();
        preferences.dispose();
        PathProviderPlatform.instance = previousPaths;
        SharedPreferencesAsyncPlatform.instance = previousPreferences;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
        debugPrint('Listening UI: cleanup complete');
      });
      await tester.runAsync(() async {
        narrator.start(
          title: 'Listening UI',
          bookId: 'listening-ui',
          sectionName: 'Page',
          index: 0,
          length: 1,
          loadSpeech: (_) async => const [
            SpeechUtterance('The garden was quiet.'),
            SpeechUtterance('A bird sang.'),
          ],
          showSection: (_) {},
        );
        await until(() => narrator.state == SpeechState.playing);
      });
      debugPrint('Listening UI: playback ready');
      await tester.pumpWidget(
        MaterialApp(
          home: Reader(
            book: book,
            library: library,
            theme: theme,
            position: 0,
            bookmark: null,
            narrator: narrator,
            preferences: preferences,
          ),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Previous sentence'), findsOneWidget);
      expect(find.widgetWithIcon(IconButton, Icons.skip_next), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Sleep timer'));
      await tester.pumpAndSettle();
      for (final label in [
        'Off',
        '15 minutes',
        '30 minutes',
        '60 minutes',
        'End of current page',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('15 minutes'));
      await tester.pumpAndSettle();
      expect(narrator.sleepTimer.active, isTrue);
      await tester.tap(find.byTooltip('Pause narration'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.skip_next),
            )
            .onPressed,
        isNotNull,
      );
      expect(narrator.state, SpeechState.paused);
      expect(narrator.sleepTimer.active, isTrue);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Narration'), findsOneWidget);
      debugPrint('Listening UI: settings opened');
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
      final speed = find.descendant(
        of: find.bySemanticsLabel('Speed'),
        matching: find.byType(Slider),
      );
      tester.widget<Slider>(speed).onChanged!(1.4);
      await _until(tester, () => player.lastSpeed == 1.4);
      debugPrint('Listening UI: speed applied');
      expect(uiSynthesized, 1);
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byType(DropdownButtonFormField<int>),
          )
          .onChanged!(16);
      await _until(
        tester,
        () =>
            narrator.settings.voice == 16 &&
            uiSynthesized == 2 &&
            narrator.passage != null,
      );
      debugPrint('Listening UI: voice applied');
      expect(narrator.state, SpeechState.paused);
      expect(narrator.currentUtterance, 0);
      expect(narrator.sleepTimer.active, isTrue);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(narrator.active, isTrue);
      await tester.tap(find.byTooltip('Book settings'));
      await tester.pumpAndSettle();
      expect(find.text('Review speakers in this chapter'), findsOneWidget);
      expect(find.text('Battery saver'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(667, 375);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.stop))
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(narrator.stop);
      debugPrint('Listening UI: stopped');
      await tester.pumpAndSettle();
      expect(narrator.sleepTimer.active, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(narrator.close);
    },
  );
}
