import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_reader/narration.dart';
import 'package:relay_reader/reader_preferences.dart';
import 'package:relay_reader/settings_screen.dart';
import 'package:relay_reader/theme.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test('Kokoro voice presets retain voice identities and visibly match applied settings', () {
    const settings = VoiceSettings(volume: .4, characterVoices: false);
    expect(
      narrationPresets(settings).keys,
      containsAll(['Warm', 'Natural', 'Clear', 'Bright', 'British', 'Fast']),
    );
    final british = applyNarrationPreset(settings, voicePresets['British']!);
    expect(british.voice, 26);
    expect(british.volume, .4);
    expect(british.characterVoices, isFalse);
    expect(
      isNarrationPresetSelected(british, voicePresets['British']!),
      isTrue,
    );
    expect(
      isNarrationPresetSelected(british, voicePresets['Natural']!),
      isFalse,
    );
  });

  test('Phonon, system and LFM3 presets change pace without changing voice or unsupported controls', () {
    for (final settings in [
      const VoiceSettings(
        engine: VoiceEngine.phonon,
        phononVoice: 'freya',
        volume: .3,
        pauses: .8,
      ),
      const VoiceSettings(engine: VoiceEngine.pocket, pocketVoice: 'marius'),
      const VoiceSettings(
        engine: VoiceEngine.supertonic,
        supertonicVoice: 'F3',
        supertonicLanguage: 'hi',
      ),
      const VoiceSettings(
        engine: VoiceEngine.system,
        systemVoice: 'premium-voice',
        pitch: 1.1,
      ),
      const VoiceSettings(lfm3Narration: true, lfm3Voice: 'male', voice: 16),
    ]) {
      final presets = narrationPresets(settings);
      expect(presets.keys, ['Relaxed', 'Natural', 'Fast']);
      final fast = applyNarrationPreset(settings, presets['Fast']!);
      expect(fast.speed, 1.22);
      expect(fast.engine, settings.engine);
      expect(fast.phononVoice, settings.phononVoice);
      expect(fast.pocketVoice, settings.pocketVoice);
      expect(fast.supertonicVoice, settings.supertonicVoice);
      expect(fast.supertonicLanguage, settings.supertonicLanguage);
      expect(fast.systemVoice, settings.systemVoice);
      expect(fast.lfm3Voice, settings.lfm3Voice);
      expect(fast.voice, settings.voice);
      expect(fast.volume, settings.volume);
      expect(fast.pauses, settings.pauses);
      expect(fast.pitch, settings.pitch);
      expect(isNarrationPresetSelected(fast, presets['Fast']!), isTrue);
      expect(isNarrationPresetSelected(fast, presets['Natural']!), isFalse);
      expect(
        presets.values.where(
          (preset) => isNarrationPresetSelected(fast, preset),
        ),
        hasLength(1),
      );
    }
  });

  testWidgets(
    'Phonon playback preset chips can be selected with clear feedback',
    (tester) async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = ReaderPreferences();
      await preferences.load();
      preferences.voice = const VoiceSettings(
        engine: VoiceEngine.phonon,
        phononVoice: 'freya',
      );
      final theme = ReaderThemeController(ThemeChoice.day);
      addTearDown(() {
        preferences.dispose();
        theme.dispose();
        SharedPreferencesAsyncPlatform.instance = previous;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(preferences: preferences, theme: theme),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Playback presets'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'British'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Fast'));
      await tester.pumpAndSettle();
      expect(preferences.voice.speed, 1.22);
      expect(preferences.voice.phononVoice, 'freya');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Fast'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Relaxed'));
      await tester.pumpAndSettle();
      expect(preferences.voice.speed, .85);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Relaxed'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Fast'))
            .selected,
        isFalse,
      );
    },
  );
}
