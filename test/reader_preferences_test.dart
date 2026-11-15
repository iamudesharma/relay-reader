import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:relay_reader/main.dart';
import 'package:relay_reader/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/reader_preferences.dart';
import 'package:relay_reader/pocket_tts.dart';
import 'package:relay_reader/supertonic.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  test('fresh preferences use Supertonic on supported devices without loading models', () async {
    final preferences = ReaderPreferences();
    expect(preferences.voice.engine, VoiceEngine.platformDefault);
    await preferences.load();
    expect(
      preferences.voice.engine,
      SupertonicModel.supported ? VoiceEngine.supertonic : VoiceEngine.kokoro,
    );
    expect(preferences.voice.supertonicVoice, 'M1');
    expect(preferences.voice.supertonicLanguage, 'en');
    preferences.dispose();
  });

  test(
    'saved Kokoro and legacy voice-only preferences retain the chosen narrator',
    () async {
      final store = SharedPreferencesAsync();
      for (final key in ['reader.voice', 'reader.voice.v1']) {
        await store.setInt(key, 6);
        final preferences = ReaderPreferences();
        await preferences.load();
        expect(preferences.voice.engine, VoiceEngine.kokoro);
        preferences.dispose();
        await store.remove(key);
      }
      await store.setString('reader.engine', 'kokoro');
      final preferences = ReaderPreferences();
      await preferences.load();
      expect(preferences.voice.engine, VoiceEngine.kokoro);
      await preferences.save();
      expect(await store.getString('reader.engine'), 'kokoro');
      preferences.dispose();
    },
  );
  test(
    'existing app preference keys migrate without changing book data',
    () async {
      final store = SharedPreferencesAsync();
      await store.setInt('reader.voice', 6);
      await store.setDouble('reader.speed', 1.3);
      await store.setDouble('reader.font', 26);
      await store.setString('reader.engine', 'system');
      await store.setString('reader.systemVoice', 'premium-voice');
      await store.setBool('reader.lfm3', true);
      await store.setString('cast.book-one', 'book-specific-cast');
      await store.setString('narration.book-one', 'book-checkpoint');
      final preferences = ReaderPreferences();
      await preferences.load();
      expect(preferences.voice.voice, upgradedVoice(6));
      expect(preferences.voice.speed, 1.3);
      expect(
        preferences.voice.engine,
        SystemVoices.supported ? VoiceEngine.system : VoiceEngine.kokoro,
      );
      expect(preferences.voice.systemVoice, 'premium-voice');
      expect(preferences.fontSize, 26);
      expect(preferences.lfm3Enabled, isTrue);
      await preferences.save();
      expect(await store.getString('cast.book-one'), 'book-specific-cast');
      expect(await store.getString('narration.book-one'), 'book-checkpoint');
      preferences.dispose();
    },
  );

  test(
    'shared settings publish immediately and persist the latest rapid change',
    () async {
      final shared = ReaderPreferences();
      await shared.load();
      var notifications = 0;
      shared.addListener(() => notifications++);
      shared.voice = shared.voice.withChanges(voice: 6, speed: 1.2);
      final first = shared.save();
      expect(notifications, 1);
      shared.voice = shared.voice.withChanges(voice: 16, speed: 1.6);
      shared.fontSize = 28;
      final second = shared.save();
      expect(notifications, 2);
      await Future.wait([first, second]);
      final reopened = ReaderPreferences();
      await reopened.load();
      expect(reopened.voice.voice, 16);
      expect(reopened.voice.speed, 1.6);
      expect(reopened.fontSize, 28);
      shared.dispose();
      reopened.dispose();
    },
  );
  test(
    'unsupported saved engines fall back to a usable settings selection',
    () async {
      await SharedPreferencesAsync().setString(
        'reader.engine',
        'not-an-engine',
      );
      final preferences = ReaderPreferences();
      await preferences.load();
      expect(preferences.voice.engine, VoiceEngine.kokoro);
      preferences.dispose();
    },
  );

  test(
    'Pocket voice persists independently of existing narrator and cast keys',
    () async {
      final store = SharedPreferencesAsync();
      await store.setString('cast.book-one', 'saved-cast');
      await store.setString('reader.phononVoice', 'freya');
      final preferences = ReaderPreferences();
      await preferences.load();
      preferences.voice = preferences.voice.withChanges(
        engine: VoiceEngine.pocket,
        pocketVoice: 'marius',
        voice: 26,
        speed: 1.3,
      );
      await preferences.save();
      final reopened = ReaderPreferences();
      await reopened.load();
      expect(
        reopened.voice.engine,
        PocketTts.supported ? VoiceEngine.pocket : VoiceEngine.kokoro,
      );
      expect(reopened.voice.pocketVoice, 'marius');
      expect(reopened.voice.voice, 26);
      expect(reopened.voice.phononVoice, 'freya');
      expect(reopened.voice.speed, 1.3);
      expect(await store.getString('cast.book-one'), 'saved-cast');
      reopened.voice = reopened.voice.withChanges(engine: VoiceEngine.kokoro);
      await reopened.save();
      expect(await store.getString('reader.pocketVoice'), 'marius');
      preferences.dispose();
      reopened.dispose();
    },
  );

  test(
    'unknown Pocket voice falls back without changing saved Kokoro voice',
    () async {
      final store = SharedPreferencesAsync();
      await store.setString('reader.pocketVoice', 'missing');
      await store.setInt('reader.voice.v1', 16);
      final preferences = ReaderPreferences();
      await preferences.load();
      expect(preferences.voice.pocketVoice, 'alba');
      expect(preferences.voice.voice, 16);
      preferences.dispose();
    },
  );

  test(
    'model transfer state survives a settings route closing and reopening',
    () {
      final preferences = ReaderPreferences();
      var preferenceEvents = 0;
      preferences.addListener(() => preferenceEvents++);
      preferences.transfers.update(
        'phonon',
        active: true,
        received: 1024,
        total: 4096,
      );
      // A new Settings route reads the same active transfer, without another request.
      expect(preferences.transfers.state('phonon').active, isTrue);
      expect(preferences.transfers.state('phonon').received, 1024);
      preferences.transfers.update(
        'phonon',
        ready: true,
        active: false,
        received: 4096,
      );
      expect(preferences.transfers.state('phonon').ready, isTrue);
      expect(preferences.transfers.state('phonon').active, isFalse);
      expect(
        preferenceEvents,
        0,
      ); // Progress never rebuilds or restarts narration.
      preferences.dispose();
    },
  );

  test(
    'Supertonic voice and language persist independently of existing engines',
    () async {
      final store = SharedPreferencesAsync();
      await store.setString('reader.phononVoice', 'freya');
      await store.setString('reader.pocketVoice', 'marius');
      await store.setString('cast.book-one', 'saved-cast');
      final preferences = ReaderPreferences();
      await preferences.load();
      preferences.voice = preferences.voice.withChanges(
        engine: VoiceEngine.supertonic,
        supertonicVoice: 'F3',
        supertonicLanguage: 'hi',
        voice: 26,
        lfm3Narration: true,
      );
      await preferences.save();
      final reopened = ReaderPreferences();
      await reopened.load();
      expect(
        reopened.voice.engine,
        SupertonicModel.supported ? VoiceEngine.supertonic : VoiceEngine.kokoro,
      );
      expect(reopened.voice.supertonicVoice, 'F3');
      expect(reopened.voice.supertonicLanguage, 'hi');
      expect(reopened.voice.lfm3Narration, isFalse);
      expect(reopened.voice.voice, 26);
      expect(reopened.voice.phononVoice, 'freya');
      expect(reopened.voice.pocketVoice, 'marius');
      expect(await store.getString('cast.book-one'), 'saved-cast');
      await store.setString('reader.supertonicVoice', 'missing');
      await store.setString('reader.supertonicLanguage', 'unknown');
      final invalid = ReaderPreferences();
      await invalid.load();
      expect(invalid.voice.supertonicVoice, 'M1');
      expect(invalid.voice.supertonicLanguage, 'en');
      preferences.dispose();
      reopened.dispose();
      invalid.dispose();
    },
  );

  testWidgets('library exposes shared settings without a book', (tester) async {
    final theme = ReaderThemeController(ThemeChoice.day);
    addTearDown(theme.dispose);
    await tester.pumpWidget(MaterialApp(home: Bookshelf(theme: theme)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Narration'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Cast'), findsNothing);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Text size ·'), findsOneWidget);
    expect(find.text('Darken PDF pages'), findsOneWidget);
  });
}
