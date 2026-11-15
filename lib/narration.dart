import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

import 'lfm3_audio.dart';
import 'audio_clip_cache.dart';
import 'listening_sleep_timer.dart';
import 'mediapipe_tts.dart';
import 'phonon.dart';
import 'pocket_tts.dart';
import 'supertonic.dart';

// English speakers in the bundled Kokoro v1.0 voice table.
const defaultVoice = 3;
const voices = {
  3: 'Heart · US · warm',
  0: 'Alloy · US · neutral',
  1: 'Aoede · US · light',
  2: 'Bella · US · bright',
  4: 'Jessica · US · expressive',
  5: 'Kore · US · firm',
  6: 'Nicole · US · calm',
  7: 'Nova · US · friendly',
  8: 'River · US · soft',
  9: 'Sarah · US · gentle',
  10: 'Sky · US · airy',
  11: 'Adam · US · deep',
  12: 'Echo · US · steady',
  13: 'Eric · US · warm',
  14: 'Fenrir · US · bold',
  15: 'Liam · US · clear',
  16: 'Michael · US · rich',
  17: 'Onyx · US · deep',
  18: 'Puck · US · lively',
  19: 'Santa · US · jolly',
  20: 'Alice · UK · clear',
  21: 'Emma · UK · warm',
  22: 'Isabella · UK · bright',
  23: 'Lily · UK · soft',
  24: 'Daniel · UK · clear',
  25: 'Fable · UK · storyteller',
  26: 'George · UK · rich',
  27: 'Lewis · UK · calm',
};

int upgradedVoice(int? previous) => switch (previous) {
  1 => 2,
  2 => 6,
  3 => 9,
  4 => 10,
  5 => 11,
  6 => 16,
  7 => 21,
  8 => 22,
  9 => 26,
  10 => 27,
  _ => defaultVoice,
};

Future<void> initializeNarration() async {
  if (Platform.isIOS || Platform.isAndroid) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.relay.relay_reader.narration',
      androidNotificationChannelName: 'Relay Reader narration',
      androidStopForegroundOnPause: false,
    );
  }
}

enum Punctuation { natural, announce }

enum VoiceEngine {
  kokoro('Kokoro', 'Bundled, works offline'),
  system('System', 'Uses your iPhone voices'),
  phonon('Phonon', 'Experimental · on-device English'),
  pocket('Pocket TTS', 'Experimental · on-device English'),
  supertonic('Supertonic 3', 'Default narrator · on-device · 31 languages');

  const VoiceEngine(this.label, this.description);
  final String label;
  final String description;

  static VoiceEngine get platformDefault =>
      SupertonicModel.supported ? VoiceEngine.supertonic : VoiceEngine.kokoro;
}

enum SpeechKind { narration, dialogue }

/// One sentence-sized piece of speech with an optional character voice.
class SpeechUtterance {
  const SpeechUtterance(
    this.text, {
    this.kind = SpeechKind.narration,
    this.speaker,
    this.kokoroVoice,
    this.systemVoice,
  });

  final String text;
  final SpeechKind kind;
  final String? speaker;
  final int? kokoroVoice;
  final String? systemVoice;

  bool get isDialogue => kind == SpeechKind.dialogue;
}

typedef SpeechLoader = Future<List<SpeechUtterance>> Function(int section);
typedef NarrationProgress = void Function(
  int section,
  int utterance,
  SpeechUtterance speech,
);

/// An Apple system voice that can be used instead of the bundled Kokoro voice.
class SystemVoice {
  const SystemVoice({
    required this.identifier,
    required this.name,
    required this.locale,
    required this.quality,
  });

  factory SystemVoice.fromMap(Object? value) {
    final map = value as Map<Object?, Object?>;
    return SystemVoice(
      identifier: '${map['identifier'] ?? ''}',
      name: '${map['name'] ?? ''}',
      locale: '${map['locale'] ?? ''}',
      quality: (map['quality'] as num?)?.toInt() ?? 0,
    );
  }

  final String identifier;
  final String name;
  final String locale;
  final int quality;

  String get qualityLabel => switch (quality) {
    >= 3 => 'Premium',
    2 => 'Enhanced',
    _ => 'Standard',
  };

  String get label {
    final region = locale.split(RegExp('[-_]')).last.toUpperCase();
    return '$name · $region · $qualityLabel';
  }
}

/// Talks to the small native bridge that lists and renders Apple voices.
abstract final class SystemVoices {
  static const _channel = MethodChannel('relay_reader/system_voices');

  static bool get supported => Platform.isIOS;

  static Future<List<SystemVoice>> list() async {
    if (!supported) return const [];
    try {
      final values = await _channel.invokeMethod<List<dynamic>>('list');
      final voices = [
        for (final value in values ?? const <dynamic>[])
          if (value is Map) SystemVoice.fromMap(value),
      ];
      voices.sort((a, b) {
        final quality = b.quality.compareTo(a.quality);
        if (quality != 0) return quality;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return voices;
    } on MissingPluginException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> synthesize({
    required String text,
    required String path,
    required VoiceSettings settings,
  }) async {
    if (!supported) return false;
    try {
      final success = await _channel.invokeMethod<bool>('synthesize', {
        'text': text,
        'path': path,
        'identifier': settings.systemVoice,
        'rate': (settings.speed * .5).clamp(.1, 1.0),
        'volume': settings.volume,
        'pitch': settings.pitch,
      });
      return success ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> preview({
    required String text,
    required VoiceSettings settings,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('preview', {
        'text': text,
        'identifier': settings.systemVoice,
        'rate': (settings.speed * .5).clamp(.1, 1.0),
        'volume': settings.volume,
        'pitch': settings.pitch,
      });
    } on MissingPluginException {
      // Keep the bundled voice when a native bridge is unavailable.
    }
  }

  static Future<void> stopPreview() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('stopPreview');
    } catch (_) {
      // Nothing to stop.
    }
  }
}

class VoiceSettings {
  const VoiceSettings({
    this.engine = VoiceEngine.kokoro,
    this.voice = defaultVoice,
    this.systemVoice,
    this.speed = 1,
    this.pauses = 1,
    this.pitch = 1,
    this.volume = 1,
    this.punctuation = Punctuation.natural,
    this.characterVoices = true,
    this.batterySaver = false,
    this.lfm3Narration = false,
    this.lfm3Voice = 'female',
    this.phononVoice = 'Harper',
    this.pocketVoice = PocketTts.defaultVoice,
    this.supertonicVoice = 'M1',
    this.supertonicLanguage = 'en',
  });

  final VoiceEngine engine;
  final int voice;
  final String? systemVoice;
  final String phononVoice;
  final String pocketVoice;
  final String supertonicVoice;
  final String supertonicLanguage;
  final double speed;
  final double pauses;
  final double pitch;
  final double volume;
  final Punctuation punctuation;
  final bool characterVoices;

  /// Generates less audio ahead and releases idle voices sooner. Intended for
  /// longer listening sessions on battery.
  final bool batterySaver;

  /// Uses the optional LFM3-Audio model for narration. Character dialogue
  /// keeps the selected Kokoro/System cast voices.
  final bool lfm3Narration;
  final String lfm3Voice;

  VoiceSettings withChanges({
    VoiceEngine? engine,
    int? voice,
    String? systemVoice,
    double? speed,
    double? pauses,
    double? pitch,
    double? volume,
    Punctuation? punctuation,
    bool? characterVoices,
    bool? batterySaver,
    bool? lfm3Narration,
    String? lfm3Voice,
    String? phononVoice,
    String? pocketVoice,
    String? supertonicVoice,
    String? supertonicLanguage,
  }) => VoiceSettings(
    engine: engine ?? this.engine,
    voice: voice ?? this.voice,
    systemVoice: systemVoice ?? this.systemVoice,
    speed: speed ?? this.speed,
    pauses: pauses ?? this.pauses,
    pitch: pitch ?? this.pitch,
    volume: volume ?? this.volume,
    punctuation: punctuation ?? this.punctuation,
    characterVoices: characterVoices ?? this.characterVoices,
    batterySaver: batterySaver ?? this.batterySaver,
    lfm3Narration: lfm3Narration ?? this.lfm3Narration,
    lfm3Voice: lfm3Voice ?? this.lfm3Voice,
    phononVoice: phononVoice ?? this.phononVoice,
    pocketVoice: pocketVoice ?? this.pocketVoice,
    supertonicVoice: supertonicVoice ?? this.supertonicVoice,
    supertonicLanguage: supertonicLanguage ?? this.supertonicLanguage,
  );
}

const voicePresets = {
  'Warm': VoiceSettings(voice: 3, speed: .94, pauses: 1),
  'Natural': VoiceSettings(voice: 3, speed: 1, pauses: 1),
  'Clear': VoiceSettings(voice: 16, speed: 1, pauses: .9),
  'Bright': VoiceSettings(voice: 2, speed: 1.06, pauses: .8),
  'British': VoiceSettings(voice: 26, speed: .98, pauses: 1),
  'Fast': VoiceSettings(speed: 1.22, pauses: .55),
};

/// Kokoro's presets choose voice timbre as well as pacing. Other narrators
/// retain their own voice and expose only supported playback-rate presets.
bool usesKokoroVoicePresets(VoiceSettings settings) =>
    settings.engine == VoiceEngine.kokoro && !settings.lfm3Narration;

Map<String, VoiceSettings> narrationPresets(VoiceSettings settings) =>
    usesKokoroVoicePresets(settings)
    ? voicePresets
    : {
        'Relaxed': settings.withChanges(speed: .85),
        'Natural': settings.withChanges(speed: 1),
        'Fast': settings.withChanges(speed: 1.22),
      };

VoiceSettings applyNarrationPreset(
  VoiceSettings settings,
  VoiceSettings preset,
) => usesKokoroVoicePresets(settings)
    ? settings.withChanges(
        voice: preset.voice,
        speed: preset.speed,
        pauses: preset.pauses,
        punctuation: preset.punctuation,
      )
    : settings.withChanges(speed: preset.speed);

bool isNarrationPresetSelected(VoiceSettings settings, VoiceSettings preset) {
  if ((settings.speed - preset.speed).abs() > .000001) return false;
  return !usesKokoroVoicePresets(settings) ||
      (settings.voice == preset.voice &&
          (settings.pauses - preset.pauses).abs() < .000001 &&
          settings.punctuation == preset.punctuation);
}

const _marks = {
  ',': 'comma',
  '.': 'period',
  ';': 'semicolon',
  ':': 'colon',
  '!': 'exclamation mark',
  '?': 'question mark',
  '(': 'open parenthesis',
  ')': 'close parenthesis',
  '[': 'open bracket',
  ']': 'close bracket',
  '"': 'quotation mark',
  '“': 'open quote',
  '”': 'close quote',
  '—': 'dash',
  '–': 'dash',
  '…': 'ellipsis',
};

String prepareSpeech(String text, Punctuation punctuation) {
  if (punctuation == Punctuation.natural) return text;
  return text.replaceAllMapped(
    RegExp(r'[,.;:!?()\[\]"“”—–…]'),
    (match) => ' ${_marks[match[0]]} ',
  );
}

/// The longest passage handed to the speech model at once.
///
/// Larger passages keep sentence prosody and pauses natural because the model
/// sees more context, while the hard cap keeps preview latency bounded.
const speechChunkLimit = 420;

/// Sentence boundaries preserve abbreviations, decimals and closing quotes.
Iterable<String> speechChunks(String text) sync* {
  for (final paragraph
      in text.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'))) {
    final normalized = paragraph.replaceAll(RegExp(r'\s+'), ' ').trim();
    var start = 0;
    final boundaries = RegExp(r'[.!?…]+["”’\x27)]*(?:\s+|$)')
        .allMatches(normalized);
    for (final boundary in boundaries) {
      final prefix = normalized.substring(start, boundary.end).trim();
      if (RegExp(
        r'(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc)|\b[A-Z]|e\.g|i\.e)\.$',
        caseSensitive: false,
      ).hasMatch(prefix)) {
        continue;
      }
      yield* _boundedSpeech(prefix);
      start = boundary.end;
    }
    yield* _boundedSpeech(normalized.substring(start).trim());
  }
}

Iterable<String> _boundedSpeech(String text) sync* {
  final runes = text.runes.toList();
  for (var start = 0; start < runes.length;) {
    var end = (start + speechChunkLimit).clamp(0, runes.length);
    if (end < runes.length) {
      for (var i = end - 1; i > start + speechChunkLimit ~/ 2; i--) {
        if (runes[i] == 32) {
          end = i + 1;
          break;
        }
      }
    }
    final part = String.fromCharCodes(runes, start, end).trim();
    if (part.isNotEmpty) yield part;
    start = end;
  }
}

class SpeechFailure implements Exception {
  const SpeechFailure(this.message);
  final String message;
}

enum SpeechState { idle, preparing, playing, paused }

class _NarrationSession {
  const _NarrationSession({
    required this.title,
    required this.sectionName,
    required this.length,
    required this.loadSpeech,
    required this.showSection,
    required this.continueToEnd,
    required this.settings,
    this.bookId,
    this.onProgress,
  });
  final String title, sectionName;
  final String? bookId;
  final int length;
  final SpeechLoader loadSpeech;
  final ValueChanged<int> showSection;
  final bool continueToEnd;
  final VoiceSettings settings;
  final NarrationProgress? onProgress;
}

typedef ClipSynthesizer = Future<void> Function(
  SpeechUtterance speech,
  VoiceSettings settings,
  String path,
);

class Narrator extends ChangeNotifier {
  Narrator({
    this.prefetch = 4,
    AudioPlayer? player,
    AudioPlayer? previewPlayer,
    AudioClipCache? cache,
    this.synthesizeClip,
    this.prepareClipEngine,
    this.configureAudioSession,
  }) : _player = player ?? AudioPlayer(),
       _previewPlayer = previewPlayer ?? AudioPlayer(),
       _cache = cache ?? AudioClipCache.shared {
    sleepTimer = ListeningSleepTimer(() => unawaited(stop()));
  }

  /// How many generated clips stay queued ahead of playback.
  final int prefetch;

  final AudioPlayer _player;
  final AudioPlayer _previewPlayer;
  final AudioClipCache _cache;
  final ClipSynthesizer? synthesizeClip;
  final Future<void> Function()? prepareClipEngine;
  final Future<void> Function()? configureAudioSession;
  late final ListeningSleepTimer sleepTimer;
  _NarrationSession? _session;
  int? currentSection, currentUtterance;
  int _currentSectionLength = 0;
  bool navigating = false;
  Timer? _settingsTimer;
  Future<void>? _preparation;
  int _startIndex = 0, _startUtterance = 0;
  String? _startPassage;
  bool _continueToEnd = true;
  int _navigationToken = 0;
  bool get canPreviousSentence =>
      active &&
      !navigating &&
      currentUtterance != null &&
      (currentUtterance! > 0 || currentSection! > 0);
  bool get canNextSentence =>
      active &&
      !navigating &&
      currentUtterance != null &&
      (currentUtterance! + 1 < _currentSectionLength ||
          (_session!.continueToEnd && currentSection! + 1 < _session!.length));
  Future<void>? _run;
  Future<void>? _closing;
  Completer<void>? _changed;
  Object? _playError;
  bool _stopped = false;
  bool _paused = false;
  bool _started = false;
  bool _closed = false;
  bool _previewing = false;
  int _previewToken = 0;

  SpeechState state = SpeechState.idle;
  VoiceSettings settings = const VoiceSettings();
  String? passage;
  String? speaker;
  String? error;
  bool get active => _run != null;
  bool get previewing => _previewing;

  void start({
    required String title,
    String? bookId,
    required String sectionName,
    required int index,
    required int length,
    required SpeechLoader loadSpeech,
    required ValueChanged<int> showSection,
    bool continueToEnd = true,
    int startUtterance = 0,
    String? resumePassage,
    NarrationProgress? onProgress,
  }) {
    if (_closed || active || navigating) return;
    final session = _NarrationSession(
      title: title,
      bookId: bookId,
      sectionName: sectionName,
      length: length,
      loadSpeech: loadSpeech,
      showSection: showSection,
      continueToEnd: continueToEnd,
      onProgress: onProgress,
      settings: settings,
    );
    _startSession(session, index, startUtterance, resumePassage: resumePassage);
  }

  void _startSession(
    _NarrationSession session,
    int index,
    int utterance, {
    String? resumePassage,
    bool paused = false,
  }) {
    if (_closed) return;
    _session = session;
    _startIndex = index;
    _startUtterance = utterance;
    _startPassage = resumePassage;
    _continueToEnd = session.continueToEnd;
    _stopped = false;
    _paused = paused;
    _started = false;
    _playError = null;
    currentSection = null;
    currentUtterance = null;
    error = null;
    speaker = null;
    state = paused ? SpeechState.paused : SpeechState.preparing;
    _run = _read(
      session.title,
      session.sectionName,
      index,
      session.length,
      session.loadSpeech,
      session.showSection,
      session.continueToEnd,
      utterance,
      resumePassage,
      session.onProgress,
    );
    notifyListeners();
  }

  _NarrationSession _updatedSession(_NarrationSession session) =>
      _NarrationSession(
        title: session.title,
        sectionName: session.sectionName,
        bookId: session.bookId,
        length: session.length,
        loadSpeech: session.loadSpeech,
        showSection: session.showSection,
        continueToEnd: _continueToEnd,
        settings: settings,
        onProgress: session.onProgress,
      );

  /// Volume and speed affect the current player immediately. Synthesis changes
  /// replace queued clips from the current sentence after the control settles.
  Future<void> applySettings(
    VoiceSettings next, {
    bool? continueToEnd,
    bool rebuild = false,
  }) async {
    if (_preparation != null &&
        !active &&
        !navigating &&
        next.engine != VoiceEngine.supertonic) {
      SupertonicNarration.cancel();
    }
    settings = next;
    if (_closed) return;
    if (continueToEnd != null) _continueToEnd = continueToEnd;
    final session = _session;
    if ((!active && !navigating) || session == null) return;
    _settingsTimer?.cancel();
    final base = session.settings;
    final playerRate =
        base.engine == VoiceEngine.phonon ||
            base.engine == VoiceEngine.pocket ||
            base.engine == VoiceEngine.supertonic ||
            base.lfm3Narration
        ? 1.0
        : base.speed;
    // Send both changes before awaiting either, preserving slider event order.
    final volume = _player.setVolume(next.volume);
    final speed = _player.setSpeed(next.speed / playerRate);
    if (rebuild ||
        !_sameSynthesis(base, next) ||
        _continueToEnd != session.continueToEnd) {
      _settingsTimer = Timer(
        const Duration(milliseconds: 180),
        () => unawaited(_restartForSettings()),
      );
    }
    await Future.wait([volume, speed]);
  }

  bool _sameSynthesis(VoiceSettings a, VoiceSettings b) =>
      (
        a.engine,
        a.voice,
        a.systemVoice,
        a.phononVoice,
        a.pocketVoice,
        a.supertonicVoice,
        a.supertonicLanguage,
        a.pauses,
        a.pitch,
        a.punctuation,
        a.characterVoices,
        a.batterySaver,
        a.lfm3Narration,
        a.lfm3Voice,
      ) ==
      (
        b.engine,
        b.voice,
        b.systemVoice,
        b.phononVoice,
        b.pocketVoice,
        b.supertonicVoice,
        b.supertonicLanguage,
        b.pauses,
        b.pitch,
        b.punctuation,
        b.characterVoices,
        b.batterySaver,
        b.lfm3Narration,
        b.lfm3Voice,
      );

  Future<void> _restartForSettings() async {
    final session = _session;
    if (_closed || navigating || !active || session == null) return;
    _settingsTimer?.cancel();
    final token = ++_navigationToken;
    navigating = true;
    final section = currentSection ?? _startIndex;
    final utterance = currentUtterance ?? _startUtterance;
    final resumePassage = passage ?? _startPassage;
    final wasPaused = _paused;
    notifyListeners();
    try {
      await _stopRun();
      if (_closed || token != _navigationToken) return;
      _startSession(
        _updatedSession(session),
        section,
        utterance,
        resumePassage: resumePassage,
        paused: wasPaused,
      );
    } finally {
      if (token == _navigationToken) navigating = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> previousSentence() => _navigateSentence(-1);
  Future<void> nextSentence() => _navigateSentence(1);

  Future<void> _navigateSentence(int direction) async {
    final session = _session;
    if (direction < 0 ? !canPreviousSentence : !canNextSentence) return;
    if (!active || navigating || session == null || currentUtterance == null) {
      return;
    }
    _settingsTimer?.cancel();
    final token = ++_navigationToken;
    navigating = true;
    notifyListeners();
    final wasPaused = _paused;
    var section = currentSection!;
    var utterance = currentUtterance! + direction;
    try {
      // Cancel in-flight synthesis immediately. Replaying uses cached clips.
      await _stopRun();
      while (section >= 0 && section < session.length) {
        if (_closed || token != _navigationToken) return;
        final speeches = await session.loadSpeech(section);
        if (_closed || token != _navigationToken) return;
        if (utterance >= 0 && utterance < speeches.length) {
          if (sleepTimer.atSectionEnd) sleepTimer.setSectionEnd(section);
          _startSession(
            _updatedSession(session),
            section,
            utterance,
            paused: wasPaused,
          );
          return;
        }
        if (!session.continueToEnd && direction > 0) return;
        section += direction;
        if (direction < 0) {
          if (section < 0) break;
          final previous = await session.loadSpeech(section);
          utterance = previous.length - 1;
        } else {
          utterance = 0;
        }
      }
      // At a boundary, keep the last valid sentence and pause state.
      if (!_closed && token == _navigationToken) {
        _startSession(
          _updatedSession(session),
          currentSection!,
          currentUtterance!,
          paused: wasPaused,
        );
      }
    } catch (failure) {
      if (!_closed && token == _navigationToken) {
        error = 'Could not change sentence. Try Read aloud again.';
      }
    } finally {
      if (token == _navigationToken) navigating = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> _read(
    String title,
    String sectionName,
    int index,
    int length,
    SpeechLoader loadSpeech,
    ValueChanged<int> showSection,
    bool continueToEnd,
    int startUtterance,
    String? resumePassage,
    NarrationProgress? onProgress,
  ) async {
    Directory? audio;
    final clips = <String, _ClipInfo>{};
    String? currentClip;
    final playback = _player.playerStateStream.listen((player) {
      if (_started &&
          !_stopped &&
          player.processingState == ProcessingState.idle) {
        // A lock-screen stop leaves no source loaded; end the run cleanly.
        _stopped = true;
        _wake();
        return;
      }
      if (_started && !_stopped) {
        _paused =
            !player.playing &&
            player.processingState != ProcessingState.completed;
        _setState(_paused ? SpeechState.paused : SpeechState.playing);
      }
      _wake();
    });
    final sequence = _player.sequenceStateStream.listen((sequence) {
      final tag = sequence.currentSource?.tag;
      if (!_stopped && tag is MediaItem && tag.id != currentClip) {
        currentClip = tag.id;
        if (clips[tag.id] case final clip?) {
          if (sleepTimer.section != null &&
              sleepTimer.section == currentSection &&
              currentSection != clip.section) {
            sleepTimer.reachedSectionEnd(currentSection!);
            if (_stopped) {
              _wake();
              return;
            }
          }
          currentSection = clip.section;
          currentUtterance = clip.utterance;
          _currentSectionLength = clip.sectionLength;
          passage = clip.text;
          speaker = clip.speaker;
          showSection(clip.section);
          onProgress?.call(clip.section, clip.utterance, clip.speech);
          if (!_closed) notifyListeners();
        }
      }
      _wake();
    });
    final errors = _player.errorStream.listen((error) {
      _playError = error;
      _wake();
    });
    final selected = _session!.settings;
    final phonon = selected.engine == VoiceEngine.phonon;
    final pocket = selected.engine == VoiceEngine.pocket;
    final supertonic = selected.engine == VoiceEngine.supertonic;
    final systemVoice = selected.engine == VoiceEngine.system;
    final lfm3Narration =
        selected.lfm3Narration && !phonon && !pocket && !supertonic;
    final queueLimit = selected.batterySaver ? 2 : prefetch;
    final end = continueToEnd ? length : (index + 1).clamp(0, length);
    try {
      if (configureAudioSession case final configure?) {
        await configure();
      } else {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.speech());
      }
      await _player.setVolume(selected.volume);
      await _player.setSpeed(
        phonon || pocket || supertonic || lfm3Narration ? selected.speed : 1,
      );
      if (pocket && synthesizeClip == null && !await PocketTts.isInstalled()) {
        throw const SpeechFailure('Download the Pocket TTS model in Settings.');
      }
      if (supertonic &&
          synthesizeClip == null &&
          !await SupertonicModel.isInstalled()) {
        throw const SpeechFailure(
          'Download the Supertonic 3 model in Settings.',
        );
      }
      if (phonon && !await PhononModel.isInstalled()) {
        throw const SpeechFailure(
          'Download the experimental Phonon model in Settings.',
        );
      }
      if (lfm3Narration && !await Lfm3AudioModel.isInstalled()) {
        throw const SpeechFailure(
          'Download the LFM3-Audio narration model in Settings.',
        );
      }
      if (systemVoice && (selected.systemVoice ?? '').isEmpty) {
        throw const SpeechFailure('Choose an iPhone voice in Settings.');
      }
      var clipNumber = 0;
      for (var section = index; section < end && !_stopped; section++) {
        if (sleepTimer.section != null && section > sleepTimer.section!) break;
        final utterances = await loadSpeech(section);
        if (_stopped) break;
        if (utterances.isEmpty) continue;
        final firstUtterance = section == index
            ? _resumeIndex(utterances, startUtterance, resumePassage)
            : 0;
        if (firstUtterance >= utterances.length) continue;
        if (audio == null) {
          final cache = await (await getTemporaryDirectory()).create(
            recursive: true,
          );
          audio = await cache.createTemp('relay-narration-');
        }

        for (
          var utteranceIndex = firstUtterance;
          utteranceIndex < utterances.length && !_stopped;
          utteranceIndex++
        ) {
          if (sleepTimer.section != null && section > sleepTimer.section!) {
            break;
          }
          final speech = utterances[utteranceIndex];
          final text = speech.text.trim();
          if (text.isEmpty) continue;
          // Keep the current clip and several upcoming clips in the player so
          // the queue survives backgrounded generation and chapter changes.
          if (!await _waitFor(
            () =>
                _player.processingState == ProcessingState.completed ||
                _player.audioSources.length - (_player.currentIndex ?? 0) <
                    queueLimit,
          )) {
            break;
          }
          if (_started && !await _waitWhilePaused()) break;
          final played = _player.currentIndex ?? 0;
          if (played > 0) {
            final finished = _player.audioSources
                .take(played)
                .map(
                  (source) =>
                      ((source as IndexedAudioSource).tag as MediaItem).id,
                )
                .toList();
            await _player.removeAudioSourceRange(0, played);
            for (final path in finished) {
              clips.remove(path);
              await File(path).delete();
            }
          }

          final useLfm3 =
              lfm3Narration &&
              (!speech.isDialogue ||
                  !selected.characterVoices ||
                  speech.speaker == null);
          final speechSettings = selected.withChanges(
            voice: speech.kokoroVoice,
            systemVoice: speech.systemVoice,
            speed: lfm3Narration || pocket || supertonic ? 1 : selected.speed,
          );
          final extension = systemVoice && !useLfm3 ? 'caf' : 'wav';
          final clip = '${audio.path}/${clipNumber++}.$extension';
          final bookId = _session!.bookId;
          final identity = <String, Object?>{
            'version': 1,
            'runtime': 'mediapipe-0.2.1:llamadart-0.19.3',
            'engine': useLfm3 ? 'lfm3-audio' : selected.engine.name,
            'text': prepareSpeech(text, selected.punctuation),
            'voice': speechSettings.voice,
            'systemVoice': speechSettings.systemVoice,
            'phononVoice': selected.phononVoice,
            'lfm3Voice': selected.lfm3Voice,
            'speed': speechSettings.speed,
            'pauses': selected.pauses,
            'pitch': selected.pitch,
            if (systemVoice) 'volume': selected.volume,
            'batterySaver': selected.batterySaver,
            'os': Platform.operatingSystemVersion,
            if (phonon) 'phononRevision': await PhononModel.cacheRevision(),
            if (pocket) ...{
              'pocketVoice': selected.pocketVoice,
              'pocketRevision': PocketTts.revision,
            },
            if (supertonic) ...{
              'supertonicVoice': selected.supertonicVoice,
              'supertonicLanguage': selected.supertonicLanguage,
              'supertonicRevision': SupertonicModel.revision,
            },
          };
          final key = AudioClipCache.clipKey(identity);
          final cached =
              bookId != null && await _cache.copyTo(bookId, key, clip);
          if (_stopped) break;
          if (!cached) {
            if (synthesizeClip case final synthesize?) {
              await synthesize(speech, speechSettings, clip);
            } else {
              if (useLfm3) {
                try {
                  await Lfm3Audio.synthesizeToFile(
                    text: prepareSpeech(text, selected.punctuation),
                    voice: selected.lfm3Voice,
                    path: clip,
                  );
                } on Lfm3AudioException catch (error) {
                  throw SpeechFailure(error.message);
                }
              } else if (supertonic) {
                try {
                  await SupertonicNarration.synthesizeToFile(
                    text: prepareSpeech(text, selected.punctuation),
                    path: clip,
                    voice: selected.supertonicVoice,
                    language: selected.supertonicLanguage,
                    pauses: selected.pauses,
                  );
                } catch (error) {
                  throw SpeechFailure(
                    'Supertonic 3 could not narrate this passage: $error',
                  );
                }
              } else if (pocket) {
                try {
                  await PocketTts.synthesizeToFile(
                    text: prepareSpeech(text, selected.punctuation),
                    path: clip,
                    voice: selected.pocketVoice,
                    pauses: selected.pauses,
                  );
                } catch (error) {
                  throw SpeechFailure(
                    'Pocket TTS could not narrate this passage: $error',
                  );
                }
              } else if (phonon) {
                try {
                  await PhononNarration.synthesizeToFile(
                    text: prepareSpeech(text, selected.punctuation),
                    path: clip,
                    voice: selected.phononVoice,
                  );
                } on PhononException catch (error) {
                  throw SpeechFailure(error.message);
                }
              } else if (systemVoice) {
                final success = await SystemVoices.synthesize(
                  text: prepareSpeech(text, selected.punctuation),
                  path: clip,
                  settings: speechSettings,
                );
                if (!success) {
                  throw const SpeechFailure(
                    'This iPhone voice could not speak the passage. '
                    'Choose another voice, or switch back to Kokoro.',
                  );
                }
              } else {
                final worker = await _KokoroPool.acquire(
                  speaker: selected.voice,
                  batterySaver: selected.batterySaver,
                );
                await worker.generate(text, speechSettings, clip);
              }
            }
            if (!_stopped && bookId != null) {
              await _cache.put(bookId, key, clip, valid: () => !_stopped);
            }
          }
          if (_stopped) break;
          final utterance = _ClipInfo(
            section: section,
            sectionLength: utterances.length,
            utterance: utteranceIndex,
            text: speech.text,
            speaker: speech.speaker,
            speech: speech,
          );
          clips[clip] = utterance;
          final source = AudioSource.file(
            clip,
            tag: MediaItem(
              id: clip,
              title: title,
              album: speech.speaker == null
                  ? '$sectionName ${section + 1}'
                  : '${speech.speaker} · $sectionName ${section + 1}',
            ),
          );
          if (_player.audioSources.isEmpty) {
            await _player.setAudioSources([source]);
          } else {
            final ended = _player.processingState == ProcessingState.completed;
            await _player.addAudioSource(source);
            final last = _player.audioSources.length - 1;
            if ((ended ||
                    _player.processingState == ProcessingState.completed) &&
                (_player.currentIndex ?? 0) < last) {
              await _player.seek(Duration.zero, index: last);
            }
          }
          // Start as soon as the first clip exists. This keeps the audio
          // session alive when the phone is locked during a long generation.
          if (!_started) _begin();
        }
      }

      if (!_stopped && _player.audioSources.isEmpty) {
        throw SpeechFailure(
          continueToEnd
              ? 'There is no readable text from here to the end of the book.'
              : 'There is no readable text in this section.',
        );
      }
      if (!_stopped && !_started) _begin();
      await _waitFor(
        () => _player.processingState == ProcessingState.completed,
      );
      if (!_stopped && currentSection != null) {
        sleepTimer.reachedSectionEnd(currentSection!);
      }
    } catch (failure, stack) {
      if (!_stopped) {
        if (kDebugMode) debugPrint('Narration failed: $failure\n$stack');
        error = failure is SpeechFailure
            ? failure.message
            : 'Read aloud stopped. Try playing this section again.';
      }
    } finally {
      await playback.cancel();
      await sequence.cancel();
      await errors.cancel();
      if (!navigating) sleepTimer.cancel();
      _KokoroPool.release(
        after: selected.batterySaver
            ? const Duration(seconds: 30)
            : const Duration(seconds: 90),
      );
      if (phonon) {
        PhononNarration.release(
          after: selected.batterySaver
              ? const Duration(seconds: 30)
              : const Duration(seconds: 90),
        );
      }
      if (pocket) {
        pocketSpeech.release(
          after: selected.batterySaver
              ? const Duration(seconds: 30)
              : const Duration(seconds: 90),
        );
      }
      if (supertonic) {
        SupertonicNarration.release(
          after: selected.batterySaver
              ? const Duration(seconds: 30)
              : const Duration(seconds: 90),
        );
      }
      try {
        await _player.stop();
        await _player.clearAudioSources();
      } finally {
        try {
          await audio?.delete(recursive: true);
        } finally {
          _run = null;
          passage = null;
          speaker = null;
          _setState(SpeechState.idle);
        }
      }
    }
  }

  int _resumeIndex(
    List<SpeechUtterance> utterances,
    int requested,
    String? passage,
  ) {
    final start = requested.clamp(0, utterances.length);
    final needle = (passage ?? '').trim().toLowerCase();
    if (needle.isEmpty) return start;
    final prefix = needle.substring(0, needle.length.clamp(0, 64));
    bool matches(int index) {
      final text = utterances[index].text.trim().toLowerCase();
      return text.isNotEmpty &&
          (text.startsWith(prefix) || prefix.startsWith(text));
    }

    if (start < utterances.length && matches(start)) return start;
    for (var i = 0; i < utterances.length; i++) {
      if (matches(i)) return i;
    }
    if (prefix.length >= 12) {
      for (var i = 0; i < utterances.length; i++) {
        if (utterances[i].text.toLowerCase().contains(prefix)) return i;
      }
    }
    return start;
  }

  /// Plays a short sample with [settings], without starting a full narration.
  Future<void> preview(VoiceSettings settings) async {
    if (_closed || active || navigating) {
      throw const SpeechFailure('Stop Read aloud before previewing a voice.');
    }
    await stopPreview();
    final token = ++_previewToken;
    const text =
        'In the morning the garden was quiet, and the whole house seemed to '
        'be listening.';
    _previewing = true;
    notifyListeners();
    Directory? audio;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      if (settings.lfm3Narration &&
          settings.engine != VoiceEngine.pocket &&
          settings.engine != VoiceEngine.supertonic) {
        if (!await Lfm3AudioModel.isInstalled()) {
          throw const SpeechFailure(
            'Download the LFM3-Audio narration model first.',
          );
        }
        audio = await (await getTemporaryDirectory()).createTemp(
          'relay-voice-preview-',
        );
        final path = '${audio.path}/preview.wav';
        try {
          await Lfm3Audio.synthesizeToFile(
            text: text,
            voice: settings.lfm3Voice,
            path: path,
          );
        } on Lfm3AudioException catch (error) {
          throw SpeechFailure(error.message);
        }
        if (token != _previewToken) return;
        await _previewPlayer.setAudioSource(
          AudioSource.file(
            path,
            tag: MediaItem(id: path, title: 'Voice preview'),
          ),
        );
        await _previewPlayer.setVolume(settings.volume);
        await _previewPlayer.setSpeed(settings.speed);
        await _previewPlayer.play();
        return;
      }
      if (settings.engine == VoiceEngine.supertonic) {
        if (!await SupertonicModel.isInstalled()) {
          throw const SpeechFailure('Download the Supertonic 3 model first.');
        }
        audio = await (await getTemporaryDirectory()).createTemp(
          'relay-voice-preview-',
        );
        final path = '${audio.path}/preview.wav';
        await SupertonicNarration.synthesizeToFile(
          text: text,
          path: path,
          voice: settings.supertonicVoice,
          language: settings.supertonicLanguage,
          pauses: settings.pauses,
        );
        if (token != _previewToken) return;
        await _previewPlayer.setAudioSource(
          AudioSource.file(
            path,
            tag: MediaItem(id: path, title: 'Voice preview'),
          ),
        );
        await _previewPlayer.setVolume(settings.volume);
        await _previewPlayer.setSpeed(settings.speed);
        await _previewPlayer.play();
        return;
      }
      if (settings.engine == VoiceEngine.pocket) {
        if (!await PocketTts.isInstalled()) {
          throw const SpeechFailure('Download the Pocket TTS model first.');
        }
        audio = await (await getTemporaryDirectory()).createTemp(
          'relay-voice-preview-',
        );
        final path = '${audio.path}/preview.wav';
        try {
          await PocketTts.synthesizeToFile(
            text: text,
            path: path,
            voice: settings.pocketVoice,
            pauses: settings.pauses,
          );
        } catch (error) {
          throw SpeechFailure(
            'Pocket TTS could not preview this voice: $error',
          );
        }
        if (token != _previewToken) return;
        await _previewPlayer.setAudioSource(
          AudioSource.file(
            path,
            tag: MediaItem(id: path, title: 'Voice preview'),
          ),
        );
        await _previewPlayer.setVolume(settings.volume);
        await _previewPlayer.setSpeed(settings.speed);
        await _previewPlayer.play();
        return;
      }
      if (settings.engine == VoiceEngine.phonon) {
        if (!await PhononModel.isInstalled()) {
          throw const SpeechFailure(
            'Download the experimental Phonon model first.',
          );
        }
        audio = await (await getTemporaryDirectory()).createTemp(
          'relay-voice-preview-',
        );
        final path = '${audio.path}/preview.wav';
        try {
          await PhononNarration.synthesizeToFile(
            text: text,
            path: path,
            voice: settings.phononVoice,
          );
        } on PhononException catch (error) {
          throw SpeechFailure(error.message);
        }
        if (token != _previewToken) return;
        await _previewPlayer.setAudioSource(
          AudioSource.file(
            path,
            tag: MediaItem(id: path, title: 'Voice preview'),
          ),
        );
        await _previewPlayer.setVolume(settings.volume);
        await _previewPlayer.setSpeed(settings.speed);
        await _previewPlayer.play();
        PhononNarration.release(after: const Duration(seconds: 90));
        return;
      }
      if (settings.engine == VoiceEngine.system) {
        await SystemVoices.preview(text: text, settings: settings);
        return;
      }
      audio = await (await getTemporaryDirectory()).createTemp(
        'relay-voice-preview-',
      );
      final path = '${audio.path}/preview.wav';
      final worker = await _KokoroPool.acquire(
        speaker: settings.voice,
        batterySaver: settings.batterySaver,
      );
      await worker.generate(text, settings, path);
      if (token != _previewToken) return;
      await _previewPlayer.setAudioSource(
        AudioSource.file(
          path,
          tag: MediaItem(id: path, title: 'Voice preview'),
        ),
      );
      await _previewPlayer.setVolume(settings.volume);
      await _previewPlayer.setSpeed(1);
      await _previewPlayer.play();
    } finally {
      try {
        await _previewPlayer.stop();
      } catch (_) {
        // The reader may have disposed while the preview was preparing.
      }
      try {
        await _previewPlayer.clearAudioSources();
      } catch (_) {
        // Nothing to clear after dispose.
      }
      _KokoroPool.release(after: const Duration(seconds: 60));
      if (settings.engine == VoiceEngine.pocket) pocketSpeech.release();
      if (settings.engine == VoiceEngine.supertonic) {
        SupertonicNarration.release();
      }
      try {
        await audio?.delete(recursive: true);
      } catch (_) {
        // Temporary files are cleaned up by the OS if this fails.
      }
      if (token == _previewToken) {
        _previewing = false;
        if (!_closed) notifyListeners();
      }
    }
  }

  Future<void> stopPreview() async {
    _previewToken++;
    if (_previewing) {
      Lfm3Audio.cancel();
      kokoroSpeech.cancel();
      phononSpeech.cancel();
      pocketSpeech.cancel();
      SupertonicNarration.cancel();
      _previewing = false;
      if (!_closed) notifyListeners();
    }
    try {
      await _previewPlayer.stop();
    } catch (_) {
      // The preview player may already be disposed.
    }
    await SystemVoices.stopPreview();
  }

  void _begin() {
    if (_stopped) return;
    _started = true;
    if (!_paused) _play();
  }

  void _play() {
    unawaited(
      _player.play().catchError((Object error) {
        _playError = error;
        _wake();
      }),
    );
  }

  void _wake() {
    final changed = _changed;
    _changed = null;
    changed?.complete();
  }

  Future<bool> _waitFor(bool Function() ready) async {
    while (!_stopped && _playError == null && !ready()) {
      await (_changed ??= Completer<void>()).future;
    }
    final error = _playError;
    if (!_stopped && error != null) throw error;
    return !_stopped;
  }

  /// Stops generating more clips while playback is paused, so a paused book
  /// does not keep a CPU core busy in the background.
  Future<bool> _waitWhilePaused() async {
    while (!_stopped && _paused && _playError == null) {
      await (_changed ??= Completer<void>()).future;
    }
    final error = _playError;
    if (!_stopped && error != null) throw error;
    return !_stopped;
  }

  Future<void> pause() async {
    if (!active || _paused || _stopped) return;
    _paused = true;
    _setState(SpeechState.paused);
    await _player.pause();
    _KokoroPool.release(after: const Duration(minutes: 2));
  }

  void resume() {
    if (!_paused || _stopped) return;
    _paused = false;
    _setState(_started ? SpeechState.playing : SpeechState.preparing);
    _wake();
    if (_started) _play();
  }

  Future<void> stop() async {
    _settingsTimer?.cancel();
    _navigationToken++;
    navigating = false;
    sleepTimer.cancel();
    final preparation = _preparation;
    if (preparation != null) SupertonicNarration.cancel();
    await _stopRun();
    if (preparation != null) {
      await preparation.catchError((Object _) {});
    }
  }

  Future<void> _stopRun() async {
    final run = _run;
    if (run == null) return;
    _stopped = true;
    Lfm3Audio.cancel();
    kokoroSpeech.cancel();
    phononSpeech.cancel();
    pocketSpeech.cancel();
    SupertonicNarration.cancel();
    _wake();
    await _player.pause();
    await run;
  }

  Future<void> setVolume(double volume) => _player.setVolume(volume);

  /// Prepare only the chosen narrator after a book is visible. No audio is
  /// generated and preparation never changes playback/checkpoint/timer state.
  Future<void> prepareSelectedVoice() {
    if (_closed ||
        active ||
        navigating ||
        _previewing ||
        settings.engine != VoiceEngine.supertonic ||
        synthesizeClip != null && prepareClipEngine == null) {
      return Future.value();
    }
    return _preparation ??=
        Future.sync(prepareClipEngine ?? SupertonicNarration.ensureLoaded)
            .whenComplete(() {
              _preparation = null;
              SupertonicNarration.release(
                after: settings.batterySaver
                    ? const Duration(seconds: 30)
                    : const Duration(seconds: 90),
              );
            });
  }

  void _setState(SpeechState next) {
    if (_closed || state == next) return;
    state = next;
    notifyListeners();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await stopPreview();
    await stop();
    await _KokoroPool.unload();
    await pocketSpeech.unload();
    await SupertonicNarration.unload();
    await _previewPlayer.dispose();
    await _player.dispose();
    sleepTimer.dispose();
    super.dispose();
  }
}

/// Shared MediaPipe task, kept warm across utterances and voice switches.
abstract final class _KokoroPool {
  static Future<_VoiceWorker> acquire({
    required int speaker,
    required bool batterySaver,
  }) async => _VoiceWorker(batterySaver);
  static void release({Duration after = const Duration(seconds: 60)}) =>
      kokoroSpeech.release(after: after);
  static Future<void> unload() => kokoroSpeech.unload();
}

class _ClipInfo {
  const _ClipInfo({
    required this.section,
    required this.sectionLength,
    required this.utterance,
    required this.text,
    required this.speaker,
    required this.speech,
  });

  final int section;
  final int sectionLength;
  final int utterance;
  final String text;
  final String? speaker;
  final SpeechUtterance speech;
}

class _VoiceWorker {
  _VoiceWorker(this.batterySaver);
  final bool batterySaver;

  Future<void> generate(String text, VoiceSettings settings, String wav) async {
    try {
      await kokoroSpeech.synthesizeToFile(
        text: prepareSpeech(text, settings.punctuation),
        voice: kokoroVoiceIds[settings.voice],
        path: wav,
        speed: settings.speed,
        pauses: settings.pauses,
        batterySaver: batterySaver,
      );
    } catch (error) {
      throw SpeechFailure('Kokoro could not narrate this passage: $error');
    }
  }
}
