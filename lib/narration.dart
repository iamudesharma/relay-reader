import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'lfm3_audio.dart';
import 'phonon.dart';

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
  phonon('Phonon', 'Experimental · on-device English');

  const VoiceEngine(this.label, this.description);
  final String label;
  final String description;
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
  });

  final VoiceEngine engine;
  final int voice;
  final String? systemVoice;
  final String phononVoice;
  final double speed;
  final double pauses;
  final double pitch;
  final double volume;
  final Punctuation punctuation;
  final bool characterVoices;

  /// Uses fewer CPU threads and generates less audio ahead. Intended for
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

Iterable<String> speechChunks(String text) sync* {
  // Paragraph boundaries are the most natural place to join two audio clips.
  for (final paragraph
      in text.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'))) {
    final normalized = paragraph.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) continue;
    final runes = normalized.runes.toList();
    for (var start = 0; start < runes.length;) {
      var end = (start + speechChunkLimit).clamp(0, runes.length);
      if (end < runes.length) {
        var lastSpace = -1;
        var lastClause = -1;
        var lastSentence = -1;
        for (var i = start + speechChunkLimit ~/ 2; i < end; i++) {
          if (runes[i] != 32) continue;
          lastSpace = i;
          final previous = runes[i - 1];
          if ('.!?…'.codeUnits.contains(previous)) {
            lastSentence = i;
          } else if (',;:—–'.codeUnits.contains(previous)) {
            lastClause = i;
          }
        }
        if (lastSentence > start) {
          end = lastSentence + 1;
        } else if (lastClause > start) {
          end = lastClause + 1;
        } else if (lastSpace > start) {
          end = lastSpace;
        }
      }
      final part = String.fromCharCodes(runes, start, end).trim();
      if (part.isNotEmpty) yield part;
      start = end;
    }
  }
}

class SpeechFailure implements Exception {
  const SpeechFailure(this.message);
  final String message;
}

enum SpeechState { idle, preparing, playing, paused }

class Narrator extends ChangeNotifier {
  Narrator({this.prefetch = 4});

  /// How many generated clips stay queued ahead of playback.
  final int prefetch;

  final _player = AudioPlayer();
  final _previewPlayer = AudioPlayer();
  Future<void>? _run;
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
    if (_closed || active) return;
    _stopped = false;
    _paused = false;
    _started = false;
    _playError = null;
    error = null;
    speaker = null;
    state = SpeechState.preparing;
    _run = _read(
      title,
      sectionName,
      index,
      length,
      loadSpeech,
      showSection,
      continueToEnd,
      startUtterance,
      resumePassage,
      onProgress,
    );
    notifyListeners();
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
    final selected = settings;
    final phonon = selected.engine == VoiceEngine.phonon;
    final systemVoice = selected.engine == VoiceEngine.system;
    final lfm3Narration = selected.lfm3Narration && !phonon;
    final queueLimit = selected.batterySaver ? 2 : prefetch;
    final end = continueToEnd ? length : (index + 1).clamp(0, length);
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      await _player.setVolume(selected.volume);
      await _player.setSpeed(phonon || lfm3Narration ? selected.speed : 1);
      if (phonon && !await PhononModel.isInstalled()) {
        throw const SpeechFailure(
          'Download the experimental Phonon model in Read aloud settings.',
        );
      }
      if (lfm3Narration && !await Lfm3AudioModel.isInstalled()) {
        throw const SpeechFailure(
          'Download the LFM3-Audio narration model in Read aloud settings.',
        );
      }
      if (systemVoice && (selected.systemVoice ?? '').isEmpty) {
        throw const SpeechFailure(
          'Choose an iPhone voice in Read aloud settings.',
        );
      }
      var clipNumber = 0;
      for (var section = index; section < end && !_stopped; section++) {
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
          final speech = utterances[utteranceIndex];
          final text = speech.text.trim();
          if (text.isEmpty) continue;
          // Keep the current clip and several upcoming clips in the player so
          // the queue survives backgrounded generation and chapter changes.
          if (!await _waitFor(
            () =>
                _player.audioSources.length - (_player.currentIndex ?? 0) <
                queueLimit,
          )) {
            break;
          }
          if (!await _waitWhilePaused()) break;
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
            speed: lfm3Narration ? 1 : selected.speed,
          );
          final extension = systemVoice && !useLfm3 ? 'caf' : 'wav';
          final clip = '${audio.path}/${clipNumber++}.$extension';
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
          if (_stopped) break;
          final utterance = _ClipInfo(
            section: section,
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
    for (var i = 0; i < utterances.length; i++) {
      final text = utterances[i].text.trim().toLowerCase();
      if (text.startsWith(prefix)) return i;
      if (text.length > 24 && prefix.startsWith(text)) return i;
    }
    return start;
  }

  /// Plays a short sample with [settings], without starting a full narration.
  Future<void> preview(VoiceSettings settings) async {
    if (_closed || active) {
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
      if (settings.lfm3Narration) {
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
    Lfm3Audio.cancel();
    if (_previewing) {
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
    final run = _run;
    if (run == null) return;
    _stopped = true;
    Lfm3Audio.cancel();
    _wake();
    await _player.pause();
    await run;
  }

  Future<void> setVolume(double volume) => _player.setVolume(volume);

  void _setState(SpeechState next) {
    if (_closed || state == next) return;
    state = next;
    notifyListeners();
  }

  Future<void> close() async {
    _closed = true;
    await stopPreview();
    await stop();
    await _KokoroPool.unload();
    await _previewPlayer.dispose();
    await _player.dispose();
    super.dispose();
  }
}

const modelFiles = [
  'model.int8.onnx',
  'voices.bin',
  'tokens.txt',
  'lexicon-us-en.txt',
  'lexicon-gb-en.txt',
];

Future<String> _modelDirectory() async {
  final assets = await AssetManifest.loadFromAssetBundle(rootBundle);
  if (!modelFiles.every(
    (name) => assets.listAssets().contains('assets/kokoro-v1/$name'),
  )) {
    throw const SpeechFailure(
      'Kokoro voice files are missing. Run scripts/prepare-reader-voice.sh and rebuild Relay Reader.',
    );
  }

  final root = await getApplicationSupportDirectory();
  final directory = await Directory('${root.path}/kokoro-int8-v1')
      .create(recursive: true);
  for (final name in modelFiles) {
    final file = File('${directory.path}/$name');
    if (await file.exists() && await file.length() > 0) continue;
    final data = await rootBundle.load('assets/kokoro-v1/$name');
    final temporary = await File('${file.path}.partial').writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await temporary.rename(file.path);
  }
  return directory.path;
}

/// Keeps the Kokoro model warm between clips and playback sessions, then
/// releases it after an idle period. Reloading the model for every start was
/// both slow and battery-hungry, while keeping it forever wastes memory.
abstract final class _KokoroPool {
  static _VoiceWorker? _worker;
  static String? _model;
  static String? _dialect;
  static int? _threads;
  static Timer? _idle;
  static Future<void>? _closing;
  static Future<String>? _modelFuture;

  static Future<String> modelDirectory() async {
    final cached = _modelFuture;
    if (cached != null) return cached;
    final future = _modelDirectory();
    _modelFuture = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_modelFuture, future)) _modelFuture = null;
      rethrow;
    }
  }

  static int _threadCount(bool batterySaver) {
    final maximum = batterySaver ? 2 : 3;
    return Platform.numberOfProcessors.clamp(1, maximum);
  }

  static Future<_VoiceWorker> acquire({
    required int speaker,
    required bool batterySaver,
  }) async {
    final closing = _closing;
    if (closing != null) await closing;
    final model = await modelDirectory();
    final dialect = speaker >= 20 ? 'gb' : 'us';
    final threads = _threadCount(batterySaver);
    _idle?.cancel();
    _idle = null;
    final current = _worker;
    if (current != null &&
        !current.exited &&
        _model == model &&
        _dialect == dialect &&
        _threads == threads) {
      return current;
    }
    await _closeNow();
    final worker = await _VoiceWorker.start(model, speaker, threads: threads);
    _worker = worker;
    _model = model;
    _dialect = dialect;
    _threads = threads;
    return worker;
  }

  static void release({Duration after = const Duration(seconds: 60)}) {
    _idle?.cancel();
    _idle = Timer(after, () => unawaited(_closeNow()));
  }

  static Future<void> unload() async {
    _idle?.cancel();
    _idle = null;
    await _closeNow();
  }

  static Future<void> _closeNow() async {
    final worker = _worker;
    if (worker == null) return;
    _worker = null;
    _model = null;
    _dialect = null;
    _threads = null;
    final future = worker.close();
    _closing = future;
    try {
      await future;
    } catch (_) {
      // A worker that already died cannot be closed; the next worker replaces it.
    } finally {
      if (identical(_closing, future)) _closing = null;
    }
  }
}

class _ClipInfo {
  const _ClipInfo({
    required this.section,
    required this.utterance,
    required this.text,
    required this.speaker,
    required this.speech,
  });

  final int section;
  final int utterance;
  final String text;
  final String? speaker;
  final SpeechUtterance speech;
}

typedef _VoiceRequest = (String text, VoiceSettings settings, String wav);

class _VoiceWorker {
  _VoiceWorker(this._commands, this._replies);

  final SendPort _commands;
  final StreamIterator<dynamic> _replies;
  bool _exited = false;

  bool get exited => _exited;

  static Future<_VoiceWorker> start(
    String model,
    int speaker, {
    required int threads,
  }) async {
    final events = ReceivePort();
    final replies = StreamIterator(events);
    try {
      await Isolate.spawn(
        _speak,
        (model, speaker >= 20 ? 'gb' : 'us', threads, events.sendPort),
        onError: events.sendPort,
        onExit: events.sendPort,
      );
      if (await replies.moveNext() && replies.current is SendPort) {
        return _VoiceWorker(replies.current as SendPort, replies);
      }
      if (kDebugMode && replies.current is List<Object?>) {
        final details = replies.current as List<Object?>;
        debugPrint(
          'Kokoro worker initialization failed: ${details.join('\n')}',
        );
      }
      throw const SpeechFailure('Kokoro could not start on this device.');
    } catch (_) {
      await replies.cancel();
      rethrow;
    }
  }

  Future<void> generate(String text, VoiceSettings settings, String wav) async {
    _commands.send((prepareSpeech(text, settings.punctuation), settings, wav));
    _exited = !await _replies.moveNext() || _replies.current == null;
    if (_exited || _replies.current != true) {
      throw const SpeechFailure(
        'Kokoro could not narrate this passage. The bundled voices are English.',
      );
    }
  }

  Future<void> close() async {
    final wasExited = _exited;
    _exited = true;
    try {
      if (!wasExited) {
        _commands.send(null);
        await _replies.moveNext();
      }
    } finally {
      await _replies.cancel();
    }
  }
}

Future<void> _speak((String, String, int, SendPort) args) async {
  final (model, dialect, threads, reply) = args;
  sherpa.initBindings();
  final tts = sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        numThreads: threads,
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: '$model/model.int8.onnx',
          voices: '$model/voices.bin',
          tokens: '$model/tokens.txt',
          lexicon: '$model/lexicon-$dialect-en.txt',
        ),
      ),
    ),
  );
  final commands = ReceivePort();
  try {
    if (tts.numSpeakers < 28) {
      throw StateError('Unexpected Kokoro speaker count');
    }
    reply.send(commands.sendPort);
    await for (final command in commands) {
      if (command == null) break;
      final (text, settings, path) = command as _VoiceRequest;
      try {
        final audio = tts.generateWithConfig(
          text: text,
          config: sherpa.OfflineTtsGenerationConfig(
            sid: settings.voice,
            speed: settings.speed,
            silenceScale: settings.pauses,
            extra: const {'max_words_in_sentence': 36},
          ),
        );
        final success =
            audio.samples.isNotEmpty &&
            sherpa.writeWave(
              filename: path,
              samples: audio.samples,
              sampleRate: audio.sampleRate,
            );
        reply.send(success);
      } catch (error, stack) {
        if (kDebugMode) debugPrint('Kokoro synthesis failed: $error\n$stack');
        reply.send(false);
      }
    }
  } finally {
    commands.close();
    tts.free();
  }
}
