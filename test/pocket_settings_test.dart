import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/reader_preferences.dart';
import 'package:relay_reader/settings_screen.dart';
import 'package:relay_reader/theme.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'listening_features_test.dart' show TestPlayer;

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  testWidgets(
    'Pocket selection, voices and deletion preserve Kokoro settings on small screens',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('relay-pocket-settings-'),
      ))!;
      final previousPaths = PathProviderPlatform.instance;
      final previousPreferences = SharedPreferencesAsyncPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = ReaderPreferences();
      await preferences.load();
      preferences.voice = const VoiceSettings(voice: 26, lfm3Narration: true);
      final theme = ReaderThemeController(ThemeChoice.day);
      final narrator = Narrator(
        player: TestPlayer(),
        previewPlayer: TestPlayer(),
        configureAudioSession: () async {},
      );
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        await tester.runAsync(narrator.close);
        preferences.dispose();
        theme.dispose();
        PathProviderPlatform.instance = previousPaths;
        SharedPreferencesAsyncPlatform.instance = previousPreferences;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            preferences: preferences,
            theme: theme,
            narrator: narrator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Pocket TTS'));
      await tester.pumpAndSettle();
      expect(preferences.voice.engine, VoiceEngine.pocket);
      expect(preferences.voice.voice, 26);
      expect(preferences.voice.lfm3Narration, isFalse);
      expect(find.text('Download Pocket TTS'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Preview voice'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Character voices'),
            )
            .onChanged,
        isNull,
      );
      expect(tester.takeException(), isNull);
      // Exercise installed UI without fetching weights in a widget test.
      preferences.transfers.update('pocket', ready: true);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('pocket-alba')));
      await tester.tap(find.byKey(const ValueKey('pocket-alba')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marius').last);
      await tester.pumpAndSettle();
      expect(preferences.voice.pocketVoice, 'marius');
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Kokoro'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Kokoro'));
      await tester.pumpAndSettle();
      expect(preferences.voice.voice, 26);
      expect(preferences.voice.pocketVoice, 'marius');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Pocket TTS'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(667, 375);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final marker = File('${root.path}/mediapipe/kokoro/keep.txt');
      await tester.runAsync(() async {
        await marker.parent.create(recursive: true);
        await marker.writeAsString('keep');
      });
      await tester.ensureVisible(find.text('Delete Pocket TTS model'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Delete Pocket TTS model'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(preferences.transfers.state('pocket').ready, isFalse);
      expect(preferences.voice.engine, VoiceEngine.kokoro);
      expect(preferences.voice.voice, 26);
      expect(await tester.runAsync(marker.exists), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Supertonic selection, language, voices and deletion preserve Kokoro settings on small screens',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('relay-pocket-settings-'),
      ))!;
      final previousPaths = PathProviderPlatform.instance;
      final previousPreferences = SharedPreferencesAsyncPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = ReaderPreferences();
      await preferences.load();
      preferences.voice = const VoiceSettings(voice: 26, lfm3Narration: true);
      final theme = ReaderThemeController(ThemeChoice.day);
      final narrator = Narrator(
        player: TestPlayer(),
        previewPlayer: TestPlayer(),
        configureAudioSession: () async {},
      );
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        await tester.runAsync(narrator.close);
        preferences.dispose();
        theme.dispose();
        PathProviderPlatform.instance = previousPaths;
        SharedPreferencesAsyncPlatform.instance = previousPreferences;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            preferences: preferences,
            theme: theme,
            narrator: narrator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Supertonic 3'));
      await tester.pumpAndSettle();
      expect(preferences.voice.engine, VoiceEngine.supertonic);
      expect(preferences.voice.voice, 26);
      expect(preferences.voice.lfm3Narration, isFalse);
      expect(find.text('Download Supertonic 3'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Preview voice'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Character voices'),
            )
            .onChanged,
        isNull,
      );
      expect(tester.takeException(), isNull);
      // Exercise installed UI without fetching weights in a widget test.
      preferences.transfers.update('supertonic', ready: true);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('supertonic-voice-M1')),
      );
      await tester.tap(find.byKey(const ValueKey('supertonic-voice-M1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Female 2').last);
      await tester.pumpAndSettle();
      expect(preferences.voice.supertonicVoice, 'F2');
      await tester.ensureVisible(
        find.byKey(const ValueKey('supertonic-language-en')),
      );
      await tester.tap(find.byKey(const ValueKey('supertonic-language-en')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arabic').last);
      await tester.pumpAndSettle();
      expect(preferences.voice.supertonicLanguage, 'ar');
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Kokoro'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Kokoro'));
      await tester.pumpAndSettle();
      expect(preferences.voice.voice, 26);
      expect(preferences.voice.supertonicVoice, 'F2');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Supertonic 3'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(667, 375);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final marker = File('${root.path}/mediapipe/kokoro/keep.txt');
      await tester.runAsync(() async {
        await marker.parent.create(recursive: true);
        await marker.writeAsString('keep');
      });
      await tester.ensureVisible(find.text('Delete Supertonic 3 model'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Delete Supertonic 3 model'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(preferences.transfers.state('supertonic').ready, isFalse);
      expect(preferences.voice.engine, VoiceEngine.kokoro);
      expect(preferences.voice.voice, 26);
      expect(await tester.runAsync(marker.exists), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
