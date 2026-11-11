import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reading_page.dart';

/// A reading palette, or the system light/dark preference.
enum ThemeChoice {
  system('Auto'),
  day('Day'),
  sepia('Sepia'),
  slate('Slate'),
  night('Night'),
  mocha('Mocha'),
  forest('Forest'),
  ink('Ink');

  const ThemeChoice(this.label);
  final String label;

  Paper? get paper => switch (this) {
    ThemeChoice.system => null,
    ThemeChoice.day => Paper.day,
    ThemeChoice.sepia => Paper.sepia,
    ThemeChoice.slate => Paper.slate,
    ThemeChoice.night => Paper.night,
    ThemeChoice.mocha => Paper.mocha,
    ThemeChoice.forest => Paper.forest,
    ThemeChoice.ink => Paper.midnight,
  };

  IconData get icon => switch (this) {
    ThemeChoice.system => Icons.brightness_auto_outlined,
    _ when paper!.isDark => Icons.dark_mode_outlined,
    _ => Icons.light_mode_outlined,
  };

  String get description => switch (this) {
    ThemeChoice.system => 'Follow your device appearance',
    ThemeChoice.day => 'Warm paper, dark ink',
    ThemeChoice.sepia => 'Soft cream, easy on the eyes',
    ThemeChoice.slate => 'Cool grey, low glare',
    ThemeChoice.night => 'Deep blue-black for late reading',
    ThemeChoice.mocha => 'Warm espresso with amber text',
    ThemeChoice.forest => 'Dark green with a soft glow',
    ThemeChoice.ink => 'True black for OLED screens',
  };

  static ThemeChoice fromName(String? name) => switch (name) {
    'day' => ThemeChoice.day,
    'sepia' => ThemeChoice.sepia,
    'slate' => ThemeChoice.slate,
    'night' => ThemeChoice.night,
    'mocha' => ThemeChoice.mocha,
    'forest' => ThemeChoice.forest,
    'ink' || 'midnight' => ThemeChoice.ink,
    _ => ThemeChoice.system,
  };
}

/// Holds the reading palette so the library and every open book share it.
class ReaderThemeController extends ChangeNotifier {
  ReaderThemeController(this._choice);

  static const _preference = 'reader.paper';

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  ThemeChoice _choice;
  bool _disposed = false;

  ThemeChoice get choice => _choice;

  static Future<ReaderThemeController> load() async {
    String? stored;
    try {
      stored = await SharedPreferencesAsync().getString(_preference);
    } catch (_) {
      // Start with Auto when the preference store is unavailable.
    }
    return ReaderThemeController(ThemeChoice.fromName(stored));
  }

  Paper paperFor(Brightness brightness) =>
      _choice.paper ??
      (brightness == Brightness.dark ? Paper.night : Paper.day);

  ThemeMode get mode => switch (_choice) {
    ThemeChoice.system => ThemeMode.system,
    _ when _choice.paper!.isDark => ThemeMode.dark,
    _ => ThemeMode.light,
  };

  ThemeData themeFor(Brightness brightness) => paperFor(brightness).theme;

  Future<void> setChoice(ThemeChoice choice) async {
    if (_choice == choice) return;
    _choice = choice;
    if (!_disposed) notifyListeners();
    try {
      await _prefs.setString(_preference, choice.name);
    } catch (_) {
      // The palette still applies for this session.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Theme chips shared by the library sheet and the reader appearance sheet.
class ThemeChooser extends StatelessWidget {
  const ThemeChooser({super.key, required this.controller, this.onChanged});

  final ReaderThemeController controller;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final choice in ThemeChoice.values)
          ChoiceChip(
            avatar: Icon(choice.icon, size: 17),
            label: Text(choice.label),
            selected: controller.choice == choice,
            onSelected: (_) {
              unawaited(controller.setChoice(choice));
              onChanged?.call();
            },
          ),
      ],
    ),
  );
}

/// A standalone theme sheet for the library, where no book is open yet.
Future<void> showReadingThemeSheet(
  BuildContext context,
  ReaderThemeController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final paper = controller.paperFor(
        MediaQuery.platformBrightnessOf(context),
      );
      return Theme(
        data: paper.theme,
        child: Material(
          color: paper.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Reading theme',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(color: paper.ink),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Choose a page colour for every book. Auto follows your '
                    'device appearance.',
                    style: TextStyle(color: paper.ink.withValues(alpha: .72)),
                  ),
                  const SizedBox(height: 20),
                  ThemeChooser(controller: controller),
                  const SizedBox(height: 20),
                  _ThemePreview(paper: paper, choice: controller.choice),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  ),
);

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.paper, required this.choice});

  final Paper paper;
  final ThemeChoice choice;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: paper.background,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: paper.ink.withValues(alpha: .16)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          choice.label,
          style: TextStyle(
            color: paper.accent,
            fontSize: 12,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'The garden was quiet, and the whole house seemed to be listening.',
          style: TextStyle(
            color: paper.ink,
            fontFamilyFallback: serif,
            fontSize: 20,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}
