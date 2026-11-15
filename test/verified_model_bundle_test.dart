import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_reader/verified_model_bundle.dart';

void main() {
  late Directory root;
  late Map<String, dynamic> spec;
  const contents = {'encoder/model.bin': 'encoder', 'voices/M1.json': 'voice'};
  setUp(() async {
    root = await Directory.systemTemp.createTemp('relay-model-bundle-');
    spec = {
      'repository': 'example/model',
      'revision': 'fixed',
      'files': [
        for (final entry in contents.entries)
          {
            'path': entry.key,
            'bytes': utf8.encode(entry.value).length,
            'sha256': sha256.convert(utf8.encode(entry.value)).toString(),
          },
      ],
    };
  });
  tearDown(() => root.delete(recursive: true));
  VerifiedModelBundle bundle(http.Client Function() client) =>
      VerifiedModelBundle(
        directory: () async => Directory('${root.path}/supertonic'),
        manifest: () async => spec,
        client: client,
      );
  String content(Uri url) => contents.entries
      .firstWhere((entry) => url.path.endsWith(entry.key))
      .value;

  test('only a complete verified bundle is installed; tampering is detected before load', () async {
    final model = bundle(
      () => MockClient(
        (request) async => http.Response(content(request.url), 200),
      ),
    );
    expect(await model.installed(), isFalse);
    var received = 0, total = 0;
    await model.download((a, b) {
      received = a;
      total = b;
    });
    expect(received, total);
    expect(await model.installed(verify: true), isTrue);
    await File('${root.path}/supertonic/encoder/model.bin')
        .writeAsString('changed');
    expect(await model.installed(verify: true), isFalse);
  });

  test(
    'failed installation has no receipt and retry reuses verified files',
    () async {
      var fail = true;
      final calls = <String, int>{};
      final model = bundle(
        () => MockClient((request) async {
          final path = request.url.path;
          calls[path] = (calls[path] ?? 0) + 1;
          return fail && path.endsWith('M1.json')
              ? http.Response('failed', 500)
              : http.Response(content(request.url), 200);
        }),
      );
      await expectLater(
        model.download((_, _) {}),
        throwsA(isA<HttpException>()),
      );
      expect(await model.installed(), isFalse);
      expect(
        await File('${root.path}/supertonic/installed.json').exists(),
        isFalse,
      );
      fail = false;
      await model.download((_, _) {});
      expect(await model.installed(verify: true), isTrue);
      expect(
        calls.entries
            .singleWhere((entry) => entry.key.endsWith('model.bin'))
            .value,
        1,
      );
    },
  );

  test('checksum failure discards partial file; deleting one model keeps other engines', () async {
    final model = bundle(
      () => MockClient((_) async => http.Response('wrong', 200)),
    );
    final marker = File('${root.path}/kokoro.keep');
    await marker.writeAsString('keep');
    await expectLater(
      model.download((_, _) {}),
      throwsA(isA<FormatException>()),
    );
    expect(await model.installed(), isFalse);
    final partials = await Directory('${root.path}/supertonic')
        .list(recursive: true)
        .where((file) => file.path.endsWith('.part'))
        .toList();
    expect(partials, isEmpty);
    await model.delete();
    expect(await marker.readAsString(), 'keep');
  });

  test(
    'invalid manifest path cannot write outside the model directory',
    () async {
      (spec['files'] as List).first['path'] = '../outside';
      final model = bundle(
        () => MockClient(
          (_) async => throw StateError('Must not request assets'),
        ),
      );
      await expectLater(
        model.download((_, _) {}),
        throwsA(isA<FormatException>()),
      );
      expect(await File('${root.path}/outside').exists(), isFalse);
    },
  );

  test(
    'native verifier is used only for a complete bundle requiring hash checks',
    () async {
      var verified = 0, valid = true;
      final model = VerifiedModelBundle(
        directory: () async => Directory('${root.path}/supertonic'),
        manifest: () async => spec,
        client: () => MockClient(
          (request) async => http.Response(content(request.url), 200),
        ),
        verifyFiles: (directory, files) async {
          verified++;
          expect(directory, '${root.path}/supertonic');
          expect(files, hasLength(2));
          return valid;
        },
      );
      expect(await model.installed(verify: true), isFalse);
      expect(verified, 0);
      await model.download((_, _) {});
      expect(await model.installed(), isTrue);
      expect(verified, 0);
      expect(await model.installed(verify: true), isTrue);
      expect(verified, 1);
      valid = false;
      expect(await model.installed(verify: true), isFalse);
      expect(verified, 2);
    },
  );
}
