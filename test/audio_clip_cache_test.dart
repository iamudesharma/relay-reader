import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_reader/audio_clip_cache.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('relay-cache-test-');
  });
  tearDown(() => root.delete(recursive: true));

  Future<String> source(String name) async {
    final file = File('${root.path}/$name');
    await file.writeAsBytes(
      Uint8List.fromList(List.filled(80, name.codeUnitAt(0))),
    );
    return file.path;
  }

  test(
    'cache survives new instances, validates bytes and isolates books/settings',
    () async {
      final directory = Directory('${root.path}/cache');
      final cache = AudioClipCache(directory: directory);
      final key = AudioClipCache.clipKey({
        'text': 'Hello.',
        'voice': 'heart',
        'speed': 1,
      });
      final changed = AudioClipCache.clipKey({
        'text': 'Hello.',
        'voice': 'emma',
        'speed': 1,
      });
      final path = await source('original');
      await cache.put('book', key, path);
      final reopened = AudioClipCache(directory: directory);
      final destination = '${root.path}/working.wav';
      expect(await reopened.copyTo('book', key, destination), isTrue);
      expect(
        await File(destination).readAsBytes(),
        await File(path).readAsBytes(),
      );
      expect(await reopened.copyTo('other-book', key, destination), isFalse);
      expect(await reopened.copyTo('book', changed, destination), isFalse);
      final cachedFile = File(
        '${directory.path}/${AudioClipCache.bookKey('book')}/$key.audio',
      );
      await cachedFile.writeAsBytes(
        List.filled(80, 0),
      ); // Same-size corruption.
      expect(await reopened.copyTo('book', key, destination), isFalse);
    },
  );

  test(
    'LRU evicts old clips without removing working playback copies',
    () async {
      final directory = Directory('${root.path}/cache');
      final cache = AudioClipCache(directory: directory, maxBytes: 430);
      final first = AudioClipCache.clipKey({'text': 'one'});
      final second = AudioClipCache.clipKey({'text': 'two'});
      final third = AudioClipCache.clipKey({'text': 'three'});
      await cache.put('book', first, await source('first'));
      await cache.put('book', second, await source('second'));
      final working = '${root.path}/playing.wav';
      expect(await cache.copyTo('book', first, working), isTrue);
      final old = File(
        '${directory.path}/${AudioClipCache.bookKey('book')}/$second.audio',
      );
      await old.setLastModified(DateTime(2020));
      await cache.put('book', third, await source('third'));
      expect(
        await cache.copyTo('book', second, '${root.path}/miss.wav'),
        isFalse,
      );
      expect(await File(working).exists(), isTrue);
      var total = 0;
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) total += await entity.length();
      }
      expect(total, lessThanOrEqualTo(430));
      await cache.removeBook('book');
      expect(await cache.copyTo('book', first, working), isFalse);
      expect(await File(working).exists(), isTrue);
    },
  );

  test(
    'failed storage and cancelled writes never stop playback or cache partials',
    () async {
      final occupied = File('${root.path}/occupied');
      await occupied.writeAsString('not a directory');
      final broken = AudioClipCache(directory: Directory(occupied.path));
      await broken.put('book', 'clip', await source('audio'));
      expect(
        await broken.copyTo('book', 'clip', '${root.path}/working.wav'),
        isFalse,
      );
      final cache = AudioClipCache(directory: Directory('${root.path}/cache'));
      await cache.put(
        'book',
        'clip',
        await source('audio'),
        valid: () => false,
      );
      expect(
        await cache.copyTo('book', 'clip', '${root.path}/working.wav'),
        isFalse,
      );
    },
  );
}
