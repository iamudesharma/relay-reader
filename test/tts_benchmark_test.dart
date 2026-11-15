import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediapipe_audio/mediapipe_audio.dart' as mp;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:relay_reader/mediapipe_tts.dart';
import 'package:relay_reader/supertonic.dart';

class _Network extends HttpOverrides {}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _BenchmarkConfig {
  const _BenchmarkConfig(
    this.name,
    this.voice,
    this.load,
    this.synthesize,
    this.unload,
  );
  final String name, voice;
  final Future<List<String>> Function() load;
  final Future<void> Function(String, String) synthesize;
  final Future<void> Function() unload;
}

_BenchmarkConfig _mediaPipe(
  String name,
  MediaPipeSpeech engine,
  String voice,
  bool battery,
) => _BenchmarkConfig(
  name,
  voice,
  () => engine.voices(batterySaver: battery),
  (text, path) => engine.synthesizeToFile(
    text: text,
    voice: voice,
    path: path,
    batterySaver: battery,
  ),
  engine.unload,
);

/// Native inference, not mocked or clip-cached. Downloads optional weights once.
/// flutter test test/tts_benchmark_test.dart --dart-define=RUN_TTS_BENCHMARK=true --reporter expanded
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerTtsBenchmark();
}

void registerTtsBenchmark({
  bool includeSupertonic = false,
  bool useAppModels = false,
  String? outputDirectory,
}) {
  const enabled = bool.fromEnvironment('RUN_TTS_BENCHMARK');
  test(
    'compare native speech engines',
    () async {
      final base = Directory(outputDirectory ?? 'build/tts-benchmark').absolute;
      final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        ':',
        '-',
      );
      final output = Directory('${base.path}/$stamp');
      await output.create(recursive: true);
      final previous = PathProviderPlatform.instance;
      if (!useAppModels) {
        PathProviderPlatform.instance = _Paths('${base.path}/models');
      }
      addTearDown(() async {
        await kokoroSpeech.unload();
        await phononSpeech.unload();
        await pocketSpeech.unload();
        if (includeSupertonic) await SupertonicNarration.unload();
        if (includeSupertonic) {
          await SupertonicNarration.channel.invokeMethod<void>('endBenchmark');
        }
        PathProviderPlatform.instance = previous;
      });
      if (includeSupertonic) {
        await SupertonicNarration.channel.invokeMethod<void>('beginBenchmark');
      }
      // Materialize the bundled model before timing, just like downloaded ones.
      // This keeps the first-run bundle copy out of Kokoro's load measurement.
      await MediaPipeModels.path('kokoro', mp.AudioModels.kokoro);
      await HttpOverrides.runWithHttpOverrides(() async {
        for (final download
            in <String, Future<void> Function(void Function(int, int))>{
              'Phonon': MediaPipeModels.downloadPhonon,
              'Pocket TTS': MediaPipeModels.downloadPocket,
              if (includeSupertonic) 'Supertonic 3': SupertonicModel.download,
            }.entries) {
          // ignore: avoid_print
          print('Preparing ${download.key} (download excluded from timings)');
          var last = -1;
          await download.value((received, total) {
            final bucket = total > 0 ? received * 10 ~/ total : 0;
            if (bucket != last) {
              last = bucket;
              // ignore: avoid_print
              print('${download.key}: ${bucket * 10}%');
            }
          });
        }
      }, _Network());
      const passages = {
        'narration': 'A gentle breeze moved through the open window. Across the garden, the old house stood quietly beneath the evening sky.',
        'dialogue': '"Did you hear that?" Alice whispered. "It was only the wind," James replied, but he kept his eyes on the door.',
        'names_numbers': 'Reid and Kit reached the station at 4:45 PM. In 1969, a ticket cost twelve dollars. Derek\'s train left on Wednesday.',
        'long_passage': 'The road curved between the trees, and for a moment she could see the river shining beyond the fields. She remembered walking here as a child, counting the stones along the bank while her brother searched for birds. Now the path seemed smaller, but the sound of the water was exactly as she remembered it.',
      };
      final support = await mp.queryTextToSpeechCapabilities();
      final configurations = [
        if (includeSupertonic)
          _BenchmarkConfig(
            'supertonic_ane_int4',
            'M1',
            () async {
              await SupertonicNarration.ensureLoaded();
              return SupertonicModel.voices.keys.toList();
            },
            (text, path) => SupertonicNarration.synthesizeToFile(
              text: text,
              path: path,
              voice: 'M1',
            ),
            SupertonicNarration.unload,
          ),
        _mediaPipe('kokoro_cpu', kokoroSpeech, 'af_heart', true),
        _mediaPipe('phonon_cpu', phononSpeech, 'freya', true),
        _mediaPipe('pocket_cpu', pocketSpeech, 'alba', true),
        if (support.supportedDelegates.contains(mp.Delegate.gpu))
          _mediaPipe('kokoro_gpu', kokoroSpeech, 'af_heart', false),
      ];
      final rows = <Map<String, Object>>[];
      final summaries = <Map<String, Object>>[];
      final errors = <String>[];
      const reverse = bool.fromEnvironment('BENCH_REVERSE');
      for (final config in reverse ? configurations.reversed : configurations) {
        await config.unload();
        try {
          final watch = Stopwatch()..start();
          final voices = await config.load();
          final loadMs = watch.elapsedMicroseconds / 1000;
          expect(voices, contains(config.voice));
          if (config.name == 'pocket_cpu') {
            expect(
              voices,
              containsAll([
                'alba',
                'marius',
                'javert',
                'jean',
                'fantine',
                'cosette',
                'eponine',
                'azelma',
              ]),
            );
          }
          Future<Map<String, Object>> synthesize(
            String id,
            String text,
            int round,
          ) async {
            final path = '${output.path}/${config.name}-$id-$round.wav';
            final timer = Stopwatch()..start();
            await config.synthesize(text, path);
            final elapsed = timer.elapsedMicroseconds / 1000;
            final wav = mp.decodeWav(await File(path).readAsBytes());
            expect(wav.samples.every((sample) => sample.isFinite), isTrue);
            expect(wav.samples.any((sample) => sample.abs() > .001), isTrue);
            final duration = wav.samples.length / wav.sampleRate;
            expect(duration, greaterThan(1));
            final row = <String, Object>{
              'configuration': config.name,
              'voice': config.voice,
              'passage': id,
              'round': round,
              'text': text,
              'synthesis_ms': elapsed,
              'audio_seconds': duration,
              'rtfx': duration * 1000 / elapsed,
              'sample_rate': wav.sampleRate,
              'rss_bytes_after': ProcessInfo.currentRss,
              'wav': path,
            };
            rows.add(row);
            return row;
          }

          final first = await synthesize('first', passages.values.first, 0);
          final warm = <Map<String, Object>>[];
          for (var round = 1; round <= 3; round++) {
            for (final passage in passages.entries) {
              warm.add(await synthesize(passage.key, passage.value, round));
            }
          }
          final latencies =
              warm.map((row) => row['synthesis_ms'] as double).toList()..sort();
          final synthMs = warm.fold<double>(
            0,
            (sum, row) => sum + (row['synthesis_ms'] as double),
          );
          final audioSeconds = warm.fold<double>(
            0,
            (sum, row) => sum + (row['audio_seconds'] as double),
          );
          final summary = <String, Object>{
            'configuration': config.name,
            'voice': config.voice,
            'load_ms': loadMs,
            'first_synthesis_ms': first['synthesis_ms']!,
            'load_plus_first_clip_ms':
                loadMs + (first['synthesis_ms'] as double),
            'warm_median_ms': (latencies[5] + latencies[6]) / 2,
            'warm_p95_ms': latencies[(latencies.length * .95).ceil() - 1],
            'warm_rtfx': audioSeconds * 1000 / synthMs,
            'warm_audio_seconds': audioSeconds,
            'warm_synthesis_ms': synthMs,
          };
          summaries.add(summary);
          // ignore: avoid_print
          print(jsonEncode(summary));
        } catch (error, stack) {
          errors.add('${config.name}: $error\n$stack');
        } finally {
          await config.unload();
        }
      }
      final cpu = await Process.run('sysctl', [
        '-n',
        'machdep.cpu.brand_string',
      ]);
      final result = {
        'timestamp_utc': stamp,
        'cpu': '${cpu.stdout}'.trim(),
        'os': Platform.operatingSystemVersion,
        'dart': Platform.version,
        'runtime': includeSupertonic
            ? 'MediaPipe 0.2.1/native 1.2.2; Supertonic Core ML INT4 / 8 steps / rate 1'
            : 'mediapipe_audio 0.2.1 / native 1.2.2',
        'host': useAppModels
            ? 'macOS Flutter debug app'
            : 'Flutter native test host',
        'app_nap_prevented': includeSupertonic,
        if (includeSupertonic)
          'supertonic_model_revision': SupertonicModel.revision,
        'method': 'flutter test native bridge; one loaded model; rate 1; pauses 1; no clip cache; three warm rounds; full WAV latency including file write; load is model-cold, not filesystem-cold',
        'model_sha256': {
          'kokoro': mp.AudioModels.kokoro.sha256,
          'phonon': mp.AudioModels.phonon.sha256,
          'pocket': mp.AudioModels.pocketTtsEn.sha256,
        },
        'summaries': summaries,
        'rows': rows,
        'errors': errors,
        'process_peak_rss_bytes': ProcessInfo.maxRss,
        'limitations': 'No transcription or human quality scoring. RSS is process-wide and cumulative, not isolated per-model peak. Running apps and thermal conditions are not controlled.',
      };
      await File('${output.path}/results.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      await File('${base.path}/latest.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      final csv = StringBuffer(
        'configuration,voice,load_ms,first_synthesis_ms,load_plus_first_clip_ms,warm_median_ms,warm_p95_ms,warm_rtfx\n',
      );
      for (final summary in summaries) {
        csv.writeln(
          [
            'configuration',
            'voice',
            'load_ms',
            'first_synthesis_ms',
            'load_plus_first_clip_ms',
            'warm_median_ms',
            'warm_p95_ms',
            'warm_rtfx',
          ].map((key) => summary[key]).join(','),
        );
      }
      await File('${output.path}/summary.csv').writeAsString(csv.toString());
      // ignore: avoid_print
      print('Benchmark artifacts: ${output.path}');
      expect(errors, isEmpty);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
