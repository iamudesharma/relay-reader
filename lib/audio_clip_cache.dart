import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Disposable, bounded disk cache. Playback always uses a separate working copy,
/// so eviction never removes a queued or playing file. Failures are cache misses.
class AudioClipCache {
  AudioClipCache({this.directory, this.maxBytes = 200 * 1024 * 1024});
  static final shared = AudioClipCache();
  final Directory? directory;
  final int maxBytes;
  Future<void> _tail = Future.value();
  int? _knownBytes;

  static String digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  static String bookKey(String bookId) => digest(bookId);
  static String clipKey(Map<String, Object?> identity) => digest(identity);

  Future<Directory> _root() async =>
      directory ??
      Directory('${(await getApplicationCacheDirectory()).path}/narration-v1');

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<bool> copyTo(String bookId, String key, String destination) =>
      _serial(() async {
        try {
          final root = await _root();
          final clip = File('${root.path}/${bookKey(bookId)}/$key.audio');
          final receipt = File('${clip.path}.json');
          if (!await clip.exists() || !await receipt.exists()) return false;
          final metadata = jsonDecode(await receipt.readAsString()) as Map;
          final bytes = await clip.readAsBytes();
          if (bytes.length < 44 ||
              bytes.length != metadata['length'] ||
              sha256.convert(bytes).toString() != metadata['sha256']) {
            await clip.delete();
            await receipt.delete();
            _knownBytes = null;
            return false;
          }
          await File(destination).writeAsBytes(bytes, flush: true);
          await clip.setLastModified(DateTime.now());
          return true;
        } catch (_) {
          return false;
        }
      });

  Future<void> put(
    String bookId,
    String key,
    String source, {
    bool Function()? valid,
  }) => _serial(() async {
    File? staged;
    try {
      if (valid?.call() == false) return;
      final file = File(source);
      final size = await file.length();
      if (size < 44 || size > maxBytes) return;
      final bytes = await file.readAsBytes();
      final root = await _root();
      final folder = await Directory('${root.path}/${bookKey(bookId)}')
          .create(recursive: true);
      final clip = File('${folder.path}/$key.audio');
      final receipt = File('${clip.path}.json');
      final replacedBytes =
          (await clip.exists() ? await clip.length() : 0) +
          (await receipt.exists() ? await receipt.length() : 0);
      staged = File('${clip.path}.part');
      await staged.writeAsBytes(bytes, flush: true);
      if (valid?.call() == false) return;
      await staged.rename(clip.path);
      await receipt.writeAsString(
        jsonEncode({
          'length': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        }),
        flush: true,
      );
      if (_knownBytes != null) {
        _knownBytes =
            _knownBytes! +
            bytes.length +
            await receipt.length() -
            replacedBytes;
      }
      await _trim(root);
    } catch (_) {
      _knownBytes = null;
      // Lack of disk space or an unavailable cache must not stop narration.
    } finally {
      try {
        if (staged != null && await staged.exists()) await staged.delete();
      } catch (_) {}
    }
  });

  Future<void> _trim(Directory root) async {
    if (_knownBytes != null && _knownBytes! <= maxBytes) return;
    final entries = <({File file, FileStat stat})>[];
    var total = 0;
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      if (entry.path.endsWith('.part') ||
          (entry.path.endsWith('.audio.json') &&
              !await File(entry.path.substring(0, entry.path.length - 5))
                  .exists())) {
        await entry.delete();
        continue;
      }
      final stat = await entry.stat();
      total += stat.size;
      if (entry.path.endsWith('.audio')) entries.add((file: entry, stat: stat));
    }
    entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    // Evict in batches to avoid a full directory scan for every new sentence.
    final target = total > maxBytes ? (maxBytes * .9).floor() : maxBytes;
    for (final entry in entries) {
      if (total <= target) break;
      await entry.file.delete();
      total -= entry.stat.size;
      final receipt = File('${entry.file.path}.json');
      if (await receipt.exists()) {
        total -= await receipt.length();
        await receipt.delete();
      }
    }
    _knownBytes = total;
  }

  Future<void> removeBook(String bookId) => _serial(() async {
    try {
      final root = await _root();
      final folder = Directory('${root.path}/${bookKey(bookId)}');
      if (await folder.exists()) await folder.delete(recursive: true);
      _knownBytes = null;
    } catch (_) {}
  });
}
