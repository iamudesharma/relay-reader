import 'dart:io';

import 'mediapipe_tts.dart';

/// The pinned English INT8 bundle; keep its voices separate from Kokoro's cast.
abstract final class PocketTts {
  static bool get supported => Platform.isIOS || Platform.isMacOS;
  static const displaySize = '163 MB';
  static const revision = 'pocket-tts-en-465e0083';
  static const defaultVoice = 'alba';
  static const voices = {
    'alba': 'Alba',
    'marius': 'Marius',
    'javert': 'Javert',
    'jean': 'Jean',
    'fantine': 'Fantine',
    'cosette': 'Cosette',
    'eponine': 'Eponine',
    'azelma': 'Azelma',
  };

  static Future<bool> isInstalled() => MediaPipeModels.pocketInstalled();
  static Future<void> download(void Function(int, int) onProgress) =>
      MediaPipeModels.downloadPocket(onProgress);
  static Future<void> delete() => MediaPipeModels.deletePocket();

  static Future<void> synthesizeToFile({
    required String text,
    required String path,
    required String voice,
    double pauses = 1,
  }) => pocketSpeech.synthesizeToFile(
    text: text,
    path: path,
    voice: voice,
    pauses: pauses,
    // Rate changes happen in the player without recreating the model.
  );
}
