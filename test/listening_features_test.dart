import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:relay_reader/audio_clip_cache.dart';
import 'package:relay_reader/deferred_initialization.dart';
import 'package:relay_reader/listening_sleep_timer.dart';
import 'package:relay_reader/mediapipe_tts.dart';
import 'package:relay_reader/narration.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
}

/// Emits the same playlist and player events used by Narrator, without native
/// audio or timing races. Advancing playback is controlled explicitly by tests.
class TestPlayer extends Mock implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final sequences = StreamController<SequenceState>.broadcast(sync: true);
  final errors = StreamController<PlayerException>.broadcast(sync: true);
  @override
  final audioSources = <AudioSource>[];
  @override
  int? currentIndex;
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  bool playing = false;
  double lastSpeed = 1, lastVolume = 1;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<SequenceState> get sequenceStateStream => sequences.stream;
  @override
  Stream<PlayerException> get errorStream => errors.stream;
  void emit() {
    sequences.add(
      SequenceState(
        sequence: audioSources.cast<IndexedAudioSource>(),
        currentIndex: currentIndex,
        shuffleIndices: [],
        shuffleModeEnabled: false,
        loopMode: LoopMode.off,
      ),
    );
    states.add(PlayerState(playing, processingState));
  }

  void advance() {
    if (currentIndex! + 1 < audioSources.length) {
      currentIndex = currentIndex! + 1;
    } else {
      processingState = ProcessingState.completed;
    }
    emit();
  }

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    audioSources
      ..clear()
      ..addAll(sources);
    currentIndex = initialIndex ?? 0;
    processingState = ProcessingState.ready;
    emit();
    return const Duration(seconds: 5);
  }

  @override
  Future<void> addAudioSource(AudioSource source) async {
    audioSources.add(source);
    emit();
  }

  @override
  Future<void> removeAudioSourceRange(int start, int end) async {
    audioSources.removeRange(start, end);
    currentIndex = currentIndex! - (end - start);
    emit();
  }

  @override
  Future<void> clearAudioSources() async {
    audioSources.clear();
    currentIndex = null;
    emit();
  }

  @override
  Future<void> play() async {
    playing = true;
    emit();
  }

  @override
  Future<void> pause() async {
    playing = false;
    emit();
  }

  @override
  Future<void> stop() async {
    playing = false;
    processingState = ProcessingState.idle;
    emit();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    currentIndex = index ?? currentIndex;
    processingState = ProcessingState.ready;
    emit();
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }

  @override
  Future<void> setSpeed(double speed) async {
    lastSpeed = speed;
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await sequences.close();
    await errors.close();
  }
}

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 1000; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Timed out waiting for playback');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'deferred initialization is unused until requested, shared and retryable',
    () async {
      var calls = 0;
      final pending = Completer<void>();
      final initialization = DeferredInitialization(() {
        calls++;
        return pending.future;
      });
      expect(calls, 0);
      final first = initialization.ensureReady();
      final second = initialization.ensureReady();
      expect(calls, 1);
      pending.complete();
      await Future.wait([first, second]);
      await initialization.ensureReady();
      expect(calls, 1);
      var attempts = 0;
      final retry = DeferredInitialization(() async {
        if (attempts++ == 0) throw StateError('retry');
      });
      await expectLater(retry.ensureReady(), throwsStateError);
      await retry.ensureReady();
      expect(attempts, 2);
    },
  );

  test(
    'sleep deadline, cancellation, replacement and section end expire once',
    () {
      fakeAsync((clock) {
        var expired = 0;
        final timer = ListeningSleepTimer(
          () => expired++,
          now: () => clock.getClock(DateTime(2026)).now(),
        );
        timer.setDuration(const Duration(minutes: 15));
        clock.elapse(const Duration(minutes: 14));
        expect(expired, 0);
        expect(timer.remaining, const Duration(minutes: 1));
        clock.elapse(const Duration(minutes: 1));
        expect(expired, 1);
        expect(timer.active, isFalse);
        clock.elapse(const Duration(hours: 1));
        expect(expired, 1);
        timer.setDuration(const Duration(minutes: 30));
        timer.setSectionEnd(3);
        clock.elapse(const Duration(minutes: 31));
        expect(expired, 1);
        timer.reachedSectionEnd(2);
        expect(expired, 1);
        timer.reachedSectionEnd(3);
        timer.reachedSectionEnd(3);
        expect(expired, 2);
        timer.setDuration(const Duration(minutes: 60));
        timer.cancel();
        clock.elapse(const Duration(hours: 2));
        expect(expired, 2);
        timer.dispose();
      });
    },
  );

  test(
    'sentence boundaries retain abbreviations, numbers, quotes and Unicode',
    () {
      final chunks = speechChunks(
        'Dr. Reid paid 12.50 dollars. “Really?” Yes! 🌱',
      ).toList();
      expect(chunks, [
        'Dr. Reid paid 12.50 dollars.',
        '“Really?”',
        'Yes!',
        '🌱',
      ]);
      expect(
        speechChunks(List.filled(500, '🌱').join()).join(),
        List.filled(500, '🌱').join(),
      );
    },
  );

  group('playback regression', () {
    late Directory root;
    late PathProviderPlatform previousPaths;
    late TestPlayer player;
    late Narrator narrator;
    late AudioClipCache cache;
    late List<(int, int, String)> checkpoints;
    late int generated;
    late List<VoiceSettings> rendered;
    final chapters = [
      const [
        SpeechUtterance('First sentence.'),
        SpeechUtterance('Second sentence.', speaker: 'Alice', kokoroVoice: 6),
      ],
      const <SpeechUtterance>[],
      const [SpeechUtterance('Last chapter sentence.')],
    ];
    setUp(() async {
      root = await Directory.systemTemp.createTemp('relay-listening-test-');
      previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      player = TestPlayer();
      generated = 0;
      rendered = [];
      checkpoints = [];
      cache = AudioClipCache(directory: Directory('${root.path}/audio'));
      narrator = Narrator(
        prefetch: 1,
        player: player,
        previewPlayer: TestPlayer(),
        cache: cache,
        configureAudioSession: () async {},
        synthesizeClip: (speech, settings, path) async {
          generated++;
          rendered.add(settings);
          await File(
            path,
          ).writeAsBytes(speechWav(Float32List.fromList([0, .2, -.2]), 24000));
        },
      );
    });
    tearDown(() async {
      await narrator.close();
      PathProviderPlatform.instance = previousPaths;
      await root.delete(recursive: true);
    });
    void start({int section = 0, int utterance = 0, SpeechLoader? load}) =>
        narrator.start(
          bookId: 'test-book',
          title: 'Test',
          sectionName: 'Chapter',
          index: section,
          length: chapters.length,
          startUtterance: utterance,
          loadSpeech: load ?? (i) async => chapters[i],
          showSection: (_) {},
          onProgress: (section, utterance, speech) =>
              checkpoints.add((section, utterance, speech.text)),
        );

    test('previous/next reuse clips and keep pause, speaker and checkpoint in sync', () async {
      start();
      await until(() => narrator.state == SpeechState.playing);
      expect(narrator.canPreviousSentence, isFalse);
      await narrator.nextSentence();
      await until(() => narrator.currentUtterance == 1);
      expect(narrator.speaker, 'Alice');
      expect(checkpoints.last, (0, 1, 'Second sentence.'));
      expect(generated, 2);
      await narrator.pause();
      await narrator.previousSentence();
      await until(() => narrator.passage == 'First sentence.');
      expect(narrator.state, SpeechState.paused);
      expect(player.playing, isFalse);
      expect(generated, 2);
      narrator.resume();
      await until(() => narrator.state == SpeechState.playing);
      await narrator.stop();
      start();
      await until(() => narrator.state == SpeechState.playing);
      expect(generated, 2);
      await narrator.stop();
      narrator.settings = const VoiceSettings(voice: 16);
      start();
      await until(() => narrator.state == SpeechState.playing);
      expect(generated, 3);
    });

    test(
      'resume retains the requested occurrence of repeated sentences',
      () async {
        narrator.start(
          title: 'Repeated',
          sectionName: 'Page',
          index: 0,
          length: 1,
          startUtterance: 2,
          resumePassage: 'Repeated.',
          loadSpeech: (_) async => const [
            SpeechUtterance('Repeated.'),
            SpeechUtterance('Middle.'),
            SpeechUtterance('Repeated.'),
          ],
          showSection: (_) {},
        );
        await until(() => narrator.state == SpeechState.playing);
        expect(narrator.currentUtterance, 2);
      },
    );

    test(
      'older multi-sentence checkpoints locate the new shorter first sentence',
      () async {
        narrator.start(
          title: 'Older checkpoint',
          sectionName: 'Page',
          index: 0,
          length: 1,
          startUtterance: 0,
          resumePassage: 'The old passage starts. It continues.',
          loadSpeech: (_) async => const [
            SpeechUtterance('An opening line.'),
            SpeechUtterance('The old passage starts.'),
            SpeechUtterance('It continues.'),
          ],
          showSection: (_) {},
        );
        await until(() => narrator.state == SpeechState.playing);
        expect(narrator.currentUtterance, 1);
      },
    );

    test(
      'live speed and volume update playback without regenerating queued audio',
      () async {
        start();
        await until(() => narrator.state == SpeechState.playing);
        await narrator.applySettings(
          narrator.settings.withChanges(speed: 1.5, volume: .4),
        );
        expect(player.lastSpeed, 1.5);
        expect(player.lastVolume, .4);
        expect(generated, 1);
        expect(narrator.currentUtterance, 0);
        expect(narrator.state, SpeechState.playing);
      },
    );

    test('Pocket voice changes isolate cache and preserve navigation, timer and Kokoro cast', () async {
      narrator.settings = const VoiceSettings(
        engine: VoiceEngine.pocket,
        voice: 16,
      );
      start();
      await until(() => narrator.state == SpeechState.playing);
      await narrator.applySettings(
        narrator.settings.withChanges(speed: 1.4, volume: .4),
      );
      expect(player.lastSpeed, 1.4);
      expect(generated, 1);
      expect(rendered.first.speed, 1);
      await narrator.pause();
      narrator.sleepTimer.setDuration(const Duration(minutes: 15));
      await narrator.nextSentence();
      await until(() => narrator.passage == 'Second sentence.');
      expect(generated, 2);
      await narrator.applySettings(
        narrator.settings.withChanges(pocketVoice: 'marius'),
      );
      await until(
        () => generated == 3 && narrator.passage == 'Second sentence.',
      );
      expect(rendered.last.pocketVoice, 'marius');
      expect(narrator.state, SpeechState.paused);
      expect(narrator.sleepTimer.active, isTrue);
      await narrator.applySettings(
        narrator.settings.withChanges(engine: VoiceEngine.kokoro),
      );
      await until(
        () => generated == 4 && narrator.passage == 'Second sentence.',
      );
      expect(rendered.last.engine, VoiceEngine.kokoro);
      expect(rendered.last.voice, 6);
      await narrator.applySettings(
        narrator.settings.withChanges(engine: VoiceEngine.pocket),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await until(
        () => narrator.state == SpeechState.paused && !narrator.navigating,
      );
      expect(
        generated,
        4,
      ); // Pocket/Marius clip was cached before switching away.
      expect(narrator.currentUtterance, 1);
      expect(narrator.sleepTimer.active, isTrue);
    });

    test('Supertonic voice and language isolate cache and retain existing playback controls', () async {
      narrator.settings = const VoiceSettings(
        engine: VoiceEngine.supertonic,
        voice: 16,
      );
      start();
      await until(() => narrator.state == SpeechState.playing);
      await narrator.applySettings(
        narrator.settings.withChanges(speed: 1.4, volume: .4),
      );
      expect(player.lastSpeed, 1.4);
      expect(generated, 1);
      expect(rendered.first.speed, 1);
      await narrator.pause();
      narrator.sleepTimer.setDuration(const Duration(minutes: 15));
      await narrator.nextSentence();
      await until(() => narrator.passage == 'Second sentence.');
      expect(generated, 2);
      await narrator.applySettings(
        narrator.settings.withChanges(supertonicVoice: 'F2'),
      );
      await until(
        () => generated == 3 && narrator.passage == 'Second sentence.',
      );
      expect(rendered.last.supertonicVoice, 'F2');
      expect(narrator.state, SpeechState.paused);
      expect(narrator.sleepTimer.active, isTrue);
      await narrator.applySettings(
        narrator.settings.withChanges(engine: VoiceEngine.kokoro),
      );
      await until(
        () => generated == 4 && narrator.passage == 'Second sentence.',
      );
      expect(rendered.last.engine, VoiceEngine.kokoro);
      expect(rendered.last.voice, 6);
      await narrator.applySettings(
        narrator.settings.withChanges(engine: VoiceEngine.supertonic),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await until(
        () => narrator.state == SpeechState.paused && !narrator.navigating,
      );
      expect(
        generated,
        4,
      ); // Supertonic/F2 clip was cached before switching away.
      await narrator.applySettings(
        narrator.settings.withChanges(supertonicLanguage: 'fr'),
      );
      await until(
        () => generated == 5 && narrator.passage == 'Second sentence.',
      );
      expect(rendered.last.supertonicLanguage, 'fr');
      await narrator.applySettings(
        narrator.settings.withChanges(supertonicLanguage: 'en'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await until(
        () => narrator.state == SpeechState.paused && !narrator.navigating,
      );
      expect(generated, 5);
      expect(narrator.currentUtterance, 1);
      expect(narrator.sleepTimer.active, isTrue);
    });

    test('live voice changes rebuild current sentence once and preserve pause and timer', () async {
      start();
      await until(() => narrator.state == SpeechState.playing);
      await narrator.pause();
      narrator.sleepTimer.setDuration(const Duration(minutes: 15));
      await narrator.applySettings(narrator.settings.withChanges(voice: 6));
      await narrator.applySettings(narrator.settings.withChanges(voice: 16));
      await until(
        () => generated == 2 && narrator.passage == 'First sentence.',
      );
      expect(narrator.settings.voice, 16);
      expect(narrator.state, SpeechState.paused);
      expect(player.playing, isFalse);
      expect(narrator.currentUtterance, 0);
      expect(narrator.sleepTimer.active, isTrue);
      expect(generated, 2);
      narrator.resume();
      await until(() => narrator.state == SpeechState.playing);
      await narrator.applySettings(narrator.settings.withChanges(voice: 3));
      await narrator.stop();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(narrator.active, isFalse);
    });

    test(
      'closing settings without a preview keeps narration and its queue active',
      () async {
        start();
        await until(() => narrator.state == SpeechState.playing);
        await narrator.stopPreview();
        expect(narrator.state, SpeechState.playing);
        expect(narrator.active, isTrue);
      },
    );

    test(
      'sentence navigation crosses empty chapters in both directions',
      () async {
        start(utterance: 1);
        await until(() => narrator.state == SpeechState.playing);
        await narrator.nextSentence();
        await until(() => narrator.currentSection == 2);
        expect(narrator.passage, 'Last chapter sentence.');
        expect(narrator.canNextSentence, isFalse);
        await narrator.previousSentence();
        await until(() => narrator.currentSection == 0);
        expect(narrator.currentUtterance, 1);
        expect(narrator.speaker, 'Alice');
      },
    );

    test(
      'end of chapter timer waits for playback and prevents chapter advance',
      () async {
        start();
        await until(() => narrator.state == SpeechState.playing);
        narrator.sleepTimer.setSectionEnd(0);
        player.advance();
        await until(() => narrator.currentUtterance == 1);
        expect(narrator.active, isTrue);
        player.advance();
        await until(() => !narrator.active);
        expect(narrator.sleepTimer.active, isFalse);
        expect(checkpoints.every((point) => point.$1 == 0), isTrue);
      },
    );

    test(
      'duration timer stops paused playback and cancels on manual Stop',
      () async {
        start();
        await until(() => narrator.state == SpeechState.playing);
        await narrator.pause();
        narrator.sleepTimer.setDuration(const Duration(seconds: 1));
        await until(() => !narrator.active);
        expect(narrator.sleepTimer.active, isFalse);
        start();
        await until(() => narrator.state == SpeechState.playing);
        narrator.sleepTimer.setDuration(const Duration(minutes: 15));
        await narrator.stop();
        expect(narrator.sleepTimer.active, isFalse);
      },
    );

    test(
      'Stop cancels navigation awaiting a loader and prevents restart',
      () async {
        final loading = Completer<List<SpeechUtterance>>();
        var block = false;
        start(load: (i) => block ? loading.future : Future.value(chapters[i]));
        await until(() => narrator.state == SpeechState.playing);
        block = true;
        final navigation = narrator.nextSentence();
        await until(() => !narrator.active);
        await narrator.stop();
        expect(narrator.navigating, isFalse);
        loading.complete(chapters[0]);
        await navigation;
        expect(narrator.active, isFalse);
        expect(narrator.navigating, isFalse);
      },
    );
  });
}
