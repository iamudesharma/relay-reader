import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:epub_rtl/epub_rtl.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'character_voices.dart';
import 'lfm3.dart';
import 'lfm3_audio.dart';
import 'library.dart';
import 'narration.dart';
import 'phonon.dart';
import 'reading_page.dart';
import 'text_highlight.dart';
import 'theme.dart';

class Reader extends StatefulWidget {
  const Reader({
    super.key,
    required this.book,
    required this.library,
    required this.theme,
    required this.position,
    required this.bookmark,
    this.resumeNarration = false,
    this.onClosed,
  });
  final OpenedBook book;
  final Library library;
  final ReaderThemeController theme;
  final int position;
  final int? bookmark;
  final bool resumeNarration;
  final VoidCallback? onClosed;

  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader> {
  final _narrator = Narrator();
  PageController? _pdfController;
  final _prefs = SharedPreferencesAsync();
  late int _index;
  int? _bookmark;
  double _fontSize = 21;
  double _lineHeight = 1.65;
  bool _changing = false;
  bool _darkPdfPages = true;
  bool _zoomedPdf = false;
  bool _backgroundPlayback = true;
  bool _continueToEnd = true;
  bool _previewing = false;
  bool _scanningCast = false;
  List<SystemVoice> _systemVoices = const [];
  bool _loadingSystemVoices = false;
  bool _lfm3Enabled = false;
  bool _lfm3Ready = false;
  bool _lfm3Downloading = false;
  bool _lfm3Analyzing = false;
  bool _lfm3Loaded = false;
  int _lfm3Received = 0;
  int _lfm3Total = Lfm3Model.expectedBytes;
  bool _lfm3AudioReady = false;
  bool _lfm3AudioDownloading = false;
  int _lfm3AudioReceived = 0;
  int _lfm3AudioTotal = Lfm3AudioModel.totalBytes;
  bool _phononReady = false;
  bool _phononDownloading = false;
  bool _phononLoadingVoices = false;
  int _phononReceived = 0;
  int _phononTotal = PhononModel.zipBytes;
  List<String> _phononVoices = const [];
  CharacterCast _cast = const CharacterCast();
  NarrationCheckpoint? _resume;
  final _textScroll = ScrollController();
  final _highlightedBlockKey = GlobalKey();
  String? _lastScrolledPassage;
  Timer? _narrationSaveTimer;
  late final AppLifecycleListener _lifecycle;
  Timer? _positionTimer;
  final Map<int, String> _chapterTitles = {};

  OpenedBook get book => widget.book;
  bool get _isPdf => book.pdf != null;
  String get _unit => book.epub != null ? 'Chapter' : 'Page';
  int get _length => book.length;
  Paper get _paper =>
      widget.theme.paperFor(MediaQuery.platformBrightnessOf(context));

  @override
  void initState() {
    super.initState();
    _index = widget.position.clamp(0, _length - 1);
    _bookmark = widget.bookmark;
    if (_isPdf) _pdfController = PageController(initialPage: _index);
    widget.theme.addListener(_themeChanged);
    _narrator.addListener(_narratorChanged);
    _lifecycle = AppLifecycleListener(
      onPause: () {
        unawaited(_persistNarration());
        if (!_backgroundPlayback) unawaited(_narrator.pause());
      },
    );
    if (book.epub case final epub?) {
      void addTitles(List<EpubNavItem> items) {
        for (final item in items) {
          final href = item.href;
          if (href != null && !EpubPath.isExternal(href)) {
            final index = book.indexOfHref(href);
            if (index >= 0) _chapterTitles.putIfAbsent(index, () => item.title);
          }
          addTitles(item.children);
        }
      }

      addTitles(epub.navigation.toc);
    }
    unawaited(_initialize());
    if (book.recovered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _notice(
            'This EPUB was opened in text-only mode because part of its '
            'structure is missing.',
          );
        }
      });
    }
  }

  void _themeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    await _loadPreferences();
    await Future.wait([
      _loadNarration(),
      _loadCast(),
      if (SystemVoices.supported) _loadSystemVoices(),
      _checkLfm3(),
    ]);
    if (!mounted) return;
    if (widget.resumeNarration && _resume != null) {
      final section = _resume!.section.clamp(0, _length - 1);
      setState(() => _index = section);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final controller = _pdfController;
        if (controller != null && controller.hasClients) {
          controller.jumpToPage(section);
        }
        if (_narrator.state == SpeechState.idle) _play();
      });
    }
  }

  Future<void> _loadNarration() async {
    try {
      final checkpoint = await widget.library.narration(book.entry);
      if (mounted && checkpoint != null) {
        setState(() => _resume = checkpoint);
      }
    } catch (_) {
      // A missing checkpoint only means narration starts from the page.
    }
  }

  Future<void> _loadCast() async {
    try {
      final cast = await widget.library.cast(book.entry);
      if (mounted) setState(() => _cast = cast);
    } catch (_) {
      // An empty cast is still a valid one.
    }
  }

  Future<void> _saveCast() async {
    try {
      await widget.library.saveCast(book.entry, _cast);
    } catch (_) {
      // Cast changes apply for this session even if persistence fails.
    }
  }

  void _narratorChanged() {
    if (_narrator.state == SpeechState.idle) {
      _lastScrolledPassage = null;
    }
    final checkpoint = _resume;
    if (checkpoint == null) return;
    final playing = _narrator.state == SpeechState.playing;
    if (checkpoint.playing != playing) {
      _resume = checkpoint.copyWith(playing: playing, updated: DateTime.now());
      _scheduleNarrationSave();
    }
  }

  void _narrationProgress(int section, int utterance, SpeechUtterance speech) {
    if (section != _resume?.section) {
      _lastScrolledPassage = null;
    }
    _resume = NarrationCheckpoint(
      section: section,
      utterance: utterance,
      passage: speech.text,
      playing: true,
      updated: DateTime.now(),
    );
    _scheduleNarrationSave();
  }

  void _scheduleNarrationSave() {
    _narrationSaveTimer?.cancel();
    _narrationSaveTimer = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_persistNarration()),
    );
  }

  Future<void> _persistNarration() async {
    final checkpoint = _resume;
    if (checkpoint == null) return;
    try {
      await widget.library.saveNarration(book.entry, checkpoint);
    } catch (_) {
      // The next checkpoint will try again.
    }
  }

  VoiceChoices _voiceChoices(VoiceSettings settings) => VoiceChoices(
    kokoro: voices.keys.toList(),
    system: _systemVoices,
    narratorKokoro: settings.voice,
    narratorSystem: settings.systemVoice,
  );

  Future<SectionAttribution?> _cachedAttribution(
    int section,
    String text,
  ) async {
    try {
      return await widget.library.attribution(
        book.entry,
        section,
        textHash(text),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveSectionAttribution(
    int section,
    String text,
    SpeechScript script,
  ) async {
    if (script.attributions.isEmpty) return;
    try {
      final attribution = SectionAttribution(hash: textHash(text))
          .withEntries(script.attributions);
      await widget.library.saveAttribution(book.entry, section, attribution);
    } catch (_) {
      // The next narration attempt will rebuild the suggestions.
    }
  }

  Future<void> _scanCharacters() async {
    if (_scanningCast) return;
    setState(() => _scanningCast = true);
    try {
      final settings = _narrator.settings.withChanges(characterVoices: true);
      final text = await book.spokenText(_index);
      final cached = await _cachedAttribution(_index, text);
      final script = buildSpeechScript(
        text: text,
        settings: settings,
        cast: _cast,
        choices: _voiceChoices(settings),
        attribution: cached,
      );
      _cast = script.cast;
      await _saveCast();
      await _saveSectionAttribution(_index, text, script);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) _notice('Characters could not be found in this section.');
    } finally {
      if (mounted) setState(() => _scanningCast = false);
    }
  }

  Future<void> _pickLead() async {
    if (_cast.voices.isEmpty) {
      _notice('Tap Find characters first, then choose the main character.');
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Main character'),
        children: [
          for (final name in _cast.voices.keys)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, name),
              child: Row(
                children: [
                  Icon(
                    name == _cast.lead
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(name)),
                ],
              ),
            ),
          if (_cast.lead != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('No main character'),
            ),
        ],
      ),
    );
    if (selected == null) return;
    await _setLead(selected.isEmpty ? null : selected);
  }

  Future<void> _setLead(String? name) async {
    setState(() => _cast = _cast.withLead(name));
    await _saveCast();
    if (!mounted) return;
    _notice(
      name == null
          ? 'The main character was cleared.'
          : '$name is now the main character. Restart narration to apply.',
    );
  }

  Future<void> _mergeIntoLead(String character) async {
    final lead = _cast.lead;
    if (lead == null || lead == character) return;
    setState(() => _cast = _cast.mergeInto(character, lead));
    await _saveCast();
    if (mounted) _notice('$character is now part of $lead.');
  }

  Future<void> _checkLfm3() async {
    if (!Lfm3Model.supported) return;
    final ready = await Lfm3Model.isDownloaded();
    if (!mounted) return;
    setState(() {
      _lfm3Ready = ready;
      if (!ready) _lfm3Enabled = false;
    });
  }

  Future<void> _toggleLfm3(bool value, {VoidCallback? onUpdate}) async {
    if (_lfm3Downloading || _lfm3Analyzing) return;
    setState(() => _lfm3Enabled = value);
    onUpdate?.call();
    await _savePreferences();
    if (value && !_lfm3Ready) {
      await _downloadLfm3(onUpdate: onUpdate);
    }
  }

  Future<void> _downloadLfm3({VoidCallback? onUpdate}) async {
    if (_lfm3Downloading || !Lfm3Model.supported) return;
    setState(() {
      _lfm3Downloading = true;
      _lfm3Received = 0;
      _lfm3Total = 100;
    });
    onUpdate?.call();
    try {
      await Lfm3Model.download(
        onProgress: (percent) {
          if (!mounted) return;
          setState(() => _lfm3Received = percent);
          onUpdate?.call();
        },
      );
      if (!mounted) return;
      setState(() {
        _lfm3Ready = true;
        _lfm3Enabled = true;
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('LFM3 is ready. Analyze a chapter to try it.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lfm3Ready = false;
        _lfm3Enabled = false;
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('The LFM3 model could not be downloaded: $error');
    } finally {
      if (mounted) {
        setState(() => _lfm3Downloading = false);
        onUpdate?.call();
      }
    }
  }

  Future<void> _deleteLfm3({VoidCallback? onUpdate}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the LFM3 model?'),
        content: const Text(
          'This frees about 1.1 GB. You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Lfm3Model.delete();
      if (!mounted) return;
      setState(() {
        _lfm3Ready = false;
        _lfm3Enabled = false;
        _lfm3Loaded = false;
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('The LFM3 model was deleted.');
    } catch (error) {
      if (mounted) _notice('The LFM3 model could not be deleted: $error');
    }
  }

  Future<void> _toggleLfm3Audio(bool value, {VoidCallback? onUpdate}) async {
    if (_lfm3AudioDownloading) return;
    if (value && !_lfm3AudioReady) {
      await _downloadLfm3Audio(onUpdate: onUpdate);
      return;
    }
    setState(() {
      _narrator.settings = _narrator.settings.withChanges(lfm3Narration: value);
    });
    onUpdate?.call();
    await _savePreferences();
    if (!value && !_narrator.active) unawaited(Lfm3Audio.unload());
  }

  Future<void> _downloadLfm3Audio({VoidCallback? onUpdate}) async {
    if (_lfm3AudioDownloading || !Lfm3AudioModel.supported) return;
    setState(() {
      _lfm3AudioDownloading = true;
      _lfm3AudioReceived = 0;
      _lfm3AudioTotal = Lfm3AudioModel.totalBytes;
    });
    onUpdate?.call();
    try {
      await Lfm3AudioModel.download(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _lfm3AudioReceived = received;
            _lfm3AudioTotal = total;
          });
          onUpdate?.call();
        },
      );
      if (!mounted) return;
      setState(() {
        _lfm3AudioReady = true;
        _narrator.settings = _narrator.settings.withChanges(
          lfm3Narration: true,
        );
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('LFM3-Audio narration is ready. Start Read aloud to try it.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lfm3AudioReady = false;
        _narrator.settings = _narrator.settings.withChanges(
          lfm3Narration: false,
        );
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('The LFM3-Audio model could not be downloaded: $error');
    } finally {
      if (mounted) {
        setState(() => _lfm3AudioDownloading = false);
        onUpdate?.call();
      }
    }
  }

  Future<void> _deleteLfm3Audio({VoidCallback? onUpdate}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the LFM3-Audio model?'),
        content: const Text(
          'This frees about 1.3 GB. Narration returns to Kokoro or your '
          'iPhone voices, and you can download the model again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Lfm3AudioModel.delete();
      if (!mounted) return;
      setState(() {
        _lfm3AudioReady = false;
        _narrator.settings = _narrator.settings.withChanges(
          lfm3Narration: false,
        );
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('The LFM3-Audio model was deleted.');
    } catch (error) {
      if (mounted) {
        _notice('The LFM3-Audio model could not be deleted: $error');
      }
    }
  }

  Future<void> _analyzeWithLfm3() async {
    if (!_lfm3Ready) {
      _notice('Download the LFM3 model first.');
      return;
    }
    if (!_narrator.settings.characterVoices) {
      _notice('Turn on Character voices first.');
      return;
    }
    if (_narrator.active) {
      _notice('Stop Read aloud before analyzing speakers.');
      return;
    }
    if (_lfm3Analyzing) return;
    setState(() {
      _lfm3Analyzing = true;
      _lfm3Received = 0;
      _lfm3Total = 0;
    });
    try {
      await Lfm3Audio.unload();
      if (!_lfm3Loaded) {
        await Lfm3Model.load();
        _lfm3Loaded = true;
      }
      final text = await book.spokenText(_index);
      final suggestions = await Lfm3Analyzer.analyze(
        text: text,
        cast: _cast.voices.keys,
        lead: _cast.lead,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _lfm3Received = done;
            _lfm3Total = total;
          });
        },
      );
      if (suggestions.isEmpty) {
        if (mounted) {
          _notice('LFM3 found no dialogue suggestions in this section.');
        }
        return;
      }

      final byParagraph = {
        for (final suggestion in suggestions)
          suggestion.paragraph: suggestion.speaker,
      };
      var attribution =
          await _cachedAttribution(_index, text) ??
          SectionAttribution(hash: textHash(text));
      // Never overwrite a line the user already corrected.
      attribution = attribution.keepManualOnly();
      final settings = _narrator.settings;
      var script = buildSpeechScript(
        text: text,
        settings: settings,
        cast: _cast,
        choices: _voiceChoices(settings),
        attribution: attribution,
      );
      final entries = <DialogueAttribution>[];
      for (final entry in script.attributions) {
        final speaker = byParagraph[entry.paragraph];
        if (speaker == null) continue;
        entries.add(
          DialogueAttribution(
            paragraph: entry.paragraph,
            quote: entry.quote,
            text: entry.text,
            speaker: speaker,
            source: 'lfm3',
          ),
        );
      }
      attribution = attribution.withEntries(entries);
      script = buildSpeechScript(
        text: text,
        settings: settings,
        cast: _cast,
        choices: _voiceChoices(settings),
        attribution: attribution,
      );
      _cast = script.cast;
      await _saveCast();
      attribution = attribution.withEntries(script.attributions);
      await widget.library.saveAttribution(book.entry, _index, attribution);
      if (!mounted) return;
      setState(() => _lfm3Analyzing = false);
      await _reviewSpeakers();
    } catch (error) {
      if (!mounted) return;
      final message = error.toString();
      if (message.contains('outputLimit') ||
          message.contains('IncompleteStructuredOutput')) {
        _notice(
          'LFM3 ran out of room for this section. Try a shorter chapter, '
          'or review the speakers manually.',
        );
      } else {
        _notice('LFM3 analysis failed: $message');
      }
    } finally {
      if (mounted && _lfm3Analyzing) {
        setState(() => _lfm3Analyzing = false);
      }
    }
  }

  Future<void> _reviewSpeakers() async {
    if (!_narrator.settings.characterVoices) {
      _notice('Turn on Character voices first.');
      return;
    }
    final settings = _narrator.settings;
    final text = await book.spokenText(_index);
    var attribution =
        await _cachedAttribution(_index, text) ??
        SectionAttribution(hash: textHash(text));
    var script = buildSpeechScript(
      text: text,
      settings: settings,
      cast: _cast,
      choices: _voiceChoices(settings),
      attribution: attribution,
    );
    _cast = script.cast;
    await _saveCast();
    attribution = attribution.withEntries(script.attributions);
    await widget.library.saveAttribution(book.entry, _index, attribution);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final names = <String>{
              for (final name in _cast.voices.keys) name,
              ?_cast.lead,
              'Unknown',
              'Narrator',
            };
            void rebuild() {
              script = buildSpeechScript(
                text: text,
                settings: settings,
                cast: _cast,
                choices: _voiceChoices(settings),
                attribution: attribution,
              );
              _cast = script.cast;
              attribution = attribution.withEntries(script.attributions);
              unawaited(_saveCast());
              unawaited(
                widget.library.saveAttribution(book.entry, _index, attribution),
              );
              if (mounted) setState(() {});
              setSheetState(() {});
            }

            void assign(DialogueAttribution entry, String? speaker) {
              if (speaker == null) return;
              attribution = attribution.withEntry(
                entry.copyWith(
                  speaker: speaker,
                  manual: true,
                  source: 'manual',
                ),
              );
              rebuild();
            }

            Future<void> reidentify() async {
              attribution = attribution.keepManualOnly();
              rebuild();
              if (mounted) {
                _notice('Speakers were re-identified; manual edits were kept.');
              }
            }

            return _sheet(
              FractionallySizedBox(
                heightFactor: 0.92,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Review speakers',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$_unit ${_index + 1} · '
                                  '${script.attributions.length} dialogue lines',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Tap a speaker to correct it. Manual changes are '
                              'saved and will not be overwritten.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: reidentify,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Re-identify'),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 20),
                    Expanded(
                      child: script.attributions.isEmpty
                          ? const Center(
                              child: Text(
                                'No quoted dialogue was found in this section.',
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                              itemCount: script.attributions.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 24),
                              itemBuilder: (context, index) {
                                final entry = script.attributions[index];
                                final current = names.contains(entry.speaker)
                                    ? entry.speaker
                                    : 'Unknown';
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '¶${entry.paragraph + 1}·${entry.quote + 1}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall,
                                        ),
                                        if (entry.speaker == _cast.lead) ...[
                                          const SizedBox(width: 6),
                                          const Icon(Icons.lock, size: 13),
                                        ],
                                        if (entry.manual) ...[
                                          const SizedBox(width: 6),
                                          const Text('edited'),
                                        ] else if (entry.source == 'lfm3') ...[
                                          const SizedBox(width: 6),
                                          const Text('LFM3'),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '“${entry.text}”',
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                    ),
                                    const SizedBox(height: 8),
                                    DropdownButtonFormField<String>(
                                      key: ValueKey(
                                        'review-${entry.key}-${entry.speaker}',
                                      ),
                                      initialValue: current,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        labelText: 'Speaker',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                      items: [
                                        for (final name in names)
                                          DropdownMenuItem(
                                            value: name,
                                            child: Text(
                                              name == 'Unknown'
                                                  ? 'Unknown / narrator'
                                                  : name,
                                            ),
                                          ),
                                      ],
                                      onChanged: (value) =>
                                          assign(entry, value),
                                    ),
                                  ],
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadSystemVoices() async {
    if (_loadingSystemVoices) return;
    if (mounted) setState(() => _loadingSystemVoices = true);
    try {
      final voices = await SystemVoices.list();
      if (!mounted) return;
      setState(() {
        _systemVoices = voices;
        final selected = _narrator.settings;
        if (selected.engine == VoiceEngine.system &&
            !voices.any((voice) => voice.identifier == selected.systemVoice) &&
            voices.isNotEmpty) {
          _narrator.settings = selected.withChanges(
            systemVoice: voices.first.identifier,
          );
        }
      });
    } finally {
      if (mounted) setState(() => _loadingSystemVoices = false);
    }
  }

  Future<void> _loadPhononVoices() async {
    if (_phononLoadingVoices || !PhononNarration.supported) return;
    setState(() => _phononLoadingVoices = true);
    try {
      final values = await PhononNarration.voices(refresh: true);
      if (!mounted) return;
      setState(() {
        _phononVoices = values;
        final selected = _narrator.settings;
        if (selected.engine == VoiceEngine.phonon &&
            values.isNotEmpty &&
            !values.contains(selected.phononVoice)) {
          _narrator.settings = selected.withChanges(phononVoice: values.first);
        }
      });
    } on PhononException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The Phonon voices could not be loaded.');
    } finally {
      if (mounted) setState(() => _phononLoadingVoices = false);
    }
  }

  Future<void> _downloadPhonon({VoidCallback? onUpdate}) async {
    if (_phononDownloading) return;
    setState(() {
      _phononDownloading = true;
      _phononReceived = 0;
      _phononTotal = PhononModel.zipBytes;
    });
    onUpdate?.call();
    try {
      await PhononModel.download(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _phononReceived = received;
            _phononTotal = total;
          });
          onUpdate?.call();
        },
      );
      if (!mounted) return;
      setState(() {
        _phononReady = true;
        _phononDownloading = false;
      });
      await _loadPhononVoices();
      if (mounted) {
        _notice('Phonon is ready. The experimental narrator is available.');
      }
    } on PhononException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The Phonon model could not be downloaded.');
    } finally {
      if (mounted) {
        setState(() => _phononDownloading = false);
        onUpdate?.call();
      }
    }
  }

  Future<void> _importPhononVoice({VoidCallback? onUpdate}) async {
    try {
      const type = XTypeGroup(
        label: 'Phonon voice',
        extensions: ['safetensors'],
      );
      final file = await openFile(acceptedTypeGroups: [type]);
      if (file == null) return;
      final name = await PhononModel.importVoice(File(file.path));
      await _loadPhononVoices();
      if (mounted) {
        _notice('Imported $name. The voice works offline.');
      }
    } on PhononException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The Phonon voice could not be imported.');
    } finally {
      onUpdate?.call();
    }
  }

  Future<void> _deletePhonon({VoidCallback? onUpdate}) async {
    try {
      await PhononModel.delete();
      if (!mounted) return;
      setState(() {
        _phononReady = false;
        _phononVoices = const [];
        _phononReceived = 0;
      });
      if (_narrator.settings.engine == VoiceEngine.phonon) {
        _narrator.settings = _narrator.settings.withChanges(
          engine: VoiceEngine.kokoro,
        );
        await _savePreferences();
      }
      if (mounted) _notice('The Phonon model was deleted. Kokoro is active.');
    } on PhononException catch (error) {
      if (mounted) _notice(error.message);
    } finally {
      onUpdate?.call();
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final darkPdf = await _prefs.getBool('reader.darkPdf');
      final font = await _prefs.getDouble('reader.font');
      final leading = await _prefs.getDouble('reader.leading');
      final voice =
          await _prefs.getInt('reader.voice.v1') ??
          upgradedVoice(await _prefs.getInt('reader.voice'));
      final engine = await _prefs.getString('reader.engine');
      final systemVoice = await _prefs.getString('reader.systemVoice');
      final background = await _prefs.getBool('reader.backgroundAudio');
      final continueToEnd = await _prefs.getBool('reader.continueToEnd');
      final speed = await _prefs.getDouble('reader.speed');
      final pauses = await _prefs.getDouble('reader.pauses');
      final pitch = await _prefs.getDouble('reader.pitch');
      final volume = await _prefs.getDouble('reader.volume');
      final marks = await _prefs.getBool('reader.marks');
      final characterVoices = await _prefs.getBool('reader.characterVoices');
      final batterySaver = await _prefs.getBool('reader.batterySaver');
      final lfm3 = await _prefs.getBool('reader.lfm3');
      final lfm3Audio = await _prefs.getBool('reader.lfm3Audio');
      final lfm3AudioVoice = await _prefs.getString('reader.lfm3AudioVoice');
      final lfm3AudioReady = await Lfm3AudioModel.isInstalled();
      final phononVoice = await _prefs.getString('reader.phononVoice');
      final phononReady =
          PhononNarration.supported && await PhononModel.isInstalled();
      if (!mounted) return;
      setState(() {
        _darkPdfPages = darkPdf ?? true;
        _backgroundPlayback = background ?? true;
        _continueToEnd = continueToEnd ?? true;
        _lfm3Enabled = lfm3 ?? false;
        _lfm3AudioReady = lfm3AudioReady;
        _phononReady = phononReady;
        _fontSize = (font ?? 21).clamp(15, 34);
        _lineHeight = (leading ?? 1.65).clamp(1.25, 2);
        _narrator.settings = VoiceSettings(
          engine: switch (engine) {
            'system' when SystemVoices.supported => VoiceEngine.system,
            'phonon' when phononReady => VoiceEngine.phonon,
            _ => VoiceEngine.kokoro,
          },
          voice: voices.containsKey(voice) ? voice : defaultVoice,
          systemVoice: systemVoice,
          speed: (speed ?? 1).clamp(.6, 1.8),
          pauses: (pauses ?? 1).clamp(.05, 1),
          pitch: (pitch ?? 1).clamp(.75, 1.35),
          volume: (volume ?? 1).clamp(0, 1),
          punctuation: marks == true
              ? Punctuation.announce
              : Punctuation.natural,
          characterVoices: characterVoices ?? true,
          batterySaver:
              batterySaver ??
              (defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.android),
          lfm3Narration: (lfm3Audio ?? false) && lfm3AudioReady,
          lfm3Voice:
              lfm3AudioVoice != null &&
                  Lfm3Audio.voices.contains(lfm3AudioVoice)
              ? lfm3AudioVoice
              : 'female',
          phononVoice: (phononVoice ?? '').trim().isEmpty
              ? 'Harper'
              : phononVoice!.trim(),
        );
      });
    } catch (_) {
      if (mounted) _notice('Saved reader settings could not be loaded.');
    }
  }

  Future<void> _savePreferences() async {
    final settings = _narrator.settings;
    try {
      await Future.wait([
        _prefs.setBool('reader.darkPdf', _darkPdfPages),
        _prefs.setDouble('reader.font', _fontSize),
        _prefs.setDouble('reader.leading', _lineHeight),
        _prefs.setString('reader.engine', settings.engine.name),
        _prefs.setInt('reader.voice.v1', settings.voice),
        if (settings.systemVoice case final voice?)
          _prefs.setString('reader.systemVoice', voice),
        _prefs.setBool('reader.backgroundAudio', _backgroundPlayback),
        _prefs.setBool('reader.continueToEnd', _continueToEnd),
        _prefs.setDouble('reader.speed', settings.speed),
        _prefs.setDouble('reader.pauses', settings.pauses),
        _prefs.setDouble('reader.pitch', settings.pitch),
        _prefs.setDouble('reader.volume', settings.volume),
        _prefs.setBool(
          'reader.marks',
          settings.punctuation == Punctuation.announce,
        ),
        _prefs.setBool('reader.characterVoices', settings.characterVoices),
        _prefs.setBool('reader.batterySaver', settings.batterySaver),
        _prefs.setBool('reader.lfm3', _lfm3Enabled),
        _prefs.setBool('reader.lfm3Audio', settings.lfm3Narration),
        _prefs.setString('reader.lfm3AudioVoice', settings.lfm3Voice),
        _prefs.setString('reader.phononVoice', settings.phononVoice),
      ]);
    } catch (_) {
      if (mounted) _notice('Reader settings could not be saved.');
    }
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _savePosition() async {
    try {
      await widget.library.savePosition(book.entry, _index);
    } catch (_) {
      _notice('Reading position could not be saved.');
    }
  }

  void _positionChanged(int index) {
    if (!mounted || _index == index) return;
    setState(() => _index = index);
    _resetTextScroll();
    _positionTimer?.cancel();
    _positionTimer = Timer(const Duration(milliseconds: 250), _savePosition);
  }

  void _showSection(int index) {
    if (!mounted || _index == index) return;
    _positionChanged(index);
    final controller = _pdfController;
    if (controller != null && controller.hasClients) {
      controller.jumpToPage(index);
    }
  }

  Future<void> _jump(int index) async {
    if (_changing || index < 0 || index >= _length) return;
    setState(() => _changing = true);
    try {
      await _narrator.stop();
      _resume = null;
      _showSection(index);
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _toggleBookmark() async {
    final bookmark = _bookmark == _index ? null : _index;
    setState(() => _bookmark = bookmark);
    try {
      await widget.library.saveBookmark(book.entry, bookmark);
    } catch (_) {
      _notice('The bookmark could not be saved.');
    }
  }

  Future<void> _contents() async {
    final next = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _sheet(
        FractionallySizedBox(
          heightFactor: .7,
          child: Column(
            children: [
              const SizedBox(height: 20),
              Text(
                book.epub != null ? 'Contents' : 'Go to page',
                style: _paper.theme.textTheme.titleLarge?.copyWith(
                  color: _paper.ink,
                ),
              ),
              if (_bookmark case final saved?)
                ListTile(
                  leading: const Icon(Icons.bookmark_outline),
                  title: Text('Bookmark · $_unit ${saved + 1}'),
                  onTap: () => Navigator.pop(context, saved),
                ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: _length,
                  itemBuilder: (context, index) => ListTile(
                    selected: index == _index,
                    title: Text(_chapterTitles[index] ?? '$_unit ${index + 1}'),
                    trailing: index == _index ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(context, index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && next != null) await _jump(next);
  }

  Future<void> _settings({required bool voice}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          final settings = _narrator.settings;
          final system = settings.engine == VoiceEngine.system;
          final phonon = settings.engine == VoiceEngine.phonon;
          final engines = [
            VoiceEngine.kokoro,
            if (SystemVoices.supported) VoiceEngine.system,
            if (PhononNarration.supported) VoiceEngine.phonon,
          ];
          void refreshSheet() {
            try {
              refresh(() {});
            } catch (_) {
              // The settings sheet can close while a download is running.
            }
          }

          void update(VoidCallback apply) {
            setState(apply);
            refresh(() {});
          }

          return _sheet(
            FractionallySizedBox(
              heightFactor: .9,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      voice ? 'Read aloud settings' : 'Reading appearance',
                      style: _paper.theme.textTheme.headlineSmall?.copyWith(
                        color: _paper.ink,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (voice) ...[
                      const Text(
                        'Changes apply the next time you start Read aloud. '
                        'Kokoro remains the default. System uses voices '
                        'installed on your iPhone; Phonon is an experimental '
                        'on-device English model.',
                      ),
                      if (engines.length > 1) ...[
                        const SizedBox(height: 16),
                        SegmentedButton<VoiceEngine>(
                          segments: [
                            for (final engine in engines)
                              ButtonSegment(
                                value: engine,
                                label: Text(engine.label),
                              ),
                          ],
                          selected: {settings.engine},
                          onSelectionChanged: (values) {
                            final engine = values.first;
                            final savedVoice = settings.systemVoice;
                            final savedIsValid = _systemVoices.any(
                              (voice) => voice.identifier == savedVoice,
                            );
                            update(() {
                              _narrator.settings = settings.withChanges(
                                engine: engine,
                                systemVoice:
                                    engine == VoiceEngine.system &&
                                        _systemVoices.isNotEmpty &&
                                        !savedIsValid
                                    ? _systemVoices.first.identifier
                                    : savedVoice,
                                lfm3Narration: engine == VoiceEngine.phonon
                                    ? false
                                    : settings.lfm3Narration,
                              );
                            });
                            if (engine == VoiceEngine.system &&
                                _systemVoices.isEmpty) {
                              unawaited(_loadSystemVoices());
                            }
                            if (engine == VoiceEngine.phonon &&
                                _phononReady &&
                                _phononVoices.isEmpty) {
                              unawaited(_loadPhononVoices());
                            }
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            settings.engine.description,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final preset in voicePresets.entries)
                            ActionChip(
                              label: Text(preset.key),
                              onPressed: () => update(() {
                                _narrator.settings = settings.withChanges(
                                  voice: settings.engine == VoiceEngine.kokoro
                                      ? preset.value.voice
                                      : settings.voice,
                                  speed: preset.value.speed,
                                  pauses: preset.value.pauses,
                                  punctuation: preset.value.punctuation,
                                );
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (system) ...[
                        if (_loadingSystemVoices)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: LinearProgressIndicator(),
                          )
                        else if (_systemVoices.isEmpty)
                          _VoiceNotice(
                            message:
                                'No iPhone voices were found. Download a voice '
                                'in Settings › Accessibility › Spoken Content › '
                                'Voices, then reopen this sheet.',
                            action: 'Refresh',
                            onAction: () => unawaited(_loadSystemVoices()),
                          )
                        else
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'system-${settings.systemVoice}-'
                              '${_systemVoices.length}',
                            ),
                            decoration: const InputDecoration(
                              labelText: 'iPhone voice',
                              border: OutlineInputBorder(),
                            ),
                            initialValue:
                                _systemVoices.any(
                                  (voice) =>
                                      voice.identifier == settings.systemVoice,
                                )
                                ? settings.systemVoice
                                : _systemVoices.first.identifier,
                            isExpanded: true,
                            items: [
                              for (final voice in _systemVoices)
                                DropdownMenuItem(
                                  value: voice.identifier,
                                  child: Text(
                                    voice.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (value) => update(
                              () => _narrator.settings = settings.withChanges(
                                systemVoice: value,
                              ),
                            ),
                          ),
                        if (_systemVoices.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: _VoiceNotice(
                              message:
                                  'For more natural voices, download enhanced '
                                  'or premium voices in Settings › '
                                  'Accessibility › Spoken Content › Voices.',
                              action: 'Refresh',
                              onAction: () => unawaited(_loadSystemVoices()),
                            ),
                          ),
                      ] else if (phonon) ...[
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Experimental · Phonon narrator',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'A ${PhononModel.displaySize} on-device English '
                          'model by Gradium. It runs on the Apple Neural '
                          'Engine and works offline after the one-time '
                          'download. License: ${PhononModel.license}.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (_phononDownloading) ...[
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                            value: _phononTotal > 0
                                ? (_phononReceived / _phononTotal).clamp(
                                    0.0,
                                    1.0,
                                  )
                                : null,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${(_phononReceived / _phononTotal * 100).clamp(0, 100).round()}% '
                            'of ${PhononModel.displaySize}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ] else if (!_phononReady) ...[
                          const SizedBox(height: 8),
                          _VoiceNotice(
                            message:
                                'Phonon is downloaded only when you choose '
                                'it. Installed size is '
                                '${PhononModel.installedSize}.',
                            action: 'Download',
                            onAction: () => unawaited(
                              _downloadPhonon(onUpdate: refreshSheet),
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: 8),
                          if (_phononLoadingVoices)
                            const LinearProgressIndicator()
                          else if (_phononVoices.isEmpty) ...[
                            _VoiceNotice(
                              message:
                                  'Phonon is installed. Load its voices to '
                                  'choose a narrator.',
                              action: 'Load voices',
                              onAction: () => unawaited(_loadPhononVoices()),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: _narrator.active
                                    ? null
                                    : () => unawaited(
                                        _deletePhonon(onUpdate: refreshSheet),
                                      ),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                label: const Text('Delete Phonon model'),
                              ),
                            ),
                          ] else
                            DropdownButtonFormField<String>(
                              key: ValueKey(
                                'phonon-${settings.phononVoice}-'
                                '${_phononVoices.length}',
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Phonon voice',
                                border: OutlineInputBorder(),
                              ),
                              initialValue:
                                  _phononVoices.contains(settings.phononVoice)
                                  ? settings.phononVoice
                                  : _phononVoices.first,
                              isExpanded: true,
                              items: [
                                for (final voice in _phononVoices)
                                  DropdownMenuItem(
                                    value: voice,
                                    child: Text(voice),
                                  ),
                              ],
                              onChanged: (value) => update(() {
                                _narrator.settings = settings.withChanges(
                                  phononVoice: value,
                                );
                                unawaited(_savePreferences());
                              }),
                            ),
                          const SizedBox(height: 6),
                          Text(
                            'Phonon reads the whole book in one voice. '
                            'Character voices and LFM3-Audio are not used '
                            'while it is selected. To use a cloned voice, '
                            'create it in Gradium Studio, download the '
                            '.safetensors file, and import it here.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed:
                                    _phononDownloading || _narrator.active
                                    ? null
                                    : () => unawaited(
                                        _importPhononVoice(
                                          onUpdate: refreshSheet,
                                        ),
                                      ),
                                icon: const Icon(
                                  Icons.library_add_outlined,
                                  size: 18,
                                ),
                                label: const Text('Import cloned voice'),
                              ),
                              TextButton.icon(
                                onPressed:
                                    _phononDownloading || _narrator.active
                                    ? null
                                    : () => unawaited(
                                        _deletePhonon(onUpdate: refreshSheet),
                                      ),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                label: const Text('Delete Phonon model'),
                              ),
                            ],
                          ),
                        ],
                      ] else
                        DropdownButtonFormField<int>(
                          key: ValueKey('kokoro-${settings.voice}'),
                          decoration: const InputDecoration(
                            labelText: 'Kokoro voice',
                            border: OutlineInputBorder(),
                          ),
                          initialValue: settings.voice,
                          isExpanded: true,
                          items: [
                            for (final item in voices.entries)
                              DropdownMenuItem(
                                value: item.key,
                                child: Text(item.value),
                              ),
                          ],
                          onChanged: (value) => update(
                            () => _narrator.settings = settings.withChanges(
                              voice: value,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _narrator.active || _previewing
                              ? null
                              : () async {
                                  final preview = _previewVoice(settings);
                                  refreshSheet();
                                  await preview;
                                  refreshSheet();
                                },
                          icon: _previewing
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_circle_outline),
                          label: Text(
                            _previewing ? 'Playing preview' : 'Preview voice',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Character voices'),
                        subtitle: const Text(
                          'Use a different voice for quoted dialogue. '
                          'Detection runs offline; you can change the cast here.',
                        ),
                        value: settings.characterVoices,
                        onChanged: (value) => update(() {
                          _narrator.settings = settings.withChanges(
                            characterVoices: value,
                          );
                        }),
                      ),
                      if (settings.characterVoices) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Cast',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _scanningCast
                                  ? null
                                  : () async {
                                      final scan = _scanCharacters();
                                      refreshSheet();
                                      await scan;
                                      refreshSheet();
                                    },
                              icon: _scanningCast
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.person_search_outlined),
                              label: Text(
                                _scanningCast ? 'Finding…' : 'Find characters',
                              ),
                            ),
                          ],
                        ),
                        if (_cast.voices.isEmpty)
                          const Text(
                            'Tap Find characters in a chapter with dialogue. '
                            'Each detected name gets its own voice automatically.',
                          )
                        else ...[
                          if (_cast.lead case final lead?) ...[
                            Row(
                              children: [
                                const Icon(Icons.lock_outline, size: 16),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Main character',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(_pickLead()),
                                  child: const Text('Change'),
                                ),
                              ],
                            ),
                            _CastVoiceTile(
                              character: lead,
                              voice: _cast.voiceFor(lead) ?? const CastVoice(),
                              settings: settings,
                              systemVoices: _systemVoices,
                              isLead: true,
                              onChanged: (voice) => update(() {
                                _cast = _cast.withVoice(lead, voice);
                                unawaited(_saveCast());
                              }),
                              onRemove: null,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Side characters',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ] else
                            _VoiceNotice(
                              message:
                                  'No main character is pinned yet. Choose one '
                                  'so their voice can never be taken by the '
                                  'automatic cast.',
                              action: 'Choose',
                              onAction: () => unawaited(_pickLead()),
                            ),
                          for (final entry in _cast.voices.entries)
                            if (entry.key != _cast.lead)
                              _CastVoiceTile(
                                character: entry.key,
                                voice: entry.value,
                                settings: settings,
                                systemVoices: _systemVoices,
                                leadVoice: _cast.voiceFor(_cast.lead ?? ''),
                                onChanged: (voice) => update(() {
                                  _cast = _cast.withVoice(entry.key, voice);
                                  unawaited(_saveCast());
                                }),
                                onRemove: () => update(() {
                                  _cast = _cast.withoutVoice(entry.key);
                                  unawaited(_saveCast());
                                }),
                                onMakeLead: () =>
                                    unawaited(_setLead(entry.key)),
                                onMergeIntoLead: _cast.lead == null
                                    ? null
                                    : () =>
                                          unawaited(_mergeIntoLead(entry.key)),
                              ),
                          const SizedBox(height: 4),
                          const Text(
                            'The main character always keeps their reserved '
                            'voice. Side characters get a different voice. '
                            'Detection is approximate, so review anything that '
                            'sounds wrong.',
                          ),
                        ],
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => unawaited(_reviewSpeakers()),
                            icon: const Icon(Icons.record_voice_over_outlined),
                            label: const Text(
                              'Review speakers in this chapter',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Divider(),
                      ],
                      if (Lfm3Model.supported) ...[
                        Container(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.science_outlined, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Experimental · LFM3 speakers',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Optional ${Lfm3Model.displaySize} on-device '
                                'LFM3 model by Liquid AI. It downloads only '
                                'after you turn this on. It can be slow and '
                                'inaccurate; suggestions are cached and always '
                                'editable.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Model license: LFM Open License v1.0.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Material(
                                type: MaterialType.transparency,
                                child: SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Use LFM3 suggestions'),
                                  subtitle: Text(
                                    _lfm3Downloading
                                        ? 'Downloading the model…'
                                        : _lfm3Ready
                                        ? 'Model ready on this device'
                                        : 'Model not downloaded',
                                  ),
                                  value: _lfm3Enabled,
                                  onChanged: _lfm3Downloading || _lfm3Analyzing
                                      ? null
                                      : (value) => unawaited(
                                          _toggleLfm3(
                                            value,
                                            onUpdate: refreshSheet,
                                          ),
                                        ),
                                ),
                              ),
                              if (_lfm3Downloading) ...[
                                const SizedBox(height: 4),
                                LinearProgressIndicator(
                                  value: _lfm3Total > 0
                                      ? (_lfm3Received / _lfm3Total).clamp(
                                          0.0,
                                          1.0,
                                        )
                                      : null,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '$_lfm3Received% of '
                                  '${Lfm3Model.displaySize}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                              if (_lfm3Ready) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.tonalIcon(
                                        onPressed: _lfm3Analyzing
                                            ? null
                                            : () =>
                                                  unawaited(_analyzeWithLfm3()),
                                        icon: _lfm3Analyzing
                                            ? const SizedBox.square(
                                                dimension: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.auto_awesome_outlined,
                                                size: 18,
                                              ),
                                        label: Text(
                                          _lfm3Analyzing
                                              ? 'Analyzing…'
                                              : 'Analyze this chapter',
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete LFM3 model',
                                      onPressed: _lfm3Analyzing
                                          ? null
                                          : () => unawaited(
                                              _deleteLfm3(
                                                onUpdate: refreshSheet,
                                              ),
                                            ),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 20,
                                      ),
                                    ),
                                  ],
                                ),
                                if (_lfm3Analyzing)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      _lfm3Total > 0
                                          ? 'Part ${_lfm3Received + 1} of '
                                                '$_lfm3Total'
                                          : 'Loading the model…',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ),
                                const SizedBox(height: 4),
                                Text(
                                  'After analysis, use Review speakers to '
                                  'correct the suggestions. Manual edits are '
                                  'never replaced.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ] else if (!_lfm3Downloading)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Turning this on starts the model '
                                    'download.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Divider(),
                      ],
                      if (Lfm3AudioModel.supported) ...[
                        Container(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.graphic_eq, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Experimental · LFM3-Audio narrator',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Optional ${Lfm3AudioModel.displaySize} '
                                'on-device model by Liquid AI. It reads '
                                'narration with a 24 kHz voice while quoted '
                                'dialogue keeps your cast. It has two voices '
                                'and can be slow; download it only if you want '
                                'to try it.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Model license: ${Lfm3AudioModel.license}.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Material(
                                type: MaterialType.transparency,
                                child: SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    'Use LFM3-Audio for narration',
                                  ),
                                  subtitle: Text(
                                    _lfm3AudioDownloading
                                        ? 'Downloading the model…'
                                        : _lfm3AudioReady
                                        ? 'Model ready on this device'
                                        : 'Model not downloaded',
                                  ),
                                  value: settings.lfm3Narration,
                                  onChanged: _lfm3AudioDownloading
                                      ? null
                                      : (value) => unawaited(
                                          _toggleLfm3Audio(
                                            value,
                                            onUpdate: refreshSheet,
                                          ),
                                        ),
                                ),
                              ),
                              if (_lfm3AudioDownloading) ...[
                                const SizedBox(height: 4),
                                LinearProgressIndicator(
                                  value: _lfm3AudioTotal > 0
                                      ? (_lfm3AudioReceived / _lfm3AudioTotal)
                                            .clamp(0.0, 1.0)
                                      : null,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${(_lfm3AudioReceived / _lfm3AudioTotal * 100).clamp(0, 100).round()}% of '
                                  '${Lfm3AudioModel.displaySize}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                              if (_lfm3AudioReady) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        key: ValueKey(
                                          'lfm3-audio-voice-'
                                          '${settings.lfm3Voice}',
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: 'LFM3-Audio voice',
                                          border: OutlineInputBorder(),
                                          isDense: true,
                                        ),
                                        initialValue: settings.lfm3Voice,
                                        items: const [
                                          DropdownMenuItem(
                                            value: 'female',
                                            child: Text('Female'),
                                          ),
                                          DropdownMenuItem(
                                            value: 'male',
                                            child: Text('Male'),
                                          ),
                                        ],
                                        onChanged: (value) => update(() {
                                          _narrator.settings = settings
                                              .withChanges(lfm3Voice: value);
                                          unawaited(_savePreferences());
                                        }),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: 'Delete LFM3-Audio model',
                                      onPressed: _lfm3AudioDownloading
                                          ? null
                                          : () => unawaited(
                                              _deleteLfm3Audio(
                                                onUpdate: refreshSheet,
                                              ),
                                            ),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 20,
                                      ),
                                    ),
                                  ],
                                ),
                                if (settings.lfm3Narration)
                                  Text(
                                    'Character dialogue still uses the cast '
                                    'voices. Turn off Character voices to have '
                                    'LFM3-Audio read the whole book.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                              ] else if (!_lfm3AudioDownloading)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Turning this on starts the model '
                                    'download.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Divider(),
                      ],
                      _SettingSlider(
                        label: 'Speed',
                        display: '${settings.speed.toStringAsFixed(2)}×',
                        value: settings.speed,
                        min: .6,
                        max: 1.8,
                        onChanged: (value) => update(
                          () => _narrator.settings = settings.withChanges(
                            speed: value,
                          ),
                        ),
                      ),
                      if (system)
                        _SettingSlider(
                          label: 'Tone',
                          display: '${((settings.pitch - 1) * 100).round()}%',
                          value: settings.pitch,
                          min: .75,
                          max: 1.35,
                          onChanged: (value) => update(
                            () => _narrator.settings = settings.withChanges(
                              pitch: value,
                            ),
                          ),
                        )
                      else
                        _SettingSlider(
                          label: 'Sentence pauses',
                          display: '${(settings.pauses * 100).round()}%',
                          value: settings.pauses,
                          min: .05,
                          max: 1,
                          onChanged: (value) => update(
                            () => _narrator.settings = settings.withChanges(
                              pauses: value,
                            ),
                          ),
                        ),
                      _SettingSlider(
                        label: 'Volume',
                        display: '${(settings.volume * 100).round()}%',
                        value: settings.volume,
                        min: 0,
                        max: 1,
                        onChanged: (value) => update(() {
                          _narrator.settings = settings.withChanges(
                            volume: value,
                          );
                          unawaited(_narrator.setVolume(value));
                        }),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Battery saver'),
                        subtitle: const Text(
                          'Uses fewer CPU threads and generates less audio '
                          'ahead. Recommended for long listening sessions on '
                          'iPhone.',
                        ),
                        value: settings.batterySaver,
                        onChanged: (value) => update(() {
                          _narrator.settings = settings.withChanges(
                            batterySaver: value,
                          );
                          unawaited(_savePreferences());
                        }),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Background playback'),
                        subtitle: const Text(
                          'Keep reading when you switch apps or lock your screen.',
                        ),
                        value: _backgroundPlayback,
                        onChanged: (value) =>
                            update(() => _backgroundPlayback = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Continue through the book'),
                        subtitle: const Text(
                          'Automatically start the next chapter or page, even '
                          'while the screen is locked.',
                        ),
                        value: _continueToEnd,
                        onChanged: (value) =>
                            update(() => _continueToEnd = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Speak punctuation marks'),
                        subtitle: const Text(
                          'Say “comma”, “period”, and other marks out loud.',
                        ),
                        value: settings.punctuation == Punctuation.announce,
                        onChanged: (value) => update(() {
                          _narrator.settings = settings.withChanges(
                            punctuation: value
                                ? Punctuation.announce
                                : Punctuation.natural,
                          );
                        }),
                      ),
                    ] else ...[
                      ThemeChooser(
                        controller: widget.theme,
                        onChanged: () => update(() {}),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.theme.choice.description,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 20),
                      if (_isPdf) ...[
                        const Text(
                          'Pages turn sideways, one full page at a time. '
                          'Pinch or double-tap to zoom; double-tap again to '
                          'fit the whole page.',
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Darken PDF pages'),
                          subtitle: const Text(
                            'Invert page colors in dark themes.',
                          ),
                          value: _darkPdfPages,
                          onChanged: (value) =>
                              update(() => _darkPdfPages = value),
                        ),
                      ] else ...[
                        _SettingSlider(
                          label: 'Text size',
                          display: '${_fontSize.round()}',
                          value: _fontSize,
                          min: 15,
                          max: 34,
                          onChanged: (value) => update(() => _fontSize = value),
                        ),
                        _SettingSlider(
                          label: 'Line spacing',
                          display: _lineHeight.toStringAsFixed(2),
                          value: _lineHeight,
                          min: 1.25,
                          max: 2,
                          onChanged: (value) =>
                              update(() => _lineHeight = value),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    await _narrator.stopPreview();
    if (mounted) await _savePreferences();
  }

  Future<void> _previewVoice(VoiceSettings settings) async {
    setState(() => _previewing = true);
    try {
      await _narrator.preview(settings);
    } on SpeechFailure catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The voice preview could not be played.');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Widget _sheet(Widget child) => Theme(
    data: _paper.theme,
    child: Material(
      color: _paper.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(top: false, child: child),
    ),
  );

  void _play() {
    switch (_narrator.state) {
      case SpeechState.idle:
        final settings = _narrator.settings;
        final choices = _voiceChoices(settings);
        var runCast = _cast;
        final resumeHere = _resume != null && _resume!.section == _index;
        _narrator.start(
          title: book.entry.title,
          sectionName: _unit,
          index: _index,
          length: _length,
          loadSpeech: (section) async {
            final text = await book.spokenText(section);
            final cached = await _cachedAttribution(section, text);
            final script = buildSpeechScript(
              text: text,
              settings: settings,
              cast: runCast,
              choices: choices,
              attribution: cached,
            );
            if (script.castChanged) {
              runCast = script.cast;
              _cast = script.cast;
              unawaited(_saveCast());
            }
            unawaited(_saveSectionAttribution(section, text, script));
            return script.utterances;
          },
          showSection: _showSection,
          continueToEnd: _continueToEnd,
          startUtterance: resumeHere ? _resume!.utterance : 0,
          resumePassage: resumeHere ? _resume!.passage : null,
          onProgress: _narrationProgress,
        );
      case SpeechState.preparing:
      case SpeechState.playing:
        unawaited(_narrator.pause());
      case SpeechState.paused:
        _narrator.resume();
    }
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _narrationSaveTimer?.cancel();
    _textScroll.dispose();
    _pdfController?.dispose();
    widget.theme.removeListener(_themeChanged);
    _narrator.removeListener(_narratorChanged);
    _lifecycle.dispose();
    unawaited(_savePosition());
    unawaited(_close().whenComplete(() => widget.onClosed?.call()));
    super.dispose();
  }

  Future<void> _close() async {
    _narrationSaveTimer?.cancel();
    await _persistNarration();
    if (_lfm3Loaded) {
      _lfm3Loaded = false;
      unawaited(Lfm3Model.unload());
    }
    unawaited(PhononNarration.unload());
    try {
      await _narrator.close();
    } finally {
      await book.close();
    }
  }

  Widget _page() {
    if (book.pdf case final pdf?) {
      return ColoredBox(
        color: _paper.background,
        child: PageView.builder(
          controller: _pdfController,
          physics: _zoomedPdf
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          pageSnapping: true,
          allowImplicitScrolling: true,
          itemCount: _length,
          onPageChanged: (index) {
            _positionChanged(index);
            if (_zoomedPdf) setState(() => _zoomedPdf = false);
          },
          itemBuilder: (context, index) => _PdfSheet(
            document: pdf,
            pageNumber: index + 1,
            active: index == _index,
            paper: _paper,
            darken: _paper.isDark && _darkPdfPages,
            onZoomChanged: (zoomed) {
              if (index == _index && zoomed != _zoomedPdf) {
                setState(() => _zoomedPdf = zoomed);
              }
            },
          ),
        ),
      );
    }
    final style = TextStyle(
      color: _paper.ink,
      fontFamilyFallback: serif,
      fontSize: _fontSize,
      height: _lineHeight,
    );
    if (book.textPages case final pages?) {
      return ReadingPage(
        key: ValueKey(_index),
        controller: _textScroll,
        itemCount: 1,
        itemBuilder: (_, _) => _textPage(pages[_index], style),
      );
    }

    final epub = book.epub!;
    final EpubChapter chapter;
    try {
      chapter = book.chapter(_index);
    } catch (_) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'This EPUB chapter could not be displayed. Try another chapter in Contents.',
          ),
        ),
      );
    }
    final passage = _playingPassage;
    final highlightedBlock = passage == null
        ? null
        : _highlightedBlockIndex(chapter, passage);
    final scope = EpubRenderScope(
      settings: EpubReaderSettings(
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        fontFamilyFallback: serif,
        theme: EpubReaderTheme(
          name: _paper.name,
          backgroundColor: _paper.background,
          textColor: _paper.ink,
          linkColor: _paper.accent,
          secondaryColor: _paper.accent,
        ),
      ),
      defaultDirection:
          chapter.direction == EpubDirection.rtl ||
              (chapter.direction == null && epub.isRtl)
          ? TextDirection.rtl
          : TextDirection.ltr,
      loadImage: epub.readBytes,
      onLink: (href) {
        if (EpubPath.isExternal(href)) return;
        final target = book.indexOfHref(href);
        if (target >= 0 && target != _index) unawaited(_jump(target));
      },
    );
    return SelectionArea(
      child: ReadingPage(
        key: ValueKey(_index),
        itemCount: chapter.blocks.length,
        itemBuilder: (_, index) {
          final block = EpubBlockView(
            block: chapter.blocks[index],
            scope: scope,
          );
          if (index != highlightedBlock) return block;
          _scheduleBlockScroll(passage!);
          return Container(
            key: _highlightedBlockKey,
            decoration: BoxDecoration(
              color: _paper.accent.withValues(alpha: _paper.isDark ? .20 : .11),
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: _paper.accent, width: 3)),
            ),
            child: block,
          );
        },
      ),
    );
  }

  String? get _playingPassage {
    if (_narrator.state == SpeechState.idle) return null;
    final passage = _narrator.passage;
    if (passage == null || passage.trim().isEmpty) return null;
    if (_resume?.section != _index) return null;
    return passage;
  }

  String get _nowPlayingLabel {
    final parts = <String>['NOW PLAYING'];
    if (_narrator.speaker case final speaker?) parts.add(speaker);
    final section = _resume?.section;
    if (section != null && section != _index) {
      parts.add('$_unit ${section + 1}');
    }
    return parts.join(' · ');
  }

  Widget _textPage(String text, TextStyle style) {
    final passage = _playingPassage;
    final range = passage == null ? null : findPassageRange(text, passage);
    if (passage == null || range == null) {
      return SelectableText(text, style: style);
    }
    _scheduleTextScroll(range.start, text.length, passage);
    return SelectableText.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: text.substring(0, range.start)),
          TextSpan(
            text: text.substring(range.start, range.end),
            style: style.copyWith(
              color: _paper.ink,
              backgroundColor: _paper.accent.withValues(
                alpha: _paper.isDark ? .30 : .18,
              ),
            ),
          ),
          TextSpan(text: text.substring(range.end)),
        ],
      ),
    );
  }

  int? _highlightedBlockIndex(EpubChapter chapter, String passage) {
    for (var index = 0; index < chapter.blocks.length; index++) {
      final text = blockText(chapter.blocks[index]);
      if (findPassageRange(text, passage) != null) return index;
    }
    return null;
  }

  void _scheduleTextScroll(int start, int length, String passage) {
    if (_lastScrolledPassage == passage || length <= 0) return;
    _lastScrolledPassage = passage;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_textScroll.hasClients) return;
      final position = _textScroll.position;
      if (position.maxScrollExtent <= 0) return;
      final target = (start / length * position.maxScrollExtent - 64).clamp(
        0.0,
        position.maxScrollExtent,
      );
      if ((position.pixels - target).abs() < 24) return;
      _textScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _scheduleBlockScroll(String passage) {
    if (_lastScrolledPassage == passage) return;
    _lastScrolledPassage = passage;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _highlightedBlockKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: .30,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _resetTextScroll() {
    _lastScrolledPassage = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _textScroll.hasClients) {
        _textScroll.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _paper.theme,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          book.entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _settings(voice: false),
            icon: const Icon(Icons.palette_outlined, size: 19),
            label: const Text('Theme'),
          ),
          IconButton(
            tooltip: _bookmark == _index
                ? 'Remove bookmark'
                : 'Bookmark this section',
            isSelected: _bookmark == _index,
            onPressed: _toggleBookmark,
            icon: const Icon(Icons.bookmark_outline),
            selectedIcon: const Icon(Icons.bookmark),
          ),
        ],
      ),
      body: book.pdf != null
          ? _page()
          : ListenableBuilder(
              listenable: _narrator,
              builder: (context, _) => _page(),
            ),
      bottomNavigationBar: ListenableBuilder(
        listenable: _narrator,
        builder: (context, _) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(height: 1),
              if (_narrator.error case final error?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Semantics(liveRegion: true, child: Text(error)),
                )
              else if (_narrator.passage case final passage?)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: _paper.accent.withValues(
                      alpha: _paper.isDark ? .16 : .09,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _paper.accent.withValues(alpha: .22),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.graphic_eq_rounded,
                        size: 18,
                        color: _paper.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _nowPlayingLabel,
                              style: TextStyle(
                                color: _paper.accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              passage,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: _paper.ink, height: 1.3),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              else if (_narrator.state == SpeechState.idle &&
                  _resume != null &&
                  _resume!.section == _index &&
                  _resume!.passage.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.history, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Continue listening · ${_resume!.passage}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_narrator.state == SpeechState.preparing)
                const LinearProgressIndicator(minHeight: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous ${_unit.toLowerCase()}',
                    onPressed: !_canNavigate || _index == 0
                        ? null
                        : () => _jump(_index - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Flexible(
                    child: TextButton.icon(
                      onPressed: _canNavigate ? _contents : null,
                      icon: const Icon(Icons.list),
                      label: Text(
                        '$_unit ${_index + 1} / $_length',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next ${_unit.toLowerCase()}',
                    onPressed: !_canNavigate || _index + 1 == _length
                        ? null
                        : () => _jump(_index + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: switch (_narrator.state) {
                      SpeechState.idle => 'Read aloud',
                      SpeechState.paused => 'Resume narration',
                      _ => 'Pause narration',
                    },
                    onPressed: _canNavigate ? _play : null,
                    icon: Icon(switch (_narrator.state) {
                      SpeechState.idle => Icons.headphones,
                      SpeechState.paused => Icons.play_arrow,
                      _ => Icons.pause,
                    }),
                  ),
                  if (_narrator.active)
                    IconButton(
                      tooltip: 'Stop narration',
                      onPressed: _narrator.stop,
                      icon: const Icon(Icons.stop),
                    ),
                  IconButton(
                    tooltip: 'Read aloud settings',
                    onPressed: () => _settings(voice: true),
                    icon: const Icon(Icons.tune),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  bool get _canNavigate => !_changing;
}

class _PdfSheet extends StatefulWidget {
  const _PdfSheet({
    required this.document,
    required this.pageNumber,
    required this.active,
    required this.paper,
    required this.darken,
    required this.onZoomChanged,
  });

  final PdfDocument document;
  final int pageNumber;
  final bool active;
  final Paper paper;
  final bool darken;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_PdfSheet> createState() => _PdfSheetState();
}

class _PdfSheetState extends State<_PdfSheet> {
  final _transform = TransformationController();
  Size? _lastSize;
  bool _zoomed = false;

  @override
  void didUpdateWidget(covariant _PdfSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _resetZoom(notify: false);
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  bool get _isZoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  void _resetZoom({bool notify = true}) {
    _transform.value = Matrix4.identity();
    if (_zoomed) {
      _zoomed = false;
      if (mounted) setState(() {});
    }
    if (notify) widget.onZoomChanged(false);
  }

  void _toggleZoom(TapDownDetails details) {
    if (_isZoomed) {
      _resetZoom();
      return;
    }
    final point = details.localPosition;
    _transform.value = Matrix4.identity()
      ..translateByDouble(point.dx, point.dy, 0, 1)
      ..scaleByDouble(2.2, 2.2, 2.2, 1)
      ..translateByDouble(-point.dx, -point.dy, 0, 1);
    _zoomed = true;
    setState(() {});
    widget.onZoomChanged(true);
  }

  void _zoomChanged() {
    final zoomed = _isZoomed;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_lastSize != constraints.biggest) {
        _lastSize = constraints.biggest;
        if (_isZoomed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _resetZoom();
          });
        }
      }
      final page = PdfPageView(
        document: widget.document,
        pageNumber: widget.pageNumber,
        maximumDpi: 240,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .22),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        pageSizeCallback: (size, page, rotationOverride) {
          final rotation = rotationOverride ?? page.rotation;
          final swap = ((rotation.index - page.rotation.index) & 1) == 1;
          final width = swap ? page.height : page.width;
          final height = swap ? page.width : page.height;
          final scale = math.min(size.width / width, size.height / height);
          return Size(width * scale, height * scale);
        },
      );
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: _toggleZoom,
        onDoubleTap: () {},
        child: InteractiveViewer(
          transformationController: _transform,
          // Let a horizontal drag turn the page until the reader zooms in.
          panEnabled: _zoomed,
          scaleEnabled: true,
          minScale: 1,
          maxScale: 5,
          onInteractionEnd: (_) => _zoomChanged(),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: widget.darken
                ? ColorFiltered(
                    colorFilter: const ColorFilter.matrix([
                      -1,
                      0,
                      0,
                      0,
                      255,
                      0,
                      -1,
                      0,
                      0,
                      255,
                      0,
                      0,
                      -1,
                      0,
                      255,
                      0,
                      0,
                      0,
                      1,
                      0,
                    ]),
                    child: page,
                  )
                : page,
          ),
        ),
      );
    },
  );
}

class _CastVoiceTile extends StatelessWidget {
  const _CastVoiceTile({
    required this.character,
    required this.voice,
    required this.settings,
    required this.systemVoices,
    required this.onChanged,
    this.onRemove,
    this.isLead = false,
    this.leadVoice,
    this.onMakeLead,
    this.onMergeIntoLead,
  });

  final String character;
  final CastVoice voice;
  final VoiceSettings settings;
  final List<SystemVoice> systemVoices;
  final ValueChanged<CastVoice> onChanged;
  final VoidCallback? onRemove;
  final bool isLead;
  final CastVoice? leadVoice;
  final VoidCallback? onMakeLead;
  final VoidCallback? onMergeIntoLead;

  @override
  Widget build(BuildContext context) {
    final system = settings.engine == VoiceEngine.system;
    final systemOptions = [
      for (final item in systemVoices)
        if (isLead ||
            item.identifier != leadVoice?.system ||
            item.identifier == voice.system)
          item,
    ];
    final kokoroOptions = [
      for (final item in voices.entries)
        if (isLead || item.key != leadVoice?.kokoro || item.key == voice.kokoro)
          item,
    ];
    final actions = <PopupMenuEntry<String>>[
      if (!isLead && onMakeLead != null)
        const PopupMenuItem(value: 'lead', child: Text('Make main character')),
      if (!isLead && onMergeIntoLead != null)
        const PopupMenuItem(
          value: 'merge',
          child: Text('Merge into main character'),
        ),
      if (onRemove != null)
        const PopupMenuItem(value: 'remove', child: Text('Remove from cast')),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isLead) ...[
                const Icon(Icons.lock, size: 15),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  character,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (isLead)
                const Text(
                  'MAIN',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
              if (actions.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Character actions',
                  itemBuilder: (context) => actions,
                  onSelected: (value) {
                    switch (value) {
                      case 'lead':
                        onMakeLead?.call();
                      case 'merge':
                        onMergeIntoLead?.call();
                      case 'remove':
                        onRemove?.call();
                    }
                  },
                ),
            ],
          ),
          if (system)
            if (systemOptions.isEmpty)
              const Text('Choose the System engine to load iPhone voices.')
            else
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'cast-$character-${voice.system}-${systemOptions.length}',
                ),
                decoration: const InputDecoration(
                  labelText: 'iPhone voice',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                initialValue:
                    systemOptions.any((item) => item.identifier == voice.system)
                    ? voice.system
                    : systemOptions.first.identifier,
                isExpanded: true,
                items: [
                  for (final item in systemOptions)
                    DropdownMenuItem(
                      value: item.identifier,
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => onChanged(voice.withSystem(value)),
              )
          else
            DropdownButtonFormField<int>(
              key: ValueKey('cast-$character-${voice.kokoro}'),
              decoration: const InputDecoration(
                labelText: 'Kokoro voice',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              initialValue:
                  kokoroOptions.any(
                    (item) => item.key == (voice.kokoro ?? settings.voice),
                  )
                  ? voice.kokoro ?? settings.voice
                  : kokoroOptions.first.key,
              isExpanded: true,
              items: [
                for (final item in kokoroOptions)
                  DropdownMenuItem(value: item.key, child: Text(item.value)),
              ],
              onChanged: (value) => onChanged(voice.withKokoro(value)),
            ),
        ],
      ),
    );
  }
}

class _VoiceNotice extends StatelessWidget {
  const _VoiceNotice({
    required this.message,
    required this.action,
    required this.onAction,
  });

  final String message;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
        TextButton(onPressed: onAction, child: Text(action)),
      ],
    ),
  );
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.display,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String display;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label · $display'),
      Semantics(
        label: label,
        child: Slider(
          value: value,
          min: min,
          max: max,
          label: display,
          semanticFormatterCallback: (_) => display,
          onChanged: onChanged,
        ),
      ),
    ],
  );
}
