import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_reader/library.dart';
import 'package:relay_reader/phonon.dart';
import 'package:relay_reader/reader.dart';
import 'package:relay_reader/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phonon narrates an English passage on this Mac', (tester) async {
    expect(PhononNarration.supported, isTrue);
    expect(await PhononModel.isInstalled(), isTrue);

    final voices = await PhononNarration.voices(refresh: true);
    expect(voices, isNotEmpty);

    final directory = await Directory.systemTemp.createTemp('relay-phonon-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/speech.wav';
    await PhononNarration.synthesizeToFile(
      text: 'In the morning the garden was quiet, and the house was listening.',
      path: path,
      voice: voices.first,
    );
    final wav = File(path);
    expect(await wav.exists(), isTrue);
    expect(await wav.length(), greaterThan(44));
    await PhononNarration.unload();
  });

  testWidgets('Phonon is available as an opt-in experimental engine', (
    tester,
  ) async {
    final library = Library();
    addTearDown(library.close);
    final theme = ReaderThemeController(ThemeChoice.day);
    addTearDown(theme.dispose);
    final book = OpenedBook(
      const LibraryBook(
        'phonon-smoke',
        'Phonon smoke test',
        '',
        BookFormat.txt,
      ),
      text: 'A quiet room. A story begins.',
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
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Read aloud settings'));
    await tester.pumpAndSettle();
    expect(find.text('Phonon'), findsOneWidget);
    await tester.tap(find.text('Phonon'));
    await tester.pumpAndSettle();
    expect(find.text('Experimental · Phonon narrator'), findsOneWidget);
    expect(
      find.text('Download').evaluate().isNotEmpty ||
          find.text('Load voices').evaluate().isNotEmpty ||
          find.text('Phonon voice').evaluate().isNotEmpty,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
