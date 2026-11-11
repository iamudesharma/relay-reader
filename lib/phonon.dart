import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class PhononException implements Exception {
  const PhononException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Phonon's Core ML programs need iOS 18 or macOS 15. Keep the option out of
/// the settings on older systems rather than offering a download that cannot
/// run.
bool _appleVersionSupported() {
  if (!Platform.isIOS && !Platform.isMacOS) return false;
  final match = RegExp(r'(\d+)').firstMatch(Platform.operatingSystemVersion);
  final major = int.tryParse(match?.group(1) ?? '') ?? 0;
  return Platform.isIOS ? major >= 18 : major >= 15;
}

/// The optional Phonon 31m English narrator.
///
/// The model is downloaded only after the reader explicitly chooses the
/// experimental engine. It runs on the Apple Neural Engine through the native
/// relay_reader/phonon bridge, so narration works without a connection.
abstract final class PhononModel {
  static const version = '0.7.0';
  static const displaySize = '137 MB';
  static const installedSize = 'about 190 MB';
  static const license = 'Apache 2.0';
  static const zipBytes = 137300950;

  static const _zipUrl =
      'https://github.com/gradium-ai/xn-ptts/releases/download/v0.7.0/'
      'phonon-31m-en-coreml.zip';

  static bool get supported => _appleVersionSupported();

  static Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/phonon').create(recursive: true);
  }

  static Future<Directory> directory() async =>
      Directory('${(await _root()).path}/31m-en');

  /// Whether every file named by the bundle manifest is present.
  static Future<bool> isInstalled() async {
    if (!supported) return false;
    try {
      final root = await directory();
      final manifest = File('${root.path}/bundle.json');
      if (!await manifest.exists()) return false;
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) return false;
      final files = decoded['files'];
      if (files is! List) return false;
      for (final entry in files) {
        if (entry is! Map) return false;
        final path = entry['path'];
        if (path is! String || path.isEmpty) return false;
        if (!await File('${root.path}/$path').exists()) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Downloads and installs the Core ML bundle. A partial download is resumed.
  static Future<void> download({
    required void Function(int received, int total) onProgress,
  }) async {
    if (!supported) {
      throw const PhononException(
        'Phonon is available only on iPhone, iPad, and Apple-silicon Macs.',
      );
    }
    final root = await _root();
    final zip = File('${root.path}/phonon-31m-en-coreml.zip.part');
    await _download(zip, onProgress: onProgress);

    final staged = Directory('${root.path}/extract');
    if (await staged.exists()) await staged.delete(recursive: true);
    await staged.create(recursive: true);
    InputFileStream? input;
    try {
      input = InputFileStream(zip.path);
      final archive = ZipDecoder().decodeStream(input);
      await extractArchiveToDisk(archive, staged.path);
    } on Object catch (error) {
      throw PhononException('The Phonon model could not be unpacked: $error');
    } finally {
      input?.closeSync();
    }

    final bundle = await _findBundle(staged);
    if (bundle == null) {
      await staged.delete(recursive: true);
      throw const PhononException(
        'The Phonon download did not contain a readable model bundle.',
      );
    }

    final target = await directory();
    if (await target.exists()) await target.delete(recursive: true);
    await bundle.parent.rename(target.path);
    if (await staged.exists()) await staged.delete(recursive: true);
    await zip.delete();
    if (!await isInstalled()) {
      throw const PhononException(
        'The Phonon model is incomplete. Delete it and download again.',
      );
    }
  }

  static Future<File?> _findBundle(Directory root) async {
    await for (final entity in root.list(recursive: true)) {
      if (entity is File && entity.uri.pathSegments.last == 'bundle.json') {
        return entity;
      }
    }
    return null;
  }

  static Future<void> _download(
    File part, {
    required void Function(int received, int total) onProgress,
  }) async {
    var start = await part.exists() ? await part.length() : 0;
    if (start > zipBytes) {
      await part.delete();
      start = 0;
    }
    if (start == zipBytes) {
      onProgress(start, zipBytes);
      return;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 30);
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(_zipUrl));
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
      } else if (start > 0 &&
          (response.statusCode == HttpStatus.requestedRangeNotSatisfiable ||
              response.statusCode == HttpStatus.notImplemented)) {
        // GitHub release assets do not always accept Range requests. Restart
        // once from zero instead of stranding a partial download.
        await response.drain<void>();
        await part.delete();
        return await _download(part, onProgress: onProgress);
      } else {
        await response.drain<void>();
        throw PhononException(
          'The Phonon download failed (HTTP ${response.statusCode}).',
        );
      }
      sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var received = start;
      onProgress(received, zipBytes);
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, zipBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != zipBytes) {
        throw PhononException(
          'The Phonon download ended early '
          '($received of $zipBytes bytes). Try again.',
        );
      }
    } on PhononException {
      rethrow;
    } on Object catch (error) {
      throw PhononException('The Phonon model could not be downloaded: $error');
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // Keep the original download failure.
      }
      client.close(force: true);
    }
  }

  /// Adds a voice file created in Gradium Studio, then reloads the model so
  /// the new voice appears in [PhononNarration.voices]. Cloning itself happens
  /// in Gradium Studio/API; Phonon does not enrol a recording on-device.
  static Future<String> importVoice(File source) async {
    if (!supported) {
      throw const PhononException(
        'Phonon is available only on Apple platforms.',
      );
    }
    if (!await isInstalled()) {
      throw const PhononException('Download the Phonon model first.');
    }
    if (!source.path.toLowerCase().endsWith('.safetensors')) {
      throw const PhononException(
        'Choose a Phonon .safetensors voice file from Gradium Studio.',
      );
    }
    final root = await directory();
    final voices = Directory('${root.path}/voices');
    await voices.create(recursive: true);
    final rawName = source.uri.pathSegments.last;
    final safe = rawName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final name = safe.isEmpty ? 'voice.safetensors' : safe;
    final target = File('${voices.path}/$name');
    await source.copy(target.path);

    await PhononNarration.unload();
    final loaded = await PhononNarration.voices(refresh: true);
    if (loaded.isEmpty) {
      throw const PhononException(
        'The voice file was added but Phonon did not load any voices.',
      );
    }
    return name;
  }

  static Future<void> delete() async {
    await PhononNarration.unload();
    await PhononNarration.stopPreview();
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (error) {
      throw PhononException('The Phonon model could not be deleted: $error');
    }
  }
}

/// Dart side of the native Core ML bridge. The native side owns the model
/// handle; this class keeps narration and preview calls serialized.
abstract final class PhononNarration {
  static const _channel = MethodChannel('relay_reader/phonon');
  static Timer? _releaseTimer;
  static List<String> _voices = const [];

  static bool get supported => _appleVersionSupported();

  static Future<bool> available() async {
    if (!supported) return false;
    try {
      final status = await _channel.invokeMethod<Map<Object?, Object?>>(
        'status',
      );
      return status?['available'] == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<String>> voices({bool refresh = false}) async {
    if (!supported) return const [];
    if (!refresh && _voices.isNotEmpty) return _voices;
    final values = await ensureLoaded();
    _voices = values;
    return _voices;
  }

  /// Loads the model if it is not already in memory. The native bridge returns
  /// immediately when the same folder is already loaded.
  static Future<List<String>> ensureLoaded() async {
    if (!supported) {
      throw const PhononException(
        'Phonon is available only on Apple platforms.',
      );
    }
    final directory = await PhononModel.directory();
    try {
      final values = await _channel.invokeMethod<List<dynamic>>('load', {
        'path': directory.path,
      });
      _releaseTimer?.cancel();
      return [
        for (final value in values ?? const <dynamic>[])
          if (value is String && value.isNotEmpty) value,
      ];
    } on MissingPluginException {
      throw const PhononException(
        'This build does not include the Phonon engine.',
      );
    } on PlatformException catch (error) {
      throw PhononException(
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'Phonon could not load on this device.',
      );
    }
  }

  static Future<void> synthesizeToFile({
    required String text,
    required String path,
    String? voice,
  }) async {
    if (!supported) {
      throw const PhononException(
        'Phonon is available only on Apple platforms.',
      );
    }
    await ensureLoaded();
    try {
      await _channel.invokeMethod<void>('synthesize', {
        'text': text,
        'path': path,
        'voice': voice,
      });
      _releaseTimer?.cancel();
    } on MissingPluginException {
      throw const PhononException(
        'This build does not include the Phonon engine.',
      );
    } on PlatformException catch (error) {
      throw PhononException(
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'Phonon could not narrate this passage.',
      );
    }
  }

  static Future<void> preview({
    required String text,
    required String path,
    String? voice,
  }) => synthesizeToFile(text: text, path: path, voice: voice);

  static Future<void> stopPreview() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('stopPreview');
    } catch (_) {
      // Nothing is playing.
    }
  }

  /// Frees the model after an idle period. The next narration reloads it.
  static void release({Duration after = const Duration(seconds: 90)}) {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(after, () => unawaited(unload()));
  }

  static Future<void> unload() async {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _voices = const [];
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('unload');
    } catch (_) {
      // The engine may already be gone.
    }
  }
}
