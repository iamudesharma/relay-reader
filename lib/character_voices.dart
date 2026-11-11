import 'dart:convert';

import 'narration.dart';

/// A voice assigned to a character for each narration engine.
class CastVoice {
  const CastVoice({this.kokoro, this.system});

  factory CastVoice.fromJson(Object? value) {
    if (value is! Map) return const CastVoice();
    return CastVoice(
      kokoro: (value['kokoro'] as num?)?.toInt(),
      system: value['system'] as String?,
    );
  }

  final int? kokoro;
  final String? system;

  CastVoice withKokoro(int? voice) => CastVoice(kokoro: voice, system: system);
  CastVoice withSystem(String? voice) =>
      CastVoice(kokoro: kokoro, system: voice);

  Map<String, Object?> toJson() => {
    if (kokoro != null) 'kokoro': kokoro,
    if (system != null) 'system': system,
  };
}

/// One dialogue line in a section, with the speaker chosen for it. Paragraph
/// and quote indexes are stable across font changes; the text is kept so a
/// saved override can be discarded if the book changes.
class DialogueAttribution {
  const DialogueAttribution({
    required this.paragraph,
    required this.quote,
    required this.text,
    required this.speaker,
    this.manual = false,
    this.source = 'rules',
  });

  factory DialogueAttribution.fromJson(Object? value) {
    if (value is! Map) {
      return const DialogueAttribution(
        paragraph: 0,
        quote: 0,
        text: '',
        speaker: 'Unknown',
      );
    }
    return DialogueAttribution(
      paragraph: (value['paragraph'] as num?)?.toInt() ?? 0,
      quote: (value['quote'] as num?)?.toInt() ?? 0,
      text: value['text'] as String? ?? '',
      speaker: value['speaker'] as String? ?? 'Unknown',
      manual: value['manual'] as bool? ?? false,
      source: value['source'] as String? ?? 'rules',
    );
  }

  final int paragraph;
  final int quote;
  final String text;
  final String speaker;
  final bool manual;
  final String source;

  String get key => '$paragraph:$quote';

  DialogueAttribution copyWith({
    String? text,
    String? speaker,
    bool? manual,
    String? source,
  }) => DialogueAttribution(
    paragraph: paragraph,
    quote: quote,
    text: text ?? this.text,
    speaker: speaker ?? this.speaker,
    manual: manual ?? this.manual,
    source: source ?? this.source,
  );

  Map<String, Object?> toJson() => {
    'paragraph': paragraph,
    'quote': quote,
    'text': text,
    'speaker': speaker,
    'manual': manual,
    'source': source,
  };
}

/// Cached speaker decisions for one section. [hash] is the hash of the text
/// that produced the decisions, so changing the book invalidates old results.
class SectionAttribution {
  const SectionAttribution({required this.hash, this.entries = const []});

  factory SectionAttribution.fromJson(Object? value) {
    if (value is! Map) return const SectionAttribution(hash: '');
    final raw = value['entries'];
    return SectionAttribution(
      hash: value['hash'] as String? ?? '',
      entries: [
        if (raw is List)
          for (final entry in raw) DialogueAttribution.fromJson(entry),
      ],
    );
  }

  final String hash;
  final List<DialogueAttribution> entries;

  DialogueAttribution? forLine(int paragraph, int quote, String text) {
    for (final entry in entries) {
      if (entry.paragraph == paragraph &&
          entry.quote == quote &&
          entry.text == text) {
        return entry;
      }
    }
    return null;
  }

  SectionAttribution withEntry(DialogueAttribution entry) {
    final next = [
      for (final old in entries)
        if (old.paragraph != entry.paragraph || old.quote != entry.quote) old,
      entry,
    ];
    next.sort((a, b) {
      final paragraph = a.paragraph.compareTo(b.paragraph);
      return paragraph != 0 ? paragraph : a.quote.compareTo(b.quote);
    });
    return SectionAttribution(hash: hash, entries: next);
  }

  SectionAttribution withEntries(Iterable<DialogueAttribution> values) {
    var result = this;
    for (final entry in values) {
      result = result.withEntry(entry);
    }
    return result;
  }

  SectionAttribution keepManualOnly() => SectionAttribution(
    hash: hash,
    entries: [
      for (final entry in entries)
        if (entry.manual) entry,
    ],
  );

  Map<String, Object?> toJson() => {
    'hash': hash,
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

String textHash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Per-book character-to-voice mapping. Auto-discovery adds entries as the
/// user listens; every entry can be overridden in the cast editor. The lead
/// character's voice is reserved and can never be taken by another character.
class CharacterCast {
  const CharacterCast({
    this.voices = const {},
    this.lead,
    this.aliases = const {},
  });

  factory CharacterCast.fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return const CharacterCast();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const CharacterCast();
      final voices = <String, CastVoice>{};
      final entries = decoded['voices'];
      if (entries is Map) {
        for (final entry in entries.entries) {
          if (entry.key is! String) continue;
          voices[entry.key as String] = CastVoice.fromJson(entry.value);
        }
      }
      final aliases = <String, String>{};
      final rawAliases = decoded['aliases'];
      if (rawAliases is Map) {
        for (final entry in rawAliases.entries) {
          if (entry.key is String && entry.value is String) {
            aliases[entry.key as String] = entry.value as String;
          }
        }
      }
      final lead = decoded['lead'];
      return CharacterCast(
        voices: Map.unmodifiable(voices),
        lead: lead is String && lead.isNotEmpty ? lead : null,
        aliases: Map.unmodifiable(aliases),
      );
    } catch (_) {
      return const CharacterCast();
    }
  }

  final Map<String, CastVoice> voices;
  final String? lead;
  final Map<String, String> aliases;

  /// Resolves an alias such as Lizzy to the canonical character name.
  String canonical(String name) {
    var current = name;
    final seen = <String>{};
    while (seen.add(current)) {
      final next = aliases[current];
      if (next == null || next.isEmpty || next == current) break;
      current = next;
    }
    return current;
  }

  CastVoice? voiceFor(String character) => voices[canonical(character)];

  CharacterCast withVoice(String character, CastVoice voice) {
    final name = canonical(character);
    return CharacterCast(
      voices: Map.unmodifiable({...voices, name: voice}),
      lead: lead,
      aliases: aliases,
    );
  }

  CharacterCast withoutVoice(String character) {
    final name = canonical(character);
    return CharacterCast(
      voices: Map.unmodifiable({
        for (final entry in voices.entries)
          if (entry.key != name) entry.key: entry.value,
      }),
      lead: lead == name ? null : lead,
      aliases: Map.unmodifiable({
        for (final entry in aliases.entries)
          if (entry.key != name && entry.value != name) entry.key: entry.value,
      }),
    );
  }

  CharacterCast withLead(String? character) {
    final value = character?.trim();
    return CharacterCast(
      voices: voices,
      lead: value == null || value.isEmpty ? null : canonical(value),
      aliases: aliases,
    );
  }

  /// Merges [from] into [into], keeping one voice and preserving aliases.
  CharacterCast mergeInto(String from, String into) {
    final source = canonical(from);
    final target = canonical(into);
    if (source == target) return this;
    final nextVoices = {...voices};
    final voice = nextVoices[target] ?? nextVoices[source];
    nextVoices.remove(source);
    if (voice != null) nextVoices[target] = voice;
    final nextAliases = {...aliases};
    for (final entry in aliases.entries) {
      if (canonical(entry.value) == source) nextAliases[entry.key] = target;
    }
    nextAliases[source] = target;
    nextAliases.remove(target);
    return CharacterCast(
      voices: Map.unmodifiable(nextVoices),
      lead: lead == source ? target : lead,
      aliases: Map.unmodifiable(nextAliases),
    );
  }

  String toJsonString() => jsonEncode({
    'voices': {
      for (final entry in voices.entries) entry.key: entry.value.toJson(),
    },
    if (lead != null) 'lead': lead,
    if (aliases.isNotEmpty) 'aliases': aliases,
  });
}

/// The voices available for casting. The narrator's voice is excluded from
/// automatic character assignments so the cast stays distinct.
class VoiceChoices {
  const VoiceChoices({
    required this.kokoro,
    required this.system,
    required this.narratorKokoro,
    required this.narratorSystem,
  });

  final List<int> kokoro;
  final List<SystemVoice> system;
  final int narratorKokoro;
  final String? narratorSystem;

  List<int> get kokoroOptions => [
    for (final id in kokoro)
      if (id != narratorKokoro) id,
  ];

  List<SystemVoice> get systemOptions => [
    for (final voice in system)
      if (voice.identifier != narratorSystem) voice,
  ];

  String kokoroLabel(int? id) =>
      id == null ? 'Automatic' : voices[id] ?? 'Kokoro $id';

  String systemLabel(String? id) {
    if (id == null) return 'Automatic';
    for (final voice in system) {
      if (voice.identifier == id) return voice.label;
    }
    return 'iPhone voice';
  }
}

class SpeechScript {
  const SpeechScript({
    required this.utterances,
    required this.cast,
    required this.characters,
    required this.castChanged,
    this.attributions = const [],
  });

  final List<SpeechUtterance> utterances;
  final CharacterCast cast;
  final List<String> characters;
  final bool castChanged;
  final List<DialogueAttribution> attributions;
}

/// Splits a section into narration and dialogue, attributes dialogue to
/// characters, and assigns each character a stable voice.
///
/// This runs fully offline. It is deliberately conservative: tagged dialogue
/// is attributed from the surrounding text, untagged replies alternate only
/// in a clear two-person scene, and anything else keeps the previous speaker
/// (or stays unknown) instead of inventing a new voice. Manual attribution
/// overrides are always respected.
SpeechScript buildSpeechScript({
  required String text,
  required VoiceSettings settings,
  required CharacterCast cast,
  required VoiceChoices choices,
  SectionAttribution? attribution,
}) {
  if (!settings.characterVoices) {
    return SpeechScript(
      utterances: [
        for (final chunk in speechChunks(text)) SpeechUtterance(chunk),
      ],
      cast: cast,
      characters: const [],
      castChanged: false,
    );
  }

  final spans = _dialogueSpans(text);
  final cached = attribution?.hash == textHash(text) ? attribution : null;
  final tagged = <int, String>{};
  final known = <String>{
    for (final name in cast.voices.keys) cast.canonical(name),
    if (cast.lead case final lead?) cast.canonical(lead),
  };
  for (var i = 0; i < spans.length; i++) {
    final span = spans[i];
    if (!span.dialogue) continue;
    final speaker = _speakerFromContext(span.before, span.after);
    if (speaker != null && speaker != 'I') {
      final canonical = cast.canonical(speaker);
      tagged[i] = canonical;
      known.add(canonical);
    }
  }

  final speakers = <int, String>{};
  String? lastSpeaker;
  for (var i = 0; i < spans.length; i++) {
    final span = spans[i];
    if (!span.dialogue) continue;
    final saved = cached?.forLine(span.paragraph, span.quote, span.text);
    if (saved != null) {
      final speaker = cast.canonical(saved.speaker);
      speakers[i] = speaker;
      lastSpeaker = speaker;
      continue;
    }

    String? speaker = tagged[i];
    speaker ??= _knownNameInContext(span.before, span.after, known);
    if (speaker == null && known.length == 2 && lastSpeaker == null) {
      speaker = known.first;
    }
    if (speaker == null &&
        known.length == 2 &&
        lastSpeaker != null &&
        known.contains(lastSpeaker)) {
      speaker = known.firstWhere(
        (name) => name != lastSpeaker,
        orElse: () => lastSpeaker!,
      );
    }
    if (speaker == null && known.length == 1 && lastSpeaker == null) {
      speaker = known.first;
    }
    speaker ??= lastSpeaker ?? 'Unknown';
    speaker = cast.canonical(speaker);
    speakers[i] = speaker;
    lastSpeaker = speaker;
  }

  var workingCast = cast;
  var leadChanged = false;
  if (workingCast.lead == null) {
    final counts = <String, int>{};
    for (final speaker in speakers.values) {
      if (speaker == 'Unknown' || speaker == 'Narrator' || speaker == 'I') {
        continue;
      }
      counts[speaker] = (counts[speaker] ?? 0) + 1;
    }
    String? lead;
    var best = 0;
    for (final entry in counts.entries) {
      if (entry.value > best) {
        lead = entry.key;
        best = entry.value;
      }
    }
    if (lead != null) {
      workingCast = workingCast.withLead(lead);
      leadChanged = true;
    }
  }

  final builder = _CastBuilder(workingCast, settings, choices);
  final utterances = <SpeechUtterance>[];
  final detected = <String>[];
  final attributions = <DialogueAttribution>[];

  for (var i = 0; i < spans.length; i++) {
    final span = spans[i];
    if (!span.dialogue) {
      for (final chunk in speechChunks(span.text)) {
        utterances.add(SpeechUtterance(chunk));
      }
      continue;
    }

    final speaker = speakers[i] ?? 'Unknown';
    final isNarrator =
        speaker == 'I' || speaker == 'Unknown' || speaker == 'Narrator';
    CastVoice voice = const CastVoice();
    if (!isNarrator) {
      if (!detected.contains(speaker)) detected.add(speaker);
      voice = builder.voiceFor(speaker);
    }
    final saved = cached?.forLine(span.paragraph, span.quote, span.text);
    attributions.add(
      DialogueAttribution(
        paragraph: span.paragraph,
        quote: span.quote,
        text: span.text,
        speaker: speaker,
        manual: saved?.manual ?? false,
        source: saved?.source ?? 'rules',
      ),
    );
    for (final chunk in speechChunks(span.text)) {
      utterances.add(
        SpeechUtterance(
          chunk,
          kind: SpeechKind.dialogue,
          speaker: isNarrator ? null : speaker,
          kokoroVoice: voice.kokoro,
          systemVoice: voice.system,
        ),
      );
    }
  }

  return SpeechScript(
    utterances: utterances,
    cast: builder.cast,
    characters: detected,
    castChanged: builder.changed || leadChanged,
    attributions: attributions,
  );
}

class _CastBuilder {
  _CastBuilder(this._cast, this.settings, this.choices)
    : usedKokoro = {
        settings.voice,
        for (final voice in _cast.voices.values)
          if (voice.kokoro != null) voice.kokoro!,
      },
      usedSystem = {
        if (settings.systemVoice != null) settings.systemVoice!,
        for (final voice in _cast.voices.values)
          if (voice.system != null) voice.system!,
      } {
    final lead = _cast.lead;
    if (lead != null && _cast.voices[lead] == null) {
      voiceFor(lead);
    }
  }

  CharacterCast _cast;
  final VoiceSettings settings;
  final VoiceChoices choices;
  final Set<int> usedKokoro;
  final Set<String> usedSystem;
  bool changed = false;

  CharacterCast get cast => _cast;
  String? get _lead => _cast.lead;

  CastVoice voiceFor(String character) {
    final name = _cast.canonical(character);
    final isLead = name == _lead;
    var existing = _cast.voices[name];
    final resKokoro = isLead ? null : _cast.voiceFor(_lead ?? '')?.kokoro;
    final resSystem = isLead ? null : _cast.voiceFor(_lead ?? '')?.system;
    if (!isLead &&
        existing != null &&
        ((resKokoro != null && existing.kokoro == resKokoro) ||
            (resSystem != null && existing.system == resSystem))) {
      existing = null;
    }
    final kokoro = existing?.kokoro ?? _pickKokoro(name, reserved: resKokoro);
    final system = existing?.system ?? _pickSystem(name, reserved: resSystem);
    if (existing == null ||
        existing.kokoro != kokoro ||
        existing.system != system) {
      _cast = _cast.withVoice(name, CastVoice(kokoro: kokoro, system: system));
      changed = true;
    }
    return CastVoice(kokoro: kokoro, system: system);
  }

  int _pickKokoro(String character, {int? reserved}) {
    final options = choices.kokoroOptions;
    if (options.isEmpty) return settings.voice;
    final pick = _pick(
      options,
      usedKokoro,
      _seed(character),
      reserved: reserved,
    );
    usedKokoro.add(pick);
    return pick;
  }

  String? _pickSystem(String character, {String? reserved}) {
    final options = [
      for (final voice in choices.systemOptions) voice.identifier,
    ];
    if (options.isEmpty) return null;
    final pick = _pick(
      options,
      usedSystem,
      _seed(character),
      reserved: reserved,
    );
    usedSystem.add(pick);
    return pick;
  }

  static T _pick<T>(List<T> options, Set<T> used, int seed, {T? reserved}) {
    for (var i = 0; i < options.length; i++) {
      final option = options[(seed + i) % options.length];
      if (!used.contains(option) && option != reserved) return option;
    }
    for (var i = 0; i < options.length; i++) {
      final option = options[(seed + i) % options.length];
      if (option != reserved) return option;
    }
    return options[seed % options.length];
  }

  static int _seed(String value) =>
      value.codeUnits.fold(0, (sum, unit) => (sum * 31 + unit) & 0x7fffffff);
}

class _Span {
  _Span(
    this.text, {
    required this.dialogue,
    this.paragraph = 0,
    this.quote = 0,
  });

  final String text;
  final bool dialogue;
  final int paragraph;
  int quote;
  String before = '';
  String after = '';
}

List<_Span> _dialogueSpans(String text) {
  final result = <_Span>[];
  final paragraphs = text.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
  var inQuote = false;
  var paragraphIndex = -1;

  for (final paragraph in paragraphs) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) continue;
    paragraphIndex++;
    var quoteIndex = 0;
    if (!inQuote && (trimmed.startsWith('—') || trimmed.startsWith('–'))) {
      final dialogue = trimmed.substring(1).trim();
      if (dialogue.isNotEmpty) {
        result.add(
          _Span(
            dialogue,
            dialogue: true,
            paragraph: paragraphIndex,
            quote: quoteIndex++,
          ),
        );
      }
      continue;
    }

    final local = <_Span>[];
    final narration = StringBuffer();
    final dialogue = StringBuffer();

    void flush({required bool quoted}) {
      final value = (quoted ? dialogue : narration).toString().trim();
      if (value.isNotEmpty) {
        local.add(_Span(value, dialogue: quoted, paragraph: paragraphIndex));
      }
      if (quoted) {
        dialogue.clear();
      } else {
        narration.clear();
      }
    }

    for (var i = 0; i < trimmed.length; i++) {
      final char = trimmed[i];
      if (char == '“' || char == '”' || char == '"') {
        if (char == '”' && !inQuote) continue;
        flush(quoted: inQuote);
        inQuote = !inQuote;
        continue;
      }
      (inQuote ? dialogue : narration).write(char);
    }
    flush(quoted: inQuote);

    for (var i = 0; i < local.length; i++) {
      if (!local[i].dialogue) continue;
      local[i].quote = quoteIndex++;
      local[i].before = i > 0 && !local[i - 1].dialogue
          ? local[i - 1].text
          : '';
      local[i].after = i + 1 < local.length && !local[i + 1].dialogue
          ? local[i + 1].text
          : '';
    }
    result.addAll(local);
  }
  return result;
}

const _speechVerbs =
    r'(?:said|asked|replied|answered|whispered|shouted|cried|murmured|added|'
    r'continued|exclaimed|muttered|laughed|sighed|called|warned|begged|'
    r'repeated|snapped|growled|observed|remarked|responded|declared|'
    r'announced|explained|protested|insisted|agreed|admitted|wondered|'
    r'thought|told|urged|pleaded|offered|suggested|promised|argued|'
    r'corrected|interrupted|breathed|hissed|roared|sobbed)';

const _title =
    r'(?:Mr\.|Mrs\.|Ms\.|Miss|Dr\.|Sir|Lady|Lord|Uncle|Aunt|Captain|'
    r'Colonel|Professor|Madame|Monsieur|Signor|Señor)';
const _name = r"[A-Z][a-zA-Z'’.-]+(?:\s+[A-Z][a-zA-Z'’.-]+){0,2}";
const _entity = '(?:(?:$_title)\\s+)?$_name';
const _genericEntity = r'(?:the|his|her|their|my|our)\s+[a-z]+(?:\s+[a-z]+)?';

const _notNames = {
  'The',
  'A',
  'An',
  'He',
  'She',
  'They',
  'It',
  'We',
  'You',
  'His',
  'Her',
  'Their',
  'My',
  'Our',
  'This',
  'That',
  'These',
  'Those',
  'But',
  'And',
  'Then',
  'When',
  'While',
  'After',
  'Before',
  'As',
  'At',
  'In',
  'On',
  'For',
  'With',
  'From',
  'There',
  'Here',
};

String? _speakerFromContext(String before, String after) {
  final fromAfter = _speakerAfter(after);
  if (fromAfter != null) return fromAfter;
  return _speakerBefore(before);
}

String? _speakerAfter(String text) {
  if (text.isEmpty) return null;
  final patterns = [
    RegExp('\\b$_speechVerbs\\s+(?:to\\s+)?($_entity)', caseSensitive: true),
    RegExp('\\b$_speechVerbs\\s+($_genericEntity)', caseSensitive: true),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(text)) {
      final name = _cleanName(match[1]);
      if (name != null) return name;
    }
  }
  return null;
}

String? _speakerBefore(String text) {
  if (text.isEmpty) return null;
  final patterns = [
    RegExp('($_entity)\\s+$_speechVerbs\\b', caseSensitive: true),
    RegExp('($_genericEntity)\\s+$_speechVerbs\\b', caseSensitive: true),
  ];
  for (final pattern in patterns) {
    final matches = pattern.allMatches(text).toList();
    for (final match in matches.reversed) {
      final name = _cleanName(match[1]);
      if (name != null) return name;
    }
  }
  return null;
}

String? _knownNameInContext(String before, String after, Set<String> known) {
  if (known.isEmpty) return null;
  final context = '$before $after';
  String? found;
  for (final name in known) {
    if (!context.contains(name)) continue;
    if (found != null && found != name) return null;
    found = name;
  }
  return found;
}

String? _cleanName(String? value) {
  if (value == null) return null;
  var name = value.replaceAll('’', "'").replaceAll(RegExp(r'\s+'), ' ').trim();
  name = name.replaceAll(RegExp(r"['’]s$"), '');
  name = name.replaceAll(RegExp(r'[.,;:!?]+$'), '').trim();
  if (name.isEmpty) return null;
  if (_notNames.contains(name)) return null;
  if (name == 'I') return 'I';
  if (RegExp(
    r'^(he|she|they|it|we|you)$',
    caseSensitive: false,
  ).hasMatch(name)) {
    return null;
  }
  if (name.length < 2) return null;
  return name;
}
