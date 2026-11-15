import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediapipe_audio/mediapipe_audio.dart' as mp;
import 'package:relay_reader/mediapipe_tts.dart';

class FakeSpeechTask implements SpeechTask {
  final started = Completer<void>();
  Completer<void>? finish;
  bool disposed = false;
  int calls = 0;
  @override
  Future<List<String>> voices() async => kokoroVoiceIds;
  @override
  Future<({Float32List samples, int rate})> synthesize(
    String text,
    String voice,
  ) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await finish?.future;
    return (samples: Float32List.fromList([0, .2, -.2]), rate: 24000);
  }

  @override
  void cancel() {} // Simulate native work that completes despite cancellation.
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  test('WAV encodes PCM16, clamps samples and keeps sample rate', () {
    final bytes = speechWav(Float32List.fromList([-2, -.5, 0, .5, 2]), 24000);
    final decoded = mp.decodeWav(bytes);
    expect(decoded.sampleRate, 24000);
    expect(decoded.samples, hasLength(5));
    expect(decoded.samples.first, closeTo(-1, .0001));
    expect(decoded.samples.last, closeTo(1, .0001));
    expect(
      () => speechWav(Float32List(0), 24000),
      throwsA(isA<MediaPipeSpeechException>()),
    );
    expect(
      () => speechWav(Float32List.fromList([double.nan]), 24000),
      throwsA(isA<MediaPipeSpeechException>()),
    );
  });

  test(
    'pause scaling changes sustained internal gaps, preserving word audio',
    () {
      final input = Float32List.fromList([
        ...List.filled(10, .2),
        ...List.filled(200, 0),
        ...List.filled(10, -.2),
        ...List.filled(10, 0),
        ...List.filled(10, .2),
      ]);
      final output = mp.decodeWav(speechWav(input, 1000, pauses: .5)).samples;
      expect(output, hasLength(input.length - 100));
      expect(output.where((s) => s.abs() > .1), hasLength(30));
    },
  );

  test(
    'cancel during model loading prevents synthesis and file creation',
    () async {
      final loading = Completer<SpeechTask>();
      final opened = Completer<void>();
      final task = FakeSpeechTask();
      final engine = MediaPipeSpeech(
        'kokoro',
        mp.AudioModels.kokoro,
        openTask: (_, _) {
          opened.complete();
          return loading.future;
        },
      );
      final root = await Directory.systemTemp.createTemp('relay-cancel-load-');
      addTearDown(() async {
        await engine.unload();
        await root.delete(recursive: true);
      });
      final path = '${root.path}/clip.wav';
      final result = engine.synthesizeToFile(
        text: 'Hello.',
        path: path,
        voice: 'af_heart',
      );
      final check = expectLater(
        result,
        throwsA(isA<MediaPipeSpeechException>()),
      );
      await opened.future;
      engine.cancel();
      loading.complete(task);
      await check;
      expect(task.calls, 0);
      expect(await File(path).exists(), isFalse);
    },
  );

  test(
    'cancel discards running and queued clips; subsequent synthesis works',
    () async {
      final task = FakeSpeechTask()..finish = Completer<void>();
      final engine = MediaPipeSpeech(
        'kokoro',
        mp.AudioModels.kokoro,
        openTask: (_, _) async => task,
      );
      final root = await Directory.systemTemp.createTemp('relay-cancel-work-');
      addTearDown(() async {
        await engine.unload();
        await root.delete(recursive: true);
      });
      final first = engine.synthesizeToFile(
        text: 'One.',
        path: '${root.path}/one.wav',
        voice: 'af_heart',
      );
      final firstCheck = expectLater(
        first,
        throwsA(isA<MediaPipeSpeechException>()),
      );
      await task.started.future;
      final second = engine.synthesizeToFile(
        text: 'Two.',
        path: '${root.path}/two.wav',
        voice: 'bf_emma',
      );
      final secondCheck = expectLater(
        second,
        throwsA(isA<MediaPipeSpeechException>()),
      );
      engine.cancel();
      task.finish!.complete();
      await Future.wait([firstCheck, secondCheck]);
      expect(await root.list().isEmpty, isTrue);
      expect(task.calls, 1);
      task.finish = null;
      await engine.synthesizeToFile(
        text: 'Three.',
        path: '${root.path}/three.wav',
        voice: 'bf_emma',
      );
      expect(await File('${root.path}/three.wav').length(), greaterThan(44));
    },
  );

  test(
    'voice switches reuse a task, while speed changes dispose and reload it',
    () async {
      final tasks = <FakeSpeechTask>[];
      final engine = MediaPipeSpeech(
        'kokoro',
        mp.AudioModels.kokoro,
        openTask: (_, _) async {
          final task = FakeSpeechTask();
          tasks.add(task);
          return task;
        },
      );
      final root = await Directory.systemTemp.createTemp('relay-warm-task-');
      addTearDown(() async {
        await engine.unload();
        await root.delete(recursive: true);
      });
      await engine.synthesizeToFile(
        text: 'One.',
        path: '${root.path}/one.wav',
        voice: 'af_heart',
      );
      await engine.synthesizeToFile(
        text: 'Two.',
        path: '${root.path}/two.wav',
        voice: 'bf_emma',
      );
      expect(tasks, hasLength(1));
      await engine.synthesizeToFile(
        text: 'Three.',
        path: '${root.path}/three.wav',
        voice: 'bf_emma',
        speed: 1.2,
      );
      expect(tasks, hasLength(2));
      expect(tasks.first.disposed, isTrue);
      await expectLater(
        engine.synthesizeToFile(
          text: 'Missing.',
          path: '${root.path}/missing.wav',
          voice: 'missing',
          speed: 1.2,
        ),
        throwsA(isA<MediaPipeSpeechException>()),
      );
      expect(await File('${root.path}/missing.wav').exists(), isFalse);
    },
  );

  test('saved Kokoro IDs retain US and UK narrator identities', () {
    expect(kokoroVoiceIds, hasLength(28));
    expect(kokoroVoiceIds.toSet(), hasLength(28));
    expect(kokoroVoiceIds[3], 'af_heart');
    expect(kokoroVoiceIds[20], 'bf_alice');
    expect(kokoroVoiceIds[26], 'bm_george');
  });
}
