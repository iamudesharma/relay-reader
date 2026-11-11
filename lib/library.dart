import 'dart:convert';
import 'dart:io';

import 'package:effect_core/effect_core.dart';
import 'package:epub_rtl/epub_rtl.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'character_voices.dart';
import 'epub_recovery.dart';

const _drmMessage =
    'This EPUB is locked with DRM. Relay Reader can only open '
    'DRM-free EPUBs. Import an unlocked copy.';

const bookTypes = XTypeGroup(
  label: 'Books and documents',
  extensions: ['epub', 'pdf', 'txt'],
  mimeTypes: ['application/epub+zip', 'application/pdf', 'text/plain'],
  uniformTypeIdentifiers: [
    'org.idpf.epub-container',
    'com.adobe.pdf',
    'public.plain-text',
  ],
);

enum BookFormat { epub, pdf, txt }

class LibraryBook {
  const LibraryBook(this.id, this.title, this.author, this.format);

  factory LibraryBook.fromJson(Map<String, dynamic> json) => LibraryBook(
    json['id'] as String,
    json['title'] as String,
    json['author'] as String,
    BookFormat.values.byName(json['format'] as String),
  );

  final String id;
  final String title;
  final String author;
  final BookFormat format;

  Map<String, String> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'format': format.name,
  };
}

class BookFailure implements Exception {
  const BookFailure(this.message, {this.details});
  final String message;

  /// Technical detail shown on request; useful when a book will not open.
  final String? details;

  @override
  String toString() => details == null ? message : '$message ($details)';
}

/// A resumable narration position: section, sentence-sized utterance, and a
/// short passage so the position can still be found if chunking changes.
class NarrationCheckpoint {
  const NarrationCheckpoint({
    required this.section,
    required this.utterance,
    required this.passage,
    required this.playing,
    required this.updated,
  });

  factory NarrationCheckpoint.fromJson(Map<String, dynamic> json) =>
      NarrationCheckpoint(
        section: (json['section'] as num?)?.toInt() ?? 0,
        utterance: (json['utterance'] as num?)?.toInt() ?? 0,
        passage: json['passage'] as String? ?? '',
        playing: json['playing'] as bool? ?? false,
        updated:
            DateTime.tryParse(json['updated'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  final int section;
  final int utterance;
  final String passage;
  final bool playing;
  final DateTime updated;

  NarrationCheckpoint copyWith({
    int? section,
    int? utterance,
    String? passage,
    bool? playing,
    DateTime? updated,
  }) => NarrationCheckpoint(
    section: section ?? this.section,
    utterance: utterance ?? this.utterance,
    passage: passage ?? this.passage,
    playing: playing ?? this.playing,
    updated: updated ?? this.updated,
  );

  Map<String, dynamic> toJson() => {
    'section': section,
    'utterance': utterance,
    'passage': passage.length > 320 ? passage.substring(0, 320) : passage,
    'playing': playing,
    'updated': updated.toIso8601String(),
  };
}

class Library {
  final _runtime = Runtime(Unit.value);
  final _prefs = SharedPreferencesAsync();

  Future<T> _run<T>(Future<T> Function() operation, String message) async {
    final result = await _runtime.runExit(
      Effect.fromFuture<T, BookFailure, Unit>(
        operation,
        onError: (error, _) => error is BookFailure
            ? error
            : BookFailure(message, details: error.toString()),
      ),
    );
    return switch (result) {
      Success(:final value) => value,
      Failure(cause: Expected(:final error)) => throw error,
      Failure() => throw BookFailure(message),
    };
  }

  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/books').create(recursive: true);
  }

  Future<List<LibraryBook>> books() async {
    final data = await _prefs.getStringList('library') ?? [];
    return data
        .map(
          (entry) =>
              LibraryBook.fromJson(jsonDecode(entry) as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> _save(List<LibraryBook> books) =>
      _prefs.setStringList('library', books.map(jsonEncode).toList());

  Future<String> path(LibraryBook book) async =>
      '${(await _directory()).path}/${book.id}.${book.format.name}';

  Future<OpenedBook> import(XFile source) => _run(() async {
    final dot = source.name.lastIndexOf('.');
    final extension = dot < 0
        ? ''
        : source.name.substring(dot + 1).toLowerCase();
    final format = BookFormat.values.asNameMap()[extension];
    if (format == null) {
      throw const BookFailure('Choose an EPUB, PDF, or TXT file.');
    }
    final size = await source.length();
    final limit = format == BookFormat.txt ? 8 : 200;
    if (size == 0 || size > limit * 1024 * 1024) {
      throw BookFailure('Choose a nonempty file smaller than $limit MB.');
    }

    final title = source.name.substring(0, dot).trim();
    final entry = LibraryBook(
      DateTime.now().microsecondsSinceEpoch.toString(),
      title.isEmpty ? 'Untitled book' : title,
      '',
      format,
    );
    final destination = File(await path(entry));
    OpenedBook? opened;
    try {
      try {
        await source.saveTo(destination.path);
      } on FileSystemException catch (failure) {
        throw BookFailure(
          'The file could not be copied from Files. Download a local copy and try again.',
          details: failure.message,
        );
      }
      if (!await destination.exists() || await destination.length() == 0) {
        throw const BookFailure(
          'The file could not be copied from Files. Download a local copy and try again.',
        );
      }
      opened = await _open(entry, destination.path);
      await _save([opened.entry, ...await books()]);
      return opened;
    } catch (_) {
      await opened?.close();
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }, 'This file could not be opened. Try another local copy.');

  Future<OpenedBook> open(LibraryBook entry) => _run(() async {
    final path = await this.path(entry);
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      throw const BookFailure(
        'The saved copy of this book is missing from this device. '
        'Import the book again to read it.',
      );
    }
    return _open(entry, path);
  }, 'This book could not be opened. Try importing it again.');

  Future<OpenedBook?> _recoverEpub(LibraryBook entry, String path) async {
    try {
      final recovered = await recoverEpubText(path);
      if (recovered == null) return null;
      return OpenedBook(entry, text: recovered.text, recovered: true);
    } on DrmProtectedEpub {
      throw const BookFailure(_drmMessage);
    }
  }

  Future<OpenedBook> _open(LibraryBook entry, String path) async {
    switch (entry.format) {
      case BookFormat.pdf:
        await pdfrxFlutterInitialize();
        try {
          final pdf = await PdfDocument.openFile(path);
          if (pdf.pages.isEmpty) {
            await pdf.dispose();
            throw const BookFailure('This PDF has no readable pages.');
          }
          return OpenedBook(entry, pdf: pdf);
        } catch (failure) {
          if (failure is BookFailure) rethrow;
          throw BookFailure(
            'This PDF could not be read. It may be damaged or password '
            'protected. Try another copy.',
            details: failure.toString(),
          );
        }
      case BookFormat.epub:
        EpubBook? epub;
        EpubException? epubFailure;
        Object? unexpectedFailure;
        try {
          // Some readable EPUBs omit navigation or obfuscate only their fonts.
          epub = EpubBook.openFile(path, lenient: true);
          if (epubContentItems(epub).isEmpty) {
            await epub.close();
            epub = null;
          }
        } on EpubException catch (failure) {
          epubFailure = failure;
          await epub?.close();
          epub = null;
        } catch (failure) {
          unexpectedFailure = failure;
          await epub?.close();
          epub = null;
        }

        if (epub != null) {
          final metadata = epub.metadata;
          final title = metadata.title.trim();
          final author = metadata.creators
              .map((person) => person.name)
              .join(', ');
          return OpenedBook(
            LibraryBook(
              entry.id,
              title.isEmpty ? entry.title : title,
              author,
              entry.format,
            ),
            epub: epub,
          );
        }

        if (epubFailure?.kind == EpubErrorKind.encrypted) {
          throw BookFailure(_drmMessage, details: epubFailure!.message);
        }
        final recovered = await _recoverEpub(entry, path);
        if (recovered != null) return recovered;

        throw BookFailure(
          switch (epubFailure?.kind) {
            EpubErrorKind.notZip =>
              'This file is not a valid EPUB archive. It may be incomplete '
                  'or a different format. Download it again and retry.',
            EpubErrorKind.missingContainer ||
            EpubErrorKind.missingPackage ||
            EpubErrorKind.malformedXml ||
            EpubErrorKind.invalidManifest ||
            EpubErrorKind.missingManifestItem =>
              'This EPUB is missing required book data. Try another copy '
                  'or re-download the book.',
            _ => 'This EPUB has no readable chapters. Try another copy.',
          },
          details:
              epubFailure?.message ??
              unexpectedFailure?.toString() ??
              'The package has no XHTML content documents.',
        );
      case BookFormat.txt:
        final text = await File(path).readAsString();
        if (text.trim().isEmpty) {
          throw const BookFailure('This text file has no readable content.');
        }
        return OpenedBook(entry, text: text);
    }
  }

  Future<void> remove(LibraryBook book) => _run(() async {
    final file = File(await path(book));
    if (await file.exists()) await file.delete();
    await _save((await books()).where((entry) => entry.id != book.id).toList());
    await _prefs.remove('page.${book.id}');
    await _prefs.remove('bookmark.${book.id}');
    await _prefs.remove('narration.${book.id}');
    await _prefs.remove('cast.${book.id}');
    await _prefs.remove('attribution.${book.id}');
    if (await _prefs.getString('reader.lastNarration') == book.id) {
      await _prefs.remove('reader.lastNarration');
    }
  }, 'The book could not be removed from this device.');

  Future<int> position(LibraryBook book) async =>
      await _prefs.getInt('page.${book.id}') ?? 0;
  Future<void> savePosition(LibraryBook book, int index) =>
      _prefs.setInt('page.${book.id}', index);
  Future<int?> bookmark(LibraryBook book) =>
      _prefs.getInt('bookmark.${book.id}');
  Future<void> saveBookmark(LibraryBook book, int? index) => index == null
      ? _prefs.remove('bookmark.${book.id}')
      : _prefs.setInt('bookmark.${book.id}', index);

  Future<NarrationCheckpoint?> narration(LibraryBook book) async {
    final raw = await _prefs.getString('narration.${book.id}');
    if (raw == null || raw.isEmpty) return null;
    try {
      return NarrationCheckpoint.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveNarration(
    LibraryBook book,
    NarrationCheckpoint checkpoint,
  ) async {
    await Future.wait([
      _prefs.setString('narration.${book.id}', jsonEncode(checkpoint.toJson())),
      _prefs.setString('reader.lastNarration', book.id),
    ]);
  }

  Future<CharacterCast> cast(LibraryBook book) async =>
      CharacterCast.fromJsonString(await _prefs.getString('cast.${book.id}'));

  Future<void> saveCast(LibraryBook book, CharacterCast cast) =>
      _prefs.setString('cast.${book.id}', cast.toJsonString());

  Future<SectionAttribution?> attribution(
    LibraryBook book,
    int section,
    String hash,
  ) async {
    final raw = await _prefs.getString('attribution.${book.id}');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = SectionAttribution.fromJson(decoded['$section']);
      return value.hash == hash ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAttribution(
    LibraryBook book,
    int section,
    SectionAttribution attribution,
  ) async {
    final key = 'attribution.${book.id}';
    Map<String, dynamic> sections = {};
    try {
      final raw = await _prefs.getString(key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          sections = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {
      sections = {};
    }
    sections['$section'] = attribution.toJson();
    await _prefs.setString(key, jsonEncode(sections));
  }

  Future<void> clearAttribution(LibraryBook book, int section) async {
    final key = 'attribution.${book.id}';
    try {
      final raw = await _prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final sections = Map<String, dynamic>.from(decoded)..remove('$section');
      await _prefs.setString(key, jsonEncode(sections));
    } catch (_) {
      // A failed cleanup only leaves stale suggestions on disk.
    }
  }

  /// The most recently recorded narration checkpoint among [books].
  Future<({LibraryBook book, NarrationCheckpoint checkpoint})?>
  continueListening(List<LibraryBook> books) async {
    final entries = await Future.wait([
      for (final book in books)
        narration(book)
            .then((checkpoint) => (book: book, checkpoint: checkpoint)),
    ]);
    ({LibraryBook book, NarrationCheckpoint checkpoint})? latest;
    for (final entry in entries) {
      final checkpoint = entry.checkpoint;
      if (checkpoint == null) continue;
      if (latest == null ||
          checkpoint.updated.isAfter(latest.checkpoint.updated)) {
        latest = (book: entry.book, checkpoint: checkpoint);
      }
    }
    return latest;
  }

  Future<void> close() => _runtime.shutdown();
}

/// The spine, or a readable fallback for packages that forgot to declare one.
List<EpubSpineItem> epubContentItems(EpubBook epub) {
  if (epub.spine.items.isNotEmpty) return epub.spine.items;
  return [
    for (final item in epub.manifest.values)
      if (item.isXhtml && !item.properties.contains('nav'))
        EpubSpineItem(idref: item.id, item: item),
  ];
}

class OpenedBook {
  OpenedBook(
    this.entry, {
    this.epub,
    this.pdf,
    String? text,
    this.recovered = false,
  }) : textPages = text == null ? null : _textPages(text);

  final LibraryBook entry;
  final EpubBook? epub;
  final PdfDocument? pdf;
  final List<String>? textPages;

  /// True when the EPUB package was damaged and only its text was recovered.
  final bool recovered;
  late final List<EpubSpineItem> _spine = epub == null
      ? const []
      : epubContentItems(epub!);
  int? _chapterIndex;
  EpubChapter? _chapter;

  int get length =>
      pdf?.pages.length ?? (epub == null ? textPages!.length : _spine.length);

  EpubChapter chapter(int index) {
    if (_chapterIndex != index) {
      final item = _spine[index].item;
      final html = epub!.readString(item.href);
      if (html == null) {
        throw EpubException(
          EpubErrorKind.missingResource,
          'Chapter file ${item.href} is missing',
        );
      }
      try {
        _chapter = EpubChapter.parse(
          html,
          path: item.href,
          loadStylesheet: epub!.readString,
        );
      } on Object {
        // One malformed content document should not make the whole book
        // unreadable. Rebuild its visible text as a plain XHTML chapter.
        final readable = htmlToText(html);
        if (readable.isEmpty) rethrow;
        final paragraphs = readable
            .split(RegExp(r'\n+'))
            .where((part) => part.trim().isNotEmpty)
            .map((part) => '<p>${const HtmlEscape().convert(part.trim())}</p>')
            .join();
        _chapter = EpubChapter.parse(
          '<html><body>$paragraphs</body></html>',
          path: item.href,
        );
      }
      _chapterIndex = index;
    }
    return _chapter!;
  }

  /// The reading-order index for [href], used by the table of contents.
  int indexOfHref(String href) {
    final item = epub?.itemByHref(href);
    if (item == null) return -1;
    return _spine.indexWhere((entry) => entry.item.id == item.id);
  }

  Future<String> spokenText(int index) async {
    if (pdf case final document?) {
      return (await document.pages[index].loadText())?.fullText ?? '';
    }
    if (textPages case final pages?) return pages[index];
    return chapter(index).blocks.map(_blockText).join('\n\n');
  }

  Future<void> close() async {
    await epub?.close();
    await pdf?.dispose();
  }
}

String _blockText(EpubBlock block) => switch (block) {
  EpubTextBlock() => block.plainText,
  EpubImageBlock() => block.alt ?? '',
  EpubQuoteBlock() => block.children.map(_blockText).join('\n'),
  EpubListBlock() =>
    block.items.expand((item) => item).map(_blockText).join('\n'),
  EpubTableBlock() =>
    block.rows
        .expand((row) => row.cells)
        .expand((cell) => cell.children)
        .map(_blockText)
        .join('\n'),
  EpubRuleBlock() => '',
};

/// Plain text of an EPUB block, used to find the sentence being narrated.
String blockText(EpubBlock block) => _blockText(block);

List<String> _textPages(String text) {
  const pageSize = 4200;
  final pages = <String>[];
  for (var start = 0; start < text.length;) {
    var end = (start + pageSize).clamp(0, text.length);
    if (end < text.length) {
      final newline = text.lastIndexOf('\n', end);
      final space = text.lastIndexOf(' ', end);
      if (newline > start + pageSize ~/ 2) {
        end = newline + 1;
      } else if (space > start + pageSize ~/ 2) {
        end = space + 1;
      } else if (text.codeUnitAt(end) & 0xfc00 == 0xdc00) {
        end--;
      }
    }
    pages.add(text.substring(start, end).trim());
    start = end;
  }
  return pages.where((page) => page.isNotEmpty).toList();
}
