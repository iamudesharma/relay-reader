import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'narration.dart';
import 'phonon.dart';
import 'pocket_tts.dart';
import 'supertonic.dart';

/// Preferences shared by the library and all books. Existing preference keys
/// remain valid; book casts, corrections and checkpoints live in Library.
class ReaderPreferences extends ChangeNotifier {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  Future<void>? _loading;
  Future<void> _saving = Future.value();
  bool _disposed = false;
  int _saveRevision = 0;
  final transfers = ModelTransfers();
  VoiceSettings voice = VoiceSettings(
    engine: VoiceEngine.platformDefault,
    batterySaver:
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android,
  );
  double fontSize = 21, lineHeight = 1.65;
  bool darkPdfPages = true,
      backgroundPlayback = true,
      continueToEnd = true,
      lfm3Enabled = false;

  Future<void> load() =>
      _loading ??= _load().catchError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _load() async {
    final savedVoice = await _prefs.getInt('reader.voice.v1');
    final legacyVoice = savedVoice == null
        ? await _prefs.getInt('reader.voice')
        : null;
    final oldVoice = savedVoice ?? upgradedVoice(legacyVoice);
    final engine = await _prefs.getString('reader.engine');
    // A missing preference uses the new default. Legacy voice-only settings
    // and explicit engine choices retain their existing narrator.
    final preferred =
        engine == null && savedVoice == null && legacyVoice == null
        ? VoiceEngine.platformDefault
        : VoiceEngine.values.where((v) => v.name == engine).firstOrNull ??
              VoiceEngine.kokoro;
    final pocketVoice = await _prefs.getString('reader.pocketVoice');
    final supertonicVoice = await _prefs.getString('reader.supertonicVoice');
    final supertonicLanguage = await _prefs.getString(
      'reader.supertonicLanguage',
    );
    voice = VoiceSettings(
      engine: switch (preferred) {
        VoiceEngine.system when !SystemVoices.supported => VoiceEngine.kokoro,
        VoiceEngine.phonon when !PhononNarration.supported =>
          VoiceEngine.kokoro,
        VoiceEngine.pocket when !PocketTts.supported => VoiceEngine.kokoro,
        VoiceEngine.supertonic when !SupertonicModel.supported =>
          VoiceEngine.kokoro,
        _ => preferred,
      },
      voice: voices.containsKey(oldVoice) ? oldVoice : defaultVoice,
      systemVoice: await _prefs.getString('reader.systemVoice'),
      speed: (await _prefs.getDouble('reader.speed') ?? 1).clamp(.6, 1.8),
      pauses: (await _prefs.getDouble('reader.pauses') ?? 1).clamp(.05, 1),
      pitch: (await _prefs.getDouble('reader.pitch') ?? 1).clamp(.75, 1.35),
      volume: (await _prefs.getDouble('reader.volume') ?? 1).clamp(0, 1),
      punctuation: await _prefs.getBool('reader.marks') == true
          ? Punctuation.announce
          : Punctuation.natural,
      characterVoices: await _prefs.getBool('reader.characterVoices') ?? true,
      batterySaver:
          await _prefs.getBool('reader.batterySaver') ?? voice.batterySaver,
      lfm3Narration:
          preferred != VoiceEngine.pocket &&
          preferred != VoiceEngine.supertonic &&
          (await _prefs.getBool('reader.lfm3Audio') ?? false),
      lfm3Voice: await _prefs.getString('reader.lfm3AudioVoice') == 'male'
          ? 'male'
          : 'female',
      phononVoice: await _prefs.getString('reader.phononVoice') ?? 'Harper',
      pocketVoice: PocketTts.voices.containsKey(pocketVoice)
          ? pocketVoice!
          : PocketTts.defaultVoice,
      supertonicVoice: SupertonicModel.voices.containsKey(supertonicVoice)
          ? supertonicVoice!
          : 'M1',
      supertonicLanguage:
          SupertonicModel.languages.containsKey(supertonicLanguage)
          ? supertonicLanguage!
          : 'en',
    );
    fontSize = (await _prefs.getDouble('reader.font') ?? 21).clamp(15, 34);
    lineHeight = (await _prefs.getDouble('reader.leading') ?? 1.65).clamp(
      1.25,
      2,
    );
    darkPdfPages = await _prefs.getBool('reader.darkPdf') ?? true;
    backgroundPlayback = await _prefs.getBool('reader.backgroundAudio') ?? true;
    continueToEnd = await _prefs.getBool('reader.continueToEnd') ?? true;
    lfm3Enabled = await _prefs.getBool('reader.lfm3') ?? false;
  }

  /// Publish synchronously for live playback, then persist a snapshot in order.
  Future<void> save() {
    if (!_disposed) notifyListeners();
    final values = <String, Object?>{
      'reader.darkPdf': darkPdfPages,
      'reader.font': fontSize,
      'reader.leading': lineHeight,
      'reader.engine': voice.engine.name,
      'reader.voice.v1': voice.voice,
      'reader.systemVoice': voice.systemVoice,
      'reader.backgroundAudio': backgroundPlayback,
      'reader.continueToEnd': continueToEnd,
      'reader.speed': voice.speed,
      'reader.pauses': voice.pauses,
      'reader.pitch': voice.pitch,
      'reader.volume': voice.volume,
      'reader.marks': voice.punctuation == Punctuation.announce,
      'reader.characterVoices': voice.characterVoices,
      'reader.batterySaver': voice.batterySaver,
      'reader.lfm3': lfm3Enabled,
      'reader.lfm3Audio': voice.lfm3Narration,
      'reader.lfm3AudioVoice': voice.lfm3Voice,
      'reader.phononVoice': voice.phononVoice,
      'reader.pocketVoice': voice.pocketVoice,
      'reader.supertonicVoice': voice.supertonicVoice,
      'reader.supertonicLanguage': voice.supertonicLanguage,
    };
    final revision = ++_saveRevision;
    final next = _saving.then((_) async {
      for (final entry in values.entries) {
        // Slider updates publish immediately; superseded snapshots need no I/O.
        if (revision != _saveRevision) return;
        switch (entry.value) {
          case final bool value:
            await _prefs.setBool(entry.key, value);
          case final int value:
            await _prefs.setInt(entry.key, value);
          case final double value:
            await _prefs.setDouble(entry.key, value);
          case final String value:
            await _prefs.setString(entry.key, value);
          case null:
            await _prefs.remove(entry.key);
        }
      }
    });
    _saving = next.catchError((Object _) {});
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    transfers.dispose();
    super.dispose();
  }
}

/// Transfer state survives closing and reopening Settings without rebuilding
/// the reader or starting duplicate model downloads.
class ModelTransfers extends ChangeNotifier {
  final _states =
      <String, ({bool active, bool ready, int received, int total})>{};
  bool _disposed = false;
  ({bool active, bool ready, int received, int total}) state(String model) =>
      _states[model] ?? (active: false, ready: false, received: 0, total: 0);
  void update(
    String model, {
    bool? active,
    bool? ready,
    int? received,
    int? total,
  }) {
    final previous = state(model);
    _states[model] = (
      active: active ?? previous.active,
      ready: ready ?? previous.ready,
      received: received ?? previous.received,
      total: total ?? previous.total,
    );
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
