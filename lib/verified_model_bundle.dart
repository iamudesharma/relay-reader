import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Pinned, resumable multi-file model installation. Only complete, verified
/// bundles get a receipt; loading never downloads missing files implicitly.
class VerifiedModelBundle {
  VerifiedModelBundle({
    required this.directory,
    required this.manifest,
    http.Client Function()? client,
    this.verifyFiles,
  }) : _client = client ?? http.Client.new;
  final Future<Directory> Function() directory;
  final Future<Map<String, dynamic>> Function() manifest;
  final http.Client Function() _client;
  final Future<bool> Function(
    String directory,
    List<Map<String, dynamic>> files,
  )?
  verifyFiles;
  Future<void>? _install;

  static List<Map<String, dynamic>> _files(Map<String, dynamic> spec) {
    final files = (spec['files'] as List).cast<Map<String, dynamic>>();
    for (final file in files) {
      final path = file['path'] as String;
      if (path.startsWith('/') ||
          path.contains('\\') ||
          path.split('/').any((part) => part == '..' || part.isEmpty)) {
        throw const FormatException('Invalid model asset path');
      }
    }
    return files;
  }

  Future<bool> installed({bool verify = false}) async {
    try {
      final spec = await manifest();
      final root = await directory();
      final receipt = jsonDecode(
        await File('${root.path}/installed.json').readAsString(),
      ) as Map;
      if (receipt['manifest'] !=
          sha256.convert(utf8.encode(jsonEncode(spec))).toString()) {
        return false;
      }
      final files = _files(spec);
      for (final item in files) {
        if (!await _valid(
          File('${root.path}/${item['path']}'),
          item,
          verify: verify && verifyFiles == null,
        )) {
          return false;
        }
      }
      if (verify && verifyFiles != null) {
        return await verifyFiles!(root.path, files);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _valid(
    File file,
    Map<String, dynamic> item, {
    bool verify = true,
  }) async {
    if (!await file.exists() || await file.length() != item['bytes']) {
      return false;
    }
    return !verify ||
        (await sha256.bind(file.openRead()).first).toString() == item['sha256'];
  }

  Future<void> download(void Function(int, int) onProgress) =>
      _install ??= _download(onProgress).whenComplete(() => _install = null);

  Future<void> _download(void Function(int, int) onProgress) async {
    final spec = await manifest();
    final files = _files(spec);
    final root = await directory();
    await root.create(recursive: true);
    final receipt = File('${root.path}/installed.json');
    if (await receipt.exists()) await receipt.delete();
    final client = _client();
    var index = 0, received = 0;
    final total = files.fold<int>(
      0,
      (sum, item) => sum + (item['bytes'] as int),
    );
    void progress(int count) {
      received += count;
      onProgress(received, total);
    }

    onProgress(0, total);
    try {
      await Future.wait(
        List.generate(4, (_) async {
          while (index < files.length) {
            final item = files[index++];
            final file = File('${root.path}/${item['path']}');
            if (await _valid(file, item)) {
              progress(item['bytes'] as int);
              continue;
            }
            await file.parent.create(recursive: true);
            final partial = File('${file.path}.part');
            try {
              final url = Uri.parse(
                'https://huggingface.co/${spec['repository']}/resolve/${spec['revision']}/${item['path']}',
              );
              final response = await client.send(http.Request('GET', url));
              if (response.statusCode != 200) {
                throw HttpException(
                  'Model download failed (HTTP ${response.statusCode})',
                );
              }
              final sink = partial.openWrite();
              try {
                await for (final chunk in response.stream) {
                  sink.add(chunk);
                  progress(chunk.length);
                }
                await sink.flush();
              } finally {
                await sink.close();
              }
              if (!await _valid(partial, item)) {
                throw const FormatException(
                  'Model checksum verification failed',
                );
              }
              await partial.rename(file.path);
            } finally {
              if (await partial.exists()) await partial.delete();
            }
          }
        }),
      );
      final staged = File('${receipt.path}.part');
      await staged.writeAsString(
        jsonEncode({
          'manifest': sha256.convert(utf8.encode(jsonEncode(spec))).toString(),
        }),
        flush: true,
      );
      await staged.rename(receipt.path);
    } finally {
      client.close();
    }
  }

  Future<void> delete() async {
    if (_install != null) {
      throw StateError('Wait for the model download to finish');
    }
    final root = await directory();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
