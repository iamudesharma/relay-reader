import 'dart:convert';

import 'package:archive/archive.dart';

/// Text recovered from an EPUB whose package structure could not be parsed.
///
/// This is a last-resort path: chapters keep their reading order, but the
/// package metadata, styling and table of contents are unavailable.
class RecoveredEpub {
  const RecoveredEpub(this.text, {required this.chapters});
  final String text;
  final int chapters;
}

/// Thrown when a book is recognised as DRM-protected rather than damaged.
class DrmProtectedEpub implements Exception {
  const DrmProtectedEpub();
}

/// Reads the XHTML entries of [path] as plain text.
///
/// Returns null when the file is not a readable ZIP or contains no text.
/// Throws [DrmProtectedEpub] for common DRM sidecar files.
Future<RecoveredEpub?> recoverEpubText(String path) async {
  InputFileStream? stream;
  try {
    stream = InputFileStream(path);
    final archive = ZipDecoder().decodeStream(stream);
    final files = [
      for (final file in archive.files)
        if (file.isFile) file,
    ];
    if (files.isEmpty) return null;
    final names = files.map((file) => file.name.toLowerCase()).toList();
    if (names.any(_drmMarkers.contains)) throw const DrmProtectedEpub();

    final content = [
      for (final file in files)
        if (_isContentDocument(file.name)) file,
    ];
    if (content.isEmpty) return null;

    final buffer = StringBuffer();
    var chapters = 0;
    for (final file in content) {
      final out = OutputMemoryStream();
      try {
        file.decompress(out);
      } on Object {
        continue;
      }
      final text = htmlToText(
        utf8.decode(out.getBytes(), allowMalformed: true),
      );
      if (text.length < 20) continue;
      chapters++;
      buffer
        ..writeln(text)
        ..writeln();
    }
    if (chapters == 0) return null;
    return RecoveredEpub(buffer.toString().trim(), chapters: chapters);
  } on DrmProtectedEpub {
    rethrow;
  } on Object {
    return null;
  } finally {
    stream?.closeSync();
  }
}

const _drmMarkers = {'meta-inf/rights.xml', 'meta-inf/sinf.xml'};

bool _isContentDocument(String name) {
  final lower = name.toLowerCase();
  if (!(lower.endsWith('.xhtml') ||
      lower.endsWith('.html') ||
      lower.endsWith('.htm'))) {
    return false;
  }
  final file = lower.split('/').last;
  return file != 'nav.xhtml' &&
      file != 'nav.html' &&
      file != 'toc.xhtml' &&
      file != 'toc.html' &&
      !file.contains('cover');
}

/// A forgiving HTML-to-text conversion for damaged EPUB content documents.
String htmlToText(String html) {
  var text = html
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
      .replaceAll(
        RegExp(
          r'<(script|style|head|svg|template)\b[^>]*>.*?</\1\s*>',
          caseSensitive: false,
          dotAll: true,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(
          r'</(p|div|section|article|h[1-6]|li|blockquote|tr|td|th|pre|figure|figcaption|dt|dd)\s*>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  text = text
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]{1,6});'),
        (match) => _codePoint(int.tryParse(match[1]!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#([0-9]{1,7});'),
        (match) => _codePoint(int.tryParse(match[1]!)),
      );
  for (final entity in _entities.entries) {
    text = text.replaceAll(entity.key, entity.value);
  }
  return text
      .replaceAll(RegExp(r'[ \t\f\v]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _codePoint(int? value) {
  if (value == null || value < 0 || value > 0x10ffff) return ' ';
  return String.fromCharCode(value);
}

const _entities = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&mdash;': '—',
  '&ndash;': '–',
  '&hellip;': '…',
  '&lsquo;': '‘',
  '&rsquo;': '’',
  '&ldquo;': '“',
  '&rdquo;': '”',
  '&copy;': '©',
  '&reg;': '®',
  '&trade;': '™',
};
