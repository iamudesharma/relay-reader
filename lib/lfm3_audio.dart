import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'lfm3.dart';

class Lfm3AudioException implements Exception {
  const Lfm3AudioException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One downloadable file that makes up the LFM3-Audio narration model.
class Lfm3AudioFile {
  const Lfm3AudioFile(this.name, this.bytes, this.url);

  final String name;
  final int bytes;
  final String url;
}

/// The optional LFM3-Audio-2B narration model.
///
/// The main and projector GGUFs are stored in the app's private support
/// directory, never bundled with the app. They are fetched only after the
/// reader explicitly enables the experimental narration feature.
abstract final class Lfm3AudioModel {
  static const displaySize = '1.3 GB';
  static const license = 'LFM Open License v1.0';

  static const _repo =
      'https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/main/';
  static const files = <Lfm3AudioFile>[
    Lfm3AudioFile(
      'LFM3-Audio-2B-Q4_K_M.gguf',
      1099626016,
      '${_repo}LFM3-Audio-2B-Q4_K_M.gguf?download=true',
    ),
    Lfm3AudioFile(
      'mmproj-LFM3-Audio-2B-Q4_K_M.gguf',
      172418048,
      '${_repo}mmproj-LFM3-Audio-2B-Q4_K_M.gguf?download=true',
    ),
  ];
  static int get totalBytes =>
      files.fold(0, (total, file) => total + file.bytes);

  static bool get supported => Platform.isIOS || Platform.isMacOS;

  static Future<Directory> directory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/lfm3_audio').create(recursive: true);
  }

  static Future<bool> isInstalled() async {
    if (!supported) return false;
    try {
      final root = await directory();
      for (final spec in files) {
        final file = File('${root.path}/${spec.name}');
        if (!await file.exists() || await file.length() != spec.bytes) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Downloads both GGUF files. A partial file is resumed when the server
  /// supports ranges. This is called only after an explicit user action.
  static Future<void> download({
    required void Function(int received, int total) onProgress,
  }) async {
    if (!supported) {
      throw const Lfm3AudioException(
        'LFM3-Audio is not available on this platform.',
      );
    }
    final root = await directory();
    final total = totalBytes;
    var completed = 0;
    var lastPercent = -1;
    void report(int received) {
      final percent = total <= 0
          ? 0
          : ((received / total) * 100).floor().clamp(0, 100);
      if (percent == lastPercent) return;
      lastPercent = percent;
      onProgress(received, total);
    }

    for (final spec in files) {
      final target = File('${root.path}/${spec.name}');
      if (await target.exists() && await target.length() == spec.bytes) {
        completed += spec.bytes;
        report(completed);
        continue;
      }
      final part = File('${target.path}.part');
      await _downloadFile(
        spec,
        part,
        onProgress: (received) => report(completed + received),
      );
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      completed += spec.bytes;
      report(completed);
    }
    if (!await isInstalled()) {
      throw const Lfm3AudioException(
        'The LFM3-Audio model download is incomplete. Try again.',
      );
    }
  }

  static Future<void> _downloadFile(
    Lfm3AudioFile spec,
    File part, {
    required void Function(int received) onProgress,
  }) async {
    var start = await part.exists() ? await part.length() : 0;
    if (start > spec.bytes) {
      await part.delete();
      start = 0;
    }
    if (start == spec.bytes) {
      onProgress(start);
      return;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 30);
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(spec.url));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'RelayReader/1.5 (+https://relay.local)',
      );
      if (start > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      }
      final response = await request.close();
      var append = false;
      if (response.statusCode == HttpStatus.partialContent && start > 0) {
        append = true;
      } else if (response.statusCode == HttpStatus.ok) {
        start = 0;
      } else if (response.statusCode ==
              HttpStatus.requestedRangeNotSatisfiable &&
          start == spec.bytes) {
        onProgress(start);
        await response.drain<void>();
        return;
      } else {
        await response.drain<void>();
        throw Lfm3AudioException(
          'The LFM3-Audio download failed (HTTP ${response.statusCode}).',
        );
      }

      sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var received = start;
      onProgress(received);
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != spec.bytes) {
        throw Lfm3AudioException(
          'The LFM3-Audio download ended early '
          '($received of ${spec.bytes} bytes).',
        );
      }
    } on Lfm3AudioException {
      rethrow;
    } catch (error) {
      throw Lfm3AudioException(
        'The LFM3-Audio model could not be downloaded: $error',
      );
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // Keep the original download failure.
      }
      client.close(force: true);
    }
  }

  static Future<void> delete() async {
    await Lfm3Audio.unload();
    try {
      final root = await directory();
      for (final spec in files) {
        for (final path in [
          '${root.path}/${spec.name}',
          '${root.path}/${spec.name}.part',
        ]) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      }
    } catch (error) {
      throw Lfm3AudioException(
        'The LFM3-Audio model could not be deleted: $error',
      );
    }
  }
}

/// Loads and runs LFM3-Audio for narration. The engine is kept alive across
/// clips so a chapter does not reload the 1.3 GB model for every sentence.
abstract final class Lfm3Audio {
  static const voices = <String>['female', 'male'];
  static const _maxFrames = 2048;
  static const _contextTokens = 8192;

  static TextToSpeechEngine? _engine;
  static Future<TextToSpeechEngine>? _loading;
  static TextToSpeechTask? _task;
  static Timer? _idle;
  static int _generation = 0;

  static bool get isLoaded => _engine != null;

  /// Requests cancellation of the active clip, if any.
  static void cancel() => _task?.cancel();

  static Future<TextToSpeechEngine> _load() async {
    if (!Lfm3AudioModel.supported) {
      throw const Lfm3AudioException(
        'LFM3-Audio is not available on this platform.',
      );
    }
    if (!await Lfm3AudioModel.isInstalled()) {
      throw const Lfm3AudioException(
        'Download the LFM3-Audio narration model first.',
      );
    }
    // Do not keep the text LFM3 model resident while the audio model loads.
    // Both are large, and the speaker analyzer and narration are never used
    // at the same time.
    await Lfm3Model.unload();

    final existing = _engine;
    if (existing != null) return existing;
    final loading = _loading;
    if (loading != null) return loading;

    final generation = _generation;
    final future = _open(generation);
    _loading = future;
    try {
      return await future;
    } finally {
      if (identical(_loading, future)) _loading = null;
    }
  }

  static Future<TextToSpeechEngine> _open(int generation) async {
    final root = await Lfm3AudioModel.directory();
    final main = Lfm3AudioModel.files.first;
    final projector = Lfm3AudioModel.files.last;
    TextToSpeechEngine? engine;
    try {
      engine = await TextToSpeechEngine.load(
        TextToSpeechModel(
          ModelSource.path('${root.path}/${main.name}'),
          projector: ModelSource.path('${root.path}/${projector.name}'),
          adapter: const Lfm3AudioTtsAdapter(),
        ),
        params: ModelParams(
          contextSize: _contextTokens,
          numberOfThreads: Platform.numberOfProcessors.clamp(1, 4),
          numberOfThreadsBatch: Platform.numberOfProcessors.clamp(1, 4),
          device: ComputeDevice.auto,
        ),
      );
      final capabilities = await engine.capabilities;
      if (!capabilities.isSupported) {
        throw Lfm3AudioException(
          capabilities.unsupportedReason ??
              'LFM3-Audio cannot synthesize speech on this device.',
        );
      }
      if (generation != _generation) {
        throw const Lfm3AudioException(
          'The LFM3-Audio model was unloaded while it was loading.',
        );
      }
      _engine = engine;
      return engine;
    } catch (error) {
      try {
        await engine?.dispose();
      } catch (_) {
        // Keep the load failure.
      }
      if (error is Lfm3AudioException) rethrow;
      throw Lfm3AudioException('LFM3-Audio could not be loaded: $error');
    }
  }

  static Future<void> synthesizeToFile({
    required String text,
    required String voice,
    required String path,
  }) async {
    if (text.trim().isEmpty) return;
    final engine = await _load();
    final TextToSpeechResult result;
    try {
      final task = await engine.synthesize(
        TextToSpeechRequest(
          text: text,
          voice: voices.contains(voice) ? voice : voices.first,
          language: 'en',
          maxFrames: _maxFrames,
        ),
      );
      _task = task;
      result = await task.result;
    } on LlamaException catch (error) {
      throw Lfm3AudioException('LFM3-Audio could not speak: $error');
    } catch (error) {
      throw Lfm3AudioException('LFM3-Audio could not speak: $error');
    } finally {
      _task = null;
    }
    if (result.samples.isEmpty) {
      throw const Lfm3AudioException(
        'LFM3-Audio returned no speech for this passage.',
      );
    }
    if (result.truncated) {
      throw const Lfm3AudioException(
        'LFM3-Audio ran out of room for this passage. Try a shorter section.',
      );
    }
    try {
      await File(path).writeAsBytes(result.toWavBytes(), flush: true);
    } on FileSystemException catch (error) {
      throw Lfm3AudioException(
        'The LFM3-Audio clip could not be saved: $error',
      );
    }
    _idle?.cancel();
    _idle = Timer(const Duration(minutes: 2), () => unawaited(unload()));
  }

  static Future<Uint8List> synthesize({
    required String text,
    String voice = 'female',
  }) async {
    final directory = await Directory.systemTemp.createTemp('lfm3-audio-');
    try {
      final path = '${directory.path}/speech.wav';
      await synthesizeToFile(text: text, voice: voice, path: path);
      return await File(path).readAsBytes();
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Temporary files are cleaned up by the OS if this fails.
      }
    }
  }

  static Future<void> unload() async {
    _idle?.cancel();
    _idle = null;
    _generation++;
    final loading = _loading;
    final engine = _engine;
    _engine = null;
    if (loading != null) {
      try {
        await loading;
      } catch (_) {
        // The load failed or was cancelled by this unload.
      }
    }
    try {
      await engine?.dispose();
    } catch (_) {
      // The engine may already be disposed.
    }
  }
}
