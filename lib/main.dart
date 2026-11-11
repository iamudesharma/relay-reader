import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';

import 'lfm3.dart';
import 'library.dart';
import 'narration.dart';
import 'reader.dart';
import 'reading_page.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeNarration();
  try {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LlamaEngineProvider()],
    );
    Lfm3Model.markReady();
  } catch (error) {
    debugPrint('On-device LFM3 is unavailable: $error');
  }
  final theme = await ReaderThemeController.load();
  runApp(RelayReader(theme: theme));
}

class RelayReader extends StatelessWidget {
  const RelayReader({super.key, required this.theme});

  final ReaderThemeController theme;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: theme,
    builder: (context, _) => MaterialApp(
      title: 'Relay Reader',
      theme: theme.themeFor(Brightness.light),
      darkTheme: theme.themeFor(Brightness.dark),
      themeMode: theme.mode,
      home: Bookshelf(theme: theme),
    ),
  );
}

class Bookshelf extends StatefulWidget {
  const Bookshelf({super.key, required this.theme});

  final ReaderThemeController theme;

  @override
  State<Bookshelf> createState() => _BookshelfState();
}

class _BookshelfState extends State<Bookshelf> {
  final _library = Library();
  List<LibraryBook> _books = [];
  ({LibraryBook book, NarrationCheckpoint checkpoint})? _continueListening;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final books = await _library.books();
      final continueListening = await _library.continueListening(books);
      if (mounted) {
        setState(() {
          _books = books;
          _continueListening = continueListening;
        });
      }
    } catch (_) {
      if (mounted) _notice('The local library could not be loaded.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open([LibraryBook? entry, bool resumeNarration = false]) async {
    if (_busy) return;
    setState(() => _busy = true);
    OpenedBook? opened;
    try {
      if (entry == null) {
        final file = await openFile(acceptedTypeGroups: [bookTypes]);
        if (file == null || !mounted) return;
        opened = await _library.import(file);
      } else {
        opened = await _library.open(entry);
      }
      final position = await _library.position(opened.entry);
      final bookmark = await _library.bookmark(opened.entry);
      if (!mounted) return;
      final book = opened;
      final closed = Completer<void>();
      final route = MaterialPageRoute<void>(
        builder: (_) => Reader(
          book: book,
          library: _library,
          theme: widget.theme,
          position: position,
          bookmark: bookmark,
          resumeNarration: resumeNarration,
          onClosed: closed.complete,
        ),
      );
      final navigation = Navigator.of(context).push(route);
      opened = null;
      await navigation;
      await route.completed;
      await closed.future;
      await _load();
    } on BookFailure catch (error) {
      if (mounted) await _failure(error);
    } catch (_) {
      if (mounted) _notice('The file could not be opened.');
    } finally {
      await opened?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(LibraryBook book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove local copy?'),
        content: Text(
          '“${book.title}” and its reading position will be removed from this library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _library.remove(book);
      await _load();
    } on BookFailure catch (error) {
      if (mounted) _notice(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _failure(BookFailure error) async {
    final copy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This book could not be opened'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(error.message),
              if (error.details case final details?) ...[
                const SizedBox(height: 16),
                Text('Details', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                SelectableText(
                  details,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (error.details != null)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Copy details'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (copy == true) {
      await Clipboard.setData(
        ClipboardData(text: '${error.message}\n\n${error.details ?? ''}'),
      );
      if (mounted) _notice('Error details copied.');
    }
  }

  @override
  void dispose() {
    unawaited(_library.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final continueListening = _continueListening;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Relay Reader'),
        actions: [
          IconButton(
            tooltip: 'Reading theme',
            onPressed: () => showReadingThemeSheet(context, widget.theme),
            icon: const Icon(Icons.palette_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              tooltip: 'Import a book',
              onPressed: _busy ? null : _open,
              icon: const Icon(Icons.add),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        constraints.maxWidth < 600 ? 24 : 48,
                        32,
                        constraints.maxWidth < 600 ? 24 : 48,
                        24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Library',
                            style: TextStyle(
                              fontSize: constraints.maxWidth < 600 ? 45 : 62,
                              fontFamilyFallback: serif,
                              height: 1.04,
                              letterSpacing: -1.8,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Your books stay on this device.',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (continueListening != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          constraints.maxWidth < 600 ? 24 : 48,
                          0,
                          constraints.maxWidth < 600 ? 24 : 48,
                          24,
                        ),
                        child: _ContinueListeningCard(
                          book: continueListening.book,
                          checkpoint: continueListening.checkpoint,
                          onResume: _busy
                              ? null
                              : () => _open(continueListening.book, true),
                        ),
                      ),
                    ),
                  if (_busy)
                    const SliverToBoxAdapter(child: LinearProgressIndicator()),
                  if (_books.isEmpty && !_busy)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(
                          constraints.maxWidth < 600 ? 24 : 48,
                        ),
                        child: _EmptyShelf(onImport: _open),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: constraints.maxWidth < 600 ? 24 : 48,
                    ),
                    sliver: SliverList.builder(
                      itemCount: _books.length,
                      itemBuilder: (context, index) {
                        final book = _books[index];
                        return Column(
                          children: [
                            const Divider(height: 1),
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 8,
                              ),
                              leading: _BookSpine(book.format),
                              title: Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                book.author.isEmpty
                                    ? book.format.name.toUpperCase()
                                    : book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: _busy ? null : () => _open(book),
                              trailing: PopupMenuButton(
                                tooltip: 'Book options',
                                enabled: !_busy,
                                onSelected: (_) => _remove(book),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Remove from library'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContinueListeningCard extends StatelessWidget {
  const _ContinueListeningCard({
    required this.book,
    required this.checkpoint,
    required this.onResume,
  });

  final LibraryBook book;
  final NarrationCheckpoint checkpoint;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final unit = book.format == BookFormat.epub ? 'Chapter' : 'Page';
    return Material(
      color: colors.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onResume,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.graphic_eq,
                  color: colors.onPrimary,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CONTINUE LISTENING',
                      style: TextStyle(
                        color: colors.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$unit ${checkpoint.section + 1} · '
                      '${_ago(checkpoint.updated)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (checkpoint.passage.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '“${checkpoint.passage}”',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: onResume,
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(14),
                ),
                child: const Icon(Icons.play_arrow),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} h ago';
    return '${difference.inDays} d ago';
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.menu_book_rounded, color: colors.primary, size: 32),
            const SizedBox(height: 20),
            Text(
              'A place for your books',
              style: TextStyle(
                fontSize: 25,
                fontFamilyFallback: serif,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            const Text('Open an EPUB, PDF, or TXT file to start reading.'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add),
              label: const Text('Import a book'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookSpine extends StatelessWidget {
  const _BookSpine(this.format);
  final BookFormat format;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final icon = switch (format) {
      BookFormat.epub => Icons.auto_stories_outlined,
      BookFormat.pdf => Icons.picture_as_pdf_outlined,
      BookFormat.txt => Icons.notes_rounded,
    };
    return Container(
      width: 43,
      height: 56,
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
        border: Border(left: BorderSide(color: colors.primary, width: 4)),
      ),
      child: Icon(icon, color: colors.onSecondaryContainer, size: 22),
    );
  }
}
