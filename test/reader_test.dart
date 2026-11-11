import 'package:archive/archive.dart';
import 'package:epub_rtl/epub_rtl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

import 'package:relay_reader/character_voices.dart';
import 'package:relay_reader/epub_recovery.dart';
import 'package:relay_reader/library.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/reader.dart';
import 'package:relay_reader/text_highlight.dart';
import 'package:relay_reader/theme.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test(
    'speech keeps Unicode text intact and expands supported marks on request',
    () {
      final word = List.filled(300, '🌱').join();
      expect(speechChunks(word).join(), word);
      expect(
        speechChunks(word)
            .every((chunk) => chunk.runes.length <= speechChunkLimit),
        isTrue,
      );
      const sentence = 'Hello, (world)!';
      expect(prepareSpeech(sentence, Punctuation.natural), sentence);
      expect(
        prepareSpeech(sentence, Punctuation.announce),
        contains('open parenthesis'),
      );
    },
  );

  test('Kokoro stays the default and Phonon settings are opt-in', () {
    const settings = VoiceSettings();
    expect(settings.engine, VoiceEngine.kokoro);
    expect(settings.phononVoice, 'Harper');
    final phonon = settings.withChanges(
      engine: VoiceEngine.phonon,
      phononVoice: 'Freya',
    );
    expect(phonon.engine, VoiceEngine.phonon);
    expect(phonon.phononVoice, 'Freya');
    expect(const VoiceSettings().engine, VoiceEngine.kokoro);
  });

  test('finds the narrated sentence with wrapped or collapsed whitespace', () {
    const text =
        'The rain stopped.\n\n“Good morning,” said Elizabeth.\n\n'
        'The garden was quiet.';
    final exact = findPassageRange(text, 'The garden was quiet.');
    expect(exact, isNotNull);
    expect(text.substring(exact!.start, exact.end), 'The garden was quiet.');

    final wrapped = findPassageRange(text, '“Good morning,” said\nElizabeth.');
    expect(wrapped, isNotNull);
    expect(
      text.substring(wrapped!.start, wrapped.end),
      contains('Good morning'),
    );

    expect(findPassageRange(text, 'A sentence that is not here.'), isNull);
  });

  test(
    'narration extracts EPUB headings, paragraphs, and lists in order',
    () async {
      final archive = Archive();
      const entries = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '''
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
        'book.opf': '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">urn:example:garden</dc:identifier>
    <dc:title>Garden Notes</dc:title><dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>''',
        'nav.xhtml': '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">A garden</a></li></ol></nav></body>
</html>''',
        'chapter.xhtml': '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>A garden</title></head>
<body><h1>A garden</h1><p>The rain has stopped.</p><ul><li>A robin sings.</li></ul></body></html>''',
      };
      for (final entry in entries.entries) {
        archive.addFile(ArchiveFile.string(entry.key, entry.value));
      }
      final epub = EpubBook.fromBytes(ZipEncoder().encode(archive));
      final book = OpenedBook(
        const LibraryBook('epub-test', 'Garden Notes', '', BookFormat.epub),
        epub: epub,
      );
      addTearDown(book.close);
      expect(book.length, 1);
      expect(
        await book.spokenText(0),
        'A garden\n\nThe rain has stopped.\n\nA robin sings.',
      );
    },
  );

  test('an EPUB without a spine falls back to its XHTML manifest order', () {
    final archive = Archive();
    const entries = {
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf': '''
<package version="3.0">
  <metadata><title>Garden</title></metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
</package>''',
      'chapter.xhtml': '''
<html><body><h1>A garden</h1><p>The rain has stopped.</p></body></html>''',
    };
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile.string(entry.key, entry.value));
    }
    final epub = EpubBook.fromBytes(
      ZipEncoder().encode(archive),
      lenient: true,
    );
    final book = OpenedBook(
      const LibraryBook('fallback', 'Garden', '', BookFormat.epub),
      epub: epub,
    );
    addTearDown(book.close);
    expect(book.length, 1);
    expect(book.chapter(0).blocks, isNotEmpty);
  });

  test('a malformed chapter falls back to plain text', () {
    final archive = Archive();
    const entries = {
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      'book.opf': '''
<package version="3.0">
  <metadata><title>Garden</title></metadata>
  <manifest>
    <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
    <item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="one"/><itemref idref="two"/></spine>
</package>''',
      'one.xhtml': '<html><body><p>The garden is quiet.</p></body></html>',
      'two.xhtml': '<html><body><p>The gate is open & the path is clear',
    };
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile.string(entry.key, entry.value));
    }
    final epub = EpubBook.fromBytes(
      ZipEncoder().encode(archive),
      lenient: true,
    );
    final book = OpenedBook(
      const LibraryBook('broken-chapter', 'Garden', '', BookFormat.epub),
      epub: epub,
    );
    addTearDown(book.close);
    expect(book.chapter(0).blocks, isNotEmpty);
    expect(book.chapter(1).blocks, isNotEmpty);
  });

  test('a damaged EPUB can be recovered as plain text', () async {
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'OEBPS/chapter.xhtml',
          '<html><head><title>A garden</title></head><body>'
              '<h1>A garden</h1><p>The rain&nbsp;has stopped.</p>'
              '</body></html>',
        ),
      );
    final directory = await Directory.systemTemp.createTemp('relay-epub-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/damaged.epub');
    await file.writeAsBytes(ZipEncoder().encode(archive));

    final recovered = await recoverEpubText(file.path);
    expect(recovered, isNotNull);
    expect(recovered!.chapters, 1);
    expect(recovered.text, contains('The rain has stopped.'));
    expect(htmlToText('Hello&nbsp;world &#8212; ok'), 'Hello world — ok');
  });

  test('common DRM sidecars are not treated as damaged books', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('META-INF/rights.xml', '<rights/>'))
      ..addFile(
        ArchiveFile.string(
          'OEBPS/chapter.xhtml',
          '<html><body><p>Hidden text.</p></body></html>',
        ),
      );
    final directory = await Directory.systemTemp.createTemp('relay-drm-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/locked.epub');
    await file.writeAsBytes(ZipEncoder().encode(archive));

    await expectLater(
      recoverEpubText(file.path),
      throwsA(isA<DrmProtectedEpub>()),
    );
  });

  test('dialogue gets distinct character voices', () {
    const text =
        'The rain stopped.\n\n'
        '“Good morning,” said Elizabeth. “Mr. Darcy,” she added. '
        '“Good morning, Miss Bennet,” said Mr. Darcy.';
    final settings = VoiceSettings(voice: 3, characterVoices: true);
    final script = buildSpeechScript(
      text: text,
      settings: settings,
      cast: const CharacterCast(),
      choices: VoiceChoices(
        kokoro: voices.keys.toList(),
        system: const [],
        narratorKokoro: 3,
        narratorSystem: null,
      ),
    );
    final elizabeth = script.utterances.firstWhere(
      (utterance) => utterance.speaker == 'Elizabeth',
    );
    final darcy = script.utterances.firstWhere(
      (utterance) => utterance.speaker == 'Mr. Darcy',
    );
    expect(elizabeth.kokoroVoice, isNotNull);
    expect(darcy.kokoroVoice, isNotNull);
    expect(elizabeth.kokoroVoice, isNot(3));
    expect(darcy.kokoroVoice, isNot(3));
    expect(elizabeth.kokoroVoice, isNot(darcy.kokoroVoice));
    expect(script.cast.voices.keys, containsAll(['Elizabeth', 'Mr. Darcy']));
  });

  test('untagged dialogue alternates between two known characters', () {
    final script = buildSpeechScript(
      text: '“Hello.” “Hi.” “How are you?”',
      settings: const VoiceSettings(voice: 3, characterVoices: true),
      cast: const CharacterCast(
        voices: {'Alice': CastVoice(kokoro: 6), 'Bob': CastVoice(kokoro: 16)},
      ),
      choices: VoiceChoices(
        kokoro: voices.keys.toList(),
        system: const [],
        narratorKokoro: 3,
        narratorSystem: null,
      ),
    );
    final dialogue = script.utterances.where((u) => u.isDialogue).toList();
    expect(dialogue.length, 3);
    expect(dialogue[0].speaker, isNot(dialogue[1].speaker));
    expect(dialogue[0].kokoroVoice, isNot(dialogue[1].kokoroVoice));
    expect(dialogue[2].speaker, dialogue[0].speaker);
  });

  test('narration checkpoints round trip and cap their passage', () {
    final checkpoint = NarrationCheckpoint(
      section: 4,
      utterance: 12,
      passage: List.filled(80, 'word').join(' '),
      playing: true,
      updated: DateTime.utc(2026, 11, 10, 19, 30),
    );
    final restored = NarrationCheckpoint.fromJson(checkpoint.toJson());
    expect(restored.section, 4);
    expect(restored.utterance, 12);
    expect(restored.playing, isTrue);
    expect(restored.updated, checkpoint.updated);
    expect(restored.passage.length, lessThanOrEqualTo(320));
  });

  test('continue listening picks the most recent book checkpoint', () async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    final library = Library();
    addTearDown(library.close);
    const first = LibraryBook('one', 'First', '', BookFormat.txt);
    const second = LibraryBook('two', 'Second', '', BookFormat.txt);
    await library.saveNarration(
      first,
      NarrationCheckpoint(
        section: 2,
        utterance: 4,
        passage: 'First checkpoint',
        playing: false,
        updated: DateTime.utc(2026, 11, 10, 18),
      ),
    );
    await library.saveNarration(
      second,
      NarrationCheckpoint(
        section: 1,
        utterance: 9,
        passage: 'Second checkpoint',
        playing: true,
        updated: DateTime.utc(2026, 11, 10, 19),
      ),
    );
    final latest = await library.continueListening([first, second]);
    expect(latest, isNotNull);
    expect(latest!.book.id, second.id);
    expect(latest.checkpoint.utterance, 9);
  });

  test('character cast round trips through JSON', () {
    const cast = CharacterCast();
    final updated = cast
        .withVoice('Elizabeth', const CastVoice(kokoro: 6))
        .withVoice(
          'Mr. Darcy',
          const CastVoice(kokoro: 16, system: 'voice-id'),
        );
    final restored = CharacterCast.fromJsonString(updated.toJsonString());
    expect(restored.voices['Elizabeth']?.kokoro, 6);
    expect(restored.voices['Mr. Darcy']?.kokoro, 16);
    expect(restored.voices['Mr. Darcy']?.system, 'voice-id');
    expect(
      restored.withoutVoice('Elizabeth').voices,
      isNot(contains('Elizabeth')),
    );
  });

  test('main character reserves a voice for the whole book', () {
    final text =
        '“Good morning,” said Elizabeth.\n\n'
        '“Good morning,” said Mr. Darcy.\n\n'
        '“Goodbye,” said Elizabeth.';
    final script = buildSpeechScript(
      text: text,
      settings: const VoiceSettings(voice: 3, characterVoices: true),
      cast: const CharacterCast(
        lead: 'Elizabeth',
        voices: {
          'Elizabeth': CastVoice(kokoro: 6),
          'Mr. Darcy': CastVoice(kokoro: 16),
        },
      ),
      choices: VoiceChoices(
        kokoro: voices.keys.toList(),
        system: const [],
        narratorKokoro: 3,
        narratorSystem: null,
      ),
    );
    final elizabeth = script.utterances.where(
      (utterance) => utterance.speaker == 'Elizabeth',
    );
    final darcy = script.utterances.where(
      (utterance) => utterance.speaker == 'Mr. Darcy',
    );
    expect(script.cast.lead, 'Elizabeth');
    expect(elizabeth, isNotEmpty);
    expect(elizabeth.every((utterance) => utterance.kokoroVoice == 6), isTrue);
    expect(darcy.every((utterance) => utterance.kokoroVoice != 6), isTrue);
  });

  test('automatic lead selection follows the most frequent speaker', () {
    final script = buildSpeechScript(
      text:
          '“One,” said Elizabeth.\n\n'
          '“Two,” said Elizabeth.\n\n'
          '“Three,” said Mr. Darcy.',
      settings: const VoiceSettings(voice: 3, characterVoices: true),
      cast: const CharacterCast(),
      choices: VoiceChoices(
        kokoro: voices.keys.toList(),
        system: const [],
        narratorKokoro: 3,
        narratorSystem: null,
      ),
    );
    expect(script.cast.lead, 'Elizabeth');
    expect(script.cast.voices.keys, containsAll(['Elizabeth', 'Mr. Darcy']));
  });

  test('manual speaker checkpoints override automatic attribution', () {
    const text = '“Hello.” “Hi.”';
    final attribution = SectionAttribution(
      hash: textHash(text),
      entries: const [
        DialogueAttribution(
          paragraph: 0,
          quote: 0,
          text: 'Hello.',
          speaker: 'Elizabeth',
          manual: true,
          source: 'manual',
        ),
        DialogueAttribution(
          paragraph: 0,
          quote: 1,
          text: 'Hi.',
          speaker: 'Mr. Darcy',
          manual: true,
          source: 'manual',
        ),
      ],
    );
    final script = buildSpeechScript(
      text: text,
      settings: const VoiceSettings(voice: 3, characterVoices: true),
      cast: const CharacterCast(lead: 'Elizabeth'),
      choices: VoiceChoices(
        kokoro: voices.keys.toList(),
        system: const [],
        narratorKokoro: 3,
        narratorSystem: null,
      ),
      attribution: attribution,
    );
    final dialogue = script.utterances.where((u) => u.isDialogue).toList();
    expect(dialogue[0].speaker, 'Elizabeth');
    expect(dialogue[1].speaker, 'Mr. Darcy');
    expect(script.attributions.every((entry) => entry.manual), isTrue);
  });

  test('lead and aliases round trip through cast JSON', () {
    final cast = const CharacterCast(
      voices: {
        'Elizabeth': CastVoice(kokoro: 6),
        'Lizzy': CastVoice(kokoro: 9),
      },
    ).withLead('Elizabeth').mergeInto('Lizzy', 'Elizabeth');
    final restored = CharacterCast.fromJsonString(cast.toJsonString());
    expect(restored.lead, 'Elizabeth');
    expect(restored.canonical('Lizzy'), 'Elizabeth');
    expect(restored.voices['Lizzy'], isNull);
    expect(restored.voices['Elizabeth']?.kokoro, 6);
  });

  test(
    'speaker checkpoints are saved per section and invalidated by hash',
    () async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      final library = Library();
      addTearDown(library.close);
      const book = LibraryBook(
        'checkpoints',
        'Checkpoints',
        '',
        BookFormat.txt,
      );
      final attribution = SectionAttribution(
        hash: 'abc',
        entries: const [
          DialogueAttribution(
            paragraph: 2,
            quote: 0,
            text: 'Hello.',
            speaker: 'Elizabeth',
            manual: true,
            source: 'manual',
          ),
        ],
      );
      await library.saveAttribution(book, 4, attribution);
      final loaded = await library.attribution(book, 4, 'abc');
      expect(loaded, isNotNull);
      expect(loaded!.entries.single.speaker, 'Elizabeth');
      expect(await library.attribution(book, 4, 'changed'), isNull);
    },
  );

  test('saved theme names stay compatible with the old palette values', () {
    expect(ThemeChoice.fromName('night'), ThemeChoice.night);
    expect(ThemeChoice.fromName('midnight'), ThemeChoice.ink);
    expect(ThemeChoice.fromName('unknown'), ThemeChoice.system);
    expect(ThemeChoice.fromName(null), ThemeChoice.system);
  });

  testWidgets(
    'reader settings and page navigation fit phone portrait and landscape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(375, 667);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      final library = Library();
      addTearDown(library.close);
      final theme = ReaderThemeController(ThemeChoice.day);
      addTearDown(theme.dispose);
      final book = OpenedBook(
        const LibraryBook('test', 'Garden notes', '', BookFormat.txt),
        text: List.filled(
          150,
          'A little garden at the back of the house.',
        ).join('\n'),
      );
      await library.saveCast(
        book.entry,
        const CharacterCast(
          voices: {
            'Elizabeth': CastVoice(kokoro: 6),
            'Mr. Darcy': CastVoice(kokoro: 16),
          },
        ),
      );
      await library.saveNarration(
        book.entry,
        NarrationCheckpoint(
          section: 0,
          utterance: 2,
          passage: 'A little garden at the back of the house.',
          playing: false,
          updated: DateTime.utc(2026, 11, 10, 19),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Reader(
            book: book,
            library: library,
            theme: theme,
            position: 0,
            bookmark: null,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 / 2'), findsOneWidget);
      tester.view.physicalSize = const Size(667, 375);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Night'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Night'))
            .selected,
        isTrue,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Read aloud settings'));
      await tester.pumpAndSettle();
      expect(find.text('Continue through the book'), findsOneWidget);
      expect(find.text('Battery saver'), findsOneWidget);
      expect(find.text('Experimental · LFM3-Audio narrator'), findsOneWidget);
      expect(find.text('Use LFM3-Audio for narration'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
