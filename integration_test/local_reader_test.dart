import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_reader/lfm3.dart';
import 'package:relay_reader/lfm3_audio.dart';
import 'package:relay_reader/library.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/reader.dart';
import 'package:relay_reader/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeNarration();
    try {
      await FlutterEdgeAi.initialize(
        inferenceEngines: const [LlamaEngineProvider()],
      );
      Lfm3Model.markReady();
    } catch (error) {
      debugPrint('Experimental LFM3 is unavailable: $error');
    }
  });
  setUp(() async {
    try {
      await SharedPreferencesAsync().setBool('reader.lfm3Audio', false);
    } catch (error) {
      debugPrint('Could not reset the LFM3-Audio preference: $error');
    }
  });

  testWidgets(
    'imports a readable EPUB with no navigation and obfuscated fonts',
    (_) async {
      final library = Library();
      addTearDown(library.close);
      final entries = {
        'META-INF/container.xml': '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
        'META-INF/encryption.xml':
            '<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>'
            '<CipherData><CipherReference URI="fonts/font.otf"/></CipherData></EncryptedData></encryption>',
        'book.opf':
            '<package version="3.0"><metadata><title>Garden</title></metadata><manifest>'
            '<item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="font" href="fonts/font.otf" media-type="font/otf"/>'
            '</manifest><spine><itemref idref="chapter"/></spine></package>',
        'chapter.xhtml': '<html><body><p>A robin sings.</p></body></html>',
        'fonts/font.otf': 'obfuscated font bytes',
      };
      final zip = Archive();
      for (final entry in entries.entries) {
        zip.addFile(ArchiveFile.string(entry.key, entry.value));
      }
      final book = await library.import(
        XFile.fromData(
          Uint8List.fromList(ZipEncoder().encode(zip)),
          path: 'Garden.epub',
        ),
      );
      addTearDown(() async {
        await book.close();
        await library.remove(book.entry);
      });
      expect(await book.spokenText(0), 'A robin sings.');
      expect(
        (await library.books()).any((entry) => entry.id == book.entry.id),
        isTrue,
      );
    },
  );

  testWidgets('recovers a damaged EPUB in text-only mode', (_) async {
    final library = Library();
    addTearDown(library.close);
    final zip = Archive()
      ..addFile(
        ArchiveFile.string(
          'OEBPS/chapter.xhtml',
          '<html><body><h1>A garden</h1><p>The rain has stopped.</p>'
              '<p>A robin sings.</p></body></html>',
        ),
      );
    final book = await library.import(
      XFile.fromData(
        Uint8List.fromList(ZipEncoder().encode(zip)),
        path: 'Damaged.epub',
      ),
    );
    addTearDown(() async {
      await book.close();
      await library.remove(book.entry);
    });
    expect(book.recovered, isTrue);
    expect(await book.spokenText(0), contains('A robin sings.'));
  });

  testWidgets('lists and renders an installed iPhone voice', (tester) async {
    if (!Platform.isIOS) return;
    final voices = await SystemVoices.list();
    expect(voices, isNotEmpty, reason: 'No English iPhone voices were found.');
    final directory = await Directory.systemTemp.createTemp('relay-voice-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/sample.caf';
    final settings = VoiceSettings(
      engine: VoiceEngine.system,
      systemVoice: voices.first.identifier,
    );
    expect(
      await SystemVoices.synthesize(
        text: 'The garden was quiet in the morning.',
        path: path,
        settings: settings,
      ),
      isTrue,
    );
    expect(await File(path).length(), greaterThan(100));
  });

  testWidgets('previews an iPhone voice', (tester) async {
    if (!Platform.isIOS) return;
    final voices = await SystemVoices.list();
    expect(voices, isNotEmpty);
    final narrator = Narrator();
    addTearDown(narrator.close);
    await narrator
        .preview(
          VoiceSettings(
            engine: VoiceEngine.system,
            systemVoice: voices.first.identifier,
          ),
        )
        .timeout(const Duration(seconds: 20));
    expect(narrator.previewing, isFalse);
  });

  testWidgets('plays two characters with different iPhone voices', (
    tester,
  ) async {
    if (!Platform.isIOS) return;
    final voices = await SystemVoices.list();
    if (voices.length < 2) return;
    final narrator = Narrator();
    addTearDown(narrator.close);
    narrator.settings = VoiceSettings(
      engine: VoiceEngine.system,
      systemVoice: voices[0].identifier,
    );
    narrator.start(
      title: 'Cast test',
      sectionName: 'Page',
      index: 0,
      length: 1,
      loadSpeech: (_) async => [
        SpeechUtterance(
          'Good morning, Elizabeth.',
          kind: SpeechKind.dialogue,
          speaker: 'Elizabeth',
          systemVoice: voices[1].identifier,
        ),
        const SpeechUtterance('She smiled and looked away.'),
        SpeechUtterance(
          'Good morning, Mr. Darcy. It is a fine day for a walk, is it not?',
          kind: SpeechKind.dialogue,
          speaker: 'Mr. Darcy',
          systemVoice: voices.length > 2
              ? voices[2].identifier
              : voices[0].identifier,
        ),
      ],
      showSection: (_) {},
      continueToEnd: false,
    );
    await _until(
      tester,
      () =>
          narrator.speaker == 'Mr. Darcy' ||
          narrator.error != null ||
          narrator.state == SpeechState.idle,
    );
    expect(narrator.error, isNull);
    expect(narrator.speaker, 'Mr. Darcy');
    await narrator.stop();
  });

  testWidgets('switches Kokoro voices between two characters', (tester) async {
    final narrator = Narrator();
    addTearDown(narrator.close);
    narrator.settings = const VoiceSettings(voice: 3, speed: 1.25);
    narrator.start(
      title: 'Kokoro cast',
      sectionName: 'Page',
      index: 0,
      length: 1,
      loadSpeech: (_) async => const [
        SpeechUtterance(
          'Good morning, Elizabeth.',
          kind: SpeechKind.dialogue,
          speaker: 'Elizabeth',
          kokoroVoice: 6,
        ),
        SpeechUtterance('She smiled and looked away.'),
        SpeechUtterance(
          'Good morning, Mr. Darcy. It is a fine day for a walk.',
          kind: SpeechKind.dialogue,
          speaker: 'Mr. Darcy',
          kokoroVoice: 16,
        ),
      ],
      showSection: (_) {},
      continueToEnd: false,
    );
    await _until(
      tester,
      () =>
          narrator.speaker == 'Mr. Darcy' ||
          narrator.error != null ||
          narrator.state == SpeechState.idle,
    );
    expect(narrator.error, isNull);
    expect(narrator.speaker, 'Mr. Darcy');
    await narrator.stop();
  });

  testWidgets('highlights the sentence being narrated', (tester) async {
    final library = Library();
    addTearDown(library.close);
    final theme = ReaderThemeController(ThemeChoice.day);
    addTearDown(theme.dispose);
    final book = OpenedBook(
      const LibraryBook('highlight-test', 'Garden notes', '', BookFormat.txt),
      text:
          'The garden was quiet in the morning light. '
          'A robin sang from the old apple tree. '
          'The house seemed to be listening. '
          'Then the rain began again.',
    );
    addTearDown(book.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Reader(
          book: book,
          library: library,
          theme: theme,
          position: 0,
          bookmark: null,
        ),
      ),
    );
    await _until(
      tester,
      () => find.byTooltip('Read aloud').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Read aloud'));
    bool highlighted() => tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    ).any((widget) {
      bool hasHighlight(InlineSpan span) {
        if (span is TextSpan) {
          if (span.style?.backgroundColor != null) return true;
          return span.children?.any(hasHighlight) ?? false;
        }
        return false;
      }

      return widget.textSpan != null && hasHighlight(widget.textSpan!);
    });
    final end = DateTime.now().add(const Duration(seconds: 150));
    while (!highlighted() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(highlighted(), isTrue);
    await tester.tap(find.byTooltip('Stop narration'));
    await _until(
      tester,
      () => find.byTooltip('Read aloud').evaluate().isNotEmpty,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('enables LFM3-Audio narration in read aloud settings', (
    tester,
  ) async {
    if (!Lfm3AudioModel.supported || !await Lfm3AudioModel.isInstalled()) {
      return;
    }
    final library = Library();
    addTearDown(library.close);
    final theme = ReaderThemeController(ThemeChoice.day);
    addTearDown(theme.dispose);
    final book = OpenedBook(
      const LibraryBook(
        'lfm3-audio-settings',
        'Garden notes',
        '',
        BookFormat.txt,
      ),
      text: 'The garden was quiet in the morning light.',
    );
    addTearDown(book.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Reader(
          book: book,
          library: library,
          theme: theme,
          position: 0,
          bookmark: null,
        ),
      ),
    );
    await _until(
      tester,
      () => find.byTooltip('Read aloud settings').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Read aloud settings'));
    await tester.pumpAndSettle();
    expect(find.text('Experimental · LFM3-Audio narrator'), findsOneWidget);
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Use LFM3-Audio for narration',
    );
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('plays a queued clip from an iPhone voice', (tester) async {
    if (!Platform.isIOS) return;
    final voices = await SystemVoices.list();
    expect(voices, isNotEmpty);
    final narrator = Narrator();
    addTearDown(narrator.close);
    narrator.settings = VoiceSettings(
      engine: VoiceEngine.system,
      systemVoice: voices.first.identifier,
    );
    narrator.start(
      title: 'Voice test',
      sectionName: 'Page',
      index: 0,
      length: 1,
      loadSpeech: (_) async => const [
        SpeechUtterance('The garden was quiet. A robin sang in the tree.'),
      ],
      showSection: (_) {},
      continueToEnd: false,
    );
    await _until(
      tester,
      () => narrator.state == SpeechState.playing || narrator.error != null,
    );
    expect(narrator.error, isNull);
    await narrator.stop();
  });

  testWidgets('saves and restores the last spoken sentence', (tester) async {
    final library = Library();
    addTearDown(library.close);
    final text = List.filled(
      20,
      'The garden was quiet and a robin sang in the old apple tree.',
    ).join(' ');
    final book = await library.import(
      XFile.fromData(Uint8List.fromList(utf8.encode(text)), path: 'Resume.txt'),
    );
    addTearDown(() async {
      await book.close();
      await library.remove(book.entry);
    });
    final theme = ReaderThemeController(ThemeChoice.day);
    addTearDown(theme.dispose);
    Widget reader({bool resume = false}) => MaterialApp(
      home: Reader(
        book: book,
        library: library,
        theme: theme,
        position: 0,
        bookmark: null,
        resumeNarration: resume,
      ),
    );

    await tester.pumpWidget(reader());
    await _until(
      tester,
      () => find.byTooltip('Read aloud').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('Read aloud'));

    final end = DateTime.now().add(const Duration(seconds: 150));
    NarrationCheckpoint? checkpoint;
    while (DateTime.now().isBefore(end)) {
      checkpoint = await library.narration(book.entry);
      if (checkpoint != null && checkpoint.utterance >= 1) break;
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(checkpoint, isNotNull);
    expect(checkpoint!.utterance, greaterThanOrEqualTo(1));
    expect(checkpoint.passage, isNotEmpty);
    final passage = checkpoint.passage.substring(
      0,
      checkpoint.passage.length < 24 ? checkpoint.passage.length : 24,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(reader());
    await tester.pump(const Duration(seconds: 1));
    await _until(
      tester,
      () => find.textContaining('Continue listening').evaluate().isNotEmpty,
    );
    expect(find.textContaining(passage), findsWidgets);

    await tester.tap(find.byTooltip('Read aloud'));
    await _until(
      tester,
      () =>
          find.byTooltip('Pause narration').evaluate().isNotEmpty ||
          find.byTooltip('Resume narration').evaluate().isNotEmpty,
    );
    expect(find.textContaining(passage), findsWidgets);
    await tester.tap(find.byTooltip('Stop narration'));
    await _until(
      tester,
      () => find.byTooltip('Read aloud').evaluate().isNotEmpty,
    );
  });

  testWidgets('swipes between whole PDF pages and narrates across them', (
    tester,
  ) async {
    final library = Library();
    addTearDown(library.close);
    final book = await library.import(
      XFile.fromData(
        _pdf(),
        path: 'Garden notes.pdf',
        mimeType: 'application/pdf',
      ),
    );
    addTearDown(() => library.remove(book.entry));
    expect(await book.spokenText(0), contains('The garden is quiet'));
    expect(book.length, 2);

    final theme = ReaderThemeController(ThemeChoice.day);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Reader(
          book: book,
          library: library,
          theme: theme,
          position: 0,
          bookmark: null,
        ),
      ),
    );

    await _until(tester, () {
      final play = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Read aloud',
        ),
      );
      return play.onPressed != null;
    });
    expect(find.text('Page 1 / 2'), findsOneWidget);
    await _until(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    final pdfPage = tester.getRect(find.byType(RawImage).first);
    final pdfView = tester.getRect(find.byType(PageView));
    expect(pdfPage.width, lessThanOrEqualTo(pdfView.width));
    expect(pdfPage.height, lessThanOrEqualTo(pdfView.height));
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 900);
    await tester.pumpAndSettle();
    expect(find.text('Page 2 / 2'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(300, 0), 900);
    await tester.pumpAndSettle();
    expect(find.text('Page 1 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Read aloud'));
    await _until(tester, () {
      final error = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      );
      for (final message in tester.widgetList<Text>(
        find.descendant(of: error, matching: find.byType(Text)),
      )) {
        fail(message.data ?? 'Narration reported an error');
      }
      return find.byTooltip('Stop narration').evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty;
    });
    expect(find.textContaining('The garden is quiet'), findsOneWidget);

    await tester.tap(find.byTooltip('Pause narration'));
    await tester.pump();
    expect(find.byTooltip('Resume narration'), findsOneWidget);
    await tester.tap(find.byTooltip('Resume narration'));
    await tester.pump();
    expect(find.byTooltip('Pause narration'), findsOneWidget);
    await _until(tester, () => find.text('Page 2 / 2').evaluate().isNotEmpty);
    expect(find.textContaining('A river runs'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop narration'));
    await _until(
      tester,
      () => find.byTooltip('Read aloud').evaluate().isNotEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, skip: !(Platform.isMacOS || Platform.isIOS || Platform.isAndroid));

  testWidgets('downloads and runs the experimental LFM3 model', (tester) async {
    if (!Lfm3Model.supported) return;
    if (!await Lfm3Model.isDownloaded()) {
      await Lfm3Model.download(onProgress: (_) {});
    }
    expect(await Lfm3Model.isDownloaded(), isTrue);
    await Lfm3Model.load();
    final suggestions = await Lfm3Analyzer.analyze(
      text:
          'The rain stopped.\n\n'
          '“Good morning,” said Elizabeth.\n\n'
          '“Good morning, Miss Bennet,” said Mr. Darcy.',
      cast: const ['Elizabeth', 'Mr. Darcy'],
      lead: 'Elizabeth',
    );
    expect(suggestions, isNotEmpty);
    expect(
      suggestions.map((suggestion) => suggestion.speaker),
      contains('Elizabeth'),
    );
    await Lfm3Model.unload();
  }, timeout: const Timeout(Duration(minutes: 30)));
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 90));
  while (!condition() && DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(
    condition(),
    isTrue,
    reason: 'Reader did not reach the expected state',
  );
}

// An in-memory fixture keeps the test independent of local documents.
Uint8List _pdf() {
  String content(String text) {
    final stream = 'BT /F1 16 Tf 72 700 Td ($text) Tj ET';
    return '<< /Length ${stream.length} >>\nstream\n$stream\nendstream';
  }

  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count 2 /Kids [3 0 R 6 0 R] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    content(
      'The garden is quiet. A robin sings. Morning light touches the trees.',
    ),
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 792 612] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>',
    content(
      'A river runs past the garden. The branches sway gently in the wind.',
    ),
  ];
  final pdf = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (final (index, object) in objects.indexed) {
    offsets.add(pdf.length);
    pdf.writeln('${index + 1} 0 obj\n$object\nendobj');
  }
  final xref = pdf.length;
  pdf.writeln('xref\n0 ${objects.length + 1}\n0000000000 65535 f ');
  for (final offset in offsets) {
    pdf.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
  }
  pdf.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(pdf.toString().codeUnits);
}
