import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:relay_reader/phonon.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('existing and imported Phonon voices keep the native route', () async {
    final root = await Directory.systemTemp.createTemp('relay-phonon-routing-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    const channel = MethodChannel('relay_reader/phonon');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'load') {
            return ['legacy-narrator', 'cloned.safetensors'];
          }
          return null;
        });
    addTearDown(() async {
      await PhononNarration.unload();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
    final legacy = await NativePhononModel.directory();
    await legacy.create(recursive: true);
    await File('${legacy.path}/test.bin').writeAsString('legacy model');
    await File('${legacy.path}/bundle.json').writeAsString(
      jsonEncode({
        'files': [
          {'path': 'test.bin'},
        ],
      }),
    );
    expect(await PhononModel.isInstalled(), isTrue);
    expect(await PhononNarration.voices(), contains('legacy-narrator'));
    await PhononNarration.synthesizeToFile(
      text: 'Hello.',
      path: '${root.path}/clip.wav',
      voice: 'legacy-narrator',
    );
    final synthesis = calls.singleWhere((call) => call.method == 'synthesize');
    expect((synthesis.arguments as Map)['voice'], 'legacy-narrator');

    final imported = File('${root.path}/cloned.safetensors');
    await imported.writeAsString('voice data');
    expect(await PhononModel.importVoice(imported), 'cloned.safetensors');
    expect(
      await File('${legacy.path}/voices/cloned.safetensors').readAsString(),
      'voice data',
    );

    final kokoro = File('${root.path}/mediapipe/kokoro/sentinel');
    await kokoro.parent.create(recursive: true);
    await kokoro.writeAsString('keep');
    await PhononModel.delete();
    expect(await PhononModel.isInstalled(), isFalse);
    expect(await kokoro.readAsString(), 'keep');
  }, skip: !Platform.isMacOS && !Platform.isIOS);
}
