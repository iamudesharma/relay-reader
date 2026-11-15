import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_reader/narration.dart';

import 'listening_features_test.dart' show TestPlayer;

void main() {
  test(
    'only the selected Supertonic voice is prepared, without starting playback',
    () async {
      var prepared = 0;
      final player = TestPlayer();
      final narrator = Narrator(
        player: player,
        previewPlayer: TestPlayer(),
        prepareClipEngine: () async {
          prepared++;
        },
      );
      addTearDown(narrator.close);
      for (final engine in [
        VoiceEngine.kokoro,
        VoiceEngine.pocket,
        VoiceEngine.phonon,
        VoiceEngine.system,
      ]) {
        narrator.settings = VoiceSettings(engine: engine);
        await narrator.prepareSelectedVoice();
      }
      expect(prepared, 0);
      narrator.settings = const VoiceSettings(engine: VoiceEngine.supertonic);
      narrator.sleepTimer.setDuration(const Duration(minutes: 15));
      await narrator.prepareSelectedVoice();
      expect(prepared, 1);
      expect(player.audioSources, isEmpty);
      expect(player.playing, isFalse);
      expect(narrator.state, SpeechState.idle);
      expect(narrator.currentUtterance, isNull);
      expect(narrator.sleepTimer.active, isTrue);
    },
  );

  test('concurrent preparation shares one task and Stop waits for cancelled initialization', () async {
    final finish = Completer<void>();
    var prepared = 0;
    final narrator = Narrator(
      player: TestPlayer(),
      previewPlayer: TestPlayer(),
      prepareClipEngine: () {
        prepared++;
        return finish.future;
      },
    );
    addTearDown(narrator.close);
    narrator.settings = const VoiceSettings(engine: VoiceEngine.supertonic);
    final first = narrator.prepareSelectedVoice();
    final second = narrator.prepareSelectedVoice();
    expect(identical(first, second), isTrue);
    expect(prepared, 1);
    var stopped = false;
    final stopping = narrator.stop().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    finish.complete();
    await Future.wait([first, second, stopping]);
    expect(stopped, isTrue);
    expect(narrator.state, SpeechState.idle);
    await narrator.close();
    await narrator.prepareSelectedVoice();
    expect(prepared, 1);
  });
}
