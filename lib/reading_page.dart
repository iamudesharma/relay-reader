import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';

const serif = ['Georgia', 'Noto Serif', 'Times New Roman', 'serif'];

enum Paper {
  day('Day', Color(0xfffaf9f5), Color(0xff22241d), Color(0xff3d5b46)),
  sepia('Sepia', Color(0xfff1e5cb), Color(0xff392e22), Color(0xff685031)),
  slate('Slate', Color(0xff252c38), Color(0xffedf0f7), Color(0xffbdcff6)),
  night('Night', Color(0xff171b20), Color(0xffe8ebef), Color(0xffbccfe7)),
  mocha('Mocha', Color(0xff1b1410), Color(0xfff3e7db), Color(0xffe0ad78)),
  forest('Forest', Color(0xff0c1511), Color(0xffe4efe7), Color(0xff93c9a5)),
  midnight('Ink', Color(0xff08090b), Color(0xffededee), Color(0xffcbd9ec));

  const Paper(this.label, this.background, this.ink, this.accent);
  final String label;
  final Color background;
  final Color ink;
  final Color accent;

  bool get isDark => index >= Paper.slate.index;

  ThemeData get theme {
    final colors = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: isDark ? Brightness.dark : Brightness.light,
      surface: background,
      onSurface: ink,
      primary: accent,
    );
    return ThemeData(
      colorScheme: colors,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      dividerColor: ink.withValues(alpha: .14),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? const Color(0xff2b3038) : ink,
        contentTextStyle: TextStyle(color: isDark ? ink : background),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class ReadingPage extends StatelessWidget {
  const ReadingPage({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
  });
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.builder(
          controller: controller,
          padding: EdgeInsets.symmetric(
            horizontal: constraints.maxWidth < 520 ? 24 : 48,
            vertical: 32,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        ),
      ),
    ),
  );
}

@Preview(name: 'Reader on a phone', size: Size(375, 667))
@Preview(name: 'Reader on a wide display', size: Size(1100, 680))
Widget readingPagePreview() => _paperPreview(Paper.day);

@Preview(name: 'Reader in Ink', size: Size(375, 667))
Widget inkReadingPreview() => _paperPreview(Paper.midnight);

Widget _paperPreview(Paper paper) => MaterialApp(
  theme: paper.theme,
  home: Scaffold(
    appBar: AppBar(title: const Text('A quiet chapter')),
    body: ReadingPage(
      itemCount: 1,
      itemBuilder: (_, _) => const Text(
        'There was a little garden at the back of the house. '
        'In the morning, its stone walls held the last of the night’s coolness.',
        style: TextStyle(fontFamilyFallback: serif, fontSize: 22, height: 1.65),
      ),
    ),
  ),
);
